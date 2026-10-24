import Foundation
#if canImport(IOKit)
import IOKit
import IOKit.ps
#endif

/// Battery facts read from macOS. Every field is optional: Macs without a battery,
/// or values macOS does not publish, stay `nil` — nothing is estimated.
public struct BatteryInfo: Sendable, Equatable {
    public var cycleCount: Int?
    public var designCapacity: Int?
    /// Full-charge capacity now, in mAh.
    public var fullChargeCapacity: Int?
    /// Current charge, 0…100.
    public var chargePercent: Int?
    public var isCharging: Bool?
    public var isPluggedIn: Bool?
    /// macOS's own assessment ("Good", "Fair", "Poor", "Check Battery"…), when published.
    public var condition: String?
    public var temperatureCelsius: Double?
    public var minutesRemaining: Int?

    /// Full-charge capacity relative to the design capacity (0…1+).
    public var maximumCapacity: Double? {
        guard let full = fullChargeCapacity, let design = designCapacity, design > 0 else { return nil }
        return Double(full) / Double(design)
    }

    /// Builds the info from the `AppleSmartBattery` registry properties and the
    /// power-source description. Pure, so it can be tested with fixture dictionaries.
    public static func from(registry: [String: Any], powerSource: [String: Any]) -> BatteryInfo? {
        guard !registry.isEmpty || !powerSource.isEmpty else { return nil }
        func int(_ value: Any?) -> Int? {
            if let number = value as? NSNumber { return number.intValue }
            return value as? Int
        }
        var info = BatteryInfo()
        info.cycleCount = int(registry["CycleCount"])
        info.designCapacity = int(registry["DesignCapacity"])
        // On Apple Silicon "MaxCapacity" is a percentage; the raw mAh value has its own key.
        let candidates = [registry["AppleRawMaxCapacity"], registry["NominalChargeCapacity"], registry["MaxCapacity"]]
        info.fullChargeCapacity = candidates.compactMap(int).first { $0 > 200 }
        info.chargePercent = int(powerSource["Current Capacity"])
        info.isCharging = powerSource["Is Charging"] as? Bool ?? (registry["IsCharging"] as? Bool)
        info.isPluggedIn = (powerSource["Power Source State"] as? String).map { $0 == "AC Power" } ?? (registry["ExternalConnected"] as? Bool)
        info.condition = powerSource["BatteryHealth"] as? String
        if let raw = int(registry["Temperature"]), raw > 0 { info.temperatureCelsius = Double(raw) / 100 }
        if let minutes = int(powerSource["Time to Empty"]), minutes > 0, info.isCharging != true { info.minutesRemaining = minutes }
        return info
    }

    /// Reads the battery of this Mac. `nil` on Macs without a battery.
    public static func current() -> BatteryInfo? {
        #if canImport(IOKit)
        var registry: [String: Any] = [:]
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dictionary = properties?.takeRetainedValue() as? [String: Any] {
                registry = dictionary
            }
            IOObjectRelease(service)
        }
        var source: [String: Any] = [:]
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for item in list {
                if let description = IOPSGetPowerSourceDescription(blob, item)?.takeUnretainedValue() as? [String: Any],
                   (description["Type"] as? String) == "InternalBattery" {
                    source = description
                }
            }
        }
        guard service != 0 || !source.isEmpty else { return nil }
        return from(registry: registry, powerSource: source)
        #else
        return nil
        #endif
    }
}

/// Cumulative bytes read and written by internal and external disks since boot.
public struct DiskCounters: Sendable, Equatable {
    public var bytesRead: UInt64
    public var bytesWritten: UInt64

    /// Bytes per second between two readings.
    public func rates(since earlier: DiskCounters, interval: TimeInterval) -> (read: Double, write: Double)? {
        guard interval > 0, bytesRead >= earlier.bytesRead, bytesWritten >= earlier.bytesWritten else { return nil }
        return (Double(bytesRead - earlier.bytesRead) / interval, Double(bytesWritten - earlier.bytesWritten) / interval)
    }

    /// Sums the statistics of every `IOBlockStorageDriver`.
    public static func current() -> DiskCounters? {
        #if canImport(IOKit)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0
        var written: UInt64 = 0
        var found = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let value = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let statistics = value as? [String: Any] else { continue }
            found = true
            read &+= (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            written &+= (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return found ? DiskCounters(bytesRead: read, bytesWritten: written) : nil
        #else
        return nil
        #endif
    }
}

/// What macOS says about the startup disk's hardware. Health data (SMART) is only
/// reported when the system exposes it; Noria never guesses it.
public struct StorageDeviceInfo: Sendable, Equatable {
    public var model: String?
    public var isSolidState: Bool?
    public var isInternal: Bool?
    public var protocolName: String?
    /// "Verified", "Failing"… as published by the storage driver, or `nil`.
    public var smartStatus: String?

    public init(model: String? = nil, isSolidState: Bool? = nil, isInternal: Bool? = nil, protocolName: String? = nil, smartStatus: String? = nil) {
        self.model = model
        self.isSolidState = isSolidState
        self.isInternal = isInternal
        self.protocolName = protocolName
        self.smartStatus = smartStatus
    }

    public static func forStartupDisk() -> StorageDeviceInfo {
        #if canImport(IOKit)
        var info = StorageDeviceInfo()
        // The first internal storage device that publishes a characteristics dictionary.
        for className in ["IONVMeController", "IOAHCIBlockStorageDevice", "AppleANS3NVMeController", "IOBlockStorageDevice"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                if let value = IORegistryEntryCreateCFProperty(service, "Device Characteristics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                   let characteristics = value as? [String: Any] {
                    info.model = info.model ?? (characteristics["Product Name"] as? String)?.trimmingCharacters(in: .whitespaces)
                    if let medium = characteristics["Medium Type"] as? String { info.isSolidState = medium.contains("Solid State") }
                }
                if let value = IORegistryEntryCreateCFProperty(service, "Protocol Characteristics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                   let characteristics = value as? [String: Any] {
                    info.protocolName = info.protocolName ?? (characteristics["Physical Interconnect"] as? String)
                    if let location = characteristics["Physical Interconnect Location"] as? String { info.isInternal = location == "Internal" }
                }
                if let status = IORegistryEntryCreateCFProperty(service, "SMART Status" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                    info.smartStatus = status
                }
                if info.model != nil { return info }
            }
        }
        return info
        #else
        return StorageDeviceInfo()
        #endif
    }
}
