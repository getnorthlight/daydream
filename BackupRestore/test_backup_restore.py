"""Synthetic schema only. Does not open a personal store or claim core wiring."""
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

from backup_restore import export_backup, restore_preview, digest, encoded, Limits, Rejected


DDL = {
    "records": "CREATE TABLE records(id TEXT PRIMARY KEY, body TEXT NOT NULL, revision TEXT NOT NULL)",
    "notes": "CREATE TABLE notes(id TEXT PRIMARY KEY, body TEXT NOT NULL)",
    "members": "CREATE TABLE members(note TEXT REFERENCES notes(id), action TEXT REFERENCES records(id))",
    "days": "CREATE TABLE days(day TEXT, note TEXT REFERENCES notes(id))",
    "corrections": "CREATE TABLE corrections(id TEXT PRIMARY KEY, action TEXT REFERENCES records(id), body TEXT)",
    "tombstones": "CREATE TABLE tombstones(id TEXT PRIMARY KEY)",
    "originals": "CREATE TABLE originals(id TEXT PRIMARY KEY, body TEXT, hash TEXT)",
    "assets": "CREATE TABLE assets(action TEXT REFERENCES records(id), hash TEXT)",
    "settings": "CREATE TABLE settings(id TEXT PRIMARY KEY, body TEXT)",
}
SAFE_SETTINGS = {"policyRevision", "deletionRevision", "correctionRevision", "excludedApps"}


class SyntheticCore:
    def __init__(self):
        self.assets = {digest(b"synthetic local attachment"): b"synthetic local attachment"}
        self.deleted = set()
        self.policy = "p1"
        self.corrections = {}
        self.interrupt = False

    def export(self, source, clean, budget):
        for table, ddl in DDL.items():
            budget.check()
            clean.execute(ddl)
            for row in source.execute("SELECT * FROM " + table):
                if table == "settings" and row[0] not in SAFE_SETTINGS:
                    continue
                clean.execute("INSERT INTO " + table + " VALUES(" + ",".join("?" for _ in row) + ")", row)
        if self.interrupt:
            raise Rejected("synthetic interruption")
        return dict(self.assets)

    def inspect(self, db, budget):
        budget.check()
        tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if tables != set(DDL):
            raise Rejected("incompatible synthetic schema")
        for table, ddl in DDL.items():
            if db.execute("SELECT sql FROM sqlite_master WHERE name=?", (table,)).fetchone()[0] != ddl:
                raise Rejected("incompatible schema")
        if db.execute("SELECT count(*) FROM sqlite_master WHERE type IN ('trigger','view')").fetchone()[0]:
            raise Rejected("unexpected executable schema")
        settings = dict(db.execute("SELECT * FROM settings"))
        if set(settings) != SAFE_SETTINGS:
            raise Rejected("unsafe settings")
        for body, hash_value in db.execute("SELECT body, hash FROM originals"):
            if digest(body.encode()) != hash_value:
                raise Rejected("original changed")
        if db.execute("SELECT count(*) FROM records JOIN tombstones USING(id)").fetchone()[0]:
            raise Rejected("deleted action resurrected")
        return {"schema": "synthetic-v1", "build": "fixture-build", "version": "1",
                "counts": {t: db.execute("SELECT count(*) FROM " + t).fetchone()[0] for t in DDL},
                "policyRevision": settings["policyRevision"], "deletionRevision": settings["deletionRevision"],
                "correctionRevision": settings["correctionRevision"],
                "assets": sorted({r[0] for r in db.execute("SELECT hash FROM assets")}),
                "privacy": {k: False for k in ("credentials", "grants", "capture", "deviceAuthorizations", "remote", "cloud")}}

    def reconcile(self, db, budget):
        conflicts = []
        for id in self.deleted:
            if db.execute("SELECT 1 FROM records WHERE id=?", (id,)).fetchone():
                conflicts.append("newer-deletion:" + id)
            # Real core must also reconcile note contents and policy exclusions.
            notes = [r[0] for r in db.execute("SELECT note FROM members WHERE action=?", (id,))]
            for note in notes:
                db.execute("DELETE FROM days WHERE note=?", (note,))
                db.execute("DELETE FROM members WHERE note=?", (note,))
                db.execute("DELETE FROM notes WHERE id=?", (note,))
            for table, column in [("corrections", "action"), ("assets", "action"), ("records", "id"), ("originals", "id")]:
                db.execute("DELETE FROM " + table + " WHERE " + column + "=?", (id,))
            db.execute("INSERT OR IGNORE INTO tombstones VALUES(?)", (id,))
        for id, body in self.corrections.items():
            db.execute("UPDATE corrections SET body=? WHERE id=?", (body, id))
            conflicts.append("newer-correction:" + id)
        if self.deleted:
            db.execute("UPDATE settings SET body='d2' WHERE id='deletionRevision'")
        if self.corrections:
            db.execute("UPDATE settings SET body='c2' WHERE id='correctionRevision'")
        previous = db.execute("SELECT body FROM settings WHERE id='policyRevision'").fetchone()[0]
        if previous != self.policy:
            # Fixture cannot prove new exclusion policy, so block rather than guess.
            raise Rejected("policy reconciliation required")
        return {"authorityRevision": "current-authority-1", "conflicts": conflicts, "originalsVerified": True}


class Backups(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mac-mem-backup-synthetic-")
        self.root = Path(self.temp.name).resolve()
        self.core = SyntheticCore()
        self.db = sqlite3.connect(self.root / "source.sqlite")
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA wal_autocheckpoint=0")
        for ddl in DDL.values():
            self.db.execute(ddl)
        for id in ("a", "b", "import"):
            body = "immutable synthetic original " + id
            self.db.execute("INSERT INTO records VALUES(?,?,?)", (id, body, digest(body.encode())))
            self.db.execute("INSERT INTO originals VALUES(?,?,?)", (id, body, digest(body.encode())))
        self.db.executemany("INSERT INTO notes VALUES(?,?)", [("n1", "actions a and b"), ("n2", "imported action")])
        self.db.executemany("INSERT INTO members VALUES(?,?)", [("n1", "a"), ("n1", "b"), ("n2", "import")])
        self.db.executemany("INSERT INTO days VALUES(?,?)", [("2026-09-11", "n1"), ("2026-09-11", "n2")])
        self.db.execute("INSERT INTO corrections VALUES('c1','a','edited description')")
        self.db.execute("INSERT INTO tombstones VALUES('previously-deleted')")
        self.db.execute("INSERT INTO assets VALUES('import',?)", (next(iter(self.core.assets)),))
        self.db.executemany("INSERT INTO settings VALUES(?,?)", [("policyRevision", "p1"), ("deletionRevision", "d1"),
            ("correctionRevision", "c1"), ("excludedApps", "[]"), ("capture", "recording"), ("apiKey", "DO-NOT-EXPORT"), ("remote", "on")])
        self.db.execute("CREATE TABLE grants(secret TEXT)")
        self.db.execute("INSERT INTO grants VALUES('DO-NOT-EXPORT')")
        self.db.commit()
        self.limits = Limits(bytes=2 * 1024 * 1024, reserve=0)

    def tearDown(self):
        self.db.close()
        self.temp.cleanup()

    def backup(self, name="backup"):
        return export_backup(self.db, self.root / name, self.core, self.limits)

    def restore(self, receipt, name="restored"):
        return restore_preview(self.root / "backup", self.root / name, receipt["manifestSHA256"], self.core, self.limits)

    def test_roundtrip_wal_relationships_originals_corrections_assets_privacy(self):
        self.assertGreater((self.root / "source.sqlite-wal").stat().st_size, 0)
        receipt = self.backup()
        preview = self.restore(receipt)
        self.assertFalse(preview["adoptable"])
        self.assertEqual(preview["before"], preview["after"])
        other = sqlite3.connect(self.root / "restored/database.sqlite")
        try:
            for table in DDL:
                if table == "settings":
                    continue
                self.assertEqual(self.db.execute("SELECT * FROM " + table).fetchall(), other.execute("SELECT * FROM " + table).fetchall())
            self.assertEqual(other.execute("PRAGMA foreign_key_check").fetchall(), [])
        finally:
            other.close()
        for file in (self.root / "backup").iterdir():
            self.assertNotIn(b"DO-NOT-EXPORT", file.read_bytes())
        for hash_value, value in self.core.assets.items():
            self.assertEqual((self.root / "restored" / ("asset-" + hash_value)).read_bytes(), value)
        self.assertEqual(self.db.execute("SELECT * FROM grants").fetchall(), [("DO-NOT-EXPORT",)])

    def test_current_deletion_correction_policy_reconciliation(self):
        receipt = self.backup()
        original = (self.root / "backup/database.sqlite").read_bytes()
        self.core.deleted = {"b"}
        self.core.corrections = {"c1": "newer correction"}
        preview = self.restore(receipt)
        self.assertEqual(preview["after"]["counts"]["records"], 2)
        db = sqlite3.connect(self.root / "restored/database.sqlite")
        self.assertEqual(db.execute("SELECT body FROM corrections").fetchone()[0], "newer correction")
        self.assertEqual(db.execute("SELECT count(*) FROM notes WHERE id='n1'").fetchone()[0], 0)
        db.close()
        self.assertEqual((self.root / "backup/database.sqlite").read_bytes(), original)
        self.core.policy = "new-policy"
        with self.assertRaises(Rejected): self.restore(receipt, "policy-blocked")
        self.assertFalse((self.root / "policy-blocked").exists())

    def test_interrupt_retry_and_overwrite(self):
        self.core.interrupt = True
        with self.assertRaises(Rejected): self.backup()
        self.assertFalse((self.root / "backup/manifest.json").exists())
        self.core.interrupt = False
        with self.assertRaises(FileExistsError): self.backup()
        self.backup("retry")
        with self.assertRaises(FileNotFoundError): self.restore({"manifestSHA256": "0" * 64})

    def test_corruption_partial_and_extra_files(self):
        receipt = self.backup()
        file = self.root / "backup/database.sqlite"
        original = file.read_bytes()
        file.write_bytes(b"corrupt")
        with self.assertRaises(Rejected): self.restore(receipt)
        file.write_bytes(original)
        (self.root / "backup/extra").write_text("unlisted")
        with self.assertRaises(Rejected): self.restore(receipt)

    def test_malicious_paths_and_symlinks(self):
        receipt = self.backup()
        raw = receipt["manifest"]
        raw["files"]["../escape"] = {"bytes": 0, "sha256": digest(b"")}
        content = encoded(raw)
        (self.root / "backup/manifest.json").write_bytes(content)
        with self.assertRaises(Rejected): self.restore({"manifestSHA256": digest(content)})
        (self.root / "linked").symlink_to(self.root / "backup", target_is_directory=True)
        with self.assertRaises(OSError): restore_preview(self.root / "linked", self.root / "restore", "0" * 64, self.core, self.limits)

    def test_low_disk_and_deadline(self):
        with patch("backup_restore.os.fstatvfs") as space:
            space.return_value.f_bavail = 0
            space.return_value.f_frsize = 4096
            with self.assertRaises(Rejected): self.backup()
        self.assertFalse((self.root / "backup").exists())
        with self.assertRaises(Rejected): export_backup(self.db, self.root / "timeout", self.core, Limits(seconds=-1))

    def test_incompatible_schema_manifest_and_privacy(self):
        receipt = self.backup()
        receipt["manifest"]["format"] = "future"
        raw = encoded(receipt["manifest"])
        (self.root / "backup/manifest.json").write_bytes(raw)
        with self.assertRaises(Rejected): self.restore({"manifestSHA256": digest(raw)})
        self.core.inspect = lambda db, budget: {"privacy": {"capture": True}}
        with self.assertRaises(Rejected): self.backup("unsafe")

    def test_missing_asset_and_unknown_reconciliation(self):
        self.core.assets = {}
        with self.assertRaises(Rejected): self.backup()
        self.core = SyntheticCore()
        receipt = self.backup("second")
        self.core.reconcile = lambda db, budget: None
        with self.assertRaises(Rejected): restore_preview(self.root / "second", self.root / "restore", receipt["manifestSHA256"], self.core, self.limits)

    def test_asset_symlink_hardlink_and_restore_overwrite(self):
        receipt = self.backup()
        self.restore(receipt)
        with self.assertRaises(FileExistsError): self.restore(receipt)
        asset = self.root / "backup" / ("asset-" + next(iter(self.core.assets)))
        original = asset.read_bytes()
        outside = self.root / "outside"
        outside.write_bytes(original)
        asset.unlink()
        asset.symlink_to(outside)
        with self.assertRaises(OSError): self.restore(receipt, "symlink-restore")
        asset.unlink()
        os.link(outside, asset)
        with self.assertRaises(Rejected): self.restore(receipt, "hardlink-restore")

    def test_rehashed_invalid_schema_and_changed_original(self):
        receipt = self.backup()
        db_path = self.root / "backup/database.sqlite"
        original = db_path.read_bytes()
        for sql in ["CREATE TABLE unexpected(id TEXT)", "UPDATE originals SET body='tampered'"]:
            db_path.write_bytes(original)
            db = sqlite3.connect(db_path)
            db.execute(sql)
            db.commit()
            db.close()
            payload = db_path.read_bytes()
            receipt["manifest"]["files"]["database.sqlite"] = {"bytes": len(payload), "sha256": digest(payload)}
            manifest = encoded(receipt["manifest"])
            (self.root / "backup/manifest.json").write_bytes(manifest)
            with self.assertRaises(Rejected): self.restore({"manifestSHA256": digest(manifest)})

    def test_write_interruption_and_fresh_retry(self):
        import backup_restore
        real_write = backup_restore.write
        def interrupted(fd, name, data, budget):
            if name == "manifest.json":
                raise OSError("synthetic disk full")
            return real_write(fd, name, data, budget)
        with patch("backup_restore.write", side_effect=interrupted):
            with self.assertRaises(OSError): self.backup()
        self.assertTrue((self.root / "backup/database.sqlite").exists())
        self.assertFalse((self.root / "backup/manifest.json").exists())
        receipt = self.backup("fresh")
        restore_preview(self.root / "fresh", self.root / "preview", receipt["manifestSHA256"], self.core, self.limits)

    def test_snapshot_size_bound_and_duplicate_manifest_fields(self):
        with self.assertRaises(Rejected): export_backup(self.db, self.root / "tiny", self.core, Limits(bytes=4096, reserve=0))
        receipt = self.backup()
        path = self.root / "backup/manifest.json"
        raw = path.read_bytes()
        raw = b'{"encrypted":true,' + raw[1:]
        path.write_bytes(raw)
        with self.assertRaises(Rejected): self.restore({"manifestSHA256": digest(raw)})


if __name__ == "__main__":
    unittest.main()
