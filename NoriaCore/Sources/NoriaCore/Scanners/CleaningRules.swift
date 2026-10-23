import Foundation

/// Everything a rule needs to produce candidates.
public struct ScanContext: Sendable {
    public var locations: SystemLocations
    public var settings: NoriaSettings
    public var policy: SafetyPolicy
    public var tracker: InodeTracker
    public var now: Date
    /// Reports files visited since the last call (throttled by the sizer).
    public var reportProgress: @Sendable (_ filesVisited: Int, _ bytesFound: Int64) -> Void

    public init(
        locations: SystemLocations,
        settings: NoriaSettings,
        tracker: InodeTracker = InodeTracker(),
        now: Date = Date(),
        reportProgress: @escaping @Sendable (Int, Int64) -> Void = { _, _ in }
    ) {
        self.locations = locations
        self.settings = settings
        self.policy = SafetyPolicy(locations: locations, exclusions: settings.exclusions)
        self.tracker = tracker
        self.now = now
        self.reportProgress = reportProgress
    }

    func ageInDays(_ date: Date?) -> Int {
        guard let date else { return 0 }
        return max(0, Int(now.timeIntervalSince(date) / 86_400))
    }

    /// Measures a node and builds a `ScanItem`. Returns `nil` for empty folders.
    func makeItem(
        path: String,
        stat: FileStat,
        category: CleanCategory,
        risk: RiskLevel,
        reason: ItemReason,
        action: ItemAction = .remove,
        ownerName: String? = nil,
        result: inout RuleOutput
    ) throws -> ScanItem? {
        var size: Int64
        var count: Int
        var newest: Date? = stat.modificationDate
        if stat.type == .directory {
            let summary = try DirectorySizer().measure(path, tracker: tracker) { visited in
                reportProgress(visited, 0)
            }
            result.recordInaccessible(summary)
            size = summary.allocatedSize
            count = summary.fileCount
            // A folder's own date changes whenever an entry is added or removed, so the
            // age of a folder is the age of the newest file inside it.
            newest = summary.newestModification ?? stat.modificationDate
            guard count > 0 else { return nil }
        } else {
            guard tracker.firstVisit(stat) else { return nil }
            size = stat.allocatedSize
            count = 1
        }
        guard size > 0 else { return nil }
        var finalRisk = risk
        var finalReason = reason
        if policy.protectionReason(for: path) != nil {
            finalRisk = .protected
            finalReason = .protectedLocation
        }
        let name = (path as NSString).lastPathComponent
        let item = ScanItem(
            path: path,
            category: category,
            risk: finalRisk,
            reason: finalReason,
            action: action,
            allocatedSize: size,
            fileCount: count,
            modificationDate: newest,
            bundleIdentifier: Self.bundleIdentifierGuess(name),
            ownerName: ownerName,
            fingerprint: stat
        )
        reportProgress(0, size)
        return item
    }

    /// Returns `name` when it looks like a reverse-DNS bundle identifier.
    static func bundleIdentifierGuess(_ name: String) -> String? {
        let parts = name.split(separator: ".")
        guard parts.count >= 3,
              ["com", "org", "net", "io", "de", "co", "app", "dev", "us", "uk", "fr", "es", "jp"].contains(parts[0].lowercased()),
              !name.contains(" ") else { return nil }
        return name
    }
}

/// Accumulates a rule's output.
public struct RuleOutput: Sendable {
    public var items: [ScanItem] = []
    public var inaccessibleCount = 0
    public var inaccessiblePaths: [String] = []
    public var locationExists = true

    mutating func recordInaccessible(_ summary: WalkSummary) {
        inaccessibleCount += summary.inaccessibleCount
        for path in summary.inaccessiblePaths where inaccessiblePaths.count < 50 {
            inaccessiblePaths.append(path)
        }
    }

    mutating func recordInaccessible(_ path: String) {
        inaccessibleCount += 1
        if inaccessiblePaths.count < 50 { inaccessiblePaths.append(path) }
    }
}

/// A scanning rule for one category. Rules only read; they never modify anything.
public protocol CleaningRule: Sendable {
    var category: CleanCategory { get }
    func scan(_ context: ScanContext) throws -> RuleOutput
}

extension CleaningRule {
    /// Lists the children of `root`, skipping excluded paths. Records failures.
    func children(of root: String, context: ScanContext, output: inout RuleOutput) -> [(String, FileStat)]? {
        guard FileSystem.stat(root)?.type == .directory else {
            output.locationExists = false
            return nil
        }
        do {
            return try FileSystem.directoryEntries(root)
                .filter { !context.policy.isExcluded($0.path) }
                .compactMap { entry in FileSystem.stat(entry.path).map { (entry.path, $0) } }
                .sorted { $0.0 < $1.0 }
        } catch {
            output.recordInaccessible(root)
            return nil
        }
    }

    func checkCancellation() throws {
        if Task.isCancelled { throw NoriaError.cancelled }
    }
}

// MARK: - Verified cache catalog

/// A cache location verified to be regenerated automatically by its owner.
public struct KnownCache: Sendable {
    /// Name of the folder directly inside `~/Library/Caches`.
    public var folderName: String
    public var owner: String
    public var category: CleanCategory
    public var officialCommand: String?
}

public enum KnownCaches {
    /// Kept intentionally small: an entry is added only when its owner documents
    /// that the content is a re-downloadable / rebuildable cache.
    public static let catalog: [KnownCache] = [
        KnownCache(folderName: "Homebrew", owner: "Homebrew", category: .developerCache, officialCommand: "brew cleanup --prune=all"),
        KnownCache(folderName: "pip", owner: "pip", category: .developerCache, officialCommand: "pip cache purge"),
        KnownCache(folderName: "Yarn", owner: "Yarn", category: .developerCache, officialCommand: "yarn cache clean"),
        KnownCache(folderName: "CocoaPods", owner: "CocoaPods", category: .developerCache, officialCommand: "pod cache clean --all"),
        KnownCache(folderName: "go-build", owner: "Go", category: .developerCache, officialCommand: "go clean -cache"),
        KnownCache(folderName: "com.microsoft.VSCode.ShipIt", owner: "Visual Studio Code (updates)", category: .userCache, officialCommand: nil),
        KnownCache(folderName: "com.spotify.client", owner: "Spotify", category: .userCache, officialCommand: nil),
        KnownCache(folderName: "Google", owner: "Google Chrome", category: .userCache, officialCommand: nil),
        KnownCache(folderName: "Firefox", owner: "Firefox", category: .userCache, officialCommand: nil),
        KnownCache(folderName: "com.operasoftware.Opera", owner: "Opera", category: .userCache, officialCommand: nil),
        KnownCache(folderName: "BraveSoftware", owner: "Brave", category: .userCache, officialCommand: nil),
        KnownCache(folderName: "Microsoft Edge", owner: "Microsoft Edge", category: .userCache, officialCommand: nil),
        KnownCache(folderName: "node-gyp", owner: "node-gyp", category: .developerCache, officialCommand: nil),
        KnownCache(folderName: "typescript", owner: "TypeScript", category: .developerCache, officialCommand: nil),
    ]

    public static func entry(named name: String) -> KnownCache? {
        catalog.first { $0.folderName == name }
    }
}

// MARK: - User cache

/// One item per folder in `~/Library/Caches`. Only catalogued caches are SAFE;
/// other third-party caches are REVIEW; Apple caches are PROTECTED.
public struct UserCacheRule: CleaningRule {
    public let category = CleanCategory.userCache
    public init() {}

    public func scan(_ context: ScanContext) throws -> RuleOutput {
        var output = RuleOutput()
        guard let entries = children(of: context.locations.caches, context: context, output: &output) else { return output }
        for (path, stat) in entries {
            try checkCancellation()
            let name = (path as NSString).lastPathComponent
            let known = KnownCaches.entry(named: name)
            if known?.category == .developerCache { continue } // reported by DeveloperCacheRule
            let risk: RiskLevel
            let reason: ItemReason
            if name.hasPrefix("com.apple.") || name == "CloudKit" || name == "FamilyCircle" || name.hasPrefix("group.com.apple") {
                risk = .protected
                reason = .systemCache
            } else if let known {
                risk = .safe
                reason = .knownRegenerableCache(tool: known.owner)
            } else {
                risk = .review
                reason = .thirdPartyCache
            }
            if let item = try context.makeItem(path: path, stat: stat, category: category, risk: risk, reason: reason, ownerName: known?.owner, result: &output) {
                output.items.append(item)
            }
        }
        return output
    }
}

// MARK: - Logs

/// Individual log files in `~/Library/Logs` older than the configured age.
public struct LogsRule: CleaningRule {
    public let category = CleanCategory.logs
    public init() {}

    public func scan(_ context: ScanContext) throws -> RuleOutput {
        var output = RuleOutput()
        let root = context.locations.logs
        guard FileSystem.stat(root)?.type == .directory else {
            output.locationExists = false
            return output
        }
        let minimumAge = context.settings.logsMinimumAgeDays
        var candidates: [(String, FileStat)] = []
        var options = WalkOptions()
        options.skippedPaths = context.policy.exclusions
        let summary = try FileWalker(options: options).walk(root: root) { path, stat in
            if stat.type == .file, context.ageInDays(stat.modificationDate) >= minimumAge {
                candidates.append((path, stat))
            }
            return .continue
        }
        output.recordInaccessible(summary)
        context.reportProgress(summary.filesVisited, 0)
        for (path, stat) in candidates {
            try checkCancellation()
            let days = context.ageInDays(stat.modificationDate)
            if let item = try context.makeItem(path: path, stat: stat, category: category, risk: .safe, reason: .oldLog(days: days), result: &output) {
                output.items.append(item)
            }
        }
        return output
    }
}

// MARK: - Temporary files

/// Old items in the per-user temporary folder. macOS already purges it
/// periodically, so items are REVIEW and Apple items are skipped.
public struct TemporaryFilesRule: CleaningRule {
    public let category = CleanCategory.temporaryFiles
    public init() {}

    public func scan(_ context: ScanContext) throws -> RuleOutput {
        var output = RuleOutput()
        guard let entries = children(of: context.locations.temporary, context: context, output: &output) else { return output }
        let minimumAge = context.settings.temporaryMinimumAgeDays
        for (path, stat) in entries {
            try checkCancellation()
            let name = (path as NSString).lastPathComponent
            if name.hasPrefix("com.apple.") || name.hasPrefix(".") { continue }
            guard stat.type == .file || stat.type == .directory else { continue }
            // Use the newest modification inside a folder, not the folder's own date.
            guard var item = try context.makeItem(path: path, stat: stat, category: category, risk: .review, reason: .oldTemporary(days: 0), result: &output) else { continue }
            let days = context.ageInDays(item.modificationDate)
            guard days >= minimumAge else { continue }
            item.reason = .oldTemporary(days: days)
            output.items.append(item)
        }
        return output
    }
}

// MARK: - Downloads

public enum DownloadKind: Sendable {
    case installer
    case archive
    case other

    public static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip", "exe", "msi"]
    public static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "rar", "7z", "zst", "tbz", "txz"]

    public static func classify(_ path: String) -> DownloadKind {
        let ext = (path as NSString).pathExtension.lowercased()
        if installerExtensions.contains(ext) { return .installer }
        if archiveExtensions.contains(ext) { return .archive }
        return .other
    }
}

/// Top-level items in `~/Downloads`: installers and archives older than the
/// configured age, and other items older than a year. Always REVIEW: they are user files.
public struct DownloadsRule: CleaningRule {
    public let category = CleanCategory.downloads
    public static let otherItemsMinimumAgeDays = 365
    public init() {}

    public func scan(_ context: ScanContext) throws -> RuleOutput {
        var output = RuleOutput()
        guard let entries = children(of: context.locations.downloads, context: context, output: &output) else { return output }
        let minimumAge = context.settings.downloadsMinimumAgeDays
        for (path, stat) in entries {
            try checkCancellation()
            let name = (path as NSString).lastPathComponent
            if name.hasPrefix(".") { continue } // .localized, .DS_Store
            let days = context.ageInDays(stat.modificationDate)
            let kind = stat.type == .file ? DownloadKind.classify(path) : .other
            let reason: ItemReason
            switch kind {
            case .installer where days >= minimumAge: reason = .oldInstaller(days: days)
            case .archive where days >= minimumAge: reason = .oldArchive(days: days)
            case .other where days >= Self.otherItemsMinimumAgeDays: reason = .oldDownload(days: days)
            default: continue
            }
            guard var item = try context.makeItem(path: path, stat: stat, category: category, risk: .review, reason: reason, result: &output) else { continue }
            // A folder counts as old only if nothing inside changed recently.
            if stat.type == .directory, context.ageInDays(item.modificationDate) < Self.otherItemsMinimumAgeDays { continue }
            item.bundleIdentifier = nil
            output.items.append(item)
        }
        return output
    }
}

// MARK: - Trash

/// Reports the size of the Trash. Informational in Phase 1: emptying is done in Finder.
/// Reading `~/.Trash` requires Full Disk Access on recent macOS versions.
public struct TrashRule: CleaningRule {
    public let category = CleanCategory.trash
    public init() {}

    public func scan(_ context: ScanContext) throws -> RuleOutput {
        var output = RuleOutput()
        let root = context.locations.trash
        guard let stat = FileSystem.stat(root), stat.type == .directory else {
            output.locationExists = false
            return output
        }
        do {
            _ = try FileSystem.directoryEntries(root)
        } catch {
            output.recordInaccessible(root)
            return output
        }
        if let item = try context.makeItem(path: root, stat: stat, category: category, risk: .review, reason: .trashContents, action: .informational, result: &output) {
            output.items.append(item)
        }
        return output
    }
}

// MARK: - Developer caches

/// Xcode DerivedData (per project), Xcode archives and device support, and
/// package-manager caches.
public struct DeveloperCacheRule: CleaningRule {
    public let category = CleanCategory.developerCache
    public init() {}

    public func scan(_ context: ScanContext) throws -> RuleOutput {
        var output = RuleOutput()
        let locations = context.locations
        var anyLocation = false

        func addChildren(of root: String, risk: RiskLevel, reason: ItemReason, owner: String) throws {
            var local = RuleOutput()
            guard let entries = children(of: root, context: context, output: &local) else {
                output.inaccessibleCount += local.inaccessibleCount
                output.inaccessiblePaths += local.inaccessiblePaths
                return
            }
            anyLocation = true
            for (path, stat) in entries {
                try checkCancellation()
                if (path as NSString).lastPathComponent.hasPrefix(".") && stat.type == .file { continue }
                if let item = try context.makeItem(path: path, stat: stat, category: category, risk: risk, reason: reason, ownerName: owner, result: &output) {
                    output.items.append(item)
                }
            }
        }

        func addWhole(_ path: String, owner: String, command: String?) throws {
            guard !context.policy.isExcluded(path), let stat = FileSystem.stat(path), stat.type == .directory else { return }
            anyLocation = true
            try checkCancellation()
            if let item = try context.makeItem(path: path, stat: stat, category: category, risk: .safe,
                                               reason: .packageManagerCache(tool: owner, officialCommand: command),
                                               ownerName: owner, result: &output) {
                output.items.append(item)
            }
        }

        try addChildren(of: locations.derivedData, risk: .safe, reason: .xcodeDerivedData, owner: "Xcode")
        try addChildren(of: locations.xcodeArchives, risk: .review, reason: .xcodeArchive, owner: "Xcode")
        try addChildren(of: locations.iOSDeviceSupport, risk: .review, reason: .xcodeDeviceSupport, owner: "Xcode")
        try addWhole(locations.npmCache, owner: "npm", command: "npm cache clean --force")
        for known in KnownCaches.catalog where known.category == .developerCache {
            let path = (locations.caches as NSString).appendingPathComponent(known.folderName)
            try addWhole(path, owner: known.owner, command: known.officialCommand)
        }
        output.locationExists = anyLocation
        return output
    }
}
