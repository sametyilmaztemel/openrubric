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
    private let phaseMenuItem: NSMenuItem
    private var settingsWindowController: SettingsWindowController?

    init(model: AppModel, store: AppSettingsStore) {
        self.model = model
        self.store = store
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
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
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

    @objc private func quit() {
        NSApp.terminate(nil)
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
