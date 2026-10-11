# test-p2-int: the gaps the integration closed (rows in scripts/checks-manifest.d/int-gaps.tsv, bug re-injections in
# scripts/mutations.d/int-gaps.tsv). Sourced by run-checks.sh (steps.d/README).
#
#   owner-summaries-this-mac   owner bug 4 with no window: "This Mac only" (Settings' Summarizer switch,
#                              SummaryControls.live) saves local and the writer on this Mac reads the typed words, after
#                              a relaunch and after OpenRouter too; the cloud-audience port never does. The REAL
#                              WriterIntegration with a fake model, installer and OpenRouter (the writer recipe).
#   owner-coordinator-healthy  Coordinator.swift's own guard: "saving works again" (onHealthy) only while recording,
#                              with no app around it (the app's `guard self.recording` hid a missing Coordinator guard).
#   runner-timeout-toy         the runner's per-step time limit (runner-1001/bounded.sh), proved by its mutation row.
if have_ob; then
  if [ -f scripts/summaries-this-mac-checks.swift ]; then
    STMSRC="Sources/MacMemApp/WriterIntegration.swift Sources/MacMemApp/WriterScheduling.swift Sources/MacMemApp/WriterQuiet.swift Sources/MacMemApp/WriterPreferences.swift Sources/MacMemApp/LevelPower.swift adapters/CoreWriterBinding.swift adapters/LevelWriterBinding.swift"
    step compile-owner-summaries-this-mac swiftc -parse-as-library "${OSW[@]}" -target arm64-apple-macosx15.0 -module-cache-path "$I/modcache" \
      -I "$OB/Modules" -I Sources/CSQLite -I WriterBackend/Sources/CLlamaBridge/include "${OLLAMA[@]}" \
      $STMSRC scripts/summaries-this-mac-checks.swift "$OB"/WriterBackend.build/*.swift.o "$OB"/CLlamaBridge.build/WriterLlama.cpp.o \
      $(oobjs MemoryCore HistoryCore MemoryUI CoreIntegration PrivacyPolicy BrowserBridge) -lsqlite3 -lc++ -o "$OUT/owner-summaries-this-mac"
    [ -n "${DRYRUN:-}" ] || mkdir -p "$OUT/owner-summaries-this-mac-home" "$OUT/owner-summaries-this-mac-root"
    step owner-summaries-this-mac env HOME="$OUT/owner-summaries-this-mac-home" CFFIXED_USER_HOME="$OUT/owner-summaries-this-mac-home" \
      STATE_CHECK_ROOT="$OUT/owner-summaries-this-mac-root" nice "$OUT/owner-summaries-this-mac"
  fi
  if [ -f scripts/coordinator-healthy-checks.swift ]; then # compiled like owner-recording-fault: the capture list, owner flags
    step compile-owner-coordinator-healthy swiftc -parse-as-library "${OSW[@]}" -module-cache-path "$I/modcache" -I "$OB/Modules" -I Sources/CSQLite \
      "${OLLAMA[@]}" $CAPTURE scripts/coordinator-healthy-checks.swift $(oobjs "${APPDEPS[@]}") -lc++ -o "$OUT/owner-coordinator-healthy"
    step owner-coordinator-healthy "$OUT/owner-coordinator-healthy"
  fi
fi
step runner-timeout-toy bash scripts/runner-timeout-toy-checks.sh
