import Foundation

/// A launchd job that starts with the Mac or at login, read from its property list.
public struct StartupItem: Identifiable, Sendable, Hashable {
    public enum Scope: String, Sendable {
        /// `~/Library/LaunchAgents`: runs for this user; Noria may remove it (with confirmation).
        case user
        /// `/Library/LaunchAgents`: runs for every user; managed by the installing app or an admin.
        case allUsersAgent
        /// `/Library/LaunchDaemons`: runs as a system service; managed by the installing app or an admin.
        case systemDaemon
    }

    public var id: String { plistPath }
    public var label: String
    public var plistPath: String
    public var scope: Scope
    /// The executable it launches, when declared.
    public var program: String?
    public var runsAtLoad: Bool
    public var keepsAlive: Bool
    /// Runs on a schedule or when something changes, instead of permanently.
    public var isOnDemand: Bool
    /// Disabled in its own plist (launchd may still list it elsewhere).
    public var isDisabled: Bool
    /// The program does not exist any more: the app was probably removed.
    public var programMissing: Bool
    /// The `.app` bundle that contains the program, if any.
    public var appPath: String?

    public var isAppleItem: Bool { label.lowercased().hasPrefix("com.apple.") }

    /// Rough impact from what the job declares (not measured).
    public enum Impact: String, Sendable { case high, medium, low }
    public var estimatedImpact: Impact {
        if keepsAlive { return .high }
        if runsAtLoad && !isOnDemand { return .medium }
        return .low
    }
}

public enum StartupItemsScanner {
    /// Folders scanned, with their scope.
    public static func folders(_ locations: SystemLocations) -> [(String, StartupItem.Scope)] {
        [(locations.launchAgents, .user), ("/Library/LaunchAgents", .allUsersAgent), ("/Library/LaunchDaemons", .systemDaemon)]
    }

    public static func scan(locations: SystemLocations) -> [StartupItem] {
        var items: [StartupItem] = []
        for (folder, scope) in folders(locations) {
            guard let entries = try? FileSystem.directoryEntries(folder) else { continue }
            for entry in entries where entry.name.hasSuffix(".plist") {
                if let item = parse(path: entry.path, scope: scope) { items.append(item) }
            }
        }
        return items.sorted { lhs, rhs in
            if lhs.programMissing != rhs.programMissing { return lhs.programMissing }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
    }

    /// Reads one launchd property list. Returns `nil` for unreadable or invalid files.
    public static func parse(path: String, scope: StartupItem.Scope) -> StartupItem? {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let label = (plist["Label"] as? String) ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
        let keepAlive: Bool
        if let flag = plist["KeepAlive"] as? Bool { keepAlive = flag } else { keepAlive = plist["KeepAlive"] is [String: Any] }
        let onDemand = plist["StartInterval"] != nil || plist["StartCalendarInterval"] != nil
            || plist["WatchPaths"] != nil || plist["QueueDirectories"] != nil || plist["MachServices"] != nil
        var missing = false
        var appPath: String?
        if let program, program.hasPrefix("/") {
            missing = FileSystem.stat(program) == nil
            if let range = program.range(of: ".app/") {
                appPath = String(program[..<range.lowerBound]) + ".app"
            }
        }
        return StartupItem(label: label, plistPath: path, scope: scope, program: program,
                           runsAtLoad: plist["RunAtLoad"] as? Bool ?? false, keepsAlive: keepAlive,
                           isOnDemand: onDemand, isDisabled: plist["Disabled"] as? Bool ?? false,
                           programMissing: missing, appPath: appPath)
    }

    /// Cleaning item for a user agent whose program no longer exists. Only user
    /// agents are offered; system-wide items belong to their installer or an admin.
    public static func removalItem(for item: StartupItem) -> ScanItem? {
        guard item.scope == .user, !item.isAppleItem, let stat = FileSystem.stat(item.plistPath) else { return nil }
        return ScanItem(path: item.plistPath, name: item.label, category: .appLeftovers,
                        risk: item.programMissing ? .safe : .review,
                        reason: .appLeftover(kind: .launchAgent, bundleIdentifier: item.label),
                        allocatedSize: stat.allocatedSize, fileCount: 1, modificationDate: stat.modificationDate,
                        bundleIdentifier: item.label, fingerprint: stat)
    }
}
