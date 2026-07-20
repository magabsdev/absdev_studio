import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import SwiftUI
@preconcurrency import UserNotifications

@MainActor
@Observable
final class AppStore {
    var openWebUI: OpenWebUIController
    var lmStudio: LMStudioController
    var aiProviders: AIProviderRegistry
    var projects: [LaravelProject] = []
    var selectedProjectID: LaravelProject.ID? {
        didSet {
            guard selectedProjectID != oldValue else { return }
            handleProjectSelectionChange()
        }
    }
    var selectedSection: AppSection = .overview
    var isCommandPalettePresented = false
    var sectionSearchQuery = ""
    var commandPaletteQuery = ""
    var sectionNavigationOrder: [String] = AppSection.allCases.map(\.id)
    var commandOutput: [String] = ["ABSDEV Studio ready."]
    var processes: [DevProcess] = [
        DevProcess(name: "Laravel Server", detail: "php artisan serve", symbol: "server.rack", command: "php artisan serve", isRunning: false, output: []),
        DevProcess(name: "Vite", detail: "npm run dev", symbol: "bolt", command: "npm run dev", isRunning: false, output: []),
        DevProcess(name: "Production Build", detail: "npm run build", symbol: "hammer", command: "npm run build", isRunning: false, output: []),
        DevProcess(name: "Queue Worker", detail: "php artisan queue:work", symbol: "tray.full", command: "php artisan queue:work --tries=1", isRunning: false, output: []),
        DevProcess(name: "Scheduler", detail: "php artisan schedule:work", symbol: "clock.arrow.circlepath", command: "php artisan schedule:work", isRunning: false, output: [])
    ]
    var environmentEntries: [EnvironmentEntry] = []
    var isEnvironmentComparisonPresented = false
    var environmentExampleContent = ""
    var environmentCurrentContent = ""
    var diagnostics: [DiagnosticItem] = []
    var isRunningDiagnostics = false
    var diagnosticsLastRun: Date?
    var routes: [RouteItem] = []
    var databaseTables: [DatabaseTableInfo] = []
    var selectedDatabaseTableName: String?
    var databaseColumns: [DatabaseColumnInfo] = []
    var databaseIndexes: [DatabaseIndexInfo] = []
    var databaseForeignKeys: [DatabaseForeignKeyInfo] = []
    var isLoadingDatabaseSchema = false
    var databaseSchemaMessage = "Schema has not been loaded yet."
    var logLines: [String] = []
    var isTailingLogs = false
    var currentLogFileName = "No log selected"
    var isBusy = false
    var isCommandProgressPresented = false
    var commandProgressTitle = "Running Command"
    var commandProgressCommand = ""
    var commandProgressDetail = "Preparing…"
    var commandProgressStartedAt: Date?
    var statusMessage = "Ready"
    var phpStatus = "Not checked"
    var testFailureReport: TestFailureReport?
    var artisanCommands: [ArtisanCommand] = []
    var isLoadingArtisanCommands = false
    var artisanDiscoveryMessage = "Commands have not been scanned yet."
    var isInteractiveArtisanSession = false
    var isInteractiveArtisanTerminalVisible = false
    var interactiveArtisanExecutable = "/bin/zsh"
    var interactiveArtisanArguments: [String] = []
    var interactiveArtisanDirectory = ""
    var interactiveArtisanEnvironment: [String] = []
    var interactiveArtisanSessionID = UUID()
    @ObservationIgnored private var interactiveArtisanReturnSectionOnExit: AppSection?
    var sailCommands: [SailCommand] = []
    var isSailInstalled = false
    var isSailRunning = false
    var isDockerRunning = false
    var isAppleContainerRunning = false
    var sailVersion = "Not installed"
    var sailDiscoveryMessage = "Laravel Sail is not installed in this project."
    var sailInput = ""
    var projectCapabilities: [ProjectCapability] = []
    var capabilitySnapshot: ProjectCapabilitiesSnapshot = .empty
    var isPackageOperationPresented = false
    var packageOperationTitle = "Package operation"
    var packageOperationDetail = "Preparing Composer…"
    var packageOperationOutput: [String] = []
    var packageOperationIsRunning = false
    var packageOperationSucceeded: Bool?
    var isServBayInstalled = false
    var isServBayBusy = false
    var servBayServices: [ServBayService] = []
    var servBayOutput: [String] = []
    var systemLoadHistory: [SystemLoadSample] = []
    var systemCPUPercent = 0.0
    var systemMemoryPercent = 0.0
    var systemStoragePercent = 0.0
    var systemMemoryDetail = "Calculating…"
    var systemStorageDetail = "Calculating…"
    var servBayWebsites: [ServBayWebsite] = []
    var servBayPHPVersions: [ServBayRuntimeVersion] = []
    var servBayCertificates: [ServBayCertificate] = []
    var servBayLogFiles: [ServBayLogFile] = []
    var servBaySelectedLogPath: String?
    var servBayLogLines: [String] = []
    var servBayServiceMetrics: [String: ServBayServiceMetrics] = [:]
    var servBayAdvancedLastRefresh: Date?

    var selectedProjectPHPPath: String {
        selectedProject?.phpExecutablePath ?? ""
    }

    var selectedProjectPHPDescription: String {
        guard let project = selectedProject else { return "No project selected" }
        guard let path = project.phpExecutablePath, !path.isEmpty else { return "Automatic detection has not been saved for this project." }
        let source = project.phpDetectionSource ?? "Detected"
        return "\(source): \(path)"
    }

    var phpPath: String {
        didSet { UserDefaults.standard.set(phpPath, forKey: "phpPath") }
    }
    var editor: String {
        didSet { UserDefaults.standard.set(editor, forKey: "editor") }
    }
    var terminal: String {
        didSet { UserDefaults.standard.set(terminal, forKey: "terminal") }
    }
    var aiFeaturesEnabled: Bool {
        didSet {
            defaults.set(aiFeaturesEnabled, forKey: "aiFeaturesEnabled")
            guard !aiFeaturesEnabled else { return }
            openWebUI.cancelGeneration()
            lmStudio.cancelGeneration()
            if selectedSection == .aiWorkspace || selectedSection == .openWebUI || selectedSection == .lmStudio || selectedSection == .mcp {
                selectedSection = .overview
            }
        }
    }

    @ObservationIgnored private var runningProcesses: [UUID: Process] = [:]
    @ObservationIgnored private var activeForegroundCommand: Process?
    @ObservationIgnored private var foregroundCommandStartedAt: Date?
    @ObservationIgnored private var processPipes: [UUID: [Pipe]] = [:]
    @ObservationIgnored private var commandRunOutput: [UUID: [String]] = [:]
    @ObservationIgnored private var testCommandRuns: Set<UUID> = []
    @ObservationIgnored private var logTailTask: Task<Void, Never>?
    @ObservationIgnored private let projectsStorageURL: URL
    @ObservationIgnored private let performsStartupDiscovery: Bool
    @ObservationIgnored private let defaults: UserDefaults

    init(
        projectsStorageURL: URL? = nil,
        performsStartupDiscovery: Bool = true,
        defaults: UserDefaults = .standard
    ) {
        let openWebUI = OpenWebUIController()
        let lmStudio = LMStudioController()
        self.openWebUI = openWebUI
        self.lmStudio = lmStudio
        self.aiProviders = AIProviderRegistry(lmStudio: lmStudio, openWebUI: openWebUI)
        self.projectsStorageURL = projectsStorageURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ABSDEVStudio/projects.json")
        self.performsStartupDiscovery = performsStartupDiscovery
        self.defaults = defaults
        let savedSectionOrder = defaults.stringArray(forKey: "sectionNavigationOrder") ?? []
        let knownSectionIDs = Set(AppSection.allCases.map(\.id))
        let validSectionOrder = savedSectionOrder.filter { knownSectionIDs.contains($0) }
        let missingSectionIDs = AppSection.allCases.map(\.id).filter { !validSectionOrder.contains($0) }
        sectionNavigationOrder = validSectionOrder + missingSectionIDs
        phpPath = defaults.string(forKey: "phpPath") ?? ""
        editor = defaults.string(forKey: "editor") ?? "Xcode"
        terminal = defaults.string(forKey: "terminal") ?? "Terminal"
        aiFeaturesEnabled = defaults.object(forKey: "aiFeaturesEnabled") as? Bool ?? false

        if performsStartupDiscovery {
            detectServBay()
            Task { await refreshContainerRuntimeAvailability() }
        }
        loadProjects()
        if projects.isEmpty { projects = [.sample] }
        selectedProjectID = projects.first?.id
        openWebUI.activeProject = selectedProject
        lmStudio.activeProject = selectedProject
        openWebUI.mcp.embeddedServer.setActiveNavigatorProject(selectedProject)
        if performsStartupDiscovery {
            Task { await refreshProject() }
        }
    }

    private func handleProjectSelectionChange() {
        stopAllProcesses()
        resetProjectScopedState()

        openWebUI.activeProject = selectedProject
        lmStudio.activeProject = selectedProject
        openWebUI.mcp.embeddedServer.setActiveNavigatorProject(selectedProject)

        guard selectedProject != nil else {
            statusMessage = "No project selected"
            return
        }

        // Populate .env-backed screens immediately, then perform the slower
        // runtime inspection asynchronously.
        loadEnvironment()
        loadLogs()
        statusMessage = "Loading project…"
        Task { await refreshProject() }
    }

    private func resetProjectScopedState() {
        environmentEntries = []
        isEnvironmentComparisonPresented = false
        environmentExampleContent = ""
        environmentCurrentContent = ""
        diagnostics = []
        diagnosticsLastRun = nil
        routes = []
        databaseTables = []
        selectedDatabaseTableName = nil
        databaseColumns = []
        databaseIndexes = []
        databaseForeignKeys = []
        databaseSchemaMessage = "Schema has not been loaded yet."
        stopLogTail()
        logLines = []
        currentLogFileName = "No log selected"
        commandOutput = ["ABSDEV Studio ready."]
        artisanCommands = []
        artisanDiscoveryMessage = "Commands have not been scanned yet."
        sailCommands = []
        isSailInstalled = false
        isSailRunning = false
        sailVersion = "Not installed"
        sailDiscoveryMessage = "Laravel Sail is not installed in this project."
        projectCapabilities = []
        capabilitySnapshot = .empty
        isPackageOperationPresented = false
        packageOperationTitle = "Package operation"
        packageOperationDetail = "Preparing Composer…"
        packageOperationOutput = []
        packageOperationIsRunning = false
        packageOperationSucceeded = nil
        stopInteractiveArtisanSession()
        isRunningDiagnostics = false
        isBusy = false

        for index in processes.indices {
            processes[index].isRunning = false
            processes[index].output = []
        }
    }

    var selectedProject: LaravelProject? {
        projects.first { $0.id == selectedProjectID }
    }

    var isDevelopmentRunning: Bool { processes.contains(where: \.isRunning) }

    var availableSections: [AppSection] {
        let visible = AppSection.allCases.filter { section in
            switch section {
            case .sail: isSailRunning
            case .servBay: isServBayInstalled
            case .containers: isDockerRunning || isAppleContainerRunning
            case .realtime: projectContainsAnyPackage(["laravel/reverb"])
            case .observability: projectContainsAnyPackage(["laravel/pulse", "laravel/telescope", "laravel/horizon", "laravel/octane", "barryvdh/laravel-debugbar"])
            case .featureFlags: projectContainsAnyPackage(["laravel/pennant"])
            case .aiInspector: aiFeaturesEnabled && projectContainsAnyPackage(["laravel/ai"])
            case .aiWorkspace: aiFeaturesEnabled
            case .mcp: true
            case .openWebUI, .lmStudio: false
            case .frontend: projectPathExists("package.json")
            case .events: projectHasArtisanCommand("event:list") || projectDirectoryContainsFiles("app/Events") || projectDirectoryContainsFiles("app/Listeners")
            case .models: projectHasArtisanCommand("model:show") || projectDirectoryContainsFiles("app/Models")
            case .testing: projectPathExists("phpunit.xml") || projectPathExists("phpunit.xml.dist") || projectContainsAnyPackage(["pestphp/pest", "phpunit/phpunit", "laravel/dusk"])
            case .apiCentre: projectPathExists("routes/api.php") || projectContainsAnyPackage(["laravel/sanctum", "laravel/passport"])
            case .mailPreview: projectDirectoryContainsFiles("app/Mail") || projectDirectoryContainsFiles("app/Notifications")
            case .storage: projectPathExists("config/filesystems.php")
            case .services: projectPathExists("config/cache.php") || projectPathExists("config/queue.php") || projectPathExists("config/services.php")
            default: true
            }
        }
        let savedOrder = sectionNavigationOrder
        return visible.sorted { lhs, rhs in
            let left = savedOrder.firstIndex(of: lhs.id) ?? Int.max
            let right = savedOrder.firstIndex(of: rhs.id) ?? Int.max
            if left == right {
                return AppSection.allCases.firstIndex(of: lhs)! < AppSection.allCases.firstIndex(of: rhs)!
            }
            return left < right
        }
    }

    func projectContainsAnyPackage(_ packageNames: [String]) -> Bool {
        capabilitySnapshot.hasAnyPackage(packageNames)
    }

    func projectContainsPackage(_ packageName: String) -> Bool {
        capabilitySnapshot.hasPackage(packageName)
    }

    func projectHasArtisanCommand(_ commandName: String) -> Bool {
        capabilitySnapshot.hasCommand(commandName)
    }

    func projectPathExists(_ relativePath: String) -> Bool {
        capabilitySnapshot.hasPath(relativePath)
    }

    func projectDirectoryContainsFiles(_ relativePath: String) -> Bool {
        if capabilitySnapshot.hasFiles(in: relativePath) { return true }
        guard let project = selectedProject else { return false }
        let url = URL(fileURLWithPath: project.path).appendingPathComponent(relativePath)
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return false }
        while let item = enumerator.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return true
            }
        }
        return false
    }

    var commandPaletteItems: [CommandPaletteItem] {
        var items = availableSections.map { section in
            CommandPaletteItem(
                id: "section:\(section.id)",
                title: section.rawValue,
                subtitle: "Open \(section.rawValue)",
                symbol: section.symbol,
                keywords: [section.rawValue, "section", "navigate"],
                kind: .section(section)
            )
        }

        items += [
            CommandPaletteItem(id: "action:add-project", title: "Add Laravel Project", subtitle: "Choose another Laravel project", symbol: "plus.circle.fill", keywords: ["open", "project", "folder"], kind: .action("add-project")),
            CommandPaletteItem(id: "action:browser", title: "Open Project in Browser", subtitle: selectedProject?.appURL ?? "Project application URL", symbol: "safari.fill", keywords: ["url", "website", "browser"], kind: .action("browser")),
            CommandPaletteItem(id: "action:finder", title: "Reveal Project in Finder", subtitle: selectedProject?.path ?? "Project folder", symbol: "folder.fill", keywords: ["folder", "files", "reveal"], kind: .action("finder")),
            CommandPaletteItem(id: "action:quick-look", title: "Quick Look Project", subtitle: "Preview README or composer.json", symbol: "eye.fill", keywords: ["preview", "readme", "composer"], kind: .action("quick-look")),
            CommandPaletteItem(id: "action:editor", title: "Open Project in Editor", subtitle: editor, symbol: "hammer.fill", keywords: ["code", "ide", "editor"], kind: .action("editor")),
            CommandPaletteItem(id: "action:refresh", title: "Refresh Project Capabilities", subtitle: "Rescan installed packages, files and commands", symbol: "arrow.clockwise", keywords: ["scan", "reload", "capabilities"], kind: .action("refresh"))
        ]

        items += artisanCommands.prefix(250).map { command in
            CommandPaletteItem(
                id: "artisan:\(command.name)",
                title: command.name,
                subtitle: command.description.isEmpty ? "Run Artisan command" : command.description,
                symbol: "terminal.fill",
                keywords: ["artisan", command.namespace] + command.aliases,
                kind: .artisan(command.name)
            )
        }
        return items
    }

    var filteredCommandPaletteItems: [CommandPaletteItem] {
        let query = commandPaletteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Array(commandPaletteItems.prefix(80)) }
        let terms = query.lowercased().split(separator: " ").map(String.init)
        return commandPaletteItems.filter { item in
            let haystack = ([item.title, item.subtitle] + item.keywords).joined(separator: " ").lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }.prefix(80).map { $0 }
    }

    func presentCommandPalette() {
        commandPaletteQuery = ""
        isCommandPalettePresented = true
    }

    func executePaletteItem(_ item: CommandPaletteItem) {
        isCommandPalettePresented = false
        switch item.kind {
        case .section(let section):
            withAnimation(.easeInOut(duration: 0.18)) { selectedSection = section }
        case .artisan(let command):
            selectedSection = .development
            runArtisan(command)
        case .action(let action):
            switch action {
            case "add-project": addProject()
            case "browser": openBrowser()
            case "finder": revealInFinder()
            case "quick-look": quickLookProject()
            case "editor": openInEditor()
            case "refresh": refreshProjectCapabilities()
            default: break
            }
        }
    }

    func quickLookProject() {
        guard let project = selectedProject else { return }
        let base = URL(fileURLWithPath: project.path)
        let candidates = ["README.md", "composer.json", "artisan"].map { base.appendingPathComponent($0) }
        let target = candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? base
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", target.path]
        try? process.run()
    }

    func copyProjectPath() {
        guard let path = selectedProject?.path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        statusMessage = "Project path copied"
    }

    private func postCompletionNotification(title: String, body: String) {
        guard !NSApp.isActive else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    func renameProject(_ projectID: LaravelProject.ID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }

        let alert = NSAlert()
        alert.messageText = "Rename Project"
        alert.informativeText = "This changes only the project alias shown in ABSDEV Studio. The folder on disk will not be renamed."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(string: projects[index].name)
        field.placeholderString = "Project alias"
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let alias = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty else {
            showAlert(title: "Project name required", message: "Enter a project alias before saving.")
            return
        }

        projects[index].name = alias
        saveProjects()
        statusMessage = "Renamed project to \(alias)"
    }

    func moveProject(_ projectID: LaravelProject.ID, before targetID: LaravelProject.ID) {
        guard projectID != targetID,
              let sourceIndex = projects.firstIndex(where: { $0.id == projectID }),
              let targetIndex = projects.firstIndex(where: { $0.id == targetID }) else { return }
        let project = projects.remove(at: sourceIndex)
        let destination = min(targetIndex, projects.count)
        projects.insert(project, at: destination)
        saveProjects()
    }

    func moveProjectToEnd(_ projectID: LaravelProject.ID) {
        guard let sourceIndex = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let project = projects.remove(at: sourceIndex)
        projects.append(project)
        saveProjects()
    }

    func moveSection(_ section: AppSection, before target: AppSection) {
        guard section != target else { return }
        var order = sectionNavigationOrder
        guard let sourceIndex = order.firstIndex(of: section.id),
              let targetIndex = order.firstIndex(of: target.id) else { return }
        let value = order.remove(at: sourceIndex)
        let destination = min(targetIndex, order.count)
        order.insert(value, at: destination)
        sectionNavigationOrder = order
        defaults.set(order, forKey: "sectionNavigationOrder")
    }

    func moveSectionToEnd(_ section: AppSection) {
        var order = sectionNavigationOrder
        guard let sourceIndex = order.firstIndex(of: section.id) else { return }
        let value = order.remove(at: sourceIndex)
        order.append(value)
        sectionNavigationOrder = order
        defaults.set(order, forKey: "sectionNavigationOrder")
    }

    // MARK: - Container runtimes

    func refreshContainerRuntimeAvailability() async {
        async let dockerRunning = containerRuntimeIsRunning(
            candidates: [
                "/opt/homebrew/bin/docker",
                "/usr/local/bin/docker",
                "/Applications/Docker.app/Contents/Resources/bin/docker"
            ],
            arguments: "info"
        )
        async let appleContainerRunning = containerRuntimeIsRunning(
            candidates: [
                "/opt/homebrew/bin/container",
                "/usr/local/bin/container"
            ],
            arguments: "system status"
        )

        isDockerRunning = await dockerRunning
        isAppleContainerRunning = await appleContainerRunning

        if selectedSection == .containers, !isDockerRunning, !isAppleContainerRunning {
            selectedSection = .overview
        }
    }

    private func containerRuntimeIsRunning(candidates: [String], arguments: String) async -> Bool {
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            return false
        }
        let result = await captureResult(
            "\(shellQuote(executable)) \(arguments) >/dev/null 2>&1",
            in: FileManager.default.homeDirectoryForCurrentUser.path
        )
        return result.succeeded
    }

    // MARK: - ServBay

    func detectServBay() {
        let applicationPath = "/Applications/ServBay.app"
        let installationPath = "/Applications/ServBay"
        let cliPath = "\(installationPath)/script/servbayctl"
        isServBayInstalled = FileManager.default.fileExists(atPath: applicationPath)
            || FileManager.default.fileExists(atPath: installationPath)
            || FileManager.default.isExecutableFile(atPath: cliPath)

        guard isServBayInstalled else {
            servBayServices = []
            if selectedSection == .servBay { selectedSection = .overview }
            return
        }

        servBayServices = detectedServBayServices().map { definition in
            ServBayService(id: definition.id, name: definition.name, symbol: definition.symbol, state: .checking, detail: "Waiting for status")
        }
        Task { await refreshServBay() }
    }

    func refreshServBay() async {
        guard isServBayInstalled else { return }
        let cli = "/Applications/ServBay/script/servbayctl"
        guard FileManager.default.isExecutableFile(atPath: cli) else {
            servBayOutput = ["ServBay is installed, but servbayctl was not found at \(cli)."]
            servBayServices = servBayServices.map { service in
                var updated = service
                updated.state = .unavailable
                updated.detail = "servbayctl unavailable"
                return updated
            }
            return
        }

        isServBayBusy = true
        defer { isServBayBusy = false }

        // ServBay's CLI output has changed between releases. Read it, but also
        // inspect the real processes launched from /Applications/ServBay so a
        // running service is never shown as stopped because of wording changes.
        async let processTask = captureResult("/bin/ps -axo pid=,command=", in: "/")
        async let launchTask = captureResult("/bin/launchctl list 2>/dev/null || true", in: "/")
        let (processResult, launchResult) = await (processTask, launchTask)
        let processSnapshot = (processResult.output + "\n" + launchResult.output)
            .removingANSIControlSequences
            .lowercased()

        var refreshed: [ServBayService] = []
        var diagnostics: [String] = []

        for service in servBayServices {
            let result = await captureResult(
                "\(shellQuote(cli)) status \(shellQuote(service.id)) -all",
                in: "/Applications/ServBay"
            )
            let clean = result.output.removingANSIControlSequences.trimmed
            let lines = clean.lines
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let lower = clean.lowercased()

            let runningLines = lines.filter { line in
                let value = line.lowercased()
                return value.contains("running")
                    || value.contains("is running")
                    || value.contains("active (running)")
                    || value.contains("started")
                    || value.contains("is up")
                    || value.contains("online")
            }
            let stoppedLines = lines.filter { line in
                let value = line.lowercased()
                return value.contains("stopped")
                    || value.contains("not running")
                    || value.contains("inactive")
                    || value.contains("is down")
                    || value.contains("offline")
            }

            let matchingProcesses = servBayProcessLines(for: service.id, in: processSnapshot)
            let processIsRunning = !matchingProcesses.isEmpty
            let cliIsRunning = !runningLines.isEmpty
            let cliIsStopped = !stoppedLines.isEmpty
            let cliUnavailable = lower.contains("usage:")
                || lower.contains("not installed")
                || lower.contains("not found")
                || lower.contains("unsupported")
                || lower.contains("unknown package")

            let state: ServBayService.State
            if cliIsRunning || processIsRunning {
                state = .running
            } else if cliIsStopped || (result.succeeded && !cliUnavailable) {
                state = .stopped
            } else {
                state = .unavailable
            }

            var updated = service
            updated.state = state
            switch state {
            case .running:
                if cliIsRunning {
                    updated.detail = runningLines.count == 1
                        ? runningLines[0]
                        : "\(runningLines.count) installed versions running"
                } else {
                    updated.detail = "Running · verified from ServBay process"
                }
            case .stopped:
                updated.detail = stoppedLines.last ?? "Installed but not running"
            case .checking:
                updated.detail = "Checking status"
            case .unavailable:
                updated.detail = lines.last ?? "Status unavailable"
            }
            refreshed.append(updated)

            if state == .unavailable || (state == .stopped && clean.isEmpty) {
                diagnostics.append("\(service.name): CLI exit \(result.exitCode); no matching ServBay process")
            }
        }

        servBayServices = refreshed.filter { $0.state != .unavailable }
        let time = Date().formatted(date: .omitted, time: .standard)
        servBayOutput = ["ServBay service status refreshed at \(time)."]
        if !diagnostics.isEmpty {
            servBayOutput.append(contentsOf: diagnostics)
        }
    }

    private func servBayProcessLines(for serviceID: String, in snapshot: String) -> [String] {
        let lines = snapshot.lines.filter { line in
            line.contains("/applications/servbay/") || line.contains("servbay")
        }

        let signatures: [String: [String]] = [
            "php": ["php-fpm", "/package/php/", "/bin/php-cgi"],
            "mysql": ["/package/mysql/", "/db/mysql/", "mysqld --defaults-file=/applications/servbay/etc/mysql"],
            "mariadb": ["/package/mariadb/", "/db/mariadb/", "mysqld --defaults-file=/applications/servbay/etc/mariadb"],
            "postgresql": ["/package/postgresql/", "/db/postgresql/", "/bin/postgres"],
            "redis": ["redis-server", "/package/redis/"],
            "memcached": ["/bin/memcached", "/package/memcached/"],
            "caddy": ["/bin/caddy", "/package/caddy/"],
            "nginx": ["/bin/nginx", "/package/nginx/"],
            "apache": ["/bin/httpd", "/package/apache/", "org.apache.httpd"],
            "dnsmasq": ["/bin/dnsmasq", "/package/dnsmasq/"],
            "mongodb": ["/bin/mongod", "/package/mongodb/", "/db/mongodb/"],
            "rabbitmq": ["rabbitmq", "beam.smp", "/package/erlang/"],
            "mailpit": ["/bin/mailpit", "/package/mailpit/"],
            "ollama": ["/bin/ollama", "/package/ollama/"]
        ]

        guard let terms = signatures[serviceID] else { return [] }
        return lines.filter { line in terms.contains { line.contains($0) } }
    }

    func performServBayAction(_ action: String, service: ServBayService) {
        guard ["start", "stop", "restart", "reload"].contains(action) else { return }
        Task {
            let cli = "/Applications/ServBay/script/servbayctl"
            isServBayBusy = true
            servBayOutput = ["$ servbayctl \(action) \(service.id) -all"]
            let result = await captureResult("\(shellQuote(cli)) \(shellQuote(action)) \(shellQuote(service.id)) -all", in: "/Applications/ServBay")
            let output = result.output.removingANSIControlSequences.trimmed
            servBayOutput.append(contentsOf: output.lines)
            servBayOutput.append(result.succeeded ? "✓ Command completed." : "✕ Command failed with exit code \(result.exitCode).")
            let transcript = servBayOutput
            isServBayBusy = false
            try? await Task.sleep(for: .milliseconds(700))
            await refreshServBay()
            servBayOutput = transcript
        }
    }

    func sampleSystemLoad() async {
        let snapshot = await Task.detached(priority: .utility) { () -> (Double?, Double?, Double?, String?) in
            func run(_ executable: String, _ arguments: [String]) -> String {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    process.waitUntilExit()
                    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                } catch {
                    return ""
                }
            }

            // The first top sample is cumulative and often reports zero for a
            // newly launched process. The second sample is the useful live value.
            let top = run("/usr/bin/top", ["-l", "2", "-n", "0", "-s", "0.25"])
            let cpuLine = top.components(separatedBy: .newlines).last { $0.localizedCaseInsensitiveContains("CPU usage") } ?? ""
            let idlePattern = #"([0-9]+(?:\.[0-9]+)?)%\s*idle"#
            var cpu: Double?
            if let regex = try? NSRegularExpression(pattern: idlePattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: cpuLine, range: NSRange(cpuLine.startIndex..., in: cpuLine)),
               let range = Range(match.range(at: 1), in: cpuLine),
               let idle = Double(cpuLine[range]) {
                cpu = max(0, min(100, 100 - idle))
            }

            // vm_stat is stable across macOS versions. Treat free, inactive,
            // speculative and purgeable pages as available memory.
            let vm = run("/usr/bin/vm_stat", [])
            let memorySizeText = run("/usr/sbin/sysctl", ["-n", "hw.memsize"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let pageSize: Double = {
                let pattern = #"page size of ([0-9]+) bytes"#
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      let match = regex.firstMatch(in: vm, range: NSRange(vm.startIndex..., in: vm)),
                      let range = Range(match.range(at: 1), in: vm) else { return 4096 }
                return Double(vm[range]) ?? 4096
            }()
            var pages: [String: Double] = [:]
            for line in vm.components(separatedBy: .newlines) {
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let value = parts[1].replacingOccurrences(of: ".", with: "").trimmingCharacters(in: .whitespaces)
                pages[parts[0]] = Double(value)
            }
            var memoryPercent: Double?
            var memoryDetail: String?
            if let totalBytes = Double(memorySizeText), totalBytes > 0 {
                let availablePages = (pages["Pages free"] ?? 0)
                    + (pages["Pages inactive"] ?? 0)
                    + (pages["Pages speculative"] ?? 0)
                    + (pages["Pages purgeable"] ?? 0)
                let usedBytes = max(0, totalBytes - availablePages * pageSize)
                memoryPercent = max(0, min(100, usedBytes / totalBytes * 100))
                memoryDetail = String(format: "%.1f / %.1f GB", usedBytes / 1_073_741_824, totalBytes / 1_073_741_824)
            }

            let storage = run("/bin/df", ["-k", "/"])
            let storageLine = storage.components(separatedBy: .newlines).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("Filesystem") } ?? ""
            let fields = storageLine.split(whereSeparator: \.isWhitespace).map(String.init)
            var storagePercent: Double?
            var storageDetail: String?
            if fields.count >= 5 {
                storagePercent = Double(fields[4].replacingOccurrences(of: "%", with: ""))
                if let totalKB = Double(fields[1]), let usedKB = Double(fields[2]) {
                    storageDetail = String(format: "%.1f / %.1f GB", usedKB / 1_048_576, totalKB / 1_048_576)
                }
            }
            return (cpu, memoryPercent, storagePercent, storageDetail ?? memoryDetail)
        }.value

        if let cpu = snapshot.0 { systemCPUPercent = cpu }
        if let memory = snapshot.1 {
            systemMemoryPercent = memory
            systemMemoryDetail = String(format: "%.1f%% in use", memory)
        }
        if let storage = snapshot.2 { systemStoragePercent = storage }
        if let detail = snapshot.3 { systemStorageDetail = detail }

        systemLoadHistory.append(SystemLoadSample(timestamp: Date(), cpuPercent: systemCPUPercent, memoryPercent: systemMemoryPercent))
        if systemLoadHistory.count > 90 {
            systemLoadHistory.removeFirst(systemLoadHistory.count - 90)
        }
    }

    private func firstPercentage(after label: String, in text: String) -> Double? {
        let pattern = #"([0-9.]+)%\s*"# + NSRegularExpression.escapedPattern(for: label)
        return firstNumber(matching: pattern, in: text)
    }

    private func firstNumber(matching pattern: String, in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[range])
    }

    func openServBay() {
        let appURL = URL(fileURLWithPath: "/Applications/ServBay.app")
        if FileManager.default.fileExists(atPath: appURL.path) {
            NSWorkspace.shared.open(appURL)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/ServBay"))
        }
    }

    func revealServBayLogs() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/ServBay/var/logs"))
    }

    private func detectedServBayServices() -> [(id: String, name: String, symbol: String)] {
        let definitions: [(String, String, String, [String])] = [
            ("php", "PHP", "chevron.left.forwardslash.chevron.right", ["/Applications/ServBay/package/php", "/Applications/ServBay/etc/php"]),
            ("mysql", "MySQL", "cylinder.fill", ["/Applications/ServBay/package/mysql", "/Applications/ServBay/etc/mysql"]),
            ("mariadb", "MariaDB", "cylinder.split.1x2.fill", ["/Applications/ServBay/package/mariadb", "/Applications/ServBay/etc/mariadb"]),
            ("postgresql", "PostgreSQL", "cylinder", ["/Applications/ServBay/package/postgresql", "/Applications/ServBay/etc/postgresql"]),
            ("redis", "Redis", "memorychip.fill", ["/Applications/ServBay/package/redis", "/Applications/ServBay/etc/redis"]),
            ("memcached", "Memcached", "externaldrive.fill", ["/Applications/ServBay/package/memcached", "/Applications/ServBay/etc/memcached"]),
            ("caddy", "Caddy", "shield.lefthalf.filled", ["/Applications/ServBay/package/caddy", "/Applications/ServBay/etc/caddy"]),
            ("nginx", "Nginx", "server.rack", ["/Applications/ServBay/package/nginx", "/Applications/ServBay/etc/nginx"]),
            ("apache", "Apache", "server.rack", ["/Applications/ServBay/package/apache", "/Applications/ServBay/etc/apache"]),
            ("dnsmasq", "DNS", "globe", ["/Applications/ServBay/package/dnsmasq", "/Applications/ServBay/etc/dnsmasq"]),
            ("mongodb", "MongoDB", "leaf.fill", ["/Applications/ServBay/package/mongodb", "/Applications/ServBay/etc/mongodb"]),
            ("rabbitmq", "RabbitMQ", "arrow.left.arrow.right.square.fill", ["/Applications/ServBay/package/rabbitmq", "/Applications/ServBay/etc/rabbitmq"]),
            ("mailpit", "Mailpit", "envelope.fill", ["/Applications/ServBay/package/mailpit"]),
            ("ollama", "Ollama", "brain.head.profile", ["/Applications/ServBay/package/ollama"])
        ]
        return definitions.compactMap { definition in
            definition.3.contains { FileManager.default.fileExists(atPath: $0) }
                ? (definition.0, definition.1, definition.2)
                : nil
        }
    }

    func addProject() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Laravel project"
        panel.message = "Select the folder containing artisan and composer.json."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("artisan").path) else {
            showAlert(title: "Not a Laravel project", message: "The selected folder does not contain an artisan file.")
            return
        }

        let project = LaravelProject(name: url.lastPathComponent, path: url.path, laravelVersion: "Detecting…", phpVersion: "Detecting…", branch: "—", appURL: "http://127.0.0.1:8000", environment: "local")
        if let existing = projects.first(where: { $0.path == project.path }) {
            selectedProjectID = existing.id
        } else {
            projects.append(project)
            selectedProjectID = project.id
            saveProjects()
        }
    }


    func setProjectIcon(projectID: LaravelProject.ID, symbol: String, colorHex: String) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].iconSymbol = symbol
        projects[index].iconColorHex = colorHex
        projects[index].customIconPath = nil
        saveProjects()
    }

    func importProjectIcon(projectID: LaravelProject.ID) {
        let panel = NSOpenPanel()
        panel.title = "Choose a project icon"
        panel.message = "Select an SVG, PNG, JPEG, PDF, TIFF, or ICNS image."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.svg, .png, .jpeg, .pdf, .tiff, UTType(filenameExtension: "icns")].compactMap { $0 }
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }

        do {
            let directory = projectsURL.deletingLastPathComponent().appendingPathComponent("ProjectIcons", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let ext = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension.lowercased()
            let destination = directory.appendingPathComponent("\(projectID.uuidString).\(ext)")

            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)

            guard NSImage(contentsOf: destination) != nil else {
                try? FileManager.default.removeItem(at: destination)
                showAlert(title: "Unsupported icon", message: "The selected image could not be read by macOS.")
                return
            }

            guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
            projects[index].customIconPath = destination.path
            saveProjects()
        } catch {
            showAlert(title: "Could not import icon", message: error.localizedDescription)
        }
    }

    func resetProjectIcon(projectID: LaravelProject.ID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        if let path = projects[index].customIconPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        projects[index].iconSymbol = nil
        projects[index].iconColorHex = nil
        projects[index].customIconPath = nil
        saveProjects()
    }

    func removeSelectedProject() {
        guard let id = selectedProjectID else { return }
        stopAllProcesses()
        projects.removeAll { $0.id == id }
        selectedProjectID = projects.first?.id
        saveProjects()
    }

    func refreshProject() async {
        guard let project = selectedProject else { return }
        let projectID = project.id
        isBusy = true
        statusMessage = "Inspecting \(project.name)…"
        defer { isBusy = false }

        async let runtimeRefresh: Void = refreshContainerRuntimeAvailability()
        let phpExecutable = await resolvePHPExecutable(in: project.path)
        async let branch = capture("git branch --show-current", in: project.path)

        var phpVersion = "Unavailable"
        var laravelVersion = "Unavailable"
        if let phpExecutable {
            let phpResult = await captureResult("\(shellQuote(phpExecutable)) -r 'echo PHP_VERSION;'", in: project.path)
            let laravelResult = await captureResult("\(shellQuote(phpExecutable)) artisan --version", in: project.path)
            if phpResult.succeeded { phpVersion = phpResult.output.trimmed.nonEmpty ?? "Unavailable" }
            if laravelResult.succeeded { laravelVersion = laravelResult.output.replacingOccurrences(of: "Laravel Framework ", with: "").trimmed.nonEmpty ?? "Unavailable" }
        }
        let branchName = await branch
        await runtimeRefresh

        // The user may have selected another project while the commands were
        // running. Never apply stale inspection results to the new selection.
        guard selectedProjectID == projectID else { return }

        if let index = projects.firstIndex(where: { $0.id == projectID }) {
            projects[index].phpVersion = phpVersion
            projects[index].laravelVersion = laravelVersion
            projects[index].branch = branchName.trimmed.nonEmpty ?? "No branch"
            loadEnvironment()
            projects[index].environment = value(for: "APP_ENV") ?? "local"
            projects[index].appURL = value(for: "APP_URL") ?? "http://127.0.0.1:8000"
            saveProjects()
        }
        if phpExecutable != nil {
            await refreshArtisanCommands()
            await refreshSailCommands()
            await refreshRoutes()
        } else {
            artisanCommands = []
            artisanDiscoveryMessage = "PHP is unavailable, so Artisan commands could not be scanned."
            routes = []
        databaseTables = []
        selectedDatabaseTableName = nil
        databaseColumns = []
        databaseIndexes = []
        databaseForeignKeys = []
        databaseSchemaMessage = "Schema has not been loaded yet."
        }
        guard selectedProjectID == projectID else { return }
        rebuildCapabilitySnapshot()
        await runDiagnostics()
        guard selectedProjectID == projectID else { return }
        rebuildCapabilitySnapshot()
        refreshProjectCapabilities()
        loadLogs()
        statusMessage = phpExecutable == nil ? "PHP executable needs attention" : "Project refreshed"
    }

    func toggleDevelopment() {
        isDevelopmentRunning ? stopAllProcesses() : startDefaultProcesses()
    }

    func startDefaultProcesses() {
        for process in processes where process.name != "Scheduler"
            && process.name != "Production Build"
            && (process.name != "Laravel Server" || shouldShowLaravelDevelopmentServer)
            && !process.isRunning {
            startProcess(process)
        }
    }

    func toggleProcess(_ process: DevProcess) {
        process.isRunning ? stopProcess(process) : startProcess(process)
    }

    func startProcess(_ process: DevProcess) {
        guard let project = selectedProject, runningProcesses[process.id] == nil else { return }
        if process.command.hasPrefix("php "), phpPath.isEmpty {
            showAlert(title: "PHP is not configured", message: "Open Settings and choose or detect a working PHP executable.")
            return
        }
        let task = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let command = resolvedProcessCommand(process.command)
        task.arguments = ["-lc", command]
        task.currentDirectoryURL = URL(fileURLWithPath: project.path)
        task.environment = commandEnvironment()
        task.standardOutput = stdout
        task.standardError = stderr

        let processID = process.id
        let receive: @Sendable (FileHandle) -> Void = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.appendProcessOutput(processID, text: text)
            }
        }
        stdout.fileHandleForReading.readabilityHandler = receive
        stderr.fileHandleForReading.readabilityHandler = receive
        task.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.processDidTerminate(processID)
            }
        }

        do {
            try task.run()
            runningProcesses[process.id] = task
            processPipes[process.id] = [stdout, stderr]
            setProcess(process.id, running: true)
            appendProcessOutput(process.id, text: "$ \(command)\n")
            statusMessage = "Started \(process.name)"
        } catch {
            showAlert(title: "Unable to start \(process.name)", message: error.localizedDescription)
        }
    }

    func stopProcess(_ process: DevProcess) {
        runningProcesses[process.id]?.terminate()
        runningProcesses[process.id] = nil
        processPipes[process.id] = nil
        setProcess(process.id, running: false)
        appendProcessOutput(process.id, text: "Process stopped.\n")
        statusMessage = "Stopped \(process.name)"
    }

    func stopAllProcesses() {
        for process in processes where process.isRunning { stopProcess(process) }
    }

    private func directDatabaseConfiguration(for project: LaravelProject) -> [String: String] {
        let values = projectEnvironment(at: project.path)
        let connection = values["DB_CONNECTION"]?.trimmed.nonEmpty ?? "mysql"
        var database = values["DB_DATABASE"]?.trimmed ?? ""
        if connection == "sqlite", !database.isEmpty, database != ":memory:", !database.hasPrefix("/") {
            database = URL(fileURLWithPath: project.path).appendingPathComponent(database).standardizedFileURL.path
        }
        return [
            "connection": connection,
            "host": values["DB_HOST"]?.trimmed.nonEmpty ?? "127.0.0.1",
            "port": values["DB_PORT"]?.trimmed ?? "",
            "database": database,
            "username": values["DB_USERNAME"]?.trimmed ?? "",
            "password": values["DB_PASSWORD"] ?? "",
            "charset": values["DB_CHARSET"]?.trimmed.nonEmpty ?? "utf8mb4"
        ]
    }

    private func directDatabaseCommand(
        php: String,
        project: LaravelProject,
        operation: String,
        table: String? = nil
    ) -> String? {
        var payload = directDatabaseConfiguration(for: project)
        payload["operation"] = operation
        if let table { payload["table"] = table }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return nil }
        let config = Data(json.utf8).base64EncodedString()

        let script = #"""
        $cfg = json_decode(base64_decode(getenv('ABSDEV_DB_CONFIG')), true, 512, JSON_THROW_ON_ERROR);
        $driver = strtolower((string)($cfg['connection'] ?? 'mysql'));
        $database = (string)($cfg['database'] ?? '');
        $host = (string)($cfg['host'] ?? '127.0.0.1');
        $port = (string)($cfg['port'] ?? '');
        $user = (string)($cfg['username'] ?? '');
        $password = (string)($cfg['password'] ?? '');
        $charset = (string)($cfg['charset'] ?? 'utf8mb4');
        $operation = (string)($cfg['operation'] ?? 'tables');
        $table = (string)($cfg['table'] ?? '');

        if ($driver === 'sqlite') {
            $dsn = 'sqlite:' . $database;
        } elseif ($driver === 'pgsql' || $driver === 'postgres' || $driver === 'postgresql') {
            $dsn = 'pgsql:host=' . $host . ($port !== '' ? ';port=' . $port : '') . ';dbname=' . $database;
        } elseif ($driver === 'sqlsrv') {
            $dsn = 'sqlsrv:Server=' . $host . ($port !== '' ? ',' . $port : '') . ';Database=' . $database;
        } else {
            $dsn = 'mysql:host=' . $host . ($port !== '' ? ';port=' . $port : '') . ';dbname=' . $database . ';charset=' . $charset;
        }

        $pdo = new PDO($dsn, $user, $password, [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES => false,
        ]);

        if ($operation === 'identity') {
            $actual = $database;
            if ($driver === 'mysql' || $driver === 'mariadb') {
                $actual = (string)$pdo->query('SELECT DATABASE()')->fetchColumn();
            } elseif ($driver === 'pgsql' || $driver === 'postgres' || $driver === 'postgresql') {
                $actual = (string)$pdo->query('SELECT current_database()')->fetchColumn();
            } elseif ($driver === 'sqlsrv') {
                $actual = (string)$pdo->query('SELECT DB_NAME()')->fetchColumn();
            }
            echo json_encode(['connection' => $driver, 'database' => $actual], JSON_THROW_ON_ERROR);
            exit;
        }

        if ($operation === 'tables') {
            if ($driver === 'sqlite') {
                $rows = $pdo->query("SELECT name, '' AS size, '' AS rows FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")->fetchAll();
            } elseif ($driver === 'pgsql' || $driver === 'postgres' || $driver === 'postgresql') {
                $statement = $pdo->prepare("SELECT tablename AS name, '' AS size, '' AS rows FROM pg_catalog.pg_tables WHERE schemaname = current_schema() ORDER BY tablename");
                $statement->execute();
                $rows = $statement->fetchAll();
            } elseif ($driver === 'sqlsrv') {
                $rows = $pdo->query("SELECT TABLE_NAME AS name, '' AS size, '' AS rows FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE='BASE TABLE' AND TABLE_CATALOG=DB_NAME() ORDER BY TABLE_NAME")->fetchAll();
            } else {
                $statement = $pdo->prepare("SELECT TABLE_NAME AS name, COALESCE(TABLE_ROWS, 0) AS rows, CONCAT(ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2), ' MB') AS size FROM information_schema.TABLES WHERE TABLE_SCHEMA = :database ORDER BY TABLE_NAME");
                $statement->execute(['database' => $database]);
                $rows = $statement->fetchAll();
            }
            echo json_encode(['database' => $database, 'tables' => $rows], JSON_THROW_ON_ERROR);
            exit;
        }

        if ($operation === 'details') {
            if ($table === '') { throw new RuntimeException('No table was selected.'); }
            $columns = []; $indexes = []; $foreignKeys = [];
            if ($driver === 'sqlite') {
                $quoted = str_replace("'", "''", $table);
                foreach ($pdo->query("PRAGMA table_info('$quoted')") as $column) {
                    $columns[] = ['name' => $column['name'], 'type' => $column['type'], 'nullable' => ((int)$column['notnull']) === 0, 'default' => $column['dflt_value'] ?? '', 'extra' => ((int)$column['pk']) === 1 ? 'primary' : ''];
                }
                foreach ($pdo->query("PRAGMA index_list('$quoted')") as $index) {
                    $indexName = (string)$index['name'];
                    $escapedIndex = str_replace("'", "''", $indexName);
                    $indexColumns = array_column($pdo->query("PRAGMA index_info('$escapedIndex')")->fetchAll(), 'name');
                    $indexes[] = ['name' => $indexName, 'columns' => implode(', ', $indexColumns), 'unique' => ((int)$index['unique']) === 1, 'primary' => false];
                }
                foreach ($pdo->query("PRAGMA foreign_key_list('$quoted')") as $fk) {
                    $foreignKeys[] = ['name' => 'fk_' . $table . '_' . $fk['id'], 'columns' => $fk['from'], 'referenced_table' => $fk['table'], 'referenced_columns' => $fk['to']];
                }
            } elseif ($driver === 'mysql' || $driver === 'mariadb') {
                $statement = $pdo->prepare("SELECT COLUMN_NAME AS name, COLUMN_TYPE AS type, IS_NULLABLE AS nullable, COALESCE(COLUMN_DEFAULT, '') AS `default`, EXTRA AS extra FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=:database AND TABLE_NAME=:table ORDER BY ORDINAL_POSITION");
                $statement->execute(['database' => $database, 'table' => $table]);
                foreach ($statement->fetchAll() as $column) { $column['nullable'] = strtoupper((string)$column['nullable']) === 'YES'; $columns[] = $column; }
                $statement = $pdo->prepare("SELECT INDEX_NAME AS name, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ', ') AS columns, MIN(NON_UNIQUE)=0 AS `unique`, INDEX_NAME='PRIMARY' AS `primary` FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=:database AND TABLE_NAME=:table GROUP BY INDEX_NAME ORDER BY INDEX_NAME");
                $statement->execute(['database' => $database, 'table' => $table]);
                $indexes = $statement->fetchAll();
                $statement = $pdo->prepare("SELECT CONSTRAINT_NAME AS name, GROUP_CONCAT(COLUMN_NAME ORDER BY ORDINAL_POSITION SEPARATOR ', ') AS columns, REFERENCED_TABLE_NAME AS referenced_table, GROUP_CONCAT(REFERENCED_COLUMN_NAME ORDER BY ORDINAL_POSITION SEPARATOR ', ') AS referenced_columns FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA=:database AND TABLE_NAME=:table AND REFERENCED_TABLE_NAME IS NOT NULL GROUP BY CONSTRAINT_NAME, REFERENCED_TABLE_NAME ORDER BY CONSTRAINT_NAME");
                $statement->execute(['database' => $database, 'table' => $table]);
                $foreignKeys = $statement->fetchAll();
            } else {
                $statement = $pdo->prepare("SELECT COLUMN_NAME AS name, DATA_TYPE AS type, IS_NULLABLE AS nullable, COALESCE(COLUMN_DEFAULT, '') AS \"default\", '' AS extra FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME=:table ORDER BY ORDINAL_POSITION");
                $statement->execute(['table' => $table]);
                foreach ($statement->fetchAll() as $column) { $column['nullable'] = strtoupper((string)$column['nullable']) === 'YES'; $columns[] = $column; }
            }
            echo json_encode(['columns' => $columns, 'indexes' => $indexes, 'foreign_keys' => $foreignKeys], JSON_THROW_ON_ERROR);
        }
        """#
        let encodedScript = Data(script.utf8).base64EncodedString()
        return "ABSDEV_DB_CONFIG=\(shellQuote(config)) \(shellQuote(php)) -r \(shellQuote("eval(base64_decode('\(encodedScript)'));"))"
    }

    func refreshDatabaseSchema() async {
        guard let project = selectedProject else {
            databaseSchemaMessage = "Select a Laravel project first."
            return
        }
        let projectID = project.id

        databaseTables = []
        selectedDatabaseTableName = nil
        databaseColumns = []
        databaseIndexes = []
        databaseForeignKeys = []
        databaseSchemaMessage = "Connecting directly to the selected project's database…"
        isLoadingDatabaseSchema = true
        defer { if selectedProjectID == projectID { isLoadingDatabaseSchema = false } }

        guard let php = await resolvePHPExecutable(in: project.path), selectedProjectID == projectID else {
            if selectedProjectID == projectID { databaseSchemaMessage = "PHP executable could not be resolved." }
            return
        }
        guard let identityCommand = directDatabaseCommand(php: php, project: project, operation: "identity"),
              let tablesCommand = directDatabaseCommand(php: php, project: project, operation: "tables") else {
            databaseSchemaMessage = "Could not construct a direct database connection."
            return
        }

        let identityResult = await captureResult(identityCommand, in: project.path, environmentProject: project)
        guard selectedProjectID == projectID else { return }
        guard identityResult.succeeded,
              let identityData = identityResult.output.data(using: .utf8),
              let identity = try? JSONSerialization.jsonObject(with: identityData) as? [String: Any] else {
            databaseSchemaMessage = "Direct database connection failed for \(databaseIdentity(for: project)). \(identityResult.output.lines.prefix(4).joined(separator: " ").trimmed)"
            return
        }

        let actualDatabase = stringValue(identity["database"])
        let expectedDatabase = directDatabaseConfiguration(for: project)["database"] ?? ""
        if !expectedDatabase.isEmpty,
           expectedDatabase != ":memory:",
           URL(fileURLWithPath: actualDatabase).lastPathComponent.caseInsensitiveCompare(URL(fileURLWithPath: expectedDatabase).lastPathComponent) != .orderedSame {
            databaseSchemaMessage = "Database mismatch blocked: .env requests \(expectedDatabase), but the direct connection opened \(actualDatabase)."
            return
        }

        let result = await captureResult(tablesCommand, in: project.path, environmentProject: project)
        guard selectedProjectID == projectID else { return }
        guard result.succeeded else {
            databaseSchemaMessage = "Schema listing failed for \(databaseIdentity(for: project)). \(result.output.lines.prefix(4).joined(separator: " ").trimmed)"
            return
        }

        let tables = parseDatabaseTablesJSON(result.output)
        databaseTables = tables.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        databaseSchemaMessage = tables.isEmpty ? "No tables were found in \(databaseIdentity(for: project))." : "\(tables.count) tables loaded directly from \(databaseIdentity(for: project))."
        if let first = databaseTables.first {
            selectedDatabaseTableName = first.name
            await loadDatabaseTableDetails(first.name)
        }
    }

    func selectDatabaseTable(_ name: String) {
        selectedDatabaseTableName = name
        Task { await loadDatabaseTableDetails(name) }
    }

    func loadDatabaseTableDetails(_ name: String) async {
        guard let project = selectedProject else { return }
        let projectID = project.id
        guard let php = await resolvePHPExecutable(in: project.path),
              selectedProjectID == projectID,
              let command = directDatabaseCommand(php: php, project: project, operation: "details", table: name) else { return }
        let result = await captureResult(command, in: project.path, environmentProject: project)
        guard selectedProjectID == projectID, selectedDatabaseTableName == name else { return }
        guard result.succeeded else {
            databaseColumns = []
            databaseIndexes = []
            databaseForeignKeys = []
            databaseSchemaMessage = "Could not inspect \(name): \(result.output.lines.prefix(4).joined(separator: " ").trimmed)"
            return
        }
        parseDatabaseTableDetailsJSON(result.output)
    }

    private func parseDatabaseTablesJSON(_ output: String) -> [DatabaseTableInfo] {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var rows: [[String: Any]] = []
        if let dict = object as? [String: Any] {
            if let value = dict["tables"] as? [[String: Any]] { rows = value }
            else if let value = dict["data"] as? [[String: Any]] { rows = value }
        } else if let value = object as? [[String: Any]] { rows = value }
        return rows.compactMap { row in
            let name = stringValue(row["name"] ?? row["table"] ?? row["table_name"])
            guard !name.isEmpty else { return nil }
            return DatabaseTableInfo(
                name: name,
                size: stringValue(row["size"] ?? row["size_human"] ?? row["total_size"]),
                rows: stringValue(row["rows"] ?? row["row_count"] ?? row["records"])
            )
        }
    }

    private func parseDatabaseTableDetailsJSON(_ output: String) {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            databaseColumns = []; databaseIndexes = []; databaseForeignKeys = []
            return
        }
        let columnRows = (dict["columns"] as? [[String: Any]]) ?? ((dict["data"] as? [String: Any])?["columns"] as? [[String: Any]]) ?? []
        databaseColumns = columnRows.compactMap { row in
            let name = stringValue(row["name"] ?? row["column"])
            guard !name.isEmpty else { return nil }
            return DatabaseColumnInfo(name: name,
                type: stringValue(row["type"] ?? row["type_name"] ?? row["data_type"]),
                nullable: boolValue(row["nullable"] ?? row["null"]),
                defaultValue: stringValue(row["default"] ?? row["default_value"]),
                extra: stringValue(row["extra"] ?? row["comment"] ?? row["collation"]))
        }
        let indexRows = (dict["indexes"] as? [[String: Any]]) ?? ((dict["data"] as? [String: Any])?["indexes"] as? [[String: Any]]) ?? []
        databaseIndexes = indexRows.compactMap { row in
            let name = stringValue(row["name"] ?? row["index"])
            guard !name.isEmpty else { return nil }
            return DatabaseIndexInfo(name: name,
                columns: listValue(row["columns"]),
                unique: boolValue(row["unique"]),
                primary: boolValue(row["primary"] ?? row["is_primary"]))
        }
        let fkRows = (dict["foreign_keys"] as? [[String: Any]]) ?? (dict["foreignKeys"] as? [[String: Any]]) ?? ((dict["data"] as? [String: Any])?["foreign_keys"] as? [[String: Any]]) ?? []
        databaseForeignKeys = fkRows.compactMap { row in
            let columns = listValue(row["columns"] ?? row["column"])
            let table = stringValue(row["foreign_table"] ?? row["referenced_table"] ?? row["table"])
            guard !columns.isEmpty || !table.isEmpty else { return nil }
            return DatabaseForeignKeyInfo(name: stringValue(row["name"] ?? row["constraint"]), columns: columns, referencedTable: table, referencedColumns: listValue(row["foreign_columns"] ?? row["referenced_columns"] ?? row["references"]))
        }
    }

    private func stringValue(_ value: Any?) -> String {
        guard let value else { return "" }
        if value is NSNull { return "" }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return String(describing: value)
    }

    private func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        let string = stringValue(value).lowercased()
        return ["1", "true", "yes", "y"].contains(string)
    }

    private func listValue(_ value: Any?) -> String {
        if let values = value as? [Any] { return values.map { stringValue($0) }.joined(separator: ", ") }
        return stringValue(value)
    }

    func runArtisan(_ command: String) {
        let trimmed = command.trimmed
        guard !trimmed.isEmpty else { return }
        guard let project = selectedProject, FileManager.default.fileExists(atPath: URL(fileURLWithPath: project.path).appendingPathComponent("artisan").path) else {
            showAlert(title: "Artisan is unavailable", message: "The selected project does not contain an artisan entry point.")
            return
        }
        guard !phpPath.isEmpty else {
            showAlert(title: "PHP is not configured", message: "Open Settings and choose a working PHP executable.")
            return
        }

        let commandName = artisanCommandName(from: trimmed)
        if !artisanCommands.isEmpty, !commandName.isEmpty, !artisanCommands.contains(where: { $0.name == commandName || $0.aliases.contains(commandName) }) {
            showAlert(
                title: "Command is not installed",
                message: "The selected project does not currently expose ‘\(commandName)’. Refresh the command list after installing or enabling its package."
            )
            return
        }

        if isInstallArtisanCommand(commandName), !confirmInstallArtisanCommand(trimmed) { return }
        if isDestructiveArtisanCommand(trimmed), !confirmDestructiveArtisanCommand(trimmed) { return }

        // model:show prompts for a model when no argument is supplied. Do not
        // expose that prompt as free-form terminal input: discover the project's
        // Eloquent models and let the user choose one from a native list.
        if commandName == "model:show", artisanArguments(from: trimmed).isEmpty {
            guard let model = chooseEloquentModel() else { return }
            clearConsole()
            runCommand("\(shellQuote(phpPath)) artisan model:show \(shellQuote(model))")
            return
        }

        clearConsole()
        if requiresInteractiveArtisanTerminal(commandName: commandName, input: trimmed) {
            runInteractiveArtisan(trimmed)
        } else {
            // Ordinary commands are more reliable through the normal process
            // runner. A PTY is reserved for commands that actually need raw
            // keyboard input or Laravel Prompts.
            runCommand("\(shellQuote(phpPath)) artisan \(trimmed)")
        }
    }


    func runTinker() {
        guard let project = selectedProject,
              FileManager.default.fileExists(atPath: URL(fileURLWithPath: project.path).appendingPathComponent("artisan").path) else {
            showAlert(title: "Tinker is unavailable", message: "Choose a valid Laravel project first.")
            return
        }
        guard !phpPath.isEmpty else {
            showAlert(title: "PHP is not configured", message: "Open Settings and choose a working PHP executable.")
            return
        }
        // When discovery has completed, respect the selected project's installed command set.
        if !artisanCommands.isEmpty,
           !artisanCommands.contains(where: { $0.name == "tinker" || $0.aliases.contains("tinker") }) {
            // Tinker is intentionally removed from artisanCommands after discovery, so verify through Composer.
            let composer = URL(fileURLWithPath: project.path).appendingPathComponent("composer.lock")
            let lock = (try? String(contentsOf: composer, encoding: .utf8)) ?? ""
            if !lock.contains("laravel/tinker") {
                showAlert(title: "Laravel Tinker is not installed", message: "Install laravel/tinker in the selected project to use this workspace.")
                return
            }
        }
        clearConsole()
        runInteractiveArtisan("tinker", returnSectionOnExit: .overview)
    }


    func runDatabaseConsole() {
        runInteractiveArtisan("db", returnSectionOnExit: .overview)
        statusMessage = "Interactive database console running"
    }

    func runTerminalWorkspace() {
        guard let project = selectedProject else { return }
        stopInteractiveArtisanSession()
        interactiveArtisanReturnSectionOnExit = .overview
        var environment = commandEnvironment()
        environment["TERM"] = environment["TERM"] ?? "xterm-256color"
        environment["COLORTERM"] = environment["COLORTERM"] ?? "truecolor"
        interactiveArtisanExecutable = "/bin/zsh"
        interactiveArtisanArguments = ["-l"]
        interactiveArtisanDirectory = project.path
        interactiveArtisanEnvironment = environment.map { "\($0.key)=\($0.value)" }.sorted()
        interactiveArtisanSessionID = UUID()
        isInteractiveArtisanSession = true
        isInteractiveArtisanTerminalVisible = true
        isBusy = true
        statusMessage = "Terminal session running"
        commandOutput = []
    }

    func rebuildCapabilitySnapshot() {
        guard let project = selectedProject else {
            capabilitySnapshot = .empty
            return
        }

        let root = URL(fileURLWithPath: project.path, isDirectory: true)
        let packageState = composerPackageState(in: project.path)
        let paths = [
            "artisan", "composer.json", "composer.lock", "package.json", "vite.config.js", "vite.config.ts",
            "phpunit.xml", "phpunit.xml.dist", "routes/api.php", "routes/channels.php",
            "config/filesystems.php", "config/cache.php", "config/queue.php", "config/services.php",
            "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml", "vendor/bin/sail"
        ]
        let directories = [
            "app/Models", "app/Events", "app/Listeners", "app/Mail", "app/Notifications",
            "app/Jobs", "app/Http/Controllers", "app/Policies", "app/Observers", "database/factories",
            "tests", "Modules", "modules", "packages"
        ]
        let existingPaths = Set(paths.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) })
        let populatedDirectories = Set(directories.filter { relative in
            let url = root.appendingPathComponent(relative, isDirectory: true)
            guard let values = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return false }
            return !values.isEmpty
        })
        let commands = Set(artisanCommands.flatMap { [$0.name] + $0.aliases })

        var profiles = Set<LaravelProjectProfile>()
        if existingPaths.contains("routes/api.php") || packageState.installed.contains("laravel/sanctum") || packageState.installed.contains("laravel/passport") { profiles.insert(.api) }
        if packageState.installed.contains("livewire/livewire") { profiles.insert(.livewire) }
        if packageState.installed.contains("inertiajs/inertia-laravel") { profiles.insert(.inertia) }
        if populatedDirectories.contains("packages") || packageState.installed.contains("orchestra/testbench") { profiles.insert(.packageDevelopment) }
        if packageState.installed.contains("filament/filament") { profiles.insert(.filament) }
        if populatedDirectories.contains("Modules") || populatedDirectories.contains("modules") || packageState.installed.contains("nwidart/laravel-modules") || packageState.installed.contains("mpba/laravel-modules") { profiles.insert(.modules) }
        if packageState.installed.contains("laravel/octane") || packageState.installed.contains("laravel/reverb") { profiles.insert(.microservice) }
        if existingPaths.contains("vendor/bin/sail") || packageState.installed.contains("laravel/sail") { profiles.insert(.sail) }
        if existingPaths.contains("docker-compose.yml") || existingPaths.contains("docker-compose.yaml") || existingPaths.contains("compose.yml") || existingPaths.contains("compose.yaml") { profiles.insert(.docker) }
        if isServBayInstalled { profiles.insert(.servBay) }

        var health: [String: CapabilityHealth] = [:]
        health["php"] = project.phpVersion == "Unavailable" ? .problem : .ready
        health["laravel"] = project.laravelVersion == "Unavailable" ? .problem : .ready
        health["composer"] = existingPaths.contains("composer.lock") ? .ready : .attention
        health["frontend"] = existingPaths.contains("package.json") ? .ready : .unavailable
        health["database"] = diagnostics.contains(where: { $0.title.localizedCaseInsensitiveContains("database") && $0.status == .error }) ? .problem : .ready
        health["tests"] = (existingPaths.contains("phpunit.xml") || existingPaths.contains("phpunit.xml.dist") || packageState.installed.contains("pestphp/pest")) ? .ready : .unavailable
        health["queue"] = existingPaths.contains("config/queue.php") ? .ready : .unavailable
        health["storage"] = existingPaths.contains("config/filesystems.php") ? .ready : .unavailable

        capabilitySnapshot = ProjectCapabilitiesSnapshot(
            scannedAt: Date(),
            packages: packageState.installed,
            directPackages: packageState.direct,
            artisanCommands: commands,
            existingPaths: existingPaths,
            nonEmptyDirectories: populatedDirectories,
            profiles: profiles,
            health: health
        )
    }

    func refreshProjectCapabilities() {
        guard let project = selectedProject else { projectCapabilities = []; return }
        let packageState = composerPackageState(in: project.path)
        let definitions: [(String,String,String,String,String,Bool)] = [
            ("Horizon", "laravel/horizon", "chart.bar.xaxis", "Queues", "Queue dashboard and worker supervision", false),
            ("Octane", "laravel/octane", "bolt.horizontal.fill", "Runtime", "High-performance application server", false),
            ("Reverb", "laravel/reverb", "antenna.radiowaves.left.and.right", "Realtime", "WebSocket server", false),
            ("Telescope", "laravel/telescope", "scope", "Observability", "Request, job and query inspection", true),
            ("Pulse", "laravel/pulse", "waveform.path.ecg", "Observability", "Application performance metrics", false),
            ("Pennant", "laravel/pennant", "flag.2.crossed.fill", "Features", "Feature flags", false),
            ("Scout", "laravel/scout", "magnifyingglass.circle.fill", "Search", "Search indexing", false),
            ("Sanctum", "laravel/sanctum", "lock.shield.fill", "Authentication", "API token authentication", false),
            ("Fortify", "laravel/fortify", "person.badge.key.fill", "Authentication", "Authentication backend", false),
            ("Cashier", "laravel/cashier", "creditcard.fill", "Billing", "Subscription billing", false),
            ("Dusk", "laravel/dusk", "moon.stars.fill", "Testing", "Browser testing", true),
            ("Pest", "pestphp/pest", "checkmark.seal.fill", "Testing", "Pest test runner", true),
            ("Livewire", "livewire/livewire", "bolt.square.fill", "Frontend", "Server-driven components", false),
            ("Inertia", "inertiajs/inertia-laravel", "arrow.left.arrow.right.square.fill", "Frontend", "Inertia adapter", false),
            ("Filament", "filament/filament", "rectangle.3.group.fill", "Admin", "Admin panel framework", false),
            ("Nova", "laravel/nova", "sparkles", "Admin", "Laravel Nova", false),
            ("Spatie Permission", "spatie/laravel-permission", "person.2.badge.gearshape.fill", "Security", "Roles and permissions", false),
            ("Laravel Modules", "nwidart/laravel-modules", "square.stack.3d.up.fill", "Architecture", "Modular application structure", false),
            ("Sail", "laravel/sail", "sailboat.fill", "Runtime", "Docker development environment", true)
        ]
        projectCapabilities = definitions.map { item in
            ProjectCapability(
                name: item.0,
                package: item.1,
                symbol: item.2,
                category: item.3,
                installed: packageState.installed.contains(item.1),
                directDependency: packageState.direct.contains(item.1),
                detail: item.4,
                developmentDependency: item.5
            )
        }.sorted { a,b in a.installed == b.installed ? a.name < b.name : a.installed && !b.installed }
    }

    private func composerPackageState(in projectPath: String) -> (direct: Set<String>, installed: Set<String>) {
        let root = URL(fileURLWithPath: projectPath)
        var direct = Set<String>()
        var installed = Set<String>()

        if let data = try? Data(contentsOf: root.appendingPathComponent("composer.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["require", "require-dev"] {
                if let dependencies = object[key] as? [String: Any] {
                    for package in dependencies.keys where package.contains("/") {
                        direct.insert(package.lowercased())
                        installed.insert(package.lowercased())
                    }
                }
            }
        }

        if let data = try? Data(contentsOf: root.appendingPathComponent("composer.lock")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["packages", "packages-dev"] {
                guard let packages = object[key] as? [[String: Any]] else { continue }
                for package in packages {
                    if let name = package["name"] as? String { installed.insert(name.lowercased()) }
                }
            }
        }

        return (direct, installed)
    }

    func installProjectCapability(_ capability: ProjectCapability) {
        guard !capability.installed else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Install \(capability.name)?"
        alert.informativeText = "Composer will add \(capability.package) to the selected project\(capability.developmentDependency ? " as a development dependency" : "")."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        runCapabilityComposerCommand(arguments: ["require", capability.package] + (capability.developmentDependency ? ["--dev"] : []), action: "Installing \(capability.name)")
    }

    func removeProjectCapability(_ capability: ProjectCapability) {
        guard capability.installed else { return }
        guard capability.directDependency else {
            showAlert(title: "Package is transitive", message: "\(capability.package) is installed by another dependency and is not declared directly in composer.json. Remove the package that requires it instead.")
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Remove \(capability.name)?"
        alert.informativeText = "Choose whether to remove only the Composer package or also delete known published artefacts such as package configuration, migrations, assets, and provider registrations. Artefact cleanup runs only after Composer succeeds."
        alert.addButton(withTitle: "Remove Package & Artefacts")
        alert.addButton(withTitle: "Remove Package Only")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return }

        runCapabilityComposerCommand(
            arguments: ["remove", capability.package],
            action: "Removing \(capability.name)",
            cleanupCapability: response == .alertFirstButtonReturn ? capability : nil
        )
    }

    private func runCapabilityComposerCommand(arguments: [String], action: String, cleanupCapability: ProjectCapability? = nil) {
        guard let project = selectedProject else { return }
        guard !phpPath.isEmpty, FileManager.default.isExecutableFile(atPath: phpPath) else {
            showAlert(title: "PHP is not configured", message: "Select a working PHP executable in Settings before running Composer. ABSDEV Studio will not use a different Homebrew PHP implicitly.")
            return
        }
        guard let composer = resolvedComposerExecutable(in: project.path) else {
            showAlert(title: "Composer was not found", message: "Install Composer or place composer.phar in the selected project. ABSDEV Studio searched the project, ServBay, Homebrew, and /usr/local locations.")
            return
        }

        let displayed = ([phpPath, composer] + arguments).map(shellQuote).joined(separator: " ")
        commandOutput = ["$ \(displayed)"]
        packageOperationTitle = action
        packageOperationDetail = arguments.first == "remove" ? "Removing the Composer package and updating the project dependency graph…" : "Installing the Composer package and resolving dependencies…"
        packageOperationOutput = ["$ \(displayed)"]
        packageOperationIsRunning = true
        packageOperationSucceeded = nil
        isPackageOperationPresented = true
        statusMessage = action
        isBusy = true

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: phpPath)
        process.arguments = [composer] + arguments + ["--no-interaction"]
        process.currentDirectoryURL = URL(fileURLWithPath: project.path)
        process.environment = commandEnvironment()
        process.standardOutput = pipe
        process.standardError = pipe

        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] file in
            let data = file.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                let lines = text.removingANSIControlSequences.replacingOccurrences(of: "\r", with: "").components(separatedBy: .newlines).filter { !$0.isEmpty }
                self?.commandOutput.append(contentsOf: lines)
                self?.packageOperationOutput.append(contentsOf: lines)
                if let self, self.packageOperationOutput.count > 250 {
                    self.packageOperationOutput.removeFirst(self.packageOperationOutput.count - 250)
                }
            }
        }
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self else { return }
                handle.readabilityHandler = nil
                self.isBusy = false
                self.packageOperationIsRunning = false
                if finished.terminationStatus == 0 {
                    self.packageOperationSucceeded = true
                    self.packageOperationDetail = "Composer completed successfully."
                    if arguments.first == "remove", arguments.count > 1 {
                        let removedPackage = arguments[1].lowercased()
                        let state = self.composerPackageState(in: project.path)
                        if state.direct.contains(removedPackage) {
                            let message = "✕ Composer returned success, but \(removedPackage) is still declared in composer.json."
                            self.commandOutput.append(message)
                            self.packageOperationOutput.append(message)
                            self.packageOperationSucceeded = false
                            self.packageOperationDetail = "Composer finished, but the package removal could not be verified."
                            self.statusMessage = "Package removal was not verified"
                            self.refreshProjectCapabilities()
                            return
                        }
                    }
                    self.commandOutput.append("✓ Composer completed")
                    self.packageOperationOutput.append("✓ Composer completed")
                    if let cleanupCapability {
                        self.packageOperationDetail = "Composer completed. Cleaning published artefacts…"
                        let cleanup = self.removePublishedArtefacts(for: cleanupCapability, projectPath: project.path)
                        self.commandOutput.append(contentsOf: cleanup)
                        self.packageOperationOutput.append(contentsOf: cleanup)
                        self.packageOperationDetail = "Package and known published artefacts were processed successfully."
                    }
                    self.statusMessage = "Composer command completed"
                    self.refreshProjectCapabilities()
                    Task { await self.refreshArtisanCommands() }
                } else {
                    let message = "✕ Failed (exit \(finished.terminationStatus))"
                    self.commandOutput.append(message)
                    self.packageOperationOutput.append(message)
                    self.packageOperationSucceeded = false
                    self.packageOperationDetail = "Composer failed. Review the output below for details."
                    self.statusMessage = "Composer command failed"
                }
            }
        }

        do { try process.run() }
        catch {
            handle.readabilityHandler = nil
            isBusy = false
            packageOperationIsRunning = false
            packageOperationSucceeded = false
            packageOperationDetail = "Composer could not be started."
            packageOperationOutput.append("✕ \(error.localizedDescription)")
            statusMessage = "Unable to run Composer"
            showAlert(title: "Composer command failed", message: error.localizedDescription)
        }
    }

    private func resolvedComposerExecutable(in projectPath: String) -> String? {
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

    private func removePublishedArtefacts(for capability: ProjectCapability, projectPath: String) -> [String] {
        let root = URL(fileURLWithPath: projectPath)
        let fm = FileManager.default
        var output = ["Cleaning known published artefacts for \(capability.name)…"]
        let exactPaths = publishedArtefactPaths(for: capability.package)
        let patterns = publishedArtefactPatterns(for: capability.package)

        for relative in exactPaths {
            let url = root.appendingPathComponent(relative)
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                try fm.removeItem(at: url)
                output.append("✓ Removed \(relative)")
            } catch {
                output.append("⚠ Could not remove \(relative): \(error.localizedDescription)")
            }
        }

        for pattern in patterns {
            let directory = root.appendingPathComponent(pattern.directory)
            guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
            for url in entries where url.lastPathComponent.range(of: pattern.filenameRegex, options: .regularExpression) != nil {
                let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
                do {
                    try fm.removeItem(at: url)
                    output.append("✓ Removed \(relative)")
                } catch {
                    output.append("⚠ Could not remove \(relative): \(error.localizedDescription)")
                }
            }
        }

        output.append(contentsOf: removeProviderRegistrations(for: capability.package, projectRoot: root))
        if output.count == 1 { output.append("No known published artefacts were present.") }
        return output
    }

    private func publishedArtefactPaths(for package: String) -> [String] {
        switch package {
        case "laravel/telescope": return ["config/telescope.php", "app/Providers/TelescopeServiceProvider.php", "public/vendor/telescope"]
        case "laravel/horizon": return ["config/horizon.php", "app/Providers/HorizonServiceProvider.php", "public/vendor/horizon"]
        case "laravel/pulse": return ["config/pulse.php", "app/Providers/PulseServiceProvider.php", "public/vendor/pulse"]
        case "laravel/octane": return ["config/octane.php", "public/octane-status"]
        case "laravel/reverb": return ["config/reverb.php"]
        case "laravel/sanctum": return ["config/sanctum.php"]
        case "laravel/fortify": return ["config/fortify.php", "app/Providers/FortifyServiceProvider.php"]
        case "laravel/cashier": return ["config/cashier.php"]
        case "laravel/scout": return ["config/scout.php"]
        case "laravel/pennant": return ["config/pennant.php"]
        case "spatie/laravel-permission": return ["config/permission.php"]
        case "nwidart/laravel-modules": return ["config/modules.php", "modules_statuses.json"]
        case "laravel/sail": return ["docker-compose.yml", "compose.yaml", "compose.yml"]
        case "laravel/dusk": return ["tests/Browser", "tests/Browser/Pages", "tests/Browser/Components"]
        default: return []
        }
    }

    private func publishedArtefactPatterns(for package: String) -> [(directory: String, filenameRegex: String)] {
        switch package {
        case "laravel/telescope": return [("database/migrations", ".*create_telescope_entries_table.*\\.php")]
        case "laravel/horizon": return [("database/migrations", ".*create_horizon.*\\.php")]
        case "laravel/pulse": return [("database/migrations", ".*create_pulse_.*\\.php")]
        case "laravel/sanctum": return [("database/migrations", ".*create_personal_access_tokens_table.*\\.php")]
        case "laravel/cashier": return [("database/migrations", ".*(create_customers_table|create_subscriptions_table|add_trial_ends_at_to_subscriptions_table).*\\.php")]
        case "spatie/laravel-permission": return [("database/migrations", ".*create_permission_tables.*\\.php")]
        default: return []
        }
    }

    private func removeProviderRegistrations(for package: String, projectRoot: URL) -> [String] {
        let providerNames: [String]
        switch package {
        case "laravel/telescope": providerNames = ["App\\Providers\\TelescopeServiceProvider"]
        case "laravel/horizon": providerNames = ["App\\Providers\\HorizonServiceProvider"]
        case "laravel/pulse": providerNames = ["App\\Providers\\PulseServiceProvider"]
        case "laravel/fortify": providerNames = ["App\\Providers\\FortifyServiceProvider"]
        default: return []
        }

        var output: [String] = []
        for relative in ["bootstrap/providers.php", "config/app.php"] {
            let url = projectRoot.appendingPathComponent(relative)
            guard var content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let original = content
            for provider in providerNames {
                let escaped = NSRegularExpression.escapedPattern(for: provider)
                content = content.replacingOccurrences(of: "(?m)^.*\(escaped)(::class)?[,]?\\s*$\\n?", with: "", options: .regularExpression)
            }
            guard content != original else { continue }
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                output.append("✓ Removed provider registration from \(relative)")
            } catch {
                output.append("⚠ Could not update \(relative): \(error.localizedDescription)")
            }
        }
        return output
    }

    private func isInstallArtisanCommand(_ commandName: String) -> Bool {
        commandName.lowercased().hasSuffix(":install")
    }

    private func confirmInstallArtisanCommand(_ input: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Run package installation command?"
        alert.informativeText = "php artisan \(input) may publish files, modify configuration, install assets, or change the selected project. Continue?"
        alert.addButton(withTitle: "Run Command")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func runInteractiveArtisan(_ command: String, returnSectionOnExit: AppSection? = nil) {
        guard let project = selectedProject else { return }
        stopInteractiveArtisanSession()
        interactiveArtisanReturnSectionOnExit = returnSectionOnExit

        let artisanCommand = "exec \(shellQuote(phpPath)) artisan \(command)"
        var environment = commandEnvironment()
        environment["TERM"] = environment["TERM"] ?? "xterm-256color"
        environment["COLORTERM"] = environment["COLORTERM"] ?? "truecolor"

        interactiveArtisanExecutable = "/bin/zsh"
        interactiveArtisanArguments = ["-l", "-c", artisanCommand]
        interactiveArtisanDirectory = project.path
        interactiveArtisanEnvironment = environment.map { "\($0.key)=\($0.value)" }.sorted()
        interactiveArtisanSessionID = UUID()
        isInteractiveArtisanSession = true
        isInteractiveArtisanTerminalVisible = true
        isBusy = true
        statusMessage = "Interactive Artisan session running"
        commandOutput = []
    }

    func interactiveArtisanDidTerminate(exitCode: Int32?) {
        let returnSection = interactiveArtisanReturnSectionOnExit
        interactiveArtisanReturnSectionOnExit = nil
        isInteractiveArtisanSession = false
        isBusy = false

        if let exitCode {
            statusMessage = exitCode == 0 ? "Interactive session ended" : "Interactive session failed (exit \(exitCode))"
        } else {
            statusMessage = "Interactive session ended"
        }

        if let returnSection {
            // Tinker is a temporary workspace. Once PsySH exits, unmount its PTY
            // and return to the normal project overview rather than leaving an
            // inactive terminal occupying the full Tinker screen.
            isInteractiveArtisanTerminalVisible = false
            interactiveArtisanSessionID = UUID()
            selectedSection = returnSection
        } else {
            // Other interactive Artisan workspaces retain their final output.
            isInteractiveArtisanTerminalVisible = true
        }
    }

    func stopInteractiveArtisanSession() {
        interactiveArtisanReturnSectionOnExit = nil
        isInteractiveArtisanSession = false
        isInteractiveArtisanTerminalVisible = false
        isBusy = false
        statusMessage = "Interactive session stopped"
        interactiveArtisanSessionID = UUID()
    }

    func refreshArtisanCommands() async {
        guard let project = selectedProject else { return }
        let projectID = project.id

        artisanDiscoveryMessage = "Scanning commands from the selected project…"
        isLoadingArtisanCommands = true
        defer { isLoadingArtisanCommands = false }

        let artisanURL = URL(fileURLWithPath: project.path).appendingPathComponent("artisan")
        guard FileManager.default.fileExists(atPath: artisanURL.path) else {
            artisanCommands = []
            artisanDiscoveryMessage = "The selected project does not contain artisan."
            return
        }

        var attempts: [(label: String, command: String)] = []
        let sailURL = URL(fileURLWithPath: project.path).appendingPathComponent("vendor/bin/sail")

        // Sail projects should be inspected inside their application container first. This
        // uses the project's PHP version, extensions, environment and service network.
        if FileManager.default.isExecutableFile(atPath: sailURL.path) || FileManager.default.fileExists(atPath: sailURL.path) {
            let sail = shellQuote(sailURL.path)
            attempts.append(("Laravel Sail JSON scanner", "\(sail) artisan list --format=json --no-ansi --no-interaction"))
            attempts.append(("Laravel Sail legacy scanner", "\(sail) artisan list --raw --no-ansi --no-interaction"))
        }

        if let phpExecutable = await resolvePHPExecutable(in: project.path) {
            let php = shellQuote(phpExecutable)
            attempts.append(("local PHP JSON scanner", "\(php) artisan list --format=json --no-ansi --no-interaction"))
            attempts.append(("local PHP legacy scanner", "\(php) artisan list --raw --no-ansi --no-interaction"))
        }

        guard !attempts.isEmpty else {
            artisanCommands = []
            artisanDiscoveryMessage = "No working PHP executable or Laravel Sail installation was found."
            return
        }

        var failures: [String] = []
        for attempt in attempts {
            guard selectedProjectID == projectID else { return }
            let result = await captureResult(attempt.command, in: project.path)
            guard selectedProjectID == projectID else { return }

            let parsed: [ArtisanCommand]
            if attempt.command.contains("--format=json") {
                parsed = parseArtisanJSON(result.output) ?? []
            } else {
                parsed = parseArtisanRawList(result.output)
            }

            if result.succeeded, !parsed.isEmpty {
                artisanCommands = Array(Set(parsed))
                    .filter { $0.name != "tinker" && !$0.aliases.contains("tinker") }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                artisanDiscoveryMessage = "\(artisanCommands.count) commands detected using the \(attempt.label), excluding Tinker which has its own workspace."
                return
            }

            let detail = result.output.trimmed
            if !detail.isEmpty {
                failures.append("\(attempt.label): \(detail)")
            }
        }

        // Do not erase a valid list just because a later rescan fails while containers or
        // project services are temporarily unavailable.
        if !artisanCommands.isEmpty {
            artisanDiscoveryMessage = "Rescan failed; retaining \(artisanCommands.count) previously detected commands. Start the project services and scan again."
            return
        }

        let reason = failures.first?.components(separatedBy: .newlines).prefix(3).joined(separator: " ")
            ?? "Artisan returned no command list."
        artisanDiscoveryMessage = "Command scan failed: \(reason)"
    }

    func refreshSailCommands() async {
        guard let project = selectedProject else { return }
        let projectID = project.id
        let sailURL = URL(fileURLWithPath: project.path).appendingPathComponent("vendor/bin/sail")
        guard FileManager.default.fileExists(atPath: sailURL.path) else {
            isSailInstalled = false
            isSailRunning = false
            sailVersion = "Not installed"
            sailCommands = []
            sailDiscoveryMessage = "Install laravel/sail in this project to enable this menu."
            if selectedSection == .sail { selectedSection = .artisan }
            return
        }

        isSailInstalled = true
        let script = (try? String(contentsOf: sailURL, encoding: .utf8)) ?? ""
        sailVersion = detectedSailVersion(projectPath: project.path) ?? "Installed"
        sailCommands = availableSailCommands(script: script)

        let runningResult = await captureResult(
            "\(shellQuote(sailURL.path)) ps -q 2>/dev/null",
            in: project.path
        )
        isSailRunning = !runningResult.output.trimmed.isEmpty
        sailDiscoveryMessage = isSailRunning
            ? "\(sailCommands.count) commands available from Laravel Sail \(sailVersion)."
            : "Laravel Sail is installed but its Docker containers are not running."

        if !isSailRunning, selectedSection == .sail {
            selectedSection = .development
        }
        guard selectedProjectID == projectID else { return }
    }

    func runSail(_ input: String) {
        let trimmed = input.trimmed
        guard !trimmed.isEmpty, let project = selectedProject else { return }
        let sailPath = URL(fileURLWithPath: project.path).appendingPathComponent("vendor/bin/sail").path
        guard FileManager.default.fileExists(atPath: sailPath) else {
            showAlert(title: "Laravel Sail is unavailable", message: "The selected project does not contain vendor/bin/sail.")
            return
        }
        let commandName = trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        if !sailCommands.contains(where: { $0.name == commandName }) && !isSailPassThroughCommand(commandName) {
            showAlert(title: "Sail command is unavailable", message: "‘\(commandName)’ is not supported by the installed Sail script. Rescan after updating laravel/sail.")
            return
        }
        if isDestructiveSailCommand(trimmed), !confirmSailCommand(trimmed) { return }
        clearConsole()
        if sailCommands.first(where: { $0.name == commandName })?.interactive == true {
            openSailInTerminal(trimmed, sailPath: sailPath, projectPath: project.path)
        } else {
            runCommand("\(shellQuote(sailPath)) \(trimmed)")
        }
    }


    private func openSailInTerminal(_ command: String, sailPath: String, projectPath: String) {
        let shellCommand = "cd \(shellQuote(projectPath)) && \(shellQuote(sailPath)) \(command)"
        let escaped = shellCommand.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"\(terminal)\" to do script \"\(escaped)\""
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error { showAlert(title: "Unable to open Sail session", message: error.description) }
        else {
            commandOutput.append("$ vendor/bin/sail \(command)")
            commandOutput.append("Interactive Sail session opened in \(terminal).")
            statusMessage = "Interactive Sail session opened"
        }
    }

    private func detectedSailVersion(projectPath: String) -> String? {
        let lockURL = URL(fileURLWithPath: projectPath).appendingPathComponent("composer.lock")
        guard let data = try? Data(contentsOf: lockURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let packages = (root["packages"] as? [[String: Any]] ?? []) + (root["packages-dev"] as? [[String: Any]] ?? [])
        return packages.first(where: { ($0["name"] as? String) == "laravel/sail" })?["version"] as? String
    }

    private func availableSailCommands(script: String) -> [SailCommand] {
        // Sail's wrapper implementation has changed substantially between releases. Some
        // versions use quoted case labels, some use grouped patterns, and newer releases
        // delegate most commands directly to Docker Compose. A text filter therefore
        // produces false negatives (for example, Sail 1.63 only exposed `php`). Keep a
        // complete version-compatible catalogue and validate the selected command when it
        // is executed by the installed project-local Sail script.
        let catalogue: [SailCommand] = [
            .init(name: "up", description: "Create and start the Sail containers.", example: "up -d", category: "Lifecycle", interactive: false),
            .init(name: "start", description: "Start existing service containers.", example: "start", category: "Lifecycle", interactive: false),
            .init(name: "stop", description: "Stop running service containers without removing them.", example: "stop", category: "Lifecycle", interactive: false),
            .init(name: "restart", description: "Restart one or all services.", example: "restart", category: "Lifecycle", interactive: false),
            .init(name: "down", description: "Stop and remove the Sail containers and network.", example: "down", category: "Lifecycle", interactive: false),
            .init(name: "ps", description: "List Sail services and their current state.", example: "ps", category: "Lifecycle", interactive: false),
            .init(name: "pause", description: "Pause one or more services.", example: "pause", category: "Lifecycle", interactive: false),
            .init(name: "unpause", description: "Resume paused services.", example: "unpause", category: "Lifecycle", interactive: false),
            .init(name: "kill", description: "Force-stop one or more service containers.", example: "kill", category: "Lifecycle", interactive: false),
            .init(name: "rm", description: "Remove stopped service containers.", example: "rm", category: "Lifecycle", interactive: false),
            .init(name: "build", description: "Build or rebuild service images.", example: "build --no-cache", category: "Images", interactive: false),
            .init(name: "pull", description: "Pull service images.", example: "pull", category: "Images", interactive: false),
            .init(name: "push", description: "Push service images where configured.", example: "push", category: "Images", interactive: false),
            .init(name: "images", description: "List images used by the Compose project.", example: "images", category: "Images", interactive: false),
            .init(name: "shell", description: "Open a shell as the Sail application user.", example: "shell", category: "Shells", interactive: true),
            .init(name: "bash", description: "Alias for the application shell on supported versions.", example: "bash", category: "Shells", interactive: true),
            .init(name: "root-shell", description: "Open a root shell in the application container.", example: "root-shell", category: "Shells", interactive: true),
            .init(name: "root-bash", description: "Alias for the root shell on supported versions.", example: "root-bash", category: "Shells", interactive: true),
            .init(name: "exec", description: "Execute a command in a running service container.", example: "exec laravel.test bash", category: "Shells", interactive: true),
            .init(name: "run", description: "Run a one-off command in a new service container.", example: "run --rm laravel.test php -v", category: "Shells", interactive: true),
            .init(name: "artisan", description: "Run an Artisan command inside Sail.", example: "artisan migrate", category: "Laravel", interactive: false),
            .init(name: "tinker", description: "Run Laravel Tinker inside Sail.", example: "tinker", category: "Laravel", interactive: true),
            .init(name: "test", description: "Run the Laravel test command inside Sail.", example: "test", category: "Testing", interactive: false),
            .init(name: "pest", description: "Run Pest inside Sail when installed.", example: "pest", category: "Testing", interactive: false),
            .init(name: "phpunit", description: "Run PHPUnit inside Sail.", example: "phpunit", category: "Testing", interactive: false),
            .init(name: "dusk", description: "Run Laravel Dusk inside Sail.", example: "dusk", category: "Testing", interactive: false),
            .init(name: "pint", description: "Run Laravel Pint inside Sail when installed.", example: "pint", category: "Quality", interactive: false),
            .init(name: "composer", description: "Run Composer inside Sail.", example: "composer install", category: "Tooling", interactive: false),
            .init(name: "php", description: "Run PHP inside the application container.", example: "php -v", category: "Tooling", interactive: false),
            .init(name: "node", description: "Run Node.js inside Sail.", example: "node --version", category: "Frontend", interactive: false),
            .init(name: "npm", description: "Run npm inside Sail.", example: "npm run dev", category: "Frontend", interactive: false),
            .init(name: "npx", description: "Run npx inside Sail.", example: "npx vite", category: "Frontend", interactive: false),
            .init(name: "yarn", description: "Run Yarn inside Sail when available.", example: "yarn dev", category: "Frontend", interactive: false),
            .init(name: "pnpm", description: "Run pnpm inside Sail when available.", example: "pnpm dev", category: "Frontend", interactive: false),
            .init(name: "mysql", description: "Open the MySQL client for the Sail database.", example: "mysql", category: "Databases", interactive: true),
            .init(name: "mariadb", description: "Open the MariaDB client when configured.", example: "mariadb", category: "Databases", interactive: true),
            .init(name: "psql", description: "Open the PostgreSQL client when configured.", example: "psql", category: "Databases", interactive: true),
            .init(name: "redis", description: "Open the Redis CLI when configured.", example: "redis", category: "Databases", interactive: true),
            .init(name: "logs", description: "View output from Sail services.", example: "logs -f", category: "Diagnostics", interactive: false),
            .init(name: "top", description: "Display running processes for services.", example: "top", category: "Diagnostics", interactive: false),
            .init(name: "events", description: "Stream Docker Compose events.", example: "events", category: "Diagnostics", interactive: true),
            .init(name: "config", description: "Validate and display the resolved Compose configuration.", example: "config", category: "Compose", interactive: false),
            .init(name: "create", description: "Create service containers without starting them.", example: "create", category: "Compose", interactive: false),
            .init(name: "cp", description: "Copy files between a service container and the host.", example: "cp laravel.test:/var/www/html/storage/logs/laravel.log .", category: "Compose", interactive: false),
            .init(name: "port", description: "Print a public port binding for a service.", example: "port laravel.test 80", category: "Compose", interactive: false),
            .init(name: "version", description: "Display Docker Compose version information.", example: "version", category: "Compose", interactive: false),
            .init(name: "share", description: "Share the local application through a public tunnel.", example: "share", category: "Utilities", interactive: true),
            .init(name: "debug", description: "Run a command with Xdebug enabled.", example: "debug artisan test", category: "Utilities", interactive: false)
        ]

        return catalogue.sorted { lhs, rhs in
            lhs.category == rhs.category ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending : lhs.category.localizedStandardCompare(rhs.category) == .orderedAscending
        }
    }

    private func isSailPassThroughCommand(_ name: String) -> Bool {
        ["exec", "run", "logs", "config", "images", "top", "port", "pause", "unpause", "kill", "rm", "cp", "create", "events", "version"].contains(name)
    }

    private func isDestructiveSailCommand(_ input: String) -> Bool {
        let lower = input.lowercased()
        return lower.hasPrefix("down") || lower.hasPrefix("rm") || lower.contains("--volumes") || lower.contains("-v") || lower.hasPrefix("artisan migrate:fresh") || lower.hasPrefix("artisan db:wipe")
    }

    private func confirmSailCommand(_ input: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Run destructive Sail command?"
        alert.informativeText = "vendor/bin/sail \(input) may remove containers, networks, volumes, or application data. Continue?"
        alert.addButton(withTitle: "Run Command")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func parseArtisanJSON(_ output: String) -> [ArtisanCommand]? {
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let commandValue = root["commands"] else { return nil }

        let rows: [[String: Any]]
        if let array = commandValue as? [[String: Any]] {
            rows = array
        } else if let dictionary = commandValue as? [String: [String: Any]] {
            rows = dictionary.map { name, details in
                var row = details
                if row["name"] == nil { row["name"] = name }
                return row
            }
        } else {
            return nil
        }

        return rows.compactMap { row in
            guard let name = row["name"] as? String, !name.isEmpty else { return nil }
            guard name != "tinker" && name != "db" else { return nil }
            let description = row["description"] as? String ?? ""
            let usage: [String]
            if let values = row["usage"] as? [String] { usage = values }
            else if let value = row["usage"] as? String { usage = [value] }
            else { usage = [] }
            let aliases = row["aliases"] as? [String] ?? []
            return ArtisanCommand(name: name, description: description, usage: usage, aliases: aliases)
        }
    }

    private func parseArtisanRawList(_ output: String) -> [ArtisanCommand] {
        output.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = parts.first else { return nil }
            let name = String(first)
            guard !name.hasPrefix("-") && name != "tinker" && name != "db" else { return nil }
            let description = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            return ArtisanCommand(name: name, description: description, usage: [], aliases: [])
        }
    }

    private func artisanCommandName(from input: String) -> String {
        let tokens = input.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return "" }
        if tokens[0] == "help", tokens.count > 1 { return "help" }
        return tokens[0]
    }


    private func artisanArguments(from input: String) -> [String] {
        let tokens = input.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count > 1 else { return [] }
        return Array(tokens.dropFirst()).filter { !$0.hasPrefix("-") }
    }

    private func chooseEloquentModel() -> String? {
        let models = discoverEloquentModels()
        guard !models.isEmpty else {
            showAlert(
                title: "No Eloquent models found",
                message: "ABSDEV Studio searched app/Models, app, and module model folders but did not find any concrete Eloquent model classes."
            )
            return nil
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Choose an Eloquent model"
        alert.informativeText = "Select the model to inspect with php artisan model:show."
        alert.addButton(withTitle: "Show Model")
        alert.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 430, height: 28), pullsDown: false)
        popup.addItems(withTitles: models)
        popup.selectItem(at: 0)
        alert.accessoryView = popup

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return popup.titleOfSelectedItem
    }

    private func discoverEloquentModels() -> [String] {
        guard let project = selectedProject else { return [] }
        let root = URL(fileURLWithPath: project.path, isDirectory: true)
        let fileManager = FileManager.default
        var roots: [URL] = [
            root.appendingPathComponent("app/Models", isDirectory: true),
            root.appendingPathComponent("app", isDirectory: true),
            root.appendingPathComponent("Modules", isDirectory: true),
            root.appendingPathComponent("modules", isDirectory: true)
        ]
        roots = roots.filter { fileManager.fileExists(atPath: $0.path) }

        var found = Set<String>()
        let namespacePattern = try? NSRegularExpression(pattern: #"namespace\s+([^;]+);"#)
        let classPattern = try? NSRegularExpression(pattern: #"(?:final\s+|abstract\s+)?class\s+([A-Za-z_][A-Za-z0-9_]*)\s+extends\s+([A-Za-z_\\][A-Za-z0-9_\\]*)"#)

        for searchRoot in roots {
            guard let enumerator = fileManager.enumerator(
                at: searchRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "php" {
                guard let source = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                let range = NSRange(source.startIndex..., in: source)
                guard let classMatch = classPattern?.firstMatch(in: source, range: range),
                      let classRange = Range(classMatch.range(at: 1), in: source),
                      let parentRange = Range(classMatch.range(at: 2), in: source) else { continue }

                let parent = String(source[parentRange])
                let isModel = parent == "Model" || parent.hasSuffix("\\Model") ||
                    source.contains("use Illuminate\\Database\\Eloquent\\Model") ||
                    source.contains("extends Authenticatable")
                guard isModel, !source.contains("abstract class") else { continue }

                let className = String(source[classRange])
                var namespace = ""
                if let namespaceMatch = namespacePattern?.firstMatch(in: source, range: range),
                   let namespaceRange = Range(namespaceMatch.range(at: 1), in: source) {
                    namespace = String(source[namespaceRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                found.insert(namespace.isEmpty ? className : "\(namespace)\\\(className)")
            }
        }

        return found.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func requiresInteractiveArtisanTerminal(commandName: String, input: String) -> Bool {
        let lower = input.lowercased()

        // These commands are known to open Laravel Prompts, database shells,
        // long-running interactive monitors, or package-defined selectors.
        if commandName == "vendor:publish" || commandName == "db" || commandName.hasPrefix("db:") {
            return true
        }
        if commandName.hasPrefix("make:") || commandName.hasSuffix(":install") {
            return true
        }
        if ["queue:listen", "queue:work", "queue:monitor", "schedule:work", "reverb:start", "octane:start", "horizon"].contains(commandName) {
            return true
        }
        if lower.contains("--interactive") || lower.contains("--ansi") && lower.contains("prompt") {
            return true
        }

        // Project and package commands frequently declare required arguments but
        // open Laravel Prompts when those arguments are omitted. Keep those
        // sessions attached to SwiftTerm so keyboard input remains available.
        if artisanArguments(from: input).isEmpty,
           let definition = artisanCommands.first(where: { $0.name == commandName || $0.aliases.contains(commandName) }),
           definition.primaryUsage.contains("<") {
            return true
        }
        return false
    }

    private func isDestructiveArtisanCommand(_ input: String) -> Bool {
        let lower = input.lowercased()
        let destructive = ["migrate:fresh", "migrate:reset", "db:wipe", "schema:dump --prune", "queue:clear", "horizon:clear"]
        return destructive.contains { lower.hasPrefix($0) } || (lower.hasPrefix("key:generate") && lower.contains("--force"))
    }

    private func confirmDestructiveArtisanCommand(_ input: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Run destructive Artisan command?"
        alert.informativeText = "php artisan \(input) may permanently remove or replace project data. Verify the selected project and environment before continuing."
        alert.addButton(withTitle: "Run Command")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func runCommand(_ command: String) {
        guard let project = selectedProject else { return }
        let runID = UUID()
        let projectName = project.name
        let isTestRun = isTestCommand(command)
        commandRunOutput[runID] = []
        if isTestRun { testCommandRuns.insert(runID) }

        commandOutput.append("$ \(command)")
        statusMessage = "Running \(command)…"
        isBusy = true
        commandProgressTitle = isTestRun ? "Running Tests" : "Running Command"
        commandProgressCommand = command
        commandProgressDetail = "Starting in \(projectName)…"
        commandProgressStartedAt = Date()
        foregroundCommandStartedAt = commandProgressStartedAt
        isCommandProgressPresented = true

        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", command]
        task.currentDirectoryURL = URL(fileURLWithPath: project.path)
        task.environment = commandEnvironment()
        task.standardOutput = pipe
        task.standardError = pipe

        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] file in
            let data = file.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let cleaned = text.removingANSIControlSequences
                    .replacingOccurrences(of: "\r", with: "")
                let lines = cleaned.components(separatedBy: .newlines).filter { !$0.isEmpty }
                self.commandOutput.append(contentsOf: lines)
                self.commandRunOutput[runID, default: []].append(contentsOf: lines)
                if let latest = lines.last {
                    self.commandProgressDetail = latest
                }
            }
        }
        task.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                guard let self else { return }
                handle.readabilityHandler = nil
                let status = process.terminationStatus
                self.commandOutput.append(status == 0 ? "✓ Completed" : "✕ Failed (exit \(status))")
                self.statusMessage = status == 0 ? "Command completed" : "Command failed"
                self.isBusy = false
                self.isCommandProgressPresented = false
                self.commandProgressStartedAt = nil
                self.activeForegroundCommand = nil
                let duration = Date().timeIntervalSince(self.foregroundCommandStartedAt ?? Date())
                self.foregroundCommandStartedAt = nil
                self.postCompletionNotification(
                    title: status == 0 ? "Command completed" : "Command failed",
                    body: "\(command) \(status == 0 ? "finished" : "failed") in \(String(format: "%.1f", duration))s."
                )

                let lines = self.commandRunOutput.removeValue(forKey: runID) ?? []
                if status == 0 && lines.isEmpty {
                    self.commandOutput.append("Command completed successfully with no textual output.")
                }
                let wasTestRun = self.testCommandRuns.remove(runID) != nil
                if wasTestRun && status != 0 {
                    self.presentTestFailureReport(
                        command: command,
                        projectName: projectName,
                        exitCode: status,
                        lines: lines
                    )
                }
            }
        }
        do {
            try task.run()
            activeForegroundCommand = task
        }
        catch {
            handle.readabilityHandler = nil
            commandRunOutput.removeValue(forKey: runID)
            testCommandRuns.remove(runID)
            commandOutput.append(error.localizedDescription)
            statusMessage = "Command failed"
            isBusy = false
            isCommandProgressPresented = false
            commandProgressStartedAt = nil
            activeForegroundCommand = nil
            foregroundCommandStartedAt = nil
        }
    }

    func cancelForegroundCommand() {
        guard let process = activeForegroundCommand, process.isRunning else { return }
        commandProgressDetail = "Cancelling…"
        process.terminate()
    }

    private func isTestCommand(_ command: String) -> Bool {
        let lower = command.lowercased()
        return lower.range(of: #"(?:^|\s)artisan\s+(?:test|dusk)(?:\s|$)"#, options: .regularExpression) != nil
            || lower.range(of: #"(?:^|\s)(?:phpunit|pest)(?:\s|$)"#, options: .regularExpression) != nil
    }

    private func presentTestFailureReport(command: String, projectName: String, exitCode: Int32, lines: [String]) {
        let details = extractTestFailures(from: lines)
        let joined = lines.joined(separator: "\n")
        let failureCount = firstCapturedInteger(
            in: joined,
            patterns: [#"Tests:\s*(\d+)\s+failed"#, #"Failures:\s*(\d+)"#, #"There (?:was|were) (\d+) failure"#]
        )

        testFailureReport = TestFailureReport(
            command: command,
            projectName: projectName,
            exitCode: exitCode,
            failureCount: failureCount,
            details: details
        )
    }

    private func extractTestFailures(from lines: [String]) -> String {
        guard !lines.isEmpty else { return "The test command failed without producing output." }

        let failureStartPatterns = [
            #"^\s*FAILED\s+Tests[\\/]"#,
            #"^\s*FAIL\s+Tests[\\/]"#,
            #"^\s*There (?:was|were) \d+ failure"#,
            #"^\s*FAILURES!"#,
            #"^\s*\d+\)\s+"#
        ]
        let summaryPatterns = [
            #"^\s*Tests:\s*.*failed"#,
            #"^\s*FAILURES!"#,
            #"^\s*Time:\s*"#,
            #"^\s*Tests run:\s*"#
        ]

        var included = IndexSet()
        for (index, line) in lines.enumerated() {
            if matchesAny(line, patterns: failureStartPatterns) {
                let end = min(lines.count, index + 45)
                included.insert(integersIn: index..<end)
            }
            if matchesAny(line, patterns: summaryPatterns) {
                included.insert(integersIn: max(0, index - 2)..<min(lines.count, index + 5))
            }
            let upper = line.trimmingCharacters(in: .whitespaces).uppercased()
            if upper.hasPrefix("⨯") || upper.hasPrefix("✕") || upper.hasPrefix("FAILED ") || upper.hasPrefix("ERROR ") {
                included.insert(integersIn: max(0, index - 1)..<min(lines.count, index + 8))
            }
        }

        if included.isEmpty {
            let start = max(0, lines.count - 120)
            return lines[start...].joined(separator: "\n")
        }

        var output: [String] = []
        var previous: Int?
        for index in included {
            if let previous, index > previous + 1 { output.append("…") }
            output.append(lines[index])
            previous = index
        }
        return output.joined(separator: "\n")
    }

    private func matchesAny(_ value: String, patterns: [String]) -> Bool {
        patterns.contains { value.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    private func firstCapturedInteger(in value: String, patterns: [String]) -> Int? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: value),
                  let result = Int(value[range]) else { continue }
            return result
        }
        return nil
    }

    func clearConsole() { commandOutput.removeAll() }

    func loadEnvironment() {
        guard let project = selectedProject else { return }
        let path = URL(fileURLWithPath: project.path).appendingPathComponent(".env")
        guard let content = try? String(contentsOf: path, encoding: .utf8) else {
            environmentEntries = []
            return
        }
        environmentEntries = content.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            let text = String(line)
            guard !text.trimmingCharacters(in: .whitespaces).hasPrefix("#"), let separator = text.firstIndex(of: "=") else { return nil }
            let key = String(text[..<separator])
            let value = String(text[text.index(after: separator)...])
            guard !key.isEmpty else { return nil }
            let secret = ["KEY", "PASSWORD", "SECRET", "TOKEN"].contains { key.uppercased().contains($0) }
            return EnvironmentEntry(key: key, value: value, isSecret: secret)
        }
    }

    func updateEnvironmentEntry(_ entry: EnvironmentEntry, newValue: String) {
        guard let index = environmentEntries.firstIndex(where: { $0.id == entry.id }) else { return }
        environmentEntries[index].value = newValue
    }

    func saveEnvironment() {
        guard let project = selectedProject else { return }
        let url = URL(fileURLWithPath: project.path).appendingPathComponent(".env")
        guard var content = try? String(contentsOf: url, encoding: .utf8) else { return }
        for entry in environmentEntries {
            let pattern = "(?m)^" + NSRegularExpression.escapedPattern(for: entry.key) + "=.*$"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(content.startIndex..., in: content)
                content = regex.stringByReplacingMatches(in: content, range: range, withTemplate: entry.key + "=" + entry.value)
            }
        }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = ".env saved"
            Task { await refreshProject() }
        } catch { showAlert(title: "Unable to save .env", message: error.localizedDescription) }
    }

    func compareEnvironment() {
        guard let project = selectedProject else { return }
        let root = URL(fileURLWithPath: project.path)
        let exampleURL = root.appendingPathComponent(".env.example")
        let currentURL = root.appendingPathComponent(".env")

        guard FileManager.default.fileExists(atPath: exampleURL.path) else {
            showAlert(title: "Unable to compare environments", message: ".env.example does not exist in this project.")
            return
        }

        environmentExampleContent = (try? String(contentsOf: exampleURL, encoding: .utf8)) ?? ""
        environmentCurrentContent = (try? String(contentsOf: currentURL, encoding: .utf8)) ?? ""
        isEnvironmentComparisonPresented = true
    }

    var shouldShowLaravelDevelopmentServer: Bool {
        guard let project = selectedProject else { return true }
        let root = URL(fileURLWithPath: project.path)
        let fm = FileManager.default

        let containerFiles = [
            "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml",
            "Containerfile", "container-compose.yml", "container-compose.yaml"
        ]
        let hasContainerRuntimeConfiguration = containerFiles.contains {
            fm.fileExists(atPath: root.appendingPathComponent($0).path)
        }
        let usesAppleContainer = fm.fileExists(atPath: root.appendingPathComponent(".container").path)
            || fm.fileExists(atPath: root.appendingPathComponent("container.json").path)

        let normalizedProjectPath = root.standardizedFileURL.path
        let servedByServBay = isServBayInstalled && servBayWebsites.contains(where: { (website: ServBayWebsite) -> Bool in
            let documentRoot = URL(fileURLWithPath: website.rootPath).standardizedFileURL.path
            return documentRoot == normalizedProjectPath
                || documentRoot.hasPrefix(normalizedProjectPath + "/")
                || normalizedProjectPath.hasPrefix(documentRoot + "/")
        })

        return !(isSailInstalled || hasContainerRuntimeConfiguration || usesAppleContainer || servedByServBay)
    }

    func runDiagnostics() async {
        guard let project = selectedProject else { return }
        let projectID = project.id
        isRunningDiagnostics = true
        statusMessage = "Running project checks…"
        defer {
            if selectedProjectID == projectID {
                isRunningDiagnostics = false
                diagnosticsLastRun = Date()
                statusMessage = "Project checks complete"
            }
        }

        await Task.yield()

        var items: [DiagnosticItem] = []
        let fm = FileManager.default
        let projectURL = URL(fileURLWithPath: project.path)

        let artisan = fm.fileExists(atPath: projectURL.appendingPathComponent("artisan").path)
        items.append(.init(title: "Artisan entry point", detail: artisan ? "artisan is present." : "artisan could not be found.", status: artisan ? .healthy : .error, action: nil, command: nil))

        let composerJSON = fm.fileExists(atPath: projectURL.appendingPathComponent("composer.json").path)
        items.append(.init(title: "Composer manifest", detail: composerJSON ? "composer.json is present." : "composer.json could not be found.", status: composerJSON ? .healthy : .error, action: nil, command: nil))

        let key = value(for: "APP_KEY") ?? ""
        items.append(.init(title: "Application key", detail: key.isEmpty ? "APP_KEY is missing." : "APP_KEY is configured.", status: key.isEmpty ? .error : .healthy, action: key.isEmpty ? "Generate key" : nil, command: key.isEmpty ? "key:generate" : nil))

        let storage = projectURL.appendingPathComponent("storage")
        let writable = fm.isWritableFile(atPath: storage.path)
        items.append(.init(title: "Storage permissions", detail: writable ? "storage is writable." : "storage is not writable.", status: writable ? .healthy : .error, action: nil, command: nil))

        let cache = projectURL.appendingPathComponent("bootstrap/cache/config.php")
        let cached = fm.fileExists(atPath: cache.path)
        items.append(.init(title: "Configuration cache", detail: cached ? "Configuration is cached; clear it after .env changes." : "No configuration cache detected.", status: cached ? .warning : .healthy, action: cached ? "Clear cache" : nil, command: cached ? "config:clear" : nil))

        let php = await resolvePHPExecutable(in: project.path)
        items.append(.init(title: "PHP runtime", detail: php.map { "Using \($0)." } ?? "No working PHP executable was detected.", status: php == nil ? .error : .healthy, action: nil, command: nil))

        let vendor = fm.fileExists(atPath: projectURL.appendingPathComponent("vendor/autoload.php").path)
        items.append(.init(title: "Composer dependencies", detail: vendor ? "vendor/autoload.php is present." : "Composer dependencies have not been installed.", status: vendor ? .healthy : .warning, action: vendor ? nil : "Run composer install", command: nil))

        guard selectedProjectID == projectID else { return }
        diagnostics = items
    }

    func executeDiagnostic(_ item: DiagnosticItem) {
        guard let command = item.command else { return }
        runArtisan(command)
        selectedSection = .artisan
    }

    func refreshRoutes() async {
        guard let project = selectedProject else { return }
        let projectID = project.id
        let output = await capture("\(shellQuote(phpPath)) artisan route:list --json", in: project.path)
        guard selectedProjectID == projectID,
              let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        routes = json.map { row in
            RouteItem(method: row["method"] as? String ?? "", uri: row["uri"] as? String ?? "", name: row["name"] as? String ?? "", action: row["action"] as? String ?? "", middleware: (row["middleware"] as? [String])?.joined(separator: ", ") ?? (row["middleware"] as? String ?? ""))
        }
    }

    private func activeLaravelLogURL(for project: LaravelProject) -> URL? {
        let directory = URL(fileURLWithPath: project.path).appendingPathComponent("storage/logs", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return files
            .filter { $0.pathExtension.lowercased() == "log" }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
            .first
    }

    func loadLogs() {
        guard let project = selectedProject else { return }
        guard let logURL = activeLaravelLogURL(for: project) else {
            currentLogFileName = "No log selected"
            logLines = ["No Laravel log file found in storage/logs."]
            return
        }
        currentLogFileName = logURL.lastPathComponent
        guard let content = try? String(contentsOf: logURL, encoding: .utf8) else {
            logLines = ["Unable to read \(logURL.lastPathComponent)."]
            return
        }
        logLines = Array(content.lines.suffix(1000))
    }

    func startLogTail() {
        guard !isTailingLogs else { return }
        guard selectedProject != nil else { return }
        isTailingLogs = true
        loadLogs()
        logTailTask?.cancel()
        logTailTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(750))
                guard !Task.isCancelled else { break }
                await MainActor.run { self?.loadLogs() }
            }
        }
    }

    func stopLogTail() {
        logTailTask?.cancel()
        logTailTask = nil
        isTailingLogs = false
    }

    func toggleLogTail() {
        isTailingLogs ? stopLogTail() : startLogTail()
    }

    func clearLogs() {
        guard let project = selectedProject, let url = activeLaravelLogURL(for: project) else {
            showAlert(title: "Unable to clear log", message: "No Laravel log file was found in storage/logs.")
            return
        }
        do {
            try "".write(to: url, atomically: true, encoding: .utf8)
            logLines = []
            currentLogFileName = url.lastPathComponent
            statusMessage = "Log cleared"
        } catch {
            showAlert(title: "Unable to clear log", message: error.localizedDescription)
        }
    }

    func openBrowser() {
        guard let raw = selectedProject?.appURL, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    func revealInFinder() {
        guard let project = selectedProject else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
    }

    func openInEditor() {
        guard let project = selectedProject else { return }
        let app = editor == "Visual Studio Code" ? "Visual Studio Code" : editor
        NSWorkspace.shared.open([URL(fileURLWithPath: project.path)], withApplicationAt: applicationURL(named: app) ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: NSWorkspace.OpenConfiguration())
    }

    func openInTerminal() {
        guard let project = selectedProject else {
            showAlert(title: "No project selected", message: "Choose a project before opening a terminal.")
            return
        }

        // Use macOS's `open` command instead of AppleScript. This opens the
        // selected terminal at the project directory without requiring the
        // Automation permission that previously caused error -1743.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", terminal, project.path]
        let errorPipe = Pipe()
        task.standardError = errorPipe

        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else {
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8)?.trimmed
                showAlert(
                    title: "Unable to open terminal",
                    message: message?.isEmpty == false
                        ? message!
                        : "macOS could not open \(terminal). Choose another terminal in Settings."
                )
                return
            }
            statusMessage = "Opened \(project.name) in \(terminal)"
        } catch {
            showAlert(title: "Unable to open terminal", message: error.localizedDescription)
        }
    }

    func choosePHPExecutable() {
        chooseProjectPHPExecutable()
    }

    func chooseProjectPHPExecutable() {
        guard let projectID = selectedProjectID else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose PHP executable for this project"
        panel.message = "This PHP runtime will be stored only for the selected project."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].phpExecutablePath = url.path
        projects[index].phpDetectionSource = "Manual"
        saveProjects()
        Task { await validateSelectedPHP() }
    }

    func clearProjectPHPExecutable() {
        guard let projectID = selectedProjectID,
              let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].phpExecutablePath = nil
        projects[index].phpDetectionSource = nil
        saveProjects()
        phpStatus = "Project PHP preference cleared"
    }

    func detectPHP() { detectProjectPHP() }

    func detectProjectPHP() {
        guard let project = selectedProject else { return }
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index].phpExecutablePath = nil
            projects[index].phpDetectionSource = nil
            saveProjects()
        }
        Task {
            if await resolvePHPExecutable(in: project.path) != nil {
                await refreshProject()
            } else {
                showAlert(title: "No working PHP found", message: "ABSDEV Studio checked the project preference, Herd, ServBay, Homebrew, Valet, and PATH locations.")
            }
        }
    }

    func validateSelectedPHP() async {
        guard let project = selectedProject else { return }
        let selectedPath = project.phpExecutablePath ?? phpPath
        guard !selectedPath.isEmpty else { phpStatus = "No PHP executable selected"; return }
        let result = await captureResult("\(shellQuote(selectedPath)) -r 'echo PHP_VERSION;'", in: project.path)
        if result.succeeded {
            phpStatus = "PHP \(result.output.trimmed)"
            await refreshProject()
        } else {
            phpStatus = concisePHPError(result.output)
            showAlert(title: "PHP could not start", message: phpStatus)
        }
    }

    func showAlert(title: String, message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.alertStyle = .warning; alert.runModal()
    }

    private func value(for key: String) -> String? { environmentEntries.first(where: { $0.key == key })?.value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
    private func applicationURL(named name: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: ["Xcode":"com.apple.dt.Xcode", "Visual Studio Code":"com.microsoft.VSCode", "PhpStorm":"com.jetbrains.PhpStorm"][name] ?? "") }
    private func setProcess(_ id: UUID, running: Bool) { if let index = processes.firstIndex(where: { $0.id == id }) { processes[index].isRunning = running } }
    private func appendProcessOutput(_ id: UUID, text: String) { if let index = processes.firstIndex(where: { $0.id == id }) { processes[index].output.append(contentsOf: text.lines); if processes[index].output.count > 300 { processes[index].output.removeFirst(processes[index].output.count - 300) } } }
    private func processDidTerminate(_ id: UUID) { runningProcesses[id] = nil; processPipes[id] = nil; setProcess(id, running: false) }

    private struct CommandResult: Sendable {
        let output: String
        let exitCode: Int32
        var succeeded: Bool { exitCode == 0 }
    }

    private func capture(_ command: String, in directory: String) async -> String {
        await captureResult(command, in: directory).output
    }

    private func captureResult(
        _ command: String,
        in directory: String,
        environmentProject: LaravelProject? = nil
    ) async -> CommandResult {
        let environment = commandEnvironment(for: environmentProject)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process(); let pipe = Pipe()
                task.executableURL = URL(fileURLWithPath: "/bin/zsh"); task.arguments = ["-c", command]
                task.currentDirectoryURL = URL(fileURLWithPath: directory); task.environment = environment; task.standardOutput = pipe; task.standardError = pipe
                do {
                    try task.run()
                    // Drain the pipe while the child is running. Waiting first can
                    // deadlock when commands such as `artisan list --format=json`
                    // produce more output than the pipe buffer can hold.
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    task.waitUntilExit()
                    continuation.resume(returning: CommandResult(output: String(data: data, encoding: .utf8) ?? "", exitCode: task.terminationStatus))
                } catch {
                    continuation.resume(returning: CommandResult(output: error.localizedDescription, exitCode: -1))
                }
            }
        }
    }

    private func resolvePHPExecutable(in directory: String) async -> String? {
        var candidates: [(path: String, source: String)] = []
        if let project = projects.first(where: { $0.path == directory }),
           let projectPHP = project.phpExecutablePath, !projectPHP.isEmpty {
            candidates.append((projectPHP, project.phpDetectionSource ?? "Project"))
        }
        if !phpPath.isEmpty { candidates.append((phpPath, "Global fallback")) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates += [
            ("\(home)/Library/Application Support/Herd/bin/php", "Herd"),
            ("\(home)/.config/herd-lite/bin/php", "Herd Lite"),
            ("\(home)/.config/valet/bin/php", "Valet"),
            ("/Applications/ServBay/package/php/current/bin/php", "ServBay"),
            ("/opt/homebrew/opt/php@8.4/bin/php", "Homebrew 8.4"),
            ("/opt/homebrew/opt/php@8.3/bin/php", "Homebrew 8.3"),
            ("/opt/homebrew/opt/php@8.2/bin/php", "Homebrew 8.2"),
            ("/opt/homebrew/bin/php", "Homebrew"),
            ("/usr/local/bin/php", "Local"),
            ("/usr/bin/php", "System")
        ]
        let pathOutput = await capture("which -a php 2>/dev/null || true", in: directory)
        candidates += pathOutput.lines.map { ($0, "PATH") }

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate.path).inserted {
            guard FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
            let result = await captureResult("\(shellQuote(candidate.path)) -r 'echo PHP_VERSION;'", in: directory)
            if result.succeeded, !result.output.trimmed.isEmpty {
                phpStatus = "PHP \(result.output.trimmed) · \(candidate.source)"
                if let index = projects.firstIndex(where: { $0.path == directory }) {
                    projects[index].phpExecutablePath = candidate.path
                    projects[index].phpDetectionSource = candidate.source
                    projects[index].phpVersion = result.output.trimmed
                    saveProjects()
                }
                return candidate.path
            }
        }
        phpStatus = "No working PHP executable found"
        return nil
    }

    private func resolvedProcessCommand(_ command: String) -> String {
        guard command.hasPrefix("php ") else { return command }
        let suffix = String(command.dropFirst(4))
        let executable = selectedProject?.phpExecutablePath ?? phpPath
        return "\(shellQuote(executable)) \(suffix)"
    }

    private func concisePHPError(_ output: String) -> String {
        if output.contains("Library not loaded"), output.contains("libpq") {
            return "The selected PHP binary is broken because PostgreSQL's libpq library is missing. Select another PHP executable, or repair the Homebrew PHP/libpq installation."
        }
        return output.lines.prefix(5).joined(separator: "\n").trimmed.nonEmpty ?? "The selected PHP executable could not run."
    }

    private func commandEnvironment(for explicitProject: LaravelProject? = nil) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [
            "/Applications/ServBay/bin",
            "/Applications/ServBay/package/node/current/bin",
            "/Applications/ServBay/package/composer/current/bin",
            "\(home)/.nvm/versions/node/current/bin",
            "\(home)/.volta/bin",
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let existing = environment["PATH"] ?? ""
        environment["PATH"] = (paths + [existing]).joined(separator: ":")

        // A GUI application can inherit Laravel and database variables from
        // the environment that launched it. Merely overlaying DB_DATABASE is not
        // sufficient: DB_URL / DATABASE_URL and provider-specific variables can
        // take precedence inside config/database.php and silently select a
        // different schema. Remove all project-scoped variables first, then apply
        // only the selected project's .env values.
        if let project = explicitProject ?? selectedProject {
            let exactProjectKeys: Set<String> = [
                "APP_ENV", "APP_DEBUG", "APP_URL", "APP_CONFIG_CACHE",
                "DB_URL", "DATABASE_URL", "CLEARDB_DATABASE_URL",
                "MYSQL_URL", "MYSQL_HOST", "MYSQL_PORT", "MYSQL_DATABASE",
                "MYSQL_USER", "MYSQL_USERNAME", "MYSQL_PASSWORD",
                "POSTGRES_URL", "POSTGRESQL_URL", "PGHOST", "PGPORT",
                "PGDATABASE", "PGUSER", "PGPASSWORD"
            ]
            let projectPrefixes = [
                "DB_", "REDIS_", "CACHE_", "QUEUE_", "SESSION_", "MAIL_",
                "FILESYSTEM_", "AWS_", "MEMCACHED_", "BROADCAST_"
            ]
            for key in Array(environment.keys) {
                if exactProjectKeys.contains(key) || projectPrefixes.contains(where: { key.hasPrefix($0) }) {
                    environment.removeValue(forKey: key)
                }
            }

            for (key, value) in projectEnvironment(at: project.path) {
                environment[key] = value
            }

            // Laravel's cached configuration contains database values captured
            // when `config:cache` was last run. Do not let that cache override the
            // selected project's current .env while ABSDEV Studio is inspecting it.
            let cacheName = "absdev-config-\(project.id.uuidString).php"
            environment["APP_CONFIG_CACHE"] = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(cacheName)
                .path
        }
        return environment
    }

    private func databaseIdentity(for project: LaravelProject) -> String {
        let values = projectEnvironment(at: project.path)
        let connection = values["DB_CONNECTION"]?.trimmed.nonEmpty ?? "database"
        let database = values["DB_DATABASE"]?.trimmed.nonEmpty ?? "default"
        return "\(connection):\(database)"
    }

    private func projectEnvironment(at projectPath: String) -> [String: String] {
        let url = URL(fileURLWithPath: projectPath).appendingPathComponent(".env")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [:] }

        var values: [String: String] = [:]
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            let assignment = line.hasPrefix("export ") ? String(line.dropFirst(7)) : line
            guard let separator = assignment.firstIndex(of: "=") else { continue }
            let key = String(assignment[..<separator]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            var value = String(assignment[assignment.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               let first = value.first,
               let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value.removeFirst()
                value.removeLast()
            } else if let comment = value.range(of: " #") {
                value = String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            values[key] = value
        }
        return values
    }

    private func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private var projectsURL: URL { projectsStorageURL }
    private func loadProjects() { guard let data = try? Data(contentsOf: projectsURL), let decoded = try? JSONDecoder().decode([LaravelProject].self, from: data) else { return }; projects = decoded }
    private func saveProjects() { do { try FileManager.default.createDirectory(at: projectsURL.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(projects).write(to: projectsURL, options: .atomic) } catch { statusMessage = "Could not save projects" } }
}

extension String {
    var removingANSIControlSequences: String {
        replacingOccurrences(
            of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
    }

    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nonEmpty: String? { isEmpty ? nil : self }
    var lines: [String] { components(separatedBy: .newlines).filter { !$0.isEmpty } }
}
