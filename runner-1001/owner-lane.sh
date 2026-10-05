#!/bin/bash
# public-typing/v1 review (release, high): the shipped-build lane. Every release stage compiles
# -DDAYDREAM_OWNER_TYPING -DDAYDREAM_CHROME_TYPING (developer-id-release.py OWNER_SWIFT_FLAGS), so the
# swiftc checks and the APP/UI checks that run against the plain (unflagged) objects run again here,
# compiled with both flags against the flagged debug objects ($OB). The unflagged steps stay: they pin
# the plain `swift build` a contributor gets.
# Sourced by run-checks.sh after owner-build (uses its step/OUT/I/R/OB/CAPTURE/APPFILES/relocated),
# or by ui-checks.sh for OWNER_UI=1 (the UI half). Nothing launches, records, prompts or signs.
OB=${OB:?OB}
OSW=(-D DAYDREAM_OWNER_TYPING -D DAYDREAM_CHROME_TYPING)
oobjs() { for t in "$@"; do ls "$OB/$t.build/"*.o; done; }
OLLAMA=(-Xcc -fmodule-map-file="$OB/CLlamaBridge.build/module.modulemap")
OAPPDEPS=(MemoryCore HistoryCore CoreIntegration WriterBackend PrivacyPolicy BrowserBridge CLlamaBridge)
# The app files with the flags: WebTypingRoute.swift compiles in, so its Chrome witness must too.
OAPPFILES="$APPFILES Sources/MacMemApp/ChromeTypingWitness.swift"

if [ -z "${OWNER_UI:-}" ]; then
  # claude/day-review-1003: the day review with Messages typing (texting-heavy day, a high-stakes text, quotes).
  if [ -f scripts/day-review-checks.swift ]; then
    step compile-owner-day-review swiftc -parse-as-library "${OSW[@]}" -target arm64-apple-macosx15.0 -module-cache-path "$I/modcache" \
      -I "$OB/Modules" -I Sources/CSQLite -I WriterBackend/Sources/CLlamaBridge/include "${OLLAMA[@]}" \
      scripts/day-review-checks.swift "$OB"/WriterBackend.build/*.swift.o "$OB"/CLlamaBridge.build/WriterLlama.cpp.o \
      $(oobjs MemoryCore HistoryCore MemoryUI CoreIntegration PrivacyPolicy BrowserBridge) -lsqlite3 -lc++ -o "$OUT/owner-day-review"
    mkdir -p "$OUT/owner-day-review-root" "$OUT/owner-day-review-home/Library/Preferences"
    step owner-day-review env HOME="$OUT/owner-day-review-home" CFFIXED_USER_HOME="$OUT/owner-day-review-home" DAY_REVIEW_ROOT="$OUT/owner-day-review-root" nice "$OUT/owner-day-review"
  fi
  # claude/searchui-1005: the search results' rows and detail, flagged (Messages typing compiles in).
  if [ -f scripts/search-results-ui-checks.swift ]; then
    step compile-owner-search-results-ui swiftc -parse-as-library "${OSW[@]}" -module-cache-path "$I/modcache" -I "$OB/Modules" -I Sources/CSQLite \
      scripts/search-results-ui-checks.swift $(oobjs MemoryCore HistoryCore PrivacyPolicy MemoryUI) -lsqlite3 -lc++ -o "$OUT/owner-search-results-ui"
    mkdir -p "$OUT/owner-search-results-ui-dd"
    step owner-search-results-ui env DD_CHECK_OUT="$OUT/owner-search-results-ui-dd" "$OUT/owner-search-results-ui"
  fi
  # claude/dayeval-1005: the synthetic-persona day review eval with the shipped flags.
  if [ -f scripts/day-review-eval-checks.swift ]; then
    step compile-owner-day-review-eval swiftc -parse-as-library "${OSW[@]}" -target arm64-apple-macosx15.0 -module-cache-path "$I/modcache" \
      -I "$OB/Modules" -I Sources/CSQLite scripts/day-review-eval-checks.swift $(oobjs MemoryCore HistoryCore PrivacyPolicy) -lsqlite3 -o "$OUT/owner-day-review-eval"
    mkdir -p "$OUT/owner-day-review-eval-root"
    step owner-day-review-eval env DAY_REVIEW_ROOT="$OUT/owner-day-review-eval-root" DAY_REVIEW_EVAL_OUT="$OUT/owner-day-review-eval-cards" nice "$OUT/owner-day-review-eval"
    step owner-day-review-eval-score python3 scripts/day-review-eval.py --cards "$OUT/owner-day-review-eval-cards/default" \
      --refs "$OUT/owner-day-review-eval-cards/refs.json" --min 95 --require privacy=1 nofiller=0.9 order=1 texting=0.9 coverage=0.9
  fi
  # Store-level checks (typed vault, preferences, the setup typing choice, data home, controls).
  for pair in typed-store:typed-store preference-save:preference-save typing-choice:onboarding-typing-choice \
              memory-controls:memory-controls onboarding-staging:onboarding-staging data-home-migration:data-home-migration; do
    name=${pair%%:*}; file=${pair#*:}
    step compile-owner-$name swiftc -parse-as-library "${OSW[@]}" -module-cache-path "$I/modcache" -I "$OB/Modules" -I Sources/CSQLite \
      scripts/$file-checks.swift $(oobjs MemoryCore HistoryCore PrivacyPolicy) -o "$OUT/owner-$name"
    step owner-$name "$OUT/owner-$name"
  done
  # gold/r2-store-perf: the owner build's preparation also settles website typing rows; the short day reads, flagged.
  if [ -f scripts/launch-preparation-checks.swift ]; then
    step compile-owner-launch-preparation swiftc -parse-as-library "${OSW[@]}" -module-cache-path "$I/modcache" -I "$OB/Modules" -I Sources/CSQLite \
      scripts/launch-preparation-checks.swift $(oobjs MemoryCore HistoryCore PrivacyPolicy MemoryUI) -o "$OUT/owner-launch-preparation"
    step owner-launch-preparation "$OUT/owner-launch-preparation"
    step compile-owner-store-perf swiftc -parse-as-library "${OSW[@]}" -module-cache-path "$I/modcache" -I "$OB/Modules" -I Sources/CSQLite \
      scripts/store-perf-checks.swift $(oobjs MemoryCore HistoryCore PrivacyPolicy MemoryUI) -o "$OUT/owner-store-perf"
    step owner-store-perf "$OUT/owner-store-perf"
  fi
  step compile-owner-typed-launch swiftc -parse-as-library "${OSW[@]}" -module-cache-path "$I/modcache" -I "$OB/Modules" -I Sources/CSQLite \
    Sources/MacMemApp/TypedTextExpiryTimer.swift Sources/MacMemApp/TypingHotkey.swift Sources/MacMemApp/TypingModel.swift \
    scripts/typed-launch-checks.swift $(oobjs MemoryCore HistoryCore PrivacyPolicy) -o "$OUT/owner-typed-launch"
  step owner-typed-launch "$OUT/owner-typed-launch"
  step compile-owner-native-witness swiftc -parse-as-library "${OSW[@]}" -module-cache-path "$I/modcache" -I "$OB/Modules" \
    Sources/MacMemApp/NativeFocusWitness.swift scripts/native-focus-witness-checks.swift $(oobjs PrivacyPolicy) -o "$OUT/owner-native-witness"
  step owner-native-witness "$OUT/owner-native-witness"
  step compile-owner-core-adapter swiftc -parse-as-library "${OSW[@]}" -module-cache-path "$I/modcache" -I "$OB/Modules" -I Sources/CSQLite "${OLLAMA[@]}" \
    adapters/CoreWriterBinding.swift adapters/CoreCaptureBinding.swift scripts/core-adapter-checks.swift \
    $(oobjs MemoryCore HistoryCore WriterBackend PrivacyPolicy BrowserBridge CLlamaBridge) -lc++ -o "$OUT/owner-core-adapter"
  step owner-core-adapter "$OUT/owner-core-adapter"
  # messages-1003: Messages send detection, conversation names and sent text through the real binding and store.
  step compile-owner-messages-store swiftc -parse-as-library "${OSW[@]}" -module-cache-path "$I/modcache" -I "$OB/Modules" -I Sources/CSQLite "${OLLAMA[@]}" \
    adapters/CoreCaptureBinding.swift scripts/messages-store-checks.swift \
    $(oobjs MemoryCore HistoryCore PrivacyPolicy BrowserBridge) -o "$OUT/owner-messages-store"
  step owner-messages-store "$OUT/owner-messages-store"
  step compile-owner-level-binding swiftc -parse-as-library "${OSW[@]}" -module-cache-path "$I/modcache" -I "$OB/Modules" -I Sources/CSQLite "${OLLAMA[@]}" \
    adapters/LevelWriterBinding.swift scripts/level-binding-checks.swift \
    $(oobjs MemoryCore HistoryCore WriterBackend PrivacyPolicy BrowserBridge CLlamaBridge) -lc++ -o "$OUT/owner-level-binding"
  step owner-level-binding "$OUT/owner-level-binding"
  # Cloud summaries never get Chrome pages or typed words: the app's own WriterScheduling.swift, flagged.
  for name in writer-retention cloud-scope; do
    step compile-owner-$name swiftc -parse-as-library "${OSW[@]}" -module-cache-path "$I/modcache" -I "$OB/Modules" -I Sources/CSQLite "${OLLAMA[@]}" \
      Sources/MacMemApp/WriterScheduling.swift scripts/$name-checks.swift $(oobjs "${OAPPDEPS[@]}") -lc++ -o "$OUT/owner-$name"
    step owner-$name "$OUT/owner-$name"
  done
  # fix/writing-forever: the writer's cadence, state machine, spin and notes, flagged as they ship. With the flags the
  # synthetic day's typed rows are kept, so nearly every moment needs the model: the public lane refuses them and never
  # exercised the load and per-moment caps (0.1.3 shipped over them). Same recipe as run-checks.sh's writer steps.
  # fix/summary-sends: the same regressions against the flagged objects.
  if [ -f scripts/summary-sends-checks.swift ]; then
    step compile-owner-summary-sends swiftc -parse-as-library "${OSW[@]}" -module-cache-path "$I/modcache" -I "$OB/Modules" -I Sources/CSQLite "${OLLAMA[@]}" \
      scripts/summary-sends-checks.swift $(oobjs MemoryCore HistoryCore WriterBackend PrivacyPolicy CLlamaBridge) -lc++ -o "$OUT/owner-summary-sends"
    step owner-summary-sends "$OUT/owner-summary-sends"
  fi
  OWRITERSRC="Sources/MacMemApp/WriterIntegration.swift Sources/MacMemApp/WriterScheduling.swift Sources/MacMemApp/WriterPreferences.swift Sources/MacMemApp/LevelPower.swift adapters/CoreWriterBinding.swift adapters/LevelWriterBinding.swift"
  for name in writer-cadence writer-state writer-spin notes-writer; do
    [ -f scripts/$name-checks.swift ] || continue
    step compile-owner-$name swiftc -parse-as-library "${OSW[@]}" -target arm64-apple-macosx15.0 -module-cache-path "$I/modcache" \
      -I "$OB/Modules" -I Sources/CSQLite -I WriterBackend/Sources/CLlamaBridge/include "${OLLAMA[@]}" \
      $OWRITERSRC scripts/$name-checks.swift "$OB"/WriterBackend.build/*.swift.o "$OB"/CLlamaBridge.build/WriterLlama.cpp.o \
      $(oobjs MemoryCore HistoryCore MemoryUI CoreIntegration PrivacyPolicy BrowserBridge) -lsqlite3 -lc++ -o "$OUT/owner-$name"
    mkdir -p "$OUT/owner-$name-home" "$OUT/owner-$name-root"
    step owner-$name env HOME="$OUT/owner-$name-home" CFFIXED_USER_HOME="$OUT/owner-$name-home" CADENCE_ROOT="$OUT/owner-$name-root" \
      STATE_CHECK_ROOT="$OUT/owner-$name-root" NOTES_CHECK_ROOT="$OUT/owner-$name-root" nice "$OUT/owner-$name"
  done
  # The app-file checks with the flagged app sources (WebTypingRoute.swift compiles in here).
  for check in browser-app-0227 browser-provider-0240; do
    src=$(relocated $check-checks.swift)
    step compile-owner-$check swiftc -parse-as-library "${OSW[@]}" -module-cache-path "$I/modcache" -I "$OB/Modules" -I Sources/CSQLite "${OLLAMA[@]}" \
      $OAPPFILES "$src" $(oobjs "${OAPPDEPS[@]}") -Xlinker -dead_strip -lc++ -o "$OUT/owner-$check"
    step owner-$check "$OUT/owner-$check"
  done
  src=$(relocated app-preferences-search-0132-checks.swift)
  step compile-owner-app-bindings-0132 swiftc -parse-as-library "${OSW[@]}" -module-cache-path "$I/modcache" -I "$OB/Modules" -I Sources/CSQLite "${OLLAMA[@]}" \
    Sources/MacMemApp/PreferenceAutosave.swift Sources/MacMemApp/AppSearchBinding.swift $OAPPFILES "$src" $(oobjs "${OAPPDEPS[@]}") -Xlinker -dead_strip -lc++ -o "$OUT/owner-app-bindings-0132"
  step owner-app-bindings-0132 "$OUT/owner-app-bindings-0132"
  src=$(relocated native-receipt-0053-checks.swift)
  step compile-owner-native-receipt-0053 swiftc -parse-as-library "${OSW[@]}" -module-cache-path "$I/modcache" -I "$OB/Modules" -I Sources/CSQLite "${OLLAMA[@]}" \
    $OAPPFILES "$src" $(oobjs "${OAPPDEPS[@]}") -Xlinker -dead_strip -lc++ -o "$OUT/owner-native-receipt-0053"
  step owner-native-receipt-0053 "$OUT/owner-native-receipt-0053"
  for name in connect-config connect-diagnostics; do
    [ -f scripts/$name-checks.swift ] || continue
    step compile-owner-$name swiftc -parse-as-library "${OSW[@]}" -module-cache-path "$I/modcache" -I "$OB/Modules" -I Sources/CSQLite \
      scripts/$name-checks.swift $(oobjs MemoryCore HistoryCore PrivacyPolicy) -o "$OUT/owner-$name"
    step owner-$name "$OUT/owner-$name"
  done
  # Chrome page history ships in the flagged release MacMem too: its reader and sender are there.
  step owner-release-has-page-history bash -c "nm '$I/build-owner-release/release/MacMem' > '$OUT/owner-release-MacMem.pages.nm' 2>&1; grep -q ChromePageProbe '$OUT/owner-release-MacMem.pages.nm' && grep -q ChromeEventSender '$OUT/owner-release-MacMem.pages.nm' && echo PASS the flagged release MacMem has Chrome page history: ChromePageProbe and ChromeEventSender"
else
  # The APP recipe checks (Settings, menu bar, app menu, app model, status, Chrome pages, honesty UI) with the
  # flagged app sources and objects. typing-ui-checks has its own owner step in ui-checks.sh.
  OUIFLAGS=(-D DEVELOPMENT_SOURCE_CHECKS "${OSW[@]}" -parse-as-library -module-cache-path "$I/modcache" -I "$OB/Modules"
    -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$OB/CLlamaBridge.build/module.modulemap"
    -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include")
  ouiobjs() { for t in MemoryCore MemoryUI HistoryCore CoreIntegration PrivacyPolicy BrowserBridge WriterBackend CLlamaBridge BackupRestore; do ls "$OB/$t.build/"*.o; done; }
  OUIHOME=$OUT/owner-ui-home; mkdir -p "$OUIHOME/Library/Preferences"
  ODDOUT=$OUT/owner-dd; mkdir -p "$ODDOUT"; chmod 700 "$ODDOUT"
  orunui() { env HOME="$OUIHOME" CFFIXED_USER_HOME="$OUIHOME" DD_CHECK_OUT="$ODDOUT" "$@"; }
  for check in ${APPCHECKS/typing-ui-checks/}; do
    src=$(uicheck $check)
    step compile-owner-$check swiftc "${OUIFLAGS[@]}" -F "$OB" -framework Sparkle -Xlinker -rpath -Xlinker "$OB" \
      "$APPSRC"/*.swift "$src" $(ouiobjs) -lc++ -o "$OUT/owner-$check"
    step owner-$check orunui "$OUT/owner-$check"
  done
  # The UI recipe (no app sources): the kit, the permission settings and the honesty UI checks, flagged.
  # gold/connections-storage: dd-recall-checks joins the flagged UI loop.
  for check in dd-kit-checks permission-settings-checks honesty-ui-checks dd-recall-checks; do
    [ -f scripts/$check.swift ] || continue
    src=$(uicheck $check)
    step compile-owner-$check swiftc "${OUIFLAGS[@]}" "$src" $(ouiobjs) -lc++ -o "$OUT/owner-$check"
    step owner-$check orunui "$OUT/owner-$check"
  done
fi
