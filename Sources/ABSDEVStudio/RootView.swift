import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var isLaunching = true

    var body: some View {
        @Bindable var store = store

        ZStack {
            NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 245, max: 290)
        } content: {
            SectionNavigationView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 240)
        } detail: {
            DetailRouter()
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    store.addProject()
                } label: {
                    Label("Add Project", systemImage: "plus.circle.fill")
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    store.toggleDevelopment()
                } label: {
                    Label(
                        store.isDevelopmentRunning ? "Stop Development" : "Start Development",
                        systemImage: store.isDevelopmentRunning ? "stop.fill" : "play.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(store.isDevelopmentRunning ? .red : .green)

                Menu {
                    Button("Open in Browser") { store.openBrowser() }
                    Button("Open in Terminal") { store.openInTerminal() }
                    Button("Open in Editor") { store.openInEditor() }
                    Divider()
                    Button("Reveal in Finder") { store.revealInFinder() }
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.infoBlue)
                }
            }
        }
            .sheet(item: $store.testFailureReport) { report in
                TestFailureDialog(report: report)
            }
            .sheet(isPresented: $store.isPackageOperationPresented) {
                PackageOperationProgressDialog()
                    .interactiveDismissDisabled(store.packageOperationIsRunning)
            }
            .sheet(isPresented: Binding(
                get: { store.isCommandProgressPresented },
                set: { _ in }
            )) {
                CommandProgressDialog(store: store)
                    .interactiveDismissDisabled()
            }
            .sheet(isPresented: $store.isCommandPalettePresented) {
                CommandPaletteView()
                    .environment(store)
            }

            if isLaunching {
                LaunchExperienceView()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .task {
            guard isLaunching else { return }
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(.easeOut(duration: 0.32)) {
                isLaunching = false
            }
        }
    }
}

private struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @State private var projectBeingCustomized: LaravelProject?
    @State private var projectPendingRename: LaravelProject?
    @State private var editedAlias = ""
    @State private var projectPendingDeletion: LaravelProject?
    @State private var moveFolderToTrash = false
    @State private var projectForTags: LaravelProject?
    @State private var tagText = ""
    @State private var searchText = ""

    private var filteredProjects: [LaravelProject] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return store.projects }
        return store.projects.filter { project in
            project.name.localizedCaseInsensitiveContains(searchText)
                || project.path.localizedCaseInsensitiveContains(searchText)
                || project.branch.localizedCaseInsensitiveContains(searchText)
                || project.projectTags.contains(where: { $0.localizedCaseInsensitiveContains(searchText) })
        }
    }

    private var favorites: [LaravelProject] { filteredProjects.filter(\.favorite) }
    private var regular: [LaravelProject] { filteredProjects.filter { !$0.favorite } }
    private var recent: [LaravelProject] {
        Array(regular.filter { $0.lastOpenedAt != nil }
            .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
            .prefix(5))
    }
    private var remainingProjects: [LaravelProject] {
        let recentIDs = Set(recent.map(\.id))
        return regular.filter { !recentIDs.contains($0.id) }
    }

    var body: some View {
        @Bindable var store = store

        List(selection: $store.selectedProjectID) {
            if !favorites.isEmpty {
                Section("Favourites") { projectRows(favorites) }
            }
            if !recent.isEmpty {
                Section("Recent") { projectRows(recent) }
            }
            if !remainingProjects.isEmpty || (favorites.isEmpty && recent.isEmpty) {
                Section("Projects") { projectRows(remainingProjects) }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search projects")
        .onReceive(NotificationCenter.default.publisher(for: .absdevRenameSelectedProject)) { _ in
            if let project = store.selectedProject { beginRename(project) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .absdevDeleteSelectedProject)) { _ in
            if let project = store.selectedProject { moveFolderToTrash = false; projectPendingDeletion = project }
        }
        .dropDestination(for: URL.self) { urls, _ in
            var imported = false
            for url in urls where url.hasDirectoryPath {
                imported = store.addProject(at: url) || imported
            }
            return imported
        }
        .sheet(item: $projectPendingRename) { project in
            ProjectAliasRenameSheet(
                project: project,
                alias: $editedAlias,
                onCancel: { projectPendingRename = nil },
                onSave: {
                    if let error = store.renameProject(project.id, to: editedAlias) {
                        store.showAlert(title: "Could not rename project alias", message: error)
                    } else {
                        projectPendingRename = nil
                    }
                }
            )
        }
        .sheet(item: $projectBeingCustomized) { project in ProjectIconEditor(project: project) }
        .sheet(item: $projectForTags) { project in
            VStack(alignment: .leading, spacing: 16) {
                Text("Project Tags").font(.title2.bold())
                Text("Enter comma-separated tags for \(project.name).")
                    .foregroundStyle(.secondary)
                TextField("Laravel, Client, Production", text: $tagText)
                HStack {
                    Spacer()
                    Button("Cancel") { projectForTags = nil }
                    Button("Save") {
                        store.setProjectTags(project.id, tags: tagText.split(separator: ",").map(String.init))
                        projectForTags = nil
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(width: 430)
        }
        .sheet(item: $projectPendingDeletion) { project in
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Delete Project?").font(.title2.bold())
                        Text(project.name).foregroundStyle(.secondary)
                    }
                }
                Text("This removes the project from ABSDEV Studio, including its settings, MCP registration, cached icon, and knowledge-base data.")
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Also move the source folder to Trash", isOn: $moveFolderToTrash)
                    .toggleStyle(.checkbox)
                Text(moveFolderToTrash ? "The source folder will be moved to the macOS Trash." : "The source files on disk will remain untouched.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") {
                        projectPendingDeletion = nil
                        moveFolderToTrash = false
                    }
                    Button("Delete", role: .destructive) {
                        if let error = store.removeProject(project.id, moveFolderToTrash: moveFolderToTrash) {
                            store.showAlert(title: "Could not delete project", message: error)
                        }
                        projectPendingDeletion = nil
                        moveFolderToTrash = false
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
            .padding(24)
            .frame(width: 480)
            .interactiveDismissDisabled()
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                HStack {
                    Button { store.addProject() } label: { Label("Add Project", systemImage: "plus.circle.fill") }
                        .buttonStyle(.plain)
                    Spacer()
                    Button {
                        if let project = store.selectedProject { projectPendingDeletion = project }
                    } label: {
                        Image(systemName: "minus.circle.fill").symbolRenderingMode(.hierarchical).foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.selectedProject == nil)
                }
            }
            .padding(12)
            .background(.bar)
        }
    }

    @ViewBuilder
    private func projectRows(_ projects: [LaravelProject]) -> some View {
        ForEach(projects) { project in
            ProjectRow(project: project, isMCPConfigured: isMCPConfigured(project))
                .onTapGesture(count: 2) { beginRename(project) }
                .tag(project.id)
            .draggable(project.id.uuidString) {
                ProjectRow(project: project, isMCPConfigured: isMCPConfigured(project))
                    .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            .dropDestination(for: String.self) { items, _ in
                guard let rawID = items.first, let draggedID = UUID(uuidString: rawID) else { return false }
                store.moveProject(draggedID, before: project.id); return true
            }
            .contextMenu { projectMenu(project) }
        }
    }

    @ViewBuilder
    private func projectMenu(_ project: LaravelProject) -> some View {
        Button("Open") { store.selectedProjectID = project.id }
        Button("Open in Finder", systemImage: "folder") {
            store.selectedProjectID = project.id; store.revealInFinder()
        }
        Button("Copy Path", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(project.path, forType: .string)
        }
        Divider()
        Button("Rename…", systemImage: "pencil") { beginRename(project) }
        Button(project.favorite ? "Remove from Favourites" : "Add to Favourites", systemImage: project.favorite ? "star.slash" : "star") {
            store.setProjectFavorite(project.id, favorite: !project.favorite)
        }
        Button("Edit Tags…", systemImage: "tag") {
            tagText = project.projectTags.joined(separator: ", "); projectForTags = project
        }
        Button("Duplicate Metadata", systemImage: "plus.square.on.square") { store.duplicateProject(project.id) }
        Button("Export Settings…", systemImage: "square.and.arrow.up") { store.exportProjectMetadata(project.id) }
        Divider()
        Button("Customize Project Icon…", systemImage: "paintpalette.fill") { projectBeingCustomized = project }
        Button("Import SVG or Image…", systemImage: "photo.badge.plus") { store.importProjectIcon(projectID: project.id) }
        Button("Reset Project Icon", systemImage: "arrow.counterclockwise") { store.resetProjectIcon(projectID: project.id) }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) {
            moveFolderToTrash = false; projectPendingDeletion = project
        }
    }

    private func beginRename(_ project: LaravelProject) {
        store.selectedProjectID = project.id
        editedAlias = project.name
        projectPendingRename = project
    }

    private func isMCPConfigured(_ project: LaravelProject) -> Bool {
        store.openWebUI.mcp.embeddedServer.projects.contains { $0.rootPath == project.path && $0.enabled }
    }
}

private struct ProjectAliasRenameSheet: View {
    let project: LaravelProject
    @Binding var alias: String
    let onCancel: () -> Void
    let onSave: () -> Void
    @FocusState private var aliasIsFocused: Bool

    private var folderName: String {
        URL(fileURLWithPath: project.path).lastPathComponent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Rename Project Alias")
                .font(.title2.bold())

            Text("Change the name displayed in ABSDEV Studio. The project folder will not be renamed or moved.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 7) {
                Text("Display alias")
                    .font(.headline)
                TextField("Project alias", text: $alias)
                    .textFieldStyle(.roundedBorder)
                    .focused($aliasIsFocused)
                    .onSubmit(onSave)
            }

            LabeledContent("Folder", value: folderName)
            LabeledContent("Path", value: project.path)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save Alias", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            aliasIsFocused = true
        }
        .interactiveDismissDisabled()
    }
}

private struct ProjectRow: View {
    let project: LaravelProject
    let isMCPConfigured: Bool

    var body: some View {
        HStack(spacing: 10) {
            ProjectIconView(project: project, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(project.name).fontWeight(.semibold).lineLimit(1)
                    if project.favorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                }
                HStack(spacing: 5) {
                    Circle().frame(width: 6, height: 6)
                        .foregroundStyle(project.gitDirty == true ? .orange : .green)
                    Text(project.branch).lineLimit(1)
                    if isMCPConfigured { Image(systemName: "point.3.connected.trianglepath.dotted").help("Available through MCP") }
                }
                .font(.caption).foregroundStyle(.secondary)
                if !project.projectTags.isEmpty {
                    Text(project.projectTags.prefix(3).joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

private struct ProjectIconView: View {
    let project: LaravelProject
    var size: CGFloat

    var body: some View {
        Group {
            if let path = project.customIconPath, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.12)
                    .background(Color.black.opacity(0.88))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .fill(projectIconColor(project.iconColorHex))
                    Image(systemName: project.iconSymbol ?? "terminal.fill")
                        .font(.system(size: size * 0.46, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
    }

    private func projectIconColor(_ hex: String?) -> Color {
        let value = hex ?? "FF6B35"
        let scanner = Scanner(string: value.replacingOccurrences(of: "#", with: ""))
        var rgb: UInt64 = 0
        guard scanner.scanHexInt64(&rgb) else { return .orange }
        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

private struct ProjectIconEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let project: LaravelProject
    @State private var selectedSymbol: String
    @State private var selectedColor: String

    private let symbols = [
        "terminal.fill", "curlybraces.square.fill", "shippingbox.fill",
        "server.rack", "cylinder.fill", "hammer.fill",
        "bolt.fill", "network", "app.fill", "square.stack.3d.up.fill"
    ]
    private let colors = [
        "FF6B35", "FF3B30", "FF2D92", "AF52DE", "5856D6",
        "3478F6", "00A7E1", "00A98F", "34C759", "D19A00",
        "6B7280", "111827"
    ]

    init(project: LaravelProject) {
        self.project = project
        _selectedSymbol = State(initialValue: project.iconSymbol ?? "terminal.fill")
        _selectedColor = State(initialValue: project.iconColorHex ?? "FF6B35")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                ProjectIconView(
                    project: LaravelProject(
                        id: project.id, name: project.name, path: project.path,
                        laravelVersion: project.laravelVersion, phpVersion: project.phpVersion,
                        branch: project.branch, appURL: project.appURL, environment: project.environment,
                        iconSymbol: selectedSymbol, iconColorHex: selectedColor, customIconPath: nil
                    ),
                    size: 64
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text("Project Icon").font(.title2.bold())
                    Text(project.name).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text("Symbol").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(46)), count: 5), spacing: 10) {
                ForEach(symbols, id: \.self) { symbol in
                    Button { selectedSymbol = symbol } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 19, weight: .semibold))
                            .frame(width: 42, height: 38)
                            .background(selectedSymbol == symbol ? Color.accentColor.opacity(0.24) : Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Colour").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(38)), count: 6), spacing: 12) {
                ForEach(colors, id: \.self) { color in
                    Button { selectedColor = color } label: {
                        Circle()
                            .fill(colorFromHex(color))
                            .frame(width: 30, height: 30)
                            .overlay {
                                Circle().stroke(.white, lineWidth: selectedColor == color ? 3 : 0)
                            }
                            .overlay { Circle().stroke(.primary.opacity(0.22), lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Button("Import SVG or Image…", systemImage: "photo.badge.plus") {
                    store.importProjectIcon(projectID: project.id)
                    dismiss()
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    store.setProjectIcon(projectID: project.id, symbol: selectedSymbol, colorHex: selectedColor)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 410)
    }

    private func colorFromHex(_ value: String) -> Color {
        var rgb: UInt64 = 0
        Scanner(string: value).scanHexInt64(&rgb)
        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

private struct SectionNavigationView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store

        let filteredSections = store.sectionSearchQuery.isEmpty
            ? store.availableSections
            : store.availableSections.filter { $0.rawValue.localizedCaseInsensitiveContains(store.sectionSearchQuery) }

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search tools", text: $store.sectionSearchQuery)
                    .textFieldStyle(.plain)
                if !store.sectionSearchQuery.isEmpty {
                    Button { store.sectionSearchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(9)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 9))
            .padding(10)

            if filteredSections.isEmpty {
                ContentUnavailableView.search(text: store.sectionSearchQuery)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredSections, selection: $store.selectedSection) { section in
                    Label {
                        Text(section.rawValue)
                    } icon: {
                        Image(systemName: section.symbol)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(section.tint)
                            .frame(width: 20)
                    }
                    .tag(section)
                    .draggable(section.id) {
                        Label(section.rawValue, systemImage: section.symbol)
                            .padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .dropDestination(for: String.self) { items, _ in
                        guard let rawID = items.first,
                              let dragged = AppSection.allCases.first(where: { $0.id == rawID }) else { return false }
                        store.moveSection(dragged, before: section)
                        return true
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .navigationTitle(store.selectedProject?.name ?? "Laravel")
    }
}

private struct DetailRouter: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            switch store.selectedSection {
        case .overview: OverviewView()
        case .development: DevelopmentView()
        case .environment: EnvironmentView()
        case .artisan: ArtisanView()
        case .tinker: TinkerView()
        case .databaseConsole: DatabaseConsoleView()
        case .terminal: TerminalWorkspaceView()
        case .intelligence: ProjectIntelligenceView()
        case .knowledgeBase: KnowledgeBaseView()
        case .sail: SailView()
        case .logs: LogsView()
        case .doctor: DoctorView()
        case .database: DatabaseView()
        case .queue: QueueView()
        case .routes: RoutesView()
        case .composer: ComposerView()
        case .scheduler: SchedulerView()
        case .containers: ContainersView()
        case .servBay: ServBayView()
        case .applicationStatus: LaravelControlCentreView(kind: .applicationStatus)
        case .cacheControl: LaravelControlCentreView(kind: .cacheControl)
        case .migrations: LaravelControlCentreView(kind: .migrations)
        case .events: LaravelControlCentreView(kind: .events)
        case .models: LaravelControlCentreView(kind: .models)
        case .services: LaravelControlCentreView(kind: .services)
        case .testing: LaravelControlCentreView(kind: .testing)
        case .frontend: LaravelControlCentreView(kind: .frontend)
        case .realtime: LaravelControlCentreView(kind: .realtime)
        case .observability: LaravelControlCentreView(kind: .observability)
        case .featureFlags: LaravelControlCentreView(kind: .featureFlags)
        case .deployment: LaravelControlCentreView(kind: .deployment)
        case .maintenance: LaravelControlCentreView(kind: .maintenance)
        case .architecture: LaravelControlCentreView(kind: .architecture)
        case .storage: LaravelControlCentreView(kind: .storage)
        case .apiCentre: LaravelControlCentreView(kind: .apiCentre)
        case .mailPreview: LaravelControlCentreView(kind: .mailPreview)
        case .aiInspector: LaravelControlCentreView(kind: .aiInspector)
        case .aiWorkspace: AIWorkspaceView()
        case .openWebUI: OpenWebUIView()
        case .lmStudio: LMStudioView()
        case .mcp: MCPWorkspaceView()
            }
        }
        .id(store.selectedSection)
        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .trailing)), removal: .opacity))
        .animation(.easeInOut(duration: 0.18), value: store.selectedSection)
    }
}

private struct CommandPaletteView: View {
    @Environment(AppStore.self) private var store
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "command.square.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                TextField("Search sections, actions, or Artisan commands", text: $store.commandPaletteQuery)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                Text("⌘⇧P").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .padding(18)
            Divider()

            if store.filteredCommandPaletteItems.isEmpty {
                ContentUnavailableView.search(text: store.commandPaletteQuery)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.filteredCommandPaletteItems) { item in
                    Button {
                        store.executePaletteItem(item)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.symbol)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.tint)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).fontWeight(.semibold)
                                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "return").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 520, idealHeight: 620)
        .task { searchFocused = true }
        .onExitCommand { store.isCommandPalettePresented = false }
    }
}
