# Sourced by run-checks.sh (same step/OUT/I/R/C/OB). Phase 1 commit 9: the check files no runner step ran before
# (the 10/07 inventory), each wired once, flagged like the release build: both shipped flags against the owner debug
# objects ($OB). Their lanes, statuses and known failures are rows of scripts/checks-manifest.tsv.
# Every step has its own scratch HOME, CFFIXED_USER_HOME, DD_CHECK_OUT, TMPDIR and *_ROOT folders under
# $I/wired/<step>; nothing reads the person's history, preferences or Keychain, and nothing opens a window on screen.
if have_ob; then
WOBJ=(MemoryCore HistoryCore MemoryUI WriterBackend CoreIntegration PrivacyPolicy BrowserBridge CLlamaBridge BackupRestore)
WFLAGS=(-parse-as-library -D DEVELOPMENT_SOURCE_CHECKS -D DAYDREAM_OWNER_TYPING -D DAYDREAM_CHROME_TYPING -module-cache-path "$I/modcache"
  -I "$OB/Modules" -I Sources/CSQLite -Xcc -fmodule-map-file="$OB/CLlamaBridge.build/module.modulemap")
wobjs() { [ -n "${DRYRUN:-}" ] && return 0; for t in "${WOBJ[@]}"; do ls "$OB/$t.build/"*.o; done; }
# wdirs NAME: the step's scratch folders (W). wscratch NAME: those, and its check source copied with the /private/tmp
# roots moved to $R (copy-check-source.py).
wdirs() { W=$I/wired/$1; [ -n "${DRYRUN:-}" ] || { rm -rf "$W"; mkdir -p "$W/home/Library/Preferences" "$W/dd" "$W/root" "$W/tmp"; }; }
wscratch() { wdirs "$1"; [ -n "${DRYRUN:-}" ] || python3 "$C/copy-check-source.py" "scripts/$1-checks.swift" "$R" > "$OUT/src/$1-checks.swift"; }
# wrun NAME BIN ARGS: run with the scratch env; @ROOT and @OUT in ARGS are the step's root folder and an output file in it.
wrun() { local name=$1 bin=$2; shift 2; local a args=()
  for a in "$@"; do a=${a//@ROOT/$W/root}; args+=("${a//@OUT/$W/root/out.json}"); done
  step "$name" env HOME="$W/home" CFFIXED_USER_HOME="$W/home" DD_CHECK_OUT="$W/dd" TMPDIR="$W/tmp/" DD_SOURCE_ROOT="$PWD" \
    FALLBACK_CHECK_ROOT="$W/root" SUMMARY_REGEN_CHECK_ROOT="$W/root" STATE_CHECK_ROOT="$W/root" "$bin" ${args[@]+"${args[@]}"}; }
# ow NAME [EXTRA SOURCES...] [-- ARGS...]: scripts/NAME-checks.swift (+ app sources it needs) against every owner target.
ow() { local name=$1; shift; local srcs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do srcs+=("$1"); shift; done; [ $# -gt 0 ] && shift
  wscratch "$name"
  step compile-$name swiftc "${WFLAGS[@]}" ${srcs[@]+"${srcs[@]}"} "$OUT/src/$name-checks.swift" $(wobjs) -lsqlite3 -lc++ -o "$OUT/$name"
  wrun "$name" "$OUT/$name" "$@"; }
# owapp NAME [-- ARGS...]: the APP recipe (run-checks.sh app_link: the check against the precompiled app module).
owapp() { local name=$1; shift; [ $# -gt 0 ] && shift
  wscratch "$name"
  step compile-$name app_link "$OB" "$OUT/$name" "$OUT/src/$name-checks.swift" "${OMF[@]}"
  wrun "$name" "$OUT/$name" "$@"; }

# --- setup-ui ---------------------------------------------------------------------------------------------------------
for name in dd-focus-list timeline-card-condense dd-status dd-status-surfaces-safety dd-today-data day-navigation layout-loop \
  page-links site-icon settings-condense; do ow $name; done
ow timeline-session-grouping -- "$PWD/scripts/fixtures/derived-session-interval-pattern.json"
for name in owner-source-detail owner-source-preview terminal-details; do ow $name -- @ROOT; done
# main-layout-stress (not a -checks file): the default and dense resize/scroll/refresh passes with the indicator check.
wdirs main-layout-stress
step compile-main-layout-stress swiftc "${WFLAGS[@]}" scripts/main-layout-stress.swift $(wobjs) -lsqlite3 -lc++ -o "$OUT/main-layout-stress"
wrun main-layout-stress "$OUT/main-layout-stress"
wrun main-layout-stress-dense "$OUT/main-layout-stress" check-indicators dense
# DayDream Preview (formerly scripts/preview/run-preview-checks.sh, beside the suite): the preview on the real launch
# path, then nothing of it outside the temporary folder; the moment menus over a new sample.
# The preview's folder is FileManager's per-user temporary folder, which ignores TMPDIR (the app has no seam for it), so
# this step is not hermetic: preview-paths removes the sample afterwards only when this run made it (none was there).
PVT="$(getconf DARWIN_USER_TEMP_DIR)DayDream Preview Sample"; PVFRESH=; [ -e "$PVT" ] || PVFRESH=$PVT
owapp preview-app
step preview-paths bash "$C/preview-paths.sh" "$OUT/preview-app.log" "$I/wired/preview-app/home" "$PVFRESH"
owapp dd-moment-menus
# --- storage ----------------------------------------------------------------------------------------------------------
for name in forget-range fuzzy-search search-context search-progressive search-typed retention core-production; do ow $name; done
# The signature repros of typed words kept across store maintenance (known failures in the manifest: an app regression).
for name in sig-indexer-maintenance sig-maintenance-fixed; do ow $name -- @ROOT @OUT; done
# Real Typesense: TYPESENSE_BINARY is the pinned typesense-server (packaging/TypesenseRuntime/local-typesense-v30.2.json
# inputServerSHA256), on the internal disk. Started only as a loopback child of a check, over synthetic stores.
TS=${TYPESENSE_BINARY:-}
step typesense-binary python3 "$C/typesense-binary.py" "$TS"
ow search-launch -- "$TS"
wscratch production-search
step compile-production-search swiftc "${WFLAGS[@]}" "$OUT/src/production-search-checks.swift" $(wobjs) -lsqlite3 -lc++ -o "$OUT/production-search"
wrun production-search env MACMEM_TYPESENSE_TEST_BINARY="$TS" MACMEM_TEST_CLI="$OB/mac-mem" "$OUT/production-search"
# The XCTest bodies of Tests/MemoryCoreTests/TypesenseTests.swift through scripts/search-test-runner.swift (no XCTest
# needed; the package has no test target).
wdirs typesense-tests
step compile-typesense-tests swiftc -parse-as-library -D DAYDREAM_OWNER_TYPING -D DAYDREAM_CHROME_TYPING -module-cache-path "$I/modcache" -I "$OB/Modules" -I Sources/CSQLite \
  scripts/search-test-runner.swift Tests/MemoryCoreTests/TypesenseTests.swift $([ -n "${DRYRUN:-}" ] || ls "$OB"/MemoryCore.build/*.o "$OB"/HistoryCore.build/*.o "$OB"/PrivacyPolicy.build/*.o) \
  -lsqlite3 -o "$OUT/typesense-tests"
wrun typesense-tests env MACMEM_TYPESENSE_TEST_BINARY="$TS" "$OUT/typesense-tests"
# --- capture ----------------------------------------------------------------------------------------------------------
for name in contact-shape-pipeline recipient-authority; do ow $name; done
# The capture recipe: the core-source capture list (headless Coordinator), as owner-production-capture builds it.
ow messages-recorder-regression $CAPTURE
ow native-intake-boundary $CAPTURE -- @ROOT
ow messages-safety Sources/MacMemApp/NativeTypingRoute.swift Sources/MacMemApp/NativeFocusWitness.swift
ow sig-context-capture PrivacyPolicy/Checks/TypingChecks.swift -- @ROOT @OUT
ow sig-context-negative -- @ROOT
ow sig-emoticon PrivacyPolicy/Checks/TypingChecks.swift -- @ROOT
step c1-search-contract-py python3 scripts/c1-search-contract-checks.py
# Its two negative controls (the old reveal-result and second-read omissions restored in the extracted code) must fail.
step c1-search-contract-controls bash -c 'for c in secure deadline; do if python3 scripts/c1-search-contract-checks.py --negative-control $c >/dev/null 2>&1; then echo "FAIL the $c negative control passed"; exit 1; fi; echo "PASS the $c negative control fails"; done'
# The fabricated recording-session transcript replayed through the capture sources, capture text on and off. The
# script compiles unflagged, so it links the public objects ($B).
step recording-replay env BUILD="$B" REPLAY_OUT_ROOT="$I/tmp" bash scripts/test-recording-replay.sh
# --- ai-tools ---------------------------------------------------------------------------------------------------------
# Folded in from scripts/run-summary-regression-checks.sh (deleted): its notes-quality, summary-sends and writer-state
# already had steps; these are the rest.
for name in fallback-compat summary-action-isolation summary-clause summary-coherence summary-copy-facts summary-fallback stale-card; do ow $name; done
ow overnight-summary-detail -- @ROOT
ow summary-regeneration Sources/MacMemApp/WriterScheduling.swift
ow sig-note-prepare-fixed Sources/MacMemApp/WriterIntegration.swift Sources/MacMemApp/WriterScheduling.swift Sources/MacMemApp/WriterPreferences.swift Sources/MacMemApp/LevelPower.swift adapters/LevelWriterBinding.swift -- @ROOT @OUT
# wb-scheduler runs WriterBackend/SchedulerChecks over stand-in types; this runs the same checks against the production
# scheduler compiled into WriterBackend.
wdirs scheduler-production
[ -n "${DRYRUN:-}" ] || { printf 'import WriterBackend\n'; cat WriterBackend/SchedulerChecks/main.swift; } > "$OUT/src/scheduler-production.swift"
step compile-scheduler-production swiftc "${WFLAGS[@]}" "$OUT/src/scheduler-production.swift" $(wobjs) -lsqlite3 -lc++ -o "$OUT/scheduler-production"
wrun scheduler-production "$OUT/scheduler-production"
# The AI-app tools evals, in process and through the real `mac-mem mcp` (temp homes; no model, no network).
step agent-tools-evals-py python3 scripts/agent-tools-evals.py --mode both --checks "$OB/MacMemChecks" --cli "$OB/mac-mem"
step migration-py env MACMEM_TEST_CLI="$OB/mac-mem" python3 scripts/check_migration.py -v
step migration-inventory-py python3 scripts/check_migration_inventory.py -v
step search-interfaces-py env MACMEM_TEST_CLI="$OB/mac-mem" python3 scripts/check_search_interfaces.py -v
# --- release ----------------------------------------------------------------------------------------------------------
# Release tooling over synthetic fixtures in their own temporary folders: the functional payload policy and trial
# manifest, the writer's macOS 15 inputs, and the developer refresh.
step functional-payload-py python3 scripts/check_functional_payload.py -v
step functional-trial-py python3 scripts/check_functional_trial.py -v
step writer-macos15-inputs-py python3 scripts/check_writer_macos15_inputs.py -v
step dev-refresh-py python3 scripts/check-dev-refresh.py -v
# --- smoke ------------------------------------------------------------------------------------------------------------
ow title-clean
# --- the sub-packages' checks no step ran (the 10/08 review: outside the old inventory globs) --------------------------
# capture: BrowserBridge's canonical ingestion against the owner objects (its /private/tmp stores moved to $R).
wdirs bb-core-ingestion
[ -n "${DRYRUN:-}" ] || sed -e "s#/private/tmp/#$R/#g" BrowserBridge/fixtures/core-ingestion-checks.swift > "$OUT/src/bb-core-ingestion.swift"
step compile-bb-core-ingestion swiftc -module-cache-path "$I/modcache" -I "$OB/Modules" -I Sources/CSQLite -D DAYDREAM_OWNER_TYPING -D DAYDREAM_CHROME_TYPING \
  "$OUT/src/bb-core-ingestion.swift" adapters/CoreCaptureBinding.swift $(wobjs) -lsqlite3 -lc++ -o "$OUT/bb-core-ingestion"
wrun bb-core-ingestion "$OUT/bb-core-ingestion"
# ai-tools: the writer runtime's synthetic signature, manifest and closed-loader policy (no trusted artifact is loaded;
# WriterBackend/SignedRuntimeChecks/run.sh's recipe, with the owner build's CLlamaBridge object).
wdirs wb-signed-runtime
[ -n "${DRYRUN:-}" ] || sed -e "s#/private/tmp/#$R/#g" WriterBackend/SignedRuntimeChecks/main.swift > "$OUT/src/wb-signed-runtime.swift"
step compile-wb-signed-runtime swiftc -parse-as-library -module-cache-path "$I/modcache" -I WriterBackend/Sources/CLlamaBridge/include \
  -Xcc -fmodule-map-file="$OB/CLlamaBridge.build/module.modulemap" WriterBackend/Sources/WriterBackend/*.swift "$OUT/src/wb-signed-runtime.swift" \
  "$OB/CLlamaBridge.build/WriterLlama.cpp.o" -lc++ -o "$OUT/wb-signed-runtime"
wrun wb-signed-runtime "$OUT/wb-signed-runtime"
fi
# capture: the BrowserBridge package (its own targets, no flags): native, diagnostic and metadata checks, the relay and
# setup fixtures, and the extension's node checks against the package's own binaries. Synthetic keys and temporary
# endpoints only; no browser is launched.
BBD=$SB/build-bb/debug
step bb-package-build swift build --jobs 3 --package-path BrowserBridge --scratch-path "$SB/build-bb" --disable-automatic-resolution
step bb-BrowserBridgeChecks "$BBD/BrowserBridgeChecks"
step bb-DiagnosticChecks "$BBD/DiagnosticChecks" --checks
step bb-MetadataChecks "$BBD/BrowserMetadataChecks"
for name in local-transport production-setup; do
  [ -n "${DRYRUN:-}" ] || sed -e "s#/private/tmp/#$R/#g" BrowserBridge/fixtures/$name-checks.swift > "$OUT/src/bb-$name.swift"
  step compile-bb-$name swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$BBD/Modules" "$OUT/src/bb-$name.swift" "$BBD"/BrowserBridge.build/*.o -o "$OUT/bb-$name"
  step bb-$name "$OUT/bb-$name"
done
step bb-extension-mjs "${NODE_BIN:-node}" --test BrowserBridge/fixtures/extension-checks.mjs
step bb-key-store-mjs "${NODE_BIN:-node}" --test BrowserBridge/fixtures/key-store-checks.mjs
step bb-authenticated-mjs "${NODE_BIN:-node}" BrowserBridge/fixtures/authenticated-checks.mjs "$BBD/BrowserMetadataChecks"
# The diagnostic transport makes /private/tmp/diag-livewire-* folders (hard-coded in the .mjs); it names each in its
# JSON lines, and the step removes exactly those afterwards.
step bb-diagnostic-transport-mjs bash -c 'out=$("${NODE_BIN:-node}" BrowserBridge/fixtures/diagnostic-transport-checks.mjs "$1" "$2" 2>&1); rc=$?; printf "%s\n" "$out"; for d in $(printf "%s\n" "$out" | sed -n "s#.*\"directory\":\"\(/private/tmp/diag-livewire-[A-Za-z0-9]*\)\".*#\1#p"); do rm -rf "$d"; done; exit $rc' _ "$BBD/DiagnosticChecks" "$BBD/BrowserBridgeDiagnosticHost"
# capture: the device-test kit's page server matches the Python one byte for byte (loopback only; harness-build's binary).
mkdir -p "$I/server-parity"
step server-parity-py python3 tools/chrome-device-test/kit/check_server_parity.py --serve "$SB/harness-build/debug/chrome-device-test-serve" --work "$I/server-parity"
# storage: the backup/restore tool's own unittest (synthetic folders).
step backup-restore-py python3 BackupRestore/test_backup_restore.py -v
# ai-tools: the writer runtime distribution plan (synthetic dylib; nothing is signed or executed).
step runtime-distribution-py python3 WriterBackend/check_runtime_distribution.py
