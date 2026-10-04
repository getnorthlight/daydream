#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
build=${1:-/private/tmp/macmem-writer-app-integration/arm64-apple-macosx/debug}
trial=$(mktemp -d /private/tmp/macmem-batch-check.XXXXXX)
trap 'rm -f "$trial/checks"; rmdir "$trial"' EXIT
swiftc -parse-as-library -target arm64-apple-macosx13.0 \
  -I "$build/Modules" -I WriterBackend/Sources/CLlamaBridge/include \
  -Xcc -fmodule-map-file="$build/CLlamaBridge.build/module.modulemap" \
  WriterBackend/BatchChecks/main.swift \
  "$build"/WriterBackend.build/*.swift.o "$build"/CLlamaBridge.build/WriterLlama.cpp.o \
  -lc++ -o "$trial/checks"
"$trial/checks"
