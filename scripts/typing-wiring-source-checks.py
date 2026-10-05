#!/usr/bin/env python3
"""W0 wiring (typing-all SPEC-LATER section 2; typesafe SPEC 12.2 items 2, 3
and 11): the app and capture call the seams they are meant to call.

Source rules only; the behaviour is checked by scripts/typed-launch-checks.swift,
scripts/production-event-capture-checks.swift and PrivacyChecks. Nothing is
built, launched or read from the Keychain here.
"""
import pathlib
import re
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / 'Sources/MacMemApp'


def read(rel):
    return (ROOT / rel).read_text()


def between(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0]


class AppWiring(unittest.TestCase):
    def test_launch_attaches_the_keychain_settles_and_starts_the_timer(self):
        app = read('Sources/MacMemApp/MacMemApp.swift')
        init = between(app, 'init(development:DevelopmentTrial?', 'func refresh()')
        wire = 'TypedTextLaunch.wire(store:store,keys:{KeychainTypedKeyStore.forStore($0)})'
        self.assertEqual(app.count(wire), 1)
        # Outside development trials, before the Coordinator can capture.
        self.assertLess(init.index('if development == nil {'), init.index(wire))
        self.assertLess(init.index(wire), init.index('coordinator = try Coordinator(store:store)'))
        self.assertIn('typedExpiry=' + wire + '.timer', init)
        launch = read('Sources/MacMemApp/TypedTextExpiryTimer.swift')
        body = between(launch, 'static func wire(', '\n    }\n}')
        order = [body.index(s) for s in ['store.coreStoreID()', 'store.attachVault(TypedTextVault(keyStore: keys(id))',
                                         'store.settleLegacyTypedText(', 'store.settleWebsiteTypingRows(', 'timer.start(schedule:']]
        self.assertEqual(order, sorted(order))
        self.assertIn('static let interval: TimeInterval = 3600', launch)
        self.assertIn('store.expireTypedText(now:', launch)
        # writePending keeps its own call to the job.
        # d586301: maintenance preserves certified native narrative before expiry.
        self.assertIn('try expireTypedTextForSummaryMaintenance(now:now)', between(read('Sources/MemoryCore/MemoryStore.swift'), 'func writePending', '\n    }\n'))
        self.assertIn('try expireTypedTextImplementation(now:wall,preservingNarrative:true)', read('Sources/MemoryCore/TypedTextRetention.swift'))

    def test_the_timer_lives_in_the_app_model_not_the_coordinator(self):
        coordinator = read('Sources/MacMemApp/Coordinator.swift')
        for word in ['TypedTextExpiryTimer', 'TypedTextLaunch', 'KeychainTypedKeyStore']:
            self.assertNotIn(word, coordinator)

    def test_only_the_app_constructs_the_keychain_store(self):
        tracked = subprocess.run(['git', 'ls-files', '*.swift'], cwd=ROOT, capture_output=True, text=True, check=True).stdout.split()
        # A construction or any store factory call, not a mention in a comment. owner/v1 review: Remove everything
        # (UninstallService) deletes the history's key through the app's own factory, so it is the one other user.
        use = re.compile(r'^(?!\s*//).*KeychainTypedKeyStore(?:\.\w+)?\(', re.M)
        users = sorted(f for f in tracked if use.search((ROOT / f).read_text(errors='ignore')))
        self.assertEqual(users, ['Sources/MacMemApp/MacMemApp.swift', 'Sources/MacMemApp/TypedTextKeychain.swift', 'Sources/MacMemApp/UninstallService.swift'])
        service = read('Sources/MacMemApp/UninstallService.swift')
        self.assertEqual(re.findall(r'KeychainTypedKeyStore\.\w+\(', service), ['KeychainTypedKeyStore.forUninstall('])

    def test_typing_model_refreshes_on_every_capture_state_change(self):
        app = read('Sources/MacMemApp/MacMemApp.swift')
        self.assertEqual(len(re.findall(r'^\s*let typing=TypingModel\(\)', app, re.M)), 1)
        self.assertIn('typing.attach(store)', app)
        status = between(app, 'func refreshCaptureStatusBounded() {', '\n    }\n')  # gold r3-store: its body (the wrapper bounds its waits)
        self.assertIn('typing.refresh(frontmostBundle:', status)
        self.assertIn('coordinator?.onStateChanged = { [weak self] in self?.refreshCaptureStatus() }', app)


class CaptureWiring(unittest.TestCase):
    def setUp(self):
        self.capture = read('Sources/MacMemApp/EventCapture.swift')

    def test_the_proof_goes_through_the_native_route_with_its_place(self):
        proof = between(self.capture, 'var proof:(UInt64,UInt64)->FocusProof? = {', '\n        }\n')
        self.assertIn('AccessibilityReader.typingProof(', proof)
        self.assertIn('NativeTypingRoute.admits(bundle:proof.bundle,pid:pid)', proof)
        self.assertIn('proof.place=NativeTypingRoute.place(for:pid)', proof)
        route = read('Sources/MacMemApp/NativeTypingRoute.swift')
        self.assertIn('CaptureGate.nativeApps.contains(bundle)', route)
        self.assertIn('AccessibilityReader.focusedWindowTitle(pid: pid)', route)
        # The title reader reads the window's title and nothing else.
        snapshot = read('Sources/MacMemApp/AccessibilitySnapshot.swift')
        title = between(snapshot, 'static func focusedWindowTitle(pid:pid_t)->String? {', '\n    }\n')
        self.assertEqual(re.findall(r'kAX\w+Attribute', title), ['kAXFocusedWindowAttribute', 'kAXTitleAttribute'])
        self.assertEqual(title.count('AXUIElementSetMessagingTimeout('), 2)
        # The binding saves the place as the typed row's title.
        binding = read('adapters/CoreCaptureBinding.swift')
        self.assertIn('title:c.proof.place', between(binding, 'private func write(_ c:TypingCommit', 'store.ingest('))

    def test_an_app_macos_did_not_launch_still_has_an_identity(self):
        # Live test (build 7): Messages reopened at login has no NSRunningApplication.launchDate, and the proof's
        # identity required one, so no key typed in Messages was ever read. The kernel's start time stands in
        # (pid + start + bundle: a reused PID never matches), and the signature check still runs.
        snapshot = read('Sources/MacMemApp/AccessibilitySnapshot.swift')
        identity = between(snapshot, '},identity:{', '},focusedApplication:')
        self.assertIn('let launched=ProcessStart.seconds(launchDate:process.launchDate,pid:pid)', identity)
        self.assertIn('trustedNativeProcess(pid:pid,bundle:bundle)', identity)
        self.assertNotIn('let launched=process.launchDate', identity)
        pages = read('Sources/MemoryCore/ChromePages.swift')
        start = between(pages, 'public static func seconds(launchDate: Date?, pid: Int32) -> Double? {', '\n    }')
        self.assertIn('launchDate.map(\\.timeIntervalSince1970) ?? kernelSeconds(pid: pid)', start)

    def test_system_alerts_and_agents_are_not_activity(self):
        # Live test (build 7): UserNotificationCenter became the day's headline. The snapshot skips the listed system
        # processes and any process that is not a regular app, before any attribute is read; the policy rules drop the
        # same bundles at capture and hide rows already saved.
        snapshot = read('Sources/MacMemApp/AccessibilitySnapshot.swift')
        # perf2-1005: `snapshot` hands its work to `read` (the same reads, safe off the main thread) and keeps the status.
        self.assertIn('let r = read(pid: pid, at: point, captureText: captureText)',
                      between(snapshot, 'static func snapshot(pid: pid_t, at point: CGPoint? = nil, captureText: Bool) -> AccessibilitySnapshot? {', '\n    }\n'))
        body = between(snapshot, 'static func read(pid: pid_t, at point: CGPoint? = nil, captureText: Bool) -> (snapshot: AccessibilitySnapshot?, status: String) {', '\n    }\n')
        skip = 'if SystemProcesses.excluded(bundle:bundle,regularApp:running.activationPolicy == .regular) {'
        self.assertIn(skip, body)
        self.assertLess(body.index(skip), body.index('AXUIElementCreateApplication'))
        models = read('Sources/MemoryCore/Models.swift')
        self.assertIn('Self.sensitiveApps + SystemProcesses.bundleIDs.sorted() + blockedApps', models)
        self.assertIn('"com.apple.UserNotificationCenter"', models)

    def test_a_new_messages_conversation_is_read_again(self):
        # fix/bugs7: the cached conversation name (3 s, keyed by the window, whose title stays "Messages") is dropped at a
        # click, Return and every Command or Control shortcut, so a reply typed to Sam right after texting Maya says Sam.
        tap = between(self.capture, 'fileprivate func handleTap(type: CGEventType, event: CGEvent) {', 'private func handleKeyDown(')
        self.assertIn('MessagesConversation.forget()', between(tap, 'case .leftMouseDown, .rightMouseDown, .otherMouseDown:', 'case .leftMouseUp'))
        key = between(self.capture, 'private func handleKeyDown(_ event: CGEvent) {', 'let stroke=KeyStroke(')
        self.assertIn('keyCode == 36 || keyCode == 76 || flags.contains(.maskCommand) || flags.contains(.maskControl)', key)
        self.assertIn('MessagesConversation.forget()', key)
        route = read('Sources/MacMemApp/NativeTypingRoute.swift')
        self.assertIn('static func forget() { lock.lock(); cache = nil; lock.unlock() }', route)

    def test_escape_and_the_pause_chord(self):
        key = between(self.capture, 'func handleNativeKey(eventAt:UInt64,stroke:KeyStroke', 'private static func identity')
        self.assertIn('let marks = !TypingHotkey.isPauseChord(stroke)', key)
        # Every shortcut marker in the key path honours it.
        self.assertEqual(len(re.findall(r'if marker && marks \{try writeMarker\("keyboard\.shortcut"\)\}', key)), 2)
        self.assertNotRegex(key, r'if marker \{try writeMarker')
        self.assertIn('if reason == .focusKey,stroke.keyCode == Self.escapeKey {escapeTyping()}', key)
        esc = between(self.capture, 'private func escapeTyping() {', '\n    }\n')
        self.assertIn('coordinator.captureBinding.escape(now:', esc)
        self.assertIn('static let escapeKey:Int64=53', self.capture)
        hotkey = read('Sources/MacMemApp/TypingHotkey.swift')
        self.assertIn('TypingPauseShortcut.matches(', hotkey)

    def test_the_binding_runs_the_prompt_latch(self):
        binding = read('adapters/CoreCaptureBinding.swift')
        self.assertIn('typing=TypingSession(promptLatchApps:promptLatchApps)', binding)
        self.assertIn('promptLatchApps:@escaping @Sendable (String)->Bool = TypingSession.tablePromptLatch', binding)
        latch = read('PrivacyPolicy/Sources/PrivacyPolicy/TerminalPromptLatch.swift')
        self.assertRegex(latch, r'public static let wired = true\b')


if __name__ == '__main__':
    unittest.main()
