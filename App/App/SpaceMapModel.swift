import NoriaCore
import Observation
import SwiftUI

/// State of the Space Map: the scanned tree, where the user is, and the selection.
@MainActor
@Observable
final class SpaceMapModel {
    enum Phase: Equatable {
        case idle, scanning, finished, cancelled
        case failed(String)
    }

    private unowned let app: AppModel

    var rootPath: String
    private(set) var phase: Phase = .idle
    private(set) var filesVisited = 0
    private(set) var bytesVisited: Int64 = 0
    private(set) var currentFolder = ""
    private(set) var report: SpaceMapReport?
    /// Folder being displayed (a container node path).
    var currentPath: String?
    var selectedNodeID: SpaceNode.ID?
    let cleanup = CleanupController()

    private var scanTask: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
        self.rootPath = app.locations.home
    }

    var isScanning: Bool { phase == .scanning }

    var currentNode: SpaceNode? {
        guard let root = report?.root else { return nil }
        return currentPath.flatMap { root.node(at: $0) } ?? root
    }

    var selectedNode: SpaceNode? {
        guard let id = selectedNodeID, let current = currentNode else { return nil }
        if current.id == id { return current }
        return Self.find(id, in: current, depth: 2)
    }

    private static func find(_ id: SpaceNode.ID, in node: SpaceNode, depth: Int) -> SpaceNode? {
        for child in node.children {
            if child.id == id { return child }
            if depth > 1, let found = find(id, in: child, depth: depth - 1) { return found }
        }
        return nil
    }

    /// Breadcrumb trail from the scan root to the current folder.
    var breadcrumbs: [SpaceNode] {
        guard let root = report?.root else { return [] }
        var trail = [root]
        guard let target = currentPath, target != root.path else { return trail }
        var node = root
        while let next = node.children.first(where: { $0.isContainer && target.isSameOrDescendant(of: $0.path) }) {
            trail.append(next)
            node = next
            if next.path == target { break }
        }
        return trail
    }

    func start() {
        guard !isScanning else { return }
        guard app.folderAccess.ensureReadable(rootPath) else { return }
        phase = .scanning
        filesVisited = 0
        bytesVisited = 0
        report = nil
        currentPath = nil
        selectedNodeID = nil
        let scanner = SpaceMapScanner()
        let root = rootPath
        let exclusions = app.settings.exclusions
        scanTask = Task { [weak self] in
            do {
                for try await event in scanner.scan(root: root, exclusions: exclusions) {
                    guard let self else { return }
                    switch event {
                    case .progress(let files, let bytes, let folder):
                        filesVisited = files
                        bytesVisited = bytes
                        currentFolder = folder
                    case .finished(let report):
                        self.report = report
                        phase = .finished
                    }
                }
                if Task.isCancelled { self?.phase = .cancelled }
            } catch is CancellationError {
                self?.phase = .cancelled
            } catch {
                self?.phase = .failed(String(describing: error))
            }
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        if isScanning { phase = .cancelled }
    }

    func chooseRoot() {
        if let path = SystemActions.chooseFolder(prompt: String(localized: "Scan"), startingAt: rootPath) {
            rootPath = FileSystem.bestEffortCanonicalPath(path)
            app.folderAccess.noteSessionGrant(rootPath)
        }
    }

    func open(_ node: SpaceNode) {
        if node.isContainer, !node.children.isEmpty {
            currentPath = node.path
            selectedNodeID = nil
        } else {
            selectedNodeID = node.id
        }
    }

    func goUp() {
        let trail = breadcrumbs
        guard trail.count > 1 else { return }
        currentPath = trail[trail.count - 2].path
        selectedNodeID = nil
    }

    /// Item for the cleaning engine, with the identity captured during the scan. `nil` for grouped blocks.
    func scanItem(for node: SpaceNode) -> ScanItem? {
        guard node.kind != .smallItems, let stat = node.fingerprint else { return nil }
        let policy = app.safetyPolicy
        let protected = policy.protectionReason(for: node.path, category: .largeFiles) != nil
            || node.path.isSameOrDescendant(of: app.locations.library)
            || !node.path.isStrictDescendant(of: app.locations.home)
        return ScanItem(path: node.path, name: node.name, category: .largeFiles,
                        risk: protected ? .protected : .review,
                        reason: protected ? .protectedLocation : .spaceMapSelection,
                        allocatedSize: node.size, fileCount: node.fileCount,
                        modificationDate: node.modificationDate, fingerprint: stat)
    }

    func remove(_ item: ScanItem) {
        guard item.isSelectable else { return }
        cleanup.run(items: [item], app: app) { [weak self] report in
            guard let self, let tree = self.report?.root else { return }
            let removed = Set(report.removed.map(\.path))
            guard !removed.isEmpty else { return }
            if let pruned = Self.pruned(tree, removing: removed) {
                self.report?.root = pruned
            }
            selectedNodeID = nil
        }
    }

    /// Removes paths from the tree and recomputes the sizes of their ancestors.
    static func pruned(_ node: SpaceNode, removing paths: Set<String>) -> SpaceNode? {
        if node.kind != .smallItems, paths.contains(node.path) { return nil }
        guard node.isContainer, paths.contains(where: { $0.isStrictDescendant(of: node.path) }) else { return node }
        var copy = node
        let before = node.children.reduce(0) { $0 + $1.size }
        copy.children = node.children.compactMap { pruned($0, removing: paths) }
        let after = copy.children.reduce(0) { $0 + $1.size }
        copy.size = max(0, node.size - (before - after))
        return copy
    }
}
