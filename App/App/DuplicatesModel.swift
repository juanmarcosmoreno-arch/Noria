import NoriaCore
import Observation
import SwiftUI

/// State of the Duplicates module.
@MainActor
@Observable
final class DuplicatesModel {
    enum Phase: Equatable {
        case idle, scanning, finished, cancelled
        case failed(String)
    }

    enum MinimumSize: Int64, CaseIterable, Identifiable {
        case mb1 = 1_000_000
        case mb10 = 10_000_000
        case mb100 = 100_000_000

        var id: Int64 { rawValue }
        var title: String { String(localized: "Larger than \(Format.bytes(rawValue))") }
    }

    private unowned let app: AppModel

    var rootPath: String
    var minimumSize: MinimumSize = .mb1
    private(set) var phase: Phase = .idle
    private(set) var stage = ""
    private(set) var filesVisited = 0
    private(set) var candidates = 0
    private(set) var hashed = 0
    private(set) var groups: [DuplicateGroup] = []
    private(set) var report: DuplicateReport?
    /// Paths selected for removal.
    var selectedPaths: Set<String> = []
    private(set) var selectionNotice: String?
    let cleanup = CleanupController()

    private var scanTask: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
        self.rootPath = app.locations.home
    }

    var isScanning: Bool { phase == .scanning }
    var reclaimableSize: Int64 { groups.reduce(0) { $0 + $1.reclaimableSize } }

    /// What would actually be removed: always leaves at least one copy per group.
    var plannedRemovals: [(DuplicateFile, Int64)] {
        let downloads = app.locations.downloads
        return groups.flatMap { group in
            DuplicateFinder.safeRemovals(groups: [group], selected: selectedPaths, downloads: downloads).map { ($0, group.size) }
        }
    }

    var selectedSize: Int64 { plannedRemovals.reduce(0) { $0 + $1.1 } }

    func keeper(of group: DuplicateGroup) -> DuplicateFile? {
        group.suggestedKeeper(downloads: app.locations.downloads)
    }

    func start() {
        guard !isScanning else { return }
        guard app.folderAccess.ensureReadable(rootPath) else { return }
        phase = .scanning
        groups = []
        report = nil
        selectedPaths = []
        selectionNotice = nil
        filesVisited = 0
        candidates = 0
        hashed = 0
        let finder = DuplicateFinder(locations: app.locations, minimumSize: minimumSize.rawValue)
        let root = rootPath
        let settings = app.settings
        scanTask = Task { [weak self] in
            do {
                for try await event in finder.scan(root: root, settings: settings) {
                    guard let self else { return }
                    switch event {
                    case .progress(let stage, let visited, let candidates, let hashed):
                        self.stage = stage
                        filesVisited = visited
                        self.candidates = candidates
                        self.hashed = hashed
                    case .finished(let report):
                        self.report = report
                        groups = report.groups
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

    /// Toggles a copy, refusing to select the last unselected copy of a group.
    func toggle(_ file: DuplicateFile, in group: DuplicateGroup) {
        if selectedPaths.contains(file.path) {
            selectedPaths.remove(file.path)
            selectionNotice = nil
            return
        }
        let unselected = group.files.filter { !selectedPaths.contains($0.path) }
        guard unselected.count > 1 else {
            selectionNotice = String(localized: "At least one copy of every file is always kept.")
            return
        }
        selectedPaths.insert(file.path)
    }

    /// Selects every copy except the suggested keeper of each group.
    func selectAutomatically() {
        var selection = Set<String>()
        for group in groups {
            let keep = keeper(of: group)?.path
            for file in group.files where file.path != keep { selection.insert(file.path) }
        }
        selectedPaths = selection
        selectionNotice = nil
    }

    func removeSelection() {
        let items = plannedRemovals.map { $0.0.asScanItem(size: $0.1) }
        guard !items.isEmpty else { return }
        cleanup.run(items: items, app: app) { [weak self] report in
            guard let self else { return }
            let removed = Set(report.removed.map(\.path))
            selectedPaths.subtract(removed)
            groups = groups.compactMap { group in
                var copy = group
                copy.files.removeAll { removed.contains($0.path) }
                return copy.files.count > 1 ? copy : nil
            }
        }
    }

    var plannedItems: [ScanItem] { plannedRemovals.map { $0.0.asScanItem(size: $0.1) } }
}
