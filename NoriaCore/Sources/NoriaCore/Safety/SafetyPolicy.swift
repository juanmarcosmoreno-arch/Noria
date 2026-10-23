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
            return [
                locations.derivedData, locations.xcodeArchives, locations.iOSDeviceSupport,
                locations.npmCache, locations.pipCache, locations.homebrewCache,
                locations.yarnCache, locations.cocoaPodsCache, locations.goBuildCache,
            ]
        case .largeFiles: return [locations.home]
        }
    }

    public func isExcluded(_ path: String) -> Bool {
        exclusions.contains { path.isSameOrDescendant(of: $0) }
    }

    /// `true` when `path` is in a location Noria never modifies, for any category.
    public func protectionReason(for path: String) -> SafetyViolation? {
        let home = locations.home
        // The temporary directory lives under /private/var on macOS; it is the only
        // system-root location allowed, and only for the temporaryFiles category.
        let inTemporary = path.isStrictDescendant(of: locations.temporary)
        if !path.isStrictDescendant(of: home) && !inTemporary {
            for root in Self.systemRoots where path.isSameOrDescendant(of: root) {
                return .systemLocation
            }
        }
        if path.isStrictDescendant(of: home) {
            if locations.protectedHomeLocations.contains(where: { path.isSameOrDescendant(of: $0) }) {
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

    /// Validates that `item` may be removed right now. Re-reads the file system.
    public func validateForRemoval(_ item: ScanItem) -> Result<Void, NoriaError> {
        let path = item.path
        if item.risk == .protected { return .failure(.blocked(path: path, reason: .protectedRisk)) }
        if item.action != .remove { return .failure(.blocked(path: path, reason: .informationalOnly)) }
        guard path.hasPrefix("/"), !path.contains("/../"), !path.hasSuffix("/..") else {
            return .failure(.blocked(path: path, reason: .notCanonical))
        }
        if isExcluded(path) { return .failure(.blocked(path: path, reason: .userExclusion)) }
        if let reason = protectionReason(for: path) { return .failure(.blocked(path: path, reason: reason)) }

        let roots = allowedRoots(for: item.category)
        if roots.contains(path) { return .failure(.blocked(path: path, reason: .isAllowedRoot)) }
        guard roots.contains(where: { path.isStrictDescendant(of: $0) }) else {
            return .failure(.blocked(path: path, reason: .outsideAllowedRoots))
        }
        // Large files: never inside ~/Library (app data) in Phase 1.
        if item.category == .largeFiles, path.isSameOrDescendant(of: locations.library) {
            return .failure(.blocked(path: path, reason: .protectedHomeLocation))
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
