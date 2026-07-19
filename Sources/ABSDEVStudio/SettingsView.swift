import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        TabView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    SettingsSection(title: "PHP Runtime", subtitle: "The PHP binary used for Artisan and project inspection.") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                TextField("PHP executable", text: $store.phpPath)
                                    .textFieldStyle(.roundedBorder)
                                Button("Choose…") { store.choosePHPExecutable() }
                                Button("Detect") { store.detectPHP() }
                            }
                            Label(store.phpStatus, systemImage: store.phpStatus.hasPrefix("PHP ") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(store.phpStatus.hasPrefix("PHP ") ? .green : .orange)
                        }
                    }

                    SettingsSection(title: "Applications", subtitle: "Choose the applications opened from the project toolbar.") {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
                            GridRow {
                                Text("Default editor").frame(width: 140, alignment: .leading)
                                Picker("", selection: $store.editor) {
                                    Text("Xcode").tag("Xcode")
                                    Text("Visual Studio Code").tag("Visual Studio Code")
                                    Text("PhpStorm").tag("PhpStorm")
                                }.labelsHidden().frame(width: 260)
                            }
                            GridRow {
                                Text("Terminal").frame(width: 140, alignment: .leading)
                                Picker("", selection: $store.terminal) {
                                    Text("Terminal").tag("Terminal")
                                    Text("iTerm").tag("iTerm")
                                    Text("Warp").tag("Warp")
                                }.labelsHidden().frame(width: 260)
                            }
                        }
                    }

                    HStack {
                        Button("Validate PHP") { Task { await store.validateSelectedPHP() } }
                        Spacer()
                        Button("Refresh Current Project") { Task { await store.refreshProject() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(32)
            }
            .tabItem { Label("Tools", systemImage: "hammer") }

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    SettingsSection(title: "Project Behaviour", subtitle: "ABSDEV Studio stores project references in Application Support.") {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Development services are stopped explicitly from the toolbar or Development screen.", systemImage: "stop.circle")
                            Label("Commands run with an expanded developer PATH containing ServBay, Homebrew, Volta and system tools.", systemImage: "terminal")
                            Divider()
                            Text("Current status: \(store.statusMessage)").foregroundStyle(.secondary)
                        }
                    }
                }.padding(32)
            }
            .tabItem { Label("Behaviour", systemImage: "gearshape") }

            AISettingsView()
                .tabItem { Label("AI", systemImage: "sparkles") }

            if store.aiFeaturesEnabled {
                AIProviderManagerSettingsView()
                    .tabItem { Label("Providers", systemImage: "square.stack.3d.up.fill") }

                LMStudioSettingsView()
                    .tabItem { Label("LM Studio", systemImage: "cpu.fill") }

                OpenWebUISettingsView()
                    .tabItem { Label("Open WebUI", systemImage: "bubble.left.and.bubble.right.fill") }

                MCPSettingsView()
                    .tabItem { Label("MCP", systemImage: "point.3.connected.trianglepath.dotted") }
            }
        }
        .frame(minWidth: 760, minHeight: 540)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.bold())
                Text(subtitle).foregroundStyle(.secondary)
            }
            content
        }
        .padding(22)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.7)))
    }
}


private struct AISettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsSection(
                    title: "AI Features",
                    subtitle: "Enable optional local and self-hosted AI integrations in ABSDEV Studio."
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Enable AI Features", isOn: $store.aiFeaturesEnabled)
                            .toggleStyle(.switch)

                        Text(store.aiFeaturesEnabled
                             ? "The unified AI Workspace, enabled providers, MCP Tools and installed Laravel AI controls are available. Configure providers in the Providers tab."
                             : "AI workspaces, menus, commands and Laravel AI controls are hidden. Existing provider settings and Knowledge Base documents are preserved.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                SettingsSection(
                    title: "Knowledge Context",
                    subtitle: "Use project documents as retrieval context with every enabled AI provider."
                ) {
                    @Bindable var knowledge = AIKnowledgeContext.shared
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Use Knowledge Base in AI Context", isOn: $knowledge.enabled)
                        Stepper("Maximum context documents: \(knowledge.maximumDocuments)", value: $knowledge.maximumDocuments, in: 1...20)
                            .disabled(!knowledge.enabled)
                        Stepper("Maximum context size: \(knowledge.maximumCharacters) characters", value: $knowledge.maximumCharacters, in: 2_000...60_000, step: 2_000)
                            .disabled(!knowledge.enabled)
                        Button("Add Documents to AI Context", systemImage: "doc.badge.plus") {
                            guard let project = store.selectedProject else { return }
                            knowledge.importDocuments(projectID: project.id)
                        }
                        .disabled(store.selectedProject == nil)
                        if let status = knowledge.status {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                        if let error = knowledge.lastError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                        Text("Documents remain in the standard Knowledge Base. Relevant excerpts are selected for each request; the underlying model is not permanently modified.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsSection(
                    title: "Privacy",
                    subtitle: "AI remains opt-in and provider connections are made only when enabled."
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Provider credentials remain stored in the macOS Keychain.", systemImage: "key.fill")
                        Label("Disabling AI stops active chat generation and returns AI workspaces to Overview.", systemImage: "stop.circle.fill")
                        Label("Saved Knowledge Base content is not deleted when AI is disabled.", systemImage: "books.vertical.fill")
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(32)
        }
    }
}
