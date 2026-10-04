#!/usr/bin/env python3
"""The release switch for Chrome page history and the signing flag must agree.

`ReleaseFeatures.chromePageHistory` (Sources/MemoryCore/ReleaseFeatures.swift) decides
whether a release has Chrome page history. Only that feature sends Apple Events, so
the release is signed with `--apple-events` exactly when the switch is on.

  python3 scripts/honesty-release-switch-checks.py --flag   prints the flag to sign with
  python3 scripts/honesty-release-switch-checks.py -v       runs the checks

Read-only: imports scripts/developer-id-release.py without running it, reads source
files, and never signs, builds or launches anything.
"""
import argparse
import importlib.util
import plistlib
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SWITCH_FILE = ROOT / 'Sources/MemoryCore/ReleaseFeatures.swift'
SENDER = 'Sources/MacMemApp/ChromeEventSender.swift'
SWITCH_RE = re.compile(r'^\s*public static let chromePageHistory\s*=\s*(true|false)\s*$', re.M)


def chrome_page_history():
    """The switch value, from the one line that sets it."""
    found = SWITCH_RE.findall(SWITCH_FILE.read_text())
    if len(found) != 1:
        raise SystemExit('ReleaseFeatures.swift must set chromePageHistory exactly once (found %d)' % len(found))
    return found[0] == 'true'


def signing_flag(on=None):
    on = chrome_page_history() if on is None else on
    return ['--apple-events'] if on else []


def load_release():
    name = 'developer_id_release_honesty'
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts/developer-id-release.py')
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name]


def strip_comments(text):
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return re.sub(r'//[^\n]*', '', text)


def swift_sources():
    for top in ['Sources', 'WriterBackend/Sources', 'PrivacyPolicy/Sources', 'BrowserBridge']:
        base = ROOT / top
        if base.exists():
            for path in sorted(base.rglob('*.swift')):
                if '.build' not in path.parts:
                    yield path


def function_body(text, signature):
    start = text.index(signature)
    open_brace = text.index('{', start + len(signature) - 1)
    depth = 0
    for i in range(open_brace, len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return text[open_brace + 1:i]
    raise AssertionError('unbalanced braces after ' + signature)


class ReleaseSwitch(unittest.TestCase):
    def test_switch_is_one_documented_constant(self):
        text = SWITCH_FILE.read_text()
        self.assertEqual(len(SWITCH_RE.findall(text)), 1)
        for need in ['--flag', 'honesty-switch-off', '--apple-events', 'browserPagesOn', 'ChromeEventSender']:
            self.assertIn(need, text)
        # Nothing else defines or overrides it.
        for path in swift_sources():
            if path != SWITCH_FILE:
                self.assertNotRegex(strip_comments(path.read_text()), r'chromePageHistory\s*=', str(path.relative_to(ROOT)))

    def test_flag_matches_switch(self):
        on = chrome_page_history()
        self.assertEqual(signing_flag(), ['--apple-events'] if on else [])
        release = load_release()
        # The release script turns the flag into exactly this entitlement for the main app.
        entitlements = release.expected_entitlements(release.MAIN, on)
        self.assertEqual(entitlements, {release.APPLE_EVENTS: True} if on else {})
        self.assertEqual(release.expected_entitlements(release.MAIN, False), {}, 'no flag: the app has no Apple Events entitlement')
        ent = release.entitlements_file(release.MAIN, on)
        self.assertEqual(ent.name if ent else None, 'main-apple-events.entitlements' if on else None)
        # The same flag is passed on to notarize and staple.
        from types import SimpleNamespace
        # sat/updates: signing_flags now also names --no-apple-events and --updates; the Apple Events part
        # still follows the switch exactly (merge sat/v1: rule unchanged, pin updated to the new shape).
        for value in [on, not on]:
            flags = release.signing_flags(SimpleNamespace(apple_events=value, updates='configured'))
            self.assertEqual([f for f in flags if 'apple-events' in f], signing_flag(value) or ['--no-apple-events'])
        self.assertEqual([f for f in release.signing_flags(SimpleNamespace(apple_events=on, updates='off')) if 'apple-events' in f],
                         signing_flag() or ['--no-apple-events'])
        # Every signing command takes the flag.
        parser = release.build_parser()
        subs = [a for a in parser._actions if isinstance(a, argparse._SubParsersAction)][0]
        takes = sorted(n for n, p in subs.choices.items() if any('--apple-events' in a.option_strings for a in p._actions))
        for command in ['sign', 'verify', 'notarize']:
            self.assertIn(command, takes)

    def test_usage_string_when_on(self):
        release = load_release()
        self.assertIn('--apple-events requires NSAppleEventsUsageDescription', release.info_problems({}, False, apple_events=True))
        self.assertNotIn('--apple-events requires NSAppleEventsUsageDescription', release.info_problems({}, False, apple_events=False))
        if chrome_page_history():
            info = plistlib.loads((ROOT / 'packaging/Info.plist').read_bytes())
            self.assertTrue(str(info.get('NSAppleEventsUsageDescription', '')).strip(), 'switch on: the usage string ships')

    def test_optional_release_hook_agrees(self):
        # If the release script ever derives the flag itself, it must derive the same one.
        release = load_release()
        for name in ['RELEASE_APPLE_EVENTS', 'release_apple_events']:
            if hasattr(release, name):
                value = getattr(release, name)
                value = value() if callable(value) else value
                self.assertEqual(bool(value), chrome_page_history(), name)

    def test_every_apple_event_goes_through_the_switch(self):
        # The only code that can build, send or ask about an Apple Event is ChromeEventSender
        # (and the private typing reader, which calls it). Each entry point stops first when off.
        # (Building a target address, NSAppleEventDescriptor(processIdentifier:), sends nothing.)
        words = ['.sendEvent(', 'AEDeterminePermissionToAutomateTarget', 'NSAppleEventDescriptor(eventClass', 'AESendMessage', 'AECreateAppleEvent', 'NSAppleScript', 'OSAScript', 'SBApplication']
        for path in swift_sources():
            rel = str(path.relative_to(ROOT))
            if rel == SENDER:
                continue
            text = strip_comments(path.read_text())
            for word in words:
                self.assertNotIn(word, text, rel)
        sender = strip_comments((ROOT / SENDER).read_text())
        self.assertIn('static var enabled:Bool { ReleaseFeatures.chromePageHistory }', sender)
        entries = {
            'static func send(': 'guard enabled else { return nil }',
            'static func permissionStatus(pid:pid_t) -> OSStatus': 'guard enabled else { return switchedOff }',
            'static func askForChromeAccess(pid:pid_t) -> OSStatus': 'guard enabled else { return switchedOff }',
            'static func pageTransport(pid:pid_t)': 'guard enabled else { return { _ in nil } }',
            'static func signatureValid(pid:pid_t': 'guard enabled,',
        }
        for signature, guard in entries.items():
            body = function_body(sender, signature)
            self.assertTrue(body.strip().startswith(guard), signature + ' starts with ' + guard)
        # Every Apple Event call in the sender sits inside one of those guarded functions.
        guarded = ''.join(function_body(sender, s) for s in entries)
        for word in ['.sendEvent(', 'AEDeterminePermissionToAutomateTarget(', 'NSAppleEventDescriptor(processIdentifier']:
            self.assertEqual(sender.count(word), guarded.count(word), word)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--flag', action='store_true', help='print the signing flag for the current switch and exit')
    args, rest = parser.parse_known_args()
    if args.flag:
        on = chrome_page_history()
        print(' '.join(signing_flag(on)))
        print('Chrome page history is %s: sign %s.' % ('on' if on else 'off', 'with --apple-events' if on else 'without --apple-events'),
              file=sys.stderr)
        return 0
    result = unittest.main(argv=[sys.argv[0]] + rest, exit=False).result
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    sys.exit(main())
