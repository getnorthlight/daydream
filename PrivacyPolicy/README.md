# PrivacyPolicy

This Swift package decides whether the recorder may read typed characters from the focused field, and whether a piece of typed text looks like a secret. The live recorder uses it; see [docs/privacy-model.md](../docs/privacy-model.md) for how it fits with the other privacy checks.

It is pure logic: no file, network, logging or model access. It only ever refuses; it cannot widen what the rest of the app allows.

## Contents

| File | What it does |
| --- | --- |
| `CaptureGate.swift` | `CaptureGate.typing` and `CaptureGate.metadata` take a description of the focused field (app, window, focus IDs, role, secure-input and private-window state, web address) and return allowed, blocked or unknown with a fixed reason code. Unknown counts as blocked. Typing is only ever allowed in the apps `TypingCategories` allows (an app's own web view only through its vendor's proof); every browser is blocked here. It also holds the built-in password manager, browser and sensitive-site lists. |
| `TypingCategories.swift` | The fixed table of apps typed text may cover, with the signer each must have, and the release gate that allows a row only with a capture proof, a confirmed bundle ID and a known signer. Rows whose signer isn't confirmed stay closed. |
| `TypingSites.swift` | Which kind a website counts as (Search boxes and AI prompts, Writing apps, Messages and email, or Other websites), and the sites that are never recorded. |
| `WebTypingGate.swift` | The gate for typing on websites in Google Chrome, used instead of `CaptureGate.typing`: it repeats every refusal of the capture gate, then needs a proven text field in a normal Chrome window, an origin-only address and a site your choices allow. |
| `TerminalPromptLatch.swift` | Drops keys typed at a password prompt in a terminal: after `sudo`, `ssh` and similar commands, or a line it couldn't fully see, every key up to and including the next Return is dropped before it becomes typed text. |
| `TypingKeyMap.swift` | Turns each key press into an edit (insert, delete a character, word or line, move the caret) from its key code and modifiers, before any character is read. |
| `TypedUnit.swift` | Rebuilds one continuous run of typing in one field, applying deletes and caret moves inside the run, and holds `UnitClassifier`, which checks a whole unit before it can be saved. |
| `TypingSession.swift` | Holds typed units in memory and decides when one is finished (see below). Any privacy boundary discards pending text without saving it. Its debug description is redacted. |
| `TextClassifier.swift` | Inspects at most 4 KB of text and rejects it if it looks like a secret: private keys, API and bearer tokens, JWTs, card, account and ID-number patterns, `password:`-style text in several languages, bare numbers and single mixed-character words. Text is normalized first (Unicode compatibility forms, zero-width characters removed) so formatting tricks do not hide a match. |
| `BrowserMetadataGate.swift` | Checks signed metadata from a planned [browser extension](../docs/browser-capture.md): Chrome or Safari only, secure input off, a normal window and tab, a non-editable focus, a fresh sample, and an origin (no path, query or fragment) that is not excluded, not a sensitive site and not login- or bank-like. No shipped build contains that extension. Chrome page history doesn't use this gate; it reads Chrome over Apple Events with its own rules (`Sources/MemoryCore/ChromePages.swift`). |
| `Authorization.swift` | `CaptureAuthorization`, a stricter recheck that binds a decision to the exact field and text. Tested here but not used by the app yet. |

The app calls these from `Sources/MacMemApp/EventCapture.swift`, `Sources/MacMemApp/AccessibilitySnapshot.swift`, `Sources/MacMemApp/NativeFocusWitness.swift` and `adapters/CoreCaptureBinding.swift`.

## How the recorder uses it

Typed text is on by default: setup shows it switched on, and one click turns it off. While it's on, it works only in the apps `TypingCategories` allows (Notes, TextEdit and Pages; Spotlight, Claude and ChatGPT; Terminal, Ghostty and Xcode; Messages and Mail if Messages and email is on) and, while Web pages in Chrome is on too, on websites in Google Chrome. The steps below are for apps; websites go through `WebTypingGate` after a check of the Chrome page, described in [docs/privacy-model.md](../docs/privacy-model.md).

1. On each key press, before reading any character, the recorder builds a fresh description of the focused field from the Accessibility API (role and subrole only, never the field's value) and asks `CaptureGate.typing`. The description must be less than one second old.
2. Allowed key presses become edits in a typed unit: one run of typing in one field. Backspace, Option-Backspace, forward delete and caret moves inside the run are applied, so the saved text is what you ended up with, not every key.
3. A unit is finished at a natural break: a pause (30 seconds, or 60 seconds when the text ends mid-sentence or right after a label), Return, leaving the field or app, a size limit (about 2,000 characters), or pause, stop and sleep. A unit whose field you left is saved only if focus moved somewhere that is provably not a password field.
4. `UnitClassifier` then checks the whole unit, including text you typed and deleted, each line, each word and the join with your previous unit in the same app. If it finds a secret, nothing from the unit is saved and typing in that app is ignored until you press Return, Tab or Esc there, or for 30 seconds. Lone numbers, opaque tokens and a value right after a label (such as "pin: 49") are saved as `[withheld]`.
5. Only text that passes is handed to the store, which applies its own checks.

Secure input, a password field, a password manager, an excluded app, turning typing off, or a change to your privacy settings discards any pending text.

## Limits

- The classifier cannot recognize an ordinary password, a passphrase made of plain words or a recovery phrase. If you type secrets into normal text boxes, leave typed text off.
- A secret split across two separate units, or in an unfamiliar format or language, can get through.
- Some harmless text is rejected, such as a bare year or a mixed-case code identifier.
- A correction made after a unit was saved becomes a separate row; the earlier row keeps the typo.
- Paste, autofill and dictation are not captured at all, and neither are input methods (for example Chinese or Japanese input) in apps, so these checks never see that text. On websites in Chrome, DayDream builds the text from the keys pressed, so under an input method these checks see those keys. Changes the app makes on its own, such as autocorrect, are not seen either.
- Typed text waits in memory for up to the pause time before it is checked and saved.

## Checks

From the repository root:

```sh
swift run --package-path PrivacyPolicy PrivacyChecks
```

`Checks/TypingChecks.swift` drives `TypingSession` with a fake clock, fake focus and a fake host that mirrors the recorder. The checks use synthetic text and synthetic field descriptions only. The labelled sample is small and hand-picked, so its catch rate is not a measure of real-world accuracy.
