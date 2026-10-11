#!/bin/bash
# usage: runner-1001/mutate.sh RUN_DIR [FILE.tsv...]   (default: every scripts/mutations.d/*.tsv)
# The mutation driver: does a check still catch the bug it was written for? Each row of a scripts/mutations.d/*.tsv
# (bug, step, file, old, new, note; "\n", "\t" and "\\" escaped in old/new) puts one real bug back:
#   1. a scratch snapshot of COMMIT (MUT_COMMIT, default HEAD) at RUN_DIR/src (a detached git worktree; Vendor copied);
#   2. `old` must occur exactly once in `file`; it is replaced with `new`;
#   3. the runner runs only that step: ONLY='^(build|owner-build|app-module|owner-app-module|(compile-)?STEP)$' (the
#      builds are incremental, in RUN_DIR/cache), TIER=nightly;
#   4. the verdict: CAUGHT when the step fails (the verdict is FAIL with every build and compile-STEP green),
#      MISSED when it passes, BROKEN when the snippet is absent or not unique, a build or the compile fails, or the
#      step did not run; then the file is restored and the snapshot must be clean again. A step that hangs is killed
#      at its time limit by the runner (runner-1001/bounded.sh: STEP_TIMEOUT, default 900 s, or the row's timeout) and
#      is CAUGHT with "TIMEOUT <step>" in its line: a hang is reported, never waited out.
# Before the rows, each step runs once unmutated (MUT_BASELINE=0 skips it): a step that fails unmutated makes its rows
# BROKEN (a mutation of a red step proves nothing).
# Env: MUT_COMMIT, MUT_BUG=<regex> (only rows whose bug matches), MUT_RUNNER (the runner, relative to the snapshot;
# default runner-1001/run-headless.sh), MUT_KEEP=1 (keep the snapshot worktree), TYPESENSE_BINARY (passed through).
# Exit 0 only when every row is CAUGHT (and there is at least one); 1 otherwise; 2 when refused.
set -uo pipefail
RUN=${1:?usage: mutate.sh RUN_DIR [FILE.tsv...]}; shift
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=${MUT_REPO:-$(cd "$HERE/.." && pwd)}
mkdir -p "$RUN"; RUN=$(cd "$RUN" && pwd -P)
files=("$@"); [ ${#files[@]} -gt 0 ] || files=("$REPO"/scripts/mutations.d/*.tsv)
for f in "${files[@]}"; do [ -f "$f" ] || { echo "REFUSING: no mutation file $f"; exit 2; }; done
commit=$(git -C "$REPO" rev-parse --short "${MUT_COMMIT:-HEAD}") || exit 2
S=$RUN/src
if [ -e "$S/.git" ]; then git -C "$S" checkout -q --detach -f "$commit" && git -C "$S" clean -ffdxq -e /Vendor || exit 2
else git -C "$REPO" worktree add -q --detach "$S" "$commit" || exit 2; fi
[ -d "$REPO/Vendor" ] && [ ! -d "$S/Vendor" ] && cp -R "$REPO/Vendor" "$S/Vendor"
cleanup() { [ -n "${MUT_KEEP:-}" ] || git -C "$REPO" worktree remove --force "$S" 2>/dev/null; }
trap cleanup EXIT
runner=${MUT_RUNNER:-runner-1001/run-headless.sh}
# The rows, one per line: index, bug, step, file, note (old/new stay in the TSV; `apply` reads them by index).
rows=$(python3 - parse "${files[@]}" <<'PY'
import sys
def unesc(s):
    out, i = [], 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s) and s[i + 1] in "nt\\":
            out.append({"n": "\n", "t": "\t", "\\": "\\"}[s[i + 1]]); i += 2
        else:
            out.append(s[i]); i += 1
    return "".join(out)
n = 0
for f in sys.argv[2:]:
    for k, line in enumerate(open(f), 1):
        line = line.rstrip("\n")
        if not line.strip() or line.startswith("#"):
            continue
        c = line.split("\t")
        if c[0] == "bug":
            if c != ["bug", "step", "file", "old", "new", "note"]:
                sys.exit("mutate: %s: header must be bug step file old new note" % f)
            continue
        if len(c) != 6 or not all(c[:4]):
            sys.exit("mutate: %s line %d: want 6 cells (bug step file old new note), the first four non-empty" % (f, k))
        print("%d\t%s\t%s\t%s\t%s\t%s:%d" % (n, c[0], c[1], c[2], c[5].replace("\t", " "), f, k)); n += 1
PY
) || exit 2
[ -n "$rows" ] || { echo "REFUSING: no mutation rows in ${files[*]}"; exit 2; }
apply() { # FILE.tsv:LINE SNAPSHOT -> exit 3 when `old` is not in the file exactly once
  python3 - "$1" "$2" <<'PY'
import sys
def unesc(s):
    out, i = [], 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s) and s[i + 1] in "nt\\":
            out.append({"n": "\n", "t": "\t", "\\": "\\"}[s[i + 1]]); i += 2
        else:
            out.append(s[i]); i += 1
    return "".join(out)
where, snap = sys.argv[1], sys.argv[2]
f, k = where.rsplit(":", 1)
c = open(f).read().split("\n")[int(k) - 1].split("\t")
path, old, new = c[2], unesc(c[3]), unesc(c[4])
try:
    text = open(snap + "/" + path).read()
except OSError as e:
    print("no file %s (%s)" % (path, e)); sys.exit(3)
n = text.count(old)
if n != 1:
    print("the snippet occurs %d times in %s (want exactly 1)" % (n, path)); sys.exit(3)
open(snap + "/" + path, "w").write(text.replace(old, new))
print("applied to %s (%d -> %d bytes)" % (path, len(text), len(text) - len(old) + len(new)))
PY
}
# run LABEL STEP -> sets RESULT (OK / FAIL / BROKEN:<why>)
run() { local label=$1 st=$2 out w
  w=$RUN/w-$label; rm -rf "$w"; mkdir -p "$w"
  (cd "$S" && env -u LANES -u PREBUILT -u NO_VERDICT -u ONLY WORKDIR="$w" SRC="$S" SHARED_BUILDS="$RUN/cache" \
     APP_MODULE_CACHE="$RUN/cache/app-module" TIER=nightly ONLY="^(build|owner-build|app-module|owner-app-module|(compile-)?$st)\$" \
     bash "$runner" "$label") > "$RUN/$label.log" 2>&1
  out=$w/out-$label
  RESULT=
  [ -f "$out/SUMMARY" ] || { RESULT="BROKEN:no SUMMARY (see $RUN/$label.log)"; return; }
  local bad; bad=$(grep -E "^(build|owner-build|app-module|owner-app-module|compile-$st) exit=[1-9-]" "$out/SUMMARY" | head -1)
  if [ -n "$bad" ] && grep -q "^FAIL TIMEOUT ${bad%% *}:" "$out/${bad%% *}.log" 2>/dev/null; then
    RESULT="BROKEN:${bad%% *} timed out ($(grep -h "^FAIL TIMEOUT ${bad%% *}:" "$out/${bad%% *}.log" | tail -1))"; return; fi
  [ -z "$bad" ] || { RESULT="BROKEN:the build failed ($bad)"; return; }
  grep -qE "^$st (exit=|SKIPPED-UI)" "$out/SUMMARY" || { RESULT="BROKEN:the step did not run"; return; }
  grep -q "^$st SKIPPED-UI" "$out/SUMMARY" && { RESULT="BROKEN:the step needs a window (SKIPPED-UI)"; return; }
  if grep -q '^VERDICT OK' "$out/VERDICT" 2>/dev/null; then RESULT=OK
  elif grep -q "^FAIL TIMEOUT $st:" "$out/$st.log" 2>/dev/null; then
    # A hang is reported, not waited out: the runner killed the step at its limit (runner-1001/bounded.sh).
    RESULT="FAIL:TIMEOUT $st, the step hung and was killed ($(grep -h "^FAIL TIMEOUT $st:" "$out/$st.log" | tail -1 | sed 's/^FAIL TIMEOUT [^:]*: //'))"
  elif grep -q '^VERDICT FAIL' "$out/VERDICT" 2>/dev/null; then RESULT="FAIL:$(grep -E "^$st " "$out/SUMMARY")"
  else RESULT="BROKEN:no verdict"; fi
}
rm -f "$RUN/RESULTS.tsv"
echo "mutate at $commit: $(printf '%s\n' "$rows" | wc -l | tr -d ' ') rows from ${files[*]}"
caught=0 missed=0 broken=0 total=0
declare -a base_ok=() base_steps=()
baseline() { local st=$1 i
  for i in ${base_steps[@]+"${!base_steps[@]}"}; do [ "${base_steps[$i]}" = "$st" ] && { BASE=${base_ok[$i]}; return; }; done
  if [ "${MUT_BASELINE:-1}" = 0 ]; then BASE=OK
  else run "base-$st" "$st"; BASE=$RESULT; echo "baseline $st (unmutated): $BASE"; fi
  base_steps+=("$st"); base_ok+=("$BASE"); }
while IFS=$'\t' read -r idx bug st file note where; do
  if [ -n "${MUT_BUG:-}" ] && ! [[ $bug =~ $MUT_BUG ]]; then continue; fi
  total=$((total+1))
  baseline "$st"
  if [ "$BASE" != OK ]; then verdict=BROKEN; why="the step does not pass unmutated ($BASE)"
  elif ! msg=$(apply "$where" "$S"); then verdict=BROKEN; why=$msg
  else
    run "m$idx" "$st"
    case "$RESULT" in
      FAIL:*) verdict=CAUGHT; why="${RESULT#FAIL:}" ;;
      OK) verdict=MISSED; why="the step still passes with the bug back" ;;
      *) verdict=BROKEN; why="${RESULT#BROKEN:}" ;;
    esac
  fi
  git -C "$S" checkout -q -f -- . && git -C "$S" clean -ffdxq -e /Vendor
  [ -z "$(git -C "$S" status --porcelain --untracked-files=no)" ] || { echo "REFUSING: the snapshot did not come back clean after $bug"; exit 2; }
  case $verdict in CAUGHT) caught=$((caught+1)); echo "PASS [mutation] $bug: CAUGHT by $st ($why)" ;;
    MISSED) missed=$((missed+1)); echo "FAIL [mutation] $bug: MISSED by $st: $why" ;;
    *) broken=$((broken+1)); echo "FAIL [mutation] $bug: BROKEN for $st: $why" ;; esac
  echo "$verdict	$bug	$st	$file	$note" >> "$RUN/RESULTS.tsv"
done <<< "$rows"
echo "mutate: $total rows: $caught CAUGHT, $missed MISSED, $broken BROKEN"
[ "$total" -gt 0 ] && [ "$caught" -eq "$total" ]
