"""Production CLI and MCP, fabricated stores only. No provider/collector/index."""
import base64
from contextlib import closing
from datetime import datetime, timezone, timedelta
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest
from urllib.parse import urlencode

CLI=os.environ["MACMEM_TEST_CLI"]


class ActionResources(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix="macmem-action-resource-")
        self.home=Path(self.temp.name)
        self.cli("demo")
        self.now=datetime.now(timezone.utc)
        self.day=self.now.strftime("%Y-%m-%d")
        with closing(sqlite3.connect(self.home/"memory.sqlite")) as db, db:
            db.execute("DELETE FROM records"); db.execute("DELETE FROM summaries")
            for n in range(65):
                value={"id":f"fixture-{n:03d}","at":self.now.isoformat(),"kind":"mouse.click","app":"TextEdit","bundle":"com.apple.TextEdit","title":"Research" if n%2 else "Status check","url":"","text":"","secure":False,"privateWindow":False,"synthetic":True}
                db.execute("INSERT INTO records VALUES(?,?,?)",(value["id"],json.dumps(value),str(n)))
        self.token=self.cli("--client","fixture","--recipient","local-test","grant")["capability"]
        self.proc=None

    def tearDown(self):
        if self.proc:
            self.proc.stdin.close(); self.proc.wait(timeout=5)
            self.proc.stdout.close(); self.proc.stderr.close()
        self.temp.cleanup()

    def cli(self,*args):
        result=subprocess.run([CLI,"--home",str(self.home),"--local",*args],capture_output=True,text=True,timeout=15)
        self.assertEqual(result.returncode,0,result.stderr)
        return json.loads(result.stdout)

    def send(self,method,params=None):
        if not self.proc:
            self.proc=subprocess.Popen([CLI,"--home",str(self.home),"--client","fixture","--recipient","local-test","mcp"],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env={**os.environ,"MAC_MEM_CAPABILITY":self.token,"DAYDREAM_MCP_TOOLSET":"legacy"})  # agent-tools v2: these pin the 0.1.4 tools (resources, current-context)
        self.proc.stdin.write(json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params or {}})+"\n"); self.proc.stdin.flush()
        return json.loads(self.proc.stdout.readline())

    def resource(self,uri):
        reply=self.send("resources/read",{"uri":uri})
        self.assertIn("result",reply)
        return json.loads(reply["result"]["contents"][0]["text"])

    def uri(self,ident):
        return "macmem://actions/"+base64.urlsafe_b64encode(ident.encode()).decode().rstrip("=")+".json"

    def test_day_pagination_and_activity_links_keep_all_actions(self):
        after=None; ids=[]; activities=set()
        while True:
            query={"timezone":"UTC"}
            if after: query["after"]=after
            result=self.resource("macmem://days/"+self.day+".json?"+urlencode(query))
            self.assertEqual(result["summary"]["actionCount"],65)
            self.assertEqual(result["summary"]["status"],"pending")
            self.assertLessEqual(len(result["actions"]["actions"]),20)
            ids += [a["id"] for a in result["actions"]["actions"]]
            activities.update(result["activities"])
            after=result["actions"].get("next")
            if not after: break
        self.assertEqual(len(ids),65); self.assertEqual(len(set(ids)),65)
        self.assertEqual(len(activities),2)
        for uri in activities:
            result=self.resource(uri)
            self.assertIn(result["actionCount"],(32,33))
            self.assertLessEqual(len(result["activity"]["actionIDs"]),20)
        action=self.resource(self.uri(ids[0]))
        self.assertEqual(action["id"],ids[0]); self.assertNotIn("evidence",action)
        self.assertEqual(action["evidenceIDs"],[ids[0]])

    def test_open_and_templates_no_filesystem_capability(self):
        templates=self.send("resources/templates/list")["result"]["resourceTemplates"]
        self.assertEqual(len(templates),3)
        # claude/mcp-prompts-1003: tools answer concise Markdown by default; detailed is the JSON as before.
        reply=self.send("tools/call",{"name":"open","arguments":{"uri":self.uri("fixture-000"),"response_format":"detailed"}})
        self.assertEqual(json.loads(reply["result"]["content"][0]["text"])["id"],"fixture-000")
        for uri in ("file:///etc/passwd","macmem://actions/../../private.json","macmem://days/2026-09-11.json?timezone=UTC&timezone=America/New_York","https://example.com"):
            self.assertIn("error",self.send("resources/read",{"uri":uri}))

    def test_live_mcp_revocation_and_deletion_no_stale_resource(self):
        uri=self.uri("fixture-000")
        self.assertIsNotNone(self.resource(uri))
        self.cli("delete","fixture-000")
        self.assertIsNone(self.resource(uri))
        self.cli("--client","fixture","--recipient","local-test","revoke")
        self.assertIn("error",self.send("resources/read",{"uri":self.uri("fixture-001")}))
        # claude/mcp-prompts-1003: a tool that ran and was refused answers as an isError result the model reads.
        refused=self.send("tools/call",{"name":"current-context"})
        self.assertTrue(refused.get("result",{}).get("isError"),refused)
        self.assertIn("access for this AI app is missing",refused["result"]["content"][0]["text"])

    def test_current_context_and_pause_stale_unavailable(self):
        def state(name,at):
            with closing(sqlite3.connect(self.home/"memory.sqlite")) as db, db:
                db.execute("INSERT OR REPLACE INTO metadata VALUES('capture',?)",(json.dumps({"state":name,"checked_at":at.isoformat()}),))
        state("recording",datetime.now(timezone.utc))
        recent=self.resource("macmem://current-context")
        self.assertEqual(recent["status"],"recent_observations"); self.assertTrue(recent["actions"])
        state("paused",datetime.now(timezone.utc))
        paused=self.resource("macmem://current-context")
        self.assertEqual(paused["status"],"capture_paused"); self.assertEqual(paused["actions"],[])
        state("recording",datetime.now(timezone.utc)-timedelta(seconds=10))
        self.assertEqual(self.resource("macmem://current-context")["status"],"capture_unavailable")

    def test_current_context_continuation_uses_production_mcp(self):
        schema=self.send("tools/list")["result"]["tools"]
        current=next(t for t in schema if t["name"] == "current-context")
        self.assertIn("after",current["inputSchema"]["properties"])
        page=self.resource("macmem://current-context")
        self.assertTrue(page["truncated"])
        ids=[a["id"] for a in page["actions"]]
        while page.get("continuation"):
            reply=self.send("tools/call",{"name":"current-context","arguments":{"after":page["continuation"],"response_format":"detailed"}})
            self.assertIn("result",reply)
            page=json.loads(reply["result"]["content"][0]["text"])
            ids += [a["id"] for a in page["actions"]]
        self.assertEqual(len(ids),65)
        self.assertEqual(len(set(ids)),65)

    def test_reload_cursor_and_explicit_scope_validation(self):
        page=self.cli("--batch-limit","10","actions")
        second=self.cli("--batch-limit","10","--after",page["next"],"actions")
        self.assertEqual(len(second["actions"]),10)
        self.assertFalse(set(a["id"] for a in page["actions"]) & set(a["id"] for a in second["actions"]))
        self.cli("delete","fixture-064")
        result=subprocess.run([CLI,"--home",str(self.home),"--local","--after",page["next"],"actions"],capture_output=True)
        self.assertNotEqual(result.returncode,0)
        denied=subprocess.run([CLI,"--home",str(self.home),"--client","fixture","--recipient","wrong","open",self.uri("fixture-000")],capture_output=True,env={**os.environ,"MAC_MEM_CAPABILITY":self.token})
        self.assertNotEqual(denied.returncode,0)


if __name__ == "__main__": unittest.main()
