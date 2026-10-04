#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

layout_build="${DAYDREAM_BUILD_DIR:-/private/tmp/daydream-ui-build/arm64-apple-macosx/debug}"
layout_output="${DAYDREAM_LAYOUT_OUTPUT_DIR:-$(mktemp -d /private/tmp/daydream-layout-checks.XXXXXX)}"
mkdir -p "$layout_output/cache"
swiftc -parse-as-library -module-cache-path "$layout_output/cache" \
  -I "$layout_build/Modules" -I Sources/CSQLite \
  scripts/main-layout-stress.swift \
  "$layout_build"/MemoryUI.build/*.swift.o \
  "$layout_build"/MemoryCore.build/*.swift.o \
  "$layout_build"/HistoryCore.build/*.swift.o \
  "$layout_build"/PrivacyPolicy.build/*.swift.o \
  -lsqlite3 -o "$layout_output/main-layout-stress"

"$layout_output/main-layout-stress" canonical actualshape bounded check-indicators
"$layout_output/main-layout-stress" canonical focus bounded check-indicators
"$layout_output/main-layout-stress" bounded check-indicators
printf 'Layout fixture executable: %s\n' "$layout_output/main-layout-stress"
