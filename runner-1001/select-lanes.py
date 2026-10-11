#!/usr/bin/env python3
"""Path selection: the manifest steps a change touches, from the paths it changes.

  select-lanes.py [--base B --head H | --paths P...] [--tier T] [--format env|text|json]
  select-lanes.py --self-test

Every changed path (git diff --name-only B..H, or --paths) is matched against scripts/checks-paths.tsv
(glob, targets, reason). A glob with a "/" matches the whole path ("*" stays inside one folder, "**" crosses folders);
one without matches the file name at any depth; a leading "/" anchors a file name at the repo root. Every matching rule counts. Targets (comma-separated):

  lane:NAME   every row of that lane (lane:* every lane)       step:GLOB   the rows whose step matches
  config:C    every row of that config (owner, public, ...)    own         the rows whose `file` matches the path
  uses        the rows whose runner command (DRYRUN) names the path (an app file: every APP-recipe step, through the
              app-shared copy), or whose check file, or a scripts/ helper it loads, names the path or its file name
  all         the full rc tier                                 none        nothing (the path is known not to matter)

A path that selects no row (no rule, or rules that name nothing) is unmatched: the whole run falls back to the full rc
tier (TIER is raised to rc and no step filter is set). The builds are always selected. TIER still applies on top: a
selected step of a higher tier does not run (select-lanes picks WHAT a change touches, the tier HOW DEEP to go).

--format env prints TIER=, ONLY= (the step regex; empty = no filter) and LANES= lines, plus "# path -> ..." reasons.
"""
import argparse, fnmatch, glob, importlib.util, json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def load_verifier(root):
    spec = importlib.util.spec_from_file_location("verify_run_manifest", os.path.join(root, "scripts", "verify-run-manifest.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def glob_re(pattern):
    """A path glob as a regex: ** crosses folders, * and ? stay inside one."""
    out, i = "", 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out += "(?:.*/)?"; i += 3
        elif pattern.startswith("**", i):
            out += ".*"; i += 2
        elif pattern[i] == "*":
            out += "[^/]*"; i += 1
        elif pattern[i] == "?":
            out += "[^/]"; i += 1
        else:
            out += re.escape(pattern[i]); i += 1
    return re.compile("^" + out + "$")


def path_matches(pattern, path):
    if pattern.startswith("/"):  # anchored at the repo root (like .gitignore)
        return bool(glob_re(pattern[1:]).match(path))
    if "/" in pattern:
        return bool(glob_re(pattern).match(path))
    return bool(glob_re(pattern).match(os.path.basename(path)))


def load_rules(path):
    rules = []
    for n, line in enumerate(open(path), 1):
        line = line.rstrip("\n")
        if not line.strip() or line.startswith("#"):
            continue
        cells = line.split("\t")
        if cells[0] == "glob":
            continue
        if len(cells) != 3 or not cells[0] or not cells[1]:
            sys.exit("select-lanes: %s line %d: want glob<TAB>targets<TAB>reason" % (path, n))
        targets = [t.strip() for t in cells[1].split(",") if t.strip()]
        for t in targets:
            if not (t in ("own", "uses", "all", "none") or re.match(r"^(lane|step|config):\S+$", t)):
                sys.exit("select-lanes: %s line %d: unknown target %r" % (path, n, t))
        rules.append((cells[0], targets, cells[2]))
    return rules


def dryrun_commands(root):
    """{step: command} from the runner's DRYRUN listing (run-checks.sh with TIER=nightly: every step)."""
    with tempfile.TemporaryDirectory(dir=os.environ.get("SELECT_LANES_TMP")) as d:
        env = dict(os.environ, DRYRUN="1", TIER="nightly", SRC=root, WORKDIR=d)
        for k in ("ONLY", "LANES", "PREBUILT", "BASE"):
            env.pop(k, None)
        subprocess.run(["bash", os.path.join(root, "runner-1001", "run-checks.sh"), "sel"], cwd=root, env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        f = os.path.join(d, "out-sel", "DRYRUN-steps.tsv")
        cmds = {}
        for line in open(f) if os.path.exists(f) else []:
            name, _, cmd = line.rstrip("\n").partition("\t")
            cmds[name] = cmds.get(name, "") + " " + cmd
        return cmds


class Selector:
    def __init__(self, root, rows, rules, cmds):
        self.root, self.rows, self.rules, self.cmds = root, rows, rules, cmds
        self.always = [s for s in rows if s in self.verifier_always()]
        self._texts = {}
        # A file name counts as naming the file only when no other tracked file has it (README.md, main.swift don't).
        names = {}
        for p in subprocess.run(["git", "-C", root, "ls-files"], capture_output=True, text=True).stdout.split():
            names[os.path.basename(p)] = names.get(os.path.basename(p), 0) + 1
        self.unique_names = {n for n, k in names.items() if k == 1}

    @staticmethod
    def verifier_always():
        return {"build", "owner-build", "app-module", "owner-app-module"}

    def row_files(self, step):
        out = []
        for pat in self.rows[step]["file"].split(","):
            if pat and pat != "-":
                out += [os.path.relpath(f, self.root) for f in glob.glob(os.path.join(self.root, pat), recursive=True) if os.path.isfile(f)]
        return out

    def text(self, rel):
        """A check file's text plus the scripts/ helpers it names or imports (one level)."""
        if rel in self._texts:
            return self._texts[rel]
        try:
            t = open(os.path.join(self.root, rel), errors="replace").read()
        except OSError:
            t = ""
        extra = []
        for name in set(re.findall(r"(?:^|\s)(?:from|import)\s+([A-Za-z_][A-Za-z0-9_]*)", t)) | set(re.findall(r"scripts/([A-Za-z0-9_.-]+\.py)", t)):
            for cand in (os.path.join(self.root, "scripts", name + ".py"), os.path.join(self.root, "scripts", name)):
                if os.path.isfile(cand) and os.path.relpath(cand, self.root) != rel:
                    try:
                        extra.append(open(cand, errors="replace").read())
                    except OSError:
                        pass
                    break
        self._texts[rel] = t + "\n".join(extra)
        return self._texts[rel]

    def own(self, path):
        hit = set()
        for s, r in self.rows.items():
            for pat in r["file"].split(","):
                if pat and pat != "-" and (pat == path or fnmatch.fnmatchcase(path, pat)):
                    hit.add(s)
        return hit

    def uses(self, path):
        hit = set()
        base = os.path.basename(path)
        app = bool(re.match(r"^Sources/MacMemApp/[^/]+\.swift$", path))
        for s in self.rows:
            cmd = self.cmds.get(s, "") + self.cmds.get("compile-" + s, "")
            if path in cmd or (app and ("app-shared" in cmd or "app_link" in cmd or "app_module" in cmd)):
                hit.add(s); continue
            for f in self.row_files(s):
                t = self.text(f)
                if path in t or (base in self.unique_names and len(base) >= 8 and "." in base and base in t):
                    hit.add(s); break
        return hit

    def target(self, t, path):
        if t == "own":
            return self.own(path)
        if t == "uses":
            return self.uses(path)
        if t == "none":
            return set()
        kind, _, val = t.partition(":")
        if kind == "lane":
            return {s for s, r in self.rows.items() if val == "*" or r["lane"] == val}
        if kind == "config":
            return {s for s, r in self.rows.items() if r["config"] == val}
        if kind == "step":
            return {s for s in self.rows if fnmatch.fnmatchcase(s, val)}
        raise ValueError(t)

    def select_path(self, path):
        """(steps, matched, reasons) for one path; `all` in targets -> steps is None."""
        steps, matched, reasons = set(), False, []
        for pat, targets, why in self.rules:
            if not path_matches(pat, path):
                continue
            if "all" in targets:
                return None, True, ["%s: all (%s)" % (pat, why)]
            got = set()
            for t in targets:
                got |= self.target(t, path)
            if got or "none" in targets:
                matched = True
                steps |= got
                reasons.append("%s: %d steps (%s)" % (pat, len(got), why))
        return steps, matched, reasons

    def select(self, paths, tier):
        steps, notes, fallback = set(), [], False
        for p in paths:
            got, matched, reasons = self.select_path(p)
            if got is None:
                fallback = True; notes.append("%s -> full rc tier: %s" % (p, "; ".join(reasons)))
            elif not matched:
                fallback = True; notes.append("%s -> unmatched: full rc tier" % p)
            else:
                steps |= got; notes.append("%s -> %s" % (p, "; ".join(reasons) or "nothing"))
        tiers = ["smoke", "change", "rc", "nightly"]
        if fallback:
            return {"tier": tiers[max(tiers.index(tier), tiers.index("rc"))], "steps": None, "lanes": [], "notes": notes}
        steps |= set(self.always)
        lanes = sorted({self.rows[s]["lane"] for s in steps})
        # Steps the change touches that this tier does not run (owner-writer-cadence, the guard of the writer wake bug,
        # is rc): named, so a change run never looks as if it covered them.
        held = sorted(s for s in steps if tiers.index(self.rows[s].get("tier") or "rc") > tiers.index(tier))
        if held:
            notes.append("held back by TIER=%s (they run at a higher tier): %s" % (tier, " ".join(
                "%s(%s)" % (s, self.rows[s].get("tier") or "rc") for s in held)))
        return {"tier": tier, "steps": sorted(steps), "lanes": lanes, "notes": notes, "held": held}


def changed_paths(root, base, head):
    out = subprocess.run(["git", "-C", root, "diff", "--name-only", "%s..%s" % (base, head)], capture_output=True, text=True, check=True).stdout
    return [l for l in out.splitlines() if l.strip()]


def step_regex(steps):
    return "^(compile-)?(%s)$" % "|".join(re.escape(s) for s in sorted(steps))


def make(root, rules_path=None, cmds=None):
    v = load_verifier(root)
    rows = v.load_manifest(os.path.join(root, "scripts", "checks-manifest.tsv"))
    rules = load_rules(rules_path or os.path.join(root, "scripts", "checks-paths.tsv"))
    # A lane: target names a lane of the manifest (or lane:*): a typo would silently select nothing for its paths.
    lanes = {r["lane"] for r in rows.values()}
    for glob_, targets, _ in rules:
        for t in targets:
            if t.startswith("lane:") and t[5:] != "*" and t[5:] not in lanes:
                sys.exit("select-lanes: rule %s names lane %r, which is not a lane (%s)" % (glob_, t[5:], ",".join(sorted(lanes))))
    return Selector(root, rows, rules, dryrun_commands(root) if cmds is None else cmds)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base"); ap.add_argument("--head", default="HEAD")
    ap.add_argument("--paths", nargs="*")
    ap.add_argument("--tier", default="change")
    ap.add_argument("--format", default="text", choices=["env", "text", "json"])
    ap.add_argument("--root", default=ROOT)
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        return self_test(a.root)
    if a.tier not in ("smoke", "change", "rc", "nightly"):
        sys.exit("select-lanes: unknown tier %r" % a.tier)
    paths = a.paths if a.paths is not None else changed_paths(a.root, a.base, a.head) if a.base else None
    if paths is None:
        ap.error("--base or --paths")
    sel = make(a.root).select(paths, a.tier) if paths else {"tier": a.tier, "steps": [], "lanes": [], "notes": ["no changed path"]}
    if paths and sel["steps"] == []:
        sel["notes"].append("nothing selected")
    if a.format == "json":
        print(json.dumps(sel, indent=1))
    elif a.format == "env":
        for n in sel["notes"]:
            print("# " + n)
        print("TIER=%s" % sel["tier"])
        print("ONLY=%s" % ("" if sel["steps"] is None else step_regex(sel["steps"]) if sel["steps"] else "^$"))
        print("LANES=%s" % ",".join(sel["lanes"]))
    else:
        for n in sel["notes"]:
            print(n)
        print("tier %s: %s" % (sel["tier"], "every step (no filter)" if sel["steps"] is None else "%d steps in %s" % (len(sel["steps"]), ",".join(sel["lanes"]))))
    return 0


# ---- self-test -------------------------------------------------------------------------------------------------------
def self_test(root):
    fails = 0

    def case(label, ok, detail=""):
        nonlocal fails
        print(("PASS " if ok else "FAIL ") + label + ("" if ok else ": " + str(detail)[:400]))
        fails += 0 if ok else 1

    # Toy cases: the rule language on a made-up manifest (no runner).
    toy_rows = {s: {"step": s, "lane": l, "config": c, "file": f, "tier": t} for s, l, c, f, t in [
        ("build", "smoke", "public-contract", "-", "smoke"), ("owner-build", "smoke", "owner", "-", "smoke"),
        ("alpha", "capture", "owner", "scripts/alpha-checks.swift", "change"),
        ("beta", "ai-tools", "public", "scripts/beta-checks.swift", "change"),
        ("gamma", "release", "n/a", "scripts/gamma-checks.py", "smoke")]}
    toy_rules = [("scripts/*-checks.*", ["own"], "a check file: its rows"), ("WriterBackend/**", ["lane:ai-tools"], "writer"),
                 ("*.md", ["step:gamma"], "docs"), ("LICENSE", ["none"], "nothing reads it"), ("Package.swift", ["all"], "everything"),
                 ("Sources/Foo/*", ["lane:capture", "config:public"], "foo")]
    t = Selector(root, toy_rows, toy_rules, {})
    r = t.select(["scripts/alpha-checks.swift"], "change")
    case("toy: a check file selects its own row (and the builds)", r["steps"] == ["alpha", "build", "owner-build"], r)
    r = t.select(["WriterBackend/Sources/WriterBackend/X.swift"], "change")
    case("toy: ** crosses folders (WriterBackend/** -> lane ai-tools)", r["steps"] == ["beta", "build", "owner-build"], r)
    r = t.select(["docs/sub/page.md"], "change")
    case("toy: a slash-less glob matches the file name at any depth", r["steps"] == ["build", "gamma", "owner-build"], r)
    r = t.select(["Sources/Foo/a/b.swift"], "change")
    case("toy: * stays inside one folder (Sources/Foo/a/b.swift is unmatched: rc fallback)", r["steps"] is None and r["tier"] == "rc", r)
    r = t.select(["Sources/Foo/b.swift"], "change")
    case("toy: lane: and config: targets union", r["steps"] == ["alpha", "beta", "build", "owner-build"], r)
    r = t.select(["LICENSE"], "smoke")
    case("toy: `none` matches and selects nothing (only the builds)", r["steps"] == ["build", "owner-build"] and r["tier"] == "smoke", r)
    r = t.select(["Package.swift", "scripts/alpha-checks.swift"], "change")
    case("toy: `all` is the full rc tier", r["steps"] is None and r["tier"] == "rc", r)
    r = t.select(["nowhere/at/all.txt"], "smoke")
    case("toy: an unmatched path raises the tier to rc with no filter", r["steps"] is None and r["tier"] == "rc", r)
    r = t.select(["nowhere/at/all.txt"], "nightly")
    case("toy: the fallback never lowers a nightly run", r["tier"] == "nightly", r)
    r = t.select(["scripts/zeta-checks.swift"], "change")
    case("toy: a rule whose targets name no row leaves the path unmatched (rc fallback)", r["steps"] is None, r)
    case("toy: the step regex keeps compile-X with X", re.match(step_regex(["alpha"]), "compile-alpha") is not None
         and re.match(step_regex(["alpha"]), "alphabet") is None)

    # The real tree: scripts/checks-paths.tsv over scripts/checks-manifest.tsv (and its fragments).
    sel = make(root)
    rows = sel.rows
    case("checks-paths.tsv loads (%d rules) and the runner's DRYRUN lists %d commands" % (len(sel.rules), len(sel.cmds)),
         len(sel.rules) > 10 and len(sel.cmds) > 200, (len(sel.rules), len(sel.cmds)))
    tracked = subprocess.run(["git", "-C", root, "ls-files"], capture_output=True, text=True).stdout.split()
    reach, unmatched = set(), []
    for p in tracked:
        got, matched, _ = sel.select_path(p)
        if got is None:
            reach |= set(rows)
        elif matched:
            reach |= got
        else:
            unmatched.append(p)
    missing = sorted(set(rows) - reach - set(sel.always))
    case("every manifest row is reachable from a path rule (%d rows, %d tracked files)" % (len(rows), len(tracked)), not missing, missing)

    def lanes_of(r):
        return {rows[s]["lane"] for s in r["steps"] or []}
    r = sel.select(["Sources/MacMemApp/MenuBarContent.swift"], "change")
    owner = [s for s in r["steps"] or [] if s.startswith("owner-")]
    case("Sources/MacMemApp/* gives setup-ui + capture + owner steps (%d steps)" % len(r["steps"] or []),
         r["steps"] is not None and {"setup-ui", "capture"} <= lanes_of(r) and len(owner) >= 10, r["notes"])
    case("an app file selects every APP-recipe step (through the module): owner-lifecycle-model, recording-model, connection-review",
         r["steps"] is not None and {"owner-lifecycle-model", "recording-model", "connection-review"} <= set(r["steps"]), r["notes"])
    w = sel.select(["Sources/MacMemApp/WriterScheduling.swift"], "change")
    case("a writer app file also selects the writer steps that compile it (owner-writer-cadence, notes-golden)",
         w["steps"] is not None and {"owner-writer-cadence", "notes-golden"} <= set(w["steps"]), w["notes"])
    case("a selected step above the tier is named as held back (owner-writer-cadence is rc; a change run skips it)",
         "owner-writer-cadence" in w.get("held", []) and any("held back by TIER=change" in n and "owner-writer-cadence(rc)" in n for n in w["notes"])
         and "notes-golden" not in w.get("held", []), w["notes"])
    r = sel.select(["WriterBackend/Sources/WriterBackend/LocalWriter.swift"], "change")
    case("WriterBackend/** gives ai-tools", r["steps"] is not None and "ai-tools" in lanes_of(r)
         and {s for s in rows if rows[s]["lane"] == "ai-tools"} <= set(r["steps"]), r["notes"])
    docs = {"docs-claims-py", "docs-dmg-background", "docs-install-render"}
    for p in ("docs/images/setup-permissions.png", "docs/faq.md", "CONTRIBUTING.md", "SECURITY.md", "WriterBackend/PROVENANCE.md"):
        r = sel.select([p], "change")
        want = docs | ({s for s in rows if rows[s]["lane"] == "ai-tools"} if p.startswith("WriterBackend/") else set())
        case("%s gives the release docs steps only%s" % (p, " (and its package's lane)" if p.startswith("WriterBackend/") else ""),
             r["steps"] is not None and set(r["steps"]) - sel.verifier_always() == want, r["notes"])
    r = sel.select(["no/such/place/at-all.bin"], "change")
    case("an unknown path gives the full rc tier", r["steps"] is None and r["tier"] == "rc", r["notes"])
    r = sel.select(["Package.swift"], "smoke")
    case("Package.swift gives the full rc tier", r["steps"] is None and r["tier"] == "rc", r["notes"])
    r = sel.select(["scripts/skipped-app-id-checks.swift"], "change")
    case("a check file gives its own step (skipped-app-id)", r["steps"] is not None and "skipped-app-id" in r["steps"], r["notes"])
    r = sel.select(["scripts/store-perf-checks.swift"], "change")
    case("a shared check file gives both of its steps (store-perf, owner-store-perf)",
         r["steps"] is not None and {"store-perf", "owner-store-perf"} <= set(r["steps"]), r["notes"])
    r = sel.select(["BrowserBridge/Sources/BrowserBridge/Relay.swift"], "change")
    case("BrowserBridge/** gives capture", r["steps"] is not None and "capture" in lanes_of(r) and "bb-package-build" in r["steps"], r["notes"])
    r = sel.select(["Sources/MemoryCore/Store.swift"], "change")
    case("Sources/MemoryCore/** gives every lane", r["steps"] is not None and lanes_of(r) >= {s["lane"] for s in rows.values()}, r["notes"])
    r = sel.select(["runner-1001/run-checks.sh"], "change")
    case("the runner itself gives the full rc tier", r["steps"] is None and r["tier"] == "rc", r["notes"])
    r = sel.select(["scripts/checks-manifest.tsv"], "change")
    case("the manifest gives the smoke lane's manifest steps", r["steps"] is not None and "manifest-dryrun" in r["steps"], r["notes"])
    r = sel.select(["packaging/Info.plist"], "change")
    case("packaging/** gives the release lane", r["steps"] is not None and "release" in lanes_of(r) and "packaging-py" in r["steps"], r["notes"])
    r = sel.select(["RELEASE.md"], "change")
    case("RELEASE.md also gives the release checks that read it (developer-id-release-py)",
         r["steps"] is not None and docs <= set(r["steps"]) and "developer-id-release-py" in r["steps"], r["notes"])
    r = sel.select(["Checks/AgentToolsChecks.swift"], "change")
    case("Checks/** gives owner-MacMemChecks and the agent-tools evals", r["steps"] is not None
         and {"owner-MacMemChecks", "agent-tools-evals-py"} <= set(r["steps"]), r["notes"])
    r = sel.select(["Sources/MacMemApp/MenuBarContent.swift", "WriterBackend/Package.swift"], "change")
    case("two paths union their steps", r["steps"] is not None and {"setup-ui", "capture", "ai-tools"} <= lanes_of(r), r["notes"])
    r = sel.select(["Sources/MacMemApp/MenuBarContent.swift"], "change")
    case("the builds (and the app modules) are always selected", r["steps"] is not None and sel.verifier_always() & set(rows) <= set(r["steps"]), r)
    if fails:
        print("%d failed" % fails)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
