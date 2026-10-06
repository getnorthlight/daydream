# DayDream

DayDream remembers which app and window you were in on your Mac, and when. It keeps that history on your Mac, so you, or an AI app you connect, can later ask "where was I?".

> [!IMPORTANT]
> **DayDream is beta software (version 0.1).** The download is signed with its developer's Apple Developer ID and notarized by Apple. Expect bugs. Your history is **not encrypted** yet, so turn on FileVault. Please read [What DayDream records](#what-daydream-records) and [Known limits](#known-limits) before you install it.

<p align="center"><img src="docs/images/menu-bar.png" width="320" alt="DayDream's menu bar panel while recording: Recording since 8:38 AM with the switch on, Pause, 4 moments remembered today, Search, Open DayDream, Settings and Quit."></p>
<p align="center"><sub>The menu bar panel, drawn with sample data.</sub></p>

## Contents

- [What DayDream records](#what-daydream-records)
- [What it doesn't record](#what-it-doesnt-record)
- [Browser history (Google Chrome)](#browser-history-google-chrome)
- [Use it on your own Mac](#use-it-on-your-own-mac)
- [Install](#install)
- [Permissions](#permissions)
- [Using DayDream](#using-daydream)
- [Summaries](#summaries)
- [Connect an AI app](#connect-an-ai-app)
- [Updates](#updates)
- [Your data](#your-data)
- [Uninstall](#uninstall)
- [Network connections](#network-connections)
  - [Usage counts](#usage-counts)
- [Known limits](#known-limits)
- [Report a problem](#report-a-problem)
- [Build from source](#build-from-source)
- [Project layout](#project-layout)
- [Contributing and security](#contributing-and-security)
- [License, trademarks and credits](#license-trademarks-and-credits)

## What DayDream records

DayDream records only while recording is on. You turn it on with the switch in the menu bar panel, and it stays on until you pause or stop it. If it was on when DayDream quit or your Mac restarted, it starts again when DayDream opens. The menu bar icon shows whether it's recording.

While recording is on, DayDream saves:

- **Which app is in front**, and when you switch apps.
- **The title of the window you're using.** Window titles often contain document names, email subjects, chat names or page titles. A title that looks like a secret (a password, an API key or token, a long random string) is saved as "[sensitive title omitted]" instead.
- **That you clicked**, and in which app and window. Not where you clicked or what you clicked on.
- **Web addresses that apps show** (for example an app with a built-in web view), trimmed to the site and page. Everything after `?` is removed except search terms in `q`, `query` or `search_query`, and anything after `#` is removed.
- **What you type, while typed text is on.** Setup shows it switched on, with one line. One click turns it off, then or any time in Settings. Nothing is recorded before you press Start Recording. See [Typed text](#typed-text).
- **Page titles and sites in Google Chrome, while Web pages in Chrome is on.** Setup shows it switched on too, and one click turns it off. See [Browser history](#browser-history-google-chrome).
- **Notes it writes** from the above, if you turn on [summaries](#summaries).

### Typed text

Setup shows typed text switched on, and one click turns it off, then or any time in Settings. When it's on, DayDream saves what you type in these apps, each kind with its own checkbox in Settings › Apps to remember:

| Kind | Apps | Websites in Google Chrome | On when you turn typing on? |
| --- | --- | --- | --- |
| Search boxes and AI prompts | Spotlight, Claude, ChatGPT | Search engines and AI chats | Yes |
| Writing apps | Notes, TextEdit, Pages, Obsidian | Notion | Yes |
| Code | Terminal, Ghostty, Xcode, Cursor | None | Yes |
| Messages and email | Messages, Mail, WhatsApp (your own messages only) | Email and chat sites, and social sites with chat, like Facebook and LinkedIn | Yes |
| Other websites | | Any other website, except blocked sites | Yes |

- **No other app's typing is recorded**, and no other browser's.
- **Websites need two switches.** What you type on websites in Google Chrome is saved only while typed text **and** [Web pages in Chrome](#browser-history-google-chrome) are both on. DayDream saves the words, the site (like `wikipedia.org`), the page's title where Chrome page history saves it (webmail keeps the open email's subject; common search and chat sites keep the site only) and, when the message box shows it, who a message went to (a chat's channel or person, an email's To name), never the rest of the address. Cloud summaries, if you turn them on, get the words, the site, the page title (on webmail, the email's subject), cleaned of any address and unread count, and who it went to.
- **Always skipped:** password fields and anything typed while macOS secure input is on; everything in Chrome while any Incognito or Guest window is open; blocked sites (common banking, password, sign-in, payment, health and government sites, web terminals and cloud consoles, sign-in and payment pages, Google Docs, and sites you add); web fields for card numbers, one-time codes, PINs and passwords; and passwords typed right after `sudo`, `ssh` and similar commands in a terminal (see [Known limits](#known-limits)). After you run `ssh`, DayDream stops recording in that terminal until you switch to another tab, window or app. If you come back to the remote session, what you type there can be recorded.
- Text that looks like an API key, a card number, a one-time code or a `password: ...` line is dropped. DayDream can't reliably spot an ordinary password typed into a normal text box, so leave typed text off if you type secrets there.
- In apps, DayDream also notes that you pressed Return or a keyboard shortcut, but not which one.
- **Who it went to.** With a message, DayDream keeps who it went to when the app shows it: the Messages conversation's name, a chat's channel or person, an email's To name. Cloud summaries get it with the words.
- **Encrypted on this Mac.** What you type is encrypted, with a key DayDream keeps in your Keychain. DayDream deletes the exact words after 7 days, unless you choose another time in Settings, and keeps a short note of where you typed.
- **AI apps read the words only if you let them.** With **Let AI apps see your typed words** on (Settings › Connections; on by default), AI apps you connect can read the words you typed and sent, through the DayDream app while it is open: never passwords, secrets, private windows, excluded apps, blocked sites or words past their kept time. With it off, they see where and about how much you typed, and your summaries, never the words DayDream saves. A summary can say what a message was about ("Texted Mom about calling tonight"). If you choose cloud summaries, they get the words you type, to write your notes. Window titles can include words you typed, like an email subject or a shell command. Those are saved, read by AI apps and sent to cloud summaries like any other window title.
- **Anyone typing on this Mac account while it's on is recorded as you.** Turn typed text off while they use it, or give them their own macOS user. The typing pause lasts only 10 minutes.

## What it doesn't record

- **No screenshots, no screen recording, no reading text off the screen, no audio.**
- **Password fields.** Nothing is read while a password field has focus or while macOS secure input is on.
- **Selected text, what's already in text fields, and what Terminal shows.** Typed text, when it's on, saves only what you type.
- **Known web browsers**, except Google Chrome when you turn it on. Safari, Arc, Edge, Brave, Firefox, Opera, Vivaldi, DuckDuckGo, Tor Browser and dozens of other browsers DayDream knows are skipped entirely, with their beta and developer editions. A browser DayDream doesn't know by name is skipped too if it opens web links; see [Known limits](#known-limits).
- **Common password managers**, such as 1Password, Bitwarden and Apple Passwords. Add others to your excluded apps in Settings › Apps to remember.
- **Apps you exclude** in Settings › Apps to remember. DayDream never records itself either.
- **Windows whose title marks them as private or incognito.**

Other apps, including messaging, mail, banking and health apps, **are** recorded unless you exclude them.

## Browser history (Google Chrome)

Setup shows **Web pages in Chrome** switched on, with one line. One click turns it off, then or any time in Settings › Apps to remember. Nothing is saved from Chrome until macOS lets DayDream control Google Chrome. Setup's Google Chrome row asks: press **Allow** there, then Allow in the box macOS shows (if Chrome is closed, it opens in the background to ask). If you say no, the row and the menu bar say so, with **Ask again**: DayDream clears its own answer for Google Chrome and macOS asks again.

- When on, DayDream saves the title, site and link of the page in front in Google Chrome, and when. Links keep no search terms and stay on this Mac. It never saves what's on the page or your clicks. It saves what you type on websites only if [typed text](#typed-text) is on too.
- While any Incognito or Guest window is open, DayDream saves nothing from Chrome.
- Search engines save what you searched for, never the rest of the address. Common chat sites save the site only. Email sites save the folder or the open email's subject while Save email subjects is on (never codes, passwords, sign-ins or bank mail), and typing in webmail keeps the open email's subject.
- Common banking, password, sign-in, payment, health and government sites are skipped. You can add your own, or use "Don't record this site".
- Work and personal Chrome profiles are both saved. Pages are kept on this Mac, unencrypted. AI apps you connect can read them, and what they read goes to their AI provider. Cloud summaries, if you turn them on, send the titles and sites of the pages they summarize to OpenRouter. Page links stay on this Mac.
- Safari, Arc, Edge, Brave, Firefox, Chrome Beta and Canary, and the other browsers DayDream knows, aren't recorded. A browser DayDream doesn't know by name is skipped too if it opens web links. One that doesn't is treated like any other app (its window titles are saved); exclude it in Settings › Apps to remember.

| Browser history | |
|---|---|
| Saved | Page title, site (like `wikipedia.org`), link and time, for the Chrome page in front. The link keeps no search terms and stays on this Mac (Open Original opens it); AI apps and cloud summaries get the title and site only |
| Typing | Saved only while typed text is on too: the words and the site. See [Typed text](#typed-text) |
| Never saved | Page text, clicks, the rest of the address (a search engine's page keeps only what was searched for), background tabs, blocked sites, anything while an Incognito or Guest window is open |
| Browsers | Google Chrome only. A browser DayDream doesn't know by name is skipped too if it opens web links. |

More in [PRIVACY.md](PRIVACY.md).

## Use it on your own Mac

Use DayDream only to record yourself, on your own Mac user account. Don't install it on anyone else's Mac or account. If someone else uses your account, stop recording (a pause ends on its own) or give them their own macOS user. If you use it at work, your employer's rules apply. DayDream isn't a monitoring tool: using it to watch other people can be illegal.

## Install

You need a Mac with Apple silicon and macOS 15 or later. DayDream is tested on macOS 26.

1. Download `DayDream-<version>.dmg` from the [Releases page](https://github.com/getnorthlight/daydream/releases/latest).
2. Open it and drag DayDream to Applications.
3. Open DayDream from Applications. Setup walks you through the two permissions and your choices.
4. Press **Start Recording**.

The [install guide](docs/install.md) has every step, with pictures, and how to check the download's fingerprint.

## Permissions

DayDream needs two macOS permissions to record. Setup explains both and opens the right page of System Settings › Privacy & Security.

| Permission | Why DayDream needs it |
| --- | --- |
| **Accessibility** | To read which app is in front and its window title, and to check that a text field is safe to read before any typed text is saved. |
| **Input Monitoring** | To notice clicks while recording, and, only if typed text is on, what you type in the apps and websites you turn typing on for. While typed text is off, key presses are ignored. DayDream only listens: it can't change or block what you type or click. |
| **Automation: Google Chrome** (optional) | Only while Web pages in Chrome is on. It lets DayDream ask Chrome for the title and address of the tab in front, and whether any window is Incognito. If typed text is on too, it also asks where Chrome's windows are, to check which site you're typing on. It never runs scripts in Chrome or changes anything in it. |

Without Accessibility and Input Monitoring, recording won't start. If you turn either one off while recording, recording stops within about a second.

DayDream doesn't use Screen Recording, the microphone or the camera.

The first time you start recording, macOS also asks whether DayDream may show notifications. DayDream uses them only to tell you when recording stopped, or didn't start again, without you asking. You can say no; the menu bar panel says why too.

## Using DayDream

- **Record:** start, pause and stop recording from the menu bar. You can pause for 5, 15 or 30 minutes or 2 hours.
- **Sleep and lock:** when your Mac wakes, unlocks or you switch back to your user, recording starts again by itself if it was on before. If it can't, DayDream shows a notice that says why and how to start again. If DayDream can't save for a moment, recording pauses and starts again by itself; you get a notice only if saving keeps failing for two minutes. If recording was on when DayDream quit or your Mac restarted, it starts again when DayDream opens, and DayDream says why if it can't. DayDream opens at login; Settings › Advanced has the switch.
- **Look back:** the main window shows your day as moments on a timeline. Search finds past activity by app, window title, site or what you typed (typed words are searched on this Mac only, while they're kept).
- **Forget:** "Forget This Moment" deletes a moment from your history.
- **Exclude:** excluding an app stops new recording from it and hides what was already recorded. Excluding more keeps AI apps connected. A change that records more (an app or site no longer excluded, or typed text or Chrome pages turned on) disconnects AI apps until you reconnect them (Settings › Apps to remember then offers **Reconnect**). Recording pauses for the save and starts again by itself if it was on. The other typed text choices, like how long exact words are kept, apply at once and do neither.
- **Back up and restore:** Settings › Advanced › Backup and restore saves your history to a folder you choose and can merge it back later. Backups are **not encrypted**, and they leave out your API key and AI app connections. If you save one to iCloud Drive or another synced folder, your whole history is uploaded there. See [docs/backup-restore.md](docs/backup-restore.md).

## Summaries

Summaries are short notes DayDream writes about your moments and days. Setup turns on summaries on this Mac unless you choose otherwise, and not every moment or day gets one (see [Known limits](#known-limits)). Your history is complete without them.

There are two kinds, each a switch in setup and in Settings › Summarizer. Turning one on turns the other off; turning it off stops it at once. Recording never waits for either.

**On this Mac.** Notes are written on your Mac, and nothing is sent to write them. The runtime that runs the model is inside the app (about 5 MB). The model itself, Qwen3.5-4B (2.74 GB), is downloaded from Hugging Face in the background when you press Continue in setup with **Summaries on this Mac** on (it's on by default on a Mac that can run it), or turn it on in Settings › Summarizer. Settings says how far the download is; closing setup doesn't stop it. It needs Apple silicon, macOS 15 or later and 8 GB of memory. If typed text is on, it can use the words DayDream saves from your typing, on your Mac, so a note can say what you asked or wrote. Cloud summaries get them too, if you turn cloud summaries on. When you turn it on, DayDream may also ask Apple about its signing certificate. If you quit during the download, it finishes after DayDream opens again (and may then ask Apple); otherwise neither happens by itself. If On this Mac was on when DayDream quit or your Mac restarted, it turns back on by itself, using only checks already on your Mac.

**Cloud summaries** use your own OpenRouter key:

- You turn on **Use an OpenRouter key instead**, in setup or Settings › Summarizer, and paste an [OpenRouter](https://openrouter.ai) API key. The line under the switch says what is sent. The key is tried when you press Continue (or Connect); if OpenRouter doesn't accept it, summaries stay off and setup says so. It's the default on a Mac that can't run summaries on this Mac.
- DayDream then sends the activity being summarized to OpenRouter: app names, window titles, page titles and sites from Google Chrome (like wikipedia.org, never the full address), the words you type when typed text is on, who a message went to, and any corrections you wrote to notes about that activity. Only activity recorded after you turn them on is sent. OpenRouter is asked to use only model hosts that don't keep your data; it keeps the text only if logging is on in your OpenRouter account.
- Each request asks OpenRouter for a model host that doesn't keep your data (zero data retention), with no fallback to other hosts. OpenRouter still keeps some details about each request, and it bills your account.
- The switch stays on when you quit DayDream or change your privacy choices; your key stays in the Keychain. If a later version changes what is sent, the switch turns off until you turn it on again.

How notes are written and checked, and exactly when On this Mac goes online, is in [docs/summaries.md](docs/summaries.md).

## Connect an AI app

DayDream includes a read-only [Model Context Protocol](https://modelcontextprotocol.io) (MCP) server, so an AI app on your Mac can look things up in your history.

**Before you connect anything:** whatever the AI app reads from DayDream, it can send to its own AI provider. Text in your history (a window title, a page title) could try to steer the AI. DayDream labels everything it returns as data, not instructions, but it can't control what the AI app does with it.

- **In the app:** Settings › Connections lists the AI apps DayDream can connect for you, each with one button. **Connect** adds one `daydream` entry to that app's settings file and changes nothing else in it. If the AI app is open, the button says **Connect & Restart**: DayDream quits the app, adds the entry and opens the app again, so it picks DayDream up. Claude Desktop then opens on a new chat with a first question typed in, for you to send; for other apps DayDream copies the question instead. The question asks the AI app to explain what DayDream does, check that it's connected and ready, and suggest three questions to ask; it doesn't ask for a recap of your day. Before each change DayDream saves a copy of the AI app's settings file next to it, if the file exists, with `.daydream-backup` added to the name (for example `~/.cursor/mcp.json.daydream-backup`). That copy can hold keys for the app's other tools; delete it when you no longer need it. **Disconnect** removes DayDream's entry again and turns its key off.
- **In Terminal:** `mac-mem connect <app>` and `mac-mem disconnect <app>` do the same. The tool is inside the app at `/Applications/DayDream.app/Contents/MacOS/mac-mem` (or under `~/Applications` if you installed DayDream there).
- **Other MCP apps:** see [Connect an AI app by hand](docs/install.md#connect-an-ai-app-by-hand).

The AI app starts `mac-mem mcp` itself and talks to it over standard input and output. The MCP server opens no network port. Its tools are `status`, `context`, `current-context`, `search`, `read`, `open`, `recall`, `recap` and `moment_details`. `status` is the setup check: whether this AI app's connection works, whether recording is on, off or paused, whether typed text is on and DayDream has saved typing in the last 24 hours (the time only, never the words), whether Web pages in Chrome is on, whether summaries run on this Mac, in the cloud or not at all, and example questions that fit those settings. An empty history on a new install reads as ready, not as a problem. `recap` gives a few days at a glance (a headline per day and a few time blocks, with what you sent, asked or worked on first; brief visits are only counted), so the AI app can answer "what have the past couple of days been like?" in a few lines. It reads DayDream's notes, never your typed words. `moment_details` reads one moment's real actions: with **Let AI apps see your typed words** on and DayDream open, the exact words you typed and sent (the DayDream app hands them over through a private local socket after checking the AI app's key), and `search` then matches typed words too; with it off, where and about how much you typed. The tools can't start or stop recording, change settings or delete anything. While [usage counts](#usage-counts) are on, the server adds one line per tool call (which AI app, which tool, how many results and how long it took, never what was asked) to a small file in DayDream's folder, which the DayDream app sends with its counts; with them off it writes nothing. The server itself never connects to anything.

A connection records which AI apps you allowed, but it isn't a lock: any program running under your macOS account can read the history file directly (see [Known limits](#known-limits)).

## Updates

DayDream checks for updates once a day at getdaydream.app and downloads a new version quietly from its [GitHub Releases page](https://github.com/getnorthlight/daydream/releases). Nothing pops up: the update installs the next time DayDream quits, or right away if you choose **Restart to Update** in the menu bar menu. You can turn automatic updates off in Settings › Advanced › App updates. Every update is signed, and DayDream refuses one whose signature doesn't match. If you were recording, recording starts again after the update relaunches DayDream.

## Your data

Your history, and everything DayDream derives from it, is in one folder:

```
~/Library/Application Support/DayDream/
```

It holds your history (`memory.sqlite`), your AI app connections and the [usage counts](#usage-counts) waiting to be sent. Only your macOS account can open the folder. Your cloud summary key, if you add one, is kept in your macOS Keychain, not in the folder. So is the key that encrypts what you type, while typed text is on. History is kept until you delete it.

DayDream was called Mac Mem while it was being built. The command-line tool is still called `mac-mem`. If you used a build from before the rename, DayDream moves your old folder here the first time it opens; see [docs/rename.md](docs/rename.md).

## Uninstall

DayDream can remove itself, with or without your history: open Settings › Advanced and choose **Uninstall DayDream…**. [docs/uninstall.md](docs/uninstall.md) has the steps, including how to remove everything by hand and how to clean up a build from before the rename.

## Network connections

Your activity is stored on your Mac. DayDream has no account and no crash reporting. It does send anonymous [usage counts](#usage-counts) to PostHog, which you can turn off; they never include your history, typed words, titles, sites or searches. It connects to the internet only in these cases:

| When | Where | What is sent |
| --- | --- | --- |
| It sends usage counts (on by default; turn off **Share anonymous usage counts** in Settings › Advanced) | `us.i.posthog.com` | About once an hour, the counts listed below, with a random ID made for this copy of DayDream. No history |
| It checks for updates (on by default; you can turn it off) | `getdaydream.app`, then `github.com` for a new version | A request for the list of versions, then the update itself. No history |
| You turn on cloud summaries | `openrouter.ai` | The activity being summarized, with your API key |
| You turn on Summaries on this Mac (in setup, it's on when you press Continue) | `huggingface.co` (it may hand the download to `us.aws.cdn.hf.co`) | A request for the 2.74 GB model file. No history |
| You turn on Summaries on this Mac, and the certificate status macOS saved has run out | Apple | A check of DayDream's signing certificate. No history. Not after a restart |
| DayDream opens after a quit that stopped a model download you started | Hugging Face, then maybe Apple | The rest of the model file, then the certificate check above. No history |
| You use "Open Original" on a web link in your history | That website | One `HEAD` request (no cookies, no query string) to check the page still exists |
| You connect an AI app | Wherever that AI app sends data | Whatever the AI app reads from DayDream |
| You save a backup to a synced folder | That sync service | Your whole history |

Web pages in Chrome doesn't use the network: DayDream asks the Chrome app on your Mac directly. Report a Problem never sends anything itself: it opens a new email in your own mail app, and nothing goes until you press Send there.

### Usage counts

So we can tell how many people use DayDream and which parts work, it sends these counts to PostHog, about once an hour:

- **Installed**: once, with the macOS version and the kind of chip.
- **Setup**: each setup step you finish: a permission allowed, the summaries you chose (on this Mac, OpenRouter or off), the AI app you connected, and setup done.
- **Once a day**: whether recording is on, paused or off; whether Accessibility and Input Monitoring are allowed; about how long DayDream recorded the day before (none, under an hour, 1–3, 3–6 or 6+ hours); which summaries are on; which AI apps are connected; whether Web pages in Chrome is on; and how many summaries were written or failed, and why (like an OpenRouter key that stopped working).
- **AI apps**: each time an AI app uses a DayDream tool: which app (Claude, Claude Code, Cursor, ChatGPT, Windsurf or other), which tool, how many results and how long it took. Never what it asked or what it got.
- **Opening and searching**: each time you open DayDream's window (from the menu bar, the Dock or another way; not when it opens by itself at login), and each search in DayDream's window, with how many results. Never what you searched.

Each count carries DayDream's version and a random ID made for this copy of DayDream, never anything from your Mac, your name or an account. DayDream asks PostHog not to keep your IP address or look up where you are. It never sends your history, typed words, window or page titles, sites, searches, notes or file names. Turn it off any time in Settings › Advanced › **Share anonymous usage counts**: sending stops at once and anything waiting is dropped. **See what's sent** there shows the last counts exactly as they go, and **Copy ID** copies the random ID, if you'd like us to delete its counts. Test and development builds never send. `mac-mem mcp` never sends anything itself (see [AI apps](#connect-an-ai-app)).

## Known limits

- **Beta.** Expect bugs. Please [report them](#report-a-problem).
- **Apple silicon and macOS 15 or later only.** Intel Macs aren't supported. DayDream is tested on macOS 26.
- **Your history isn't encrypted, only what you type.** It's a regular SQLite database in your user folder. Other macOS users can't open it without administrator rights, but **any app running under your macOS account can read it**, including DayDream's own command-line tool. Only your Mac login password and FileVault protect it, so turn on FileVault (System Settings › Privacy & Security › FileVault) and don't run software you don't trust.
- **Browsers DayDream doesn't know.** A browser that isn't on DayDream's list (for example a new or rare one) is skipped if it tells macOS that it opens web links, as browsers normally do. One that doesn't is treated like any other app. Its window titles, usually page titles, are saved, and so are web addresses, including search terms, if it shows them to macOS. Exclude it in Settings › Apps to remember.
- **Short skip lists.** The password manager and sensitive-site lists cover common ones. They are not complete. Exclude any other app, and add any other site, yourself.
- **Typed text only in the apps listed in [Typed text](#typed-text) and on websites in Google Chrome**, and only while typed text is on (it starts on; one click turns it off). It works only with the US, ABC or British keyboard layout, and input methods (such as Chinese or Japanese input) aren't captured. Paste, autofill and dictation aren't captured.
- **Terminal password prompts.** DayDream can't always tell when a terminal is asking for a password. Passwords typed right after `sudo`, `ssh` and similar commands are skipped, but a script or custom prompt can be missed. If you switch to another tab, window or app while a password prompt or a remote `ssh` session is open, what you type there after you come back can be recorded.
- **ChatGPT needs an accessibility setting turned on.** ChatGPT's app shows its prompt box to DayDream only with the setting VoiceOver uses. While typed text and AI prompts are on, DayDream turns that setting on for ChatGPT, and off again when recording or typing stops or DayDream quits. While it's on, ChatGPT uses a little more memory, and window managers such as Rectangle move its windows more slowly. The first key after ChatGPT opens isn't recorded. See [privacy-model.md](docs/privacy-model.md).
- **Incognito or temporary chats in Claude and ChatGPT.** DayDream can't tell when Claude or ChatGPT is in an incognito or temporary chat, so what you type there is saved like any other prompt. Turn off Search boxes and AI prompts, or turn typed text off, before you use one.
- **History is kept until you delete it.** There's no setting yet to expire old history automatically.
- **Summaries are experimental, and many moments get none.** A note covers at most 400 recorded actions, so very long moments get none. Cloud summaries cover only activity recorded after you first turned them on (they stay on across a quit), so earlier moments are written on your Mac or by code, or stay without notes. Their actions stay as they are. Notes can still be wrong.
- **Summaries on this Mac need memory.** They need 8 GB of memory, and the model uses several GB while it's loaded. They have been tested on macOS 26 only.

## Report a problem

In DayDream, choose **Report a Problem…** in the menu bar menu or the Help menu. It opens a new email to support@getdaydream.app in your mail app, with a "What happened?" section for you and a few details: app and macOS version, whether Accessibility, Input Monitoring and Chrome automation are on, whether recording is on, the summary mode, which AI apps are connected, recent error codes and a few counts. It never includes your history, typed words, window titles, web addresses, names, file paths or keys. Read it, write what happened, and press Send. With no mail app set up, the same text is copied for you to paste into an email.

**Never paste your history, window titles, typed text, database files or screenshots of your timeline into an issue.** Issues are public.

## Build from source

You need an Apple silicon Mac with Xcode or the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/getnorthlight/daydream.git
cd daydream
scripts/bootstrap.sh
swift build
```

`scripts/bootstrap.sh` downloads the Sparkle 2.9.6 framework (the updater) from its official GitHub release into `Vendor/`, and checks it against a pinned SHA-256 before unpacking it. It's safe to run again, and `--offline` keeps it off the network. `swift build` then builds:

- `MacMem`: the app itself;
- `mac-mem`: the command-line tool and MCP server;
- `mac-mem-backup`: the backup helper.

A plain `swift build` leaves out the release's typing flags, so typed text works only in Notes and TextEdit and typing on websites is compiled out. Release builds define both (`swift build -Xswiftc -DDAYDREAM_OWNER_TYPING -Xswiftc -DDAYDREAM_CHROME_TYPING`).

`swift build` plus the checks is the supported development loop. There's no public recipe for a runnable `.app` yet: `scripts/package.sh` needs inputs that aren't in this repository, and release builds are signed with DayDream's Developer ID ([RELEASE.md](RELEASE.md)).

Builds you make yourself aren't signed with DayDream's Developer ID. macOS treats each one as a new app, so you may need to turn the permissions on again after each rebuild. They don't check for updates: only release builds carry the update feed and DayDream's public update key. How the signed download is made is in [RELEASE.md](RELEASE.md).

You can try the command-line tool on made-up data without touching your real history:

```sh
demo="$(mktemp -d)/daydream-demo"
.build/debug/mac-mem --home "$demo" demo
.build/debug/mac-mem --home "$demo" --local search SQLite
```

Never point `demo` or other test commands at your real history folder. To run the checks, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Project layout

| Path | What's there |
| --- | --- |
| `Sources/MacMemApp` | The app: menu bar, windows, and the recorder |
| `Sources/MemoryUI` | SwiftUI views |
| `Sources/MemoryCore` | Storage (SQLite), privacy rules, search, deletion and backup support |
| `Sources/HistoryCore` | Event model and observation rules, derived from open-codex-computer-history (see [credits](#license-trademarks-and-credits)) |
| `Sources/MacMemCLI` | The `mac-mem` command-line tool and MCP server |
| `PrivacyPolicy/` | The rules that decide whether typed text may be recorded |
| `WriterBackend/` | Summaries |
| `BackupRestore/` | The `mac-mem-backup` helper |
| `BrowserBridge/` | Browser code that isn't used by the app in this version |
| `adapters/` | Glue between the app and the packages above |
| `Checks/`, `Tests/`, `scripts/*-checks.*` | Checks and tests |
| `packaging/` | `Info.plist`, icons and dependency pins |
| `docs/` | [How DayDream works](docs/README.md) |

## Contributing and security

- Bug reports and ideas are welcome in [Issues](https://github.com/getnorthlight/daydream/issues). Reproduce problems with demo data, never your own history.
- Found a security problem? Please report it privately; see [SECURITY.md](SECURITY.md).
- Questions about privacy? See the [privacy and security FAQ](docs/faq.md) and the [privacy policy](PRIVACY.md).
- Want to contribute code? See [CONTRIBUTING.md](CONTRIBUTING.md).

## License, trademarks and credits

DayDream's source code is licensed under the [MIT License](LICENSE). Copyright (c) 2026 The DayDream Authors.

The DayDream name and icon are **not** covered by that license; see [TRADEMARKS.md](TRADEMARKS.md). Third-party code and its licenses are listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md), and the app carries the same files.

DayDream builds on:

- **[open-codex-computer-history](https://github.com/hqhq1025/open-codex-computer-history)** (MIT, Copyright (c) 2026 Open Codex Computer History contributors). DayDream's event model and observation rules (`Sources/HistoryCore`) and parts of its recorder are derived from this project. Thank you.
- **[Sparkle](https://sparkle-project.org)** (MIT) for app updates.
- **[llama.cpp](https://github.com/ggml-org/llama.cpp)** (MIT), whose libraries are inside the app, and the **Qwen** model (Apache 2.0), downloaded when you choose it, for summaries on this Mac.
- **[Typesense](https://github.com/typesense/typesense)** (GPL-3.0), the unmodified official build inside the app, for search on this Mac. Its source is attached to every release.

DayDream is an independent project. It isn't affiliated with or endorsed by Apple, Google, OpenRouter or the authors of the projects above.
