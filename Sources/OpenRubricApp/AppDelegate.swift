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

        // Capture any crash that happens this session (and surface the
        // previous one from the menu bar). Installed before any flasher is
        // created so a launch-time trap is still caught.
        CrashReporter.install()

        let store = AppSettingsStore()
        let history = HistoryStore(fileURL: Self.defaultHistoryURL())
        let panel = AnswerPanel()
        let hotkey = HotkeyManager()
        let appModel = AppModel(store: store, panel: panel, hotkey: hotkey, history: history)
        appModel.startHotkey()

        let bar = MenuBarController(model: appModel, store: store, history: history)

        model = appModel
        menuBar = bar
    }

    /// Application Support/OpenRubric/history.jsonl (created on demand).
    private static func defaultHistoryURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OpenRubric", isDirectory: true)
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("history.jsonl")
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stopHotkey()
    }
}

#endif
