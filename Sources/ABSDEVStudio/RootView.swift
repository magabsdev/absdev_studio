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

    var body: some View {
        @Bindable var store = store

        List(selection: $store.selectedProjectID) {
            Section("Projects") {
                ForEach(store.projects) { project in
                    ProjectRow(project: project)
                        .tag(project.id)
                        .draggable(project.id.uuidString) {
                            ProjectRow(project: project)
                                .padding(8)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .dropDestination(for: String.self) { items, _ in
                            guard let rawID = items.first,
                                  let draggedID = UUID(uuidString: rawID) else { return false }
                            store.moveProject(draggedID, before: project.id)
                            return true
                        }
                        .contextMenu {
                            Button("Customize Project Icon…", systemImage: "paintpalette.fill") {
                                projectBeingCustomized = project
                            }
                            Button("Import SVG or Image…", systemImage: "photo.badge.plus") {
                                store.importProjectIcon(projectID: project.id)
                            }
                            Divider()
                            Button("Reset Project Icon", systemImage: "arrow.counterclockwise") {
                                store.resetProjectIcon(projectID: project.id)
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .sheet(item: $projectBeingCustomized) { project in
            ProjectIconEditor(project: project)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    store.addProject()
                } label: {
                    Label("Add Project", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    store.removeSelectedProject()
                } label: {
                    Image(systemName: "minus.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .disabled(store.selectedProject == nil)
            }
            .padding(12)
            .background(.bar)
        }
    }
}

private struct ProjectRow: View {
    let project: LaravelProject

    var body: some View {
        HStack(spacing: 10) {
            ProjectIconView(project: project, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).fontWeight(.semibold)
                Text(project.branch)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
