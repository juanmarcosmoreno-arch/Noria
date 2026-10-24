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
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu(Text("Scan")) {
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
