import NoriaCore
import Observation
import SwiftUI

/// Samples system metrics every few seconds while a view needs them.
/// Polling stops as soon as no view is subscribed, so Noria stays idle in the
/// background. Per-process data is only collected while Performance is open.
@MainActor
@Observable
final class MetricsMonitor {
    struct Point: Identifiable {
        var date: Date
        var value: Double
        var id: Date { date }
    }

    private(set) var cpuUsage: Double?
    private(set) var memory: MemorySnapshot?
    private(set) var diskReadRate: Double?
    private(set) var diskWriteRate: Double?
    private(set) var cpuHistory: [Point] = []
    private(set) var memoryHistory: [Point] = []
    private(set) var diskReadHistory: [Point] = []
    private(set) var diskWriteHistory: [Point] = []
    private(set) var topByCPU: [ProcessUsage] = []
    private(set) var topByMemory: [ProcessUsage] = []
    /// Processes Noria could read (the rest are not visible to it).
    private(set) var visibleProcessCount = 0

    private var subscribers = 0
    private var processSubscribers = 0
    private var task: Task<Void, Never>?
    private var lastTicks: CPUTicks?
    private var lastDisk: (Date, DiskCounters)?
    private var lastProcesses: (Date, [ProcessSample])?
    private let interval: Duration
    private let historyLength = 90

    init(interval: Duration = .seconds(2)) {
        self.interval = interval
    }

    func start(includeProcesses: Bool = false) {
        subscribers += 1
        if includeProcesses { processSubscribers += 1 }
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sample()
                guard let interval = self?.interval else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop(includeProcesses: Bool = false) {
        subscribers = max(0, subscribers - 1)
        if includeProcesses {
            processSubscribers = max(0, processSubscribers - 1)
            if processSubscribers == 0 { lastProcesses = nil }
        }
        guard subscribers == 0 else { return }
        task?.cancel()
        task = nil
        lastTicks = nil
        lastDisk = nil
    }

    private func append(_ value: Double, to history: inout [Point], at date: Date) {
        history.append(Point(date: date, value: value))
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }
    }

    private func sample() async {
        let now = Date()
        if let ticks = SystemMetrics.cpuTicks() {
            if let lastTicks, let usage = ticks.usage(since: lastTicks) {
                cpuUsage = usage
                append(usage, to: &cpuHistory, at: now)
            }
            lastTicks = ticks
        }
        memory = SystemMetrics.memory()
        if let memory { append(memory.usedFraction, to: &memoryHistory, at: now) }
        if let counters = DiskCounters.current() {
            if let last = lastDisk, let rates = counters.rates(since: last.1, interval: now.timeIntervalSince(last.0)) {
                diskReadRate = rates.read
                diskWriteRate = rates.write
                append(rates.read, to: &diskReadHistory, at: now)
                append(rates.write, to: &diskWriteHistory, at: now)
            }
            lastDisk = (now, counters)
        }
        guard processSubscribers > 0 else { return }
        let samples = await Task.detached(priority: .utility) { ProcessMonitor.sample() }.value
        if let last = lastProcesses {
            let usage = ProcessMonitor.usage(from: last.1, to: samples, interval: now.timeIntervalSince(last.0))
            topByCPU = Array(usage.sorted { $0.cpu > $1.cpu }.prefix(10))
            topByMemory = Array(usage.sorted { $0.residentMemory > $1.residentMemory }.prefix(10))
            visibleProcessCount = usage.count
        }
        lastProcesses = (now, samples)
    }
}
