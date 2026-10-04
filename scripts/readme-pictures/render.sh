#!/bin/bash
# Renders the README pictures into docs/images/readme (or the folder you name), in light and dark, from the app's own
# SwiftUI views over a made-up day. It never reads your DayDream history, Keychain or the network.
#
#   scripts/readme-pictures/render.sh [output folder]
#
# SWIFT_BUILD_FLAGS adds flags to `swift build` (for example --scratch-path). Builds with the release typing flags, so
# the pictures show what a release shows.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-$ROOT/docs/images/readme}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$ROOT"
FLAGS=(-Xswiftc -DDAYDREAM_OWNER_TYPING -Xswiftc -DDAYDREAM_CHROME_TYPING ${SWIFT_BUILD_FLAGS:-})
swift build "${FLAGS[@]}"
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)"
OBJS=()
for target in MemoryCore MemoryUI HistoryCore CoreIntegration PrivacyPolicy BrowserBridge WriterBackend CLlamaBridge BackupRestore; do
  OBJS+=("$BIN/$target.build/"*.o)
done
swiftc -D DEVELOPMENT_SOURCE_CHECKS -D DAYDREAM_OWNER_TYPING -D DAYDREAM_CHROME_TYPING -parse-as-library -I "$BIN/Modules" \
  -Xcc -fmodule-map-file="$ROOT/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$BIN/CLlamaBridge.build/module.modulemap" \
  -Xcc -I -Xcc "$ROOT/WriterBackend/Sources/CLlamaBridge/include" \
  "$ROOT"/scripts/readme-pictures/*.swift "${OBJS[@]}" -lc++ -lsqlite3 -o "$WORK/readme-render"
# The app's site icons (YouTube, Hacker News) come from MemoryUI's resource bundle, found next to the binary.
cp -R "$BIN/MacMem_MemoryUI.bundle" "$WORK/"
mkdir -p "$OUT" "$WORK/home" "$WORK/tmp"
for picture in today day moment search recent ai settings setup menu; do
  for mode in light dark; do
    env HOME="$WORK/home" CFFIXED_USER_HOME="$WORK/home" TMPDIR="$WORK/tmp/" README_ROOT="$ROOT" \
      "$WORK/readme-render" "$OUT" "$picture" "$mode" | grep '^PNG'
  done
done
