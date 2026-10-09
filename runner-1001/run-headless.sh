#!/bin/bash
# Headless synthetic checks. All builds and outputs stay in WORKDIR (default .build/checks in this repo).
# Env: LANES=a,b (manifest lanes), ONLY=<regex>, TYPESENSE_BINARY (the storage lane's pinned server). See README.md.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export SRC=${SRC:-$(dirname "$HERE")}
export WORKDIR=${WORKDIR:-$SRC/.build/checks}
# A full run, or the storage lane, starts real Typesense: refuse up front instead of a red typesense-binary step and
# every search step after it.
if [ -z "${TYPESENSE_BINARY:-}" ] && [ -z "${ONLY:-}" ] && { [ -z "${LANES:-}" ] || [[ ,$LANES, == *,storage,* ]]; }; then
  echo "REFUSING: TYPESENSE_BINARY is not set. Point it at the pinned typesense-server: runtimeURL in"
  echo "  packaging/TypesenseRuntime/local-typesense-v30.2.json (archiveSHA256 there), unpacked on an internal disk;"
  echo "  its sha256 must be inputServerSHA256. Or run other lanes (LANES=smoke,capture,...)."
  exit 2
fi
# /tmp is a symlink; the checks compare resolved paths, so the root is resolved (/private/tmp/...).
OWNSOCK=; [ -n "${SOCKROOT:-}" ] || { SOCKROOT=$(mktemp -d /private/tmp/ddchk.XXXXXX); OWNSOCK=1; }
mkdir -p "$SOCKROOT"; export SOCKROOT=$(cd "$SOCKROOT" && pwd -P)
# Default homes are isolated too, even for a step that forgets its own fixture HOME.
mkdir -p "$WORKDIR/headless-home/Library/Preferences"
export HOME="$WORKDIR/headless-home" CFFIXED_USER_HOME="$WORKDIR/headless-home"
# The window steps to skip come from the manifest (run-checks.sh: needs=window), not from here.
printf 'start %s HEAD %s; timings contaminated under parallel workload\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$(git -C "$SRC" rev-parse HEAD)"
rc=0; nice bash "$HERE/run-checks.sh" "${1:-run}" || rc=$?
[ -z "$OWNSOCK" ] || rm -rf "$SOCKROOT"
exit $rc
