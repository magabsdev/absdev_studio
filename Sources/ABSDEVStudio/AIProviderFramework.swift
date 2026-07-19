import SwiftUI
import Observation

// Provider-neutral contracts used by ABSDEV Studio's AI workspace.
enum AIProviderID: String, CaseIterable, Codable, Identifiable {
    case lmStudio
    case openWebUI

    var id: String { rawValue }
    var title: String {
        switch self {
        case .lmStudio: "LM Studio"
        case .openWebUI: "Open WebUI"
        }
    }
    var symbol: String {
        switch self {
        case .lmStudio: "cpu.fill"
        case .openWebUI: "bubble.left.and.bubble.right.fill"
        }
    }
    var isLocal: Bool { self == .lmStudio }
}

enum AIProviderCapability: String, CaseIterable, Hashable {
    case chat = "Chat"
    case streaming = "Streaming"
    case models = "Model discovery"
    case knowledge = "Knowledge Base"
    case tools = "MCP tools"
}

struct AIProviderDescriptor: Identifiable, Hashable {
    let id: AIProviderID
    let subtitle: String
    let capabilities: Set<AIProviderCapability>
}

@MainActor
protocol AIProviderAdapter: AnyObject {
    var providerID: AIProviderID { get }
    var isConfigured: Bool { get }
    var isBusy: Bool { get }
    var connectionSummary: String { get }
    func newConversation()
    func stop()
    func refreshModels() async
}

@MainActor
final class LMStudioProviderAdapter: AIProviderAdapter {
    private let controller: LMStudioController
    init(_ controller: LMStudioController) { self.controller = controller }
    var providerID: AIProviderID { .lmStudio }
    var isConfigured: Bool { controller.configured }
    var isBusy: Bool { controller.isSending }
    var connectionSummary: String { controller.connectionStatus }
    func newConversation() { controller.newChat() }
    func stop() { controller.cancelGeneration() }
    func refreshModels() async { await controller.loadModels() }
}

@MainActor
final class OpenWebUIProviderAdapter: AIProviderAdapter {
    private let controller: OpenWebUIController
    init(_ controller: OpenWebUIController) { self.controller = controller }
    var providerID: AIProviderID { .openWebUI }
    var isConfigured: Bool { controller.configured }
    var isBusy: Bool { controller.isSending }
    var connectionSummary: String { controller.connectionStatus }
    func newConversation() { controller.newChat() }
    func stop() { controller.cancelGeneration() }
    func refreshModels() async { await controller.loadModels() }
}

@MainActor
@Observable
final class AIProviderRegistry {
    var selectedProvider: AIProviderID {
        didSet { UserDefaults.standard.set(selectedProvider.rawValue, forKey: "ai.defaultProvider") }
    }
    var enabledProviders: Set<AIProviderID> {
        didSet {
            UserDefaults.standard.set(enabledProviders.map(\.rawValue), forKey: "ai.enabledProviders")
            if !enabledProviders.contains(selectedProvider), let first = enabledProviders.first {
                selectedProvider = first
            }
        }
    }

    let descriptors: [AIProviderDescriptor] = [
        AIProviderDescriptor(id: .lmStudio, subtitle: "Local OpenAI-compatible models", capabilities: [.chat, .streaming, .models, .knowledge]),
        AIProviderDescriptor(id: .openWebUI, subtitle: "Self-hosted model gateway and chat", capabilities: [.chat, .streaming, .models, .knowledge, .tools])
    ]

    @ObservationIgnored private var adapters: [AIProviderID: any AIProviderAdapter] = [:]

    init(lmStudio: LMStudioController, openWebUI: OpenWebUIController) {
        let saved = UserDefaults.standard.string(forKey: "ai.defaultProvider").flatMap(AIProviderID.init(rawValue:)) ?? .lmStudio
        let enabledRaw = UserDefaults.standard.stringArray(forKey: "ai.enabledProviders")
        selectedProvider = saved
        enabledProviders = Set((enabledRaw ?? AIProviderID.allCases.map(\.rawValue)).compactMap(AIProviderID.init(rawValue:)))
        adapters[.lmStudio] = LMStudioProviderAdapter(lmStudio)
        adapters[.openWebUI] = OpenWebUIProviderAdapter(openWebUI)
    }

    var availableDescriptors: [AIProviderDescriptor] {
        descriptors.filter { enabledProviders.contains($0.id) }
    }

    func adapter(for id: AIProviderID) -> (any AIProviderAdapter)? { adapters[id] }
    func setEnabled(_ enabled: Bool, provider: AIProviderID) {
        if enabled { enabledProviders.insert(provider) }
        else { enabledProviders.remove(provider) }
    }
    func newConversation() { adapters[selectedProvider]?.newConversation() }
    func stop() { adapters[selectedProvider]?.stop() }
    func refreshModels() async { await adapters[selectedProvider]?.refreshModels() }
}

struct AIWorkspaceView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var registry = store.aiProviders
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("AI Workspace", systemImage: "sparkles")
                    .font(.title2.bold())
                Picker("Provider", selection: $registry.selectedProvider) {
                    ForEach(registry.availableDescriptors) { provider in
                        Label(provider.id.title, systemImage: provider.id.symbol).tag(provider.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 230)
                Spacer()
                Button { registry.newConversation() } label: { Label("New Chat", systemImage: "plus") }
                Button { Task { await registry.refreshModels() } } label: { Label("Refresh Models", systemImage: "arrow.clockwise") }
                    .disabled(registry.adapter(for: registry.selectedProvider)?.isConfigured != true)
                Button { registry.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .disabled(registry.adapter(for: registry.selectedProvider)?.isBusy != true)
            }
            .padding(16)
            .background(.bar)

            if registry.availableDescriptors.isEmpty {
                ContentUnavailableView("No AI Provider Enabled", systemImage: "sparkles", description: Text("Enable at least one provider in Settings → AI Providers."))
            } else {
                switch registry.selectedProvider {
                case .lmStudio: LMStudioView()
                case .openWebUI: OpenWebUIView()
                }
            }
        }
    }
}

struct AIProviderManagerSettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var registry = store.aiProviders
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("AI Providers").font(.title2.bold())
                    Text("Choose the providers available in the unified AI Workspace. Provider credentials remain in Keychain.")
                        .foregroundStyle(.secondary)
                }
                Picker("Default Provider", selection: $registry.selectedProvider) {
                    ForEach(registry.availableDescriptors) { provider in
                        Text(provider.id.title).tag(provider.id)
                    }
                }
                .disabled(registry.availableDescriptors.isEmpty)

                ForEach(registry.descriptors) { provider in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(provider.id.title, systemImage: provider.id.symbol).font(.headline)
                            Spacer()
                            Toggle("Enabled", isOn: Binding(
                                get: { registry.enabledProviders.contains(provider.id) },
                                set: { registry.setEnabled($0, provider: provider.id) }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                        }
                        Text(provider.subtitle).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            ForEach(Array(provider.capabilities).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { capability in
                                Text(capability.rawValue)
                                    .font(.caption)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                        Text(registry.adapter(for: provider.id)?.connectionSummary ?? "Not available")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(18)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.6)))
                }
            }
            .padding(32)
        }
    }
}
