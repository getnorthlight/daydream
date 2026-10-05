#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
project="$PWD"
if [[ "${1:-}" == functional ]]; then
  shift
  exec python3 -B scripts/stage_functional.py "$@"
fi
format="${1:-dmg}"
if [[ "$format" != pkg && "$format" != dmg ]]; then exit 2; fi
artifact_name="${2:-Daydream-GUI-Trial-unsigned.dmg}"
if [[ ! "$artifact_name" =~ ^Daydream-[A-Za-z0-9.-]+\.dmg$ ]]; then echo 'Invalid GUI artifact basename' >&2; exit 2; fi
gui_artifact="$project/dist/$artifact_name"
if [[ "$format" == dmg && -e "$gui_artifact" ]]; then
  printf '%s\n' 'GUI artifact exists. Preserve it explicitly before rebuilding.' >&2
  exit 2
fi
if [[ "$format" == pkg && ( -e "$project/dist/Daydream-guided-local-unsigned.pkg" || -e "$project/dist/Daydream-local-unsigned.zip" ) ]]; then
  echo 'Refusing to overwrite existing package/ZIP artifacts' >&2
  exit 2
fi
# Local unsigned packages. DAYDREAM_OWNER_TYPING=1 compiles in expanded typing
# and website typing (SPEC-LATER section 3) and marks the app as the owner's
# copy. The signed release (developer-id-release.py stage) always compiles both
# in (the owner's decision of 2026-09-25); without the switch a local package
# types in Notes and TextEdit only.
swift_flags=()
owner_plist_key=''
build_suffix=''
if [[ "${DAYDREAM_OWNER_TYPING:-}" == 1 ]]; then
  swift_flags=(-Xswiftc -DDAYDREAM_OWNER_TYPING -Xswiftc -DDAYDREAM_CHROME_TYPING)
  owner_plist_key=MacMemOwnerTyping
  build_suffix=-owner
  printf '%s\n' 'OWNER BUILD: expanded typing and website typing ON'
fi
# Local copies include the reviewed, self-contained Typesense runtime. No service install or download.
python3 -B -c 'import sys;sys.path.insert(0,"scripts");import search_payload;search_payload.source_files(".",sys.argv[1])' "${DAYDREAM_TYPESENSE_INPUTS:-$project/Vendor/Typesense-30.2}"
python3 scripts/bootstrap-sparkle.py
build_root="${MACMEM_BUILD_ROOT:-$project/.build$build_suffix}"
swift build --package-path "$project" --scratch-path "$build_root" -c release --product MacMem ${swift_flags[@]+"${swift_flags[@]}"}
swift build --package-path "$project" --scratch-path "$build_root" -c release --product mac-mem ${swift_flags[@]+"${swift_flags[@]}"}
swift build --package-path "$project" --scratch-path "$build_root" -c release --product mac-mem-backup ${swift_flags[@]+"${swift_flags[@]}"}
release_bin="$(swift build --package-path "$project" --scratch-path "$build_root" -c release --show-bin-path ${swift_flags[@]+"${swift_flags[@]}"})"
# Unique staging keeps earlier artifacts recoverable. No installer is executed.
stage="$(mktemp -d "$project/.build/package.XXXXXX")"
app="$stage/root/DayDream.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$project/dist"
install -m 755 "$release_bin/MacMem" "$app/Contents/MacOS/MacMem"
install -m 755 "$release_bin/mac-mem" "$app/Contents/MacOS/mac-mem"
install -m 755 "$release_bin/mac-mem-backup" "$app/Contents/MacOS/mac-mem-backup"
install -m 644 packaging/Info.plist "$app/Contents/Info.plist"
# DayDream needs macOS 15 (owner decision for 0.1.5, as the website says); the pinned arm64 search runtime needs 13.1.
plutil -replace LSMinimumSystemVersion -string 15.0 "$app/Contents/Info.plist"
ditto "$release_bin/MacMem_MemoryUI.bundle" "$app/Contents/Resources/MacMem_MemoryUI.bundle"
if [[ -n "$owner_plist_key" ]]; then plutil -insert "$owner_plist_key" -bool true "$app/Contents/Info.plist"; fi
mkdir -p "$app/Contents/Frameworks"
ditto Vendor/Sparkle-2.9.6/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$app/Contents/Frameworks/Sparkle.framework"
install -m 644 Vendor/Sparkle-2.9.6/LICENSE "$app/Contents/Resources/Sparkle-LICENSE.txt"
test -f packaging/Daydream.icns
install -m 644 packaging/Daydream.icns "$app/Contents/Resources/Daydream.icns"
# License and third-party notices. Every source path here is tracked in the repo.
install -m 644 LICENSE "$app/Contents/Resources/LICENSE.txt"
install -m 644 NOTICE "$app/Contents/Resources/NOTICE.txt"
install -m 644 THIRD-PARTY-NOTICES.md "$app/Contents/Resources/THIRD-PARTY-NOTICES.md"
install -m 644 WriterBackend/Notices/llama-MIT.txt WriterBackend/Notices/Qwen-APACHE-2.0.txt "$app/Contents/Resources/"
install -m 644 adapters/before_turn.py "$app/Contents/Resources/before_turn.py"
install -m 644 adapters/launcher.example.json "$app/Contents/Resources/"
python3 -B scripts/search_payload.py assemble --app "$app" --source "$project" --inputs "${DAYDREAM_TYPESENSE_INPUTS:-$project/Vendor/Typesense-30.2}"
python3 scripts/release.py manifest --app "$app"
# claude/crashguard-015: macOS 15.0 (Info.plist, Package.swift) and arm64-only binaries built for 15.0.
python3 scripts/release.py platform --app "$app"
if [[ "${MACMEM_PRE_SIGNING:-0}" == 1 ]]; then
  printf '%s\n' 'UNSIGNED/PENDING TRUST: outer seal intentionally absent; signing owner must seal final bytes.'
else
  bash scripts/seal-local-app.sh "$app"
fi
python3 scripts/verify-app-companions.py "$app"
if [[ "$format" == dmg ]]; then
  # Finder shortcut inside the image only. No system installation or launch.
  ln -s /Applications "$stage/root/Applications"
  hdiutil create -srcfolder "$stage/root" -volname 'DayDream' -format UDZO "$gui_artifact"
  hdiutil verify "$gui_artifact"
  bash scripts/verify-dmg-seal.sh "$gui_artifact"
  printf '%s\n' "GUI trial: $gui_artifact" 'Unsigned; not installed. Existing package/ZIP preserved.'
  exit 0
fi
pkgbuild --analyze --root "$stage/root" "$stage/components.plist"
python3 scripts/fix_package_components.py "$stage/components.plist"
pkgbuild --root "$stage/root" --component-plist "$stage/components.plist" --identifier local.macmem.acceptance --version 0.1.0 --install-location /Applications "$stage/MacMem-component.pkg"
productbuild --distribution packaging/Distribution.xml --resources packaging --package-path "$stage" "$project/dist/Daydream-guided-local-unsigned.pkg"
ditto -c -k --keepParent "$app" "$project/dist/Daydream-local-unsigned.zip"
printf '%s\n' 'Created local unsigned package and ZIP. Not installed or notarized; sign and notarize before distributing.'
