import AppKit
import NoriaCore
import SwiftUI

struct SpaceMapView: View {
    @Environment(AppModel.self) private var model
    @State private var confirming: ScanItem?
    @State private var showingCleanup = false

    private var map: SpaceMapModel { model.spaceMap }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .navigationTitle(Text("Space Map"))
        .sheet(item: $confirming) { item in
            CleanupConfirmationView(items: [item], method: model.settings.removalMethod) {
                confirming = nil
                map.remove(item)
                showingCleanup = true
            } onCancel: {
                confirming = nil
            }
        }
        .sheet(isPresented: $showingCleanup) {
            CleanupProgressView(controller: map.cleanup) { showingCleanup = false }
        }
    }

    private var controls: some View {
        HStack(spacing: NoriaSpacing.m) {
            Button {
                map.chooseRoot()
            } label: {
                Label((map.rootPath as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .disabled(map.isScanning)
            Spacer()
            if map.isScanning {
                ProgressView().controlSize(.small)
                Text("\(Format.count(map.filesVisited)) files · \(Format.bytes(map.bytesVisited))")
                    .font(NoriaFont.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Cancel") { map.cancel() }
                    .buttonStyle(SecondaryButtonStyle())
            } else {
                Button {
                    map.start()
                } label: {
                    Label(map.report == nil ? LocalizedStringKey("Map This Folder") : LocalizedStringKey("Scan Again"),
                          systemImage: "square.grid.3x3.square")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(.horizontal, NoriaSpacing.l)
        .padding(.vertical, NoriaSpacing.s)
    }

    @ViewBuilder
    private var content: some View {
        if let current = map.currentNode {
            VStack(spacing: 0) {
                Breadcrumbs()
                HStack(spacing: 0) {
                    TreemapView(node: current, selectedID: map.selectedNodeID) { node in
                        map.selectedNodeID = node.id
                    } onOpen: { node in
                        map.open(node)
                    }
                    .padding(NoriaSpacing.s)
                    Divider()
                    SpaceSidebar(node: current) { item in confirming = item }
                        .frame(width: 300)
                }
            }
        } else if map.isScanning {
            VStack(spacing: NoriaSpacing.m) {
                SawView(isSpinning: true).frame(width: 110, height: 110)
                Text("Measuring folders…").font(NoriaFont.sectionTitle)
                Text((map.currentFolder as NSString).abbreviatingWithTildeInPath)
                    .font(NoriaFont.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 500)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if case .failed(let message) = map.phase {
            EmptyStateView(title: "The scan could not finish", message: "\(message)", systemImage: "exclamationmark.triangle")
        } else {
            EmptyStateView(title: "See what fills your disk",
                           message: "Noria measures every folder and draws a map where each block is proportional to its size. Click to select, double-click to go inside. Nothing is changed while scanning.",
                           systemImage: "square.grid.3x3.square")
        }
    }
}

private struct Breadcrumbs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let map = model.spaceMap
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button {
                    map.goUp()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(map.breadcrumbs.count <= 1)
                .help(Text("Enclosing folder"))
                ForEach(Array(map.breadcrumbs.enumerated()), id: \.element.id) { index, node in
                    if index > 0 {
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    Button {
                        map.currentPath = node.path
                        map.selectedNodeID = nil
                    } label: {
                        Text(index == 0 ? (node.path as NSString).abbreviatingWithTildeInPath : node.name)
                            .fontWeight(index == map.breadcrumbs.count - 1 ? .semibold : .regular)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, NoriaSpacing.l)
            .padding(.vertical, NoriaSpacing.xs)
        }
    }
}

/// One drawn block of the treemap.
private struct Tile {
    var node: SpaceNode
    var rect: CGRect
    var level: Int
}

/// Treemap of a folder: its children, and inside each folder block, that folder's
/// own children (one level), so the structure is visible at a glance.
private struct TreemapView: View {
    var node: SpaceNode
    var selectedID: SpaceNode.ID?
    var onSelect: (SpaceNode) -> Void
    var onOpen: (SpaceNode) -> Void

    @State private var hovered: SpaceNode?

    var body: some View {
        GeometryReader { proxy in
            let tiles = Self.tiles(for: node, in: CGRect(origin: .zero, size: proxy.size))
            Canvas { context, _ in
                for tile in tiles {
                    let rect = tile.rect.insetBy(dx: tile.level == 0 ? 1.5 : 1, dy: tile.level == 0 ? 1.5 : 1)
                    guard rect.width > 1, rect.height > 1 else { continue }
                    let path = Path(roundedRect: rect, cornerRadius: tile.level == 0 ? 6 : 3)
                    context.fill(path, with: .color(Self.color(for: tile.node, level: tile.level)))
                    if tile.node.id == selectedID {
                        context.stroke(path, with: .color(.primary), lineWidth: 2.5)
                    } else if tile.node.id == hovered?.id {
                        context.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
                    }
                    if tile.level == 0, rect.width > 70, rect.height > 30 {
                        let caption = Self.title(of: tile.node) + "  " + Format.bytes(tile.node.size)
                        let label = Text(verbatim: caption)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                        context.draw(label, in: CGRect(x: rect.minX + 6, y: rect.minY + 4, width: rect.width - 12, height: 16))
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location): hovered = Self.hit(tiles, at: location)?.node
                case .ended: hovered = nil
                }
            }
            .onTapGesture(count: 2, coordinateSpace: .local) { location in
                if let tile = Self.hit(tiles, at: location, preferTopLevel: true) { onOpen(tile.node) }
            }
            .onTapGesture(count: 1, coordinateSpace: .local) { location in
                if let tile = Self.hit(tiles, at: location) { onSelect(tile.node) }
            }
            .overlay(alignment: .bottomLeading) {
                if let hovered {
                    Text(verbatim: Self.title(of: hovered) + " · " + Format.bytes(hovered.size))
                        .font(NoriaFont.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Space map of \(node.name)"))
    }

    static func tiles(for node: SpaceNode, in bounds: CGRect) -> [Tile] {
        var tiles: [Tile] = []
        let children = node.children.filter { $0.size > 0 }
        let rects = Treemap.layout(values: children.map { Double($0.size) },
                                   in: Treemap.Rect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height))
        for (child, rect) in zip(children, rects) {
            let frame = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
            tiles.append(Tile(node: child, rect: frame, level: 0))
            // Nested level, leaving room for the label.
            if child.isContainer, !child.children.isEmpty, frame.width > 40, frame.height > 40 {
                let inner = frame.insetBy(dx: 4, dy: 4).offsetBy(dx: 0, dy: 10).insetBy(dx: 0, dy: 5)
                let grandChildren = child.children.filter { $0.size > 0 }
                let innerRects = Treemap.layout(values: grandChildren.map { Double($0.size) },
                                                in: Treemap.Rect(x: inner.minX, y: inner.minY, width: inner.width, height: inner.height))
                for (grandChild, innerRect) in zip(grandChildren, innerRects) {
                    tiles.append(Tile(node: grandChild, rect: CGRect(x: innerRect.x, y: innerRect.y, width: innerRect.width, height: innerRect.height), level: 1))
                }
            }
        }
        return tiles
    }

    static func title(of node: SpaceNode) -> String {
        node.kind == .smallItems ? String(localized: "Small items") : node.name
    }

    static func hit(_ tiles: [Tile], at point: CGPoint, preferTopLevel: Bool = false) -> Tile? {
        let matches = tiles.filter { $0.rect.contains(point) }
        return preferTopLevel ? matches.first { $0.level == 0 } : (matches.last ?? matches.first)
    }

    static func color(for node: SpaceNode, level: Int) -> Color {
        switch node.kind {
        case .directory:
            return level == 0 ? NoriaColor.woodDark.opacity(0.85) : NoriaColor.wood.opacity(0.75)
        case .package, .file:
            return node.fileKind.mapColor.opacity(level == 0 ? 1 : 0.85)
        case .smallItems:
            return NoriaColor.steelMid.opacity(level == 0 ? 0.55 : 0.4)
        }
    }
}

/// Contents of the current folder as a list, and details/actions for the selection.
private struct SpaceSidebar: View {
    var node: SpaceNode
    var onRemove: (ScanItem) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let map = model.spaceMap
        VStack(spacing: 0) {
            if let selected = map.selectedNode {
                SelectionDetails(node: selected, onRemove: onRemove)
                Divider()
            }
            List(node.children, selection: Binding(get: { map.selectedNodeID }, set: { map.selectedNodeID = $0 })) { child in
                HStack(spacing: NoriaSpacing.s) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(TreemapView.color(for: child, level: 0))
                        .frame(width: 12, height: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(child.kind == .smallItems ? String(localized: "Small items (\(Format.count(child.groupedCount)))") : child.name)
                            .lineLimit(1)
                        CapacityBar(fraction: node.size > 0 ? Double(child.size) / Double(node.size) : 0, height: 4)
                    }
                    Text(Format.bytes(child.size)).font(NoriaFont.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .tag(child.id)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { map.open(child) }
            }
            .listStyle(.inset)
        }
    }
}

private struct SelectionDetails: View {
    var node: SpaceNode
    var onRemove: (ScanItem) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let map = model.spaceMap
        let item = map.scanItem(for: node)
        VStack(alignment: .leading, spacing: NoriaSpacing.xs) {
            Text(verbatim: TreemapView.title(of: node))
                .font(NoriaFont.sectionTitle)
                .lineLimit(2)
            Text("\(Format.bytes(node.size)) · \(Format.count(node.fileCount)) files")
                .font(NoriaFont.caption).foregroundStyle(.secondary)
            if node.kind == .smallItems {
                Text("\(Format.count(node.groupedCount)) small files and folders grouped together. Open the folder in Finder to see them.")
                    .font(NoriaFont.caption).foregroundStyle(.secondary)
            } else if let item, !item.isSelectable {
                Label("Managed by macOS or another app; Noria does not remove it.", systemImage: "lock")
                    .font(NoriaFont.caption).foregroundStyle(.secondary)
            }
            HStack {
                if node.isContainer, !node.children.isEmpty {
                    Button("Open") { map.open(node) }
                }
                Button("Reveal in Finder") { SystemActions.revealInFinder([node.path]) }
                if let item, item.isSelectable {
                    Button(model.settings.removalMethod.actionTitle) { onRemove(item) }
                }
            }
            .buttonStyle(.borderless)
            .font(NoriaFont.caption)
        }
        .padding(NoriaSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
