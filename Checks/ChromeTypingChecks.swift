#if DAYDREAM_CHROME_TYPING
// Compiled only with -DDAYDREAM_CHROME_TYPING: every release build defines it; a plain swift build leaves this file out.
// Fully synthetic: a fake Chrome (Apple Events) and a fake Accessibility tree. No Apple Event, AX call, event tap,
// Chrome launch or permission request happens here.
import Foundation
import Security
import MemoryCore
import PrivacyPolicy

final class FakeAXNode {
    let name: String
    var role: String, subrole: String
    /// fix/chrome-capture: AXChildren follows AXParent.
    var parent: FakeAXNode? { didSet { oldValue?.kids.removeAll { $0 === self }; parent?.kids.append(self) } }
    var kids: [FakeAXNode] = []
    var frame: ChromeBounds?
    var title: String?
    var url: String?
    var owner: Int32
    var minimized: Bool?
    var labels: BrowserTypingFieldLabels? = BrowserTypingFieldLabels(texts: [], identifiers: [])
    /// AXEditableAncestor (asked only of an AXComboBox): nil = unsupported or unread.
    var editableAncestor: FakeAXNode?
    /// fix/chrome-capture: AXEnabled and AXDescription (a control's names are its title and description).
    var enabled: Bool? = true
    var desc: String?
    /// claude/axjoin-1005 (the Accessibility join): AXDocument, the window server's number, AXDOMClassList (nil: read
    /// error) and whether AXCustomContent is present (nil: read error).
    var document: String?
    var windowNumber: String?
    var classes: [String]? = []
    var described: Bool? = false
    init(_ name: String, role: String, subrole: String = "", parent: FakeAXNode? = nil, owner: Int32) {
        self.name = name; self.role = role; self.subrole = subrole; self.parent = parent; self.owner = owner
        parent?.kids.append(self)
    }
}

final class FakeChromeWorld {
    struct Window { var id: String; var mode: String?; var bounds: ChromeBounds; var name: String; var tab: String; var url: String }
    static let chromePID: Int32 = 4242
    var windows: [Window]
    var facts = ChromeTargetFacts(pid: chromePID, bundleID: "com.google.Chrome", launchIdentity: "4242:1790000000:com.google.Chrome",
                                  signatureValid: true, bundleVersion: "153.0.8010.54", frameworkVersions: ["153.0.8010.53", "153.0.8010.54"],
                                  instances: 1)
    var enabled = true, permitted = true, secure = false
    var frontmost: Int32 = chromePID, systemFocused: Int32? = chromePID
    /// claude/xtyping-1005: Chrome's accessibility is asleep (no assistive client asked its application its role yet):
    /// Accessibility names no focused application, and Chrome no focused window or element. `wake` (logged "ax:wake")
    /// wakes it; `wakes` false: Chrome doesn't answer.
    var sleeping = false { didSet { if sleeping { systemFocused = nil } } }
    var wakes = true
    var axWindow: FakeAXNode?, axFocus: FakeAXNode?
    /// Chrome's AXWindows: the windows on the current Space (other Spaces are not listed).
    var axWindows: [FakeAXNode]?
    var log: [String] = []
    var clock: UInt64 = 5_000_000_000
    var tick: UInt64 = 1_000_000               // each Apple Event costs 1 ms
    var axTick: UInt64 = 0                     // each AXRole and AXParent read (fix/x-typing: a deep page's walk costs time)
    var focusTick: UInt64 = 0                  // QF-17: each frontmost-app read (a bracketed read's opening focus check)
    var failing: Set<String> = []              // request kinds that time out
    /// fix/chrome-capture: what Accessibility's hit test finds under the pointer.
    var hit: FakeAXNode?
    /// fix/chrome-capture (QF-11): AXChildren can't be read.
    var childrenUnreadable = false
    /// Review 10:48: nodes whose AXSubrole can't be read.
    var subroleUnreadable: Set<String> = []
    var namesUnreadable: Set<String> = []
    /// Review Q7-1: what each AXChildren read costs in time (0: free).
    var childrenTick: UInt64 = 0
    var aeCount = 0
    var onAppleEvent: ((ChromeJoinRequest, Int) -> Void)?

    // The standard page: Gmail compose in one normal window.
    let window: FakeAXNode, scroll: FakeAXNode, web: FakeAXNode, group: FakeAXNode, field: FakeAXNode
    static let bounds = ChromeBounds(left: 0, top: 25, right: 1440, bottom: 900)
    static let title = "Inbox (3) - someone@example.org - Gmail"
    static let url = "https://mail.google.com/mail/u/0/?compose=new#inbox"

    init() {
        let pid = Self.chromePID
        window = FakeAXNode("window-101", role: "AXWindow", subrole: "AXStandardWindow", owner: pid)
        window.frame = ChromeBounds(x: 0, y: 25, width: 1440, height: 875); window.title = Self.title; window.minimized = false
        scroll = FakeAXNode("scroll", role: "AXScrollArea", parent: window, owner: pid)
        web = FakeAXNode("web", role: "AXWebArea", parent: scroll, owner: pid)
        web.url = "https://mail.google.com/mail/u/0/?compose=new#compose"
        group = FakeAXNode("group", role: "AXGroup", parent: web, owner: pid)
        field = FakeAXNode("compose-body", role: "AXTextArea", parent: group, owner: pid)
        field.labels = BrowserTypingFieldLabels(texts: ["Message Body"], identifiers: [":r7", "Am", "Al", "editable"])
        windows = [Window(id: "101", mode: "normal", bounds: Self.bounds, name: Self.title, tab: "7", url: Self.url)]
        axWindow = window; axFocus = field; axWindows = [window]
    }
    static func kind(_ r: ChromeJoinRequest) -> String {
        switch r {
        case .windowIDs: return "ids"
        case .modes: return "modes"
        case .allBounds: return "allBounds"
        case .mode(let w): return "mode:" + w
        case .bounds(let w): return "bounds:" + w
        case .name(let w): return "name:" + w
        case .activeTabID(let w): return "activeTab:" + w
        case .tabURL(let w, let t): return "url:" + w + ":" + t
        }
    }
    func ae(_ r: ChromeJoinRequest) -> ChromeJoinReply? {
        aeCount += 1; clock += tick
        let kind = Self.kind(r)
        onAppleEvent?(r, aeCount)
        // fix/chrome-root: the synchronous join asks every window's mode and bounds in one event each (`modes`,
        // `allBounds`); a failing "mode" or "bounds" times those out too.
        let base = kind == "modes" ? "mode" : kind == "allBounds" ? "bounds" : String(kind.split(separator: ":").first ?? "")
        guard !failing.contains(base) && !failing.contains(kind) else { log.append("ae:" + kind + "=timeout"); return nil }
        let reply: ChromeJoinReply?
        let w = r.windowID.flatMap { id in windows.first { $0.id == id } }
        switch r {
        case .windowIDs: reply = .ids(windows.map(\.id))
        // QF-17 batched reads: a window whose mode can't be read leaves the list short (the join refuses).
        case .modes: reply = .texts(windows.compactMap(\.mode))
        case .allBounds: reply = .boundsList(windows.map(\.bounds))
        case .mode: reply = w?.mode.map { .text($0) }
        case .bounds: reply = w.map { .bounds($0.bounds) }
        case .name: reply = w.map { .text($0.name) }
        case .activeTabID: reply = w.map { .text($0.tab) }
        case .tabURL(_, let t): reply = w.flatMap { $0.tab == t ? .text($0.url) : nil }
        }
        if case .mode = r, case .text(let m)? = reply { log.append("ae:" + kind + "=" + m) } else { log.append("ae:" + kind) }
        // fix/chrome-root: a batched read logs what it read of each window too, in the per-window form the ordering
        // checks use (every window's mode before anything else; bounds are window content).
        if case .modes = r { for w in windows { if let m = w.mode { log.append("ae:mode:" + w.id + "=" + m) } } }
        if case .allBounds = r { for w in windows { log.append("ae:bounds:" + w.id) } }
        return reply
    }
    var access: ChromeAXAccess<FakeAXNode> {
        var a = ChromeAXAccess<FakeAXNode>(
            frontmostPID: { self.log.append("ax:frontmost"); self.clock += self.focusTick; return self.frontmost },
            systemFocusedPID: { self.log.append("ax:systemFocused"); return self.systemFocused },
            secureInput: { self.log.append("ax:secure"); return self.secure },
            focusedWindow: { self.log.append("ax:focusedWindow"); return self.sleeping ? nil : self.axWindow },
            windows: { self.log.append("ax:windows"); return self.axWindows },
            focusedElement: { self.log.append("ax:focusedElement"); return self.sleeping ? nil : self.axFocus },
            owner: { $0.owner },
            role: { self.clock += self.axTick; self.log.append("ax:role:" + $0.name); return $0.role },
            subrole: { self.log.append("ax:subrole:" + $0.name); return self.subroleUnreadable.contains($0.name) ? nil : $0.subrole },
            parent: { self.clock += self.axTick; return $0.parent },
            frame: { self.log.append("ax:frame:" + $0.name); return $0.frame },
            minimized: { $0.minimized },
            title: { self.log.append("ax:title:" + $0.name); return $0.title },
            url: { self.log.append("ax:url:" + $0.name); return $0.url },
            fieldLabels: { self.log.append("ax:labels:" + $0.name); return $0.labels },
            equal: { $0 === $1 },
            editableAncestor: { self.log.append("ax:editable:" + $0.name); return $0.editableAncestor },
            elementAt: { _, _ in self.log.append("ax:hit"); return self.hit },
            enabled: { self.log.append("ax:enabled:" + $0.name); return $0.enabled },
            controlNames: { self.log.append("ax:names:" + $0.name); return self.namesUnreadable.contains($0.name) ? nil : [$0.title ?? "", $0.desc ?? ""] },
            children: { self.clock += self.childrenTick; self.log.append("ax:children:" + $0.name); return self.childrenUnreadable ? nil : $0.kids })
        a.wake = {
            self.log.append("ax:wake")
            guard self.wakes else { return false }
            if self.sleeping { self.sleeping = false; self.systemFocused = self.frontmost }
            return true
        }
        return a
    }
    var environment: ChromeJoinEnvironment {
        ChromeJoinEnvironment(now: { self.clock }, enabled: { self.log.append("env:enabled"); return self.enabled },
                              target: { self.log.append("env:target"); return self.facts },
                              automationPermitted: { self.log.append("env:permission"); return $0 == self.facts.pid && self.permitted },
                              launchIdentity: { self.log.append("env:launch"); return $0 == self.facts.pid ? self.facts.launchIdentity : nil })
    }
    func run(_ join: BrowserTypingJoin<FakeAXNode>, blockList: BrowserTypingBlockList = BrowserTypingBlockList(),
             alwaysBlocked: [String] = PrivacySettings.sensitiveDomains) -> BrowserTypingJoinResult {
        join.join(environment: environment, appleEvents: ae, accessibility: access, blockList: blockList, alwaysBlocked: alwaysBlocked)
    }
    /// A second Chrome window (normal unless stated), not focused. `onThisSpace`:
    /// Accessibility lists it too (AXWindows shows only the current Space).
    @discardableResult
    func addWindow(_ id: String, mode: String?, front: Bool = true, bounds: ChromeBounds = ChromeBounds(left: 200, top: 100, right: 1000, bottom: 700),
                   name: String = "Private page title", url: String = "https://private.example.net/secret-path?q=private",
                   onThisSpace: Bool = true) -> FakeAXNode {
        let w = Window(id: id, mode: mode, bounds: bounds, name: name, tab: "9" + id, url: url)
        if front { windows.insert(w, at: 0) } else { windows.append(w) }
        let node = axOnlyWindow("window-" + id, frame: bounds, title: name)
        if onThisSpace { axWindows?.append(node) }
        return node
    }
    /// A window Accessibility shows but Apple Events does not list (an
    /// Incognito window that is opening or closing, or another Chrome process).
    func axOnlyWindow(_ name: String, frame: ChromeBounds, title: String, subrole: String = "AXStandardWindow") -> FakeAXNode {
        let node = FakeAXNode(name, role: "AXWindow", subrole: subrole, owner: Self.chromePID)
        node.frame = frame; node.title = title; node.minimized = false
        return node
    }
    func removeWindow(_ id: String) {
        windows.removeAll { $0.id == id }
        axWindows?.removeAll { $0.name == "window-" + id }
    }
    /// Content reads: anything that reveals a window's title, page, URL or AX content.
    static func isContent(_ entry: String) -> Bool {
        ["ae:bounds:", "ae:name:", "ae:activeTab:", "ae:url:", "ax:focusedWindow", "ax:windows", "ax:focusedElement", "ax:title:", "ax:url:",
         "ax:role:", "ax:subrole:", "ax:frame:", "ax:labels:", "ax:editable:"].contains { entry.hasPrefix($0) }
    }
    /// Page-authored or page-identifying reads: titles, names, tabs, URLs, fields, labels.
    static func isPageContent(_ entry: String) -> Bool {
        ["ae:name:", "ae:activeTab:", "ae:url:", "ax:focusedElement", "ax:title:", "ax:url:", "ax:labels:"].contains { entry.hasPrefix($0) }
    }
}

/// fix/chrome-capture (QF-10): Chrome's AXTitle is the Apple Events window name followed by " - Google Chrome"
/// (and " - <profile>" when there are several profiles). An exact match denied every real page with `.window`.
/// fix/chrome-capture (privacy review B5): the diagnostics names are pinned; none tells a privacy refusal apart, and a
/// line never carries a count.
func checkDiagnosticsAllowlist() throws {
    let allowed = CaptureDiagnostics.allowed
    // claude/livefix-1004: + "post.chord.marked" (Command-Return marked a post's earlier pieces; an outcome, not a denial).
    try check(allowed.count == 107, "diagnostics: the allowed names are pinned (\(allowed.count))")
    // Review of the (i) set, B5-1: no denial names a reason (a named harmless one would single out the unnamed ones);
    // B5-2: nothing is named before the secret check; no per-key Accessibility read on main for diagnostics.
    try check(!allowed.contains { $0.contains("denied.") || $0.hasPrefix("post.skip.pageChanged") || $0 == "commit.nothing"
                                   || $0.hasPrefix("key.target.notSystemFocused") || $0.hasPrefix("key.target.systemFocusUnread")
                                   || $0.hasPrefix("join.formScan") || $0.hasPrefix("drop.") || $0.hasPrefix("settle.") || $0 == "commit.parked"
                                   || ["burst.typed", "seal.idle", "seal.click", "seal.inputSource", "seal.lateKeyGap", "seal.otherAppKey", "seal.switchShortcut"].contains($0) },
              "diagnostics B5-1/B5-2: no denial reason, no pre-check or refusal-only name is allowed")
    let forbidden = ["notNormal", "sensitiveField", "blockedSite", "secure", "private", "incognito", "guest", "secret",
                     "sensitive", "held", "latch", "gate", "notFocused", "denied.changed", "unlisted", "windowList", "denied.typingOff", "password",
                     "afterRefusal", "deniedQuiet", "formScan.password", "formScan.reveal", "formScan.clear", "join.full.denied.field", "join.click.denied.field"]
    try check(!allowed.contains { name in forbidden.contains { name.lowercased().contains($0.lowercased()) } || name.hasSuffix(".disabled") },
              "diagnostics: no allowed name tells a privacy refusal apart")
    let d = CaptureDiagnostics(run: "abcd1234"); d.setEnabled(true)
    for _ in 0..<7 { d.count("tap.key") }
    d.count("join.full.denied"); d.count("join.full.denied", BrowserTypingDenial.notNormal); d.count("join.full.denied", BrowserTypingDenial.sensitiveField)
    d.count("join.full.denied", BrowserTypingDenial.timeout); d.count("burst.dropped", BrowserTypingDrop.held); d.count("burst.dropped", BrowserTypingDrop.latch)
    d.count("seal.reason", SealReason.sensitive); d.count("seal.reason", SealReason.idle)
    // Held by a join on its way: kept only if that join allows.
    d.hold("join.title", ChromeWindowMatching.TitleShape.profile); d.hold("join.formScan", BrowserFormScanResult.exhausted)
    d.settleHeld(allowed: false)
    try check(d.heldSnapshot().isEmpty && d.snapshot()["join.title.profile"] == nil, "diagnostics B5-1: a denied join's held names are forgotten")
    let line = d.flush(now: Date(), context: { nil }, system: { CaptureDiagnostics.System(hidKeys: 12, sessionKeys: 3) }) ?? ""
    try check(line == "capture-diagnostics run=abcd1234 seq=1 gen=none policy=none epoch=none join.full.denied seal.reason.idle sys.hid.keys sys.session.keys tap.key",
              "diagnostics: a line names what was seen, once each, no counts, no privacy reason (\(line))")
    d.hold("join.title", ChromeWindowMatching.TitleShape.suffix); d.hold("join.formScan", BrowserFormScanResult.password)
    d.settleHeld(allowed: true)
    let kept = d.snapshot()
    try check(kept["join.title.suffix"] == 1 && kept.keys.allSatisfy { !$0.contains("formScan") } && d.heldSnapshot().isEmpty,
              "diagnostics: an allowed join's held names are kept (never a privacy outcome) (\(kept.keys.sorted()))")
}

/// fix/chrome-capture (QF-11, QF-3): the form scan around a typed field, and sign-in usernames.
func checkFormScan() throws {
    func join(_ w: FakeChromeWorld, anyFocus: Bool = false) -> BrowserTypingJoinResult {
        BrowserTypingJoin<FakeAXNode>().join(environment: w.environment, appleEvents: w.ae, accessibility: w.access,
                                             blockList: BrowserTypingBlockList(), alwaysBlocked: PrivacySettings.sensitiveDomains, anyFocus: anyFocus)
    }
    /// The p11 fixture's shape: the field in a <p> of a <form> whose other <p>s hold password fields.
    func formWorld(password: Bool = true, button: String? = nil, desc: String? = nil, fillers: Int = 0, passwordLast: Bool = false) -> FakeChromeWorld {
        let w = FakeChromeWorld(); let pid = FakeChromeWorld.chromePID
        let form = FakeAXNode("form", role: "AXGroup", parent: w.web, owner: pid)
        w.group.parent = form
        // An <input type=text>, labelled (QF-4 refuses an unlabelled one on its own; P04 below is unlabelled).
        w.field.role = "AXTextField"
        w.field.labels = BrowserTypingFieldLabels(texts: ["Name"], identifiers: ["curtext"])
        func pw() { let p = FakeAXNode("p-pw", role: "AXGroup", parent: form, owner: pid)
                    _ = FakeAXNode("pw", role: "AXTextField", subrole: "AXSecureTextField", parent: p, owner: pid) }
        if password && !passwordLast { pw() }
        for i in 0..<fillers {
            let p = FakeAXNode("p\(i)", role: "AXGroup", parent: form, owner: pid)
            _ = FakeAXNode("t\(i)", role: "AXStaticText", parent: p, owner: pid)
        }
        if password && passwordLast { pw() }
        if button != nil || desc != nil {
            let b = FakeAXNode("toggle", role: "AXButton", parent: w.group, owner: pid); b.title = button; b.desc = desc
        }
        return w
    }
    // The first Apple Event of the confirming read (a one-window join has 7 in its first read).
    let firstConfirming = 8
    // The pure name rule.
    try check(["Show password", "Hide password", "Toggle password visibility", "Passwort anzeigen", "show Password"].allSatisfy(BrowserFormScan.revealName)
              && !["Show", "Send", "Password", "Show more", "Forgot password?", ""].contains(where: BrowserFormScan.revealName),
              "form scan: a show/hide password control's name, nothing else")
    // P04: a password shown as text (type=text, autocomplete=current-password, no label) in a form with a password field.
    var w = formWorld(); w.field.labels = BrowserTypingFieldLabels(texts: [], identifiers: ["curtext"])
    try check(join(w).denial == .sensitiveField, "form scan (P04): an unlabelled text field in a form with a password field: sensitiveField (the scan comes first)")
    w = formWorld()
    try check(join(w).denial == .sensitiveField, "form scan: a labelled text field in a form with a password field: sensitiveField")
    // P05 / QF-3: a username beside a password.
    w = formWorld(); w.field.role = "AXTextField"; w.field.labels = BrowserTypingFieldLabels(texts: ["Email"], identifiers: ["email"])
    try check(join(w).denial == .sensitiveField, "form scan (P05, QF-3): the email or username of a login or signup form: sensitiveField")
    // A show-password control beside the field, with no password field left (it was shown as text).
    for (title, desc) in [("Show password", nil), (nil, "Toggle password visibility"), ("Hide password", nil)] as [(String?, String?)] {
        w = formWorld(password: false, button: title, desc: desc)
        try check(join(w).denial == .sensitiveField, "form scan: a text field beside '\(title ?? desc ?? "")': sensitiveField")
    }
    // Still allowed: a form with no password field, an unrelated button.
    w = formWorld(password: false, button: "Send")
    try check(join(w).proof != nil, "form scan: a form with no password field and a Send button: allowed")
    try check(join(FakeChromeWorld()).proof != nil, "form scan: the standard compose page: allowed")
    // Nearest first: a password field beside the field (the same row, as P05) is found before a large form's other rows.
    w = formWorld(password: false, fillers: 200)
    _ = FakeAXNode("row-pw", role: "AXTextField", subrole: "AXSecureTextField", parent: w.group, owner: FakeChromeWorld.chromePID)
    try check(join(w).denial == .sensitiveField, "form scan: a password field in the field's own row, 200 other rows: sensitiveField")
    // Breadth first: a password row among the first rows of the form is found (p11 has 13 rows).
    w = formWorld(fillers: 40)
    try check(join(w).denial == .sensitiveField, "form scan: a password row first among 40 rows: sensitiveField")
    // The budget (review of 31012ae, blocker 1): a scan cut short can't show there is no password field; it denies.
    w = formWorld(fillers: 200, passwordLast: true)
    try check(join(w).denial == .field, "form scan: a password field past node 64: the scan is cut short and denies (field)")
    w = formWorld(password: false, fillers: 200)
    let farToggle = FakeAXNode("far-toggle", role: "AXButton", parent: w.group.parent!, owner: FakeChromeWorld.chromePID); farToggle.title = "Show password"
    try check(join(w).denial == .field, "form scan: a show-password control past node 64: denied (field)")
    w = formWorld(password: false, fillers: 200)
    try check(join(w).denial == .field, "form scan: no password field at all, but more than 64 nodes in scope: denied (field), never clear")
    // Levels 1 and 2 clear, level 3 cut short: denied.
    do {
        let w = FakeChromeWorld(); let pid = FakeChromeWorld.chromePID
        w.field.role = "AXTextField"; w.field.labels = BrowserTypingFieldLabels(texts: ["Name"], identifiers: [])
        let form = FakeAXNode("form", role: "AXGroup", owner: pid), outer = FakeAXNode("outer", role: "AXGroup", parent: w.web, owner: pid)
        form.parent = outer; w.group.parent = form
        for i in 0..<3 { _ = FakeAXNode("near\(i)", role: "AXStaticText", parent: form, owner: pid) }
        for i in 0..<100 { _ = FakeAXNode("far\(i)", role: "AXStaticText", parent: outer, owner: pid) }
        try check(join(w).denial == .field, "form scan: levels 1-2 clear, level 3 past the budget: denied (field)")
    }
    // 256/257 children, at an ancestor level and in the breadth-first walk: 256 is read (the password first is found),
    // 257 is never read (unreadable: denied, never clear, never the first 256).
    for n in [256, 257] {
        let w = FakeChromeWorld(); let pid = FakeChromeWorld.chromePID
        w.field.role = "AXTextField"; w.field.labels = BrowserTypingFieldLabels(texts: ["Name"], identifiers: [])
        _ = FakeAXNode("pw-first", role: "AXTextField", subrole: "AXSecureTextField", parent: w.group, owner: pid)
        for i in 0..<(n - 2) { _ = FakeAXNode("sib\(i)", role: "AXStaticText", parent: w.group, owner: pid) }
        try check(w.group.kids.count == n, "form scan setup: \(n) children at the field's parent")
        try check(join(w).denial == (n == 256 ? .sensitiveField : .field),
                  "form scan: \(n) children at an ancestor level: \(n == 256 ? "read (sensitiveField)" : "unreadable (field)")")
        let v = FakeChromeWorld()
        v.field.role = "AXTextField"; v.field.labels = BrowserTypingFieldLabels(texts: ["Name"], identifiers: [])
        let big = FakeAXNode("big", role: "AXGroup", parent: v.group, owner: pid)
        _ = FakeAXNode("pw-in-big", role: "AXTextField", subrole: "AXSecureTextField", parent: big, owner: pid)
        for i in 0..<(n - 1) { _ = FakeAXNode("row\(i)", role: "AXStaticText", parent: big, owner: pid) }
        try check(join(v).denial == (n == 256 ? .sensitiveField : .field),
                  "form scan: \(n) children in the breadth-first walk: \(n == 256 ? "read (sensitiveField)" : "unreadable (field)")")
    }
    // Running out of time mid-scan never gives clear.
    w = formWorld(password: false, fillers: 25)
    try check(join(w).proof != nil, "form scan setup: 25 rows, no password field, in time: clear")
    w = formWorld(password: false, fillers: 25); w.axTick = 4_000_000
    let lateResult = join(w)
    try check(lateResult.denial == .timeout && w.log.contains(where: { $0.hasPrefix("ax:children:") }),
              "form scan: the join's time runs out during the scan: timeout, never clear (\(String(describing: lateResult.denial)))")
    // Review 10:48: a datalist password (`<input type=password list=...>`) is an AXComboBox with the subrole
    // AXSecureTextField. Beside the field (1 level up), across the page, and 5 levels up: sensitiveField. A plain
    // datalist combo box (not secure) leaves the field typed.
    do {
        let pid = FakeChromeWorld.chromePID
        for role in ["AXComboBox", "AXTextArea", "AXSearchField"] {
            let d = FakeChromeWorld(); d.field.labels = BrowserTypingFieldLabels(texts: ["Email"], identifiers: [])
            _ = FakeAXNode("dl-pw", role: role, subrole: "AXSecureTextField", parent: d.group, owner: pid)
            try check(join(d).denial == .sensitiveField && d.log.contains("ax:subrole:dl-pw"),
                      "10:48: a \(role) with subrole AXSecureTextField beside the field: sensitiveField")
        }
        let far = FakeChromeWorld(); far.field.labels = BrowserTypingFieldLabels(texts: ["Email"], identifiers: [])
        _ = FakeAXNode("dl-pw", role: "AXComboBox", subrole: "AXSecureTextField", parent: FakeAXNode("login", role: "AXGroup", parent: far.web, owner: pid), owner: pid)
        try check(join(far).denial == .sensitiveField, "10:48: a datalist password elsewhere on the page: sensitiveField")
        let plain = FakeChromeWorld(); plain.field.labels = BrowserTypingFieldLabels(texts: ["Email"], identifiers: [])
        _ = FakeAXNode("dl-city", role: "AXComboBox", subrole: "", parent: plain.group, owner: pid)
        try check(join(plain).proof != nil, "10:48 control: a plain datalist combo box beside the field: typed")
        let unread = FakeChromeWorld(); unread.field.labels = BrowserTypingFieldLabels(texts: ["Email"], identifiers: [])
        let u = FakeAXNode("dl-x", role: "AXComboBox", subrole: "", parent: unread.group, owner: pid)
        unread.subroleUnreadable = [u.name]
        try check(join(unread).denial == .field, "10:48: a combo box whose subrole can't be read: field (fail closed)")
    }
    // C1 closure (was the review C1 DOCUMENTED GAP "a password field 4 ancestors up is not seen; the field is
    // allowed"): every ancestor up to the page is scanned, nearest first, in the same budget.
    do {
        let pid = FakeChromeWorld.chromePID
        /// A field `depth` levels below the page (the field's own group is level 1), the password field (or a reveal
        /// control) a child of level `at`, `rows` static texts directly under the page.
        func deep(_ depth: Int, passwordAt at: Int?, reveal: Bool = false, rows: Int = 0, frameRows: Int = 0) -> FakeChromeWorld {
            let w = FakeChromeWorld()
            w.field.role = "AXTextField"; w.field.labels = BrowserTypingFieldLabels(texts: ["Name"], identifiers: [])
            if frameRows > 0 {
                let f = FakeAXNode("frame-web", role: "AXWebArea", parent: w.web, owner: pid)
                for i in 0..<frameRows { _ = FakeAXNode("frame-row\(i)", role: "AXStaticText", parent: f, owner: pid) }
            }
            var levels: [FakeAXNode] = [w.group]
            w.web.kids.removeAll { $0 === w.group }
            var parent: FakeAXNode = w.web
            for i in stride(from: depth, to: 1, by: -1) { parent = FakeAXNode("level\(i)", role: "AXGroup", parent: parent, owner: pid); levels.insert(parent, at: 0) }
            w.group.parent = parent; parent.kids.append(w.group)
            // levels[0] is level `depth` (right under the page) ... levels[depth-1] is level 1 (w.group).
            if let at, at >= 1, at <= depth {
                let holder = levels[depth - at]
                if reveal { let b = FakeAXNode("reveal-at\(at)", role: "AXButton", parent: holder, owner: pid); b.title = "Show password" }
                else { _ = FakeAXNode("pw-at\(at)", role: "AXTextField", subrole: "AXSecureTextField", parent: holder, owner: pid) }
            }
            for i in 0..<rows { _ = FakeAXNode("page-row\(i)", role: "AXStaticText", parent: w.web, owner: pid) }
            return w
        }
        for (depth, at) in [(4, 4), (6, 6), (6, 4), (8, 5)] {
            try check(join(deep(depth, passwordAt: at)).denial == .sensitiveField,
                      "C1 closure: a password field \(at) levels up (field \(depth) levels below the page): sensitiveField (was the C1 DOCUMENTED GAP: allowed)")
        }
        try check(join(deep(6, passwordAt: 5, reveal: true)).denial == .sensitiveField, "C1 closure: a Show password control 5 levels up: sensitiveField")
        // A password field directly under the page, the field 7 levels down: sensitiveField.
        let top = deep(7, passwordAt: nil)
        _ = FakeAXNode("page-pw", role: "AXTextField", subrole: "AXSecureTextField", parent: top.web, owner: pid)
        try check(join(top).denial == .sensitiveField, "C1 closure: a password field directly under the page, the field 7 levels down: sensitiveField")
        // A deep field on a page with no password field that fits the budget: typed.
        for depth in [4, 6, 12] {
            try check(join(deep(depth, passwordAt: nil, rows: 20)).proof != nil, "C1 closure: a field \(depth) levels down a small page with no password field: typed")
        }
        // STATED COST: a deep field on a big page: field (the budget runs out before the page is covered).
        try check(join(deep(6, passwordAt: nil, rows: 100)).denial == .field, "C1 closure STATED COST: a field 6 levels down a page with 100 other nodes: field")
        // Review (11:30) a: a password field past the budget is field, never typed.
        let past = deep(6, passwordAt: nil, rows: 100)
        _ = FakeAXNode("late-pw", role: "AXTextField", subrole: "AXSecureTextField", parent: past.web, owner: pid)
        try check(join(past).denial == .field, "C1 closure: a password field under the page after 100 page rows, the field 6 levels down: field (budget), never typed")
        // Review (11:30) b: the join's time runs out at a level above 3: timeout.
        let slow = deep(8, passwordAt: nil, rows: 10)
        slow.childrenTick = BrowserTypingTiming.joinBudgetNanoseconds / 5
        let slowResult = join(slow)
        let levelsRead = slow.log.filter { $0.hasPrefix("ax:children:level") }.count
        try check(slowResult.denial == .timeout && levelsRead >= 4 && !slow.log.contains("ax:children:web"),
                  "C1 closure: time runs out at a level above 3 (\(levelsRead) levels read, the page not reached): timeout (\(String(describing: slowResult.denial)))")
        // Q6-1 order unchanged: page first, frames last. A page password field behind an early 40-node frame, the
        // field 6 levels down: sensitiveField, the frame never opened; with no password the frame spends the budget: field.
        let q = deep(6, passwordAt: nil, rows: 30, frameRows: 40)
        _ = FakeAXNode("page-pw", role: "AXTextField", subrole: "AXSecureTextField", parent: FakeAXNode("pw-box", role: "AXGroup", parent: q.web, owner: pid), owner: pid)
        try check(join(q).denial == .sensitiveField && !q.log.contains("ax:children:frame-web"),
                  "C1 closure: Q6-1 order: a page password behind an early frame, field 6 levels down: sensitiveField, the frame never opened")
        try check(join(deep(6, passwordAt: nil, rows: 30, frameRows: 40)).denial == .field,
                  "C1 closure: the same page with no password field: the frame spends the budget: field")
    }
    // Every supported kind of box is scanned (Codex 04:40, option a): a search box (X2), a text area or a contenteditable
    // box (X1, X3) beside a password field or a show-password control is refused, and a text area on a big page too.
    for (role, subrole, labels, name) in [("AXTextField", "AXSearchField", [String](), "X2: an unlabelled search box"),
                                          ("AXComboBox", "", ["Search query"], "a search combo box"),
                                          ("AXTextArea", "", ["Notes"], "X1: a text area"), ("AXTextArea", "", [], "an unlabelled contenteditable box")] {
        let v = formWorld(); v.field.role = role; v.field.subrole = subrole
        if role == "AXComboBox" { v.field.editableAncestor = v.field }
        v.field.labels = BrowserTypingFieldLabels(texts: labels, identifiers: [])
        try check(join(v).denial == .sensitiveField, "form scan: \(name) beside a password field: sensitiveField")
        let t = formWorld(password: false, button: "Show password"); t.field.role = role; t.field.subrole = subrole
        if role == "AXComboBox" { t.field.editableAncestor = t.field }
        t.field.labels = BrowserTypingFieldLabels(texts: labels, identifiers: [])
        try check(join(t).denial == .sensitiveField, "form scan: \(name) beside a show-password control: sensitiveField")
        let late = formWorld(password: false); late.field.role = role; late.field.subrole = subrole
        if role == "AXComboBox" { late.field.editableAncestor = late.field }
        // (An unlabelled one-line box is refused in the first read already, Q4-1; label it so the confirming read's scan decides.)
        late.field.labels = BrowserTypingFieldLabels(texts: labels.isEmpty ? ["Search"] : labels, identifiers: [])
        late.onAppleEvent = { _, n in if n == firstConfirming {
            let b = FakeAXNode("late-toggle", role: "AXButton", parent: late.group, owner: FakeChromeWorld.chromePID); b.title = "Show password" } }
        try check(join(late).denial == .sensitiveField, "form scan (X3): \(name), a show-password control added between the reads: sensitiveField")
    }
    // The stated loss: a composer (a text area) on a big page can't be proven and is refused (field).
    for rows in [100, 300] {
        let v = FakeChromeWorld()
        for i in 0..<rows { _ = FakeAXNode("feed\(i)", role: "AXLink", parent: v.group, owner: FakeChromeWorld.chromePID) }
        try check(join(v).denial == .field, "form scan STATED LOSS: a composer beside \(rows) links (the scan can't finish): field")
    }
    // Review X1: a multi-line secret named by its label is refused without any scan.
    for label in ["Mnemonic", "Seed phrase", "Recovery phrase", "Recovery words", "Secret phrase", "Private key", "Security answer",
                  "Enter your 12-word seed phrase", "Paste your private key"] {
        let v = FakeChromeWorld(); v.field.labels = BrowserTypingFieldLabels(texts: [label], identifiers: [])
        try check(join(v).denial == .sensitiveField, "X1: a text area named '\(label)': sensitiveField")
    }
    // Review R9-1 (the QF-17 implementer's r9 patch, reviewed; was: "the page itself is never scanned: allowed"): the field is 2 levels under the
    // page, so the page's other children are scanned too, and a password field of another form on the same small page
    // now refuses this field. A stated cost of the proposal (a sign-up box beside a login form on one small page).
    w = FakeChromeWorld(); w.field.role = "AXTextField"; w.field.labels = BrowserTypingFieldLabels(texts: ["Name"], identifiers: [])
    let other = FakeAXNode("other-form", role: "AXGroup", parent: w.web, owner: FakeChromeWorld.chromePID)
    _ = FakeAXNode("other-pw", role: "AXTextField", subrole: "AXSecureTextField", parent: other, owner: FakeChromeWorld.chromePID)
    try check(join(w).denial == .sensitiveField, "form scan (r9 proposal, stated cost): a password field of another form on the same small page, the field within 3 levels of the page: sensitiveField")
    // Review R9-1: a flat page. A labelled field (label-for "Email", or a placeholder only) directly under the page,
    // or 2 levels down, next to a password field elsewhere on the page: sensitiveField.
    for depth in [0, 1, 2] {
        for texts in [["Email"], ["you@example.com"]] {
            let v = FakeChromeWorld(); let pid = FakeChromeWorld.chromePID
            v.field.role = "AXTextField"; v.field.labels = BrowserTypingFieldLabels(texts: texts, identifiers: [])
            var parent: FakeAXNode = v.web
            for i in 0..<depth { parent = FakeAXNode("wrap\(i)", role: "AXGroup", parent: parent, owner: pid) }
            v.group.parent = nil; v.field.parent = parent
            _ = FakeAXNode("flat-pw", role: "AXTextField", subrole: "AXSecureTextField", parent: v.web, owner: pid)
            try check(join(v).denial == .sensitiveField, "R9-1: \(texts) \(depth) levels under a flat page with a password field: sensitiveField")
            let clean = FakeChromeWorld()
            clean.field.role = "AXTextField"; clean.field.labels = BrowserTypingFieldLabels(texts: texts, identifiers: [])
            var cp: FakeAXNode = clean.web
            for i in 0..<depth { cp = FakeAXNode("wrap\(i)", role: "AXGroup", parent: cp, owner: pid) }
            clean.group.parent = nil; clean.field.parent = cp
            try check(join(clean).proof != nil, "R9-1 control: \(texts) \(depth) levels under a small page with no password field: typed")
        }
    }
    // R9-1 stated cost: a field right under a page with more than 64 other nodes: field (never clear).
    do {
        let v = FakeChromeWorld(); let pid = FakeChromeWorld.chromePID
        v.field.labels = BrowserTypingFieldLabels(texts: ["Notes"], identifiers: [])
        for i in 0..<100 { _ = FakeAXNode("page-row\(i)", role: "AXStaticText", parent: v.web, owner: pid) }
        try check(join(v).denial == .field, "R9-1 STATED COST: a field 2 levels under a page with 100 other nodes: field")
    }
    // Codex 07:10 (fail-closed nested web areas; was the R9-1 DOCUMENTED GAP "a password field inside an iframe is not
    // read, the field is allowed"): a nested AXWebArea is opened inside the same node budget.
    do {
        let pid = FakeChromeWorld.chromePID
        // An iframe's password field next to a main-page Email field: sensitiveField (one-line box, text area).
        for role in ["AXTextField", "AXTextArea"] {
            for nest in [0, 2] {
                let f = FakeChromeWorld(); f.field.role = role
                f.field.labels = BrowserTypingFieldLabels(texts: ["Email"], identifiers: [])
                let frame = FakeAXNode("frame-web", role: "AXWebArea", parent: f.web, owner: pid)
                var inner: FakeAXNode = frame
                for i in 0..<nest { inner = FakeAXNode("frame-wrap\(i)", role: "AXGroup", parent: inner, owner: pid) }
                _ = FakeAXNode("frame-pw", role: "AXTextField", subrole: "AXSecureTextField", parent: inner, owner: pid)
                try check(join(f).denial == .sensitiveField && f.log.contains("ax:children:frame-web"),
                          "07:10 nested web areas: \(role) 'Email' beside an iframe with a password field \(nest) levels in: sensitiveField (was the R9-1 DOCUMENTED GAP: allowed)")
            }
        }
        // A frame's secure role (not only a secure subrole) refuses too.
        let r = FakeChromeWorld(); r.field.labels = BrowserTypingFieldLabels(texts: ["Email"], identifiers: [])
        let rf = FakeAXNode("frame-web", role: "AXWebArea", parent: r.web, owner: pid)
        _ = FakeAXNode("frame-secure", role: "AXSecureTextField", parent: rf, owner: pid)
        try check(join(r).denial == .sensitiveField, "07:10 nested web areas: an AXSecureTextField in an iframe: sensitiveField")
        // An iframe with no password field (a video embed, a text field of its own) leaves a labelled field typed,
        // and reads no control names inside the frame (roles, subroles and children only).
        let c = FakeChromeWorld(); c.field.labels = BrowserTypingFieldLabels(texts: ["Notes"], identifiers: [])
        let cf = FakeAXNode("frame-web", role: "AXWebArea", parent: c.web, owner: pid)
        let cg = FakeAXNode("frame-group", role: "AXGroup", parent: cf, owner: pid)
        _ = FakeAXNode("frame-text", role: "AXStaticText", parent: cg, owner: pid)
        _ = FakeAXNode("frame-box", role: "AXTextField", subrole: "", parent: cg, owner: pid)
        let fb = FakeAXNode("frame-play", role: "AXButton", parent: cg, owner: pid); fb.title = "Play"
        try check(join(c).proof != nil && c.log.contains("ax:children:frame-web") && c.log.contains("ax:names:frame-play"),
                  "07:10 nested web areas: an iframe with no password field (a Play button): the labelled field is typed")
        // Review Q6-2: a control's names are read inside frames too (deny-only): a "Show password" toggle refuses.
        let t = FakeChromeWorld(); t.field.labels = BrowserTypingFieldLabels(texts: ["Email"], identifiers: [])
        let tf = FakeAXNode("frame-web", role: "AXWebArea", parent: t.web, owner: pid)
        let tb = FakeAXNode("frame-toggle", role: "AXButton", parent: FakeAXNode("frame-group", role: "AXGroup", parent: tf, owner: pid), owner: pid)
        tb.title = "Show password"
        try check(join(t).denial == .sensitiveField, "Q6-2: a Show password control inside an iframe: sensitiveField")
        // Review Q7-1 (speed): each deferred frame's children are read only while the join has time and the budget has
        // room. 30 frames: a slow AXChildren runs the join out of time after a few frames (timeout), and frames of 10
        // nodes spend the budget (field); neither reads every frame.
        do {
            let z = FakeChromeWorld(); z.field.labels = BrowserTypingFieldLabels(texts: ["Notes"], identifiers: [])
            for k in 0..<30 { let f = FakeAXNode("yframe\(k)", role: "AXWebArea", parent: z.web, owner: pid); _ = FakeAXNode("yrow\(k)", role: "AXStaticText", parent: f, owner: pid) }
            z.childrenTick = BrowserTypingTiming.joinBudgetNanoseconds / 10
            let r = join(z)
            let opened = z.log.filter { $0.hasPrefix("ax:children:yframe") }.count
            try check(r.denial == .timeout && opened < 30, "Q7-1: 30 frames with a slow AXChildren: out of time after \(opened) frames, refused (timeout)")
            let b = FakeChromeWorld(); b.field.labels = BrowserTypingFieldLabels(texts: ["Notes"], identifiers: [])
            for k in 0..<20 { let f = FakeAXNode("bframe\(k)", role: "AXWebArea", parent: b.web, owner: pid)
                              for i in 0..<10 { _ = FakeAXNode("bframe\(k)-row\(i)", role: "AXStaticText", parent: f, owner: pid) } }
            let rb = join(b)
            let openedB = b.log.filter { $0.hasPrefix("ax:children:bframe") }.count
            try check(rb.denial == .field && openedB < 20, "Q7-1: 20 frames of 10 nodes: the budget is spent after \(openedB) frames, refused (field)")
        }
        // Review Q6-1: frames are scanned after the page. A page's password field behind an early frame (40 nodes, or
        // more than the child cap) is still found (sensitiveField, as before frames were opened), never `exhausted`.
        for (rows, name) in [(40, "a 40-node frame"), (300, "a 300-child frame")] {
            let q = FakeChromeWorld(); q.field.labels = BrowserTypingFieldLabels(texts: ["Email"], identifiers: [])
            let qf = FakeAXNode("frame-web", role: "AXWebArea", parent: q.web, owner: pid)
            for i in 0..<rows { _ = FakeAXNode("frame-row\(i)", role: "AXStaticText", parent: qf, owner: pid) }
            let pwBox = FakeAXNode("pw-box", role: "AXGroup", parent: q.web, owner: pid)
            for i in 0..<30 { _ = FakeAXNode("page-row\(i)", role: "AXStaticText", parent: q.web, owner: pid) }
            _ = FakeAXNode("page-pw", role: "AXTextField", subrole: "AXSecureTextField", parent: pwBox, owner: pid)
            try check(join(q).denial == .sensitiveField && !q.log.contains("ax:children:frame-web"),
                      "Q6-1: a page password field behind \(name) and 30 page nodes: sensitiveField, the frame never opened")
        }
        // A budget spent inside frames: field (fail closed), never clear.
        let e = FakeChromeWorld(); e.field.labels = BrowserTypingFieldLabels(texts: ["Notes"], identifiers: [])
        for k in 0..<2 {
            let ef = FakeAXNode("frame-web\(k)", role: "AXWebArea", parent: e.web, owner: pid)
            for i in 0..<40 { _ = FakeAXNode("frame\(k)-row\(i)", role: "AXStaticText", parent: ef, owner: pid) }
        }
        try check(join(e).denial == .field, "07:10 nested web areas STATED COST: two iframes of 40 nodes beside the field exhaust the budget: field")
        // A password field past the budget, inside a frame: still field (never clear).
        let x = FakeChromeWorld(); x.field.labels = BrowserTypingFieldLabels(texts: ["Notes"], identifiers: [])
        let xf = FakeAXNode("frame-web", role: "AXWebArea", parent: x.web, owner: pid)
        for i in 0..<80 { _ = FakeAXNode("frame-row\(i)", role: "AXStaticText", parent: xf, owner: pid) }
        _ = FakeAXNode("frame-pw", role: "AXTextField", subrole: "AXSecureTextField", parent: xf, owner: pid)
        try check(join(x).denial == .field, "07:10 nested web areas: a frame's password field past node 64: field")
        // A frame with more than maxChildren children: unreadable, field.
        let u = FakeChromeWorld(); u.field.labels = BrowserTypingFieldLabels(texts: ["Notes"], identifiers: [])
        let uf = FakeAXNode("frame-web", role: "AXWebArea", parent: u.web, owner: pid)
        for i in 0...BrowserFormScan.maxChildren { _ = FakeAXNode("frame-cell\(i)", role: "AXStaticText", parent: uf, owner: pid) }
        try check(join(u).denial == .field, "07:10 nested web areas: a frame with more than 256 children: field")
    }
    // Fail closed: AXChildren unreadable.
    w = formWorld(password: false); w.childrenUnreadable = true
    try check(join(w).denial == .field, "form scan: children unreadable: denied (field)")
    // The click join (anyFocus) doesn't scan: it attributes nothing typed.
    w = formWorld(); w.childrenUnreadable = true
    try check(join(w, anyFocus: true).proof != nil && !w.log.contains(where: { $0.hasPrefix("ax:children:") }), "form scan: the click join reads no children")
    // The scan runs once per join (the first read only) and reads no labels of other nodes.
    w = formWorld(password: false)
    _ = join(w)
    try check(w.log.filter { $0.hasPrefix("ax:labels:") }.allSatisfy { $0 == "ax:labels:compose-body" }, "form scan: no other field's labels are read")
    // Privacy review M7: both reads scan. A password field, a show-password toggle or a sensitive label that appears
    // between the first read and the confirming read (its first Apple Event, the 8th of this one-window join) denies.
    w = formWorld(password: false)
    var logAtChange: [String] = []
    w.onAppleEvent = { _, n in if n == firstConfirming {
        logAtChange = w.log
        _ = FakeAXNode("late-pw", role: "AXTextField", subrole: "AXSecureTextField", parent: w.group, owner: FakeChromeWorld.chromePID) } }
    try check(join(w).denial == .sensitiveField, "M7: a password field added between the reads: sensitiveField")
    try check(logAtChange.contains("ax:labels:compose-body") && logAtChange.contains(where: { $0.hasPrefix("ax:children:") }),
              "M7: the change came after the first read's labels and scan (the confirming read denied it)")
    w = formWorld(password: false)
    w.onAppleEvent = { _, n in if n == firstConfirming { let b = FakeAXNode("late-toggle", role: "AXButton", parent: w.group, owner: FakeChromeWorld.chromePID); b.title = "Show password" } }
    try check(join(w).denial == .sensitiveField, "M7: a show-password toggle added between the reads: sensitiveField")
    // M7 with a cut-short scan: rows or a far password field added between the reads deny.
    w = formWorld(password: false)
    w.onAppleEvent = { _, n in if n == firstConfirming, let form = w.group.parent {
        for i in 0..<100 { _ = FakeAXNode("late-row\(i)", role: "AXStaticText", parent: form, owner: FakeChromeWorld.chromePID) } } }
    try check(join(w).denial == .field, "M7: a sibling list that grows past the budget between the reads: denied (field)")
    w = formWorld(password: false, fillers: 20)
    w.onAppleEvent = { _, n in if n == firstConfirming, let form = w.group.parent {
        for i in 0..<60 { _ = FakeAXNode("late-row\(i)", role: "AXStaticText", parent: form, owner: FakeChromeWorld.chromePID) }
        _ = FakeAXNode("late-far-pw", role: "AXTextField", subrole: "AXSecureTextField", parent: form, owner: FakeChromeWorld.chromePID) } }
    try check(join(w).denial == .field, "M7: a password field added past node 64 between the reads: denied (field)")
    // Review (b): the scan's scope comes from each read's own role and subrole; a kind that changes between the reads
    // is `changed`, in both directions, and so is the search subrole.
    for (from, to) in [(("AXTextArea", ""), ("AXTextField", "")), (("AXTextField", ""), ("AXTextArea", "")),
                       (("AXTextField", ""), ("AXTextField", "AXSearchField")), (("AXTextField", "AXSearchField"), ("AXTextField", ""))] {
        let v = formWorld(password: false)
        v.field.role = from.0; v.field.subrole = from.1; v.field.labels = BrowserTypingFieldLabels(texts: ["Name"], identifiers: [])
        v.onAppleEvent = { _, n in if n == firstConfirming { v.field.role = to.0; v.field.subrole = to.1 } }
        try check(join(v).denial == .changed, "M7: the field turns from \(from) into \(to) between the reads: changed")
    }
    // Review C2: a scan that can't finish and one that can't read leave the same diagnostics line as any other denial.
    do {
        let d = CaptureDiagnostics.shared
        func deniedLine(_ w: FakeChromeWorld) -> String {
            d.setEnabled(false); d.setEnabled(true)
            let r = join(w)
            d.count("join.full.denied"); d.settleHeld(allowed: r.proof != nil)
            let line = d.flush(now: Date().addingTimeInterval(Double.random(in: 100...100_000)), context: { nil }, system: { nil }) ?? ""
            return line.components(separatedBy: " ").filter { !$0.hasPrefix("seq=") }.joined(separator: " ")
        }
        let exhausted = deniedLine(formWorld(password: false, fillers: 200))
        let unreadableWorld = formWorld(password: false); unreadableWorld.childrenUnreadable = true
        let unreadable = deniedLine(unreadableWorld)
        let incognito = FakeChromeWorld(); incognito.addWindow("777", mode: "incognito", front: false)
        let other = deniedLine(incognito)
        d.setEnabled(false)
        try check(exhausted == unreadable && unreadable == other && !exhausted.contains("formScan"),
                  "C2: exhausted, unreadable and an Incognito denial leave the same line (\(exhausted) | \(unreadable) | \(other))")
    }
    w = FakeChromeWorld()
    w.onAppleEvent = { _, n in if n == firstConfirming { w.field.labels = BrowserTypingFieldLabels(texts: ["Verification code"], identifiers: []) } }
    try check(join(w).denial == .sensitiveField, "M7: the field's label turns into 'Verification code' between the reads: sensitiveField")
    w = FakeChromeWorld()
    w.onAppleEvent = { _, n in if n == firstConfirming { w.field.labels = BrowserTypingFieldLabels(texts: ["Username"], identifiers: []) } }
    try check(join(w).denial == .sensitiveField, "M7: the field turns into a username between the reads: sensitiveField")
    // A focused field that was secure when a join saw it and is now shown as text.
    w = FakeChromeWorld(); w.field.role = "AXTextField"; w.field.subrole = "AXSecureTextField"
    let j = BrowserTypingJoin<FakeAXNode>()
    func run(_ w: FakeChromeWorld) -> BrowserTypingJoinResult {
        j.join(environment: w.environment, appleEvents: w.ae, accessibility: w.access, blockList: BrowserTypingBlockList(),
               alwaysBlocked: PrivacySettings.sensitiveDomains)
    }
    try check(run(w).denial == .field, "revealed password: the secure field is denied")
    w.field.subrole = ""
    try check(run(w).denial == .sensitiveField, "revealed password: the same field shown as text: sensitiveField")
    try check(run(FakeChromeWorld()).proof != nil, "revealed password: another field is allowed")
    // QF-3: a sign-in username on its own (a-store deny-login-username).
    for (texts, ids) in [(["Email or username"], ["username", "login-username"]), (["Username"], []), ([], ["login_user"]), ([], ["signinEmail"]),
                         (["User name"], [])] as [([String], [String])] {
        w = FakeChromeWorld(); w.field.labels = BrowserTypingFieldLabels(texts: texts, identifiers: ids)
        try check(join(w).denial == .sensitiveField, "QF-3: sign-in field \(texts + ids): sensitiveField")
    }
    w = FakeChromeWorld(); w.field.labels = BrowserTypingFieldLabels(texts: ["Email"], identifiers: ["email"])
    try check(join(w).proof != nil, "QF-3: a plain Email field outside a login form is allowed (documented gap)")
}

/// fix/chrome-capture (QF-2): which shortcuts save the unfinished text at their key-down.
/// Only approved C1 mechanics: deep composers, datalist secure subroles, page/frame order and failed metadata.
/// No real browsing data; these fixture tripwires do not satisfy C-8's shipped-Chrome hidden/timing gate.
func checkBoundedFormSearch() throws {
    let w = FakeChromeWorld()
    let chain = [w.field, w.group, w.web, w.scroll, w.window]
    var ax = w.access
    var calls: [(BrowserFormSearch, Int)] = []
    var fields = [w.field]
    var reveal: [FakeAXNode] = []
    var fail = false
    ax.formSearch = { page, query, limit in
        try! check(page === w.web, "C1 search: only the chain's exact page")
        calls.append((query, limit))
        if fail { return nil }
        switch query { case .textFields: return fields; case .revealControls: return reveal }
    }
    func result() -> BrowserFormScanResult { BrowserFormScan.search(chain: chain, ax: ax, late: { false }) }
    try check(result() == .clear && calls.count == 5, "C1 search: complete identity sentinel and four fixed control searches")
    try check(calls.allSatisfy { $0.1 == 65 }, "C1 search: fixed 65 limit on every call")
    fields = []
    try check(result() == .unreadable, "C1 search: no sentinel refuses, no count-only path")
    let other = FakeAXNode("other-text", role: "AXTextField", owner: FakeChromeWorld.chromePID)
    fields = [other]
    try check(result() == .unreadable, "C1 search: one different field is not the sentinel")
    fields = [w.field, other]; other.subrole = "AXSecureTextField"; other.role = "AXComboBox"
    try check(result() == .password, "C1 search: datalist password subrole refuses")
    other.role = "AXGroup"
    try check(result() == .password, "C1 search: secure subrole wins even on a group")
    other.subrole = ""; other.role = "AXSecureUnknown"
    try check(result() == .password, "C1 search: secure role wins before allowed-role checks")
    other.role = "AXGroup"; other.editableAncestor = nil
    try check(result() == .unreadable, "C1 search: arbitrary group refuses")
    other.editableAncestor = other
    try check(result() == .clear, "C1 search: editable group root accepted with read subrole")
    w.subroleUnreadable.insert(other.name)
    try check(result() == .unreadable, "C1 search: missing group subrole refuses")
    w.subroleUnreadable = []; other.role = "AXStaticText"
    try check(result() == .unreadable, "C1 search: ignored key returning wrong roles refuses")
    other.role = "AXTextField"; other.owner += 1
    try check(result() == .unreadable, "C1 search: wrong owner refuses")
    other.owner = FakeChromeWorld.chromePID
    fields = Array(repeating: w.field, count: 65)
    try check(result() == .unreadable, "C1 search: result limit is partial and refuses")
    fields = [w.field]; fail = true
    try check(result() == .unreadable, "C1 search: failed or unsupported read refuses")
    fail = false
    let button = FakeAXNode("show-pass", role: "AXButton", owner: FakeChromeWorld.chromePID)
    button.title = "Show password"; reveal = [button]
    try check(result() == .reveal, "C1 search: names returned must satisfy revealName")
    button.title = "Password help"
    try check(result() == .clear, "C1 search: secret word alone is not a reveal gesture")
    w.namesUnreadable.insert(button.name)
    try check(result() == .unreadable, "C1 search: failed control-name read refuses")
    w.namesUnreadable = []; button.role = "AXTextField"
    try check(result() == .unreadable, "C1 search: control key returning a field refuses")
    reveal = Array(repeating: button, count: 65)
    try check(result() == .unreadable, "C1 search: control result limit refuses")
    reveal = []; calls = []
    try check(BrowserFormScan.search(chain: chain, ax: ax, late: { true }) == .late && calls.isEmpty,
              "C1 search: late before any read does not search")
    var reads = 0
    try check(BrowserFormScan.search(chain: chain, ax: ax, late: { reads += 1; return reads == 9 }) == .late,
              "C1 search: lateness during metadata inspection refuses")
    // fix/chrome-large-pages: recovery is ON by default (production and QA); it changes only exhaustion.
    for i in 0..<100 { _ = FakeAXNode("large-page-\(i)", role: "AXStaticText", parent: w.web, owner: FakeChromeWorld.chromePID) }
    try check(ax.formSearchRecoveryEnabled && w.access.formSearchRecoveryEnabled, "C1 search: production recovery default is ON")
    ax.formSearchRecoveryEnabled = false
    calls = []
    try check(BrowserFormScan.scan(chain: chain, ax: ax, late: { false }) == .exhausted && calls.isEmpty,
              "C1 search negative control: recovery off (the old default) refuses the large page, no extra AX work")
    ax.formSearchRecoveryEnabled = true
    try check(BrowserFormScan.scan(chain: chain, ax: ax, late: { false }) == .clear,
              "C1 search: complete result recovers large clear page")
    fail = true
    try check(BrowserFormScan.scan(chain: chain, ax: ax, late: { false }) == .exhausted,
              "C1 search: failure retains exact exhausted refusal")
    fail = false
    let deepPassword = FakeAXNode("deep-password", role: "AXComboBox", subrole: "AXSecureTextField", owner: FakeChromeWorld.chromePID)
    fields = [w.field, deepPassword]
    try check(BrowserFormScan.scan(chain: chain, ax: ax, late: { false }) == .password,
              "C1 search: secure neighbour beyond exhausted walk remains sensitive")
    fields = []
    try check(BrowserFormScan.scan(chain: chain, ax: ax, late: { false }) == .exhausted,
              "C1 search: missing sentinel retains exact exhausted refusal")
    fields = [w.field]
    let password = FakeAXNode("near-password", role: "AXTextField", subrole: "AXSecureTextField", parent: w.group, owner: FakeChromeWorld.chromePID)
    calls = []
    try check(BrowserFormScan.scan(chain: chain, ax: ax, late: { false }) == .password && calls.isEmpty,
              "C1 search: known page password never downgraded or searched")
    password.role = "AXButton"; password.subrole = ""; password.title = "Show password"
    calls = []
    try check(BrowserFormScan.scan(chain: chain, ax: ax, late: { false }) == .reveal && calls.isEmpty,
              "C1 search: known reveal never downgraded")
    w.namesUnreadable.insert(password.name)
    try check(BrowserFormScan.scan(chain: chain, ax: ax, late: { false }) == .unreadable && calls.isEmpty,
              "C1 walk: failed control-name read refuses; search cannot mask it")
}

/// fix/chrome-root (2026-10-02): the cause of "no Chrome typing is ever saved" on the owner's Mac. Every Apple Event
/// to Chrome takes 8-17 ms there (median 12.5 ms with Chrome in front, measured by the read-only harness in
/// a harness run against a real Chrome; Finder answers in 8.3 ms too), and the double read asked
/// 2 + 2 events per window per read, 26 events for three windows: about 330 ms against a 150 ms budget. Every join was
/// refused (`timeout`, or `notNormal`/`windowList` when one event ran past the 20 ms per-event timeout, which Apple
/// Events round to one 16.7 ms tick). Now: every window's mode and bounds in one event each (QF-17's batched reads),
/// 16 events whatever the window count, a 500 ms budget and a 100 ms per-event timeout.
func checkRealAppleEventLatency() throws {
    /// Three normal windows on the owner's Mac shape: Google in front, two others; each Apple Event costs `tick`.
    func owner(tick: UInt64, windows extra: Int = 2) -> FakeChromeWorld {
        let w = FakeChromeWorld(); w.tick = tick
        w.windows[0].name = "Google"; w.windows[0].url = "https://www.google.com/"; w.window.title = "Google - Google Chrome"
        w.web.url = "https://www.google.com/"
        w.field.role = "AXTextArea"; w.field.labels = BrowserTypingFieldLabels(texts: ["Search"], identifiers: ["APjFqb", "gLFyf"])
        for i in 0..<extra {
            let o = Double(40 * i)
            w.addWindow("3\(i)", mode: "normal", front: false, bounds: ChromeBounds(left: 100 + o, top: 80 + o, right: 900 + o, bottom: 700 + o),
                        name: "Other \(i)", url: "https://example.org/\(i)")
        }
        return w
    }
    // The measured median (12.5 ms) and a slow tenth (20 ms): allowed, with 16 events.
    for tick: UInt64 in [12_500_000, 20_000_000] {
        let w = owner(tick: tick)
        let began = w.clock
        let r = w.run(BrowserTypingJoin<FakeAXNode>())
        try check(r.proof?.origin == "https://www.google.com" && r.proof?.role == "AXTextArea" && w.aeCount == 16,
                  "fix/chrome-root: Google's search box with three windows and \(tick / 1_000_000) ms Apple Events: allowed with 16 events (\(String(describing: r.denial)), \(w.aeCount))")
        try check(w.clock - began <= BrowserTypingTiming.joinBudgetNanoseconds, "fix/chrome-root: that join fits its budget")
    }
    // The event count no longer grows with the window count (it was 2 + 2 per window, per read).
    var counts: [Int] = []
    for extra in [0, 2, 9] { let w = owner(tick: 1_000_000, windows: extra); _ = w.run(BrowserTypingJoin<FakeAXNode>()); counts.append(w.aeCount) }
    try check(counts == [16, 16, 16], "fix/chrome-root: 16 Apple Events per join with 1, 3 or 10 windows (\(counts))")
    // The old shape at the measured latency could never fit the old budget: 26 events of 12.5 ms for three windows.
    try check(26 * 12_500_000 > 150_000_000 && 16 * 12_500_000 + 100_000_000 <= BrowserTypingTiming.joinBudgetNanoseconds,
              "fix/chrome-root: the old 26-event join (325 ms) overran 150 ms; the 16-event join has room for slow AX reads")
    try check(BrowserTypingTiming.lightBudgetNanoseconds >= 3 * 20_000_000 && BrowserTypingTiming.maxKeyLagNanoseconds == 150_000_000,
              "fix/chrome-root: the light check's three events fit its budget; the key lag bound is unchanged")
    // A Chrome slower than the budget still refuses.
    var w = owner(tick: 40_000_000)
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .timeout, "fix/chrome-root: 40 ms Apple Events (640 ms join): timeout, as before")
    // The batched reads keep every refusal.
    w = owner(tick: 12_500_000); w.windows[2].mode = "incognito"
    var r = w.run(BrowserTypingJoin<FakeAXNode>())
    try check(r.denial == .notNormal && !w.log.contains(where: FakeChromeWorld.isPageContent), "fix/chrome-root: one Incognito window among three: notNormal before any page read")
    w = owner(tick: 12_500_000); w.windows[1].mode = nil
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .notNormal, "fix/chrome-root: a window whose mode is missing from the batched answer: notNormal")
    w = owner(tick: 12_500_000); w.failing = ["modes"]
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .notNormal, "fix/chrome-root: the batched mode read times out: notNormal (fail closed)")
    w = owner(tick: 12_500_000); w.failing = ["allBounds"]
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .window, "fix/chrome-root: the batched bounds read times out: window")
    // M6: a window opening right after the bounds read (before the list is read again) breaks the index pairing: changed.
    w = owner(tick: 12_500_000)
    w.onAppleEvent = { _, n in if n == 4 { w.addWindow("666", mode: "normal", front: true, onThisSpace: false) } }
    r = w.run(BrowserTypingJoin<FakeAXNode>())
    try check(r.denial == .changed && !w.log.contains(where: FakeChromeWorld.isPageContent), "fix/chrome-root: a window opening during the bounds read: changed, before any page read")
    // An Incognito window opening between the two reads: the confirming read's batched mode read refuses.
    w = owner(tick: 12_500_000)
    var seen = 0
    w.onAppleEvent = { req, _ in if case .tabURL = req { seen += 1; if seen == 1 { w.addWindow("667", mode: "incognito", front: false, onThisSpace: false) } } }
    r = w.run(BrowserTypingJoin<FakeAXNode>())
    try check(r.proof == nil, "fix/chrome-root: an Incognito window opening between the reads: refused (\(String(describing: r.denial)))")
    // The light check at the measured latency vouches for the next key (it asked 2 + one per window and never fit).
    w = owner(tick: 12_500_000)
    let j = BrowserTypingJoin<FakeAXNode>()
    _ = w.run(j); let before = w.aeCount
    let l = j.light(environment: w.environment, appleEvents: w.ae, accessibility: w.access, blockList: BrowserTypingBlockList())
    try check(l?.proof?.light == true && w.aeCount - before == 3, "fix/chrome-root: the light check at 12.5 ms per event vouches with 3 events")
    w.windows[1].mode = "incognito"
    try check(j.light(environment: w.environment, appleEvents: w.ae, accessibility: w.access, blockList: BrowserTypingBlockList()) == nil,
              "fix/chrome-root: the light check's batched mode read still sees an Incognito window")
    // The key's lag is measured to its join's start: a key whose 200 ms join started at once is on time; one whose join
    // started more than 150 ms after it was typed is late; the old measurement (after the join) refused every key.
    let burst = BrowserTypingBurst()
    w = owner(tick: 12_500_000)
    let typed = w.clock; w.clock += 2_000_000
    let allowed = w.run(BrowserTypingJoin<FakeAXNode>())
    try check(!BrowserTypingBurst.onTime(typedAt: typed, processedAt: w.clock) && w.clock - typed > 150_000_000,
              "fix/chrome-root: negative control: measured after the join (the old rule) the key was late")
    try check(burst.admitKey(allowed, typedAt: typed, processedAt: w.clock), "fix/chrome-root: measured at the join's start the key is on time")
    let burst2 = BrowserTypingBurst()
    w = owner(tick: 12_500_000)
    let typedEarly = w.clock; w.clock += 160_000_000
    let lateJoin = w.run(BrowserTypingJoin<FakeAXNode>())
    try check(!burst2.admitKey(lateJoin, typedAt: typedEarly, processedAt: w.clock) && burst2.dropReason == .late,
              "fix/chrome-root: a join that started 160 ms after the key: late, refused")
    let burst3 = BrowserTypingBurst()
    w = owner(tick: 12_500_000)
    let typedAfter = w.clock + 1
    let beforeKey = w.run(BrowserTypingJoin<FakeAXNode>())
    try check(!burst3.admitKey(beforeKey, typedAt: typedAfter, processedAt: w.clock), "fix/chrome-root: a join that started before the key never admits it")
    try check(BrowserTypingBurst.processingStart(.allowed(beforeKey.proof!), processedAt: beforeKey.proof!.checkedAt + BrowserTypingTiming.joinBudgetNanoseconds + 1)
              == beforeKey.proof!.checkedAt + BrowserTypingTiming.joinBudgetNanoseconds + 1,
              "fix/chrome-root: a proof older than a join can take is measured at processing, as before")
}

/// fix/chrome-large-pages: the full double-read join on a large Google-shaped page (hundreds of nodes, the search box
/// 10 levels below the page), with a fake page search that walks the whole fake page the way Chrome's
/// AXUIElementsForSearchPredicate is expected to (text fields incl. secure ones and contenteditable roots; buttons,
/// check boxes and links whose names hold the search text). Synthetic: it does not prove what shipped Chrome returns.
func checkLargePageRecovery() throws {
    let pid = FakeChromeWorld.chromePID
    let googleURL = "https://www.google.com/"
    let googleTitle = "Google"
    /// A Google-shaped page: header, apps grid, footer links (several hundred nodes) and the search box deep inside.
    func google(depth: Int = 10, filler: Int = 120) -> FakeChromeWorld {
        let w = FakeChromeWorld()
        w.windows[0].name = googleTitle; w.windows[0].url = googleURL; w.window.title = googleTitle; w.web.url = googleURL
        // Rebuild the field's ancestry: web > d0 > d1 > ... > field.
        var parent: FakeAXNode = w.web
        for level in 0..<depth {
            let d = FakeAXNode("d\(level)", role: "AXGroup", parent: parent, owner: pid)
            // Each level has siblings, so the walk (nearest first) spends its budget on them.
            for k in 0..<6 {
                let sib = FakeAXNode("d\(level)-sib\(k)", role: "AXGroup", parent: parent, owner: pid)
                _ = FakeAXNode("d\(level)-sib\(k)-text", role: "AXStaticText", parent: sib, owner: pid)
                let b = FakeAXNode("d\(level)-sib\(k)-btn", role: "AXButton", parent: sib, owner: pid); b.title = "Search by voice"
            }
            parent = d
        }
        w.group.parent = parent
        w.field.role = "AXTextArea"
        w.field.labels = BrowserTypingFieldLabels(texts: ["Search"], identifiers: ["APjFqb", "gLFyf"])
        for i in 0..<filler {
            let block = FakeAXNode("footer-\(i)", role: "AXGroup", parent: w.web, owner: pid)
            let l = FakeAXNode("footer-\(i)-link", role: "AXLink", parent: block, owner: pid); l.title = "Link \(i)"
            _ = FakeAXNode("footer-\(i)-text", role: "AXStaticText", parent: block, owner: pid)
        }
        return w
    }
    func count(_ n: FakeAXNode) -> Int { 1 + n.kids.reduce(0) { $0 + count($1) } }
    func all(_ n: FakeAXNode) -> [FakeAXNode] { [n] + n.kids.flatMap(all) }
    struct Search { var fail = false; var cost: UInt64 = 0; var calls = 0 }
    var search = Search()
    func access(_ w: FakeChromeWorld, recovery: Bool = true) -> ChromeAXAccess<FakeAXNode> {
        var ax = w.access
        ax.formSearchRecoveryEnabled = recovery
        ax.formSearch = { page, query, limit in
            search.calls += 1; w.clock += search.cost
            guard !search.fail, page === w.web else { return nil }
            let nodes = all(page).dropFirst()
            let found: [FakeAXNode]
            switch query {
            case .textFields:
                found = nodes.filter { ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains($0.role) || $0.role.lowercased().contains("secure")
                                       || $0.subrole.lowercased().contains("secure") || ($0.role == "AXGroup" && $0.editableAncestor === $0) }
            case .revealControls(let word):
                found = nodes.filter { ["AXButton", "AXCheckBox", "AXLink"].contains($0.role)
                                       && (($0.title ?? "") + " " + ($0.desc ?? "")).lowercased().contains(word) }
            }
            return Array(found.prefix(limit))
        }
        return ax
    }
    func join(_ w: FakeChromeWorld, recovery: Bool = true) -> BrowserTypingJoinResult {
        BrowserTypingJoin<FakeAXNode>().join(environment: w.environment, appleEvents: w.ae, accessibility: access(w, recovery: recovery),
                                             blockList: BrowserTypingBlockList(), alwaysBlocked: PrivacySettings.sensitiveDomains)
    }
    func depth(_ w: FakeChromeWorld) -> Int { var d = 0, n: FakeAXNode? = w.field; while let c = n, c !== w.web { d += 1; n = c.parent }; return d }

    // The page is large and the field is deep: the strict walk alone runs out of its budget.
    var w = google()
    try check(count(w.web) >= 300 && depth(w) >= 8, "large page: \(count(w.web)) nodes, field \(depth(w)) levels below the page")
    let chain: [FakeAXNode] = { var c: [FakeAXNode] = [], n: FakeAXNode? = w.field; while let x = n { c.append(x); n = x.parent }; return c }()
    var off = w.access; off.formSearchRecoveryEnabled = false
    try check(BrowserFormScan.scan(chain: chain, ax: off, late: { false }) == .exhausted, "large page: the walk alone is exhausted")
    // Negative control: the old default (recovery off) refuses the large page as `field`.
    search = Search()
    try check(join(google(), recovery: false).denial == .field && search.calls == 0,
              "large page negative control: recovery off (before fix/chrome-large-pages) refuses it (field), no search")
    // The fix: allowed, with both reads searching (5 searches each).
    search = Search(); w = google()
    var r = join(w)
    try check(r.proof != nil && r.denial == nil && search.calls == 10, "large Google-shaped page, no password: ALLOWED (\(String(describing: r.denial)), \(search.calls) searches)")
    // A password field anywhere on the page (past the walk's budget, at the end of the footer).
    search = Search(); w = google()
    _ = FakeAXNode("far-password", role: "AXTextField", subrole: "AXSecureTextField", parent: w.web.kids.last!, owner: pid)
    try check(join(w).denial == .sensitiveField, "large page + a password field anywhere: REFUSED (sensitiveField)")
    // A password field directly under the page, first in order.
    search = Search(); w = google()
    let first = FakeAXNode("first-password", role: "AXTextField", subrole: "AXSecureTextField", parent: w.web, owner: pid)
    w.web.kids.removeLast(); w.web.kids.insert(first, at: 0)
    try check(w.web.kids.contains { $0 === first } && join(w).denial == .sensitiveField, "large page + a password field first on the page: REFUSED (sensitiveField)")
    // A datalist password combo box.
    search = Search(); w = google()
    _ = FakeAXNode("datalist-password", role: "AXComboBox", subrole: "AXSecureTextField", parent: w.web.kids.last!, owner: pid)
    try check(join(w).denial == .sensitiveField, "large page + a datalist password combo box: REFUSED (sensitiveField)")
    // A reveal ("Show password") button, a reveal check box and a description-only reveal link.
    for (role, title, desc) in [("AXButton", "Show password", nil), ("AXCheckBox", "Hide password", nil), ("AXLink", "", "Toggle password visibility")] as [(String, String, String?)] {
        search = Search(); w = google()
        let b = FakeAXNode("far-reveal", role: role, parent: w.web.kids.last!, owner: pid); b.title = title; b.desc = desc
        try check(join(w).denial == .sensitiveField, "large page + a reveal \(role): REFUSED (sensitiveField)")
    }
    // A plain "Password help" link is not a reveal control: still allowed.
    search = Search(); w = google()
    let help = FakeAXNode("pw-help", role: "AXLink", parent: w.web.kids.last!, owner: pid); help.title = "Password help"
    try check(join(w).proof != nil, "large page + a 'Password help' link (no reveal word): allowed")
    // An unreadable search (failed or unsupported read): refused as before (field).
    search = Search(fail: true)
    try check(join(google()).denial == .field && search.calls == 1, "large page + an unreadable search: REFUSED (field)")
    // An unreadable search result (a field's subrole can't be read): refused (field).
    search = Search(); w = google()
    let odd = FakeAXNode("odd-field", role: "AXTextField", parent: w.web.kids.last!, owner: pid); w.subroleUnreadable.insert(odd.name)
    try check(join(w).denial == .field, "large page + an unreadable search result: REFUSED (field)")
    // A truncated search (65 text fields): refused (field).
    search = Search(); w = google()
    for i in 0..<65 { _ = FakeAXNode("many-\(i)", role: "AXTextField", parent: w.web.kids.last!, owner: pid) }
    try check(join(w).denial == .field, "large page + 65 text fields (a truncated search): REFUSED (field)")
    // A late search: the search would push the join past its 150 ms budget.
    search = Search(cost: BrowserTypingTiming.joinBudgetNanoseconds + 1)
    try check(join(google()).denial == .timeout, "large page + a late search: REFUSED (timeout)")
    // Searches that each fit but together push the double-read join past 150 ms: refused.
    search = Search(cost: BrowserTypingTiming.joinBudgetNanoseconds / 9)
    r = join(google())
    try check(r.proof == nil && r.denial == .timeout, "large page + searches that add up past 150 ms: REFUSED (\(String(describing: r.denial)))")
    // Searches within the budget: allowed.
    search = Search(cost: 1_000_000)
    try check(join(google()).proof != nil, "large page + 1 ms searches (10 ms in all): allowed")
    // A container with 257 children on the walk's path: the child cap refuses before any search.
    search = Search(); w = google()
    let wide = w.field.parent!.parent!
    for i in 0..<257 { _ = FakeAXNode("wide-\(i)", role: "AXStaticText", parent: wide, owner: pid) }
    try check(join(w).denial == .field && search.calls == 0, "large page + a 257-child container: REFUSED (field), no search")
    // A password field near the field: the walk finds it; never downgraded, never searched.
    search = Search(); w = google()
    _ = FakeAXNode("near-password", role: "AXTextField", subrole: "AXSecureTextField", parent: w.group, owner: pid)
    try check(join(w).denial == .sensitiveField && search.calls == 0, "large page + a password beside the field: REFUSED by the walk, no search")
    // A password field added between the two reads (M7): the confirming read's search refuses.
    search = Search(); w = google()
    let target = w.web.kids.last!
    w.onAppleEvent = { _, n in if n == 8 { _ = FakeAXNode("late-pw", role: "AXTextField", subrole: "AXSecureTextField", parent: target, owner: pid) } }
    try check(join(w).denial == .sensitiveField, "large page + a password field added between the reads: REFUSED (sensitiveField)")
}

func checkSwitchShortcuts() throws {
    let saves: [KeyStroke] = [KeyStroke(keyCode: 48, command: true), KeyStroke(keyCode: 48, command: true, shift: true),
                              KeyStroke(keyCode: 48, control: true), KeyStroke(keyCode: 48, control: true, shift: true),
                              KeyStroke(keyCode: 50, command: true), KeyStroke(keyCode: 37, command: true), KeyStroke(keyCode: 17, command: true),
                              KeyStroke(keyCode: 30, command: true, shift: true), KeyStroke(keyCode: 33, command: true, shift: true),
                              KeyStroke(keyCode: 18, command: true), KeyStroke(keyCode: 25, command: true)]
    try check(saves.allSatisfy(WebSwitchShortcut.savesAtKeyDown), "switch shortcuts (app, window, tab, address bar) save at the key-down")
    let parks: [KeyStroke] = [KeyStroke(keyCode: 45, command: true, shift: true), KeyStroke(keyCode: 45, command: true),
                              KeyStroke(keyCode: 13, command: true), KeyStroke(keyCode: 12, command: true), KeyStroke(keyCode: 17, command: true, shift: true),
                              KeyStroke(keyCode: 48), KeyStroke(keyCode: 36, command: true), KeyStroke(keyCode: 37, command: true, shift: true),
                              KeyStroke(keyCode: 37, control: true), KeyStroke(keyCode: 48, command: true, control: true),
                              KeyStroke(keyCode: 48, command: true, autorepeat: true), KeyStroke(keyCode: 17, command: true, fn: true),
                              KeyStroke(keyCode: 30, command: true), KeyStroke(keyCode: 18, command: true, shift: true), KeyStroke(keyCode: 29, command: true)]
    try check(!parks.contains(where: WebSwitchShortcut.savesAtKeyDown),
              "Command-Shift-N (Incognito), Command-N, Command-W, Command-Q, Command-Shift-T, plain Tab and the rest stay parked boundaries")
}

func checkWindowTitleSuffix() throws {
    // The pure rule.
    let m = ChromeWindowMatching.titleMatches
    try check(m("Notes", "Notes") && m("Notes - Google Chrome", "Notes") && m("Notes \u{2013} Google Chrome", "Notes")
              && m("Notes - Google Chrome - Work", "Notes") && m("Notes \u{2013} Google Chrome \u{2013} Person 1", "Notes"),
              "title match: the name alone, with the Chrome suffix, and with a profile tail")
    try check(!m("Notes - Google Chrome - ", "Notes") && !m("Notes - Google Chromebook", "Notes") && !m("Notes - Google Chrome extra", "Notes")
              && !m("Notes", "Notes - Google Chrome") && !m("Other - Google Chrome", "Notes") && !m("Note - Google Chrome", "Notes")
              && !m("Notes - Chrome", "Notes") && !m("xNotes - Google Chrome", "Notes") && !m("Notes - Google Chrome - Work\nnext", "Notes")
              && !m("", "Notes") && !m("Notes - Google Chrome", ""),
              "title match: nothing but the suffix and a profile tail after the name")
    // The join, on a page whose title is kept (not webmail), so the saved title shows which name was used.
    func page(_ name: String, axTitle: String) -> FakeChromeWorld {
        let w = FakeChromeWorld()
        w.windows[0].name = name; w.windows[0].url = "https://notes.example.org/doc/1"; w.web.url = "https://notes.example.org/doc/1"
        w.window.title = axTitle
        return w
    }
    let plain = page("Project notes", axTitle: "Project notes").run(BrowserTypingJoin<FakeAXNode>()).proof
    try check(plain != nil && plain?.windowID == "101", "title equal to the window name: allowed (as before)")
    for (tail, label) in [(" - Google Chrome", "suffix"), (" \u{2013} Google Chrome", "en-dash suffix"),
                          (" - Google Chrome - Work", "profile tail"), (" - Google Chrome - Person 1 (someone)", "profile tail with spaces")] {
        let p = page("Project notes", axTitle: "Project notes" + tail).run(BrowserTypingJoin<FakeAXNode>()).proof
        try check(p != nil && p?.windowID == "101" && p?.tabID == plain?.tabID, "AXTitle with the Chrome \(label): allowed")
        try check(p?.pageTitle == plain?.pageTitle && !(p?.pageTitle ?? "").contains("Google Chrome") && !(p?.pageTitle ?? "").contains("Work"),
                  "AXTitle with the Chrome \(label): the saved page title is the tab's own, never the suffix or profile")
    }
    // claude/typing-1004 (owner laptop 10/04: an X reply refused `window` on every join): with ONE listed window of the
    // focused window's bounds, bounds alone bind it (as the bracketed design's lean read): an AXTitle of a shape the
    // rule doesn't know is let through, site only: no page title is saved (the name it couldn't match may lag the page).
    for (axTitle, label) in [("Bank statement - Google Chrome", "an unrelated AXTitle"), ("Project notes 2 - Google Chrome", "an AXTitle that only starts with the name"),
                             ("Project notes - Google Chrome - ", "an AXTitle with an empty profile tail"),
                             ("Project notes - Some new tab state - Google Chrome", "an AXTitle with a tab state the rule doesn't know")] {
        let p = page("Project notes", axTitle: axTitle).run(BrowserTypingJoin<FakeAXNode>()).proof
        try check(p?.windowID == "101" && p?.pageTitle == "" && !(plain?.pageTitle ?? "").isEmpty,
                  "one window with these bounds, \(label): allowed on its bounds, site only (no title it couldn't match is saved)")
    }
    // With several listed windows of those bounds (another Space), the title still decides, exactly as before.
    for axTitle in ["Bank statement - Google Chrome", "Project notes 2 - Google Chrome", "Project notes - Google Chrome - "] {
        let w = page("Project notes", axTitle: axTitle)
        w.addWindow("202", mode: "normal", front: false, bounds: FakeChromeWorld.bounds, name: "Other page", url: "https://other.example.org/", onThisSpace: false)
        try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .window, "two windows with these bounds, an AXTitle matching neither name: denied (\(axTitle.count) chars)")
    }
    // The page itself is still proven: the tab's address must be the web area's.
    let switched = page("Project notes", axTitle: "Bank statement - Google Chrome")
    switched.web.url = "https://bank.example.org/statement"
    try check(switched.run(BrowserTypingJoin<FakeAXNode>()).denial == .url, "title let through on bounds, but the web area shows another page: denied (url)")
    // A page whose own title contains " - Google Chrome" never matches a different window: with another listed
    // window of the same bounds (another Space) named like it, both match and the join refuses.
    var w = page("Plan - Google Chrome", axTitle: "Plan - Google Chrome - Google Chrome")
    w.addWindow("202", mode: "normal", front: false, bounds: FakeChromeWorld.bounds, name: "Plan", url: "https://other.example.org/", onThisSpace: false)
    var r = w.run(BrowserTypingJoin<FakeAXNode>())
    try check(r.denial == .ambiguousWindow && r.proof == nil, "page title containing ' - Google Chrome': the other window named 'Plan' is never chosen")
    w = page("Plan", axTitle: "Plan - Google Chrome")
    w.addWindow("202", mode: "normal", front: false, bounds: FakeChromeWorld.bounds, name: "Plan - Google Chrome", url: "https://other.example.org/",
                onThisSpace: false)
    r = w.run(BrowserTypingJoin<FakeAXNode>())
    try check(r.denial == .ambiguousWindow && r.proof == nil, "the other window's page title is 'Plan - Google Chrome': never chosen for 'Plan'")
    // Different bounds: the other window is no candidate, and the focused one matches alone.
    w = page("Plan - Google Chrome", axTitle: "Plan - Google Chrome - Google Chrome")
    w.addWindow("202", mode: "normal", front: false, name: "Plan", url: "https://other.example.org/", onThisSpace: false)
    r = w.run(BrowserTypingJoin<FakeAXNode>())
    try check(r.proof?.windowID == "101", "page title containing ' - Google Chrome', other window elsewhere: the focused window only")
    // Two same-named windows with the same bounds, suffixed titles: still ambiguous.
    w = page("Project notes", axTitle: "Project notes - Google Chrome - Work")
    w.addWindow("202", mode: "normal", front: false, bounds: FakeChromeWorld.bounds, name: "Project notes", url: "https://notes.example.org/doc/1",
                onThisSpace: false)
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .ambiguousWindow, "two same-named windows (suffixed AXTitle): ambiguousWindow")
}

func runChromeTypingChecks() throws {
    try checkJoinVocabulary()
    try checkTargetPolicy()
    try checkTargetFactsCache()
    try checkSites()
    try checkFieldRules()
    try checkWindowMatching()
    try checkJoin()
    try checkUnmarkedTextBoxes()
    try checkDeepPages()
    try checkUnlistedWindows()
    try checkBursts()
    try checkSubmitControl()
    try checkSubmitTracker()
    try checkAsleepChrome()
    try checkXComposers()
    try checkAccessibilityJoin()
}

/// Finding 9: the per-key join re-read Chrome's versions on disk and the
/// Automation answer every key. They are cached per launch / for 1 s while
/// allowed; a denial or a new launch reads them again.
private func checkTargetFactsCache() throws {
    let cache = ChromeTargetFactsCache(ttlNanoseconds: 1_000_000_000)
    var diskReads = 0
    let read: () -> (bundleVersion: String?, frameworkVersions: [String]) = { diskReads += 1; return ("153.0.8010.54", ["153.0.8010.54"]) }
    for _ in 0..<20 { _ = cache.versions(launch: "612@1", read: read) }
    try check(cache.versionReads == 1 && diskReads == 1, "Chrome versions on disk read once per launch, not per key")
    _ = cache.versions(launch: "613@2", read: read)
    try check(cache.versionReads == 2, "a relaunched Chrome reads its versions again")
    cache.invalidate(); _ = cache.versions(launch: "613@2", read: read)
    try check(cache.versionReads == 3, "after a denial the versions are read again")

    var asks = 0, answer = true
    let ask: (Int32) -> Bool = { _ in asks += 1; return answer }
    let t0: UInt64 = 5_000_000_000
    for i in 0..<10 { _ = cache.permitted(pid: 612, launch: "612@1", now: t0 + UInt64(i) * 50_000_000, read: ask) }
    try check(asks == 1 && cache.permissionReads == 1, "Automation permission reused within one second")
    try check(cache.permitted(pid: 612, launch: "612@1", now: t0 + 1_600_000_000, read: ask) && asks == 2, "Automation permission read again after the TTL")
    try check(cache.permitted(pid: 613, launch: "613@2", now: t0 + 1_700_000_000, read: ask) && asks == 3, "another Chrome process is asked again")
    answer = false
    cache.invalidate()
    try check(!cache.permitted(pid: 612, launch: "612@1", now: t0 + 1_800_000_000, read: ask) && asks == 4, "a revoked permission is seen after invalidate")
    try check(!cache.permitted(pid: 612, launch: "612@1", now: t0 + 1_800_000_001, read: ask) && asks == 5, "a denial is never cached")
    answer = true
    try check(cache.permitted(pid: 612, launch: nil, now: t0 + 1_900_000_000, read: ask)
              && cache.permitted(pid: 612, launch: nil, now: t0 + 1_900_000_001, read: ask) && asks == 7, "no launch identity: never cached")
    _ = cache.permitted(pid: 612, launch: "612@1", now: t0 + 2_000_000_000, read: ask)
    let before = asks
    _ = cache.permitted(pid: 612, launch: "612@1", now: t0, read: ask)
    try check(asks == before + 1, "a clock that went backwards reads the permission again")
    // fix/web-textbox (battery): a page or field refusal keeps the facts; any other denial reads them again.
    let facts = ChromeTargetFactsCache(ttlNanoseconds: 1_000_000_000)
    var factsReads = 0
    let factsRead: () -> (bundleVersion: String?, frameworkVersions: [String]) = { factsReads += 1; return ("153.0.8010.54", ["153.0.8010.54"]) }
    _ = facts.versions(launch: "612@1", read: factsRead)
    for d in [nil, .blockedSite, .field, .sensitiveField] as [BrowserTypingDenial?] { facts.after(d); _ = facts.versions(launch: "612@1", read: factsRead) }
    try check(factsReads == 1, "a blocked site, a refused field or no denial keeps Chrome's cached versions (no disk read per refused key)")
    for d in BrowserTypingDenial.allCases where !ChromeTargetFactsCache.pageDenials.contains(d) {
        facts.after(d); let n = factsReads; _ = facts.versions(launch: "612@1", read: factsRead)
        try check(factsReads == n + 1, "after a \(d) denial Chrome's versions are read again")
    }
}

private func checkJoinVocabulary() throws {
    let requests: [ChromeJoinRequest] = [.windowIDs, .mode("101"), .bounds("101"), .name("101"), .activeTabID("101"), .tabURL("101", "7")]
    for r in requests {
        guard let s = r.specifier else { throw MemError.invalid("FAILED: no specifier for \(r)") }
        let outer = ChromeAppleEvents.fourCC(s.forKeyword(ChromeAppleEvents.code("seld"))?.typeCodeValue ?? 0)
        try check(ChromeAppleEvents.audit(s) && ChromeAppleEvents.readableProperties.contains(r.property) && outer == r.property,
                  "join request is one audited allowlisted core/getd: \(r)")
    }
    try check(ChromeJoinRequest.mode("").specifier == nil && ChromeJoinRequest.tabURL("101", "").specifier == nil, "join refuses empty IDs")
    // Reply decoding.
    let list = NSAppleEventDescriptor.list()
    list.insert(NSAppleEventDescriptor(string: "101"), at: 1); list.insert(NSAppleEventDescriptor(string: "202"), at: 2)
    try check(ChromeJoinRequest.windowIDs.decode(list) == .ids(["101", "202"]), "window ID list decodes in order")
    var rect: [Int16] = [25, 0, 900, 1440]   // QuickDraw: top, left, bottom, right
    let qd = NSAppleEventDescriptor(descriptorType: ChromeAppleEvents.code("qdrt"), bytes: &rect, length: 8)!
    try check(ChromeJoinRequest.bounds("101").decode(qd) == .bounds(FakeChromeWorld.bounds), "QuickDraw bounds decode to left/top/right/bottom")
    let four = NSAppleEventDescriptor.list()
    for (i, v) in [0, 25, 1440, 900].enumerated() { four.insert(NSAppleEventDescriptor(int32: Int32(v)), at: i + 1) }
    try check(ChromeJoinRequest.bounds("101").decode(four) == .bounds(FakeChromeWorld.bounds), "AppleScript-style bounds list decodes")
    var empty: [Int16] = [25, 0, 25, 0]
    try check(ChromeJoinRequest.bounds("101").decode(NSAppleEventDescriptor(descriptorType: ChromeAppleEvents.code("qdrt"), bytes: &empty, length: 8)!) == nil, "empty bounds refused")
    try check(ChromeJoinRequest.mode("101").decode(NSAppleEventDescriptor(int32: 1)) == nil, "non-text mode refused")
    try check(ChromeJoinRequest.mode("101").decode(NSAppleEventDescriptor(string: "normal")) == .text("normal"), "text mode decodes")
    try check(ChromeJoinRequest.bounds("101").decode(NSAppleEventDescriptor(string: "0,0,1,1")) == nil, "text bounds refused")
    // Input classification for the quiet period.
    for code: Int64 in [36, 76, 48, 53, 123, 124, 125, 126, 115, 119, 116, 121] {
        try check(BrowserTypingInput.disruptive(keyCode: code, command: false, control: false, option: false), "quiet period after key \(code)")
    }
    try check(BrowserTypingInput.disruptive(keyCode: 45, command: true, control: false, option: false), "Cmd+Shift+N starts the quiet period")
    try check(BrowserTypingInput.disruptive(keyCode: 0, command: false, control: true, option: false)
              && BrowserTypingInput.disruptive(keyCode: 0, command: false, control: false, option: true), "Control and Option chords start the quiet period")
    try check(!BrowserTypingInput.disruptive(keyCode: 0, command: false, control: false, option: false), "a plain letter is not disruptive")
    // UNCONFIRMED and not wired: keyboard keys carry source PID 0, posted keys the poster's PID.
    try check(BrowserTypingInput.hardwareSource(sourcePID: 0) && !BrowserTypingInput.hardwareSource(sourcePID: 612),
              "synthetic-key classifier: PID 0 is the keyboard, any other PID is a posting app")
}

private func checkTargetPolicy() throws {
    let good = FakeChromeWorld().facts
    try check(ChromeTargetPolicy.accepts(good), "signed Chrome 153 accepted")
    var f = good; f.bundleVersion = "150.0.7871.99"
    try check(!ChromeTargetPolicy.accepts(f), "Chrome < 151 refused")
    f = good; f.frameworkVersions = ["150.0.7871.99", "153.0.8010.54"]
    try check(!ChromeTargetPolicy.accepts(f), "an older framework version still on disk (possibly running) refused")
    for v in [nil, "", "abc", "153.0.8010.54-beta", "１５３.0", "153..0", "+153"] as [String?] {
        f = good; f.bundleVersion = v
        try check(!ChromeTargetPolicy.accepts(f), "unreadable Chrome version refused: \(v ?? "nil")")
    }
    f = good; f.frameworkVersions = []
    try check(!ChromeTargetPolicy.accepts(f), "missing framework versions refused")
    f = good; f.signatureValid = false
    try check(!ChromeTargetPolicy.accepts(f), "unsigned 'Chrome' refused")
    for id in ["com.google.Chrome.canary", "com.google.Chrome.beta", "org.chromium.Chromium", "com.google.chrome"] {
        f = good; f.bundleID = id
        try check(!ChromeTargetPolicy.accepts(f), "other bundle refused: " + id)
    }
    f = good; f.pid = 0
    try check(!ChromeTargetPolicy.accepts(f), "invalid PID refused")
    // A second Chrome process (another --user-data-dir) has windows this
    // process's Apple Events never list: strict mode cannot see its Incognito windows.
    for n in [0, 2, 3] {
        f = good; f.instances = n
        try check(!ChromeTargetPolicy.accepts(f), "\(n) running Chrome processes refused (exactly one required)")
    }
    try check(ChromeTargetPolicy.majorVersion("151.0.0.0") == 151 && ChromeTargetPolicy.versionAllowed("151.0.7000.1"), "Chrome 151 is the minimum")

    // Code signature, with the Security framework, on a synthetic unsigned bundle.
    var requirement: SecRequirement?
    let compiled = SecRequirementCreateWithString(ChromeTargetPolicy.requirement as CFString, [], &requirement)
    try check(compiled == errSecSuccess && requirement != nil, "Chrome requirement compiles")
    try check(ChromeTargetPolicy.requirement.contains("EQHXZ8M8AV") && ChromeTargetPolicy.requirement.contains("identifier \"com.google.Chrome\""),
              "requirement pins Google's team and Chrome's identifier")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("daydream-fake-chrome-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("Google Chrome.app")
    let versions = bundle.appendingPathComponent(ChromeTargetPolicy.frameworkVersionsPath)
    try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: versions.appendingPathComponent("153.0.8010.54"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: versions.appendingPathComponent("Current").path, withDestinationPath: "153.0.8010.54")
    let info: [String: Any] = ["CFBundleIdentifier": "com.google.Chrome", "CFBundleShortVersionString": "153.0.8010.54",
                               "CFBundleExecutable": "Google Chrome", "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    let executable = bundle.appendingPathComponent("Contents/MacOS/Google Chrome")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let read = ChromeTargetPolicy.bundleVersions(at: bundle)
    try check(read.bundleVersion == "153.0.8010.54" && read.frameworkVersions == ["153.0.8010.54"], "versions read from the bundle, 'Current' ignored")
    func satisfies(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard let requirement, SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
    let unsigned = satisfies(bundle)
    try check(!unsigned, "unsigned 'Chrome' bundle does not satisfy the Chrome requirement")
    try check(!satisfies(URL(fileURLWithPath: "/bin/ls")), "an Apple-signed non-Chrome binary does not satisfy it either")
    f = ChromeTargetFacts(pid: 4242, bundleID: "com.google.Chrome", launchIdentity: "4242:1:com.google.Chrome", signatureValid: unsigned,
                          bundleVersion: read.bundleVersion, frameworkVersions: read.frameworkVersions, instances: 1)
    try check(!ChromeTargetPolicy.accepts(f), "unsigned 'Chrome' with a valid version is still refused")
}

private func checkSites() throws {
    let list = BrowserTypingBlockList()
    for d in BrowserTypingBlockList.defaults + BrowserTypingBlockList.pinned {
        try check(BrowserTypingSites.normalizedDomain(d) == d, "default block entry is normalized: " + d)
    }
    try check(Set(BrowserTypingBlockList.defaults).count == BrowserTypingBlockList.defaults.count, "default block list has no duplicates")
    try check(Set(PrivacySettings.sensitiveDomains).isSubset(of: Set(list.effective)), "app-wide sensitive domains are in the effective block list")
    func decision(_ url: String, _ l: BrowserTypingBlockList = BrowserTypingBlockList(), always: [String] = PrivacySettings.sensitiveDomains) -> BrowserTypingSiteDecision {
        BrowserTypingSites.evaluate(url, blockList: l, alwaysBlocked: always)
    }
    for url in ["https://chase.com/", "https://secure.chase.com/overview", "https://my.1password.com/vaults", "https://vault.bitwarden.com/#/vault",
                "https://www.irs.gov/refunds", "https://www.ssa.gov/myaccount/", "https://www.gov.uk/log-in-register-hmrc-online-services",
                "https://mychart.examplehospital.org/MyChart/", "https://www.coinbase.com/home", "https://accounts.google.com/v3/signin",
                "https://www.kp.org/", "https://turbotax.intuit.com/", "https://shop.example.org/checkout/cart", "https://example.org/account/login?next=/",
                "https://example.org/users/sign-in", "https://example.org/api/oauth/authorize",
                "https://example.org/%6Cogin", "https://example.org/pay/", "https://example.org/sso", "https://example.org/#/login",
                "https://example.org/#!/checkout"] {
        try check(decision(url) == .blocked, "blocked by default: " + url)
    }
    // Review I4: separators, word pairs, the query, more page words, government hosts.
    for url in ["https://example.org/users/sign_in", "https://example.org/Sign.In", "https://example.org/sign%20in", "https://example.org/log_in",
                "https://example.org/signIn", "https://example.org/account/two-step", "https://example.org/2-step-verification",
                "https://example.org/settings/two_factor", "https://example.org/settings/multi-factor", "https://example.org/one_time_code",
                "https://example.org/check_out", "https://example.org/%EF%BD%8C%EF%BD%8F%EF%BD%87%EF%BD%89%EF%BD%8E",
                "https://example.org/?next=/login", "https://example.org/account?action=checkout", "https://example.org/?page=payment",
                "https://example.org/docs?q=password#section", "https://example.org/search?q=sign+in",
                "https://shop.example.org/basket", "https://shop.example.org/bag", "https://shop.example.org/purchase/confirm",
                "https://example.org/verification", "https://example.org/donate", "https://example.org/billing/invoices/123",
                "https://example.org/sessions/new", "https://example.org/terminal", "https://example.org/ssh/host1", "https://example.org/console",
                "https://example.org/cloudshell/editor",
                "https://sede.gob.es/", "https://tax.gob.mx/", "https://portal.gov.example/", "https://www.example-gov.org/",
                "https://services.gouv.example/", "https://www.govt.example/", "https://base.mil.example/",
                "https://www.gov.br/", "https://www.bund.de/", "https://www.admin.ch/", "https://www.elster.de/", "https://www.skatteverket.se/",
                "https://www.digid.nl/", "https://www.service-public.fr/", "https://www.gov.sg/", "https://www.go.jp/", "https://www.gouv.qc.ca/",
                "https://shell.cloud.google.com/", "https://ssh.cloud.google.com/v2/ssh/projects/p", "https://console.aws.amazon.com/cloudshell/home",
                "https://shell.azure.com/", "https://vscode.dev/", "https://github.dev/owner/repo", "https://replit.com/@user/app",
                "https://app.repl.co/", "https://colab.research.google.com/drive/x", "https://stackblitz.com/edit/x", "https://codesandbox.io/p/x"] {
        try check(decision(url) == .blocked, "blocked by default (review I4/C3): " + url)
    }
    for (url, origin) in [("https://mail.google.com/mail/u/0/?compose=new#inbox", "https://mail.google.com"),
                          ("https://example.org/docs?q=weather#section", "https://example.org"),
                          ("https://www.google.com/search?q=weather+tomorrow", "https://www.google.com"),
                          ("https://docs.google.com/document/d/abc/edit?tab=t.0", "https://docs.google.com"),
                          ("https://github.com/owner/repo/issues/new", "https://github.com"),
                          ("https://news.example.com/2026/09/story?utm_source=x", "https://news.example.com"),
                          ("https://app.slack.com/client/T1/C2", "https://app.slack.com"),
                          ("https://notchase.com/", "https://notchase.com"),
                          ("https://www.governor.example/", "https://www.governor.example"),
                          ("http://localhost:3000/notes", "http://localhost:3000"),
                          ("https://mail.google.com:443/x", "https://mail.google.com"),
                          ("https://Chat.Example.ORG./c/123", "https://chat.example.org")] {
        try check(decision(url) == .allowed(origin: origin), "allowed as origin only: " + url + " -> " + origin)
    }
    for url in ["chrome://settings", "chrome-search://local-ntp", "chrome-extension://abcdefghijklmnop/popup.html", "devtools://devtools/bundled",
                "file:///Users/someone/notes.html", "about:blank", "data:text/html,hello", "blob:https://example.org/1", "javascript:alert(1)",
                "https://user:pw@example.org/", "https://bücher.example/", "view-source:https://example.org/", "https://under_score.example/", ""] {
        try check(decision(url) == .invalid, "not an http(s) origin: " + url)
    }
    // User edits: suffix matching, removable defaults, pinned domains, one click.
    var edited = list
    try check(edited.add("Example.ORG") && decision("https://a.b.example.org/x", edited) == .blocked && decision("https://example.org/", edited) == .blocked,
              "user-added domain blocks itself and its subdomains")
    try check(decision("https://example.org.evil.com/", edited) == .allowed(origin: "https://example.org.evil.com"), "suffix match is dot-anchored")
    try check(edited.removeDefault("coinbase.com") && decision("https://www.coinbase.com/home", edited) == .allowed(origin: "https://www.coinbase.com"),
              "a removed default no longer blocks")
    try check(edited.add("coinbase.com") && decision("https://www.coinbase.com/home", edited) == .blocked, "re-adding a removed default blocks again")
    try check(edited.removeDefault("vscode.dev") && decision("https://vscode.dev/", edited) == .allowed(origin: "https://vscode.dev"),
              "a web-terminal default can be removed like any other")
    try check(!edited.removeDefault("chase.com") && decision("https://chase.com/", edited) == .blocked, "app-wide sensitive domains cannot be removed here")
    try check(decision("https://news.example.net/story", edited, always: PrivacySettings.sensitiveDomains + ["news.example.net"]) == .blocked,
              "the global blocked-domain list always wins")
    try check(edited.blockSite(origin: "https://notes.example.com") && decision("https://notes.example.com/today", edited) == .blocked
              && decision("https://deep.notes.example.com/", edited) == .blocked && decision("https://example.com/", edited) == .allowed(origin: "https://example.com"),
              "one-click 'don't record this site' blocks that host and its subdomains only")
    try check(!edited.blockSite(origin: "chrome://settings") && !edited.add("not a domain") && !edited.add(""), "invalid sites are not added")
    try check(edited.removeAdded("example.org") && decision("https://example.org/", edited) == .allowed(origin: "https://example.org"), "user additions can be removed")
    let coded = try JSONDecoder().decode(BrowserTypingBlockList.self, from: JSONEncoder().encode(edited))
    try check(coded == edited, "block list round-trips")
    for (entry, normalized) in [("*.Example.org", "example.org"), (".example.org.", "example.org"), ("https://www.example.org/path", "www.example.org"),
                                ("example.org/path", "example.org"), ("  gov  ", "gov")] {
        try check(BrowserTypingSites.normalizedDomain(entry) == normalized, "block entry normalized: " + entry)
    }
    try check(BrowserTypingSites.normalizedDomain("exa mple.org") == nil && BrowserTypingSites.normalizedDomain("*") == nil, "invalid block entries refused")
}

/// Review I3/C2/C3: card, one-time-code, PIN and web-terminal fields are
/// denied by label, id or class. Deny-only.
private func checkFieldRules() throws {
    func denies(_ texts: [String] = [], _ ids: [String] = []) -> Bool {
        BrowserTypingFieldRules.denies(BrowserTypingFieldLabels(texts: texts, identifiers: ids))
    }
    for (texts, ids, name) in [(["Card number"], [], "Card number label"), ([], ["cc-number"], "cc-number id"), ([], ["ccNumber"], "ccNumber id"),
                               (["One-time code"], [], "One-time code label"), (["Enter the 6-digit one time code"], [], "one time code phrase"),
                               ([], ["otpInput"], "otpInput id"), (["PIN"], [], "PIN label"), (["Expiration date (MM/YY)"], [], "expiry label"),
                               (["MM / YY"], [], "expiry placeholder"), (["CVC"], [], "CVC"), (["Security code"], [], "security code"),
                               (["Name on card"], [], "name on card"), (["验证码"], [], "Chinese verification code"),
                               (["Two-factor authentication code"], [], "2FA label"), (["Sort code"], [], "UK sort code"),
                               (["Terminal input"], ["xterm-helper-textarea"], "xterm.js terminal"), ([], ["xterm-helper-textarea"], "xterm class alone"),
                               (["Editor content;Press Alt+F1 for Accessibility Options."], ["inputarea", "monaco-mouse-cursor-text"], "Monaco editor"),
                               ([], ["inputarea"], "Monaco class alone"), (["Password"], [], "password label"), (["pass\u{200B}word"], [], "zero-width split label"),
                               ([], ["one_time_code"], "one_time_code id"), ([], ["card_exp"], "card_exp id"),
                               // fix/web-textbox: Monaco's label alone still refuses (the phrase is judged in labels only).
                               (["Editor content;Press Alt+F1 for Accessibility Options."], [], "Monaco label alone"),
                               // The sensitive names, as a label, a placeholder or an id/class. Chrome's Accessibility
                               // tree exposes neither the input type nor `autocomplete`; pages that set
                               // autocomplete=cc-number or one-time-code usually name the field the same way.
                               ([], ["cc-number"], "autocomplete-style cc-number class"), ([], ["one-time-code"], "one-time-code id"),
                               (["cc-number"], [], "cc-number placeholder"), (["one-time-code"], [], "one-time-code label"),
                               (["Enter your password"], [], "label containing password"), ([], ["login-password"], "password id"),
                               (["Passcode"], [], "passcode"), ([], ["pin-input"], "pin id"), (["Enter PIN"], [], "PIN placeholder"),
                               (["OTP"], [], "OTP"), (["2FA code"], [], "2FA"), ([], ["cvv"], "cvv id"), (["CVC"], [], "CVC label"),
                               (["Card"], [], "card label"), (["SSN"], [], "SSN"), (["IBAN"], [], "IBAN"), (["Routing number"], [], "routing number"),
                               ([], ["mfaCode"], "mfaCode id")] as [([String], [String], String)] {
        try check(denies(texts, ids), "sensitive field denied: " + name)
    }
    for (texts, ids, name) in [(["Message Body"], [":r7", "Am", "Al", "editable"], "Gmail body"), (["Search mail"], ["gs_lc50"], "Gmail search"),
                               (["To recipients"], [], "To"), (["Subject"], ["subjectbox"], "Subject"), (["Write a comment…"], ["new_comment_field"], "comment"),
                               (["Search"], ["APjFqb"], "Google search"), ([], [], "no labels"),
                               // fix/web-textbox: X's post and reply box is a Draft.js editor (class
                               // `public-DraftEditor-content`), which once read as Monaco's "editor content".
                               (["Post text"], ["notranslate", "public-DraftEditor-content"], "X post box"),
                               ([], ["notranslate", "public-DraftEditor-content"], "unlabelled Draft.js box"),
                               ([], ["public-DraftEditor-content"], "Draft.js class alone"),
                               ([], ["ProseMirror"], "ProseMirror box"), ([], ["ql-editor"], "Quill box"), ([], ["search-input"], "search box class")]
                               as [([String], [String], String)] {
        try check(!denies(texts, ids), "ordinary field allowed: " + name)
    }
    try check(denies([String](repeating: "x", count: 65)) && denies([String(repeating: "a", count: 5000)]), "oversized label sets are denied")
    try check(BrowserTypingFieldRules.tokens("ccNumber-one_TimeCode") == ["cc", "number", "one", "time", "code"], "camelCase and separator tokens")
    // Promo/zip-code labels are not denied by the bare word "code"; ids with a "code" token are.
    try check(!denies(["Zip code"]) && denies([], ["zip-code"]), "the bare word 'code' denies in ids only (harness parity)")
}

private func checkWindowMatching() throws {
    let a = ChromeBounds(left: 0, top: 0, right: 100, bottom: 100), b = ChromeBounds(left: 10, top: 10, right: 110, bottom: 110)
    try check(ChromeWindowMatching.coversAll([], [a]) && ChromeWindowMatching.coversAll([a], [a, b]) && ChromeWindowMatching.coversAll([b, a], [a, b]),
              "every Accessibility window paired with a listed window")
    try check(!ChromeWindowMatching.coversAll([a, a], [a]) && !ChromeWindowMatching.coversAll([a, b], [a]) && !ChromeWindowMatching.coversAll([b], [a]),
              "an Accessibility window with no listed window of its own is unpaired")
    // X fits both listed windows, Y only the first. A greedy pass (X takes P)
    // would strand Y; augmenting paths pair X-Q and Y-P.
    let p = ChromeBounds(left: 0, top: 0, right: 100, bottom: 100), q = ChromeBounds(left: 1, top: 1, right: 101, bottom: 101)
    let x = ChromeBounds(left: 0.5, top: 0.5, right: 100.5, bottom: 100.5), y = ChromeBounds(left: -0.8, top: -0.8, right: 99.2, bottom: 99.2)
    try check(x.matches(p) && x.matches(q) && y.matches(p) && !y.matches(q), "matching fixture is the greedy trap")
    try check(ChromeWindowMatching.coversAll([x, y], [p, q]) && !ChromeWindowMatching.coversAll([x, y, y], [p, q, b]),
              "matching is one-to-one, not greedy")
}

private func checkJoin() throws {
    // Baseline: one normal window, Gmail compose.
    var w = FakeChromeWorld()
    var join = BrowserTypingJoin<FakeAXNode>()
    var r = w.run(join)
    guard let proof = r.proof else { throw MemError.invalid("FAILED: baseline join denied: \(String(describing: r.denial))") }
    try check(proof.origin == "https://mail.google.com" && proof.windowID == "101" && proof.tabID == "7" && proof.windowList == ["101"],
              "normal window, allowed site: origin-only proof")
    let fields = Mirror(reflecting: proof).children.map { "\($0.value)" }.joined(separator: "|")
    for leaked in ["compose", "/mail/u", "Inbox", "someone@example.org", "Gmail", "Message Body", "?", "#"] {
        try check(!fields.contains(leaked), "proof carries no title, path, query, fragment or label: " + leaked)
    }
    // Review C5: target facts and Automation once per join; 7 + 9 Apple Events for one window.
    try check(w.log.filter { $0 == "env:target" }.count == 1 && w.log.filter { $0 == "env:permission" }.count == 1
              && w.log.filter { $0 == "env:launch" }.count == 1 && w.aeCount == 16, "one signature check, one permission check, 16 Apple Events per join")
    // Mode is read for every window before any bounds, name, tab, URL or AX content.
    func modesFirst(_ log: [String], ids: [String]) -> Bool {
        guard let firstContent = log.firstIndex(where: FakeChromeWorld.isContent) else { return true }
        return ids.allSatisfy { id in log[..<firstContent].contains("ae:mode:" + id + "=normal") }
    }
    try check(modesFirst(w.log, ids: ["101"]), "mode read before any title, URL or AX content")
    // Labels are the last page read: after the URL agreement.
    try check((w.log.firstIndex { $0.hasPrefix("ax:url:") } ?? Int.max) < (w.log.firstIndex { $0.hasPrefix("ax:labels:") } ?? -1),
              "field labels read only after the page URLs agree")
    let again = w.run(join).proof
    try check(again.map { $0.sameBurst(as: proof) && $0.documentID == proof.documentID } == true, "unchanged page keeps its document and focus IDs")

    w = FakeChromeWorld(); w.addWindow("202", mode: "normal", front: false); w.addWindow("303", mode: "normal", front: false, bounds: ChromeBounds(left: 50, top: 50, right: 900, bottom: 800))
    join = BrowserTypingJoin<FakeAXNode>()
    r = w.run(join)
    try check(r.proof?.windowID == "101" && r.proof?.windowList == ["101", "202", "303"], "the focused window is found among several normal windows")
    try check(modesFirst(w.log, ids: ["101", "202", "303"]), "every window's mode read before anything else about any window")
    for id in ["101", "202", "303"] {
        let firstMode = w.log.firstIndex(of: "ae:mode:" + id + "=normal") ?? Int.max
        let firstOther = w.log.firstIndex { $0.hasPrefix("ae:name:" + id) || $0.hasPrefix("ae:url:" + id) || $0.hasPrefix("ae:activeTab:" + id) } ?? Int.max
        try check(firstMode < firstOther, "window \(id): mode before its name, tab or URL")
    }
    // Review C5: names are read only for windows with the focused window's bounds.
    try check(w.log.contains("ae:name:101") && !w.log.contains("ae:name:202") && !w.log.contains("ae:name:303"),
              "other windows' titles are never read")

    // Incognito anywhere: front, middle, back. Strict mode denies before any content read.
    for position in ["front", "middle", "back"] {
        w = FakeChromeWorld(); w.addWindow("202", mode: "normal", front: false)
        let incognito = FakeChromeWorld.Window(id: "666", mode: "incognito", bounds: ChromeBounds(left: 0, top: 25, right: 1440, bottom: 900),
                                               name: "Private page title", tab: "66", url: "https://private.example.net/")
        w.windows.insert(incognito, at: position == "front" ? 0 : position == "middle" ? 1 : 2)
        r = w.run(BrowserTypingJoin<FakeAXNode>())
        try check(r.denial == .notNormal, "incognito window \(position): denied")
        try check(!w.log.contains(where: FakeChromeWorld.isContent), "incognito window \(position): zero titles, URLs, bounds or AX content read")
    }
    // Guest reports "incognito" (Chromium runs Guest off the record); anything not exactly "normal" is denied.
    for mode in ["incognito", "guest", "Normal", "normal ", "", nil] as [String?] {
        w = FakeChromeWorld(); w.addWindow("777", mode: mode, front: false, name: "Guest page")
        r = w.run(BrowserTypingJoin<FakeAXNode>())
        try check(r.denial == .notNormal && !w.log.contains(where: FakeChromeWorld.isContent), "Guest/unknown mode '\(mode ?? "nil")' denied before content")
    }
    // Preconditions deny before any Apple Event.
    let preconditions: [(String, (FakeChromeWorld) -> Void, BrowserTypingDenial)] = [
        ("feature off", { $0.enabled = false }, .disabled),
        ("Chrome < 151", { $0.facts.bundleVersion = "150.0.7871.99" }, .untrustedTarget),
        ("unsigned 'Chrome'", { $0.facts.signatureValid = false }, .untrustedTarget),
        ("a second Chrome process (another profile directory)", { $0.facts.instances = 2 }, .untrustedTarget),
        ("Automation not granted", { $0.permitted = false }, .noPermission),
        ("Spotlight-style focus: Chrome frontmost, keys go to another process", { $0.systemFocused = 999 }, .notFocused),
        ("another app frontmost", { $0.frontmost = 999; $0.systemFocused = 999 }, .notFocused),
        ("secure input on", { $0.secure = true }, .notFocused),
    ]
    for (name, setup, denial) in preconditions {
        w = FakeChromeWorld(); setup(w)
        r = w.run(BrowserTypingJoin<FakeAXNode>())
        try check(r.denial == denial && w.aeCount == 0 && !w.log.contains(where: FakeChromeWorld.isContent), name + ": denied with zero Apple Events")
    }
    // Window list problems.
    w = FakeChromeWorld(); w.windows = []
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .windowList, "no windows: denied")
    w = FakeChromeWorld(); w.addWindow("101", mode: "normal", front: false)
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .windowList, "duplicate window IDs: denied")
    w = FakeChromeWorld(); for i in 0..<64 { w.addWindow("9\(i)", mode: "normal", front: false, onThisSpace: false) }
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .windowList, "more than 64 windows: denied")
    // Timeouts at each step fail closed.
    for (kind, denial) in [("ids", BrowserTypingDenial.windowList), ("mode", .notNormal), ("bounds", .window), ("name", .window), ("activeTab", .url), ("url", .url)] {
        w = FakeChromeWorld(); w.failing = [kind]
        try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == denial, "Chrome slow to answer '\(kind)': denied")
    }
    // AE <-> AX window match.
    // claude/typing-1004: a name mismatch decides only among windows with the same bounds (one window: its bounds bind it).
    w = FakeChromeWorld(); w.window.title = "Inbox (4) - someone@example.org - Gmail"
    w.addWindow("202", mode: "normal", front: false, bounds: FakeChromeWorld.bounds, name: "Elsewhere", url: "https://other.example.org/", onThisSpace: false)
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .window, "window name mismatch with a same-bounds window elsewhere: denied")
    w = FakeChromeWorld(); w.window.title = "Inbox (4) - someone@example.org - Gmail"
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).proof != nil, "window name mismatch, one window with those bounds: allowed on its bounds")
    try checkWindowTitleSuffix()
    try checkSwitchShortcuts()
    try checkFormScan()
    try checkBoundedFormSearch()
    try checkLargePageRecovery()
    try checkRealAppleEventLatency()
    try checkDiagnosticsAllowlist()
    w = FakeChromeWorld(); w.window.frame = ChromeBounds(x: 5, y: 25, width: 1440, height: 875)
    r = w.run(BrowserTypingJoin<FakeAXNode>())
    try check(r.denial == .unlistedWindow && !w.log.contains(where: FakeChromeWorld.isPageContent), "window bounds mismatch: no listed window for it, denied before any title")
    w = FakeChromeWorld(); w.window.frame = ChromeBounds(x: 0.6, y: 24.5, width: 1440, height: 875.4)
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).proof != nil, "bounds within 1 pt match")
    w = FakeChromeWorld(); w.window.minimized = true
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .window, "minimized window: denied")
    w = FakeChromeWorld(); w.axWindow = nil
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .window, "no focused AX window: denied")
    w = FakeChromeWorld(); w.window.subrole = "AXDialog"
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .window, "focused window is not a standard window: denied")
    w = FakeChromeWorld(); w.addWindow("202", mode: "normal", front: false, bounds: FakeChromeWorld.bounds, name: FakeChromeWorld.title, url: FakeChromeWorld.url)
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .ambiguousWindow, "two windows with the same bounds (this Space): denied")
    w = FakeChromeWorld(); w.addWindow("202", mode: "normal", front: false, bounds: FakeChromeWorld.bounds, name: FakeChromeWorld.title, url: FakeChromeWorld.url,
                                       onThisSpace: false)
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .ambiguousWindow, "two listed windows with the same bounds and name (other Space): denied")
    // The field.
    // fix/web-textbox: an AXComboBox is refused unless it is its own editable root (checkUnmarkedTextBoxes).
    for (role, subrole) in [("AXTextField", "AXSecureTextField"), ("AXWebArea", ""), ("AXButton", ""), ("AXComboBox", ""), ("AXTextArea", "AXSecure"),
                            ("AXGroup", ""), ("AXStaticText", ""), ("AXLink", "")] {
        w = FakeChromeWorld(); w.field.role = role; w.field.subrole = subrole
        try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .field, "field \(role)/\(subrole): denied")
    }
    w = FakeChromeWorld(); w.field.subrole = "AXSearchField"; w.field.role = "AXTextField"; w.field.labels = BrowserTypingFieldLabels(texts: ["Search mail"], identifiers: [])
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).proof != nil, "plain search field on an allowed page is a text field")
    w = FakeChromeWorld(); w.field.owner = 999
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .field, "focused element owned by another process: denied")
    // Review I3/C2/C3: card, code, terminal fields on an allowed page.
    for (texts, ids) in [(["Card number"], ["cc-number"]), (["One-time code"], []), ([], ["otp"]), (["Terminal input"], ["xterm-helper-textarea"]),
                         (["Editor content;Press Alt+F1 for Accessibility Options."], ["inputarea", "monaco-mouse-cursor-text"])] as [([String], [String])] {
        w = FakeChromeWorld(); w.field.labels = BrowserTypingFieldLabels(texts: texts, identifiers: ids)
        r = w.run(BrowserTypingJoin<FakeAXNode>())
        try check(r.denial == .sensitiveField && w.aeCount == 7, "sensitive field \(texts + ids): denied after a single read")
    }
    w = FakeChromeWorld(); w.field.labels = nil
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .field, "field labels unreadable: denied")
    // iframe / two web areas; address bar (no web area); detached field.
    w = FakeChromeWorld()
    let frame = FakeAXNode("iframe-web", role: "AXWebArea", parent: w.group, owner: FakeChromeWorld.chromePID)
    frame.url = "https://payments.example.com/card"
    w.field.parent = FakeAXNode("iframe-group", role: "AXGroup", parent: frame, owner: FakeChromeWorld.chromePID)
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .frame, "field inside an iframe (two AXWebAreas): denied")
    w = FakeChromeWorld(); w.field.parent = FakeAXNode("toolbar", role: "AXToolbar", parent: w.window, owner: FakeChromeWorld.chromePID)
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .frame, "address bar (no web page above the field): denied")
    w = FakeChromeWorld(); w.scroll.parent = nil
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .frame, "ancestry that never reaches the window: denied")
    w = FakeChromeWorld(); w.scroll.parent = w.group
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .frame, "ancestry cycle: denied")
    // URL agreement.
    w = FakeChromeWorld(); w.web.url = "https://mail.google.com/mail/u/1/?compose=new"
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .url, "AE and AX pages differ (navigation pending): denied")
    w = FakeChromeWorld(); w.web.url = "https://evil.example/mail/u/0/?compose=new"
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .url, "AE and AX origins differ: denied")
    w = FakeChromeWorld(); w.windows[0].url = "chrome://newtab/"; w.web.url = "chrome://newtab/"
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .url, "chrome:// page: denied")
    w = FakeChromeWorld(); w.web.url = nil
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .url, "no AXURL: denied")
    // Blocked site: denied, and no confirming second read.
    w = FakeChromeWorld(); w.windows[0].url = "https://secure.chase.com/web/auth/dashboard"; w.web.url = w.windows[0].url
    r = w.run(BrowserTypingJoin<FakeAXNode>())
    try check(r.denial == .blockedSite && w.aeCount == 7, "blocked subdomain: denied after a single read")
    w = FakeChromeWorld()
    var userList = BrowserTypingBlockList(); userList.blockSite(origin: "https://mail.google.com")
    try check(w.run(BrowserTypingJoin<FakeAXNode>(), blockList: userList).denial == .blockedSite, "one-click blocked site: denied")
    w = FakeChromeWorld()
    try check(w.run(BrowserTypingJoin<FakeAXNode>(), alwaysBlocked: ["google.com"]).denial == .blockedSite, "global blocked domain wins over the Chrome list")
    // Double read: anything that changes between or during the reads is denied.
    let races: [(String, (FakeChromeWorld) -> Void)] = [
        ("focus moves to another field", { $0.axFocus = FakeAXNode("other-field", role: "AXTextField", parent: $0.group, owner: FakeChromeWorld.chromePID) }),
        ("URL changes (same origin)", { $0.windows[0].url = "https://mail.google.com/mail/u/0/?search=x"; $0.web.url = $0.windows[0].url }),
        ("tab switch", { $0.windows[0].tab = "8" }),
        ("incognito window opens", { $0.addWindow("666", mode: "incognito") }),
        ("incognito window opens, not yet listed by Apple Events", { w in
            w.axWindows?.append(w.axOnlyWindow("incognito-unlisted", frame: ChromeBounds(left: 300, top: 200, right: 900, bottom: 800), title: "Private")) }),
        ("a normal window opens on another Space", { $0.addWindow("505", mode: "normal", front: false, onThisSpace: false) }),
        ("Spotlight takes focus", { $0.systemFocused = 999 }),
        ("Chrome relaunched", { $0.facts.launchIdentity = "4242:1790000999:com.google.Chrome" }),
        ("focused window replaced", { let other = $0.axOnlyWindow("window-101b", frame: $0.window.frame!, title: $0.window.title!)
            $0.axWindow = other; $0.axWindows = [other] }),
        ("field becomes a card field", { $0.field.labels = BrowserTypingFieldLabels(texts: ["Card number"], identifiers: []) }),
    ]
    // 7 Apple Events in the first read, 9 in the confirming read (its last
    // two are the re-check). A change at 8 or 14 falls between two reads of
    // every fact; at 7 and 3 only facts the first read already took are
    // stale (a change seen consistently by both reads is not a race).
    let afterFirstRead: Set<String> = ["tab switch", "window retitled", "incognito window opens", "incognito window opens, not yet listed by Apple Events",
        "a normal window opens on another Space", "Spotlight takes focus", "Chrome relaunched", "focused window replaced", "field becomes a card field"]
    let afterWindowReads: Set<String> = ["incognito window opens", "incognito window opens, not yet listed by Apple Events",
        "a normal window opens on another Space", "Spotlight takes focus", "Chrome relaunched", "focused window replaced", "field becomes a card field"]
    // At 14 the confirming read has already compared names and title; a
    // retitle then changes no fact the join relies on.
    let lateInConfirming = Set(races.map(\.0)).subtracting(["window retitled"])
    for (at, when, only) in [(8, "at the start of the confirming read", nil), (14, "during the confirming read, before its re-check", lateInConfirming),
                             (7, "after the first read's last Apple Event", afterFirstRead),
                             (3, "between the Accessibility window reads and the list re-check", afterWindowReads)] as [(Int, String, Set<String>?)] {
        for (name, change) in races where only?.contains(name) ?? true {
            w = FakeChromeWorld()
            w.onAppleEvent = { _, n in if n == at { change(w) } }
            r = w.run(BrowserTypingJoin<FakeAXNode>())
            try check(r.proof == nil, "\(name) \(when): denied (\(String(describing: r.denial)))")
        }
    }
    // claude/axjoin-1005 (owner laptop 10/04, X: a title rewritten between the reads refused `changed`): with exactly one
    // listed window of the focused window's bounds, the title binds nothing (step 9 binds by bounds); window, tab, both
    // addresses, web area and field are still the same. A retitle between the reads is then allowed, with no place title
    // (site only). With a same-bounds window elsewhere the title chose the window, and a retitle still refuses
    // (ChromeAXJoinChecks).
    for at in [7, 8, 14] {
        w = FakeChromeWorld()
        w.onAppleEvent = { _, n in if n == at { w.windows[0].name = "Sent - Gmail"; w.window.title = "Sent - Gmail" } }
        r = w.run(BrowserTypingJoin<FakeAXNode>())
        try check(r.proof?.windowID == "101" && r.proof?.pageTitle == "", "window retitled at event \(at), one same-bounds window: allowed, site only (\(r))")
    }
    // Incognito opening mid-read is caught by the list re-check, before any title or URL.
    // fix/chrome-root: the list re-check is the 4th event now (ids, modes, allBounds, ids).
    w = FakeChromeWorld()
    w.onAppleEvent = { _, n in if n == 4 { w.addWindow("666", mode: "incognito") } }
    r = w.run(BrowserTypingJoin<FakeAXNode>())
    try check(r.denial == .changed && !w.log.contains(where: FakeChromeWorld.isPageContent), "incognito opened mid-read: denied before any title, tab or URL")
    w = FakeChromeWorld()
    w.onAppleEvent = { _, n in if n == 3 { w.addWindow("666", mode: "incognito") } }
    r = w.run(BrowserTypingJoin<FakeAXNode>())
    try check(r.proof == nil && !w.log.contains(where: FakeChromeWorld.isPageContent), "incognito opened during the bounds read: denied before any title, tab or URL (\(String(describing: r.denial)))")
    // Time budget: the whole double read within `joinBudgetNanoseconds` (fix/chrome-root: 500 ms; was 150 ms).
    w = FakeChromeWorld(); w.tick = 40_000_000
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .timeout, "double read over the 500 ms budget (16 events of 40 ms): denied")
    w = FakeChromeWorld(); w.tick = 5_000_000
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).proof != nil, "double read within budget: allowed")
}

/// fix/web-textbox (the owner, 2026-09-28: typing on X and other websites was
/// thrown away; "include text boxes if they are unmarked"). A plain, non-secure
/// text box is typed whether or not it has a label, placeholder, id or class:
/// `<input type=text|search>`, `<textarea>`, a contenteditable (role=textbox)
/// root, an editable `<input role=combobox>` search box, and X's post box (a
/// Draft.js editor). Every secure and sensitive refusal holds, with or without
/// a label, and a box whose kind can't be proven stays refused.
private func checkUnmarkedTextBoxes() throws {
    let pid = FakeChromeWorld.chromePID
    func world(_ role: String, subrole: String = "", labels: BrowserTypingFieldLabels? = BrowserTypingFieldLabels(texts: [], identifiers: []),
               url: String = "https://notes.example.org/pad/7") -> FakeChromeWorld {
        let w = FakeChromeWorld(); w.windows[0].url = url; w.web.url = url
        w.field.role = role; w.field.subrole = subrole; w.field.labels = labels
        if role == "AXComboBox" { w.field.editableAncestor = w.field }
        return w
    }
    let defaults = BrowserTypingSiteRules(choices: TypedCategoryChoices(), expanded: true)
    let messages = BrowserTypingSiteRules(choices: TypedCategoryChoices(messagesAndEmail: true), expanded: true)
    let messagesOff = BrowserTypingSiteRules(choices: TypedCategoryChoices(messagesAndEmail: false), expanded: true)
    func run(_ w: FakeChromeWorld, _ rules: BrowserTypingSiteRules) -> BrowserTypingJoinResult {
        BrowserTypingJoin<FakeAXNode>().join(environment: w.environment, appleEvents: w.ae, accessibility: w.access, blockList: rules.blockList,
                                             alwaysBlocked: rules.alwaysBlocked, sites: rules.permits(url:), field: rules.permits(url:field:))
    }
    // Unmarked boxes on an allowed page, with the default site choices.
    // Codex 06:10: an unlabelled textarea or contenteditable box (C03), X's Draft.js box without its label, is
    // refused as `field` (a stated loss); with a label it is typed.
    for ids in [[String](), ["notranslate", "public-DraftEditor-content"], ["ProseMirror"]] {
        for texts in [[String](), ["  "], ["\u{200B}"]] {
            let r = run(world("AXTextArea", labels: BrowserTypingFieldLabels(texts: texts, identifiers: ids)), defaults)
            try check(r.denial == .field, "Codex 06:10: an unlabelled text area or contenteditable box \(ids) \(texts): field (\(String(describing: r.denial)))")
        }
    }
    for texts in [["Post text"], ["Message Body"], ["Notes"], ["Document content"], ["Write a comment…"]] {
        let r = run(world("AXTextArea", labels: BrowserTypingFieldLabels(texts: texts, identifiers: [])), defaults)
        try check(r.proof?.role == "AXTextArea", "Codex 06:10: a labelled composer \(texts): typed (\(String(describing: r.denial)))")
    }
    // Codex 06:10: a box labelled only with a generic "Number" or "Value" is a suspicious code field.
    for texts in [["Number"], ["Value"], ["Enter a value"], ["Number:"], ["Number", "Number"], ["Your number"], ["ＮＵＭＢＥＲ"]] {
        for role in ["AXTextField", "AXTextArea"] {
            try check(run(world(role, labels: BrowserTypingFieldLabels(texts: texts, identifiers: [])), defaults).denial == .sensitiveField,
                      "Codex 06:10: \(role) labelled only \(texts): sensitiveField")
        }
    }
    // Review Q5-3: the widened generic rule and identity phrases.
    for texts in [["Numbers"], ["Values"], ["No."], ["Nr."], ["Num"], ["#"], ["Nº"], ["№"], ["Value 1"], ["Number #2"], ["Number", "e.g. 42"],
                  ["Número"], ["Numéro"], ["Nummer"], ["Valor"], ["Valeur"], ["Wert"], ["номер"], ["番号"], ["号码"],
                  ["ID"], ["Key"], ["Token"], ["Input"], ["Answer"], ["Entry"], ["Your answer"],
                  ["ID number"], ["National ID"], ["Tax number"], ["Social insurance number"], ["National insurance number"],
                  ["License number"], ["Driver's licence number"], ["Personal number"], ["Enter your national ID"],
                  // Review Q6: the Q5 holes.
                  ["Identification number"], ["Identity number"], ["National identification number"], ["Personal ID"],
                  ["Licence no."], ["License No."], ["Tax no."], ["Personal no."], ["ID no."], ["User ID"], ["Login ID"], ["Member ID"],
                  ["Customer ID"], ["UserID"], ["Personnummer"], ["Aadhaar"], ["Aadhaar number"], ["NINO"], ["TFN"], ["BSN"], ["NRIC"],
                  ["PESEL"], ["CURP"], ["CPF"], ["Numéro de sécurité sociale"], ["Número de la Seguridad Social"],
                  ["Sozialversicherungsnummer"], ["Codice fiscale"], ["Steuernummer"], ["Ihre Steuernummer"]] {
        for role in ["AXTextField", "AXTextArea"] {
            try check(run(world(role, labels: BrowserTypingFieldLabels(texts: texts, identifiers: [])), defaults).denial == .sensitiveField,
                      "Q5-3: \(role) labelled \(texts): sensitiveField")
        }
    }
    // Review Q5-1: punctuation or emoji alone is no label (field); a letter or a digit is.
    for texts in [["*"], ["-"], ["…"], ["🔑"], ["* :"], ["—", "•"]] {
        for role in ["AXTextField", "AXTextArea", "AXComboBox"] {
            let v = world(role, labels: BrowserTypingFieldLabels(texts: texts, identifiers: []))
            try check(run(v, defaults).denial == .field, "Q5-1: \(role) labelled only \(texts): field")
        }
    }
    for texts in [["A"], ["Q1"], ["🔑 Notes"], ["* Name"], ["Notes", "—"]] {
        try check(run(world("AXTextField", labels: BrowserTypingFieldLabels(texts: texts, identifiers: [])), defaults).proof != nil,
                  "Q5-1: a label with a letter or a digit \(texts): typed")
    }
    for texts in [["Phone number"], ["Order number"], ["Value (USD)"], ["Number of guests"], ["Name", "Value"], ["Street number"],
                  ["Write your answer to the quiz"], ["Guest entry note"], ["Keyword"], ["Input your story"], ["Valid number of seats"],
                  ["Paid number"], ["Customer name"], ["Member since"], ["Tax notes"], ["Personal note"], ["Login email"],
                  ["Sin gluten"], ["Identity"]] {
        try check(run(world("AXTextField", labels: BrowserTypingFieldLabels(texts: texts, identifiers: [])), defaults).proof != nil,
                  "Codex 06:10: \(texts) is not a generic label only: typed")
    }
    // fix/chrome-capture (QF-4, option a): a one-line box with no label, description or placeholder is refused unless
    // it is a search field (the p11 fixture's P04 curtext, P08 x1 cc-number and P12 x2 one-time-code: Chrome exposes
    // neither `autocomplete` nor the input type). A labelled one (p01 "Name of thing", p05 "First", p09 To/Subject,
    // X's "Search query" combo box) is typed as before.
    for (role, ids, name) in [("AXTextField", [String](), "input type=text"), ("AXTextField", ["x1"], "P08 (autocomplete=cc-number, id only)"),
                              ("AXTextField", ["x2"], "P12 (autocomplete=one-time-code, id only)"), ("AXTextField", ["curtext"], "P04 (password shown as text)"),
                              ("AXComboBox", [], "input role=combobox"), ("AXTextField", [], "input type=search (review Q4-1)")] as [(String, [String], String)] {
        for texts in [[String](), ["   "], [" \n"]] {
            let subrole = name.hasPrefix("input type=search") ? "AXSearchField" : ""
            let r = run(world(role, subrole: subrole, labels: BrowserTypingFieldLabels(texts: texts, identifiers: ids)), defaults)
            try check(r.denial == .field, "QF-4: unlabelled one-line \(name) \(texts): refused, can't prove (field) (\(String(describing: r.denial)))")
        }
    }
    for (role, subrole, texts, name) in [("AXTextField", "", ["Name of thing"], "p01 label"), ("AXTextField", "", ["First"], "p05 label"),
                                         ("AXTextField", "", ["To"], "p09 To"), ("AXTextField", "", ["Subject"], "p09 Subject"),
                                         ("AXTextField", "", ["Zip code"], "Zip code"), ("AXComboBox", "", ["Search query", "Search"], "X search"),
                                         ("AXTextField", "AXSearchField", ["Search"], "C04 search field (aria-label and placeholder)"),
                                         ("AXTextField", "", ["Country code"], "Country code"), ("AXTextField", "", ["Postal code"], "Postal code"),
                                         ("AXTextField", "", ["(555) 555-0100"], "phone placeholder with parentheses")]
                                         as [(String, String, [String], String)] {
        let r = run(world(role, subrole: subrole, labels: BrowserTypingFieldLabels(texts: texts, identifiers: [])), defaults)
        try check(r.proof?.role == role, "QF-4: \(name) \(texts) still typed (\(String(describing: r.denial)))")
    }
    // QF-4: a placeholder that is a number or code mask, or names the digits of a code, is a sensitive field.
    for texts in [["1234 5678 9012 3456"], ["•••• •••• •••• ••••"], ["000000"], ["XXX-XX-XXXX"], ["123-456"], ["12/26"],
                  ["Enter the 6-digit code"], ["4 digits"], ["Name", "••••••"]] {
        try check(run(world("AXTextField", labels: BrowserTypingFieldLabels(texts: texts, identifiers: [])), defaults).denial == .sensitiveField,
                  "QF-4: a field whose label or placeholder is \(texts): refused as a sensitive field")
        try check(run(world("AXTextArea", labels: BrowserTypingFieldLabels(texts: texts, identifiers: [])), defaults).denial == .sensitiveField,
                  "QF-4: a text area whose label or placeholder is \(texts): refused too")
    }
    // Review Q4 item 2: the same masks written with full-width digits or other bullets.
    for texts in [["１２３４ ５６７８ ９０１２ ３４５６"], ["０００ ０００"], ["∗∗∗∗∗∗"], ["＊＊＊＊"], ["◦◦◦◦ ◦◦◦◦"], ["12\u{200B}34 5678"]] {
        try check(run(world("AXTextField", labels: BrowserTypingFieldLabels(texts: texts, identifiers: [])), defaults).denial == .sensitiveField,
                  "QF-4 (Q4 item 2): a mask \(texts): refused as a sensitive field")
    }
    // Review Q4 item 3: the label word "code" refuses unless an ordinary code's word comes right before it.
    for texts in [["Enter code"], ["Enter the 6-digit code"], ["Code"], ["Your code"], ["Access codes"], ["Gift code"], ["Enter code", "Name"]] {
        for role in ["AXTextField", "AXTextArea"] {
            try check(run(world(role, labels: BrowserTypingFieldLabels(texts: texts, identifiers: [])), defaults).denial == .sensitiveField,
                      "QF-4 (Q4 item 3): \(role) labelled \(texts): refused as a sensitive field")
        }
    }
    for texts in [["Zip code"], ["Promo code"], ["Coupon code"], ["Discount code"], ["Referral code"], ["Invite code"], ["Country code"],
                  ["Area code"], ["Post code"], ["Postal code"], ["Zip/postal code"], ["ZIP-code"]] {
        try check(run(world("AXTextField", labels: BrowserTypingFieldLabels(texts: texts, identifiers: [])), defaults).proof != nil,
                  "QF-4 (Q4 item 3): an ordinary code \(texts): typed")
    }
    for texts in [["2 guests"], ["Digital camera"], ["May 2026"], ["Room 12"], ["x"], ["12"], ["+1 555"]] {
        try check(run(world("AXTextField", labels: BrowserTypingFieldLabels(texts: texts, identifiers: [])), defaults).proof != nil,
                  "QF-4: an ordinary label or placeholder \(texts): typed")
    }
    // QF-4: the light per-key check refuses too, if the label is gone since the full join (a script cleared it).
    do {
        let w = world("AXTextField", labels: BrowserTypingFieldLabels(texts: ["Name of thing"], identifiers: []))
        let join = BrowserTypingJoin<FakeAXNode>()
        guard join.join(environment: w.environment, appleEvents: w.ae, accessibility: w.access, blockList: BrowserTypingBlockList()).proof != nil else {
            throw MemError.invalid("FAILED: QF-4 light setup: labelled field denied")
        }
        w.clock += 5_000_000
        try check(join.light(environment: w.environment, appleEvents: w.ae, accessibility: w.access, blockList: BrowserTypingBlockList())?.proof?.light == true,
                  "QF-4: a labelled one-line field: the light check admits the next key")
        w.field.labels = BrowserTypingFieldLabels(texts: [], identifiers: ["x1"])
        try check(join.light(environment: w.environment, appleEvents: w.ae, accessibility: w.access, blockList: BrowserTypingBlockList()) == nil,
                  "QF-4: its label gone: the light check can't vouch for the key")
    }
    // X's post and reply box: a Draft.js contenteditable, with or without its label.
    // (Codex 06:10: an unlabelled Draft.js box is refused as `field`; checked below.)
    for labels in [BrowserTypingFieldLabels(texts: ["Post text"], identifiers: ["notranslate", "public-DraftEditor-content"]),
                   BrowserTypingFieldLabels(texts: ["Post text"], identifiers: [])] {
        let w = world("AXTextArea", labels: labels, url: "https://x.com/home")
        try check(run(w, messages).proof?.role == "AXTextArea", "X post box \(labels.texts + labels.identifiers): allowed with Messages and email on")
        // X counts as Messages and email (review F1): on by default (fix/messaging-default); turned off, nothing on X is typed.
        try check(run(w, defaults).proof?.role == "AXTextArea", "X post box \(labels.texts + labels.identifiers): allowed with the default switches")
        try check(run(world("AXTextArea", labels: labels, url: "https://x.com/home"), messagesOff).denial == .blockedSite,
                  "X post box \(labels.texts + labels.identifiers): Messages and email off: refused as a site whose switch is off")
    }
    let xSearch = world("AXComboBox", labels: BrowserTypingFieldLabels(texts: ["Search query", "Search"], identifiers: []), url: "https://x.com/explore")
    try check(run(xSearch, messages).proof?.role == "AXComboBox", "X search box (an editable combo box): allowed with Messages and email on")
    // Never secure: an unmarked password field is refused, however it is reported.
    try check(run(world("AXTextField", subrole: "AXSecureTextField"), messages).denial == .field, "unmarked password field (AXSecureTextField): refused")
    // Chromium reports the secure subrole for a text field; a password `<input role=combobox>` is AXComboBox
    // with no secure subrole. Its guard is macOS secure input (below), not this subrole.
    try check(run(world("AXComboBox", subrole: "AXSecureTextField"), messages).denial == .field,
              "combo box reporting a secure subrole (not the guard; a Chrome that does report it): refused")
    try check(run(world("AXSecureTextField"), messages).denial == .field, "unmarked secure role: refused")
    for role in ["AXTextField", "AXTextArea", "AXComboBox"] {
        let w = world(role); w.secure = true
        let r = run(w, messages)
        try check(r.denial == .notFocused && !w.log.contains(where: FakeChromeWorld.isContent),
                  "unmarked \(role) while macOS secure input is on (Chrome's password fields; for AXComboBox with no secure subrole, a password <input role=combobox>): refused before any page read")
    }
    // A combo box counts only when it is its own editable root: a select-only drop-down, a
    // wrapper around another node, or an editable ancestor that can't be read stay refused.
    var w = world("AXComboBox"); w.field.editableAncestor = nil
    try check(run(w, messages).denial == .field, "combo box with no editable ancestor (select-only drop-down, or unreadable): refused")
    w = world("AXComboBox"); w.field.editableAncestor = FakeAXNode("inner-input", role: "AXTextField", parent: w.field, owner: pid)
    try check(run(w, messages).denial == .field, "combo box whose editable root is another node (an ARIA 1.0 wrapper): refused")
    // Boxes of other or unknown kinds stay refused, labelled or not.
    for role in ["AXGroup", "AXWebArea", "AXButton", "AXStaticText", "AXPopUpButton", "AXListBox", "AXMenuItem", ""] {
        try check(run(world(role), messages).denial == .field, "unmarked focus of kind '\(role)': refused")
    }
    // Labels that can't be read are never read as unmarked.
    try check(run(world("AXTextArea", labels: nil), messages).denial == .field, "labels unreadable: refused, not taken as unmarked")
    // One-time codes named without "one-time" or "2FA" as its own word (fix/web-textbox review).
    for labels in [BrowserTypingFieldLabels(texts: ["Authenticator code"], identifiers: []),
                   BrowserTypingFieldLabels(texts: ["Enter the code from your authenticator app"], identifiers: []),
                   BrowserTypingFieldLabels(texts: ["2-Step Verification code"], identifiers: []),
                   BrowserTypingFieldLabels(texts: ["Two-step code"], identifiers: []),
                   BrowserTypingFieldLabels(texts: ["Your 2FA code"], identifiers: []),
                   BrowserTypingFieldLabels(texts: [], identifiers: ["authenticatorCode"])] {
        try check(run(world("AXTextField", labels: labels), messages).denial == .sensitiveField,
                  "one-time code box named \(labels.texts + labels.identifiers): refused as a sensitive field")
    }
    // "2 step" in class names is not judged (hashed classes); ordinary boxes stay typed.
    for labels in [BrowserTypingFieldLabels(texts: [], identifiers: ["mt-2", "step-body"]), BrowserTypingFieldLabels(texts: ["Zip code"], identifiers: []),
                   BrowserTypingFieldLabels(texts: ["Promo code"], identifiers: [])] {
        // Classes are judged with a label present (an unlabelled box is refused on its own, QF-4).
        let named = labels.texts.isEmpty ? BrowserTypingFieldLabels(texts: ["Notes"], identifiers: labels.identifiers) : labels
        try check(run(world("AXTextField", labels: named), messages).proof != nil, "ordinary box named \(named.texts + named.identifiers): typed")
    }
    // Sensitive names still refuse (label, placeholder, id or class).
    for labels in [BrowserTypingFieldLabels(texts: ["Password"], identifiers: []), BrowserTypingFieldLabels(texts: ["Enter your password"], identifiers: []),
                   BrowserTypingFieldLabels(texts: [], identifiers: ["cc-number"]), BrowserTypingFieldLabels(texts: [], identifiers: ["one-time-code"]),
                   BrowserTypingFieldLabels(texts: ["Card number"], identifiers: []), BrowserTypingFieldLabels(texts: ["PIN"], identifiers: []),
                   BrowserTypingFieldLabels(texts: [], identifiers: ["otp"]), BrowserTypingFieldLabels(texts: ["CVV"], identifiers: [])] {
        for role in ["AXTextField", "AXTextArea", "AXComboBox"] {
            try check(run(world(role, labels: labels), messages).denial == .sensitiveField,
                      "\(role) named \(labels.texts + labels.identifiers): refused as a sensitive field")
        }
    }
    // Site rules still refuse an unmarked box: the block list, sign-in pages, a site
    // the person blocked, and any Incognito window.
    for url in ["https://secure.chase.com/web/auth/dashboard", "https://accounts.google.com/", "https://example.org/login", "https://docs.google.com/document/d/1"] {
        // (Labelled: an unlabelled box is refused as `field` before the site's rule is judged, Codex 06:10.)
        let notes = BrowserTypingFieldLabels(texts: ["Notes"], identifiers: [])
        try check(run(world("AXTextArea", labels: notes, url: url), messages).denial == .blockedSite, "unmarked box on \(url): refused")
        try check(run(world("AXTextArea", url: url), messages).proof == nil, "unlabelled box on \(url): refused")
    }
    let blocked = BrowserTypingSiteRules(choices: TypedCategoryChoices(messagesAndEmail: true), expanded: true)
    blocked.blockList.blockSite(origin: "https://notes.example.org")
    try check(run(world("AXTextArea", labels: BrowserTypingFieldLabels(texts: ["Notes"], identifiers: [])), blocked).denial == .blockedSite,
              "unmarked box on a site the person blocked: refused")
    w = world("AXTextArea"); w.addWindow("666", mode: "incognito", front: false)
    try check(run(w, messages).denial == .notNormal && !w.log.contains(where: FakeChromeWorld.isContent),
              "unmarked box with an Incognito window open: refused before any page read")
    // An unmarked box inside an iframe stays refused.
    w = world("AXTextArea")
    let frame = FakeAXNode("iframe-web", role: "AXWebArea", parent: w.group, owner: pid); frame.url = "https://widgets.example.com/"
    w.field.parent = FakeAXNode("iframe-group", role: "AXGroup", parent: frame, owner: pid)
    try check(run(w, messages).denial == .frame, "unmarked box inside an iframe: refused")
    // The light per-key check proves the combo box is still its own editable root.
    w = world("AXComboBox", labels: BrowserTypingFieldLabels(texts: ["Search query"], identifiers: []))
    let join = BrowserTypingJoin<FakeAXNode>()
    guard join.join(environment: w.environment, appleEvents: w.ae, accessibility: w.access, blockList: BrowserTypingBlockList()).proof != nil else {
        throw MemError.invalid("FAILED: editable combo box: full join denied")
    }
    w.clock += 5_000_000
    try check(join.light(environment: w.environment, appleEvents: w.ae, accessibility: w.access, blockList: BrowserTypingBlockList())?.proof?.light == true,
              "editable combo box: the light check admits the next key")
    w.field.editableAncestor = nil
    try check(join.light(environment: w.environment, appleEvents: w.ae, accessibility: w.access, blockList: BrowserTypingBlockList()) == nil,
              "combo box no longer its own editable root: the light check can't vouch for the key")
}

/// Review I1: Apple Events can lag Accessibility when an Incognito window
/// opens or closes. Every window Accessibility shows must be a listed window
/// before any title, tab, URL or page is read.
extension FakeChromeWorld {
    /// fix/x-typing: a page as deep as X's. X's post box sits about 45
    /// `<div>`s below `<body>` (every one an AXGroup in Chrome's tree), and
    /// Chrome's own views add several more between the AXWebArea and the
    /// window, so the field's parent walk is 55 to 65 steps; claude.ai's
    /// ProseMirror box is about 20. `dom` AXGroups go between the page's group
    /// and the field, `chrome` between the window and the scroll area.
    @discardableResult
    func deepen(dom: Int, chrome: Int = 8) -> [FakeAXNode] {
        let pid = Self.chromePID
        var top = window
        for i in 0..<chrome { top = FakeAXNode("chrome-\(i)", role: i == 2 ? "AXSplitGroup" : "AXGroup", parent: top, owner: pid) }
        scroll.parent = top
        var below = group, made: [FakeAXNode] = []
        for i in 0..<dom { below = FakeAXNode("div-\(i)", role: "AXGroup", parent: below, owner: pid); made.append(below) }
        field.parent = below
        return made
    }
    /// X's home page in the one window: its title (with the unread count), address and post box.
    func xPage(url: String = "https://x.com/home", title: String = "(3) Home / X",
               labels: BrowserTypingFieldLabels = BrowserTypingFieldLabels(texts: ["Post text"], identifiers: ["notranslate", "public-DraftEditor-content"])) {
        windows[0].url = url; web.url = url; windows[0].name = title; window.title = title
        field.role = "AXTextArea"; field.subrole = ""; field.labels = labels
    }
}

/// fix/x-typing (the owner, test 7, 2026-09-29: "X is not recording
/// keystrokes; in Claude it seems to be working"). The join walked at most 48
/// parents from the focused field to the window and refused the field
/// (`.frame`) when the window was further up. X's post box is further than
/// that (`FakeChromeWorld.deepen`); claude.ai's box is not. Deep pages are
/// allowed now; every refusal still holds at that depth, and the walk stays
/// bounded (`maxAncestors`, the join's time budget, the cycle check).
private func checkDeepPages() throws {
    let defaults = BrowserTypingSiteRules(choices: TypedCategoryChoices(), expanded: true)
    let messagesOff = BrowserTypingSiteRules(choices: TypedCategoryChoices(messagesAndEmail: false), expanded: true)
    func run(_ w: FakeChromeWorld, _ rules: BrowserTypingSiteRules = defaults, join: BrowserTypingJoin<FakeAXNode> = BrowserTypingJoin<FakeAXNode>()) -> BrowserTypingJoinResult {
        join.join(environment: w.environment, appleEvents: w.ae, accessibility: w.access, blockList: rules.blockList,
                  alwaysBlocked: rules.alwaysBlocked, sites: rules.permits(url:), field: rules.permits(url:field:))
    }
    func xWorld(dom: Int = 48, chrome: Int = 8) -> FakeChromeWorld {
        let w = FakeChromeWorld(); w.xPage(); w.deepen(dom: dom, chrome: chrome); return w
    }
    // X's post box, 61 steps from the window, with the default switches.
    var w = xWorld()
    var r = run(w)
    try check(r.proof?.role == "AXTextArea" && r.proof?.origin == "https://x.com" && r.proof?.pageTitle == "Home / X",
              "X's post box 61 steps below the window (Draft.js, 'Post text'): allowed, site x.com, title 'Home / X' (\(String(describing: r.denial)))")
    // The limit covers X with room to spare, and stays a bound.
    try check(BrowserTypingTiming.maxAncestors >= 128 && BrowserTypingTiming.maxAncestors <= 256,
              "parent walk limit covers X's post box (61 steps) with room to spare, and stays bounded (\(BrowserTypingTiming.maxAncestors))")
    // Without its label or classes, and the reply box on a post page.
    w = xWorld(); w.field.labels = BrowserTypingFieldLabels(texts: [], identifiers: [])
    try check(run(w).denial == .field, "X's post box 61 steps down, unlabelled: refused (field, Codex 06:10)")
    w = xWorld(); w.xPage(url: "https://x.com/someone/status/1839000000000000000", title: "someone on X: \"gm\" / X",
                          labels: BrowserTypingFieldLabels(texts: ["Post your reply"], identifiers: ["notranslate", "public-DraftEditor-content"]))
    try check(run(w).proof?.role == "AXTextArea", "X's reply box on a post page, 61 steps down: allowed")
    // The compose window (x.com/compose/post) and the search box (an editable combo box).
    w = xWorld(); w.xPage(url: "https://x.com/compose/post", title: "(3) Home / X")
    try check(run(w).proof != nil, "X's compose window (x.com/compose/post), 61 steps down: allowed")
    w = xWorld(); w.xPage(url: "https://x.com/explore", title: "Explore / X", labels: BrowserTypingFieldLabels(texts: ["Search query", "Search"], identifiers: []))
    w.field.role = "AXComboBox"; w.field.editableAncestor = w.field
    try check(run(w).proof?.role == "AXComboBox", "X's search box 61 steps down (an editable combo box): allowed")
    // Deeper still (Facebook, LinkedIn): 120 AXGroups under the page.
    w = xWorld(dom: 110, chrome: 10)
    try check(run(w).proof != nil, "a post box 125 steps below the window: allowed")
    // Emoji and joined emoji in the title and labels: read, compared and cleaned without trouble.
    w = xWorld(); w.xPage(title: "(12) 👩‍👩‍👧 gm ☕️ ✨ / X",
                           labels: BrowserTypingFieldLabels(texts: ["Post text", "What’s happening? 🔥👩🏽‍💻"], identifiers: ["notranslate", "public-DraftEditor-content"]))
    r = run(w)
    // Privacy.clean drops zero-width characters, the joiner too, so a joined emoji is kept as its parts.
    try check(r.proof?.pageTitle == "👩👩👧 gm ☕️ ✨ / X", "emoji title and labels on X: allowed, unread count dropped (\(String(describing: r.proof?.pageTitle)))")
    let family = String(repeating: "👩‍👩‍👧", count: 300)
    let title = WebTypingTitle.clean("(3) " + family + " / X", url: "https://x.com/home", origin: "https://x.com")
    try check(!title.isEmpty && title.utf8.count <= 256 && title.allSatisfy { ["👩", "👧"].contains($0) }, "a long emoji title is cut on whole characters to 256 bytes")
    w = xWorld(); w.xPage(title: family + family)
    try check(run(w).denial == .window, "a window title over 4096 bytes: refused, nothing read from the page")
    // A realistic cost per Accessibility read (0.25 ms) and Apple Event (1 ms): the double read fits the budget.
    w = xWorld(); w.axTick = 250_000
    try check(run(w).proof != nil, "X's post box with 0.25 ms per Accessibility read: the double read fits in 150 ms")
    // A Chrome too slow for that depth: refused at the budget, never a long walk.
    w = xWorld(dom: 110, chrome: 10); w.axTick = 2_000_000
    let started = w.clock
    try check(run(w).denial == .timeout && w.clock - started <= BrowserTypingTiming.joinBudgetNanoseconds + 10_000_000,
              "a slow Chrome on a deep page: refused (.timeout) at the join's budget")
    // Every refusal holds at X's depth.
    w = xWorld(); w.field.role = "AXTextField"; w.field.subrole = "AXSecureTextField"
    try check(run(w).denial == .field, "password field 61 steps down (AXSecureTextField): refused")
    w = xWorld(); w.field.role = "AXSecureTextField"
    try check(run(w).denial == .field, "secure role 61 steps down: refused")
    w = xWorld(); w.secure = true
    try check(run(w).denial == .notFocused && !w.log.contains(where: FakeChromeWorld.isContent),
              "macOS secure input on X's page: refused before any page read")
    for (texts, ids) in [(["Verification code"], [String]()), (["Password"], []), ([], ["cc-number"]), (["Enter your one-time code"], [])] {
        w = xWorld(); w.field.labels = BrowserTypingFieldLabels(texts: texts, identifiers: ids)
        try check(run(w).denial == .sensitiveField, "sensitive field 61 steps down \(texts + ids): refused")
    }
    w = xWorld(); w.xPage(url: "https://x.com/i/flow/login", title: "Log in to X / X")
    try check(run(w).denial == .blockedSite, "X's sign-in page, 61 steps down: refused (blocked page)")
    w = xWorld()
    try check(run(w, messagesOff).denial == .blockedSite, "X's post box 61 steps down with Messages and email off: refused")
    w = xWorld(); w.addWindow("666", mode: "incognito", front: false)
    try check(run(w).denial == .notNormal, "X's post box with an Incognito window open: refused")
    // An iframe (a second web area) deep in the page, and a secure node in the ancestry.
    w = xWorld(); var divs = w.deepen(dom: 48)
    let frameWeb = FakeAXNode("iframe-web", role: "AXWebArea", parent: divs[30], owner: FakeChromeWorld.chromePID)
    frameWeb.url = "https://payments.example.com/card"; divs[31].parent = frameWeb
    try check(run(w).denial == .frame, "a field in an iframe 30 groups down X's page: refused")
    w = xWorld(); divs = w.deepen(dom: 48); divs[20].role = "AXSecureTextField"
    try check(run(w).denial == .frame, "a secure node in a deep field's ancestry: refused")
    // A cycle deep in the tree and a tree deeper than the limit: refused, with a bounded walk.
    w = xWorld(); divs = w.deepen(dom: 48); divs[0].parent = divs[40]
    try check(run(w).denial == .frame, "an ancestry cycle 48 groups down: refused")
    w = xWorld(dom: BrowserTypingTiming.maxAncestors + 200)
    r = run(w)
    let walked = w.log.filter { $0.hasPrefix("ax:role:div-") }.count
    try check(r.denial == .frame && walked <= BrowserTypingTiming.maxAncestors,
              "a field deeper than the limit: refused (.frame) after at most \(BrowserTypingTiming.maxAncestors) steps (\(walked))")
    // The light per-key check after a full join on X's deep page (it reads the field and its parent only).
    w = xWorld(); let join = BrowserTypingJoin<FakeAXNode>()
    _ = run(w, join: join)
    let light = join.light(environment: w.environment, appleEvents: w.ae, accessibility: w.access, blockList: defaults.blockList,
                           alwaysBlocked: defaults.alwaysBlocked, sites: defaults.permits(url:), field: defaults.permits(url:field:))
    try check(light?.proof?.light == true, "the light per-key check vouches for the next key in X's deep post box")
}

private func checkUnlistedWindows() throws {
    let incognitoFrame = ChromeBounds(left: 300, top: 200, right: 900, bottom: 800)
    // 1. Twin: an unlisted Incognito window with the listed window's frame,
    //    title and URL has focus. Denied on geometry, before its title is read.
    var w = FakeChromeWorld()
    let twin = w.axOnlyWindow("incognito-twin", frame: w.window.frame!, title: FakeChromeWorld.title)
    let twinWeb = FakeAXNode("twin-web", role: "AXWebArea", parent: twin, owner: FakeChromeWorld.chromePID); twinWeb.url = w.web.url
    w.axWindows?.append(twin); w.axWindow = twin; w.group.parent = twinWeb
    var r = w.run(BrowserTypingJoin<FakeAXNode>())
    try check(r.denial == .unlistedWindow && !w.log.contains(where: FakeChromeWorld.isPageContent),
              "unlisted same-frame twin focused: denied before any title, tab, URL or label")
    //    The same twin while a normal window on another Space has that frame
    //    too: the one-to-one matching passes (twin to that window), so the
    //    same-frame rule is what denies it.
    w = FakeChromeWorld()
    w.addWindow("303", mode: "normal", front: false, bounds: FakeChromeWorld.bounds, name: "Other page", url: "https://other.example.org/", onThisSpace: false)
    let twin2 = w.axOnlyWindow("incognito-twin", frame: w.window.frame!, title: FakeChromeWorld.title)
    let twin2Web = FakeAXNode("twin-web", role: "AXWebArea", parent: twin2, owner: FakeChromeWorld.chromePID); twin2Web.url = w.web.url
    w.axWindows?.append(twin2); w.axWindow = twin2; w.group.parent = twin2Web
    r = w.run(BrowserTypingJoin<FakeAXNode>())
    try check(r.denial == .ambiguousWindow && !w.log.contains(where: FakeChromeWorld.isPageContent),
              "unlisted twin paired with another Space's window: denied by the same-frame rule, before any title")
    // 2. Closing: Apple Events already dropped the Incognito window, AX still shows it.
    w = FakeChromeWorld()
    w.axWindows?.append(w.axOnlyWindow("incognito-closing", frame: incognitoFrame, title: "Private"))
    r = w.run(BrowserTypingJoin<FakeAXNode>())
    try check(r.denial == .unlistedWindow && !w.log.contains(where: FakeChromeWorld.isPageContent),
              "a closing Incognito window still in AXWindows: denied before any page read")
    // Same, while it still has focus (AX focus lags too).
    w = FakeChromeWorld()
    let closing = w.axOnlyWindow("incognito-closing", frame: incognitoFrame, title: "Private")
    w.axWindows?.append(closing); w.axWindow = closing
    r = w.run(BrowserTypingJoin<FakeAXNode>())
    try check(r.denial == .unlistedWindow && !w.log.contains(where: FakeChromeWorld.isPageContent), "focused unlisted window: denied")
    // 3. Opening, minimized, or a second process's window: any unlisted standard window denies.
    w = FakeChromeWorld()
    let hidden = w.axOnlyWindow("incognito-minimized", frame: incognitoFrame, title: "Private"); hidden.minimized = true
    w.axWindows?.append(hidden)
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .unlistedWindow, "an unlisted minimized window: denied")
    w = FakeChromeWorld(); w.addWindow("202", mode: "normal", front: false, onThisSpace: false)
    let minimizedTwin = w.axOnlyWindow("incognito-minimized-twin", frame: w.window.frame!, title: FakeChromeWorld.title); minimizedTwin.minimized = true
    w.axWindows?.append(minimizedTwin)
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .ambiguousWindow, "a minimized window with the focused frame: denied")
    // 4. Accessibility read failures deny.
    w = FakeChromeWorld(); w.axWindows = nil
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .unlistedWindow, "AXWindows unreadable: denied")
    w = FakeChromeWorld(); w.axWindows = []
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .unlistedWindow, "focused window missing from AXWindows: denied")
    w = FakeChromeWorld(); let broken = w.addWindow("202", mode: "normal", front: false); broken.frame = nil
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .unlistedWindow, "another window's frame unreadable: denied")
    // 5. What stays allowed.
    //    Other Spaces: Apple Events list windows Accessibility does not show.
    w = FakeChromeWorld(); w.addWindow("202", mode: "normal", front: false, onThisSpace: false); w.addWindow("303", mode: "normal", onThisSpace: false)
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).proof?.windowID == "101", "windows on other Spaces: allowed")
    //    A listed, minimized normal window.
    w = FakeChromeWorld(); let mini = w.addWindow("202", mode: "normal", front: false); mini.minimized = true
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).proof != nil, "a listed minimized window: allowed")
    //    Chrome's bubbles and popovers are not standard windows.
    w = FakeChromeWorld(); w.axWindows?.append(w.axOnlyWindow("bubble", frame: incognitoFrame, title: "", subrole: "AXFloatingWindow"))
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).proof != nil, "a non-standard helper window: ignored")
    // 6. Closing between the Accessibility read and the Apple Events re-list: denied.
    w = FakeChromeWorld(); w.addWindow("202", mode: "normal", front: false)
    w.onAppleEvent = { _, n in if n == 4 { w.removeWindow("202") } }   // ids, mode, mode, then the re-list
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .changed, "a window closing during the Accessibility window reads: denied")
    // 7. Known residual (documented, not fixed): an unlisted Incognito window
    //    on this Space whose frame, title and URL equal a listed normal window
    //    on another Space. Accessibility cannot see the normal window, Apple
    //    Events cannot see the Incognito one, and every compared fact agrees.
    //    Bounded by the lag window (Apple Events list a new window within a
    //    few event-loop turns) and by the key-lag rule.
    w = FakeChromeWorld()
    let ghost = w.axOnlyWindow("incognito-ghost", frame: w.window.frame!, title: FakeChromeWorld.title)
    w.scroll.parent = ghost; w.axWindow = ghost; w.axWindows = [ghost]
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).proof != nil, "RESIDUAL pinned: cross-Space identical twin is not detectable")
}

private func checkBursts() throws {
    let quiet = BrowserTypingTiming.quietNanoseconds
    /// A key typed now and processed `lag` later: the join runs at processing time.
    func key(_ burst: inout BrowserTypingBurst, _ w: FakeChromeWorld, _ join: BrowserTypingJoin<FakeAXNode>, lag: UInt64 = 2_000_000) -> Bool {
        let typed = w.clock; w.clock += lag
        let result = w.run(join)
        return burst.admitKey(result, typedAt: typed, processedAt: w.clock)
    }
    func timedSave(_ burst: inout BrowserTypingBurst, _ w: FakeChromeWorld, _ join: BrowserTypingJoin<FakeAXNode>) -> String? {
        let result = w.run(join)
        return burst.save(result, typedAt: nil, processedAt: w.clock)
    }
    // Happy path: start, keys, save -> origin only.
    var w = FakeChromeWorld(), join = BrowserTypingJoin<FakeAXNode>(), burst = BrowserTypingBurst()
    for _ in 0..<3 { try check(key(&burst, w, join), "key admitted on an allowed page"); w.clock += 80_000_000 }
    try check(timedSave(&burst, w, join) == "https://mail.google.com", "save stores the origin only")
    try check(timedSave(&burst, w, join) == nil, "a save consumes the burst")
    // Return: saved with the Return's typed time.
    burst = BrowserTypingBurst(); _ = key(&burst, w, join)
    var typed = w.clock; w.clock += 3_000_000
    var result = w.run(join)
    try check(burst.save(result, typedAt: typed, processedAt: w.clock) == "https://mail.google.com", "Return processed promptly: saved")
    // Save needs a fresh full join.
    burst = BrowserTypingBurst(); _ = key(&burst, w, join)
    try check(burst.save(.denied(.timeout), typedAt: nil, processedAt: w.clock) == nil && !burst.pending, "save without an allowed join discards")
    burst = BrowserTypingBurst(); _ = key(&burst, w, join)
    let stale = w.run(join); w.clock += 1_100_000_000
    try check(burst.save(stale, typedAt: nil, processedAt: w.clock) == nil, "save with a stale join discards")
    burst = BrowserTypingBurst()
    try check(timedSave(&burst, w, join) == nil, "save with no burst stores nothing")

    // Incognito opened between burst start and save (AX lagging: still focused on the normal window).
    w = FakeChromeWorld(); join = BrowserTypingJoin<FakeAXNode>(); burst = BrowserTypingBurst()
    try check(key(&burst, w, join) && key(&burst, w, join), "burst started in a normal window")
    w.addWindow("666", mode: "incognito"); w.log = []
    let atSave = w.run(join)
    try check(atSave.denial == .notNormal && burst.save(atSave, typedAt: nil, processedAt: w.clock) == nil, "incognito opened before save: burst discarded")
    try check(!w.log.contains(where: FakeChromeWorld.isContent), "save-time join read no titles or URLs once incognito existed")

    // A new normal window between start and save: window list differs, burst discarded.
    w = FakeChromeWorld(); join = BrowserTypingJoin<FakeAXNode>(); burst = BrowserTypingBurst()
    _ = key(&burst, w, join)
    w.addWindow("404", mode: "normal", front: false)
    let listChanged = w.run(join)
    try check(listChanged.proof != nil && burst.save(listChanged, typedAt: nil, processedAt: w.clock) == nil, "window list changed between burst start and save: discarded")

    // Lagging Chrome, case 1: Cmd+Shift+N, Chrome lists the new incognito
    // window while AX still reports the old normal window for several keys.
    w = FakeChromeWorld(); join = BrowserTypingJoin<FakeAXNode>(); burst = BrowserTypingBurst()
    _ = key(&burst, w, join)
    burst.noteDisruptive(at: w.clock)                    // Cmd+Shift+N
    try check(!burst.pending, "shortcut discards the pending burst")
    w.addWindow("666", mode: "incognito")
    var admitted = 0
    for _ in 0..<8 { w.clock += 90_000_000; if key(&burst, w, join) { admitted += 1 } }
    try check(admitted == 0 && timedSave(&burst, w, join) == nil, "lagging AX after Cmd+Shift+N: zero keys, nothing saved")
    // Lagging Chrome, case 2: both views lag (no shortcut seen, e.g. a window
    // opened by another app). Keys pass per-key checks; the mandatory
    // save-time join sees the incognito window and discards the burst.
    w = FakeChromeWorld(); join = BrowserTypingJoin<FakeAXNode>(); burst = BrowserTypingBurst()
    for _ in 0..<4 { _ = key(&burst, w, join); w.clock += 50_000_000 }
    try check(burst.pending, "keys buffered while both views lag")
    w.addWindow("666", mode: "incognito")
    try check(timedSave(&burst, w, join) == nil, "lagging AX and AE: the save-time strict check discards the burst")

    // Quiet period after shortcuts, Return, Tab, arrows and clicks, by typed time.
    w = FakeChromeWorld(); join = BrowserTypingJoin<FakeAXNode>(); burst = BrowserTypingBurst()
    let clickAt = w.clock
    burst.noteDisruptive(at: clickAt)                    // a click
    w.clock = clickAt + 100_000_000
    try check(!key(&burst, w, join), "key 100 ms after a click: dropped")
    w.clock = clickAt + quiet - 20_000_000
    try check(!key(&burst, w, join, lag: 40_000_000), "key typed inside the quiet period, processed after it: dropped")
    try check(key(&burst, w, join), "after the quiet period, a fresh join admits keys")

    // Review I2: the join describes the moment of processing, so a key
    // processed late may have gone to a window that has closed since.
    w = FakeChromeWorld(); join = BrowserTypingJoin<FakeAXNode>(); burst = BrowserTypingBurst()
    try check(key(&burst, w, join), "prompt key admitted")
    try check(!key(&burst, w, join, lag: 200_000_000) && !burst.pending, "key processed 200 ms after it was typed: dropped, burst discarded")
    let lateAt = w.clock
    try check(!key(&burst, w, join), "the backlog behind a late key is dropped (quiet period from its processing)")
    w.clock = lateAt + quiet + 1_000_000
    try check(key(&burst, w, join), "keys typed after that quiet period are admitted again")
    try check(key(&burst, w, join, lag: 100_000_000), "key processed 116 ms after it was typed: admitted")
    try check(!key(&burst, w, join, lag: BrowserTypingTiming.maxKeyLagNanoseconds + 1), "lag bound is 150 ms")
    //    Incognito closed before processing: typed while an Incognito window
    //    had focus; processed after it closed, by a join that now sees only normal windows.
    w = FakeChromeWorld(); join = BrowserTypingJoin<FakeAXNode>(); burst = BrowserTypingBurst()
    w.addWindow("666", mode: "incognito")
    typed = w.clock
    w.removeWindow("666"); w.clock += 300_000_000
    result = w.run(join)
    try check(result.proof != nil && !burst.admitKey(result, typedAt: typed, processedAt: w.clock),
              "key typed in an Incognito window that closed before the key was processed: dropped")
    //    A join that started before the key was typed cannot admit it.
    w = FakeChromeWorld(); join = BrowserTypingJoin<FakeAXNode>(); burst = BrowserTypingBurst()
    result = w.run(join)
    try check(!burst.admitKey(result, typedAt: w.clock + 1, processedAt: w.clock + 2), "join older than the key: key dropped")
    //    A late Return saves nothing.
    w = FakeChromeWorld(); join = BrowserTypingJoin<FakeAXNode>(); burst = BrowserTypingBurst()
    _ = key(&burst, w, join)
    typed = w.clock; w.clock += 250_000_000
    result = w.run(join)
    try check(result.proof != nil && burst.save(result, typedAt: typed, processedAt: w.clock) == nil, "Return processed 250 ms late: nothing saved")
    //    Quiet after a denial: Spotlight had the keys; they are processed after it closed.
    w = FakeChromeWorld(); join = BrowserTypingJoin<FakeAXNode>(); burst = BrowserTypingBurst()
    _ = key(&burst, w, join)
    w.systemFocused = 999
    try check(!key(&burst, w, join), "Spotlight takes the keys: key dropped, burst discarded")
    let deniedAt = w.clock
    w.systemFocused = FakeChromeWorld.chromePID
    w.clock = deniedAt + 50_000_000
    try check(!key(&burst, w, join), "key typed 50 ms after a denial (Spotlight just closed): dropped")
    try check(timedSave(&burst, w, join) == nil, "Spotlight query never saved as Chrome typing")
    w.clock = deniedAt + quiet + 1_000_000
    try check(key(&burst, w, join), "keys admitted again after the post-denial quiet period")

    // Focus moving between keys.
    w = FakeChromeWorld(); join = BrowserTypingJoin<FakeAXNode>(); burst = BrowserTypingBurst()
    _ = key(&burst, w, join)
    w.axFocus = FakeAXNode("subject", role: "AXTextField", parent: w.group, owner: FakeChromeWorld.chromePID)
    try check(!key(&burst, w, join) && !burst.pending, "focus moved to another field: burst discarded")
    try check(timedSave(&burst, w, join) == nil, "nothing saved after a focus change")
    // URL change mid-burst (same origin, new page).
    w = FakeChromeWorld(); join = BrowserTypingJoin<FakeAXNode>(); burst = BrowserTypingBurst()
    _ = key(&burst, w, join)
    w.windows[0].url = "https://mail.google.com/mail/u/1/?compose=new"; w.web.url = w.windows[0].url
    try check(!key(&burst, w, join), "URL change mid-burst: burst discarded")
    // Tab switch mid-burst.
    w = FakeChromeWorld(); join = BrowserTypingJoin<FakeAXNode>(); burst = BrowserTypingBurst()
    _ = key(&burst, w, join)
    w.windows[0].tab = "8"
    try check(!key(&burst, w, join), "tab switch mid-burst: burst discarded")
    // Chrome relaunch mid-burst.
    w = FakeChromeWorld(); join = BrowserTypingJoin<FakeAXNode>(); burst = BrowserTypingBurst()
    _ = key(&burst, w, join)
    w.facts.launchIdentity = "4242:1790000999:com.google.Chrome"
    try check(!key(&burst, w, join), "Chrome relaunched mid-burst: burst discarded")
    // A stale proof cannot admit a key.
    w = FakeChromeWorld(); join = BrowserTypingJoin<FakeAXNode>(); burst = BrowserTypingBurst()
    let old = w.run(join); w.clock += 1_500_000_000
    try check(!burst.admitKey(old, typedAt: w.clock - 1_000_000, processedAt: w.clock), "stale join cannot admit a key")
}

/// fix/chrome-capture: X's composer (a post box and its toolbar with Post, an
/// emoji button and a disabled copy of Post), the navigation's Post link and
/// Post button, and a post in the timeline with its Reply button.
final class FakeXComposer {
    let composer: FakeAXNode, toolbar: FakeAXNode, post: FakeAXNode, postLabel: FakeAXNode, emoji: FakeAXNode
    let nav: FakeAXNode, navLink: FakeAXNode, navLinkText: FakeAXNode, navButton: FakeAXNode
    let article: FakeAXNode, reply: FakeAXNode, main: FakeAXNode
    init(_ w: FakeChromeWorld) {
        let pid = FakeChromeWorld.chromePID
        w.xPage()
        let divs = w.deepen(dom: 40)
        main = divs[4]; main.subrole = "AXLandmarkMain"
        composer = divs[30]
        toolbar = FakeAXNode("toolbar", role: "AXGroup", parent: composer, owner: pid)
        let inner = FakeAXNode("toolbar-inner", role: "AXGroup", parent: toolbar, owner: pid)
        post = FakeAXNode("post", role: "AXButton", parent: inner, owner: pid)
        post.title = "Post"; post.frame = ChromeBounds(x: 1000, y: 300, width: 60, height: 30)
        postLabel = FakeAXNode("post-label", role: "AXStaticText", parent: post, owner: pid)
        emoji = FakeAXNode("emoji", role: "AXButton", parent: inner, owner: pid)
        emoji.desc = "Add emoji"; emoji.frame = ChromeBounds(x: 900, y: 300, width: 30, height: 30)
        nav = FakeAXNode("nav", role: "AXGroup", subrole: "AXLandmarkNavigation", parent: w.group, owner: pid)
        navLink = FakeAXNode("nav-post-link", role: "AXLink", parent: nav, owner: pid)
        navLink.title = "Post"; navLink.frame = ChromeBounds(x: 100, y: 600, width: 200, height: 50)
        navLinkText = FakeAXNode("nav-post-text", role: "AXStaticText", parent: navLink, owner: pid)
        navButton = FakeAXNode("nav-post-button", role: "AXButton", parent: nav, owner: pid)
        navButton.title = "Post"; navButton.frame = ChromeBounds(x: 100, y: 700, width: 200, height: 50)
        article = FakeAXNode("article", role: "AXGroup", subrole: "AXDocumentArticle", parent: divs[20], owner: pid)
        reply = FakeAXNode("reply", role: "AXButton", parent: article, owner: pid)
        reply.title = "Reply"; reply.frame = ChromeBounds(x: 600, y: 500, width: 60, height: 30)
    }
}

/// fix/chrome-capture: the Post check against a fake X page. Only a press on
/// the composer's own enabled Post button, on the page and field the words
/// were typed in, is proven; everything else says why not.
private func checkSubmitControl() throws {
    let names = BrowserSubmitControls.names(origin: "https://x.com")!
    try check(names == ["post", "reply", "post all"] && BrowserSubmitControls.names(origin: "https://mobile.x.com") != nil
              && BrowserSubmitControls.names(origin: "https://mail.google.com") == nil && BrowserSubmitControls.names(origin: "https://notx.com") == nil,
              "submit controls: X's names; no other site (and no look-alike host) has any")
    try check(BrowserSubmitControls.control(["Post", ""], allowed: names) == "post" && BrowserSubmitControls.control(["  Post  all "], allowed: names) == "post all"
              && BrowserSubmitControls.control(["Post", "Add photos"], allowed: names) == nil && BrowserSubmitControls.control(["", ""], allowed: names) == nil
              && BrowserSubmitControls.control(["12 Replies. Reply"], allowed: names) == nil,
              "submit controls: every name the button has must be the control's (a tweet's reply count button is not)")
    func setUp() -> (FakeChromeWorld, BrowserTypingJoin<FakeAXNode>, FakeXComposer, BrowserTypingJoinProof?) {
        let w = FakeChromeWorld(), x = FakeXComposer(w), join = BrowserTypingJoin<FakeAXNode>()
        let full = w.run(join)
        guard full.proof != nil else { return (w, join, x, nil) }
        let click = join.join(environment: w.environment, appleEvents: w.ae, accessibility: w.access, blockList: BrowserTypingBlockList(), anyFocus: true)
        return (w, join, x, click.proof.map { var p = $0; p.sendField = full.proof!.focusID; return p })
    }
    func press(_ w: FakeChromeWorld, _ join: BrowserTypingJoin<FakeAXNode>, _ page: BrowserTypingJoinProof, focusID: String, at: (Double, Double) = (1030, 315))
        -> Result<BrowserSubmitPress, BrowserSubmitDenial> {
        join.submitControl(at: at.0, at.1, pid: FakeChromeWorld.chromePID, page: page, focusID: focusID, names: names, environment: w.environment, accessibility: w.access)
    }
    // The composer's Post, clicked on its label: proven.
    var (w, join, x, page) = setUp()
    guard var p = page else { try check(false, "submit: the X page joins"); return }
    let field = p.sendField
    w.hit = x.postLabel; w.log = []
    let proven = press(w, join, p, focusID: field)
    let v = proven.value
    try check(v?.control == "post" && v?.frame == x.post.frame && v?.documentID == p.documentID && v?.focusID == field,
              "submit: a press on the label inside the composer's enabled Post button is proven (\(proven))")
    try check(!w.log.contains { $0.hasPrefix("ax:labels:") || $0.hasPrefix("ax:url:") || $0.hasPrefix("ae:") || $0.hasPrefix("ax:title:") },
              "submit: the check reads no field label, address, title or Apple Event (\(w.log.filter { $0.hasPrefix("ax:labels") || $0.hasPrefix("ax:url") }))")
    let order = ["env:enabled", "ax:frontmost", "ax:hit", "ax:enabled:post", "ax:names:post", "ax:frame:post"].map { e in w.log.firstIndex(of: e) ?? -1 }
    try check(!order.contains(-1) && order == order.sorted() && w.log.last == "ax:secure",
              "submit: consent and focus first, then the hit test, the button's state, names and frame; focus again last (\(w.log.prefix(8)))")
    // Everything that is not the composer's Post.
    func denied(_ name: String, _ expect: BrowserSubmitDenial, _ change: (FakeChromeWorld, FakeXComposer) -> Void, at: (Double, Double) = (1030, 315),
                focus: String? = nil, page override: BrowserTypingJoinProof? = nil) throws {
        let (w, join, x, page) = setUp()
        guard let p = page else { try check(false, "submit: the X page joins (\(name))"); return }
        w.hit = x.postLabel
        change(w, x)
        let r = press(w, join, override ?? p, focusID: focus ?? p.sendField, at: at)
        try check(r.error == expect, "submit: \(name) is not proven (\(r))")
    }
    try denied("X's navigation Post (a link)", .link, { w, x in w.hit = x.navLinkText }, at: (150, 620))
    try denied("a Post button in the navigation landmark", .landmark, { w, x in w.hit = x.navButton }, at: (150, 720))
    try denied("a disabled Post button (an empty composer)", .disabledButton, { _, x in x.post.enabled = false })
    try denied("an unreadable AXEnabled", .disabledButton, { _, x in x.post.enabled = nil })
    try denied("the emoji button", .name, { w, x in w.hit = x.emoji }, at: (910, 310))
    try denied("a post's Reply button in the timeline (another post)", .landmark, { w, x in w.hit = x.reply }, at: (620, 510))
    try denied("a press outside the button's frame", .outsideButton, { _, _ in }, at: (1200, 315))
    // claude/livefix-1004: a click in the post box itself is its own answer, so the route keeps the post's pieces for the
    // Post click that follows (a caret move mid-draft); any other text box is still not a button.
    try denied("the post box itself", .inField, { w, _ in w.hit = w.field })
    try denied("nothing under the pointer", .nothingAt, { w, _ in w.hit = nil })
    try denied("another app's element", .nothingAt, { w, x in x.postLabel.owner = 1 })
    try denied("Chrome not frontmost", .notFocused, { w, _ in w.frontmost = 77 })
    try denied("secure input on", .notFocused, { w, _ in w.secure = true })
    try denied("typing turned off", .typingOff, { w, _ in w.enabled = false })
    try denied("a composer that is gone (the field removed)", .fieldGone, { w, _ in w.field.parent = nil })
    try denied("rows of another field", .noField, { _, _ in }, focus: UUID().uuidString)
    try denied("a secure element on the way", .notButton, { w, x in x.postLabel.role = "AXSecureTextField" })
    try denied("a button too many hops up", .notButton, { w, x in
        var n = x.postLabel
        for i in 0..<5 { let g = FakeAXNode("wrap-\(i)", role: "AXGroup", parent: x.post, owner: FakeChromeWorld.chromePID); n.parent = g; n = g }
    })
    try denied("a Post button in another frame (an iframe's web area)", .frame, { w, x in
        let frame = FakeAXNode("iframe-web", role: "AXWebArea", parent: x.composer, owner: FakeChromeWorld.chromePID)
        x.toolbar.parent = frame
    })
    try denied("a Post button far from the composer", .far, { w, x in
        var top = x.toolbar
        for i in 0..<30 { let g = FakeAXNode("far-\(i)", role: "AXGroup", parent: top.parent, owner: FakeChromeWorld.chromePID); top.parent = g; top = g }
    })
    try denied("a dialog between the button and the composer", .landmark, { w, x in x.toolbar.subrole = "AXApplicationDialog" })
    try denied("a slow Chrome (over the budget)", .timeout, { w, _ in w.axTick = 5_000_000 })
    // A stale page: another page's click join, and a denied join since.
    (w, join, x, page) = setUp(); p = page!
    w.hit = x.postLabel
    w.windows[0].url = "https://x.com/i/bookmarks"; w.web.url = w.windows[0].url
    let other = join.join(environment: w.environment, appleEvents: w.ae, accessibility: w.access, blockList: BrowserTypingBlockList(), anyFocus: true).proof
    try check(other != nil && other?.documentID != p.documentID && press(w, join, other!, focusID: p.sendField).error == .noField,
              "submit: a click join of another page proves nothing")
    try check(press(w, join, p, focusID: p.sendField).error == .noField, "submit: nor does the old page's proof once another page was joined")
    w.windows[0].url = "https://x.com/home"; w.web.url = w.windows[0].url
    (w, join, x, page) = setUp(); p = page!; w.hit = x.postLabel
    w.addWindow("555", mode: "incognito")
    _ = join.join(environment: w.environment, appleEvents: w.ae, accessibility: w.access, blockList: BrowserTypingBlockList(), anyFocus: true)
    w.removeWindow("555")
    try check(press(w, join, p, focusID: p.sendField).error == .noField, "submit: after a denied join (an Incognito window) the field is stale")
    try check(!BrowserSubmitControls.boundary(subrole: "") && BrowserSubmitControls.boundary(subrole: "AXLandmarkBanner")
              && BrowserSubmitControls.boundary(subrole: "AXDocumentArticle"), "submit: landmarks, dialogs and articles bound a composer")
}
extension Result {
    var error: Failure? { if case .failure(let e) = self { return e }; return nil }
    var value: Success? { if case .success(let v) = self { return v }; return nil }
}

/// fix/chrome-capture: which rows a Post click may mark, and when a press is a click.
private func checkSubmitTracker() throws {
    func row(_ id: String, focus: String = "f1", doc: String = "d1", surface: String = "social", field: String = "textArea", seal: String = "idle",
             at: UInt64 = 10_000_000_000) -> BrowserSubmitTracker.Row {
        BrowserSubmitTracker.Row(id: id, runID: "r", origin: "https://x.com", windowID: "101", tabID: "7", documentID: doc, focusID: focus,
                                 surface: surface, field: field, sealReason: seal, writtenAt: at)
    }
    let t = BrowserSubmitTracker()
    t.wrote(row("a"), send: "unknown"); t.wrote(row("b", seal: "submit"), send: "unknown"); t.wrote(row("c", seal: "pointer"), send: "unknown")
    try check(t.candidates(now: 11_000_000_000).map(\.id) == ["a", "b", "c"], "tracker: a composer's pieces (a pause, a Return new line, the click) collect")
    try check(t.candidates(now: 10_000_000_000 + BrowserSubmitTiming.rowAgeNanoseconds + 1).isEmpty, "tracker: pieces older than two minutes can't be marked")
    // claude/livefix-1004: X re-creates its post box mid-draft (a new focus ID on the same page): the pieces stay one post.
    t.wrote(row("d", focus: "f2", seal: "focus"), send: "unknown"); t.wrote(row("d2", focus: "f2", seal: "cursor"), send: "unknown")
    try check(t.rows.map(\.id) == ["a", "b", "c", "d", "d2"], "tracker: a piece in a re-created box of the same page, or after a caret move, stays")
    t.wrote(row("d3", doc: "d2"), send: "unknown")
    try check(t.rows.map(\.id) == ["d3"], "tracker: a piece of another page (document) starts over")
    t.wrote(row("c1", seal: "pointer"), send: "unknown")
    try check(t.chordSent(row("c2", seal: "submitChord"), now: 11_000_000_000).map(\.id) == ["c1"] && t.rows.isEmpty,
              "tracker: Command-Return takes the same page's waiting pieces (the other page's are not that post) and leaves nothing")
    t.wrote(row("e", focus: "f2", seal: "focusKey"), send: "unknown")
    try check(t.rows.isEmpty, "tracker: a piece Tab ended leaves nothing to mark")
    t.wrote(row("f", surface: "social", field: "search"), send: "unknown")
    try check(t.rows.isEmpty, "tracker: X's search box is never a post")
    t.wrote(row("g", surface: "email", field: "body"), send: "unknown")
    try check(t.rows.isEmpty, "tracker: a site whose buttons aren't proven (webmail) leaves nothing to mark")
    t.wrote(row("h"), send: "unknown"); t.wrote(row("i", seal: "submitChord"), send: "detected")
    try check(t.rows.isEmpty, "tracker: Command-Return already posted: nothing left for a click to mark")
    let frame = ChromeBounds(x: 1000, y: 300, width: 60, height: 30)
    func armed() -> BrowserSubmitTracker {
        let t = BrowserSubmitTracker(); t.wrote(row("a"), send: "unknown")
        t.arm(BrowserSubmitTracker.Press(rows: t.rows, control: "post", frame: frame, downAt: 20_000_000_000, x: 1030, y: 315, revision: "r", generation: 1))
        return t
    }
    try check(armed().release(at: 20_100_000_000, x: 1031, y: 316, left: true)?.control == "post", "tracker: released on the button in time: a click")
    try check(armed().release(at: 20_100_000_000, x: 1045, y: 315, left: true) == nil, "tracker: dragged more than 6 points: not a click")
    try check(armed().release(at: 20_100_000_000, x: 1030, y: 360, left: true) == nil, "tracker: released off the button (cancel): not a click")
    try check(armed().release(at: 23_100_000_000, x: 1030, y: 315, left: true) == nil, "tracker: held over 3 s: not a click")
    try check(armed().release(at: 20_100_000_000, x: 1030, y: 315, left: false) == nil, "tracker: another button came up: not a click")
    let once = armed(); _ = once.release(at: 20_100_000_000, x: 1030, y: 315, left: true)
    try check(once.release(at: 20_200_000_000, x: 1030, y: 315, left: true) == nil, "tracker: a press completes once")
    try check(TypingPress(x: 0, y: 0, left: true, clicks: 1, modified: false).plain && !TypingPress(x: 0, y: 0, left: true, clicks: 2, modified: false).plain
              && !TypingPress(x: 0, y: 0, left: true, clicks: 1, modified: true).plain && !TypingPress(x: 0, y: 0, left: false, clicks: 1, modified: false).plain,
              "tracker: only a plain single left click can be a Post click (not a double click, a modified click or another button)")
}

/// claude/xtyping-1005 (owner laptop 10/04, public 0.1.4: a Google search typed in Chrome was saved, an X post or reply
/// was not; reproduced on a fresh Chrome 154 with a local page shaped like X). Chrome builds its accessibility tree only
/// once an assistive client asks its application element its role. Until then Accessibility names no focused
/// application while Chrome is in front, and every full join was refused `notFocused` before any read, with nothing to
/// say why. Now a join that finds Chrome asleep goes on to the mode gate, wakes Chrome (its role, nothing else) and is
/// refused as before; the next join reads Chrome awake, with every check unchanged. Website typing also wakes Chrome
/// when it comes to the front (`BrowserTypingJoin.wake`), behind the same checks and mode gate.
private func checkAsleepChrome() throws {
    func asleep(_ setup: (FakeChromeWorld) -> Void = { _ in }) -> FakeChromeWorld {
        let w = FakeChromeWorld(); w.xPage(); w.sleeping = true; setup(w); return w
    }
    // The first key: refused, Chrome woken after the mode gate, nothing about a window or page read.
    var w = asleep()
    let join = BrowserTypingJoin<FakeAXNode>()
    var r = w.run(join)
    let wakeAt = w.log.firstIndex(of: "ax:wake"), modesAt = w.log.firstIndex(of: "ae:modes")
    try check(r.denial == .notFocused && wakeAt != nil && modesAt != nil && modesAt! < wakeAt! && w.aeCount == 2,
              "asleep Chrome: the join reads window IDs and modes, then wakes Chrome, and is refused (\(w.log))")
    try check(!w.log.contains(where: FakeChromeWorld.isContent) && w.log.last == "ax:wake",
              "asleep Chrome: no title, bounds, URL, field or AX content read before or after the wake")
    // The next key: Chrome awake, the full join as always.
    w.log = []
    r = w.run(join)
    try check(r.proof?.role == "AXTextArea" && !w.log.contains("ax:wake"), "asleep Chrome: the next key's join, Chrome awake, is allowed (\(String(describing: r.denial)))")
    // Every gate before the wake holds: nothing is woken and nothing read.
    let gates: [(String, (FakeChromeWorld) -> Void, BrowserTypingDenial)] = [
        ("an Incognito window open", { $0.addWindow("555", mode: "incognito", front: false) }, .notNormal),
        ("a Guest window", { $0.addWindow("556", mode: "guest") }, .notNormal),
        ("a window whose mode can't be read", { $0.failing = ["mode"] }, .notNormal),
        ("window list unreadable", { $0.failing = ["ids"] }, .windowList),
        ("typing off", { $0.enabled = false }, .disabled),
        ("Automation not granted", { $0.permitted = false }, .noPermission),
        ("an unsigned 'Chrome'", { $0.facts.signatureValid = false }, .untrustedTarget),
        ("secure input on (a password field)", { $0.secure = true }, .notFocused),
        ("another app in front", { $0.frontmost = 999 }, .notFocused),
        ("another app focused (Spotlight), Chrome in front", { $0.systemFocused = 999 }, .notFocused),
    ]
    for (name, setup, denial) in gates {
        w = asleep(setup)
        r = w.run(BrowserTypingJoin<FakeAXNode>())
        try check(r.denial == denial && !w.log.contains("ax:wake") && !w.log.contains(where: FakeChromeWorld.isContent),
                  "asleep Chrome, \(name): refused \(denial) with no wake and no content read (\(String(describing: r.denial)))")
    }
    // The click join (`anyFocus`) is the same read (refused, waking Chrome only after the gate); the light check reads
    // focus only and can't vouch for a key, so the full join decides.
    w = asleep()
    r = join.join(environment: w.environment, appleEvents: w.ae, accessibility: w.access, blockList: BrowserTypingBlockList(), anyFocus: true)
    try check(r.denial == .notFocused && !w.log.contains(where: FakeChromeWorld.isContent), "asleep Chrome: a click join is refused before any content read")
    w = asleep()
    try check(join.light(environment: w.environment, appleEvents: w.ae, accessibility: w.access, blockList: BrowserTypingBlockList()) == nil
              && !w.log.contains(where: FakeChromeWorld.isContent), "asleep Chrome: the light check can't vouch for a key")
    // Chrome that doesn't answer the wake: still refused, and the next join tries again (never allowed asleep).
    w = asleep { $0.wakes = false }
    _ = w.run(join); w.log = []
    try check(w.run(join).denial == .notFocused && w.log.contains("ax:wake"), "asleep Chrome that doesn't wake: refused again, woken again")

    // Website typing's wake when Chrome comes to the front.
    func wake(_ w: FakeChromeWorld, _ j: BrowserTypingJoin<FakeAXNode> = BrowserTypingJoin<FakeAXNode>()) -> Bool {
        j.wake(environment: w.environment, appleEvents: w.ae, accessibility: w.access)
    }
    w = asleep()
    try check(wake(w) && !w.sleeping && w.aeCount == 2 && w.log.firstIndex(of: "ae:modes")! < w.log.firstIndex(of: "ax:wake")!
              && !w.log.contains(where: FakeChromeWorld.isContent), "front wake: asleep, every window normal: window IDs, modes, then the wake; nothing else read")
    w.log = []; w.aeCount = 0
    try check(!wake(w) && w.aeCount == 0 && !w.log.contains("ax:wake"), "front wake: Chrome already awake: no Apple Event, no wake (cheap, idempotent)")
    for (name, setup) in gates.map({ ($0.0, $0.1) }) {
        w = asleep(setup)
        try check(!wake(w) && !w.log.contains("ax:wake") && !w.log.contains(where: FakeChromeWorld.isContent), "front wake, \(name): no wake")
    }
    w = asleep { $0.enabled = false }
    _ = wake(w)
    try check(w.aeCount == 0, "front wake: typing off: not one Apple Event")
    w = asleep()
    try check(!wake(w, BrowserTypingJoin<FakeAXNode>(design: .bracketed)) && w.aeCount == 0 && !w.log.contains("ax:wake"),
              "front wake: the bracketed design never wakes")
    // Consent withdrawn between the mode gate and the wake.
    w = asleep()
    let withdrawn = w
    w.onAppleEvent = { req, _ in if case .modes = req { withdrawn.enabled = false } }
    try check(!wake(w) && !w.log.contains("ax:wake"), "front wake: typing turned off during the reads: no wake")
}

/// claude/xtyping-1005: X's post and reply boxes, shaped as Chrome 154 reports them for a contenteditable
/// role=textbox (checked against a local page on 127.0.0.1, never x.com): inline on the home page and under a post,
/// and inside the compose dialog (role=dialog, AXApplicationDialog). Every one is allowed once Chrome is awake, and
/// the same box in a sensitive or blocked case stays refused.
private func checkXComposers() throws {
    let pid = FakeChromeWorld.chromePID
    let label = BrowserTypingFieldLabels(texts: ["Post text"], identifiers: ["notranslate", "public-DraftEditor-content"])
    let replyLabel = BrowserTypingFieldLabels(texts: ["Post your reply"], identifiers: ["notranslate", "public-DraftEditor-content"])
    func page(url: String, title: String, labels: BrowserTypingFieldLabels, role: String, dialog: Bool, asleep: Bool) -> FakeChromeWorld {
        let w = FakeChromeWorld()
        w.xPage(url: url, title: title, labels: labels)
        w.field.role = role
        let divs = w.deepen(dom: 40)
        if dialog {
            // role=dialog aria-modal: an AXGroup with the dialog subrole well above the box, as X's compose layer.
            divs[10].subrole = "AXApplicationDialog"
        } else {
            divs[4].subrole = "AXLandmarkMain"
            _ = FakeAXNode("article", role: "AXGroup", subrole: "AXDocumentArticle", parent: divs[12], owner: pid)
        }
        w.sleeping = asleep
        return w
    }
    let cases: [(String, String, String, BrowserTypingFieldLabels, Bool)] = [
        ("inline post box (home)", "https://x.com/home", "(2) Home / X", label, false),
        ("inline reply box (a post's page)", "https://x.com/synthetic_user/status/1000000000000000001", "Synthetic User on X: \"sample post\" / X", replyLabel, false),
        ("compose dialog (role=dialog)", "https://x.com/compose/post", "(2) Home / X", label, true),
        ("reply dialog (role=dialog)", "https://x.com/compose/post", "(2) Home / X", replyLabel, true),
    ]
    for (name, url, title, labels, dialog) in cases {
        for role in ["AXTextArea", "AXTextField"] {
            // Awake: allowed at once.
            var w = page(url: url, title: title, labels: labels, role: role, dialog: dialog, asleep: false)
            var r = w.run(BrowserTypingJoin<FakeAXNode>())
            try check(r.proof?.role == role, "X \(name), contenteditable as \(role), Chrome awake: allowed (\(String(describing: r.denial)))")
            // Asleep (the owner's laptop): the first key wakes Chrome and is refused, the second is allowed.
            w = page(url: url, title: title, labels: labels, role: role, dialog: dialog, asleep: true)
            let j = BrowserTypingJoin<FakeAXNode>()
            let first = w.run(j)
            r = w.run(j)
            try check(first.denial == .notFocused && r.proof?.role == role,
                      "X \(name), contenteditable as \(role), Chrome asleep: the first key wakes Chrome, the next is allowed (\(String(describing: r.denial)))")
        }
    }
    // Privacy holds for the same boxes: an Incognito window, secure input, and the site switch.
    var w = page(url: "https://x.com/compose/post", title: "(2) Home / X", labels: label, role: "AXTextArea", dialog: true, asleep: false)
    w.addWindow("555", mode: "incognito", front: false)
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .notNormal, "X compose dialog with an Incognito window open: refused")
    w = page(url: "https://x.com/compose/post", title: "(2) Home / X", labels: label, role: "AXTextArea", dialog: true, asleep: false); w.secure = true
    try check(w.run(BrowserTypingJoin<FakeAXNode>()).denial == .notFocused, "X compose dialog under secure input: refused")
    let messagesOff = BrowserTypingSiteRules(choices: TypedCategoryChoices(messagesAndEmail: false), expanded: true)
    w = page(url: "https://x.com/compose/post", title: "(2) Home / X", labels: label, role: "AXTextArea", dialog: true, asleep: false)
    let off = BrowserTypingJoin<FakeAXNode>().join(environment: w.environment, appleEvents: w.ae, accessibility: w.access, blockList: messagesOff.blockList,
                                                   alwaysBlocked: messagesOff.alwaysBlocked, sites: messagesOff.permits(url:), field: messagesOff.permits(url:field:))
    try check(off.denial == .blockedSite, "X compose dialog with Messages and email off: refused as a site whose switch is off")
}
#endif
