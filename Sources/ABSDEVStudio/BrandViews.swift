import AppKit
import SwiftUI

extension Color {
    static let studioBlue = Color(red: 0.18, green: 0.49, blue: 1.0)
    static let laravelRed = studioBlue
    static let terminalGreen = Color(red: 0.35, green: 0.82, blue: 0.36)
    static let warningAmber = Color(red: 1.0, green: 0.67, blue: 0.16)
    static let infoBlue = Color(red: 0.24, green: 0.62, blue: 1.0)
    static let forgePurple = Color(red: 0.56, green: 0.38, blue: 0.95)
}

struct BrandMark: View {
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(nsColor: .windowBackgroundColor), .black.opacity(0.9)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                        .stroke(.white.opacity(0.16), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.3), radius: size * 0.12, y: size * 0.08)

            Text("A")
                .font(.system(size: size * 0.48, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .offset(x: -size * 0.12, y: 0)

            Text("S")
                .font(.system(size: size * 0.48, weight: .black, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, .studioBlue],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .offset(x: size * 0.13, y: 0)
        }
        .frame(width: size, height: size)
    }
}

struct LaunchExperienceView: View {
    @State private var appeared = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            RadialGradient(
                colors: [.laravelRed.opacity(0.18), .clear],
                center: .center,
                startRadius: 10,
                endRadius: 330
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                BrandMark(size: 112)
                    .scaleEffect(appeared ? 1 : 0.86)
                    .opacity(appeared ? 1 : 0)

                VStack(spacing: 6) {
                    Text("ABSDEV Studio")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("The native local development studio")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .offset(y: appeared ? 0 : 12)
                .opacity(appeared ? 1 : 0)

                ProgressView()
                    .controlSize(.small)
                    .tint(.laravelRed)
                    .padding(.top, 6)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                appeared = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("ABSDEV Studio is starting")
    }
}

struct AboutABSDEVStudioView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 20) {
            BrandMark(size: 118)

            VStack(spacing: 6) {
                Text("ABSDEV Studio")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Version \(version) (\(build))")
                    .foregroundStyle(.secondary)
            }

            Text("A professional native macOS workspace for managing local projects, services, containers, commands, logs and development workflows.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)

            HStack(spacing: 20) {
                Label("Laravel", systemImage: "shippingbox.fill")
                    .foregroundStyle(Color.laravelRed)
                Label("macOS", systemImage: "macwindow")
                    .foregroundStyle(Color.infoBlue)
                Label("SwiftUI", systemImage: "swift")
                    .foregroundStyle(Color.warningAmber)
            }
            .font(.callout.weight(.semibold))

            Divider()

            Text("Copyright © 2026 ABSDEV. All rights reserved.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(36)
        .frame(width: 500, height: 480)
    }
}

struct MenuBarPanel: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var store = store

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                BrandMark(size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("ABSDEV Studio").fontWeight(.semibold)
                    Text(store.selectedProject?.name ?? "No project selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Button {
                store.toggleDevelopment()
            } label: {
                Label(
                    store.isDevelopmentRunning ? "Stop Development" : "Start Development",
                    systemImage: store.isDevelopmentRunning ? "stop.fill" : "play.fill"
                )
            }

            Button("Open Main Window", systemImage: "macwindow") {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }

            Button("Open Project in Terminal", systemImage: "terminal.fill") {
                store.openInTerminal()
            }
            .disabled(store.selectedProject == nil)

            Divider()

            Button("About ABSDEV Studio", systemImage: "info.circle") {
                openWindow(id: "about")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }

            Button("Quit ABSDEV Studio", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 270)
    }
}

struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About ABSDEV Studio") {
                openWindow(id: "about")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
    }
}
