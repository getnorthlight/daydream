"""Inert fixture policy checks: no app execution, service, signing or credentials.

ship-1004 (owner decision 2026-10-03, "Ship typesense."): the reviewed record now clears public distribution with
the Complete Corresponding Source kit named by sha256. The old private record, a forged record and a record naming
any other kit stay refused; each old private-behaviour check now asserts the public behaviour or the refusal."""
import hashlib
import json
import plistlib
import shutil
import struct
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import search_payload as s
import functional_payload as legacy
import release


REAL_NOTICE = (Path(__file__).resolve().parent.parent / s.SOURCE_DIR / 'Typesense-NOTICES.txt').read_text()
REAL_PINS = {name: getattr(s, name) for name in ('SERVER_SHA256', 'ARCHIVE_SHA256', 'LICENSE_SHA256')}


def private_record():
    """The record every build carried before 2026-10-03: private self-use, source incomplete."""
    record = {k: v for k, v in s.expected_distribution().items()
              if k not in ('modified', 'publicDistributionApproval', 'sourceCommit', 'correspondingSource')}
    record.update(scope='private-local-self-use', publicDistribution=False, completeCorrespondingSource=False)
    return record


class SearchPayloadChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='daydream-search-payload-', dir='/private/tmp')
        self.root = Path(self.temp.name).resolve()
        self.source = self.root / 'source'
        self.inputs = self.root / 'inputs'
        self.directory = self.source / s.SOURCE_DIR
        self.directory.mkdir(parents=True)
        self.inputs.mkdir()
        server = struct.pack('<8I', 0xfeedfacf, 0x0100000c, 0, 2, 1, 24, 0, 0) + struct.pack('<6I', 0x32, 24, 1, 13 << 16 | 1 << 8, 13 << 16 | 1 << 8, 0)
        (self.inputs / 'typesense-server').write_bytes(server)
        (self.inputs / 'typesense-server').chmod(0o755)
        (self.inputs / 'runtime.tar.gz').write_bytes(b'fabricated archive, never extracted or executed')
        for name, value in [('SERVER_SHA256', s.digest(self.inputs / 'typesense-server')), ('ARCHIVE_SHA256', s.digest(self.inputs / 'runtime.tar.gz'))]:
            patcher = patch.object(s, name, value);patcher.start();self.addCleanup(patcher.stop)
        (self.directory / 'local-typesense-v30.2.json').write_text(json.dumps(s.expected_distribution()))
        (self.directory / 'Typesense-LICENSE.txt').write_text('GNU GENERAL PUBLIC LICENSE fixture, never distributed')
        # The committed GPL notice text (no personal data); notice_problems() requires it to name the recorded kit.
        (self.directory / 'Typesense-NOTICES.txt').write_text(REAL_NOTICE)
        patcher = patch.object(s, 'LICENSE_SHA256', s.digest(self.directory / 'Typesense-LICENSE.txt'));patcher.start();self.addCleanup(patcher.stop)
        self.app = self.root / 'DayDream.app'
        c = self.app / 'Contents'
        (c / 'MacOS').mkdir(parents=True)
        (c / 'Resources').mkdir()
        for name in ['MacMem', 'mac-mem', 'mac-mem-backup']:
            (c / 'MacOS' / name).write_bytes(b'fabricated companion, never executed')
            (c / 'MacOS' / name).chmod(0o755)
        (c / 'Resources/before_turn.py').write_text('# inert fixture')
        (c / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.getnorthlight.daydream', 'CFBundleVersion': '1', 'LSMinimumSystemVersion': '13.1', 'CFBundleShortVersionString': '0.1.4 Beta'}))

    def tearDown(self):
        self.temp.cleanup()

    def private(self):
        """A commit whose reviewed record is still the private one (as before 2026-10-03)."""
        record = private_record()
        patcher = patch.object(s, 'expected_distribution', lambda: dict(record));patcher.start();self.addCleanup(patcher.stop)
        (self.directory / 'local-typesense-v30.2.json').write_text(json.dumps(record))

    def fixture_kit(self, data=b'fabricated corresponding-source kit, never published'):
        """A fabricated kit file and the constants pinned to it; the record and notice name its sha256."""
        kit = self.root / 'kit' / s.SOURCE_KIT_NAME
        kit.parent.mkdir(exist_ok=True)
        kit.write_bytes(data)
        real = s.SOURCE_KIT_SHA256
        for name, value in [('SOURCE_KIT_SHA256', s.digest(kit)), ('SOURCE_KIT_BYTES', len(data))]:
            patcher = patch.object(s, name, value);patcher.start();self.addCleanup(patcher.stop)
        (self.directory / 'local-typesense-v30.2.json').write_text(json.dumps(s.expected_distribution()))
        (self.directory / 'Typesense-NOTICES.txt').write_text(REAL_NOTICE.replace(real, s.SOURCE_KIT_SHA256))
        return kit

    def set_info(self, **values):
        p = self.app / 'Contents/Info.plist';info = plistlib.loads(p.read_bytes());info.update(values);p.write_bytes(plistlib.dumps(info))

    def gates(self):
        # release.py's first gates (the appcast and prepare both run them), with the inert writer stand-in.
        with patch.object(release.writer_payload, 'paths', return_value={'inert-runtime'}):
            release._payload_gates(self.app)

    def assemble(self):
        return s.assemble(self.app, self.source, self.inputs)

    def stage_fixture(self, *updates):
        # Reuse the existing inert builder/signature inspector, never sign or run.
        import check_developer_id_release as checks
        fixture = checks.StageFromCommit(methodName='test_clean_commit_stages_with_commit_recorded')
        fixture.setUp();self.addCleanup(fixture.doCleanups)
        destination = fixture.repo / s.SOURCE_DIR
        shutil.rmtree(destination, ignore_errors=True)
        shutil.copytree(self.directory, destination)
        checks.git(fixture.repo, 'add', s.SOURCE_DIR)
        checks.git(fixture.repo, 'commit', '-q', '-m', 'fabricated search metadata')
        args = checks.dr.build_parser().parse_args(['stage', '--out', str(fixture.folder / 'search-out'), '--build', '20260930120000', '--first-build'] + list(updates or ('--updates', 'off')) + ['--typesense-inputs', str(self.inputs)])
        return checks, fixture, args

    def run_stage(self, checks, fixture, args):
        import contextlib, io
        with contextlib.redirect_stdout(io.StringIO()):
            checks.dr.cmd_stage(args, runner=checks.HybridRunner(), root=fixture.repo, builder=fixture.builder)
        return fixture.folder / 'search-out'

    def test_public_stage_carries_typesense_feed_and_kit(self):
        # NEW (ship-1004): a public stage (updates configured) bundles Typesense, takes the website feed and quiet
        # updates, and records the source kit it checked byte for byte.
        kit = self.fixture_kit()
        checks, fixture, args = self.stage_fixture('--updates', 'configured', '--typesense-source-kit', str(kit))
        out = self.run_stage(checks, fixture, args)
        target = out / 'DayDream.app'
        self.assertEqual(s.paths(target), s.PAYLOAD)
        self.assertTrue(s.public_cleared_app(target))
        info = plistlib.loads((target / 'Contents/Info.plist').read_bytes())
        self.assertIn('SUFeedURL', info)
        self.assertIs(info['SUEnableAutomaticChecks'], True)
        self.assertNotIn(s.TEST_ONLY_KEY, info)
        receipt = json.loads((out / 'stage-receipt.json').read_text())
        self.assertEqual(receipt['updates'], 'configured')
        self.assertEqual(receipt['typesense_source_kit'], {'name': s.SOURCE_KIT_NAME, 'sha256': s.digest(kit), 'bytes': kit.stat().st_size})
        self.assertIn(s.digest(kit), (target / 'Contents' / s.NOTICES).read_text())

    def test_public_stage_without_matching_kit_refused_before_build(self):
        # NEW (ship-1004): no kit, or a kit that is not the recorded bytes, stops a public stage before anything is built.
        kit = self.fixture_kit()
        checks, fixture, args = self.stage_fixture('--updates', 'configured')
        with self.assertRaisesRegex(Exception, 'typesense-source-kit'):
            checks.dr.cmd_stage(args, runner=checks.HybridRunner(), root=fixture.repo, builder=fixture.builder)
        other = self.root / 'other' / s.SOURCE_KIT_NAME;other.parent.mkdir();other.write_bytes(kit.read_bytes() + b'drift')
        args.typesense_source_kit = str(other)
        with self.assertRaisesRegex(ValueError, 'does not match the recorded sha256'):
            checks.dr.cmd_stage(args, runner=checks.HybridRunner(), root=fixture.repo, builder=fixture.builder)
        self.assertEqual(fixture.built, [])
        self.assertFalse(Path(args.out).exists())

    def test_sign_gate_follows_the_record(self):
        # CHANGED (ship-1004): sign refused every updates-on Typesense app; now only one whose record is not the cleared
        # public one. Checked from the source, as check_developer_id_release.py checks cmd_sign: nothing is signed here.
        import check_developer_id_release as checks
        source = (Path(checks.dr.__file__)).read_text()
        sign = source[source.index('def cmd_sign('):source.index('def cmd_verify(')]
        self.assertIn("require(args.updates == 'off' or search_payload.public_cleared_app(source),", sign)
        self.assertNotIn("require(args.updates == 'off', 'Local Typesense copy requires updates off')", sign)
        self.assertIn("search_payload.SERVER_SHA256", sign)
        self.assemble()
        self.assertTrue(s.public_cleared_app(self.app))

    def test_uncleared_commit_public_stage_still_needs_updates_off(self):
        # CHANGED (ship-1004): was the only behaviour; now only a commit with the private record is refused.
        self.private()
        checks, fixture, args = self.stage_fixture('--updates', 'configured')
        with self.assertRaisesRegex(Exception, 'pass --updates off'):
            checks.dr.cmd_stage(args, runner=checks.HybridRunner(), root=fixture.repo, builder=fixture.builder)
        self.assertEqual(fixture.built, [])

    def test_default_developer_stage_includes_search_without_legacy_writer(self):
        # The owner stage (--updates off) still bundles Typesense and needs no kit.
        checks, fixture, args = self.stage_fixture()
        self.run_stage(checks, fixture, args)
        target = fixture.folder / 'search-out/DayDream.app'
        self.assertEqual(s.paths(target), s.PAYLOAD)
        self.assertEqual(legacy.paths(target), set())
        receipt = json.loads((fixture.folder / 'search-out/stage-receipt.json').read_text())
        self.assertFalse(receipt['test_only_without_search_runtime'])
        self.assertEqual(receipt['search_runtime'], s.runtime_manifest(target))
        self.assertIsNone(receipt['typesense_source_kit'])
        self.assertNotIn(s.TEST_ONLY_KEY, plistlib.loads((target / 'Contents/Info.plist').read_bytes()))

    def test_default_stage_missing_inputs_fails_before_build(self):
        checks, fixture, args = self.stage_fixture();args.typesense_inputs = str(self.root / 'not-present')
        with self.assertRaisesRegex(ValueError, 'Missing/unsafe'):
            checks.dr.cmd_stage(args, runner=checks.HybridRunner(), root=fixture.repo, builder=fixture.builder)
        self.assertEqual(fixture.built, [])
        self.assertFalse(Path(args.out).exists())

    def test_payload_is_independent_of_legacy_writer(self):
        self.assemble()
        self.assertEqual(s.paths(self.app), s.PAYLOAD)
        self.assertEqual(legacy.paths(self.app), set())
        self.assertFalse((self.app / 'Contents' / legacy.MANIFEST).exists())
        release.manifest(self.app, source_commit='a' * 40)
        release.audit(self.app)
        hashes = json.loads((self.app / 'Contents/Resources/Companions.json').read_text())['sha256']
        self.assertTrue(s.PAYLOAD <= hashes.keys())

    def test_test_only_missing_search_build_cannot_release(self):
        p = self.app / 'Contents/Info.plist';info = plistlib.loads(p.read_bytes());info[s.TEST_ONLY_KEY] = True;p.write_bytes(plistlib.dumps(info))
        with patch.object(release.writer_payload, 'paths', return_value={'inert-runtime'}), self.assertRaisesRegex(ValueError, 'Test-only'):
            release.prepare(self.app, {}, None, 0, None, False)
        with self.assertRaisesRegex(ValueError, 'Test-only'):
            self.assemble()

    def test_minimum_os_cannot_understate_runtime(self):
        p = self.app / 'Contents/Info.plist';info = plistlib.loads(p.read_bytes());info['LSMinimumSystemVersion'] = '13.0';p.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, 'minimum macOS'):
            self.assemble()

    def test_other_app_identity_cannot_claim_runtime(self):
        p = self.app / 'Contents/Info.plist';info = plistlib.loads(p.read_bytes());info['CFBundleIdentifier'] = 'fiction.other.app';p.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, 'identity'):
            self.assemble()

    def test_cleared_runtime_may_carry_public_update_feed(self):
        # CHANGED (ship-1004): was test_local_runtime_never_reads_public_update_feed. The cleared public record lets
        # the Typesense app carry the feed and automatic checks.
        self.set_info(SUFeedURL='https://fiction.example/appcast.xml', SUEnableAutomaticChecks=True)
        self.assemble()
        self.assertEqual(s.paths(self.app), s.PAYLOAD)

    def test_uncleared_runtime_never_reads_public_update_feed(self):
        # The old rule, kept for a commit whose record is still private.
        self.private()
        self.set_info(SUFeedURL='https://fiction.example/feed')
        with self.assertRaisesRegex(ValueError, 'updates off'):
            self.assemble()
        self.set_info(SUEnableAutomaticChecks=True)
        with self.assertRaisesRegex(ValueError, 'updates off'):
            self.assemble()

    def test_public_distribution_cleared_by_recorded_kit(self):
        # CHANGED (ship-1004): was test_public_distribution_remains_refused. release.py's appcast/prepare gate
        # accepts the app whose record is the cleared public one.
        self.assemble()
        self.assertTrue(s.public_cleared_app(self.app))
        self.gates()

    def test_private_record_still_refused_for_public(self):
        self.private()
        self.assemble()
        self.assertFalse(s.public_cleared_app(self.app))
        with self.assertRaisesRegex(ValueError, 'not cleared for public'):
            release.prepare(self.app, {}, None, 0, None, False)
        with self.assertRaisesRegex(ValueError, 'not cleared for public'):
            self.gates()

    def test_public_cleared_requires_complete_source_and_recorded_kit(self):
        record = s.expected_distribution()
        self.assertTrue(s.public_cleared(record))
        self.assertIs(record['publicDistribution'], True)
        self.assertIs(record['completeCorrespondingSource'], True)
        self.assertIs(record['modified'], False)
        self.assertEqual(record['correspondingSource']['sha256'], s.SOURCE_KIT_SHA256)
        self.assertEqual(record['correspondingSource']['snowballDetermination'], 'best-determination')
        self.assertFalse(s.public_cleared(private_record()))
        self.assertFalse(s.public_cleared({**record, 'completeCorrespondingSource': False}))
        self.assertFalse(s.public_cleared({**record, 'publicDistribution': False}))
        self.assertFalse(s.public_cleared({**record, 'correspondingSource': {**record['correspondingSource'], 'sha256': '0' * 64}}))
        self.assertFalse(s.public_cleared({k: v for k, v in record.items() if k != 'correspondingSource'}))
        self.assertFalse(s.public_cleared({**record, 'scope': 'private-local-self-use'}))
        self.assertFalse(s.public_cleared(None))

    def test_source_kit_must_match_recorded_sha(self):
        kit = self.fixture_kit()
        self.assertEqual(s.verify_source_kit(kit), kit)
        kit.write_bytes(kit.read_bytes()[:-1] + b'X')
        with self.assertRaisesRegex(ValueError, 'does not match the recorded sha256'):
            s.verify_source_kit(kit)
        renamed = kit.with_name('typesense-source.tar.gz');kit.rename(renamed)
        with self.assertRaisesRegex(ValueError, 'does not match the recorded sha256'):
            s.verify_source_kit(renamed)

    def test_private_notice_wording_refused(self):
        (self.directory / 'Typesense-NOTICES.txt').write_text(
            'Typesense30.2, copyright Typesense authors. Licensed under GNU GPLv3; see Typesense-LICENSE.txt.\n'
            'This app copy is for private local self-use. ... this payload is not approved for public distribution.\n')
        with self.assertRaisesRegex(ValueError, 'GPL notice for the recorded source kit'):
            self.assemble()
        self.assertFalse((self.app / 'Contents' / s.SERVER).exists())

    def test_committed_notice_and_record_are_public(self):
        # The committed files themselves: the record is the cleared one and the notice is the GPL notice for its kit.
        directory = Path(__file__).resolve().parent.parent / s.SOURCE_DIR
        with patch.multiple(s, **REAL_PINS):
            self.assertEqual(json.loads((directory / 'local-typesense-v30.2.json').read_text()), s.expected_distribution())
            self.assertTrue(s.public_cleared(json.loads((directory / 'local-typesense-v30.2.json').read_text())))
            self.assertEqual(s.digest(directory / 'Typesense-LICENSE.txt'), s.LICENSE_SHA256)
        self.assertEqual(s.notice_problems((directory / 'Typesense-NOTICES.txt').read_text()), [])

    def test_exact_allowlist_rejects_extra_helper(self):
        self.assemble()
        (self.app / 'Contents/Helpers/unreviewed-helper').write_text('inert')
        with self.assertRaisesRegex(ValueError, 'Unexpected release payload'):
            release.audit(self.app)

    def test_stale_server_hash_refused(self):
        self.assemble()
        p = self.app / 'Contents' / s.SERVER;p.write_bytes(p.read_bytes() + b'drift')
        with self.assertRaisesRegex(ValueError, 'Stale final'):
            s.paths(self.app)

    def test_final_supervisor_hash_refresh_after_nested_change(self):
        self.assemble()
        p = self.app / 'Contents/MacOS/mac-mem';p.write_bytes(b'fictional new final helper bytes')
        with self.assertRaisesRegex(ValueError, 'Stale final'):
            s.paths(self.app)
        release.manifest(self.app)
        self.assertEqual(s.paths(self.app), s.PAYLOAD)
        self.assertEqual(json.loads((self.app / 'Contents' / s.RUNTIME).read_text())['supervisorSHA256'], s.digest(p))

    def test_missing_piece_is_not_silently_optional(self):
        self.assemble()
        (self.app / 'Contents' / s.NOTICES).rename(self.root / 'saved-notice')
        with self.assertRaisesRegex(ValueError, 'Missing/unsafe'):
            s.paths(self.app)

    def test_wrong_input_pin_fails_before_assembly(self):
        p = self.inputs / 'typesense-server';p.write_bytes(p.read_bytes() + b'drift')
        with self.assertRaisesRegex(ValueError, 'Unreviewed'):
            self.assemble()
        self.assertFalse((self.app / 'Contents' / s.SERVER).exists())

    def test_wrong_platform_is_refused(self):
        p = self.inputs / 'typesense-server';data = bytearray(p.read_bytes());struct.pack_into('<I', data, 40, 2);p.write_bytes(data)
        with patch.object(s, 'SERVER_SHA256', s.digest(p)):
            with self.assertRaisesRegex(ValueError, 'platform'):
                self.assemble()

    def test_symlink_input_refused(self):
        p = self.inputs / 'typesense-server';p.rename(self.inputs / 'actual-server');p.symlink_to(self.inputs / 'actual-server')
        with self.assertRaisesRegex(ValueError, 'Missing/unsafe'):
            self.assemble()

    def test_new_policy_cannot_claim_legacy_trial(self):
        self.assemble()
        (self.app / 'Contents/Resources/FunctionalTrial.json').write_text('{}')
        with self.assertRaisesRegex(ValueError, 'mix'):
            legacy.paths(self.app)

    def test_sealed_app_cannot_refresh(self):
        self.assemble()
        (self.app / 'Contents/_CodeSignature').mkdir()
        with self.assertRaisesRegex(ValueError, 'sealed'):
            release.manifest(self.app)

    def test_assembly_refuses_overwrite(self):
        self.assemble()
        with self.assertRaisesRegex(ValueError, 'overwrite'):
            self.assemble()

    def test_normal_app_without_payload_is_not_claimed(self):
        self.assertFalse(s.present(self.app))
        self.assertEqual(s.paths(self.app), set())
        self.assertEqual(legacy.paths(self.app), set())

    def test_forged_public_scope_is_refused(self):
        # CHANGED (ship-1004): the record is public now, so the forgeries are a public claim without complete source,
        # a record naming another kit, and a private record swapped back in. Each is refused by paths() and the gate.
        self.assemble()
        p = self.app / 'Contents' / s.DISTRIBUTION;good = json.loads(p.read_text())
        kit = dict(good['correspondingSource'], sha256='e' * 64)
        for forged in ({**good, 'completeCorrespondingSource': False}, {**good, 'correspondingSource': kit},
                       {**private_record(), 'publicDistribution': True}, private_record()):
            p.write_text(json.dumps(forged))
            with self.assertRaisesRegex(ValueError, 'scope'):
                s.paths(self.app)
            with self.assertRaisesRegex(ValueError, 'scope'):
                self.gates()
        p.write_text(json.dumps(good))
        self.assertTrue(s.public_cleared_app(self.app))


if __name__ == '__main__':
    unittest.main()
