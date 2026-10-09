#!/bin/bash
# Full headless synthetic check suite for DayDream: builds the package, runs MacMemChecks and every
# scripts/*-checks step below, plus the public/owner typing scans. Run it through run-headless.sh.
# Env: SRC=worktree (default: this repo), WORKDIR=build+output dir (default: .build/checks; use one per parallel run),
# SOCKROOT=short socket dir (default: a new /tmp/ddchk.* folder; one per parallel run).
# No app launch, event tap, Apple Event to Chrome, permission request, keychain,
# signing or download. Every temp/build path is under the scratch folder below.
set -uo pipefail
C=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export PATH="$C/bin:$PATH"
# docs-claims-checks can also check post drafts kept outside the repo (DAYDREAM_DRAFT_ROOT); none by default.
SATC=${DAYDREAM_DRAFT_ROOT:-$C/no-drafts}
WT=${SRC:-$(cd "$C/.." && pwd)}
# Resolved: /var/tmp and /tmp are symlinks, and the writer's installer, the release tools and several stores refuse a
# path under a symlink (or compare resolved paths), so a WORKDIR under /var/tmp failed them for that reason alone.
I=${WORKDIR:-$WT/.build/checks}; mkdir -p "$I"; I=$(cd "$I" && pwd -P)
BUILD=${BUILD:-$I/build-public}
LABEL=${1:-run}
OUT=$I/out-$LABEL
rm -rf "$OUT"; mkdir -p "$OUT" "$I/tmp" "$I/modcache" "$OUT/src"
export TMPDIR=$I/tmp/ PYTHONDONTWRITEBYTECODE=1
export CLANG_MODULE_CACHE_PATH=$I/modcache SWIFT_MODULECACHE_PATH=$I/modcache
cd "$WT"
# This COPY is headless-only: SKIP is every manifest row that needs a window (needs=window), whatever the caller set,
# so an unset or custom SKIP can never open a window, and the list has one source (scripts/checks-manifest.tsv).
SKIP=$(python3 scripts/verify-run-manifest.py --skip-regex) || { echo "REFUSING: scripts/checks-manifest.tsv does not load"; exit 1; }
export SKIP
case "$I" in /private/var/*|/private/tmp/*)
  echo "NOTE: WORKDIR is under /private/var or /private/tmp. uninstall-plan fails there: MemoryCore's UninstallProbe.noLinks"
  echo "      (Sources/MemoryCore/Uninstall.swift) reads url.standardizedFileURL, which drops /private, so the path walks the"
  echo "      /var or /tmp symlink and the plan refuses the scratch folder. An app behaviour (reported, not hidden); use a"
  echo "      work folder outside /var and /tmp (for example ~/DaydreamReleases/<run>) for a clean run." ;;
esac
LANE_ONLY=
if [ -n "${LANES:-}" ]; then LANE_ONLY=$(python3 scripts/verify-run-manifest.py --lanes-regex "$LANES") || { echo "REFUSING: bad LANES=$LANES"; exit 1; }; fi
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
# SKIP (above) skips the steps that host on-screen AppKit windows (this runner is headless); they are logged as
# "SKIPPED-UI" in the summary. Their compile-<name> steps still run, so a window check that no longer builds is red
# here too, not only in the Phase 2 window lane.
skipped() { [ -n "${SKIP:-}" ] && [[ $1 =~ $SKIP ]]; }
# DRYRUN=1 lists the steps (names and commands in $OUT/DRYRUN-steps.tsv) without building or running anything.
# LANES=smoke,storage runs the steps the manifest (scripts/checks-manifest.tsv) puts in those lanes, plus the builds.
# The run's result is scripts/verify-run-manifest.py over SUMMARY (see the end of this file), not a count of red steps.
step() { local name=$1; shift; if [ -n "${ONLY:-}" ] && ! [[ $name =~ $ONLY ]]; then return 0; fi
  if [ -n "${LANE_ONLY:-}" ] && ! [[ $name =~ $LANE_ONLY ]]; then return 0; fi
  if [ -n "${DRYRUN:-}" ]; then summary+=("$name DRYRUN"); printf '%s\t%s\n' "$name" "$*" >> "$OUT/DRYRUN-steps.tsv"; return 0; fi
  if skipped "$name"; then summary+=("$name SKIPPED-UI"); echo "$name SKIPPED-UI"; return 0; fi; "$@" >"$OUT/$name.log" 2>&1; local rc=$?
  if [ "$rc" -ne 0 ]; then failed_steps=$((failed_steps+1)); fi
  summary+=("$name exit=$rc pass=$(passes "$OUT/$name.log")"); echo "$name exit=$rc"; }
# PASS lines: a check's PASS / unittest "... ok" / node "# pass" lines and its own "N passed" total line. Compiler output
# never counts: a source excerpt ("129 |   print(\"... passed\")") or a diagnostic ("/path:12:3: warning: ...") quoting
# "passed" made a build log count 1 in a fresh scratch and 0 in an incremental one.
passes() { grep -E '^PASS|\.\.\. ok$|^# pass|passed' "$1" | grep -cvE '^ *[0-9]* *\| |^/[^ ]+:[0-9]+:[0-9]+: (warning|error|note):'; }
objs() { for t in "$@"; do ls "$B/$t.build/"*.o; done; }
# Copy a check whose store root is hard-coded under /private/tmp into scratch,
# pointing the root at a short temp folder instead (the repo file is not
# changed). Short because browser-app-0227 binds a UNIX socket in that root and
# sun_path holds at most 104 bytes; the scratch path is longer than that.
R=${SOCKROOT:-$(mktemp -d /private/tmp/ddchk.XXXXXX)}; mkdir -p "$R"; R=$(cd "$R" && pwd -P)  # resolved: /tmp is a symlink
# One scratch copy of the app sources (copy-check-source.py: /private/tmp roots moved to $R, headless permission seams)
# shared by every APP-recipe step; none of them edits it (the flash mutant copies it first).
appsrc() { local d=$OUT/src/app-shared
  if [ ! -f "$d/.done" ] && [ -z "${DRYRUN:-}" ]; then mkdir -p "$d"
    for f in Sources/MacMemApp/*.swift; do python3 "$C/copy-check-source.py" "$f" "$R" > "$d/$(basename "$f")"; done; touch "$d/.done"; fi
  echo "$d"; }
# The owner objects exist (DRYRUN lists the owner steps without them).
have_ob() { [ -n "${DRYRUN:-}" ] || [ -d "${OB:-/nonexistent}/MemoryCore.build" ]; }
relocated() { local f=$1; sed -e "s#/private/tmp/#$R/#g" "scripts/$f" > "$OUT/src/$f"; echo "$OUT/src/$f"; }
LLAMA=(-Xcc -fmodule-map-file="$B/CLlamaBridge.build/module.modulemap")
APPDEPS=(MemoryCore HistoryCore CoreIntegration WriterBackend PrivacyPolicy BrowserBridge CLlamaBridge)

# The tree is a git checkout. typing-wiring-source, connect-horizon, test-copy-identity and developer-id-release read
# `git ls-files` / `git check-ignore`; in a plain copy (the 10/07 run) they went red for that reason alone. One clear
# red here names the cause.
step git-checkout bash -c 'if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then echo "PASS the source tree is a git checkout"; else echo "FAIL the source tree is not a git checkout: run in a git worktree (git worktree add), not a copy"; exit 1; fi'
# The manifest itself (no build): the runner's step list matches it, the verifier's own cases, no orphan check file.
step manifest-dryrun bash -c "env -u ONLY -u LANES DRYRUN=1 SRC='$WT' WORKDIR='$I/dryrun' bash '$C/run-checks.sh' dry >/dev/null 2>&1; python3 scripts/verify-run-manifest.py --dryrun '$I/dryrun/out-dry/DRYRUN-steps.tsv'"
step manifest-verifier-py python3 scripts/verify-run-manifest-checks.py
step manifest-inventory python3 scripts/verify-run-manifest.py --inventory
# The deployment-target lint: every API and SF Symbols name newer than macOS 15 sits under #available (the compiler
# misses symbol names, which draw nothing on macOS 15, and code under flags the build skips).
step deployment-api-py python3 scripts/check_macos13_api.py
step build swift build --jobs 3 --scratch-path "$BUILD" --disable-automatic-resolution
# The duplicated checks run once, in the owner lane (owner-*: both shipped flags against the flagged objects $OB);
# the unflagged build keeps the public-contract steps (its build, PrivacyChecks, the binary scans) and the checks
# that have no owner twin yet.
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
# perf-1005: What happened folds back-to-back rows of the same app, site and kind; a card's member actions are one read
# (the same actions as the page walk, a fraction of its cost). Headless: fictional actions and a scratch store.
if [ -f scripts/what-happened-fold-checks.swift ]; then
  step compile-what-happened-fold swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite "${LLAMA[@]}" \
    scripts/what-happened-fold-checks.swift $(objs MemoryCore HistoryCore PrivacyPolicy MemoryUI) -lc++ -lsqlite3 -o "$OUT/what-happened-fold"
  step what-happened-fold "$OUT/what-happened-fold"
fi
# perf2-1005: the input tap's wait for the main thread is bounded (a stalled main no longer makes macOS turn the tap off),
# and the typing key's Keychain read is made ahead off the main thread. Headless: synthetic events, in-memory key store.
if [ -f scripts/tap-handoff-checks.swift ]; then
  step compile-tap-handoff swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite "${LLAMA[@]}" \
    scripts/tap-handoff-checks.swift $(objs MemoryCore HistoryCore PrivacyPolicy) -lc++ -lsqlite3 -o "$OUT/tap-handoff"
  step tap-handoff "$OUT/tap-handoff"
fi
# claude/dayeval-1005: never "draft" on screen or to an AI app (stored words are rewritten at display time).
if [ -f scripts/no-draft-display-checks.swift ]; then
  step compile-no-draft-display swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite "${LLAMA[@]}" \
    scripts/no-draft-display-checks.swift $(objs MemoryCore HistoryCore PrivacyPolicy MemoryUI) -lc++ -lsqlite3 -o "$OUT/no-draft-display"
  step no-draft-display "$OUT/no-draft-display"
fi
# claude/search-1005 (owner decision 2026-10-04): the Web searches card lists each search with its words.
if [ -f scripts/search-words-checks.swift ]; then
  step compile-search-words swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite \
    scripts/search-words-checks.swift $(objs MemoryCore HistoryCore PrivacyPolicy MemoryUI) -lc++ -lsqlite3 -o "$OUT/search-words"
  step search-words "$OUT/search-words"
fi
if [ -f scripts/store-main-thread-source-checks.py ]; then
  step store-main-thread-source-py python3 scripts/store-main-thread-source-checks.py -v
fi
if [ -f scripts/store-main-thread-checks.swift ]; then
  SMTSRC=$(appsrc); mkdir -p "$OUT/store-main-thread-home/Library/Preferences" "$OUT/store-main-thread-dd"
  sed -e "s#/private/tmp/daydream-#$R/daydream-#g" scripts/store-main-thread-checks.swift > "$OUT/src/store-main-thread-checks.swift"
  step compile-store-main-thread swiftc -D DEVELOPMENT_SOURCE_CHECKS -parse-as-library ${PERF_STORE_SWIFT_FLAGS:-} -module-cache-path "$I/modcache" -I "$B/Modules" \
    -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$B/CLlamaBridge.build/module.modulemap" \
    -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include" -F "$B" -framework Sparkle -Xlinker -rpath -Xlinker "$B" \
    "$SMTSRC"/*.swift "$OUT/src/store-main-thread-checks.swift" \
    $(for t in MemoryCore MemoryUI HistoryCore CoreIntegration PrivacyPolicy BrowserBridge WriterBackend CLlamaBridge BackupRestore; do [ -d "$B/$t.build" ] && ls "$B/$t.build/"*.o; done) \
    -lc++ -o "$OUT/store-main-thread"
  step store-main-thread env HOME="$OUT/store-main-thread-home" CFFIXED_USER_HOME="$OUT/store-main-thread-home" DD_CHECK_OUT="$OUT/store-main-thread-dd" "$OUT/store-main-thread"
  # claude/perf3-1005: the recorder's heartbeat, the status and typing refreshes, today's reread and a scroll of the day
  # run no statement on the main thread (StoreMainThread); the heartbeat writes only what changed. Offscreen window.
  # Runs in the owner lane (owner-store-main-thread-guard); its scratch copy is made here.
  [ -f scripts/store-main-thread-guard-checks.swift ] && sed -e "s#/private/tmp/daydream-#$R/daydream-#g" scripts/store-main-thread-guard-checks.swift > "$OUT/src/store-main-thread-guard-checks.swift"
fi
step privacy-build swift build --jobs 3 --package-path PrivacyPolicy --scratch-path "$BUILD-pp" --disable-automatic-resolution --product PrivacyChecks
step PrivacyChecks "$BUILD-pp/debug/PrivacyChecks"
# memory-controls, onboarding-staging, typed-store (vault: crypto, raw rows and file bytes), ai-read-typed ("Let AI apps
# see your typed words") and typed-secret-fuzz (seeded synthetic secret shapes) run in the owner lane.
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
# search-results-ui, typed-launch (vault attach, settle, hourly expiry) and typing-unlock-delivery: owner lane.
step typing-wiring-source-py python3 scripts/typing-wiring-source-checks.py -v
# claude/typing-1004: public 0.1.4 compiles typing like the owner copy; the Chrome window title only breaks ties;
# a tap that gets no keys stops with the reason that offers Quit & Reopen.
if [ -f scripts/typing-public-lane-checks.py ]; then
  step typing-public-lane-py python3 scripts/typing-public-lane-checks.py
fi
# claude/crashguard-015: APIs that assert the main queue (Text Input Sources, TSM, NSEvent characters, Carbon hot keys)
# only in listed functions behind MainQueue.require(); nothing main-only inside an off-main block (owner laptop 10/04:
# TSM trapped off the main queue on macOS 15, not on 26).
if [ -f scripts/check_main_thread_apis.py ]; then
  step main-thread-apis-py python3 scripts/check_main_thread_apis.py
fi
CAPTURE=$(python3 -c "import re;s=open('scripts/daydream-core-source-checks.py').read();print(' '.join('Sources/MacMemApp/%s.swift'%n for n in eval(re.search(r'capture=(\[[^\]]*\])',s).group(1))))")
python3 "$C/copy-check-source.py" Sources/MacMemApp/Coordinator.swift "$R" > "$OUT/src/headless-Coordinator.swift"
CAPTURE=${CAPTURE/Sources\/MacMemApp\/Coordinator.swift/$OUT\/src\/headless-Coordinator.swift}
echo "core-source capture list: $CAPTURE" > "$OUT/core-source-capture-list.txt"
# production-capture, recording-fault (a failed capture write never stops recording for good), save-path (nothing
# momentary stops saving for good), capture-input (the input tap macOS turns off, late keys), native-witness and
# typing-choice run in the owner lane.
step compile-onboarding-flow swiftc -parse-as-library -module-cache-path "$I/modcache" \
  Sources/MacMemApp/DaydreamOnboardingState.swift scripts/onboarding-flow-checks.swift -o "$OUT/onboarding-flow"
step onboarding-flow "$OUT/onboarding-flow"
# level-binding (the level writer loads the runtime only while it writes) and preference-save: owner lane. core-adapter
# runs in both: owner-core-adapter is the shipped build; this unflagged one is the contributor build's contract (a plain
# `swift build` of the open-source tree), whose typing refuses Claude, Terminal and the other flag-gated apps as
# excluded before any character is read (the #else branches no owner step reaches).
step compile-core-adapter swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite "${LLAMA[@]}" \
  adapters/CoreWriterBinding.swift adapters/CoreCaptureBinding.swift scripts/core-adapter-checks.swift \
  $(objs MemoryCore HistoryCore WriterBackend PrivacyPolicy BrowserBridge CLlamaBridge) -lc++ -o "$OUT/core-adapter"
step core-adapter "$OUT/core-adapter"
# rel-018: any real bundle ID can be skipped (underscores, spaces); the picker lists only what saves; every app on this Mac saves.
if [ -f scripts/skipped-app-id-checks.swift ]; then
  SAHOME=$OUT/skipped-app-id-home; mkdir -p "$SAHOME/Library/Preferences"
  step compile-skipped-app-id swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" \
    -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" \
    scripts/skipped-app-id-checks.swift $(objs MemoryUI MemoryCore HistoryCore PrivacyPolicy) -o "$OUT/skipped-app-id"
  step skipped-app-id env HOME="$SAHOME" CFFIXED_USER_HOME="$SAHOME" "$OUT/skipped-app-id"
fi
# rel-018: setup's Input Monitoring step side by side, with the drop zone and the chip (pure parts, renders, source rules).
if [ -f scripts/permission-drag-guide-checks.swift ]; then
  PDGHOME=$OUT/permission-drag-guide-home; PDGDD=$OUT/permission-drag-guide-dd; mkdir -p "$PDGHOME/Library/Preferences" "$PDGDD"
  step compile-permission-drag-guide swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" \
    -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" \
    scripts/permission-drag-guide-checks.swift $(objs MemoryUI MemoryCore HistoryCore PrivacyPolicy) -o "$OUT/permission-drag-guide"
  step permission-drag-guide env HOME="$PDGHOME" CFFIXED_USER_HOME="$PDGHOME" DD_CHECK_OUT="$PDGDD" "$OUT/permission-drag-guide"
fi
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
# writer-retention and cloud-scope (cloud summaries never get Chrome pages): owner lane.
# gold/notes: notes and summary-writer regressions (G15 G18-G26 G52 G63 G73 extra6, status latches).
# Synthetic stores under $OUT only (NOTES_CHECK_ROOT: the writer's ledger folder must not sit under a symlink like /var).
if [ -f scripts/notes-golden-checks.swift ]; then
  step compile-notes-golden swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite "${LLAMA[@]}" \
    adapters/CoreWriterBinding.swift Sources/MacMemApp/WriterScheduling.swift scripts/notes-golden-checks.swift \
    $(objs "${APPDEPS[@]}") -lc++ -o "$OUT/notes-golden"
  mkdir -p "$OUT/notes-fixtures"
  step notes-golden env HOME="$OUT/notes-home" CFFIXED_USER_HOME="$OUT/notes-home" NOTES_CHECK_ROOT="$OUT/notes-fixtures" "$OUT/notes-golden"
fi
# notes-writer: owner lane.
# fix/sx-engine-battery: the writer's cadence on a busy synthetic day (power, battery, an AI app, Low Power Mode,
# catch-up) and its state machine (phases, download, Off, cloud failures), both through the real WriterIntegration with
# a fake model, installer and OpenRouter. No network, keys, model or capture. Then the WriterBackend package checks.
WRITERSRC="Sources/MacMemApp/WriterIntegration.swift Sources/MacMemApp/WriterScheduling.swift Sources/MacMemApp/WriterQuiet.swift Sources/MacMemApp/WriterPreferences.swift Sources/MacMemApp/LevelPower.swift adapters/CoreWriterBinding.swift adapters/LevelWriterBinding.swift"
# fix/writing-forever: writer-spin (fix/perf7) joins them (same recipe). writer-cadence, writer-state and writer-spin
# run in the owner lane (the shipped flags keep typed rows, so the model's load and per-moment caps are exercised).
for name in writer-quiet; do
  if [ -f scripts/$name-checks.swift ]; then
    step compile-$name swiftc -parse-as-library -target arm64-apple-macosx15.0 -module-cache-path "$I/modcache" \
      -I "$B/Modules" -I Sources/CSQLite -I WriterBackend/Sources/CLlamaBridge/include "${LLAMA[@]}" \
      $WRITERSRC scripts/$name-checks.swift "$B"/WriterBackend.build/*.swift.o "$B"/CLlamaBridge.build/WriterLlama.cpp.o \
      $(objs MemoryCore HistoryCore MemoryUI CoreIntegration PrivacyPolicy BrowserBridge) -lsqlite3 -lc++ -o "$OUT/$name"
    mkdir -p "$OUT/$name-home" "$OUT/$name-root"
    step $name env HOME="$OUT/$name-home" CFFIXED_USER_HOME="$OUT/$name-home" CADENCE_ROOT="$OUT/$name-root" STATE_CHECK_ROOT="$OUT/$name-root" nice "$OUT/$name"
  fi
done
step compile-writer-app-integration swiftc -parse-as-library -target arm64-apple-macosx15.0 -module-cache-path "$I/modcache" \
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
step compile-wb-batch swiftc -parse-as-library -target arm64-apple-macosx15.0 -module-cache-path "$I/modcache" -I "$B/Modules" \
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
# summary-sends (sends kept in word-less moments, writer/core claim agreement): owner lane.
# claude/ready-1002: one fallback line per distinct sentence; terminal titles without tool status glyphs or bare shells.
# claude/summary-1003: terminal and AI-tool summaries (Claude Code prompts, shell commands by purpose, no filler beside real lines).
if [ -f scripts/summary-terminal-checks.swift ]; then
  step compile-summary-terminal swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite "${LLAMA[@]}" \
    scripts/summary-terminal-checks.swift $(objs MemoryCore HistoryCore WriterBackend PrivacyPolicy CLlamaBridge) -lc++ -o "$OUT/summary-terminal"
  step summary-terminal "$OUT/summary-terminal"
fi
# summary-fail (a failed Summarize Now; the card's states and footer): owner lane.
if [ -f scripts/summary-ready-checks.swift ]; then
  step compile-summary-ready swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite "${LLAMA[@]}" \
    scripts/summary-ready-checks.swift $(objs MemoryCore HistoryCore WriterBackend PrivacyPolicy CLlamaBridge) -lc++ -o "$OUT/summary-ready"
  step summary-ready "$OUT/summary-ready"
fi
# claude/dayeval-1005: moment cards without a model's note (code's note for every moment, no model load or cloud send).
if [ -f scripts/moment-cards-checks.swift ]; then
  step compile-moment-cards swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite "${LLAMA[@]}" \
    scripts/moment-cards-checks.swift $(objs MemoryCore HistoryCore WriterBackend PrivacyPolicy CLlamaBridge) -lsqlite3 -lc++ -o "$OUT/moment-cards"
  step moment-cards "$OUT/moment-cards"
fi
# The Today card's day review (rank groups, hysteresis, clauses, quotes, Forget, model failure) and its six-persona eval
# (apps the owner doesn't use; must-holds, then the rubric score) run in the owner lane with Messages typing.
# gold/notes: G24 lives in the existing action-audit check (its 5000-action assertion now expects the whole day).
if [ -f scripts/action-audit-checks.swift ]; then
  step compile-action-audit swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite \
    scripts/action-audit-checks.swift $(objs MemoryCore HistoryCore PrivacyPolicy) -o "$OUT/action-audit"
  step action-audit "$OUT/action-audit"
fi
# scripts/run-*.sh equivalents (they cd to another checkout and write /private/tmp/daydream-*).
# int-1003: cc-label-1003's TerminalToolProcesses.swift is what Coordinator asks for a terminal's AI tool.
APPFILES="Sources/MacMemApp/BrowserProviderResolver.swift Sources/MacMemApp/BrowserCaptureTransport.swift Sources/MacMemApp/BrowserCaptureReceipt.swift Sources/MacMemApp/NativeCaptureReceipts.swift Sources/MacMemApp/NativeFocusWitness.swift Sources/MacMemApp/Coordinator.swift Sources/MacMemApp/EventCapture.swift Sources/MacMemApp/MessagesComposer.swift Sources/MacMemApp/AccessibilitySnapshot.swift Sources/MacMemApp/ChromeModeReader.swift Sources/MacMemApp/ChromeEventSender.swift Sources/MacMemApp/ChromePageRecorder.swift Sources/MacMemApp/NativeTypingRoute.swift Sources/MacMemApp/TypingHotkey.swift Sources/MacMemApp/WebTypingRoute.swift Sources/MacMemApp/TerminalToolProcesses.swift"
# browser-app-0227, browser-provider-0240, app-bindings-0132 and native-receipt-0053 run with these files in the owner lane.
step browser-boundary-py python3 scripts/check_browser_boundary.py -v
# Safe typing H (access slice): claim wording in app strings and docs stays literally true.
step typed-claim-checks python3 scripts/typed-claim-checks.py -v
# Anonymous usage counts: approved keys only, no networking in mac-mem, no sending from check or development builds.
[ -f scripts/usage-counts-checks.py ] && step usage-counts-py python3 scripts/usage-counts-checks.py -v
step native-coverage-mjs "${NODE_BIN:-node}" --test BrowserBridge/fixtures/native-coverage-checks.mjs
step harness-source-py python3 tools/chrome-device-test/check_harness_source.py -v
step qa-harness-boundary-py python3 scripts/check-qa-harness-boundary.py -v
step harness-build swift build --jobs 3 --package-path tools/chrome-device-test --scratch-path "$I/harness-build" --disable-automatic-resolution
step harness-selftest "$I/harness-build/debug/chrome-device-test-selftest"
# The Chrome-typing-only private build (-DDAYDREAM_CHROME_TYPING alone) is gone: nothing ships it. The owner build
# (both flags, what every release stage builds) carries Chrome typing; binary-features below scans both builds.
# Review C7: the release MacMem (what the public ships) carries no private
# Chrome typing symbol or string either.
step release-build swift build --jobs 3 -c release --product MacMem --scratch-path "$I/build-release" --disable-automatic-resolution
step release-scan python3 scripts/chrome-typing-checks.py --binary "$I/build-release/release/MacMem"
# Safe typing E (categories slice): the legal gate runs as owner-typing-gate (public and owner release objects).
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
# claude/perf3-1005: the main-thread guard check again, with both flags against the flagged objects (the shipped build).
if [ -f scripts/store-main-thread-guard-checks.swift ] && [ -n "${SMTSRC:-}" ]; then
  mkdir -p "$OUT/owner-store-main-thread-guard-home/Library/Preferences" "$OUT/owner-store-main-thread-guard-dd"
  step compile-owner-store-main-thread-guard swiftc -D DEVELOPMENT_SOURCE_CHECKS -D DAYDREAM_OWNER_TYPING -D DAYDREAM_CHROME_TYPING -parse-as-library -module-cache-path "$I/modcache" -I "$OB/Modules" \
    -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$OB/CLlamaBridge.build/module.modulemap" \
    -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include" -F "$OB" -framework Sparkle -Xlinker -rpath -Xlinker "$OB" \
    "$SMTSRC"/*.swift "$OUT/src/store-main-thread-guard-checks.swift" \
    $(for t in MemoryCore MemoryUI HistoryCore CoreIntegration PrivacyPolicy BrowserBridge WriterBackend CLlamaBridge BackupRestore; do [ -d "$OB/$t.build" ] && ls "$OB/$t.build/"*.o; done) \
    -lc++ -o "$OUT/owner-store-main-thread-guard"
  step owner-store-main-thread-guard env HOME="$OUT/owner-store-main-thread-guard-home" CFFIXED_USER_HOME="$OUT/owner-store-main-thread-guard-home" DD_CHECK_OUT="$OUT/owner-store-main-thread-guard-dd" "$OUT/owner-store-main-thread-guard"
fi
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
  OCIMSRC=$(appsrc)
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
  UCSRC=$(appsrc)
  ucobjs() { for t in MemoryCore MemoryUI HistoryCore CoreIntegration PrivacyPolicy BrowserBridge WriterBackend CLlamaBridge BackupRestore; do
    [ -d "$1/$t.build" ] && ls "$1/$t.build/"*.o; done; }
  for lane in owner; do
    UB=$OB; UF=(-D DAYDREAM_OWNER_TYPING -D DAYDREAM_CHROME_TYPING)
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
# What each MacMem carries (nm and strings): public debug and release hold no private Chrome typing or website typing
# symbol, no Other websites row and no OWNER BUILD string, and do carry Chrome page history; the owner debug and release
# carry website typing, its help and page history, and the owner debug carries every private symbol and string (so the
# public scans are not vacuous). One step, every assertion reported.
step binary-features python3 scripts/binary-feature-checks.py --public-debug "$B/MacMem" --public-release "$I/build-release/release/MacMem" \
  --owner-debug "$OB/MacMem" --owner-release "$I/build-owner-release/release/MacMem"
# Source rules, the compile guard, the release refusal, and probes linked
# against the public and the owner RELEASE PrivacyPolicy objects.
step owner-typing-gate python3 scripts/typing-release-gate-checks.py -v --release "$I/build-release/release" --owner "$I/build-owner-release/release" --tmp "$I/tmp"
# public-typing review (release, high): the shipped-build lane. The swiftc checks above, compiled again with
# both flags against the flagged objects ($OB) that every release stage builds (the UI half is in ui-checks.sh).
# Cocoa Scripting parses Chrome's dictionary the way the Chrome typing code expects (a Chrome-shaped sdef fixture embedded
# as this binary's scripting dictionary; no Apple Event is sent), with both shipped flags against $OB.
CPDIR=$OUT/chrome-parse; mkdir -p "$CPDIR"; cp scripts/fixtures/chrome-shaped.sdef "$CPDIR/ChromeShaped.sdef"
python3 -c "import plistlib,sys;open(sys.argv[1],'wb').write(plistlib.dumps({'CFBundleIdentifier':'local.synthetic.chrome-parse-checks','NSAppleScriptEnabled':True,'OSAScriptingDefinition':'ChromeShaped.sdef'}))" "$CPDIR/embedded-info.plist"
step compile-owner-chrome-parse swiftc -parse-as-library -D DAYDREAM_OWNER_TYPING -D DAYDREAM_CHROME_TYPING -module-cache-path "$I/modcache" \
  -I "$OB/Modules" -I Sources/CSQLite scripts/chrome-apple-event-parse-checks.swift $(oobjs MemoryCore HistoryCore PrivacyPolicy) -lsqlite3 \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$CPDIR/embedded-info.plist" -o "$CPDIR/chrome-apple-event-parse-checks"
step owner-chrome-parse "$CPDIR/chrome-apple-event-parse-checks"
source "$C/owner-lane.sh"
# Saturday (sat/v1): release pipeline, public-cleanup and rename checks. Added steps only.
step signing-plan-py python3 scripts/check_signing_plan.py -v
step developer-id-release-py python3 scripts/check_developer_id_release.py -v
# ship-1004: the bundled Typesense's public record, source kit, notice and update gates (inert fixtures, no signing).
step search-payload-py python3 scripts/check_search_payload.py -v
step owner-updates-py env DAYDREAM_TEST_CLI="$OB/mac-mem" python3 scripts/check_updates.py -v
step packaging-py python3 scripts/check_daydream_packaging.py -v
step brand-py python3 scripts/check_daydream_brand.py
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
  RECSRC=$(appsrc)
  sed -e "s#/private/tmp/daydream-#$R/daydream-#g" scripts/recording-model-checks.swift > "$OUT/src/recording-model-checks.swift"
  recobjs() { for t in MemoryCore MemoryUI HistoryCore CoreIntegration PrivacyPolicy BrowserBridge WriterBackend CLlamaBridge BackupRestore; do
    [ -d "$B/$t.build" ] && ls "$B/$t.build/"*.o; done; }
  step compile-recording-model swiftc -D DEVELOPMENT_SOURCE_CHECKS -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" \
    -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$B/CLlamaBridge.build/module.modulemap" \
    -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include" -F "$B" -framework Sparkle -Xlinker -rpath -Xlinker "$B" \
    "$RECSRC"/*.swift "$OUT/src/recording-model-checks.swift" $(recobjs) -lc++ -o "$OUT/recording-model"
  step recording-model env HOME="$RECHOME" CFFIXED_USER_HOME="$RECHOME" DD_CHECK_OUT="$RECDD" "$OUT/recording-model"
  # rc-018 RC3 (package A): the restart waits for System Settings' sheet, setup comes back in front on its page after
  # any relaunch, recording wanted survives it, the held memory window, the hand-back, the Live Test mark. The REAL
  # MemoryViewModel and setup with the check seams (in-memory defaults, nothing activates, hidden windows only).
  if [ -f scripts/setup-lifecycle-checks.swift ]; then
    SLCHOME=$OUT/setup-lifecycle-home; SLCDD=$OUT/setup-lifecycle-dd; mkdir -p "$SLCHOME/Library/Preferences" "$SLCDD"; chmod 700 "$SLCDD"
    step compile-setup-lifecycle swiftc -D DEVELOPMENT_SOURCE_CHECKS -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" \
      -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$B/CLlamaBridge.build/module.modulemap" \
      -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include" -F "$B" -framework Sparkle -Xlinker -rpath -Xlinker "$B" \
      "$RECSRC"/*.swift scripts/setup-lifecycle-checks.swift $(recobjs) -lc++ -o "$OUT/setup-lifecycle"
    step setup-lifecycle env HOME="$SLCHOME" CFFIXED_USER_HOME="$SLCHOME" DD_CHECK_OUT="$SLCDD" "$OUT/setup-lifecycle"
  fi
  # gold/capture-input (golden 5 G32, G3): Input Monitoring turned on while DayDream runs sends every Start to
  # Permissions (Quit & Reopen); a lost input tap keeps recording wanted: owner-capture-input-model (owner lane).
  # gold/lifecycle (test 5): launch resume (G10, G42, Extra 1), Open at login (G10b), an import or restore preview an
  # automatic start waits on (Extra 2, Extra 4, the lock-fix nit), latched lines (G4, G35, G36, Extra 3), a second copy
  # (G39), a wake start that stops at once (G56) and Stop in Needs Permission (G65), on the REAL MemoryViewModel with
  # the check seams (in-memory typing keys, no event tap, no login item, private defaults). Owner objects.
  if [ -f scripts/lifecycle-model-checks.swift ]; then
    if have_ob; then
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
    if have_ob; then
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
  # permflash-015 (owner 10/4: "the permission screen flashes for two frames though everything is on"): what every
  # surface SHOWS of the permissions follows a settled value (PermissionSettle): an off read changes it only once the
  # reads have stayed off for the settle time; a permission really off still shows within the bound; the person's own
  # Start, a first setup and the recorder are unchanged. The REAL MemoryViewModel with the check seams, plus the
  # permission page and setup hosted in a window never ordered on screen. Then the mutation: the same check against a
  # copy of the app source whose shown value takes every read as it is must FAIL (else the check guards nothing).
  if [ -f scripts/permission-flash-checks.swift ]; then
    flash_mutant() { # <lane: "" | owner-> <modules dir> <objs fn> <flags...>
      local lane=$1 mb=$2 objs=$3; shift 3
      local src=$OUT/src/${lane}flash-mutant; rm -rf "$src"; mkdir -p "$src"; cp "$RECSRC"/*.swift "$src/"
      python3 - "$src/MacMemApp.swift" <<'PY' || return 1
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = "else {shown=permissionShown.read(read,at:now,settle:settle,counts:awake && !wake.suspended)}"
if s.count(old) != 1: print("FAIL: the settle line is not in MacMemApp.swift exactly once (%d)" % s.count(old)); sys.exit(1)
p.write_text(s.replace(old, "else {shown=permissionShown.take(read)}"))
PY
      local home=$OUT/${lane}permission-flash-mutant-home dd=$OUT/${lane}permission-flash-mutant-dd; mkdir -p "$home/Library/Preferences" "$dd"; chmod 700 "$dd"
      swiftc "$@" -D DEVELOPMENT_SOURCE_CHECKS -parse-as-library -module-cache-path "$I/modcache" -I "$mb/Modules" \
        -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$mb/CLlamaBridge.build/module.modulemap" \
        -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include" -F "$mb" -framework Sparkle -Xlinker -rpath -Xlinker "$mb" \
        "$src"/*.swift scripts/permission-flash-checks.swift $($objs) -lc++ -o "$OUT/${lane}permission-flash-mutant" || { echo "FAIL: the mutant did not compile"; return 1; }
      env HOME="$home" CFFIXED_USER_HOME="$home" DD_CHECK_OUT="$dd" DD_FLASH_ONLY=A,B,G "$OUT/${lane}permission-flash-mutant" > "$OUT/${lane}permission-flash-mutant.out" 2>&1
      local rc=$? fails; fails=$(grep -cE '^FAIL' "$OUT/${lane}permission-flash-mutant.out")
      if [ "$rc" -ne 0 ] && [ "$fails" -gt 0 ]; then echo "PASS [mutation] without the settle the flash checks fail: exit=$rc, $fails FAIL lines"; return 0; fi
      echo "FAIL [mutation] without the settle the flash checks still pass (exit=$rc, $fails FAIL lines): they guard nothing"; return 1; }
    if have_ob; then
      OPFHOME=$OUT/owner-permission-flash-home; OPFDD=$OUT/owner-permission-flash-dd; mkdir -p "$OPFHOME/Library/Preferences" "$OPFDD"; chmod 700 "$OPFDD"
      step compile-owner-permission-flash swiftc -D DEVELOPMENT_SOURCE_CHECKS -D DAYDREAM_OWNER_TYPING -D DAYDREAM_CHROME_TYPING -parse-as-library \
        -module-cache-path "$I/modcache" -I "$OB/Modules" \
        -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$OB/CLlamaBridge.build/module.modulemap" \
        -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include" -F "$OB" -framework Sparkle -Xlinker -rpath -Xlinker "$OB" \
        "$RECSRC"/*.swift scripts/permission-flash-checks.swift $(opbobjs) -lc++ -o "$OUT/owner-permission-flash"
      step owner-permission-flash env HOME="$OPFHOME" CFFIXED_USER_HOME="$OPFHOME" DD_CHECK_OUT="$OPFDD" "$OUT/owner-permission-flash"
      step owner-permission-flash-mutation flash_mutant owner- "$OB" opbobjs -D DAYDREAM_OWNER_TYPING -D DAYDREAM_CHROME_TYPING
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
    if have_ob; then
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
      if have_ob; then
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
  UQSRC=$(appsrc)
  UQHOME=$OUT/update-quit-home; mkdir -p "$UQHOME/Library/Preferences"
  uqobjs() { for t in MemoryCore MemoryUI HistoryCore CoreIntegration PrivacyPolicy BrowserBridge WriterBackend CLlamaBridge BackupRestore; do
    [ -d "$1/$t.build" ] && ls "$1/$t.build/"*.o; done; }
  uqcompile() { local name=$1 b=$2; shift 2
    step compile-$name swiftc -D DEVELOPMENT_SOURCE_CHECKS "$@" -parse-as-library -module-cache-path "$I/modcache" -I "$b/Modules" \
      -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$b/CLlamaBridge.build/module.modulemap" \
      -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include" -F "$b" -framework Sparkle -Xlinker -rpath -Xlinker "$b" \
      "$UQSRC"/*.swift scripts/update-quit-checks.swift $(uqobjs "$b") -lc++ -o "$OUT/$name"
    step $name env HOME="$UQHOME" CFFIXED_USER_HOME="$UQHOME" "$OUT/$name"; }
  have_ob && uqcompile owner-update-quit "$OB" -D DAYDREAM_OWNER_TYPING -D DAYDREAM_CHROME_TYPING
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
  # connect-config and connect-diagnostics run in the owner lane.
  for name in connect-toml connect-skill; do
    [ -f "scripts/$name-checks.swift" ] || continue
    step compile-$name swiftc -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules" -I Sources/CSQLite \
      scripts/$name-checks.swift $(objs MemoryCore HistoryCore PrivacyPolicy) -o "$OUT/$name"
    step $name "$OUT/$name"
  done
  step owner-connect-cli-py env DAYDREAM_TEST_CLI="$OB/mac-mem" python3 scripts/connect-cli-checks.py
  # No Horizon/SSH string in any built binary (public and owner, debug and release) or the sources: one scan.
  step connect-horizon-py python3 scripts/connect-horizon-checks.py --binary "$I/build-release/release/MacMem" --binary "$B/MacMem" --binary "$B/mac-mem" \
    --binary "$I/build-owner-release/release/MacMem" --binary "$I/build-owner-release/release/mac-mem" --binary "$OB/MacMem" --binary "$OB/mac-mem"
  # gold/connections-storage (G13, G45): an AI app's server carries on across an update, follows a repaired history.
  if [ -f scripts/mcp-update-checks.py ]; then
    step owner-mcp-update-py env DAYDREAM_TEST_CLI="$OB/mac-mem" python3 scripts/mcp-update-checks.py
  fi
  # claude/mcp-prompts-1003: the MCP server's text and replies (instructions, response_format, concise Markdown, isError
  # results), its resources, and the DayDream Agent Skill. Scratch histories from `mac-mem demo` and fixtures only.
  for lane in owner-; do
    CLI_FOR=$B; [ -n "$lane" ] && CLI_FOR=$OB
    step ${lane}mcp-interfaces-py env DAYDREAM_TEST_CLI="$CLI_FOR/mac-mem" python3 scripts/check_interfaces.py
    step ${lane}mcp-readiness-py env DAYDREAM_TEST_CLI="$CLI_FOR/mac-mem" python3 scripts/mcp-readiness-checks.py
    step ${lane}mcp-resources-py env MACMEM_TEST_CLI="$CLI_FOR/mac-mem" python3 scripts/check_action_resources.py
    # claude/recall-1004: every tool the MCP text names (Next lines, hints, instructions) is in that build's tool list.
    [ -f scripts/mcp-tool-hint-checks.py ] && step ${lane}mcp-tool-hints-py env DAYDREAM_TEST_CLI="$CLI_FOR/mac-mem" python3 scripts/mcp-tool-hint-checks.py
  done
  step mcp-skill-py python3 scripts/mcp-skill-checks.py
  [ -f scripts/agent-skill-embed.py ] && step agent-skill-embed-py python3 scripts/agent-skill-embed.py --check
  CONNHOME=$OUT/connect-home; CONNDD=$OUT/connect-dd; mkdir -p "$CONNHOME/Library/Preferences" "$CONNDD"
  CONNSRC=$(appsrc)
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
  step compile-wb-core-lib swiftc -parse-as-library -emit-library -emit-module -module-name WriterBackend -target arm64-apple-macosx15.0 \
    -module-cache-path "$I/modcache" WriterBackend/Sources/WriterBackend/{Contract,LocalWriter,CloudWriter,CloudActivation,CloudTransport,CanonicalNotes,SourceClauseCoverage,ModelView,CoreWriterAdapter,LongMomentNotes}.swift \
    -emit-module-path "$WBT/WriterBackend.swiftmodule" -o "$WBT/libWriterBackend.dylib"
  step compile-wb-core swiftc -parse-as-library WriterBackend/CoreChecks.swift -target arm64-apple-macosx15.0 -module-cache-path "$I/modcache" \
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
    PFBSRC=$(appsrc)
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
UI_SOURCED=1
source "$C/ui-checks.sh"
# RC supplements use this candidate's own debug modules and synthetic homes only.
for lane in owner; do
  MB="$OB"; MF=(-D DAYDREAM_OWNER_TYPING -D DAYDREAM_CHROME_TYPING)
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
# Phase 1 commit 9: the check files no step ran before (owner objects, scratch homes), by lane.
source "$C/wired-lanes.sh"
printf '%s\n' ${summary[@]+"${summary[@]}"} | tee "$OUT/SUMMARY"
[ -n "${DRYRUN:-}" ] && exit 0
# The result: every selected manifest step ran (or is a named known failure / a window-lane skip), nothing unlisted ran.
echo "($failed_steps steps exited non-zero; the manifest decides which of them are known)"
python3 scripts/verify-run-manifest.py --summary "$OUT/SUMMARY" --only "${ONLY:-}" --lanes "${LANES:-}" | tee "$OUT/VERDICT"
exit "${PIPESTATUS[0]}"
