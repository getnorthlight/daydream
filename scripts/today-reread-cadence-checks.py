#!/usr/bin/env python3
"""fix/perf7-reread: while recording, a capture commit rereads today at most every 10 s only while a memory window
shows it; otherwise at most once a minute. Each reread is the day's actions and levels off the main thread plus
Today's snapshot on it: about 290 ms on a 2,400-action synthetic day (debug; perf7 harness), up to every 10 s all day.
Source rules (the path needs recording, which no check may start):
  A. captureCommitted passes 10 s with a memory shell mounted (ShellPresence), 60 s without; no other commit path
     rereads every 10 s
  B. nothing user-visible depends on the 10 s cadence with no window: today's snapshot (TodayDigest) is read only by
     the Focus List and Recall (inside the memory shell, which rereads on appear), and by the menu bar panel, which
     rereads when it opens; the menu bar label reads no snapshot; AI apps (MacMemCLI, MCP) never use it
"""
import re, sys, pathlib
root = pathlib.Path(__file__).resolve().parent.parent
src = root / "Sources"
app = (src / "MacMemApp/MacMemApp.swift").read_text()
fails = 0
def check(ok, name, got=""):
    global fails
    print(("PASS " if ok else "FAIL ") + name + ("" if ok or not got else f" (got: {got})"))
    if not ok: fails += 1
m = re.search(r"private func captureCommitted\(\) \{.*?self\.dayData\.refreshTodayIfStale\(ShellPresence\.shared\.isMounted\(self\.activity\) \? 10 : 60\)\s*\}\s*\}", app, re.S)
check(m is not None, "A: a commit rereads today every 10 s with a memory window mounted, else once a minute")
check("refreshTodayIfStale(10)" not in app, "A: no other app-model path rereads today every 10 s")
readers = sorted(str(p.relative_to(src)) for p in src.rglob("*.swift")
                 if re.search(r"today\.snapshot|today\.\$snapshot|\.today\.snapshot", p.read_text()))
check(readers == ["MacMemApp/MenuBarContent.swift", "MemoryUI/CanonicalTimeline.swift", "MemoryUI/RecallModel.swift"] or
      set(readers) <= {"MacMemApp/MenuBarContent.swift", "MemoryUI/CanonicalTimeline.swift", "MemoryUI/RecallModel.swift", "MemoryUI/RecallHost.swift"},
      "B: today's snapshot is read only by the Focus List, Recall and the menu bar panel", readers)
tl = (src / "MemoryUI/CanonicalTimeline.swift").read_text()
check(".onAppear { appear() }" in tl and "today.refreshIfStale()" in tl, "B: the Focus List rereads today when it appears")
mb = (src / "MacMemApp/MenuBarContent.swift").read_text()
check(re.search(r"\.onAppear \{\s*model\.dayData\.refreshTodayIfStale\(10\)", mb) is not None, "B: the menu bar panel rereads today (10 s) when it opens")
label = re.search(r"struct DaydreamMenuBarLabel: View \{.*?\n\}\n", mb, re.S)
code = "\n".join(l.split("//")[0] for l in label.group(0).splitlines()) if label else ""
check(label is not None and "snapshot" not in code and ".today" not in code, "B: the menu bar label reads no today snapshot")
cli = "".join(p.read_text() for p in (src / "MacMemCLI").rglob("*.swift"))
check("TodayDigest" not in cli and "ActivityBrowser" not in cli, "B: AI apps (MacMemCLI/MCP) read the history, never the app's today snapshot")
print("today-reread-cadence: " + ("all passed" if fails == 0 else f"{fails} failed"))
sys.exit(1 if fails else 0)
