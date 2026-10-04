#!/bin/sh
# Source regression only. No app/browser launch, grants, default store or install.
set -eu
browser_fixture_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
browser_fixture_build=$(mktemp -d /private/tmp/browser-core-checks.XXXXXX)
cd "$browser_fixture_root"
export CLANG_MODULE_CACHE_PATH="$browser_fixture_build/modules"
export SWIFT_MODULECACHE_PATH="$browser_fixture_build/modules"
swift build --scratch-path "$browser_fixture_build/build" --target CoreIntegration
browser_fixture_bin=$(swift build --scratch-path "$browser_fixture_build/build" --show-bin-path)
swiftc -module-cache-path "$browser_fixture_build/modules" -I "$browser_fixture_bin/Modules" -I Sources/CSQLite \
  BrowserBridge/fixtures/core-ingestion-checks.swift adapters/CoreCaptureBinding.swift \
  "$browser_fixture_bin"/MemoryCore.build/*.swift.o "$browser_fixture_bin"/HistoryCore.build/*.swift.o \
  "$browser_fixture_bin"/PrivacyPolicy.build/*.swift.o "$browser_fixture_bin"/BrowserBridge.build/*.swift.o \
  -o "$browser_fixture_build/core-checks"
"$browser_fixture_build/core-checks"
node --test BrowserBridge/fixtures/key-store-checks.mjs
printf 'Fixture outputs: %s\n' "$browser_fixture_build"
