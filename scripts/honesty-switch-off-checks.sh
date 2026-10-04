#!/bin/bash
# Builds DayDream with Chrome page history switched off (ReleaseFeatures.chromePageHistory = false)
# and proves no Apple Event path runs: scripts/honesty-switch-off-checks.swift, compiled with the
# app's capture sources (EventCapture, Coordinator, ChromePageRecorder, ChromeEventSender, ...).
#
#   bash scripts/honesty-switch-off-checks.sh <scratch-dir> [<switch-on debug build dir>]
#
# <scratch-dir> gets a copy of this tree (Vendor is linked, not copied) with the one switch line
# flipped, its build, and the harness. The tree itself is never changed. With a second argument
# (an existing normal debug build, e.g. .build/arm64-apple-macosx/debug) the same harness also runs
# against the switch-on build as a control, so the zero counts in the switch-off run mean something.
# Nothing is launched, installed, signed or asked of macOS; the harness uses a fake Chrome environment.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
S=${1:?usage: honesty-switch-off-checks.sh <scratch-dir> [<switch-on debug build dir>]}
ON=${2:-}
mkdir -p "$S"; S=$(cd "$S" && pwd)
SRC=$S/src; BUILD=$S/build; F=Sources/MemoryCore/ReleaseFeatures.swift
LINE='    public static let chromePageHistory = true'
OFF='    public static let chromePageHistory = false'

[ "$(grep -cxF "$LINE" "$ROOT/$F")" = 1 ] || { echo "FAIL: $F must hold the line '$LINE' exactly once"; exit 1; }
mkdir -p "$SRC"
rsync -a --delete --exclude .build --exclude .git --exclude /Vendor --exclude "/$F" "$ROOT/" "$SRC/"
ln -sfn "$ROOT/Vendor" "$SRC/Vendor"
# Rewrite the switch file only when it changed, so repeat runs build incrementally.
sed "s/^$LINE\$/$OFF/" "$ROOT/$F" > "$S/ReleaseFeatures.swift.new"
cmp -s "$S/ReleaseFeatures.swift.new" "$SRC/$F" 2>/dev/null || cp "$S/ReleaseFeatures.swift.new" "$SRC/$F"
[ "$(grep -cxF "$OFF" "$SRC/$F")" = 1 ] && [ "$(grep -c 'chromePageHistory = true' "$SRC/$F")" = 0 ] \
  || { echo "FAIL: the copy's switch is not off"; exit 1; }
diff -q <(grep -v 'chromePageHistory = ' "$ROOT/$F") <(grep -v 'chromePageHistory = ' "$SRC/$F") >/dev/null \
  || { echo "FAIL: the copy differs from the tree in more than the switch line"; exit 1; }
echo "PASS: the copy differs from the tree only in the switch line (chromePageHistory = false)"

cd "$SRC"
swift build --scratch-path "$BUILD" --disable-automatic-resolution --product MacMem
echo "PASS: the whole app (MacMem) builds with Chrome page history off"

CAPTURE=$(python3 -c "import re;s=open('scripts/daydream-core-source-checks.py').read();print(' '.join('Sources/MacMemApp/%s.swift'%n for n in eval(re.search(r'capture=(\[[^\]]*\])',s).group(1))))")
DEPS=(MemoryCore HistoryCore CoreIntegration WriterBackend PrivacyPolicy BrowserBridge CLlamaBridge MemoryUI)
harness() { # <debug build dir> <sources root> <output>
  local b=$1 root=$2 out=$3 objs=()
  for t in "${DEPS[@]}"; do objs+=("$b/$t.build/"*.o); done
  local files=(); for f in $CAPTURE; do files+=("$root/$f"); done
  swiftc -parse-as-library -module-cache-path "$S/modcache" -I "$b/Modules" -I "$root/Sources/CSQLite" \
    -Xcc -fmodule-map-file="$b/CLlamaBridge.build/module.modulemap" \
    "${files[@]}" "$root/scripts/honesty-switch-off-checks.swift" "${objs[@]}" -lc++ -o "$out"
}
OFFB=$BUILD/arm64-apple-macosx/debug
harness "$OFFB" "$SRC" "$S/switch-off-checks"
nm "$S/switch-off-checks" > "$S/switch-off-checks.nm"
grep -q ChromeEventSender "$S/switch-off-checks.nm" || { echo "FAIL: the harness does not contain ChromeEventSender"; exit 1; }
echo "PASS: the harness links the real ChromeEventSender"
"$S/switch-off-checks" --expect-off
if [ -n "$ON" ]; then
  harness "$ON" "$ROOT" "$S/switch-on-control"
  "$S/switch-on-control"
fi
echo "PASS: honesty-switch-off: Chrome page history off leaves no Apple Event path"
