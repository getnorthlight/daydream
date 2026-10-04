#!/usr/bin/env python3
"""claude/typing-1004: the public lane pins what the owner's laptop (public 0.1.4, 2026-10-04) depended on.

Run from the tree root. Reads sources only; builds, launches and permissions are never touched.

1. A public release compiles typing exactly like the owner's copy: stage_swift_flags gives the same typing
   defines for a release and an owner build, and the MacMemOwnerTyping Info.plist key is read only by QA-harness
   code (never a runtime typing gate).
2. A Chrome window whose AX title and Apple Events name disagree (the page's title shape: a notification count, a
   media mark, a profile suffix, a title changing as it loads) is still admitted when it is the only window with
   those bounds; the title only chooses among several. The full join and the bracketed read agree.
3. A tap that never gets a key while keys are typed stops with the reason inputNeedsReopen knows, so Start offers
   Quit & Reopen (or the app restarts itself once), instead of showing Recording while nothing is saved.
"""
import importlib.util
import re
import sys
import unittest
from pathlib import Path

ROOT = Path.cwd()


def source(rel):
    return (ROOT / rel).read_text()


class PublicLane(unittest.TestCase):
    def test_release_and_owner_compile_the_same_typing(self):
        spec = importlib.util.spec_from_file_location('ddrelease', ROOT / 'scripts/developer-id-release.py')
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        release = mod.stage_swift_flags(False, 'auto')
        owner = mod.stage_swift_flags(True, 'off')
        self.assertEqual(release, owner)
        self.assertIn('-DDAYDREAM_OWNER_TYPING', release)
        self.assertIn('-DDAYDREAM_CHROME_TYPING', release)

    def test_owner_typing_plist_key_is_qa_only(self):
        readers = []
        for path in (ROOT / 'Sources').rglob('*.swift'):
            text = path.read_text()
            if 'MacMemOwnerTyping' not in text:
                continue
            readers.append(path.name)
            # Every line that reads it sits inside an #if DAYDREAM_QA_HARNESS block.
            depth = []
            for line in text.splitlines():
                s = line.strip()
                if s.startswith('#if'):
                    depth.append('DAYDREAM_QA_HARNESS' in s and not s.startswith('#if !'))
                elif s.startswith('#endif'):
                    depth.pop()
                elif s.startswith('#else') and depth:
                    depth[-1] = False
                if 'MacMemOwnerTyping' in line:
                    self.assertTrue(any(depth), '%s reads MacMemOwnerTyping outside QA code' % path.name)
        self.assertTrue(readers)

    def test_title_breaks_ties_only(self):
        full = source('Sources/MemoryCore/BrowserTypingJoin.swift')
        self.assertRegex(full, r'if matches\.count == 1 \{ pick = matches\[0\] \}\s*'
                               r'else if matches\.count > 1 \{ return \.failure\(\.ambiguousWindow\) \}\s*'
                               r'else if candidates\.count == 1 \{ pick = 0; step\("window\.titleUnmatched"\) \}')
        self.assertIn('pageName: matches.isEmpty ? "" : names[pick]', full)
        lean = source('Sources/MemoryCore/BrowserTypingJoinBracketed.swift')
        self.assertIn('guard let pick = matches.first ?? (candidates.count == 1 ? 0 : nil) else { return .failure(.window) }', lean)
        self.assertIn('matches.isEmpty ? "" : names[pick]', lean)

    def test_refusal_steps_are_tallied(self):
        tally = source('Sources/MemoryCore/WebTypingRefusals.swift')
        for name in ('step.window.title', 'step.window.titleUnmatched', 'step.frame.chromeUI', 'step.frame.nested', 'tap.noKeys'):
            self.assertIn('"%s"' % name, tally)

    def test_no_keys_stop_offers_quit_and_reopen(self):
        app = source('Sources/MacMemApp/MacMemApp.swift')
        # The tap's own reason, which the app already shows as "Keyboard and mouse aren't reaching DayDream."
        self.assertIn('capture?.stop(reason:"Input event tap unavailable. No recording started.")', app)
        self.assertIn('"Input event tap unavailable. No recording started.": inputUnreachable',
                      source('Sources/MemoryUI/DaydreamCaptureState.swift'))
        self.assertIn('reason.hasPrefix("Input event tap")', app)
        capture = source('Sources/MacMemApp/EventCapture.swift')
        self.assertIn('keyWatch.keyArrived()', capture)
        self.assertIn('onKeysNotArriving', capture)

    # Owner laptop 10/04 (macOS 15.7.2): SIGTRAP under TSMTranslateKeyEvent / -[NSEvent characters] on the route's queue.
    OFF_MAIN_FILES = ('Sources/MacMemApp/WebTypingRoute.swift', 'Sources/MacMemApp/ChromeTypingWitness.swift',
                      'Sources/MemoryCore/BrowserTypingJoin.swift', 'Sources/MemoryCore/BrowserTypingJoinBracketed.swift',
                      'Sources/MemoryCore/ChromeAppleEvents.swift', 'Sources/MemoryCore/TypingKeyHandoff.swift',
                      'Sources/MemoryCore/WebTypingRefusals.swift', 'Sources/MemoryCore/KeyArrivalWatch.swift',
                      'Sources/MemoryCore/BrowserSubmitGesture.swift', 'Sources/MemoryCore/BrowserComposeSignals.swift')
    MAIN_ONLY = re.compile(r'\bNSEvent\b|\.characters\b|charactersIgnoringModifiers|\bTIS[A-Z]\w*|\bTSM\w*|UCKeyTranslate|'
                           r'\bNSPasteboard\b|\bNSApp\b|\bNSApplication\b|\bNSScreen\b|\bNSCursor\b|@MainActor|MainActor\.')

    def test_off_main_typing_files_use_no_main_queue_apis(self):
        for rel in self.OFF_MAIN_FILES:
            path = ROOT / rel
            if not path.exists():
                continue
            for n, line in enumerate(path.read_text().splitlines(), 1):
                code = line.split('//', 1)[0]
                self.assertIsNone(self.MAIN_ONLY.search(code), '%s:%d uses a main-queue API off the main queue' % (rel, n))

    def test_tap_thread_reads_keys_without_appkit(self):
        capture = source('Sources/MacMemApp/EventCapture.swift')
        off = capture.split('fileprivate func handleTapOffMain(', 1)[1].split('\n    }\n', 1)[0]
        self.assertNotIn('NSEvent', off)
        self.assertIn('Self.keyCharacters(event)', off)
        self.assertEqual(capture.count('NSEvent(cgEvent'), 1)
        self.assertIn('static func keyCharacters(_ event: CGEvent, onMain: Bool = MainQueue.isCurrent) -> String', capture)
        self.assertIn('keyboardGetUnicodeString', capture)
        handoff = source('Sources/MemoryCore/TypingKeyHandoff.swift')
        self.assertIn('guard MainQueue.isCurrent else', handoff)


if __name__ == '__main__':
    sys.exit(0 if unittest.main(exit=False, verbosity=2).result.wasSuccessful() else 1)
