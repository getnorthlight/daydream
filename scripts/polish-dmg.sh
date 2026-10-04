#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_name="${1:-Daydream-GUI-Trial-unsigned.dmg}"
result_name="${2:-Daydream-GUI-Trial-layout-unsigned.dmg}"
for name in "$source_name" "$result_name"; do
  if [[ ! "$name" =~ ^Daydream-[A-Za-z0-9.-]+\.dmg$ ]]; then echo 'Invalid GUI artifact basename' >&2; exit 2; fi
done
source_image="$PWD/dist/$source_name"
result_image="$PWD/dist/$result_name"
test -f "$source_image"
# Rebuilding an image drops its signature and notarization ticket. Signed release images
# are laid out before signing by scripts/developer-id-release.py dmg.
if codesign -dv "$source_image" >/dev/null 2>&1; then
  echo 'Refusing to polish a signed or notarized image; use developer-id-release.py dmg' >&2; exit 2
fi
if test -e "$result_image"; then echo 'Refusing to overwrite existing presentation artifact' >&2; exit 2; fi
stage="$(mktemp -d "$PWD/.build/dmg-layout.XXXXXX")"
mkdir "$stage/mount"
hdiutil convert "$source_image" -format UDRW -o "$stage/writable.dmg"
hdiutil attach "$stage/writable.dmg" -nobrowse -mountpoint "$stage/mount"
trap 'hdiutil detach "$stage/mount" >/dev/null 2>&1 || true' EXIT
swift scripts/dmg-background.swift "$stage/mount" "$stage/background.alias"
python3 scripts/dmg-layout.py "$stage/mount" "$stage/background.alias"
hdiutil detach "$stage/mount"
trap - EXIT
hdiutil convert "$stage/writable.dmg" -format UDZO -o "$result_image"
hdiutil verify "$result_image"
bash scripts/verify-dmg-seal.sh "$result_image"
shasum -a 256 "$source_image" "$result_image"
