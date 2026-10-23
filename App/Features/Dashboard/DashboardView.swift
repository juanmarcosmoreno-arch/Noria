import NoriaCore
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoriaSpacing.l) {
                ScanHeroCard()
                HStack(alignment: .top, spacing: NoriaSpacing.l) {
                    StorageCard()
                    DeviceCard()
                }
                if !model.smartScan.recommendations.isEmpty {
                    RecommendationsCard()
                }
            }
            .padding(NoriaSpacing.xl)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(Text("Dashboard"))
        .onAppear { model.refreshVolume() }
    }
}

// MARK: - Smart Scan hero

private struct ScanHeroCard: View {
    @Environment(AppModel.self) private var model

    private var scan: SmartScanModel { model.smartScan }

    var body: some View {
        Card(padding: NoriaSpacing.xl) {
            HStack(alignment: .center, spacing: NoriaSpacing.xl) {
                TurbineProgressView(isActive: scan.isScanning, progress: scan.categoryProgress, lineWidth: 7)
                    .frame(width: 190, height: 190)

                VStack(alignment: .leading, spacing: NoriaSpacing.s) {
                    status
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                CategoryChecklist()
                    .frame(width: 300)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch scan.phase {
        case .idle:
            Text("Make space. Run better.").font(NoriaFont.title)
            Text("Noria analyzes caches, logs, temporary files, developer data and old downloads. Nothing is removed without your review and confirmation.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            analyzeButton.padding(.top, NoriaSpacing.xs)

        case .scanning:
            Text("Analyzing your Mac…").font(NoriaFont.title)
            if let category = scan.currentCategory {
                Label(category.title, systemImage: category.systemImage)
                    .foregroundStyle(NoriaColor.primaryBlue)
            }
            scanCounters
            Button("Cancel") { scan.cancel() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                .padding(.top, NoriaSpacing.xs)

        case .finished:
            if let report = scan.report {
                Text(Format.bytes(report.recoverableSize))
                    .font(NoriaFont.heroValue)
                    .foregroundStyle(NoriaColor.primaryBlue)
                Text("potentially recoverable · \(Format.bytes(report.safeSize)) marked safe")
                    .foregroundStyle(.secondary)
                let duration = Format.duration(report.finishedAt.timeIntervalSince(report.startedAt))
                Text("Found \(Format.count(report.allItems.count)) items in \(duration).")
                    .font(NoriaFont.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: NoriaSpacing.s) {
                    Button("Review and Clean") { model.selection = .smartClean }
                        .buttonStyle(PrimaryButtonStyle())
                    Button("Analyze Again") { scan.start() }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .padding(.top, NoriaSpacing.xs)
            }

        case .cancelled:
            Text("Scan cancelled").font(NoriaFont.title)
            Text("No files were changed. Results are partial and have been discarded.")
                .foregroundStyle(.secondary)
            analyzeButton

        case .failed(let message):
            Text("The scan could not finish").font(NoriaFont.title)
            Text(message).foregroundStyle(.secondary).textSelection(.enabled)
            analyzeButton
        }
    }

    private var analyzeButton: some View {
        Button {
            scan.start()
        } label: {
            Label("Analyze My Mac", systemImage: "sparkle.magnifyingglass")
        }
        .buttonStyle(PrimaryButtonStyle())
        .keyboardShortcut(.defaultAction)
    }

    private var scanCounters: some View {
        HStack(spacing: NoriaSpacing.l) {
            MetricView(title: "Files examined", value: Format.count(scan.filesVisited))
            MetricView(title: "Found", value: Format.bytes(scan.bytesFound))
            if let start = scan.startedAt {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    MetricView(title: "Elapsed", value: Format.duration(context.date.timeIntervalSince(start)))
                }
            }
        }
    }
}

/// Per-category status list, as in the reference design.
private struct CategoryChecklist: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let scan = model.smartScan
        let categories = scan.plannedCategories.isEmpty
            ? CleanCategory.smartScanCategories.filter { model.settings.enabledCategories.contains($0) }
            : scan.plannedCategories
        VStack(spacing: 2) {
            ForEach(categories) { category in
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

// MARK: - Storage

private struct StorageCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: NoriaSpacing.m) {
                CardHeader(title: "Storage", systemImage: "internaldrive") {
                    Button {
                        model.refreshVolume()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(Text("Refresh"))
                }
                if let volume = model.volume {
                    VStack(alignment: .leading, spacing: NoriaSpacing.xs) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(volume.name.isEmpty ? String(localized: "Startup Disk") : volume.name)
                                .font(NoriaFont.body.weight(.medium))
                            Spacer()
                            Text("\(Format.percent(volume.usedFraction)) used")
                                .font(NoriaFont.caption)
                                .foregroundStyle(.secondary)
                        }
                        CapacityBar(fraction: volume.usedFraction)
                    }
                    Grid(alignment: .leading, horizontalSpacing: NoriaSpacing.l, verticalSpacing: NoriaSpacing.s) {
                        GridRow {
                            MetricView(title: "Capacity", value: Format.bytes(volume.totalCapacity))
                            MetricView(title: "Used", value: Format.bytes(volume.usedCapacity))
                        }
                        GridRow {
                            MetricView(title: "Available", value: Format.bytes(volume.availableForImportantUsage),
                                       caption: volume.purgeableCapacity > 0
                                           ? String(localized: "includes \(Format.bytes(volume.purgeableCapacity)) purgeable")
                                           : nil)
                            MetricView(title: "Recoverable",
                                       value: model.smartScan.report.map { Format.bytes($0.recoverableSize) } ?? "—",
                                       caption: model.smartScan.report == nil ? String(localized: "Run an analysis to calculate") : nil)
                        }
                    }
                } else if let error = model.volumeError {
                    Text(error).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Device

private struct DeviceCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let device = model.device
        Card {
            VStack(alignment: .leading, spacing: NoriaSpacing.m) {
                CardHeader(title: "This Mac", systemImage: "desktopcomputer")
                Grid(alignment: .leading, horizontalSpacing: NoriaSpacing.m, verticalSpacing: NoriaSpacing.xs) {
                    row("Model", device.modelIdentifier ?? "—")
                    row("Processor", device.processor ?? device.architecture)
                    row("Cores", Format.count(device.processorCount))
                    row("Memory", Format.memory(device.physicalMemory))
                    row("macOS", device.osVersion)
                }
                Text("Live CPU, memory pressure, swap and battery health arrive with Performance and Mac Health (phase 3).")
                    .font(NoriaFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(title).font(NoriaFont.body).foregroundStyle(.secondary)
            Text(value).font(NoriaFont.body).textSelection(.enabled)
        }
    }
}

// MARK: - Recommendations

private struct RecommendationsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: NoriaSpacing.m) {
                CardHeader(title: "Recommendations", systemImage: "lightbulb")
                ForEach(model.smartScan.recommendations.prefix(6)) { recommendation in
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
                    if recommendation.id != model.smartScan.recommendations.prefix(6).last?.id {
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
