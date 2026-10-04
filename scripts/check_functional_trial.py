"""Inert synthetic packaging tests. No signing or packaged code execution."""
import importlib.util
import json
import plistlib
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("functional_trial", Path(__file__).with_name("functional_trial.py"))
f = importlib.util.module_from_spec(spec)
spec.loader.exec_module(f)

class Checks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="daydream-functionalTrial-", dir="/private/tmp")
        self.addCleanup(self.tmp.cleanup)
        self.app = Path(self.tmp.name) / "DayDream.app"
        self.c = self.app / "Contents"
        for d in ("MacOS", "Helpers", "Resources"):
            (self.c / d).mkdir(parents=True, exist_ok=True)
        (self.c / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.getnorthlight.daydream"}))
        for name in ("MacOS/MacMem", "MacOS/mac-mem", "MacOS/mac-mem-backup", f.SERVER):
            (self.c / name).write_bytes(b"synthetic NOT executable code")
            (self.c / name).chmod(0o755)
        for name in (*f.NOTICES, "Resources/before_turn.py"):
            (self.c / name).write_text("synthetic")
        (self.c / "Resources/Companions.json").write_text(json.dumps({"sha256": {
            name: "old" for name in ("MacOS/mac-mem", "MacOS/mac-mem-backup", "Resources/before_turn.py")}}))

    def test_final_hashes_and_tamper(self):
        f.manifests(self.app, True)
        f.manifests(self.app, False)
        (self.c / "MacOS/mac-mem").write_bytes(b"new signed bytes")
        with self.assertRaisesRegex(ValueError, "Stale search"):
            f.manifests(self.app, False)
        f.manifests(self.app, True)
        f.manifests(self.app, False)

    def test_missing_server(self):
        (self.c / f.SERVER).unlink()
        with self.assertRaisesRegex(ValueError, "Missing/unsafe"):
            f.manifests(self.app, True)

    def test_missing_writer(self):
        with self.assertRaisesRegex(ValueError, "Missing Phone/root"):
            f.writer(self.app, None)

    def test_incomplete_source_review(self):
        review = self.c / "Resources/review.json"
        review.write_text(json.dumps({"completeCorrespondingSource": False}))
        with self.assertRaisesRegex(ValueError, "Incomplete Typesense"):
            f.distribution_review(review, self.c / f.NOTICES[0], self.c / f.NOTICES[1])

    def test_dev_rejected(self):
        (self.c / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.getnorthlight.daydream", "DaydreamDevelopmentTrial": True}))
        with self.assertRaisesRegex(ValueError, "OFF guard"):
            f.normal(self.app)

    def test_sealed_refresh_refused(self):
        (self.c / "_CodeSignature").mkdir()
        with self.assertRaisesRegex(ValueError, "UNSEALED"):
            f.manifests(self.app, True)

    def test_link_refused(self):
        (self.c / f.SERVER).unlink()
        (self.c / f.SERVER).symlink_to(self.c / "MacOS/mac-mem")
        with self.assertRaisesRegex(ValueError, "Missing/unsafe"):
            f.manifests(self.app, True)

    def test_escape_refused(self):
        with self.assertRaisesRegex(ValueError, "Unsafe"):
            f.contained(self.c, "../outside")

    def test_writable_refused(self):
        (self.c / f.SERVER).chmod(0o777)
        with self.assertRaisesRegex(ValueError, "Writable"):
            f.manifests(self.app, True)

if __name__ == "__main__":
    unittest.main()
