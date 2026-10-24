import Foundation

/// A web browser whose profile data Noria knows how to explain.
public struct Browser: Sendable, Hashable, Identifiable {
    public enum Engine: String, Sendable { case chromium, firefox }

    public var id: String { bundleIdentifier }
    /// Product name (not localized).
    public var name: String
    public var bundleIdentifier: String
    public var engine: Engine
    /// Folder inside `~/Library/Application Support` that holds the profiles.
    public var supportPath: String
}

/// What kind of browsing data a group of files holds.
public enum BrowserDataKind: String, Codable, Sendable, CaseIterable {
    /// Visited pages, typed URLs and top sites.
    case history
    /// Cookies: removing them signs you out of websites.
    case cookies
    /// Open and recently closed tabs and windows.
    case sessions
    /// Text typed into web forms (Firefox).
    case formHistory
    /// Website storage: local storage, IndexedDB, service workers and their caches.
    case siteData
}

/// Browsing data of one browser profile, of one kind. Removed as a unit.
public struct BrowserDataEntry: Identifiable, Sendable, Hashable {
    public var id: String { "\(browser.bundleIdentifier)|\(profilePath)|\(kind.rawValue)" }
    public var browser: Browser
    /// Profile folder name as shown by the browser when known ("Default", "Profile 1"…).
    public var profile: String
    public var profilePath: String
    public var kind: BrowserDataKind
    public var items: [ScanItem]

    public var size: Int64 { items.reduce(0) { $0 + $1.allocatedSize } }
    public var lastModified: Date? { items.compactMap(\.modificationDate).max() }
}

/// Something Noria found but does not remove, with the reason (for transparency).
public struct PrivacyNotice: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable {
        /// Safari's data is protected by macOS; cleared from Safari's own menu.
        case safariProtected
        /// Firefox stores history and bookmarks in the same database.
        case firefoxHistoryWithBookmarks
    }

    public var id: String { "\(kind.rawValue)|\(path)" }
    public var kind: Kind
    public var browserName: String
    public var path: String
}

public struct PrivacyReport: Sendable {
    public var entries: [BrowserDataEntry]
    public var notices: [PrivacyNotice]
    public var duration: TimeInterval

    public var browsers: [Browser] {
        var seen = Set<String>()
        return entries.map(\.browser).filter { seen.insert($0.bundleIdentifier).inserted }
    }
}

/// Finds browsing data of the browsers installed for this user. Read-only.
///
/// * Only files and folders with names in `removableNames` are ever reported, and the
///   safety policy checks the same list again before removal.
/// * Passwords, bookmarks, extensions, settings and payment data are never reported.
/// * Everything is REVIEW and never preselected: this is personal data, not junk.
/// * The browser must be closed before its data is removed (`requiresQuitting`).
public struct PrivacyScanner: Sendable {
    public var locations: SystemLocations

    public init(locations: SystemLocations = .current) {
        self.locations = locations
    }

    public static let browsers: [Browser] = [
        Browser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", engine: .chromium, supportPath: "Google/Chrome"),
        Browser(name: "Brave", bundleIdentifier: "com.brave.Browser", engine: .chromium, supportPath: "BraveSoftware/Brave-Browser"),
        Browser(name: "Microsoft Edge", bundleIdentifier: "com.microsoft.edgemac", engine: .chromium, supportPath: "Microsoft Edge"),
        Browser(name: "Vivaldi", bundleIdentifier: "com.vivaldi.Vivaldi", engine: .chromium, supportPath: "Vivaldi"),
        Browser(name: "Arc", bundleIdentifier: "company.thebrowser.Browser", engine: .chromium, supportPath: "Arc/User Data"),
        Browser(name: "Opera", bundleIdentifier: "com.operasoftware.Opera", engine: .chromium, supportPath: "com.operasoftware.Opera"),
        Browser(name: "Chromium", bundleIdentifier: "org.chromium.Chromium", engine: .chromium, supportPath: "Chromium"),
        Browser(name: "Firefox", bundleIdentifier: "org.mozilla.firefox", engine: .firefox, supportPath: "Firefox/Profiles"),
    ]

    /// Names inside a profile that hold each kind of data. `Network/` entries are
    /// relative to the profile folder.
    public static func files(for kind: BrowserDataKind, engine: Browser.Engine) -> [String] {
        switch (engine, kind) {
        case (.chromium, .history):
            return ["History", "History-journal", "Visited Links", "Top Sites", "Top Sites-journal", "Shortcuts", "Shortcuts-journal"]
        case (.chromium, .cookies):
            return ["Cookies", "Cookies-journal", "Network/Cookies", "Network/Cookies-journal"]
        case (.chromium, .sessions):
            return ["Sessions", "Current Session", "Current Tabs", "Last Session", "Last Tabs"]
        case (.chromium, .formHistory):
            return [] // Chromium keeps autofill together with payment data ("Web Data"): never touched.
        case (.chromium, .siteData):
            return ["Local Storage", "Session Storage", "IndexedDB", "Service Worker"]
        case (.firefox, .history):
            return [] // places.sqlite also holds bookmarks: never touched (see PrivacyNotice).
        case (.firefox, .cookies):
            return ["cookies.sqlite", "cookies.sqlite-wal", "cookies.sqlite-shm"]
        case (.firefox, .sessions):
            return ["sessionstore.jsonlz4", "sessionstore-backups"]
        case (.firefox, .formHistory):
            return ["formhistory.sqlite", "formhistory.sqlite-wal", "formhistory.sqlite-shm"]
        case (.firefox, .siteData):
            return ["storage", "webappsstore.sqlite", "webappsstore.sqlite-wal"]
        }
    }

    /// Every last path component the privacy category may remove.
    public static let removableNames: Set<String> = {
        var names = Set<String>()
        for kind in BrowserDataKind.allCases {
            for engine in [Browser.Engine.chromium, .firefox] {
                for file in files(for: kind, engine: engine) { names.insert((file as NSString).lastPathComponent) }
            }
        }
        return names
    }()

    /// Folders that hold the profiles of every known browser.
    public func supportFolders() -> [String] {
        Self.browsers.map { (locations.applicationSupport as NSString).appendingPathComponent($0.supportPath) }
    }

    public func scan() throws -> PrivacyReport {
        let start = Date()
        var entries: [BrowserDataEntry] = []
        var notices: [PrivacyNotice] = []
        let tracker = InodeTracker()

        for browser in Self.browsers {
            let root = (locations.applicationSupport as NSString).appendingPathComponent(browser.supportPath)
            guard FileSystem.stat(root)?.type == .directory else { continue }
            for (profile, profilePath) in profiles(of: browser, root: root) {
                try Task.checkCancellationAsNoriaError()
                for kind in BrowserDataKind.allCases {
                    var items: [ScanItem] = []
                    for relative in Self.files(for: kind, engine: browser.engine) {
                        let path = (profilePath as NSString).appendingPathComponent(relative)
                        guard let stat = FileSystem.stat(path), stat.type == .file || stat.type == .directory else { continue }
                        let summary = try DirectorySizer().measure(path, tracker: tracker)
                        items.append(ScanItem(path: path, category: .privacy, risk: .review,
                                              reason: .browserData(browser: browser.name, kind: kind),
                                              allocatedSize: summary.allocatedSize, fileCount: max(summary.fileCount, 1),
                                              modificationDate: summary.newestModification ?? stat.modificationDate,
                                              bundleIdentifier: browser.bundleIdentifier, ownerName: browser.name,
                                              fingerprint: stat, requiresQuitting: browser.bundleIdentifier,
                                              group: "\(browser.name) · \(profile)"))
                    }
                    if !items.isEmpty {
                        entries.append(BrowserDataEntry(browser: browser, profile: profile, profilePath: profilePath,
                                                        kind: kind, items: items))
                    }
                }
                if browser.engine == .firefox {
                    let places = (profilePath as NSString).appendingPathComponent("places.sqlite")
                    if FileSystem.stat(places) != nil {
                        notices.append(PrivacyNotice(kind: .firefoxHistoryWithBookmarks, browserName: browser.name, path: places))
                    }
                }
            }
        }
        // Safari: ~/Library/Safari is protected by macOS (Full Disk Access) and Noria never modifies it.
        let safari = (locations.library as NSString).appendingPathComponent("Safari")
        if FileSystem.stat(safari) != nil {
            notices.append(PrivacyNotice(kind: .safariProtected, browserName: "Safari", path: safari))
        }
        return PrivacyReport(entries: entries, notices: notices, duration: Date().timeIntervalSince(start))
    }

    /// Profile folders: Chromium profiles contain a `Preferences` file (Opera keeps
    /// its main profile in the root folder); Firefox profiles contain `prefs.js`.
    func profiles(of browser: Browser, root: String) -> [(name: String, path: String)] {
        let marker = browser.engine == .chromium ? "Preferences" : "prefs.js"
        func isProfile(_ path: String) -> Bool {
            FileSystem.stat((path as NSString).appendingPathComponent(marker))?.type == .file
        }
        var result: [(String, String)] = []
        if browser.engine == .chromium, isProfile(root) { result.append((browser.name, root)) }
        for entry in (try? FileSystem.directoryEntries(root)) ?? [] where FileSystem.stat(entry.path)?.type == .directory {
            guard entry.name != "System Profile", entry.name != "Guest Profile", isProfile(entry.path) else { continue }
            // Firefox folder names are "<random>.<profile name>".
            let name = browser.engine == .firefox
                ? (entry.name.split(separator: ".", maxSplits: 1).last.map(String.init) ?? entry.name)
                : entry.name
            result.append((name, entry.path))
        }
        return result.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }
}
