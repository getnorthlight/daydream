#!/bin/bash
# Headless B2 fixtures only. Requires the repository's existing Sparkle vendor
# dependency (no download/bootstrap here). No app target, model or owner data.
set -eo pipefail
SOURCE=$(cd "$(dirname "$0")/.." && pwd)
SCRATCH=${1:-$(mktemp -d /private/tmp/daydream-messages-checks.XXXXXX)}
mkdir -p "$SCRATCH/tmp" "$SCRATCH/modcache"
SCRATCH=$(cd "$SCRATCH" && pwd)
export TMPDIR="$SCRATCH/tmp/" CLANG_MODULE_CACHE_PATH="$SCRATCH/modcache" SWIFT_MODULECACHE_PATH="$SCRATCH/modcache"
cd "$SOURCE"
for lane in public owner; do
    flags=()
    swiftflags=()
    if [ "$lane" = owner ]; then
        flags=(-D DAYDREAM_OWNER_TYPING -D DAYDREAM_CHROME_TYPING)
        swiftflags=(-Xswiftc -DDAYDREAM_OWNER_TYPING -Xswiftc -DDAYDREAM_CHROME_TYPING)
    fi
    nice swift build --jobs 3 --target MemoryCore --disable-automatic-resolution --scratch-path "$SCRATCH/build-$lane" "${swiftflags[@]}" > "$SCRATCH/build-$lane.log" 2>&1
    B="$SCRATCH/build-$lane/arm64-apple-macosx/debug"
    objects=("$B/MemoryCore.build/"*.o "$B/HistoryCore.build/"*.o "$B/PrivacyPolicy.build/"*.o)
    nice swiftc -parse-as-library -module-cache-path "$SCRATCH/modcache" -I "$B/Modules" -I Sources/CSQLite "${flags[@]}" \
        scripts/messages-moment-checks.swift "${objects[@]}" -o "$SCRATCH/messages-moment-$lane" > "$SCRATCH/compile-$lane.log" 2>&1
    nice "$SCRATCH/messages-moment-$lane" > "$SCRATCH/messages-moment-$lane.log" 2>&1
    tail -1 "$SCRATCH/messages-moment-$lane.log"
done
printf 'Evidence: %s\n' "$SCRATCH"
