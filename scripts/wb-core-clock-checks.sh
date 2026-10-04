#!/bin/bash
# wb-core at every time of day and in every time zone (gold/r2-copy-checks). WriterBackend/CoreChecks builds a day of
# synthetic actions around "now"; it used Date(), and from midnight to 1 AM in New York its visits at 1 AM were still
# ahead, so it failed an hour a night. This runs the built check under a shifted clock (scripts/clock-shift.c, loaded
# into the check alone) at the hours around midnight, noon and the DST changes, and with several TZ values.
# Usage: wb-core-clock-checks.sh <core-checks binary> <libclockshift.dylib> <clock-shift-probe binary>
# Synthetic stores in the check's own TMPDIR folder; nothing else runs under the shifted clock.
set -u
bin=${1:?core-checks binary}; shim=${2:?clock shift dylib}; probe=${3:?clock-shift-probe binary}
fails=0; passes=0
at() { python3 -c 'import datetime,zoneinfo,sys; y,m,d,H,M,S=map(int,sys.argv[1:7]); print(datetime.datetime(y,m,d,H,M,S,tzinfo=zoneinfo.ZoneInfo("America/New_York")).timestamp())' "$@"; }
run() { local label=$1 when=$2 tz=$3 out seen
  if [ -z "$when" ]; then out=$(env TZ="$tz" "$bin" 2>&1)
  else
    # The shift must take: the probe, under the same shim and time, reads the wanted time (within two minutes).
    seen=$(env TZ="$tz" DD_FAKE_NOW="$when" DYLD_INSERT_LIBRARIES="$shim" "$probe" 2>&1)
    if ! python3 -c 'import sys; sys.exit(0 if abs(float(sys.argv[1])-float(sys.argv[2]))<120 else 1)' "$seen" "$when" 2>/dev/null; then
      fails=$((fails+1)); echo "FAIL: wb-core at $label (TZ=$tz): the clock shift did not take (probe read $seen, wanted $when)"; return; fi
    out=$(env TZ="$tz" DD_FAKE_NOW="$when" DYLD_INSERT_LIBRARIES="$shim" "$bin" 2>&1)
  fi
  local rc=$?
  if [ $rc -eq 0 ] && grep -q "checks passed" <<<"$out"; then passes=$((passes+1)); echo "PASS wb-core at $label (TZ=$tz)"
  else fails=$((fails+1)); echo "FAIL: wb-core at $label (TZ=$tz): $(grep -m1 -E 'Fatal error|FAIL|error' <<<"$out" | cut -c1-220)"; fi; }
# Every shifted run is preceded by a probe of the clock under the same shift (above); the old check fails 25 of these.
run "the real clock" "" "${TZ:-}"
for hm in "2026 9 27 0 0 5" "2026 9 27 0 30 0" "2026 9 27 0 59 59" "2026 9 27 1 0 30" "2026 9 27 11 59 59" "2026 9 27 12 0 0" \
          "2026 9 27 23 59 30" "2026 3 8 0 30 0" "2026 3 8 3 30 0" "2026 11 1 0 30 0" "2026 11 1 1 30 0" "2026 12 31 0 30 0"; do
  set -- $hm
  label=$(printf '%04d-%02d-%02d %02d:%02d:%02d New York' "$@")
  for tz in America/New_York UTC Pacific/Kiritimati Pacific/Pago_Pago America/Los_Angeles; do
    run "$label" "$(at "$@")" "$tz"
  done
done
echo "$passes passed, $fails failed"
[ $fails -eq 0 ]
