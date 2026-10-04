#!/usr/bin/env python3
"""perm-1004: test copies look different, and ad-hoc copies never borrow a real bundle ID.

1. Icons (owner 10/3: "about 4 DayDreams everywhere"): the Live Test and QA copies get the public icon with an orange
   TEST / QA label (packaging/Daydream-TEST.icns, packaging/Daydream-QA.icns), installed by the stage, not app logic.
   The public icon is byte-for-byte unchanged.
2. Ad-hoc IDs (tccd 10/3): an ad-hoc build run under com.getnorthlight.daydream.livetest on 9/29 left privacy rows
   holding its cdhash; the Developer ID copy could never match them. Every ad-hoc seal renames the bundle ID to
   <id>.adhoc before signing, and the repo has no other ad-hoc signing site.

No signing, launch, permission read or System Settings.
"""
import hashlib, importlib.util, re, subprocess, sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location('developer_id_release', SCRIPTS / 'developer-id-release.py')
dr = importlib.util.module_from_spec(spec); sys.modules['developer_id_release'] = dr; spec.loader.exec_module(dr)

PUBLIC_ICON_SHA256 = '14d8816a03f0c1d093055812d69b3399f17044e0b310303c4c1eff87c0988983'
passed = failed = 0
def check(ok, label, detail=''):
    global passed, failed
    if ok:
        passed += 1; print('PASS', label)
    else:
        failed += 1; print('FAIL', label, detail)

def chunks(data):
    """The icns chunk types (one per size)."""
    if data[:4] != b'icns' or int.from_bytes(data[4:8], 'big') != len(data):
        return None
    out, i = [], 8
    while i < len(data):
        kind, size = data[i:i + 4], int.from_bytes(data[i + 4:i + 8], 'big')
        if size < 8:
            return None
        out.append(kind); i += size
    return out

# 1. Icons
public = (ROOT / 'packaging/Daydream.icns').read_bytes()
check(hashlib.sha256(public).hexdigest() == PUBLIC_ICON_SHA256, 'the public icon is unchanged')
public_kinds = chunks(public)
check(public_kinds is not None, 'the public icon is a valid icns')
badged = {}
for badge, rel in sorted(dr.ICON_BADGES.items()):
    path = ROOT / rel
    data = path.read_bytes() if path.is_file() else b''
    badged[badge] = data
    kinds = chunks(data)
    check(kinds is not None and len(data) > 100_000, '%s icon is a valid icns (%s)' % (badge, rel), str(len(data)))
    check(kinds is not None and set(public_kinds or []) <= set(kinds), '%s icon has every size the public icon has' % badge)
    check(data != public, '%s icon differs from the public icon' % badge)
check(badged.get('TEST') != badged.get('QA'), 'the TEST and QA icons differ')
check(dr.icon_badge({}) is None, 'a public release: no badge')
check(dr.icon_badge({dr.OWNER_PLIST_KEY: True}) is None, 'an owner build alone: no badge (the public icon)')
check(dr.icon_badge({dr.LIVE_TEST_PLIST_KEY: True}) == 'TEST', 'the Live Test copy: TEST')
check(dr.icon_badge({dr.QA_PLIST_KEY: True}) == 'QA', 'a QA copy: QA')
check(dr.icon_badge({dr.QA_PLIST_KEY: True, dr.LIVE_TEST_PLIST_KEY: True}) == 'QA', 'QA wins over TEST')
check(dr.icon_problems({}, public, ROOT) == [], 'a public stage with the public icon passes')
check(dr.icon_problems({}, badged['TEST'], ROOT) != [], 'a public stage with a badged icon is refused')
check(dr.icon_problems({dr.LIVE_TEST_PLIST_KEY: True}, public, ROOT) != [], 'a Live Test stage with the public icon is refused')
check(dr.icon_problems({dr.LIVE_TEST_PLIST_KEY: True}, badged['TEST'], ROOT) == [], 'a Live Test stage with the TEST icon passes')
check(dr.icon_problems({dr.QA_PLIST_KEY: True}, badged['QA'], ROOT) == [], 'a QA stage with the QA icon passes')
stage = (SCRIPTS / 'developer-id-release.py').read_text()
check("install_file(source / ICON_BADGES[badge], resources / 'Daydream.icns', 0o644)" in stage
      and 'problems += icon_problems(info,' in stage, 'the stage installs the badged icon and audits it')
check(stage.index('install_file(source / ICON_BADGES[badge]') < stage.index('release.manifest(target'),
      'the icon is installed before the manifest and any signing')
check(not re.search(r'Daydream-(TEST|QA)', ''.join(p.read_text() for p in (ROOT / 'Sources').rglob('*.swift'))),
      'the app code never picks an icon (packaging only)')

# 2. Ad-hoc IDs
seal = (SCRIPTS / 'seal-local-app.sh').read_text()
rewrite = seal.find('plutil -replace CFBundleIdentifier -string "$bundle_id.adhoc"')
sign = seal.find('codesign --force --sign -')
check(rewrite != -1 and sign != -1 and rewrite < sign, 'the ad-hoc seal renames the bundle ID to <id>.adhoc before signing')
check("*.adhoc) ;;" in seal and "Refusing: no CFBundleIdentifier" in seal, 'never <id>.adhoc.adhoc; no ID refuses')
sites = subprocess.run(['git', 'grep', '-nE', '-e', r"--sign[ =]+-( |$|\")|'--sign', '-'|\"--sign\", \"-\"|codesign -s -", '--',
                        '*.sh', '*.py', '*.swift', ':!scripts/check_*.py', ':!scripts/test-copy-identity-checks.py'],
                       cwd=ROOT, capture_output=True, text=True)
lines = [l for l in sites.stdout.splitlines() if l]
check(sites.returncode in (0, 1) and [l.split(':')[0] for l in lines] == ['scripts/seal-local-app.sh'],
      'the ad-hoc seal is the only ad-hoc signing site', '\n'.join(lines))
for name in ['check_dmg.py', 'check_package.py', 'stage-local-ui-update.py', 'preview/build-preview-app.sh']:
    text = (SCRIPTS / name).read_text()
    check('.adhoc' in text, '%s knows the .adhoc ID' % name)

print('test-copy-identity-checks: %d passed, %d failed' % (passed, failed))
sys.exit(1 if failed else 0)
