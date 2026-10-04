"""Mount read-only, inspect and copy to an isolated temporary location.
Never install, request permissions, start capture or bypass Gatekeeper.

Usage: check_dmg.py [NAME_IN_dist/ | PATH/TO.dmg] [--expect-developer-id [--apple-events]]
       [--updates off|configured] [--launch-isolated]
--updates defaults to configured with --expect-developer-id (a release) and off otherwise.
A release image must be named DayDream-<x.y.z>.dmg and have a matching <dmg>.sha256 taken
after stapling. The copied app is launched ONLY with --launch-isolated (a notarized image
always passes Gatekeeper, so acceptance alone must never trigger a launch).
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import sys

ROOT=Path(__file__).resolve().parents[1]
TEAM_REQUIREMENT='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "L76C3ZC66J"'
FLAGS={'--launch-isolated','--expect-developer-id','--apple-events'}
argv=sys.argv[1:]
updates='configured' if '--expect-developer-id' in argv else 'off'
if '--updates' in argv:
    at=argv.index('--updates')
    assert at+1<len(argv) and argv[at+1] in ('off','configured'), '--updates expects off or configured'
    updates=argv[at+1]
    del argv[at:at+2]
flags={a for a in argv if a.startswith('--')}
assert flags<=FLAGS, 'Unknown flag: '+', '.join(sorted(flags-FLAGS))
launch='--launch-isolated' in flags
developer_id='--expect-developer-id' in flags
positional=[a for a in argv if not a.startswith('--')]
name=positional[0] if positional else 'Daydream-GUI-Trial-unsigned.dmg'
if '/' in name:
    artifact=Path(name).absolute()
    assert artifact.name.endswith('.dmg') and artifact.is_file()
else:
    assert Path(name).name==name and name.endswith('.dmg')
    artifact=ROOT/'dist'/name
def run(*args):
    return subprocess.run(args,check=True,capture_output=True,text=True).stdout
import importlib.util
spec=importlib.util.spec_from_file_location('developer_id_release',Path(__file__).with_name('developer-id-release.py'))
pipeline=importlib.util.module_from_spec(spec);spec.loader.exec_module(pipeline)

run('hdiutil','verify',str(artifact))
if developer_id:
    run('codesign','--verify','--strict','-R='+TEAM_REQUIREMENT,str(artifact))
    run('xcrun','stapler','validate',str(artifact))
    image=subprocess.run(['spctl','--assess','--type','open','--context','context:primary-signature','--verbose=4',str(artifact)],capture_output=True,text=True)
    assert image.returncode==0 and 'Notarized Developer ID' in image.stdout+image.stderr, image.stdout+image.stderr
    print('PASS: image signed by Team L76C3ZC66J, stapled, Gatekeeper: Notarized Developer ID')
    # The checksum people compare with is of the stapled file (stapling changes the bytes).
    # One '<digest>  <name>' line, as the pipeline writes it; a test image's name has spaces.
    try:
        digest,listed=pipeline.read_checksum(artifact)
    except pipeline.ReleaseError as problem:
        raise AssertionError('stale or missing '+artifact.name+'.sha256: '+str(problem))
    assert listed==artifact.name and digest==hashlib.sha256(artifact.read_bytes()).hexdigest(), 'stale or missing '+artifact.name+'.sha256'
    print('PASS: '+artifact.name+'.sha256 matches the stapled image')
with tempfile.TemporaryDirectory(prefix='macmem-drag-trial-') as folder:
    temporary=Path(folder)
    mount=temporary/'volume'
    mount.mkdir()
    run('hdiutil','attach','-readonly','-nobrowse','-mountpoint',str(mount),str(artifact))
    try:
        assert {p.name for p in mount.iterdir() if not p.name.startswith('.')} == {'DayDream.app','Applications'}
        assert (mount/'Applications').is_symlink() and os.readlink(mount/'Applications') == '/Applications'
        target=temporary/'Copied location'/'DayDream.app'
        target.parent.mkdir()
        run('ditto',str(mount/'DayDream.app'),str(target))
        contents=target/'Contents'
        info=plistlib.loads((contents/'Info.plist').read_bytes())
        # perm-1004: an ad-hoc image's app carries the .adhoc ID (seal-local-app.sh); a signed one the normal ID.
        assert info['CFBundleIdentifier'] in ('com.getnorthlight.daydream', 'com.getnorthlight.daydream.adhoc'), info['CFBundleIdentifier']
        assert info['CFBundleDisplayName'] == 'DayDream'
        # Same Sparkle policy as the pipeline's sign/verify: automatic install is always off by
        # default; configured = daily checks from the GitHub Releases feed; off = no feed at all.
        problems=pipeline.update_policy_problems(info,updates)
        assert not problems, problems
        if developer_id:
            # The release name, or a test build's own name (developer-id-release.py dmg --name).
            assert artifact.name==pipeline.dmg_name(info['CFBundleShortVersionString']) or pipeline.test_dmg_name(artifact.name), artifact.name
            print('PASS: download named '+artifact.name+'; version '+info['CFBundleShortVersionString']+'; updates '+updates)
        for name in ['MacMem','mac-mem','mac-mem-backup']:
            assert os.access(contents/'MacOS'/name,os.X_OK)
        for name in ['Companions.json','before_turn.py','Daydream.icns','Sparkle-LICENSE.txt']:
            assert (contents/'Resources'/name).is_file()
        manifest=json.loads((contents/'Resources/Companions.json').read_text())
        assert manifest['version'] == info['CFBundleShortVersionString']
        assert manifest['build'] == info['CFBundleVersion']
        for name,digest in manifest['sha256'].items():
            assert not Path(name).is_absolute() and '..' not in Path(name).parts
            assert hashlib.sha256((contents/name).read_bytes()).hexdigest() == digest
        framework=contents/'Frameworks/Sparkle.framework'
        run('codesign','--verify','--deep','--strict',str(framework))
        links=run('otool','-L',str(contents/'MacOS/MacMem'))
        assert '@rpath/Sparkle.framework/Versions/B/Sparkle' in links
        assert str(ROOT) not in links
        commands=run('otool','-l',str(contents/'MacOS/MacMem'))
        assert '@executable_path/../Frameworks' in commands
        for name in ['memory.sqlite','events.jsonl','LaunchAgents','LaunchDaemons','postinstall','preinstall']:
            assert not list(target.rglob(name)), name
        print('PASS: image has only app and Applications shortcut; isolated drag-copy preserves bundle and companion paths')
        print('PASS: Sparkle helpers verify; no memory, services or installation scripts bundled')
        if developer_id:
            run('codesign','--verify','--deep','--strict','-R='+TEAM_REQUIREMENT,str(target))
            run('xcrun','stapler','validate',str(target))
            options=[a for a in ('--apple-events',) if a in flags]+['--updates',updates]
            # Per-item runtime flag, secure timestamp, team, one leaf (writer builds: the enrolled leaf), exact entitlements, no get-task-allow.
            print(run(sys.executable,'-B',str(Path(__file__).with_name('developer-id-release.py')),'verify','--app',str(target),'--expect','developer-id',*options).strip().splitlines()[-1])
        # Assessment is not overridden with xattr, ad-hoc signing or open flags.
        assessment=subprocess.run(['spctl','--assess','--type','execute','--verbose=4',str(target)],capture_output=True,text=True)
        print('GATEKEEPER:',assessment.returncode,(assessment.stdout+assessment.stderr).strip())
        if developer_id:
            assert assessment.returncode==0 and 'Notarized Developer ID' in assessment.stdout+assessment.stderr
        if assessment.returncode:
            print('PENDING: copied app launch withheld after Gatekeeper refusal; no bypass attempted')
        elif not launch:
            print('NOT LAUNCHED: Gatekeeper accepted; pass --launch-isolated to launch the copied app with isolated memory')
        else:
            memory=temporary/'isolated-memory'
            process=subprocess.Popen([str(contents/'MacOS/MacMem')],env={**os.environ,'MAC_MEM_HOME':str(memory)},stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            try:
                import time, sqlite3
                deadline=time.monotonic()+8
                while time.monotonic()<deadline and not (memory/'memory.sqlite').exists() and process.poll() is None:
                    time.sleep(.1)
                assert process.poll() is None, 'App exited during isolated launch'
                with sqlite3.connect(memory/'memory.sqlite') as db:
                    capture=json.loads(db.execute("SELECT body FROM metadata WHERE id='capture'").fetchone()[0])
                    assert capture['state'] == 'off'
                    assert db.execute('SELECT count(*) FROM records').fetchone()[0] == 0
                print('PASS: copied app launched with isolated empty memory and capture OFF; no controls invoked')
            finally:
                process.terminate()
                process.communicate(timeout=5)
    finally:
        run('hdiutil','detach',str(mount))
print('DMG SHA-256:',hashlib.sha256(artifact.read_bytes()).hexdigest())
