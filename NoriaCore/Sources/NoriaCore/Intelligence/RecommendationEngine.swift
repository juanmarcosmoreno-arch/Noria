import Foundation

/// A rule-based, on-device recommendation. Nothing leaves the Mac.
public struct Recommendation: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// SAFE items of a category.
        case cleanSafeItems(CleanCategory, count: Int)
        /// One old, large installer in Downloads.
        case oldInstaller(name: String, days: Int)
        /// One large third-party cache folder.
        case largeCache(name: String)
        /// Large, old files in Downloads.
        case staleDownloads(count: Int)
        /// Xcode DerivedData; `stale` projects were not built for 30 days.
        case derivedData(projects: Int, stale: Int)
        /// A single log file far bigger than normal: the app writing it may be misbehaving.
        case largeLog(name: String)
        /// The Trash holds a lot of data.
        case emptyTrash
        /// Data of apps that are no longer installed.
        case appLeftovers(count: Int)
        /// Downloadable copies of Mail attachments.
        case mailAttachments(accounts: Int)
    }

    public enum Confidence: String, Sendable, Hashable {
        case high, medium, low
    }

    public enum SuggestedAction: Sendable, Hashable {
        case reviewItems([UUID])
        case emptyTrashInFinder
    }

    public var id: String
    public var kind: Kind
    public var bytes: Int64
    public var confidence: Confidence
    public var risk: RiskLevel
    public var action: SuggestedAction

    /// Usefulness weighted by safety: safe bytes count fully, review bytes half.
    public var score: Double {
        let weight: Double = risk == .safe ? 1.0 : (risk == .review ? 0.5 : 0)
        return Double(bytes) * weight
    }
}

/// Derives recommendations from a scan. Pure function: deterministic and testable.
/// Designed so a local model can later add or re-rank recommendations behind the same type.
public enum RecommendationEngine {
    public static let largeCacheThreshold: Int64 = 1_000_000_000
    public static let largeInstallerThreshold: Int64 = 200_000_000
    public static let minimumWorthwhileBytes: Int64 = 50_000_000
    public static let largeLogThreshold: Int64 = 500_000_000

    public static func recommendations(for report: ScanReport) -> [Recommendation] {
        var result: [Recommendation] = []

        for category in report.categories {
            let safe = category.items.filter { $0.isSelectable && $0.risk == .safe }
            let safeBytes = safe.reduce(0) { $0 + $1.allocatedSize }
            if category.category == .developerCache {
                let derived = safe.filter { $0.reason == .xcodeDerivedData }
                let derivedBytes = derived.reduce(0) { $0 + $1.allocatedSize }
                if derivedBytes >= minimumWorthwhileBytes {
                    let cutoff = report.finishedAt.addingTimeInterval(-30 * 86_400)
                    let stale = derived.filter { ($0.modificationDate ?? .distantPast) < cutoff }.count
                    result.append(Recommendation(id: "derivedData", kind: .derivedData(projects: derived.count, stale: stale), bytes: derivedBytes,
                                                 confidence: .high, risk: .safe, action: .reviewItems(derived.map(\.id))))
                }
                let others = safe.filter { $0.reason != .xcodeDerivedData }
                let otherBytes = others.reduce(0) { $0 + $1.allocatedSize }
                if otherBytes >= minimumWorthwhileBytes {
                    result.append(Recommendation(id: "safe-\(category.category.rawValue)", kind: .cleanSafeItems(category.category, count: others.count),
                                                 bytes: otherBytes, confidence: .high, risk: .safe, action: .reviewItems(others.map(\.id))))
                }
            } else if safeBytes >= minimumWorthwhileBytes {
                result.append(Recommendation(id: "safe-\(category.category.rawValue)", kind: .cleanSafeItems(category.category, count: safe.count),
                                             bytes: safeBytes, confidence: .high, risk: .safe, action: .reviewItems(safe.map(\.id))))
            }

            switch category.category {
            case .userCache:
                for item in category.items where item.risk == .review && item.allocatedSize >= largeCacheThreshold {
                    result.append(Recommendation(id: "cache-\(item.path)", kind: .largeCache(name: item.name), bytes: item.allocatedSize,
                                                 confidence: .medium, risk: .review, action: .reviewItems([item.id])))
                }
            case .downloads:
                var installers: [ScanItem] = []
                for item in category.items where item.allocatedSize >= largeInstallerThreshold {
                    if case .oldInstaller(let days) = item.reason {
                        installers.append(item)
                        result.append(Recommendation(id: "installer-\(item.path)", kind: .oldInstaller(name: item.name, days: days),
                                                     bytes: item.allocatedSize, confidence: .high, risk: .review, action: .reviewItems([item.id])))
                    }
                }
                let stale = category.items.filter { item in
                    if case .oldDownload = item.reason { return item.allocatedSize >= 100_000_000 }
                    return false
                }
                let staleBytes = stale.reduce(0) { $0 + $1.allocatedSize }
                if staleBytes >= minimumWorthwhileBytes {
                    result.append(Recommendation(id: "staleDownloads", kind: .staleDownloads(count: stale.count), bytes: staleBytes,
                                                 confidence: .medium, risk: .review, action: .reviewItems(stale.map(\.id))))
                }
            case .logs:
                for item in category.items where item.allocatedSize >= largeLogThreshold && item.fileCount == 1 {
                    result.append(Recommendation(id: "log-\(item.path)", kind: .largeLog(name: item.name), bytes: item.allocatedSize,
                                                 confidence: .medium, risk: item.risk, action: .reviewItems([item.id])))
                }
            case .appLeftovers:
                let leftovers = category.items.filter(\.isSelectable)
                let bytes = leftovers.reduce(0) { $0 + $1.allocatedSize }
                if bytes >= minimumWorthwhileBytes {
                    result.append(Recommendation(id: "appLeftovers", kind: .appLeftovers(count: leftovers.count), bytes: bytes,
                                                 confidence: .medium, risk: .review, action: .reviewItems(leftovers.map(\.id))))
                }
            case .mail:
                let attachments = category.items.filter { item in
                    if case .mailServerAttachments = item.reason { return true }
                    return false
                }
                let bytes = attachments.reduce(0) { $0 + $1.allocatedSize }
                if bytes >= minimumWorthwhileBytes {
                    let accounts = Set(attachments.compactMap(\.group)).count
                    result.append(Recommendation(id: "mailAttachments", kind: .mailAttachments(accounts: accounts), bytes: bytes,
                                                 confidence: .high, risk: .review, action: .reviewItems(attachments.map(\.id))))
                }
            case .trash:
                if let trash = category.items.first, trash.allocatedSize >= minimumWorthwhileBytes {
                    result.append(Recommendation(id: "trash", kind: .emptyTrash, bytes: trash.allocatedSize,
                                                 confidence: .high, risk: .review, action: .emptyTrashInFinder))
                }
            default:
                break
            }
        }
        return result.sorted { $0.score > $1.score }
    }
}
