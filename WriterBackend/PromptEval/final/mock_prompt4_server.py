#!/usr/bin/env python3
"""Stand-in for llama-server used only by `prompt4.py selftest --mock-run`. No model.

ITEMS prompts: the first answer breaks a rule ("Finished everything."), the repair turn gets a
valid answer, so both attempts and the prefill continuation are exercised. JSON-action prompts
(the prompt3 baseline) get one bullet per action, like ../mock_llama_server.py.
"""
import json, re, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port = int(sys.argv[sys.argv.index("--port") + 1])
PREFILL = '{"title":"'

def join(xs): return xs[0] if len(xs) == 1 else ", ".join(xs[:-1]) + " and " + xs[-1]

def answer(user):
    try:
        actions = json.loads(user.replace("\\u003c", "<"))
        return {"title": "Mock activity", "bullets": [{"text": "Observed activity in %s." % (a.get("app") or "an app"), "actionIDs": [a["id"]],
                                                       "assertion": "observed"} for a in actions]}
    except ValueError:
        pass
    view = user.split("\n\nYour previous answer was thrown away.")[0]
    items = re.findall(r"^(i\d+)\. ([^:\n]+): (.*)$", view, re.M)
    if "Previous answer:" not in user:
        return {"title": "Mock", "bullets": [{"ids": [i for i, _, _ in items], "text": "Finished everything."}]}
    groups = {}
    for i, app, body in items:
        kind = ("sent" if body.startswith("SENT") else "report" if body.startswith("REPORT") else "note" if body.startswith("YOUR NOTE")
                else "asked" if body.startswith("YOU ASKED") else "plan" if body.startswith("YOUR PLAN") else "typed" if body.startswith("typed")
                else "search" if body.startswith("search results") else "screen" if body.startswith("text on screen") else None)
        if kind: groups.setdefault(kind, []).append((i, app))
    text = {"typed": "Typed a draft in %s.", "sent": "%s confirmed a message was sent.", "report": "%s reported something; not verified.",
            "note": "You noted something in %s.", "asked": "Asked %s for something.", "plan": "You plan something in %s.",
            "search": "Had search results open in %s.", "screen": "Had text on screen in %s."}
    bullets = [{"ids": [i for i, _ in g], "text": text[k] % join(sorted({a for _, a in g}))} for k, g in groups.items()]
    if not bullets:
        bullets = [{"ids": [i for i, _, _ in items], "text": "Had windows open in %s." % join(sorted({a for _, a, _ in items}))}]
    return {"title": "Mock summary", "bullets": bullets}

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        self.send({"status": "ok"})
    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["Content-Length"])).decode())
        if self.path == "/tokenize":
            self.send({"tokens": list(range(len(req["content"].encode()) // 3))})
        elif self.path == "/apply-template":
            self.send({"prompt": ""})
        elif self.path == "/completion":
            user = re.search(r"<\|im_start\|>user\n(.*)<\|im_end\|>\n<\|im_start\|>assistant", req["prompt"], re.S).group(1)
            out = json.dumps(answer(user), ensure_ascii=False, separators=(",", ":"))
            if req["prompt"].endswith(PREFILL) and out.startswith(PREFILL): out = out[len(PREFILL):]
            self.send({"content": out, "stop_type": "eos", "tokens_evaluated": len(req["prompt"]) // 3,
                       "tokens_predicted": len(out) // 3, "timings": {"prompt_ms": 1.0, "predicted_ms": 1.0}})
        else:
            self.send_response(404); self.end_headers()

HTTPServer(("127.0.0.1", port), H).serve_forever()
