import AppKit
import NoriaCore
import Observation
import SwiftUI

/// State of App Remover: installed apps, the selected app's files and the removal.
@MainActor
@Observable
final class AppRemoverModel {
    private unowned let app: AppModel

    private(set) var apps: [InstalledApp] = []
    private(set) var sizes: [String: Int64] = [:]
    private(set) var isLoadingApps = false
    var searchText = ""

    enum SortOrder: String, CaseIterable, Identifiable {
        case size, name
        var id: String { rawValue }
        var title: String {
            switch self {
            case .size: return String(localized: "Largest First")
            case .name: return String(localized: "Name")
            }
        }
    }

    var sortOrder: SortOrder = .size

    var selectedAppID: InstalledApp.ID? {
        didSet { if selectedAppID != oldValue { loadRelatedFiles() } }
    }
    private(set) var relatedItems: [ScanItem] = []
    private(set) var isLoadingFiles = false
    var selectedItemIDs: Set<UUID> = []
    let cleanup = CleanupController()

    private var filesTask: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
    }

    var visibleApps: [InstalledApp] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let matching = query.isEmpty ? apps
            : apps.filter { $0.name.localizedCaseInsensitiveContains(query) || ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains(query) }
        switch sortOrder {
        case .name:
            return matching.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size:
            // Apps still being measured go last.
            return matching.sorted { (sizes[$0.path] ?? -1) > (sizes[$1.path] ?? -1) }
        }
    }

    var selectedApp: InstalledApp? { apps.first { $0.id == selectedAppID } }
    var selectedItems: [ScanItem] { relatedItems.filter { selectedItemIDs.contains($0.id) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.allocatedSize } }
    var includesAppBundle: Bool { selectedItems.contains { $0.reason == .applicationBundle } }

    /// Lists apps in /Applications and ~/Applications (Apple apps and Noria itself are hidden).
    func loadApps() {
        guard !isLoadingApps else { return }
        isLoadingApps = true
        let roots = app.locations.applicationFolders
        let ownIdentifier = Bundle.main.bundleIdentifier?.lowercased()
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                AppInventory.scan(roots: roots).filter { !$0.isApple && $0.bundleIdentifier?.lowercased() != ownIdentifier }
            }.value
            apps = found
            isLoadingApps = false
            await measureSizes(found)
        }
    }

    private func measureSizes(_ apps: [InstalledApp]) async {
        for installed in apps where sizes[installed.path] == nil {
            let path = installed.path
            let size = await Task.detached(priority: .utility) {
                (try? DirectorySizer().measure(path, tracker: InodeTracker()).allocatedSize) ?? 0
            }.value
            sizes[path] = size
        }
    }

    func isRunning(_ installed: InstalledApp) -> Bool {
        guard let identifier = installed.bundleIdentifier else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty
    }

    private func loadRelatedFiles() {
        filesTask?.cancel()
        relatedItems = []
        selectedItemIDs = []
        guard let selected = selectedApp else { return }
        isLoadingFiles = true
        let context = ScanContext(locations: app.locations, settings: app.settings)
        filesTask = Task {
            let items = await Task.detached(priority: .userInitiated) {
                (try? AppFilesFinder.relatedItems(for: selected, context: context)) ?? []
            }.value
            guard !Task.isCancelled, selectedAppID == selected.id else { return }
            relatedItems = items.sorted { $0.allocatedSize > $1.allocatedSize }
            // Only reliable, disposable matches start selected; REVIEW items need a choice.
            selectedItemIDs = Set(items.filter { $0.isSelectable && $0.risk == .safe }.map(\.id))
            isLoadingFiles = false
        }
    }

    func toggle(_ item: ScanItem) {
        guard item.isSelectable else { return }
        if selectedItemIDs.contains(item.id) { selectedItemIDs.remove(item.id) } else { selectedItemIDs.insert(item.id) }
    }

    /// In the App Store edition, asks for the folders the removal needs.
    func ensureAccess() -> Bool {
        let access = app.folderAccess
        for item in selectedItems where !access.canModify(item.path) {
            if item.path.isSameOrDescendant(of: FolderAccess.applicationsFolder) {
                let message = String(localized: "To remove apps, Noria needs permission to modify the Applications folder. Click Allow Access.")
                guard access.requestAccess(to: FolderAccess.applicationsFolder, message: message) else { return false }
            } else if access.needsGrant {
                guard access.requestHomeAccess() else { return false }
            }
        }
        return true
    }

    func removeSelection() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        cleanup.run(items: items, app: app) { [weak self] report in
            guard let self else { return }
            let removedPaths = Set(report.removed.map(\.path))
            relatedItems.removeAll { removedPaths.contains($0.path) }
            selectedItemIDs = selectedItemIDs.intersection(Set(relatedItems.map(\.id)))
            if let selected = selectedApp, removedPaths.contains(selected.path) {
                apps.removeAll { $0.id == selected.id }
                selectedAppID = nil
            }
        }
    }
}
