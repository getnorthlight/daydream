"""Structure checks for scripts/developer-id-release.py. No signing, upload or launch.

Run: python3 -B scripts/check_developer_id_release.py
"""
import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import plistlib
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))


def load_pipeline():
    name = 'developer_id_release'
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, SCRIPTS / 'developer-id-release.py')
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name]


dr = load_pipeline()
import release  # noqa: E402
import functional_payload  # noqa: E402
import writer_payload  # noqa: E402

SHA1 = 'A' * 40
# A thin arm64 Mach-O header with one LC_BUILD_VERSION (macOS, minos 15.0): what release.platform_problems needs.
MACHO = (struct.pack('<8I', 0xfeedfacf, 0x0100000C, 0, 2, 1, 24, 0, 0)
         + struct.pack('<6I', 0x32, 24, 1, 0x000F0000, 0x000F0000, 0))

ADHOC_HELPER = """Executable=/x/DayDream.app/Contents/MacOS/mac-mem
Identifier=com.getnorthlight.daydream.mac-mem
Format=Mach-O thin (arm64)
CodeDirectory v=20500 size=219293 flags=0x10002(adhoc,runtime) hashes=6842+7 location=embedded
CDHash=4b7a64cdcb4e20dbd01f2959afaec964c7656d50
Signature=adhoc
Info.plist=not bound
TeamIdentifier=not set
Runtime Version=15.0.0
"""
DEVID_APP = """Executable=/x/DayDream.app/Contents/MacOS/MacMem
Identifier=com.getnorthlight.daydream
CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+7 location=embedded
CDHash=00
Signature size=8986
Authority=Developer ID Application: Fixture Owner (L76C3ZC66J)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
Timestamp=Sep 24, 2026 at 1:00:00 PM
TeamIdentifier=L76C3ZC66J
"""


def synthetic_app(root, typesense=False):
    app = Path(root) / 'DayDream.app'
    contents = app / 'Contents'
    for rel in sorted(dr.KNOWN_MACHO):
        if rel == functional_payload.SERVER and not typesense:
            continue
        path = contents / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(MACHO)
    return app


class EntitlementFiles(unittest.TestCase):
    def test_files_are_exact_xml_and_linted(self):
        self.assertTrue(dr.lint_entitlements())
        names = sorted(p.name for p in dr.ENTITLEMENTS_DIR.iterdir())
        # Public builds bundle no Node runtime, so the only entitlements file is the opt-in one.
        self.assertEqual(names, ['main-apple-events.entitlements'])
        load = lambda n: plistlib.loads((dr.ENTITLEMENTS_DIR / n).read_bytes())
        self.assertEqual(load('main-apple-events.entitlements'), {'com.apple.security.automation.apple-events': True})
        for name in names:
            self.assertNotIn(dr.GET_TASK_ALLOW, load(name))

    def test_drift_and_get_task_allow_rejected(self):
        with tempfile.TemporaryDirectory(prefix='daydream-ent-') as folder:
            copy = Path(folder) / 'e'
            shutil.copytree(dr.ENTITLEMENTS_DIR, copy)
            value = {dr.APPLE_EVENTS: True, dr.GET_TASK_ALLOW: True}
            (copy / 'main-apple-events.entitlements').write_bytes(plistlib.dumps(value))
            with self.assertRaisesRegex(dr.ReleaseError, 'drift'):
                dr.lint_entitlements(directory=copy)
            (copy / 'main-apple-events.entitlements').write_bytes(plistlib.dumps({dr.APPLE_EVENTS: True}))
            (copy / 'extra.entitlements').write_bytes(plistlib.dumps({}))
            with self.assertRaisesRegex(dr.ReleaseError, 'Unexpected'):
                dr.lint_entitlements(directory=copy)

    def test_main_app_has_no_entitlements_by_default(self):
        self.assertEqual(dr.expected_entitlements(dr.MAIN), {})
        self.assertEqual(dr.expected_entitlements(dr.MAIN, apple_events=True), {dr.APPLE_EVENTS: True})
        self.assertEqual(dr.expected_entitlements(dr.PRESERVE), {})
        self.assertEqual(dr.expected_entitlements(None), {})


class SigningOrderAndFlags(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='daydream-sign-order-')
        self.addCleanup(self.temp.cleanup)
        self.app = synthetic_app(self.temp.name, typesense=True)

    def steps(self, identity='-', **kw):
        writer = ['Contents/' + writer_payload.LIBROOT + n for n in ('libllama.0.dylib', 'libggml.0.dylib')]
        return dr.sign_steps(self.app, identity, writer_libs=writer, **kw)

    def test_inside_out_order(self):
        rows = [s['row'] for s in self.steps()]
        self.assertEqual(rows, ['sparkle-installer', 'sparkle-downloader', 'sparkle-autoupdate', 'sparkle-updater',
                                'sparkle-framework', 'writer-runtime', 'writer-runtime', 'typesense-server',
                                'mac-mem', 'mac-mem-backup', 'companions', 'app'])
        steps = self.steps()
        self.assertEqual(steps[-1]['argv'][-1], str(self.app))
        self.assertEqual(steps[-2]['action'], 'manifest')

    def test_flags_every_sign(self):
        for identity, stamp in (('-', '--timestamp=none'), (SHA1, '--timestamp')):
            for step in self.steps(identity):
                argv = step['argv']
                self.assertNotIn('--deep', argv)
                if step['action'] != 'sign':
                    continue
                self.assertEqual(argv[:4], ['codesign', '--force', '--sign', identity])
                self.assertIn(stamp, argv)
                self.assertEqual(argv[argv.index('--options') + 1], 'runtime')
                self.assertEqual(sum(a.startswith('--timestamp') for a in argv), 1)

    def by_row(self, steps):
        return {s['row']: s['argv'] for s in steps if s['action'] == 'sign'}

    def test_per_item_entitlements_and_identifiers(self):
        rows = self.by_row(self.steps())
        self.assertNotIn('--entitlements', rows['sparkle-autoupdate'])
        self.assertFalse(any(a.startswith('--preserve-metadata') for a in rows['sparkle-autoupdate']))
        self.assertIn('--preserve-metadata=entitlements', rows['sparkle-downloader'])
        self.assertNotIn('--entitlements', rows['sparkle-downloader'])
        for key in ('sparkle-installer', 'sparkle-updater', 'sparkle-framework', 'typesense-server', 'mac-mem', 'mac-mem-backup', 'app'):
            self.assertNotIn('--entitlements', rows[key], key)
        ids = {k: v[v.index('--identifier') + 1] for k, v in rows.items() if '--identifier' in v}
        self.assertEqual(ids, {'typesense-server': 'com.getnorthlight.daydream.typesense-server',
                               'mac-mem': 'com.getnorthlight.daydream.mac-mem', 'mac-mem-backup': 'com.getnorthlight.daydream.mac-mem-backup'})

    def test_opt_ins(self):
        rows = self.by_row(self.steps(apple_events=True))
        app = rows['app']
        self.assertEqual(Path(app[app.index('--entitlements') + 1]).name, 'main-apple-events.entitlements')
        self.assertFalse(any('daydream-node' in ' '.join(v) for v in rows.values()))

    def test_writer_dylibs_verify_only(self):
        steps = self.steps(SHA1)
        writer = [s for s in steps if s['row'] == 'writer-runtime']
        self.assertEqual({s['action'] for s in writer}, {'verify'})
        for s in writer:
            self.assertEqual(s['argv'][:3], ['codesign', '--verify', '--strict'])
        self.assertFalse(any('WriterRuntime' in s['argv'][-1] for s in steps if s['action'] == 'sign'))

    def test_optional_rows_skipped(self):
        app = synthetic_app(Path(self.temp.name) / 'plain')
        rows = [s['row'] for s in dr.sign_steps(app, '-', writer_libs=[])]
        self.assertNotIn('typesense-server', rows)
        self.assertNotIn('daydream-node', rows)
        self.assertNotIn('writer-runtime', rows)
        self.assertEqual(rows[-2:], ['companions', 'app'])


class IdentityAndParsers(unittest.TestCase):
    def test_identity(self):
        self.assertEqual(dr.identity_kind('-'), 'adhoc')
        self.assertEqual(dr.identity_kind(SHA1.lower()), 'developer-id')
        for bad in ('', 'Developer ID Application: Someone (L76C3ZC66J)', 'A' * 39, 'G' * 40):
            with self.assertRaises(dr.ReleaseError):
                dr.identity_kind(bad)

    def test_coverage_flags_unknown_macho(self):
        with tempfile.TemporaryDirectory(prefix='daydream-cov-') as folder:
            app = synthetic_app(folder)
            self.assertEqual(dr.coverage_problems(app), [])
            (app / 'Contents/Helpers').mkdir(exist_ok=True)
            (app / 'Contents/Helpers/BrowserBridgeHost').write_bytes(MACHO)
            (app / 'Contents/Resources').mkdir(exist_ok=True)
            (app / 'Contents/Resources/notes.txt').write_text('not code')
            self.assertEqual(dr.coverage_problems(app), ['Helpers/BrowserBridgeHost'])

    def test_known_macho_matches_pinned_sparkle(self):
        vendor = dr.SPARKLE_VENDOR
        found = {'Frameworks/Sparkle.framework/' + p.relative_to(vendor).as_posix() for p in dr.walk_files(vendor) if dr.is_macho(p)}
        self.assertEqual(found, {m for m in dr.KNOWN_MACHO if m.startswith('Frameworks/Sparkle.framework/')})

    def test_linkage_and_rpath(self):
        libs = dr.parse_otool_libraries('/x/MacMem:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)\n'
                                        '\t@rpath/Sparkle.framework/Versions/B/Sparkle (compatibility version 1.6.0, current version 2.9.6)\n'
                                        '\t@rpath/libswiftCompatibility56.dylib (compatibility version 1.0.0, current version 1.0.0)\n')
        self.assertEqual(dr.linkage_problems('MacOS/MacMem', libs), ['@rpath/libswiftCompatibility56.dylib'])
        self.assertEqual(dr.linkage_problems('MacOS/mac-mem', libs[:2]), ['@rpath/Sparkle.framework/Versions/B/Sparkle'])
        text = ('Load command 18\n          cmd LC_RPATH\n      cmdsize 32\n         path /usr/lib/swift (offset 12)\n'
                'Load command 19\n          cmd LC_RPATH\n      cmdsize 72\n         path /Library/Developer/CommandLineTools/usr/lib/swift-6.2/macosx (offset 12)\n')
        rpaths = dr.parse_rpaths(text)
        self.assertEqual(rpaths, ['/usr/lib/swift', '/Library/Developer/CommandLineTools/usr/lib/swift-6.2/macosx'])
        self.assertTrue(rpaths[1].startswith(dr.TOOLCHAIN_RPATH_PREFIXES))
        self.assertNotIn(rpaths[1], dr.ALLOWED_RPATHS)

    def test_macho_archs(self):
        with tempfile.TemporaryDirectory(prefix='daydream-arch-') as folder:
            thin = Path(folder) / 'thin'
            thin.write_bytes(MACHO)
            self.assertEqual(dr.macho_archs(thin), {'arm64'})
            x86 = Path(folder) / 'x86'
            x86.write_bytes(bytes.fromhex('cffaedfe') + (0x01000007).to_bytes(4, 'little') + bytes(24))
            self.assertEqual(dr.macho_archs(x86), {'x86_64'})


FIXTURE_KEY = '11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo='  # RFC 8032 test vector 1; never a real key
FIXTURE_UPDATES = {'owner': 'getnorthlight', 'repository': 'daydream', 'site': 'getdaydream.app',
                   'feed': 'https://getdaydream.app/appcast.xml',
                   'public_key': FIXTURE_KEY}


class InfoPolicy(unittest.TestCase):
    def template(self):
        return plistlib.loads((dr.ROOT / 'packaging/Info.plist').read_bytes())

    def test_release_info_is_clean(self):
        info = dr.release_info(self.template(), '20260924120000', '0.1.0', '15.0', writer=None)
        self.assertEqual(dr.info_problems(info, writer=None), [])
        self.assertEqual(info['CFBundleDisplayName'], 'DayDream')
        self.assertEqual(info['LSMinimumSystemVersion'], '15.0')
        self.assertNotIn('DaydreamWriterRuntimeDistribution', info)
        # Every release carries "On this Mac" (owner decision 2026-09-26): the key names the signed runtime.
        writer = dr.release_info(self.template(), '20260924120000', '0.1.0', '15.0', writer=writer_payload.ID)
        self.assertEqual(writer['DaydreamWriterRuntimeDistribution'], writer_payload.ID)
        self.assertEqual(dr.info_problems(writer, writer=writer_payload.ID), [])
        self.assertTrue(dr.info_problems(writer, writer=functional_payload.ID))
        self.assertTrue(dr.info_problems(writer, writer=None))

    def test_beta_label_is_in_the_version_string(self):
        # Item 31: the About box shows CFBundleShortVersionString, so "Beta" lives there.
        info = dr.release_info(self.template(), '20260924120000', '0.1.0', '15.0', writer=None)
        self.assertEqual(info['CFBundleShortVersionString'], '0.1.0 Beta')
        plain = dr.release_info(self.template(), '20260924120000', '0.1.0', '15.0', writer=None, beta=False)
        self.assertEqual(plain['CFBundleShortVersionString'], '0.1.0')
        for bad in ('0.1.0 beta', '0.1.0-beta', 'Beta 0.1.0', '0.1', '1'):
            problems = dr.info_problems({**info, 'CFBundleShortVersionString': bad}, writer=None)
            self.assertEqual(any('CFBundleShortVersionString' in p for p in problems), bad != '0.1', bad)
        self.assertEqual(release.version_core('0.1.0 Beta'), '0.1.0')
        self.assertEqual(release.release_tag('0.1.0 Beta'), 'v0.1.0')
        self.assertEqual(dr.dmg_name('0.1.0 Beta'), 'DayDream-0.1.0.dmg')
        self.assertEqual(dr.dmg_label('0.1.0 Beta'), 'DayDream 0.1.0 Beta')

    def test_configured_release_info(self):
        # Item 30: checks on, the website's appcast feed and the public key from packaging/updates.json.
        # CHANGED (updates-1003, owner 10/03): updates download quietly and install at the quit or at Restart to
        # Update (SUAutomaticallyUpdate and SUAllowsAutomaticUpdates true); the app never pops a window for them.
        info = dr.release_info(self.template(), '20260924120000', '0.1.0', '15.0', writer=None,
                               updates='configured', update_data=FIXTURE_UPDATES)
        self.assertEqual(dr.info_problems(info, False, 'configured', data=FIXTURE_UPDATES), [])
        self.assertEqual(info['SUFeedURL'], 'https://getdaydream.app/appcast.xml')
        self.assertEqual(info['DaydreamUpdateSite'], 'getdaydream.app')
        self.assertEqual(info['SUPublicEDKey'], FIXTURE_KEY)
        self.assertIs(info['SUEnableAutomaticChecks'], True)
        self.assertIs(info['SUAutomaticallyUpdate'], True)
        self.assertIs(info['SUAllowsAutomaticUpdates'], True)
        self.assertEqual(info['SUScheduledCheckInterval'], 86400)
        self.assertIs(info['SUSendProfileInfo'], False)
        self.assertTrue(dr.info_problems(info, False, 'off'))

    def test_policy_failures(self):
        base = dr.release_info(self.template(), '20260924120000', '0.1.0', '15.0', writer=None)
        cases = [({'SUFeedURL': 'https://x.invalid/appcast.xml'}, False, 'off'),
                 ({'SUAutomaticallyUpdate': True}, False, 'off'),
                 ({'SUAllowsAutomaticUpdates': True}, False, 'off'),
                 ({'DaydreamUpdateSite': 'getdaydream.app'}, False, 'off'),
                 ({'SUEnableAutomaticChecks': True}, False, 'off'),
                 ({'CFBundleVersion': '1.2'}, False, 'off'),
                 ({'CFBundleVersion': str(2 ** 64)}, False, 'off'),
                 ({'DaydreamWriterRuntimeDistribution': writer_payload.ID}, None, 'off'),
                 ({'LSMinimumSystemVersion': '13.0', 'DaydreamWriterRuntimeDistribution': writer_payload.ID}, writer_payload.ID, 'off'),
                 ({'DaydreamWriterRuntimeDistribution': functional_payload.ID}, writer_payload.ID, 'off'),
                 ({}, None, 'configured')]
        for change, writer, updates in cases:
            info = {**base, **change}
            self.assertTrue(dr.info_problems(info, writer, updates, data=FIXTURE_UPDATES), change)
        # CHANGED (updates-1003): configured mode requires the exact values of packaging/updates.json,
        # including the website's feed (no longer the GitHub latest-release asset) and the owner's public key.
        configured = dr.release_info(self.template(), '20260924120000', '0.1.0', '15.0', None, 'configured', FIXTURE_UPDATES)
        self.assertEqual(dr.info_problems(configured, False, 'configured', data=FIXTURE_UPDATES), [])
        for key in ('MacMemGitHubOwner', 'MacMemGitHubRepository', 'DaydreamUpdateSite', 'SUFeedURL', 'SUPublicEDKey'):
            missing = {k: v for k, v in configured.items() if k != key}
            self.assertTrue(any(key in p for p in dr.info_problems(missing, False, 'configured', data=FIXTURE_UPDATES)), key)
        for key, value in (('SUFeedURL', 'https://getnorthlight.github.io/daydream/appcast.xml'),
                           ('SUFeedURL', 'https://github.com/getnorthlight/daydream/releases/latest/download/appcast.xml'),
                           ('SUAutomaticallyUpdate', False), ('SUEnableAutomaticChecks', False),
                           ('SURequireSignedFeed', False), ('SUVerifyUpdateBeforeExtraction', False),
                           ('SUAllowsAutomaticUpdates', False), ('DaydreamUpdateSite', 'example.com')):
            self.assertTrue(any(key in p for p in dr.info_problems({**configured, key: value}, False, 'configured', data=FIXTURE_UPDATES)), key)
        with patch.object(release, 'config', side_effect=ValueError('No valid update public key')):
            self.assertTrue(any('public key' in p for p in dr.info_problems(configured, False, 'configured')))
        # updates-1003: a release updates quietly (both keys true, a missing one refused); an updates-off build has both
        # false (a missing one refused too), so nothing automatic can happen in the owner, QA or test copies.
        for mode, info, wrong in (('configured', configured, False), ('off', base, True)):
            for key in ('SUAllowsAutomaticUpdates', 'SUAutomaticallyUpdate'):
                for value in (wrong, None):
                    changed = {**info, key: value} if value is not None else {k: v for k, v in info.items() if k != key}
                    self.assertTrue(any(key in p for p in dr.info_problems(changed, False, mode, data=FIXTURE_UPDATES)), (mode, key, value))
        no_usage = {k: v for k, v in base.items() if k != 'NSAppleEventsUsageDescription'}
        self.assertTrue(dr.info_problems(no_usage, False, 'off', apple_events=True))

    def test_chrome_switch_off_drops_the_chrome_prompt_text(self):
        on = dr.release_info(self.template(), '2', '0.1.0', '15.0', None)
        off = dr.release_info(self.template(), '2', '0.1.0', '15.0', None, chrome_pages=False)
        self.assertIn('NSAppleEventsUsageDescription', on)
        self.assertNotIn('NSAppleEventsUsageDescription', off)


class ChromeReleaseSwitch(unittest.TestCase):
    """--apple-events follows ReleaseFeatures.chromePageHistory (honesty track H7)."""

    def root_with(self, folder, text):
        root = Path(folder)
        if text is not None:
            path = root / dr.RELEASE_FEATURES
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        return root

    def test_switch_is_read_from_the_swift_constant(self):
        with tempfile.TemporaryDirectory(prefix='daydream-switch-') as folder:
            self.assertTrue(dr.chrome_page_history_switch(self.root_with(folder, None)))
        cases = [('public enum ReleaseFeatures { public static let chromePageHistory = true }', True),
                 ('public enum ReleaseFeatures {\n  /// Set `static let chromePageHistory = true` to ship it.\n'
                  '  public static let chromePageHistory: Bool = false\n}', False),
                 ('/* static let chromePageHistory = true */ enum R { static let chromePageHistory = false }', False)]
        for text, expected in cases:
            with tempfile.TemporaryDirectory(prefix='daydream-switch-') as folder:
                self.assertEqual(dr.chrome_page_history_switch(self.root_with(folder, text)), expected, text)
        for text in ('enum R { static let chromePageHistory = flag }',
                     'enum R { static let chromePageHistory = true; static var chromePageHistory = false }', ''):
            with tempfile.TemporaryDirectory(prefix='daydream-switch-') as folder:
                with self.assertRaises(dr.ReleaseError):
                    dr.chrome_page_history_switch(self.root_with(folder, text))

    def test_disagreeing_flag_is_refused(self):
        for switch in (True, False):
            with patch.object(dr, 'chrome_page_history_switch', return_value=switch):
                self.assertEqual(dr.resolve_apple_events(None), switch)
                self.assertEqual(dr.resolve_apple_events(switch), switch)
                with self.assertRaisesRegex(dr.ReleaseError, 'disagrees'):
                    dr.resolve_apple_events(not switch)
        with patch.object(dr, 'chrome_page_history_switch', return_value=False), \
                patch('subprocess.run', side_effect=AssertionError('must not execute')), \
                contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertEqual(dr.main(['verify', '--app', '/nonexistent/DayDream.app', '--expect', 'adhoc', '--apple-events']), 2)
        self.assertIn('disagrees', err.getvalue())


class SignatureChecks(unittest.TestCase):
    def test_adhoc_helper_passes(self):
        info = dr.parse_display(ADHOC_HELPER)
        info['entitlements'] = dr.parse_entitlements('<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
                                                     '</dict></plist>')
        self.assertEqual(dr.signature_problems(info, 'adhoc', identifier='com.getnorthlight.daydream.mac-mem',
                                               entitlements={}), [])
        self.assertTrue(dr.signature_problems(info, 'developer-id', identifier='com.getnorthlight.daydream.mac-mem',
                                              entitlements={}))

    def test_developer_id_requirements(self):
        info = dr.parse_display(DEVID_APP)
        info['entitlements'] = {}
        self.assertEqual(dr.signature_problems(info, 'developer-id', identifier='com.getnorthlight.daydream', entitlements={}), [])
        for mutate, needle in ((lambda i: i.pop('Timestamp'), 'timestamp'),
                               (lambda i: i['flags'].discard('runtime'), 'runtime'),
                               (lambda i: i.update(TeamIdentifier='HX7739G8FX'), 'TeamIdentifier'),
                               (lambda i: i['entitlements'].update({dr.GET_TASK_ALLOW: True}), 'get-task-allow'),
                               (lambda i: i['entitlements'].update({'com.apple.security.cs.disable-library-validation': True}), 'entitlements')):
            copy = dr.parse_display(DEVID_APP)
            copy['entitlements'] = {}
            mutate(copy)
            problems = dr.signature_problems(copy, 'developer-id', identifier='com.getnorthlight.daydream', entitlements={})
            self.assertTrue(any(needle in p for p in problems), (needle, problems))

    def test_empty_entitlements_output(self):
        self.assertEqual(dr.parse_entitlements(''), {})
        self.assertEqual(dr.parse_entitlements('<?xml version="1.0"?><plist version="1.0"><dict></dict></plist>'), {})


class PrintOnlyAndGuards(unittest.TestCase):
    def call(self, argv):
        out, err = io.StringIO(), io.StringIO()
        with patch('subprocess.run', side_effect=AssertionError('must not execute')) as run, \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = dr.main(argv)
            run.assert_not_called()
        return code, out.getvalue(), err.getvalue()

    def test_notarize_and_staple_print_only(self):
        # FIXED (review): the expected command is built with shlex.join, as the code prints it,
        # so the test also passes when TMPDIR contains a space; one case forces a space.
        with tempfile.TemporaryDirectory(prefix='daydream-notary-') as folder:
            for parent in (Path(folder), Path(folder) / 'with space'):
                parent.mkdir(exist_ok=True)
                app, dmg, out = parent / 'DayDream.app', parent / 'DayDream-0.1.0.dmg', parent / 'n'
                code, text, _ = self.call(['notarize', '--artifact', str(app), '--out', str(out)])
                self.assertEqual(code, 0)
                self.assertIn('PRINT-ONLY', text)
                self.assertIn(shlex.join(['xcrun', 'notarytool', 'submit', str(out / 'notary-app.zip'), '--keychain-profile',
                                          'daydream-notary', '--wait', '--timeout', dr.NOTARY_WAIT, '--output-format', 'json']), text)
                self.assertIn(shlex.join(['ditto', '-c', '-k', '--keepParent', str(app), str(out / 'notary-app.zip')]), text)
                self.assertIn('--resume --execute', text)
                self.assertFalse(out.exists())
                code, text, _ = self.call(['notarize', '--artifact', str(dmg), '--out', str(out), '--keychain-profile', 'daydream-notary'])
                self.assertEqual(code, 0)
                self.assertNotIn('ditto', text)
                code, text, _ = self.call(['staple', '--artifact', str(app), '--notary-dir', str(out)])
                self.assertEqual(code, 0)
                self.assertIn(shlex.join(['xcrun', 'stapler', 'staple', str(app)]), text)
                self.assertIn('--notary-dir ' + shlex.quote(str(out)), text)
                self.assertIn('--type execute', text)
                code, text, _ = self.call(['staple', '--artifact', str(dmg)])
                self.assertIn('context:primary-signature', text)

    def test_execute_requires_keychain_profile(self):
        code, _, err = self.call(['notarize', '--artifact', '/nonexistent/DayDream.app', '--out', '/nonexistent/n', '--execute'])
        self.assertEqual(code, 2)
        self.assertIn('--keychain-profile', err)

    def test_staple_execute_requires_notary_dir(self):
        code, _, err = self.call(['staple', '--artifact', '/nonexistent/DayDream.app', '--execute'])
        self.assertEqual(code, 2)
        self.assertIn('--notary-dir', err)

    def test_installed_copies_are_never_stapled(self):
        self.assertTrue(dr.installed_location('/Applications/DayDream.app'))
        self.assertTrue(dr.installed_location(Path.home() / 'Applications/DayDream.app'))
        self.assertFalse(dr.installed_location(Path.home() / 'DaydreamReleases/1/signed/DayDream.app'))

    def test_notarize_resume_and_rerun_refused_before_any_command(self):
        with tempfile.TemporaryDirectory(prefix='daydream-resume-') as folder:
            app, out = Path(folder) / 'DayDream.app', Path(folder) / 'notary'
            (app / 'Contents/MacOS').mkdir(parents=True)
            (app / 'Contents/MacOS/MacMem').write_bytes(MACHO + b'WebTypingRoute')  # the full-typing build
            out.mkdir()
            common = ['notarize', '--artifact', str(app), '--out', str(out), '--keychain-profile', 'daydream-notary', '--execute']
            code, _, err = self.call(common + ['--resume'])
            self.assertEqual(code, 2)
            self.assertIn('Nothing to resume', err)
            (out / 'notary-app-receipt.json').write_text(json.dumps({'status': 'uploading'}))
            code, _, err = self.call(common)
            self.assertEqual(code, 2)
            self.assertIn('--resume', err)
            (out / 'notary-app.json').write_text('{}')
            code, _, err = self.call(common + ['--resume'])
            self.assertEqual(code, 2)
            self.assertIn('No submission id', err)

    def test_stage_has_no_base_app_path(self):
        # CHANGED (sat/updates, item 17): stage builds every binary from a git archive of the
        # commit. There is no --base (installed app copy) and no --inherit any more.
        for extra in (['--base', '/Applications/DayDream.app'], ['--inherit', 'MacMem'], ['--bin-dir', '/tmp']):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                dr.main(['stage', '--out', '/nonexistent/o', '--build', '2'] + extra)
        source = (SCRIPTS / 'developer-id-release.py').read_text()
        self.assertNotIn("'--base'", source)
        self.assertNotIn('inherited from the base', source)

    def test_bad_inputs_refused_before_any_command(self):
        code, _, err = self.call(['sign', '--app', '/nonexistent/DayDream.app', '--out', '/nonexistent/o', '--identity', 'Developer ID Application: X'])
        self.assertEqual(code, 2)
        self.assertIn('SHA-1', err)
        code, _, err = self.call(['dmg', '--app', '/nonexistent/DayDream.app', '--out', '/nonexistent/bad.dmg', '--unsigned'])
        self.assertEqual(code, 2)
        code, _, err = self.call(['stage', '--out', '/nonexistent/o', '--build', '0'])
        self.assertEqual(code, 2)
        code, _, err = self.call(['dmg', '--app', '/nonexistent/DayDream.app', '--out', '/nonexistent/DayDream-0.1.0.dmg', '--unsigned'])
        self.assertEqual(code, 2)


class FakeRunner:
    """Records argv; returns rc 0 and empty output unless a prefix is scripted."""

    def __init__(self, returncodes=None):
        self.calls, self.notes, self.returncodes = [], [], returncodes or {}

    def run(self, argv, check=True, env=None, timeout=None, quiet=False):
        argv = [str(a) for a in argv]
        self.calls.append(argv)
        code = next((rc for prefix, rc in self.returncodes.items() if argv[:len(prefix)] == list(prefix)), 0)
        return subprocess.CompletedProcess(argv, code, '', '')

    def note(self, text):
        self.notes.append(text)


def devid_info(identifier):
    info = dr.parse_display(DEVID_APP.replace('Identifier=com.getnorthlight.daydream', 'Identifier=' + identifier))
    info['entitlements'] = {}
    return info


class WriterAndLeafPolicy(unittest.TestCase):
    NAMES = ('libllama.0.dylib', 'libggml.0.dylib')

    def writer_app(self, folder, rows):
        app = Path(folder) / 'DayDream.app'
        manifest = app / 'Contents' / writer_payload.MANIFEST
        manifest.parent.mkdir(parents=True)
        manifest.write_text(json.dumps({'files': rows}))
        return app

    def verify(self, app, leaf=dr.LEAF_SHA256):
        libs = ['Contents/' + writer_payload.LIBROOT + n for n in self.NAMES]
        ids = {n: writer_payload.signing_identifier(n) for n in self.NAMES}
        with patch.object(dr, 'writer_libraries', return_value=libs), \
                patch.object(dr, 'inspect_signature', side_effect=lambda runner, path: devid_info(ids[Path(path).name])), \
                patch.object(dr, 'leaf_sha256', return_value=leaf):
            return dr.writer_verification(app, FakeRunner(), writer=writer_payload.ID)

    def rows(self):
        return [{'name': n, 'signingIdentifier': writer_payload.signing_identifier(n)} for n in self.NAMES]

    def test_writer_dylibs_pass_with_enrolled_leaf(self):
        with tempfile.TemporaryDirectory(prefix='daydream-writer-') as folder:
            report, problems = self.verify(self.writer_app(folder, self.rows()))
            self.assertEqual(problems, [])
            self.assertEqual([r['row'] for r in report], ['writer-runtime'] * 2)

    def test_writer_dylib_wrong_leaf(self):
        with tempfile.TemporaryDirectory(prefix='daydream-writer-') as folder:
            _, problems = self.verify(self.writer_app(folder, self.rows()), leaf='0' * 64)
            self.assertEqual(len(problems), 2)
            self.assertTrue(all('enrolled' in p for p in problems))

    def test_writer_dylib_missing_from_manifest_is_a_problem_not_a_crash(self):
        with tempfile.TemporaryDirectory(prefix='daydream-writer-') as folder:
            _, problems = self.verify(self.writer_app(folder, self.rows()[:1]))
            self.assertTrue(any('not in the enrolled manifest' in p for p in problems), problems)
            (Path(folder) / 'DayDream.app/Contents' / writer_payload.MANIFEST).write_text('{"no": "files"}')
            _, problems = self.verify(Path(folder) / 'DayDream.app')
            self.assertTrue(problems and 'manifest unreadable' in problems[0], problems)

    def test_no_writer_means_no_writer_checks(self):
        self.assertEqual(dr.writer_verification(Path('/nonexistent/DayDream.app'), FakeRunner(), writer=None), ([], []))

    def test_leaf_pin_applies_to_writer_builds_only(self):
        other = '1' * 64
        self.assertEqual(dr.leaf_problems(dr.LEAF_SHA256, writer=writer_payload.ID), [])
        self.assertTrue(dr.leaf_problems(other, writer=writer_payload.ID))
        self.assertEqual(dr.leaf_problems(other, writer=None), [])
        self.assertTrue(dr.leaf_problems(None, writer=None))
        # One leaf pin: the one the signed runtime's manifest records and the pipeline enforces.
        self.assertEqual(dr.LEAF_SHA256, writer_payload.LEAF_SHA256)


class DmgGate(unittest.TestCase):
    """notarize/staple of a DMG: receipt, image signature and the stapled app inside."""

    def image(self, folder, receipt):
        dmg = Path(folder) / 'DayDream-0.1.0-1.dmg'
        dmg.write_bytes(b'image')
        if receipt is not None:
            receipt.setdefault('sha256', hashlib.sha256(b'image').hexdigest())
            Path(str(dmg) + '.receipt.json').write_text(json.dumps(receipt))
        return dmg

    def problems(self, dmg, runner=None, typing=True, owner=False, writer=True, **kw):
        runner = runner or FakeRunner()
        good_image = dr.parse_display(DEVID_APP)
        with patch.object(dr, 'parse_display', return_value=good_image), \
                patch.object(writer_payload, 'paths', return_value={writer_payload.MANIFEST} if writer else set()), \
                patch.object(dr, 'leaf_sha256', return_value='f' * 64), \
                patch.object(dr, 'typing_app', return_value=typing), patch.object(dr, 'owner_app', return_value=owner), \
                patch.object(dr, 'verify_app', return_value=([], [{'row': 'app', 'leaf_sha256': 'f' * 64}])):
            return dr.dmg_problems(dmg, runner, **kw), runner

    def test_inner_app_must_be_the_full_typing_public_build(self):
        # public-typing review: the image's app carries website typing, and only an -owner.dmg holds the owner's copy.
        receipt = {'signature': 'developer-id', 'app_stapled': True, 'allow_unstapled_app': False}
        with tempfile.TemporaryDirectory(prefix='daydream-dmg-gate-') as folder:
            dmg = self.image(folder, receipt)
            problems, _ = self.problems(dmg, typing=False)
            self.assertIn('image app: not the full-typing build (MacOS/MacMem lacks WebTypingRoute)', problems)
            problems, _ = self.problems(dmg, owner=True)
            self.assertTrue(any('owner\'s private copy' in p for p in problems), problems)
            owner_dmg = dmg.with_name('DayDream-0.1.0-owner.dmg')
            dmg.rename(owner_dmg)
            Path(str(dmg) + '.receipt.json').rename(str(owner_dmg) + '.receipt.json')
            problems, _ = self.problems(owner_dmg, owner=True)
            self.assertEqual(problems, ['the app inside the image is not stapled'])

    def test_good_receipt_passes_except_unstapled_inner_app(self):
        with tempfile.TemporaryDirectory(prefix='daydream-dmg-gate-') as folder:
            dmg = self.image(folder, {'signature': 'developer-id', 'app_stapled': True, 'allow_unstapled_app': False})
            problems, runner = self.problems(dmg)
            # The fake mount is empty, so the inner app has no ticket: exactly that is reported.
            self.assertEqual(problems, ['the app inside the image is not stapled'])
            self.assertTrue(any(c[:3] == ['hdiutil', 'attach', '-readonly'] for c in runner.calls))
            self.assertTrue(any(c[:2] == ['hdiutil', 'detach'] for c in runner.calls))

    def test_missing_or_bad_receipt_refused(self):
        with tempfile.TemporaryDirectory(prefix='daydream-dmg-gate-') as folder:
            problems, _ = self.problems(self.image(folder, None))
            self.assertTrue(any('receipt' in p for p in problems))
        for receipt, needle in (({'signature': 'adhoc', 'app_stapled': True}, 'Developer ID'),
                                ({'signature': 'developer-id', 'app_stapled': True, 'allow_unstapled_app': True}, 'not stapled'),
                                ({'signature': 'developer-id', 'app_stapled': True, 'sha256': '0' * 64}, 'changed')):
            with tempfile.TemporaryDirectory(prefix='daydream-dmg-gate-') as folder:
                problems, _ = self.problems(self.image(folder, receipt))
                self.assertTrue(any(needle in p for p in problems), (needle, problems))

    def test_inner_app_must_carry_on_this_mac(self):
        # Owner decision 2026-09-26: every release carries the runtime; a test stage without it never ships.
        with tempfile.TemporaryDirectory(prefix='daydream-dmg-gate-') as folder:
            dmg = self.image(folder, {'signature': 'developer-id', 'app_stapled': True, 'allow_unstapled_app': False})
            problems, _ = self.problems(dmg, writer=False)
            self.assertIn('image app: ' + dr.NO_WRITER_RUNTIME, problems)

    def test_image_requirement_failure_refused(self):
        with tempfile.TemporaryDirectory(prefix='daydream-dmg-gate-') as folder:
            dmg = self.image(folder, {'signature': 'developer-id', 'app_stapled': True})
            problems, _ = self.problems(dmg, FakeRunner({('codesign', '--verify', '--strict'): 3}))
            self.assertTrue(any('team requirement' in p for p in problems))


class PrivatePayload(unittest.TestCase):
    """The remote bridge, its Node runtime and Horizon files never reach a public build."""
    def test_pipeline_has_no_node_or_bridge(self):
        source = (SCRIPTS / 'developer-id-release.py').read_text()
        for gone in ('NODE_SMOKE', 'node_pin', 'node-runtime.json', 'connection_payload', "ROOT / 'RemoteBridge'",
                     'horizon-host.example.json\')', '--node-'):
            self.assertNotIn(gone, source)
        self.assertFalse(any('node' in row['key'] for row in dr.SIGNING_TABLE))
        self.assertNotIn('MacOS/daydream-node', dr.KNOWN_MACHO)
        for private in ('MacOS/daydream-node', 'Resources/RemoteBridge', 'Resources/ConnectionAvailability.json',
                        'Resources/horizon-host.example.json', 'Resources/horizon-reader.example.json', 'Resources/PROVENANCE.md'):
            self.assertIn(private, dr.PRIVATE_PAYLOAD)

    def test_audit_rejects_each_private_piece(self):
        for private in dr.PRIVATE_PAYLOAD:
            with tempfile.TemporaryDirectory(prefix='daydream-private-') as folder:
                app = Path(folder) / 'DayDream.app'
                path = app / 'Contents' / private
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'x')
                with self.assertRaisesRegex(ValueError, 'Unexpected release payload'):
                    release.audit(app)

    def test_stage_ships_licences(self):
        source = (SCRIPTS / 'developer-id-release.py').read_text()
        for name in ("'LICENSE.txt'", "'NOTICE.txt'", "'THIRD-PARTY-NOTICES.md'", "'Sparkle-LICENSE.txt'",
                     "'llama-MIT.txt'", "'Qwen-APACHE-2.0.txt'"):
            self.assertIn(name, source)


class ReleaseAuditAndDmgTools(unittest.TestCase):
    def test_audit_accepts_stapled_ticket_only(self):
        with tempfile.TemporaryDirectory(prefix='daydream-audit-') as folder:
            app = Path(folder) / 'DayDream.app'
            (app / 'Contents/Resources').mkdir(parents=True)
            (app / 'Contents/CodeResources').write_bytes(b'ticket')
            release.audit(app)
            (app / 'Contents/Unexpected').write_bytes(b'x')
            with self.assertRaisesRegex(ValueError, 'Unexpected release payload'):
                release.audit(app)

    def test_layout_checker_is_importable(self):
        import check_dmg_layout
        for name in ('inventory', 'entries', 'check_volume', 'single_image', 'two_image'):
            self.assertTrue(callable(getattr(check_dmg_layout, name)))

    def test_polish_refuses_signed_images(self):
        source = (SCRIPTS / 'polish-dmg.sh').read_text()
        self.assertIn('codesign -dv "$source_image"', source)

    def test_check_dmg_never_launches_by_default(self):
        source = (SCRIPTS / 'check_dmg.py').read_text()
        self.assertIn("'--launch-isolated'", source)
        self.assertLess(source.index('if not launch'), source.index('subprocess.Popen'))


class HybridRunner(FakeRunner):
    """Runs git, tar and ditto for real (the archive and copies are what is under test) and
    records everything else (otool, xattr, install_name_tool, swift) without running it."""
    REAL = ('git', 'tar', 'ditto')

    def __init__(self):
        super().__init__()
        self.records = []

    def run(self, argv, check=True, env=None, timeout=None, quiet=False):
        argv = [str(a) for a in argv]
        if argv[0] in self.REAL:
            self.calls.append(argv)
            proc = subprocess.run(argv, capture_output=True, text=True)
            if check and proc.returncode:
                raise dr.ReleaseError('fixture command failed: %s: %s' % (argv, proc.stderr))
            return proc
        return super().run(argv, check, env, timeout, quiet)


def git(root, *argv):
    env = {**os.environ, 'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_SYSTEM': '/dev/null'}
    return subprocess.run(['git', '-C', str(root), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@invalid',
                           '-c', 'commit.gpgsign=false'] + list(argv), check=True, capture_output=True, text=True, env=env).stdout.strip()


# ---------------------------------------------------------------- a synthetic signed "On this Mac" runtime
RUNTIME_PINS = writer_payload.runtime_pins((dr.ROOT / writer_payload.RUNTIME).read_text())
WRITER_NAMES = sorted(RUNTIME_PINS['files'])


def dylib_command(command, path):
    raw = path.encode() + b'\0'
    size = (24 + len(raw) + 7) // 8 * 8
    return struct.pack('<6I', command, size, 24, 2, 0x10000, 0x10000) + raw + bytes(size - 24 - len(raw))


def synthetic_dylib(name, dependencies=('/usr/lib/libSystem.B.dylib',)):
    """A minimal thin arm64 MH_DYLIB that the loader's Mach-O rule accepts: id @loader_path/<name>."""
    commands = dylib_command(0xd, '@loader_path/' + name) + b''.join(dylib_command(0xc, d) for d in dependencies)
    return (struct.pack('<8I', 0xfeedfacf, 0x0100000C, 0, 6, 1 + len(dependencies), len(commands), 0, 0)
            + commands + b'synthetic signature ' + name.encode())


def synthetic_manifest(libraries):
    rows = [{'name': n, 'upstreamSHA256': RUNTIME_PINS['files'][n][1], 'signedSHA256': hashlib.sha256(d).hexdigest(),
             'signedBytes': len(d), 'signingIdentifier': writer_payload.signing_identifier(n)} for n, d in sorted(libraries.items())]
    return (json.dumps({'schema': RUNTIME_PINS['schema'], 'distributionID': writer_payload.ID,
                        'upstreamArchiveSHA256': RUNTIME_PINS['archive'], 'teamID': writer_payload.TEAM_ID,
                        'certificateSHA256': writer_payload.LEAF_SHA256, 'files': rows}, indent=2, sort_keys=True) + '\n').encode()


def policy_with(pins):
    """The real SignedRuntimePolicy.swift with approvedManifestSHA256 set to `pins`."""
    text = (dr.ROOT / writer_payload.POLICY).read_text()
    body = ',\n'.join('        "%s": "%s"' % item for item in pins.items())
    changed, count = re.subn(r'(static let approvedManifestSHA256: \[String: String\] = \[)(.*?)(\n    \])',
                             lambda m: m.group(1) + '\n' + body + m.group(3), text, count=1, flags=re.S)
    assert count == 1 and writer_payload.policy_pins(changed) == pins
    return changed


def writer_files(libraries=None, pin='match', signed=True):
    """The commit's runtime files: packaging/WriterRuntime/<ID>/ (when `signed`) and the two Swift pin files.
    pin: 'match' (the manifest's SHA-256), None (no entry for the ID) or any other value."""
    libraries = libraries or {n: synthetic_dylib(n) for n in WRITER_NAMES}
    manifest = synthetic_manifest(libraries)
    pins = {} if pin is None else {writer_payload.ID: hashlib.sha256(manifest).hexdigest() if pin == 'match' else pin}
    files = {writer_payload.POLICY: policy_with(pins).encode(), writer_payload.RUNTIME: (dr.ROOT / writer_payload.RUNTIME).read_bytes()}
    if signed:
        files[writer_payload.SOURCE_DIR + '/' + writer_payload.MANIFEST_NAME] = manifest
        files.update({writer_payload.SOURCE_DIR + '/' + n: d for n, d in libraries.items()})
    return files


def fixture_repo(folder, public_key=FIXTURE_KEY, writer=None):
    """A tiny committed repository with every file stage copies into the app, the signed runtime included
    (`writer`: writer_files(...), default a good signed set)."""
    root = Path(folder) / 'repo'
    files = {'packaging/Info.plist': (dr.ROOT / 'packaging/Info.plist').read_bytes(),
             'Package.swift': (dr.ROOT / 'Package.swift').read_bytes(),  # its macOS 15 floor (release.package_platform_problems)
             'packaging/updates.json': json.dumps({**FIXTURE_UPDATES, 'public_key': public_key}).encode(),
             'packaging/Daydream.icns': b'icns-fixture', 'LICENSE': b'MIT fixture\n', 'NOTICE': b'notice fixture\n',
             'THIRD-PARTY-NOTICES.md': b'third-party fixture\n', 'WriterBackend/Notices/llama-MIT.txt': b'mit fixture\n',
             'WriterBackend/Notices/Qwen-APACHE-2.0.txt': b'qwen fixture\n', 'adapters/before_turn.py': b'# committed\n',
             'adapters/launcher.example.json': b'{}\n', '.gitignore': b'*.key\n/Vendor/\n'}
    files.update(writer_files() if writer is None else writer)
    for rel, data in files.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    git(root.parent, 'init', '-q', str(root))
    git(root, 'add', '-A')
    git(root, 'commit', '-q', '-m', 'fixture')
    return root


# What the full-typing flags compile into the fake binaries (a real build's symbols).
TYPING_BYTES = {'MacMem': b'$s6MacMem14WebTypingRouteO', 'mac-mem': b'BrowserTypingJoin'}


class SignedRuntimeFixture:
    """codesign answers for the synthetic runtime (Developer ID, team, enrolled leaf; nothing is signed or
    run) and writer_payload's pins read from the fixture repository, as a real stage reads its own checkout."""

    def fake_signatures(self, identifier=None, leaf=None, team=None):
        def inspect(runner, path):
            info = devid_info(identifier or writer_payload.signing_identifier(Path(path).name))
            if team:
                info['TeamIdentifier'] = team
            return info
        for patcher in (patch.object(dr, 'inspect_signature', side_effect=inspect),
                        patch.object(dr, 'leaf_sha256', return_value=leaf or dr.LEAF_SHA256),
                        patch.object(writer_payload, 'ROOT', self.repo)):
            patcher.start()
            self.addCleanup(patcher.stop)


class StageFromCommit(SignedRuntimeFixture, unittest.TestCase):
    """Item 17: a release is built only from a clean git archive of a commit."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='daydream-stage-')
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.repo = fixture_repo(self.folder)
        self.fake_signatures()
        self.built = []
        self.flags = []

    def builder(self, source, scratch, runner, swift_flags=()):
        self.built.append((Path(source), Path(scratch)))
        self.flags.append(tuple(swift_flags))
        self.assertTrue((Path(source) / 'packaging/Info.plist').is_file())
        self.assertFalse((Path(source) / '.git').exists())
        self.assertTrue((Path(source) / 'Vendor/Sparkle-2.9.6/Sparkle.xcframework').is_dir())
        bins = Path(scratch) / 'release'
        bins.mkdir(parents=True)
        for name in dr.SWIFT_BINARIES:
            (bins / name).write_bytes(MACHO + name.encode() + (TYPING_BYTES.get(name, b'') if swift_flags else b''))
        icons = bins / 'MacMem_MemoryUI.bundle/SiteIcons'
        icons.mkdir(parents=True)
        (icons / 'x.png').write_bytes(b'x-favicon-fixture')
        (icons / 'instagram.png').write_bytes(b'instagram-favicon-fixture')
        for name in ['google', 'claude-code', 'cursor']:
            (icons / (name + '.png')).write_bytes((name + '-icon-fixture').encode())
        return bins

    def stage(self, *extra, out='out', first=True):
        # 263cdae: release default is 0.1.4; this fixture deliberately exercises 0.1.0.
        argv = ['stage', '--without-search-runtime-for-tests', '--out', str(self.folder / out), '--build', '20260926120000', '--version', '0.1.0']
        # G78: every stage names the build it follows (--previous-build) or says it is the first (--first-build).
        if first and '--previous-build' not in extra and '--first-build' not in extra:
            argv.append('--first-build')
        args = dr.build_parser().parse_args(argv + list(extra))
        runner = HybridRunner()
        with contextlib.redirect_stdout(io.StringIO()):
            dr.cmd_stage(args, runner=runner, root=self.repo, builder=self.builder)
        return runner

    def test_stage_refuses_anything_but_macos_15_on_apple_silicon(self):
        """claude/crashguard-015: 0.1.5 is macOS 15.0+ on Apple silicon only (0.1.4 crashed on macOS 15)."""
        with self.assertRaisesRegex(dr.ReleaseError, 'LSMinimumSystemVersion must be 15.0'):
            self.stage('--min-macos', '14.0', out='out-14')
        x86 = struct.pack('<8I', 0xfeedfacf, 0x01000007, 3, 2, 1, 24, 0, 0) + MACHO[32:]
        # A universal (arm64 + x86_64) binary passes the build's "has arm64" check; release refuses it.
        fat = struct.pack('>2I', 0xcafebabe, 2) + struct.pack('>5I', 0x0100000C, 0, 4096, len(MACHO), 12) + struct.pack('>5I', 0x01000007, 3, 8192, len(x86), 12)
        fat = fat + bytes(4096 - len(fat)) + MACHO + bytes(4096 - len(MACHO)) + x86
        old = struct.pack('<8I', 0xfeedfacf, 0x0100000C, 0, 2, 1, 24, 0, 0) + struct.pack('<6I', 0x32, 24, 1, 0x000E0000, 0x000F0000, 0)
        for header, message in ((fat, 'mac-mem must be arm64 only'), (old, 'mac-mem must be built for macOS 15.0')):
            original = MACHO
            try:
                globals()['MACHO'] = header
                with self.subTest(message=message), self.assertRaisesRegex(dr.ReleaseError, message):
                    self.stage(out='out-' + message.split()[-1])
            finally:
                globals()['MACHO'] = original
        # Package.swift's floor comes from the exported commit.
        (self.repo / 'Package.swift').write_text((self.repo / 'Package.swift').read_text().replace('.macOS("15.0")', '.macOS("14.0")').replace('.macOS(.v15)', '.macOS(.v14)'))
        git(self.repo, 'commit', '-q', '-am', 'macOS 14')
        with self.assertRaisesRegex(dr.ReleaseError, 'Package.swift must declare platforms'):
            self.stage(out='out-package')

    def test_stage_ships_memory_ui_resources(self):
        self.stage()
        icons = self.folder / 'out/DayDream.app/Contents/Resources/MacMem_MemoryUI.bundle/SiteIcons'
        self.assertEqual((icons / 'x.png').read_bytes(), b'x-favicon-fixture')
        self.assertEqual((icons / 'instagram.png').read_bytes(), b'instagram-favicon-fixture')
        for name in ['google', 'claude-code', 'cursor']:
            self.assertEqual((icons / (name + '.png')).read_bytes(), (name + '-icon-fixture').encode())

    def test_clean_commit_stages_with_commit_recorded(self):
        runner = self.stage()
        head = git(self.repo, 'rev-parse', 'HEAD')
        out = self.folder / 'out'
        app = out / 'DayDream.app'
        receipt = json.loads((out / 'stage-receipt.json').read_text())
        self.assertEqual(receipt['source_commit'], head)
        self.assertEqual(json.loads((app / 'Contents/Resources/Companions.json').read_text())['source_commit'], head)
        self.assertIn(['git', '-C', str(self.repo), 'archive', '--format=tar', '-o', str(out / 'source.tar'), head], runner.calls)
        self.assertEqual(self.built, [(out / 'source', out / 'build')])
        # A public stage compiles typing in (the owner's decision of 2026-09-25), records the flags,
        # and carries no owner key: it is not the owner's private copy.
        self.assertEqual(self.flags, [dr.OWNER_SWIFT_FLAGS])
        self.assertIs(receipt['owner_build'], False)
        self.assertEqual(receipt['swift_flags'], list(dr.OWNER_SWIFT_FLAGS))
        self.assertEqual(dr.owner_markers(app), ['MacOS/MacMem carries WebTypingRoute', 'MacOS/mac-mem carries BrowserTypingJoin'])
        self.assertFalse(dr.owner_app(app))
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        self.assertNotIn(dr.OWNER_PLIST_KEY, info)
        self.assertEqual(info['CFBundleShortVersionString'], '0.1.0 Beta')
        self.assertEqual(info['CFBundleVersion'], '20260926120000')
        self.assertEqual(dr.update_policy_problems(info, 'configured', FIXTURE_UPDATES), [])
        self.assertEqual((app / 'Contents/Resources/before_turn.py').read_bytes(), b'# committed\n')
        self.assertEqual((app / 'Contents/Resources/LICENSE.txt').read_bytes(), b'MIT fixture\n')
        for name in dr.SWIFT_BINARIES:
            self.assertEqual((app / 'Contents/MacOS' / name).read_bytes(), MACHO + name.encode() + TYPING_BYTES.get(name, b''))
        self.assertEqual(dr.sparkle_inventory_digest(app / 'Contents/Frameworks/Sparkle.framework'), dr.SPARKLE_INVENTORY_SHA256)
        for private in dr.PRIVATE_PAYLOAD:
            self.assertFalse((app / 'Contents' / private).exists())
        release.audit(app)

    def test_ignored_files_never_enter_the_build(self):
        (self.repo / 'adapters/local-secret.key').write_text('not for release')
        self.stage()
        self.assertFalse((self.folder / 'out/source/adapters/local-secret.key').exists())

    def refused(self, needle, *extra, out='out'):
        with self.assertRaises(dr.ReleaseError) as caught:
            self.stage(*extra, out=out)
        self.assertIn(needle, str(caught.exception))
        self.assertFalse((self.folder / out).exists())
        self.assertEqual(self.built, [])

    def test_uncommitted_change_refused(self):
        (self.repo / 'adapters/before_turn.py').write_text('# edited, not committed\n')
        self.refused('uncommitted')

    def test_staged_but_uncommitted_change_refused(self):
        (self.repo / 'NOTICE').write_text('changed\n')
        git(self.repo, 'add', 'NOTICE')
        self.refused('uncommitted')

    def test_untracked_file_refused(self):
        (self.repo / 'adapters/new.py').write_text('# untracked\n')
        self.refused('untracked')

    def test_commit_must_be_the_checkout(self):
        first = git(self.repo, 'rev-parse', 'HEAD')
        (self.repo / 'NOTICE').write_text('second\n')
        git(self.repo, 'commit', '-q', '-am', 'second')
        self.refused('but the checkout is at', '--commit', first)
        self.refused('is not a commit', '--commit', 'no-such-ref')

    def test_not_a_git_checkout_refused(self):
        shutil.rmtree(self.repo / '.git')
        self.refused('not a git checkout')

    def test_missing_update_key_refused(self):
        self.repo = fixture_repo(self.folder / 'nokey', public_key='')
        with self.assertRaisesRegex(ValueError, 'public key'):
            self.stage()
        self.assertFalse((self.folder / 'out').exists())

    def test_build_numbers_only_go_up(self):
        self.refused('must exceed', '--previous-build', '20260926120000')

    def test_every_stage_names_the_build_it_follows(self):
        # G78 (golden test 5): the monotonic check is on by default. A stage without --previous-build (or the
        # explicit --first-build) is refused before anything runs, so test 5 can't reuse or go below test 4's build.
        with self.assertRaises(dr.ReleaseError) as caught:
            self.stage(first=False)
        self.assertIn('Pass --previous-build', str(caught.exception))
        self.assertFalse((self.folder / 'out').exists())
        self.assertEqual(self.built, [])
        test4 = '20260926142910'
        for build in ('20260926120000', test4, '1'):
            self.refused('must exceed', '--build', build, '--previous-build', test4)
        self.refused('positive', '--previous-build', '0')
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            dr.build_parser().parse_args(['stage', '--without-search-runtime-for-tests', '--out', 'x', '--build', '2', '--previous-build', '1', '--first-build'])
        self.stage('--build', '20261003120000', '--previous-build', test4)
        receipt = json.loads((self.folder / 'out/stage-receipt.json').read_text())
        self.assertEqual((receipt['build'], receipt['previous_build'], receipt['first_build']), ('20261003120000', int(test4), False))
        self.stage('--first-build', out='first')
        receipt = json.loads((self.folder / 'first/stage-receipt.json').read_text())
        self.assertEqual((receipt['previous_build'], receipt['first_build']), (None, True))
        self.assertIn('--first-build', (dr.ROOT / 'RELEASE.md').read_text())

    def test_output_inside_the_repository_refused(self):
        with self.assertRaisesRegex(dr.ReleaseError, 'outside the repository'):
            self.stage(out='repo/out')


class OwnerBuild(SignedRuntimeFixture, unittest.TestCase):
    """Every stage is the full-typing build (typing-all SPEC-LATER section 3; public since the owner's
    decision of 2026-09-25): both flags on every swift build, and MacMem must carry the website typing
    route. `stage --owner-build` is the owner's private copy of it: owner_build=true in
    stage-receipt.json, the Info.plist mark, updates off and the owner DMG name. A public stage refuses
    the owner key and the packager's owner banner."""

    OWNER_FLAGS = ('-Xswiftc', '-DDAYDREAM_OWNER_TYPING', '-Xswiftc', '-DDAYDREAM_CHROME_TYPING')

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='daydream-owner-')
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.repo = fixture_repo(self.folder)
        self.fake_signatures()
        self.calls = []
        self.marks = None  # None: marks follow the flags, as a real build does

    def builder(self, source, scratch, runner, swift_flags=()):
        self.calls.append((Path(scratch), tuple(swift_flags)))
        typing = tuple(swift_flags) == self.OWNER_FLAGS
        marks = self.marks if self.marks is not None else (TYPING_BYTES if typing else {})
        bins = Path(scratch) / 'release'
        bins.mkdir(parents=True)
        for name in dr.SWIFT_BINARIES:
            (bins / name).write_bytes(MACHO + name.encode() + marks.get(name, b''))
        icons = bins / 'MacMem_MemoryUI.bundle/SiteIcons'
        icons.mkdir(parents=True)
        (icons / 'x.png').write_bytes(b'x-favicon-fixture')
        (icons / 'instagram.png').write_bytes(b'instagram-favicon-fixture')
        return bins

    def stage(self, *extra, out='out', env=None):
        # 263cdae: release default is 0.1.4; this fixture deliberately exercises 0.1.0.
        argv = ['stage', '--without-search-runtime-for-tests', '--out', str(self.folder / out), '--build', '20260926120000', '--version', '0.1.0']
        if '--previous-build' not in extra and '--first-build' not in extra:
            argv.append('--first-build')  # G78
        args = dr.build_parser().parse_args(argv + list(extra))
        with contextlib.redirect_stdout(io.StringIO()) as printed, patch.dict(os.environ, env or {}, clear=False):
            if env is None:
                os.environ.pop('DAYDREAM_OWNER_TYPING', None)
            dr.cmd_stage(args, runner=HybridRunner(), root=self.repo, builder=self.builder)
        return printed.getvalue()

    def test_flags_are_the_packagers(self):
        self.assertEqual(dr.OWNER_SWIFT_FLAGS, self.OWNER_FLAGS)
        package = (dr.ROOT / 'scripts/package.sh').read_text()
        self.assertIn('swift_flags=(%s)' % ' '.join(self.OWNER_FLAGS), package)

    def test_build_products_passes_the_flags_to_every_swift_build(self):
        class BinRunner(FakeRunner):
            def run(self, argv, check=True, env=None, timeout=None, quiet=False):
                done = super().run(argv, check, env, timeout, quiet)
                return subprocess.CompletedProcess(done.args, 0, '/scratch/release\n' if '--show-bin-path' in done.args else '', '')
        for flags in (self.OWNER_FLAGS, ()):
            runner = BinRunner()
            self.assertEqual(dr.build_products(Path('/src'), Path('/scratch'), runner, swift_flags=flags), Path('/scratch/release'))
            builds = [c for c in runner.calls if c[:2] == ['swift', 'build']]
            self.assertEqual(len(builds), len(dr.SWIFT_BINARIES) + 1)  # the three products and --show-bin-path
            for argv in builds:
                self.assertEqual(argv.count('-Xswiftc'), 2 if flags else 0, argv)
                if flags:
                    at = argv.index('-DDAYDREAM_OWNER_TYPING')
                    self.assertEqual(argv[at - 1:at + 3], list(self.OWNER_FLAGS), argv)
                else:
                    self.assertFalse([a for a in argv if a.startswith('-D')], argv)

    def test_owner_stage_records_owner_build(self):
        printed = self.stage('--owner-build', '--updates', 'off')
        out = self.folder / 'out'
        app = out / 'DayDream.app'
        self.assertEqual(self.calls, [(out / 'build-owner', self.OWNER_FLAGS)])
        receipt = json.loads((out / 'stage-receipt.json').read_text())
        self.assertIs(receipt['owner_build'], True)
        self.assertEqual(receipt['updates'], 'off')
        self.assertEqual(receipt['swift_flags'], list(self.OWNER_FLAGS))
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        self.assertIs(info[dr.OWNER_PLIST_KEY], True)
        self.assertIs(receipt['info_plist'][dr.OWNER_PLIST_KEY], True)
        self.assertIn('OWNER BUILD', printed)
        self.assertTrue(dr.owner_app(app))
        # The owner app still passes the release checks sign and verify run on it (with --updates off),
        # and carries no update feed or key: the public checks for a configured build refuse it.
        self.assertEqual(dr.info_problems(info, writer_payload.ID, 'off', True), [])
        self.assertTrue(dr.info_problems(info, writer_payload.ID, 'configured', True, FIXTURE_UPDATES))
        # The owner's copy carries "On this Mac" too (owner decision 2026-09-26).
        self.assertEqual(dr.app_writer_id(app), writer_payload.ID)
        self.assertEqual(receipt['writer_runtime']['id'], writer_payload.ID)
        release.audit(app)

    def refused(self, needle, *extra, env=None, built=False):
        with self.assertRaises(dr.ReleaseError) as caught:
            self.stage(*extra, env=env)
        self.assertIn(needle, str(caught.exception))
        self.assertEqual(bool(self.calls), built)
        self.assertEqual((self.folder / 'out').exists(), built)
        self.assertFalse((self.folder / 'out/stage-receipt.json').exists())

    def test_public_stage_compiles_typing_in(self):
        printed = self.stage()
        out = self.folder / 'out'
        app = out / 'DayDream.app'
        self.assertEqual(self.calls, [(out / 'build', self.OWNER_FLAGS)])
        receipt = json.loads((out / 'stage-receipt.json').read_text())
        self.assertIs(receipt['owner_build'], False)
        self.assertEqual(receipt['swift_flags'], list(self.OWNER_FLAGS))
        self.assertNotIn(dr.OWNER_PLIST_KEY, plistlib.loads((app / 'Contents/Info.plist').read_bytes()))
        self.assertFalse(dr.owner_app(app))
        self.assertIn('MacOS/MacMem carries WebTypingRoute', dr.owner_markers(app))
        self.assertIn('Typing in more apps and on websites compiled in', printed)
        self.assertNotIn('OWNER BUILD', printed)

    def test_public_stage_without_typing_refused(self):
        self.marks = {}  # flags passed, but the website typing route never compiled in
        self.refused('full-typing build without MacOS/MacMem carries WebTypingRoute', built=True)
        self.assertEqual(self.calls[0][1], self.OWNER_FLAGS)

    def test_public_stage_refuses_the_owner_banner_in_any_binary(self):
        for name in dr.SWIFT_BINARIES:
            with self.subTest(name=name):
                shutil.rmtree(self.folder / 'out', ignore_errors=True)
                self.calls, self.marks = [], dict(TYPING_BYTES)
                self.marks[name] = self.marks.get(name, b'') + b'OWNER BUILD'
                self.refused('owner marker in a public build: MacOS/%s carries OWNER BUILD' % name, built=True)

    def test_public_stage_refuses_a_committed_owner_plist_key(self):
        info = plistlib.loads((self.repo / 'packaging/Info.plist').read_bytes())
        info[dr.OWNER_PLIST_KEY] = False  # any value: a public app has no such key at all
        (self.repo / 'packaging/Info.plist').write_bytes(plistlib.dumps(info))
        git(self.repo, 'commit', '-q', '-am', 'owner key')
        self.refused('owner marker in a public build: Info.plist has %s' % dr.OWNER_PLIST_KEY, built=True)

    def test_public_stage_refuses_the_owner_environment_switch(self):
        self.refused('DAYDREAM_OWNER_TYPING is set', env={'DAYDREAM_OWNER_TYPING': '1'})
        self.stage(env={'DAYDREAM_OWNER_TYPING': '0'})
        self.assertEqual(self.calls[-1][1], self.OWNER_FLAGS)

    def test_owner_stage_without_the_owner_code_refused(self):
        self.marks = {}  # flags passed, but the website typing route never compiled in
        self.refused('owner build without MacOS/MacMem carries WebTypingRoute', '--owner-build', '--updates', 'off', built=True)

    def test_owner_stage_refuses_the_public_update_feed(self):
        # owner/v1 review: the default (--updates configured) would let the next public release replace the owner build.
        self.refused('OWNER BUILD: pass --updates off', '--owner-build')
        self.refused('OWNER BUILD: pass --updates off', '--owner-build', '--updates', 'configured')
        self.stage('--owner-build', '--updates', 'off')
        self.assertEqual(self.calls, [(self.folder / 'out' / 'build-owner', self.OWNER_FLAGS)])

    def test_owner_and_public_builds_never_share_a_scratch_folder(self):
        self.refused('--scratch for an owner stage', '--owner-build', '--updates', 'off', '--scratch', str(self.folder / 'swift'))
        self.refused('--scratch for an owner stage', '--scratch', str(self.folder / 'swift-owner'))
        self.stage('--owner-build', '--updates', 'off', '--scratch', str(self.folder / 'swift-owner'))
        self.assertEqual(self.calls, [(self.folder / 'swift-owner', self.OWNER_FLAGS)])

    def app(self, owner, version='0.1.0 Beta', typing=True):
        app = self.folder / ('owner' if owner else 'public' if typing else 'narrow') / 'DayDream.app'
        (app / 'Contents/MacOS').mkdir(parents=True)
        info = {'CFBundleShortVersionString': version}
        if owner:
            info[dr.OWNER_PLIST_KEY] = True
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        # Public and owner apps alike carry website typing; only the Info.plist key marks the owner's copy.
        (app / 'Contents/MacOS/MacMem').write_bytes(MACHO + (b'WebTypingRoute' if typing else b'NativeTypingRoute'))
        return app

    def dmg(self, app, name, *extra):
        class Reached(FakeRunner):
            def run(self, argv, check=True, env=None, timeout=None, quiet=False):
                raise dr.ReleaseError('REACHED %s' % argv[0])
        with patch.object(dr, 'Runner', return_value=Reached()), patch('subprocess.run', side_effect=AssertionError('must not execute')), \
                contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertEqual(dr.main(['dmg', '--app', str(app), '--out', str(self.folder / name), '--unsigned'] + list(extra)), 2)
        return err.getvalue()

    def test_dmg_names_and_refusals(self):
        owner, public = self.app(True), self.app(False)
        self.assertIn('OWNER BUILD', self.dmg(owner, 'DayDream-0.1.0.dmg'))
        self.assertIn('OWNER BUILD', self.dmg(owner, 'DayDream-0.1.0-owner.dmg'))
        self.assertIn('must be named DayDream-0.1.0-owner.dmg', self.dmg(owner, 'DayDream-0.1.0.dmg', '--owner-build'))
        self.assertIn('REACHED codesign', self.dmg(owner, 'DayDream-0.1.0-owner.dmg', '--owner-build'))
        self.assertIn('not an owner build', self.dmg(public, 'DayDream-0.1.0-owner.dmg', '--owner-build'))
        self.assertIn('must be named DayDream-0.1.0.dmg', self.dmg(public, 'DayDream-0.1.0-owner.dmg'))
        self.assertIn('REACHED codesign', self.dmg(public, 'DayDream-0.1.0.dmg'))
        self.assertEqual(dr.dmg_name('0.1.0 Beta', True), 'DayDream-0.1.0-owner.dmg')
        # public-typing review: an app without website typing (a narrow build) is never packaged.
        narrow = self.app(False, typing=False)
        self.assertIn('Not the full-typing build', self.dmg(narrow, 'DayDream-0.1.0.dmg'))
        self.assertTrue(dr.typing_app(public) and dr.typing_app(owner) and not dr.typing_app(narrow)
                        and not dr.typing_app(self.folder / 'missing' / 'DayDream.app'))

    def test_sign_and_staple_refuse_a_narrow_app(self):
        # public-typing review: sign's pre-sign checks and staple's app checks need the full-typing build.
        source = (SCRIPTS / 'developer-id-release.py').read_text()
        sign = source[source.index('def cmd_sign('):source.index('def cmd_verify(')]
        self.assertLess(sign.index('if typing_app(target) else'), sign.index("require(not problems, 'Pre-sign checks failed"))
        staple = source[source.index('def cmd_staple('):source.index('def checksum_path(')]
        self.assertLess(staple.index('if typing_app(artifact) else'), staple.index("require(not problems, 'Refusing to staple"))

    def test_notes_refuse_a_narrow_app(self):
        dmg = self.folder / 'DayDream-0.1.0.dmg'
        dmg.write_bytes(b'image')
        with self.assertRaisesRegex(dr.ReleaseError, 'Not the full-typing build'):
            dr.release_notes(self.app(False, typing=False), dmg, FakeRunner())

    def test_owner_dmg_checksum_but_never_notes_or_appcast(self):
        dmg = self.folder / 'DayDream-0.1.0-owner.dmg'
        dmg.write_bytes(b'owner image')
        self.assertEqual(dr.write_checksum(dmg, FakeRunner()), hashlib.sha256(b'owner image').hexdigest())
        owner = self.app(True)
        with self.assertRaisesRegex(dr.ReleaseError, 'OWNER BUILD'):
            dr.release_notes(owner, dmg, FakeRunner())
        source = (SCRIPTS / 'release.py').read_text()
        # updates-1003: prepare (from the app) and appcast (from the DMG or zip) share _release_app_facts, which holds
        # the refusals; each calls it before any archive is made or signed.
        prepare = source[source.index('def _release_app_facts('):source.index('def main(')]
        refusal = prepare.index('require("MacMemOwnerTyping" not in info,')
        # Website typing alone is no refusal (every release carries it); its absence is: a narrow app never
        # reaches the appcast (public-typing review).
        narrow = prepare.index('b"WebTypingRoute" in macmem.read_bytes()')
        for later in ('runner(["ditto", "-c"', 'appcast_argv('):
            self.assertLess(refusal, prepare.index(later))
            self.assertLess(narrow, prepare.index(later))
        for name in ('def prepare(', 'def appcast('):
            body = source[source.index(name):]
            body = body[:body.index('\ndef ', 1)]
            facts = body.index('_release_app_facts(')
            for later in ('runner(["ditto", "-c"', '_sign_feed('):
                self.assertLess(facts, body.index(later), (name, later))

    def test_owner_build_help_never_says_typing_differs(self):
        # public-typing review: dmg and notarize said "(expanded and website typing ON)" after every stage
        # compiled both in. Typing is the same in both apps; --owner-build only marks the owner's copy.
        parser = dr.build_parser()
        subs = next(a for a in parser._actions if isinstance(a, argparse._SubParsersAction)).choices
        helps = {}
        for name, sub in subs.items():
            for action in sub._actions:
                if action.help:
                    helps['%s %s' % (name, '/'.join(action.option_strings) or action.dest)] = action.help
        owner = {k: v for k, v in helps.items() if k.endswith('--owner-build')}
        self.assertEqual(set(owner), {'stage --owner-build', 'dmg --owner-build', 'notarize --owner-build'})
        for key, text in helps.items():
            self.assertNotRegex(text, r'(?i)typing\s+(is\s+)?on\b', key)
            self.assertNotIn('website typing ON', text, key)
        self.assertEqual(owner['dmg --owner-build'], dr.OWNER_COPY_HELP)
        self.assertEqual(owner['notarize --owner-build'], dr.OWNER_COPY_HELP)
        self.assertIn('typing is the same as the public release', dr.OWNER_COPY_HELP)
        self.assertNotIn('typing ON', (SCRIPTS / 'developer-id-release.py').read_text())

    def test_sign_records_an_owner_build(self):
        source = (SCRIPTS / 'developer-id-release.py').read_text()
        sign = source[source.index('def cmd_sign('):source.index('def cmd_verify(')]
        self.assertIn("'owner_build': owner_app(target)", sign)


class WriterRuntimeStage(SignedRuntimeFixture, unittest.TestCase):
    """Owner decision 2026-09-26: "On this Mac" is in every build. stage takes the signed runtime from the
    commit's packaging/WriterRuntime/<ID>/, checks it against that commit's own pins (manifest SHA-256 compiled
    into SignedRuntimePolicy.swift, MacOS15Runtime pins, bytes, the loader's Mach-O rule, Developer ID signature,
    team and leaf) and copies it unchanged. Without it stage refuses, unless it is explicitly a test build,
    which is then never released."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='daydream-writer-stage-')
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.repo = fixture_repo(self.folder)
        self.built = []
        self.fake_signatures()

    def builder(self, source, scratch, runner, swift_flags=()):
        self.built.append(Path(scratch))
        bins = Path(scratch) / 'release'
        bins.mkdir(parents=True)
        for name in dr.SWIFT_BINARIES:
            (bins / name).write_bytes(MACHO + name.encode() + TYPING_BYTES.get(name, b''))
        icons = bins / 'MacMem_MemoryUI.bundle/SiteIcons'
        icons.mkdir(parents=True)
        (icons / 'x.png').write_bytes(b'x-favicon-fixture')
        (icons / 'instagram.png').write_bytes(b'instagram-favicon-fixture')
        return bins

    def stage(self, *extra, out='out', runner=None):
        # G78 (gold/int): every stage names the build it follows or says it is the first.
        first = [] if '--previous-build' in extra or '--first-build' in extra else ['--first-build']
        # 263cdae: retain the fixture's named 0.1.0 DMG independently of the release default.
        args = dr.build_parser().parse_args(['stage', '--without-search-runtime-for-tests', '--out', str(self.folder / out), '--build', '20260926120000', '--version', '0.1.0'] + first + list(extra))
        runner = runner or HybridRunner()
        with contextlib.redirect_stdout(io.StringIO()) as printed:
            dr.cmd_stage(args, runner=runner, root=self.repo, builder=self.builder)
        return runner, printed.getvalue()

    def use(self, **kw):
        self.repo = fixture_repo(self.folder / ('variant-%d' % len(list(self.folder.iterdir()))), writer=writer_files(**kw))
        return self.repo

    def refused_early(self, needle, *extra):
        """Refused before anything is built or written."""
        with self.assertRaises(dr.ReleaseError) as caught:
            self.stage(*extra)
        self.assertIn(needle, str(caught.exception))
        self.assertFalse((self.folder / 'out').exists())
        self.assertEqual(self.built, [])

    def test_stage_places_the_signed_runtime_unchanged(self):
        runner, printed = self.stage()
        out = self.folder / 'out'
        app = out / 'DayDream.app'
        contents = app / 'Contents'
        committed = self.repo / writer_payload.SOURCE_DIR
        self.assertEqual((contents / writer_payload.MANIFEST).read_bytes(), (committed / writer_payload.MANIFEST_NAME).read_bytes())
        self.assertEqual(sorted(p.name for p in (contents / 'Resources/WriterRuntime').iterdir()), [writer_payload.ID + '.json'])
        self.assertEqual(sorted(p.name for p in (contents / 'Frameworks/WriterRuntime').iterdir()), [writer_payload.ID])
        self.assertEqual(sorted(p.name for p in (contents / writer_payload.LIBROOT).iterdir()), WRITER_NAMES)
        for name in WRITER_NAMES:
            self.assertEqual((contents / writer_payload.LIBROOT / name).read_bytes(), (committed / name).read_bytes())
        info = plistlib.loads((contents / 'Info.plist').read_bytes())
        self.assertEqual(info['DaydreamWriterRuntimeDistribution'], writer_payload.ID)
        self.assertEqual(info['LSMinimumSystemVersion'], '15.0')
        companions = json.loads((contents / 'Resources/Companions.json').read_text())['sha256']
        for rel in writer_payload.paths(app):
            self.assertEqual(companions[rel], hashlib.sha256((contents / rel).read_bytes()).hexdigest(), rel)
        self.assertEqual(len(writer_payload.paths(app)), 8)
        receipt = json.loads((out / 'stage-receipt.json').read_text())
        self.assertEqual(receipt['writer_runtime']['id'], writer_payload.ID)
        self.assertEqual(receipt['writer_runtime']['manifest_sha256'],
                         hashlib.sha256((committed / writer_payload.MANIFEST_NAME).read_bytes()).hexdigest())
        self.assertIs(receipt['test_only_without_writer_runtime'], False)
        self.assertEqual(dr.app_writer_id(app), writer_payload.ID)
        self.assertEqual(dr.coverage_problems(app), [])
        release.audit(app)
        self.assertIn('On this Mac runtime: %s (signed, unchanged)' % writer_payload.ID, printed)
        # stage signs nothing; it checked each library against the Developer ID + team requirement.
        self.assertFalse(any(c[0] == 'codesign' and '--sign' in c for c in runner.calls))
        checked = [c[-1] for c in runner.calls if c[:3] == ['codesign', '--verify', '--strict'] and c[3].startswith('-R=')]
        self.assertEqual(sorted(Path(p).name for p in checked), WRITER_NAMES)
        self.assertTrue(all('/source/' + writer_payload.SOURCE_DIR + '/' in p for p in checked), checked)
        # sign verifies them in place and never re-signs them; the outer app is signed last.
        steps = dr.sign_steps(app, SHA1)
        writer = [s for s in steps if s['row'] == 'writer-runtime']
        self.assertEqual(sorted(Path(s['argv'][-1]).name for s in writer), WRITER_NAMES)
        self.assertEqual({s['action'] for s in writer}, {'verify'})
        self.assertFalse(any('WriterRuntime' in s['argv'][-1] for s in steps if s['action'] == 'sign'))
        self.assertEqual(steps[-1]['row'], 'app')
        self.assertLess(max(steps.index(s) for s in writer), steps.index(next(s for s in steps if s['action'] == 'manifest')))
        # verify's writer check passes with the enrolled leaf, and fails with any other.
        report, problems = dr.writer_verification(app, FakeRunner(), writer_payload.ID)
        self.assertEqual((len(report), problems), (7, []))

    def test_owner_stage_carries_the_runtime_too(self):
        self.stage('--owner-build', '--updates', 'off')
        app = self.folder / 'out/DayDream.app'
        self.assertTrue(dr.owner_app(app))
        self.assertEqual(dr.app_writer_id(app), writer_payload.ID)

    def test_commit_without_the_signed_runtime_is_refused(self):
        self.use(signed=False)
        self.refused_early('writer runtime not signed yet')
        self.assertIn('--without-writer-runtime-for-tests', writer_payload.NOT_SIGNED)

    def test_test_build_without_the_runtime_is_never_released(self):
        self.use(signed=False)
        runner, printed = self.stage('--without-writer-runtime-for-tests')
        out = self.folder / 'out'
        app = out / 'DayDream.app'
        self.assertIn('TEST BUILD', printed)
        self.assertIn('NONE. TEST BUILD ONLY', printed)
        self.assertFalse((app / 'Contents/Frameworks/WriterRuntime').exists())
        self.assertFalse((app / 'Contents/Resources/WriterRuntime').exists())
        self.assertNotIn('DaydreamWriterRuntimeDistribution', plistlib.loads((app / 'Contents/Info.plist').read_bytes()))
        receipt = json.loads((out / 'stage-receipt.json').read_text())
        self.assertIs(receipt['test_only_without_writer_runtime'], True)
        self.assertIsNone(receipt['writer_runtime'])
        self.assertIsNone(dr.app_writer_id(app))
        release.audit(app)
        # Never into the appcast...
        with self.assertRaisesRegex(ValueError, 'No On this Mac runtime inside'):
            release.prepare(app, self.folder / 'updates', self.folder / 'none.key', 0, None, True)
        # ...and never a Developer ID image (refused before any command runs).
        with patch.object(dr, 'Runner', return_value=FakeRunner()), patch('subprocess.run', side_effect=AssertionError('must not execute')), \
                contextlib.redirect_stderr(io.StringIO()) as err:
            code = dr.main(['dmg', '--app', str(app), '--out', str(self.folder / 'DayDream-0.1.0.dmg'), '--identity', SHA1])
        self.assertEqual(code, 2)
        self.assertIn('no "On this Mac" runtime inside', err.getvalue())
        self.assertFalse((self.folder / 'DayDream-0.1.0.dmg').exists())

    def test_pin_mismatch_is_refused(self):
        self.use(pin='0' * 64)
        self.refused_early('does not match the pin')

    def test_unpinned_runtime_is_refused(self):
        self.use(pin=None)
        self.refused_early('is not pinned')

    def test_changed_library_is_refused(self):
        files = writer_files()
        files[writer_payload.SOURCE_DIR + '/libllama.0.dylib'] += b'changed'
        self.repo = fixture_repo(self.folder / 'changed', writer=files)
        self.refused_early('bytes differ from the manifest: libllama.0.dylib')

    def test_extra_or_missing_file_is_refused(self):
        files = writer_files()
        files[writer_payload.SOURCE_DIR + '/notes.txt'] = b'x'
        self.repo = fixture_repo(self.folder / 'extra', writer=files)
        self.refused_early("differ from the manifest (extra or missing: ['notes.txt'])")
        files = writer_files()
        del files[writer_payload.SOURCE_DIR + '/libggml-rpc.0.dylib']
        self.repo = fixture_repo(self.folder / 'missing', writer=files)
        self.refused_early("differ from the manifest (extra or missing: ['libggml-rpc.0.dylib'])")

    def test_library_the_loader_would_refuse_is_refused(self):
        libraries = {n: synthetic_dylib(n) for n in WRITER_NAMES}
        libraries['libllama.0.dylib'] = synthetic_dylib('libllama.0.dylib', ('@rpath/libggml.0.dylib',))
        self.use(libraries=libraries)
        self.refused_early('would be refused by the loader')

    def test_wrong_signature_is_refused(self):
        for kw, needle in ((dict(identifier='com.daydream.writer.libllama.0'), 'identifier'),
                           (dict(leaf='0' * 64), 'leaf certificate'),
                           (dict(team='OTHERTEAM1'), 'TeamIdentifier')):
            with self.subTest(**kw):
                shutil.rmtree(self.folder / 'out', ignore_errors=True)
                self.fake_signatures(**kw)
                with self.assertRaises(dr.ReleaseError) as caught:
                    self.stage()
                self.assertIn('Writer runtime signatures refused', str(caught.exception))
                self.assertIn(needle, str(caught.exception))
                self.assertEqual(self.built, [])
                self.assertFalse((self.folder / 'out/DayDream.app').exists())
        self.fake_signatures()
        runner = HybridRunner()
        runner.returncodes = {('codesign', '--verify', '--strict'): 1}
        shutil.rmtree(self.folder / 'out', ignore_errors=True)
        with self.assertRaisesRegex(dr.ReleaseError, 'Developer ID, team L76C3ZC66J'):
            self.stage(runner=runner)

    def test_app_with_a_manifest_that_no_longer_matches_the_pin_is_refused(self):
        self.stage()
        app = self.folder / 'out/DayDream.app'
        pins = writer_payload.load_pins(self.repo)
        with patch.object(writer_payload, 'load_pins', return_value={**pins, 'approved': {writer_payload.ID: '1' * 64}}):
            with self.assertRaisesRegex(ValueError, 'does not match the pin'):
                release.audit(app)
        (app / 'Contents' / writer_payload.LIBROOT / 'libggml.0.dylib').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'Signed writer bytes changed: libggml.0.dylib'):
            release.audit(app)

    def test_every_library_keeps_the_loader_identifier(self):
        self.assertEqual(writer_payload.signing_identifier('libllama.0.dylib'), 'com.getnorthlight.daydream.writer.libllama.0')
        manifest = json.loads(synthetic_manifest({n: synthetic_dylib(n) for n in WRITER_NAMES}))
        bad = dict(manifest)
        bad['files'] = [dict(r, signingIdentifier='com.daydream.writer.' + r['name'][:-6]) for r in manifest['files']]
        raw = json.dumps(bad).encode()
        pins = {**RUNTIME_PINS, 'approved': {writer_payload.ID: hashlib.sha256(raw).hexdigest()}}
        self.assertTrue(any('signingIdentifier' in p for p in writer_payload.manifest_problems(raw, pins)))


class RealRepositoryRuntime(unittest.TestCase):
    """The repository itself: the signed set is committable, and it is either absent (stage refuses: not signed
    yet) or exactly what SignedRuntimePolicy.swift pins."""

    def test_signed_libraries_are_not_gitignored(self):
        probe = writer_payload.SOURCE_DIR + '/libllama.0.dylib'
        ignored = subprocess.run(['git', '-C', str(dr.ROOT), 'check-ignore', '-q', '--no-index', probe]).returncode
        self.assertEqual(ignored, 1, probe + ' would be ignored by .gitignore')
        self.assertEqual(subprocess.run(['git', '-C', str(dr.ROOT), 'check-ignore', '-q', '--no-index', 'build/libx.dylib']).returncode, 0)

    def test_committed_runtime_matches_the_compiled_pin(self):
        pins = writer_payload.load_pins()
        self.assertLessEqual(len(pins['approved']), 1)
        if writer_payload.source_present(dr.ROOT):
            manifest, rows = writer_payload.source_files(dr.ROOT)
            self.assertEqual(pins['approved'], {writer_payload.ID: hashlib.sha256(manifest.read_bytes()).hexdigest()})
            self.assertEqual(len(rows), 7)
        else:
            self.assertNotIn(writer_payload.ID, pins['approved'])
            self.assertIn('writer runtime not signed yet', writer_payload.NOT_SIGNED)


class ManifestV2Tool(unittest.TestCase):
    """WriterBackend/runtime_distribution.py manifest-v2, the signing kit's last step, writes exactly the manifest
    stage accepts once pinned, and refuses a set the loader would refuse."""

    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, str(dr.ROOT / 'WriterBackend'))
        import runtime_distribution
        cls.rd = runtime_distribution

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='writer-manifest-')
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name) / 'signed'
        self.dir.mkdir()
        self.libraries = {n: synthetic_dylib(n) for n in WRITER_NAMES}
        for name, data in self.libraries.items():
            (self.dir / name).write_bytes(data)

    def test_output_is_what_stage_accepts_once_pinned(self):
        raw, sha = self.rd.manifest_v2(self.dir, writer_payload.LEAF_SHA256)
        self.assertEqual(raw, synthetic_manifest(self.libraries))
        self.assertEqual(sha, hashlib.sha256(raw).hexdigest())
        pins = writer_payload.load_pins()
        self.assertEqual(writer_payload.manifest_problems(raw, {**pins, 'approved': {writer_payload.ID: sha}}), [])
        self.assertIn('does not match the pin', writer_payload.manifest_problems(raw, {**pins, 'approved': {writer_payload.ID: '0' * 64}})[0])
        self.assertIn('is not pinned', writer_payload.manifest_problems(raw, {**pins, 'approved': {}})[0])

    def test_refuses_another_certificate(self):
        with self.assertRaisesRegex(ValueError, 'not the enrolled'):
            self.rd.manifest_v2(self.dir, 'b' * 64)

    def test_refuses_what_the_loader_would(self):
        (self.dir / 'libggml-rpc.0.dylib').write_bytes(synthetic_dylib('libggml-rpc.0.dylib', ('/opt/homebrew/lib/libz.1.dylib',)))
        with self.assertRaisesRegex(ValueError, 'would be refused by the loader'):
            self.rd.manifest_v2(self.dir, writer_payload.LEAF_SHA256)

    def test_refuses_a_missing_or_extra_library(self):
        (self.dir / 'extra.dylib').write_bytes(b'x')
        with self.assertRaises(ValueError):
            self.rd.manifest_v2(self.dir, writer_payload.LEAF_SHA256)
        (self.dir / 'extra.dylib').unlink()
        (self.dir / 'libllama.0.dylib').unlink()
        with self.assertRaises((ValueError, OSError)):
            self.rd.manifest_v2(self.dir, writer_payload.LEAF_SHA256)


class DownloadNameAndChecksum(unittest.TestCase):
    """Item 31: DayDream-<version>.dmg, and its SHA-256 only after stapling."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='daydream-sum-')
        self.addCleanup(self.temp.cleanup)
        self.dmg = Path(self.temp.name) / 'DayDream-0.1.0.dmg'
        self.dmg.write_bytes(b'image before staple')

    def test_checksum_refused_before_staple(self):
        runner = FakeRunner({('xcrun', 'stapler', 'validate'): 65})
        with self.assertRaisesRegex(dr.ReleaseError, 'not stapled'):
            dr.write_checksum(self.dmg, runner)
        self.assertFalse(dr.checksum_path(self.dmg).exists())

    def test_checksum_format(self):
        digest = dr.write_checksum(self.dmg, FakeRunner())
        self.assertEqual(digest, hashlib.sha256(b'image before staple').hexdigest())
        self.assertEqual(dr.checksum_path(self.dmg).read_text(), '%s  DayDream-0.1.0.dmg\n' % digest)
        for name in ('DayDream-0.1.0-20260926.dmg', 'Daydream-0.1.0.dmg', 'DayDream.dmg'):
            other = Path(self.temp.name) / name
            other.write_bytes(b'x')
            with self.assertRaises(dr.ReleaseError):
                dr.write_checksum(other, FakeRunner())

    def test_staple_writes_the_checksum_of_the_stapled_file(self):
        dmg = self.dmg

        class StapleRunner(FakeRunner):
            def run(self, argv, check=True, env=None, timeout=None, quiet=False):
                argv = [str(a) for a in argv]
                self.calls.append(argv)
                if argv[:3] == ['xcrun', 'stapler', 'staple']:
                    with open(dmg, 'ab') as stream:
                        stream.write(b'+ticket')  # stapling changes the bytes
                out = 'accepted source=Notarized Developer ID' if argv[0] == 'spctl' else ''
                return subprocess.CompletedProcess(argv, 0, out, '')

        runner = StapleRunner()
        notary = Path(self.temp.name) / 'notary'
        notary.mkdir()
        (notary / 'notary-dmg-receipt.json').write_text(json.dumps({'status': 'Accepted', 'artifact_cdhash': 'ab'}))
        before = hashlib.sha256(dmg.read_bytes()).hexdigest()
        with patch.object(dr, 'Runner', return_value=runner), patch.object(dr, 'artifact_cdhash', return_value='ab'), \
                patch.object(dr, 'chrome_page_history_switch', return_value=True), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(dr.main(['staple', '--artifact', str(dmg), '--notary-dir', str(notary), '--execute']), 0)
        after = hashlib.sha256(dmg.read_bytes()).hexdigest()
        self.assertNotEqual(before, after)
        self.assertEqual(dr.checksum_path(dmg).read_text().split()[0], after)
        staple_at = runner.calls.index(['xcrun', 'stapler', 'staple', str(dmg)])
        validate_after = [i for i, c in enumerate(runner.calls) if c == ['xcrun', 'stapler', 'validate', str(dmg)]]
        self.assertTrue(validate_after and max(validate_after) > staple_at)

    def test_dmg_refuses_a_name_that_is_not_the_version(self):
        with tempfile.TemporaryDirectory(prefix='daydream-dmgname-') as folder:
            app = Path(folder) / 'DayDream.app'
            (app / 'Contents/MacOS').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '0.1.0 Beta'}))
            (app / 'Contents/MacOS/MacMem').write_bytes(MACHO + b'WebTypingRoute')  # the full-typing build
            for name in ('DayDream-0.1.0-20260926.dmg', 'Daydream-0.1.0.dmg', 'DayDream-0.2.0.dmg'):
                with patch('subprocess.run', side_effect=AssertionError('must not execute')), \
                        contextlib.redirect_stderr(io.StringIO()) as err:
                    self.assertEqual(dr.main(['dmg', '--app', str(app), '--out', str(Path(folder) / name), '--unsigned']), 2)
                self.assertIn('DayDream-0.1.0.dmg', err.getvalue())

    def test_dmg_background_says_beta(self):
        source = (SCRIPTS / 'developer-id-release.py').read_text()
        self.assertIn("'dmg-background.swift', mount, work / 'background.alias', dmg_label(short_version)", source)
        self.assertIn('CommandLine.arguments[3]', (SCRIPTS / 'dmg-background.swift').read_text())


class TestImageNames(unittest.TestCase):
    """G77 (golden test 5): a test build's image has its own file and volume name, never test 4's
    (DayDream-0.1.0.dmg on the volume "DayDream"), and never passes for a public release."""

    NAME = 'DayDream - Saturday test 5.dmg'

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='daydream-testdmg-')
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)

    def app(self, owner=False):
        app = self.folder / ('owner' if owner else 'public') / 'DayDream.app'
        (app / 'Contents/MacOS').mkdir(parents=True)
        info = {'CFBundleShortVersionString': '0.1.0 Beta'}
        if owner:
            info[dr.OWNER_PLIST_KEY] = True
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        (app / 'Contents/MacOS/MacMem').write_bytes(MACHO + b'WebTypingRoute')
        return app

    def test_names(self):
        out = self.folder
        self.assertEqual(dr.dmg_target(out, self.NAME, None, '0.1.0 Beta'), (out / self.NAME, 'DayDream - Saturday test 5'))
        self.assertEqual(dr.dmg_target(out / self.NAME, self.NAME, 'DayDream Saturday 5', '0.1.0 Beta'),
                         (out / self.NAME, 'DayDream Saturday 5'))
        self.assertEqual(dr.dmg_target(out / 'DayDream-0.1.0.dmg', None, None, '0.1.0 Beta'), (out / 'DayDream-0.1.0.dmg', 'DayDream'))
        # test 4's image: DayDream-0.1.0.dmg on the volume "DayDream". Test 5's differs in both.
        test4 = (dr.dmg_name('0.1.0 Beta'), dr.RELEASE_VOLUME_NAME)
        self.assertEqual(test4, ('DayDream-0.1.0.dmg', 'DayDream'))
        test5 = dr.dmg_target(out, self.NAME, None, '0.1.0 Beta')
        self.assertNotEqual(test5[0].name, test4[0])
        self.assertNotEqual(test5[1], test4[1])
        for bad in ('DayDream-0.1.0.dmg', 'DayDream - .dmg', 'Daydream - test.dmg', 'DayDream - a/b.dmg', 'DayDream - test',
                    'DayDream -  test.dmg', 'DayDream - test .dmg', '../DayDream - test.dmg', 'DayDream - test.dmg.zip'):
            self.assertFalse(dr.test_dmg_name(bad), bad)
            with self.assertRaises(dr.ReleaseError):
                dr.dmg_target(out, bad, None, '0.1.0 Beta')
        for bad in ('DayDream', 'Daydream test', 'DayDream  test', 'Other', 'DayDream test/5', 'DayDream test '):
            with self.assertRaises(dr.ReleaseError, msg=bad):
                dr.dmg_target(out, self.NAME, bad, '0.1.0 Beta')
        with self.assertRaisesRegex(dr.ReleaseError, 'path ending in'):
            dr.dmg_target(out / 'other.dmg', self.NAME, None, '0.1.0 Beta')
        with self.assertRaisesRegex(dr.ReleaseError, 'is for a test image'):
            dr.dmg_target(out / 'DayDream-0.1.0.dmg', None, 'DayDream test', '0.1.0 Beta')
        with self.assertRaisesRegex(dr.ReleaseError, 'or give a test build its own name'):
            dr.dmg_target(out / self.NAME, None, None, '0.1.0 Beta')

    def test_dmg_builds_the_test_image_on_its_own_volume(self):
        class Recorder(FakeRunner):
            def run(self, argv, check=True, env=None, timeout=None, quiet=False):
                done = super().run(argv, check, env, timeout, quiet)
                if done.args[:2] == ['hdiutil', 'attach']:
                    raise dr.ReleaseError('STOP at attach')
                return done
        runner = Recorder()
        app = self.app()
        with patch.object(dr, 'Runner', return_value=runner), patch('subprocess.run', side_effect=AssertionError('must not execute')), \
                contextlib.redirect_stderr(io.StringIO()) as err:
            code = dr.main(['dmg', '--app', str(app), '--out', str(self.folder), '--name', self.NAME, '--unsigned'])
        self.assertEqual(code, 2)
        self.assertIn('STOP at attach', err.getvalue())
        create = next(c for c in runner.calls if c[:2] == ['hdiutil', 'create'])
        self.assertEqual(create[create.index('-volname') + 1], 'DayDream - Saturday test 5')
        self.assertFalse((self.folder / self.NAME).exists())
        self.assertEqual([p.name for p in self.folder.iterdir() if p.name.startswith('dmg-work.')], [])
        with patch('subprocess.run', side_effect=AssertionError('must not execute')), contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertEqual(dr.main(['dmg', '--app', str(app), '--out', str(self.folder / 'DayDream-0.1.0.dmg'),
                                      '--volume-name', 'DayDream test 5', '--unsigned']), 2)
        self.assertIn('is for a test image', err.getvalue())
        source = (SCRIPTS / 'developer-id-release.py').read_text()
        self.assertIn("'name': dmg.name, 'volume_name': volume,", source)
        self.assertIn("'owner_build': owner,", source)

    def test_owner_copy_of_a_test_image_is_read_from_its_receipt(self):
        dmg = self.folder / self.NAME
        dmg.write_bytes(b'image')
        with self.assertRaisesRegex(dr.ReleaseError, 'keep the'):
            dr.refuse_owner_artifact(dmg, False)
        receipt = Path(str(dmg) + '.receipt.json')
        receipt.write_text(json.dumps({'owner_build': True}))
        with self.assertRaisesRegex(dr.ReleaseError, 'OWNER BUILD'):
            dr.refuse_owner_artifact(dmg, False)
        dr.refuse_owner_artifact(dmg, True)
        receipt.write_text(json.dumps({'owner_build': False}))
        dr.refuse_owner_artifact(dmg, False)
        with self.assertRaisesRegex(dr.ReleaseError, 'not an owner build'):
            dr.refuse_owner_artifact(dmg, True)
        receipt.write_text(json.dumps({}))
        with self.assertRaisesRegex(dr.ReleaseError, 'does not say'):
            dr.dmg_owner(dmg)
        # Release names keep reading their name.
        self.assertTrue(dr.dmg_owner(self.folder / 'DayDream-0.1.0-owner.dmg'))
        self.assertFalse(dr.dmg_owner(self.folder / 'DayDream-0.1.0.dmg'))

    def test_image_gate_reads_the_receipt(self):
        receipt = {'signature': 'developer-id', 'app_stapled': True, 'allow_unstapled_app': False, 'owner_build': False,
                   'sha256': hashlib.sha256(b'image').hexdigest()}
        dmg = self.folder / self.NAME
        dmg.write_bytes(b'image')
        Path(str(dmg) + '.receipt.json').write_text(json.dumps(receipt))
        gate = DmgGate()
        problems, _ = gate.problems(dmg, owner=True)
        self.assertTrue(any('owner\'s private copy' in p for p in problems), problems)
        problems, _ = gate.problems(dmg)
        self.assertEqual(problems, ['the app inside the image is not stapled'])
        Path(str(dmg) + '.receipt.json').write_text(json.dumps({**receipt, 'owner_build': True}))
        problems, _ = gate.problems(dmg, owner=True)
        self.assertEqual(problems, ['the app inside the image is not stapled'])

    def test_checksum_yes_public_notes_no(self):
        dmg = self.folder / self.NAME
        dmg.write_bytes(b'test image')
        self.assertEqual(dr.write_checksum(dmg, FakeRunner()), hashlib.sha256(b'test image').hexdigest())
        self.assertEqual(dr.read_checksum(dmg), (hashlib.sha256(b'test image').hexdigest(), self.NAME))
        with self.assertRaisesRegex(dr.ReleaseError, 'no public release notes'):
            dr.release_notes(self.app(), dmg, FakeRunner())
        runbook = (dr.ROOT / 'RELEASE.md').read_text()
        self.assertIn('--name "DayDream - Test N.dmg"', runbook)
        self.assertIn('--previous-build <last test build>', runbook)

    def test_checksum_line_is_read_back_whole(self):
        # write_checksum writes "<digest>  DayDream - Saturday test 5.dmg"; every reader takes the name whole.
        for name in (self.NAME, 'DayDream-0.1.0.dmg'):
            dmg = self.folder / name
            dmg.write_bytes(b'stapled ' + name.encode())
            digest = dr.write_checksum(dmg, FakeRunner())
            self.assertEqual(dr.checksum_path(dmg).read_text(), '%s  %s\n' % (digest, name))
            self.assertEqual(dr.read_checksum(dmg), (digest, name))
        dmg = self.folder / self.NAME
        digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
        for bad in ('%s %s\n' % (digest, self.NAME), '%s  %s\n%s  other.dmg\n' % (digest, self.NAME, digest),
                    '%s  \n' % digest, digest.upper() + '  ' + self.NAME + '\n', '', 'x  ' + self.NAME + '\n'):
            dr.checksum_path(dmg).write_text(bad)
            with self.assertRaisesRegex(dr.ReleaseError, 'is not one', msg=repr(bad)):
                dr.read_checksum(dmg)
        dr.checksum_path(dmg).unlink()
        with self.assertRaisesRegex(dr.ReleaseError, 'No DayDream - Saturday test 5.dmg.sha256'):
            dr.read_checksum(dmg)
        for script in ('check_dmg.py', 'developer-id-release.py'):
            self.assertFalse('.read_text().split()' in (SCRIPTS / script).read_text(),
                             '%s splits a checksum line at every space; use read_checksum' % script)

    def volume_app(self, version, updates):
        """The DayDream.app a fake mount puts on the volume: just what check_dmg.py reads up to its name gate."""
        app = Path(tempfile.mkdtemp(prefix='volume-', dir=self.folder)) / 'DayDream.app'
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/Resources').mkdir()
        policy = release.update_info(FIXTURE_UPDATES)
        if updates == 'off':
            policy = {k: v for k, v in policy.items() if k not in dr.UPDATE_KEYS}
            policy.update(SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False, SUAllowsAutomaticUpdates=False)
        info = {'CFBundleIdentifier': 'com.getnorthlight.daydream', 'CFBundleDisplayName': 'DayDream',
                'CFBundleShortVersionString': version + ' Beta', 'CFBundleVersion': '20261003120000', **policy}
        self.assertEqual(dr.update_policy_problems(info, updates, FIXTURE_UPDATES), [])
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        for name in ('MacMem', 'mac-mem', 'mac-mem-backup'):
            (app / 'Contents/MacOS' / name).write_bytes(MACHO)
            (app / 'Contents/MacOS' / name).chmod(0o755)
        for name in ('before_turn.py', 'Daydream.icns', 'Sparkle-LICENSE.txt'):
            (app / 'Contents/Resources' / name).write_bytes(b'x')
        (app / 'Contents/Resources/Companions.json').write_text(json.dumps(
            {'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'], 'sha256': {}}))
        return app

    def check_dmg(self, dmg, version, *flags):
        """Run scripts/check_dmg.py (RELEASE.md step 6) in process with every tool faked: codesign, stapler and
        Gatekeeper answer as for a notarized image, the mount holds volume_app(version), and the run stops at the
        first check after the download-name gate (the Sparkle framework's signature)."""
        class PastTheNameGate(Exception):
            pass
        updates = flags[flags.index('--updates') + 1] if '--updates' in flags else 'configured'
        app, calls = self.volume_app(version, updates), []

        def tool(argv, **kwargs):
            argv = [str(a) for a in argv]
            calls.append(argv)
            if argv[:2] == ['hdiutil', 'attach']:
                mount = Path(argv[argv.index('-mountpoint') + 1])
                shutil.copytree(app, mount / 'DayDream.app', symlinks=True)
                (mount / 'Applications').symlink_to('/Applications')
            elif argv[0] == 'ditto':
                shutil.copytree(argv[1], argv[2], symlinks=True)
            elif argv[:3] == ['codesign', '--verify', '--deep']:
                raise PastTheNameGate()
            out = 'source=Notarized Developer ID\n' if argv[0] == 'spctl' else ''
            return subprocess.CompletedProcess(argv, 0, '', out)
        import runpy
        out = io.StringIO()
        with patch('subprocess.run', side_effect=tool), patch.object(release, 'config', return_value=dict(FIXTURE_UPDATES)), \
                patch.object(sys, 'argv', ['check_dmg.py', str(dmg), *flags]), contextlib.redirect_stdout(out):
            try:
                runpy.run_path(str(SCRIPTS / 'check_dmg.py'), run_name='__main__')
            except PastTheNameGate:
                pass
        return out.getvalue(), calls

    def test_check_dmg_accepts_a_test_image_and_its_checksum(self):
        # RELEASE.md "A test build": check "$D" as in step 6, `check_dmg.py "$D" --expect-developer-id`
        # ("A test build with no updates" adds --updates off).
        for name, version, flags in ((self.NAME, '0.2.0', ()), (self.NAME, '0.2.0', ('--updates', 'off')),
                                     ('DayDream-0.1.0.dmg', '0.1.0', ())):
            dmg = self.folder / name
            dmg.write_bytes(b'stapled ' + name.encode())
            dr.write_checksum(dmg, FakeRunner())
            out, calls = self.check_dmg(dmg, version, '--expect-developer-id', *flags)
            self.assertIn('PASS: %s.sha256 matches the stapled image' % name, out)
            self.assertIn('PASS: download named %s; version %s Beta; updates %s'
                          % (name, version, 'off' if flags else 'configured'), out)
            self.assertIn(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint'], [c[:5] for c in calls])
            self.assertEqual(calls[-2][:3], ['codesign', '--verify', '--deep'])
            self.assertEqual(calls[-1][:2], ['hdiutil', 'detach'])
        # The name gate still holds: a release name that is not this version's.
        with self.assertRaisesRegex(AssertionError, r'^DayDream-0\.1\.0\.dmg$'):
            self.check_dmg(self.folder / 'DayDream-0.1.0.dmg', '0.2.0', '--expect-developer-id')
        dmg = self.folder / self.NAME
        dmg.write_bytes(b'rebuilt after the checksum')
        with self.assertRaisesRegex(AssertionError, 'stale or missing DayDream - Saturday test 5.dmg.sha256'):
            self.check_dmg(dmg, '0.2.0', '--expect-developer-id')
        dr.checksum_path(dmg).unlink()
        with self.assertRaisesRegex(AssertionError, 'stale or missing DayDream - Saturday test 5.dmg.sha256'):
            self.check_dmg(dmg, '0.2.0', '--expect-developer-id')


class ReleaseNotes(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='daydream-notes-')
        self.addCleanup(self.temp.cleanup)
        folder = Path(self.temp.name)
        self.app = folder / 'DayDream.app'
        (self.app / 'Contents/Resources').mkdir(parents=True)
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/MacOS/MacMem').write_bytes(b'x\x00$s14WebTypingRouteO\x00')
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '0.1.0 Beta',
                                                                        'CFBundleVersion': '20260926120000',
                                                                        'LSMinimumSystemVersion': '15.0'}))
        self.commit = 'c' * 40
        (self.app / 'Contents/Resources/Companions.json').write_text(json.dumps({'source_commit': self.commit}))
        self.dmg = folder / 'DayDream-0.1.0.dmg'
        self.dmg.write_bytes(b'stapled image')
        dr.write_checksum(self.dmg, FakeRunner())

    def notes(self, runner=None):
        with patch.object(release, 'config', return_value=dict(FIXTURE_UPDATES)):
            return dr.release_notes(self.app, self.dmg, runner or FakeRunner())

    def test_template_filled(self):
        text = self.notes()
        digest = hashlib.sha256(b'stapled image').hexdigest()
        for piece in ('# DayDream 0.1.0 Beta', 'DayDream-0.1.0.dmg', digest, self.commit, 'getnorthlight/daydream',
                      'macOS 15.0 or later', 'beta'):
            self.assertIn(piece, text)
        self.assertNotIn('{{', text)
        self.assertIn('[', text)  # the owner still writes "What's new"; prepare refuses until then

    def test_template_is_plain_and_true(self):
        template = dr.NOTES_TEMPLATE.read_text()
        self.assertTrue(set(re.findall(r'\{\{([A-Z0-9_]+)\}\}', template)) <= {
            'VERSION', 'VERSION_NUMBER', 'TAG', 'BUILD', 'MIN_MACOS', 'DATE', 'COMMIT', 'SHA256', 'DMG', 'REPOSITORY'})
        self.assertNotIn('](', template)  # no markdown links: prepare refuses any "[" left in the notes
        for word in ('Mac Mem', 'Daydream ', 'appcast', 'EdDSA'):
            self.assertNotIn(word, template)

    def test_notes_refuse_stale_checksum_unstapled_image_or_no_commit(self):
        self.dmg.write_bytes(b'rebuilt image')
        with self.assertRaisesRegex(dr.ReleaseError, 'does not match'):
            self.notes()
        dr.write_checksum(self.dmg, FakeRunner())
        with self.assertRaisesRegex(dr.ReleaseError, 'not stapled'):
            self.notes(FakeRunner({('xcrun', 'stapler', 'validate'): 65}))
        (self.app / 'Contents/Resources/Companions.json').write_text('{}')
        with self.assertRaisesRegex(dr.ReleaseError, 'source commit'):
            self.notes()


if __name__ == '__main__':
    unittest.main()
