#!/bin/bash
# Synthetic summary regressions against matching, already-built source/modules.
# No app launch, capture, model, network, signing or installation.
set -euo pipefail
source_root="${SUMMARY_SOURCE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
build_root="${1:?Usage: run-summary-regression-checks.sh BUILD_ROOT [OUTPUT_DIR]}"
source_root="$(cd "$source_root" && pwd -P)"
build_root="$(cd "$build_root" && pwd -P)"
if [[ -d "$build_root/Modules" ]]; then binaries="$build_root"; else binaries="$build_root/arm64-apple-macosx/debug"; fi
output_root="${2:-$(mktemp -d /private/tmp/daydream-summary-checks.XXXXXX)}"
mkdir -p -m 700 "$output_root/fixtures" "$output_root/cache"
output_root="$(cd "$output_root" && pwd -P)"
cd "$source_root"
objects=()
for target in MemoryCore HistoryCore MemoryUI WriterBackend CoreIntegration PrivacyPolicy BrowserBridge CLlamaBridge; do
  for object in "$binaries/$target.build/"*.o; do
    [[ -f "$object" ]] || { echo "Missing matching objects for $target" >&2; exit 2; }
    objects+=("$object")
  done
done
shasum -a 256 "${objects[@]}" > "$output_root/objects-before.sha256"
common=(-j 2 -parse-as-library -module-cache-path "$output_root/cache" -I "$binaries/Modules" -I Sources/CSQLite -Xcc "-fmodule-map-file=$binaries/CLlamaBridge.build/module.modulemap")
checks=(notes-quality summary-coherence summary-sends summary-fallback fallback-compat summary-regeneration scheduler writer-state)
for check in "${checks[@]}"; do
  sources=()
  case "$check" in
    notes-quality|summary-coherence|summary-sends|summary-fallback|fallback-compat) sources=("scripts/$check-checks.swift") ;;
    summary-regeneration) sources=(Sources/MacMemApp/WriterScheduling.swift scripts/summary-regeneration-checks.swift) ;;
    scheduler)
      # Exercise the compiled production scheduler instead of standalone type aliases.
      { printf 'import WriterBackend\n'; cat WriterBackend/SchedulerChecks/main.swift; } > "$output_root/scheduler-checks.swift"
      sources=("$output_root/scheduler-checks.swift") ;;
    writer-state)
      sources=(Sources/MacMemApp/WriterIntegration.swift Sources/MacMemApp/WriterScheduling.swift Sources/MacMemApp/LevelPower.swift Sources/MacMemApp/WriterPreferences.swift adapters/LevelWriterBinding.swift scripts/writer-state-checks.swift) ;;
  esac
  echo "Compiling $check"
  swiftc "${common[@]}" "${sources[@]}" "${objects[@]}" -lc++ -o "$output_root/$check" > "$output_root/$check.compile.log" 2>&1
  echo "Running $check"
  if [[ "$check" == writer-state ]]; then
    env STATE_CHECK_ROOT="$output_root/fixtures" "$output_root/$check" --only-regeneration > "$output_root/$check.result.log" 2>&1
  else
    env FALLBACK_CHECK_ROOT="$output_root/fixtures" SUMMARY_REGEN_CHECK_ROOT="$output_root/fixtures" "$output_root/$check" > "$output_root/$check.result.log" 2>&1
  fi
  tail -n 1 "$output_root/$check.result.log"
done
shasum -a 256 "${objects[@]}" > "$output_root/objects-after.sha256"
cmp "$output_root/objects-before.sha256" "$output_root/objects-after.sha256"
echo "PASS matching object hashes stayed unchanged"
echo "Artifacts: $output_root"
