#!/bin/sh
# run.sh [manifest.json signed-dir]
# WRITER_BUILD: the WriterBackend debug build folder (swift build --scratch-path <X> gives <X>/arm64-apple-macosx/debug).
# TMPDIR: where the check binary is built (default /private/tmp).
set -eu
cd "$(dirname "$0")/../.."
build=${WRITER_BUILD:-/private/tmp/macmem-writer-build/arm64-apple-macosx/debug}
trial=$(mktemp -d "${TMPDIR:-/private/tmp}/writer-signature-policy.XXXXXX")
trap 'rm -f "$trial/checks"; rmdir "$trial"' EXIT
swiftc -parse-as-library -I WriterBackend/Sources/CLlamaBridge/include \
  -Xcc -fmodule-map-file="$build/CLlamaBridge.build/module.modulemap" \
  WriterBackend/Sources/WriterBackend/*.swift WriterBackend/SignedRuntimeChecks/main.swift \
  "$build/CLlamaBridge.build/WriterLlama.cpp.o" \
  -lc++ -o "$trial/checks"
"$trial/checks" "$@"
