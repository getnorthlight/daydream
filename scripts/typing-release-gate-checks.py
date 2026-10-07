#!/usr/bin/env python3
"""Safe typing E, the legal gate: typing beyond Notes and TextEdit needs a
lawyer session first (browser-scope/legal.md, launch checklist 12-13).

`TypingRelease.expandedApproved` is a code constant. These checks keep it an
honest one:
- the source declares it `false` exactly once, with no `#if` that a build flag
  could use to flip it, and nothing else in shipping code assigns it;
- no shipping source calls the table with `expanded: true` (only checks may);
- build 4's set is exactly Notes and TextEdit;
- with `--release DIR` (the `swift build -c release` products folder): a probe
  linked against the RELEASE-compiled PrivacyPolicy objects prints the gate
  and the allowed set with every category on, and they must be `false` and
  exactly Notes + TextEdit; `OwnerTyping.enabled`, `TypingRelease.open` and
  website typing for a normal site are all `false`.
- the owner switch (`DAYDREAM_OWNER_TYPING`, SPEC-LATER section 3):
  `OwnerTyping.enabled = true` appears only under `#if DAYDREAM_OWNER_TYPING`;
  no shipping file defines the flag (`-D`, `define(`); only
  `scripts/package.sh` and the check scripts pass it; the owner flag without
  `DAYDREAM_CHROME_TYPING` does not compile; `developer-id-release.py`
  refuses an owner app unless `--owner-build` is given.
- with `--owner DIR` (an owner `swift build -c release` products folder): the
  same probe prints `open=true`, a native row outside Notes and TextEdit is
  allowed, and the allowed set is exactly OWNER_SET (the table rows with a
  proof and a signer read on a Mac): larger than Notes and TextEdit, with
  Claude, ChatGPT and Mail read through the web-content proof, Spotlight as
  the one launcher panel, and Messages and Mail off under the default choices.
- the app proofs (typing-all apps track): AXEnhancedUserInterface is named
  once, in the owner build's AppTreeSwitch, written only there and only for
  the table's enhancedUserInterfaceApps after the signature check
  (chatgpt-capture: ChatGPT has no AXManualAccessibility); AXManualAccessibility
  is written in one place; the
  witness and route files hold no timer or polling loop; each app's signer
  comes from the table, never a fixed string.
The rules test themselves against bad fixtures first.
"""
import argparse
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
TABLE = ROOT / 'PrivacyPolicy/Sources/PrivacyPolicy/TypingCategories.swift'
SHIPPING = ['Sources', 'adapters', 'PrivacyPolicy/Sources', 'BrowserBridge', 'WriterBackend/Sources', 'ConnectionSetup/Sources', 'UIRender', 'BackupRestore']
BUILD_FOUR = {'com.apple.Notes', 'com.apple.TextEdit'}
# The owner build's allowed set (typing-all apps track): every table row with a
# capture proof, a confirmed bundle ID and a signer read on a Mac.
OWNER_SET = BUILD_FOUR | {'com.apple.Pages', 'com.apple.Spotlight', 'com.anthropic.claudefordesktop', 'com.openai.codex', 'com.openai.chat',
                          'com.apple.Terminal', 'com.mitchellh.ghostty', 'com.apple.dt.Xcode', 'com.apple.MobileSMS', 'com.apple.mail',
                          'net.whatsapp.WhatsApp', 'md.obsidian', 'com.todesktop.230313mzl4w4u92'}
OWNER_WEB = {'com.anthropic.claudefordesktop', 'com.openai.codex', 'com.apple.mail', 'md.obsidian', 'com.todesktop.230313mzl4w4u92'}
# fix/typing-e2e L1: Messages and email is on by default, so the owner defaults are every owner app.
OWNER_DEFAULTS = set(OWNER_SET)
# Attribute names only the web-content proof's live reads use (owner build only).
WEB_CONTENT_STRINGS = ['AXManualAccessibility', 'AXEditableAncestor']
RELEASE = None
RELEASE_TMP = None
OWNER = None
OWNER_FLAG = 'DAYDREAM_OWNER_TYPING'
OWNER_FILE = ROOT / 'PrivacyPolicy/Sources/PrivacyPolicy/OwnerTyping.swift'
OWNER_GUARD = ROOT / 'Sources/MemoryCore/OwnerTypingGuard.swift'
# Files that may pass the owner flag to a compiler: the packager, the release pipeline's
# stage (one OWNER_SWIFT_FLAGS tuple, used for every stage since the owner's decision of 2026-09-25;
# test_release_pipeline_passes_both_flags_to_every_stage) and the checks.
OWNER_FLAG_PASSERS = {'scripts/package.sh', 'scripts/developer-id-release.py', 'scripts/check_developer_id_release.py',
                      'scripts/typing-release-gate-checks.py',
                      # launch/candidate: the DayDream Preview builder (separate bundle id) passes the release stage's flags.
                      'scripts/preview/build-preview-app.sh',
                      # claude/scrub-1004: README's Build from source shows the release's swift build line with both flags.
                      # claude/rel-017c: that section moved to docs/README-details.md with the short README.
                      'README.md', 'docs/README-details.md'}
# Check recipes, QA-harness build scripts and docs that compile or describe the owner lane (never a shipping build:
# Package.swift, packaging/ and the app's sources still never define the flag). Each with the commit that added it.
CHECK_AND_QA_PASSERS = {
    'runner-1001/run-checks.sh', 'runner-1001/owner-lane.sh', 'runner-1001/ui-checks.sh',  # 858ec32: the owner lane
    'scripts/agent-tools-evals.py',            # f2e15e7: agent-tools evals, owner lane
    'scripts/check-ui-revision.sh',            # 5a02623: UI revision check build (QA harness)
    'scripts/compile-legacy-qa-boundary.py',   # c92de61: asserts the QA stage's flags
    'scripts/day-review-checks.swift',         # ba46541: its compile line in a comment
    'scripts/reddit-combined-capture-checks.swift',  # 4a5a188: standalone QA check, compile line in a comment
    'scripts/run-messages-moment-checks.sh',   # d252cbf: Messages moment checks, owner flags
    'scripts/sig-modern-repro-build.py',       # d5f82ae: QA repro build
    'scripts/sig-note-prepare-build.py',       # d586301: QA note-prepare build
    'scripts/typing-public-lane-checks.py',    # 079c36d: asserts the release passes the flag
    'docs/agent-tools/ownership.md',           # 5a74d76: the owner lane's build line
    'docs/private-capture-qa.md',              # 0184887: QA fixture compiles
    'tools/capture-fixture-empty/README.md',   # 451b171: QA helper compile line
    'evidence-0930/CODEX-B-1001-REPORT.md',    # 630af14: a QA run's recorded command
}

DECLARED_FALSE = re.compile(r'public\s+static\s+let\s+expandedApproved\s*=\s*false\b')
ANY_ASSIGN = re.compile(r'expandedApproved\s*(?::\s*Bool\s*)?=(?!=)')
# A call into the typing table or policy that opens the gate (other UI code
# has unrelated `expanded:` arguments).
EXPANDED_TRUE = re.compile(r'\b(?:permits|permitsSite|releaseAllows|allowedBundles|excludedBundles|TypingIndicator\.state)\s*\([^\n]*\bexpanded\s*:\s*true\b')
BUILD_FOUR_DECL = re.compile(r'buildFourApps\s*:\s*Set<String>\s*=\s*\[([^\]]*)\]')


def table_problems(text):
    found = []
    if len(DECLARED_FALSE.findall(text)) != 1:
        found.append('gate-not-declared-false-once')
    if len(ANY_ASSIGN.findall(text)) != 1:
        found.append('gate-assigned-elsewhere')
    if re.search(r'^\s*#\s*if\b', text, re.M):
        found.append('conditional-compilation-in-table')
    m = BUILD_FOUR_DECL.search(text)
    if not m or set(re.findall(r'"([^"]+)"', m.group(1))) != BUILD_FOUR:
        found.append('build-four-set-changed')
    return found


def shipping_problems(path, text):
    found = []
    if path.resolve() != TABLE.resolve() and ANY_ASSIGN.search(text):
        found.append(('gate-assigned-outside-table', str(path)))
    if EXPANDED_TRUE.search(text):
        found.append(('expanded-true-in-shipping-code', str(path)))
    return found


def shipping_files():
    for base in SHIPPING:
        root = ROOT / base
        if root.is_dir():
            yield from (p for p in root.rglob('*.swift') if '.build' not in p.parts)


class RulesSelfTest(unittest.TestCase):
    GOOD = 'public enum TypingRelease {\n    public static let expandedApproved = false\n    public static let buildFourApps: Set<String> = ["com.apple.Notes", "com.apple.TextEdit"]\n}\n'

    def test_good_fixture_passes(self):
        self.assertEqual(table_problems(self.GOOD), [])

    def test_flipped_gate_fails(self):
        self.assertIn('gate-not-declared-false-once', table_problems(self.GOOD.replace('= false', '= true')))

    def test_flag_controlled_gate_fails(self):
        bad = '#if EXPANDED\npublic static let expandedApproved = true\n#else\n' + self.GOOD + '#endif\n'
        problems = table_problems(bad)
        self.assertIn('conditional-compilation-in-table', problems)
        self.assertIn('gate-assigned-elsewhere', problems)

    def test_wider_build_four_fails(self):
        self.assertIn('build-four-set-changed', table_problems(self.GOOD.replace('"com.apple.TextEdit"', '"com.apple.TextEdit", "com.apple.Terminal"')))

    def test_shipping_rules_catch_expanded_true(self):
        self.assertTrue(shipping_problems(ROOT / 'Sources/X.swift', 'TypingCategories.permits(bundle: b, on: on, expanded: true)'))
        self.assertTrue(shipping_problems(ROOT / 'Sources/X.swift', 'let expandedApproved = true'))
        self.assertTrue(shipping_problems(ROOT / 'Sources/X.swift', 'policy.excludedBundles(expanded:true)'))
        self.assertFalse(shipping_problems(ROOT / 'Sources/X.swift', 'func permits(expanded: Bool = TypingRelease.expandedApproved)'))
        self.assertFalse(shipping_problems(ROOT / 'Sources/X.swift', 'DisclosureGroup(expanded: true) { rows }'))


LATCH = ROOT / 'PrivacyPolicy/Sources/PrivacyPolicy/TerminalPromptLatch.swift'
SESSION = ROOT / 'PrivacyPolicy/Sources/PrivacyPolicy/TypingSession.swift'
LATCH_DECL = re.compile(r'public\s+static\s+let\s+wired\s*=\s*(true|false)\b')
LATCH_ASSIGN = re.compile(r'\bwired\s*(?::\s*Bool\s*)?=(?!=)')
# Evidence that typing sessions run every key through the latch: the session
# keeps latches, feeds them the window title and each key, and drops the key
# (with the terminal-prompt reason) when the latch says so.
LATCH_HOOK = [r'TerminalPromptLatch\(\)', r'\.titleObserved\(', r'\.key\(\.text\b', r'\.key\(\.submit\(', r'\.terminalPrompt\b',
              r'if\s+let\s+\w+\s*=\s*promptKey\(']


def latch_problems(latch_text, table_text, session_text=''):
    """Terminals stay refused until the prompt latch is wired into capture.
    `wired` is declared once, with no `#if`; `true` needs the session hook."""
    found = []
    declared = LATCH_DECL.findall(latch_text)
    if len(declared) != 1 or len(LATCH_ASSIGN.findall(latch_text)) != 1 or re.search(r'^\s*#\s*if\b', latch_text, re.M):
        found.append('latch-wired-not-declared-once')
    elif declared[0] == 'true' and not all(re.search(p, session_text) for p in LATCH_HOOK):
        found.append('latch-claimed-wired-without-session-hook')
    if not re.search(r'!app\.promptLatch\s*\|\|\s*TerminalPromptLatch\.wired', table_text):
        found.append('release-rule-ignores-the-latch')
    return found


OWNER_TRUE = re.compile(r'\benabled\s*=\s*true\b')
DEFINES_FLAG = re.compile(r'(?:-D\s*|define\(\s*"|-Xswiftc\s+-D)' + OWNER_FLAG)


def owner_problems(owner_text):
    """`OwnerTyping.enabled = true` only inside `#if DAYDREAM_OWNER_TYPING`, `false` in its `#else`."""
    found = []
    m = re.search(r'#if\s+' + OWNER_FLAG + r'\s*\n(.*?)#else\s*\n(.*?)#endif', owner_text, re.S)
    if not m:
        return ['owner-switch-not-under-the-flag']
    outside = owner_text[:m.start()] + owner_text[m.end():]
    if OWNER_TRUE.search(outside) or OWNER_TRUE.search(m.group(2)) or 'enabled = false' not in m.group(2):
        found.append('owner-enabled-outside-the-flag')
    if len(OWNER_TRUE.findall(m.group(1))) != 1:
        found.append('owner-branch-not-true-once')
    return found


def flag_definers(files):
    """Files (relative paths) that define or pass the owner flag."""
    return sorted(rel for rel, text in files if DEFINES_FLAG.search(text))


def strip_comments(text):
    """Swift source without // and /* */ comments (string contents kept)."""
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return re.sub(r'(?m)^((?:[^"\n]|"(?:\\.|[^"\\\n])*")*?)//.*$', r'\1', text)


APP_FILES = ['Sources/MacMemApp/NativeFocusWitness.swift', 'Sources/MacMemApp/NativeTypingRoute.swift']
POLLING = re.compile(r'\b(?:Timer|asyncAfter|DispatchSource|RunLoop|usleep|sleep)\b|while\s+true')


QA_IF = re.compile(r'^\s*#if DAYDREAM_QA_HARNESS && !?DAYDREAM_OWNER_TYPING( && DAYDREAM_CHROME_TYPING)?\s*$')


def without_qa(text):
    """`text` as a build without DAYDREAM_QA_HARNESS compiles it (as check_browser_boundary.py's): each
    `#if DAYDREAM_QA_HARNESS && ...` branch is dropped (nesting-aware); its `#else`/`#elseif` branch stays."""
    out, depth, skipping = [], 0, False
    for line in text.splitlines(keepends=True):
        st = line.strip()
        if skipping:
            if st.startswith('#if'):
                depth += 1
            elif st.startswith('#endif'):
                depth -= 1
                if depth == 0:
                    skipping = False
            elif depth == 1 and (st.startswith('#else') or st.startswith('#elseif')):
                skipping = False
            continue
        if QA_IF.match(line):
            skipping, depth = True, 1
            continue
        out.append(line)
    return ''.join(out)


assert without_qa('a\n#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING\nqa\n#if X\nqa2\n#endif\n#else\nkept\n#endif\nb\n') == 'a\nkept\n#endif\nb\n'


def app_proof_problems(files):
    """files: (relative path, text). The web-content proof's source rules, over what a shipping (non-QA) build
    compiles: the QA harness's own bootstraps (e01b406, aaeab02) focus a fresh test field and never ship."""
    found = []
    code = {rel: strip_comments(without_qa(text)) for rel, text in files}
    snapshot = code.get('Sources/MacMemApp/AccessibilitySnapshot.swift', '')
    # chatgpt-capture: AXEnhancedUserInterface only as AppTreeSwitch's one constant (ChatGPT, which has no
    # AXManualAccessibility), never anywhere else.
    for rel, text in code.items():
        if 'AXEnhancedUserInterface' in text and (rel != 'Sources/MacMemApp/AccessibilitySnapshot.swift' or text.count('AXEnhancedUserInterface') != 1
                or not re.search(r'enum AppTreeSwitch \{\n\s*static let enhancedUserInterface\s*=\s*"AXEnhancedUserInterface"', text)):
            found.append(('enhanced-user-interface', rel))
    if 'enhancedUserInterface as CFString' in snapshot:
        prepare = snapshot.split('static func prepareAppTree(', 1)[-1].split('static func restoreAppTrees(', 1)[0]
        if 'TypingCategories.enhancedUserInterfaceApps.contains(bundle)' not in prepare or 'trustedNativeProcess(pid:pid,bundle:bundle)' not in prepare \
                or 'allowed(bundle)' not in prepare:
            found.append(('enhanced-user-interface-not-scoped', 'AccessibilitySnapshot.swift'))
    writers = [rel for rel, text in code.items() if 'AXUIElementSetAttributeValue(' in text]
    enhanced_writes = len(re.findall(r'AXUIElementSetAttributeValue\(app,enhancedUserInterface as CFString,', snapshot))
    if writers != ['Sources/MacMemApp/AccessibilitySnapshot.swift'] or snapshot.count('AXUIElementSetAttributeValue(') != 1 + enhanced_writes \
            or enhanced_writes > 1 \
            or not re.search(r'AXUIElementSetAttributeValue\(app,manualAccessibility as CFString,kCFBooleanTrue\)', snapshot) \
            or len(re.findall(r'static let manualAccessibility\s*=\s*"AXManualAccessibility"', snapshot)) != 1:
        found.append(('attribute-write-not-only-the-manual-switch', writers))
    # The web-content proof's live reads and the switch writes: owner build only.
    gated = re.findall(r'#if DAYDREAM_OWNER_TYPING\n(.*?)#endif', snapshot, re.S)
    for needle in ['AXUIElementSetAttributeValue(', 'enum WebContentAXReader', '"AXEditableAncestor"', '"AXPlaceholderValue"', '"AXManualAccessibility"',
                   '"AXEnhancedUserInterface"', 'enum AppTreeSwitch']:
        if needle in snapshot and not any(needle in block for block in gated):
            found.append(('web-content-reads-outside-the-owner-build', needle))
    # The web-content reads are metadata: never the field's value, selection or a title.
    reader = snapshot.split('enum WebContentAXReader', 1)[1] if 'enum WebContentAXReader' in snapshot else ''
    if re.search(r'kAXValueAttribute|kAXTitleAttribute|kAXSelected\w*Attribute|"AXValue"|"AXTitle"|"AXSelected\w*"|"AXStringForRange"|"AXAttributedString', reader):
        found.append(('web-content-reads-field-text', 'AccessibilitySnapshot.swift'))
    for rel, text in code.items():
        if rel != 'Sources/MacMemApp/AccessibilitySnapshot.swift' and ('"AXManualAccessibility"' in text or 'WebContentAXReader.' in text):
            found.append(('web-content-reads-outside-the-owner-build', rel))
    for rel in APP_FILES:
        if POLLING.search(code.get(rel, '')):
            found.append(('polling-in-app-proof', rel))
    trusted = snapshot.split('private static func trustedNativeProcess(', 1)[-1].split('/// Where focus went', 1)[0]
    if 'TypingCategories.signingRequirement(' not in trusted or 'anchor apple' in trusted:
        found.append(('fixed-signer-in-trusted-process', 'AccessibilitySnapshot.swift'))
    return found


class GateChecks(unittest.TestCase):
    def test_app_proof_source_rules(self):
        good = [('Sources/MacMemApp/AccessibilitySnapshot.swift',
                 '// never AXEnhancedUserInterface\n#if DAYDREAM_OWNER_TYPING\nenum WebContentAXReader {\nstatic let manualAccessibility="AXManualAccessibility"\n'
                 'AXUIElementSetAttributeValue(app,manualAccessibility as CFString,kCFBooleanTrue)\n}\n#endif\n'
                 'private static func trustedNativeProcess(pid:pid_t)->Bool { TypingCategories.signingRequirement(row) }\n/// Where focus went\n'),
                ('Sources/MacMemApp/NativeFocusWitness.swift', 'final class W {} // no Timer here\n'),
                ('Sources/MacMemApp/NativeTypingRoute.swift', 'enum R {}\n')]
        self.assertEqual(app_proof_problems(good), [])
        def bad(rel, text):
            return app_proof_problems([(r, text if r == rel else t) for r, t in good])
        self.assertIn('enhanced-user-interface', [k for k, _ in app_proof_problems(good + [('Sources/X.swift', 'let a="AXEnhancedUserInterface"')])])
        # chatgpt-capture: the one allowed form, gated, scoped to the table's list and the signature check.
        enhanced = ('#if DAYDREAM_OWNER_TYPING\nenum AppTreeSwitch {\n    static let enhancedUserInterface="AXEnhancedUserInterface"\n'
                    'static func set() { AXUIElementSetAttributeValue(app,enhancedUserInterface as CFString,v) }\n}\n'
                    'static func prepareAppTree(frontmost pid:pid_t) { TypingCategories.enhancedUserInterfaceApps.contains(bundle) allowed(bundle) '
                    'trustedNativeProcess(pid:pid,bundle:bundle) }\nstatic func restoreAppTrees() {}\n#endif\n')
        with_enhanced = [(r, t + enhanced if r == 'Sources/MacMemApp/AccessibilitySnapshot.swift' else t) for r, t in good]
        self.assertEqual(app_proof_problems(with_enhanced), [])
        def enhanced_bad(text):
            return [k for k, _ in app_proof_problems([(r, t + text if r == 'Sources/MacMemApp/AccessibilitySnapshot.swift' else t) for r, t in good])]
        self.assertIn('enhanced-user-interface-not-scoped', enhanced_bad(enhanced.replace('TypingCategories.enhancedUserInterfaceApps.contains(bundle)', 'true')))
        self.assertIn('enhanced-user-interface-not-scoped', enhanced_bad(enhanced.replace('trustedNativeProcess(pid:pid,bundle:bundle)', '')))
        self.assertIn('enhanced-user-interface', enhanced_bad(enhanced.replace('enum AppTreeSwitch {', 'enum Other {')))
        self.assertIn('enhanced-user-interface', enhanced_bad(enhanced + 'let again="AXEnhancedUserInterface"\n'))
        self.assertIn('web-content-reads-outside-the-owner-build', enhanced_bad(enhanced.replace('#if DAYDREAM_OWNER_TYPING\n', '').replace('#endif\n', '')))
        self.assertIn('attribute-write-not-only-the-manual-switch',
                      enhanced_bad(enhanced.replace('}\n}\n', '}\nstatic func x() { AXUIElementSetAttributeValue(app,enhancedUserInterface as CFString,w) }\n}\n', 1)))
        self.assertIn('attribute-write-not-only-the-manual-switch', [k for k, _ in app_proof_problems(good + [('Sources/X.swift', 'AXUIElementSetAttributeValue(x,y,z)')])])
        # A write inside a QA-harness-only branch is not compiled into a shipping build; one outside it still is.
        qa = '#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING && DAYDREAM_CHROME_TYPING\nAXUIElementSetAttributeValue(f,k,v)\n#endif\n'
        self.assertEqual(app_proof_problems(good + [('Sources/QA.swift', qa)]), [])
        self.assertIn('attribute-write-not-only-the-manual-switch',
                      [k for k, _ in app_proof_problems(good + [('Sources/QA.swift', qa + 'AXUIElementSetAttributeValue(f,k,v)\n')])])
        self.assertIn('polling-in-app-proof', [k for k, _ in bad('Sources/MacMemApp/NativeFocusWitness.swift', 'Timer.scheduledTimer(withTimeInterval:1,repeats:true){_ in}')])
        self.assertIn('polling-in-app-proof', [k for k, _ in bad('Sources/MacMemApp/NativeTypingRoute.swift', 'DispatchQueue.main.asyncAfter(deadline:.now()){}')])
        self.assertIn('fixed-signer-in-trusted-process', [k for k, _ in bad('Sources/MacMemApp/AccessibilitySnapshot.swift',
            '#if DAYDREAM_OWNER_TYPING\nstatic let manualAccessibility="AXManualAccessibility"\nAXUIElementSetAttributeValue(app,manualAccessibility as CFString,kCFBooleanTrue)\n#endif\n'
            'private static func trustedNativeProcess(pid:pid_t)->Bool { "anchor apple and identifier" }\n/// Where focus went\n')])
        # The switch write or the web-content reads compiled into the public build.
        ungated = good[0][1].replace('#if DAYDREAM_OWNER_TYPING\n', '').replace('}\n#endif\n', '}\n')
        self.assertIn('web-content-reads-outside-the-owner-build', [k for k, _ in bad('Sources/MacMemApp/AccessibilitySnapshot.swift', ungated)])
        self.assertIn('web-content-reads-outside-the-owner-build', [k for k, _ in app_proof_problems(good + [('Sources/MacMemApp/EventCapture.swift', 'let n="AXManualAccessibility"')])])
        self.assertIn('web-content-reads-field-text', [k for k, _ in bad('Sources/MacMemApp/AccessibilitySnapshot.swift',
            good[0][1].replace('}\n#endif', 'copy(node,kAXValueAttribute)\n}\n#endif'))])
        self.assertIn('web-content-reads-field-text', [k for k, _ in bad('Sources/MacMemApp/AccessibilitySnapshot.swift',
            good[0][1].replace('}\n#endif', 'copy(node,"AXSelectedText")\n}\n#endif'))])
        files = [(str(p.relative_to(ROOT)), p.read_text()) for p in shipping_files()]
        self.assertEqual(app_proof_problems(files), [])

    def test_table_declares_the_gate_false(self):
        self.assertEqual(table_problems(TABLE.read_text()), [])

    def test_terminals_wait_for_the_prompt_latch(self):
        # Rewritten by typesafe SPEC 12.2 item 11: once the latch is wired,
        # `wired = true` is allowed, and only with the session hook in place.
        good_latch = 'public static let wired = false\n'
        good_table = 'signingRequirement(app) != nil,\n !app.promptLatch || TerminalPromptLatch.wired else { return false }'
        hook = ('var l=prompts[p.bundle] ?? TerminalPromptLatch()\nl.titleObserved(p.place,focusID:f)\nlet d=l.key(.text,focusID:f)\n'
                '_=l.key(.submit(line:x),focusID:f)\nreturn CaptureGate.result(.blocked,.terminalPrompt,p)\nif let dropped=promptKey(proof) {return dropped}\n')
        self.assertEqual(latch_problems(good_latch, good_table), [])
        self.assertEqual(latch_problems(good_latch.replace('false', 'true'), good_table, hook), [])
        self.assertIn('latch-claimed-wired-without-session-hook', latch_problems(good_latch.replace('false', 'true'), good_table))
        self.assertIn('latch-claimed-wired-without-session-hook', latch_problems(good_latch.replace('false', 'true'), good_table, hook.replace('if let dropped=promptKey(proof)', 'if false')))
        self.assertIn('latch-wired-not-declared-once', latch_problems('#if X\n' + good_latch.replace('false', 'true') + '#else\n' + good_latch + '#endif\n', good_table, hook))
        self.assertIn('release-rule-ignores-the-latch', latch_problems(good_latch, 'signingRequirement(app) != nil else { return false }'))
        self.assertEqual(latch_problems(LATCH.read_text(), TABLE.read_text(), SESSION.read_text()), [])

    def test_owner_switch_is_under_its_flag(self):
        good = ('public enum OwnerTyping {\n#if DAYDREAM_OWNER_TYPING\n    public static let enabled = true\n#else\n'
                '    public static let enabled = false\n#endif\n}\n')
        self.assertEqual(owner_problems(good), [])
        self.assertIn('owner-switch-not-under-the-flag', owner_problems('public enum OwnerTyping { public static let enabled = true }'))
        self.assertIn('owner-enabled-outside-the-flag', owner_problems(good.replace('enabled = false', 'enabled = true')))
        self.assertIn('owner-enabled-outside-the-flag', owner_problems(good + 'extension OwnerTyping { static let enabled = true }\n'))
        self.assertEqual(owner_problems(OWNER_FILE.read_text()), [])
        # The table opens only through the switch or the lawyer's constant.
        self.assertRegex(TABLE.read_text(), r'static\s+var\s+open\s*:\s*Bool\s*\{\s*expandedApproved\s*\|\|\s*OwnerTyping\.enabled\s*\}')

    def test_owner_flag_is_defined_only_by_the_packager_and_checks(self):
        self.assertEqual(flag_definers([('Package.swift', 'swiftSettings:[.define("DAYDREAM_OWNER_TYPING")]')]), ['Package.swift'])
        self.assertEqual(flag_definers([('x.sh', 'swift build -Xswiftc -DDAYDREAM_OWNER_TYPING')]), ['x.sh'])
        self.assertEqual(flag_definers([('x.swift', '#if DAYDREAM_OWNER_TYPING')]), [])
        try:
            tracked = subprocess.run(['git', 'ls-files'], cwd=ROOT, capture_output=True, text=True, check=True).stdout.split()
        except (OSError, subprocess.CalledProcessError):
            tracked = [str(p.relative_to(ROOT)) for p in ROOT.rglob('*') if p.is_file() and '.build' not in p.parts]
        files = []
        for rel in tracked:
            path = ROOT / rel
            if path.is_file() and path.stat().st_size < 4_000_000:
                try:
                    files.append((rel, path.read_text(errors='ignore')))
                except OSError:
                    pass
        definers = set(flag_definers(files))
        self.assertLessEqual(definers, OWNER_FLAG_PASSERS | CHECK_AND_QA_PASSERS)
        # What builds the app itself never turns the switch on: the manifests, packaging and the sources.
        self.assertFalse({d for d in definers if d.endswith('Package.swift') or d.startswith(('packaging/', 'Sources/', 'PrivacyPolicy/',
                          'WriterBackend/Sources', 'BrowserBridge/Sources'))})
        self.assertIn('scripts/package.sh', definers)
        package = (ROOT / 'scripts/package.sh').read_text()
        # package.sh passes it only when DAYDREAM_OWNER_TYPING=1, with CHROME_TYPING too.
        block = re.search(r'if \[\[ "\$\{DAYDREAM_OWNER_TYPING:-\}" == 1 \]\]; then\n(.*?)\nfi\n', package, re.S)
        self.assertIsNotNone(block, 'package.sh has one owner block')
        self.assertEqual(len(DEFINES_FLAG.findall(package)), len(DEFINES_FLAG.findall(block.group(1))))
        self.assertIn('-Xswiftc -DDAYDREAM_CHROME_TYPING', block.group(1))
        self.assertIn('OWNER BUILD: expanded typing and website typing ON', block.group(1))
        self.assertIn('MacMemOwnerTyping', block.group(1))

    def test_release_pipeline_passes_both_flags_to_every_stage(self):
        # developer-id-release.py names the defines once, in OWNER_SWIFT_FLAGS (both flags together),
        # and hands them to the builder for every stage: every release is the full-typing build (the
        # owner's decision of 2026-09-25). --owner-build only marks the owner's private copy.
        script = (ROOT / 'scripts/developer-id-release.py').read_text()
        lines = [l for l in script.splitlines() if DEFINES_FLAG.search(l)]
        self.assertEqual(lines, ["OWNER_SWIFT_FLAGS = ('-Xswiftc', '-DDAYDREAM_OWNER_TYPING', '-Xswiftc', '-DDAYDREAM_CHROME_TYPING')"])
        self.assertEqual(script.count('-DDAYDREAM_CHROME_TYPING'), 1)
        # 0184887 (QA harness out of normal builds): the stage's flags come from stage_swift_flags, which always
        # starts with OWNER_SWIFT_FLAGS and adds the QA flags only for an explicit --qa-harness owner stage.
        self.assertEqual(re.findall(r'.*swift_flags = .*', script), ['    swift_flags = stage_swift_flags(owner, args.updates, qa_harness)'])
        self.assertIn("    return OWNER_SWIFT_FLAGS + (QA_SWIFT_FLAGS if qa_harness else ())", script)
        self.assertIn('bin_dir = Path(builder(source, scratch, runner, swift_flags=swift_flags))', script)
        self.assertIn("owner = bool(getattr(args, 'owner_build', False))", script)
        import importlib.util
        spec = importlib.util.spec_from_file_location('developer_id_release_gate', ROOT / 'scripts/developer-id-release.py')
        dr = importlib.util.module_from_spec(spec)
        sys.path.insert(0, str(ROOT / 'scripts'))
        spec.loader.exec_module(dr)
        both = ('-Xswiftc', '-DDAYDREAM_OWNER_TYPING', '-Xswiftc', '-DDAYDREAM_CHROME_TYPING')
        for owner, updates in [(False, 'configured'), (False, 'off'), (True, 'off')]:
            self.assertEqual(dr.stage_swift_flags(owner, updates), both, (owner, updates))
        self.assertEqual(dr.stage_swift_flags(True, 'off', True), both + ('-Xswiftc', '-DDAYDREAM_QA_HARNESS'))
        for owner, updates in [(False, 'configured'), (False, 'off'), (True, 'configured')]:
            with self.assertRaises(dr.ReleaseError):
                dr.stage_swift_flags(owner, updates, True)

    def test_owner_flag_alone_does_not_compile(self):
        if RELEASE_TMP is None:
            self.skipTest('no --tmp folder given')
        with tempfile.TemporaryDirectory(dir=RELEASE_TMP) as work:
            cache = pathlib.Path(work) / 'cache'
            def compiles(*flags):
                return subprocess.run(['swiftc', '-typecheck', '-module-cache-path', str(cache), *flags, str(OWNER_GUARD)],
                                      capture_output=True, text=True).returncode == 0
            self.assertTrue(compiles(), 'public build')
            self.assertFalse(compiles('-D' + OWNER_FLAG), 'owner flag without Chrome typing is a compile error')
            self.assertTrue(compiles('-D' + OWNER_FLAG, '-DDAYDREAM_CHROME_TYPING'), 'owner build')

    def test_developer_id_refuses_an_owner_app_without_owner_build(self):
        # Print-only notarize and a refused dmg: nothing is signed, uploaded or run.
        import plistlib
        script = ROOT / 'scripts/developer-id-release.py'
        with tempfile.TemporaryDirectory(dir=RELEASE_TMP) as work:
            def app(folder, owner, typing=True):
                bundle = pathlib.Path(work) / folder / 'DayDream.app'
                (bundle / 'Contents/MacOS').mkdir(parents=True)
                # owner/v1: the app is DayDream.app, and dmg names the image from its version.
                info = {'CFBundleIdentifier': 'example.synthetic', 'CFBundleShortVersionString': '1.0 Beta'}
                if owner:
                    info['MacMemOwnerTyping'] = True
                (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
                # public-typing/v1: every stage compiles website typing in, the owner's copy and the public app alike.
                (bundle / 'Contents/MacOS/MacMem').write_bytes(b'x\x00$s14WebTypingRouteO\x00' if typing else b'synthetic')
                return bundle
            owner, public = app('owner', True), app('public', False)
            def run(*argv):
                done = subprocess.run([sys.executable, '-B', str(script), *argv], capture_output=True, text=True)
                return done.returncode, done.stdout + done.stderr
            code, text = run('notarize', '--artifact', str(owner), '--out', work)
            self.assertTrue(code != 0 and 'OWNER BUILD' in text and 'PRINT-ONLY' not in text, text)
            code, text = run('notarize', '--artifact', str(owner), '--out', work, '--owner-build')
            self.assertTrue(code == 0 and 'PRINT-ONLY' in text and '--owner-build' in text, text)
            code, text = run('notarize', '--artifact', str(public), '--out', work)
            self.assertTrue(code == 0 and 'PRINT-ONLY' in text, text)
            code, text = run('notarize', '--artifact', str(public), '--out', work, '--owner-build')
            self.assertTrue(code != 0 and 'not an owner build' in text, text)
            code, text = run('notarize', '--artifact', str(pathlib.Path(work) / 'DayDream-1.0-owner.dmg'), '--out', work)
            self.assertTrue(code != 0 and 'OWNER BUILD' in text, text)
            code, text = run('dmg', '--app', str(owner), '--out', str(pathlib.Path(work) / 'DayDream-1.0.dmg'), '--unsigned')
            self.assertTrue(code != 0 and 'OWNER BUILD' in text, text)
            code, text = run('dmg', '--app', str(owner), '--out', str(pathlib.Path(work) / 'DayDream-1.0.dmg'), '--unsigned', '--owner-build')
            self.assertTrue(code != 0 and '-owner.dmg' in text, text)
            # Website typing in the binary is no owner mark: every release carries it. Only the key is.
            code, text = run('notarize', '--artifact', str(public), '--out', work)
            self.assertTrue(code == 0 and 'PRINT-ONLY' in text and 'OWNER BUILD' not in text, text)
            # A narrow app (no website typing code: an old public stage, or package.sh without the owner flag)
            # is never notarized or packaged, with or without --owner-build (public-typing review).
            narrow, narrow_owner = app('narrow', False, typing=False), app('narrow-owner', True, typing=False)
            for bundle, extra in ((narrow, ()), (narrow_owner, ('--owner-build',))):
                code, text = run('notarize', '--artifact', str(bundle), '--out', work, *extra)
                self.assertTrue(code != 0 and 'Not the full-typing build' in text and 'PRINT-ONLY' not in text, text)
                code, text = run('dmg', '--app', str(bundle), '--out', str(pathlib.Path(work) / 'DayDream-1.0.dmg'), '--unsigned', *extra)
                self.assertTrue(code != 0 and 'Not the full-typing build' in text, text)

    def test_release_objects_allow_only_notes_and_textedit(self):
        if RELEASE is None:
            self.skipTest('no --release folder given')
        release = pathlib.Path(RELEASE)
        objects = sorted((release / 'PrivacyPolicy.build').glob('*.o'))
        self.assertTrue(objects, 'release PrivacyPolicy objects exist')
        self.assertTrue(any(o.name.startswith('TypingCategories') for o in objects), 'the release build compiled the table')
        with tempfile.TemporaryDirectory(dir=RELEASE_TMP) as work:
            probe = pathlib.Path(work) / 'main.swift'
            probe.write_text(PROBE)
            binary = pathlib.Path(work) / 'probe'
            cache = pathlib.Path(work) / 'cache'
            build = subprocess.run(['swiftc', '-O', '-module-cache-path', str(cache), '-I', str(release / 'Modules'), str(probe),
                                    *map(str, objects), '-o', str(binary)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr[-2000:])
            run = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertEqual(run.stdout.split(), ['false', 'com.apple.Notes,com.apple.TextEdit', 'false',
                                                  'OwnerTyping.enabled=false', 'open=false', 'native-row=false', 'permitsSite=false',
                                                  'probeBuild=false', 'capture=com.apple.Notes,com.apple.TextEdit', 'web=', 'panels=',
                                                  'defaults=com.apple.Notes,com.apple.TextEdit'])

    def test_public_release_binary_reads_no_web_content(self):
        """The public release MacMem never turns on an app's Accessibility tree
        and holds none of the web-content proof's live reads (apps track)."""
        if RELEASE is None:
            self.skipTest('no --release folder given')
        binary = pathlib.Path(RELEASE) / 'MacMem'
        self.assertTrue(binary.is_file(), binary)
        text = subprocess.run(['strings', '-a', str(binary)], capture_output=True, text=True).stdout
        names = subprocess.run(['nm', str(binary)], capture_output=True, text=True).stdout
        self.assertTrue('ChromePageProbe' in names, 'the scan reads a real MacMem')
        for needle in WEB_CONTENT_STRINGS:
            self.assertNotIn(needle, text)
        self.assertNotIn('WebContentAXReader', names)

    def test_owner_release_binary_has_the_web_content_proof(self):
        if OWNER is None:
            self.skipTest('no --owner folder given')
        binary = pathlib.Path(OWNER) / 'MacMem'
        self.assertTrue(binary.is_file(), binary)
        text = subprocess.run(['strings', '-a', str(binary)], capture_output=True, text=True).stdout
        for needle in WEB_CONTENT_STRINGS:
            self.assertIn(needle, text)

    def test_owner_objects_open_the_gate(self):
        if OWNER is None:
            self.skipTest('no --owner folder given')
        owner = pathlib.Path(OWNER)
        objects = sorted((owner / 'PrivacyPolicy.build').glob('*.o'))
        self.assertTrue(any(o.name.startswith('OwnerTyping') for o in objects), 'the owner build compiled the switch')
        with tempfile.TemporaryDirectory(dir=RELEASE_TMP) as work:
            probe = pathlib.Path(work) / 'main.swift'
            probe.write_text(PROBE)
            binary = pathlib.Path(work) / 'probe'
            build = subprocess.run(['swiftc', '-O', '-module-cache-path', str(pathlib.Path(work) / 'cache'), '-I', str(owner / 'Modules'),
                                    str(probe), *map(str, objects), '-o', str(binary)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr[-2000:])
            run = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            out = run.stdout.split()
            self.assertEqual(out[0], 'false', 'the lawyer constant stays false in the owner build')
            self.assertTrue(BUILD_FOUR <= set(out[1].split(',')), out[1])
            self.assertEqual(out[3:8], ['OwnerTyping.enabled=true', 'open=true', 'native-row=true', 'permitsSite=true', 'probeBuild=true'])
            # The apps track's rows (SPEC-LATER section 6): larger than Notes
            # and TextEdit, exactly the rows with a confirmed signer.
            def listed(token, key):
                self.assertTrue(token.startswith(key + '='), token)
                return set(filter(None, token.split('=', 1)[1].split(',')))
            self.assertEqual(set(out[1].split(',')), OWNER_SET)
            self.assertTrue(BUILD_FOUR < OWNER_SET)
            self.assertEqual(listed(out[8], 'capture'), OWNER_SET)
            self.assertEqual(listed(out[9], 'web'), OWNER_WEB)
            self.assertEqual(listed(out[10], 'panels'), {'com.apple.Spotlight'})
            self.assertEqual(listed(out[11], 'defaults'), OWNER_DEFAULTS)
            self.assertEqual(len(out), 12)

    def test_website_typing_is_in_the_owner_release_only(self):
        # typing-all SPEC-LATER 4.2: the owner release MacMem carries website
        # typing (its route, gate, site rules, row and honest status line);
        # the public release MacMem carries none of it.
        if OWNER is None or RELEASE is None:
            self.skipTest('needs --owner and --release folders')
        def contents(folder):
            binary = pathlib.Path(folder) / 'MacMem'
            self.assertTrue(binary.is_file(), binary)
            nm = subprocess.run(['nm', str(binary)], capture_output=True, text=True).stdout
            text = subprocess.run(['strings', '-a', str(binary)], capture_output=True, text=True).stdout
            self.assertTrue(nm and text, binary)
            return nm, text
        owner_nm, owner_text = contents(OWNER)
        public_nm, public_text = contents(RELEASE)
        for name in WEB_SYMBOLS:
            self.assertIn(name, owner_nm, name)
            self.assertNotIn(name, public_nm, name)
            self.assertNotIn(name, public_text, name)
        for text in WEB_STRINGS:
            self.assertIn(text, owner_text, text)
            self.assertNotIn(text, public_text, text)
        # The public release keeps its own browser line; the page history code is in both.
        self.assertIn("what you type in browsers is never saved", public_text)
        self.assertIn('ChromePageProbe', public_nm)


# Website typing: names and strings only the owner build carries.
WEB_SYMBOLS = ['WebTypingRoute', 'WebTypingGate', 'BrowserTypingSiteRules', 'WebTypedRow', 'BrowserTypingBurst', 'BrowserTypingJoin', 'WebSearchQuery']
WEB_STRINGS = ['chrome-typing-join-v1', 'chrome-search-url-v1', 'What you type on websites in Google Chrome is saved only while typing and Web pages in Chrome are both on']


# Printed by the probe: the gate, the allowed set with every category on,
# claude.ai under the defaults, the switch, the open flag, whether a signed
# native row outside build 4 passes the release rule with the defaults,
# website typing for a normal (Writing) site with every switch on, the
# device-test switch, the capture gate's allowlists (all, web content,
# launcher panels), and the allowed set under the default category choices.
PROBE = ('import PrivacyPolicy\n'
         'print(TypingRelease.expandedApproved)\n'
         'print(TypingCategories.allowedBundles(on: { _ in true }).sorted().joined(separator: ","))\n'
         'print(TypingCategories.permitsSite(host: "claude.ai", on: { _ in true }))\n'
         'print("OwnerTyping.enabled=\\(OwnerTyping.enabled)")\n'
         'print("open=\\(TypingRelease.open)")\n'
         'let row = TypingApp("com.example.synthetic.editor", "Synthetic", .writing, .apple, .native)\n'
         'print("native-row=\\(TypingCategories.releaseAllows(row))")\n'
         'print("permitsSite=\\(TypingCategories.permitsSite(host: "notion.so", path: "/notes", on: { _ in true }))")\n'
         'print("probeBuild=\\(TypingRelease.probeBuild)")\n'
         'print("capture=" + CaptureGate.nativeApps.sorted().joined(separator: ","))\n'
         'print("web=" + CaptureGate.webContentApps.sorted().joined(separator: ","))\n'
         'print("panels=" + CaptureGate.keyPanelApps.sorted().joined(separator: ","))\n'
         'print("defaults=" + TypingCategories.allowedBundles(on: { $0.defaultOn }).sorted().joined(separator: ","))\n')


if __name__ == '__main__':
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument('--release')
    ap.add_argument('--tmp')
    ap.add_argument('--owner')
    known, rest = ap.parse_known_args()
    RELEASE = known.release
    RELEASE_TMP = known.tmp
    OWNER = known.owner
    unittest.main(argv=[sys.argv[0], *rest])
