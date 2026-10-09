#!/bin/bash
# usage: runner-1001/lanes.sh RUN_DIR [COMMIT]
# Every lane of scripts/checks-manifest.tsv at once, each in its own WORKDIR (RUN_DIR/<lane>), all from one detached
# snapshot of COMMIT (default HEAD) at RUN_DIR/src, so edits to this tree never reach a running lane. Each lane is
# run-headless.sh with LANES=<lane> from the snapshot; its verdict is RUN_DIR/<lane>/out-<lane>/VERDICT.
# Put RUN_DIR on an internal disk, outside /var and /tmp (uninstall-plan fails under them: see run-checks.sh).
# Needs TYPESENSE_BINARY (the storage lane's pinned typesense-server) and Sparkle in this tree's Vendor/
# (python3 scripts/bootstrap-sparkle.py). Exits 1 when any lane's verdict is not OK.
set -uo pipefail
RUN=${1:?usage: lanes.sh RUN_DIR [COMMIT]}
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
: "${TYPESENSE_BINARY:?set TYPESENSE_BINARY to the pinned typesense-server (see runner-1001/README.md)}"
[ -d "$REPO/Vendor" ] || { echo "REFUSING: no Vendor/ in $REPO (python3 scripts/bootstrap-sparkle.py)"; exit 2; }
LANES_ALL=${LANES_ALL:-smoke setup-ui capture storage ai-tools release perf}
mkdir -p "$RUN"; RUN=$(cd "$RUN" && pwd -P)
c=$(git -C "$REPO" rev-parse --short "${2:-HEAD}") || exit 2
S=$RUN/src
if [ ! -d "$S" ]; then git -C "$REPO" worktree add -q --detach "$S" "$c" && cp -R "$REPO/Vendor" "$S/Vendor" || exit 2; fi
[ "$(git -C "$S" rev-parse --short HEAD)" = "$c" ] || { echo "REFUSING: $S holds $(git -C "$S" rev-parse --short HEAD), not $c"; exit 2; }
export TYPESENSE_BINARY
echo "lanes at $c: $LANES_ALL"
start=$(date +%s); pids=()
for lane in $LANES_ALL; do
  ( s=$(date +%s); WORKDIR=$RUN/$lane LANES=$lane bash "$S/runner-1001/run-headless.sh" "$lane" > "$RUN/$lane.log" 2>&1
    rc=$?; echo "WALL $(( $(date +%s) - s ))s rc=$rc" >> "$RUN/$lane.log" ) & pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
echo "ALL-LANES WALL $(( $(date +%s) - start ))s at $c" | tee "$RUN/WALL"
bad=0
for lane in $LANES_ALL; do
  v=$(grep -h '^VERDICT' "$RUN/$lane/out-$lane/VERDICT" 2>/dev/null)
  echo "== $lane: ${v:-no verdict} $(grep -h '^WALL' "$RUN/$lane.log")"
  case "$v" in "VERDICT OK"*) ;; *) bad=1 ;; esac
done
echo "(the snapshot stays at $S for reruns; git -C '$REPO' worktree remove --force '$S' when done)"
exit $bad
