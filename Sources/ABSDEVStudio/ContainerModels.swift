import Foundation

enum ContainerRuntime: String, CaseIterable, Identifiable, Codable {
    case docker = "Docker"
    case apple = "Apple Container"
    var id: String { rawValue }
    var symbol: String { self == .docker ? "shippingbox.fill" : "apple.logo" }
}

enum ContainerArea: String, CaseIterable, Identifiable {
    case containers = "Containers"
    case monitor = "Monitor"
    case images = "Images"
    case volumes = "Volumes"
    case networks = "Networks"
    case compose = "Compose"
    case system = "System"
    var id: String { rawValue }
}

struct RuntimeContainer: Identifiable, Hashable {
    var id: String
    var name: String
    var image: String
    var state: String
    var status: String
    var ports: String
    var isRunning: Bool { state.lowercased().contains("running") || status.lowercased().contains("up") }
}

struct RuntimeImage: Identifiable, Hashable {
    var id: String
    var repository: String
    var tag: String
    var size: String
    var created: String
}

struct RuntimeVolume: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var driver: String
    var mountpoint: String
    var size: String
}

struct RuntimeNetwork: Identifiable, Hashable {
    var id: String
    var name: String
    var driver: String
    var scope: String
}

struct ComposeProject: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var status: String
    var configFiles: String
}


struct ContainerStats: Identifiable, Hashable {
    var id: String
    var name: String
    var cpu: String
    var memoryUsage: String
    var memoryPercent: String
    var networkIO: String
    var blockIO: String
    var pids: String

    var cpuValue: Double { Self.percentageValue(cpu) }
    var memoryValue: Double { Self.percentageValue(memoryPercent) }

    private static func percentageValue(_ text: String) -> Double {
        let cleaned = text
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return min(max(Double(cleaned) ?? 0, 0), 100)
    }
}
