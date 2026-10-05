#!/usr/bin/env python3
"""DayDream Developer ID release pipeline (python3 stdlib, 3.9+).

  stage     build a complete, UNSIGNED DayDream.app from a clean `git archive` of HEAD: never
            from an installed app or another Mac's copy. Refuses a tree with uncommitted or
            untracked changes. Builds MacMem, mac-mem and mac-mem-backup in a scratch folder,
            adds the pinned Sparkle and the licence files from that commit, writes the release
            Info.plist (version "x.y.z Beta", Sparkle settings from packaging/updates.json) and
            records the commit in stage-receipt.json and Contents/Resources/Companions.json.
            Needs --previous-build (the build of the last copy anyone installed; --build must exceed
            it, since an update only goes to a higher build) or --first-build for the very first one.
  sign      inside-out signing of a COPY of a staged app with explicit per-item flags and
            the entitlements files in packaging/entitlements/. --identity - is an ad-hoc
            structure dry run that still uses --options runtime.
  verify    codesign --verify --strict --deep plus per-item checks: runtime flag, secure
            timestamp (not ad-hoc), no get-task-allow, exact entitlements, identifiers,
            team consistency, one leaf certificate for all items and, for writer builds,
            the writer-enrolled leaf certificate.
  dmg       final-layout DayDream-<version>.dmg from a signed (for release: stapled) app, using
            dmg-background.swift and dmg-layout.py; signs the image. Built in a work directory
            and moved to --out only after every post-check passes. A test build gets its own file
            and volume name (--name "DayDream - Saturday test 5.dmg", --volume-name), so it never
            looks like the release or an earlier test; notes refuse such an image.
  notarize  PRINT-ONLY unless --execute and --keychain-profile are given. Re-verifies the app
            (or mounts the DMG read-only and verifies the stapled app inside) before uploading;
            --resume waits on a saved submission instead of uploading again.
  staple    PRINT-ONLY unless --execute is given. Requires the Accepted notary receipt whose
            CDHash matches the artifact, and refuses installed copies. For a DMG it then writes
            <dmg>.sha256: the checksum is taken only after stapling, which changes the file.
  checksum  (re)write <dmg>.sha256 for a stapled DMG; refuses one that is not stapled.
  notes     fill docs/release-notes-template.md for this release (version, build, commit and
            the post-staple SHA-256).

Every stage builds the full-typing app (the owner's decision of 2026-09-25): stage adds OWNER_SWIFT_FLAGS
(the DAYDREAM_OWNER_TYPING and DAYDREAM_CHROME_TYPING defines, each through -Xswiftc) to every swift
build, so typing in more apps and on websites in Google Chrome is compiled in (each still off until the
person turns it on), and refuses an app whose MacMem lacks the website typing route.

--qa-harness (stage only) explicitly compiles capture automation and its helper window; requires
--owner-build --updates off, sets DaydreamQAHarness=true, and never belongs to the shipping app.

--owner-build (stage, dmg, notarize) is the owner's private test copy of that same app: stage marks
Info.plist MacMemOwnerTyping=true and records owner_build=true in stage-receipt.json. An owner stage
needs --updates off: it never reads the public update feed. A public stage refuses the owner key. dmg
names an owner image DayDream-<version>-owner.dmg; notes and release.py prepare refuse owner copies.

--apple-events follows ReleaseFeatures.chromePageHistory (Sources/MemoryCore/ReleaseFeatures.swift)
by default; passing a value that disagrees with that switch is refused.

Every stage also carries the "On this Mac" runtime (owner decision 2026-09-26): the signed llama.cpp
libraries and their manifest committed under packaging/WriterRuntime/<ID>/ (writer_payload.py). stage checks
the manifest against the pin compiled into that commit's SignedRuntimePolicy.swift and each library's bytes,
Developer ID signature, team and leaf certificate, then copies them unchanged into
Contents/Frameworks/WriterRuntime/<ID>/ and Contents/Resources/WriterRuntime/<ID>.json and sets
DaydreamWriterRuntimeDistribution. A commit without them is refused ("writer runtime not signed yet");
--without-writer-runtime-for-tests stages a test build without them, which dmg (Developer ID), notarize of
its image and release.py prepare refuse.

Every stage also carries the local Typesense search server (GPL-3.0, the unmodified vendor binary; owner decision
2026-10-03 "Ship typesense."), from --typesense-inputs, checked by scripts/search_payload.py. A public stage
(updates configured) needs this commit's cleared public distribution record and --typesense-source-kit, the
Complete Corresponding Source kit whose sha256 the record names; the kit is attached to the GitHub release next to
the DMG (GPLv3 6(d)). An owner stage (--updates off) needs neither.

Never reads or lists the keychain, never runs `security`, never launches the app, never
re-signs the enrolled writer runtime dylibs. See RELEASE.md for the runbook.
"""
import argparse
import hashlib
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
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
ROOT = SCRIPTS.parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))
import functional_payload  # noqa: E402
import search_payload  # noqa: E402
import release  # noqa: E402
import writer_payload  # noqa: E402


def _load_bootstrap():
    import importlib.util
    spec = importlib.util.spec_from_file_location('bootstrap_sparkle', SCRIPTS / 'bootstrap-sparkle.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bootstrap_sparkle = _load_bootstrap()

TEAM_ID = 'L76C3ZC66J'
# DER SHA-256 of the enrolled Developer ID Application leaf certificate (writer_payload.LEAF_SHA256;
# the signed manifest records it and SignedRuntimePolicy.check requires the host app to match it).
# Enforced only for writer builds: the writer compares the host's leaf with it, while TCC
# and notarization only need the team. Every build still requires one leaf for all items.
LEAF_SHA256 = writer_payload.LEAF_SHA256
BUNDLE_ID = 'com.getnorthlight.daydream'
APP_NAME = 'DayDream.app'
DEFAULT_MIN_MACOS = '15.0'
DEFAULT_NOTARY_PROFILE = 'daydream-notary'
# An unanswered "codesign wants to sign using key" prompt or a locked keychain makes codesign
# wait forever; this turns that into an error.
CODESIGN_TIMEOUT = 900
# notarytool's own polling limit (man notarytool: submit/wait --timeout). The submission keeps
# processing at Apple after it; `notarize --resume` waits on the saved id without re-uploading.
NOTARY_WAIT = '2h'
NOTARY_PROCESS_TIMEOUT = 3 * 3600
TERMINAL_NOTARY_STATUSES = ('Accepted', 'Invalid', 'Rejected')
# Mirrors WriterBackend/Sources/WriterBackend/RuntimeSignatureVerifier.swift:11 plus the team.
DEVELOPER_ID_REQUIREMENT = ('anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists '
                            'and certificate leaf[field.1.2.840.113635.100.6.1.13] exists '
                            'and certificate leaf[subject.OU] = "%s"' % TEAM_ID)

ENTITLEMENTS_DIR = ROOT / 'packaging/entitlements'
APPLE_EVENTS = 'com.apple.security.automation.apple-events'
GET_TASK_ALLOW = 'com.apple.security.get-task-allow'
# Exact contents of every entitlements file. Code signed with no --entitlements has none.
# Public builds bundle no Node runtime or remote bridge, so there is no helper entitlement.
ENTITLEMENT_FILES = {
    'main-apple-events.entitlements': {APPLE_EVENTS: True},
}
# Downloader.xpc is signed with --preserve-metadata=entitlements (Sparkle >= 2.6,
# https://sparkle-project.org/documentation/sandboxing/). Sparkle 2.9.6 ships it with an
# empty dict; any other value means a Sparkle change that needs review.
SPARKLE_DOWNLOADER_ENTITLEMENTS = {}

SPARKLE = 'Contents/Frameworks/Sparkle.framework'
SPARKLE_B = SPARKLE + '/Versions/B'
SPARKLE_VENDOR = ROOT / 'Vendor/Sparkle-2.9.6/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
SPARKLE_INVENTORY_SHA256 = 'd7ae7cd8bac0109a011eb6f34bf6f1d46c7a228766c00b537f29ad0709926428'
SPARKLE_DIR = ROOT / 'Vendor/Sparkle-2.9.6'
SWIFT_BINARIES = ('MacMem', 'mac-mem', 'mac-mem-backup')
# A full release build of the three products; generous, it only turns a hang into an error.
BUILD_TIMEOUT = 3 * 3600
RELEASE_FEATURES = 'Sources/MemoryCore/ReleaseFeatures.swift'
# CFBundleShortVersionString: numeric, then " Beta" while DayDream is in beta. The About box
# shows it ("Version 0.1.0 Beta (build)"); Sparkle shows it in its update window.
VERSION_RE = r'[0-9]+(\.[0-9]+){1,2}'
SHORT_VERSION_RE = VERSION_RE + r'( Beta)?'
# Info.plist keys that point Sparkle at a feed. A build without them never creates Sparkle.
UPDATE_KEYS = ('SUFeedURL', 'SUPublicEDKey', 'MacMemGitHubOwner', 'MacMemGitHubRepository', 'DaydreamUpdateSite',
               'SUScheduledCheckInterval')
ALLOWED_RPATHS = {'/usr/lib/swift', '@loader_path', '@executable_path/../Frameworks'}
TOOLCHAIN_RPATH_PREFIXES = ('/Library/Developer/', '/Applications/Xcode')

PRESERVE = 'preserve'
MAIN = 'main'


def _row(key, path, mode='sign', identifier=None, entitlements=None, optional=False, identifier_pattern=None):
    return {'key': key, 'path': path, 'mode': mode, 'identifier': identifier, 'entitlements': entitlements,
            'optional': optional, 'identifier_pattern': identifier_pattern}


# Inside-out signing table. Paths are relative to DayDream.app. Order matters only between
# depths: Sparkle rows follow Sparkle's documented order; every helper precedes the
# companion manifest, which precedes the outer app. Never --deep.
SIGNING_TABLE = (
    _row('sparkle-installer', SPARKLE_B + '/XPCServices/Installer.xpc'),
    _row('sparkle-downloader', SPARKLE_B + '/XPCServices/Downloader.xpc', entitlements=PRESERVE),
    # No entitlements: drops com.apple.application-identifier, a restricted entitlement no
    # Developer ID profile could authorize (TN3125), as Sparkle's docs do.
    _row('sparkle-autoupdate', SPARKLE_B + '/Autoupdate', identifier_pattern=r'Autoupdate(-[0-9a-f]{40})?'),
    _row('sparkle-updater', SPARKLE_B + '/Updater.app'),
    _row('sparkle-framework', SPARKLE),
    _row('writer-runtime', 'Contents/Frameworks/WriterRuntime', mode='verify', optional=True),
    _row('typesense-server', 'Contents/' + functional_payload.SERVER, identifier='com.getnorthlight.daydream.typesense-server', optional=True),
    _row('mac-mem', 'Contents/MacOS/mac-mem', identifier='com.getnorthlight.daydream.mac-mem'),
    _row('mac-mem-backup', 'Contents/MacOS/mac-mem-backup', identifier='com.getnorthlight.daydream.mac-mem-backup'),
    _row('companions', None, mode='manifest'),
    _row('app', '', identifier=None, entitlements=MAIN),
)

# Every Mach-O in the bundle must be one of these (relative to Contents), or an enrolled
# writer dylib. A new binary (BrowserBridgeHost, an .appex, a Sparkle upgrade) fails until
# it gets a row in SIGNING_TABLE.
KNOWN_MACHO = {
    'MacOS/MacMem', 'MacOS/mac-mem', 'MacOS/mac-mem-backup', functional_payload.SERVER,
    'Frameworks/Sparkle.framework/Versions/B/Sparkle',
    'Frameworks/Sparkle.framework/Versions/B/Autoupdate',
    'Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater',
    'Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer',
    'Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader',
}
# Never in a public build (relative to Contents): the owner's remote bridge and its Node
# runtime, the bridge's availability file, Horizon examples and the old provenance note
# with a home path. `stage` builds from the commit, so none can come in; it and `verify` fail if one is present.
PRIVATE_PAYLOAD = ('MacOS/daydream-node', 'Resources/Node-LICENSE.txt', 'Resources/RemoteBridge',
                   'Resources/ConnectionAvailability.json',
                   'Resources/horizon-host.example.json', 'Resources/horizon-reader.example.json',
                   'Resources/PROVENANCE.md')
LINKED_EXECUTABLES = ('MacOS/MacMem', 'MacOS/mac-mem', 'MacOS/mac-mem-backup', functional_payload.SERVER)
MACHO_MAGICS = {bytes.fromhex(m) for m in ('cffaedfe', 'feedfacf', 'cefaedfe', 'feedface', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}


class ReleaseError(Exception):
    pass


def require(ok, message):
    if not ok:
        raise ReleaseError(message)


# ---------------------------------------------------------------- command runner
class Runner:
    """Runs and records every external command. Output is kept for the receipt."""

    def __init__(self, echo=True):
        self.records = []
        self.echo = echo

    def run(self, argv, check=True, env=None, timeout=None, quiet=False):
        argv = [str(a) for a in argv]
        if self.echo:
            print('$ ' + shlex.join(argv), flush=True)
        try:
            proc = subprocess.run(argv, capture_output=True, text=True, env=env, timeout=timeout)
        except subprocess.TimeoutExpired:
            self.records.append({'argv': argv, 'timed_out_after_seconds': timeout})
            hint = (' An unanswered keychain prompt or a locked keychain is the usual cause; run in the'
                    ' logged-in GUI session with the screen unlocked (RELEASE.md §3).') if argv[0] == 'codesign' else ''
            raise ReleaseError('Timed out after %ss: %s.%s' % (timeout, shlex.join(argv), hint))
        record = {'argv': argv, 'returncode': proc.returncode}
        if proc.returncode or not quiet:
            tail = (proc.stdout + proc.stderr).strip()
            if tail:
                record['output_tail'] = tail[-4000:]
                if self.echo and (proc.returncode or not quiet):
                    print('  ' + tail[-4000:].replace('\n', '\n  '), flush=True)
        self.records.append(record)
        if check and proc.returncode:
            raise ReleaseError('Command failed (%d): %s' % (proc.returncode, shlex.join(argv)))
        return proc

    def note(self, text):
        self.records.append({'note': text})
        if self.echo:
            print('# ' + text, flush=True)


# ---------------------------------------------------------------- small helpers
def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def load_plist(path):
    return plistlib.loads(Path(path).read_bytes())


def identity_kind(identity):
    """'-' => adhoc; 40 hex => developer-id (the certificate SHA-1, never a name)."""
    if identity == '-':
        return 'adhoc'
    require(isinstance(identity, str) and re.fullmatch(r'[0-9A-Fa-f]{40}', identity or ''),
            'Identity must be "-" (ad-hoc dry run) or the 40-hex SHA-1 of the Developer ID Application certificate')
    return 'developer-id'


def codesign_sign_argv(identity, path, identifier=None, entitlements=None, preserve_entitlements=False, runtime=True):
    argv = ['codesign', '--force', '--sign', identity, '--timestamp=none' if identity == '-' else '--timestamp']
    if runtime:
        argv += ['--options', 'runtime']
    if identifier:
        argv += ['--identifier', identifier]
    if preserve_entitlements:
        argv.append('--preserve-metadata=entitlements')
    if entitlements:
        argv += ['--entitlements', str(entitlements)]
    argv.append(str(path))
    return argv


def entitlements_file(kind, apple_events=False, directory=None):
    directory = Path(directory or ENTITLEMENTS_DIR)
    if kind == MAIN:
        return directory / 'main-apple-events.entitlements' if apple_events else None
    return None


def expected_entitlements(kind, apple_events=False):
    if kind == PRESERVE:
        return dict(SPARKLE_DOWNLOADER_ENTITLEMENTS)
    path = entitlements_file(kind, apple_events)
    return dict(ENTITLEMENT_FILES[path.name]) if path else {}


def lint_entitlements(runner=None, directory=None):
    """Every file parses as an XML plist and holds exactly the reviewed dict."""
    directory = Path(directory or ENTITLEMENTS_DIR)
    found = sorted(p.name for p in directory.iterdir() if p.suffix == '.entitlements')
    require(found == sorted(ENTITLEMENT_FILES), 'Unexpected entitlements files: %s' % found)
    for name, expected in ENTITLEMENT_FILES.items():
        path = directory / name
        require(path.read_bytes().lstrip().startswith(b'<?xml'), 'Entitlements must be XML: ' + name)
        value = load_plist(path)
        require(value == expected, 'Entitlements drift in %s: %r' % (name, value))
        require(GET_TASK_ALLOW not in value, 'get-task-allow is never allowed: ' + name)
        if runner:
            runner.run(['plutil', '-lint', path], quiet=True)
    return True


# ---------------------------------------------------------------- Mach-O inspection
def is_macho(path):
    try:
        with open(path, 'rb') as stream:
            return stream.read(4) in MACHO_MAGICS
    except OSError:
        return False


CPU_NAMES = {0x0100000C: 'arm64', 0x01000007: 'x86_64', 0x0200000C: 'arm64_32'}


def macho_archs(path):
    data = Path(path).read_bytes()[:4096]
    magic = data[:4]
    if magic == bytes.fromhex('cffaedfe'):
        return {CPU_NAMES.get(struct.unpack_from('<I', data, 4)[0], 'other')}
    if magic in (bytes.fromhex('cafebabe'), bytes.fromhex('cafebabf')):
        count = struct.unpack_from('>I', data, 4)[0]
        size = 20 if magic == bytes.fromhex('cafebabe') else 32
        return {CPU_NAMES.get(struct.unpack_from('>I', data, 8 + i * size)[0], 'other') for i in range(min(count, 16))}
    return set()


def walk_files(root):
    """Regular files under root, never following symlinks."""
    for directory, dirs, files in os.walk(root):
        for name in files:
            path = Path(directory) / name
            if not path.is_symlink():
                yield path


def coverage_problems(app):
    contents = Path(app) / 'Contents'
    writer = set(functional_payload.paths(Path(app))) | set(writer_payload.paths(Path(app)))
    bad = []
    for path in walk_files(contents):
        rel = path.relative_to(contents).as_posix()
        if is_macho(path) and rel not in KNOWN_MACHO and rel not in writer:
            bad.append(rel)
    return sorted(bad)


def parse_otool_libraries(text):
    return [line.strip().split(' (compatibility')[0] for line in text.splitlines() if line.startswith('\t')]


def linkage_problems(rel, libraries):
    allowed_rpath = {'@rpath/Sparkle.framework/Versions/B/Sparkle'} if rel == 'MacOS/MacMem' else set()
    return [lib for lib in libraries
            if not (lib.startswith('/usr/lib/') or lib.startswith('/System/Library/') or lib in allowed_rpath)]


def parse_rpaths(text):
    rpaths, pending = [], False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped == 'cmd LC_RPATH':
            pending = True
        elif pending and stripped.startswith('path '):
            match = re.match(r'path (.*) \(offset \d+\)$', stripped)
            rpaths.append(match.group(1) if match else stripped[5:])
            pending = False
    return rpaths


def lint_binaries(app, runner):
    """Coverage, linkage and rpath checks. Read-only."""
    contents = Path(app) / 'Contents'
    problems = ['Mach-O not in signing table: ' + rel for rel in coverage_problems(app)]
    for rel in LINKED_EXECUTABLES:
        path = contents / rel
        if not path.exists():
            continue
        libs = parse_otool_libraries(runner.run(['otool', '-L', path], quiet=True).stdout)
        problems += ['%s links %s (embed and sign it, or raise the deployment target)' % (rel, lib)
                     for lib in linkage_problems(rel, libs)]
        if rel.startswith('MacOS/') and rel[6:] in SWIFT_BINARIES:
            rpaths = parse_rpaths(runner.run(['otool', '-l', path], quiet=True).stdout)
            problems += ['%s has LC_RPATH %s (run stage, which removes toolchain rpaths)' % (rel, rp)
                         for rp in rpaths if rp not in ALLOWED_RPATHS]
    return problems


def xattr_problems(root, runner):
    out = runner.run(['xattr', '-r', root], quiet=True).stdout
    bad = []
    for line in out.splitlines():
        name = line.rsplit(': ', 1)[-1].strip()
        if name and name != 'com.apple.provenance':
            bad.append(line.strip())
    return bad


# ---------------------------------------------------------------- Info.plist policy
def update_policy_problems(info, updates, data=None):
    """Sparkle policy. 'configured' (the release default): checks once a day from the website's signed appcast
    (packaging/updates.json: https://<site>/appcast.xml and its public key), downloads a found update quietly and installs
    it when DayDream quits or the person chooses Restart to Update (SUAutomaticallyUpdate and SUAllowsAutomaticUpdates
    true; the app never pops a window for it). 'off' (owner, QA and test copies): no feed, no key, nothing automatic."""
    problems = []
    if info.get('SUSendProfileInfo', False) is not False:
        problems.append('SUSendProfileInfo must be false (no system profile is sent)')
    for key in ('SURequireSignedFeed', 'SUVerifyUpdateBeforeExtraction'):
        if info.get(key) is not True:
            problems.append('%s must be true' % key)
    present = [k for k in UPDATE_KEYS if k in info]
    if updates == 'off':
        if present:
            problems.append('updates=off build must not configure %s' % present)
        for key in ('SUEnableAutomaticChecks', 'SUAutomaticallyUpdate', 'SUAllowsAutomaticUpdates'):
            if info.get(key) is not False:
                problems.append('updates=off build must set %s=false' % key)
    elif updates == 'configured':
        try:
            data = data or release.config()
        except (ValueError, OSError) as error:
            return problems + ['updates=configured needs packaging/updates.json with the public key: %s' % error]
        for key, value in release.update_info(data).items():
            if info.get(key) != value:
                problems.append('updates=configured requires %s=%r (packaging/updates.json), found %r' % (key, value, info.get(key)))
    else:
        problems.append('Unknown updates mode: %r' % updates)
    return problems


def info_problems(info, writer, updates='off', apple_events=False, data=None):
    """`writer`: the writer runtime ID the app carries (writer_payload.ID, or the private trial's), or None."""
    problems = []
    if info.get('CFBundleIdentifier') != BUNDLE_ID:
        problems.append('CFBundleIdentifier must be ' + BUNDLE_ID)
    if info.get('CFBundleExecutable') != 'MacMem':
        problems.append('CFBundleExecutable must be MacMem')
    build = str(info.get('CFBundleVersion', ''))
    # CompanionIdentity.swift:15 parses it as UInt64; Sparkle compares it as the build number.
    if not re.fullmatch(r'[1-9][0-9]*', build) or int(build) >= 2 ** 64:
        problems.append('CFBundleVersion must be a positive integer that fits UInt64')
    if not re.fullmatch(SHORT_VERSION_RE, str(info.get('CFBundleShortVersionString', ''))):
        problems.append('CFBundleShortVersionString must be x.y or x.y.z, optionally followed by " Beta"')
    minimum = str(info.get('LSMinimumSystemVersion', ''))
    if not re.fullmatch(r'[0-9]+(\.[0-9]+){0,2}', minimum):
        problems.append('LSMinimumSystemVersion missing')
    elif writer and tuple(int(x) for x in minimum.split('.'))[:1] < (15,):
        problems.append('Writer builds require LSMinimumSystemVersion >= 15.0')
    has_key = 'DaydreamWriterRuntimeDistribution' in info
    if writer and info.get('DaydreamWriterRuntimeDistribution') != writer:
        problems.append('Writer build must set DaydreamWriterRuntimeDistribution=%s' % writer)
    if not writer and has_key:
        problems.append('No-writer build must not advertise DaydreamWriterRuntimeDistribution')
    if apple_events and not str(info.get('NSAppleEventsUsageDescription', '')).strip():
        problems.append('--apple-events requires NSAppleEventsUsageDescription')
    return problems + update_policy_problems(info, updates, data)


def release_info(template, build, version, min_macos, writer, updates='off', update_data=None, beta=True,
                 chrome_pages=True):
    """`writer`: the writer runtime ID to advertise (writer_payload.ID), or None for a build without it."""
    info = dict(template)
    info.update(CFBundleName='DayDream', CFBundleDisplayName='DayDream', CFBundleVersion=str(build),
                CFBundleShortVersionString=version + (' Beta' if beta else ''), LSMinimumSystemVersion=min_macos,
                SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False, SUAllowsAutomaticUpdates=False,
                SUSendProfileInfo=False, SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True)
    for key in UPDATE_KEYS:
        info.pop(key, None)
    if updates == 'configured':
        info.update(release.update_info(update_data or release.config()))
    if writer:
        info['DaydreamWriterRuntimeDistribution'] = writer
    else:
        info.pop('DaydreamWriterRuntimeDistribution', None)
    if not chrome_pages:
        # Chrome page history switched off for this release: nothing asks to control Chrome.
        info.pop('NSAppleEventsUsageDescription', None)
    return info


def strip_swift_comments(text):
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return re.sub(r'//[^\n]*', '', text)


def chrome_page_history_switch(root=ROOT):
    """ReleaseFeatures.chromePageHistory, the one switch for Chrome page history in a release.

    Before Sources/MemoryCore/ReleaseFeatures.swift exists, page history ships (it is merged and
    on sat/v1), so the answer is True. Once the file exists, exactly one
    `static let chromePageHistory = true|false` must be found, or the release stops."""
    path = Path(root) / RELEASE_FEATURES
    if not path.exists():
        return True
    found = re.findall(r'\bstatic\s+(?:let|var)\s+chromePageHistory\s*(?::\s*Bool\s*)?=\s*(true|false)\b',
                       strip_swift_comments(path.read_text()))
    require(len(found) == 1, 'Could not read ReleaseFeatures.chromePageHistory from %s' % RELEASE_FEATURES)
    return found[0] == 'true'


def resolve_apple_events(flag, root=ROOT):
    """--apple-events follows the switch. An explicit value that disagrees with it is refused."""
    switch = chrome_page_history_switch(root)
    if flag is None:
        return switch
    require(bool(flag) == switch, '%s disagrees with ReleaseFeatures.chromePageHistory = %s in %s'
            % ('--apple-events' if flag else '--no-apple-events', 'true' if switch else 'false', RELEASE_FEATURES))
    return switch


# ---------------------------------------------------------------- signing plan (shared with signing_plan.py)
def writer_libraries(app):
    app = Path(app)
    trial = {'Contents/' + name for name in functional_payload.paths(app) if name.startswith(functional_payload.LIBROOT)}
    return sorted(trial | set(writer_payload.libraries(app)))


def app_writer_id(app):
    """The writer runtime ID `app` carries, fully checked: writer_payload.ID (every release), the private
    trial's functional_payload.ID, or None when it has none."""
    app = Path(app)
    if functional_payload.paths(app):
        return functional_payload.ID
    if writer_payload.paths(app):
        return writer_payload.ID
    return None


def writer_manifest_rel(app):
    return functional_payload.MANIFEST if functional_payload.paths(Path(app)) else writer_payload.MANIFEST


def sign_steps(target, identity, apple_events=False, present=None, writer_libs=None,
               entitlements_dir=None, python='python3'):
    """Ordered steps for signing `target` (a DayDream.app path). Pure: runs nothing.

    present(rel) says whether an optional row exists; writer_libs lists enrolled dylibs
    (relative to the app) that are verified, never re-signed.
    """
    target = Path(target)
    present = present or (lambda rel: (target / rel).exists())
    writer_libs = writer_libraries(target) if writer_libs is None else list(writer_libs)
    steps = []
    for row in SIGNING_TABLE:
        if row['mode'] == 'manifest':
            steps.append({'row': row['key'], 'action': 'manifest',
                          'argv': [python, str(SCRIPTS / 'release.py'), 'manifest', '--app', str(target)]})
            continue
        if row['mode'] == 'verify':
            for rel in writer_libs:
                steps.append({'row': row['key'], 'action': 'verify', 'rel': rel,
                              'argv': ['codesign', '--verify', '--strict', str(target / rel)]})
            continue
        if row['optional'] and not present(row['path']):
            continue
        ent = entitlements_file(row['entitlements'], apple_events, entitlements_dir) if row['entitlements'] == MAIN else None
        argv = codesign_sign_argv(identity, target / row['path'] if row['path'] else target, identifier=row['identifier'],
                                  entitlements=ent, preserve_entitlements=row['entitlements'] == PRESERVE)
        steps.append({'row': row['key'], 'action': 'sign', 'rel': row['path'], 'argv': argv})
    return steps


# ---------------------------------------------------------------- signature inspection
def parse_display(text):
    info = {'authorities': [], 'flags': set()}
    for line in text.splitlines():
        key, sep, value = line.partition('=')
        if not sep:
            continue
        if key == 'Authority':
            info['authorities'].append(value)
        elif key == 'CodeDirectory v':
            match = re.search(r'flags=0x[0-9a-f]+\(([^)]*)\)', line)
            if match:
                info['flags'] = set(match.group(1).split(','))
        elif key in ('Identifier', 'TeamIdentifier', 'Signature', 'Timestamp', 'Signed Time', 'CDHash', 'Format', 'Runtime Version'):
            info[key] = value
    return info


def parse_entitlements(text):
    text = (text or '').strip()
    if not text:
        return {}
    start = text.find('<?xml')
    value = plistlib.loads(text[start if start >= 0 else 0:].encode())
    return dict(value) if isinstance(value, dict) else {}


def signature_problems(info, expect, identifier=None, identifier_pattern=None, entitlements=None, team=TEAM_ID):
    problems = []
    if 'runtime' not in info.get('flags', set()):
        problems.append('hardened runtime flag missing')
    ents = info.get('entitlements', {})
    if GET_TASK_ALLOW in ents:
        problems.append('get-task-allow present')
    if entitlements is not None and ents != entitlements:
        problems.append('entitlements %s != expected %s' % (json.dumps(ents, sort_keys=True), json.dumps(entitlements, sort_keys=True)))
    ident = info.get('Identifier', '')
    if identifier is not None and ident != identifier:
        problems.append('identifier %r != %r' % (ident, identifier))
    if identifier_pattern is not None and not re.fullmatch(identifier_pattern, ident):
        problems.append('identifier %r does not match %s' % (ident, identifier_pattern))
    adhoc = 'adhoc' in info.get('flags', set()) or info.get('Signature') == 'adhoc'
    if expect == 'adhoc':
        if not adhoc:
            problems.append('expected ad-hoc signature')
        if info.get('TeamIdentifier') != 'not set':
            problems.append('ad-hoc item has a Team ID')
    elif expect == 'developer-id':
        if adhoc:
            problems.append('ad-hoc signature where Developer ID is required')
        if not info.get('authorities') or not info['authorities'][0].startswith('Developer ID Application:'):
            problems.append('leaf authority is not Developer ID Application')
        if info.get('TeamIdentifier') != team:
            problems.append('TeamIdentifier %r != %s' % (info.get('TeamIdentifier'), team))
        if not info.get('Timestamp'):
            problems.append('secure timestamp missing')
    else:
        problems.append('unknown expectation %r' % expect)
    return problems


def inspect_signature(runner, path):
    info = parse_display(runner.run(['codesign', '-dvvv', path], quiet=True).stderr)
    info['entitlements'] = parse_entitlements(runner.run(['codesign', '-d', '--entitlements', '-', '--xml', path], quiet=True).stdout)
    return info


def leaf_sha256(runner, path):
    with tempfile.TemporaryDirectory(prefix='daydream-cert-') as folder:
        runner.run(['codesign', '-d', '--extract-certificates=' + str(Path(folder) / 'c'), path], quiet=True)
        leaf = Path(folder) / 'c0'
        return sha256_file(leaf) if leaf.exists() else None


def bundle_identifier(path):
    path = Path(path)
    for candidate in (path / 'Contents/Info.plist', path / 'Versions/B/Resources/Info.plist', path / 'Resources/Info.plist'):
        if candidate.is_file():
            return load_plist(candidate).get('CFBundleIdentifier')
    return None


def expected_identity(row, target):
    if row['key'] == 'app':
        return BUNDLE_ID, None
    if row['identifier'] or row['identifier_pattern']:
        return row['identifier'], row['identifier_pattern']
    return bundle_identifier(target / row['path']), None


def verify_app(app, expect, runner, apple_events=False, updates='off'):
    """All checks; returns (problems, per-item report). Read-only."""
    app = Path(app).absolute()
    problems, report = [], []
    require(app.name == APP_NAME and app.is_dir() and not app.is_symlink(), 'Expected a real DayDream.app')
    release.audit(app)
    deep = runner.run(['codesign', '--verify', '--strict', '--deep', '--verbose=2', app], check=False, quiet=True)
    if deep.returncode:
        problems.append('codesign --verify --strict --deep failed')
    writer = app_writer_id(app)
    problems += info_problems(load_plist(app / 'Contents/Info.plist'), writer, updates, apple_events)
    problems += lint_binaries(app, runner)
    companions = runner.run([sys.executable, '-B', SCRIPTS / 'verify-app-companions.py', app], check=False)
    if companions.returncode:
        problems.append('companion hashes do not match')
    for private in PRIVATE_PAYLOAD:
        if (app / 'Contents' / private).exists() or (app / 'Contents' / private).is_symlink():
            problems.append('private piece in a public build: ' + private)
    teams, leaves = set(), set()
    for row in SIGNING_TABLE:
        if row['mode'] == 'manifest':
            continue
        if row['mode'] == 'verify':
            writer_report, writer_problems = writer_verification(app, runner, writer)
            report += writer_report
            problems += writer_problems
            continue
        if row['optional'] and not (app / row['path']).exists():
            continue
        path = app / row['path'] if row['path'] else app
        require(path.exists(), 'Missing signed item: ' + (row['path'] or APP_NAME))
        info = inspect_signature(runner, path)
        identifier, pattern = expected_identity(row, app)
        item = signature_problems(info, expect, identifier=identifier, identifier_pattern=pattern,
                                  entitlements=expected_entitlements(row['entitlements'], apple_events))
        teams.add(info.get('TeamIdentifier'))
        leaf = None
        if expect == 'developer-id':
            leaf = leaf_sha256(runner, path)
            leaves.add(leaf)
            item += leaf_problems(leaf, writer)
        report.append(_report(row['key'], row['path'] or APP_NAME, info, item, leaf))
        problems += ['%s: %s' % (row['path'] or APP_NAME, p) for p in item]
    if len(teams) != 1:
        problems.append('Team identifiers differ across signed items: %s' % sorted(t or '' for t in teams))
    if expect == 'developer-id':
        if len(leaves) != 1:
            problems.append('Signed items use different leaf certificates')
        elif not writer and leaves != {LEAF_SHA256} and None not in leaves:
            runner.note('NOTE: leaf certificate %s is not the writer-enrolled %s. That is fine for this no-writer build '
                        '(notarization and permission grants depend on the team only); a writer build must be signed '
                        'with the enrolled certificate.' % (next(iter(leaves)), LEAF_SHA256))
        req = runner.run(['codesign', '--verify', '--strict', '-R=' + DEVELOPER_ID_REQUIREMENT, app], check=False)
        if req.returncode:
            problems.append('app does not satisfy the Developer ID + team requirement')
        dr = runner.run(['codesign', '-d', '-r-', app], quiet=True, check=False)
        text = dr.stdout + dr.stderr
        if 'identifier "%s"' % BUNDLE_ID not in text or 'leaf[subject.OU] = %s' % TEAM_ID not in text.replace('"', ''):
            problems.append('designated requirement is not identifier + team based')
    if (app / 'Contents/CodeResources').exists():
        if runner.run(['xcrun', 'stapler', 'validate', app], check=False).returncode:
            problems.append('stapled ticket does not validate')
    return problems, report


def leaf_problems(leaf, writer):
    """Developer ID leaf policy for one outer signed item (not the enrolled writer dylibs)."""
    if leaf is None:
        return ['leaf certificate could not be extracted']
    if writer and leaf != LEAF_SHA256:
        return ['leaf certificate SHA-256 %s != writer-enrolled %s (the writer denies any other host certificate, '
                'SignedRuntimePolicy.swift:56)' % (leaf, LEAF_SHA256)]
    return []


def writer_verification(app, runner, writer):
    """Enrolled writer dylibs are verified in place and never re-signed. Returns (report, problems)."""
    if not writer:
        return [], []
    try:
        manifest = json.loads((app / 'Contents' / writer_manifest_rel(app)).read_text())
        rows = {r['name']: r for r in manifest['files']}
    except (OSError, ValueError, KeyError, TypeError) as error:
        return [], ['writer manifest unreadable: %s' % error]
    report, problems = [], []
    for rel in writer_libraries(app):
        path = app / rel
        row = rows.get(path.name)
        ok = runner.run(['codesign', '--verify', '--strict', '-R=' + DEVELOPER_ID_REQUIREMENT, path], check=False).returncode == 0
        info = inspect_signature(runner, path)
        item = signature_problems(info, 'developer-id', identifier=(row or {}).get('signingIdentifier', ''), entitlements={})
        if row is None:
            item.append('writer dylib is not in the enrolled manifest')
        if not ok:
            item.append('codesign --verify --strict (Developer ID, team %s) failed' % TEAM_ID)
        leaf = leaf_sha256(runner, path)
        if leaf != LEAF_SHA256:
            item.append('writer dylib leaf certificate %s != enrolled %s' % (leaf, LEAF_SHA256))
        report.append(_report('writer-runtime', rel, info, item, leaf))
        problems += ['%s: %s' % (rel, p) for p in item]
    return report, problems


def _report(key, rel, info, problems, leaf=None):
    return {'row': key, 'path': rel, 'identifier': info.get('Identifier'), 'cdhash': info.get('CDHash'),
            'flags': sorted(info.get('flags', ())), 'team': info.get('TeamIdentifier'),
            'timestamp': info.get('Timestamp'), 'authority': (info.get('authorities') or [info.get('Signature')])[0],
            'entitlements': info.get('entitlements', {}), 'leaf_sha256': leaf, 'problems': problems}


def artifact_cdhash(runner, path):
    """CDHash of the code signature. Stapling adds a ticket but never changes it, which is what
    binds a notary receipt to the exact app or image."""
    return parse_display(runner.run(['codesign', '-dvvv', path], check=False, quiet=True).stderr).get('CDHash')


def installed_location(path):
    resolved = Path(path).resolve()
    return any(resolved == root or resolved.is_relative_to(root)
               for root in (Path('/Applications').resolve(), (Path.home() / 'Applications').resolve()))


def dmg_problems(dmg, runner, apple_events=False, updates='off', check_receipt_sha256=True):
    """Checks for a release DMG before upload or stapling. Mounts it read-only; never writes to it."""
    dmg = Path(dmg).absolute()
    problems = []
    receipt_path = Path(str(dmg) + '.receipt.json')
    try:
        receipt = json.loads(receipt_path.read_text())
    except (OSError, ValueError):
        receipt = None
        problems.append('missing or unreadable %s (build the image with `dmg`)' % receipt_path.name)
    if receipt is not None:
        if receipt.get('signature') != 'developer-id':
            problems.append('dmg receipt: the image was not signed with a Developer ID identity')
        if receipt.get('allow_unstapled_app') or receipt.get('app_stapled') is not True:
            problems.append('dmg receipt: the app was not stapled when the image was built')
        if check_receipt_sha256 and receipt.get('sha256') != sha256_file(dmg):
            problems.append('image changed since `dmg` wrote its receipt')
    if runner.run(['codesign', '--verify', '--strict', '-R=' + DEVELOPER_ID_REQUIREMENT, dmg], check=False).returncode:
        problems.append('image does not satisfy the Developer ID + team requirement')
    info = parse_display(runner.run(['codesign', '-dvvv', dmg], check=False, quiet=True).stderr)
    if not info['authorities'] or not info['authorities'][0].startswith('Developer ID Application:'):
        problems.append('image leaf authority is not Developer ID Application')
    if info.get('TeamIdentifier') != TEAM_ID:
        problems.append('image TeamIdentifier %r != %s' % (info.get('TeamIdentifier'), TEAM_ID))
    if not info.get('Timestamp'):
        problems.append('image signature has no secure timestamp')
    image_leaf = leaf_sha256(runner, dmg)
    mount = Path(tempfile.mkdtemp(prefix='daydream-dmg-check.'))
    attached = False
    try:
        runner.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', mount, dmg], quiet=True)
        attached = True
        inner = mount / APP_NAME
        if not (inner / 'Contents/CodeResources').exists():
            problems.append('the app inside the image is not stapled')
        inner_problems, report = verify_app(inner, 'developer-id', runner, apple_events, updates)
        problems += ['image app: ' + p for p in inner_problems]
        # The app that ships is the full-typing build, and only an ...-owner.dmg may hold the owner's copy.
        if not typing_app(inner):
            problems.append('image app: not the full-typing build (MacOS/MacMem lacks WebTypingRoute)')
        if not writer_payload.paths(inner):
            problems.append('image app: ' + NO_WRITER_RUNTIME)
        try:
            owner_image = dmg_owner(dmg)
        except ReleaseError as error:
            problems.append(str(error))
            owner_image = True
        if owner_app(inner) and not owner_image:
            problems.append('image app: the owner\'s private copy (Info.plist %s) in an image that is not the owner\'s '
                            '(not named -owner.dmg, or a test image whose receipt says owner_build false)' % OWNER_PLIST_KEY)
        app_leaf = next((item['leaf_sha256'] for item in report if item['row'] == 'app'), None)
        if image_leaf is None or image_leaf != app_leaf:
            problems.append('image and app are not signed with the same certificate')
    finally:
        if attached:
            runner.run(['hdiutil', 'detach', mount], check=False)
        try:
            mount.rmdir()  # never rmtree: that would reach into a volume that failed to detach
        except OSError:
            pass
    return problems


def print_report(report):
    for item in report:
        print('  %-18s %-10s team=%-10s ts=%-3s leaf=%-8s id=%s ents=%s %s' % (
            item['row'], ','.join(item['flags']), item['team'], 'yes' if item['timestamp'] else 'no',
            (item.get('leaf_sha256') or '-')[:8], item['identifier'], json.dumps(item['entitlements'], sort_keys=True),
            'OK' if not item['problems'] else 'FAIL: ' + '; '.join(item['problems'])))


# ---------------------------------------------------------------- stage
def sparkle_inventory_digest(root):
    root = Path(root)
    out = {}
    for directory, dirs, files in os.walk(root):
        for name in dirs + files:
            path = Path(directory) / name
            rel = str(path.relative_to(root))
            if path.is_symlink():
                out[rel] = 'link:' + os.readlink(path)
            elif path.is_file():
                out[rel] = hashlib.sha256(path.read_bytes()).hexdigest()
    return hashlib.sha256(json.dumps(out, sort_keys=True).encode()).hexdigest()


def install_file(source, destination, mode):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() or destination.is_symlink():
        destination.unlink()
    shutil.copyfile(source, destination)
    os.chmod(destination, mode)


# Files the app ships, copied from the extracted commit (never from the working tree).
RESOURCES = (('packaging/Daydream.icns', 'Daydream.icns'),
             ('LICENSE', 'LICENSE.txt'),
             ('NOTICE', 'NOTICE.txt'),
             ('THIRD-PARTY-NOTICES.md', 'THIRD-PARTY-NOTICES.md'),
             ('WriterBackend/Notices/llama-MIT.txt', 'llama-MIT.txt'),
             ('WriterBackend/Notices/Qwen-APACHE-2.0.txt', 'Qwen-APACHE-2.0.txt'),
             ('adapters/before_turn.py', 'before_turn.py'),
             ('adapters/launcher.example.json', 'launcher.example.json'))


def source_problems(runner, root, commit):
    """(full commit hash, problems). A release is staged only from HEAD of a clean checkout:
    no uncommitted change and no untracked file, so what is built is exactly that commit."""
    def git(*argv):
        return runner.run(['git', '-C', root] + list(argv), check=False, quiet=True)
    head = git('rev-parse', '--verify', '--quiet', 'HEAD^{commit}').stdout.strip()
    if not re.fullmatch(r'[0-9a-f]{40}', head):
        return None, ['%s is not a git checkout with a commit' % root]
    wanted = git('rev-parse', '--verify', '--quiet', (commit or 'HEAD') + '^{commit}').stdout.strip()
    problems = []
    if not re.fullmatch(r'[0-9a-f]{40}', wanted):
        problems.append('--commit %s is not a commit' % commit)
    elif wanted != head:
        problems.append('--commit %s is %s but the checkout is at %s. Check out that commit first, so the release '
                        'scripts and the build come from the same commit.' % (commit, wanted[:12], head[:12]))
    status = git('status', '--porcelain=v1', '--untracked-files=all')
    if status.returncode:
        problems.append('git status failed')
    elif status.stdout.strip():
        changed = status.stdout.strip().splitlines()
        problems.append('uncommitted or untracked changes (commit or remove them first): %s%s'
                        % (', '.join(line[3:] for line in changed[:8]), ' ...' if len(changed) > 8 else ''))
    return head, problems


def build_products(source, scratch, runner, swift_flags=()):
    """swift build -c release of the three products, from the extracted commit only. stage passes
    OWNER_SWIFT_FLAGS (the full-typing build, public and owner alike); every swift build gets them."""
    common = ['swift', 'build', '--package-path', source, '--scratch-path', scratch, '-c', 'release',
              '--disable-automatic-resolution'] + list(swift_flags)
    for product in SWIFT_BINARIES:
        runner.run(common + ['--product', product], timeout=BUILD_TIMEOUT)
    return Path(runner.run(common + ['--show-bin-path'], quiet=True).stdout.strip().splitlines()[-1])


# The full-typing build (typing-all SPEC-LATER section 3; every release since the owner's decision of
# 2026-09-25): the same two flags scripts/package.sh passes with DAYDREAM_OWNER_TYPING=1.
# OWNER_TYPING without CHROME_TYPING does not compile (Sources/MemoryCore/OwnerTypingGuard.swift).
OWNER_SWIFT_FLAGS = ('-Xswiftc', '-DDAYDREAM_OWNER_TYPING', '-Xswiftc', '-DDAYDREAM_CHROME_TYPING')
QA_SWIFT_FLAGS = ('-Xswiftc', '-DDAYDREAM_QA_HARNESS')
QA_PLIST_KEY = 'DaydreamQAHarness'
# Runtime literals, not source filenames: canonical -g retains the latter even for excluded declarations.
QA_BINARY_MARKS = (b'--capture-fixture-trial', b'qa final source amber lantern proof', b'QA normal-main Chrome metadata',
                   b'--synthetic-trial-check', b'--synthetic-writer-check', b'--synthetic-writer-restart-check',
                   b'--recording-trial', b'--functional-trial', b'Back to recording trial',
                   b'--signed-writer-acceptance', 'Signed writer acceptance · Recording OFF'.encode('utf-8'),
                   b'--isolated-interactive-trial', b'Synthetic preview', b'Open synthetic preview')
QA_SYMBOL_MARKS = (b'CaptureFixtureTrial', b'CaptureFixtureLaunch', b'CaptureChromeAutomationRequestUI',
                   b'ChromeNormalMainProbe', b'PackagedTrial', b'PackagedHistoryChecks', b'RecordingTrialReadiness',
                   b'RecordingTrialProof', b'SignedWriterTrial', b'SyntheticWindow')



# perm-1004 (owner 10/3: "about 4 DayDreams everywhere"): test copies get the public icon with a bold orange label, so
# System Settings' privacy lists, the Dock and Finder tell them apart. The public app keeps packaging/Daydream.icns.
# Made by scripts/badge-icon.swift from packaging/Daydream.iconset.
ICON_BADGES = {'TEST': 'packaging/Daydream-TEST.icns', 'QA': 'packaging/Daydream-QA.icns'}
LIVE_TEST_PLIST_KEY = 'DaydreamLiveTest'


def icon_badge(info):
    """The staged copy's icon label: QA for a QA harness copy, TEST for the Live Test copy (live-test-release.py sets
    DaydreamLiveTest), else None (the public icon)."""
    if info.get(QA_PLIST_KEY) is True:
        return 'QA'
    if info.get(LIVE_TEST_PLIST_KEY) is True:
        return 'TEST'
    return None


def icon_problems(info, icon_bytes, source):
    """The staged icon is the one its identity calls for: the public icon for every release, a badged one only for a
    QA or Live Test copy."""
    badge = icon_badge(info)
    wanted = Path(source) / (ICON_BADGES[badge] if badge else 'packaging/Daydream.icns')
    if not wanted.is_file():
        return ['missing icon %s' % wanted.name]
    if icon_bytes != wanted.read_bytes():
        return ['staged icon is not %s' % wanted.name]
    return []


def stage_swift_flags(owner, updates, qa_harness=False):
    """QA is an explicit private stage choice; owner typing alone never includes it."""
    require(not qa_harness or (owner and updates == 'off'),
            '--qa-harness requires --owner-build --updates off; never a normal release')
    return OWNER_SWIFT_FLAGS + (QA_SWIFT_FLAGS if qa_harness else ())


def qa_harness_problems(info, binary, enabled=False):
    """Bind the explicit stage choice to package metadata and executable bytes."""
    problems = []
    if enabled:
        if info.get(QA_PLIST_KEY) is not True or info.get('MacMemOwnerTyping') is not True:
            problems.append('private QA package markers missing')
        if b'--capture-fixture-trial' not in binary:
            problems.append('private QA fixture route not compiled')
    else:
        if any(key in info for key in (QA_PLIST_KEY, 'DaydreamRecordingTrial', 'DaydreamFunctionalTrial')):
            problems.append('QA harness/trial marker in a normal build')
        if any(mark in binary for mark in QA_BINARY_MARKS):
            problems.append('QA fixture/window code in a normal build')
    return problems
def qa_code_symbol_problems(symbols, enabled=False):
    """Inspect actual Mach-O symbols; nm's multi-file headings and DWARF source paths are not code."""
    lines = [line for line in symbols.splitlines() if line.startswith(b'_')]
    if not enabled and any(mark in line for mark in QA_SYMBOL_MARKS for line in lines):
        return ['QA fixture/window symbol in a normal build']
    return []

# Bytes the full-typing binaries carry: the website typing route and join (compiled only with the
# flags above), and package.sh's owner banner (never in a staged app).
OWNER_STAGE_MARKS = (b'WebTypingRoute', b'BrowserTypingJoin', b'OWNER BUILD')
# What every stage needs (typing really compiled in).
TYPING_MARK = 'MacOS/MacMem carries WebTypingRoute'


def owner_markers(app):
    """Every marker in a staged app: the Info.plist owner key (any value) and full-typing bytes
    in any of the three Swift binaries."""
    contents = Path(app) / 'Contents'
    found = []
    info = contents / 'Info.plist'
    if info.is_file() and OWNER_PLIST_KEY in plistlib.loads(info.read_bytes()):
        found.append('Info.plist has %s' % OWNER_PLIST_KEY)
    for name in SWIFT_BINARIES:
        path = contents / 'MacOS' / name
        data = path.read_bytes() if path.is_file() else b''
        found += ['MacOS/%s carries %s' % (name, mark.decode()) for mark in OWNER_STAGE_MARKS if mark in data]
    return found


def writer_source(source, runner):
    """The signed "On this Mac" runtime in an extracted commit, checked the way the app will check it:
    the manifest SHA-256 equals the pin compiled into that commit's SignedRuntimePolicy.swift, every field
    matches the commit's MacOS15Runtime pins, each library's bytes match the manifest and pass the loader's
    Mach-O rule, and each is Developer ID signed (team, leaf certificate, hardened runtime, timestamp,
    exact identifier, no entitlements). Returns (manifest path, rows). Raises ReleaseError."""
    try:
        manifest, rows = writer_payload.source_files(source)
    except ValueError as error:
        raise ReleaseError(str(error))
    problems = []
    for name, path, row in rows:
        ok = runner.run(['codesign', '--verify', '--strict', '-R=' + DEVELOPER_ID_REQUIREMENT, path], check=False).returncode == 0
        info = inspect_signature(runner, path)
        item = signature_problems(info, 'developer-id', identifier=row['signingIdentifier'], entitlements={})
        if not ok:
            item.append('codesign --verify --strict (Developer ID, team %s) failed' % TEAM_ID)
        leaf = leaf_sha256(runner, path)
        if leaf != LEAF_SHA256:
            item.append('leaf certificate %s != enrolled %s' % (leaf, LEAF_SHA256))
        problems += ['%s: %s' % (name, p) for p in item]
    require(not problems, 'Writer runtime signatures refused:\n  ' + '\n  '.join(problems))
    return manifest, rows


def cmd_stage(args, runner=None, root=ROOT, builder=build_products, sparkle_dir=SPARKLE_DIR):
    runner = runner or Runner()
    root = Path(root)
    out = Path(args.out).absolute()
    require(not out.exists(), 'Output directory must not exist: %s' % out)
    require(not out.is_relative_to(root.resolve()) and not out.is_relative_to(root),
            'Output must be outside the repository (%s)' % root)
    require(re.fullmatch(r'[1-9][0-9]{0,19}', args.build or '') and int(args.build) < 2 ** 64, '--build must be a positive integer (UInt64)')
    template = load_plist(root / 'packaging/Info.plist')
    version = args.version or template['CFBundleShortVersionString']
    require(re.fullmatch(VERSION_RE, version), '--version must be numeric x.y[.z] (" Beta" is added by stage)')
    # An update only goes to a higher build (Sparkle compares CFBundleVersion), and two copies with one build number
    # can't be told apart. So every stage names the build it follows, or says it is the very first.
    first = bool(getattr(args, 'first_build', False))
    require(first != (args.previous_build is not None),
            'Pass --previous-build <the CFBundleVersion of the last copy anyone installed> (--build must exceed it), '
            'or --first-build for the very first build')
    if args.previous_build is not None:
        require(args.previous_build >= 1, '--previous-build must be a positive build number')
        require(int(args.build) > args.previous_build, '--build %s must exceed the previous release build %s' % (args.build, args.previous_build))
    update_data = release.config(root / 'packaging/updates.json') if args.updates == 'configured' else None
    chrome_pages = chrome_page_history_switch(root)
    owner = bool(getattr(args, 'owner_build', False))
    qa_harness = bool(getattr(args, 'qa_harness', False))
    swift_flags = stage_swift_flags(owner, args.updates, qa_harness)
    require(QA_PLIST_KEY not in template, 'QA marker belongs only to explicit staging, never source Info.plist')
    require(owner or os.environ.get('DAYDREAM_OWNER_TYPING', '') in ('', '0'),
            'DAYDREAM_OWNER_TYPING is set in the environment, but this is a public stage. A public release never '
            'carries the owner switch; pass --owner-build only for the owner\'s own test build.')
    scratch = Path(args.scratch).absolute() if args.scratch else out / ('build-owner' if owner else 'build')
    # Owner and public builds never share a SwiftPM scratch folder (as package.sh's .build-owner).
    require(scratch.name.endswith('-owner') == owner,
            '--scratch for an owner stage must end in "-owner", and a public stage must not use one that does')
    # The owner's private copy never takes public updates: it stays the build the owner installed until
    # they install the next one by hand.
    require(not owner or args.updates == 'off',
            'OWNER BUILD: pass --updates off. An owner build must not read the public update feed, or the next public '
            'release would replace it.')
    commit, problems = source_problems(runner, root, args.commit)
    require(not problems, 'Refusing to stage:\n  ' + '\n  '.join(problems))
    # "On this Mac" ships in every build (owner decision 2026-09-26). The checkout is clean and at the commit,
    # so refuse here, before anything is built, when its signed runtime is missing or not pinned; the
    # extracted commit is checked again below, signatures included, and that copy is what ships.
    without_writer = bool(getattr(args, 'without_writer_runtime_for_tests', False))
    if not without_writer:
        require(writer_payload.source_present(root), writer_payload.NOT_SIGNED)
        try:
            writer_payload.source_files(root)
        except ValueError as error:
            raise ReleaseError(str(error))
    without_search = bool(getattr(args, 'without_search_runtime_for_tests', False))
    search_inputs = Path(getattr(args, 'typesense_inputs', None) or root / 'Vendor/Typesense-30.2').resolve()
    source_kit = None
    if not without_search:
        search_payload.source_files(root, search_inputs)
        # Typesense (GPL-3.0) goes to the public, and so may take updates, only with this commit's cleared public
        # record (owner decision 2026-10-03) and the Complete Corresponding Source kit in hand, byte for byte the
        # recorded one: it is attached to the GitHub release next to the DMG (GPLv3 6(d)). Updates off needs neither.
        if args.updates != 'off':
            require(search_payload.public_cleared(json.loads((root / search_payload.SOURCE_DIR / 'local-typesense-v30.2.json').read_text())),
                    'Local Typesense copy: pass --updates off; public distribution is not cleared by this commit')
            require(getattr(args, 'typesense_source_kit', None),
                    'Public Typesense stage: pass --typesense-source-kit <path to %s> (sha256 %s); it is attached to the '
                    'release next to the DMG' % (search_payload.SOURCE_KIT_NAME, search_payload.SOURCE_KIT_SHA256))
            source_kit = search_payload.verify_source_kit(Path(args.typesense_source_kit).absolute())
    require(not bootstrap_sparkle.folder_problems(sparkle_dir, bootstrap_sparkle.pin()),
            'Vendor Sparkle is not the pinned copy: run python3 scripts/bootstrap-sparkle.py')
    require(sparkle_inventory_digest(Path(sparkle_dir) / SPARKLE_VENDOR.relative_to(SPARKLE_DIR)) == SPARKLE_INVENTORY_SHA256,
            'Vendor Sparkle framework differs from pin')

    out.mkdir(parents=True)
    source, archive = out / 'source', out / 'source.tar'
    # The commit, exactly: git archive has no untracked, ignored or modified files.
    runner.run(['git', '-C', root, 'archive', '--format=tar', '-o', archive, commit])
    source.mkdir()
    runner.run(['tar', '-xf', archive, '-C', source])
    # Sparkle is not in git (Vendor/ is ignored); the build and the app use the pinned copy.
    runner.run(['ditto', sparkle_dir, source / 'Vendor' / Path(sparkle_dir).name])
    if without_writer:
        print('TEST BUILD: no "On this Mac" runtime (--without-writer-runtime-for-tests). It can never be released.')
        writer_files = None
    else:
        writer_files = writer_source(source, runner)
    print('Typing in more apps and on websites compiled in (%s).' % ' '.join(OWNER_SWIFT_FLAGS))
    if owner:
        print("OWNER BUILD: the owner's private test copy (updates off). Not a public release.")
    bin_dir = Path(builder(source, scratch, runner, swift_flags=swift_flags))
    receipt = {'schema': 2, 'source_commit': commit, 'source_archive_sha256': sha256_file(archive),
               'build': args.build, 'previous_build': args.previous_build, 'first_build': first,
               'version': version, 'beta': args.beta, 'updates': args.updates,
               'chrome_page_history': chrome_pages, 'owner_build': owner, 'qa_harness': qa_harness, 'swift_flags': list(swift_flags),
               'bin_dir': str(bin_dir), 'products': {}, 'writer_runtime': None,
               'test_only_without_writer_runtime': without_writer,
               'test_only_without_search_runtime': without_search, 'search_runtime': None,
               'typesense_source_kit': None if source_kit is None else {'name': source_kit.name, 'sha256': search_payload.SOURCE_KIT_SHA256,
                                                                         'bytes': search_payload.SOURCE_KIT_BYTES}}

    target = out / APP_NAME
    contents = target / 'Contents'
    # 1. Swift binaries, all three built from the commit. Nothing is taken from another app.
    for name in SWIFT_BINARIES:
        built = bin_dir / name
        require(built.is_file() and not built.is_symlink(), 'Build did not produce %s' % name)
        require('arm64' in macho_archs(built), 'Built %s is not an arm64 Mach-O' % name)
        install_file(built, contents / 'MacOS' / name, 0o755)
        receipt['products'][name] = sha256_file(contents / 'MacOS' / name)
    # 2. Pinned Sparkle.
    runner.run(['ditto', source / 'Vendor' / Path(sparkle_dir).name / SPARKLE_VENDOR.relative_to(SPARKLE_DIR),
                contents / 'Frameworks/Sparkle.framework'])
    # 3. Resources and licences from the commit.
    resources = contents / 'Resources'
    for rel, name in RESOURCES:
        install_file(source / rel, resources / name, 0o644)
    install_file(source / 'Vendor' / Path(sparkle_dir).name / 'LICENSE', resources / 'Sparkle-LICENSE.txt', 0o644)
    # SwiftPM's MemoryUI bundle is built from the same exact archived commit.
    ui_resources = bin_dir / 'MacMem_MemoryUI.bundle'
    require(ui_resources.is_dir() and not ui_resources.is_symlink(), 'Build did not produce MemoryUI resources')
    runner.run(['ditto', ui_resources, resources / 'MacMem_MemoryUI.bundle'])
    # 3b. The "On this Mac" runtime, byte for byte from the commit: never re-signed, no extended attributes.
    if writer_files:
        manifest, rows = writer_files
        install_file(manifest, contents / writer_payload.MANIFEST, 0o644)
        for name, path, row in rows:
            destination = contents / writer_payload.LIBROOT / name
            install_file(path, destination, 0o755)
            require(sha256_file(destination) == row['signedSHA256'], 'Copy of %s changed' % name)
        receipt['writer_runtime'] = {'id': writer_payload.ID, 'manifest_sha256': sha256_file(manifest),
                                     'files': {name: row['signedSHA256'] for name, _, row in rows}}
    # 4. Info.plist = the commit's packaging/Info.plist + release fields + update settings.
    writer_id = writer_payload.ID if writer_files else None
    info = release_info(load_plist(source / 'packaging/Info.plist'), args.build, version, args.min_macos, writer_id,
                        args.updates, update_data, args.beta, chrome_pages)
    if owner:
        info[OWNER_PLIST_KEY] = True
    if qa_harness:
        info[QA_PLIST_KEY] = True
    if without_search:
        info[search_payload.TEST_ONLY_KEY] = True
    else:
        require(search_payload.TEST_ONLY_KEY not in info, 'Test-only search marker in source Info.plist')
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    receipt['info_plist'] = info
    # 4b. perm-1004: a QA or Live Test copy gets its labelled icon (same file name, so nothing else changes).
    badge = icon_badge(info)
    if badge:
        install_file(source / ICON_BADGES[badge], resources / 'Daydream.icns', 0o644)
        print('TEST COPY ICON: %s badge (%s).' % (badge, ICON_BADGES[badge]))
    receipt['icon_badge'] = badge
    # 5. Toolchain rpaths (Command Line Tools) are removed before any signing.
    for name in SWIFT_BINARIES:
        path = contents / 'MacOS' / name
        for rpath in parse_rpaths(runner.run(['otool', '-l', path], quiet=True).stdout):
            if rpath.startswith(TOOLCHAIN_RPATH_PREFIXES):
                runner.run(['install_name_tool', '-delete_rpath', rpath, path])
    if not without_search:
        receipt['search_runtime'] = search_payload.assemble(target, source, search_inputs)
    release.manifest(target, source_commit=commit)
    release.audit(target)
    problems = info_problems(info, writer_id, args.updates, chrome_pages, update_data) + lint_binaries(target, runner) + xattr_problems(target, runner)
    # claude/crashguard-015: macOS 15.0 in Info.plist and Package.swift, arm64-only Swift products built for 15.0.
    problems += release.package_platform_problems(source) + release.platform_problems(target)
    problems += qa_harness_problems(info, (contents / 'MacOS/MacMem').read_bytes(), qa_harness)
    problems += icon_problems(info, (resources / 'Daydream.icns').read_bytes(), source)
    if not qa_harness:
        symbols = runner.run(['/usr/bin/nm', '-j', contents / 'MacOS/MacMem'], check=False, quiet=True)
        if symbols.returncode != 0:
            problems.append('normal QA code-symbol inspection failed')
        else:
            problems += qa_code_symbol_problems(symbols.stdout.encode('utf-8'))
    if writer_id and app_writer_id(target) != writer_id:
        problems.append('the "On this Mac" runtime is not in place in the staged app')
    problems += ['private piece in a public build: ' + p for p in PRIVATE_PAYLOAD if (contents / p).exists()]
    markers = owner_markers(target)
    if owner:
        # The flags really compiled typing in, and the app says it is the owner's copy.
        problems += ['owner build without %s' % need for need in ('Info.plist has %s' % OWNER_PLIST_KEY, TYPING_MARK)
                     if need not in markers]
    else:
        # The flags really compiled typing in; nothing marks it as the owner's copy.
        problems += ['full-typing build without %s' % TYPING_MARK] if TYPING_MARK not in markers else []
        problems += ['owner marker in a public build: ' + m for m in markers
                     if m.startswith('Info.plist has ') or m.endswith(' carries OWNER BUILD')]
    require(not problems, 'Staged app fails pre-sign checks:\n  ' + '\n  '.join(problems))
    receipt['commands'] = runner.records if hasattr(runner, 'records') else []
    receipt['macos_sha256'] = {name: sha256_file(contents / 'MacOS' / name) for name in sorted(os.listdir(contents / 'MacOS'))}
    (out / 'stage-receipt.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
    print('STAGED%s (unsigned outer) from commit %s: %s' % (' OWNER BUILD' if owner else '', commit, target))
    print('On this Mac runtime: %s' % (writer_payload.ID + ' (signed, unchanged)' if writer_id
                                       else 'NONE. TEST BUILD ONLY: never release it.'))
    return 0


# ---------------------------------------------------------------- sign
def cmd_sign(args):
    runner = Runner()
    kind = identity_kind(args.identity)
    source = Path(args.app).absolute()
    out = Path(args.out).absolute()
    require(source.name == APP_NAME and source.is_dir() and not source.is_symlink(), 'Expected a staged DayDream.app')
    require(not out.exists(), 'Output directory must not exist: %s' % out)
    require(not out.is_relative_to(source) and not source.is_relative_to(out), 'Output must be separate from the input')
    lint_entitlements(runner)
    release.audit(source)
    if search_payload.present(source):
        require(args.updates == 'off' or search_payload.public_cleared_app(source),
                'Local Typesense copy requires updates off unless its distribution record is the cleared public one')
        require(sha256_file(source / 'Contents' / search_payload.SERVER) == search_payload.SERVER_SHA256,
                'Unreviewed unsigned Typesense input: stage a fresh local copy')
    out.mkdir(parents=True)
    target = out / APP_NAME
    contents = target / 'Contents'
    runner.run(['ditto', source, target])
    bad = xattr_problems(target, runner)
    require(not bad, 'Extended attributes present (re-run stage):\n  ' + '\n  '.join(bad[:20]))
    for stale in (contents / '_CodeSignature', contents / 'CodeResources'):
        if stale.exists():
            runner.note('removing obsolete %s on the copy' % stale.name)
            shutil.rmtree(stale) if stale.is_dir() else stale.unlink()

    writer = app_writer_id(target)
    problems = info_problems(load_plist(contents / 'Info.plist'), writer, args.updates, args.apple_events)
    problems += lint_binaries(target, runner)
    problems += [] if typing_app(target) else ['not the full-typing build: MacOS/MacMem lacks WebTypingRoute (stage it with `stage`)']
    if sparkle_inventory_digest(contents / 'Frameworks/Sparkle.framework') != SPARKLE_INVENTORY_SHA256:
        problems.append('Sparkle.framework is not the pinned vendor framework (run stage first)')
    require(not problems, 'Pre-sign checks failed:\n  ' + '\n  '.join(problems))

    steps = sign_steps(target, args.identity, args.apple_events, python=sys.executable)
    for step in steps:
        if step['action'] == 'manifest':
            runner.note('release.py manifest (companion hashes over the signed helper bytes)')
            release.manifest(target)
        else:
            runner.run(step['argv'], timeout=CODESIGN_TIMEOUT)
    expect = 'adhoc' if kind == 'adhoc' else 'developer-id'
    problems, report = verify_app(target, expect, runner, args.apple_events, args.updates)
    print_report(report)
    receipt = {'schema': 1, 'input': str(source), 'app': str(target), 'identity_kind': kind,
               'identity_sha1': None if kind == 'adhoc' else args.identity.upper(),
               'options': {'apple_events': args.apple_events, 'updates': args.updates}, 'owner_build': owner_app(target),
               'steps': [s['argv'] for s in steps], 'items': report, 'problems': problems, 'commands': runner.records}
    (out / 'sign-receipt.json').write_text(json.dumps(receipt, indent=2, sort_keys=True, default=list) + '\n')
    require(not problems, 'Post-sign verification failed:\n  ' + '\n  '.join(problems))
    print('SIGNED (%s): %s' % (kind, target))
    return 0


# ---------------------------------------------------------------- verify
def cmd_verify(args):
    runner = Runner()
    problems, report = verify_app(args.app, args.expect, runner, args.apple_events, args.updates)
    print_report(report)
    if args.json:
        Path(args.json).write_text(json.dumps({'app': str(Path(args.app).absolute()), 'expect': args.expect, 'items': report,
                                               'problems': problems, 'commands': runner.records},
                                              indent=2, sort_keys=True, default=list) + '\n')
    if problems:
        print('VERIFY FAILED:\n  ' + '\n  '.join(problems))
        return 1
    print('VERIFY OK (%s): %s' % (args.expect, Path(args.app).absolute()))
    return 0


# ---------------------------------------------------------------- dmg
def dmg_name(short_version, owner=False):
    """The download: DayDream-<x.y.z>.dmg (the numeric version, no build number). The owner's own
    test build is DayDream-<x.y.z>-owner.dmg, so notarize can tell it apart without mounting it."""
    return 'DayDream-%s%s.dmg' % (release.version_core(short_version), '-owner' if owner else '')


# A test build's image has a name of its own (golden test 5 on), so a test copy never has the file or volume name
# of the release or of an earlier test: "DayDream - Saturday test 5.dmg", volume "DayDream - Saturday test 5".
# Such an image is never a public release (notes refuse it), and whether it holds the owner's copy is read from
# the receipt `dmg` writes next to it (its name doesn't say).
TEST_DMG_RE = r'DayDream - [A-Za-z0-9][A-Za-z0-9 ._()-]{0,60}\.dmg'
VOLUME_NAME_RE = r'DayDream(?: [A-Za-z0-9 ._()-]{1,60})?'
RELEASE_VOLUME_NAME = 'DayDream'


def test_dmg_name(name):
    """True for a test build's own image name (dmg --name)."""
    return bool(re.fullmatch(TEST_DMG_RE, name or '')) and '  ' not in name and not name.endswith(' .dmg')


def volume_name_ok(name):
    return bool(re.fullmatch(VOLUME_NAME_RE, name or '')) and '  ' not in name and not name.endswith(' ')


def dmg_target(out, name, volume, short_version, owner=False):
    """(path of the new image, its volume name). A release image is DayDream-<x.y.z>[-owner].dmg on the volume
    "DayDream". A test image (`name`) is that name, at --out (a folder, or a path ending in the name), on its own
    volume (default: the name without .dmg)."""
    out = Path(out).absolute()
    if name is None:
        expected = dmg_name(short_version, owner)
        require(out.name == expected, 'The DMG must be named %s (from the app version %r), or give a test build its '
                'own name with --name "DayDream - <words>.dmg"' % (expected, short_version))
        require(volume in (None, RELEASE_VOLUME_NAME), '--volume-name is for a test image (--name); a release image '
                'is always on the volume %r' % RELEASE_VOLUME_NAME)
        return out, RELEASE_VOLUME_NAME
    require(test_dmg_name(name), '--name must be "DayDream - <letters, digits, spaces>.dmg", for example '
            '"DayDream - Saturday test 5.dmg"; got %r' % name)
    target = out / name if out.is_dir() else out
    require(target.name == name, '--out must be an existing folder or a path ending in %s' % name)
    volume = volume or name[:-len('.dmg')]
    require(volume_name_ok(volume) and volume != RELEASE_VOLUME_NAME,
            '--volume-name must start with "DayDream " and differ from the release volume %r; got %r'
            % (RELEASE_VOLUME_NAME, volume))
    return target, volume


def dmg_owner(dmg):
    """Whether an image holds the owner's private copy, without mounting it: a release image by its name
    (...-owner.dmg), a test image by the receipt `dmg` wrote next to it."""
    dmg = Path(dmg)
    if not test_dmg_name(dmg.name):
        return dmg.name.endswith('-owner.dmg')
    try:
        owner = json.loads(Path(str(dmg) + '.receipt.json').read_text()).get('owner_build')
    except (OSError, ValueError):
        raise ReleaseError('%s is a test image: keep the %s.receipt.json that `dmg` wrote next to it' % (dmg.name, dmg.name))
    require(isinstance(owner, bool), '%s.receipt.json does not say whether it holds the owner\'s copy' % dmg.name)
    return owner


def dmg_label(short_version):
    """Second line of the DMG background, under the drag hint: 'DayDream 0.1.0 Beta'."""
    require(re.fullmatch(SHORT_VERSION_RE, short_version or ''), 'Bad app version %r' % short_version)
    return 'DayDream ' + short_version


def tree_megabytes(root):
    total = 0
    for directory, dirs, files in os.walk(root):
        for name in files:
            total += os.lstat(os.path.join(directory, name)).st_size
    return total // (1 << 20) + 1


def cmd_dmg(args):
    import check_dmg_layout
    runner = Runner()
    app = Path(args.app).absolute()
    require(app.name == APP_NAME and app.is_dir(), 'Expected a signed DayDream.app')
    owner = bool(getattr(args, 'owner_build', False))
    refuse_owner_artifact(app, owner)
    short_version = load_plist(app / 'Contents/Info.plist').get('CFBundleShortVersionString', '')
    dmg, volume = dmg_target(args.out, getattr(args, 'name', None), getattr(args, 'volume_name', None), short_version, owner)
    require(not dmg.exists() and dmg.parent.is_dir(), 'DMG must be new, in an existing directory')
    require(bool(args.unsigned) != bool(args.identity), 'Pass exactly one of --identity or --unsigned')
    kind = None if args.unsigned else identity_kind(args.identity)
    # A Developer ID image is a release candidate: it carries "On this Mac", like every release.
    require(kind != 'developer-id' or writer_payload.paths(app), NO_WRITER_RUNTIME)
    runner.run(['codesign', '--verify', '--deep', '--strict', app])
    runner.run([sys.executable, '-B', SCRIPTS / 'verify-app-companions.py', app])
    app_stapled = (app / 'Contents/CodeResources').exists()
    if kind == 'developer-id':
        runner.run(['codesign', '--verify', '--strict', '-R=' + DEVELOPER_ID_REQUIREMENT, app])
        require(app_stapled or args.allow_unstapled_app,
                'Release DMGs are built from the stapled app (or pass --allow-unstapled-app; notarize then refuses the image)')
    # Everything is built inside work/ (same volume as the target) and moved to the final
    # name only after every post-check passes; a failure leaves no image at --out.
    work = Path(tempfile.mkdtemp(prefix='dmg-work.', dir=dmg.parent))
    root, mount, check = work / 'root', work / 'mount', work / 'check'
    partial = work / dmg.name
    rw = work / 'rw.dmg'
    try:
        for folder in (root, mount, check):
            folder.mkdir()
        runner.run(['ditto', app, root / APP_NAME])
        (root / 'Applications').symlink_to('/Applications')
        size = tree_megabytes(root) + 40  # headroom for the ~5 MB .background.tiff and .DS_Store
        runner.run(['hdiutil', 'create', '-srcfolder', root, '-volname', volume, '-fs', 'HFS+', '-format', 'UDRW', '-size', '%dm' % size, rw])
        attached = False
        try:
            runner.run(['hdiutil', 'attach', rw, '-nobrowse', '-noautoopen', '-mountpoint', mount], quiet=True)
            attached = True
            runner.run(['swift', SCRIPTS / 'dmg-background.swift', mount, work / 'background.alias', dmg_label(short_version)])
            runner.run([sys.executable, SCRIPTS / 'dmg-layout.py', mount, work / 'background.alias'])
            shutil.rmtree(mount / '.fseventsd', ignore_errors=True)
            runner.run(['hdiutil', 'detach', mount])
            attached = False
        finally:
            if attached:
                runner.run(['hdiutil', 'detach', '-force', mount], check=False)
        runner.run(['hdiutil', 'convert', rw, '-format', 'UDZO', '-o', partial], quiet=True)
        runner.run(['hdiutil', 'verify', partial], quiet=True)
        if kind:
            # Developer ID Application on the image: no hardened runtime, no entitlements.
            runner.run(codesign_sign_argv(args.identity, partial, runtime=False), timeout=CODESIGN_TIMEOUT)
            runner.run(['codesign', '--verify', '--strict', '--verbose=2', partial])
        # Read-only post-check of the final image.
        attached = False
        try:
            runner.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', check, partial], quiet=True)
            attached = True
            check_dmg_layout.check_volume(check)
            require(check_dmg_layout.inventory(check / APP_NAME) == check_dmg_layout.inventory(app),
                    'App inside the image differs from the signed app')
            runner.run(['codesign', '--verify', '--deep', '--strict', check / APP_NAME])
        finally:
            if attached:
                runner.run(['hdiutil', 'detach', check], check=False)
        require(not os.path.ismount(check), 'Could not detach %s' % check)
        require(not dmg.exists(), 'DMG appeared at the target while building: %s' % dmg)
        os.rename(partial, dmg)
    finally:
        if os.path.ismount(mount) or os.path.ismount(check):
            print('WARNING: an image is still attached under %s; detach it with hdiutil, then delete that directory' % work,
                  file=sys.stderr)
        else:
            shutil.rmtree(work, ignore_errors=True)
    receipt = {'schema': 2, 'app': str(app), 'dmg': str(dmg), 'name': dmg.name, 'volume_name': volume,
               'test_image': test_dmg_name(dmg.name), 'owner_build': owner, 'sha256': sha256_file(dmg),
               'signature': kind or 'unsigned', 'app_stapled': app_stapled,
               'allow_unstapled_app': bool(args.allow_unstapled_app), 'app_cdhash': artifact_cdhash(runner, app),
               'image_cdhash': artifact_cdhash(runner, dmg) if kind else None, 'commands': runner.records}
    Path(str(dmg) + '.receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print('DMG (%s): %s\nSHA-256 before stapling (not the download checksum; staple writes that): %s'
          % (kind or 'unsigned', dmg, receipt['sha256']))
    return 0


# ---------------------------------------------------------------- notarize / staple
def artifact_kind(path):
    require(path.suffix in ('.app', '.dmg'), 'Artifact must be a .app or a .dmg')
    return path.suffix[1:]


# The owner's private copy (stage --owner-build, or scripts/package.sh with
# DAYDREAM_OWNER_TYPING=1) marks its Info.plist. Every release carries the
# website typing route, so only that key tells the owner's copy apart. It never
# goes out as a public release by mistake: dmg and notarize refuse it unless
# --owner-build is given, and an owner DMG is named ...-owner.dmg so notarize
# can tell it apart without mounting it.
OWNER_PLIST_KEY = 'MacMemOwnerTyping'


def owner_app(app):
    """True when `app` is the owner's private copy (the Info.plist key)."""
    info = app / 'Contents/Info.plist'
    if info.is_file():
        try:
            if plistlib.loads(info.read_bytes()).get(OWNER_PLIST_KEY) is True:
                return True
        except (plistlib.InvalidFileException, ValueError, OSError):
            raise ReleaseError('Unreadable Info.plist in %s' % app)
    return False


def typing_app(app):
    """True when `app`'s MacMem was built with typing in apps and on websites (every stage compiles it in:
    OWNER_SWIFT_FLAGS). An app without it (a narrow build from before the owner's decision of 2026-09-25, or
    a package.sh build without DAYDREAM_OWNER_TYPING=1) contradicts the published typing claims and would
    narrow typing for people who update, so no step after stage accepts it."""
    binary = Path(app) / 'Contents/MacOS/MacMem'
    return binary.is_file() and OWNER_STAGE_MARKS[0] in binary.read_bytes()


NO_WRITER_RUNTIME = ('no "On this Mac" runtime inside (a --without-writer-runtime-for-tests stage). Test builds are '
                     'never released; stage from a commit with the signed runtime (RELEASE.md, "Writer runtime").')
NARROW_BUILD = ('Not the full-typing build: %s has no website typing code (MacOS/MacMem lacks WebTypingRoute). '
                'Stage it with developer-id-release.py stage.')


def refuse_owner_artifact(artifact, owner_build):
    """Refuses an owner build without --owner-build, --owner-build on a public one, and an app that is not
    the full-typing build (a DMG's app is checked when `dmg` builds it and when the image is checked)."""
    if artifact.suffix == '.dmg':
        owner = dmg_owner(artifact)
    elif artifact.is_dir():
        owner = owner_app(artifact)
        require(typing_app(artifact), NARROW_BUILD % artifact.name)
    else:
        return
    require(owner_build or not owner,
            'OWNER BUILD: %s is the owner\'s private test copy (updates off). It is not a public release; '
            'pass --owner-build only for that copy.' % artifact.name)
    require(owner or not owner_build, '--owner-build given, but %s is not an owner build' % artifact.name)


def notarize_commands(artifact, out, profile):
    kind = artifact_kind(artifact)
    submit = out / 'notary-app.zip' if kind == 'app' else artifact
    commands = []
    if kind == 'app':
        commands.append(['ditto', '-c', '-k', '--keepParent', str(artifact), str(submit)])
    commands.append(['xcrun', 'notarytool', 'submit', str(submit), '--keychain-profile', profile, '--wait', '--timeout', NOTARY_WAIT,
                     '--output-format', 'json'])
    commands.append(['xcrun', 'notarytool', 'log', '<submission-id>', '--keychain-profile', profile,
                     str(out / ('notary-%s-log-<submission-id>.json' % kind))])
    return kind, submit, commands


def notary_wait_command(submission, profile):
    return ['xcrun', 'notarytool', 'wait', submission, '--keychain-profile', profile, '--timeout', NOTARY_WAIT, '--output-format', 'json']


def parse_notary_json(text, returncode, what):
    try:
        value = json.loads(text)
    except ValueError:
        raise ReleaseError('notarytool %s returned no JSON (exit %d); see the output above' % (what, returncode))
    require(isinstance(value, dict), 'notarytool %s returned unexpected JSON' % what)
    return value


def signing_flags(args):
    return ((['--apple-events'] if args.apple_events else ['--no-apple-events']) +
            (['--updates', args.updates] if args.updates != 'configured' else []))


def cmd_notarize(args):
    artifact = Path(args.artifact).absolute()
    out = Path(args.out).absolute()
    profile = args.keychain_profile or DEFAULT_NOTARY_PROFILE
    # Before anything is printed or run.
    refuse_owner_artifact(artifact, getattr(args, 'owner_build', False))
    kind, submit, commands = notarize_commands(artifact, out, profile)
    base = ['python3', str(Path(__file__).resolve()), 'notarize', '--artifact', str(artifact), '--out', str(out),
            '--keychain-profile', profile] + signing_flags(args) + (['--owner-build'] if getattr(args, 'owner_build', False) else [])
    if not args.execute:
        print('PRINT-ONLY: nothing was executed or uploaded. After the owner approves this upload, run')
        print('  ' + shlex.join(base + ['--execute']))
        print('which runs:')
        for argv in commands:
            print('  ' + shlex.join(argv))
        print('and requires status "Accepted" and a log with no issues. If the wait times out or the connection drops after')
        print('the upload, keep waiting on the saved submission without uploading again:')
        print('  ' + shlex.join(base + ['--resume', '--execute']))
        return 0
    require(args.keychain_profile and re.fullmatch(r'[A-Za-z0-9._-]+', args.keychain_profile), '--execute requires --keychain-profile NAME')
    require(artifact.exists(), 'Missing artifact')
    refuse_owner_artifact(artifact, getattr(args, 'owner_build', False))
    result_path = out / ('notary-%s.json' % kind)
    receipt_path = out / ('notary-%s-receipt.json' % kind)
    # File-state refusals come first: nothing runs when a step is re-run in the wrong mode.
    if args.resume:
        require(receipt_path.is_file() and result_path.is_file(),
                'Nothing to resume in %s. If an upload may have reached Apple, the owner checks '
                '`xcrun notarytool history --keychain-profile %s` before any new upload.' % (out, profile))
        receipt = json.loads(receipt_path.read_text())
        submission = parse_notary_json(result_path.read_text(), 0, 'submit').get('id')
        require(isinstance(submission, str) and re.fullmatch(r'[0-9A-Fa-f-]{36}', submission), 'No submission id saved in %s' % result_path)
    else:
        for existing in (result_path, receipt_path):
            require(not existing.exists(), 'A previous attempt exists (%s). Use --resume to keep waiting on its submission; '
                                           'never upload again without checking it.' % existing)
    runner = Runner()
    cdhash = artifact_cdhash(runner, artifact)
    require(cdhash, 'Artifact has no code signature')
    if args.resume:
        require(receipt.get('artifact_cdhash') == cdhash, 'The artifact is not the one that was submitted (CDHash differs)')
        digest = receipt.get('sha256')
        proc = runner.run(notary_wait_command(submission, profile), check=False, quiet=True, timeout=NOTARY_PROCESS_TIMEOUT)
        (out / ('notary-%s-wait-%s.json' % (kind, submission))).write_text(proc.stdout)
        result = parse_notary_json(proc.stdout, proc.returncode, 'wait')
    else:
        if kind == 'app':
            problems, report = verify_app(artifact, 'developer-id', runner, args.apple_events, args.updates)
            print_report(report)
        else:
            problems = dmg_problems(artifact, runner, args.apple_events, args.updates)
        require(not problems, 'Refusing to upload: checks failed:\n  ' + '\n  '.join(problems))
        out.mkdir(parents=True, exist_ok=True)
        if kind == 'app':
            require(not submit.exists(), 'Refusing to overwrite %s' % submit)
            runner.run(commands[0])
        digest = sha256_file(submit)
        receipt = {'artifact': str(artifact), 'artifact_cdhash': cdhash, 'submitted': str(submit), 'sha256': digest,
                   'status': 'uploading'}
        # Written before the upload so --resume can bind to this artifact even if this process dies.
        receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
        runner.note('uploading %s (sha256 %s)' % (submit, digest))
        proc = runner.run(commands[-2], check=False, quiet=True, timeout=NOTARY_PROCESS_TIMEOUT)
        result_path.write_text(proc.stdout)
        result = parse_notary_json(proc.stdout, proc.returncode, 'submit')
    submission, status = result.get('id'), result.get('status')
    log_path = out / ('notary-%s-log-%s.json' % (kind, submission))
    if submission and status in TERMINAL_NOTARY_STATUSES and not log_path.exists():
        runner.run(['xcrun', 'notarytool', 'log', submission, '--keychain-profile', profile, log_path], check=False, timeout=600)
    receipt.update(submission=submission, status=status, result=result, log=str(log_path) if log_path.exists() else None,
                   commands=receipt.get('commands', []) + runner.records)
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
    if submission and status not in TERMINAL_NOTARY_STATUSES:
        raise ReleaseError('Submission %s is %r (not finished). Nothing needs uploading again; continue with:\n  %s'
                           % (submission, status, shlex.join(base + ['--resume', '--execute'])))
    require(status == 'Accepted', 'Notarization status %r: %s (details: %s)' % (status, result.get('message'), log_path))
    log = json.loads(log_path.read_text()) if log_path.exists() else None
    require(log is not None, 'Notary log missing')
    require(not log.get('issues'), 'Notary log has issues: %s' % json.dumps(log.get('issues'), indent=2))
    print('NOTARIZED (%s): submission %s Accepted, no issues; sha256 %s' % (kind, submission, digest))
    return 0


def staple_commands(artifact):
    kind = artifact_kind(artifact)
    assess = (['spctl', '--assess', '-vvv', '--type', 'execute', str(artifact)] if kind == 'app' else
              ['spctl', '--assess', '-vvv', '--type', 'open', '--context', 'context:primary-signature', str(artifact)])
    return kind, [['xcrun', 'stapler', 'staple', str(artifact)], ['xcrun', 'stapler', 'validate', str(artifact)], assess]


def cmd_staple(args):
    artifact = Path(args.artifact).absolute()
    kind, commands = staple_commands(artifact)
    notary_dir = Path(args.notary_dir).absolute() if args.notary_dir else None
    if not args.execute:
        print('PRINT-ONLY: nothing was executed. After notarization is Accepted, run')
        print('  ' + shlex.join(['python3', str(Path(__file__).resolve()), 'staple', '--artifact', str(artifact),
                                 '--notary-dir', str(notary_dir or '<notarize --out directory>')] + signing_flags(args) + ['--execute']))
        print('which checks the artifact and its Accepted notary receipt, then runs:')
        for argv in commands:
            print('  ' + shlex.join(argv))
        return 0
    require(notary_dir, '--execute requires --notary-dir (the notarize --out directory)')
    require(artifact.exists(), 'Missing artifact')
    require(not installed_location(artifact), 'Refusing to staple an installed copy (%s); staple the release output' % artifact)
    runner = Runner()
    try:
        receipt = json.loads((notary_dir / ('notary-%s-receipt.json' % kind)).read_text())
    except (OSError, ValueError):
        raise ReleaseError('No notary receipt for this %s in %s (run notarize first)' % (kind, notary_dir))
    require(receipt.get('status') == 'Accepted', 'Notary receipt status is %r, not Accepted' % receipt.get('status'))
    cdhash = artifact_cdhash(runner, artifact)
    require(cdhash and receipt.get('artifact_cdhash') == cdhash, 'This %s is not the one that was notarized (CDHash differs)' % kind)
    if kind == 'app':
        problems, report = verify_app(artifact, 'developer-id', runner, args.apple_events, args.updates)
        print_report(report)
        problems += [] if typing_app(artifact) else ['not the full-typing build: MacOS/MacMem lacks WebTypingRoute']
    else:
        problems = []
        if runner.run(['codesign', '--verify', '--strict', '-R=' + DEVELOPER_ID_REQUIREMENT, artifact], check=False).returncode:
            problems.append('image does not satisfy the Developer ID + team requirement')
    require(not problems, 'Refusing to staple: checks failed:\n  ' + '\n  '.join(problems))
    for argv in commands[:2]:
        runner.run(argv, timeout=600)
    assess = runner.run(commands[2], check=False)
    require(assess.returncode == 0 and 'Notarized Developer ID' in (assess.stdout + assess.stderr),
            'Gatekeeper did not report "Notarized Developer ID"')
    if kind == 'app':
        problems, report = verify_app(artifact, 'developer-id', runner, args.apple_events, args.updates)
        print_report(report)
        require(not problems, 'Verify after stapling failed:\n  ' + '\n  '.join(problems))
    print('STAPLED (%s): %s' % (kind, artifact))
    if kind == 'dmg':
        digest = write_checksum(artifact, runner)
        print('SHA-256 of the stapled download: %s (written to %s)' % (digest, checksum_path(artifact).name))
    return 0


# ---------------------------------------------------------------- checksum / notes
def checksum_path(dmg):
    return Path(str(dmg) + '.sha256')


def read_checksum(dmg):
    """(digest, file name) from <dmg>.sha256, read the way write_checksum (and `shasum -a 256`) writes it:
    one '<64 hex digits>  <file name>' line. The name may hold spaces (a test image, "DayDream - Saturday
    test 5.dmg"), so the line is split at the two spaces after the digest, never at every space."""
    try:
        text = checksum_path(dmg).read_text()
    except (OSError, ValueError):
        raise ReleaseError('No %s. Run `checksum` (or staple) first.' % checksum_path(dmg).name)
    found = re.fullmatch(r'([0-9a-f]{64})  ([^\n]+)\n?', text)
    require(found, '%s is not one "<SHA-256>  <file name>" line. Run `checksum` again.' % checksum_path(dmg).name)
    return found.group(1), found.group(2)


def write_checksum(dmg, runner):
    """SHA-256 of the final download, in `shasum -a 256` format next to the DMG.

    Taken only after stapling: stapling adds Apple's ticket to the file, so a checksum taken
    before it would not match what people download."""
    dmg = Path(dmg).absolute()
    require((re.fullmatch(r'DayDream-' + VERSION_RE + r'(-owner)?\.dmg', dmg.name) or test_dmg_name(dmg.name)) and dmg.is_file(),
            'Expected an existing DayDream-<version>.dmg (or the owner\'s DayDream-<version>-owner.dmg, or a test '
            'build\'s "DayDream - <words>.dmg")')
    require(runner.run(['xcrun', 'stapler', 'validate', dmg], check=False, quiet=True).returncode == 0,
            'The DMG is not stapled. Staple it first: the checksum is taken after stapling.')
    digest = sha256_file(dmg)
    checksum_path(dmg).write_text('%s  %s\n' % (digest, dmg.name))
    return digest


def cmd_checksum(args):
    runner = Runner()
    digest = write_checksum(args.dmg, runner)
    print('SHA-256 %s  %s (written to %s)' % (digest, Path(args.dmg).name, checksum_path(args.dmg).name))
    return 0


NOTES_TEMPLATE = ROOT / 'docs/release-notes-template.md'


def fill_template(text, fields):
    for key, value in fields.items():
        text = text.replace('{{%s}}' % key, str(value))
    left = re.findall(r'\{\{[A-Z0-9_]+\}\}', text)
    require(not left, 'Unfilled fields in the release notes template: %s' % sorted(set(left)))
    return text


def release_notes(app, dmg, runner, today=None):
    """The release notes for this app and its stapled DMG, from docs/release-notes-template.md."""
    import datetime
    app, dmg = Path(app).absolute(), Path(dmg).absolute()
    info = load_plist(app / 'Contents/Info.plist')
    short = info.get('CFBundleShortVersionString', '')
    require(not owner_app(app), 'OWNER BUILD: %s is the owner\'s private test copy (updates off). It gets no public release notes.' % app.name)
    require(typing_app(app), NARROW_BUILD % app.name)
    require(not test_dmg_name(dmg.name), '%s is a test build\'s image: it gets no public release notes' % dmg.name)
    require(dmg.name == dmg_name(short), 'The DMG must be named %s' % dmg_name(short))
    commit = json.loads((app / 'Contents/Resources/Companions.json').read_text()).get('source_commit', '')
    require(re.fullmatch(r'[0-9a-f]{40}', commit or ''), 'The app records no source commit (stage it with developer-id-release.py stage)')
    require(runner.run(['xcrun', 'stapler', 'validate', dmg], check=False, quiet=True).returncode == 0,
            'The DMG is not stapled. Staple it first.')
    digest, name = read_checksum(dmg)
    require(name == dmg.name and digest == sha256_file(dmg), '%s does not match the DMG. Run `checksum` again.' % checksum_path(dmg).name)
    data = release.config(require_key=False)
    return fill_template(NOTES_TEMPLATE.read_text(), {
        'VERSION': short, 'VERSION_NUMBER': release.version_core(short), 'TAG': release.release_tag(short),
        'BUILD': info['CFBundleVersion'], 'MIN_MACOS': info.get('LSMinimumSystemVersion', ''),
        'DATE': (today or datetime.date.today()).isoformat(), 'COMMIT': commit, 'SHA256': digest, 'DMG': dmg.name,
        'REPOSITORY': '%s/%s' % (data['owner'], data['repository'])})


def cmd_notes(args):
    out = Path(args.out).absolute()
    require(not out.exists(), 'Refusing to overwrite %s' % out)
    out.write_text(release_notes(args.app, args.dmg, Runner(echo=False)))
    print('Wrote %s. Replace every [bracketed] line before publishing; release.py prepare refuses a "[".' % out)
    return 0


# ---------------------------------------------------------------- CLI
# dmg and notarize: what --owner-build means there. Typing is the same in the public release and the
# owner's copy (every stage compiles OWNER_SWIFT_FLAGS); the copy differs only by its Info.plist key and
# updates off (RELEASE.md). check_developer_id_release.py keeps any "typing is on" wording out of every help string.
OWNER_COPY_HELP = ("the owner's private test copy (Info.plist MacMemOwnerTyping, updates off); typing is the same as "
                   "the public release; never a public release")


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command', required=True)

    def signing_options(p):
        p.add_argument('--apple-events', action=argparse.BooleanOptionalAction, default=None,
                       help='main app gets packaging/entitlements/main-apple-events.entitlements. Default: follow '
                            'ReleaseFeatures.chromePageHistory; a value that disagrees with it is refused')
        p.add_argument('--updates', choices=['configured', 'off'], default='configured',
                       help='configured (default): Sparkle settings from packaging/updates.json; off: no feed')

    p = sub.add_parser('stage', help='build an unsigned DayDream.app from a clean git archive of HEAD')
    p.add_argument('--out', required=True, help='new output directory, outside the repository')
    p.add_argument('--build', required=True, help='numeric CFBundleVersion, greater than every earlier release')
    first = p.add_mutually_exclusive_group()
    first.add_argument('--previous-build', type=int,
                       help='CFBundleVersion of the last copy anyone installed (a release or a test build); --build must '
                            'exceed it. Required unless --first-build')
    first.add_argument('--first-build', action='store_true', help='the very first build: nothing to compare --build with')
    p.add_argument('--version', help='numeric x.y.z (default: packaging/Info.plist); " Beta" is added unless --no-beta')
    p.add_argument('--beta', action=argparse.BooleanOptionalAction, default=True, help='label the version "x.y.z Beta" (default)')
    p.add_argument('--commit', default='HEAD', help='must name HEAD; a guard against staging the wrong checkout')
    p.add_argument('--scratch', help='SwiftPM scratch folder (default: <out>/build)')
    p.add_argument('--updates', choices=['configured', 'off'], default='configured',
                   help='configured (default): Sparkle settings from packaging/updates.json; off: no feed')
    p.add_argument('--min-macos', default=DEFAULT_MIN_MACOS)
    p.add_argument('--owner-build', action='store_true',
                   help="the owner's private test copy: marks Info.plist MacMemOwnerTyping (every stage compiles typing in "
                        "with OWNER_SWIFT_FLAGS); needs --updates off; never a public release")
    p.add_argument('--qa-harness', action='store_true',
                   help='PRIVATE QA ONLY: compile test routes/windows; requires --owner-build --updates off; excluded by default')
    p.add_argument('--typesense-inputs', help='verified local directory holding pinned runtime.tar.gz and typesense-server; no download')
    p.add_argument('--typesense-source-kit', help='public stage with Typesense: the Complete Corresponding Source kit '
                   '(typesense-30.2-complete-source.tar.gz), checked against the sha256 in scripts/search_payload.py')
    p.add_argument('--without-search-runtime-for-tests', action='store_true',
                   help='synthetic test build only; omits the automatic local search runtime')
    p.add_argument('--without-writer-runtime-for-tests', action='store_true',
                   help='TEST BUILDS ONLY: stage without the signed "On this Mac" runtime (packaging/WriterRuntime). '
                        'Its Developer ID DMG, notarized image and appcast are refused')
    p.set_defaults(func=cmd_stage)

    p = sub.add_parser('sign', help='inside-out signing of a copy of a staged app')
    p.add_argument('--app', required=True)
    p.add_argument('--out', required=True, help='new output directory')
    p.add_argument('--identity', required=True, help='"-" for an ad-hoc dry run, or the certificate SHA-1')
    signing_options(p)
    p.set_defaults(func=cmd_sign)

    p = sub.add_parser('verify', help='verify a signed app')
    p.add_argument('--app', required=True)
    p.add_argument('--expect', required=True, choices=['adhoc', 'developer-id'])
    p.add_argument('--json', help='write the per-item report here')
    signing_options(p)
    p.set_defaults(func=cmd_verify)

    p = sub.add_parser('dmg', help='build and sign the final-layout DMG')
    p.add_argument('--app', required=True)
    p.add_argument('--out', required=True, help='path of the new DayDream-<x.y.z>.dmg (numeric app version; DayDream-<x.y.z>-owner.dmg '
                                                'with --owner-build); with --name, a folder or a path ending in that name')
    p.add_argument('--name', help='a test build\'s own file name, "DayDream - <words>.dmg" (for example "DayDream - Saturday '
                                  'test 5.dmg"); never a public release')
    p.add_argument('--volume-name', help='a test image\'s volume name (default: --name without .dmg); a release image is '
                                         'always on the volume "DayDream"')
    p.add_argument('--identity', help='"-" (ad-hoc) or the certificate SHA-1')
    p.add_argument('--unsigned', action='store_true')
    p.add_argument('--allow-unstapled-app', action='store_true')
    p.add_argument('--owner-build', action='store_true', help=OWNER_COPY_HELP)
    p.set_defaults(func=cmd_dmg)

    p = sub.add_parser('notarize', help='PRINT-ONLY unless --execute and --keychain-profile')
    p.add_argument('--artifact', required=True, help='signed DayDream.app or signed .dmg')
    p.add_argument('--out', required=True, help='directory for the zip, JSON result and log')
    p.add_argument('--keychain-profile')
    p.add_argument('--resume', action='store_true',
                   help='wait on the submission saved in --out (after a timeout or dropped connection); never uploads')
    p.add_argument('--execute', action='store_true')
    p.add_argument('--owner-build', action='store_true', help=OWNER_COPY_HELP)
    signing_options(p)
    p.set_defaults(func=cmd_notarize)

    p = sub.add_parser('staple', help='PRINT-ONLY unless --execute')
    p.add_argument('--artifact', required=True)
    p.add_argument('--notary-dir', help='the notarize --out directory holding the Accepted receipt (required with --execute)')
    p.add_argument('--execute', action='store_true')
    signing_options(p)
    p.set_defaults(func=cmd_staple)

    p = sub.add_parser('checksum', help='write <dmg>.sha256 for a stapled DMG')
    p.add_argument('--dmg', required=True)
    p.set_defaults(func=cmd_checksum)

    p = sub.add_parser('notes', help='fill docs/release-notes-template.md for this release')
    p.add_argument('--app', required=True, help='the signed, stapled DayDream.app')
    p.add_argument('--dmg', required=True, help='the stapled DayDream-<version>.dmg (with its .sha256)')
    p.add_argument('--out', required=True, help='new file, e.g. $OUT/DayDream-<version>.md')
    p.set_defaults(func=cmd_notes)
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        if hasattr(args, 'apple_events'):
            args.apple_events = resolve_apple_events(args.apple_events)
        return args.func(args)
    except (ReleaseError, ValueError, OSError, subprocess.SubprocessError, AssertionError) as error:
        print('ERROR: %s: %s' % (type(error).__name__, error), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
