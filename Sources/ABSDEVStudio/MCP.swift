import Foundation
import Observation
import Security
import SwiftUI

struct MCPServerConfiguration: Identifiable, Codable, Hashable {
    enum Authentication: String, Codable, CaseIterable, Identifiable {
        case none = "None"
        case bearer = "Bearer Token"
        var id: String { rawValue }
    }

    var id = UUID()
    var name = "MCP Server"
    var url = "http://127.0.0.1:8000/mcp"
    var authentication: Authentication = .none
    var enabled = true
}

struct MCPToolDescriptor: Identifiable, Hashable {
    let serverID: UUID
    let serverName: String
    let name: String
    let title: String
    let description: String
    let inputSchemaJSON: String
    var id: String { "\(serverID.uuidString):\(name)" }
}

struct MCPServerStatus: Hashable {
    enum State: String { case disconnected = "Not connected", connecting = "Connecting", connected = "Connected", failed = "Connection failed" }
    var state: State = .disconnected
    var detail = "Not tested"
    var toolCount = 0
}

@MainActor
@Observable
final class MCPController {
    var embeddedServer = EmbeddedMCPServerController()
    var servers: [MCPServerConfiguration] {
        didSet { persistServers() }
    }
    var statuses: [UUID: MCPServerStatus] = [:]
    var tools: [MCPToolDescriptor] = []
    var selectedToolID: String?
    var toolArguments = "{}"
    var toolResult = ""
    var isRefreshing = false
    var isInvoking = false
    var lastError: String?

    private let defaults = UserDefaults.standard
    private let keychain = MCPKeychain()
    private var sessions: [UUID: String] = [:]
    private static let serversKey = "openWebUI.mcp.servers"

    init() {
        if let data = defaults.data(forKey: Self.serversKey),
           let decoded = try? JSONDecoder().decode([MCPServerConfiguration].self, from: data) {
            servers = decoded
        } else {
            servers = []
        }
        if !servers.contains(where: { $0.url == "http://127.0.0.1:8765/mcp" }) {
            servers.insert(MCPServerConfiguration(name: "ABSDEV Studio Embedded MCP", url: "http://127.0.0.1:8765/mcp"), at: 0)
            persistServers()
        }
    }

    var enabledTools: [MCPToolDescriptor] {
        let enabledIDs = Set(servers.filter(\.enabled).map(\.id))
        return tools.filter { enabledIDs.contains($0.serverID) }
    }

    var selectedTool: MCPToolDescriptor? {
        tools.first { $0.id == selectedToolID }
    }

    func addServer() {
        let server = MCPServerConfiguration(name: "New MCP Server")
        servers.append(server)
        statuses[server.id] = MCPServerStatus()
    }

    func removeServer(_ id: UUID) {
        servers.removeAll { $0.id == id }
        statuses[id] = nil
        sessions[id] = nil
        tools.removeAll { $0.serverID == id }
        try? keychain.save("", account: id.uuidString)
    }

    func token(for serverID: UUID) -> String {
        (try? keychain.load(account: serverID.uuidString)) ?? ""
    }

    func setToken(_ token: String, for serverID: UUID) {
        try? keychain.save(token, account: serverID.uuidString)
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastError = nil
        defer { isRefreshing = false }

        var discovered: [MCPToolDescriptor] = []
        for server in servers where server.enabled {
            do {
                let serverTools = try await connectAndListTools(server)
                discovered.append(contentsOf: serverTools)
                statuses[server.id] = MCPServerStatus(state: .connected, detail: "Ready", toolCount: serverTools.count)
            } catch {
                statuses[server.id] = MCPServerStatus(state: .failed, detail: error.localizedDescription, toolCount: 0)
                lastError = error.localizedDescription
            }
        }
        tools = discovered.sorted {
            if $0.serverName == $1.serverName { return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return $0.serverName.localizedCaseInsensitiveCompare($1.serverName) == .orderedAscending
        }
        if selectedToolID == nil || !tools.contains(where: { $0.id == selectedToolID }) {
            selectedToolID = tools.first?.id
            toolArguments = selectedTool.map(Self.exampleArguments(for:)) ?? "{}"
        }
    }

    func testServer(_ serverID: UUID) async {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }
        statuses[serverID] = MCPServerStatus(state: .connecting, detail: "Negotiating capabilities", toolCount: 0)
        do {
            let serverTools = try await connectAndListTools(server)
            tools.removeAll { $0.serverID == serverID }
            tools.append(contentsOf: serverTools)
            statuses[serverID] = MCPServerStatus(state: .connected, detail: "Ready", toolCount: serverTools.count)
        } catch {
            statuses[serverID] = MCPServerStatus(state: .failed, detail: error.localizedDescription, toolCount: 0)
            lastError = error.localizedDescription
        }
    }

    func invokeSelectedTool() async {
        guard let tool = selectedTool,
              let server = servers.first(where: { $0.id == tool.serverID }) else { return }
        guard let argumentData = toolArguments.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: argumentData) as? [String: Any] else {
            lastError = "Tool arguments must be a valid JSON object."
            return
        }

        isInvoking = true
        toolResult = "Calling \(tool.name)…"
        lastError = nil
        defer { isInvoking = false }
        do {
            let result = try await rpc(server: server, method: "tools/call", params: ["name": tool.name, "arguments": arguments])
            toolResult = Self.prettyJSON(result)
        } catch {
            lastError = error.localizedDescription
            toolResult = "Tool call failed: \(error.localizedDescription)"
        }
    }

    func contextSummary() -> String {
        guard !enabledTools.isEmpty else { return "" }
        let lines = enabledTools.prefix(40).map { "- \($0.serverName) / \($0.name): \($0.description)" }
        return "Available MCP tools configured in ABSDEV Studio:\n" + lines.joined(separator: "\n")
    }

    private func connectAndListTools(_ server: MCPServerConfiguration) async throws -> [MCPToolDescriptor] {
        statuses[server.id] = MCPServerStatus(state: .connecting, detail: "Initializing", toolCount: 0)
        let initialize = try await rpc(
            server: server,
            method: "initialize",
            params: [
                "protocolVersion": "2025-11-25",
                "capabilities": [:],
                "clientInfo": ["name": "ABSDEV Studio", "version": "1.0"]
            ]
        )
        guard initialize["serverInfo"] != nil || initialize["capabilities"] != nil else {
            throw MCPError.invalidResponse("The server did not return MCP initialization capabilities.")
        }
        _ = try? await rpc(server: server, method: "notifications/initialized", params: [:], notification: true)
        let response = try await rpc(server: server, method: "tools/list", params: [:])
        guard let rawTools = response["tools"] as? [[String: Any]] else { return [] }
        return rawTools.compactMap { value in
            guard let name = value["name"] as? String else { return nil }
            let title = (value["title"] as? String) ?? name
            let description = (value["description"] as? String) ?? "No description supplied by the MCP server."
            let schema = (value["inputSchema"] as? [String: Any]) ?? [:]
            return MCPToolDescriptor(
                serverID: server.id,
                serverName: server.name,
                name: name,
                title: title,
                description: description,
                inputSchemaJSON: Self.prettyJSON(schema)
            )
        }
    }

    private func rpc(
        server: MCPServerConfiguration,
        method: String,
        params: [String: Any],
        notification: Bool = false
    ) async throws -> [String: Any] {
        guard let url = URL(string: server.url.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) else {
            throw MCPError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let session = sessions[server.id] { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        if server.authentication == .bearer {
            let token = token(for: server.id)
            guard !token.isEmpty else { throw MCPError.missingToken }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var payload: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if !notification { payload["id"] = UUID().uuidString }
        if !params.isEmpty { payload["params"] = params }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError.invalidResponse("No HTTP response.") }
        if let session = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !session.isEmpty { sessions[server.id] = session }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw MCPError.http(http.statusCode, detail)
        }
        if notification || data.isEmpty { return [:] }

        let jsonData = Self.extractJSONData(from: data)
        guard let object = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw MCPError.invalidResponse("The server returned neither JSON nor a supported SSE event.")
        }
        if let error = object["error"] as? [String: Any] {
            throw MCPError.remote((error["message"] as? String) ?? Self.prettyJSON(error))
        }
        return (object["result"] as? [String: Any]) ?? object
    }

    private func persistServers() {
        if let data = try? JSONEncoder().encode(servers) { defaults.set(data, forKey: Self.serversKey) }
    }

    private static func extractJSONData(from data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8), text.contains("data:") else { return data }
        for line in text.split(separator: "\n") {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("data:") {
                return Data(value.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
            }
        }
        return data
    }

    private static func prettyJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
            return String(describing: value)
        }
        return String(data: data, encoding: .utf8) ?? String(describing: value)
    }

    private static func exampleArguments(for tool: MCPToolDescriptor) -> String {
        guard let data = tool.inputSchemaJSON.data(using: .utf8),
              let schema = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let properties = schema["properties"] as? [String: [String: Any]] else { return "{}" }
        var example: [String: Any] = [:]
        for (name, definition) in properties {
            if let defaultValue = definition["default"] { example[name] = defaultValue; continue }
            switch definition["type"] as? String {
            case "string": example[name] = ""
            case "integer", "number": example[name] = 0
            case "boolean": example[name] = false
            case "array": example[name] = []
            case "object": example[name] = [:]
            default: break
            }
        }
        return prettyJSON(example)
    }
}

private enum MCPError: LocalizedError {
    case invalidURL
    case missingToken
    case invalidResponse(String)
    case http(Int, String)
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The MCP server URL must be a valid HTTP or HTTPS endpoint."
        case .missingToken: "This MCP server requires a bearer token. Add it in Settings."
        case .invalidResponse(let detail): "Invalid MCP response: \(detail)"
        case .http(let status, let detail): "MCP server returned HTTP \(status): \(detail)"
        case .remote(let detail): "MCP server error: \(detail)"
        }
    }
}

private struct MCPKeychain {
    private let service = "com.absdev.studio.mcp"

    func save(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    func load(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return String(data: data, encoding: .utf8)
    }
}

struct MCPWorkspaceView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var mcp = store.openWebUI.mcp
        VStack(spacing: 0) {
            HStack {
                Label("MCP Tools", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.title2.bold())
                Text("Native Model Context Protocol workspace").foregroundStyle(.secondary)
                Spacer()
                Button("Refresh Tools", systemImage: "arrow.clockwise") { Task { await mcp.refreshAll() } }
                    .disabled(mcp.isRefreshing || mcp.servers.filter(\.enabled).isEmpty)
                SettingsLink { Text("MCP Settings…") }
            }
            .padding(16)
            .background(.bar)

            if mcp.servers.isEmpty {
                ContentUnavailableView {
                    Label("No MCP servers configured", systemImage: "network.slash")
                } description: {
                    Text("Add a Streamable HTTP MCP server in Settings to discover native tools.")
                } actions: {
                    SettingsLink { Text("Open Settings") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if mcp.tools.isEmpty && !mcp.isRefreshing {
                ContentUnavailableView {
                    Label("No tools discovered", systemImage: "wrench.and.screwdriver")
                } description: {
                    Text("Refresh enabled MCP servers and check their connection status in Settings.")
                } actions: {
                    Button("Refresh Tools") { Task { await mcp.refreshAll() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(selection: $mcp.selectedToolID) {
                        ForEach(mcp.tools) { tool in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(tool.title).fontWeight(.semibold)
                                Text(tool.serverName).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(Optional(tool.id))
                        }
                    }
                    .frame(minWidth: 240, idealWidth: 290)

                    if let tool = mcp.selectedTool {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(tool.title).font(.title2.bold())
                                    Text("\(tool.serverName) · \(tool.name)").foregroundStyle(.secondary)
                                    Text(tool.description)
                                }
                                GroupBox("Input schema") {
                                    Text(tool.inputSchemaJSON).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                }
                                GroupBox("Arguments (JSON)") {
                                    TextEditor(text: $mcp.toolArguments).font(.system(.body, design: .monospaced)).frame(minHeight: 150).padding(6)
                                }
                                HStack {
                                    Button("Run Tool", systemImage: "play.fill") { Task { await mcp.invokeSelectedTool() } }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(mcp.isInvoking)
                                    if mcp.isInvoking { ProgressView().controlSize(.small) }
                                }
                                if !mcp.toolResult.isEmpty {
                                    GroupBox("Result") {
                                        ScrollView(.horizontal) {
                                            Text(mcp.toolResult).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                        }
                                    }
                                }
                                if let error = mcp.lastError { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled) }
                            }
                            .padding(24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        ContentUnavailableView("Select a tool", systemImage: "wrench.and.screwdriver")
                    }
                }
            }
        }
        .task { if mcp.tools.isEmpty && !mcp.servers.isEmpty { await mcp.refreshAll() } }
        .navigationTitle("MCP Tools")
    }
}

struct MCPSettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var mcp = store.openWebUI.mcp
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                EmbeddedMCPServerSettingsCard()

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("External MCP Servers").font(.title3.bold())
                        Text("Connect trusted Streamable HTTP Model Context Protocol servers. Credentials are stored in the macOS Keychain.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Add Server", systemImage: "plus") { mcp.addServer() }
                }

                if mcp.servers.isEmpty {
                    ContentUnavailableView("No MCP servers", systemImage: "network", description: Text("Add a server to expose tools, resources, and workflows to the native AI workspace."))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                }

                ForEach(Array(mcp.servers.enumerated()), id: \.element.id) { index, server in
                    MCPServerSettingsCard(index: index, serverID: server.id)
                }

                HStack {
                    Label("Only connect MCP servers you trust; enabled tools may read data or perform actions in external systems.", systemImage: "lock.shield.fill")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh All Tools") { Task { await mcp.refreshAll() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(mcp.isRefreshing || mcp.servers.isEmpty)
                }
            }
            .padding(32)
        }
    }
}


private struct EmbeddedMCPServerSettingsCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var server = store.openWebUI.mcp.embeddedServer
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("ABSDEV Studio MCP Server", systemImage: "server.rack")
                        .font(.title3.bold())
                    Text("Runs inside ABSDEV Studio and serves projects defined by separate JSON files.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(server.isRunning ? "Running" : "Stopped", systemImage: server.isRunning ? "checkmark.circle.fill" : "stop.circle")
                    .foregroundStyle(server.isRunning ? .green : .secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("Endpoint").frame(width: 110, alignment: .leading)
                    Text(server.endpoint).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Button("Copy", systemImage: "doc.on.doc") { server.copyEndpoint() }
                }
                GridRow {
                    Text("Port").frame(width: 110, alignment: .leading)
                    TextField("8765", value: $server.port, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .disabled(server.isRunning)
                }
                GridRow {
                    Text("Projects").frame(width: 110, alignment: .leading)
                    Text("\(server.projects.count) JSON definitions")
                    Button("Open Folder", systemImage: "folder") { server.openProjectsDirectory() }
                }
            }

            Toggle("Start the embedded MCP server automatically with ABSDEV Studio", isOn: $server.startsAutomatically)

            HStack {
                Text(server.status).font(.caption).foregroundStyle(.secondary)
                if let error = server.lastError { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
                Spacer()
                Button("Reload JSON", systemImage: "arrow.clockwise") { server.reloadProjects() }
                Button("Create JSON for Studio Projects", systemImage: "plus.square.on.square") {
                    server.importProjects(store.projects)
                }
                Button(server.isRunning ? "Restart" : "Start", systemImage: server.isRunning ? "arrow.clockwise" : "play.fill") {
                    server.isRunning ? server.restart() : server.start()
                }
                if server.isRunning {
                    Button("Stop", systemImage: "stop.fill", role: .destructive) { server.stop() }
                }
            }
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.7)))
    }
}

private struct MCPServerSettingsCard: View {
    @Environment(AppStore.self) private var store
    let index: Int
    let serverID: UUID
    @State private var token = ""

    var body: some View {
        @Bindable var mcp = store.openWebUI.mcp
        if mcp.servers.indices.contains(index), mcp.servers[index].id == serverID {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Toggle("", isOn: $mcp.servers[index].enabled).labelsHidden()
                    TextField("Server name", text: $mcp.servers[index].name).font(.headline).textFieldStyle(.plain)
                    Spacer()
                    let status = mcp.statuses[serverID] ?? MCPServerStatus()
                    Label(status.state.rawValue, systemImage: status.state == .connected ? "checkmark.circle.fill" : (status.state == .failed ? "exclamationmark.triangle.fill" : "network"))
                        .font(.caption).foregroundStyle(status.state == .connected ? .green : (status.state == .failed ? .red : .secondary))
                    Button(role: .destructive) { mcp.removeServer(serverID) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                    GridRow { Text("URL").frame(width: 100, alignment: .leading); TextField("https://server.example/mcp", text: $mcp.servers[index].url).textFieldStyle(.roundedBorder) }
                    GridRow {
                        Text("Authentication").frame(width: 100, alignment: .leading)
                        Picker("", selection: $mcp.servers[index].authentication) {
                            ForEach(MCPServerConfiguration.Authentication.allCases) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().frame(width: 180)
                    }
                    if mcp.servers[index].authentication == .bearer {
                        GridRow {
                            Text("Token").frame(width: 100, alignment: .leading)
                            SecureField("Bearer token", text: $token).textFieldStyle(.roundedBorder)
                                .onChange(of: token) { _, newValue in mcp.setToken(newValue, for: serverID) }
                        }
                    }
                }
                HStack {
                    let status = mcp.statuses[serverID]
                    Text(status?.detail ?? "Not tested").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    if let count = status?.toolCount, count > 0 { Text("\(count) tools").font(.caption).foregroundStyle(.secondary) }
                    Button("Test & Discover") { Task { await mcp.testServer(serverID) } }
                }
            }
            .padding(18)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.7)))
            .task { token = mcp.token(for: serverID) }
        }
    }
}
