import AppKit
import Foundation
import Observation
#if canImport(Network)
@preconcurrency import Network
#endif

struct MCPProjectDefinition: Identifiable, Codable, Hashable, Sendable {
    struct Permissions: Codable, Hashable, Sendable {
        var listDirectories = true
        var readFiles = true
        var searchFiles = true
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
        reloadProjects()
        if startsAutomatically {
            Task { @MainActor [weak self] in self?.start() }
        }
    }

    var endpoint: String { "http://\(host):\(port)/mcp" }
    var projectsDirectory: URL { projectStore.directory }

    func start() {
        guard !isRunning else { return }
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
                    case .failed(let error):
                        self.isRunning = false
                        self.status = "Failed"
                        self.lastError = error.localizedDescription
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
    }

    func restart() {
        stop()
        start()
    }

    func reloadProjects() {
        do {
            projects = try projectStore.loadAll()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func importProjects(_ appProjects: [LaravelProject]) {
        for project in appProjects {
            let slug = Self.slug(project.name)
            let definition = MCPProjectDefinition(
                id: slug,
                name: project.name,
                rootPath: project.path,
                projectType: "laravel",
                projectDescription: "Laravel project managed by ABSDEV Studio"
            )
            do { try projectStore.save(definition) } catch { lastError = error.localizedDescription }
        }
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

    private static func slug(_ text: String) -> String {
        let allowed = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : "-" }
        return String(allowed).replacingOccurrences(of: "-+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    #if canImport(Network)
    private func accept(_ connection: NWConnection) {
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
        let params = object["params"] as? [String: Any] ?? [:]
        if id == nil {
            send(status: 202, body: Data(), on: connection)
            return
        }
        do {
            let result = try route(method: method, params: params)
            send(status: 200, body: Self.jsonResult(id: id, result: result), on: connection)
        } catch {
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
            return ["tools": MCPToolRouter.toolDefinitions]
        case "tools/call":
            guard let name = params["name"] as? String else { throw MCPServerError.invalidArguments("Missing tool name") }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return try MCPToolRouter(projects: projectStore.loadAll()).call(name: name, arguments: arguments)
        case "ping":
            return [:]
        default:
            throw MCPServerError.methodNotFound(method)
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

    func loadAll() throws -> [MCPProjectDefinition] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url in
                let data = try Data(contentsOf: url)
                return try JSONDecoder().decode(MCPProjectDefinition.self, from: data)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func save(_ definition: MCPProjectDefinition) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(definition)
        try data.write(to: directory.appendingPathComponent("\(definition.id).json"), options: .atomic)
    }
}

private struct MCPToolRouter {
    let projects: [MCPProjectDefinition]

    static let toolDefinitions: [[String: Any]] = [
        tool("projects_list", "List configured projects", "Returns enabled JSON-defined projects served by ABSDEV Studio.", properties: [:]),
        tool("project_tree", "Project tree", "Lists files and folders below a project-relative path.", properties: ["project": string("Project id"), "path": string("Relative path"), "depth": integer("Maximum depth")], required: ["project"]),
        tool("project_read_file", "Read project file", "Reads a UTF-8 text file from a configured project.", properties: ["project": string("Project id"), "path": string("Relative file path"), "maxBytes": integer("Maximum bytes")], required: ["project", "path"]),
        tool("project_search", "Search project", "Searches text files in a configured project.", properties: ["project": string("Project id"), "query": string("Text to find"), "maxResults": integer("Maximum results")], required: ["project", "query"])
    ]

    func call(name: String, arguments: [String: Any]) throws -> [String: Any] {
        let value: Any
        switch name {
        case "projects_list":
            value = projects.filter(\.enabled).map { ["id": $0.id, "name": $0.name, "rootPath": $0.rootPath, "projectType": $0.projectType, "description": $0.projectDescription] }
        case "project_tree":
            let project = try resolve(arguments)
            guard project.permissions.listDirectories else { throw MCPServerError.permissionDenied }
            value = try tree(project: project, relativePath: arguments["path"] as? String ?? "", maxDepth: min(max(arguments["depth"] as? Int ?? 3, 1), 8))
        case "project_read_file":
            let project = try resolve(arguments)
            guard project.permissions.readFiles else { throw MCPServerError.permissionDenied }
            value = try read(project: project, relativePath: try requiredString("path", arguments), maxBytes: min(max(arguments["maxBytes"] as? Int ?? 262_144, 1_024), 1_048_576))
        case "project_search":
            let project = try resolve(arguments)
            guard project.permissions.searchFiles else { throw MCPServerError.permissionDenied }
            value = try search(project: project, query: try requiredString("query", arguments), maxResults: min(max(arguments["maxResults"] as? Int ?? 50, 1), 200))
        default:
            throw MCPServerError.methodNotFound(name)
        }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "isError": false]
    }

    private func resolve(_ arguments: [String: Any]) throws -> MCPProjectDefinition {
        let id = try requiredString("project", arguments)
        guard let project = projects.first(where: { $0.id == id && $0.enabled }) else { throw MCPServerError.projectNotFound(id) }
        guard FileManager.default.fileExists(atPath: project.rootPath) else { throw MCPServerError.projectRootMissing(project.rootPath) }
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
        guard !isExcluded(relativePath, project: project) else { throw MCPServerError.permissionDenied }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { throw MCPServerError.notTextFile(relativePath) }
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ["project": project.id, "path": relativePath, "content": text, "truncated": fileSize > data.count]
    }

    private func search(project: MCPProjectDefinition, query: String, maxResults: Int) throws -> [[String: Any]] {
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
}

private enum MCPServerError: LocalizedError {
    case invalidArguments(String), methodNotFound(String), projectNotFound(String), projectRootMissing(String), pathTraversal, permissionDenied, notTextFile(String)
    var errorDescription: String? {
        switch self {
        case .invalidArguments(let value): value
        case .methodNotFound(let value): "Unknown MCP method or tool: \(value)"
        case .projectNotFound(let value): "Project not found or disabled: \(value)"
        case .projectRootMissing(let value): "Project root does not exist: \(value)"
        case .pathTraversal: "The requested path is outside the configured project root."
        case .permissionDenied: "This operation is disabled by the project definition."
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
