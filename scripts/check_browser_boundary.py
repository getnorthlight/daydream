"""Source invariants for native wiring; never execute browser/permission APIs."""
from pathlib import Path
import re
import unittest
ROOT = Path(__file__).resolve().parents[1]
FLAG = 'DAYDREAM_CHROME_TYPING'
# The Apple Event allowlist (plan section 3): the only event DayDream may send
# is core/getd, and the only properties it may read are these six.
AE_EVENT = ('core', 'getd')
AE_PROPERTIES = {'mode', 'ID  ', 'pbnd', 'pnam', 'URL ', 'acTa'}
# Descriptor keywords and types used to build and decode those reads. No event
# class, event ID or property code outside AE_EVENT/AE_PROPERTIES may appear.
AE_STRUCTURE = {'----', 'errn', 'want', 'form', 'seld', 'from', 'obj ', 'abso', 'firs', 'all ', 'null',
                'utxt', 'TEXT', 'type', 'enum', 'list', 'qdrt'}
AE_OBJECTS = {('cwin', 'indx'), ('cwin', 'ID  '), ('CrTb', 'ID  '), ('prop', 'prop')}
CHROME_AE_FILES = ['Sources/MacMemApp/ChromeModeReader.swift', 'Sources/MemoryCore/ChromeAppleEvents.swift',
                   'Sources/MemoryCore/BrowserTypingJoin.swift', 'Sources/MacMemApp/ChromeTypingWitness.swift',
                   'Sources/MacMemApp/ChromeEventSender.swift', 'Sources/MemoryCore/ChromePages.swift']
# The one file that may build, send or permission-check an Apple Event.
SENDER = 'Sources/MacMemApp/ChromeEventSender.swift'
# The only files that may name the sender: itself, the page recorder, the app
# model (Settings' Chrome access row: read-only checks, and Allow's one prompt),
# and the private typing reader and witness.
APP_MODEL = 'Sources/MacMemApp/MacMemApp.swift'
SENDER_USERS = {SENDER, 'Sources/MacMemApp/ChromePageRecorder.swift', 'Sources/MacMemApp/ChromeModeReader.swift',
                'Sources/MacMemApp/ChromeTypingWitness.swift', APP_MODEL}
# Private-build-only Chrome typing files: compiled out unless -DDAYDREAM_CHROME_TYPING.
CHROME_TYPING_FILES = ['Sources/MemoryCore/BrowserTypingJoin.swift', 'Sources/MacMemApp/ChromeTypingWitness.swift',
                       'Sources/MacMemApp/ChromeModeReader.swift', 'Checks/ChromeTypingChecks.swift',
                       # QF-17 (fix/chrome-join-async): the bracketed design's engine, held buffer and single read.
                       'Sources/MemoryCore/ChromeBracket.swift', 'Sources/MemoryCore/BrowserTypingJoinBracketed.swift',
                       # Website typing (typing-all SPEC-LATER 4.2): its focus gate and its checks.
                       'PrivacyPolicy/Sources/PrivacyPolicy/WebTypingGate.swift', 'Checks/WebTypingChecks.swift',
                       # fix/chrome-capture: the Post gesture (a click proven on the composer's own Post button).
                       'Sources/MemoryCore/BrowserSubmitGesture.swift',
                       # fix/chrome-x: a Chrome composer's compose signals (route kind, reply phrases, AX-only re-read).
                       'Sources/MemoryCore/BrowserComposeSignals.swift']
# The only files that may name the flag at all (review C7): the flagged files,
# the check entry point that calls them, and the scripts that build or check them.
FLAG_FILES = set(CHROME_TYPING_FILES) | {'Checks/main.swift', 'Checks/ChromeBracketChecks.swift', 'scripts/check_browser_boundary.py', 'scripts/chrome-typing-checks.py',
                                         # claude/scrub-1004: README's Build from source names the release's two typing flags.
                                         'README.md',
                                         'scripts/chrome-apple-event-parse-checks.swift', 'scripts/daydream-core-source-checks.py',
                                         # The owner build (SPEC-LATER section 3) needs Chrome typing too: the
                                         # packager's owner block, the compile guard and its check.
                                         'scripts/package.sh', 'Sources/MemoryCore/OwnerTypingGuard.swift', 'scripts/typing-release-gate-checks.py',
                                         # The release pipeline's stage (one OWNER_SWIFT_FLAGS tuple, pinned below, used
                                         # for every stage since the owner's decision of 2026-09-25) and its check.
                                         'scripts/developer-id-release.py', 'scripts/check_developer_id_release.py',
                                         # launch/candidate (summaries line): the DayDream Preview builder passes the same
                                         # flags as the release stage; the sample fixture names the web-typing provider
                                         # only under the flag (release-scan keeps the public binary clean).
                                         'scripts/preview/build-preview-app.sh', 'Sources/MemoryCore/PreviewSample.swift',
                                         # CODEX-E-1001: reviewed nonshipping copied headless check recipes.
                                         'runner-1001/run-checks.sh', 'runner-1001/owner-lane.sh'}
# Website typing (typing-all SPEC-LATER 4.2, the web track): its owner-only
# row, rules and strings live in the Chrome typing core file; its end-to-end
# check drives the actual EventCapture in the owner build.
WEB_OWNER_FILES = ['Sources/MemoryCore/BrowserTypingJoin.swift', 'scripts/production-event-capture-checks.swift',
                   # fix/chrome-capture: the store's one amendment for a proven Post click (owner block of the gesture file).
                   'Sources/MemoryCore/BrowserSubmitGesture.swift']
# The shared files where website typing hooks in, and how many owner blocks
# each may have. Each block is short, calls only owner-only website typing
# names, and (except CaptureSession's write extension) keeps the public code
# in its #else or after its #endif (test_owner_hooks_are_small).
OWNER_HOOKS = {'Sources/MemoryCore/BrowserSafety.swift': 1, 'Sources/MemoryCore/TypedTextStore.swift': 1,
               'Sources/MemoryCore/TypingIndicator.swift': 2, 'Sources/MemoryCore/CaptureSession.swift': 2,
               'Sources/MacMemApp/AccessibilitySnapshot.swift': 1}
# owner/v1 review: shared text that must be true of the build it is shown in. Each file names the
# flag in exactly one #if/#else/#endif around plain strings (test_owner_text_blocks_are_strings); the
# #else keeps the public text, pinned here.
OWNER_TEXT_FILES = {
    'Sources/MemoryUI/ChromePagesSettings.swift': ["It never saves what's on the page, what you type, or your clicks."],
    'Sources/MemoryCore/Diagnostics.swift': ['"Typed text (Notes and TextEdit)"'],
    'Sources/MemoryUI/PermissionSetup.swift': ['"Notice clicks while recording, and typing in Notes and TextEdit only if you turn typed text on."',
                                              '"Notices clicks, and typing in Notes and TextEdit."'],
    # typingfix (owner/v1 review F4): the typed-text switch and the safe-typing screen name websites in Chrome.
    'Sources/MemoryUI/OnboardingScreens.swift': ['public static var typedTextScope: String { "\\(TypingSettingsText.allowedAppsPhrase()) only" }',
                                                'public static let websiteTypingBullet: String? = nil'],
}
# The website typing row's proof provider: owner-only code names it (the public store never does).
WEB_ROW_PROVIDER = 'chrome-typing-join-v1'
# The owner switch: the only files that may name DAYDREAM_OWNER_TYPING.
OWNER_FLAG = 'DAYDREAM_OWNER_TYPING'
OWNER_FLAG_FILES = {'PrivacyPolicy/Sources/PrivacyPolicy/OwnerTyping.swift', 'Sources/MemoryCore/OwnerTypingGuard.swift',
                    'Sources/MacMemApp/WebTypingRoute.swift', 'Sources/MacMemApp/EventCapture.swift', 'scripts/package.sh',
                    'scripts/developer-id-release.py', 'scripts/typing-release-gate-checks.py', 'scripts/check_browser_boundary.py',
                    'scripts/daydream-core-source-checks.py',
                    # claude/scrub-1004: README's Build from source names the release's two typing flags.
                    'README.md',
                    # claude/chrome-offmain-1003: the replay of website typing on and off the main thread (owner build only).
                    'scripts/chrome-offmain-checks.swift',
                    # typing-all apps track: the web-content proof's live reads (owner build only).
                    'Sources/MacMemApp/AccessibilitySnapshot.swift',
                    # messages-1003 (2734e01): the Messages composer's placeholder label is read in the owner build only.
                    'Sources/MacMemApp/MessagesComposer.swift',
                    # typing-all ui track: the owner-only "Other websites" strings, and their check.
                    'Sources/MemoryUI/TypingSettings.swift', 'scripts/typing-ui-checks.swift',
                    # owner/v1: the release pipeline's `stage --owner-build` checks.
                    'scripts/check_developer_id_release.py',
                    # gold/capture-input: the owner build of these checks swaps in a fake website-typing route (no live Chrome read).
                    'scripts/capture-input-checks.swift',
                    # launch/candidate (summaries line): the Preview builder's flags, the sample's build flavor, and the
                    # threads golden day's owner-build expectation.
                    'scripts/preview/build-preview-app.sh', 'Sources/MemoryCore/PreviewSample.swift', 'Checks/ThreadChecks.swift',
                    # fix/sx-day-card: the stale-card check's owner-build expectations (typed rows are recorded).
                    'scripts/stale-card-checks.swift',
                    # fix/sx-all round 3: the docs check reads the owner build's Chrome site-only line from its block, and
                    # the writer's "would typing be recorded here" fact asks the owner build's website rules (public: never).
                    'scripts/docs-claims-checks.py', 'Sources/MemoryCore/WriterFacts.swift',
                    # CODEX-E-1001: reviewed nonshipping copied headless check recipes.
                    'runner-1001/run-checks.sh', 'runner-1001/owner-lane.sh'} | set(WEB_OWNER_FILES) | set(OWNER_HOOKS) | set(OWNER_TEXT_FILES)
# The owner block in scripts/package.sh: the one place a build turns either flag on.
OWNER_BLOCK = re.compile(r'if \[\[ "\$\{DAYDREAM_OWNER_TYPING:-\}" == 1 \]\]; then\n(.*?)\nfi\n', re.S)
# Every Accessibility attribute the Chrome witness may read (review I5).
WITNESS_SEARCH = {'AXUIElementsForSearchPredicate', 'AXResultsLimit', 'AXDirection', 'AXDirectionNext',
                  'AXSearchKey', 'AXTextFieldSearchKey', 'AXButtonSearchKey', 'AXCheckBoxSearchKey', 'AXLinkSearchKey', 'AXSearchText'}
WITNESS_AX = {'AXRole', 'AXSubrole', 'AXParent', 'AXFocusedWindow', 'AXFocusedUIElement', 'AXWindows', 'AXPosition', 'AXSize',
              'AXMinimized', 'AXTitle', 'AXURL', 'AXDescription', 'AXPlaceholderValue', 'AXDOMIdentifier', 'AXDOMClassList',
              'AXEditableAncestor',
              # fix/chrome-capture: whether the button under a Post click is enabled.
              'AXEnabled',
              # fix/chrome-capture (QF-11, QF-3): the containers around a typed field, for its form scan.
              'AXChildren',
              # claude/int-1003 (compose-send/v1): the proven composer's character count after a send gesture (never its value).
              'AXNumberOfCharacters'}
SOURCE_ROOTS = ['Sources', 'adapters', 'PrivacyPolicy/Sources', 'BrowserBridge/Sources', 'WriterBackend/Sources',
                'BackupRestore/Native', 'BackupRestore/Worker', 'UIRender']

def swift_sources():
    for root in SOURCE_ROOTS:
        for path in sorted((ROOT/root).rglob('*.swift')):
            if '.build' not in path.parts:
                yield path

def apple_event_allowlist(case):
    """Replaces the old banned-word check: every Apple Event DayDream can
    express is core/getd of an allowlisted property, built in one place and
    sent from one function. Raw codes cannot slip past it."""
    texts = {f: (ROOT/f).read_text() for f in CHROME_AE_FILES}
    events = (ROOT/'Sources/MemoryCore/ChromeAppleEvents.swift').read_text()
    case.assertIn('public static let eventClass = "%s"' % AE_EVENT[0], events)
    case.assertIn('public static let eventID = "%s"' % AE_EVENT[1], events)
    declared = re.search(r'readableProperties: Set<String> = \[([^\]]*)\]', events).group(1)
    case.assertEqual(set(re.findall(r'"(.{4})"', declared)), AE_PROPERTIES)
    for name in ['windowProperties', 'tabProperties']:
        subset = re.search(name + r': Set<String> = \[([^\]]*)\]', events).group(1)
        case.assertLessEqual(set(re.findall(r'"(.{4})"', subset)), AE_PROPERTIES, name)
    # The audit grammar accepts only the allowlisted object forms.
    audit = events.split('private static func node(', 1)[1]
    case.assertEqual(set(re.findall(r'case \("(.{4})", "(.{4})"\)', audit)), AE_OBJECTS)
    seen = set()
    for f, text in texts.items():
        codes = set(re.findall(r'code\("(.{4})"\)', text))
        case.assertLessEqual(codes, AE_STRUCTURE | AE_PROPERTIES, f)
        objects = set(re.findall(r'object\("(.{4})", form: "(.{4})"', text))
        case.assertLessEqual(objects, AE_OBJECTS, f)
        properties = set(re.findall(r'property\("(.{4})"', text)) | set(re.findall(r'property: "(.{4})"', text))
        case.assertLessEqual(properties, AE_PROPERTIES, f)
        seen |= codes | properties | {o for pair in objects for o in pair}
        # Codes are spelled only through code("...") so the scan above sees them all.
        case.assertIsNone(re.search(r'\b(FourCharCode|OSType|AEEventClass|AEEventID|DescType)\(', text), f)
        case.assertIsNone(re.search(r'(typeCode|enumCode|eventClass|eventID|descriptorType|forKeyword):\s*0x', text), f)
    case.assertGreaterEqual(seen, {'want', 'form', 'seld', 'from', 'abso', 'cwin', 'CrTb', 'prop'} | AE_PROPERTIES)  # scan is not vacuous
    join = texts['Sources/MemoryCore/BrowserTypingJoin.swift']
    mapping = join.split('public var property: String {', 1)[1].split('public var windowID', 1)[0]
    case.assertLessEqual(set(re.findall(r'return "(.{4})"', mapping)), AE_PROPERTIES)
    pages = texts['Sources/MemoryCore/ChromePages.swift']
    mapping = pages.split('public var specifier: NSAppleEventDescriptor? {', 1)[1].split('public func decode', 1)[0]
    case.assertEqual(set(re.findall(r'property: "(.{4})"', mapping)) | set(re.findall(r'property\("(.{4})"', mapping)), {'mode', 'ID  ', 'URL ', 'pnam'})
    case.assertIn('return built.flatMap { ChromeAppleEvents.audit($0) ? $0 : nil }', mapping)
    reader = texts[SENDER]
    case.assertEqual(reader.count('NSAppleEventDescriptor(eventClass:'), 1)
    case.assertIn('NSAppleEventDescriptor(eventClass:code(ChromeAppleEvents.eventClass),eventID:code(ChromeAppleEvents.eventID)', reader)
    # Two permission calls: the read that never asks (permissionStatus, last
    # argument false), and the one call that lets macOS ask (last argument true),
    # inside askForChromeAccess. Same core/getd scope for both.
    case.assertEqual(reader.count('AEDeterminePermissionToAutomateTarget('), 2)
    never_asks = 'AEDeterminePermissionToAutomateTarget(target.aeDesc,code(ChromeAppleEvents.eventClass),code(ChromeAppleEvents.eventID),false)'
    asks = 'AEDeterminePermissionToAutomateTarget(target.aeDesc,code(ChromeAppleEvents.eventClass),code(ChromeAppleEvents.eventID),true)'
    case.assertEqual(reader.count(never_asks), 1)
    case.assertEqual(reader.count(asks), 1)
    status = reader.split('static func permissionStatus(pid:pid_t) -> OSStatus {', 1)[1].split('\n    }', 1)[0]
    case.assertIn(never_asks, status)
    ask = reader.split('static func askForChromeAccess(pid:pid_t) -> OSStatus {', 1)[1].split('\n    }', 1)[0]
    case.assertIn(asks, ask)
    case.assertEqual(len(re.findall(r',\s*true\s*\)', reader)), 1)  # the one asking call is the only `, true)`
    case.assertEqual(reader.count('.sendEvent('), 1)
    sender = reader.split('static func send(', 1)[1].split('static func permissionStatus(', 1)[0]
    guard = 'guard let specifier, ChromeAppleEvents.audit(specifier, everyWindow:everyWindow) else { return nil }'
    case.assertEqual(sender.count('ChromeAppleEvents.audit('), 1)
    case.assertLess(sender.index(guard), sender.index('.sendEvent('))
    case.assertIn("event.setParam(specifier,forKeyword:code(\"----\"))", sender)
    # QF-17 PM7: `… of every window` is IDs only unless a caller widens it; only Chrome typing's join session and its
    # request builder pass the typing scope (modes and bounds, never names, tabs or URLs), and the audit clamps any
    # scope to those three whatever a caller passes.
    case.assertIn('everyWindow:Set<String> = ChromeAppleEvents.everyWindowDefault) -> NSAppleEventDescriptor? {', sender)
    case.assertIn('public static let everyWindowDefault: Set<String> = ["ID  "]', events)
    audit_fn = events.split('public static func audit(', 1)[1].split('private static func node(', 1)[0]
    case.assertIn('everyWindow: Set<String> = everyWindowDefault) -> Bool {', audit_fn)
    case.assertIn('let every = everyWindow.intersection(["ID  ", "mode", "pbnd"])', audit_fn)
    case.assertIn('case .windows?: return every.contains(name) ? .value : nil', audit)
    case.assertIn('case .frontWindow?: return name == "ID  " ? .value : nil', audit)
    case.assertIn('public static let everyWindow: Set<String> = ["ID  ", "mode", "pbnd"]', join)
    case.assertIn('return built.flatMap { ChromeAppleEvents.audit($0, everyWindow: Self.everyWindow) ? $0 : nil }', join)
    widen = {}
    for path in swift_sources():
        text, rel = path.read_text(), str(path.relative_to(ROOT))
        n = len(re.findall(r'everyWindow:\s*(ChromeJoinRequest\.everyWindow|Self\.everyWindow)', text))
        if n: widen[rel] = n
    case.assertEqual(widen, {'Sources/MacMemApp/ChromeModeReader.swift': 1, 'Sources/MemoryCore/BrowserTypingJoin.swift': 1})
    reader_session = texts['Sources/MacMemApp/ChromeModeReader.swift']
    case.assertIn('everyWindow:ChromeJoinRequest.everyWindow).flatMap(request.decode)', reader_session)
    # Page history keeps the default (IDs of every window only).
    case.assertNotIn('everyWindow:', pages)
    case.assertEqual(sender.count('setParam('), 1)
    case.assertIn('.neverInteract', sender)
    # Nothing else in the app or its packages can send an Apple Event or run a script.
    for path in swift_sources():
        text, rel = path.read_text(), str(path.relative_to(ROOT))
        for word in ['NSAppleScript', 'OSAScript', 'SBApplication', 'osascript', 'AESendMessage', 'AECreateAppleEvent', 'executeJavaScript']:
            case.assertNotIn(word, text, rel)
        if rel != SENDER:
            for word in ['NSAppleEventDescriptor(eventClass', '.sendEvent(options', 'AEDeterminePermissionToAutomateTarget']:
                case.assertNotIn(word, text, rel)
        if rel not in SENDER_USERS:
            case.assertNotIn('ChromeEventSender.', text, rel)
        # Review I5: only the flagged witness reaches the reader, and nothing
        # ever asks macOS to prompt for Automation.
        if rel not in ('Sources/MacMemApp/ChromeModeReader.swift', 'Sources/MacMemApp/ChromeTypingWitness.swift'):
            for word in ['ChromeModeReader.permission(', 'ChromeModeReader.JoinSession(', 'ChromeModeReader.send(', 'ChromeModeReader.read(']:
                case.assertNotIn(word, text, rel)
        case.assertIsNone(re.search(r'request\s*:\s*true', text), rel)
        # UI slice: macOS is asked only from askForChromeAccess, which only the
        # model's allowChromeAccess() calls, which only the Allow… button and the
        # model's own askChromeAccessInSetup (setup's Chrome row on Permissions) and
        # askChromeAccessAfterSetup (after that row's unanswered press) call.
        if rel not in (SENDER, APP_MODEL):
            case.assertNotIn('askForChromeAccess(', text, rel)
        if rel not in (APP_MODEL, 'Sources/MacMemApp/DaydreamSettings.swift'):
            case.assertNotIn('allowChromeAccess(', text, rel)
        if rel != SENDER:
            case.assertIsNone(re.search(r'AEDeterminePermissionToAutomateTarget|askUserIfNeeded', text), rel)
    model = (ROOT/APP_MODEL).read_text()
    case.assertEqual(model.count('askForChromeAccess('), 1)
    case.assertEqual(model.count('func allowChromeAccess('), 1)
    allow = model.split('func allowChromeAccess() {', 1)[1].split('\n    }\n', 1)[0]
    case.assertIn('ChromeEventSender.askForChromeAccess(pid:pid)', allow)
    # Chrome running, then Google's signature, then the prompt, off the main thread.
    case.assertLess(allow.index('env.running()'), allow.index('env.background {'))
    case.assertLess(allow.index('env.background {'), allow.index('env.verify(pid)'))
    case.assertLess(allow.index('env.verify(pid)'), allow.index('askForChromeAccess('))
    check = model.split('func checkChromeAccess() {', 1)[1].split('\n    }\n', 1)[0]
    case.assertNotIn('ask', check.replace('askingChromeAccess', ''))
    case.assertIn('env.status(pid)', check)
    case.assertLess(check.index('env.background {'), check.index('env.status(pid)'))
    live = model.split('static var live:ChromeAccessEnvironment {', 1)[1].split('\n    }', 1)[0]
    case.assertIn('ask:nil', live)
    case.assertIn('status:{ChromeEventSender.permissionStatus(pid:$0)}', live)
    settings = (ROOT/'Sources/MacMemApp/DaydreamSettings.swift').read_text()
    case.assertEqual(settings.count('allowChromeAccess('), 1)
    case.assertIn('allow: { model.allowChromeAccess() }', settings)
    card = (ROOT/'Sources/MemoryUI/ChromePagesSettings.swift').read_text()
    # The card reads access when it appears; only its Allow… button calls allow().
    case.assertIn('.onAppear { if savedOn { checkAccess() } }', card)
    case.assertEqual(card.count('allow()'), 1)
    case.assertIn('case .allow: allow()', card)

class BrowserBoundary(unittest.TestCase):
    def test_native_typed_only_and_current_policy_before_characters(self):
        source=(ROOT/'Sources/MacMemApp/AccessibilitySnapshot.swift').read_text()
        native=source.split('status="Supported native app observation."',1)[1].split('/// Safari and Chrome',1)[0]
        self.assertNotIn('kAXValueAttribute',native)
        self.assertNotIn('kAXSelectedTextAttribute',native)
        self.assertIn('selectedText: nil',native)
        key=(ROOT/'Sources/MacMemApp/EventCapture.swift').read_text().split('func handleNativeKey',1)[1].split('private static func identity',1)[0]
        self.assertLess(key.index('freshTypingProof()'),key.index('return try acquire()'))
        self.assertLess(key.index('CaptureGate.typing(final'),key.index('return try acquire()'))
        coordinator=(ROOT/'Sources/MacMemApp/Coordinator.swift').read_text().split('func acceptsTyping',1)[1].split('private func evidence',1)[0]
        self.assertIn('store.policy()',coordinator)
        self.assertIn('PreCapturePrivacy.nativeTypingAllowed',coordinator)
    def test_buffer_invalidated_before_debounce_and_policy_save(self):
        source=(ROOT/'Sources/MacMemApp/EventCapture.swift').read_text()
        handler=source.split('func handleAX',1)[1].split('private func processAX',1)[0]
        # Focus and window changes seal the typed unit before the debounce.
        self.assertLess(handler.index('sealTyping('),handler.index('DispatchWorkItem'))
        flush=source.split('func flushNativeText',1)[1].split('private func',1)[0]
        self.assertLess(flush.index('freshTypingProof()'),flush.index('commitTypedText('))
        coordinator=(ROOT/'Sources/MacMemApp/Coordinator.swift').read_text()
        self.assertIn('captureBinding.commitText(id:id,proof:proof,now:now,reason:reason,sentText:sentText)',coordinator)
        ui=(ROOT/'Sources/MacMemApp/MacMemApp.swift').read_text().split('func savePolicy()',1)[1].split('struct MemoryWindow',1)[0]
        self.assertNotIn('store.updatePolicy(',ui)
        autosave=(ROOT/'Sources/MacMemApp/PreferenceAutosave.swift').read_text()
        flush=autosave.split('func flush()',1)[1].split('func reload()',1)[0]
        self.assertLess(flush.index('stopProducer()'),flush.index('store.savePreferences('))
        self.assertLess(flush.index('store.savePreferences('),flush.index('policy=result.policy'))
        self.assertIn('expectedRevision:policy.revision',flush)
        self.assertIn('Not saved. Recording is stopped.',ui)
        stop=coordinator.split('func stopForPreferences',1)[1].split('func reconcileResume',1)[0]
        self.assertLess(stop.index('stop()'),stop.index('capture?.stop('))
    def test_browser_keys_stop_before_character_extraction(self):
        source=(ROOT/'Sources/MacMemApp/EventCapture.swift').read_text()
        key=source.split('private func handleKeyDown',1)[1].split('func handleNativeKey',1)[0]
        self.assertLess(key.index('handleNativeKey('),key.index('NSEvent(cgEvent:'))
        witness=(ROOT/'Sources/MacMemApp/AccessibilitySnapshot.swift').read_text().split('static func typingProof',1)[1].split('private static func directKeyboardInput',1)[0]
        self.assertLess(witness.index('CaptureGate.nativeApps.contains'),witness.index('AXUIElementCreateApplication'))
    def test_typed_units_read_nothing_before_gate_and_latch(self):
        binding=(ROOT/'adapters/CoreCaptureBinding.swift').read_text()
        insert=binding.split('public func insert(proof:',1)[1].split('public func append(',1)[0]
        self.assertLess(insert.index('captureStatus()'),insert.index('CaptureGate.typing('))
        self.assertLess(insert.index('CaptureGate.typing('),insert.index('typing.admit('))
        self.assertLess(insert.index('typing.admit('),insert.index('readCharacters()'))
        self.assertEqual(insert.count('readCharacters()'),1)
        write=binding.split('private func write(_ c:TypingCommit',1)[1]
        self.assertLess(write.index('Privacy.secret('),write.index('store.ingest('))
        self.assertIn('requireRecording:true',write.split('store.ingest(',1)[1].split('\n',1)[0])
    def test_departure_reads_metadata_only_and_never_browsers(self):
        source=(ROOT/'Sources/MacMemApp/AccessibilitySnapshot.swift').read_text()
        departure=source.split('static func departureState()',1)[1].split('/// Build a snapshot for',1)[0]
        for attribute in ['kAXValueAttribute','kAXSelectedTextAttribute','kAXTitleAttribute','kAXDescriptionAttribute','kAXPlaceholderValueAttribute']:
            self.assertNotIn(attribute,departure)
        self.assertLess(departure.index('CaptureSession.excludedBrowsers.contains(bundle)'),departure.index('AXUIElementCreateApplication'))
        self.assertIn('0.025',departure)
        capture=(ROOT/'Sources/MacMemApp/EventCapture.swift').read_text()
        handler=capture.split('func handleAX',1)[1].split('private func processAX',1)[0]
        self.assertNotIn('discardPending',handler)
        self.assertNotIn('sealTyping(.title',handler)
    def test_no_script_or_browser_launch_and_no_implicit_permission_request(self):
        source=(ROOT/SENDER).read_text()
        apple_event_allowlist(self)
        self.assertNotIn('NSWorkspace.shared.open',source)
        self.assertNotIn('NSWorkspace.shared.open',(ROOT/'Sources/MacMemApp/ChromePageRecorder.swift').read_text())
        self.assertIn('eventID),false)',source)
        # Review M4: the signature check uses the one flag set everywhere it
        # checks Chrome. typing-all final review (critical): that flag set is
        # empty. SecCodeCheckValidity (running code) rejects
        # kSecCSDoNotValidateResources with errSecCSInvalidFlags, which failed
        # every check; with no flags it does not hash Chrome's resources.
        # browser-app-0227 runs the real call against its own process.
        self.assertIn('static let signatureFlags=SecCSFlags(rawValue:0)',source)
        self.assertNotIn('kSecCSDoNotValidateResources',source)
        self.assertEqual(re.findall(r'SecCodeCheckValidity\(code,(\w+),requirement\)',source),['signatureFlags'])
        self.assertEqual(source.count('SecCodeCheckValidity('),1)
        self.assertIn('.neverInteract',source)
        self.assertIn('processIdentifier:pid',source)
        self.assertIn('deadline',source)
        ui=(ROOT/'Sources/MemoryUI/SetupView.swift').read_text()
        # ux/declutter: Settings › Advanced (SetupView) no longer repeats the browsers card; "Web pages in Chrome"
        # is said once, on Settings › Apps to remember (ChromePagesCard), with the unknown-browser line (honesty H8).
        self.assertNotIn('browsersTitle',ui)
        self.assertNotIn('Web pages in Chrome',ui)
        chrome=(ROOT/'Sources/MemoryUI/ChromePagesSettings.swift').read_text()
        self.assertIn('public static let title = "Web pages in Chrome"',chrome)
        self.assertIn("A browser DayDream doesn't know by name is skipped too if it opens web links.",chrome)
        self.assertNotIn('Browser capture unavailable',ui)
        self.assertNotIn('requestChromePermission',ui)
        app=(ROOT/'Sources/MacMemApp/MacMemApp.swift').read_text()
        self.assertNotIn('ChromeModeReader.permission',app)
        self.assertNotIn('confirmBrowserPermission',ui)
        self.assertNotIn('Button("Ask macOS")',ui)
        self.assertNotIn('requestChromePermission()',ui.split('.task {',1)[1].split('}',1)[0])
    def test_browser_path_never_reads_ax_content_or_selection(self):
        source=(ROOT/'Sources/MacMemApp/AccessibilitySnapshot.swift').read_text()
        browser=source.split('if CaptureSession.excludedBrowsers.contains(bundle) {',1)[1].split('let appElement',1)[0]
        for attribute in ['kAXValueAttribute','kAXSelectedTextAttribute','kAXTitleAttribute']:
            self.assertNotIn(attribute,browser)
        self.assertIn('return nil',browser)
        self.assertNotIn('ChromeModeReader',browser)
        self.assertNotIn('ChromeEventSender',browser)
        self.assertNotIn('ChromePageRecorder',browser)
        self.assertNotIn('AXUIElementCreateApplication',browser)
    def test_one_system_wide_focus_read_without_a_process_wide_timeout(self):
        # AXUIElementSetMessagingTimeout on the system-wide element sets the
        # default timeout for every Accessibility call in the process, so the
        # app has exactly one system-wide read, it sets no timeout, and the
        # native and Chrome witnesses both use it.
        users=[str(p.relative_to(ROOT)) for p in swift_sources() if 'AXUIElementCreateSystemWide()' in p.read_text()]
        self.assertEqual(users,['Sources/MacMemApp/AccessibilitySnapshot.swift'])
        snapshot=(ROOT/'Sources/MacMemApp/AccessibilitySnapshot.swift').read_text()
        self.assertEqual(snapshot.count('AXUIElementCreateSystemWide()'),1)
        helper=snapshot.split('static func systemFocusedApplication()',1)[1].split('private static func',1)[0]
        self.assertIn('AXUIElementCreateSystemWide()',helper)
        self.assertNotIn('AXUIElementSetMessagingTimeout',helper)
        self.assertIn('focusedApplication:systemFocusedApplication',snapshot)
        witness=(ROOT/'Sources/MacMemApp/ChromeTypingWitness.swift').read_text()
        self.assertIn('systemFocusedPID: { AccessibilityReader.systemFocusedApplication() }',witness)
    def test_installer_includes_explanation_not_permission_automation(self):
        # Chrome page history (SPEC §11.10): the Automation usage string says what is
        # read (title, address, Incognito state), that nothing runs in Chrome, and
        # nothing else. macOS shows it from setup's Chrome step, right after setup
        # starts recording if still unanswered (with the switch on), and when the
        # Settings Allow… button asks.
        import plistlib
        info=plistlib.loads((ROOT/'packaging/Info.plist').read_bytes())
        usage=info['NSAppleEventsUsageDescription']
        self.assertIn('never runs scripts in Chrome',usage)
        self.assertIn('Incognito',usage)
        self.assertIn('page titles and sites',usage)
        self.assertIn('on this Mac',usage)
        for old in ['Browser capture is unavailable','type text','keystroke','every browser','all browsers','Safari']:
            self.assertNotIn(old,usage)
        # The dormant extension provider stays unconfigured: no relay keys ship,
        # so BrowserProviderResolver.bundled always refuses and only Chrome page
        # history can write a browser row.
        self.assertFalse([k for k in info if k.startswith('DaydreamBrowser')])
        self.assertEqual(info['CFBundleDisplayName'],'DayDream')
    def test_docs_match_build(self):
        # Legal conditions F, G and I: the README and the privacy page describe
        # exactly what this build does with browsers, and never overclaim.
        for name in ['README.md','PRIVACY.md']:
            text=(ROOT/name).read_text()
            for need in ['Google Chrome','Incognito','page titles and sites from Google Chrome','AI apps you connect']:
                self.assertIn(need,text,name)
            lower=text.lower()
            for banned in ['coming soon','all browsers','full address is saved']:
                self.assertNotIn(banned,lower,name)
        privacy=(ROOT/'PRIVACY.md').read_text()
        for need in ['Guest','Time Machine','Safari',"Don't record this site",'Exclude Google Chrome','not complete','Use it on your own Mac']:
            self.assertIn(need,privacy)
        self.assertEqual(privacy.split('\n## Browser history questions\n',1)[1].count('\n### '),6,'the FAQ has six entries')
        readme=(ROOT/'README.md').read_text()
        self.assertIn('Use it on your own Mac',readme)
        self.assertNotIn('Unsupported browser typing stays OFF',readme)
        # Honesty review: no absolute claim the code can't back.
        for name in ['README.md','PRIVACY.md']:
            lower=(ROOT/name).read_text().lower()
            for banned in ['every other browser',"an ai app you never connected can't",'only apps you connect yourself get access',
                           'records a browser only when','- search, email and chat pages save','while the change is saved','password managers are never recorded']:
                self.assertNotIn(banned,lower,name)
            # email-1003 (owner decision 2026-10-03): email sites keep their subjects; search and chat stay site-only.
            for need in ["doesn't know",'common search and chat sites save the site only','save email subjects','ai provider','not encrypted' if name=='PRIVACY.md' else 'unencrypted']:
                self.assertIn(need,lower,name)
        # A save pauses recording and starts it again by itself if it was on (MemoryViewModel.resumeAfterSave).
        self.assertIn('recording pauses for the save and starts again by itself if it was on',privacy.lower())
        self.assertNotIn('recording stays off until you start it again',privacy.lower())
        ui=''.join((ROOT/f).read_text() for f in ['Sources/MemoryUI/ChromePagesSettings.swift','Sources/MemoryUI/SetupView.swift','Sources/MemoryUI/OnboardingScreens.swift',
                                                  'Sources/MemoryUI/PermissionSetup.swift','Sources/MemoryUI/DaydreamKitStatus.swift','Sources/MemoryUI/DaydreamKitMoments.swift',
                                                  'Sources/MacMemApp/RecordingTrialReadiness.swift','Sources/MemoryCore/CaptureSession.swift','Sources/MacMemApp/AccessibilitySnapshot.swift'])
        for banned in ["Other browsers aren't recorded","Web browsers aren't recorded","\"Browsers aren't recorded",'"Password manager apps are never','"Password managers are never',
                       'Browser text is never saved','Recording stops while the change is saved, "\n            + "and AI apps you connected are disconnected until you reconnect them. You can undo',
                       '"Search, email and chat pages']:
            self.assertNotIn(banned,ui)
        # legal.md §11.4 in the app's setup, not only the docs. ux/declutter: setup says it once, on the review
        # page before Start Recording (the apps step and Settings' old Recording requirements page repeated it).
        screens=(ROOT/'Sources/MemoryUI/OnboardingScreens.swift').read_text()
        # ux/v1 words it as README and PRIVACY.md do (below); honesty-ui-checks pins the same sentence.
        self.assertIn('public static let ownMac = "Use DayDream only to record yourself, on your own Mac account."',screens)
        self.assertIn('notice("person", DaydreamSetupText.ownMac)',screens)
        for doc in [privacy,(ROOT/'README.md').read_text()]:
            self.assertIn("Use DayDream only to record yourself, on your own Mac user account.",doc)
            self.assertIn("isn't a monitoring tool",doc)
    def test_chrome_typing_is_private_build_only_and_unwired(self):
        for f in CHROME_TYPING_FILES:
            lines=[l for l in (ROOT/f).read_text().splitlines() if l.strip()]
            self.assertEqual(lines[0],'#if '+FLAG,f)
            self.assertEqual(lines[-1],'#endif',f)
        reader=(ROOT/'Sources/MacMemApp/ChromeModeReader.swift').read_text()
        self.assertLess(reader.index('#if '+FLAG),reader.index('enum ChromeModeReader'))
        self.assertNotIn('static func read(',reader)
        # The private reader no longer sends or permission-checks: ChromeEventSender does.
        self.assertNotIn('sendEvent(',reader)
        self.assertNotIn('AEDeterminePermissionToAutomateTarget',reader)
        # Review C7: the flag is named only where it is expected, in every tracked file.
        import subprocess
        try:
            tracked=subprocess.run(['git','ls-files'],cwd=ROOT,capture_output=True,text=True,check=True).stdout.split()
        except (OSError,subprocess.CalledProcessError):
            tracked=[str(p.relative_to(ROOT)) for p in ROOT.rglob('*') if p.is_file() and '.build' not in p.parts and '.git' not in p.parts]
        users=set()
        for f in tracked:
            path=ROOT/f
            if path.is_file() and path.stat().st_size<4_000_000:
                try:
                    if FLAG in path.read_text(errors='ignore'): users.add(f)
                except OSError: pass
        self.assertLessEqual(users,FLAG_FILES)
        self.assertGreaterEqual(users,set(CHROME_TYPING_FILES))
        main=(ROOT/'Checks/main.swift').read_text()
        self.assertLess(main.index('#if '+FLAG),main.index('runChromeTypingChecks()'))
        # Off by default: no manifest or build setting turns the flag on. The
        # packager names it only inside its DAYDREAM_OWNER_TYPING=1 block.
        for f in ['Package.swift','scripts/package.sh','scripts/build-dev-loop.py','scripts/signing_plan.py']:
            if not (ROOT/f).exists(): continue
            text=(ROOT/f).read_text()
            if f == 'scripts/package.sh':
                blocks=OWNER_BLOCK.findall(text)
                self.assertEqual(len(blocks),1,'package.sh has one owner block')
                text=OWNER_BLOCK.sub('',text)
                self.assertIn('-Xswiftc -D'+FLAG,blocks[0])
            self.assertNotIn(FLAG,text,f)
            self.assertNotIn('-D'+OWNER_FLAG,text,f)
        # The release pipeline passes the flags only through its one OWNER_SWIFT_FLAGS tuple (every stage).
        release=(ROOT/'scripts/developer-id-release.py').read_text()
        tuple_line="OWNER_SWIFT_FLAGS = ('-Xswiftc', '-D"+OWNER_FLAG+"', '-Xswiftc', '-D"+FLAG+"')"
        self.assertEqual(release.count(tuple_line),1)
        rest=release.replace(tuple_line,'')
        self.assertNotIn('-D'+FLAG,rest)
        self.assertNotIn('-D'+OWNER_FLAG,rest)
        # The device-test harness sends Apple Events to Chrome; it is its own
        # package and never part of the app build or its packaging.
        for f in ['Package.swift','scripts/package.sh','scripts/build-dev-loop.py','scripts/signing_plan.py','scripts/release.py']:
            if (ROOT/f).exists():
                for word in ['tools/','chrome-device-test','ChromeProbeCore','ChromeDeviceTest']:
                    self.assertNotIn(word,(ROOT/f).read_text(),f)
        # Not wired: capture, coordinator, snapshot, app and adapters never reach it.
        for f in ['Sources/MacMemApp/EventCapture.swift','Sources/MacMemApp/Coordinator.swift','Sources/MacMemApp/AccessibilitySnapshot.swift',
                  'Sources/MacMemApp/MacMemApp.swift','adapters/CoreCaptureBinding.swift','adapters/CoreWriterBinding.swift']:
            text=(ROOT/f).read_text()
            for word in [FLAG,'ChromeTypingWitness','BrowserTypingJoin','JoinSession','BrowserTypingBurst']:
                self.assertNotIn(word,text,f)
    def test_owner_switch_is_named_only_where_expected(self):
        import subprocess
        try:
            tracked=subprocess.run(['git','ls-files'],cwd=ROOT,capture_output=True,text=True,check=True).stdout.split()
        except (OSError,subprocess.CalledProcessError):
            tracked=[str(p.relative_to(ROOT)) for p in ROOT.rglob('*') if p.is_file() and '.build' not in p.parts and '.git' not in p.parts]
        users={f for f in tracked if (ROOT/f).is_file() and (ROOT/f).stat().st_size<4_000_000 and OWNER_FLAG in (ROOT/f).read_text(errors='ignore')}
        self.assertLessEqual(users,OWNER_FLAG_FILES)
        self.assertGreaterEqual(users,{'PrivacyPolicy/Sources/PrivacyPolicy/OwnerTyping.swift','Sources/MacMemApp/WebTypingRoute.swift','scripts/package.sh'})
        # The website route is compiled only into the owner build, and EventCapture
        # calls it only under the flag.
        route=(ROOT/'Sources/MacMemApp/WebTypingRoute.swift').read_text().strip().splitlines()
        self.assertEqual((route[0],route[-1]),('#if '+OWNER_FLAG,'#endif'))
        capture=(ROOT/'Sources/MacMemApp/EventCapture.swift').read_text()
        blocks=re.findall(r'#if '+OWNER_FLAG+r'\n(.*?)#endif',capture,re.S)
        self.assertEqual(capture.count('#if '+OWNER_FLAG),5)
        self.assertEqual(len(blocks),5)
        self.assertEqual([re.findall(r'WebTypingRoute[.\w]*\(',b) for b in blocks],
                         [['WebTypingRoute.shared.drop('],['WebTypingRoute.shared.finishPending('],
                          ['WebTypingRoute.handle('],['WebTypingRoute.shared.drop('],
                          ['WebTypingRoute.shared.chromeWindowNotification(']])
        self.assertIn('if currentBundle == ChromePageTarget.bundleID,',blocks[-1])
        code=[l for l in capture.splitlines() if 'WebTypingRoute' in l and not l.strip().startswith('//')]
        self.assertEqual(len(code),5)
        # The snapshot names the flag only around the web-content proof's reads
        # (three blocks, each about WebContentAXReader and nothing else) and the
        # web track's one browser status hook (test_owner_hooks_are_small).
        snapshot=(ROOT/'Sources/MacMemApp/AccessibilitySnapshot.swift').read_text()
        blocks=re.findall(r'#if '+OWNER_FLAG+r'\n(.*?)#endif',snapshot,re.S)
        self.assertEqual((len(blocks),snapshot.count(OWNER_FLAG)),(4,4))
        reader=[b for b in blocks if 'WebContentAXReader' in b]
        self.assertEqual(len(reader),3)
        for b in reader:
            for word in [FLAG,'WebTypingRoute','ChromeTypingWitness','BrowserTypingJoin','BrowserTypingBurst','WebTypingText','#else']:
                self.assertNotIn(word,b)
        (status,)=[b for b in blocks if 'WebContentAXReader' not in b]
        self.assertIn('WebTypingText.browserStatus',status)
        # The Typing settings name the flag once, around the "Other websites"
        # strings only; the public build gets nil and no strings.
        settings=(ROOT/'Sources/MemoryUI/TypingSettings.swift').read_text()
        blocks=re.findall(r'^[ \t]*#if '+OWNER_FLAG+r'\n(.*?)^[ \t]*#else\n(.*?)^[ \t]*#endif',settings,re.S|re.M)
        self.assertEqual((len(blocks),settings.count('#if '+OWNER_FLAG)),(1,1))
        owner,public=blocks[0]
        self.assertIn('otherWebsites',owner)
        self.assertEqual([l.strip() for l in public.splitlines() if l.strip()],['public static let otherWebsites: (title: String, help: String)? = nil'])
        for word in [FLAG,'WebTypingRoute','ChromeTypingWitness','BrowserTypingJoin','AXUIElement','NSAppleEventDescriptor']:
            self.assertNotIn(word,owner)
        # The compile guard: the owner flag always comes with Chrome typing.
        guard=(ROOT/'Sources/MemoryCore/OwnerTypingGuard.swift').read_text()
        self.assertIn('#if '+OWNER_FLAG+' && !'+FLAG,guard)
        self.assertIn('#error(',guard)
    def test_owner_hooks_are_small(self):
        # Website typing reaches shared files only through short owner blocks.
        block=re.compile(r'^[ \t]*#if '+OWNER_FLAG+r'\n(.*?)^[ \t]*#(else|endif)',re.S|re.M)
        for f,most in OWNER_HOOKS.items():
            text=(ROOT/f).read_text()
            self.assertEqual(text.count(OWNER_FLAG),text.count('#if '+OWNER_FLAG),f)
            blocks=block.findall(text)
            if f.endswith('AccessibilitySnapshot.swift'):
                # The apps track's WebContentAXReader blocks are pinned by
                # test_owner_switch_is_named_only_where_expected; this test
                # governs the website typing hook only.
                blocks=[b for b in blocks if 'WebContentAXReader' not in b[0]]
            self.assertTrue(1<=len(blocks)<=most,(f,len(blocks)))
            for body,end in blocks:
                code=[l for l in body.splitlines() if l.strip() and not l.strip().startswith('//')]
                limit=24 if f.endswith('CaptureSession.swift') and 'extension CaptureSession' in body else 4
                self.assertLessEqual(len(code),limit,(f,body))
                for word in ['ChromeTypingWitness','JoinSession','AXUIElement','NSAppleEventDescriptor','ChromeEventSender','readCharacters','acquire']:
                    self.assertNotIn(word,body,f)
        # The recording reason and the browser status keep their public text for the public build.
        session=(ROOT/'Sources/MemoryCore/CaptureSession.swift').read_text()
        self.assertIn("What's on web pages and what you type in browsers is never saved.",session.split('#else',1)[1].split('#endif',1)[0])
        snapshot=(ROOT/'Sources/MacMemApp/AccessibilitySnapshot.swift').read_text()
        (status,)=[b.split('#endif',1)[0] for b in snapshot.split('#if '+OWNER_FLAG)[1:] if 'WebTypingText.browserStatus' in b.split('#endif',1)[0]]
        self.assertIn("What's on web pages and what you type in browsers is never saved.",status.split('#else',1)[1])
        # The core owner code sits inside the Chrome typing file's own owner block.
        join=(ROOT/'Sources/MemoryCore/BrowserTypingJoin.swift').read_text()
        owner=join.split('#if '+OWNER_FLAG,1)[1]
        for name in ['public enum WebTypedRow','func permitsWebsiteRow(','public enum WebTypingText']:
            self.assertIn(name,owner)
            self.assertEqual(join.count(name),1,name)
    def test_owner_text_blocks_are_strings(self):
        # Diagnostics names the flag twice (the typed-text label, and the owner line with no #else); the
        # others once. Every block holds strings only: no website typing code, no OS call.
        block=re.compile(r'^[ \t]*#if '+OWNER_FLAG+r'\n(.*?)^[ \t]*#(?:else\n(.*?)^[ \t]*#)?endif',re.S|re.M)
        for f,public in OWNER_TEXT_FILES.items():
            text=(ROOT/f).read_text()
            blocks=block.findall(text)
            most=2 if f.endswith('Diagnostics.swift') else 1
            self.assertEqual(text.count(OWNER_FLAG),text.count('#if '+OWNER_FLAG),f)
            self.assertTrue(1<=len(blocks)==text.count('#if '+OWNER_FLAG)<=most,(f,len(blocks)))
            publics=''.join(p for _,p in blocks)
            for line in public:
                self.assertIn(line,publics,(f,line))
            for owner,_ in blocks:
                code=[l for l in owner.splitlines() if l.strip() and not l.strip().startswith('//')]
                self.assertLessEqual(len(code),4,(f,owner))
                for word in [FLAG,'WebTypingRoute','ChromeTypingWitness','BrowserTypingBurst','AXUIElement','NSAppleEventDescriptor',
                             'ChromeEventSender','SecItem','CGEvent','Process(']:
                    self.assertNotIn(word,owner,(f,word))
    def test_setup_review_line_names_the_build_scope(self):
        # typingfix review: the setup Review step's typed-text line must not name fewer places than the build
        # records. Since int/v1 (ux/v1) each Review row shows one value: the typed-text row says only On or Off,
        # so it names no places at all, and no website words live in the Review step.
        onboarding=(ROOT/'Sources/MacMemApp/DaydreamOnboarding.swift').read_text()
        self.assertIn('DaydreamReviewRow(id: "typing", title: "Typed text", value: typedText ? "On" : "Off",',onboarding)
        self.assertNotIn('"Included in ',onboarding)
        review=onboarding.split('DaydreamReviewRow(id: "typing"',1)[1].split('\n',2)
        self.assertNotIn('website',''.join(review[:2]).lower())
    def test_website_rows_reach_the_store_through_one_owner_line(self):
        # typingfix review: the store's website typing rules (ingest check and the one-time launch settle) are one
        # owner-only value; the public build has nil, so it neither checks nor deletes any website row itself.
        store=(ROOT/'Sources/MemoryCore/TypedTextStore.swift').read_text()
        owner,public=re.findall(r'^[ \t]*#if '+OWNER_FLAG+r'\n(.*?)^[ \t]*#else\n(.*?)^[ \t]*#endif',store,re.S|re.M)[0]
        self.assertEqual([l.strip() for l in owner.splitlines() if l.strip()],['static let websiteRows: (any WebsiteTypingRows)? = WebsiteTypingRowRules()'])
        self.assertEqual([l.strip() for l in public.splitlines() if l.strip() and not l.strip().startswith('//')],
                         ['static let websiteRows: (any WebsiteTypingRows)? = nil'])
        self.assertNotIn(WEB_ROW_PROVIDER,store)
        join=(ROOT/'Sources/MemoryCore/BrowserTypingJoin.swift').read_text()
        owned=join.split('#if '+OWNER_FLAG,1)[1]
        for name in ['struct WebsiteTypingRowRules: WebsiteTypingRows','func keepsEarlierWebsiteRow(']:
            self.assertIn(name,owned)
            self.assertEqual(join.count(name),1,name)
        launch=(ROOT/'Sources/MacMemApp/TypedTextExpiryTimer.swift').read_text()
        self.assertLess(launch.index('store.settleLegacyTypedText('),launch.index('store.settleWebsiteTypingRows('))
        self.assertLess(launch.index('store.settleWebsiteTypingRows('),launch.index('timer.start(schedule:'))
    def test_website_typing_reads_nothing_before_the_join(self):
        # The route reads the OS only through the Chrome typing witness (the
        # join), the secure-input flag, the mouse idle clock and native
        # typing's keyboard layout rule; it never builds an Apple Event or
        # reads Accessibility itself.
        route=(ROOT/'Sources/MacMemApp/WebTypingRoute.swift').read_text()
        for word in ['AXUIElement','NSAppleEventDescriptor','ChromeEventSender','AEDeterminePermissionToAutomateTarget','kAX','NSPasteboard',
                     'AXManualAccessibility','AXEnhancedUserInterface','requestAccess','AXIsProcessTrustedWithOptions']:
            self.assertNotIn(word,route,word)
        self.assertEqual(route.count('ChromeTypingWitness('),1)
        # QF-17 (N-B3): the design is chosen in one place, and the route and the witness both take it from there.
        code_lines=[l for l in route.splitlines() if not l.strip().startswith('//')]
        self.assertEqual(sum(l.count('ChromeJoinDesign.current') for l in code_lines),2)   # the Environment default and `live`
        live=route.split('static var live: Environment {',1)[1].split('\n        }\n',1)[0]
        self.assertIn('let design = ChromeJoinDesign.current',live)
        self.assertIn('let witness = ChromeTypingWitness(design: design)',live)
        self.assertIn('env.design = design',live)
        # QF-17 D3/D5/B2/PM1/PM2: in the bracketed design a key's characters are acquired only after the freshness
        # gate, the system-focused and frontmost checks, the key-time refs matching the last verified read, and a
        # following read being due; nothing before that reads Accessibility or the characters.
        bh=route.split('    private func bracketedHandle(',1)[1].split('\n    func lose(',1)[0]
        order=[bh.index(w) for w in ['burst.dropsUnread(typedAt: t)','environment.directKeyboardInput()','engine.verified(endingBefore: t)',
                                     't - last.start < ChromeBracketTiming.spanNanoseconds','environment.systemFocus()','environment.keyIdentity?(pid)',
                                     'identity.frontmostPID == pid, !identity.secureInput','last.window.matches(object: w), last.focus.matches(object: f)',
                                     'control.running','try acquire()','held.append(']]
        self.assertEqual(order,sorted(order))
        self.assertEqual(bh.count('acquire('),1)
        self.assertIn('case .edit(.moveBackward), .edit(.moveForward):',bh)
        handle=route.split('    func handle(eventAt:',1)[1].split('    private func join(',1)[0]
        self.assertLess(handle.index('guard bundle == WebTypingGate.bundle'),handle.index('active(coordinator)'))
        self.assertLess(handle.index('active(coordinator)'),handle.index('burst.key('))
        # typingfix (owner/v1 review F3): native typing's direct-keyboard rule runs before any join
        # read, and a failure is an unproven key (nothing read, the unfinished text dropped).
        join_fn=route.split('    private func join(',1)[1].split('    private func write(',1)[0]
        # fix/chrome-capture: the opt-in diagnostics count the refusal (a counter name only).
        self.assertIn('guard environment.directKeyboardInput() else { diagnostics.count("web.inputMethod"); WebTypingStatus.set(.denied); return .denied(.inputMethod) }',join_fn)
        self.assertLess(join_fn.index('environment.directKeyboardInput()'),join_fn.index('environment.join('))
        self.assertIn('var directKeyboardInput: () -> Bool = { AccessibilityReader.keyboardInputIsDirect() }',route)
        snapshot=(ROOT/'Sources/MacMemApp/AccessibilitySnapshot.swift').read_text()
        self.assertIn('static func keyboardInputIsDirect()->Bool {directKeyboardInput()}',snapshot)
        # A change of input source seals the website text too: capture's one observer call reaches
        # TypingInputSource, and the route listens (a static target, the route in use).
        capture=(ROOT/'Sources/MacMemApp/EventCapture.swift').read_text()
        observer=capture.split('kTISNotifySelectedKeyboardInputSourceChanged',1)[1].split('\n        }',1)[0]
        self.assertIn('self?.inputSourceChanged()',observer)
        changed=capture.split('    func inputSourceChanged() {',1)[1].split('\n    }',1)[0]
        self.assertLess(changed.index('TypingInputSource.changed()'),changed.index('sealTyping(.inputSource,focusMoved:true)'))
        self.assertIn('TypingInputSource.listen { WebTypingRoute.shared.inputSourceChanged() }',route)
        sealed=route.split('    func inputSourceChanged() {',1)[1].split('\n    }',1)[0]
        self.assertIn('burst.boundary(.inputSource,',sealed)
        # The key's characters are handed to the burst unread; the route never calls them itself.
        self.assertEqual(handle.count('read: acquire'),1)
        self.assertNotIn('acquire(',handle)
        # The burst reads a key's characters only after the join, the burst
        # rules, the website gate and the secret latch allowed it.
        join=(ROOT/'Sources/MemoryCore/BrowserTypingJoin.swift').read_text()
        burst=join.split('public final class BrowserTypingBurst',1)[1]
        insert=burst.split('private func insert(',1)[1].split('private func admitted(',1)[0]
        self.assertLess(insert.index('admitted('),insert.index('characters()'))
        admitted=burst.split('private func admitted(',1)[1].split('private func after(',1)[0]
        order=[admitted.index(w) for w in ['result.denial','admitKey(','session.typingGate(','session.admit(']]
        self.assertEqual(order,sorted(order))
        key=burst.split('public func key(',1)[1].split('private func insert(',1)[0]
        self.assertEqual(key.count('read()'),1)
        self.assertLess(key.index('insert(keyJoin()'),key.index('read()'))
        # Review G51: a key of an open burst may take the light per-key check; a burst starts, and
        # Return, paste, splits and every save take, the full join. A light proof never saves.
        self.assertIn('func keyJoin() -> BrowserTypingJoinResult { (start != nil ? light() : nil) ?? join() }',key)
        for commit in ['commit(join(), typedAt: typedAt, processedAt: now(), reason: reason,','let outcome = try commit(join(), typedAt: typedAt,']:
            self.assertIn(commit,key)
        save=burst.split('public func save(',1)[1].split('// MARK: Text on the typing session',1)[0]
        self.assertIn('guard !f.light else { return nil }',save)
        self.assertIn('guard !proof.light else { return false }',burst.split('public func admitKey(',1)[1].split('public func save(',1)[0])
        after=burst.split('private func after(',1)[1].split('public func commit(',1)[0]
        self.assertIn('let saving = light ? full() : result',after)
        self.assertIn('!j.light &&',burst.split('private func samePage(',1)[1])
        self.assertIn('guard let p = result.proof, !p.light,',burst.split('public func pointerDown(',1)[1])
        # Review G12, round 1: the settle takes the full join first (as every save does) and the click
        # join only right after a full join denied `.field`; a click join that fails can't make the
        # full join forget the page. The join keeps the page a `.field` denial forgot for the next
        # join only when that is a click join.
        settle=route.split('    private func settle(',1)[1]
        self.assertIn('let result: BrowserTypingJoinResult? = secure ? nil : join(a)',settle)
        self.assertIn("let page: BrowserTypingJoinResult? = !secure && result?.denial == .field && burst.last != nil ? pageJoin(a) : nil",settle)
        self.assertLess(settle.index('join(a)'),settle.index('pageJoin(a)'))
        join_api=join.split('    public func join(environment e:',1)[1].split('    private func attempt(',1)[0]
        self.assertIn('if anyFocus, previous == nil { previous = departed }',join_api)
        self.assertIn('if !anyFocus, denial == .field { departedPage = before }',join_api)
        self.assertLess(join_api.index('departedPage = nil'),join_api.index('attempt('))
        self.assertLess(join_api.index('invalidate()'),join_api.index('departedPage = before'))
        self.assertIn('public func invalidate() { previous = nil; anchor = nil; departedPage = nil; heldBox = nil }',join)
        # Codex 07:10 (field hold): the hold's check reads only which app, window and element have focus (no label,
        # role, address, page or Apple Event), and a held key is dropped before any join, light check or read.
        holds=join.split('public func holdsRefusedBox(',1)[1].split('\n    }\n',1)[0]
        for word in ['fieldLabels','ax.role(','ax.url(','ax.title(','ax.children(','ae(','ax.subrole(']:
            self.assertNotIn(word,holds,word)
        held_key=join.split('public func key(',1)[1].split('private func insert(',1)[0]
        held_key=held_key.split('if fieldHeld {',1)[1].split('switch intent {',1)[0]
        # Review FH-1: a key in a held burst is dropped unread whether or not the box still has focus; the quiet
        # period starts again either way. Review 10:35 Q-1: both are denial quiet (noteDenied, never recoverable by
        # QF-1); the hold goes on only while the box has focus.
        self.assertIn('if holdBurst, let same = held() {',held_key)
        self.assertIn('noteDenied(at: at)\n                    fieldHeld = same\n',held_key)
        self.assertNotIn('noteDisruptive(','\n'.join(l.split('//')[0] for l in held_key.splitlines()))
        # Review FH-2: a key in another app ends the holds, even with nothing unfinished.
        other_app=route.split('guard bundle == WebTypingGate.bundle, let pid else {',1)[1].split('return false',1)[0]
        self.assertIn('burst.endHolds()',other_app)
        self.assertIn('burst.endHolds()',route.split('    func inputSourceChanged() {',1)[1].split('\n    }',1)[0])
        self.assertLess(held_key.index('dropReason = .held; session.retract()'),held_key.index('return .dropped'))
        self.assertNotIn('join()',held_key)
        self.assertNotIn('read()',held_key)
        self.assertEqual(join.count('departedPage = before'),1)
        # Chrome page rows never carry typed words: a website typing row has its own provider.
        self.assertIn('public static let provider = "chrome-typing-join-v1"',join)
    def test_chrome_typing_reads_mode_first_and_never_field_content(self):
        join=(ROOT/'Sources/MemoryCore/BrowserTypingJoin.swift').read_text()
        read=join.split('private func read(',1)[1].split('private func unchanged(',1)[0]
        # fix/chrome-root: every window's mode in one event (`ae(.modes)`), and bounds in one (`ae(.allBounds)`).
        self.assertNotIn('ae(.mode(',read); self.assertNotIn('ae(.bounds(',read)
        first_mode=read.index('ae(.modes)')
        self.assertLess(read.index('ae(.windowIDs)'),first_mode)
        for later in ['ae(.allBounds)','ae(.name(','ae(.activeTabID(','ae(.tabURL(','ax.focusedWindow(','ax.focusedElement(','ax.title(','ax.url(','ax.frame(',
                      'ax.windows(','ax.fieldLabels(']:
            self.assertLess(first_mode,read.index(later),later)
        # Review I1: every Accessibility window is accounted for (geometry only)
        # before any title, name, tab, URL or page is read.
        accounted=read.index('ChromeWindowMatching.coversAll(')
        self.assertLess(read.index('ax.windows('),accounted)
        for later in ['ae(.name(','ax.title(','ae(.activeTabID(','ae(.tabURL(','ax.focusedElement(','ax.url(','ax.fieldLabels(']:
            self.assertLess(accounted,read.index(later),later)
        # Review I3: labels are read last, deny-only.
        self.assertLess(read.index('ax.url('),read.index('ax.fieldLabels('))
        self.assertIn('guard !BrowserTypingFieldRules.denies(labels) else { return .failure(.sensitiveField) }',read)
        # typingfix (owner/v1 review F1): a message composer outside the categories follows Messages
        # and email, judged from the same labels, after the sensitive-field rule.
        self.assertIn('guard field(url, labels) else { return .failure(.blockedSite) }',read)
        self.assertLess(read.index('BrowserTypingFieldRules.denies(labels)'),read.index('guard field(url, labels)'))
        # Review C5: the signature and Automation checks run once per join, not per read.
        self.assertNotIn('e.target()',read)
        self.assertNotIn('e.automationPermitted(',read)
        body=join.split('public func join(',1)[1].split('private func focused(',1)[0]
        self.assertLess(body.index('e.target()'),body.index('read(e'))
        self.assertLess(body.index('e.automationPermitted('),body.index('read(e'))
        # Strict mode: the first mode loop returns before anything else is read.
        self.assertIn('guard case .texts(let modes)? = ae(.modes), modes.count == ids.count, modes.allSatisfy({ $0 == "normal" })\n        else { return .failure(.notNormal) }',read[:read.index('ax.focusedWindow(')])
        # M6: the bounds pair with the IDs by index only because the list is read again, identical, right after them.
        self.assertLess(read.index('ae(.allBounds)'),read.index('guard ae(.windowIDs) == .ids(ids) else { return .failure(.changed) }'))
        self.assertLess(read.index('guard ae(.windowIDs) == .ids(ids) else { return .failure(.changed) }'),read.index('ChromeWindowMatching.coversAll('))
        # Mode and the window list are read again after page content.
        self.assertGreater(read.rindex('ae(.modes)'),read.index('ax.url('))
        self.assertGreater(read.rindex('ae(.windowIDs)'),read.index('ax.url('))
        for f in ['Sources/MemoryCore/BrowserTypingJoin.swift','Sources/MacMemApp/ChromeTypingWitness.swift']:
            text=(ROOT/f).read_text()
            for word in ['kAXValueAttribute','kAXSelectedText','AXSelectedText','CGWindowList','NSPasteboard','AXEnhancedUserInterface',
                         'AXManualAccessibility','AXUIElementSetAttributeValue','NSWorkspace.shared.open','executeJavaScript']:
                self.assertNotIn(word,text,f)
        witness=(ROOT/'Sources/MacMemApp/ChromeTypingWitness.swift').read_text()
        # Review I5: one Accessibility read function, an enum of allowed attributes, nothing else.
        self.assertEqual(witness.count('AXUIElementCopyAttributeValue('),1)
        self.assertNotIn('AXUIElementCopyMultipleAttributeValues',witness)
        self.assertEqual(witness.count('AXUIElementCopyParameterizedAttributeValue('),1)
        search=witness.split('private static func formSearch(',1)[1].split('// MARK: - AX plumbing',1)[0]
        self.assertIn('limit == BrowserFormScan.searchLimit',search)
        self.assertIn('BrowserFormScan.searchWords.contains(word)',search)
        core=(ROOT/'Sources/MemoryCore/BrowserTypingJoin.swift').read_text()
        scan=core.split('public enum BrowserFormScan {',1)[1]
        secret=re.findall(r'"([^"\n]+)"',scan.split('static let secretWords =',1)[1].split(']',1)[0])
        words=re.findall(r'"([^"\n]+)"',scan.split('public static let searchWords =',1)[1].split(']',1)[0])
        self.assertTrue(all(any(fragment in word for fragment in words) for word in secret))
        # fix/chrome-large-pages (owner-approved 2026-10-02): the page search answers an exhausted walk in production.
        self.assertIn('public var formSearchRecoveryEnabled = true',core)
        self.assertIn('init(design: ChromeJoinDesign, formSearchRecoveryEnabled: Bool = true)',witness)
        self.assertIn('guard walked == .exhausted, ax.formSearchRecoveryEnabled else { return walked }',scan)
        self.assertIn('let pid = ax.owner(page)',scan)
        self.assertIn('ax.owner(node) == pid',scan)
        self.assertIn('public var formControlNames: ((Node, () -> Bool) -> [String]?)? = nil',core)
        self.assertIn('access.formControlNames = { node, late in Self.formControlNames(node, late: late) }',witness)
        names=witness.split('private static func formControlNames(',1)[1].split('/// A container',1)[0]
        self.assertIn('guard !late(), let title = optionalString(node, .title)',names)
        self.assertIn('guard !late(), let description = optionalString(node, .description)',names)
        self.assertIn('return late() ? nil : [title, description]',names)
        controls=scan.split('let searchControls:',1)[1].split('private static func walk',1)[0]
        self.assertLess(controls.index('let subrole = ax.subrole(node)'),controls.index('guard searchControls.contains(role)'))
        self.assertIn('if subrole.lowercased().contains("secure") { return .password }',controls)
        self.assertIn('let names = ax.controlNamesForForm(node, late: late)\n                if late() { return .late }',controls)
        for forbidden in ['AXVisibleOnly','AXSearchCurrentElement','AXImmediateDescendantsOnly','AXDirectionPrevious','AXAnyTypeSearchKey']:
            self.assertNotIn(forbidden,witness)
        self.assertIsNone(re.search(r'kAX\w+Attribute',witness))
        self.assertIn('private static func copy(_ node: AXUIElement, _ name: Attribute) -> Copied {',witness)
        enum=witness.split('enum Attribute: String, CaseIterable {',1)[1].split('}',1)[0]
        self.assertEqual(set(re.findall(r'"(AX[A-Za-z]+)"',enum)),WITNESS_AX)
        self.assertEqual(set(re.findall(r'"(AX[A-Za-z]+)"',witness)),WITNESS_AX | WITNESS_SEARCH)
        self.assertNotIn('"AXValue"',witness)
        # fix/chrome-capture: one hit test, on Chrome's lazily made application element, only for the Post check.
        self.assertEqual(witness.count('AXUIElementCopyElementAtPosition('),1)
        self.assertIn('AXUIElementCopyElementAtPosition(',lazy_part:=witness.split('private final class LazyApplication {',1)[1].split('static func access(',1)[0])
        for rel in ['Sources/MacMemApp/WebTypingRoute.swift','Sources/MemoryCore/BrowserTypingJoin.swift','Sources/MemoryCore/BrowserSubmitGesture.swift',
                    'Sources/MacMemApp/EventCapture.swift']:
            self.assertNotIn('AXUIElementCopyElementAtPosition',(ROOT/rel).read_text(),rel)
        gesture=(ROOT/'Sources/MemoryCore/BrowserSubmitGesture.swift').read_text()
        check=gesture.split('public func submitControl(',1)[1].split('public final class BrowserSubmitTracker',1)[0]
        # The Post check reads no field value, label, address or title; the hit test comes after the field and focus
        # checks, and consent and focus are asked again at the end.
        for word in ['fieldLabels','ax.url(','ax.title(','kAX','AXValue']:
            self.assertNotIn(word,check,word)
        order=[check.index(w) for w in ['fieldTrail','e.enabled()','focused()','ax.elementAt(','ax.enabled(','ax.controlNames(','ax.frame(']]
        self.assertEqual(order,sorted(order))
        self.assertGreater(check.rindex('e.enabled()'),check.index('BrowserSubmitControls.boundary('))
        self.assertGreater(check.rindex('focused()'),check.index('BrowserSubmitControls.boundary('))
        route=(ROOT/'Sources/MacMemApp/WebTypingRoute.swift').read_text()
        self.assertEqual(route.count('environment.submitControl('),1)
        arm=route.split('    private func armSubmit(',1)[1].split('    func pointerUp(',1)[0]
        self.assertLess(arm.index('press.plain'),arm.index('pageJoin(a, anchor: downAt)'))
        self.assertLess(arm.index('environment.secureInput()'),arm.index('pageJoin(a, anchor: downAt)'))
        self.assertLess(arm.index('pageJoin(a, anchor: downAt)'),arm.index('environment.submitControl('))
        # A click alone is never a send: the seal says unknown, and only the store's amendment marks a row.
        # claude/livefix-1004: that one amendment also marks a post's earlier pieces after Command-Return (`chord`).
        self.assertEqual(gesture.count('sendBy = '),1)
        self.assertEqual(gesture.count('sendBy = chord ? "commandReturn" : "button"'),1)
        self.assertIn('#if '+OWNER_FLAG,gesture.split('extension MemoryStore',1)[0][-40:])
        # Review C9: no Accessibility object for Chrome exists before the join asks for one.
        self.assertEqual(witness.count('AXUIElementCreateApplication('),2)
        lazy=witness.split('private final class LazyApplication {',1)[1].split('static func access(',1)[0]
        self.assertIn('AXUIElementCreateApplication(',lazy)
        # QF-17 D5: the other is the key-time identity reader's own element: on main, a 25 ms timeout, only the
        # focused-window and focused-element refs, never the system-wide element, paused after a slow or failed read.
        ident=witness.split('final class KeyIdentityReader {',1)[1].split('// MARK: - AX plumbing',1)[0]
        self.assertIn('AXUIElementCreateApplication(pid)',ident)
        self.assertIn('dispatchPrecondition(condition: .onQueue(.main))',ident)
        self.assertIn('guard ChromeTypingWitness.timed(element) else { return nil }',ident)
        self.assertEqual(set(re.findall(r'element\(root, \.(\w+)\)',ident)),{'focusedWindow','focusedElement'})
        self.assertNotIn('SystemWide',ident)
        self.assertNotIn('copy(',ident)
        self.assertIn('fileprivate static func timed(_ node: AXUIElement) -> Bool { AXUIElementSetMessagingTimeout(node, 0.025) == .success }',witness)
        self.assertNotIn('AXUIElementCreateSystemWide',witness)
        # Review I6: strict mode needs exactly one Chrome process.
        # Live test (build 7): the person's processes only; a headless or automation Chrome is not counted.
        self.assertIn('let instances = ChromeEventSender.userProcessCount(',witness)
        sender=(ROOT/SENDER).read_text()
        self.assertIn('ChromeProcesses.user(processes(frontmost:frontmost)).count',sender)
        self.assertIn('NSRunningApplication.runningApplications(withBundleIdentifier:ChromePageTarget.bundleID)',sender)
        self.assertIn('&& f.instances == 1',join)
        # The proof is origin-only: no title, URL, name or label field.
        proof=join.split('public struct BrowserTypingJoinProof',1)[1].split('public func sameBurst',1)[0]
        fields=set(re.findall(r'public let (\w+):',proof))
        self.assertEqual(fields,{'origin','windowID','tabID','windowList','documentID','focusID','targetIdentity','role','subrole','checkedAt'})
        # summaries/v3 (intent lines spec §4, a deliberate change): two derived fields, the field class and a chat
        # composer's channel or person, and only through SendRules (never a raw label, title or URL).
        # fix/typing-e2e (L5): a third, the page's title, only through WebTypingTitle.clean (the page history rules).
        # C1: metadata observation times and the lean-read discriminator contain no raw field data.
        # QF-17: the bracketed design's read record (per-fact digests, observation times and AX refs; no title, URL,
        # name or label value) rides on the proof.
        # fix/chrome-x (compose signals): the route's compose kind (never the address) and the reply phrases of the labels.
        self.assertEqual(re.findall(r'public var (\w+)',proof),['sendField','sendPlace','pageTitle','composeRoute','replyLabels','titleObservedAt','axURLObservedAt','leanRead','light','bracket'])
        self.assertIn('composeRoute: BrowserComposeRoute.path(url: url)',read)
        self.assertIn('replyLabels = BrowserComposeRoute.replyMarkers(labels.texts)',read)
        self.assertIn('public var bracket: ChromeReadRecord? = nil',proof)
        self.assertIn('pageTitle = WebTypingTitle.clean(',join)
        self.assertIn('sendField = SendRules.fieldClass(role: role, labels: labels.texts',join)
        self.assertIn('sendPlace = SendRules.composerPlace(labels: labels.texts, host: BrowserTypingSites.host(of: url)) ?? ""',join)
        # Review G51: the light per-key check reads the window list and every mode before anything
        # else about a window or its page, re-reads the field's labels (deny-only, then the composer
        # rule) and the window list after them, and never denies (nil: the full join decides).
        light=join.split('public func light(',1)[1].split('private func focused(',1)[0]
        order=[light.index(w) for w in ['e.enabled()','e.launchIdentity(','focused(ax, a.pid)','ae(.windowIDs)','ae(.modes)','ax.windows()',
                                        'ax.focusedWindow()','ax.focusedElement()','ax.subrole(focus)','ax.url(a.webArea)','ax.fieldLabels(focus)']]
        self.assertEqual(order,sorted(order))
        # fix/chrome-root: every window's mode in one event, as many answers as the window list.
        self.assertIn('guard case .texts(let modes)? = ae(.modes), modes.count == a.ids.count, modes.allSatisfy({ $0 == "normal" }) else { return nil }',light)
        self.assertIn('guard let labels = ax.fieldLabels(focus), !BrowserTypingFieldRules.denies(labels), field(a.url, labels) else { return nil }',light)
        self.assertGreater(light.rindex('ae(.windowIDs)'),light.index('ax.fieldLabels(focus)'))
        self.assertGreater(light.rindex('focused(ax, a.pid)'),light.index('ax.fieldLabels(focus)'))
        self.assertNotIn('.denied(',light)
        self.assertIn('BrowserTypingTiming.proofTTLNanoseconds',light)
        self.assertIn('BrowserTypingTiming.lightBudgetNanoseconds',light)
        # Review G12: the click join never takes a focus whose subrole can't be read as "not secure".
        read_fn=join.split('private func read(',1)[1].split('private func unchanged(',1)[0]
        self.assertIn('let subrole = ax.subrole(focus),',read_fn)
        self.assertNotIn('?? (anyFocus',read_fn)

    def test_bracketed_read_orders_mode_gate_and_blocks_first(self):
        # QF-17 PM7: the bracketed design's one read (BrowserTypingJoinBracketed.swift) keeps the synchronous read's
        # order: window IDs, then every window's mode, exactly "normal", before any window's geometry, name, tab, URL
        # or page is read through AX or Apple Events; the IDs read again and every AX window accounted for before
        # any name; the site blocks before anything about the field; the labels deny-only, in every read.
        text=(ROOT/'Sources/MemoryCore/BrowserTypingJoinBracketed.swift').read_text()
        read=text.split('func bracketedAttempt(',1)[1]
        gate='guard case .texts(let modes)? = ask(.modes, .modes), lean || modes.count == ids.count, !modes.isEmpty,'
        self.assertEqual(read.count(gate),1)
        self.assertIn('modes.count <= BrowserTypingTiming.maxWindows, modes.allSatisfy({ $0 == "normal" })',read)
        # The feasibility prototype's lean shape (2 Apple Events) is never the default.
        bracket=(ROOT/'Sources/MemoryCore/ChromeBracket.swift').read_text()
        self.assertIn('private static var value: ChromeReadShape = .full',bracket)
        self.assertIn('private static var value: ChromeJoinDesign = .synchronous',bracket)
        mode=read.index(gate)
        self.assertLess(read.index('ask(.windowIDs, .windowIDs)'),mode)
        for later in ['ax.focusedWindow(','ax.windows(','ax.frame(','ax.title(','ax.focusedElement(','ax.url(','ax.fieldLabels(',
                      'ask(.bounds, .allBounds)','ae(.name(','.activeTabID(','.tabURL(']:
            self.assertLess(mode,read.index(later),later)
        # Nothing about a window is read through Apple Events before the gate either (IDs only).
        self.assertEqual(re.findall(r'ask\(\.(\w+),',read[:mode]),['windowIDs'])
        again=read.index('guard lean || ask(.windowIDs, .windowIDs) == .ids(ids) else { return .denied(.changed) }')
        covers=read.index('guard ChromeWindowMatching.coversAll(g.axFrames, bounds) else { return .denied(.unlistedWindow) }')
        self.assertLess(read.index('ask(.bounds, .allBounds)'),again)
        self.assertLess(again,covers)
        for later in ['ae(.name(','ax.title(','.activeTabID(','.tabURL(','ax.focusedElement(','ax.url(','ax.fieldLabels(']:
            self.assertLess(covers,read.index(later),later)
        blocks=read.index('BrowserTypingSites.evaluate(url, blockList: blockList, alwaysBlocked: alwaysBlocked)')
        self.assertLess(read.index('ax.url('),blocks)
        self.assertLess(blocks,read.index('ax.fieldLabels('))
        self.assertLess(read.index('sites(url), sites(axURL) else { return .denied(.blockedSite) }'),read.index('ax.fieldLabels('))
        # M7: the field's sensitivity in every read (deny-only), skipped only for the click join, which never admits.
        sens=read.split('clock.observe(.sensitivity) {',1)[1].split('\n            }',1)[0]
        self.assertIn('guard !BrowserTypingFieldRules.denies(labels) else { return .failure(.sensitiveField) }',sens)
        self.assertIn('guard field(url, labels) else { return .failure(.blockedSite) }',sens)
        self.assertLess(sens.index('BrowserTypingFieldRules.denies(labels)'),sens.index('guard field(url, labels)'))
        self.assertIn('guard !anyFocus else { return .allowed(proof) }',read)
        # Strict: the focus and every ancestor never secure; the per-read budget is the span.
        self.assertIn('!role.lowercased().contains("secure")',read)
        self.assertIn('ChromeBracketTiming.readBudgetNanoseconds',read)
        # Nothing in the bracketed read reads field content or the clipboard.
        for word in ['kAXValueAttribute','AXSelectedText','NSPasteboard','AXUIElementSetAttributeValue','CGWindowList']:
            self.assertNotIn(word,text)
        # The engine and the held buffer are pure bookkeeping: no OS call, no log, no print.
        engine=(ROOT/'Sources/MemoryCore/ChromeBracket.swift').read_text()
        for word in ['print(','NSLog','os_log','Logger(','DiagnosticsLog','RecordingLog','AXUIElement','NSAppleEventDescriptor']:
            self.assertNotIn(word,engine,word)
        self.assertIn('memset_s(',engine)

    def test_chrome_pages_read_mode_first_and_only_on_page_triggers(self):
        pages=(ROOT/'Sources/MemoryCore/ChromePages.swift').read_text()
        read=pages.split('public static func read(userBlocked:',1)[1].split('private static func modes(',1)[0]
        order=[read.index(w) for w in ['ask(.windowIDs)','modes(ids, ask)','ask(.activeTabID(front))','ask(.tabURL(front, tab))',
                                       'BrowserSites.pageDecision(url, userBlocked: userBlocked)','ask(.tabTitle(front, tab))']]
        self.assertEqual(order,sorted(order))
        # The title is asked only for pages that keep one; the re-check follows it.
        self.assertEqual(read.count('ask(.tabTitle('),1)
        # email-1003 (owner decision 2026-10-03): an email page asks for its title too, only while Save email subjects is on.
        self.assertLess(read.index('if !siteOnly || emailTitle {'),read.index('ask(.tabTitle('))
        self.assertIn('let emailTitle = siteOnly && emailSubjects && BrowserSites.emailPage(url)',read)
        self.assertGreater(read.rindex('modes(ids, ask)'),read.index('ask(.tabTitle('))
        self.assertGreater(read.rindex('ask(.tabURL(front, tab))'),read.index('ask(.tabTitle('))
        # Only the origin, the cleaned title and (fix/show-all, on this Mac only) the page link leave the read: never
        # the raw address, and the link only through BrowserSites.pageLink, none for site-only pages. page-links-1003
        # (owner decision 2026-10-03: a page row opens the exact page): pageLink keeps a YouTube video's v, t and list and a
        # Sheets tab or Wikipedia section; never another query part, a token, a signed address or an auth page.
        fields=set(re.findall(r'public let (\w+):',pages.split('public struct ChromePageRead',1)[1].split('public init',1)[0]))
        self.assertEqual(fields,{'windowID','tabID','origin','title','siteOnly','link'})
        self.assertIn('link: siteOnly ? nil : BrowserSites.pageLink(url)',read)
        recorder=(ROOT/'Sources/MacMemApp/ChromePageRecorder.swift').read_text()
        work=recorder.split('environment.background {',1)[1].split('environment.main {',1)[0]
        self.assertLess(work.index('environment.verify('),work.index('environment.permission('))
        self.assertLess(work.index('environment.permission('),work.index('ChromePageProbe.read('))
        self.assertLess(work.index('status == noErr'),work.index('environment.transport('))
        for f in ['Sources/MemoryCore/ChromePages.swift','Sources/MacMemApp/ChromePageRecorder.swift',SENDER]:
            text=(ROOT/f).read_text()
            for word in ['print(','NSLog(','os_log','Logger(','AXUIElement','kAXValueAttribute','NSPasteboard','executeJavaScript']:
                self.assertNotIn(word,text,f)
        self.assertEqual(re.findall(r'AccessibilityReader\.status=([^\n;]+)',recorder),['Self.status'])
        # Triggers: app switch and window/title changes only (plus the poll and
        # confirms inside the recorder). Keys and clicks never reach it.
        capture=(ROOT/'Sources/MacMemApp/EventCapture.swift').read_text()
        self.assertEqual(capture.count('pages.trigger('),1)
        self.assertEqual(capture.count('pages.windowChanged()'),1)
        switch=capture.split('func switchFrontmost(pid: pid_t',1)[1].split('private func installAXObserver',1)[0]
        self.assertIn('pages.trigger(.appSwitch)',switch)
        # Review m1: the window/title trigger runs in handleAX before the AX
        # debounce and its input epoch, so a key or click can never cancel it.
        ax=capture.split('func handleAX(_ notification: String)',1)[1].split('private func processAX(',1)[0]
        self.assertIn('pages.windowChanged()',ax)
        self.assertLess(ax.index('pages.windowChanged()'),ax.index('axDebounce[notification]?.cancel()'))
        self.assertLess(ax.index('pages.windowChanged()'),ax.index('let epoch=inputEpoch'))
        self.assertIn('kAXFocusedWindowChangedNotification || notification == kAXTitleChangedNotification',ax)
        # The recorder paces window reads itself; key/click paths never reach its epochs.
        self.assertIn('static let windowGap:TimeInterval=1.5',recorder)
        self.assertIn('environment.idleSeconds() >= Self.idleLimit',recorder.split('func tick()',1)[1].split('func windowChanged()',1)[0])
        self.assertNotIn('pages.invalidate()',capture.split('private func resetObservation(',1)[1].split('// MARK: - Accessibility notifications',1)[0])
        for name,end in [('fileprivate func handleTap(','private func handleKeyDown('),('private func handleKeyDown(','static func eventNanoseconds('),
                         ('func handleNativeKey(eventAt:UInt64,stroke:','private func insertTyping('),('private func handleMouseUp(','// MARK: - Typed units')]:
            body=capture.split(name,1)[1].split(end,1)[0]
            self.assertNotIn('pages.',body,name)
        observer=capture.split('private func installAXObserver(',1)[1].split('private func installEventTap',1)[0]
        chrome=observer.split('chrome ? [',1)[1].split(']',1)[0]
        self.assertEqual(set(re.findall(r'kAX\w+Notification',chrome)),{'kAXFocusedWindowChangedNotification','kAXTitleChangedNotification'})
        # The heartbeat (fix/lock-resume: built with Timer(timeInterval:) and added in the common run-loop modes).
        heartbeat=capture.split('let timer = Timer(timeInterval: 0.5, repeats: true)',1)[1].split('return true',1)[0]
        self.assertIn('self?.pages.tick()',heartbeat)
        self.assertIn('RunLoop.main.add(timer, forMode: .common)',heartbeat)

    def test_chrome_typing_lists_stay_in_sync(self):
        # Review I3: MemoryCore cannot import PrivacyPolicy, so the field rules
        # carry a copy of TextClassifier.sensitiveLabel's words; it must stay a superset.
        classifier=(ROOT/'PrivacyPolicy/Sources/PrivacyPolicy/TextClassifier.swift').read_text()
        words=set(re.findall(r'"([^"]+)"',classifier.split('public static func sensitiveLabel',1)[1].split('.contains(where',1)[0]))
        join=(ROOT/'Sources/MemoryCore/BrowserTypingJoin.swift').read_text()
        copy=set(re.findall(r'"([^"]+)"',join.split('static let classifierWords = [',1)[1].split(']',1)[0]))
        self.assertTrue(words and words<=copy,words-copy)
        # The app's id tokens cover the device harness's (tools/chrome-device-test Rules.swift).
        rules=(ROOT/'tools/chrome-device-test/Sources/ChromeProbeCore/Rules.swift').read_text()
        harness=set(re.findall(r'"([^"]+)"',rules.split('public static let idTokens: Set<String> = [',1)[1].split(']',1)[0]))
        app=set(re.findall(r'"([^"]+)"',join.split('public static let idTokens: Set<String> = [',1)[1].split(']',1)[0]))
        self.assertTrue(harness and harness<=app,harness-app)
        # Review C6: the two app-wide sensitive-domain lists are the same list.
        gate=(ROOT/'PrivacyPolicy/Sources/PrivacyPolicy/CaptureGate.swift').read_text()
        models=(ROOT/'Sources/MemoryCore/Models.swift').read_text()
        a=set(re.findall(r'"([^"]+)"',gate.split('public static let sensitiveDomains:Set<String>=[',1)[1].split(']',1)[0]))
        b=set(re.findall(r'"([^"]+)"',models.split('public static let sensitiveDomains = [',1)[1].split(']',1)[0]))
        self.assertTrue(a and a==b,a^b)

    # Review round 3, R3-2: the QF-17 bracketed design, the lean read shape and the per-fact rule stay switched off.
    # No app or library source (everything under Sources/) may switch them on: no assignment to the three `current`
    # switches, and no `.bracketed`, `.lean` or `.perFact` anywhere except a comparison (==, !=) or a `case` label.
    # Checks and harnesses (Checks/, scripts/) set them; the shipped code never does. The defaults are pinned too.
    QF17_SWITCHES = ('ChromeJoinDesign', 'ChromeReadShape', 'ChromeBracketRule')
    QF17_ON_VALUES = ('bracketed', 'lean', 'perFact')
    @staticmethod
    def _swift_code(text):
        text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
        text = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', text)
        return re.sub(r'//[^\n]*', '', text)
    @classmethod
    def qf17_switch_violations(cls, files):
        bad = []
        for name, text in files:
            code = cls._swift_code(text)
            for m in re.finditer(r'\b(%s)\s*\.\s*current\s*=(?!=)' % '|'.join(cls.QF17_SWITCHES), code):
                bad.append('%s: assigns %s.current' % (name, m.group(1)))
            # An implicit member (`.bracketed`, not a property such as `burst.bracketed`) or the type's own member.
            on = r'(?:(?<![\w)\]])|\b(?:%s)\s*)\.(%s)\b' % ('|'.join(cls.QF17_SWITCHES), '|'.join(cls.QF17_ON_VALUES))
            for m in re.finditer(on, code):
                line = code[code.rfind('\n', 0, m.start()) + 1:m.start()]
                if re.search(r'(==|!=)\s*$', line) or re.search(r'\bcase\s*$', line) or re.search(r'\bcase\s+[^:]*,\s*$', line):
                    continue
                bad.append('%s: uses .%s outside a comparison: %s' % (name, m.group(1), line.strip() + '.' + m.group(1)))
            for m in re.finditer(r'\b(%s)\s*\(\s*rawValue' % '|'.join(cls.QF17_SWITCHES), code):
                bad.append('%s: builds %s from a raw value' % (name, m.group(1)))
        return bad
    def test_qf17_designs_stay_switched_off(self):
        files = [(str(f.relative_to(ROOT)), f.read_text()) for f in sorted((ROOT / 'Sources').rglob('*.swift'))]
        self.assertGreater(len(files), 50)
        self.assertEqual(self.qf17_switch_violations(files), [])
        bracket = (ROOT / 'Sources/MemoryCore/ChromeBracket.swift').read_text()
        for pin in ('private static var value: ChromeJoinDesign = .synchronous', 'private static var value: ChromeReadShape = .full',
                    'private static var value: ChromeBracketRule = .wholeRead'):
            self.assertEqual(bracket.count(pin), 1, pin)
        # Self-test: each way a one-line change could switch a design on is caught.
        for line in ('ChromeJoinDesign.current = .bracketed', 'ChromeReadShape.current=.lean', 'ChromeBracketRule . current = .perFact',
                     'env.design = .bracketed', 'let w = ChromeTypingWitness(design: .bracketed)', 'engine.rule = .perFact',
                     'var design: ChromeJoinDesign = .bracketed', 'return .lean', 'ChromeJoinDesign(rawValue: "bracketed")',
                     'let d = ChromeJoinDesign.bracketed', 'f(shape:.lean)'):
            self.assertTrue(self.qf17_switch_violations([('probe.swift', 'func f() {\n    %s\n}\n' % line)]), line)
        for line in ('if environment.design == .bracketed { x() }', 'guard design != .bracketed else { return }', 'let lean = ChromeReadShape.current == .lean',
                     'case .perFact:', '// ChromeJoinDesign.current = .bracketed', 'let s = "design = .bracketed"',
                     'burst.bracketed = environment.design == .bracketed', 'if d == ChromeJoinDesign.bracketed {}'):
            self.assertEqual(self.qf17_switch_violations([('probe.swift', 'func f() {\n    %s\n}\n' % line)]), [], line)

    # Review 10:35 (Codex QF-1, cffe8c6): boundary recovery stays off. Its two declarations default to false, and the
    # only other assignment under Sources/ copies the environment's value into the burst; nothing sets it on.
    QF1_ALLOWED = ('var recoverBracketedBoundaries = false', 'public var recoverBracketedBoundaries = false',
                   'burst.recoverBracketedBoundaries = environment.recoverBracketedBoundaries')
    @classmethod
    def qf1_recovery_violations(cls, files):
        bad = []
        for name, text in files:
            code = cls._swift_code(text)
            for m in re.finditer(r'recoverBracketedBoundaries\s*=(?!=)', code):
                line = code[code.rfind('\n', 0, m.start()) + 1:code.find('\n', m.start()) if code.find('\n', m.start()) >= 0 else len(code)].strip()
                if re.sub(r'\s+', ' ', line) not in cls.QF1_ALLOWED:
                    bad.append('%s: sets recoverBracketedBoundaries: %s' % (name, line))
            for m in re.finditer(r'recoverBracketedBoundaries\s*:', code):
                bad.append('%s: passes recoverBracketedBoundaries as an argument' % name)
        return bad
    def test_qf1_recovery_stays_off(self):
        files = [(str(f.relative_to(ROOT)), f.read_text()) for f in sorted((ROOT / 'Sources').rglob('*.swift'))]
        self.assertEqual(self.qf1_recovery_violations(files), [])
        route = (ROOT / 'Sources/MacMemApp/WebTypingRoute.swift').read_text()
        join = (ROOT / 'Sources/MemoryCore/BrowserTypingJoin.swift').read_text()
        self.assertEqual(route.count('var recoverBracketedBoundaries = false'), 1)
        self.assertEqual(join.count('public var recoverBracketedBoundaries = false'), 1)
        self.assertEqual(route.count('burst.recoverBracketedBoundaries = environment.recoverBracketedBoundaries'), 1)
        for line in ('env.recoverBracketedBoundaries = true', 'burst.recoverBracketedBoundaries=true', 'var recoverBracketedBoundaries = true',
                     'x.recoverBracketedBoundaries = flag', 'let e = Environment(recoverBracketedBoundaries: true)'):
            self.assertTrue(self.qf1_recovery_violations([('probe.swift', 'func f() {\n    %s\n}\n' % line)]), line)
        for line in ('if burst.recoverBracketedBoundaries == true {}', '// env.recoverBracketedBoundaries = true',
                     'guard !environment.recoverBracketedBoundaries else { return }'):
            self.assertEqual(self.qf1_recovery_violations([('probe.swift', 'func f() {\n    %s\n}\n' % line)]), [], line)

if __name__ == '__main__': unittest.main()
