import NoriaCore
import SwiftUI

@main
struct NoriaApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
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
    }
}
