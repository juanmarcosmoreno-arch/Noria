import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Capacity figures for the volume containing a path. All values come from the OS.
public struct VolumeInfo: Sendable, Equatable {
    public var name: String
    public var mountPath: String
    public var formatDescription: String?
    public var totalCapacity: Int64
    /// Free bytes right now.
    public var availableCapacity: Int64
    /// Free bytes including space macOS can purge on demand (what Finder shows as "Available").
    /// Equal to `availableCapacity` when the OS does not provide it.
    public var availableForImportantUsage: Int64

    public var usedCapacity: Int64 { max(0, totalCapacity - availableForImportantUsage) }
    public var purgeableCapacity: Int64 { max(0, availableForImportantUsage - availableCapacity) }

    public var usedFraction: Double {
        totalCapacity > 0 ? Double(usedCapacity) / Double(totalCapacity) : 0
    }

    public init(name: String, mountPath: String, formatDescription: String?, totalCapacity: Int64, availableCapacity: Int64, availableForImportantUsage: Int64) {
        self.name = name
        self.mountPath = mountPath
        self.formatDescription = formatDescription
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
        self.availableForImportantUsage = availableForImportantUsage
    }
}

public protocol VolumeInfoProviding: Sendable {
    func volumeInfo(for path: String) throws -> VolumeInfo
}

public struct VolumeInfoProvider: VolumeInfoProviding {
    public init() {}

    public func volumeInfo(for path: String) throws -> VolumeInfo {
        #if os(macOS)
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeURLKey, .volumeLocalizedFormatDescriptionKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]
        let values = try url.resourceValues(forKeys: keys)
        guard let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity else {
            throw NoriaError.unsupported("Volume capacity unavailable for \(path)")
        }
        let important = values.volumeAvailableCapacityForImportantUsage ?? Int64(available)
        return VolumeInfo(
            name: values.volumeName ?? "",
            mountPath: values.volume?.path ?? "/",
            formatDescription: values.volumeLocalizedFormatDescription,
            totalCapacity: Int64(total),
            availableCapacity: Int64(available),
            availableForImportantUsage: max(important, Int64(available))
        )
        #else
        var info = statvfs()
        guard statvfs(path, &info) == 0 else { throw NoriaError.fromErrno(errno, path: path) }
        let blockSize = Int64(info.f_frsize)
        let total = Int64(info.f_blocks) * blockSize
        let available = Int64(info.f_bavail) * blockSize
        return VolumeInfo(name: "", mountPath: "/", formatDescription: nil, totalCapacity: total,
                          availableCapacity: available, availableForImportantUsage: available)
        #endif
    }
}
