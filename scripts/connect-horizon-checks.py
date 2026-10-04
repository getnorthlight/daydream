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


def tracked(paths):
    out = subprocess.run(['git', 'ls-files', '-z', '--', *paths], cwd=ROOT, capture_output=True, check=True).stdout
    return [ROOT / p for p in out.decode().split('\0') if p]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', action='append', default=[])
    args = parser.parse_args()

    # The pattern itself: a real match is caught, "horizontal" is not.
    ok(HORIZON.search('com.horizon.history.push') and HORIZON.search('Horizon and approved connections')
       and not HORIZON.search('slider.horizontal.3 accessibilityHorizontalScrollBar'), 'the Horizon pattern skips only "horizontal"')

    for binary in args.binary:
        path = Path(binary)
        ok(path.is_file() and path.stat().st_size > 0, f'{path.name} is built', str(path))
        text = subprocess.run(['strings', '-a', str(path)], capture_output=True, text=True, errors='replace').stdout
        hits = sorted({line.strip()[:80] for line in text.splitlines() if HORIZON.search(line)})
        ok(not hits, f'{path.name} holds no Horizon string', '; '.join(hits[:10]))
        for word in ('horizon-forced-command', 'mac-mem-horizon', 'DaydreamConnectionSetup', 'known_hosts', 'StrictHostKeyChecking'):
            ok(word not in text, f'{path.name} holds no "{word}"')

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
