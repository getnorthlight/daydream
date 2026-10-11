#!/usr/bin/env python3
"""Realism package boundary: its own check files never touch a real permission, the person's history or home.

Scans every file of the realism package (scripts/realism-*, scripts/fixtures/realism/**, runner-1001/steps.d/realism.sh,
including this file) for: a permission reset or request (the reset tool, the privacy database, the Accessibility trust
call with its prompt option, the Input Monitoring and post-event requests, the HID access request, the Automation
consent call, camera/contacts/calendar access requests, login-item registration, System Settings' privacy panes);
the person's DayDream history folder or a DayDream .sqlite; and the person's home (the home-folder APIs of Python and
Foundation, or a literal tilde path). It also checks that every run in runner-1001/steps.d/realism.sh goes through
rrun, which sets HOME and CFFIXED_USER_HOME to that step's own scratch folder under the run's output. The patterns are
assembled from pieces, so this file does not match itself. Reads files only; never runs anything.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
J = ''.join

BANNED = [
    (J(['tcc', 'util']), 'runs the permission reset tool'),
    (J(['TCC', '.db']), 'touches the TCC database'),
    (J(['com.apple', '.TCC']), 'touches the TCC folder'),
    (J(['AXIsProcess', 'TrustedWithOptions']), 'the Accessibility trust call with options (can prompt)'),
    (J(['kAXTrusted', 'CheckOptionPrompt']), 'the Accessibility prompt option'),
    (J(['CGRequest', 'ListenEventAccess']), 'asks for Input Monitoring'),
    (J(['CGRequest', 'PostEventAccess']), 'asks to post events'),
    (J(['IOHID', 'RequestAccess']), 'asks for Input Monitoring'),
    (J(['AEDetermine', 'PermissionToAutomateTarget']), 'asks for Automation'),
    (J(['request', 'Access(']), 'a permission request API'),
    (J(['SMApp', 'Service']), 'registers a login item'),
    (J(['Privacy', '_Accessibility']), "opens System Settings' Accessibility pane"),
    (J(['Privacy', '_ListenEvent']), "opens System Settings' Input Monitoring pane"),
    (J(['Application Support', '/DayDream']), "the person's DayDream history folder"),
    (J(['Application\\ Support', '/DayDream']), "the person's DayDream history folder"),
    (J(['Path', '.home(']), "the person's home (Path.home)"),
    (J(['expand', 'user(']), "the person's home (expanduser)"),
    (J(['NSHome', 'Directory(']), "the person's home (NSHomeDirectory)"),
    (J(['homeDirectory', 'ForCurrentUser']), "the person's home (FileManager's home directory)"),
]
TILDE = re.compile(J([r'(?<![\w$])', '~', '/']))
SQLITE = re.compile(J([r'[\w/.-]*', 'DayDream', r'[\w/.-]*\.sqlite']), re.I)


def package_files():
    files = sorted(ROOT.glob('scripts/realism-*'))
    files += sorted(p for p in (ROOT / 'scripts/fixtures/realism').rglob('*') if p.is_file() and '__pycache__' not in p.parts)
    steps = ROOT / 'runner-1001/steps.d/realism.sh'
    if steps.is_file():
        files.append(steps)
    return files


def main():
    files = package_files()
    passed = failed = 0

    def check(ok, label, detail=''):
        nonlocal passed, failed
        if ok:
            passed += 1
            print('PASS ' + label)
        else:
            failed += 1
            print('FAIL ' + label + ('  [' + detail + ']' if detail else ''))

    names = {p.relative_to(ROOT).as_posix() for p in files}
    check(any(n.endswith('realism-app-checks.swift') for n in names) and 'scripts/realism-seams.py' in names
          and 'runner-1001/steps.d/realism.sh' in names,
          'source-scan: found the package (%d files: app checks, seams, steps fragment, fixtures)' % len(files))
    for path in files:
        rel = path.relative_to(ROOT).as_posix()
        try:
            text = path.read_text(errors='replace')
        except OSError as problem:
            check(False, 'source-scan %s: readable' % rel, str(problem))
            continue
        hits = ['%s (line %d)' % (why, text[:text.index(token)].count('\n') + 1) for token, why in BANNED if token in text]
        tilde = [m.start() for m in TILDE.finditer(text)]
        hits += ['a literal tilde home path (line %d)' % (text[:i].count('\n') + 1) for i in tilde]
        hits += ['a DayDream .sqlite path: %s' % m.group(0) for m in SQLITE.finditer(text)]
        check(not hits, 'source-scan %s: no permission request or reset, no TCC, no real DayDream history, no real home' % rel, '; '.join(hits))
    steps = ROOT / 'runner-1001/steps.d/realism.sh'
    if steps.is_file():
        body = steps.read_text()
        lines = [l.strip() for l in body.splitlines() if re.match(r'\s*(rrun|rapp|step) realism-', l)]
        rapp = re.search(r'rapp\(\) \{([^\n]*)\}', body)
        via = ('rrun ',) + (('rapp ',) if rapp and 'rrun "$name"' in rapp.group(1) else ())
        bad = [l for l in lines if not l.startswith(via)]
        check(len(lines) >= 10 and not bad, 'source-scan steps.d/realism.sh: every realism run (%d) goes through rrun (one scratch HOME per step)' % len(lines),
              '; '.join(bad) or '%d runs' % len(lines))
        body = steps.read_text()
        m = re.search(r'rrun\(\) \{(.*?)"\$@"; \}', body, re.S)
        rrun = m.group(1) if m else ''
        check('HOME="$W/home"' in rrun and 'CFFIXED_USER_HOME="$W/home"' in rrun and 'W=$OUT/realism/' in body,
              'source-scan steps.d/realism.sh: rrun sets HOME and CFFIXED_USER_HOME to the step\'s own folder under $OUT', rrun.strip()[:200])
    print('realism-source-scan: %d passed, %d failed' % (passed, failed))
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
