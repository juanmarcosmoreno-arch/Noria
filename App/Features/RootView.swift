import NoriaCore
import SwiftUI

/// Sidebar destinations, in product order.
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case dashboard, smartClean, spaceMap, largeFiles, duplicates, appRemover, mail, startupManager
    case performance, privacy, developerClean, macHealth, history, settings

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .dashboard: return "Dashboard"
        case .smartClean: return "Smart Clean"
        case .spaceMap: return "Space Map"
        case .largeFiles: return "Large Files"
        case .duplicates: return "Duplicates"
        case .appRemover: return "App Remover"
        case .mail: return "Mail"
        case .startupManager: return "Startup Manager"
        case .performance: return "Performance"
        case .privacy: return "Privacy"
        case .developerClean: return "Developer Clean"
        case .macHealth: return "Mac Health"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.33percent"
        case .smartClean: return "sparkles"
        case .spaceMap: return "square.grid.3x3.square"
        case .largeFiles: return "doc.on.doc"
        case .duplicates: return "square.on.square"
        case .appRemover: return "xmark.app"
        case .mail: return "envelope"
        case .startupManager: return "power"
        case .performance: return "speedometer"
        case .privacy: return "hand.raised"
        case .developerClean: return "hammer"
        case .macHealth: return "heart.text.square"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }

    /// Modules that are implemented; the others show a "planned" screen.
    var isAvailable: Bool {
        switch self {
        case .dashboard, .smartClean, .spaceMap, .largeFiles, .duplicates, .appRemover, .mail,
             .startupManager, .performance, .macHealth, .history, .settings: return true
        default: return false
        }
    }

    /// Development phase in which the module ships.
    var phase: Int {
        switch self {
        case .dashboard, .smartClean, .largeFiles, .history, .settings: return 1
        case .appRemover, .mail: return 2
        case .spaceMap, .duplicates: return 2
        case .performance, .startupManager, .macHealth, .privacy: return 3
        case .developerClean: return 4
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(SidebarItem.allCases) { item in
                    Label(item.title, systemImage: item.systemImage)
                        .badge(item == .smartClean && model.smartScan.phase == .finished ? Text(Format.bytes(model.smartScan.selectedSize)) : nil)
                        .opacity(item.isAvailable ? 1 : 0.55)
                        .tag(item)
                }
            }
            .safeAreaInset(edge: .top) {
                NoriaLogo()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, NoriaSpacing.m)
                    .padding(.vertical, NoriaSpacing.s)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            detail(for: model.selection ?? .dashboard)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NoriaColor.canvasBackground)
        }
    }

    @ViewBuilder
    private func detail(for item: SidebarItem) -> some View {
        switch item {
        case .dashboard: DashboardView()
        case .smartClean: SmartCleanView()
        case .largeFiles: LargeFilesView()
        case .appRemover: AppRemoverView()
        case .spaceMap: SpaceMapView()
        case .performance: PerformanceView()
        case .startupManager: StartupView()
        case .macHealth: MacHealthView()
        case .duplicates: DuplicatesView()
        case .mail: MailView()
        case .history: HistoryView()
        case .settings: SettingsView()
        default: PlannedFeatureView(item: item)
        }
    }
}

/// Honest placeholder for modules scheduled in later phases. No fake data.
struct PlannedFeatureView: View {
    var item: SidebarItem
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: NoriaSpacing.l) {
            Image(systemName: item.systemImage)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(NoriaColor.accent)
            Text(item.title).font(NoriaFont.title)
            Text("Planned for phase \(item.phase). This module is not available yet.")
                .foregroundStyle(.secondary)
            if item == .developerClean {
                Text("Xcode DerivedData, archives, device support and npm, pip, Homebrew, Yarn, CocoaPods and Go caches are already analyzed by Smart Clean.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460)
                Button("Open Smart Clean") { model.selection = .smartClean }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(NoriaSpacing.xxl)
    }
}
