import AppKit
import CoreData
import Foundation
import Observation
import Security
import SwiftUI

struct OpenWebUIModel: Identifiable, Codable, Hashable {
    let id: String
    let name: String?

    var displayName: String { name?.isEmpty == false ? name! : id }
}

struct OpenWebUIMessage: Identifiable, Codable, Hashable {
    enum Role: String, Codable { case system, user, assistant }

    let id: UUID
    let role: Role
    var content: String
    let createdAt: Date

    init(id: UUID = UUID(), role: Role, content: String, createdAt: Date = .now) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

@MainActor
@Observable
final class OpenWebUIController {
    var serverURL: String {
        didSet { defaults.set(serverURL, forKey: Keys.serverURL) }
    }
    var apiKey: String {
        didSet { try? keychain.save(apiKey, account: Keys.apiKeyAccount) }
    }
    var defaultModel: String {
        didSet { defaults.set(defaultModel, forKey: Keys.defaultModel) }
    }
    var systemPrompt: String {
        didSet { defaults.set(systemPrompt, forKey: Keys.systemPrompt) }
    }
    var autoSaveChats: Bool {
        didSet { defaults.set(autoSaveChats, forKey: Keys.autoSaveChats) }
    }
    var autoSaveOnlyStarred: Bool {
        didSet { defaults.set(autoSaveOnlyStarred, forKey: Keys.autoSaveOnlyStarred) }
    }
    var saveCodeBlocksSeparately: Bool {
        didSet { defaults.set(saveCodeBlocksSeparately, forKey: Keys.saveCodeBlocksSeparately) }
    }
    var generateKnowledgeArticle: Bool {
        didSet { defaults.set(generateKnowledgeArticle, forKey: Keys.generateKnowledgeArticle) }
    }
    var automaticTags: Bool {
        didSet { defaults.set(automaticTags, forKey: Keys.automaticTags) }
    }
    var maximumSavedMessages: Int {
        didSet { defaults.set(maximumSavedMessages, forKey: Keys.maximumSavedMessages) }
    }
    var models: [OpenWebUIModel] = []
    var messages: [OpenWebUIMessage] = []
    var draft = ""
    var isLoadingModels = false
    var isSending = false
    var connectionStatus = "Not connected"
    var lastError: String?
    var knowledgeStatus: String?
    var isConversationStarred = false
    var activeProject: LaravelProject?
    var mcp = MCPController()

    private let defaults = UserDefaults.standard
    private let keychain = OpenWebUIKeychain()
    private var sendTask: Task<Void, Never>?

    private enum Keys {
        static let serverURL = "openWebUI.serverURL"
        static let defaultModel = "openWebUI.defaultModel"
        static let systemPrompt = "openWebUI.systemPrompt"
        static let autoSaveChats = "openWebUI.autoSaveChats"
        static let autoSaveOnlyStarred = "openWebUI.autoSaveOnlyStarred"
        static let saveCodeBlocksSeparately = "openWebUI.saveCodeBlocksSeparately"
        static let generateKnowledgeArticle = "openWebUI.generateKnowledgeArticle"
        static let automaticTags = "openWebUI.automaticTags"
        static let maximumSavedMessages = "openWebUI.maximumSavedMessages"
        static let apiKeyAccount = "open-webui-api-key"
    }

    init() {
        serverURL = defaults.string(forKey: Keys.serverURL) ?? "http://127.0.0.1:3000"
        defaultModel = defaults.string(forKey: Keys.defaultModel) ?? ""
        systemPrompt = defaults.string(forKey: Keys.systemPrompt) ?? "You are a Laravel development assistant integrated into ABSDEV Studio."
        autoSaveChats = defaults.object(forKey: Keys.autoSaveChats) as? Bool ?? false
        autoSaveOnlyStarred = defaults.object(forKey: Keys.autoSaveOnlyStarred) as? Bool ?? true
        saveCodeBlocksSeparately = defaults.object(forKey: Keys.saveCodeBlocksSeparately) as? Bool ?? false
        generateKnowledgeArticle = defaults.object(forKey: Keys.generateKnowledgeArticle) as? Bool ?? false
        automaticTags = defaults.object(forKey: Keys.automaticTags) as? Bool ?? true
        maximumSavedMessages = max(2, defaults.object(forKey: Keys.maximumSavedMessages) as? Int ?? 50)
        apiKey = (try? keychain.load(account: Keys.apiKeyAccount)) ?? ""
    }

    var configured: Bool {
        normalizedBaseURL != nil && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var selectedModel: String {
        get { defaultModel }
        set { defaultModel = newValue }
    }

    func testConnection() async {
        await loadModels(showSuccess: true)
    }

    func loadModels(showSuccess: Bool = false) async {
        guard let baseURL = normalizedBaseURL else {
            connectionStatus = "Invalid server URL"
            lastError = connectionStatus
            return
        }
        guard !apiKey.isEmpty else {
            connectionStatus = "API key required"
            lastError = connectionStatus
            return
        }

        isLoadingModels = true
        lastError = nil
        defer { isLoadingModels = false }

        do {
            var request = URLRequest(url: baseURL.appending(path: "api/models"))
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
            let decoded = try JSONDecoder().decode(OpenWebUIModelsResponse.self, from: data)
            models = decoded.data.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            if defaultModel.isEmpty || !models.contains(where: { $0.id == defaultModel }) {
                defaultModel = models.first?.id ?? ""
            }
            connectionStatus = showSuccess ? "Connected · \(models.count) models" : "Connected"
        } catch {
            connectionStatus = "Connection failed"
            lastError = error.localizedDescription
        }
    }

    func newChat() {
        cancelGeneration()
        messages = []
        draft = ""
        lastError = nil
        knowledgeStatus = nil
        isConversationStarred = false
    }

    func cancelGeneration() {
        sendTask?.cancel()
        sendTask = nil
        isSending = false
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        guard configured else {
            lastError = "Configure the Open WebUI server and API key in Settings first."
            return
        }
        guard !defaultModel.isEmpty else {
            lastError = "Select a model before sending a message."
            return
        }

        draft = ""
        messages.append(OpenWebUIMessage(role: .user, content: text))
        let assistantID = UUID()
        messages.append(OpenWebUIMessage(id: assistantID, role: .assistant, content: ""))
        isSending = true
        lastError = nil

        let payloadMessages = requestMessages()
        sendTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.streamCompletion(messages: payloadMessages, assistantID: assistantID)
                if self.autoSaveChats && (!self.autoSaveOnlyStarred || self.isConversationStarred) {
                    self.saveConversationToKnowledgeBase(project: self.activeProject, asArticle: self.generateKnowledgeArticle, automatic: true)
                }
            } catch is CancellationError {
                // User-requested stop.
            } catch {
                self.lastError = error.localizedDescription
                if let index = self.messages.firstIndex(where: { $0.id == assistantID }), self.messages[index].content.isEmpty {
                    self.messages[index].content = "Request failed: \(error.localizedDescription)"
                }
            }
            self.isSending = false
            self.sendTask = nil
        }
    }

    func saveResponseToKnowledgeBase(_ messageID: UUID, project: LaravelProject?) {
        guard let message = messages.first(where: { $0.id == messageID && $0.role == .assistant }),
              !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let prompt = nearestPrompt(before: messageID)
        let title = knowledgeTitle(from: prompt ?? message.content)
        let body = [
            "# \(title)",
            "",
            "**Source:** Open WebUI",
            "**Model:** \(defaultModel)",
            "**Saved:** \(Date().formatted(date: .abbreviated, time: .shortened))",
            prompt.map { "\n## Prompt\n\n\($0)" } ?? "",
            "\n## Response\n\n\(message.content)"
        ].joined(separator: "\n")
        saveKnowledgeDocument(title: title, body: body, project: project, tags: inferredTags(from: body), favorite: isConversationStarred)
        if saveCodeBlocksSeparately { saveCodeBlocks(from: message.content, project: project, parentTitle: title) }
    }

    func saveConversationToKnowledgeBase(project: LaravelProject?, asArticle: Bool = false, automatic: Bool = false) {
        let relevant = Array(messages.filter { !$0.content.isEmpty }.suffix(maximumSavedMessages))
        guard relevant.contains(where: { $0.role == .assistant }) else { return }
        let title = knowledgeTitle(from: relevant.first(where: { $0.role == .user })?.content ?? "Open WebUI Conversation")
        let body = asArticle ? articleBody(title: title, messages: relevant) : conversationBody(title: title, messages: relevant)
        saveKnowledgeDocument(title: title, body: body, project: project, tags: inferredTags(from: body), favorite: isConversationStarred)
        if saveCodeBlocksSeparately {
            relevant.filter { $0.role == .assistant }.forEach { saveCodeBlocks(from: $0.content, project: project, parentTitle: title) }
        }
        knowledgeStatus = automatic ? "Conversation saved automatically" : (asArticle ? "Knowledge article created" : "Conversation saved")
    }

    private func saveKnowledgeDocument(title: String, body: String, project: LaravelProject?, tags: [String], favorite: Bool) {
        do {
            try OpenWebUIKnowledgeWriter.shared.save(
                projectID: project?.id ?? UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                title: title,
                text: body,
                tags: tags,
                favorite: favorite
            )
            knowledgeStatus = "Saved to Knowledge Base"
        } catch {
            lastError = "Knowledge Base save failed: \(error.localizedDescription)"
        }
    }

    private func nearestPrompt(before messageID: UUID) -> String? {
        guard let index = messages.firstIndex(where: { $0.id == messageID }), index > 0 else { return nil }
        return messages[..<index].last(where: { $0.role == .user })?.content
    }

    private func knowledgeTitle(from value: String) -> String {
        let line = value.split(separator: "\n").first.map(String.init) ?? "Open WebUI Knowledge"
        let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(80)).isEmpty ? "Open WebUI Knowledge" : String(cleaned.prefix(80))
    }

    private func conversationBody(title: String, messages: [OpenWebUIMessage]) -> String {
        var lines = ["# \(title)", "", "**Source:** Open WebUI", "**Model:** \(defaultModel)", "**Saved:** \(Date().formatted(date: .abbreviated, time: .shortened))", ""]
        for message in messages where message.role != .system {
            lines.append(message.role == .user ? "## Prompt" : "## Response")
            lines.append("")
            lines.append(message.content)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func articleBody(title: String, messages: [OpenWebUIMessage]) -> String {
        let prompts = messages.filter { $0.role == .user }.map(\.content)
        let answers = messages.filter { $0.role == .assistant }.map(\.content)
        return [
            "# \(title)", "", "## Overview", "",
            prompts.first ?? "AI-assisted project knowledge.", "",
            "## Guidance", "", answers.joined(separator: "\n\n---\n\n"), "",
            "## Source", "", "Generated from an Open WebUI conversation using `\(defaultModel)` on \(Date().formatted(date: .abbreviated, time: .shortened))."
        ].joined(separator: "\n")
    }

    private func inferredTags(from text: String) -> [String] {
        guard automaticTags else { return ["Open WebUI", "AI"] }
        let candidates = ["Laravel", "PHP", "Swift", "macOS", "Docker", "Redis", "MySQL", "SQLite", "Livewire", "Inertia", "API", "Queue", "Testing", "Security", "Deployment", "Open WebUI", "AI"]
        let lower = text.lowercased()
        return candidates.filter { lower.contains($0.lowercased()) }.prefix(8).map { $0 }
    }

    private func saveCodeBlocks(from text: String, project: LaravelProject?, parentTitle: String) {
        let blocks = OpenWebUIKnowledgeWriter.codeBlocks(in: text)
        for (index, block) in blocks.enumerated() {
            let language = block.language.isEmpty ? "Code" : block.language.capitalized
            saveKnowledgeDocument(
                title: "\(parentTitle) — \(language) Snippet \(index + 1)",
                body: "# \(language) Snippet\n\n```\(block.language)\n\(block.code)\n```",
                project: project,
                tags: ["Open WebUI", "Snippet", language],
                favorite: isConversationStarred
            )
        }
    }

    private func requestMessages() -> [[String: String]] {
        var result: [[String: String]] = []

        let prompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let userQuery = messages.last(where: { $0.role == .user })?.content ?? ""

        let knowledge = activeProject.map {
            AIKnowledgeContext.shared.context(
                projectID: $0.id,
                query: userQuery
            )
        } ?? ""

        var contextParts: [String] = []

        if !prompt.isEmpty {
            contextParts.append(prompt)
        }

    
        if !knowledge.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            contextParts.append(knowledge)
        }

        let combinedSystemPrompt = contextParts.joined(separator: "\n\n")

        if !combinedSystemPrompt.isEmpty {
            result.append([
                "role": "system",
                "content": combinedSystemPrompt
            ])
        }

        result += messages
            .filter {
                $0.role != .system &&
                !$0.content.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            }
            .map {
                [
                    "role": $0.role.rawValue,
                    "content": $0.content
                ]
            }

        return result
    }

    private func streamCompletion(messages payloadMessages: [[String: String]], assistantID: UUID) async throws {
        guard let baseURL = normalizedBaseURL else { throw OpenWebUIError.invalidServerURL }
        var request = URLRequest(url: baseURL.appending(path: "api/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": defaultModel,
            "messages": payloadMessages,
            "stream": true
        ])

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try validate(response: response, data: nil)
        var receivedText = false

        for try await rawLine in bytes.lines {
            try Task.checkCancellation()
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { continue }
            let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if value == "[DONE]" { break }
            guard let data = value.data(using: .utf8),
                  let event = try? JSONDecoder().decode(OpenWebUIChatChunk.self, from: data),
                  let content = event.choices.first?.delta.content,
                  !content.isEmpty else { continue }
            receivedText = true
            if let index = self.messages.firstIndex(where: { $0.id == assistantID }) {
                self.messages[index].content += content
            }
        }

        if !receivedText {
            throw OpenWebUIError.emptyResponse
        }
    }

    private var normalizedBaseURL: URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), components.scheme != nil, components.host != nil else { return nil }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        return components.url
    }

    private func validate(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { throw OpenWebUIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail: String
            if let data, let body = String(data: data, encoding: .utf8), !body.isEmpty {
                detail = body
            } else {
                detail = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            }
            throw OpenWebUIError.httpStatus(http.statusCode, detail)
        }
    }
}

struct OpenWebUIModelsResponse: Decodable { let data: [OpenWebUIModel] }
struct OpenWebUIChatChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta
    }
    let choices: [Choice]
}

private enum OpenWebUIError: LocalizedError {
    case invalidServerURL
    case invalidResponse
    case httpStatus(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: "The Open WebUI server URL is invalid."
        case .invalidResponse: "Open WebUI returned an invalid response."
        case .httpStatus(let status, let detail): "Open WebUI returned HTTP \(status): \(detail)"
        case .emptyResponse: "Open WebUI completed without returning any text."
        }
    }
}

struct OpenWebUIKeychain {
    private let service = "com.absdev.studio.openwebui"

    func save(_ value: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
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
        guard status == errSecSuccess, let data = result as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return String(data: data, encoding: .utf8)
    }
}


@MainActor
final class OpenWebUIKnowledgeWriter {
    static let shared = OpenWebUIKnowledgeWriter()
    private init() {}

    struct CodeBlock { let language: String; let code: String }

    func save(projectID: UUID, title: String, text: String, tags: [String], favorite: Bool) throws {
        let context = KBPersistence.shared.container.viewContext
        let request = NSFetchRequest<KBDocument>(entityName: "KBDocument")
        request.predicate = NSPredicate(format: "projectID == %@", projectID as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(key: "order", ascending: false)]
        request.fetchLimit = 1
        let nextOrder = ((try context.fetch(request).first?.order) ?? -1) + 1

        let document = KBDocument(context: context)
        document.id = UUID()
        document.projectID = projectID
        document.title = title
        document.text = text
        document.priority = KBPriority.normal.rawValue
        document.order = nextOrder
        document.createdAt = .now
        document.updatedAt = .now
        document.tags = tags.joined(separator: ", ")
        document.isFavorite = favorite
        document.isTrashed = false
        document.version = 1
        try context.save()
    }

    static func codeBlocks(in text: String) -> [CodeBlock] {
        let pattern = "```([A-Za-z0-9_+.-]*)\\n([\\s\\S]*?)```"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let languageRange = Range(match.range(at: 1), in: text),
                  let codeRange = Range(match.range(at: 2), in: text) else { return nil }
            return CodeBlock(language: String(text[languageRange]), code: String(text[codeRange]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

struct OpenWebUIView: View {
    @Environment(AppStore.self) private var store
    @FocusState private var composerFocused: Bool

    var body: some View {
        @Bindable var controller = store.openWebUI

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("Open WebUI", systemImage: "bubble.left.and.bubble.right.fill")
                    .font(.title2.bold())
                Text("Native AI workspace")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Model", selection: $controller.defaultModel) {
                    if controller.models.isEmpty {
                        Text("No models loaded").tag("")
                    }
                    ForEach(controller.models) { model in Text(model.displayName).tag(model.id) }
                }
                .labelsHidden()
                .frame(width: 240)
                Button { Task { await controller.loadModels() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh models")
                .disabled(controller.isLoadingModels || !controller.configured)
                Button { controller.isConversationStarred.toggle() } label: {
                    Image(systemName: controller.isConversationStarred ? "star.fill" : "star")
                }
                .help(controller.isConversationStarred ? "Unstar conversation" : "Star conversation")
                Menu {
                    Button("Save Conversation", systemImage: "text.bubble") {
                        controller.saveConversationToKnowledgeBase(project: store.selectedProject)
                    }
                    Button("Create Knowledge Article", systemImage: "doc.text.fill") {
                        controller.saveConversationToKnowledgeBase(project: store.selectedProject, asArticle: true)
                    }
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .disabled(!controller.messages.contains(where: { $0.role == .assistant && !$0.content.isEmpty }))
                Button("New Chat", systemImage: "square.and.pencil") { controller.newChat() }
            }
            .padding(16)
            .background(.bar)

            if !controller.configured {
                ContentUnavailableView {
                    Label("Configure Open WebUI", systemImage: "gearshape.2.fill")
                } description: {
                    Text("Add your self-hosted Open WebUI URL and API key in ABSDEV Studio Settings.")
                } actions: {
                    SettingsLink { Text("Open Settings") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            if controller.messages.isEmpty {
                                ContentUnavailableView("Start a conversation", systemImage: "sparkles", description: Text("Messages are sent directly to your configured Open WebUI server."))
                                    .padding(.top, 100)
                            }
                            ForEach(controller.messages) { message in
                                OpenWebUIMessageBubble(message: message) {
                                    controller.saveResponseToKnowledgeBase(message.id, project: store.selectedProject)
                                }
                                .id(message.id)
                            }
                        }
                        .padding(22)
                    }
                    .onChange(of: controller.messages) { _, messages in
                        if let id = messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                    }
                }

                if let status = controller.knowledgeStatus {
                    Label(status, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 6)
                }

                if let error = controller.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 6)
                }

                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Ask Open WebUI…", text: $controller.draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...8)
                        .focused($composerFocused)
                        .onSubmit { if !NSEvent.modifierFlags.contains(.shift) { controller.send() } }
                        .padding(12)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                    if controller.isSending {
                        Button("Stop", systemImage: "stop.fill") { controller.cancelGeneration() }
                            .buttonStyle(.bordered)
                            .tint(.red)
                    } else {
                        Button("Send", systemImage: "paperplane.fill") { controller.send() }
                            .buttonStyle(.borderedProminent)
                            .disabled(controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.defaultModel.isEmpty)
                    }
                }
                .padding(16)
                .background(.bar)
            }
        }
        .task {
            controller.activeProject = store.selectedProject
            if controller.configured && controller.models.isEmpty { await controller.loadModels() }
            composerFocused = true
        }
        .onChange(of: store.selectedProjectID) { _, _ in controller.activeProject = store.selectedProject }
        .navigationTitle("Open WebUI")
    }
}

private struct OpenWebUIMessageBubble: View {
    let message: OpenWebUIMessage
    let saveResponse: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 100) }
            VStack(alignment: .leading, spacing: 7) {
                Label(message.role == .user ? "You" : "Open WebUI", systemImage: message.role == .user ? "person.crop.circle.fill" : "sparkles")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(message.content.isEmpty ? "Thinking…" : message.content)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if message.role == .assistant && !message.content.isEmpty {
                    HStack {
                        Button("Save Response", systemImage: "square.and.arrow.down") { saveResponse() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        Spacer()
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: 760, alignment: .leading)
            .background(message.role == .user ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
            if message.role != .user { Spacer(minLength: 100) }
        }
    }
}

struct OpenWebUISettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var controller = store.openWebUI
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Open WebUI Connection").font(.title3.bold())
                        Text("Connect ABSDEV Studio to a self-hosted Open WebUI instance using its REST API.").foregroundStyle(.secondary)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
                        GridRow {
                            Text("Server URL").frame(width: 140, alignment: .leading)
                            TextField("http://127.0.0.1:3000", text: $controller.serverURL).textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            Text("API key").frame(width: 140, alignment: .leading)
                            SecureField("Open WebUI API key", text: $controller.apiKey).textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            Text("Default model").frame(width: 140, alignment: .leading)
                            Picker("", selection: $controller.defaultModel) {
                                if controller.models.isEmpty { Text("Load models first").tag("") }
                                ForEach(controller.models) { model in Text(model.displayName).tag(model.id) }
                            }.labelsHidden()
                        }
                    }
                    HStack {
                        Label(controller.connectionStatus, systemImage: controller.connectionStatus.hasPrefix("Connected") ? "checkmark.circle.fill" : "network")
                            .foregroundStyle(controller.connectionStatus.hasPrefix("Connected") ? .green : .secondary)
                        Spacer()
                        Button("Test & Load Models") { Task { await controller.testConnection() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(controller.isLoadingModels)
                    }
                    if let error = controller.lastError {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                .padding(22)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.7)))


                VStack(alignment: .leading, spacing: 14) {
                    Text("Knowledge Base").font(.title3.bold())
                    Toggle("Save completed conversations automatically", isOn: $controller.autoSaveChats)
                    Toggle("Only auto-save starred conversations", isOn: $controller.autoSaveOnlyStarred)
                        .disabled(!controller.autoSaveChats)
                    Toggle("Create documentation-style articles", isOn: $controller.generateKnowledgeArticle)
                    Toggle("Save code blocks as separate snippets", isOn: $controller.saveCodeBlocksSeparately)
                    Toggle("Generate tags automatically", isOn: $controller.automaticTags)
                    Stepper("Maximum saved messages: \(controller.maximumSavedMessages)", value: $controller.maximumSavedMessages, in: 2...200, step: 2)
                    Text("Manual Save Response and Save Conversation actions remain available in the Open WebUI workspace. Saved items are associated with the currently selected Laravel project.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(22)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.7)))

                VStack(alignment: .leading, spacing: 12) {
                    Text("System Prompt").font(.title3.bold())
                    TextEditor(text: $controller.systemPrompt)
                        .font(.body)
                        .frame(minHeight: 130)
                        .padding(8)
                        .background(.background, in: RoundedRectangle(cornerRadius: 10))
                    Text("The API key is stored in the macOS Keychain. Chat requests go directly from this Mac to the configured Open WebUI server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(22)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.7)))
            }
            .padding(32)
        }
    }
}
