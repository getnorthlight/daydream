"""Update checks: settings, the key file, Sparkle interop with a throwaway key, and the app's guards.

Nothing here makes or reads the real update key, touches the Keychain, uses the network,
signs an app or publishes anything. The Sparkle interop tests run the vendored
generate_appcast / sign_update on a synthetic app with a key made under TMPDIR.
The tests that run DayDream's verifier need DAYDREAM_TEST_CLI set to a built mac-mem.
"""
import base64
import copy
import hashlib
import importlib.util
import json
import os
import plistlib
from pathlib import Path
import re
import shutil
import stat
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import release

ROOT = Path(__file__).resolve().parents[1]
FIXTURE_KEY = base64.b64encode(bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")).decode()
FIXTURE = {"owner": "getnorthlight", "repository": "daydream", "site": "getdaydream.app",
           "feed": "https://getdaydream.app/appcast.xml",
           "public_key": FIXTURE_KEY}
APPCAST_CACHE = Path.home() / "Library/Caches/Sparkle_generate_appcast"


def built_cli():
    value = os.environ.get("DAYDREAM_TEST_CLI")
    if not value:
        raise AssertionError("Set DAYDREAM_TEST_CLI to the explicitly selected built CLI")
    return value


def load_bootstrap():
    spec = importlib.util.spec_from_file_location("bootstrap_sparkle", ROOT / "scripts/bootstrap-sparkle.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def throwaway_key(folder):
    """A test key made the same way as the real one, but under the test's temp folder."""
    path, public = release.make_key(Path(folder) / "keys")
    return path, public


class TempCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="daydream-update-check-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)


class UpdateSettings(TempCase):
    def validate(self, data, require_key=True):
        path = self.root / "updates.json"
        path.write_text(json.dumps(data))
        return release.config(path, require_key)

    def test_shipped_settings_use_the_website_feed(self):
        # updates-1003: the feed moved from the GitHub "latest release" asset to the website (a stable URL the owner
        # controls; archives stay GitHub release assets by default).
        data = release.config(release.UPDATES_JSON, require_key=False)
        self.assertEqual(data["feed"], "https://getdaydream.app/appcast.xml")
        self.assertEqual(release.feed_url("getdaydream.app"), data["feed"])
        # The owner's existing key (commit 7d10875) is reused: 0.1.3 copies trust only it.
        self.assertEqual(data["public_key"], "yJCzogP0s2x3YaR3CVuYJ+WCauu5m5ygHLK/svx3AQc=")
        self.assertEqual(release.download_prefix(data, "0.1.0 Beta"),
                         "https://github.com/getnorthlight/daydream/releases/download/v0.1.0/")
        self.assertIn(data.get("public_key", ""), ("",) if not data.get("public_key") else (data["public_key"],))
        if data.get("public_key"):
            self.assertTrue(release.valid_public_key(data["public_key"]))

    def test_real_shaped_fixture_without_tools(self):
        with patch("subprocess.run") as run:
            self.assertEqual(self.validate(FIXTURE), FIXTURE)
            run.assert_not_called()

    def test_missing_fields(self):
        for field in FIXTURE:
            data = copy.copy(FIXTURE)
            del data[field]
            with self.assertRaises((ValueError, KeyError)):
                self.validate(data)

    def test_only_the_website_feed_is_accepted(self):
        for feed in ("https://getnorthlight.github.io/daydream/appcast.xml",
                     "http://getdaydream.app/appcast.xml",
                     "https://github.com/getnorthlight/daydream/releases/latest/download/appcast.xml",
                     "https://www.getdaydream.app/appcast.xml",
                     "https://getdaydream.app/updates/appcast.xml",
                     "https://getdaydream.app/appcast.xml?x=1",
                     "https://evil.invalid/appcast.xml"):
            with self.assertRaisesRegex(ValueError, "website's appcast"):
                self.validate({**FIXTURE, "feed": feed})
        for site in ("getdaydream", "example.com", "localhost", "GetDayDream.app", "getnorthlight.github.io", "x.invalid", ""):
            with self.assertRaisesRegex(ValueError, "site"):
                self.validate({**FIXTURE, "site": site, "feed": "https://%s/appcast.xml" % site})

    def test_archive_hosts(self):
        ok = ["https://github.com/getnorthlight/daydream/releases/download/v0.1.5/DayDream-0.1.5.zip",
              "https://getdaydream.app/releases/v0.1.5/DayDream-0.1.5.zip",
              "https://downloads.getdaydream.app/v0.1.5/DayDream-0.1.5.zip"]
        bad = ["http://getdaydream.app/DayDream.zip", "https://getdaydream.app:8443/DayDream.zip",
               "https://evilgetdaydream.app/DayDream.zip", "https://getdaydream.app.evil.example/DayDream.zip",
               "https://github.com/someone/daydream/releases/download/v1/DayDream.zip",
               "https://github.com/getnorthlight/daydream/archive/v1/DayDream.zip",
               "https://getdaydream.app/DayDream.dmg", "https://getdaydream.app/a/../DayDream.zip",
               "https://getdaydream.app//DayDream.zip", "https://getdaydream.app/DayDream.zip?x=1",
               "https://user@getdaydream.app/DayDream.zip"]
        for url in ok:
            self.assertEqual(release.archive_url_problems(url, FIXTURE), [], url)
        for url in bad:
            self.assertTrue(release.archive_url_problems(url, FIXTURE), url)
        # The app's rule is the same one (UpdateConfiguration.permitsArchive).
        policy = (ROOT / "Sources/MemoryCore/UpdatePolicy.swift").read_text()
        self.assertIn('return host == site || host.hasSuffix("." + site)', policy)

    def test_placeholders_and_bad_keys_refused(self):
        for field, value in [("owner", "YOUR-OWNER"), ("repository", "replace-me"), ("owner", "a/b"),
                             ("public_key", base64.b64encode(bytes(32)).decode()), ("public_key", "not base64!"),
                             ("public_key", base64.b64encode(b"x" * 31).decode())]:
            with self.assertRaises(ValueError):
                self.validate({**FIXTURE, field: value})

    def test_key_required_for_a_release_but_not_for_validate(self):
        data = {**FIXTURE, "public_key": ""}
        self.assertEqual(self.validate(data, require_key=False)["public_key"], "")
        with self.assertRaisesRegex(ValueError, "public key"):
            self.validate(data)

    def test_release_info_checks_daily_and_updates_quietly(self):
        info = release.update_info(FIXTURE)
        self.assertEqual(info["SUFeedURL"], FIXTURE["feed"])
        self.assertEqual(info["DaydreamUpdateSite"], "getdaydream.app")
        self.assertEqual(info["SUPublicEDKey"], FIXTURE_KEY)
        self.assertIs(info["SUEnableAutomaticChecks"], True)
        self.assertEqual(info["SUScheduledCheckInterval"], 86400)
        # updates-1003 (owner, 10/03): download quietly, install at the quit or at Restart to Update.
        self.assertIs(info["SUAutomaticallyUpdate"], True)
        self.assertIs(info["SUAllowsAutomaticUpdates"], True)
        self.assertIs(info["SUSendProfileInfo"], False)
        self.assertIs(info["SURequireSignedFeed"], True)
        self.assertIs(info["SUVerifyUpdateBeforeExtraction"], True)

    def test_version_core_and_tag(self):
        self.assertEqual(release.version_core("0.1.0 Beta"), "0.1.0")
        self.assertEqual(release.release_tag("0.1.0 Beta"), "v0.1.0")
        self.assertEqual(release.release_tag("1.2"), "v1.2")
        for bad in ("0.1.0 beta", "0.1.0-beta", "v0.1.0", "0.1.0 Beta 2", "", "1"):
            with self.assertRaises(ValueError):
                release.version_core(bad)

    def test_set_public_key(self):
        path = self.root / "updates.json"
        path.write_text(json.dumps({**FIXTURE, "public_key": ""}))
        with self.assertRaises(ValueError):
            release.set_public_key(base64.b64encode(bytes(32)).decode(), path)
        release.set_public_key(FIXTURE_KEY, path)
        self.assertEqual(release.config(path)["public_key"], FIXTURE_KEY)

    def test_dev_info_plist_has_no_updates(self):
        info = plistlib.loads((ROOT / "packaging/Info.plist").read_bytes())
        for key in ("SUFeedURL", "SUPublicEDKey"):
            self.assertNotIn(key, info)
        self.assertFalse(info["SUEnableAutomaticChecks"])
        self.assertFalse(info["SUAutomaticallyUpdate"])


class Ed25519(unittest.TestCase):
    RFC8032 = [  # (secret seed, public key), RFC 8032 section 7.1 tests 1-3
        ("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
         "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"),
        ("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
         "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"),
        ("c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
         "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025"),
    ]

    def test_rfc_vectors(self):
        for seed, public in self.RFC8032:
            self.assertEqual(release.ed25519_public_key(bytes.fromhex(seed)).hex(), public)

    def test_seed_length(self):
        with self.assertRaises((ValueError, AssertionError)):
            release.ed25519_public_key(b"short")


class KeyFile(TempCase):
    def test_make_key_writes_a_private_file_once(self):
        path, public = throwaway_key(self.root)
        self.assertEqual(path, self.root / "keys/sparkle-ed25519.key")
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
        self.assertEqual(len(base64.b64decode(path.read_text(), validate=True)), 32)
        self.assertEqual(release.key_file_problems(path), [])
        self.assertEqual(release.public_key_of(path), public)
        self.assertTrue(release.valid_public_key(public))
        self.assertEqual((path.parent / "sparkle-ed25519.pub").read_text().strip(), public)
        before = path.read_bytes()
        with self.assertRaisesRegex(ValueError, "Never replace the update key"):
            release.make_key(self.root / "keys")
        self.assertEqual(path.read_bytes(), before)

    def test_two_keys_differ(self):
        _, first = release.make_key(self.root / "a")
        _, second = release.make_key(self.root / "b")
        self.assertNotEqual(first, second)

    def test_default_location_is_a_file_in_daydream_keys(self):
        self.assertEqual(release.KEY_FILE, Path.home() / "DayDream-keys/sparkle-ed25519.key")
        self.assertEqual(release.key_location_problems(release.KEY_FILE), [])

    def test_never_the_keychain_stdin_or_the_repository(self):
        for place in (Path.home() / "Library/Keychains/login.keychain-db", self.root / "update.keychain",
                      self.root / "x.keychain-db", Path("-"), ROOT / "packaging/sparkle.key",
                      ROOT / "Vendor/sparkle.key"):
            self.assertNotEqual(release.key_location_problems(place), [], place)
            self.assertNotEqual(release.key_file_problems(place), [], place)
        with self.assertRaises(ValueError):
            release.make_key(self.root / "keys", "update.keychain")
        self.assertFalse((self.root / "keys/update.keychain").exists())
        with self.assertRaises(ValueError):
            release.make_key(ROOT / "packaging", "never.key")
        self.assertFalse((ROOT / "packaging/never.key").exists())

    def test_loose_permissions_refused(self):
        path, _ = throwaway_key(self.root)
        os.chmod(path, 0o644)
        self.assertTrue(any("chmod 600" in p for p in release.key_file_problems(path)))
        os.chmod(path, 0o600)
        os.chmod(path.parent, 0o755)
        self.assertTrue(any("chmod 700" in p for p in release.key_file_problems(path)))
        os.chmod(path.parent, 0o700)
        with self.assertRaisesRegex(ValueError, "refused"):
            os.chmod(path, 0o640)
            release.public_key_of(path)

    def test_symlink_and_bad_content_refused(self):
        path, _ = throwaway_key(self.root)
        link = path.parent / "link.key"
        link.symlink_to(path)
        self.assertNotEqual(release.key_file_problems(link), [])
        bad = path.parent / "bad.key"
        bad.write_text("not a key")
        os.chmod(bad, 0o600)
        self.assertTrue(any("32 bytes" in p for p in release.key_file_problems(bad)))
        self.assertNotEqual(release.key_file_problems(path.parent / "missing.key"), [])

    def test_sparkle_is_given_the_file_never_the_keychain(self):
        argv = release.appcast_argv("/k/sparkle-ed25519.key", "https://x/", "/out")
        self.assertEqual(argv[1:3], ["--ed-key-file", "/k/sparkle-ed25519.key"])
        self.assertIn("--embed-release-notes", argv)
        self.assertEqual(argv[argv.index("--maximum-deltas") + 1], "0")
        verify = release.feed_verify_argv("/k/sparkle-ed25519.key", "/out/appcast.xml")
        for command in (argv, verify):
            self.assertNotIn("--account", command)
            self.assertNotIn("-s", command)
        source = (ROOT / "scripts/release.py").read_text() + (ROOT / "scripts/developer-id-release.py").read_text() \
            + (ROOT / "scripts/signing_plan.py").read_text()
        self.assertNotIn('"--account"', source)
        self.assertNotIn("'--account'", source)
        self.assertNotIn("generate_keys\"", source)
        self.assertNotIn("security find-generic-password", source)


# claude/crashguard-015: a thin arm64 Mach-O built for macOS 15.0 (header + LC_BUILD_VERSION), as release.platform_problems
# requires of the three Swift products; Sparkle's generate_appcast reads its architecture too.
def macho(minos=0x000F0000, cpu=0x0100000C, tail=b""):
    return (struct.pack("<8I", 0xfeedfacf, cpu, 0, 2, 1, 24, 0, 0) + struct.pack("<6I", 0x32, 24, 1, minos, minos, 0)
            + bytes(4096) + tail)


def synthetic_app(folder, build, short_version, public_key, name="DayDream.app"):
    """An unsigned app bundle Sparkle's tools accept: a shell-script executable and the update keys."""
    app = Path(folder) / name
    (app / "Contents/MacOS").mkdir(parents=True)
    (app / "Contents/Resources").mkdir()
    exe = app / "Contents/MacOS/MacMem"
    exe.write_bytes(macho())
    exe.chmod(0o755)
    info = {"CFBundleIdentifier": "com.getnorthlight.daydream", "CFBundleName": "DayDream", "CFBundleExecutable": "MacMem",
            "CFBundlePackageType": "APPL", "CFBundleVersion": str(build), "CFBundleShortVersionString": short_version,
            "LSMinimumSystemVersion": "15.0", **release.update_info({**FIXTURE, "public_key": public_key})}
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    return app


# A synthetic "On this Mac" runtime (scripts/writer_payload.py): the v2 manifest and seven stand-in
# libraries. Prepare swaps only the compiled manifest pin in load_pins; every other check runs as written.
WRITER = release.writer_payload
WRITER_PINS = WRITER.runtime_pins((WRITER.ROOT / WRITER.RUNTIME).read_text())
WRITER_LIBRARIES = {name: b"synthetic signed " + name.encode() for name in sorted(WRITER_PINS["files"])}
WRITER_MANIFEST = (json.dumps({
    "schema": WRITER_PINS["schema"], "distributionID": WRITER.ID, "upstreamArchiveSHA256": WRITER_PINS["archive"],
    "teamID": WRITER.TEAM_ID, "certificateSHA256": WRITER.LEAF_SHA256,
    "files": [{"name": name, "upstreamSHA256": WRITER_PINS["files"][name][1],
               "signedSHA256": hashlib.sha256(data).hexdigest(), "signedBytes": len(data),
               "signingIdentifier": WRITER.signing_identifier(name)} for name, data in WRITER_LIBRARIES.items()]},
    indent=2, sort_keys=True) + "\n").encode()


def add_writer_runtime(app):
    """What developer-id-release.py stage places: the Info key, the manifest and the seven libraries."""
    contents = Path(app) / "Contents"
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    info[WRITER.INFO_KEY] = WRITER.ID
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    manifest = contents / WRITER.MANIFEST
    manifest.parent.mkdir(parents=True)
    manifest.write_bytes(WRITER_MANIFEST)
    manifest.chmod(0o644)
    folder = contents / WRITER.LIBROOT
    folder.mkdir(parents=True)
    for name, data in WRITER_LIBRARIES.items():
        (folder / name).write_bytes(data)
        (folder / name).chmod(0o755)


class AppcastCacheGuard:
    """generate_appcast keeps a cache in ~/Library/Caches. Remove only what this test added."""

    def __enter__(self):
        self.existed = APPCAST_CACHE.exists()
        self.before = set(APPCAST_CACHE.iterdir()) if self.existed else set()
        return self

    def __exit__(self, *exc):
        if not APPCAST_CACHE.exists():
            return
        if not self.existed:
            shutil.rmtree(APPCAST_CACHE, ignore_errors=True)
            return
        for path in set(APPCAST_CACHE.iterdir()) - self.before:
            shutil.rmtree(path, ignore_errors=True) if path.is_dir() else path.unlink()


@unittest.skipUnless((release.SPARKLE_TOOLS / "generate_appcast").is_file(), "Vendor/Sparkle-2.9.6 is not bootstrapped")
class SparkleInterop(TempCase):
    """The key file made by release.py works with Sparkle's tools and with DayDream's verifier."""

    def test_sign_update_signature_verifies_in_daydream(self):
        cli = built_cli()
        key, public = throwaway_key(self.root)
        archive = self.root / "DayDream-0.1.0.zip"
        archive.write_bytes(os.urandom(4096))
        signature = subprocess.run([str(release.SPARKLE_TOOLS / "sign_update"), "--ed-key-file", str(key), "-p", str(archive)],
                                   check=True, capture_output=True, text=True).stdout.strip()
        self.assertEqual(len(base64.b64decode(signature)), 64)
        ok = subprocess.run([cli, "verify-update-signature", str(archive), signature, public], capture_output=True, text=True)
        self.assertEqual(ok.returncode, 0, ok.stderr)
        subprocess.run([str(release.SPARKLE_TOOLS / "sign_update"), "--ed-key-file", str(key), "--verify", str(archive), signature],
                       check=True, capture_output=True)
        # A different public key, or a changed archive, is rejected.
        _, other = release.make_key(self.root / "other")
        self.assertNotEqual(subprocess.run([cli, "verify-update-signature", str(archive), signature, other], capture_output=True).returncode, 0)
        archive.write_bytes(archive.read_bytes() + b"x")
        self.assertNotEqual(subprocess.run([cli, "verify-update-signature", str(archive), signature, public], capture_output=True).returncode, 0)

    def test_generate_appcast_with_key_file_makes_a_signed_feed(self):
        key, public = throwaway_key(self.root)
        out = self.root / "release"
        out.mkdir()
        app = synthetic_app(self.root / "app", 20260926120000, "0.1.0 Beta", public)
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(app), str(out / "DayDream-0.1.0.zip")], check=True)
        (out / "DayDream-0.1.0.md").write_text("# DayDream 0.1.0 Beta\n\nFirst beta.\n")
        prefix = release.download_prefix(FIXTURE, "0.1.0 Beta")
        with AppcastCacheGuard():
            subprocess.run(release.appcast_argv(key, prefix, out), check=True, capture_output=True, timeout=120)
        feed = out / "appcast.xml"
        signature = release.check_appcast(feed, prefix, "DayDream-0.1.0.zip", 20260926120000, "0.1.0 Beta")
        self.assertTrue(signature)
        text = feed.read_text()
        # claude/crashguard-015: Sparkle infers the macOS 15.0 floor and arm64 from the app; check_appcast requires both.
        self.assertIn("<sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>", text)
        self.assertIn("<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>", text)
        for old, new in (("<sparkle:minimumSystemVersion>15.0<", "<sparkle:minimumSystemVersion>14.0<"),
                         ("<sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>", ""),
                         ("<sparkle:hardwareRequirements>arm64<", "<sparkle:hardwareRequirements>x86_64<"),
                         ("<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>", "")):
            changed = self.root / "changed.xml"
            changed.write_text(text.replace(old, new))
            with self.subTest(old=old, new=new), self.assertRaisesRegex(ValueError, "DO NOT publish"):
                release.check_appcast(changed, prefix, "DayDream-0.1.0.zip", 20260926120000, "0.1.0 Beta")
        self.assertIn("https://github.com/getnorthlight/daydream/releases/download/v0.1.0/DayDream-0.1.0.zip", text)
        self.assertIn("First beta.", text)
        subprocess.run(release.feed_verify_argv(key, feed), check=True, capture_output=True)
        # A feed changed after signing fails the check Sparkle runs in the app.
        feed.write_text(text.replace("First beta.", "Changed."))
        self.assertNotEqual(subprocess.run(release.feed_verify_argv(key, feed), capture_output=True).returncode, 0)


class Prepare(TempCase):
    """release.py prepare: refusals before any tool runs, then the full path with fakes for signing tools."""

    def setUp(self):
        super().setUp()
        # The fixture runtime's manifest stands in for the one pinned in SignedRuntimePolicy.swift.
        self.pins = dict(WRITER.load_pins(), approved={WRITER.ID: hashlib.sha256(WRITER_MANIFEST).hexdigest()})
        patcher = patch.object(WRITER, "load_pins", return_value=self.pins)
        patcher.start()
        self.addCleanup(patcher.stop)

    def release_app(self, public_key, build="20260926120000", typing=True, folder="stage", writer=True):
        app = synthetic_app(self.root / folder, build, "0.1.0 Beta", public_key)
        contents = app / "Contents"
        # Every release is the full-typing build: its MacMem carries the website typing route (public-typing review).
        if typing:
            (contents / "MacOS/MacMem").write_bytes(macho(tail=b"WebTypingRoute"))
        (contents / "MacOS/mac-mem").write_bytes(macho(tail=b"mac-mem fixture"))
        (contents / "MacOS/mac-mem-backup").write_bytes(macho(tail=b"backup fixture"))
        (contents / "Resources/before_turn.py").write_text("# fixture\n")
        # Every release carries the signed "On this Mac" runtime (owner decision 2026-09-26).
        if writer:
            add_writer_runtime(app)
        release.manifest(app, "c" * 40)
        return app

    def test_app_without_the_on_this_mac_runtime_refused(self):
        key, public = throwaway_key(self.root)
        updates = self.updates(public)
        runner = unittest.mock.Mock(side_effect=AssertionError("no tool may run"))
        out = self.root / "out"
        # A --without-writer-runtime-for-tests stage is a test build: never in the appcast.
        bare = self.release_app(public, writer=False, folder="bare")
        with self.assertRaisesRegex(ValueError, "No On this Mac runtime inside"):
            release.prepare(bare, out, key, 1, self.notes(), True, updates, runner=runner)
        # Changed library bytes, or a manifest that is not the compiled pin, are refused too.
        changed = self.release_app(public, folder="changed")
        (changed / "Contents" / WRITER.LIBROOT / sorted(WRITER_LIBRARIES)[0]).write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "Signed writer bytes changed"):
            release.prepare(changed, out, key, 1, self.notes(), True, updates, runner=runner)
        unpinned = self.release_app(public, folder="unpinned")
        with patch.object(WRITER, "load_pins", return_value=dict(self.pins, approved={})), \
                self.assertRaisesRegex(ValueError, "is not pinned"):
            release.prepare(unpinned, out, key, 1, self.notes(), True, updates, runner=runner)
        runner.assert_not_called()
        self.assertFalse(out.exists())

    def notes(self, text="# DayDream 0.1.0 Beta\n\nFirst beta.\n"):
        path = self.root / "notes.md"
        path.write_text(text)
        return path

    def updates(self, public_key):
        path = self.root / "updates.json"
        path.write_text(json.dumps({**FIXTURE, "public_key": public_key}))
        return path

    def test_refusals_before_any_tool(self):
        key, public = throwaway_key(self.root)
        app = self.release_app(public)
        updates = self.updates(public)
        runner = unittest.mock.Mock(side_effect=AssertionError("no tool may run"))
        cases = [
            dict(rights_confirmed=False),
            dict(key_file=self.root / "missing.key"),
            dict(key_file=Path.home() / "Library/Keychains/login.keychain-db"),
            dict(notes=self.notes("# DayDream\n\n- [One line per change]\n")),
            dict(notes=None),
            dict(updates_path=self.updates(FIXTURE_KEY)),  # key file doesn't match updates.json
            dict(previous_build=20260926120000),
        ]
        for case in cases:
            args = dict(app=app, output=self.root / "out", key_file=key, previous_build=1, notes=self.notes(),
                        rights_confirmed=True, updates_path=updates, runner=runner)
            args.update(case)
            with self.subTest(case=list(case)), self.assertRaises(ValueError):
                release.prepare(**args)
            self.updates(public) if "updates_path" in case else None
        runner.assert_not_called()
        self.assertFalse((self.root / "out").exists())
        # A narrow app (no website typing code) never reaches ditto or the appcast.
        narrow = self.release_app(public, typing=False, folder="narrow")
        with self.assertRaisesRegex(ValueError, "Not the full-typing build"):
            release.prepare(narrow, self.root / "out", key, 1, self.notes(), True, updates, runner=runner)
        runner.assert_not_called()
        self.assertFalse((self.root / "out").exists())

    def test_not_macos_15_or_not_arm64_refused(self):
        """claude/crashguard-015: 0.1.5 is macOS 15.0+ on Apple silicon only; anything else never reaches a tool."""
        key, public = throwaway_key(self.root)
        updates = self.updates(public)
        runner = unittest.mock.Mock(side_effect=AssertionError("no tool may run"))
        self.assertEqual(release.platform_problems(self.release_app(public, folder="good")), [])
        self.assertEqual(release.package_platform_problems(), [])
        x86 = 0x01000007
        fat = (struct.pack(">2I", 0xcafebabe, 2) + struct.pack(">5I", 0x0100000C, 0, 4096, len(macho()), 14)
               + struct.pack(">5I", x86, 3, 12288, len(macho()), 12))
        fat = fat + bytes(4096 - len(fat)) + macho() + bytes(4096 - len(macho()) % 4096) + macho(cpu=x86)
        cases = {
            "info-14": ("plist", "14.0", "LSMinimumSystemVersion must be 15.0"),
            "info-15.1": ("plist", "15.1", "LSMinimumSystemVersion must be 15.0"),
            "info-missing": ("plist", None, "LSMinimumSystemVersion must be 15.0"),
            "intel": ("mac-mem", macho(cpu=x86), "mac-mem must be arm64 only"),
            "universal": ("MacMem", fat + b"WebTypingRoute", "MacMem must be arm64 only"),
            "minos-14": ("mac-mem-backup", macho(minos=0x000E0000), "mac-mem-backup must be built for macOS 15.0"),
            "not-macho": ("mac-mem", b"#!/bin/sh\nexit 0\n", "mac-mem must be arm64 only"),
        }
        for folder, (what, value, message) in cases.items():
            app = self.release_app(public, folder=folder)
            contents = app / "Contents"
            if what == "plist":
                info = plistlib.loads((contents / "Info.plist").read_bytes())
                info.pop("LSMinimumSystemVersion") if value is None else info.update(LSMinimumSystemVersion=value)
                (contents / "Info.plist").write_bytes(plistlib.dumps(info))
            else:
                (contents / "MacOS" / what).write_bytes(value)
                release.manifest(app, "c" * 40)
            with self.subTest(case=folder):
                self.assertTrue(any(message in p for p in release.platform_problems(app)), release.platform_problems(app))
                with self.assertRaisesRegex(ValueError, "Not a macOS 15 / Apple silicon release"):
                    release.prepare(app, self.root / "out", key, 1, self.notes(), True, updates, runner=runner)
        # The universal binary's own slices are both read.
        self.assertEqual(release.macho_platform(self.root / "universal/DayDream.app/Contents/MacOS/MacMem")[0], (0x0100000C, x86))
        # Package.swift's floor: .macOS(.v15) or "15.0" only.
        for text, ok in (('platforms: [.macOS(.v15)]', True), ('platforms: [.macOS("15.0")]', True),
                         ('platforms: [.macOS(.v14)]', False), ('platforms: [.macOS("13.0")]', False), ('platforms: []', False)):
            folder = self.root / ("pkg-%d" % abs(hash(text)))
            folder.mkdir()
            (folder / "Package.swift").write_text("let package = Package(name: \"X\", %s)\n" % text)
            with self.subTest(package=text):
                self.assertEqual(release.package_platform_problems(folder) == [], ok)
        runner.assert_not_called()
        self.assertFalse((self.root / "out").exists())

    def test_app_without_the_same_update_settings_refused(self):
        key, public = throwaway_key(self.root)
        app = self.release_app(FIXTURE_KEY)
        with self.assertRaisesRegex(ValueError, "SUPublicEDKey"):
            release.prepare(app, self.root / "out", key, 1, self.notes(), True, self.updates(public),
                            runner=unittest.mock.Mock(side_effect=AssertionError("no tool may run")))

    @unittest.skipUnless((release.SPARKLE_TOOLS / "generate_appcast").is_file(), "Vendor/Sparkle-2.9.6 is not bootstrapped")
    def test_full_prepare_with_throwaway_key(self):
        cli = built_cli()
        key, public = throwaway_key(self.root)
        app = self.release_app(public)
        out = self.root / "out"
        calls = []

        def runner(argv, **kwargs):
            argv = [str(a) for a in argv]
            calls.append(argv)
            if argv[0] in ("codesign", "spctl", "xcrun"):
                stderr = ("Authority=Developer ID Application: Fixture (%s)\nTeamIdentifier=%s\n"
                          "CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1\n" % (release.apple_team_id(), release.apple_team_id()))
                return subprocess.CompletedProcess(argv, 0, "", stderr)
            if argv[0].endswith("Contents/MacOS/mac-mem"):
                argv = [cli] + argv[1:]
            return subprocess.run(argv, **kwargs)

        with AppcastCacheGuard():
            release.prepare(app, out, key, 20260925000000, self.notes(), True, self.updates(public), runner=runner)
        self.assertEqual(sorted(p.name for p in out.iterdir()),
                         ["DayDream-0.1.0.md", "DayDream-0.1.0.zip", "RELEASE-VERIFIED.json", "appcast.xml"])
        verified = json.loads((out / "RELEASE-VERIFIED.json").read_text())
        self.assertEqual(verified["tag"], "v0.1.0")
        self.assertEqual(verified["source_commit"], "c" * 40)
        self.assertIs(verified["published"], False)
        self.assertTrue(any(c[1:2] == ["verify-update-signature"] for c in calls))
        self.assertTrue(any(c[0].endswith("sign_update") and "--verify" in c for c in calls))
        for command in calls:
            self.assertNotIn("--account", command)
            self.assertFalse(any(part in ("gh", "git", "curl") for part in command[:1]))
        with self.assertRaisesRegex(ValueError, "new directory"):
            release.prepare(app, out, key, 20260925000000, self.notes(), True, self.updates(public), runner=runner)

    def fake_signing_runner(self, cli, calls, image_app=None):
        """codesign/spctl/xcrun answer as a stapled Developer ID app would; hdiutil 'mounts' `image_app` (a copy);
        Sparkle's tools and ditto really run."""
        def runner(argv, **kwargs):
            argv = [str(a) for a in argv]
            calls.append(argv)
            if argv[0] in ("codesign", "spctl", "xcrun"):
                stderr = ("Authority=Developer ID Application: Fixture (%s)\nTeamIdentifier=%s\n"
                          "CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1\n" % (release.apple_team_id(), release.apple_team_id()))
                return subprocess.CompletedProcess(argv, 0, "", stderr)
            if argv[0] == "hdiutil":
                if argv[1] == "attach":
                    mount = Path(argv[argv.index("-mountpoint") + 1])
                    shutil.copytree(image_app, mount / "DayDream.app", symlinks=True)
                else:
                    shutil.rmtree(Path(argv[2]) / "DayDream.app")
                return subprocess.CompletedProcess(argv, 0, "", "")
            if argv[0].endswith("Contents/MacOS/mac-mem"):
                argv = [cli] + argv[1:]
            return subprocess.run(argv, **kwargs)
        return runner

    def plain_notes(self, text="Typing in Chrome works on long pages.\nSummaries keep their place after a restart.\n"):
        path = self.root / ("notes-%s.txt" % hashlib.sha256(text.encode()).hexdigest()[:12])
        path.write_text(text)
        return path

    def test_appcast_refusals_before_any_tool(self):
        key, public = throwaway_key(self.root)
        updates = self.updates(public)
        zipped = self.root / "DayDream-0.1.0.zip"
        zipped.write_bytes(b"PK fixture")
        runner = unittest.mock.Mock(side_effect=AssertionError("no tool may run"))
        cases = [
            dict(dmg=None, zip_file=None), dict(dmg=zipped, zip_file=zipped), dict(dmg=zipped),
            dict(rights_confirmed=False), dict(key_file=self.root / "missing.key"),
            dict(notes=self.notes()),  # .md, not plain text
            dict(notes=self.plain_notes("")), dict(notes=self.plain_notes("- [ ] One line per change\n")),
            dict(notes=self.plain_notes("<p>Fixed</p>\n")), dict(notes=self.plain_notes("TODO\n")),
        ]
        mismatch = self.root / "updates-other-key.json"  # the key file doesn't match updates.json
        mismatch.write_text(json.dumps({**FIXTURE, "public_key": FIXTURE_KEY}))
        cases.append(dict(updates_path=mismatch))
        for case in cases:
            args = dict(output=self.root / "out", key_file=key, previous_build=1, notes=self.plain_notes(), rights_confirmed=True,
                        zip_file=zipped, updates_path=updates, runner=runner)
            args.update(case)
            if "dmg" in case and "zip_file" not in case:
                args["zip_file"] = None
            with self.subTest(case=list(case)), self.assertRaises(ValueError):
                release.appcast(**args)
        runner.assert_not_called()
        self.assertFalse((self.root / "out").exists())

    @unittest.skipUnless((release.SPARKLE_TOOLS / "generate_appcast").is_file(), "Vendor/Sparkle-2.9.6 is not bootstrapped")
    def test_appcast_from_a_zip_and_from_a_dmg(self):
        cli = built_cli()
        key, public = throwaway_key(self.root)
        app = self.release_app(public)
        zipped = self.root / "in" / "DayDream-0.1.0.zip"
        zipped.parent.mkdir()
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(app), str(zipped)], check=True)
        for kind in ("zip", "dmg"):
            with self.subTest(kind=kind):
                calls, out = [], self.root / ("out-" + kind)
                runner = self.fake_signing_runner(cli, calls, image_app=app)
                source = dict(zip_file=zipped) if kind == "zip" else dict(dmg=self.root / "in" / "DayDream-0.1.0.dmg")
                if kind == "dmg":
                    source["dmg"].write_bytes(b"fixture image")
                prefix = "https://downloads.getdaydream.app/v0.1.0/" if kind == "dmg" else None
                with AppcastCacheGuard():
                    release.appcast(out, key, 20260925000000, self.plain_notes(), True, updates_path=self.updates(public),
                                    runner=runner, download_url_prefix=prefix, **source)
                self.assertEqual(sorted(p.name for p in out.iterdir()),
                                 ["DayDream-0.1.0.txt", "DayDream-0.1.0.zip", "RELEASE-VERIFIED.json", "appcast.xml"])
                feed = (out / "appcast.xml").read_text()
                url = (prefix or "https://github.com/getnorthlight/daydream/releases/download/v0.1.0/") + "DayDream-0.1.0.zip"
                self.assertIn('url="%s"' % url, feed)
                self.assertIn("Typing in Chrome works on long pages.", feed)
                self.assertIn("sparkle:edSignature=", feed)
                self.assertIn("sparkle-signatures:", feed)
                verified = json.loads((out / "RELEASE-VERIFIED.json").read_text())
                self.assertEqual((verified["archive_url"], verified["feed_url"], verified["published"]),
                                 (url, "https://getdaydream.app/appcast.xml", False))
                if kind == "zip":
                    self.assertEqual((out / "DayDream-0.1.0.zip").read_bytes(), zipped.read_bytes())
                else:
                    self.assertTrue(any(c[:2] == ["hdiutil", "attach"] and "-readonly" in c for c in calls))
                    self.assertTrue(any(c[:2] == ["hdiutil", "detach"] for c in calls))
                    self.assertTrue(any(c[:3] == ["xcrun", "stapler", "validate"] and c[-1].endswith(".dmg") for c in calls))
                self.assertTrue(any(c[1:2] == ["verify-update-signature"] for c in calls))
                self.assertTrue(any(c[0].endswith("sign_update") and "--verify" in c for c in calls))
                for command in calls:
                    self.assertNotIn("--account", command)
                    self.assertFalse(any(part in ("gh", "git", "curl", "wrangler", "rsync") for part in command[:1]))
        # An archive host other than GitHub releases or the site is refused before anything is written.
        with self.assertRaisesRegex(ValueError, "Download prefix refused"):
            release.appcast(self.root / "out-bad", key, 20260925000000, self.plain_notes(), True, zip_file=zipped,
                            updates_path=self.updates(public), runner=self.fake_signing_runner(cli, []),
                            download_url_prefix="https://example.net/")
        self.assertFalse((self.root / "out-bad").exists())


class Payload(TempCase):
    def test_payload_refuses_private_files_and_escape(self):
        app = self.root / "DayDream.app"
        resources = app / "Contents/Resources"
        resources.mkdir(parents=True)
        release.audit(app)
        secret = resources / "personal-config.json"
        secret.write_text("synthetic")
        with self.assertRaises(ValueError):
            release.audit(app)
        secret.unlink()
        (resources / "Daydream.icns").symlink_to(self.root / "outside")
        with self.assertRaises(ValueError):
            release.audit(app)

    def test_manifest_keeps_the_source_commit(self):
        app = synthetic_app(self.root, 5, "0.1.0 Beta", FIXTURE_KEY)
        contents = app / "Contents"
        for name in ("MacOS/mac-mem", "MacOS/mac-mem-backup", "Resources/before_turn.py"):
            (contents / name).write_bytes(name.encode())
        release.manifest(app, "a" * 40)
        release.manifest(app)
        self.assertEqual(json.loads((contents / "Resources/Companions.json").read_text())["source_commit"], "a" * 40)
        with self.assertRaises(ValueError):
            release.manifest(app, "HEAD")


class BootstrapSparkle(TempCase):
    def setUp(self):
        super().setUp()
        self.module = load_bootstrap()
        self.pin = self.module.pin()

    def test_pin(self):
        self.assertEqual(self.pin["version"], "2.9.6")
        self.assertRegex(self.pin["sha256"], r"^[0-9a-f]{64}$")
        self.assertRegex(self.pin["inventory_sha256"], r"^[0-9a-f]{64}$")
        self.assertTrue(self.pin["url"].startswith("https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/"))

    @unittest.skipUnless((ROOT / "Vendor/Sparkle-2.9.6").is_dir(), "Vendor/Sparkle-2.9.6 is not bootstrapped")
    def test_existing_folder_checked_by_content_and_stamp_written(self):
        copy_ = self.root / "Sparkle-2.9.6"
        subprocess.run(["ditto", str(ROOT / "Vendor/Sparkle-2.9.6"), str(copy_)], check=True)
        stamp = copy_ / self.module.STAMP
        if stamp.exists():
            stamp.unlink()
        self.assertEqual(self.module.folder_problems(copy_, self.pin), [])
        self.module.check_folder(copy_, self.pin)
        self.assertEqual(stamp.read_text().strip(), self.pin["sha256"])
        # A wrong stamp or a changed file is refused.
        stamp.write_text("0" * 64 + "\n")
        self.assertTrue(any("different archive" in p for p in self.module.folder_problems(copy_, self.pin)))
        stamp.write_text(self.pin["sha256"] + "\n")
        (copy_ / "bin/sign_update").write_bytes(b"changed")
        self.assertTrue(self.module.folder_problems(copy_, self.pin))
        with self.assertRaises(SystemExit):
            self.module.check_folder(copy_, self.pin)

    def test_missing_or_linked_folder_refused(self):
        self.assertTrue(self.module.folder_problems(self.root / "none", self.pin))
        (self.root / "real").mkdir()
        (self.root / "link").symlink_to(self.root / "real")
        self.assertTrue(self.module.folder_problems(self.root / "link", self.pin))

    def test_inventory_ignores_only_the_stamp(self):
        folder = self.root / "f"
        folder.mkdir()
        (folder / "a").write_text("1")
        first = self.module.inventory_digest(folder)
        (folder / self.module.STAMP).write_text("x")
        self.assertEqual(self.module.inventory_digest(folder), first)
        (folder / "b").symlink_to("a")
        self.assertNotEqual(self.module.inventory_digest(folder), first)


class AppGuards(unittest.TestCase):
    def setUp(self):
        self.source = (ROOT / "Sources/MacMemApp/Updates.swift").read_text()
        self.policy = (ROOT / "Sources/MemoryCore/UpdatePolicy.swift").read_text()

    def test_no_update_keys_means_no_sparkle(self):
        self.assertLess(self.source.index("guard let config=try? UpdateConfiguration"),
                        self.source.index("SPUStandardUpdaterController(startingUpdater:false"))
        self.assertNotIn("installationSafetyVerified", self.policy + self.source)

    def test_feed_rule_in_the_app_matches_release_py(self):
        self.assertIn('public static func feedURL(site:String)->String { "https://\\(site)/appcast.xml" }', self.policy)
        self.assertEqual(release.feed_url("getdaydream.app"), "https://getdaydream.app/appcast.xml")
        self.assertIn('info["DaydreamUpdateSite"]', self.policy)
        self.assertIn("SURequireSignedFeed", self.policy)
        self.assertIn("SUVerifyUpdateBeforeExtraction", self.policy)

    def test_update_pauses_recording_only_at_the_quit(self):
        # CHANGED (golden test 5, G9): recording was paused as Sparkle began the install, before DayDream knew it
        # would quit; a refused quit or a stopped install left it paused for good. Now nothing pauses before the
        # quit, and the quit itself pauses recording and saves typed text (willTerminate), as every quit does.
        code = "\n".join(line for line in self.source.splitlines() if not line.strip().startswith("//"))
        self.assertNotIn("pauseForUpdate", self.source)
        # updates-1003: willInstallUpdateOnQuit only keeps Sparkle's install-now block; nothing pauses there.
        self.assertNotIn("willInstallUpdate(", code)
        hold = self.source[self.source.index("willInstallUpdateOnQuit item"):self.source.index("func updateWaiting(")]
        self.assertNotIn("pause", hold.lower())
        self.assertNotIn("relaunching()", hold)
        self.assertIn("func updaterWillRelaunchApplication(_ updater:SPUUpdater) { relaunching() }", self.source)
        app = (ROOT / "Sources/MacMemApp/MacMemApp.swift").read_text()
        self.assertNotIn("pauseForUpdate", app)
        self.assertRegex(app, r"willTerminateNotification[\s\S]{0,300}commitTyping:true")
        # sat5: only Sparkle's relaunch leaves the resume marker (when recording is on), read once at the next
        # launch. It goes when the install stops or DayDream is still running after the grace period.
        relaunch = self.source[self.source.index("func relaunching("):self.source.index("func relaunchEnded(")]
        self.assertRegex(relaunch, r"if isRecording\(\) \{\s*UpdateResume\.record\(defaults")
        self.assertIn("prepareToQuit()", relaunch)
        self.assertIn("asyncAfter(deadline:.now()+relaunchGrace)", relaunch)
        self.assertEqual(self.source.count("UpdateResume.record("), 1)
        self.assertIn("relaunchEnded()", self.source[self.source.index("func finished(error:"):self.source.index("func relaunching(")])

    def test_status_line_answers_check_now_and_never_sticks(self):
        # G53, G76 (golden test 5): a scheduled check that can't read or reach the update page says nothing, a
        # cancelled install is not a failure, and "Checking…" never stays (the behaviour: update-quit-checks.swift).
        self.assertIn("UpdateText.failureLine(asked:asked,", self.source)
        self.assertIn("public static func failureLine(asked:Bool,", self.policy)
        cycle = self.source[self.source.index("didFinishUpdateCycleFor"):self.source.index("func updater(_ updater:SPUUpdater,didAbortWithError")]
        self.assertIn("if status == UpdateText.checking { status=\"\" }", cycle)

    def test_replacement_blocks_updates(self):
        self.assertIn("mayPerform", self.source)
        self.assertIn("shouldProceedWithUpdate", self.source)
        # check, Restart to Update, Check Now, mayPerform, shouldProceed, a failed check
        self.assertEqual(self.source.count("replacementInProgress()"), 6)

    def test_quiet_updates_never_interrupt(self):
        # updates-1003 (owner, 10/03): a found update downloads quietly and waits; it installs at the quit, log out or
        # restart, or when the person picks Restart to Update. Nothing pops up.
        code = "\n".join(line for line in self.source.splitlines() if not line.strip().startswith("//"))
        self.assertNotIn("installUpdatesIfAvailable", code)
        self.assertNotIn("SUAutomaticallyUpdate", code)
        # One switch: downloads follow checks in Settings, and once at the first quiet-updates start (0.1.3 saved
        # "never download" every launch); after that the person's choice stays.
        self.assertRegex(self.source, r"try updater\.start\(\)\n(\s*//[^\n]*\n)*\s*if !defaults\.bool\(forKey:Self\.quietUpdatesKey\) \{\n"
                                      r"\s*updater\.automaticallyDownloadsUpdates=updater\.automaticallyChecksForUpdates\n"
                                      r"\s*defaults\.set\(true,forKey:Self\.quietUpdatesKey\)\n")
        self.assertIn("updater.automaticallyChecksForUpdates=value\n        updater.automaticallyDownloadsUpdates=value", self.source)
        self.assertIn('info["SUAllowsAutomaticUpdates"] as? Bool == true', self.policy)
        self.assertIn('info["SUAutomaticallyUpdate"] as? Bool == true', self.policy)
        # A downloaded update: DayDream keeps Sparkle's install-now block (returns true, so Sparkle shows nothing) and
        # runs it only from Restart to Update.
        hold = self.source[self.source.index("willInstallUpdateOnQuit item"):self.source.index("func updateWaiting(")]
        self.assertIn("installNow=immediateInstallHandler", hold)
        self.assertIn(".restart(version:", hold)
        self.assertIn("return true", hold)
        self.assertEqual(code.count("installNow?()"), 1)
        act = self.source[self.source.index("func actOnWaiting()"):self.source.index("func checkNow()")]
        self.assertIn("installNow?()", act)
        # A scheduled update Sparkle would show in a window is offered quietly instead (Update DayDream…).
        self.assertIn("func standardUserDriverShouldHandleShowingScheduledUpdate(_ update:SUAppcastItem,andInImmediateFocus immediateFocus:Bool)->Bool { false }", self.source)
        self.assertIn("var supportsGentleScheduledUpdateReminders:Bool { true }", self.source)
        self.assertIn("updateWaiting(.review(version:", self.source)
        # Never asks to check, and never fires a notification or a window of its own.
        self.assertIn("func updaterShouldPromptForPermissionToCheck(forUpdates updater:SPUUpdater)->Bool { false }", self.source)
        for word in ("UNUserNotificationCenter", "NSAlert", "NSUserNotification", "orderFront", "makeKeyAndOrderFront", "activate("):
            self.assertNotIn(word, code)

    def test_restart_to_update_is_offered_in_the_menus(self):
        menu = (ROOT / "Sources/MemoryUI/MenuBarMenu.swift").read_text()
        panel = (ROOT / "Sources/MacMemApp/MenuBarContent.swift").read_text()
        commands = (ROOT / "Sources/MacMemApp/AppCommands.swift").read_text()
        self.assertIn("if let update, !update.isEmpty { rows.append(Row(action: .update, title: update, key: nil)) }", menu)
        self.assertIn("case .update: update?.run()", menu)
        self.assertIn("update: updates.waiting.map", panel)
        self.assertIn("updates.actOnWaiting()", panel)
        self.assertIn("if let waiting = updates.waiting { Button(waiting.title) { updates.actOnWaiting() } }", commands)
        self.assertIn('public static let restartTitle="Restart to Update"', self.policy)

    def test_settings_text_comes_from_update_text(self):
        for name in ("sourceNote", "switchTitle"):
            self.assertIn("Text(UpdateText.%s)" % name, self.source)
        self.assertIn("Button(UpdateText.checkTitle) { updates.checkNow() }", self.source)
        self.assertIn("Button(waiting.title) { updates.actOnWaiting() }", self.source)
        # sat5: one switch; Sparkle's raw error text never reaches the page.
        self.assertNotIn("Download and install updates automatically", self.source)
        self.assertNotIn("localizedDescription", self.source)
        self.assertNotIn("keepNote", self.policy)
        self.assertNotIn("03:00", self.source)
        # UpdateText's body only: the resume marker's key and Sparkle's error domain aren't page text.
        start = self.policy.index("enum UpdateText")
        strings = re.findall(r'"((?:[^"\\]|\\.)*)"', self.policy[start:self.policy.index("\n}\n", start)])
        self.assertGreater(len(strings), 10)
        for text in strings:
            for word in ("Mac Mem", "Sparkle", "appcast", "EdDSA", "Daydream"):
                self.assertNotIn(word, text)


class BundledCLI(TempCase):
    def test_bundled_mcp_carries_on_as_the_replacement(self):
        # gold G13: the AI app's server is never left answering with errors until a restart. Once the new copy is in
        # place it answers as that copy (scripts/mcp-update-checks.py covers the mid-swap and hash cases).
        fixture_cli = built_cli()
        contents = self.root / "DayDream.app/Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Resources").mkdir()
        cli = contents / "MacOS/mac-mem"
        shutil.copy2(fixture_cli, cli)
        manifest = contents / "Resources/Companions.json"
        manifest.write_text(json.dumps({"schema": 1, "build": "1", "version": "0.1.0 Beta"}))
        home = self.root / "synthetic-memory"
        subprocess.run([str(cli), "--home", str(home), "demo"], check=True, capture_output=True)
        child = subprocess.Popen([str(cli), "--home", str(home), "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            child.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize"}) + "\n")
            child.stdin.flush()
            self.assertEqual(json.loads(child.stdout.readline())["result"]["serverInfo"]["version"], "0.1.0 Beta")
            manifest.write_text(json.dumps({"schema": 1, "build": "2", "version": "0.2.0 Beta"}))
            child.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 2, "method": "ping"}) + "\n")
            child.stdin.flush()
            reply = json.loads(child.stdout.readline())
            self.assertNotIn("error", reply)
            self.assertEqual(reply["id"], 2)
            child.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 3, "method": "initialize"}) + "\n")
            child.stdin.flush()
            self.assertEqual(json.loads(child.stdout.readline())["result"]["serverInfo"]["version"], "0.2.0 Beta")
        finally:
            child.stdin.close()
            child.wait(timeout=5)
            child.stdout.close()
        result = json.loads(subprocess.check_output([str(cli), "version"], text=True))
        self.assertEqual(result["version"], "0.2.0 Beta")


if __name__ == "__main__":
    unittest.main()
