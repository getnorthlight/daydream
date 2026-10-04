# Headless check runner

Runs every synthetic check in the repo without opening a window. From the repo root:

    bash runner-1001/run-headless.sh <label>

Results go to `$WORKDIR/out-<label>/` (one log per step and a `SUMMARY` with one `name exit=N` line per step). `WORKDIR` defaults to `.build/checks`; sockets go to a fresh `/private/tmp/ddchk.*` folder unless `SOCKROOT` names one. The script exits non-zero if any step failed, and failed steps stay in `SUMMARY` even when later steps pass.

What you need first:

- Xcode's Swift toolchain (the checks compile against the app's sources).
- Sparkle 2.9.6 in `Vendor/`: `python3 scripts/bootstrap-sparkle.py` fetches and verifies it.
- Node 22 for the browser-extension checks (`NODE_BIN` can point at a specific binary).

`ONLY=<regex>` runs just the matching steps, for a rerun after a fix. Checks that need a real window are always logged as `SKIPPED-UI`.

The checks use made-up data and temporary homes only. They don't read your DayDream data, don't change privacy permissions, and don't launch, sign, notarize or install the app. Timings measured while other work runs on the Mac are not reliable.
