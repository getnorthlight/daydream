# Summaries

DayDream can write a short note about a moment (a group of related actions) or a whole day. This page explains when that happens, what the writer sees, how its answer is checked, and how the cloud and local options work. It describes the current code: the writer versions `deepseek-v4-flash-0731-zdr-prompt20-validator26` (cloud) and `qwen35-4b-q4-b9723-prompt21-validator32` (on this Mac), and `code-moment8-validator14` for notes written by code with no model.

The code lives in the `WriterBackend/` package: the view and the checks are in `ModelView.swift` and `CanonicalNotes.swift`. The app side is in `Sources/MacMemApp/WriterIntegration.swift` and `Sources/MacMemApp/WriterScheduling.swift`, and notes are stored by `Sources/MemoryCore/DerivedNotes.swift`.

## Optional

Summaries are optional, and you can turn them off at any time. Your history is complete without them, and every action stays visible whether or not a note exists.

There are two writers, and you pick one: **on this Mac** (the model runs on your Mac, see [On this Mac](#on-this-mac)) or **cloud summaries** with your own OpenRouter key.

Only one writer runs at a time, and neither falls back to the other. Turning summaries off stops the writer. Deleting the cloud key also turns cloud summaries off. Both kinds stay on across a relaunch: if they were on when DayDream quit or your Mac restarted, they turn back on by themselves when DayDream opens (summaries on this Mac using only checks already on your Mac). Cloud summaries also stay on through a change to your privacy settings, restarting under the new settings.

## When a note is written

Summaries on this Mac are on by default in setup, on a Mac that can run them. The local writer runs at low priority and pauses inference during actual typing bursts (`WriterIntegration.swift`, `WriterScheduling.swift`, `LevelPower.swift`):

- A **moment** closes 10 minutes after its last action (2 minutes once a later moment has started), or at once when your Mac locks, sleeps or sits idle for 5 minutes.
- **While a local moment is open**, the first provisional summary is due after 10 minutes, with another update every 10 minutes. It is written again when the moment closes, even if its actions have not changed. Closed local moments waiting 5 minutes take priority over ordinary batches. Availability, privacy, power, thermal and failure backoff checks can delay completion.
- **Actual typing** pauses local inference until 3 seconds after the last key event. Mouse movement and scrolling do not count as typing bursts. The model retains its generation while paused and resumes it afterward.
- **Ordinary batches** run at most every 20 minutes while you keep working, and sooner once idle, locked or asleep. One batch writes up to 12 notes. Due open-moment updates and final local summaries use their own deadlines rather than waiting for an ordinary batch.
- **On battery**, local background summaries may run at 20% charge or above, with Low Power Mode off and the Mac below serious thermal pressure. Otherwise the model waits; code can still write block and day notes from existing moment notes at most every 10 minutes.
- **When an AI app asks** about the last hour (the MCP tools), one batch writes that hour's moments, open ones too, at most every 5 minutes. On battery this request is limited to at most 3 notes at most every 15 minutes, with the same power safeguards.
- **Cloud summaries** keep the existing closed-moment batch behavior. The local live-update deadlines and inference pauses do not switch your selected writer or enable cloud summaries.
- **Past days** (up to 7 back, newest first) are caught up on power, 10 notes a batch. Blocks, days, weeks and months are written after the moments they cover.

You can also ask for a note on a single moment (**Summarize Now**).

Waiting work is listed in `WriterScheduling/pending-v1.json` in the data folder. The file holds only which moment, revision numbers and when notes were written: never action text, answers or keys.

- When the model or OpenRouter fails, the whole writer waits 1, 5, 15, then 60 minutes before it tries again (Try Again ends the wait). A key, credits or host problem waits for its button instead.
- A cloud request that fails with a busy or server error, a timeout, a dropped connection or an empty answer is tried again after 2 and 8 seconds. OpenRouter may bill a request that reached a host even when it failed, so one note can be billed up to 3 times.
- An answer that fails the checks gets one repair turn (a second call), then salvage (below).

## What the writer sees

**Terminals and AI coding tools.** A line typed in a terminal (Terminal, Ghostty, iTerm2 and others) whose window shows an AI coding tool (Claude Code, Codex, Gemini CLI, Aider: from the window title, such as Claude Code's "✳" title, or from a line that started the tool) is a prompt to that tool, so its line reads "Asked Claude Code to ..." or "Told Claude Code ...", one per distinct request, giving its gist. Other lines run with Return are shell commands, which code says by what they were for in one line ("Entered commands to build the Swift package and run the Swift tests in harborline"), never "Wrote code in Ghostty". Entering a command shows it was run, not its result.

**One summary, no filler.** Wherever a moment's lines are shown (its card, a card that joins several moments of one app, and recaps for AI apps), code's place-only lines ("Typed a draft in Ghostty.", "Used the send key in Ghostty.", "Wrote code in Ghostty.", "Pressed Return") appear only when no line says more, each line appears once (a line that only repeats the start of a fuller one is left out), and a card shows at most about 4 lines, the most informative. The saved note keeps every line and the actions each cites.

For local AI tools and terminals, independently filtered captured requests are grouped into a contiguous session so the summary can describe what you asked. The cloud view retains separate typed items. Every original action remains in What happened, before and after a summary arrives. Stand-in summaries show at most five newest distinct excerpts from permitted local source; secrets and one-time codes remain withheld.

The writer receives a bounded view for each moment or day, and may make another call for repair or a later update. It doesn't see the raw actions. Code first turns them into a short list called the ITEMS view (`ModelView`):

```text
NOTE: moment
ITEMS:
i1. Numbers: "Budget — household" open and in use
i2. Numbers: typed "move 200 from dining out to savings" in "Budget — household"
i3. Claude: typed text (not captured) in "Launch plan" over about 2 minutes
```

**Messages.** Texts you send in one Messages conversation are one item, the texts in order, so the note says it in one bullet: "Texted Sam that you and friends are going to ZUX tomorrow and asked if they want to meet there." A text that was saved in pieces (a pause or a switch mid-word) reads joined, as you typed it. The conversation is the name Messages shows in its window; with no name read, the bullet says "Texted someone ...", never "unknown", and a text with no name is never put with another conversation. A draft you leave in a conversation after sending is mentioned at most in that bullet, never as its own "Typed a draft" line. The person you texted is called by name or "they", never "he" or "she", and "you" in that bullet means you.

**Replies and comments.** A reply, quote or comment says what it answered, from the page DayDream read when you sent it (its author and the start of the post, never your words): "Replied to Ada's post about small tools beating big frameworks, saying it'll help with weekend projects." Viewing that post gets no line of its own. A reply you leave unsent is "Drafted a reply to Ada's post on X"; a Reddit comment is "Commented on r/swift".

Each item is one thing you had open, typed or were told. Clicks, shortcuts, Return presses and repeat visits are folded into the item they belong to. The view says only whether an item was "in use", never which keys or how often. Typing whose words the writer doesn't see (typing off, or words already deleted), in one app with nothing else in between, is one item with its window titles and about how long it took, never a count of drafts.

The view never shows:

- action IDs, app bundle IDs or timestamps. Items are numbered `i1`, `i2` and so on, and code maps them back to the real actions;
- idle time. The model never sees it and no bullet may cite it;
- text after anything that looks like an instruction to an AI ("ignore previous instructions", "note to the summarizer" and similar). The view shows "text addressed to AI tools" instead;
- health and money details. They become "a personal health note (details hidden)" or "a personal finance note (details hidden)";
- phone, card, account and reference numbers, and window titles saved as `[sensitive title omitted]`.

The whole view is text in one line per item, with no double quotes or angle brackets inside the quoted text, so a title can't close its quotes or form a special token.

**Size limits.** A moment or day with more than 40 items, or more than 16,000 bytes of view, is folded further: items of the same app are merged into one line, background items first. If a moment still doesn't fit, or it has more than 400 actions, it is written in segments of about 150 actions (cut where the conversation or window changes, never inside a typing run), each checked on its own, and the segment notes are merged into one card. A day that doesn't fit, or a moment over 2,000 actions, isn't summarized: its note stays pending and its actions stay as they are. Cloud notes have the same limits (there is no separate cloud cap), and each cloud request is at most 24,000 bytes.

**What cloud summaries see from browsers.** Chrome pages go to cloud notes as their page titles and sites, cleaned of web addresses, unread counts and the site's name suffix; the address itself never goes. Typing on websites goes the same way, and what you typed into a search box goes with the rest of your typing (a search term kept in an address never does). Other browsers are not recorded. With typed text on, cloud summaries do get the words you type. Only actions recorded after you turned cloud summaries on are sent. Corrections you write to a note go with the actions they cover, marked as your correction rather than as something recorded, so a cloud request includes them.

The privacy settings are checked again before a note is prepared, before the request, after the answer and before the note is saved. If an action was deleted or excluded, or your settings changed in the meantime, the result is thrown away.

## The answer, and how it is checked

The model answers with one JSON object:

```json
{"title":"Household budget","bullets":[{"ids":["i1","i2"],"text":"Worked in the household Budget sheet in Numbers, typing a note to move 200 from dining out to savings."}]}
```

A moment gets 1 to 3 bullets and a day 2 to 5; the writer is asked for 1 or 2 for a moment. Each bullet is one sentence of at most 240 characters. The title is at most 60 characters.

The checks (validator14) throw the answer away when a bullet:

- cites an item that isn't in the list, has no items, or repeats or nearly repeats another bullet;
- says something was sent, emailed, messaged, replied or delivered, unless an item shows the app confirmed it was sent;
- claims an outcome no item shows, such as finished, fixed, paid, saved, merged, decided or confirmed;
- says you read, reviewed or watched something that was only open, or worked in something that was only open;
- states typed text, a page or a title as fact, instead of "the draft says" or "the page says";
- relays what an app reported without "<app> reported" and "; not verified";
- states a time, a time of day or a duration the items don't state, or a number that isn't in the items it cites;
- uses a name that isn't in its items, or says "the user", "you" or "your" (a note is written with no subject: "Asked Claude about the PR"; only a line about the person's own note, plan or request says whose words they are: "You noted ...", "You plan to ...", "You asked ...", and a "Texted ..." line retells a text in your own voice: "Texted Mom that you'll call tonight");
- says a message went to "unknown", or calls the person it went to "he" or "she";
- repeats your typed words, or says them again with a few words changed or reordered;
- includes a phone, card, account or reference number, a money or health detail, a secret, an app ID, or text addressed to AI tools.

Each rejection comes with a fixed reason. The reason never quotes your history, only the model's own offending word.

**The labels come from code.** Each saved bullet lists the real actions of every item it cites, whole items only. Its label (observed, draft, sent, reported or interpretation) is worked out from those actions' recorded states, and the weakest wins. The model never chooses a label.

**Every item is covered.** Items the model left out that were only open are added by code. Typed text, sent messages, reports, notes, requests and plans must be in a bullet; an answer that leaves one out is thrown away.

**Salvage.** When an answer still fails, DayDream keeps every bullet that passes, and writes up to three plain bullets in code for what's left, such as "Drafted an email to Sam." or "Messaged #eng.": who it went to, or a subject or place code read from the window, never a topic taken from your typed words. It never writes more than that: if more would be needed, or code can name nothing concrete, the note stays pending.

**Code's own note.** When no answer holds even after repair and salvage, code writes the moment's note from its facts. A Messages conversation gets one line in code's own words, never your typed words (a note may not repeat them, and it outlives them): who it went to, at most two names your texts write with a capital, and whether a sent text asked something, like "Texted Jamie Lin about ZUX and asked a question." or "Texted someone in Messages.". A reply, quote or comment gets "Replied to Ada's post on X (“<the start of that post>”)." and an email you sent "Emailed Sam.". Prompts sent to an AI coding tool in a terminal get the tool and the session's own title, like "Asked Claude Code about “Tallybird app design review” (5 prompts).", never a bare "Asked Claude Code." and never "Drafted" for a prompt sent with Return.

**The last check.** Before a note is saved, the app checks it once more, with the real action IDs: known writer version, whole items, derived labels, every bullet's wording, full coverage and the title. Only notes from this writer version pass (`qwen35-4b-q4-b9723-prompt21-validator32` on this Mac, `deepseek-v4-flash-0731-zdr-prompt20-validator26` in the cloud, `code-moment8-validator14` by code).

**Older notes.** A moment note from an older writer version on the last 4 days is written again by the current one. The older note stays shown until the new one is saved. Older days keep their notes as written.

Saved notes are marked `generated_unverified`. The checks catch common overclaims; they don't prove a note is true. When a note is rejected or can't be written, the actions stay as they are.

## Cloud summaries

Cloud summaries send the ITEMS view to [OpenRouter](https://openrouter.ai), which routes it to the model `deepseek/deepseek-v4-flash-0731`. A reply from any model whose name starts with `deepseek/deepseek-v4-flash` is accepted.

- **Calls per note.** One call, plus one repair turn when the answer fails the checks, plus the retries above. Blocks, days, weeks and months are written by the cloud model too when everything they would send is from after you turned cloud summaries on; code writes the rest.
- **Turning them on.** The switch is **Use an OpenRouter key instead**, with one line under it: "From now on, window titles, page titles and what you type go to OpenRouter. Zero-retention hosts requested." Your key is tried once with a tiny fixed request (nothing from your history), and only a key that works is saved. Only actions recorded after that moment are sent.
- **Turning them off.** The switch, or deleting the key. Quitting DayDream and changing your privacy settings don't: the switch stays on across a quit. If a later version changes what is sent, the switch turns off until you turn it on again.
- **The key** is kept in your login Keychain under the service `DayDream.Writer.OpenRouter`. It is never written to settings files or logs.
- **Each request** goes only to `https://openrouter.ai/api/v1/chat/completions`, with no cookies, cache or redirects, a 30-second timeout and a 128 KB limit on the reply. It asks OpenRouter for [zero-retention](https://openrouter.ai/docs/guides/features/zdr) hosts only (`zdr: true`, `data_collection: deny`), forbids fallback to other hosts (`allow_fallbacks: false`), and uses no tools. The reply must name the exact model requested.

Zero retention is a routing request to OpenRouter, not a promise. It doesn't control OpenRouter's own request metadata or any logging you turned on in your OpenRouter account; see OpenRouter's [data collection](https://openrouter.ai/docs/guides/privacy/data-collection) page. After a cloud note is saved, the app says "Generated note saved. Written through OpenRouter by a model host asked not to keep it." It never claims that no data was collected.

## On this Mac

Choose **On this Mac** in setup or in Settings › Summarizer. Notes are then written on your Mac, with no cloud.

- **Inside the app.** The runtime that runs the model ships **inside the app**: seven [llama.cpp](https://github.com/ggml-org/llama.cpp) libraries (release b9723, built for macOS 15 on Apple silicon), about 5.2 MB, signed with DayDream's Developer ID. They make the download about 5 MB bigger.
- **Downloaded only when you ask.** The model, [Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B) (Q4_K_M, 2.74 GB: 2,740,937,888 bytes), is downloaded only after you turn on **Summaries on this Mac** (in setup, **Continue** with it on, as it is by default). It comes from Hugging Face (`huggingface.co`, which may pass the download to its `us.aws.cdn.hf.co` servers). The download resumes if it stops, and the file is checked for its exact size and SHA-256 before it's used. It's saved in `~/Library/Application Support/DayDream/Models/`. If the model is already there, nothing is downloaded. If you quit during the download, it finishes after DayDream opens again.
- **What your Mac needs.** Apple silicon, macOS 15 or later, at least 8 GB of memory and about 2.8 GB of free space for the model. In one test on an Apple M4 Pro, the model took about 28 seconds to load and a note took about 6 seconds (up to about 17).
- **On battery.** Notes are written on battery too, in the same batches as when your Mac is plugged in. They wait while Low Power Mode is on, the battery is under 20%, or your Mac is hot, and are written once that ends.
- **The signature check.** Before DayDream loads the libraries, it checks their signatures on your Mac, using the certificate status macOS has already saved. If that saved status has run out, DayDream asks Apple about its signing certificate, and only when you turn On this Mac on (or a download you started finishes after a quit). Nothing from your history is sent in that request.
- **After a restart.** If On this Mac was on when DayDream quit or your Mac restarted, it turns back on by itself when DayDream opens, using only that check on your Mac. The one time it goes online without a click is to finish a model download you started before quitting (and the Apple check that follows it). If the saved certificate status has run out, it stays off and Settings › Summarizer says "On this Mac is off until DayDream checks its signature with Apple." Press **Try Again**.
- **Typed words.** If typed text is on, summaries on this Mac can use the words DayDream saves from your typing (up to 1,600 characters of each draft), so a note can say what you asked or wrote. The words are opened in memory on your Mac while the note is written; only the note is saved. A note may copy at most five words in a row from a draft, fewer for a short one. AI apps you connect read the note; the words only while **Let AI apps read what you typed** is on (their `moment_details` tool). Cloud summaries, if you chose them instead, get the words too (see Cloud summaries).
- **What goes online.** Writing a note on this Mac sends nothing. The only requests are the model download (including one you started that resumes after a quit) and, when needed, the certificate check above.

How it works, for developers:

- It runs [Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B) (Q4_K_M) with [llama.cpp](https://github.com/ggml-org/llama.cpp) release b9723, inside the DayDream process through a small C++ bridge (`WriterBackend/Sources/CLlamaBridge`). There is no server, port, background service or tool use.
- The answer starts with `{"title":"` already filled in, so the model writes JSON from its first word, and is limited to 640 tokens.
- If the first answer fails the checks, the model gets **one repair turn**: the view again, its own previous answer and the fixed reason. If that also fails, DayDream salvages the repair answer, or else the first one, as described above.
- Limits: an 8,192-token context, four CPU threads, one note at a time and 90 seconds per answer. Cancelling stops at the next step.
- Signed builds never download runtime libraries. They load only the libraries inside the app (`Contents/Frameworks/WriterRuntime/<ID>/`), and only when all of these hold:
  - the manifest's SHA-256 matches the pin compiled into `SignedRuntimePolicy.swift`;
  - each library's bytes match the manifest;
  - each library is signed by team `L76C3ZC66J` with the same leaf certificate as the app, with the hardened runtime and no entitlements;
  - each library loads its siblings only through `@loader_path`;
  - the certificate status passes the offline revocation check.
- Development builds download the pinned model and an upstream runtime (for macOS 26) over HTTPS, and check each file's size and SHA-256 before using it.

Pins, licences and how to reproduce them are in [WriterBackend/PROVENANCE.md](../WriterBackend/PROVENANCE.md). How a signed build admits the runtime inside it is in `WriterBackend/Sources/WriterBackend/WriterRuntimeAdmission.swift` and `SignedRuntimePolicy.swift`. How the libraries are signed once and placed in each release is in [RELEASE.md](../RELEASE.md#writer-runtime).

## Development checks

Run from the repository root. None of these download a model or contact a cloud provider:

```sh
swift run --package-path WriterBackend WriterChecks
swift run --package-path WriterBackend PromptChecks          # archived PromptEval/final parity; current-version failures remain unresolved
swift run --package-path WriterBackend InstallationChecks    # synthetic checks only
swift run --package-path WriterBackend CloudActivationChecks
swift run --package-path WriterBackend AdapterChecks
```

`bash WriterBackend/run-core-checks.sh <path to a debug build>` links the writer against the real `MemoryCore` store and runs the note checks.

`WRITER_BUILD=<WriterBackend debug build> sh WriterBackend/SignedRuntimeChecks/run.sh` runs the signed-runtime policy checks, and `sh WriterBackend/AppIntegrationChecks/run.sh <app debug build>` runs the app's writer with fake keys, HTTP and admission. That includes a relaunch that never goes online.

`ModelTrial` and `CandidateRuntimeChecks` run the real model on sample actions. They take the paths to an already downloaded runtime and model file and never download anything.
