"""Non-launch regression checks against a disposable copy of an existing app."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent

def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True)

def inventory(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file() and not p.is_symlink()}

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path)
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='macmem-seal-regression-') as work:
    app = Path(work) / 'DayDream.app'
    run('ditto', str(args.app), str(app))
    framework = app / 'Contents/Frameworks/Sparkle.framework'
    before = inventory(framework)
    companions = (app / 'Contents/Resources/Companions.json').read_bytes()
    run('bash', str(ROOT / 'seal-local-app.sh'), str(app))
    assert before == inventory(framework), 'Vendor signature or framework changed'
    assert companions == (app / 'Contents/Resources/Companions.json').read_bytes()
    run('python3', str(ROOT / 'verify-app-companions.py'), str(app))
    copied = Path(work) / 'Copied.app'
    run('ditto', str(app), str(copied))
    run('codesign', '--verify', '--deep', '--strict', str(copied))
    # Corrupt only this disposable fixture, never the supplied app.
    with (copied / 'Contents/Resources/THIRD-PARTY-NOTICES.md').open('ab') as stream:
        stream.write(b'\nsynthetic tamper\n')
    result = subprocess.run(['codesign', '--verify', '--deep', '--strict', str(copied)],
                            capture_output=True, text=True)
    assert result.returncode != 0, 'Resource tampering was accepted'
print('PASS: final seal, unchanged vendor bytes, companion hashes, copied seal, resource tamper rejection. No launch.')
