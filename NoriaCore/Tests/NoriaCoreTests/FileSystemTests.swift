import Foundation
import Testing
@testable import NoriaCore

@Suite struct FileSystemTests {
    @Test func statReportsTypeAndSize() throws {
        let box = try Sandbox()
        let file = try box.file("a.bin", bytes: 10_000)
        let stat = try #require(FileSystem.stat(file))
        #expect(stat.type == .file)
        #expect(stat.size == 10_000)
        #expect(stat.allocatedSize >= 10_000)
        #expect(FileSystem.stat(box.path("missing")) == nil)
    }

    @Test func symlinksAreNotFollowed() throws {
        let box = try Sandbox()
        let target = try box.file("big.bin", bytes: 1_000_000)
        let link = box.path("link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        #expect(FileSystem.stat(link)?.type == .symlink)
    }

    @Test func walkerCountsHardLinksOnceAndSkipsSymlinkTargets() throws {
        let box = try Sandbox()
        let dir = try box.directory("tree")
        let original = try box.file("tree/a.bin", bytes: 100_000)
        try FileManager.default.linkItem(atPath: original, toPath: box.path("tree/hardlink.bin"))
        let outside = try box.file("outside/huge.bin", bytes: 2_000_000)
        try FileManager.default.createSymbolicLink(atPath: box.path("tree/link"), withDestinationPath: (outside as NSString).deletingLastPathComponent)

        let summary = try FileWalker().walk(root: dir, tracker: InodeTracker()) { _, _ in .continue }
        let fileSize = try #require(FileSystem.stat(original)).allocatedSize
        #expect(summary.fileCount == 1)
        #expect(summary.allocatedSize < fileSize + 1_000_000, "symlinked directory must not be followed")
        #expect(summary.allocatedSize >= fileSize)
    }

    @Test func walkerSkipsConfiguredPaths() throws {
        let box = try Sandbox()
        try box.file("t/keep.bin", bytes: 1000)
        try box.file("t/skip/no.bin", bytes: 1000)
        var options = WalkOptions()
        options.skippedPaths = [box.path("t/skip")]
        var seen: [String] = []
        try FileWalker(options: options).walk(root: box.path("t")) { path, _ in
            seen.append(path)
            return .continue
        }
        #expect(seen.contains(box.path("t/keep.bin")))
        #expect(!seen.contains(where: { $0.contains("/skip") }))
    }

    @Test func walkerRecordsUnreadableDirectories() throws {
        guard getuid() != 0 else { return } // root can read everything
        let box = try Sandbox()
        try box.file("t/locked/secret.bin", bytes: 10)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: box.path("t/locked"))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: box.path("t/locked")) }
        let summary = try FileWalker().walk(root: box.path("t")) { _, _ in .continue }
        #expect(summary.inaccessibleCount == 1)
    }

    @Test func walkerHonoursCancellation() async throws {
        let box = try Sandbox()
        for index in 0..<600 { try box.file("many/f\(index)", bytes: 10) }
        let root = box.path("many")
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try FileWalker().walk(root: root) { _, _ in .continue }
        }
        await #expect(throws: NoriaError.cancelled) { try await task.value }
    }

    @Test func pathAncestry() {
        #expect("/a/b".isSameOrDescendant(of: "/a"))
        #expect("/a".isSameOrDescendant(of: "/a"))
        #expect(!"/ab".isSameOrDescendant(of: "/a"))
        #expect(!"/a".isStrictDescendant(of: "/a"))
    }
}
