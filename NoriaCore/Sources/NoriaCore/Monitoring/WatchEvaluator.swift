import Foundation

/// A condition Noria Watch may notify about.
public enum WatchAlert: Sendable, Equatable {
    /// Free space fell below the user's threshold.
    case lowSpace(available: Int64)
    /// Free space dropped by at least the threshold within the last hour.
    case spaceDropped(by: Int64, available: Int64)
    /// CPU stayed above the threshold for the whole window.
    case sustainedHighCPU(average: Double, minutes: Int)

    var key: String {
        switch self {
        case .lowSpace: return "lowSpace"
        case .spaceDropped: return "spaceDropped"
        case .sustainedHighCPU: return "highCPU"
        }
    }
}

/// What the user enabled. `nil` disables a rule.
public struct WatchConfiguration: Sendable, Equatable {
    public var lowSpaceBytes: Int64?
    public var spaceDropBytes: Int64?
    /// Fraction of total CPU (0…1).
    public var highCPUThreshold: Double?
    public var highCPUDuration: TimeInterval

    public init(lowSpaceBytes: Int64? = nil, spaceDropBytes: Int64? = nil, highCPUThreshold: Double? = nil, highCPUDuration: TimeInterval = 300) {
        self.lowSpaceBytes = lowSpaceBytes
        self.spaceDropBytes = spaceDropBytes
        self.highCPUThreshold = highCPUThreshold
        self.highCPUDuration = highCPUDuration
    }

    public init(settings: NoriaSettings) {
        self.init(
            lowSpaceBytes: settings.notifyLowSpace ? Int64(settings.lowSpaceThresholdGB) * 1_000_000_000 : nil,
            spaceDropBytes: settings.notifySpaceDrop ? Int64(settings.spaceDropThresholdGB) * 1_000_000_000 : nil,
            highCPUThreshold: settings.notifyHighCPU ? 0.85 : nil
        )
    }

    public var isEmpty: Bool { lowSpaceBytes == nil && spaceDropBytes == nil && highCPUThreshold == nil }
}

/// Turns periodic readings into rare, meaningful alerts.
///
/// Every alert has a cooldown so the user is never nagged, and CPU alerts need a
/// sustained condition, not a spike. Pure value type: deterministic and testable.
public struct WatchEvaluator: Sendable {
    public var configuration: WatchConfiguration
    public static let cooldowns: [String: TimeInterval] = ["lowSpace": 6 * 3600, "spaceDropped": 3 * 3600, "highCPU": 3600]
    static let dropWindow: TimeInterval = 3600

    private var lastAlert: [String: Date] = [:]
    private var spaceSamples: [(Date, Int64)] = []
    private var cpuSamples: [(Date, Double)] = []

    public init(configuration: WatchConfiguration) {
        self.configuration = configuration
    }

    /// Feeds one reading; returns the alerts to deliver now.
    public mutating func ingest(date: Date, availableBytes: Int64?, cpu: Double?) -> [WatchAlert] {
        var alerts: [WatchAlert] = []
        if let available = availableBytes {
            spaceSamples.append((date, available))
            spaceSamples.removeAll { date.timeIntervalSince($0.0) > Self.dropWindow }
            if let threshold = configuration.lowSpaceBytes, available < threshold {
                alerts.append(.lowSpace(available: available))
            }
            if let threshold = configuration.spaceDropBytes, let peak = spaceSamples.map(\.1).max(), peak - available >= threshold {
                alerts.append(.spaceDropped(by: peak - available, available: available))
            }
        }
        if let cpu {
            cpuSamples.append((date, cpu))
            let window = configuration.highCPUDuration
            cpuSamples.removeAll { date.timeIntervalSince($0.0) > window }
            if let threshold = configuration.highCPUThreshold, let first = cpuSamples.first,
               date.timeIntervalSince(first.0) >= window * 0.9, cpuSamples.allSatisfy({ $0.1 >= threshold }) {
                let average = cpuSamples.reduce(0) { $0 + $1.1 } / Double(cpuSamples.count)
                alerts.append(.sustainedHighCPU(average: average, minutes: Int((window / 60).rounded())))
            }
        }
        return alerts.filter { alert in
            if let last = lastAlert[alert.key], date.timeIntervalSince(last) < (Self.cooldowns[alert.key] ?? 3600) { return false }
            lastAlert[alert.key] = date
            return true
        }
    }
}
