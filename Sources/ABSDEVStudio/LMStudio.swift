import AppKit
import Foundation
import Observation
import Security
import SwiftUI

@MainActor
@Observable
final class LMStudioController {
    var serverURL: String { didSet { defaults.set(serverURL, forKey: Keys.serverURL) } }
    var apiToken: String { didSet { try? keychain.save(apiToken, account: Keys.apiTokenAccount) } }
    var defaultModel: String { didSet { defaults.set(defaultModel, forKey: Keys.defaultModel) } }
    var systemPrompt: String { didSet { defaults.set(systemPrompt, forKey: Keys.systemPrompt) } }
    var temperature: Double { didSet { defaults.set(temperature, forKey: Keys.temperature) } }
    var autoSaveChats: Bool { didSet { defaults.set(autoSaveChats, forKey: Keys.autoSaveChats) } }
    var autoSaveOnlyStarred: Bool { didSet { defaults.set(autoSaveOnlyStarred, forKey: Keys.autoSaveOnlyStarred) } }
    var maximumSavedMessages: Int { didSet { defaults.set(maximumSavedMessages, forKey: Keys.maximumSavedMessages) } }

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

    private let defaults = UserDefaults.standard
    private let keychain = OpenWebUIKeychain()
    private var sendTask: Task<Void, Never>?

    private enum Keys {
        static let serverURL = "lmStudio.serverURL"
        static let defaultModel = "lmStudio.defaultModel"
        static let systemPrompt = "lmStudio.systemPrompt"
        static let temperature = "lmStudio.temperature"
        static let autoSaveChats = "lmStudio.autoSaveChats"
        static let autoSaveOnlyStarred = "lmStudio.autoSaveOnlyStarred"
        static let maximumSavedMessages = "lmStudio.maximumSavedMessages"
        static let apiTokenAccount = "lm-studio-api-token"
    }

    init() {
        serverURL = defaults.string(forKey: Keys.serverURL) ?? "http://127.0.0.1:1234"
        defaultModel = defaults.string(forKey: Keys.defaultModel) ?? ""
        systemPrompt = defaults.string(forKey: Keys.systemPrompt) ?? "You are a Laravel development assistant integrated into ABSDEV Studio."
        temperature = defaults.object(forKey: Keys.temperature) as? Double ?? 0.7
        autoSaveChats = defaults.object(forKey: Keys.autoSaveChats) as? Bool ?? false
        autoSaveOnlyStarred = defaults.object(forKey: Keys.autoSaveOnlyStarred) as? Bool ?? true
        maximumSavedMessages = max(2, defaults.object(forKey: Keys.maximumSavedMessages) as? Int ?? 50)
        apiToken = (try? keychain.load(account: Keys.apiTokenAccount)) ?? ""
    }

    var configured: Bool { normalizedBaseURL != nil }

    func openApplication() {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/LM Studio.app"), configuration: configuration) { _, error in
            if let error { Task { @MainActor in self.lastError = error.localizedDescription } }
        }
    }

    func testConnection() async { await loadModels(showSuccess: true) }

    func loadModels(showSuccess: Bool = false) async {
        guard let url = endpoint("v1/models") else {
            connectionStatus = "Invalid server URL"
            lastError = connectionStatus
            return
        }
        isLoadingModels = true
        lastError = nil
        defer { isLoadingModels = false }
        do {
            var request = URLRequest(url: url)
            applyHeaders(to: &request)
            request.timeoutInterval = 15
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
        guard configured else { lastError = "Configure the LM Studio server in Settings first."; return }
        guard !defaultModel.isEmpty else { lastError = "Load and select a model before sending a message."; return }

        draft = ""
        messages.append(OpenWebUIMessage(role: .user, content: text))
        let assistantID = UUID()
        messages.append(OpenWebUIMessage(id: assistantID, role: .assistant, content: ""))
        isSending = true
        lastError = nil
        let payload = requestMessages()

        sendTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.streamCompletion(messages: payload, assistantID: assistantID)
                if self.autoSaveChats && (!self.autoSaveOnlyStarred || self.isConversationStarred) {
                    self.saveConversationToKnowledgeBase(project: self.activeProject, automatic: true)
                }
            } catch is CancellationError {
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
        guard let project,
              let message = messages.first(where: { $0.id == messageID && $0.role == .assistant }),
              !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let prompt = nearestPrompt(before: messageID)
        let title = knowledgeTitle(from: prompt ?? message.content)
        let body = "# \(title)\n\n**Source:** LM Studio\n**Model:** \(defaultModel)\n**Saved:** \(Date().formatted(date: .abbreviated, time: .shortened))\n\n## Prompt\n\n\(prompt ?? "")\n\n## Response\n\n\(message.content)"
        saveKnowledge(project: project, title: title, body: body, tags: inferredTags(from: body))
    }

    func saveConversationToKnowledgeBase(project: LaravelProject?, automatic: Bool = false) {
        guard let project else { knowledgeStatus = "Select a project before saving."; return }
        let relevant = Array(messages.suffix(maximumSavedMessages))
        guard relevant.contains(where: { $0.role == .assistant && !$0.content.isEmpty }) else { return }
        let title = knowledgeTitle(from: relevant.first(where: { $0.role == .user })?.content ?? "LM Studio Conversation")
        var lines = ["# \(title)", "", "**Source:** LM Studio", "**Model:** \(defaultModel)", "**Saved:** \(Date().formatted(date: .abbreviated, time: .shortened))", ""]
        for message in relevant where message.role != .system {
            lines += [message.role == .user ? "## You" : "## LM Studio", "", message.content, ""]
        }
        saveKnowledge(project: project, title: title, body: lines.joined(separator: "\n"), tags: inferredTags(from: lines.joined(separator: "\n")), automatic: automatic)
    }

    private func saveKnowledge(project: LaravelProject, title: String, body: String, tags: [String], automatic: Bool = false) {
        do {
            try OpenWebUIKnowledgeWriter.shared.save(projectID: project.id, title: title, text: body, tags: tags, favorite: isConversationStarred)
            knowledgeStatus = automatic ? "Conversation saved automatically." : "Saved to Knowledge Base."
        } catch { lastError = "Knowledge Base save failed: \(error.localizedDescription)" }
    }

    private func requestMessages() -> [[String: String]] {
        var result: [[String: String]] = []
        let prompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { result.append(["role": "system", "content": prompt + projectContext]) }
        result += messages.filter { $0.role != .system && !$0.content.isEmpty }.map { ["role": $0.role.rawValue, "content": $0.content] }
        return result
    }

    private var projectContext: String {
        guard let project = activeProject else { return "" }
        return "\n\nActive Laravel project: \(project.name) at \(project.path)."
    }

    private func streamCompletion(messages: [[String: String]], assistantID: UUID) async throws {
        guard let url = endpoint("v1/chat/completions") else { throw LMStudioError.invalidServerURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": defaultModel,
            "messages": messages,
            "temperature": temperature,
            "stream": true
        ])

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw LMStudioError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw LMStudioError.httpStatus(http.statusCode) }
        var received = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if value == "[DONE]" { break }
            guard let data = value.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(OpenWebUIChatChunk.self, from: data),
                  let content = chunk.choices.first?.delta.content, !content.isEmpty else { continue }
            received = true
            if let index = self.messages.firstIndex(where: { $0.id == assistantID }) { self.messages[index].content += content }
        }
        if !received { throw LMStudioError.emptyResponse }
    }

    private var normalizedBaseURL: URL? {
        let value = serverURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: value)
    }

    private func endpoint(_ path: String) -> URL? { normalizedBaseURL?.appending(path: path) }

    private func applyHeaders(to request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw LMStudioError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw LMStudioError.httpDetail(http.statusCode, detail)
        }
    }

    private func nearestPrompt(before messageID: UUID) -> String? {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return nil }
        return messages[..<index].last(where: { $0.role == .user })?.content
    }

    private func knowledgeTitle(from value: String) -> String {
        let line = value.split(separator: "\n").first.map(String.init) ?? "LM Studio Knowledge"
        let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "LM Studio Knowledge" : String(cleaned.prefix(80))
    }

    private func inferredTags(from text: String) -> [String] {
        let candidates = ["Laravel", "PHP", "Swift", "macOS", "Docker", "Redis", "MySQL", "SQLite", "Livewire", "Inertia", "API", "Queue", "Testing", "Security", "Deployment"]
        let found = candidates.filter { text.localizedCaseInsensitiveContains($0) }
        return Array(Set(["LM Studio", "AI"] + found)).sorted()
    }
}

private enum LMStudioError: LocalizedError {
    case invalidServerURL, invalidResponse, httpStatus(Int), httpDetail(Int, String), emptyResponse
    var errorDescription: String? {
        switch self {
        case .invalidServerURL: "The LM Studio server URL is invalid."
        case .invalidResponse: "LM Studio returned an invalid response."
        case .httpStatus(let status): "LM Studio returned HTTP \(status)."
        case .httpDetail(let status, let detail): "LM Studio returned HTTP \(status): \(detail)"
        case .emptyResponse: "LM Studio completed without returning any text."
        }
    }
}

struct LMStudioView: View {
    @Environment(AppStore.self) private var store
    @FocusState private var composerFocused: Bool

    var body: some View {
        @Bindable var controller = store.lmStudio
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("LM Studio", systemImage: "cpu.fill").font(.title2.bold())
                Text("Local native AI workspace").foregroundStyle(.secondary)
                Spacer()
                Picker("Model", selection: $controller.defaultModel) {
                    if controller.models.isEmpty { Text("No models available").tag("") }
                    ForEach(controller.models) { Text($0.displayName).tag($0.id) }
                }.labelsHidden().frame(width: 270)
                Button { Task { await controller.loadModels() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh models").disabled(controller.isLoadingModels || !controller.configured)
                Button { controller.isConversationStarred.toggle() } label: { Image(systemName: controller.isConversationStarred ? "star.fill" : "star") }
                Menu {
                    Button("Save Conversation", systemImage: "text.bubble") { controller.saveConversationToKnowledgeBase(project: store.selectedProject) }
                } label: { Label("Save", systemImage: "square.and.arrow.down") }
                    .disabled(!controller.messages.contains(where: { $0.role == .assistant && !$0.content.isEmpty }))
                Button("New Chat", systemImage: "square.and.pencil") { controller.newChat() }
            }.padding(16).background(.bar)

            if !controller.configured {
                ContentUnavailableView {
                    Label("Configure LM Studio", systemImage: "gearshape.2.fill")
                } description: {
                    Text("Configure the local LM Studio API server in ABSDEV Studio Settings.")
                } actions: {
                    Button("Open LM Studio") { controller.openApplication() }
                    SettingsLink { Text("Open Settings") }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            if controller.messages.isEmpty {
                                ContentUnavailableView("Start a local conversation", systemImage: "cpu", description: Text("Messages are processed by the model running in LM Studio."))
                                    .padding(.top, 100)
                            }
                            ForEach(controller.messages) { message in
                                HStack(alignment: .top) {
                                    if message.role == .user { Spacer(minLength: 100) }
                                    VStack(alignment: .leading, spacing: 7) {
                                        Label(message.role == .user ? "You" : "LM Studio", systemImage: message.role == .user ? "person.crop.circle.fill" : "cpu.fill")
                                            .font(.caption.bold()).foregroundStyle(.secondary)
                                        Text(message.content.isEmpty ? "Thinking…" : message.content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                        if message.role == .assistant && !message.content.isEmpty {
                                            Button("Save Response", systemImage: "square.and.arrow.down") { controller.saveResponseToKnowledgeBase(message.id, project: store.selectedProject) }
                                                .buttonStyle(.borderless).font(.caption)
                                        }
                                    }.padding(14).frame(maxWidth: 760, alignment: .leading)
                                        .background(message.role == .user ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
                                    if message.role != .user { Spacer(minLength: 100) }
                                }.id(message.id)
                            }
                        }.padding(22)
                    }.onChange(of: controller.messages) { _, items in if let id = items.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
                }
                if let status = controller.knowledgeStatus { Label(status, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 6) }
                if let error = controller.lastError { Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 6) }
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Ask LM Studio…", text: $controller.draft, axis: .vertical)
                        .textFieldStyle(.plain).lineLimit(1...8).focused($composerFocused)
                        .onSubmit { if !NSEvent.modifierFlags.contains(.shift) { controller.send() } }
                        .padding(12).background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                    if controller.isSending {
                        Button("Stop", systemImage: "stop.fill") { controller.cancelGeneration() }.buttonStyle(.bordered).tint(.red)
                    } else {
                        Button("Send", systemImage: "paperplane.fill") { controller.send() }.buttonStyle(.borderedProminent)
                            .disabled(controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.defaultModel.isEmpty)
                    }
                }.padding(16).background(.bar)
            }
        }
        .task {
            controller.activeProject = store.selectedProject
            if controller.configured && controller.models.isEmpty { await controller.loadModels() }
            composerFocused = true
        }
        .onChange(of: store.selectedProjectID) { _, _ in controller.activeProject = store.selectedProject }
        .navigationTitle("LM Studio")
    }
}

struct LMStudioSettingsView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        @Bindable var controller = store.lmStudio
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("LM Studio Connection").font(.title3.bold())
                    Text("Connect to LM Studio's local OpenAI-compatible API server.").foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
                        GridRow { Text("Server URL").frame(width: 140, alignment: .leading); TextField("http://127.0.0.1:1234", text: $controller.serverURL).textFieldStyle(.roundedBorder) }
                        GridRow { Text("API token").frame(width: 140, alignment: .leading); SecureField("Optional LM Studio API token", text: $controller.apiToken).textFieldStyle(.roundedBorder) }
                        GridRow { Text("Default model").frame(width: 140, alignment: .leading); Picker("", selection: $controller.defaultModel) { if controller.models.isEmpty { Text("Load models first").tag("") }; ForEach(controller.models) { Text($0.displayName).tag($0.id) } }.labelsHidden() }
                        GridRow { Text("Temperature").frame(width: 140, alignment: .leading); Slider(value: $controller.temperature, in: 0...2, step: 0.05); Text(controller.temperature.formatted(.number.precision(.fractionLength(2)))).monospacedDigit().frame(width: 42) }
                    }
                    HStack {
                        Label(controller.connectionStatus, systemImage: controller.connectionStatus.hasPrefix("Connected") ? "checkmark.circle.fill" : "network").foregroundStyle(controller.connectionStatus.hasPrefix("Connected") ? .green : .secondary)
                        Spacer()
                        Button("Open LM Studio") { controller.openApplication() }
                        Button("Test & Load Models") { Task { await controller.testConnection() } }.buttonStyle(.borderedProminent).disabled(controller.isLoadingModels)
                    }
                    if let error = controller.lastError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                }.padding(22).background(.background.secondary, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.7)))

                VStack(alignment: .leading, spacing: 14) {
                    Text("Knowledge Base").font(.title3.bold())
                    Toggle("Save completed conversations automatically", isOn: $controller.autoSaveChats)
                    Toggle("Only auto-save starred conversations", isOn: $controller.autoSaveOnlyStarred).disabled(!controller.autoSaveChats)
                    Stepper("Maximum saved messages: \(controller.maximumSavedMessages)", value: $controller.maximumSavedMessages, in: 2...200, step: 2)
                }.padding(22).background(.background.secondary, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.7)))

                VStack(alignment: .leading, spacing: 12) {
                    Text("System Prompt").font(.title3.bold())
                    TextEditor(text: $controller.systemPrompt).font(.body).frame(minHeight: 130).padding(8).background(.background, in: RoundedRectangle(cornerRadius: 10))
                    Text("Authentication is optional unless it is enabled in LM Studio. Tokens are stored in the macOS Keychain. The default local server address is http://127.0.0.1:1234.").font(.caption).foregroundStyle(.secondary)
                }.padding(22).background(.background.secondary, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.7)))
            }.padding(32)
        }
    }
}
