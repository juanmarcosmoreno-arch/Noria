import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// Whether a Mail account keeps its messages on a server.
public enum MailAccountKind: String, Sendable {
    /// IMAP, Exchange, iCloud, Google…: attachments stay on the server and Mail
    /// downloads them again when a message is opened.
    case server
    /// POP: messages live only on this Mac once downloaded.
    case local
    /// Could not be determined. Treated like `local` (never removable).
    case unknown
}

public struct MailAccountInfo: Sendable, Equatable {
    public var kind: MailAccountKind
    public var displayName: String?

    public init(kind: MailAccountKind, displayName: String? = nil) {
        self.kind = kind
        self.displayName = displayName
    }
}

/// Maps the account folders in `~/Library/Mail/V*/` to account types.
public protocol MailAccountResolving: Sendable {
    func account(for identifier: String) -> MailAccountInfo
}

/// Fixed answers; used by tests and as the "nothing known" fallback.
public struct StaticMailAccountResolver: MailAccountResolving {
    public var accounts: [String: MailAccountInfo]

    public init(_ accounts: [String: MailAccountInfo] = [:]) {
        self.accounts = accounts
    }

    public func account(for identifier: String) -> MailAccountInfo {
        accounts[identifier.uppercased()] ?? accounts[identifier] ?? MailAccountInfo(kind: .unknown)
    }
}

/// Reads account types from the macOS accounts database (read-only).
/// Requires Full Disk Access, like Mail's own folder. Any failure leaves the
/// type `unknown`, which keeps the attachments protected.
public struct AccountsDatabaseResolver: MailAccountResolving {
    private let resolver: StaticMailAccountResolver

    public init(databasePath: String) {
        resolver = StaticMailAccountResolver(Self.load(databasePath))
    }

    public func account(for identifier: String) -> MailAccountInfo {
        resolver.account(for: identifier)
    }

    static func kind(forAccountType type: String) -> MailAccountKind {
        let type = type.lowercased()
        if type.contains("pop") { return .local }
        let serverTypes = ["imap", "exchange", "google", "gmail", "yahoo", "aol", "outlook", "hotmail"]
        return serverTypes.contains { type.contains($0) } ? .server : .unknown
    }

    static func load(_ path: String) -> [String: MailAccountInfo] {
        #if canImport(SQLite3)
        var database: OpaquePointer?
        let uri = "file:" + path + "?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return [:]
        }
        defer { sqlite3_close(database) }
        let query = """
            SELECT a.ZIDENTIFIER, a.ZACCOUNTDESCRIPTION, a.ZUSERNAME, t.ZIDENTIFIER
            FROM ZACCOUNT a LEFT JOIN ZACCOUNTTYPE t ON a.ZACCOUNTTYPE = t.Z_PK
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        func text(_ column: Int32) -> String? {
            guard let value = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: value)
        }
        var result: [String: MailAccountInfo] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let identifier = text(0) else { continue }
            let name = text(2).flatMap { $0.isEmpty ? nil : $0 } ?? text(1)
            result[identifier.uppercased()] = MailAccountInfo(kind: kind(forAccountType: text(3) ?? ""), displayName: name)
        }
        return result
        #else
        return [:]
        #endif
    }
}

/// Disk usage of one Mail account folder.
public struct MailAccountUsage: Sendable, Identifiable, Equatable {
    public var id: String { path }
    public var path: String
    public var identifier: String
    public var displayName: String
    public var kind: MailAccountKind
    /// Everything stored for the account (messages, attachments, indexes).
    public var totalSize: Int64
    /// Of which: local copies of attachments.
    public var attachmentsSize: Int64
}

public struct MailUsageReport: Sendable {
    public var accounts: [MailAccountUsage]
    public var mailDownloadsSize: Int64
    /// `false` when `~/Library/Mail` could not be read (Full Disk Access missing).
    public var mailFolderReadable: Bool

    public var totalSize: Int64 { accounts.reduce(mailDownloadsSize) { $0 + $1.totalSize } }
}

/// Mail attachments and Mail Downloads.
///
/// * **Mail Downloads** — copies Mail creates when you open an attachment: SAFE.
/// * **Attachments of server accounts** — local copies of attachments that remain
///   on the server; Mail downloads them again when needed: REVIEW.
/// * **Attachments of POP/local/unknown accounts** — may be the only copy: PROTECTED.
///
/// Messages themselves are never touched. Mail must be quit before cleaning.
public struct MailRule: CleaningRule {
    public let category = CleanCategory.mail
    public static let mailBundleIdentifier = "com.apple.mail"
    /// Mail's folder for "On My Mac" mailboxes.
    static let localMailboxesFolder = "Mailboxes"

    public init() {}

    public func scan(_ context: ScanContext) throws -> RuleOutput {
        var output = RuleOutput()
        let locations = context.locations
        var found = false

        // Mail Downloads.
        if FileSystem.stat(locations.mailDownloads)?.type == .directory {
            found = true
            if let entries = children(of: locations.mailDownloads, context: context, output: &output) {
                for (path, stat) in entries where !(path as NSString).lastPathComponent.hasPrefix(".") {
                    try checkCancellation()
                    if var item = try context.makeItem(path: path, stat: stat, category: category, risk: .safe,
                                                       reason: .mailDownloads, ownerName: "Mail", result: &output) {
                        item.requiresQuitting = Self.mailBundleIdentifier
                        item.group = "Mail Downloads"
                        output.items.append(item)
                    }
                }
            }
        }

        // Attachments inside ~/Library/Mail/V*/<account>/.
        guard FileSystem.stat(locations.mail)?.type == .directory else {
            output.locationExists = found
            return output
        }
        found = true
        let versions: [DirectoryEntry]
        do {
            versions = try FileSystem.directoryEntries(locations.mail)
        } catch {
            output.recordInaccessible(locations.mail) // Full Disk Access not granted.
            output.locationExists = found
            return output
        }
        for version in versions where Self.isMailVersionFolder(version.name) {
            guard let accounts = try? FileSystem.directoryEntries(version.path) else {
                output.recordInaccessible(version.path)
                continue
            }
            for account in accounts where FileSystem.stat(account.path)?.type == .directory && account.name != "MailData" {
                try checkCancellation()
                let info: MailAccountInfo = account.name == Self.localMailboxesFolder
                    ? MailAccountInfo(kind: .local, displayName: "On My Mac")
                    : context.mailAccounts.account(for: account.name)
                let label = info.displayName ?? account.name
                for (path, stat) in try attachmentFolders(in: account.path, output: &output) {
                    try checkCancellation()
                    let removable = info.kind == .server
                    if var item = try context.makeItem(
                        path: path, stat: stat, category: category,
                        risk: removable ? .review : .protected,
                        reason: removable ? .mailServerAttachments(account: label) : .mailLocalAttachments(account: label),
                        action: removable ? .remove : .informational,
                        ownerName: "Mail", result: &output
                    ) {
                        item.name = Self.mailboxName(for: path)
                        item.requiresQuitting = Self.mailBundleIdentifier
                        item.group = label
                        item.bundleIdentifier = nil
                        output.items.append(item)
                    }
                }
            }
        }
        output.locationExists = found
        return output
    }

    /// Per-account sizes for the Mail screen. Read-only.
    public static func usage(_ context: ScanContext) throws -> MailUsageReport {
        let locations = context.locations
        var downloads: Int64 = 0
        if FileSystem.stat(locations.mailDownloads)?.type == .directory {
            downloads = (try? DirectorySizer().measure(locations.mailDownloads, tracker: InodeTracker()).allocatedSize) ?? 0
        }
        guard let versions = try? FileSystem.directoryEntries(locations.mail) else {
            return MailUsageReport(accounts: [], mailDownloadsSize: downloads, mailFolderReadable: false)
        }
        var accounts: [MailAccountUsage] = []
        for version in versions where isMailVersionFolder(version.name) {
            guard let entries = try? FileSystem.directoryEntries(version.path) else { continue }
            for account in entries where account.name != "MailData" && FileSystem.stat(account.path)?.type == .directory {
                if Task.isCancelled { throw NoriaError.cancelled }
                let info: MailAccountInfo = account.name == localMailboxesFolder
                    ? MailAccountInfo(kind: .local, displayName: "On My Mac")
                    : context.mailAccounts.account(for: account.name)
                let tracker = InodeTracker()
                var attachments: Int64 = 0
                var total: Int64 = 0
                let summary = try FileWalker().walk(root: account.path, tracker: tracker) { path, stat in
                    if stat.type == .directory, (path as NSString).lastPathComponent == "Attachments" {
                        attachments += (try? DirectorySizer().measure(path, tracker: InodeTracker()).allocatedSize) ?? 0
                    }
                    return .continue
                }
                total = summary.allocatedSize
                accounts.append(MailAccountUsage(path: account.path, identifier: account.name,
                                                 displayName: info.displayName ?? account.name, kind: info.kind,
                                                 totalSize: total, attachmentsSize: min(attachments, total)))
            }
        }
        return MailUsageReport(accounts: accounts.sorted { $0.totalSize > $1.totalSize },
                               mailDownloadsSize: downloads, mailFolderReadable: true)
    }

    static func isMailVersionFolder(_ name: String) -> Bool {
        name.count >= 2 && name.first == "V" && name.dropFirst().allSatisfy(\.isNumber)
    }

    /// `Attachments` folders inside an account, without descending into message files.
    func attachmentFolders(in accountPath: String, output: inout RuleOutput) throws -> [(String, FileStat)] {
        var found: [(String, FileStat)] = []
        let summary = try FileWalker().walk(root: accountPath) { path, stat in
            guard stat.type == .directory, path != accountPath else { return .continue }
            let name = (path as NSString).lastPathComponent
            if name == "Attachments" {
                found.append((path, stat))
                return .skipDescendants
            }
            return name == "Messages" ? .skipDescendants : .continue
        }
        output.recordInaccessible(summary)
        return found
    }

    /// "INBOX" for `.../INBOX.mbox/<id>/Data/Attachments`.
    static func mailboxName(for attachmentsPath: String) -> String {
        let mailboxes = attachmentsPath.split(separator: "/").filter { $0.hasSuffix(".mbox") }
        let names = mailboxes.map { String($0.dropLast(5)) }
        return names.isEmpty ? "Attachments" : names.joined(separator: " › ")
    }
}
