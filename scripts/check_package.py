"""Inspect installer bytes only. Never run Installer, capture or services."""
import plistlib
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]

class PackageChecks(unittest.TestCase):
    def test_guided_payload_and_identity(self):
        with tempfile.TemporaryDirectory(prefix="macmem-package-check-") as folder:
            expanded = Path(folder) / "expanded"
            subprocess.run(["/usr/sbin/pkgutil", "--expand-full", str(ROOT / "dist/Daydream-guided-local-unsigned.pkg"), str(expanded)],check=True,capture_output=True)
            distribution = ET.parse(expanded / "Distribution").getroot()
            self.assertEqual(distribution.findtext("title"), "DayDream")
            self.assertEqual(distribution.find("pkg-ref").attrib["onConclusion"], "None")
            apps = list(expanded.rglob("DayDream.app"))
            self.assertEqual(len(apps),1)
            contents = apps[0] / "Contents"
            self.assertTrue((contents / "_CodeSignature/CodeResources").is_file())
            subprocess.run(["codesign","--verify","--deep","--strict",str(apps[0])],check=True,capture_output=True)
            info = plistlib.loads((contents / "Info.plist").read_bytes())
            self.assertEqual(info["CFBundleDisplayName"],"DayDream")
            # perm-1004: the local unsigned package is ad-hoc sealed, so its app has the .adhoc ID.
            self.assertEqual(info["CFBundleIdentifier"],"com.getnorthlight.daydream.adhoc")
            self.assertEqual(info["CFBundleIconFile"],"Daydream")
            self.assertEqual((contents / "Resources/Daydream.icns").read_bytes()[:4],b"icns")
            for name in ["MacMem","mac-mem","mac-mem-backup"]:
                self.assertTrue((contents / "MacOS" / name).is_file())
            self.assertTrue((contents / "Resources/before_turn.py").is_file())
            self.assertTrue((contents / "Resources/Companions.json").is_file())
            self.assertTrue((contents / "Resources/Sparkle-LICENSE.txt").is_file())
            framework = contents / "Frameworks/Sparkle.framework"
            self.assertTrue((framework / "Sparkle").is_file())
            self.assertTrue((framework / "Sparkle").is_symlink())
            subprocess.run(["codesign","--verify","--deep","--strict",str(framework)],check=True,capture_output=True)
            self.assertFalse(info["SUEnableAutomaticChecks"])
            self.assertFalse(info["SUAutomaticallyUpdate"])
            self.assertNotIn("SUFeedURL",info)
            self.assertNotIn("SUPublicEDKey",info)
            self.assertTrue(info["SURequireSignedFeed"])
            self.assertTrue(info["SUVerifyUpdateBeforeExtraction"])
            self.assertFalse(list(expanded.rglob("Scripts")))
            self.assertFalse(list(expanded.rglob("LaunchAgents")))
            self.assertFalse(list(expanded.rglob("memory.sqlite")))
            self.assertFalse(list(expanded.rglob("events.jsonl")))
            for metadata in expanded.rglob("PackageInfo"):
                package = ET.parse(metadata).getroot()
                self.assertEqual(package.attrib["relocatable"],"false")
                self.assertFalse(package.findall("./relocate/*"), "Installer must never relocate Sparkle into another app")

    def test_no_memory_upload_implementation(self):
        # Static check only. Sparkle is an explicit network dependency; it starts
        # only with configured feed/key, and never receives memory/recipient data.
        forbidden = ["URLSession", "NWConnection", "AF_INET", "urllib.request", "requests.get", "requests.post", "http.client", "socket.create_connection"]
        paths = list((ROOT / "Sources").rglob("*.swift")) + list((ROOT / "adapters").glob("*.py"))
        for path in paths:
            source = path.read_text()
            for symbol in forbidden:
                self.assertNotIn(symbol,source,f"{path}: {symbol}")

    def test_clean_doctor_does_not_create_store(self):
        import json
        with tempfile.TemporaryDirectory(prefix="macmem-clean-doctor-") as folder:
            target = Path(folder) / "uninitialized"
            result = json.loads(subprocess.check_output([str(ROOT / ".build/debug/mac-mem"),"--home",str(target),"doctor"],text=True))
            self.assertEqual(result["database"],"absent")
            self.assertEqual(result["capture"],"off")
            self.assertFalse(target.exists())

if __name__ == "__main__": unittest.main()
