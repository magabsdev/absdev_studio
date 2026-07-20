import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - Per-project runtime profiles

struct ProjectRuntimeProfile: Codable, Hashable, Sendable {
    var projectID: UUID
    var php: String = ""
    var composer: String = ""
    var node: String = ""
    var npm: String = ""
    var pnpm: String = ""
    var bun: String = ""
    var docker: String = ""
    var databaseDriver: String = "Auto"
    var environmentName: String = "local"
    var updatedAt: Date = .now

    static func profile(for project: LaravelProject) -> Self {
        .init(projectID: project.id, php: project.phpExecutablePath ?? "", environmentName: project.environment)
    }
}

@MainActor
@Observable
final class ProjectRuntimeProfileStore {
    static let shared = ProjectRuntimeProfileStore()

    private(set) var profiles: [UUID: ProjectRuntimeProfile] = [:]
    private(set) var validationMessages: [String: String] = [:]

    private init() { load() }

    func profile(for project: LaravelProject) -> ProjectRuntimeProfile {
        profiles[project.id] ?? .profile(for: project)
    }

    func save(_ profile: ProjectRuntimeProfile) {
        var updated = profile
        updated.updatedAt = .now
        profiles[profile.projectID] = updated
        persist()
        StudioEventBus.shared.publish(.runtimeChanged(profile.projectID))
        StudioLogCentre.shared.write("Saved project runtime profile", channel: .runtime, projectID: profile.projectID)
    }

    func detect(for project: LaravelProject) async -> ProjectRuntimeProfile {
        var value = profile(for: project)
        value.php = project.phpExecutablePath ?? executable(named: "php") ?? ""
        value.composer = executable(named: "composer") ?? ""
        value.node = executable(named: "node") ?? ""
        value.npm = executable(named: "npm") ?? ""
        value.pnpm = executable(named: "pnpm") ?? ""
        value.bun = executable(named: "bun") ?? ""
        value.docker = executable(named: "docker") ?? ""
        save(value)
        return value
    }

    func validate(_ profile: ProjectRuntimeProfile) async {
        let tools: [(String, String)] = [
            ("PHP", profile.php), ("Composer", profile.composer), ("Node", profile.node),
            ("npm", profile.npm), ("pnpm", profile.pnpm), ("Bun", profile.bun), ("Docker", profile.docker)
        ]
        var results: [String: String] = [:]
        for (name, path) in tools {
            guard !path.isEmpty else { results[name] = "Not configured"; continue }
            guard FileManager.default.isExecutableFile(atPath: path) else { results[name] = "Executable not found"; continue }
            results[name] = await version(of: path)
        }
        validationMessages = results
    }

    private func executable(named name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)",
            NSString(string: "~/.local/bin/\(name)").expandingTildeInPath,
            NSString(string: "~/Library/Application Support/ServBay/package/common/\(name)/current/bin/\(name)").expandingTildeInPath
        ]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
    }

    private func version(of executable: String) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = ["--version"]
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    process.waitUntilExit()
                    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(returning: output.split(separator: "\n").first.map(String.init) ?? "Available")
                } catch {
                    continuation.resume(returning: error.localizedDescription)
                }
            }
        }
    }

    private var storageURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ABSDEVStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("runtime-profiles.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let values = try? JSONDecoder().decode([ProjectRuntimeProfile].self, from: data) else { return }
        profiles = Dictionary(uniqueKeysWithValues: values.map { ($0.projectID, $0) })
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Array(profiles.values)) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}

struct RuntimeCentreView: View {
    @Environment(AppStore.self) private var store
    @State private var runtimeStore = ProjectRuntimeProfileStore.shared
    @State private var draft: ProjectRuntimeProfile?
    @State private var isWorking = false

    var body: some View {
        Group {
            if let project = store.selectedProject {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        FeatureHeader(title: "Runtime Centre", subtitle: "Configure and validate development tools independently for \(project.name).", symbol: "gearshape.2.fill")
                        if draft != nil {
                            RuntimeProfileEditor(profile: Binding(get: { draft! }, set: { draft = $0 }), messages: runtimeStore.validationMessages)
                            HStack {
                                Button("Detect Installed Tools", systemImage: "wand.and.stars") {
                                    isWorking = true
                                    Task { draft = await runtimeStore.detect(for: project); isWorking = false }
                                }
                                Button("Validate", systemImage: "checkmark.seal") {
                                    guard let draft else { return }
                                    isWorking = true
                                    Task { await runtimeStore.validate(draft); isWorking = false }
                                }
                                Spacer()
                                Button("Save Profile", systemImage: "square.and.arrow.down.fill") {
                                    guard let draft else { return }
                                    runtimeStore.save(draft)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .disabled(isWorking)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 1100, alignment: .leading)
                }
                .task(id: project.id) { draft = runtimeStore.profile(for: project) }
            } else {
                ContentUnavailableView("Select a project", systemImage: "folder.badge.questionmark")
            }
        }
    }
}

private struct RuntimeProfileEditor: View {
    @Binding var profile: ProjectRuntimeProfile
    let messages: [String: String]

    var body: some View {
        GroupBox("Project Runtime Profile") {
            VStack(spacing: 12) {
                runtimeRow("PHP", value: $profile.php)
                runtimeRow("Composer", value: $profile.composer)
                runtimeRow("Node", value: $profile.node)
                runtimeRow("npm", value: $profile.npm)
                runtimeRow("pnpm", value: $profile.pnpm)
                runtimeRow("Bun", value: $profile.bun)
                runtimeRow("Docker", value: $profile.docker)
                Divider()
                LabeledContent("Database Driver") { TextField("Auto", text: $profile.databaseDriver).frame(width: 360) }
                LabeledContent("Environment") { TextField("local", text: $profile.environmentName).frame(width: 360) }
            }
            .padding(8)
        }
    }

    private func runtimeRow(_ name: String, value: Binding<String>) -> some View {
        LabeledContent {
            HStack {
                TextField("Executable path", text: value).textFieldStyle(.roundedBorder).frame(width: 430)
                Text(messages[name] ?? "").font(.caption).foregroundStyle(.secondary).frame(width: 230, alignment: .leading)
            }
        } label: {
            Text(name).fontWeight(.medium)
        }
    }
}

// MARK: - Laravel-first project hub

struct LaravelStudioView: View {
    @Environment(AppStore.self) private var store
    @State private var snapshot: ProjectDigitalTwinSnapshot?
    @State private var loading = false

    var body: some View {
        Group {
            if let project = store.selectedProject {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        FeatureHeader(title: "Laravel Studio", subtitle: "A framework-aware map of \(project.name).", symbol: "shippingbox.fill")
                        if loading { ProgressView("Indexing Laravel application…") }
                        if let snapshot {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                                metric("Routes", snapshot.routes.count, "arrow.triangle.branch", .routes)
                                metric("Controllers", snapshot.controllers.count, "square.stack.3d.up.fill", .architecture)
                                metric("Models", snapshot.models.count, "cube.transparent.fill", .models)
                                metric("Migrations", snapshot.migrations.count, "arrow.up.arrow.down.square.fill", .migrations)
                                metric("Jobs", snapshot.jobs.count, "tray.full.fill", .queue)
                                metric("Events & Listeners", snapshot.events.count + snapshot.listeners.count, "bolt.horizontal.fill", .events)
                                metric("Views", snapshot.views.count, "rectangle.3.group.fill", .frontend)
                                metric("Tests", snapshot.testFiles.count, "checkmark.seal.fill", .testing)
                                metric("Packages", snapshot.packages.count, "shippingbox.fill", .composer)
                                metric("Configuration", snapshot.configurationFiles.count, "gearshape.fill", .environment)
                            }
                            GroupBox("Project Summary") {
                                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                                    summaryRow("Laravel", project.laravelVersion)
                                    summaryRow("PHP", project.phpVersion)
                                    summaryRow("Environment", project.environment)
                                    summaryRow("Branch", project.branch)
                                    summaryRow("Indexed", snapshot.indexedAt.formatted(date: .abbreviated, time: .standard))
                                }.padding(8)
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 1200, alignment: .leading)
                }
                .task(id: project.id) { await refresh(project) }
                .toolbar { Button("Refresh Index", systemImage: "arrow.clockwise") { Task { await refresh(project, force: true) } } }
            } else {
                ContentUnavailableView("Select a Laravel project", systemImage: "shippingbox")
            }
        }
    }

    private func metric(_ title: String, _ count: Int, _ symbol: String, _ section: AppSection) -> some View {
        Button { store.selectedSection = section } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol).font(.title2)
                Text(count.formatted()).font(.title.bold())
                Text(title).font(.headline)
                Text("Open \(title.lowercased())").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 125, alignment: .leading)
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func summaryRow(_ name: String, _ value: String) -> some View {
        GridRow { Text(name).foregroundStyle(.secondary); Text(value).textSelection(.enabled) }
    }

    private func refresh(_ project: LaravelProject, force: Bool = false) async {
        loading = true
        snapshot = await ProjectDigitalTwinService.shared.snapshot(for: project, refresh: force)
        loading = false
    }
}

private struct FeatureHeader: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 30)).frame(width: 48, height: 48).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) { Text(title).font(.largeTitle.bold()); Text(subtitle).foregroundStyle(.secondary) }
        }
    }
}
