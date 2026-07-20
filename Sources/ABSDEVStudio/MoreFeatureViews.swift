import SwiftUI

struct DatabaseView: View {
    @Environment(AppStore.self) private var store
    @State private var confirmFresh = false
    @State private var schemaSearch = ""
    @State private var selectedDetail = "Columns"

    private var filteredTables: [DatabaseTableInfo] {
        let term = schemaSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return store.databaseTables }
        return store.databaseTables.filter { $0.name.localizedCaseInsensitiveContains(term) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                PageHeader(title: "Database", subtitle: "Browse the connected schema and run migration commands.")
                Spacer()
                if store.isLoadingDatabaseSchema { ProgressView().controlSize(.small) }
                Button("Refresh Schema", systemImage: "arrow.clockwise") {
                    Task { await store.refreshDatabaseSchema() }
                }
                Button("Database Console", systemImage: "terminal.fill") {
                    store.selectedSection = .databaseConsole
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 18)

            HStack(spacing: 14) {
                MetricCard(title: "Connection", value: environmentValue("DB_CONNECTION", fallback: "Unknown"), detail: "Selected project .env", symbol: "cylinder")
                MetricCard(title: "Database", value: databaseDisplayName, detail: databaseLocationDetail, symbol: "externaldrive")
                MetricCard(title: "Tables", value: "\(store.databaseTables.count)", detail: store.databaseSchemaMessage, symbol: "tablecells")
                MetricCard(title: "Safety", value: "Confirmed", detail: "Fresh requires confirmation", symbol: "lock.shield")
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 18)

            GroupBox("Actions") {
                HStack(spacing: 10) {
                    Button("Migration Status") { run("migrate:status") }
                    Button("Migrate") { run("migrate") }.buttonStyle(.borderedProminent)
                    Button("Run Seeder") { run("db:seed") }
                    Button("Rollback") { run("migrate:rollback") }
                    Spacer()
                    Button("Fresh Database", role: .destructive) { confirmFresh = true }
                }
                .padding(.vertical, 8)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 18)

            Divider()

            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        TextField("Filter tables", text: $schemaSearch)
                            .textFieldStyle(.roundedBorder)
                        Text("\(filteredTables.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    Divider()

                    if filteredTables.isEmpty {
                        ContentUnavailableView("No schema loaded", systemImage: "tablecells", description: Text(store.databaseSchemaMessage))
                    } else {
                        List(filteredTables, selection: Binding(
                            get: { store.selectedDatabaseTableName },
                            set: { if let value = $0 { store.selectDatabaseTable(value) } }
                        )) { table in
                            HStack {
                                Image(systemName: "tablecells")
                                    .foregroundStyle(.red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(table.name).font(.callout.monospaced().weight(.semibold))
                                    HStack(spacing: 8) {
                                        if !table.rows.isEmpty { Text("\(table.rows) rows") }
                                        if !table.size.isEmpty { Text(table.size) }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .tag(table.name)
                        }
                        .listStyle(.sidebar)
                    }
                }
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)

                VStack(spacing: 0) {
                    if let table = store.selectedDatabaseTableName {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(table).font(.title2.bold().monospaced())
                                Text("Columns, indexes, and foreign-key relationships")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker("Detail", selection: $selectedDetail) {
                                Text("Columns").tag("Columns")
                                Text("Indexes").tag("Indexes")
                                Text("Foreign Keys").tag("Foreign Keys")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 360)
                        }
                        .padding(18)
                        Divider()

                        Group {
                            switch selectedDetail {
                            case "Indexes": indexesView
                            case "Foreign Keys": foreignKeysView
                            default: columnsView
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        ContentUnavailableView("Select a table", systemImage: "tablecells", description: Text("Choose a table from the schema list to inspect its structure."))
                    }
                }
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .confirmationDialog("Rebuild the database?", isPresented: $confirmFresh) {
            Button("Run migrate:fresh --seed", role: .destructive) { run("migrate:fresh --seed") }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This deletes all data in the selected project's configured database.") }
        .task(id: store.selectedProjectID) {
            await store.refreshDatabaseSchema()
        }
    }


    private func environmentValue(_ key: String, fallback: String = "") -> String {
        guard let raw = store.environmentEntries.first(where: { $0.key == key })?.value else { return fallback }
        let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        return value.isEmpty ? fallback : value
    }

    private var databaseDisplayName: String {
        let connection = environmentValue("DB_CONNECTION", fallback: "")
        let database = environmentValue("DB_DATABASE", fallback: "Not configured")
        guard connection == "sqlite", database != "Not configured" else { return database }
        if database == ":memory:" { return database }
        return URL(fileURLWithPath: database).lastPathComponent
    }

    private var databaseLocationDetail: String {
        let connection = environmentValue("DB_CONNECTION", fallback: "")
        let database = environmentValue("DB_DATABASE", fallback: "")
        if connection == "sqlite", !database.isEmpty {
            return database.hasPrefix("/") ? database : "Relative to project root"
        }
        let host = environmentValue("DB_HOST", fallback: "localhost")
        let port = environmentValue("DB_PORT", fallback: "")
        return port.isEmpty ? host : "\(host):\(port)"
    }

    private var columnsView: some View {
        Table(store.databaseColumns) {
            TableColumn("Column", value: \.name).width(min: 160, ideal: 220)
            TableColumn("Type", value: \.type).width(min: 130, ideal: 180)
            TableColumn("Nullable") { item in Text(item.nullable ? "Yes" : "No") }.width(80)
            TableColumn("Default", value: \.defaultValue).width(min: 120, ideal: 180)
            TableColumn("Extra", value: \.extra).width(min: 150, ideal: 240)
        }
        .padding(18)
    }

    private var indexesView: some View {
        Table(store.databaseIndexes) {
            TableColumn("Index", value: \.name).width(min: 160, ideal: 220)
            TableColumn("Columns", value: \.columns).width(min: 200, ideal: 300)
            TableColumn("Unique") { item in Text(item.unique ? "Yes" : "No") }.width(80)
            TableColumn("Primary") { item in Text(item.primary ? "Yes" : "No") }.width(80)
        }
        .padding(18)
    }

    private var foreignKeysView: some View {
        Table(store.databaseForeignKeys) {
            TableColumn("Constraint", value: \.name).width(min: 150, ideal: 220)
            TableColumn("Columns", value: \.columns).width(min: 160, ideal: 220)
            TableColumn("References Table", value: \.referencedTable).width(min: 170, ideal: 230)
            TableColumn("References Columns", value: \.referencedColumns).width(min: 170, ideal: 230)
        }
        .padding(18)
    }

    private func run(_ command: String) {
        store.runArtisan(command)
        store.selectedSection = .artisan
    }
}

struct QueueView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Queue", subtitle: "Control queue workers and failed jobs.")
            HStack(spacing: 14) {
                MetricCard(title: "Worker", value: store.processes.first(where: { $0.name == "Queue Worker" })?.isRunning == true ? "Running" : "Stopped", detail: "Default queue", symbol: "gearshape.2.fill")
                MetricCard(title: "Failed jobs", value: "Inspect", detail: "Use queue:failed", symbol: "exclamationmark.triangle")
            }
            GroupBox("Queue actions") { HStack { Button("List Failed Jobs") { run("queue:failed") }; Button("Retry All") { run("queue:retry all") }; Button("Forget All", role: .destructive) { run("queue:flush") }; Spacer(); Button("Restart Workers") { run("queue:restart") }.buttonStyle(.borderedProminent) }.padding(.vertical, 8) }
        }.padding(28) }
    }
    private func run(_ command: String) { store.runArtisan(command); store.selectedSection = .artisan }
}

struct RoutesView: View {
    @Environment(AppStore.self) private var store
    @State private var search = ""
    var filtered: [RouteItem] { search.isEmpty ? store.routes : store.routes.filter { $0.uri.localizedCaseInsensitiveContains(search) || $0.name.localizedCaseInsensitiveContains(search) || $0.action.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack { PageHeader(title: "Routes", subtitle: "Search the application's HTTP endpoints."); TextField("Search routes", text: $search).textFieldStyle(.roundedBorder).frame(width: 260); Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refreshRoutes() } } }.padding(28)
            if filtered.isEmpty { ContentUnavailableView("No routes loaded", systemImage: "arrow.triangle.branch", description: Text("Choose a valid Laravel project and press Refresh.")) }
            else { Table(filtered) { TableColumn("Method") { route in Text(route.method).font(.caption.bold()).padding(4).background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 5)) }.width(85); TableColumn("URI", value: \.uri).width(min: 180, ideal: 240); TableColumn("Name", value: \.name).width(min: 150, ideal: 210); TableColumn("Action", value: \.action).width(min: 220, ideal: 300); TableColumn("Middleware", value: \.middleware).width(min: 160, ideal: 220) }.padding(.horizontal, 28).padding(.bottom, 28) }
        }
    }
}

struct ComposerView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                PageHeader(title: "Composer", subtitle: "Inspect packages and manage project dependencies.")
                Spacer()
                Button("Show Packages", systemImage: "list.bullet") { run("composer show --direct") }
                Button("Audit", systemImage: "checkmark.shield") { run("composer audit") }
                Button("Install", systemImage: "square.and.arrow.down") { run("composer install") }
                Button("Update", systemImage: "arrow.down.circle") { run("composer update") }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 18)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Command Output").font(.headline)
                    Spacer()
                    if store.isBusy {
                        ProgressView().controlSize(.small)
                        Text(store.statusMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Clear Output") { store.clearConsole() }
                }

                ConsoleView(lines: store.commandOutput)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func run(_ command: String) {
        store.clearConsole()
        store.runCommand(command)
    }
}

struct SchedulerView: View {
    @Environment(AppStore.self) private var store

    private let tasks = [
        ScheduleTask(
            command: "schedule:list",
            summary: "Read current schedule",
            status: "Now",
            purpose: "Show all scheduled tasks"
        ),
        ScheduleTask(
            command: "schedule:run",
            summary: "Run tasks that are due",
            status: "On demand",
            purpose: "Run due scheduled tasks"
        ),
        ScheduleTask(
            command: "schedule:test",
            summary: "Interactively test a task",
            status: "On demand",
            purpose: "Test a scheduled task interactively"
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                PageHeader(title: "Scheduler", subtitle: "Inspect and run Laravel scheduled tasks.")
                Spacer()
                Button("Refresh Schedule", systemImage: "arrow.clockwise") {
                    run("schedule:list")
                }
                .buttonStyle(.borderedProminent)
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
                    ForEach(tasks) { task in
                        ScheduleCard(task: task) {
                            run(task.command)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func run(_ command: String) {
        store.runArtisan(command)
        store.selectedSection = .artisan
    }
}

private struct ScheduleTask: Identifiable {
    let command: String
    let summary: String
    let status: String
    let purpose: String

    var id: String { command }
}

private struct ScheduleCard: View {
    let task: ScheduleTask
    let action: () -> Void

    private var isImmediate: Bool { task.status == "Now" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(.blue.opacity(0.13))
                        Image(systemName: "clock.badge.checkmark")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.blue)
                    }
                    .frame(width: 48, height: 48)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.command)
                            .font(.headline.monospaced())
                            .lineLimit(1)
                        Text(task.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2, reservesSpace: true)
                    }

                    Spacer(minLength: 8)

                    Text(task.status)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isImmediate ? .green : .orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            (isImmediate ? Color.green : Color.orange).opacity(0.10),
                            in: Capsule()
                        )
                        .overlay {
                            Capsule()
                                .stroke(
                                    (isImmediate ? Color.green : Color.orange).opacity(0.35),
                                    lineWidth: 1
                                )
                        }
                }

                Divider()

                ScheduleDetailRow(
                    icon: "calendar",
                    title: "Status",
                    value: task.status
                )

                Divider()

                ScheduleDetailRow(
                    icon: "list.bullet.rectangle",
                    title: "Purpose",
                    value: task.purpose
                )
            }
            .padding(18)

            Spacer(minLength: 0)

            Divider()

            HStack {
                Spacer()
                Button("Run Now", systemImage: "play.fill", action: action)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, minHeight: 330, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.separator, lineWidth: 1)
        }
    }
}

private struct ScheduleDetailRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.indigo)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout)
                    .lineLimit(2, reservesSpace: true)
            }

            Spacer(minLength: 0)
        }
    }
}
import SwiftUI

private struct FullTerminalWorkspace: View {
    @Environment(AppStore.self) private var store
    let section: AppSection
    let title: String
    let subtitle: String
    let startingTitle: String
    let startSymbol: String
    let start: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                PageHeader(title: title, subtitle: subtitle)
                Spacer()
                if store.isInteractiveArtisanTerminalVisible {
                    Button("Stop", systemImage: "stop.fill") {
                        store.stopInteractiveArtisanSession()
                        store.selectedSection = .overview
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            Divider()

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
                .padding(18)
            } else {
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                    Label(
                        store.selectedProject == nil ? "Select a project to continue" : startingTitle,
                        systemImage: startSymbol
                    )
                    .font(.headline)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 700, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            guard store.selectedProject != nil,
                  !store.isInteractiveArtisanTerminalVisible,
                  !store.isInteractiveArtisanSession else { return }

            // Allow SwiftUI to mount the terminal host before launching the PTY.
            DispatchQueue.main.async {
                guard store.selectedSection == section,
                      !store.isInteractiveArtisanTerminalVisible,
                      !store.isInteractiveArtisanSession else { return }
                start()
            }
        }
        .onDisappear {
            if store.isInteractiveArtisanSession {
                store.stopInteractiveArtisanSession()
            }
        }
    }
}

struct DatabaseConsoleView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        FullTerminalWorkspace(
            section: .databaseConsole,
            title: "Database Console",
            subtitle: "A dedicated interactive Laravel database CLI for the selected project.",
            startingTitle: "Starting Database Console…",
            startSymbol: "cylinder.split.1x2.fill",
            start: { store.runDatabaseConsole() }
        )
    }
}

struct TerminalWorkspaceView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        FullTerminalWorkspace(
            section: .terminal,
            title: "Terminal",
            subtitle: "A full interactive shell rooted at the selected Laravel project.",
            startingTitle: "Starting Terminal…",
            startSymbol: "terminal.fill",
            start: { store.runTerminalWorkspace() }
        )
    }
}

struct LegacyProjectCapabilitiesView: View {
    @Environment(AppStore.self) private var store
    @State private var installedOnly = true
    @State private var search = ""

    private var filtered: [ProjectCapability] {
        store.projectCapabilities.filter { item in
            (!installedOnly || item.installed) &&
            (search.isEmpty ||
             item.name.localizedCaseInsensitiveContains(search) ||
             item.package.localizedCaseInsensitiveContains(search) ||
             item.category.localizedCaseInsensitiveContains(search))
        }
    }

    private var grouped: [(String, [ProjectCapability])] {
        Dictionary(grouping: filtered, by: \.category)
            .map { category, capabilities in
                (category, capabilities.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
            }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if filtered.isEmpty {
                ContentUnavailableView(
                    "No matching capabilities",
                    systemImage: "sparkles.rectangle.stack",
                    description: Text("Install a supported package or show unavailable integrations.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(
                                .adaptive(minimum: 340, maximum: 520),
                                spacing: 20,
                                alignment: .top
                            )
                        ],
                        alignment: .leading,
                        spacing: 20
                    ) {
                        ForEach(grouped, id: \.0) { category, capabilities in
                            capabilitySection(category: category, capabilities: capabilities)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: store.selectedProjectID) { store.refreshProjectCapabilities() }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 18) {
                PageHeader(
                    title: "Project Intelligence",
                    subtitle: "Features and frameworks detected from the selected project's installed Composer packages."
                )
                Spacer(minLength: 24)
                controls
            }

            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    title: "Project Intelligence",
                    subtitle: "Features and frameworks detected from the selected project's installed Composer packages."
                )
                controls
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Toggle("Installed only", isOn: $installedOnly)
                .toggleStyle(.switch)
                .fixedSize()

            TextField("Search packages", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)

            Button("Rescan", systemImage: "arrow.clockwise") {
                store.refreshProjectCapabilities()
            }
        }
    }

    @ViewBuilder
    private func capabilitySection(category: String, capabilities: [ProjectCapability]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text(category)
                    .font(.title3.weight(.semibold))
                Text("\(capabilities.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                Spacer()
            }

            VStack(spacing: 12) {
                ForEach(capabilities) { item in
                    capabilityCard(item)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.separator.opacity(0.65))
        }
    }

    private func capabilityCard(_ item: ProjectCapability) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill((item.installed ? Color.green : Color.secondary).opacity(0.12))
                    Image(systemName: item.symbol)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(item.installed ? Color.green : Color.secondary)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(item.package)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Text(item.installed ? (item.directDependency ? "Installed" : "Dependency") : "Unavailable")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(item.installed ? Color.green : Color.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background((item.installed ? Color.green : Color.secondary).opacity(0.14), in: Capsule())
            }

            Text(item.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)

            HStack {
                Spacer()
                if item.installed && item.directDependency {
                    Button("Remove", systemImage: "trash") {
                        store.removeProjectCapability(item)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(store.isBusy)
                } else if item.installed {
                    Text("Required by another package")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Install", systemImage: "arrow.down.circle") {
                        store.installProjectCapability(item)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isBusy)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.separator.opacity(0.8))
        }
    }
}



struct PackageOperationProgressDialog: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(statusColor.opacity(0.14))
                    if store.packageOperationIsRunning {
                        ProgressView()
                            .controlSize(.regular)
                    } else {
                        Image(systemName: store.packageOperationSucceeded == true ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundStyle(statusColor)
                    }
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 5) {
                    Text(store.packageOperationTitle)
                        .font(.title2.weight(.semibold))
                    Text(store.packageOperationDetail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            if store.packageOperationIsRunning {
                ProgressView()
                    .progressViewStyle(.linear)
                Text("Do not close ABSDEV Studio while Composer is updating the project.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GroupBox("Composer Output") {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(store.packageOperationOutput.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                        .padding(12)
                    }
                    .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                    .onChange(of: store.packageOperationOutput.count) { _, count in
                        guard count > 0 else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(count - 1, anchor: .bottom)
                        }
                    }
                }
            }
            .frame(minHeight: 230, maxHeight: 330)

            HStack {
                if !store.packageOperationIsRunning {
                    Text(store.packageOperationSucceeded == true ? "Operation completed" : "Operation failed")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(statusColor)
                }
                Spacer()
                Button("Close") {
                    store.isPackageOperationPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.packageOperationIsRunning)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 620, idealWidth: 700, minHeight: 430)
    }

    private var statusColor: Color {
        if store.packageOperationIsRunning { return .accentColor }
        return store.packageOperationSucceeded == true ? .green : .red
    }
}


struct ServBayView: View {
    @Environment(AppStore.self) private var store

    private var runningCount: Int { store.servBayServices.filter { $0.state.isRunning }.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                PageHeader(title: "ServBay", subtitle: "Manage ServBay services, runtimes, websites, certificates, and logs.")
                Spacer()
                if store.isServBayBusy { ProgressView().controlSize(.small) }
                Button("Open ServBay", systemImage: "macwindow") { store.openServBay() }
                Button("Logs", systemImage: "doc.text.magnifyingglass") { store.revealServBayLogs() }
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await store.refreshServBay() }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(28)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 14) {
                        MetricCard(title: "Installation", value: "Detected", detail: "/Applications/ServBay", symbol: "checkmark.seal.fill")
                        MetricCard(title: "Services", value: "\(store.servBayServices.count)", detail: "Installed packages detected", symbol: "server.rack")
                        MetricCard(title: "Running", value: "\(runningCount)", detail: "Reported by servbayctl", symbol: "play.circle.fill")
                    }


                    GroupBox("Services") {
                        VStack(spacing: 0) {
                            ForEach(store.servBayServices) { service in
                                ServBayServiceRow(service: service)
                                if service.id != store.servBayServices.last?.id { Divider() }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Command Output").font(.headline)
                            Spacer()
                            Button("Clear") { store.servBayOutput = [] }
                        }
                        ConsoleView(lines: store.servBayOutput.isEmpty ? ["ServBay integration ready."] : store.servBayOutput)
                            .frame(minHeight: 150, maxHeight: 230)
                    }
                }
                .padding(28)
            }
        }
        .task { await store.refreshServBay() }
    }
}

private struct ServBaySystemMonitor: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("System Load").font(.headline)
                        Text("Live CPU and memory usage sampled every two seconds")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label("Live", systemImage: "waveform.path.ecg")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }

                HStack(alignment: .top, spacing: 20) {
                    SystemGauge(title: "CPU", value: store.systemCPUPercent, symbol: "cpu")
                    SystemLoadChart(samples: store.systemLoadHistory)
                        .frame(minWidth: 360, maxWidth: .infinity, minHeight: 180)
                    VStack(spacing: 12) {
                        SystemUsageBar(title: "Memory", value: store.systemMemoryPercent, detail: store.systemMemoryDetail, symbol: "memorychip")
                        SystemUsageBar(title: "Storage", value: store.systemStoragePercent, detail: store.systemStorageDetail, symbol: "internaldrive")
                    }
                    .frame(width: 245)
                }
            }
            .padding(8)
        }
    }
}

private struct SystemGauge: View {
    let title: String
    let value: Double
    let symbol: String

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label(title, systemImage: symbol).font(.headline)
                Spacer()
            }
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 13)
                Circle()
                    .trim(from: 0, to: max(0.002, min(1, value / 100)))
                    .stroke(AngularGradient(colors: [.green, .yellow, .orange, .red], center: .center), style: StrokeStyle(lineWidth: 13, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text(value, format: .number.precision(.fractionLength(1)))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("percent").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 135, height: 135)
        }
        .frame(width: 165)
    }
}

private struct SystemLoadChart: View {
    let samples: [SystemLoadSample]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Usage History").font(.headline)
                Spacer()
                Label("CPU", systemImage: "circle.fill").foregroundStyle(.orange)
                Label("Memory", systemImage: "circle.fill").foregroundStyle(.blue)
            }
            .font(.caption)

            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.35))
                    VStack {
                        Divider(); Spacer(); Divider(); Spacer(); Divider()
                    }
                    .opacity(0.35)
                    if samples.count > 1 {
                        chartPath(values: samples.map(\.cpuPercent), size: geometry.size)
                            .stroke(.orange, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        chartPath(values: samples.map(\.memoryPercent), size: geometry.size)
                            .stroke(.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    } else {
                        Text("Collecting system samples…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func chartPath(values: [Double], size: CGSize) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let step = size.width / CGFloat(values.count - 1)
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: CGFloat(index) * step, y: size.height * (1 - CGFloat(max(0, min(100, value))) / 100))
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }
}

private struct SystemUsageBar: View {
    let title: String
    let value: Double
    let detail: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: symbol).fontWeight(.semibold)
                Spacer()
                Text(value / 100, format: .percent.precision(.fractionLength(1)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: value, total: 100).tint(value > 85 ? .red : value > 65 ? .orange : .green)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ServBayServiceRow: View {
    @Environment(AppStore.self) private var store
    let service: ServBayService

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: service.symbol)
                .font(.title3)
                .foregroundStyle(service.state.isRunning ? Color.green : Color.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(service.name).fontWeight(.semibold)
                Text(service.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }

            Spacer()
            StatusPill(text: service.state.rawValue, active: service.state.isRunning)

            if service.state.isRunning {
                Button("Reload") { store.performServBayAction("reload", service: service) }
                Button("Restart") { store.performServBayAction("restart", service: service) }
                Button("Stop", role: .destructive) { store.performServBayAction("stop", service: service) }
            } else {
                Button("Start") { store.performServBayAction("start", service: service) }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
            }
        }
        .padding(.vertical, 12)
        .disabled(store.isServBayBusy)
    }
}
