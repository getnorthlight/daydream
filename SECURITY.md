# Security policy

DayDream records activity on your Mac, so we take reports about it seriously. Thank you for helping keep its users safe.

## Reporting a vulnerability

Please report security problems **privately** through GitHub:

**[Report a vulnerability](https://github.com/getnorthlight/daydream/security/advisories/new)** (the repository's Security tab, then "Report a vulnerability").

- Don't open a public issue, discussion or pull request for a security problem.
- Don't include real captured history, window titles, typed text or database files, yours or anyone else's. Reproduce the problem with demo data instead: `mac-mem --home <empty folder> demo` creates a throwaway history.
- Tell us the DayDream version (DayDream › About DayDream) or commit, your macOS version, and the steps to reproduce. The details from Help › Report a Problem help, and contain no history.

DayDream is a small project. We aim to acknowledge a report within 7 days, keep you updated while we work on it, and agree a disclosure date with you, normally within 90 days. We'll credit you in the advisory unless you'd rather we didn't.

## Supported versions

DayDream is in beta. Only the latest release, and the `main` branch, get security fixes. Updates reach people through DayDream's built-in updater.

| Version | Supported |
| --- | --- |
| Latest 0.x beta | Yes |
| Older betas | No |

## Threat model

This section says what DayDream protects against today and what it doesn't. The [guide](docs/guide.md#what-daydream-records) lists exactly what is recorded.

### What is stored, and where

- History is stored only on your Mac, in `~/Library/Application Support/DayDream/memory.sqlite`. The folder is created with permissions `0700` and the database with `0600`, so other macOS user accounts can't open it without administrator rights.
- **The history is not encrypted.** Any process running under your macOS account can read it: another app, a script, a package's install hook, or an AI coding agent that has been tricked by a prompt injection. DayDream's own `mac-mem` tool can also read it with `--local`, without any grant. Until encryption lands, the protections are your macOS login, FileVault and not running software you don't trust.
- Anyone who can use your unlocked Mac can open DayDream and search your history.
- Backups are **not encrypted**. They leave out AI app grants and the cloud API key, but anyone who can read the backup folder can read the history in it. A backup saved to a synced folder is uploaded to that service.
- A cloud API key, if you add one, is stored in your macOS Keychain (service `DayDream.Writer.OpenRouter`), not in the database.

### The MCP server (connecting AI apps)

- `mac-mem mcp` is a read-only MCP server. The AI app starts it as a child process and talks to it over standard input and output. It opens no network port.
- Its tools are `status`, `context`, `current-context`, `search`, `read`, `open`, `recall` and `recap`. None of them can start or stop recording, change settings, create grants or delete anything.
- Every tool except `status` requires a grant: a client and recipient label plus a secret token. Settings › Connections creates one when you connect an app, and `mac-mem grant` creates one by hand. The database stores only the token's SHA-256 hash. `status` answers without a grant. It reveals whether DayDream is recording and why, when the last action was recorded, and summary progress; as a setup check, it also says whether the calling app's own grant works (checked with the token it was started with), which settings are on (typed text, Web pages in Chrome, summaries), and when typing was last saved within the past 24 hours. It holds no titles, addresses or typed text.
- Changing which apps, typing or web pages are recorded, and restoring a backup, revoke every grant. The AI apps have to be connected again.
- **Grants are not a security boundary against local software.** Anything that can run programs as you can create its own grant or read the database directly. Grants record which AI apps the owner allowed; they don't stop other local code.
- Recorded text can contain words written by other people, such as a page title or a chat name. DayDream labels everything it returns as untrusted data, not instructions, but it can't stop an AI app from acting on it. Whatever an AI app reads, it may send to its own AI provider.

### Typed text

- On by default: setup shows it switched on, and one click turns it off, then or any time in Settings. Nothing is recorded before Start Recording. When on, DayDream records what you type in a fixed list of apps, each checked by its code signature, and, only while Web pages in Chrome is on too, on websites in Google Chrome. The guide's [Typed text](docs/guide.md#typed-text) section lists the apps, the websites and what is always skipped.
- The words are encrypted with AES-GCM, one key per day, and the keys are kept in your macOS Keychain. Where and when you typed, and how much, are not encrypted. DayDream deletes the exact words after 7 days unless you choose another time. Time Machine backups of your Mac can keep older encrypted copies.
- `mac-mem`, which AI apps start as the MCP server, has no typing key. While **Let AI apps read what you typed** is on, the DayDream app (which holds the key) hands it the words of the moments an AI app asks for, over a socket only this Mac account can open (mode 0600, same user checked), after checking that AI app's key; secrets, private windows, excluded apps, blocked sites and expired words are never handed over. While it is off, or DayDream isn't open, AI apps get where and about how much you typed, never the words DayDream saves. Cloud summaries, when you turn them on, get the words you type, who a message went to, and Chrome page titles and sites (never web addresses). Window titles, which can include words you typed, are read and sent like any other window title.
- Anyone typing on your macOS account while typed text is on is recorded as you.

### Chrome page history

- On by default: setup shows it switched on, and one click turns it off, then or any time in Settings. macOS asks for Chrome access right after setup starts recording (or the first time Chrome comes to the front, if it isn't running), and again only when the user presses Allow… in Settings. When on, DayDream sends Apple Events to Google Chrome, on this Mac only, to read the title and address of the tab in front and each window's mode. With typed text on too, it also reads where each Chrome window is and its title, to match the field you type in. It never runs scripts in Chrome.
- It reads only a Chrome that is signed by Google, only when no Incognito or Guest window is open, and it keeps only the page title and site, plus, with typed text on, the words you type and the site. See [PRIVACY.md](PRIVACY.md#browser-history-google-chrome).

### Network

DayDream has no analytics or telemetry. It contacts the network only in these cases:

- **Update checks** (on by default, can be turned off): Sparkle 2.9.6 fetches the list of versions from this repository's GitHub Releases. The list must be signed with DayDream's update key (EdDSA), and so must each update. No system profile is sent.
- **Cloud summaries** (off by default): the activity being summarized is sent to `openrouter.ai` with the user's own API key. Each request requires a zero-data-retention provider, denies data collection and disables fallback providers. OpenRouter still keeps request metadata. The words you type are included, and so are Chrome page titles and sites, cleaned of web addresses and unread counts.
- **"Open Original"** on a web link: one `HEAD` request to that HTTPS address, without cookies, credentials, redirects or query strings.

### Builds

- Releases are built from a clean checkout of one commit, which the release records, signed with the maintainer's Apple Developer ID, notarized by Apple and stapled. Each release lists the SHA-256 of its disk image, taken after stapling. [RELEASE.md](RELEASE.md) has the steps.
- Check an installed copy with `spctl -a -vv /Applications/DayDream.app`. It should report `source=Notarized Developer ID`.
- `scripts/bootstrap.sh` checks the one downloaded build dependency, Sparkle, against a pinned SHA-256.

### What we most want to hear about

Reading the history from code that already runs as the same macOS user is a known, documented limit. Reports that go further are very welcome, for example:

- DayDream recording while recording is off, or recording something it says it never records (password fields, secure input, excluded apps, known browsers, Chrome pages or website typing while the switch is off or while an Incognito or Guest window is open, typed text when that's off or in an app or on a site it doesn't cover);
- secrets that get past the redaction of titles and typed text;
- a way for an MCP client to write, delete, raise its own access, or read without a valid grant (other than `status`);
- a backup or restore that can write outside the folder it was given, or restore data it shouldn't;
- an update or feed that DayDream accepts without a valid signature;
- DayDream sending data anywhere not listed above.
