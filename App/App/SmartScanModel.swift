import NoriaCore
import Observation
import SwiftUI

/// State of the Smart Scan and of the Smart Clean review.
@MainActor
@Observable
final class SmartScanModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case finished
        case cancelled
        case failed(String)
    }

    private unowned let app: AppModel

    private(set) var phase: Phase = .idle
    private(set) var startedAt: Date?
    private(set) var currentCategory: CleanCategory?
    private(set) var categoryIndex = 0
    private(set) var categoryTotal = 0
    /// Files examined in the current scan (all categories so far).
    private(set) var filesVisited = 0
    /// Bytes found in reported items so far.
    private(set) var bytesFound: Int64 = 0
    private(set) var plannedCategories: [CleanCategory] = []
    private(set) var results: [CleanCategory: CategoryResult] = [:]
    private(set) var report: ScanReport?
    private(set) var recommendations: [Recommendation] = []
    private(set) var appNames: [String: String] = [:]

    var selectedIDs: Set<UUID> = []
    let cleanup = CleanupController()

    private var scanTask: Task<Void, Never>?
    private var finishedCategoriesFiles = 0

    init(app: AppModel) {
        self.app = app
    }

    var isScanning: Bool { phase == .scanning }

    /// Real progress at category granularity: categories completed / categories planned.
    /// Within a category the amount of work is unknown, so no finer percentage is invented.
    var categoryProgress: Double? {
        guard isScanning, categoryTotal > 0 else { return nil }
        let done = Double(results.count)
        return done > 0 ? done / Double(categoryTotal) : nil
    }

    var allItems: [ScanItem] { report?.allItems ?? [] }

    var selectedItems: [ScanItem] { allItems.filter { selectedIDs.contains($0.id) } }

    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.allocatedSize } }

    func start() {
        guard !isScanning else { return }
        // App Store edition: the first scan asks for access to the home folder.
        if app.folderAccess.needsGrant {
            app.folderAccess.requestHomeAccess()
            guard !app.folderAccess.needsGrant else { return }
        }
        scanTask?.cancel()
        var settings = app.settings
        settings.enabledCategories.subtract(AppEdition.unavailableCategories)
        let engine = SmartScanEngine(locations: app.locations, appLookup: AppModel.appLookup)
        plannedCategories = CleanCategory.smartScanCategories.filter { settings.enabledCategories.contains($0) }
        phase = .scanning
        startedAt = Date()
        currentCategory = nil
        categoryIndex = 0
        categoryTotal = plannedCategories.count
        filesVisited = 0
        finishedCategoriesFiles = 0
        bytesFound = 0
        results = [:]
        report = nil
        recommendations = []
        selectedIDs = []
        cleanup.reset()

        scanTask = Task { [weak self] in
            do {
                for try await event in engine.scan(settings: settings) {
                    self?.handle(event)
                }
                if Task.isCancelled { self?.phase = .cancelled }
            } catch is CancellationError {
                self?.phase = .cancelled
            } catch {
                self?.phase = .failed(String(describing: error))
            }
            self?.currentCategory = nil
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        if isScanning { phase = .cancelled }
    }

    private func handle(_ event: ScanEvent) {
        switch event {
        case .categoryStarted(let category, let index, let total):
            currentCategory = category
            categoryIndex = index
            categoryTotal = total
            finishedCategoriesFiles = filesVisited
        case .progress(_, let files, _):
            filesVisited = finishedCategoriesFiles + files
        case .categoryFinished(let result):
            results[result.category] = result
            bytesFound += result.items.filter(\.isSelectable).reduce(0) { $0 + $1.allocatedSize }
        case .finished(let report):
            self.report = report
            recommendations = RecommendationEngine.recommendations(for: report)
            // Pre-select SAFE items only; REVIEW items always need an explicit choice.
            selectedIDs = Set(report.allItems.filter { $0.isSelectable && $0.risk == .safe }.map(\.id))
            phase = .finished
            resolveAppNames(for: report.allItems)
            app.record(.scan(report))
        }
    }

    private func resolveAppNames(for items: [ScanItem]) {
        var names: [String: String] = [:]
        for bundleID in Set(items.compactMap(\.bundleIdentifier)) {
            if let name = AppDirectory.appName(for: bundleID) { names[bundleID] = name }
        }
        appNames = names
    }

    func associatedApp(for item: ScanItem) -> String? {
        if let owner = item.ownerName { return owner }
        if let bundleID = item.bundleIdentifier { return appNames[bundleID] }
        return nil
    }

    func items(in category: CleanCategory) -> [ScanItem] {
        results[category]?.items ?? []
    }

    func toggle(_ item: ScanItem) {
        guard item.isSelectable else { return }
        if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) } else { selectedIDs.insert(item.id) }
    }

    func setSelection(_ items: [ScanItem], selected: Bool) {
        for item in items where item.isSelectable {
            if selected { selectedIDs.insert(item.id) } else { selectedIDs.remove(item.id) }
        }
    }

    func selectAllSafe() {
        selectedIDs = Set(allItems.filter { $0.isSelectable && $0.risk == .safe }.map(\.id))
    }

    /// Runs the confirmed cleanup on the current selection.
    func cleanSelection() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        cleanup.run(items: items, app: app) { [weak self] report in
            self?.apply(report)
        }
    }

    /// Removes cleaned items from the results so the view reflects the disk.
    private func apply(_ cleanupReport: CleanupReport) {
        let removed = Set(cleanupReport.removed.map(\.itemID))
        guard var report else { return }
        report.categories = report.categories.map { category in
            var category = category
            category.items.removeAll { removed.contains($0.id) }
            return category
        }
        self.report = report
        for category in report.categories { results[category.category] = category }
        selectedIDs.subtract(removed)
        recommendations = RecommendationEngine.recommendations(for: report)
    }
}

/// Runs a cleanup through `CleaningEngine` and exposes its progress.
@MainActor
@Observable
final class CleanupController {
    enum State: Equatable {
        case idle
        case running(done: Int, total: Int)
        case finished
    }

    private(set) var state: State = .idle
    private(set) var report: CleanupReport?
    private(set) var currentPath: String?
    private var task: Task<Void, Never>?
    private var cancellation = CleanupCancellation()

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    func reset() {
        guard !isRunning else { return }
        state = .idle
        report = nil
    }

    func run(items: [ScanItem], app: AppModel, onFinish: @escaping @MainActor (CleanupReport) -> Void) {
        guard !isRunning else { return }
        let remover: any FileRemoving
        do {
            remover = try Removers.remover(for: app.settings.removalMethod, quarantine: app.quarantine)
        } catch {
            return
        }
        let engine = CleaningEngine(policy: app.safetyPolicy, remover: remover)
        state = .running(done: 0, total: items.count)
        report = nil
        let cancellation = CleanupCancellation()
        self.cancellation = cancellation
        task = Task { [weak self] in
            var done = 0
            for await event in engine.clean(items, cancellation: cancellation) {
                switch event {
                case .itemStarted(let item, _, _):
                    self?.currentPath = item.path
                case .itemFinished:
                    done += 1
                    self?.state = .running(done: done, total: items.count)
                case .finished(let report):
                    self?.report = report
                    self?.state = .finished
                    self?.currentPath = nil
                    app.record(.cleanup(report))
                    app.refreshVolume()
                    Task { await app.refreshQuarantine() }
                    onFinish(report)
                }
            }
        }
    }

    /// Stops after the item currently being processed; the report still arrives.
    func cancel() {
        cancellation.cancel()
    }
}
