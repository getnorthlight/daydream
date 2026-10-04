"""Chrome typing groundwork: build and check both the public and the private build.

Synthetic only. Builds offline (no package resolution), runs the synthetic
checks, and never launches DayDream or Chrome, sends an Apple Event, creates
an event tap, requests a permission or signs anything.

  public  (default):  swift build                                   -> no Chrome typing code, Chrome page history
  private (flagged):  swift build -Xswiftc -DDAYDREAM_CHROME_TYPING -> join, witness, tests, Chrome page history

Usage: python3 scripts/chrome-typing-checks.py [--scratch DIR]
       python3 scripts/chrome-typing-checks.py --binary PATH   (scan one built binary, e.g. a release MacMem)
"""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FLAG = "DAYDREAM_CHROME_TYPING"
# Types that exist only in the private build.
PRIVATE_SYMBOLS = ["BrowserTypingJoin", "ChromeTypingWitness", "ChromeJoinRequest", "BrowserTypingBlockList", "BrowserTypingBurst", "JoinSession",
                   "ChromeTargetPolicy", "BrowserTypingSites", "ChromeAXAccess", "ChromeBounds", "BrowserTypingTiming", "BrowserTypingInput",
                   "BrowserTypingFieldRules", "ChromeWindowMatching", "ChromeModeReader"]
# Strings that only the private Chrome typing code carries (typing-only
# block-list and field-rule entries, the witness's extra AX attribute names).
# The shared site list (turbotax.intuit.com and the rest) and Google's team ID
# (EQHXZ8M8AV, ChromePageTarget) are public now: Chrome page history uses them.
PRIVATE_STRINGS = ["shell.cloud.google.com", "inputarea", "AXDOMClassList", "AXPlaceholderValue",
                   "Google Chrome Framework.framework"]
# Website typing (typing-all SPEC-LATER 4.2): compiled only into Chrome typing
# builds, and live only in the owner build. Every public binary is free of these
# names and strings (the scan below); the private build carries the first two
# (its checks drive them), the owner build carries them all
# (scripts/typing-release-gate-checks.py --owner).
WEB_TYPING_SYMBOLS = ["WebTypingGate", "BrowserTypingSiteRules", "WebTypedRow", "WebTypingText", "WebTypingRoute"]
WEB_TYPING_STRINGS = ["chrome-typing-join-v1", "chrome-search-url-v1", "What you type on websites in Google Chrome"]
WEB_TYPING_PRIVATE = ["WebTypingGate", "BrowserTypingSiteRules"]
# Chrome page history is public: both builds, and any scanned binary, must carry
# it. This also keeps the private-symbol scan honest (it would pass on an empty binary).
PUBLIC_REQUIRED_SYMBOLS = ["ChromePageProbe", "ChromeEventSender", "BrowserSites", "ChromePageRecorder"]
PUBLIC_REQUIRED_STRINGS = ["EQHXZ8M8AV", "plannedparenthood.org", "chrome-appleevents-page-v1"]
# A sample of the private build's synthetic checks that must run there, and only there.
PRIVATE_CHECKS = ["incognito window front: zero titles, URLs, bounds or AX content read",
                  "lagging AX and AE: the save-time strict check discards the burst",
                  "Spotlight query never saved as Chrome typing",
                  "unsigned 'Chrome' bundle does not satisfy the Chrome requirement",
                  "blocked by default: https://secure.chase.com/overview",
                  "unlisted same-frame twin focused: denied before any title, tab, URL or label",
                  "a closing Incognito window still in AXWindows: denied before any page read",
                  "sensitive field denied: Card number label",
                  "sensitive field denied: xterm.js terminal",
                  "key processed 200 ms after it was typed: dropped, burst discarded",
                  "a second Chrome process (another profile directory): denied with zero Apple Events",
                  "blocked by default (review I4/C3): https://shell.cloud.google.com/",
                  # Website typing on the rebuilt burst (Checks/WebTypingChecks.swift).
                  "website typing: an Incognito window open: nothing typed, and the unsaved words before it are dropped",
                  "website typing: Other websites off means nothing is typed on an unknown site",
                  "website typing: a password field reads nothing and drops the unsaved words",
                  "website gate: the closed release gate refuses every website"]


def run(args, **kw):
    # Echo the command without the long object-file list.
    shown = [Path(str(a)).name if str(a).endswith(".o") else str(a) for a in args]
    objects = sum(1 for a in args if str(a).endswith(".o"))
    shown = [a for a in shown if not a.endswith(".o")] + ([f"<{objects} object files>"] if objects else [])
    print("$", " ".join(shown), flush=True)
    return subprocess.run([str(a) for a in args], cwd=ROOT, text=True, capture_output=True, timeout=1200, **kw)


def must(p, what):
    if p.returncode != 0:
        sys.stdout.write(p.stdout[-4000:] + p.stderr[-4000:])
        raise SystemExit("FAILED: " + what)


def build(scratch, flagged):
    extra = ["-Xswiftc", "-D" + FLAG] if flagged else []
    # mac-mem: MacMemChecks drives the CLI/MCP binary next to it (safe typing access checks).
    for product in ["MacMemChecks", "mac-mem", "MacMem"]:
        must(run(["swift", "build", "--disable-automatic-resolution", "--scratch-path", scratch, *extra, "--product", product]),
             ("private" if flagged else "public") + " build of " + product)
    return Path(scratch) / "debug"


def symbols(binary):
    p = run(["nm", binary]); must(p, "nm " + str(binary))
    return p.stdout


def strings(binary):
    p = run(["strings", "-a", binary]); must(p, "strings " + str(binary))
    return p.stdout


def scan(binary):
    """Review C7: a built binary (debug or release) carries no private Chrome
    typing symbol or string. Returns the offending names."""
    nm, text = symbols(binary), strings(binary)
    return ([s for s in PRIVATE_SYMBOLS + WEB_TYPING_SYMBOLS if s in nm or s in text]
            + [s for s in PRIVATE_STRINGS + WEB_TYPING_STRINGS if s in text])


def missing_page_history(binary):
    """Chrome page history symbols and strings that a built MacMem lacks."""
    nm, text = symbols(binary), strings(binary)
    return [s for s in PUBLIC_REQUIRED_SYMBOLS if s not in nm] + [s for s in PUBLIC_REQUIRED_STRINGS if s not in text]


def parse_check(debug, flagged, work):
    """Compile and run the Cocoa Scripting parse check with a Chrome-shaped dictionary."""
    out = Path(work) / ("parse-" + ("private" if flagged else "public"))
    out.mkdir(parents=True, exist_ok=True)
    shutil.copy(ROOT / "scripts/fixtures/chrome-shaped.sdef", out / "ChromeShaped.sdef")
    info = out / "embedded-info.plist"
    info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "local.synthetic.chrome-parse-checks",
                                     "NSAppleScriptEnabled": True, "OSAScriptingDefinition": "ChromeShaped.sdef"}))
    objects = sorted((debug / "MemoryCore.build").glob("*.o")) + sorted((debug / "HistoryCore.build").glob("*.o")) + sorted((debug / "PrivacyPolicy.build").glob("*.o"))
    binary = out / "chrome-apple-event-parse-checks"
    must(run(["swiftc", "-parse-as-library", "-I", debug / "Modules", "-I", "Sources/CSQLite",
              *(["-D" + FLAG] if flagged else []), "scripts/chrome-apple-event-parse-checks.swift", *objects,
              "-lsqlite3", "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", info,
              "-o", binary]), "compile parse checks")
    p = run([binary]); must(p, "parse checks"); print(p.stdout, end="")
    return p.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scratch", help="build directory to reuse (default: a new temporary directory)")
    ap.add_argument("--binary", help="only scan this built binary for private Chrome typing symbols and strings")
    a = ap.parse_args()
    if a.binary:
        found = scan(a.binary)
        if found: raise SystemExit("FAILED: private Chrome typing code in %s: %s" % (a.binary, found))
        missing = missing_page_history(a.binary)
        if missing: raise SystemExit("FAILED: Chrome page history missing from %s: %s" % (a.binary, missing))
        print("PASS: no private Chrome typing symbol or string in", a.binary)
        print("PASS: Chrome page history symbols and strings present in", a.binary)
        return
    work = Path(a.scratch or tempfile.mkdtemp(prefix="dd-chrome-typing-checks-"))
    results = {}
    for flagged in [False, True]:
        name = "private" if flagged else "public"
        debug = build(work / ("build-" + name), flagged)
        p = run([debug / "MacMemChecks"]); must(p, name + " synthetic checks")
        passes = [l for l in p.stdout.splitlines() if l.startswith("PASS: ")]
        present = [c for c in PRIVATE_CHECKS if "PASS: " + c in p.stdout]
        nm = symbols(debug / "MacMem")
        found = [s for s in PRIVATE_SYMBOLS if s in nm]
        missing = missing_page_history(debug / "MacMem")
        assert not missing, (name + " build must contain Chrome page history", missing)
        if flagged:
            assert present == PRIVATE_CHECKS, ("private build must run the Chrome typing checks", PRIVATE_CHECKS, present)
            assert found == PRIVATE_SYMBOLS, ("private build must contain the Chrome typing code", found)
            text = strings(debug / "MacMem")
            assert all(s in text for s in PRIVATE_STRINGS), ("the string scan is not vacuous", [s for s in PRIVATE_STRINGS if s not in text])
            web = [s for s in WEB_TYPING_PRIVATE if s not in nm]
            assert not web, ("private build must contain website typing's gate and site rules", web)
        else:
            assert not present, ("public build must not contain Chrome typing checks", present)
            assert not found, ("public binary must contain no Chrome typing path", found)
            leaked = scan(debug / "MacMem")
            assert not leaked, ("public binary must contain no Chrome typing symbol or string", leaked)
        parse = parse_check(debug, flagged, work)
        results[name] = (len(passes), len(found), parse.count("PASS: "))
    p = run([sys.executable, "scripts/check_browser_boundary.py"]); must(p, "browser boundary checks"); print(p.stderr.strip().splitlines()[-1])
    for name, (passes, found, parse) in results.items():
        print(f"{name}: {passes} synthetic checks passed; {parse} parse checks passed; private-only symbols in MacMem: {found}")
    print("scratch:", work)


if __name__ == "__main__":
    main()
