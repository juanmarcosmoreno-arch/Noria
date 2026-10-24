import Foundation
import Testing
@testable import NoriaCore

@Suite struct PrivacyTests {
    /// A fake Chrome profile, a Firefox profile and Safari's folder.
    func makeBrowsers(_ box: Sandbox) throws {
        let chrome = "Library/Application Support/Google/Chrome"
        try box.file("\(chrome)/Local State", bytes: 10)
        for profile in ["Default", "Profile 1"] {
            try box.file("\(chrome)/\(profile)/Preferences", bytes: 10)
            try box.file("\(chrome)/\(profile)/History", bytes: 4096)
            try box.file("\(chrome)/\(profile)/Network/Cookies", bytes: 4096)
            try box.file("\(chrome)/\(profile)/Login Data", bytes: 4096)
            try box.file("\(chrome)/\(profile)/Bookmarks", bytes: 4096)
            try box.file("\(chrome)/\(profile)/Web Data", bytes: 4096)
        }
        try box.file("\(chrome)/Default/Sessions/Session_1", bytes: 4096)
        try box.file("\(chrome)/Default/Service Worker/CacheStorage/a", bytes: 8192)
        try box.file("\(chrome)/System Profile/Preferences", bytes: 10)
        try box.file("\(chrome)/System Profile/History", bytes: 4096)

        let firefox = "Library/Application Support/Firefox/Profiles/abc123.default-release"
        try box.file("\(firefox)/prefs.js", bytes: 10)
        try box.file("\(firefox)/places.sqlite", bytes: 4096)
        try box.file("\(firefox)/cookies.sqlite", bytes: 4096)
        try box.file("\(firefox)/formhistory.sqlite", bytes: 4096)
        try box.file("\(firefox)/logins.json", bytes: 4096)
        try box.file("\(firefox)/key4.db", bytes: 4096)
        try box.file("Library/Safari/History.db", bytes: 4096)
    }

    @Test func findsBrowsingDataButNeverPasswordsOrBookmarks() throws {
        let box = try Sandbox()
        try makeBrowsers(box)
        let report = try PrivacyScanner(locations: box.locations).scan()

        let names = Set(report.entries.flatMap(\.items).map(\.name))
        #expect(names.isSuperset(of: ["History", "Cookies", "Sessions", "Service Worker", "cookies.sqlite", "formhistory.sqlite"]))
        for forbidden in ["Login Data", "Bookmarks", "Web Data", "Preferences", "places.sqlite", "logins.json", "key4.db", "prefs.js"] {
            #expect(!names.contains(forbidden), "\(forbidden) must never be reported")
        }
        #expect(!report.entries.contains { $0.profile == "System Profile" })
        #expect(Set(report.entries.filter { $0.browser.name == "Google Chrome" }.map(\.profile)) == ["Default", "Profile 1"])
        #expect(report.entries.first { $0.browser.engine == .firefox }?.profile == "default-release")

        let items = report.entries.flatMap(\.items)
        #expect(items.allSatisfy { $0.risk == .review && $0.category == .privacy && $0.requiresQuitting != nil })
        #expect(Set(report.notices.map(\.kind)) == [.safariProtected, .firefoxHistoryWithBookmarks])
        #expect(!items.contains { $0.path.hasPrefix(box.path("Library/Safari")) })
    }

    @Test func policyAllowsOnlyKnownBrowsingData() throws {
        let box = try Sandbox()
        try makeBrowsers(box)
        let policy = SafetyPolicy(locations: box.locations)
        let profile = box.path("Library/Application Support/Google/Chrome/Default")
        func item(_ path: String) -> ScanItem {
            ScanItem(path: path, category: .privacy, risk: .review, reason: .browserData(browser: "Google Chrome", kind: .history),
                     allocatedSize: 1, fileCount: 1, modificationDate: nil, fingerprint: FileSystem.stat(path))
        }
        #expect((try? policy.validateForRemoval(item(profile + "/History")).get()) != nil)
        #expect((try? policy.validateForRemoval(item(profile + "/Network/Cookies")).get()) != nil)
        for forbidden in ["Login Data", "Bookmarks", "Web Data", "Preferences"] {
            guard case .failure(.blocked(_, let reason)) = policy.validateForRemoval(item(profile + "/" + forbidden)) else {
                Issue.record("\(forbidden) was not blocked"); continue
            }
            #expect(reason == .notBrowsingData)
        }
        // A file called "History" outside a browser profile is refused too.
        let stray = try box.file("Library/Application Support/Google/Chrome/History", bytes: 10)
        #expect((try? policy.validateForRemoval(item(stray)).get()) == nil)
        let elsewhere = try box.file("Documents/History", bytes: 10)
        #expect((try? policy.validateForRemoval(item(elsewhere)).get()) == nil)
        // Safari is never removable, whatever the category.
        #expect((try? policy.validateForRemoval(item(box.path("Library/Safari/History.db"))).get()) == nil)
    }

    @Test func cleanupRemovesOnlySelectedEntry() async throws {
        let box = try Sandbox()
        try makeBrowsers(box)
        let report = try PrivacyScanner(locations: box.locations).scan()
        let history = try #require(report.entries.first { $0.browser.name == "Google Chrome" && $0.profile == "Default" && $0.kind == .history })
        let bin = (box.root as NSString).appendingPathComponent("bin")
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        let engine = CleaningEngine(policy: SafetyPolicy(locations: box.locations), remover: MoveToDirectoryRemover(destination: bin))
        let events = await Array(engine.clean(history.items))
        guard case .finished(let result)? = events.last else { Issue.record("no report"); return }
        #expect(result.removed.count == history.items.count)
        let chrome = "Library/Application Support/Google/Chrome/Default"
        #expect(!box.exists(box.path("\(chrome)/History")))
        #expect(box.exists(box.path("\(chrome)/Network/Cookies")))
        #expect(box.exists(box.path("\(chrome)/Bookmarks")))
        #expect(box.exists(box.path("Library/Application Support/Google/Chrome/Profile 1/History")))
    }
}

extension Array {
    init(_ stream: AsyncStream<Element>) async {
        self = []
        for await element in stream { append(element) }
    }
}
