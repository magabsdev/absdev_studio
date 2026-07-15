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
