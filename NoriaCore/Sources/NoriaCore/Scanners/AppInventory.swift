import Foundation

/// An application bundle found on disk.
public struct InstalledApp: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var bundleIdentifier: String?
    public var version: String?
    /// Built by Apple (bundle identifier `com.apple.*`). Never removable by Noria.
    public var isApple: Bool
    /// Installed from the Mac App Store (has a receipt).
    public var isFromAppStore: Bool
    public var modificationDate: Date?
}

/// Lists installed applications by reading their `Info.plist`.
public enum AppInventory {
    /// Reads one `.app` bundle. Returns `nil` if it is not a readable app bundle.
    public static func readApp(at path: String) -> InstalledApp? {
        guard (path as NSString).pathExtension == "app", let stat = FileSystem.stat(path), stat.type == .directory else { return nil }
        let plistPath = (path as NSString).appendingPathComponent("Contents/Info.plist")
        let info = FileManager.default.contents(atPath: plistPath)
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let identifier = info["CFBundleIdentifier"] as? String
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? fileName
        let receipt = (path as NSString).appendingPathComponent("Contents/_MASReceipt/receipt")
        return InstalledApp(
            path: path,
            name: name.isEmpty ? fileName : name,
            bundleIdentifier: identifier,
            version: info["CFBundleShortVersionString"] as? String,
            isApple: identifier?.lowercased().hasPrefix("com.apple.") ?? false,
            isFromAppStore: FileSystem.stat(receipt) != nil,
            modificationDate: stat.modificationDate
        )
    }

    /// Apps directly inside each root and one folder level below
    /// (e.g. `/Applications/Utilities/X.app`, `/Applications/Adobe/X.app`).
    public static func scan(roots: [String]) -> [InstalledApp] {
        var apps: [InstalledApp] = []
        var seen = Set<String>()
        for root in roots {
            guard let entries = try? FileSystem.directoryEntries(root) else { continue }
            for entry in entries {
                if let app = readApp(at: entry.path) {
                    if seen.insert(app.path).inserted { apps.append(app) }
                } else if FileSystem.stat(entry.path)?.type == .directory, !FileWalker.isPackage(entry.path),
                          let nested = try? FileSystem.directoryEntries(entry.path) {
                    for child in nested {
                        if let app = readApp(at: child.path), seen.insert(app.path).inserted { apps.append(app) }
                    }
                }
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Folders searched to decide whether an app is still installed (includes Apple's).
    public static func registryRoots(_ locations: SystemLocations) -> [String] {
        locations.applicationFolders + ["/System/Applications", "/System/Library/CoreServices"]
    }
}

/// Answers "is the app with this bundle identifier still installed?" conservatively:
/// when in doubt, the answer is yes, so its data is not offered as a leftover.
public struct InstalledAppRegistry: Sendable {
    public var bundleIdentifiers: Set<String>
    /// Additional lookup (the app uses Launch Services, which knows apps anywhere on disk).
    public var externalLookup: (@Sendable (String) -> Bool)?

    public init(bundleIdentifiers: Set<String>, externalLookup: (@Sendable (String) -> Bool)? = nil) {
        self.bundleIdentifiers = Set(bundleIdentifiers.map { $0.lowercased() })
        self.externalLookup = externalLookup
    }

    public init(apps: [InstalledApp], externalLookup: (@Sendable (String) -> Bool)? = nil) {
        self.init(bundleIdentifiers: Set(apps.compactMap(\.bundleIdentifier)), externalLookup: externalLookup)
    }

    public static let empty = InstalledAppRegistry(bundleIdentifiers: [])

    /// The developer part of an identifier: `com.google.Chrome` → `com.google`.
    static func vendor(of identifier: String) -> String {
        identifier.split(separator: ".").prefix(2).joined(separator: ".")
    }

    public func isInstalled(_ identifier: String) -> Bool {
        let id = identifier.lowercased()
        if bundleIdentifiers.contains(id) { return true }
        // Helpers and extensions (com.foo.app.helper) and parent identifiers.
        if bundleIdentifiers.contains(where: { id.hasPrefix($0 + ".") || $0.hasPrefix(id + ".") }) { return true }
        // Another app from the same developer is installed: the data may be shared with it.
        let vendor = Self.vendor(of: id)
        if bundleIdentifiers.contains(where: { Self.vendor(of: $0) == vendor }) { return true }
        return externalLookup?(identifier) ?? false
    }
}

// MARK: - Per-app data locations

/// One `~/Library` location where apps keep data, and how entries are named there.
struct AppDataLocation: Sendable {
    var root: String
    var kind: AppDataKind
    /// Suffixes removed from entry names before comparing with a bundle identifier.
    var suffixes: [String] = []
    /// Whether a folder named exactly like the app counts (probable match).
    var matchesAppName = false

    static func all(_ locations: SystemLocations, includingCaches: Bool, includingGroups: Bool) -> [AppDataLocation] {
        var result = [
            AppDataLocation(root: locations.applicationSupport, kind: .applicationSupport, matchesAppName: true),
            AppDataLocation(root: locations.preferences, kind: .preferences, suffixes: [".plist"]),
            AppDataLocation(root: locations.byHostPreferences, kind: .preferences, suffixes: [".plist"]),
            AppDataLocation(root: locations.containers, kind: .container),
            AppDataLocation(root: locations.savedApplicationState, kind: .savedState, suffixes: [".savedState"]),
            AppDataLocation(root: locations.logs, kind: .logs, matchesAppName: true),
            AppDataLocation(root: locations.httpStorages, kind: .webData, suffixes: [".binarycookies"]),
            AppDataLocation(root: locations.webKit, kind: .webData),
            AppDataLocation(root: locations.applicationScripts, kind: .scripts),
            AppDataLocation(root: locations.launchAgents, kind: .launchAgent, suffixes: [".plist"]),
        ]
        if includingCaches {
            result.append(AppDataLocation(root: locations.caches, kind: .cache, matchesAppName: true))
        }
        if includingGroups {
            result.append(AppDataLocation(root: locations.groupContainers, kind: .groupContainer))
        }
        return result
    }

    /// The identifier-like part of an entry name: strips known suffixes and a
    /// trailing host UUID (`com.foo.app.0A1B2C….plist` in ByHost).
    func identifierPart(of name: String) -> String {
        var base = name
        for suffix in suffixes where base.lowercased().hasSuffix(suffix.lowercased()) {
            base = String(base.dropLast(suffix.count))
        }
        if kind == .preferences, let last = base.split(separator: ".").last,
           last.count >= 12, last.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            base = String(base.dropLast(last.count + 1))
        }
        return base
    }
}

// MARK: - Related files of an installed app (App Remover)

public enum AppFilesFinder {
    /// The app bundle plus every `~/Library` item that belongs to it.
    /// Exact bundle-identifier matches are reliable; name matches and shared
    /// group containers are marked REVIEW and are never preselected by the UI.
    public static func relatedItems(for app: InstalledApp, context: ScanContext) throws -> [ScanItem] {
        var output = RuleOutput()
        var items: [ScanItem] = []
        let quit = app.bundleIdentifier

        if let stat = FileSystem.stat(app.path),
           var bundle = try context.makeItem(path: app.path, stat: stat, category: .appRemoval, risk: app.isApple ? .protected : .safe,
                                             reason: .applicationBundle, ownerName: app.name, result: &output) {
            bundle.name = app.name
            bundle.bundleIdentifier = app.bundleIdentifier
            bundle.requiresQuitting = quit
            items.append(bundle)
        }
        guard let identifier = app.bundleIdentifier?.lowercased(), !app.isApple else { return items }
        let appName = app.name.lowercased()
        let fileName = ((app.path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()

        for location in AppDataLocation.all(context.locations, includingCaches: true, includingGroups: true) {
            guard let entries = try? FileSystem.directoryEntries(location.root) else { continue }
            for entry in entries.sorted(by: { $0.name < $1.name }) {
                try Task.checkCancellationAsNoriaError()
                if context.policy.isExcluded(entry.path) { continue }
                let lowered = entry.name.lowercased()
                let candidate = location.identifierPart(of: entry.name).lowercased()
                let match: AppFileMatch
                if location.kind == .groupContainer {
                    guard lowered.hasSuffix("." + identifier) || lowered.contains("." + identifier + ".") else { continue }
                    match = .sharedGroup
                } else if candidate == identifier || candidate.hasPrefix(identifier + ".") {
                    match = .bundleIdentifier
                } else if location.matchesAppName, lowered == appName || lowered == fileName {
                    match = .appName
                } else {
                    continue
                }
                guard let stat = FileSystem.stat(entry.path) else { continue }
                let risk = Self.risk(kind: location.kind, match: match)
                if var item = try context.makeItem(path: entry.path, stat: stat, category: .appRemoval, risk: risk,
                                                   reason: .appData(kind: location.kind, match: match),
                                                   ownerName: app.name, result: &output) {
                    item.requiresQuitting = quit
                    item.group = location.kind.rawValue
                    items.append(item)
                }
            }
        }
        return items
    }

    /// Disposable data (caches, logs, window state, preferences, launchers) is SAFE when
    /// matched by identifier; data that may hold the user's work is REVIEW.
    static func risk(kind: AppDataKind, match: AppFileMatch) -> RiskLevel {
        guard match == .bundleIdentifier else { return .review }
        switch kind {
        case .cache, .logs, .savedState, .webData, .preferences, .launchAgent: return .safe
        case .applicationSupport, .container, .groupContainer, .scripts: return .review
        }
    }
}

// MARK: - Leftovers of uninstalled apps (Smart Scan)

/// Data in `~/Library` named after a bundle identifier whose app is no longer
/// installed. Always REVIEW: Noria cannot be certain the app is gone for good.
public struct AppLeftoversRule: CleaningRule {
    public let category = CleanCategory.appLeftovers
    public init() {}

    public func scan(_ context: ScanContext) throws -> RuleOutput {
        var output = RuleOutput()
        var anyLocation = false
        // Caches of removed apps are already reported by the User Cache rule; group
        // containers are shared between apps and never treated as leftovers.
        for location in AppDataLocation.all(context.locations, includingCaches: false, includingGroups: false) {
            guard FileSystem.stat(location.root)?.type == .directory else { continue }
            anyLocation = true
            let entries: [DirectoryEntry]
            do {
                entries = try FileSystem.directoryEntries(location.root)
            } catch {
                output.recordInaccessible(location.root)
                continue
            }
            for entry in entries.sorted(by: { $0.name < $1.name }) {
                try checkCancellation()
                if context.policy.isExcluded(entry.path) { continue }
                let identifier = location.identifierPart(of: entry.name)
                guard ScanContext.bundleIdentifierGuess(identifier) != nil,
                      !identifier.lowercased().hasPrefix("com.apple."),
                      !context.appRegistry.isInstalled(identifier),
                      let stat = FileSystem.stat(entry.path) else { continue }
                if var item = try context.makeItem(path: entry.path, stat: stat, category: category, risk: .review,
                                                   reason: .appLeftover(kind: location.kind, bundleIdentifier: identifier),
                                                   result: &output) {
                    item.bundleIdentifier = identifier
                    item.group = identifier
                    output.items.append(item)
                }
            }
        }
        output.locationExists = anyLocation
        return output
    }
}

extension Task where Success == Never, Failure == Never {
    static func checkCancellationAsNoriaError() throws {
        if Task.isCancelled { throw NoriaError.cancelled }
    }
}
