import Foundation
import OpenRubricCore

/// Persists `OpenRubricSettings` (non-secret values) in UserDefaults and
/// the API key in the Keychain. UserDefaults is the only place provider,
/// base URL, model, prompt mode, crop radius, popup, and flash channels are
/// ever written.
///
/// The defaults key is versioned (`settings.v1` -> `v2` -> `v3`). On the
/// first launch after a schema bump the store reads the previous key and
/// migrates the user's values under the new key (new fields take their
/// defaults), so an upgrade never silently resets the configuration.
final class AppSettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults

    private static let defaultsKey = "settings.v3"
    private static let legacyKey = "settings.v2"
    private static let legacyKeyV1 = "settings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = Self.load(from: defaults)
    }

    private static func load(from defaults: UserDefaults) -> OpenRubricSettings {
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(OpenRubricSettings.self, from: data) {
            return decoded
        }
        // One-time migration from the previous schema (settings.v2: has
        // flashChannels, no showAnswerPopup).
        if let legacy = defaults.data(forKey: legacyKey), let migrated = migrate(fromV2: legacy) {
            if let data = try? JSONEncoder().encode(migrated) {
                defaults.set(data, forKey: defaultsKey)
            }
            return migrated
        }
        // Older migration from settings.v1 (no flashChannels, no showAnswerPopup).
        if let legacy = defaults.data(forKey: legacyKeyV1), let migrated = migrate(fromV1: legacy) {
            if let data = try? JSONEncoder().encode(migrated) {
                defaults.set(data, forKey: defaultsKey)
            }
            return migrated
        }
        return OpenRubricSettings()
    }

    /// Decodes a `settings.v2` payload (no `showAnswerPopup` field) into the
    /// current struct, letting the new field fall back to its default (true,
    /// so an upgrade never hides the popup the user was seeing).
    private static func migrate(fromV2 data: Data) -> OpenRubricSettings? {
        struct V2: Decodable {
            let apiProvider: ApiProvider?
            let baseURL: String?
            let model: String?
            let promptMode: PromptMode?
            let includeExplanation: Bool?
            let cropRadius: CGFloat?
            let flashChannels: Set<FlashChannel>?
        }
        guard let old = try? JSONDecoder().decode(V2.self, from: data) else { return nil }
        guard old.apiProvider != nil || old.baseURL != nil || old.model != nil
                || old.promptMode != nil || old.includeExplanation != nil
                || old.cropRadius != nil || old.flashChannels != nil else { return nil }
        return OpenRubricSettings(
            apiProvider: old.apiProvider ?? .anthropic,
            baseURL: old.baseURL,
            model: old.model,
            promptMode: old.promptMode ?? .multipleChoice,
            includeExplanation: old.includeExplanation ?? true,
            cropRadius: old.cropRadius ?? 260,
            showAnswerPopup: true,
            flashChannels: old.flashChannels ?? [.capsLockLED]
        )
    }

    /// Decodes a `settings.v1` payload (no `flashChannels`, no
    /// `showAnswerPopup`) into the current struct, letting both new fields
    /// fall back to their defaults.
    private static func migrate(fromV1 data: Data) -> OpenRubricSettings? {
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
            cropRadius: old.cropRadius ?? 260,
            showAnswerPopup: true
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
