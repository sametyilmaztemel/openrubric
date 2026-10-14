#if os(macOS)
import AppKit
import IOKit
import IOKit.hid

// MARK: - Apple vendor page constants
//
// Apple's built-in keyboards expose backlight through the vendor page
// (0xFF00) rather than a standard HID usage, and these constants are
// not shipped in the public headers (AppleHIDUsageTables.h is blank
// since 10.14), so they are declared locally.
private let appleVendorPage: UInt32 = 0xFF00
private let topCaseUsage: UInt32 = 0x01          // TopCase collection
private let keyboardBacklightUsage: UInt32 = 0x0F // KeyboardBacklight collection

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
    ///
    /// Backlight elements show up in different shapes depending on the
    /// hardware, so several element shapes are tried in order:
    ///   - GenericDesktop 0x6F (some third-party HID keyboards)
    ///   - Consumer page 0x79/0x7A increment/decrement
    ///   - Apple vendor page: TopCase 0x01 (built-in MacBook keyboards)
    ///     and KeyboardBacklight 0x0F — these live on the vendor page
    ///     (0xFF00) and are not in the public HID usage tables, so the
    ///     constants are local.
    /// A keyboard exposing none of these simply doesn't pulse.
    private static func pulseBrightness(keyboard: IOHIDDeviceRef, times: Int, gap: Double) {
        let candidates: [(page: UInt32, usage: UInt32, type: Int)] = [
            // Built-in MacBook keyboards (Apple vendor page).
            (appleVendorPage, keyboardBacklightUsage, kIOHIDElementTypeFeature),
            (appleVendorPage, keyboardBacklightUsage, kIOHIDElementTypeOutput),
            (appleVendorPage, topCaseUsage, kIOHIDElementTypeFeature),
            (appleVendorPage, topCaseUsage, kIOHIDElementTypeOutput),
            // Some third-party HID keyboards.
            (kHIDPage_Consumer, kHIDUsage_Csmr_KeyboardBrightnessIncrement, kIOHIDElementTypeFeature),
            // 0x6F is not a standard GenericDesktop usage; some third-party
            // keyboards nonetheless expose brightness there, so it costs
            // nothing to try.
            (kHIDPage_GenericDesktop, 0x6F, kIOHIDElementTypeFeature),
            (kHIDPage_GenericDesktop, 0x6F, kIOHIDElementTypeOutput)
        ]
        guard let element = candidates.lazy.compactMap {
            firstElement(keyboard: keyboard, usagePage: $0.page, usage: $0.usage, type: $0.type)
        }.first else { return }

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
