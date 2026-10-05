#!/usr/bin/env python3
"""claude/dayeval-1005: scores Today-card day reviews (DayReview.assemble) against a rubric.

Input: card files as written by scripts/day-review-eval-checks.swift (synthetic personas) or by a private replay tool
(real days, kept outside the repo), plus a references file naming each day's projects, the detail a good line gives,
and the people texted. Output: scores only, never a line of a card (cards may hold real titles and names).

Rubric (each 0..1; the composite is out of 100):
  coverage    25  the day's main projects by real effort are on the card (reference aliases, effort-weighted)
  detail      10  a covered project's line says which part of it (reference detail words)
  specific    10  share of work and browsing lines with a concrete detail: a clause, a link, a named piece of work,
                  a result, a document or page name (a line that only names an app or a site is not)
  nofiller    15  1 - share of filler lines ("Used Claude", "Read posts on X", "Read example.com", "Worked on Texts")
  order       10  work, then browsing, then conversations; at most one conversation line once there is anything else
  privacy     10  no quote on a conversation line, no phone number, no raw id on the card
  texting     10  one texting line (0.5) that names the people texted most (0.5, reference people, top three)
  concise      5  at most 7 lines and at most 14 words a line
  clickable    5  every line carries the moments it came from
Faithfulness is checked with the card, not scored: a line's moments must belong to its own thread (`unbacked`).
Stability (snapshots through the day): `churn`, the mean share of lines that change from one snapshot to the next while
the day goes on, and `flips`, how often the first line's thread changes.
Left off (snapshots): `leftoff_hit`, how often the next piece of work after a break of 30 minutes or more is the
thread the left-off guess named (`last`: the last work moment's thread; `top`: the top work thread; `line`: the card's
own line when it shows one).

usage: day-review-eval.py --cards DIR --refs FILE [--split tune|held|all] [--self NAME ...] [--min SCORE] [--json OUT]
"""
import argparse, glob, json, os, re, statistics, sys

FILLER = [
    re.compile(r"^Used [^:]+\.$"),                       # an app only opened
    re.compile(r"^Read posts on [^:]+\.$"),              # a feed only read
    re.compile(r"^(Read|Watched|Searched) [^ ]+\.$"),     # a site with no page: "Read example.com."
    re.compile(r"^Worked on (Texts|Messages|Chat)\b"),    # a conversation said as work
    re.compile(r"^Read texts\.$"),
]
PHONE = re.compile(r"\+?\d[\d\s().-]{6,}\d")
RAW_ID = re.compile(r"activity_[0-9a-f]{6,}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-|\b[0-9a-f]{24,}\b")
CATEGORY_ORDER = {"work": 0, "leftoff": 0, "browsing": 1, "personal": 2}
GENERIC = {"in", "on", "at", "the", "a", "an", "of", "for", "to", "about", "with", "and", "from"}
OUTCOME = {"Submitted", "Signed", "Ordered", "Paid", "Booked", "Registered", "Deployed", "Published", "Merged", "Shipped", "Fixed", "Sent",
           "Released", "Finished", "Completed", "Applied", "Filed"}


def words(s):
    return re.findall(r"[a-z0-9]+", s.lower())


def filler(b):
    return any(p.search(b["text"]) for p in FILLER)


def specific(b, apps):
    """A concrete detail beyond the app or site: a clause, a link, a result, or a named piece of work."""
    if b.get("clause") or b.get("link"):
        return 1.0
    lead = b["lead"].rstrip(":")
    if lead.split(" ")[0] in OUTCOME:
        return 1.0
    rest = b.get("rest") or ""
    named = [w for w in words(lead + " " + rest) if w not in GENERIC and w not in apps]
    verbs = {"asked", "worked", "read", "used", "wrote", "watched", "searched", "joined", "texted", "emailed", "told", "replied", "posted",
             "left", "off", "commented", "messaged", "document", "texts", "posts", "people", "others", "someone"}
    named = [w for w in named if w not in verbs]
    if named:
        return 1.0
    return 0.5 if b.get("quote") else 0.0


def score_card(snap, ref, self_names):
    bullets = snap["bullets"]
    threads = {t["key"]: t for t in snap["threads"]}
    apps = set()
    for t in snap["threads"]:
        if t["kind"] in ("ai", "app"):
            apps.update(words(t["name"]))
    apps.update({"claude", "chatgpt", "code", "ghostty", "terminal", "chrome", "google", "safari", "textedit", "messages", "codex", "x",
                 "youtube", "reddit"})
    n = len(bullets)
    res = {"lines": n}
    texts = [b["text"].lower() for b in bullets]
    nonpersonal = [b for b in bullets if b["category"] != "personal"]

    # Coverage and detail (reference projects, effort-weighted).
    cov = det = wsum = dsum = 0.0
    for p in ref.get("projects", []):
        w = p["weight"]
        wsum += w
        lines = [b for b in nonpersonal if any(a in b["text"].lower() or a in b["thread"].lower() for a in p["aliases"])]
        if lines:
            cov += w
            if p.get("detail"):
                dsum += w
                if any(any(d in b["text"].lower() for d in p["detail"]) for b in lines):
                    det += w
        elif p.get("detail"):
            dsum += w
    res["coverage"] = cov / wsum if wsum else 1.0
    res["detail"] = det / dsum if dsum else 1.0

    # Specificity, filler.
    sp = [specific(b, apps) for b in nonpersonal if b["category"] != "leftoff"]
    res["specific"] = statistics.mean(sp) if sp else 0.0
    fill = [filler(b) for b in bullets]
    # The owner's own account name as a project ("Worked on Jamielin").
    for i, b in enumerate(bullets):
        if any(s and s in words(b["lead"]) for s in self_names):
            fill[i] = True
    res["filler"] = sum(fill)
    res["nofiller"] = 1 - (sum(fill) / n if n else 0)

    # Order: categories never go back; one conversation line once there's anything else.
    cats = [CATEGORY_ORDER.get(b["category"], 1) for b in bullets]
    violations = sum(1 for a, b in zip(cats, cats[1:]) if b < a)
    personal = [b for b in bullets if b["category"] == "personal"]
    if nonpersonal and len(personal) > 1:
        violations += len(personal) - 1
    res["order"] = 1.0 if violations == 0 else max(0.0, 1 - 0.5 * violations)

    # Privacy.
    leaks = sum(1 for b in personal if b.get("quote")) + sum(1 for t in texts if PHONE.search(t)) + sum(1 for t in texts if RAW_ID.search(t))
    res["privacy_leaks"] = leaks
    res["privacy"] = 1.0 if leaks == 0 else 0.0

    # Texting: one line that names the people texted most.
    people = ref.get("people", [])[:3]
    merged = 1.0 if len(personal) <= 1 else 0.0
    if people:
        named = sum(1 for p in people if any(p.lower() in t for t in [b["text"].lower() for b in personal]))
        res["people"] = named / len(people)
        res["texting"] = 0.5 * merged + 0.5 * res["people"]
    else:
        res["people"] = 1.0
        res["texting"] = 0.5 * merged + 0.5
    # Concision, clickability, faithfulness (moments of the line's own thread).
    wl = [len(t.split()) for t in [b["text"] for b in bullets]]
    res["concise"] = (1.0 if n <= 7 else 0.0) * 0.5 + (1.0 if (max(wl) if wl else 0) <= 14 else 0.5) * 0.5
    res["clickable"] = sum(1 for b in bullets if b.get("moments")) / n if n else 1.0
    unbacked = 0
    for b in bullets:
        t = threads.get(b["thread"])
        if not b.get("moments"):
            unbacked += 1
    res["unbacked"] = unbacked
    res["echo"] = sum(1 for b in bullets if re.search(r"^(asked|used) (\w[\w ]*) about \2\b", b["text"].lower())
                      or re.search(r"^told ([\w ]+) about texts with \1", b["text"].lower()))
    res["score"] = round(100 * (0.25 * res["coverage"] + 0.10 * res["detail"] + 0.10 * res["specific"] + 0.15 * res["nofiller"]
                                + 0.10 * res["order"] + 0.10 * res["privacy"] + 0.10 * res["texting"] + 0.05 * res["concise"]
                                + 0.05 * res["clickable"]), 1)
    return res


def stability(snaps):
    """Churn while the day goes on: snapshots in order, the final (24:00) left out, empty cards left out."""
    seq = [s for s in snaps if s["at"] != "24:00" and s["bullets"]]
    churn, flips = [], 0
    for a, b in zip(seq, seq[1:]):
        ta, tb = set(x["text"] for x in a["bullets"]), set(x["text"] for x in b["bullets"])
        churn.append(1 - len(ta & tb) / len(ta | tb))
        if a["bullets"][0]["thread"] != b["bullets"][0]["thread"]:
            flips += 1
    return (statistics.mean(churn) if churn else 0.0), flips, len(seq)


def leftoff(snaps):
    out = {"last": [0, 0], "top": [0, 0], "line": [0, 0]}
    for s in snaps:
        if s["at"] == "24:00":
            continue
        info = s.get("leftOff") or {}
        if "next" not in info or info.get("gap", 0) < 1800:
            continue
        for k in out:
            if k in info:
                out[k][1] += 1
                out[k][0] += 1 if info[k] == info["next"] else 0
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cards", required=True)
    ap.add_argument("--refs", required=True)
    ap.add_argument("--split", default="all")
    ap.add_argument("--machine", default="")
    ap.add_argument("--self", nargs="*", default=[])
    ap.add_argument("--min", type=float, default=None, help="fail (exit 1) when the mean composite is under this")
    ap.add_argument("--require", nargs="*", default=[], help="metric=value floors on the mean, e.g. privacy=1 nofiller=0.8")
    ap.add_argument("--json", default=None)
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()
    refs = json.load(open(a.refs))
    self_names = [w for s in a.self for w in words(s)]
    rows = {}
    for path in sorted(glob.glob(os.path.join(a.cards, "*.json"))):
        day = os.path.basename(path)[:-5]
        ref = refs.get(day)
        if ref is None or (a.split != "all" and ref.get("split") != a.split) or (a.machine and not day.startswith(a.machine)):
            continue
        card = json.load(open(path))
        final = [s for s in card["snapshots"] if s["at"] == "24:00"] or card["snapshots"][:1]
        r = score_card(final[0], ref, self_names)
        r["churn"], r["flips"], r["snapshots"] = stability(card["snapshots"])
        r["leftoff"] = leftoff(card["snapshots"])
        rows[day] = r
    if not rows:
        print("no cards matched"); sys.exit(2)
    keys = ["score", "coverage", "detail", "specific", "nofiller", "order", "privacy", "texting", "people", "concise", "clickable", "lines", "filler",
            "privacy_leaks", "echo", "unbacked", "churn", "flips"]
    if not a.quiet:
        print("%-22s " % "day" + " ".join("%8s" % k[:8] for k in keys))
        for day, r in rows.items():
            print("%-22s " % day[:22] + " ".join("%8s" % (("%.2f" % r[k]) if isinstance(r[k], float) else r[k]) for k in keys))
    mean = {k: statistics.mean(r[k] for r in rows.values()) for k in keys}
    lo = {k: [sum(r["leftoff"][k][0] for r in rows.values()), sum(r["leftoff"][k][1] for r in rows.values())] for k in ("last", "top", "line")}
    print("%-22s " % ("MEAN (%d days)" % len(rows)) + " ".join("%8.2f" % mean[k] for k in keys))
    print("leftoff_hit " + " ".join("%s=%d/%d" % (k, v[0], v[1]) for k, v in lo.items()))
    if a.json:
        json.dump({"days": rows, "mean": mean, "leftoff": lo}, open(a.json, "w"), indent=1)
    failed = []
    if a.min is not None and mean["score"] < a.min:
        failed.append("score %.1f < %.1f" % (mean["score"], a.min))
    for req in a.require:
        k, v = req.split("=")
        if mean[k] < float(v):
            failed.append("%s %.2f < %s" % (k, mean[k], v))
    if failed:
        print("FAIL " + "; ".join(failed)); sys.exit(1)
    print("PASS day-review-eval")


if __name__ == "__main__":
    main()
