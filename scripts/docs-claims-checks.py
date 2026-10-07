#!/usr/bin/env python3
"""Checks that the user-facing docs match the code and each other.

Run from anywhere: python3 scripts/docs-claims-checks.py -v

It reads files only. It never builds, launches or downloads anything.
Post drafts kept outside the repo can be checked too (DAYDREAM_DRAFTS names their folder);
those checks are skipped when it is unset or the folder is absent.
"""
import ast
import os
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
IMAGES = DOCS / "images"
REPO = "getnorthlight/daydream"

# The files the docs track owns (SPEC 6.6). Other docs have their own checks.
OWNED = [
    "README.md", "PRIVACY.md", "SECURITY.md", "CONTRIBUTING.md",
    "docs/README-details.md",   # claude/rel-017c: the full reference the short README links to
    "docs/README.md", "docs/privacy-model.md", "docs/summaries.md", "docs/backup-restore.md",
    "docs/install.md", "docs/faq.md", "docs/bad-build-plan.md",
    "PrivacyPolicy/README.md",
]
# Pages other tracks add (SPEC 6.2). Until they merge, a link to them may dangle;
# after the merge the page exists and the link is checked like any other.
PENDING = {"docs/uninstall.md": "uninstall track"}
GITHUB_FILES = sorted(str(p.relative_to(ROOT)) for p in (ROOT / ".github").rglob("*") if p.is_file())


def raw(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


def read(rel):
    """A file's text. claude/rel-017c: README.md is the short version and docs/README-details.md, which it links to,
    holds the rest of what it used to say, so a claim about the README is checked against both (links and anchors are
    still checked per file: `anchors` reads each file alone)."""
    text = raw(rel)
    return text + "\n" + raw("docs/README-details.md") if rel == "README.md" else text


def slug(heading):
    """GitHub's heading anchor: lower case, punctuation dropped, spaces to hyphens."""
    text = re.sub(r"`", "", heading.strip().lower())
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


def anchors(rel):
    out, seen = set(), {}
    in_code = False
    for line in raw(rel).splitlines():
        if line.lstrip().startswith("```"):
            in_code = not in_code
            continue
        m = None if in_code else re.match(r"^#{1,6}\s+(.*)$", line)
        if m:
            base = slug(m.group(1))
            n = seen.get(base, 0)
            out.add(base if n == 0 else f"{base}-{n}")
            seen[base] = n + 1
    return out


def links(rel):
    """Markdown and HTML links outside code blocks and inline code."""
    text = re.sub(r"(?s)```.*?```", "", raw(rel))   # claude/rel-017c: each file alone, so links resolve from its folder
    text = re.sub(r"`[^`\n]*`", "", text)
    found = re.findall(r"\]\(([^)\s]+)\)", text)
    found += re.findall(r'(?:src|href)="([^"]+)"', text)
    return found


def swift_constant(rel, pattern):
    m = re.search(pattern, read(rel))
    if not m:
        raise AssertionError(f"{rel}: {pattern} not found")
    return m.group(1)


class OwnedFiles(unittest.TestCase):
    def test_no_placeholders_or_other_repos(self):
        for rel in OWNED + GITHUB_FILES:
            text = read(rel)
            self.assertNotIn("<org>", text, rel)
            for owner, repo in re.findall(r"github\.com/([\w.-]+)/([\w.-]+)", text):
                if repo.lower().startswith("daydream"):
                    self.assertEqual(f"{owner}/{repo}".lower().removesuffix(".git"), REPO, rel)

    def test_no_ssh_connections(self):
        for rel in OWNED:
            text = read(rel)
            self.assertNotRegex(text, r"Connections\s*[›>]\s*SSH", rel)
            for line in text.splitlines():
                if line.startswith("|"):
                    self.assertNotIn("SSH", line, f"{rel}: network or table row mentions SSH: {line}")

    def test_banned_claims(self):
        banned = [
            "not signed", "unsigned", "not notarized", "update checks are off", "updates are off",
            "coming soon", "no dock icon", "all browser activity", "batches of up to 20",
            "records all browsers", "encrypted at rest", "end-to-end", "nothing ever leaves",
            "nothing leaves your mac.", "summaries on your mac are available",
        ]
        for rel in OWNED:
            low = read(rel).lower()
            for phrase in banned:
                self.assertNotIn(phrase, low, f"{rel}: {phrase!r}")

    def test_old_name_only_in_rename_context(self):
        for rel in ["PRIVACY.md", "SECURITY.md", "docs/install.md", "docs/faq.md", "docs/bad-build-plan.md",
                    "docs/privacy-model.md", "docs/summaries.md", "docs/backup-restore.md"]:
            self.assertNotIn("Mac Mem", read(rel), rel)

    def test_relative_links_resolve(self):
        for rel in OWNED:
            base = (ROOT / rel).parent
            for link in links(rel):
                if re.match(r"^[a-z]+:", link) or link.startswith("//"):
                    continue
                path, _, frag = link.partition("#")
                target = (base / path).resolve() if path else (ROOT / rel).resolve()
                target_rel = str(target.relative_to(ROOT)) if target.is_relative_to(ROOT) else None
                if not target.exists() and target_rel in PENDING:
                    continue
                self.assertTrue(target.exists(), f"{rel}: broken link {link}")
                if frag and target_rel in OWNED:
                    self.assertIn(frag, anchors(target_rel), f"{rel}: missing anchor {link}")


    def test_no_old_nothing_sent_claims(self):
        # Usage counts are sent: no owned page may still say there are no analytics or that nothing reaches the
        # developers. Each page that talks about it names PostHog and the switch.
        for rel in OWNED:
            low = read(rel).lower()
            for phrase in ["no analytics", "analytics, telemetry", "no telemetry", "or telemetry", "receive nothing", "receives nothing",
                           "nothing, unless you send it to us", "never receive your history, your settings or anything about how you use"]:
                self.assertNotIn(phrase, low, f"{rel}: {phrase!r}")
            self.assertNotIn("everything stays on your mac", low, rel)
        for rel in ["README.md", "PRIVACY.md", "SECURITY.md", "docs/faq.md", "docs/privacy-model.md"]:
            text = read(rel)
            self.assertIn("PostHog", text, rel)
            self.assertIn("Settings › Advanced", text, rel)
        privacy = read("PRIVACY.md")
        self.assertIn("## Usage counts", privacy)
        self.assertIn("never include your history", privacy)


class PendingPages(unittest.TestCase):
    def test_pending_pages(self):
        missing = [f"{page} ({track})" for page, track in PENDING.items() if not (ROOT / page).exists()]
        if missing:
            self.skipTest("not merged yet: " + ", ".join(missing))


class Readme(unittest.TestCase):
    text = read("README.md")

    def test_title_and_links(self):
        self.assertTrue(self.text.startswith("# DayDream\n"))
        for target in ["docs/uninstall.md", "docs/rename.md", "docs/install.md", "docs/faq.md", "PRIVACY.md", "SECURITY.md"]:
            # claude/rel-017c: from README.md, or from docs/README-details.md (whose links start in docs/).
            from_details = target[len("docs/"):] if target.startswith("docs/") else "../" + target
            self.assertTrue(f"]({target}" in raw("README.md") or f"]({from_details}" in raw("docs/README-details.md"), target)

    def test_release_facts(self):
        low = self.text.lower()
        self.assertIn("notarized", low)
        self.assertIn("developer id", low)
        self.assertIn("github releases", low)
        # Opt-out since 9/28 (owner): setup shows typing on, one click turns it off.
        self.assertIn("one click turns it off", low)
        self.assertNotIn("setup never turns it on", low)
        # writer/v1 (owner decision 2026-09-26): On this Mac is in every release; the model downloads on request.
        self.assertNotIn("aren't offered in the download", low)
        for needle in ["the runtime that runs the model is inside the app", "qwen3.5-4b (2.74 gb)", "8 gb of memory",
                       "finishes after daydream opens again", "turns back on by itself"]:
            self.assertIn(needle, low)
        self.assertIn("not encrypted", low)

    def test_typed_text_names_what_the_release_records(self):
        # Every release stage builds the full-typing app (owner decision of 2026-09-25), so the README's
        # Typed text table names exactly the apps that build's release gate allows: OWNER_SET in
        # typing-release-gate-checks.py, which that check proves against the built gate. No more, no fewer.
        section = self.text.split("\n### Typed text\n", 1)[1].split("\n## ", 1)[0]
        table = read("PrivacyPolicy/Sources/PrivacyPolicy/TypingCategories.swift")
        names = dict(re.findall(r'TypingApp\("([^"]+)", "([^"]+)"', table))
        gate = read("scripts/typing-release-gate-checks.py")
        four = ast.literal_eval(re.search(r"BUILD_FOUR = (\{[^}]*\})", gate).group(1))
        more = ast.literal_eval(re.search(r"OWNER_SET = BUILD_FOUR \| (\{[^}]*\})", gate).group(1))
        allowed = {names[b] for b in four | more}
        listed = set()
        for row in section.splitlines():
            cells = [c.strip() for c in row.strip().strip("|").split("|")]
            if not row.startswith("| ") or len(cells) < 4 or cells[0] in ("Kind", "---"):
                continue
            listed |= {a.strip() for a in re.sub(r"\([^)]*\)", "", cells[1]).split(",") if a.strip()}
        self.assertEqual(listed, allowed, "the README lists exactly the apps the release records typing in")
        self.assertNotIn("Notes and TextEdit only", self.text)
        for phrase in ["Websites need two switches", "Web pages in Chrome", "Incognito or Guest", "password fields",
                       "encrypted", "7 days", "never the words", "If you choose cloud summaries, they get the words you type", "Messages and email",
                       "Anyone typing on this Mac account while it's on is recorded"]:
            self.assertIn(phrase, section, phrase)

    def test_network_table_lists_update_checks(self):
        section = self.text.split("## Network connections", 1)[1].split("\n## ", 1)[0]
        self.assertIn("github.com", section)
        self.assertIn("openrouter.ai", section)
        self.assertIn("us.i.posthog.com", section)

    def test_usage_counts_are_listed_plainly(self):
        # Anonymous usage counts (Sources/MacMemApp/UsageSender.swift): the README lists every kind, says what is never
        # sent, and names the switch as Settings › Advanced draws it (UsageSharingText.title).
        section = self.text.split("### Usage counts", 1)[1].split("\n## ", 1)[0]
        title = re.search(r'public static let title = "([^"]+)"', read("Sources/MemoryUI/UsageSharingSettings.swift")).group(1)
        self.assertEqual(title, "Share anonymous usage counts")
        for needle in ["**Installed**", "**Setup**", "**Once a day**", "**AI apps**", "**Opening and searching**", "PostHog",
                       "random ID", "Settings › Advanced", title, "See what's sent", "Copy ID", "Test and development builds never send",
                       "never sends your history, typed words, window or page titles, sites, searches", "Never what you searched"]:
            self.assertIn(needle, section, needle)


class Pictures(unittest.TestCase):
    def test_every_picture_is_rendered_referenced_and_present(self):
        names = re.search(r"static let names\s*=\s*\[([^\]]*)\]", read("scripts/docs-install-render.swift"))
        self.assertIsNotNone(names)
        rendered = set(re.findall(r'"([\w-]+)"', names.group(1)))
        on_disk = {p.stem for p in IMAGES.glob("*.png")}
        self.assertEqual(rendered, on_disk, "docs/images must hold exactly the rendered pictures")
        used = set()
        for rel in ["README.md", "docs/install.md"]:
            used |= {Path(l).stem for l in links(rel) if l.endswith(".png") and "images/" in l}
        self.assertEqual(used, on_disk, "every picture is used, and every used picture exists")

    def test_pictures_have_alt_text(self):
        for rel in ["docs/install.md"]:
            for alt in re.findall(r"!\[([^\]]*)\]\(images/", read(rel)):
                self.assertGreater(len(alt), 20, f"{rel}: alt text too short: {alt!r}")
        for alt in re.findall(r'<img [^>]*alt="([^"]*)"', read("README.md")):
            self.assertGreater(len(alt), 20)

    def test_pictures_are_sample_data(self):
        self.assertIn("sample data", read("docs/install.md"))
        self.assertIn("sample data", read("README.md"))


class Policy(unittest.TestCase):
    def test_privacy_contact(self):
        text = read("PRIVACY.md")
        self.assertTrue("[CONTACT EMAIL]" in text or re.search(r"(?m)^## Contact", text))
        self.assertIn("Effective", text)

    def test_faq_questions(self):
        heads = [h.strip() for h in re.findall(r"(?m)^## (.*)$", read("docs/faq.md"))]
        for q in ["Is this a keylogger?", "What leaves my Mac?", "Is my history encrypted?", "How do I delete everything?"]:
            self.assertIn(q, heads)

    def test_faq_keylogger_answer_matches_capture(self):
        # EventCapture ignores key presses unless typed text is on.
        capture = read("Sources/MacMemApp/EventCapture.swift")
        self.assertRegex(capture, r"guard\s+coordinator\.captureText")
        self.assertIn("ignores key presses", read("docs/faq.md"))

    def test_security_private_reporting(self):
        text = read("SECURITY.md")
        self.assertIn(f"https://github.com/{REPO}/security/advisories/new", text)
        self.assertIn("DayDream.Writer.OpenRouter", text)
        self.assertIn(swift_constant("WriterBackend/Sources/WriterBackend/CloudWriter.swift", r'model = "([^"]+)"').split("/")[0], read("docs/summaries.md"))

    def test_bug_form_asks_for_report_a_problem(self):
        form = read(".github/ISSUE_TEMPLATE/bug_report.yml")
        self.assertIn("Report a Problem", form)
        self.assertRegex(form, r"id:\s*report")
        self.assertNotIn("<org>", form)

    def test_pr_template_privacy_checklist(self):
        pr = read(".github/PULL_REQUEST_TEMPLATE.md")
        for needle in ["PRIVACY.md", "docs/faq.md", "docs-claims-checks.py", "- [ ]"]:
            self.assertIn(needle, pr)

    def test_docs_index_lists_every_page(self):
        index = read("docs/README.md")
        for page in ["install.md", "faq.md", "uninstall.md", "rename.md", "privacy-model.md", "browser-capture.md",
                     "summaries.md", "backup-restore.md", "bad-build-plan.md"]:
            self.assertIn(f"]({page})", index, page)


class Summaries(unittest.TestCase):
    text = read("docs/summaries.md")
    notes = "WriterBackend/Sources/WriterBackend/CanonicalNotes.swift"
    view = "WriterBackend/Sources/WriterBackend/ModelView.swift"

    def test_writer_versions(self):
        for name in ["localVersion", "cloudVersion"]:
            version = swift_constant(self.notes, rf'static let {name}="([^"]+)"')
            self.assertIn(version, self.text)
        self.assertNotIn("batches of up to 20", self.text)

    def test_every_named_writer_version_is_current(self):
        # fix/sx-all round 2: a page naming an older writer version ("prompt7-validator9") describes code that is gone.
        current = {swift_constant(self.notes, rf'static let {n}="([^"]+)"') for n in ["localVersion", "cloudVersion", "codeVersion"]}
        suffixes = {re.search(r"prompt\d+-validator\d+|validator\d+$", v).group(0) for v in current}
        validators = {re.search(r"validator\d+", v).group(0) for v in current}
        for rel in ["README.md", "PRIVACY.md"] + sorted(str(p.relative_to(ROOT)) for p in (ROOT / "docs").glob("*.md")):
            text = read(rel)
            for m in re.finditer(r"prompt\d+-validator\d+", text):
                self.assertIn(m.group(0), suffixes, f"{rel}: {m.group(0)}")
            for m in re.finditer(r"\bvalidator\d+\b", text):
                self.assertIn(m.group(0), validators, f"{rel}: {m.group(0)}")

    def test_limits_match_code(self):
        m = re.search(r"maxActions = (\d+), maxItems = (\d+), maxViewBytes = (\d+)", read(self.view))
        actions, items, size = m.groups()
        self.assertIn(f"more than {actions} actions", self.text)
        self.assertIn(f"more than {items} items", self.text)
        self.assertIn(f"{int(size):,} bytes", self.text)
        caps = re.search(r"bulletCap:\[ModelView\.Scope:Int\]=\[\.moment:(\d+),\.day:(\d+)\]", read(self.notes))
        self.assertIn(f"A moment gets 1 to {caps.group(1)} bullets and a day 2 to {caps.group(2)}", self.text)
        chars = re.search(r"bulletChars=(\d+),titleChars=(\d+)", read(self.notes))
        self.assertIn(f"at most {chars.group(1)} characters", self.text)
        self.assertIn(f"title is at most {chars.group(2)} characters", self.text)
        self.assertIn(f"limited to {swift_constant(self.notes, r'maxTokens=(\d+)')} tokens", self.text)
        self.assertIn(f"up to {swift_constant(self.notes, r'salvageMax=(\d+)')} plain bullets".replace("up to 3", "up to three"), self.text)
        # fix/sx-all round 1: typed words to the writer, and no cloud action cap.
        quote = int(re.search(r"typedQuoteChars = (\d+)", read(self.view)).group(1))
        self.assertIn(f"up to {quote:,} characters of each draft", self.text)

    def test_schedule_matches_code(self):
        # fix/sx-all round 1: the batch schedule (WriterIntegration, WriterScheduling, LevelPower), quoted from the code.
        writer = read("Sources/MacMemApp/WriterIntegration.swift")
        scheduling = read("Sources/MacMemApp/WriterScheduling.swift")
        self.assertIn("static let closeAfter:TimeInterval=10*60", scheduling)
        self.assertIn("static let closeAfterLater:TimeInterval=2*60", scheduling)
        self.assertIn("closes 10 minutes after its last action (2 minutes once a later moment has started)", self.text)
        self.assertIn("static let batchEvery:TimeInterval=20*60", writer)
        self.assertIn("static let idleClose:TimeInterval=5*60", writer)
        self.assertIn("at most every 20 minutes", self.text)
        self.assertIn("static let batchNotes=12", writer)
        self.assertIn("up to 12 notes", self.text)
        self.assertIn("static let codeLevelsEvery:TimeInterval=10*60", writer)
        # Summary UX: local live updates and healthy battery background work are explicit.
        self.assertIn("static let liveEvery:TimeInterval=10*60", scheduling)
        self.assertIn("static let overdueAfter:TimeInterval=5*60", writer)
        self.assertIn("nonisolated static let typingBurst:TimeInterval=3", writer)
        self.assertIn("every 10 minutes", self.text)
        self.assertIn("Closed local moments waiting 5 minutes", self.text)
        self.assertIn("3 seconds after the last key event", self.text)
        self.assertIn("local background summaries may run at 20% charge or above", self.text)
        self.assertNotIn("Only closed moments are written", self.text)
        self.assertIn("static let onDemandBatteryNotes=3", writer)
        self.assertIn("static let onDemandBatteryEvery:TimeInterval=15*60", writer)
        self.assertIn("at most 3 notes at most every 15 minutes", self.text)
        self.assertIn("static let backoff:[TimeInterval]=[60,300,900,3600]", writer)
        self.assertIn("1, 5, 15, then 60 minutes", self.text)
        self.assertIn("retryDelays: [TimeInterval] = [2, 8]", read("WriterBackend/Sources/WriterBackend/CloudWriter.swift"))
        self.assertIn("after 2 and 8 seconds", self.text)
        self.assertIn("up to 3 times", self.text)
        self.assertIn("pending-v1.json", writer)
        self.assertIn("WriterScheduling/pending-v1.json", self.text)
        for stale in ["30 seconds after its last action", "never retried", "every 15 seconds", "at most six times", "one paid call per note",
                      "press **download**", "there is no repair turn"]:
            self.assertNotIn(stale, self.text.lower(), stale)

    def test_cloud_gets_page_titles(self):
        # fix/sx-all round 1: Chrome pages go to cloud notes as cleaned titles and sites; every page says so.
        transport = read("WriterBackend/Sources/WriterBackend/CloudWriter.swift")
        for needle in ['"zdr":true', '"data_collection":"deny"', '"allow_fallbacks":false']:
            self.assertIn(needle, transport)
        self.assertIn('reply.hasPrefix("deepseek/deepseek-v4-flash")', transport)
        self.assertIn("starts with `deepseek/deepseek-v4-flash`", self.text)
        self.assertIn("`zdr: true`, `data_collection: deny`", self.text)
        self.assertIn('status:"generated_unverified"', read("Sources/MemoryCore/DerivedNotes.swift"))
        self.assertIn("`generated_unverified`", self.text)
        self.assertIn("Chrome pages go to cloud notes as their page titles and sites", self.text)
        switch = swift_constant("Sources/MemoryUI/CloudSummariesSwitch.swift", r'public static let title = "([^"]+)"')
        self.assertIn(f"**{switch}**", self.text)
        for rel in ["README.md", "PRIVACY.md", "docs/privacy-model.md", "docs/summaries.md"]:
            low = read(rel).lower()
            for stale in ["never the page title", "100 actions", "100 recorded actions", "never goes online by itself",
                          "search terms never go", "cloud summaries switch", "press download"]:
                self.assertNotIn(stale, low, f"{rel}: {stale!r}")
        for rel in ["README.md", "PRIVACY.md", "docs/privacy-model.md"]:
            self.assertRegex(read(rel), r"page title(?: \(on webmail, the email's subject\))?, cleaned of any address and unread count", rel)

    def test_cloud_page_titles_match_code(self):
        # fix/bugs7: cloud summaries read browser pages and website typing with the page title cleaned (NoteAudience.cloudView,
        # fix/day-card owner decision 9/28). Every doc says so; none says the cloud never gets the page title.
        self.assertIn("v.title=title", read("Sources/MemoryCore/DerivedNotes.swift"))
        self.assertIn("NoteAudience.cloudTitle(action)", read("adapters/CoreWriterBinding.swift"))
        for rel in ["PRIVACY.md", "README.md", "docs/privacy-model.md", "docs/browser-capture.md"]:
            text = read(rel)
            self.assertNotIn("never the page title", text, rel)
            self.assertRegex(text, r"the site,? (?:and )?the page title(?: \(on webmail, the email's subject\))?, cleaned of any address and unread count", rel)

    def test_on_this_mac_ships_inside(self):
        # writer/v1 (owner decision 2026-09-26): every release carries the runtime; the model downloads on request.
        # A test build staged without the runtime still refuses, with the runtime (not the model) named as missing.
        writer = read("Sources/MacMemApp/WriterIntegration.swift")
        self.assertIn("guard localOffered else", writer)
        self.assertIn("status=DaydreamSetupText.localUnavailable", writer)
        unavailable = swift_constant("Sources/MemoryUI/OnboardingScreens.swift", r'static let localUnavailable = "([^"]+)"')
        self.assertTrue(unavailable.startswith("Not in this version.") and "model" not in unavailable, unavailable)
        self.assertNotIn("not in the download", self.text)
        self.assertIn("ships **inside the app**", self.text)
        plan = read("WriterBackend/Sources/WriterBackend/ManagedInstaller.swift")
        recommended = re.search(r"static let recommended.*", plan).group(0)
        size = int(re.search(r"bytes:(\d[\d_]*),sha256", recommended).group(1).replace("_", ""))
        memory = int(re.search(r"minimumMemory:(\d[\d_]*)", recommended).group(1).replace("_", ""))
        self.assertIn(f"{size:,} bytes", self.text)
        self.assertEqual(memory, 8 << 30)
        self.assertIn("at least 8 GB of memory", self.text)
        host = re.search(r'target\.host == "([^"]+)"', read("WriterBackend/Sources/WriterBackend/AssetDownload.swift")).group(1)
        self.assertIn(f"`{host}`", self.text)
        self.assertIn(f"`{host}`", read("README.md"))
        # The one line Settings shows when the saved certificate status has run out, quoted exactly.
        line = swift_constant("Sources/MacMemApp/WriterIntegration.swift", r'static let appleCheckLine="([^"]+)"')
        self.assertIn(f'"{line}"', self.text)
        # fix/sx-all round 1: a download you started resumes after a quit (and may then ask Apple): never "never by itself".
        self.assertIn("finish a model download you started before quitting", self.text)
        runtime = read("scripts/writer_payload.py")
        distribution = re.search(r"^ID = '([^']+)'", runtime, re.M).group(1)
        self.assertIn(distribution, read("RELEASE.md"))
        self.assertIn("writer runtime not signed yet", read("RELEASE.md"))
        self.assertIn("writer runtime not signed yet", runtime)
        self.assertIn("Contents/Frameworks/WriterRuntime/", read("THIRD-PARTY-NOTICES.md"))
        self.assertNotIn("The runtime libraries are not bundled", read("THIRD-PARTY-NOTICES.md"))
        for rel in ["README.md", "PRIVACY.md", "docs/privacy-model.md", "docs/faq.md", "RELEASE.md", "THIRD-PARTY-NOTICES.md"]:
            low = read(rel).lower()
            for stale in ["not in the download", "aren't offered in the download", "doesn't offer summaries on this mac",
                          "no local writer or typesense in public builds", "which the download doesn't offer",
                          "typesense stays out of public builds", "do not include node.js or typesense"]:
                self.assertNotIn(stale, low, f"{rel}: {stale!r}")


class ReviewFixes(unittest.TestCase):
    """sat/v1 review: claims that were true of older builds, pinned to this one."""

    def test_summary_limits_in_readme(self):
        readme = read("README.md")
        limits = readme.split("## Known limits", 1)[1].split("\n## ", 1)[0]
        local = re.search(r"maxActions = (\d+)", read("WriterBackend/Sources/WriterBackend/ModelView.swift")).group(1)
        self.assertIn(f"A note covers at most {local} recorded actions", limits)
        self.assertNotIn("100 recorded actions", readme)
        self.assertNotIn("quitting DayDream turns them off", readme)
        self.assertNotIn("each moment and each day", readme)

    def test_search_never_promises_typed_text(self):
        self.assertIn("Typed bodies and generated notes never match.", read("Sources/MemoryCore/MemorySearch.swift"))
        readme = read("README.md")
        self.assertNotIn("window title, site or text", readme)
        self.assertNotIn("Typed text isn't searchable", readme)
        self.assertIn("typed words are searched on this Mac only, while they're kept", readme)

    def test_cloud_notice_names_corrections(self):
        self.assertIn("User correction to related note", read("adapters/CoreWriterBinding.swift"))
        self.assertIn("corrections you write to notes", read("WriterBackend/Sources/WriterBackend/CloudActivation.swift"))
        for rel in ["README.md", "PRIVACY.md", "docs/faq.md", "docs/privacy-model.md", "docs/summaries.md"]:
            self.assertRegex(read(rel), r"[Cc]orrections you wr(ote|ite) to (a )?notes?", rel)

    def test_saved_note_status_is_quoted_from_code(self):
        status = re.search(r'status=mode=="cloud" \? "([^"]+)"', read("Sources/MacMemApp/WriterIntegration.swift")).group(1)
        text = read("docs/summaries.md")
        self.assertIn(status, text)
        self.assertNotIn("Processed Using ZDR Endpoints", text)

    def test_notification_prompt_is_documented(self):
        self.assertIn("requestAuthorization", read("Sources/MacMemApp/WakeSystem.swift"))
        wake = read("Sources/MacMemApp/WakeResume.swift")
        self.assertIn("static func resumeFailed(", wake)
        self.assertIn("static func timedPauseEnded(", wake)
        for rel in ["README.md", "docs/install.md"]:
            self.assertIn("may show notifications", read(rel), rel)
            # Notices also follow an unlock, a user switch and a timed pause ending, not only sleep.
            self.assertIn("only to tell you when recording stopped, or didn't start again, without you asking", read(rel), rel)
            self.assertNotIn("didn't start again after sleep", read(rel), rel)

    def test_uninstall_names_every_history_marker(self):
        markers = re.search(r'historyMarkers = \[([^\]]+)\]', read("Sources/MemoryCore/Uninstall.swift")).group(1)
        names = re.findall(r'"([^"]+)"', markers)
        self.assertTrue(names)
        row = next(line for line in read("docs/uninstall.md").splitlines() if "Application Support/Daydream`" in line)
        for name in names:
            self.assertIn("`" + name + "`", row)

    def test_install_matches_permission_buttons(self):
        install = read("docs/install.md")
        setup = read("Sources/MemoryUI/PermissionSetup.swift")
        # DayDream never shows a macOS prompt: each card opens its pane, or is dragged into its list.
        self.assertNotIn("Allow…", setup)
        permissions = install[install.index("## 4. Turn on the two permissions"):install.index("## 5.")]
        self.assertNotIn("Allow…", permissions)
        self.assertIn('Text("Open System Settings")', setup)
        self.assertIn("press **Open System Settings**", install)
        self.assertIn("It never shows a macOS prompt for them", install)
        self.assertIn("drag its card from the setup window into the list", install)
        self.assertIn(".onDrag {", setup)
        self.assertIn('quitAndReopenTitle = "Quit & Reopen"', setup)
        self.assertIn("**Quit & Reopen**", install)
        # The picture's alt text says what the missing cards show now (ux/perms: no Allow… button).
        self.assertIn("each with an Open System Settings button", install)
        self.assertNotIn("press **Set up later**", install)
        self.assertIn("~/Applications", install)
        render = read("scripts/docs-install-render.swift")
        self.assertIn(".environment(\\.daydreamPermissionRequests", render)

    def test_ai_app_backups_are_documented(self):
        self.assertIn('backupSuffix = ".daydream-backup"', read("Sources/MemoryCore/AIAppConnect.swift"))
        for rel in ["README.md", "docs/uninstall.md"]:
            self.assertIn(".daydream-backup", read(rel), rel)

    def test_release_documents_a_build_without_updates(self):
        self.assertIn("--expect-developer-id --updates off", read("RELEASE.md"))


class TypesenseClaims(unittest.TestCase):
    """ship-1004 (owner decision 2026-10-03, "Ship typesense."): every build bundles Typesense under GPL-3.0, and the
    notices, runbook and in-app notice say so and name the one source kit scripts/search_payload.py records."""

    def setUp(self):
        import json, sys
        sys.path.insert(0, str(ROOT / "scripts"))
        import search_payload
        self.s = search_payload
        self.record = json.loads(read(search_payload.SOURCE_DIR + "/local-typesense-v30.2.json"))

    def test_record_is_public_with_complete_source(self):
        self.assertTrue(self.s.public_cleared(self.record))
        self.assertEqual(self.record["correspondingSource"]["sha256"], self.s.SOURCE_KIT_SHA256)

    def test_notices_name_typesense_and_the_kit(self):
        notices = read("THIRD-PARTY-NOTICES.md")
        self.assertIn("## Typesense (GPL-3.0)", notices)
        for claim in [self.s.SOURCE_KIT_NAME, self.s.SOURCE_KIT_SHA256, self.s.SOURCE_COMMIT, self.s.ARCHIVE_SHA256,
                      "Contents/Helpers/typesense-server", "Contents/Resources/Typesense-LICENSE.txt",
                      "Contents/Resources/Typesense-NOTICES.txt", "WITHOUT ANY WARRANTY", "unmodified",
                      "https://github.com/%s/releases" % REPO, "best-determined commit"]:
            self.assertIn(claim, notices, claim)
        self.assertNotIn("do not include Node.js or Typesense", notices)
        self.assertEqual(self.s.notice_problems(read(self.s.SOURCE_DIR + "/Typesense-NOTICES.txt")), [])
        self.assertIn("https://github.com/%s/releases" % REPO, read(self.s.SOURCE_DIR + "/Typesense-NOTICES.txt"))

    def test_runbook_stages_and_attaches_the_kit(self):
        runbook = read("RELEASE.md")
        self.assertIn('--typesense-inputs "$TS_INPUTS" --typesense-source-kit "$TS_KIT"', runbook)
        self.assertIn("### Typesense", runbook)
        self.assertIn(self.s.SOURCE_KIT_SHA256, runbook)
        self.assertIn("`%s` and `%s.sha256`" % (self.s.SOURCE_KIT_NAME, self.s.SOURCE_KIT_NAME), runbook)
        limits = runbook.split("## 7. Known limits", 1)[1]
        self.assertIn("**Every release carries Typesense**", limits)
        self.assertNotIn("Typesense stays out of public builds", runbook)
        # The flag the runbook names is the one the stage takes.
        self.assertIn("'--typesense-source-kit'", read("scripts/developer-id-release.py"))


class DaydreamLicense(unittest.TestCase):
    """license-1005 (owner decision, "MIT."): DayDream's own code is MIT. Third-party components keep their own
    licenses: Typesense stays GPL-3.0, Qwen stays Apache-2.0, and the credits still name every one of them."""

    SAYS_DAYDREAM_LICENSE = ["README.md", "NOTICE", "TRADEMARKS.md", "CONTRIBUTING.md", "docs/faq.md",
                             "THIRD-PARTY-NOTICES.md", "packaging/Info.plist", "packaging/Welcome.html"]

    def test_license_is_the_standard_mit_text(self):
        text = read("LICENSE")
        self.assertTrue(text.startswith("MIT License\n\nCopyright (c) 2026 The DayDream Authors\n\n"), text[:80])
        for clause in ["Permission is hereby granted, free of charge, to any person obtaining a copy",
                       "The above copyright notice and this permission notice shall be included in all",
                       'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND']:
            self.assertIn(clause, text)
        self.assertNotIn("Apache", text)

    def test_daydream_is_never_called_apache(self):
        for rel in self.SAYS_DAYDREAM_LICENSE:
            text = read(rel)
            self.assertIn("MIT License", text, rel)
            for bad in ["DayDream is licensed under the Apache", "source code is licensed under the Apache",
                        "licensed under the [Apache", "under the Apache License 2.0. You can read it",
                        "Apache License 2.0.</string>", "This product is licensed under the Apache",
                        "derived code are licensed under Apache", "icon is not licensed under Apache",
                        "Contributions are licensed under the [Apache"]:
                self.assertNotIn(bad, text, rel)
        # Qwen's Apache text lives in its own notice now that LICENSE is MIT.
        self.assertNotIn("whose full\ntext is in this repository's `LICENSE` file", read("THIRD-PARTY-NOTICES.md"))
        self.assertTrue((ROOT / "WriterBackend/Notices/Qwen-APACHE-2.0.txt").is_file())

    def test_source_headers_say_mit(self):
        old = "Licensed under the Apache License,"
        for path in ROOT.rglob("*.swift"):
            if ".build" in path.parts or "Vendor" in path.parts:
                continue
            head = "\n".join(path.read_text(encoding="utf-8", errors="replace").splitlines()[:3])
            self.assertNotIn(old, head, path.relative_to(ROOT))
        self.assertTrue(read("Sources/HistoryCore/Event.swift").startswith(
            "// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;\n// see LICENSE.\n"))

    def test_third_parties_keep_their_licenses_and_credits(self):
        notices = read("THIRD-PARTY-NOTICES.md")
        for row in ["| [open-codex-computer-history]", "| MIT |", "| [Sparkle]", "| [llama.cpp / ggml]", "| [Qwen3.5-4B]",
                    "| Apache-2.0 |", "| [Typesense]", "| GPL-3.0 |", "## Typesense (GPL-3.0)", "## Qwen3.5-4B (Apache-2.0)"]:
            self.assertIn(row, notices, row)
        readme = read("README.md").split("## License, trademarks and credits", 1)[1]
        for name in ["open-codex-computer-history", "Sparkle", "llama.cpp", "Qwen", "Typesense"]:
            self.assertIn(name, readme, name)
        self.assertIn("**[Typesense](https://github.com/typesense/typesense)** (GPL-3.0)", readme)
        self.assertIn("GNU General Public License, version 3, not the MIT License", " ".join(read("NOTICE").split()))
        self.assertIn("Typesense under the GNU GPL version 3", read("packaging/Welcome.html"))
        for rel in self.SAYS_DAYDREAM_LICENSE:
            flat = " ".join(read(rel).split())
            self.assertIsNone(re.search(r"Typesense[^.|]{0,60}\(MIT\)|Typesense[^.|]{0,40}is licensed under the MIT", flat), rel)
        self.assertIn("GNU GENERAL PUBLIC LICENSE", read("packaging/TypesenseRuntime/Typesense-LICENSE.txt"))
        self.assertIn("version 3", read("packaging/TypesenseRuntime/Typesense-NOTICES.txt"))
        self.assertIn("Apache License", read("WriterBackend/Notices/Qwen-APACHE-2.0.txt"))
        self.assertIn("MIT License", read("WriterBackend/Notices/llama-MIT.txt"))


class PublicTypingReview(unittest.TestCase):
    """public-typing/v1 review: typing claims the full-typing release can't back, pinned to what it does."""

    def limits(self):
        return read("README.md").split("## Known limits", 1)[1].split("\n## ", 1)[0]

    def test_no_flat_cloud_claim_about_typing(self):
        # Window titles (a Mail subject, a shell command) can hold typed words and are sent to cloud summaries
        # like any title, so the promise is about the words DayDream saves, as the app's PrivacyPromise says.
        for rel in OWNED + ["docs/browser-capture.md"]:
            self.assertNotIn("what you type is never sent", read(rel).lower(), rel)
        # summaries/v3 (owner 2026-09-27, decision 8 reversed): cloud summaries, if chosen, get the words you type. No page
        # may still promise they never do.
        for rel in ["README.md", "PRIVACY.md", "docs/faq.md", "docs/install.md"]:
            text = read(rel)
            self.assertIn("Window titles can include words you typed", text, rel)
            self.assertNotIn("from your typing are never sent to cloud summaries", text, rel)
            self.assertNotIn("never the words DayDream saves from your typing)", text, rel)
            self.assertRegex(text, r"[Cc]loud summaries, if you choose them, get the words|[Ii]f you choose cloud summaries, they get the words|if you chose cloud summaries, sent to the summary service", rel)
        self.assertIn("Cloud summaries get window titles, page titles and the words you type.", read("Sources/MemoryUI/SettingsHub.swift"))

    def test_ssh_rule_lasts_until_the_focus_changes(self):
        # TerminalPromptLatch.focusChanged ends a remote session's rule; the docs say so.
        self.assertIn("arm = nil; remote = false", read("PrivacyPolicy/Sources/PrivacyPolicy/TerminalPromptLatch.swift"))
        for rel in OWNED + ["docs/browser-capture.md"]:
            self.assertNotRegex(read(rel), r"[Rr]emote sessions over `?ssh`? aren't recorded", rel)
        self.assertIn("If you come back to the remote session, what you type there can be recorded.", read("README.md"))
        self.assertIn("if you come back to the remote session, what you type there can be recorded", read("docs/privacy-model.md"))
        self.assertIn("can't always tell when a terminal is asking for a password", self.limits())

    def test_ai_chat_incognito_limit_is_said_before_settings(self):
        self.assertIn("incognito or temporary chat", self.limits())
        for rel in ["PRIVACY.md", "docs/faq.md"]:
            self.assertIn("can't tell when Claude or ChatGPT is in an incognito or temporary chat", read(rel), rel)

    def test_no_stale_typing_defaults(self):
        # fix/sx-all round 2: typing and every category, Messages and email too, are on unless the person turns them off
        # (setup shows the switches on; `SetupChoices.categorySeed`), so no page may say one is off by default.
        seed = read("Sources/MemoryCore/SetupChoices.swift")
        self.assertIn("messagesAndEmail != .off", seed)
        pages = ["README.md", "PRIVACY.md", "PrivacyPolicy/README.md"] + sorted(str(p.relative_to(ROOT)) for p in (ROOT / "docs").glob("*.md"))
        for rel in pages:
            low = read(rel).lower()
            for phrase in ["messages and email is off", "messages and email, off", "off unless you turn it on",
                           'after you confirm the "remember what you type" screen', "off until you turn on typed text"]:
                self.assertNotIn(phrase, low, f"{rel}: {phrase!r}")

    def test_site_only_line_matches_settings(self):
        # fix/sx-all round 2: the Settings bullet the release build shows (owner typing) is what README and PRIVACY say.
        line = re.search(r'#if DAYDREAM_OWNER_TYPING.*?siteOnlyLine = "([^"]+)"', read("Sources/MemoryUI/ChromePagesSettings.swift"), re.S).group(1)
        self.assertIn("webmail keeps the open email's subject", line)
        for rel in ["README.md", "PRIVACY.md", "docs/browser-capture.md"]:
            self.assertIn(line.rstrip("."), read(rel), rel)

    def test_social_chat_sites_count_as_messages(self):
        join = read("Sources/MemoryCore/BrowserTypingJoin.swift")
        hosts = ast.literal_eval("{" + re.search(r"socialChatHosts: Set<String> = \[([^\]]*)\]", join).group(1) + "}")
        self.assertTrue({"facebook.com", "linkedin.com", "x.com"} <= hosts)
        self.assertIn("social sites with chat, like Facebook and LinkedIn", read("README.md"))
        self.assertIn("social sites with chat, like Facebook, LinkedIn and X", read("PRIVACY.md"))
        self.assertIn("social sites with chat, like Facebook and LinkedIn", read("Sources/MemoryUI/TypingSettings.swift"))

    def test_faq_keylogger_answer_is_not_a_flat_no(self):
        # Once typed text is on, DayDream saves what you type in terminals, AI apps and every non-blocked
        # website, so the answer can't open with a flat "No" (the owner's fact sheet forbids "no keylogging").
        answer = read("docs/faq.md").split("## Is this a keylogger?", 1)[1].split("\n## ", 1)[0].strip()
        self.assertFalse(answer.startswith("No"), answer[:80])
        self.assertTrue(answer.startswith("Only while typed text is on."), answer[:80])

    def test_typing_off_advice_is_not_the_timed_pause(self):
        # The only typing pause lasts 10 minutes (TypingPauseShortcut.minutes), then typing resumes on its own.
        self.assertIn("static let minutes = 10", read("Sources/MemoryCore/TypingIndicator.swift"))
        readme = read("README.md")
        line = next(l for l in readme.splitlines() if "Anyone typing on this Mac account while it's on is recorded as you." in l)
        self.assertIn("Turn typed text off while they use it", line)
        self.assertIn("The typing pause lasts only 10 minutes.", line)
        for rel in OWNED:
            self.assertNotIn("or pause typing, before you use one", read(rel), rel)

    def test_input_methods_are_refused_everywhere(self):
        # Review G71: website typing refuses input methods too (WebTypingRoute.join needs the US, ABC or British layout),
        # so no doc says website words are built from keys under an input method, or limits the refusal to apps.
        self.assertIn("return .denied(.inputMethod)", read("Sources/MacMemApp/WebTypingRoute.swift"))
        for rel in OWNED + ["docs/browser-capture.md"]:
            text = read(rel)
            self.assertNotIn("no keyboard-layout check", text, rel)
            self.assertNotIn("saved words can differ", text, rel)
            for m in re.finditer(r"input methods[^.]*(?:aren't|are not) (?:captured|recorded)[^.]*\.", text):
                sentence = text[text.rfind(".", 0, m.start()) + 1:m.end()]
                self.assertFalse(sentence.lower().rstrip(". ").endswith("in apps"), f"{rel}: {sentence.strip()}")
        self.assertIn("It works only with the US, ABC or British keyboard layout, and input methods (such as Chinese or Japanese input) aren't captured.", read("README.md"))


DRAFTS = Path(os.environ.get("DAYDREAM_DRAFTS", "") or "/nonexistent-daydream-drafts")


@unittest.skipUnless(DRAFTS.is_dir(), "DAYDREAM_DRAFTS names no drafts folder")
class Drafts(unittest.TestCase):
    competitors = ["Rewind", "Limitless", "Screenpipe", "Microsoft Recall", "Windows Recall", "RescueTime",
                   "Timing app", "Claude", "ChatGPT", "Codex", "Cursor", "Anthropic", "OpenAI", "Copilot", "Gemini"]

    def files(self):
        found = sorted(DRAFTS.glob("*.md"))
        self.assertTrue(found)
        return found

    def test_marked_as_drafts(self):
        for path in self.files():
            self.assertTrue(path.read_text(encoding="utf-8").startswith("DRAFT, for the owner to rewrite\n"), path.name)

    def test_demo_label(self):
        for path in self.files():
            text = path.read_text(encoding="utf-8")
            if re.search(r"(?i)\bdemo\b", text):
                self.assertIn("Demo sped up, sample data", text, path.name)

    def test_no_competitor_names(self):
        for path in self.files():
            text = path.read_text(encoding="utf-8")
            for name in self.competitors:
                self.assertIsNone(re.search(rf"\b{re.escape(name)}\b", text), f"{path.name}: {name}")

    def test_no_everything_local_claims(self):
        # fact-sheet.md: "Nothing leaves your Mac" is on the list of things not to say; so is any rewording.
        for path in self.files():
            if path.name == "fact-sheet.md":
                continue
            low = path.read_text(encoding="utf-8").lower()
            for phrase in ["keeps everything local", "everything stays local", "nothing leaves your mac", "stays on your mac"]:
                self.assertNotIn(phrase, low, f"{path.name}: {phrase!r}")

    def test_fact_sheet_facts(self):
        text = (DRAFTS / "fact-sheet.md").read_text(encoding="utf-8")
        for needle in ["Summaries on the Mac or in the cloud", "Typed text is off by default", "Other known browsers aren't recorded",
                       "Chrome pages are off by default", "Signed and notarized", "Not encrypted", "MIT License",
                       f"github.com/{REPO}"]:
            self.assertIn(needle.lower(), text.lower(), needle)


if __name__ == "__main__":
    unittest.main()
