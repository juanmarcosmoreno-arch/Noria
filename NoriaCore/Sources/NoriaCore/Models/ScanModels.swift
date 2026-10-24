import Foundation

/// Cleanup categories. Order defines the order in which Smart Scan runs them.
public enum CleanCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case userCache
    case logs
    case temporaryFiles
    case developerCache
    case downloads
    case trash
    /// Data left behind by apps that are no longer installed.
    case appLeftovers
    /// Local copies of Mail attachments and Mail Downloads.
    case mail
    /// Not part of Smart Scan; used for items removed from the Large Files module.
    case largeFiles
    /// Not part of Smart Scan; an installed app and its files, removed from App Remover.
    case appRemoval
    /// Not part of Smart Scan; extra copies of identical files, removed from Duplicates.
    case duplicates
    /// Not part of Smart Scan; browsing data removed from Privacy.
    case privacy

    public var id: String { rawValue }

    /// Categories included in Smart Scan.
    public static var smartScanCategories: [CleanCategory] {
        [.userCache, .logs, .temporaryFiles, .appLeftovers, .mail, .developerCache, .downloads, .trash]
    }
}

/// How risky it is to remove an item.
public enum RiskLevel: String, Codable, Sendable, CaseIterable, Comparable {
    /// Matched a verified rule: content is regenerated automatically or is disposable.
    case safe
    /// Probably disposable, but the user must decide.
    case review
    /// Must not be removed by Noria. Shown for transparency only.
    case protected

    private var order: Int {
        switch self {
        case .safe: return 0
        case .review: return 1
        case .protected: return 2
        }
    }

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.order < rhs.order }
}

/// Why an item was reported. The UI turns each case into a localized explanation.
public enum ItemReason: Codable, Sendable, Hashable {
    /// A cache in Noria's verified catalog. `tool` is a human-readable app/tool name.
    case knownRegenerableCache(tool: String)
    /// A third-party cache folder not in the verified catalog.
    case thirdPartyCache
    /// A cache owned by macOS or an Apple app.
    case systemCache
    /// A log or diagnostic report not modified for `days` days.
    case oldLog(days: Int)
    /// A temporary item not modified for `days` days.
    case oldTemporary(days: Int)
    /// A disk image or installer package in Downloads.
    case oldInstaller(days: Int)
    /// A compressed archive in Downloads.
    case oldArchive(days: Int)
    /// Any other old download.
    case oldDownload(days: Int)
    /// Xcode build products, rebuilt on the next build.
    case xcodeDerivedData
    /// Xcode archives: needed to symbolicate crashes or re-export builds.
    case xcodeArchive
    /// Device support files, re-created when the device is connected again.
    case xcodeDeviceSupport
    /// Package-manager download cache (npm, pip, Homebrew…).
    case packageManagerCache(tool: String, officialCommand: String?)
    /// Content of the Trash; emptied from Finder.
    case trashContents
    /// A large file found by the Large Files scanner.
    case largeFile
    /// Inside a location Noria never modifies (app containers, iCloud, libraries…).
    case protectedLocation
    /// Data of an app that is not installed any more (matched by bundle identifier).
    case appLeftover(kind: AppDataKind, bundleIdentifier: String)
    /// A file or folder that belongs to an installed app (App Remover).
    case appData(kind: AppDataKind, match: AppFileMatch)
    /// The application bundle itself.
    case applicationBundle
    /// Attachments Mail downloaded from a server account; Mail downloads them again when needed.
    case mailServerAttachments(account: String)
    /// Attachments stored only on this Mac (POP or local mailboxes, or unknown account type).
    case mailLocalAttachments(account: String)
    /// Copies Mail made when you opened attachments.
    case mailDownloads
    /// An identical copy of another file (same SHA-256).
    case duplicateCopy
    /// An item selected in the Space Map.
    case spaceMapSelection
    /// A developer tool's data (see `DeveloperTool.Kind` raw values).
    case developerItem(tool: String)
    /// Browsing data of a browser profile (Privacy).
    case browserData(browser: String, kind: BrowserDataKind)
}

/// Kind of per-app data in `~/Library`.
public enum AppDataKind: String, Codable, Sendable, CaseIterable {
    case applicationSupport, cache, preferences, container, groupContainer
    case savedState, logs, webData, scripts, launchAgent
}

/// How a file was associated with an app.
public enum AppFileMatch: String, Codable, Sendable {
    /// The name is the app's bundle identifier (or starts with it): reliable.
    case bundleIdentifier
    /// The folder has the same name as the app: probable, not certain.
    case appName
    /// A group container shared by several apps of the same developer.
    case sharedGroup
}

/// What Noria can do with an item.
public enum ItemAction: String, Codable, Sendable {
    /// Can be selected and removed through the cleaning engine.
    case remove
    /// Shown for information; the user acts elsewhere (e.g. empty Trash in Finder).
    case informational
}

/// A file or folder found by a scan.
public struct ScanItem: Identifiable, Sendable, Hashable, Codable {
    public var id: UUID
    /// Canonical absolute path at scan time.
    public var path: String
    public var name: String
    public var category: CleanCategory
    public var risk: RiskLevel
    public var reason: ItemReason
    public var action: ItemAction
    /// Bytes allocated on disk (hard links counted once per scan).
    public var allocatedSize: Int64
    /// Number of regular files contained (1 for a file).
    public var fileCount: Int
    public var modificationDate: Date?
    /// Reverse-DNS identifier when the name looks like one (e.g. `com.spotify.client`).
    public var bundleIdentifier: String?
    /// Human-readable owner when known from the rule catalog.
    public var ownerName: String?
    /// Identity captured at scan time; the cleaning engine refuses to act if it changed.
    public var fingerprint: FileStat?
    /// The app (bundle identifier) that must not be running while this item is removed.
    public var requiresQuitting: String?
    /// Optional grouping label (e.g. the Mail account) used by the UI.
    public var group: String?

    public init(
        id: UUID = UUID(),
        path: String,
        name: String? = nil,
        category: CleanCategory,
        risk: RiskLevel,
        reason: ItemReason,
        action: ItemAction = .remove,
        allocatedSize: Int64,
        fileCount: Int,
        modificationDate: Date?,
        bundleIdentifier: String? = nil,
        ownerName: String? = nil,
        fingerprint: FileStat?,
        requiresQuitting: String? = nil,
        group: String? = nil
    ) {
        self.id = id
        self.path = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
        self.category = category
        self.risk = risk
        self.reason = reason
        self.action = action
        self.allocatedSize = allocatedSize
        self.fileCount = fileCount
        self.modificationDate = modificationDate
        self.bundleIdentifier = bundleIdentifier
        self.ownerName = ownerName
        self.fingerprint = fingerprint
        self.requiresQuitting = requiresQuitting
        self.group = group
    }

    /// Whether the user may select this item for removal.
    public var isSelectable: Bool { action == .remove && risk != .protected }

    public var url: URL { URL(fileURLWithPath: path) }
}

/// Result of scanning one category.
public struct CategoryResult: Sendable, Identifiable {
    public var category: CleanCategory
    public var items: [ScanItem]
    /// Paths that could not be read (permissions, TCC). Capped to keep memory bounded.
    public var inaccessiblePaths: [String]
    public var inaccessibleCount: Int
    /// `false` when the category root does not exist on this Mac.
    public var locationExists: Bool
    public var duration: TimeInterval

    public var id: CleanCategory { category }

    public init(category: CleanCategory, items: [ScanItem], inaccessiblePaths: [String] = [], inaccessibleCount: Int = 0, locationExists: Bool = true, duration: TimeInterval = 0) {
        self.category = category
        self.items = items
        self.inaccessiblePaths = inaccessiblePaths
        self.inaccessibleCount = inaccessibleCount
        self.locationExists = locationExists
        self.duration = duration
    }

    public var totalSize: Int64 { items.reduce(0) { $0 + $1.allocatedSize } }

    public func size(for risk: RiskLevel) -> Int64 {
        items.filter { $0.risk == risk && $0.action == .remove }.reduce(0) { $0 + $1.allocatedSize }
    }
}

/// Complete result of a Smart Scan.
public struct ScanReport: Sendable {
    public var startedAt: Date
    public var finishedAt: Date
    public var categories: [CategoryResult]

    public init(startedAt: Date, finishedAt: Date, categories: [CategoryResult]) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.categories = categories
    }

    public var allItems: [ScanItem] { categories.flatMap(\.items) }

    /// Bytes that Noria could remove (safe + review, excluding informational items).
    public var recoverableSize: Int64 {
        allItems.filter(\.isSelectable).reduce(0) { $0 + $1.allocatedSize }
    }

    public var safeSize: Int64 {
        allItems.filter { $0.isSelectable && $0.risk == .safe }.reduce(0) { $0 + $1.allocatedSize }
    }

    public var fileCount: Int { allItems.reduce(0) { $0 + $1.fileCount } }
}

/// Events emitted while a Smart Scan runs.
public enum ScanEvent: Sendable {
    case categoryStarted(CleanCategory, index: Int, total: Int)
    /// Running counters for the current category. Total work is unknown, so there is no percentage.
    case progress(CleanCategory, filesVisited: Int, bytesFound: Int64)
    case categoryFinished(CategoryResult)
    case finished(ScanReport)
}
