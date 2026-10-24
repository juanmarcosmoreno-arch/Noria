import Foundation

/// A node of the Space Map tree.
public struct SpaceNode: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case directory
        /// A bundle (.app, .photoslibrary…) shown as one block.
        case package
        case file
        /// Small files and folders of a directory grouped into one block.
        case smallItems
    }

    public var id: String { kind == .smallItems ? path + "/…" : path }
    public var path: String
    public var name: String
    public var kind: Kind
    public var size: Int64
    public var fileCount: Int
    public var fileKind: FileKind
    public var modificationDate: Date?
    /// Children sorted by size, largest first. Empty for files and grouped items.
    public var children: [SpaceNode]
    /// Number of entries grouped in a `smallItems` node.
    public var groupedCount: Int

    public var isContainer: Bool { kind == .directory || kind == .package }

    /// Finds the node at `path` in this subtree.
    public func node(at path: String) -> SpaceNode? {
        if self.path == path && kind != .smallItems { return self }
        guard path.isStrictDescendant(of: self.path) else { return nil }
        for child in children where child.isContainer && path.isSameOrDescendant(of: child.path) {
            return child.node(at: path)
        }
        return nil
    }
}

public enum SpaceMapEvent: Sendable {
    case progress(filesVisited: Int, bytesVisited: Int64, currentFolder: String)
    case finished(SpaceMapReport)
}

public struct SpaceMapReport: Sendable {
    public var root: SpaceNode
    public var filesVisited: Int
    public var inaccessibleCount: Int
    public var duration: TimeInterval
}

/// Builds the Space Map tree for a folder.
///
/// Every byte is counted (hard links once, symlinks never followed, other volumes
/// skipped), but only items that are at least `minimumNodeFraction` of their
/// parent — and at least `minimumNodeSize` — are kept as separate nodes. The rest
/// of each folder becomes one "small items" block, which keeps memory bounded even
/// for millions of files.
public struct SpaceMapScanner: Sendable {
    public var minimumNodeSize: Int64
    public var minimumNodeFraction: Double

    public init(minimumNodeSize: Int64 = 1_000_000, minimumNodeFraction: Double = 0.002) {
        self.minimumNodeSize = minimumNodeSize
        self.minimumNodeFraction = minimumNodeFraction
    }

    public func scan(root: String, exclusions: [String] = []) -> AsyncThrowingStream<SpaceMapEvent, Error> {
        let scanner = self
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let task = Task.detached(priority: .utility) {
                let start = Date()
                let canonicalRoot = FileSystem.bestEffortCanonicalPath(root)
                guard let rootStat = FileSystem.stat(canonicalRoot), rootStat.type == .directory else {
                    continuation.finish(throwing: NoriaError.notFound(path: canonicalRoot))
                    return
                }
                var state = BuildState(device: rootStat.device, exclusions: exclusions.map { FileSystem.bestEffortCanonicalPath($0) }) { files, bytes, folder in
                    continuation.yield(.progress(filesVisited: files, bytesVisited: bytes, currentFolder: folder))
                }
                do {
                    let tree = try scanner.build(path: canonicalRoot, stat: rootStat, isPackage: false, state: &state)
                    continuation.yield(.finished(SpaceMapReport(root: tree, filesVisited: state.files,
                                                                inaccessibleCount: state.inaccessible,
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

    struct BuildState {
        var device: UInt64
        var exclusions: [String]
        var report: (Int, Int64, String) -> Void
        var tracker = InodeTracker()
        var files = 0
        var bytes: Int64 = 0
        var inaccessible = 0
        var lastReport = Date.distantPast

        init(device: UInt64, exclusions: [String], report: @escaping (Int, Int64, String) -> Void) {
            self.device = device
            self.exclusions = exclusions
            self.report = report
        }
    }

    /// Recursive build; depth is bounded by the folder depth on disk.
    func build(path: String, stat: FileStat, isPackage: Bool, state: inout BuildState) throws -> SpaceNode {
        if Task.isCancelled { throw NoriaError.cancelled }
        let name = (path as NSString).lastPathComponent
        var children: [SpaceNode] = []
        var total: Int64 = stat.allocatedSize
        var fileCount = 0
        var newest = stat.modificationDate

        if let entries = try? FileSystem.directoryEntries(path) {
            for entry in entries {
                if state.exclusions.contains(where: { entry.path.isSameOrDescendant(of: $0) }) { continue }
                guard let childStat = FileSystem.stat(entry.path) else { continue }
                switch childStat.type {
                case .directory:
                    guard childStat.device == state.device else { continue } // another volume
                    let child = try build(path: entry.path, stat: childStat, isPackage: FileWalker.isPackage(entry.path), state: &state)
                    total += child.size
                    fileCount += child.fileCount
                    if let date = child.modificationDate, date > newest { newest = date }
                    children.append(child)
                case .file:
                    state.files += 1
                    guard state.tracker.firstVisit(childStat) else { continue }
                    state.bytes += childStat.allocatedSize
                    total += childStat.allocatedSize
                    fileCount += 1
                    if childStat.modificationDate > newest { newest = childStat.modificationDate }
                    children.append(SpaceNode(path: entry.path, name: entry.name, kind: .file, size: childStat.allocatedSize,
                                              fileCount: 1, fileKind: FileKind.classify(entry.path),
                                              modificationDate: childStat.modificationDate, children: [], groupedCount: 0))
                case .symlink, .other:
                    total += childStat.allocatedSize
                }
            }
            if Date().timeIntervalSince(state.lastReport) > 0.15 {
                state.lastReport = Date()
                state.report(state.files, state.bytes, path)
            }
        } else {
            state.inaccessible += 1
        }

        // Keep significant children; group the rest into one block.
        let threshold = max(minimumNodeSize, Int64(Double(total) * minimumNodeFraction))
        var kept: [SpaceNode] = []
        var smallSize: Int64 = 0
        var smallFiles = 0
        var smallCount = 0
        for child in children {
            if child.size >= threshold {
                kept.append(child)
            } else {
                smallSize += child.size
                smallFiles += child.fileCount
                smallCount += 1
            }
        }
        if smallSize > 0 {
            kept.append(SpaceNode(path: path, name: name, kind: .smallItems, size: smallSize, fileCount: smallFiles,
                                  fileKind: .other, modificationDate: nil, children: [], groupedCount: smallCount))
        }
        kept.sort { $0.size > $1.size }
        let kind: SpaceNode.Kind = isPackage ? .package : .directory
        return SpaceNode(path: path, name: name, kind: kind, size: total, fileCount: fileCount,
                         fileKind: isPackage ? FileKind.classify(path) : .other,
                         modificationDate: newest, children: kept, groupedCount: 0)
    }
}

/// Squarified treemap layout (Bruls, Huizing & van Wijk): rectangles proportional
/// to the values, with aspect ratios kept close to 1 so they are easy to read.
public enum Treemap {
    public struct Rect: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var area: Double { width * height }
    }

    /// Returns one rectangle per value, in the same order. Values must be sorted
    /// largest first for the best result; zero or negative values get empty rects.
    public static func layout(values: [Double], in bounds: Rect) -> [Rect] {
        var result = [Rect](repeating: Rect(x: bounds.x, y: bounds.y, width: 0, height: 0), count: values.count)
        let total = values.reduce(0) { $0 + max(0, $1) }
        guard total > 0, bounds.width > 0, bounds.height > 0 else { return result }
        let scale = bounds.area / total
        let areas = values.map { max(0, $0) * scale }

        var remaining = bounds
        var row: [Int] = []
        var index = 0

        func worst(_ indices: [Int], side: Double) -> Double {
            let sum = indices.reduce(0) { $0 + areas[$1] }
            guard sum > 0, side > 0 else { return .infinity }
            let maxArea = indices.map { areas[$0] }.max() ?? 0
            let minArea = indices.map { areas[$0] }.filter { $0 > 0 }.min() ?? 0
            guard minArea > 0 else { return .infinity }
            let sideSquared = side * side
            return max(sideSquared * maxArea / (sum * sum), (sum * sum) / (sideSquared * minArea))
        }

        func place(_ indices: [Int]) {
            let sum = indices.reduce(0) { $0 + areas[$1] }
            guard sum > 0 else { return }
            if remaining.width >= remaining.height {
                // Column on the left.
                let width = sum / remaining.height
                var y = remaining.y
                for i in indices {
                    let height = areas[i] / width
                    result[i] = Rect(x: remaining.x, y: y, width: width, height: height)
                    y += height
                }
                remaining = Rect(x: remaining.x + width, y: remaining.y, width: max(0, remaining.width - width), height: remaining.height)
            } else {
                // Row on the top.
                let height = sum / remaining.width
                var x = remaining.x
                for i in indices {
                    let width = areas[i] / height
                    result[i] = Rect(x: x, y: remaining.y, width: width, height: height)
                    x += width
                }
                remaining = Rect(x: remaining.x, y: remaining.y + height, width: remaining.width, height: max(0, remaining.height - height))
            }
        }

        while index < areas.count {
            if areas[index] <= 0 {
                index += 1
                continue
            }
            let side = min(remaining.width, remaining.height)
            if row.isEmpty || worst(row + [index], side: side) <= worst(row, side: side) {
                row.append(index)
                index += 1
            } else {
                place(row)
                row = []
            }
        }
        if !row.isEmpty { place(row) }
        return result
    }
}
