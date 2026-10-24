import Foundation
import Testing
@testable import NoriaCore

@Suite struct CleaningEngineTests {
    func scan(_ box: Sandbox) async throws -> ScanReport {
        let events = try await collect(SmartScanEngine(locations: box.locations).scan(settings: NoriaSettings()))
        guard case .finished(let report) = events.last else { throw NoriaError.cancelled }
        return report
    }

    func engine(_ box: Sandbox) throws -> (CleaningEngine, String) {
        let bin = (box.root as NSString).appendingPathComponent("bin")
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        let engine = CleaningEngine(policy: SafetyPolicy(locations: box.locations),
                                    remover: MoveToDirectoryRemover(destination: bin),
                                    volumeInfo: FixedVolumeInfo())
        return (engine, bin)
    }

    @Test func removesSelectedSafeItems() async throws {
        let box = try Sandbox()
        let cache = try box.file("Library/Caches/com.spotify.client/data", bytes: 100_000)
        let keep = try box.file("Documents/keep.txt", bytes: 100)
        let report = try await scan(box)
        let (engine, bin) = try engine(box)

        let events = await collect(engine.clean(report.allItems.filter(\.isSelectable)))
        guard case .finished(let result) = events.last else {
            Issue.record("missing finished event")
            return
        }
        #expect(result.removed.count == 1)
        #expect(result.removedSize > 0)
        #expect(!box.exists(cache))
        #expect(box.exists(keep))
        #expect(try FileManager.default.contentsOfDirectory(atPath: bin).count == 1)
    }

    @Test func neverRemovesProtectedOrInformationalItems() async throws {
        let box = try Sandbox()
        let apple = try box.file("Library/Caches/com.apple.Safari/blob", bytes: 10_000)
        let trash = try box.file(".Trash/old.bin", bytes: 10_000)
        let report = try await scan(box)
        let (engine, _) = try engine(box)

        // Pass everything, even items the UI would never allow to be selected.
        let events = await collect(engine.clean(report.allItems))
        guard case .finished(let result) = events.last else { return }
        #expect(result.removed.isEmpty)
        #expect(result.failed.count == report.allItems.count)
        #expect(box.exists(apple))
        #expect(box.exists(trash))
    }

    @Test func skipsItemsThatChangedAfterTheScan() async throws {
        let box = try Sandbox()
        let log = try box.file("Library/Logs/app.log", bytes: 4096, ageDays: 30)
        let report = try await scan(box)
        try Data(repeating: 7, count: 9000).write(to: URL(fileURLWithPath: log)) // app wrote to it again
        let (engine, _) = try engine(box)
        let events = await collect(engine.clean(report.allItems.filter(\.isSelectable)))
        guard case .finished(let result) = events.last else { return }
        #expect(result.removed.isEmpty)
        #expect(result.outcomes.first?.status == .skipped)
        #expect(box.exists(log))
    }

    @Test func forgedItemsOutsideAllowedRootsAreRefused() async throws {
        let box = try Sandbox()
        let precious = try box.file("Documents/thesis.docx", bytes: 4096)
        let forged = ScanItem(path: precious, category: .userCache, risk: .safe, reason: .thirdPartyCache,
                              allocatedSize: 4096, fileCount: 1, modificationDate: nil, fingerprint: FileSystem.stat(precious))
        let (engine, _) = try engine(box)
        let events = await collect(engine.clean([forged]))
        guard case .finished(let result) = events.last else { return }
        #expect(result.removed.isEmpty)
        #expect(box.exists(precious))
    }

    @Test func reportsVolumeMeasurements() async throws {
        let box = try Sandbox()
        let (engine, _) = try engine(box)
        let events = await collect(engine.clean([]))
        guard case .finished(let result) = events.last else { return }
        #expect(result.volumeAvailableBefore == 50)
        #expect(result.measuredFreedSize == 0)
    }

    @Test func cancellationStopsAndStillReports() async throws {
        let box = try Sandbox()
        for index in 0..<5 { try box.file("Library/Caches/com.spotify.client/\(index)/f", bytes: 4096) }
        try box.file("Library/Caches/com.other.app/f", bytes: 4096)
        let report = try await scan(box)
        let (engine, _) = try engine(box)
        let token = CleanupCancellation()
        token.cancel()
        let events = await collect(engine.clean(report.allItems.filter(\.isSelectable), cancellation: token))
        guard case .finished(let result) = events.last else {
            Issue.record("missing finished event")
            return
        }
        #expect(result.wasCancelled)
        #expect(result.removed.isEmpty)
        #expect(result.outcomes.allSatisfy { $0.status == .skipped })
    }

    @Test func permanentRemoverDeletesInsideSandboxOnly() throws {
        let box = try Sandbox()
        let file = try box.file("Library/Caches/com.x.y/z", bytes: 10)
        try PermanentRemover().remove(ScanItem(path: file, category: .userCache, risk: .safe, reason: .thirdPartyCache, allocatedSize: 10, fileCount: 1, modificationDate: nil, fingerprint: nil))
        #expect(!box.exists(file))
    }
}

@Suite struct PersistenceTests {
    @Test func operationLogRoundTripAndCorruptLineTolerance() async throws {
        let box = try Sandbox()
        let url = URL(fileURLWithPath: box.root).appendingPathComponent("log/operations.jsonl")
        let log = OperationLog(fileURL: url)
        try await log.append(OperationRecord(date: Date(timeIntervalSince1970: 1000), kind: .smartScan, duration: 1, recoverableBytes: 10, itemsFound: 2))
        try await log.append(OperationRecord(date: Date(timeIntervalSince1970: 2000), kind: .cleanup, duration: 2, method: .moveToTrash, removedPaths: ["/a"], removedBytes: 10))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{broken".utf8))
        try handle.close()

        let records = try await log.records()
        #expect(records.map(\.kind) == [.cleanup, .smartScan])
        try await log.clear()
        #expect(try await log.records().isEmpty)
    }

    @Test func settingsDecodeWithMissingKeys() throws {
        let data = Data(#"{"logsMinimumAgeDays": 14}"#.utf8)
        let settings = try JSONDecoder().decode(NoriaSettings.self, from: data)
        #expect(settings.logsMinimumAgeDays == 14)
        #expect(settings.removalMethod == .quarantine)
        #expect(settings.enabledCategories == Set(CleanCategory.smartScanCategories))
    }

    @Test func newCategoriesStartEnabledForExistingUsers() throws {
        // Saved by an older version: no knownCategories key, logs disabled by the user.
        let data = Data(#"{"enabledCategories": ["userCache", "temporaryFiles", "developerCache", "downloads", "trash"]}"#.utf8)
        let settings = try JSONDecoder().decode(NoriaSettings.self, from: data)
        #expect(!settings.enabledCategories.contains(.logs), "the user's choice is kept")
        #expect(settings.enabledCategories.contains(.appLeftovers))
        #expect(settings.enabledCategories.contains(.mail))
    }

    @Test func settingsStoreRoundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "noria.tests.\(UUID().uuidString)"))
        let store = UserDefaultsSettingsStore(defaults: defaults)
        var settings = store.load()
        settings.exclusions = ["/Users/x/Keep"]
        settings.language = .spanish
        store.save(settings)
        #expect(store.load() == settings)
    }

    @Test func volumeInfoReadsRealValues() throws {
        let info = try VolumeInfoProvider().volumeInfo(for: NSHomeDirectory())
        #expect(info.totalCapacity > 0)
        #expect(info.availableCapacity <= info.totalCapacity)
        #expect(info.usedFraction >= 0 && info.usedFraction <= 1)
    }
}

@Suite struct RecommendationTests {
    @Test func rankedBySafetyWeightedSize() {
        func item(_ name: String, _ category: CleanCategory, _ risk: RiskLevel, _ reason: ItemReason, _ size: Int64) -> ScanItem {
            ScanItem(path: "/h/\(name)", category: category, risk: risk, reason: reason, allocatedSize: size, fileCount: 1, modificationDate: nil, fingerprint: nil)
        }
        let report = ScanReport(startedAt: Date(), finishedAt: Date(), categories: [
            CategoryResult(category: .userCache, items: [
                item("spotify", .userCache, .safe, .knownRegenerableCache(tool: "Spotify"), 600_000_000),
                item("big.cache", .userCache, .review, .thirdPartyCache, 2_000_000_000),
            ]),
            CategoryResult(category: .downloads, items: [
                item("Xcode.xip", .downloads, .review, .oldInstaller(days: 270), 3_200_000_000),
            ]),
        ])
        let recs = RecommendationEngine.recommendations(for: report)
        #expect(recs.count == 3)
        #expect(recs.first?.kind == .oldInstaller(name: "Xcode.xip", days: 270))
        #expect(recs.map(\.score) == recs.map(\.score).sorted(by: >))
    }
}
