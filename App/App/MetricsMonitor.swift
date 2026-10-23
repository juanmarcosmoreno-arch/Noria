import NoriaCore
import Observation
import SwiftUI

/// Samples CPU and memory every few seconds while a view needs them.
/// Polling stops as soon as no view is subscribed, so Noria stays idle in the background.
@MainActor
@Observable
final class MetricsMonitor {
    private(set) var cpuUsage: Double?
    private(set) var memory: MemorySnapshot?

    private var subscribers = 0
    private var task: Task<Void, Never>?
    private var lastTicks: CPUTicks?
    private let interval: Duration

    init(interval: Duration = .seconds(2)) {
        self.interval = interval
    }

    func start() {
        subscribers += 1
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                guard let interval = self?.interval else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        subscribers = max(0, subscribers - 1)
        guard subscribers == 0 else { return }
        task?.cancel()
        task = nil
        lastTicks = nil
    }

    private func sample() {
        if let ticks = SystemMetrics.cpuTicks() {
            if let lastTicks, let usage = ticks.usage(since: lastTicks) { cpuUsage = usage }
            lastTicks = ticks
        }
        memory = SystemMetrics.memory()
    }
}
