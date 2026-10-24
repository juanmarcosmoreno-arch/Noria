import Foundation

/// One file in a duplicate group.
public struct DuplicateFile: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public var path: String
    public var name: String { (path as NSString).lastPathComponent }
    public var modificationDate: Date
    public var fingerprint: FileStat

    public var parentPath: String { (path as NSString).deletingLastPathComponent }

    public func asScanItem(size: Int64) -> ScanItem {
        ScanItem(path: path, name: name, category: .duplicates, risk: .review, reason: .duplicateCopy,
                 allocatedSize: size, fileCount: 1, modificationDate: modificationDate, fingerprint: fingerprint)
    }
}

/// Files with byte-for-byte identical content (same size and SHA-256).
public struct DuplicateGroup: Identifiable, Sendable, Hashable {
    public var id: String { digest }
    public var digest: String
    /// Allocated size of one copy.
    public var size: Int64
    public var files: [DuplicateFile]
    public var kind: FileKind

    /// Space used by the extra copies.
    public var reclaimableSize: Int64 { size * Int64(max(0, files.count - 1)) }

    /// The copy a conservative automatic selection keeps: the oldest (most likely
    /// the original), preferring files outside Downloads, then the shortest path.
    public func suggestedKeeper(downloads: String) -> DuplicateFile? {
        files.min { lhs, rhs in
            let lhsDownload = lhs.path.isSameOrDescendant(of: downloads)
            let rhsDownload = rhs.path.isSameOrDescendant(of: downloads)
            if lhsDownload != rhsDownload { return !lhsDownload }
            if lhs.modificationDate != rhs.modificationDate { return lhs.modificationDate < rhs.modificationDate }
            return lhs.path.count < rhs.path.count
        }
    }
}

public enum DuplicateEvent: Sendable {
    /// `stage` is a short machine name: "walking", "comparing", "hashing".
    case progress(stage: String, filesVisited: Int, candidates: Int, hashed: Int)
    case finished(DuplicateReport)
}

public struct DuplicateReport: Sendable {
    public var root: String
    public var groups: [DuplicateGroup]
    public var filesVisited: Int
    public var inaccessibleCount: Int
    public var duration: TimeInterval

    public var reclaimableSize: Int64 { groups.reduce(0) { $0 + $1.reclaimableSize } }
}

/// Finds real duplicates:
/// 1. group regular files by size (hard links counted once — they share storage);
/// 2. drop groups whose head/tail digest differs;
/// 3. confirm with a full SHA-256.
///
/// It never descends into bundles or managed libraries (Photos, Music…), skips
/// `~/Library` (app data) and the Trash, and never reads symbolic-link targets.
public struct DuplicateFinder: Sendable {
    public var locations: SystemLocations
    public var minimumSize: Int64

    public init(locations: SystemLocations = .current, minimumSize: Int64 = 1_000_000) {
        self.locations = locations
        self.minimumSize = minimumSize
    }

    public func scan(root: String, settings: NoriaSettings) -> AsyncThrowingStream<DuplicateEvent, Error> {
        let locations = self.locations
        let minimumSize = max(1, self.minimumSize)
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let task = Task.detached(priority: .utility) {
                let start = Date()
                let canonicalRoot = FileSystem.bestEffortCanonicalPath(root)
                let policy = SafetyPolicy(locations: locations, exclusions: settings.exclusions)
                var options = WalkOptions()
                options.descendsIntoPackages = false
                options.skippedPaths = (policy.exclusions + [locations.library, locations.trash]).filter { $0 != canonicalRoot }

                var bySize: [Int64: [DuplicateFile]] = [:]
                var seenInodes = Set<FileIdentity>()
                var visited = 0
                var lastReport = Date.distantPast
                do {
                    let summary = try FileWalker(options: options).walk(root: canonicalRoot) { path, stat in
                        if stat.type == .directory, path != canonicalRoot, FileWalker.isPackage(path) {
                            return .skipDescendants
                        }
                        guard stat.type == .file else { return .continue }
                        visited += 1
                        guard stat.size >= minimumSize, policy.protectionReason(for: path) == nil else { return .continue }
                        // Hard links share their data: they are not duplicates.
                        if stat.linkCount > 1, !seenInodes.insert(stat.identity).inserted { return .continue }
                        bySize[stat.size, default: []].append(DuplicateFile(path: path, modificationDate: stat.modificationDate, fingerprint: stat))
                        if Date().timeIntervalSince(lastReport) > 0.2 {
                            lastReport = Date()
                            continuation.yield(.progress(stage: "walking", filesVisited: visited, candidates: 0, hashed: 0))
                        }
                        return .continue
                    }

                    let candidates = bySize.filter { $0.value.count > 1 }
                    let candidateCount = candidates.values.reduce(0) { $0 + $1.count }
                    var hashed = 0
                    var groups: [DuplicateGroup] = []
                    for (_, files) in candidates.sorted(by: { $0.key > $1.key }) {
                        if Task.isCancelled { throw CancellationError() }
                        let size = files[0].fingerprint.size
                        // Quick pass: head and tail.
                        var byPartial: [String: [DuplicateFile]] = [:]
                        for file in files {
                            guard let digest = try? FileHasher.partialDigest(path: file.path, size: size) else { continue }
                            byPartial[digest, default: []].append(file)
                        }
                        for sameEnds in byPartial.values where sameEnds.count > 1 {
                            var byFull: [String: [DuplicateFile]] = [:]
                            for file in sameEnds {
                                if Task.isCancelled { throw CancellationError() }
                                guard let digest = try? FileHasher.sha256(path: file.path) else { continue }
                                byFull[digest, default: []].append(file)
                                hashed += 1
                                continuation.yield(.progress(stage: "hashing", filesVisited: visited, candidates: candidateCount, hashed: hashed))
                            }
                            for (digest, identical) in byFull where identical.count > 1 {
                                groups.append(DuplicateGroup(digest: digest, size: identical[0].fingerprint.allocatedSize,
                                                             files: identical.sorted { $0.path < $1.path },
                                                             kind: FileKind.classify(identical[0].path)))
                            }
                        }
                    }
                    groups.sort { $0.reclaimableSize > $1.reclaimableSize }
                    continuation.yield(.finished(DuplicateReport(root: canonicalRoot, groups: groups, filesVisited: visited,
                                                                 inaccessibleCount: summary.inaccessibleCount,
                                                                 duration: Date().timeIntervalSince(start))))
                    continuation.finish()
                } catch NoriaError.cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Safety net for any selection: returns the selected paths that may be removed
    /// so that every group keeps at least one copy, and re-checks that a kept copy
    /// still exists with the same size. Selections that would remove every copy are
    /// trimmed (the suggested keeper is preserved).
    public static func safeRemovals(groups: [DuplicateGroup], selected: Set<String>, downloads: String) -> [DuplicateFile] {
        var result: [DuplicateFile] = []
        for group in groups {
            var chosen = group.files.filter { selected.contains($0.path) }
            if chosen.count == group.files.count, let keeper = group.suggestedKeeper(downloads: downloads) {
                chosen.removeAll { $0.path == keeper.path }
            }
            let kept = group.files.filter { file in !chosen.contains(where: { $0.path == file.path }) }
            let keptStillThere = kept.contains { FileSystem.stat($0.path)?.size == $0.fingerprint.size }
            if keptStillThere { result += chosen }
        }
        return result
    }
}
