# Browser capture

DayDream skips web browsers. The one exception is Google Chrome. **Chrome page history** ("Web pages in Chrome") saves the title and site of the page in front. **Typing on websites** saves what you type in Chrome, with the site, only while typed text is on too. Setup shows both switches already on, each with one line saying what it saves, and one click turns either off; nothing is recorded before Start Recording. A release can leave Chrome out entirely with one switch (see [The release switch](#the-release-switch)).

A second design, a browser extension, exists in `BrowserBridge/` but is not used by any build. It is described at the end.

## What is recorded from browsers

| Browser | What DayDream saves |
| --- | --- |
| Google Chrome, with Web pages in Chrome on | The title and site of the page in front, and when. Nothing while any Incognito or Guest window is open. |
| Google Chrome, with Web pages in Chrome and typed text both on | Also what you type on websites, with the site. See [Typing on websites in Chrome](#typing-on-websites-in-chrome). |
| Google Chrome, with Web pages in Chrome off | Nothing, typing included. |
| Every other browser, including Chrome Beta, Dev and Canary | Nothing, typing included. Settings lists them as "Not recorded in this version". |
| A browser DayDream doesn't know by name | Nothing, if it declares that it opens web links (see below). |

## Chrome page history

Settings > Apps to remember > Web pages in Chrome. When it is on:

- DayDream reads only the page in front, only from Google Chrome (`com.google.Chrome`), signed by Google.
- It asks Chrome with read-only Apple Events (`core/getd`) for a fixed list of properties: the window list, each window's mode, position and title, the active tab and its address (`Sources/MemoryCore/ChromeAppleEvents.swift`). Window positions are read only for typing on websites. It never runs a script or JavaScript and never changes anything in Chrome. Setup has a Google Chrome step (only while the switch is on and Chrome is installed): its one button asks macOS for Automation access, opening Chrome in the background first if it is closed. Otherwise macOS asks only when you press Allow in Settings, never on its own later. If you said no, setup's row, the menu bar and Settings offer Ask again: DayDream runs `/usr/bin/tccutil reset AppleEvents com.getnorthlight.daydream` on itself (its own Automation answer only, never another app or permission; the command is fixed in `ChromeAutomationReset`) and asks again. Where that can't bring the question back, it opens Privacy & Security › Automation with a small guide beside it, and picks up the switch without a restart.
- If any Incognito or Guest window is open, it saves nothing.
- The address is cut to the site (`https://example.org`) for the saved row. Beside it, on this Mac only, the page's link is kept so Open Original opens that page (`Evidence.page`, `BrowserSites.pageLink`): the path, and from the query only a YouTube video's `v`, `t` and `list` (every other part, such as `utm_*`, `fbclid` and share IDs, is dropped); the fragment only for a Google Sheets tab or a Wikipedia section. No link at all for a login, token-like, card-like or blocked path part, an auth page (callback, confirm, unsubscribe and similar), a signed or token address (S3, Google Cloud Storage and Azure signatures, OAuth `code`, `access_token`) or search, email and chat sites. No MCP or CLI reply, search document, writer or cloud request reads it.
- Search engines save what you searched for, never the rest of the address. Common chat sites save the site only. Email sites save the folder or the open email's subject while Save email subjects is on (never codes, passwords, sign-ins or bank mail), and typing in webmail keeps the open email's subject. Banking, password, sign-in, payment, health and government sites, and the sites you add, are skipped.
- Cloud summaries, when you turn them on, get Chrome page titles and sites, cleaned of web addresses and unread counts.

The code: `Sources/MacMemApp/ChromePageRecorder.swift` (when to read), `Sources/MacMemApp/ChromeEventSender.swift` (the only Apple Event sender in the app), `Sources/MemoryCore/ChromePages.swift` and `Sources/MemoryCore/BrowserSafety.swift` (what a page row may hold). `CaptureSession.accepts` refuses a Chrome page row unless `PrivacySettings.browserPagesOn` is true.

## Typing on websites in Chrome

Only while typed text ("Remember what you type") **and** Web pages in Chrome are both on (setup shows both on; either can be turned off). While both are on:

- A key typed in Google Chrome is read only after a fresh check of the page. The first key, Return and every save take a full check: DayDream asks Chrome for its windows and the address of the tab in front, and matches them through Accessibility to the focused field. For up to a second after a full check, the next keys take a lighter one: the same windows, each still an ordinary window, the same focused field on the same page, and the field's labels read again. Keys that would be dropped anyway take no check and are never read: those typed just after Return, a click or a shortcut, and those typed within a second of a refused key (a blocked site, a site whose checkbox is off, an Incognito or Guest window, a sensitive field) with no click, Return or shortcut since. It needs the stable Google Chrome, signed by Google, version 151 or later, and exactly one copy of Chrome running.
- It saves nothing while any Incognito or Guest window is open, or while macOS secure input is on.
- The field must be an ordinary text box (a text field, text area, or search or autocomplete box; it doesn't need a label), not a password field, in a page with exactly one web area (no embedded frames). Fields labelled as card numbers, one-time codes, PINs, passwords or web terminals are refused.
- Blocked sites are never recorded: Chrome page history's list (banking, password, sign-in, payment, health and government sites), web terminals and cloud consoles, sign-in and payment pages, Google Docs, and the sites you add.
- Each website counts as one kind, and the checkbox for that kind must be on: Search boxes and AI prompts (search engines and AI chats), Writing apps (Notion), Messages and email (email and chat sites, and every page of social sites with chat, like Facebook, LinkedIn and X; on unless you turn it off), or Other websites (everything else, on by default).
- It keeps the words, the site, the page's title where Chrome page history saves it (webmail keeps the open email's subject; search engines keep what was searched for; common chat sites keep the site only) and, when the message box names it, who a message went to (a chat's channel or person from the box's label, an email's To name), never the rest of the address. Text that looks like a secret is dropped. The words are encrypted and deleted after 7 days unless you choose another time.
- AI apps you connect read the words you typed only while **Let AI apps see your typed words** is on; with it off they see where and about how much you typed, and your summaries, never the words. Website typing goes to cloud summaries only if you chose them: the words, the site, the page title, cleaned of any address and unread count, and who it went to.

The code: `Sources/MacMemApp/WebTypingRoute.swift` (keys typed in Chrome), `Sources/MacMemApp/ChromeTypingWitness.swift` and `Sources/MemoryCore/BrowserTypingJoin.swift` (the page check and the site rules), `PrivacyPolicy/Sources/PrivacyPolicy/WebTypingGate.swift` (the focus gate) and `PrivacyPolicy/Sources/PrivacyPolicy/TypingSites.swift` (which kind a site counts as).

## Browsers DayDream doesn't know

Known browsers are listed in `Sources/HistoryCore/KnownBrowsers.swift`. To cover browsers that aren't on that list, DayDream also treats an app as a browser when its `Info.plist` declares the `http` or `https` URL scheme (`BrowserLookalike` in `Sources/MemoryCore/BrowserSafety.swift`). Such an app is skipped before anything is saved, and Settings lists it under Web browsers.

Limits:

- An app is found through Launch Services by its bundle ID, and only its `Info.plist` is read. The answer is kept while DayDream runs, so a browser installed after the first look is caught the next time DayDream starts.
- A browser that doesn't declare `http` or `https`, and isn't on the list, is recorded like any other app until you exclude it in Settings.
- An app that isn't a browser but declares those schemes (for example a link picker) is skipped too.

## The release switch

`ReleaseFeatures.chromePageHistory` in `Sources/MemoryCore/ReleaseFeatures.swift` decides whether a release has Chrome page history. It is `true` by default.

When it is `false`:

- the Web pages in Chrome card is hidden;
- `PrivacySettings.browserPagesOn` is false everywhere, whatever was saved, so no Chrome page can be read or saved;
- every entry point of `ChromeEventSender` returns before building an event or asking macOS, so the app sends no Apple Event and never shows the Automation prompt;
- setup, Settings, the recording status and the text AI apps read stop mentioning Chrome pages, and say web browsers are not recorded;
- typing on websites, which needs Web pages in Chrome, can't turn on either;
- the release must be signed without `--apple-events`.

To leave Chrome page history out of a release:

1. Change `chromePageHistory` to `false` in `ReleaseFeatures.swift`. Change nothing else.
2. Run the checks. `scripts/honesty-switch-off-checks.sh` builds a copy of the app with the switch off and proves no Apple Event path runs. `scripts/honesty-release-switch-checks.py` checks that the signing flag matches the switch.
3. Sign with the flag that `python3 scripts/honesty-release-switch-checks.py --flag` prints: `--apple-events` when the switch is on, nothing when it is off.

People's saved choices are kept. If a later release turns the switch back on, their earlier Web pages in Chrome choice comes back.

## The extension design (not used)

`BrowserBridge/` holds a Chrome extension (Manifest V3), a native messaging host and signed messages between them. It would report only a site's origin and whether a tab stayed in front, never a title, full address, page text or typing. The app turns this path on only when its `Info.plist` names a relay directory, a Keychain service, a deployment and an extension ID, the code signature is valid, and an enrolment in the relay directory matches (`Sources/MacMemApp/BrowserProviderResolver.swift`). Packaged builds set none of these, and nothing in the app installs the extension or registers the host. It needs a real signed extension ID and testing on a real Mac before it could ship.

## Development checks

All of these use synthetic data, fake Chrome environments and fake app folders. None opens a browser, sends an Apple Event or installs anything.

- `swift build` then `.build/debug/MacMemChecks`: the store side, including Chrome page rows, the made-up browser check and the password manager list.
- `python3 scripts/honesty-release-switch-checks.py -v`: the switch and the signing flag agree, and every Apple Event goes through the switch.
- `bash scripts/honesty-switch-off-checks.sh <scratch folder> [.build/arm64-apple-macosx/debug]`: builds with the switch off and checks that nothing reads Chrome.
- `python3 scripts/check_browser_boundary.py -v`: the source guarantees for every browser path.
- From `BrowserBridge/`: `swift build`, then `.build/debug/BrowserBridgeChecks` and the `node --test fixtures/*.mjs` checks for the extension design.
