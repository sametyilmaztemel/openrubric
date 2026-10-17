import Testing
import Foundation
@testable import OpenRubricApp
import OpenRubricCore

/// App-layer tests that need the macOS app target (UserDefaults-based
/// settings migration). Kept separate from `OpenRubricCoreTests` because
/// `AppSettingsStore` is `internal` to the executable and compiled only on
/// macOS.
///
/// Schema history:
///  - v1: no `flashChannels`.
///  - v2: added `flashChannels`.
///  - v3: added `showAnswerPopup` (and, transitively, `.edgeLight` is now a
///        selectable channel in `flashChannels`).
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

    private enum MigrationTestError: Error {
        case couldNotCreateSuite
    }

    /// A `settings.v1` payload: every field present except `flashChannels`
    /// and `showAnswerPopup` (added in v2 / v3 respectively).
    private static let v1Payload: String = """
    {"apiProvider":"anthropic","baseURL":"https://api.anthropic.com","model":"claude-haiku-5-5","promptMode":"multipleChoice","includeExplanation":true,"cropRadius":180}
    """

    /// A `settings.v2` payload: has `flashChannels` but no `showAnswerPopup`
    /// (added in v3).
    private static let v2Payload: String = """
    {"apiProvider":"anthropic","baseURL":"https://api.anthropic.com","model":"claude-haiku-5-5","promptMode":"multipleChoice","includeExplanation":true,"cropRadius":180,"flashChannels":["capsLockLED","screenFlash"]}
    """

    @Test("a v1 payload is migrated to v3 with flashChannels + showAnswerPopup defaulted")
    func migratesV1ToV3() throws {
        let defaults = try makeDefaults()
        defaults.set(Data(Self.v1Payload.utf8), forKey: "settings.v1")

        let store = AppSettingsStore(defaults: defaults)

        // Migrated values are preserved from the legacy payload ...
        #expect(store.settings.apiProvider == .anthropic)
        #expect(store.settings.baseURL == "https://api.anthropic.com")
        #expect(store.settings.model == "claude-haiku-5-5")
        #expect(store.settings.cropRadius == 180)
        #expect(store.settings.promptMode == .multipleChoice)
        // ... and the two newer fields take their defaults (an upgrade must
        // not silently reset or drop the user's existing configuration).
        #expect(store.settings.flashChannels == [.capsLockLED])
        #expect(store.settings.showAnswerPopup == true)

        // The migration persists under the current key so the next launch
        // reads v3 directly rather than re-migrating.
        #expect(defaults.data(forKey: "settings.v3") != nil)
    }

    @Test("a v2 payload is migrated to v3 with showAnswerPopup defaulted true")
    func migratesV2ToV3() throws {
        let defaults = try makeDefaults()
        defaults.set(Data(Self.v2Payload.utf8), forKey: "settings.v2")

        let store = AppSettingsStore(defaults: defaults)

        // The v2 channel set is preserved ...
        #expect(store.settings.flashChannels == [.capsLockLED, .screenFlash])
        // ... and the new v3 field takes its default.
        #expect(store.settings.showAnswerPopup == true)
        #expect(defaults.data(forKey: "settings.v3") != nil)
    }

    @Test("a missing legacy payload falls back to current defaults, not an error")
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
