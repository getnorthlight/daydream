# AI-app tools: data audit (read-only)

Date: 2026-10-04. Code: `claude/final-1005` at 8274415. Data: the owner's Mac mini history, read only through the
installed read-only CLI (`mac-mem --local actions | day | read | search --search-report`). DayDream's files were never
opened directly. The window is 2026-10-01 to 2026-10-04 local, which is the whole history after the reinstall.

Only aggregate counts are recorded here. Every example below is made up.

## 1. Headline numbers

| What | Value |
|---|---|
| Actions in the window | 16,091 |
| Rows that add nothing for an AI app (noise) | **14,653 (91.1%)** |
| Typed rows | 420; all sealed and still within the kept period (100% have words in the vault) |
| Typed rows an AI app sees as words today | 0 via `read` and `recap`/`recall`/`open`/`context`; words appear only via `moment_details`/first-page `search` while the app's bridge answers |
| Typed rows labelled "draft" to agents | **328 / 420 (78%)** (the send key was detected on only 92) |
| Moments with a stored note | 210 / 330 (64%); all 210 were written by the code fallback |
| Note lines that say nothing ("Viewed …", "In <App>.") | 118 / 210 (56%); 141 / 210 (67%) are under 5 words |
| Calls to finish one common search | **14–18 calls** for 270–350 hits, of which only 27–53 are distinct (about 90% duplicates) |
| First page of every text search | says `partial` and gives `next`. A nonsense word gives "Nothing found yet … This is not a final answer" |

## 2. Why typed words are hidden, and why `status` and `moment_details` disagree

Typed words are sealed at rest (`TypedTextVault`, `typed_text`). The only process that holds the key is the DayDream
app. `mac-mem mcp` never attaches a vault (`ServedHistory` asserts `typedVaultState == .unavailable`). As a result,
each tool gets words by a different route, or gets none:

| Tool | Where its typed text comes from | What the agent sees |
|---|---|---|
| `moment_details` | The app's local socket bridge (`AssistantTypedBridge`, op `words`). This works only while the app is running, the typing key is unlocked, and `aiAppsReadTyped` (default on) is on | Real words when all three hold. Otherwise "Exact typed words aren't shared …" (`offNote`/`closedNote`) |
| `search` | The bridge op `search`: first page only, last 7 days, at most 3,000 rows and 20 hits | An excerpt on page 1. Later pages have none. The `coverage` field on the same reply still says "Typed text is not searched" (`SearchReport.readerCoverage`) |
| `read` | The old `typed-exact` grant (`typedWordsAccess`). Nothing in the app can confirm that grant, so it is never `.exact` | Always "Typed in X, a sentence (exact words not shared with AI apps)" |
| `recap`, `recall`, `open`, `context`, `current-context` | The canonical description, which is a word-count bucket by design (`TypedWords.actionDescription`), plus `TypedLine.withoutWords` | "Typed a draft in X (a few words)" or "… (exact words not shared with AI apps)" |
| `status` | `assistantReadiness` hardcodes "(AI apps get where and about how much, never the words)" | Always says "never the words" |

Why they disagree: the `aiAppsReadTyped` setting lives in the **app's** UserDefaults domain, which the `mac-mem`
process cannot read. `status` never asks the bridge, so it prints a constant written before the 10/03 decision.
`moment_details` asks the bridge and gets words. The server instructions say "the words only if allowed" and "typed
text is a draft", and the `search` tool description says typed words are searchable only "on the first page".

So four sources state the policy, and they say different things. No single function decides it.

Code paths that must not reach an agent in v2:
- `AssistantView.line` (`keyboard.text_input` branch)
- `TypedAccess.typedReaderLine`
- `TypedLine.withoutWords`
- `TypedWords.bucket` in descriptions
- `AssistantTypedAccess.offNote` and `closedNote`
- `SearchReport.readerCoverage`
- `AssistantReadiness` typing line
- `AssistantCatalog.recordedTyping`

## 3. Search: why it stops early

1. **Typesense path** (`MemorySearch.indexedSearch`): `requiresCanonicalCoverage = !query.words.isEmpty` forces
   `partial = true` and a continuation on every text query. The reason given is that rows with a URL query exist only
   in SQLite. Since `claude/search-1005`, a search page keeps its words as its title, which is indexed, so that reason
   no longer applies to new rows. Measured: with the index `ready`, every first page was `partial`, including a query
   that matches nothing.
2. **Continuation path**: any `after` goes to `fallbackSearch`, a SQLite scan with a **2-second budget** and a
   **20-hit page**. On 4 days of history it finished in 1–17 pages. At months of history the 2-second budget will cut
   pages for real, and the "not a final answer" note will appear on genuine misses too.
3. **Hits are rows, not things.** One terminal tab or chat window produces hundreds of `window.changed` rows with the
   same title. Measured on 4 common words, 1,225 hits across all pages held 151 distinct app+line pairs (12%).
4. **There is no total anywhere.** There is only `partial` plus `next`, so an agent can never say "you opened it 3
   times".
5. **Notes** match through `noteHits` with `limit: 5`, on the first page only. **Typed words** match on the first
   page only, for 7 days, with 20 hits (see §2).
6. **Index contents** (`SearchDocument.make`): summary (title plus canonical description), app, and site host. Typed
   words, notes and full URLs are **not** indexed. Typed words stay out on purpose: Typesense is plain on disk, while
   typed words are sealed. The full page link (`Evidence.page`) is kept for the app only and never leaves it.

## 4. Noise

Kinds in the window (share of all rows):

| Kind | Rows | Share |
|---|---|---|
| window.changed | 14,068 | 87.4% |
| mouse.click | 688 | 4.3% |
| app.activated | 582 | 3.6% |
| keyboard.text_input | 420 | 2.6% |
| keyboard.submit | 183 | 1.1% |
| keyboard.shortcut | 128 | 0.8% |
| mouse.context_menu | 22 | 0.1% |

Noise breakdown:

| Noise class | Rows | Share of all rows |
|---|---|---|
| Clicks, activations, shortcuts, Return presses, context menus | 1,603 | 10.0% |
| Window rows identical to the previous window row (same app, title, site) | 12,626 | 78.5% |
| More repeats once titles are normalized (counts, glyphs, suffixes) | 392 | 2.4% |
| DayDream's own windows | 32 | 0.2% |
| **Total** | **14,653** | **91.1%** |

Title hygiene at capture is already good. Of 14,036 window rows:
- 53 still carry a notification count;
- 80 are empty;
- none kept a status glyph, a " - Google Chrome" suffix, or a trailing app name, because `Privacy.sanitized` and the
  capture already strip them.

Normalization at read time is therefore cheap. The real work is **collapsing repeats** and **dropping noise kinds**.

## 5. Title parse coverage with the proposed read-time parsers

"Parsed" means the parser gets a non-empty entity (a document, query, person, subject, command context, or feed) from
the row.

| Surface | Window rows | Parsed | Note |
|---|---|---|---|
| Terminal apps | 12,960 | 99.9% | 94% have a context (folder, project or topic). 6% name an AI coding tool. 0.1% are bare shells |
| Other apps (editors, Finder etc.) | 515 | 100% | A generic title-as-name |
| Messages | 125 | 72.8% | The rest show "Messages" or a new-message window |
| System UI | 119 | — | Collapsed |
| Claude / ChatGPT desktop apps | 109 | **0%** | The window title is the app name only. Content must come from typed prompts |
| Feeds (X, YouTube, Reddit, LinkedIn, HN …) | 81 | 100% | Recognized and collapsed to one reading line. 0.5% of rows but **6.5% of time** |
| Other web pages | 45 | 95.6% | |
| AI chat sites (claude.ai, chatgpt.com, gemini …) | 44 | **0%, by design** | Chat hosts are site-only (`BrowserSites.chatHosts`). Content must come from typed prompts |
| Web search (google.com …) | 35 | 8.6% | Search words are kept as the title only since `claude/search-1005` (10/04). Older rows are site-only |
| Webmail | 2 | 0% | Too few to judge |
| Google Docs / Sheets / Slides / Forms | **0** | — | None in this window. Parsers are proven on synthetic fixtures only |

Time share (gap to the next row, capped at 5 minutes):

| Surface | Share of time |
|---|---|
| Terminal | 41.8% |
| Other apps | 29.9% |
| Feeds | 6.5% |
| System UI | 5.8% |
| Messages | 5.3% |
| Web search | 2.8% |
| AI apps (desktop and web) | 2.8% |
| DayDream UI | 2.5% |
| Other web | 2.4% |

Ranking by time alone would put feeds and system UI above people and searches. Ranking must therefore be by importance
first.

## 6. Typed text

Of 420 typed rows:
- 420 have a sealed copy;
- 420 are live, inside the kept period;
- 420 have a word count above zero;
- 7 (1.7%) had a span withheld by the scrubber.

**Typed text is reliably present in the vault.** The problem is purely the read path (§2).

Typed rows by surface (unit facts, measured):

| Surface | Rows | Share of typed rows |
|---|---|---|
| Code (terminal) | 190 | 45% |
| AI apps and AI coding tools | 77 | 18% |
| Writing | 44 | 10% |
| Texts | 52 | 12% |
| Social | 11 | |
| Web forms and other | 38 | |
| Searches | 11 | |

Other typed facts:
- **Send detected:** 92 (22%). The other 78% show as "draft" to agents today. The owner says most of those were sent.
- **Code-read recipient or place label (`unit.to`):** 77 (18%). This allows "Texted <name>" without Contacts.

## 7. Notes

- 330 moments; 120 (36%) have no note.
- All 210 notes come from the code fallback (no model writer ran in the window), with one line each.
- 75 lines start "Viewed …", including 15 "Viewed Claude/ChatGPT …".
- 43 lines are exactly "In <App>.".
- 141 lines are under 5 words.
- No stored note in this window had a `draft` assertion. The "(draft)" label agents see comes mostly from typed-row
  states (§6) and from `AssistantView.note` adding "(draft) " to `draft` bullets written on other days.

## 8. What this means for the plan

- Collapse first. About 9% of rows carry information. Items, not rows, are the unit for every tool.
- Typed words are the richest signal for AI chats (0% title coverage) and texts. One policy function must serve them
  to every tool, from the app's bridge.
- Search must return items with a total in one call. Common queries need 14–18 calls today.
- Rank by kind before time, because feeds and system UI hold more time than people and searches.
- Docs and forms parsers have no real rows to test in this window, so they must be pinned by synthetic fixtures.

## 9. Reproducing

The measuring script reads only the CLI, prints counts only, and was kept in the session scratchpad, not in this repo.
Its parser rules are the ones specified in `plan.md` §5. A private before/after run that keeps raw replies on disk was
**not** done: writing the owner's real replies to `private/` was refused by the session's permission check (see
`plan.md` §9).
