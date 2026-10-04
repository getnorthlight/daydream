"""Exact functional-trial payload policy. No key use or runtime execution.

The PRIVATE same-owner trial only: Typesense, its search hashes, FunctionalTrial.json and the
2026-09-14 enrolled writer set. The public "On this Mac" runtime that every release carries is
writer_payload.py; this policy applies only to an app that has one of the trial's own pieces.
"""
import hashlib
import json
import search_payload
from pathlib import Path
ID = 'daydream-qwen35-b9723-macos15-20260914'
MANIFEST_HASH = 'f96202ce0b1d60476d0b80c588278c9d8abf65afacfb29a52e6b0b5973b847a9'
MANIFEST = 'Resources/WriterRuntime/' + ID + '.json'
LIBROOT = 'Frameworks/WriterRuntime/' + ID + '/'
SERVER = 'Helpers/typesense-server'
SEARCH = 'Resources/typesense-runtime-v1.json'
TRIAL = 'Resources/FunctionalTrial.json'
NOTICES = {'Resources/Typesense-LICENSE.txt', 'Resources/Typesense-NOTICES.txt', 'Resources/WriterRuntime-LICENSE.txt', TRIAL}

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1048576), b''): h.update(chunk)
    return h.hexdigest()

def require(ok, message):
    if not ok: raise ValueError(message)

def paths(app):
    c = app / 'Contents'
    if search_payload.present(app):
        require(not (c / MANIFEST).exists() and not (c / TRIAL).exists(), 'Do not mix local search with legacy enrolled trial')
        search_payload.paths(app)
        return set()
    # Only the trial's own pieces make an app a trial. A writer runtime alone is writer_payload.py's.
    if not any((c / p).exists() or (c / p).is_symlink() for p in (MANIFEST, SERVER, SEARCH, TRIAL)): return set()
    m = c / MANIFEST
    require(m.is_file() and not m.is_symlink() and digest(m) == MANIFEST_HASH, 'Missing/unreviewed enrolled writer manifest')
    data = json.loads(m.read_text())
    names = {row['name'] for row in data['files']}
    require(len(names) == 7 and all(Path(n).name == n for n in names), 'Invalid writer file set')
    directory = c / LIBROOT
    require(directory.is_dir() and set(p.name for p in directory.iterdir()) == names, 'Writer payload differs from enrolled set')
    for row in data['files']:
        p = directory / row['name']
        require(p.is_file() and not p.is_symlink() and p.stat().st_size == row['signedBytes'] and digest(p) == row['signedSHA256'], 'Enrolled writer bytes changed: ' + row['name'])
    allowed = {MANIFEST, SERVER, SEARCH, *NOTICES, *(LIBROOT + n for n in names)}
    for name in allowed:
        p = c / name
        require(p.is_file() and not p.is_symlink() and p.resolve() == p.absolute() and not p.stat().st_mode & 0o022, 'Missing/unsafe functional payload: ' + name)
    trial = json.loads((c/'Resources/FunctionalTrial.json').read_text())
    require(trial.get('scope') == 'private-same-owner-self-use' and trial.get('publicDistribution') is False
            and trial.get('completeCorrespondingSource') is False, 'Wrong private-trial scope')
    return allowed

def refresh(app):
    c = app / 'Contents'
    if search_payload.present(app):
        return
    if (c / SERVER).exists():
        require(not (c/'_CodeSignature').exists(), 'Cannot refresh sealed functional app')
        (c / SEARCH).write_text(json.dumps({'version': 1, 'serverSHA256': digest(c / SERVER), 'supervisorSHA256': digest(c / 'MacOS/mac-mem')}, sort_keys=True) + '\n')

def verify_search(app):
    c = app / 'Contents'
    if paths(app):
        require(json.loads((c / SEARCH).read_text()) == {'version': 1, 'serverSHA256': digest(c / SERVER), 'supervisorSHA256': digest(c / 'MacOS/mac-mem')}, 'Stale final search hashes')
