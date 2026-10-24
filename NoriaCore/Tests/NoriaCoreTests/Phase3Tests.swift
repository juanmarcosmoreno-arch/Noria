import Foundation
import Testing
@testable import NoriaCore

@Suite struct Phase3Tests {
    @Test func processCPUFromSamples() {
        let earlier = [ProcessSample(pid: 10, name: "a", cpuTime: 1_000_000_000, residentMemory: 10),
                       ProcessSample(pid: 11, name: "b", cpuTime: 0, residentMemory: 10)]
        let later = [ProcessSample(pid: 10, name: "a", cpuTime: 2_000_000_000, residentMemory: 20),
                     ProcessSample(pid: 12, name: "new", cpuTime: 5, residentMemory: 1)]
        let usage = ProcessMonitor.usage(from: earlier, to: later, interval: 2, timebase: 1)
        #expect(usage.count == 1, "processes without a previous sample are skipped")
        #expect(usage.first?.cpu == 0.5)
        #expect(usage.first?.residentMemory == 20)
    }

    @Test func batteryFromAppleSiliconProperties() throws {
        let registry: [String: Any] = ["CycleCount": 312, "DesignCapacity": 4382, "AppleRawMaxCapacity": 3943,
                                       "MaxCapacity": 100, "Temperature": 3050]
        let source: [String: Any] = ["Current Capacity": 80, "Is Charging": false, "Power Source State": "Battery Power",
                                     "BatteryHealth": "Good", "Time to Empty": 300]
        let info = try #require(BatteryInfo.from(registry: registry, powerSource: source))
        #expect(info.cycleCount == 312)
        #expect(info.fullChargeCapacity == 3943, "the percentage MaxCapacity is not mistaken for mAh")
        #expect(abs((info.maximumCapacity ?? 0) - 0.8998) < 0.001)
        #expect(info.isPluggedIn == false)
        #expect(info.condition == "Good")
        #expect(info.temperatureCelsius == 30.5)
        #expect(info.minutesRemaining == 300)
        #expect(BatteryInfo.from(registry: [:], powerSource: [:]) == nil)
    }

    @Test func diskRates() {
        let a = DiskCounters(bytesRead: 1000, bytesWritten: 500)
        let b = DiskCounters(bytesRead: 3000, bytesWritten: 1500)
        let rates = b.rates(since: a, interval: 2)
        #expect(rates?.read == 1000 && rates?.write == 500)
        #expect(a.rates(since: b, interval: 2) == nil)
    }

    @Test func startupItemsFromLaunchdPlists() throws {
        let box = try Sandbox()
        let tool = try box.file("Applications/Tool.app/Contents/MacOS/helper", bytes: 10)
        func write(_ name: String, _ plist: [String: Any]) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try box.file("Library/LaunchAgents/\(name).plist", bytes: 1)
            try data.write(to: URL(fileURLWithPath: box.path("Library/LaunchAgents/\(name).plist")))
        }
        try write("com.example.tool.helper", ["Label": "com.example.tool.helper", "ProgramArguments": [tool, "--daemon"], "RunAtLoad": true, "KeepAlive": true])
        try write("com.gone.updater", ["Label": "com.gone.updater", "Program": box.path("Applications/Gone.app/Contents/MacOS/updater"), "StartInterval": 3600])
        try box.file("Library/LaunchAgents/broken.plist", bytes: 20)

        let items = StartupItemsScanner.scan(locations: box.locations).filter { $0.scope == .user }
        #expect(items.map(\.label) == ["com.gone.updater", "com.example.tool.helper"], "orphans first, invalid plists ignored")
        let gone = items[0]
        #expect(gone.programMissing)
        #expect(gone.estimatedImpact == .low)
        #expect(gone.appPath == box.path("Applications/Gone.app"))
        let helper = items[1]
        #expect(!helper.programMissing && helper.estimatedImpact == .high)

        let removal = try #require(StartupItemsScanner.removalItem(for: gone))
        #expect(removal.risk == .safe)
        #expect(throws: Never.self) { try SafetyPolicy(locations: box.locations).validateForRemoval(removal).get() }
    }

    @Test func watchLowSpaceWithCooldown() {
        var watch = WatchEvaluator(configuration: WatchConfiguration(lowSpaceBytes: 10_000))
        let start = Date(timeIntervalSince1970: 0)
        #expect(watch.ingest(date: start, availableBytes: 20_000, cpu: nil).isEmpty)
        #expect(watch.ingest(date: start.addingTimeInterval(60), availableBytes: 5_000, cpu: nil) == [.lowSpace(available: 5_000)])
        #expect(watch.ingest(date: start.addingTimeInterval(120), availableBytes: 4_000, cpu: nil).isEmpty, "cooldown")
        #expect(watch.ingest(date: start.addingTimeInterval(7 * 3600), availableBytes: 4_000, cpu: nil) == [.lowSpace(available: 4_000)])
    }

    @Test func watchSpaceDropWithinAnHour() {
        var watch = WatchEvaluator(configuration: WatchConfiguration(spaceDropBytes: 1_000))
        let start = Date(timeIntervalSince1970: 0)
        _ = watch.ingest(date: start, availableBytes: 5_000, cpu: nil)
        #expect(watch.ingest(date: start.addingTimeInterval(1800), availableBytes: 3_500, cpu: nil) == [.spaceDropped(by: 1_500, available: 3_500)])
        // A slow decline spread over more than an hour does not alert.
        var slow = WatchEvaluator(configuration: WatchConfiguration(spaceDropBytes: 1_000))
        _ = slow.ingest(date: start, availableBytes: 5_000, cpu: nil)
        _ = slow.ingest(date: start.addingTimeInterval(3000), availableBytes: 4_400, cpu: nil)
        #expect(slow.ingest(date: start.addingTimeInterval(6000), availableBytes: 3_900, cpu: nil).isEmpty)
    }

    @Test func watchHighCPUNeedsSustainedLoad() {
        var watch = WatchEvaluator(configuration: WatchConfiguration(highCPUThreshold: 0.85, highCPUDuration: 300))
        let start = Date(timeIntervalSince1970: 0)
        var alerts: [WatchAlert] = []
        for minute in 0...5 {
            alerts += watch.ingest(date: start.addingTimeInterval(Double(minute) * 60), availableBytes: nil, cpu: minute == 2 ? 0.5 : 0.95)
        }
        #expect(alerts.isEmpty, "a dip inside the window prevents the alert")
        for minute in 6...12 {
            alerts += watch.ingest(date: start.addingTimeInterval(Double(minute) * 60), availableBytes: nil, cpu: 0.95)
        }
        #expect(alerts.count == 1)
        if case .sustainedHighCPU(let average, let minutes) = alerts.first {
            #expect(average >= 0.9 && minutes == 5)
        }
        #expect(WatchConfiguration(settings: NoriaSettings()).isEmpty, "notifications are off by default")
    }

    @Test func wholeDeveloperCachesAreRemovable() async throws {
        let box = try Sandbox()
        let npm = try box.file(".npm/_cacache/index-v5/aa", bytes: 5_000)
        let pip = try box.file("Library/Caches/pip/http/x", bytes: 5_000)
        let events = try await collect(SmartScanEngine(locations: box.locations, appRegistry: .empty).scan(settings: NoriaSettings()))
        guard case .finished(let report) = events.last else { return }
        let items = report.allItems.filter { $0.category == .developerCache }
        #expect(items.count == 2)
        let policy = SafetyPolicy(locations: box.locations)
        for item in items {
            #expect(throws: Never.self) { try policy.validateForRemoval(item).get() }
        }
        _ = (npm, pip)
    }

    @Test func developerScannerNamesAndClassifiesItems() throws {
        let box = try Sandbox()
        // DerivedData with the project path recorded by Xcode.
        try box.file("Library/Developer/Xcode/DerivedData/MyApp-abcdef/Build/x.o", bytes: 40_000)
        let info = try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": "/Users/me/Dev/MyApp.xcodeproj"], format: .xml, options: 0)
        try info.write(to: URL(fileURLWithPath: box.path("Library/Developer/Xcode/DerivedData/MyApp-abcdef/info.plist")))
        // An archive with its Info.plist.
        try box.file("Library/Developer/Xcode/Archives/2026-01-02/MyApp 2.xcarchive/Products/a", bytes: 20_000)
        let archiveInfo = try PropertyListSerialization.data(fromPropertyList: ["Name": "MyApp", "ApplicationProperties": ["CFBundleShortVersionString": "2.1"]], format: .xml, options: 0)
        try archiveInfo.write(to: URL(fileURLWithPath: box.path("Library/Developer/Xcode/Archives/2026-01-02/MyApp 2.xcarchive/Info.plist")))
        try box.file("Library/Developer/Xcode/watchOS DeviceSupport/10.2 (21S364)/Symbols/x", bytes: 20_000)
        // A simulator device.
        try box.file("Library/Developer/CoreSimulator/Devices/ABC/data/x", bytes: 20_000)
        let device = try PropertyListSerialization.data(fromPropertyList: ["name": "iPhone 15", "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-17-2"], format: .xml, options: 0)
        try device.write(to: URL(fileURLWithPath: box.path("Library/Developer/CoreSimulator/Devices/ABC/device.plist")))
        try box.file(".gradle/caches/modules/x.jar", bytes: 20_000)
        // A stale project with node_modules, and an active one.
        try box.file("Developer/old-site/package.json", bytes: 100, ageDays: 200)
        try box.file("Developer/old-site/node_modules/lib/index.js", bytes: 30_000, ageDays: 200)
        try box.setAge(box.path("Developer/old-site/node_modules"), days: 200)
        try box.file("Developer/new-site/package.json", bytes: 100)
        try box.file("Developer/new-site/node_modules/lib/index.js", bytes: 30_000)
        // A folder called node_modules without a manifest is not touched.
        try box.file("Developer/notes/node_modules/readme.txt", bytes: 30_000, ageDays: 200)

        let report = try DeveloperScanner(locations: box.locations).scan()
        let derived = try #require(report.items(for: .xcodeDerivedData).first)
        #expect(derived.title == "MyApp" && derived.risk == .safe)
        let archive = try #require(report.items(for: .xcodeArchives).first)
        #expect(archive.title == "MyApp" && archive.subtitle == "2.1" && archive.risk == .review)
        #expect(report.items(for: .xcodeDeviceSupport).first?.subtitle == "watchOS")
        let simulator = try #require(report.items(for: .simulators).first)
        #expect(simulator.title == "iPhone 15" && simulator.subtitle == "iOS 17 2")
        #expect(simulator.asScanItem() == nil, "simulators are removed with xcrun simctl only")
        #expect(report.items(for: .gradle).count == 1)
        let projects = report.items(for: .projectDependencies)
        #expect(projects.map(\.title) == ["old-site"])
        #expect(projects.first?.asScanItem()?.category == .largeFiles)

        let policy = SafetyPolicy(locations: box.locations)
        for item in report.items.compactMap({ $0.asScanItem() }) {
            #expect(throws: Never.self, "\(item.path)") { try policy.validateForRemoval(item).get() }
        }
    }
}
