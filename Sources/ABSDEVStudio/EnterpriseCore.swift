import Foundation
import Observation

// MARK: - Shared application events

enum StudioEvent: Sendable, Equatable {
    case projectOpened(UUID)
    case projectClosed(UUID)
    case projectIndexed(UUID)
    case runtimeChanged(UUID)
    case diagnosticsChanged
    case documentationOpened(String)
    case knowledgeBaseUpdated(UUID?)
    case aiCompleted(UUID?)
}

@MainActor
@Observable
final class StudioEventBus {
    static let shared = StudioEventBus()

    private(set) var recentEvents: [StudioEvent] = []
    private var continuations: [UUID: AsyncStream<StudioEvent>.Continuation] = [:]

    private init() {}

    func publish(_ event: StudioEvent) {
        recentEvents.insert(event, at: 0)
        if recentEvents.count > 200 { recentEvents.removeLast(recentEvents.count - 200) }
        for continuation in continuations.values { continuation.yield(event) }
    }

    func stream() -> AsyncStream<StudioEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations.removeValue(forKey: id) }
            }
        }
    }
}

// MARK: - Unified diagnostics

struct StudioDiagnostic: Identifiable, Codable, Hashable, Sendable {
    enum Severity: String, Codable, CaseIterable, Sendable { case information, warning, error }
    enum Domain: String, Codable, CaseIterable, Sendable {
        case application, project, runtime, database, git, ai, mcp, documentation
    }

    let id: UUID
    let createdAt: Date
    let severity: Severity
    let domain: Domain
    let title: String
    let detail: String
    let projectID: UUID?

    init(severity: Severity, domain: Domain, title: String, detail: String, projectID: UUID? = nil) {
        self.id = UUID()
        self.createdAt = Date()
        self.severity = severity
        self.domain = domain
        self.title = title
        self.detail = detail
        self.projectID = projectID
    }
}

@MainActor
@Observable
final class StudioDiagnosticsCentre {
    static let shared = StudioDiagnosticsCentre()
    private(set) var items: [StudioDiagnostic] = []

    private init() {}

    func report(_ diagnostic: StudioDiagnostic) {
        items.insert(diagnostic, at: 0)
        if items.count > 1_000 { items.removeLast(items.count - 1_000) }
        StudioEventBus.shared.publish(.diagnosticsChanged)
    }

    func clear(projectID: UUID? = nil) {
        guard let projectID else { items.removeAll(); return }
        items.removeAll { $0.projectID == projectID }
    }
}

// MARK: - Unified logging

struct StudioLogEntry: Identifiable, Codable, Hashable, Sendable {
    enum Channel: String, Codable, CaseIterable, Sendable {
        case application, project, runtime, database, git, ai, mcp, documentation
    }

    let id: UUID
    let timestamp: Date
    let channel: Channel
    let message: String
    let projectID: UUID?

    init(channel: Channel, message: String, projectID: UUID? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.channel = channel
        self.message = message
        self.projectID = projectID
    }
}

@MainActor
@Observable
final class StudioLogCentre {
    static let shared = StudioLogCentre()
    private(set) var entries: [StudioLogEntry] = []

    private init() {}

    func write(_ message: String, channel: StudioLogEntry.Channel = .application, projectID: UUID? = nil) {
        entries.insert(StudioLogEntry(channel: channel, message: message, projectID: projectID), at: 0)
        if entries.count > 5_000 { entries.removeLast(entries.count - 5_000) }
    }
}

// MARK: - Project Digital Twin foundation

struct ProjectDigitalTwinSnapshot: Codable, Hashable, Sendable {
    struct Runtime: Codable, Hashable, Sendable {
        var phpExecutable: String?
        var phpVersion: String
        var composerVersion: String?
        var nodeVersion: String?
    }

    let projectID: UUID
    var indexedAt: Date
    var files: [String]
    var routes: [String]
    var controllers: [String]
    var models: [String]
    var packages: [String: String]
    var configurationFiles: [String]
    var testFiles: [String]
    var migrations: [String]
    var jobs: [String]
    var events: [String]
    var listeners: [String]
    var middleware: [String]
    var policies: [String]
    var views: [String]
    var runtime: Runtime

    static func empty(for project: LaravelProject) -> Self {
        .init(
            projectID: project.id,
            indexedAt: .distantPast,
            files: [], routes: [], controllers: [], models: [], packages: [:],
            configurationFiles: [], testFiles: [], migrations: [], jobs: [], events: [], listeners: [], middleware: [], policies: [], views: [],
            runtime: .init(phpExecutable: project.phpExecutablePath, phpVersion: project.phpVersion, composerVersion: nil, nodeVersion: nil)
        )
    }
}

actor ProjectDigitalTwinService {
    static let shared = ProjectDigitalTwinService()
    private var snapshots: [UUID: ProjectDigitalTwinSnapshot] = [:]

    func snapshot(for project: LaravelProject, refresh: Bool = false) async -> ProjectDigitalTwinSnapshot {
        if !refresh, let existing = snapshots[project.id] { return existing }
        let built = await buildSnapshot(for: project)
        snapshots[project.id] = built
        await MainActor.run {
            StudioLogCentre.shared.write("Indexed digital twin for \(project.name)", channel: .project, projectID: project.id)
            StudioEventBus.shared.publish(.projectIndexed(project.id))
        }
        return built
    }

    func invalidate(projectID: UUID) { snapshots.removeValue(forKey: projectID) }

    private func buildSnapshot(for project: LaravelProject) async -> ProjectDigitalTwinSnapshot {
        let root = URL(fileURLWithPath: project.path, isDirectory: true)
        let fm = FileManager.default
        let ignored = Set(["vendor", "node_modules", ".git", "storage", ".build", "DerivedData"])
        var files: [String] = []
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: [.skipsHiddenFiles]) {
            while let url = enumerator.nextObject() as? URL {
                let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
                let first = relative.split(separator: "/").first.map(String.init) ?? ""
                if ignored.contains(first) { enumerator.skipDescendants(); continue }
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(relative) }
                if files.count >= 25_000 { break }
            }
        }
        files.sort()

        let controllers = files.filter { $0.hasPrefix("app/Http/Controllers/") && $0.hasSuffix(".php") }
        let models = files.filter { $0.hasPrefix("app/Models/") && $0.hasSuffix(".php") }
        let routes = files.filter { $0.hasPrefix("routes/") && $0.hasSuffix(".php") }
        let configs = files.filter { $0.hasPrefix("config/") && $0.hasSuffix(".php") }
        let tests = files.filter { $0.hasPrefix("tests/") && $0.hasSuffix(".php") }
        let migrations = files.filter { $0.hasPrefix("database/migrations/") && $0.hasSuffix(".php") }
        let jobs = files.filter { $0.hasPrefix("app/Jobs/") && $0.hasSuffix(".php") }
        let events = files.filter { $0.hasPrefix("app/Events/") && $0.hasSuffix(".php") }
        let listeners = files.filter { $0.hasPrefix("app/Listeners/") && $0.hasSuffix(".php") }
        let middleware = files.filter { $0.contains("/Middleware/") && $0.hasSuffix(".php") }
        let policies = files.filter { $0.hasPrefix("app/Policies/") && $0.hasSuffix(".php") }
        let views = files.filter { $0.hasPrefix("resources/views/") && ($0.hasSuffix(".blade.php") || $0.hasSuffix(".php")) }

        var packages: [String: String] = [:]
        let lockURL = root.appendingPathComponent("composer.lock")
        if let data = try? Data(contentsOf: lockURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["packages", "packages-dev"] {
                for package in object[key] as? [[String: Any]] ?? [] {
                    if let name = package["name"] as? String, let version = package["version"] as? String { packages[name] = version }
                }
            }
        }

        return .init(
            projectID: project.id,
            indexedAt: Date(),
            files: files,
            routes: routes,
            controllers: controllers,
            models: models,
            packages: packages,
            configurationFiles: configs,
            testFiles: tests,
            migrations: migrations, jobs: jobs, events: events, listeners: listeners, middleware: middleware, policies: policies, views: views,
            runtime: .init(phpExecutable: project.phpExecutablePath, phpVersion: project.phpVersion, composerVersion: nil, nodeVersion: nil)
        )
    }
}
