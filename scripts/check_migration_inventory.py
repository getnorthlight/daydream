"""Only fabricated local sources; no default history paths."""
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from migration_inventory import inventory, MigrationError


class InventoryChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="migration-counts-synthetic-")
        self.root = Path(self.temp.name).resolve()

    def tearDown(self):
        self.temp.cleanup()

    def test_activity_counts_without_content(self):
        path = self.root / "archive.sqlite"
        with sqlite3.connect(path) as db:
            db.execute("CREATE TABLE document(doc_id,source,source_id,kind,ts,title,body,uri,extra)")
            db.executemany("INSERT INTO document VALUES(?,?,?,?,?,?,?,?,?)", [(str(n), source, str(n), "activity", "now", "PRIVATE TITLE", "PRIVATE BODY", "PRIVATE URI", "{}") for n, source in enumerate(["activity", "activity", "mail"])])
        before = path.read_bytes()
        result = inventory("horizon-activity-sqlite-v1", str(path))
        self.assertEqual(result["activityRows"], 2)
        self.assertNotIn("PRIVATE", json.dumps(result))
        self.assertFalse(result["contentValidated"])
        self.assertEqual(before, path.read_bytes())

    def test_closed_segment_counts_and_no_export(self):
        events, meta = self.root / "events", self.root / "metadata"
        events.write_text('{"private":"not emitted"}\n\n{}\n')
        meta.write_text(json.dumps({"endedAt":"now", "sessionID":"private", "segmentID":"private", "eventCount":2, "suppressedEventCount":3}))
        result = inventory("history-segment-v1", str(events), str(meta))
        self.assertEqual(result["nonemptyLines"], 2)
        self.assertEqual(result["suppressedEvents"], 3)
        self.assertFalse(result["contentValidated"])
        self.assertEqual(len(list(self.root.iterdir())), 2)
        meta.write_text('{}')
        with self.assertRaises(MigrationError): inventory("history-segment-v1", str(events), str(meta))

    def test_links_and_unsupported_schema_fail(self):
        path = self.root / "db"
        with sqlite3.connect(path) as db:
            db.execute("CREATE VIEW document AS SELECT 'activity' AS source")
        with self.assertRaises(MigrationError): inventory("horizon-activity-sqlite-v1", str(path))
        link = self.root / "linked"
        link.symlink_to(path)
        with self.assertRaises(MigrationError): inventory("horizon-activity-sqlite-v1", str(link))


if __name__ == "__main__":
    unittest.main()
