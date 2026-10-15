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
    private var hotKeyRefPreview: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    /// Invoked on the main thread when the primary hotkey fires.
    var onFire: (@MainActor () -> Void)?
    /// Invoked on the main thread when the preview hotkey fires.
    var onPreview: (@MainActor () -> Void)?

    /// Default: ⌃⌥⌘A.
    static let defaultKeyCode: UInt32 = UInt32(kVK_ANSI_A)
    static let defaultModifiers: UInt32 = UInt32(controlKey | optionKey | cmdKey)
    /// Default preview (⌃⌥⌘P): show the cursor-centred crop without asking.
    static let previewKeyCode: UInt32 = UInt32(kVK_ANSI_P)
    static let previewModifiers: UInt32 = UInt32(controlKey | optionKey | cmdKey)

    func start(
        keyCode: UInt32 = defaultKeyCode, modifiers: UInt32 = defaultModifiers,
        previewKeyCode: UInt32 = Self.previewKeyCode, previewModifiers: UInt32 = Self.previewModifiers
    ) {
        stop()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                // Route by the registered id: 1 = answer, 2 = preview.
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
                )
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard status == noErr else { return }
                        if hotKeyID.id == 2 { manager.onPreview?() } else { manager.onFire?() }
                    }
                }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        // Signature 'ORBC' identifies our hotkeys (id 1 = answer, id 2 = preview).
        _ = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x4F524243), id: 1), GetApplicationEventTarget(), 0, &hotKeyRef)
        _ = RegisterEventHotKey(previewKeyCode, previewModifiers, EventHotKeyID(signature: OSType(0x4F524243), id: 2), GetApplicationEventTarget(), 0, &hotKeyRefPreview)
    }

    func stop() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        if let hotKeyRefPreview { UnregisterEventHotKey(hotKeyRefPreview); self.hotKeyRefPreview = nil }
        if let eventHandler { RemoveEventHandler(eventHandler); self.eventHandler = nil }
    }

    deinit { stop() }
}

#endif
