#if os(macOS)
import AppKit
import OpenRubricCore

/// Menu bar (accessory) app: no Dock icon, no main window, lives in the
/// status bar until the user quits from the menu.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory: menu-bar-only, never steals focus from the exam.
        NSApp.setActivationPolicy(.accessory)

        let store = AppSettingsStore()
        let panel = AnswerPanel()
        let hotkey = HotkeyManager()
        let appModel = AppModel(store: store, panel: panel, hotkey: hotkey)
        appModel.startHotkey()

        let bar = MenuBarController(model: appModel, store: store)

        model = appModel
        menuBar = bar
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stopHotkey()
    }
}

#endif
