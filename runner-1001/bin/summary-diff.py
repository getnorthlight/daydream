#!/usr/bin/env python3
"""usage: summary-diff.py OLD NEW [--moved REGEX]
Step by step, a run's SUMMARY against an earlier one (each argument: a SUMMARY file, or a folder whose */out-*/SUMMARY
and out/SUMMARY files are read together, as runner-1001/lanes.sh leaves them; a step in several of them counts once,
with its best line). Exit 1 when a step of OLD is missing from NEW (LOST; --moved names steps another tier runs now,
reported as MOVED), a step that passed now exits non-zero (WORSE), or a step prints fewer PASS lines (LOWER)."""
import argparse, glob, os, re, sys


def load(arg):
    files = [arg] if os.path.isfile(arg) else sorted(set(glob.glob(os.path.join(arg, "*", "out-*", "SUMMARY")) + glob.glob(os.path.join(arg, "out", "SUMMARY"))))
    if not files:
        sys.exit("summary-diff: no SUMMARY in %s" % arg)
    steps = {}
    for f in files:
        for line in open(f):
            m = re.match(r"^(\S+) exit=(-?\d+) pass=(\d+)$", line.strip())
            if m:
                cur = (int(m.group(2)), int(m.group(3)))
            elif re.match(r"^(\S+) SKIPPED-UI$", line.strip()):
                cur = ("SKIPPED-UI", 0)
            else:
                continue
            name = line.split()[0]
            old = steps.get(name)
            if old is None or (cur[0] == 0 and (old[0] != 0 or cur[1] > old[1])):
                steps[name] = cur
    return steps


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("old"); ap.add_argument("new")
    ap.add_argument("--moved", default="", help="regex of steps that now run in another tier (reported, not LOST)")
    a = ap.parse_args()
    old, new = load(a.old), load(a.new)
    bad = 0
    out = {"LOST": [], "MOVED": [], "WORSE": [], "LOWER": [], "ADDED": [], "SAME": [], "HIGHER": [], "BETTER": []}
    for s, (rc, n) in sorted(old.items()):
        if s not in new:
            if a.moved and re.search(a.moved, s):
                out["MOVED"].append(s)
            else:
                out["LOST"].append(s)
            continue
        nrc, nn = new[s]
        if rc == 0 and nrc != 0:
            out["WORSE"].append("%s: exit %s -> %s" % (s, rc, nrc))
        elif rc != 0 and nrc == 0:
            out["BETTER"].append("%s: exit %s -> 0" % (s, rc))
        elif nn < n:
            out["LOWER"].append("%s: pass %d -> %d" % (s, n, nn))
        elif nn > n:
            out["HIGHER"].append("%s: pass %d -> %d" % (s, n, nn))
        else:
            out["SAME"].append(s)
    out["ADDED"] = sorted(set(new) - set(old))
    for k in ("LOST", "WORSE", "LOWER", "MOVED", "BETTER", "HIGHER", "ADDED"):
        print("== %s (%d)" % (k, len(out[k])))
        for line in out[k]:
            print("  " + line)
    bad = len(out["LOST"]) + len(out["WORSE"]) + len(out["LOWER"])
    print("summary-diff: %d steps before, %d now: %d same, %d higher, %d added, %d moved; %d lost, %d worse, %d lower" % (
        len(old), len(new), len(out["SAME"]), len(out["HIGHER"]), len(out["ADDED"]), len(out["MOVED"]), len(out["LOST"]), len(out["WORSE"]), len(out["LOWER"])))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
