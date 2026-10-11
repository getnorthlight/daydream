# Realism (test-suite phase 2, owner 10/8: "realistic bugs which are similar to the ones that I have pointed out to you
# time and time again"): the owner's own bugs replayed where DayDream meets macOS. Sourced by run-checks.sh
# (steps.d/README); rows in scripts/checks-manifest.d/realism.tsv, pins in scripts/checks-known-failures.d/realism.tsv,
# bug re-injections in scripts/mutations.d/realism.tsv.
#
#   realism-adhoc-identity   bug 3   ad-hoc seals never carry a real or test-copy bundle ID (fake codesign)
#   realism-staging          bug 11  every staging path builds fresh or refuses a reused SwiftPM scratch (fake SwiftPM)
#   realism-source-scan              the package's own files never touch a permission, TCC, the history or the real home
#   realism-skip-app         bug 2   realism-writer-binding  bug 4   realism-setup-poll   bug 5   realism-drag-caches  bug 6
#   realism-setup-start      bug 12  realism-tcc-states      bug 3 + the 5 x 3 TCC matrix   realism-window-layouts
# The app sections are one binary (scripts/realism-app-checks.swift: every app source through scripts/realism-seams.py,
# the owner objects, both shipped flags), compiled once per run (rapp); each section is its own step.
# Every step has its own scratch HOME and CFFIXED_USER_HOME under $OUT/realism/<step> (rrun). Injected permission states
# only: nothing reads or changes a real permission, records, signs, builds the app, or goes online.

# rrun NAME CMD...: CMD as step NAME with its own scratch HOME, CFFIXED_USER_HOME, DD_CHECK_OUT and TMPDIR.
# REALISM_OUT (the staging checks' scratch) is under the run's /private/tmp root ($R): stage-local-ui-update.py stages
# only inside the workspace or /private/tmp, and lanes.sh's work folders are neither (there the helper refused every
# stage for its folder, which read as the stale-binary refusal the check looks for).
rrun() { local name=$1; shift; local W=$OUT/realism/$name RO=$R/realism/$name
  [ -n "${DRYRUN:-}" ] || { rm -rf "$W" "$RO"; mkdir -p "$W/home/Library/Preferences" "$W/home/Library/Caches" "$W/dd" "$W/tmp" "$RO"; chmod 700 "$W/dd"; }
  step "$name" env HOME="$W/home" CFFIXED_USER_HOME="$W/home" DD_CHECK_OUT="$W/dd" TMPDIR="$W/tmp/" REALISM_OUT="$RO" \
    PYTHONDONTWRITEBYTECODE=1 "$@"; }

rrun realism-adhoc-identity python3 scripts/realism-adhoc-identity-checks.py
rrun realism-staging python3 scripts/realism-staging-checks.py
rrun realism-source-scan python3 scripts/realism-source-scan-checks.py

if have_ob; then
  # The APP recipe (wired-lanes.sh's owapp) on realism-seams.py's copy of the app sources. One binary serves every app
  # section: each section's compile-<step> builds it only when its inputs (the seamed sources, the check, the owner
  # objects) differ from the last build in this run, so a step run alone (ONLY=, mutate.sh) still compiles what it runs.
  realism_compile() {
    local src=$OUT/src/realism-app key objs mod=
    rm -rf "$src"; python3 scripts/realism-seams.py Sources/MacMemApp "$src" "$R" || return 1
    objs=$(oobjs MemoryCore HistoryCore MemoryUI WriterBackend CoreIntegration PrivacyPolicy BrowserBridge CLlamaBridge BackupRestore) || return 1
    local flags=(-parse-as-library -D DEVELOPMENT_SOURCE_CHECKS -D DAYDREAM_OWNER_TYPING -D DAYDREAM_CHROME_TYPING -module-cache-path "$I/modcache"
      -I "$OB/Modules" -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$OB/CLlamaBridge.build/module.modulemap"
      -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include" -F "$OB" -framework Sparkle -Xlinker -rpath -Xlinker "$OB")
    # With the precompiled app module (runner-1001/app-module.sh, when the runner has one): the seamed sources are built
    # once into DDApp (cached by their content), and only the check compiles here.
    if [ -n "${APPMOD:-}" ] && [ -f "$C/app-module.sh" ]; then
      mod=$(MODCACHE="$I/modcache" bash "$C/app-module.sh" ensure "$APPMOD" "$src" "$OB" -D DAYDREAM_OWNER_TYPING -D DAYDREAM_CHROME_TYPING) || return 1
    fi
    key=$( { echo "module $mod"; cat "$src"/*.swift scripts/realism-app-checks.swift; stat -f '%N %z %m' $objs; } | shasum | cut -c1-40)
    if [ -x "$OUT/realism-app" ] && [ "$(cat "$OUT/realism-app.key" 2>/dev/null)" = "$key" ]; then
      echo "realism-app is current (inputs $key): reused"; return 0; fi
    rm -f "$OUT/realism-app" "$OUT/realism-app.key"
    if [ -n "$mod" ]; then
      { echo "@testable import DDApp"; echo "#sourceLocation(file: \"scripts/realism-app-checks.swift\", line: 1)"; cat scripts/realism-app-checks.swift; } > "$OUT/src/realism-app-checks.swift"
      swiftc "${flags[@]}" -I "$mod" "$OUT/src/realism-app-checks.swift" -Xlinker -force_load -Xlinker "$mod/libDDApp.a" $objs -lc++ -o "$OUT/realism-app" || return 1
    else
      swiftc "${flags[@]}" "$src"/*.swift scripts/realism-app-checks.swift $objs -lc++ -o "$OUT/realism-app" || return 1
    fi
    echo "$key" > "$OUT/realism-app.key"; echo "realism-app compiled ($([ -n "$mod" ] && echo "app module ${mod##*/}" || echo "all app sources"))"; }
  # rapp STEP SECTION [ARGS...]: compile-STEP, then STEP runs that section of the binary.
  rapp() { local name=$1; shift; step compile-$name realism_compile; rrun "$name" "$OUT/realism-app" "$@"; }
  rapp realism-skip-app skip-app "$PWD/scripts/fixtures/realism/skip-app-bundle-ids.tsv"
  rapp realism-writer-binding writer-binding
  rapp realism-setup-poll setup-poll
  rapp realism-setup-start setup-start
  rapp realism-tcc-states tcc-states
  rapp realism-drag-caches drag-caches
  rapp realism-window-layouts window-layouts "$PWD/scripts/fixtures/realism/display-layouts.json"
fi
