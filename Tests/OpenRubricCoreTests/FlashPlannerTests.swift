import Foundation
import Testing
@testable import OpenRubricCore

@Suite("FlashPlanner")
struct FlashPlannerTests {
    @Test("letter maps to 1-based number")
    func letterNumbers() {
        #expect(FlashPlanner.letterNumber("A") == 1)
        #expect(FlashPlanner.letterNumber("b") == 2)
        #expect(FlashPlanner.letterNumber("C") == 3)
        #expect(FlashPlanner.letterNumber("D") == 4)
        #expect(FlashPlanner.letterNumber("Z") == 26)
    }

    @Test("non-letters and nil map to nil")
    func nonLetters() {
        #expect(FlashPlanner.letterNumber(nil) == nil)
        // Multi-letter values are handled by the parser (which decides
        // whether the text is a letter at all); the mapper only takes
        // the first character, so "B1" is validly B -> 2.
        #expect(FlashPlanner.letterNumber("1") == nil)
        #expect(FlashPlanner.letterNumber("") == nil)
        #expect(FlashPlanner.letterNumber("9") == nil)
        #expect(FlashPlanner.letterNumber(" ") == nil)
    }

    @Test("plan is restricted to enabled channels, in stable order")
    func planRestrictsChannels() {
        let answer = ParsedAnswer(
            letter: "C", text: "C",
            confidence: .high, explanation: nil
        )
        let plan = FlashPlanner.plan(
            for: answer,
            enabled: Set(FlashChannel.allCases)
        )
        #expect(plan?.count == 3)
        #expect(plan?.channels == [
            .capsLockLED, .screenFlash, .keyboardBacklight, .cameraLED
        ])
    }

    @Test("no plan when nothing is enabled")
    func emptyEnabled() {
        let answer = ParsedAnswer(
            letter: "A", text: "A",
            confidence: .high, explanation: nil
        )
        #expect(FlashPlanner.plan(for: answer, enabled: []) == nil)
    }

    @Test("short answers have no letter, so no plan")
    func shortAnswerNoPlan() {
        let answer = ParsedAnswer(
            letter: nil, text: "Photosynthesis converts light to chemical energy.",
            confidence: .high, explanation: nil
        )
        #expect(
            FlashPlanner.plan(
                for: answer,
                enabled: Set(FlashChannel.allCases)
            ) == nil
        )
    }

    @Test("settings round-trip keeps flash channels")
    func settingsRoundTrip() {
        let s = OpenRubricSettings(
            flashChannels: [.screenFlash, .capsLockLED]
        )
        let data = try! JSONEncoder().encode(s)
        let back = try! JSONDecoder().decode(OpenRubricSettings.self, from: data)
        #expect(back.flashChannels == s.flashChannels)
    }
}
