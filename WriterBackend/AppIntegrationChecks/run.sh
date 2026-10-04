#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
build=${1:-/private/tmp/macmem-writer-app-integration/arm64-apple-macosx/debug}
trial=$(mktemp -d "${TMPDIR:-/private/tmp}/macmem-writer-app-check.XXXXXX")
trap 'rm -f "$trial/checks"; rmdir "$trial"' EXIT
swiftc -parse-as-library -target arm64-apple-macosx13.0 \
  -I "$build/Modules" -I Sources/CSQLite -I WriterBackend/Sources/CLlamaBridge/include \
  -Xcc -fmodule-map-file="$build/CLlamaBridge.build/module.modulemap" \
  Sources/MacMemApp/WriterIntegration.swift Sources/MacMemApp/WriterScheduling.swift \
  "${2:-WriterBackend/AppIntegrationChecks/main.swift}" \
  "$build"/WriterBackend.build/*.swift.o "$build"/CLlamaBridge.build/WriterLlama.cpp.o \
  "$build"/MemoryCore.build/*.swift.o "$build"/HistoryCore.build/*.swift.o \
  "$build"/MemoryUI.build/*.swift.o "$build"/CoreIntegration.build/*.swift.o \
  "$build"/PrivacyPolicy.build/*.swift.o "$build"/BrowserBridge.build/*.swift.o \
  -lsqlite3 -lc++ -o "$trial/checks"
shift $(( $# > 0 ? 1 : 0 ))
shift $(( $# > 0 ? 1 : 0 ))
"$trial/checks" "$@"
