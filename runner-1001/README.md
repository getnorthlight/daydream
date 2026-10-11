# Headless check runner

Runs every synthetic check in the repo without opening a window. From the repo root:

    TYPESENSE_BINARY=/path/to/typesense-server bash runner-1001/run-headless.sh <label>

Results go to `$WORKDIR/out-<label>/`: one log per step, a `SUMMARY` with one `name exit=N pass=N` line per step, and a
`VERDICT`. `WORKDIR` defaults to `.build/checks`; sockets go to a fresh `/private/tmp/ddchk.*` folder unless `SOCKROOT`
names one.

## The verdict

The run's result is `scripts/verify-run-manifest.py` over `SUMMARY`, not a count of red steps. The script exits with
the verdict's code. `scripts/checks-manifest.tsv` has one row per step (lane, configuration, file, min_pass, status).
The verdict is FAIL when any of these happen:

- a selected row did not run. A `compile-X` line alone does not count as X running.
- a step is listed twice, or a step has no row.
- a required step or any compile failed.
- a step printed fewer PASS lines than its `min_pass`.
- the selection (`ONLY`/`LANES`) names no row.
- a dated row (a known failure, a window-only step) is past its `review_by`.

A known failure is pinned in `scripts/checks-known-failures.tsv`. It must exit with the listed code, still print its
`min_pass` PASS lines, and print only the listed FAIL lines, and every listed line must still fail. Anything else is
FAIL: a new FAIL in the same file, a crash, or a fixed assertion (narrow the pin). A known failure that passes in full
is XPASS: remove its row's status.

Steps that need a window (manifest `needs=window`) are logged `SKIPPED-UI`; that list comes from the manifest. Their
`compile-*` steps still run.

`python3 scripts/verify-run-manifest.py --inventory` fails on any check file anywhere in the tree (the sub-packages
too) that is neither a row's file nor listed in `scripts/checks-inventory-exempt.tsv` with a reason.

## Selecting steps

- `TIER=smoke|change|rc|nightly` (default rc) runs that tier's rows and every lower tier's (the manifest's `tier`
  column; blank = rc). The 273 rows: smoke 49 (the two debug builds, the smoke lane's checks and the source scans
  that need no build), change 209 (every other model, app, store, capture and writer check, with the app modules),
  rc 14 (the public twins store-perf, core-adapter, privacy-build and PrivacyChecks, the release builds, scans and
  gates, owner-writer-cadence, connect-horizon-py, honesty-switch-off and app-module-selftest), nightly 1 (the
  mutation run owner-permission-flash-mutation).
- `LANES=smoke,storage` runs those lanes' rows plus the builds. The lane list comes from the manifest and its
  fragments (`python3 scripts/verify-run-manifest.py --list-lanes`).
- `ONLY=<regex>` runs just the matching steps, for a rerun after a fix. Remember `compile-`: `^(compile-)?name$`.
- `DRYRUN=1` lists the steps (`DRYRUN-steps.tsv`) without building or running anything.

## Time limits

Every step runs in a process group of its own (runner-1001/bounded.sh). A step still running at its limit gets TERM,
then KILL 5 s later, to its whole group; its log ends "FAIL TIMEOUT <step>: ...", it exits 124, and the verdict lists it
as "TIMEOUT <step>" (never a known failure). The limit is STEP_TIMEOUT (default 900 s), or the row's own `timeout`
column (owner-writer-cadence 1800, owner-permission-flash-mutation 2400, runner-timeout-toy 20), or a step fragment's
`step_timeout NAME SECONDS`. mutate.sh reports a hung mutant as CAUGHT with "TIMEOUT <step>" instead of waiting it out
(a permission-drag-guide mutation once hung for 37 minutes); scripts/mutations.d/int-gaps.tsv row timeout-toy-hang
proves it end to end.

## Lanes

A row's lane is a known lane or one a manifest fragment declares ("# lanes: flows"); verify-run-manifest.py refuses any
other, and select-lanes.py refuses a checks-paths.tsv `lane:` target that names no lane.

## Path selection

`python3 runner-1001/select-lanes.py --base B --head H` (or `--paths P...`) maps every path of `git diff --name-only
B..H` to the steps it touches, through `scripts/checks-paths.tsv` (glob, targets, reason). A glob with a "/" matches
the whole path (`*` stays in one folder, `**` crosses folders); without one it matches the file name anywhere; a
leading "/" anchors it at the repo root. Targets: `lane:NAME`, `step:GLOB`, `config:C`, `own` (the rows whose file
it is), `uses` (the steps whose command, check file or loaded scripts/ helper names it), `all`, `none`. Every matching
rule counts.

- A path no rule selects a row for falls back to the full rc tier (no filter). The builds are always selected.
- The tier still applies on top: select-lanes picks WHAT a change touches, TIER how deep to go. The steps a change touches
  that its tier does not run are named ("held back by TIER=change ...": owner-writer-cadence, the writer-wake guard, is
  rc), so a change run never reads as covering them.
- Some rules: Package.swift and runner-1001/** give everything; Sources/MemoryCore/** and MemoryUI/** every lane;
  Sources/MacMemApp/** the setup-ui and capture lanes plus every step that compiles or scans the file (all
  APP-recipe steps, through the app module); WriterBackend/** ai-tools; docs/** and *.md the release docs steps only
  (plus the checks that read that page, for RELEASE.md, README.md, PRIVACY.md and similar).
- `select-lanes.py --self-test` (step select-lanes-py) checks the rules against the real tree: every manifest row is
  reachable from some rule, and the cases above select what they say.

## lanes.sh: one build per run, every lane at once

`runner-1001/lanes.sh RUN_DIR [COMMIT]` runs the selection at COMMIT (default HEAD) from a detached snapshot, so edits
to the tree never reach a running lane:

1. the snapshot is `CACHE/src` (CACHE defaults to `RUN_DIR/cache`: a cold run);
2. the builds run once, the public debug build and its app module beside the owner debug build and its app module,
   into CACHE (SHARED_BUILDS). Every worker reuses them read-only (PREBUILT=1);
3. one worker per lane, plus a worker of its own for each long step (SOLO: owner-writer-cadence,
   owner-permission-flash, stale-card, store-perf, owner-store-perf, dd-status, dd-focus-list, owner-launch-state,
   owner-production-capture, owner-typed-secret-fuzz). At most MAX_WORKERS (8, the performance cores) run at a time,
   the longest first (ORDER): with 18 at once, the time budgets of wb-AdapterChecks, PrivacyChecks and
   owner-MacMemChecks failed. Each worker has its own WORKDIR and module cache, and its compiles run at nice 10
   (COMPILE_NICE). The QUIET steps (core-adapter, owner-permission-blip, owner-chrome-offmain, wb-batch,
   wb-AdapterChecks: a real-time window of 1 s or less, or a main-thread time budget, that full load overran in a
   run; store-perf and owner-store-perf: the store's timing checks, whose heartbeat waits, measured on the wall clock,
   overran beside 7 other workers) run one at a time after the lane workers;
4. one SUMMARY, TIMES and VERDICT for the whole run in `RUN_DIR/out`, and `RUN_DIR/WALL` (the wall time, the build
   count, each worker's wall time).

`TIER=` and `BASE=<commit>` (path selection against that commit) apply. With `CACHE=<a folder kept across runs>` the
snapshot is checked out at the new commit (git touches only the changed files), so the builds are incremental and the
app module is reused when its key is unchanged. `runner-1001/bin/summary-diff.py OLD NEW` compares two runs step by
step (LOST, WORSE, LOWER fail; `--moved` names steps another tier runs now).

## The precompiled app module

The 30 APP-recipe checks used to compile the 86 app files (about 25,500 lines) again, each. Now
`runner-1001/app-module.sh` compiles the scratch copy of the app once per flag set into a static library and module
(DDApp), and each check compiles alone with `@testable import DDApp` (run-checks.sh `app_link`). The key is a sha256
of every input: each app file's bytes, the -D flags, the compiler version, the imported modules and the C headers. A
changed byte is a new key and a new build; nothing is reused by folder name or time stamp. The copies read the
socket root from `DD_CHECK_SOCKROOT` at run time, so the module is the same from run to run. `app-module-selftest`
proves it can't serve stale code: an edited app file gives a new key and a build, and the new string is in the linked
binary and absent from the old module.

## Mutation runs

`runner-1001/mutate.sh RUN_DIR [FILE.tsv...]` (default: every `scripts/mutations.d/*.tsv`) puts real bugs back, one
row at a time: bug, step, file, old, new, note (`\n`, `\t`, `\\` escaped). For each row it applies the change to a
scratch snapshot of the commit, runs only that step (with its builds) and reports CAUGHT (the step fails), MISSED
(the step still passes) or BROKEN (the snippet is absent or not unique, a build or the compile failed, or the step
fails without the bug). It exits 1 unless every row is CAUGHT. The snapshot is restored and checked clean after
each row. The owner-permission-flash-mutation step (nightly) is row flash-settle of `scripts/mutations.d/tiers.tsv`.

## Timings (measured)

On the 12-core Mac mini, 10/08-10/09, every run under `lockf -k ~/DaydreamReleases/.tp2-build.lock` with
TYPESENSE_BINARY set (other agents' locked builds and lane runs ran between these runs, not during them):

| What | Before | Now |
| --- | --- | --- |
| rc, cold, every lane (lanes.sh) | 3,169 s at 8369afe; 3,305 s at 74225f8 (7 lane workers, each building) | 2,514 s at cd658ed, VERDICT OK (21 workers, at most 8 at a time) |
| the builds of an rc run | each lane built what it used | 111 s for both debug builds and both app modules, once |
| 30 APP-recipe compiles, serial, warm builds | 692 s (74225f8) | 33 s, plus 40 s for the two app modules |
| the same 30 compiles inside the rc run | about 1,300 s | 154 s, plus 51 s for the two app modules |
| smoke after a one-line MemoryUI edit, warm | (no smoke tier) | 207 s (49 manifest rows; the incremental builds took 15 s) |
| change: one MacMemApp file, path-selected, warm | (no path selection) | 619 s (133 manifest rows, 14 workers, at most 8 at a time) |
| nightly: the flash mutation step | ran in every run | 925 s, warm (CAUGHT) |
| mutate.sh: the flash row and a no-op row, cold | | about 1,300 s: flash-settle CAUGHT, the no-op MISSED, exit 1 |

The rc wall time is the length of owner-writer-cadence (2,402 s in its own worker): every other worker, the quiet
steps included, is done by about 1,000 s. Sharding that step (the cadence package) is what brings rc under 25
minutes. Against the 8369afe run, step by step (bin/summary-diff.py): 0 steps lost, 0 worse, 0 with fewer PASS
lines; owner-permission-flash-mutation moved to nightly; the known-failure pins are unchanged.

## Fragments (packages add steps without editing the runner or the manifest)

- `runner-1001/steps.d/*.sh` are sourced by run-checks.sh in lexical order, after wired-lanes.sh and before SUMMARY,
  with its `step`, `OUT`, `I`, `R`, `B`, `OB`, `appsrc`, `oobjs`, `relocated` and `CAPTURE` (contract:
  `runner-1001/steps.d/README`).
- `scripts/checks-manifest.d/*.tsv` add rows: the manifest's columns plus `tier` (and optionally `timeout`). A new lane
  must be declared in the fragment ("# lanes: NAME"); the lane list (`verify-run-manifest.py --list-lanes`, what
  lanes.sh runs) comes from the rows.
- `scripts/checks-known-failures.d/*.tsv` add pins (same columns as the pin file).
- A step listed in two files is FAIL, and so is a step pinned in two pin files. `--inventory`, `--dryrun`,
  `--skip-regex` and `--lanes-regex` all see the fragments.

## What you need first

- Xcode's Swift toolchain (the checks compile against the app's sources).
- Sparkle 2.9.6 in `Vendor/`: `python3 scripts/bootstrap-sparkle.py` fetches and verifies it.
- Node 22 for the browser-extension checks (`NODE_BIN` can point at a specific binary).
- `TYPESENSE_BINARY` for the storage lane: the pinned `typesense-server`. Get it from `runtimeURL` in
  `packaging/TypesenseRuntime/local-typesense-v30.2.json` (check it against `archiveSHA256`), unpacked on an internal
  disk. Its sha256 must be `inputServerSHA256`. `run-headless.sh` refuses a full or storage run without it.
- A work folder outside `/var` and `/tmp`, for example `~/DaydreamReleases/<run>`. Under them, uninstall-plan fails
  because of an app behaviour: `UninstallProbe.noLinks` (`Sources/MemoryCore/Uninstall.swift`) reads
  `standardizedFileURL`, which drops `/private`, so the walk meets the `/var` or `/tmp` symlink and refuses the folder.
  The runner prints a NOTE when it sees such a work folder.

## Safety

The checks use made-up data and temporary homes only. They don't read your DayDream data, don't change privacy
permissions, and don't launch, sign, notarize or install the app.

One known exception is preview-app. The DayDream Preview sample lives in the per-user temporary folder
(`/var/folders/.../T/DayDream Preview Sample`), which ignores `TMPDIR`. preview-paths removes the sample afterwards
only when the run made it.

Timings measured while other work runs on the Mac are not reliable.
