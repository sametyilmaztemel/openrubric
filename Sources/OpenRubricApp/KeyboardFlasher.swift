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
    /// The LED is an on/off element, so "blink N times" is a pulse loop
    /// (on -> off -> on -> off ...), not a single value write: a one-shot
    /// write of the count clamps to the element's max of 1 and leaves the
    /// LED lit instead of flashing. The resting state is read first and
    /// restored afterwards, so a cycle never leaves Caps Lock on.
    func flashCapsLock(count: Int) {
        queue.async {
            let keyboards = Self.keyboards()
            FlashDiagnostics.note("flash: capsLock count=\(count) keyboards=\(keyboards.count)")
            for keyboard in keyboards {
                Self.blinkCapsLock(keyboard: keyboard, count: count, gap: self.pulseGap)
            }
        }
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
    private static func blinkCapsLock(keyboard: IOHIDDevice, count: Int, gap: Double) {
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

    /// Pulses the keyboard backlight, `count` times, restoring the original
    /// level afterwards.
    ///
    /// The built-in keyboard's HID backlight element cannot be read reliably
    /// (`readElement FAILED` — the element is an output element and its
    /// "value" is managed by the LMU firmware), so the pulse is driven through
    /// the **`AppleLMUController`** IOKit service instead (the same path used
    /// by keyboardparty / maclight / macbook-brightness, all of which work on
    /// Intel Macs):
    ///   - selector 1 = get current LED brightness (0...0xFFF on 12-bit
    ///     hardware; the read value is the scale ceiling);
    ///   - selector 2 = set LED brightness (input [0, level]).
    /// The current level is read first so it can be restored after the
    /// pulse; a level of 0 means the backlight is off and the pulse blips up
    /// to a minimum visible level and back. When `AppleLMUController` is
    /// absent (e.g. an external-only setup) the channel no-ops and the log
    /// says why. External RGB keyboards (Logitech etc.) are not driven here.
    private static func pulseBacklight(count: Int, gap: Double) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleLMUController"))
        guard service != 0 else {
            FlashDiagnostics.note("flash: backlight AppleLMUController NOT FOUND — skipped")
            return
        }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        let openStatus = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard openStatus == KERN_SUCCESS else {
            FlashDiagnostics.note("flash: backlight IOServiceOpen FAILED status=\(openStatus) — skipped")
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
                FlashDiagnostics.note("flash: backlight selector=\(selector) IOConnectCallScalarMethod FAILED status=\(kr)")
                return nil
            }
            return output
        }

        guard let originalRaw = call(1, [0]) else { return }
        let scale = Int(max(originalRaw, 1))
        let blip = UInt64(FlashMath.backlightPulseLevel(maxValue: scale))
        let (pulseLevel, restoreLevel): (UInt64, UInt64)
        if originalRaw > 0 {
            // Backlight on: dim to 0, restore the original level.
            pulseLevel = 0
            restoreLevel = originalRaw
        } else {
            // Backlight off: blip up to a minimum visible level, back to 0.
            pulseLevel = blip
            restoreLevel = 0
        }
        if pulseLevel == restoreLevel {
            FlashDiagnostics.note("flash: backlight pulse not visible (original=\(originalRaw)) — skipped")
            return
        }
        FlashDiagnostics.note("flash: backlight count=\(count) original=\(originalRaw) pulse=\(pulseLevel) restore=\(restoreLevel)")
        for cycle in 0..<count {
            let kr = call(2, [0, pulseLevel])
            if cycle == 0 && kr == nil { return }
            Thread.sleep(forTimeInterval: gap)
            let kr2 = call(2, [0, restoreLevel])
            if cycle == 0 {
                FlashDiagnostics.note("flash: backlight first write=\(kr2 == nil ? "FAILED" : "ok")")
            }
            Thread.sleep(forTimeInterval: gap)
        }
        FlashDiagnostics.note("flash: backlight done — \(count) pulse(s) sent")
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
