import SwiftUI

struct ContainersView: View {
    @State private var manager = ContainerStore()
    @State private var pullReference = ""
    @State private var volumeName = ""
    @State private var imagePendingDelete: RuntimeImage?
    @AppStorage("containers.showActivity") private var showActivity = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showActivity {
                HSplitView {
                    content.frame(minWidth: 620)
                    console.frame(minWidth: 300, idealWidth: 420)
                }
            } else {
                content.frame(minWidth: 620)
            }
        }
        .task { await manager.refreshAll() }
        .task(id: "\(manager.runtime.rawValue)-\(manager.area.rawValue)") {
            guard manager.runtime == .docker, manager.area == .monitor else { return }
            while !Task.isCancelled {
                await manager.refreshStats()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .confirmationDialog(
            "Delete Docker image?",
            isPresented: Binding(
                get: { imagePendingDelete != nil },
                set: { if !$0 { imagePendingDelete = nil } }
            ),
            presenting: imagePendingDelete
        ) { image in
            Button("Delete \(image.repository):\(image.tag)", role: .destructive) {
                showActivity = true
                Task { await manager.removeImage(image) }
                imagePendingDelete = nil
            }
            Button("Cancel", role: .cancel) { imagePendingDelete = nil }
        } message: { image in
            Text("This permanently removes \(image.repository):\(image.tag) from Docker. Containers using the image may prevent removal until they are deleted.")
        }
    }

    private var availableAreas: [ContainerArea] {
        if manager.runtime == .docker {
            return [.containers, .images, .volumes, .networks, .compose, .system, .monitor]
        }
        return [.containers, .images, .volumes, .system]
    }

    private func areaSymbol(_ area: ContainerArea) -> String {
        switch area {
        case .containers: return "shippingbox"
        case .images: return "photo.on.rectangle"
        case .volumes: return "externaldrive"
        case .networks: return "point.3.connected.trianglepath.dotted"
        case .compose: return "square.3.layers.3d"
        case .system: return "terminal"
        case .monitor: return "waveform.path.ecg"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text("Runtime:")
                    .fontWeight(.semibold)
                    .frame(width: 72, alignment: .trailing)

                HStack(spacing: 0) {
                    ForEach(ContainerRuntime.allCases) { runtime in
                        Button {
                            manager.selectRuntime(runtime)
                            if !availableAreas.contains(manager.area) {
                                manager.area = .containers
                            }
                        } label: {
                            Label(runtime.rawValue, systemImage: runtime.symbol)
                                .frame(minWidth: runtime == .docker ? 150 : 180)
                                .frame(height: 34)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(manager.runtime == runtime ? Color.accentColor : Color.secondary.opacity(0.13))
                        .foregroundStyle(manager.runtime == runtime ? Color.white : Color.primary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                Spacer(minLength: 20)

                Circle()
                    .fill(manager.runtimeAvailable ? Color.green : Color.red)
                    .frame(width: 9, height: 9)
                Text(manager.runtimeAvailable ? "Connected" : "Unavailable")
                    .foregroundStyle(.secondary)

                Button { Task { await manager.refreshAll() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .frame(height: 30)
                }
                .buttonStyle(.bordered)
                .disabled(manager.isBusy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                Text("Area:")
                    .fontWeight(.semibold)
                    .frame(width: 72, alignment: .trailing)

                HStack(spacing: 2) {
                    ForEach(availableAreas) { area in
                        Button {
                            manager.area = area
                        } label: {
                            Label(area.rawValue, systemImage: areaSymbol(area))
                                .lineLimit(1)
                                .frame(minWidth: area == .containers ? 120 : 104)
                                .frame(height: 34)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(manager.area == area ? Color.accentColor : Color.secondary.opacity(0.10))
                        .foregroundStyle(manager.area == area ? Color.white : Color.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }

                TextField("Filter", text: $manager.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180, idealWidth: 260, maxWidth: 340)

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showActivity.toggle()
                    }
                } label: {
                    Image(systemName: showActivity ? "sidebar.right" : "sidebar.right")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .help(showActivity ? "Hide Activity" : "Show Activity")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.bar)
        .onChange(of: manager.runtime) { _, _ in
            if !availableAreas.contains(manager.area) {
                manager.area = .containers
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch manager.area {
        case .containers: containerList
        case .monitor: monitorView
        case .images: imageList
        case .volumes: volumeList
        case .networks: networkList
        case .compose: composeList
        case .system: systemView
        }
    }

    private var containerList: some View {
        Table(manager.containers.filter { manager.search.isEmpty || "\($0.name) \($0.image) \($0.status)".localizedCaseInsensitiveContains(manager.search) }) {
            TableColumn("Name") { Text($0.name).fontWeight(.medium) }
            TableColumn("Image") { Text($0.image).lineLimit(1) }
            TableColumn("State") { row in Label(row.status.isEmpty ? row.state : row.status, systemImage: row.isRunning ? "circle.fill" : "circle").foregroundStyle(row.isRunning ? Color.green : Color.secondary) }
            TableColumn("Ports") { Text($0.ports).foregroundStyle(.secondary) }
            TableColumn("Actions") { row in
                HStack(spacing: 6) {
                    Button { Task { await manager.containerAction(row.isRunning ? "stop" : "start", id: row.id) } } label: { Image(systemName: row.isRunning ? "stop.fill" : "play.fill") }
                    Button { Task { await manager.containerAction("restart", id: row.id) } } label: { Image(systemName: "arrow.clockwise") }
                    Menu { containerMenu(row) } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton)
                }.buttonStyle(.borderless)
            }.width(120)
        }
    }

    @ViewBuilder private func containerMenu(_ row: RuntimeContainer) -> some View {
        Button("Logs") {
            showActivity = true
            Task { await manager.logs(container: row) }
        }
        Button("Inspect") { Task { await manager.inspect(kind: "container", id: row.id) } }
        Button("Open Shell") { Task { await manager.openShell(id: row.id) } }
        Divider()
        Button("Kill", role: .destructive) { Task { await manager.containerAction("kill", id: row.id) } }
        Button("Remove", role: .destructive) { Task { await manager.containerAction("remove", id: row.id) } }
    }


    private var monitorView: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Live Docker Statistics", systemImage: "gauge.with.dots.needle.67percent")
                    .fontWeight(.semibold)
                Text("Refreshes every 2 seconds using docker stats --no-stream")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh Now") { Task { await manager.refreshStats() } }
            }
            .padding(10)

            Table(manager.stats.filter { manager.search.isEmpty || $0.name.localizedCaseInsensitiveContains(manager.search) }) {
                TableColumn("Container") { Text($0.name).fontWeight(.medium) }
                TableColumn("CPU") { row in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(row.cpu); Spacer() }
                        ProgressView(value: row.cpuValue, total: 100)
                            .progressViewStyle(.linear)
                            .help("CPU usage: \(row.cpu)")
                    }
                    .padding(.vertical, 4)
                }
                TableColumn("Memory") { row in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(row.memoryUsage).lineLimit(1)
                            Spacer()
                            Text(row.memoryPercent).font(.caption).foregroundStyle(.secondary)
                        }
                        ProgressView(value: row.memoryValue, total: 100)
                            .progressViewStyle(.linear)
                            .help("Memory usage: \(row.memoryUsage) (\(row.memoryPercent))")
                    }
                    .padding(.vertical, 4)
                }
                TableColumn("Network I/O") { Text($0.networkIO) }
                TableColumn("Block I/O") { Text($0.blockIO) }
                TableColumn("PIDs") { Text($0.pids) }
            }
        }
    }

    private var imageList: some View {
        VStack(spacing: 0) {
            HStack { TextField("Image reference, e.g. nginx:latest", text: $pullReference); Button("Pull") { let value = pullReference; pullReference = ""; Task { await manager.pullImage(value) } }.disabled(pullReference.isEmpty) }.padding(10)
            Table(manager.images.filter { manager.search.isEmpty || "\($0.repository):\($0.tag)".localizedCaseInsensitiveContains(manager.search) }) {
                TableColumn("Repository") { Text($0.repository).fontWeight(.medium) }
                TableColumn("Tag") { Text($0.tag) }
                TableColumn("Size") { Text($0.size) }
                TableColumn("Created") { Text($0.created).foregroundStyle(.secondary) }
                TableColumn("") { row in
                    Menu {
                        Button("Inspect") {
                            showActivity = true
                            Task { await manager.inspect(kind: "image", id: row.id) }
                        }
                        Button("Delete", role: .destructive) {
                            imagePendingDelete = row
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                }
                .width(45)
            }
            HStack { Spacer(); Button("Prune Unused Images") { Task { await manager.prune("image") } }.padding(10) }
        }
    }

    private var volumeList: some View {
        VStack(spacing: 0) {
            HStack { TextField("New volume name", text: $volumeName); Button("Create") { let value = volumeName; volumeName = ""; Task { await manager.createVolume(value) } }.disabled(volumeName.isEmpty) }.padding(10)
            Table(manager.volumes.filter { manager.search.isEmpty || $0.name.localizedCaseInsensitiveContains(manager.search) }) {
                TableColumn("Name") { Text($0.name).fontWeight(.medium) }
                TableColumn("Driver") { Text($0.driver) }
                TableColumn("Source") { Text($0.mountpoint).lineLimit(1) }
                TableColumn("Size") { Text($0.size) }
                TableColumn("") { row in Menu { Button("Inspect") { Task { await manager.inspect(kind: "volume", id: row.name) } }; Button("Delete", role: .destructive) { Task { await manager.removeVolume(row.name) } } } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton) }.width(45)
            }
            HStack { Spacer(); Button("Prune Unused Volumes") { Task { await manager.prune("volume") } }.padding(10) }
        }
    }

    private var networkList: some View {
        Table(manager.networks.filter { manager.search.isEmpty || $0.name.localizedCaseInsensitiveContains(manager.search) }) {
            TableColumn("Name") { Text($0.name).fontWeight(.medium) }
            TableColumn("Driver") { Text($0.driver) }
            TableColumn("Scope") { Text($0.scope) }
            TableColumn("") { row in Menu { Button("Inspect") { Task { await manager.inspect(kind: "network", id: row.id) } }; Button("Delete", role: .destructive) { Task { await manager.removeNetwork(row.id) } } } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton) }.width(45)
        }
    }

    private var composeList: some View {
        Table(manager.composeProjects) {
            TableColumn("Project") { Text($0.name).fontWeight(.medium) }
            TableColumn("Status") { Text($0.status) }
            TableColumn("Configuration") { Text($0.configFiles).lineLimit(1) }
            TableColumn("Actions") { row in
                HStack {
                    Button("Up") { Task { await manager.composeAction("up -d", project: row) } }
                    Button("Down") { Task { await manager.composeAction("down", project: row) } }
                    Button("Logs") {
                        showActivity = true
                        Task { await manager.composeAction("logs --no-color --timestamps --tail 300", project: row) }
                    }
                }
                .buttonStyle(.borderless)
            }.width(160)
        }
    }

    private var systemView: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Runtime Configuration") {
                Form {
                    TextField("Executable", text: $manager.executablePath)
                    if manager.runtime == .docker { TextField("DOCKER_HOST (optional)", text: $manager.dockerHost) }
                }.padding(8)
            }
            HStack {
                if manager.runtime == .apple {
                    Button("Start System") { Task { await manager.systemAction("start") } }
                    Button("Stop System") { Task { await manager.systemAction("stop") } }
                    Button("Restart System") { Task { await manager.systemAction("restart") } }
                }
                Button("Load System Information") { Task { await manager.loadSystemInfo() } }
                if manager.runtime == .docker { Button("System Prune") { Task { await manager.prune("system") } } }
            }
            ScrollView { Text(manager.systemInfo.isEmpty ? "Choose Load System Information to inspect the runtime." : manager.systemInfo).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }.background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }.padding(16)
    }

    private var console: some View {
        VStack(spacing: 0) {
            HStack { Label("Activity", systemImage: "terminal").fontWeight(.semibold); Spacer(); Button("Clear") { manager.output = "" }.buttonStyle(.borderless) }.padding(10).background(.bar)
            ScrollView { Text(manager.output).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(12) }.background(Color(nsColor: .textBackgroundColor))
        }
    }
}
