import Foundation
import Testing
@testable import NoriaCore

/// Regression tests for the Phase 5 security review of the removal path.
@Suite struct SecurityReviewTests {
    func item(_ path: String, _ category: CleanCategory, risk: RiskLevel = .review) -> ScanItem {
        ScanItem(path: path, category: category, risk: risk, reason: .spaceMapSelection, allocatedSize: 1, fileCount: 1,
                 modificationDate: nil, fingerprint: FileSystem.stat(path))
    }

    func blockReason(_ policy: SafetyPolicy, _ item: ScanItem) -> SafetyViolation? {
        if case .failure(.blocked(_, let reason)) = policy.validateForRemoval(item) { return reason }
        return nil
    }

    @Test func foldersHoldingLibrariesOrProtectedLocationsAreRefused() throws {
        let box = try Sandbox()
        try box.file("Pictures/Photos Library.photoslibrary/database/Photos.sqlite", bytes: 10)
        try box.file("Music/Music/Music Library.musiclibrary/Library.musicdb", bytes: 10)
        try box.file("Projects/Old/Shoot.photoslibrary/x", bytes: 10)
        try box.file("Projects/Plain/file.txt", bytes: 10)
        let policy = SafetyPolicy(locations: box.locations)
        #expect(blockReason(policy, item(box.path("Pictures"), .largeFiles)) == .containsProtectedData)
        #expect(blockReason(policy, item(box.path("Music"), .largeFiles)) == .containsProtectedData)
        #expect(blockReason(policy, item(box.path("Projects"), .largeFiles)) == .containsProtectedData)
        #expect(blockReason(policy, item(box.path("Projects/Plain"), .largeFiles)) == nil)
    }

    @Test func nonCanonicalPathsAreRefused() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/com.example/a", bytes: 10)
        let policy = SafetyPolicy(locations: box.locations)
        // Built by concatenation: NSString path APIs would normalize these on macOS.
        let caches = box.path("Library/Caches")
        for path in [caches + "/.", caches + "//com.example", caches + "/com.example/", caches + "/com.example/../com.example"] {
            #expect(blockReason(policy, item(path, .userCache)) == .notCanonical, "\(path)")
        }
        #expect(blockReason(policy, item(box.path("Library/Caches/com.example"), .userCache)) == nil)
    }

    @Test func developerCategoryOnlyReachesKnownCaches() throws {
        let box = try Sandbox()
        let snippets = try box.directory("Library/Developer/Xcode/UserData/CodeSnippets")
        let previews = try box.directory("Library/Developer/Xcode/UserData/Previews")
        let support = try box.directory("Library/Developer/Xcode/iOS DeviceSupport/17.0")
        let device = try box.directory("Library/Developer/CoreSimulator/Devices/ABC")
        let simCaches = try box.directory("Library/Developer/CoreSimulator/Caches")
        let policy = SafetyPolicy(locations: box.locations)
        #expect(blockReason(policy, item(snippets, .developerCache)) == .notDeveloperCache)
        #expect(blockReason(policy, item(device, .developerCache)) == .notDeveloperCache)
        #expect(blockReason(policy, item(previews, .developerCache)) == nil)
        #expect(blockReason(policy, item(support, .developerCache)) == nil)
        #expect(blockReason(policy, item(simCaches, .developerCache)) == nil)
    }

    @Test func onMyMacAttachmentsAndAppleGroupContainersAreRefused() throws {
        let box = try Sandbox()
        let local = try box.directory("Library/Mail/V10/Mailboxes/Inbox.mbox/Attachments")
        let notes = try box.directory("Library/Group Containers/group.com.apple.notes")
        let policy = SafetyPolicy(locations: box.locations)
        #expect(blockReason(policy, item(local, .mail)) == .notMailAttachment)
        #expect(blockReason(policy, item(notes, .appRemoval)) == .appleItem)
    }

    @Test func quarantineNeverMovesWithoutMetadata() throws {
        let box = try Sandbox()
        let file = try box.file("Downloads/a.dmg", bytes: 10)
        let root = (box.root as NSString).appendingPathComponent("q")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        // A read-only quarantine root: the metadata cannot be written, so nothing must move.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root) }
        guard getuid() != 0 else { return } // root ignores permissions
        let store = QuarantineStore(root: root)
        #expect(throws: (any Error).self) { try store.quarantine(item(file, .downloads)) }
        #expect(box.exists(file))
    }

    @Test func restoreRefusesSymlinkedDestination() throws {
        let box = try Sandbox()
        let file = try box.file("Documents/proj/notes.txt", bytes: 10)
        let store = QuarantineStore(root: (box.root as NSString).appendingPathComponent("q"))
        let entry = try store.quarantine(item(file, .largeFiles))
        // Replace the original folder with a link to somewhere else.
        try FileManager.default.removeItem(atPath: box.path("Documents/proj"))
        let elsewhere = try box.directory("Elsewhere")
        try FileManager.default.createSymbolicLink(atPath: box.path("Documents/proj"), withDestinationPath: elsewhere)
        #expect(throws: QuarantineError.destinationRedirected(file)) { try store.restore(entry) }
        #expect(!box.exists(box.path("Elsewhere/notes.txt")))
        #expect(store.entries().count == 1)
    }
}
