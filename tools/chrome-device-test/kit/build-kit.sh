#!/bin/bash
# Builds the MacBook kit for the Chrome device test. Developer Mac only
# (needs the Command Line Tools). Never part of the app build: it lives here,
# not in scripts/ (scripts/check_browser_boundary.py).
#
#   tools/chrome-device-test/kit/build-kit.sh --work DIR [--identity SHA1]
#
# 1. swift build -c release (arm64) with --scratch-path DIR/build, TMPDIR=DIR/tmp
# 2. selftest, check_harness_source.py, bash -n run.sh
# 3. assembles DIR/kit/DayDream Chrome Test/: run.sh, READ ME FIRST.txt,
#    bin/chrome-device-test, bin/chrome-device-test-serve, testpage/
# 4. signs. With --identity: Developer ID, hardened runtime, secure timestamp;
#    chrome-device-test gets kit/entitlements.plist (Apple Events only), the
#    server gets no entitlements. Without it: ad hoc with the same hardened
#    runtime and entitlements, for local testing only.
# 5. DIR/DayDream-Chrome-Test.dmg (UDZO, volume "DayDream Chrome Test"),
#    signed with --identity, verified by mounting it read-only under DIR.
# It never notarizes or staples; it prints those commands instead.

[ -n "${BASH_VERSION:-}" ] || exec /bin/bash "$0" "$@"
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HARNESS_DIR="$(cd "$HERE/.." && pwd -P)"
VOLNAME="DayDream Chrome Test"
DMG_NAME="DayDream-Chrome-Test.dmg"
WORK=""
IDENTITY=""

usage() {
  sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
}
die() { printf 'build-kit: %s\n' "$*" >&2; exit 1; }
section() { printf '\n== %s ==\n' "$1"; }

while [ $# -gt 0 ]; do
  case "$1" in
    (--work) [ $# -ge 2 ] || die "--work needs a folder"; WORK="$2"; shift ;;
    (--identity) [ $# -ge 2 ] || die "--identity needs a SHA-1"; IDENTITY="$2"; shift ;;
    (--help|-h) usage; exit 0 ;;
    (*) usage; die "unknown argument $1" ;;
  esac
  shift
done
[ -n "$WORK" ] || { usage; die "--work DIR is required"; }
if [ -n "$IDENTITY" ]; then
  case "$IDENTITY" in
    (*[!0-9A-Fa-f]*) die "--identity must be the 40-character SHA-1 of a Developer ID Application certificate" ;;
  esac
  [ ${#IDENTITY} -eq 40 ] || die "--identity must be the 40-character SHA-1 of a Developer ID Application certificate"
fi
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd -P)"
case "$WORK" in
  ("$HARNESS_DIR"|"$HARNESS_DIR"/*) die "--work must be outside the source tree" ;;
esac
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"

section "Build (release, arm64)"
swift build -c release --package-path "$HARNESS_DIR" --scratch-path "$WORK/build"
BIN_DIR="$(swift build -c release --package-path "$HARNESS_DIR" --scratch-path "$WORK/build" --show-bin-path)"
for p in chrome-device-test chrome-device-test-serve chrome-device-test-selftest; do
  [ -x "$BIN_DIR/$p" ] || die "missing $BIN_DIR/$p"
done
for p in chrome-device-test chrome-device-test-serve; do
  archs="$(lipo -archs "$BIN_DIR/$p")"
  case " $archs " in (*" arm64 "*) ;; (*) die "$p is not arm64 ($archs)" ;; esac
  # Only the OS's own libraries: nothing has to be installed on the MacBook.
  if otool -L "$BIN_DIR/$p" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/Library/)' >/dev/null; then
    otool -L "$BIN_DIR/$p"
    die "$p links a library outside /usr/lib and /System/Library"
  fi
  printf '%s: %s, links system libraries only\n' "$p" "$archs"
done

section "Checks"
"$BIN_DIR/chrome-device-test-selftest"
python3 -B "$HARNESS_DIR/check_harness_source.py"
/bin/bash -n "$HERE/run.sh"
printf 'bash -n run.sh: OK\n'

section "Assemble"
STAGE="$WORK/kit/$VOLNAME"
rm -rf "$WORK/kit"
mkdir -p "$STAGE/bin" "$STAGE/testpage"
cp "$HERE/run.sh" "$STAGE/run.sh"
cp "$HERE/READ ME FIRST.txt" "$STAGE/READ ME FIRST.txt"
cp "$BIN_DIR/chrome-device-test" "$STAGE/bin/chrome-device-test"
cp "$BIN_DIR/chrome-device-test-serve" "$STAGE/bin/chrome-device-test-serve"
for f in index.html frame.html; do
  cp "$HARNESS_DIR/testpage/$f" "$STAGE/testpage/$f"
  cmp -s "$HARNESS_DIR/testpage/$f" "$STAGE/testpage/$f" || die "testpage/$f differs from the repo copy"
done
chmod 755 "$STAGE/run.sh" "$STAGE/bin/chrome-device-test" "$STAGE/bin/chrome-device-test-serve"
chmod 644 "$STAGE/READ ME FIRST.txt" "$STAGE/testpage/index.html" "$STAGE/testpage/frame.html"
xattr -cr "$STAGE"
(cd "$STAGE" && find . -type f | sort)

section "Sign"
if [ -n "$IDENTITY" ]; then
  SIGN="$IDENTITY"
  STAMP="--timestamp"
  printf 'Developer ID identity %s, hardened runtime, secure timestamp\n' "$IDENTITY"
else
  SIGN="-"
  STAMP="--timestamp=none"
  printf 'No --identity: ad hoc signature (local testing only; the MacBook needs the Developer ID build)\n'
fi
codesign --force --options runtime "$STAMP" --identifier com.macmem.chrome-device-test \
  --entitlements "$HERE/entitlements.plist" --sign "$SIGN" "$STAGE/bin/chrome-device-test"
codesign --force --options runtime "$STAMP" --identifier com.macmem.chrome-device-test-serve \
  --sign "$SIGN" "$STAGE/bin/chrome-device-test-serve"
for p in chrome-device-test chrome-device-test-serve; do
  codesign --verify --strict --verbose=2 "$STAGE/bin/$p"
  codesign -dv "$STAGE/bin/$p" 2>&1 | grep -E '^(Identifier|Format|CodeDirectory|Authority|TeamIdentifier|Timestamp|Runtime)' || true
done
ents="$(codesign -d --entitlements - --xml "$STAGE/bin/chrome-device-test" 2>/dev/null)"
case "$ents" in (*com.apple.security.automation.apple-events*) ;; (*) die "chrome-device-test lacks the Apple Events entitlement" ;; esac
if [ "$(printf '%s' "$ents" | grep -o '<key>' | wc -l | tr -d ' ')" != 1 ]; then die "chrome-device-test has entitlements other than Apple Events"; fi
if codesign -d --entitlements - --xml "$STAGE/bin/chrome-device-test-serve" 2>/dev/null | grep -q '<key>'; then
  die "chrome-device-test-serve must have no entitlements"
fi
printf 'entitlements: chrome-device-test = Apple Events only; chrome-device-test-serve = none\n'

section "Disk image"
DMG="$WORK/$DMG_NAME"
rm -f "$DMG"
hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
if [ -n "$IDENTITY" ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  codesign --verify --verbose=2 "$DMG"
fi
hdiutil verify -quiet "$DMG"
MNT="$WORK/mnt"
mkdir -p "$MNT"
detach() { hdiutil detach -quiet "$MNT" 2>/dev/null || hdiutil detach -quiet -force "$MNT" 2>/dev/null || true; }
trap detach EXIT
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$MNT" "$DMG"
diff -r -x '.fseventsd' -x '.Trashes' -x '.DS_Store' "$STAGE" "$MNT"
[ -x "$MNT/bin/chrome-device-test" ] && [ -x "$MNT/bin/chrome-device-test-serve" ] || die "binaries lost their execute bit in the image"
detach
trap - EXIT
rmdir "$MNT"
printf 'The image mounts read-only and matches the kit folder exactly.\n'
printf '%s\n' "$DMG"
shasum -a 256 "$DMG"

section "Next (not done by this script)"
if [ -n "$IDENTITY" ]; then
  printf 'Notarize and staple, then check (the owner opens the DMG by double-clicking it):\n'
  printf '  xcrun notarytool submit %q --keychain-profile daydream-notary --wait\n' "$DMG"
  printf '  xcrun stapler staple %q\n' "$DMG"
  printf '  xcrun stapler validate %q\n' "$DMG"
  printf '  spctl -a -t open --context context:primary-signature -vv %q   # expect: source=Notarized Developer ID\n' "$DMG"
else
  printf 'This image is ad hoc signed and will be blocked on another Mac. For the MacBook, rebuild with\n'
  printf '  --identity <SHA-1 of the Developer ID Application certificate>\n'
  printf 'then notarize and staple it (xcrun notarytool submit ... --wait; xcrun stapler staple ...).\n'
fi
