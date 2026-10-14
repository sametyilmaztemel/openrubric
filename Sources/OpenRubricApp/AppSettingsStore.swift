import Foundation
import OpenRubricCore

/// Persists `OpenRubricSettings` (non-secret values) in UserDefaults and
/// the API key in the Keychain. UserDefaults is the only place provider,
/// base URL, model, prompt mode, crop radius, and flash channels are ever
/// written.
///
/// The defaults key is versioned (`settings.v1` -> `settings.v2`): a
/// settings schema change that adds a field migrates by falling back to
/// defaults once, so a new field never breaks decode of old payloads.
final class AppSettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults

    private static let defaultsKey = "settings.v2"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(OpenRubricSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = OpenRubricSettings()
        }
    }

    private(set) var settings: OpenRubricSettings

    /// The stored API key; `nil` when the user has not set one.
    var apiKey: String {
        KeychainStore.load()
    }

    /// Applies a new settings value and persists both halves
    /// (UserDefaults + Keychain).
    func apply(_ new: OpenRubricSettings, apiKey: String throws {
        settings = new
        let data = try JSONEncoder().encode(new)
        defaults.set(data, forKey: Self.defaultsKey)
        try KeychainStore.save(apiKey ?? "")
    }

    /// Sets only the key (Settings window "Save" when other fields were
    /// unchanged) - still goes through the same Keychain path.
    func apply(key apiKey: String throws {
        try KeychainStore.save(apiKey ?? "")
    }
}
