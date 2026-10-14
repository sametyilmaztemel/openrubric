#if os(macOS)
import AppKit
import OpenRubricCore

/// Floating, non-activating panel that shows the parsed answer near the
/// cursor.
///
/// `NSWindowSharingNone` keeps the panel out of future captures and
/// other apps' screen shares; `nonactivatingPanel` style lets the user
/// hit the hotkey again while it is visible without stealing focus from
/// the exam window.
@MainActor
final class AnswerPanel {

    private let panel: NSPanel
    private let letterLabel = NSTextField(labelWithString: "")
    private let answerLabel = NSTextField(labelWithString: "")
    private let explanationLabel = NSTextField(labelWithString: "")
    private let confidenceIndicator = NSView()

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 140),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .titled, .closable, .resizable, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // The whole reason the panel exists is to stay readable over a
        // full-screen exam without being captured again.
        panel.sharingType = .none
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 140))
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor

        letterLabel.font = .monospacedSystemFont(ofSize: 44, weight: .bold)
        letterLabel.translatesAutoresizingMaskIntoConstraints = false
        letterLabel.lineBreakMode = .byTruncatingTail

        answerLabel.font = .systemFont(ofSize: 15, weight: .medium)
        answerLabel.translatesAutoresizingMaskIntoConstraints = false
        answerLabel.lineBreakMode = .byWordWrapping
        answerLabel.maximumNumberOfLines = 2
        answerLabel.textColor = .secondaryLabelColor

        explanationLabel.font = .systemFont(ofSize: 12)
        explanationLabel.translatesAutoresizingMaskIntoConstraints = false
        explanationLabel.lineBreakMode = .byWordWrapping
        explanationLabel.maximumNumberOfLines = 3
        explanationLabel.textColor = .tertiaryLabelColor

        confidenceIndicator.translatesAutoresizingMaskIntoConstraints = false
        confidenceIndicator.layer?.cornerRadius = 4

        content.addSubview(letterLabel)
        content.addSubview(answerLabel)
        content.addSubview(explanationLabel)
        content.addSubview(confidenceIndicator)
        panel.contentView = content

        NSLayoutConstraint.activate([
            letterLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            letterLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            letterLabel.widthAnchor.constraint(equalToConstant: 56),

            answerLabel.leadingAnchor.constraint(equalTo: letterLabel.trailingAnchor, constant: 12),
            answerLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            answerLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),

            confidenceIndicator.leadingAnchor.constraint(equalTo: letterLabel.trailingAnchor, constant: 12),
            confidenceIndicator.topAnchor.constraint(equalTo: answerLabel.bottomAnchor, constant: 6),
            confidenceIndicator.widthAnchor.constraint(equalToConstant: 10),
            confidenceIndicator.heightAnchor.constraint(equalToConstant: 10),

            explanationLabel.leadingAnchor.constraint(equalTo: confidenceIndicator.trailingAnchor, constant: 8),
            explanationLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            explanationLabel.topAnchor.constraint(equalTo: confidenceIndicator.topAnchor, constant: -2),
        ])
    }

    /// Shows the parsed answer near the cursor (screen coordinates,
    /// top-left origin — converted to AppKit's bottom-left space here).
    func show(_ answer: ParsedAnswer, nearCursor cursor: CGPoint) {
        if answer.isMultipleChoice, let letter = answer.letter {
            letterLabel.stringValue = letter
            answerLabel.stringValue = answer.text == letter ? "Doğru cevap" : answer.text
            letterLabel.isHidden = false
        } else {
            letterLabel.isHidden = true
            answerLabel.stringValue = answer.text
        }
        explanationLabel.stringValue = answer.explanation ?? ""
        explanationLabel.isHidden = (answer.explanation?.isEmpty ?? true)
        confidenceIndicator.layer?.backgroundColor = Self.color(for: answer.confidence).cgColor

        panel.setContentSize(NSSize(width: 340, height: 140))
        position(nearCursor: cursor)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    var isVisible: Bool { panel.isVisible }

    /// Places the panel to the right of the cursor when there is room,
    /// otherwise to the left; clamped to the cursor's screen.
    private func position(nearCursor cursor: CGPoint) {
        // The cursor arrives in SCK's top-left screen space; convert to
        // AppKit's bottom-left global space (mirror about the primary's
        // height — both spaces share the primary's corner as origin).
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main else {
            panel.center()
            return
        }
        let appKitCursor = NSPoint(x: cursor.x, y: primary.frame.maxY - cursor.y)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(appKitCursor) }) ?? NSScreen.main else {
            panel.center()
            return
        }
        let panelSize = panel.frame.size
        let gap: CGFloat = 24
        var x = appKitCursor.x + gap
        if x + panelSize.width > screen.frame.maxX - 8 {
            x = appKitCursor.x - gap - panelSize.width
        }
        var y = appKitCursor.y - panelSize.height / 2
        y = max(screen.frame.minY + 8, min(y, screen.frame.maxY - panelSize.height - 8))
        x = max(screen.frame.minX + 8, min(x, screen.frame.maxX - panelSize.width - 8))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private static func color(for confidence: ParsedAnswer.Confidence) -> NSColor {
        switch confidence {
        case .high: return .systemGreen
        case .medium: return .systemYellow
        case .low: return .systemRed
        }
    }
}

#endif
