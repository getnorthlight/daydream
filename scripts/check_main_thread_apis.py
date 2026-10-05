"""Main-queue API lint (claude/crashguard-015). Read-only; no build, no app launch.

Owner laptop 10/04 (public 0.1.4, macOS 15.7.2): DayDream quit with EXC_BREAKPOINT in `_dispatch_assert_queue_fail`
under `TSMTranslateKeyEvent` / `-[NSEvent characters]` on the input tap thread. Text Input Sources, TSM and AppKit's key
translation assert the main QUEUE; macOS 26 doesn't trap, so nothing tested on the mini saw it (fixed in 761fe57). This
lint keeps that kind of call where it can only run on the main queue, over the code of every Swift file of the app's
targets and the local packages it links (comments and string literal text blanked, as scripts/check_macos13_api.py):

1. Queue-asserting APIs (Text Input Sources `TIS*`, `TSM*`, `UCKeyTranslate`, `LMGetKbdType`, `KBGetLayoutType`,
   `NSEvent` character reads and `NSEvent(cgEvent:)`, Carbon hot keys and event handlers) appear only inside the
   functions of `ALLOWED`, and each of those (QA-harness files aside, whose callers assert the main thread) calls
   `MainQueue.require()` before its first such call: debug and check builds trap there, on any macOS, if one is ever
   reached off the main queue. A new use elsewhere fails here until it is wrapped the same way and listed.
2. No code written inside an off-main block (a `DispatchQueue.global` or named queue's `async`/`sync`, `Task.detached`,
   a `Thread`, website typing's executor) names a main-only API: the queue-asserting ones above, AppKit's windows,
   views, menus, status items, pasteboard, screens, alerts, panels and cursor, `MainActor.assumeIsolated` (it traps
   off the main actor) or `objectWillChange` (SwiftUI state). Code inside a block nested in it that goes back to the
   main queue (`DispatchQueue.main.async`, `MainActor.run`, `Task { @MainActor`) is not off-main.
3. The guard itself: `MainQueue.require()` is `dispatchPrecondition(condition: .onQueue(.main))` in debug builds, and
   the Text Input Sources reader answers off the main queue without calling TIS (`KeyboardInputSource`).

4. Website typing's executor files (`EXECUTOR_FILES`: their code runs on the route's executor and the tap thread) read
   secure keyboard input (`IsSecureEventInputEnabled`, HIToolbox) and the frontmost app (`NSWorkspace`) only inside
   `EXECUTOR_MAIN_READS`, each behind a main-queue guard: everything else asks `MainInputFacts`, which answers the
   last main-queue read off the main queue (the same OS family as the macOS 15 trap; never run off main there).

Lexical, so a main-only API one call away from an off-main block is not seen here: the `MainQueue.require()` guards of
rule 1 trap that at run time in every check build, and runner-1001's Main Thread Checker step (AppKit) covers the rest.
Self-tests (`SELF_TESTS`) prove each rule fires on a sample before the tree is judged.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_state_vocabulary import ROOT, line_of, matching_braces, scan  # noqa: E402

FOLDERS = ('Sources', 'UIRender', 'BackupRestore', 'adapters', 'WriterBackend', 'PrivacyPolicy', 'BrowserBridge')
SKIPPED_PARTS = {'.build', 'vendor', 'Vendor', 'Tests'}

# Rule 1: APIs that assert the main queue (TSM's `dispatch_assert_queue`), not just the main thread.
QUEUE_ASSERTING = re.compile(
    r'\bTIS[A-Z]\w*|\bkTISProperty\w*|\bTSM[A-Z]\w*|\bUCKeyTranslate\b|\bLMGetKbdType\b|\bKBGetLayoutType\b'
    r'|\bNSEvent\s*\(\s*cgEvent\s*:|\bcharacters\s*\(\s*byApplyingModifiers\s*:'
    r'|(?P<recv>\w+|\)\??|\]\??)\.characters(?:IgnoringModifiers)?\b(?!\s*\()'
    r'|\b(?:RegisterEventHotKey|UnregisterEventHotKey|InstallEventHandler|RemoveEventHandler|GetApplicationEventTarget'
    r'|GetEventDispatcherTarget|SendEventToEventTarget|RunApplicationEventLoop)\b')

# (file, enclosing declaration's name) -> 'guard' (must call MainQueue.require() first) or 'qa' (QA-harness file).
ALLOWED = {
    ('Sources/MacMemApp/AccessibilitySnapshot.swift', 'selectedSourceID'): 'guard',
    ('Sources/MacMemApp/EventCapture.swift', 'appKitCharacters'): 'guard',
    ('Sources/MacMemApp/TypingHotkey.swift', 'register'): 'guard',
    ('Sources/MacMemApp/TypingHotkey.swift', 'unregister'): 'guard',
    ('Sources/MemoryUI/DaydreamKeyRouter.swift', 'route'): 'guard',
    # QA harness only (`#if DAYDREAM_QA_HARNESS`): fixture trials run on the main thread (`Thread.isMainThread` gates).
    ('Sources/MacMemApp/CaptureFixtureTrial.swift', 'fixedUSKeyboard'): 'qa',
    ('Sources/MacMemApp/CaptureMessagesFixtureTrial.swift', 'fixedUSKeyboard'): 'qa',
}

# Rule 4: secure input and the frontmost app in the files website typing's executor runs, and where they may be read.
EXECUTOR_FILES = ('Sources/MacMemApp/WebTypingRoute.swift', 'Sources/MacMemApp/ChromeTypingWitness.swift')
EXECUTOR_MAIN_READ = re.compile(r'\bIsSecureEventInputEnabled\b|\bfrontmostApplication\b')
# (file, function) -> the main-queue guard it must state before the read.
EXECUTOR_MAIN_READS = {
    ('Sources/MacMemApp/ChromeTypingWitness.swift', 'readLive'): 'MainQueue.require()',
    ('Sources/MacMemApp/ChromeTypingWitness.swift', 'read'): 'dispatchPrecondition(condition: .onQueue(.main))',
}

# Rule 2: main-only APIs (the queue-asserting ones plus AppKit UI and SwiftUI/main-actor state).
MAIN_ONLY = re.compile(
    QUEUE_ASSERTING.pattern +
    r'|\bNSApp\b|\bNSApplication\.shared\b|\bNSWindow\b|\bNSPanel\b|\bNSStatusBar\b|\bNSStatusItem\b|\bNSMenu(?:Item)?\b'
    r'|\bNSPasteboard\b|\bNSScreen\b|\bNSAlert\b|\bNSCursor\b|\bNS(?:Open|Save)Panel\b|\bNSHosting(?:View|Controller)\b'
    r'|\bNSView\b|\.lockFocus\b|\bMainActor\.assumeIsolated\b|\bobjectWillChange\b')
OFF_MAIN_OPENER = re.compile(
    r'\bDispatchQueue\.global\s*\([^)]*\)\s*\.\s*(?:async|asyncAfter|sync)\b'
    r'|\bTask\.detached\b'
    r'|\b(?!main\b)\w*[Qq]ueue\s*\.\s*(?:async|asyncAfter|sync)\b'
    r'|\bexecutor\s*\??\.\s*(?:async|sync|after)\b'
    r'|\bThread\.detachNewThread\b|\bThread\s*\{|\bconcurrentPerform\b')
BACK_TO_MAIN = re.compile(
    r'\bDispatchQueue\.main\s*\.\s*(?:async|asyncAfter|sync)\b|\bMainActor\.run\b|\bTask\s*(?:\([^)]*\))?\s*\{\s*@MainActor')
FUNC = re.compile(r'\bfunc\s+(\w+)')
PROPERTY = re.compile(r'^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|open|static|class|lazy|final|override'
                      r'|weak|unowned|nonisolated(?:\(unsafe\))?)\s+)*(?:var|let)\s+(\w+)[^=]*(?:=\s*)?$')
INIT = re.compile(r'\b(init|deinit)\b\s*[?!]?\s*(?:\(|$)')
# `.characters` is NSEvent's only in files that can see NSEvent.
APPKIT_IMPORT = re.compile(r'^\s*(?:@\w+\s+)*import\s+(?:AppKit|Cocoa|Carbon(?:\.\w+)?|SwiftUI)\b', re.M)


def swift_sources():
    for folder in FOLDERS:
        for path in sorted((ROOT / folder).rglob('*.swift')):
            if not SKIPPED_PARTS.intersection(path.relative_to(ROOT).parts):
                yield path


def block_after(code, pairs, end, reach=240):
    """The brace pair of the closure an opener at `end` takes (its trailing closure or `execute:` argument)."""
    k = code.find('{', end)
    if k < 0 or k - end > reach or k not in pairs:
        return None
    return k, pairs[k]


def enclosing_decl(code, pairs, offset):
    """(name, body's opening brace) of the innermost declaration (func, var, let, init) whose body holds `offset`."""
    opens = sorted((o, c) for o, c in pairs.items() if o < offset < c)
    for o, _ in reversed(opens):
        start = max(code.rfind('}', 0, o), code.rfind('{', 0, o), code.rfind(';', 0, o)) + 1
        header = code[start:o]
        funcs = FUNC.findall(header)
        if funcs:
            return funcs[-1], o
        prop = PROPERTY.match(header.rsplit('\n', 1)[-1])
        if prop:
            return prop.group(1), o
        init = INIT.search(header)
        if init:
            return init.group(1), o
    return None, None


def event_characters_ok(m, appkit):
    """False for a `.characters` match that can't be an NSEvent's: `SomeType.characters` (an enum case or static) or a
    file that doesn't import AppKit (a model's own `characters`)."""
    recv = m.groupdict().get('recv')
    return recv is None or (appkit and not recv[:1].isupper())


def queue_asserting_hits(code, appkit):
    for m in QUEUE_ASSERTING.finditer(code):
        if event_characters_ok(m, appkit):
            yield m


def executor_reads(rel, code, source):
    """Rule 4 findings for one file."""
    if rel not in EXECUTOR_FILES:
        return []
    out, pairs = [], matching_braces(code)
    for m in EXECUTOR_MAIN_READ.finditer(code):
        name, body = enclosing_decl(code, pairs, m.start())
        where = f'{rel}:{line_of(source, m.start())} {m.group(0)} in {name or "top level"}'
        guard = EXECUTOR_MAIN_READS.get((rel, name))
        if guard is None:
            out.append(where + ': read it through MainInputFacts')
        elif code.find(guard, body, m.start()) < 0:
            out.append(where + f': no {guard} before it')
    return out


def lint(files):
    """files: [(rel, source)] -> (findings by rule, counts)."""
    rule1, rule2 = [], []
    allowed_seen, uses = set(), 0
    for rel, source in files:
        code, _ = scan(source)
        pairs = matching_braces(code)
        appkit = bool(APPKIT_IMPORT.search(source))
        qa_file = source.lstrip().startswith('#if DAYDREAM_QA_HARNESS') or '\n#if DAYDREAM_QA_HARNESS' in source[:2000]
        for m in queue_asserting_hits(code, appkit):
            uses += 1
            name, body_start = enclosing_decl(code, pairs, m.start())
            kind = ALLOWED.get((rel, name))
            where = f'{rel}:{line_of(source, m.start())} {m.group(0).strip()} in {name or "top level"}'
            if kind is None:
                rule1.append(where + ': not in a listed main-queue function')
                continue
            allowed_seen.add((rel, name))
            if kind == 'qa':
                if not qa_file:
                    rule1.append(where + ': listed as QA-harness code, but the file is not under #if DAYDREAM_QA_HARNESS')
                continue
            guard = code.find('MainQueue.require()', body_start, m.start())
            if guard < 0:
                rule1.append(where + ': no MainQueue.require() before it')
        for m in OFF_MAIN_OPENER.finditer(code):
            block = block_after(code, pairs, m.end())
            if block is None:
                continue
            o, c = block
            # Blocks nested in it that go back to the main queue are main again.
            main_spans = []
            for b in BACK_TO_MAIN.finditer(code, o, c):
                inner = block_after(code, pairs, b.end())
                if inner:
                    main_spans.append(inner)
            for hit in MAIN_ONLY.finditer(code, o, c):
                if not event_characters_ok(hit, appkit):
                    continue
                if any(a < hit.start() < b for a, b in main_spans):
                    continue
                rule2.append(f'{rel}:{line_of(source, hit.start())} {hit.group(0).strip()} inside the off-main block of '
                             f'{m.group(0).strip()} at line {line_of(source, m.start())}')
    return rule1, rule2, allowed_seen, uses


SELF_TESTS = [
    # (name, file, source, expect rule1 count, expect rule2 count)
    ('TIS outside the list', 'Sources/MacMemApp/X.swift',
     'enum X { static func layout() -> Bool { TISCopyCurrentKeyboardInputSource() != nil } }', 1, 0),
    ('NSEvent characters outside the list', 'Sources/MacMemApp/X.swift',
     'import AppKit\nfunc key(_ e: CGEvent) -> String { NSEvent(cgEvent: e)?.characters ?? "" }', 2, 0),
    ('a model property named characters (no AppKit)', 'PrivacyPolicy/Sources/PrivacyPolicy/X.swift',
     'func n(_ model: M) -> Int { model.characters.count }', 0, 0),
    ('if let is not a declaration', 'Sources/MacMemApp/TypingHotkey.swift',
     'final class R { func unregister() { MainQueue.require(); if let hotKey { UnregisterEventHotKey(hotKey) } } }', 0, 0),
    ('a listed function without the guard', 'Sources/MacMemApp/AccessibilitySnapshot.swift',
     'enum K { private static func selectedSourceID() -> String? { TISCopyCurrentKeyboardInputSource(); return nil } }', 1, 0),
    ('a listed function with the guard', 'Sources/MacMemApp/AccessibilitySnapshot.swift',
     'enum K { private static func selectedSourceID() -> String? { MainQueue.require(); TISCopyCurrentKeyboardInputSource(); return nil } }', 0, 0),
    ('an enum case named characters', 'Sources/MacMemApp/X.swift',
     'func f() { throw NotesMetadataError.characters }', 0, 0),
    ('AppKit in a global queue block', 'Sources/MacMemApp/X.swift',
     'func f() { DispatchQueue.global(qos: .utility).async { NSPasteboard.general.clearContents() } }', 0, 1),
    ('assumeIsolated on a named queue', 'Sources/MacMemApp/X.swift',
     'func f() { readQueue.async { MainActor.assumeIsolated { g() } } }', 0, 1),
    ('back on main inside the block', 'Sources/MacMemApp/X.swift',
     'func f() { Task.detached { let v = load(); DispatchQueue.main.async { MainActor.assumeIsolated { NSApp.activate() } } } }', 0, 0),
    ('the executor', 'Sources/MacMemApp/X.swift',
     'import AppKit\nfunc f() { executor.sync { _ = event.charactersIgnoringModifiers } }', 1, 1),
    ('main queue blocks are not off-main', 'Sources/MacMemApp/X.swift',
     'func f() { DispatchQueue.main.async { NSApp.activate() } }', 0, 0),
]


def main():
    passes, failures = 0, []

    def ok(condition, message, detail=''):
        nonlocal passes
        if condition:
            passes += 1
            print('PASS ' + message)
        else:
            failures.append(message + (f' ({detail})' if detail else ''))

    for name, rel, source, want1, want2 in SELF_TESTS:
        r1, r2, _, _ = lint([(rel, source)])
        ok(len(r1) == want1 and len(r2) == want2, f'self-test: {name}', f'rule 1: {r1}; rule 2: {r2}')

    for name, rel, source, want in [
        ('secure input read in the route', 'Sources/MacMemApp/WebTypingRoute.swift',
         'struct E { var secureInput: () -> Bool = { IsSecureEventInputEnabled() } }', 1),
        ('frontmost app read in the witness', 'Sources/MacMemApp/ChromeTypingWitness.swift',
         'enum W { static func f() -> Int32? { NSWorkspace.shared.frontmostApplication?.processIdentifier } }', 1),
        ('the main-queue reader with its guard', 'Sources/MacMemApp/ChromeTypingWitness.swift',
         'enum M { private static func readLive() -> Bool { MainQueue.require(); return IsSecureEventInputEnabled() } }', 0),
        ('the main-queue reader without its guard', 'Sources/MacMemApp/ChromeTypingWitness.swift',
         'enum M { private static func readLive() -> Bool { IsSecureEventInputEnabled() } }', 1),
        ('another file is not the executor\'s', 'Sources/MacMemApp/EventCapture.swift',
         'func f() -> Bool { IsSecureEventInputEnabled() }', 0)]:
        code = scan(source)[0]
        found = executor_reads(rel, code, source)
        ok(len(found) == want, f'self-test: {name}', '; '.join(found))

    files = [(str(p.relative_to(ROOT)), p.read_text()) for p in swift_sources()]
    rule1, rule2, seen, uses = lint(files)
    rule4 = [f for rel, source in files for f in executor_reads(rel, scan(source)[0], source)]
    ok(not rule4, 'website typing\'s executor files read secure input and the frontmost app only through the main queue '
                  '(MainInputFacts)', '; '.join(rule4))
    facts = (ROOT / 'Sources/MacMemApp/ChromeTypingWitness.swift').read_text().split('enum MainInputFacts {', 1)[-1].split('\n}\n', 1)[0]
    ok('return fresh ? secure : true' in facts and 'return fresh ? front : nil' in facts,
       'off the main queue, secure input reads as on and no app as frontmost when the last main read is missing or stale')
    ok(len(files) >= 200, 'scanned the code of every Swift file of the app targets and linked packages', f'{len(files)} files')
    ok(not rule1, f'queue-asserting APIs only in the listed main-queue functions, each behind MainQueue.require() '
                  f'({uses} uses)', '; '.join(rule1))
    ok(not rule2, 'no main-only API is written inside an off-main block', '; '.join(rule2))
    present = {(rel, name) for rel, name in ALLOWED if (ROOT / rel).exists()}
    ok(seen == present, 'every listed main-queue function still holds such a call (the list does not rot)',
       ', '.join(f'{r}:{n}' for r, n in sorted(present - seen)))

    handoff = (ROOT / 'Sources/MemoryCore/TypingKeyHandoff.swift').read_text()
    require = handoff.split('public static func require()', 1)[-1].split('\n    }', 1)[0]
    ok('dispatchPrecondition(condition: .onQueue(.main))' in require and '_isDebugAssertConfiguration()' in require,
       'MainQueue.require() traps off the main queue in debug and check builds')
    snapshot = (ROOT / 'Sources/MacMemApp/AccessibilitySnapshot.swift').read_text()
    reader = snapshot.split('enum KeyboardInputSource {', 1)[-1].split('\nenum AccessibilityReader', 1)[0]
    direct = reader.split('static func isDirect() -> Bool {', 1)[-1].split('\n    }', 1)[0]
    ok('guard MainQueue.isCurrent else' in direct and direct.index('guard MainQueue.isCurrent else') < direct.index('selectedSourceID()'),
       'Text Input Sources are read only on the main queue; elsewhere the last main-queue value is answered')
    ok('KeyboardInputSource.isDirect()' in snapshot.split('private static func directKeyboardInput()', 1)[-1].split('\n    }', 1)[0],
       'the direct-layout rule (native and website typing) reads through KeyboardInputSource')
    capture = (ROOT / 'Sources/MacMemApp/EventCapture.swift').read_text()
    changed = capture.split('    func inputSourceChanged() {', 1)[-1].split('\n    }', 1)[0]
    ok('KeyboardInputSource.refresh()' in changed, 'an input source change is read again on the main queue at once')

    for message in failures:
        print('FAIL: ' + message, file=sys.stderr)
    print(f'{"FAIL" if failures else "PASS"} check_main_thread_apis: {passes} passed, {len(failures)} failed')
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
