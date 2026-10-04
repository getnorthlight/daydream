#!/bin/bash
# Reviewed native synthetic replay only. Source/root build must be frozen by the integrator.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=${SRC:-$(dirname "$HERE")}
BUILD=${BUILD:-}
RUN=$(mktemp -d "${REPLAY_OUT_ROOT:-/private/tmp}/daydream-session-replay-XXXXXXXX")
mkdir -p "$RUN/home/Library/Preferences" "$RUN/tmp" "$RUN/modules" "$RUN/src"
export HOME="$RUN/home" CFFIXED_USER_HOME="$RUN/home" TMPDIR="$RUN/tmp/" PYTHONDONTWRITEBYTECODE=1
export CLANG_MODULE_CACHE_PATH="$RUN/modules" SWIFT_MODULECACHE_PATH="$RUN/modules"
cd "$SRC"
PIN=$(git rev-parse HEAD)
printf 'source=%s head=%s build=%s run=%s\n' "$SRC" "$PIN" "$BUILD" "$RUN" > "$RUN/receipt.txt"
if [ -z "$BUILD" ]; then
  nice swift build --jobs 3 --disable-automatic-resolution --scratch-path "$RUN/build" --product MacMem > "$RUN/build.log" 2>&1
  BUILD="$RUN/build/arm64-apple-macosx/debug"
fi
# This is the same compile-source list as the reviewed copied production-capture recipe.

python3 - "$SRC" "$RUN" <<'PY'
import ast,re,sys
from pathlib import Path
src,run=map(Path,sys.argv[1:])
text=(src/'scripts/daydream-core-source-checks.py').read_text()
names=ast.literal_eval(re.search(r'capture=(\[[^\]]*\])',text).group(1))
paths=[]
for name in names:
 p=src/'Sources/MacMemApp'/f'{name}.swift'
 if name=='Coordinator':
  content=p.read_text()
  old='static var permitted: Bool { AXIsProcessTrusted() && CGPreflightListenEventAccess() }'
  assert content.count(old)==1,'Headless permission seam drift'
  dest=run/'src/Coordinator.swift';dest.write_text(content.replace(old,'static var permitted: Bool { false }'));p=dest
 paths.append(str(p))
(run/'capture-files.txt').write_text('\n'.join(paths)+'\n')
PY
CAPTURE=()
while IFS= read -r path; do CAPTURE+=("$path"); done < "$RUN/capture-files.txt"
OBJECTS=()
for target in MemoryCore HistoryCore CoreIntegration WriterBackend PrivacyPolicy BrowserBridge CLlamaBridge; do
  for path in "$BUILD/$target.build/"*.o; do
    [ -f "$path" ] || { echo "Missing immutable object: $path" >&2; exit 1; }
    OBJECTS+=("$path")
  done
done
nice swiftc -parse-as-library -module-cache-path "$RUN/modules" -I "$BUILD/Modules" -I Sources/CSQLite \
  -Xcc -fmodule-map-file="$BUILD/CLlamaBridge.build/module.modulemap" \
  "${CAPTURE[@]}" "$HERE/recording-session-replay.swift" "${OBJECTS[@]}" -lc++ -o "$RUN/session-replay" > "$RUN/compile.log" 2>&1
[ "$(git rev-parse HEAD)" = "$PIN" ] || { echo 'Source HEAD changed; refusing replay' >&2; exit 1; }
# Executing this binary never calls EventCapture.start(), AppKit lifecycle or live system surfaces.
nice "$RUN/session-replay" "$HERE/fixtures/recording-session-synthetic.json" "$RUN/stores" > "$RUN/replay.jsonl" 2>&1
cat "$RUN/replay.jsonl"
printf 'PASS output=%s\n' "$RUN"
