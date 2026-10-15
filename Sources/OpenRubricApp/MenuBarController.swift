#if os(macOS)
import AppKit
import OpenRubricCore

/// The menu bar status item and its menu. The icon reflects the current
/// phase (idle / working / answered / error) via a badge dot.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let model: AppModel
    private let store: AppSettingsStore
    private let history: HistoryStore
    private let phaseMenuItem: NSMenuItem
    private var settingsWindowController: SettingsWindowController?
    private var historyWindowController: HistoryWindowController?

    init(model: AppModel, store: AppSettingsStore, history: HistoryStore) {
        self.model = model
        self.store = store
        self.history = history
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        phaseMenuItem = NSMenuItem(title: "Ready (⌃⌥⌘A)", action: nil, keyEquivalent: "")
        super.init()

        statusItem.button?.image = Self.makeImage(badge: .idle)
        statusItem.button?.toolTip = "OpenRubric — ⌃⌥⌘A to answer"

        let menu = NSMenu()
        menu.addItem(phaseMenuItem)
        menu.addItem(.separator())
        let answer = NSMenuItem(title: "Answer Question Now", action: #selector(triggerAnswer), keyEquivalent: "a")
        answer.keyEquivalentModifierMask = [.control, .option, .command]
        answer.target = self
        menu.addItem(answer)
        let dismiss = NSMenuItem(title: "Dismiss Answer", action: #selector(dismissAnswer), keyEquivalent: "d")
        dismiss.keyEquivalentModifierMask = [.command]
        dismiss.target = self
        menu.addItem(dismiss)
        menu.addItem(.separator())
        let help = NSMenuItem(title: "How to use…", action: #selector(showHelp), keyEquivalent: "?")
        help.keyEquivalentModifierMask = [.command]
        help.target = self
        menu.addItem(help)
        let flashLog = NSMenuItem(title: "Flash Log…", action: #selector(showFlashLog), keyEquivalent: "l")
        flashLog.keyEquivalentModifierMask = [.command]
        flashLog.target = self
        menu.addItem(flashLog)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let historyItem = NSMenuItem(title: "History…", action: #selector(openHistory), keyEquivalent: "h")
        historyItem.target = self
        menu.addItem(historyItem)
        let quit = NSMenuItem(title: "Quit OpenRubric", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu

        model.onPhaseChange = { [weak self] phase in
            DispatchQueue.main.async {
                self?.update(for: phase)
            }
        }
    }

    private func update(for phase: AppModel.Phase) {
        switch phase {
        case .idle:
            phaseMenuItem.title = "Ready (⌃⌥⌘A)"
            statusItem.button?.image = Self.makeImage(badge: .idle)
        case .capturing:
            phaseMenuItem.title = "Capturing screen…"
            statusItem.button?.image = Self.makeImage(badge: .working)
        case .asking:
            phaseMenuItem.title = "Asking Claude…"
            statusItem.button?.image = Self.makeImage(badge: .working)
        case .presenting:
            phaseMenuItem.title = "Answer shown — press again for next"
            statusItem.button?.image = Self.makeImage(badge: .answered)
        case .failed(let message):
            phaseMenuItem.title = "Error: \(message)"
            statusItem.button?.image = Self.makeImage(badge: .error)
        }
    }

    @objc private func triggerAnswer() {
        model.trigger()
    }

    @objc private func dismissAnswer() {
        model.dismissPanel()
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(store: store)
        }
        settingsWindowController?.showWindow(nil)
    }

    @objc private func openHistory() {
        if historyWindowController == nil {
            historyWindowController = HistoryWindowController(store: history)
        }
        historyWindowController?.showWindow(nil)
    }

    /// A short in-app guide. The most common mistake is the crop: the app
    /// captures a square centred on the mouse pointer, so the pointer must be
    /// sitting on the question — not on a nearby icon or the menu bar.
    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "How OpenRubric works"
        alert.informativeText = """
        1. Point the mouse at the question. The app captures a square centred \
        on your cursor (Settings → Crop radius controls its size) and sends \
        only that region to the model. If the text or the answer choices are \
        not inside that square, the model can't see them — so place the cursor \
        in the middle of the question.

        2. Check the frame first: press Control+Option+Command+P to open a \
        preview of exactly what the model will see. If the question or the \
        choices are cut off, move the cursor (or raise the crop radius in \
        Settings) until the whole question fits, then close the preview.

        3. Ask it: press Control+Option+Command+A anywhere, or choose \
        "Answer Question Now" from this menu.

        4. Read the answer in the small panel near the cursor. Press the \
        answer hotkey again (or "Dismiss Answer") to clear it and ask the next \
        one.

        Discreet signals (multiple choice only): when the answer is a letter, \
        the enabled channels fire — the Caps Lock LED blinks A=1, B=2, … and \
        the keyboard backlight / screen brightness pulse. Enable them in \
        Settings → Discreet output. Backlight and screen are best-effort: some \
        keyboards and external displays don't expose a controllable element, \
        in which case the panel is the reliable channel.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Shows the tail of the flash diagnostics file so the user can see what
    /// happened without a terminal or `log --private` (Monterey redacts NSLog
    /// bodies as `<private>`). Read-only and non-activating, so it never
    /// steals focus from the exam.
    @objc private func showFlashLog() {
        let tail = FlashDiagnostics.lastLines(30)
        let alert = NSAlert()
        alert.messageText = "Flash Log (last 30 lines)"
        alert.informativeText = "Full file: ~/Library/Application Support/OpenRubric/flash.log"
        alert.accessoryView = makeLogTextView(tail)
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn, let url = Self.flashLogURL() {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// A scrollable, monospaced text view sized for the alert, so the full
    /// tail is readable rather than truncated in `informativeText`.
    private func makeLogTextView(_ text: String) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 280))
        scroll.hasVerticalScroller = true
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = text
        scroll.documentView = textView
        return scroll
    }

    private static func flashLogURL() -> URL? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OpenRubric", isDirectory: true)
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("flash.log")
    }

    private enum Badge { case idle, working, answered, error }

    /// Draws "OR" plus a status dot so the item is recognizable in a
    /// crowded menu bar.
    private static func makeImage(badge: Badge) -> NSImage {
        let size = NSSize(width: 30, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        let text = "OR" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.controlTextColor,
        ]
        let textSize = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: 2, y: (18 - textSize.height) / 2), withAttributes: attrs)
        let dotColor: NSColor
        switch badge {
        case .idle: dotColor = .clear
        case .working: dotColor = .systemYellow
        case .answered: dotColor = .systemGreen
        case .error: dotColor = .systemRed
        }
        if dotColor != .clear {
            dotColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: 22, y: 10, width: 6, height: 6)).fill()
        }
        image.unlockFocus()
        image.isTemplate = (badge == .idle)
        return image
    }
}

#endif
