#!/usr/bin/env python3
"""Step tests-status (lane flows): Tests/README.md stays true (see that page).

- Package.swift declares no .testTarget (the Command Line Tools have no XCTest; the README says why).
- Every file under Tests/ (the README aside) is a `file` of a manifest row (scripts/checks-manifest.tsv or a
  scripts/checks-manifest.d/*.tsv fragment), so the suite runs it, and the README names it and that row's step.
- The README names the stand-in runner (scripts/search-test-runner.swift) and its step (typesense-tests).
Also prints, as a note only, whether this machine has XCTest (xcrun --find xctest).

Usage: tests-status.py [TREE]. Prints PASS/FAIL lines; exit 1 on any FAIL.
"""
import fnmatch
import glob
import os
import re
import subprocess
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


def rows():
    out = []
    for path in [os.path.join(TREE, "scripts/checks-manifest.tsv")] + sorted(glob.glob(os.path.join(TREE, "scripts/checks-manifest.d/*.tsv"))):
        with open(path) as f:
            lines = [l.rstrip("\n").split("\t") for l in f if l.strip() and not l.startswith("#")]
        out += [dict(zip(lines[0], cells)) for cells in lines[1:]]
    return out


pkg = open(os.path.join(TREE, "Package.swift")).read()
code = "\n".join(l.split("//")[0] for l in pkg.split("\n"))
check(".testTarget(" not in code, "[tests] Package.swift declares no testTarget (Tests/README.md: the Command Line Tools have no XCTest)")
readme_path = os.path.join(TREE, "Tests/README.md")
check(os.path.isfile(readme_path), "[tests] Tests/README.md exists")
readme = open(readme_path).read() if os.path.isfile(readme_path) else ""
check("scripts/search-test-runner.swift" in readme and "typesense-tests" in readme,
      "[tests] Tests/README.md names the stand-in runner (scripts/search-test-runner.swift) and its step (typesense-tests)")
manifest = rows()
files = sorted(os.path.relpath(p, TREE) for p in glob.glob(os.path.join(TREE, "Tests/**/*"), recursive=True)
               if os.path.isfile(p) and not p.endswith("Tests/README.md"))
check(len(files) >= 1, "[tests] Tests/ holds test files", "none")
for f in files:
    steps = [r["step"] for r in manifest if any(fnmatch.fnmatchcase(f, p) for p in (r.get("file") or "").split(",") if p and p != "-")]
    check(bool(steps), "[tests] %s is a manifest row's file (the suite runs it)" % f, "no row lists it")
    check(f in readme and all(s in readme for s in steps), "[tests] Tests/README.md names %s and its step %s" % (f, ",".join(steps) or "-"))
try:
    r = subprocess.run(["xcrun", "--find", "xctest"], capture_output=True, text=True, timeout=20)
    print("note: xcrun --find xctest: " + ((r.stdout or r.stderr).strip().splitlines() or ["(nothing)"])[0])
except Exception as e:  # informational only
    print("note: xcrun --find xctest: %s" % e)
print("tests-status: %d passed, %d failed" % (passed, failed))
sys.exit(1 if failed else 0)
