#if os(macOS)
import AppKit
import OpenRubricCore

/// The settings window. Non-secret fields bind to `OpenRubricSettings`;
/// the API key round-trips through the Keychain via `AppSettingsStore`.
///
/// Everything is built programmatically (no nib) so the whole app target
/// is source-only.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let store: AppSettingsStore

    private let providerPicker = NSPopUpButton()
    private let baseURLField = NSTextField()
    private let modelField = NSTextField()
    private let promptModePicker = NSPopUpButton()
    private let explanationToggle = NSButton(checkboxWithTitle: "Include one-sentence explanation", target: nil, action: nil)
    private let cropField = NSTextField()
    private let apiKeyField = NSSecureTextField()
    private let ledToggle = NSButton(checkboxWithTitle: "Caps Lock LED blinks (A=1…D=4)", target: nil, action: nil)
    private let screenFlashToggle = NSButton(checkboxWithTitle: "Screen brightness pulses", target: nil, action: nil)
    private let backlightToggle = NSButton(checkboxWithTitle: "Keyboard backlight pulses", target: nil, action: nil)
    private let cameraLEDToggle = NSButton(checkboxWithTitle: "Camera LED blinks (green, top)", target: nil, action: nil)
    private let edgeLightToggle = NSButton(checkboxWithTitle: "Edge Light border (ring light)", target: nil, action: nil)
    private let popupToggle = NSButton(checkboxWithTitle: "Show answer popup near cursor", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    init(store: AppSettingsStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 580),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenRubric Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
        loadValues()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        stack.addArrangedSubview(row("Provider", control: providerPicker))
        stack.addArrangedSubview(row("Base URL", control: baseURLField))
        stack.addArrangedSubview(row("Model", control: modelField))
        stack.addArrangedSubview(row("Prompt mode", control: promptModePicker))
        stack.addArrangedSubview(row("API key", control: apiKeyField))
        stack.addArrangedSubview(row("Crop radius (pt)", control: cropField))
        stack.addArrangedSubview(explanationToggle)

        let flashHeader = NSTextField(labelWithString: "Discreet output (multiple choice only)")
        flashHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        flashHeader.textColor = .secondaryLabelColor
        stack.addArrangedSubview(flashHeader)
        stack.addArrangedSubview(ledToggle)
        stack.addArrangedSubview(screenFlashToggle)
        stack.addArrangedSubview(backlightToggle)
        stack.addArrangedSubview(cameraLEDToggle)
        stack.addArrangedSubview(edgeLightToggle)

        let displayHeader = NSTextField(labelWithString: "Display")
        displayHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        displayHeader.textColor = .secondaryLabelColor
        stack.addArrangedSubview(displayHeader)
        stack.addArrangedSubview(popupToggle)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(stack)
        content.addSubview(statusLabel)
        content.addSubview(buttons)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            statusLabel.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 8),

            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
    }

    /// A labeled row: the label is pinned to a fixed width so controls
    /// line up regardless of label length.
    private func row(_ label: String, control: NSView) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        labelField.alignment = .right
        let fieldStack = NSStackView(views: [labelField, control])
        fieldStack.orientation = .horizontal
        fieldStack.spacing = 8
        fieldStack.alignment = .centerY
        labelField.widthAnchor.constraint(equalToConstant: 130).isActive = true
        control.widthAnchor.constraint(equalToConstant: 300).isActive = true
        return fieldStack
    }

    private func loadValues() {
        let settings = store.settings
        providerPicker.removeAllItems()
        providerPicker.addItems(withTitles: ApiProvider.allCases.map(\.displayName))
        providerPicker.selectItem(at: ApiProvider.allCases.firstIndex(of: settings.apiProvider) ?? 0)

        baseURLField.stringValue = settings.baseURL
        modelField.stringValue = settings.model
        promptModePicker.removeAllItems()
        promptModePicker.addItems(withTitles: PromptMode.allCases.map(\.displayName))
        promptModePicker.selectItem(at: PromptMode.allCases.firstIndex(of: settings.promptMode) ?? 0)
        explanationToggle.state = settings.includeExplanation ? .on : .off
        cropField.stringValue = String(Int(settings.cropRadius))
        apiKeyField.stringValue = store.apiKey ?? ""
        ledToggle.state = settings.flashChannels.contains(.capsLockLED) ? .on : .off
        screenFlashToggle.state = settings.flashChannels.contains(.screenFlash) ? .on : .off
        backlightToggle.state = settings.flashChannels.contains(.keyboardBacklight) ? .on : .off
        cameraLEDToggle.state = settings.flashChannels.contains(.cameraLED) ? .on : .off
        edgeLightToggle.state = settings.flashChannels.contains(.edgeLight) ? .on : .off
        popupToggle.state = settings.showAnswerPopup ? .on : .off

        providerPicker.target = self
        providerPicker.action = #selector(providerChanged)
        statusLabel.stringValue = store.apiKey == nil ? "No API key stored yet." : "API key stored in Keychain."
    }

    /// Swapping provider resets base URL / model to that provider's
    /// defaults so a half-typed Anthropic key doesn't silently point at
    /// an OpenAI-shaped endpoint.
    @objc private func providerChanged() {
        let index = providerPicker.indexOfSelectedItem
        guard let provider = ApiProvider.allCases[safe: index] else { return }
        baseURLField.stringValue = OpenRubricSettings.defaultBaseURL(for: provider)
        modelField.stringValue = OpenRubricSettings.defaultModel(for: provider)
    }

    @objc private func save() {
        let provider = ApiProvider.allCases[safe: providerPicker.indexOfSelectedItem] ?? .anthropic
        let promptMode = PromptMode.allCases[safe: promptModePicker.indexOfSelectedItem] ?? .multipleChoice
        let radius = max(60, CGFloat(Int(cropField.stringValue) ?? 260))
        var channels = Set<FlashChannel>()
        if ledToggle.state == .on { channels.insert(.capsLockLED) }
        if screenFlashToggle.state == .on { channels.insert(.screenFlash) }
        if backlightToggle.state == .on { channels.insert(.keyboardBacklight) }
        if cameraLEDToggle.state == .on { channels.insert(.cameraLED) }
        if edgeLightToggle.state == .on { channels.insert(.edgeLight) }
        let newSettings = OpenRubricSettings(
            apiProvider: provider,
            baseURL: baseURLField.stringValue,
            model: modelField.stringValue,
            promptMode: promptMode,
            includeExplanation: explanationToggle.state == .on,
            cropRadius: radius,
            showAnswerPopup: popupToggle.state == .on,
            flashChannels: channels
        )
        do {
            try store.apply(newSettings, apiKey: apiKeyField.stringValue)
            statusLabel.textColor = .systemGreen
            statusLabel.stringValue = "Saved."
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.window?.close()
            }
        } catch {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "Save failed: \(error.localizedDescription)"
        }
    }

    @objc private func cancel() {
        window?.close()
    }
}

extension ApiProvider {
    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude Haiku)"
        case .openAI: return "OpenAI (ChatGPT vision)"
        case .deepseek: return "DeepSeek (vision)"
        case .openAICompatible: return "OpenAI-compatible (custom)"
        }
    }
}

extension PromptMode {
    var displayName: String {
        switch self {
        case .multipleChoice: return "Multiple choice"
        case .shortAnswer: return "Short answer"
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#endif
