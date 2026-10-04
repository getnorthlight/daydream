#!/bin/bash
# Local integrity only. No developer identity, notarization or trust override.
set -euo pipefail
app="${1:?app path required}"
test -f "$app/Contents/Info.plist"
test -f "$app/Contents/Resources/Companions.json"
if [[ -f "$app/Contents/Resources/FunctionalTrial.json" ]]; then
  echo 'Functional trial requires root Developer ID sealing; no ad-hoc reseal.' >&2
  exit 2
fi
# Preserve Sparkle's vendor signatures. Never use --deep when signing.
codesign --verify --deep --strict "$app/Contents/Frameworks/Sparkle.framework"
codesign --verify --strict "$app/Contents/MacOS/mac-mem"
codesign --verify --strict "$app/Contents/MacOS/mac-mem-backup"
if [[ -f "$app/Contents/Resources/LocalSearchDistribution.json" ]]; then
  codesign --verify --strict "$app/Contents/Helpers/typesense-server"
  python3 -B "$(dirname "$0")/search_payload.py" verify --app "$app"
fi
# perm-1004 (tccd, 10/3): macOS keeps one privacy row per bundle ID, holding the code requirement of the copy that made
# it. An ad-hoc copy's requirement is its cdhash, so an ad-hoc build run under a real or test-copy ID leaves a row that
# the Developer ID copy later can never match (it reads off while System Settings shows it on). Every ad-hoc seal
# therefore gets its own ID: <id>.adhoc. Never the normal, Live Test or QA ID.
plist="$app/Contents/Info.plist"
bundle_id="$(plutil -extract CFBundleIdentifier raw "$plist")"
case "$bundle_id" in
  *.adhoc) ;;
  ?*) plutil -replace CFBundleIdentifier -string "$bundle_id.adhoc" "$plist"
      echo "Ad-hoc seal: bundle ID $bundle_id.adhoc (never $bundle_id, which Developer ID copies use)." ;;
  *) echo 'Refusing: no CFBundleIdentifier' >&2; exit 2 ;;
esac
# All resources and companion hashes must already be final before sealing.
codesign --force --sign - --timestamp=none "$app"
test -s "$app/Contents/_CodeSignature/CodeResources"
codesign --verify --deep --strict --verbose=4 "$app"
