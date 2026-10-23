import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Cumulative CPU ticks for all cores since boot. Usage is the change between two samples.
public struct CPUTicks: Sendable, Equatable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    /// Fraction of CPU time spent busy between `earlier` and `self` (0…1).
    /// `nil` when no time elapsed or the counters went backwards.
    public func usage(since earlier: CPUTicks) -> Double? {
        guard user >= earlier.user, system >= earlier.system, idle >= earlier.idle, nice >= earlier.nice else { return nil }
        let busy = (user - earlier.user) + (system - earlier.system) + (nice - earlier.nice)
        let total = busy + (idle - earlier.idle)
        guard total > 0 else { return nil }
        return Double(busy) / Double(total)
    }
}

/// macOS memory pressure level as reported by the kernel.
public enum MemoryPressure: String, Sendable {
    case normal, warning, critical
}

/// Physical memory figures. "Used" follows Activity Monitor: app memory + wired + compressed.
public struct MemorySnapshot: Sendable, Equatable {
    public var total: UInt64
    public var appMemory: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var swapUsed: UInt64?
    public var pressure: MemoryPressure?

    public var used: UInt64 { min(total, appMemory + wired + compressed) }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

/// Reads live system metrics through public Mach and `sysctl` interfaces.
/// Every call is cheap (a few syscalls); nothing runs in the background.
/// Returns `nil` where the platform does not provide the value.
public enum SystemMetrics {
    #if canImport(Darwin)
    /// Obtained once: every `mach_host_self()` call adds a send right to the port.
    private static let hostPort: mach_port_t = mach_host_self()
    #endif

    public static func cpuTicks() -> CPUTicks? {
        #if canImport(Darwin)
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // cpu_ticks is indexed by CPU_STATE_USER, CPU_STATE_SYSTEM, CPU_STATE_IDLE, CPU_STATE_NICE.
        return CPUTicks(user: UInt64(info.cpu_ticks.0), system: UInt64(info.cpu_ticks.1),
                        idle: UInt64(info.cpu_ticks.2), nice: UInt64(info.cpu_ticks.3))
        #else
        return nil
        #endif
    }

    public static func memory() -> MemorySnapshot? {
        #if canImport(Darwin)
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(getpagesize())
        let internalPages = UInt64(stats.internal_page_count)
        let purgeablePages = UInt64(stats.purgeable_count)
        return MemorySnapshot(
            total: ProcessInfo.processInfo.physicalMemory,
            appMemory: (internalPages > purgeablePages ? internalPages - purgeablePages : 0) * page,
            wired: UInt64(stats.wire_count) * page,
            compressed: UInt64(stats.compressor_page_count) * page,
            swapUsed: swapUsed(),
            pressure: pressure()
        )
        #else
        return nil
        #endif
    }

    static func swapUsed() -> UInt64? {
        #if canImport(Darwin)
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return usage.xsu_used
        #else
        return nil
        #endif
    }

    static func pressure() -> MemoryPressure? {
        #if canImport(Darwin)
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        switch level {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return nil
        }
        #else
        return nil
        #endif
    }
}
