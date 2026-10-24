import AppKit
import NoriaCore
import SwiftUI

/// What starts with the Mac or at login, as far as macOS lets apps read it.
struct StartupView: View {
    @Environment(AppModel.self) private var model
    @State private var items: [StartupItem] = []
    @State private var loaded = false
    @State private var confirming: ScanItem?
    @State private var showingCleanup = false
    @State private var cleanup = CleanupController()

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: NoriaSpacing.s) {
                    Text("macOS only lets each app turn its own login items on or off. Noria shows the background jobs it can read and points out the ones left behind by apps you removed. To turn items off, use Login Items in System Settings.")
                        .font(NoriaFont.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Login Items Settings…") { Self.openLoginItemsSettings() }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .padding(.vertical, NoriaSpacing.xs)
            }
            section("Left behind by removed apps", items.filter { $0.programMissing })
            section("For your account", items.filter { !$0.programMissing && $0.scope == .user })
            section("For all users", items.filter { !$0.programMissing && $0.scope == .allUsersAgent })
            section("System services", items.filter { !$0.programMissing && $0.scope == .systemDaemon })
        }
        .listStyle(.inset)
        .overlay {
            if loaded && items.isEmpty {
                EmptyStateView(title: "No background items found",
                               message: "Noria found no login agents or services it can read.",
                               systemImage: "power")
            }
        }
        .navigationTitle(Text("Startup Manager"))
        .toolbar {
            ToolbarItem {
                Button {
                    reload()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .task { reload() }
        .sheet(item: $confirming) { item in
            CleanupConfirmationView(items: [item], method: model.settings.removalMethod) {
                confirming = nil
                cleanup.run(items: [item], app: model) { _ in reload() }
                showingCleanup = true
            } onCancel: {
                confirming = nil
            }
        }
        .sheet(isPresented: $showingCleanup) {
            CleanupProgressView(controller: cleanup) { showingCleanup = false }
        }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ items: [StartupItem]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    StartupRow(item: item) {
                        if model.folderAccess.ensureReadable(item.plistPath), let removal = StartupItemsScanner.removalItem(for: item) {
                            confirming = removal
                        }
                    }
                }
            }
        }
    }

    private func reload() {
        let locations = model.locations
        Task {
            items = await Task.detached(priority: .userInitiated) {
                StartupItemsScanner.scan(locations: locations).filter { !$0.isAppleItem }
            }.value
            loaded = true
        }
    }

    static func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct StartupRow: View {
    var item: StartupItem
    var onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: NoriaSpacing.s) {
            Group {
                if let appPath = item.appPath, FileSystem.stat(appPath) != nil {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: appPath)).resizable()
                } else {
                    Image(systemName: item.programMissing ? "exclamationmark.triangle" : "gearshape")
                        .foregroundStyle(item.programMissing ? NoriaColor.review : .secondary)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(appName ?? item.label).font(NoriaFont.body.weight(.medium))
                if appName != nil {
                    Text(item.label).font(NoriaFont.caption.monospaced()).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if item.runsAtLoad { badge("Starts automatically") }
                    if item.keepsAlive { badge("Restarts if it quits") }
                    if item.isOnDemand { badge("Runs when needed") }
                    if item.isDisabled { badge("Disabled") }
                }
                if item.programMissing {
                    Text("Its program no longer exists, so it does nothing but fail at every login. It is safe to remove.")
                        .font(NoriaFont.caption)
                        .foregroundStyle(NoriaColor.review)
                } else if let program = item.program {
                    Text((program as NSString).abbreviatingWithTildeInPath)
                        .font(NoriaFont.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(impactTitle).font(NoriaFont.caption).foregroundStyle(.secondary)
                HStack {
                    Button {
                        SystemActions.revealInFinder([item.plistPath])
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help(Text("Reveal in Finder"))
                    if item.scope == .user {
                        Button("Remove…", action: onRemove)
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var appName: String? {
        item.appPath.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
    }

    private var impactTitle: String {
        switch item.estimatedImpact {
        case .high: return String(localized: "Always running")
        case .medium: return String(localized: "Runs at login")
        case .low: return String(localized: "Occasional")
        }
    }

    private func badge(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(NoriaColor.subtleFill, in: Capsule())
    }
}
