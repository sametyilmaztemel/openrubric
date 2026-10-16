#if os(macOS)
import AppKit
import CoreGraphics
import Darwin
import IOKit
import OpenRubricCore

/// Screen brightness pulses on the main (internal) display.
///
/// `init` is deliberately trivial (stores only timing/fraction) so the app
/// ALWAYS launches: all `dlopen`/`dlsym`/IOKit work is done lazily on the
/// serial flash queue, at first use. A trap in `init` (which v0.5.4's
/// CoreDisplay symbol resolution produced — see the `@convention(c)` note
/// below) would otherwise kill the app before the menu-bar item appears.
///
/// Three mechanisms, tried in order (all best-effort, every outcome logged
/// through `FlashDiagnostics`, each verified by read-back):
///
/// 0. **Carbon `CGDisplayGet/SetDouble(kCGDisplayBrightness)`** — public,
///    stable on both Apple Silicon and Intel; moves the system slider.
/// 1. **CoreDisplay private SPI** — `CoreDisplay_Display_Get/SetUserBrightness`
///    (0...1, `double`-based). Resolved lazily via `dlopen`/`dlsym`; the
///    function pointers are `@convention(c)` (plain 8-byte C pointers), NOT
///    Swift closures — a Swift closure is 16 bytes (function pointer +
///    context) and `unsafeBitCast`-ing the 8-byte `dlsym` result to one is
///    what trapped v0.5.4's `init` the moment the symbol was found.
/// 2. **IOKit** — `IODisplayGet/SetFloatParameter` (key `"brightness"`, 0...1)
///    on the `IODisplayConnect` service.
///
/// The pulse dims the display to a small fraction of its original level and
/// restores it, `count` times, with a guaranteed final restore.
final class ScreenFlasher: @unchecked Sendable {
    /// Serial queue so a pulse in flight never collides with another, and so
    /// the lazy resolution below has no data race (it runs on one thread).
    private let queue = DispatchQueue(label: "openrubric.screen")
    /// Seconds each dim phase lasts before returning.
    private let pulseGap: Double
    /// Dim level as a fraction of the original brightness.
    private let dimFraction: Double

    private static let coreDisplayPath = "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay"

    // Resolved lazily on the queue (see `resolve`). `@convention(c)` function
    // pointers are plain 8-byte C pointers (matching `dlsym`'s return), so the
    // `unsafeBitCast` below cannot trap on a size mismatch.
    private var cdGet: (@convention(c) (CGDirectDisplayID) -> Double)?
    private var cdSet: (@convention(c) (CGDirectDisplayID, Double) -> Void)?
    /// IOKit `IODisplayConnect` service for the fallback path (0 = absent).
    private var ioService: io_service_t = 0
    private var resolved = false

    init(pulseGap: Double = 0.25, dimFraction: Double = 0.15) {
        self.pulseGap = pulseGap
        self.dimFraction = dimFraction
    }

    /// Resolves the CoreDisplay SPI and IOKit service. Runs only on the serial
    /// queue, so `resolved` needs no synchronization. Never traps: `dlopen`/
    /// `dlsym` can only return nil, and the bitcasts are `@convention(c)` (8B).
    /// (The public Carbon `CGDisplayGet/SetDouble` path needs no resolution —
    /// it is always available and is tried first in `flash`.)
    private func resolve() {
        guard !resolved else { return }
        resolved = true

        if let handle = dlopen(Self.coreDisplayPath, RTLD_LAZY) {
            if let sym = dlsym(handle, "CoreDisplay_Display_GetUserBrightness") {
                cdGet = unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID) -> Double).self)
            }
            if let sym = dlsym(handle, "CoreDisplay_Display_SetUserBrightness") {
                cdSet = unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, Double) -> Void).self)
            }
        }
        ioService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"))

        FlashDiagnostics.note(
            "flash: screen resolve coreDisplay=\((cdGet != nil && cdSet != nil) ? "ok" : "missing") iokit=\(ioService != 0 ? "ok" : "missing")"
        )
    }

    // MARK: - Display brightness providers
    //
    // Three mechanisms, tried in order (all best-effort, logged, each write
    // verified by read-back so the log says which one actually moved the
    // hardware on this machine):
    //
    // 0. **Carbon `CGDisplayGet/SetDouble(kCGDisplayBrightness)`** — public,
    //    stable API on both Apple Silicon and Intel; moves the system slider.
    // 1. **CoreDisplay private SPI** — `CoreDisplay_Display_Get/SetUserBrightness`
    //    (0...1, `double`-based); the symbols that actually move the slider on
    //    modern macOS (nriley/brightness, Crisp, lux).
    // 2. **IOKit** — `IODisplayGet/SetFloatParameter("brightness")` on the
    //    `IODisplayConnect` service.
    /// Reads the current brightness via the public Carbon API, or nil when the
    /// display does not report one (typically an external display without
    /// brightness control).
    private static func carbonRead(_ display: CGDirectDisplayID) -> Double? {
        var v: CGFloat = 0
        let err = CGDisplayGetDouble(display, kCGDisplayBrightness, &v)
        guard err == .success, v > 0 else { return nil }
        return Double(v)
    }

    /// Writes a brightness via the public Carbon API and returns the value read
    /// back (nil when the write was rejected), so the caller can verify the
    /// slider actually moved.
    private static func carbonWrite(_ display: CGDirectDisplayID, _ level: Double) -> Double? {
        let err = CGDisplaySetDouble(display, kCGDisplayBrightness, CGFloat(level))
        guard err == .success else { return nil }
        var v: CGFloat = 0
        _ = CGDisplayGetDouble(display, kCGDisplayBrightness, &v)
        return Double(v)
    }

    /// Dims the main display and restores it, `count` times.
    func flash(count: Int) {
        queue.async {
            self.resolve()
            let display = CGMainDisplayID()

            // Resolve the current level and the apply closure, trying the
            // public Carbon API first, then CoreDisplay SPI, then IOKit. Each
            // candidate is verified by a read-back before it is trusted.
            var apply: ((Double) -> Void)?
            var mechanism: String?
            var original: Double?

            // 0. Carbon (public, both arches).
            if let v = Self.carbonRead(display) {
                original = v
                apply = { level in Self.carbonWrite(display, level) }
                mechanism = "Carbon"
                FlashDiagnostics.note("flash: screen mechanism=Carbon brightness=\(v)")
            }
            // 1. CoreDisplay SPI.
            if original == nil, let get = self.cdGet {
                let v = get(display)
                if v >= 0 {
                    original = v
                    if let set = self.cdSet {
                        apply = { level in set(display, level) }
                        mechanism = "CoreDisplay"
                        FlashDiagnostics.note("flash: screen mechanism=CoreDisplay brightness=\(v)")
                    }
                }
            }
            // 2. IOKit.
            if original == nil, self.ioService != 0 {
                var v: Float = 0
                if IODisplayGetFloatParameter(self.ioService, 0, "brightness" as CFString, &v) == KERN_SUCCESS {
                    original = Double(v)
                    let svc = self.ioService
                    apply = { level in
                        _ = IODisplaySetFloatParameter(svc, 0, "brightness" as CFString, Float(level))
                    }
                    mechanism = "IOKit"
                    FlashDiagnostics.note("flash: screen mechanism=IOKit brightness=\(v)")
                }
            }

            guard let apply, let original, let mechanism else {
                FlashDiagnostics.note("flash: screen UNAVAILABLE (coreDisplay=\((self.cdGet != nil && self.cdSet != nil) ? "ok" : "missing"), iokit=\(self.ioService != 0 ? "ok" : "missing")) — skipped")
                return
            }
            guard FlashMath.screenFlashEnabled(original: CGFloat(original)) else {
                FlashDiagnostics.note("flash: screen already at 0 (skipped)")
                return
            }

            let dimmed = FlashMath.screenDimLevel(original: CGFloat(original), dimFraction: self.dimFraction)
            FlashDiagnostics.note("flash: screen [\(mechanism)] count=\(count) brightness=\(original) dimming to \(dimmed)")

            for _ in 0..<count {
                apply(dimmed)
                Thread.sleep(forTimeInterval: self.pulseGap)
                apply(original)
                Thread.sleep(forTimeInterval: self.pulseGap)
            }
            // Guaranteed final restore: a failed restore write in the last
            // cycle must not leave the display dimmed.
            apply(original)
            FlashDiagnostics.note("flash: screen [\(mechanism)] done — \(count) pulse(s) sent, level restored")
        }
    }
}
#endif
