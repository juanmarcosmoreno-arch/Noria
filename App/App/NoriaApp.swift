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

        // Noria Watch (optional, off by default). The setter only writes real changes:
        // SwiftUI calls it while updating the scene, and every write to the observed
        // settings invalidates the scene again, which looped forever at launch.
        MenuBarExtra(isInserted: Binding(get: { model.settings.showsMenuBarExtra },
                                         set: { newValue in
                                             if model.settings.showsMenuBarExtra != newValue {
                                                 model.settings.showsMenuBarExtra = newValue
                                             }
                                         })) {
            WatchMenuView()
                .environment(model)
        } label: {
            Image(systemName: "gauge.with.dots.needle.33percent")
        }
        .menuBarExtraStyle(.window)
    }
}

/// The Scan menu. Kept in its own types, and it reads no observed state: the main
/// menu is rebuilt whenever what it reads changes. Both actions check the scan
/// state themselves (starting while scanning or stopping while idle does nothing).
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

        Button("Stop Scan") { model.smartScan.cancel() }
            .keyboardShortcut(".", modifiers: [.command])
    }
}
