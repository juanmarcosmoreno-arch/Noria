import NoriaCore
import SwiftUI

/// Phase 1 history: the local operation log. Charts and trends come in phase 4.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingClear = false

    private var cleanupsThisMonth: [OperationRecord] {
        let calendar = Calendar.current
        return model.history.filter { $0.kind == .cleanup && calendar.isDate($0.date, equalTo: Date(), toGranularity: .month) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: NoriaSpacing.l) {
                Card {
                    MetricView(title: "Removed this month",
                               value: Format.bytes(cleanupsThisMonth.reduce(0) { $0 + ($1.removedBytes ?? 0) }),
                               caption: String(localized: "Moved to the Trash or deleted by Noria"))
                }
                Card {
                    MetricView(title: "Cleanups this month", value: Format.count(cleanupsThisMonth.count))
                }
                Card {
                    MetricView(title: "Recorded operations", value: Format.count(model.history.count))
                }
            }
            .padding(NoriaSpacing.l)

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
        .navigationTitle(Text("History"))
        .toolbar {
            ToolbarItem {
                Button(role: .destructive) {
                    confirmingClear = true
                } label: {
                    Label("Clear History", systemImage: "trash")
                }
                .disabled(model.history.isEmpty)
            }
        }
        .confirmationDialog("Clear the history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
        } message: {
            Text("This deletes Noria's local log. Files are not affected.")
        }
        .task { await model.loadHistory() }
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
        }
    }

    private var title: String {
        switch record.kind {
        case .smartScan: return String(localized: "Smart Scan")
        case .largeFileScan: return String(localized: "Large Files scan")
        case .cleanup:
            return record.method == .deletePermanently
                ? String(localized: "Cleanup (deleted)")
                : String(localized: "Cleanup (moved to Trash)")
        }
    }

    private var summary: String {
        switch record.kind {
        case .smartScan:
            return String(localized: "\(Format.bytes(record.recoverableBytes ?? 0)) recoverable · \(Format.count(record.itemsFound ?? 0)) items")
        case .largeFileScan:
            return String(localized: "\(Format.count(record.itemsFound ?? 0)) files · \(Format.bytes(record.recoverableBytes ?? 0))")
        case .cleanup:
            var text = String(localized: "\(Format.bytes(record.removedBytes ?? 0)) · \(Format.count(record.removedPaths.count)) items")
            if !record.failures.isEmpty {
                text += " · " + String(localized: "\(Format.count(record.failures.count)) skipped")
            }
            return text
        }
    }
}
