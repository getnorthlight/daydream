#!/bin/bash
# usage: preview-paths.sh PREVIEW_APP_LOG SCRATCH_HOME [FRESH_SAMPLE]
# FRESH_SAMPLE: the sample folder when none was there before this run; it is removed at the end (synthetic, this run's).
# The preview sample lives in FileManager's per-user temporary folder (/var/folders/…/T), never in the scratch HOME's
# Application Support or a /private/tmp/daydream-* folder (formerly part of scripts/preview/run-preview-checks.sh).
S=$(sed -n 's/^PASS: MAC_MEM_HOME is the preview folder in the temporary folder (\(.*\))$/\1/p' "$1")
case "$S" in
  /var/folders/*/T/"DayDream Preview Sample"/memory) echo "PASS: the sample is in the per-user temporary folder" ;;
  *) echo "FAIL: the sample is at \"$S\""; exit 1 ;;
esac
if [ -e "$2/Library/Application Support/DayDream" ]; then echo "FAIL: the scratch HOME has Application Support/DayDream"; exit 1; fi
echo "PASS: nothing in the scratch HOME Application Support/DayDream"
# The sample's own folder, not any daydream-*preview* name: search checks leave LocalSearchSetup's
# /private/tmp/daydream-typesense-preview-<uuid> folders there, which are not the DayDream Preview sample.
if find /private/tmp -maxdepth 2 -path '/private/tmp/daydream-*' -name 'DayDream Preview Sample' 2>/dev/null | grep -q .; then
  echo "FAIL: a DayDream Preview Sample under /private/tmp/daydream-*"; exit 1; fi
echo "PASS: no DayDream Preview Sample under /private/tmp/daydream-*"
if [ -n "${3:-}" ]; then
  if [ -f "$3/PREVIEW-SAMPLE-ONLY" ]; then rm -rf "$3"; echo "PASS: removed the preview sample this run made ($3)"
  else echo "NOTE: no preview sample with its marker at $3 to remove"; fi
else
  echo "NOTE: a DayDream Preview Sample was there before this run (a DayDream Preview or an earlier run); left in place"
fi
