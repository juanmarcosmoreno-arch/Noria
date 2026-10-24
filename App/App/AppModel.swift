import AppKit
import NoriaCore
import Observation
import SwiftUI

/// Root application state. Owns long-lived services and the per-feature models.
@MainActor
@Observable
final class AppModel {
    var selection: SidebarItem? = .dashboard

    var settings: NoriaSettings {
        didSet {
            guard settings != oldValue else { return }
            settingsStore.save(settings)
            if settings.language != oldValue.language { LanguageManager.apply(settings.language) }
            watch.configure(settings)
        }
    }

    private(set) var volume: VolumeInfo?
    private(set) var volumeError: String?
    let device = DeviceInfo.current()
    let metrics = MetricsMonitor()
    let watch = WatchService()
    let folderAccess: FolderAccess
    private(set) var history: [OperationRecord] = []
    private(set) var historyError: String?

    let locations = SystemLocations.current
    let operationLog = OperationLog(fileURL: OperationLog.defaultFileURL())
    let quarantine = QuarantineStore(root: QuarantineStore.defaultRoot())
    private(set) var quarantineEntries: [QuarantineEntry] = []
    private(set) var quarantineMessage: String?
    private let settingsStore: any SettingsStore

    // Feature models need a reference back to the app model, so they are created
    // at the end of init; the accessors expose them as non-optional.
    @ObservationIgnored private var smartScanStorage: SmartScanModel?
    @ObservationIgnored private var largeFilesStorage: LargeFilesModel?
    @ObservationIgnored private var appRemoverStorage: AppRemoverModel?
    @ObservationIgnored private var mailStorage: MailModel?
    @ObservationIgnored private var spaceMapStorage: SpaceMapModel?
    @ObservationIgnored private var duplicatesStorage: DuplicatesModel?
    var smartScan: SmartScanModel { smartScanStorage! }
    var largeFiles: LargeFilesModel { largeFilesStorage! }
    var appRemover: AppRemoverModel { appRemoverStorage! }
    var mail: MailModel { mailStorage! }
    var spaceMap: SpaceMapModel { spaceMapStorage! }
    var duplicates: DuplicatesModel { duplicatesStorage! }

    /// Launch Services knows apps anywhere on disk, not only in Applications folders.
    static let appLookup: @Sendable (String) -> Bool = { identifier in
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) != nil
    }

    init(settingsStore: any SettingsStore = UserDefaultsSettingsStore()) {
        self.settingsStore = settingsStore
        self.settings = settingsStore.load()
        self.folderAccess = FolderAccess(homePath: SystemLocations.current.home)
        smartScanStorage = SmartScanModel(app: self)
        largeFilesStorage = LargeFilesModel(app: self)
        appRemoverStorage = AppRemoverModel(app: self)
        mailStorage = MailModel(app: self)
        spaceMapStorage = SpaceMapModel(app: self)
        duplicatesStorage = DuplicatesModel(app: self)
        refreshVolume()
        watch.configure(settings)
        Task {
            await loadHistory()
            await purgeExpiredQuarantine()
        }
    }

    // MARK: Quarantine

    var quarantineSize: Int64 { quarantineEntries.reduce(0) { $0 + $1.allocatedSize } }

    func refreshQuarantine() async {
        let store = quarantine
        quarantineEntries = await Task.detached(priority: .utility) { store.entries() }.value
    }

    /// Deletes entries older than the retention period chosen in Settings.
    func purgeExpiredQuarantine() async {
        let store = quarantine
        let days = settings.quarantineRetentionDays
        let purged = await Task.detached(priority: .utility) { store.purgeExpired(retentionDays: days) }.value
        if !purged.isEmpty { record(.quarantineDeletion(purged)) }
        await refreshQuarantine()
    }

    func restore(_ entries: [QuarantineEntry]) {
        let store = quarantine
        Task {
            let (restored, failures) = await Task.detached(priority: .userInitiated) { () -> ([QuarantineEntry], [OperationRecord.Failure]) in
                var restored: [QuarantineEntry] = []
                var failures: [OperationRecord.Failure] = []
                for entry in entries {
                    do {
                        try store.restore(entry)
                        restored.append(entry)
                    } catch {
                        failures.append(OperationRecord.Failure(path: entry.originalPath, message: String(describing: error)))
                    }
                }
                return (restored, failures)
            }.value
            record(.restore(restored, failures: failures))
            quarantineMessage = failures.isEmpty
                ? String(localized: "\(Format.count(restored.count)) items restored to their original location.")
                : String(localized: "\(Format.count(failures.count)) items could not be restored because something already exists at their original location. Use Reveal to recover them manually.")
            await refreshQuarantine()
            refreshVolume()
        }
    }

    func deleteFromQuarantine(_ entries: [QuarantineEntry]) {
        let store = quarantine
        Task {
            let deleted = await Task.detached(priority: .userInitiated) {
                entries.filter { (try? store.delete($0)) != nil }
            }.value
            if !deleted.isEmpty { record(.quarantineDeletion(deleted)) }
            let freed = Format.bytes(deleted.reduce(0) { $0 + $1.allocatedSize })
            quarantineMessage = String(localized: "\(freed) freed.")
            await refreshQuarantine()
            refreshVolume()
        }
    }

    /// Path of a quarantined item on disk, for "Reveal in Finder".
    func quarantinePath(of entry: QuarantineEntry) -> String {
        ((quarantine.root as NSString).appendingPathComponent(entry.id.uuidString) as NSString).appendingPathComponent(entry.storedName)
    }

    var safetyPolicy: SafetyPolicy {
        SafetyPolicy(locations: locations, exclusions: settings.exclusions)
    }

    func refreshVolume() {
        let home = locations.home
        Task {
            let result = await Task.detached(priority: .utility) { () -> Result<VolumeInfo, Error> in
                Result { try VolumeInfoProvider().volumeInfo(for: home) }
            }.value
            switch result {
            case .success(let info):
                volume = info
                volumeError = nil
            case .failure(let error):
                volumeError = String(describing: error)
            }
        }
    }

    func loadHistory() async {
        do {
            history = try await operationLog.records()
            historyError = nil
        } catch {
            historyError = error.localizedDescription
        }
    }

    func record(_ record: OperationRecord) {
        Task {
            do {
                try await operationLog.append(record)
            } catch {
                historyError = error.localizedDescription
            }
            await loadHistory()
        }
    }

    func clearHistory() {
        Task {
            try? await operationLog.clear()
            await loadHistory()
        }
    }

    func addExclusion(_ path: String) {
        let canonical = FileSystem.bestEffortCanonicalPath(path)
        guard !settings.exclusions.contains(canonical) else { return }
        settings.exclusions.append(canonical)
    }
}

/// Applies the interface-language preference. macOS reads `AppleLanguages`
/// at launch, so a change takes effect after relaunching Noria.
enum LanguageManager {
    static func apply(_ language: AppLanguage) {
        switch language {
        case .system:
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .english, .spanish:
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
    }
}

/// Finder / System Settings helpers.
enum SystemActions {
    static func revealInFinder(_ paths: [String]) {
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
    }

    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Opens Privacy & Security › Full Disk Access. Noria never tries to bypass TCC;
    /// the user decides whether to grant access.
    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openTrash() {
        NSWorkspace.shared.open(URL(fileURLWithPath: SystemLocations.current.trash))
    }

    /// Lets the user pick a folder.
    @MainActor
    static func chooseFolder(prompt: String, startingAt path: String? = nil) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        if let path { panel.directoryURL = URL(fileURLWithPath: path) }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    /// Lets the user pick files or folders (for exclusions).
    @MainActor
    static func chooseItems(prompt: String) -> [String] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.urls.map(\.path) : []
    }
}

/// Resolves bundle identifiers to installed app names and detects running apps.
@MainActor
enum AppDirectory {
    private static var nameCache: [String: String?] = [:]

    static func appName(for bundleIdentifier: String) -> String? {
        if let cached = nameCache[bundleIdentifier] { return cached }
        var name: String?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        nameCache[bundleIdentifier] = name
        return name
    }

    /// Names of running apps related to the given items (by bundle id or owner).
    static func runningApps(relatedTo items: [ScanItem]) -> [String] {
        let running = NSWorkspace.shared.runningApplications
        var names = Set<String>()
        for item in items {
            for app in running {
                guard let bundleID = app.bundleIdentifier else { continue }
                let matchesBundle = item.bundleIdentifier.map { bundleID.caseInsensitiveCompare($0) == .orderedSame } ?? false
                let matchesOwner = item.ownerName.map { owner in
                    (app.localizedName ?? "").localizedCaseInsensitiveContains(owner) && !owner.isEmpty
                } ?? false
                if matchesBundle || matchesOwner, let name = app.localizedName { names.insert(name) }
            }
        }
        return names.sorted()
    }
}
