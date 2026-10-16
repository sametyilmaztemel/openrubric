#if os(macOS)
import AppKit
import Darwin
import ObjectiveC
import OpenRubricCore

/// Runtime bridge to CoreBrightness.framework's private `KeyboardBrightnessClient`
/// — the same path System Settings uses to move the keyboard-backlight slider on
/// **both** Apple Silicon and Intel.
///
/// There is no public API for keyboard-backlight control. On Apple Silicon the
/// actual PWM hardware is owned by `corebrightnessd` (`AppleARMPWMDevice`) and it
/// *ignores* the IOKit `KeyboardBacklightBrightness` property (that property is a
/// state mirror, not a control register). Intel's old `AppleLMUController` service
/// simply does not exist on Apple Silicon. CoreBrightness is the one unprivileged
/// call that reaches the LED on both architectures (kblight, KBPulse, kbdlight and
/// the KeyboardBacklightToggle all use it), so it is our primary path; the
/// `AppleLMUController` path is kept as an Intel fallback.
///
/// Methods are resolved with the ObjC runtime and invoked through their IMPs
/// (plain `@convention(c)` 8-byte function pointers) because several take
/// primitive `float` / `UInt64` arguments that `perform:` cannot pass. Everything
/// is best-effort and nil-safe: an absent framework or class just yields `nil`s
/// and the caller falls back to the Intel path.
enum CoreBrightness {
    /// dlopen'd image handle, kept alive for the process lifetime.
    private static var handle: UnsafeMutableRawPointer?

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"

    // Resolved exactly once (on the flash queue). The IMPs are `@convention(c)`
    // function pointers (8 bytes), matching the ABI the runtime returns — NOT
    // Swift closures (16 bytes), which is what trapped the v0.5.4 CoreDisplay
    // bitcast.
    private static var clientClass: AnyClass?
    private static var copyIDs: (@convention(c) (AnyObject, Selector) -> Unmanaged<NSArray>)?
    private static var isBuiltIn: (@convention(c) (AnyObject, Selector, UInt64) -> ObjCBool)?
    private static var getBrightness: (@convention(c) (AnyObject, Selector, UInt64) -> Float)?
    private static var setBrightness: (@convention(c) (AnyObject, Selector, Float, UInt64) -> ObjCBool)?
    private static var instance: AnyObject?
    private static var resolved = false

    /// Loads the framework and resolves `KeyboardBrightnessClient`'s methods.
    /// Returns true when the client is usable. Safe to call repeatedly; runs on
    /// the caller's (serial) queue so `resolved` needs no synchronization.
    static func resolve() -> Bool {
        guard !resolved else { return clientClass != nil }
        resolved = true

        if handle == nil {
            handle = dlopen(frameworkPath, RTLD_LAZY)
        }
        guard let cls: AnyClass = NSClassFromString("KeyboardBrightnessClient") else {
            return false
        }
        clientClass = cls

        func imp(_ selector: String) -> UnsafeMutableRawPointer? {
            guard let method = class_getInstanceMethod(cls, Selector(selector)) else { return nil }
            return method_getImplementation(method)
        }
        if let i = imp("copyKeyboardBacklightIDs") {
            copyIDs = unsafeBitCast(i, to: (@convention(c) (AnyObject, Selector) -> Unmanaged<NSArray>).self)
        }
        if let i = imp("isKeyboardBuiltIn:") {
            isBuiltIn = unsafeBitCast(i, to: (@convention(c) (AnyObject, Selector, UInt64) -> ObjCBool).self)
        }
        if let i = imp("brightnessForKeyboard:") {
            getBrightness = unsafeBitCast(i, to: (@convention(c) (AnyObject, Selector, UInt64) -> Float).self)
        }
        if let i = imp("setBrightness:forKeyboard:") {
            setBrightness = unsafeBitCast(i, to: (@convention(c) (AnyObject, Selector, Float, UInt64) -> ObjCBool).self)
        }

        // Standard alloc/init through the runtime (the class has a plain -init).
        if let alloc = cls.perform(Selector(("alloc"))) as AnyObject? {
            if let initialized = alloc.perform(Selector(("init"))) as AnyObject? {
                instance = initialized
            }
        }
        return instance != nil && copyIDs != nil && setBrightness != nil
    }

    /// IDs of the backlit keyboards the system reports (`UInt64`). Empty when
    /// there is no built-in backlit keyboard or the class is unavailable.
    static func keyboardIDs() -> [UInt64] {
        guard let ids = copyIDs, let obj = instance else { return [] }
        // `copy…` returns +1, so consume the reference with takeRetainedValue.
        let arr = ids(obj, Selector(("copyKeyboardBacklightIDs"))).takeRetainedValue()
        return arr.compactMap { ($0 as? NSNumber)?.uint64Value }
    }

    static func isBuiltIn(_ id: UInt64) -> Bool {
        guard let fn = isBuiltIn, let obj = instance else { return false }
        return fn(obj, Selector(("isKeyboardBuiltIn:")), id).boolValue
    }

    /// Current backlight level (0...1) for `id`, or nil on failure.
    static func getBrightness(_ id: UInt64) -> Float? {
        guard let fn = getBrightness, let obj = instance else { return nil }
        return fn(obj, Selector(("brightnessForKeyboard:")), id)
    }

    /// Writes a 0...1 level and returns the value read back, so the caller can
    /// verify the write actually moved the hardware (the CoreBrightness property
    /// can be a state mirror on some OS versions). Returns nil when the write
    /// was rejected.
    @discardableResult
    static func setBrightness(_ id: UInt64, _ level: Float) -> Float? {
        guard let fn = setBrightness, let obj = instance else { return nil }
        let ok = fn(obj, Selector(("setBrightness:forKeyboard:")), level, id).boolValue
        guard ok else { return nil }
        return getBrightness(id)
    }
}
#endif
