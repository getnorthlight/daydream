"""Safety checks for the new manifest reader, never a release acceptance pass."""
import hashlib
from pathlib import Path
import tempfile
import unittest
from independent_candidate import source_files


class CandidateManifestChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="macmem-manifest-fixture-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.file = self.root / "Package.swift"
        self.file.write_text("// fabricated manifest fixture\n")
        self.digest = hashlib.sha256(self.file.read_bytes()).hexdigest()

    def test_exact_bytes_and_corruption(self):
        manifest = {"source_files":{"Package.swift":self.digest}}
        source_files(self.root, manifest)
        self.file.write_text("// changed\n")
        with self.assertRaises(ValueError):
            source_files(self.root, manifest)

    def test_escape_and_missing_inventory(self):
        for manifest in ({}, {"files":{}}, {"files":{"Package.swift":self.digest,"../outside":"0"*64}},
                         {"files":{"Package.swift":self.digest,"/absolute":"0"*64}}):
            with self.subTest(manifest=manifest), self.assertRaises(ValueError):
                source_files(self.root, manifest)

    def test_invalid_digest(self):
        for digest in (None, "", "z"*64, {"other":"0"*64}):
            with self.subTest(digest=digest), self.assertRaises(ValueError):
                source_files(self.root, {"files":{"Package.swift":digest}})


if __name__ == "__main__":
    unittest.main()
