#!/bin/bash
# The precompiled app module: the scratch copy of Sources/MacMemApp/*.swift (run-checks.sh's appsrc, built with
# DEVELOPMENT_SOURCE_CHECKS) compiled ONCE per flag set into a static library + module (DDApp), instead of once per
# APP-recipe check. Each APP-recipe check then compiles only itself (with `@testable import DDApp`) and links the
# library (run-checks.sh app_link).
#
#   app-module.sh ensure CACHE APPSRC MODULES_DIR [-D FLAG]...
#       Print the module folder (CACHE/<key>: libDDApp.a, DDApp.swiftmodule, KEY). Build it when there is none.
#       The key is a sha256 of every input that changes the module: each app source's bytes (the scratch copy, so the
#       runner's rewrites count), the -D flags and the extra swiftc flags (APP_MODULE_FLAGS), the compiler version,
#       the imported modules' .swiftmodule files and the C module maps and headers. A changed byte anywhere is a new
#       key and a new build; nothing is ever reused by folder name or time stamp (the staged-copy lesson: a reused
#       SwiftPM scratch once "built" stale code in 0.33 s). Concurrent callers wait on one lock per key.
#   app-module.sh selftest CACHE APPSRC MODULES_DIR [-D FLAG]...
#       Prove the cache can't serve stale code: copy APPSRC, add a new string to one app file, ensure (a new key, a
#       build), link a probe against the result and find the string in the linked binary; then ensure the unedited
#       copy again and find the string absent. Prints PASS/FAIL lines.
#
# Env: MODCACHE (clang module cache; default CACHE/modcache), APP_MODULE_JOBS (default 8).
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mode=${1:?usage: app-module.sh ensure|selftest CACHE APPSRC MODULES_DIR [-D FLAG]...}
cache=${2:?CACHE}; src=${3:?APPSRC}; mb=${4:?MODULES_DIR}; shift 4
dflags=("$@")
root=$(pwd)  # the source tree (run-checks.sh runs from it): Sources/CSQLite and the CLlamaBridge headers
mkdir -p "$cache"; cache=$(cd "$cache" && pwd -P)
modcache=${MODCACHE:-$cache/modcache}
# shellcheck disable=SC2206
extra=(${APP_MODULE_FLAGS:-})

compile_flags() { # the APP recipe's compile flags against $1 (a debug build folder)
  printf '%s\n' -D DEVELOPMENT_SOURCE_CHECKS ${dflags[@]+"${dflags[@]}"} ${extra[@]+"${extra[@]}"} -parse-as-library \
    -module-cache-path "$modcache" -I "$1/Modules" \
    -Xcc "-fmodule-map-file=$root/Sources/CSQLite/module.modulemap" -Xcc "-fmodule-map-file=$1/CLlamaBridge.build/module.modulemap" \
    -Xcc -I -Xcc "$root/WriterBackend/Sources/CLlamaBridge/include" -F "$1"
}

key_of() { # APPSRC MODULES_DIR: the module's key (and its inputs, for KEY)
  python3 - "$1" "$2" "$root" "$(swiftc --version 2>&1 | head -1)" ${dflags[@]+"${dflags[@]}"} ${extra[@]+"${extra[@]}"} <<'PY'
import glob, hashlib, os, sys
src, mb, root, version = sys.argv[1:5]
flags = sys.argv[5:]
h = hashlib.sha256()
lines = []
def add(label, data):
    d = hashlib.sha256(data).hexdigest()
    h.update(label.encode() + b"\0" + d.encode() + b"\n")
    lines.append("%s %s" % (d[:16], label))
add("compiler " + version, b"")
# -D X and -DX are the same flag, in any order: one key per flag set.
norm, i = [], 0
while i < len(flags):
    if flags[i] == "-D" and i + 1 < len(flags):
        norm.append("-D" + flags[i + 1]); i += 2
    else:
        norm.append(flags[i]); i += 1
defines = sorted(f for f in norm if f.startswith("-D"))
add("flags " + " ".join(defines + [f for f in norm if not f.startswith("-D")]), b"")
files = sorted(glob.glob(os.path.join(src, "*.swift")))
if not files:
    sys.exit("app-module: no .swift files in %s" % src)
for f in files:
    add("src/" + os.path.basename(f), open(f, "rb").read())
inputs = sorted(glob.glob(os.path.join(mb, "Modules", "*.swiftmodule")))
inputs += [os.path.join(mb, "CLlamaBridge.build", "module.modulemap")]
inputs += sorted(glob.glob(os.path.join(root, "Sources", "CSQLite", "*")))
inputs += sorted(glob.glob(os.path.join(root, "WriterBackend", "Sources", "CLlamaBridge", "include", "**", "*"), recursive=True))
inputs += sorted(glob.glob(os.path.join(mb, "Sparkle.framework", "Versions", "*", "Headers", "*.h")))
for f in inputs:
    if os.path.isfile(f):
        rel = os.path.relpath(f, mb) if f.startswith(mb) else os.path.relpath(f, root)
        add("dep/" + rel, open(f, "rb").read())
print(h.hexdigest()[:24])
for l in lines:
    print(l)
PY
}

ensure() { # APPSRC MODULES_DIR -> prints the module folder
  local s=$1 b=$2 info key d
  info=$(key_of "$s" "$b") || return 1
  key=$(printf '%s\n' "$info" | head -1); d=$cache/$key
  if [ -f "$d/.done" ]; then echo "app-module: cache hit $key (no compile)" >&2; echo "$d"; return 0; fi
  mkdir -p "$cache/locks"
  # One builder per key; the others wait on the lock and then find .done.
  lockf -k "$cache/locks/$key" bash "$here/app-module.sh" _build "$cache" "$s" "$b" "$key" ${dflags[@]+"${dflags[@]}"} \
    || { echo "app-module: FAIL the module did not build ($key)" >&2; return 1; }
  [ -f "$d/.done" ] || { echo "app-module: FAIL no module after the build ($key)" >&2; return 1; }
  [ -f "$d/KEY" ] || printf '%s\n' "$info" > "$d/KEY"
  echo "app-module: $key: $(tail -1 "$d/build.log" 2>/dev/null)" >&2
  echo "$d"
}

build() { # APPSRC MODULES_DIR KEY (under the key's lock)
  local s=$1 b=$2 key=$3 d t s0 flags
  d=$cache/$key
  [ -f "$d/.done" ] && return 0
  t=$d.tmp.$$; rm -rf "$t"; mkdir -p "$t"; s0=$(date +%s)
  flags=(); while IFS= read -r f; do flags+=("$f"); done < <(compile_flags "$b")
  if swiftc -emit-library -static -module-name DDApp -enable-testing -emit-module -emit-module-path "$t/DDApp.swiftmodule" \
      -j "${APP_MODULE_JOBS:-8}" "${flags[@]}" "$s"/*.swift -o "$t/libDDApp.a" > "$t/build.log" 2>&1; then
    echo "built in $(( $(date +%s) - s0 ))s from $(ls "$s"/*.swift | wc -l | tr -d ' ') files" >> "$t/build.log"
    rm -rf "$d"; mv "$t" "$d"; touch "$d/.done"
  else
    cat "$t/build.log" >&2; rm -rf "$t"; return 1
  fi
}

selftest() { # APPSRC MODULES_DIR
  local s=$1 b=$2 work probe tag m0 m1 fails=0 f
  work=$(mktemp -d "$cache/selftest.XXXXXX"); tag="DD-APP-MODULE-PROBE-$(date +%s)-$$-$RANDOM"
  mkdir -p "$work/src"; cp "$s"/*.swift "$work/src/"
  f=$(ls "$work/src"/*.swift | head -1)
  m0=$(ensure "$work/src" "$b") || { echo "FAIL the unedited app module does not build"; return 1; }
  printf '\nlet ddAppModuleProbe = "%s"\n' "$tag" >> "$f"
  m1=$(ensure "$work/src" "$b") || { echo "FAIL the edited app module does not build"; return 1; }
  if [ "$m1" != "$m0" ] && [ -f "$m1/.done" ]; then echo "PASS editing $(basename "$f") gives a new key and a new build ($(basename "$m0") -> $(basename "$m1"))"
  else echo "FAIL editing $(basename "$f") kept the key $(basename "$m0")"; fails=$((fails+1)); fi
  if grep -q "built in" "$m1/build.log"; then echo "PASS the edited module was compiled ($(tail -1 "$m1/build.log"))"
  else echo "FAIL the edited module has no build log"; fails=$((fails+1)); fi
  # The probe links the library the way an APP-recipe check does and reads the string through the module.
  probe=$work/probe.swift
  printf '@testable import DDApp\n@main enum Probe { static func main() { print(ddAppModuleProbe) } }\n' > "$probe"
  local flags=(); while IFS= read -r x; do flags+=("$x"); done < <(compile_flags "$b")
  local objs=(); for t in MemoryCore MemoryUI HistoryCore CoreIntegration PrivacyPolicy BrowserBridge WriterBackend CLlamaBridge BackupRestore; do
    [ -d "$b/$t.build" ] && for o in "$b/$t.build/"*.o; do objs+=("$o"); done; done
  if swiftc "${flags[@]}" -I "$m1" -framework Sparkle -Xlinker -rpath -Xlinker "$b" "$probe" -Xlinker -force_load -Xlinker "$m1/libDDApp.a" \
      "${objs[@]}" -lc++ -o "$work/probe" > "$work/probe.log" 2>&1; then
    if grep -aqF "$tag" "$work/probe"; then echo "PASS the new string is in the linked binary ($tag)"
    else echo "FAIL the linked binary lacks the new string $tag"; fails=$((fails+1)); fi
    if [ "$("$work/probe" 2>/dev/null)" = "$tag" ]; then echo "PASS the linked binary prints the new string"
    else echo "FAIL the linked binary does not print the new string"; fails=$((fails+1)); fi
  else
    cat "$work/probe.log"; echo "FAIL the probe does not link against the edited module"; fails=$((fails+1))
  fi
  if grep -aqF "$tag" "$m0/libDDApp.a"; then echo "FAIL the unedited module has the new string"; fails=$((fails+1))
  else echo "PASS the unedited module (the old key) does not have the new string"; fi
  # The edited module is a throwaway: remove both selftest keys unless another caller uses the unedited one.
  rm -rf "$m1" "$work"
  [ "$fails" -eq 0 ]
}

case "$mode" in
  ensure) ensure "$src" "$mb" ;;
  _build) key=${dflags[0]}; dflags=(${dflags[@]+"${dflags[@]:1}"}); build "$src" "$mb" "$key" ;;
  selftest) selftest "$src" "$mb" ;;
  *) echo "usage: app-module.sh ensure|selftest CACHE APPSRC MODULES_DIR [-D FLAG]..." >&2; exit 2 ;;
esac
