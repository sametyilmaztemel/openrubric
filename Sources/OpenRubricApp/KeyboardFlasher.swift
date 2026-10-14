#if os(macOS)
import AppKit
import IOKit
import IOKit.hid

// MARK: - Apple vendor page constants
//
// Apple built-in keyboards expose the backlight through a vendor page
// (0xFF00) rather than a standard HID usage. These constants are not in
// the public headers (AppleHIDUsageTables.h has been empty since 10.14),
// so they are declared locally.
private let appleVendorPage = 0xFF00
private let topCaseUsage = 0x01
private let keyboardBacklightUsage = 0x0F

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
    private static func writeCapsLock(keyboard: IOHIDDevice, count: Int) {
        let elements = matchingElements(on: keyboard, page: kHIDPage_LEDs, usage: kHIDUsage_LED_CapsLock)
        for element in elements {
            setElement(keyboard: keyboard, element: element, value: count)
        }
    }

    /// Pulses the keyboard backlight, `count` times, restoring the original
    /// level afterwards.
    ///
    /// Backlight elements appear in different shapes depending on the
    /// hardware, so several page/usage pairs are tried in order and the first
    /// that yields an element is used:
    ///   - Apple vendor page (0xFF00): KeyboardBacklight (0x0F) / TopCase
    ///     (0x01) - built-in MacBook keyboards.
    ///   - Consumer page brightness (0x79 / 0x7A) - some third-party.
    ///   - GenericDesktop 0x6F - a non-standard slot some keyboards use.
    private static func pulseBacklight(keyboard: IOHIDDevice, count: Int, gap: Double) {
        let candidates: [(page: Int, usage: Int)] = [
            (appleVendorPage, keyboardBacklightUsage),
            (appleVendorPage, topCaseUsage),
            (kHIDPage_Consumer, 0x79),
            (kHIDPage_Consumer, 0x7A),
            (kHIDPage_GenericDesktop, 0x6F)
        ]
        var element: IOHIDElement?
        for c in candidates {
            let found = matchingElements(on: keyboard, page: c.page, usage: c.usage)
            if let first = found.first {
                element = first
                break
            }
        }
        guard let element else { return }

        // Read the current level so it can be restored after the pulse.
        // The placeholder value is bound to a local so ARC keeps it alive
        // across the read, exactly as in the reference implementation.
        let placeholderValue = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, 0)
        var placeholder = Unmanaged.passUnretained(placeholderValue)
        let got = IOHIDDeviceGetValue(keyboard, element, &placeholder)
        guard got == kIOReturnSuccess else { return }
        let original = Int(IOHIDValueGetIntegerValue(placeholder.takeUnretainedValue()))

        for _ in 0..<count {
            setElement(keyboard: keyboard, element: element, value: 0)
            Thread.sleep(forTimeInterval: gap)
            setElement(keyboard: keyboard, element: element, value: original)
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
