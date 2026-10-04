#!/bin/bash
# Reviewed laptop client. Remote bytes are artifacts/data, never evaluated scripts.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
# The build machine is configured per developer. There are no defaults:
#   DAYDREAM_DEV_HOST    ssh destination of the machine running build-dev-loop.py (user@host)
#   DAYDREAM_DEV_REMOTE  absolute path of that checkout's dist/dev-loop folder
DEV_HOST="${DAYDREAM_DEV_HOST:-}"
DEV_REMOTE="${DAYDREAM_DEV_REMOTE:-}"
DEV_ID='com.getnorthlight.daydream.development'
fetch() {
  [[ -n "$DEV_HOST" && -n "$DEV_REMOTE" ]] || { echo 'Set DAYDREAM_DEV_HOST and DAYDREAM_DEV_REMOTE first.' >&2; return 1; }
  /usr/bin/scp -q -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 "$DEV_HOST:$DEV_REMOTE/$1" "$2"
}
field() { /usr/libexec/PlistBuddy -c "Print :$2" "$1"; }
digest() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
verify_seal() { /usr/bin/codesign --verify --deep --strict "$1"; }
verify_app() {
  local app="$1" hash="$2" info="$1/Contents/Info.plist"
  [[ ! -L "$app" && -d "$app" && "$(field "$info" CFBundleIdentifier)" == "$DEV_ID" && "$(field "$info" DaydreamDevelopmentTrial)" == true ]] || return 1
  [[ "$(field "$info" SUAutomaticallyUpdate)" == false && "$(field "$info" SUEnableAutomaticChecks)" == false ]] || return 1
  [[ "$(digest "$app/Contents/MacOS/MacMem")" == "$hash" ]] || return 1
  verify_seal "$app"
}
quit_dev() {
  # Native AppKit calls only, not Apple Events or force-kill. Exact identity/path.
  /usr/bin/osascript -l JavaScript -e 'ObjC.import("AppKit"); function run(a) { var apps=$.NSRunningApplication.runningApplicationsWithBundleIdentifier("com.getnorthlight.daydream.development"); for(var i=0;i<apps.count;i++){var p=apps.objectAtIndex(i);if(ObjC.unwrap(p.bundleURL.path)===a[0]){p.terminate;for(var n=0;n<50&&!p.terminated;n++)delay(0.2);if(!p.terminated)throw Error("Quit DayDream Dev and retry; no forced termination.");}}}' "$1"
}
open_dev() {
  /usr/bin/open -n --env "DAYDREAM_DEVELOPMENT_ROOT=$2" --env "MAC_MEM_HOME=$2/memory" --env "CFFIXED_USER_HOME=$2/preferences" "$1" --args --development-trial
  /usr/bin/osascript -l JavaScript -e 'ObjC.import("AppKit");function run(a){for(var n=0;n<50;n++){var apps=$.NSRunningApplication.runningApplicationsWithBundleIdentifier("com.getnorthlight.daydream.development");for(var i=0;i<apps.count;i++){if(ObjC.unwrap(apps.objectAtIndex(i).bundleURL.path)===a[0])return "Exact dev process started";}delay(0.2);}throw Error("Development app did not start. Preserve previous copy; review this exact app in macOS.");}' "$1"
}
valid_version() { [[ "$1" =~ ^[0-9]{8}-[0-9]{6}$ ]]; }
switch_pointer() {
  local base="$1" version="$2"
  printf '%s\n' "$version" > "$base/current.new"
  /bin/mv "$base/current.new" "$base/current"
}
refresh() {
  local base="$1" mode="${2:-refresh}"
  [[ "$mode" == refresh || "$mode" == --rollback ]] || { echo 'Use refresh or --rollback'; return 1; }
  if [[ -e "$base" ]]; then
    [[ -d "$base" && ! -L "$base" && "$(/bin/cat "$base/OWNED")" == daydream-dev-loop-v1 ]] || { echo 'Unowned directory; stopped.'; return 1; }
  else
    /bin/mkdir -m 700 "$base"
    printf 'daydream-dev-loop-v1\n' > "$base/OWNED"
    /bin/mkdir -m 700 "$base/versions"
  fi
  local old='' version hash app stage archive expected
  if [[ -f "$base/current" ]]; then read -r old < "$base/current"; valid_version "$old"; fi
  if [[ "$mode" == --rollback ]]; then
    read -r version < "$base/previous";valid_version "$version"
  else
    stage="$(/usr/bin/mktemp -d "$base/stage.XXXXXXXX")"
    if ! fetch latest.plist "$stage/latest.plist"; then echo "Build machine unavailable. Current dev copy unchanged. Retained stage: $stage"; return 1; fi
    version="$(field "$stage/latest.plist" version)";valid_version "$version"
    archive="Daydream-Dev-$version.zip"
    expected="$(field "$stage/latest.plist" archiveSHA256)"
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]]
    fetch "$archive" "$stage/download.zip" || { echo 'Incomplete download; current unchanged.';return 1; }
    [[ "$(digest "$stage/download.zip")" == "$expected" ]] || { echo 'Corrupt download; current unchanged.';return 1; }
    # Reject traversal before extraction. Builder emits only this exact top-level.
    /usr/bin/unzip -Z1 "$stage/download.zip" > "$stage/members"
    while IFS= read -r member; do
      [[ "$member" == 'Daydream Dev.app/'* && "$member" != *'../'* && "$member" != /* ]] || { echo 'Unexpected archive path';return 1; }
    done < "$stage/members"
    /usr/bin/ditto -x -k "$stage/download.zip" "$stage/payload"
    hash="$(field "$stage/latest.plist" executableSHA256)";[[ "$hash" =~ ^[0-9a-f]{64}$ ]]
    verify_app "$stage/payload/Daydream Dev.app" "$hash" || { echo 'Wrong/invalid development app. Current unchanged.';return 1; }
    if [[ ! -e "$base/versions/$version" ]]; then
      /bin/mv "$stage/latest.plist" "$stage/payload/receipt.plist"
      /bin/mv "$stage/payload" "$base/versions/$version"
    else
      [[ "$(field "$base/versions/$version/receipt.plist" archiveSHA256)" == "$expected" ]] || { echo 'Version collision; stopped.';return 1; }
    fi
  fi
  app="$base/versions/$version/Daydream Dev.app"
  hash="$(field "$base/versions/$version/receipt.plist" executableSHA256)"
  verify_app "$app" "$hash"
  if [[ -n "$old" ]]; then quit_dev "$base/versions/$old/Daydream Dev.app" || return 1; fi
  local data
  if [[ -f "$base/trial-root" ]]; then read -r data < "$base/trial-root";[[ "$data" == /private/tmp/daydream-development-trial-* && -d "$data" && ! -L "$data" ]];
  else
    data="$(/usr/bin/mktemp -d /private/tmp/daydream-development-trial-XXXXXXXX)"
    /bin/mkdir -m 700 "$data/memory" "$data/preferences" "$data/backups"
    printf 'synthetic-only\n' > "$data/DEVELOPMENT-ONLY"
    printf '%s\n' "$data" > "$base/trial-root"
  fi
  if [[ -n "$old" && "$old" != "$version" ]]; then printf '%s\n' "$old" > "$base/previous"; fi
  switch_pointer "$base" "$version"
  if ! open_dev "$app" "$data"; then
    if [[ -n "$old" ]]; then switch_pointer "$base" "$old"; fi
    echo "macOS did not open $app. Current pointer restored when possible. Use exact-app Open Anyway only; no security bypass."
    return 1
  fi
  echo "Daydream Dev $version opening. Synthetic data: $data"
  echo "If macOS blocks it: Privacy & Security > Open Anyway for $app only, then run this action again."
  echo 'Rollback: run this same local script with --rollback. Previous app and synthetic data are retained; schema downgrade safety is not implied.'
}
main() { refresh "$HOME/Library/Application Support/Daydream Dev Loop" "${1:-refresh}"; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
