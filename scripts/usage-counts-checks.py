#!/usr/bin/env python3
"""Source checks for anonymous usage counts (Settings › Advanced › Share anonymous usage counts).

Run from anywhere: python3 scripts/usage-counts-checks.py -v

- Every event and property key is from the approved list, and the sender adds only the common keys.
- Every place the app records an event passes only that event's keys.
- `mac-mem mcp` (the MacMemCLI target, and the shared MemoryCore file it uses) has no networking: it only appends to
  the inbox file, and only when the file already exists.
- Test and development builds never send, nothing is sent without a project key, and only to PostHog's batch endpoint.
The runtime side is scripts/usage-counts-app-checks.swift. It reads files only.
"""
import re
import plistlib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COUNTS = ROOT / "Sources/MemoryCore/UsageCounts.swift"
SENDER = ROOT / "Sources/MacMemApp/UsageSender.swift"
REPORT = ROOT / "Sources/MacMemApp/UsageReport.swift"
CLI = ROOT / "Sources/MacMemCLI/main.swift"

# The approved design (owner, 2026-10-06). Changing what is sent means changing this list and the docs.
APPROVED = {
    "installed": {"macos_version", "chip"},
    "setup_step": {"step", "summaries", "ai_app"},
    "daily_check": {"recording", "accessibility_ok", "input_monitoring_ok", "hours_recorded_bucket", "summaries", "connected_ai_apps", "chrome_pages"},
    "ai_used": {"ai_app", "tool", "result_count", "empty", "latency_ms"},
    "app_opened": {"how"},
    "app_search": {"result_count"},
}
SUMMARY_MODES = {"local", "openrouter"}
COMMON = {"$geoip_disable", "$ip", "$lib", "app_version"}
# Raw sockets too (a bare `connect(`/`socket(`; `AIAppConnect.connect(` edits a settings file and is not one).
NETWORK = re.compile(r"URLSession|URLRequest|NSURLConnection|import\s+Network|NWConnection|CFStream|CFSocket|(?<![\w.])socket\(|(?<![\w.])connect\(|posthog|https?://")


def read(path):
    return path.read_text(encoding="utf-8")


def swift_set(text, name):
    m = re.search(rf"static let {re.escape(name)}: Set<String> = \[([^\]]*)\]", text)
    assert m, name
    return set(re.findall(r'"([^"]+)"', m.group(1)))


def swift_list(text, name):
    m = re.search(rf"static let {re.escape(name)} = \[([^\]]*)\]", text)
    assert m, name
    return re.findall(r'"([^"]+)"', m.group(1))


class Vocabulary(unittest.TestCase):
    text = read(COUNTS)

    def keys(self):
        block = self.text.split("public static let keys: [String: Set<String>] = [", 1)[1].split("\n    ]", 1)[0]
        out = {}
        for event, body in re.findall(r'"(\w+)": ([^\n]*?),?(?:\n|$)', block):
            out[event] = set(re.findall(r'"([^"]+)"', body)) if body.startswith("[") else body
        return out

    def test_events_and_keys_are_the_approved_ones(self):
        keys = self.keys()
        self.assertEqual(swift_set(self.text, "events"), set(APPROVED) | {"summaries_result"})
        for event, allowed in APPROVED.items():
            self.assertEqual(keys[event], allowed, event)
        self.assertEqual(keys["summaries_result"], 'summaryKeys.union(["problem"])')
        self.assertEqual(swift_set(self.text, "commonKeys"), COMMON)

    def test_summary_counts_are_counts_by_mode(self):
        self.assertEqual(set(swift_list(self.text, "summaryModes")), SUMMARY_MODES)
        for outcome in swift_list(self.text, "summaryOutcomes"):
            self.assertRegex(outcome, r"^(ok|fallback|failed_[a-z]+)$")

    def test_text_values_are_fixed_words(self):
        self.assertEqual(swift_list(self.text, "aiApps"), ["claude", "claude_code", "cursor", "chatgpt", "windsurf", "other"])
        tools = set(swift_list(self.text, "tools"))
        self.assertTrue({"status", "context", "current_context", "search", "read", "open", "recall", "recap", "moment_details"} <= tools)
        # Every text property is checked against a word list (macos_version by its version-number shape).
        self.assertIn('guard words[key]?.contains(text) == true else { return false }', self.text)
        self.assertIn(r'^\d{1,3}(\.\d{1,3}){0,2}$', self.text)


class Sender(unittest.TestCase):
    text = read(SENDER)

    def test_only_common_keys_are_added(self):
        wire = self.text.split("static func wire(", 1)[1].split("\n    }", 1)[0]
        self.assertEqual(set(re.findall(r'properties\["([^"]+)"\] =', wire)), COMMON)
        self.assertIn('properties["$geoip_disable"] = true', wire)
        self.assertIn('properties["$ip"] = NSNull()', wire)
        self.assertIn('"distinct_id": id', wire)

    def test_everything_queued_is_checked(self):
        add = self.text.split("func add(_ events: [UsageEvent])", 1)[1].split("\n    }", 1)[0]
        self.assertIn("filter(UsageCounts.allowed)", add)
        self.assertIn("guard enabled", add)

    def test_one_endpoint_no_cookies_no_redirects(self):
        self.assertEqual(re.findall(r'https://[^"]+', self.text), ["https://us.i.posthog.com/batch/"])
        self.assertEqual(self.text.count("URLSession(configuration:"), 1)
        for needle in ["URLSessionConfiguration.ephemeral", "httpCookieStorage = nil", "urlCredentialStorage = nil", "urlCache = nil", "completionHandler(nil)"]:
            self.assertIn(needle, self.text)

    def test_development_and_check_builds_never_send(self):
        gate = self.text.split("static var buildMaySend: Bool {", 1)[1].split("\n    }", 1)[0]
        self.assertIn("#if DEBUG || DEVELOPMENT_SOURCE_CHECKS || DAYDREAM_QA_HARNESS || DAYDREAM_LIVETEST\n        return false", gate)
        self.assertIn("DaydreamIdentity.bundleID", gate)
        self.assertIn('"DaydreamDevelopmentTrial"', gate)
        send = self.text.split("    func send() {", 1)[1].split("\n    }", 1)[0]
        self.assertIn("guard enabled, Self.buildMaySend, !key.isEmpty, inFlight == nil, !pending.isEmpty else { return }", send)
        # The one request is made in send(), after that guard.
        self.assertLess(send.index("Self.buildMaySend"), send.index("dataTask"))
        self.assertEqual(self.text.count("dataTask("), 1)

    def test_project_key_is_in_info_plist(self):
        info = plistlib.loads((ROOT / "packaging/Info.plist").read_bytes())
        key = info.get("DDPostHogKey")
        self.assertIsInstance(key, str)
        self.assertTrue(key == "" or key.startswith("phc_"), "DDPostHogKey holds a PostHog project key or nothing")
        self.assertIn('forInfoDictionaryKey: "DDPostHogKey"', self.text)

    def test_off_drops_the_queue_and_the_inbox(self):
        off = self.text.split("func setEnabled(_ on: Bool) {", 1)[1].split("\n    }\n", 1)[0]
        for needle in ["inFlight?.cancel()", "pending = []", "UsageInbox.remove(home: home)"]:
            self.assertIn(needle, off)

    def test_install_id_is_random(self):
        ensure = self.text.split("func ensureInstallID()", 1)[1].split("\n    }", 1)[0]
        self.assertIn("UUID().uuidString", ensure)
        for name in ["hostName", "localizedName", "NSUserName", "NSFullUserName", "serial", "IOPlatform", "macAddress"]:
            self.assertNotIn(name, self.text)


class Recording(unittest.TestCase):
    def test_app_records_only_allowed_keys(self):
        sources = list((ROOT / "Sources/MacMemApp").glob("*.swift"))
        calls = 0
        for path in sources:
            text = read(path)
            for event, body in re.findall(r'record\("(\w+)",\s*(\[[^\]]*\]|properties|result)', text):
                calls += 1
                self.assertIn(event, APPROVED | {"summaries_result": set()}, f"{path.name}: {event}")
                if body.startswith("["):
                    self.assertLessEqual(set(re.findall(r'"(\w+)": \.', body)), APPROVED[event], f"{path.name}: {event}")
            for step, body in re.findall(r'setupStep\("(\w+)"(?:,\s*(\[[^\]]*\]))?\)', text):
                self.assertIn(step, {"accessibility_allowed", "input_monitoring_allowed", "summaries_chosen", "ai_connected", "setup_done"})
                self.assertLessEqual(set(re.findall(r'"(\w+)": \.', body or "")), APPROVED["setup_step"])
        self.assertGreaterEqual(calls, 4)
        report = read(REPORT)
        daily = report.split("static func dailyCheck(", 1)[1].split("\n    }\n", 1)[0]
        self.assertLessEqual(set(re.findall(r'"(\w+)": \.', daily)) | set(re.findall(r'properties\["(\w+)"\]', daily)), APPROVED["daily_check"])

    def test_search_hook_passes_a_number_only(self):
        browser = read(ROOT / "Sources/MemoryUI/ActivityModel.swift")
        self.assertIn("public var searched: ((Int) -> Void)?", browser)


class Helper(unittest.TestCase):
    def test_mcp_helper_has_no_networking(self):
        for path in [CLI, COUNTS]:
            hits = [m.group(0) for m in NETWORK.finditer(read(path))]
            self.assertEqual(hits, [], f"{path.name}: {hits}")

    def test_mcp_helper_target_does_not_link_the_app(self):
        package = read(ROOT / "Package.swift")
        cli = re.search(r'\.executableTarget\(name: "MacMemCLI", dependencies: \[([^\]]*)\]', package)
        self.assertIsNotNone(cli)
        self.assertEqual(re.findall(r'"(\w+)"', cli.group(1)), ["MemoryCore"])
        self.assertFalse((ROOT / "Sources/MemoryCore/UsageSender.swift").exists())

    def test_helper_writes_only_an_existing_inbox(self):
        text = read(COUNTS)
        append = text.split("public static func appendAIUse(", 1)[1].split("\n    }", 1)[0]
        self.assertIn("O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC", append)
        self.assertNotIn("O_CREAT", append)
        self.assertIn("maxBytes", append)
        self.assertIn("UsageCounts.allowed(event)", append)
        cli = read(CLI)
        self.assertEqual(cli.count("UsageInbox."), 1, "the helper's only usage call is appendAIUse")
        self.assertIn("UsageInbox.appendAIUse(", cli)
        # Only the tool name, a count and the time: never the arguments or the reply text.
        record = cli.split("enum MCPUsage {", 1)[1].split("\n}\n", 1)[0]
        self.assertNotIn("input", record)
        self.assertNotIn("body", record)


if __name__ == "__main__":
    unittest.main()
