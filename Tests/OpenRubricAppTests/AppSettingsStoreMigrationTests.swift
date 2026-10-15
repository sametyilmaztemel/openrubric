import Testing
import Foundation
@testable import OpenRubricApp
import OpenRubricCore

/// App-layer tests that need the macOS app target (UserDefaults-based
/// settings migration). Kept separate from `OpenRubricCoreTests` because
/// `AppSettingsStore` is `internal` to the executable and compiled only on
/// macOS.
@Suite("AppSettingsStore migration")
struct AppSettingsStoreMigrationTests {

    private func makeDefaults() throws -> UserDefaults {
        // A unique suite name per test process avoids cross-test and
        // cross-run contamination of the standard suite.
        let suiteName = "openrubric.migration.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw MigrationTestError.couldNotCreateSuite
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private struct MigrationTestError: Error {
        case couldNotCreateSuite
    }

    /// A `settings.v1` payload: every field present except `flashChannels`
    /// (the field added in v2). Uses the legacy provider raw value so it
    /// decodes under the current enum.
    private static let v1Payload: String = """
    {"apiProvider":"anthropic","baseURL":"https://api.anthropic.com","model":"claude-haiku-5-5","promptMode":"multipleChoice","includeExplanation":true,"cropRadius":180}
    """

    @Test("a v1 payload is migrated to v2 with flashChannels defaulted")
    func migratesV1ToV2() throws {
        let defaults = try makeDefaults()
        defaults.set(Data(Self.v1Payload.utf8), forKey: "settings.v1")

        let store = AppSettingsStore(defaults: defaults)

        // Migrated values are preserved from the legacy payload ...
        #expect(store.settings.apiProvider == .anthropic)
        #expect(store.settings.baseURL == "https://api.anthropic.com")
        #expect(store.settings.model == "claude-haiku-5-5")
        #expect(store.settings.cropRadius == 180)
        #expect(store.settings.promptMode == .multipleChoice)
        // ... and the new field takes its default (an upgrade must not
        // silently reset or drop the user's existing configuration).
        #expect(store.settings.flashChannels == [.capsLockLED])

        // The migration persists under the new key so the next launch reads
        // v2 directly rather than re-migrating.
        #expect(defaults.data(forKey: "settings.v2") != nil)
    }

    @Test("a missing v1 payload falls back to current defaults, not an error")
    func noLegacyFallsBackToDefaults() throws {
        let defaults = try makeDefaults()
        // Nothing written at all.
        let store = AppSettingsStore(defaults: defaults)
        #expect(store.settings == OpenRubricSettings())
    }

    @Test("a corrupted v1 payload is ignored and current defaults are used")
    func corruptedLegacyIgnored() throws {
        let defaults = try makeDefaults()
        defaults.set(Data("this is not valid settings json".utf8), forKey: "settings.v1")
        let store = AppSettingsStore(defaults: defaults)
        #expect(store.settings == OpenRubricSettings())
    }
}
