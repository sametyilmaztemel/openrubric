#if os(macOS)
import AppKit

/// Screen brightness pulses via CoreGraphics.
///
/// `CGDisplaySetDisplayBrightness` is the public API for the main
/// (internal) display; external displays often ignore it, which matches
/// the "main/internal display" scope in the issue. The pulse dims the
/// display to ~15% of its original level and restores it.
final class ScreenFlasher: @unchecked Sendable {
    /// Serial queue so a pulse in flight never collides with another.
    private let queue = DispatchQueue(label: "openrubric.screen")
    /// Seconds each dim phase lasts before returning.
    private let pulseGap: Double
    /// Dim level as a fraction of the original brightness.
    private let dimFraction: Double

    init(pulseGap: Double = 0.25, dimFraction: Double = 0.15) {
        self.pulseGap = pulseGap
        self.dimFraction = dimFraction
    }

    /// Dims the main display and restores it, `count` times.
    func flash(count: Int) {
        queue.async {
            let display = CGMainDisplayID()
            let original = CGDisplayBrightness(display)
            guard original > 0 else { return }

            let dimmed = max(0.0, original * self.dimFraction)
            for _ in 0..<count {
                CGDisplaySetDisplayBrightness(display, dimmed)
                Thread.sleep(forTimeInterval: self.pulseGap)
                CGDisplaySetDisplayBrightness(display, original)
                Thread.sleep(forTimeInterval: self.pulseGap)
            }
        }
    }
}
