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
        workflows = loadJSON([WorkspaceWorkflow].self, at: workflowsURL()) ?? Self.defaultWorkflows
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
        findings = await Task.detached { Self.audit(path: project.path) }.value
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
            workflowOutput += "\n$ \(command)\n"
            let result = await Task.detached { Self.runShell(command, cwd: project.path) }.value
            workflowOutput += result.output
            if result.status != 0 { workflowOutput += "\nStopped with exit code \(result.status).\n"; break }
        }
        isBusy = false; status = "Workflow finished"
    }

    func saveWorkflows() { saveJSON(workflows, at: workflowsURL()) }

    private static var defaultWorkflows: [WorkspaceWorkflow] {[
        WorkspaceWorkflow(name: "Laravel Refresh", commands: ["git pull --ff-only", "composer install", "php artisan migrate --force", "npm install", "npm run build", "php artisan test"]),
        WorkspaceWorkflow(name: "Swift Verify", commands: ["git pull --ff-only", "swift package resolve", "swift test", "swift build"]),
        WorkspaceWorkflow(name: "Quick Test", commands: ["php artisan test || swift test"])
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

    nonisolated private static func audit(path: String) -> [ProjectAuditFinding] {
        let root = URL(fileURLWithPath: path)
        var f: [ProjectAuditFinding] = []
        func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(p).path) }
        func text(_ p: String) -> String { (try? String(contentsOf: root.appendingPathComponent(p), encoding: .utf8)) ?? "" }
        if exists("composer.json") {
            if !exists("composer.lock") { f.append(.init(severity: .high, title: "Composer lock file missing", detail: "Reproducible dependency installation cannot be guaranteed.", path: "composer.lock")) }
            let env = text(".env")
            if env.contains("APP_DEBUG=true") { f.append(.init(severity: .high, title: "Application debug enabled", detail: "Disable APP_DEBUG outside local development.", path: ".env")) }
            if env.contains("APP_ENV=production") && env.contains("APP_DEBUG=true") { f.append(.init(severity: .critical, title: "Production debug exposure", detail: "Production is configured with debug output enabled.", path: ".env")) }
            if !exists("tests") && !exists("Tests") { f.append(.init(severity: .medium, title: "No test directory detected", detail: "Add automated coverage for critical application behaviour.", path: nil)) }
            if exists("package.json") && !exists("package-lock.json") && !exists("pnpm-lock.yaml") && !exists("yarn.lock") { f.append(.init(severity: .medium, title: "Frontend lock file missing", detail: "Commit a package-manager lock file.", path: "package.json")) }
            let audit = runShell("composer audit --no-interaction", cwd: path)
            if audit.status != 0 { f.append(.init(severity: .high, title: "Composer security audit failed", detail: String(audit.output.prefix(1500)), path: "composer.lock")) }
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
            let command = "rg -n -i --hidden --glob '!vendor/**' --glob '!node_modules/**' --glob '!.git/**' --glob '!DerivedData/**' --max-count 30 '\(escaped)' ."
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

    nonisolated private static func runShell(_ command: String, cwd: String) -> (status: Int32, output: String) {
        let p = Process(); let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
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
    enum Tab: String, CaseIterable, Identifiable { case memory = "AI Memory", graph = "Knowledge Graph", entities = "Entity Diagrams", timeline = "Timeline", audit = "Health Audit", mcp = "MCP Hub", automation = "Automation", search = "Cross-Project Search"; var id: String { rawValue } }
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
            Group { switch tab { case .memory: memoryView; case .graph: graphView; case .entities: EntityDiagramWorkspaceView(project: store.selectedProject); case .timeline: timelineView; case .audit: auditView; case .mcp: mcpView; case .automation: automationView; case .search: searchView } }
        }
        .task(id: store.selectedProjectID) { model.load(project: store.selectedProject) }
    }

    private var memoryView: some View { ScrollView { VStack(alignment: .leading, spacing: 16) { GroupBox("Add project memory") { VStack(alignment: .leading) { HStack { Picker("Category", selection: $memoryCategory) { ForEach(["Architecture","Convention","Coding Standard","Decision","Known Issue"], id: \.self) { Text($0) } }.frame(width: 190); TextField("Title", text: $memoryTitle) }; TextEditor(text: $memoryDetail).frame(minHeight: 80); HStack { Spacer(); Button("Remember", systemImage: "brain.head.profile") { guard let p = store.selectedProject, !memoryTitle.isEmpty else { return }; model.addMemory(project: p, category: memoryCategory, title: memoryTitle, detail: memoryDetail); memoryTitle=""; memoryDetail="" } } } }.padding(.bottom, 8); ForEach(model.memories) { item in GroupBox { HStack(alignment: .top) { VStack(alignment: .leading, spacing: 5) { Text(item.category.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary); Text(item.title).font(.headline); Text(item.detail).textSelection(.enabled) }; Spacer(); Button(role: .destructive) { if let p=store.selectedProject { model.deleteMemory(project:p,id:item.id) } } label: { Image(systemName:"trash") }.buttonStyle(.borderless) } } } }.padding(24) } }

    private var graphView: some View { VStack { HStack { Text("\(model.graphSymbols.count) symbols · \(model.graphEdges.count) dependencies").foregroundStyle(.secondary); Spacer(); Button("Rebuild Graph", systemImage:"arrow.clockwise") { if let p=store.selectedProject { Task { await model.refreshGraph(project:p) } } } }.padding(); Table(model.graphSymbols) { TableColumn("Kind", value:\.kind); TableColumn("Symbol", value:\.name); TableColumn("File", value:\.path); TableColumn("Line") { Text("\($0.line)") } } } }
    private var timelineView: some View { VStack { HStack { Spacer(); Button("Refresh", systemImage:"arrow.clockwise") { if let p=store.selectedProject { Task { await model.refreshTimeline(project:p) } } } }.padding(); List(model.timeline) { e in HStack(alignment:.top) { Text(e.date, style:.date).frame(width:100,alignment:.leading); VStack(alignment:.leading) { Text(e.title).font(.headline); Text("\(e.kind) · \(e.detail)").font(.caption).foregroundStyle(.secondary) } } } } }
    private var auditView: some View { VStack { HStack { Text("Laravel, Swift, dependency, environment, testing, and repository checks.").foregroundStyle(.secondary); Spacer(); Button("Run Full Audit", systemImage:"stethoscope") { if let p=store.selectedProject { Task { await model.runAudit(project:p) } } }.buttonStyle(.borderedProminent) }.padding(); List(model.findings) { f in VStack(alignment:.leading,spacing:5) { HStack { Text(f.severity.rawValue.uppercased()).font(.caption.bold()); Text(f.title).font(.headline); Spacer(); if let path=f.path { Text(path).font(.caption.monospaced()).foregroundStyle(.secondary) } }; Text(f.detail).foregroundStyle(.secondary).textSelection(.enabled) } } } }
    private var mcpView: some View { ScrollView { VStack(alignment:.leading,spacing:18) { ContentUnavailableView("Native MCP Hub is active", systemImage:"server.rack", description:Text("The embedded server already synchronises navigator projects, maintains per-project indexes, exposes project-aware search and reasoning tools, and records diagnostics.")); GroupBox("Workspace tools") { Text("projects_list · ask_project · project_search · semantic_search · find_definition · find_references · project_dependency_graph · project_git_status · run_project_tests").font(.body.monospaced()).textSelection(.enabled) }; Button("Open MCP Tools", systemImage:"network") { store.selectedSection = .mcp } }.padding(24) } }
    private var automationView: some View { HSplitView { List(model.workflows, selection: .constant(nil as UUID?)) { w in VStack(alignment:.leading) { Text(w.name).font(.headline); Text(w.commands.joined(separator:" → ")).font(.caption).foregroundStyle(.secondary).lineLimit(2); Button("Run", systemImage:"play.fill") { if let p=store.selectedProject { Task { await model.runWorkflow(w,project:p) } } }.padding(.top,4) } }.frame(minWidth:340); ScrollView { Text(model.workflowOutput.isEmpty ? "Workflow output will appear here." : model.workflowOutput).font(.system(.body,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.topLeading).padding() } } }
    private var searchView: some View { VStack { HStack { TextField("Search classes, routes, migrations, translations, views, endpoints…", text:$query).textFieldStyle(.roundedBorder).onSubmit { Task { await model.search(projects:store.projects,query:query) } }; Button("Search All Projects", systemImage:"magnifyingglass") { Task { await model.search(projects:store.projects,query:query) } }.buttonStyle(.borderedProminent) }.padding(); Table(model.searchResults) { TableColumn("Project",value:\.project).width(min:100,ideal:140); TableColumn("File",value:\.path).width(min:220,ideal:360); TableColumn("Line") { Text("\($0.line)") }.width(55); TableColumn("Match",value:\.excerpt) } } }
}
