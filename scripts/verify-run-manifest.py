#!/usr/bin/env python3
"""The run's verdict: compares a runner SUMMARY with scripts/checks-manifest.tsv.

  --summary SUMMARY [--only REGEX] [--lanes a,b] [--tier T] [--windowed] [--logs DIR]
      The selection is the rows that match ONLY, are in LANES (the builds always are) and whose tier is T or lower
      (smoke < change < rc < nightly; a blank tier is rc; T defaults to rc).
      Exit 1 when the selection (ONLY/LANES/TIER) names no manifest row, a selected manifest step did not run (its
      compile-X line alone does not count), a step appears twice, SUMMARY has a step the manifest doesn't list
      (compile-X belongs to row X), a required step or any compile failed, a step printed fewer PASS lines than
      its min_pass, a step that needs no window was skipped as SKIPPED-UI (or any window step was, with
      --windowed), or a dated row (known failure, window-only) is past its review_by.
      A known failure is pinned by scripts/checks-known-failures.tsv: it must exit with the listed code, print
      at least min_pass PASS lines, and every FAIL line in its log (DIR/<step>.log, DIR defaults to SUMMARY's
      folder) must be one of its listed failures, each of which must still fail. Anything else is FAIL (a new
      regression, a crash, an expected failure that now passes: narrow the row). Passing in full is XPASS.
      Prints PASS / KNOWN-FAIL / SKIPPED-UI / FAIL groups.
  --inventory
      Exit 1 when a check file (INVENTORY_GLOBS) is neither a manifest row's file nor listed in
      scripts/checks-inventory-exempt.tsv.
  --dryrun DRYRUN-steps.tsv
      Exit 1 when the runner's step list (DRYRUN=1) and the manifest's differ, a row's own step is missing (a
      compile-X line alone does not count), or a step is listed twice.
  --lanes-regex a,b [--tier T]
      Print the step regex for those lanes (plus the builds every lane needs) for the runner's LANES=.
  --select-regex [--lanes a,b] [--tier T]
      Print the step regex of the selection (every lane when --lanes is empty): the runner's LANES= and TIER=.
  --plan [--only REGEX] [--lanes a,b] [--tier T] [--solo REGEX]
      runner-1001/lanes.sh's workers: one line "<worker>\t<step regex>\t<steps>" per lane with selected steps, the
      builds (built once, by lanes.sh) left out, and one worker of its own for each selected step matching --solo.
  --skip-regex
      Print the regex of the steps that need a window (manifest needs=window): the headless runner's SKIP.
  --list-lanes
      Print the lanes of the manifest and its fragments, one per line (runner-1001/lanes.sh runs each).
  --timeouts
      Print "step<TAB>seconds" for every row with a `timeout` (the runner's per-step limit; default 900 s).

Fragments: every scripts/checks-manifest.d/*.tsv (the folder beside --manifest, named after it) adds rows with the
same columns plus `tier`; every scripts/checks-known-failures.d/*.tsv adds pins with the same columns as the pin file.
A step listed in two files (the manifest and a fragment, or two fragments) is FAIL, and so is a step pinned in two
pin files.

Lanes: a row's lane is one of KNOWN_LANES or a lane a manifest file declares on a "# lanes: a,b" comment line (a
package that adds a lane declares it in its fragment). Any other lane is refused, so a typo can't make a new lane.

Timeouts: the manifest and its fragments may end their header with a `timeout` column (seconds, digits; a row may
leave the cell out). The runner (run-checks.sh) kills a step still running after its limit (default STEP_TIMEOUT, 900 s)
with its whole process group and logs "FAIL TIMEOUT <step>"; the verdict names it "TIMEOUT <step>", never a known
failure.
"""
import argparse, datetime, fnmatch, glob, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LANE_NAME = re.compile(r"^[a-z0-9][a-z0-9-]*$")
# The lanes every row may use. A package adds a lane by declaring it in its fragment ("# lanes: flows"); a lane neither
# known nor declared is refused (a typo made a new lane, run by lanes.sh, that no LANES= selection named).
KNOWN_LANES = {"smoke", "setup-ui", "capture", "storage", "ai-tools", "release", "perf"}
LANES_DECL = re.compile(r"^#\s*lanes:\s*(.*)$")
CONFIGS = {"owner", "public", "public-contract", "n/a"}
NEEDS = {"headless", "window", "typesense", "model"}
STATUSES = {"required", "known-failure", "window-only"}
COLUMNS = ["step", "lane", "config", "file", "needs", "min_pass", "status", "reason", "since", "review_by"]
TIER_COLUMNS = COLUMNS + ["tier"]  # fragments always carry the tier column
TIMEOUT_COLUMNS = TIER_COLUMNS + ["timeout"]  # optional last column: the step's own time limit in seconds
TIERS = ["smoke", "change", "rc", "nightly"]  # blank tier = rc
ALWAYS = {"build", "owner-build", "app-module", "owner-app-module"}  # every lane compiles against these (when tiered in)
EXEMPT_KINDS = {"tool", "library", "release-module", "qa-optin", "perf-phase2", "stage-only", "render",
                "manual-window", "fixture", "runner",
                "needs-model",  # needs the real model or runtime archive; the manifest's needs=model lane is Phase 2
                "phase2-rewrite",  # stale against today's app (reason says how); Phase 2 rewrites it, not run until then
                "pending"}  # Phase 1 bookkeeping only: files still to be removed, merged or wired; none may remain
# Check files anywhere in the tree (the sub-packages' check targets and fixtures too), not the product's own sources.
INVENTORY_GLOBS = ["scripts/*check*", "scripts/*-render.swift", "Checks/*.swift", "Tests/**/*", "**/*Checks/**/*",
                   "**/*Checks.swift", "**/*-checks.*", "**/*_checks.*", "**/check_*.py", "**/test_*.py",
                   "**/run-core-checks.sh", "**/*Tests/**/*"]
INVENTORY_SKIP = re.compile(r"(^|/)(\.build|\.git|Vendor|node_modules|dist|__pycache__)(/|$)|^Sources/")
KNOWN_COLUMNS = ["step", "exit", "fail"]
# A failure line in a step's log, and the label it is pinned by (scripts/checks-known-failures.tsv `fail` is a prefix
# of the label). Swift checks print "FAIL ..." / "FAIL: ...", a crash "<file>:<line>: Precondition failed: ...",
# unittest "name (Class) ... FAIL" and "FAIL: name (Class)" (the same label), node --test "not ok N - name".
UNITTEST_LINE = re.compile(r"^(test\S*) \((\S+)\) \.\.\. (FAIL|ERROR)$")
UNITTEST_HEAD = re.compile(r"^(FAIL|ERROR): (test\S*) \((\S+)\)$")
CRASH = re.compile(r"(Precondition failed|Fatal error|Assertion failed)\b.*$")


def die(msg):
    print("verify-run-manifest: " + msg, file=sys.stderr)
    sys.exit(2)


def read_tsv(path, columns, alt=None, more=None):
    """Rows of a TSV whose header is `columns` (or `alt`, or `more`, when given); every row gets every key of the
    longest. With the `more` header (a trailing optional column), a row may leave out that last cell."""
    rows = []
    with open(path) as f:
        lines = [l.rstrip("\n") for l in f if l.strip() and not l.startswith("#")]
    if not lines:
        die("%s: no header" % path)
    head = lines[0].split("\t")
    if head != columns and head != alt and head != more:
        die("%s: header must be %s, is %s" % (path, alt or columns, head))
    keys = max([columns, alt or [], more or []], key=len)
    for n, line in enumerate(lines[1:], 2):
        cells = line.split("\t")
        if len(cells) != len(head) and not (more and head == more and len(cells) == len(head) - 1):
            die("%s row %d (%s): %d cells, want %d" % (path, n, cells[0], len(cells), len(head)))
        row = dict(zip(head, cells))
        for c in keys:
            row.setdefault(c, "")
        rows.append(row)
    return rows


def declared_lanes(path):
    """The lanes a manifest file declares on its "# lanes: a,b" comment lines."""
    out = set()
    for line in open(path):
        m = LANES_DECL.match(line.strip())
        if m:
            for lane in (x.strip() for x in m.group(1).split(",")):
                if not LANE_NAME.match(lane):
                    die("%s: declares lane %r (lowercase letters, digits and dashes)" % (os.path.basename(path), lane))
                out.add(lane)
    return out


def fragments(path):
    """The fragment files of a manifest or pin file: <name>.d/*.tsv beside it, in lexical order."""
    d = os.path.splitext(path)[0] + ".d"
    return sorted(glob.glob(os.path.join(d, "*.tsv"))) if os.path.isdir(d) else []


def load_manifest(path):
    by, where = {}, {}
    files = [path] + fragments(path)
    lanes = set(KNOWN_LANES)
    for f in files:
        lanes |= declared_lanes(f)
    for f in files:
        main = f == path
        for r in read_tsv(f, COLUMNS if main else TIER_COLUMNS, TIER_COLUMNS, TIMEOUT_COLUMNS):
            s = r["step"]
            if s in by:
                if where[s] == f:
                    die("manifest: step %s listed twice in %s" % (s, os.path.basename(f)))
                die("FAIL: step %s is listed in two files, %s and %s (one row per step)" % (s, where[s], f))
            check_row(r, lanes, f)
            by[s] = r
            where[s] = f
    return by


def check_row(r, lanes=None, where=""):
    s = r["step"]
    if not LANE_NAME.match(r["lane"]):
        die("manifest: %s has lane %r" % (s, r["lane"]))
    if lanes is not None and r["lane"] not in lanes:
        die("manifest: %s (%s) has lane %r, which is not a lane: the lanes are %s; a package that adds a lane declares it "
            "in its fragment (\"# lanes: %s\")" % (s, os.path.basename(where), r["lane"], ",".join(sorted(lanes)), r["lane"]))
    if r.get("timeout") and not (r["timeout"].isdigit() and int(r["timeout"]) > 0):
        die("manifest: %s has timeout %r (whole seconds, more than 0)" % (s, r["timeout"]))
    if r["tier"] and r["tier"] not in TIERS:
        die("manifest: %s has tier %r (one of %s, blank = rc)" % (s, r["tier"], "|".join(TIERS)))
    if r["config"] not in CONFIGS:
        die("manifest: %s has config %r" % (s, r["config"]))
    if r["needs"] not in NEEDS:
        die("manifest: %s has needs %r" % (s, r["needs"]))
    if r["status"] not in STATUSES:
        die("manifest: %s has status %r" % (s, r["status"]))
    if r["min_pass"] and not r["min_pass"].isdigit():
        die("manifest: %s has min_pass %r" % (s, r["min_pass"]))
    if r["status"] == "known-failure" and not r["min_pass"]:
        die("manifest: known failure %s needs a min_pass (the PASS lines it still prints)" % s)
    if r["status"] in ("known-failure", "window-only"):
        for c in ("reason", "since", "review_by"):
            if not r[c]:
                die("manifest: %s %s needs a %s" % (r["status"], s, c))
        for c in ("since", "review_by"):
            try:
                datetime.date.fromisoformat(r[c])
            except ValueError:
                die("manifest: %s %s %r is not YYYY-MM-DD" % (s, c, r[c]))
    if r["status"] == "window-only" and r["needs"] != "window":
        die("manifest: %s is window-only but needs %s" % (s, r["needs"]))
    if r["needs"] == "window" and r["status"] == "required":
        die("manifest: %s needs a window, so it can't be required in the headless runner" % s)


def load_known(path, rows):
    """scripts/checks-known-failures.tsv and its fragments: {step: (exit code, [failure label prefixes])}, one row per
    pinned failure. A step's pins live in one file."""
    known, where = {}, {}
    pins = []
    for f in [path] + fragments(path):
        for r in read_tsv(f, KNOWN_COLUMNS):
            if r["step"] in where and where[r["step"]] != f:
                die("FAIL: %s is pinned in two files, %s and %s (a step's pins live in one file)" % (r["step"], where[r["step"]], f))
            where[r["step"]] = f
            pins.append(r)
    for r in pins:
        s = r["step"]
        if s not in rows or rows[s]["status"] != "known-failure":
            die("%s: %s is not a known-failure row of the manifest" % (os.path.basename(path), s))
        if not re.fullmatch(r"-?\d+", r["exit"]) or r["exit"] == "0":
            die("%s: %s has exit %r (a known failure exits non-zero)" % (os.path.basename(path), s, r["exit"]))
        if not r["fail"].strip():
            die("%s: %s has an empty fail label" % (os.path.basename(path), s))
        code = int(r["exit"])
        if s in known and known[s][0] != code:
            die("%s: %s lists two exit codes" % (os.path.basename(path), s))
        known.setdefault(s, (code, []))[1].append(r["fail"].strip())
    for s, row in rows.items():
        if row["status"] == "known-failure" and s not in known:
            die("%s: known failure %s pins no failure (list its exit and FAIL lines)" % (os.path.basename(path), s))
    return known


def fail_labels(log):
    """The failure labels a step's log prints, in order, each once."""
    out = []
    try:
        lines = open(log, errors="replace").read().splitlines()
    except OSError:
        return None
    for line in lines:
        line = line.strip()
        m = UNITTEST_LINE.match(line)
        label = None
        if m:
            label = "%s: %s (%s)" % (m.group(3), m.group(1), m.group(2))
        elif UNITTEST_HEAD.match(line):
            label = line
        elif re.match(r"^FAIL\b", line) or re.match(r"^not ok\b", line):
            label = line
        else:
            c = CRASH.search(line)
            if c:
                label = c.group(0)
        if label and label not in out:
            out.append(label)
    return out


def timed_out(log, name):
    """The runner's TIMEOUT line in a step's log ("FAIL TIMEOUT <step>: ..."), without its prefix, or None."""
    try:
        lines = open(log, errors="replace").read().splitlines()
    except OSError:
        return None
    for line in reversed(lines):
        if line.startswith("FAIL TIMEOUT %s:" % name):
            return line[len("FAIL TIMEOUT %s:" % name):].strip()
    return None


def pinned(label, pin):
    """A pin names a failure label: the whole label, or its start up to a separator (so case-2 is not case-23)."""
    return label == pin or (label.startswith(pin) and label[len(pin)] in " :(,;\u2014")


def owner_row(name, rows):
    """The manifest row a SUMMARY step belongs to (compile-X belongs to X), or None."""
    if name in rows:
        return rows[name], False
    if name.startswith("compile-") and name[len("compile-"):] in rows:
        return rows[name[len("compile-"):]], True
    return None, False


def parse_summary(path):
    out = []
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        m = re.match(r"^(\S+) exit=(-?\d+) pass=(\d+)$", line)
        if m:
            out.append((m.group(1), "ran", int(m.group(2)), int(m.group(3))))
            continue
        m = re.match(r"^(\S+) (SKIPPED-UI|DRYRUN)$", line)
        if m:
            out.append((m.group(1), m.group(2), None, None))
            continue
        out.append((line.split()[0], "garbled", None, None))
    return out


def all_lanes(rows):
    return sorted({r["lane"] for r in rows.values()})


def lane_set(text, rows):
    lanes = {l.strip() for l in (text or "").split(",") if l.strip()}
    bad = lanes - set(all_lanes(rows))
    if bad:
        die("unknown lane(s) %s; lanes are %s" % (",".join(sorted(bad)), ",".join(all_lanes(rows))))
    return lanes


def tier_of(row):
    return row.get("tier") or "rc"


def tier_ok(row, tier):
    return TIERS.index(tier_of(row)) <= TIERS.index(tier or "rc")


def check_tier(tier):
    if tier and tier not in TIERS:
        die("unknown tier %r; tiers are %s (each runs the lower ones too)" % (tier, " < ".join(TIERS)))
    return tier or "rc"


def selected(row, only, lanes, tier="nightly"):
    if only and not re.search(only, row["step"]):
        return False
    if lanes and row["lane"] not in lanes and row["step"] not in ALWAYS:
        return False
    return tier_ok(row, tier)


def step_regex(names):
    return "^(compile-)?(%s)$" % "|".join(re.escape(n) for n in sorted(names)) if names else "^$"


def verify_summary(args, rows, known):
    today = datetime.date.fromisoformat(args.today) if args.today else datetime.date.today()
    lanes = lane_set(args.lanes, rows)
    tier = check_tier(args.tier)
    only = args.only or ""
    logs = args.logs or os.path.dirname(os.path.abspath(args.summary))
    entries = parse_summary(args.summary)
    groups = {"PASS": [], "KNOWN-FAIL": [], "SKIPPED-UI": [], "FAIL": []}
    ran = set()      # rows whose own step ran (or was skipped as SKIPPED-UI); a compile-X line alone is not X running
    names = set()
    picked = [s for s, row in rows.items() if selected(row, only, lanes, tier)]
    print("selection: TIER=%s LANES=%s ONLY=%s: %d rows" % (tier, args.lanes or "(all)", (only[:120] + "...") if len(only) > 120 else (only or "(all)"), len(picked)))
    if not picked:
        groups["FAIL"].append("the selection (ONLY=%r LANES=%r TIER=%s) names no manifest row: nothing was verified" % (only, args.lanes or "", tier))
    for name, kind, rc, npass in entries:
        if name in names:
            groups["FAIL"].append("%s: listed twice in SUMMARY (wired twice? both copies write the same log)" % name)
            continue
        names.add(name)
        row, is_compile = owner_row(name, rows)
        if row is None:
            groups["FAIL"].append("%s: not in scripts/checks-manifest.tsv or its fragments (add a row, or remove the step)" % name)
            continue
        if kind == "garbled":
            groups["FAIL"].append("%s: unreadable SUMMARY line" % name)
            continue
        if kind == "DRYRUN":
            continue
        if not is_compile:
            ran.add(row["step"])
        status = row["status"]
        if kind == "SKIPPED-UI":
            if row["needs"] != "window":
                groups["FAIL"].append("%s: skipped as SKIPPED-UI but the manifest says it needs no window" % name)
            elif args.windowed:
                groups["FAIL"].append("%s: SKIPPED-UI in a run that has a window" % name)
            elif not is_compile:
                groups["SKIPPED-UI"].append("%s (needs the window lane, until %s)" % (name, row["review_by"]))
            continue
        timed = timed_out(os.path.join(logs, name + ".log"), name) if rc != 0 else None
        if timed:  # never a known failure either: a hung step proves nothing about its pins
            groups["FAIL"].append("TIMEOUT %s: %s" % (name, timed))
            continue
        if is_compile:
            if rc != 0:  # never a known failure: the pinned failure is the check's, not its build's
                groups["FAIL"].append("%s: exit=%d (a compile failure is never a known failure)" % (name, rc))
            continue
        if status == "known-failure":
            group, line = known_verdict(name, row, rc, npass, known[row["step"]], logs)
            groups[group].append(line)
            continue
        if rc != 0:
            groups["FAIL"].append("%s: exit=%d pass=%d" % (name, rc, npass))
            continue
        if row["min_pass"] and npass < int(row["min_pass"]):
            groups["FAIL"].append("%s: pass=%d, below min_pass %s (did it run its checks?)" % (name, npass, row["min_pass"]))
            continue
        groups["PASS"].append("%s pass=%d" % (name, npass))
    for s in picked:
        row = rows[s]
        if s not in ran:
            why = " (only its compile-%s line ran)" % s if "compile-" + s in names else ""
            groups["FAIL"].append("%s: in the manifest (lane %s) but its step is missing from SUMMARY%s" % (s, row["lane"], why))
        if row["review_by"] and datetime.date.fromisoformat(row["review_by"]) < today:
            groups["FAIL"].append("%s: %s past its review_by %s (fix it or re-date it with a reason)" % (s, row["status"], row["review_by"]))
    print("== PASS (%d)" % len(groups["PASS"]))
    for g in ("KNOWN-FAIL", "SKIPPED-UI", "FAIL"):
        print("== %s (%d)" % (g, len(groups[g])))
        for line in groups[g]:
            print("  " + line)
    verdict = "FAIL" if groups["FAIL"] else "OK"
    print("VERDICT %s: %d pass, %d known failures, %d window-lane skips, %d failures" % (
        verdict, len(groups["PASS"]), len(groups["KNOWN-FAIL"]), len(groups["SKIPPED-UI"]), len(groups["FAIL"])))
    return 1 if groups["FAIL"] else 0


def known_verdict(name, row, rc, npass, pin, logs):
    """("KNOWN-FAIL", line) when the step failed exactly as pinned, else ("FAIL", why)."""
    code, expected = pin
    if rc == 0:
        return "FAIL", "%s: XPASS, a known failure passed (pass=%d); remove its known-failure status and pins" % (name, npass)
    problems = []
    if rc != code:
        problems.append("exit=%d, pinned exit=%d" % (rc, code))
    if npass < int(row["min_pass"]):
        problems.append("pass=%d, below min_pass %s" % (npass, row["min_pass"]))
    labels = fail_labels(os.path.join(logs, name + ".log"))
    if labels is None:
        problems.append("no log at %s" % os.path.join(logs, name + ".log"))
        labels = []
    for label in labels:
        if not any(pinned(label, e) for e in expected):
            problems.append("unexpected failure: %s" % label[:200])
    for e in expected:
        if not any(pinned(label, e) for label in labels):
            problems.append("pinned failure no longer fails (narrow the pin): %s" % e[:200])
    if problems:
        return "FAIL", "%s: known failure, but not as pinned: %s" % (name, "; ".join(problems))
    return "KNOWN-FAIL", "%s: %d pinned failure(s), pass=%d (min %s): %s (since %s, until %s)" % (
        name, len(expected), npass, row["min_pass"], row["reason"], row["since"], row["review_by"])


def plan(rows, only, lanes, tier, solo):
    """lanes.sh's workers: a lane's selected steps (not the builds, which lanes.sh builds once), and a worker of its own
    for every selected step matching `solo` (a long step that has no step after it depending on it)."""
    picked = [s for s, r in rows.items() if selected(r, only, lanes, tier) and s not in ALWAYS]
    work = {}
    for s in picked:
        name = s if solo and re.search(solo, s) else rows[s]["lane"]
        work.setdefault(name, []).append(s)
    for name in sorted(work, key=lambda n: (n not in rows, n)):
        print("%s\t%s\t%d" % (name, step_regex(work[name]), len(work[name])))
    return 0


def verify_dryrun(args, rows):
    names = [l.split("\t", 1)[0] for l in open(args.dryrun) if l.strip()]
    problems = []
    listed, seen = set(), set()
    for n in names:
        if n in seen:
            problems.append("runner step %s is listed twice" % n)
            continue
        seen.add(n)
        row, is_compile = owner_row(n, rows)
        if row is None:
            problems.append("runner step %s is not in the manifest" % n)
        elif not is_compile:
            listed.add(row["step"])
    for s in rows:
        if s not in listed:
            why = " (only compile-%s is)" % s if "compile-" + s in seen else ""
            problems.append("manifest step %s is not a runner step%s" % (s, why))
    for p in problems:
        print("FAIL " + p)
    if not problems:
        print("PASS the runner's %d steps and the manifest's %d rows agree" % (len(names), len(rows)))
    return 1 if problems else 0


def verify_inventory(args, rows):
    exempt = read_tsv(args.exempt, ["file", "kind", "reason"])
    patterns = set()
    for r in rows.values():
        for f in r["file"].split(","):
            if f and f != "-":
                patterns.add(f)
    problems = []
    for e in exempt:
        if e["kind"] not in EXEMPT_KINDS:
            problems.append("exempt %s: kind %r is not one of %s" % (e["file"], e["kind"], ",".join(sorted(EXEMPT_KINDS))))
        if not e["reason"]:
            problems.append("exempt %s: no reason" % e["file"])
        if not os.path.exists(os.path.join(args.root, e["file"])):
            problems.append("exempt %s: no such file (drop the row)" % e["file"])
        patterns.add(e["file"])
    for p in sorted(patterns):
        if not glob.glob(os.path.join(args.root, p), recursive=True):
            problems.append("manifest/exempt file %s matches nothing" % p)
    files = set()
    for g in INVENTORY_GLOBS:
        for f in glob.glob(os.path.join(args.root, g), recursive=True):
            rel = os.path.relpath(f, args.root)
            if os.path.isfile(f) and not INVENTORY_SKIP.search(rel):
                files.add(rel)
    orphans = sorted(f for f in files if not any(fnmatch.fnmatchcase(f, p) for p in patterns))
    for f in orphans:
        problems.append("orphan check file %s: give it a manifest step or an exempt row with a reason" % f)
    for p in problems:
        print("FAIL " + p)
    if not problems:
        print("PASS inventory: %d check files, each a manifest step's or listed exempt" % len(files))
    return 1 if problems else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--manifest", default=os.path.join(HERE, "checks-manifest.tsv"))
    ap.add_argument("--exempt", default=os.path.join(HERE, "checks-inventory-exempt.tsv"))
    ap.add_argument("--root", default=ROOT)
    ap.add_argument("--summary")
    ap.add_argument("--only", default="")
    ap.add_argument("--lanes", default="")
    ap.add_argument("--windowed", action="store_true")
    ap.add_argument("--today", help="YYYY-MM-DD (tests)")
    ap.add_argument("--known", default=os.path.join(HERE, "checks-known-failures.tsv"))
    ap.add_argument("--logs", help="folder of the steps' logs (default: SUMMARY's folder)")
    ap.add_argument("--skip-regex", action="store_true")
    ap.add_argument("--inventory", action="store_true")
    ap.add_argument("--dryrun")
    ap.add_argument("--lanes-regex")
    ap.add_argument("--list-lanes", action="store_true")
    ap.add_argument("--timeouts", action="store_true")
    ap.add_argument("--tier", default="", help="smoke | change | rc | nightly (default rc)")
    ap.add_argument("--select-regex", action="store_true")
    ap.add_argument("--plan", action="store_true")
    ap.add_argument("--solo", default="", help="--plan: steps that get a worker of their own")
    a = ap.parse_args()
    rows = load_manifest(a.manifest)
    known = load_known(a.known, rows)
    if a.skip_regex:
        names = sorted(s for s, r in rows.items() if r["needs"] == "window")
        print("^(%s)$" % "|".join(re.escape(n) for n in names) if names else "^$")
        return 0
    if a.list_lanes:
        print("\n".join(all_lanes(rows)))
        return 0
    if a.timeouts:
        for s in sorted(rows):
            if rows[s].get("timeout"):
                print("%s\t%s" % (s, rows[s]["timeout"]))
        return 0
    if a.lanes_regex is not None:
        lanes = lane_set(a.lanes_regex, rows)
        if not lanes:
            die("--lanes-regex needs at least one lane")
        print(step_regex([s for s, r in rows.items() if selected(r, "", lanes, a.tier or "nightly")]))
        return 0
    if a.select_regex:
        lanes = lane_set(a.lanes, rows)
        print(step_regex([s for s, r in rows.items() if selected(r, "", lanes, check_tier(a.tier))]))
        return 0
    if a.plan:
        return plan(rows, a.only, lane_set(a.lanes, rows), check_tier(a.tier), a.solo)
    if a.summary:
        return verify_summary(a, rows, known)
    if a.dryrun:
        return verify_dryrun(a, rows)
    if a.inventory:
        return verify_inventory(a, rows)
    ap.error("one of --summary, --dryrun, --inventory, --lanes-regex, --select-regex, --plan, --skip-regex, --list-lanes, --timeouts")


if __name__ == "__main__":
    sys.exit(main())
