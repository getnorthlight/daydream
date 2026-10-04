"""Real CLI, fabricated SQLite rows. Does not certify capture or ingestion."""
import base64
from contextlib import closing
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time
import unittest


class IndependentRecall(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="macmem-independent-recall-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.cli("demo")
        with closing(sqlite3.connect(self.home / "memory.sqlite")) as db, db:
            db.execute("DELETE FROM records")
            db.execute("DELETE FROM summaries")

    def cli(self, *args):
        p = subprocess.run([os.environ["MACMEM_TEST_CLI"], "--home", str(self.home),
                            "--local", *args], capture_output=True, text=True, timeout=5)
        self.assertEqual(p.returncode, 0, p.stderr)
        return json.loads(p.stdout)

    def put(self, age):
        now = datetime.now(timezone.utc)
        row = dict(id="independent-recall", at=(now-timedelta(seconds=age)).isoformat(),
                   kind="mouse.click", app="TextEdit", bundle="com.apple.TextEdit",
                   title="IndependentRecallMarker", url="", text="", secure=False,
                   privateWindow=False, synthetic=True)
        with closing(sqlite3.connect(self.home / "memory.sqlite")) as db, db:
            db.execute("INSERT OR REPLACE INTO records VALUES(?,?,?)", (row["id"], json.dumps(row), str(age)))
            db.execute("INSERT OR REPLACE INTO metadata VALUES('capture',?)",
                       (json.dumps(dict(state="recording", checked_at=now.isoformat())),))

    def test_recent_ten_seconds_without_writer_or_index(self):
        for age in (0, 9.5):
            with self.subTest(age=age):
                self.put(age)
                started = time.monotonic()
                hits = self.cli("search", "IndependentRecallMarker")
                self.assertIn("independent-recall", [row["id"] for row in hits])
                current = self.cli("current-context")
                self.assertEqual(current["status"], "recent_observations")
                self.assertIn("independent-recall", [row["id"] for row in current["actions"]])
                self.assertLess(time.monotonic()-started, 10)

    def test_pause_restart_delete_and_no_cross_store(self):
        self.put(0)
        with closing(sqlite3.connect(self.home / "memory.sqlite")) as db, db:
            db.execute("UPDATE metadata SET body=? WHERE id='capture'",
                       (json.dumps(dict(state="paused", checked_at=datetime.now(timezone.utc).isoformat())),))
        # Every CLI invocation is a fresh process. Stored pause survives restart.
        for _ in range(2):
            current = self.cli("current-context")
            self.assertEqual(current["status"], "capture_paused")
            self.assertEqual(current["actions"], [])
        uri = "macmem://actions/" + base64.urlsafe_b64encode(b"independent-recall").decode().rstrip("=") + ".json"
        self.assertEqual(self.cli("open", uri)["id"], "independent-recall")
        self.cli("delete", "independent-recall")
        self.assertIsNone(self.cli("open", uri))
        self.assertEqual(self.cli("search", "IndependentRecallMarker"), [])
        self.home = self.home / "separate-store"
        self.cli("demo")
        self.assertEqual(self.cli("search", "IndependentRecallMarker"), [])


if __name__ == "__main__":
    unittest.main()
