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

            LMStudioSettingsView()
                .tabItem { Label("LM Studio", systemImage: "cpu.fill") }

            OpenWebUISettingsView()
                .tabItem { Label("Open WebUI", systemImage: "bubble.left.and.bubble.right.fill") }

            MCPSettingsView()
                .tabItem { Label("MCP", systemImage: "point.3.connected.trianglepath.dotted") }
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
