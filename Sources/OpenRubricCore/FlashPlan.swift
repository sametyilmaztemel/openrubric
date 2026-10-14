import Foundation

/// Discreet output channels: the answer is flashed (blink/pulse count
/// encodes the letter) instead of — or in addition to — the panel.
///
/// Only multiple-choice answers carry a letter, so only they are flammable.
/// Each channel is independently enable/disable-able in settings.
public enum FlashChannel: String, CaseIterable, Codable, Sendable {
    /// Caps Lock LED blinks `letterNumber` times (A=1 ... Z=26).
    case capsLockLED
    /// Internal display brightness pulses (restore original after).
    case screenFlash
    /// Keyboard backlight pulses (external keyboards vary; best-effort).
    case keyboardBacklight
}

/// The plan for one flash: which channels fire and with what count.
public struct FlashPlan: Equatable, Sendable {
    public let channels: [FlashChannel]
    /// Blink count for count-based channels (A=1, B=2, ...).
    public let count: Int

    public init(channels: [FlashChannel], count: Int) {
        self.channels = channels
        self.count = count
    }
}

public enum FlashPlanner {
    /// Letter -> 1-based number (A=1 ... Z=26).
    public static func letterNumber(_ letter: String?) -> Int? {
        guard let c = letter?.uppercased().first,
              let ascii = c.asciiValue, (65...90).contains(ascii) else {
            return nil
        }
        return Int(ascii - 64)
    }

    /// Builds the plan for a parsed answer restricted to the channels the
    /// user enabled. Short answers and unmapped letters yield no plan
    /// (nothing to encode).
    public static func plan(for answer: ParsedAnswer, enabled: Set<FlashChannel>) -> FlashPlan? {
        guard let count = letterNumber(answer.letter) else { return nil }
        let channels = FlashChannel.allCases.filter { enabled.contains($0) }
        guard !channels.isEmpty else { return nil }
        return FlashPlan(channels: channels, count: count)
    }
}
