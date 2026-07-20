import Charts
import Darwin
import Foundation
import Observation
import SwiftUI

struct PerformanceSample: Identifiable, Codable, Sendable {
    let id: UUID
    let date: Date
    let cpu: Double
    let memory: Double
    let storage: Double

    init(id: UUID = UUID(), date: Date, cpu: Double, memory: Double, storage: Double) {
        self.id = id
        self.date = date
        self.cpu = cpu
        self.memory = memory
        self.storage = storage
    }
}

enum PerformanceRange: String, CaseIterable, Identifiable {
    case fiveMinutes = "5m"
    case oneHour = "1h"
    case oneDay = "24h"
    case sevenDays = "7d"
    case thirtyDays = "30d"

    var id: String { rawValue }

    var interval: TimeInterval {
        switch self {
        case .fiveMinutes: 5 * 60
        case .oneHour: 60 * 60
        case .oneDay: 24 * 60 * 60
        case .sevenDays: 7 * 24 * 60 * 60
        case .thirtyDays: 30 * 24 * 60 * 60
        }
    }
}

@MainActor
@Observable
final class OverviewPerformanceMonitor {
    var cpuPercent = 0.0
    var memoryPercent = 0.0
    var storagePercent = 0.0
    var storageUsedText = "—"
    private(set) var history: [PerformanceSample] = []

    private var samplingTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var previousCPU: host_cpu_load_info_data_t?
    private var activeProjectID: UUID?
    private var historyURL: URL?

    func configure(projectID: UUID) {
        guard activeProjectID != projectID else { return }
        stop()
        activeProjectID = projectID
        historyURL = Self.historyURL(for: projectID)
        history = loadHistory()
        previousCPU = nil

        if let latest = history.last {
            cpuPercent = latest.cpu
            memoryPercent = latest.memory
            storagePercent = latest.storage
        }
    }

    func start() {
        guard activeProjectID != nil, samplingTask == nil else { return }
        sample()
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                self?.sample()
            }
        }
    }

    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
        saveTask?.cancel()
        saveTask = nil
        persistHistory()
    }

    func samples(in range: PerformanceRange) -> [PerformanceSample] {
        let cutoff = Date().addingTimeInterval(-range.interval)
        let filtered = history.filter { $0.date >= cutoff }
        return downsampleForDisplay(filtered, maximumPoints: 900)
    }

    private func sample() {
        cpuPercent = readCPU()
        memoryPercent = readMemory()
        let storage = readStorage()
        storagePercent = storage.percent
        storageUsedText = storage.text

        history.append(
            PerformanceSample(
                date: .now,
                cpu: cpuPercent,
                memory: memoryPercent,
                storage: storagePercent
            )
        )

        compactHistory()
        scheduleSave()
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.persistHistory()
            self?.saveTask = nil
        }
    }

    private func loadHistory() -> [PerformanceSample] {
        guard let historyURL,
              let data = try? Data(contentsOf: historyURL),
              let decoded = try? JSONDecoder.performanceDecoder.decode([PerformanceSample].self, from: data)
        else { return [] }

        let cutoff = Date().addingTimeInterval(-(30 * 24 * 60 * 60))
        return decoded.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
    }

    private func persistHistory() {
        guard let historyURL else { return }
        compactHistory()
        do {
            try FileManager.default.createDirectory(
                at: historyURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.performanceEncoder.encode(history)
            try data.write(to: historyURL, options: .atomic)
        } catch {
            // Performance persistence is best-effort and must never interrupt the overview.
        }
    }

    private func compactHistory() {
        let now = Date()
        let thirtyDaysAgo = now.addingTimeInterval(-(30 * 24 * 60 * 60))
        let oneDayAgo = now.addingTimeInterval(-(24 * 60 * 60))
        let oneHourAgo = now.addingTimeInterval(-(60 * 60))

        let retained = history.filter { $0.date >= thirtyDaysAgo }.sorted { $0.date < $1.date }
        var recent: [PerformanceSample] = []
        var daily: [PerformanceSample] = []
        var archive: [PerformanceSample] = []

        var lastDailyBucket: Int64?
        var lastArchiveBucket: Int64?

        for sample in retained {
            if sample.date >= oneHourAgo {
                recent.append(sample) // Full two-second resolution for the latest hour.
            } else if sample.date >= oneDayAgo {
                let bucket = Int64(sample.date.timeIntervalSince1970 / 60)
                if bucket != lastDailyBucket {
                    daily.append(sample) // One point per minute for the latest day.
                    lastDailyBucket = bucket
                }
            } else {
                let bucket = Int64(sample.date.timeIntervalSince1970 / (15 * 60))
                if bucket != lastArchiveBucket {
                    archive.append(sample) // One point per 15 minutes for the 30-day archive.
                    lastArchiveBucket = bucket
                }
            }
        }

        history = archive + daily + recent
    }

    private func downsampleForDisplay(_ samples: [PerformanceSample], maximumPoints: Int) -> [PerformanceSample] {
        guard samples.count > maximumPoints else { return samples }
        let stride = max(1, Int(ceil(Double(samples.count) / Double(maximumPoints))))
        var result: [PerformanceSample] = []
        result.reserveCapacity(maximumPoints + 1)
        for index in Swift.stride(from: 0, to: samples.count, by: stride) {
            result.append(samples[index])
        }
        if let last = samples.last, result.last?.id != last.id {
            result.append(last)
        }
        return result
    }

    private static func historyURL(for projectID: UUID) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("ABSDEVStudio", isDirectory: true)
            .appendingPathComponent("Performance", isDirectory: true)
            .appendingPathComponent("\(projectID.uuidString).json")
    }

    private func readCPU() -> Double {
        var load = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return cpuPercent }

        defer { previousCPU = load }
        guard let previousCPU else { return cpuPercent }

        let user = Double(load.cpu_ticks.0 - previousCPU.cpu_ticks.0)
        let system = Double(load.cpu_ticks.1 - previousCPU.cpu_ticks.1)
        let idle = Double(load.cpu_ticks.2 - previousCPU.cpu_ticks.2)
        let nice = Double(load.cpu_ticks.3 - previousCPU.cpu_ticks.3)
        let total = user + system + idle + nice

        guard total > 0 else { return cpuPercent }
        return min(100, max(0, ((user + system + nice) / total) * 100))
    }

    private func readMemory() -> Double {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let result = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return memoryPercent }

        let pageSize = Double(vm_kernel_page_size)
        let active = Double(statistics.active_count) * pageSize
        let inactive = Double(statistics.inactive_count) * pageSize
        let wired = Double(statistics.wire_count) * pageSize
        let compressed = Double(statistics.compressor_page_count) * pageSize
        let used = active + inactive + wired + compressed
        let total = Double(ProcessInfo.processInfo.physicalMemory)

        guard total > 0 else { return memoryPercent }
        return min(100, max(0, used / total * 100))
    }

    private func readStorage() -> (percent: Double, text: String) {
        do {
            let values = try URL(fileURLWithPath: "/").resourceValues(
                forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
            )
            let total = Double(values.volumeTotalCapacity ?? 0)
            let available = Double(values.volumeAvailableCapacityForImportantUsage ?? 0)
            guard total > 0 else { return (0, "—") }

            let used = max(0, total - available)
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            formatter.allowedUnits = [.useGB, .useTB]
            let text = "\(formatter.string(fromByteCount: Int64(used))) / \(formatter.string(fromByteCount: Int64(total)))"
            return (min(100, used / total * 100), text)
        } catch {
            return (storagePercent, storageUsedText)
        }
    }
}

private extension JSONEncoder {
    static var performanceEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var performanceDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

struct OverviewPerformanceCounters: View {
    let projectID: UUID

    @State private var monitor = OverviewPerformanceMonitor()
    @State private var selectedRange: PerformanceRange = .oneHour

    private var visibleSamples: [PerformanceSample] {
        monitor.samples(in: selectedRange)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("System Load")
                        .font(.title3.bold())
                    Text("Persistent per-project history sampled every two seconds")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("History range", selection: $selectedRange) {
                    ForEach(PerformanceRange.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)

                Label("Live", systemImage: "waveform.path.ecg")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
            }

            HStack(spacing: 14) {
                performanceCard(
                    title: "CPU",
                    value: monitor.cpuPercent,
                    detail: "Current processor usage",
                    symbol: "cpu"
                )
                performanceCard(
                    title: "Memory",
                    value: monitor.memoryPercent,
                    detail: "\(monitor.memoryPercent.formatted(.number.precision(.fractionLength(1))))% in use",
                    symbol: "memorychip"
                )
                performanceCard(
                    title: "Storage",
                    value: monitor.storagePercent,
                    detail: monitor.storageUsedText,
                    symbol: "internaldrive"
                )
            }

            if visibleSamples.count > 1 {
                Chart {
                    ForEach(visibleSamples) { sample in
                        LineMark(
                            x: .value("Time", sample.date),
                            y: .value("CPU", sample.cpu)
                        )
                        .foregroundStyle(by: .value("Metric", "CPU"))

                        LineMark(
                            x: .value("Time", sample.date),
                            y: .value("Memory", sample.memory)
                        )
                        .foregroundStyle(by: .value("Metric", "Memory"))

                        LineMark(
                            x: .value("Time", sample.date),
                            y: .value("Storage", sample.storage)
                        )
                        .foregroundStyle(by: .value("Metric", "Storage"))
                    }
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .stride(by: 25)) { axisValue in
                        AxisGridLine()
                        AxisValueLabel {
                            if let percentage = axisValue.as(Double.self) {
                                Text("\(Int(percentage))%")
                            }
                        }
                    }
                }
                .frame(height: 190)
            } else {
                ContentUnavailableView(
                    "Building performance history",
                    systemImage: "chart.xyaxis.line",
                    description: Text("Samples are saved automatically and will be restored the next time ABSDEV Studio opens.")
                )
                .frame(height: 150)
            }
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.separator.opacity(0.65))
        )
        .task(id: projectID) {
            monitor.configure(projectID: projectID)
            monitor.start()
        }
        .onDisappear { monitor.stop() }
    }

    private func performanceCard(
        title: String,
        value: Double,
        detail: String,
        symbol: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.headline)
                Spacer()
                Text("\(value.formatted(.number.precision(.fractionLength(1))))%")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: value, total: 100)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }
}
