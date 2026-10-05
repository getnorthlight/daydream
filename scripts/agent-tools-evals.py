#!/usr/bin/env python3
"""AI-app tools v2 evals (docs/agent-tools/plan.md §7). Synthetic data only, in temp folders.

The eval table lives in one place, Checks/AgentToolsChecks.swift (`AgentEvals.all`); this script reads it from the built
checks binary (`MacMemChecks --agent-tools evals-list`).

Modes:
  inprocess (default)  MacMemChecks builds the synthetic week in a temp home and runs every eval in process, with the
                       fixture's own typed-words source (no app, no socket). Deterministic.
  live                 The same fixture, then `mac-mem mcp` over JSON-RPC with a temp HOME and a grant made in the temp
                       home: tools/list, the header line, budgets, and every eval's tool calls through the real server.
                       There is no DayDream app here, so typed words are unavailable: evals that need them are checked
                       for everything except the typed facts and reported "partial".
  both                 inprocess, then live.

  --llm (off by default, live only): an LLM answers each playbook question using only the four tools, through the
  same `mac-mem mcp`, and its answer is graded against the eval's answer facts. Needs the `anthropic` package and
  credentials (ANTHROPIC_API_KEY or `ant auth login`). Spends money; synthetic data only ever leaves the Mac.

Every mode reports tool calls and tokens (UTF-8 bytes / 4) per question.

Examples:
  python3 scripts/agent-tools-evals.py                      # public lane, in process
  python3 scripts/agent-tools-evals.py --owner --build      # owner lane (.build-owner), building first
  python3 scripts/agent-tools-evals.py --mode live --show P01,E03
  python3 scripts/agent-tools-evals.py --mode live --llm --only P01,P04
Exit status: 1 when an armed eval misses (its work packages are real), or with --strict when any eval misses.
"""
import argparse
import datetime as dt
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
OWNER_FLAGS = ["-Xswiftc", "-DDAYDREAM_OWNER_TYPING", "-Xswiftc", "-DDAYDREAM_CHROME_TYPING"]
FIXTURE_DAY = "2026-10-04"
FIXTURE_TZ = "America/Chicago"
ID = re.compile(r"\b\d{4}-[a-z2-7]{5,6}\b")
V2_TOOLS = ["timeline", "search", "details", "status"]
LEGACY = ["recap", "recall", "open", "read", "context", "current-context", "moment_details"]


def tokens(text):
    return len(text.encode("utf-8")) // 4


def rx(pattern, text):
    return re.search(pattern, text, re.IGNORECASE) is not None


# ---------------------------------------------------------------------------------------------------------------------
# Binaries and the fixture


def binaries(args):
    build = ROOT / (".build-owner" if args.owner else ".build") / "debug"
    checks = Path(args.checks or os.environ.get("DAYDREAM_TEST_CHECKS") or build / "MacMemChecks")
    cli = Path(args.cli or os.environ.get("DAYDREAM_TEST_CLI") or build / "mac-mem")
    if args.build:
        extra = (["--scratch-path", str(ROOT / ".build-owner")] + OWNER_FLAGS) if args.owner else []
        for product in ("MacMemChecks", "mac-mem"):
            subprocess.run(["swift", "build", "--product", product] + extra, cwd=ROOT, check=True)
    for b in (checks, cli):
        if not b.exists():
            sys.exit(f"missing {b}: build it (swift build --product {b.name}) or pass --build")
    return checks, cli


def scratch_env(base):
    home, tmp = base / "home", base / "tmp"
    home.mkdir(parents=True, exist_ok=True)
    tmp.mkdir(parents=True, exist_ok=True)
    # A test name for the "write recent notes" request, so a DayDream running on this Mac is never woken.
    return {**os.environ, "HOME": str(home), "TMPDIR": str(tmp), "TZ": FIXTURE_TZ,
            "DAYDREAM_TEST_FRESHEN_REQUEST": "com.example.agenttools-evals", "DAYDREAM_MCP_TOOLSET": "v2"}


def eval_table(checks, env):
    out = subprocess.run([str(checks), "--agent-tools", "evals-list"], cwd=ROOT, env=env, capture_output=True, text=True, check=True)
    table = json.loads(out.stdout)
    PERSON_WORDS[:] = table.get("personWords", [])
    return table


def select(table, only):
    evals = table["evals"]
    if only:
        wanted = set(only.split(","))
        evals = [e for e in evals if e["id"] in wanted]
    return evals


# ---------------------------------------------------------------------------------------------------------------------
# Shared text checks (the same rules as AgentEvalRunner in Checks/AgentToolsChecks.swift)


def unquoted(text):
    lines = []
    for line in text.split("\n"):
        i = line.find(": '")
        if i >= 0:
            line = line[:i]
        lines.append(re.sub("“[^”]*”", "", line))
    return "\n".join(lines)


PERSON_WORDS = []  # the fixture's own words that say "draft" (from evals-list), removed before that check


def own_wording(text):
    """DayDream's own wording: unquoted, without the person's known words, and without straight-quoted titles ("...")
    except a note's."""
    text = unquoted(text)
    for words in PERSON_WORDS:
        text = text.replace(words, "")
    return re.sub(r'(?<!note: )"[^"\n]*"', "", text)


def always_problems(table, texts, secrets):
    joined = "\n".join(texts)
    out = [f"always: {name}" for name, p in sorted(table["always"].items()) if rx(p, joined)]
    plain = unquoted(joined)
    out += [f"always: send-state claim /{p}/" for p in table["sendState"] if rx(p, plain)]
    own = own_wording(joined)
    out += [f"always: DayDream wording /{p}/" for p in table.get("ownWording", []) if rx(p, own)]
    out += [f"always: secret leaked ({s[:6]}…)" for s in secrets if s in joined]
    return out


def first_line(text, pattern):
    for i, line in enumerate(text.split("\n")):
        if rx(pattern, line):
            return i
    return None


def first_id(text, pattern):
    for line in text.split("\n"):
        if rx(pattern, line):
            m = ID.search(line)
            if m:
                return m.group(0)
    return None


def cursor_in(text):
    m = re.search(r"\bcursor\b\W{0,3}([A-Za-z0-9_\-.:=+/]{1,200})", text)
    return m.group(1) if m else None


def text_custom(name, outputs, typed_available, rerun):
    """Text-only versions of the named checks. Returns (problems, skipped)."""
    texts = [o["text"] for o in outputs]
    if name == "form_above_feed":
        t = next((o["text"] for o in outputs if o["tool"] == "timeline"), None)
        if t is None:
            return ["form_above_feed: no timeline reply"], False
        form = first_line(t, "Northwind Fellowship application")
        feed = first_line(t, r"\bx\.com\b|Home / X|\bfeeds?\b|\breading X\b")
        if form is None:
            return ["form_above_feed: the form is not listed"], False
        if feed is not None and feed < form:
            return [f"form_above_feed: the feed (line {feed + 1}) is above the form (line {form + 1})"], False
        return [], False
    if name == "collapsed_adds_up":
        problems = []
        for o in outputs:
            if o["tool"] != "timeline":
                continue
            for line in o["text"].split("\n"):
                m = re.search(r"Collapsed:\s*\d[\d,]* items? \([^)]*\)", line)
                if m:
                    nums = [int(n.replace(",", "")) for n in re.findall(r"\d[\d,]*", m.group(0))]
                    if len(nums) > 1 and sum(nums[1:]) != nums[0]:
                        problems.append(f'collapsed_adds_up: "{line}" parts don\'t add up to {nums[0]}')
        return problems, False
    if name == "search_total_57":
        pages = [o["text"] for o in outputs if o["tool"] == "search"]
        problems = []
        if not pages or not rx(r"\b57 items match", pages[0]):
            problems.append("search_total_57: the first page doesn't say 57 items match")
        seen = []
        for p in pages:
            seen += sorted(set(ID.findall(p)))
        if len(seen) != len(set(seen)):
            problems.append("search_total_57: duplicate items across pages")
        if len(set(seen)) != 57:
            problems.append(f"search_total_57: pages hold {len(set(seen))} distinct items, expected 57")
        if pages and cursor_in(pages[-1]):
            problems.append("search_total_57: the last page still has a cursor")
        return problems, False
    if name == "status_matches_policy":
        status = next((o["text"] for o in outputs if o["tool"] == "status"), None)
        if status is None:
            return ["status_matches_policy: no status reply"], False
        if not typed_available and not rx(r"typed words: (unavailable|off)|unavailable while DayDream is closed", status):
            return ["status_matches_policy: no DayDream app is reachable here, but status doesn't say typed words are unavailable"], False
        return [], typed_available
    if name == "status_matches_details":
        status = next((o["text"] for o in outputs if o["tool"] == "status"), None)
        details = next((o["text"] for o in reversed(outputs) if o["tool"] == "details"), None)
        if status is None or details is None:
            return ["status_matches_details: needs a status and a details reply"], False
        says = not rx(r"typed words: (off|unavailable)", status)
        quoted = rx(r": '[^'\n]+", details)
        if says != quoted:
            return [f"status_matches_details: status says typed words {'are' if says else 'are not'} shared, details {'quotes' if quoted else 'quotes no'} typed words"], False
        return [], False
    if name == "excerpt_vs_full":
        return [], True  # needs typed words
    if name == "ids_valid_stable":
        problems = []
        if not any(ID.search(t) for t in texts):
            problems.append("ids_valid_stable: no ids in the replies")
        again = rerun()
        if again != texts:
            problems.append("ids_valid_stable: the same calls twice gave different replies")
        return problems, False
    return [f"unknown custom check {name}"], False


# ---------------------------------------------------------------------------------------------------------------------
# In process


def run_inprocess(args, checks, base):
    env = scratch_env(base)
    report_path = base / "inprocess-report.json"
    cmd = [str(checks), "--agent-tools", "run", str(base / "fixture-inprocess"), "--json", str(report_path)]
    if args.only:
        cmd += ["--only", args.only]
    if args.show:
        cmd += ["--replies"]
    if args.strict:
        cmd += ["--strict"]
    started = time.time()
    proc = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True)
    if not report_path.exists():
        sys.stderr.write(proc.stdout + proc.stderr)
        sys.exit("in-process run wrote no report")
    report = json.loads(report_path.read_text())
    wps = " ".join(f"{k}={'real' if v else 'stub'}" for k, v in sorted(report["workPackages"].items()))
    print(f"\n== in process ({report['lane']} lane; work packages {wps}; {time.time() - started:.1f}s)")
    print(f"{'eval':5} {'status':16} {'calls':>5} {'max tok':>7} {'sum tok':>7}  title / first problems")
    worst = 0
    show = set((args.show or "").split(",")) if args.show else set()
    for r in report["results"]:
        toks = r.get("tokens") or []
        line = f"{r['id']:5} {r['status']:16} {r['calls']:>5} {max(toks or [0]):>7} {sum(toks):>7}  {r['title']}"
        print(line)
        for p in (r.get("problems") or [])[: (None if args.verbose else 3)]:
            print(f"{'':39}- {p}")
        if r.get("note"):
            print(f"{'':39}({r['note']})")
        if r["id"] in show or "all" in show:
            for c in r.get("replies") or []:
                print(f"--- {c['tool']} {c['args']} ({c['tokens']} tokens)\n{c['text']}\n---")
        if r["status"] == "fail" or (args.strict and r["status"] == "expected-miss"):
            worst = 1
    counts = {}
    for r in report["results"]:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    print("summary: " + ", ".join(f"{v} {k}" for k, v in sorted(counts.items())))
    return report, worst


# ---------------------------------------------------------------------------------------------------------------------
# Live: mac-mem mcp over JSON-RPC


class MCP:
    def __init__(self, cli, home, env, client="agenttools-evals", recipient="local"):
        grant = subprocess.run([str(cli), "--home", str(home), "--client", client, "--recipient", recipient, "grant"],
                               env=env, capture_output=True, text=True, check=True)
        capability = json.loads(grant.stdout)["capability"]
        self.proc = subprocess.Popen([str(cli), "--home", str(home), "--client", client, "--recipient", recipient, "mcp"],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                     env={**env, "MAC_MEM_CAPABILITY": capability})
        self.next = 0
        self.notifications = []

    def request(self, method, params=None):
        self.next += 1
        self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params or {}}) + "\n")
        self.proc.stdin.flush()
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("mac-mem mcp closed: " + self.proc.stderr.read()[-2000:])
            msg = json.loads(line)
            if "id" not in msg:
                self.notifications.append(msg)
                continue
            if msg["id"] == self.next:
                return msg

    def call(self, name, arguments):
        msg = self.request("tools/call", {"name": name, "arguments": arguments})
        if "error" in msg:
            return None, f"{name}{json.dumps(arguments, sort_keys=True)}: protocol error {msg['error']}"
        result = msg["result"]
        text = "\n".join(c.get("text", "") for c in result.get("content", []) if c.get("type") == "text")
        return text, (f"{name}: isError: {text[:200]}" if result.get("isError") else None)

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.kill()


def absolute_when(value, real_today):
    """Relative days in the eval table mean the fixture's days; rewrite them when the real clock is on another day."""
    if real_today == FIXTURE_DAY or not isinstance(value, str):
        return value
    return {"today": "2026-10-04", "yesterday": "2026-10-03", "this week": "2026-09-28 to 2026-10-04"}.get(value, value)


def set_writer(home, mode):
    with sqlite3.connect(str(home / "memory.sqlite")) as db:
        db.execute("INSERT OR REPLACE INTO metadata VALUES('summary_writer',?)",
                   (json.dumps({"mode": mode, "at": "2026-10-04T21:52:00Z"}),))


def live_steps(mcp, ev, real_today):
    outputs, problems = [], []
    for step in ev["steps"]:
        args = {k: absolute_when(v, real_today) if k == "when" else v for k, v in step["args"].items()}
        if step["tool"] == "details" and step.get("detailsOf"):
            if not outputs:
                problems.append("details: no earlier reply")
                break
            ident = first_id(outputs[-1]["text"], step["detailsOf"])
            if not ident:
                problems.append(f"details: no item matching /{step['detailsOf']}/ with an id in the previous reply")
                break
            args["id"] = ident
        text, problem = mcp.call(step["tool"], args)
        if problem:
            problems.append(problem)
        if text is None:
            break
        outputs.append({"tool": step["tool"], "args": args, "text": text})
        pages = 0
        while step.get("pageAll") and pages < 20:
            cur = cursor_in(text)
            if not cur:
                break
            pages += 1
            text, problem = mcp.call(step["tool"], {**args, "cursor": cur})
            if problem:
                problems.append(problem)
            if text is None:
                break
            outputs.append({"tool": step["tool"], "args": {**args, "cursor": cur}, "text": text})
    return outputs, problems


def run_live(args, checks, cli, base, table):
    env = scratch_env(base)
    home = base / "fixture-live"
    subprocess.run([str(checks), "--agent-tools", "fixture", str(home)], cwd=ROOT, env=env, check=True, capture_output=True)
    manifest = json.loads((home / "agenttools-fixture.json").read_text())
    real_today = dt.datetime.now(ZoneInfo(FIXTURE_TZ)).strftime("%Y-%m-%d")
    mcp = MCP(cli, home, env)
    worst = 0
    print(f"\n== live: mac-mem mcp, temp HOME ({manifest['lane']} lane fixture; no DayDream app, so no typed words)")
    try:
        init = mcp.request("initialize", {"protocolVersion": "2025-06-18"})["result"]
        listed = [t["name"] for t in mcp.request("tools/list")["result"]["tools"]]
        server = []
        server.append(("tools/list lists exactly the 4 v2 tools", listed == V2_TOOLS, f"listed {listed}"))
        server.append(("initialize says the tool list may change", init.get("capabilities", {}).get("tools", {}).get("listChanged") is True, ""))
        server.append(("instructions at most 1,600 characters", len(init.get("instructions", "")) <= 1600, f"{len(init.get('instructions', ''))}"))
        status, _ = mcp.call("status", {})
        server.append(("every reply starts with the one header line", bool(status) and re.match(r"^DayDream · ", status or "") is not None, (status or "")[:80]))
        listed_text = init.get("instructions", "") + json.dumps(mcp.request("tools/list")["result"])
        server.append(('no "draft" in the instructions or tool list', not rx("draft", listed_text), ""))
        server.append(('no "draft" in DayDream\'s wording of the status reply', not rx("draft", own_wording(status or "")), ""))
        for name in LEGACY:
            msg = mcp.request("tools/call", {"name": name, "arguments": {}})
            server.append((f"legacy {name} still answers (unlisted)", "result" in msg, json.dumps(msg.get("error", ""))[:120]))
            body = "\n".join(c.get("text", "") for c in msg.get("result", {}).get("content", []))
            server.append((f'legacy {name}: no "draft" in DayDream\'s wording', not rx("draft", own_wording(body)),
                           re.sub(r"\s+", " ", own_wording(body))[:120]))
        for name, ok, detail in server:
            print(f"{'ok ' if ok else 'MISS'} server: {name}" + ("" if ok else f" ({detail})"))
        server_miss = [n for n, ok, _ in server if not ok]

        print(f"{'eval':5} {'status':16} {'calls':>5} {'max tok':>7} {'sum tok':>7}  title / first problems")
        results = []
        for ev in select(table, args.only):
            if ev["setup"] in ("typingOff", "locked"):
                results.append({"id": ev["id"], "status": "n/a", "note": "the typed-words setting and the vault live in the app; no app here"})
                print(f"{ev['id']:5} {'n/a':16} {'':>5} {'':>7} {'':>7}  {ev['title']} (setting lives in the app)")
                continue
            if ev["id"] == "E13" and real_today != FIXTURE_DAY:
                results.append({"id": ev["id"], "status": "n/a", "note": "'tomorrow' needs the real clock on the fixture day"})
                print(f"{ev['id']:5} {'n/a':16} {'':>5} {'':>7} {'':>7}  {ev['title']} (clock is not on {FIXTURE_DAY})")
                continue
            if ev["setup"] == "writerOff":
                set_writer(home, "off")
            outputs, problems = live_steps(mcp, ev, real_today)
            if ev["setup"] == "writerOff":
                set_writer(home, "local")
            skipped_details = []
            if ev["typed"]:
                # No app here, so no typed words: an item found only by its typed words can't be picked for details. The
                # eval is "partial" already; the replies it did get are still checked below.
                skipped_details = [p for p in problems if p.startswith("details: no item matching")]
                problems = [p for p in problems if p not in skipped_details]
            texts = [o["text"] for o in outputs]
            joined = "\n".join(texts)
            typed_missing = ev["typed"]
            if len(outputs) > ev["maxCalls"]:
                problems.append(f"{len(outputs)} calls, limit {ev['maxCalls']}")
            for o in outputs:
                if tokens(o["text"]) > ev["maxTokens"]:
                    problems.append(f"{o['tool']}: {tokens(o['text'])} tokens, limit {ev['maxTokens']}")
                if not o["text"].startswith("DayDream · "):
                    problems.append(f"{o['tool']}: no header line")
            if not typed_missing:
                problems += [f"missing: /{p}/" for p in ev["required"] if not rx(p, joined)]
            problems += [f"forbidden: /{p}/" for p in ev["forbidden"] if rx(p, joined)]
            problems += always_problems(table, texts, manifest["secrets"])
            for name in ev["custom"]:
                got, skipped = text_custom(name, outputs, False, lambda: [o["text"] for o in live_steps(mcp, ev, real_today)[0]])
                if not skipped:
                    problems += got
            status = ("partial-miss" if problems else "partial-pass") if typed_missing else ("miss" if problems else "pass")
            if problems and args.strict:
                worst = 1  # live misses fail the run only with --strict (stubs miss by design)
            toks = [tokens(t) for t in texts]
            note = "details skipped: the item is found only by typed words" if skipped_details else None
            results.append({"id": ev["id"], "status": status, "calls": len(outputs), "tokens": toks, "problems": problems, "note": note})
            print(f"{ev['id']:5} {status:16} {len(outputs):>5} {max(toks or [0]):>7} {sum(toks):>7}  {ev['title']}" + (f" ({note})" if note else ""))
            for p in problems[: (None if args.verbose else 3)]:
                print(f"{'':39}- {p}")
            if args.show and (ev["id"] in args.show.split(",") or args.show == "all"):
                for o in outputs:
                    print(f"--- {o['tool']} {json.dumps(o['args'], sort_keys=True)} ({tokens(o['text'])} tokens)\n{o['text']}\n---")
        counts = {}
        for r in results:
            counts[r["status"]] = counts.get(r["status"], 0) + 1
        print("summary: " + ", ".join(f"{v} {k}" for k, v in sorted(counts.items())) + f"; server checks missed: {len(server_miss)}")
        if server_miss and args.strict:
            worst = 1

        llm = run_llm(args, mcp, init, table, manifest) if args.llm else None
        return {"server": [{"check": n, "ok": ok} for n, ok, _ in server], "results": results, "llm": llm}, worst
    finally:
        mcp.close()


# ---------------------------------------------------------------------------------------------------------------------
# LLM in the loop (optional)


def run_llm(args, mcp, init, table, manifest):
    try:
        import anthropic
    except ImportError:
        print("--llm needs the anthropic package (pip install anthropic)")
        return None
    client = anthropic.Anthropic()
    tools = [{"name": t["name"], "description": t.get("description", ""), "input_schema": t.get("inputSchema", {"type": "object"})}
             for t in mcp.request("tools/list")["result"]["tools"]]
    system = (init.get("instructions", "") + "\n\nYou are answering one question from the person whose Mac this is. Use only the "
              "DayDream tools. Today is Sunday, October 4, 2026, 4:52 PM in Chicago. Answer briefly in plain words.")
    print(f"\n== LLM in the loop ({args.llm_model}): answers graded against each eval's answer facts")
    out = []
    for ev in select(table, args.only):
        if not ev.get("playbook") and not args.llm_all:
            continue
        messages = [{"role": "user", "content": ev["question"]}]
        calls, used, answer, stop = 0, [], "", ""
        for _ in range(ev["maxCalls"] + 6):
            response = client.messages.create(
                model=args.llm_model, max_tokens=16000, system=system, tools=tools, messages=messages,
                output_config={"effort": args.llm_effort},
                # Server-side fallback when a safety classifier declines (the model may be routed to another one).
                extra_headers={"anthropic-beta": "server-side-fallback-2026-07-01"}, extra_body={"fallbacks": "default"})
            stop = response.stop_reason
            if stop == "refusal":
                break
            if stop != "tool_use":
                answer = "".join(b.text for b in response.content if b.type == "text")
                break
            messages.append({"role": "assistant", "content": response.content})
            results = []
            for block in response.content:
                if block.type != "tool_use":
                    continue
                calls += 1
                used.append(block.name)
                text, problem = mcp.call(block.name, block.input)
                results.append({"type": "tool_result", "tool_use_id": block.id, "content": text or problem or "",
                                **({"is_error": True} if text is None else {})})
            messages.append({"role": "user", "content": results})
        facts = ev.get("answer") or []
        missing = [f for f in facts if not rx(f, answer)] if not ev["typed"] else []
        bad = [p for p in table["sendState"] if rx(p, unquoted(answer))] + [s for s in manifest["secrets"] if s in answer]
        ok = not missing and not bad and calls <= max(ev["maxCalls"], 2) and stop != "refusal"
        out.append({"id": ev["id"], "calls": calls, "tools": used, "ok": ok, "missing": missing, "bad": bad, "stop": stop, "answer": answer})
        print(f"{ev['id']:5} {'pass' if ok else 'miss':5} {calls:>2} calls {'(' + ','.join(used) + ')':40} "
              + ("" if ok else f"missing {missing} bad {bad} stop {stop}"))
        if args.verbose:
            print("    " + answer.replace("\n", "\n    "))
    return out


# ---------------------------------------------------------------------------------------------------------------------


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--mode", choices=["inprocess", "live", "both"], default="inprocess")
    p.add_argument("--owner", action="store_true", help="the owner lane: binaries in .build-owner (built with the owner flags)")
    p.add_argument("--build", action="store_true", help="swift build MacMemChecks and mac-mem first")
    p.add_argument("--checks", help="MacMemChecks binary (default: DAYDREAM_TEST_CHECKS or .build/debug)")
    p.add_argument("--cli", help="mac-mem binary (default: DAYDREAM_TEST_CLI or .build/debug)")
    p.add_argument("--only", help="comma-separated eval ids")
    p.add_argument("--show", help="print the replies of these eval ids (or 'all')")
    p.add_argument("--json", help="write the whole report here")
    p.add_argument("--strict", action="store_true", help="exit 1 on any miss, armed or not")
    p.add_argument("--verbose", "-v", action="store_true")
    p.add_argument("--llm", action="store_true", help="LLM in the loop (live mode; off by default)")
    p.add_argument("--llm-all", action="store_true", help="with --llm: every eval, not only the playbook")
    p.add_argument("--llm-model", default="claude-opus-5-5")
    p.add_argument("--llm-effort", default="medium", choices=["low", "medium", "high", "xhigh", "max"])
    p.add_argument("--keep", action="store_true", help="keep the temp folder (synthetic only)")
    args = p.parse_args()
    if args.llm and args.mode == "inprocess":
        args.mode = "live"

    checks, cli = binaries(args)
    base = Path(tempfile.mkdtemp(prefix="agenttools-evals-"))
    report, worst = {}, 0
    try:
        table = eval_table(checks, scratch_env(base))
        if args.mode in ("inprocess", "both"):
            report["inprocess"], w = run_inprocess(args, checks, base)
            worst = max(worst, w)
        if args.mode in ("live", "both"):
            report["live"], w = run_live(args, checks, cli, base, table)
            worst = max(worst, w)
        if args.json:
            Path(args.json).write_text(json.dumps(report, indent=2, sort_keys=True))
    finally:
        if args.keep:
            print(f"kept {base}")
        else:
            subprocess.run(["rm", "-rf", str(base)])
    sys.exit(worst)


if __name__ == "__main__":
    main()
