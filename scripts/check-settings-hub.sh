#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
objects=/private/tmp/daydream-ui-build/arm64-apple-macosx/debug
swift build --product MacMem --scratch-path /private/tmp/daydream-ui-build
swiftc -D DEVELOPMENT_SOURCE_CHECKS -parse-as-library -module-cache-path /private/tmp/daydream-ui-build/cache \
  -I "$objects/Modules" -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" \
  -Xcc -fmodule-map-file="$objects/CLlamaBridge.build/module.modulemap" \
  -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include" \
  -F "$objects" -framework Sparkle -Xlinker -rpath -Xlinker "$objects" \
  Sources/MacMemApp/*.swift scripts/settings-hub-checks.swift \
  "$objects"/{MemoryCore,MemoryUI,HistoryCore,CoreIntegration,PrivacyPolicy,BrowserBridge,WriterBackend,CLlamaBridge,BackupRestore}.build/*.o \
  -lc++ -o /private/tmp/daydream-settings-hub-checks
/private/tmp/daydream-settings-hub-checks
