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
            for keyboard in Self.keyboards() {
                Self.blinkCapsLock(keyboard: keyboard, count: count, gap: self.pulseGap)
            }
        }
    }

    /// Pulses the keyboard backlight, `count` times.
    func flashBacklight(count: Int) {
        queue.async {
            for keyboard in Self.keyboards() {
                Self.pulseBacklight(keyboard: keyboard, count: count, gap: self.pulseGap)
            }
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
        _ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

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
        guard !elements.isEmpty else { return }
        for element in elements {
            let resting = readElement(keyboard: keyboard, element: element) ?? 0
            // Clamp to the element's logical max so no out-of-range write is
            // ever sent (a max-0 LED can't show "on", so the blink is
            // invisible on such hardware — same as before).
            let maxValue = Int(IOHIDElementGetLogicalMax(element))
            let inverse = FlashMath.clampedBlinkCount(resting == 0 ? 1 : 0, maxValue: maxValue)
            let restore = FlashMath.clampedBlinkCount(resting, maxValue: maxValue)
            for _ in 0..<count {
                setElement(keyboard: keyboard, element: element, value: inverse)
                Thread.sleep(forTimeInterval: gap)
                setElement(keyboard: keyboard, element: element, value: restore)
                Thread.sleep(forTimeInterval: gap)
            }
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
    /// Backlight elements appear in different shapes depending on the
    /// hardware, so several page/usage pairs are probed in order (the ordered
    /// candidate list lives in `FlashMath.backlightCandidates`, which is unit
    /// tested). The first candidate that matches an element wins. The two
    /// levels of a pulse are decided by `FlashMath.backlightPulse`:
    ///   - backlight on  -> dim to 0, restore to the original level;
    ///   - backlight off -> blip up to a minimum visible level, back to 0.
    /// Both are clamped to the element's maximum value, so no out-of-range
    /// write is ever sent.
    private static func pulseBacklight(keyboard: IOHIDDevice, count: Int, gap: Double) {
        // Look candidates up in order and stop at the first one that matches
        // an element (early break: built-in keyboards hit the Apple vendor
        // page first, so the common case is a single lookup). The "first
        // non-empty wins" selection is still the pure, unit-tested policy.
        var found: [[IOHIDElement]] = []
        for candidate in FlashMath.backlightCandidates {
            let elements = matchingElements(on: keyboard, page: candidate.page, usage: candidate.usage)
            found.append(elements)
            if !elements.isEmpty { break }
        }
        guard let index = FlashMath.firstMatchingCandidateIndex(found.map(\.count)),
              let element = found[index].first else { return }

        // Read the current level so it can be restored after the pulse; a
        // failed read means we cannot restore, so skip (best-effort channel).
        guard let original = readElement(keyboard: keyboard, element: element) else { return }

        let maxValue = Int(IOHIDElementGetLogicalMax(element))
        let pulseLevel = FlashMath.backlightPulseLevel(maxValue: maxValue)
        guard FlashMath.backlightPulseVisible(original: original, maxValue: maxValue, pulseLevel: pulseLevel) else {
            return
        }
        let levels = FlashMath.backlightPulse(original: original, maxValue: maxValue, pulseLevel: pulseLevel)

        for _ in 0..<count {
            setElement(keyboard: keyboard, element: element, value: levels.set)
            Thread.sleep(forTimeInterval: gap)
            setElement(keyboard: keyboard, element: element, value: levels.restore)
            Thread.sleep(forTimeInterval: gap)
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

    /// Writes an integer value to an element on `keyboard`.
    private static func setElement(keyboard: IOHIDDevice, element: IOHIDElement, value: Int) {
        let newValue = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, value)
        _ = IOHIDDeviceSetValue(keyboard, element, newValue)
    }
}
#endif
