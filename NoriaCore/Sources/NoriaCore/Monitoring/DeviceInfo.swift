import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Basic hardware and OS facts read from public APIs (`sysctl`, `ProcessInfo`).
/// Values that are unavailable stay `nil`; nothing is estimated.
public struct DeviceInfo: Sendable, Equatable {
    /// Model identifier such as `Mac15,3`.
    public var modelIdentifier: String?
    public var processor: String?
    public var architecture: String
    public var physicalMemory: UInt64
    public var processorCount: Int
    public var osVersion: String
    /// Local host name. Read with `gethostname`: `ProcessInfo.hostName` may do a
    /// reverse DNS lookup and block for a long time on some networks.
    public var hostName: String

    public static func current() -> DeviceInfo {
        let process = ProcessInfo.processInfo
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        return DeviceInfo(
            modelIdentifier: sysctlString("hw.model"),
            processor: sysctlString("machdep.cpu.brand_string"),
            architecture: architecture,
            physicalMemory: process.physicalMemory,
            processorCount: process.processorCount,
            osVersion: process.operatingSystemVersionString,
            hostName: localHostName()
        )
    }

    static func localHostName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func sysctlString(_ name: String) -> String? {
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let value = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
        #else
        return nil
        #endif
    }
}
