#!/bin/bash
# claude/perf3-1005: the on-screen scroll bench (scripts/scroll-bench.swift). Synthetic data in a scratch folder only.
#   scripts/scroll-bench.sh <release-build-dir> <work-dir> <label>
# <release-build-dir>: a `swift build -c release` scratch path's arm64-apple-macosx/release (its objects and modules).
# The bench is a test bundle, "DayDream Scroll Bench.app" (com.getnorthlight.daydream.scrollbench.adhoc), run with HOME,
# CFFIXED_USER_HOME and MAC_MEM_HOME in <work-dir>. It never opens the person's history, installs nothing, signs
# nothing beyond the linker's ad-hoc signature and asks for no permission. Its EventCapture copy installs no input tap,
# Accessibility observer or Chrome page read, so the window records nothing outside the bench.
# Env: BENCH_SEED_HOME (a seeded history to copy; made once under <work-dir>/seed otherwise), SCROLL_BENCH_ONLY
# (idle,today,pointer,rereads,clicks,past,expanded,detail,search), SCROLL_BENCH_SPEED (pt/s, default 2400), DISK_BUSY=1 (an fsync-heavy
# writer on the history's volume while the bench runs, like a sync client), SAMPLE=1 (a 1 ms sample of the bench).
set -euo pipefail
B=${1:?release build dir}; W=${2:?work dir}; L=${3:?label}
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$W/modcache" "$W/$L/src"
OUT=$W/$L; APPSRC=$OUT/src
for f in "$SRC"/Sources/MacMemApp/*.swift; do python3 "$SRC/runner-1001/copy-check-source.py" "$f" "$W/sock" > "$APPSRC/$(basename "$f")"; done
# The recorder without its inputs: no tap, no Accessibility observer, no workspace observer, no Chrome page reads.
python3 - "$APPSRC/EventCapture.swift" <<'PY'
import sys
p=sys.argv[1]; t=open(p).read()
def cut(old,new=""):
    global t
    if t.count(old)!=1: raise SystemExit("scroll bench seam drift: "+old[:60])
    t=t.replace(old,new)
cut('guard installEventTap() else { coordinator.pause("Input event tap unavailable. No recording started."); return false }')
cut('        keyWatch.start()\n        installWorkspaceObserver()\n        if let app = NSWorkspace.shared.frontmostApplication {','        if false, let app = NSWorkspace.shared.frontmostApplication {')
cut('        coordinator.record(kind: .sessionStarted, snapshot: snapshot())\n        emitWindowChangeIfNeeded(snapshot())\n')
cut('else if self?.finishingTyping == false { self?.heartbeat(); self?.pages.tick() }','else if self?.finishingTyping == false { self?.heartbeat() }')
cut('        if !Self.tapIsOn(eventTap) { tapDisabled() }\n')
cut('        watchKeyArrival()\n')
open(p,"w").write(t)
PY
cp "$SRC/scripts/scroll-bench.swift" "$OUT/src-bench.swift"
APP="$OUT/DayDream Scroll Bench.app"; rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
swiftc -O -D DEVELOPMENT_SOURCE_CHECKS -parse-as-library -module-cache-path "$W/modcache" -I "$B/Modules" \
  -Xcc -fmodule-map-file="$SRC/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$B/CLlamaBridge.build/module.modulemap" \
  -Xcc -I -Xcc "$SRC/WriterBackend/Sources/CLlamaBridge/include" -F "$B" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "$APPSRC"/*.swift "$OUT/src-bench.swift" \
  $(for t in MemoryCore MemoryUI HistoryCore CoreIntegration PrivacyPolicy BrowserBridge WriterBackend CLlamaBridge BackupRestore; do ls "$B/$t.build/"*.o; done) \
  -lc++ -o "$APP/Contents/MacOS/ScrollBench" > "$OUT/compile.log" 2>&1 || { tail -30 "$OUT/compile.log"; exit 1; }
cp -R "$B/Sparkle.framework" "$APP/Contents/Frameworks/"
cp -R "$B/MacMem_MemoryUI.bundle" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.getnorthlight.daydream.scrollbench.adhoc</string>
<key>CFBundleName</key><string>DayDream Scroll Bench</string>
<key>CFBundleExecutable</key><string>ScrollBench</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.0.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
H=$OUT/home; rm -rf "$H"; mkdir -p "$H/Library/Preferences" "$H/Library/Application Support"
SEED=${BENCH_SEED_HOME:-$W/seed}
if [ ! -f "$SEED/memory.sqlite" ]; then
  echo "seeding $SEED (once)"
  env HOME="$H" CFFIXED_USER_HOME="$H" "$APP/Contents/MacOS/ScrollBench" --seed "$SEED" > "$W/seed.log" 2>&1
  grep BENCH "$W/seed.log"
fi
cp -R "$SEED" "$H/history"
rm -f "$OUT/results.txt"; touch "$OUT/results.txt"
STRESS=""
if [ "${DISK_BUSY:-0}" = 1 ]; then
  python3 - "$H/disk-busy" <<'PY' &
import os,sys,time
p=sys.argv[1]; os.makedirs(p,exist_ok=True); buf=os.urandom(1<<20); end=time.time()+900; i=0
while time.time()<end:
    f=os.path.join(p,"f%d"%(i%8)); fd=os.open(f,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
    for _ in range(4): os.write(fd,buf)
    os.fsync(fd); os.close(fd); i+=1
PY
  STRESS=$!
fi
env HOME="$H" CFFIXED_USER_HOME="$H" MAC_MEM_HOME="$H/history" SCROLL_BENCH_OUT="$OUT/results.txt" \
  "$APP/Contents/MacOS/ScrollBench" > "$OUT/bench.log" 2>&1 &
PID=$!
if [ "${SAMPLE:-0}" = 1 ]; then (sleep 25; sample $PID 40 1 -file "$OUT/bench.sample.txt" >/dev/null 2>&1) & fi
( sleep 600; kill $PID 2>/dev/null ) & WD=$!
wait $PID || echo "bench exit $?"
kill $WD 2>/dev/null || true
[ -n "$STRESS" ] && kill $STRESS 2>/dev/null || true
rm -rf "$H/disk-busy"
grep -E "^BENCH" "$OUT/results.txt" || tail -20 "$OUT/bench.log"
