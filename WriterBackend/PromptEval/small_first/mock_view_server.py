#!/usr/bin/env python3
"""Stand-in for llama-server for `eval_small.py selftest-run`: no model, plumbing only.
Answers the prompt3 JSON contract like ../mock_llama_server.py, and the prompt4 ITEMS view with
one bullet per note. For a view containing "Weekly planning" it first answers with a bullet the
validator drops ("Read ..."), so the repair turn is exercised."""
import json, re, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port = int(sys.argv[sys.argv.index("--port") + 1])

def answer(prompt):
    users = re.findall(r"<\|im_start\|>user\n(.*?)<\|im_end\|>", prompt, re.S)
    last, prefill = users[-1], prompt.endswith('{"title":"')
    if last.startswith("["):
        acts = json.loads(last.replace("\\u003c", "<"))
        return json.dumps({"title": "Mock activity", "bullets": [{"text": "Observed activity in %s." % (a.get("app") or "an app"),
                                                                  "actionIDs": [a["id"]], "assertion": "observed"} for a in acts]}), 40 * len(acts)
    view = users[0]
    items = re.findall(r"^(\d+)\. ([^:]+):", view, re.M)
    apps = sorted({a for _, a in items})
    bad = "Weekly planning" in view and not last.startswith("Fix this")
    text = "Read the Weekly planning email in Mail." if bad else "Had %s open." % " and ".join(apps)
    out = json.dumps({"title": "Mock note for " + apps[0], "bullets": [{"text": text, "ids": [int(n) for n, _ in items]}]}, separators=(",", ":"))
    return (out[len('{"title":"'):] if prefill else out), 30

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def do_GET(self): self.send({"status": "ok"})
    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["Content-Length"])).decode())
        if self.path == "/tokenize": self.send({"tokens": list(range(len(req["content"].encode()) // 3))})
        elif self.path == "/apply-template": self.send({"prompt": ""})
        elif self.path == "/completion":
            content, n = answer(req["prompt"])
            self.send({"content": content, "stop_type": "eos", "tokens_evaluated": len(req["prompt"]) // 3, "tokens_predicted": n,
                       "timings": {"prompt_ms": 1.0, "predicted_ms": 1.0}})
        else: self.send_response(404); self.end_headers()

HTTPServer(("127.0.0.1", port), H).serve_forever()
