import AppKit
import NoriaCore
import Observation
import SwiftUI

/// State of the Mail screen: where Mail's space goes and what can be safely cleaned.
@MainActor
@Observable
final class MailModel {
    enum Phase: Equatable {
        case idle, scanning, finished
        case failed(String)
    }

    private unowned let app: AppModel

    private(set) var phase: Phase = .idle
    private(set) var usage: MailUsageReport?
    private(set) var items: [ScanItem] = []
    var selectedIDs: Set<UUID> = []
    let cleanup = CleanupController()

    init(app: AppModel) {
        self.app = app
    }

    var removableItems: [ScanItem] { items.filter(\.isSelectable) }
    var selectedItems: [ScanItem] { items.filter { selectedIDs.contains($0.id) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.allocatedSize } }
    var protectedSize: Int64 { items.filter { !$0.isSelectable }.reduce(0) { $0 + $1.allocatedSize } }

    var isMailRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: MailRule.mailBundleIdentifier).isEmpty
    }

    func analyze() {
        guard phase != .scanning else { return }
        if app.folderAccess.needsGrant {
            app.folderAccess.requestHomeAccess()
            guard !app.folderAccess.needsGrant else { return }
        }
        phase = .scanning
        let context = ScanContext(locations: app.locations, settings: app.settings,
                                  mailAccounts: AccountsDatabaseResolver(databasePath: app.locations.accountsDatabase))
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(MailUsageReport, [ScanItem]), Error> in
                Result {
                    let usage = try MailRule.usage(context)
                    let output = try MailRule().scan(context)
                    return (usage, output.items.sorted { $0.allocatedSize > $1.allocatedSize })
                }
            }.value
            switch result {
            case .success(let (usage, items)):
                self.usage = usage
                self.items = items
                // Mail Downloads are copies: preselected. Server attachments need a choice.
                selectedIDs = Set(items.filter { $0.isSelectable && $0.risk == .safe }.map(\.id))
                phase = .finished
            case .failure(let error):
                phase = .failed(String(describing: error))
            }
        }
    }

    func toggle(_ item: ScanItem) {
        guard item.isSelectable else { return }
        if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) } else { selectedIDs.insert(item.id) }
    }

    func selectAllRemovable(_ selected: Bool) {
        selectedIDs = selected ? Set(removableItems.map(\.id)) : []
    }

    func cleanSelection() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        cleanup.run(items: items, app: app) { [weak self] _ in
            self?.analyze()
        }
    }
}
