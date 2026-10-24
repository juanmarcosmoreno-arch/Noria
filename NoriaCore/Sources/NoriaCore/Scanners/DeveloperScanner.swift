import Foundation

/// One developer-tool location Noria knows how to explain.
public struct DeveloperTool: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        case xcodeDerivedData, xcodeArchives, xcodeDeviceSupport, xcodePreviews, simulatorCaches, simulators
        case swiftPM, npm, yarn, pnpm, bun, pip, homebrew, cocoaPods, go, gradle, maven, cargo
        case projectDependencies
    }

    public var id: Kind { kind }
    public var kind: Kind
    /// Human-readable tool name (not localized: product names).
    public var tool: String
    /// The official command that cleans it, when one exists.
    public var officialCommand: String?
    /// Whether the tool recreates the content by itself when needed.
    public var regenerates: Bool
}

/// A developer item: one project's DerivedData, one archive, one simulator…
public struct DeveloperItem: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public var path: String
    public var title: String
    public var subtitle: String?
    public var tool: DeveloperTool.Kind
    public var size: Int64
    public var lastUsed: Date?
    public var risk: RiskLevel
    /// For simulators: removed through `xcrun simctl`, never by deleting folders.
    public var requiresOfficialCommand: Bool
    public var fingerprint: FileStat?

    public func asScanItem() -> ScanItem? {
        guard !requiresOfficialCommand else { return nil }
        // Project dependencies live in the user's own folders: same rules as Large Files.
        let category: CleanCategory = tool == .projectDependencies ? .largeFiles : .developerCache
        return ScanItem(path: path, name: title, category: category, risk: risk,
                        reason: .developerItem(tool: tool.rawValue), allocatedSize: size, fileCount: 1,
                        modificationDate: lastUsed, fingerprint: fingerprint)
    }
}

public struct DeveloperReport: Sendable {
    public var items: [DeveloperItem]
    public var duration: TimeInterval

    public func items(for kind: DeveloperTool.Kind) -> [DeveloperItem] { items.filter { $0.tool == kind } }
    public func size(for kind: DeveloperTool.Kind) -> Int64 { items(for: kind).reduce(0) { $0 + $1.size } }
}

/// Inspects developer tools' data. Read-only.
///
/// * Rebuildable caches (DerivedData, package caches) are SAFE.
/// * Archives, device support, Maven repository and project dependencies are REVIEW:
///   they can be recreated but at a cost (rebuild, re-download, symbolication).
/// * Simulators are removed only through `xcrun simctl` (Apple's supported way).
/// * Project dependencies are only listed for projects untouched for `staleProjectDays`.
public struct DeveloperScanner: Sendable {
    public var locations: SystemLocations
    public var projectRoots: [String]
    public var staleProjectDays: Int

    public init(locations: SystemLocations = .current, projectRoots: [String]? = nil, staleProjectDays: Int = 90) {
        self.locations = locations
        let home = locations.home
        self.projectRoots = projectRoots ?? ["Developer", "Projects", "Code", "code", "src", "dev", "GitHub", "repos"]
            .map { (home as NSString).appendingPathComponent($0) }
        self.staleProjectDays = staleProjectDays
    }

    public static let tools: [DeveloperTool.Kind: DeveloperTool] = {
        let list: [DeveloperTool] = [
            DeveloperTool(kind: .xcodeDerivedData, tool: "Xcode", officialCommand: nil, regenerates: true),
            DeveloperTool(kind: .xcodeArchives, tool: "Xcode", officialCommand: nil, regenerates: false),
            DeveloperTool(kind: .xcodeDeviceSupport, tool: "Xcode", officialCommand: nil, regenerates: true),
            DeveloperTool(kind: .xcodePreviews, tool: "Xcode Previews", officialCommand: "xcrun simctl --set previews delete all", regenerates: true),
            DeveloperTool(kind: .simulatorCaches, tool: "Simulator", officialCommand: nil, regenerates: true),
            DeveloperTool(kind: .simulators, tool: "Simulator", officialCommand: "xcrun simctl delete unavailable", regenerates: false),
            DeveloperTool(kind: .swiftPM, tool: "Swift Package Manager", officialCommand: "swift package purge-cache", regenerates: true),
            DeveloperTool(kind: .npm, tool: "npm", officialCommand: "npm cache clean --force", regenerates: true),
            DeveloperTool(kind: .yarn, tool: "Yarn", officialCommand: "yarn cache clean", regenerates: true),
            DeveloperTool(kind: .pnpm, tool: "pnpm", officialCommand: "pnpm store prune", regenerates: true),
            DeveloperTool(kind: .bun, tool: "Bun", officialCommand: "bun pm cache rm", regenerates: true),
            DeveloperTool(kind: .pip, tool: "pip", officialCommand: "pip cache purge", regenerates: true),
            DeveloperTool(kind: .homebrew, tool: "Homebrew", officialCommand: "brew cleanup --prune=all", regenerates: true),
            DeveloperTool(kind: .cocoaPods, tool: "CocoaPods", officialCommand: "pod cache clean --all", regenerates: true),
            DeveloperTool(kind: .go, tool: "Go", officialCommand: "go clean -cache", regenerates: true),
            DeveloperTool(kind: .gradle, tool: "Gradle", officialCommand: nil, regenerates: true),
            DeveloperTool(kind: .maven, tool: "Maven", officialCommand: nil, regenerates: true),
            DeveloperTool(kind: .cargo, tool: "Cargo", officialCommand: nil, regenerates: true),
            DeveloperTool(kind: .projectDependencies, tool: "Projects", officialCommand: nil, regenerates: true),
        ]
        return Dictionary(uniqueKeysWithValues: list.map { ($0.kind, $0) })
    }()

    private func inHome(_ components: String...) -> String {
        components.reduce(locations.home) { ($0 as NSString).appendingPathComponent($1) }
    }

    /// Whole-folder caches: (kind, path, risk).
    var cacheFolders: [(DeveloperTool.Kind, String, RiskLevel)] {
        [
            (.xcodePreviews, inHome("Library", "Developer", "Xcode", "UserData", "Previews"), .safe),
            (.simulatorCaches, inHome("Library", "Developer", "CoreSimulator", "Caches"), .safe),
            (.swiftPM, inHome("Library", "Caches", "org.swift.swiftpm"), .safe),
            (.npm, locations.npmCache, .safe),
            (.yarn, locations.yarnCache, .safe),
            (.pnpm, inHome("Library", "pnpm", "store"), .safe),
            (.bun, inHome(".bun", "install", "cache"), .safe),
            (.pip, locations.pipCache, .safe),
            (.homebrew, locations.homebrewCache, .safe),
            (.cocoaPods, locations.cocoaPodsCache, .safe),
            (.go, locations.goBuildCache, .safe),
            (.gradle, inHome(".gradle", "caches"), .safe),
            (.maven, inHome(".m2", "repository"), .review),
            (.cargo, inHome(".cargo", "registry"), .safe),
        ]
    }

    public func scan() throws -> DeveloperReport {
        let start = Date()
        var items: [DeveloperItem] = []
        let tracker = InodeTracker()

        func measure(_ path: String) throws -> (Int64, Date?)? {
            guard FileSystem.stat(path) != nil else { return nil }
            let summary = try DirectorySizer().measure(path, tracker: tracker)
            return summary.allocatedSize > 0 ? (summary.allocatedSize, summary.newestModification) : nil
        }

        // DerivedData: one item per project, named after the project.
        for entry in (try? FileSystem.directoryEntries(locations.derivedData)) ?? [] {
            try Task.checkCancellationAsNoriaError()
            guard let (size, date) = try measure(entry.path) else { continue }
            let workspace = Self.plistString((entry.path as NSString).appendingPathComponent("info.plist"), key: "WorkspacePath")
            let title = workspace.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
                ?? entry.name.components(separatedBy: "-").dropLast().joined(separator: "-")
            items.append(DeveloperItem(path: entry.path, title: title.isEmpty ? entry.name : title, subtitle: workspace,
                                       tool: .xcodeDerivedData, size: size, lastUsed: date, risk: .safe,
                                       requiresOfficialCommand: false, fingerprint: FileSystem.stat(entry.path)))
        }

        // Archives: one item per .xcarchive with app name and version.
        for day in (try? FileSystem.directoryEntries(locations.xcodeArchives)) ?? [] {
            for archive in (try? FileSystem.directoryEntries(day.path)) ?? [] where archive.name.hasSuffix(".xcarchive") {
                try Task.checkCancellationAsNoriaError()
                guard let (size, date) = try measure(archive.path) else { continue }
                let info = (archive.path as NSString).appendingPathComponent("Info.plist")
                let name = Self.plistString(info, key: "Name") ?? (archive.name as NSString).deletingPathExtension
                let version = Self.plistString(info, key: "ApplicationProperties.CFBundleShortVersionString")
                items.append(DeveloperItem(path: archive.path, title: name, subtitle: version, tool: .xcodeArchives,
                                           size: size, lastUsed: date, risk: .review, requiresOfficialCommand: false,
                                           fingerprint: FileSystem.stat(archive.path)))
            }
        }

        // Device support for every platform: one item per OS version.
        let developer = inHome("Library", "Developer", "Xcode")
        for platform in (try? FileSystem.directoryEntries(developer)) ?? [] where platform.name.hasSuffix("DeviceSupport") {
            for version in (try? FileSystem.directoryEntries(platform.path)) ?? [] {
                try Task.checkCancellationAsNoriaError()
                guard let (size, date) = try measure(version.path) else { continue }
                items.append(DeveloperItem(path: version.path, title: version.name,
                                           subtitle: platform.name.replacingOccurrences(of: " DeviceSupport", with: ""),
                                           tool: .xcodeDeviceSupport, size: size, lastUsed: date, risk: .review,
                                           requiresOfficialCommand: false, fingerprint: FileSystem.stat(version.path)))
            }
        }

        // Simulators: listed per device; only unavailable ones are suggested.
        let devices = inHome("Library", "Developer", "CoreSimulator", "Devices")
        for device in (try? FileSystem.directoryEntries(devices)) ?? [] {
            try Task.checkCancellationAsNoriaError()
            let plist = (device.path as NSString).appendingPathComponent("device.plist")
            guard let name = Self.plistString(plist, key: "name"), let (size, date) = try measure(device.path) else { continue }
            let runtime = Self.plistString(plist, key: "runtime")?.components(separatedBy: ".").last?
                .replacingOccurrences(of: "-", with: " ")
            items.append(DeveloperItem(path: device.path, title: name, subtitle: runtime, tool: .simulators, size: size,
                                       lastUsed: date, risk: .review, requiresOfficialCommand: true, fingerprint: nil))
        }

        // Whole caches.
        for (kind, path, risk) in cacheFolders {
            try Task.checkCancellationAsNoriaError()
            guard let (size, date) = try measure(path) else { continue }
            items.append(DeveloperItem(path: path, title: Self.tools[kind]?.tool ?? kind.rawValue, subtitle: nil, tool: kind,
                                       size: size, lastUsed: date, risk: risk, requiresOfficialCommand: false,
                                       fingerprint: FileSystem.stat(path)))
        }

        items += try staleProjectDependencies(tracker: tracker)
        return DeveloperReport(items: items, duration: Date().timeIntervalSince(start))
    }

    /// Dependency folders that a package manager can recreate, inside projects nobody
    /// touched for `staleProjectDays`. Each needs its manifest next to it.
    static let dependencyFolders: [(folder: String, manifest: String)] = [
        ("node_modules", "package.json"), ("Pods", "Podfile"), (".build", "Package.swift"),
        ("target", "Cargo.toml"), (".gradle", "build.gradle"), ("build", "build.gradle"),
        (".venv", "pyproject.toml"), ("venv", "requirements.txt"),
    ]

    func staleProjectDependencies(tracker: InodeTracker) throws -> [DeveloperItem] {
        var items: [DeveloperItem] = []
        let cutoff = Date().addingTimeInterval(-Double(staleProjectDays) * 86_400)
        var options = WalkOptions()
        options.descendsIntoPackages = false
        for root in projectRoots where FileSystem.stat(root)?.type == .directory {
            try FileWalker(options: options).walk(root: root) { path, stat in
                guard stat.type == .directory, path != root else { return .continue }
                let name = (path as NSString).lastPathComponent
                guard let rule = Self.dependencyFolders.first(where: { $0.folder == name }) else {
                    // Do not descend into other dependency/VCS folders.
                    return name.hasPrefix(".") && name != ".build" && name != ".venv" && name != ".gradle" ? .skipDescendants : .continue
                }
                let project = (path as NSString).deletingLastPathComponent
                guard FileSystem.stat((project as NSString).appendingPathComponent(rule.manifest)) != nil else { return .skipDescendants }
                // The project's own files (not the dependency folder) decide whether it is stale.
                let projectEntries = (try? FileSystem.directoryEntries(project)) ?? []
                let newestOwn = projectEntries.filter { $0.name != name }
                    .compactMap { FileSystem.stat($0.path)?.modificationDate }.max() ?? stat.modificationDate
                guard newestOwn < cutoff else { return .skipDescendants }
                let size = try DirectorySizer().measure(path, tracker: tracker).allocatedSize
                if size > 0 {
                    items.append(DeveloperItem(path: path, title: (project as NSString).lastPathComponent, subtitle: name,
                                               tool: .projectDependencies, size: size, lastUsed: newestOwn, risk: .review,
                                               requiresOfficialCommand: false, fingerprint: stat))
                }
                return .skipDescendants
            }
        }
        return items
    }

    /// Reads a (possibly nested, dot-separated) string from a property list.
    static func plistString(_ path: String, key: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              var value = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        for component in key.split(separator: ".") {
            guard let dictionary = value as? [String: Any], let next = dictionary[String(component)] else { return nil }
            value = next
        }
        return value as? String
    }
}
