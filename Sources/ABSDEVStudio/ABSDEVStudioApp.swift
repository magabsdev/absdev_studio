import AppKit
import SwiftUI

@main
struct ABSDEVStudioApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(store)
                .frame(minWidth: 1160, minHeight: 720)
                .tint(.laravelRed)
        }
        .defaultSize(width: 1380, height: 880)
        .commands {
            AboutCommands()

            CommandGroup(after: .newItem) {
                Button("Add Laravel Project…") {
                    store.addProject()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            CommandMenu("Navigate") {
                Button("Command Palette…") { store.presentCommandPalette() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                Button("Overview") { store.selectedSection = .overview }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("Development") { store.selectedSection = .development }
                    .keyboardShortcut("2", modifiers: [.command])
                Button("Artisan") { store.selectedSection = .artisan }
                    .keyboardShortcut("3", modifiers: [.command])
                Button("Terminal") { store.selectedSection = .terminal }
                    .keyboardShortcut("4", modifiers: [.command])
            }

            CommandMenu("Project") {
                Button("Rename Project…") {
                    NotificationCenter.default.post(name: .absdevRenameSelectedProject, object: nil)
                }
                .keyboardShortcut(.return, modifiers: [])
                Button("Delete Project…") {
                    NotificationCenter.default.post(name: .absdevDeleteSelectedProject, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                Divider()
                Button("Refresh Capabilities") { store.refreshProjectCapabilities() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Quick Look Project") { store.quickLookProject() }
                    .keyboardShortcut("y", modifiers: [.command])
                Button("Reveal in Finder") { store.revealInFinder() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Copy Project Path") { store.copyProjectPath() }
                    .keyboardShortcut("c", modifiers: [.command, .option])
            }

            if store.aiFeaturesEnabled {
                CommandMenu("AI") {
                    Button("Open AI Workspace") { store.selectedSection = .aiWorkspace }
                        .keyboardShortcut("a", modifiers: [.command, .shift])
                    Button("New Conversation") {
                        store.aiProviders.newConversation()
                        store.selectedSection = .aiWorkspace
                    }
                        .keyboardShortcut("n", modifiers: [.command, .option])
                    Divider()
                    Button("Refresh Models") { Task { await store.aiProviders.refreshModels() } }
                        .disabled(store.aiProviders.adapter(for: store.aiProviders.selectedProvider)?.isConfigured != true)
                    Button("Stop Generation") { store.aiProviders.stop() }
                        .disabled(store.aiProviders.adapter(for: store.aiProviders.selectedProvider)?.isBusy != true)
                    Divider()
                    Button("Open MCP Tools") { store.selectedSection = .mcp }
                        .keyboardShortcut("m", modifiers: [.command, .shift])
                    Button("Refresh MCP Tools") { Task { await store.openWebUI.mcp.refreshAll() } }
                        .disabled(store.openWebUI.mcp.servers.isEmpty)
                    Divider()
                    SettingsLink { Text("AI Provider Settings…") }
                }
            }

            CommandMenu("Laravel") {
                Button(store.isDevelopmentRunning ? "Stop Development" : "Start Development") {
                    store.toggleDevelopment()
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Run Artisan Command") {
                    store.selectedSection = .artisan
                }
                .keyboardShortcut("k", modifiers: [.command])
            }
        }

        Window("About ABSDEV Studio", id: "about") {
            AboutABSDEVStudioView()
                .tint(.laravelRed)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environment(store)
                .frame(minWidth: 760, idealWidth: 820, minHeight: 540, idealHeight: 620)
                .tint(.laravelRed)
        }

        MenuBarExtra("ABSDEV Studio", systemImage: "terminal.fill") {
            MenuBarPanel()
                .environment(store)
        }
        .menuBarExtraStyle(.window)
    }
}


extension Notification.Name {
    static let absdevRenameSelectedProject = Notification.Name("ABSDEVStudio.renameSelectedProject")
    static let absdevDeleteSelectedProject = Notification.Name("ABSDEVStudio.deleteSelectedProject")
}
