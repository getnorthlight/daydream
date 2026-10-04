"""Actual CLI/MCP over bounded loopback HTTP with synthetic stores only."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest
import uuid
from datetime import datetime, timedelta, timezone
import migration_export
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CLI = os.environ["MACMEM_TEST_CLI"]


class SearchInterfaces(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="macmem-search-interface-")
        self.home = Path(self.temp.name).resolve()
        self.docs = {}
        self.exists = False
        self.mode = "normal"
        self.after_search = None
        self.requests = []
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, code, body):
                data = body if isinstance(body, bytes) else json.dumps(body).encode()
                self.send_response(code)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                try:
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def do_GET(self):
                fixture.requests.append(self.path)
                if "/documents/search?" in self.path:
                    if fixture.mode == "redirect":
                        self.send_response(302)
                        self.send_header("Location", "/must-not-follow")
                        self.end_headers()
                        return
                    if fixture.mode == "oversized":
                        self.send_response(200)
                        self.send_header("Content-Length", "1000000")
                        self.end_headers()
                        return
                    if fixture.mode == "slow":
                        time.sleep(1.2)
                    if fixture.after_search:
                        fixture.after_search()
                    return self.reply(200, {"found": len(fixture.docs), "hits": [
                        {"document": {"source_id": d["source_id"], "revision": d["revision"],
                                      "summary": "NEVER TRUST INDEX CONTENT"}} for d in fixture.docs.values()]})
                self.reply(200 if fixture.exists else 404, {})

            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                if self.path == "/collections":
                    fixture.exists = True
                    return self.reply(201, {})
                rows = [json.loads(line) for line in body.splitlines()]
                for row in rows:
                    fixture.docs[row["id"]] = row
                self.reply(200, b"\n".join(b'{"success":true}' for _ in rows))

            def do_DELETE(self):
                fixture.docs.pop(self.path.rsplit("/", 1)[-1], None)
                self.reply(200, {})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.cli("demo")
        for name in ("search.key", "sync.key"):
            path = self.home / name
            path.write_text(str(uuid.uuid4()))
            path.chmod(0o600)
        config = self.cli("--local", "search-config")
        config.update(enabled=True, port=self.server.server_port)
        path = self.home / "search-typesense.json"
        path.write_text(json.dumps(config)); path.chmod(0o600)
        self.cli("--local", "search-sync")

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join()
        self.temp.cleanup()

    def cli(self, *args):
        result = subprocess.run([CLI, "--home", str(self.home), *args], text=True, capture_output=True, timeout=10)
        if result.returncode:
            raise AssertionError(result.stderr)
        return json.loads(result.stdout)

    def mcp(self, token="", recipient="test-model"):
        request = {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                   "params": {"name": "search", "arguments": {"query": "Search", "response_format": "detailed"}}}
        result = subprocess.run([CLI, "--home", str(self.home), "--client", "search-tests", "--recipient", recipient, "mcp"],
                                input=json.dumps(request)+"\n", text=True, capture_output=True, timeout=10,
                                env={**os.environ, "MAC_MEM_CAPABILITY": token})
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    @staticmethod
    def refused(reply):
        # claude/mcp-prompts-1003: a refused tool call is an isError tool result, not a JSON-RPC error.
        return "error" in reply or reply.get("result", {}).get("isError") is True

    def grant(self):
        return self.cli("--client", "search-tests", "--recipient", "test-model", "grant")["capability"]

    def test_cli_and_mcp_shared_source_validated_results(self):
        report = self.cli("--local", "--search-report", "search", "Search")
        self.assertEqual(report["backend"], "typesense")
        self.assertEqual(report["status"], "ready")
        self.assertTrue(report["hits"])
        self.assertNotIn("NEVER TRUST", json.dumps(report))
        result = json.loads(self.mcp(self.grant())["result"]["content"][0]["text"])
        self.assertEqual(result["hits"], report["hits"])
        self.assertNotIn("evidence", result["hits"][0])
        # CLI's original array stdout is retained.
        self.assertEqual(self.cli("--local", "search", "Search"), report["hits"])

    def test_staged_legacy_actions_feed_index_without_indexing_old_notes(self):
        root=self.home
        self.home=root/"import-target"
        self.docs.clear(); self.exists=False
        at=datetime.now(timezone.utc).isoformat()
        events=root/"events.jsonl"; meta=root/"metadata.json"; episodes=root/"episodes.jsonl"
        events.write_text("\n".join(json.dumps({"id":n,"timestamp":at,"kind":"mouse.click","app":{"name":"TextEdit","bundleIdentifier":"com.apple.TextEdit","secureInput":False},"window":{"title":"Distinct orchard action "+str(n)}}) for n in range(5)))
        meta.write_text(json.dumps({"sessionID":"fixture","segmentID":"five","startedAt":at,"endedAt":at,"eventCount":5,"suppressedEventCount":0}))
        historical=(datetime.now(timezone.utc)-timedelta(days=7)).isoformat()
        episodes.write_text(json.dumps({"source_id":"old-note","start":historical,"end":historical,"primary_app":"TextEdit","summary":"Historical orchard overview, never an observation"}))
        plan=root/"plan.json"
        plan.write_text(json.dumps({"version":1,"namespace":"search-import-fixture","deletionsReviewed":True,"deletions":{"noneConfirmed":True},"sources":[{"format":"history-segment-v1","path":str(events),"metadata":str(meta)},{"format":"horizon-episodes-v1","path":str(episodes)}]}))
        exported=migration_export.export(plan,root/"export")
        self.cli("--local","migration-init")
        view=self.cli("--local","migration-stage-prepare","--snapshot",str(root/"export/snapshot.json"),"--snapshot-sha256",exported["snapshotSHA256"],"--staging-home",str(root/"stage"))
        ident=view["id"]
        self.cli("--local","migration-stage-step","--import-id",ident,"--confirm-import")
        self.cli("--local","migration-adoption-review","--import-id",ident)
        receipt=self.cli("--local","migration-adoption-confirm","--import-id",ident,"--confirm-import")
        self.assertEqual(len(receipt["actionIDs"]),5)
        self.assertEqual(len(self.cli("--local","search","orchard")),5,"immediate SQLite path before index")
        for name in ("search.key","sync.key"):
            key=self.home/name; key.write_text(str(uuid.uuid4())); key.chmod(0o600)
        config=self.cli("--local","search-config"); config.update(enabled=True,port=self.server.server_port)
        file=self.home/"search-typesense.json";file.write_text(json.dumps(config));file.chmod(0o600)
        self.cli("--local","search-sync")
        self.assertEqual(len(self.docs),5)
        self.assertNotIn("Historical orchard",json.dumps(self.docs))
        report=self.cli("--local","--search-report","search","orchard")
        self.assertEqual(report["backend"],"typesense");self.assertEqual(len(report["hits"]),5)
        self.cli("--local","search-sync");self.assertEqual(len(self.docs),5)
        self.cli("--local","delete",receipt["actionIDs"][0])
        self.assertEqual(len(self.cli("--local","search","orchard")),4,"stale index hit cannot disclose deleted source")
        self.cli("--local","search-sync");self.assertEqual(len(self.docs),4)

    def test_recipient_and_revocation_during_request(self):
        token = self.grant()
        self.assertTrue(self.refused(self.mcp(token, recipient="other-model")))
        self.after_search = lambda: self.cli("--client", "search-tests", "--recipient", "test-model", "revoke")
        self.assertTrue(self.refused(self.mcp(token)))
        self.after_search = None
        count = len(self.requests)
        self.assertTrue(self.refused(self.mcp(token)))
        self.assertEqual(len(self.requests), count, "revoked request must not reach index")

    def test_deletion_during_request(self):
        self.after_search = lambda: self.cli("delete", "demo-search")
        result = self.cli("--local", "--search-report", "search", "Search")
        self.assertEqual(result["status"], "source_changed_retry")
        self.assertEqual(result["hits"], [])

    def test_transport_bounds_no_redirect_or_key_forwarding(self):
        for mode in ("redirect", "oversized", "slow"):
            self.mode = mode
            start = time.monotonic()
            report = self.cli("--local", "--search-report", "search", "Search")
            self.assertEqual(report["status"], "unavailable_fallback", mode)
            self.assertLess(time.monotonic()-start, 1.5, mode)
        self.assertFalse(any("must-not-follow" in path for path in self.requests))

    def test_filters_and_invalid_sync_authority(self):
        report = self.cli("--local", "--app", "nonexistent", "--search-report", "search", "Search")
        self.assertEqual(report["hits"], [])
        result = subprocess.run([CLI, "--home", str(self.home), "search-rebuild"], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.docs)


if __name__ == "__main__":
    unittest.main()
