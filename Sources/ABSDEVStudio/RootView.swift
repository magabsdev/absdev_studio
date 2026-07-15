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

    var body: some View {
        @Bindable var store = store

        List(selection: $store.selectedProjectID) {
            Section("Projects") {
                ForEach(store.projects) { project in
                    ProjectRow(project: project)
                        .tag(project.id)
                }
            }
        }
        .listStyle(.sidebar)
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
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        LinearGradient(
                            colors: [.red, .orange],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 34, height: 34)
                Image(systemName: "terminal.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
            }
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

private struct SectionNavigationView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store

        List(store.availableSections, selection: $store.selectedSection) { section in
            Label {
                Text(section.rawValue)
            } icon: {
                Image(systemName: section.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(section.tint)
                    .frame(width: 20)
            }
            .tag(section)
        }
        .navigationTitle(store.selectedProject?.name ?? "Laravel")
        .listStyle(.sidebar)
    }
}

private struct DetailRouter: View {
    @Environment(AppStore.self) private var store

    @ViewBuilder
    var body: some View {
        switch store.selectedSection {
        case .overview: OverviewView()
        case .development: DevelopmentView()
        case .environment: EnvironmentView()
        case .artisan: ArtisanView()
        case .tinker: TinkerView()
        case .databaseConsole: DatabaseConsoleView()
        case .terminal: TerminalWorkspaceView()
        case .intelligence: ProjectIntelligenceView()
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
        }
    }
}
