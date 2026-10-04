#!/usr/bin/env python3
"""Stand-in for llama-server used only by `eval_writer.py selftest --mock-run`.

It accepts the same command line, answers /health, /tokenize, /apply-template and
/completion, and "generates" a one-bullet-per-action note from the evidence in the
prompt. No model is loaded; this only exercises the harness plumbing.
"""
import json, re, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port = int(sys.argv[sys.argv.index("--port") + 1])

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
            actions = json.loads(user.replace("\\u003c", "<"))
            out = {"title": "Mock activity", "bullets": [{"text": "Observed activity in %s." % (a.get("app") or "an app"), "actionIDs": [a["id"]],
                                                          "assertion": "observed"} for a in actions]}
            self.send({"content": json.dumps(out), "stop_type": "eos", "tokens_evaluated": len(req["prompt"]) // 3,
                       "tokens_predicted": 40 * len(actions), "timings": {"prompt_ms": 1.0, "predicted_ms": 1.0}})
        else:
            self.send_response(404); self.end_headers()

HTTPServer(("127.0.0.1", port), H).serve_forever()
