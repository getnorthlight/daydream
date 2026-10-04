import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("writer", Path(__file__).with_name("prepare_writer_macos15.py"))
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)

class Checks(unittest.TestCase):
    def test_exact_profile(self):
        self.assertEqual(len(w.pins()), 7)

    def test_transform(self):
        self.assertEqual(w.dependency_changes(["@rpath/libllama.0.dylib"], w.pins()),
                         [("@rpath/libllama.0.dylib", "@loader_path/libllama.0.dylib")])

    def test_system_and_local(self):
        self.assertEqual(w.dependency_changes(["/usr/lib/libSystem.B.dylib", "@loader_path/libllama.0.dylib"], w.pins()), [])

    def test_unreviewed(self):
        for name in ("@rpath/other.dylib", "/opt/homebrew/lib/foo.dylib", "/usr/lib/../bad.dylib"):
            with self.assertRaises(ValueError):
                w.dependency_changes([name], w.pins())

    def test_wrong_archive(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as tmp:
            path = Path(tmp) / "bad.tar.gz"
            path.write_bytes(b"not a runtime")
            with self.assertRaisesRegex(ValueError, "Archive pin"):
                w.read_archive(path, w.pins())

    def test_canonical_archive(self):
        licence = (Path(__file__).resolve().parents[1] / "WriterBackend/Notices/llama-MIT.txt").read_bytes()
        files = {"runtime-LICENSE": licence, **{name: name.encode() for name in w.pins()}}
        self.assertEqual(w.canonical_archive(files), w.canonical_archive(dict(reversed(list(files.items())))))
        with self.assertRaisesRegex(ValueError, "Licence"):
            w.canonical_archive({**files, "runtime-LICENSE": b"other"})
        with self.assertRaisesRegex(ValueError, "Exactly"):
            w.canonical_archive({**files, "extra.dylib": b""})

    def test_destination(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as tmp:
            parent = Path(tmp) / "parent"
            parent.mkdir(mode=0o755)
            self.assertTrue(w.private_parent(parent))
            self.assertTrue(w.private_parent(Path("/private/tmp")))  # sticky
            parent.chmod(0o777)
            self.assertFalse(w.private_parent(parent))
            parent.chmod(0o755)
            (Path(tmp) / "link").symlink_to(parent)
            self.assertFalse(w.private_parent(Path(tmp) / "link"))
            w.check_destination(parent / "out")
            w.check_destination(Path(tmp) / "out")
            for bad in (Path("relative/out"), parent, Path(tmp) / "link" / "out", Path(tmp) / "link", Path(tmp) / "no-parent" / "out"):
                with self.assertRaises(ValueError):
                    w.check_destination(bad)
            parent.chmod(0o775)
            with self.assertRaises(ValueError):
                w.check_destination(parent / "out")

if __name__ == "__main__":
    unittest.main()
