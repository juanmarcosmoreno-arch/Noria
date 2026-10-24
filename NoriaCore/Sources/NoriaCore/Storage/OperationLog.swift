import Foundation

/// A persisted entry of the operation log (History).
public struct OperationRecord: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case smartScan
        case largeFileScan
        case cleanup
        /// Items moved back from the quarantine.
        case restore
        /// Quarantined items deleted for good (manually or after the retention period).
        case quarantineDeletion
    }

    public struct Failure: Codable, Sendable, Equatable {
        public var path: String
        public var message: String
    }

    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var duration: TimeInterval
    /// Scan: bytes Noria could remove. Cleanup: unused.
    public var recoverableBytes: Int64?
    public var itemsFound: Int?
    /// Cleanup only.
    public var method: RemovalMethod?
    public var removedPaths: [String]
    public var removedBytes: Int64?
    public var measuredFreedBytes: Int64?
    public var failures: [Failure]
    public var wasCancelled: Bool

    public init(id: UUID = UUID(), date: Date, kind: Kind, duration: TimeInterval, recoverableBytes: Int64? = nil, itemsFound: Int? = nil,
                method: RemovalMethod? = nil, removedPaths: [String] = [], removedBytes: Int64? = nil,
                measuredFreedBytes: Int64? = nil, failures: [Failure] = [], wasCancelled: Bool = false) {
        self.id = id
        self.date = date
        self.kind = kind
        self.duration = duration
        self.recoverableBytes = recoverableBytes
        self.itemsFound = itemsFound
        self.method = method
        self.removedPaths = removedPaths
        self.removedBytes = removedBytes
        self.measuredFreedBytes = measuredFreedBytes
        self.failures = failures
        self.wasCancelled = wasCancelled
    }

    public static func scan(_ report: ScanReport) -> OperationRecord {
        OperationRecord(date: report.finishedAt, kind: .smartScan, duration: report.finishedAt.timeIntervalSince(report.startedAt),
                        recoverableBytes: report.recoverableSize, itemsFound: report.allItems.count)
    }

    public static func largeFileScan(_ report: LargeFileReport) -> OperationRecord {
        OperationRecord(date: Date(), kind: .largeFileScan, duration: report.duration,
                        recoverableBytes: report.files.reduce(0) { $0 + $1.allocatedSize }, itemsFound: report.files.count)
    }

    public static func restore(_ entries: [QuarantineEntry], failures: [Failure] = []) -> OperationRecord {
        OperationRecord(date: Date(), kind: .restore, duration: 0, removedPaths: entries.map(\.originalPath),
                        removedBytes: entries.reduce(0) { $0 + $1.allocatedSize }, failures: failures)
    }

    public static func quarantineDeletion(_ entries: [QuarantineEntry]) -> OperationRecord {
        OperationRecord(date: Date(), kind: .quarantineDeletion, duration: 0, removedPaths: entries.map(\.originalPath),
                        removedBytes: entries.reduce(0) { $0 + $1.allocatedSize })
    }

    public static func cleanup(_ report: CleanupReport) -> OperationRecord {
        OperationRecord(date: report.finishedAt, kind: .cleanup, duration: report.finishedAt.timeIntervalSince(report.startedAt),
                        method: report.method, removedPaths: report.removed.map(\.path), removedBytes: report.removedSize,
                        measuredFreedBytes: report.method == .deletePermanently ? report.measuredFreedSize : nil,
                        failures: report.failed.map { Failure(path: $0.path, message: $0.message ?? "") },
                        wasCancelled: report.wasCancelled)
    }
}

/// Append-only JSON Lines log stored locally. One line per record, so a crash
/// mid-write can corrupt at most the last line, which is ignored on read.
public actor OperationLog {
    public nonisolated let fileURL: URL
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/Noria/operations.jsonl`.
    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Noria", isDirectory: true).appendingPathComponent("operations.jsonl")
    }

    public func append(_ record: OperationRecord) throws {
        var data = try encoder.encode(record)
        data.append(0x0A)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: fileURL, options: .atomic)
        }
    }

    /// All records, newest first.
    public func records() throws -> [OperationRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(OperationRecord.self, from: Data($0)) }
            .sorted { $0.date > $1.date }
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
