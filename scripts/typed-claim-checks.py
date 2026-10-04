#!/usr/bin/env python3
"""Safe typing H: the "is it a keylogger?" answer must stay literally true.

Scans every app string source, the README and release notes for claim
wording that the product can't back up:
- "never leaves your Mac" without an "unless ..." clause in the same sentence
  (AI apps get summaries, and exact words can go out when the person allows it);
- "skips passwords" without "fields" (ordinary-looking passwords typed into
  normal text boxes can be missed; only password fields are never read);
- "(history|memory|everything) is encrypted" (only what you type is);
- "open source" in the typing claim while the repository has no MIT
  LICENSE, or `TypedClaim.openSourcePublished = true` without one.
The rules test themselves against bad and good fixtures first, so a rule
that stops matching fails the check instead of passing silently.
"""
import pathlib
import re
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCANNED = ['Sources', 'adapters', 'UIRender', 'packaging', 'BrowserBridge/extension', 'ConnectionSetup/Sources', 'docs']
SCANNED_FILES = ['README.md', 'RELEASE.md', 'UI-REVISION.md']
SUFFIXES = {'.swift', '.md', '.plist', '.html', '.json', '.strings', '.js', '.txt'}

NEVER_LEAVES = re.compile(r"never\s+(?:leaves?|leaving|sends?\s+(?:it|them|anything)\s+(?:off|out\s+of))\s+(?:your|this|the)\s+Mac", re.I)
SKIPS_PASSWORDS = re.compile(r"\b(?:skips?|skipping|ignores?|never\s+records?)\s+(?:your\s+)?passwords?\b(?!\s+fields?)", re.I)
ALL_ENCRYPTED = re.compile(r"\b(?:history|memory|everything|all (?:your )?data|your data)\s+(?:is|are|stays?)\s+(?:fully\s+|always\s+)?encrypted", re.I)
OPEN_SOURCE = re.compile(r"open[ -]source", re.I)
BACKUPS = re.compile(r"\bbackups?\s+(?:don't|do not|never|won't)\s+(?:include|hold|contain|keep)", re.I)
SENTENCE_END = re.compile(r"[.!?](?:\s|$)|\\n|\n")


def sentence_after(text, start):
    """The rest of the sentence from `start` (up to 240 characters)."""
    tail = text[start:start + 240]
    end = SENTENCE_END.search(tail)
    return tail[:end.start()] if end else tail


def problems(text):
    found = []
    for m in NEVER_LEAVES.finditer(text):
        if not re.search(r"\bunless\b", sentence_after(text, m.start()), re.I):
            found.append(('never-leaves-without-unless', m.group(0)))
    for m in SKIPS_PASSWORDS.finditer(text):
        found.append(('skips-passwords-without-fields', m.group(0)))
    for m in BACKUPS.finditer(text):
        # Only DayDream's own backups: Time Machine copies the database file.
        if not re.search(r"DayDream(?:'|\u2019)s own\s+$", text[max(0, m.start() - 20):m.start()]):
            found.append(('backups-claim-unqualified', m.group(0)))
    for m in ALL_ENCRYPTED.finditer(text):
        before = text[max(0, m.start() - 12):m.start()].lower()
        if "n't" not in text[m.start():m.end()] and "not" not in before:
            found.append(('everything-encrypted', m.group(0)))
    return found


def license_is_mit():
    for name in ['LICENSE', 'LICENSE.txt', 'LICENSE.md']:
        path = ROOT / name
        if path.exists():
            body = path.read_text(errors='replace')
            return (body.startswith('MIT License\n') and 'Copyright (c) 2026 The DayDream Authors' in body
                    and 'Permission is hereby granted, free of charge' in body and 'Apache' not in body)
    return False


def scanned_files():
    for folder in SCANNED:
        base = ROOT / folder
        if base.exists():
            for path in sorted(base.rglob('*')):
                if path.is_file() and path.suffix in SUFFIXES and '.build' not in path.parts and 'node_modules' not in path.parts:
                    yield path
    for name in SCANNED_FILES:
        if (ROOT / name).exists():
            yield ROOT / name


class ClaimRules(unittest.TestCase):
    def test_rules_catch_the_original_sentence(self):
        original = "Off by default, encrypted, never leaves your Mac, open source, skips passwords and private windows, and deletes the exact words after 7 days."
        kinds = {kind for kind, _ in problems(original)}
        self.assertEqual(kinds, {'never-leaves-without-unless', 'skips-passwords-without-fields'})

    def test_rules_catch_variants(self):
        for bad in ["Your typing never leaves this Mac.", "It skips passwords.", "DayDream ignores your passwords",
                    "Your history is encrypted.", "Everything is fully encrypted on disk.",
                    "Typed text never leaves your Mac. Unless you connect an AI app.",
                    'Text("Never leaves your Mac")', "Backups don't include the exact words you typed."]:
            self.assertTrue(problems(bad), bad)

    def test_rules_pass_the_corrected_wording(self):
        for good in ["Off by default. When on, what you type is encrypted on your Mac, password fields and private browser windows are skipped, the exact words are deleted after 7 days unless you choose otherwise, and they never leave your Mac unless you let an AI app or cloud summaries read them.",
                     "Off by default; encrypted on your Mac; skips password fields and private browser windows; deletes the exact words after 7 days.",
                     "Your history isn't encrypted yet, only what you type. Turn on FileVault.",
                     "Skips password fields, private windows, and things that look like passwords.",
                     "DayDream's own backups don't include the exact words you typed."]:
            self.assertEqual(problems(good), [], good)

    def test_app_strings_and_docs_make_no_false_claim(self):
        bad = []
        count = 0
        for path in scanned_files():
            count += 1
            text = path.read_text(errors='replace')
            for kind, match in problems(text):
                line = text[:text.find(match)].count('\n') + 1
                bad.append(f"{path.relative_to(ROOT)}:{line}: {kind}: {match!r}")
        self.assertGreater(count, 50, 'the scan reached the app sources')
        self.assertEqual(bad, [])

    def test_typed_claim_constant_is_honest(self):
        source = (ROOT / 'Sources/MemoryCore/TypedClaim.swift').read_text()
        body = source.split('public static var sentence: String {', 1)[1].split('}', 1)[0]
        self.assertEqual(problems(body.replace('\\(TypedRetention.default.label)', '7 days')), [])
        for phrase in ['password fields', 'private browser windows', 'DayDream deletes the exact words', 'unless you choose otherwise',
                       'AI apps never get the exact words', 'cloud summaries do only if you choose them',
                       'what you type is encrypted on your Mac']:
            self.assertIn(phrase, body)
        # AI apps have no typing key, so the sentence never offers them the words. Cloud summaries get them only
        # while typing is on and Cloud is the chosen writer (TypedAccess .cloudWriter), which the sentence says.
        self.assertNotIn('cloud summaries never', body)
        self.assertNotIn('unless you let an AI app', body)
        published = re.search(r'openSourcePublished\s*=\s*(true|false)', source).group(1) == 'true'
        if published:
            self.assertTrue(license_is_mit(), 'open source is claimed only with an MIT LICENSE')
        # The retention default the sentence names.
        policy = (ROOT / 'Sources/MemoryCore/TypedTextPolicy.swift').read_text()
        self.assertIn('public static let `default` = TypedRetention.days7', policy)

    def test_limits_name_time_machine_and_the_key_place(self):
        source = (ROOT / 'Sources/MemoryCore/TypedClaim.swift').read_text()
        self.assertIn('Time Machine backups of this Mac can keep older encrypted copies', source)
        # "stays on this Mac" is said for the data-protection keychain only.
        login = source.split('case .loginKeychain: return', 1)[1].split('\n', 1)[0]
        self.assertNotIn('stays on this Mac', login)
        self.assertIn('Time Machine', login)

    def test_open_source_typing_claim_needs_a_license(self):
        if license_is_mit():
            return
        bad = []
        for path in scanned_files():
            if path.name == 'TypedClaim.swift':
                continue  # gated by openSourcePublished, checked above
            text = path.read_text(errors='replace')
            for m in OPEN_SOURCE.finditer(text):
                window = text[max(0, m.start() - 200):m.end() + 200].lower()
                if 'typ' in window and ('encrypt' in window or 'keylogger' in window):
                    bad.append(f"{path.relative_to(ROOT)}: {m.group(0)!r}")
        self.assertEqual(bad, [])


if __name__ == '__main__':
    sys.exit(0 if unittest.main(argv=[sys.argv[0]] + sys.argv[1:], exit=False).result.wasSuccessful() else 1)
