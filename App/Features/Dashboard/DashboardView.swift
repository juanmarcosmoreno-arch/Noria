import NoriaCore
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoriaSpacing.l) {
                HeroCard()
                if model.smartScan.phase != .idle {
                    AnalysisCard()
                }
                if !model.smartScan.recommendations.isEmpty {
                    RecommendationsCard()
                }
                DeviceCard()
            }
            .padding(NoriaSpacing.xl)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(Text("Dashboard"))
        .onAppear {
            model.refreshVolume()
            model.metrics.start()
        }
        .onDisappear { model.metrics.stop() }
    }
}

// MARK: - Hero

private struct HeroCard: View {
    @Environment(AppModel.self) private var model

    private var scan: SmartScanModel { model.smartScan }

    var body: some View {
        Card(padding: NoriaSpacing.xl) {
            HStack(alignment: .center, spacing: NoriaSpacing.xl) {
                SawProgressView(isActive: scan.isScanning, progress: scan.categoryProgress,
                                lineWidth: 7, showsRing: scan.isScanning)
                    .frame(width: 280, height: 280)

                VStack(alignment: .leading, spacing: NoriaSpacing.m) {
                    header
                    StorageSummary()
                    HStack(spacing: NoriaSpacing.s) {
                        RecoverableTile()
                        CPUTile()
                        MemoryTile()
                    }
                    actions
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: NoriaSpacing.xxs) {
            switch scan.phase {
            case .idle:
                Text("Make space. Run better.").font(NoriaFont.title)
                Text("Analyze, clean and free up space safely.").foregroundStyle(.secondary)
            case .scanning:
                Text("Analyzing your Mac…").font(NoriaFont.title)
                if let category = scan.currentCategory {
                    Label(category.title, systemImage: category.systemImage)
                        .foregroundStyle(NoriaColor.accent)
                }
            case .finished:
                Text("Analysis complete").font(NoriaFont.title)
                if let report = scan.report {
                    let duration = Format.duration(report.finishedAt.timeIntervalSince(report.startedAt))
                    Text("Found \(Format.count(report.allItems.count)) items in \(duration).")
                        .foregroundStyle(.secondary)
                }
            case .cancelled:
                Text("Scan cancelled").font(NoriaFont.title)
                Text("No files were changed. Results are partial and have been discarded.")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text("The scan could not finish").font(NoriaFont.title)
                Text(message).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch scan.phase {
        case .scanning:
            HStack(spacing: NoriaSpacing.l) {
                MetricView(title: "Files examined", value: Format.count(scan.filesVisited))
                MetricView(title: "Found", value: Format.bytes(scan.bytesFound))
                if let start = scan.startedAt {
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        MetricView(title: "Elapsed", value: Format.duration(context.date.timeIntervalSince(start)))
                    }
                }
                Spacer()
                Button("Cancel") { scan.cancel() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        case .finished:
            HStack(spacing: NoriaSpacing.s) {
                Button {
                    model.selection = .smartClean
                } label: {
                    Label("Review and Clean", systemImage: "checklist")
                }
                .buttonStyle(PrimaryButtonStyle(prominent: true))
                Button("Analyze Again") { scan.start() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        case .idle, .cancelled, .failed:
            Button {
                scan.start()
            } label: {
                Label("Analyze My Mac", systemImage: "play.fill")
            }
            .buttonStyle(PrimaryButtonStyle(prominent: true))
            .keyboardShortcut(.defaultAction)
        }
    }
}

/// Startup volume: name, used of total, percentage and capacity bar.
private struct StorageSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .center, spacing: NoriaSpacing.m) {
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 30))
                .foregroundStyle(NoriaColor.steelMid)
            if let volume = model.volume {
                VStack(alignment: .leading, spacing: NoriaSpacing.xs) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(volume.name.isEmpty ? String(localized: "Startup Disk") : volume.name)
                                .font(NoriaFont.body.weight(.semibold))
                            Text("\(Format.bytes(volume.usedCapacity)) of \(Format.bytes(volume.totalCapacity))")
                                .font(NoriaFont.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(Format.percent(volume.usedFraction)).font(NoriaFont.metric)
                            Text("used").font(NoriaFont.caption).foregroundStyle(.secondary)
                        }
                    }
                    CapacityBar(fraction: volume.usedFraction)
                    Text(volume.purgeableCapacity > 0
                         ? String(localized: "\(Format.bytes(volume.availableForImportantUsage)) available, including \(Format.bytes(volume.purgeableCapacity)) purgeable")
                         : String(localized: "\(Format.bytes(volume.availableForImportantUsage)) available"))
                        .font(NoriaFont.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let error = model.volumeError {
                Text(error).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(NoriaSpacing.m)
        .background(NoriaColor.subtleFill.opacity(0.6), in: RoundedRectangle(cornerRadius: NoriaRadius.card - 4, style: .continuous))
    }
}

/// Small metric tile used in the hero (recoverable space, CPU, memory).
private struct MetricTile: View {
    var title: LocalizedStringKey
    var systemImage: String
    var value: String
    var caption: String?

    var body: some View {
        HStack(alignment: .top, spacing: NoriaSpacing.s) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundStyle(NoriaColor.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(NoriaFont.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(value).font(NoriaFont.metric).lineLimit(1).minimumScaleFactor(0.7)
                Text(caption ?? " ").font(NoriaFont.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(NoriaSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoriaColor.subtleFill.opacity(0.6), in: RoundedRectangle(cornerRadius: NoriaRadius.small + 2, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct RecoverableTile: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let report = model.smartScan.report
        MetricTile(title: "Recoverable space", systemImage: "wand.and.stars",
                   value: report.map { Format.bytes($0.recoverableSize) } ?? "—",
                   caption: report.map { String(localized: "\(Format.bytes($0.safeSize)) marked safe") }
                       ?? String(localized: "Run an analysis to calculate"))
    }
}

private struct CPUTile: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        MetricTile(title: "CPU", systemImage: "cpu",
                   value: model.metrics.cpuUsage.map { Format.percent($0) } ?? "—",
                   caption: String(localized: "\(Format.count(model.device.processorCount)) cores"))
    }
}

private struct MemoryTile: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let memory = model.metrics.memory
        MetricTile(title: "Memory", systemImage: "memorychip",
                   value: memory.map { Format.memory($0.used) } ?? "—",
                   caption: String(localized: "of \(Format.memory(model.device.physicalMemory))"))
    }
}

// MARK: - Analysis

/// Per-category status of the current or last Smart Scan.
private struct AnalysisCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let scan = model.smartScan
        Card {
            VStack(alignment: .leading, spacing: NoriaSpacing.s) {
                CardHeader(title: "Smart Clean", systemImage: "sparkles") {
                    if scan.phase == .finished, let report = scan.report {
                        Text("\(Format.bytes(report.recoverableSize)) recoverable")
                            .font(NoriaFont.body.weight(.semibold))
                            .foregroundStyle(NoriaColor.accent)
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: NoriaSpacing.l), GridItem(.flexible())], spacing: 2) {
                    ForEach(scan.plannedCategories) { category in
                        HStack(spacing: NoriaSpacing.s) {
                            CategoryIcon(category: category, size: 26)
                            Text(category.title).font(NoriaFont.body)
                            Spacer()
                            trailing(for: category, scan: scan)
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, NoriaSpacing.xs)
                        .background(scan.currentCategory == category ? NoriaColor.subtleFill : .clear,
                                    in: RoundedRectangle(cornerRadius: NoriaRadius.small))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func trailing(for category: CleanCategory, scan: SmartScanModel) -> some View {
        if let result = scan.results[category] {
            if !result.locationExists {
                Text("Not present").font(NoriaFont.caption).foregroundStyle(.tertiary)
            } else if result.items.isEmpty && result.inaccessibleCount > 0 {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    .help(Text("Noria does not have permission to read this location."))
            } else {
                HStack(spacing: 6) {
                    Text(Format.bytes(category == .trash ? result.totalSize : result.items.filter(\.isSelectable).reduce(0) { $0 + $1.allocatedSize }))
                        .font(NoriaFont.body.monospacedDigit())
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(NoriaColor.safe)
                }
            }
        } else if scan.currentCategory == category {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Device

private struct DeviceCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let device = model.device
        let memory = model.metrics.memory
        Card {
            VStack(alignment: .leading, spacing: NoriaSpacing.m) {
                CardHeader(title: "This Mac", systemImage: "desktopcomputer")
                Grid(alignment: .leading, horizontalSpacing: NoriaSpacing.xl, verticalSpacing: NoriaSpacing.xs) {
                    GridRow {
                        row("Model", device.modelIdentifier ?? "—")
                        row("Memory", Format.memory(device.physicalMemory))
                    }
                    GridRow {
                        row("Processor", device.processor ?? device.architecture)
                        row("Memory pressure", memory?.pressure?.title ?? "—")
                    }
                    GridRow {
                        row("macOS", device.osVersion)
                        row("Swap used", memory?.swapUsed.map { Format.memory($0) } ?? "—")
                    }
                }
                Text("Battery health and per-process activity arrive with Mac Health and Performance (phase 3).")
                    .font(NoriaFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(spacing: NoriaSpacing.s) {
            Text(title).font(NoriaFont.body).foregroundStyle(.secondary)
            Spacer(minLength: NoriaSpacing.s)
            Text(value).font(NoriaFont.body).textSelection(.enabled).lineLimit(1)
        }
    }
}

// MARK: - Recommendations

private struct RecommendationsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let recommendations = Array(model.smartScan.recommendations.prefix(6))
        Card {
            VStack(alignment: .leading, spacing: NoriaSpacing.m) {
                CardHeader(title: "Recommendations", systemImage: "lightbulb")
                ForEach(recommendations) { recommendation in
                    HStack(alignment: .top, spacing: NoriaSpacing.m) {
                        Image(systemName: recommendation.risk == .safe ? "checkmark.shield" : "eye")
                            .foregroundStyle(recommendation.risk.color)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(recommendation.title).font(NoriaFont.body.weight(.medium))
                            Text(recommendation.detail).font(NoriaFont.caption).foregroundStyle(.secondary)
                            HStack(spacing: NoriaSpacing.xs) {
                                RiskBadge(risk: recommendation.risk)
                                Text(recommendation.confidenceTitle).font(NoriaFont.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(Format.bytes(recommendation.bytes)).font(NoriaFont.body.monospacedDigit())
                        actionButton(for: recommendation)
                    }
                    if recommendation.id != recommendations.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actionButton(for recommendation: Recommendation) -> some View {
        switch recommendation.action {
        case .reviewItems:
            Button("Review") { model.selection = .smartClean }
                .buttonStyle(SecondaryButtonStyle())
        case .emptyTrashInFinder:
            Button("Open Trash") { SystemActions.openTrash() }
                .buttonStyle(SecondaryButtonStyle())
        }
    }
}

extension MemoryPressure {
    var title: String {
        switch self {
        case .normal: return String(localized: "Normal")
        case .warning: return String(localized: "Elevated")
        case .critical: return String(localized: "Critical")
        }
    }
}
