#!/usr/bin/env python3
"""Realism, owner bug 11 (10/07, "preview3"): a staged test copy held stale code. The live copy was staged with
`developer-id-release.py stage --scratch <home>/DaydreamReleases/rel018-preview-build-owner`, a SwiftPM scratch folder an
earlier stage had built in; SwiftPM finished in 0.33 s, compiled nothing, and the owner tested the old binary.

The rule: every staging path builds in a fresh SwiftPM scratch (or refuses one that already holds a build), and the
binary it stages carries a string from the newest commit. Each path is replayed the way the owner's runs go: stage at
one commit, commit again (a new marker string), stage again, and read the staged MacMem for the new marker.
  A. scripts/developer-id-release.py stage (release, Live Test and preview copies): the default scratch, and the 10/07
     command line (--scratch naming an earlier stage's scratch).
  B. scripts/package.sh (local unsigned copies): two package runs in a sandbox copy of the packaging inputs.
  C. scripts/stage-local-ui-update.py (the local UI update helper): it takes a compiled MacMem; a MacMem from an older
     commit must be refused.
SwiftPM is a fake that reproduces the 10/07 behaviour (scripts/fixtures/realism/fakes/swift and the builder below): a
scratch that already holds a product is reused as is; otherwise it "compiles" a file carrying the commit's marker.
Nothing is built, signed (fake codesign), launched or installed; every path is in a scratch folder (REALISM_OUT/TMPDIR).
"""
import contextlib
import importlib.util
import io
import os
import shutil
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / 'fixtures/realism'))
sys.path.insert(0, str(HERE))
import realism_fixtures as fx  # noqa: E402

report = fx.Report('realism-staging')
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
    return Path(tempfile.mkdtemp(prefix='realism-staging-', dir=base))


def new_marker(tag):
    return 'realism-marker %s %s' % (tag, uuid.uuid4().hex)


# ---------------------------------------------------------------- A. developer-id-release.py stage
def developer_id(root):
    cdr = load('check_developer_id_release', 'check_developer_id_release.py')  # its synthetic repo and runners
    dr = cdr.dr
    folder = root / 'devid'
    folder.mkdir()
    repo = cdr.fixture_repo(folder)
    marker_file = repo / 'Sources/realism-marker.txt'
    builds = []

    def builder(source, scratch, runner, swift_flags=()):
        """SwiftPM as the owner saw it on 10/07: a scratch that already holds the products is reused untouched."""
        bins = Path(scratch) / 'release'
        if all((bins / name).is_file() for name in dr.SWIFT_BINARIES):
            builds.append(('reused', Path(scratch)))
            return bins
        builds.append(('compiled', Path(scratch)))
        marker = (Path(source) / 'Sources/realism-marker.txt').read_bytes()
        bins.mkdir(parents=True, exist_ok=True)
        for name in dr.SWIFT_BINARIES:
            (bins / name).write_bytes(cdr.MACHO + name.encode() + cdr.TYPING_BYTES.get(name, b'') + b'\n' + marker)
        icons = bins / 'MacMem_MemoryUI.bundle/SiteIcons'
        icons.mkdir(parents=True, exist_ok=True)
        for name in ['x', 'instagram', 'google', 'claude-code', 'cursor']:
            (icons / (name + '.png')).write_bytes((name + '-icon-fixture').encode())
        return bins

    def commit(tag):
        marker = new_marker(tag)
        marker_file.parent.mkdir(parents=True, exist_ok=True)
        marker_file.write_text(marker + '\n')
        cdr.git(repo, 'add', '-A')
        cdr.git(repo, 'commit', '-q', '-m', 'realism ' + tag)
        return marker

    def stage(out, *extra):
        argv = ['stage', '--without-search-runtime-for-tests', '--out', str(folder / out), '--build', '20261008120000',
                '--version', '0.1.8', '--first-build'] + list(extra)
        args = dr.build_parser().parse_args(argv)
        inspect = lambda runner, path: cdr.devid_info(cdr.writer_payload.signing_identifier(Path(path).name))
        with mock.patch.object(dr, 'inspect_signature', side_effect=inspect), \
                mock.patch.object(dr, 'leaf_sha256', return_value=dr.LEAF_SHA256), \
                mock.patch.object(cdr.writer_payload, 'ROOT', repo), contextlib.redirect_stdout(io.StringIO()):
            try:
                dr.cmd_stage(args, runner=cdr.HybridRunner(), root=repo, builder=builder)
                return None
            except dr.ReleaseError as error:
                return error

    def staged(out):
        path = folder / out / 'DayDream.app/Contents/MacOS/MacMem'
        return path.read_bytes() if path.is_file() else b''

    first = commit('preview2')
    error = stage('preview2')
    check(error is None and first.encode() in staged('preview2'),
          'bug11 developer-id-release.py stage: control, the first stage compiles and MacMem carries its commit marker', repr(error))
    second = commit('preview3')
    error = stage('preview3')
    check(error is None and second.encode() in staged('preview3') and builds[-1][0] == 'compiled',
          'bug11 developer-id-release.py stage (default scratch): the next commit is staged from a fresh SwiftPM scratch and '
          'its MacMem carries the newest commit marker', '%r %r' % (error, builds[-1:]))
    third = commit('preview3b')
    reused = folder / 'preview2/build'   # the 10/07 command line: --scratch <an earlier stage's scratch>
    error = stage('preview3b', '--scratch', str(reused))
    fresh = error is None and third.encode() in staged('preview3b')
    check(error is not None or fresh,
          'bug11 developer-id-release.py stage --scratch <an earlier stage\'s scratch> (the 10/07 command): refused, or the '
          'staged MacMem carries the newest commit marker',
          'not refused; SwiftPM %s; staged MacMem has the newest marker: %s, an older one: %s'
          % (builds[-1][0], third.encode() in staged('preview3b'), first.encode() in staged('preview3b')))


# ---------------------------------------------------------------- B. package.sh
STUBS = {
    # The packaging helpers package.sh calls are stubs here: only its own build-root and staging logic is under test.
    'scripts/search_payload.py': 'import sys\ndef source_files(*a, **k):\n    return []\nif __name__ == "__main__":\n    sys.exit(0)\n',
    'scripts/bootstrap-sparkle.py': 'pass\n',
    'scripts/verify-app-companions.py': 'pass\n',
    'scripts/release.py': ('import json, sys\nfrom pathlib import Path\n'
                           'if sys.argv[1] == "manifest":\n'
                           '    app = Path(sys.argv[sys.argv.index("--app") + 1])\n'
                           '    (app / "Contents/Resources/Companions.json").write_text(json.dumps({"sha256": {}}) + "\\n")\n'),
    'scripts/verify-dmg-seal.sh': 'exit 0\n',
}


def package_sandbox(root):
    project = root / 'package-project'
    for rel in ('packaging/Info.plist',):
        (project / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(HERE.parent / rel, project / rel)
    for rel in ('scripts/package.sh', 'scripts/seal-local-app.sh'):
        (project / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(HERE.parent / rel, project / rel)
    for rel, text in STUBS.items():
        (project / rel).write_text(text)
    for rel in ('packaging/Daydream.icns', 'LICENSE', 'NOTICE', 'THIRD-PARTY-NOTICES.md', 'WriterBackend/Notices/llama-MIT.txt',
                'WriterBackend/Notices/Qwen-APACHE-2.0.txt', 'adapters/before_turn.py', 'adapters/launcher.example.json',
                'Vendor/Sparkle-2.9.6/LICENSE', 'Vendor/Sparkle-2.9.6/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/Sparkle',
                'Vendor/Typesense-30.2/README'):
        (project / rel).parent.mkdir(parents=True, exist_ok=True)
        (project / rel).write_text('fixture\n')
    return project


def package_run(project, name, env):
    done = fx.run(['bash', project / 'scripts/package.sh', 'dmg', name], env)
    stages = sorted((project / '.build').glob('package.*'), key=lambda p: p.stat().st_mtime)
    app = stages[-1] / 'root/DayDream.app' if stages else None
    data = (app / 'Contents/MacOS/MacMem').read_bytes() if app and (app / 'Contents/MacOS/MacMem').is_file() else b''
    return done, data


def package_sh(root):
    project = package_sandbox(root)
    marker_file = project / 'Sources/realism-marker.txt'
    marker_file.parent.mkdir(parents=True, exist_ok=True)
    env, _ = fx.fake_env(project)
    env['REALISM_SWIFT_LOG'] = str(project / 'swift.log')
    env.pop('DAYDREAM_OWNER_TYPING', None)
    env.pop('MACMEM_BUILD_ROOT', None)
    first = new_marker('package-1')
    marker_file.write_text(first + '\n')
    done, data = package_run(project, 'Daydream-realism-1.dmg', env)
    check(done.returncode == 0 and first.encode() in data,
          'bug11 package.sh: control, the first package run compiles and its MacMem carries the commit marker', done.stderr[-400:])
    second = new_marker('package-2')
    marker_file.write_text(second + '\n')
    done, data = package_run(project, 'Daydream-realism-2.dmg', env)
    check(done.returncode != 0 or second.encode() in data,
          'bug11 package.sh: the next package run (a new commit) builds in a fresh SwiftPM scratch or refuses the reused '
          'one; its staged MacMem carries the newest commit marker',
          'exit %d; staged MacMem has the newest marker: %s, the previous one: %s' % (done.returncode, second.encode() in data, first.encode() in data))
    fresh = project / '.build-realism-fresh'
    env2 = dict(env, MACMEM_BUILD_ROOT=str(fresh))
    third = new_marker('package-3')
    marker_file.write_text(third + '\n')
    done, data = package_run(project, 'Daydream-realism-3.dmg', env2)
    check(done.returncode == 0 and third.encode() in data,
          'bug11 package.sh: control, MACMEM_BUILD_ROOT naming a new folder stages the newest commit', done.stderr[-400:])


# ---------------------------------------------------------------- C. stage-local-ui-update.py
def stage_local(root):
    stage_mod = load('realism_stage_local_ui_update', 'stage-local-ui-update.py')
    head = subprocess.run(['git', '-C', str(HERE.parent), 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
    older = subprocess.run(['git', '-C', str(HERE.parent), 'rev-parse', 'HEAD~1'], capture_output=True, text=True).stdout.strip()

    def attempt(tag, binary_bytes):
        folder = root / ('stage-local-' + tag)
        base = fx.fixture_app(folder / 'base', 'com.getnorthlight.daydream.adhoc')
        binary = folder / 'MacMem'
        binary.write_bytes(binary_bytes)
        binary.chmod(0o755)
        env, _ = fx.fake_env(folder)
        real_run = subprocess.run

        def routed(argv, *a, **k):
            argv = [str(x) for x in argv]
            if argv and argv[0] in ('/usr/bin/codesign', 'codesign'):
                argv = [str(fx.FAKES / 'codesign')] + argv[1:]
            k.setdefault('env', env)
            return real_run(argv, *a, **k)
        args = stage_mod.argparse.Namespace(base=base, binary=binary, build='101', output=folder / 'staged')
        with mock.patch.object(stage_mod.subprocess, 'run', side_effect=routed), contextlib.redirect_stdout(io.StringIO()):
            try:
                stage_mod.stage(args)
                return None, (folder / 'staged/DayDream.app/Contents/MacOS/MacMem').read_bytes()
            except Exception as error:  # noqa: BLE001
                return error, b''

    error, data = attempt('fresh', ('MACHO-FIXTURE MacMem built from %s\n' % head).encode())
    check(error is None and head.encode() in data,
          'bug11 stage-local-ui-update.py: control, a MacMem built from HEAD is staged byte for byte', repr(error))
    error, data = attempt('stale', ('MACHO-FIXTURE MacMem built from %s\n' % older).encode())
    # A refusal for the staging folder's place (not inside the workspace or /private/tmp) is not a refusal of the binary.
    check(error is not None and 'Stage only inside' not in str(error),
          'bug11 stage-local-ui-update.py: a MacMem built from an older commit (no string from HEAD) is refused',
          'staged it: the helper copies whatever --binary it is given and never checks it was built from HEAD')


def main():
    root = scratch_root()
    developer_id(root)
    package_sh(root)
    stage_local(root)
    return report.finish()


if __name__ == '__main__':
    sys.exit(main())
