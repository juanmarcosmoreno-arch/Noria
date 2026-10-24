import NoriaCore
import Observation
import SwiftUI

/// State of the Privacy module. Nothing is preselected: browsing data is personal, not junk.
@MainActor
@Observable
final class PrivacyModel {
    enum Phase: Equatable {
        case idle, scanning, finished
        case failed(String)
    }

    private unowned let app: AppModel

    private(set) var phase: Phase = .idle
    private(set) var report: PrivacyReport?
    var selectedEntryIDs: Set<String> = []
    let cleanup = CleanupController()

    init(app: AppModel) {
        self.app = app
    }

    /// Browsers with the most data first.
    var browsers: [Browser] {
        (report?.browsers ?? []).sorted { size(of: $0) > size(of: $1) }
    }

    /// Largest entries first.
    func entries(for browser: Browser) -> [BrowserDataEntry] {
        (report?.entries ?? []).filter { $0.browser == browser }.sorted { $0.size > $1.size }
    }

    func size(of browser: Browser) -> Int64 {
        (report?.entries ?? []).filter { $0.browser == browser }.reduce(0) { $0 + $1.size }
    }

    var selectedItems: [ScanItem] {
        (report?.entries ?? []).filter { selectedEntryIDs.contains($0.id) }.flatMap(\.items)
    }

    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.allocatedSize } }

    func scan() {
        guard phase != .scanning else { return }
        guard app.folderAccess.ensureReadable(app.locations.applicationSupport) else { return }
        phase = .scanning
        selectedEntryIDs = []
        let scanner = PrivacyScanner(locations: app.locations)
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try scanner.scan() } }.value
            switch result {
            case .success(let report):
                self.report = report
                phase = .finished
            case .failure(let error):
                phase = .failed(String(describing: error))
            }
        }
    }

    func toggle(_ entry: BrowserDataEntry) {
        if selectedEntryIDs.contains(entry.id) { selectedEntryIDs.remove(entry.id) } else { selectedEntryIDs.insert(entry.id) }
    }

    /// Selects or clears one kind of data in every profile of a browser.
    func setSelection(_ kind: BrowserDataKind, of browser: Browser, selected: Bool) {
        for entry in entries(for: browser) where entry.kind == kind {
            if selected { selectedEntryIDs.insert(entry.id) } else { selectedEntryIDs.remove(entry.id) }
        }
    }

    func cleanSelection() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        cleanup.run(items: items, app: app) { [weak self] report in
            guard let self, var current = self.report else { return }
            let removed = Set(report.removed.map(\.path))
            for index in current.entries.indices {
                current.entries[index].items.removeAll { removed.contains($0.path) }
            }
            current.entries.removeAll { $0.items.isEmpty }
            self.report = current
            selectedEntryIDs = selectedEntryIDs.filter { id in current.entries.contains { $0.id == id } }
        }
    }
}
