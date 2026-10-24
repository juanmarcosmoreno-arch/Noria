import NoriaCore
import SwiftUI

/// Hardware facts macOS exposes. Values macOS does not publish are shown as
/// "Not reported" — never estimated.
struct MacHealthView: View {
    @Environment(AppModel.self) private var model
    @State private var battery: BatteryInfo?
    @State private var storage = StorageDeviceInfo()
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoriaSpacing.l) {
                deviceCard
                if loaded {
                    if let battery { batteryCard(battery) } else { noBatteryCard }
                }
                storageCard
            }
            .padding(NoriaSpacing.xl)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(Text("Mac Health"))
        .task {
            let (battery, storage) = await Task.detached(priority: .userInitiated) {
                (BatteryInfo.current(), StorageDeviceInfo.forStartupDisk())
            }.value
            self.battery = battery
            self.storage = storage
            loaded = true
            model.refreshVolume()
        }
    }

    private var notReported: String { String(localized: "Not reported by macOS") }

    private var deviceCard: some View {
        let device = model.device
        return Card {
            VStack(alignment: .leading, spacing: NoriaSpacing.m) {
                CardHeader(title: "This Mac", systemImage: "desktopcomputer")
                InfoGrid(rows: [
                    (String(localized: "Model"), device.modelIdentifier ?? notReported),
                    (String(localized: "Processor"), device.processor ?? device.architecture),
                    (String(localized: "Cores"), Format.count(device.processorCount)),
                    (String(localized: "Memory"), Format.memory(device.physicalMemory)),
                    (String(localized: "macOS"), device.osVersion),
                    (String(localized: "Running since"), Format.dateTime(Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime))),
                ])
            }
        }
    }

    private func batteryCard(_ battery: BatteryInfo) -> some View {
        Card {
            VStack(alignment: .leading, spacing: NoriaSpacing.m) {
                CardHeader(title: "Battery", systemImage: "battery.75percent")
                HStack(spacing: NoriaSpacing.xl) {
                    MetricView(title: "Maximum capacity", value: battery.maximumCapacity.map { Format.percent($0) } ?? "—",
                               caption: String(localized: "compared with when it was new"))
                    MetricView(title: "Charge cycles", value: battery.cycleCount.map { Format.count($0) } ?? "—")
                    MetricView(title: "Condition", value: battery.condition.map(Self.localizedCondition) ?? "—")
                }
                InfoGrid(rows: [
                    (String(localized: "Charge"), battery.chargePercent.map { Format.percent(Double($0) / 100) } ?? notReported),
                    (String(localized: "Power"), battery.isPluggedIn.map { $0 ? String(localized: "Connected to power") : String(localized: "On battery") } ?? notReported),
                    (String(localized: "Charging"), battery.isCharging.map { $0 ? String(localized: "Yes") : String(localized: "No") } ?? notReported),
                    (String(localized: "Full-charge capacity"), battery.fullChargeCapacity.map(Self.milliampHours) ?? notReported),
                    (String(localized: "Design capacity"), battery.designCapacity.map(Self.milliampHours) ?? notReported),
                    (String(localized: "Temperature"), battery.temperatureCelsius.map(Self.celsius) ?? notReported),
                ])
                Text("Apple considers a battery consumed when it reaches about 80% of its original capacity. macOS shows its own recommendation in System Settings › Battery.")
                    .font(NoriaFont.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var noBatteryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: NoriaSpacing.s) {
                CardHeader(title: "Battery", systemImage: "powerplug")
                Text("This Mac has no battery.").foregroundStyle(.secondary)
            }
        }
    }

    private var storageCard: some View {
        Card {
            VStack(alignment: .leading, spacing: NoriaSpacing.m) {
                CardHeader(title: "Storage", systemImage: "internaldrive")
                if let volume = model.volume {
                    CapacityBar(fraction: volume.usedFraction)
                    Text("\(Format.bytes(volume.usedCapacity)) of \(Format.bytes(volume.totalCapacity))")
                        .font(NoriaFont.caption).foregroundStyle(.secondary)
                }
                InfoGrid(rows: [
                    (String(localized: "Device"), storage.model ?? notReported),
                    (String(localized: "Type"), storage.isSolidState.map { $0 ? String(localized: "Solid state (SSD)") : String(localized: "Hard disk") } ?? notReported),
                    (String(localized: "Connection"), storage.protocolName ?? notReported),
                    (String(localized: "File system"), model.volume?.formatDescription ?? notReported),
                    (String(localized: "Health (SMART)"), storage.smartStatus ?? notReported),
                ])
                Text("Apple's internal SSDs do not publish detailed wear data to apps. Noria shows SMART status only when macOS reports it; Disk Utility › First Aid checks the file system.")
                    .font(NoriaFont.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func milliampHours(_ value: Int) -> String {
        Measurement(value: Double(value), unit: UnitElectricCharge.milliampereHours).formatted(.measurement(width: .abbreviated))
    }

    static func celsius(_ value: Double) -> String {
        Measurement(value: value, unit: UnitTemperature.celsius)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))))
    }

    static func localizedCondition(_ value: String) -> String {
        switch value.lowercased() {
        case "good": return String(localized: "Normal")
        case "fair": return String(localized: "Fair")
        case "poor", "check battery": return String(localized: "Service recommended")
        default: return value
        }
    }
}

private struct InfoGrid: View {
    var rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: NoriaSpacing.xl, verticalSpacing: NoriaSpacing.xs) {
            ForEach(rows.indices, id: \.self) { index in
                GridRow {
                    Text(rows[index].0).font(NoriaFont.body).foregroundStyle(.secondary)
                    Text(rows[index].1).font(NoriaFont.body).textSelection(.enabled)
                }
            }
        }
    }
}
