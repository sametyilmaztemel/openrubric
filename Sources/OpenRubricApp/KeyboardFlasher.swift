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
/// does not react, and nothing here throws. The Caps Lock channel writes
/// the blink count as the LED value (0 = off, 1 = on, 2+ = blink that many
/// times, after which the keyboard hardware returns to its steady state).
/// The backlight channel pulses a brightness element and restores it.
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
    func flashCapsLock(count: Int) {
        queue.async {
            for keyboard in Self.keyboards() {
                Self.writeCapsLock(keyboard: keyboard, count: count)
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

    /// Blinks every Caps Lock LED element on `keyboard` to `count`.
    ///
    /// A Caps Lock LED is normally an Output element on the LEDs page; some
    /// keyboards expose it as a Feature. Matching on page+usage returns every
    /// such element regardless of type, and writing the value to each is the
    /// same thing a working reference implementation does, so no type filter
    /// is needed.
    ///
    /// The count is clamped to the element's reported maximum
    /// (`IOHIDElementGetLogicalMax`) before the write: a Z (26) answer
    /// would otherwise be out of range for driver stacks that reject
    /// writes above the element's max, so clamping preserves the blink intent
    /// without an out-of-range write.
    private static func writeCapsLock(keyboard: IOHIDDevice, count: Int) {
        let elements = matchingElements(on: keyboard, page: kHIDPage_LEDs, usage: kHIDUsage_LED_CapsLock)
        for element in elements {
            let maxValue = Int(IOHIDElementGetLogicalMax(element))
            let clamped = FlashMath.clampedBlinkCount(count, maxValue: maxValue)
            setElement(keyboard: keyboard, element: element, value: clamped)
        }
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

        // Read the current level so it can be restored after the pulse.
        // The placeholder value is bound to a local so ARC keeps it alive
        // across the read. IOHIDDeviceGetValue fills the out-param with the
        // element's current value, but the public header does not state
        // whether it writes a new retained (+1) object or reuses the pointer
        // we passed. To be safe under both interpretations we compare the
        // pointer after the call: if it differs from our placeholder, the
        // call handed us a new reference we must release; if it is the same,
        // ARC already owns the placeholder and releasing it would be a
        // double-free.
        let placeholderValue = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, 0)
        var placeholder = Unmanaged.passUnretained(placeholderValue)
        let got = IOHIDDeviceGetValue(keyboard, element, &placeholder)
        guard got == kIOReturnSuccess else { return }
        let returned = placeholder.takeUnretainedValue()
        let original = Int(IOHIDValueGetIntegerValue(returned))
        if Unmanaged.passUnretained(returned).toOpaque() != Unmanaged.passUnretained(placeholderValue).toOpaque() {
            // GetValue installed a different, caller-owned value: take
            // ownership (balanced +1/-1) and release it now that the
            // integer has been read. If it reused our placeholder instead,
            // ARC owns that object and we must not release it here.
            Unmanaged.passUnretained(returned).release()
        }

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
