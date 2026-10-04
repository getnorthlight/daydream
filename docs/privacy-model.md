# Privacy model

DayDream keeps a history of what you do on your Mac so you can search it later. This page explains what the recorder captures, what it refuses to capture, where the history is kept and what can leave your Mac. It describes the current code. The limits at the end matter as much as the rules.

## What is recorded

DayDream reads app and window activity through the macOS Accessibility API and a listen-only input event tap. It does not take screenshots or record the screen.

Recording is off until you start it, and it stays off after you pause or stop it. If it was on when DayDream quit, the Mac restarted or the app updated, it starts again when DayDream opens, with the same checks as Start. Recording needs the Accessibility and Input Monitoring permissions; without both, nothing is recorded. When the Mac sleeps, the screen locks or you switch to another user, recording stops. When you come back, it starts again by itself only if it was on before; if it can't, DayDream tells you why.

While recording, DayDream stores:

- the app you switch to;
- window changes: the app name and window title, and a web address when the app exposes one;
- mouse clicks and right-clicks, with the app and window they happened in;
- if you turned on Web pages in Chrome, the title and site of the page in front in Google Chrome;
- if you turned on typed text, what you type in the apps and websites it covers (below).

It does not store which button or link you clicked, text you select, or terminal contents.

Typed text ("Remember what you type") is a separate setting from recording. Setup shows it on, with one line saying what it saves, and you can turn it off there or in Settings at any time. While it's off, nothing typed is stored and key presses are ignored. Anyone typing on this Mac account while it's on is recorded as you. Even when it's on, typed text is only accepted:

- **in apps on a fixed list**, whose code signature is checked: Notes, TextEdit, Pages and Obsidian (Writing apps); Spotlight, Claude and ChatGPT (Search boxes and AI prompts); Terminal, Ghostty, Xcode and Cursor (Code); Messages, Mail and WhatsApp (Messages and email). An app whose signer DayDream hasn't confirmed is never accepted. In apps, only ordinary text fields count, with the US, ABC or British keyboard layout, and pressing Return or a keyboard shortcut is stored as a marker without any characters;
- **on websites in Google Chrome**, only while Web pages in Chrome is on too. A website counts as Search boxes and AI prompts, Writing apps, Messages and email, or Other websites, and the checkbox for its kind must be on. Every kind is on when typed text is turned on, unless you turned its checkbox off.

Each kind has its own checkbox. Paste, autofill and dictation are not captured, and neither are input methods such as Chinese or Japanese input, in apps or on websites.

## How the rules are enforced

The checks run in layers. Each layer can only refuse; none can widen what an earlier layer allowed.

**1. Before an event is recorded.** Every event is checked against its context first: the frontmost app, the window title and web address, and the focused element. The event is dropped when:

- the app is on your exclusion list, is a known password manager, or is DayDream itself;
- the app is a known web browser (Safari, Edge, Firefox, Arc, Brave and dozens of others on a fixed list, with their beta and developer editions). The only exception is Google Chrome while Web pages in Chrome is on, and then only through the Chrome page reader and, with typed text on too, the Chrome typing check described below;
- the window looks private or incognito;
- macOS secure input is on, or the field is a password field;
- the web address is on your blocked-site list or a built-in list of sensitive sites, or contains words such as `login`, `password`, `checkout`, `bank` or `wallet`;
- the focused element is unknown.

**2. Chrome pages.** With Web pages in Chrome on, DayDream asks Google Chrome over Apple Events, on this Mac only, for each window's mode and the title and address of the tab in front. It first checks that the running Chrome is signed by Google. It saves nothing while any window is Incognito or Guest, while Chrome's answer is unclear, while more than one copy of Chrome runs, or while secure input is on. It keeps the title, the site and, on this Mac only, the page's link without its search terms or tracking and token parts (a YouTube video keeps its video and time; Open Original opens it; AI apps and cloud summaries never get it); common search, email and chat sites keep the site only, with no link. A built-in list of banking, password, sign-in, payment, credit, health, reproductive health and government sites is skipped by default, and you can add your own. [browser-capture.md](browser-capture.md) has the details and the release switch.

**3. Typed text.** Characters are read only after the checks above pass and a fresh check of the focused field (less than one second old) confirms an ordinary text field in an allowed app, or, in Google Chrome, a fresh check of the page. For Chrome, DayDream asks Chrome over Apple Events for its windows (their mode, position and title) and the address of the tab in front, and matches them against the focused field through Accessibility. It refuses when any window is Incognito or Guest, the field is a password field or labelled as a card number, one-time code, PIN, password or web terminal, the page has more than one web area (such as an embedded frame), the site is blocked (the Chrome page history list, web terminals and cloud consoles, sign-in and payment pages, Google Docs and your own sites), or the checkbox for the site's kind is off. It keeps the words, the site, the page's title where Chrome page history saves it (webmail keeps the open email's subject; common search and chat sites keep the site only) and, when the message box names it, who a message went to (a chat's channel or person, an email's To name), never the rest of the address; cloud summaries, if you turn them on, get the words, the site, the page title (on webmail, the email's subject), cleaned of any address and unread count, and who it went to. In apps too, a message keeps who it went to when the app shows it (the Messages conversation's name, a chat's channel or person, Mail's To name). Password fields are refused before any character is read. In a terminal, passwords typed right after `sudo`, `ssh` and similar commands are skipped. After `ssh`, nothing more is recorded in that terminal until you switch to another tab, window or app; if you come back to the remote session, what you type there can be recorded. A script or custom password prompt can be missed. Typed text is gathered into short units held only in memory, and a local classifier checks each whole unit before it is saved. It drops the unit if it looks like a secret: private keys, API tokens, bearer tokens and JWTs, card-length digit runs, strings shaped like ID or account numbers, `password: …`-style text in several languages, and similar. A unit that passes is encrypted before it is written (AES-GCM, one key per day, the keys kept in your Keychain). The exact words are deleted after 7 days unless you choose another time, leaving a short note of where you typed; AI apps get that note and the summaries, never the saved words. A summary can say what a message was about ("Texted Mom about calling tonight"). Cloud summaries, when you turn them on, get the words themselves (see 5). Window titles can include words you typed, like an email subject or a shell command, and AI apps and cloud summaries get them like any other window title. [PrivacyPolicy/README.md](../PrivacyPolicy/README.md) describes the units and the classifier.

Switching keyboard layouts, pausing, sleep and changes to your settings discard any pending text instead of saving it. Moving to another field, window or app saves it, except into a password field or a password manager, or while secure input is on. On websites, pending text is saved when you press Return or move to another field on the same page (with Tab or a click); switching to another tab, window or app first discards it.

**4. At storage.** The store repeats the app, site, private-window, secure-input and retention checks before writing, and cleans what it keeps:

- a window title that looks like a secret is replaced with `[sensitive title omitted]`; others are cut to 160 characters;
- typed text is kept only if the typed-text setting is on and the text does not look like a secret;
- web addresses lose any user name, password and `#fragment`, and every query parameter except the search terms `q`, `query` and `search_query`. A search term that looks like a secret is dropped too;
- a Chrome page row is accepted only while Web pages in Chrome is on;
- a website typing row is accepted only from a valid Chrome check, while recording and under the settings it was decided with; the store then checks the typing pause, the site rules and the secret classifier again before it encrypts the words.

**5. Before anything is shared.** Summaries and connected AI apps read history through the same store. The current privacy settings are checked again before a summary is prepared, before it is sent to a cloud provider, after the reply and before the result is saved. Changing your settings restarts cloud summaries under the new settings; nothing prepared under the old ones is sent. They stay on across a relaunch. Cloud summaries get the words you type while typed text is on, and Chrome page titles and sites, cleaned of web addresses and unread counts.

The code for these layers:

| Layer | Code |
| --- | --- |
| App, site and private-window rules | `Sources/HistoryCore/Policy.swift`, `Sources/HistoryCore/KnownBrowsers.swift`, `Sources/MemoryCore/PreCapturePrivacy.swift`, `Sources/MemoryCore/CaptureSession.swift` |
| Chrome pages | `Sources/MemoryCore/ChromePages.swift`, `Sources/MemoryCore/BrowserSites.swift`, `Sources/MacMemApp/ChromePageRecorder.swift`, `Sources/MacMemApp/ChromeEventSender.swift` |
| Typed-text gate, classifier and units | `PrivacyPolicy/` (see its README), `adapters/CoreCaptureBinding.swift`, `Sources/MacMemApp/EventCapture.swift` |
| Typing on websites in Chrome | `Sources/MemoryCore/BrowserTypingJoin.swift`, `Sources/MacMemApp/ChromeTypingWitness.swift`, `Sources/MacMemApp/WebTypingRoute.swift`, `PrivacyPolicy/Sources/PrivacyPolicy/WebTypingGate.swift`, `PrivacyPolicy/Sources/PrivacyPolicy/TypingSites.swift` |
| Storage cleaning | `Privacy.sanitized` in `Sources/MemoryCore/Models.swift` |
| What cloud summaries may read | `NoteAudience` in `Sources/MemoryCore/DerivedNotes.swift` |

## Where the history lives

Everything is stored in `~/Library/Application Support/DayDream/`. The main file is the SQLite database `memory.sqlite`. The folder is readable only by your user account (mode 0700, database 0600).

History is kept until you delete it. In the app you can forget a single moment or action. There's no way yet to delete a whole day, or all history, from inside the main window; to erase everything, follow [uninstall.md](uninstall.md). Excluding an app stops new recording and hides its existing history, but does not delete it.

## What can leave your Mac

DayDream has no account, analytics or crash reporting. History leaves your Mac only in these cases, each of which you have to set up or choose:

- **Cloud summaries.** Off unless you turn on the **Use an OpenRouter key instead** switch with a working OpenRouter API key. They then send the actions being summarized (app names, window titles, which can include words you typed, sites, page titles, the words you type when typed text is on, including what you type into search boxes, and corrections you wrote to notes about those actions) to OpenRouter, asking for model hosts that don't keep data. That is a request, not a promise: OpenRouter keeps each request's time and cost, and keeps the text only if logging is on in your OpenRouter account. Chrome pages are sent as their page titles and sites, cleaned of web addresses and unread counts; addresses (and the search terms in them) are not. Only actions recorded after you turn cloud summaries on are sent; earlier history is never uploaded. See [summaries](summaries.md).
- **Open Original.** When you choose Open Original on a web link, DayDream sends one `HEAD` request (no cookies, and only for addresses without a query) to that site to check the page still exists. The site sees your IP address and the page address.
- **AI apps you connect.** The `mac-mem mcp` server lets an AI app read your history through the Model Context Protocol. Each app needs a grant, which Settings › Connections or `mac-mem grant` creates. A grant allows all three read scopes (`context`, `search` and `detail`), so a connected app can read any of your history. For typed text, it can read the words you typed and sent while **Let AI apps read what you typed** is on (on by default; Settings › Connections): the `mac-mem` process has no typing key, so the DayDream app hands it those words. With the switch off, it gets only where and about how much you typed, and your summaries. Window titles, which can include words you typed, are read like any other. What the AI app does with what it reads is governed by that app and its AI provider.
- **Backups.** Backups are unencrypted folders saved wherever you choose. If that is a synced folder such as iCloud Drive, the backup is synced too. See [backup and restore](backup-restore.md).

Two more connections carry no history: update checks, which fetch the list of versions from GitHub (on by default, and you can turn them off), and Chrome page and typing checks, which stay on this Mac.

**Summaries on this Mac** send no history: notes are written on your Mac. If typed text is on, they can use the words DayDream saves from your typing, and nothing leaves your Mac to write them. They go online only in two ways, and only after you choose On this Mac:

- **The model download.** The 2.74 GB model is downloaded from Hugging Face when you turn on Summaries on this Mac (in setup, Continue with it on), and never before. A download you started that a quit interrupted finishes after DayDream opens again. The runtime that runs it is already inside the app.
- **The signature check with Apple.** Before loading that runtime, DayDream checks its signature with the certificate status macOS has already saved. Only if that has run out does DayDream ask Apple about its signing certificate, and only when you turn On this Mac on, or when a download you started finishes after a quit. It doesn't do this when summaries on this Mac turn back on after a restart. Nothing from your history is sent.

See [summaries](summaries.md#on-this-mac).

## Known limits

These are real gaps, not edge cases:

- **The history is not encrypted.** Any program running under your macOS account can read `memory.sqlite`, whether or not it has an MCP grant. Only your login password and FileVault protect it. Time Machine and local snapshots also copy the folder, and deleting history in DayDream does not remove it from those backups.
- **The secret classifier is not password protection.** It cannot recognise an ordinary password, a passphrase made of plain words or a recovery phrase. If you type secrets into normal text boxes, leave typed text off.
- **Browsers are matched by a fixed list, and by what they declare.** A browser DayDream doesn't know by name is skipped if its `Info.plist` says it opens `http` or `https` links (see [browser-capture.md](browser-capture.md)). One that doesn't is treated as an ordinary app, so its window titles (page titles) and web addresses can be recorded, including search terms. Private-window detection for such apps relies on the window title.
- **The password manager and sensitive-site lists cover common ones.** A password manager, bank or site that is not on them is not skipped automatically. Add it to your exclusions or your own site list.
- **Search terms are kept** in web addresses that apps show. The `q`, `query` and `search_query` parts are stored unless they look like a secret. (Chrome pages keep only the site, never the search part.)
