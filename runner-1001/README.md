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

- `LANES=smoke,storage` runs those lanes' rows plus the two builds. The lanes are smoke, setup-ui, capture, storage,
  ai-tools, release and perf.
- `ONLY=<regex>` runs just the matching steps, for a rerun after a fix. Remember `compile-`: `^(compile-)?name$`.
- `DRYRUN=1` lists the steps (`DRYRUN-steps.tsv`) without building or running anything.
- `runner-1001/lanes.sh RUN_DIR [COMMIT]` runs every lane at once. Each lane gets its own WORKDIR, and all of them use
  one detached snapshot of COMMIT, so edits to the tree never reach a running lane. It took 53 minutes (3,169 s, every
  lane OK) on the 12-core Mac mini at 8369afe (10/08), against about 3 hours serial. ai-tools is the long pole
  (owner-writer-cadence alone ran 36 minutes under the parallel load).

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
