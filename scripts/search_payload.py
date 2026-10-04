"""Pinned Typesense payload (GPL-3.0, unmodified vendor binary). No runtime execution.

Independent of the legacy functional trial's writer enrollment. Public distribution
was approved by the owner on 2026-10-03 ("Ship typesense.") once the Complete
Corresponding Source kit existed: typesense-30.2-complete-source.tar.gz, whose
sha256 is SOURCE_KIT_SHA256 below. It is attached to every GitHub release next to
the DMG (GPLv3 section 6(d)). A distribution record that names any other kit, or
claims public distribution without complete source, is refused.
"""
import argparse
import hashlib
import json
import plistlib
import re
import shutil
import struct
from pathlib import Path

SERVER = 'Helpers/typesense-server'
RUNTIME = 'Resources/typesense-runtime-v1.json'
DISTRIBUTION = 'Resources/LocalSearchDistribution.json'
LICENSE = 'Resources/Typesense-LICENSE.txt'
NOTICES = 'Resources/Typesense-NOTICES.txt'
SOURCE_DIR = 'packaging/TypesenseRuntime'
ARCHIVE_SHA256 = '7d8d6d0c33930ad20ea23dd184250547b16615944be891b2078e8a075152fa7e'
SERVER_SHA256 = '086d498fbf0afb45091f4e28b50e803a3633daac506388a5f71e5ed90407c91f'
LICENSE_SHA256 = '8b1ba204bb69a0ade2bfcf65ef294a920f6bb361b317dba43c7ef29d96332b9b'
SOURCE_SHA256 = '98ce13b5f05b68ff280b2e4b463c9a0f3be303d2c83a1e18ffbddf90f2b19ad1'
SOURCE_COMMIT = 'd45d46baf3996d1de8bf96a87f375cfb43691560'
# The Complete Corresponding Source kit for this exact binary (launch-candidate/typesense-source-30.2/).
# Snowball's commit inside it is a best determination (README "Snowball"); the kit carries snowball's full history.
SOURCE_KIT_NAME = 'typesense-30.2-complete-source.tar.gz'
SOURCE_KIT_SHA256 = 'bf6a5eaa126c42dde00fc0a3e9256485e7b524683ff6989464f3ccb43aac4ae5'
SOURCE_KIT_BYTES = 624901777
SNOWBALL_COMMIT = 'f34fe0eebaaa2032fc806b5ff64f03f30998d86a'
PAYLOAD = {SERVER, RUNTIME, DISTRIBUTION, LICENSE, NOTICES}
TEST_ONLY_KEY = 'DaydreamTestOnlyWithoutSearchRuntime'


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1048576), b''):
            h.update(chunk)
    return h.hexdigest()


def regular(path, executable=False):
    path = Path(path)
    require(path.is_file() and not path.is_symlink() and path.resolve() == path.absolute(), 'Missing/unsafe local search file: ' + str(path))
    require(not path.stat().st_mode & 0o022, 'Writable by others: ' + str(path))
    require(not executable or path.stat().st_mode & 0o111, 'Not executable: ' + str(path))
    return path


def expected_distribution():
    return {'schema': 'daydream-local-search-payload/v1', 'runtimeVersion': '30.2',
            'architecture': 'arm64', 'minimumOS': '13.1', 'scope': 'public-unmodified-vendor-binary',
            'modified': False, 'publicDistribution': True, 'completeCorrespondingSource': True,
            'publicDistributionApproval': {'by': 'owner', 'date': '2026-10-03', 'statement': 'Ship typesense.'},
            'archiveSHA256': ARCHIVE_SHA256, 'inputServerSHA256': SERVER_SHA256,
            'sourceSHA256': SOURCE_SHA256, 'sourceCommit': SOURCE_COMMIT,
            'correspondingSource': {'name': SOURCE_KIT_NAME, 'sha256': SOURCE_KIT_SHA256, 'bytes': SOURCE_KIT_BYTES,
                                    'delivery': 'GPLv3 6(d): attached to each GitHub release next to the DMG',
                                    'snowballCommit': SNOWBALL_COMMIT, 'snowballDetermination': 'best-determination'},
            'runtimeURL': 'https://dl.typesense.org/releases/30.2/typesense-server-30.2-darwin-arm64.tar.gz',
            'sourceURL': 'https://codeload.github.com/typesense/typesense/tar.gz/refs/tags/v30.2'}


def public_cleared(record):
    """A record clears public distribution (and so updates-on builds) only when it claims public distribution
    WITH complete corresponding source, names this commit's reviewed kit by sha256, and is otherwise exactly
    the reviewed record. A forged flag, another kit or a private record is refused."""
    kit = record.get('correspondingSource') if isinstance(record, dict) else None
    return (isinstance(record, dict) and record.get('publicDistribution') is True
            and record.get('completeCorrespondingSource') is True
            and isinstance(kit, dict) and kit.get('sha256') == SOURCE_KIT_SHA256
            and re.fullmatch(r'[0-9a-f]{64}', SOURCE_KIT_SHA256) is not None
            and record == expected_distribution())


def verify_source_kit(path):
    """The kit file itself, when one is given (stage --typesense-source-kit): exactly the recorded bytes."""
    kit = regular(path)
    require(kit.name == SOURCE_KIT_NAME and kit.stat().st_size == SOURCE_KIT_BYTES and digest(kit) == SOURCE_KIT_SHA256,
            'Typesense source kit does not match the recorded sha256 ' + SOURCE_KIT_SHA256)
    return kit


def notice_problems(text):
    """Typesense-NOTICES.txt is a real GPL notice that points at the recorded kit."""
    text = ' '.join(text.split())
    need = ['Typesense', 'GNU General Public License', 'version 3', 'WITHOUT ANY WARRANTY', 'Typesense-LICENSE.txt',
            'unmodified', SOURCE_KIT_NAME, SOURCE_KIT_SHA256, SOURCE_COMMIT]
    return [n for n in need if n not in text] + (['private-use wording'] if 'not approved for public distribution' in text else [])


def platform(path):
    # Inspect Mach-O load commands without launching the executable or changing it.
    data = Path(path).read_bytes()
    require(len(data) >= 32, 'Truncated Typesense Mach-O')
    magic, cpu, _, _, count, size, _, _ = struct.unpack_from('<8I', data)
    require(magic == 0xfeedfacf and cpu == 0x0100000c and 32 + size <= len(data), 'Typesense must be a thin arm64 Mach-O')
    offset = 32
    found = False
    for _ in range(count):
        require(offset + 8 <= 32 + size, 'Truncated load command')
        cmd, length = struct.unpack_from('<2I', data, offset)
        require(length >= 8 and offset + length <= 32 + size, 'Unsafe load command')
        if cmd == 0x32:
            require(length >= 24, 'Truncated build version')
            target, minimum = struct.unpack_from('<2I', data, offset + 8)
            require(target == 1 and minimum == (13 << 16 | 1 << 8), 'Unreviewed Typesense platform/minimum OS')
            found = True
        offset += length
    require(found, 'Missing Typesense build version')


def source_files(source, inputs=None):
    source = Path(source).resolve()
    inputs = Path(inputs).resolve() if inputs is not None else source / 'Vendor/Typesense-30.2'
    server = regular(inputs / 'typesense-server', True)
    archive = regular(inputs / 'runtime.tar.gz')
    require(digest(server) == SERVER_SHA256 and digest(archive) == ARCHIVE_SHA256, 'Unreviewed Typesense runtime/archive bytes')
    platform(server)
    directory = source / SOURCE_DIR
    descriptor = regular(directory / 'local-typesense-v30.2.json')
    require(json.loads(descriptor.read_text()) == expected_distribution(), 'Wrong local search distribution descriptor')
    license_path, notices = regular(directory / 'Typesense-LICENSE.txt'), regular(directory / 'Typesense-NOTICES.txt')
    require(digest(license_path) == LICENSE_SHA256 and 'GNU GENERAL PUBLIC LICENSE' in license_path.read_text() and notices.stat().st_size > 0, 'Missing/unreviewed Typesense notices')
    require(not notice_problems(notices.read_text()), 'Typesense notice is not the GPL notice for the recorded source kit: ' + ', '.join(notice_problems(notices.read_text())))
    return {'server': server, 'distribution': descriptor, 'license': license_path, 'notices': notices}


def normal_app(app):
    info = plistlib.loads(regular(Path(app) / 'Contents/Info.plist').read_bytes())
    # perm-1004: an ad-hoc seal gives the normal identity its own .adhoc ID (seal-local-app.sh).
    require(info.get('CFBundleIdentifier') in ('com.getnorthlight.daydream', 'com.getnorthlight.daydream.adhoc'),
            'Local search requires the normal DayDream app identity')
    require(re.fullmatch(r'[0-9]+(\.[0-9]+){0,2}', str(info.get('LSMinimumSystemVersion', ''))) is not None and tuple(int(x) for x in (str(info['LSMinimumSystemVersion']) + '.0.0').split('.')[:3]) >= (13, 1, 0), 'Local search requires minimum macOS 13.1 or newer')
    require(TEST_ONLY_KEY not in info, 'Test-only missing-search marker cannot claim local search')
    # Updates on (the website feed, quiet automatic checks) only with the cleared public record; otherwise off.
    updates_on = info.get('SUEnableAutomaticChecks', False) is not False or 'SUFeedURL' in info
    require(not updates_on or public_cleared(expected_distribution()),
            'Local search copy must have public updates off: Typesense is not cleared for public distribution')


def present(app):
    c = Path(app) / 'Contents'
    return (c / DISTRIBUTION).exists() or (c / DISTRIBUTION).is_symlink()


def paths(app):
    if not present(app):
        return set()
    c = Path(app) / 'Contents'
    normal_app(app)
    require(not (c / 'Resources/FunctionalTrial.json').exists(), 'Do not mix local search policy and legacy functional trial')
    for name in PAYLOAD:
        regular(c / name, name == SERVER)
    require(json.loads((c / DISTRIBUTION).read_text()) == expected_distribution(), 'Wrong local search scope/provenance')
    require(not notice_problems((c / NOTICES).read_text()), 'Typesense notice is not the GPL notice for the recorded source kit')
    require(digest(c / LICENSE) == LICENSE_SHA256 and 'GNU GENERAL PUBLIC LICENSE' in (c / LICENSE).read_text(), 'Missing/unreviewed GPL license')
    platform(c / SERVER)
    manifest = json.loads((c / RUNTIME).read_text())
    require(manifest == runtime_manifest(app), 'Stale final search runtime hashes')
    return set(PAYLOAD)


def public_cleared_app(app):
    """The app's bundled Typesense may go to the public (and into the appcast): its payload verifies and its
    distribution record is the cleared public record that names the recorded source kit."""
    if not present(app):
        return False
    paths(app)
    return public_cleared(json.loads((Path(app) / 'Contents' / DISTRIBUTION).read_text()))


def runtime_manifest(app):
    c = Path(app) / 'Contents'
    return {'version': 1, 'serverSHA256': digest(regular(c / SERVER, True)),
            'supervisorSHA256': digest(regular(c / 'MacOS/mac-mem', True))}


def refresh(app):
    if not present(app):
        return
    c = Path(app) / 'Contents'
    require(not (c / '_CodeSignature').exists(), 'Cannot refresh sealed local search app')
    regular(c / DISTRIBUTION)
    (c / RUNTIME).write_text(json.dumps(runtime_manifest(app), sort_keys=True) + '\n')
    (c / RUNTIME).chmod(0o644)


def assemble(app, source, inputs=None):
    app = Path(app).resolve()
    c = app / 'Contents'
    require(app.name == 'DayDream.app' and c.is_dir(), 'Requires a staged DayDream.app')
    require(not (c / '_CodeSignature').exists(), 'Stage local search before outer signing')
    require(not any((c / name).exists() or (c / name).is_symlink() for name in PAYLOAD), 'Refusing to overwrite existing search payload')
    normal_app(app)
    files = source_files(source, inputs)
    regular(c / 'MacOS/mac-mem', True)
    for key, name in [('server', SERVER), ('distribution', DISTRIBUTION), ('license', LICENSE), ('notices', NOTICES)]:
        destination = c / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(files[key], destination)
        destination.chmod(0o755 if key == 'server' else 0o644)
        require(digest(destination) == digest(files[key]), 'Search input changed during copy')
    refresh(app)
    paths(app)
    return runtime_manifest(app)


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['assemble', 'verify'])
    p.add_argument('--app', required=True, type=Path)
    p.add_argument('--source', type=Path)
    p.add_argument('--inputs', type=Path)
    args = p.parse_args()
    if args.action == 'assemble':
        require(args.source is not None, 'Explicit source required')
        print(json.dumps(assemble(args.app, args.source, args.inputs), sort_keys=True))
    else:
        require(paths(args.app), 'Missing local search payload')
        print('Local search runtime final-byte hashes and exact payload match')
