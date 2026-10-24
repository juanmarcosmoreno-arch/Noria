import Foundation
import Testing
@testable import NoriaCore

@Suite struct HashingTests {
    @Test func sha256KnownVectors() {
        #expect(FileHasher.sha256(data: Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(FileHasher.sha256(data: Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let long = Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)
        #expect(FileHasher.sha256(data: long) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    @Test func portableImplementationMatchesAcrossChunkBoundaries() {
        // Feed 1 000 000 × "a" in uneven chunks; known digest.
        var hasher = PortableSHA256()
        let chunk = Data(repeating: UInt8(ascii: "a"), count: 999)
        var fed = 0
        while fed < 1_000_000 {
            let take = min(999, 1_000_000 - fed)
            hasher.update(chunk.prefix(take))
            fed += take
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #expect(hex == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test func fileHashesMatchDataHashes() throws {
        let box = try Sandbox()
        let path = try box.file("x.bin", bytes: 300_000)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(try FileHasher.sha256(path: path) == FileHasher.sha256(data: data))
    }
}

@Suite struct DuplicateTests {
    func scan(_ box: Sandbox, minimum: Int64 = 1000) async throws -> DuplicateReport {
        let events = try await collect(DuplicateFinder(locations: box.locations, minimumSize: minimum)
            .scan(root: box.home, settings: NoriaSettings()))
        guard case .finished(let report) = events.last else { throw NoriaError.cancelled }
        return report
    }

    @Test func findsOnlyIdenticalContent() async throws {
        let box = try Sandbox()
        try box.file("Documents/a.mov", bytes: 200_000)
        try box.file("Downloads/a copy.mov", bytes: 200_000)
        // Same size, different content (last byte differs).
        let different = try box.file("Desktop/same-size.mov", bytes: 200_000)
        var bytes = try Data(contentsOf: URL(fileURLWithPath: different))
        bytes[bytes.count - 1] = 0x01
        try bytes.write(to: URL(fileURLWithPath: different))
        // Same name, different size: not a duplicate.
        try box.file("Movies/a.mov", bytes: 150_000)

        let report = try await scan(box)
        #expect(report.groups.count == 1)
        let group = try #require(report.groups.first)
        #expect(Set(group.files.map(\.name)) == ["a.mov", "a copy.mov"])
        #expect(group.reclaimableSize == group.size)
    }

    @Test func ignoresHardLinksLibraryAndBundles() async throws {
        let box = try Sandbox()
        let original = try box.file("Documents/big.iso", bytes: 100_000)
        try FileManager.default.linkItem(atPath: original, toPath: box.path("Documents/big-link.iso"))
        try box.file("Library/Application Support/App/data.db", bytes: 100_000)
        try box.file("Library/Caches/App/data.db", bytes: 100_000)
        try box.file("Applications/Tool.app/Contents/Resources/a.dat", bytes: 100_000)
        try box.file("Applications/Tool2.app/Contents/Resources/a.dat", bytes: 100_000)
        let report = try await scan(box)
        #expect(report.groups.isEmpty)
    }

    @Test func automaticSelectionAlwaysKeepsOneCopy() throws {
        let box = try Sandbox()
        let a = try box.file("Documents/a.pdf", bytes: 10_000)
        let b = try box.file("Downloads/a.pdf", bytes: 10_000)
        func file(_ path: String) -> DuplicateFile {
            let stat = FileSystem.stat(path)!
            return DuplicateFile(path: path, modificationDate: stat.modificationDate, fingerprint: stat)
        }
        let group = DuplicateGroup(digest: "x", size: 10_000, files: [file(a), file(b)], kind: .document)
        #expect(group.suggestedKeeper(downloads: box.locations.downloads)?.path == a, "the copy outside Downloads is kept")
        // Selecting every copy is trimmed to leave the keeper.
        let removals = DuplicateFinder.safeRemovals(groups: [group], selected: [a, b], downloads: box.locations.downloads)
        #expect(removals.map(\.path) == [b])
        // If the kept copy disappeared, nothing in the group is removed.
        try FileManager.default.removeItem(atPath: a)
        #expect(DuplicateFinder.safeRemovals(groups: [group], selected: [b], downloads: box.locations.downloads).isEmpty)
    }
}

@Suite struct SpaceMapTests {
    @Test func buildsTreeWithGroupedSmallItems() async throws {
        let box = try Sandbox()
        try box.file("Movies/film.mov", bytes: 3_000_000)
        try box.file("Documents/report.pdf", bytes: 1_200_000)
        for index in 0..<20 { try box.file("Documents/notes/n\(index).txt", bytes: 2_000) }
        let events = try await collect(SpaceMapScanner(minimumNodeSize: 500_000).scan(root: box.home))
        guard case .finished(let report) = events.last else {
            Issue.record("missing finished event")
            return
        }
        let root = report.root
        #expect(root.size >= 4_200_000 + 40_000)
        #expect(root.children.first?.name == "Movies", "sorted largest first")
        let documents = try #require(root.node(at: box.path("Documents")))
        #expect(documents.children.contains { $0.kind == .file && $0.name == "report.pdf" })
        let small = try #require(documents.children.first { $0.kind == .smallItems })
        #expect(small.groupedCount == 1, "the small notes folder is grouped")
        #expect(report.filesVisited == 22)
        #expect(root.children.reduce(0) { $0 + $1.size } <= root.size)
    }

    @Test func treemapFillsBoundsProportionally() {
        let values: [Double] = [6, 6, 4, 3, 2, 2, 1]
        let bounds = Treemap.Rect(x: 0, y: 0, width: 600, height: 400)
        let rects = Treemap.layout(values: values, in: bounds)
        let total = values.reduce(0, +)
        for (value, rect) in zip(values, rects) {
            #expect(abs(rect.area - bounds.area * value / total) < 0.01)
            #expect(rect.x >= -0.001 && rect.y >= -0.001)
            #expect(rect.x + rect.width <= 600.001 && rect.y + rect.height <= 400.001)
        }
        #expect(abs(rects.reduce(0) { $0 + $1.area } - bounds.area) < 0.01)
        #expect(Treemap.layout(values: [0, 0], in: bounds).allSatisfy { $0.area == 0 })
    }
}
