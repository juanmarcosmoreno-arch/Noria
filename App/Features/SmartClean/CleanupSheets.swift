import NoriaCore
import SwiftUI

/// Last step before anything is removed: shows exactly what will happen.
struct CleanupConfirmationView: View {
    var items: [ScanItem]
    var method: RemovalMethod
    var onConfirm: () -> Void
    var onCancel: () -> Void

    @State private var acknowledgedPermanent = false
    @State private var runningApps: [String] = []

    private var totalSize: Int64 { items.reduce(0) { $0 + $1.allocatedSize } }
    private var reviewCount: Int { items.filter { $0.risk == .review }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: NoriaSpacing.m) {
            HStack(spacing: NoriaSpacing.m) {
                TurbineMark().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Confirm cleanup").font(NoriaFont.title)
                    Text("\(Format.count(items.count)) items · \(Format.bytes(totalSize))")
                        .foregroundStyle(.secondary)
                }
            }

            switch method {
            case .moveToTrash:
                Label("Items will be moved to the Trash. You can put them back from Finder. Space is freed when you empty the Trash.",
                      systemImage: "trash")
            case .deletePermanently:
                Label("Items will be deleted immediately and cannot be recovered.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(NoriaColor.danger)
            }

            if reviewCount > 0 {
                Label("\(Format.count(reviewCount)) selected items are marked REVIEW. Make sure you no longer need them.",
                      systemImage: "eye")
                    .foregroundStyle(NoriaColor.review)
            }

            if !runningApps.isEmpty {
                let names = runningApps.formatted(.list(type: .and))
                Label("These apps are running: \(names). Quit them before cleaning their data.",
                      systemImage: "exclamationmark.circle")
                    .foregroundStyle(NoriaColor.review)
            }

            List(items) { item in
                HStack {
                    CategoryIcon(category: item.category, size: 20)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.name).lineLimit(1)
                        Text(item.path).font(NoriaFont.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    RiskBadge(risk: item.risk)
                    Text(Format.bytes(item.allocatedSize)).monospacedDigit().frame(width: 76, alignment: .trailing)
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 180)

            Text("Before acting, Noria re-checks every item: anything that changed since the scan, is protected, or is excluded is skipped.")
                .font(NoriaFont.caption)
                .foregroundStyle(.secondary)

            if method == .deletePermanently {
                Toggle("I understand these items cannot be recovered", isOn: $acknowledgedPermanent)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(method == .moveToTrash ? LocalizedStringKey("Move to Trash") : LocalizedStringKey("Delete"), role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(items.isEmpty || (method == .deletePermanently && !acknowledgedPermanent))
            }
        }
        .padding(NoriaSpacing.l)
        .frame(width: 620, height: 560)
        .onAppear { runningApps = AppDirectory.runningApps(relatedTo: items) }
    }
}

/// Progress and result of a cleanup. Distinguishes moved-to-Trash from freed space.
struct CleanupProgressView: View {
    var controller: CleanupController
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: NoriaSpacing.l) {
            switch controller.state {
            case .idle, .running:
                running
            case .finished:
                if let report = controller.report {
                    CleanupResultView(report: report, onDone: onDone)
                }
            }
        }
        .padding(NoriaSpacing.xl)
        .frame(width: 520)
        .interactiveDismissDisabled(controller.isRunning)
    }

    @ViewBuilder
    private var running: some View {
        TurbineView(isSpinning: true).frame(width: 90, height: 90)
        Text("Cleaning…").font(NoriaFont.title)
        if case .running(let done, let total) = controller.state {
            ProgressView(value: Double(done), total: Double(max(total, 1)))
            Text("\(Format.count(done)) of \(Format.count(total))").foregroundStyle(.secondary)
        }
        if let path = controller.currentPath {
            Text(path).font(NoriaFont.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        Button("Stop") { controller.cancel() }
            .buttonStyle(SecondaryButtonStyle())
    }
}

struct CleanupResultView: View {
    var report: CleanupReport
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NoriaSpacing.m) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Format.bytes(report.removedSize))
                        .font(NoriaFont.heroValue)
                    Text(report.method == .moveToTrash ? LocalizedStringKey("moved to the Trash") : LocalizedStringKey("deleted"))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: report.failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(report.failed.isEmpty ? NoriaColor.safe : NoriaColor.review)
            }

            Grid(alignment: .leading, horizontalSpacing: NoriaSpacing.l, verticalSpacing: NoriaSpacing.xs) {
                GridRow {
                    Text("Items removed").foregroundStyle(.secondary)
                    Text(Format.count(report.removed.count))
                }
                GridRow {
                    Text("Skipped or failed").foregroundStyle(.secondary)
                    Text(Format.count(report.failed.count))
                }
                if report.method == .moveToTrash {
                    GridRow {
                        Text("In the Trash").foregroundStyle(.secondary)
                        Text(Format.bytes(report.movedToTrashSize))
                    }
                } else if let freed = report.measuredFreedSize {
                    GridRow {
                        Text("Free space change (measured)").foregroundStyle(.secondary)
                        Text(Format.bytes(freed))
                    }
                }
            }
            .font(NoriaFont.body)

            if report.method == .moveToTrash {
                Text("Space is freed when you empty the Trash in Finder. Until then you can restore anything with Put Back.")
                    .font(NoriaFont.caption)
                    .foregroundStyle(.secondary)
            }
            if report.wasCancelled {
                Text("Stopped before finishing. Remaining items were not touched.")
                    .font(NoriaFont.caption)
                    .foregroundStyle(NoriaColor.review)
            }

            if !report.failed.isEmpty {
                DisclosureGroup("Details of skipped items") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: NoriaSpacing.xs) {
                            ForEach(report.failed) { outcome in
                                VStack(alignment: .leading, spacing: 0) {
                                    Text("\(outcome.statusTitle): \((outcome.path as NSString).lastPathComponent)").font(NoriaFont.caption.weight(.medium))
                                    Text(outcome.message ?? "").font(NoriaFont.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
            }

            HStack {
                if report.method == .moveToTrash && !report.removed.isEmpty {
                    Button("Open Trash") { SystemActions.openTrash() }
                        .buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
