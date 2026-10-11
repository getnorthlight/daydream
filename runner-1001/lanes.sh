#!/bin/bash
# usage: runner-1001/lanes.sh RUN_DIR [COMMIT]
# The suite at COMMIT (default HEAD) from a detached snapshot, in parallel workers, with ONE build of each kind:
#   1. the snapshot: CACHE/src, a git worktree checked out at COMMIT (edits to this tree never reach a run);
#   2. the selection: TIER (smoke < change < rc < nightly, default rc) and, with BASE=<commit>, the steps
#      runner-1001/select-lanes.py picks from `git diff --name-only BASE..COMMIT` (an unmatched path: the full rc tier);
#   3. the builds, once: the public debug build + its app module, and the owner debug build + its app module, two
#      processes side by side, into CACHE (SHARED_BUILDS); every worker reuses them read-only (PREBUILT=1);
#   4. the workers: one per lane with selected steps (the manifest's and its fragments' lanes), plus one of its own for
#      each long step matching SOLO; all at once, each with its own WORKDIR (RUN_DIR/w-<worker>) and socket root;
#   5. the verdict: scripts/verify-run-manifest.py over every worker's SUMMARY and the builds' together
#      (RUN_DIR/out/SUMMARY, VERDICT, TIMES; the logs are linked into RUN_DIR/out).
# CACHE (default RUN_DIR/cache: a cold run) can be a folder kept across runs: its snapshot is checked out at COMMIT
# (git touches only the files that changed), so SwiftPM's builds there are incremental, and the app module is reused
# when its key (a hash of its inputs, runner-1001/app-module.sh) is unchanged.
# Put RUN_DIR and CACHE on an internal disk, outside /var and /tmp (uninstall-plan fails under them: see run-checks.sh).
# Needs TYPESENSE_BINARY when a selected step needs Typesense, and Sparkle in this tree's Vendor/
# (python3 scripts/bootstrap-sparkle.py). Exits with the verdict's code (2: refused before running).
set -uo pipefail
RUN=${1:?usage: lanes.sh RUN_DIR [COMMIT]}
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[ -d "$REPO/Vendor" ] || { echo "REFUSING: no Vendor/ in $REPO (python3 scripts/bootstrap-sparkle.py)"; exit 2; }
mkdir -p "$RUN"; RUN=$(cd "$RUN" && pwd -P)
case "$RUN" in /private/var/*|/private/tmp/*) echo "REFUSING: RUN_DIR under /var or /tmp ($RUN); use an internal-disk folder"; exit 2 ;; esac
c=$(git -C "$REPO" rev-parse --short "${2:-HEAD}") || exit 2
CACHE=${CACHE:-$RUN/cache}; mkdir -p "$CACHE"; CACHE=$(cd "$CACHE" && pwd -P)
S=$CACHE/src
# One run at a time per cache.
if ! mkdir "$CACHE/.lanes-busy" 2>/dev/null; then
  holder=$(cat "$CACHE/.lanes-busy/pid" 2>/dev/null)
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then echo "REFUSING: $CACHE is in use by lanes.sh pid $holder"; exit 2; fi
  rm -rf "$CACHE/.lanes-busy"; mkdir "$CACHE/.lanes-busy" || exit 2
fi
echo $$ > "$CACHE/.lanes-busy/pid"
trap 'rm -rf "$CACHE/.lanes-busy"' EXIT
start=$(date +%s)
if [ ! -e "$S/.git" ]; then
  git -C "$REPO" worktree add -q --detach "$S" "$c" && cp -R "$REPO/Vendor" "$S/Vendor" || exit 2
else
  # Only the files that changed get a new time stamp, so the builds in CACHE stay incremental and correct.
  git -C "$S" checkout -q --detach -f "$c" && git -C "$S" clean -ffdxq -e /Vendor || exit 2
  [ -d "$S/Vendor" ] || cp -R "$REPO/Vendor" "$S/Vendor" || exit 2
fi
[ "$(git -C "$S" rev-parse --short HEAD)" = "$c" ] || { echo "REFUSING: $S holds $(git -C "$S" rev-parse --short HEAD), not $c"; exit 2; }
[ -z "$(git -C "$S" status --porcelain --untracked-files=no)" ] || { echo "REFUSING: $S has changes"; exit 2; }
V="python3 $S/scripts/verify-run-manifest.py"
TIER=${TIER:-rc}; ONLY=${ONLY:-}; LANES=${LANES:-}
if [ -n "${BASE:-}" ]; then
  sel=$(cd "$S" && python3 runner-1001/select-lanes.py --base "$BASE" --head "$c" --tier "$TIER" --format env) || { echo "REFUSING: select-lanes.py failed"; exit 2; }
  printf '%s\n' "$sel" | sed -n 's/^# /select-lanes: /p'
  TIER=$(printf '%s\n' "$sel" | sed -n 's/^TIER=//p'); PONLY=$(printf '%s\n' "$sel" | sed -n 's/^ONLY=//p')
  if [ -n "$PONLY" ] && [ -n "$ONLY" ]; then echo "REFUSING: BASE and ONLY both select steps; use one"; exit 2; fi
  ONLY=${ONLY:-$PONLY}
fi
# SOLO steps get a worker of their own (the long ones: 70 s and more in a warm change run), so no lane waits on them.
SOLO=${SOLO:-^(owner-writer-cadence|owner-permission-flash|stale-card|store-perf|owner-store-perf|dd-status|dd-focus-list|owner-launch-state|owner-production-capture|owner-typed-secret-fuzz)$}
# QUIET steps get a worker of their own that starts only when the lane workers are done (the long solo steps may still
# run). They are checks with a short real-time window that full-machine load can overrun:
#   core-adapter: the wall clock taken at its start must be within 1 s of the recording heartbeat
#     (scripts/core-adapter-checks.swift `now`); it crashed twice under 11 workers' load, never alone.
#   owner-permission-blip: G33-person sets a 0.2 s permission blip and expects Start to read inside it; it failed once
#     under load (passed in the three other runs and alone).
#   owner-chrome-offmain: its bench holds an allowed Chrome key to under 3 ms of main-thread time; it failed once under
#     18 workers (passed in the four runs before).
#   wb-batch, wb-AdapterChecks: cancel a writer request 50 ms after starting it and expect it prepared by then; each
#     crashed once under load ("cancellation cancels ... without commit").
#   store-perf, owner-store-perf: the store's timing checks (the heartbeat's longest wait under 50 ms of wall time). Beside
#     7 other workers (verifier's rc run at 0c84b87) owner-store-perf's missing-word search took 75.8 s on the
#     recorder's connection and the other process's search hit "Memory storage busy: read failed (code 5)" after 222 s.
#     (That other-process search ran on a rollback-journal history and passed or failed by chance, alone too; since
#     rel-019 flakeB it runs on the WAL history the app keeps, and the pins are gone.) A timing check measures the store,
#     not the machine's load. They end well before owner-writer-cadence, so the wall is unchanged.
QUIET=${QUIET:-^(core-adapter|owner-permission-blip|owner-chrome-offmain|wb-batch|wb-AdapterChecks|store-perf|owner-store-perf)$}
plan=$(cd "$S" && $V --plan --only "$ONLY" --lanes "$LANES" --tier "$TIER" --solo "($SOLO)|($QUIET)") || exit 2
[ -n "$plan" ] || { echo "REFUSING: the selection (TIER=$TIER LANES=$LANES ONLY=$ONLY) has no step"; exit 2; }
if [ -z "${TYPESENSE_BINARY:-}" ] && printf '%s\n' "$plan" | cut -f2 | grep -q 'typesense'; then
  echo "REFUSING: a selected step needs TYPESENSE_BINARY (the pinned typesense-server; see runner-1001/README.md)"; exit 2
fi
export COMPILE_NICE=${COMPILE_NICE:-10} TYPESENSE_BINARY="${TYPESENSE_BINARY:-}" SRC=$S SHARED_BUILDS=$CACHE APP_MODULE_CACHE=$CACHE/app-module TIER LANES
nw=$(printf '%s\n' "$plan" | wc -l | tr -d ' ')
echo "lanes at $c: TIER=$TIER${BASE:+ BASE=$BASE}${LANES:+ LANES=$LANES} cache=$CACHE, $nw workers: $(printf '%s\n' "$plan" | cut -f1 | tr '\n' ' ')"
# Each worker has its own WORKDIR and its own clang/Swift module cache. Not one shared through symlinks: clang then sees
# the same .pcm under two paths ("module '_Builtin_stdarg' is defined in both ...") and the app module fails to build.
wdir() { mkdir -p "$RUN/$1"; echo "$RUN/$1"; }
runw() { # NAME ONLY [env...]: one run-headless.sh, its wall time appended to RUN/NAME.log
  local name=$1 only=$2; shift 2; local s rc; s=$(date +%s)
  (cd "$S" && env WORKDIR="$(wdir "$name")" ONLY="$only" NO_VERDICT=1 "$@" bash runner-1001/run-headless.sh "$name") > "$RUN/$name.log" 2>&1
  rc=$?; echo "WALL $(( $(date +%s) - s ))s rc=$rc" >> "$RUN/$name.log"; }
# 3. The builds, once (public and owner side by side). The tier still applies (a TIER=smoke run has no app module).
pre=$(date +%s)
runw prep-public '^(build|app-module)$' BUILD_JOBS=6 &
p1=$!
runw prep-owner '^(owner-build|owner-app-module)$' BUILD_JOBS=6 &
p2=$!
wait $p1 $p2
echo "builds: $(( $(date +%s) - pre ))s: $(cat "$RUN"/prep-*/out-prep-*/SUMMARY 2>/dev/null | tr '\n' ' ')"
built=1
for b in build owner-build; do grep -q "^$b exit=0 " "$RUN"/prep-*/out-prep-*/SUMMARY 2>/dev/null || built=; done
# 4. The workers: at most MAX_WORKERS at a time (default 8, this Mac's performance cores; 18 at once overran the time
# budgets of wb-AdapterChecks, PrivacyChecks and owner-MacMemChecks), the longest first. ORDER lists the workers by
# their measured length (an rc run, 10/09); the others start after them, in plan order.
MAX_WORKERS=${MAX_WORKERS:-8}
ORDER=${ORDER:-owner-writer-cadence storage release ai-tools setup-ui stale-card owner-permission-flash smoke capture owner-store-perf store-perf dd-status owner-production-capture owner-typed-secret-fuzz owner-launch-state dd-focus-list}
pids=() lane_pids=() quiet=() todo=()
for o in $ORDER; do while IFS=$'\t' read -r name only n; do [ "$name" = "$o" ] && todo+=("$name	$only"); done <<< "$plan"; done
while IFS=$'\t' read -r name only n; do
  case " $ORDER " in *" $name "*) ;; *) todo+=("$name	$only") ;; esac
done <<< "$plan"
running() { local p c=0; for p in ${pids[@]+"${pids[@]}"}; do kill -0 "$p" 2>/dev/null && c=$((c+1)); done; echo $c; }
if [ -n "$built" ]; then
  for t in "${todo[@]}"; do
    name=${t%%	*} only=${t#*	}
    if [[ $name =~ $QUIET ]]; then quiet+=("$t"); continue; fi
    while [ "$(running)" -ge "$MAX_WORKERS" ]; do sleep 2; done
    runw "w-$name" "$only" PREBUILT=1 & pids+=($!)
    [[ $name =~ $SOLO ]] || lane_pids+=($!)
  done
  if [ ${#quiet[@]} -gt 0 ]; then
    for p in ${lane_pids[@]+"${lane_pids[@]}"}; do wait "$p"; done
    for q in "${quiet[@]}"; do runw "w-${q%%	*}" "${q#*	}" PREBUILT=1; done
  fi
  for p in ${pids[@]+"${pids[@]}"}; do wait "$p"; done
else
  echo "the builds failed: no worker ran (the verdict lists every step as missing)"
fi
# 5. One SUMMARY, one verdict.
O=$RUN/out; rm -rf "$O"; mkdir -p "$O"
for d in "$RUN"/prep-public "$RUN"/prep-owner "$RUN"/w-*; do
  [ -d "$d" ] || continue
  for o in "$d"/out-*; do
    [ -f "$o/SUMMARY" ] && cat "$o/SUMMARY" >> "$O/SUMMARY"
    [ -f "$o/TIMES" ] && sed "s/\$/ $(basename "$d")/" "$o/TIMES" >> "$O/TIMES"
    for l in "$o"/*.log; do [ -e "$l" ] && ln -sf "$l" "$O/$(basename "$l")"; done
  done
done
touch "$O/SUMMARY"
(cd "$S" && $V --summary "$O/SUMMARY" --only "$ONLY" --lanes "$LANES" --tier "$TIER" --logs "$O") > "$O/VERDICT"; rc=$?
wall=$(( $(date +%s) - start ))
nb=$(ls "$RUN"/*/out-*/build.log 2>/dev/null | wc -l | tr -d ' '); nob=$(ls "$RUN"/*/out-*/owner-build.log 2>/dev/null | wc -l | tr -d ' ')
{
  echo "ALL-LANES WALL ${wall}s at $c TIER=$TIER${BASE:+ BASE=$BASE} ($nw workers)"
  echo "BUILDS public debug $nb, owner debug $nob (one each per run)"
  for d in "$RUN"/prep-public "$RUN"/prep-owner "$RUN"/w-*; do
    [ -d "$d" ] && echo "== $(basename "$d"): $(grep -h '^WALL' "$RUN/$(basename "$d").log" 2>/dev/null)"
  done
  grep '^VERDICT' "$O/VERDICT"
} | tee "$RUN/WALL"
sed -n '/^== FAIL ([1-9]/,/^VERDICT/p' "$O/VERDICT" | head -40
echo "(the snapshot stays at $S; run again with CACHE=$CACHE for an incremental run)"
exit $rc
