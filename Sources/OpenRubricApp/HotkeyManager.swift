#if os(macOS)
import AppKit
import Carbon

/// Global hotkey via Carbon's `RegisterEventHotKey` — the only reliable
/// way to get a system-wide shortcut without an event tap.
///
/// Default binding: ⌃⌥⌘A (control + option + command + A).
///
/// `@unchecked Sendable`: the C event callback hands the manager back on
/// the main queue, and `start`/`stop` are only ever called from the
/// main actor, so no lock is needed.
final class HotkeyManager: @unchecked Sendable {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    /// Invoked on the main thread when the hotkey fires.
    var onFire: (@MainActor () -> Void)?

    /// Default: ⌃⌥⌘A.
    static let defaultKeyCode: UInt32 = UInt32(kVK_ANSI_A)
    static let defaultModifiers: UInt32 = UInt32(controlKey | optionKey | commandKey)

    func start(keyCode: UInt32 = Self.defaultKeyCode, modifiers: UInt32 = Self.defaultModifiers) {
        stop()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { manager.onFire?() }
                }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        // Signature 'ORBC' identifies our hotkey.
        let hotKeyID = EventHotKeyID(signature: OSType(0x4F524243), id: 1)
        _ = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func stop() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        if let eventHandler { RemoveEventHandler(eventHandler); self.eventHandler = nil }
    }

    deinit { stop() }
}

#endif
