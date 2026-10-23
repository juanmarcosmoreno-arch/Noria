import Foundation
@testable import NoriaCore

/// A disposable fake home directory. All destructive tests run inside it.
final class Sandbox {
    let root: String
    let home: String
    let temporary: String

    init() throws {
        let base = FileSystem.bestEffortCanonicalPath(NSTemporaryDirectory())
        root = (base as NSString).appendingPathComponent("noria-tests-\(UUID().uuidString)")
        home = (root as NSString).appendingPathComponent("home")
        temporary = (root as NSString).appendingPathComponent("tmp")
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: temporary, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    var locations: SystemLocations { SystemLocations(home: home, temporary: temporary) }

    func path(_ relative: String) -> String {
        (home as NSString).appendingPathComponent(relative)
    }

    /// Writes `bytes` of non-zero data (so file systems allocate real blocks).
    @discardableResult
    func file(_ relative: String, bytes: Int, ageDays: Double = 0, inTemporary: Bool = false) throws -> String {
        let full = inTemporary ? (temporary as NSString).appendingPathComponent(relative) : path(relative)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: bytes).write(to: URL(fileURLWithPath: full))
        if ageDays > 0 { try setAge(full, days: ageDays) }
        return full
    }

    @discardableResult
    func directory(_ relative: String) throws -> String {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
        return full
    }

    func setAge(_ full: String, days: Double) throws {
        let date = Date().addingTimeInterval(-days * 86_400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: full)
    }

    func exists(_ full: String) -> Bool {
        FileSystem.stat(full) != nil
    }
}

func collect<T>(_ stream: AsyncThrowingStream<T, Error>) async throws -> [T] {
    var events: [T] = []
    for try await event in stream { events.append(event) }
    return events
}

func collect<T>(_ stream: AsyncStream<T>) async -> [T] {
    var events: [T] = []
    for await event in stream { events.append(event) }
    return events
}

struct FixedVolumeInfo: VolumeInfoProviding {
    func volumeInfo(for path: String) throws -> VolumeInfo {
        VolumeInfo(name: "Test", mountPath: "/", formatDescription: nil, totalCapacity: 100, availableCapacity: 50, availableForImportantUsage: 60)
    }
}
