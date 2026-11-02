import AppKit
import Charts
import NoriaCore
import SwiftUI

/// Live CPU, memory, swap and disk activity, and the processes using the most.
/// Everything shown is measured; there is no "free up RAM" button because macOS
/// manages memory better than any app can from outside.
struct PerformanceView: View {
    @Environment(AppModel.self) private var model
    @State private var processToQuit: NSRunningApplication?

    private var metrics: MetricsMonitor { model.metrics }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoriaSpacing.l) {
                insights
                LazyVGrid(columns: [GridItem(.flexible(), spacing: NoriaSpacing.l), GridItem(.flexible())], spacing: NoriaSpacing.l) {
                    ChartCard(title: "CPU", systemImage: "cpu",
                              value: metrics.cpuUsage.map { Format.percent($0) } ?? "—",
                              caption: String(localized: "\(Format.count(model.device.processorCount)) cores"),
                              points: metrics.cpuHistory, maximum: 1)
                    ChartCard(title: "Memory", systemImage: "memorychip",
                              value: metrics.memory.map { Format.memory($0.used) } ?? "—",
                              caption: memoryCaption,
                              points: metrics.memoryHistory, maximum: 1)
                    ChartCard(title: "Disk reads", systemImage: "arrow.down.doc",
                              value: metrics.diskReadRate.map { Format.bytes(Int64($0)) + "/s" } ?? "—",
                              caption: nil, points: metrics.diskReadHistory, maximum: nil)
                    ChartCard(title: "Disk writes", systemImage: "arrow.up.doc",
                              value: metrics.diskWriteRate.map { Format.bytes(Int64($0)) + "/s" } ?? "—",
                              caption: nil, points: metrics.diskWriteHistory, maximum: nil)
                }
                HStack(alignment: .top, spacing: NoriaSpacing.l) {
                    ProcessCard(title: "Most CPU", processes: metrics.topByCPU, showsCPU: true) { processToQuit = $0 }
                    ProcessCard(title: "Most memory", processes: metrics.topByMemory, showsCPU: false) { processToQuit = $0 }
                }
                Text("Noria lists the processes macOS lets it read (\(Format.count(metrics.visibleProcessCount)) right now). CPU is per core, like Activity Monitor: 200% means two cores fully busy.")
                    .font(NoriaFont.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(NoriaSpacing.xl)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(Text("Performance"))
        .onAppear { metrics.start(includeProcesses: true) }
        .onDisappear { metrics.stop(includeProcesses: true) }
        .confirmationDialog("Quit this app?", isPresented: Binding(get: { processToQuit != nil }, set: { if !$0 { processToQuit = nil } })) {
            Button("Quit") {
                processToQuit?.terminate()
                processToQuit = nil
            }
        } message: {
            Text("The app is asked to quit normally, so it can save your work.")
        }
    }

    private var memoryCaption: String {
        guard let memory = metrics.memory else { return "" }
        var parts = [String(localized: "of \(Format.memory(memory.total))")]
        if let pressure = memory.pressure { parts.append(String(localized: "pressure: \(pressure.title)")) }
        if let swap = memory.swapUsed { parts.append(String(localized: "swap: \(Format.memory(swap))")) }
        return parts.joined(separator: " · ")
    }

    /// Recommendations based only on what was measured.
    @ViewBuilder
    private var insights: some View {
        let messages = insightMessages
        if !messages.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: NoriaSpacing.s) {
                    CardHeader(title: "What Noria sees", systemImage: "lightbulb")
                    ForEach(messages, id: \.self) { message in
                        Label(message, systemImage: "info.circle")
                            .font(NoriaFont.body)
                    }
                }
            }
        }
    }

    private var insightMessages: [String] {
        var messages: [String] = []
        if let memory = metrics.memory, let pressure = memory.pressure, pressure != .normal {
            if let top = metrics.topByMemory.first {
                messages.append(String(localized: "Memory pressure is \(pressure.title.lowercased()). \(top.name) is using \(Format.memory(top.residentMemory)). Quitting apps you are not using helps; restarting the Mac also clears swap."))
            } else {
                messages.append(String(localized: "Memory pressure is \(pressure.title.lowercased()). Quitting apps you are not using helps."))
            }
        }
        if let busy = metrics.topByCPU.first, busy.cpu >= 0.8 {
            messages.append(String(localized: "\(busy.name) is using \(Format.percent(busy.cpu)) of a core. If you did not expect that, check whether it is stuck."))
        }
        if let swap = metrics.memory?.swapUsed, swap > 4_000_000_000 {
            messages.append(String(localized: "\(Format.memory(swap)) of swap in use: macOS is moving memory to the disk, which is slower."))
        }
        return messages
    }
}

private struct ChartCard: View {
    var title: LocalizedStringKey
    var systemImage: String
    var value: String
    var caption: String?
    var points: [MetricsMonitor.Point]
    /// Fixed top of the scale (1 for fractions); `nil` lets the chart scale itself.
    var maximum: Double?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: NoriaSpacing.s) {
                HStack {
                    CardHeader(title: title, systemImage: systemImage)
                    Text(value).font(NoriaFont.metric)
                }
                if let caption, !caption.isEmpty {
                    Text(caption).font(NoriaFont.caption).foregroundStyle(.secondary)
                }
                Chart(points) { point in
                    AreaMark(x: .value("Time", point.date), y: .value("Value", point.value))
                        .foregroundStyle(LinearGradient(colors: [NoriaColor.wood.opacity(0.35), NoriaColor.wood.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", point.date), y: .value("Value", point.value))
                        .foregroundStyle(NoriaColor.wood)
                }
                .chartYScale(domain: 0...(maximum ?? max(points.map(\.value).max() ?? 1, 1)))
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 90)
                .accessibilityHidden(true)
            }
        }
    }
}

private struct ProcessCard: View {
    var title: LocalizedStringKey
    var processes: [ProcessUsage]
    var showsCPU: Bool
    var onQuit: (NSRunningApplication) -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: NoriaSpacing.s) {
                CardHeader(title: title, systemImage: showsCPU ? "flame" : "memorychip")
                if processes.isEmpty {
                    Text("Measuring…").font(NoriaFont.caption).foregroundStyle(.secondary)
                }
                ForEach(processes) { process in
                    let app = NSRunningApplication(processIdentifier: process.pid)
                    HStack(spacing: NoriaSpacing.s) {
                        if let icon = app?.icon {
                            Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                        } else {
                            Image(systemName: "gearshape").frame(width: 18, height: 18).foregroundStyle(.secondary)
                        }
                        Text(app?.localizedName ?? process.name).lineLimit(1)
                        Spacer()
                        Text(showsCPU ? Format.percent(process.cpu) : Format.memory(process.residentMemory))
                            .font(NoriaFont.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if let app, app.activationPolicy == .regular, app != NSRunningApplication.current {
                            Button {
                                onQuit(app)
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                            .help(Text("Quit"))
                        }
                    }
                    .font(NoriaFont.body)
                }
            }
        }
    }
}
