# Privacy and security FAQ

Short answers to the questions people ask first. The [README](../README.md) and the [privacy policy](../PRIVACY.md) have the full details.

## Is this a keylogger?

Only while typed text is on. It uses the same macOS permissions a keylogger would, and once typed text is on it saves what you type in the places below.

- Setup shows typed text switched on, with one line. One click turns it off, then or any time in Settings. Nothing is recorded before you press Start Recording. While it's off, DayDream ignores key presses completely.
- While it's on, DayDream saves what you type **only** in the apps on a fixed list (Notes, TextEdit, Pages, Obsidian, Spotlight, Claude, ChatGPT, Terminal, Ghostty, Xcode and Cursor, plus Messages, Mail and WhatsApp while Messages and email is on, which it is unless you turn it off) and on websites in Google Chrome. In apps, it also notes that you pressed Return or a keyboard shortcut, but not which one. The README's [Typed text](../README.md#typed-text) section has the full list.
- Websites need two switches: typed text and Web pages in Chrome. Nothing is saved from Chrome while any Incognito or Guest window is open, or on blocked sites such as banking, sign-in and payment pages.
- It never reads password fields, and it drops typed text that looks like a key, a card number or a one-time code.
- What you type is encrypted on your Mac. DayDream deletes the exact words after 7 days, unless you choose another time, and keeps a short note of where you typed.
- AI apps you connect read the words you typed and sent while **Let AI apps read what you typed** is on (Settings › Connections, on by default); with it off they see where and about how much you typed, never the words DayDream saves. Cloud summaries, if you choose them, get the words you type to write your notes. Window titles can include words you typed, like an email subject or a shell command. Those are saved, read by AI apps and sent to cloud summaries like any other window title.
- DayDream can't tell when Claude or ChatGPT is in an incognito or temporary chat. Turn off Search boxes and AI prompts, or turn typed text off, before you use one.
- It never records what you type in any other app or browser.
- Anyone typing on your Mac account while it's on is recorded as you.
- It only listens. It can't change or block what you type.
- Everything stays on your Mac unless you choose to send it somewhere (see below).
- The code is open, so you can check all of this yourself.

## What leaves my Mac?

Only what you choose, plus a check for updates (below):

- **Cloud summaries** (off until you turn on their switch and add your own OpenRouter key) send the activity being summarized, including words you type, to OpenRouter.
- **An AI app you connect** can read your history, and can send what it reads to its own AI provider.
- **A backup** you save to iCloud Drive or another synced folder is uploaded by that service.
- **"Open Original"** on a web link sends one request to that website to check the page still exists.

DayDream also checks its website for updates and downloads them from GitHub, unless you turn that off. Those requests carry no history. Summaries on this Mac send no history either: choosing them downloads the model from Hugging Face, and pressing Download or Turn on may check DayDream's signing certificate with Apple. The full list is in the README's [Network connections](../README.md#network-connections).

## Do you (the developers) see my data?

No. DayDream has no account, analytics, telemetry or crash reporting. We never receive your history, your settings or anything about how you use the app. If you open a GitHub issue, what you write there is public, so never paste your history into one.

## Does it take screenshots or record my screen?

No. It doesn't take screenshots, record the screen, read text off the screen, or use the microphone or camera. It reads app names and window titles through macOS Accessibility.

## Does it record my passwords?

It tries hard not to:

- Nothing is read while a password field has focus or while macOS secure input is on.
- Common password managers, such as 1Password, Bitwarden and Apple Passwords, are skipped entirely. Add any others to your excluded apps.
- A window title that looks like a secret is saved as "[sensitive title omitted]".
- With typed text on, text that looks like a key, a card number, a one-time code or a `password: ...` line is dropped.

It can't reliably spot an ordinary password or passphrase that you type as plain text. If you type secrets into normal text boxes, leave typed text off.

## Does it record my web browsing?

Only in Google Chrome, while **Web pages in Chrome** is on. Setup shows it switched on, and one click turns it off. With it on, it saves the title, the site, the link and the time of the page in front. The link keeps no search terms and stays on this Mac. It never saves what's on the page. If typed text is on too, it also saves what you type on websites, with the site. It saves nothing from Chrome while any Incognito or Guest window is open.

Safari, Arc, Edge, Brave, Firefox and the other browsers DayDream knows are never recorded. A browser it doesn't know by name is skipped too if it opens web links. One that doesn't is treated like any other app, so its window titles are saved; exclude it in Settings. [PRIVACY.md](../PRIVACY.md#browser-history-google-chrome) has the details.

## Is my history encrypted?

Not yet, except what you type: typed text is encrypted, with a key kept in your Keychain. The rest of your history is a regular database file in your user folder. Other users on your Mac can't open it without administrator rights. Turn on FileVault (System Settings › Privacy & Security › FileVault) so your disk is encrypted while your Mac is off. Encrypting the history itself is planned.

## Can other apps read my history?

Yes. Any app or tool that runs as you on your Mac can read the file, just as it can read your documents. That's why it matters to run only software you trust. Connecting an AI app through DayDream records which apps you allowed, but it isn't a lock against other software on your Mac.

## What can an AI app I connect see and do?

It can read your history: moments, apps, window titles, Chrome pages if that's on, and DayDream's notes. Typed text is on by default, and it can read the words you typed and sent while **Let AI apps read what you typed** is on (also on by default; Settings › Connections). With that switch off, it sees only where and about how much you typed, and your summaries. It can't start or stop recording, change settings or delete anything. What it reads may go to its AI provider, under that provider's policy. Disconnect it any time in Settings › Connections.

Text in your history, such as a page title, could try to steer the AI. DayDream labels what it returns as data, not instructions, but it can't control what the AI app does.

## What do cloud summaries send, and to whom?

App names, window titles (which can include words you typed), Chrome page titles and sites (cleaned of web addresses and unread counts), the words you type when typed text is on, and corrections you wrote to notes, for the moments being summarized. Only activity recorded after you turn them on. It goes to OpenRouter, which passes it to a model host that is asked not to keep it. OpenRouter keeps the time and cost of each request, keeps the text only if logging is on in your OpenRouter account, and bills your OpenRouter account. You add your own key; we never see it.

## Why does it need Accessibility and Input Monitoring?

Accessibility lets it read which app is in front and the window title. Input Monitoring lets it notice clicks, and, only if typed text is on, what you type in the apps and websites you turn typing on for. Without both, recording can't start.

## Why does it ask to control Google Chrome?

Only while Web pages in Chrome is on. That's how DayDream asks Chrome for the title and address of the tab in front, and whether any window is Incognito. If typed text is on too, it also asks where Chrome's windows are, to check which site you're typing on. It never runs scripts in Chrome or changes anything in it. You can turn it off in System Settings › Privacy & Security › Automation.

## Does recording start by itself?

You start recording, and it stays on until you pause or stop it. If your Mac sleeps, locks or switches users while recording, DayDream starts recording again when you come back. If recording was on when you quit DayDream, restarted your Mac or installed an update, it starts again when DayDream opens. If it can't, DayDream tells you why.

## Can I use it to watch someone else?

No. Use DayDream only to record yourself, on your own Mac user account. Don't install it on anyone else's Mac or account. Using it to watch other people can be illegal.

## How do I delete everything?

Follow [docs/uninstall.md](uninstall.md). DayDream can remove itself and your history, and the page lists the few things macOS makes you remove yourself.

## How do I know the download is really from DayDream?

The app is signed with its developer's Apple Developer ID and notarized by Apple, so macOS checks it when you open it. Each release lists the download's SHA-256 fingerprint; the [install guide](install.md#check-the-download-optional) shows how to compare it. Updates are signed too, and DayDream refuses an update whose signature doesn't match.

## Is it open source?

Yes. The code is at [github.com/getnorthlight/daydream](https://github.com/getnorthlight/daydream) under the MIT License. You can read it, and [build it yourself](../README.md#build-from-source).

## How do I report a security problem?

Privately, through GitHub's [private vulnerability reporting](https://github.com/getnorthlight/daydream/security/advisories/new). Please don't open a public issue. See [SECURITY.md](../SECURITY.md).
