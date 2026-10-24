import AppKit
import NoriaCore
import Observation
import SwiftUI

/// State of Developer Clean.
@MainActor
@Observable
final class DeveloperModel {
    enum Phase: Equatable {
        case idle, scanning, finished
        case failed(String)
    }

    private unowned let app: AppModel

    private(set) var phase: Phase = .idle
    private(set) var report: DeveloperReport?
    var selectedPaths: Set<String> = []
    private(set) var commandOutput: String?
    private(set) var isRunningCommand = false
    let cleanup = CleanupController()

    init(app: AppModel) {
        self.app = app
    }

    var selectedItems: [ScanItem] {
        (report?.items ?? []).filter { selectedPaths.contains($0.path) }.compactMap { $0.asScanItem() }
    }

    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.allocatedSize } }

    /// Tool kinds present in the report, in a fixed, meaningful order.
    var presentKinds: [DeveloperTool.Kind] {
        DeveloperTool.Kind.allCases.filter { !(report?.items(for: $0).isEmpty ?? true) }
            .sorted { (report?.size(for: $0) ?? 0) > (report?.size(for: $1) ?? 0) }
    }

    func scan() {
        guard phase != .scanning else { return }
        guard app.folderAccess.ensureReadable(app.locations.home) else { return }
        phase = .scanning
        let scanner = DeveloperScanner(locations: app.locations)
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try scanner.scan() } }.value
            switch result {
            case .success(var report):
                report.items.sort { $0.size > $1.size }
                self.report = report
                // Rebuildable caches start selected; anything that costs work to recreate does not.
                selectedPaths = Set(report.items.filter { $0.risk == .safe && !$0.requiresOfficialCommand }.map(\.path))
                phase = .finished
            case .failure(let error):
                phase = .failed(String(describing: error))
            }
        }
    }

    func toggle(_ item: DeveloperItem) {
        guard !item.requiresOfficialCommand else { return }
        if selectedPaths.contains(item.path) { selectedPaths.remove(item.path) } else { selectedPaths.insert(item.path) }
    }

    func setSelection(_ kind: DeveloperTool.Kind, selected: Bool) {
        for item in report?.items(for: kind) ?? [] where !item.requiresOfficialCommand {
            if selected { selectedPaths.insert(item.path) } else { selectedPaths.remove(item.path) }
        }
    }

    func cleanSelection() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        cleanup.run(items: items, app: app) { [weak self] report in
            guard let self else { return }
            let removed = Set(report.removed.map(\.path))
            self.report?.items.removeAll { removed.contains($0.path) }
            selectedPaths.subtract(removed)
        }
    }

    /// Apple's tools can only be run outside the App Sandbox.
    var canRunOfficialCommands: Bool { !AppEdition.isSandboxed }

    /// Runs `xcrun simctl delete unavailable`, Apple's supported way to remove
    /// simulators whose runtime is no longer installed.
    func deleteUnavailableSimulators() {
        guard canRunOfficialCommands, !isRunningCommand else { return }
        isRunningCommand = true
        commandOutput = nil
        Task {
            let output = await Task.detached(priority: .userInitiated) { () -> String in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                process.arguments = ["simctl", "delete", "unavailable"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    return process.terminationStatus == 0 ? (text.isEmpty ? String(localized: "Done.") : text) : text
                } catch {
                    return error.localizedDescription
                }
            }.value
            commandOutput = output
            isRunningCommand = false
            app.record(OperationRecord(date: Date(), kind: .cleanup, duration: 0, removedPaths: ["xcrun simctl delete unavailable"]))
            scan()
        }
    }
}
