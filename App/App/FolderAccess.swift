import AppKit
import NoriaCore
import Observation

/// Which edition is running. The App Store edition is built with the
/// `NORIA_APP_STORE` compilation condition and runs inside the App Sandbox.
enum AppEdition {
    #if NORIA_APP_STORE
    static let isAppStore = true
    #else
    static let isAppStore = false
    #endif

    /// `true` when macOS runs Noria inside the App Sandbox.
    static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    /// Categories that cannot work in the sandbox: the per-user temporary folder
    /// is not reachable, the sandbox redirects it to the app container.
    static var unavailableCategories: Set<CleanCategory> {
        isSandboxed ? [.temporaryFiles] : []
    }
}

/// Access to the user's home folder in the App Sandbox.
///
/// The user grants access once through the standard macOS open panel (the
/// sandbox's "powerbox"). Noria keeps a security-scoped bookmark so the grant
/// survives relaunches, and can be revoked from Settings. Outside the sandbox
/// this type does nothing: the direct edition already has normal file access.
@MainActor
@Observable
final class FolderAccess {
    enum GrantError: Equatable {
        case wrongFolder(selected: String, expected: String)
        case bookmarkFailed(String)
    }

    let homePath: String
    private(set) var grantedPath: String?
    private(set) var lastError: GrantError?

    @ObservationIgnored private var accessedURL: URL?
    private let defaults: UserDefaults
    private let bookmarkKey = "noria.homeFolderBookmark.v1"
    /// Additional folders granted by the user (e.g. /Applications for App Remover).
    private(set) var extraGrants: Set<String> = []
    @ObservationIgnored private var extraURLs: [String: URL] = [:]
    static let applicationsFolder = "/Applications"

    init(homePath: String, defaults: UserDefaults = .standard) {
        self.homePath = FileSystem.bestEffortCanonicalPath(homePath)
        self.defaults = defaults
        restore()
        restoreExtra(Self.applicationsFolder)
    }

    private func extraKey(_ folder: String) -> String { "noria.folderBookmark.v1." + folder }

    /// Whether Noria may modify `path` (always true outside the sandbox).
    func canModify(_ path: String) -> Bool {
        guard AppEdition.isSandboxed else { return true }
        if let grantedPath, path.isSameOrDescendant(of: grantedPath) { return true }
        return extraGrants.contains { path.isSameOrDescendant(of: $0) }
    }

    private func restoreExtra(_ folder: String) {
        guard AppEdition.isSandboxed, let data = defaults.data(forKey: extraKey(folder)) else { return }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale),
              url.startAccessingSecurityScopedResource() else { return }
        extraURLs[folder] = url
        extraGrants.insert(folder)
    }

    /// Asks the user to allow access to `folder` through the open panel.
    @discardableResult
    func requestAccess(to folder: String, message: String) -> Bool {
        guard AppEdition.isSandboxed else { return true }
        let panel = NSOpenPanel()
        panel.message = message
        panel.prompt = String(localized: "Allow Access")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: folder, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let selected = FileSystem.bestEffortCanonicalPath(url.path)
        guard selected == FileSystem.bestEffortCanonicalPath(folder) else {
            lastError = .wrongFolder(selected: selected, expected: FileSystem.bestEffortCanonicalPath(folder))
            return false
        }
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(data, forKey: extraKey(folder))
        }
        if url.startAccessingSecurityScopedResource() { extraURLs[folder] = url }
        extraGrants.insert(folder)
        lastError = nil
        return true
    }

    /// `true` when scanning is blocked until the user grants access.
    var needsGrant: Bool { AppEdition.isSandboxed && grantedPath == nil }

    /// Re-opens access from the saved bookmark, if any.
    private func restore() {
        guard AppEdition.isSandboxed, let data = defaults.data(forKey: bookmarkKey) else { return }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                 relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            defaults.removeObject(forKey: bookmarkKey)
            return
        }
        guard url.startAccessingSecurityScopedResource() else { return }
        accessedURL = url
        grantedPath = FileSystem.bestEffortCanonicalPath(url.path)
        if isStale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(fresh, forKey: bookmarkKey)
        }
    }

    /// Shows the open panel pointed at the home folder. Returns `true` on success.
    @discardableResult
    func requestHomeAccess() -> Bool {
        guard AppEdition.isSandboxed else { return true }
        let panel = NSOpenPanel()
        panel.message = String(localized: "Noria needs access to your Home folder to analyze caches, logs, developer data, downloads and large files. Click Allow Access without selecting anything else. Nothing is changed without your confirmation.")
        panel.prompt = String(localized: "Allow Access")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: homePath, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return false }

        let selected = FileSystem.bestEffortCanonicalPath(url.path)
        guard selected == homePath else {
            lastError = .wrongFolder(selected: selected, expected: homePath)
            return false
        }
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(data, forKey: bookmarkKey)
        } catch {
            lastError = .bookmarkFailed(error.localizedDescription)
        }
        stopAccessing()
        if url.startAccessingSecurityScopedResource() { accessedURL = url }
        grantedPath = selected
        lastError = nil
        return true
    }

    /// Forgets every grant. Scans are blocked again until access is granted.
    func revoke() {
        stopAccessing()
        grantedPath = nil
        defaults.removeObject(forKey: bookmarkKey)
        for (folder, url) in extraURLs {
            url.stopAccessingSecurityScopedResource()
            defaults.removeObject(forKey: extraKey(folder))
        }
        extraURLs = [:]
        extraGrants = []
    }

    private func stopAccessing() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }

    var errorMessage: String? {
        switch lastError {
        case .wrongFolder(let selected, let expected):
            return String(localized: "You selected “\((selected as NSString).abbreviatingWithTildeInPath)”. Please select “\((expected as NSString).abbreviatingWithTildeInPath)”.")
        case .bookmarkFailed(let message):
            return String(localized: "Access was granted for this session but could not be saved: \(message)")
        case nil:
            return nil
        }
    }
}
