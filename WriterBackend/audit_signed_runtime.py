#!/usr/bin/env python3
"""Independent audit of a signed "On this Mac" runtime set (plan step 5), before or after pinning it.

    python3 WriterBackend/audit_signed_runtime.py SIGNED_DIR PREPARED_DIR [--not-pinned-yet]

SIGNED_DIR holds exactly <ID>.json and the seven signed dylibs (sign-runtime.sh output, or the committed
packaging/WriterRuntime/<ID>/). PREPARED_DIR is the prepare_writer_macos15.py folder they were signed from.

Checks every file with the system tools, not with the repository's own parsers alone:
  - the manifest: exact pin in SignedRuntimePolicy.swift (or, with --not-pinned-yet, every other field),
    schema, IDs, archive, team, leaf, upstream pins and identifiers (scripts/writer_payload.py);
  - each dylib: bytes and size equal the manifest; codesign --verify --strict with the Developer ID +
    team requirement; identifier, team, Developer ID Application authority, secure timestamp, runtime
    flag and no ad hoc flag; no entitlements; leaf certificate DER SHA-256; arm64 only; minos 15.0;
    otool -L references only @loader_path siblings or system libraries; LC_RPATH only @loader_path;
    and the loader's own Mach-O rule;
  - the signed bytes came from the prepared copy: the prepared copy is what signing-inputs.json and the
    upstream pins say (runtime_distribution.check_prepared).
It reads files only; it never signs, loads or contacts the network. No revocation claim is made.
"""
import argparse
import hashlib
import plistlib
import re
import subprocess
import sys
import json
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
sys.path.insert(0, str(ROOT / 'WriterBackend'))
import writer_payload as w  # noqa: E402
import runtime_distribution  # noqa: E402

REQUIREMENT = ('anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and '
               'certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "%s"'
               % w.TEAM_ID)


def run(*args):
    return subprocess.run(args, check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def audit(signed, prepared, not_pinned_yet=False):
    problems = []
    signed, prepared = Path(signed), Path(prepared)
    try:
        runtime_distribution.check_prepared(prepared)
    except (ValueError, OSError) as error:
        return ['prepared folder: %s' % error]
    inputs = {row['name']: row for row in json.loads((prepared / 'signing-inputs.json').read_bytes())['files']}
    manifest_path = signed / w.MANIFEST_NAME
    if manifest_path.is_symlink() or not manifest_path.is_file():
        return ['missing %s' % manifest_path]
    raw = manifest_path.read_bytes()
    pins = w.load_pins()
    if not_pinned_yet:
        pins = dict(pins, approved={w.ID: hashlib.sha256(raw).hexdigest()})
    problems += ['manifest: ' + p for p in w.manifest_problems(raw, pins)]
    if problems:
        return problems
    rows = {row['name']: row for row in json.loads(raw)['files']}
    present = {p.name for p in signed.iterdir()}
    if present != set(rows) | {w.MANIFEST_NAME}:
        return ['%s holds %s, expected the manifest and the seven libraries' % (signed, sorted(present))]
    leaves = set()
    with tempfile.TemporaryDirectory(prefix='writer-audit-') as tmp:
        for name, row in sorted(rows.items()):
            p = signed / name
            data = p.read_bytes()
            if p.is_symlink() or not p.is_file():
                problems.append('%s: not a regular file' % name); continue
            if hashlib.sha256(data).hexdigest() != row['signedSHA256'] or len(data) != row['signedBytes']:
                problems.append('%s: bytes differ from the manifest' % name)
            if row['upstreamSHA256'] != inputs[name]['upstreamSHA256']:
                problems.append('%s: upstream pin differs from signing-inputs.json' % name)
            if row['signingIdentifier'] != inputs[name]['signingIdentifier']:
                problems.append('%s: identifier differs from signing-inputs.json' % name)
            problems += ['%s: %s' % (name, x) for x in w.macho_problems(data, set(rows))]
            verify = run('/usr/bin/codesign', '--verify', '--strict', '-R=' + REQUIREMENT, str(p))
            if verify.returncode:
                problems.append('%s: codesign --verify --strict with the Developer ID + team requirement failed: %s'
                                % (name, verify.stderr.decode(errors='replace').strip()))
                continue
            detail = run('/usr/bin/codesign', '-d', '--verbose=4', str(p)).stderr.decode(errors='replace')
            lines = detail.splitlines()
            authorities = [line for line in lines if line.startswith('Authority=')]
            for ok, what in (
                    ('Identifier=%s' % row['signingIdentifier'] in lines, 'identifier'),
                    ('TeamIdentifier=%s' % w.TEAM_ID in lines, 'team'),
                    (bool(authorities) and authorities[0].startswith('Authority=Developer ID Application:'), 'Developer ID Application leaf'),
                    (any(line.startswith('Timestamp=') for line in lines), 'secure timestamp'),
                    (any(line.startswith('CodeDirectory ') and re.search(r'flags=0x[0-9a-f]+\([^)]*runtime', line) for line in lines), 'hardened runtime flag'),
                    (not any('adhoc' in line for line in lines if line.startswith(('CodeDirectory ', 'Signature='))), 'not ad hoc')):
                if not ok:
                    problems.append('%s: %s check failed' % (name, what))
            ents = run('/usr/bin/codesign', '-d', '--entitlements', ':-', str(p)).stdout
            try:
                if ents.strip() and plistlib.loads(ents) != {}:
                    problems.append('%s: has entitlements' % name)
            except Exception:
                problems.append('%s: unreadable entitlements' % name)
            prefix = str(Path(tmp) / name) + '.'
            run('/usr/bin/codesign', '-d', '--extract-certificates=' + prefix, str(p))
            leaf = Path(prefix + '0')
            if not leaf.is_file() or sha(leaf) != w.LEAF_SHA256:
                problems.append('%s: leaf certificate is not %s' % (name, w.LEAF_SHA256))
            else:
                leaves.add(sha(leaf))
            if run('/usr/bin/lipo', '-archs', str(p)).stdout.strip() != b'arm64':
                problems.append('%s: not arm64 only' % name)
            commands = run('/usr/bin/otool', '-l', str(p)).stdout.decode(errors='replace').splitlines()
            if not any(line.strip() == 'minos 15.0' for line in commands):
                problems.append('%s: minimum macOS is not 15.0' % name)
            for i, line in enumerate(commands):
                if line.strip() == 'cmd LC_RPATH' and commands[i + 2].strip().split()[1] != '@loader_path':
                    problems.append('%s: LC_RPATH is not @loader_path' % name)
            for dep in run('/usr/bin/otool', '-L', str(p)).stdout.decode(errors='replace').splitlines()[1:]:
                dep = dep.strip().split(' (')[0]
                if not (dep in ['@loader_path/' + n for n in rows]
                        or (dep.startswith(('/usr/lib/', '/System/Library/Frameworks/')) and '..' not in dep)):
                    problems.append('%s: dependency %s' % (name, dep))
    if len(leaves) > 1:
        problems.append('the libraries use different certificates')
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('signed')
    parser.add_argument('prepared')
    parser.add_argument('--not-pinned-yet', action='store_true',
                        help='check everything except the compiled pin (before the one-line pin change)')
    args = parser.parse_args()
    problems = audit(args.signed, args.prepared, args.not_pinned_yet)
    manifest = Path(args.signed) / w.MANIFEST_NAME
    if problems:
        print('REFUSED:\n  ' + '\n  '.join(problems), file=sys.stderr)
        return 1
    print('PASS %s: seven strict Developer ID seals (team %s, leaf %s), no entitlements, byte pins, arm64/minos 15.0, '
          '@loader_path/system dependencies only. Manifest SHA-256 %s%s. No load, no network, no revocation claim.'
          % (w.ID, w.TEAM_ID, w.LEAF_SHA256, sha(manifest), ' (not pinned yet)' if args.not_pinned_yet else ' (pinned)'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
