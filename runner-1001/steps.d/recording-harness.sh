# Step fragment (runner-1001/steps.d/README): the recording harness's steps, lane `flows` (rows:
# scripts/checks-manifest.d/recording-harness.tsv; pins: scripts/checks-known-failures.d/recording-harness.tsv).
# What the harness is and what each step proves: scripts/harness/README.md.
#   flow-oracle       the 0.2.0 oracles' self-tests and every flow's timeline validated (Foundation only)
#   flow-replay       every synthetic flow (scripts/fixtures/flows) replayed twice through the real capture objects on a
#                     virtual clock into scratch stores: the determinism hash, each flow's expectations, the bug labels
#   flow-app          the bug-1 lock flows and the bug-9 launches on the real view model and app delegate (APP recipe)
#   flow-source-scan  no event tap, permission API, Keychain read, Apple event or tccutil in the harness, and the seams
# Each step runs in its own scratch HOME/CFFIXED_USER_HOME/TMPDIR under $I/flows/<step>; nothing reads the person's
# history, preferences or Keychain, nothing opens a window, nothing is sent.
rh_dirs() { RHW=$I/flows/$1; [ -n "${DRYRUN:-}" ] || { rm -rf "$RHW"; mkdir -p "$RHW/home/Library/Preferences" "$RHW/dd" "$RHW/scratch" "$RHW/tmp"; }; }
rh_run() { local name=$1; shift
  step "$name" env HOME="$RHW/home" CFFIXED_USER_HOME="$RHW/home" DD_CHECK_OUT="$RHW/dd" TMPDIR="$RHW/tmp/" "$@"; }
rh_objs() { [ -n "${DRYRUN:-}" ] && return 0; oobjs "$@"; }
RH_FLOWS=$PWD/scripts/fixtures/flows
RH_FLAGS=(-parse-as-library -D DAYDREAM_OWNER_TYPING -D DAYDREAM_CHROME_TYPING -module-cache-path "$I/modcache")

# flow-oracle: pure Swift (the timeline and the oracles), no app objects.
rh_dirs flow-oracle
step compile-flow-oracle swiftc "${RH_FLAGS[@]}" scripts/harness/Timeline.swift scripts/harness/Oracles.swift \
  scripts/flow-oracle-checks.swift -o "$OUT/flow-oracle"
rh_run flow-oracle "$OUT/flow-oracle" "$RH_FLOWS"

step flow-source-scan python3 scripts/harness/source-scan.py "$PWD"

if have_ob; then
  # flow-replay: the capture recipe ($CAPTURE: the core-source capture list with the headless Coordinator copy), as
  # owner-production-capture builds it, plus the app files the driver needs, against the owner objects.
  rh_dirs flow-replay
  step compile-flow-replay swiftc "${RH_FLAGS[@]}" -I "$OB/Modules" -I Sources/CSQLite \
    -Xcc -fmodule-map-file="$OB/CLlamaBridge.build/module.modulemap" $CAPTURE \
    scripts/harness/Timeline.swift scripts/harness/Oracles.swift scripts/harness/CaptureDriver.swift \
    Sources/MacMemApp/WakeResume.swift Sources/MacMemApp/LaunchLocation.swift Sources/MacMemApp/TypedTextExpiryTimer.swift \
    scripts/flow-replay-checks.swift \
    $(rh_objs MemoryCore HistoryCore CoreIntegration WriterBackend PrivacyPolicy BrowserBridge CLlamaBridge MemoryUI) \
    -lc++ -lsqlite3 -o "$OUT/flow-replay"
  rh_run flow-replay "$OUT/flow-replay" "$RH_FLOWS" "$RHW/scratch"

  # flow-app: the APP recipe as a check build (in-memory typing keyring, inert login item), with the headless permission
  # seams. Where the runner has the precompiled app module (app_link, tiers), the check links against it: Timeline.swift
  # and the check are joined into one source (app_link takes one file). Otherwise every app source is compiled in
  # (appsrc, as ui-checks.sh builds its APP checks).
  rh_dirs flow-app
  if declare -F app_link >/dev/null; then
    [ -n "${DRYRUN:-}" ] || cat scripts/harness/Timeline.swift scripts/flow-app-checks.swift > "$OUT/src/flow-app-joined.swift"
    step compile-flow-app app_link "$OB" "$OUT/flow-app" "$OUT/src/flow-app-joined.swift" -D DAYDREAM_OWNER_TYPING -D DAYDREAM_CHROME_TYPING
  else
    RH_APPSRC=$(appsrc)
    step compile-flow-app swiftc "${RH_FLAGS[@]}" -D DEVELOPMENT_SOURCE_CHECKS -I "$OB/Modules" \
      -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$OB/CLlamaBridge.build/module.modulemap" \
      -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include" -F "$OB" -framework Sparkle -Xlinker -rpath -Xlinker "$OB" \
      "$RH_APPSRC"/*.swift scripts/harness/Timeline.swift scripts/flow-app-checks.swift \
      $(rh_objs MemoryCore MemoryUI HistoryCore CoreIntegration PrivacyPolicy BrowserBridge WriterBackend CLlamaBridge BackupRestore) \
      -lc++ -o "$OUT/flow-app"
  fi
  rh_run flow-app "$OUT/flow-app" "$RH_FLOWS"
fi

# tests-status: Tests/README.md stays true (no testTarget: the Command Line Tools have no XCTest; every Tests/ file is a
# manifest row's file, typesense-tests through scripts/search-test-runner.swift).
step tests-status python3 scripts/harness/tests-status.py "$PWD"
