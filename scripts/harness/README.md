# Recording harness

The harness replays a made-up day at the Mac through DayDream's real recording code, into a scratch store, with no
real input, no permissions and no real Chrome. It then checks what was saved. It is headless and runs in seconds. Its
flows are built from the bugs the owner actually hit (the `[bug-N]` labels), so a regression of one of those bugs
turns a step red.

| Piece | File | Step (lane `flows`, tier `change`) |
|---|---|---|
| Timeline schema v1 | `Timeline.swift` | all |
| 0.2.0 oracles (samples, session events) and the adapter protocol | `Oracles.swift` | `flow-oracle` (`scripts/flow-oracle-checks.swift`) |
| Session driver: real capture objects on a virtual clock | `CaptureDriver.swift` | `flow-replay` (`scripts/flow-replay-checks.swift`) |
| APP flows: the real view model and app delegate | `scripts/flow-app-checks.swift` | `flow-app` |
| Source scan | `source-scan.py` | `flow-source-scan` |
| Tests/ status (no XCTest with the Command Line Tools) | `tests-status.py` | `tests-status` |
| Flows | `scripts/fixtures/flows/*.json` (13) | `flow-oracle`, `flow-replay`, `flow-app` |
| Mutations (bugs put back) | `scripts/mutations.d/recording-harness.tsv` | `runner-1001/mutate.sh` |

The steps are in `runner-1001/steps.d/recording-harness.sh`. Their rows are in
`scripts/checks-manifest.d/recording-harness.tsv`, and the pins in `scripts/checks-known-failures.d/recording-harness.tsv`.

## Run it

```
# the lane, through the runner (needs the owner build; TYPESENSE_BINARY as in runner-1001/README.md)
LANES=flows TYPESENSE_BINARY=... runner-1001/run-headless.sh flows
# or only these steps
ONLY='^(build|owner-build|(compile-)?(flow-.*|tests-status))$' runner-1001/run-headless.sh flows
```

`flow-replay` takes `<fixtures dir> <scratch dir> [name filter]`. It prints `HASH <flow> <sha256>` for each flow.
Setting `DD_FLOW_VERBOSE=1` also prints each flow's typed rows and page rows.

## Timeline schema v1 (`"schema": "daydream-timeline/1"`)

A timeline is a JSON object:

- `synthetic`: must be true.
- `name`, `about` (what real flow it replays), `start` (ISO 8601 with offset), `timeZone` (IANA).
- `install`: optional, `{kind: fresh|upgrade, from, messagesAndEmail, typing}`.
- `events`: the timeline itself.
- `expect`: optional.

Each event is `{at, op, ...}`, where `at` is seconds after `start`. Events are in order: one may not start before the
one before it ends. The first event is a `launch`.

| op | fields | what it is |
|---|---|---|
| `launch` | `how`: opened, login, no-open-event, self-relaunch, update-relaunch; `version` | DayDream starts |
| `quit` | | DayDream quits (marks a self or update relaunch when the next launch is one) |
| `record` | `on` | the person turns recording on or off |
| `front` | `app`, `bundle` | the app in front changes |
| `window` | `window`, `title` | a window switch |
| `tab` | `tab`, `url`, `title` | a Chrome tab or page change |
| `focus` | `field`, `place` | the focused field (a Messages conversation in `place`) |
| `type` | `text`, `cps` (default 8) | one key per character; it takes (n−1)/cps seconds |
| `backspace` | `count` | that many backspaces |
| `key` | `key`: return or tab | never a send |
| `input` | `kind`: click or move | |
| `mic` | `on` | the microphone in use (0.2.0 only) |
| `sleep` / `wake`, `lock` / `unlock` | | the Mac sleeps or locks |
| `pause` / `resume` | `seconds` (a timed pause) | the person pauses |
| `writer` | | the summaries pass runs on its own (its one-minute retry) |
| `hold` | `seconds` (0, 30] | the main thread is held (App Nap, a busy disk): no timer and no heartbeat |

`expect` holds:

- `typed`: `[{bundle, words}]` in order.
- `pages`: Chrome page titles.
- `never`: words never saved.
- `opened`: app_opened `how` values.
- `updated`: `[[from, to]]`.
- `recordingAtEnd`.

The validator refuses anything the drivers can't replay faithfully, before a store is made.

## The session driver (`CaptureDriver.swift`)

The driver is compiled from the runner's capture recipe: `$CAPTURE`, the core-source capture list with the headless
Coordinator copy, plus `WakeResume.swift`, `LaunchLocation.swift` and `TypedTextExpiryTimer.swift`, against the owner
objects. It drives the real objects:

- `EventCapture`: typing through the native typing route, app, window and field switches, and the Chrome page recorder over a fake transport
- `Coordinator`
- `CoreCaptureBinding`
- the sealed `MemoryStore`, with its typed text vault
- `SummaryWorker`
- `WakeResumeMachine`
- `UsageLaunch` / `UsageCounts`

Clocks:

- **Virtual clock.** `mono` runs everything the app schedules itself: the typing timers, the wake settle, timed pauses
  and the recorder's heartbeat. The heartbeat fires every 0.5 s while Chrome is in front or within 10 s of activity,
  otherwise every 15 s.
- **Real time.** The store keeps real time: the heartbeat goes stale after 5 s real, and BrowserSafety's freshness is
  −0.1…1 s. Row times are therefore not part of the hash.
- **Page clock.** Chrome page reads use a page clock anchored at the first read of each new tab and URL. This keeps
  them inside BrowserSafety's 1 s window. The cost is that a page's flicker window is compressed.
- **`hold`** sleeps for real, because the 5 s stale limit is real time. busy-mac-then-lock holds for 5.5 s, so each
  replay of it takes about 11 s.

The summaries pass:

- After each event, key or timer that committed something, the pass runs the same way the app's
  `scheduleLegacySummaries` does.
- `writer` runs it on its own.
- **Carry replay.** The driver then re-saves the replay's records into a fresh store, with the paste fact the RC's
  binding leaves out (`pasted=false`, see the RC findings below). The summaries pass runs at the same points. This
  checks bug 8's own mechanism (the pass must keep the carry) apart from finding 1.

Determinism: every replay goes into a fresh folder. The rows are normalized before hashing:

- volatile times dropped
- run ids become `run-N`
- random UUIDs become `uuid-N`
- keys sorted

The SHA-256 of the result is `HASH`. Each flow is replayed twice, and the two hashes must match.

## What it never touches

`flow-source-scan` proves the following from the source, and its own self-test shows the scan would flag each API it
looks for:

- The harness's files name no event tap, IOHID, Accessibility or Input Monitoring permission API, Keychain API, Apple
  event or script, tccutil, network, the installed app, or a named sqlite file.
- `CaptureDriver.installSeams()` turns `EventCapture.reenableTap`, `remakeTap` and `registerAX` into a `fatalError`.
  Even a path the replay never meant to take cannot make a tap or an observer.
- The driver never calls `EventCapture.start()`, `installEventTap` or `startInput`.
- Typing keys are `InMemoryTypedKeyStore`, and defaults are in memory.
- `flow-app` answers `permissionRead` and `permissionsGranted` itself. Its `startInput` starts nothing. It is a check
  build, so its typing keyring is in memory and its login item is inert. It refuses to run outside a synthetic HOME.
- In the real sources, `CGEvent.tapCreate` is only in `EventCapture.installEventTap`. That is reached only from
  `start()` and the `remakeTap` seam. `AXObserverCreate` is only in the `registerAX` seam, and the Keychain typing
  keyring is only outside check builds.

The flows send nothing. The usage events stay in an in-memory queue, and launch events are `NSAppleEventDescriptor`
values built in the check, never sent.

## Oracles for 0.2.0 (`Oracles.swift`)

0.1.8 writes no per-minute samples or session-event rows. The oracles say what 0.2.0 must write for any timeline:

- **`expectedSamples`**: one row per whole minute (absolute time, so the rows are right across DST) while DayDream
  runs, records, and nothing suspends it. Each row holds the app in front, the whole seconds since the last input (a
  key, click, or app/window/tab/field switch) and whether the mic is in use.
- **`expectedSessionEvents`**: sleep, lock and pause intervals. At most one is open at a time (sleep hides a lock, a
  lock hides a pause), each is closed by its own end, by quit, or by recording turned off, and none overlap.

`flow-oracle` has 39 cases on the RC. These include the oracles' self-tests (DST fall-back and spring-forward,
overlaps, a timed pause, quit closing an interval, the comparison's slack) and every flow validated.

**Adapter.** 0.2.0 implements one protocol over its tables:

```swift
protocol RecordingRowsAdapter {
    var writesRows: Bool { get }
    func sampleRows(timelineStart: Date) throws -> [SampleRow]
    func sessionEventRows(timelineStart: Date) throws -> [SessionEventRow]
}
```

`RecordingRowsComparison.samples` and `.sessionEvents` compare the read-back rows with the oracles, allowing a timer
up to `slack` (2 s) late. 0.1.8 uses `NoRecordingRowsYet`, so the comparison is skipped and says why. To wire 0.2.0:

1. Implement the adapter over the store.
2. Return it from the driver's `read()`.
3. Add the two comparisons to `flow-replay`.

## The flows and the owner's bugs

| Flow | Bug label(s) | What it replays |
|---|---|---|
| draft-extended-textedit, draft-extended-notes | [bug-8] | a draft typed, a long pause with a summaries pass, then continued ending in "sig :(" |
| google-searches-chrome | [bug-7] | four Google searches: four page rows, each titled with its own words, never google.com ×4 |
| busy-mac-then-lock | [bug-1] | a held main thread (stale heartbeat) refuses a save, then a lock and an unlock: recording never stops for good |
| login-launch-after-restart, update-relaunch, quit-and-reopen | [bug-9] | app_opened counts only launches the person asked for; app_updated sends real from/to versions |
| upgrade-messages-off, fresh-install-messages | [bug-13] | Messages typing on by default on a fresh install, and an upgrade keeps an explicit off |
| app-switches-and-break, pause-and-resume, sleep-and-wake, lock-and-unlock | [flows] | everyday switches, a 6-minute break, a pause, sleep, lock |

`flow-app` runs bug 1 and bug 9 on the real app objects:

- **Bug 1, three ways:** the lock heard late after a stale save, the lock heard on time, and the lock never heard
  (the 2 s lock watch must catch it).
- **Bug 9:** the three launch flows through `DaydreamAppDelegate.launchKind`, read in `applicationDidFinishLaunching`
  (the launch event is not current yet in `applicationWillFinishLaunching`).

**Mutations.** `scripts/mutations.d/recording-harness.tsv` has eleven rows. The first seven put one bug back as its exact
pre-fix code; the last four are realistic regressions of the same bugs that no commit made (added by the adversarial
review, 10/08). Each was shown CAUGHT (the step goes red, the verdict FAIL) on this branch:

| Row | Step | Caught by |
|---|---|---|
| bug1-capture-failed-pauses (pre-d197f8c) | flow-replay | [bug-1] next words |
| bug1-no-lock-watch | flow-app | [bug-1] lock never heard |
| bug7-search-site-only (pre-7bae3d7) | flow-replay | [bug-7] |
| bug8-clause-delete-every-pass (pre-1398cbb) | flow-replay | [bug-8] carry replay |
| bug9-launch-read-too-early (pre-7535504) | flow-app | [bug-9] |
| bug9-version-shape (pre-6646abf) | flow-replay | [bug-9] app_updated |
| bug13-messages-default-off (the pre-d5f9298 rule, at `SetupChoices.messagesSeed`) | flow-replay | [bug-13] fresh install |
| bug1-unlock-never-restarts (`WakeResumeMachine.end` plans nothing) | flow-replay | [bug-1] after the unlock; flow-app's three lock flows too |
| bug1-stale-refusal-is-storage (`CaptureFault.classify`: a refused save is a storage failure) | flow-replay | [bug-1] next words; flow-app lock-heard-late too |
| bug7-first-query-item (`SearchPage.query` reads the first query item, not `q`) | flow-replay | [flows] Chrome page rows (the fourth search's address has `sca_esv` first) |
| bug13-upgrade-optout-overridden (`messagesSeed` ignores the explicit off) | flow-replay | [bug-13] upgrade keeps the opt-out |

`runner-1001/mutate.sh` (tiers) runs them unattended.

Review fixes (10/08), each found by a mutation the first version MISSED:

- upgrade-messages-off saved the opt-out straight into the store and nothing ran the ON path again, so a `turnOnTyping`
  that overrides the person's Messages off went unseen. The upgrade history now saves the choice the way the
  checkbox does (`rememberMessagesChoice`) and then turns the typing switch off and on in Settings
  (`rememberTypingOff`, `turnOnTyping`).
- Every Google address had `q` first, so reading the first query item looked right. The fourth search's address now
  has `sca_esv` before `q`, as Google's own search box writes it.
- flow-app's lock-heard-late made a metadata save after 5.6 s without a heartbeat, but the store keeps metadata saves
  whatever the heartbeat (measured: records 0 -> 1 with the capture status "unavailable"), so no save was refused and
  both bug-1 `captureFailed` mutations passed it. It now also hands the coordinator the refusal the store throws for
  a typed unit (`captureFailed(MemError.invalid("Capture is not recording"), recording: true)`).
- `[bug-8] … the continuation is the same unit's next part` passed on an empty list when no row ended in "sig :(".
  It now needs that row, so on the RC it fails with finding 1 and is pinned with it (flow-replay min_pass 62).

A first bug-13 row put back the literal pre-d5f9298 line (`TypedCategoryChoices.init`'s default
`messagesAndEmail: false`). It was MISSED, and correctly so: since 5a26e5e and 3da8450, a fresh install's categories
are seeded in `turnOnTyping` from `SetupChoices`, so that default no longer reaches the path. The row now puts the
old rule ("off unless the person turns it on") back where the decision is made today.

## RC findings (pinned, frozen 0.1.8 RC)

1. **Bug 8 does not hold end to end in real capture.** `CoreCaptureBinding` saves an unpasted unit with `pasted=nil`
   (`TypedSendFacts.apply`: `pasted ? true : nil`). `TypedNarrativeCarry.certified` requires `pasted == false`, so no
   carry ever forms. A draft continued after a long pause has its next part withheld as `[withheld]` and loses its
   "sig :(" ending. The existing sig checks build their units with `pasted: false`, so they never see this.
   Pinned:
   - `[bug-8] … keeps its exact "sig :(" ending`
   - `[bug-8] … nothing typed is withheld`
   - `[bug-8] … the continuation is the same unit's next part`

   With `pasted=false` (the carry replay), the summaries pass keeps the carry. That label passes, and the pre-1398cbb
   mutation turns it red.
2. **A Google search's typed row reads back `<unreadable>`.** `WebTypedRow.valid` needs text for the
   `chrome-search-url-v1` provider, but the row is sealed with empty text, so `Privacy.sanitized` hides it. Pinned:
   `[flows] google-searches-chrome: each search's typed search row reads back with its words`. The page rows keep the
   words, so [bug-7] passes.
3. **Not pinned (by design in 0.1.8): the unit refused for a stale heartbeat is dropped.** Recording continues and the
   next words are saved, which is what bug 1 needs. The refused words themselves are lost.

## Limits

- **Page clock.** Chrome page times are compressed (see the page clock above), so the harness cannot test a page's
  exact dwell.
- **No real input path.** There is no OS event tap, so the tap's own enable and disable path is not exercised here
  (`owner-capture-input` covers it). The typing proof is faked per app.
- **`hold` takes real time,** up to 30 s per event.
- **0.2.0 rows.** The sample and session-event oracles are not compared until 0.2.0 implements the adapter.
