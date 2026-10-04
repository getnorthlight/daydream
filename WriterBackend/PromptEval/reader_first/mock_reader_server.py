#!/usr/bin/env python3
"""Stand-in for llama-server used only by `reader_first.py selftest --mock-run`. No model.

Item-view prompts: the first answer breaks a rule ("Finished"), the repair turn gets a valid
answer, so both attempts of the pipeline are exercised. JSON-action prompts (the prompt3
baseline) get one bullet per action, like ../mock_llama_server.py.
"""
import json, re, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port = int(sys.argv[sys.argv.index("--port") + 1])

def answer(user):
    try:
        actions = json.loads(user.replace("\\u003c", "<"))
        return {"title": "Mock activity", "bullets": [{"text": "Observed activity in %s." % (a.get("app") or "an app"), "actionIDs": [a["id"]],
                                                       "assertion": "observed"} for a in actions]}
    except ValueError:
        pass
    items = re.findall(r"^(i\d+) \| ([^|]+) \|", user, re.M)
    ids = [i for i, _ in items]
    apps = sorted({a.strip() for _, a in items})
    if "Previous answer:" not in user:
        return {"title": "Mock", "bullets": [{"text": "Finished everything.", "ids": ids}]}
    cues = []
    if "[report]" in user or "[your note]" in user: cues.append("someone reported or noted something")
    if "[request]" in user: cues.append("you asked for something")
    if "[plan]" in user: cues.append("you plan more")
    text = "Looked at things in " + ", ".join(apps) + (("; " + ", ".join(cues)) if cues else "") + "."
    return {"title": "Mock summary", "bullets": [{"text": text[:190], "ids": ids}]}

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
            out = json.dumps(answer(user), ensure_ascii=False)
            self.send({"content": out, "stop_type": "eos", "tokens_evaluated": len(req["prompt"]) // 3,
                       "tokens_predicted": len(out) // 3, "timings": {"prompt_ms": 1.0, "predicted_ms": 1.0}})
        else:
            self.send_response(404); self.end_headers()

HTTPServer(("127.0.0.1", port), H).serve_forever()
