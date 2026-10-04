#!/usr/bin/env python3
"""Run the shared eval harness (../eval_writer.py) with prompt4 small-model-first variants.

Same commands and flags as eval_writer.py. Variants whose "contract" is "view1-v6" are built
with smallfirst.model_view (numbered ITEMS instead of the raw NoteAction JSON), rendered with
the '{"title":"' assistant prefill, and validated with smallfirst.validate_v6. Any other
variant (e.g. ../variants/prompt3-validator5.json) runs exactly as in eval_writer.py, so one
command gives an A/B against the shipping prompt:

  python3 WriterBackend/PromptEval/small_first/eval_small.py run --model /path/Qwen3.5-4B-Q4_K_M.gguf \
      --variant WriterBackend/PromptEval/variants/prompt3-validator5.json \
      --variant WriterBackend/PromptEval/small_first/prompt4-small.json \
      --variant WriterBackend/PromptEval/small_first/prompt4-small-noexamples.json

Offline (no model):
  eval_small.py score --outputs small_first/expected-prompt4-small.jsonl --variant small_first/prompt4-small.json
  eval_small.py render --case E01 --variant small_first/prompt4-small.json [--evidence-only] [--stats]
  eval_small.py viewcheck      # view/validator6 self-checks on all 17 cases
"""
import json, re, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parent))
import eval_writer as ew  # noqa: E402
import smallfirst as sf   # noqa: E402

_build_prompt, _evaluate = ew.build_prompt, ew.evaluate
BACKEND = []  # the live llama backend, so evaluate() can run the optional repair turn

for _cls in (ew.Server, ew.Completion):
    _init = _cls.__init__
    def _wrapped(self, *a, _init=_init, **k):
        _init(self, *a, **k); BACKEND[:] = [self]
    _cls.__init__ = _wrapped

def _instruction(v):
    text = v["instruction"]
    if v.get("stripExamples"): text = text.split("\nExample\n")[0]
    return text

def build_prompt(variant, case):
    if variant.get("contract") != "view1-v6": return _build_prompt(variant, case)
    view, items = sf.model_view(case["request"])
    prefill = sf.PREFILL if variant.get("prefill", True) else ""
    return sf.render(_instruction(variant), view, prefill), view, {"__items__": items, "__prefill__": prefill}

def evaluate(variant, case, raw, alias, globals_, gen=None):
    if variant.get("contract") != "view1-v6": return _evaluate(variant, case, raw, alias, globals_, gen)
    req = case["request"]; acts = ew.sort_actions(req["actions"]); gen = gen or {}
    items, prefill = alias["__items__"], alias["__prefill__"]
    full = sf.with_prefill(raw, prefill)
    block = []
    if gen.get("stop") and gen["stop"] not in ("eos", "not-run"): block.append("no end-of-generation token within %d tokens (bridge status 10)" % variant["maxTokens"])
    if gen.get("promptTokens") is not None and gen["promptTokens"] + variant["maxTokens"] > ew.APP["n_ctx"]: block.append("prompt tokens + max tokens > 8192 (bridge status 6)")
    if gen.get("seconds") and gen["seconds"] > ew.APP["deadline_s"]: block.append("over the 90 s deadline (bridge status 5)")
    res = {"case": case["id"], "variant": variant["name"], "raw": full, "gen": gen, "validator5": "n/a (view1 contract)", "appBlock": block}
    try:
        note = sf.validate_v6(full, req, acts, items); res["validator"] = None
    except ew.Invalid as e:
        note, res["validator"] = None, str(e)
    if note is None and variant.get("repairTurn") and BACKEND and gen.get("stop") not in (None, "not-run"):
        msg = sf.repair_message(res["validator"])
        prompt2 = sf.render_repair(_instruction(variant), sf.model_view(req)[0], full, msg, prefill)
        raw2, gen2 = BACKEND[0].complete(prompt2, variant["maxTokens"], variant.get("jsonSchema"))
        full2 = sf.with_prefill(raw2, prefill)
        res["repairTurn"] = {"message": msg, "firstError": res["validator"], "raw": full2, "gen": gen2}
        if gen2.get("stop") not in ("eos", None): block.append("repair turn: no end-of-generation token (bridge status 10)")
        try:
            note = sf.validate_v6(full2, req, acts, items); res["validator"] = None; res["raw"] = full2
        except ew.Invalid as e:
            res["validator"] = "after repair turn: " + str(e)
    res["core"] = ew.core_gate(note, acts) if note else None
    res["publishable"] = bool(note) and res["core"] is None and not block
    res["appWouldPublish"] = False
    if note:
        rep = note.pop("_report"); res["repairs"] = rep; res["note"] = note
        res["score"] = ew.score(case, note["title"], note["bullets"], globals_, res["core"] is None)
        res["score"]["soft"] += ["validator6 dropped bullet #%d: %s" % d for d in rep["dropped"]]
        res["score"]["soft"] += ["validator6 repaired item %d (%s)" % r for r in rep["repaired"]]
        if rep["titleFallback"]: res["score"]["soft"].append("title replaced by derived fallback (%s)" % rep["titleFallback"])
        res["score"]["modelCoverage"] = round(1 - len(rep["repaired"]) / max(1, len(items)), 2)
    else:
        res["score"] = {"grounded": False, "clean": False, "quality": 0.0, "hard": ["validator6: " + res["validator"]], "leaks": [], "soft": []}
    return res

ew.build_prompt, ew.evaluate = build_prompt, evaluate

def cmd_viewcheck(args):
    globals_, cases = ew.load_cases(args.cases, args.only)
    v = ew.load_variant(HERE / "prompt4-small.json")
    fails = 0
    def expect(ok, label):
        nonlocal fails
        fails += not ok
        print(("PASS " if ok else "FAIL ") + label)
    leak = re.compile(r"not established|Recorded a |native-|browser_[0-9a-f]|[0-9a-f]{40}|\b(com|jp)\.[a-z]+\.|<\||\\u003c|\"revision\"")
    for c in cases:
        view, items = sf.model_view(c["request"])
        prompt, _, _ = build_prompt(v, c)
        old, _, _ = _build_prompt(ew.load_variant(HERE.parent / "variants/prompt3-validator5.json"), c)
        ids = [x for it in items.values() for x in it["actionIDs"]]
        expect(sorted(ids) == sorted(a["id"] for a in c["request"]["actions"]) and len(ids) == len(set(ids)),
               "%s every action is in exactly one of %d items" % (c["id"], len(items)))
        m = leak.search(view)
        expect(m is None, "%s view has no IDs, hashes, hedges, bundle IDs or template tokens%s" % (c["id"], "" if not m else ": " + m.group(0)))
        print("     %s prompt %d B (was %d B), view %d B, %d actions -> %d items" % (c["id"], len(prompt.encode()), len(old.encode()), len(view.encode()),
              len(c["request"]["actions"]), len(items)))
    # validator6 behaviour on hand-made outputs
    c = next(c for c in cases if c["id"] == "E03"); acts = ew.sort_actions(c["request"]["actions"]); _, items = sf.model_view(c["request"])
    def v6(obj): return sf.validate_v6(obj if isinstance(obj, str) else json.dumps(obj), c["request"], acts, items)
    n = v6({"title": "Reply to Priya", "bullets": [{"text": "Drafted a reply to Priya in Mail.", "ids": [1]}, {"text": "Sent it to Priya.", "ids": [2, 3, 4]}]})
    expect(len(n["bullets"]) == 2 and n["bullets"][1]["text"].startswith("Also:") and n["_report"]["dropped"][0][0] == 1,
           "E03 a bullet claiming 'Sent' is dropped and its items repaired into an Also bullet")
    n2 = v6({"title": "Reply to Priya", "bullets": [{"text": "Drafted a reply to Priya in Mail.", "ids": [1, 2, 4]}, {"text": "A shortcut and a Return press.", "ids": [3]}]})
    expect([b["assertion"] for b in n2["bullets"]] == ["draft", "observed"], "E03 assertion derived from cited states (all typed -> draft; shortcut+Return -> observed)")
    n = v6('```json\n{"title":"Reply to Priya","bullets":[{"text":"Drafted a reply to Priya in Mail; sending isn\'t confirmed.","ids":["1","#2",3,4,],}]}\n```')
    expect(len(n["bullets"]) == 1 and len(n["bullets"][0]["actionIDs"]) == 5, "E03 fenced JSON, string ids and trailing commas are accepted")
    try: v6({"title": "x", "bullets": [{"text": "Sent the reply.", "ids": [1, 2, 3, 4]}]}); ok = False
    except ew.Invalid: ok = True
    expect(ok, "E03 a note whose only bullet is dropped stays pending")
    n = v6({"title": "Finished and sent", "bullets": [{"text": "Drafted a reply to Priya.", "ids": [1, 2, 3, 4]}]})
    expect(n["title"] not in ("Activity note", "Day summary") and n["_report"]["titleFallback"], "E03 a state-word title falls back to a derived, non-generic title: %r" % n["title"])
    c = next(c for c in cases if c["id"] == "E06"); acts = ew.sort_actions(c["request"]["actions"]); _, items = sf.model_view(c["request"])
    rep = next(n for n, it in items.items() if it["family"] == "report")
    ok1 = not sf.bullet_problem("Claude reported that the merge bug is fixed; not verified.", [a for a in acts if a["id"] in items[rep]["actionIDs"]], [items[rep]])
    ok2 = bool(sf.bullet_problem("Fixed the merge bug.", [a for a in acts if a["id"] in items[rep]["actionIDs"]], [items[rep]]))
    expect(ok1 and ok2, "E06 'fixed' is allowed only as an attributed relay of the cited report")
    print("%d failures" % fails)
    return 1 if fails else 0

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "viewcheck":
        import argparse
        ap = argparse.ArgumentParser(); ap.add_argument("cmd"); ap.add_argument("--cases", default=str(HERE.parent / "cases.json")); ap.add_argument("--only")
        sys.exit(cmd_viewcheck(ap.parse_args()))
    sys.exit(ew.main())
