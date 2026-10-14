#if os(macOS)
import AppKit
import IOKit
import IOKit.hid

/// Keyboard output channels driven through IOKit HID.
///
/// Both are best-effort: a keyboard without the relevant LED element or a
/// controllable brightness element simply doesn't react. Nothing here
/// throws — a missing keyboard or unsupported element is a no-op, not an
/// error (the issue marks LED/backlight as "depends on keyboard support").
///
/// The Caps Lock channel writes the blink count as the LED value (0 = off,
/// 1 = on, 2+ = blink that many times; the keyboard hardware then resets
/// it to its steady state). The backlight channel pulses a brightness
/// element to 0 and restores it `count` times.
final class KeyboardFlasher: @unchecked Sendable {
    /// Serial queue so overlapping answer cycles can't interleave HID
    /// writes on the same elements.
    private let queue = DispatchQueue(label: "openrubric.keyboard")
    /// Seconds a pulse stays "off" before returning to the original value.
    private let pulseGap: Double

    init(pulseGap: Double = 0.25) {
        self.pulseGap = pulseGap
    }

    /// Blinks the Caps Lock LED `count` times (A=1 ...).
    func flashCapsLock(count: Int) {
        queue.async {
            for keyboard in Self.keyboards() {
                Self.setLED(keyboard: keyboard, usage: kHIDUsage_LED_CapsLock, value: UInt32(count))
            }
        }
    }

    /// Pulses the keyboard backlight to 0 and restores it, `count` times.
    func flashBacklight(count: Int) {
        queue.async {
            for keyboard in Self.keyboards() {
                Self.pulseBrightness(keyboard: keyboard, times: count, gap: self.pulseGap)
            }
        }
    }

    // MARK: - HID internals

    /// All keyboards currently attached (GenericDesktop page, Keyboard usage).
    private static func keyboards() -> [IOHIDDeviceRef] {
        let manager = IOHIDManagerCreate(
            kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone)
        )
        guard let manager else { return [] }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        let matching: [CFString: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        guard let set = IOHIDManagerCopyDevices(manager) else { return [] }
        defer { CFRelease(set) }
        let count = Int(CFSetGetCount(set))
        guard count > 0 else { return [] }
        var buffer = [CFTypeRef?](repeating: nil, count: count)
        buffer.withUnsafeMutableBufferPointer {
            CFSetGetValues(set, $0.baseAddress)
        }
        return buffer.compactMap { $0 as? IOHIDDeviceRef }
    }

    /// Sets one LED element on a keyboard device to `value`.
    private static func setLED(keyboard: IOHIDDeviceRef, usage: UInt32, value: UInt32) {
        guard let element = firstElement(
            keyboard: keyboard,
            usagePage: kHIDPage_LEDs,
            usage: usage,
            type: kIOHIDElementTypeOutput
        ) else { return }

        guard let newValue = IOHIDValueCreateWithIntegerValue(
            kCFAllocatorDefault, element, 0, Int64(value)
        ) else { return }
        defer { CFRelease(newValue) }
        _ = IOHIDDeviceSetValue(keyboard, element, newValue)
    }

    /// Pulses the keyboard brightness element to 0 and restores it.
    private static func pulseBrightness(keyboard: IOHIDDeviceRef, times: Int, gap: Double) {
        // Brightness is exposed as a GenericDesktop attribute/output on
        // keyboards that support it (usage 0x6F). Some hardware only
        // exposes it through the private CoreBrightness framework — those
        // simply have no matching element and are skipped.
        guard let element = firstElement(
            keyboard: keyboard,
            usagePage: kHIDPage_GenericDesktop,
            usage: kHIDUsage_GD_KeyboardBrightness,
            type: kIOHIDElementTypeAttribute
        ) ?? firstElement(
            keyboard: keyboard,
            usagePage: kHIDPage_GenericDesktop,
            usage: kHIDUsage_GD_KeyboardBrightness,
            type: kIOHIDElementTypeOutput
        ) else { return }

        var currentValue: IOHIDValueRef?
        _ = IOHIDDeviceGetValue(keyboard, element, &currentValue)
        guard let current = currentValue else { return }
        defer { CFRelease(current) }
        let original = IOHIDValueGetIntegerValue(current)

        for _ in 0..<times {
            setElement(keyboard: keyboard, element: element, value: 0)
            Thread.sleep(forTimeInterval: gap)
        }
        setElement(keyboard: keyboard, element: element, value: original)
    }

    /// The first HID element on `keyboard` with the given page/usage/type.
    private static func firstElement(
        keyboard: IOHIDDeviceRef,
        usagePage: UInt32,
        usage: UInt32,
        type: Int
    ) -> IOHIDElementRef? {
        let matching: [CFString: Any] = [
            kIOHIDElementUsagePageKey: usagePage,
            kIOHIDElementUsageKey: usage,
            kIOHIDElementTypeKey: type
        ]
        guard let elements = IOHIDDeviceCopyMatchingElements(
            keyboard, matching as CFDictionary, IOOptionBits(kIOHIDOptionsTypeNone)
        ) else { return nil }
        defer { CFRelease(elements) }
        guard CFArrayGetCount(elements) > 0,
              let ptr = CFArrayGetValueAtIndex(elements, 0) else { return nil }
        return IOHIDElementRef(ptr)
    }

    private static func setElement(keyboard: IOHIDDeviceRef, element: IOHIDElementRef, value: Int64) {
        guard let newValue = IOHIDValueCreateWithIntegerValue(
            kCFAllocatorDefault, element, 0, value
        ) else { return }
        defer { CFRelease(newValue) }
        _ = IOHIDDeviceSetValue(keyboard, element, newValue)
    }
}
