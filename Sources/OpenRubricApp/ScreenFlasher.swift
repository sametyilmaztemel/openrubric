#if os(macOS)
import AppKit
import CoreGraphics
import Darwin
import IOKit
import OpenRubricCore

/// Screen brightness pulses on the main (internal) display.
///
/// Two mechanisms, tried in order (both best-effort, every outcome logged
/// through `FlashDiagnostics`):
///
/// 1. **CoreDisplay private SPI** — `CoreDisplay_Display_GetUserBrightness`
///    / `CoreDisplay_Display_SetUserBrightness` (0...1). These are the
///    symbols that actually move the brightness slider (used by nriley/
///    brightness, Crisp, lux). The old `CGDisplayBrightness` /
///    `CGDisplaySetDisplayBrightness` names do not exist in CoreGraphics,
///    so `dlsym(RTLD_DEFAULT, ...)` could never find them — that was why
///    the channel was a silent no-op. The framework is loaded with
///    `dlopen` and the symbols resolved at runtime, so nothing is linked
///    against a private framework at build time.
/// 2. **Public IOKit** — `IODisplayGetFloatParameter` /
///    `IODisplaySetFloatParameter` on the `IODisplayConnect` service.
///    Deprecated but still functional on Intel Macs; used when CoreDisplay
///    is unavailable.
///
/// The pulse dims the display to a small fraction of its original level
/// and restores it, `count` times.
final class ScreenFlasher: @unchecked Sendable {
    /// Serial queue so a pulse in flight never collides with another.
    private let queue = DispatchQueue(label: "openrubric.screen")
    /// Seconds each dim phase lasts before returning.
    private let pulseGap: Double
    /// Dim level as a fraction of the original brightness.
    private let dimFraction: Double

    /// CoreDisplay SPI, resolved at load time (nil when unavailable).
    private let cdGet: ((CGDirectDisplayID) -> Double)?
    private let cdSet: ((CGDirectDisplayID, Double) -> Void)?
    /// IOKit `IODisplayConnect` service for the fallback path (0 = absent).
    private let ioService: io_service_t

    private static let coreDisplayPath = "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay"

    init(pulseGap: Double = 0.25, dimFraction: Double = 0.15) {
        self.pulseGap = pulseGap
        self.dimFraction = dimFraction

        var get: ((CGDirectDisplayID) -> Double)?
        var set: ((CGDirectDisplayID, Double) -> Void)?
        if let handle = dlopen(Self.coreDisplayPath, RTLD_LAZY) {
            if let sym = dlsym(handle, "CoreDisplay_Display_GetUserBrightness") {
                get = unsafeBitCast(sym, to: ((CGDirectDisplayID) -> Double).self)
            }
            if let sym = dlsym(handle, "CoreDisplay_Display_SetUserBrightness") {
                set = unsafeBitCast(sym, to: ((CGDirectDisplayID, Double) -> Void).self)
            }
        }
        self.cdGet = get
        self.cdSet = set

        // The service is kept open for the app's lifetime (a retained
        // service port is fine here; the app is a menu-bar utility).
        self.ioService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"))

        FlashDiagnostics.note(
            "flash: screen init coreDisplay=\(get != nil && set != nil ? "ok" : "missing") iokit=\(self.ioService != 0 ? "ok" : "missing")"
        )
    }

    /// Dims the main display and restores it, `count` times.
    func flash(count: Int) {
        queue.async {
            let display = CGMainDisplayID()
            let get = self.cdGet
            let set = self.cdSet

            // Read the current level through whichever mechanism is usable.
            var original: Double?
            var mechanism = "none"
            if let get, let set {
                original = get(display)
                mechanism = "CoreDisplay"
            } else if self.ioService != 0 {
                var v: Float = 0
                // kIODisplayBrightnessKey == "brightness".
                if IODisplayGetFloatParameter(self.ioService, 0, "brightness" as CFString, &v) == KERN_SUCCESS {
                    original = Double(v)
                    mechanism = "IOKit"
                }
            }
            guard let original else {
                FlashDiagnostics.note("flash: screen UNAVAILABLE (coreDisplay=\(get != nil && set != nil ? "ok" : "missing"), iokit=\(self.ioService != 0 ? "ok" : "missing")) — skipped")
                return
            }
            guard FlashMath.screenFlashEnabled(original: CGFloat(original)) else {
                FlashDiagnostics.note("flash: screen already at 0 (skipped)")
                return
            }

            let dimmed = FlashMath.screenDimLevel(original: CGFloat(original), dimFraction: self.dimFraction)
            FlashDiagnostics.note("flash: screen [\(mechanism)] count=\(count) brightness=\(original) dimming to \(dimmed)")

            let apply: (Double) -> Void = { level in
                if let set, get != nil {
                    set(display, level)
                } else {
                    _ = IODisplaySetFloatParameter(self.ioService, 0, "brightness" as CFString, Float(level))
                }
            }
            for _ in 0..<count {
                apply(dimmed)
                Thread.sleep(forTimeInterval: self.pulseGap)
                apply(original)
                Thread.sleep(forTimeInterval: self.pulseGap)
            }
            FlashDiagnostics.note("flash: screen done — \(count) pulse(s) sent")
        }
    }
}
#endif
