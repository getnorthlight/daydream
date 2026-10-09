"""No Horizon and no SSH connection in DayDream (connect track, C2). Read-only.

1. Every binary given with --binary (the release MacMem at least) holds no "Horizon" string, in any case.
   "horizontal" is a normal word (SwiftUI layout, SF Symbol names, AppKit accessibility selectors) and is allowed.
2. The shipped sources hold no Horizon wording, no horizon-forced-command profile, no com.horizon services,
   and the ConnectionSetup (SSH) package is gone from the package and the tree.
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HORIZON = re.compile(r'horizon(?!tal)', re.IGNORECASE)
# What ships: the app, the CLI, the backup worker and the local packages they link.
SHIPPED = ['Sources', 'UIRender', 'BackupRestore', 'adapters', 'packaging', 'WriterBackend/Sources', 'PrivacyPolicy/Sources',
           'BrowserBridge/Sources', 'Package.swift']
passes = 0
failures = []


def ok(condition, message, detail=''):
    global passes
    if condition:
        passes += 1
        print('PASS ' + message)
    else:
        failures.append(message + (f': {detail}' if detail else ''))
        print('FAIL ' + message + (f': {detail}' if detail else ''))


def git_checkout_skip_reason():
    """None in a git checkout of this repo; otherwise why the tracked-source scan is skipped (a `git archive` tree)."""
    try:
        top = subprocess.run(['git', '-C', str(ROOT), 'rev-parse', '--show-toplevel'], capture_output=True, text=True)
    except OSError as error:
        return f'git is not available ({error})'
    if top.returncode != 0:
        return f'{ROOT} is not a git checkout: the shipped-source list is git ls-files'
    if Path(top.stdout.strip()).resolve() != ROOT.resolve():
        return f'{ROOT} is not the top of its git checkout ({top.stdout.strip()})'
    return None


def local_roots(binary):
    """The source tree and the build scratch folder (.../<triple>/<debug|release>/<binary> -> the scratch)."""
    # As given and resolved: a debug build writes the paths it was handed (/var/tmp/... or /private/var/tmp/...).
    roots = {str(ROOT), str(Path(__file__).absolute().parents[1]), str(Path.cwd()), str(Path.cwd().resolve())}
    for place in (binary.absolute(), binary.resolve()):
        if len(place.parents) > 2 and place.parent.name in ('debug', 'release'):
            roots.add(str(place.parents[2]))
    return sorted(roots, key=len, reverse=True)


def strip_roots(line, roots):
    for root in roots:
        line = line.replace(root, '')
    return line


def tracked(paths):
    out = subprocess.run(['git', 'ls-files', '-z', '--', *paths], cwd=ROOT, capture_output=True, check=True).stdout
    return [ROOT / p for p in out.decode().split('\0') if p]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', action='append', default=[])
    args = parser.parse_args()

    # Only the build's own paths are set aside: a Horizon path anywhere else in a string is still caught.
    ok(not HORIZON.search(strip_roots('/Volumes/OldHorizon/w/tree/Sources/A.swift', ['/Volumes/OldHorizon/w/tree']))
       and HORIZON.search(strip_roots('/Volumes/OldHorizon/old/history', ['/Volumes/OldHorizon/w/tree'])),
       'build paths are set aside, other Horizon paths are not')
    # The pattern itself: a real match is caught, "horizontal" is not.
    ok(HORIZON.search('com.horizon.history.push') and HORIZON.search('Horizon and approved connections')
       and not HORIZON.search('slider.horizontal.3 accessibilityHorizontalScrollBar'), 'the Horizon pattern skips only "horizontal"')

    for binary in args.binary:
        path = Path(binary)
        ok(path.is_file() and path.stat().st_size > 0, f'{path.name} is built', str(path))
        text = subprocess.run(['strings', '-a', str(path)], capture_output=True, text=True, errors='replace').stdout
        # A debug build records where it was built: the source tree and its own scratch folder. Built on a volume
        # named Horizon (the 10/07 run), those paths alone matched. They are not DayDream's words; anything else is.
        roots = local_roots(path)
        hits = sorted({line.strip()[:80] for line in text.splitlines() if HORIZON.search(strip_roots(line, roots))})
        ok(not hits, f'{path.name} holds no Horizon string', '; '.join(hits[:10]))
        for word in ('horizon-forced-command', 'mac-mem-horizon', 'DaydreamConnectionSetup', 'known_hosts', 'StrictHostKeyChecking'):
            ok(word not in text, f'{path.name} holds no "{word}"')

    reason = git_checkout_skip_reason()
    if reason:
        print(f'SKIP the shipped sources are scanned: {reason}')
        print(f'SKIP no Horizon wording in the shipped sources: {reason}')
        ok(not (ROOT / 'ConnectionSetup').exists(), 'the ConnectionSetup (SSH) package is gone (folder only; git-tracked part skipped)')
    else:
        files = [p for p in tracked(SHIPPED) if p.is_file()]
        ok(len(files) > 100, 'the shipped sources are scanned', str(len(files)))
        hits = []
        for path in files:
            try:
                text = path.read_text(errors='replace')
            except OSError:
                continue
            for number, line in enumerate(text.splitlines(), 1):
                if HORIZON.search(line):
                    hits.append(f'{path.relative_to(ROOT)}:{number}')
        ok(not hits, 'no Horizon wording in the shipped sources', ', '.join(hits[:10]))
        ok(not (ROOT / 'ConnectionSetup').exists() and not tracked(['ConnectionSetup']), 'the ConnectionSetup (SSH) package is gone')
    package = (ROOT / 'Package.swift').read_text()
    ok('ConnectionSetup' not in package, 'Package.swift no longer links ConnectionSetup')
    review = (ROOT / 'Sources/MemoryCore/InstallationReview.swift').read_text()
    ok('com.horizon' not in review and 'knownServices: [String] = []' in review, 'InstallationReview knows no com.horizon services')
    hub = (ROOT / 'Sources/MemoryUI/SettingsHub.swift').read_text()
    # ux/declutter: the hub's rows are titles only; its privacy line says what connected AI apps can do.
    ok('title: DaydreamSettingsPage.connections.title' in hub and 'AI apps you connect' in hub and 'subtitle:' not in hub,
       'the Settings Connections row is named, and the hub says what connected AI apps can do')

    print(f'{passes} no-Horizon checks passed, {len(failures)} failed.')
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
