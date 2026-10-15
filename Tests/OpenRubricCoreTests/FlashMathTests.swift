import Testing
import Foundation
@testable import OpenRubricCore

@Suite("FlashMath")
struct FlashMathTests {

    @Suite("clampedBlinkCount")
    struct Blink {
        @Test("count below max is kept")
        func below() {
            #expect(FlashMath.clampedBlinkCount(3, maxValue: 26) == 3)
        }

        @Test("Z (26) is clamped down to a small element max")
        func zClamped() {
            // Many LED elements report a max of 0, 1, or 2 — a 26 would be
            // out of range; clamp to the max.
            #expect(FlashMath.clampedBlinkCount(26, maxValue: 2) == 2)
        }

        @Test("negative count floors to 0")
        func negative() {
            #expect(FlashMath.clampedBlinkCount(-5, maxValue: 26) == 0)
        }

        @Test("max of 0 clamps everything to 0")
        func zeroMax() {
            #expect(FlashMath.clampedBlinkCount(1, maxValue: 0) == 0)
            #expect(FlashMath.clampedBlinkCount(26, maxValue: 0) == 0)
        }

        @Test("count above a large max is clamped")
        func aboveLarge() {
            #expect(FlashMath.clampedBlinkCount(40, maxValue: 26) == 26)
        }
    }

    @Suite("screen brightness")
    struct Screen {
        @Test("dim level is original * fraction")
        func dim() {
            let dimmed = FlashMath.screenDimLevel(original: 1.0, dimFraction: 0.15)
            #expect(abs(dimmed - 0.15) < 0.001)
        }

        @Test("dim level is never negative for a positive original")
        func notNegative() {
            #expect(FlashMath.screenDimLevel(original: 0.8, dimFraction: 0.15) > 0)
        }

        @Test("screen at 0 is not flashable")
        func off() {
            #expect(!FlashMath.screenFlashEnabled(original: 0))
            #expect(FlashMath.screenFlashEnabled(original: 0.2))
        }
    }

    @Suite("backlight candidate selection")
    struct Candidates {
        @Test("candidate list is non-empty and in documented order")
        func order() {
            #expect(!FlashMath.backlightCandidates.isEmpty)
            // Apple vendor page (0xFF00) entries come first (built-ins), then
            // the Consumer / GenericDesktop third-party slots.
            #expect(FlashMath.backlightCandidates[0].page == 0xFF00)
            #expect(FlashMath.backlightCandidates[0].usage == 0x0F)
        }

        @Test("first hit wins; no match is nil")
        func firstHit() {
            #expect(FlashMath.firstMatchingCandidateIndex([0, 0, 2, 1]) == 2)
            #expect(FlashMath.firstMatchingCandidateIndex([1, 5, 0]) == 0)
            #expect(FlashMath.firstMatchingCandidateIndex([0, 0, 0, 0, 0]) == nil)
            #expect(FlashMath.firstMatchingCandidateIndex([]) == nil)
        }

        @Test("a zero count never wins even if later counts exist")
        func zeroNeverWins() {
            #expect(FlashMath.firstMatchingCandidateIndex([0, 3, 0]) == 1)
        }
    }

    @Suite("backlight pulse")
    struct Pulse {
        @Test("backlight on: dim to 0, restore to original")
        func on() {
            let p = FlashMath.backlightPulse(original: 120, maxValue: 255, pulseLevel: 60)
            #expect(p.set == 0)
            #expect(p.restore == 120)
        }

        @Test("backlight on above max: restore clamps to max")
        func onClamped() {
            let p = FlashMath.backlightPulse(original: 999, maxValue: 255, pulseLevel: 60)
            #expect(p.set == 0)
            #expect(p.restore == 255)
        }

        @Test("backlight off: blip up to pulse level, restore to 0")
        func off() {
            let p = FlashMath.backlightPulse(original: 0, maxValue: 255, pulseLevel: 60)
            #expect(p.set == 60)
            #expect(p.restore == 0)
        }

        @Test("backlight off with no headroom (max 0) is a no-op")
        func offNoHeadroom() {
            let p = FlashMath.backlightPulse(original: 0, maxValue: 0, pulseLevel: 60)
            #expect(p.set == 0)
            #expect(p.restore == 0)
            #expect(!FlashMath.backlightPulseVisible(original: 0, maxValue: 0, pulseLevel: 60))
        }

        @Test("visibility: on and off-with-headroom are visible; off-without is not")
        func visible() {
            #expect(FlashMath.backlightPulseVisible(original: 120, maxValue: 255, pulseLevel: 60))
            #expect(FlashMath.backlightPulseVisible(original: 0, maxValue: 255, pulseLevel: 60))
            #expect(!FlashMath.backlightPulseVisible(original: 0, maxValue: 0, pulseLevel: 60))
            #expect(!FlashMath.backlightPulseVisible(original: 0, maxValue: 255, pulseLevel: 0))
        }
    }

    @Suite("backlight pulse level")
    struct PulseLevel {
        @Test("pulse level is a quarter of the max, min 1 when there is headroom")
        func quarter() {
            #expect(FlashMath.backlightPulseLevel(maxValue: 255) == 63)   // 0.25 * 255 = 63.75 -> 63
            #expect(FlashMath.backlightPulseLevel(maxValue: 4) == 1)      // 0.25 * 4 = 1
            #expect(FlashMath.backlightPulseLevel(maxValue: 1) == 1)      // clamps up to min visible
        }

        @Test("no headroom gives 0")
        func zero() {
            #expect(FlashMath.backlightPulseLevel(maxValue: 0) == 0)
            #expect(FlashMath.backlightPulseLevel(maxValue: -5) == 0)
        }
    }
}
