#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
objects=/private/tmp/daydream-ui-build/arm64-apple-macosx/debug
if [[ "${1:-}" != "--connections-only" ]]; then
swiftc -D DEVELOPMENT_SOURCE_CHECKS -D DAYDREAM_OWNER_TYPING -D DAYDREAM_CHROME_TYPING -D DAYDREAM_QA_HARNESS -parse-as-library -module-cache-path /private/tmp/daydream-ui-build/cache \
  -I "$objects/Modules" -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" \
  -Xcc -fmodule-map-file="$objects/CLlamaBridge.build/module.modulemap" \
  -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include" \
  -F "$objects" -framework Sparkle -Xlinker -rpath -Xlinker "$objects" \
  Sources/MacMemApp/*.swift scripts/ui-review-render.swift \
  "$objects"/{MemoryCore,MemoryUI,HistoryCore,CoreIntegration,PrivacyPolicy,BrowserBridge,WriterBackend,CLlamaBridge,BackupRestore}.build/*.o \
  -lc++ -o /private/tmp/daydream-ui-render
/private/tmp/daydream-ui-render /private/tmp/daydream-ui-renders
fi
# Settings > Connections and Help > Report a Problem, with the app sources and a fake command-line tool.
mkdir -p /private/tmp/daydream-ui-connection-renders
swiftc -D DEVELOPMENT_SOURCE_CHECKS -D DAYDREAM_OWNER_TYPING -D DAYDREAM_CHROME_TYPING -D DAYDREAM_QA_HARNESS -parse-as-library -module-cache-path /private/tmp/daydream-ui-build/cache \
  -I "$objects/Modules" -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" \
  -Xcc -fmodule-map-file="$objects/CLlamaBridge.build/module.modulemap" \
  -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include" \
  -F "$objects" -framework Sparkle -Xlinker -rpath -Xlinker "$objects" \
  Sources/MacMemApp/*.swift scripts/connection-review-checks.swift \
  "$objects"/{MemoryCore,MemoryUI,HistoryCore,CoreIntegration,PrivacyPolicy,BrowserBridge,WriterBackend,CLlamaBridge,BackupRestore}.build/*.o \
  -lc++ -o /private/tmp/daydream-ui-connection-checks
DD_CHECK_OUT=/private/tmp/daydream-ui-connection-renders /private/tmp/daydream-ui-connection-checks
