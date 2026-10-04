# DayDream tools

Contents: status, recap, search, moment_details, open, recall, read, context, current-context, errors.

All tools are read-only. Every tool except `context` takes `response_format`: `concise` (the default, Markdown) or `detailed` (JSON, also sent as structuredContent).

## status
Checks whether DayDream is set up for this AI app. It takes no other arguments. The reply starts with a setup line: either "ready" or the one thing to fix. It also reports connection, recording, typing, Chrome pages, summaries, last activity, the local time and example questions. It never contains activity. On a new install with an empty history, the result is ready, not broken.

## recap
`when`: today, yesterday, past 2 days, past 3 days, this week, last week, a weekday, a date, or `2026-09-28 to 2026-09-30` (at most 7 days).
Returns one section per day: a headline, up to 5 time blocks (when, what, minutes, up to 3 lines of what was sent, asked, written or worked on), and a count of brief visits. It ends with "How to answer". It never returns typed words.

## search
Arguments:
- `query`: 1-3 words.
- `start`, `end`: ISO-8601 with an offset.
- `app`: an app's name or bundle id.
- `site`: a host.
- `after`: the cursor from the previous page.

It matches app names, window and document titles, web page titles and sites (if recorded), and DayDream's notes. Typed words match too, on the first page only, when the person allows AI apps to read them.
Returns up to 20 numbered hits, newest first: local time, description, state and id. Typed-word hits come with a short quoted excerpt. Matching notes come with an `open` value for `recall`.

## moment_details
Arguments:
- `id`: a search hit's id, or a moment id (`activity_...`).
- `moment`: a moment link, as an alternative to `id`.
- `day`: needed only for moment ids older than a week.
- `after`: the cursor for the next page.

Returns the moment's actions in time order: local time, app, window or conversation, site and state. Typed words are quoted (`> "..."`) only when the person allows it. Otherwise each typed action says where and about how much was typed, and the reply says why the words aren't there. Passwords, secrets, private windows, excluded apps, blocked sites and expired words never appear. Each page is about 24 KB; the `Next:` line gives `after` when there is more.

## open
`uri`: `macmem://days/today.json`, `macmem://days/yesterday.json` or `macmem://days/YYYY-MM-DD.json` (optional `?timezone=IANA`), or a link from an earlier result.
For a day, it returns every moment in time order with its time, name, apps, sites, note and moment id.

## recall
DayDream's notes at any zoom.
- `level` (month, week, day, block, moment) with `when` returns that note and its children.
- `open` (from an earlier reply) zooms in one level.
- `query` searches every level by word starts, so "email Sam" finds "Emailed Sam".

It never returns typed words.

## read
`id`: a search hit's id. Returns that one action in full: time, app, window, site, state. For typing, it gives only where and about how much; use `moment_details` for the words.

## context and current-context
`context` returns the last 30 seconds as short text. It shows activity only while DayDream is recording. `current-context` returns the same 30 seconds as records with ids, up to 10 per page; pass `after` to continue.

## Errors
- A tool that ran and failed returns an error result. The first line says why; a `Next:` line gives the arguments that work.
- "Access for this AI app is missing" means the person must reconnect in DayDream's Settings › Connections. Don't retry.
- "DayDream's history changed while reading" means: call again without `after`.
- An unknown tool name is a protocol error that lists the real tools.
