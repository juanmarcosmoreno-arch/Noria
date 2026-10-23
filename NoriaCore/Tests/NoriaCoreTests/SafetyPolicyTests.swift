import Foundation
import Testing
@testable import NoriaCore

@Suite struct SafetyPolicyTests {
    func item(_ path: String, category: CleanCategory = .userCache, risk: RiskLevel = .safe, action: ItemAction = .remove) -> ScanItem {
        ScanItem(path: path, category: category, risk: risk, reason: .thirdPartyCache, action: action,
                 allocatedSize: 1, fileCount: 1, modificationDate: nil, fingerprint: FileSystem.stat(path))
    }

    @Test func allowsItemInsideItsCategoryRoot() throws {
        let box = try Sandbox()
        let path = try box.file("Library/Caches/com.example.app/data.bin", bytes: 100)
        let policy = SafetyPolicy(locations: box.locations)
        let folder = (path as NSString).deletingLastPathComponent
        #expect(throws: Never.self) { try policy.validateForRemoval(item(folder)).get() }
    }

    @Test func blocksCategoryRootItself() throws {
        let box = try Sandbox()
        let caches = try box.directory("Library/Caches")
        let policy = SafetyPolicy(locations: box.locations)
        #expect(throws: NoriaError.blocked(path: caches, reason: .isAllowedRoot)) { try policy.validateForRemoval(item(caches)).get() }
    }

    @Test func blocksItemsOutsideCategoryRoot() throws {
        let box = try Sandbox()
        let doc = try box.file("Documents/thesis.pdf", bytes: 100)
        let policy = SafetyPolicy(locations: box.locations)
        #expect(throws: NoriaError.blocked(path: doc, reason: .outsideAllowedRoots)) { try policy.validateForRemoval(item(doc)).get() }
    }

    @Test func blocksProtectedRiskAndInformationalItems() throws {
        let box = try Sandbox()
        let path = try box.file("Library/Caches/x/y", bytes: 10)
        let policy = SafetyPolicy(locations: box.locations)
        #expect(throws: NoriaError.blocked(path: path, reason: .protectedRisk)) { try policy.validateForRemoval(item(path, risk: .protected)).get() }
        #expect(throws: NoriaError.blocked(path: path, reason: .informationalOnly)) { try policy.validateForRemoval(item(path, action: .informational)).get() }
    }

    @Test func blocksSystemLocations() {
        let policy = SafetyPolicy(locations: SystemLocations(home: "/Users/test", temporary: "/private/var/folders/x/T"))
        for path in ["/System/Library/Caches", "/usr/lib/x", "/Library/Caches/foo", "/Applications/Safari.app"] {
            #expect(policy.protectionReason(for: path) == .systemLocation, "\(path)")
        }
        #expect(policy.protectionReason(for: "/private/var/folders/x/T/old") == nil)
    }

    @Test func blocksProtectedHomeLocationsAndManagedLibraries() throws {
        let box = try Sandbox()
        let policy = SafetyPolicy(locations: box.locations)
        #expect(policy.protectionReason(for: box.path("Library/Containers/com.x/Data/big")) == .protectedHomeLocation)
        #expect(policy.protectionReason(for: box.path("Library/Mobile Documents/file")) == .protectedHomeLocation)
        #expect(policy.protectionReason(for: box.path("Pictures/Old.photoslibrary/originals/a.heic")) == .managedLibrary)
        #expect(policy.protectionReason(for: box.path("Movies/clip.mov")) == nil)
    }

    @Test func blocksUserExclusions() throws {
        let box = try Sandbox()
        let path = try box.file("Library/Caches/keep.me/file", bytes: 10)
        let policy = SafetyPolicy(locations: box.locations, exclusions: [box.path("Library/Caches/keep.me")])
        let folder = (path as NSString).deletingLastPathComponent
        #expect(throws: NoriaError.blocked(path: folder, reason: .userExclusion)) { try policy.validateForRemoval(item(folder)).get() }
    }

    @Test func detectsFilesChangedSinceScan() throws {
        let box = try Sandbox()
        let path = try box.file("Library/Logs/app.log", bytes: 100, ageDays: 30)
        let scanned = item(path, category: .logs)
        try Data(repeating: 1, count: 5000).write(to: URL(fileURLWithPath: path))
        let policy = SafetyPolicy(locations: box.locations)
        #expect(throws: NoriaError.changedSinceScan(path: path)) { try policy.validateForRemoval(scanned).get() }
    }

    @Test func detectsReplacedNode() throws {
        let box = try Sandbox()
        let path = try box.file("Library/Caches/swap/file", bytes: 100)
        let folder = (path as NSString).deletingLastPathComponent
        let scanned = item(folder)
        // Move the original away (keeping its inode alive) and put a different folder in its place.
        try FileManager.default.moveItem(atPath: folder, toPath: box.path("moved-away"))
        try box.file("Library/Caches/swap/other", bytes: 100)
        let policy = SafetyPolicy(locations: box.locations)
        #expect(throws: NoriaError.changedSinceScan(path: folder)) { try policy.validateForRemoval(scanned).get() }
    }

    @Test func blocksSymlinkedParent() throws {
        let box = try Sandbox()
        // ~/Library/Caches/redirect -> ~/Documents ; an item "under" it must be refused.
        try box.file("Documents/precious.txt", bytes: 100)
        try box.directory("Library/Caches")
        try FileManager.default.createSymbolicLink(atPath: box.path("Library/Caches/redirect"), withDestinationPath: box.path("Documents"))
        let target = box.path("Library/Caches/redirect/precious.txt")
        let policy = SafetyPolicy(locations: box.locations)
        #expect(throws: NoriaError.blocked(path: target, reason: .symlinkedParent)) { try policy.validateForRemoval(item(target)).get() }
    }

    @Test func blocksLargeFilesInsideLibrary() throws {
        let box = try Sandbox()
        let path = try box.file("Library/Application Support/App/db.sqlite", bytes: 100)
        let policy = SafetyPolicy(locations: box.locations)
        #expect(throws: NoriaError.blocked(path: path, reason: .protectedHomeLocation)) {
            try policy.validateForRemoval(item(path, category: .largeFiles, risk: .review)).get()
        }
        let movie = try box.file("Movies/clip.mov", bytes: 100)
        #expect(throws: Never.self) { try policy.validateForRemoval(item(movie, category: .largeFiles, risk: .review)).get() }
    }

    @Test func rejectsRelativeComponents() throws {
        let box = try Sandbox()
        let path = box.path("Library/Caches/../../Documents")
        let policy = SafetyPolicy(locations: box.locations)
        #expect(throws: NoriaError.blocked(path: path, reason: .notCanonical)) { try policy.validateForRemoval(item(path)).get() }
    }
}
