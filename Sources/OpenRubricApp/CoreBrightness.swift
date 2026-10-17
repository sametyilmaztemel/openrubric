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
///
/// All mutable state lives in a single immutable `static let` box (`State`),
/// which is `@unchecked Sendable`: the box reference is a `let` (so it is
/// concurrency-safe shared state), and its contents are written exactly once by
/// `resolve()` and thereafter only read — all on the caller's serial flash
/// queue, so the internal `var`s need no locking. This is the standard
/// "immutable handle to a synchronized box" pattern and is what lets this file
/// build under Swift 6's strict concurrency checking.
enum CoreBrightness {
    /// The resolved, immutable state box. A `let` of an `@unchecked Sendable`
    /// reference type is fine as nonisolated global shared state.
    private static let state = State()

    /// Framework image path (a constant — `let` is concurrency-safe).
    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"

    /// Mutable resolution state, boxed so the enclosing `static let state` is an
    /// immutable (concurrency-safe) reference. Only `resolve()` writes to it, and
    /// it runs on the serial flash queue; everything after is read-only.
    private final class State: @unchecked Sendable {
        /// dlopen'd image handle, kept alive for the process lifetime.
        var handle: UnsafeMutableRawPointer?
        /// `KeyboardBrightnessClient` class, or nil when unavailable.
        var clientClass: AnyClass?
        // The IMPs are `@convention(c)` function pointers (8 bytes), matching the
        // ABI the runtime returns — NOT Swift closures (16 bytes), which is what
        // trapped the v0.5.4 CoreDisplay bitcast.
        var copyIDs: (@convention(c) (AnyObject, Selector) -> Unmanaged<NSArray>)?
        var isBuiltIn: (@convention(c) (AnyObject, Selector, UInt64) -> ObjCBool)?
        var getBrightness: (@convention(c) (AnyObject, Selector, UInt64) -> Float)?
        var setBrightness: (@convention(c) (AnyObject, Selector, Float, UInt64) -> ObjCBool)?
        /// A live `KeyboardBrightnessClient` instance (alloc/init).
        var instance: AnyObject?
        /// Guards `resolve()` from running more than once.
        var resolved = false
    }

    /// Runs `body` on the main thread and returns its result.
    ///
    /// The `KeyboardBrightnessClient` instance is a private CoreBrightness
    /// object that is **not** safe to touch from a pooled GCD worker thread —
    /// on the user's Apple Silicon x13 the second answer (delivered from a
    /// different worker thread) SEGV'd inside `-[KeyboardBrightnessClient
    /// copyKeyboardBacklightIDs]`. Confining every instance IMP call to the
    /// main thread fixes it. The callers (flasher serial queues) are never the
    /// main thread, so a `main.sync` hop is deadlock-free; the `isMainThread`
    /// guard makes nested hops (setBrightness → getBrightness) run inline.
    private static func onMain<T>(_ body: @escaping () -> T) -> T {
        if Thread.isMainThread {
            return body()
        }
        return DispatchQueue.main.sync(execute: body)
    }

    /// Loads the framework and resolves `KeyboardBrightnessClient`'s methods.
    /// Returns true when the client is usable. Safe to call repeatedly; runs on
    /// the caller's (serial) queue, so the `resolved` flag needs no sync.
    static func resolve() -> Bool {
        guard !state.resolved else { return state.clientClass != nil }
        state.resolved = true

        if state.handle == nil {
            state.handle = dlopen(frameworkPath, RTLD_LAZY)
        }
        guard let cls: AnyClass = NSClassFromString("KeyboardBrightnessClient") else {
            return false
        }
        state.clientClass = cls

        func imp(_ selector: String) -> UnsafeMutableRawPointer? {
            guard let method = class_getInstanceMethod(cls, Selector(selector)) else { return nil }
            // method_getImplementation returns an IMP (OpaquePointer); wrap it
            // in UnsafeMutableRawPointer so the unsafeBitCast below has a
            // concrete 8-byte source type.
            return UnsafeMutableRawPointer(method_getImplementation(method))
        }
        if let i = imp("copyKeyboardBacklightIDs") {
            state.copyIDs = unsafeBitCast(i, to: (@convention(c) (AnyObject, Selector) -> Unmanaged<NSArray>).self)
        }
        if let i = imp("isKeyboardBuiltIn:") {
            state.isBuiltIn = unsafeBitCast(i, to: (@convention(c) (AnyObject, Selector, UInt64) -> ObjCBool).self)
        }
        if let i = imp("brightnessForKeyboard:") {
            state.getBrightness = unsafeBitCast(i, to: (@convention(c) (AnyObject, Selector, UInt64) -> Float).self)
        }
        if let i = imp("setBrightness:forKeyboard:") {
            state.setBrightness = unsafeBitCast(i, to: (@convention(c) (AnyObject, Selector, Float, UInt64) -> ObjCBool).self)
        }

        // Standard alloc/init through the runtime (the class has a plain -init).
        // `cls` is a metatype (AnyClass); the class object is viewed as AnyObject
        // to send +alloc, then -init. `perform` returns the ObjC result as an
        // Unmanaged +1 reference, so takeRetainedValue() consumes it correctly
        // (a bare `as AnyObject?` would store the Unmanaged box, not the object).
        //
        // The alloc/init of the client is also confined to the main thread: the
        // object must be created and used on the same thread it is safe on, so
        // creating it on main and never touching it off-main keeps it stable.
        // `cls` is captured (a class reference is Sendable) so the closure only
        // holds Sendable values under Swift 6 strict concurrency.
        let instance = onMain { () -> AnyObject? in
            let clsInstance = cls as AnyObject
            guard let allocUnmanaged = clsInstance.perform(Selector("alloc")) else { return nil }
            let allocObj = allocUnmanaged.takeRetainedValue()
            guard let initUnmanaged = allocObj.perform(Selector("init")) else { return nil }
            return initUnmanaged.takeRetainedValue()
        }
        state.instance = instance
        return state.instance != nil && state.copyIDs != nil && state.setBrightness != nil
    }

    /// IDs of the backlit keyboards the system reports (`UInt64`). Empty when
    /// there is no built-in backlit keyboard or the class is unavailable.
    static func keyboardIDs() -> [UInt64] {
        // Only the Sendable `state` box is captured, so the main-thread hop is
        // clean under Swift 6 strict concurrency.
        let arr: NSArray = onMain {
            guard let ids = state.copyIDs, let obj = state.instance else { return [] }
            // `copy…` returns +1, so consume the reference with takeRetainedValue.
            return ids(obj, Selector(("copyKeyboardBacklightIDs"))).takeRetainedValue()
        }
        return arr.compactMap { ($0 as? NSNumber)?.uint64Value }
    }

    static func isBuiltIn(_ id: UInt64) -> Bool {
        onMain {
            guard let fn = state.isBuiltIn, let obj = state.instance else { return false }
            return fn(obj, Selector(("isKeyboardBuiltIn:")), id).boolValue
        }
    }

    /// Current backlight level (0...1) for `id`, or nil on failure.
    static func getBrightness(_ id: UInt64) -> Float? {
        onMain {
            guard let fn = state.getBrightness, let obj = state.instance else { return nil }
            return fn(obj, Selector(("brightnessForKeyboard:")), id)
        }
    }

    /// Writes a 0...1 level and returns the value read back, so the caller can
    /// verify the write actually moved the hardware (the CoreBrightness property
    /// can be a state mirror on some OS versions). Returns nil when the write
    /// was rejected. The whole sequence (set + read-back) is confined to the
    /// main thread so the set and its verification hit the same thread context.
    @discardableResult
    static func setBrightness(_ id: UInt64, _ level: Float) -> Float? {
        onMain {
            guard let fn = state.setBrightness, let obj = state.instance else { return nil }
            let ok = fn(obj, Selector(("setBrightness:forKeyboard:")), level, id).boolValue
            guard ok else { return nil }
            guard let get = state.getBrightness else { return nil }
            return get(obj, Selector(("brightnessForKeyboard:")), id)
        }
    }
}
#endif
