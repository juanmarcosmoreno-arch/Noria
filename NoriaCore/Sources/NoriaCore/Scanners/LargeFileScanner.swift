import Foundation

/// Broad file families used by Large Files and the Space Map.
public enum FileKind: String, Codable, Sendable, CaseIterable {
    case video, audio, image, diskImage, installer, archive, backup, application, library, document, other

    static let byExtension: [String: FileKind] = {
        var map: [String: FileKind] = [:]
        func add(_ kind: FileKind, _ exts: [String]) { exts.forEach { map[$0] = kind } }
        add(.video, ["mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "flv", "mpg", "mpeg", "mts", "m2ts", "3gp", "braw", "r3d", "prores"])
        add(.audio, ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "alac", "ogg", "caf"])
        add(.image, ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "raw", "cr2", "cr3", "nef", "arw", "dng", "psd", "psb", "gif", "webp"])
        add(.diskImage, ["dmg", "iso", "img", "sparseimage", "sparsebundle", "vmdk", "vdi", "qcow2", "vhd", "vhdx", "utm", "pvm"])
        add(.installer, ["pkg", "mpkg", "xip", "exe", "msi", "ipsw", "apk", "ipa"])
        add(.archive, ["zip", "tar", "gz", "tgz", "bz2", "xz", "rar", "7z", "zst", "tbz", "txz", "lz4"])
        add(.backup, ["bak", "backup", "backupbundle", "sqlbackup", "abbu", "olm", "pst"])
        add(.application, ["app"])
        add(.library, ["photoslibrary", "musiclibrary", "tvlibrary", "fcpbundle", "imovielibrary", "logicx", "xcarchive"])
        add(.document, ["pdf", "key", "pages", "numbers", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "epub"])
        return map
    }()

    public static func classify(_ path: String) -> FileKind {
        byExtension[(path as NSString).pathExtension.lowercased()] ?? .other
    }
}

/// A large file (or package) found on disk.
public struct LargeFile: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var kind: FileKind
    public var allocatedSize: Int64
    public var modificationDate: Date
    /// `true` when the item is a bundle (e.g. `.app`, `.photoslibrary`) measured as a whole.
    public var isPackage: Bool
    public var risk: RiskLevel
    public var fingerprint: FileStat

    public var parentPath: String { (path as NSString).deletingLastPathComponent }

    /// Converts to a `ScanItem` so the cleaning engine can process it.
    public func asScanItem() -> ScanItem {
        ScanItem(path: path, name: name, category: .largeFiles, risk: risk, reason: risk == .protected ? .protectedLocation : .largeFile,
                 allocatedSize: allocatedSize, fileCount: 1, modificationDate: modificationDate, fingerprint: fingerprint)
    }
}

public enum LargeFileEvent: Sendable {
    case progress(filesVisited: Int, bytesVisited: Int64)
    case found([LargeFile])
    case finished(LargeFileReport)
}

public struct LargeFileReport: Sendable {
    public var root: String
    public var threshold: Int64
    public var files: [LargeFile]
    public var filesVisited: Int
    public var inaccessibleCount: Int
    public var inaccessiblePaths: [String]
    public var duration: TimeInterval
}

/// Finds files above a size threshold. Memory use is bounded by the number of
/// results: only files above the threshold are kept.
public struct LargeFileScanner: Sendable {
    public var locations: SystemLocations

    public init(locations: SystemLocations = .current) {
        self.locations = locations
    }

    public func scan(root: String, threshold: Int64, settings: NoriaSettings) -> AsyncThrowingStream<LargeFileEvent, Error> {
        let locations = self.locations
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task.detached(priority: .utility) {
                let start = Date()
                let canonicalRoot = FileSystem.bestEffortCanonicalPath(root)
                let policy = SafetyPolicy(locations: locations, exclusions: settings.exclusions)
                var options = WalkOptions()
                // The Trash is reported by Smart Scan; app containers trigger macOS
                // "access data from other apps" prompts and hold app-managed data.
                var skipped = policy.exclusions + [locations.trash]
                if settings.largeFilesSkipsAppContainers {
                    skipped += [
                        (locations.library as NSString).appendingPathComponent("Containers"),
                        (locations.library as NSString).appendingPathComponent("Group Containers"),
                    ]
                }
                options.skippedPaths = skipped.filter { $0 != canonicalRoot }
                options.descendsIntoPackages = false

                let tracker = InodeTracker()
                var results: [LargeFile] = []
                var pending: [LargeFile] = []
                var visited = 0
                var bytes: Int64 = 0
                var lastReport = Date()
                var inaccessible = 0
                var inaccessiblePaths: [String] = []

                func record(_ path: String, _ stat: FileStat, size: Int64, isPackage: Bool) {
                    guard size >= threshold else { return }
                    let risk: RiskLevel = policy.protectionReason(for: path) != nil || path.isSameOrDescendant(of: locations.library)
                        || !path.isStrictDescendant(of: locations.home) ? .protected : .review
                    let file = LargeFile(path: path, name: (path as NSString).lastPathComponent,
                                         kind: isPackage ? Self.packageKind(path) : FileKind.classify(path),
                                         allocatedSize: size, modificationDate: stat.modificationDate,
                                         isPackage: isPackage, risk: risk, fingerprint: stat)
                    pending.append(file)
                }

                do {
                    let summary = try FileWalker(options: options).walk(root: canonicalRoot, tracker: tracker) { path, stat in
                        if stat.type == .file {
                            visited += 1
                            bytes += stat.allocatedSize
                            if stat.allocatedSize >= threshold, stat.linkCount <= 1 || tracker.firstVisit(stat) {
                                record(path, stat, size: stat.allocatedSize, isPackage: false)
                            }
                        } else if stat.type == .directory, path != canonicalRoot, FileWalker.isPackage(path) {
                            // Measure bundles as a unit instead of listing their internals.
                            var packageOptions = options
                            packageOptions.descendsIntoPackages = true
                            let size = try DirectorySizer(options: packageOptions).measure(path, tracker: tracker)
                            visited += size.fileCount
                            bytes += size.allocatedSize
                            record(path, stat, size: size.allocatedSize, isPackage: true)
                            return .skipDescendants
                        }
                        let now = Date()
                        if now.timeIntervalSince(lastReport) > 0.15 {
                            lastReport = now
                            continuation.yield(.progress(filesVisited: visited, bytesVisited: bytes))
                            if !pending.isEmpty {
                                results += pending
                                continuation.yield(.found(pending))
                                pending.removeAll()
                            }
                        }
                        return .continue
                    }
                    inaccessible = summary.inaccessibleCount
                    inaccessiblePaths = summary.inaccessiblePaths
                    if !pending.isEmpty {
                        results += pending
                        continuation.yield(.found(pending))
                    }
                    continuation.yield(.progress(filesVisited: visited, bytesVisited: bytes))
                    continuation.yield(.finished(LargeFileReport(
                        root: canonicalRoot, threshold: threshold,
                        files: results.sorted { $0.allocatedSize > $1.allocatedSize },
                        filesVisited: visited, inaccessibleCount: inaccessible,
                        inaccessiblePaths: inaccessiblePaths, duration: Date().timeIntervalSince(start))))
                    continuation.finish()
                } catch NoriaError.cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func packageKind(_ path: String) -> FileKind {
        let kind = FileKind.classify(path)
        return kind == .other ? .library : kind
    }
}
