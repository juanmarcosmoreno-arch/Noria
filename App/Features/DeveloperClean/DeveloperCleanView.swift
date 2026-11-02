import AppKit
import NoriaCore
import SwiftUI

/// Developer Clean: what each developer tool stores, what happens if it is removed,
/// whether it comes back, and Noria's recommendation.
struct DeveloperCleanView: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false
    @State private var showingCleanup = false
    @State private var confirmingSimctl = false

    private var developer: DeveloperModel { model.developer }

    var body: some View {
        VStack(spacing: 0) {
            content
            if developer.report != nil {
                Divider()
                bottomBar
            }
        }
        .navigationTitle(Text("Developer Clean"))
        .toolbar {
            ToolbarItem {
                Button {
                    developer.scan()
                } label: {
                    Label("Analyze Again", systemImage: "arrow.clockwise")
                }
                .disabled(developer.phase == .scanning)
            }
        }
        .sheet(isPresented: $confirming) {
            CleanupConfirmationView(items: developer.selectedItems, method: model.settings.removalMethod) {
                confirming = false
                developer.cleanSelection()
                showingCleanup = true
            } onCancel: {
                confirming = false
            }
        }
        .sheet(isPresented: $showingCleanup) {
            CleanupProgressView(controller: developer.cleanup) { showingCleanup = false }
        }
        .confirmationDialog("Delete unavailable simulators?", isPresented: $confirmingSimctl) {
            Button("Run xcrun simctl delete unavailable", role: .destructive) { developer.deleteUnavailableSimulators() }
        } message: {
            Text("Apple's command removes only simulators whose runtime is no longer installed, together with the apps and data inside them.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let report = developer.report {
            List {
                ForEach(developer.presentKinds, id: \.self) { kind in
                    Section {
                        ForEach(report.items(for: kind)) { item in
                            DeveloperRow(item: item, isSelected: developer.selectedPaths.contains(item.path)) {
                                developer.toggle(item)
                            }
                        }
                        if kind == .simulators {
                            simulatorActions
                        }
                    } header: {
                        ToolHeader(kind: kind, size: report.size(for: kind))
                    }
                }
            }
            .listStyle(.inset)
        } else if developer.phase == .scanning {
            VStack(spacing: NoriaSpacing.m) {
                SawView(isSpinning: true).frame(width: 110, height: 110)
                Text("Looking at developer tools…").font(NoriaFont.sectionTitle)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: NoriaSpacing.l) {
                EmptyStateView(title: "Clean up after Xcode and package managers",
                               message: "Noria looks at Xcode build data, archives, device support, simulators, package-manager caches and the dependencies of projects you have not touched in months. Each item explains what happens if you remove it.",
                               systemImage: "hammer")
                Button {
                    developer.scan()
                } label: {
                    Label("Analyze Developer Data", systemImage: "magnifyingglass")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var simulatorActions: some View {
        VStack(alignment: .leading, spacing: NoriaSpacing.xs) {
            if developer.canRunOfficialCommands {
                Button {
                    confirmingSimctl = true
                } label: {
                    Label("Delete Unavailable Simulators…", systemImage: "trash")
                }
                .disabled(developer.isRunningCommand)
            } else {
                Text("The App Store edition cannot run Apple's developer tools. Run this command in Terminal:")
                    .font(NoriaFont.caption).foregroundStyle(.secondary)
                CommandSnippet(command: "xcrun simctl delete unavailable")
            }
            if let output = developer.commandOutput {
                Text(output).font(NoriaFont.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(.vertical, NoriaSpacing.xs)
    }

    private var bottomBar: some View {
        HStack(spacing: NoriaSpacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("\(developer.selectedItems.count) items selected")
                    Text(verbatim: "· " + Format.bytes(developer.selectedSize))
                }
                .font(NoriaFont.body.weight(.medium))
                Text("Rebuildable caches are preselected. Archives, device support and project dependencies need your choice.")
                    .font(NoriaFont.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                confirming = true
            } label: {
                Text("Clean \(Format.bytes(developer.selectedSize))…")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(developer.selectedItems.isEmpty || developer.cleanup.isRunning)
        }
        .padding(.horizontal, NoriaSpacing.l)
        .padding(.vertical, NoriaSpacing.s)
        .background(.bar)
    }
}

private struct ToolHeader: View {
    var kind: DeveloperTool.Kind
    var size: Int64
    @Environment(AppModel.self) private var model

    var body: some View {
        let tool = DeveloperScanner.tools[kind]
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: NoriaSpacing.s) {
                Image(systemName: kind.systemImage).foregroundStyle(NoriaColor.accent)
                Text(kind.title).font(NoriaFont.sectionTitle).foregroundStyle(.primary)
                if tool?.regenerates == true {
                    Text("Rebuilt automatically")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .foregroundStyle(NoriaColor.safe)
                        .background(NoriaColor.safe.opacity(0.14), in: Capsule())
                }
                Spacer()
                Text(Format.bytes(size)).font(NoriaFont.body.monospacedDigit()).foregroundStyle(.secondary)
                if kind != .simulators {
                    Button("Select All") { model.developer.setSelection(kind, selected: true) }
                        .buttonStyle(.link).font(NoriaFont.caption)
                }
            }
            Text(kind.consequence).font(NoriaFont.caption).foregroundStyle(.secondary)
            Text(kind.recommendation).font(NoriaFont.caption.weight(.medium)).foregroundStyle(.secondary)
            if let command = tool?.officialCommand, kind != .simulators {
                HStack(spacing: 4) {
                    Text("Official command:").font(NoriaFont.caption).foregroundStyle(.secondary)
                    CommandSnippet(command: command)
                }
            }
        }
        .padding(.vertical, NoriaSpacing.xxs)
        .textCase(nil)
    }
}

private struct CommandSnippet: View {
    var command: String

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: command)
                .font(NoriaFont.caption.monospaced())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(NoriaColor.subtleFill, in: RoundedRectangle(cornerRadius: 4))
                .textSelection(.enabled)
            Button {
                SystemActions.copyToPasteboard(command)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(Text("Copy"))
        }
    }
}

private struct DeveloperRow: View {
    var item: DeveloperItem
    var isSelected: Bool
    var onToggle: () -> Void

    var body: some View {
        HStack(spacing: NoriaSpacing.s) {
            Toggle(isOn: Binding(get: { isSelected }, set: { _ in onToggle() })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(item.requiresOfficialCommand)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: NoriaSpacing.xs) {
                    Text(item.title).lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle).font(NoriaFont.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Text((item.path as NSString).abbreviatingWithTildeInPath)
                    .font(NoriaFont.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let date = item.lastUsed {
                Text(Format.date(date)).font(NoriaFont.caption).foregroundStyle(.secondary)
            }
            RiskBadge(risk: item.risk)
            Text(Format.bytes(item.size)).font(NoriaFont.body.monospacedDigit()).frame(width: 80, alignment: .trailing)
        }
        .contextMenu {
            Button("Reveal in Finder") { SystemActions.revealInFinder([item.path]) }
        }
    }
}
