#if os(macOS)
import AppKit
import OpenRubricCore

/// Fans out a `FlashPlan` to the concrete output channels. The plan is
/// built in core (letter -> count, user-enabled channels); this class
/// only knows how to drive each channel.
final class FlashCoordinator: @unchecked Sendable {
    private let keyboard: KeyboardFlasher
    private let screen: ScreenFlasher
    private let camera: CameraLEDFlasher

    init(keyboard: KeyboardFlasher = KeyboardFlasher(),
         screen: ScreenFlasher = ScreenFlasher(),
         camera: CameraLEDFlasher = CameraLEDFlasher()) {
        self.keyboard = keyboard
        self.screen = screen
        self.camera = camera
    }

    /// Fires every channel in the plan. No-op for an empty plan.
    func flash(_ plan: FlashPlan) {
        guard plan.count >= 1 else { return }
        for channel in plan.channels {
            switch channel {
            case .capsLockLED:
                keyboard.flashCapsLock(count: plan.count)
            case .keyboardBacklight:
                keyboard.flashBacklight(count: plan.count)
            case .screenFlash:
                screen.flash(count: plan.count)
            case .cameraLED:
                camera.flash(count: plan.count)
            }
        }
    }
}

#endif
