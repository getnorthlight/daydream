"""Shared fixtures for the realism release checks (scripts/realism-adhoc-identity-checks.py,
scripts/realism-staging-checks.py). Synthetic app bundles and a fake codesign only: nothing here signs, builds,
launches, installs or reads a keychain, and every path is under the caller's scratch folder.
"""
import hashlib
import json
import os
import plistlib
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
FAKES = HERE / 'fakes'
SCRIPTS = HERE.parent.parent
ROOT = SCRIPTS.parent

# The IDs an ad-hoc copy must never be sealed under (perm-1004; tccd 10/3 and the owner's TCC lesson): the public app,
# the Live Test copy, the development copy and the Preview copy. Each gets its own <id>.adhoc.
REAL_AND_TEST_COPY_IDS = ['com.getnorthlight.daydream', 'com.getnorthlight.daydream.livetest',
                          'com.getnorthlight.daydream.development', 'com.getnorthlight.daydream.preview']


class Report:
    def __init__(self, name):
        self.name, self.passed, self.failed = name, 0, 0

    def check(self, ok, label, detail=''):
        if ok:
            self.passed += 1
            print('PASS ' + label, flush=True)
        else:
            self.failed += 1
            print('FAIL ' + label + (('  [' + detail + ']') if detail else ''), flush=True)

    def finish(self):
        print('%s: %d passed, %d failed' % (self.name, self.passed, self.failed), flush=True)
        return 1 if self.failed else 0


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def fixture_app(folder, bundle_id, build='100', macmem=b'MACHO-FIXTURE MacMem\n'):
    """A synthetic DayDream.app shaped like a local ad-hoc copy: Info.plist, the three executables (bytes only, never
    run), before_turn.py, Companions.json with their hashes and an empty Sparkle.framework folder."""
    app = Path(folder) / 'DayDream.app'
    contents = app / 'Contents'
    for rel, data in (('MacOS/MacMem', macmem), ('MacOS/mac-mem', b'MACHO-FIXTURE mac-mem\n'),
                      ('MacOS/mac-mem-backup', b'MACHO-FIXTURE mac-mem-backup\n'),
                      ('Resources/before_turn.py', b'# fixture\n')):
        path = contents / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        if rel.startswith('MacOS/'):
            path.chmod(0o755)
    (contents / 'Frameworks/Sparkle.framework').mkdir(parents=True, exist_ok=True)
    info = {'CFBundleIdentifier': bundle_id, 'CFBundleVersion': build, 'CFBundleShortVersionString': '0.1.8',
            'CFBundleExecutable': 'MacMem', 'CFBundleName': 'DayDream', 'SUAllowsAutomaticUpdates': False,
            'SUAutomaticallyUpdate': False, 'SUEnableAutomaticChecks': False}
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    companions = {'build': build, 'sha256': {rel: sha(contents / rel) for rel in
                                             ('MacOS/mac-mem', 'MacOS/mac-mem-backup', 'Resources/before_turn.py')}}
    (contents / 'Resources/Companions.json').write_text(json.dumps(companions, sort_keys=True) + '\n')
    return app


def bundle_id(app):
    return plistlib.loads((Path(app) / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier']


def fake_env(scratch, extra_path=()):
    """PATH with the fakes first (codesign, and whatever `extra_path` adds), and the fake's log under `scratch`."""
    log = Path(scratch) / 'codesign.log'
    env = dict(os.environ)
    env['PATH'] = os.pathsep.join([str(p) for p in extra_path] + [str(FAKES), env.get('PATH', '/usr/bin:/bin')])
    env['REALISM_CODESIGN_LOG'] = str(log)
    env['PYTHONDONTWRITEBYTECODE'] = '1'
    return env, log


def signings(log):
    """Every --sign the fake saw: (identity, bundle ID at that moment, target)."""
    out = []
    if Path(log).is_file():
        for line in Path(log).read_text().splitlines():
            parts = line.split('\t')
            if parts[0] == 'sign' and len(parts) >= 4:
                out.append((parts[1].split('=', 1)[1], parts[2].split('=', 1)[1], parts[3]))
    return out


def run(argv, env, cwd=None):
    return subprocess.run([str(a) for a in argv], env=env, cwd=cwd, capture_output=True, text=True)
