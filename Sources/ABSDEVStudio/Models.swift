import Foundation
import SwiftUI


struct CommandPaletteItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case section(AppSection)
        case artisan(String)
        case action(String)
    }

    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let keywords: [String]
    let kind: Kind
}

struct LaravelProject: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var path: String
    var laravelVersion: String
    var phpVersion: String
    var branch: String
    var appURL: String
    var environment: String
    var iconSymbol: String? = nil
    var iconColorHex: String? = nil
    var customIconPath: String? = nil

    static let sample = LaravelProject(
        name: "PoolMate",
        path: NSString(string: "~/Developer/ABSDEV/PoolMate").expandingTildeInPath,
        laravelVersion: "13.x",
        phpVersion: "8.x",
        branch: "develop",
        appURL: "http://127.0.0.1:8000",
        environment: "local"
    )
}

enum AppSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case development = "Development"
    case environment = "Environment"
    case artisan = "Artisan"
    case tinker = "Tinker"
    case terminal = "Terminal"
    case intelligence = "Project Intelligence"
    case knowledgeBase = "Knowledge Base"
    case sail = "Sail"
    case logs = "Logs"
    case doctor = "Project Doctor"
    case database = "Database"
    case databaseConsole = "Database Console"
    case queue = "Queue"
    case routes = "Routes"
    case composer = "Composer"
    case scheduler = "Scheduler"
    case containers = "Containers"
    case servBay = "ServBay"
    case applicationStatus = "Application Status"
    case cacheControl = "Cache Control"
    case migrations = "Migrations"
    case events = "Events & Listeners"
    case models = "Models"
    case services = "Services & Integrations"
    case testing = "Testing Centre"
    case frontend = "Frontend"
    case realtime = "Real-Time Services"
    case observability = "Observability"
    case featureFlags = "Feature Flags"
    case deployment = "Deployment"
    case maintenance = "Maintenance Mode"
    case architecture = "Architecture Map"
    case storage = "Storage"
    case apiCentre = "API Centre"
    case mailPreview = "Mail & Notifications"
    case aiInspector = "Laravel AI"
    case openWebUI = "Open WebUI"
    case lmStudio = "LM Studio"
    case mcp = "MCP Tools"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2.fill"
        case .development: "play.rectangle.fill"
        case .environment: "slider.horizontal.3"
        case .artisan: "terminal.fill"
        case .tinker: "chevron.left.forwardslash.chevron.right"
        case .databaseConsole: "cylinder.split.1x2.fill"
        case .terminal: "terminal.fill"
        case .intelligence: "sparkles.rectangle.stack.fill"
        case .knowledgeBase: "books.vertical.fill"
        case .sail: "sailboat.fill"
        case .logs: "doc.text.magnifyingglass"
        case .doctor: "stethoscope"
        case .database: "cylinder.fill"
        case .queue: "tray.full.fill"
        case .routes: "arrow.triangle.branch"
        case .composer: "shippingbox.fill"
        case .scheduler: "calendar.badge.clock"
        case .containers: "shippingbox.and.arrow.backward.fill"
        case .servBay: "server.rack"
        case .applicationStatus: "heart.text.square.fill"
        case .cacheControl: "bolt.horizontal.circle.fill"
        case .migrations: "arrow.up.arrow.down.square.fill"
        case .events: "point.3.connected.trianglepath.dotted"
        case .models: "cube.transparent.fill"
        case .services: "switch.2"
        case .testing: "checkmark.seal.fill"
        case .frontend: "paintbrush.pointed.fill"
        case .realtime: "wave.3.right.circle.fill"
        case .observability: "gauge.with.dots.needle.67percent"
        case .featureFlags: "flag.pattern.checkered"
        case .deployment: "shippingbox.and.arrow.backward.fill"
        case .maintenance: "wrench.and.screwdriver.fill"
        case .architecture: "square.3.layers.3d"
        case .storage: "externaldrive.fill"
        case .apiCentre: "network"
        case .mailPreview: "envelope.badge.fill"
        case .aiInspector: "brain.head.profile.fill"
        case .openWebUI: "bubble.left.and.bubble.right.fill"
        case .lmStudio: "cpu.fill"
        case .mcp: "point.3.connected.trianglepath.dotted"
        }
    }

    var tint: Color {
        switch self {
        case .overview: .blue
        case .development: .green
        case .environment: .orange
        case .artisan: .mint
        case .tinker: .purple
        case .databaseConsole: .cyan
        case .terminal: .green
        case .intelligence: .pink
        case .knowledgeBase: .purple
        case .sail: .blue
        case .logs: .yellow
        case .doctor: .red
        case .database: .cyan
        case .queue: .purple
        case .routes: .indigo
        case .composer: .orange
        case .scheduler: .teal
        case .containers: .blue
        case .servBay: .pink
        case .applicationStatus: .green
        case .cacheControl: .yellow
        case .migrations: .orange
        case .events: .purple
        case .models: .indigo
        case .services: .teal
        case .testing: .green
        case .frontend: .pink
        case .realtime: .cyan
        case .observability: .mint
        case .featureFlags: .orange
        case .deployment: .blue
        case .maintenance: .red
        case .architecture: .purple
        case .storage: .brown
        case .apiCentre: .indigo
        case .mailPreview: .blue
        case .aiInspector: .pink
        case .openWebUI: .purple
        case .lmStudio: .orange
        case .mcp: .indigo
        }
    }
}

struct DevProcess: Identifiable {
    let id = UUID()
    let name: String
    let detail: String
    let symbol: String
    let command: String
    var isRunning: Bool
    var output: [String]
}

struct DiagnosticItem: Identifiable {
    enum Status { case healthy, warning, error }
    let id = UUID()
    let title: String
    let detail: String
    let status: Status
    let action: String?
    let command: String?
}

struct RouteItem: Identifiable {
    let id = UUID()
    let method: String
    let uri: String
    let name: String
    let action: String
    let middleware: String
}


struct DatabaseTableInfo: Identifiable, Hashable {
    let name: String
    let size: String
    let rows: String
    var id: String { name }
}

struct DatabaseColumnInfo: Identifiable, Hashable {
    let name: String
    let type: String
    let nullable: Bool
    let defaultValue: String
    let extra: String
    var id: String { name }
}

struct DatabaseIndexInfo: Identifiable, Hashable {
    let name: String
    let columns: String
    let unique: Bool
    let primary: Bool
    var id: String { name + columns }
}

struct DatabaseForeignKeyInfo: Identifiable, Hashable {
    let name: String
    let columns: String
    let referencedTable: String
    let referencedColumns: String
    var id: String { name + columns + referencedTable }
}

struct EnvironmentEntry: Identifiable {
    let id = UUID()
    var key: String
    var value: String
    var isSecret: Bool = false
}


struct ArtisanCommand: Identifiable, Hashable {
    let name: String
    let description: String
    let usage: [String]
    let aliases: [String]

    var id: String { name }
    var namespace: String {
        guard let separator = name.firstIndex(of: ":") else { return "Global" }
        return String(name[..<separator]).capitalized
    }

    var primaryUsage: String {
        usage.first ?? name
    }
}

struct TestFailureReport: Identifiable {
    let id = UUID()
    let command: String
    let projectName: String
    let exitCode: Int32
    let failureCount: Int?
    let details: String
    let createdAt = Date()

    var title: String {
        if let failureCount {
            return failureCount == 1 ? "1 Test Failed" : "\(failureCount) Tests Failed"
        }
        return "Tests Failed"
    }
}


struct SailCommand: Identifiable, Hashable {
    let name: String
    let description: String
    let example: String
    let category: String
    let interactive: Bool

    var id: String { name }
}


enum CapabilityHealth: String, Hashable {
    case ready = "Ready"
    case attention = "Needs attention"
    case problem = "Problem detected"
    case unavailable = "Not configured"

    var symbol: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .problem: "xmark.octagon.fill"
        case .unavailable: "circle.dashed"
        }
    }

    var tint: Color {
        switch self {
        case .ready: .green
        case .attention: .yellow
        case .problem: .red
        case .unavailable: .secondary
        }
    }
}

enum LaravelProjectProfile: String, CaseIterable, Identifiable, Hashable {
    case api = "Laravel API"
    case livewire = "Livewire"
    case inertia = "Inertia"
    case packageDevelopment = "Package Development"
    case filament = "Filament"
    case modules = "Modules"
    case microservice = "Microservice"
    case sail = "Sail"
    case docker = "Docker"
    case servBay = "ServBay"

    var id: String { rawValue }
}

struct ProjectCapabilitiesSnapshot: Hashable {
    var scannedAt = Date.distantPast
    var packages: Set<String> = []
    var directPackages: Set<String> = []
    var artisanCommands: Set<String> = []
    var existingPaths: Set<String> = []
    var nonEmptyDirectories: Set<String> = []
    var profiles: Set<LaravelProjectProfile> = []
    var health: [String: CapabilityHealth] = [:]

    static let empty = ProjectCapabilitiesSnapshot()

    func hasPackage(_ name: String) -> Bool { packages.contains(name.lowercased()) }
    func hasAnyPackage(_ names: [String]) -> Bool { names.contains { hasPackage($0) } }
    func hasCommand(_ name: String) -> Bool { artisanCommands.contains(name) }
    func hasPath(_ path: String) -> Bool { existingPaths.contains(path) }
    func hasFiles(in path: String) -> Bool { nonEmptyDirectories.contains(path) }
    func status(for key: String, fallback: CapabilityHealth = .ready) -> CapabilityHealth { health[key] ?? fallback }
}


struct ProjectCapability: Identifiable, Hashable {
    let name: String
    let package: String
    let symbol: String
    let category: String
    let installed: Bool
    let directDependency: Bool
    let detail: String
    let developmentDependency: Bool
    var id: String { package }
}


struct SystemLoadSample: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let cpuPercent: Double
    let memoryPercent: Double
}

struct ServBayService: Identifiable, Hashable {
    enum State: String {
        case running = "Running"
        case stopped = "Stopped"
        case unavailable = "Unavailable"
        case checking = "Checking…"
        var isRunning: Bool { self == .running }
    }

    let id: String
    let name: String
    let symbol: String
    var state: State
    var detail: String
}


struct ServBayWebsite: Identifiable, Hashable {
    let id: String
    let name: String
    let domain: String
    let rootPath: String
    let phpVersion: String
    let server: String
    let isSSL: Bool
    let isLaravel: Bool
    let isReachable: Bool

    var url: URL? { URL(string: "\(isSSL ? "https" : "http")://\(domain)") }
}

struct ServBayRuntimeVersion: Identifiable, Hashable {
    let id: String
    let version: String
    let executablePath: String
    let isCurrent: Bool
    let extensions: [String]
}

struct ServBayCertificate: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let subject: String
    let issuer: String
    let expiresAt: Date?

    var isExpiringSoon: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 60 * 60 * 24 * 30
    }
}

struct ServBayLogFile: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let sizeBytes: Int64
    let modifiedAt: Date?
}

struct ServBayServiceMetrics: Hashable {
    let cpuPercent: Double
    let memoryPercent: Double
    let processCount: Int
    let uptime: String
    let version: String
}
