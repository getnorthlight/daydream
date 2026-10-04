#!/bin/bash
# Inspect extracted bytes only. Does not launch, install or alter security.
set -euo pipefail
artifact="${1:?DMG required}"
work="$(mktemp -d "${TMPDIR:-/private/tmp}/macmem-seal-check.XXXXXX")"
mkdir "$work/mount"
mounted=0
cleanup() { if [[ "$mounted" == 1 ]]; then hdiutil detach "$work/mount"; fi; }
trap cleanup EXIT
hdiutil verify "$artifact"
# Signed image (developer-id-release.py dmg): the image signature must verify too.
if codesign -dv "$artifact" >/dev/null 2>&1; then codesign --verify --strict --verbose=2 "$artifact"; fi
req=''
if [[ -n "${DAYDREAM_EXPECT_TEAM:-}" ]]; then
  req="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$DAYDREAM_EXPECT_TEAM\""
  codesign --verify --strict -R="$req" "$artifact"
fi
hdiutil attach -readonly -nobrowse -mountpoint "$work/mount" "$artifact"
mounted=1
test "$(readlink "$work/mount/Applications")" = /Applications
ditto "$work/mount/DayDream.app" "$work/DayDream.app"
if [[ "${MACMEM_PRE_SIGNING:-0}" != 1 ]]; then
  test -s "$work/DayDream.app/Contents/_CodeSignature/CodeResources"
  codesign --verify --deep --strict --verbose=4 "$work/DayDream.app"
else
  test ! -e "$work/DayDream.app/Contents/_CodeSignature/CodeResources"
  printf '%s\n' 'UNSIGNED/PENDING TRUST: no outer seal; only payload hashes inspected. Do not execute.'
fi
if [[ -n "$req" ]]; then codesign --verify --deep --strict -R="$req" "$work/DayDream.app"; fi
if [[ "${DAYDREAM_EXPECT_STAPLED:-0}" == 1 ]]; then
  xcrun stapler validate "$artifact"
  xcrun stapler validate "$work/DayDream.app"
fi
python3 "$(dirname "$0")/verify-app-companions.py" "$work/DayDream.app"
printf '%s\n' "Extracted payload: $work/DayDream.app" 'Read-only inspection; not a Gatekeeper or notarization approval. No launch performed.'
