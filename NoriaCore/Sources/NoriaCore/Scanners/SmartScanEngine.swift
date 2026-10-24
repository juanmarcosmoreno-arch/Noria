import Foundation

/// Runs the cleaning rules off the main thread and streams progress.
///
/// The scan is read-only. Cancelling the consuming task (or breaking out of the
/// `for await` loop) cancels the scan.
public struct SmartScanEngine: Sendable {
    public var locations: SystemLocations
    public var rules: [any CleaningRule]
    /// Installed apps; `nil` builds the registry from the Applications folders at scan time.
    public var appRegistry: InstalledAppRegistry?
    /// Mail account types; `nil` reads the macOS accounts database at scan time.
    public var mailAccounts: (any MailAccountResolving)?
    /// Extra "is this app installed?" lookup used when the registry is built at scan time.
    public var appLookup: (@Sendable (String) -> Bool)?

    public static let defaultRules: [any CleaningRule] = [
        UserCacheRule(), LogsRule(), TemporaryFilesRule(), AppLeftoversRule(), MailRule(),
        DeveloperCacheRule(), DownloadsRule(), TrashRule(),
    ]

    public init(locations: SystemLocations = .current, rules: [any CleaningRule] = SmartScanEngine.defaultRules,
                appRegistry: InstalledAppRegistry? = nil, mailAccounts: (any MailAccountResolving)? = nil,
                appLookup: (@Sendable (String) -> Bool)? = nil) {
        self.locations = locations
        self.rules = rules
        self.appRegistry = appRegistry
        self.mailAccounts = mailAccounts
        self.appLookup = appLookup
    }

    public func scan(settings: NoriaSettings) -> AsyncThrowingStream<ScanEvent, Error> {
        let rules = self.rules.filter { settings.enabledCategories.contains($0.category) }
        let locations = self.locations
        let suppliedRegistry = appRegistry
        let suppliedMailAccounts = mailAccounts
        let appLookup = self.appLookup
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task.detached(priority: .utility) {
                let startedAt = Date()
                let tracker = InodeTracker()
                let registry = suppliedRegistry
                    ?? InstalledAppRegistry(apps: AppInventory.scan(roots: AppInventory.registryRoots(locations)), externalLookup: appLookup)
                let mailAccounts = suppliedMailAccounts ?? AccountsDatabaseResolver(databasePath: locations.accountsDatabase)
                var results: [CategoryResult] = []
                var claimed: [String] = []
                do {
                    for (index, rule) in rules.enumerated() {
                        try Task.checkCancellation()
                        let category = rule.category
                        continuation.yield(.categoryStarted(category, index: index, total: rules.count))
                        let counters = ProgressCounters()
                        let context = ScanContext(locations: locations, settings: settings, tracker: tracker,
                                                  appRegistry: registry, mailAccounts: mailAccounts) { files, bytes in
                            let snapshot = counters.add(files: files, bytes: bytes)
                            continuation.yield(.progress(category, filesVisited: snapshot.files, bytesFound: snapshot.bytes))
                        }
                        let ruleStart = Date()
                        let output: RuleOutput
                        do {
                            output = try rule.scan(context)
                        } catch NoriaError.cancelled {
                            throw CancellationError()
                        }
                        let items = Self.removingOverlaps(output.items, claimed: &claimed)
                        let result = CategoryResult(
                            category: category,
                            items: items.sorted { $0.allocatedSize > $1.allocatedSize },
                            inaccessiblePaths: output.inaccessiblePaths,
                            inaccessibleCount: output.inaccessibleCount,
                            locationExists: output.locationExists,
                            duration: Date().timeIntervalSince(ruleStart)
                        )
                        results.append(result)
                        continuation.yield(.categoryFinished(result))
                    }
                    continuation.yield(.finished(ScanReport(startedAt: startedAt, finishedAt: Date(), categories: results)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Drops items equal to, inside, or containing an item already reported, so
    /// no byte is offered twice across categories.
    static func removingOverlaps(_ items: [ScanItem], claimed: inout [String]) -> [ScanItem] {
        var kept: [ScanItem] = []
        for item in items.sorted(by: { $0.path < $1.path }) {
            let overlaps = claimed.contains { item.path.isSameOrDescendant(of: $0) || $0.isSameOrDescendant(of: item.path) }
            if overlaps { continue }
            claimed.append(item.path)
            kept.append(item)
        }
        return kept
    }
}

/// Thread-safe running totals for progress events.
final class ProgressCounters: @unchecked Sendable {
    private var files = 0
    private var bytes: Int64 = 0
    private let lock = NSLock()

    func add(files: Int, bytes: Int64) -> (files: Int, bytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        self.files += files
        self.bytes += bytes
        return (self.files, self.bytes)
    }
}
