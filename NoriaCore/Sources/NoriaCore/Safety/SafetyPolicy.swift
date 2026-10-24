import Foundation

/// Why the safety policy refused an item.
public enum SafetyViolation: String, Codable, Sendable, Equatable {
    case protectedRisk
    case informationalOnly
    case systemLocation
    case protectedHomeLocation
    case managedLibrary
    case outsideAllowedRoots
    case isAllowedRoot
    case userExclusion
    case symlinkedParent
    case notCanonical
    /// Belongs to macOS or an Apple app.
    case appleItem
    /// Inside Mail, only attachment folders may be removed.
    case notMailAttachment
    /// In an Applications folder, only `.app` bundles may be removed.
    case notApplicationBundle
}

/// Central, deliberately conservative rules about what Noria may touch.
///
/// Every removal goes through `validateForRemoval`, which is evaluated again
/// right before acting, independently of how the item was classified by the scan.
public struct SafetyPolicy: Sendable {
    public var locations: SystemLocations
    /// User-configured exclusions (canonical paths). Items equal to or inside them are never touched.
    public var exclusions: [String]

    public init(locations: SystemLocations, exclusions: [String] = []) {
        self.locations = locations
        self.exclusions = exclusions.map { FileSystem.bestEffortCanonicalPath($0) }
    }

    /// System locations that are always off-limits, regardless of category.
    public static let systemRoots: [String] = [
        "/System", "/bin", "/sbin", "/usr", "/Library", "/private", "/etc", "/var",
        "/opt", "/cores", "/dev", "/Applications", "/Network", "/Volumes",
        // Linux equivalents so the policy holds on headless test runners too.
        "/boot", "/lib", "/lib64", "/proc", "/sys", "/snap", "/root",
    ]

    /// Package extensions whose internals are managed by an app and must not be edited piecemeal.
    public static let managedLibraryExtensions: Set<String> = [
        "photoslibrary", "musiclibrary", "tvlibrary", "photolibrary", "aplibrary",
        "migratedphotolibrary", "fcpbundle", "logicx", "band",
    ]

    /// Roots inside which items of each category may be removed. An item must lie
    /// strictly inside one of them; the roots themselves are never removable.
    public func allowedRoots(for category: CleanCategory) -> [String] {
        switch category {
        case .userCache: return [locations.caches]
        case .logs: return [locations.logs]
        case .temporaryFiles: return [locations.temporary]
        case .downloads: return [locations.downloads]
        case .trash: return [] // Phase 1: Trash is informational only.
        case .developerCache:
            // Parents of the developer caches: a whole cache folder (e.g. ~/.npm/_cacache)
            // must lie strictly inside an allowed root to be removable.
            let home = locations.home as NSString
            return [
                locations.derivedData, locations.xcodeArchives,
                home.appendingPathComponent("Library/Developer/Xcode"),
                home.appendingPathComponent("Library/Developer/CoreSimulator/Caches"),
                home.appendingPathComponent("Library/Developer/CoreSimulator"),
                home.appendingPathComponent(".npm"), locations.caches,
                home.appendingPathComponent("Library/pnpm"), home.appendingPathComponent(".bun/install"),
                home.appendingPathComponent(".gradle"), home.appendingPathComponent(".m2"),
                home.appendingPathComponent(".cargo"),
            ]
        case .largeFiles, .duplicates: return [locations.home]
        case .appLeftovers: return appDataRoots
        case .appRemoval: return appDataRoots + [locations.groupContainers, locations.caches] + locations.applicationFolders
        case .mail: return [locations.mail, locations.mailDownloads]
        }
    }

    /// `~/Library` folders where apps keep per-app data, one entry per app.
    var appDataRoots: [String] {
        [
            locations.applicationSupport, locations.preferences, locations.containers,
            locations.savedApplicationState, locations.logs, locations.httpStorages,
            locations.webKit, locations.applicationScripts, locations.launchAgents,
        ]
    }

    /// Protected home locations a category is allowed to reach into. Per-app data
    /// in Containers/Preferences is only removable for the app it belongs to, and
    /// Mail only for attachment copies — both enforced again in `validateForRemoval`.
    func relaxedLocations(for category: CleanCategory?) -> [String] {
        switch category {
        case .appLeftovers: return [locations.containers, locations.preferences]
        case .appRemoval: return [locations.containers, locations.groupContainers, locations.preferences]
        case .mail: return [locations.mail, locations.containers]
        default: return []
        }
    }

    public func isExcluded(_ path: String) -> Bool {
        exclusions.contains { path.isSameOrDescendant(of: $0) }
    }

    /// Returns why `path` must not be modified, or `nil`. Without a category, the
    /// strictest rules apply; some categories may reach specific protected locations.
    public func protectionReason(for path: String, category: CleanCategory? = nil) -> SafetyViolation? {
        let home = locations.home
        // The temporary directory lives under /private/var on macOS; it is the only
        // system-root location allowed, and only for the temporaryFiles category.
        let inTemporary = path.isStrictDescendant(of: locations.temporary)
        let isUninstallableApp = category == .appRemoval && isApplicationBundleLocation(path)
        if !path.isStrictDescendant(of: home) && !inTemporary && !isUninstallableApp {
            for root in Self.systemRoots where path.isSameOrDescendant(of: root) {
                return .systemLocation
            }
        }
        if path.isStrictDescendant(of: home) {
            let relaxed = relaxedLocations(for: category)
            let protected = locations.protectedHomeLocations.filter { !relaxed.contains($0) }
            if protected.contains(where: { path.isSameOrDescendant(of: $0) }) {
                return .protectedHomeLocation
            }
            // ~/Library itself and ~/Library/<anything> are only removable through
            // categories whose allowed roots point there explicitly.
        }
        let components = path.split(separator: "/")
        if components.contains(where: { Self.managedLibraryExtensions.contains(($0 as NSString).pathExtension.lowercased()) }) {
            return .managedLibrary
        }
        return nil
    }

    /// `true` for `/Applications/X.app`, `/Applications/Folder/X.app` and the same under `~/Applications`.
    func isApplicationBundleLocation(_ path: String) -> Bool {
        guard (path as NSString).pathExtension == "app" else { return false }
        let parent = (path as NSString).deletingLastPathComponent
        let grandparent = (parent as NSString).deletingLastPathComponent
        return locations.applicationFolders.contains { $0 == parent || $0 == grandparent }
    }

    /// Extra rules for categories that reach into sensitive places.
    func categorySpecificViolation(for path: String, category: CleanCategory) -> SafetyViolation? {
        let name = (path as NSString).lastPathComponent
        switch category {
        case .appLeftovers, .appRemoval:
            if name.lowercased().hasPrefix("com.apple.") || name.hasPrefix(".GlobalPreferences") {
                return .appleItem
            }
            if locations.applicationFolders.contains(where: { path.isStrictDescendant(of: $0) }) {
                guard isApplicationBundleLocation(path) else { return .notApplicationBundle }
                if let identifier = Self.bundleIdentifier(ofAppAt: path), identifier.lowercased().hasPrefix("com.apple.") {
                    return .appleItem
                }
            }
            return nil
        case .mail:
            if path.isStrictDescendant(of: locations.mailDownloads) { return nil }
            // Inside ~/Library/Mail only attachment folders (or files in them) may go.
            let components = path.dropFirst(locations.mail.count).split(separator: "/")
            return components.contains("Attachments") ? nil : .notMailAttachment
        default:
            return nil
        }
    }

    /// Reads `CFBundleIdentifier` from an app bundle's Info.plist.
    public static func bundleIdentifier(ofAppAt path: String) -> String? {
        let plist = (path as NSString).appendingPathComponent("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return info["CFBundleIdentifier"] as? String
    }

    /// Validates that `item` may be removed right now. Re-reads the file system.
    public func validateForRemoval(_ item: ScanItem) -> Result<Void, NoriaError> {
        let path = item.path
        if item.risk == .protected { return .failure(.blocked(path: path, reason: .protectedRisk)) }
        if item.action != .remove { return .failure(.blocked(path: path, reason: .informationalOnly)) }
        guard path.hasPrefix("/"), !path.contains("/../"), !path.hasSuffix("/..") else {
            return .failure(.blocked(path: path, reason: .notCanonical))
        }
        if isExcluded(path) { return .failure(.blocked(path: path, reason: .userExclusion)) }
        if let reason = protectionReason(for: path, category: item.category) { return .failure(.blocked(path: path, reason: reason)) }

        let roots = allowedRoots(for: item.category)
        if roots.contains(path) { return .failure(.blocked(path: path, reason: .isAllowedRoot)) }
        guard roots.contains(where: { path.isStrictDescendant(of: $0) }) else {
            return .failure(.blocked(path: path, reason: .outsideAllowedRoots))
        }
        // Large files: never inside ~/Library (app data) in Phase 1.
        if item.category == .largeFiles || item.category == .duplicates, path.isSameOrDescendant(of: locations.library) {
            return .failure(.blocked(path: path, reason: .protectedHomeLocation))
        }
        if let violation = categorySpecificViolation(for: path, category: item.category) {
            return .failure(.blocked(path: path, reason: violation))
        }

        // The parent directory must still resolve to the same place: a symlink swapped
        // into the path after the scan must not redirect the removal elsewhere.
        let parent = (path as NSString).deletingLastPathComponent
        guard let canonicalParent = FileSystem.canonicalPath(parent) else {
            return .failure(.notFound(path: path))
        }
        if canonicalParent != parent { return .failure(.blocked(path: path, reason: .symlinkedParent)) }

        // The node must be the same one we scanned.
        guard let current = FileSystem.stat(path) else { return .failure(.notFound(path: path)) }
        if let fingerprint = item.fingerprint {
            if current.identity != fingerprint.identity || current.type != fingerprint.type {
                return .failure(.changedSinceScan(path: path))
            }
            if current.type == .file,
               current.size != fingerprint.size || current.modificationDate != fingerprint.modificationDate {
                return .failure(.changedSinceScan(path: path))
            }
        }
        return .success(())
    }
}
