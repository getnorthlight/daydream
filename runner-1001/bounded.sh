# runner-1001/bounded.sh: the per-step time limit, sourced by run-checks.sh (and by scripts/verify-run-manifest-checks.py's
# cases). bash 3.2 (macOS /bin/bash): no associative arrays.
#
#   STEP_TIMEOUT        the default limit in seconds (900)
#   STEP_TIMEOUTS       "step<TAB>seconds" lines: the manifest's `timeout` column (verify-run-manifest.py --timeouts),
#                       plus any step_timeout call; the last line for a step wins
#   step_timeout N S    a step fragment's own limit for step N
#   step_limit N        prints step N's limit (a compile-X step has the default unless it is named itself)
#   run_bounded NAME LIMIT LOG NICE CMD...
#                       runs CMD (a command or a shell function) in a process group of its own (set -m), stdin from
#                       /dev/null, stdout and stderr to LOG, at niceness NICE when given; a watchdog in another group
#                       sends the whole group TERM after LIMIT seconds and KILL 5 s later. Returns CMD's exit, or 124 on a
#                       timeout, when LOG ends with "FAIL TIMEOUT NAME: ...".
#   end_step_groups     ends the running step's group and its watchdog (the runner's TERM/INT/HUP traps call it, so a
#                       killed run leaves no step behind in its own group)
STEP_TIMEOUT=${STEP_TIMEOUT:-900}
STEP_TIMEOUTS=${STEP_TIMEOUTS:-}
CUR_PG= CUR_WD=
step_timeout() { STEP_TIMEOUTS="$STEP_TIMEOUTS"$'\n'"$1"$'\t'"$2"; }
step_limit() { printf '%s\n' "$STEP_TIMEOUTS" | awk -F'\t' -v n="$1" -v d="$STEP_TIMEOUT" '$1==n && $2 ~ /^[0-9]+$/ && $2>0 {v=$2} END {print (v ? v : d)}'; }
end_step_groups() { [ -n "$CUR_PG" ] && kill -TERM -- -"$CUR_PG" 2>/dev/null; [ -n "$CUR_WD" ] && kill -TERM -- -"$CUR_WD" 2>/dev/null; return 0; }
run_bounded() { local name=$1 lim=$2 log=$3 nic=$4; shift 4; local pid wpid rc mark
  mark=$(dirname "$log")/.timeout-$name
  rm -f "$mark"
  set -m
  ( trap - TERM INT HUP; exec </dev/null
    [ -n "$nic" ] && renice -n "$nic" -p "$(exec sh -c 'echo $PPID')" >/dev/null 2>&1
    "$@" ) >"$log" 2>&1 &
  pid=$!
  ( trap - TERM INT HUP; exec >/dev/null 2>&1 </dev/null
    sleep "$lim"; : > "$mark"; kill -TERM -- -"$pid"; sleep 5; kill -KILL -- -"$pid" ) &
  wpid=$!
  set +m
  CUR_PG=$pid CUR_WD=$wpid
  { wait "$pid"; } 2>/dev/null; rc=$?
  if [ -f "$mark" ]; then
    # TERM went to the group; whatever ignored it gets KILL now (the watchdog would send it 5 s later).
    sleep 1; kill -KILL -- -"$pid" 2>/dev/null; rm -f "$mark"; rc=124
    echo "FAIL TIMEOUT $name: still running after ${lim} s; its process group was killed (limit: STEP_TIMEOUT or the row's timeout)" >> "$log"
  fi
  kill -TERM -- -"$wpid" 2>/dev/null; { wait "$wpid"; } 2>/dev/null
  CUR_PG= CUR_WD=
  return $rc; }
