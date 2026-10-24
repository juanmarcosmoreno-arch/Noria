import Foundation

/// An item held in Noria's quarantine.
public struct QuarantineEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    /// Where the item lived before it was quarantined.
    public var originalPath: String
    public var name: String
    public var quarantinedAt: Date
    public var allocatedSize: Int64
    public var category: CleanCategory
    /// File name of the item inside its entry folder.
    public var storedName: String

    public func expiresAt(retentionDays: Int) -> Date {
        quarantinedAt.addingTimeInterval(TimeInterval(max(1, retentionDays)) * 86_400)
    }
}

public enum QuarantineError: Error, Equatable, CustomStringConvertible {
    /// Something already exists at the original location.
    case destinationExists(String)
    case missingPayload(String)

    public var description: String {
        switch self {
        case .destinationExists(let path): return "Something already exists at \(path)"
        case .missingPayload(let path): return "The quarantined item is missing: \(path)"
        }
    }
}

/// Noria-managed quarantine.
///
/// Each item is moved into `<root>/<uuid>/` next to an `entry.json` describing
/// where it came from, so it can be restored exactly. On the same volume the move
/// is an instant rename, which also means **no space is freed until the entry is
/// deleted** (manually or when the retention period ends).
public struct QuarantineStore: Sendable {
    public let root: String

    public init(root: String) {
        self.root = root
    }

    /// `~/Library/Application Support/Noria/Quarantine` (inside the container when sandboxed).
    public static func defaultRoot() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Noria/Quarantine", isDirectory: true).path
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Default date strategy (seconds since 2001 as a Double) round-trips exactly.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    private func folder(for id: UUID) -> String {
        (root as NSString).appendingPathComponent(id.uuidString)
    }

    private func payloadPath(for entry: QuarantineEntry) -> String {
        (folder(for: entry.id) as NSString).appendingPathComponent(entry.storedName)
    }

    /// Moves `item` into the quarantine.
    @discardableResult
    public func quarantine(_ item: ScanItem, now: Date = Date()) throws -> QuarantineEntry {
        let entry = QuarantineEntry(id: UUID(), originalPath: item.path, name: item.name, quarantinedAt: now,
                                    allocatedSize: item.allocatedSize, category: item.category,
                                    storedName: (item.path as NSString).lastPathComponent)
        let entryFolder = folder(for: entry.id)
        let manager = FileManager.default
        try manager.createDirectory(atPath: entryFolder, withIntermediateDirectories: true)
        do {
            try manager.moveItem(atPath: item.path, toPath: payloadPath(for: entry))
        } catch {
            try? manager.removeItem(atPath: entryFolder)
            throw error
        }
        // The metadata is written after the move: an entry without metadata is
        // still listed (as "unknown origin") rather than silently lost.
        try Self.encoder.encode(entry).write(to: URL(fileURLWithPath: (entryFolder as NSString).appendingPathComponent("entry.json")))
        return entry
    }

    /// All entries, newest first.
    public func entries() -> [QuarantineEntry] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return names.compactMap { name -> QuarantineEntry? in
            let metadata = ((root as NSString).appendingPathComponent(name) as NSString).appendingPathComponent("entry.json")
            guard let data = FileManager.default.contents(atPath: metadata) else { return nil }
            return try? Self.decoder.decode(QuarantineEntry.self, from: data)
        }
        .sorted { $0.quarantinedAt > $1.quarantinedAt }
    }

    /// Bytes currently held in the quarantine.
    public func totalSize() -> Int64 {
        entries().reduce(0) { $0 + $1.allocatedSize }
    }

    /// Moves the item back. Refuses to overwrite anything at the destination.
    public func restore(_ entry: QuarantineEntry, to destination: String? = nil) throws {
        let target = destination ?? entry.originalPath
        let manager = FileManager.default
        let payload = payloadPath(for: entry)
        guard FileSystem.stat(payload) != nil else { throw QuarantineError.missingPayload(payload) }
        guard FileSystem.stat(target) == nil else { throw QuarantineError.destinationExists(target) }
        try manager.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try manager.moveItem(atPath: payload, toPath: target)
        try manager.removeItem(atPath: folder(for: entry.id))
    }

    /// Deletes the entry for good.
    public func delete(_ entry: QuarantineEntry) throws {
        try FileManager.default.removeItem(atPath: folder(for: entry.id))
    }

    /// Deletes entries older than the retention period. Returns what was deleted.
    @discardableResult
    public func purgeExpired(retentionDays: Int, now: Date = Date()) -> [QuarantineEntry] {
        entries().filter { $0.expiresAt(retentionDays: retentionDays) <= now }.filter { (try? delete($0)) != nil }
    }
}

/// Removes items by moving them into the quarantine.
public struct QuarantineRemover: FileRemoving {
    public let method = RemovalMethod.quarantine
    public var store: QuarantineStore

    public init(store: QuarantineStore) {
        self.store = store
    }

    public func remove(_ item: ScanItem) throws {
        try store.quarantine(item)
    }
}
