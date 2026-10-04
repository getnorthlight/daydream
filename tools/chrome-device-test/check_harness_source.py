#!/usr/bin/env python3
"""Source invariants for the Chrome device-test harness. Reads files only;
never runs the harness, Chrome, Apple Events or Accessibility.

Run: python3 tools/chrome-device-test/check_harness_source.py
"""
from pathlib import Path
import plistlib
import re
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SRC = HERE / "Sources"
CORE = SRC / "ChromeProbeCore"
LIVE = SRC / "ChromeDeviceTest"
SELF = SRC / "ChromeProbeSelfTest"
SERVE = SRC / "ChromeDeviceTestServe"
KIT = HERE / "kit"
# The app's private-build flag, spelled in two parts so this file never names it
# (scripts/check_browser_boundary.py lists every tracked file that does).
FLAG_NAME = "DAYDREAM_" + "CHROME_TYPING"


def text(folder):
    return {p: p.read_text() for p in sorted(folder.rglob("*.swift"))}


def code_only(s):
    """Swift source with // comments and string-free doc comments removed."""
    return re.sub(r"//[^\n]*", "", s)


ALL = {**text(CORE), **text(LIVE), **text(SELF), **text(SERVE)}
LIVE_SRC = text(LIVE)

# Accessibility attributes the harness may read (plan row 0: roles,
# AXWebArea/AXURL, focused element role/subrole, window geometry/title for the
# AE<->AX match, AXWindows for the window count (review I1), and deny-only
# label metadata behind --probe-labels, including the class list).
AX_ALLOWED = {
    "AXRole", "AXSubrole", "AXParent", "AXFocusedWindow", "AXFocusedUIElement", "AXFocusedApplication",
    "AXWindows", "AXPosition", "AXSize", "AXMinimized", "AXTitle", "AXURL",
    "AXDescription", "AXPlaceholderValue", "AXDOMIdentifier", "AXDOMClassList",
    "AXEditableAncestor",
}
# Four-char codes allowed in Apple Events: only core/getd, object-specifier
# plumbing, and the plan's property allowlist (mode, ID, pbnd, pnam, URL, acTa).
AE_CODES_ALLOWED = {
    "core", "getd", "want", "form", "seld", "from", "obj ", "cwin", "indx", "prop", "ID  ",
    "abso", "all ", "firs", "acTa", "----", "errn", "list", "qdrt", "tdta",
}
AE_PROPERTIES_ALLOWED = {"ID  ", "mode", "pbnd", "pnam", "URL "}

FORBIDDEN = [
    "kAXValueAttribute", '"AXValue"', "kAXSelectedText", "AXSelectedText", "AXStringForRange", "AXAttributedStringForRange",
    "AXEnhancedUserInterface", "AXManualAccessibility", "AXUIElementSetAttributeValue", "AXUIElementPerformAction",
    "AXUIElementCopyParameterizedAttributeValue", "AXUIElementCopyMultipleAttributeValues", "AXUIElementPostKeyboardEvent",
    "AXIsProcessTrustedWithOptions", "kAXTrustedCheckOptionPrompt",
    "CGEventTapCreate", "CGEvent.tapCreate", "addGlobalMonitorForEvents", "addLocalMonitorForEvents",
    "NSAppleScript", "osascript", "executeJavaScript", "CrSu", "NSUserAppleScriptTask",
    "NSWorkspace.shared.open", "openApplication", "launchApplication", "Process(", "NSTask",
    "NSAppleEventDescriptor(bundleIdentifier", "kCGWindowName", "NSPasteboard", "CGWindowListCreateImage",
    "SCShareableContent", "CGRequestScreenCaptureAccess", "CGRequestListenEventAccess",
]


class HarnessSource(unittest.TestCase):
    def test_not_part_of_the_app_build(self):
        root_pkg = (ROOT / "Package.swift").read_text()
        self.assertNotIn("chrome-device-test", root_pkg)
        self.assertNotIn("tools/", root_pkg)
        self.assertNotIn("ChromeProbeCore", root_pkg)
        for p in (ROOT / "Sources").rglob("*.swift"):
            self.assertNotIn("ChromeProbeCore", p.read_text(), p)

    def test_forbidden_apis_absent(self):
        for p, s in ALL.items():
            for word in FORBIDDEN:
                self.assertFalse(word in s, f"{word} found in {p.name}")

    def test_core_and_selftest_have_no_system_access(self):
        for folder, allowed in [(CORE, {"Foundation", "PrivacyPolicy"}), (SELF, {"Foundation", "ChromeProbeCore"})]:
            for p, s in text(folder).items():
                imports = set(re.findall(r"^import\s+(\w+)", s, re.M))
                self.assertLessEqual(imports, allowed, p.name)
                for word in ["AXUIElement", "NSAppleEventDescriptor", "AEDetermine", "CGWindowList", "IsSecureEventInputEnabled"]:
                    self.assertNotIn(word, code_only(s), f"{word} in {p.name}")

    def test_ax_attribute_allowlist(self):
        live = LIVE / "LiveAccessibility.swift"
        s = live.read_text()
        enum = s.split("enum AXAttr: String {", 1)[1].split("\n}", 1)[0]
        raw = set(re.findall(r'=\s*"(AX\w+)"', enum))
        self.assertTrue(raw)
        self.assertLessEqual(raw, AX_ALLOWED)
        # Exactly one attribute read call, and it only takes an AXAttr.
        all_live = "".join(LIVE_SRC.values())
        self.assertEqual(all_live.count("AXUIElementCopyAttributeValue("), 1)
        self.assertIn("AXUIElementCopyAttributeValue(element, attr.rawValue as CFString, &value)", s)
        # No kAX...Attribute constants anywhere in live code.
        self.assertEqual(re.findall(r"kAX\w+Attribute", code_only(all_live)), [])
        # Labels only through the optional closure, which is nil without --probe-labels.
        self.assertIn("fieldLabels: probeLabels ? { self.labels($0) } : nil", s)

    def test_apple_event_allowlist(self):
        s = (LIVE / "LiveAppleEvents.swift").read_text()
        codes = set(re.findall(r'code\("(.{4})"\)', s))
        self.assertLessEqual(codes, AE_CODES_ALLOWED, codes - AE_CODES_ALLOWED)
        self.assertEqual(s.count("NSAppleEventDescriptor(eventClass:"), 1)
        self.assertIn('NSAppleEventDescriptor(eventClass: code("core"), eventID: code("getd")', s)
        self.assertIn(".neverInteract", s)
        self.assertIn("processIdentifier: pid", s)
        model = (CORE / "Model.swift").read_text()
        props = set(re.findall(r'case\s+\w+\s*=\s*"(.{4})"', model.split("public enum AEProperty", 1)[1].split("\n}", 1)[0]))
        props |= set(re.findall(r'\w+\s*=\s*"(.{4})"', model.split("public enum AEProperty", 1)[1].split("public var label", 1)[0]))
        self.assertEqual(props, AE_PROPERTIES_ALLOWED)
        for p, src in LIVE_SRC.items():
            if p.name != "LiveAppleEvents.swift":
                self.assertNotIn("sendEvent(", src, p.name)

    def test_automation_prompt_only_with_flag(self):
        all_live = "".join(LIVE_SRC.values())
        self.assertEqual(all_live.count("AEDeterminePermissionToAutomateTarget("), 1)
        self.assertEqual(all_live.count("ask: true"), 1)
        self.assertEqual(all_live.count("requestAutomationPermission(pid: p.pid)"), 1)
        runner = (LIVE / "Runner.swift").read_text()
        before = runner.split("requestAutomationPermission(pid: p.pid)", 1)[0].splitlines()[-3:]
        self.assertTrue(any("if opts.requestPermission {" in line for line in before), before)
        # The request comes after the profile gate refuses a non-throwaway Chrome.
        self.assertLess(runner.index("guard p.profileOK, let app = apps.first else { return p }"),
                        runner.index("requestAutomationPermission(pid: p.pid)"))
        options = (CORE / "Options.swift").read_text()
        self.assertIn("public var requestPermission = false", options)
        self.assertEqual(options.count("o.requestPermission = true"), 1)
        self.assertIn('case "--request-permission": o.requestPermission = true', options)

    def test_strict_mode_before_any_content(self):
        s = (CORE / "Join.swift").read_text()
        run = s.split("public func run() -> JoinOutcome<Node> {", 1)[1].split("public func lightCheck", 1)[0]
        strict = run.index("if !nonNormal.isEmpty {")
        self.assertIn("r.verdict = .strictPause", run[strict:strict + 400])
        for marker in ["axRead(", ".activeTab(", "(.name)", ".name)", "ax.windowTitle", "ax.webAreaURL", "ax.focusedElement"]:
            if marker in run:
                self.assertLess(strict, run.index(marker), marker)
        mode = run.index(".mode)")
        self.assertLess(mode, strict)
        # Review I1: the AX window count, and the stop when a window is
        # unlisted, come before any title, address, tab or field read.
        count = run.index("ax.windows()")
        stop = run.index("r.stoppedBeforeContent = true")
        self.assertIn("audit.noteAXWindows(standard:", run[count:stop])
        self.assertIn("return finish()", run[stop:stop + 120])
        for marker in [".activeTab(", "(.name)", "ax.windowTitle", "ax.webAreaURL", "ax.focusedElement", "ax.fieldLabels", "read(element)"]:
            if marker in run:
                self.assertLess(stop, run.index(marker), marker)
        # Step 5 stops without further reads if the window list changed.
        self.assertIn("a new window may\n        // be Incognito, so no further Accessibility read is allowed.", run)

    def test_strict_step_needs_an_incognito_window(self):
        # incognito-background with no Incognito window open measured nothing
        # but graded A2 FAIL (ABANDON). The guard reads window IDs and modes
        # only, before any join, and marks the step not run.
        runner = (LIVE / "Runner.swift").read_text()
        body = runner.split("func stepJoins(_ spec: StepSpec, _ r: inout StepResult) {", 1)[1].split("\n    }\n", 1)[0]
        self.assertLess(body.index("if spec.kind == .strict {"), body.index("join.run()"))
        guard = code_only(body.split("if spec.kind == .strict {", 1)[1].split('if spec.id == "plain-input" {', 1)[0])
        self.assertIn("Steps.strictPrecondition(modes: base.ids.map { ae.send(.window(.id($0), .mode)).text ?? \"\" })", guard)
        self.assertIn("r.ran = false", guard)
        for marker in [".name", ".tabURL", ".activeTab", "ax.", "join.run", ".bounds", "readLine"]:
            self.assertNotIn(marker, guard, marker)
        steps = (CORE / "Steps.swift").read_text()
        pre = steps.split("public static func strictPrecondition(modes: [String]) -> String? {", 1)[1].split("\n    }\n", 1)[0]
        self.assertIn('guard modes.allSatisfy({ $0 == "normal" }) else { return nil }', pre)
        self.assertEqual([s for s in re.findall(r"kind: \.(\w+)", steps) if s == "strict"], ["strict"])

    def test_profile_gate_before_anything(self):
        main = (LIVE / "main.swift").read_text()
        self.assertLess(main.index("guard pre.profileOK else"), main.index("Session(opts, pre)"))
        runner = (LIVE / "Runner.swift").read_text()
        pre = runner.split("static func run(_ opts: Options) -> Preflight {", 1)[1].split("\n    }\n", 1)[0]
        gate = pre.index("guard p.profileOK, let app = apps.first else { return p }")
        for later in ["AXIsProcessTrusted()", "Automation.", "chromeSignatureOK"]:
            self.assertLess(gate, pre.index(later), later)

    def test_report_holds_no_names(self):
        s = (CORE / "Report.swift").read_text()
        self.assertIn("steps.map(RunReport.scrub)", s)
        self.assertIn('w.name = w.name.map { "(\\($0.count) characters)" }', s)

    def test_testpage_is_local_and_dummy(self):
        page = (HERE / "testpage" / "index.html").read_text()
        frame = (HERE / "testpage" / "frame.html").read_text()
        for html in (page, frame):
            for url in re.findall(r"https?://[^\s\"'<>]+", html):
                self.assertRegex(url, r"^http://(127\.0\.0\.1|localhost)")
            self.assertNotIn("<link", html)
            self.assertNotRegex(html, r"<script[^>]+src=")
        self.assertIn('value="dummy-not-a-real-password"', page)
        for needed in ['id="plain-input"', "<textarea", 'contenteditable="true"', 'type="password"', 'id="toggle-password"',
                       'autocomplete="cc-number"', 'autocomplete="one-time-code"', 'src="frame.html"', 'id="frame-cross"',
                       'class="xterm-helper-textarea"', 'id="ask-before-leaving"', "'beforeunload'",
                       'id="combo-search" type="text" role="combobox"', 'id="hidden-combo" type="password" role="combobox"']:
            self.assertIn(needed, page)
        serve = (HERE / "testpage" / "serve.py").read_text()
        self.assertIn('("127.0.0.1", PORT)', serve)
        self.assertIn('("::1", PORT)', serve)
        self.assertNotIn("0.0.0.0", serve)

    def test_reply_types_match_the_app(self):
        # Review C4: F9 grades reply types against the app's decoder, so the
        # harness's copy of the accepted types must be the app's.
        join = (ROOT / "Sources" / "MemoryCore" / "BrowserTypingJoin.swift").read_text()
        decode = join.split("public func decode(_ d: NSAppleEventDescriptor) -> ChromeJoinReply? {", 1)[1].split("\n    }\n", 1)[0]
        text_case = decode.split("case .mode, .name, .activeTabID, .tabURL:", 1)[1]
        app_text = set(re.findall(r'ChromeAppleEvents\.code\("(.{4})"\)', text_case.split("contains(d.descriptorType)", 1)[0]))
        bounds_init = join.split("public init?(descriptor d: NSAppleEventDescriptor) {", 1)[1].split("guard valid", 1)[0]
        app_bounds = set(re.findall(r'd\.descriptorType == ChromeAppleEvents\.code\("(.{4})"\)', bounds_init))
        model = (CORE / "Model.swift").read_text()
        table = model.split("public static let appAcceptedReplyTypes: [String: Set<String>] = [", 1)[1].split("\n    ]", 1)[0]
        harness = {k: set(re.findall(r'"(.{4})"', v)) for k, v in re.findall(r'"([\w-]+)":\s*\[([^\]]*)\]', table)}
        self.assertEqual(app_text, {"utxt", "TEXT"})
        self.assertEqual(app_bounds, {"qdrt", "list"})
        self.assertEqual(harness, {"mode": app_text, "name": app_text, "tab-id": app_text, "tab-url": app_text, "bounds": app_bounds})
        # The app's text decoding covers exactly these four requests.
        self.assertIn("case .mode, .name, .activeTabID, .tabURL:", decode)

    def test_package_has_exactly_three_products(self):
        pkg = (HERE / "Package.swift").read_text()
        products = re.findall(r'\.executable\(name: "([\w-]+)", targets: \["(\w+)"\]\)', pkg)
        self.assertEqual(sorted(products), [("chrome-device-test", "ChromeDeviceTest"),
                                            ("chrome-device-test-selftest", "ChromeProbeSelfTest"),
                                            ("chrome-device-test-serve", "ChromeDeviceTestServe")])
        self.assertEqual(len(re.findall(r"\.(executable|library)\(", pkg)), 3)
        # The server links only the pure core, never the code that talks to Chrome.
        self.assertIn('.executableTarget(name: "ChromeDeviceTestServe", dependencies: ["ChromeProbeCore"])', pkg)
        self.assertEqual(sorted(p.name for p in SRC.iterdir() if p.is_dir()),
                         ["ChromeDeviceTest", "ChromeDeviceTestServe", "ChromeProbeCore", "ChromeProbeSelfTest"])

    def test_serve_is_loopback_only(self):
        files = text(SERVE)
        self.assertEqual([p.name for p in files], ["main.swift"])
        s = files[SERVE / "main.swift"]
        code = code_only(s)
        self.assertLessEqual(set(re.findall(r"^import\s+(\w+)", s, re.M)), {"Foundation", "Darwin", "ChromeProbeCore"})
        # No Apple Events, no Accessibility (not even the trust check), no
        # other app, no other program, no wildcard address.
        for word in ["AXUIElement", "AXIsProcessTrusted", "kAXTrusted", "NSAppleEventDescriptor", "AEDetermine", "AESend",
                     "sendEvent(", "CGWindowList", "IsSecureEventInputEnabled", "NSWorkspace", "NSRunningApplication",
                     "NSApplication", "NSSound", "INADDR_ANY", "in6addr_any", "0.0.0.0", '"::"', "SO_REUSEPORT",
                     "NWListener", "import Network", "posix_spawn", "execv", "fork(", "popen(", "system("]:
            self.assertNotIn(word, code, word)
        # Exactly two listeners, bound to 127.0.0.1 and ::1 and nothing else.
        self.assertEqual(len(re.findall(r"\bbind\(", code)), 2)
        self.assertIn("withSockaddr(loopbackV4(port), { Darwin.bind(fd, $0, $1) })", code)
        self.assertIn("withSockaddr(loopbackV6(port), { Darwin.bind(fd, $0, $1) })", code)
        self.assertEqual(re.findall(r'inet_pton\((\w+), "([^"]*)"', code), [("AF_INET", "127.0.0.1"), ("AF_INET6", "::1")])
        self.assertEqual(code.count("inet_pton("), 2)
        self.assertEqual(len(re.findall(r"\.sin6?_addr\b", code)), 2)
        self.assertIn("setOption(fd, IPPROTO_IPV6, IPV6_V6ONLY, 1)", code)
        # A closed tab or an idle connection cannot stop or stall it.
        self.assertIn("signal(SIGPIPE, SIG_IGN)", code)
        self.assertIn("SO_RCVTIMEO", code)
        self.assertIn("Thread { serve(c) }", code)
        # Replies come only from TestPage; one file open, never through a symlink.
        self.assertIn("TestPage.respond(", code)
        self.assertIn("writeAll(c, TestPage.serialize(reply))", code)
        self.assertEqual(len(re.findall(r"\bopen\(", code)), 1)
        self.assertIn('open(root + "/" + name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)', code)

    def test_test_page_rules_are_pure_and_strict(self):
        s = (CORE / "TestPage.swift").read_text()
        code = code_only(s)
        for word in ["socket(", "bind(", "open(", "FileManager", "contentsOf", "fopen", "import Darwin", "Process"]:
            self.assertNotIn(word, code, word)
        self.assertIn("public static let port: UInt16 = 8765", code)
        # Every reply that has a head says no-store, from the one serializer.
        self.assertEqual(code.count("func serialize("), 1)
        self.assertIn('head += "Cache-Control: no-store\\r\\n\\r\\n"', code)
        # One path component inside the page folder, never a dotfile.
        self.assertIn("guard stack.count == 1, !trailingSlash else { return nil }", code)
        self.assertIn('guard !name.hasPrefix(".")', code)
        selftest = (SELF / "main.swift").read_text()
        for needed in ['"traversal attempt is 404"', '"traversal attempt only looks inside the page folder"',
                       '"no path ever names anything outside the page folder"', '"Cache-Control: no-store on',
                       '"POST is 501"', '"GET / serves index.html"', '"HEAD /: headers, no body"']:
            self.assertIn(needed, selftest)

    def test_access_command_is_read_only(self):
        # `chrome-device-test access` (kit step 2) only asks macOS whether the
        # app running it has Accessibility: no prompt, no Chrome, no Apple Event.
        all_live = code_only("".join(LIVE_SRC.values()))
        self.assertEqual(all_live.count("AXIsProcessTrusted()"), 2)
        main = (LIVE / "main.swift").read_text()
        self.assertEqual(main.count("case .access:"), 1)
        block = code_only(main.split("case .access:", 1)[1].split("default:", 1)[0])
        self.assertIn("AXIsProcessTrusted()", block)
        for word in ["Preflight", "Session", "System.", "LiveAX", "Automation", "NSApplication", "NSApp", "requestPermission",
                     "AEDetermine", "sendEvent", "AXUIElement", "Chrome", "chrome"]:
            self.assertNotIn(word, block, word)
        self.assertLess(main.index("case .access:"), main.index("_ = NSApplication.shared"))
        options = (CORE / "Options.swift").read_text()
        self.assertIn("case preflight, windows, join, focus, run, steps, access, help", options)

    def test_kit_run_script(self):
        s = (KIT / "run.sh").read_text()
        lines = s.splitlines()
        self.assertEqual(lines[0], "#!/bin/bash")
        self.assertIn('[ -n "${BASH_VERSION:-}" ] || exec /bin/bash "$0" "$@"', s)
        self.assertIn("\nPATH=/usr/bin:/bin:/usr/sbin:/sbin\n", s)
        code_lines = [l for l in lines if not l.lstrip().startswith("#")]
        code = "\n".join(code_lines)
        # It refuses root (and sudo) before doing anything else: as root every
        # "is it running?" check would miss the owner's own Chrome and DayDream.
        head = [l for l in code_lines if l.strip()][:7]
        self.assertEqual(head[:5], ['[ -n "${BASH_VERSION:-}" ] || exec /bin/bash "$0" "$@"', "set -u",
                                    "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "export PATH", "umask 077"])
        self.assertEqual(head[5], 'if [ "$(id -u)" = 0 ] || [ -n "${SUDO_USER:-}" ]; then')
        guard = code.split(head[5], 1)[1].split("\nfi\n", 1)[0]
        self.assertIn("exit 1", guard)
        # The Chrome version it warns about is the harness's own (F8).
        model = (CORE / "Model.swift").read_text()
        self.assertEqual(re.search(r"^MIN_CHROME=(\d+)$", s, re.M).group(1),
                         re.search(r"public static let minimumChromeMajor = (\d+)", model).group(1))
        # macOS's own /bin/bash 3.2.
        for bashism in ["declare -A", "mapfile", "readarray", ",,}", "^^}", "&>>", "|&", "coproc", "local -n", "wait -n",
                        "EPOCHSECONDS", "globstar", "${BASH_REMATCH"]:
            self.assertNotIn(bashism, code, bashism)
        # No developer tools, network, privilege, app scripting or remote debugging.
        for pattern in [r"\bpython", r"\bswift\b", r"\bxcrun\b", r"\bgit\b", r"\bbrew\b", r"\bsudo\b", r"\bcurl\b",
                        r"\bwget\b", r"\bnc\b", r"osascript", r"\bpkill\b", r"\bkillall\b", r"remote-debugging",
                        r"AXIsProcessTrustedWithOptions", r"defaults write", r"\blaunchctl\b", r"tccutil reset (Accessibility|All)",
                        r"Library/Application Support/Google", FLAG_NAME]:
            self.assertIsNone(re.search(pattern, code), pattern)
        # The steps it passes to --only are the harness's own.
        ids = re.findall(r'StepSpec\(id: "([\w-]+)"', (CORE / "Steps.swift").read_text())
        self.assertEqual(re.search(r'^STEP_IDS="([^"]*)"', s, re.M).group(1).split(), ids)
        # The only Chrome launch is README step 4's, on the throwaway profile.
        cmd = r'(?:^|[;&|()!]|\bif\b|\bthen\b|\bdo\b|\belse\b)\s*'
        opens = re.findall(cmd + r"open\s+(.*)", code, re.M)
        allowed = ['"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" ;;',
                   '"x-apple.systempreferences:com.apple.preference.security?Privacy_Automation" ;;',
                   '-na "Google Chrome" --args --user-data-dir="$PROFILE" --no-first-run --no-default-browser-check http://127.0.0.1:8765/; then',
                   '-R "$REPORT"']
        self.assertEqual(sorted(o.strip() for o in opens), sorted(allowed))
        # Signals only to its own page server or to the verified test Chrome,
        # re-checking the process before every signal (kill -0 only asks).
        kill_ok = [r'^is_test_chrome_pid "\$pid" "\$profile" && kill -(TERM|KILL) "\$pid" 2>/dev/null$',
                   r'^is_our_server_pid "\$spid" && kill -TERM "\$spid" 2>/dev/null$',
                   r'^is_our_server_pid "\$SERVER_PID" && kill -TERM "\$SERVER_PID" 2>/dev/null$',
                   r'^if ! kill -0 "\$SERVER_PID" 2>/dev/null; then$']
        kills = [l.strip() for l in code_lines if re.search(r"\bkill\b", l)]
        self.assertTrue(kills)
        for l in kills:
            self.assertTrue(any(re.match(k, l) for k in kill_ok), l)
        # Deletes only its own temporary folders, lock and note.
        rms = [l.strip() for l in code_lines if re.search(r"\brm\s", l)]
        self.assertEqual(len(rms), 6)
        for l in rms:
            self.assertRegex(l, r'rm -r?f -- "\$(PROFILE|WORK|d|STATE_FILE|LOCK_DIR)"')
        self.assertIn('("$TMP_ROOT"/ddchrometest-kit.*) [ -d "$WORK" ] && [ ! -L "$WORK" ] && rm -rf -- "$WORK" ;;', code)
        self.assertIn('for d in "$TMP_ROOT"/ddchrometest.* "$TMP_ROOT"/ddchrometest-kit.*; do', code)
        delete = code.split("delete_profile() {", 1)[1].split("\n}", 1)[0]
        self.assertLess(delete.index('("$TMP_ROOT"/ddchrometest.*) ;;'), delete.index('rm -rf -- "$PROFILE"'))
        # The lock has a fixed name that the leftover sweep can never match, and
        # only a lock this run made is removed on exit.
        self.assertIn('\nLOCK_DIR="$TMP_ROOT/ddchrometest-lock"\n', code)
        self.assertIn('[ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ] && rm -rf -- "$LOCK_DIR"', code)
        final = code.split("final_cleanup() {", 1)[1].split("\n}", 1)[0]
        self.assertIn('[ "$LOCKED" = 1 ] && drop_lock', final)
        self.assertLess(code.index("\ntake_lock\n"), code.index('\nstep 1 "Quick checks"\n'))
        # Permission reminders do not depend on how far the test got (review:
        # a stop in step 2 or 3 used to skip them), and an exit that cuts the
        # clean-up short still prints what is left to switch off.
        clean = code.split("cleanup_interactive() {", 1)[1].split("\n}", 1)[0]
        self.assertNotIn('[ -n "$WORK" ] || return', clean)
        work_block = clean.split('if [ -n "$WORK" ]; then', 1)[1].split("\n  fi\n", 1)[0]
        self.assertNotIn("permission_cleanup", work_block)
        self.assertIn("permission_cleanup", clean.split("\n  fi\n", 1)[1])
        perm = code.split("permission_cleanup() {", 1)[1].split("\n}", 1)[0]
        self.assertIn('if [ "$AX_CHECKED" = 1 ] || [ -n "$AX_BEFORE" ]; then accessibility_cleanup; fi', perm)
        self.assertIn('[ "$ASKED_AUTOMATION" = 1 ] && automation_cleanup', perm)
        self.assertIn("CLEANUP_DONE=1", clean)
        self.assertIn('elif [ "$CLEANUP_DONE" != 1 ]; then\n    short_reminders', final)
        self.assertIn("AX_CHECKED=1", code.split("ensure_accessibility() {", 1)[1].split("\n}", 1)[0])
        # DayDream is quit before any permission step (README safety rule 5).
        self.assertLess(code.index("\nquit_daydream\n"), code.index('\nstep 2 "Let $APP see'))
        # --only adds the steps that open the windows later steps need.
        self.assertIn('ONLY="$ONLY,incognito-race"', code)
        self.assertIn('ONLY="$ONLY,two-windows-new"', code)
        # One Automation reset, only after the owner types y; never Accessibility.
        tcc = [l.strip() for l in code_lines if "tccutil" in l and not l.strip().startswith('[ "$DRY" = 1 ] && dry ')]
        self.assertEqual(tcc, ['if tccutil reset AppleEvents "$APP_BUNDLE" >/dev/null 2>&1; then'])
        i = code.index("if tccutil reset AppleEvents")
        self.assertIn('if ask_yes "Switch off all of $APP\'s Automation permissions now?"; then', code[i - 120:i])
        # The permission prompt is asked for once, by the harness's own flag.
        self.assertEqual(len(re.findall(r'^\s*"\$HARNESS" preflight --request-permission ', code, re.M)), 1)
        self.assertIn('args=(run --probe-labels --report "$REPORT")', code)
        self.assertIn('\n  "$HARNESS" "${args[@]}"\n', code)          # foreground, keyboard attached
        self.assertIn('"$SERVER" --root "$PAGE_DIR" --port "$PORT" </dev/null >"$WORK/server.log" 2>&1 &', code)
        # The report goes to the home folder, which needs no Files & Folders
        # permission; nothing makes macOS ask for the Desktop.
        self.assertNotIn("$HOME/Desktop", code)
        self.assertIn('local dir="$HOME" n=2', code)
        # The owner sees only preflight's status lines, not developer hints.
        self.assertIn("PF_LINES='^(Chrome profile|Chrome|Accessibility|Automation):'", code)
        self.assertIn("  show_preflight\n}", code.split("run_preflight() {", 1)[1])
        # --dry-run: every side effect sits in a function that checks $DRY first.
        effect = re.compile(cmd + r'(?:open|tccutil|afplay|mktemp|mkdir|"\$HARNESS"|"\$SERVER")\s|\bkill\s+-|\brm\s+-|>\s*"\$(STATE_FILE|LOCK_DIR)')
        func, seen_dry = None, False
        for line in code_lines:
            m = re.match(r"^(\w+)\(\) \{", line)
            if m:
                func, seen_dry = m.group(1), False
            if func and ('"$DRY" = 1' in line or '"$DRY" != 1' in line):
                before = line.split('"$DRY"', 1)[0]
                seen_dry = seen_dry or not effect.search(before)
            if effect.search(line):
                self.assertIsNotNone(func, "side effect outside a function: " + line)
                self.assertTrue(seen_dry, "%s: side effect before any $DRY check: %s" % (func, line.strip()))
            if line == "}":
                func = None

    def test_kit_build_script_and_entitlements(self):
        s = (KIT / "build-kit.sh").read_text()
        code_lines = [l for l in s.splitlines() if not l.lstrip().startswith("#")]
        code = "\n".join(code_lines)
        # It never notarizes, staples or touches the keychain: it prints those steps.
        for l in code_lines:
            if re.search(r"notarytool|stapler|spctl", l):
                self.assertTrue(l.lstrip().startswith("printf "), l)
        for pattern in [r"(^|[;&|(]\s*)security\s", r"\bgit\b", r"\bcurl\b", r"\bsudo\b", r"altool", FLAG_NAME]:
            self.assertIsNone(re.search(pattern, code, re.M), pattern)
        self.assertIn('VOLNAME="DayDream Chrome Test"', code)
        self.assertIn('--scratch-path "$WORK/build"', code)
        self.assertIn('--entitlements "$HERE/entitlements.plist" --sign "$SIGN" "$STAGE/bin/chrome-device-test"', code)
        serve_sign = code.split("--identifier com.macmem.chrome-device-test-serve", 1)[1].split("\n", 2)
        self.assertNotIn("--entitlements", "\n".join(serve_sign[:2]))
        self.assertEqual(plistlib.loads((KIT / "entitlements.plist").read_bytes()),
                         {"com.apple.security.automation.apple-events": True})
        for p in KIT.iterdir():
            if p.is_file():
                self.assertNotIn(FLAG_NAME, p.read_text(errors="ignore"), p.name)
        self.assertIn('bash "/Volumes/DayDream Chrome Test/run.sh"', (KIT / "READ ME FIRST.txt").read_text())

    def test_panel_defaults_include_launchers(self):
        # Review I7: launchers and password managers that type or take keys
        # while Chrome stays frontmost are watched by default.
        options = (CORE / "Options.swift").read_text()
        line = [l for l in options.splitlines() if "public var panelBundles: [String] =" in l][0]
        for b in ["com.apple.Spotlight", "com.raycast.macos", "com.runningwithcrayons.Alfred", "com.1password.1password"]:
            self.assertIn(f'"{b}"', line)


if __name__ == "__main__":
    unittest.main()
