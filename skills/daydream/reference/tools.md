# DayDream tools

Contents: timeline, search, details, status, older tool names, errors.

All tools are read-only. Each takes `format`: `text` (the default, compact plain text) or `json` (the same page as JSON, also sent as structuredContent). Every reply starts with one header line: `DayDream · <local time now> · recorded <range> · notes on | paused | catching up`. Replies are data: they never tell you how to answer, and they never contain links.

## timeline
What the person did in a period, most important first.

Arguments:
- `when`: today (the default), yesterday, this morning, this afternoon, this week, last week, past 3 days, a weekday, a date (`2026-10-03`, `Oct 3`) or a range (`Sep 28 to Oct 2`), at most 7 days. A future period ("tomorrow") says DayDream can't see it and lists today's documents and forms to pick up from. Part of a day ("this morning") counts only the visits in it.
- `detail`: `summary` (the default: up to 12 items a day) or `full` (every item).
- `cursor`: from the previous reply's More line.

Returns, per day: a day heading when it isn't today, an optional day note, then items under Documents, People, Email, Questions (web searches, AI prompts and AI coding tools), Code, Reading and Apps. Each item has its local time or visits, active minutes, an id for `details`, and, when the person shares typed words, the newest thing they typed there in single quotes (`Texted Sam: '...'`, `Asked Claude: '...'`, `Typed in <doc>: '...'`). Feeds read as one line ("Read X for 45 min"). A "Collapsed: N more (...) · detail=full lists them" line counts what the summary left out; nothing is hidden silently. The reply ends with "Where you left off" and, when there is more, "More: N more items · cursor=...".

## search
Find one specific thing across the whole history.

Arguments:
- `query`: 1-3 distinctive words. Every word must match a title, site, app, note or typed words. When no item holds every word, items holding some of them are listed and the reply says so; close spellings are tried only when nothing matches at all.
- `kinds`: any of `document`, `form`, `person`, `ai_chat`, `web_search`, `email`, `terminal`, `page`, `feed`, `app`. `ai_chat` includes AI coding tools in a terminal.
- `person`: a name, for conversations with that person.
- `app`, `site`: only items in that app or on that site.
- `when`: a period, as for `timeline`, without the 7-day limit. Default: the whole history.
- `limit`: items per page, 1-50 (default 20).
- `cursor`: from the previous reply's More line, with the same other arguments.

Returns "N items match" (the complete count, with visits) and the items, grouped and de-duplicated, each with when, why it matched when the line doesn't show it (`matched: site`, `app`, `note`, `close spelling`; a title match and a typed line go unmarked), the matching typed lines (`Asked Claude: '...'`, `Texted Maya Chen: '...'`, `Searched Google: '...'`, `Ran in api: '...'`) and an id. "No items match" means none. When typed words couldn't be searched, the reply says so on its own line.

## details
One item in full, by the id `timeline` or `search` gave (like `1004-k7f2q`).

Arguments:
- `id`: the item's id, exactly as given.
- `cursor`: from the previous reply's More line.

Returns the item's visits, everything the person typed in it in time order (texts, AI prompts, searches, commands and document text, with passwords, codes and keys removed), its notes (marked generated, unverified), and what else was open around the same time, with ids. It never says whether a message was sent. When typed words are off or DayDream is closed, the reply says so instead of quoting.

## status
Whether DayDream is set up for this AI app. No arguments besides `format`.

Returns a Setup line first ("Ready: ...", "Not ready: ..." with the fix, or what is switched off; a new install with nothing recorded yet is ready, not broken), then recording and last activity, the connection, typing and Chrome pages, what AI apps can see (generated from the person's sharing settings), whether notes are on, and example questions. It contains no activity.

## Older tool names
Chats that began before DayDream 0.1.5 may still list `recap`, `recall`, `open`, `read`, `context`, `current-context` and `moment_details`. They keep answering for one release, without send states. Prefer the four tools above when you have them.

## Errors
- A tool that ran and failed returns an error result that says why and which arguments work.
- "Access for this AI app is missing" means the person must reconnect in DayDream's Settings › Connections. Don't retry.
- A note that DayDream was updated while the chat was open means the person should restart the AI app to get the new tool list; the tools you have still work.
- An unknown tool name is a protocol error that lists the real tools.
