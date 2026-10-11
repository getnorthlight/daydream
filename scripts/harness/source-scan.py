#!/usr/bin/env python3
"""Source scan for the recording harness (step flow-source-scan; scripts/harness/README.md, "What it never touches").

Proves, from the source, that the flows make no OS event tap, no permission read or request, no Keychain read, no
Apple event and no tccutil call, and touch no real DayDream data:

1. The harness's own files (scripts/harness/*, scripts/flow-*-checks.swift, scripts/fixtures/flows/*.json and
   runner-1001/steps.d/recording-harness.sh) never name one of those APIs (comments aside).
2. The seams that close the real code's paths are in place: CaptureDriver turns every tap and Accessibility-observer
   path into a fatalError and keeps typing keys in memory; flow-replay installs those seams before any replay; flow-app
   answers permission reads itself, starts no input and is compiled as a check build (in-memory typing keyring, inert
   login item).
3. In the real sources the flows compile, the only event tap is made in EventCapture.installEventTap, reached only from
   EventCapture.start() and the remakeTap seam; the only Accessibility observer in the registerAX seam; and the app's
   Keychain keyring only outside check builds. The harness never calls start(), installEventTap, the uninstaller,
   the settings' key place or the browser enrollment's Keychain read.
4. Self-test: the scan flags each forbidden API in a synthetic snippet (so a clean result means something).

Usage: source-scan.py [TREE]   (default: the current directory). Prints PASS/FAIL lines; exit 1 on any FAIL.
"""
import glob
import os
import re
import sys

TREE = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
passed = failed = 0


def check(ok, label, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print("PASS " + label)
    else:
        failed += 1
        print("FAIL " + label + (": " + detail if detail else ""))


# API tokens the harness's own files must never name (outside comments). Each: (token regex, what it is).
FORBIDDEN = [
    (r"tapCreate|CGEventTap|CGEvent\s*\.\s*tap", "an OS event tap"),
    (r"\bIOHID", "an IOHID read or request"),
    (r"AXIsProcessTrusted|kAXTrustedCheckOptionPrompt", "an Accessibility permission read or prompt"),
    (r"AXObserverCreate|AXUIElementCreate", "a live Accessibility observer or element"),
    (r"CG(Request|Preflight)(Listen|Post)EventAccess", "an Input Monitoring permission read or request"),
    (r"requestAccess\s*\(|requestAuthorization\s*\(", "a permission request"),
    (r"\bSecItem|SecKeychain|kSecClass|KeychainTypedKeyStore|MetadataAppKeychain", "a Keychain read or write"),
    (r"NSAppleScript|OSAScript|AESendMessage|osascript|\.sendEvent\s*\(", "a sent Apple event or script"),
    (r"\btccutil\b|TCC\.db|com\.apple\.TCC", "tccutil or the TCC database"),
    (r"UninstallService|UninstallTypingKeys", "the uninstaller (it deletes Keychain items)"),
    (r"BrowserEnrollmentReview\s*\.\s*existing|DaydreamSettings\s*\.\s*values", "a path that reads the Keychain"),
    (r"NSWorkspace\s*\.\s*shared\s*\.\s*(open|launchApplication|openApplication)", "opening an app or URL"),
    (r"\bURLSession\b|\bNWConnection\b", "the network"),
    (r"/Applications/DayDream\.app", "the installed app"),
    (r"\.sqlite[\"']", "a named sqlite file (stores are fresh scratch folders)"),
]


def strip_comments(path, text):
    """Comment-free text: Swift // lines and trailing // comments (outside strings), shell # lines. JSON is kept."""
    if path.endswith(".json"):
        return text
    out = []
    for line in text.split("\n"):
        if path.endswith((".sh", ".py")):
            if line.lstrip().startswith("#"):
                continue
            out.append(line)
            continue
        s = line.lstrip()
        if s.startswith("//") or s.startswith("///"):
            continue
        # a trailing comment: the first // outside a string literal
        q, i, cut = False, 0, len(line)
        while i < len(line) - 1:
            c = line[i]
            if c == "\\" and q:
                i += 2
                continue
            if c == '"':
                q = not q
            elif not q and line[i:i + 2] == "//":
                cut = i
                break
            i += 1
        out.append(line[:cut])
    return "\n".join(out)


def scan(path, text):
    """[(line number, what)] for each forbidden API the comment-free text names."""
    hits = []
    for n, line in enumerate(strip_comments(path, text).split("\n"), 1):
        for rx, what in FORBIDDEN:
            if re.search(rx, line):
                hits.append((n, what, line.strip()[:100]))
    return hits


def read(rel):
    with open(os.path.join(TREE, rel), encoding="utf-8") as f:
        return f.read()


# 4 first: the scanner itself must see what it is looking for.
for rx, what in FORBIDDEN:
    sample = {
        "an OS event tap": "let t = CGEvent.tapCreate(tap: .cgSessionEventTap)",
        "an IOHID read or request": "IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)",
        "an Accessibility permission read or prompt": "let ok = AXIsProcessTrusted()",
        "a live Accessibility observer or element": "AXObserverCreate(pid, cb, &o)",
        "an Input Monitoring permission read or request": "CGRequestListenEventAccess()",
        "a permission request": "AVCaptureDevice.requestAccess(for: .audio) { _ in }",
        "a Keychain read or write": "SecItemCopyMatching(q as CFDictionary, &r)",
        "a sent Apple event or script": "NSAppleScript(source: s)?.executeAndReturnError(nil)",
        "tccutil or the TCC database": "run(\"/usr/bin/tccutil\", [\"reset\"])",
        "the uninstaller (it deletes Keychain items)": "UninstallService.run()",
        "a path that reads the Keychain": "_ = DaydreamSettings.values(model: m, typing: t)",
        "opening an app or URL": "NSWorkspace.shared.open(url)",
        "the network": "URLSession.shared.dataTask(with: u)",
        "the installed app": "let app = \"/Applications/DayDream.app\"",
        "a named sqlite file (stores are fresh scratch folders)": "let db = home + \"/memory.sqlite\"",
    }[what]
    found = scan("x.swift", "func f() {\n    " + sample + "\n}\n")
    check(any(w == what for _, w, _ in found), "[source-scan] self-test: the scan flags %s" % what, "missed: " + sample)
check(not scan("x.swift", "// CGEvent.tapCreate and SecItemCopyMatching are never called\nlet a = 1 // no tccutil here\n"),
      "[source-scan] self-test: comments that name an API are not calls")

# 1. The harness's own files.
own = sorted(set(
    glob.glob(os.path.join(TREE, "scripts/harness/*.swift"))
    + glob.glob(os.path.join(TREE, "scripts/flow-*-checks.swift"))
    + glob.glob(os.path.join(TREE, "scripts/fixtures/flows/*.json"))
    + glob.glob(os.path.join(TREE, "runner-1001/steps.d/recording-harness.sh"))))
own = [os.path.relpath(p, TREE) for p in own]
check(len([p for p in own if p.endswith(".json")]) >= 12 and any(p.endswith("CaptureDriver.swift") for p in own)
      and any(p.endswith("flow-replay-checks.swift") for p in own) and any(p.endswith("flow-app-checks.swift") for p in own),
      "[source-scan] the harness's files are all here (driver, both flow checks, at least 12 flows)", ", ".join(own))
for rel in own:
    hits = scan(rel, read(rel))
    check(not hits, "[source-scan] %s names no event tap, permission, Keychain, Apple event or tccutil API" % rel,
          "; ".join("line %d: %s (%s)" % h for h in hits))

# 2. The seams.
driver = strip_comments("d.swift", read("scripts/harness/CaptureDriver.swift"))
for seam in [r"EventCapture\.reenableTap\s*=\s*\{\s*_\s*in\s*fatalError\(",
             r"EventCapture\.remakeTap\s*=\s*\{\s*_\s*in\s*fatalError\(",
             r"EventCapture\.registerAX\s*=\s*\{\s*_\s*,\s*_\s*,\s*_\s*in\s*fatalError\("]:
    check(re.search(seam, driver) is not None,
          "[source-scan] CaptureDriver turns %s into a fatalError" % seam.split("\\.")[1].split("\\s")[0])
check(re.search(r"InMemoryTypedKeyStore\(\)", driver) is not None and "KeyStore" not in re.sub(r"InMemoryTypedKeyStore|TypedKeyStore\b", "", driver),
      "[source-scan] CaptureDriver keeps typing keys in memory only (InMemoryTypedKeyStore, no other keyring)")
calls = re.findall(r"\b\w*[cC]apture\w*\??\s*\.\s*start\s*\(|installEventTap|startInput|installAXObserver\s*\(", driver)
check(not calls, "[source-scan] CaptureDriver never starts EventCapture (no start(), installEventTap, startInput or live AX observer)",
      ", ".join(calls))
check(re.search(r"UserDefaults\.standard|NSUserDefaults", driver) is None,
      "[source-scan] CaptureDriver's defaults are in memory (no UserDefaults.standard)")
replay = strip_comments("r.swift", read("scripts/flow-replay-checks.swift"))
i_seams, i_driver = replay.find("CaptureDriver.installSeams()"), replay.find("CaptureDriver(t")
check(0 <= i_seams < i_driver, "[source-scan] flow-replay installs the seams before its first replay")
app = strip_comments("a.swift", read("scripts/flow-app-checks.swift"))
for seam, what in [(r"MemoryViewModel\.startInput\s*=\s*\{\s*_\s*in\s*true\s*\}", "starts no input (startInput)"),
                   (r"MemoryViewModel\.permissionRead\s*=\s*\{", "answers permission reads itself (permissionRead)"),
                   (r"MemoryViewModel\.permissionsGranted\s*=\s*\{\s*true\s*\}", "answers the permission gate itself"),
                   (r"MemoryViewModel\.launchIntentDefaults\s*=\s*MemoryDefaults\(\)", "keeps launch intents in memory"),
                   (r"env\[\"CFFIXED_USER_HOME\"\]", "refuses to run outside a synthetic HOME")]:
    check(re.search(seam, app) is not None, "[source-scan] flow-app " + what)
steps = os.path.join(TREE, "runner-1001/steps.d/recording-harness.sh")
if os.path.exists(steps):
    s = open(steps).read()
    check("DEVELOPMENT_SOURCE_CHECKS" in s and "CFFIXED_USER_HOME" in s,
          "[source-scan] flow-app is compiled as a check build (in-memory typing keyring, inert login item) and run in a scratch HOME")

# 3. The real code's paths.
ec = strip_comments("e.swift", read("Sources/MacMemApp/EventCapture.swift"))


def enclosing(text, pos):
    """The name of the func or static var a position sits in (the nearest declaration above it)."""
    before = text[:pos]
    m = list(re.finditer(r"\n\s*(?:@\w+\s+)*(?:(?:private|fileprivate|internal|public|final|override)\s+)*(func\s+(\w+)|static\s+var\s+(\w+))", before))
    return (m[-1].group(2) or m[-1].group(3)) if m else None


taps = [enclosing(ec, m.start()) for m in re.finditer(r"CGEvent\.tapCreate", ec)]
check(taps == ["installEventTap"], "[source-scan] the only event tap in the code the flows compile is made in EventCapture.installEventTap",
      "made in %s" % taps)
others = [p for p in glob.glob(os.path.join(TREE, "Sources/**/*.swift"), recursive=True)
          if "tapCreate" in strip_comments(p, open(p).read()) and not p.endswith("MacMemApp/EventCapture.swift")]
check(not others, "[source-scan] no other source file makes an event tap", ", ".join(others))
callers = [enclosing(ec, m.start()) for m in re.finditer(r"(?<!func )installEventTap\s*\(\s*\)", ec)]
check(sorted(callers) == ["remakeTap", "start"], "[source-scan] installEventTap is reached only from start() and the remakeTap seam",
      "called from %s" % callers)
ax = [enclosing(ec, m.start()) for m in re.finditer(r"AXObserverCreate\s*\(", ec)]
check(ax == ["registerAX"], "[source-scan] the only Accessibility observer is made in the registerAX seam", "made in %s" % ax)
mm = read("Sources/MacMemApp/MacMemApp.swift")
k = mm.find("KeychainTypedKeyStore.forStore")
block = mm[:k]
check(k > 0 and block.rfind("#else") > block.rfind("#if DEVELOPMENT_SOURCE_CHECKS") > block.rfind("#endif"),
      "[source-scan] the app attaches the Keychain typing keyring only outside check builds (#else of DEVELOPMENT_SOURCE_CHECKS)")
check(re.search(r"#if DEVELOPMENT_SOURCE_CHECKS\s*\n\s*static var typedKeyStore[^\n]*\n[^#]*InMemoryTypedKeyStore\(\)", mm) is not None,
      "[source-scan] a check build's typing keyring is in memory (MemoryViewModel.typedKeyStore)")
check(re.search(r"#if DEVELOPMENT_SOURCE_CHECKS\s*\n\s*static var loginItem\s*=\s*LoginItemControl\.inert", mm) is not None,
      "[source-scan] a check build's login item registers nothing (LoginItemControl.inert)")

print("source-scan: %d passed, %d failed" % (passed, failed))
sys.exit(1 if failed else 0)
