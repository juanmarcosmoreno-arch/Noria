import AppKit
import NoriaCore
import Observation
import UserNotifications

/// Noria Watch: a light check once a minute (free space, CPU, memory pressure)
/// that feeds the menu bar extra and the optional notifications. It runs only
/// while the menu bar extra or a notification is enabled, and never scans files.
@MainActor
@Observable
final class WatchService {
    private(set) var availableBytes: Int64?
    private(set) var totalBytes: Int64?
    private(set) var cpuUsage: Double?
    private(set) var memoryPressure: MemoryPressure?
    private(set) var isRunning = false

    @ObservationIgnored private var evaluator = WatchEvaluator(configuration: WatchConfiguration())
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastTicks: CPUTicks?
    @ObservationIgnored private var home: String = SystemLocations.current.home
    private let interval: Duration = .seconds(60)

    /// Starts or stops the loop to match the settings.
    func configure(_ settings: NoriaSettings) {
        let configuration = WatchConfiguration(settings: settings)
        evaluator.configuration = configuration
        let shouldRun = settings.showsMenuBarExtra || !configuration.isEmpty
        if shouldRun && task == nil {
            isRunning = true
            task = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.tick()
                    guard let interval = self?.interval else { return }
                    try? await Task.sleep(for: interval)
                }
            }
        } else if !shouldRun {
            task?.cancel()
            task = nil
            isRunning = false
        }
    }

    /// Refreshes the readings now (used when the menu opens).
    func refreshNow() {
        Task { await tick(evaluate: false) }
    }

    private func tick(evaluate: Bool = true) async {
        let home = self.home
        let volume = await Task.detached(priority: .utility) { try? VolumeInfoProvider().volumeInfo(for: home) }.value
        availableBytes = volume?.availableForImportantUsage
        totalBytes = volume?.totalCapacity
        if let ticks = SystemMetrics.cpuTicks() {
            if let lastTicks { cpuUsage = ticks.usage(since: lastTicks) }
            lastTicks = ticks
        }
        memoryPressure = SystemMetrics.memory()?.pressure
        guard evaluate else { return }
        for alert in evaluator.ingest(date: Date(), availableBytes: availableBytes, cpu: cpuUsage) {
            post(alert)
        }
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func post(_ alert: WatchAlert) {
        let content = UNMutableNotificationContent()
        switch alert {
        case .lowSpace(let available):
            content.title = String(localized: "Your Mac is running out of space")
            content.body = String(localized: "Only \(Format.bytes(available)) available. Open Noria to see what you can safely clean.")
        case .spaceDropped(let amount, let available):
            content.title = String(localized: "Free space dropped quickly")
            content.body = String(localized: "\(Format.bytes(amount)) were used in the last hour; \(Format.bytes(available)) remain. A download, backup or app may be writing a lot.")
        case .sustainedHighCPU(let average, let minutes):
            content.title = String(localized: "Your Mac has been very busy")
            content.body = String(localized: "CPU usage averaged \(Format.percent(average)) for \(Format.count(minutes)) minutes. Open Performance in Noria to see which app is responsible.")
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
