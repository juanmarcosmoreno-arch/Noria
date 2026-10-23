import Foundation

/// Keeps track of hard-linked files already counted during one scan so the same
/// data is never counted twice. Only nodes with more than one link are stored,
/// which keeps memory proportional to the (usually tiny) number of hard links.
public final class InodeTracker: @unchecked Sendable {
    private var seen = Set<FileIdentity>()
    private let lock = NSLock()

    public init() {}

    /// Returns `true` the first time a node is seen.
    public func firstVisit(_ stat: FileStat) -> Bool {
        guard stat.linkCount > 1, stat.type == .file else { return true }
        lock.lock()
        defer { lock.unlock() }
        return seen.insert(stat.identity).inserted
    }
}

/// Options controlling a recursive walk.
public struct WalkOptions: Sendable {
    /// Do not descend into other mounted volumes.
    public var staysOnDevice = true
    /// Descend into bundles such as `.app` or `.photoslibrary`.
    public var descendsIntoPackages = true
    /// Canonical paths that are skipped entirely (neither visited nor descended into).
    public var skippedPaths: [String] = []
    /// Maximum number of inaccessible paths remembered (the count is always exact).
    public var maxRecordedErrors = 50

    public init() {}
}

/// What the visitor wants the walker to do after a node.
public enum WalkDecision: Sendable {
    case `continue`
    case skipDescendants
}

/// Summary of a walk.
public struct WalkSummary: Sendable {
    public var filesVisited = 0
    public var directoriesVisited = 0
    public var allocatedSize: Int64 = 0
    public var fileCount = 0
    public var newestModification: Date?
    public var inaccessibleCount = 0
    public var inaccessiblePaths: [String] = []
}

/// Synchronous, iterative (no recursion), non-following file-system walker.
///
/// It never follows symbolic links, checks `Task.isCancelled` regularly and
/// records unreadable directories instead of failing. Run it from a background task.
public struct FileWalker: Sendable {
    public static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "xpc", "appex", "photoslibrary",
        "musiclibrary", "tvlibrary", "photolibrary", "fcpbundle", "logicx", "band",
        "sparsebundle", "xcarchive", "pages", "numbers", "key", "rtfd", "playground", "xcodeproj",
        "xcworkspace", "lpdf", "imovielibrary", "dSYM",
    ]

    public static func isPackage(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty else { return false }
        return packageExtensions.contains(ext) || packageExtensions.contains(ext.lowercased())
    }

    public var options: WalkOptions

    public init(options: WalkOptions = WalkOptions()) {
        self.options = options
    }

    /// Walks the tree rooted at `root`. The visitor is called for every node
    /// (including the root) with its path and `lstat` data.
    @discardableResult
    public func walk(
        root: String,
        tracker: InodeTracker? = nil,
        visitor: (String, FileStat) throws -> WalkDecision
    ) throws -> WalkSummary {
        var summary = WalkSummary()
        guard let rootStat = FileSystem.stat(root) else {
            throw NoriaError.notFound(path: root)
        }
        var stack: [(String, FileStat)] = [(root, rootStat)]
        var sinceCancellationCheck = 0

        while let (path, stat) = stack.popLast() {
            sinceCancellationCheck += 1
            if sinceCancellationCheck >= 256 {
                sinceCancellationCheck = 0
                if Task.isCancelled { throw NoriaError.cancelled }
            }
            if options.skippedPaths.contains(where: { path.isSameOrDescendant(of: $0) }) { continue }

            let decision = try visitor(path, stat)

            switch stat.type {
            case .file:
                summary.filesVisited += 1
                if tracker?.firstVisit(stat) ?? true {
                    summary.allocatedSize += stat.allocatedSize
                    summary.fileCount += 1
                }
                if summary.newestModification.map({ stat.modificationDate > $0 }) ?? true {
                    summary.newestModification = stat.modificationDate
                }
            case .symlink, .other:
                // A symlink occupies (almost) nothing; its target is never followed.
                summary.allocatedSize += stat.allocatedSize
            case .directory:
                summary.directoriesVisited += 1
                summary.allocatedSize += stat.allocatedSize
                guard case .continue = decision else { continue }
                if options.staysOnDevice && stat.device != rootStat.device { continue }
                if !options.descendsIntoPackages && path != root && Self.isPackage(path) { continue }
                let entries: [DirectoryEntry]
                do {
                    entries = try FileSystem.directoryEntries(path)
                } catch {
                    summary.inaccessibleCount += 1
                    if summary.inaccessiblePaths.count < options.maxRecordedErrors {
                        summary.inaccessiblePaths.append(path)
                    }
                    continue
                }
                for entry in entries {
                    if let childStat = FileSystem.stat(entry.path) {
                        stack.append((entry.path, childStat))
                    }
                }
            }
        }
        return summary
    }
}

/// Measures folders. Progress is reported through `onProgress` at most every
/// `progressInterval` files so the UI is never flooded.
public struct DirectorySizer: Sendable {
    public var options: WalkOptions
    public var progressInterval = 500

    public init(options: WalkOptions = WalkOptions()) {
        self.options = options
    }

    public func measure(
        _ path: String,
        tracker: InodeTracker,
        onProgress: ((Int) -> Void)? = nil
    ) throws -> WalkSummary {
        var visited = 0
        return try FileWalker(options: options).walk(root: path, tracker: tracker) { _, stat in
            if stat.type == .file {
                visited += 1
                if visited % progressInterval == 0 { onProgress?(progressInterval) }
            }
            return .continue
        }
    }
}
