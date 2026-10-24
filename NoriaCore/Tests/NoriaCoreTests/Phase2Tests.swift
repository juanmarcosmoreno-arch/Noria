import Foundation
import Testing
@testable import NoriaCore

extension Sandbox {
    /// Creates a minimal `.app` bundle with an Info.plist.
    @discardableResult
    func app(_ relative: String, identifier: String, name: String? = nil, bytes: Int = 50_000) throws -> String {
        let path = self.path(relative)
        try file(relative + "/Contents/MacOS/binary", bytes: bytes)
        var info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": "1.2"]
        if let name { info["CFBundleName"] = name }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        return path
    }
}

@Suite struct QuarantineTests {
    func item(_ path: String) -> ScanItem {
        ScanItem(path: path, category: .userCache, risk: .safe, reason: .thirdPartyCache,
                 allocatedSize: 4096, fileCount: 1, modificationDate: nil, fingerprint: FileSystem.stat(path))
    }

    @Test func quarantineAndRestoreRoundTrip() throws {
        let box = try Sandbox()
        let original = try box.file("Library/Caches/com.example.app/data.bin", bytes: 4096)
        let folder = (original as NSString).deletingLastPathComponent
        let store = QuarantineStore(root: (box.root as NSString).appendingPathComponent("quarantine"))

        let entry = try store.quarantine(item(folder))
        #expect(!box.exists(folder))
        #expect(store.entries() == [entry])
        #expect(store.totalSize() == 4096)

        try store.restore(entry)
        #expect(box.exists(original))
        #expect(store.entries().isEmpty)
    }

    @Test func restoreNeverOverwrites() throws {
        let box = try Sandbox()
        let original = try box.file("Downloads/setup.dmg", bytes: 100)
        let store = QuarantineStore(root: (box.root as NSString).appendingPathComponent("quarantine"))
        let entry = try store.quarantine(item(original))
        try box.file("Downloads/setup.dmg", bytes: 7) // a new file appeared at the same path
        #expect(throws: QuarantineError.destinationExists(original)) { try store.restore(entry) }
        #expect(store.entries().count == 1, "the quarantined copy is kept")
    }

    @Test func purgeDeletesOnlyExpiredEntries() throws {
        let box = try Sandbox()
        let store = QuarantineStore(root: (box.root as NSString).appendingPathComponent("quarantine"))
        let old = try store.quarantine(item(try box.file("a", bytes: 10)), now: Date().addingTimeInterval(-10 * 86_400))
        let recent = try store.quarantine(item(try box.file("b", bytes: 10)))
        let purged = store.purgeExpired(retentionDays: 7)
        #expect(purged == [old])
        #expect(store.entries() == [recent])
    }

    @Test func cleaningEngineQuarantinesItems() async throws {
        let box = try Sandbox()
        let cache = try box.file("Library/Caches/com.spotify.client/data", bytes: 100_000)
        let events = try await collect(SmartScanEngine(locations: box.locations, appRegistry: .empty).scan(settings: NoriaSettings()))
        guard case .finished(let report) = events.last else { return }
        let store = QuarantineStore(root: (box.root as NSString).appendingPathComponent("quarantine"))
        let engine = CleaningEngine(policy: SafetyPolicy(locations: box.locations), remover: QuarantineRemover(store: store),
                                    volumeInfo: FixedVolumeInfo())
        let result = await collect(engine.clean(report.allItems.filter(\.isSelectable)))
        guard case .finished(let cleanup) = result.last else { return }
        #expect(cleanup.method == .quarantine)
        #expect(cleanup.quarantinedSize > 0)
        #expect(!box.exists(cache))
        #expect(store.entries().count == 1)
    }
}

@Suite struct AppRemovalTests {
    @Test func readsAppBundles() throws {
        let box = try Sandbox()
        try box.app("Applications/Tool.app", identifier: "com.example.tool", name: "Tool")
        try box.app("Applications/Suite/Editor.app", identifier: "com.example.editor")
        let apps = AppInventory.scan(roots: [box.path("Applications")])
        #expect(apps.map(\.bundleIdentifier) == ["com.example.editor", "com.example.tool"])
        #expect(apps.first { $0.name == "Tool" }?.version == "1.2")
    }

    @Test func registryIsConservative() {
        let registry = InstalledAppRegistry(bundleIdentifiers: ["com.google.Chrome"])
        #expect(registry.isInstalled("com.google.chrome"))
        #expect(registry.isInstalled("com.google.Chrome.helper"), "helper of an installed app")
        #expect(registry.isInstalled("com.google.Keystone"), "same developer is installed")
        #expect(!registry.isInstalled("com.gone.app"))
        let withLookup = InstalledAppRegistry(bundleIdentifiers: [], externalLookup: { $0 == "com.elsewhere.app" })
        #expect(withLookup.isInstalled("com.elsewhere.app"))
    }

    @Test func findsRelatedFilesByIdentifierAndName() throws {
        let box = try Sandbox()
        let appPath = try box.app("Applications/Tool.app", identifier: "com.example.tool", name: "Tool")
        try box.file("Library/Caches/com.example.tool/cache.db", bytes: 4096)
        try box.file("Library/Preferences/com.example.tool.plist", bytes: 512)
        try box.file("Library/Preferences/ByHost/com.example.tool.0A1B2C3D-0A1B-0A1B-0A1B-0A1B2C3D4E5F.plist", bytes: 512)
        try box.file("Library/Application Support/Tool/projects.db", bytes: 4096)
        try box.file("Library/Application Support/com.example.tool.helper/state", bytes: 4096)
        try box.file("Library/Group Containers/ABCDE12345.com.example.tool/shared.db", bytes: 4096)
        try box.file("Library/Containers/com.example.tool/Data/x", bytes: 4096)
        try box.file("Library/Caches/com.example.toolkit/other", bytes: 4096) // different app: must not match

        let app = try #require(AppInventory.readApp(at: appPath))
        let items = try AppFilesFinder.relatedItems(for: app, context: ScanContext(locations: box.locations, settings: NoriaSettings()))
        // Keyed by path relative to the sandbox home.
        let byPath = Dictionary(uniqueKeysWithValues: items.map { (String($0.path.dropFirst(box.home.count + 1)), $0) })

        #expect(byPath["Applications/Tool.app"]?.reason == .applicationBundle)
        #expect(byPath["Library/Caches/com.example.tool"]?.risk == .safe)
        #expect(byPath["Library/Containers/com.example.tool"]?.risk == .review)
        #expect(byPath["Library/Preferences/com.example.tool.plist"]?.risk == .safe)
        #expect(byPath.keys.contains { $0.hasPrefix("Library/Preferences/ByHost/com.example.tool.0A1B") })
        #expect(byPath["Library/Application Support/Tool"]?.reason == .appData(kind: .applicationSupport, match: .appName))
        #expect(byPath["Library/Application Support/Tool"]?.risk == .review)
        #expect(byPath["Library/Application Support/com.example.tool.helper"]?.risk == .review)
        #expect(byPath["Library/Group Containers/ABCDE12345.com.example.tool"]?.reason == .appData(kind: .groupContainer, match: .sharedGroup))
        #expect(!byPath.keys.contains("Library/Caches/com.example.toolkit"))
        #expect(items.allSatisfy { $0.requiresQuitting == "com.example.tool" })
    }

    @Test func policyAllowsAppDataButNeverAppleItems() throws {
        let box = try Sandbox()
        let policy = SafetyPolicy(locations: box.locations)
        let prefs = try box.file("Library/Preferences/com.example.tool.plist", bytes: 100)
        let apple = try box.file("Library/Preferences/com.apple.finder.plist", bytes: 100)
        func item(_ path: String, _ category: CleanCategory) -> ScanItem {
            ScanItem(path: path, category: category, risk: .safe, reason: .applicationBundle,
                     allocatedSize: 1, fileCount: 1, modificationDate: nil, fingerprint: FileSystem.stat(path))
        }
        #expect(throws: Never.self) { try policy.validateForRemoval(item(prefs, .appRemoval)).get() }
        #expect(throws: NoriaError.blocked(path: apple, reason: .appleItem)) { try policy.validateForRemoval(item(apple, .appRemoval)).get() }
        // Without the App Remover category, Preferences stay protected.
        #expect(throws: NoriaError.blocked(path: prefs, reason: .protectedHomeLocation)) { try policy.validateForRemoval(item(prefs, .userCache)).get() }
        // Keychains are never reachable.
        let keychain = try box.file("Library/Keychains/login.keychain-db", bytes: 100)
        #expect(throws: NoriaError.blocked(path: keychain, reason: .protectedHomeLocation)) { try policy.validateForRemoval(item(keychain, .appRemoval)).get() }
    }

    @Test func policyOnlyAllowsAppBundlesInApplicationFolders() throws {
        let box = try Sandbox()
        let policy = SafetyPolicy(locations: box.locations)
        let app = try box.app("Applications/Tool.app", identifier: "com.example.tool")
        let appleApp = try box.app("Applications/Pages.app", identifier: "com.apple.iWork.Pages")
        let notApp = try box.file("Applications/readme.txt", bytes: 10)
        func item(_ path: String) -> ScanItem {
            ScanItem(path: path, category: .appRemoval, risk: .safe, reason: .applicationBundle,
                     allocatedSize: 1, fileCount: 1, modificationDate: nil, fingerprint: FileSystem.stat(path))
        }
        #expect(throws: Never.self) { try policy.validateForRemoval(item(app)).get() }
        #expect(throws: NoriaError.blocked(path: appleApp, reason: .appleItem)) { try policy.validateForRemoval(item(appleApp)).get() }
        #expect(throws: NoriaError.blocked(path: notApp, reason: .notApplicationBundle)) { try policy.validateForRemoval(item(notApp)).get() }
        #expect(policy.protectionReason(for: "/Applications/Safari.app/Contents", category: .appRemoval) == .systemLocation)
    }

    @Test func leftoversOnlyForUninstalledVendors() throws {
        let box = try Sandbox()
        try box.file("Library/Application Support/com.gone.editor/data", bytes: 4096)
        try box.file("Library/Preferences/com.gone.editor.plist", bytes: 512)
        try box.file("Library/Application Support/com.google.Keystone/data", bytes: 4096) // vendor still installed
        try box.file("Library/Application Support/com.apple.something/data", bytes: 4096)
        try box.file("Library/Application Support/Some Folder/data", bytes: 4096) // not an identifier
        let context = ScanContext(locations: box.locations, settings: NoriaSettings(),
                                  appRegistry: InstalledAppRegistry(bundleIdentifiers: ["com.google.Chrome"]))
        let output = try AppLeftoversRule().scan(context)
        #expect(Set(output.items.map(\.name)) == ["com.gone.editor", "com.gone.editor.plist"])
        #expect(output.items.allSatisfy { $0.risk == .review && $0.isSelectable })
    }
}

@Suite struct MailTests {
    func mailTree(_ box: Sandbox) throws {
        try box.file("Library/Mail/V10/SERVER-ID/INBOX.mbox/X1/Data/Attachments/1/2/invoice.pdf", bytes: 80_000)
        try box.file("Library/Mail/V10/SERVER-ID/INBOX.mbox/X1/Data/Messages/1.emlx", bytes: 8_000)
        try box.file("Library/Mail/V10/POP-ID/INBOX.mbox/X2/Data/Attachments/1/photo.jpg", bytes: 50_000)
        try box.file("Library/Mail/V10/UNKNOWN-ID/Archive.mbox/X3/Data/Attachments/1/doc.pdf", bytes: 50_000)
        try box.file("Library/Mail/V10/Mailboxes/Old.mbox/X4/Data/Attachments/1/a.zip", bytes: 50_000)
        try box.file("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/ABC/report.pdf", bytes: 30_000)
    }

    @Test func classifiesAttachmentsByAccountType() throws {
        let box = try Sandbox()
        try mailTree(box)
        let resolver = StaticMailAccountResolver([
            "SERVER-ID": MailAccountInfo(kind: .server, displayName: "me@icloud.com"),
            "POP-ID": MailAccountInfo(kind: .local, displayName: "old@pop.example"),
        ])
        let output = try MailRule().scan(ScanContext(locations: box.locations, settings: NoriaSettings(), mailAccounts: resolver))
        let byGroup = Dictionary(grouping: output.items, by: { $0.group ?? "" })

        let server = try #require(byGroup["me@icloud.com"]?.first)
        #expect(server.risk == .review && server.isSelectable)
        #expect(server.name == "INBOX")
        #expect(server.requiresQuitting == "com.apple.mail")
        #expect(byGroup["old@pop.example"]?.first?.risk == .protected)
        #expect(byGroup["UNKNOWN-ID"]?.first?.risk == .protected, "unknown account type is never removable")
        #expect(byGroup["On My Mac"]?.first?.isSelectable == false)
        #expect(byGroup["Mail Downloads"]?.first?.risk == .safe)
        #expect(!output.items.contains { $0.path.contains("/Messages") }, "messages are never listed")
    }

    @Test func policyKeepsMessagesOutOfReach() throws {
        let box = try Sandbox()
        try mailTree(box)
        let policy = SafetyPolicy(locations: box.locations)
        func item(_ relative: String) -> ScanItem {
            let path = box.path(relative)
            return ScanItem(path: path, category: .mail, risk: .review, reason: .mailDownloads,
                            allocatedSize: 1, fileCount: 1, modificationDate: nil, fingerprint: FileSystem.stat(path))
        }
        let attachments = item("Library/Mail/V10/SERVER-ID/INBOX.mbox/X1/Data/Attachments")
        let messages = item("Library/Mail/V10/SERVER-ID/INBOX.mbox/X1/Data/Messages")
        let mailbox = item("Library/Mail/V10/SERVER-ID/INBOX.mbox")
        #expect(throws: Never.self) { try policy.validateForRemoval(attachments).get() }
        #expect(throws: NoriaError.blocked(path: messages.path, reason: .notMailAttachment)) { try policy.validateForRemoval(messages).get() }
        #expect(throws: NoriaError.blocked(path: mailbox.path, reason: .notMailAttachment)) { try policy.validateForRemoval(mailbox).get() }
    }

    @Test func accountTypeMapping() {
        #expect(AccountsDatabaseResolver.kind(forAccountType: "com.apple.account.IMAP") == .server)
        #expect(AccountsDatabaseResolver.kind(forAccountType: "com.apple.account.Exchange") == .server)
        #expect(AccountsDatabaseResolver.kind(forAccountType: "com.apple.account.POP") == .local)
        #expect(AccountsDatabaseResolver.kind(forAccountType: "com.apple.account.SomethingNew") == .unknown)
        #expect(AccountsDatabaseResolver(databasePath: "/nonexistent/Accounts4.sqlite").account(for: "X").kind == .unknown)
    }

    @Test func usageReportPerAccount() throws {
        let box = try Sandbox()
        try mailTree(box)
        let resolver = StaticMailAccountResolver(["SERVER-ID": MailAccountInfo(kind: .server, displayName: "me@icloud.com")])
        let report = try MailRule.usage(ScanContext(locations: box.locations, settings: NoriaSettings(), mailAccounts: resolver))
        #expect(report.mailFolderReadable)
        let server = try #require(report.accounts.first { $0.displayName == "me@icloud.com" })
        #expect(server.kind == .server)
        #expect(server.attachmentsSize >= 80_000)
        #expect(server.totalSize > server.attachmentsSize, "messages count in the total")
        #expect(report.mailDownloadsSize >= 30_000)
        #expect(report.accounts.count == 4)
    }

    @Test func mailboxNames() {
        #expect(MailRule.mailboxName(for: "/h/Library/Mail/V10/A/Work.mbox/Clients.mbox/X/Data/Attachments") == "Work › Clients")
    }
}
