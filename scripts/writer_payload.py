"""The "On this Mac" runtime inside DayDream.app: one manifest and the seven signed llama.cpp
libraries, nothing else. Reads files only: no signing, no key use, nothing is run.

Public and owner builds both carry it (owner decision 2026-09-26). The private Typesense trial
(functional_payload.py) is a separate policy and stays private.

Where it comes from: packaging/WriterRuntime/<ID>/ in the commit being staged. The owner signs the
seven prepared libraries once (RELEASE.md section 7); the signed set and its manifest are committed
there and reused unchanged by every release.

Where it goes in the app (WriterBackend/Sources/WriterBackend/WriterRuntimeAdmission.swift):
  Contents/Resources/WriterRuntime/<ID>.json     the manifest
  Contents/Frameworks/WriterRuntime/<ID>/<name>  the seven dylibs, byte for byte, never re-signed
  Info.plist DaydreamWriterRuntimeDistribution=<ID>

The manifest's SHA-256 must equal approvedManifestSHA256[<ID>] compiled into the same commit's
SignedRuntimePolicy.swift, and every other field must match the pins the loader checks, so a stage
never ships a runtime the app itself would refuse.
"""
import hashlib
import json
import plistlib
import re
import stat
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# The signed distribution. A new signed set (a llama.cpp update or a new certificate) gets a new ID.
ID = 'daydream-qwen35-b9723-macos15-v2'
INFO_KEY = 'DaydreamWriterRuntimeDistribution'
SOURCE_DIR = 'packaging/WriterRuntime/' + ID
MANIFEST_NAME = ID + '.json'
MANIFEST = 'Resources/WriterRuntime/' + MANIFEST_NAME
LIBROOT = 'Frameworks/WriterRuntime/' + ID + '/'
POLICY = 'WriterBackend/Sources/WriterBackend/SignedRuntimePolicy.swift'
RUNTIME = 'WriterBackend/Sources/WriterBackend/MacOS15Runtime.swift'
TEAM_ID = 'L76C3ZC66J'
# DER SHA-256 of the Developer ID Application leaf certificate that signs the app and the runtime.
# The loader requires the host app and all seven libraries to share the manifest's certificate.
LEAF_SHA256 = '4b87cd4e80280eb7a2fc8dee7d50bf5fb534f6f73f172343bc16dcfe36a1a9af'
IDENTIFIER_PREFIX = 'com.getnorthlight.daydream.writer.'
MAX_MANIFEST_BYTES = 32_768  # RuntimeManifestReader.swift
MAX_LIBRARY_BYTES = 32_000_000  # SignedRuntimeLoader.swift
NOT_SIGNED = ('writer runtime not signed yet: this commit has no %s/ (the signed libraries and their '
              'manifest). Sign them once (RELEASE.md, "Writer runtime"), commit them there and pin the manifest, '
              'or pass --without-writer-runtime-for-tests for a test build that can never be released.' % SOURCE_DIR)


class NotSigned(ValueError):
    """The commit has no signed runtime yet."""


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest_bytes(data):
    return hashlib.sha256(data).hexdigest()


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def signing_identifier(name):
    """The code-signing identifier of one library: com.getnorthlight.daydream.writer.libllama.0"""
    return IDENTIFIER_PREFIX + name.removesuffix('.dylib')


def _strip_swift_comments(text):
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return re.sub(r'//[^\n]*', '', text)


PIN_PAIR = r'"([A-Za-z0-9_-]{1,96})"\s*:\s*"([0-9a-f]{64})"'


def policy_pins(text):
    """approvedManifestSHA256 from SignedRuntimePolicy.swift source: {distribution ID: manifest SHA-256}."""
    code = _strip_swift_comments(text)
    found = re.findall(r'static\s+let\s+approvedManifestSHA256\s*:\s*\[String\s*:\s*String\]\s*=\s*\[(.*?)\]', code, re.S)
    require(len(found) == 1, 'Could not read approvedManifestSHA256 from ' + POLICY)
    body = found[0]
    pairs = re.findall(PIN_PAIR, body)
    require(not re.sub(PIN_PAIR, '', body).strip(' ,\n\t\r'), 'Unreadable approvedManifestSHA256 entry in ' + POLICY)
    require(len({key for key, _ in pairs}) == len(pairs), 'Duplicate approvedManifestSHA256 entry in ' + POLICY)
    return dict(pairs)


def runtime_pins(text):
    """The unsigned library pins, archive hash and signed schema from MacOS15Runtime.swift source."""
    code = _strip_swift_comments(text)
    rows = re.findall(r'\("([^"/]+\.dylib)",(\d+),"([a-f0-9]{64})"\)', code)
    archive = re.findall(r'static\s+let\s+archiveSHA256\s*=\s*"([0-9a-f]{64})"', code)
    schema = re.findall(r'static\s+let\s+signedSchema\s*=\s*"([^"]+)"', code)
    require(len(rows) == 7 and len({name for name, _, _ in rows}) == 7 and len(archive) == 1 and len(schema) == 1,
            'Could not read the seven library pins, archiveSHA256 and signedSchema from ' + RUNTIME)
    return {'files': {name: (int(size), sha) for name, size, sha in rows}, 'archive': archive[0], 'schema': schema[0]}


def load_pins(root=None):
    """Pins from a checkout or an extracted commit (default: this script's own checkout)."""
    root = Path(root or ROOT)
    return {'approved': policy_pins((root / POLICY).read_text()), **runtime_pins((root / RUNTIME).read_text())}


def _strict_json(raw):
    def pairs(items):
        keys = [key for key, _ in items]
        require(len(keys) == len(set(keys)), 'Duplicate key in the writer manifest')
        return dict(items)

    def depth(value, level=0):
        require(level <= 8, 'Writer manifest nests too deeply')
        children = value.values() if isinstance(value, dict) else value if isinstance(value, list) else ()
        for child in children:
            depth(child, level + 1)

    value = json.loads(raw.decode('utf-8'), object_pairs_hook=pairs)
    depth(value)
    return value


def _hex(value):
    return isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value) is not None


def manifest_problems(raw, pins, distribution_id=ID):
    """Problems with manifest bytes: the compiled pin first, then every field the loader checks."""
    pin = pins['approved'].get(distribution_id)
    if pin is None:
        return ['writer runtime %s is not pinned: %s has no approvedManifestSHA256 entry for it' % (distribution_id, POLICY)]
    actual = digest_bytes(raw)
    if actual != pin:
        return ['writer manifest SHA-256 %s does not match the pin %s compiled into %s' % (actual, pin, POLICY)]
    if not 0 < len(raw) <= MAX_MANIFEST_BYTES:
        return ['writer manifest size %d is out of bounds' % len(raw)]
    try:
        data = _strict_json(raw)
    except (ValueError, UnicodeDecodeError) as error:
        return ['writer manifest unreadable: %s' % error]
    if not isinstance(data, dict):
        return ['writer manifest is not an object']
    problems = []
    for key, expected in (('schema', pins['schema']), ('distributionID', distribution_id),
                          ('upstreamArchiveSHA256', pins['archive']), ('teamID', TEAM_ID),
                          ('certificateSHA256', LEAF_SHA256)):
        if data.get(key) != expected:
            problems.append('writer manifest %s is %r, expected %r' % (key, data.get(key), expected))
    files = data.get('files')
    if not isinstance(files, list) or not all(isinstance(row, dict) for row in files):
        return problems + ['writer manifest files is not a list of objects']
    names = [row.get('name') for row in files]
    if len(names) != len(set(names)) or set(names) != set(pins['files']):
        return problems + ['writer manifest names %s are not the seven pinned libraries' % sorted(map(str, names))]
    for row in files:
        name = row['name']
        size = row.get('signedBytes')
        if row.get('upstreamSHA256') != pins['files'][name][1]:
            problems.append('%s: upstreamSHA256 is not the MacOS15Runtime pin' % name)
        if not _hex(row.get('signedSHA256')) or row.get('signedSHA256') == row.get('upstreamSHA256'):
            problems.append('%s: signedSHA256 missing or unsigned' % name)
        if type(size) is not int or not 0 < size <= MAX_LIBRARY_BYTES:
            problems.append('%s: signedBytes out of bounds' % name)
        if row.get('signingIdentifier') != signing_identifier(name):
            problems.append('%s: signingIdentifier %r != %r' % (name, row.get('signingIdentifier'), signing_identifier(name)))
    return problems


# ---------------------------------------------------------------- Mach-O (port of RuntimeMachO in SignedRuntimeLoader.swift)
LC_ID_DYLIB = 0xd
LC_RPATH = 0x8000001c
PATH_COMMANDS = (0xc, LC_ID_DYLIB, 0x80000018, 0x8000001f, 0x20, 0x80000023, LC_RPATH)
FORBIDDEN_COMMANDS = (0x27, 0xe)  # LC_DYLD_ENVIRONMENT, LC_LOAD_DYLINKER


def macho_problems(data, allowed):
    """The loader's own rule for a signed library: thin arm64 MH_DYLIB, sibling references through
    @loader_path/ only, system libraries by absolute path, and @loader_path as the only rpath."""
    def word(offset):
        require(0 <= offset and offset + 4 <= len(data), 'truncated')
        return int.from_bytes(data[offset:offset + 4], 'little')
    try:
        if word(0) != 0xfeedfacf or word(4) != 0x0100000C or word(12) != 6:
            return ['not a thin arm64 dylib']
        count, end = word(16), 32 + word(20)
        if count > 256 or end > len(data):
            return ['load commands out of bounds']
        cursor, has_loader, needs_loader, problems = 32, False, False, []
        for _ in range(count):
            command, size = word(cursor), word(cursor + 4)
            if size < 8 or size % 4 or cursor + size > end:
                return ['bad load command size']
            if command in FORBIDDEN_COMMANDS:
                problems.append('forbidden load command 0x%x' % command)
            if command in PATH_COMMANDS:
                offset = word(cursor + 8)
                if offset < 12 or offset >= size:
                    return ['bad load command path offset']
                raw = data[cursor + offset:cursor + size]
                nul = raw.find(b'\0')
                if nul < 0:
                    return ['unterminated load command path']
                path = raw[:nul].decode('utf-8')
                if command == LC_RPATH:
                    if path != '@loader_path':
                        problems.append('rpath %s (only @loader_path is allowed)' % path)
                    has_loader = True
                else:
                    local = path.startswith('@rpath/') and path[7:] in allowed
                    loader = path.startswith('@loader_path/') and path[13:] in allowed
                    system = path.startswith(('/usr/lib/', '/System/Library/Frameworks/')) and '..' not in path
                    if not ((local and command == LC_ID_DYLIB) or loader or system):
                        problems.append('dependency %s (siblings must be @loader_path/)' % path)
                    if local and command != LC_ID_DYLIB:
                        needs_loader = True
            cursor += size
        if cursor != end or (needs_loader and not has_loader):
            problems.append('load command layout')
        return problems
    except (ValueError, UnicodeDecodeError):
        return ['unreadable Mach-O']


# ---------------------------------------------------------------- the committed signed set
def _regular(path, what, inside):
    """A regular file, with no symlink anywhere between `inside` and it."""
    require(path.is_file() and not path.is_symlink()
            and path.resolve() == Path(inside).resolve() / path.relative_to(inside), 'Missing or linked ' + what)


def source_present(root):
    """Whether the commit (a clean checkout or an extracted archive at `root`) has the signed set."""
    folder = Path(root) / SOURCE_DIR
    return folder.exists() or folder.is_symlink()


def source_files(root, pins=None):
    """Checks packaging/WriterRuntime/<ID>/ in `root` against the pins of the same tree.

    Returns (manifest path, [(name, path, manifest row)]). Raises NotSigned when the folder is absent
    and ValueError on anything else. Signatures are checked by the caller (codesign)."""
    root = Path(root)
    if not source_present(root):
        raise NotSigned(NOT_SIGNED)
    folder = root / SOURCE_DIR
    require(folder.is_dir() and not folder.is_symlink(), 'Not a folder: ' + SOURCE_DIR)
    parent = folder.parent
    require(sorted(p.name for p in parent.iterdir()) == [ID],
            'packaging/WriterRuntime/ must hold only %s/ (found %s)' % (ID, sorted(p.name for p in parent.iterdir())))
    pins = pins or load_pins(root)
    manifest = folder / MANIFEST_NAME
    _regular(manifest, SOURCE_DIR + '/' + MANIFEST_NAME, root)
    raw = manifest.read_bytes()
    problems = manifest_problems(raw, pins)
    require(not problems, 'Writer runtime refused: ' + '; '.join(problems))
    rows = json.loads(raw)['files']
    names = {row['name'] for row in rows}
    found = {p.name for p in folder.iterdir()}
    require(found == names | {MANIFEST_NAME}, 'Files in %s differ from the manifest (extra or missing: %s)'
            % (SOURCE_DIR, sorted(found ^ (names | {MANIFEST_NAME}))))
    result = []
    for row in rows:
        path = folder / row['name']
        _regular(path, SOURCE_DIR + '/' + row['name'], root)
        data = path.read_bytes()
        require(len(data) == row['signedBytes'] and digest_bytes(data) == row['signedSHA256'],
                'Signed library bytes differ from the manifest: ' + row['name'])
        bad = macho_problems(data, names)
        require(not bad, '%s would be refused by the loader: %s' % (row['name'], '; '.join(bad)))
        result.append((row['name'], path, row))
    return manifest, result


# ---------------------------------------------------------------- inside an app
def _info(app):
    path = Path(app) / 'Contents/Info.plist'
    if not path.is_file():
        return {}
    try:
        return plistlib.loads(path.read_bytes())
    except (plistlib.InvalidFileException, ValueError) as error:
        raise ValueError('Unreadable Info.plist: %s' % error)


def present(app):
    """Whether `app` carries (any part of) a writer runtime outside the private trial."""
    c = Path(app) / 'Contents'
    if (c / 'Resources/FunctionalTrial.json').exists():
        return False
    return (INFO_KEY in _info(app) or any((c / p).exists() or (c / p).is_symlink()
                                          for p in ('Resources/WriterRuntime', 'Frameworks/WriterRuntime')))


def paths(app, pins=None):
    """Relative paths (to Contents) of the runtime inside `app`, fully checked; empty when the app has
    none. The private trial (Resources/FunctionalTrial.json) is functional_payload.py's, never this."""
    app = Path(app)
    if not present(app):
        return set()
    c = app / 'Contents'
    require(_info(app).get(INFO_KEY) == ID, 'Writer runtime needs Info.plist %s=%s' % (INFO_KEY, ID))
    for folder, expected in (('Resources/WriterRuntime', [MANIFEST_NAME]), ('Frameworks/WriterRuntime', [ID])):
        path = c / folder
        require(path.is_dir() and not path.is_symlink() and sorted(p.name for p in path.iterdir()) == expected,
                'Contents/%s must hold exactly %s' % (folder, expected))
    manifest = c / MANIFEST
    _regular(manifest, 'writer manifest', app)
    raw = manifest.read_bytes()
    problems = manifest_problems(raw, pins or load_pins())
    require(not problems, 'Writer runtime refused: ' + '; '.join(problems))
    rows = json.loads(raw)['files']
    names = {row['name'] for row in rows}
    directory = c / LIBROOT
    require(directory.is_dir() and not directory.is_symlink() and {p.name for p in directory.iterdir()} == names,
            'Writer libraries differ from the manifest set')
    for row in rows:
        path = directory / row['name']
        _regular(path, 'writer library ' + row['name'], app)
        require(path.stat().st_size == row['signedBytes'] and digest(path) == row['signedSHA256'],
                'Signed writer bytes changed: ' + row['name'])
    allowed = {MANIFEST, *(LIBROOT + name for name in names)}
    for name in allowed:
        mode = (c / name).stat().st_mode
        require(not mode & (stat.S_IWGRP | stat.S_IWOTH), 'Writer file is group or world writable: ' + name)
    return allowed


def libraries(app):
    """The seven library paths relative to the app (Contents/...), sorted."""
    return sorted('Contents/' + name for name in paths(app) if name.startswith(LIBROOT))
