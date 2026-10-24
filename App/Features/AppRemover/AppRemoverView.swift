import AppKit
import NoriaCore
import SwiftUI

struct AppRemoverView: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false
    @State private var showingCleanup = false

    private var remover: AppRemoverModel { model.appRemover }

    var body: some View {
        @Bindable var remover = remover
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TextField("Search apps", text: $remover.searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(NoriaSpacing.s)
                List(remover.visibleApps, selection: $remover.selectedAppID) { installed in
                    AppRow(installed: installed, size: remover.sizes[installed.path])
                        .tag(installed.id)
                }
                .listStyle(.inset)
                .overlay {
                    if remover.isLoadingApps && remover.apps.isEmpty {
                        ProgressView()
                    }
                }
            }
            .frame(width: 320)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(Text("App Remover"))
        .toolbar {
            ToolbarItem {
                Button {
                    remover.loadApps()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .onAppear { if remover.apps.isEmpty { remover.loadApps() } }
        .sheet(isPresented: $confirming) {
            CleanupConfirmationView(items: remover.selectedItems, method: model.settings.removalMethod) {
                confirming = false
                remover.removeSelection()
                showingCleanup = true
            } onCancel: {
                confirming = false
            }
        }
        .sheet(isPresented: $showingCleanup) {
            CleanupProgressView(controller: remover.cleanup) { showingCleanup = false }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let installed = remover.selectedApp {
            VStack(spacing: 0) {
                AppHeader(installed: installed, size: remover.sizes[installed.path])
                Divider()
                if remover.isLoadingFiles {
                    ProgressView("Looking for files created by this app…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    RelatedFilesList()
                }
                Divider()
                bottomBar
            }
        } else {
            EmptyStateView(title: "Remove apps completely",
                           message: "Select an app to see everything it installed: support files, caches, preferences and more. You choose what to remove; files shared with other apps are never preselected.",
                           systemImage: "xmark.app")
        }
    }

    private var bottomBar: some View {
        HStack(spacing: NoriaSpacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("\(remover.selectedItemIDs.count) items selected")
                    Text(verbatim: "· " + Format.bytes(remover.selectedSize))
                }
                .font(NoriaFont.body.weight(.medium))
                Text(remover.includesAppBundle
                     ? String(localized: "The app and the selected files will be removed.")
                     : String(localized: "The app stays installed; only the selected files are removed (useful to reset it)."))
                    .font(NoriaFont.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                if remover.ensureAccess() { confirming = true }
            } label: {
                Text(remover.includesAppBundle ? LocalizedStringKey("Remove App…") : LocalizedStringKey("Remove Selected Files…"))
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(remover.selectedItemIDs.isEmpty || remover.cleanup.isRunning)
        }
        .padding(.horizontal, NoriaSpacing.l)
        .padding(.vertical, NoriaSpacing.s)
        .background(.bar)
    }
}

private struct AppRow: View {
    var installed: InstalledApp
    var size: Int64?

    var body: some View {
        HStack(spacing: NoriaSpacing.s) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: installed.path))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(installed.name).font(NoriaFont.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 4) {
                    if let version = installed.version {
                        Text(version)
                    }
                    if installed.isFromAppStore {
                        Text("App Store")
                    }
                }
                .font(NoriaFont.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let size {
                Text(Format.bytes(size)).font(NoriaFont.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct AppHeader: View {
    var installed: InstalledApp
    var size: Int64?
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: NoriaSpacing.m) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: installed.path))
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: NoriaSpacing.xxs) {
                Text(installed.name).font(NoriaFont.title)
                HStack(spacing: NoriaSpacing.s) {
                    if let version = installed.version { Text("Version \(version)") }
                    if let size { Text(Format.bytes(size)) }
                    if installed.isFromAppStore { Text("App Store") }
                }
                .font(NoriaFont.caption)
                .foregroundStyle(.secondary)
                Text(installed.bundleIdentifier ?? installed.path)
                    .font(NoriaFont.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if model.appRemover.isRunning(installed) {
                    HStack {
                        Label("This app is open. Quit it before removing it or its files.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(NoriaColor.review)
                        Button("Quit App") {
                            if let identifier = installed.bundleIdentifier {
                                NSRunningApplication.runningApplications(withBundleIdentifier: identifier).forEach { $0.terminate() }
                            }
                        }
                    }
                    .font(NoriaFont.caption)
                }
            }
            Spacer()
            Button("Reveal in Finder") { SystemActions.revealInFinder([installed.path]) }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(NoriaSpacing.l)
    }
}

/// The app's files grouped by kind, each with why it is listed and what happens if removed.
private struct RelatedFilesList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let remover = model.appRemover
        List {
            ForEach(sections(remover.relatedItems), id: \.title) { section in
                Section {
                    ForEach(section.items) { item in
                        RelatedFileRow(item: item, isSelected: remover.selectedItemIDs.contains(item.id)) {
                            remover.toggle(item)
                        }
                        .contextMenu {
                            Button("Reveal in Finder") { SystemActions.revealInFinder([item.path]) }
                            Button("Copy Path") { SystemActions.copyToPasteboard(item.path) }
                        }
                    }
                } header: {
                    Label(section.title, systemImage: section.systemImage)
                }
            }
        }
        .listStyle(.inset)
    }

    private struct FileSection {
        var title: String
        var systemImage: String
        var items: [ScanItem]
    }

    private func sections(_ items: [ScanItem]) -> [FileSection] {
        var result: [FileSection] = []
        let bundle = items.filter { $0.reason == .applicationBundle }
        if !bundle.isEmpty {
            result.append(FileSection(title: String(localized: "Application"), systemImage: "app", items: bundle))
        }
        for kind in AppDataKind.allCases {
            let matching = items.filter {
                if case .appData(let itemKind, _) = $0.reason { return itemKind == kind }
                return false
            }
            if !matching.isEmpty {
                result.append(FileSection(title: kind.title, systemImage: kind.systemImage, items: matching))
            }
        }
        return result
    }
}

private struct RelatedFileRow: View {
    var item: ScanItem
    var isSelected: Bool
    var onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: NoriaSpacing.s) {
            Toggle(isOn: Binding(get: { isSelected }, set: { _ in onToggle() })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!item.isSelectable)
            VStack(alignment: .leading, spacing: 2) {
                Text((item.path as NSString).lastPathComponent).font(NoriaFont.body.weight(.medium)).lineLimit(1)
                Text(item.reason.explanation)
                    .font(NoriaFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text((item.path as NSString).abbreviatingWithTildeInPath)
                    .font(NoriaFont.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: NoriaSpacing.s)
            RiskBadge(risk: item.risk)
            Text(Format.bytes(item.allocatedSize))
                .font(NoriaFont.body.monospacedDigit())
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }
}
