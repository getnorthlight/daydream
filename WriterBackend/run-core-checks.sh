#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Existing core build must include current canonical Actions/DerivedNotes APIs.
core_build="${1:-.build/arm64-apple-macosx/debug}"
test_dir="$(mktemp -d /private/tmp/writer-core-build.XXXXXX)"
trap 'rm -r "$test_dir"' EXIT
test -f "$core_build/MemoryCore.build/DerivedNotes.swift.o"
swiftc -parse-as-library -emit-library -emit-module -module-name WriterBackend \
  -target arm64-apple-macosx13.0 -module-cache-path "$test_dir/cache" \
  WriterBackend/Sources/WriterBackend/{Contract,LocalWriter,CloudWriter,CanonicalNotes,ModelView,CoreWriterAdapter}.swift \
  -emit-module-path "$test_dir/WriterBackend.swiftmodule" -o "$test_dir/libWriterBackend.dylib"
swiftc -parse-as-library WriterBackend/CoreChecks.swift \
  -target arm64-apple-macosx13.0 -module-cache-path "$test_dir/cache" \
  -I "$test_dir" -I "$core_build/Modules" -I Sources/CSQLite \
  "$core_build"/MemoryCore.build/*.swift.o "$core_build"/HistoryCore.build/*.swift.o \
  -L "$test_dir" -lWriterBackend -lsqlite3 -Xlinker -rpath -Xlinker "$test_dir" \
  -o "$test_dir/core-checks"
"$test_dir/core-checks"
swiftc -parse-as-library WriterBackend/AdapterChecks/main.swift \
  -target arm64-apple-macosx13.0 -module-cache-path "$test_dir/cache" \
  -I "$test_dir" -I "$core_build/Modules" -I Sources/CSQLite \
  "$core_build"/MemoryCore.build/*.swift.o "$core_build"/HistoryCore.build/*.swift.o \
  -L "$test_dir" -lWriterBackend -lsqlite3 -Xlinker -rpath -Xlinker "$test_dir" \
  -o "$test_dir/adapter-checks"
"$test_dir/adapter-checks"
