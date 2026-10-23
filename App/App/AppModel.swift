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
        }
    }

    private(set) var volume: VolumeInfo?
    private(set) var volumeError: String?
    let device = DeviceInfo.current()
    private(set) var history: [OperationRecord] = []
    private(set) var historyError: String?

    let locations = SystemLocations.current
    let operationLog = OperationLog(fileURL: OperationLog.defaultFileURL())
    private let settingsStore: any SettingsStore

    // Feature models need a reference back to the app model, so they are created
    // at the end of init; the accessors expose them as non-optional.
    @ObservationIgnored private var smartScanStorage: SmartScanModel?
    @ObservationIgnored private var largeFilesStorage: LargeFilesModel?
    var smartScan: SmartScanModel { smartScanStorage! }
    var largeFiles: LargeFilesModel { largeFilesStorage! }

    init(settingsStore: any SettingsStore = UserDefaultsSettingsStore()) {
        self.settingsStore = settingsStore
        self.settings = settingsStore.load()
        smartScanStorage = SmartScanModel(app: self)
        largeFilesStorage = LargeFilesModel(app: self)
        refreshVolume()
        Task { await loadHistory() }
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
