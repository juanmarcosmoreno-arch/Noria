import AppKit
import NoriaCore
import SwiftUI

struct LargeFilesView: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false
    @State private var showingCleanup = false

    private var largeFiles: LargeFilesModel { model.largeFiles }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if largeFiles.files.isEmpty {
                emptyState
            } else {
                table(largeFiles)
            }
            Divider()
            bottomBar
        }
        .navigationTitle(Text("Large Files"))
        .sheet(isPresented: $confirming) {
            CleanupConfirmationView(items: largeFiles.removableSelection.map { $0.asScanItem() },
                                    method: model.settings.removalMethod) {
                confirming = false
                largeFiles.moveSelectionToTrash()
                showingCleanup = true
            } onCancel: {
                confirming = false
            }
        }
        .sheet(isPresented: $showingCleanup) {
            CleanupProgressView(controller: largeFiles.cleanup) { showingCleanup = false }
        }
    }

    private var controls: some View {
        @Bindable var largeFiles = largeFiles
        return HStack(spacing: NoriaSpacing.m) {
            Button {
                largeFiles.chooseRoot()
            } label: {
                Label((largeFiles.rootPath as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .disabled(largeFiles.isScanning)
            .help(Text("Choose the folder to scan"))

            Picker("Size", selection: $largeFiles.threshold) {
                ForEach(LargeFilesModel.Threshold.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            .disabled(largeFiles.isScanning)

            if largeFiles.threshold == .custom {
                TextField("MB", value: $largeFiles.customThresholdMB, format: .number)
                    .frame(width: 70)
                Text(verbatim: "MB").foregroundStyle(.secondary)
            }

            Picker("Type", selection: $largeFiles.kindFilter) {
                Text("All Types").tag(FileKind?.none)
                ForEach(FileKind.allCases, id: \.self) { kind in
                    Label(kind.title, systemImage: kind.systemImage).tag(FileKind?.some(kind))
                }
            }
            .fixedSize()

            Spacer()

            if largeFiles.isScanning {
                ProgressView().controlSize(.small)
                Text("\(Format.count(largeFiles.filesVisited)) files · \(Format.bytes(largeFiles.bytesVisited))")
                    .font(NoriaFont.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Cancel") { largeFiles.cancel() }
                    .buttonStyle(SecondaryButtonStyle())
            } else {
                Button {
                    largeFiles.start()
                } label: {
                    Label("Find Large Files", systemImage: "magnifyingglass")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(.horizontal, NoriaSpacing.l)
        .padding(.vertical, NoriaSpacing.s)
    }

    private func table(_ model: LargeFilesModel) -> some View {
        @Bindable var model = model
        return Table(model.visibleFiles, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name) { file in
                HStack(spacing: NoriaSpacing.xs) {
                    Image(systemName: file.kind.systemImage).foregroundStyle(NoriaColor.accent).frame(width: 18)
                    Text(file.name).lineLimit(1)
                    if file.risk == .protected {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                            .help(Text("Inside a location managed by macOS or another app. Noria does not modify it."))
                    }
                }
            }
            .width(min: 180, ideal: 260)
            TableColumn("Type", value: \.kind.title) { file in
                Text(file.kind.title).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110)
            TableColumn("Size", value: \.allocatedSize) { file in
                Text(Format.bytes(file.allocatedSize)).monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn("Modified", value: \.modificationDate) { file in
                Text(Format.date(file.modificationDate)).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110)
            TableColumn("Location", value: \.parentPath) { file in
                Text((file.parentPath as NSString).abbreviatingWithTildeInPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .contextMenu(forSelectionType: LargeFile.ID.self) { ids in
            Button("Reveal in Finder") { SystemActions.revealInFinder(Array(ids)) }
            if ids.count == 1, let id = ids.first {
                Button("Open") { SystemActions.open(id) }
                Button("Copy Path") { SystemActions.copyToPasteboard(id) }
                Divider()
                Button("Always Exclude This Item") { self.model.addExclusion(id) }
            }
        } primaryAction: { ids in
            SystemActions.revealInFinder(Array(ids))
        }
        .inspector(isPresented: .constant(true)) {
            LargeFileInspector(file: model.selectedFiles.count == 1 ? model.selectedFiles.first : nil)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 340)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch largeFiles.phase {
        case .scanning:
            VStack(spacing: NoriaSpacing.m) {
                SawView(isSpinning: true).frame(width: 110, height: 110)
                Text("Looking for large files…").font(NoriaFont.sectionTitle)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .finished:
            EmptyStateView(title: "No large files found",
                           message: "No files above \(Format.bytes(largeFiles.thresholdBytes)) in this folder.",
                           systemImage: "checkmark.circle")
        case .failed(let message):
            EmptyStateView(title: "The scan could not finish", message: "\(message)", systemImage: "exclamationmark.triangle")
        case .idle, .cancelled:
            EmptyStateView(title: "Find large files",
                           message: "Choose a folder and a size, then start the scan. Nothing is changed during the scan.",
                           systemImage: "doc.on.doc")
        }
    }

    private var bottomBar: some View {
        HStack(spacing: NoriaSpacing.m) {
            if let report = largeFiles.lastReport {
                let count = Format.count(report.files.count)
                let total = Format.bytes(report.files.reduce(0) { $0 + $1.allocatedSize })
                let examined = Format.count(report.filesVisited)
                let duration = Format.duration(report.duration)
                Text("\(count) files · \(total) · \(examined) examined in \(duration)")
                    .font(NoriaFont.caption)
                    .foregroundStyle(.secondary)
                if report.inaccessibleCount > 0 {
                    Text("· \(Format.count(report.inaccessibleCount)) folders not readable")
                        .font(NoriaFont.caption)
                        .foregroundStyle(.secondary)
                        .help(Text("macOS protects some folders unless you grant access in Privacy & Security."))
                }
            }
            Spacer()
            Button("Reveal in Finder") { SystemActions.revealInFinder(largeFiles.selectedFiles.map(\.path)) }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(largeFiles.selection.isEmpty)
            Button {
                confirming = true
            } label: {
                Text(model.settings.removalMethod == .moveToTrash ? LocalizedStringKey("Move to Trash…") : LocalizedStringKey("Delete…"))
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(largeFiles.removableSelection.isEmpty || largeFiles.cleanup.isRunning)
        }
        .padding(.horizontal, NoriaSpacing.l)
        .padding(.vertical, NoriaSpacing.s)
        .background(.bar)
    }
}

private struct LargeFileInspector: View {
    var file: LargeFile?

    var body: some View {
        if let file {
            ScrollView {
                VStack(alignment: .leading, spacing: NoriaSpacing.m) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                        .resizable()
                        .frame(width: 64, height: 64)
                    Text(file.name).font(NoriaFont.sectionTitle).textSelection(.enabled)
                    RiskBadge(risk: file.risk)
                    Text(file.risk == .protected ? ItemReason.protectedLocation.explanation : RiskLevel.review.explanation)
                        .font(NoriaFont.caption).foregroundStyle(.secondary)
                    Divider()
                    info("Size", Format.bytes(file.allocatedSize))
                    info("Type", file.kind.title)
                    info("Modified", Format.dateTime(file.modificationDate))
                    if file.isPackage {
                        Text("Bundle measured as a whole; its contents are not listed separately.")
                            .font(NoriaFont.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Location").font(NoriaFont.caption).foregroundStyle(.secondary)
                        Text(file.path).font(NoriaFont.caption).textSelection(.enabled)
                    }
                    HStack {
                        Button("Reveal in Finder") { SystemActions.revealInFinder([file.path]) }
                        Button("Open") { SystemActions.open(file.path) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .padding(NoriaSpacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Select a file to see its details.")
                .font(NoriaFont.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func info(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(NoriaFont.body)
    }
}
