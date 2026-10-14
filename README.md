# OpenRubric

Open-source, bring-your-own-key macOS menu bar app: point your cursor at
the question, press a hotkey, get the answer through channels that are hard
to notice — a menu bar icon, a window that never appears in screen share,
the Caps Lock LED, a screen brightness flash, or your keyboard backlight.

No vendor server sits between you and the model. The screen crop goes
straight from the app to **your** API key. The default target is the
Anthropic Messages API — `claude-haiku-5-5` on `api.anthropic.com`, or
any Anthropic-compatible proxy (e.g. MiniMax). Any OpenAI-compatible
endpoint (OpenAI, Groq, Together, OpenRouter, a local Ollama, vLLM, …)
works too.

```
cursor on question  →  ⌃⌥⌘ + Enter  →  crop around cursor
        →  Claude Haiku (your key)  →  "B — high"
        →  menu bar icon / hidden panel / Caps Lock LED / brightness flash
```

This repository currently contains the platform-agnostic core
(`OpenRubricCore`) with full unit-test coverage and macOS CI. The menu bar
app (capture pipeline, hotkeys, hidden answer panel) and the discreet
output channels follow in the tracked phases below.

## Privacy

- The crop is sent only to the endpoint you configured.
- The API key lives in the macOS Keychain, never written to disk.
- No telemetry, no analytics, no account.
- Run fully offline with a local Ollama/vLLM model (OpenAI-compatible mode).

## Roadmap

Tracked in the [issues](https://github.com/sametyilmaztemel/openrubric/issues):

- [x] #2 P1: Core logic — parser, prompts, crop geometry,
      Anthropic Messages client (default) + OpenAI-compatible client,
      unit tests, CI *(this branch)*
- [ ] #3 P2: MVP pipeline — hotkey, ScreenCaptureKit crop, hidden answer
      window, settings UI
- [ ] #4 P3: Discreet output channels — Caps Lock LED, screen flash,
      keyboard backlight
- [ ] #5 P4: Packaging — DMG, signing, releases, history, token cost

## Development

Requires Swift 6.0+ (the core builds and tests on macOS and Linux; the app
itself is macOS 14+).

```sh
swift test --parallel          # run the core test suite
swift build                    # build all targets
```

## License

MIT — see [LICENSE](LICENSE).
