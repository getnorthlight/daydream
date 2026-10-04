"""Keyboard ownership lint (plan section 7, plan section 5 I1 item 6, amendments I1). Read-only; no app launch.

1. Every modifier `.keyboardShortcut(` / `KeyboardShortcut(` in Sources/ is in Sources/MacMemApp/AppCommands.swift,
   except the allowlist below. Role shortcuts (.defaultAction / .cancelAction: a sheet's or dialog's
   Return / Esc) are allowed anywhere; a plain Esc back button only where listed.
2. Within AppCommands.swift every (key, modifiers) pair is bound once, and the section 7 bindings are there.
3. Every key hint drawn in MemoryUI (Keycap, KeyHint, `keys:` of a moment action or toolbar segment, Recall's
   footer hints) names a real binding: an AppCommands menu command, or a key the Focus List router / Recall field
   owns. The main shortcuts are bound in the menus (the Focus List footer that also drew them is gone).
4. One control per toolbar identifier: `capture-state` and `memory-settings` are each assigned by one control, built
   only by the toolbar. (The offscreen checks count toolbar rows, not identifiers, where SwiftUI exposes no
   accessibility tree; this keeps a second capsule or gear from appearing outside the row unnoticed.)
The runtime counterpart is scripts/dd-app-menu-checks.swift (the installed main menu, no duplicates).
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COMMANDS = ROOT / 'Sources/MacMemApp/AppCommands.swift'
failures = []
passes = 0


def ok(condition, message, detail=''):
    global passes
    if condition:
        passes += 1
        print('PASS ' + message)
    else:
        failures.append(message + (f' ({detail})' if detail else ''))


def code(path):
    """Source without // comments (so documentation mentioning a shortcut is not a binding)."""
    lines = []
    for line in path.read_text().splitlines():
        lines.append(re.sub(r'(^|[^:"])//.*$', r'\1', line) if '//' in line else line)
    return '\n'.join(lines)


def calls(text, name):
    """Balanced-parenthesis argument text of every `name(` call."""
    out = []
    for m in re.finditer(re.escape(name) + r'\(', text):
        depth, i = 1, m.end()
        while i < len(text) and depth:
            depth += {'(': 1, ')': -1}.get(text[i], 0)
            i += 1
        out.append((text.count('\n', 0, m.start()) + 1, text[m.end():i - 1]))
    return out


GLYPH = {'command': '⌘', 'shift': '⇧', 'option': '⌥', 'control': '⌃'}
KEYS = {'.return': '↩', '.escape': 'Esc', '.upArrow': '↑', '.downArrow': '↓', '.space': 'Space', '.tab': '⇥', '.delete': '⌫'}


def chord(args):
    """'"k", modifiers: .command' -> '⌘K'; None when the arguments are not a literal key."""
    m = re.match(r'\s*(?:KeyEquivalent\()?("(?:[^"\\]|\\.)*"|\.[A-Za-z]+)\)?\s*(?:,\s*modifiers:\s*(.+?))?\s*$', args, re.S)
    if not m:
        return None
    key, mods = m.group(1), m.group(2)
    if key.startswith('"'):
        key = bytes(key[1:-1], 'utf-8').decode('unicode_escape')
        key = {'\r': '↩'}.get(key, key.upper())
    elif key in KEYS:
        key = KEYS[key]
    else:
        return None
    names = re.findall(r'\.(command|shift|option|control)', mods) if mods is not None else ['command']
    if mods is not None and re.sub(r'[\s\[\]]', '', mods) == '':
        names = []
    return ''.join(GLYPH[n] for n in ['control', 'option', 'shift', 'command'] if n in names) + key


# ---------------------------------------------------------------------------------------------
# 1. Where modifier shortcuts may live
ROLES = re.compile(r'^\s*(?:\.defaultAction|\.cancelAction|[A-Za-z_.]+\s*\?\s*nil\s*:\s*\.cancelAction|[A-Za-z_.]+\s*\?\s*\.cancelAction\s*:\s*nil)\s*$')
# (file, argument pattern, why)
ALLOWED = [
    ('Sources/MemoryUI/MenuBarMenu.swift', r'^\s*row\.key\.map\s*\{\s*KeyboardShortcut\(KeyEquivalent\(\$0\),\s*modifiers:\s*\.command\)\s*\}\s*$',
     'menu bar panel rows ⌘O ⌘, ⌘Q (the panel is its own key window)'),
    ('Sources/MemoryUI/MenuBarMenu.swift', r'^\s*KeyEquivalent\(\$0\),\s*modifiers:\s*\.command\s*$', 'the same panel rows'),
    ('Sources/MemoryUI/MenuBarMenu.swift', r'^\s*"p",\s*modifiers:\s*\.command\s*$', 'the panel\'s ⌘P (MenuBarMenu.pauseKey)'),
    ('Sources/MemoryUI/MenuBarMenu.swift', r'^\s*Self\.pauseKey\s*$', 'the panel\'s ⌘P on the Pause row: pause for 15 minutes'),
    ('Sources/MemoryUI/MenuBarMenu.swift', r'^\s*enabled\s*\?\s*Self\.pauseKey\s*:\s*nil\s*$', 'the panel\'s ⌘P on Resume Now'),
    ('Sources/MemoryUI/MenuBarRecordingMenu.swift', r'^\s*item\.action == \.pause\(minutes: Self\.shortcutMinutes\) \? pauseShortcut : nil\s*$',
     'the Recording rows take ⌘P from AppCommands (pauseShortcut, on Pause for ▸ 15 Minutes)'),
    ('Sources/MemoryUI/ActivityView.swift', r'^\s*\.escape\s*,\s*modifiers:\s*\[\s*\]\s*$', 'legacy detail Back button (plain Esc)'),
    ('Sources/MemoryUI/FocusListDetail.swift', r'^\s*\.escape\s*,\s*modifiers:\s*\[\s*\]\s*$', 'Focus List detail Back button (plain Esc)'),
    # ux/v1: a Settings sub-page's Back square answers ⌘[ too. Settings is a sheet, and the Go menu's Previous Day ⌘[
    # is off while a sheet is attached (DaydreamSheetWatch), so the two never both answer.
    ('Sources/MemoryUI/SettingsHub.swift', r'^\s*"\[",\s*modifiers:\s*\.command\s*$', 'Settings sub-page Back (⌘[)'),
]
found_outside = []
for path in sorted((ROOT / 'Sources').rglob('*.swift')):
    rel = str(path.relative_to(ROOT))
    if rel == 'Sources/MacMemApp/AppCommands.swift':
        continue
    text = code(path)
    for name in ['.keyboardShortcut', 'KeyboardShortcut']:
        for line, args in calls(text, name):
            if name == 'KeyboardShortcut' and text[:text.find(args)].endswith('.keyboardShortcut('):
                continue
            if ROLES.match(args):
                continue
            if any(rel == f and re.match(p, args, re.S) for f, p, _ in ALLOWED):
                continue
            found_outside.append(f'{rel}:{line}: {name}({args.strip()})')
ok(not found_outside, 'modifier shortcuts live only in AppCommands.swift (plus the allowlist: menu bar panel rows and ⌘P, '
   'the Recording rows\' pauseShortcut, plain-Esc Back buttons; .defaultAction/.cancelAction roles anywhere)',
   '; '.join(found_outside))

panel = code(ROOT / 'Sources/MemoryUI/MenuBarMenu.swift')
panel_keys = sorted(set(re.findall(r'\bRow\(action:[^)]*key:\s*"(.)"', panel)))
ok(panel_keys == sorted([',', 'o', 'q']), 'the menu bar panel rows bind ⌘O, ⌘, and ⌘Q only', ','.join(panel_keys))
# The panel's ⌘P is one constant, installed twice and never together: on the Pause row (pause for 15 minutes, only
# while recording) and on Resume Now (only while paused). Its drawn hint is the same constant.
ok(re.findall(r'static let pauseKey = KeyboardShortcut\(([^)]*)\)', panel) == ['"p", modifiers: .command'] and
   'static let pauseKeys = "⌘P"' in panel and 'static let pauseKeyMinutes = 15' in panel,
   'the panel\'s ⌘P is MenuBarMenu.pauseKey, drawn as "⌘P", pausing for 15 minutes')
ok(sorted(a.strip() for _, a in calls(panel, '.keyboardShortcut')) ==
   sorted(['Self.pauseKey', 'enabled ? Self.pauseKey : nil', 'row.key.map { KeyboardShortcut(KeyEquivalent($0), modifiers: .command) }']),
   'the panel installs ⌘P on the Pause row and on Resume Now, and ⌘O ⌘, ⌘Q on its rows, nothing else',
   '; '.join(a.strip() for _, a in calls(panel, '.keyboardShortcut')))
pause_callers = []
for path in sorted((ROOT / 'Sources').rglob('*.swift')):
    rel = str(path.relative_to(ROOT))
    for line, args in calls(code(path), 'MenuBarRecordingMenu'):
        if 'pauseShortcut:' in args and rel != 'Sources/MacMemApp/AppCommands.swift':
            pause_callers.append(f'{rel}:{line}')
ok(not pause_callers, 'only AppCommands.swift gives the Recording rows their ⌘P', ', '.join(pause_callers))

# ---------------------------------------------------------------------------------------------
# 2. AppCommands.swift: unique pairs, the section 7 set
commands = code(COMMANDS)
bindings = []
for line, args in calls(commands, '.keyboardShortcut') + calls(commands, 'KeyboardShortcut'):
    if args.strip() in ('Self.pauseShortcut', 'DaydreamRecordingRows.pauseShortcut', 'pauseShortcut'):
        continue
    c = chord(args)
    ok(c is not None, f'AppCommands.swift:{line} binds a literal key', args.strip())
    if c:
        bindings.append(c)
dups = sorted({b for b in bindings if bindings.count(b) > 1})
ok(not dups, 'every (key, modifiers) pair in AppCommands.swift is bound once', ', '.join(dups))
# ⌘Q: DayDream ▸ Quit DayDream replaces AppKit's Quit, which does nothing while Settings is open (golden test 5, G40).
SECTION7 = {'⌘K', '⌘F', '⌘[', '⌘]', '⌘T', '⌘↩', '⇧⌘C', '⌘R', '⇧⌘R', '⌘P', '⌘,', '⌘O', '⌘Q'}
ok(set(bindings) == SECTION7, 'AppCommands.swift binds exactly the section 7 set', ' '.join(sorted(set(bindings) ^ SECTION7)))
ok('CommandGroup(replacing: .printItem) {}' in commands and 'CommandGroup(replacing: .newItem)' in commands,
   'Print and New Window are replaced')
for title in ['Edit Correction…', 'Forget This Moment…']:
    ok(title in commands and not re.search(re.escape(title) + r'[^\n]*\n[^\n]*\.keyboardShortcut', commands),
       f'{title} is in AppCommands.swift without a key equivalent')
# The Recording rows are MenuBarRecordingMenu's (AppCommands passes only pauseShortcut): its one shortcut is on the
# Pause for ▸ 15 Minutes row (one submenu, ux/declutter); Start / Resume Recording (one row) and Stop Recording take none.
rows = code(ROOT / 'Sources/MemoryUI/MenuBarRecordingMenu.swift')
row_keys = calls(rows, '.keyboardShortcut')
ok([a.strip() for _, a in row_keys] == ['item.action == .pause(minutes: Self.shortcutMinutes) ? pauseShortcut : nil'],
   'MenuBarRecordingMenu binds one shortcut, pauseShortcut, on one preset', '; '.join(a.strip() for _, a in row_keys))
pause_row = rows.splitlines()[row_keys[0][0] - 2] if row_keys else ''
ok('Button(item.title)' in pause_row and re.search(r'Menu\(rows\[0\]\.title\) \{\s*ForEach\(rows\[0\]\.children', rows)
   and re.search(r'public static let shortcutMinutes = 15\b', rows),
   'pauseShortcut is on Pause for ▸ 15 Minutes (rows[0] is the submenu)', pause_row.strip())
ok(not re.search(r'Item\(title: "Pause for " \+ presetTitle', rows), 'no separate Pause for 15 Minutes row')
ok(re.search(r'let start = paused \? "Resume Recording" : "Start Recording"', rows) and
   re.search(r'Button\(rows\[1\]\.title\) \{ run\(rows\[1\]\) \}\.disabled', rows) and
   re.search(r'Button\(rows\[2\]\.title\) \{ run\(rows\[2\]\) \}\.disabled', rows),
   'Start / Resume Recording (rows[1]) and Stop Recording (rows[2]) are plain buttons without a key equivalent')
# Every auxiliary Window scene opens from its own controls, so none adds a Window-menu item (the onboarding one
# would bypass the Development Trial's disabled File ▸ Set Up DayDream…).
app = code(ROOT / 'Sources/MacMemApp/MacMemApp.swift')
scenes = re.findall(r'\n\s*(Window\("[^"]*",\s*id:\s*"[^"]*"\).*?)(?=\n\s*(?:Window\(|MenuBarExtra|WindowGroup\(|\}\s*\n\s*\}\s*\n#endif))', app, re.S)
ok(len(scenes) == 3 and all('.commandsRemoved()' in body for body in scenes),
   'the demo, permissions and onboarding Window scenes carry .commandsRemoved()',
   '; '.join(body.split('\n')[0] for body in scenes if '.commandsRemoved()' not in body) or f'{len(scenes)} scenes')

# ---------------------------------------------------------------------------------------------
# 3. Key hints drawn in MemoryUI name real bindings
ROUTER = {'↑', '↓', '↩', 'Esc', '⌘C', '⌥↩', '⌃↑', '⌃↓'}   # Focus List key router, Recall field (section 7)
REAL = SECTION7 | ROUTER
hints = []
for path in sorted((ROOT / 'Sources/MemoryUI').glob('*.swift')):
    rel = str(path.relative_to(ROOT))
    text = code(path)
    for line, args in calls(text, 'Keycap'):
        m = re.match(r'\s*"([^"]*)"\s*$', args)
        if m:
            hints.append((rel, line, m.group(1)))
    for m in re.finditer(r'\bkeys:\s*(?:[^,\n()]*\?\s*)?"([^"]+)"(?:\s*:\s*"([^"]+)")?', text):
        line = text.count('\n', 0, m.start()) + 1
        hints += [(rel, line, k) for k in m.groups() if k]
    for m in re.finditer(r'\bhint\("[^"]*",\s*"([^"]*)"', text):
        if m.group(1):
            hints.append((rel, text.count('\n', 0, m.start()) + 1, m.group(1)))
ok(len(hints) >= 8, 'key hints found in MemoryUI', str(len(hints)))
unknown = [f'{r}:{l} "{k}"' for r, l, k in hints if k not in REAL]
ok(not unknown, 'every drawn key hint is a menu command in AppCommands.swift or a router/field key', '; '.join(unknown))
# ux/declutter: the permanent footer that drew these is gone (the menus show every shortcut), so each must be
# bound in a menu, where people find it.
for key in ['⌘K', '⌘[', '⌘]', '⌘,', '⌘P', '⌘↩', '⌘R', '⌘T', '⇧⌘C']:
    ok(key in set(bindings) or (key == '⌘P' and 'pauseShortcut' in commands), f'the shortcut {key} is shown in a menu (bound in AppCommands.swift)')

# ---------------------------------------------------------------------------------------------
# 4. One control per toolbar identifier
ids = {'capture-state': [], 'memory-settings': []}
builds = {'StatusCapsule': [], 'SettingsGearButton': [], 'CaptureControls': []}
for path in sorted((ROOT / 'Sources').rglob('*.swift')):
    rel = str(path.relative_to(ROOT))
    text = code(path)
    for ident in ids:
        ids[ident] += [rel] * len(re.findall(r'\.accessibilityIdentifier\(\s*"' + re.escape(ident) + r'"\s*\)', text))
    for name in builds:
        builds[name] += [rel] * len(re.findall(r'(?<![\w.])' + name + r'\(', text))
# I2 deleted the legacy CaptureControls view (amendments I2), so the status capsule is the only assignment left, plus
# (ux/declutter) the Start Recording pill, which takes the capsule's place while Off: the toolbar draws one or the other
# (if/else in StatusCapsuleItem), never both, and the pill assigns it once (`recordingControl`), to its chevron when it
# has one (an issue to show) and otherwise to its label.
toolbar = code(ROOT / 'Sources/MemoryUI/DaydreamToolbar.swift')
# gold/r2-copy-checks: the if-branch is exactly one StartRecordingButton call with its `more:` chevron, however its
# arguments wrap (the call spans two lines since the pill took its slot width); the else-branch is the capsule. The old
# pattern wanted the call on one line and failed on a tree that was right.
pill = re.search(r'if ToolbarLayout\.showsStart\(state\) \{(?P<start>.*?)\} else \{\s*StatusCapsule\(', toolbar, re.S)
pill_calls = calls(pill.group('start'), 'StartRecordingButton') if pill else []
ok(ids['capture-state'] == ['Sources/MemoryUI/StatusCapsule.swift'] * 2
   and len(pill_calls) == 1 and re.search(r'(^|,)\s*more:', pill_calls[0][1]) is not None
   and pill.group('start').strip() == 'StartRecordingButton(' + pill_calls[0][1] + ')',
   'capture-state is assigned by the status capsule or, in its place while Off, the Start pill (chevron or label, never both)',
   ', '.join(ids['capture-state']))
ok(ids['memory-settings'] == ['Sources/MemoryUI/DaydreamToolbar.swift'], 'memory-settings is assigned once, by the toolbar gear',
   ', '.join(ids['memory-settings']))
ok(builds['StatusCapsule'] == ['Sources/MemoryUI/DaydreamToolbar.swift'], 'the status capsule is built once, by the toolbar',
   ', '.join(builds['StatusCapsule']))
ok(builds['SettingsGearButton'] == ['Sources/MemoryUI/DaydreamToolbar.swift'] * 2,
   'the settings gear is built by the toolbar only (the inline row and the window-toolbar item, one per chrome)',
   ', '.join(builds['SettingsGearButton']))
ok(builds['CaptureControls'] == [], 'nothing in Sources builds the legacy CaptureControls view', ', '.join(builds['CaptureControls']))

for message in failures:
    print('FAIL: ' + message, file=sys.stderr)
print(f'{"FAIL" if failures else "PASS"} check_shortcuts: {passes} passed, {len(failures)} failed')
sys.exit(1 if failures else 0)
