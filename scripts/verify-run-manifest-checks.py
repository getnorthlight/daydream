#!/usr/bin/env python3
"""Cases for scripts/verify-run-manifest.py: one fixture SUMMARY per way a run can go wrong, plus the clean run.
Every case reports; the exit is non-zero when any case failed."""
import os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "verify-run-manifest.py")
HEAD = "step\tlane\tconfig\tfile\tneeds\tmin_pass\tstatus\treason\tsince\treview_by\n"
MANIFEST = HEAD + "".join("\t".join(r) + "\n" for r in [
    ["build", "smoke", "public-contract", "-", "headless", "", "required", "", "", ""],
    ["owner-build", "smoke", "owner", "-", "headless", "", "required", "", "", ""],
    ["alpha", "capture", "owner", "scripts/alpha-checks.swift", "headless", "3", "required", "", "", ""],
    ["beta", "ai-tools", "owner", "scripts/beta-checks.swift", "headless", "60", "known-failure", "writer wake bug", "2026-10-08", "2026-10-22"],
    ["gamma", "setup-ui", "owner", "scripts/gamma-checks.swift", "window", "", "window-only", "on-screen window", "2026-10-08", "2026-10-22"],
    ["delta", "storage", "public", "scripts/delta-checks.swift", "headless", "", "required", "", "", ""],
])
GOOD = """build exit=0 pass=1
owner-build exit=0 pass=1
compile-alpha exit=0 pass=0
alpha exit=0 pass=5
compile-beta exit=0 pass=0
beta exit=1 pass=60
gamma SKIPPED-UI
delta exit=0 pass=1
"""
# beta's pins: exit 1 and two failures; its log (beside SUMMARY) prints 60 PASS lines and exactly those two.
KNOWN = "step\texit\tfail\nbeta\t1\tFAIL AC (shipped): the shipped day\nbeta\t1\tFAIL case-2\n"
BETA_LOG = "PASS one\nFAIL AC (shipped): the shipped day passes the oracle \u2014 at 17:10\nFAIL case-2\nbeta: 60 passed, 2 failed\n"
failures = 0


def run(summary, *extra, manifest=MANIFEST, known=KNOWN, logs=None, today="2026-10-09"):
    with tempfile.TemporaryDirectory() as d:
        m = os.path.join(d, "m.tsv"); s = os.path.join(d, "SUMMARY"); k = os.path.join(d, "known.tsv")
        open(m, "w").write(manifest); open(s, "w").write(summary); open(k, "w").write(known)
        for name, text in ({"beta": BETA_LOG} if logs is None else logs).items():
            open(os.path.join(d, name + ".log"), "w").write(text)
        p = subprocess.run([sys.executable, TOOL, "--manifest", m, "--known", k, "--summary", s, "--today", today, *extra],
                           capture_output=True, text=True)
        return p.returncode, p.stdout + p.stderr


def case(label, want_rc, summary, *extra, expect=None, **kw):
    global failures
    rc, out = run(summary, *extra, **kw)
    ok = rc == want_rc and (expect is None or expect in out)
    print(("PASS " if ok else "FAIL ") + label + ("" if ok else " (rc=%d)\n%s" % (rc, out)))
    failures += 0 if ok else 1


case("a clean run with a known failure and a window skip is OK", 0, GOOD, expect="KNOWN-FAIL (1)")
case("a selected manifest step missing from SUMMARY fails", 1, GOOD.replace("delta exit=0 pass=1\n", ""), expect="delta: in the manifest")
case("a SUMMARY step the manifest doesn't list fails", 1, GOOD + "omega exit=0 pass=2\n", expect="omega: not in")
case("compile-X of a listed X is allowed", 0, GOOD.replace("compile-alpha exit=0", "compile-alpha exit=0"))
case("a failed compile-X counts as X failing", 1, GOOD.replace("compile-alpha exit=0", "compile-alpha exit=1"), expect="compile-alpha: exit=1")
case("a required step that exits non-zero fails", 1, GOOD.replace("delta exit=0", "delta exit=1"), expect="delta: exit=1")
case("a known failure that passes is XPASS", 1, GOOD.replace("beta exit=1", "beta exit=0"), expect="XPASS")
case("a known failure past its review_by fails", 1, GOOD, today="2026-10-23", expect="beta: known-failure past its review_by")
case("a window-only row past its review_by fails", 1, GOOD, today="2026-10-23", expect="gamma: window-only past its review_by")
case("a window-only row without dates is refused", 2, GOOD, manifest=MANIFEST.replace("on-screen window\t2026-10-08\t2026-10-22", "on-screen window\t\t"), expect="needs a since")
case("a known failure without min_pass is refused", 2, GOOD, manifest=MANIFEST.replace("headless\t60\tknown-failure", "headless\t\tknown-failure"), expect="needs a min_pass")
case("a known failure with no pinned failure is refused", 2, GOOD, known="step\texit\tfail\n", expect="pins no failure")
case("a pin for a row that is not a known failure is refused", 2, GOOD, known=KNOWN + "alpha\t1\tFAIL x\n", expect="alpha is not a known-failure row")
case("a known failure that fails exactly as pinned is KNOWN-FAIL", 0, GOOD, expect="beta: 2 pinned failure(s), pass=60")
case("a known failure with an unpinned FAIL line fails (a new regression in the same file)", 1, GOOD,
     logs={"beta": BETA_LOG + "FAIL secure field refuses typing case-5\n"}, expect="unexpected failure: FAIL secure field refuses typing case-5")
case("a pin matches up to a separator only (case-2 is not case-23)", 1, GOOD,
     logs={"beta": BETA_LOG.replace("FAIL case-2\n", "FAIL case-23\n")}, expect="unexpected failure: FAIL case-23")
case("a pinned failure that no longer fails is reported (narrow the pin)", 1, GOOD,
     logs={"beta": BETA_LOG.replace("FAIL case-2\n", "PASS case-2\n")}, expect="pinned failure no longer fails (narrow the pin): FAIL case-2")
case("a known failure that crashes (another exit code) fails", 1, GOOD.replace("beta exit=1 pass=60", "beta exit=2 pass=60"), expect="exit=2, pinned exit=1")
case("a known failure below its min_pass fails (it stopped running its checks)", 1, GOOD.replace("beta exit=1 pass=60", "beta exit=1 pass=8"), expect="pass=8, below min_pass 60")
case("a known failure without a log fails", 1, GOOD, logs={}, expect="no log at")
case("a crash line is a failure label", 0, GOOD.replace("beta exit=1 pass=60", "beta exit=133 pass=60"),
     known="step\texit\tfail\nbeta\t133\tPrecondition failed: search boundary changed originating\n",
     logs={"beta": "main/x.swift:87: Precondition failed: search boundary changed originating\n"})
case("a unittest FAIL is one label in both its forms", 0, GOOD, known="step\texit\tfail\nbeta\t1\tFAIL: test_one\n",
     logs={"beta": "test_one (__main__.T.test_one) ... FAIL\ntest_two (__main__.T.test_two) ... ok\nFAIL: test_one (__main__.T.test_one)\nFAILED (failures=1)\n"})
case("a failed compile of a known failure is never known", 1, GOOD.replace("compile-beta exit=0", "compile-beta exit=1"), expect="never a known failure")
case("a compile-X line alone does not count as X running", 1, GOOD.replace("delta exit=0 pass=1\n", "compile-delta exit=0 pass=0\n"),
     expect="delta: in the manifest (lane storage) but its step is missing from SUMMARY (only its compile-delta line ran)")
case("a step listed twice in SUMMARY fails", 1, GOOD + "delta exit=0 pass=1\n", expect="delta: listed twice")
case("ONLY that names no manifest row fails (it verified nothing)", 1, "", "--only", "^(compile-)?(setup-upgrade-checks)$", expect="names no manifest row")
case("fewer PASS lines than min_pass fails", 1, GOOD.replace("alpha exit=0 pass=5", "alpha exit=0 pass=2"), expect="below min_pass")
case("a headless step logged SKIPPED-UI fails", 1, GOOD.replace("delta exit=0 pass=1", "delta SKIPPED-UI"), expect="needs no window")
case("a window step SKIPPED-UI in a windowed run fails", 1, GOOD, "--windowed", expect="run that has a window")
case("ONLY narrows the selection (others need not appear)", 0, "alpha exit=0 pass=4\n", "--only", "^alpha$")
case("LANES narrows the selection but keeps the builds", 1, "alpha exit=0 pass=4\n", "--lanes", "capture", expect="build: in the manifest")
case("LANES=capture with the builds is OK", 0, "build exit=0 pass=1\nowner-build exit=0 pass=1\nalpha exit=0 pass=4\n", "--lanes", "capture")
case("an unknown lane is refused", 2, GOOD, "--lanes", "nope", expect="unknown lane")
case("a known failure without a reason is refused", 2, GOOD, manifest=MANIFEST.replace("writer wake bug", ""), expect="needs a reason")
case("a duplicated manifest row is refused", 2, GOOD, manifest=MANIFEST + MANIFEST.splitlines()[-1] + "\n", expect="listed twice")
case("a garbled SUMMARY line fails", 1, GOOD + "zeta exploded\n")

with tempfile.TemporaryDirectory() as d:
    m = os.path.join(d, "m.tsv"); open(m, "w").write(MANIFEST)
    dry = os.path.join(d, "dry.tsv")
    k = os.path.join(d, "known.tsv"); open(k, "w").write(KNOWN)
    open(dry, "w").write("build\tswift build\nowner-build\tswift build\ncompile-alpha\tswiftc\nalpha\tx\nbeta\tx\ngamma\tx\ndelta\tx\n")
    p = subprocess.run([sys.executable, TOOL, "--manifest", m, "--known", k, "--dryrun", dry], capture_output=True, text=True)
    ok = p.returncode == 0
    print(("PASS " if ok else "FAIL ") + "the DRYRUN step list matches the manifest")
    failures += 0 if ok else 1
    open(dry, "a").write("epsilon\tx\n")
    p = subprocess.run([sys.executable, TOOL, "--manifest", m, "--known", k, "--dryrun", dry], capture_output=True, text=True)
    ok = p.returncode == 1 and "epsilon" in p.stdout
    print(("PASS " if ok else "FAIL ") + "a runner step missing from the manifest fails the DRYRUN comparison")
    failures += 0 if ok else 1
    full = "build\tswift build\nowner-build\tswift build\ncompile-alpha\tswiftc\nalpha\tx\nbeta\tx\ngamma\tx\ndelta\tx\n"
    for label, text, want in [
        ("a DRYRUN with a row's compile but not its step fails", full.replace("alpha\tx\n", ""), "manifest step alpha is not a runner step (only compile-alpha is)"),
        ("a DRYRUN with a step listed twice fails", full + "delta\tx\n", "runner step delta is listed twice")]:
        open(dry, "w").write(text)
        p = subprocess.run([sys.executable, TOOL, "--manifest", m, "--known", k, "--dryrun", dry], capture_output=True, text=True)
        ok = p.returncode == 1 and want in p.stdout
        print(("PASS " if ok else "FAIL ") + label + ("" if ok else "\n" + p.stdout + p.stderr))
        failures += 0 if ok else 1
    p = subprocess.run([sys.executable, TOOL, "--manifest", m, "--known", k, "--skip-regex"], capture_output=True, text=True)
    rx = p.stdout.strip()
    ok = re.search(rx, "gamma") and not re.search(rx, "compile-gamma") and not re.search(rx, "delta")
    print(("PASS " if ok else "FAIL ") + "the skip regex is the window rows' own steps (their compiles still run)")
    failures += 0 if ok else 1
    p = subprocess.run([sys.executable, TOOL, "--manifest", m, "--known", k, "--lanes-regex", "capture"], capture_output=True, text=True)
    rx = p.stdout.strip()
    ok = all(re.search(rx, n) for n in ("build", "owner-build", "alpha", "compile-alpha")) and not re.search(rx, "delta")
    print(("PASS " if ok else "FAIL ") + "the lanes regex selects the lane, its compiles and the builds only")
    failures += 0 if ok else 1
    root = os.path.join(d, "root"); os.makedirs(os.path.join(root, "scripts"))
    for f in ("alpha-checks.swift", "beta-checks.swift", "gamma-checks.swift", "delta-checks.swift"):
        open(os.path.join(root, "scripts", f), "w").write("")
    ex = os.path.join(d, "ex.tsv"); open(ex, "w").write("file\tkind\treason\n")
    p = subprocess.run([sys.executable, TOOL, "--manifest", m, "--known", k, "--exempt", ex, "--root", root, "--inventory"], capture_output=True, text=True)
    ok = p.returncode == 0
    print(("PASS " if ok else "FAIL ") + "an inventory where every check file is a manifest step passes")
    failures += 0 if ok else 1
    open(os.path.join(root, "scripts", "orphan-checks.swift"), "w").write("")
    p = subprocess.run([sys.executable, TOOL, "--manifest", m, "--known", k, "--exempt", ex, "--root", root, "--inventory"], capture_output=True, text=True)
    ok = p.returncode == 1 and "orphan-checks.swift" in p.stdout
    print(("PASS " if ok else "FAIL ") + "an orphan check file fails the inventory")
    failures += 0 if ok else 1
    open(ex, "a").write("scripts/orphan-checks.swift\ttool\trun by hand\n")
    p = subprocess.run([sys.executable, TOOL, "--manifest", m, "--known", k, "--exempt", ex, "--root", root, "--inventory"], capture_output=True, text=True)
    ok = p.returncode == 0
    print(("PASS " if ok else "FAIL ") + "an exempt row with a reason covers it")
    failures += 0 if ok else 1

if failures:
    print("%d failed" % failures)
    sys.exit(1)
