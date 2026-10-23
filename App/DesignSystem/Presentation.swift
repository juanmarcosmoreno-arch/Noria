import NoriaCore
import SwiftUI

// Localized presentation of NoriaCore values. NoriaCore returns structured data
// (enums with parameters); every user-facing sentence lives here and in
// Localizable.xcstrings.

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func memory(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func duration(_ interval: TimeInterval) -> String {
        Duration.seconds(interval.rounded()).formatted(.time(pattern: interval >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number)
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    /// "9 months", "2 years"… for recommendation sentences.
    static func age(days: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        if days >= 365 {
            formatter.allowedUnits = [.year]
        } else if days >= 60 {
            formatter.allowedUnits = [.month]
        } else {
            formatter.allowedUnits = [.day]
        }
        return formatter.string(from: TimeInterval(days) * 86_400) ?? "\(days)"
    }
}

extension CleanCategory {
    var title: String {
        switch self {
        case .userCache: return String(localized: "User Cache")
        case .logs: return String(localized: "Logs")
        case .temporaryFiles: return String(localized: "Temporary Files")
        case .developerCache: return String(localized: "Developer Cache")
        case .downloads: return String(localized: "Downloads")
        case .trash: return String(localized: "Trash")
        case .largeFiles: return String(localized: "Large Files")
        }
    }

    var summary: String {
        switch self {
        case .userCache: return String(localized: "Data apps keep to load faster. Most of it is rebuilt automatically.")
        case .logs: return String(localized: "Old activity logs and diagnostic reports.")
        case .temporaryFiles: return String(localized: "Old items left in your temporary folder.")
        case .developerCache: return String(localized: "Build products and package-manager caches.")
        case .downloads: return String(localized: "Old installers, archives and forgotten downloads.")
        case .trash: return String(localized: "Items already in the Trash.")
        case .largeFiles: return String(localized: "Large files selected in Large Files.")
        }
    }

    var systemImage: String {
        switch self {
        case .userCache: return "shippingbox"
        case .logs: return "doc.text.magnifyingglass"
        case .temporaryFiles: return "clock.arrow.circlepath"
        case .developerCache: return "hammer"
        case .downloads: return "arrow.down.circle"
        case .trash: return "trash"
        case .largeFiles: return "doc.richtext"
        }
    }

    /// Category icons share the brand's wood accent, as in the brand board.
    var tint: Color { NoriaColor.accent }
}

extension RiskLevel {
    var title: String {
        switch self {
        case .safe: return String(localized: "SAFE")
        case .review: return String(localized: "REVIEW")
        case .protected: return String(localized: "PROTECTED")
        }
    }

    var explanation: String {
        switch self {
        case .safe: return String(localized: "Matched a verified rule: the content is rebuilt automatically or is disposable.")
        case .review: return String(localized: "Probably not needed, but only you can decide. Check it before cleaning.")
        case .protected: return String(localized: "Noria never removes this. It is shown for transparency only.")
        }
    }

    var color: Color {
        switch self {
        case .safe: return NoriaColor.safe
        case .review: return NoriaColor.review
        case .protected: return NoriaColor.protected
        }
    }
}

extension ItemReason {
    /// Why Noria suggests cleaning the item.
    var explanation: String {
        switch self {
        case .knownRegenerableCache(let tool):
            return String(localized: "Cache of \(tool). It is rebuilt automatically when needed. Quit the app before cleaning.")
        case .thirdPartyCache:
            return String(localized: "Cache folder of a third-party app. Usually rebuilt automatically, but the app may need to download data again. Quit the app before cleaning.")
        case .systemCache:
            return String(localized: "Cache managed by macOS or an Apple app. Noria does not touch it.")
        case .oldLog(let days):
            return String(localized: "Log not modified for \(Format.age(days: days)). Apps write new logs as needed.")
        case .oldTemporary(let days):
            return String(localized: "Temporary item not modified for \(Format.age(days: days)). macOS also purges these over time.")
        case .oldInstaller(let days):
            return String(localized: "Installer downloaded \(Format.age(days: days)) ago. If the app is already installed, you probably don't need it.")
        case .oldArchive(let days):
            return String(localized: "Compressed archive not modified for \(Format.age(days: days)). Check you have extracted what you need.")
        case .oldDownload(let days):
            return String(localized: "Download not modified for \(Format.age(days: days)).")
        case .xcodeDerivedData:
            return String(localized: "Xcode build products. Xcode rebuilds them; the next build will take longer. Quit Xcode first.")
        case .xcodeArchive:
            return String(localized: "Xcode archive. Needed to symbolicate crash reports or re-export this build. Keep archives of released versions.")
        case .xcodeDeviceSupport:
            return String(localized: "Debug symbols for a device OS version. Xcode copies them again when that device is connected.")
        case .packageManagerCache(let tool, let command):
            if let command {
                return String(localized: "Download cache of \(tool); packages are downloaded again when needed. Official equivalent: \(command)")
            }
            return String(localized: "Download cache of \(tool); packages are downloaded again when needed.")
        case .trashContents:
            return String(localized: "Space used by the Trash. Empty it from Finder to free this space.")
        case .largeFile:
            return String(localized: "Large file in your home folder.")
        case .protectedLocation:
            return String(localized: "Inside a location managed by macOS or another app. Noria does not modify it.")
        }
    }
}

extension Recommendation {
    var title: String {
        switch kind {
        case .cleanSafeItems(let category, let count):
            return String(localized: "\(Format.count(count)) safe items in \(category.title)")
        case .oldInstaller(let name, let days):
            return String(localized: "Found a \(Format.bytes(bytes)) installer downloaded \(Format.age(days: days)) ago: \(name)")
        case .largeCache(let name):
            return String(localized: "The cache folder “\(name)” takes \(Format.bytes(bytes)).")
        case .staleDownloads(let count):
            return String(localized: "Downloads holds \(Format.count(count)) large items not modified for over a year.")
        case .derivedData(let projects):
            return String(localized: "Xcode DerivedData for \(Format.count(projects)) projects")
        case .emptyTrash:
            return String(localized: "The Trash holds \(Format.bytes(bytes)).")
        }
    }

    var detail: String {
        switch kind {
        case .cleanSafeItems:
            return String(localized: "Matched verified rules. Rebuilt automatically when needed.")
        case .oldInstaller:
            return String(localized: "If the app is installed and up to date, the installer is no longer needed.")
        case .largeCache:
            return String(localized: "Check that the related app is closed before cleaning it.")
        case .staleDownloads:
            return String(localized: "Review them and keep what you still need.")
        case .derivedData:
            return String(localized: "Xcode rebuilds them; the next build of each project will be slower.")
        case .emptyTrash:
            return String(localized: "Empty the Trash from Finder to free this space.")
        }
    }

    var confidenceTitle: String {
        switch confidence {
        case .high: return String(localized: "High confidence")
        case .medium: return String(localized: "Medium confidence")
        case .low: return String(localized: "Low confidence")
        }
    }
}

extension FileKind {
    var title: String {
        switch self {
        case .video: return String(localized: "Video")
        case .audio: return String(localized: "Audio")
        case .image: return String(localized: "Image")
        case .diskImage: return String(localized: "Disk Image")
        case .installer: return String(localized: "Installer")
        case .archive: return String(localized: "Archive")
        case .backup: return String(localized: "Backup")
        case .application: return String(localized: "Application")
        case .library: return String(localized: "Library / Bundle")
        case .document: return String(localized: "Document")
        case .other: return String(localized: "Other")
        }
    }

    var systemImage: String {
        switch self {
        case .video: return "film"
        case .audio: return "waveform"
        case .image: return "photo"
        case .diskImage: return "opticaldiscdrive"
        case .installer: return "shippingbox"
        case .archive: return "doc.zipper"
        case .backup: return "externaldrive.badge.timemachine"
        case .application: return "app"
        case .library: return "books.vertical"
        case .document: return "doc.text"
        case .other: return "doc"
        }
    }
}

extension ItemOutcome {
    var statusTitle: String {
        switch status {
        case .removed: return String(localized: "Removed")
        case .skipped: return String(localized: "Skipped")
        case .failed: return String(localized: "Failed")
        }
    }
}

extension RemovalMethod {
    var title: String {
        switch self {
        case .moveToTrash: return String(localized: "Move to Trash (recommended)")
        case .deletePermanently: return String(localized: "Delete immediately")
        }
    }
}
