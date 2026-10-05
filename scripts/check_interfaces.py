"""Synthetic CLI/MCP and before-turn integration. Explicit temporary data only."""
import importlib.util
import json
import sqlite3
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
# claude/mcp-prompts-1003: DAYDREAM_TEST_CLI names a built mac-mem (the headless runner builds in scratch).
CLI = os.environ.get("DAYDREAM_TEST_CLI") or str(ROOT / ".build/debug/mac-mem")
spec = importlib.util.spec_from_file_location("before_turn", ROOT / "adapters/before_turn.py")
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)


class Interfaces(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="macmem-interface-")
        self.home = self.temp.name
        self.base = [CLI, "--home", self.home]
        self.run_cli("demo")
        # Explicit text consent belongs only to this temporary synthetic fixture.
        with sqlite3.connect(str(Path(self.home)/"memory.sqlite")) as db:
            policy=json.loads(db.execute("SELECT body FROM metadata WHERE id='policy'").fetchone()[0])
            self.assertFalse(policy["captureText"])
            policy["captureText"]=True
            db.execute("UPDATE metadata SET body=? WHERE id='policy'",(json.dumps(policy),))
        self.run_cli("demo")

    def tearDown(self):
        self.temp.cleanup()

    def run_cli(self, *args, env=None):
        return json.loads(subprocess.check_output(self.base + list(args), env=env, text=True))

    def test_persisted_search_read_and_doctor(self):
        self.assertEqual(self.run_cli("status")["capture"], "off")
        # The cloud field is the setting the app last reported; a store the app never opened says "unknown", never a fixed "off".
        self.assertEqual(self.run_cli("doctor")["cloud"], "unknown")
        hits = self.run_cli("--local", "search", "SQLite")
        self.assertEqual(hits[0]["id"], "demo-search")
        item = self.run_cli("--local", "read", "demo-request")
        self.assertEqual(item["actionState"], "requested")
        self.assertTrue(item["evidence"]["synthetic"])

    def token(self):
        return self.run_cli("--client", "test-host", "--recipient", "synthetic-local", "grant")["capability"]

    def test_read_only_mcp_bound_identity(self):
        token = self.token()
        requests = [{"jsonrpc":"2.0","id":i,"method":method,"params":params} for i,(method,params) in enumerate([
            ("initialize",{}), ("tools/list",{}), ("tools/call",{"name":"search","arguments":{"query":"SQLite"}}),
            ("tools/call",{"name":"delete","arguments":{"id":"demo-request"}}),
            ("tools/call",{"name":"read","arguments":{"id":"../../etc/passwd","response_format":"detailed"}}),
            ("tools/call",{"name":"read","arguments":{"id":"../../etc/passwd"}})])]
        result = subprocess.check_output(self.base + ["--client","test-host","--recipient","synthetic-local","mcp"],
                                        input="\n".join(map(json.dumps,requests))+"\n", text=True,
                                        env={**os.environ,"MAC_MEM_CAPABILITY":token})
        rows = [json.loads(line) for line in result.splitlines()]
        # agent-tools v2: the server lists the four v2 tools; the 0.1.4 names (read here) still answer, unlisted.
        self.assertEqual([t["name"] for t in rows[1]["result"]["tools"]],["timeline","search","details","status"])
        self.assertTrue(rows[0]["result"]["capabilities"]["tools"]["listChanged"])
        self.assertIn("start with timeline",rows[0]["result"]["instructions"])
        found = rows[2]["result"]["content"][0]["text"]
        self.assertTrue(found.startswith("DayDream \u00b7 ")); self.assertIn("SQLite",found); self.assertNotIn("macmem://",found)
        self.assertNotIn("not a final answer",found)
        self.assertIn("error",rows[3]); self.assertEqual(rows[4]["result"]["content"][0]["text"],"null")
        # claude/mcp-prompts-1003: unknown tools stay protocol errors and name the real ones; a missing item says what to do.
        self.assertEqual(rows[3]["error"]["code"],-32602); self.assertIn("details",rows[3]["error"]["message"])
        self.assertIn("Next:",rows[5]["result"]["content"][0]["text"])

    def mcp(self, requests, toolset=None):
        token = self.token()
        env = {**os.environ,"MAC_MEM_CAPABILITY":token}
        env.pop("DAYDREAM_MCP_TOOLSET", None)
        if toolset: env["DAYDREAM_MCP_TOOLSET"] = toolset
        lines = "\n".join(json.dumps({"jsonrpc":"2.0","id":i,"method":m,"params":p}) for i,(m,p) in enumerate(requests))+"\n"
        result = subprocess.check_output(self.base + ["--client","test-host","--recipient","synthetic-local","mcp"], input=lines, text=True, env=env)
        return [json.loads(line) for line in result.splitlines()]

    def test_legacy_toolset(self):
        # agent-tools v2: DAYDREAM_MCP_TOOLSET=legacy lists the 0.1.4 tools with the 0.1.4 instructions; both lists them all.
        rows = self.mcp([("initialize",{}),("tools/list",{})], toolset="legacy")
        self.assertEqual([t["name"] for t in rows[1]["result"]["tools"]],["status","context","search","read","open","recall","current-context","recap","moment_details"])
        self.assertIn("recap",rows[0]["result"]["instructions"]); self.assertNotIn("start with timeline",rows[0]["result"]["instructions"])
        both = [t["name"] for t in self.mcp([("tools/list",{})], toolset="both")[0]["result"]["tools"]]
        self.assertEqual(both[:4],["timeline","search","details","status"])
        for name in ["recap","recall","open","read","context","current-context","moment_details"]: self.assertIn(name,both)

    def test_v2_tools(self):
        # agent-tools v2: one header line, compact text by default, json on request, plain errors, no links or send states.
        rows = self.mcp([("initialize",{"protocolVersion":"2025-06-18"}),("tools/call",{"name":"timeline","arguments":{"when":"today"}}),
                         ("tools/call",{"name":"timeline","arguments":{"when":"today","format":"json","detail":"full"}}),
                         ("tools/call",{"name":"search","arguments":{"query":"Search","kinds":["page"]}}),
                         ("tools/call",{"name":"details","arguments":{"id":"not-an-id"}}),
                         ("tools/call",{"name":"status","arguments":{}}),
                         ("tools/call",{"name":"timeline","arguments":{"when":"next week"}}),
                         ("tools/call",{"name":"recap","arguments":{"when":"today"}})])[1:]
        text = [r["result"]["content"][0]["text"] for r in rows]
        for t in [text[0],text[2],text[4]]:
            self.assertTrue(t.startswith("DayDream \u00b7 ")); self.assertNotIn("macmem://",t)
            for word in ["How to answer","Next:","not sent","send key","(confirmed)"]: self.assertNotIn(word,t)
        self.assertIn("Where you left off:",text[0])
        page = json.loads(text[1]); self.assertEqual(page["tool"],"timeline"); self.assertEqual(rows[1]["result"]["structuredContent"]["tool"],"timeline")
        self.assertIn("1 item matches",text[2])
        ids = [w for w in text[2].split() if len(w)==10 and w[4]=="-"]
        self.assertTrue(ids)
        details = self.mcp([("tools/call",{"name":"details","arguments":{"id":ids[0]}})])[0]["result"]["content"][0]["text"]
        self.assertTrue(details.startswith("DayDream \u00b7 ")); self.assertIn(ids[0],details)
        self.assertTrue(rows[3]["result"]["isError"]); self.assertIn("1004-k7f2q",text[3])
        self.assertIn("Recording:",text[4]); self.assertIn("Never shown: whether a message went out",text[4])
        self.assertFalse(rows[5]["result"].get("isError",False)); self.assertIn("can't see the future",text[5]); self.assertIn("calendar",text[5])
        self.assertFalse(rows[6]["result"].get("isError",False)); self.assertTrue(text[6].startswith("**Recap:"))

    def test_recap_over_mcp(self):
        # mcp-recap-1002: recap answers over MCP with the per-day shape and how to present it; ids and links never.
        token = self.token()
        requests = [{"jsonrpc":"2.0","id":i,"method":"tools/call","params":{"name":"recap","arguments":args}} for i,args in enumerate([
            {"when":"past 2 days","response_format":"detailed"}, {"response_format":"detailed"}, {"when":"next fortnight please"}, {"when":"past 2 days"}])]
        result = subprocess.check_output(self.base + ["--client","test-host","--recipient","synthetic-local","mcp"],
                                        input="\n".join(map(json.dumps,requests))+"\n", text=True,
                                        env={**os.environ,"MAC_MEM_CAPABILITY":token,"DAYDREAM_TEST_FRESHEN_REQUEST":"com.example.recap-check"})
        rows = [json.loads(line) for line in result.splitlines()]
        recap = json.loads(rows[0]["result"]["content"][0]["text"])
        self.assertEqual(len(recap["days"]),2)
        self.assertIn("one plain line",recap["present"])
        for day in recap["days"]:
            self.assertTrue(day["day"] and day["date"])
            self.assertTrue("blocks" in day or "quiet" in day)
            for block in day.get("blocks",[]):
                self.assertLessEqual(len(block.get("did",[])),3)
                self.assertTrue(block["when"] and block["about"])
        self.assertEqual(len(json.loads(rows[1]["result"]["content"][0]["text"])["days"]),1)
        # claude/mcp-prompts-1003: a bad argument is an isError result with the arguments that work.
        self.assertTrue(rows[2]["result"]["isError"]); self.assertIn("Use today, yesterday",rows[2]["result"]["content"][0]["text"])
        concise = rows[3]["result"]["content"][0]["text"]
        self.assertTrue(concise.startswith("**Recap:")); self.assertIn("How to answer:",concise); self.assertNotIn("macmem://",concise)
        text = rows[0]["result"]["content"][0]["text"]
        self.assertNotIn("macmem://",text); self.assertNotIn("demo-",text)

    def test_every_turn_failed_dispatch_revocation_and_budget(self):
        calls = []
        def dispatch(**request):
            calls.append(request)
            if request["user_request"] == "fail":
                raise RuntimeError("synthetic dispatch failure")
            return request
        # Synthetic tokenizer counts UTF-8 bytes. Production hosts must supply
        # their model's actual tokenizer; this test does not certify one.
        host = adapter.MacMemHost(CLI,self.home,"test-host","synthetic-local",self.token(),lambda t:len(t.encode()),dispatch)
        host.request("first"); host.request("warm continuation")
        with self.assertRaises(RuntimeError): host.request("fail")
        host.request("retry")
        self.assertEqual(len(calls),4)
        for row in calls: self.assertLessEqual(len(row["memory_evidence"].encode()),400)
        self.run_cli("--client","test-host","--recipient","synthetic-local","revoke")
        result = host.request("after revocation")
        self.assertNotIn("demo-request",result["memory_evidence"])
        self.assertIn("unavailable",result["memory_evidence"])

    def test_delete_between_prepare_and_validate(self):
        host = adapter.MacMemHost(CLI,self.home,"test-host","synthetic-local",self.token(),lambda t:len(t.encode()),lambda **request:request)
        original = host._read
        def interleaved(verb, deadline):
            result = original(verb, deadline)
            if verb == "context": self.run_cli("delete","demo-request")
            return result
        host._read = interleaved
        result = host.request("after prepared evidence was deleted")
        self.assertNotIn("demo-request",result["memory_evidence"])
        self.assertIn("unavailable",result["memory_evidence"])


if __name__ == "__main__": unittest.main()
