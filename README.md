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
cursor on question  ->  Control+Option+Command+A  ->  crop around cursor
        ->  Claude Haiku (your key)  ->  "B — high"
        ->  menu bar icon / hidden panel / Caps Lock LED / brightness flash
```

## Install

Download the latest `OpenRubric.dmg` from the
[releases](https://github.com/sametyilmaztemel/openrubric/releases), open
the disk image, and drag **OpenRubric.app** to Applications.

- First launch: the app lives in the **menu bar** (the "OR" icon) — there
  is no Dock icon.
- Gatekeeper: on the first start, right-click the app in Applications and
  choose **Open** (ad-hoc builds are not notarized).
- Add your API key in **Settings…** (menu bar icon). The key is stored in
  the macOS Keychain and never written to disk.
- The packaged build targets **Apple Silicon (arm64)**. For an Intel Mac,
  build locally from source with `./scripts/build-dmg.sh`.

## Required permissions

Grant each when macOS asks (System Settings → Privacy & Security):

| Permission | Used for | Where |
|---|---|---|
| Screen Recording | ScreenCaptureKit crop around the cursor | Privacy & Security → Screen Recording |
| Accessibility | the global `Control+Option+Command+A` hotkey | Privacy & Security → Accessibility |
| Input Monitoring | reading Caps Lock state for the LED channel | Privacy & Security → Input Monitoring |

The Caps Lock LED, keyboard-backlight, and screen-flash channels are
independent and best-effort: a keyboard/display without the relevant
hardware element simply does not react. Enable only the channels you want
in **Settings…**.

## Features

- **Answer cycle** — crop around the cursor, multiple-choice or
  short-answer mode, confidence + explanation, hidden panel (never in
  screen share) or menu bar badge.
- **Discreet channels** — Caps Lock LED blinks A=1…Z=26, screen
  brightness pulse, keyboard backlight pulse; each toggleable.
- **History** — the last 50 answers with model, token usage, and USD cost
  (menu bar → History…). The question screenshot is never stored.
- **Token cost** — per-turn cost from the provider's reported usage and a
  documented pricing table; unknown models show "—" rather than a guess.
- **BYO key** — Anthropic (default) or any OpenAI-compatible endpoint;
  fully offline with a local Ollama/vLLM model.

## Privacy

- The crop is sent only to the endpoint you configured.
- The API key lives in the macOS Keychain, never written to disk.
- No telemetry, no analytics, no account.
- History stores only answer, letter, model, usage, and cost — never the
  screenshot.
- Run fully offline with a local Ollama/vLLM model (OpenAI-compatible mode).

## FAQ

**Why does the Caps Lock LED not blink?**
Built-in MacBook keyboards expose it as an Output HID element; some
external keyboards do not at all. The channel is best-effort — a missing
element is a no-op, not an error.

**The screen flash is invisible.**
`CGDisplaySetDisplayBrightness` controls the main/internal display; many
external monitors ignore it. The pulse also reads and restores the current
brightness, so it is a no-op when the display is already at minimum.

**Which model is the default?**
`claude-haiku-5-5` (fast, cheap). Change the model or provider in
Settings.

## Roadmap

Tracked in the [issues](https://github.com/sametyilmaztemel/openrubric/issues):

- [x] #2 P1: Core logic — parser, prompts, crop geometry,
      Anthropic Messages client (default) + OpenAI-compatible client,
      unit tests, CI
- [x] #3 P2: MVP pipeline — hotkey, ScreenCaptureKit crop, hidden answer
      window, settings UI
- [x] #4 P3: Discreet output channels — Caps Lock LED, screen flash,
      keyboard backlight
- [x] #5 P4: Packaging — DMG, signing, releases, history, token cost
- [ ] #9 P5: harden flash channels (clamp, off-backlight pulse, app-layer
      tests)

## Development

Requires Swift 6.0+ (the core builds and tests on macOS and Linux; the app
itself is macOS 14+).

```sh
swift test --parallel          # run the core test suite
swift build                    # build all targets
./scripts/build-dmg.sh         # build + sign + DMG into dist/
```

The GitHub Actions **Release** workflow builds a DMG and publishes it to
the releases page whenever a `v*` tag is pushed. Ad-hoc signing is used
when no `APPLE_IDENTITY` secret is set; provide `APPLE_ID`,
`APPLE_APP_PASSWORD`, and `APPLE_TEAM_ID` to sign and notarize.

## License

MIT — see [LICENSE](LICENSE).
