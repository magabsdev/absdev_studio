import Darwin
import Foundation
import Observation
import SwiftUI
import Charts

fileprivate struct PerformanceSample: Identifiable {
    let id = UUID()
    let date: Date
    let cpu: Double
    let memory: Double
}

@MainActor
@Observable
final class OverviewPerformanceMonitor {
    static let shared = OverviewPerformanceMonitor()

    var cpuPercent = 0.0
    var memoryPercent = 0.0
    var storagePercent = 0.0
    var storageUsedText = "—"
    fileprivate var history: [PerformanceSample] = []

    private var samplingTask: Task<Void, Never>?
    private var previousCPU: host_cpu_load_info_data_t?

    private init() {}

    func start() {
        guard samplingTask == nil else { return }
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
                memory: memoryPercent
            )
        )
        if history.count > 60 {
            history.removeFirst(history.count - 60)
        }
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
        guard let previousCPU else { return 0 }

        let user = Double(load.cpu_ticks.0 - previousCPU.cpu_ticks.0)
        let system = Double(load.cpu_ticks.1 - previousCPU.cpu_ticks.1)
        let idle = Double(load.cpu_ticks.2 - previousCPU.cpu_ticks.2)
        let nice = Double(load.cpu_ticks.3 - previousCPU.cpu_ticks.3)
        let total = user + system + idle + nice

        guard total > 0 else { return 0 }
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

        guard total > 0 else { return 0 }
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

struct OverviewPerformanceCounters: View {
    @State private var monitor = OverviewPerformanceMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("System Load")
                        .font(.title3.bold())
                    Text("Live CPU, memory and storage usage sampled every two seconds")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
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

            if monitor.history.count > 1 {
                Chart {
                    ForEach(monitor.history) { sample in
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
                    }
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(
                        position: .leading,
                        values: .stride(by: 25)
                    ) { axisValue in
                        AxisGridLine()
                        AxisValueLabel {
                            if let percentage = axisValue.as(Double.self) {
                                Text("\(Int(percentage))%")
                            }
                        }
                    }
                }
                .frame(height: 150)
            }
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.separator.opacity(0.65))
        )
        .task { monitor.start() }
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
