#if os(macOS)
import AppKit
import QuartzCore
import OpenRubricCore

/// Edge Light channel: a bright, glowing border around the main display,
/// toggled on/off `count` times — the FaceTime "Edge Light" ring-light look,
/// reproduced as an overlay so it works on any macOS version and any display
/// (the native Edge Light API, AVCaptureDevice.isEdgeLightActive, is read-only
/// and macOS 26.2+ and only shows while the camera is active in a call).
///
/// The overlay is a borderless, click-through, floating window whose content
/// is a layer that draws a thick white glow along the display edges. It is
/// excluded from screen capture (sharingType .none) so the next crop never
/// picks the border up, and it ignores mouse events so the exam stays
/// interactive underneath. `init` is trivial (no I/O); the window is created
/// lazily on the main thread at first use (AppKit objects are @MainActor),
/// bridged from the serial flash queue via DispatchQueue.main.sync.
final class EdgeLightFlasher: @unchecked Sendable {
    /// Serial queue so overlapping cycles never interleave overlay shows.
    private let queue = DispatchQueue(label: "openrubric.edgelight")
    /// Seconds the border stays lit before turning off.
    private let pulseGap: Double
    /// Border thickness in points.
    private let borderWidth: CGFloat

    /// The overlay window (a @MainActor instance; only ever touched on main).
    private var window: EdgeLightWindow?
    /// Guards the one-time build of `window`.
    private var built = false

    init(pulseGap: Double = 0.35, borderWidth: CGFloat = 28) {
        self.pulseGap = pulseGap
        self.borderWidth = borderWidth
    }

    /// Turns the border on and off `count` times on the main display.
    func flash(count: Int) {
        queue.async {
            self.ensureWindow()
            guard let window = self.window else {
                FlashDiagnostics.note("flash: edgeLight UNAVAILABLE (no display) — skipped")
                return
            }
            FlashDiagnostics.note("flash: edgeLight count=\(count) border=\(Int(self.borderWidth))pt (overlay ring-light)")
            for _ in 0..<count {
                self.showOverlay(window)
                Thread.sleep(forTimeInterval: self.pulseGap)
                self.hideOverlay(window)
                Thread.sleep(forTimeInterval: self.pulseGap)
            }
            // Guaranteed final hide: never leave the border lit.
            self.hideOverlay(window)
            FlashDiagnostics.note("flash: edgeLight done — \(count) pulse(s), border off")
        }
    }

    /// Builds the overlay window once, on the main thread (AppKit windows are
    /// main-actor objects even though the flash loop runs on the serial queue).
    /// Best-effort: a missing main display just leaves `window` nil and the
    /// flash no-ops. `DispatchQueue.main.sync` is safe here because the caller
    /// is the serial flash queue, never main.
    private func ensureWindow() {
        guard !built else { return }
        built = true
        let width = borderWidth
        DispatchQueue.main.sync {
            self.window = MainActor.assumeIsolated {
                guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
                return EdgeLightWindow(screenFrame: screen.frame, borderWidth: width)
            }
        }
        if window == nil {
            FlashDiagnostics.note("flash: edgeLight no NSScreen — skipped")
        }
    }

    private func showOverlay(_ window: EdgeLightWindow) {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                window.show()
            }
        }
    }

    private func hideOverlay(_ window: EdgeLightWindow) {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                window.hide()
            }
        }
    }
}

/// The click-through glow overlay. A `@MainActor` class because it owns an
/// NSWindow/NSView. It is only ever touched from the main thread (the
/// EdgeLightFlasher bridges to main via `DispatchQueue.main.sync`), so the
/// AppKit isolation is satisfied and no locking is needed.
@MainActor
private final class EdgeLightWindow {
    private let window: NSWindow
    private let borderView: BorderGlowView

    init(screenFrame: NSRect, borderWidth: CGFloat) {
        borderView = BorderGlowView(frame: screenFrame, borderWidth: borderWidth)
        window = NSWindow(
            contentRect: screenFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        // Keep the ring light out of the next screen capture.
        window.sharingType = .none
        window.contentView = borderView
    }

    func show() {
        window.orderFrontRegardless()
        borderView.animateOn()
    }

    func hide() {
        borderView.animateOff()
        window.orderOut(nil)
    }
}

/// Draws a soft, bright border hugging all four edges of the display.
/// NSView is @MainActor, so this subclass is main-actor-isolated too.
private final class BorderGlowView: NSView {
    private let borderWidth: CGFloat
    private let glowLayer = CAGradientLayer()

    init(frame: NSRect, borderWidth: CGFloat) {
        self.borderWidth = borderWidth
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor

        // A single inset, stroked rounded rectangle reads as a continuous
        // glowing border on all four sides at once (cheaper than 4 views).
        glowLayer.cornerRadius = 18
        glowLayer.borderWidth = borderWidth
        glowLayer.borderColor = NSColor.white.withAlphaComponent(0.92).cgColor
        glowLayer.shadowColor = NSColor.white.cgColor
        glowLayer.shadowRadius = borderWidth * 0.9
        glowLayer.shadowOpacity = 0.9
        glowLayer.shadowOffset = .zero
        glowLayer.opacity = 0
        // Inset so the outer half of the stroke and the shadow sit inside the
        // display rather than clipping at the window edge.
        let inset = borderWidth + borderWidth * 0.9 + 2
        glowLayer.frame = NSRect(x: inset, y: inset,
                                 width: frame.width - inset * 2,
                                 height: frame.height - inset * 2)
        layer?.addSublayer(glowLayer)
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let inset = borderWidth + borderWidth * 0.9 + 2
        glowLayer.frame = NSRect(x: inset, y: inset,
                                 width: bounds.width - inset * 2,
                                 height: bounds.height - inset * 2)
    }

    func animateOn() {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0
        a.toValue = 1
        a.duration = 0.08
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        glowLayer.add(a, forKey: "on")
        glowLayer.opacity = 1
    }

    func animateOff() {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = glowLayer.presentation()?.opacity ?? glowLayer.opacity
        a.toValue = 0
        a.duration = 0.08
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        glowLayer.add(a, forKey: "off")
        glowLayer.opacity = 0
    }
}
#endif
