import NoriaCore
import SwiftUI

struct SmartCleanView: View {
    enum RiskFilter: Hashable, CaseIterable, Identifiable {
        case all, safe, review, protected
        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .all: return "All"
            case .safe: return "Safe"
            case .review: return "Review"
            case .protected: return "Protected"
            }
        }

        func includes(_ risk: RiskLevel) -> Bool {
            switch self {
            case .all: return true
            case .safe: return risk == .safe
            case .review: return risk == .review
            case .protected: return risk == .protected
            }
        }
    }

    @Environment(AppModel.self) private var model
    @State private var filter: RiskFilter = .all
    @State private var focusedID: ScanItem.ID?
    @State private var showInspector = true
    @State private var confirming = false
    @State private var showingCleanup = false

    private var scan: SmartScanModel { model.smartScan }

    var body: some View {
        Group {
            if scan.report == nil {
                emptyState
            } else {
                content
            }
        }
        .navigationTitle(Text("Smart Clean"))
        .sheet(isPresented: $confirming) {
            CleanupConfirmationView(items: scan.selectedItems, method: model.settings.removalMethod) {
                confirming = false
                scan.cleanSelection()
                showingCleanup = true
            } onCancel: {
                confirming = false
            }
        }
        .sheet(isPresented: $showingCleanup) {
            CleanupProgressView(controller: scan.cleanup) { showingCleanup = false }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: NoriaSpacing.l) {
            SawProgressView(isActive: scan.isScanning, progress: scan.categoryProgress, lineWidth: 6)
                .frame(width: 150, height: 150)
            if scan.isScanning {
                Text("Analyzing your Mac…").font(NoriaFont.title)
                Text("\(Format.count(scan.filesVisited)) files examined").foregroundStyle(.secondary)
                Button("Cancel") { scan.cancel() }.buttonStyle(SecondaryButtonStyle())
            } else {
                Text("No analysis yet").font(NoriaFont.title)
                Text("Run Smart Scan to find files you can safely review and remove.")
                    .foregroundStyle(.secondary)
                Button {
                    scan.start()
                } label: {
                    Label("Analyze My Mac", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        VStack(spacing: 0) {
            List(selection: $focusedID) {
                ForEach(CleanCategory.smartScanCategories) { category in
                    let items = scan.items(in: category).filter { filter.includes($0.risk) }
                    if let result = scan.results[category], !(items.isEmpty && result.inaccessibleCount == 0) {
                        Section {
                            ForEach(items) { item in
                                ScanItemRow(item: item, appName: scan.associatedApp(for: item),
                                            isSelected: scan.selectedIDs.contains(item.id)) {
                                    scan.toggle(item)
                                }
                                .tag(item.id)
                                .contextMenu { itemMenu(item) }
                            }
                            if result.inaccessibleCount > 0 {
                                InaccessibleNotice(count: result.inaccessibleCount, category: category)
                            }
                        } header: {
                            CategoryHeader(category: category, items: items)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .inspector(isPresented: $showInspector) {
                ItemInspector(item: scan.allItems.first { $0.id == focusedID })
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
            }
            Divider()
            bottomBar
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("Filter", selection: $filter) {
                    ForEach(RiskFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help(Text("Filter by risk"))
                Button {
                    scan.start()
                } label: {
                    Label("Analyze Again", systemImage: "arrow.clockwise")
                }
                .disabled(scan.isScanning || scan.cleanup.isRunning)
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Details", systemImage: "sidebar.right")
                }
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: NoriaSpacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Format.count(scan.selectedIDs.count)) items selected")
                    .font(NoriaFont.body.weight(.medium))
                Text(model.settings.removalMethod == .moveToTrash
                     ? String(localized: "Selected items will be moved to the Trash. Space is freed when the Trash is emptied.")
                     : String(localized: "Selected items will be deleted immediately."))
                    .font(NoriaFont.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Select Safe Items") { scan.selectAllSafe() }
                .buttonStyle(SecondaryButtonStyle())
            Button("Deselect All") { scan.selectedIDs = [] }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(scan.selectedIDs.isEmpty)
            Button {
                confirming = true
            } label: {
                Text("Clean \(Format.bytes(scan.selectedSize))…")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(scan.selectedIDs.isEmpty || scan.cleanup.isRunning || scan.isScanning)
        }
        .padding(.horizontal, NoriaSpacing.l)
        .padding(.vertical, NoriaSpacing.s)
        .background(.bar)
    }

    @ViewBuilder
    private func itemMenu(_ item: ScanItem) -> some View {
        Button("Reveal in Finder") { SystemActions.revealInFinder([item.path]) }
        Button("Copy Path") { SystemActions.copyToPasteboard(item.path) }
        Divider()
        Button("Always Exclude This Item") {
            model.addExclusion(item.path)
            scan.selectedIDs.remove(item.id)
        }
    }
}

private struct CategoryHeader: View {
    var category: CleanCategory
    var items: [ScanItem]
    @Environment(AppModel.self) private var model

    var body: some View {
        let scan = model.smartScan
        let selectable = items.filter(\.isSelectable)
        let selectedCount = selectable.filter { scan.selectedIDs.contains($0.id) }.count
        HStack(spacing: NoriaSpacing.s) {
            CategoryIcon(category: category, size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(category.title).font(NoriaFont.sectionTitle).foregroundStyle(.primary)
                Text(category.summary).font(NoriaFont.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Format.bytes(items.reduce(0) { $0 + $1.allocatedSize }))
                .font(NoriaFont.body.monospacedDigit())
                .foregroundStyle(.secondary)
            if !selectable.isEmpty {
                Button(selectedCount == selectable.count ? LocalizedStringKey("Deselect") : LocalizedStringKey("Select All")) {
                    scan.setSelection(selectable, selected: selectedCount != selectable.count)
                }
                .buttonStyle(.link)
                .font(NoriaFont.caption)
            }
            if category == .trash {
                Button("Open Trash") { SystemActions.openTrash() }
                    .buttonStyle(.link)
                    .font(NoriaFont.caption)
            }
        }
        .padding(.vertical, NoriaSpacing.xxs)
    }
}

private struct ScanItemRow: View {
    var item: ScanItem
    var appName: String?
    var isSelected: Bool
    var onToggle: () -> Void

    var body: some View {
        HStack(spacing: NoriaSpacing.s) {
            Toggle(isOn: Binding(get: { isSelected }, set: { _ in onToggle() })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!item.isSelectable)
            .accessibilityLabel(Text("Select \(item.name)"))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: NoriaSpacing.xs) {
                    Text(item.name).font(NoriaFont.body.weight(.medium)).lineLimit(1)
                    if let appName {
                        Text(appName).font(NoriaFont.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Text(item.path)
                    .font(NoriaFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: NoriaSpacing.s)
            Text(Format.date(item.modificationDate))
                .font(NoriaFont.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            RiskBadge(risk: item.risk)
                .frame(width: 84, alignment: .center)
            Text(Format.bytes(item.allocatedSize))
                .font(NoriaFont.body.monospacedDigit())
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .opacity(item.isSelectable ? 1 : 0.6)
    }
}

private struct InaccessibleNotice: View {
    var count: Int
    var category: CleanCategory

    var body: some View {
        HStack(spacing: NoriaSpacing.s) {
            Image(systemName: "lock")
                .foregroundStyle(.secondary)
            Text("\(Format.count(count)) locations could not be read. macOS protects them unless you grant access.")
                .font(NoriaFont.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Privacy Settings…") { SystemActions.openFullDiskAccessSettings() }
                .buttonStyle(.link)
                .font(NoriaFont.caption)
        }
    }
}

/// Details for the focused item: what it is and why Noria lists it.
struct ItemInspector: View {
    var item: ScanItem?
    @Environment(AppModel.self) private var model

    var body: some View {
        if let item {
            ScrollView {
                VStack(alignment: .leading, spacing: NoriaSpacing.m) {
                    HStack {
                        CategoryIcon(category: item.category, size: 32)
                        Text(item.name).font(NoriaFont.sectionTitle).lineLimit(2)
                    }
                    RiskBadge(risk: item.risk)
                    Text(item.risk.explanation).font(NoriaFont.caption).foregroundStyle(.secondary)
                    Divider()
                    Text("Why it is listed").font(NoriaFont.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(item.reason.explanation).font(NoriaFont.body).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    detail("Size", Format.bytes(item.allocatedSize))
                    detail("Files", Format.count(item.fileCount))
                    detail("Modified", Format.date(item.modificationDate))
                    detail("Category", item.category.title)
                    if let app = model.smartScan.associatedApp(for: item) ?? item.bundleIdentifier {
                        detail("Application", app)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Location").font(NoriaFont.caption).foregroundStyle(.secondary)
                        Text(item.path).font(NoriaFont.caption).textSelection(.enabled)
                    }
                    Button("Reveal in Finder") { SystemActions.revealInFinder([item.path]) }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .padding(NoriaSpacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Select an item to see why Noria lists it.")
                .font(NoriaFont.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detail(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(NoriaFont.body)
    }
}
