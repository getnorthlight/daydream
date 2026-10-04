#!/bin/bash
# DayDream Preview checks, run beside the suite (runner-1001/run-checks.sh):
#   1. scripts/preview-app-checks.swift with the APP recipe of runner-1001/ui-checks.sh (app sources + the check + the
#      built debug objects, -D DEVELOPMENT_SOURCE_CHECKS, HOME and CFFIXED_USER_HOME in scratch, TMPDIR in scratch).
#      It seeds the sample through the real launch path, checks nothing records or asks, and renders PNGs offscreen.
#   2. The MCP recall tool over that sample, through the preview app's own bundled mac-mem (a companion needs its
#      bundle manifest): initialize, tools/list, then recall at the day and week levels and a note search.
# Env: SRC (worktree), WORKDIR (a scratch folder), BUILD (a debug scratch the suite built), APP (the
# built "DayDream Preview.app", optional: step 2 is skipped without it). Never launches the app.
set -uo pipefail
C=$(cd "$(dirname "$0")/../../runner-1001" && pwd)
export PATH="$C/bin:$PATH"
WT=${SRC:?SRC}; I=${WORKDIR:?WORKDIR}; BUILD=${BUILD:?BUILD}; LABEL=${1:-preview}
OUT=$I/out-$LABEL
rm -rf "$OUT"; mkdir -p "$OUT/src" "$OUT/tmp" "$I/modcache"
export TMPDIR=$OUT/tmp/ PYTHONDONTWRITEBYTECODE=1 CLANG_MODULE_CACHE_PATH=$I/modcache SWIFT_MODULECACHE_PATH=$I/modcache
cd "$WT"
B=$BUILD/arm64-apple-macosx/debug
summary=()
step() { local name=$1; shift; "$@" >"$OUT/$name.log" 2>&1; local rc=$?
  summary+=("$name exit=$rc pass=$(grep -cE '^PASS' "$OUT/$name.log")"); echo "$name exit=$rc"; return $rc; }
UIHOME=$OUT/ui-home; mkdir -p "$UIHOME/Library/Preferences"
DDOUT=$OUT/dd; mkdir -p "$DDOUT"
R=${SOCKROOT:-$(mktemp -d /private/tmp/ddpv.XXXXXX)}; mkdir -p "$R"; R=$(cd "$R" && pwd -P)
APPSRC=$OUT/src/app; mkdir -p "$APPSRC"
for f in Sources/MacMemApp/*.swift; do sed -e "s#/private/tmp/daydream-#$R/daydream-#g" "$f" > "$APPSRC/$(basename "$f")"; done
objs() { for t in MemoryCore MemoryUI HistoryCore CoreIntegration PrivacyPolicy BrowserBridge WriterBackend CLlamaBridge BackupRestore; do ls "$B/$t.build/"*.o; done; }
FLAGS=(-D DEVELOPMENT_SOURCE_CHECKS ${PREVIEW_SWIFT_FLAGS:-} -parse-as-library -module-cache-path "$I/modcache" -I "$B/Modules"
  -Xcc -fmodule-map-file="$PWD/Sources/CSQLite/module.modulemap" -Xcc -fmodule-map-file="$B/CLlamaBridge.build/module.modulemap"
  -Xcc -I -Xcc "$PWD/WriterBackend/Sources/CLlamaBridge/include")
step compile-preview-app-checks swiftc "${FLAGS[@]}" -F "$B" -framework Sparkle -Xlinker -rpath -Xlinker "$B" \
  "$APPSRC"/*.swift scripts/preview-app-checks.swift $(objs) -lc++ -o "$OUT/preview-app-checks"
step preview-app-checks env HOME="$UIHOME" CFFIXED_USER_HOME="$UIHOME" DD_CHECK_OUT="$DDOUT" "$OUT/preview-app-checks"
# A first launch (fresh defaults, the window made while "Getting ready…") shows the search field. Its own HOME, so
# nothing the check above saved makes it a second launch.
step compile-dd-first-launch-checks swiftc "${FLAGS[@]}" -F "$B" -framework Sparkle -Xlinker -rpath -Xlinker "$B" \
  "$APPSRC"/*.swift scripts/dd-first-launch-checks.swift $(objs) -lc++ -o "$OUT/dd-first-launch-checks"
FIRSTHOME=$OUT/first-home; mkdir -p "$FIRSTHOME/Library/Preferences"
step dd-first-launch-checks env HOME="$FIRSTHOME" CFFIXED_USER_HOME="$FIRSTHOME" DD_CHECK_OUT="$DDOUT" "$OUT/dd-first-launch-checks"
# Secondary click on a moment (Recall rows = the ⌘K Actions menu; Focus List rows and ribbon spans = the moment's
# actions) and the ribbon's hover tip, on a new sample in a scratch folder; PNGs in dd/moment-menus.
step compile-dd-moment-menus-checks swiftc "${FLAGS[@]}" -F "$B" -framework Sparkle -Xlinker -rpath -Xlinker "$B" \
  "$APPSRC"/*.swift scripts/dd-moment-menus-checks.swift $(objs) -lc++ -o "$OUT/dd-moment-menus-checks"
step dd-moment-menus-checks env HOME="$FIRSTHOME" CFFIXED_USER_HOME="$FIRSTHOME" DD_CHECK_OUT="$DDOUT" "$OUT/dd-moment-menus-checks"
# Nothing of the preview may land outside the temporary folder (FileManager's, the per-user /var/folders temp).
SAMPLE=$(sed -n 's/^PASS: MAC_MEM_HOME is the preview folder in the temporary folder (\(.*\))$/\1/p' "$OUT/preview-app-checks.log")
step preview-paths bash -c '
  case "'"$SAMPLE"'" in /var/folders/*/T/"DayDream Preview Sample"/memory) echo "PASS: the sample is in the per-user temporary folder";; *) exit 1;; esac
  test ! -e "'"$UIHOME"'/Library/Application Support/DayDream" && echo "PASS: nothing in the scratch HOME Application Support/DayDream" || exit 1
  ls -d /private/tmp/daydream-* 2>/dev/null | grep -qi preview && exit 1 || echo "PASS: no /private/tmp/daydream-* preview folder"'

if [ -n "${APP:-}" ] && [ -x "$APP/Contents/MacOS/mac-mem" ]; then
  MEM="$SAMPLE"
  step preview-mcp python3 - "$APP/Contents/MacOS/mac-mem" "$MEM" <<'PY'
import json, subprocess, sys
cli, home = sys.argv[1], sys.argv[2]
grant = json.loads(subprocess.run([cli, "--home", home, "--client", "preview-check", "--recipient", "local", "grant"], capture_output=True, text=True, check=True).stdout)
env = {"MAC_MEM_CAPABILITY": grant["capability"], "PATH": "/usr/bin:/bin"}
calls = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "preview-check", "version": "1"}}},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "recall", "arguments": {"level": "day", "when": "today"}}},
    {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "recall", "arguments": {"level": "week", "when": "this week"}}},
    {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "recall", "arguments": {"query": "export"}}},
]
p = subprocess.run([cli, "--home", home, "--client", "preview-check", "--recipient", "local", "mcp"], input="\n".join(json.dumps(c) for c in calls) + "\n",
                   capture_output=True, text=True, env=env, timeout=120)
replies = {r.get("id"): r for r in (json.loads(l) for l in p.stdout.splitlines() if l.strip().startswith("{"))}
def ok(cond, name):
    print(("PASS: " if cond else "FAIL: ") + name)
    if not cond:
        print(p.stdout[-3000:], p.stderr[-2000:]); sys.exit(1)
ok(1 in replies and "result" in replies[1], "MCP initialize answers over the preview history")
tools = [t["name"] for t in replies.get(2, {}).get("result", {}).get("tools", [])]
ok("recall" in tools, "MCP lists the recall tool")
for i, label in [(3, "day"), (4, "week"), (5, "search")]:
    r = replies.get(i, {})
    text = "".join(c.get("text", "") for c in r.get("result", {}).get("content", []))
    print(f"--- recall {label} ---\n{text[:1200]}\n")
    ok("result" in r and len(text) > 40 and not r.get("result", {}).get("isError"), f"MCP recall ({label}) answers from the sample")
PY
else
  echo "preview-mcp skipped: no APP"
fi
printf '%s\n' "${summary[@]}" | tee "$OUT/SUMMARY"
