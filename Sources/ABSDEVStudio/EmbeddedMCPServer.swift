import AppKit
import Foundation
import Observation
#if canImport(Network)
@preconcurrency import Network
#endif


struct MCPLogEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: String
    let message: String

    init(level: String, message: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.level = level
        self.message = message
    }
}

struct MCPProjectDefinition: Identifiable, Codable, Hashable, Sendable {
    struct Permissions: Codable, Hashable, Sendable {
        var listDirectories = true
        var readFiles = true
        var searchFiles = true
        var writeFiles = false
        var runTests = false

        enum CodingKeys: String, CodingKey { case listDirectories, readFiles, searchFiles, writeFiles, runTests }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            listDirectories = try container.decodeIfPresent(Bool.self, forKey: .listDirectories) ?? true
            readFiles = try container.decodeIfPresent(Bool.self, forKey: .readFiles) ?? true
            searchFiles = try container.decodeIfPresent(Bool.self, forKey: .searchFiles) ?? true
            writeFiles = try container.decodeIfPresent(Bool.self, forKey: .writeFiles) ?? false
            runTests = try container.decodeIfPresent(Bool.self, forKey: .runTests) ?? false
        }
    }

    var schemaVersion = 1
    var id: String
    var name: String
    var enabled = true
    var rootPath: String
    var projectType = "generic"
    var projectDescription = ""
    var include: [String] = ["**/*"]
    var exclude: [String] = [
        ".git/**", ".build/**", "DerivedData/**", "node_modules/**", "vendor/**",
        "storage/**", "bootstrap/cache/**", ".env", "*.key", "*.pem"
    ]
    var permissions = Permissions()

    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, enabled, rootPath, projectType
        case projectDescription = "description"
        case include, exclude, permissions
    }

    init(id: String, name: String, rootPath: String, projectType: String = "generic", projectDescription: String = "") {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.projectType = projectType
        self.projectDescription = projectDescription
    }
}

@MainActor
@Observable
final class EmbeddedMCPServerController {
    var isRunning = false
    var status = "Stopped"
    var lastError: String?
    var requestCount = 0
    var lastRequest = "No requests received"
    var projects: [MCPProjectDefinition] = []
    var activeNavigatorProject: MCPProjectDefinition?
    var logEntries: [MCPLogEntry] = []
    var isLogViewerPresented = false
    var indexingProjectIDs: Set<String> = []
    var indexMessages: [String: String] = [:]
    var port: UInt16 {
        didSet { defaults.set(Int(port), forKey: Keys.port) }
    }
    var startsAutomatically: Bool {
        didSet { defaults.set(startsAutomatically, forKey: Keys.startsAutomatically) }
    }

    let host = "127.0.0.1"
    private let defaults = UserDefaults.standard
    private let projectStore: MCPProjectDefinitionStore
    #if canImport(Network)
    @ObservationIgnored private var listener: NWListener?
    #endif

    private enum Keys {
        static let port = "embeddedMCP.port"
        static let startsAutomatically = "embeddedMCP.startsAutomatically"
    }

    init() {
        let configuredPort = defaults.integer(forKey: Keys.port)
        port = UInt16(configuredPort == 0 ? 8765 : min(max(configuredPort, 1024), 65535))
        startsAutomatically = defaults.object(forKey: Keys.startsAutomatically) as? Bool ?? true
        projectStore = MCPProjectDefinitionStore()
        reloadLog()
        appendLog("INFO", "Embedded MCP controller initialised; definitions folder: \(projectStore.directory.path)")
        reloadProjects()
        if startsAutomatically {
            Task { @MainActor [weak self] in self?.start() }
        }
    }

    var endpoint: String { "http://\(host):\(port)/mcp" }

    var effectiveProjects: [MCPProjectDefinition] {
        guard let active = activeNavigatorProject else { return projects }
        let activeRoot = URL(fileURLWithPath: active.rootPath).standardizedFileURL.resolvingSymlinksInPath().path
        var result = projects.filter { project in
            let root = URL(fileURLWithPath: project.rootPath).standardizedFileURL.resolvingSymlinksInPath().path
            return project.id.caseInsensitiveCompare(active.id) != .orderedSame && root != activeRoot
        }
        result.insert(active, at: 0)
        return result
    }

    func setActiveNavigatorProject(_ project: LaravelProject?) {
        guard let project else {
            activeNavigatorProject = nil
            appendLog("INFO", "Navigator project cleared")
            return
        }
        let type = Self.detectProjectType(at: project.path)
        var definition = MCPProjectDefinition(
            id: Self.slug(project.name),
            name: project.name,
            rootPath: project.path,
            projectType: type,
            projectDescription: "Active navigator project (\(type))"
        )
        definition.rootPath = URL(fileURLWithPath: NSString(string: project.path).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath().path
        activeNavigatorProject = definition
        appendLog("INFO", "Active navigator project set to \(definition.id) at \(definition.rootPath)")
    }
    var projectsDirectory: URL { projectStore.directory }
    var logFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ABSDEVStudio/Logs/mcp.log")
    }

    func start() {
        guard !isRunning else { appendLog("DEBUG", "Start ignored because server is already running"); return }
        appendLog("INFO", "Starting embedded MCP server on \(endpoint)")
        lastError = nil
        #if canImport(Network)
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.status = "Running on \(self.endpoint)"
                        self.appendLog("INFO", "Server listening on \(self.endpoint); \(self.effectiveProjects.filter(\.enabled).count) enabled projects")
                    case .failed(let error):
                        self.isRunning = false
                        self.status = "Failed"
                        self.lastError = error.localizedDescription
                        self.appendLog("ERROR", "Listener failed: \(error.localizedDescription)")
                    case .cancelled:
                        self.isRunning = false
                        self.status = "Stopped"
                    default:
                        break
                    }
                }
            }
            self.listener = listener
            status = "Starting…"
            listener.start(queue: DispatchQueue(label: "uk.co.absdev.studio.mcp.listener", qos: .userInitiated))
        } catch {
            status = "Failed"
            lastError = error.localizedDescription
        }
        #else
        status = "Embedded MCP requires macOS Network.framework"
        #endif
    }

    func stop() {
        #if canImport(Network)
        listener?.cancel()
        listener = nil
        #endif
        isRunning = false
        status = "Stopped"
        appendLog("INFO", "Embedded MCP server stopped")
    }

    func restart() {
        stop()
        start()
    }

    func rebuildIndex(for project: MCPProjectDefinition, force: Bool = true) {
        guard !indexingProjectIDs.contains(project.id) else { return }
        indexingProjectIDs.insert(project.id)
        indexMessages[project.id] = "Indexing…"
        appendLog("INFO", "Indexing project \(project.id) at \(project.rootPath)")
        Task.detached(priority: .userInitiated) { [project] in
            do {
                let snapshot = try MCPProjectIntelligence.shared.rebuild(project: project, force: force)
                let symbols = snapshot.documents.reduce(0) { $0 + $1.symbols.count }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.indexingProjectIDs.remove(project.id)
                    self.indexMessages[project.id] = "\(snapshot.documents.count) files · \(symbols) symbols"
                    self.appendLog("INFO", "Indexed \(project.id): \(snapshot.documents.count) files, \(symbols) symbols")
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.indexingProjectIDs.remove(project.id)
                    self.indexMessages[project.id] = "Failed: \(error.localizedDescription)"
                    self.lastError = error.localizedDescription
                    self.appendLog("ERROR", "Indexing \(project.id) failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func removeIndex(for project: MCPProjectDefinition) {
        do {
            try MCPProjectIntelligence.shared.removeIndex(projectID: project.id)
            indexMessages[project.id] = "Not indexed"
            appendLog("INFO", "Removed index for \(project.id)")
        } catch {
            indexMessages[project.id] = "Failed: \(error.localizedDescription)"
            lastError = error.localizedDescription
            appendLog("ERROR", "Could not remove index for \(project.id): \(error.localizedDescription)")
        }
    }

    func refreshIndexStatuses() {
        for project in projects {
            do {
                let status = try MCPProjectIntelligence.shared.persistedStatus(project: project)
                if status["indexed"] as? Bool == true {
                    let files = status["fileCount"] as? Int ?? 0
                    let symbols = status["symbolCount"] as? Int ?? 0
                    indexMessages[project.id] = "\(files) files · \(symbols) symbols"
                } else {
                    indexMessages[project.id] = "Not indexed"
                }
            } catch {
                indexMessages[project.id] = "Invalid index: \(error.localizedDescription)"
            }
        }
    }

    func openIndexesDirectory() {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ABSDEVStudio/MCPIndexes", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func reloadProjects() {
        do {
            let result = try projectStore.loadAllWithDiagnostics()
            var correctedProjects: [MCPProjectDefinition] = []
            for var project in result.projects {
                let detectedType = Self.detectProjectType(at: project.rootPath)
                if project.projectType.lowercased() != detectedType.lowercased() {
                    appendLog("WARN", "Correcting project type for \(project.id): \(project.projectType) -> \(detectedType)")
                    project.projectType = detectedType
                    project.projectDescription = Self.defaultProjectDescription(for: detectedType)
                    try? projectStore.save(project, replacing: project.id)
                }
                correctedProjects.append(project)
            }
            projects = correctedProjects
            lastError = result.errors.last
            appendLog("INFO", "Loaded \(projects.count) MCP project definitions (\(projects.filter(\.enabled).count) enabled)")
            for project in projects {
                let exists = FileManager.default.fileExists(atPath: project.rootPath)
                appendLog(exists ? "DEBUG" : "WARN", "Project \(project.id): root=\(project.rootPath), enabled=\(project.enabled), exists=\(exists)")
            }
            for error in result.errors { appendLog("ERROR", error) }
            refreshIndexStatuses()
        } catch {
            lastError = error.localizedDescription
            appendLog("ERROR", "Could not load MCP projects: \(error.localizedDescription)")
        }
    }

    func importProjects(_ appProjects: [LaravelProject]) {
        for project in appProjects {
            let slug = Self.slug(project.name)
            let definition = MCPProjectDefinition(
                id: slug,
                name: project.name,
                rootPath: project.path,
                projectType: Self.detectProjectType(at: project.path),
                projectDescription: Self.defaultProjectDescription(for: Self.detectProjectType(at: project.path))
            )
            do { try projectStore.save(definition) } catch { lastError = error.localizedDescription }
        }
        reloadProjects()
    }

    /// Creates definitions only for Studio projects that do not already have one.
    /// Existing JSON remains authoritative so edits made in the MCP editor are preserved.
    func synchroniseProjects(_ appProjects: [LaravelProject]) {
        let existing = (try? projectStore.loadAll()) ?? []
        let existingRoots = Set(existing.map { URL(fileURLWithPath: $0.rootPath).standardizedFileURL.path })
        for project in appProjects {
            let root = URL(fileURLWithPath: project.path).standardizedFileURL.path
            guard !existingRoots.contains(root) else { continue }
            var identifier = Self.slug(project.name)
            if identifier.isEmpty { identifier = UUID().uuidString.lowercased() }
            var suffix = 2
            let ids = Set(((try? projectStore.loadAll()) ?? []).map(\.id))
            let base = identifier
            while ids.contains(identifier) {
                identifier = "\(base)-\(suffix)"
                suffix += 1
            }
            let definition = MCPProjectDefinition(
                id: identifier,
                name: project.name,
                rootPath: project.path,
                projectType: Self.detectProjectType(at: project.path),
                projectDescription: Self.defaultProjectDescription(for: Self.detectProjectType(at: project.path))
            )
            do { try projectStore.save(definition) } catch { lastError = error.localizedDescription }
        }
        reloadProjects()
    }


    private static func detectProjectType(at rawPath: String) -> String {
        let path = NSString(string: rawPath).expandingTildeInPath
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        func exists(_ relative: String) -> Bool { fm.fileExists(atPath: root.appendingPathComponent(relative).path) }

        if exists("Package.swift") || ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
            return "swift"
        }
        if exists("artisan") || exists("composer.json") { return "laravel" }
        if exists("pyproject.toml") || exists("requirements.txt") || exists("setup.py") { return "python" }
        if exists("Cargo.toml") { return "rust" }
        if exists("go.mod") { return "go" }
        if exists("package.json") { return "javascript" }
        return "generic"
    }

    private static func defaultProjectDescription(for type: String) -> String {
        switch type.lowercased() {
        case "swift": return "Swift/Xcode project managed by ABSDEV Studio"
        case "laravel": return "Laravel project managed by ABSDEV Studio"
        case "python": return "Python project managed by ABSDEV Studio"
        case "rust": return "Rust project managed by ABSDEV Studio"
        case "go": return "Go project managed by ABSDEV Studio"
        case "javascript": return "JavaScript/TypeScript project managed by ABSDEV Studio"
        default: return "Local project managed by ABSDEV Studio"
        }
    }

    func saveProject(_ definition: MCPProjectDefinition, replacing originalID: String? = nil) throws {
        let trimmedID = definition.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRoot = definition.rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw MCPProjectDefinitionError.validation("Project name is required.") }
        let requestedID = trimmedID.isEmpty ? trimmedName : trimmedID
        let normalisedID = Self.slug(requestedID)
        guard !normalisedID.isEmpty else { throw MCPProjectDefinitionError.validation("Enter a project name or ID containing letters or numbers.") }
        guard !trimmedRoot.isEmpty else { throw MCPProjectDefinitionError.validation("Project root path is required.") }
        let expandedRoot = NSString(string: trimmedRoot).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedRoot, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MCPProjectDefinitionError.validation("The project root folder does not exist: \(expandedRoot)")
        }
        var updated = definition
        updated.id = normalisedID
        updated.name = trimmedName
        updated.rootPath = URL(fileURLWithPath: expandedRoot).standardizedFileURL.resolvingSymlinksInPath().path
        try projectStore.save(updated, replacing: originalID)
        appendLog("INFO", "Saved MCP project definition \(updated.id) -> \(updated.rootPath)")
        reloadProjects()
    }

    func grantFullSourceAccess(to definition: MCPProjectDefinition) throws {
        var updated = definition
        updated.enabled = true
        updated.permissions.listDirectories = true
        updated.permissions.readFiles = true
        updated.permissions.searchFiles = true
        try saveProject(updated, replacing: definition.id)
        appendLog("INFO", "Granted full MCP source access to \(updated.id)")
    }

    func deleteProject(id: String) throws {
        let removedFiles = try projectStore.delete(id: id)
        try? MCPProjectIntelligence.shared.removeIndex(projectID: id)
        indexMessages[id] = nil
        indexingProjectIDs.remove(id)
        appendLog("INFO", "Deleted MCP project definition \(id) from \(removedFiles.joined(separator: ", "))")
        reloadProjects()
    }

    func openProjectsDirectory() {
        try? FileManager.default.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(projectsDirectory)
    }

    func copyEndpoint() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(endpoint, forType: .string)
    }

    func appendLog(_ level: String, _ message: String) {
        let entry = MCPLogEntry(level: level, message: message)
        logEntries.append(entry)
        if logEntries.count > 1000 { logEntries.removeFirst(logEntries.count - 1000) }
        let formatter = ISO8601DateFormatter()
        let line = "[\(formatter.string(from: entry.timestamp))] [\(level)] \(message)\n"
        do {
            try FileManager.default.createDirectory(at: logFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logFileURL.path) {
                try Data(line.utf8).write(to: logFileURL, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: logFileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
            }
        } catch {
            lastError = "MCP logging failed: \(error.localizedDescription)"
        }
    }

    func clearLog() {
        logEntries.removeAll()
        try? FileManager.default.removeItem(at: logFileURL)
        appendLog("INFO", "MCP log cleared")
    }

    func openLogFile() {
        if !FileManager.default.fileExists(atPath: logFileURL.path) { appendLog("INFO", "MCP log file created") }
        NSWorkspace.shared.open(logFileURL)
    }

    private func reloadLog() {
        guard let text = try? String(contentsOf: logFileURL, encoding: .utf8) else { return }
        logEntries = text.components(separatedBy: .newlines).suffix(500).compactMap { line in
            guard !line.isEmpty else { return nil }
            return MCPLogEntry(level: "HISTORY", message: line)
        }
    }

    private static func slug(_ text: String) -> String {
        let allowed = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : "-" }
        return String(allowed).replacingOccurrences(of: "-+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    #if canImport(Network)
    private func accept(_ connection: NWConnection) {
        appendLog("DEBUG", "Accepted MCP client connection from \(String(describing: connection.endpoint))")
        connection.start(queue: DispatchQueue(label: "uk.co.absdev.studio.mcp.connection", qos: .userInitiated))
        receive(on: connection, accumulated: Data())
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                var buffer = accumulated
                if let data { buffer.append(data) }
                if let error {
                    connection.cancel()
                    self.lastError = error.localizedDescription
                    self.appendLog("ERROR", "Connection receive failed: \(error.localizedDescription)")
                    return
                }
                if let request = HTTPRequest.parse(buffer) {
                    self.handle(request, connection: connection)
                } else if isComplete || buffer.count > 4_194_304 {
                    self.send(status: 400, body: Self.jsonError(id: nil, code: -32700, message: "Invalid HTTP request"), on: connection)
                } else {
                    self.receive(on: connection, accumulated: buffer)
                }
            }
        }
    }

    private func handle(_ request: HTTPRequest, connection: NWConnection) {
        requestCount += 1
        lastRequest = "\(request.method) \(request.path)"
        appendLog("INFO", "HTTP \(request.method) \(request.path), bodyBytes=\(request.body.count)")
        guard request.method == "POST", request.path == "/mcp" else {
            send(status: 404, body: Self.jsonError(id: nil, code: -32601, message: "Use POST /mcp"), on: connection)
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let method = object["method"] as? String else {
            send(status: 400, body: Self.jsonError(id: nil, code: -32700, message: "Invalid JSON-RPC request"), on: connection)
            return
        }
        let id = object["id"]
        appendLog("DEBUG", "JSON-RPC method=\(method), id=\(String(describing: id))")
        let params = object["params"] as? [String: Any] ?? [:]
        if id == nil {
            send(status: 202, body: Data(), on: connection)
            return
        }
        do {
            let result = try route(method: method, params: params)
            appendLog("INFO", "JSON-RPC \(method) completed")
            send(status: 200, body: Self.jsonResult(id: id, result: result), on: connection)
        } catch {
            appendLog("ERROR", "JSON-RPC \(method) failed: \(error.localizedDescription)")
            send(status: 200, body: Self.jsonError(id: id, code: -32000, message: error.localizedDescription), on: connection)
        }
    }

    private func route(method: String, params: [String: Any]) throws -> Any {
        switch method {
        case "initialize":
            return [
                "protocolVersion": "2025-11-25",
                "capabilities": ["tools": ["listChanged": true]],
                "serverInfo": ["name": "ABSDEV Studio Embedded MCP", "version": "1.0"]
            ]
        case "tools/list":
            reloadProjectsForRequest()
            return ["tools": MCPToolRouter.toolDefinitions]
        case "tools/call":
            reloadProjectsForRequest()
            guard let name = params["name"] as? String else { throw MCPServerError.invalidArguments("Missing tool name") }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            appendLog("INFO", "Tool call \(name), arguments=\(Self.redactedArguments(arguments))")
            return try MCPToolRouter(projects: effectiveProjects, logger: { [weak self] level, message in self?.appendLog(level, message) }).call(name: name, arguments: arguments)
        case "ping":
            return [:]
        default:
            throw MCPServerError.methodNotFound(method)
        }
    }

    private func reloadProjectsForRequest() {
        do {
            let result = try projectStore.loadAllWithDiagnostics()
            projects = result.projects
            for error in result.errors { appendLog("ERROR", error) }
            refreshIndexStatuses()
            appendLog("DEBUG", "Refreshed MCP project definitions for request: \(projects.count) loaded")
        } catch {
            appendLog("ERROR", "Could not refresh MCP projects for request: \(error.localizedDescription)")
        }
    }

    private func send(status: Int, body: Data, on connection: NWConnection) {
        let reason = status == 200 ? "OK" : status == 202 ? "Accepted" : status == 400 ? "Bad Request" : "Not Found"
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: application/json\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
    #endif

    private static func redactedArguments(_ arguments: [String: Any]) -> String {
        var safe = arguments
        for key in safe.keys where key.lowercased().contains("token") || key.lowercased().contains("password") || key.lowercased().contains("secret") { safe[key] = "<redacted>" }
        guard let data = try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func jsonResult(id: Any?, result: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])) ?? Data()
    }

    private static func jsonError(id: Any?, code: Int, message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])) ?? Data()
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let body: Data

    static func parse(_ data: Data) -> HTTPRequest? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: data[..<separator.lowerBound], encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }
        let lengthLine = lines.first { $0.lowercased().hasPrefix("content-length:") }
        let length = Int(lengthLine?.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
        let bodyStart = separator.upperBound
        guard data.count >= bodyStart + length else { return nil }
        return HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), body: data.subdata(in: bodyStart..<(bodyStart + length)))
    }
}

private struct MCPProjectDefinitionStore {
    let directory: URL

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ABSDEVStudio/MCPProjects", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func loadAll() throws -> [MCPProjectDefinition] { try loadAllWithDiagnostics().projects }

    func loadAllWithDiagnostics() throws -> (projects: [MCPProjectDefinition], errors: [String]) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "json" }
        var projects: [MCPProjectDefinition] = []
    var activeNavigatorProject: MCPProjectDefinition?
        var errors: [String] = []
        for url in urls {
            do { projects.append(try JSONDecoder().decode(MCPProjectDefinition.self, from: Data(contentsOf: url))) }
            catch { errors.append("Invalid MCP JSON \(url.lastPathComponent): \(error.localizedDescription)") }
        }
        return (projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }, errors)
    }

    func save(_ definition: MCPProjectDefinition, replacing originalID: String? = nil) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(definition.id).json")
        if let originalID, originalID != definition.id {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(originalID).json"))
        }
        let data = try JSONEncoder.pretty.encode(definition)
        try data.write(to: destination, options: .atomic)
    }

    @discardableResult
    func delete(id: String) throws -> [String] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "json" }

        var matches: [URL] = []
        for url in urls {
            if url.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(id) == .orderedSame {
                matches.append(url)
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let definition = try? JSONDecoder().decode(MCPProjectDefinition.self, from: data) else { continue }
            if definition.id.caseInsensitiveCompare(id) == .orderedSame {
                matches.append(url)
            }
        }

        guard !matches.isEmpty else {
            throw MCPProjectDefinitionError.validation("No JSON definition could be found for project ID \(id).")
        }

        var removed: [String] = []
        for url in Set(matches) {
            try FileManager.default.removeItem(at: url)
            removed.append(url.lastPathComponent)
        }
        return removed.sorted()
    }
}

private enum MCPProjectDefinitionError: LocalizedError {
    case validation(String)
    var errorDescription: String? {
        switch self { case .validation(let message): message }
    }
}

private struct MCPToolRouter {
    let projects: [MCPProjectDefinition]
    let logger: (String, String) -> Void

    static let toolDefinitions: [[String: Any]] = [
        tool("projects_list", "List configured projects", "Returns enabled JSON-defined projects served by ABSDEV Studio.", properties: [:]),
        tool("project_tree", "Project tree", "Lists files and folders below a project-relative path.", properties: ["project": string("Project id"), "path": string("Relative path"), "depth": integer("Maximum depth")], required: ["project"]),
        tool("project_read_file", "Read project file", "Reads a UTF-8 text file from a configured project.", properties: ["project": string("Project id"), "path": string("Relative file path"), "maxBytes": integer("Maximum bytes")], required: ["project", "path"]),
        tool("project_search", "Search project", "Searches text files in a configured project.", properties: ["project": string("Project id"), "query": string("Text to find"), "maxResults": integer("Maximum results")], required: ["project", "query"]),
        tool("ask_project", "Ask a project", "Primary free-text tool. Accepts a natural-language question and returns ranked source code plus project intelligence in one response. The project may be an id or display name; it may be omitted when only one project is enabled.", properties: ["project": string("Optional project id or name"), "question": string("Free-text question about the project"), "maxFiles": integer("Maximum source files to return")], required: ["question"]),
        tool("project_ask_context", "Get source context for a question", "Compatibility alias for ask_project.", properties: ["project": string("Project id or name"), "question": string("Question about the project source code"), "maxFiles": integer("Maximum source files to return")], required: ["question"]),
        tool("find_definition", "Find symbol definition", "Finds likely class, struct, enum, protocol, function, method, route or variable definitions.", properties: ["project": string("Optional project id or name"), "symbol": string("Symbol to find"), "maxResults": integer("Maximum results")], required: ["symbol"]),
        tool("find_references", "Find symbol references", "Finds usages of a symbol across project source files.", properties: ["project": string("Optional project id or name"), "symbol": string("Symbol to find"), "maxResults": integer("Maximum results")], required: ["symbol"]),
        tool("project_overview", "Project overview", "Returns framework, manifests, important directories, dependencies, routes, tests and Git status for a project.", properties: ["project": string("Optional project id or name")]),
        tool("project_git_status", "Git status", "Returns read-only Git branch and working-tree status.", properties: ["project": string("Optional project id or name")]),
        tool("project_laravel_routes", "Laravel routes", "Returns Laravel route declarations found in route files without executing application code.", properties: ["project": string("Optional project id or name"), "maxResults": integer("Maximum routes")]),
        tool("project_tests", "Project tests", "Lists tests and matches test names/content using optional free text.", properties: ["project": string("Optional project id or name"), "query": string("Optional test search"), "maxResults": integer("Maximum results")]),
        tool("project_index_status", "Project index status", "Returns a source inventory and language breakdown generated from the current local files.", properties: ["project": string("Optional project id or name")]),
        tool("project_access_status", "Check project access", "Reports whether the project root exists and which MCP source permissions are enabled.", properties: ["project": string("Project id or name")]),
        tool("refresh_project_index", "Refresh project index", "Incrementally refreshes the persistent source and symbol index. Set force to rebuild all entries.", properties: ["project": string("Optional project id or name"), "force": boolean("Rebuild every indexed file")]),
        tool("semantic_search", "Semantic project search", "Ranks source files and symbols for a natural-language query using the local persistent index.", properties: ["project": string("Optional project id or name"), "query": string("Natural-language search"), "maxResults": integer("Maximum results")], required: ["query"]),
        tool("project_dependency_graph", "Dependency graph", "Returns import/use/require dependency edges found across project source.", properties: ["project": string("Optional project id or name"), "maxResults": integer("Maximum edges")]),
        tool("conversation_ask_project", "Ask with follow-up memory", "Free-text project question with short-lived conversation memory. Supply the same session id for follow-up questions.", properties: ["project": string("Optional project id or name"), "session": string("Conversation session id"), "question": string("Natural-language question"), "maxFiles": integer("Maximum source files")], required: ["session", "question"]),
        tool("preview_project_edit", "Preview exact source edit", "Produces a bounded diff preview for an exact text replacement without modifying the project.", properties: ["project": string("Optional project id or name"), "path": string("Relative file path"), "find": string("Exact text to replace"), "replace": string("Replacement text")], required: ["path", "find", "replace"]),
        tool("apply_project_edit", "Apply approved source edit", "Applies an exact replacement with backup and change-detection hash. Requires writeFiles permission.", properties: ["project": string("Optional project id or name"), "path": string("Relative file path"), "find": string("Exact text to replace"), "replace": string("Replacement text"), "expectedHash": string("Optional hash returned by project_file_hash")], required: ["path", "find", "replace"]),
        tool("project_file_hash", "Project file hash", "Returns a stable file hash for safe edit change detection.", properties: ["project": string("Optional project id or name"), "path": string("Relative file path")], required: ["path"]),
        tool("run_project_tests", "Run project tests", "Runs a bounded framework test command selected by ABSDEV Studio. Requires runTests permission; arbitrary shell commands are not accepted.", properties: ["project": string("Optional project id or name"), "filter": string("Optional test filter")])
    ]

    func call(name: String, arguments: [String: Any]) throws -> [String: Any] {
        logger("DEBUG", "Routing tool \(name) across \(projects.filter(\.enabled).count) enabled projects")
        let value: Any
        switch name {
        case "projects_list":
            value = projects.filter(\.enabled).map { ["id": $0.id, "name": $0.name, "rootPath": $0.rootPath, "projectType": $0.projectType, "description": $0.projectDescription] }
        case "project_tree":
            let project = try resolve(arguments)
            value = try tree(project: project, relativePath: arguments["path"] as? String ?? "", maxDepth: min(max(arguments["depth"] as? Int ?? 3, 1), 8))
        case "project_read_file":
            let project = try resolve(arguments)
            value = try read(project: project, relativePath: try requiredString("path", arguments), maxBytes: min(max(arguments["maxBytes"] as? Int ?? 262_144, 1_024), 1_048_576))
        case "project_search":
            let project = try resolve(arguments)
            value = try search(project: project, query: try requiredString("query", arguments), maxResults: min(max(arguments["maxResults"] as? Int ?? 50, 1), 200))
        case "ask_project", "project_ask_context":
            let project = try resolveOptional(arguments)
            try requireSourceAccess(project)
            value = try askProject(project: project, question: try requiredString("question", arguments), maxFiles: min(max(arguments["maxFiles"] as? Int ?? 14, 1), 30))
        case "find_definition":
            let project = try resolveOptional(arguments)
            try requireSourceAccess(project)
            value = try symbolMatches(project: project, symbol: try requiredString("symbol", arguments), definitionsOnly: true, maxResults: min(max(arguments["maxResults"] as? Int ?? 50, 1), 200))
        case "find_references":
            let project = try resolveOptional(arguments)
            try requireSourceAccess(project)
            value = try symbolMatches(project: project, symbol: try requiredString("symbol", arguments), definitionsOnly: false, maxResults: min(max(arguments["maxResults"] as? Int ?? 100, 1), 300))
        case "project_overview":
            let project = try resolveOptional(arguments)
            value = try projectOverview(project)
        case "project_git_status":
            value = gitStatus(try resolveOptional(arguments))
        case "project_laravel_routes":
            let project = try resolveOptional(arguments)
            try requireSourceAccess(project)
            value = try laravelRoutes(project, maxResults: min(max(arguments["maxResults"] as? Int ?? 200, 1), 500))
        case "project_tests":
            let project = try resolveOptional(arguments)
            try requireSourceAccess(project)
            value = try tests(project, query: arguments["query"] as? String ?? "", maxResults: min(max(arguments["maxResults"] as? Int ?? 200, 1), 500))
        case "project_index_status":
            value = try MCPProjectIntelligence.shared.persistedStatus(project: try resolveOptional(arguments))
        case "project_access_status":
            let project = try resolveOptional(arguments)
            value = [
                "id": project.id,
                "name": project.name,
                "rootPath": project.rootPath,
                "rootExists": FileManager.default.fileExists(atPath: project.rootPath),
                "enabled": project.enabled,
                "permissions": [
                    "listDirectories": project.permissions.listDirectories,
                    "readFiles": project.permissions.readFiles,
                    "searchFiles": project.permissions.searchFiles,
                    "writeFiles": project.permissions.writeFiles,
                    "runTests": project.permissions.runTests
                ]
            ]
        case "refresh_project_index":
            let project = try resolveOptional(arguments)
            try requireSourceAccess(project)
            let snapshot = try MCPProjectIntelligence.shared.rebuild(project: project, force: arguments["force"] as? Bool ?? false)
            value = ["project": project.id, "generatedAt": ISO8601DateFormatter().string(from: snapshot.generatedAt), "fileCount": snapshot.documents.count, "symbolCount": snapshot.documents.reduce(0) { $0 + $1.symbols.count }]
        case "semantic_search":
            let project = try resolveOptional(arguments)
            try requireSourceAccess(project)
            value = MCPProjectIntelligence.shared.semanticMatches(project: project, files: try sourceFiles(project), question: try requiredString("query", arguments), limit: min(max(arguments["maxResults"] as? Int ?? 30, 1), 200))
        case "project_dependency_graph":
            let project = try resolveOptional(arguments)
            try requireSourceAccess(project)
            value = MCPProjectIntelligence.shared.dependencyGraph(project: project, files: try sourceFiles(project), limit: min(max(arguments["maxResults"] as? Int ?? 500, 1), 2_000))
        case "conversation_ask_project":
            let project = try resolveOptional(arguments)
            try requireSourceAccess(project)
            let session = try requiredString("session", arguments)
            let question = try requiredString("question", arguments)
            let history = MCPProjectIntelligence.shared.conversationContext(session: session)
            MCPProjectIntelligence.shared.remember(session: session, question: question)
            var answer = try askProject(project: project, question: (history + [question]).joined(separator: "\nFollow-up: "), maxFiles: min(max(arguments["maxFiles"] as? Int ?? 14, 1), 30))
            answer["session"] = session
            answer["conversationHistory"] = history + [question]
            value = answer
        case "preview_project_edit":
            let project = try resolveOptional(arguments)
            try requireSourceAccess(project)
            value = try MCPProjectIntelligence.shared.previewEdit(project: project, relativePath: try requiredString("path", arguments), find: try requiredString("find", arguments), replace: arguments["replace"] as? String ?? "")
        case "apply_project_edit":
            let project = try resolveOptional(arguments)
            guard project.permissions.writeFiles else { throw MCPServerError.permissionDenied("Writing is disabled for project \(project.id). Enable Write files in Settings → MCP → Edit Project.") }
            value = try MCPProjectIntelligence.shared.applyEdit(project: project, relativePath: try requiredString("path", arguments), find: try requiredString("find", arguments), replace: arguments["replace"] as? String ?? "", expectedSHA256: arguments["expectedHash"] as? String)
        case "project_file_hash":
            let project = try resolveOptional(arguments)
            try requireSourceAccess(project)
            value = ["path": try requiredString("path", arguments), "hash": try MCPProjectIntelligence.shared.fileHash(project: project, relativePath: try requiredString("path", arguments))]
        case "run_project_tests":
            let project = try resolveOptional(arguments)
            guard project.permissions.runTests else { throw MCPServerError.permissionDenied("Test execution is disabled for project \(project.id). Enable Run tests in Settings → MCP → Edit Project.") }
            value = runTests(project, filter: arguments["filter"] as? String ?? "")
        default:
            throw MCPServerError.methodNotFound(name)
        }
        var data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        let maximumToolResponseBytes = 350_000
        if data.count > maximumToolResponseBytes {
            logger("WARN", "Tool \(name) response was \(data.count) bytes; returning a bounded summary for client compatibility")
            let summary: [String: Any] = [
                "project": (value as? [String: Any])?["project"] ?? NSNull(),
                "question": (value as? [String: Any])?["question"] ?? NSNull(),
                "message": "The project was accessed successfully, but the complete context exceeded the MCP client-safe response limit. Use semantic_search, project_read_file, find_definition, or ask_project with a smaller maxFiles value for more detail.",
                "sourceFiles": Array(((value as? [String: Any])?["sourceFiles"] as? [String] ?? []).prefix(2_000)),
                "sourceFileCount": (value as? [String: Any])?["sourceFileCount"] ?? NSNull(),
                "overview": (value as? [String: Any])?["overview"] ?? NSNull(),
                "definitions": Array(((value as? [String: Any])?["definitions"] as? [[String: Any]] ?? []).prefix(20)),
                "references": Array(((value as? [String: Any])?["references"] as? [[String: Any]] ?? []).prefix(20)),
                "semanticMatches": Array(((value as? [String: Any])?["semanticMatches"] as? [[String: Any]] ?? []).prefix(20))
            ]
            data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        }
        logger("DEBUG", "Tool \(name) response size=\(data.count) bytes")
        return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "isError": false]
    }

    private func resolveOptional(_ arguments: [String: Any]) throws -> MCPProjectDefinition {
        let enabled = projects.filter(\.enabled)
        let requested = (arguments["project"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if requested.isEmpty {
            guard enabled.count == 1, let project = enabled.first else {
                throw MCPServerError.invalidArguments("Specify project. Enabled projects: " + enabled.map { "\($0.id) (\($0.name))" }.joined(separator: ", "))
            }
            var resolved = project
            resolved.rootPath = URL(fileURLWithPath: NSString(string: project.rootPath).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
            guard FileManager.default.fileExists(atPath: resolved.rootPath) else { throw MCPServerError.projectRootMissing(resolved.rootPath) }
            return resolved
        }
        let needle = requested.lowercased()
        guard let project = enabled.first(where: { $0.id.lowercased() == needle || $0.name.lowercased() == needle }) else {
            throw MCPServerError.projectNotFound(requested)
        }
        var resolved = project
        resolved.rootPath = URL(fileURLWithPath: NSString(string: project.rootPath).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
        guard FileManager.default.fileExists(atPath: resolved.rootPath) else { throw MCPServerError.projectRootMissing(resolved.rootPath) }
        logger("DEBUG", "Resolved free-text project \(resolved.id) at \(resolved.rootPath)")
        return resolved
    }

    private func requireSourceAccess(_ project: MCPProjectDefinition) throws {
        // Enabled MCP projects always permit read-only source discovery. Write and test execution remain opt-in.
    }

    private func resolve(_ arguments: [String: Any]) throws -> MCPProjectDefinition {
        let id = try requiredString("project", arguments)
        let needle = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard var project = projects.first(where: { $0.enabled && ($0.id.lowercased() == needle || $0.name.lowercased() == needle) }) else { logger("WARN", "Project resolution failed for id=\(id)"); throw MCPServerError.projectNotFound(id) }
        project.rootPath = URL(fileURLWithPath: NSString(string: project.rootPath).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
        guard FileManager.default.fileExists(atPath: project.rootPath) else { throw MCPServerError.projectRootMissing(project.rootPath) }
        logger("DEBUG", "Resolved project \(project.id) at \(project.rootPath)")
        return project
    }

    private func safeURL(project: MCPProjectDefinition, relativePath: String) throws -> URL {
        let root = URL(fileURLWithPath: project.rootPath, isDirectory: true).standardizedFileURL
        let target = root.appendingPathComponent(relativePath).standardizedFileURL
        guard target.path == root.path || target.path.hasPrefix(root.path + "/") else { throw MCPServerError.pathTraversal }
        return target
    }

    private func tree(project: MCPProjectDefinition, relativePath: String, maxDepth: Int) throws -> [[String: Any]] {
        let root = try safeURL(project: project, relativePath: relativePath)
        let rootDepth = root.pathComponents.count
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return [] }
        var result: [[String: Any]] = []
        for case let url as URL in enumerator {
            let depth = url.pathComponents.count - rootDepth
            if depth > maxDepth { enumerator.skipDescendants(); continue }
            let relative = String(url.path.dropFirst(URL(fileURLWithPath: project.rootPath).standardizedFileURL.path.count + 1))
            if isExcluded(relative, project: project) { if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator.skipDescendants() }; continue }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            result.append(["path": relative, "type": values.isDirectory == true ? "directory" : "file", "size": values.fileSize ?? 0])
            if result.count >= 5_000 { break }
        }
        return result
    }

    private func read(project: MCPProjectDefinition, relativePath: String, maxBytes: Int) throws -> [String: Any] {
        let url = try safeURL(project: project, relativePath: relativePath)
        logger("INFO", "Reading project file \(project.id):\(relativePath), maxBytes=\(maxBytes)")
        guard !isExcluded(relativePath, project: project) else { throw MCPServerError.permissionDenied("The path \(relativePath) is excluded by the project JSON definition.") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { throw MCPServerError.notTextFile(relativePath) }
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ["project": project.id, "path": relativePath, "content": text, "truncated": fileSize > data.count]
    }

    private func search(project: MCPProjectDefinition, query: String, maxResults: Int) throws -> [[String: Any]] {
        logger("INFO", "Searching project \(project.id) for query=\(query), maxResults=\(maxResults)")
        let root = URL(fileURLWithPath: project.rootPath, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return [] }
        var matches: [[String: Any]] = []
        for case let url as URL in enumerator {
            let relative = String(url.path.dropFirst(root.standardizedFileURL.path.count + 1))
            if isExcluded(relative, project: project) { if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator.skipDescendants() }; continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= 1_048_576, let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, line) in text.components(separatedBy: .newlines).enumerated() where line.localizedCaseInsensitiveContains(query) {
                matches.append(["path": relative, "line": index + 1, "text": String(line.prefix(500))])
                if matches.count >= maxResults { return matches }
            }
        }
        return matches
    }

    private func askContext(project: MCPProjectDefinition, question: String, maxFiles: Int) throws -> [String: Any] {
        let root = URL(fileURLWithPath: project.rootPath, isDirectory: true).standardizedFileURL
        let terms = question.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
        let preferredExtensions = Set(["swift", "php", "blade.php", "js", "ts", "tsx", "jsx", "py", "rb", "java", "kt", "kts", "go", "rs", "c", "h", "cpp", "hpp", "cs", "json", "xml", "yml", "yaml", "toml", "md"])
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return ["project": project.id, "question": question, "files": []] }
        var candidates: [(score: Int, url: URL, relative: String)] = []
        for case let url as URL in enumerator {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            if isExcluded(relative, project: project) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator.skipDescendants() }
                continue
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= 1_500_000 else { continue }
            let lowerPath = relative.lowercased()
            let ext = url.pathExtension.lowercased()
            guard preferredExtensions.contains(ext) || lowerPath.hasSuffix(".blade.php") || url.lastPathComponent == "Package.swift" else { continue }
            var score = terms.reduce(0) { $0 + (lowerPath.contains($1) ? 10 : 0) }
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let lowerText = String(text.prefix(250_000)).lowercased()
                score += terms.reduce(0) { $0 + min(lowerText.components(separatedBy: $1).count - 1, 8) }
            }
            if score > 0 { candidates.append((score, url, relative)) }
        }
        if candidates.isEmpty {
            candidates = try fallbackSourceFiles(root: root, project: project, limit: maxFiles)
        }
        let selected = candidates.sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.relative < rhs.relative : lhs.score > rhs.score
        }.prefix(maxFiles)
        var files: [[String: Any]] = []
        var totalBytes = 0
        for candidate in selected {
            guard totalBytes < 180_000 else { break }
            guard let data = try? Data(contentsOf: candidate.url, options: [.mappedIfSafe]) else { continue }
            let clipped = data.prefix(min(data.count, 24_000, 180_000 - totalBytes))
            guard let text = String(data: clipped, encoding: .utf8) else { continue }
            totalBytes += clipped.count
            files.append(["path": candidate.relative, "score": candidate.score, "content": text, "truncated": data.count > clipped.count])
        }
        logger("INFO", "Built source context for \(project.id): question=\(question), files=\(files.count), bytes=\(totalBytes)")
        return ["project": project.id, "question": question, "files": files]
    }

    private func askProject(project: MCPProjectDefinition, question: String, maxFiles: Int) throws -> [String: Any] {
        let context = try askContext(project: project, question: question, maxFiles: maxFiles)
        let terms = question.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 }
        var definitions: [[String: Any]] = []
        var references: [[String: Any]] = []
        for term in terms.prefix(5) {
            definitions.append(contentsOf: try symbolMatches(project: project, symbol: term, definitionsOnly: true, maxResults: 8))
            references.append(contentsOf: try symbolMatches(project: project, symbol: term, definitionsOnly: false, maxResults: 8))
        }
        let allFiles = try sourceFiles(project)
        let overview = try projectOverview(project)
        let routeHints = project.projectType.lowercased().contains("laravel") ? try laravelRoutes(project, maxResults: 80) : []
        let testHints = try tests(project, query: terms.first ?? "", maxResults: 40)
        let semantic = MCPProjectIntelligence.shared.semanticMatches(project: project, files: allFiles, question: question, limit: maxFiles)
        let structuredDefinitions = terms.prefix(5).flatMap { MCPProjectIntelligence.shared.definitions(project: project, files: allFiles, symbol: $0, limit: 12) }
        let dependencyEdges = MCPProjectIntelligence.shared.dependencyGraph(project: project, files: allFiles, limit: 80)
        let knowledge = projectKnowledge(project: project, question: question, maxResults: 4)
        let sourceInventory = allFiles.prefix(2_000).map { $0.1 }
        logger("INFO", "ask_project completed for \(project.id): question=\(question), definitions=\(definitions.count), references=\(references.count)")
        return [
            "project": project.id,
            "projectName": project.name,
            "question": question,
            "answerInstruction": "Answer the user's free-text question from the supplied local source evidence. Cite file paths and line numbers. State clearly when evidence is incomplete.",
            "overview": overview,
            "sourceFiles": sourceInventory,
            "sourceFileCount": allFiles.count,
            "sourceContext": context,
            "definitions": Array((structuredDefinitions + definitions).prefix(20)),
            "references": Array(references.prefix(20)),
            "semanticMatches": semantic,
            "dependencyGraph": dependencyEdges,
            "knowledgeBaseAndDocumentation": knowledge,
            "routes": routeHints,
            "tests": testHints
        ]
    }

    private func sourceFiles(_ project: MCPProjectDefinition, maximumBytes: Int = 1_500_000) throws -> [(URL, String)] {
        let root = URL(fileURLWithPath: project.rootPath, isDirectory: true).standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        let extensions = Set(["swift", "php", "js", "ts", "tsx", "jsx", "py", "rb", "java", "kt", "kts", "go", "rs", "c", "h", "cpp", "hpp", "cs", "json", "xml", "yml", "yaml", "toml", "md", "sql"])
        var files: [(URL, String)] = []
        for case let url as URL in enumerator {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            if isExcluded(relative, project: project) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator.skipDescendants() }
                continue
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            let lower = relative.lowercased()
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= maximumBytes,
                  extensions.contains(url.pathExtension.lowercased()) || lower.hasSuffix(".blade.php") || url.lastPathComponent == "Package.swift" else { continue }
            files.append((url, relative))
        }
        return files
    }

    private func symbolMatches(project: MCPProjectDefinition, symbol: String, definitionsOnly: Bool, maxResults: Int) throws -> [[String: Any]] {
        let escaped = NSRegularExpression.escapedPattern(for: symbol)
        let definitionPattern = "(?i)\\b(class|struct|enum|protocol|actor|interface|trait|function|func|def|fn|let|var|const|typealias)\\s+" + escaped + "\\b|Route::[A-Za-z]+\\([^\\n]*" + escaped
        let definitionRegex = try? NSRegularExpression(pattern: definitionPattern)
        var output: [[String: Any]] = []
        for (url, relative) in try sourceFiles(project) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                guard line.localizedCaseInsensitiveContains(symbol) else { continue }
                if definitionsOnly {
                    let range = NSRange(line.startIndex..<line.endIndex, in: line)
                    guard definitionRegex?.firstMatch(in: line, range: range) != nil else { continue }
                }
                output.append(["path": relative, "line": index + 1, "text": String(line.prefix(700)), "kind": definitionsOnly ? "definition" : "reference"])
                if output.count >= maxResults { return output }
            }
        }
        return output
    }

    private func projectOverview(_ project: MCPProjectDefinition) throws -> [String: Any] {
        let root = URL(fileURLWithPath: project.rootPath, isDirectory: true)
        let manifests = ["composer.json", "package.json", "Package.swift", "pyproject.toml", "requirements.txt", "Cargo.toml", "go.mod"]
            .filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
        let important = ["app", "Modules", "Sources", "Tests", "tests", "routes", "resources", "src", "lib", "database"]
            .filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
        return [
            "id": project.id, "name": project.name, "type": project.projectType,
            "description": project.projectDescription, "rootPath": project.rootPath,
            "manifests": manifests, "importantDirectories": important,
            "git": gitStatus(project), "index": try indexStatus(project)
        ]
    }

    private func gitStatus(_ project: MCPProjectDefinition) -> [String: Any] {
        let result = runReadOnly(["/usr/bin/git", "-C", project.rootPath, "status", "--short", "--branch"], timeout: 8)
        return ["available": result.exitCode == 0, "output": result.output, "exitCode": result.exitCode]
    }

    private func laravelRoutes(_ project: MCPProjectDefinition, maxResults: Int) throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        for (url, relative) in try sourceFiles(project) where relative.hasPrefix("routes/") || relative.contains("/Routes/") {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (lineNumber, line) in text.components(separatedBy: .newlines).enumerated() where line.contains("Route::") {
                result.append(["path": relative, "line": lineNumber + 1, "declaration": String(line.trimmingCharacters(in: .whitespaces).prefix(900))])
                if result.count >= maxResults { return result }
            }
        }
        return result
    }

    private func tests(_ project: MCPProjectDefinition, query: String, maxResults: Int) throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        let needle = query.lowercased()
        for (url, relative) in try sourceFiles(project) {
            let lower = relative.lowercased()
            guard lower.contains("test") || lower.contains("spec") else { continue }
            if needle.isEmpty || lower.contains(needle) {
                result.append(["path": relative, "line": 1, "text": "Test file"])
            } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                for (lineNumber, line) in text.components(separatedBy: .newlines).enumerated() where line.lowercased().contains(needle) {
                    result.append(["path": relative, "line": lineNumber + 1, "text": String(line.prefix(700))])
                    break
                }
            }
            if result.count >= maxResults { break }
        }
        return result
    }

    private func indexStatus(_ project: MCPProjectDefinition) throws -> [String: Any] {
        let files = try sourceFiles(project)
        return MCPProjectIntelligence.shared.status(project: project, files: files)
    }

    private func projectKnowledge(project: MCPProjectDefinition, question: String, maxResults: Int) -> [[String: Any]] {
        let terms = question.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 }
        let roots = [
            URL(fileURLWithPath: project.rootPath).appendingPathComponent("docs", isDirectory: true),
            URL(fileURLWithPath: project.rootPath).appendingPathComponent("README.md"),
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ABSDEVStudio/KnowledgeBase", isDirectory: true)
        ]
        var results: [[String: Any]] = []
        for root in roots {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }
            let urls: [URL]
            if isDirectory.boolValue {
                urls = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles])?.allObjects as? [URL]) ?? []
            } else { urls = [root] }
            for url in urls {
                guard ["md", "txt", "json", "yaml", "yml"].contains(url.pathExtension.lowercased()),
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let lower = text.lowercased()
                let score = terms.reduce(0) { $0 + min(lower.components(separatedBy: $1).count - 1, 8) }
                guard score > 0 else { continue }
                results.append(["path": url.path, "score": score, "content": String(text.prefix(8_000))])
                if results.count >= maxResults { return results.sorted { ($0["score"] as? Int ?? 0) > ($1["score"] as? Int ?? 0) } }
            }
        }
        return results.sorted { ($0["score"] as? Int ?? 0) > ($1["score"] as? Int ?? 0) }
    }

    private func runReadOnly(_ command: [String], timeout: TimeInterval) -> (exitCode: Int32, output: String) {
        guard let executable = command.first else { return (-1, "Missing command") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { process.terminate(); return (-2, "Command timed out") }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(decoding: data.prefix(200_000), as: UTF8.self))
        } catch { return (-1, error.localizedDescription) }
    }

    private func runTests(_ project: MCPProjectDefinition, filter: String) -> [String: Any] {
        let root = URL(fileURLWithPath: project.rootPath)
        let command: [String]
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("artisan").path) {
            command = ["/usr/bin/env", "php", "artisan", "test"] + (filter.isEmpty ? [] : ["--filter", filter])
        } else if FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
            command = ["/usr/bin/env", "swift", "test"] + (filter.isEmpty ? [] : ["--filter", filter])
        } else if FileManager.default.fileExists(atPath: root.appendingPathComponent("pyproject.toml").path) || FileManager.default.fileExists(atPath: root.appendingPathComponent("pytest.ini").path) {
            command = ["/usr/bin/env", "python3", "-m", "pytest"] + (filter.isEmpty ? [] : ["-k", filter])
        } else {
            return ["exitCode": -1, "output": "No supported test runner was detected."]
        }
        let process = Process(); process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: command[0]); process.arguments = Array(command.dropFirst())
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(120)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            if process.isRunning { process.terminate(); return ["exitCode": -2, "output": "Tests timed out after 120 seconds."] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return ["exitCode": process.terminationStatus, "output": String(decoding: data.prefix(500_000), as: UTF8.self), "command": command.joined(separator: " ")]
        } catch { return ["exitCode": -1, "output": error.localizedDescription] }
    }

    private func fallbackSourceFiles(root: URL, project: MCPProjectDefinition, limit: Int) throws -> [(score: Int, url: URL, relative: String)] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return [] }
        var result: [(Int, URL, String)] = []
        let extensions = Set(["swift", "php", "js", "ts", "py", "java", "kt", "go", "rs"])
        for case let url as URL in enumerator {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            if isExcluded(relative, project: project) { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= 1_500_000, extensions.contains(url.pathExtension.lowercased()) else { continue }
            result.append((1, url, relative))
            if result.count >= limit { break }
        }
        return result
    }

    private func isExcluded(_ relativePath: String, project: MCPProjectDefinition) -> Bool {
        let path = relativePath.replacingOccurrences(of: "\\", with: "/")
        return project.exclude.contains { pattern in
            let prefix = pattern.replacingOccurrences(of: "/**", with: "").replacingOccurrences(of: "**/", with: "")
            if pattern.hasPrefix("*.") { return path.lowercased().hasSuffix(String(pattern.dropFirst()).lowercased()) }
            return path == prefix || path.hasPrefix(prefix + "/")
        }
    }

    private func requiredString(_ key: String, _ arguments: [String: Any]) throws -> String {
        guard let value = arguments[key] as? String, !value.isEmpty else { throw MCPServerError.invalidArguments("Missing \(key)") }
        return value
    }

    private static func tool(_ name: String, _ title: String, _ description: String, properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["name": name, "title": title, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
    }
    private static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
    private static func integer(_ description: String) -> [String: Any] { ["type": "integer", "description": description] }
    private static func boolean(_ description: String) -> [String: Any] { ["type": "boolean", "description": description] }
}

enum MCPServerError: LocalizedError {
    case invalidArguments(String), methodNotFound(String), projectNotFound(String), projectRootMissing(String), pathTraversal, permissionDenied(String), notTextFile(String)
    var errorDescription: String? {
        switch self {
        case .invalidArguments(let value): value
        case .methodNotFound(let value): "Unknown MCP method or tool: \(value)"
        case .projectNotFound(let value): "Project not found or disabled: \(value)"
        case .projectRootMissing(let value): "Project root does not exist: \(value)"
        case .pathTraversal: "The requested path is outside the configured project root."
        case .permissionDenied(let value): value
        case .notTextFile(let value): "The file is not readable UTF-8 text: \(value)"
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
