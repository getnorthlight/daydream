# DayDream privacy policy

Effective October 3, 2026. This policy covers the DayDream app for Mac, version 0.1 (beta), and this GitHub project.

## The short version

- DayDream keeps a history of which apps and windows you used, and when, **on your Mac**.
- **We don't receive it.** There's no account and no crash reporting, and your history is never sent to the people who make DayDream. DayDream does send anonymous [usage counts](#usage-counts), like how often it's opened or used by AI apps, with a random ID and never your history, typed words, titles, sites or searches. Turn them off in Settings › Advanced.
- Your history leaves your Mac only when **you** choose something that sends it: cloud summaries, an AI app you connect, or a backup you save to a synced folder.
- Your history is **not encrypted** yet. Turn on FileVault.
- Use DayDream only to record yourself, on your own Mac.

## What DayDream keeps on your Mac

Only while recording is on, DayDream saves which app is in front, window titles, that you clicked, web addresses that apps show (trimmed), and when. While they're on, it also saves the title and site of the page in front in Google Chrome, and what you type in some apps (such as Notes, Spotlight and Terminal) and on websites in Google Chrome. Setup shows both switched on, each with one line. One click turns either off, then or any time in Settings. Nothing is recorded before you press Start Recording. Typing on websites is saved only while typed text and Web pages in Chrome are both on. It never takes screenshots, records audio or reads password fields. The [README](README.md#what-daydream-records) lists exactly what is and isn't saved, and [which apps and websites](README.md#typed-text) typed text covers.

What you type is encrypted on your Mac, and DayDream deletes the exact words after 7 days unless you choose another time. With a message, DayDream also keeps who it went to when the app shows it (the Messages conversation's name, a chat's channel or person, an email's To name). AI apps you connect can read the words you typed and sent while **Let AI apps see your typed words** is on (on by default; Settings › Connections). With it off, they see only where and about how much you typed, and your summaries. Summaries read the words so notes can say what you asked or sent and what it was about: on this Mac, or, if you chose cloud summaries, sent to the summary service (below). Window titles can include words you typed, like an email subject or a shell command. Those are saved, read by AI apps and sent to cloud summaries like any other window title. DayDream can't tell when Claude or ChatGPT is in an incognito or temporary chat, so turn off Search boxes and AI prompts, or turn typed text off, before you use one. Anyone typing on this Mac account while typed text is on is recorded as you.

Everything is kept in `~/Library/Application Support/DayDream/` on your Mac, until you delete it. A cloud summary key, if you add one, is kept in your macOS Keychain.

## What leaves your Mac, and only when you choose it

| You choose | Who gets it | What they get |
| --- | --- | --- |
| Cloud summaries (off until you turn on **Use an OpenRouter key instead** and add your own key) | OpenRouter, then a model host that is asked not to keep it | The activity being summarized: app names, window titles (which can include words you typed), page titles and sites from Google Chrome (like wikipedia.org, never the full address), the words you type when typed text is on, who a message went to, and corrections you wrote to notes about that activity. Only activity recorded after you turn them on. Each request asks OpenRouter to use only model hosts that don't keep your data, with no fallback. OpenRouter keeps the time and cost of each request, and keeps the text only if logging is on in your OpenRouter account. DayDream can't see that setting or which host answered, so check it once. |
| Connecting an AI app | That AI app, and its AI provider | Whatever the AI app reads from your history. For typed text, that's the words you typed and sent while **Let AI apps see your typed words** is on (on by default; never passwords, secrets, private windows, excluded apps or blocked sites), and where and about how much you typed, never the words DayDream saves, while it is off. DayDream's setup check also tells it which recording settings are on and when typing was last saved (the time, not the words). Window titles, which can include words you typed, are read like any other. The AI app's own policy applies. |
| Saving a backup to a synced folder, like iCloud Drive | That sync service | Your whole history, unencrypted |
| "Open Original" on a web link | That website | One check that the page still exists, with no cookies |

DayDream also sends anonymous [usage counts](#usage-counts) to PostHog about once an hour, unless you turn them off. They carry no history.

DayDream also checks DayDream's website (getdaydream.app) for updates, unless you turn that off, and downloads a new version from GitHub. Those requests ask for the list of versions and the update itself, and carry no history. The website and GitHub see your IP address, as any website does.

Summaries on this Mac send no history. Setup shows them switched on (on a Mac that can run them): when you press Continue, or turn them on in Settings › Summarizer, DayDream downloads the model (2.74 GB) from Hugging Face in the background, and it may also ask Apple about its signing certificate. It does neither by itself, except that a download you started finishes after a quit (and may then ask Apple), and neither request carries history.

## What we receive

Anonymous usage counts, unless you turn them off (below), and what you send us yourself. If you open an issue or a discussion on GitHub, what you write there is public. Report a Problem opens an email to support@getdaydream.app in your own mail app: you see everything in it, and we receive it only if you press Send. It holds app states (versions, permission, recording and summary settings, connected AI apps, error codes and counts) and never your history.

## Usage counts

DayDream sends these counts to PostHog (a product analytics service, `us.i.posthog.com`), about once an hour, so we can tell how many people use it and which parts work:

- once, when it's installed: the macOS version and the kind of chip;
- each setup step you finish: a permission allowed, the summaries you chose (on this Mac, OpenRouter or off), the AI app you connected (Claude, Claude Code, Cursor, ChatGPT, Windsurf or other), and setup done;
- once a day: whether recording is on, paused or off, whether its two permissions are allowed, about how long it recorded the day before (none, under an hour, 1–3, 3–6 or 6+ hours), which summaries are on, which AI apps are connected, whether Web pages in Chrome is on, and how many summaries were written or failed and why (like a bad OpenRouter key);
- each time an AI app uses a DayDream tool: which AI app, which tool, how many results and how long it took;
- each time you open DayDream's window (from the menu bar, the Dock or another way) and each search in it, with how many results.

Each count carries DayDream's version and a random ID made for your copy of DayDream. The ID isn't made from anything on your Mac, your name, your email or an account, so we can't tell who you are from it. DayDream asks PostHog not to keep your IP address or look up where you are. Usage counts never include your history, the words you type, window or page titles, sites or addresses, app names other than the AI apps above, searches, notes or file names.

They're on by default. Turn off **Share anonymous usage counts** in Settings › Advanced and sending stops at once; anything waiting is dropped. **See what's sent** there shows the last counts exactly as they go. **Copy ID** copies the random ID: email it to support@getdaydream.app and we'll delete its counts. Test and development builds never send.

## How long, and how to delete it

History stays on your Mac until you delete it. You can forget a moment in the app, exclude an app (which hides what it recorded), or remove everything: see [docs/uninstall.md](docs/uninstall.md). Copies in Time Machine or in backups you made are not changed; delete those yourself. Deleting or hiding history in DayDream can't recall what was already shared: what a connected AI app read, what cloud summaries sent, or a backup you saved. If a history limit was set with the `mac-mem` tool, older history is deleted after that many days, and Settings › Advanced says so.

## Security

The history file is not encrypted. Other users on your Mac can't open it without administrator rights, but any app or tool running as you can read it. Turn on FileVault, and don't run software you don't trust. [SECURITY.md](SECURITY.md) has the details and how to report a problem privately.

## Use it on your own Mac

Use DayDream only to record yourself, on your own Mac user account. Don't install it on anyone else's Mac or account. If someone else uses your account, stop recording (a pause ends on its own) or give them their own macOS user. If you use it at work, your employer's rules apply. DayDream isn't a monitoring tool: using it to watch other people can be illegal.

## Browser history (Google Chrome)

Setup, and the "What's new" pages after an update, show **Web pages in Chrome** switched on, with one line. One click turns it off, then or any time in Settings › Apps to remember, where the same switch turns it back on. Nothing is saved from Chrome until macOS lets DayDream control Google Chrome. Setup's Google Chrome row asks, from its **Allow** button (the same button is on that card in Settings › Apps to remember). If you say no, **Ask again** there or in the menu bar clears DayDream's own answer and macOS asks again.

- **Saved:** for the page in front in Google Chrome, the page title, the site (like `wikipedia.org`), the page's link without its search terms (so Open Original opens that page; the link stays on this Mac, and AI apps and cloud summaries never get it) and the time. Search engines save what you searched for, never the rest of the address. Common chat sites save the site only. Email sites save the folder or the open email's subject while Save email subjects is on (never codes, passwords, sign-ins or bank mail), and typing in webmail keeps the open email's subject. This list is not complete either: a site that isn't on it keeps its title, so add any site you want skipped to your own list. Page titles can include other people's words, like email subjects or chat names.
- **Typing:** saved only if typed text is on too. DayDream saves the words, the site, where the page history above saves it the page title (on webmail, the open email's subject), and, when the message box shows it, who a message went to (a chat's channel or person, an email's To name), never the rest of the address. Cloud summaries, if you turn them on, get the words, the site, the page title (on webmail, the email's subject), cleaned of any address and unread count, and who it went to. Typing is never saved on blocked sites, in fields for card numbers, one-time codes, PINs or passwords, or while an Incognito or Guest window is open. The words are encrypted and deleted after 7 days unless you choose another time. Typing on common email and chat sites, and on every page of social sites with chat, like Facebook, LinkedIn and X, is saved only while Messages and email is on (it is on unless you turn it off).
- **Never saved:** what's on the page, your clicks, the rest of the address (a search engine's page keeps only what was searched for), tabs that aren't in front, blocked sites, and anything from Chrome while an Incognito or Guest window is open.
- **Only Google Chrome.** DayDream checks that the Chrome in front is signed by Google before it reads anything. Safari, Arc, Edge, Brave, Firefox, Chrome Beta, Dev and Canary, and dozens of other browsers DayDream knows are not recorded. A browser DayDream doesn't know by name is skipped too if it tells macOS that it opens web links, as browsers normally do. One that doesn't is treated like any other app: its window titles, which are usually page titles, are saved. Exclude it in Settings › Apps to remember.
- **Private windows.** Before reading anything, DayDream asks Chrome whether each window is Incognito. Chrome reports Guest windows as Incognito too. If any window is, or if Chrome doesn't answer clearly, nothing is saved. Nothing is saved while more than one copy of Chrome is running, or while a password box has secure typing on.
- **Skipped sites.** Common banking, password, sign-in, payment, health (including sexual and reproductive health) and government sites are skipped by default. The list is not complete. Add your own sites in Settings › Apps to remember › Web pages in Chrome, or use "Don't record this site" on a Chrome moment.
- **Where pages go.** They're kept on this Mac in DayDream's history file, which is not encrypted. AI apps you connect can read them, and what they read is sent to that app's AI provider. If you turn on cloud summaries, the titles and sites of the pages they summarize are sent to OpenRouter. They're never sent to us.
- **Hide and delete.** "Don't record this site" stops saving that site and hides its saved pages. AI apps stay connected, and recording pauses for the save and starts again by itself if it was on. Adding a site in Settings does the same; removing one, or turning Web pages in Chrome on, also disconnects AI apps until you reconnect them. Exclude Google Chrome stops saving Chrome pages and hides all of them. Turning Web pages in Chrome off stops new pages; saved ones stay until you forget or hide them. Hidden pages stay in the file until you forget them, and copies in Time Machine or earlier backups are not changed.
- **Chrome's own history** is separate. Safari's own history has stronger macOS protection than DayDream's file: other apps need your permission to read it. DayDream's file doesn't have that protection.

## Changes to this policy

If DayDream starts collecting or sending anything new, we'll update this page before that version is released, and say so in the release notes. You can see every change to this page in its GitHub history.

## Contact

Questions about privacy: [support@getdaydream.app](mailto:support@getdaydream.app). Security problems: please use [private vulnerability reporting](https://github.com/getnorthlight/daydream/security/advisories/new).

## Browser history questions

### Does DayDream record Incognito windows?

No. While any Incognito window is open, DayDream saves nothing from Chrome at all, including from your normal windows. It starts again when the last Incognito window is closed.

### What about Guest windows?

The same as Incognito. Chrome reports Guest windows as Incognito, so while one is open nothing is saved from Chrome.

### Are my work and personal Chrome profiles both recorded?

Yes, while the switch is on. If you don't want a work profile recorded, add its sites to your list, or turn Web pages in Chrome off while you use it.

### Can AI apps see my pages?

AI apps you connect can read them, like the rest of your history, and what they read is sent to that app's AI provider. Other apps and tools running as you on this Mac could read the unencrypted file too. "Don't record this site" and Exclude Google Chrome hide pages from AI apps you connect.

### Are my pages sent to cloud summaries?

Only if you turn on cloud summaries (**Use an OpenRouter key instead**): then the titles and sites of the pages being summarized are sent to OpenRouter, which is asked to use only hosts that don't keep your data. Summaries on this Mac send nothing.

### How do I turn it off?

Turn off Web pages in Chrome in Settings › Apps to remember. To also hide what was saved, use "Exclude Google Chrome from Recording…" on a Chrome moment, or "Don't record this site" for one site. You can also turn off Google Chrome under DayDream in System Settings › Privacy & Security › Automation.
