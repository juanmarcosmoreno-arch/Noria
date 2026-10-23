import NoriaCore
import Observation
import SwiftUI

/// State of the Large Files module.
@MainActor
@Observable
final class LargeFilesModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case finished
        case cancelled
        case failed(String)
    }

    enum Threshold: Hashable, CaseIterable, Identifiable {
        case mb100, mb500, gb1, custom

        var id: Self { self }

        var bytes: Int64? {
            switch self {
            case .mb100: return 100_000_000
            case .mb500: return 500_000_000
            case .gb1: return 1_000_000_000
            case .custom: return nil
            }
        }

        var title: String {
            switch self {
            case .mb100: return String(localized: "Over 100 MB")
            case .mb500: return String(localized: "Over 500 MB")
            case .gb1: return String(localized: "Over 1 GB")
            case .custom: return String(localized: "Custom")
            }
        }
    }

    private unowned let app: AppModel

    var rootPath: String
    var threshold: Threshold = .mb500
    var customThresholdMB = 250
    var kindFilter: FileKind?
    var sortOrder = [KeyPathComparator(\LargeFile.allocatedSize, order: .reverse)]
    var selection: Set<LargeFile.ID> = []

    private(set) var phase: Phase = .idle
    private(set) var files: [LargeFile] = []
    private(set) var filesVisited = 0
    private(set) var bytesVisited: Int64 = 0
    private(set) var startedAt: Date?
    private(set) var lastReport: LargeFileReport?
    let cleanup = CleanupController()

    private var scanTask: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
        self.rootPath = app.locations.home
        let saved = app.settings.largeFileThreshold
        self.threshold = Threshold.allCases.first { $0.bytes == saved } ?? .custom
        self.customThresholdMB = Int(saved / 1_000_000)
    }

    var thresholdBytes: Int64 {
        threshold.bytes ?? Int64(max(1, customThresholdMB)) * 1_000_000
    }

    var isScanning: Bool { phase == .scanning }

    var visibleFiles: [LargeFile] {
        let filtered = kindFilter.map { kind in files.filter { $0.kind == kind } } ?? files
        return filtered.sorted(using: sortOrder)
    }

    var selectedFiles: [LargeFile] { files.filter { selection.contains($0.id) } }

    /// Selected files Noria is allowed to move to the Trash.
    var removableSelection: [LargeFile] { selectedFiles.filter { $0.risk != .protected } }

    func start() {
        guard !isScanning else { return }
        let scanner = LargeFileScanner(locations: app.locations)
        let threshold = thresholdBytes
        let root = rootPath
        let settings = app.settings
        app.settings.largeFileThreshold = threshold
        phase = .scanning
        files = []
        selection = []
        filesVisited = 0
        bytesVisited = 0
        startedAt = Date()
        lastReport = nil
        cleanup.reset()

        scanTask = Task { [weak self] in
            do {
                for try await event in scanner.scan(root: root, threshold: threshold, settings: settings) {
                    guard let self else { return }
                    switch event {
                    case .progress(let visited, let bytes):
                        self.filesVisited = visited
                        self.bytesVisited = bytes
                    case .found(let batch):
                        self.files.append(contentsOf: batch)
                    case .finished(let report):
                        self.files = report.files
                        self.lastReport = report
                        self.phase = .finished
                        self.app.record(.largeFileScan(report))
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
        }
    }

    func moveSelectionToTrash() {
        let items = removableSelection.map { $0.asScanItem() }
        guard !items.isEmpty else { return }
        cleanup.run(items: items, app: app) { [weak self] report in
            let removed = Set(report.removed.map(\.path))
            self?.files.removeAll { removed.contains($0.path) }
            self?.selection.subtract(removed)
        }
    }
}
