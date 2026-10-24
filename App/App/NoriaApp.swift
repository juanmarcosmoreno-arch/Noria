import NoriaCore
import SwiftUI

@main
struct NoriaApp: App {
    static let mainWindowID = "main"
    @State private var model = AppModel()

    var body: some Scene {
        // A single main window: reopening it from the menu bar brings it to the front.
        Window(Text(verbatim: "Noria"), id: Self.mainWindowID) {
            RootView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { ScanCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 620, height: 560)
        }

        // Noria Watch (optional, off by default).
        MenuBarExtra(isInserted: Binding(get: { model.settings.showsMenuBarExtra },
                                         set: { model.settings.showsMenuBarExtra = $0 })) {
            WatchMenuView()
                .environment(model)
        } label: {
            Image(systemName: "gauge.with.dots.needle.33percent")
        }
        .menuBarExtraStyle(.window)
    }
}

/// The Scan menu. Kept in its own types: building these buttons inline in the
/// scene's `.commands` closure made the Swift runtime recurse while resolving
/// their opaque types and crash at launch on some macOS versions.
struct ScanCommands: Commands {
    var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandMenu(Text("Scan")) {
            ScanMenuItems(model: model)
        }
    }
}

private struct ScanMenuItems: View {
    var model: AppModel

    var body: some View {
        Button("Analyze My Mac") {
            model.selection = .dashboard
            model.smartScan.start()
        }
        .keyboardShortcut("r", modifiers: [.command])
        .disabled(model.smartScan.isScanning)

        Button("Stop Scan") { model.smartScan.cancel() }
            .keyboardShortcut(".", modifiers: [.command])
            .disabled(!model.smartScan.isScanning)
    }
}
