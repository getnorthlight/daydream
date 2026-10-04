# Chrome device test

This is a read-only test you run once on your own Mac, against a throwaway Chrome. It answers one question before any Chrome typing work ships (plan Work table, row 0): can DayDream tell which Chrome window, page and field the keys are going to, fast enough, from outside Chrome? It must do this without an extension and without ever touching Incognito or Guest windows.

It takes about 35 minutes. The pass and fail rules are fixed below, before you run it. The table the tool prints at the end is the decision.

This tool is not part of the DayDream app. The app's `Package.swift` does not reference it, and the app build never compiles it.

## What it reads, and what it never reads

**It reads:**

- **Apple Events** (`core/getd` only). For each window: its ID, `mode`, bounds and name. For the active tab: its ID and URL. It reads a window's name or URL only after every window has answered `mode = "normal"`.
- **Accessibility, in Chrome's basic mode:**
  - roles and subroles;
  - the focused window, its position, size, minimised state and title;
  - Chrome's window list (`AXWindows`): each window's subrole, position and size only, to count windows that Apple Events did not list. The join stops before any title, address or field read if a standard window is unlisted, two share the focused window's frame, or the focused window is not in the list;
  - the focused element's role and subrole, and, only when it is an `AXComboBox`, its `AXEditableAncestor` (an element reference, compared with the element itself to tell an editable search box from a drop-down, as the app does);
  - parent links, walked up at most 160 steps (X's post box is about 60 steps below its window);
  - `AXURL`, read on `AXWebArea` elements only.
  - Only with `--probe-labels`: the focused field's `AXDescription`, `AXPlaceholderValue`, `AXDOMIdentifier` and `AXDOMClassList`. These are used only to test the card, one-time-code and web-terminal deny rules. The tool prints which rule matched, never the text.
- **macOS:**
  - the frontmost app;
  - the system-wide focused app, which is how the Spotlight case is caught, and how long that read takes;
  - whether secure input is on;
  - the owner app, bounds and alpha of on-screen windows, which shows when a launcher panel is visible (Spotlight, and by default Raycast, Alfred and 1Password; their bundle IDs are UNCONFIRMED, and `--panel-bundles` replaces the list). It never reads window titles.
  - Chrome's launch arguments, to confirm the throwaway profile.

**It never:**

- reads `AXValue`, selected text, or anything you type;
- sets any Accessibility attribute or performs any action;
- turns on Chrome's full accessibility mode;
- runs JavaScript in Chrome or creates event taps;
- takes screenshots or reads the clipboard;
- launches or activates Chrome;
- writes anything except the optional `--report` file.

The report holds origins only, never titles, full URLs or labels. Window names are replaced by "(N characters)".

**Permissions.** The Automation prompt ("Terminal wants access to control Google Chrome") appears only when you pass `--request-permission` (`Sources/ChromeDeviceTest/Runner.swift:50-52`). The tool never shows the Accessibility prompt. You add Terminal yourself in step 5.

## Safety rules for the owner

1. **Quit your real Chrome** (Cmd+Q, not just closing windows) before you start. The tool refuses to run if more than one Chrome is running, or if Chrome is using your real profile folder. It checks this before any Apple Event, Accessibility read or permission request (`Runner.swift:34`, `main.swift:50`).
2. **Launch Chrome with `--user-data-dir` pointing at a new temporary folder** (step 4). Don't sign in to Google, sync, or install extensions in it.
3. **Use made-up text only.** For example: "purple lamp sings over quiet hills".
4. **Use the dummy password only, and only on the local test page.** The page ships with the value `dummy-not-a-real-password`. Never type a real password, card number or code anywhere during the test.
5. **Quit DayDream while you test** (menu bar > Quit), so it records none of it. Open it again after clean-up.

## Pass and fail rules (agreed before the run)

The tool grades every rule automatically (`Sources/ChromeProbeCore/Criteria.swift`). The overall result is one of:

- **RUN INVALID**: a gate (G) failed. The results don't count. Fix the cause and run again.
- **ABANDON**: any A rule failed. Stop Chrome typing work until after launch (plan §6, row 7). The kill date stays Oct 2, 2026.
- **INCOMPLETE**: an A rule was not run. Re-run those steps with `--only step,step`.
- **CONTINUE**: no A rule failed. Any F rules marked FIX become build tasks.

Budgets (`Sources/ChromeProbeCore/Model.swift:9-26`):

| Budget | Limit |
|---|---|
| Whole join | 150 ms |
| One Apple Event | 20 ms |
| One AX read | 25 ms |
| Light per-key check | 30 ms |
| Incognito listing gap | every sample of the gap must show the extra AX window; FIX if the gap is over 700 ms |
| Many windows | at least 8 windows open for F13 |
| "In most joins" | 90% or more |

### Gates: the run only counts if all pass

| ID | Rule | Code |
|---|---|---|
| G1 | Exactly one Chrome, on a throwaway `--user-data-dir` profile | Criteria.swift:62 |
| G2 | Accessibility is on and Automation is granted for Terminal | Criteria.swift:63 |
| G3 | No title, URL or AX content was read while any window was not "normal", or after Accessibility showed more standard windows than Apple Events listed. An independent read audit (`Audit.swift:58-73`) must record zero violations. | Criteria.swift:67 |
| G4 | The frontmost-app reading is live: at most 10% of field joins say "keys in Chrome" while "Chrome not frontmost" | Criteria.swift:76 |

### Abandon: any FAIL means stop Chrome typing work

| ID | Rule | Code |
|---|---|---|
| A1 | Every window is listed and its mode read by window ID. The fixed first-window descriptor (`abso`) works. No mode is unreadable. | Criteria.swift:87 |
| A2 | A new Incognito window reports `incognito`. Every join pauses with it in front and with it behind a normal window. | Criteria.swift:99 |
| A3 | A Guest window reports `incognito`, and every join pauses | Criteria.swift:105 |
| A4 | A new Incognito window: between focus moving to it and Apple Events listing it, every sample shows one more standard AX window than listed, so the join's window count denies. A gap with any uncovered sample, or with no sample, fails; a lag alone is no longer a pass. A covered gap over 700 ms is FIX. | Criteria.swift:138 |
| A5 | Basic-mode AX shows the input and textarea as text fields, with exactly one `AXWebArea` and a readable `AXURL` | Criteria.swift:152 |
| A6 | Basic-mode AX shows the contenteditable editor as a text field | Criteria.swift:154 |
| A7 | The Apple Events front window and the AX focused window match on bounds, title and URL in 90% or more of joins (one window, then two windows) | Criteria.swift:169 |
| A8 | While you type, the join accepts the field and the AX field object stays the same in 90% or more of samples | Criteria.swift:176 |
| A9 | Warm full-join median is 150 ms or less | Criteria.swift:192 |
| A10 | When Spotlight is open over Chrome, the system-wide focused app is not Chrome | Criteria.swift:201 |
| A11 | Fields inside iframes (same-origin and cross-site) can be told apart from top-level fields and are never accepted | Criteria.swift:216 |
| A12 | The hidden password field shows a secure subrole, or macOS secure input is on | Criteria.swift:221 |
| A13 | The address bar is never accepted | Criteria.swift:230 |
| A14 | An Incognito window closing behind a "Leave site?" dialog: every join pauses (still listed) or stops at the window count before any title, address or field read (dropped from the list but still on screen). Needs your "y" that the dialog stayed open. | Criteria.swift:248 |
| A15 | A password input with `role=combobox` and no label (box 13) turns on macOS secure input, or shows a secure subrole, in every join, and is never accepted. Chromium may report it as a plain `AXComboBox`, so secure input is the guard. | Criteria.swift:400 |

### Fix: FIX means it becomes a build task, not a stop

| ID | Rule | Code |
|---|---|---|
| F1 | The pre-fix first-window descriptor (enum `firs`, `ChromeModeReader.swift:39` at 6f26d15) fails. That failure confirms the `abso` fix in 0584e30 was needed. If it works, the result is INFO. | Criteria.swift:258 |
| F2 | The shown (plain-text) password is still denied by some layer | Criteria.swift:271 |
| F3 | Card-number and one-time-code fields are denied by label or id (needs `--probe-labels`) | Criteria.swift:285 |
| F4 | The top `AXWebArea`'s parent is `AXScrollArea` | Criteria.swift:289 |
| F5 | Light per-key check p95 is 30 ms or less | Criteria.swift:294 |
| F6 | Per-read p95 is 20 ms or less for Apple Events and 25 ms or less for AX | Criteria.swift:302 |
| F7 | Warm full-join p90 is 150 ms or less | Criteria.swift:309 |
| F8 | Chrome passes the Google signature requirement (Team EQHXZ8M8AV) and is version 151 or later | Criteria.swift:313 |
| F9 | Every Apple Event reply type is one the app's decoder accepts: `utxt`/`TEXT` for mode, name, tab ID and URL; `qdrt`/`list` for bounds (`Model.swift:34`, kept equal to the app by `check_harness_source.py`). The harness reads looser types, so this is what shows the app would work. | Criteria.swift:328 |
| F10 | The web-terminal input (box 9) is denied by label, id or class (needs `--probe-labels`) | Criteria.swift:337 |
| F11 | Two zoomed windows with one frame are denied before any content read (the same-frame rule; typing there is not recorded) | Criteria.swift:349 |
| F12 | A minimized window still pairs with its listed bounds, so the window in use is accepted | Criteria.swift:360 |
| F13 | With 10 windows open, warm join p90 is 150 ms or less and the field is accepted | Criteria.swift:375 |
| F14 | In TextEdit (and Notes, if used), the system-wide focused app equals the frontmost app in 90% or more of samples, and that read's p95 is 25 ms or less | Criteria.swift:387 |
| F15 | An unlabelled search box with suggestions (`<input role=combobox>`, box 12) is `AXComboBox`, its `AXEditableAncestor` is itself, and it is accepted in 90% or more of joins | Criteria.swift:411 |

A harness deny for a label, id or class rule implies an app deny: the app's field rules are a superset of the harness's (`scripts/check_browser_boundary.py`).

**Information only:** I1 is Chrome's accessibility warm-up time. I2 is how the AX title compares with the window name. I3 is the Apple Events reply types for the list and bounds.

## Running on a MacBook with the kit

A stock MacBook has no Python or Swift: typing `python3` or `swift` only opens the "install developer tools" dialog. So on the owner's MacBook the test runs from a kit, a signed and notarized disk image named "DayDream Chrome Test". The kit does steps 2 to 7 below and explains each one in plain words. Step 1 happens on the developer Mac, where `kit/build-kit.sh` builds the kit. The order changes in one place: the kit has DayDream quit first, then sets up Accessibility (the first half of step 5) before any Chrome is opened, so that a Terminal restart loses nothing. It asks the owner to quit their own Chrome after that.

| In the kit | What it is |
|---|---|
| `run.sh` | The one command the owner runs. It does the checks, Accessibility, quitting Chrome and DayDream, the test page, the throwaway Chrome, preflight, the guided run and the clean-up. It uses macOS's `/bin/bash` 3.2 and system tools only. |
| `bin/chrome-device-test` | This harness. It is signed with the hardened runtime and the Apple Events entitlement (`kit/entitlements.plist`); without that entitlement, a hardened build could not send Apple Events. |
| `bin/chrome-device-test-serve` | A Swift replacement for `testpage/serve.py`. It is loopback only and gives the same replies. It has no entitlements. |
| `testpage/` | `index.html` and `frame.html`, byte for byte the same as this folder's. |
| `READ ME FIRST.txt` | One page for the owner. |

**Owner:** double-click the DMG, open Terminal, paste `bash "/Volumes/DayDream Chrome Test/run.sh"` and follow the screen. At the end, attach the report from the home folder (Finder shows it) to a GitHub issue. `--only a,b` re-runs single steps. `--dry-run` prints every action without doing any of them. `READ ME FIRST.txt` has the owner's troubleshooting list.

**Developer:**

```sh
tools/chrome-device-test/kit/build-kit.sh --work /path/to/scratch                     # ad hoc, local checks only
tools/chrome-device-test/kit/build-kit.sh --work /path/to/scratch --identity <SHA-1>  # Developer ID; then notarize and staple (printed)
python3 tools/chrome-device-test/kit/check_server_parity.py --serve /path/to/scratch/build/release/chrome-device-test-serve --work /path/to/scratch
```

What the kit adds to the harness:

- **`chrome-device-test access`.** It prints whether Terminal has Accessibility and exits 0 for on, 1 for off. It needs no Chrome, sends no Apple Event and shows no prompt (`Sources/ChromeDeviceTest/main.swift`). This lets `run.sh` set up Accessibility before Chrome is open.
- **`chrome-device-test-serve`** (`Sources/ChromeDeviceTestServe/main.swift`; the request rules are in `Sources/ChromeProbeCore/TestPage.swift`, which the selftest covers).
  - It gives the same answers as `serve.py`: status codes, `Content-Type`, `Cache-Control: no-store` and body bytes. `kit/check_server_parity.py` compares the two over 127.0.0.1 and ::1.
  - It is stricter than `serve.py` in a few places. It serves only regular files directly in the page folder: no subfolders, dotfiles, symlinks, listings or redirects. A path like `/.` gets `index.html` instead of a redirect.
  - It refuses to start if port 8765 is taken (exit 3).
- **`run.sh` launches the throwaway Chrome exactly as step 4 does**, with an explicit `mktemp` template under `$TMPDIR`. On macOS 26, `mktemp -t` ignores `$TMPDIR`. It never touches the real profile. It closes a Chrome only when the owner types y, and only if that Chrome's launch arguments name the kit's own throwaway folder. It never sends Chrome an Apple Event itself.
- **Clean-up.** `run.sh` offers `tccutil reset AppleEvents` only after warning that it clears every Automation grant Terminal has. It never resets Accessibility; it shows where to switch it off, and only when Terminal did not have it before the test. These reminders appear however the run ends: also after q or Ctrl+C in step 2 or 3, before any Chrome was opened. If the clean-up itself is cut short (Ctrl+C during it, or the window closes), a short "Before you go" list names what is left: the test Chrome, Automation, Accessibility and the report.
- **The report** goes to the home folder, not the Desktop, so Terminal never needs the Desktop (Files & Folders) permission.
- **One run at a time.** A lock folder (`$TMPDIR/ddchrometest-lock`) stops a second copy, which would otherwise stop the first copy's test page and delete its work folder. A lock whose process is gone is taken over.
- **Not as root.** `run.sh` refuses to run as root or under `sudo`: its "is Chrome or DayDream running?" checks look at the owner's own processes only.
- **`--only`** runs in a new Chrome with one window, so the kit adds the step that opens the windows a step needs: `incognito-race` for `incognito-background` and `incognito-closing`, and `two-windows-new` for `two-windows-old`, `two-windows-zoomed` and `minimized-window`. The harness also marks `incognito-background` NOT RUN (not FAIL) when every window is normal, because then there is no Incognito window to measure.
- **Chrome older than 151** is not a gate in the README rules (F8 is a FIX), so the kit explains how to update and asks whether to carry on; the default answer stops.
- **Accessibility that stays off.** After one Terminal restart the kit has Terminal removed from the list and added again; after two restarts it stops with a line to copy to Claude instead of asking for another restart.
- **Items to confirm on the MacBook:**
  - no Gatekeeper prompt for the notarized tools;
  - whether a "removable volume" prompt appears;
  - that Accessibility reads on without restarting Terminal (if not, `run.sh` asks for a Terminal restart, then starts again from the beginning);
  - that the hardened, entitled build gets `Automation: granted`.

## Steps (about 25 minutes)

Run every command from the repository root on branch `chrome/v1`. You need two Terminal windows or tabs. If you use iTerm, read "Terminal" as iTerm throughout.

### 1. Build (3 min, no network)

```sh
cd tools/chrome-device-test
swift build -c release
.build/release/chrome-device-test-selftest     # optional: synthetic checks, expect "0 failed"
python3 check_harness_source.py                # optional: source rules, expect "OK"
cd ../..
```

### 2. Quit your real Chrome and DayDream (1 min)

1. In Chrome, press Cmd+Q. Check that Chrome no longer has a dot under its Dock icon.
2. Quit DayDream from its menu bar icon.

### 3. Start the local test page (1 min, Terminal tab 1)

```sh
python3 tools/chrome-device-test/testpage/serve.py
```

This serves the page on this Mac only (127.0.0.1 and ::1, port 8765). Leave the tab open.

### 4. Launch a throwaway Chrome (1 min, Terminal tab 2)

```sh
DDPROFILE="$(mktemp -d -t ddchrometest)"; echo "$DDPROFILE"
open -na "Google Chrome" --args --user-data-dir="$DDPROFILE" --no-first-run --no-default-browser-check http://127.0.0.1:8765/
```

Chrome opens the "DayDream device test" page with boxes 1–11. Box 8 should say "Loaded from localhost (a different site)". Skip any Chrome sign-in prompt. Keep this one window only.

### 5. Permissions (3 min)

1. Open System Settings > Privacy & Security > Accessibility.
2. Click +, choose Applications > Utilities > Terminal, and switch it on.
3. In tab 2, run:

   ```sh
   tools/chrome-device-test/.build/release/chrome-device-test preflight --request-permission
   ```

4. When macOS asks "Terminal wants access to control Google Chrome", click **Allow**.

Preflight should end with `Preflight OK.` and these lines:

- `Chrome profile: Chrome is using a throwaway profile folder: …`
- `Accessibility: on`
- `Automation: granted`

If Accessibility still says OFF, quit and reopen Terminal, then run preflight again without `--request-permission`.

### 6. Guided run (20–25 min)

```sh
tools/chrome-device-test/.build/release/chrome-device-test run --probe-labels --report ~/Desktop/chrome-device-test-report.json
```

Each step prints what to set up, then waits.

1. Do the "Before you press Return" part.
2. Press Return in Terminal.
3. Click into Chrome and do the "Then, in Chrome" part.
4. If the step has a timed action, do it when you hear **Tink** (go).
5. Keep still until you hear **Glass** (done), then go back to Terminal.

Type `s` and Return to skip a step. Type `q` and Return to stop; the table still prints.

To read every instruction first, run `chrome-device-test steps --verbose`.

| # | Step | What you do |
|---|---|---|
| 1 | descriptor | Nothing. Chrome must have one normal window. |
| 2 | plain-input | Click in box 1. Don't type. |
| 3 | textarea | Click in box 2. |
| 4 | contenteditable | Click in box 3. |
| 5 | typing | Click in box 2. At Tink, type made-up words non-stop for 10 s. |
| 6 | password-hidden | Box 4 shows dots. Click in box 4. |
| 7 | password-shown | Click "Show password" first, then click in box 4. |
| 8 | card | Click in box 5 (Card number). |
| 9 | otp | Click in box 6 (One-time code). |
| 10 | terminal | Click in box 9 (Web terminal). |
| 11 | iframe-same | Click the input inside box 7. |
| 12 | iframe-cross | Click the input inside box 8. |
| 13 | address-bar | Click the page, then press Cmd+L. |
| 14 | two-windows-new | Before Return: press Cmd+N, open http://127.0.0.1:8765/ and put the windows side by side. Then click box 1 in the new window. |
| 15 | two-windows-old | Click box 1 in the old window. |
| 16 | two-windows-zoomed | Before Return: Window > Zoom in each window (or Window > Fill), so they sit exactly on top of each other; not full screen. Click box 1 in the front one. |
| 17 | minimized-window | Before Return: Window > Zoom again in one window, then Cmd+M the other one. Click box 1 in the window on screen. |
| 18 | many-windows | Before Return: Cmd+N until there are 10 windows; open the test page in the newest. Click its box 1. |
| 19 | spotlight | Before Return: close windows (Cmd+Shift+W) until two are left, un-minimize. Click in box 1. At Tink: Cmd+Space, type made-up words (no Return), wait about 3 s, press Esc. |
| 20 | native-editors | Before Return: open TextEdit with a blank document (Notes optional). Click into it; at Tink type made-up words until Glass. |
| 21 | incognito-race | Click in box 1. At Tink, press Cmd+Shift+N. Leave the Incognito window in front. |
| 22 | incognito-background | Click box 1 in a normal window, so the Incognito window is behind it. |
| 23 | incognito-closing | Before Return: in the Incognito window open the test page and tick box 10. Click that page; at Tink press Cmd+Shift+W and leave "Leave site?" open until Glass. Answer `y`, then click Leave. |
| 24 | guest | Before Return: make sure the Incognito window is closed, then open profile icon > Guest. Answer `y` in Terminal. |
| 25 | combo-input | Before Return: close the Guest window (and any Incognito window) and reload the test page in a normal window. Click in box 12 (Search box with suggestions, no label). Don't type. |
| 26 | password-combo | Click in box 13 (Hidden combo box: a password input with `role=combobox`, no label). Don't type. |

At the end the tool prints the table, then `OVERALL: …`, and writes the JSON report. The report holds origins only, so it is safe to share.

Exit codes:

| Code | Meaning |
|---|---|
| 0 | CONTINUE |
| 2 | RUN INVALID, or the throwaway-profile check refused |
| 3 | ABANDON |
| 4 | INCOMPLETE |

To redo single steps, run `run --probe-labels --only guest,spotlight`.

### 7. Clean-up (3 min)

1. Quit the throwaway Chrome (Cmd+Q). Then run `rm -rf "$DDPROFILE"` in tab 2.
2. In tab 1, press Ctrl+C to stop `serve.py`.
3. System Settings > Privacy & Security > Automation > Terminal: switch off Google Chrome. You can also run `tccutil reset AppleEvents com.apple.Terminal`, which clears every Automation grant Terminal has.
4. System Settings > Privacy & Security > Accessibility: switch off or remove Terminal, unless you had it on before.
5. Reopen your real Chrome and DayDream.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "N Chrome instances are running" | Quit every Chrome (Cmd+Q), including Chrome Beta or Canary, then do step 4 again. |
| "Chrome is using your real profile folder" or "not launched with --user-data-dir" | Chrome was already running when you ran `open`. Quit it and do step 4 again. |
| "Could not read Chrome's launch arguments" | Rare. Add `--skip-profile-check` only if you are sure this is the throwaway Chrome. The table then marks G1 "UNVERIFIED". |
| Box 8 shows an error or is blank | `serve.py` is not listening on `::1`. Open http://localhost:8765/ instead, so box 8 loads from 127.0.0.1. |
| "Chrome never came to the front" | Click the Chrome window within 45 s of pressing Return. |
| G4 fails | macOS reported a stale frontmost app. Run again with `--settle 5`. |
| Every join denies with `window-listing-failed` | Automation was switched off. Run preflight again. |
| Step 21 says a non-normal window was already open | Close every Incognito and Guest window, then run `--only incognito-race,incognito-background,incognito-closing`. |
| Step 23 closes the window without asking "Leave site?" | Chrome asks only after a click on the page. Tick box 10, click the page once, then press Cmd+Shift+W. Answer `n` and re-run `--only incognito-closing`. |
| Step 22 says no Incognito window is open (A2 NOT RUN) | Press Cmd+Shift+N, then re-run `--only incognito-race,incognito-background,incognito-closing`. |
| Step 23 says no Incognito window is open | Press Cmd+Shift+N, open http://127.0.0.1:8765/ in it, tick box 10, then re-run `--only incognito-closing`. |
| F11 is NOT RUN | The two windows did not share a frame. Use Window > Zoom (not full screen) in both. |

## For developers

The tool is a separate SwiftPM package. It depends only on `../../PrivacyPolicy`, and nothing in the app depends on it (`check_harness_source.py`, `test_not_part_of_the_app_build`). To build without touching the repo's `.build`:

```sh
swift build --package-path tools/chrome-device-test --scratch-path /tmp/cdt-build
```

The selftest (`Sources/ChromeProbeSelfTest/main.swift`) runs the real join, audit, grading and report code against a fake Chrome and a fake AX tree. It makes no system calls. `check_harness_source.py` enforces these source rules:

- the AX attribute and Apple Event allowlists;
- no forbidden APIs;
- the permission prompt only behind the flag;
- strict mode before any content read, and the AX window count (with its stop) before any title, address, tab or field read;
- the profile gate first;
- a local test page with a dummy password;
- the reply types F9 grades against are the app's (`Sources/MemoryCore/BrowserTypingJoin.swift`);
- the default panel list includes Raycast, Alfred and 1Password;
- the package has exactly three products, and the server depends only on the core;
- the server binds only 127.0.0.1 and ::1, uses no Apple Events or Accessibility (not even the trust check), and starts no program;
- the test-page rules serve one file name inside the page folder and send `Cache-Control: no-store` on every reply;
- `access` only calls `AXIsProcessTrusted()`;
- the strict step (`incognito-background`) reads only window IDs and modes before deciding that no Incognito window is open;
- `kit/run.sh`:
  - refuses root and `sudo` before any other command;
  - uses bash 3.2 only and no developer tools or network;
  - launches only the README step 4 Chrome;
  - signals only its own server or the verified test Chrome, re-checking the process first;
  - deletes only its own temporary folders, lock and note;
  - resets Automation only after a y, and never resets Accessibility;
  - shows the permission reminders whether or not step 4 was reached, and a short list when the clean-up is cut short;
  - quits DayDream before any permission step;
  - never asks for the Desktop, and shows only preflight's status lines;
  - keeps `MIN_CHROME` equal to the harness's `minimumChromeMajor`;
  - checks `--dry-run` before every side effect;
- `kit/build-kit.sh` never notarizes or touches the keychain, and the entitlements are Apple Events only.

| What | Where |
|---|---|
| Fixed first-window and every-window descriptors (`typeAbsoluteOrdinal`) | Sources/ChromeDeviceTest/LiveAppleEvents.swift:29-31, 47-48 |
| Pre-fix enum descriptor, kept for F1 | LiveAppleEvents.swift:50 |
| The only Apple Event built (`core/getd`) and sent (`.neverInteract`, `.dontRecord`) | LiveAppleEvents.swift:70, 74 |
| Automation status (never asks) and request (only with the flag) | LiveAppleEvents.swift:127-137; Runner.swift:50-55; Options.swift:121 |
| AX attribute allowlist and the single read call | Sources/ChromeDeviceTest/LiveAccessibility.swift:10, 53 |
| Label reads only with `--probe-labels` | LiveAccessibility.swift:129 |
| Throwaway-profile gate, run before anything else | Sources/ChromeProbeCore/Options.swift:52-62; Runner.swift:34; main.swift:50 |
| Launch arguments (argv only; the environment is never decoded) | Sources/ChromeDeviceTest/LiveSystem.swift:31-34; Options.swift:25-42 |
| Launcher panel check: window owner, bounds and alpha only | LiveSystem.swift:64-76 |
| Join step 0: frontmost app, system-wide focus, secure input | Sources/ChromeProbeCore/Join.swift:252-258 |
| Join step 1 and strict pause before any content read | Join.swift:273 |
| Join step 2b: AX window count, stop before content (review I1) | Join.swift:307-345; one-to-one pairing Join.swift:169 |
| Join step 5: re-list, stop if a window appeared | Join.swift:424 |
| Light per-key check | Join.swift:471 |
| Independent read audit, including the AX window count | Sources/ChromeProbeCore/Audit.swift:26, 58-73 |
| Race sampling of the gap; closing-window and native-editor steps | Runner.swift:332, 386, 417 |
| Strict step: no Incognito window open means not run (IDs and modes only) | Runner.swift:256; Steps.swift `strictPrecondition` |
| Grading and overall result | Criteria.swift:53, 406 |

Owner decisions this tool supports but does not test:

- No extension.
- Strict mode: any Incognito or Guest window pauses Chrome typing (A2 and A3 test the signal).
- Scope is "everywhere except a block list", with suffix-matched default blocks, removable defaults, added sites and one-click "don't record this site".
- The origin is stored, never the path.
- Browser typing is off by default: it needs typed text (with its consent screen) and Web pages in Chrome both on.

The block list and site rules live in the app (`Sources/MemoryCore/BrowserTypingJoin.swift`, compiled into every release build).
