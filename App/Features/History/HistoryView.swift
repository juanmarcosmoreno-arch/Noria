import Charts
import NoriaCore
import SwiftUI

/// Quarantine (restore or delete for good) and the local operation log.
/// Charts and trends come in phase 4.
struct HistoryView: View {
    enum Tab: Hashable { case quarantine, activity }

    @Environment(AppModel.self) private var model
    @State private var confirmingClear = false
    @State private var tab: Tab = .quarantine

    private var cleanupsThisMonth: [OperationRecord] {
        let calendar = Calendar.current
        return model.history.filter { $0.kind == .cleanup && calendar.isDate($0.date, equalTo: Date(), toGranularity: .month) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                Text("Quarantine").tag(Tab.quarantine)
                Text("Activity").tag(Tab.activity)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            .padding(.top, NoriaSpacing.m)
            switch tab {
            case .quarantine: QuarantineView()
            case .activity: activity
            }
        }
        .navigationTitle(Text("History"))
        .toolbar {
            if tab == .activity {
                ToolbarItem {
                    Button(role: .destructive) {
                        confirmingClear = true
                    } label: {
                        Label("Clear History", systemImage: "trash")
                    }
                    .disabled(model.history.isEmpty)
                }
            }
        }
        .confirmationDialog("Clear the history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
        } message: {
            Text("This deletes Noria's local log. Files are not affected.")
        }
        .task {
            await model.loadHistory()
            await model.refreshQuarantine()
        }
    }

    private var activity: some View {
        VStack(spacing: 0) {
            HStack(spacing: NoriaSpacing.l) {
                Card {
                    MetricView(title: "Removed this month",
                               value: Format.bytes(cleanupsThisMonth.reduce(0) { $0 + ($1.removedBytes ?? 0) }),
                               caption: String(localized: "Moved to quarantine or Trash, or deleted by Noria"))
                }
                Card {
                    MetricView(title: "Cleanups this month", value: Format.count(cleanupsThisMonth.count))
                }
                Card {
                    MetricView(title: "Recorded operations", value: Format.count(model.history.count))
                }
            }
            .padding(NoriaSpacing.l)

            if !model.history.isEmpty {
                HistoryCharts(records: model.history)
                    .padding(.horizontal, NoriaSpacing.l)
                    .padding(.bottom, NoriaSpacing.m)
            }

            if model.history.isEmpty {
                EmptyStateView(title: "No history yet",
                               message: "Scans and cleanups are recorded here. The log is stored only on this Mac.",
                               systemImage: "clock")
            } else {
                List(model.history) { record in
                    HistoryRow(record: record)
                }
                .listStyle(.inset)
            }
        }
    }
}

/// Items Noria moved to its quarantine: restore them or delete them for good.
private struct QuarantineView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<QuarantineEntry.ID> = []
    @State private var confirmingDelete = false

    private var selectedEntries: [QuarantineEntry] { model.quarantineEntries.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: NoriaSpacing.l) {
                Card {
                    MetricView(title: "In quarantine", value: Format.bytes(model.quarantineSize),
                               caption: String(localized: "Not freed until deleted"))
                }
                Card {
                    MetricView(title: "Kept for", value: String(localized: "\(model.settings.quarantineRetentionDays) days"),
                               caption: String(localized: "Then deleted automatically"))
                }
            }
            .padding(NoriaSpacing.l)

            if let message = model.quarantineMessage {
                Text(message)
                    .font(NoriaFont.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, NoriaSpacing.l)
                    .padding(.bottom, NoriaSpacing.s)
            }

            if model.quarantineEntries.isEmpty {
                EmptyStateView(title: "Quarantine is empty",
                               message: "When Noria cleans something, it is kept here first so you can restore it. Choose the method and the number of days in Settings.",
                               systemImage: "archivebox")
            } else {
                Table(model.quarantineEntries, selection: $selection) {
                    TableColumn("Name") { entry in
                        HStack {
                            CategoryIcon(category: entry.category, size: 20)
                            Text(entry.name).lineLimit(1)
                        }
                    }
                    TableColumn("Original location") { entry in
                        Text((entry.originalPath as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    TableColumn("Size") { entry in
                        Text(Format.bytes(entry.allocatedSize)).monospacedDigit()
                    }
                    .width(80)
                    TableColumn("Quarantined") { entry in
                        Text(Format.dateTime(entry.quarantinedAt)).foregroundStyle(.secondary)
                    }
                    .width(min: 120, ideal: 140)
                    TableColumn("Deleted on") { entry in
                        Text(Format.date(entry.expiresAt(retentionDays: model.settings.quarantineRetentionDays)))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 90, ideal: 110)
                }
                .contextMenu(forSelectionType: QuarantineEntry.ID.self) { ids in
                    let entries = model.quarantineEntries.filter { ids.contains($0.id) }
                    Button("Restore") { model.restore(entries) }
                    Button("Reveal in Finder") { SystemActions.revealInFinder(entries.map { model.quarantinePath(of: $0) }) }
                }
            }

            Divider()
            HStack {
                Text("Restoring puts items back exactly where they were. Nothing is overwritten.")
                    .font(NoriaFont.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restore") { model.restore(selectedEntries) }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(selection.isEmpty)
                Button(selection.isEmpty ? LocalizedStringKey("Empty Quarantine…") : LocalizedStringKey("Delete Selected…")) {
                    confirmingDelete = true
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.quarantineEntries.isEmpty)
            }
            .padding(.horizontal, NoriaSpacing.l)
            .padding(.vertical, NoriaSpacing.s)
            .background(.bar)
        }
        .confirmationDialog("Delete for good?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                model.deleteFromQuarantine(selection.isEmpty ? model.quarantineEntries : selectedEntries)
                selection = []
            }
        } message: {
            let entries = selection.isEmpty ? model.quarantineEntries : selectedEntries
            let total = Format.bytes(entries.reduce(0) { $0 + $1.allocatedSize })
            Text("\(Format.count(entries.count)) items (\(total)) will be deleted and can no longer be restored. This frees the space.")
        }
    }
}

private struct HistoryRow: View {
    var record: OperationRecord

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: NoriaSpacing.xs) {
                if !record.removedPaths.isEmpty {
                    Text("Removed items").font(NoriaFont.caption.weight(.semibold))
                    ForEach(record.removedPaths.prefix(50), id: \.self) { path in
                        Text(path).font(NoriaFont.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if record.removedPaths.count > 50 {
                        Text("and \(Format.count(record.removedPaths.count - 50)) more").font(NoriaFont.caption).foregroundStyle(.secondary)
                    }
                }
                if !record.failures.isEmpty {
                    Text("Skipped or failed").font(NoriaFont.caption.weight(.semibold))
                    ForEach(record.failures.prefix(50), id: \.path) { failure in
                        Text("\(failure.path) — \(failure.message)").font(NoriaFont.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            .padding(.leading, NoriaSpacing.xl)
        } label: {
            HStack(spacing: NoriaSpacing.m) {
                Image(systemName: icon).foregroundStyle(NoriaColor.accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(NoriaFont.body.weight(.medium))
                    Text(Format.dateTime(record.date)).font(NoriaFont.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(summary).font(NoriaFont.body.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var icon: String {
        switch record.kind {
        case .smartScan: return "sparkle.magnifyingglass"
        case .largeFileScan: return "doc.on.doc"
        case .cleanup: return "trash"
        case .restore: return "arrow.uturn.backward.circle"
        case .quarantineDeletion: return "archivebox"
        }
    }

    private var title: String {
        switch record.kind {
        case .smartScan: return String(localized: "Smart Scan")
        case .largeFileScan: return String(localized: "Large Files scan")
        case .cleanup:
            switch record.method {
            case .deletePermanently: return String(localized: "Cleanup (deleted)")
            case .quarantine: return String(localized: "Cleanup (moved to quarantine)")
            case .moveToTrash, nil: return String(localized: "Cleanup (moved to Trash)")
            }
        case .restore: return String(localized: "Restored from quarantine")
        case .quarantineDeletion: return String(localized: "Deleted from quarantine")
        }
    }

    private var summary: String {
        switch record.kind {
        case .smartScan:
            return String(localized: "\(Format.bytes(record.recoverableBytes ?? 0)) recoverable · \(Format.count(record.itemsFound ?? 0)) items")
        case .largeFileScan:
            return String(localized: "\(Format.count(record.itemsFound ?? 0)) files · \(Format.bytes(record.recoverableBytes ?? 0))")
        case .cleanup, .restore, .quarantineDeletion:
            var text = String(localized: "\(Format.bytes(record.removedBytes ?? 0)) · \(Format.count(record.removedPaths.count)) items")
            if !record.failures.isEmpty {
                text += " · " + String(localized: "\(Format.count(record.failures.count)) skipped")
            }
            return text
        }
    }
}

/// Evolution charts built from the local operation log.
private struct HistoryCharts: View {
    var records: [OperationRecord]

    private struct Point: Identifiable {
        var date: Date
        var bytes: Int64
        var id: Date { date }
    }

    /// Bytes removed by Noria per month, last 6 months.
    private var monthly: [Point] {
        let calendar = Calendar.current
        var totals: [Date: Int64] = [:]
        for record in records where record.kind == .cleanup {
            guard let month = calendar.dateInterval(of: .month, for: record.date)?.start else { continue }
            totals[month, default: 0] += record.removedBytes ?? 0
        }
        let start = calendar.date(byAdding: .month, value: -5, to: calendar.dateInterval(of: .month, for: Date())?.start ?? Date()) ?? Date()
        return (0..<6).compactMap { offset in
            calendar.date(byAdding: .month, value: offset, to: start).map { Point(date: $0, bytes: totals[$0] ?? 0) }
        }
    }

    /// Free space measured at each Smart Scan.
    private var freeSpace: [Point] {
        records.filter { $0.kind == .smartScan }
            .compactMap { record in record.volumeAvailableBytes.map { Point(date: record.date, bytes: $0) } }
            .sorted { $0.date < $1.date }
    }

    var body: some View {
        HStack(alignment: .top, spacing: NoriaSpacing.l) {
            Card {
                VStack(alignment: .leading, spacing: NoriaSpacing.s) {
                    CardHeader(title: "Cleaned per month", systemImage: "chart.bar")
                    Chart(monthly) { point in
                        BarMark(x: .value("Month", point.date, unit: .month), y: .value("Bytes", Double(point.bytes)))
                            .foregroundStyle(NoriaColor.woodGradient)
                            .cornerRadius(4)
                    }
                    .chartYAxis { bytesAxis }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .month)) { _ in
                            AxisValueLabel(format: .dateTime.month(.abbreviated))
                        }
                    }
                    .frame(height: 140)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: NoriaSpacing.s) {
                    CardHeader(title: "Free space at each analysis", systemImage: "chart.line.uptrend.xyaxis")
                    if freeSpace.count < 2 {
                        Text("Run Smart Scan on different days to see how your free space evolves.")
                            .font(NoriaFont.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
                    } else {
                        Chart(freeSpace) { point in
                            LineMark(x: .value("Date", point.date), y: .value("Bytes", Double(point.bytes)))
                                .foregroundStyle(NoriaColor.wood)
                            PointMark(x: .value("Date", point.date), y: .value("Bytes", Double(point.bytes)))
                                .foregroundStyle(NoriaColor.woodDark)
                        }
                        .chartYAxis { bytesAxis }
                        .frame(height: 140)
                    }
                }
            }
        }
    }

    private var bytesAxis: some AxisContent {
        AxisMarks { value in
            AxisGridLine()
            AxisValueLabel {
                if let bytes = value.as(Double.self) {
                    Text(verbatim: Format.bytes(Int64(bytes)))
                }
            }
        }
    }
}
