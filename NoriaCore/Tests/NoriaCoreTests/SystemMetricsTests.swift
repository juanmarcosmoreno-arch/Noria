import Foundation
import Testing
@testable import NoriaCore

@Suite struct SystemMetricsTests {
    @Test func cpuUsageFromTickDeltas() {
        let earlier = CPUTicks(user: 100, system: 50, idle: 800, nice: 0)
        let later = CPUTicks(user: 160, system: 70, idle: 920, nice: 0)
        #expect(later.usage(since: earlier) == 0.4)
        #expect(earlier.usage(since: earlier) == nil)
        #expect(earlier.usage(since: later) == nil)
    }

    @Test func memoryUsedIsCappedAtTotal() {
        let snapshot = MemorySnapshot(total: 100, appMemory: 80, wired: 30, compressed: 10, swapUsed: nil, pressure: nil)
        #expect(snapshot.used == 100)
        #expect(snapshot.usedFraction == 1)
    }

    #if os(macOS)
    @Test func liveMetricsAreAvailableOnMacOS() throws {
        let ticks = try #require(SystemMetrics.cpuTicks())
        #expect(ticks.user + ticks.system + ticks.idle > 0)
        let memory = try #require(SystemMetrics.memory())
        #expect(memory.total == ProcessInfo.processInfo.physicalMemory)
        #expect(memory.used > 0 && memory.used <= memory.total)
        #expect(memory.swapUsed != nil)
        #expect(memory.pressure != nil)
    }
    #endif
}
