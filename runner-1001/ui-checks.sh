#!/bin/bash
# UI checks. Sourced by run-checks.sh (uses its step/OUT/B/I/WT); it refuses to run on its own.
# (The on-screen steps are in SKIP, so the headless runner logs them as SKIPPED-UI.)
# APP recipe: Sources/MacMemApp/*.swift + the check + the built objects (with Sparkle).
# UI recipe: the same without Sources/MacMemApp/*.swift and without Sparkle.
# Never runs scripts/check-settings-hub.sh (it writes /private/tmp/daydream-ui-build). Every
# /private/tmp/daydream- literal in the compiled copies (checks and MacMemApp sources) is rewritten
# to the short temp root $R, so nothing is created under /private/tmp/daydream-*.
# The checks run with HOME and CFFIXED_USER_HOME in a scratch folder (UserDefaults stay there).
set -uo pipefail
if [ -z "${UI_SOURCED:-}" ]; then echo "REFUSING direct UI runner; use run-headless.sh"; exit 1; fi
R=${R:-${SOCKROOT:-$(mktemp -d /private/tmp/ddchk.XXXXXX)}}; mkdir -p "$R"; R=$(cd "$R" && pwd -P)
UIHOME=$OUT/ui-home; mkdir -p "$UIHOME/Library/Preferences"
DDOUT=$OUT/dd; mkdir -p "$DDOUT"
APPSRC=$OUT/src/app; rm -rf "$APPSRC"; mkdir -p "$APPSRC"
for f in Sources/MacMemApp/*.swift; do python3 "$C/copy-check-source.py" "$f" "$R" > "$APPSRC/$(basename "$f")"; done
uicheck() { python3 "$C/copy-check-source.py" "scripts/$1.swift" "$R" > "$OUT/src/$1.swift"; echo "$OUT/src/$1.swift"; }
uiobjs() { for t in MemoryCore MemoryUI HistoryCore CoreIntegration PrivacyPolicy BrowserBridge WriterBackend CLlamaBridge BackupRestore; do ls "$B/$t.build/"*.o; done; }
UIFLAGS=(-D DEVELOPMENT_SOURCE_CHECKS -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules"
  -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$B/CLlamaBridge.build/module.modulemap"
  -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include")
runui() { env HOME="$UIHOME" CFFIXED_USER_HOME="$UIHOME" DD_CHECK_OUT="$DDOUT" "$@"; }
APPCHECKS="settings-hub-checks dd-menubar-checks dd-app-menu-checks dd-app-model-checks dd-settings-status-checks"
[ -f scripts/chrome-pages-ui-checks.swift ] && APPCHECKS="$APPCHECKS chrome-pages-ui-checks"
# gold/save-path: Exclude App, Don't Record and the site field say nothing while a busy save is tried again.
[ -f scripts/save-path-app-checks.swift ] && APPCHECKS="$APPCHECKS save-path-app-checks"
# gold/connections-storage (G45): launch repairs a damaged history; the menu line, Backup notice and button, setup reset.
[ -f scripts/history-set-aside-checks.swift ] && APPCHECKS="$APPCHECKS history-set-aside-checks"
# typing-all ui track: the Typing screens, menu rows, glyph badge and the pause shortcut (fake registrar).
[ -f scripts/typing-ui-checks.swift ] && APPCHECKS="$APPCHECKS typing-ui-checks"
# fix/setup-status: setup and its upgrade what's-new (the real setup window, scratch histories), setup's renders
# (DD_CHECK_OUT/onboarding-renders) and first launch.
[ -f scripts/setup-upgrade-checks.swift ] && APPCHECKS="$APPCHECKS setup-upgrade-checks"
[ -f scripts/onboarding-screen-checks.swift ] && grep -q '^// DD-RECIPE: APP' scripts/onboarding-screen-checks.swift && APPCHECKS="$APPCHECKS onboarding-screen-checks"
[ -f scripts/dd-first-launch-checks.swift ] && APPCHECKS="$APPCHECKS dd-first-launch-checks"
for check in $APPCHECKS; do
  src=$(uicheck $check)
  step compile-$check swiftc "${UIFLAGS[@]}" -F "$B" -framework Sparkle -Xlinker -rpath -Xlinker "$B" \
    "$APPSRC"/*.swift "$src" $(uiobjs) -lc++ -o "$OUT/$check"
  step $check runui "$OUT/$check"
done
# typing-all ui track: the same typing UI check compiled with the owner flags against the owner
# debug objects (run-checks.sh builds them as $OB): owner app lists and the Other websites row.
# (sat/v1 dropped the DaydreamConnectionSetup package, so it is not in the object list.)
if [ -n "${OB:-}" ] && [ -f scripts/typing-ui-checks.swift ]; then
  src=$(uicheck typing-ui-checks)
  OUIFLAGS=(-D DEVELOPMENT_SOURCE_CHECKS -D DAYDREAM_OWNER_TYPING -D DAYDREAM_CHROME_TYPING -parse-as-library -module-cache-path "$I/modcache" -I "$OB/Modules"
    -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$OB/CLlamaBridge.build/module.modulemap"
    -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include")
  step compile-owner-typing-ui-checks swiftc "${OUIFLAGS[@]}" -F "$OB" -framework Sparkle -Xlinker -rpath -Xlinker "$OB" \
    "$APPSRC"/*.swift "$src" $(for t in MemoryCore MemoryUI HistoryCore CoreIntegration PrivacyPolicy BrowserBridge WriterBackend CLlamaBridge BackupRestore; do ls "$OB/$t.build/"*.o; done) \
    -lc++ -o "$OUT/owner-typing-ui-checks"
  step owner-typing-ui-checks runui env DD_EXPECT_OWNER=1 "$OUT/owner-typing-ui-checks"
  # public-typing review (release, high): every other APP and UI check, flagged, against $OB (owner-lane.sh).
  OWNER_UI=1 source "$C/owner-lane.sh"
fi
# gold/connections-storage: dd-recall-checks joins the UI loop.
for check in dd-kit-checks permission-settings-checks dd-recall-checks; do
  [ -f "scripts/$check.swift" ] || continue
  src=$(uicheck $check)
  step compile-$check swiftc "${UIFLAGS[@]}" "$src" $(uiobjs) -lc++ -o "$OUT/$check"
  step $check runui "$OUT/$check"
done
# fix/setup-status: the permission window (UI recipe; the check uses MemoryUI without importing it, so its copy gets the
# import); renders only, never a window ordered on screen.
if [ -f scripts/permission-window-checks.swift ]; then
  src=$(uicheck permission-window-checks)
  grep -q '^import MemoryUI' "$src" || sed -i '' '1s/^/import MemoryUI\
/' "$src"
  step compile-permission-window-checks swiftc "${UIFLAGS[@]}" "$src" $(uiobjs) -lc++ -o "$OUT/permission-window-checks"
  step permission-window-checks runui "$OUT/permission-window-checks" --render-only
fi
step settings-0013-py python3 scripts/settings-0013-checks.py -v
if [ -z "${UI_SOURCED:-}" ]; then printf '%s\n' "${summary[@]}" | tee "$OUT/SUMMARY"; fi
