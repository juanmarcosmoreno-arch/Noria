import NoriaCore
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoriaSpacing.l) {
                HeroCard()
                if model.smartScan.phase != .idle {
                    OverviewCard()
                }
                SystemInsightsCard()
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
                VStack(spacing: NoriaSpacing.m) {
                    WheelProgressView(isActive: scan.isScanning, progress: scan.categoryProgress,
                                      lineWidth: 7, showsRing: scan.phase != .idle)
                        .frame(width: 210, height: 210)
                    header
                    actions
                }
                .frame(width: 340)
                .multilineTextAlignment(.center)

                Group {
                    if scan.phase == .idle {
                        VStack(alignment: .leading, spacing: NoriaSpacing.m) {
                            StorageSummary()
                            HStack(spacing: NoriaSpacing.s) {
                                RecoverableTile()
                                CPUTile()
                                MemoryTile()
                            }
                        }
                    } else {
                        CategoryStatusList()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(spacing: NoriaSpacing.xxs) {
            switch scan.phase {
            case .idle:
                Text("Make space. Run better.").font(NoriaFont.title)
                Text("Analyze, clean and free up space safely.").foregroundStyle(.secondary)
            case .scanning:
                Text("Analyzing your Mac…").font(NoriaFont.title)
                Text("Looking for unnecessary files, caches and more.").foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text("\(scan.filesVisited) files examined")
                    Text(verbatim: "· " + Format.bytes(scan.bytesFound))
                }
                .font(NoriaFont.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            case .finished:
                Text("Analysis complete").font(NoriaFont.title)
                if let report = scan.report {
                    let duration = Format.duration(report.finishedAt.timeIntervalSince(report.startedAt))
                    HStack(spacing: 4) {
                        Text("\(report.allItems.count) items found")
                        Text(verbatim: "· " + duration)
                    }
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
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var actions: some View {
        switch scan.phase {
        case .scanning:
            Button("Cancel") { scan.cancel() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
        case .finished:
            VStack(spacing: NoriaSpacing.xs) {
                Button {
                    model.selection = .smartClean
                } label: {
                    Label("Review and Clean", systemImage: "checklist")
                }
                .buttonStyle(PrimaryButtonStyle(prominent: true))
                Button("Analyze Again") { scan.start() }
                    .buttonStyle(.link)
            }
        case .idle, .cancelled, .failed:
            VStack(spacing: NoriaSpacing.xs) {
                Button {
                    scan.start()
                } label: {
                    Label("Analyze My Mac", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                FolderAccessNote()
            }
        }
    }
}

/// Storage and live metrics, shown under the hero once an analysis has started.
private struct OverviewCard: View {
    var body: some View {
        Card {
            HStack(alignment: .top, spacing: NoriaSpacing.m) {
                StorageSummary()
                    .frame(maxWidth: .infinity)
                RecoverableTile()
                CPUTile()
                MemoryTile()
            }
        }
    }
}

/// Every Smart Scan category with its icon, the space found and its status.
private struct CategoryStatusList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let scan = model.smartScan
        VStack(spacing: 0) {
            ForEach(Array(scan.plannedCategories.enumerated()), id: \.element) { index, category in
                if index > 0 { Divider().padding(.leading, 48) }
                HStack(spacing: NoriaSpacing.s) {
                    CategoryIcon(category: category, size: 28)
                    Text(category.title).font(NoriaFont.body)
                    Spacer()
                    trailing(for: category, scan: scan)
                }
                .padding(.vertical, 7)
                .padding(.horizontal, NoriaSpacing.s)
                .background(scan.currentCategory == category ? NoriaColor.accent.opacity(0.08) : .clear,
                            in: RoundedRectangle(cornerRadius: NoriaRadius.small, style: .continuous))
                .accessibilityElement(children: .combine)
            }
            if scan.phase == .finished, let report = scan.report {
                Divider()
                HStack {
                    Text("Recoverable").font(NoriaFont.body.weight(.semibold))
                    Spacer()
                    Text(Format.bytes(report.recoverableSize))
                        .font(NoriaFont.body.weight(.semibold).monospacedDigit())
                        .foregroundStyle(NoriaColor.accent)
                }
                .padding(.horizontal, NoriaSpacing.s)
                .padding(.top, NoriaSpacing.s)
            }
        }
        .padding(NoriaSpacing.xs)
        .background(NoriaColor.subtleFill.opacity(0.5), in: RoundedRectangle(cornerRadius: NoriaRadius.card - 4, style: .continuous))
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
                HStack(spacing: NoriaSpacing.s) {
                    Text(Format.bytes(category == .trash ? result.totalSize : result.items.filter(\.isSelectable).reduce(0) { $0 + $1.allocatedSize }))
                        .font(NoriaFont.body.monospacedDigit())
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(NoriaColor.accent)
                }
            }
        } else if scan.currentCategory == category {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: "ellipsis").foregroundStyle(.tertiary)
        }
    }
}

/// App Store edition: explains the one-time home-folder permission and shows grant errors.
struct FolderAccessNote: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let access = model.folderAccess
        if let error = access.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(NoriaFont.caption)
                .foregroundStyle(NoriaColor.review)
        } else if access.needsGrant {
            Label("The first time, macOS asks you to allow access to your Home folder. Noria only reads it until you confirm a cleanup.",
                  systemImage: "lock.shield")
                .font(NoriaFont.caption)
                .foregroundStyle(.secondary)
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
                .foregroundStyle(NoriaColor.slate)
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

// MARK: - System insights

/// Recommendations that do not need a scan: they come from live, measured values.
private struct SystemInsightsCard: View {
    @Environment(AppModel.self) private var model

    private struct Insight: Identifiable {
        var id: String
        var icon: String
        var color: Color
        var text: String
        var action: LocalizedStringKey?
        var destination: SidebarItem?
    }

    private var insights: [Insight] {
        var result: [Insight] = []
        if let volume = model.volume, volume.usedFraction > 0.9 || volume.availableForImportantUsage < 20_000_000_000 {
            result.append(Insight(id: "disk", icon: "exclamationmark.triangle.fill", color: NoriaColor.review,
                                  text: String(localized: "Your disk is \(Format.percent(volume.usedFraction)) full. macOS needs free space for updates, virtual memory and temporary files; keep at least 10–15% free."),
                                  action: "Analyze My Mac", destination: .dashboard))
        }
        if model.quarantineSize >= 1_000_000_000 {
            result.append(Insight(id: "quarantine", icon: "archivebox", color: NoriaColor.accent,
                                  text: String(localized: "\(Format.bytes(model.quarantineSize)) are waiting in the quarantine. That space is freed when you empty it or when the retention period ends."),
                                  action: "Open Quarantine", destination: .history))
        }
        if let pressure = model.metrics.memory?.pressure, pressure != .normal {
            result.append(Insight(id: "memory", icon: "memorychip", color: NoriaColor.review,
                                  text: String(localized: "Memory pressure is \(pressure.title.lowercased()). See which apps use the most memory in Performance."),
                                  action: "Open Performance", destination: .performance))
        }
        return result
    }

    var body: some View {
        let insights = self.insights
        if !insights.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: NoriaSpacing.s) {
                    ForEach(insights) { insight in
                        HStack(alignment: .top, spacing: NoriaSpacing.s) {
                            Image(systemName: insight.icon).foregroundStyle(insight.color).frame(width: 20)
                            Text(insight.text).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            if let action = insight.action, let destination = insight.destination {
                                Button(action) {
                                    if insight.id == "disk" {
                                        model.smartScan.start()
                                    } else {
                                        model.selection = destination
                                    }
                                }
                                .buttonStyle(SecondaryButtonStyle())
                            }
                        }
                    }
                }
            }
            .task { await model.refreshQuarantine() }
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
            Button("Review") {
                if case .mailAttachments = recommendation.kind {
                    model.selection = .mail
                } else {
                    model.selection = .smartClean
                }
            }
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
