import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Cumulative CPU time and memory of one process at a moment.
public struct ProcessSample: Sendable, Hashable {
    public var pid: Int32
    public var name: String
    /// User + system CPU time, in nanoseconds.
    public var cpuTime: UInt64
    /// Resident memory in bytes.
    public var residentMemory: UInt64
}

/// A process with its CPU share over the sampling interval.
public struct ProcessUsage: Sendable, Identifiable, Hashable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var name: String
    /// Share of one core (1.0 = one core fully busy), like Activity Monitor's "% CPU" / 100.
    public var cpu: Double
    public var residentMemory: UInt64
}

/// Lists processes through the public libproc interface. macOS only returns details
/// for processes Noria is allowed to inspect (usually the user's own); the others
/// are skipped rather than estimated.
public enum ProcessMonitor {
    public static func sample() -> [ProcessSample] {
        #if os(macOS)
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard count > 0 else { return [] }
        var result: [ProcessSample] = []
        result.reserveCapacity(Int(count))
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }
            var nameBuffer = [CChar](repeating: 0, count: 256)
            proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            let nameBytes = nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            result.append(ProcessSample(pid: pid, name: String(decoding: nameBytes, as: UTF8.self),
                                        cpuTime: info.pti_total_user &+ info.pti_total_system,
                                        residentMemory: info.pti_resident_size))
        }
        return result
        #else
        return []
        #endif
    }

    /// Converts two samples into per-process CPU usage. `timebase` converts
    /// `cpuTime` units to nanoseconds (Mach absolute time on Apple Silicon).
    public static func usage(from earlier: [ProcessSample], to later: [ProcessSample],
                             interval: TimeInterval, timebase: Double = ProcessMonitor.timebase) -> [ProcessUsage] {
        guard interval > 0 else { return [] }
        let previous = Dictionary(earlier.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        return later.compactMap { current in
            guard let before = previous[current.pid], current.cpuTime >= before.cpuTime else { return nil }
            let seconds = Double(current.cpuTime - before.cpuTime) * timebase / 1e9
            return ProcessUsage(pid: current.pid, name: current.name, cpu: seconds / interval,
                                residentMemory: current.residentMemory)
        }
    }

    /// Nanoseconds per unit of `pti_total_user`/`pti_total_system`.
    public static let timebase: Double = {
        #if os(macOS)
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return 1 }
        return Double(info.numer) / Double(info.denom)
        #else
        return 1
        #endif
    }()
}
