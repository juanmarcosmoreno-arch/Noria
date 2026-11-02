import AppKit
import NoriaCore
import SwiftUI

/// Content of the Noria Watch menu bar extra: live status and quick actions.
struct WatchMenuView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let watch = model.watch
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                NoriaLogo(size: 22)
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help(Text("Settings…"))
            }
            .padding(.horizontal, NoriaSpacing.m)
            .padding(.top, NoriaSpacing.m)
            .padding(.bottom, NoriaSpacing.s)

            VStack(alignment: .leading, spacing: NoriaSpacing.xs) {
                HStack {
                    Text("Free space").foregroundStyle(.secondary)
                    Spacer()
                    Text(watch.availableBytes.map { Format.bytes($0) } ?? "—").monospacedDigit()
                }
                if let available = watch.availableBytes, let total = watch.totalBytes, total > 0 {
                    CapacityBar(fraction: 1 - Double(available) / Double(total), height: 5)
                }
                HStack {
                    Text("CPU").foregroundStyle(.secondary)
                    Text(watch.cpuUsage.map { Format.percent($0) } ?? "—").monospacedDigit()
                    Spacer()
                    Text("Memory").foregroundStyle(.secondary)
                    Text(watch.memoryPressure?.title ?? "—")
                }
            }
            .font(NoriaFont.caption)
            .padding(.horizontal, NoriaSpacing.m)
            .padding(.bottom, NoriaSpacing.s)

            Divider()
            VStack(spacing: 2) {
                MenuRow(title: "Quick Analysis", systemImage: "magnifyingglass") {
                    show(.dashboard)
                    model.smartScan.start()
                }
                MenuRow(title: "Free Up Space", systemImage: "sparkles") { show(.smartClean) }
                MenuRow(title: "Large Files", systemImage: "doc.on.doc") { show(.largeFiles) }
                MenuRow(title: "Duplicates", systemImage: "square.on.square") { show(.duplicates) }
            }
            .padding(NoriaSpacing.xs)
            Divider()
            VStack(spacing: 2) {
                MenuRow(title: "Open Noria", systemImage: "macwindow") { show(.dashboard) }
                MenuRow(title: "Quit Noria", systemImage: "power") { NSApp.terminate(nil) }
            }
            .padding(NoriaSpacing.xs)
        }
        .frame(width: 260)
        .onAppear { watch.refreshNow() }
    }

    private func show(_ item: SidebarItem) {
        model.selection = item
        openWindow(id: NoriaApp.mainWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// A full-width menu item with a hover highlight, like the system's own menus.
private struct MenuRow: View {
    var title: LocalizedStringKey
    var systemImage: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NoriaSpacing.s) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(hovering ? Color.white : NoriaColor.accent)
                Text(title)
                Spacer()
            }
            .font(NoriaFont.body)
            .foregroundStyle(hovering ? Color.white : Color.primary)
            .padding(.horizontal, NoriaSpacing.s)
            .padding(.vertical, 6)
            .background(hovering ? NoriaColor.accent : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
