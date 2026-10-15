import Foundation
import OpenRubricCore

/// Persists `OpenRubricSettings` (non-secret values) in UserDefaults and
/// the API key in the Keychain. UserDefaults is the only place provider,
/// base URL, model, prompt mode, crop radius, and flash channels are ever
/// written.
///
/// The defaults key is versioned (`settings.v1` -> `settings.v2`). On the
/// first launch after a schema bump the store reads the previous key,
/// migrates the user's values under the new key (new fields take their
/// defaults), so an upgrade never silently resets the configuration.
final class AppSettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults

    private static let defaultsKey = "settings.v2"
    private static let legacyKey = "settings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = Self.load(from: defaults)
    }

    private static func load(from defaults: UserDefaults) -> OpenRubricSettings {
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(OpenRubricSettings.self, from: data) {
            return decoded
        }
        // One-time migration from the previous schema.
        if let legacy = defaults.data(forKey: legacyKey), let migrated = migrate(legacy: legacy) {
            if let data = try? JSONEncoder().encode(migrated) {
                defaults.set(data, forKey: defaultsKey)
            }
            return migrated
        }
        return OpenRubricSettings()
    }

    /// Decodes a `settings.v1` payload (no `flashChannels` field) into the
    /// current struct, letting the new field fall back to its default.
    private static func migrate(legacy data: Data) -> OpenRubricSettings? {
        // All-optional mirror of the v1 schema; the payload only needs to
        // be a JSON object with at least one known field to count as legacy
        // settings worth preserving.
        struct Legacy: Decodable {
            let apiProvider: ApiProvider?
            let baseURL: String?
            let model: String?
            let promptMode: PromptMode?
            let includeExplanation: Bool?
            let cropRadius: CGFloat?
        }
        guard let old = try? JSONDecoder().decode(Legacy.self, from: data) else { return nil }
        guard old.apiProvider != nil || old.baseURL != nil || old.model != nil
                || old.promptMode != nil || old.includeExplanation != nil
                || old.cropRadius != nil else { return nil }
        return OpenRubricSettings(
            apiProvider: old.apiProvider ?? .anthropic,
            baseURL: old.baseURL,
            model: old.model,
            promptMode: old.promptMode ?? .multipleChoice,
            includeExplanation: old.includeExplanation ?? true,
            cropRadius: old.cropRadius ?? 260
        )
    }

    private(set) var settings: OpenRubricSettings

    /// The stored API key; `nil` when the user has not set one.
    var apiKey: String? {
        KeychainStore.load()
    }

    /// Applies a new settings value and persists both halves
    /// (UserDefaults + Keychain).
    func apply(_ new: OpenRubricSettings, apiKey: String?) throws {
        settings = new
        let data = try JSONEncoder().encode(new)
        defaults.set(data, forKey: Self.defaultsKey)
        try KeychainStore.save(apiKey ?? "")
    }

    /// Sets only the key (Settings window "Save" when other fields were
    /// unchanged) - still goes through the same Keychain path.
    func apply(key apiKey: String?) throws {
        try KeychainStore.save(apiKey ?? "")
    }
}
