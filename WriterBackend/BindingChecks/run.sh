#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
build=${1:-/private/tmp/macmem-writer-app-integration/arm64-apple-macosx/debug}
trial=$(mktemp -d /private/tmp/macmem-binding-check.XXXXXX)
trap 'rm -f "$trial/checks"; rmdir "$trial"' EXIT
swiftc -parse-as-library -target arm64-apple-macosx13.0 \
  -I "$build/Modules" -I Sources/CSQLite -I WriterBackend/Sources/CLlamaBridge/include \
  -Xcc -fmodule-map-file="$build/CLlamaBridge.build/module.modulemap" \
  WriterBackend/BindingChecks/main.swift adapters/CoreWriterBinding.swift \
  "$build"/WriterBackend.build/*.swift.o "$build"/CLlamaBridge.build/WriterLlama.cpp.o \
  "$build"/MemoryCore.build/*.swift.o "$build"/HistoryCore.build/*.swift.o \
  -lc++ -lsqlite3 -o "$trial/checks"
"$trial/checks"
