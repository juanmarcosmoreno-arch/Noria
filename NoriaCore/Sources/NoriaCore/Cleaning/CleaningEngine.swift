import Foundation

/// Removes a single node. Implementations must not follow symbolic links.
public protocol FileRemoving: Sendable {
    var method: RemovalMethod { get }
    func remove(path: String) throws
}

#if os(macOS)
/// Moves items to the user's Trash through `FileManager.trashItem`, the same
/// mechanism Finder uses, so the user can put them back.
public struct TrashRemover: FileRemoving {
    public let method = RemovalMethod.moveToTrash
    public init() {}

    public func remove(path: String) throws {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }
}
#endif

/// Deletes items immediately. Only used when the user explicitly chooses it.
public struct PermanentRemover: FileRemoving {
    public let method = RemovalMethod.deletePermanently
    public init() {}

    public func remove(path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }
}

/// Moves items into a directory. Used by tests (and the basis of Phase 2 quarantine).
public struct MoveToDirectoryRemover: FileRemoving {
    public let method = RemovalMethod.moveToTrash
    public var destination: String

    public init(destination: String) {
        self.destination = destination
    }

    public func remove(path: String) throws {
        let name = UUID().uuidString + "-" + (path as NSString).lastPathComponent
        try FileManager.default.moveItem(atPath: path, toPath: (destination as NSString).appendingPathComponent(name))
    }
}

public enum Removers {
    /// The remover for a method on this platform.
    public static func remover(for method: RemovalMethod) throws -> any FileRemoving {
        switch method {
        case .deletePermanently:
            return PermanentRemover()
        case .moveToTrash:
            #if os(macOS)
            return TrashRemover()
            #else
            throw NoriaError.unsupported("Moving to Trash is only available on macOS")
            #endif
        }
    }
}

/// Outcome for one item.
public struct ItemOutcome: Sendable, Codable, Identifiable {
    public enum Status: String, Sendable, Codable {
        case removed
        case skipped
        case failed
    }

    public var id: UUID { itemID }
    public var itemID: UUID
    public var path: String
    public var allocatedSize: Int64
    public var status: Status
    public var message: String?
}

/// Result of a cleanup. Distinguishes what was removed from what was actually freed.
public struct CleanupReport: Sendable, Codable {
    public var startedAt: Date
    public var finishedAt: Date
    public var method: RemovalMethod
    public var outcomes: [ItemOutcome]
    public var wasCancelled: Bool
    /// Free space on the volume before and after (raw available bytes, not including purgeable).
    public var volumeAvailableBefore: Int64?
    public var volumeAvailableAfter: Int64?

    public var removed: [ItemOutcome] { outcomes.filter { $0.status == .removed } }
    public var failed: [ItemOutcome] { outcomes.filter { $0.status != .removed } }
    /// Bytes of the removed items as measured during the scan.
    public var removedSize: Int64 { removed.reduce(0) { $0 + $1.allocatedSize } }

    /// Bytes now sitting in the Trash: not freed until the Trash is emptied.
    public var movedToTrashSize: Int64 { method == .moveToTrash ? removedSize : 0 }

    /// Measured change in free space. May differ from `removedSize` because other
    /// processes write to disk and APFS may share blocks between clones/snapshots.
    public var measuredFreedSize: Int64? {
        guard let before = volumeAvailableBefore, let after = volumeAvailableAfter else { return nil }
        return after - before
    }
}

/// Requests that a running cleanup stop after the current item, while still
/// delivering the final report (unlike cancelling the consuming task).
public final class CleanupCancellation: @unchecked Sendable {
    private var cancelled = false
    private let lock = NSLock()

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

public enum CleanupEvent: Sendable {
    case itemStarted(ScanItem, index: Int, total: Int)
    case itemFinished(ItemOutcome)
    case finished(CleanupReport)
}

/// Executes a user-confirmed cleanup.
///
/// Each item is re-validated against the safety policy immediately before it is
/// touched. Items are processed one by one so the operation can be cancelled
/// between items; an item already being moved is always completed atomically.
public struct CleaningEngine: Sendable {
    public var policy: SafetyPolicy
    public var remover: any FileRemoving
    public var volumeInfo: any VolumeInfoProviding

    public init(policy: SafetyPolicy, remover: any FileRemoving, volumeInfo: any VolumeInfoProviding = VolumeInfoProvider()) {
        self.policy = policy
        self.remover = remover
        self.volumeInfo = volumeInfo
    }

    public func clean(_ items: [ScanItem], cancellation: CleanupCancellation = CleanupCancellation()) -> AsyncStream<CleanupEvent> {
        let policy = self.policy
        let remover = self.remover
        let volumeInfo = self.volumeInfo
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let start = Date()
                let volumePath = policy.locations.home
                let before = try? volumeInfo.volumeInfo(for: volumePath).availableCapacity
                var outcomes: [ItemOutcome] = []
                var cancelled = false
                // Children before parents is irrelevant (overlaps were removed at scan time),
                // but process deepest paths first defensively.
                let ordered = items.sorted { $0.path.count > $1.path.count }
                for (index, item) in ordered.enumerated() {
                    if Task.isCancelled || cancellation.isCancelled {
                        cancelled = true
                        break
                    }
                    continuation.yield(.itemStarted(item, index: index, total: ordered.count))
                    let outcome = Self.process(item, policy: policy, remover: remover)
                    outcomes.append(outcome)
                    continuation.yield(.itemFinished(outcome))
                }
                if cancelled {
                    for item in ordered where !outcomes.contains(where: { $0.itemID == item.id }) {
                        outcomes.append(ItemOutcome(itemID: item.id, path: item.path, allocatedSize: item.allocatedSize, status: .skipped, message: "Cancelled"))
                    }
                }
                let after = try? volumeInfo.volumeInfo(for: volumePath).availableCapacity
                let report = CleanupReport(startedAt: start, finishedAt: Date(), method: remover.method, outcomes: outcomes,
                                           wasCancelled: cancelled, volumeAvailableBefore: before, volumeAvailableAfter: after)
                continuation.yield(.finished(report))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func process(_ item: ScanItem, policy: SafetyPolicy, remover: any FileRemoving) -> ItemOutcome {
        switch policy.validateForRemoval(item) {
        case .failure(let error):
            let status: ItemOutcome.Status
            if case .blocked = error { status = .skipped } else if case .changedSinceScan = error { status = .skipped } else { status = .failed }
            return ItemOutcome(itemID: item.id, path: item.path, allocatedSize: item.allocatedSize, status: status, message: error.description)
        case .success:
            do {
                try remover.remove(path: item.path)
                return ItemOutcome(itemID: item.id, path: item.path, allocatedSize: item.allocatedSize, status: .removed, message: nil)
            } catch {
                return ItemOutcome(itemID: item.id, path: item.path, allocatedSize: item.allocatedSize, status: .failed,
                                   message: (error as NSError).localizedDescription)
            }
        }
    }
}
