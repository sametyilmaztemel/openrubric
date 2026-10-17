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
/// through `FlashDiagnostics`; the first whose READ sees a controllable level
/// wins and its paired write targets the same backing value):
///
/// 0. **DisplayServices private SPI** — `DisplayServicesGet/SetBrightness`.
///    The path the maintainers of nriley/brightness and displayutil document
///    for **Apple Silicon** (macOS 11+); the CoreDisplay functions they note
///    "don't work on Apple Silicon Macs".
/// 1. **CoreDisplay private SPI** — `CoreDisplay_Display_Get/SetUserBrightness`
///    (0...1, `double`-based); the slider-moving symbols on newer Intel.
/// 2. **IOKit** — `IODisplayGet/SetFloatParameter` (key `"brightness"`, 0...1)
///    on the `IODisplayConnect` service.
///
/// This is exactly the combination every reference brightness tool uses
/// (DisplayServices → CoreDisplay → IOKit), so it is stable on both
/// architectures: DisplayServices carries Apple Silicon, CoreDisplay carries
/// Intel, IOKit is the common fallback.
///
/// Every resolved function pointer is `@convention(c)` (a plain 8-byte C
/// pointer, exactly what `dlsym` returns) — NOT a Swift closure (16 bytes:
/// function pointer + context). `unsafeBitCast`-ing an 8-byte `dlsym` result
/// to a Swift closure is what trapped v0.5.4's `init` the moment the symbol
/// was found; with `@convention(c)` types the bitcast cannot trap on size.
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

    private static let displayServicesPath =
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    private static let coreDisplayPath = "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay"

    // Resolved lazily on the queue (see `resolve`). `@convention(c)` function
    // pointers are plain 8-byte C pointers (matching `dlsym`'s return), so the
    // `unsafeBitCast`s below cannot trap on a size mismatch.
    /// DisplayServices (Apple Silicon primary). Success == 0.
    private var dsGet: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32)?
    private var dsSet: (@convention(c) (CGDirectDisplayID, Float) -> Int32)?
    /// CoreDisplay SPI.
    private var cdGet: (@convention(c) (CGDirectDisplayID) -> Double)?
    private var cdSet: (@convention(c) (CGDirectDisplayID, Double) -> Void)?
    /// IOKit `IODisplayConnect` service for the fallback path (0 = absent).
    private var ioService: io_service_t = 0
    private var resolved = false

    init(pulseGap: Double = 0.25, dimFraction: Double = 0.15) {
        self.pulseGap = pulseGap
        self.dimFraction = dimFraction
    }

    /// Resolves the DisplayServices SPI, CoreDisplay SPI and IOKit service.
    /// Runs only on the serial queue, so `resolved` needs no synchronization.
    /// Never traps: `dlopen`/`dlsym` can only return nil, and the bitcasts are
    /// `@convention(c)` (8 bytes).
    private func resolve() {
        guard !resolved else { return }
        resolved = true

        if let handle = dlopen(Self.displayServicesPath, RTLD_LAZY) {
            if let sym = dlsym(handle, "DisplayServicesGetBrightness") {
                dsGet = unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self)
            }
            if let sym = dlsym(handle, "DisplayServicesSetBrightness") {
                dsSet = unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, Float) -> Int32).self)
            }
        }
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
            "flash: screen resolve displayServices=\((dsGet != nil && dsSet != nil) ? "ok" : "missing") " +
            "coreDisplay=\((cdGet != nil && cdSet != nil) ? "ok" : "missing") " +
            "iokit=\(ioService != 0 ? "ok" : "missing")"
        )
    }

    // MARK: - Read/write pairs, in priority order
    //
    // Each tuple is (name, read, write). `read` returns a valid 0...1 level
    // (or nil when the mechanism can't see the display); `write` is the paired
    // setter, so trusting a read means the write targets the same value.
    // `flash` picks the FIRST mechanism whose read succeeds and uses its write.

    private struct Mechanism {
        let name: String
        let read: (CGDirectDisplayID) -> Double?
        let write: (CGDirectDisplayID, Double) -> Void
    }

    /// Builds the ordered mechanism list. Runs on the serial queue after
    /// `resolve()` (closures capture `self`'s resolved pointers).
    private func mechanisms() -> [Mechanism] {
        var list: [Mechanism] = []

        // 0. DisplayServices (Apple Silicon primary). Trust the return code:
        //    == 0 means we got a value (0.0 is a genuinely dark panel, not a
        //    failure); non-zero means "no brightness / not controllable" -> nil.
        //    (Crisp: do NOT require > 0 and fall through — the CoreDisplay
        //    fallback reads a stale 1.0 on macOS 26, which would brighten a
        //    dark screen. `screenFlashEnabled` handles the "already at 0" skip.)
        if let get = self.dsGet, let set = self.dsSet {
            list.append(Mechanism(name: "DisplayServices",
                                  read: { d in
                                    var v: Float = 0
                                    guard get(d, &v) == 0 else { return nil }
                                    return Double(min(max(v, 0), 1))
                                  },
                                  write: { d, level in _ = set(d, Float(level)) }))
        }

        // 1. CoreDisplay SPI (double 0...1; a negative return is "no value").
        if let get = self.cdGet, let set = self.cdSet {
            list.append(Mechanism(name: "CoreDisplay",
                                  read: { d in
                                    let v = get(d)
                                    return v >= 0 ? v : nil
                                  },
                                  write: { d, level in set(d, level) }))
        }

        // 2. IOKit (float 0...1 on the IODisplayConnect service) — the
        //    cross-arch fallback both reference tools use.
        if self.ioService != 0 {
            let svc = self.ioService
            list.append(Mechanism(name: "IOKit",
                                  read: { _ in
                                    var v: Float = 0
                                    guard IODisplayGetFloatParameter(svc, 0, "brightness" as CFString, &v) == KERN_SUCCESS, v > 0 else { return nil }
                                    return Double(v)
                                  },
                                  write: { _, level in _ = IODisplaySetFloatParameter(svc, 0, "brightness" as CFString, Float(level)) }))
        }
        return list
    }

    /// Dims the main display and restores it, `count` times.
    func flash(count: Int) {
        queue.async {
            self.resolve()
            let display = CGMainDisplayID()

            // Pick the first mechanism whose read sees a controllable level,
            // and remember its paired writer.
            var chosen: Mechanism?
            var original: Double?
            for m in self.mechanisms() {
                if let v = m.read(display) {
                    chosen = m
                    original = v
                    FlashDiagnostics.note("flash: screen mechanism=\(m.name) brightness=\(v)")
                    break
                }
            }
            guard let chosen, let original else {
                FlashDiagnostics.note("flash: screen UNAVAILABLE (no mechanism read a level; " +
                    "displayServices=\((self.dsGet != nil && self.dsSet != nil) ? "ok" : "missing"), " +
                    "coreDisplay=\((self.cdGet != nil && self.cdSet != nil) ? "ok" : "missing"), " +
                    "iokit=\(self.ioService != 0 ? "ok" : "missing")) — skipped")
                return
            }
            guard FlashMath.screenFlashEnabled(original: CGFloat(original)) else {
                FlashDiagnostics.note("flash: screen already at 0 (skipped)")
                return
            }

            let dimmed = FlashMath.screenDimLevel(original: CGFloat(original), dimFraction: self.dimFraction)
            FlashDiagnostics.note("flash: screen [\(chosen.name)] count=\(count) brightness=\(original) dimming to \(dimmed)")

            for _ in 0..<count {
                chosen.write(display, dimmed)
                Thread.sleep(forTimeInterval: self.pulseGap)
                chosen.write(display, original)
                Thread.sleep(forTimeInterval: self.pulseGap)
            }
            // Guaranteed final restore: a failed restore write in the last
            // cycle must not leave the display dimmed.
            chosen.write(display, original)
            FlashDiagnostics.note("flash: screen [\(chosen.name)] done — \(count) pulse(s) sent, level restored")
        }
    }
}
#endif
