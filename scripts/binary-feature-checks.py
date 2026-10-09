#!/usr/bin/env python3
"""What the built MacMem binaries carry, by build (nm and strings only; nothing runs).

  public debug and release (the unflagged `swift build` a contributor gets):
    none of the 17 private Chrome typing symbols, no website typing symbol, no "Other websites" row or help,
    no OWNER BUILD string; Chrome page history (ChromePageProbe, ChromeEventSender) and "Remember what you type".
  owner debug and release (both shipped flags, what every release stage builds):
    website typing (WebTypingRoute, BrowserTypingJoin) and the Other websites help; Chrome page history;
    the debug MacMem also carries every private Chrome typing symbol and string (the public scans are not vacuous).

Usage: binary-feature-checks.py --public-debug B --public-release B --owner-debug B --owner-release B
Every assertion reports PASS or FAIL; the exit is non-zero when any failed.
"""
import argparse, importlib.util, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("ctc", os.path.join(HERE, "chrome-typing-checks.py"))
ctc = importlib.util.module_from_spec(spec); spec.loader.exec_module(ctc)
failures = 0


def check(cond, msg):
    global failures
    print(("PASS " if cond else "FAIL ") + msg, flush=True)
    failures += 0 if cond else 1


def read(cmd, path):
    if not os.path.isfile(path) or os.path.getsize(path) == 0:
        return None
    p = subprocess.run(cmd + [path], capture_output=True, text=True, errors="replace")
    return p.stdout if p.returncode == 0 else None


def main():
    ap = argparse.ArgumentParser()
    for k in ("public-debug", "public-release", "owner-debug", "owner-release"):
        ap.add_argument("--" + k, required=True)
    a = ap.parse_args()
    bins = {"public debug": a.public_debug, "public release": a.public_release,
            "owner debug": a.owner_debug, "owner release": a.owner_release}
    nm, text = {}, {}
    for name, path in bins.items():
        nm[name], text[name] = read(["nm"], path), read(["strings", "-a"], path)
        check(nm[name] is not None and text[name] is not None, "%s MacMem is built and readable (%s)" % (name, path))
    check(len(ctc.PRIVATE_SYMBOLS) == 17, "the private Chrome typing symbol list has its 17 names")
    for name in ("public debug", "public release"):
        n, t = nm[name] or "", text[name] or ""
        if name == "public debug":
            found = [s for s in ctc.PRIVATE_SYMBOLS if s in n]
            check(not found, "public debug MacMem: none of the 17 private Chrome typing symbols %s" % (found or ""))
        found = [s for s in ("WebTypingRoute", "BrowserTypingBurst", "BrowserTypingJoin") if s in n]
        check(not found, "%s MacMem: no website typing symbol %s" % (name, found or ""))
        check("OWNER BUILD" not in t, "%s MacMem: no OWNER BUILD string" % name)
        found = [s for s in ("Websites not listed above", "Other websites") if s in t]
        check(not found, "%s MacMem: no Other websites row or help %s" % (name, found or ""))
        check("Remember what you type" in t, "%s MacMem: the typing row's copy is there (the string scan reads the binary)" % name)
        missing = [s for s in ("ChromePageProbe", "ChromeEventSender") if s not in n]
        check(not missing, "%s MacMem: Chrome page history (ChromePageProbe, ChromeEventSender) %s" % (name, missing or ""))
    for name in ("owner debug", "owner release"):
        n, t = nm[name] or "", text[name] or ""
        missing = [s for s in ("WebTypingRoute", "BrowserTypingJoin") if s not in n]
        check(not missing, "%s MacMem: website typing (WebTypingRoute, BrowserTypingJoin) %s" % (name, missing or ""))
        check("Websites not listed above, except blocked sites. Never in Incognito or Guest windows." in t,
              "%s MacMem: the Other websites help" % name)
        missing = [s for s in ("ChromePageProbe", "ChromeEventSender") if s not in n]
        check(not missing, "%s MacMem: Chrome page history %s" % (name, missing or ""))
    n, t = nm["owner debug"] or "", text["owner debug"] or ""
    missing = [s for s in ctc.PRIVATE_SYMBOLS if s not in n]
    check(not missing, "owner debug MacMem: every private Chrome typing symbol (the public symbol scan is not vacuous) %s" % (missing or ""))
    missing = [s for s in ctc.PRIVATE_STRINGS if s not in t]
    check(not missing, "owner debug MacMem: every private Chrome typing string (the public string scan is not vacuous) %s" % (missing or ""))
    missing = [s for s in ctc.WEB_TYPING_PRIVATE if s not in n]
    check(not missing, "owner debug MacMem: website typing's gate and site rules %s" % (missing or ""))
    if failures:
        print("%d failed" % failures)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
