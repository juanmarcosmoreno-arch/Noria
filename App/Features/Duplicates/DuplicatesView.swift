import AppKit
import NoriaCore
import SwiftUI

struct DuplicatesView: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false
    @State private var showingCleanup = false

    private var duplicates: DuplicatesModel { model.duplicates }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
            if !duplicates.groups.isEmpty {
                Divider()
                bottomBar
            }
        }
        .navigationTitle(Text("Duplicates"))
        .sheet(isPresented: $confirming) {
            CleanupConfirmationView(items: duplicates.plannedItems, method: model.settings.removalMethod) {
                confirming = false
                duplicates.removeSelection()
                showingCleanup = true
            } onCancel: {
                confirming = false
            }
        }
        .sheet(isPresented: $showingCleanup) {
            CleanupProgressView(controller: duplicates.cleanup) { showingCleanup = false }
        }
    }

    private var controls: some View {
        @Bindable var duplicates = duplicates
        return HStack(spacing: NoriaSpacing.m) {
            Button {
                duplicates.chooseRoot()
            } label: {
                Label((duplicates.rootPath as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .disabled(duplicates.isScanning)
            Picker("Size", selection: $duplicates.minimumSize) {
                ForEach(DuplicatesModel.MinimumSize.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            .disabled(duplicates.isScanning)
            Spacer()
            if duplicates.isScanning {
                ProgressView().controlSize(.small)
                Text(progressText)
                    .font(NoriaFont.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Cancel") { duplicates.cancel() }
                    .buttonStyle(SecondaryButtonStyle())
            } else {
                Button {
                    duplicates.start()
                } label: {
                    Label("Find Duplicates", systemImage: "square.on.square")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(.horizontal, NoriaSpacing.l)
        .padding(.vertical, NoriaSpacing.s)
    }

    private var progressText: String {
        if duplicates.stage == "hashing" {
            return String(localized: "Comparing contents: \(Format.count(duplicates.hashed)) of \(Format.count(duplicates.candidates)) candidates")
        }
        return String(localized: "\(Format.count(duplicates.filesVisited)) files examined")
    }

    @ViewBuilder
    private var content: some View {
        if !duplicates.groups.isEmpty {
            List {
                Section {
                    Text("Only files with byte-for-byte identical content are listed (same size and SHA-256). Names do not matter. Photos and other app libraries, apps and ~/Library are not searched.")
                        .font(NoriaFont.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(duplicates.groups) { group in
                    Section {
                        ForEach(group.files) { file in
                            DuplicateRow(file: file, isSelected: duplicates.selectedPaths.contains(file.path),
                                         isKeeper: duplicates.keeper(of: group)?.path == file.path) {
                                duplicates.toggle(file, in: group)
                            }
                        }
                    } header: {
                        HStack {
                            Image(systemName: group.kind.systemImage).foregroundStyle(NoriaColor.accent)
                            Text(group.files.first?.name ?? "")
                            Spacer()
                            Text("\(Format.count(group.files.count)) copies × \(Format.bytes(group.size))")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)
        } else {
            switch duplicates.phase {
            case .scanning:
                VStack(spacing: NoriaSpacing.m) {
                    SawView(isSpinning: true).frame(width: 110, height: 110)
                    Text(progressText).font(NoriaFont.sectionTitle)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .finished:
                EmptyStateView(title: "No duplicates found",
                               message: "No identical files above the chosen size in this folder.",
                               systemImage: "checkmark.circle")
            case .failed(let message):
                EmptyStateView(title: "The scan could not finish", message: "\(message)", systemImage: "exclamationmark.triangle")
            case .idle, .cancelled:
                EmptyStateView(title: "Find identical files",
                               message: "Noria compares file contents, not names. You decide which copies to remove, and one copy of each file is always kept.",
                               systemImage: "square.on.square")
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: NoriaSpacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Format.count(duplicates.groups.count)) groups · \(Format.bytes(duplicates.reclaimableSize)) in extra copies")
                    .font(NoriaFont.body.weight(.medium))
                Text(duplicates.selectionNotice ?? String(localized: "Automatic selection keeps the oldest copy, preferring copies outside Downloads."))
                    .font(NoriaFont.caption)
                    .foregroundStyle(duplicates.selectionNotice == nil ? Color.secondary : NoriaColor.review)
            }
            Spacer()
            Button("Select Extra Copies") { duplicates.selectAutomatically() }
                .buttonStyle(SecondaryButtonStyle())
            Button("Deselect All") { duplicates.selectedPaths = [] }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(duplicates.selectedPaths.isEmpty)
            Button {
                confirming = true
            } label: {
                Text("Remove \(Format.bytes(duplicates.selectedSize))…")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(duplicates.plannedRemovals.isEmpty || duplicates.cleanup.isRunning)
        }
        .padding(.horizontal, NoriaSpacing.l)
        .padding(.vertical, NoriaSpacing.s)
        .background(.bar)
    }
}

private struct DuplicateRow: View {
    var file: DuplicateFile
    var isSelected: Bool
    var isKeeper: Bool
    var onToggle: () -> Void

    var body: some View {
        HStack(spacing: NoriaSpacing.s) {
            Toggle(isOn: Binding(get: { isSelected }, set: { _ in onToggle() })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                .resizable()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).lineLimit(1)
                Text((file.parentPath as NSString).abbreviatingWithTildeInPath)
                    .font(NoriaFont.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if isKeeper {
                Text("Suggested to keep")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .foregroundStyle(NoriaColor.safe)
                    .background(NoriaColor.safe.opacity(0.14), in: Capsule())
            }
            Text(Format.date(file.modificationDate)).font(NoriaFont.caption).foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Reveal in Finder") { SystemActions.revealInFinder([file.path]) }
            Button("Open") { SystemActions.open(file.path) }
        }
    }
}
