#if os(macOS)
import AppKit
import OpenRubricCore

/// Orchestrates one answer cycle: capture the crop around the cursor,
/// build the prompts, call the configured provider, parse the answer,
/// and present it in the `AnswerPanel`.
///
/// Everything runs on the main actor (UI work); the API call hops off
/// via `await` and returns to it. A press while a cycle is in flight
/// (capturing/asking) is dropped — the exam user is not going to spam
/// the hotkey, and re-entering would double-bill the API key.
@MainActor
final class AppModel {
    enum Phase: Equatable {
        case idle
        case capturing
        case asking
        case presenting
        case failed(String)
    }

    private let store: AppSettingsStore
    private let capture = ScreenCaptureService()
    private let panel: AnswerPanel
    private let hotkey: HotkeyManager
    private let flash: FlashCoordinator
    private let history: HistoryStore

    private(set) var phase: Phase = .idle
    private var inFlight: Task<Void, Never>?

    /// Fired after every cycle so the menu bar can reflect status.
    var onPhaseChange: (@MainActor (Phase) -> Void)?

    init(store: AppSettingsStore, panel: AnswerPanel, hotkey: HotkeyManager,
         flash: FlashCoordinator = FlashCoordinator(),
         history: HistoryStore? = nil) {
        self.store = store
        self.panel = panel
        self.hotkey = hotkey
        self.flash = flash
        if let history {
            self.history = history
        } else {
            // Default: Application Support/<bundle>/history.jsonl
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("OpenRubric", isDirectory: true)
                ?? FileManager.default.temporaryDirectory
            self.history = HistoryStore(fileURL: dir.appendingPathComponent("history.jsonl"))
        }
    }

    func startHotkey() {
        hotkey.onFire = { [weak self] in self?.trigger() }
        hotkey.start()
    }

    func stopHotkey() {
        hotkey.stop()
    }

    /// Runs one full answer cycle. Re-entrant guard: a press while a
    /// cycle is in flight (capturing/asking) is dropped, but a fresh
    /// press while the previous answer is on screen starts a new cycle
    /// for the next question.
    func trigger() {
        guard phase != .capturing, phase != .asking else { return }
        runCycle()
    }

    private func runCycle() {
        let task = Task { @MainActor in
            setPhase(.capturing)
            do {
                let settings = store.settings
                guard let key = store.apiKey, !key.isEmpty else {
                    throw CycleError.noKey
                }
                guard let cursor = Self.cursorInGlobalTopLeftCoordinates() else {
                    throw CycleError.noScreen
                }

                let png = try await capture.captureCrop(cursor: cursor, radius: settings.cropRadius)
                setPhase(.asking)

                let client = try settings.makeClient(apiKey: key)
                let result = try await client.completion(
                    systemPrompt: PromptBuilder.systemPrompt(mode: settings.promptMode, includeExplanation: settings.includeExplanation),
                    userPrompt: PromptBuilder.userPrompt(mode: settings.promptMode, includeExplanation: settings.includeExplanation),
                    imagePNG: png
                )
                let parsed = AnswerParser.parse(result.text, mode: .init(promptMode: settings.promptMode))
                panel.show(parsed, nearCursor: cursor)
                recordHistory(result: result, parsed: parsed, model: settings.model)
                if let plan = FlashPlanner.plan(for: parsed, enabled: settings.flashChannels) {
                    flash.flash(plan)
                }
                setPhase(.presenting)
            } catch {
                panel.hide()
                setPhase(.failed(error.localizedDescription))
            }
        }
        inFlight = task
    }

    func dismissPanel() {
        panel.hide()
        setPhase(.idle)
    }

    /// Persists the answer, its letter, the model, and the token accounting
    /// for this turn. The cost is resolved from the model pricing table;
    /// `nil` when the model is not in the table (no made-up prices). A
    /// write failure is logged (not thrown) so a full Application Support
    /// directory never crashes the cycle — but is not silent either.
    private func recordHistory(result: CompletionResult, parsed: ParsedAnswer, model: String) {
        let letter = parsed.letter
        let cost = TokenCostEstimator.pricing(for: model)?.cost(of: result.usage)
        let entry = HistoryEntry(
            answer: parsed.text,
            letter: letter,
            model: model,
            usage: result.usage,
            costUSD: cost
        )
        do {
            try history.record(entry)
        } catch {
            NSLog("OpenRubric: failed to record history entry: \(error)")
        }
    }

    private func setPhase(_ new: Phase) {
        phase = new
        onPhaseChange?(new)
    }
}

extension AppModel {
    /// The cursor as a point in **global top-left display coordinates**
    /// (the space `SCDisplay.frame` and `CropGeometry` use).
    ///
    /// `NSEvent.mouseLocation` is in AppKit's bottom-left global space;
    /// the two spaces share the primary display's corner as their origin
    /// (one top-left, the other bottom-left), so y is a mirror about the
    /// primary's height and x is shared verbatim. Per-screen conversion
    /// formulas are error-prone on secondary/mirrored displays, so the
    /// primary is the only reference used.
    static func cursorInGlobalTopLeftCoordinates() -> CGPoint? {
        let mouseLocation = NSEvent.mouseLocation
        // Both spaces share the primary display's corner as their origin;
        // SCK's is top-left, AppKit's global is bottom-left — so y is a
        // mirror about the primary's height. X is shared verbatim.
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main else {
            return nil
        }
        return CGPoint(x: mouseLocation.x, y: primary.frame.maxY - mouseLocation.y)
    }
}

enum CycleError: LocalizedError {
    case noKey
    case noScreen

    var errorDescription: String? {
        switch self {
        case .noKey:
            return "No API key set. Open Settings and add your Anthropic key."
        case .noScreen:
            return "No display is available to capture."
        }
    }
}

#endif
