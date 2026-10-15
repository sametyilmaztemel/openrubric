#if os(macOS)
import AppKit
import CoreGraphics
import Darwin

/// Screen brightness pulses via CoreGraphics.
///
/// `CGDisplayBrightness` / `CGDisplaySetDisplayBrightness` control the main
/// (internal) display; external displays often ignore them, which matches
/// the "main/internal display" scope in the issue. The pulse dims the
/// display to a small fraction of its original level and restores it.
///
/// These two functions are not consistently surfaced in the public
/// CoreGraphics Swift module, so they are resolved by symbol name at load
/// time. If the symbols are missing the channel is a silent no-op (the
/// issue marks screen flash as best-effort).
final class ScreenFlasher: @unchecked Sendable {
    /// Serial queue so a pulse in flight never collides with another.
    private let queue = DispatchQueue(label: "openrubric.screen")
    /// Seconds each dim phase lasts before returning.
    private let pulseGap: Double
    /// Dim level as a fraction of the original brightness.
    private let dimFraction: Double

    /// `CGDisplayBrightness(display) -> CGFloat`, if the symbol resolved.
    private let getBrightness: ((CGDirectDisplayID) -> CGFloat)?
    /// `CGDisplaySetDisplayBrightness(display, level)`, if the symbol resolved.
    private let setBrightness: ((CGDirectDisplayID, CGFloat) -> Void)?

    /// `RTLD_DEFAULT` is `((void *) -2)` on Darwin. Built directly from the
    /// numeric value so this file does not rely on the `RTLD_DEFAULT`
    /// constant being visible in the Darwin module (it is not, in this
    /// target's build), while `dlsym` itself resolves without issue.
    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)!

    init(pulseGap: Double = 0.25, dimFraction: Double = 0.15) {
        self.pulseGap = pulseGap
        self.dimFraction = dimFraction

        var getter: ((CGDirectDisplayID) -> CGFloat)?
        var setter: ((CGDirectDisplayID, CGFloat) -> Void)?
        if let sym = dlsym(Self.rtldDefault, "CGDisplayBrightness") {
            getter = unsafeBitCast(sym, to: ((CGDirectDisplayID) -> CGFloat).self)
        }
        if let sym = dlsym(Self.rtldDefault, "CGDisplaySetDisplayBrightness") {
            setter = unsafeBitCast(sym, to: ((CGDirectDisplayID, CGFloat) -> Void).self)
        }
        self.getBrightness = getter
        self.setBrightness = setter
    }

    /// Dims the main display and restores it, `count` times.
    func flash(count: Int) {
        queue.async {
            guard let get = self.getBrightness, let set = self.setBrightness else { return }
            let display = CGMainDisplayID()
            let original = get(display)
            guard original > 0 else { return }

            let dimmed = max(0.0, original * self.dimFraction)
            for _ in 0..<count {
                set(display, dimmed)
                Thread.sleep(forTimeInterval: self.pulseGap)
                set(display, original)
                Thread.sleep(forTimeInterval: self.pulseGap)
            }
        }
    }
}
#endif
