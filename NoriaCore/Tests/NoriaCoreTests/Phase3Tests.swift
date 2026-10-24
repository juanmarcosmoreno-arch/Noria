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
}
