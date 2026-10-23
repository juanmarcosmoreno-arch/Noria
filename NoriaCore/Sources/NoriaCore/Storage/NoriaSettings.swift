import Foundation

/// How selected items are removed.
public enum RemovalMethod: String, Codable, Sendable, CaseIterable {
    /// Move to the user's Trash (recoverable from Finder). Default.
    case moveToTrash
    /// Delete immediately. Not recoverable.
    case deletePermanently
}

/// Interface language. `.system` follows macOS.
public enum AppLanguage: String, Codable, Sendable, CaseIterable {
    case system
    case english = "en"
    case spanish = "es"
}

/// User preferences shared by the app and the engines.
public struct NoriaSettings: Codable, Sendable, Equatable {
    public var removalMethod: RemovalMethod = .moveToTrash
    /// Absolute paths never scanned or removed.
    public var exclusions: [String] = []
    public var enabledCategories: Set<CleanCategory> = Set(CleanCategory.smartScanCategories)
    public var logsMinimumAgeDays = 7
    public var temporaryMinimumAgeDays = 7
    public var downloadsMinimumAgeDays = 30
    public var largeFileThreshold: Int64 = 500 * 1_000_000
    public var largeFilesSkipsAppContainers = true
    public var language: AppLanguage = .system

    public init() {}

    // Decoding tolerates missing keys so new settings never reset old ones.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = NoriaSettings()
        removalMethod = try container.decodeIfPresent(RemovalMethod.self, forKey: .removalMethod) ?? defaults.removalMethod
        exclusions = try container.decodeIfPresent([String].self, forKey: .exclusions) ?? defaults.exclusions
        enabledCategories = try container.decodeIfPresent(Set<CleanCategory>.self, forKey: .enabledCategories) ?? defaults.enabledCategories
        logsMinimumAgeDays = try container.decodeIfPresent(Int.self, forKey: .logsMinimumAgeDays) ?? defaults.logsMinimumAgeDays
        temporaryMinimumAgeDays = try container.decodeIfPresent(Int.self, forKey: .temporaryMinimumAgeDays) ?? defaults.temporaryMinimumAgeDays
        downloadsMinimumAgeDays = try container.decodeIfPresent(Int.self, forKey: .downloadsMinimumAgeDays) ?? defaults.downloadsMinimumAgeDays
        largeFileThreshold = try container.decodeIfPresent(Int64.self, forKey: .largeFileThreshold) ?? defaults.largeFileThreshold
        largeFilesSkipsAppContainers = try container.decodeIfPresent(Bool.self, forKey: .largeFilesSkipsAppContainers) ?? defaults.largeFilesSkipsAppContainers
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? defaults.language
    }
}

/// Persists `NoriaSettings`.
public protocol SettingsStore: Sendable {
    func load() -> NoriaSettings
    func save(_ settings: NoriaSettings)
}

/// Stores settings as one JSON blob in `UserDefaults`.
public struct UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "noria.settings.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> NoriaSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(NoriaSettings.self, from: data) else {
            return NoriaSettings()
        }
        return settings
    }

    public func save(_ settings: NoriaSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}
