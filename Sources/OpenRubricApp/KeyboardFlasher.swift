#if os(macOS)
import AppKit
import IOKit
import IOKit.hid
import OpenRubricCore

// MARK: - Apple vendor page constants
//
// Apple built-in keyboards expose the backlight through a vendor page
// (0xFF00) rather than a standard HID usage. These constants are not in
// the public headers (AppleHIDUsageTables.h has been empty since 10.14).
// The concrete candidate page/usage pairs live in `FlashMath.backlightCandidates`
// (unit tested); this comment documents why the vendor page is non-obvious.

/// Keyboard output channels driven through IOKit HID.
///
/// Both are best-effort: a keyboard without the relevant element simply
/// does not react, and nothing here throws. The Caps Lock channel blinks the
/// LED `count` times by pulsing it on/off per cycle (the element is an on/off
/// LED, so the count is never written as a single value — that would clamp to
/// the max of 1 and leave the LED lit). The backlight channel pulses a
/// brightness element and restores it.
///
/// The IOKit Swift overlay renames the CF pointer types:
/// `IOHIDManagerRef`/`IOHIDDeviceRef`/`IOHIDElementRef`/`IOHIDValueRef`
/// become `IOHIDManager`/`IOHIDDevice`/`IOHIDElement`/`IOHIDValue`, and
/// CF containers bridge directly (`as? Set<IOHIDDevice>`,
/// `as? [IOHIDElement]`). CF objects are ARC-managed, so there is no
/// `CFRelease`. HID page/usage constants import as `Int`.
final class KeyboardFlasher: @unchecked Sendable {
    /// Serial queue so overlapping answer cycles cannot interleave HID
    /// writes on the same elements.
    private let queue = DispatchQueue(label: "openrubric.keyboard")
    /// Seconds a pulse stays dim before returning to its original level.
    private let pulseGap: Double

    init(pulseGap: Double = 0.25) {
        self.pulseGap = pulseGap
    }

    /// Blinks the Caps Lock LED `count` times (A=1 ...).
    ///
    /// The **built-in** MacBook keyboard is driven by the `HIDCapsLockLED`
    /// service property (macOS 26+) or `IOHIDSetModifierLockState`
    /// (macOS 10.6+) — see `blinkBuiltInCapsLED`. Its HID LED element write
    /// returns `kIOReturnMethodNotSupported` (0xE00002CD), which is why the
    /// dedicated path exists. **External** HID keyboards still use the
    /// element-write fallback (`blinkCapsLock` per device). All paths are
    /// best-effort and log their outcome.
    func flashCapsLock(count: Int) {
        queue.async {
            // 1. Built-in LED via the HID service property (no case change).
            var doneBuiltIn = false
            do {
                try Self.blinkBuiltInCapsLED(count: count, gap: self.pulseGap)
                doneBuiltIn = true
            } catch {
                FlashDiagnostics.note("flash: capsLock [HIDCapsLockLED] unavailable: \(error)")
            }

            // 2. External HID keyboards via element writes (built-in's HID
            //    write returns MethodNotSupported, so this covers the others).
            let keyboards = Self.keyboards()
            FlashDiagnostics.note("flash: capsLock count=\(count) keyboards=\(keyboards.count) builtIn=\(doneBuiltIn)")
            for keyboard in keyboards {
                Self.blinkCapsLock(keyboard: keyboard, count: count, gap: self.pulseGap)
            }
        }
    }

    /// Blinks the **built-in** keyboard's caps lock LED `count` times.
    ///
    /// Two mechanisms, feature-detected at runtime (best-effort, logged):
    ///
    /// 1. `HIDCapsLockLED` service property (`"On"`/`"Off"`/`"Auto"`) on the
    ///    built-in HID service — the clean path (Karabiner's mechanism, used
    ///    by pi-caps-blink): drives the LED without touching the typing case.
    ///    Probed by reading the property; when the read returns nothing the
    ///    OS does not support it and we fall through.
    /// 2. `IOHIDSetModifierLockState` on the `IOHIDSystem` service
    ///    (`kIOHIDCapsLockState` = 1) — public since macOS 10.6 and verified
    ///    working on Sequoia 15.x (kanata, the Qiita Swift snippet, the
    ///    `lock_keys` crate all use it). Side effect: the real caps lock
    ///    modifier state is toggled for the duration of each pulse, so we
    ///    read the resting state first and restore it at the end; the LED
    ///    follows the state, so the blink is visible.
    ///
    /// Neither path can leave the LED stuck: path 1 ends in `"Auto"`,
    /// path 2 ends at the resting state.
    private enum CapsLEDMode: String {
        case on = "On", off = "Off", auto = "Auto"
    }

    private struct BuiltInCapsLEDError: Error, CustomStringConvertible {
        let text: String
        var description: String { text }
    }

    /// Constants from IOKit/hid/IOHIDLib.h (kept as literals so the code does
    /// not depend on which overlay header exposes them).
    private static let ioHIDSystemClass = "IOHIDSystem"
    private static let hidParamConnectType: UInt32 = 1
    private static let hidCapsLockState: Int32 = 1

    private static func blinkBuiltInCapsLED(count: Int, gap: Double) throws {
        // Locate the built-in keyboard's HID service through the event
        // system. The services array must outlive every use of `builtIn`
        // (its elements are owned by the array), so it stays in function
        // scope rather than an inner `if let` block.
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let services = IOHIDEventSystemClientCopyServices(client)

        var builtIn: IOHIDServiceClient?
        if let services {
            let n = CFArrayGetCount(services)
            for i in 0..<n {
                guard let raw = CFArrayGetValueAtIndex(services, i) else { continue }
                // takeUnretainedValue (not unsafeBitCast to the class type):
                // the element is owned by `services`, and a class-typed cast
                // would make ARC emit a phantom release on the local.
                let service = Unmanaged<IOHIDServiceClient>.fromOpaque(raw).takeUnretainedValue()
                // GenericDesktop (0x01) / Keyboard (0x06).
                guard IOHIDServiceClientConformsTo(service, 0x01, 0x06) != 0 else { continue }
                if let flag = IOHIDServiceClientCopyProperty(service, "Built-In" as CFString),
                   (flag as? NSNumber)?.boolValue == true {
                    builtIn = service
                    break
                }
            }
        }

        // Path 1: HIDCapsLockLED property (feature-detect by read, verified
        // by write + read-back inside blinkViaCapsLEDProperty). Any failure
        // falls through to path 2 instead of skipping the built-in LED.
        if let target = builtIn {
            if IOHIDServiceClientCopyProperty(target, "HIDCapsLockLED" as CFString) != nil {
                do {
                    try blinkViaCapsLEDProperty(target, count: count, gap: gap)
                    return
                } catch {
                    FlashDiagnostics.note("flash: capsLock [HIDCapsLockLED] failed: \(error) — using modifier-lock state")
                }
            } else {
                FlashDiagnostics.note("flash: capsLock [HIDCapsLockLED] property not supported on this OS — using modifier-lock state")
            }
        } else {
            FlashDiagnostics.note("flash: capsLock [HIDCapsLockLED] no built-in keyboard service — using modifier-lock state")
        }

        // Path 2: IOHIDSetModifierLockState on IOHIDSystem (macOS 10.6+).
        try blinkViaModifierLockState(count: count, gap: gap)
    }

    private static func blinkViaCapsLEDProperty(_ target: IOHIDServiceClient, count: Int, gap: Double) throws {
        func set(_ mode: CapsLEDMode) -> Bool {
            IOHIDServiceClientSetProperty(target, "HIDCapsLockLED" as CFString, mode.rawValue as NSString)
        }
        func read() -> String? {
            guard let value = IOHIDServiceClientCopyProperty(target, "HIDCapsLockLED" as CFString),
                  let str = value as? NSString else { return nil }
            return str as String
        }
        guard set(.auto) else {
            throw BuiltInCapsLEDError(text: "HIDCapsLockLED write rejected")
        }
        // Write + read-back verification: a property that accepts writes but
        // does not actually move the LED would silently win this path and
        // never fall through to the modifier-lock mechanism.
        guard set(.on), read() == "On" else {
            _ = set(.auto)
            throw BuiltInCapsLEDError(text: "HIDCapsLockLED write not observable (read-back mismatch)")
        }
        FlashDiagnostics.note("flash: capsLock [HIDCapsLockLED] built-in service found, writing On/Off x\(count)")
        for _ in 0..<count {
            _ = set(.on)
            Thread.sleep(forTimeInterval: gap)
            _ = set(.off)
            Thread.sleep(forTimeInterval: gap)
        }
        _ = set(.auto)
        FlashDiagnostics.note("flash: capsLock [HIDCapsLockLED] done — \(count) blink(s), restored Auto")
    }

    private static func blinkViaModifierLockState(count: Int, gap: Double) throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(Self.ioHIDSystemClass))
        guard service != 0 else {
            throw BuiltInCapsLEDError(text: "IOHIDSystem service not found")
        }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, Self.hidParamConnectType, &connection)
        guard kr == KERN_SUCCESS else {
            throw BuiltInCapsLEDError(text: "IOServiceOpen(IOHIDSystem) failed status=\(kr)")
        }
        defer { IOServiceClose(connection) }

        var resting = false
        let readKR = IOHIDGetModifierLockState(connection, Self.hidCapsLockState, &resting)
        if readKR != KERN_SUCCESS {
            FlashDiagnostics.note("flash: capsLock [modifierState] read status=\(readKR) (assuming off)")
        }
        FlashDiagnostics.note("flash: capsLock [modifierState] resting=\(resting) count=\(count)")
        for _ in 0..<count {
            IOHIDSetModifierLockState(connection, Self.hidCapsLockState, !resting)
            Thread.sleep(forTimeInterval: gap)
            IOHIDSetModifierLockState(connection, Self.hidCapsLockState, resting)
            Thread.sleep(forTimeInterval: gap)
        }
        // Guarantee the resting state even if the loop's last write was lost.
        IOHIDSetModifierLockState(connection, Self.hidCapsLockState, resting)
        FlashDiagnostics.note("flash: capsLock [modifierState] done — \(count) blink(s), resting=\(resting) restored")
    }

    /// Pulses the keyboard backlight, `count` times.
    func flashBacklight(count: Int) {
        queue.async {
            Self.pulseBacklight(count: count, gap: self.pulseGap)
        }
    }

    // MARK: - HID internals

    /// All keyboards currently attached (GenericDesktop page, Keyboard usage).
    private static func keyboards() -> [IOHIDDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let openStatus = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        // kIOReturnSuccess (0) means the manager opened for reading *and*
        // writing. A non-zero return (typically kIOReturnNoAccess when the
        // Input Monitoring permission is missing) means the devices are
        // visible but writes below will silently fail — so surface it.
        FlashDiagnostics.note("flash: IOHIDManagerOpen status=\(openStatus) (0=success/read+write)")

        return (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.map { $0 } ?? []
    }

    /// Blinks every Caps Lock LED element on `keyboard` `count` times by
    /// pulsing each on/off cycle, then restores the resting state.
    ///
    /// A Caps Lock LED is an on/off element, so "blink N times" is a pulse
    /// loop, not a single value write (a one-shot write of the count clamps
    /// to the element's max of 1 and leaves the LED lit instead of
    /// flashing). Each cycle writes the *inverse* of the resting state and
    /// back to it, so a blink is visible whether the LED starts on or off,
    /// and the loop ends at the resting state (a cycle never toggles Caps
    /// Lock on).
    ///
    /// The built-in keyboard is skipped here: its HID LED element write
    /// returns `kIOReturnMethodNotSupported` (0xE00002CD) — the built-in LED
    /// is driven by the `HIDCapsLockLED` / modifier-lock paths in
    /// `blinkBuiltInCapsLED` instead.
    private static func blinkCapsLock(keyboard: IOHIDDevice, count: Int, gap: Double) {
        if isBuiltIn(keyboard: keyboard) {
            FlashDiagnostics.note("flash: capsLock skipping built-in keyboard on HID element path (handled via HIDCapsLockLED/modifier-lock)")
            return
        }
        let elements = matchingElements(on: keyboard, page: kHIDPage_LEDs, usage: kHIDUsage_LED_CapsLock)
        guard !elements.isEmpty else {
            FlashDiagnostics.note("flash: capsLock element NOT FOUND on this keyboard")
            return
        }
        for element in elements {
            let resting = readElement(keyboard: keyboard, element: element) ?? 0
            let maxValue = Int(IOHIDElementGetLogicalMax(element))
            FlashDiagnostics.note("flash: capsLock element found max=\(maxValue) resting=\(resting)")
            let inverse = FlashMath.clampedBlinkCount(resting == 0 ? 1 : 0, maxValue: maxValue)
            let restore = FlashMath.clampedBlinkCount(resting, maxValue: maxValue)
            for cycle in 0..<count {
                // kIOReturnSuccess (0) on the first write is the confirmation
                // the device accepted writes; a non-zero code (e.g. no access)
                // is logged so the cause is visible without `log --private`.
                let writeStatus = setElement(keyboard: keyboard, element: element, value: inverse)
                if cycle == 0 {
                    FlashDiagnostics.note("flash: capsLock first write status=\(writeStatus) (0=success)")
                }
                Thread.sleep(forTimeInterval: gap)
                _ = setElement(keyboard: keyboard, element: element, value: restore)
                Thread.sleep(forTimeInterval: gap)
            }
            FlashDiagnostics.note("flash: capsLock done — \(count) blink(s) sent")
        }
    }

    /// True for the MacBook's built-in keyboard. Apple devices expose
    /// `Product` = "Apple Internal Keyboard / Trackpad" (the `Built-In`
    /// property lives on the HID *service*, not the device handle, so the
    /// product name is the reliable device-level check).
    private static func isBuiltIn(keyboard: IOHIDDevice) -> Bool {
        let product = (IOHIDDeviceGetProperty(keyboard, kIOHIDProductKey as CFString) as? String) ?? ""
        return product.contains("Apple Internal")
    }

    /// Reads the current integer value of `element` on `keyboard`, or `nil`
    /// when the read fails. The placeholder is bound to a local so ARC keeps
    /// it alive across the call; if `IOHIDDeviceGetValue` installs a new
    /// caller-owned value (pointer differs from the placeholder) we release
    /// it after reading the integer.
    private static func readElement(keyboard: IOHIDDevice, element: IOHIDElement) -> Int? {
        let placeholderValue = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, 0)
        var placeholder = Unmanaged.passUnretained(placeholderValue)
        guard IOHIDDeviceGetValue(keyboard, element, &placeholder) == kIOReturnSuccess else { return nil }
        let returned = placeholder.takeUnretainedValue()
        let value = Int(IOHIDValueGetIntegerValue(returned))
        if Unmanaged.passUnretained(returned).toOpaque() != Unmanaged.passUnretained(placeholderValue).toOpaque() {
            Unmanaged.passUnretained(returned).release()
        }
        return value
    }

    /// Pulses the keyboard backlight `count` times, restoring the original
    /// level afterwards.
    ///
    /// Two mechanisms, tried in order (both best-effort, logged with read-back
    /// so the log says *which* path actually moved the hardware):
    ///
    /// 1. **CoreBrightness** (`KeyboardBrightnessClient`) — the path
    ///    `corebrightnessd` responds to on **both** Apple Silicon and Intel;
    ///    it is what System Settings' slider uses. On Apple Silicon the
    ///    IOKit `KeyboardBacklightBrightness` property is a state mirror the
    ///    PWM hardware ignores, and the old Intel `AppleLMUController` service
    ///    does not exist at all — so this is the primary path. Each write is
    ///    verified by reading the value back.
    /// 2. **`AppleLMUController`** (Intel) — the classic IOKit scalar-method
    ///    path (keyboardparty / maclight / macbook-brightness), kept for Intel
    ///    Macs where CoreBrightness is unavailable or read-back fails.
    ///
    /// The current level is read first so it can be restored after the pulse;
    /// a level of 0 means the backlight is off and the pulse blips up to a
    /// minimum visible level and back.
    private static func pulseBacklight(count: Int, gap: Double) {
        // 1. CoreBrightness (Apple Silicon + Intel).
        if CoreBrightness.resolve() {
            let ids = CoreBrightness.keyboardIDs()
            let builtInID = ids.first(where: CoreBrightness.isBuiltIn)
            // Prefer the built-in keyboard; fall back to the first ID.
            let target = builtInID ?? ids.first
            // One line that tells us the whole picture from the user's machine:
            // which IDs the system reports, which (if any) is built-in, and the
            // current level of the chosen target. This is the exact data needed
            // to diagnose why CoreBrightness is not moving the LED on a given
            // machine (empty IDs vs. no built-in vs. level stuck at 0 vs.
            // state-mirror write).
            FlashDiagnostics.note("flash: backlight [CoreBrightness] ids=\(ids.map { String($0) }) builtIn=\(builtInID.map { String($0) } ?? "none") target=\(target.map { String($0) } ?? "none")")
            if let id = target {
                if pulseBacklightViaCoreBrightness(count: count, gap: gap, id: id) {
                    return
                }
                FlashDiagnostics.note("flash: backlight [CoreBrightness] read-back failed for id=\(id) — trying AppleLMUController")
            } else {
                FlashDiagnostics.note("flash: backlight [CoreBrightness] no backlight IDs reported — trying AppleLMUController")
            }
        } else {
            FlashDiagnostics.note("flash: backlight [CoreBrightness] unavailable (framework/class not resolved) — trying AppleLMUController")
        }

        // 2. AppleLMUController (Intel fallback).
        pulseBacklightViaLMU(count: count, gap: gap)
    }

    /// CoreBrightness backlight pulse. Returns true when the write was
    /// verified by read-back (so the caller can trust the level actually
    /// changed); false otherwise, letting the caller fall back to the Intel
    /// path.
    private static func pulseBacklightViaCoreBrightness(count: Int, gap: Double, id: UInt64) -> Bool {
        guard let original = CoreBrightness.getBrightness(id) else {
            FlashDiagnostics.note("flash: backlight [CoreBrightness] getBrightness(id=\(id)) returned nil")
            return false
        }
        // Dim level: 0 when the backlight is on (a visible dip); a fixed
        // minimum-visible blip when it is off (0 would be invisible).
        let dimmed: Float = original > 0 ? 0 : Float(FlashMath.backlightPulseLevel(maxValue: 1000)) / 1000
        let restored: Float = original
        if dimmed == restored {
            FlashDiagnostics.note("flash: backlight [CoreBrightness] pulse not visible (original=\(original)) — skipped")
            return true
        }
        // Verify the dim write actually moves the value before committing to
        // the loop (catches a state-mirror property that accepts writes but
        // never propagates). Read-back is captured in its own local so the
        // guard's else-body (where `probe` is out of scope) can still log it.
        let probe = CoreBrightness.setBrightness(id, dimmed)
        guard let probe, abs(probe - dimmed) < 0.05 else {
            _ = CoreBrightness.setBrightness(id, restored)
            FlashDiagnostics.note("flash: backlight [CoreBrightness] dim write not observable (set=\(dimmed) readback=\(probe.map { String($0) } ?? "nil"))")
            return false
        }
        Thread.sleep(forTimeInterval: gap)
        FlashDiagnostics.note("flash: backlight [CoreBrightness] count=\(count) original=\(original) dimming to \(dimmed) (verified)")
        for _ in 0..<count {
            _ = CoreBrightness.setBrightness(id, dimmed)
            Thread.sleep(forTimeInterval: gap)
            _ = CoreBrightness.setBrightness(id, restored)
            Thread.sleep(forTimeInterval: gap)
        }
        // Guaranteed final restore: a failed restore write in the last cycle
        // must not leave the backlight dimmed.
        let final = CoreBrightness.setBrightness(id, restored)
        FlashDiagnostics.note("flash: backlight [CoreBrightness] done — \(count) pulse(s), restored=\(final.map { abs($0 - restored) < 0.05 } ?? false)")
        return true
    }

    /// Intel IOKit path via `AppleLMUController` (kept for Intel Macs):
    /// selector 1 = get current LED brightness (0...0xFFF), selector 2 = set
    /// LED brightness (input [0, level]). No-ops (with a log) when the service
    /// is absent, which is the Apple Silicon case — that's why CoreBrightness
    /// is tried first.
    private static func pulseBacklightViaLMU(count: Int, gap: Double) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleLMUController"))
        guard service != 0 else {
            FlashDiagnostics.note("flash: backlight [AppleLMUController] NOT FOUND (Apple Silicon?) — skipped")
            return
        }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        let openStatus = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard openStatus == KERN_SUCCESS else {
            FlashDiagnostics.note("flash: backlight [AppleLMUController] IOServiceOpen FAILED status=\(openStatus) — skipped")
            return
        }
        defer { IOServiceClose(connection) }

        func call(_ selector: UInt32, _ input: [UInt64]) -> UInt64? {
            var input = input
            var output: UInt64 = 0
            var outputCount: UInt32 = 1
            let kr = IOConnectCallScalarMethod(
                connection, selector,
                &input, UInt32(input.count),
                &output, &outputCount
            )
            guard kr == KERN_SUCCESS else {
                FlashDiagnostics.note("flash: backlight [AppleLMUController] selector=\(selector) IOConnectCallScalarMethod FAILED status=\(kr)")
                return nil
            }
            return output
        }

        guard let originalRaw = call(1, [0]) else { return }
        // Blip level for the backlight-OFF case: a fixed 25% of the assumed
        // 12-bit maximum (0x1000) — when the backlight is off the read
        // returns 0 and a 1/4095 blip would be invisible. On 8-bit hardware
        // the firmware clamps 1024 to 255, still a clear blip.
        let blip = UInt64(FlashMath.backlightPulseLevel(maxValue: 0x1000))
        let (pulseLevel, restoreLevel): (UInt64, UInt64)
        if originalRaw > 0 {
            pulseLevel = 0
            restoreLevel = originalRaw
        } else {
            pulseLevel = blip
            restoreLevel = 0
        }
        if pulseLevel == restoreLevel {
            FlashDiagnostics.note("flash: backlight [AppleLMUController] pulse not visible (original=\(originalRaw)) — skipped")
            return
        }
        FlashDiagnostics.note("flash: backlight [AppleLMUController] count=\(count) original=\(originalRaw) pulse=\(pulseLevel) restore=\(restoreLevel)")
        for cycle in 0..<count {
            let kr = call(2, [0, pulseLevel])
            if cycle == 0 && kr == nil {
                return
            }
            Thread.sleep(forTimeInterval: gap)
            let kr2 = call(2, [0, restoreLevel])
            if cycle == 0 {
                FlashDiagnostics.note("flash: backlight [AppleLMUController] first write=\(kr2 == nil ? "FAILED" : "ok")")
            }
            Thread.sleep(forTimeInterval: gap)
        }
        let final = call(2, [0, restoreLevel])
        if final == nil {
            FlashDiagnostics.note("flash: backlight [AppleLMUController] FINAL restore FAILED — may be left at pulse level")
        } else {
            FlashDiagnostics.note("flash: backlight [AppleLMUController] done — \(count) pulse(s) sent, level restored")
        }
    }

    /// HID elements on `keyboard` with the given page and usage (any type).
    private static func matchingElements(on keyboard: IOHIDDevice, page: Int, usage: Int) -> [IOHIDElement] {
        let matching: [String: Any] = [
            kIOHIDElementUsagePageKey as String: page,
            kIOHIDElementUsageKey as String: usage
        ]
        let result = IOHIDDeviceCopyMatchingElements(
            keyboard, matching as CFDictionary, IOOptionBits(kIOHIDOptionsTypeNone)
        ) as? [IOHIDElement]
        return result ?? []
    }

    /// Writes an integer value to an element on `keyboard` and returns the
    /// IOKit status code (`kIOReturnSuccess` == 0 on success) so callers can
    /// log whether the device actually accepted the write.
    @discardableResult
    private static func setElement(keyboard: IOHIDDevice, element: IOHIDElement, value: Int) -> IOReturn {
        let newValue = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, value)
        return IOHIDDeviceSetValue(keyboard, element, newValue)
    }
}
#endif
