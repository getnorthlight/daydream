#!/bin/bash
# "DayDream Preview.app": the memory-levels UI over a made-up week, recording off (PreviewSample, PreviewLaunch).
# The local package path (scripts/package.sh) with a different bundle id and name, and the Info.plist key
# DaydreamPreviewSample=true, so this app always opens the sample and never a real history:
#   swift build (release, owner typing flags as the release has them), stage, the companion manifest
#   (release.py manifest: local hashes only, no key, no network), the local ad-hoc seal (seal-local-app.sh:
#   `codesign --sign -`), verify-app-companions.
# No Developer ID signing, notarization, DMG, appcast or download. Nothing is launched or installed.
# Output: $PREVIEW_OUT (default .build/preview)/<N>/DayDream Preview.app,
# where N is the next build number (1, 2, 3...; PREVIEW_BUILD sets it). The bundle says "DayDream Preview N"
# (CFBundleDisplayName, and CFBundleVersion N). Earlier builds stay in their own folders; nothing is deleted.
set -euo pipefail
cd "$(dirname "$0")/../.."
project="$PWD"
out="${PREVIEW_OUT:-$PWD/.build/preview}"
mkdir -p "$out/tmp" "$out/modcache"
last=$(find "$out" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' -exec basename {} \; | sort -n | tail -1)
build=${PREVIEW_BUILD:-$(( ${last:-0} + 1 ))}
[[ "$build" =~ ^[0-9]+$ ]] || { echo "PREVIEW_BUILD must be a number" >&2; exit 2; }
dest="$out/$build"
[ -e "$dest" ] && { echo "Refusing: $dest exists (builds are never overwritten)" >&2; exit 2; }
export TMPDIR="$out/tmp/" CLANG_MODULE_CACHE_PATH="$out/modcache" SWIFT_MODULECACHE_PATH="$out/modcache" PYTHONDONTWRITEBYTECODE=1
# The pinned Sparkle copy in Vendor/ (checked offline; never downloaded here).
python3 scripts/bootstrap-sparkle.py --offline
flags=(-Xswiftc -DDAYDREAM_OWNER_TYPING -Xswiftc -DDAYDREAM_CHROME_TYPING)
build_root="$out/scratch-release"
for product in MacMem mac-mem mac-mem-backup; do
  swift build --package-path "$project" --scratch-path "$build_root" -c release --disable-automatic-resolution --product "$product" "${flags[@]}"
done
bin="$(swift build --package-path "$project" --scratch-path "$build_root" -c release --show-bin-path "${flags[@]}")"
stage="$(mktemp -d "$out/stage.XXXXXX")"
app="$stage/DayDream Preview.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
install -m 755 "$bin/MacMem" "$app/Contents/MacOS/MacMem"
install -m 755 "$bin/mac-mem" "$app/Contents/MacOS/mac-mem"
install -m 755 "$bin/mac-mem-backup" "$app/Contents/MacOS/mac-mem-backup"
install -m 644 packaging/Info.plist "$app/Contents/Info.plist"
ditto "$bin/MacMem_MemoryUI.bundle" "$app/Contents/Resources/MacMem_MemoryUI.bundle"
plist="$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string com.getnorthlight.daydream.preview "$plist"
plutil -replace CFBundleName -string "DayDream Preview" "$plist"
plutil -replace CFBundleDisplayName -string "DayDream Preview $build" "$plist"
plutil -replace CFBundleVersion -string "$build" "$plist"
plutil -insert DaydreamPreviewSample -bool true "$plist"
ditto Vendor/Sparkle-2.9.6/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$app/Contents/Frameworks/Sparkle.framework"
install -m 644 Vendor/Sparkle-2.9.6/LICENSE "$app/Contents/Resources/Sparkle-LICENSE.txt"
install -m 644 packaging/Daydream.icns "$app/Contents/Resources/Daydream.icns"
install -m 644 LICENSE "$app/Contents/Resources/LICENSE.txt"
install -m 644 NOTICE "$app/Contents/Resources/NOTICE.txt"
install -m 644 THIRD-PARTY-NOTICES.md "$app/Contents/Resources/THIRD-PARTY-NOTICES.md"
install -m 644 WriterBackend/Notices/llama-MIT.txt WriterBackend/Notices/Qwen-APACHE-2.0.txt "$app/Contents/Resources/"
install -m 644 adapters/before_turn.py "$app/Contents/Resources/before_turn.py"
install -m 644 adapters/launcher.example.json "$app/Contents/Resources/"
python3 scripts/release.py manifest --app "$app"
bash scripts/seal-local-app.sh "$app"
python3 scripts/verify-app-companions.py "$app"
test "$(plutil -extract CFBundleIdentifier raw "$plist")" = com.getnorthlight.daydream.preview.adhoc   # perm-1004: ad-hoc ID
test "$(plutil -extract DaydreamPreviewSample raw "$plist")" = true
mkdir -p "$dest"
mv "$app" "$dest/DayDream Preview.app"
rmdir "$stage"
codesign --verify --deep --strict "$dest/DayDream Preview.app"
printf '%s\n' "Built: $dest/DayDream Preview.app (DayDream Preview $build; ad-hoc sealed, not launched, not installed)"
