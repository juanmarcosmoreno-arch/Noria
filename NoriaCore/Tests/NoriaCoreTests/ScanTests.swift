import Foundation
import Testing
@testable import NoriaCore

@Suite struct RuleTests {
    @Test func userCacheClassification() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/com.apple.Safari/blob", bytes: 50_000)
        try box.file("Library/Caches/com.spotify.client/data", bytes: 50_000)
        try box.file("Library/Caches/com.unknown.tool/data", bytes: 50_000)
        try box.file("Library/Caches/Homebrew/downloads/x.tar.gz", bytes: 50_000)
        try box.directory("Library/Caches/empty.folder")

        let output = try UserCacheRule().scan(ScanContext(locations: box.locations, settings: NoriaSettings()))
        let byName = Dictionary(uniqueKeysWithValues: output.items.map { ($0.name, $0) })
        #expect(byName["com.apple.Safari"]?.risk == .protected)
        #expect(byName["com.spotify.client"]?.risk == .safe)
        #expect(byName["com.unknown.tool"]?.risk == .review)
        #expect(byName["com.unknown.tool"]?.bundleIdentifier == "com.unknown.tool")
        #expect(byName["Homebrew"] == nil, "developer caches are reported by DeveloperCacheRule")
        #expect(byName["empty.folder"] == nil, "empty folders are not reported")
    }

    @Test func logsOnlyOldFiles() throws {
        let box = try Sandbox()
        try box.file("Library/Logs/App/old.log", bytes: 4096, ageDays: 30)
        try box.file("Library/Logs/App/fresh.log", bytes: 4096, ageDays: 1)
        try box.file("Library/Logs/DiagnosticReports/crash.ips", bytes: 4096, ageDays: 10)
        let output = try LogsRule().scan(ScanContext(locations: box.locations, settings: NoriaSettings()))
        let names = Set(output.items.map(\.name))
        #expect(names == ["old.log", "crash.ips"])
        #expect(output.items.allSatisfy { $0.risk == .safe })
    }

    @Test func downloadsReportsOldInstallersAndArchivesOnly() throws {
        let box = try Sandbox()
        try box.file("Downloads/Old.dmg", bytes: 4096, ageDays: 90)
        try box.file("Downloads/New.dmg", bytes: 4096, ageDays: 2)
        try box.file("Downloads/source.zip", bytes: 4096, ageDays: 45)
        try box.file("Downloads/notes.txt", bytes: 4096, ageDays: 45)
        try box.file("Downloads/ancient.mov", bytes: 4096, ageDays: 400)
        let output = try DownloadsRule().scan(ScanContext(locations: box.locations, settings: NoriaSettings()))
        let byName = Dictionary(uniqueKeysWithValues: output.items.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["Old.dmg", "source.zip", "ancient.mov"])
        #expect(output.items.allSatisfy { $0.risk == .review })
        if case .oldInstaller(let days) = byName["Old.dmg"]?.reason { #expect(days >= 89) } else { Issue.record("wrong reason") }
    }

    @Test func downloadsFolderWithRecentContentIsNotOld() throws {
        let box = try Sandbox()
        try box.file("Downloads/Project/recent.txt", bytes: 4096, ageDays: 3)
        try box.setAge(box.path("Downloads/Project"), days: 500)
        let output = try DownloadsRule().scan(ScanContext(locations: box.locations, settings: NoriaSettings()))
        #expect(output.items.isEmpty)
    }

    @Test func developerCaches() throws {
        let box = try Sandbox()
        try box.file("Library/Developer/Xcode/DerivedData/App-abc/Build/x.o", bytes: 50_000)
        try box.file("Library/Developer/Xcode/Archives/2026-01-01/App.xcarchive/Info.plist", bytes: 5_000)
        try box.file(".npm/_cacache/index-v5/aa", bytes: 5_000)
        try box.file("Library/Caches/pip/http/x", bytes: 5_000)
        let output = try DeveloperCacheRule().scan(ScanContext(locations: box.locations, settings: NoriaSettings()))
        let byName = Dictionary(uniqueKeysWithValues: output.items.map { ($0.name, $0) })
        #expect(byName["App-abc"]?.risk == .safe)
        #expect(byName["App-abc"]?.reason == .xcodeDerivedData)
        #expect(byName["2026-01-01"]?.risk == .review)
        #expect(byName["_cacache"]?.risk == .safe)
        #expect(byName["pip"]?.reason == .packageManagerCache(tool: "pip", officialCommand: "pip cache purge"))
    }

    @Test func temporaryFilesUseNewestContentDate() throws {
        let box = try Sandbox()
        try box.file("old-folder/a", bytes: 4096, ageDays: 20, inTemporary: true)
        try box.file("busy-folder/a", bytes: 4096, ageDays: 20, inTemporary: true)
        try box.file("busy-folder/b", bytes: 4096, ageDays: 0, inTemporary: true)
        try box.file("com.apple.thing/a", bytes: 4096, ageDays: 20, inTemporary: true)
        let output = try TemporaryFilesRule().scan(ScanContext(locations: box.locations, settings: NoriaSettings()))
        #expect(output.items.map(\.name) == ["old-folder"])
    }

    @Test func trashIsInformational() throws {
        let box = try Sandbox()
        try box.file(".Trash/deleted.bin", bytes: 10_000)
        let output = try TrashRule().scan(ScanContext(locations: box.locations, settings: NoriaSettings()))
        #expect(output.items.count == 1)
        #expect(output.items.first?.action == .informational)
        #expect(output.items.first?.isSelectable == false)
    }

    @Test func exclusionsAreNotScanned() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/com.private.app/data", bytes: 5_000)
        var settings = NoriaSettings()
        settings.exclusions = [box.path("Library/Caches/com.private.app")]
        let output = try UserCacheRule().scan(ScanContext(locations: box.locations, settings: settings))
        #expect(output.items.isEmpty)
    }

    @Test func missingLocationsAreReported() throws {
        let box = try Sandbox()
        let output = try UserCacheRule().scan(ScanContext(locations: box.locations, settings: NoriaSettings()))
        #expect(output.locationExists == false)
    }
}

@Suite struct SmartScanEngineTests {
    @Test func fullScanEmitsOrderedEventsAndReport() async throws {
        let box = try Sandbox()
        try box.file("Library/Caches/com.spotify.client/data", bytes: 100_000)
        try box.file("Library/Logs/old.log", bytes: 8_192, ageDays: 20)
        try box.file("Downloads/setup.pkg", bytes: 8_192, ageDays: 60)

        let events = try await collect(SmartScanEngine(locations: box.locations).scan(settings: NoriaSettings()))
        let started = events.compactMap { event -> CleanCategory? in
            if case .categoryStarted(let category, _, _) = event { return category }
            return nil
        }
        #expect(started == CleanCategory.smartScanCategories)
        guard case .finished(let report) = events.last else {
            Issue.record("missing finished event")
            return
        }
        #expect(report.allItems.count == 3)
        #expect(report.safeSize > 0)
        #expect(report.recoverableSize >= report.safeSize)
    }

    @Test func disabledCategoriesAreSkipped() async throws {
        let box = try Sandbox()
        var settings = NoriaSettings()
        settings.enabledCategories = [.logs]
        let events = try await collect(SmartScanEngine(locations: box.locations).scan(settings: settings))
        let started = events.filter { if case .categoryStarted = $0 { return true } else { return false } }
        #expect(started.count == 1)
    }

    @Test func overlappingItemsAreReportedOnce() {
        func item(_ path: String) -> ScanItem {
            ScanItem(path: path, category: .userCache, risk: .safe, reason: .thirdPartyCache, allocatedSize: 1, fileCount: 1, modificationDate: nil, fingerprint: nil)
        }
        var claimed = ["/h/Library/Caches/pip"]
        let kept = SmartScanEngine.removingOverlaps([item("/h/Library/Caches/pip/x"), item("/h/Library/Caches/other"), item("/h/Library/Caches")], claimed: &claimed)
        #expect(kept.map(\.path) == ["/h/Library/Caches/other"])
    }

    @Test func scanCanBeCancelled() async throws {
        let box = try Sandbox()
        for index in 0..<2000 { try box.file("Library/Caches/com.x.y/f\(index)", bytes: 16) }
        let engine = SmartScanEngine(locations: box.locations)
        let task = Task {
            var count = 0
            for try await _ in engine.scan(settings: NoriaSettings()) { count += 1 }
            return count
        }
        task.cancel()
        _ = try? await task.value // Must terminate (either finished quickly or cancelled).
    }
}

@Suite struct LargeFileScannerTests {
    @Test func findsFilesAboveThresholdAndMeasuresPackages() async throws {
        let box = try Sandbox()
        try box.file("Movies/big.mov", bytes: 600_000)
        try box.file("Movies/small.mov", bytes: 10_000)
        try box.file("Applications/Tool.app/Contents/MacOS/Tool", bytes: 400_000)
        try box.file("Applications/Tool.app/Contents/Resources/r", bytes: 400_000)
        try box.file("Library/Containers/com.x/Data/huge.bin", bytes: 900_000)

        let events = try await collect(LargeFileScanner(locations: box.locations)
            .scan(root: box.home, threshold: 500_000, settings: NoriaSettings()))
        guard case .finished(let report) = events.last else {
            Issue.record("missing finished event")
            return
        }
        let names = Set(report.files.map(\.name))
        #expect(names == ["big.mov", "Tool.app"])
        let app = try #require(report.files.first { $0.name == "Tool.app" })
        #expect(app.isPackage)
        #expect(app.kind == .application)
        #expect(report.files.first { $0.name == "big.mov" }?.kind == .video)
        #expect(report.files.first { $0.name == "big.mov" }?.risk == .review)
    }

    @Test func fileKindClassification() {
        #expect(FileKind.classify("/x/a.DMG") == .diskImage)
        #expect(FileKind.classify("/x/a.pkg") == .installer)
        #expect(FileKind.classify("/x/a.tar") == .archive)
        #expect(FileKind.classify("/x/a.unknown") == .other)
    }
}
