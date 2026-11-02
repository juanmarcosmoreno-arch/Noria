import AppKit
import NoriaCore
import SwiftUI

/// Privacy: browsing data of the browsers installed for this user. Nothing is
/// preselected, every kind explains what removing it means, and the browser must
/// be closed first. Passwords, bookmarks and Safari are never touched.
struct PrivacyView: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false
    @State private var showingCleanup = false

    private var privacy: PrivacyModel { model.privacy }

    var body: some View {
        VStack(spacing: 0) {
            content
            if privacy.report != nil {
                Divider()
                bottomBar
            }
        }
        .navigationTitle(Text("Privacy"))
        .toolbar {
            ToolbarItem {
                Button {
                    privacy.scan()
                } label: {
                    Label("Analyze Again", systemImage: "arrow.clockwise")
                }
                .disabled(privacy.phase == .scanning)
            }
        }
        .sheet(isPresented: $confirming) {
            CleanupConfirmationView(items: privacy.selectedItems, method: model.settings.removalMethod) {
                confirming = false
                privacy.cleanSelection()
                showingCleanup = true
            } onCancel: {
                confirming = false
            }
        }
        .sheet(isPresented: $showingCleanup) {
            CleanupProgressView(controller: privacy.cleanup) { showingCleanup = false }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let report = privacy.report {
            List {
                Section {
                    Text("Only history, cookies, tabs and website data are listed. Saved passwords, bookmarks, extensions and settings are never shown or removed. Close a browser before removing its data.")
                        .font(NoriaFont.caption)
                        .foregroundStyle(.secondary)
                }
                if report.entries.isEmpty {
                    Text("No browsing data from supported browsers was found.")
                        .foregroundStyle(.secondary)
                }
                ForEach(privacy.browsers) { browser in
                    Section {
                        let entries = privacy.entries(for: browser)
                        let showsProfile = Set(entries.map(\.profilePath)).count > 1
                        ForEach(entries) { entry in
                            BrowserDataRow(entry: entry, showsProfile: showsProfile,
                                           isSelected: privacy.selectedEntryIDs.contains(entry.id)) {
                                privacy.toggle(entry)
                            }
                        }
                    } header: {
                        BrowserHeader(browser: browser, size: privacy.entries(for: browser).reduce(0) { $0 + $1.size })
                    }
                }
                if !report.notices.isEmpty {
                    Section {
                        ForEach(report.notices) { notice in
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: notice.browserName).font(NoriaFont.body.weight(.medium))
                                    Text(notice.kind.explanation)
                                        .font(NoriaFont.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            } icon: {
                                Image(systemName: "lock.shield").foregroundStyle(NoriaColor.protected)
                            }
                        }
                    } header: {
                        Text("Not removed by Noria")
                    }
                }
            }
            .listStyle(.inset)
        } else if privacy.phase == .scanning {
            VStack(spacing: NoriaSpacing.m) {
                SawView(isSpinning: true).frame(width: 110, height: 110)
                Text("Looking for browsing data…").font(NoriaFont.sectionTitle)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: NoriaSpacing.l) {
                if case .failed(let message) = privacy.phase {
                    EmptyStateView(title: "The scan could not finish", message: "\(message)", systemImage: "exclamationmark.triangle")
                } else {
                    EmptyStateView(title: "Your browsing data, under your control",
                                   message: "Noria shows the history, cookies, tabs and website data that Chrome, Brave, Edge, Vivaldi, Arc, Opera and Firefox keep on this Mac, and explains what removing each one means. Nothing is selected for you.",
                                   systemImage: "hand.raised")
                }
                Button {
                    privacy.scan()
                } label: {
                    Label("Analyze Browsing Data", systemImage: "magnifyingglass")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: NoriaSpacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("\(privacy.selectedItems.count) items selected")
                    Text(verbatim: "· " + Format.bytes(privacy.selectedSize))
                }
                .font(NoriaFont.body.weight(.medium))
                Text("Nothing is preselected. \(model.settings.removalMethod.outcome)")
                    .font(NoriaFont.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Deselect All") { privacy.selectedEntryIDs = [] }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(privacy.selectedEntryIDs.isEmpty)
            Button {
                confirming = true
            } label: {
                Text("Remove \(Format.bytes(privacy.selectedSize))…")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(privacy.selectedItems.isEmpty || privacy.cleanup.isRunning)
        }
        .padding(.horizontal, NoriaSpacing.l)
        .padding(.vertical, NoriaSpacing.s)
        .background(.bar)
    }
}

private struct BrowserHeader: View {
    var browser: Browser
    var size: Int64

    var body: some View {
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleIdentifier).isEmpty
        HStack(spacing: NoriaSpacing.s) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
            } else {
                Image(systemName: "globe").foregroundStyle(NoriaColor.accent)
            }
            Text(verbatim: browser.name).font(NoriaFont.sectionTitle).foregroundStyle(.primary)
            if running {
                Label("Open: quit it before removing its data", systemImage: "exclamationmark.triangle.fill")
                    .font(NoriaFont.caption)
                    .foregroundStyle(NoriaColor.review)
            }
            Spacer()
            Text(Format.bytes(size)).font(NoriaFont.body.monospacedDigit()).foregroundStyle(.secondary)
        }
        .textCase(nil)
        .padding(.vertical, NoriaSpacing.xxs)
    }
}

private struct BrowserDataRow: View {
    var entry: BrowserDataEntry
    var showsProfile: Bool
    var isSelected: Bool
    var onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: NoriaSpacing.s) {
            Toggle(isOn: Binding(get: { isSelected }, set: { _ in onToggle() })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(systemName: entry.kind.systemImage)
                .foregroundStyle(NoriaColor.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.kind.title).font(NoriaFont.body.weight(.medium))
                    if showsProfile {
                        Text(verbatim: "· " + entry.profile).foregroundStyle(.secondary)
                    }
                }
                Text(entry.kind.consequence)
                    .font(NoriaFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let date = entry.lastModified {
                    Text("Last changed \(Format.date(date))")
                        .font(NoriaFont.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: NoriaSpacing.s)
            RiskBadge(risk: .review)
            Text(Format.bytes(entry.size))
                .font(NoriaFont.body.monospacedDigit())
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Reveal in Finder") { SystemActions.revealInFinder(entry.items.map(\.path)) }
        }
    }
}
