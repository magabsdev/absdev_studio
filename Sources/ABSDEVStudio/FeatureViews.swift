import SwiftUI

struct DevelopmentView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    PageHeader(title: "Development", subtitle: "Run and supervise the services used by this Laravel project.")
                    Spacer()
                    Button("Stop All", role: .destructive) { store.stopAllProcesses() }
                    Button("Start All") { store.startDefaultProcesses() }.buttonStyle(.borderedProminent)
                }
                CommandResultsCard()

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 520), spacing: 18)], spacing: 18) {
                    ForEach(store.processes.filter { process in
                        process.name != "Laravel Server" || store.shouldShowLaravelDevelopmentServer
                    }) { process in
                        ProcessCard(process: process)
                    }
                }
            }.padding(32)
        }
    }
}


private struct CommandResultsCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: store.isBusy ? "terminal.fill" : "terminal")
                    .font(.title2)
                    .foregroundStyle(store.isBusy ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Command Output").font(.headline)
                    Text(store.isBusy ? store.statusMessage : "Output from control-centre, Artisan and shell commands.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.isBusy {
                    ProgressView().controlSize(.small)
                    Button("Stop", role: .destructive) { store.cancelForegroundCommand() }
                        .buttonStyle(.bordered)
                }
                Button("Clear") { store.clearConsole() }
                    .buttonStyle(.bordered)
                    .disabled(store.commandOutput.isEmpty)
            }

            if store.commandOutput.isEmpty {
                ContentUnavailableView(
                    "No command output yet",
                    systemImage: "terminal",
                    description: Text("Run a control-centre action to see its complete output here.")
                )
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                ConsoleView(lines: store.commandOutput)
                    .frame(minHeight: 220, idealHeight: 300, maxHeight: 420)
            }
        }
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.separator.opacity(0.6)))
    }
}

private struct ProcessCard: View {
    @Environment(AppStore.self) private var store
    let process: DevProcess
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill((process.isRunning ? Color.green : Color.secondary).opacity(0.12))
                    Image(systemName: process.symbol).font(.title2).foregroundStyle(process.isRunning ? .green : .secondary)
                }.frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(process.name).font(.headline)
                    Text(process.detail).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(text: process.isRunning ? "Running" : "Stopped", active: process.isRunning)
                Button(process.isRunning ? "Stop" : (process.name == "Production Build" ? "Build" : "Start")) {
                    store.toggleProcess(process)
                }
                .buttonStyle(.borderedProminent)
                .tint(process.isRunning ? .red : .green)
            }
            if !process.output.isEmpty {
                ConsoleView(lines: Array(process.output.suffix(20))).frame(minHeight: 110, maxHeight: 170)
            } else {
                Text("No process output yet.").font(.caption).foregroundStyle(.tertiary).frame(height: 28)
            }
        }
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.separator.opacity(0.6)))
    }
}

struct EnvironmentView: View {
    @Environment(AppStore.self) private var store
    @State private var search = ""
    @State private var editingEntry: EnvironmentEntry?
    @State private var editedValue = ""
    var filteredEntries: [EnvironmentEntry] { search.isEmpty ? store.environmentEntries : store.environmentEntries.filter { $0.key.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack { VStack(alignment: .leading, spacing: 5) { Text("Environment").font(.largeTitle.bold()); Text("Edit .env values while preserving unrelated lines.").foregroundStyle(.secondary) }; Spacer(); Button("Reload") { store.loadEnvironment() }; Button("Compare with .env.example") { store.compareEnvironment() }; Button("Save Changes") { store.saveEnvironment() }.buttonStyle(.borderedProminent) }.padding(28)
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Filter variables", text: $search).textFieldStyle(.plain); Spacer(); Text("\(filteredEntries.count) variables").font(.caption).foregroundStyle(.secondary) }.padding(10).background(.background.secondary, in: RoundedRectangle(cornerRadius: 9)).padding(.horizontal, 28).padding(.bottom, 14)
            List(filteredEntries) { entry in
                HStack(spacing: 16) { Text(entry.key).font(.callout.monospaced().weight(.semibold)).frame(width: 190, alignment: .leading); Text(entry.isSecret ? "••••••••" : entry.value).font(.callout.monospaced()).foregroundStyle(entry.isSecret ? .secondary : .primary); Spacer(); if entry.isSecret { Image(systemName: "lock.fill").foregroundStyle(.secondary) }; Button("Edit") { editingEntry = entry; editedValue = entry.value }.buttonStyle(.borderless) }.padding(.vertical, 5)
            }.listStyle(.inset)
        }
        .sheet(item: $editingEntry) { entry in
            VStack(alignment: .leading, spacing: 16) { Text("Edit \(entry.key)").font(.title2.bold()); TextField("Value", text: $editedValue).textFieldStyle(.roundedBorder); HStack { Spacer(); Button("Cancel") { editingEntry = nil }; Button("Save") { store.updateEnvironmentEntry(entry, newValue: editedValue); editingEntry = nil }.buttonStyle(.borderedProminent) } }.padding(24).frame(width: 520)
        }
        .sheet(isPresented: Bindable(store).isEnvironmentComparisonPresented) {
            EnvironmentComparisonView(
                exampleContent: store.environmentExampleContent,
                currentContent: store.environmentCurrentContent
            )
        }
    }
}


private struct EnvironmentComparisonView: View {
    @Environment(\.dismiss) private var dismiss
    let exampleContent: String
    let currentContent: String

    private var exampleLines: [String] {
        exampleContent.components(separatedBy: .newlines)
    }

    private var currentLines: [String] {
        currentContent.components(separatedBy: .newlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Compare Environment Files").font(.title2.bold())
                    Text("Review the template and active environment side by side.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(22)

            Divider()

            HSplitView {
                EnvironmentFileColumn(
                    title: ".env.example",
                    subtitle: "Project template",
                    lines: exampleLines,
                    counterpart: currentLines
                )
                EnvironmentFileColumn(
                    title: ".env",
                    subtitle: "Current project values",
                    lines: currentLines,
                    counterpart: exampleLines
                )
            }
        }
        .frame(minWidth: 1100, idealWidth: 1380, minHeight: 700, idealHeight: 820)
    }
}

private struct EnvironmentFileColumn: View {
    let title: String
    let subtitle: String
    let lines: [String]
    let counterpart: [String]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline.monospaced())
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(lines.count) lines")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.background.secondary)

            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .top, spacing: 12) {
                            Text(String(index + 1))
                                .foregroundStyle(.tertiary)
                                .frame(width: 42, alignment: .trailing)
                            Text(line.isEmpty ? " " : line)
                                .textSelection(.enabled)
                                .foregroundStyle(lineColour(at: index))
                            Spacer(minLength: 12)
                        }
                        .font(.system(.callout, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2)
                        .background(lineBackground(at: index))
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.background)
    }

    private func lineBackground(at index: Int) -> Color {
        guard index >= counterpart.count || counterpart[index] != lines[index] else { return .clear }
        return .orange.opacity(0.08)
    }

    private func lineColour(at index: Int) -> Color {
        guard index >= counterpart.count || counterpart[index] != lines[index] else { return .primary }
        return .orange
    }
}

struct ArtisanView: View {
    @Environment(AppStore.self) private var store
    @State private var command = "about"
    @State private var parameterValues: [String: String] = [:]
    @State private var enabledFlags: Set<String> = []
    @State private var search = ""
    @State private var selectedCommandName: String?
    @State private var expandedCommandGroups: Set<String> = []

    private var filteredCommands: [ArtisanCommand] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.artisanCommands }
        return store.artisanCommands.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.description.localizedCaseInsensitiveContains(query) ||
            $0.aliases.contains(where: { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    private var groupedCommands: [(name: String, commands: [ArtisanCommand])] {
        let favourites = ["about", "test", "migrate", "migrate:status", "optimize:clear", "route:list", "queue:work"]
        var result: [(String, [ArtisanCommand])] = []
        let favouriteCommands = favourites.compactMap { favourite in
            filteredCommands.first(where: { $0.name == favourite })
        }
        if !favouriteCommands.isEmpty, search.isEmpty {
            result.append(("Favourites", favouriteCommands))
        }

        let favouriteNames = Set(favouriteCommands.map(\.name))
        let remainder = filteredCommands.filter { !favouriteNames.contains($0.name) || !search.isEmpty }
        let dictionary = Dictionary(grouping: remainder, by: \.namespace)
        result.append(contentsOf: dictionary.keys.sorted().map { namespace in
            (namespace, dictionary[namespace, default: []].sorted { $0.name < $1.name })
        })
        return result
    }

    private var selectedCommand: ArtisanCommand? {
        guard let selectedCommandName else { return nil }
        return store.artisanCommands.first { $0.name == selectedCommandName }
    }

    private func selectCommand(_ item: ArtisanCommand) {
        selectedCommandName = item.name
        command = item.name
        parameterValues = [:]
        enabledFlags = []
    }

    private var commandParameters: [ArtisanUIParameter] {
        selectedCommand.map(ArtisanUIParameter.parse) ?? []
    }

    private func runSelectedCommand() {
        var pieces = [command]
        for parameter in commandParameters {
            let value = parameterValues[parameter.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            switch parameter.kind {
            case .argument:
                if !value.isEmpty { pieces.append(artisanShellQuote(value)) }
            case .flag:
                if enabledFlags.contains(parameter.id) { pieces.append("--\(parameter.name)") }
            case .option:
                if !value.isEmpty { pieces.append("--\(parameter.name)=\(artisanShellQuote(value))") }
            }
        }
        store.runArtisan(pieces.joined(separator: " "))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                HStack(alignment: .center, spacing: 16) {
                    PageHeader(
                        title: "Artisan",
                        subtitle: "Every command exposed by this project, including Laravel, packages, modules, and custom commands."
                    )
                    Spacer(minLength: 24)
                    if store.isLoadingArtisanCommands || store.isBusy {
                        ProgressView().controlSize(.small)
                    }
                    Button("Scan Commands", systemImage: "arrow.clockwise") {
                        Task { await store.refreshArtisanCommands() }
                    }
                    .disabled(store.isLoadingArtisanCommands || store.isBusy)
                    Button("Clear Output") { store.clearConsole() }
                        .buttonStyle(.bordered)
                }

                HStack(spacing: 12) {
                    Label {
                        Text("php artisan \(command)")
                            .font(.body.monospaced().weight(.semibold))
                            .textSelection(.enabled)
                    } icon: {
                        Image(systemName: "terminal")
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 34)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                    .help("Select a command from the list. This value cannot be edited.")

                    Spacer()

                    Button("Run") { runSelectedCommand() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(store.isBusy || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                HStack(spacing: 8) {
                    Image(systemName: store.artisanCommands.isEmpty ? "exclamationmark.triangle" : "checkmark.seal.fill")
                        .foregroundStyle(store.artisanCommands.isEmpty ? Color.orange : Color.green)
                    Text(store.artisanDiscoveryMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    if !store.artisanCommands.isEmpty {
                        Text("\(store.artisanCommands.count) installed")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Divider()

            HSplitView {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Filter names and descriptions", text: $search)
                            .textFieldStyle(.plain)
                        if !search.isEmpty {
                            Button { search = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 9))
                    .padding(14)

                    HStack(spacing: 10) {
                        Button("Expand All") {
                            expandedCommandGroups = Set(groupedCommands.map(\.name))
                        }
                        .buttonStyle(.borderless)
                        Button("Collapse All") {
                            expandedCommandGroups.removeAll()
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                    }
                    .font(.caption)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)

                    if store.artisanCommands.isEmpty && !store.isLoadingArtisanCommands {
                        ContentUnavailableView {
                            Label("No Commands Loaded", systemImage: "terminal")
                        } description: {
                            Text("Scan the selected project to load commands supported by its Laravel version and installed packages.")
                        } actions: {
                            Button("Scan Commands") { Task { await store.refreshArtisanCommands() } }
                                .buttonStyle(.borderedProminent)
                        }
                    } else {
                        List(selection: $selectedCommandName) {
                            ForEach(groupedCommands, id: \.name) { group in
                                DisclosureGroup(
                                    isExpanded: Binding(
                                        get: { expandedCommandGroups.contains(group.name) },
                                        set: { isExpanded in
                                            if isExpanded { expandedCommandGroups.insert(group.name) }
                                            else { expandedCommandGroups.remove(group.name) }
                                        }
                                    )
                                ) {
                                    ForEach(group.commands) { item in
                                        ArtisanCommandRow(item: item)
                                            .tag(item.name)
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                selectCommand(item)
                                            }
                                    }
                                } label: {
                                    HStack {
                                        Text(group.name)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("\(group.commands.count)")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                        .listStyle(.sidebar)
                    }
                }
                .frame(minWidth: 330, idealWidth: 390, maxWidth: 480, maxHeight: .infinity, alignment: .topLeading)

                VStack(spacing: 0) {
                    if let selectedCommand {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "terminal.fill").foregroundStyle(.mint)
                                Text(selectedCommand.name).font(.headline.monospaced())
                                Spacer()
                            }
                            if !selectedCommand.description.isEmpty {
                                Text(selectedCommand.description).font(.callout).foregroundStyle(.secondary)
                            }
                            if !selectedCommand.usage.isEmpty {
                                Text(selectedCommand.primaryUsage)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .foregroundStyle(.secondary)
                            }
                            if !selectedCommand.aliases.isEmpty {
                                Text("Aliases: \(selectedCommand.aliases.joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)

                        if !commandParameters.isEmpty {
                            Divider()
                            ArtisanParameterForm(
                                parameters: commandParameters,
                                values: $parameterValues,
                                enabledFlags: $enabledFlags
                            )
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                        }
                        Divider()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("Command Output").font(.headline)
                            Spacer()
                            if store.isInteractiveArtisanTerminalVisible {
                                Button(
                                    store.isInteractiveArtisanSession ? "Stop" : "Close",
                                    systemImage: store.isInteractiveArtisanSession ? "stop.fill" : "xmark"
                                ) {
                                    store.stopInteractiveArtisanSession()
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                                .controlSize(.small)
                                .keyboardShortcut(.escape, modifiers: [])
                            }
                            Text(store.statusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if store.isInteractiveArtisanTerminalVisible {
                            InteractiveTerminalView(
                                sessionID: store.interactiveArtisanSessionID,
                                executable: store.interactiveArtisanExecutable,
                                arguments: store.interactiveArtisanArguments,
                                environment: store.interactiveArtisanEnvironment,
                                currentDirectory: store.interactiveArtisanDirectory,
                                onTermination: { store.interactiveArtisanDidTerminate(exitCode: $0) }
                            )
                            .id(store.interactiveArtisanSessionID)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ConsoleView(lines: store.commandOutput)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .padding(.top, 16)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
                .frame(minWidth: 680, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .layoutPriority(1)
        }
        .frame(minWidth: 1050, minHeight: 700, maxHeight: .infinity, alignment: .topLeading)
        .task(id: store.selectedProjectID) {
            if store.artisanCommands.isEmpty {
                await store.refreshArtisanCommands()
            }
        }
    }
}


struct CommandProgressDialog: View {
    let store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.black.gradient)
                    Text("AS")
                        .font(.system(size: 21, weight: .heavy, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white, Color(red: 0.25, green: 0.55, blue: 1.0)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .frame(width: 48, height: 48)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(store.commandProgressTitle)
                        .font(.title3.weight(.semibold))
                    Text("ABSDEV Studio is working in the selected project")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text(store.commandProgressCommand)
                .font(.body.monospaced().weight(.semibold))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 9))

            ProgressView()
                .progressViewStyle(.linear)

            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(store.commandProgressDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let started = store.commandProgressStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let elapsed = max(0, Int(context.date.timeIntervalSince(started)))
                        Text(String(format: "%02d:%02d", elapsed / 60, elapsed % 60))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            HStack {
                Text("Command output continues to update behind this dialog.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel", role: .destructive) {
                    store.cancelForegroundCommand()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}


private enum ArtisanParameterKind {
    case argument
    case flag
    case option
}

private struct ArtisanUIParameter: Identifiable, Hashable {
    let id: String
    let name: String
    let label: String
    let kind: ArtisanParameterKind
    let required: Bool
    let repeatable: Bool
    let placeholder: String

    static func parse(_ command: ArtisanCommand) -> [ArtisanUIParameter] {
        let usage = command.primaryUsage
        var result: [ArtisanUIParameter] = []
        var seen = Set<String>()

        // Symfony/Laravel usage marks positional arguments as <name> or [<name>].
        let argumentPattern = #"(\[)?<([A-Za-z0-9_-]+)>(\.\.\.)?(\])?"#
        if let regex = try? NSRegularExpression(pattern: argumentPattern) {
            let range = NSRange(usage.startIndex..., in: usage)
            for match in regex.matches(in: usage, range: range) {
                guard let nameRange = Range(match.range(at: 2), in: usage) else { continue }
                let name = String(usage[nameRange])
                let id = "argument:\(name)"
                guard seen.insert(id).inserted else { continue }
                let optional = match.range(at: 1).location != NSNotFound || match.range(at: 4).location != NSNotFound
                let repeatable = match.range(at: 3).location != NSNotFound
                result.append(.init(
                    id: id,
                    name: name,
                    label: name.replacingOccurrences(of: "-", with: " ").capitalized,
                    kind: .argument,
                    required: !optional,
                    repeatable: repeatable,
                    placeholder: repeatable ? "Enter one or more values" : "Enter \(name)"
                ))
            }
        }

        // Long options are either switches (--force) or values (--database=DATABASE).
        let optionPattern = #"--([A-Za-z0-9][A-Za-z0-9-]*)(?:=|\s+)?(?:\[?<?([A-Z][A-Z0-9_-]*)>?\]?)?"#
        if let regex = try? NSRegularExpression(pattern: optionPattern) {
            let range = NSRange(usage.startIndex..., in: usage)
            for match in regex.matches(in: usage, range: range) {
                guard let nameRange = Range(match.range(at: 1), in: usage) else { continue }
                let name = String(usage[nameRange])
                guard name != "help" && name != "quiet" && name != "verbose" && name != "version" && name != "ansi" && name != "no-ansi" && name != "no-interaction" && name != "env" else { continue }
                let id = "option:\(name)"
                guard seen.insert(id).inserted else { continue }
                let valueName: String? = match.range(at: 2).location == NSNotFound ? nil : Range(match.range(at: 2), in: usage).map { String(usage[$0]) }
                if let valueName, !valueName.isEmpty {
                    result.append(.init(
                        id: id,
                        name: name,
                        label: name.replacingOccurrences(of: "-", with: " ").capitalized,
                        kind: .option,
                        required: false,
                        repeatable: usage.contains("--\(name)=\(valueName)..."),
                        placeholder: valueName.lowercased().replacingOccurrences(of: "_", with: " ")
                    ))
                } else {
                    result.append(.init(
                        id: id,
                        name: name,
                        label: name.replacingOccurrences(of: "-", with: " ").capitalized,
                        kind: .flag,
                        required: false,
                        repeatable: false,
                        placeholder: ""
                    ))
                }
            }
        }
        return result
    }
}

private struct ArtisanParameterForm: View {
    let parameters: [ArtisanUIParameter]
    @Binding var values: [String: String]
    @Binding var enabledFlags: Set<String>

    private let columns = [GridItem(.adaptive(minimum: 250), spacing: 14, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Command Inputs").font(.headline)
                Spacer()
                Text("Generated from the installed command definition")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(parameters) { parameter in
                    switch parameter.kind {
                    case .flag:
                        Toggle(isOn: Binding(
                            get: { enabledFlags.contains(parameter.id) },
                            set: { enabled in
                                if enabled { enabledFlags.insert(parameter.id) }
                                else { enabledFlags.remove(parameter.id) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(parameter.label)
                                Text("--\(parameter.name)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        .padding(10)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 9))
                    case .argument, .option:
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 5) {
                                Text(parameter.label).font(.caption.weight(.semibold))
                                if parameter.required { Text("Required").font(.caption2).foregroundStyle(.red) }
                                if parameter.repeatable { Text("Repeatable").font(.caption2).foregroundStyle(.secondary) }
                            }
                            TextField(parameter.placeholder, text: Binding(
                                get: { values[parameter.id, default: ""] },
                                set: { values[parameter.id] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                            Text(parameter.kind == .option ? "--\(parameter.name)" : "<\(parameter.name)>")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            Text("Required fields may be left blank when the installed command provides an interactive Laravel prompt; ABSDEV Studio will open the embedded terminal in that case.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private func artisanShellQuote(_ value: String) -> String {
    if value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
       !value.contains("'") && !value.contains("\"") {
        return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private struct ArtisanCommandRow: View {
    let item: ArtisanCommand

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.callout.monospaced().weight(.medium))
                if !item.description.isEmpty {
                    Text(item.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }
}


struct TinkerView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                PageHeader(
                    title: "Laravel Tinker",
                    subtitle: "A dedicated full-size interactive PsySH console for the selected project."
                )
                Spacer(minLength: 24)

                if store.isInteractiveArtisanTerminalVisible {
                    Button(
                        store.isInteractiveArtisanSession ? "Stop" : "Close",
                        systemImage: store.isInteractiveArtisanSession ? "stop.fill" : "xmark"
                    ) {
                        store.stopInteractiveArtisanSession()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }

            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Interactive Console", systemImage: "terminal.fill")
                        .font(.headline)
                    Spacer()
                    Text(store.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if store.isInteractiveArtisanTerminalVisible {
                    InteractiveTerminalView(
                        sessionID: store.interactiveArtisanSessionID,
                        executable: store.interactiveArtisanExecutable,
                        arguments: store.interactiveArtisanArguments,
                        environment: store.interactiveArtisanEnvironment,
                        currentDirectory: store.interactiveArtisanDirectory,
                        onTermination: { store.interactiveArtisanDidTerminate(exitCode: $0) }
                    )
                    .id(store.interactiveArtisanSessionID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
                } else {
                    VStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.large)
                        Text(store.selectedProject == nil ? "Select a project to use Tinker" : "Starting Tinker…")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 700, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            guard store.selectedProject != nil,
                  !store.isInteractiveArtisanTerminalVisible,
                  !store.isInteractiveArtisanSession else { return }

            // Start PsySH as soon as the dedicated Tinker workspace is opened.
            // Dispatching to the next run-loop turn allows SwiftUI to finish
            // mounting the terminal container before the PTY session begins.
            DispatchQueue.main.async {
                guard store.selectedSection == .tinker,
                      !store.isInteractiveArtisanTerminalVisible,
                      !store.isInteractiveArtisanSession else { return }
                store.runTinker()
            }
        }
        .onDisappear {
            if store.isInteractiveArtisanSession {
                store.stopInteractiveArtisanSession()
            }
        }
    }
}


struct SailView: View {
    @Environment(AppStore.self) private var store
    @State private var search = ""
    @State private var command = "up -d"
    @State private var selectedName: String?

    private var filtered: [SailCommand] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.sailCommands }
        return store.sailCommands.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.description.localizedCaseInsensitiveContains(query) ||
            $0.category.localizedCaseInsensitiveContains(query)
        }
    }

    private var groups: [(String, [SailCommand])] {
        Dictionary(grouping: filtered, by: \.category)
            .map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.0 < $1.0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                PageHeader(title: "Laravel Sail", subtitle: "Project-aware Docker commands from the installed Sail version.")
                Spacer()
                Text(store.sailVersion).font(.caption.monospaced()).foregroundStyle(.secondary)
                Button("Rescan", systemImage: "arrow.clockwise") { Task { await store.refreshSailCommands() } }
            }
            .padding(28)

            HStack(spacing: 10) {
                TextField("Sail command and options", text: $command)
                    .font(.body.monospaced())
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { store.runSail(command) }
                Button("Run", systemImage: "play.fill") { store.runSail(command) }
                    .buttonStyle(.borderedProminent)
                    .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isBusy)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 16)

            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Filter Sail commands", text: $search).textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 12).frame(height: 40)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 9))
                    .padding(14)

                    if store.sailCommands.isEmpty {
                        ContentUnavailableView("No Sail Commands", systemImage: "sailboat", description: Text(store.sailDiscoveryMessage))
                    } else {
                        List(selection: $selectedName) {
                            ForEach(groups, id: \.0) { group in
                                Section(group.0) {
                                    ForEach(group.1) { item in
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack {
                                                Text(item.name).font(.callout.monospaced().weight(.semibold))
                                                if item.interactive { Image(systemName: "rectangle.and.pencil.and.ellipsis").font(.caption).foregroundStyle(.blue) }
                                                Spacer()
                                            }
                                            Text(item.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                        .padding(.vertical, 4)
                                        .tag(item.name)
                                        .contentShape(Rectangle())
                                        .onTapGesture { selectedName = item.name; command = item.example }
                                    }
                                }
                            }
                        }
                        .listStyle(.sidebar)
                    }
                }
                .frame(minWidth: 340, idealWidth: 410, maxWidth: 480)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Sail Output").font(.headline)
                        Spacer()
                        Text(store.sailDiscoveryMessage).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    ConsoleView(lines: store.commandOutput)
                }
                .padding(20)
                .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: store.selectedProjectID) { await store.refreshSailCommands() }
    }
}

struct LogsView: View {
    @Environment(AppStore.self) private var store
    @State private var search = ""

    var filtered: [String] {
        search.isEmpty ? store.logLines : store.logLines.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                PageHeader(title: "Logs", subtitle: "Read or follow the current Laravel log file.")
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(store.currentLogFileName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if store.isTailingLogs {
                        Label("Following live", systemImage: "dot.radiowaves.left.and.right")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                TextField("Search logs", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                if store.isTailingLogs {
                    Button("Pause", systemImage: "pause.fill") {
                        store.toggleLogTail()
                    }
                    .buttonStyle(BorderedProminentButtonStyle())
                } else {
                    Button("Tail", systemImage: "waveform.path.ecg") {
                        store.toggleLogTail()
                    }
                    .buttonStyle(BorderedButtonStyle())
                }
                Button("Refresh", systemImage: "arrow.clockwise") { store.loadLogs() }
                Button("Clear", systemImage: "trash", role: .destructive) { store.clearLogs() }
            }
            .padding(28)

            Divider()

            ConsoleView(lines: filtered)
                .padding(28)
        }
        .task(id: store.selectedProjectID) {
            store.loadLogs()
        }
        .onDisappear {
            store.stopLogTail()
        }
    }
}

struct DoctorView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                PageHeader(title: "Project Doctor", subtitle: "Detect configuration and runtime problems.")
                Spacer()
                if let lastRun = store.diagnosticsLastRun {
                    Text("Checked \(lastRun.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await store.runDiagnostics() }
                } label: {
                    if store.isRunningDiagnostics {
                        ProgressView().controlSize(.small)
                        Text("Checking…")
                    } else {
                        Label("Run Checks", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isRunningDiagnostics)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 18)

            Divider()

            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: 320, maximum: 520),
                            spacing: 20,
                            alignment: .top
                        )
                    ],
                    alignment: .leading,
                    spacing: 20
                ) {
                    ForEach(store.diagnostics) { item in
                        diagnosticCard(item)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            if store.diagnostics.isEmpty {
                await store.runDiagnostics()
            }
        }
    }

    private func diagnosticCard(_ item: DiagnosticItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(color(item.status).opacity(0.13))
                    Image(systemName: icon(item.status))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(color(item.status))
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(statusTitle(item.status))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color(item.status))
                }

                Spacer(minLength: 8)
            }

            Text(item.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3, reservesSpace: true)

            HStack {
                Spacer()
                if let action = item.action {
                    Button(action) { store.executeDiagnostic(item) }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.separator.opacity(0.7))
        }
    }

    private func statusTitle(_ status: DiagnosticItem.Status) -> String {
        switch status {
        case .healthy: "Healthy"
        case .warning: "Warning"
        case .error: "Problem"
        }
    }

    private func icon(_ status: DiagnosticItem.Status) -> String {
        switch status { case .healthy: "checkmark.circle.fill"; case .warning: "exclamationmark.triangle.fill"; case .error: "xmark.octagon.fill" }
    }

    private func color(_ status: DiagnosticItem.Status) -> Color {
        switch status { case .healthy: .green; case .warning: .orange; case .error: .red }
    }
}
