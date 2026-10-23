import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

    /// Locations for the current user, always based on the real home folder.
    /// In the sandboxed App Store edition the paths are only readable after the
    /// user grants access to the home folder (see `FolderAccess` in the app).
    public static var current: SystemLocations {
        SystemLocations(home: realHomeDirectory, temporary: NSTemporaryDirectory())
    }

    /// The user's real home folder. Unlike `NSHomeDirectory()`, this is not
    /// redirected to the app container when running inside the App Sandbox.
    public static var realHomeDirectory: String {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return String(cString: directory)
        }
        return NSHomeDirectory()
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
