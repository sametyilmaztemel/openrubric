import Foundation

/// Pure, platform-agnostic math for the discreet output channels.
///
/// The flashers in `OpenRubricApp` talk to IOKit / CoreGraphics, which are
/// not available on Linux and are awkward to unit test directly. The
/// decisions they make — how much to dim, what to clamp, which backlight
/// element to target, whether a pulse is even visible — are plain integer /
/// fraction math, so they live here and are covered by tests on every CI
/// platform. The flashers call into `FlashMath` and keep only the
/// hardware I/O.
public enum FlashMath {

    // MARK: - Caps Lock LED

    /// The blink count to write to a Caps Lock LED element.
    ///
    /// The answer letter maps to a count (A=1 ... Z=26). A Caps Lock LED
    /// element reports a small `IOHIDElementGetLogicalMax` (often 0, 1, or
    /// 2), and some driver stacks silently drop writes outside
    /// `0...maximum`. Clamping to the element's maximum (and to 0) keeps the
    /// write in range while preserving the "blink" intent for elements that
    /// support it.
    public static func clampedBlinkCount(_ count: Int, maxValue: Int) -> Int {
        min(max(count, 0), max(maxValue, 0))
    }

    // MARK: - Screen brightness

    /// The level a screen flash dims to, as a fraction of the current level.
    /// Never negative. A display already at 0 has nothing to flash, so the
    /// caller should skip when `screenFlashEnabled` is false.
    public static func screenDimLevel(original: CGFloat, dimFraction: Double) -> CGFloat {
        max(0, original * dimFraction)
    }

    /// Whether a screen flash is worth doing (the display is on).
    public static func screenFlashEnabled(original: CGFloat) -> Bool {
        original > 0
    }

    // MARK: - Camera (front) LED

    /// The (set, restore) byte pair for one camera-LED pulse, driven through
    /// the SMC `LSOO` key (1 = lit, 0 = off).
    ///
    /// The camera LED is an on/off byte, so "flash N times" is an inverse
    /// pulse, exactly like the Caps Lock LED: a resting state of 0 blips up
    /// to 1 and back; a resting state of 1 dips to 0 and back. The result
    /// ends at the resting state, so a cycle never leaves the LED in the
    /// opposite position. Both levels are clamped to `0...1` so only a valid
    /// on/off byte is ever written to the SMC.
    ///
    /// Best-effort note: on modern Macs the LED is hardware-interlocked to
    /// the camera sensor, so when the camera is genuinely active the SMC
    /// write may be overridden — the caller treats the channel as best-effort
    /// and the diagnostic log records the write result.
    public static func cameraLEDPulse(resting: Int) -> (set: Int, restore: Int) {
        let r = min(max(resting, 0), 1)
        return (set: 1 - r, restore: r)
    }

    // MARK: - Keyboard backlight

    /// A HID page/usage pair to probe for a backlight element. Exposed as
    /// plain data (not IOKit types) so the candidate list and the selection
    /// policy can be unit tested without a keyboard attached.
    public struct HIDCandidate: Equatable, Sendable {
        public let page: Int
        public let usage: Int
        public init(page: Int, usage: Int) {
            self.page = page
            self.usage = usage
        }
    }

    /// Backlight element candidates, tried in order. The first candidate
    /// that matches an element on the attached device wins (backlight
    /// elements appear under different page/usage pairs depending on the
    /// hardware: Apple vendor page for built-ins, Consumer / GenericDesktop
    /// slots for some third-party keyboards).
    public static let backlightCandidates: [HIDCandidate] = [
        HIDCandidate(page: 0xFF00, usage: 0x0F),  // Apple vendor: keyboard backlight
        HIDCandidate(page: 0xFF00, usage: 0x01),  // Apple vendor: top case
        HIDCandidate(page: 0x0C, usage: 0x79),    // Consumer: brightness up
        HIDCandidate(page: 0x0C, usage: 0x7A),    // Consumer: brightness down
        HIDCandidate(page: 0x01, usage: 0x6F),    // GenericDesktop: non-standard slot
    ]

    /// Given, for each candidate in `backlightCandidates` order, the number
    /// of elements found on the device, return the index of the first
    /// candidate that matched at least one element, or `nil` when none did.
    ///
    /// Pure selection policy: the caller performs the IOKit lookups and
    /// feeds in the result counts, so the "first hit wins" rule is testable
    /// without hardware.
    public static func firstMatchingCandidateIndex(_ foundCounts: [Int]) -> Int? {
        for (index, count) in foundCounts.enumerated() where count > 0 {
            return index
        }
        return nil
    }

    /// A fixed minimum visible level for an off-backlight blip: a quarter of
    /// the element's maximum (clamped to at least 1 when the element can reach
    /// a level above 0), so the pulse is visible on hardware with different
    /// max values.
    public static func backlightPulseLevel(maxValue: Int) -> Int {
        let ceiling = max(maxValue, 0)
        guard ceiling > 0 else { return 0 }
        return max(1, Int(Double(ceiling) * 0.25))
    }

    /// The (set, restore) level pair for a single backlight pulse.
    ///
    /// The two levels differ by the element's current state:
    /// - backlight on (`original > 0`): dim to 0, then restore to the
    ///   original level, so a lit keyboard briefly goes dark and comes back;
    /// - backlight off (`original == 0`): a dim-to-0 would be invisible, so
    ///   instead blip *up* to a fixed minimum visible `pulseLevel`, then back
    ///   to 0 (its resting state).
    ///
    /// Both levels are clamped to `0...maxValue` so an out-of-range write is
    /// never sent. The result is only worth performing when
    /// `backlightPulseVisible` is true (i.e. `set != restore`).
    public static func backlightPulse(
        original: Int,
        maxValue: Int,
        pulseLevel: Int
    ) -> (set: Int, restore: Int) {
        let ceiling = max(maxValue, 0)
        if original > 0 {
            return (set: 0, restore: min(original, ceiling))
        }
        return (set: min(max(pulseLevel, 0), ceiling), restore: 0)
    }

    /// Whether a backlight pulse will actually be visible: the two written
    /// levels must differ (otherwise nothing on the hardware changes).
    public static func backlightPulseVisible(
        original: Int,
        maxValue: Int,
        pulseLevel: Int
    ) -> Bool {
        let levels = backlightPulse(original: original, maxValue: maxValue, pulseLevel: pulseLevel)
        return levels.set != levels.restore
    }
}
