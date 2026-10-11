#!/usr/bin/env python3
"""Realism, owner bug 3 (10/3, the Live Test copy): permission rows ON in System Settings while DayDream read them OFF.

An ad-hoc build had run under a real bundle ID (com.getnorthlight.daydream.livetest on 9/29). macOS keeps one privacy
row per bundle ID with the code requirement of the copy that made it; an ad-hoc copy's requirement is its cdhash, so the
Developer ID copy could never match the row again ("Failed to match existing code requirement"). The rule since
perm-1004: an ad-hoc or development seal NEVER carries a real or test-copy bundle ID; it always gets <id>.adhoc.

This replays each way an ad-hoc copy gets sealed, on synthetic bundles, and reads the bundle ID the bundle carries at
the moment `codesign --sign -` runs (a fake codesign that signs nothing logs it):
  A. scripts/seal-local-app.sh (package.sh, build-dev-loop.py, preview/build-preview-app.sh and the staging helper all
     seal through it), for the public, Live Test, development and Preview IDs; a second seal never doubles .adhoc.
  B. scripts/stage-local-ui-update.py, the owner's local UI update flow, end to end on a fixture baseline.
  C. scripts/developer-id-release.py `sign --identity -` (its "ad-hoc structure dry run").
The other half of bug 3 (an injected "on in System Settings, off here" state shows one plain-words fix with one button)
is in scripts/realism-app-checks.swift (step realism-tcc-states).

No real signing, keychain, launch, permission read or System Settings. Scratch folders only (REALISM_OUT or TMPDIR).
"""
import contextlib
import importlib.util
import io
import os
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / 'fixtures/realism'))
sys.path.insert(0, str(HERE))
import realism_fixtures as fx  # noqa: E402

report = fx.Report('realism-adhoc-identity')
check = report.check


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def scratch_root():
    base = os.environ.get('REALISM_OUT') or tempfile.gettempdir()
    Path(base).mkdir(parents=True, exist_ok=True)
    return Path(tempfile.mkdtemp(prefix='realism-adhoc-', dir=base))


def seal_paths(root):
    # A. seal-local-app.sh for each real or test-copy ID.
    for real in fx.REAL_AND_TEST_COPY_IDS:
        folder = root / ('seal-' + real.rsplit('.', 1)[-1])
        app = fx.fixture_app(folder, real)
        env, log = fx.fake_env(folder)
        done = fx.run(['bash', HERE / 'seal-local-app.sh', app], env)
        signed = fx.signings(log)
        check(done.returncode == 0 and len(signed) == 1, 'bug3 seal-local-app.sh seals a %s copy once' % real, done.stderr.strip()[-300:])
        check(bool(signed) and signed[0][0] == '-' and signed[0][1] == real + '.adhoc',
              'bug3 seal-local-app.sh: the ad-hoc signature is made under %s.adhoc, never %s' % (real, real), repr(signed))
        check(fx.bundle_id(app) == real + '.adhoc', 'bug3 seal-local-app.sh: the sealed copy says %s.adhoc' % real, fx.bundle_id(app))
        again = fx.run(['bash', HERE / 'seal-local-app.sh', app], env)
        check(again.returncode == 0 and fx.bundle_id(app) == real + '.adhoc' and fx.signings(log)[-1][1] == real + '.adhoc',
              'bug3 seal-local-app.sh: sealing a %s.adhoc copy again keeps one .adhoc' % real, fx.bundle_id(app))


def staging_helper(root):
    # B. The owner's local UI update: an ad-hoc baseline in the home Applications folder, a freshly compiled MacMem, a new build number.
    stage_mod = load('realism_stage_local_ui_update', 'stage-local-ui-update.py')
    for start in ('com.getnorthlight.daydream', 'com.getnorthlight.daydream.adhoc'):
        folder = root / ('stage-' + start.rsplit('.', 1)[-1])
        base = fx.fixture_app(folder / 'base', start)
        binary = folder / 'MacMem-new'
        binary.write_bytes(b'MACHO-FIXTURE MacMem new\n')
        binary.chmod(0o755)
        env, log = fx.fake_env(folder)
        real_run = subprocess.run

        def routed(argv, *a, **k):
            # The helper calls /usr/bin/codesign by its full path: route it to the fake (nothing is signed).
            argv = [str(x) for x in argv]
            if argv and argv[0] in ('/usr/bin/codesign', 'codesign'):
                argv = [str(fx.FAKES / 'codesign')] + argv[1:]
            k.setdefault('env', env)
            return real_run(argv, *a, **k)
        out = folder / 'staged'
        args = stage_mod.argparse.Namespace(base=base, binary=binary, build='101', output=out)
        error = None
        with mock.patch.object(stage_mod.subprocess, 'run', side_effect=routed), contextlib.redirect_stdout(io.StringIO()):
            try:
                stage_mod.stage(args)
            except Exception as problem:  # noqa: BLE001 (reported below)
                error = problem
        signed = fx.signings(log)
        staged = out / 'DayDream.app'
        check(error is None and staged.is_dir(), 'bug3 stage-local-ui-update.py stages a %s baseline' % start, repr(error))
        check(bool(signed) and all(s[0] == '-' and s[1] == 'com.getnorthlight.daydream.adhoc' for s in signed),
              'bug3 stage-local-ui-update.py: its ad-hoc seal is made under com.getnorthlight.daydream.adhoc (baseline %s)' % start, repr(signed))
        receipt = (out / 'staging-receipt.json')
        check(receipt.is_file() and '"bundleIdentifier": "com.getnorthlight.daydream.adhoc"' in receipt.read_text(),
              'bug3 stage-local-ui-update.py: the receipt names the .adhoc ID (baseline %s)' % start)


def developer_id_dry_run(root):
    # C. developer-id-release.py `sign --identity -`: the "ad-hoc structure dry run" makes a runnable ad-hoc DayDream.app.
    dr = load('realism_developer_id_release', 'developer-id-release.py')
    app = fx.fixture_app(root / 'devid', 'com.getnorthlight.daydream')
    steps = dr.sign_steps(app, '-', present=lambda rel: True, writer_libs=[])
    signs = [s for s in steps if s['action'] == 'sign']
    main = [s for s in signs if not s.get('rel')]
    ids = []
    for step in main:
        argv = step['argv']
        ids.append(argv[argv.index('--identifier') + 1] if '--identifier' in argv else fx.bundle_id(app))
    check(len(main) == 1 and all(argv['argv'][3] == '-' for argv in main),
          'bug3 developer-id-release.py sign --identity -: one ad-hoc signature of the app itself', repr([s['argv'] for s in main]))
    check(bool(ids) and all(i.endswith('.adhoc') for i in ids),
          'bug3 developer-id-release.py sign --identity -: the ad-hoc dry run seals the app under an .adhoc ID, never com.getnorthlight.daydream',
          'identifier ' + repr(ids))


def main():
    root = scratch_root()
    seal_paths(root)
    staging_helper(root)
    developer_id_dry_run(root)
    return report.finish()


if __name__ == '__main__':
    sys.exit(main())
