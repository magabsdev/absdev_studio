import AppKit
import CoreText
import SwiftUI
import SwiftTerm

struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 30, weight: .bold))
            Text(subtitle).font(.body).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: symbol).font(.title2).foregroundStyle(.tint)
                Spacer()
            }
            Text(value).font(.system(size: 25, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.75)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 145, alignment: .leading)
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.separator.opacity(0.55)))
    }
}

struct StatusPill: View {
    let text: String
    let active: Bool
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(active ? Color.green : Color.secondary).frame(width: 8, height: 8)
            Text(text).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background((active ? Color.green : Color.secondary).opacity(0.12), in: Capsule())
    }
}

struct ConsoleView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(consoleColor(for: line))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: lines.count) { _, count in
                if count > 0 {
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
    }

    private func consoleColor(for line: String) -> SwiftUI.Color {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let upper = trimmed.uppercased()

        if trimmed.hasPrefix("✓") || upper.hasPrefix("PASS ") || upper.contains(" TESTS PASSED") || upper == "PASS" {
            return .green
        }

        if trimmed.hasPrefix("✕") || trimmed.hasPrefix("⨯") || upper.hasPrefix("FAIL ") || upper.hasPrefix("FAILED ") || upper.contains(" TESTS FAILED") {
            return .red
        }

        if trimmed.hasPrefix("$") {
            return .secondary
        }

        return .primary
    }
}


struct TestFailureDialog: View {
    @Environment(\.dismiss) private var dismiss
    let report: TestFailureReport

    private var completeReport: String {
        """
        \(report.title)
        Project: \(report.projectName)
        Command: \(report.command)
        Exit code: \(report.exitCode)
        Time: \(report.createdAt.formatted(date: .abbreviated, time: .standard))

        \(report.details)
        """
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.red)

                VStack(alignment: .leading, spacing: 5) {
                    Text(report.title)
                        .font(.title2.bold())
                    Text("The passing tests have been omitted. Review the failed tests and their available diagnostic output below.")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Copy Report", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(completeReport, forType: .string)
                }
                .buttonStyle(.bordered)

                Button("Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(24)

            Divider()

            HStack(spacing: 22) {
                Label(report.projectName, systemImage: "folder")
                Label("Exit \(report.exitCode)", systemImage: "exclamationmark.circle")
                Label(report.createdAt.formatted(date: .abbreviated, time: .standard), systemImage: "clock")
                Spacer()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            VStack(alignment: .leading, spacing: 8) {
                Text("Command")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(report.command)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 14)

            ScrollView([.vertical, .horizontal]) {
                Text(report.details)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(18)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.76), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(minWidth: 900, idealWidth: 1050, minHeight: 620, idealHeight: 760)
    }
}


private enum TerminalFontResolver {
    static func preferredFont(size: CGFloat = 14) -> NSFont {
        let manager = NSFontManager.shared
        var candidates: [String] = []

        // PostScript names are the most reliable way to create an NSFont.
        candidates.append(contentsOf: manager.availableFonts)
        for family in manager.availableFontFamilies {
            for member in manager.availableMembers(ofFontFamily: family) ?? [] {
                if let postScriptName = member.first as? String {
                    candidates.append(postScriptName)
                }
            }
        }

        let preferredTokens = [
            "meslolgs", "meslonerd", "jetbrainsmononerd", "jetbrainsmononf",
            "caskaydiacove", "cascadiacode", "hacknerd", "firacodenerd",
            "saucecodepro", "sourcecodenerd", "ubuntumononerd",
            "robotomononerd", "nerdfontmono", "nerdfont", "powerline"
        ]

        func normalized(_ value: String) -> String {
            value.lowercased().filter { $0.isLetter || $0.isNumber }
        }

        let unique = Array(Set(candidates))
        let ranked = unique.sorted { lhs, rhs in
            let left = normalized(lhs)
            let right = normalized(rhs)
            let li = preferredTokens.firstIndex(where: { left.contains($0) }) ?? Int.max
            let ri = preferredTokens.firstIndex(where: { right.contains($0) }) ?? Int.max
            return li == ri ? lhs.localizedStandardCompare(rhs) == .orderedAscending : li < ri
        }

        for name in ranked {
            let normalizedName = normalized(name)
            guard preferredTokens.contains(where: { normalizedName.contains($0) }),
                  let font = NSFont(name: name, size: size),
                  supportsPowerlineGlyphs(font) else { continue }
            return font
        }

        // Fall back to any installed monospaced font that contains Powerline's
        // private-use glyphs, even when its family name is unconventional.
        for name in unique {
            guard let font = NSFont(name: name, size: size),
                  font.isFixedPitch,
                  supportsPowerlineGlyphs(font) else { continue }
            return font
        }

        return NSFont(name: "Menlo-Regular", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func supportsPowerlineGlyphs(_ font: NSFont) -> Bool {
        let coreTextFont = font as CTFont
        var characters: [UniChar] = [0xE0A0, 0xE0B0, 0xE0B2]
        var glyphs = Array(repeating: CGGlyph(), count: characters.count)
        return CTFontGetGlyphsForCharacters(coreTextFont, &characters, &glyphs, characters.count)
            && glyphs.allSatisfy { $0 != 0 }
    }
}

final class FocusableLocalProcessTerminalView: LocalProcessTerminalView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.rightMouseDown(with: event)
    }
}

struct InteractiveTerminalView: NSViewRepresentable {
    let sessionID: UUID
    let executable: String
    let arguments: [String]
    let environment: [String]
    let currentDirectory: String
    let onTermination: @MainActor @Sendable (Int32?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(sessionID: sessionID, onTermination: onTermination)
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = FocusableLocalProcessTerminalView(frame: .zero)
        terminal.processDelegate = context.coordinator
        let terminalFont = TerminalFontResolver.preferredFont(size: 14)
        terminal.font = terminalFont
        terminal.nativeBackgroundColor = NSColor.textBackgroundColor
        terminal.nativeForegroundColor = NSColor.labelColor
        terminal.startProcess(
            executable: executable,
            args: arguments,
            environment: environment,
            execName: URL(fileURLWithPath: executable).lastPathComponent,
            currentDirectory: currentDirectory
        )
        context.coordinator.terminal = terminal
        DispatchQueue.main.async {
            // SwiftTerm may recreate its renderer when the process starts, so
            // re-apply the selected Nerd Font after startup as well.
            terminal.font = terminalFont
            terminal.window?.makeFirstResponder(terminal)
        }
        return terminal
    }

    func updateNSView(_ terminal: LocalProcessTerminalView, context: Context) {
        terminal.processDelegate = context.coordinator
        DispatchQueue.main.async {
            if terminal.window?.firstResponder !== terminal {
                terminal.window?.makeFirstResponder(terminal)
            }
        }
    }

    static func dismantleNSView(_ terminal: LocalProcessTerminalView, coordinator: Coordinator) {
        if terminal.process.running {
            terminal.terminate()
        }
        terminal.processDelegate = nil
        coordinator.terminal = nil
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let sessionID: UUID
        let onTermination: @MainActor @Sendable (Int32?) -> Void
        weak var terminal: LocalProcessTerminalView?

        init(sessionID: UUID, onTermination: @escaping @MainActor @Sendable (Int32?) -> Void) {
            self.sessionID = sessionID
            self.onTermination = onTermination
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            Task { @MainActor [onTermination] in
                onTermination(exitCode)
            }
        }
    }
}

