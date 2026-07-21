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
        case .fiveMinutes: 300
        case .oneHour: 3_600
        case .oneDay: 86_400
        case .sevenDays: 604_800
        case .thirtyDays: 2_592_000
        }
    }
}

@MainActor
@Observable
final class OverviewPerformanceMonitor {
    var cpuPercent = 0.0
    var cpuSystemPercent = 0.0
    var cpuUserPercent = 0.0
    var cpuNicePercent = 0.0
    var cpuIdlePercent = 100.0

    var memoryPercent = 0.0
    var memoryUsedText = "—"
    var memoryAppText = "—"
    var memoryWiredText = "—"
    var memoryCompressedText = "—"

    var storagePercent = 0.0
    var storageUsedText = "—"
    var storageFreeText = "—"

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
        return downsampleForDisplay(history.filter { $0.date >= cutoff }, maximumPoints: 600)
    }

    private func sample() {
        readCPU()
        readMemory()
        readStorage()
        history.append(PerformanceSample(date: .now, cpu: cpuPercent, memory: memoryPercent, storage: storagePercent))
        compactHistory()
        scheduleSave()
    }

    private func readCPU() {
        var load = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        defer { previousCPU = load }
        guard let previousCPU else { return }

        let user = Double(load.cpu_ticks.0 - previousCPU.cpu_ticks.0)
        let system = Double(load.cpu_ticks.1 - previousCPU.cpu_ticks.1)
        let idle = Double(load.cpu_ticks.2 - previousCPU.cpu_ticks.2)
        let nice = Double(load.cpu_ticks.3 - previousCPU.cpu_ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return }

        cpuUserPercent = user / total * 100
        cpuSystemPercent = system / total * 100
        cpuNicePercent = nice / total * 100
        cpuIdlePercent = idle / total * 100
        cpuPercent = min(100, max(0, cpuUserPercent + cpuSystemPercent + cpuNicePercent))
    }

    private func readMemory() {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let pageSize = Double(vm_kernel_page_size)
        let app = Double(statistics.active_count + statistics.inactive_count) * pageSize
        let wired = Double(statistics.wire_count) * pageSize
        let compressed = Double(statistics.compressor_page_count) * pageSize
        let used = app + wired + compressed
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return }

        memoryPercent = min(100, max(0, used / total * 100))
        memoryUsedText = "\(formatBytes(used)) / \(formatBytes(total))"
        memoryAppText = formatBytes(app)
        memoryWiredText = formatBytes(wired)
        memoryCompressedText = formatBytes(compressed)
    }

    private func readStorage() {
        do {
            let values = try URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
            let total = Double(values.volumeTotalCapacity ?? 0)
            let available = Double(values.volumeAvailableCapacityForImportantUsage ?? 0)
            guard total > 0 else { return }
            let used = max(0, total - available)
            storagePercent = min(100, used / total * 100)
            storageUsedText = "\(formatBytes(used)) / \(formatBytes(total))"
            storageFreeText = formatBytes(available)
        } catch { }
    }

    private func formatBytes(_ bytes: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useTB]
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(bytes))
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
        guard let historyURL, let data = try? Data(contentsOf: historyURL),
              let decoded = try? JSONDecoder.performanceDecoder.decode([PerformanceSample].self, from: data) else { return [] }
        let cutoff = Date().addingTimeInterval(-2_592_000)
        return decoded.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
    }

    private func persistHistory() {
        guard let historyURL else { return }
        compactHistory()
        do {
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.performanceEncoder.encode(history).write(to: historyURL, options: .atomic)
        } catch { }
    }

    private func compactHistory() {
        let now = Date()
        let thirtyDaysAgo = now.addingTimeInterval(-2_592_000)
        let oneDayAgo = now.addingTimeInterval(-86_400)
        let oneHourAgo = now.addingTimeInterval(-3_600)
        let retained = history.filter { $0.date >= thirtyDaysAgo }.sorted { $0.date < $1.date }
        var recent: [PerformanceSample] = []
        var daily: [PerformanceSample] = []
        var archive: [PerformanceSample] = []
        var lastMinute: Int64?
        var lastQuarterHour: Int64?
        for sample in retained {
            if sample.date >= oneHourAgo {
                recent.append(sample)
            } else if sample.date >= oneDayAgo {
                let bucket = Int64(sample.date.timeIntervalSince1970 / 60)
                if bucket != lastMinute { daily.append(sample); lastMinute = bucket }
            } else {
                let bucket = Int64(sample.date.timeIntervalSince1970 / 900)
                if bucket != lastQuarterHour { archive.append(sample); lastQuarterHour = bucket }
            }
        }
        history = archive + daily + recent
    }

    private func downsampleForDisplay(_ samples: [PerformanceSample], maximumPoints: Int) -> [PerformanceSample] {
        guard samples.count > maximumPoints else { return samples }
        let step = max(1, Int(ceil(Double(samples.count) / Double(maximumPoints))))
        var result = Swift.stride(from: 0, to: samples.count, by: step).map { samples[$0] }
        if let last = samples.last, result.last?.id != last.id { result.append(last) }
        return result
    }

    private static func historyURL(for projectID: UUID) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ABSDEVStudio/Performance", isDirectory: true)
            .appendingPathComponent("\(projectID.uuidString).json")
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

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
    private var visibleSamples: [PerformanceSample] { monitor.samples(in: selectedRange) }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
            cpuCard
            historyCard
            memoryCard
            storageCard
        }
        .task(id: projectID) {
            monitor.configure(projectID: projectID)
            monitor.start()
        }
        .onDisappear { monitor.stop() }
    }

    private var cpuCard: some View {
        dashboardCard("CPU Load") {
            VStack(spacing: 10) {
                CompactCPUGauge(value: monitor.cpuPercent)
                    .frame(width: 205, height: 112)

                HStack(spacing: 0) {
                    metric("System", monitor.cpuSystemPercent, tint: .blue)
                    metric("User", monitor.cpuUserPercent, tint: .green)
                    metric("Nice", monitor.cpuNicePercent, tint: .purple)
                    metric("Idle", monitor.cpuIdlePercent, tint: .secondary)
                }
            }
        }
        .frame(minHeight: 230)
    }

    private var historyCard: some View {
        dashboardCard("CPU Usage History", trailing: {
            Picker("History range", selection: $selectedRange) {
                ForEach(PerformanceRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 250)
            .controlSize(.small)
        }) {
            Chart(visibleSamples) { sample in
                AreaMark(x: .value("Time", sample.date), y: .value("CPU", sample.cpu))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.linearGradient(colors: [.green.opacity(0.55), .green.opacity(0.04)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", sample.date), y: .value("CPU", sample.cpu))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .foregroundStyle(.green)
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, 50, 100]) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
                    AxisValueLabel {
                        if let number = value.as(Double.self) { Text("\(Int(number))%") }
                    }
                }
            }
            .frame(height: 145)
        }
        .frame(minHeight: 230)
    }

    private var memoryCard: some View {
        dashboardCard("Memory") {
            VStack(alignment: .leading, spacing: 16) {
                CompactUsageBar(value: monitor.memoryPercent)
                    .overlay(alignment: .trailing) {
                        Text(monitor.memoryUsedText).font(.caption.weight(.semibold)).foregroundStyle(.secondary).offset(x: 2, y: -22)
                    }
                HStack(spacing: 0) {
                    textMetric("Pressure", "\(monitor.memoryPercent.formatted(.number.precision(.fractionLength(1))))%")
                    textMetric("App", monitor.memoryAppText)
                    textMetric("Wired", monitor.memoryWiredText)
                    textMetric("Compressed", monitor.memoryCompressedText)
                }
            }
        }
        .frame(minHeight: 155)
    }

    private var storageCard: some View {
        dashboardCard("Storage") {
            VStack(alignment: .leading, spacing: 16) {
                CompactUsageBar(value: monitor.storagePercent)
                    .overlay(alignment: .trailing) {
                        Text(monitor.storageUsedText).font(.caption.weight(.semibold)).foregroundStyle(.secondary).offset(x: 2, y: -22)
                    }
                HStack(spacing: 0) {
                    textMetric("Used", monitor.storageUsedText.components(separatedBy: " / ").first ?? "—")
                    textMetric("Free", monitor.storageFreeText)
                    Spacer()
                }
            }
        }
        .frame(minHeight: 155)
    }

    private func dashboardCard<Content: View, Trailing: View>(
        _ title: String,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                trailing()
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.separator.opacity(0.45)))
    }

    private func dashboardCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        dashboardCard(title, trailing: { EmptyView() }, content: content)
    }

    private func metric(_ title: String, _ value: Double, tint: Color) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text("\(value.formatted(.number.precision(.fractionLength(1))))%")
                .font(.callout.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity)
    }

    private func textMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit()).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CompactCPUGauge: View {
    let value: Double
    private var progress: Double { min(1, max(0, value / 100)) }

    var body: some View {
        ZStack(alignment: .bottom) {
            Circle()
                .trim(from: 0.125, to: 0.875)
                .stroke(.quaternary, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                .rotationEffect(.degrees(90))

            Circle()
                .trim(from: 0.125, to: 0.125 + (0.75 * progress))
                .stroke(
                    AngularGradient(colors: [.green, .green, .yellow, .orange, .red], center: .center, startAngle: .degrees(135), endAngle: .degrees(405)),
                    style: StrokeStyle(lineWidth: 16, lineCap: .round)
                )
                .rotationEffect(.degrees(90))
                .animation(.easeOut(duration: 0.45), value: progress)

            Rectangle()
                .fill(.blue)
                .frame(width: 72, height: 7)
                .clipShape(Capsule())
                .offset(x: 34)
                .rotationEffect(.degrees(-135 + (270 * progress)), anchor: .leading)
                .animation(.easeOut(duration: 0.45), value: progress)

            Circle().fill(.blue).frame(width: 17, height: 17).offset(y: -9)

            Text("\(value.formatted(.number.precision(.fractionLength(1))))%")
                .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                .offset(y: 14)
        }
        .padding(.horizontal, 10)
    }
}

private struct CompactUsageBar: View {
    let value: Double
    private var progress: Double { min(1, max(0, value / 100)) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(colors: [.green, .green, .yellow, .orange], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(8, geometry.size.width * progress))
                    .animation(.easeOut(duration: 0.45), value: progress)
            }
        }
        .frame(height: 10)
    }
}
