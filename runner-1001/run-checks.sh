#!/bin/bash
# Full headless synthetic check suite for DayDream: builds the package, runs MacMemChecks and every
# scripts/*-checks step below, plus the public/owner typing scans. Run it through run-headless.sh.
# Env: SRC=worktree (default: this repo), WORKDIR=build+output dir (default: .build/checks; use one per parallel run),
# SOCKROOT=short socket dir (default: a new /tmp/ddchk.* folder; one per parallel run).
# No app launch, event tap, Apple Event to Chrome, permission request, keychain,
# signing or download. Every temp/build path is under the scratch folder below.
set -uo pipefail
# This COPY is headless-only; an unset/custom SKIP can never enable a window.
export SKIP='^(owner-)?(recording-permission|docs-install-render|honesty-ui|honesty-ui-checks|update-quit|dd-menubar-checks|dd-app-menu-checks|dd-settings-status-checks|typing-ui-checks|setup-upgrade-checks|onboarding-screen-checks|dd-kit-checks|dd-recall-checks|permission-window-checks)$'
C=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export PATH="$C/bin:$PATH"
# docs-claims-checks can also check post drafts kept outside the repo (DAYDREAM_DRAFT_ROOT); none by default.
SATC=${DAYDREAM_DRAFT_ROOT:-$C/no-drafts}
WT=${SRC:-$(cd "$C/.." && pwd)}
I=${WORKDIR:-$WT/.build/checks}; mkdir -p "$I"
BUILD=${BUILD:-$I/build-public}
LABEL=${1:-run}
OUT=$I/out-$LABEL
rm -rf "$OUT"; mkdir -p "$OUT" "$I/tmp" "$I/modcache" "$OUT/src"
export TMPDIR=$I/tmp/ PYTHONDONTWRITEBYTECODE=1
export CLANG_MODULE_CACHE_PATH=$I/modcache SWIFT_MODULECACHE_PATH=$I/modcache
cd "$WT"
# gold/int: every APP-recipe check builds MemoryViewModel with -D DEVELOPMENT_SOURCE_CHECKS, where the typing keys are
# in memory (gold/lifecycle's MemoryViewModel.typedKeyStore). Refuse a tree without that seam: its checks would reach
# the real Keychain at launch (TypedTextLaunch.wire).
if ! grep -q 'typedExpiry=TypedTextLaunch.wire(store:store,keys:Self.typedKeyStore).timer' Sources/MacMemApp/MacMemApp.swift; then
  echo "REFUSING: Sources/MacMemApp/MacMemApp.swift has no check-build typing-key seam (the checks would reach the Keychain)"; exit 1
fi
B=$BUILD/arm64-apple-macosx/debug
summary=()
failed_steps=0
# gold/int: ONLY=<regex> runs just the matching steps (reruns after a fix); unset runs everything.
# SKIP=<regex> also skips steps that host on-screen AppKit windows (this runner is headless). Skipped steps are
# logged as "SKIPPED-UI" in the summary.
step() { local name=$1; shift; if [ -n "${ONLY:-}" ] && ! [[ $name =~ $ONLY ]]; then return 0; fi; if [ -n "${SKIP:-}" ] && [[ $name =~ $SKIP ]]; then summary+=("$name SKIPPED-UI"); echo "$name SKIPPED-UI"; return 0; fi; "$@" >"$OUT/$name.log" 2>&1; local rc=$?
  if [ "$rc" -ne 0 ]; then failed_steps=$((failed_steps+1)); fi
  summary+=("$name exit=$rc pass=$(grep -cE '^PASS|\.\.\. ok$|^# pass|passed' "$OUT/$name.log")"); echo "$name exit=$rc"; }
objs() { for t in "$@"; do ls "$B/$t.build/"*.o; done; }
# Copy a check whose store root is hard-coded under /private/tmp into scratch,
# pointing the root at a short temp folder instead (the repo file is not
# changed). Short because browser-app-0227 binds a UNIX socket in that root and
# sun_path holds at most 104 bytes; the scratch path is longer than that.
R=${SOCKROOT:-$(mktemp -d /private/tmp/ddchk.XXXXXX)}; mkdir -p "$R"; R=$(cd "$R" && pwd -P)  # resolved: /tmp is a symlink
relocated() { local f=$1; sed -e "s#/private/tmp/#$R/#g" "scripts/$f" > "$OUT/src/$f"; echo "$OUT/src/$f"; }
LLAMA=(-Xcc -fmodule-map-file="$B/CLlamaBridge.build/module.modulemap")
APPDEPS=(MemoryCore HistoryCore CoreIntegration WriterBackend PrivacyPolicy BrowserBridge CLlamaBridge)

step build swift build --jobs 3 --scratch-path "$BUILD" --disable-automatic-resolution
step MacMemChecks "$B/MacMemChecks"
step ProductionBindingChecks "$B/ProductionBindingChecks"
# gold/perf-store (G6, G7, G16, G17, G60, G64): store work costs what is new, and no store I/O on the main thread.
if [ -f scripts/store-perf-checks.swift ]; then
  step compile-store-perf swiftc -parse-as-library ${PERF_STORE_SWIFT_FLAGS:-} -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite \
    scripts/store-perf-checks.swift $(objs MemoryCore HistoryCore PrivacyPolicy MemoryUI) -o "$OUT/store-perf"
  step store-perf "$OUT/store-perf"
fi
# perf-1002: the menu bar label and Recording rows publish only a changed value (headless, no status item).
if [ -f scripts/perf-1002-checks.swift ]; then
  step compile-perf-1002 swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite \
    scripts/perf-1002-checks.swift $(objs MemoryCore HistoryCore PrivacyPolicy MemoryUI) -o "$OUT/perf-1002"
  step perf-1002 "$OUT/perf-1002"
fi
# claude/perf2-1003: 0.1.4's new paths (typed-words search, index sync, title floods, detail folds, catch-up days,
# Privacy.secret, the search supervisor's pacing) with their main-thread cost (headless, synthetic stores, BENCH lines).
if [ -f scripts/perf-1003-checks.swift ]; then
  step compile-perf-1003 swiftc -parse-as-library ${PERF_STORE_SWIFT_FLAGS:-} -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite "${LLAMA[@]}" \
    scripts/perf-1003-checks.swift $(objs MemoryCore HistoryCore PrivacyPolicy MemoryUI) -lc++ -lsqlite3 -o "$OUT/perf-1003"
  step perf-1003 env DD_CHECK_OUT="$OUT" "$OUT/perf-1003"
fi
# gold/r2-store-perf: launch prepares the history (repair, time indexes, website typing settle) off the main thread.
if [ -f scripts/launch-preparation-checks.swift ]; then
  step compile-launch-preparation swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite \
    scripts/launch-preparation-checks.swift $(objs MemoryCore HistoryCore PrivacyPolicy MemoryUI) -o "$OUT/launch-preparation"
  step launch-preparation "$OUT/launch-preparation"
fi
if [ -f scripts/store-main-thread-source-checks.py ]; then
  step store-main-thread-source-py python3 scripts/store-main-thread-source-checks.py -v
fi
if [ -f scripts/store-main-thread-checks.swift ]; then
  SMTSRC=$OUT/src/store-main-thread-app; rm -rf "$SMTSRC"; mkdir -p "$SMTSRC" "$OUT/store-main-thread-home/Library/Preferences" "$OUT/store-main-thread-dd"
  for f in Sources/MacMemApp/*.swift; do python3 "$C/copy-check-source.py" "$f" "$R" > "$SMTSRC/$(basename "$f")"; done
  sed -e "s#/private/tmp/daydream-#$R/daydream-#g" scripts/store-main-thread-checks.swift > "$OUT/src/store-main-thread-checks.swift"
  step compile-store-main-thread swiftc -D DEVELOPMENT_SOURCE_CHECKS -parse-as-library ${PERF_STORE_SWIFT_FLAGS:-} -module-cache-path "$I/modcache" -I "$B/Modules" \
    -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$B/CLlamaBridge.build/module.modulemap" \
    -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include" -F "$B" -framework Sparkle -Xlinker -rpath -Xlinker "$B" \
    "$SMTSRC"/*.swift "$OUT/src/store-main-thread-checks.swift" \
    $(for t in MemoryCore MemoryUI HistoryCore CoreIntegration PrivacyPolicy BrowserBridge WriterBackend CLlamaBridge BackupRestore; do [ -d "$B/$t.build" ] && ls "$B/$t.build/"*.o; done) \
    -lc++ -o "$OUT/store-main-thread"
  step store-main-thread env HOME="$OUT/store-main-thread-home" CFFIXED_USER_HOME="$OUT/store-main-thread-home" DD_CHECK_OUT="$OUT/store-main-thread-dd" "$OUT/store-main-thread"
fi
step privacy-build swift build --jobs 3 --package-path PrivacyPolicy --scratch-path "$BUILD-pp" --disable-automatic-resolution --product PrivacyChecks
step PrivacyChecks "$BUILD-pp/debug/PrivacyChecks"
# scripts/daydream-core-source-checks.py steps (its fixed /private/tmp roots and
# dist/ manifest are replaced by scratch paths; same compile lists).
for name in memory-controls onboarding-staging; do
  step compile-$name swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite \
    scripts/$name-checks.swift $(objs MemoryCore HistoryCore PrivacyPolicy) -o "$OUT/$name"
  step $name "$OUT/$name"
done
# Safe typing (vault slice): crypto, raw SQLite rows and raw file bytes, in-memory keys only.
step compile-typed-store swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite \
  scripts/typed-store-checks.swift $(objs MemoryCore HistoryCore PrivacyPolicy) -o "$OUT/typed-store"
step typed-store "$OUT/typed-store"
# claude/summary-1003 (owner decision 2026-10-03): "Let AI apps read what you typed" (bridge, moment_details, typed search).
if [ -f scripts/ai-read-typed-checks.swift ]; then
  step compile-ai-read-typed swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite \
    scripts/ai-read-typed-checks.swift $(objs MemoryCore HistoryCore PrivacyPolicy) -lsqlite3 -o "$OUT/ai-read-typed"
  step ai-read-typed env AI_READ_CHECK_ROOT="$R" DAYDREAM_TEST_CLI="$B/mac-mem" "$OUT/ai-read-typed"
fi
# gold/typing-chrome: a seeded synthetic fuzz of secret shapes through TypingSession and TypedSecretScrubber
# (API keys, cards, passwords; corrections, caret moves, dead keys, paste, input methods, unit splits). No real secret.
if [ -f scripts/typed-secret-fuzz-checks.swift ]; then
  step compile-typed-secret-fuzz swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite \
    scripts/typed-secret-fuzz-checks.swift $(objs MemoryCore HistoryCore PrivacyPolicy) -o "$OUT/typed-secret-fuzz"
  step typed-secret-fuzz "$OUT/typed-secret-fuzz"
fi
# 237f6fb current exact byte contract, alongside legacy late-key fixtures.
if [ -f scripts/typed-boundary-space-checks.swift ]; then
  step compile-typed-boundary-space swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite \
    PrivacyPolicy/Checks/TypingChecks.swift scripts/typed-boundary-space-checks.swift $(objs MemoryCore HistoryCore PrivacyPolicy) -o "$OUT/typed-boundary-space"
  step typed-boundary-space "$OUT/typed-boundary-space" "$OUT/typed-boundary-space-fixture"
fi
if [ -f scripts/search-app-label-checks.swift ]; then
  step compile-search-app-label swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite \
    scripts/search-app-label-checks.swift $(objs MemoryCore HistoryCore PrivacyPolicy) -o "$OUT/search-app-label"
  step search-app-label "$OUT/search-app-label"
fi
# W0 (typing-all SPEC-LATER section 2): launch wiring from the app's own files
# (vault attach, build 4 settle, hourly expiry), in-memory keys, fake scheduler.
step compile-typed-launch swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite \
  Sources/MacMemApp/TypedTextExpiryTimer.swift Sources/MacMemApp/TypingHotkey.swift Sources/MacMemApp/TypingModel.swift \
  scripts/typed-launch-checks.swift $(objs MemoryCore HistoryCore PrivacyPolicy) -o "$OUT/typed-launch"
step typed-launch "$OUT/typed-launch"
# gold/capture-input (golden 5 G58, G74a): typing's unlock is heard while DayDream is in the background; one
# end-of-pause refresh and one toast clear wait at a time. Own notification names, in-memory keys, recorded scheduler.
if [ -f scripts/typing-unlock-delivery-checks.swift ]; then
  step compile-typing-unlock-delivery swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite \
    Sources/MacMemApp/TypedTextExpiryTimer.swift Sources/MacMemApp/TypingHotkey.swift Sources/MacMemApp/TypingModel.swift \
    scripts/typing-unlock-delivery-checks.swift $(objs MemoryCore HistoryCore PrivacyPolicy) -o "$OUT/typing-unlock-delivery"
  step typing-unlock-delivery "$OUT/typing-unlock-delivery"
fi
step typing-wiring-source-py python3 scripts/typing-wiring-source-checks.py -v
CAPTURE=$(python3 -c "import re;s=open('scripts/daydream-core-source-checks.py').read();print(' '.join('Sources/MacMemApp/%s.swift'%n for n in eval(re.search(r'capture=(\[[^\]]*\])',s).group(1))))")
python3 "$C/copy-check-source.py" Sources/MacMemApp/Coordinator.swift "$R" > "$OUT/src/headless-Coordinator.swift"
CAPTURE=${CAPTURE/Sources\/MacMemApp\/Coordinator.swift/$OUT\/src\/headless-Coordinator.swift}
echo "core-source capture list: $CAPTURE" > "$OUT/core-source-capture-list.txt"
step compile-production-capture swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite "${LLAMA[@]}" \
  $CAPTURE scripts/production-event-capture-checks.swift $(objs "${APPDEPS[@]}") -lc++ -o "$OUT/production-capture"
step production-capture "$OUT/production-capture"
# fix/lock-resume: a failed capture write never stops recording for good (Coordinator.captureFailed, the heartbeat,
# EventCapture.onStopped), on a synthetic store; EventCapture is created and stopped, never started.
if [ -f scripts/recording-fault-checks.swift ]; then
  step compile-recording-fault swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite "${LLAMA[@]}" \
    $CAPTURE scripts/recording-fault-checks.swift $(objs "${APPDEPS[@]}") -lc++ -o "$OUT/recording-fault"
  step recording-fault "$OUT/recording-fault"
fi
# gold/save-path: nothing that passes in a moment stops recording or saving for good (busy unit, in-process readers,
# momentary SQLite codes, one false permission read, busy preference save). Synthetic stores; a --hold child of the
# check binary holds a read lock. No event tap, permission read, Keychain or network.
if [ -f scripts/save-path-checks.swift ]; then
  step compile-save-path swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite "${LLAMA[@]}" \
    $CAPTURE Sources/MacMemApp/PreferenceAutosave.swift Sources/MacMemApp/PreferenceProblem.swift Sources/MacMemApp/WakeResume.swift \
    Sources/MacMemApp/LaunchLocation.swift scripts/save-path-checks.swift $(objs "${APPDEPS[@]}") -lc++ -o "$OUT/save-path"
  step save-path "$OUT/save-path"
fi
# gold/capture-input (golden 5 G3, G7, G41, G58, G8/G74b pins): the input tap macOS turns off, keys handled late,
# app notifications registered again, the input-source listener. Synthetic stores, fake clock; EventCapture is never
# started (the tap and AX registration are seams). Run from the tree root (the pins read its sources).
if [ -f scripts/capture-input-checks.swift ]; then
  step compile-capture-input swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite "${LLAMA[@]}" \
    $CAPTURE scripts/capture-input-checks.swift $(objs "${APPDEPS[@]}") -lc++ -o "$OUT/capture-input"
  step capture-input "$OUT/capture-input"
fi
step compile-native-witness swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" \
  Sources/MacMemApp/NativeFocusWitness.swift scripts/native-focus-witness-checks.swift $(objs PrivacyPolicy) -o "$OUT/native-witness"
step native-witness "$OUT/native-witness"
step compile-typing-choice swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite \
  scripts/onboarding-typing-choice-checks.swift $(objs MemoryCore HistoryCore PrivacyPolicy) -o "$OUT/typing-choice"
step typing-choice "$OUT/typing-choice"
step compile-onboarding-flow swiftc -parse-as-library -module-cache-path "$I/modcache" \
  Sources/MacMemApp/DaydreamOnboardingState.swift scripts/onboarding-flow-checks.swift -o "$OUT/onboarding-flow"
step onboarding-flow "$OUT/onboarding-flow"
step compile-core-adapter swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite "${LLAMA[@]}" \
  adapters/CoreWriterBinding.swift adapters/CoreCaptureBinding.swift scripts/core-adapter-checks.swift \
  $(objs MemoryCore HistoryCore WriterBackend PrivacyPolicy BrowserBridge CLlamaBridge) -lc++ -o "$OUT/core-adapter"
step core-adapter "$OUT/core-adapter"
# summaries/v3 (launch/candidate): the level writer loads the shared runtime only while it writes, and falls back to code.
step compile-level-binding swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite "${LLAMA[@]}" \
  adapters/LevelWriterBinding.swift scripts/level-binding-checks.swift \
  $(objs MemoryCore HistoryCore WriterBackend PrivacyPolicy BrowserBridge CLlamaBridge) -lc++ -o "$OUT/level-binding"
step level-binding "$OUT/level-binding"
step compile-preference-save swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite \
  scripts/preference-save-checks.swift $(objs MemoryCore HistoryCore PrivacyPolicy) -o "$OUT/preference-save"
step preference-save "$OUT/preference-save"
# gold/connections-storage: search reaches the month without the index (G27), a newer history is refused and attachment
# tidying never fails a committed change (G61, G62), a damaged history is repaired (G45).
for name in search-depth search-prefilter search-fallback-coverage store-format store-integrity; do
  [ -f scripts/$name-checks.swift ] || continue
  step compile-$name swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite \
    scripts/$name-checks.swift $(objs MemoryCore HistoryCore PrivacyPolicy) -o "$OUT/$name"
  step $name "$OUT/$name"
done
# gold/connections-storage (G29, critic extra 5): a backup of the whole history, through the real helper.
if [ -f scripts/backup-depth-checks.swift ]; then
  step compile-backup-depth swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite \
    scripts/backup-depth-checks.swift $(objs MemoryCore HistoryCore PrivacyPolicy BackupRestore) -o "$OUT/backup-depth"
  step backup-depth "$OUT/backup-depth" "$B/mac-mem-backup"
fi
# gold/connections-storage: the container's own checks (their "oversize" follows the new limit).
if [ -f BackupRestore/Tests/NativeChecks.swift ]; then
  step compile-backup-native swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite \
    BackupRestore/Tests/NativeChecks.swift $(objs MemoryCore HistoryCore PrivacyPolicy BackupRestore) -o "$OUT/backup-native"
  mkdir -p BackupRestore/.build; step backup-native "$OUT/backup-native" "$B/mac-mem-backup"
fi
# Cloud summaries never get Chrome pages: both compile the actual app WriterScheduling.swift.
for name in writer-retention cloud-scope; do
  step compile-$name swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite "${LLAMA[@]}" \
    Sources/MacMemApp/WriterScheduling.swift scripts/$name-checks.swift $(objs "${APPDEPS[@]}") -lc++ -o "$OUT/$name"
  step $name "$OUT/$name"
done
# gold/notes: notes and summary-writer regressions (G15 G18-G26 G52 G63 G73 extra6, status latches).
# Synthetic stores under $OUT only (NOTES_CHECK_ROOT: the writer's ledger folder must not sit under a symlink like /var).
if [ -f scripts/notes-golden-checks.swift ]; then
  step compile-notes-golden swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite "${LLAMA[@]}" \
    adapters/CoreWriterBinding.swift Sources/MacMemApp/WriterScheduling.swift scripts/notes-golden-checks.swift \
    $(objs "${APPDEPS[@]}") -lc++ -o "$OUT/notes-golden"
  mkdir -p "$OUT/notes-fixtures"
  step notes-golden env HOME="$OUT/notes-home" CFFIXED_USER_HOME="$OUT/notes-home" NOTES_CHECK_ROOT="$OUT/notes-fixtures" "$OUT/notes-golden"
fi
if [ -f scripts/notes-writer-checks.swift ]; then
  step compile-notes-writer swiftc -parse-as-library -target arm64-apple-macosx13.0 -module-cache-path "$I/modcache" \
    -I "$B/Modules" -I Sources/CSQLite -I WriterBackend/Sources/CLlamaBridge/include "${LLAMA[@]}" \
    Sources/MacMemApp/WriterIntegration.swift Sources/MacMemApp/WriterScheduling.swift Sources/MacMemApp/WriterPreferences.swift Sources/MacMemApp/LevelPower.swift adapters/CoreWriterBinding.swift adapters/LevelWriterBinding.swift \
    scripts/notes-writer-checks.swift "$B"/WriterBackend.build/*.swift.o "$B"/CLlamaBridge.build/WriterLlama.cpp.o \
    $(objs MemoryCore HistoryCore MemoryUI CoreIntegration PrivacyPolicy BrowserBridge) -lsqlite3 -lc++ -o "$OUT/notes-writer"
  mkdir -p "$OUT/notes-fixtures"
  step notes-writer env HOME="$OUT/notes-home" CFFIXED_USER_HOME="$OUT/notes-home" NOTES_CHECK_ROOT="$OUT/notes-fixtures" "$OUT/notes-writer"
fi
# fix/sx-engine-battery: the writer's cadence on a busy synthetic day (power, battery, an AI app, Low Power Mode,
# catch-up) and its state machine (phases, download, Off, cloud failures), both through the real WriterIntegration with
# a fake model, installer and OpenRouter. No network, keys, model or capture. Then the WriterBackend package checks.
WRITERSRC="Sources/MacMemApp/WriterIntegration.swift Sources/MacMemApp/WriterScheduling.swift Sources/MacMemApp/WriterPreferences.swift Sources/MacMemApp/LevelPower.swift adapters/CoreWriterBinding.swift adapters/LevelWriterBinding.swift"
# fix/writing-forever: writer-spin (fix/perf7) joins them (same recipe).
for name in writer-cadence writer-state writer-spin; do
  if [ -f scripts/$name-checks.swift ]; then
    step compile-$name swiftc -parse-as-library -target arm64-apple-macosx13.0 -module-cache-path "$I/modcache" \
      -I "$B/Modules" -I Sources/CSQLite -I WriterBackend/Sources/CLlamaBridge/include "${LLAMA[@]}" \
      $WRITERSRC scripts/$name-checks.swift "$B"/WriterBackend.build/*.swift.o "$B"/CLlamaBridge.build/WriterLlama.cpp.o \
      $(objs MemoryCore HistoryCore MemoryUI CoreIntegration PrivacyPolicy BrowserBridge) -lsqlite3 -lc++ -o "$OUT/$name"
    mkdir -p "$OUT/$name-home" "$OUT/$name-root"
    step $name env HOME="$OUT/$name-home" CFFIXED_USER_HOME="$OUT/$name-home" CADENCE_ROOT="$OUT/$name-root" STATE_CHECK_ROOT="$OUT/$name-root" nice "$OUT/$name"
  fi
done
step compile-writer-app-integration swiftc -parse-as-library -target arm64-apple-macosx13.0 -module-cache-path "$I/modcache" \
  -I "$B/Modules" -I Sources/CSQLite -I WriterBackend/Sources/CLlamaBridge/include "${LLAMA[@]}" \
  $WRITERSRC WriterBackend/AppIntegrationChecks/main.swift "$B"/WriterBackend.build/*.swift.o "$B"/CLlamaBridge.build/WriterLlama.cpp.o \
  $(objs MemoryCore HistoryCore MemoryUI CoreIntegration PrivacyPolicy BrowserBridge) -lsqlite3 -lc++ -o "$OUT/writer-app-integration"
mkdir -p "$OUT/writer-app-home"
step writer-app-integration env HOME="$OUT/writer-app-home" CFFIXED_USER_HOME="$OUT/writer-app-home" "$OUT/writer-app-integration"
step wb-package-build swift build --jobs 3 --package-path WriterBackend --scratch-path "$I/build-wb" --disable-automatic-resolution
for name in WriterChecks CloudActivationChecks AdapterChecks InstallationChecks PromptChecks; do
  step wb-$name bash -c "cd WriterBackend && '$I/build-wb/debug/$name'"
done
step compile-wb-scheduler swiftc -parse-as-library -module-cache-path "$I/modcache" WriterBackend/SchedulerChecks/Support.swift \
  WriterBackend/Sources/WriterBackend/PendingNoteScheduler.swift WriterBackend/SchedulerChecks/main.swift -o "$OUT/wb-scheduler"
step wb-scheduler "$OUT/wb-scheduler"
step compile-wb-batch swiftc -parse-as-library -target arm64-apple-macosx13.0 -module-cache-path "$I/modcache" -I "$B/Modules" \
  -I WriterBackend/Sources/CLlamaBridge/include "${LLAMA[@]}" WriterBackend/BatchChecks/main.swift \
  "$B"/WriterBackend.build/*.swift.o "$B"/CLlamaBridge.build/WriterLlama.cpp.o -lc++ -o "$OUT/wb-batch"
step wb-batch "$OUT/wb-batch"
step compile-download-time swiftc -parse-as-library -module-cache-path "$I/modcache" Sources/MemoryUI/DownloadTimeEstimate.swift \
  scripts/download-time-checks.swift -o "$OUT/download-time"
step download-time "$OUT/download-time"
# notes-quality: owner-style moment notes (who and what for every send, no filler, code notes with no model load for a
# window, social leads, title cleaning shared with threads, no "Also" bullets). Synthetic requests; no model or store.
if [ -f scripts/notes-quality-checks.swift ]; then
  step compile-notes-quality swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite "${LLAMA[@]}" \
    scripts/notes-quality-checks.swift $(objs MemoryCore HistoryCore WriterBackend PrivacyPolicy CLlamaBridge) -lc++ -o "$OUT/notes-quality"
  step notes-quality "$OUT/notes-quality"
fi
# fix/summary-sends (QF-13, QF-14, QF-15): sends kept in word-less moments, writer/core claim agreement, `read` send state.
if [ -f scripts/summary-sends-checks.swift ]; then
  step compile-summary-sends swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite "${LLAMA[@]}" \
    scripts/summary-sends-checks.swift $(objs MemoryCore HistoryCore WriterBackend PrivacyPolicy CLlamaBridge) -lc++ -o "$OUT/summary-sends"
  step summary-sends "$OUT/summary-sends"
fi
# claude/ready-1002: one fallback line per distinct sentence; terminal titles without tool status glyphs or bare shells.
# claude/summary-1003: terminal and AI-tool summaries (Claude Code prompts, shell commands by purpose, no filler beside real lines).
if [ -f scripts/summary-terminal-checks.swift ]; then
  step compile-summary-terminal swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite "${LLAMA[@]}" \
    scripts/summary-terminal-checks.swift $(objs MemoryCore HistoryCore WriterBackend PrivacyPolicy CLlamaBridge) -lc++ -o "$OUT/summary-terminal"
  step summary-terminal "$OUT/summary-terminal"
fi
# claude/summary-fail-1003: a failed Summarize Now names Settings only when summaries are off or broken; the card's
# Summarize Now states (pending, working with one sweep, done, failed); the pending footer; one day-card entry per conversation.
if [ -f scripts/summary-fail-checks.swift ]; then
  step compile-summary-fail swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite \
    scripts/summary-fail-checks.swift $(objs MemoryCore HistoryCore MemoryUI PrivacyPolicy) -lsqlite3 -lc++ -o "$OUT/summary-fail"
  step summary-fail "$OUT/summary-fail"
fi
if [ -f scripts/summary-ready-checks.swift ]; then
  step compile-summary-ready swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite "${LLAMA[@]}" \
    scripts/summary-ready-checks.swift $(objs MemoryCore HistoryCore WriterBackend PrivacyPolicy CLlamaBridge) -lc++ -o "$OUT/summary-ready"
  step summary-ready "$OUT/summary-ready"
fi
# claude/day-review-1003: the Today card's day review (rank groups, hysteresis, clauses, quotes, Forget, model failure).
# The owner lane runs it again with Messages typing (owner-lane.sh).
if [ -f scripts/day-review-checks.swift ]; then
  step compile-day-review swiftc -parse-as-library -target arm64-apple-macosx14.0 -module-cache-path "$I/modcache" \
    -I "$B/Modules" -I Sources/CSQLite -I WriterBackend/Sources/CLlamaBridge/include "${LLAMA[@]}" \
    scripts/day-review-checks.swift "$B"/WriterBackend.build/*.swift.o "$B"/CLlamaBridge.build/WriterLlama.cpp.o \
    $(objs MemoryCore HistoryCore MemoryUI CoreIntegration PrivacyPolicy BrowserBridge) -lsqlite3 -lc++ -o "$OUT/day-review"
  mkdir -p "$OUT/day-review-root" "$OUT/day-review-home/Library/Preferences"
  step day-review env HOME="$OUT/day-review-home" CFFIXED_USER_HOME="$OUT/day-review-home" DAY_REVIEW_ROOT="$OUT/day-review-root" nice "$OUT/day-review"
fi
# gold/notes: G24 lives in the existing action-audit check (its 5000-action assertion now expects the whole day).
if [ -f scripts/action-audit-checks.swift ]; then
  step compile-action-audit swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite \
    scripts/action-audit-checks.swift $(objs MemoryCore HistoryCore PrivacyPolicy) -o "$OUT/action-audit"
  step action-audit "$OUT/action-audit"
fi
# scripts/run-*.sh equivalents (they cd to another checkout and write /private/tmp/daydream-*).
# int-1003: cc-label-1003's TerminalToolProcesses.swift is what Coordinator asks for a terminal's AI tool.
APPFILES="Sources/MacMemApp/BrowserProviderResolver.swift Sources/MacMemApp/BrowserCaptureTransport.swift Sources/MacMemApp/BrowserCaptureReceipt.swift Sources/MacMemApp/NativeCaptureReceipts.swift Sources/MacMemApp/NativeFocusWitness.swift Sources/MacMemApp/Coordinator.swift Sources/MacMemApp/EventCapture.swift Sources/MacMemApp/MessagesComposer.swift Sources/MacMemApp/AccessibilitySnapshot.swift Sources/MacMemApp/ChromeModeReader.swift Sources/MacMemApp/ChromeEventSender.swift Sources/MacMemApp/ChromePageRecorder.swift Sources/MacMemApp/NativeTypingRoute.swift Sources/MacMemApp/TypingHotkey.swift Sources/MacMemApp/WebTypingRoute.swift Sources/MacMemApp/TerminalToolProcesses.swift"
for check in browser-app-0227 browser-provider-0240; do
  src=$(relocated $check-checks.swift)
  step compile-$check swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite "${LLAMA[@]}" \
    $APPFILES "$src" $(objs "${APPDEPS[@]}") -Xlinker -dead_strip -lc++ -o "$OUT/$check"
  step $check "$OUT/$check"
done
src=$(relocated app-preferences-search-0132-checks.swift)
step compile-app-bindings-0132 swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite "${LLAMA[@]}" \
  Sources/MacMemApp/PreferenceAutosave.swift Sources/MacMemApp/AppSearchBinding.swift $APPFILES "$src" $(objs "${APPDEPS[@]}") -Xlinker -dead_strip -lc++ -o "$OUT/app-bindings-0132"
step app-bindings-0132 "$OUT/app-bindings-0132"
src=$(relocated native-receipt-0053-checks.swift)
step compile-native-receipt-0053 swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite "${LLAMA[@]}" \
  $APPFILES "$src" $(objs "${APPDEPS[@]}") -Xlinker -dead_strip -lc++ -o "$OUT/native-receipt-0053"
step native-receipt-0053 "$OUT/native-receipt-0053"
step browser-boundary-py python3 scripts/check_browser_boundary.py -v
# Safe typing H (access slice): claim wording in app strings and docs stays literally true.
step typed-claim-checks python3 scripts/typed-claim-checks.py -v
step native-coverage-mjs "${NODE_BIN:-node}" --test BrowserBridge/fixtures/native-coverage-checks.mjs
step harness-source-py python3 tools/chrome-device-test/check_harness_source.py -v
step qa-harness-boundary-py python3 scripts/check-qa-harness-boundary.py -v
step harness-build swift build --jobs 3 --package-path tools/chrome-device-test --scratch-path "$I/harness-build" --disable-automatic-resolution
step harness-selftest "$I/harness-build/debug/chrome-device-test-selftest"
# The public MacMem binary must hold none of the private Chrome typing types.
nm "$B/MacMem" > "$OUT/MacMem.nm" 2>&1
# All 15 PRIVATE_SYMBOLS, read from scripts/chrome-typing-checks.py so the two lists never drift.
PRIVATE_RE=$(python3 -c "import re;s=open('scripts/chrome-typing-checks.py').read();l=eval(re.search(r'PRIVATE_SYMBOLS = (\[[^\]]*\])',s).group(1));assert len(l)==15,l;print('|'.join(l))")
echo "$PRIVATE_RE" > "$OUT/private-symbols.txt"
step public-nm-no-chrome-typing bash -c "[ \$(tr '|' '\n' < '$OUT/private-symbols.txt' | wc -l) -eq 15 ] && ! grep -E '$PRIVATE_RE' '$OUT/MacMem.nm' && echo PASS none of the 15 private Chrome typing symbols in public MacMem"
# Chrome page history is public: the public MacMem must carry its reader and sender.
step public-nm-has-page-history bash -c "grep -q ChromePageProbe '$OUT/MacMem.nm' && grep -q ChromeEventSender '$OUT/MacMem.nm' && echo PASS public MacMem has Chrome page history: ChromePageProbe and ChromeEventSender"
# Public + private (-DDAYDREAM_CHROME_TYPING) builds, synthetic checks, parse checks, nm.
step chrome-typing-checks-py python3 scripts/chrome-typing-checks.py --scratch "$I/ctc"
step private-build swift build --jobs 3 --scratch-path "$I/ctc/build-private" --disable-automatic-resolution -Xswiftc -DDAYDREAM_CHROME_TYPING
# The private build runs the same production EventCapture checks: Chrome typing
# is compiled in but not wired, so behaviour must be unchanged.
PB=$I/ctc/build-private/arm64-apple-macosx/debug
pobjs() { for t in "$@"; do ls "$PB/$t.build/"*.o; done; }
step compile-production-capture-private swiftc -parse-as-library -DDAYDREAM_CHROME_TYPING -module-cache-path "$I/modcache" -I "$PB/Modules" -I Sources/CSQLite \
  -Xcc -fmodule-map-file="$PB/CLlamaBridge.build/module.modulemap" $CAPTURE scripts/production-event-capture-checks.swift $(pobjs "${APPDEPS[@]}") -lc++ -o "$OUT/production-capture-private"
step production-capture-private "$OUT/production-capture-private"
nm "$OUT/production-capture-private" > "$OUT/production-capture-private.nm" 2>&1
step private-nm-has-witness bash -c "grep -q ChromeTypingWitness '$OUT/production-capture-private.nm' && echo PASS private capture build compiles the Chrome witness"
# Review C7: the release MacMem (what the public ships) carries no private
# Chrome typing symbol or string either.
step release-build swift build --jobs 3 -c release --product MacMem --scratch-path "$I/build-release" --disable-automatic-resolution
step release-scan python3 scripts/chrome-typing-checks.py --binary "$I/build-release/release/MacMem"
# Safe typing E (categories slice): the legal gate. Source rules, and a probe
# linked against the RELEASE-compiled PrivacyPolicy objects: gate false, and
# the allowed set with every category on is exactly Notes and TextEdit.
step typing-release-gate python3 scripts/typing-release-gate-checks.py -v --release "$I/build-release/release" --tmp "$I/tmp"
step public-debug-scan python3 scripts/chrome-typing-checks.py --binary "$B/MacMem"
# Owner switch (typing-all SPEC-LATER section 3). The owner build passes both
# flags, the way scripts/package.sh does with DAYDREAM_OWNER_TYPING=1.
OWNERFLAGS=(-Xswiftc -DDAYDREAM_OWNER_TYPING -Xswiftc -DDAYDREAM_CHROME_TYPING)
# public-typing/v1 (owner decision 2026-09-25): every release stage compiles these flags, so the owner
# build IS the shipped build. It builds every product (not only MacMem) so the product checks, the
# PrivacyPolicy checks and the CLI checks below also run against the flagged code that ships. The
# unflagged steps above stay: they pin the plain `swift build` a contributor gets.
step owner-build swift build --jobs 3 --scratch-path "$I/build-owner" --disable-automatic-resolution "${OWNERFLAGS[@]}"
OB=$I/build-owner/arm64-apple-macosx/debug
step owner-MacMemChecks "$OB/MacMemChecks"
step owner-ProductionBindingChecks "$OB/ProductionBindingChecks"
step owner-privacy-build swift build --jobs 3 --package-path PrivacyPolicy --scratch-path "$BUILD-pp-owner" --disable-automatic-resolution --product PrivacyChecks "${OWNERFLAGS[@]}"
step owner-PrivacyChecks "$BUILD-pp-owner/debug/PrivacyChecks"
oobjs() { for t in "$@"; do ls "$OB/$t.build/"*.o; done; }
step compile-owner-production-capture swiftc -parse-as-library -DDAYDREAM_OWNER_TYPING -DDAYDREAM_CHROME_TYPING -module-cache-path "$I/modcache" -I "$OB/Modules" -I Sources/CSQLite \
  -Xcc -fmodule-map-file="$OB/CLlamaBridge.build/module.modulemap" $CAPTURE scripts/production-event-capture-checks.swift $(oobjs "${APPDEPS[@]}") -lc++ -o "$OUT/owner-production-capture"
step owner-production-capture "$OUT/owner-production-capture"
# claude/chrome-offmain-1003: website typing's route off the main thread saves byte-identical rows (a synthetic replay),
# and the owner model's main-thread time per allowed Chrome key (BENCH lines in the log).
if [ -f scripts/chrome-offmain-checks.swift ]; then
  step compile-owner-chrome-offmain swiftc -parse-as-library -DDAYDREAM_OWNER_TYPING -DDAYDREAM_CHROME_TYPING -module-cache-path "$I/modcache" -I "$OB/Modules" -I Sources/CSQLite \
    -Xcc -fmodule-map-file="$OB/CLlamaBridge.build/module.modulemap" $CAPTURE scripts/chrome-offmain-checks.swift $(oobjs "${APPDEPS[@]}") -lc++ -o "$OUT/owner-chrome-offmain"
  step owner-chrome-offmain env CHROME_OFFMAIN_DUMP="$OUT/chrome-offmain-dump" "$OUT/owner-chrome-offmain"
fi
if [ -f scripts/ai-read-typed-checks.swift ]; then
  step compile-owner-ai-read-typed swiftc -parse-as-library -DDAYDREAM_OWNER_TYPING -DDAYDREAM_CHROME_TYPING -module-cache-path "$I/modcache" -I "$OB/Modules" -I Sources/CSQLite \
    scripts/ai-read-typed-checks.swift $(oobjs MemoryCore HistoryCore PrivacyPolicy) -lsqlite3 -o "$OUT/owner-ai-read-typed"
  step owner-ai-read-typed env AI_READ_CHECK_ROOT="$R" DAYDREAM_TEST_CLI="$OB/mac-mem" "$OUT/owner-ai-read-typed"
fi
# fix/typing-e2e: typing is really on and reaches both writers (fresh install, upgrades from test 4 and test 5): setup's
# Continue through TypingModel, typing through CoreCaptureBinding and the website typing session, the writers' views.
if [ -f scripts/typing-e2e-checks.swift ]; then
  step compile-typing-e2e swiftc -parse-as-library -DDAYDREAM_OWNER_TYPING -DDAYDREAM_CHROME_TYPING -module-cache-path "$I/modcache" -I "$OB/Modules" -I Sources/CSQLite \
    -Xcc -fmodule-map-file="$OB/CLlamaBridge.build/module.modulemap" $CAPTURE Sources/MacMemApp/TypedTextExpiryTimer.swift Sources/MacMemApp/TypingModel.swift \
    scripts/typing-e2e-checks.swift $(oobjs "${APPDEPS[@]}") -lc++ -o "$OUT/typing-e2e"
  step typing-e2e env TYPING_E2E_EVIDENCE="$OUT/typing-e2e-evidence.txt" "$OUT/typing-e2e"
fi
if [ -f scripts/typed-secret-fuzz-checks.swift ]; then # gold/typing-chrome, flagged like the release build
  step compile-owner-typed-secret-fuzz swiftc -parse-as-library -DDAYDREAM_OWNER_TYPING -DDAYDREAM_CHROME_TYPING -module-cache-path "$I/modcache" -I "$OB/Modules" -I Sources/CSQLite \
    scripts/typed-secret-fuzz-checks.swift $(oobjs MemoryCore HistoryCore PrivacyPolicy) -o "$OUT/owner-typed-secret-fuzz"
  step owner-typed-secret-fuzz "$OUT/owner-typed-secret-fuzz"
fi
if [ -f scripts/recording-fault-checks.swift ]; then # fix/lock-resume, flagged like the release build
  step compile-owner-recording-fault swiftc -parse-as-library -DDAYDREAM_OWNER_TYPING -DDAYDREAM_CHROME_TYPING -module-cache-path "$I/modcache" -I "$OB/Modules" -I Sources/CSQLite \
    -Xcc -fmodule-map-file="$OB/CLlamaBridge.build/module.modulemap" $CAPTURE scripts/recording-fault-checks.swift $(oobjs "${APPDEPS[@]}") -lc++ -o "$OUT/owner-recording-fault"
  step owner-recording-fault "$OUT/owner-recording-fault"
fi
if [ -f scripts/save-path-checks.swift ]; then # gold/save-path, flagged like the release build
  step compile-owner-save-path swiftc -parse-as-library -DDAYDREAM_OWNER_TYPING -DDAYDREAM_CHROME_TYPING -module-cache-path "$I/modcache" -I "$OB/Modules" -I Sources/CSQLite \
    -Xcc -fmodule-map-file="$OB/CLlamaBridge.build/module.modulemap" $CAPTURE Sources/MacMemApp/PreferenceAutosave.swift Sources/MacMemApp/PreferenceProblem.swift \
    Sources/MacMemApp/WakeResume.swift Sources/MacMemApp/LaunchLocation.swift scripts/save-path-checks.swift $(oobjs "${APPDEPS[@]}") -lc++ -o "$OUT/owner-save-path"
  step owner-save-path "$OUT/owner-save-path"
fi
if [ -f scripts/capture-input-checks.swift ]; then # gold/capture-input, flagged like the release build
  step compile-owner-capture-input swiftc -parse-as-library -DDAYDREAM_OWNER_TYPING -DDAYDREAM_CHROME_TYPING -module-cache-path "$I/modcache" -I "$OB/Modules" -I Sources/CSQLite \
    -Xcc -fmodule-map-file="$OB/CLlamaBridge.build/module.modulemap" $CAPTURE scripts/capture-input-checks.swift $(oobjs "${APPDEPS[@]}") -lc++ -o "$OUT/owner-capture-input"
  step owner-capture-input "$OUT/owner-capture-input"
fi
if [ -f scripts/typing-unlock-delivery-checks.swift ]; then # gold/capture-input, flagged like the release build
  step compile-owner-typing-unlock-delivery swiftc -parse-as-library -DDAYDREAM_OWNER_TYPING -DDAYDREAM_CHROME_TYPING -module-cache-path "$I/modcache" -I "$OB/Modules" -I Sources/CSQLite \
    Sources/MacMemApp/TypedTextExpiryTimer.swift Sources/MacMemApp/TypingHotkey.swift Sources/MacMemApp/TypingModel.swift \
    scripts/typing-unlock-delivery-checks.swift $(oobjs MemoryCore HistoryCore PrivacyPolicy) -o "$OUT/owner-typing-unlock-delivery"
  step owner-typing-unlock-delivery "$OUT/owner-typing-unlock-delivery"
fi
if [ -f scripts/capture-input-model-checks.swift ]; then # gold/capture-input, flagged like the release build
  OCIMSRC=$OUT/src/owner-capture-input-app; rm -rf "$OCIMSRC"; mkdir -p "$OCIMSRC"
  for f in Sources/MacMemApp/*.swift; do python3 "$C/copy-check-source.py" "$f" "$R" > "$OCIMSRC/$(basename "$f")"; done
  sed -e "s#/private/tmp/daydream-#$R/daydream-#g" scripts/capture-input-model-checks.swift > "$OUT/src/owner-capture-input-model-checks.swift"
  OCIMHOME=$OUT/owner-capture-input-model-home; OCIMDD=$OUT/owner-capture-input-model-dd; mkdir -p "$OCIMHOME/Library/Preferences" "$OCIMDD"
  step compile-owner-capture-input-model swiftc -D DEVELOPMENT_SOURCE_CHECKS -DDAYDREAM_OWNER_TYPING -DDAYDREAM_CHROME_TYPING -parse-as-library -module-cache-path "$I/modcache" -I "$OB/Modules" \
    -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$OB/CLlamaBridge.build/module.modulemap" \
    -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include" -F "$OB" -framework Sparkle -Xlinker -rpath -Xlinker "$OB" \
    "$OCIMSRC"/*.swift "$OUT/src/owner-capture-input-model-checks.swift" \
    $(for t in MemoryCore MemoryUI HistoryCore CoreIntegration PrivacyPolicy BrowserBridge WriterBackend CLlamaBridge BackupRestore; do [ -d "$OB/$t.build" ] && ls "$OB/$t.build/"*.o; done) \
    -lc++ -o "$OUT/owner-capture-input-model"
  step owner-capture-input-model env HOME="$OCIMHOME" CFFIXED_USER_HOME="$OCIMHOME" DD_CHECK_OUT="$OCIMDD" "$OUT/owner-capture-input-model"
fi
# gold/ui-copy (golden test 5): every reason the sources can write into the capture session has plain words (a source
# scan), the orange line and Review… open the page that fixes it, the Settings card's pause lines, Report a Problem's
# log keeps every kind of line, setup while recording, the permission window's float. APP recipe, public and owner
# (flagged, against $OB). No MemoryViewModel is built; nothing launches, records, prompts or reads the Keychain.
# gold/r2-copy-checks (items 1-3): R2-1 every operationalIssue line (plain words, one button that fixes it, the line that
# clears it), R2-2 every RecordingNotice (plain words, a control the menu bar panel really shows), R2-3 the restore
# preview's held-back line. Same step, no new block.
if [ -f scripts/ui-copy-checks.swift ]; then
  UCHOME=$OUT/ui-copy-home; mkdir -p "$UCHOME/Library/Preferences"
  UCSRC=$OUT/src/ui-copy-app; rm -rf "$UCSRC"; mkdir -p "$UCSRC"
  for f in Sources/MacMemApp/*.swift; do python3 "$C/copy-check-source.py" "$f" "$R" > "$UCSRC/$(basename "$f")"; done
  ucobjs() { for t in MemoryCore MemoryUI HistoryCore CoreIntegration PrivacyPolicy BrowserBridge WriterBackend CLlamaBridge BackupRestore; do
    [ -d "$1/$t.build" ] && ls "$1/$t.build/"*.o; done; }
  for lane in public owner; do
    if [ $lane = public ]; then UB=$B; UF=(); else UB=$OB; UF=(-D DAYDREAM_OWNER_TYPING -D DAYDREAM_CHROME_TYPING); fi
    step compile-$lane-ui-copy swiftc ${UF[@]+"${UF[@]}"} -D DEVELOPMENT_SOURCE_CHECKS -parse-as-library -module-cache-path "$I/modcache" -I "$UB/Modules" \
      -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$UB/CLlamaBridge.build/module.modulemap" \
      -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include" -F "$UB" -framework Sparkle -Xlinker -rpath -Xlinker "$UB" \
      "$UCSRC"/*.swift scripts/ui-copy-checks.swift $(ucobjs "$UB") -lc++ -o "$OUT/$lane-ui-copy"
    step $lane-ui-copy env HOME="$UCHOME" CFFIXED_USER_HOME="$UCHOME" DD_SRC_ROOT="$PWD" "$OUT/$lane-ui-copy"
  done
fi
step owner-release-build swift build --jobs 3 -c release --product MacMem --scratch-path "$I/build-owner-release" --disable-automatic-resolution "${OWNERFLAGS[@]}"
# The other two release products a stage ships (developer-id-release.py SWIFT_BINARIES), flagged the same way.
step owner-release-build-cli bash -c "swift build --jobs 3 -c release --product mac-mem --scratch-path '$I/build-owner-release' --disable-automatic-resolution ${OWNERFLAGS[*]} && swift build --jobs 3 -c release --product mac-mem-backup --scratch-path '$I/build-owner-release' --disable-automatic-resolution ${OWNERFLAGS[*]}"
nm "$OB/MacMem" > "$OUT/owner-MacMem.nm" 2>&1
nm "$I/build-owner-release/release/MacMem" > "$OUT/owner-release-MacMem.nm" 2>&1
step owner-nm-has-website-typing bash -c "for f in '$OUT/owner-MacMem.nm' '$OUT/owner-release-MacMem.nm'; do grep -q WebTypingRoute \$f && grep -q BrowserTypingJoin \$f || exit 1; done; echo PASS the owner debug and release MacMem carry WebTypingRoute and BrowserTypingJoin"
# The public debug and release MacMem: no website typing symbol, no owner banner.
nm "$I/build-release/release/MacMem" > "$OUT/release-MacMem.nm" 2>&1
step public-nm-no-website-typing bash -c "[ -s '$OUT/MacMem.nm' ] && [ -s '$OUT/release-MacMem.nm' ] && ! grep -E 'WebTypingRoute|BrowserTypingBurst|BrowserTypingJoin' '$OUT/MacMem.nm' '$OUT/release-MacMem.nm' && ! strings '$B/MacMem' '$I/build-release/release/MacMem' | grep -q 'OWNER BUILD' && echo PASS public debug and release MacMem: no website typing symbol and no OWNER BUILD string"
# typing-all ui track: the owner-only "Other websites" row is compiled only
# under DAYDREAM_OWNER_TYPING. Public debug and release MacMem carry none of its
# strings; the owner debug and release MacMem carry both.
step public-strings-no-website-typing bash -c "for f in '$B/MacMem' '$I/build-release/release/MacMem'; do [ -s \$f ] || exit 1; strings \$f | grep -qE 'Websites not listed above|Other websites' && exit 1; strings \$f | grep -q 'Remember what you type' || exit 1; done; echo PASS public debug and release MacMem: no Other websites row or help"
step owner-strings-has-website-typing bash -c "for f in '$OB/MacMem' '$I/build-owner-release/release/MacMem'; do strings \$f | grep -q 'Websites not listed above, except blocked sites. Never in Incognito or Guest windows.' || exit 1; done; echo PASS owner debug and release MacMem carry the Other websites help"
# Source rules, the compile guard, the release refusal, and probes linked
# against the public and the owner RELEASE PrivacyPolicy objects.
step owner-typing-gate python3 scripts/typing-release-gate-checks.py -v --release "$I/build-release/release" --owner "$I/build-owner-release/release" --tmp "$I/tmp"
# public-typing review (release, high): the shipped-build lane. The swiftc checks above, compiled again with
# both flags against the flagged objects ($OB) that every release stage builds (the UI half is in ui-checks.sh).
source "$C/owner-lane.sh"
# Saturday (sat/v1): release pipeline, public-cleanup and rename checks. Added steps only.
step signing-plan-py python3 scripts/check_signing_plan.py -v
step developer-id-release-py python3 scripts/check_developer_id_release.py -v
# ship-1004: the bundled Typesense's public record, source kit, notice and update gates (inert fixtures, no signing).
step search-payload-py python3 scripts/check_search_payload.py -v
step updates-py env DAYDREAM_TEST_CLI="$B/mac-mem" python3 scripts/check_updates.py -v
step owner-updates-py env DAYDREAM_TEST_CLI="$OB/mac-mem" python3 scripts/check_updates.py -v
step packaging-py python3 scripts/check_daydream_packaging.py -v
step brand-py python3 scripts/check_daydream_brand.py
step compile-data-home-migration swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite \
  scripts/data-home-migration-checks.swift $(objs MemoryCore HistoryCore PrivacyPolicy) -o "$OUT/data-home-migration"
step data-home-migration "$OUT/data-home-migration"
# track uninstall: Settings > Setup > Uninstall (item 25). Synthetic scratch homes under TMPDIR; the
# fake "Trash" is a scratch folder. Skipped only in trees that don't have the file yet (other tracks).
if [ -f scripts/uninstall-plan-checks.swift ]; then
  step compile-uninstall-plan swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite \
    scripts/uninstall-plan-checks.swift $(objs MemoryCore HistoryCore PrivacyPolicy) -o "$OUT/uninstall-plan"
  step uninstall-plan "$OUT/uninstall-plan"
fi
# track recording (SPEC 6.3): the sleep/lock/user-switch rules and stop notices, the download-window
# warning, and the permission buttons (macOS calls stubbed; nothing records, prompts or relaunches).
# Skipped only in trees that don't have the files yet (other tracks).
if [ -f scripts/recording-wake-checks.swift ]; then
  step compile-recording-wake swiftc -parse-as-library -module-cache-path "$I/modcache" \
    Sources/MacMemApp/WakeResume.swift Sources/MacMemApp/LaunchLocation.swift scripts/recording-wake-checks.swift -o "$OUT/recording-wake"
  step recording-wake "$OUT/recording-wake"
  step compile-dd-recording-state swiftc -parse-as-library -module-cache-path "$I/modcache" \
    Sources/MemoryUI/DaydreamCaptureState.swift scripts/dd-recording-state-checks.swift -o "$OUT/dd-recording-state"
  step dd-recording-state "$OUT/dd-recording-state"
  # fix/lock-resume: the screen lock is heard while DayDream is in the background (own notification names only).
  if [ -f scripts/lock-notice-delivery-checks.swift ]; then
    step compile-lock-notice-delivery swiftc -parse-as-library -module-cache-path "$I/modcache" \
      Sources/MacMemApp/WakeSystem.swift Sources/MacMemApp/WakeResume.swift Sources/MacMemApp/LaunchLocation.swift \
      scripts/lock-notice-delivery-checks.swift -o "$OUT/lock-notice-delivery"
    step lock-notice-delivery "$OUT/lock-notice-delivery"
  fi
  RECHOME=$OUT/recording-home; RECDD=$OUT/recording-dd; mkdir -p "$RECHOME/Library/Preferences" "$RECDD"
  step compile-recording-permission swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" \
    -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" Sources/MacMemApp/PermissionRequests.swift Sources/MacMemApp/LaunchLocation.swift \
    scripts/recording-permission-checks.swift $(objs MemoryUI MemoryCore HistoryCore PrivacyPolicy) -o "$OUT/recording-permission"
  step recording-permission env HOME="$RECHOME" CFFIXED_USER_HOME="$RECHOME" DD_CHECK_OUT="$RECDD" "$OUT/recording-permission"
  RECSRC=$OUT/src/recording-app; rm -rf "$RECSRC"; mkdir -p "$RECSRC"
  for f in Sources/MacMemApp/*.swift; do python3 "$C/copy-check-source.py" "$f" "$R" > "$RECSRC/$(basename "$f")"; done
  sed -e "s#/private/tmp/daydream-#$R/daydream-#g" scripts/recording-model-checks.swift > "$OUT/src/recording-model-checks.swift"
  recobjs() { for t in MemoryCore MemoryUI HistoryCore CoreIntegration PrivacyPolicy BrowserBridge WriterBackend CLlamaBridge BackupRestore; do
    [ -d "$B/$t.build" ] && ls "$B/$t.build/"*.o; done; }
  step compile-recording-model swiftc -D DEVELOPMENT_SOURCE_CHECKS -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" \
    -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$B/CLlamaBridge.build/module.modulemap" \
    -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include" -F "$B" -framework Sparkle -Xlinker -rpath -Xlinker "$B" \
    "$RECSRC"/*.swift "$OUT/src/recording-model-checks.swift" $(recobjs) -lc++ -o "$OUT/recording-model"
  step recording-model env HOME="$RECHOME" CFFIXED_USER_HOME="$RECHOME" DD_CHECK_OUT="$RECDD" "$OUT/recording-model"
  # gold/capture-input (golden 5 G32, G3): Input Monitoring turned on while DayDream runs sends every Start to
  # Permissions (Quit & Reopen); a lost input tap keeps recording wanted. Permission reads are substituted; no start.
  if [ -f scripts/capture-input-model-checks.swift ]; then
    sed -e "s#/private/tmp/daydream-#$R/daydream-#g" scripts/capture-input-model-checks.swift > "$OUT/src/capture-input-model-checks.swift"
    CIMHOME=$OUT/capture-input-model-home; CIMDD=$OUT/capture-input-model-dd; mkdir -p "$CIMHOME/Library/Preferences" "$CIMDD"
    step compile-capture-input-model swiftc -D DEVELOPMENT_SOURCE_CHECKS -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" \
      -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$B/CLlamaBridge.build/module.modulemap" \
      -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include" -F "$B" -framework Sparkle -Xlinker -rpath -Xlinker "$B" \
      "$RECSRC"/*.swift "$OUT/src/capture-input-model-checks.swift" $(recobjs) -lc++ -o "$OUT/capture-input-model"
    step capture-input-model env HOME="$CIMHOME" CFFIXED_USER_HOME="$CIMHOME" DD_CHECK_OUT="$CIMDD" "$OUT/capture-input-model"
  fi
  step shell-wiring-py python3 scripts/check_shell.py -v
  # gold/lifecycle (test 5): launch resume (G10, G42, Extra 1), Open at login (G10b), an import or restore preview an
  # automatic start waits on (Extra 2, Extra 4, the lock-fix nit), latched lines (G4, G35, G36, Extra 3), a second copy
  # (G39), a wake start that stops at once (G56) and Stop in Needs Permission (G65), on the REAL MemoryViewModel with
  # the check seams (in-memory typing keys, no event tap, no login item, private defaults). Public and owner objects.
  if [ -f scripts/lifecycle-model-checks.swift ]; then
    LCHOME=$OUT/lifecycle-home; LCDD=$OUT/lifecycle-dd; mkdir -p "$LCHOME/Library/Preferences" "$LCDD"; chmod 700 "$LCDD"
    step compile-lifecycle-model swiftc -D DEVELOPMENT_SOURCE_CHECKS -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" \
      -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$B/CLlamaBridge.build/module.modulemap" \
      -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include" -F "$B" -framework Sparkle -Xlinker -rpath -Xlinker "$B" \
      "$RECSRC"/*.swift scripts/lifecycle-model-checks.swift $(recobjs) -lc++ -o "$OUT/lifecycle-model"
    step lifecycle-model env HOME="$LCHOME" CFFIXED_USER_HOME="$LCHOME" DD_CHECK_OUT="$LCDD" "$OUT/lifecycle-model"
    if [ -d "${OB:-/nonexistent}/MemoryCore.build" ]; then
      OLCHOME=$OUT/owner-lifecycle-home; OLCDD=$OUT/owner-lifecycle-dd; mkdir -p "$OLCHOME/Library/Preferences" "$OLCDD"; chmod 700 "$OLCDD"
      olcobjs() { for t in MemoryCore MemoryUI HistoryCore CoreIntegration PrivacyPolicy BrowserBridge WriterBackend CLlamaBridge BackupRestore; do
        [ -d "$OB/$t.build" ] && ls "$OB/$t.build/"*.o; done; }
      step compile-owner-lifecycle-model swiftc -D DEVELOPMENT_SOURCE_CHECKS -D DAYDREAM_OWNER_TYPING -D DAYDREAM_CHROME_TYPING -parse-as-library \
        -module-cache-path "$I/modcache" -I "$OB/Modules" \
        -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$OB/CLlamaBridge.build/module.modulemap" \
        -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include" -F "$OB" -framework Sparkle -Xlinker -rpath -Xlinker "$OB" \
        "$RECSRC"/*.swift scripts/lifecycle-model-checks.swift $(olcobjs) -lc++ -o "$OUT/owner-lifecycle-model"
      step owner-lifecycle-model env HOME="$OLCHOME" CFFIXED_USER_HOME="$OLCHOME" DD_CHECK_OUT="$OLCDD" "$OUT/owner-lifecycle-model"
    fi
  fi
  # gold/int final review repair (G33): a moment's "not allowed" at an automatic start (the wake start, a timed pause's
  # end, the launch resume, an import ending) reads again instead of stopping recording for good; a permission really
  # off still never starts recording and gets one notice. The REAL MemoryViewModel with the check seams. Public and owner.
  if [ -f scripts/permission-blip-checks.swift ]; then
    PBHOME=$OUT/permission-blip-home; PBDD=$OUT/permission-blip-dd; mkdir -p "$PBHOME/Library/Preferences" "$PBDD"; chmod 700 "$PBDD"
    step compile-permission-blip swiftc -D DEVELOPMENT_SOURCE_CHECKS -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" \
      -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$B/CLlamaBridge.build/module.modulemap" \
      -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include" -F "$B" -framework Sparkle -Xlinker -rpath -Xlinker "$B" \
      "$RECSRC"/*.swift scripts/permission-blip-checks.swift $(recobjs) -lc++ -o "$OUT/permission-blip"
    step permission-blip env HOME="$PBHOME" CFFIXED_USER_HOME="$PBHOME" DD_CHECK_OUT="$PBDD" "$OUT/permission-blip"
    if [ -d "${OB:-/nonexistent}/MemoryCore.build" ]; then
      OPBHOME=$OUT/owner-permission-blip-home; OPBDD=$OUT/owner-permission-blip-dd; mkdir -p "$OPBHOME/Library/Preferences" "$OPBDD"; chmod 700 "$OPBDD"
      opbobjs() { for t in MemoryCore MemoryUI HistoryCore CoreIntegration PrivacyPolicy BrowserBridge WriterBackend CLlamaBridge BackupRestore; do
        [ -d "$OB/$t.build" ] && ls "$OB/$t.build/"*.o; done; }
      step compile-owner-permission-blip swiftc -D DEVELOPMENT_SOURCE_CHECKS -D DAYDREAM_OWNER_TYPING -D DAYDREAM_CHROME_TYPING -parse-as-library \
        -module-cache-path "$I/modcache" -I "$OB/Modules" \
        -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$OB/CLlamaBridge.build/module.modulemap" \
        -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include" -F "$OB" -framework Sparkle -Xlinker -rpath -Xlinker "$OB" \
        "$RECSRC"/*.swift scripts/permission-blip-checks.swift $(opbobjs) -lc++ -o "$OUT/owner-permission-blip"
      step owner-permission-blip env HOME="$OPBHOME" CFFIXED_USER_HOME="$OPBHOME" DD_CHECK_OUT="$OPBDD" "$OUT/owner-permission-blip"
    fi
  fi
  # perm-1004 (owner 10/3): every surface names the missing permission and goes to its pane; Input Monitoring turned
  # on after launch restarts by itself once; the exact row, removed with minus first, then added again; no macOS prompt
  # (every Accessibility root and posted event reads trust first); test copies get a labelled icon and ad-hoc copies
  # an .adhoc ID. Pure MemoryUI checks and source checks: no window, permission read, prompt, relaunch or signing.
  step permission-prompt-py python3 scripts/permission-prompt-checks.py
  step test-copy-identity-py python3 scripts/test-copy-identity-checks.py
  if [ -f scripts/permission-guidance-checks.swift ]; then
    PGHOME=$OUT/permission-guidance-home; PGDD=$OUT/permission-guidance-dd; mkdir -p "$PGHOME/Library/Preferences" "$PGDD"
    step compile-permission-guidance swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" \
      -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" scripts/permission-guidance-checks.swift \
      $(objs MemoryUI MemoryCore HistoryCore PrivacyPolicy) -lsqlite3 -o "$OUT/permission-guidance"
    step permission-guidance env HOME="$PGHOME" CFFIXED_USER_HOME="$PGHOME" DD_CHECK_OUT="$PGDD" "$OUT/permission-guidance"
    if [ -d "${OB:-/nonexistent}/MemoryCore.build" ]; then
      step compile-owner-permission-guidance swiftc -D DAYDREAM_OWNER_TYPING -D DAYDREAM_CHROME_TYPING -parse-as-library \
        -module-cache-path "$I/modcache" -I "$OB/Modules" -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" \
        scripts/permission-guidance-checks.swift $(oobjs MemoryUI MemoryCore HistoryCore PrivacyPolicy) -lsqlite3 -o "$OUT/owner-permission-guidance"
      step owner-permission-guidance env HOME="$PGHOME" CFFIXED_USER_HOME="$PGHOME" DD_CHECK_OUT="$PGDD" "$OUT/owner-permission-guidance"
    fi
  fi
  # gold r2 (launch-state): states that must never latch. A saved choice keeps a timed pause and the lock's pause (a save
  # landing behind the lock reads "Paused while your screen was locked."), a history another connection holds at launch
  # opens by itself with the launch intent kept, and a second copy hands off to the running one (or, when it can't,
  # says one short line and opens the history once free). The REAL MemoryViewModel with the check seams; in-memory
  # launch-intent defaults; the other copy is a fake (nothing is looked for, opened, activated or quit). Public and owner.
  # gold/r3-store (golden test 5, gate item 5): the owner's everyday store actions (an app choice saved, a Correct and
  # Forget, clicks while another connection holds the history for 0.9, 2.5 and 8 s) never hold the main thread over
  # 100 ms, and no click is lost. Same seams and recipe as launch-state.
  for LSCHECK in launch-state single-copy store-main-hold; do
    if [ -f scripts/$LSCHECK-checks.swift ]; then
      LSHOME=$OUT/$LSCHECK-home; LSDD=$OUT/$LSCHECK-dd; mkdir -p "$LSHOME/Library/Preferences" "$LSDD"; chmod 700 "$LSDD"
      step compile-$LSCHECK swiftc -D DEVELOPMENT_SOURCE_CHECKS -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" \
        -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$B/CLlamaBridge.build/module.modulemap" \
        -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include" -F "$B" -framework Sparkle -Xlinker -rpath -Xlinker "$B" \
        "$RECSRC"/*.swift scripts/$LSCHECK-checks.swift $(recobjs) -lc++ -o "$OUT/$LSCHECK"
      step $LSCHECK env HOME="$LSHOME" CFFIXED_USER_HOME="$LSHOME" DD_CHECK_OUT="$LSDD" "$OUT/$LSCHECK"
      if [ -d "${OB:-/nonexistent}/MemoryCore.build" ]; then
        OLSHOME=$OUT/owner-$LSCHECK-home; OLSDD=$OUT/owner-$LSCHECK-dd; mkdir -p "$OLSHOME/Library/Preferences" "$OLSDD"; chmod 700 "$OLSDD"
        olsobjs() { for t in MemoryCore MemoryUI HistoryCore CoreIntegration PrivacyPolicy BrowserBridge WriterBackend CLlamaBridge BackupRestore; do
          [ -d "$OB/$t.build" ] && ls "$OB/$t.build/"*.o; done; }
        step compile-owner-$LSCHECK swiftc -D DEVELOPMENT_SOURCE_CHECKS -D DAYDREAM_OWNER_TYPING -D DAYDREAM_CHROME_TYPING -parse-as-library \
          -module-cache-path "$I/modcache" -I "$OB/Modules" \
          -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$OB/CLlamaBridge.build/module.modulemap" \
          -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include" -F "$OB" -framework Sparkle -Xlinker -rpath -Xlinker "$OB" \
          "$RECSRC"/*.swift scripts/$LSCHECK-checks.swift $(olsobjs) -lc++ -o "$OUT/owner-$LSCHECK"
        step owner-$LSCHECK env HOME="$OLSHOME" CFFIXED_USER_HOME="$OLSHOME" DD_CHECK_OUT="$OLSDD" "$OUT/owner-$LSCHECK"
      fi
    fi
  done
fi
# track updates (SPEC 6.4): the vendored Sparkle matches its pin (offline; may add the .bootstrap-sha256
# stamp inside the gitignored Vendor folder) and packaging/updates.json names the GitHub Releases feed.
# No key, network or signing. Skipped only in trees that don't have packaging/updates.json yet (other tracks).
if [ -f packaging/updates.json ]; then
  step sparkle-pin python3 scripts/bootstrap-sparkle.py --offline
  step updates-json python3 scripts/release.py validate
  # updates-1003: the release stage writes the website feed, the owner's key and quiet updates; the QA, owner and
  # Live Test builds never update. Source rules only (staged apps: --release-app/--qa-app/--livetest-app).
  if [ -f scripts/check_update_builds.py ]; then step update-builds-py python3 -B scripts/check_update_builds.py -v; fi
fi
# gold/updates-release (golden test 5: G9, G40, G53, G76): quitting while Settings is open (DayDream ▸ Quit, ⌘Q,
# the quit Apple event of the Dock, log out, restart and Sparkle's installer; Install and Relaunch) in child copies
# of the check, the update relaunch marker and the updates status line; public, and flagged like the release build.
# APP recipe. Nothing checks for, downloads or installs an update; preferences stay in memory.
if [ -f scripts/update-quit-checks.swift ]; then
  UQSRC=$OUT/src/update-quit-app; rm -rf "$UQSRC"; mkdir -p "$UQSRC"
  for f in Sources/MacMemApp/*.swift; do python3 "$C/copy-check-source.py" "$f" "$R" > "$UQSRC/$(basename "$f")"; done
  UQHOME=$OUT/update-quit-home; mkdir -p "$UQHOME/Library/Preferences"
  uqobjs() { for t in MemoryCore MemoryUI HistoryCore CoreIntegration PrivacyPolicy BrowserBridge WriterBackend CLlamaBridge BackupRestore; do
    [ -d "$1/$t.build" ] && ls "$1/$t.build/"*.o; done; }
  uqcompile() { local name=$1 b=$2; shift 2
    step compile-$name swiftc -D DEVELOPMENT_SOURCE_CHECKS "$@" -parse-as-library -module-cache-path "$I/modcache" -I "$b/Modules" \
      -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$b/CLlamaBridge.build/module.modulemap" \
      -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include" -F "$b" -framework Sparkle -Xlinker -rpath -Xlinker "$b" \
      "$UQSRC"/*.swift scripts/update-quit-checks.swift $(uqobjs "$b") -lc++ -o "$OUT/$name"
    step $name env HOME="$UQHOME" CFFIXED_USER_HOME="$UQHOME" "$OUT/$name"; }
  uqcompile update-quit "$B"
  [ -n "${OB:-}" ] && [ -d "$OB" ] && uqcompile owner-update-quit "$OB" -D DAYDREAM_OWNER_TYPING -D DAYDREAM_CHROME_TYPING
fi
# track docs (SPEC 6.6): the docs claims checks (README, PRIVACY, FAQ, summaries, templates, the
# owner's drafts), and the install-guide pictures drawn from the real setup, menu bar and Settings
# views with sample data. Never the live app: nothing launches, records, prompts or registers.
# Skipped only in trees that don't have the files yet (other tracks).
if [ -f scripts/docs-claims-checks.py ]; then
  step docs-claims-py env DAYDREAM_DRAFTS="$SATC/drafts" python3 scripts/docs-claims-checks.py -v
fi
if [ -f scripts/docs-install-render.swift ]; then
  DOCSOBJS=$(for t in MemoryCore MemoryUI HistoryCore CoreIntegration PrivacyPolicy BrowserBridge WriterBackend CLlamaBridge BackupRestore; do ls "$B/$t.build/"*.o; done)
  step compile-docs-install-render swiftc -D DEVELOPMENT_SOURCE_CHECKS -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" \
    -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$B/CLlamaBridge.build/module.modulemap" \
    -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include" scripts/docs-install-render.swift $DOCSOBJS -lc++ -o "$OUT/docs-install-render"
  rm -rf "$OUT/docs-bg" "$OUT/docs-images" "$OUT/docs-scratch" "$OUT/docs-home"; mkdir -p "$OUT/docs-bg" "$OUT/docs-home"
  step docs-dmg-background swift scripts/dmg-background.swift "$OUT/docs-bg" "$OUT/docs-bg/bookmark"
  step docs-install-render env HOME="$OUT/docs-home" CFFIXED_USER_HOME="$OUT/docs-home" \
    "$OUT/docs-install-render" "$OUT/docs-images" "$OUT/docs-scratch" "$PWD" "$OUT/docs-bg/.background.tiff"
fi
# track honesty: items 19-24 and 28, H7 release switch, H8 unknown browsers (SPEC §6.1). Skipped only in
# trees that don't have the files yet (other tracks). The switch-off build is a copy under $I/switch-off
# (Vendor linked); the checks use fake Chrome environments and fake app folders: no Apple Event, no prompt.
if [ -f scripts/honesty-release-switch-checks.py ]; then
  step honesty-release-switch-py python3 scripts/honesty-release-switch-checks.py -v
  step honesty-switch-off bash scripts/honesty-switch-off-checks.sh "$I/switch-off" "$B"
  step compile-honesty-ui swiftc -D DEVELOPMENT_SOURCE_CHECKS -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" \
    -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$B/CLlamaBridge.build/module.modulemap" \
    -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include" scripts/honesty-ui-checks.swift \
    $(objs MemoryCore MemoryUI HistoryCore CoreIntegration PrivacyPolicy BrowserBridge WriterBackend CLlamaBridge BackupRestore) -lc++ -o "$OUT/honesty-ui"
  mkdir -p "$OUT/honesty-home/Library/Preferences"
  step honesty-ui env HOME="$OUT/honesty-home" CFFIXED_USER_HOME="$OUT/honesty-home" "$OUT/honesty-ui"
fi
# track connect (SPEC 6.5): Settings > Connections writes an AI app's MCP entry through `mac-mem connect`
# (scratch settings files and history only), Help > Report a Problem shows a cleaned report (synthetic history
# and log lines), and no Horizon/SSH connection is left in the sources or the release MacMem.
# Nothing touches a real AI app, the network, the Keychain or the general pasteboard.
# Skipped only in trees that don't have the files yet (other tracks).
if [ -f scripts/connect-config-checks.swift ]; then
  for name in connect-config connect-diagnostics connect-toml; do
    [ -f "scripts/$name-checks.swift" ] || continue
    step compile-$name swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite \
      scripts/$name-checks.swift $(objs MemoryCore HistoryCore PrivacyPolicy) -o "$OUT/$name"
    step $name "$OUT/$name"
  done
  step connect-cli-py env DAYDREAM_TEST_CLI="$B/mac-mem" python3 scripts/connect-cli-checks.py
  step connect-horizon-py python3 scripts/connect-horizon-checks.py --binary "$I/build-release/release/MacMem" --binary "$B/MacMem" --binary "$B/mac-mem"
  step owner-connect-cli-py env DAYDREAM_TEST_CLI="$OB/mac-mem" python3 scripts/connect-cli-checks.py
  step owner-connect-horizon-py python3 scripts/connect-horizon-checks.py --binary "$I/build-owner-release/release/MacMem" \
    --binary "$I/build-owner-release/release/mac-mem" --binary "$OB/MacMem" --binary "$OB/mac-mem"
  # gold/connections-storage (G13, G45): an AI app's server carries on across an update, follows a repaired history.
  if [ -f scripts/mcp-update-checks.py ]; then
    step mcp-update-py env DAYDREAM_TEST_CLI="$B/mac-mem" python3 scripts/mcp-update-checks.py
    step owner-mcp-update-py env DAYDREAM_TEST_CLI="$OB/mac-mem" python3 scripts/mcp-update-checks.py
  fi
  # claude/mcp-prompts-1003: the MCP server's text and replies (instructions, response_format, concise Markdown, isError
  # results), its resources, and the DayDream Agent Skill. Scratch histories from `mac-mem demo` and fixtures only.
  for lane in "" owner-; do
    CLI_FOR=$B; [ -n "$lane" ] && CLI_FOR=$OB
    step ${lane}mcp-interfaces-py env DAYDREAM_TEST_CLI="$CLI_FOR/mac-mem" python3 scripts/check_interfaces.py
    step ${lane}mcp-readiness-py env DAYDREAM_TEST_CLI="$CLI_FOR/mac-mem" python3 scripts/mcp-readiness-checks.py
    step ${lane}mcp-resources-py env MACMEM_TEST_CLI="$CLI_FOR/mac-mem" python3 scripts/check_action_resources.py
  done
  step mcp-skill-py python3 scripts/mcp-skill-checks.py
  CONNHOME=$OUT/connect-home; CONNDD=$OUT/connect-dd; mkdir -p "$CONNHOME/Library/Preferences" "$CONNDD"
  CONNSRC=$OUT/src/connect-app; rm -rf "$CONNSRC"; mkdir -p "$CONNSRC"
  for f in Sources/MacMemApp/*.swift; do python3 "$C/copy-check-source.py" "$f" "$R" > "$CONNSRC/$(basename "$f")"; done
  sed -e "s#/private/tmp/daydream-#$R/daydream-#g" scripts/connection-review-checks.swift > "$OUT/src/connection-review-checks.swift"
  connobjs() { for t in MemoryCore MemoryUI HistoryCore CoreIntegration PrivacyPolicy BrowserBridge WriterBackend CLlamaBridge BackupRestore; do
    ls "$B/$t.build/"*.o; done; }
  step compile-connection-review swiftc -D DEVELOPMENT_SOURCE_CHECKS -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" \
    -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$B/CLlamaBridge.build/module.modulemap" \
    -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include" -F "$B" -framework Sparkle -Xlinker -rpath -Xlinker "$B" \
    "$CONNSRC"/*.swift "$OUT/src/connection-review-checks.swift" $(connobjs) -lc++ -o "$OUT/connection-review"
  step connection-review env HOME="$CONNHOME" CFFIXED_USER_HOME="$CONNHOME" DD_CHECK_OUT="$CONNDD" "$OUT/connection-review"
fi
# gold/r2-copy-checks (item 4): check_shortcuts.py joins the suite. Its capture-state rule now reads the toolbar's
# if/else with the script's balanced-call parse (on a6944d3 its regex failed on the nested call). Source scan only.
step shortcuts-py python3 scripts/check_shortcuts.py
# gold/r2-copy-checks (item 4): wb-core (WriterBackend/CoreChecks) at the real clock, then at the hours around
# midnight, noon and the DST changes in New York under five TZ values, through a test-only clock shift loaded into the
# check alone (scripts/clock-shift.c); before each shifted run a probe proves the shift took. Synthetic stores in TMPDIR.
if [ -f scripts/wb-core-clock-checks.sh ]; then
  WBT=$OUT/wb-core; mkdir -p "$WBT"
  step compile-wb-core-lib swiftc -parse-as-library -emit-library -emit-module -module-name WriterBackend -target arm64-apple-macosx13.0 \
    -module-cache-path "$I/modcache" WriterBackend/Sources/WriterBackend/{Contract,LocalWriter,CloudWriter,CloudActivation,CloudTransport,CanonicalNotes,SourceClauseCoverage,ModelView,CoreWriterAdapter,LongMomentNotes}.swift \
    -emit-module-path "$WBT/WriterBackend.swiftmodule" -o "$WBT/libWriterBackend.dylib"
  step compile-wb-core swiftc -parse-as-library WriterBackend/CoreChecks.swift -target arm64-apple-macosx13.0 -module-cache-path "$I/modcache" \
    -I "$WBT" -I "$B/Modules" -I Sources/CSQLite "$B"/MemoryCore.build/*.swift.o "$B"/HistoryCore.build/*.swift.o "$B"/PrivacyPolicy.build/*.swift.o \
    -L "$WBT" -lWriterBackend -lsqlite3 -Xlinker -rpath -Xlinker "$WBT" -o "$WBT/core-checks"
  step wb-core "$WBT/core-checks"
  step compile-clock-shift clang -dynamiclib scripts/clock-shift.c -o "$WBT/libclockshift.dylib"
  step compile-clock-shift-probe swiftc -module-cache-path "$I/modcache" scripts/clock-shift-probe.swift -o "$WBT/clock-shift-probe"
  step wb-core-clock bash scripts/wb-core-clock-checks.sh "$WBT/core-checks" "$WBT/libclockshift.dylib" "$WBT/clock-shift-probe"
fi
# gold/r2-copy-checks (item 4): preference-blocker-checks S (its source rules) alone. The rest of that check builds the
# production MemoryViewModel (UserDefaults.standard, the Keychain), so it stays out of this suite; `--sources-only`
# returns before any of it. APP recipe; a tree whose check has no such mode fails here instead of running the rest.
if [ -f scripts/preference-blocker-checks.swift ]; then
  if grep -q -- '"--sources-only"' scripts/preference-blocker-checks.swift; then
    PFBSRC=$OUT/src/preference-blocker-app; rm -rf "$PFBSRC"; mkdir -p "$PFBSRC"
    for f in Sources/MacMemApp/*.swift; do python3 "$C/copy-check-source.py" "$f" "$R" > "$PFBSRC/$(basename "$f")"; done
    sed -e "s#/private/tmp/daydream-#$R/daydream-#g" scripts/preference-blocker-checks.swift > "$OUT/src/preference-blocker-checks.swift"
    PFBHOME=$OUT/preference-blocker-home; mkdir -p "$PFBHOME/Library/Preferences"
    step compile-preference-blocker-sources swiftc -D DEVELOPMENT_SOURCE_CHECKS -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" \
      -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$B/CLlamaBridge.build/module.modulemap" \
      -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include" -F "$B" -framework Sparkle -Xlinker -rpath -Xlinker "$B" \
      "$PFBSRC"/*.swift "$OUT/src/preference-blocker-checks.swift" \
      $(for t in MemoryCore MemoryUI HistoryCore CoreIntegration PrivacyPolicy BrowserBridge WriterBackend CLlamaBridge BackupRestore; do [ -d "$B/$t.build" ] && ls "$B/$t.build/"*.o; done) \
      -lc++ -o "$OUT/preference-blocker"
    step preference-blocker-sources env HOME="$PFBHOME" CFFIXED_USER_HOME="$PFBHOME" "$OUT/preference-blocker" --sources-only
  else
    step preference-blocker-sources bash -c 'echo "FAIL: scripts/preference-blocker-checks.swift has no --sources-only mode; its S rules would need the whole check (UserDefaults.standard, Keychain)"; exit 1'
  fi
fi
# UI checks (SPEC §13.3): the APP and UI recipes plus settings-0013 and the typing UI checks (public and,
# with $OB, owner), from ui-checks.sh (same step/OUT/B).
# Never scripts/check-settings-hub.sh (it writes /private/tmp/daydream-ui-build).
UI_SOURCED=1
source "$C/ui-checks.sh"
# RC supplements use this candidate's own debug modules and synthetic homes only.
for lane in public owner; do
  MB="$B"; MF=(); [ "$lane" != owner ] || { MB="$OB"; MF=(-D DAYDREAM_OWNER_TYPING -D DAYDREAM_CHROME_TYPING); }
  step compile-rc-messages-$lane swiftc -parse-as-library ${MF[@]+"${MF[@]}"} -module-cache-path "$I/modcache" -I "$MB/Modules" -I Sources/CSQLite \
    scripts/messages-moment-checks.swift "$MB"/MemoryCore.build/*.o "$MB"/HistoryCore.build/*.o "$MB"/PrivacyPolicy.build/*.o -o "$OUT/rc-messages-$lane"
  step rc-messages-$lane "$OUT/rc-messages-$lane"
done
UXOBJS=()
for target in MemoryCore MemoryUI HistoryCore CoreIntegration PrivacyPolicy BrowserBridge WriterBackend CLlamaBridge; do
  for object in "$OB/$target.build/"*.o; do UXOBJS+=("$object"); done
done
for name in snapshot owner-view intent scheduling; do
  UXSRC=(); [ "$name" != scheduling ] || read -r -a UXSRC <<< "$WRITERSRC"
  step compile-rc-summary-ux-$name swiftc -parse-as-library -D DAYDREAM_OWNER_TYPING -D DAYDREAM_CHROME_TYPING \
    -module-cache-path "$I/modcache" -I "$OB/Modules" -I Sources/CSQLite \
    -Xcc -fmodule-map-file="$OB/CLlamaBridge.build/module.modulemap" \
    ${UXSRC[@]+"${UXSRC[@]}"} "scripts/summary-ux-$name-checks.swift" "${UXOBJS[@]}" -lsqlite3 -lc++ -o "$OUT/rc-summary-ux-$name"
  mkdir -p "$OUT/rc-summary-ux-$name-root" "$OUT/rc-summary-ux-$name-home/Library/Preferences"
  step rc-summary-ux-$name env HOME="$OUT/rc-summary-ux-$name-home" CFFIXED_USER_HOME="$OUT/rc-summary-ux-$name-home" \
    STATE_CHECK_ROOT="$OUT/rc-summary-ux-$name-root" nice "$OUT/rc-summary-ux-$name" "$OUT/rc-summary-ux-$name-root"
done
step rc-summary-ux-pause bash WriterBackend/PauseChecks/run.sh
printf '%s\n' "${summary[@]}" | tee "$OUT/SUMMARY"
if [ "$failed_steps" -ne 0 ]; then exit 1; fi
