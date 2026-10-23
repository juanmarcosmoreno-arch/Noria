import Foundation

/// Well-known locations Noria inspects, derived from a home directory.
///
/// Every location is canonical (symlinks resolved) so path comparisons in the
/// safety policy are reliable. Tests build an instance over a temporary
/// directory; the app uses `.current`.
public struct SystemLocations: Sendable, Equatable {
    public var home: String
    public var temporary: String

    public init(home: String, temporary: String) {
        self.home = FileSystem.bestEffortCanonicalPath(home)
        self.temporary = FileSystem.bestEffortCanonicalPath(temporary)
    }

    /// Locations for the current user. In a non-sandboxed build `NSHomeDirectory()`
    /// is the real home folder; in a sandboxed build it is the app container, which
    /// is why the App Store edition needs user-granted folder access (see docs).
    public static var current: SystemLocations {
        SystemLocations(home: NSHomeDirectory(), temporary: NSTemporaryDirectory())
    }

    private func inHome(_ components: String...) -> String {
        components.reduce(home) { ($0 as NSString).appendingPathComponent($1) }
    }

    public var library: String { inHome("Library") }
    public var caches: String { inHome("Library", "Caches") }
    public var logs: String { inHome("Library", "Logs") }
    public var downloads: String { inHome("Downloads") }
    public var trash: String { inHome(".Trash") }
    public var derivedData: String { inHome("Library", "Developer", "Xcode", "DerivedData") }
    public var xcodeArchives: String { inHome("Library", "Developer", "Xcode", "Archives") }
    public var iOSDeviceSupport: String { inHome("Library", "Developer", "Xcode", "iOS DeviceSupport") }
    public var npmCache: String { inHome(".npm", "_cacache") }
    public var pipCache: String { inHome("Library", "Caches", "pip") }
    public var homebrewCache: String { inHome("Library", "Caches", "Homebrew") }
    public var yarnCache: String { inHome("Library", "Caches", "Yarn") }
    public var cocoaPodsCache: String { inHome("Library", "Caches", "CocoaPods") }
    public var goBuildCache: String { inHome("Library", "Caches", "go-build") }

    /// Locations inside the home folder that Noria never modifies: app data managed
    /// by macOS or by other apps, iCloud Drive, keychains, preferences, libraries.
    public var protectedHomeLocations: [String] {
        [
            inHome("Library", "Containers"),
            inHome("Library", "Group Containers"),
            inHome("Library", "Mobile Documents"),
            inHome("Library", "CloudStorage"),
            inHome("Library", "Keychains"),
            inHome("Library", "Preferences"),
            inHome("Library", "Mail"),
            inHome("Library", "Messages"),
            inHome("Library", "Accounts"),
            inHome("Library", "Cookies"),
            inHome("Library", "Safari"),
            inHome("Library", "Calendars"),
            inHome("Library", "Application Support", "MobileSync"),
            inHome("Library", "Application Support", "AddressBook"),
            inHome("Library", "Photos"),
            inHome("Pictures", "Photos Library.photoslibrary"),
            inHome("Music", "Music"),
        ]
    }
}
