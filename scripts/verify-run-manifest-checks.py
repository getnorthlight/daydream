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


FHEAD = HEAD.rstrip("\n") + "\ttier\n"
# A fragment (scripts/checks-manifest.d/*.tsv): the manifest's columns plus tier; a new lane is allowed once the fragment
# declares it ("# lanes: boundary").
FRAG = FHEAD + "".join("\t".join(r) + "\n" for r in [
    ["epsilon", "boundary", "owner", "scripts/epsilon-checks.swift", "headless", "2", "required", "", "", "", "change"],
    ["zeta", "boundary", "owner", "scripts/zeta-checks.swift", "headless", "1", "known-failure", "lock bug repro", "2026-10-08", "2026-10-22", "rc"],
]) + "# lanes: boundary\n"
FRAG_KNOWN = "step\texit\tfail\nzeta\t1\tFAIL lock\n"
FRAG_GOOD = GOOD + "compile-epsilon exit=0 pass=0\nepsilon exit=0 pass=2\nzeta exit=1 pass=1\n"
FRAG_LOGS = {"beta": BETA_LOG, "zeta": "PASS before\nFAIL lock: paused and stopped\n"}


def write_tree(d, manifest, known, frags=None, known_frags=None):
    m = os.path.join(d, "m.tsv"); k = os.path.join(d, "known.tsv")
    open(m, "w").write(manifest); open(k, "w").write(known)
    for sub, files in (("m.d", frags or {}), ("known.d", known_frags or {})):
        if files:
            os.makedirs(os.path.join(d, sub), exist_ok=True)
        for name, text in files.items():
            open(os.path.join(d, sub, name), "w").write(text)
    return m, k


def run(summary, *extra, manifest=MANIFEST, known=KNOWN, logs=None, today="2026-10-09", frags=None, known_frags=None):
    with tempfile.TemporaryDirectory() as d:
        m, k = write_tree(d, manifest, known, frags, known_frags)
        s = os.path.join(d, "SUMMARY"); open(s, "w").write(summary)
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

# Fragments: scripts/checks-manifest.d/*.tsv and scripts/checks-known-failures.d/*.tsv beside the files they extend.
case("a fragment's rows join the manifest (its known failure pinned by a pin fragment)", 0, FRAG_GOOD,
     frags={"pkg.tsv": FRAG}, known_frags={"pkg.tsv": FRAG_KNOWN}, logs=FRAG_LOGS, expect="zeta: 1 pinned failure(s)")
case("a fragment's step missing from SUMMARY fails", 1, GOOD, frags={"pkg.tsv": FRAG}, known_frags={"pkg.tsv": FRAG_KNOWN},
     logs=FRAG_LOGS, expect="epsilon: in the manifest (lane boundary)")
case("a step in the manifest and a fragment is FAIL", 2, GOOD, frags={"pkg.tsv": FHEAD + "alpha\tcapture\towner\t-\theadless\t\trequired\t\t\t\tchange\n"},
     expect="FAIL: step alpha is listed in two files")
case("a step in two fragments is FAIL", 2, GOOD, frags={"a.tsv": FRAG, "b.tsv": FHEAD + FRAG.splitlines()[1] + "\n"},
     known_frags={"pkg.tsv": FRAG_KNOWN}, expect="FAIL: step epsilon is listed in two files")
case("a step pinned in two pin files is FAIL", 2, GOOD, frags={"pkg.tsv": FRAG},
     known_frags={"pkg.tsv": FRAG_KNOWN, "z.tsv": FRAG_KNOWN}, expect="FAIL: zeta is pinned in two files")
case("a fragment without the tier column is refused", 2, GOOD, frags={"pkg.tsv": HEAD + "epsilon\tboundary\towner\t-\theadless\t\trequired\t\t\t\n"},
     expect="header must be")
case("a fragment row with an unknown tier is refused", 2, GOOD, frags={"pkg.tsv": FRAG.replace("\tchange\n", "\tweekly\n")},
     known_frags={"pkg.tsv": FRAG_KNOWN}, expect="has tier 'weekly'")
case("a fragment's new lane is a lane (LANES=boundary selects it, with the builds)", 0,
     "build exit=0 pass=1\nowner-build exit=0 pass=1\nepsilon exit=0 pass=2\nzeta exit=1 pass=1\n", "--lanes", "boundary",
     frags={"pkg.tsv": FRAG}, known_frags={"pkg.tsv": FRAG_KNOWN}, logs=FRAG_LOGS)
case("files beside the fragments that are not .tsv are not fragments", 0, GOOD, frags={"README": "not a manifest\n"})
# Lane names (test-p2-int): a lane is a known one or one a manifest file declares; a typo is refused, not a new lane.
case("a fragment row whose lane is neither known nor declared is refused (a typo can't make a lane)", 2, GOOD,
     frags={"pkg.tsv": FRAG.replace("epsilon\tboundary", "epsilon\tboundry")}, known_frags={"pkg.tsv": FRAG_KNOWN},
     expect="has lane 'boundry', which is not a lane")
case("an undeclared new lane in a fragment is refused", 2, GOOD, frags={"pkg.tsv": FRAG.replace("# lanes: boundary\n", "")},
     known_frags={"pkg.tsv": FRAG_KNOWN}, expect="has lane 'boundary', which is not a lane")
case("a manifest row with a typo lane is refused", 2, GOOD, manifest=MANIFEST.replace("delta\tstorage", "delta\tstorge"),
     expect="has lane 'storge', which is not a lane")
case("a lane one fragment declares serves another fragment's rows", 0, FRAG_GOOD,
     frags={"a.tsv": FHEAD + "# lanes: boundary\n", "pkg.tsv": FRAG.replace("# lanes: boundary\n", "")}, known_frags={"pkg.tsv": FRAG_KNOWN},
     logs=FRAG_LOGS)
case("a declared lane must be a lane name", 2, GOOD, frags={"pkg.tsv": FRAG.replace("# lanes: boundary", "# lanes: Boundary Lane")},
     known_frags={"pkg.tsv": FRAG_KNOWN}, expect="declares lane 'Boundary Lane'")

# Time limits (test-p2-int): an optional `timeout` column, and a step the runner killed at its limit is named TIMEOUT.
TFRAG = FHEAD.rstrip("\n") + "\ttimeout\n" + FRAG.splitlines()[1] + "\t30\n" + FRAG.splitlines()[2] + "\n# lanes: boundary\n"
with tempfile.TemporaryDirectory() as d:
    m, k = write_tree(d, MANIFEST, KNOWN, {"pkg.tsv": TFRAG}, {"pkg.tsv": FRAG_KNOWN})
    p = subprocess.run([sys.executable, TOOL, "--manifest", m, "--known", k, "--timeouts"], capture_output=True, text=True)
    ok = p.returncode == 0 and p.stdout == "epsilon\t30\n"
    print(("PASS " if ok else "FAIL ") + "--timeouts lists a row's own limit; a row may leave the timeout cell out" + ("" if ok else ": %r %r" % (p.stdout, p.stderr)))
    failures += 0 if ok else 1
case("a timeout that is not whole seconds is refused", 2, GOOD, frags={"pkg.tsv": TFRAG.replace("\t30\n", "\t0\n")}, known_frags={"pkg.tsv": FRAG_KNOWN},
     expect="has timeout '0'")
case("a step the runner killed at its limit is FAIL, named TIMEOUT", 1, GOOD.replace("delta exit=0 pass=1", "delta exit=124 pass=0"),
     logs={"beta": BETA_LOG, "delta": "PASS started\nFAIL TIMEOUT delta: still running after 900 s; its process group was killed\n"},
     expect="TIMEOUT delta: still running after 900 s")
case("a known failure that times out is TIMEOUT, never KNOWN-FAIL", 1, GOOD.replace("beta exit=1 pass=60", "beta exit=124 pass=60"),
     logs={"beta": BETA_LOG + "FAIL TIMEOUT beta: still running after 900 s; its process group was killed\n"}, expect="TIMEOUT beta:")
case("a compile that times out is named TIMEOUT", 1, GOOD.replace("compile-alpha exit=0", "compile-alpha exit=124"),
     logs={"beta": BETA_LOG, "compile-alpha": "FAIL TIMEOUT compile-alpha: still running after 900 s\n"}, expect="TIMEOUT compile-alpha:")

# runner-1001/bounded.sh, the runner's own time limit: a hung step (and the child it started) is killed with its process
# group at the limit and logged FAIL TIMEOUT; a step that ends in time keeps its exit; step_timeout and the manifest's
# limit beat STEP_TIMEOUT.
BOUNDED = os.path.join(os.path.dirname(HERE), "runner-1001", "bounded.sh")
with tempfile.TemporaryDirectory() as d:
    script = r"""
set -u; source "$1"; OUT=$2
STEP_TIMEOUT=900 STEP_TIMEOUTS=$'hung\t2\nignores\t2'
step_timeout fast 7
echo "limits $(step_limit hung) $(step_limit fast) $(step_limit compile-hung) $(step_limit other)"
fn() { echo "fn $1"; return 3; }
s=$SECONDS; run_bounded fast "$(step_limit fast)" "$OUT/fast.log" "" fn ok; echo "fast rc=$? t=$((SECONDS-s))"
s=$SECONDS; run_bounded hung "$(step_limit hung)" "$OUT/hung.log" "" bash -c 'sleep 600 & echo child $!; sleep 600'; echo "hung rc=$? t=$((SECONDS-s))"
s=$SECONDS; run_bounded ignores "$(step_limit ignores)" "$OUT/ignores.log" 10 bash -c 'trap "" TERM; sleep 600'; echo "ignores rc=$? t=$((SECONDS-s))"
"""
    sh = os.path.join(d, "t.sh"); open(sh, "w").write(script)
    p = subprocess.run(["/bin/bash", sh, BOUNDED, d], capture_output=True, text=True, timeout=120)
    out = p.stdout
    hung = open(os.path.join(d, "hung.log")).read() if os.path.exists(os.path.join(d, "hung.log")) else ""
    child = re.search(r"child (\d+)", hung)
    alive = child and subprocess.run(["kill", "-0", child.group(1)], capture_output=True).returncode == 0
    t = dict(re.findall(r"(\w+) rc=\d+ t=(\d+)", out))
    checks = [
        ("limits 2 7 900 900" in out, "the row's limit and step_timeout beat STEP_TIMEOUT; compile-X keeps the default"),
        ("fast rc=3" in out and "fn ok" in open(os.path.join(d, "fast.log")).read(), "a step (a shell function) that ends in time keeps its own exit and output"),
        ("hung rc=124" in out and int(t.get("hung", 99)) <= 6 and "FAIL TIMEOUT hung: still running after 2 s" in hung,
         "a hung step is killed at its limit, exit 124, its log ends FAIL TIMEOUT (reported, not stalled)"),
        (bool(child) and not alive, "the hung step's child is killed with its process group"),
        ("ignores rc=124" in out and int(t.get("ignores", 99)) <= 9, "a step that ignores TERM is killed too (KILL to its group)"),
    ]
    for ok, label in checks:
        print(("PASS " if ok else "FAIL ") + "bounded.sh: " + label + ("" if ok else ": %r %r" % (out, p.stderr)))
        failures += 0 if ok else 1

with tempfile.TemporaryDirectory() as d:
    m, k = write_tree(d, MANIFEST, KNOWN, {"pkg.tsv": FRAG}, {"pkg.tsv": FRAG_KNOWN})
    p = subprocess.run([sys.executable, TOOL, "--manifest", m, "--known", k, "--list-lanes"], capture_output=True, text=True)
    ok = p.returncode == 0 and "boundary" in p.stdout.split() and "smoke" in p.stdout.split()
    print(("PASS " if ok else "FAIL ") + "a fragment's lane is listed with the manifest's (lanes.sh runs every listed lane)")
    failures += 0 if ok else 1
    dry = os.path.join(d, "dry.tsv")
    open(dry, "w").write("build\tswift build\nowner-build\tswift build\ncompile-alpha\tswiftc\nalpha\tx\nbeta\tx\ngamma\tx\ndelta\tx\n")
    p = subprocess.run([sys.executable, TOOL, "--manifest", m, "--known", k, "--dryrun", dry], capture_output=True, text=True)
    ok = p.returncode == 1 and "manifest step epsilon is not a runner step" in p.stdout
    print(("PASS " if ok else "FAIL ") + "a fragment row the runner (steps.d) does not list fails the DRYRUN comparison")
    failures += 0 if ok else 1
    root = os.path.join(d, "root"); os.makedirs(os.path.join(root, "scripts"))
    for f in ("alpha", "beta", "gamma", "delta", "epsilon", "zeta"):
        open(os.path.join(root, "scripts", f + "-checks.swift"), "w").write("")
    ex = os.path.join(d, "ex.tsv"); open(ex, "w").write("file\tkind\treason\n")
    p = subprocess.run([sys.executable, TOOL, "--manifest", m, "--known", k, "--exempt", ex, "--root", root, "--inventory"], capture_output=True, text=True)
    ok = p.returncode == 0
    print(("PASS " if ok else "FAIL ") + "the inventory sees fragment rows (their check files are not orphans)" + ("" if ok else "\n" + p.stdout + p.stderr))
    failures += 0 if ok else 1
    os.remove(os.path.join(d, "m.d", "pkg.tsv")); os.remove(os.path.join(d, "known.d", "pkg.tsv"))
    p = subprocess.run([sys.executable, TOOL, "--manifest", m, "--known", k, "--exempt", ex, "--root", root, "--inventory"], capture_output=True, text=True)
    ok = p.returncode == 1 and "orphan check file scripts/epsilon-checks.swift" in p.stdout
    print(("PASS " if ok else "FAIL ") + "without the fragment its check file is an orphan")
    failures += 0 if ok else 1

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

# Tiers: an 11th manifest column (smoke < change < rc < nightly; blank = rc). TIER=<t> selects that tier and every lower one.
TIERED = FHEAD + "".join("\t".join(r) + "\n" for r in [
    ["build", "smoke", "public-contract", "-", "headless", "", "required", "", "", "", "smoke"],
    ["owner-build", "smoke", "owner", "-", "headless", "", "required", "", "", "", "smoke"],
    ["app-module", "smoke", "public", "-", "headless", "", "required", "", "", "", "change"],
    ["quick", "smoke", "n/a", "-", "headless", "1", "required", "", "", "", "smoke"],
    ["owner-twin", "capture", "owner", "-", "headless", "1", "required", "", "", "", "change"],
    ["twin", "capture", "public", "-", "headless", "1", "required", "", "", "", "rc"],
    ["blank", "capture", "owner", "-", "headless", "1", "required", "", "", "", ""],
    ["mutant", "setup-ui", "owner", "-", "headless", "1", "required", "", "", "", "nightly"],
])
B = "build exit=0 pass=0\nowner-build exit=0 pass=0\n"
case("TIER=smoke selects the smoke rows only (and the smoke builds)", 0, B + "quick exit=0 pass=1\n", "--tier", "smoke", manifest=TIERED, known="step\texit\tfail\n")
case("TIER=change also needs the change rows (the app module, the owner twin)", 1, B + "quick exit=0 pass=1\n", "--tier", "change",
     manifest=TIERED, known="step\texit\tfail\n", expect="owner-twin: in the manifest")
case("TIER=rc needs rc and blank-tier rows (blank = rc) but not nightly ones", 0,
     B + "app-module exit=0 pass=0\nquick exit=0 pass=1\nowner-twin exit=0 pass=1\ntwin exit=0 pass=1\nblank exit=0 pass=1\n",
     manifest=TIERED, known="step\texit\tfail\n", expect="selection: TIER=rc")
case("TIER=rc without a blank-tier row fails (blank is rc)", 1, B + "app-module exit=0 pass=0\nquick exit=0 pass=1\nowner-twin exit=0 pass=1\ntwin exit=0 pass=1\n",
     "--tier", "rc", manifest=TIERED, known="step\texit\tfail\n", expect="blank: in the manifest")
case("TIER=nightly needs the nightly rows too", 1, B + "app-module exit=0 pass=0\nquick exit=0 pass=1\nowner-twin exit=0 pass=1\ntwin exit=0 pass=1\nblank exit=0 pass=1\n",
     "--tier", "nightly", manifest=TIERED, known="step\texit\tfail\n", expect="mutant: in the manifest")
case("a nightly step in an rc run's SUMMARY is still a manifest step (no FAIL)", 0,
     B + "app-module exit=0 pass=0\nquick exit=0 pass=1\nowner-twin exit=0 pass=1\ntwin exit=0 pass=1\nblank exit=0 pass=1\nmutant exit=0 pass=1\n",
     manifest=TIERED, known="step\texit\tfail\n")
case("an unknown TIER is refused", 2, B, "--tier", "weekly", manifest=TIERED, known="step\texit\tfail\n", expect="unknown tier")
case("a manifest row with an unknown tier is refused", 2, B, manifest=TIERED.replace("\tnightly\n", "\tsometimes\n"),
     known="step\texit\tfail\n", expect="has tier 'sometimes'")
with tempfile.TemporaryDirectory() as d:
    m, k = write_tree(d, TIERED, "step\texit\tfail\n")
    def tool(*args):
        return subprocess.run([sys.executable, TOOL, "--manifest", m, "--known", k, *args], capture_output=True, text=True).stdout.strip()
    rx = tool("--select-regex", "--tier", "smoke")
    ok = all(re.search(rx, n) for n in ("build", "owner-build", "quick")) and not any(re.search(rx, n) for n in ("app-module", "owner-twin", "twin"))
    print(("PASS " if ok else "FAIL ") + "the runner's tier regex: TIER=smoke is the smoke rows and builds, not the app module" + ("" if ok else ": " + rx))
    failures += 0 if ok else 1
    rx = tool("--select-regex", "--lanes", "capture", "--tier", "change")
    ok = all(re.search(rx, n) for n in ("build", "app-module", "owner-twin", "compile-owner-twin")) and not any(re.search(rx, n) for n in ("twin", "quick", "mutant"))
    print(("PASS " if ok else "FAIL ") + "LANES=capture TIER=change: the lane's change rows and the builds" + ("" if ok else ": " + rx))
    failures += 0 if ok else 1
    plan = tool("--plan", "--tier", "rc", "--solo", "^blank$").splitlines()
    names = [l.split("\t")[0] for l in plan]
    ok = names == ["blank", "capture", "smoke"] and not any(re.search(l.split("\t")[1], "build") for l in plan) and plan[1].endswith("\t2")
    print(("PASS " if ok else "FAIL ") + "the lanes plan: a solo worker first, one worker per lane, no builds (built once before)" + ("" if ok else ": %s" % plan))
    failures += 0 if ok else 1

# runner-1001/mutate.sh on toy rows: a throwaway git repo whose "runner" fails its toy step when value=1 is gone and
# fails its compile on "syntax error"; CAUGHT / MISSED / BROKEN (absent snippet, failed compile, red baseline).
MUTATE = os.path.join(os.path.dirname(HERE), "runner-1001", "mutate.sh")
TOY_RUNNER = """#!/bin/bash
out=$WORKDIR/out-$1; mkdir -p "$out"
[[ compile-toy =~ $ONLY ]] && [[ toy =~ $ONLY ]] && [[ build =~ $ONLY ]] || { echo "bad ONLY $ONLY"; exit 1; }
c=0; grep -q 'syntax error' toy.txt && c=1
r=1; grep -q '^value=1$' toy.txt && r=0; grep -q '^red$' toy.txt && r=1
n=0; grep -q '^norun$' toy.txt && n=1
{ echo "build exit=0 pass=0"; echo "compile-toy exit=$c pass=0"; [ $c = 0 ] && [ $n = 0 ] && echo "toy exit=$r pass=1"; } > "$out/SUMMARY"
if [ $c = 0 ] && [ $r = 0 ] && [ $n = 0 ]; then echo "VERDICT OK: toy"; else echo "VERDICT FAIL: toy"; fi > "$out/VERDICT"
"""
MHEAD = "bug\tstep\tfile\told\tnew\tnote\n"


def mutate_case(label, rows, want_rc, want, toy="value=1\nother=2\n"):
    global failures
    with tempfile.TemporaryDirectory() as d:
        repo = os.path.join(d, "repo"); os.makedirs(repo)
        open(os.path.join(repo, "toy.txt"), "w").write(toy)
        open(os.path.join(repo, "toy-runner.sh"), "w").write(TOY_RUNNER)
        for cmd in (["init", "-q"], ["add", "."], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "toy"]):
            subprocess.run(["git", "-C", repo] + cmd, check=True, capture_output=True)
        rows_f = os.path.join(d, "toy.tsv"); open(rows_f, "w").write(MHEAD + rows)
        env = dict(os.environ, MUT_REPO=repo, MUT_RUNNER="toy-runner.sh")
        p = subprocess.run(["bash", MUTATE, os.path.join(d, "run"), rows_f], capture_output=True, text=True, env=env)
        got = []
        res = os.path.join(d, "run", "RESULTS.tsv")
        if os.path.exists(res):
            got = [l.split("\t")[:2] for l in open(res).read().splitlines()]
        clean = subprocess.run(["git", "-C", repo, "worktree", "list"], capture_output=True, text=True).stdout.count("\n") == 1
        ok = p.returncode == want_rc and got == want and clean
        print(("PASS " if ok else "FAIL ") + label + ("" if ok else " (rc=%d got=%s clean=%s)\n%s" % (p.returncode, got, clean, p.stdout + p.stderr)))
        failures += 0 if ok else 1


mutate_case("mutate.sh: a row whose bug the step catches is CAUGHT (exit 0, the snapshot removed)",
            "caught\ttoy\ttoy.txt\tvalue=1\tvalue=2\tthe toy check fails\n", 0, [["CAUGHT", "caught"]])
mutate_case("mutate.sh: CAUGHT, MISSED, BROKEN (absent snippet, failed compile, a snippet twice) and escapes; exit 1",
            "caught\ttoy\ttoy.txt\tvalue=1\tvalue=2\tfails\n"
            "missed\ttoy\ttoy.txt\tother=2\tother=3\tnothing checks other\n"
            "absent\ttoy\ttoy.txt\tnothere\tx\tthe snippet is gone\n"
            "compile\ttoy\ttoy.txt\tvalue=1\tsyntax error\tthe compile fails\n"
            "twice\ttoy\ttoy.txt\t=\t:\tnot unique\n"
            "escaped\ttoy\ttoy.txt\tvalue=1\\nother=2\tvalue=9\\nother=2\ta newline escape\n", 1,
            [["CAUGHT", "caught"], ["MISSED", "missed"], ["BROKEN", "absent"], ["BROKEN", "compile"], ["BROKEN", "twice"], ["CAUGHT", "escaped"]])
mutate_case("mutate.sh: a step that fails unmutated makes its rows BROKEN (exit 1)",
            "caught\ttoy\ttoy.txt\tvalue=1\tvalue=2\tfails\n", 1, [["BROKEN", "caught"]], toy="value=1\nred\n")
mutate_case("mutate.sh: a bug that stops the step from running is BROKEN, not CAUGHT (the verdict's FAIL is the missing step)",
            "norun\ttoy\ttoy.txt\tother=2\tnorun\tthe step never runs\n", 1, [["BROKEN", "norun"]])
mutate_case("mutate.sh: a no-op row is MISSED (exit 1)", "noop\ttoy\ttoy.txt\tother=2\tother=2\tchanges nothing\n", 1, [["MISSED", "noop"]])

# runner-1001/bin/summary-diff.py: a run against an earlier one, step by step (the "no step lost, no lower PASS" diff).
SDIFF = os.path.join(os.path.dirname(HERE), "runner-1001", "bin", "summary-diff.py")


def sdiff_case(label, old, new, want_rc, want, *extra, lanes=False):
    global failures
    with tempfile.TemporaryDirectory() as d:
        a = os.path.join(d, "old"); open(a, "w").write(old)
        if lanes:  # the lanes.sh layout: a step in two workers' SUMMARY counts once, with its best line
            b = os.path.join(d, "run")
            for i, part in enumerate(new):
                o = os.path.join(b, "w-%d" % i, "out-w-%d" % i); os.makedirs(o); open(os.path.join(o, "SUMMARY"), "w").write(part)
        else:
            b = os.path.join(d, "new"); open(b, "w").write(new)
        p = subprocess.run([sys.executable, SDIFF, a, b, *extra], capture_output=True, text=True)
        ok = p.returncode == want_rc and all(w in p.stdout for w in want)
        print(("PASS " if ok else "FAIL ") + label + ("" if ok else " (rc=%d)\n%s" % (p.returncode, p.stdout + p.stderr)))
        failures += 0 if ok else 1


sdiff_case("summary-diff: same steps, a higher PASS count and an added step are OK", "a exit=0 pass=3\nb exit=1 pass=0\n",
           "a exit=0 pass=4\nb exit=1 pass=0\nc exit=0 pass=1\n", 0, ["0 lost, 0 worse, 0 lower", "a: pass 3 -> 4", "  c"])
sdiff_case("summary-diff: a lost step, a step that turned red and a lower PASS count fail", "a exit=0 pass=3\nb exit=0 pass=2\nc exit=0 pass=1\n",
           "a exit=0 pass=2\nb exit=1 pass=2\n", 1, ["1 lost, 1 worse, 1 lower", "a: pass 3 -> 2", "b: exit 0 -> 1"])
sdiff_case("summary-diff: --moved reports a step another tier runs now, not LOST", "a exit=0 pass=1\nmut exit=0 pass=1\n",
           "a exit=0 pass=1\n", 0, ["== MOVED (1)", "0 lost"], "--moved", "^mut$")
sdiff_case("summary-diff: a lanes.sh run folder reads every worker's SUMMARY; a repeated step keeps its best line",
           "a exit=0 pass=1\nb exit=0 pass=5\n", ["a exit=0 pass=1\nb exit=1 pass=0\n", "b exit=0 pass=5\n"], 0, ["0 lost, 0 worse, 0 lower"], lanes=True)

if failures:
    print("%d failed" % failures)
    sys.exit(1)
