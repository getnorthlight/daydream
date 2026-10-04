#!/usr/bin/env python3
"""perm-1004: DayDream never makes macOS show a permission prompt by itself.

macOS shows "<app> would like to control this computer using accessibility features" when an app without Accessibility
uses the Accessibility API, and the same prompt for a posted keyboard event without it. On 10/3 the owner's Live Test copy
showed that prompt: `AccessibilityReader.systemFocusedApplication()` (a system-wide Accessibility read) ran on every status
refresh in the owner build, trusted or not (`TypingModel.keyPanel` -> `NativeTypingRoute.keyPanelBundle`).

Source checks, no build, no launch, no permission read:
1. No request API anywhere in Sources (the prompting forms).
2. Every place that makes an Accessibility root (an application or system-wide element, an observer, a hit test) or posts
   an event checks trust first, inside the same declaration and before the call: AXIsProcessTrusted() for Accessibility,
   and CGPreflightPostEventAccess() as well for a posted event. A guard function named in GUARDS counts as that check.
3. The regression itself: the system-wide focus read and the status refresh's key-panel path are gated.
"""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / 'Sources'
REQUEST_APIS = ['AXIsProcessTrustedWithOptions', 'kAXTrustedCheckOptionPrompt', 'CGRequestListenEventAccess',
                'CGRequestPostEventAccess', 'IOHIDRequestAccess', 'CGRequestScreenCaptureAccess']
AX_ROOTS = re.compile(r'AXUIElementCreateApplication\(|AXUIElementCreateSystemWide\(|AXObserverCreate\(|AXUIElementCopyElementAtPosition\(')
POSTS = re.compile(r'\.post\(tap:|CGEventPost\(|\.postToPid\(')
DECL = re.compile(r'^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|static|class|override|nonisolated|mutating|final)\s+)*(?:(?:func|init)\b|var\b.*\{\s*$)')
# Guard helpers that read trust themselves (file, function name): calling one before the root counts as the check.
GUARDS = {
    'RedditNativeBootstrap.swift': ['allowed('],
}
TRUST = 'AXIsProcessTrusted()'
POST_TRUST = 'CGPreflightPostEventAccess()'

passed = failed = 0
def check(ok, label, detail=''):
    global passed, failed
    if ok:
        passed += 1; print('PASS', label)
    else:
        failed += 1; print('FAIL', label, detail)

def strip_comment(line):
    i = line.find('//')
    return line if i < 0 else line[:i]

files = sorted(SOURCES.rglob('*.swift'))
check(len(files) > 50, 'Sources has the app files', str(len(files)))
for api in REQUEST_APIS:
    users = [str(f.relative_to(ROOT)) for f in files if api in ''.join(strip_comment(l) for l in f.read_text().splitlines(True))]
    check(not users, 'no %s in Sources' % api, ', '.join(users))

def region(lines, index):
    """The enclosing declaration's lines up to and including `index` (the nearest func/init/var above it)."""
    start = index
    while start > 0 and not DECL.match(lines[start]):
        start -= 1
    return [strip_comment(l) for l in lines[start:index + 1]], start

roots = 0
for f in files:
    lines = f.read_text().splitlines()
    for i, raw in enumerate(lines):
        line = strip_comment(raw)
        ax, post = AX_ROOTS.search(line), POSTS.search(line)
        if not (ax or post):
            continue
        roots += 1
        body, start = region(lines, i)
        text = '\n'.join(body)
        guards = GUARDS.get(f.name, [])
        trusted = TRUST in text or any(g in text for g in guards)
        where = '%s:%d (%s)' % (f.relative_to(ROOT), i + 1, lines[start].strip()[:70])
        if ax:
            check(trusted, 'Accessibility trust read before the Accessibility call at ' + where)
        if post:
            check(trusted and (POST_TRUST in text or any(g in text for g in guards)),
                  'trust and post-event preflight before the posted event at ' + where)
check(roots >= 20, 'found the Accessibility roots and event posts', str(roots))

# 3. The 10/3 regression, by name.
snap = (SOURCES / 'MacMemApp/AccessibilitySnapshot.swift').read_text()
m = re.search(r'static func systemFocusedApplication\(\)->pid_t\? \{(.*?)\n    \}', snap, re.S)
check(m is not None and m.group(1).find(TRUST) != -1 and m.group(1).find(TRUST) < m.group(1).find('AXUIElementCreateSystemWide'),
      'systemFocusedApplication reads trust before the system-wide focus read (the 10/3 prompt)')
m = re.search(r'static func typingProof\(.*?\{(.*?)let pid=NativeTypingRoute\.keyTarget', snap, re.S)
check(m is not None and TRUST in m.group(1), 'typingProof reads trust before the key target (a system-wide read)')
route = (SOURCES / 'MacMemApp/NativeTypingRoute.swift').read_text()
check('static var keyFocus: () -> pid_t? = { AccessibilityReader.systemFocusedApplication() }' in route,
      "the status refresh's key-panel read goes through the gated systemFocusedApplication")
typing = (SOURCES / 'MacMemApp/TypingModel.swift').read_text()
check('keyPanel()' in typing, 'TypingModel.refresh still reads the key panel (so the gate above is what keeps it quiet)')
# The comments that promise it stay true.
check('DayDream never shows a macOS permission prompt' in (SOURCES / 'MemoryUI/PermissionSetup.swift').read_text(),
      'the permission page still promises no macOS prompt')
print('permission-prompt-checks: %d passed, %d failed' % (passed, failed))
sys.exit(1 if failed else 0)
