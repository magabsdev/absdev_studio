import AppKit
import Foundation
import Observation
import SwiftUI

struct ProjectMemoryRecord: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var category: String
    var title: String
    var detail: String
    var createdAt = Date()
}

struct ProjectTimelineEntry: Identifiable, Hashable, Sendable {
    let id = UUID()
    let date: Date
    let kind: String
    let title: String
    let detail: String
}

struct ProjectAuditFinding: Identifiable, Hashable, Sendable {
    enum Severity: String, CaseIterable, Sendable { case critical, high, medium, low, info }
    let id = UUID()
    let severity: Severity
    let title: String
    let detail: String
    let path: String?
}

struct WorkspaceSearchResult: Identifiable, Hashable, Sendable {
    let id = UUID()
    let project: String
    let projectPath: String
    let path: String
    let line: Int
    let excerpt: String
}

struct WorkspaceWorkflow: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var commands: [String]
}

@MainActor @Observable
final class ProjectIntelligenceSuiteModel {
    var memories: [ProjectMemoryRecord] = []
    var timeline: [ProjectTimelineEntry] = []
    var findings: [ProjectAuditFinding] = []
    var searchResults: [WorkspaceSearchResult] = []
    var graphSymbols: [MCPIndexedSymbol] = []
    var graphEdges: [(String, String)] = []
    var workflows: [WorkspaceWorkflow] = []
    var workflowOutput = ""
    var isBusy = false
    var status = "Ready"

    private let fm = FileManager.default

    func load(project: LaravelProject?) {
        guard let project else { return }
        memories = loadJSON([ProjectMemoryRecord].self, at: memoryURL(project.id)) ?? []
        workflows = (loadJSON([WorkspaceWorkflow].self, at: workflowsURL()) ?? Self.defaultWorkflows)
            .filter { $0.name != "Swift Verify" }
        Task { await refreshGraph(project: project); await refreshTimeline(project: project) }
    }

    func addMemory(project: LaravelProject, category: String, title: String, detail: String) {
        memories.insert(ProjectMemoryRecord(category: category, title: title, detail: detail), at: 0)
        saveJSON(memories, at: memoryURL(project.id))
    }

    func deleteMemory(project: LaravelProject, id: UUID) {
        memories.removeAll { $0.id == id }
        saveJSON(memories, at: memoryURL(project.id))
    }

    func refreshGraph(project: LaravelProject) async {
        isBusy = true; status = "Indexing project graph…"
        let result = await Task.detached { () -> ([MCPIndexedSymbol], [(String, String)]) in
            let def = MCPProjectDefinition(id: project.id.uuidString, name: project.name, rootPath: project.path)
            guard let snapshot = try? MCPProjectIntelligence.shared.rebuild(project: def, force: false) else { return ([], []) }
            let symbols = snapshot.documents.flatMap(\.symbols)
            let files = (try? MCPProjectIntelligence.shared.discoverProjectFiles(project: def)) ?? []
            let raw = MCPProjectIntelligence.shared.dependencyGraph(project: def, files: files, limit: 1000)
            let edges = raw.compactMap { item -> (String, String)? in
                guard let source = item["source"] as? String, let target = item["target"] as? String else { return nil }
                return (source, target)
            }
            return (symbols, edges)
        }.value
        graphSymbols = result.0; graphEdges = result.1
        status = "Indexed \(graphSymbols.count) symbols and \(graphEdges.count) dependencies"
        isBusy = false
    }

    func refreshTimeline(project: LaravelProject) async {
        let entries = await Task.detached { Self.gitTimeline(path: project.path) }.value
        timeline = entries
    }

    func runAudit(project: LaravelProject) async {
        isBusy = true; status = "Running health audit…"
        findings = await Task.detached { Self.audit(project: project) }.value
        status = findings.isEmpty ? "No material findings" : "Audit found \(findings.count) items"
        isBusy = false
    }

    func search(projects: [LaravelProject], query: String) async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { searchResults = []; return }
        isBusy = true; status = "Searching workspace…"
        searchResults = await Task.detached { Self.workspaceSearch(projects: projects, query: query) }.value
        status = "Found \(searchResults.count) matches across \(Set(searchResults.map(\.project)).count) projects"
        isBusy = false
    }

    func runWorkflow(_ workflow: WorkspaceWorkflow, project: LaravelProject) async {
        isBusy = true; workflowOutput = "$ cd \(project.path)\n"
        for command in workflow.commands {
            let resolvedCommand = Self.resolveWorkflowCommand(command, project: project)
            workflowOutput += "\n$ \(resolvedCommand)\n"
            let result = await Task.detached { Self.runShell(resolvedCommand, cwd: project.path) }.value
            workflowOutput += result.output
            if result.status != 0 { workflowOutput += "\nStopped with exit code \(result.status).\n"; break }
        }
        isBusy = false; status = "Workflow finished"
    }

    func saveWorkflows() { saveJSON(workflows, at: workflowsURL()) }

    private static var defaultWorkflows: [WorkspaceWorkflow] {[
        WorkspaceWorkflow(name: "Laravel Refresh", commands: ["git pull --ff-only", "composer install", "php artisan migrate --force", "npm install", "npm run build", "php artisan test"]),
        WorkspaceWorkflow(name: "Quick Test", commands: ["php artisan test"])
    ]}

    nonisolated private static func gitTimeline(path: String) -> [ProjectTimelineEntry] {
        let result = runShell("git log -n 80 --date=iso-strict --pretty=format:'%aI%x09%h%x09%s'", cwd: path)
        let formatter = ISO8601DateFormatter()
        return result.output.split(separator: "\n").compactMap { row in
            let parts = row.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3, let date = formatter.date(from: parts[0]) else { return nil }
            return ProjectTimelineEntry(date: date, kind: "Commit", title: parts[2], detail: parts[1])
        }
    }

    nonisolated private static func audit(project: LaravelProject) -> [ProjectAuditFinding] {
        let path = project.path
        let root = URL(fileURLWithPath: path)
        var f: [ProjectAuditFinding] = []
        func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(p).path) }
        func text(_ p: String) -> String { (try? String(contentsOf: root.appendingPathComponent(p), encoding: .utf8)) ?? "" }
        if exists("composer.json") {
            if !exists("composer.lock") { f.append(.init(severity: .high, title: "Composer lock file missing", detail: "Reproducible dependency installation cannot be guaranteed.", path: "composer.lock")) }
            let env = text(".env")
            let isProduction = env.contains("APP_ENV=production")
            if isProduction && env.contains("APP_DEBUG=true") {
                f.append(.init(severity: .critical, title: "Production debug exposure", detail: "Production is configured with debug output enabled.", path: ".env"))
            }
            if !exists("tests") && !exists("Tests") { f.append(.init(severity: .medium, title: "No test directory detected", detail: "Add automated coverage for critical application behaviour.", path: nil)) }
            if exists("package.json") && !exists("package-lock.json") && !exists("pnpm-lock.yaml") && !exists("yarn.lock") { f.append(.init(severity: .medium, title: "Frontend lock file missing", detail: "Commit a package-manager lock file.", path: "package.json")) }
            if let composer = composerExecutable(projectPath: path) {
                let php = phpExecutable(for: project)
                let command = "\(shellQuote(php)) \(shellQuote(composer)) audit --no-interaction"
                let audit = runShell(command, cwd: path)
                if audit.status != 0 { f.append(.init(severity: .high, title: "Composer security audit failed", detail: String(audit.output.prefix(1500)), path: "composer.lock")) }
            } else {
                f.append(.init(severity: .medium, title: "Composer executable not found", detail: "Configure Composer or install it in ServBay, Homebrew, /usr/local, or the project root. The security audit was skipped.", path: "composer.lock"))
            }
        }
        if exists("Package.swift") {
            if !exists("Tests") { f.append(.init(severity: .medium, title: "Swift tests missing", detail: "No Tests directory was detected.", path: nil)) }
            let test = runShell("swift test --skip-build", cwd: path)
            if test.status != 0 { f.append(.init(severity: .medium, title: "Swift test verification failed", detail: String(test.output.prefix(1500)), path: "Package.swift")) }
        }
        let git = runShell("git status --porcelain", cwd: path)
        if !git.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { f.append(.init(severity: .info, title: "Working tree has changes", detail: String(git.output.prefix(1200)), path: nil)) }
        return f.sorted { $0.severity.rank < $1.severity.rank }
    }

    nonisolated private static func workspaceSearch(projects: [LaravelProject], query: String) -> [WorkspaceSearchResult] {
        let escaped = query.replacingOccurrences(of: "'", with: "'\\''")
        var results: [WorkspaceSearchResult] = []
        for project in projects {
            let command: String
            if let rg = executable(named: "rg") {
                command = "\(shellQuote(rg)) -n -i --hidden --glob '!vendor/**' --glob '!node_modules/**' --glob '!.git/**' --glob '!DerivedData/**' --max-count 30 '\(escaped)' ."
            } else {
                command = "grep -RIn --exclude-dir=vendor --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=DerivedData -- '\(escaped)' . | head -n 100"
            }
            let output = runShell(command, cwd: project.path).output
            for line in output.split(separator: "\n").prefix(100) {
                let parts = line.split(separator: ":", maxSplits: 2).map(String.init)
                guard parts.count == 3 else { continue }
                results.append(.init(project: project.name, projectPath: project.path, path: parts[0], line: Int(parts[1]) ?? 0, excerpt: parts[2]))
                if results.count >= 500 { return results }
            }
        }
        return results
    }

    nonisolated private static func resolveWorkflowCommand(_ command: String, project: LaravelProject) -> String {
        var resolved = command
        let php = shellQuote(phpExecutable(for: project))
        if resolved == "php" || resolved.hasPrefix("php ") {
            resolved = php + resolved.dropFirst(3)
        }
        if resolved == "composer" || resolved.hasPrefix("composer ") {
            if let composer = composerExecutable(projectPath: project.path) {
                let composerCommand = "\(php) \(shellQuote(composer))"
                resolved = composerCommand + resolved.dropFirst("composer".count)
            }
        }
        return resolved
    }

    nonisolated private static func phpExecutable(for project: LaravelProject) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        if let configured = project.phpExecutablePath { candidates.append(configured) }
        candidates += [
            "\(home)/Library/Application Support/Herd/bin/php",
            "\(home)/.config/herd-lite/bin/php",
            "\(home)/.config/valet/bin/php",
            "/Applications/ServBay/package/php/current/bin/php",
            "/opt/homebrew/opt/php@8.4/bin/php",
            "/opt/homebrew/opt/php@8.3/bin/php",
            "/opt/homebrew/opt/php@8.2/bin/php",
            "/opt/homebrew/bin/php",
            "/usr/local/bin/php",
            "/usr/bin/php"
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            let result = runShell("\(shellQuote(candidate)) -r 'echo PHP_VERSION;'", cwd: project.path)
            if result.status == 0, !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return candidate }
        }
        return "/usr/bin/php"
    }

    nonisolated private static func composerExecutable(projectPath: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            URL(fileURLWithPath: projectPath).appendingPathComponent("composer.phar").path,
            "/Applications/ServBay/package/composer/current/bin/composer",
            "/Applications/ServBay/bin/composer",
            "\(home)/.composer/vendor/bin/composer",
            "/opt/homebrew/bin/composer",
            "/usr/local/bin/composer"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    nonisolated private static func executable(named name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            "/Applications/ServBay/bin", "\(home)/.local/bin", "\(home)/bin"
        ]
        return directories.map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated private static func runShell(_ command: String, cwd: String) -> (status: Int32, output: String) {
        let p = Process(); let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "/Applications/ServBay/bin", "\(home)/.local/bin", "\(home)/bin", environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        p.environment = environment
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run(); p.waitUntilExit() } catch { return (-1, error.localizedDescription) }
        return (p.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }

    private func baseURL() -> URL { fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ABSDEVStudio/ProjectIntelligence", isDirectory: true) }
    private func memoryURL(_ id: UUID) -> URL { baseURL().appendingPathComponent("memory-\(id.uuidString).json") }
    private func workflowsURL() -> URL { baseURL().appendingPathComponent("workflows.json") }
    private func saveJSON<T: Encodable>(_ value: T, at url: URL) { try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); if let d = try? JSONEncoder().encode(value) { try? d.write(to: url, options: .atomic) } }
    private func loadJSON<T: Decodable>(_ type: T.Type, at url: URL) -> T? { guard let d = try? Data(contentsOf: url) else { return nil }; return try? JSONDecoder().decode(type, from: d) }
}

private extension ProjectAuditFinding.Severity { var rank: Int { switch self { case .critical: 0; case .high: 1; case .medium: 2; case .low: 3; case .info: 4 } } }

struct ProjectIntelligenceView: View {
    enum Tab: String, CaseIterable, Identifiable { case studio = "Product Studio", memory = "AI Memory", graph = "Knowledge Graph", entities = "Entity Diagrams", timeline = "Timeline", audit = "Health Audit", mcp = "MCP Hub", automation = "Automation", search = "Cross-Project Search"; var id: String { rawValue } }
    @Environment(AppStore.self) private var store
    @State private var model = ProjectIntelligenceSuiteModel()
    @State private var tab: Tab = .memory
    @State private var query = ""
    @State private var memoryTitle = ""
    @State private var memoryDetail = ""
    @State private var memoryCategory = "Architecture"

    var body: some View {
        VStack(spacing: 0) {
            HStack { PageHeader(title: "Project Intelligence", subtitle: "Persistent project memory, repository knowledge, audits, automation, and workspace-wide MCP intelligence."); Spacer(); if model.isBusy { ProgressView() }; Text(model.status).font(.caption).foregroundStyle(.secondary) }.padding(24)
            Picker("Feature", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).padding(.horizontal, 24).padding(.bottom, 16)
            Divider()
            Group { switch tab { case .studio: ProductStudioView(); case .memory: memoryView; case .graph: graphView; case .entities: EntityDiagramWorkspaceView(project: store.selectedProject); case .timeline: timelineView; case .audit: auditView; case .mcp: mcpView; case .automation: automationView; case .search: searchView } }
        }
        .task(id: store.selectedProjectID) { model.load(project: store.selectedProject) }
    }

    private var memoryView: some View { ScrollView { VStack(alignment: .leading, spacing: 16) { GroupBox("Add project memory") { VStack(alignment: .leading) { HStack { Picker("Category", selection: $memoryCategory) { ForEach(["Architecture","Convention","Coding Standard","Decision","Known Issue"], id: \.self) { Text($0) } }.frame(width: 190); TextField("Title", text: $memoryTitle) }; TextEditor(text: $memoryDetail).frame(minHeight: 80); HStack { Spacer(); Button("Remember", systemImage: "brain.head.profile") { guard let p = store.selectedProject, !memoryTitle.isEmpty else { return }; model.addMemory(project: p, category: memoryCategory, title: memoryTitle, detail: memoryDetail); memoryTitle=""; memoryDetail="" } } } }.padding(.bottom, 8); ForEach(model.memories) { item in GroupBox { HStack(alignment: .top) { VStack(alignment: .leading, spacing: 5) { Text(item.category.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary); Text(item.title).font(.headline); Text(item.detail).textSelection(.enabled) }; Spacer(); Button(role: .destructive) { if let p=store.selectedProject { model.deleteMemory(project:p,id:item.id) } } label: { Image(systemName:"trash") }.buttonStyle(.borderless) } } } }.padding(24) } }

    private var graphView: some View { VStack { HStack { Text("\(model.graphSymbols.count) symbols · \(model.graphEdges.count) dependencies").foregroundStyle(.secondary); Spacer(); Button("Rebuild Graph", systemImage:"arrow.clockwise") { if let p=store.selectedProject { Task { await model.refreshGraph(project:p) } } } }.padding(); Table(model.graphSymbols) { TableColumn("Kind", value:\.kind); TableColumn("Symbol", value:\.name); TableColumn("File", value:\.path); TableColumn("Line") { Text("\($0.line)") } } } }
    private var timelineView: some View { VStack { HStack { Spacer(); Button("Refresh", systemImage:"arrow.clockwise") { if let p=store.selectedProject { Task { await model.refreshTimeline(project:p) } } } }.padding(); List(model.timeline) { e in HStack(alignment:.top) { Text(e.date, style:.date).frame(width:100,alignment:.leading); VStack(alignment:.leading) { Text(e.title).font(.headline); Text("\(e.kind) · \(e.detail)").font(.caption).foregroundStyle(.secondary) } } } } }
    private var auditView: some View { VStack { HStack { Text("Laravel, Swift, dependency, environment, testing, and repository checks.").foregroundStyle(.secondary); Spacer(); Button("Run Full Audit", systemImage:"stethoscope") { if let p=store.selectedProject { Task { await model.runAudit(project:p) } } }.buttonStyle(.borderedProminent) }.padding(); List(model.findings) { f in VStack(alignment:.leading,spacing:5) { HStack { Text(f.severity.rawValue.uppercased()).font(.caption.bold()); Text(f.title).font(.headline); Spacer(); if let path=f.path { Text(path).font(.caption.monospaced()).foregroundStyle(.secondary) } }; Text(f.detail).foregroundStyle(.secondary).textSelection(.enabled) } } } }
    private var mcpView: some View {
        ScrollView {
            VStack(spacing: 22) {
                ContentUnavailableView(
                    "Native MCP Hub is active",
                    systemImage: "server.rack",
                    description: Text("The embedded server already synchronises navigator projects, maintains per-project indexes, exposes project-aware search and reasoning tools, and records diagnostics.")
                )
                .frame(maxWidth: 620)

                GroupBox("Workspace tools") {
                    Text("projects_list · ask_project · project_search · semantic_search · find_definition · find_references · project_dependency_graph · project_git_status · run_project_tests")
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: 900)

                Button("Open MCP Tools", systemImage: "network") { store.selectedSection = .mcp }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(24)
        }
    }
    private var automationView: some View { HSplitView { List(model.workflows, selection: .constant(nil as UUID?)) { w in VStack(alignment:.leading) { Text(w.name).font(.headline); Text(w.commands.joined(separator:" → ")).font(.caption).foregroundStyle(.secondary).lineLimit(2); Button("Run", systemImage:"play.fill") { if let p=store.selectedProject { Task { await model.runWorkflow(w,project:p) } } }.padding(.top,4) } }.frame(minWidth:340); ScrollView { Text(model.workflowOutput.isEmpty ? "Workflow output will appear here." : model.workflowOutput).font(.system(.body,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.topLeading).padding() } } }
    private var searchView: some View { VStack { HStack { TextField("Search classes, routes, migrations, translations, views, endpoints…", text:$query).textFieldStyle(.roundedBorder).onSubmit { Task { await model.search(projects:store.projects,query:query) } }; Button("Search All Projects", systemImage:"magnifyingglass") { Task { await model.search(projects:store.projects,query:query) } }.buttonStyle(.borderedProminent) }.padding(); Table(model.searchResults) { TableColumn("Project",value:\.project).width(min:100,ideal:140); TableColumn("File",value:\.path).width(min:220,ideal:360); TableColumn("Line") { Text("\($0.line)") }.width(55); TableColumn("Match",value:\.excerpt) } } }
}

// MARK: - Product Studio

private struct ProductStudioMetric: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let value: String
    let detail: String
    let symbol: String
}

private struct ProductStudioItem: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let detail: String
    let path: String?
    let kind: String
}

@MainActor @Observable
private final class ProductStudioModel {
    enum Module: String, CaseIterable, Identifiable {
        case dashboard = "Mission Control"
        case architecture = "Architecture"
        case database = "Database Studio"
        case git = "Git Client"
        case deployment = "Deployment"
        case ai = "AI Assistant"
        case performance = "Performance"
        case security = "Security Centre"
        case packages = "Packages"
        case routes = "Route Designer"
        case queues = "Queue Studio"
        case scheduler = "Scheduler"
        case logs = "Log Centre"
        case api = "API Studio"
        case containers = "Containers"
        case upgrade = "Upgrade Assistant"
        case templates = "Templates"
        case metrics = "Code Metrics"
        case documentation = "Documentation"
        case replay = "Project Replay"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .dashboard: "gauge.with.dots.needle.50percent"
            case .architecture: "point.3.connected.trianglepath.dotted"
            case .database: "cylinder.split.1x2"
            case .git: "arrow.triangle.branch"
            case .deployment: "cloud.fill"
            case .ai: "brain.head.profile"
            case .performance: "waveform.path.ecg.rectangle"
            case .security: "lock.shield.fill"
            case .packages: "shippingbox.fill"
            case .routes: "signpost.right.and.left.fill"
            case .queues: "tray.full.fill"
            case .scheduler: "calendar.badge.clock"
            case .logs: "doc.text.magnifyingglass"
            case .api: "network"
            case .containers: "shippingbox.and.arrow.backward.fill"
            case .upgrade: "arrow.up.forward.app.fill"
            case .templates: "square.grid.2x2.fill"
            case .metrics: "chart.xyaxis.line"
            case .documentation: "doc.richtext.fill"
            case .replay: "clock.arrow.circlepath"
            }
        }
    }

    var selected: Module = .dashboard
    var metrics: [ProductStudioMetric] = []
    var items: [ProductStudioItem] = []
    var output = ""
    var isBusy = false
    var status = "Ready"

    func refresh(project: LaravelProject?) async {
        guard let project else { metrics = []; items = []; return }
        isBusy = true
        status = "Inspecting \(selected.rawValue)…"
        let module = selected
        let snapshot = await Task.detached { Self.scan(project: project, module: module) }.value
        metrics = snapshot.0
        items = snapshot.1
        output = ""
        status = snapshot.2
        isBusy = false
    }

    func run(_ command: String, project: LaravelProject) async {
        isBusy = true
        let resolved = Self.resolveProjectCommand(command, project: project)
        output = "$ cd \(project.path)\n$ \(resolved.display)\n\n"
        let result = await Task.detached { Self.shell(resolved.command, cwd: project.path) }.value
        output += result.output
        output += "\nExit code: \(result.status)\n"
        status = result.status == 0 ? "Command completed" : "Command failed"
        isBusy = false
    }

    nonisolated private static func scan(project: LaravelProject, module: Module) -> ([ProductStudioMetric], [ProductStudioItem], String) {
        let root = URL(fileURLWithPath: project.path)
        let fm = FileManager.default
        func exists(_ relative: String) -> Bool { fm.fileExists(atPath: root.appendingPathComponent(relative).path) }
        func count(_ command: String) -> Int {
            Int(shell(command, cwd: project.path).output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        func lines(_ command: String) -> [String] {
            shell(command, cwd: project.path).output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        }
        func itemise(_ values: [String], kind: String) -> [ProductStudioItem] {
            values.prefix(250).map { value in ProductStudioItem(title: URL(fileURLWithPath: value).lastPathComponent, detail: value, path: value, kind: kind) }
        }

        let isLaravel = exists("artisan") && exists("composer.json")
        let phpFiles = count("find app Modules -type f -name '*.php' 2>/dev/null | wc -l | tr -d ' '")
        let tests = count("find tests Tests -type f 2>/dev/null | wc -l | tr -d ' '")
        let commits = count("git rev-list --count HEAD 2>/dev/null || echo 0")

        switch module {
        case .dashboard:
            let branch = shell("git branch --show-current 2>/dev/null", cwd: project.path).output.trimmingCharacters(in: .whitespacesAndNewlines)
            let dirty = !shell("git status --porcelain", cwd: project.path).output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let routeCount = isLaravel ? count("php artisan route:list --json 2>/dev/null | php -r '$d=json_decode(stream_get_contents(STDIN),true); echo is_array($d)?count($d):0;' 2>/dev/null") : 0
            return ([
                .init(title: "Source Files", value: "\(phpFiles)", detail: "Application PHP files", symbol: "doc.on.doc"),
                .init(title: "Tests", value: "\(tests)", detail: "Automated test files", symbol: "checkmark.seal"),
                .init(title: "Routes", value: "\(routeCount)", detail: "Registered Laravel routes", symbol: "signpost.right"),
                .init(title: "Commits", value: "\(commits)", detail: branch.isEmpty ? "Git repository" : branch, symbol: "arrow.triangle.branch"),
                .init(title: "Working Tree", value: dirty ? "Changed" : "Clean", detail: dirty ? "Uncommitted changes" : "No local changes", symbol: dirty ? "exclamationmark.triangle" : "checkmark.circle")
            ], [], "Project mission control refreshed")

        case .architecture:
            let commands = [
                ("Models", "find app Modules -type f -path '*/Models/*.php' 2>/dev/null | sort"),
                ("Controllers", "find app Modules -type f -path '*/Controllers/*.php' 2>/dev/null | sort"),
                ("Services", "find app Modules -type f \\( -path '*/Services/*.php' -o -path '*/Repositories/*.php' \\) 2>/dev/null | sort"),
                ("Events", "find app Modules -type f \\( -path '*/Events/*.php' -o -path '*/Listeners/*.php' \\) 2>/dev/null | sort"),
                ("Jobs", "find app Modules -type f -path '*/Jobs/*.php' 2>/dev/null | sort")
            ]
            let result = commands.flatMap { name, command in itemise(lines(command), kind: name) }
            return ([.init(title: "Architecture Nodes", value: "\(result.count)", detail: "Models, controllers, services, events and jobs", symbol: "point.3.connected.trianglepath.dotted")], result, "Architecture index contains \(result.count) nodes")

        case .database:
            let migrations = itemise(lines("find database/migrations Modules -type f -name '*.php' 2>/dev/null | sort"), kind: "Migration")
            return ([.init(title: "Migrations", value: "\(migrations.count)", detail: "Schema evolution files", symbol: "cylinder")], migrations, "Database Studio is ready")

        case .git:
            let entries = lines("git log -n 100 --pretty=format:'%h%x09%ad%x09%s' --date=short 2>/dev/null").map { row -> ProductStudioItem in
                let p = row.split(separator: "\t", maxSplits: 2).map(String.init)
                return ProductStudioItem(title: p.count > 2 ? p[2] : row, detail: p.count > 1 ? "\(p[0]) · \(p[1])" : row, path: nil, kind: "Commit")
            }
            return ([.init(title: "Commits", value: "\(commits)", detail: "Repository history", symbol: "arrow.triangle.branch")], entries, "Loaded recent Git history")

        case .deployment:
            let files = itemise(lines("find . -maxdepth 3 -type f \\( -name 'Dockerfile*' -o -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' -o -name 'forge.yml' -o -name 'deploy*.sh' -o -name 'serverless.yml' -o -name 'Procfile' \\) 2>/dev/null | sort"), kind: "Deployment")
            return ([.init(title: "Deployment Assets", value: "\(files.count)", detail: "Detected deployment configuration", symbol: "cloud")], files, "Deployment configuration inspected")

        case .ai:
            return ([.init(title: "Project Context", value: "Active", detail: "MCP index and project memory available", symbol: "brain.head.profile")], [], "AI project context is available")

        case .performance:
            let configs = ["config/cache.php", "config/queue.php", "config/database.php"].filter(exists).map { ProductStudioItem(title: URL(fileURLWithPath: $0).lastPathComponent, detail: $0, path: $0, kind: "Configuration") }
            return ([.init(title: "Instrumentation", value: exists("composer.lock") ? "Ready" : "Review", detail: "Cache, queue and database configuration", symbol: "waveform.path.ecg")], configs, "Performance configuration inspected")

        case .security:
            var findings: [ProductStudioItem] = []
            let env = (try? String(contentsOf: root.appendingPathComponent(".env"), encoding: .utf8)) ?? ""
            if env.contains("APP_ENV=production") && env.contains("APP_DEBUG=true") { findings.append(.init(title: "Production debug enabled", detail: "Set APP_DEBUG=false in production.", path: ".env", kind: "Critical")) }
            if !exists("composer.lock") { findings.append(.init(title: "Composer lock missing", detail: "Commit composer.lock for reproducible and auditable builds.", path: "composer.lock", kind: "High")) }
            if !exists("tests") && !exists("Tests") { findings.append(.init(title: "Tests not detected", detail: "Add automated security and behaviour coverage.", path: nil, kind: "Medium")) }
            return ([.init(title: "Security Findings", value: "\(findings.count)", detail: findings.isEmpty ? "No baseline issues found" : "Review required", symbol: "lock.shield")], findings, "Security baseline completed")

        case .packages:
            let packages = lines("grep -E '\"name\"[[:space:]]*:' composer.lock 2>/dev/null | sed -E 's/.*\"name\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\\1/' | sort -u").map { name in
                ProductStudioItem(title: name, detail: "Installed Composer dependency", path: "composer.lock", kind: "Composer")
            }
            return ([.init(title: "Composer Packages", value: "\(packages.count)", detail: "Installed production and development packages", symbol: "shippingbox")], packages, "Package inventory loaded")

        case .routes:
            let routeLines = lines("php artisan route:list --except-vendor 2>/dev/null")
            return ([.init(title: "Routes", value: "\(max(0, routeLines.count - 2))", detail: "Application route map", symbol: "signpost.right.and.left")], itemise(routeLines, kind: "Route"), "Route map loaded")

        case .queues:
            let jobs = itemise(lines("find app Modules -type f -path '*/Jobs/*.php' 2>/dev/null | sort"), kind: "Job")
            return ([.init(title: "Queued Jobs", value: "\(jobs.count)", detail: "Discovered job classes", symbol: "tray.full")], jobs, "Queue classes inspected")

        case .scheduler:
            let schedule = lines("php artisan schedule:list 2>/dev/null")
            return ([.init(title: "Scheduled Tasks", value: "\(schedule.count)", detail: "Configured scheduler entries", symbol: "calendar.badge.clock")], itemise(schedule, kind: "Schedule"), "Scheduler inspected")

        case .logs:
            let logs = itemise(lines("find storage/logs -type f -maxdepth 2 2>/dev/null | sort"), kind: "Log")
            return ([.init(title: "Log Files", value: "\(logs.count)", detail: "Laravel application logs", symbol: "doc.text.magnifyingglass")], logs, "Log sources discovered")

        case .api:
            let controllers = itemise(lines("find app Modules -type f \\( -path '*/Http/Controllers/Api/*.php' -o -path '*/Http/Resources/*.php' \\) 2>/dev/null | sort"), kind: "API")
            return ([.init(title: "API Components", value: "\(controllers.count)", detail: "Controllers and resources", symbol: "network")], controllers, "API surface inspected")

        case .containers:
            let assets = itemise(lines("find . -maxdepth 3 -type f \\( -name 'Dockerfile*' -o -name 'compose.yml' -o -name 'compose.yaml' -o -name 'docker-compose.yml' -o -name 'docker-compose.yaml' \\) 2>/dev/null | sort"), kind: "Container")
            return ([.init(title: "Container Assets", value: "\(assets.count)", detail: "Docker and Compose definitions", symbol: "shippingbox.and.arrow.backward")], assets, "Container configuration inspected")

        case .upgrade:
            let composer = (try? String(contentsOf: root.appendingPathComponent("composer.json"), encoding: .utf8)) ?? ""
            let framework = composer.range(of: #"laravel/framework\"\s*:\s*\"([^\"]+)"#, options: .regularExpression).map { String(composer[$0]) } ?? "Not detected"
            return ([.init(title: "Laravel Constraint", value: framework.replacingOccurrences(of: "\"", with: ""), detail: "Review packages and deprecations before upgrade", symbol: "arrow.up.forward.app")], [], "Upgrade readiness inspected")

        case .templates:
            let templates = ["SaaS", "REST API", "Livewire", "Inertia", "Filament", "Modular Enterprise", "GraphQL"].map { ProductStudioItem(title: $0, detail: "Curated Laravel project blueprint", path: nil, kind: "Template") }
            return ([.init(title: "Blueprints", value: "\(templates.count)", detail: "Available project starting points", symbol: "square.grid.2x2")], templates, "Project templates available")

        case .metrics:
            let classes = count("grep -RIl --include='*.php' -E '^[[:space:]]*(final[[:space:]]+)?(abstract[[:space:]]+)?class[[:space:]]+' app Modules 2>/dev/null | wc -l | tr -d ' '")
            let methods = count("grep -Rho --include='*.php' -E 'function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' app Modules 2>/dev/null | wc -l | tr -d ' '")
            return ([
                .init(title: "PHP Files", value: "\(phpFiles)", detail: "Application source", symbol: "doc.on.doc"),
                .init(title: "Classes", value: "\(classes)", detail: "Declared classes", symbol: "cube"),
                .init(title: "Methods", value: "\(methods)", detail: "Declared methods", symbol: "function"),
                .init(title: "Tests", value: "\(tests)", detail: "Test files", symbol: "checkmark.seal")
            ], [], "Code metrics calculated")

        case .documentation:
            let docs = itemise(lines("find . -maxdepth 3 -type f \\( -iname 'README*' -o -iname '*.md' -o -path './docs/*' \\) -not -path './vendor/*' -not -path './node_modules/*' 2>/dev/null | sort"), kind: "Documentation")
            return ([.init(title: "Documentation Files", value: "\(docs.count)", detail: "Markdown and project guides", symbol: "doc.richtext")], docs, "Documentation inventory loaded")

        case .replay:
            let history = lines("git log -n 150 --date=iso --pretty=format:'%ad%x09%h%x09%s' 2>/dev/null").map { row -> ProductStudioItem in
                let p = row.split(separator: "\t", maxSplits: 2).map(String.init)
                return ProductStudioItem(title: p.count > 2 ? p[2] : row, detail: p.count > 1 ? "\(p[0]) · \(p[1])" : row, path: nil, kind: "History")
            }
            return ([.init(title: "Replay Events", value: "\(history.count)", detail: "Recent project evolution", symbol: "clock.arrow.circlepath")], history, "Project replay built from Git history")
        }
    }

    nonisolated private static func resolveProjectCommand(_ command: String, project: LaravelProject) -> (command: String, display: String) {
        var resolved = command
        let display = command
        let php = workingPHP(for: project)
        if command == "php" || command.hasPrefix("php ") {
            resolved = shellQuote(php) + command.dropFirst(3)
        }
        if command == "composer" || command.hasPrefix("composer ") {
            guard let composer = composerExecutable(projectPath: project.path) else {
                return ("printf '%s\n' 'Composer was not found. Configure Composer in ABSDEV Studio or install it with ServBay/Homebrew.'; exit 127", command)
            }
            resolved = "\(shellQuote(php)) \(shellQuote(composer))" + command.dropFirst("composer".count)
        }
        return (resolved, display)
    }

    nonisolated private static func workingPHP(for project: LaravelProject) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        if let configured = project.phpExecutablePath { candidates.append(configured) }
        candidates += [
            "\(home)/Library/Application Support/Herd/bin/php",
            "\(home)/.config/herd-lite/bin/php",
            "\(home)/.config/valet/bin/php",
            "/Applications/ServBay/package/php/current/bin/php",
            "/opt/homebrew/opt/php@8.4/bin/php",
            "/opt/homebrew/opt/php@8.3/bin/php",
            "/opt/homebrew/opt/php@8.2/bin/php",
            "/opt/homebrew/bin/php",
            "/usr/local/bin/php",
            "/usr/bin/php"
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            let test = shell("\(shellQuote(candidate)) -r 'echo PHP_VERSION;'", cwd: project.path)
            if test.status == 0, !test.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return candidate }
        }
        return "/usr/bin/php"
    }

    nonisolated private static func composerExecutable(projectPath: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            URL(fileURLWithPath: projectPath).appendingPathComponent("composer.phar").path,
            "/Applications/ServBay/package/composer/current/bin/composer",
            "/Applications/ServBay/bin/composer",
            "\(home)/.composer/vendor/bin/composer",
            "/opt/homebrew/bin/composer",
            "/usr/local/bin/composer"
        ]
        return candidates.first { FileManager.default.isReadableFile(atPath: $0) }
    }

    nonisolated private static func shell(_ command: String, cwd: String) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = ["/Applications/ServBay/bin", "/Applications/ServBay/package/php/current/bin", "/Applications/ServBay/package/composer/current/bin", "\(home)/Library/Application Support/Herd/bin", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        environment["PATH"] = (paths + [environment["PATH"] ?? ""]).joined(separator: ":")
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run(); process.waitUntilExit() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private struct ProductStudioView: View {
    @Environment(AppStore.self) private var store
    @State private var model = ProductStudioModel()

    var body: some View {
        HSplitView {
            List(ProductStudioModel.Module.allCases, selection: $model.selected) { module in
                Label(module.rawValue, systemImage: module.symbol).tag(module)
            }
            .frame(minWidth: 205, idealWidth: 230, maxWidth: 275)

            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.selected.rawValue).font(.title2.bold())
                        Text(description(for: model.selected)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh(project: store.selectedProject) } }
                }
                .padding(20)
                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !model.metrics.isEmpty {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                                ForEach(model.metrics) { metric in
                                    GroupBox {
                                        HStack(alignment: .top) {
                                            Image(systemName: metric.symbol).foregroundStyle(.tint).font(.title3)
                                            VStack(alignment: .leading, spacing: 5) {
                                                Text(metric.value).font(.title2.bold())
                                                Text(metric.title).font(.headline)
                                                Text(metric.detail).font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                        }.frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
                                    }
                                }
                            }
                        }

                        actionBar

                        if !model.items.isEmpty {
                            GroupBox("Results") {
                                LazyVStack(spacing: 0) {
                                    ForEach(model.items) { item in
                                        HStack(alignment: .top, spacing: 12) {
                                            Image(systemName: icon(for: item.kind)).foregroundStyle(.secondary).frame(width: 18)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(item.title).font(.headline)
                                                Text(item.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                            }
                                            Spacer()
                                            Text(item.kind).font(.caption2.bold()).foregroundStyle(.secondary)
                                        }
                                        .padding(.vertical, 9)
                                        if item.id != model.items.last?.id { Divider() }
                                    }
                                }
                            }
                        }

                        if !model.output.isEmpty {
                            GroupBox("Output") {
                                Text(model.output).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .frame(minWidth: 650)
        }
        .task(id: store.selectedProjectID) { await model.refresh(project: store.selectedProject) }
        .onChange(of: model.selected) { _, _ in Task { await model.refresh(project: store.selectedProject) } }
    }

    @ViewBuilder private var actionBar: some View {
        if let project = store.selectedProject {
            GroupBox("Actions") {
                HStack(spacing: 10) {
                    switch model.selected {
                    case .database:
                        Button("Open Database Inspector", systemImage: "cylinder") { store.selectedSection = .database }
                        Button("Open ERD", systemImage: "point.3.connected.trianglepath.dotted") { }
                    case .git:
                        Button("Status", systemImage: "arrow.triangle.branch") { Task { await model.run("git status --short --branch", project: project) } }
                        Button("Fetch", systemImage: "arrow.down.circle") { Task { await model.run("git fetch --all --prune", project: project) } }
                    case .deployment:
                        Button("Build", systemImage: "hammer") { Task { await model.run("npm run build", project: project) } }
                        Button("Optimise", systemImage: "bolt") { Task { await model.run("php artisan optimize", project: project) } }
                    case .ai:
                        Button("Open AI Workspace", systemImage: "brain.head.profile") { store.selectedSection = .aiWorkspace }
                        Button("Open MCP Tools", systemImage: "network") { store.selectedSection = .mcp }
                    case .performance:
                        Button("Laravel About", systemImage: "info.circle") { Task { await model.run("php artisan about", project: project) } }
                        Button("Clear Caches", systemImage: "trash") { Task { await model.run("php artisan optimize:clear", project: project) } }
                    case .security:
                        Button("Composer Audit", systemImage: "lock.shield") { Task { await model.run("composer audit --no-interaction", project: project) } }
                        Button("Run Tests", systemImage: "checkmark.seal") { Task { await model.run("php artisan test", project: project) } }
                    case .packages:
                        Button("Outdated", systemImage: "clock.arrow.circlepath") { Task { await model.run("composer outdated --direct", project: project) } }
                        Button("Audit", systemImage: "shield.lefthalf.filled") { Task { await model.run("composer audit", project: project) } }
                    case .routes:
                        Button("Export Routes", systemImage: "square.and.arrow.up") { Task { await model.run("php artisan route:list --json", project: project) } }
                    case .queues:
                        Button("Failed Jobs", systemImage: "exclamationmark.triangle") { Task { await model.run("php artisan queue:failed", project: project) } }
                        Button("Retry All", systemImage: "arrow.clockwise") { Task { await model.run("php artisan queue:retry all", project: project) } }
                    case .scheduler:
                        Button("Run Scheduler", systemImage: "play") { Task { await model.run("php artisan schedule:run", project: project) } }
                    case .logs:
                        Button("Tail Laravel Log", systemImage: "text.alignleft") { Task { await model.run("tail -n 250 storage/logs/laravel.log", project: project) } }
                    case .api:
                        Button("Route JSON", systemImage: "network") { Task { await model.run("php artisan route:list --json", project: project) } }
                    case .containers:
                        Button("Open Containers", systemImage: "shippingbox") { store.selectedSection = .containers }
                    case .upgrade:
                        Button("Composer Outdated", systemImage: "arrow.up.circle") { Task { await model.run("composer outdated --direct", project: project) } }
                    case .documentation:
                        Button("Generate Route Reference", systemImage: "doc.badge.gearshape") { Task { await model.run("php artisan route:list", project: project) } }
                    case .architecture, .dashboard, .templates, .metrics, .replay:
                        Button("Open Project", systemImage: "folder") { NSWorkspace.shared.open(URL(fileURLWithPath: project.path)) }
                    }
                    Spacer()
                }
            }
        }
    }

    private func description(for module: ProductStudioModel.Module) -> String {
        switch module {
        case .dashboard: "A single operational view of source, tests, routes, Git and project health."
        case .architecture: "Explore controllers, services, models, jobs, events and application boundaries."
        case .database: "Inspect migrations and open the native database inspector and ERD workspace."
        case .git: "Review repository history and run common Git operations without leaving the project."
        case .deployment: "Discover deployment assets and run repeatable build and optimisation steps."
        case .ai: "Use project-aware AI memory, MCP indexing and source reasoning."
        case .performance: "Inspect runtime configuration, caches, queues and database performance foundations."
        case .security: "Run baseline configuration, dependency and test-readiness checks."
        case .packages: "Inventory Composer dependencies, versions, security and upgrade state."
        case .routes: "Inspect the Laravel route surface and middleware/controller flow."
        case .queues: "Discover queued jobs and operate failed-job workflows."
        case .scheduler: "Inspect and execute Laravel scheduled tasks."
        case .logs: "Discover and inspect application logs from a single place."
        case .api: "Explore API controllers, resources and registered endpoints."
        case .containers: "Discover Docker and Compose assets and open native container tooling."
        case .upgrade: "Assess Laravel and package constraints before framework upgrades."
        case .templates: "Curated blueprints for common Laravel application architectures."
        case .metrics: "Measure source size, classes, methods and test coverage foundations."
        case .documentation: "Inventory project documentation and generate technical references."
        case .replay: "Review project evolution as a chronological development timeline."
        }
    }

    private func icon(for kind: String) -> String {
        switch kind.lowercased() {
        case "model": "cube"
        case "controller": "rectangle.and.hand.point.up.left"
        case "service": "gearshape.2"
        case "event": "bolt.horizontal"
        case "job": "tray.full"
        case "commit", "history": "arrow.triangle.branch"
        case "critical", "high": "exclamationmark.shield"
        case "route": "signpost.right"
        case "migration": "cylinder"
        case "documentation": "doc.richtext"
        default: "doc.text"
        }
    }
}
