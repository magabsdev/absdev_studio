import SwiftUI

struct OverviewView: View {
    @Environment(AppStore.self) private var store
    @State private var containerStore = ContainerStore()

    private let columns = [GridItem(.adaptive(minimum: 210), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "Project Overview", subtitle: "A live view of your Laravel development environment.")

                if let project = store.selectedProject {
                    HStack(spacing: 12) {
                        StatusPill(text: store.isDevelopmentRunning ? "Development running" : "Development stopped", active: store.isDevelopmentRunning)
                        Text(project.path)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button("Open \(project.appURL)") { store.openBrowser() }
                    }

                    LazyVGrid(columns: columns, spacing: 14) {
                        MetricCard(title: "Laravel", value: project.laravelVersion, detail: "Framework version", symbol: "shippingbox.fill")
                        MetricCard(title: "PHP", value: project.phpVersion, detail: "Active runtime", symbol: "chevron.left.forwardslash.chevron.right")
                        MetricCard(title: "Git branch", value: project.branch, detail: "Working tree clean", symbol: "point.3.connected.trianglepath.dotted")
                        MetricCard(title: "Environment", value: project.environment, detail: "APP_DEBUG enabled", symbol: "slider.horizontal.3")
                    }

                    if containerStore.runtimeAvailable && !containerStore.containers.isEmpty {
                        ContainerResourcesCard(store: containerStore)
                    }
                }

                GroupBox {
                    VStack(spacing: 0) {
                        OverviewRow(symbol: "checkmark.circle.fill", title: "Application health", detail: "6 checks passed, 2 warnings", tint: .green)
                        Divider()
                        OverviewRow(symbol: "arrow.up.circle.fill", title: "Database", detail: "1 migration pending", tint: .orange)
                        Divider()
                        OverviewRow(symbol: "tray.full.fill", title: "Queue", detail: "Worker active · 0 failed jobs", tint: .blue)
                        Divider()
                        OverviewRow(symbol: "doc.text.fill", title: "Logs", detail: "No new errors in the last hour", tint: .green)
                    }
                } label: {
                    Text("Project status").font(.headline)
                }

                HStack(alignment: .top, spacing: 14) {
                    GroupBox("Recent commands") {
                        VStack(alignment: .leading, spacing: 12) {
                            CommandHistoryRow(command: "php artisan test", time: "2 min ago", success: true)
                            CommandHistoryRow(command: "npm run build", time: "9 min ago", success: true)
                            CommandHistoryRow(command: "php artisan migrate", time: "Yesterday", success: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Quick actions") {
                        VStack(alignment: .leading, spacing: 8) {
                            QuickActionButton(title: "Run test suite", symbol: "checkmark.seal") {
                                store.selectedSection = .artisan
                                store.runArtisan("test")
                            }
                            QuickActionButton(title: "Clear Laravel caches", symbol: "arrow.clockwise") {
                                store.selectedSection = .artisan
                                store.runArtisan("optimize:clear")
                            }
                            QuickActionButton(title: "Run migrations", symbol: "cylinder.split.1x2") {
                                store.selectedSection = .artisan
                                store.runArtisan("migrate")
                            }
                            QuickActionButton(title: "Open Tinker", symbol: "terminal") {
                                store.selectedSection = .tinker
                                store.runTinker()
                            }
                        }
                        .disabled(store.selectedProject == nil || store.isBusy)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(28)
        }
        .navigationTitle("Overview")
        .task {
            containerStore.selectRuntime(.docker)
            await containerStore.refreshAll()

            // The performance card is intentionally absent when no container runtime is
            // actually in use. Avoid polling a missing daemon in the background.
            guard containerStore.runtimeAvailable, !containerStore.containers.isEmpty else { return }
            while !Task.isCancelled {
                await containerStore.refreshStats()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}


private struct QuickActionButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct ContainerResourcesCard: View {
    let store: ContainerStore

    var body: some View {
        GroupBox {
            VStack(spacing: 0) {
                if store.stats.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Waiting for live container statistics…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 110)
                } else {
                    ForEach(Array(store.stats.enumerated()), id: \.element.id) { index, stat in
                        ContainerResourceRow(stat: stat)
                        if index < store.stats.count - 1 { Divider() }
                    }
                }
            }
        } label: {
            HStack {
                Label("Container resources", systemImage: "gauge.with.dots.needle.67percent")
                    .font(.headline)
                Spacer()
                Text("Live · 2 second refresh")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ContainerResourceRow: View {
    let stat: ContainerStats

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(stat.name).fontWeight(.semibold)
                Spacer()
                Text("CPU \(stat.cpu) · Memory \(stat.memoryPercent)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CPU").font(.caption2).foregroundStyle(.secondary)
                    ProgressView(value: stat.cpuValue, total: 100)
                        .progressViewStyle(.linear)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Memory").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text(stat.memoryUsage).font(.caption2).foregroundStyle(.secondary)
                    }
                    ProgressView(value: stat.memoryValue, total: 100)
                        .progressViewStyle(.linear)
                }
            }
        }
        .padding(.vertical, 11)
    }
}

private struct OverviewRow: View {
    let symbol: String
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(tint).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(.vertical, 11)
    }
}

private struct CommandHistoryRow: View {
    let command: String
    let time: String
    let success: Bool

    var body: some View {
        HStack {
            Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(success ? .green : .red)
            Text(command).font(.callout.monospaced())
            Spacer()
            Text(time).font(.caption).foregroundStyle(.secondary)
        }
    }
}
