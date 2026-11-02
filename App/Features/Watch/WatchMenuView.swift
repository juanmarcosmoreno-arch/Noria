import AppKit
import NoriaCore
import SwiftUI

/// Content of the Noria Watch menu bar extra.
struct WatchMenuView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let watch = model.watch
        VStack(alignment: .leading, spacing: NoriaSpacing.m) {
            NoriaLogo(size: 24)
            VStack(alignment: .leading, spacing: NoriaSpacing.xs) {
                HStack {
                    Label("Free space", systemImage: "internaldrive")
                    Spacer()
                    Text(watch.availableBytes.map { Format.bytes($0) } ?? "—").monospacedDigit()
                }
                if let available = watch.availableBytes, let total = watch.totalBytes, total > 0 {
                    CapacityBar(fraction: 1 - Double(available) / Double(total), height: 6)
                }
                HStack {
                    Label("CPU", systemImage: "cpu")
                    Spacer()
                    Text(watch.cpuUsage.map { Format.percent($0) } ?? "—").monospacedDigit()
                }
                HStack {
                    Label("Memory pressure", systemImage: "memorychip")
                    Spacer()
                    Text(watch.memoryPressure?.title ?? "—")
                }
            }
            .font(NoriaFont.body)
            Divider()
            Button {
                show(.smartClean)
                model.smartScan.start()
            } label: {
                Label("Analyze My Mac", systemImage: "sparkle.magnifyingglass")
            }
            Button {
                show(.largeFiles)
            } label: {
                Label("Large Files", systemImage: "doc.on.doc")
            }
            Button {
                show(.dashboard)
            } label: {
                Label("Open Noria", systemImage: "macwindow")
            }
            Divider()
            HStack {
                SettingsLink {
                    Label("Settings…", systemImage: "gearshape")
                }
                Spacer()
                Button("Quit Noria") { NSApp.terminate(nil) }
            }
        }
        .buttonStyle(.borderless)
        .padding(NoriaSpacing.m)
        .frame(width: 280)
        .onAppear { watch.refreshNow() }
    }

    private func show(_ item: SidebarItem) {
        model.selection = item
        openWindow(id: NoriaApp.mainWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}
