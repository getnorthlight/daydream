import Foundation
import ChromeProbeCore

// Synthetic checks for the device-test harness. A fake Chrome stands in for
// Apple Events and Accessibility; nothing here touches the real system.

var failures = 0, passes = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok { passes += 1 } else { failures += 1; print("FAIL: \(name) \(detail())") }
}

// MARK: - Fake Chrome (Apple Events side)

final class FakeChrome: AppleEventPort {
    struct Win { var id: String; var mode: String?; var bounds: Rect; var name: String; var tabID: String; var url: String }
    var windows: [Win]
    var everyWorks = true
    var legacyWorks = false
    /// Reply descriptor type per AEQuery.replyKind, to test F9.
    var rawTypes: [String: String] = [:]
    var sent: [AEQuery] = []
    /// Called after each send with the running count; lets a test change Chrome mid-join.
    var after: ((Int, FakeChrome) -> Void)?
    init(_ w: [Win]) { windows = w }

    func send(_ q: AEQuery) -> AEReply {
        sent.append(q)
        defer { after?(sent.count, self) }
        func ok(_ v: AEValue) -> AEReply {
            let t: String
            switch v { case .text: t = "utxt"; case .list: t = "list"; case .rect: t = "qdrt" }
            return AEReply(value: v, status: 0, nanos: 1_000_000, rawType: rawTypes[q.replyKind] ?? t)
        }
        func err(_ s: Int32) -> AEReply { AEReply(value: nil, status: s, nanos: 1_000_000) }
        func win(_ id: String) -> Win? { windows.first { $0.id == id } }
        switch q {
        case .window(.every, .id): return everyWorks ? ok(.list(windows.map(\.id))) : err(-1708)
        case .window(.firstAbsolute, .id): return windows.first.map { ok(.text($0.id)) } ?? err(-1719)
        case .window(.firstLegacyEnum, .id): return legacyWorks ? (windows.first.map { ok(.text($0.id)) } ?? err(-1719)) : err(-1700)
        case .window(.index(let i), .id): return i >= 1 && i <= windows.count ? ok(.text(windows[i - 1].id)) : err(-1719)
        case .window(.id(let id), .mode): return win(id)?.mode.map { ok(.text($0)) } ?? err(-1728)
        case .window(.id(let id), .bounds): return win(id).map { ok(.rect($0.bounds)) } ?? err(-1728)
        case .window(.id(let id), .name): return win(id).map { ok(.text($0.name)) } ?? err(-1728)
        case .activeTab(let id, .id): return win(id).map { ok(.text($0.tabID)) } ?? err(-1728)
        case .activeTab(let id, .url): return win(id).map { ok(.text($0.url)) } ?? err(-1728)
        default: return err(-1708)
        }
    }
    var contentSends: Int { sent.filter(\.isContent).count }
}

// MARK: - Fake Accessibility tree

final class FakeAX {
    struct Node { var role: String; var subrole = ""; var parent: Int?; var pid: Int32 = 100; var frame: Rect?; var title: String?; var url: String?; var labels = FieldLabels(); var minimized = false
                 /// fix/web-textbox: AXEditableAncestor is the node itself.
                 var editableSelf = false }
    var nodes: [Int: Node] = [:]
    var focusedWindow: Int? = 1
    /// AXWindows of the application (nil: unreadable).
    var windowList: [Int]? = [1]
    var titleReads = 0
    var focusedElement: Int? = 6
    var frontPID: Int32 = 100
    var focusedAppPID: Int32 = 100
    var secure = false
    var reads = 0
    var labelReads = 0
    var editableReads = 0

    /// window(1) > group(2) > scroll area(3) > web area(4) > group(5) > field(6)
    static func page(url: String = "http://127.0.0.1:8765/", frame: Rect = Rect(x: 0, y: 25, w: 1200, h: 800), title: String = "DayDream device test",
                     role: String = "AXTextField", subrole: String = "", labels: FieldLabels = FieldLabels(), editableSelf: Bool = false) -> FakeAX {
        let a = FakeAX()
        a.nodes[1] = Node(role: "AXWindow", subrole: "AXStandardWindow", parent: nil, frame: frame, title: title)
        a.nodes[2] = Node(role: "AXGroup", parent: 1)
        a.nodes[3] = Node(role: "AXScrollArea", parent: 2)
        a.nodes[4] = Node(role: "AXWebArea", parent: 3, url: url)
        a.nodes[5] = Node(role: "AXGroup", parent: 4)
        a.nodes[6] = Node(role: role, subrole: subrole, parent: 5, labels: labels, editableSelf: editableSelf)
        return a
    }
    /// Adds an iframe: web area(4) > group(7) > web area(8, frameURL) > field(9), focused.
    func addIframe(frameURL: String) {
        nodes[7] = Node(role: "AXGroup", parent: 4)
        nodes[8] = Node(role: "AXWebArea", parent: 7, url: frameURL)
        nodes[9] = Node(role: "AXTextField", parent: 8)
        focusedElement = 9
    }
    /// Another AX window (standard unless told otherwise) with its own page;
    /// returns its id. `focus` moves the focused window and field into it.
    @discardableResult
    func addWindow(_ id: Int, frame: Rect, subrole: String = "AXStandardWindow", title: String = "DayDream device test",
                   url: String = "http://127.0.0.1:8765/", minimized: Bool = false, focus: Bool = false) -> Int {
        nodes[id] = Node(role: "AXWindow", subrole: subrole, parent: nil, frame: frame, title: title, minimized: minimized)
        nodes[id + 1] = Node(role: "AXScrollArea", parent: id)
        nodes[id + 2] = Node(role: "AXWebArea", parent: id + 1, url: url)
        nodes[id + 3] = Node(role: "AXTextField", parent: id + 2)
        windowList?.append(id)
        if focus { focusedWindow = id; focusedElement = id + 3 }
        return id
    }
    /// Address bar: window(1) > toolbar(10) > text field(11), focused.
    func addAddressBar() {
        nodes[10] = Node(role: "AXToolbar", parent: 1)
        nodes[11] = Node(role: "AXTextField", parent: 10)
        focusedElement = 11
    }

    var access: AXAccess<Int> {
        AXAccess<Int>(
            frontmostPID: { self.frontPID },
            focusedApplicationPID: { self.focusedAppPID },
            secureInputOn: { self.secure },
            applicationRole: { self.reads += 1; return "AXApplication" },
            focusedWindow: { self.reads += 1; return self.focusedWindow },
            windows: { self.reads += 1; return self.windowList },
            focusedElement: { self.reads += 1; return self.focusedElement },
            owner: { self.reads += 1; return self.nodes[$0]?.pid },
            role: { self.reads += 1; return self.nodes[$0]?.role },
            subrole: { self.reads += 1; return self.nodes[$0]?.subrole },
            parent: { self.reads += 1; return self.nodes[$0]?.parent },
            minimized: { self.reads += 1; return self.nodes[$0]?.minimized ?? false },
            frame: { self.reads += 1; return self.nodes[$0]?.frame },
            windowTitle: { self.reads += 1; self.titleReads += 1; return self.nodes[$0]?.title },
            webAreaURL: { self.reads += 1; return self.nodes[$0]?.role == "AXWebArea" ? self.nodes[$0]?.url : nil },
            fieldLabels: { self.reads += 1; self.labelReads += 1; return self.nodes[$0]?.labels ?? FieldLabels() },
            equal: { $0 == $1 },
            editableAncestor: { self.reads += 1; self.editableReads += 1; return self.nodes[$0]?.editableSelf == true ? $0 : nil })
    }
}

let front = Rect(x: 0, y: 25, w: 1200, h: 800)
func normalWindow(_ id: String = "11", bounds: Rect = front, url: String = "http://127.0.0.1:8765/") -> FakeChrome.Win {
    FakeChrome.Win(id: id, mode: "normal", bounds: bounds, name: "DayDream device test", tabID: "t\(id)", url: url)
}
func incognitoWindow(_ id: String = "12", bounds: Rect = Rect(x: 40, y: 65, w: 1000, h: 700)) -> FakeChrome.Win {
    FakeChrome.Win(id: id, mode: "incognito", bounds: bounds, name: "SECRET INCOGNITO TITLE", tabID: "t\(id)", url: "https://secret.example/private")
}

var clockNanos: UInt64 = 0
var tick: UInt64 = 100_000 // 0.1 ms per clock read
let clock: () -> UInt64 = { clockNanos += tick; return clockNanos }

struct Rig {
    let chrome: FakeChrome, ax: FakeAX, audit: ReadAudit, timings: TimingLog, join: ChromeJoin<Int>
}
func rig(_ chrome: FakeChrome, _ ax: FakeAX, labels: Bool = false, listing: ListingMode = .every) -> Rig {
    let audit = ReadAudit(), timings = TimingLog()
    let port = AuditedPort(chrome, audit: audit, timings: timings)
    var access = ax.access
    if !labels { access.fieldLabels = nil }
    let join = ChromeJoin(chromePID: 100, ae: port, audit: audit, ax: access, timings: timings, now: clock)
    join.probeLabels = labels
    join.listingMode = listing
    return Rig(chrome: chrome, ax: ax, audit: audit, timings: timings, join: join)
}

// MARK: - Join protocol

do {
    let r = rig(FakeChrome([normalWindow()]), FakeAX.page())
    let o = r.join.run().report
    check(o.verdict == .allow, "plain field in one normal window is allowed", o.summary)
    check(o.webAreaCount == 1 && o.topWebAreaParentRole == "AXScrollArea", "one web area under a scroll area", "\(o.webAreaCount) \(o.topWebAreaParentRole ?? "-")")
    check(o.boundsMatchFront == true && o.titleMatch == .exact && o.urlComparison == "same", "AE and AX agree")
    check(o.origin == "http://127.0.0.1:8765", "only the origin is kept", o.origin ?? "nil")
    check(r.audit.violations.isEmpty, "no audit violations on the happy path", r.audit.violations.joined(separator: "; "))
    check(o.ancestorRoles == ["AXTextField", "AXGroup", "AXWebArea", "AXScrollArea", "AXGroup", "AXWindow"], "ancestor roles recorded", o.ancestorRoles.joined(separator: ">"))
    let data = try JSONEncoder().encode(o)
    let json = String(decoding: data, as: UTF8.self)
    check(!json.contains("DayDream device test") && !json.contains("8765/\""), "join report holds no title or full URL", json)
}

for (label, mode) in [("incognito", "incognito" as String?), ("guest (reports incognito)", "incognito"), ("empty mode", ""), ("missing mode", nil), ("unknown mode", "private")] {
    for incognitoInFront in [false, true] {
        var other = incognitoWindow(); other.mode = mode
        let chrome = FakeChrome(incognitoInFront ? [other, normalWindow()] : [normalWindow(), other])
        let ax = FakeAX.page()
        let r = rig(chrome, ax)
        let o = r.join.run().report
        let place = incognitoInFront ? "front" : "behind"
        check(o.verdict == .strictPause, "\(label) window \(place): strict pause", o.summary)
        check(chrome.contentSends == 0, "\(label) \(place): zero title/URL/tab Apple Events", "\(chrome.sent.map(\.label))")
        check(ax.reads == 0, "\(label) \(place): zero Chrome Accessibility reads", "\(ax.reads)")
        check(r.audit.violations.isEmpty && o.aeContentReads == 0 && o.axContentReads == 0, "\(label) \(place): audit clean")
        let names = chrome.sent.filter { if case .window(_, .name) = $0 { return true }; return false }
        check(names.isEmpty, "\(label) \(place): no window name read at all")
    }
}

do {
    let r = rig(FakeChrome([normalWindow(bounds: Rect(x: 10, y: 25, w: 1200, h: 800))]), FakeAX.page())
    let o = r.join.run().report
    check(o.verdict == .deny && o.reasons.contains(.boundsMismatch), "bounds off by 10 pt is denied", o.summary)
    let r2 = rig(FakeChrome([normalWindow(bounds: Rect(x: 1, y: 24, w: 1201, h: 799))]), FakeAX.page())
    check(r2.join.run().report.verdict == .allow, "bounds within 1 pt are accepted")
}

do {
    let ax = FakeAX.page(title: "Something else")
    let o = rig(FakeChrome([normalWindow()]), ax).join.run().report
    check(o.reasons.contains(.titleMismatch), "title mismatch is denied", o.summary)
    let ax2 = FakeAX.page(title: "DayDream device test - Person 1")
    let o2 = rig(FakeChrome([normalWindow()]), ax2).join.run().report
    check(o2.titleMatch == .axStartsWithAE && o2.verdict == .allow, "AX title that starts with the AE name is accepted (plan fallback)", o2.summary)
}

do {
    let o = rig(FakeChrome([normalWindow(url: "http://127.0.0.1:8765/#frag")]), FakeAX.page()).join.run().report
    check(o.verdict == .allow, "fragment-only difference is accepted", o.summary)
    let o2 = rig(FakeChrome([normalWindow(url: "http://127.0.0.1:8765/other")]), FakeAX.page()).join.run().report
    check(o2.reasons.contains(.urlMismatch), "path difference is denied", o2.summary)
    let o3 = rig(FakeChrome([normalWindow(url: "file:///tmp/x.html")]), FakeAX.page(url: "file:///tmp/x.html")).join.run().report
    check(o3.reasons.contains(.scheme), "file:// is denied", o3.summary)
    let o4 = rig(FakeChrome([normalWindow(url: "https://u:p@example.com/")]), FakeAX.page(url: "https://u:p@example.com/")).join.run().report
    check(o4.reasons.contains(.userInfo), "user:password in URL is denied", o4.summary)
}

for (name, frameURL, expect) in [("same-origin iframe", "http://127.0.0.1:8765/frame.html", DenyReason.iframe),
                                  ("cross-site iframe", "http://localhost:8765/frame.html", DenyReason.iframe)] {
    let ax = FakeAX.page(); ax.addIframe(frameURL: frameURL)
    let o = rig(FakeChrome([normalWindow()]), ax).join.run().report
    check(o.verdict == .deny && o.reasons.contains(expect) && o.webAreaCount == 2, "\(name) is denied", o.summary)
    check(o.nearestFrameVsTab != "same", "\(name): nearest frame URL differs from the tab URL", o.nearestFrameVsTab)
}

do {
    let ax = FakeAX.page(); ax.addAddressBar()
    let o = rig(FakeChrome([normalWindow()]), ax).join.run().report
    check(o.verdict == .deny && o.reasons.contains(.noWebArea), "address bar has no web area and is denied", o.summary)
}

do {
    let o = rig(FakeChrome([normalWindow()]), FakeAX.page(subrole: "AXSecureTextField")).join.run().report
    check(o.reasons.contains(.fieldSecure), "secure subrole is denied", o.summary)
    let ax = FakeAX.page(); ax.secure = true
    let o2 = rig(FakeChrome([normalWindow()]), ax).join.run().report
    check(o2.reasons.contains(.secureInput), "macOS secure input is denied", o2.summary)
    let o3 = rig(FakeChrome([normalWindow()]), FakeAX.page(role: "AXButton")).join.run().report
    check(o3.reasons.contains(.fieldRole), "non-text role is denied", o3.summary)
    let o4 = rig(FakeChrome([normalWindow()]), FakeAX.page(role: "AXTextArea")).join.run().report
    check(o4.verdict == .allow, "textarea / contenteditable role is allowed", o4.summary)
}

do {
    // Spotlight: Chrome still frontmost, keys go elsewhere.
    let ax = FakeAX.page(); ax.focusedAppPID = 555
    let o = rig(FakeChrome([normalWindow()]), ax).join.run().report
    check(o.verdict == .deny && o.reasons.contains(.focusInOtherApp) && o.frontmostIsChrome, "system-wide focus elsewhere is denied", o.summary)
    let ax2 = FakeAX.page(); ax2.frontPID = 555; ax2.focusedAppPID = 555
    check(rig(FakeChrome([normalWindow()]), ax2).join.run().report.reasons.contains(.chromeNotFrontmost), "Chrome not frontmost is denied")
}

do {
    // Label probe: deny-only, and never on unless asked.
    let card = FieldLabels(title: "Card number", description: nil, placeholder: "1234 5678", domIdentifier: "dd-card-number")
    let ax = FakeAX.page(labels: card)
    let off = rig(FakeChrome([normalWindow()]), ax, labels: false).join.run().report
    check(ax.labelReads == 0 && off.labelDeny == nil, "labels are not read without --probe-labels")
    let on = rig(FakeChrome([normalWindow()]), ax, labels: true).join.run().report
    check(on.reasons.contains(.sensitiveLabel) && (on.labelDeny ?? []).contains("AXDOMIdentifier:card"), "card label/id denied with --probe-labels", "\(on.labelDeny ?? [])")
    let json = String(decoding: try JSONEncoder().encode(on), as: UTF8.self)
    check(!json.contains("Card number") && !json.contains("1234") && !json.contains("dd-card-number"), "label text never reaches the report", json)
    check(on.labelPresence?["AXTitle"] == 11, "label presence recorded as a length", "\(on.labelPresence ?? [:])")
    let otp = rig(FakeChrome([normalWindow()]), FakeAX.page(labels: FieldLabels(title: "One-time code", domIdentifier: "otp")), labels: true).join.run().report
    check(otp.reasons.contains(.sensitiveLabel), "one-time code denied", "\(otp.labelDeny ?? [])")
    let plain = rig(FakeChrome([normalWindow()]), FakeAX.page(labels: FieldLabels(title: "Plain input", domIdentifier: "plain-input")), labels: true).join.run().report
    check(plain.verdict == .allow, "plain field not denied by labels", "\(plain.labelDeny ?? [])")
}

do {
    // Changes during the join.
    let chrome = FakeChrome([normalWindow()])
    var flipped = false
    chrome.after = { n, c in if !flipped, c.sent.filter(\.isContent).count >= 3 { flipped = true; c.windows[0].url = "http://127.0.0.1:8765/next" } }
    let o = rig(chrome, FakeAX.page()).join.run().report
    check(o.reasons.contains(.changedAE), "navigation mid-join is denied", o.summary)

    let chrome2 = FakeChrome([normalWindow()])
    var opened = false
    chrome2.after = { _, c in if !opened, c.sent.filter(\.isContent).count >= 3 { opened = true; c.windows.insert(incognitoWindow(), at: 0) } }
    let ax2 = FakeAX.page()
    let r2 = rig(chrome2, ax2)
    let o2 = r2.join.run().report
    check(o2.verdict == .strictPause && o2.reasons.contains(.changedAE), "Incognito opened mid-join: pause, no more reads", o2.summary)
    let readsAfter = ax2.reads
    check(r2.audit.violations.isEmpty, "Incognito opened mid-join: audit clean", r2.audit.violations.joined(separator: "; "))
    let idx = chrome2.sent.lastIndex { if case .window(.every, .id) = $0 { return true }; return false } ?? 0
    check(!chrome2.sent[idx...].contains(where: \.isContent), "no content Apple Event after the new window is listed")
    _ = readsAfter

    let ax3 = FakeAX.page()
    let chrome3 = FakeChrome([normalWindow()])
    var moved = false
    chrome3.after = { _, c in if !moved, c.sent.filter(\.isContent).count >= 4 { moved = true; ax3.focusedElement = 5 } }
    let o3 = rig(chrome3, ax3).join.run().report
    check(o3.reasons.contains(.changedAX), "focus moved mid-join is denied", o3.summary)
}

do {
    // Listing fallbacks and descriptor probe.
    let chrome = FakeChrome([normalWindow("11"), normalWindow("21", bounds: Rect(x: 600, y: 25, w: 600, h: 800))])
    chrome.everyWorks = false
    let r = rig(chrome, FakeAX.page(), listing: .every)
    let o = r.join.run().report
    check(o.listing == "indexed" && o.verdict == .allow, "indexed listing fallback works", o.summary)
    check(r.audit.violations.isEmpty, "indexed listing satisfies the audit", r.audit.violations.joined(separator: "; "))
    let d = DescriptorResult.probe(FakeChrome([normalWindow()]))
    check(d.fixedWorks && !d.legacyWorks && d.listingWorks, "descriptor probe reports fixed works, legacy fails")
}

do {
    // The auditor itself catches an out-of-order read (a buggy caller).
    let chrome = FakeChrome([normalWindow(), incognitoWindow()])
    let audit = ReadAudit(), port = AuditedPort(chrome, audit: audit, timings: TimingLog())
    audit.beginPass()
    _ = port.send(.window(.id("11"), .name))
    check(audit.violations.count == 1, "audit flags a name read before any mode")
    audit.beginPass()
    _ = port.send(.window(.every, .id)); _ = port.send(.window(.id("11"), .mode))
    _ = port.send(.activeTab(windowID: "11", .url))
    check(audit.violations.count == 2, "audit flags a URL read while another window's mode is unknown")
    _ = port.send(.window(.id("12"), .mode))
    _ = port.send(.window(.id("11"), .name))
    check(audit.violations.count == 3, "audit flags a name read while an Incognito window is listed (strict)")
    audit.willReadAX("AX test")
    check(audit.violations.count == 4, "audit flags an AX read while an Incognito window is listed")
    _ = port.send(.window(.firstAbsolute, .name))
    check(audit.violations.count == 5, "audit flags a content read not addressed by window ID")
}

do {
    // Window table: names only when every window is normal.
    let t = WindowPass.table(FakeChrome([normalWindow(), incognitoWindow()]), names: true)!
    check(t.strictPause && t.windows.allSatisfy { $0.name == nil } && t.windows[1].bounds != nil, "window table: strict, no names, bounds kept")
    let t2 = WindowPass.table(FakeChrome([normalWindow()]), names: true)!
    check(!t2.strictPause && t2.windows[0].name == "DayDream device test", "window table: names when all normal")
}

do {
    // Light check.
    let ax = FakeAX.page()
    let r = rig(FakeChrome([normalWindow()]), ax)
    let out = r.join.run()
    let l = r.join.lightCheck(frontID: out.frontID!, window: out.window, element: out.element)
    check(l.ok, "light check passes when nothing changed")
    ax.focusedElement = 5
    check(!r.join.lightCheck(frontID: out.frontID!, window: out.window, element: out.element).ok, "light check fails when focus moves")
}

// MARK: - AX window count (review I1)

do {
    // An Incognito window Apple Events has not listed (opening or closing),
    // with the same frame as the listed normal window, is focused.
    let ax = FakeAX.page()
    ax.addWindow(20, frame: front, title: "SECRET INCOGNITO TITLE", url: "https://secret.example/private", focus: true)
    let chrome = FakeChrome([normalWindow()])
    let r = rig(chrome, ax, labels: true)
    let o = r.join.run().report
    check(o.verdict == .deny && o.reasons.contains(.unlistedWindow) && o.reasons.contains(.sameFrameTwin), "unlisted same-frame twin focused: denied", o.summary)
    check(o.stoppedBeforeContent && chrome.contentSends == 0 && ax.titleReads == 0 && ax.labelReads == 0, "unlisted twin: no title, tab, URL or label read",
          "\(chrome.sent.map(\.label)) titles \(ax.titleReads)")
    check(o.axStandardWindows == 2 && o.unpairedAXWindows == 1 && o.sameFrameWindows == 2, "unlisted twin: counts recorded", "\(o.axStandardWindows ?? -1) \(o.unpairedAXWindows ?? -1) \(o.sameFrameWindows ?? -1)")
    check(r.audit.violations.isEmpty, "unlisted twin: the join itself breaks no audit rule", r.audit.violations.joined(separator: "; "))
    // Without the count (a buggy join), the audit would flag the title read.
    r.audit.willReadAX("AX window title")
    check(r.audit.unlistedWindowSeen && r.audit.violations.count == 1, "audit flags any read once AX showed an unlisted window", r.audit.violations.joined(separator: "; "))
    _ = r.audit
}

do {
    // A closing Incognito window with its own frame, dropped from Apple Events, still focused.
    let ax = FakeAX.page()
    ax.addWindow(30, frame: Rect(x: 40, y: 65, w: 1000, h: 700), title: "SECRET INCOGNITO TITLE", focus: true)
    let chrome = FakeChrome([normalWindow()])
    let o = rig(chrome, ax).join.run().report
    check(o.verdict == .deny && o.reasons.contains(.unlistedWindow) && o.stoppedBeforeContent, "closing unlisted window focused: denied at the count", o.summary)
    check(chrome.contentSends == 0 && ax.titleReads == 0, "closing unlisted window: zero content reads")

    // Unlisted window in the background, a listed normal window focused: still denied.
    let ax2 = FakeAX.page()
    ax2.addWindow(30, frame: Rect(x: 40, y: 65, w: 1000, h: 700))
    let chrome2 = FakeChrome([normalWindow()])
    let o2 = rig(chrome2, ax2).join.run().report
    check(o2.reasons.contains(.unlistedWindow) && o2.stoppedBeforeContent && chrome2.contentSends == 0, "unlisted background window: denied before content", o2.summary)
}

do {
    let ax = FakeAX.page(); ax.windowList = nil
    let chrome = FakeChrome([normalWindow()])
    let o = rig(chrome, ax).join.run().report
    check(o.reasons.contains(.axWindowsUnreadable) && o.stoppedBeforeContent && chrome.contentSends == 0, "AXWindows unreadable: denied before content", o.summary)

    // Non-standard AX windows (a dialog, a panel) are not counted.
    let ax2 = FakeAX.page(); ax2.addWindow(40, frame: Rect(x: 300, y: 300, w: 400, h: 200), subrole: "AXDialog")
    check(rig(FakeChrome([normalWindow()]), ax2).join.run().report.verdict == .allow, "a non-standard AX window is not counted")

    // A minimized normal window pairs with its listed bounds.
    let mini = Rect(x: 1300, y: 25, w: 600, h: 800)
    let ax3 = FakeAX.page(); ax3.addWindow(50, frame: mini, minimized: true)
    let o3 = rig(FakeChrome([normalWindow(), normalWindow("21", bounds: mini)]), ax3).join.run().report
    check(o3.verdict == .allow && o3.unpairedAXWindows == 0, "minimized listed window pairs; the field is allowed", o3.summary)

    // Two listed zoomed windows with one frame: denied by the same-frame rule, before content.
    let ax4 = FakeAX.page(); ax4.addWindow(60, frame: front)
    let chrome4 = FakeChrome([normalWindow(), normalWindow("21")])
    let o4 = rig(chrome4, ax4).join.run().report
    check(o4.reasons == [.sameFrameTwin] && o4.stoppedBeforeContent && chrome4.contentSends == 0, "zoomed twins, both listed: same-frame deny before content", o4.summary)

    // Two windows side by side, both in AXWindows: allowed.
    let ax5 = FakeAX.page(); ax5.addWindow(70, frame: Rect(x: 1300, y: 25, w: 600, h: 800))
    check(rig(FakeChrome([normalWindow(), normalWindow("21", bounds: Rect(x: 1300, y: 25, w: 600, h: 800))]), ax5).join.run().report.verdict == .allow,
          "two side-by-side windows, both counted: allowed")

    // An AX window that appears between the count and the re-check.
    let ax6 = FakeAX.page()
    let chrome6 = FakeChrome([normalWindow()])
    var added = false
    chrome6.after = { _, c in if !added, c.sent.filter(\.isContent).count >= 3 { added = true; ax6.addWindow(80, frame: Rect(x: 40, y: 65, w: 1000, h: 700)) } }
    let o6 = rig(chrome6, ax6).join.run().report
    check(o6.reasons.contains(.changedAX), "a window appearing on the AX side mid-join is denied", o6.summary)

    // Focused window missing from AXWindows (the app denies this too).
    let ax8 = FakeAX.page(); ax8.windowList = []
    let chrome8 = FakeChrome([normalWindow()])
    let o8 = rig(chrome8, ax8).join.run().report
    check(o8.reasons.contains(.focusedNotInAXWindows) && o8.stoppedBeforeContent && chrome8.contentSends == 0, "focused window not in AXWindows: denied before content", o8.summary)

    // Focused window not an AXStandardWindow.
    let ax7 = FakeAX.page(); ax7.nodes[1]!.subrole = "AXFloatingWindow"
    check(rig(FakeChrome([normalWindow()]), ax7).join.run().report.reasons.contains(.axWindowSubrole), "focused window must be an AXStandardWindow")
}

do {
    // Pairing is one-to-one and exact: a greedy pass would strand f2.
    let x = Rect(x: 0, y: 0, w: 100, h: 100), y = Rect(x: 1, y: 0, w: 100, h: 100)
    let f1 = Rect(x: 0.5, y: 0, w: 100, h: 100), f2 = Rect(x: -0.5, y: 0, w: 100, h: 100)
    check(WindowMatch.maximum([f1, f2], [x, y]) == 2, "window pairing is a maximum matching")
    check(WindowMatch.maximum([f1, f1, f1], [x, y]) == 2, "three AX windows cannot share two listed windows")
    check(WindowMatch.maximum([], [x]) == 0 && WindowMatch.maximum([x], []) == 0, "empty pairing")
}

do {
    // F9 inputs: the audited port records each reply's descriptor type.
    let chrome = FakeChrome([normalWindow()]); chrome.rawTypes = ["tab-id": "long"]
    let audit = ReadAudit(), port = AuditedPort(chrome, audit: audit, timings: TimingLog())
    let r = ChromeJoin(chromePID: 100, ae: port, audit: audit, ax: FakeAX.page().access, timings: TimingLog(), now: clock)
    _ = r.run()
    check(port.replyTypes["tab-id"] == ["long"] && port.replyTypes["mode"] == ["utxt"] && port.replyTypes["bounds"] == ["qdrt"] && port.replyTypes["window-list"] == ["list"],
          "reply types recorded per property", "\(port.replyTypes)")
}

// MARK: - Rules, options, profile gate

check(FieldDeny.tokens("ccNumber") == ["cc", "number"], "camelCase tokens", "\(FieldDeny.tokens("ccNumber"))")
check(FieldDeny.tokens("one_time-code") == ["one", "time", "code"], "separator tokens")
check(FieldDeny.matches(FieldLabels(description: "Terminal input", classList: ["xterm-helper-textarea"])).contains("AXDOMClassList:xterm"), "xterm class denied")
check(FieldDeny.matches(FieldLabels(classList: ["monaco-editor", "inputarea"])).contains("AXDOMClassList:inputarea"), "Monaco input area denied")
check(FieldDeny.matches(FieldLabels(title: "Plain input", domIdentifier: "plain-input", classList: ["form-control"])).isEmpty, "plain classes not denied")
check(FieldLabels(classList: ["a", "b"]).presence["AXDOMClassList"] == 2, "class list presence is a count")
check(URLRules.origin("https://Mail.Google.com/mail/u/0/#inbox") == "https://mail.google.com", "origin strips path and fragment")
check(URLRules.origin("http://127.0.0.1:8765/a?b=c") == "http://127.0.0.1:8765", "origin keeps the port")
check(!URLRules.isWebScheme("chrome://newtab/") && !URLRules.isWebScheme("about:blank") && URLRules.isWebScheme("https://x.y/"), "scheme rule")

do {
    let d = try Options.parse(["run"])
    check(d.command == .run && !d.requestPermission, "run does not request permission by default")
    check(!(try Options.parse(["preflight"])).requestPermission, "preflight does not request permission by default")
    let none = try Options.parse([])
    check(!none.requestPermission && none.command == .help, "no arguments: help, no permission")
    check((try Options.parse(["preflight", "--request-permission"])).requestPermission, "--request-permission is honoured")
    check(!(try Options.parse(["run", "--probe-labels"])).requestPermission, "other flags never imply the permission request")
    var threw = false
    do { _ = try Options.parse(["run", "--request-permissions"]) } catch { threw = true }
    check(threw, "a misspelt permission flag is rejected, not ignored")
    let o = try Options.parse(["join", "--repeat", "7", "--only", "a, b", "--report", "/tmp/r.json"])
    check(o.repeatCount == 7 && o.only == ["a", "b"] && o.reportPath == "/tmp/r.json", "option values parse")
    let access = try Options.parse(["access"])
    check(access.command == .access && !access.requestPermission, "access command parses and requests nothing")
}

// MARK: - Test-page server rules (chrome-device-test-serve; no sockets here)

do {
    let index = Array("<html>index</html>\n".utf8), frame = Array("<html>frame</html>\n".utf8)
    let mtime = Date(timeIntervalSince1970: 1_790_000_000.75)
    var looked: [String] = []
    let files: (String) -> TestPage.File? = { name in
        looked.append(name)
        switch name {
        case "index.html": return TestPage.File(bytes: index, modified: mtime)
        case "frame.html": return TestPage.File(bytes: frame, modified: mtime)
        default: return nil
        }
    }
    let now = Date(timeIntervalSince1970: 1_790_000_100)
    func ask(_ raw: String) -> TestPage.Response? { TestPage.respond(head: Array(raw.utf8), now: now, file: files) }
    func get(_ path: String, method: String = "GET", extra: String = "") -> TestPage.Response? {
        ask("\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1:8765\r\n\(extra)\r\n")
    }

    check(TestPage.port == 8765 && TestPage.requiredFiles == ["index.html", "frame.html"], "server port and required files")
    for (path, name) in [("/", "index.html"), ("/index.html", "index.html"), ("/frame.html?x=1#y", "frame.html"), ("//frame.html", "frame.html"),
                         ("/./frame.html", "frame.html"), ("/%66rame.html", "frame.html"), ("/../../README.md", "README.md"),
                         ("/%2e%2e/README.md", "README.md"), ("/..%2f..%2fREADME.md", "README.md"), ("/a/../index.html", "index.html")] {
        check(TestPage.fileName(forPath: path) == name, "path \(path) -> \(name)", "\(String(describing: TestPage.fileName(forPath: path)))")
    }
    for path in ["/index.html/", "/index.html%2F", "/testpage/index.html", "/a/b", "/.hidden", "/%2e%2e%2f.git/config", "/index.html%00.png", "/x%0a"] {
        check(TestPage.fileName(forPath: path) == nil, "path \(path) -> 404")
    }
    let traversal = ["/../../../../etc/passwd", "/%2e%2e/%2e%2e/etc/passwd", "/..%2F..%2Fetc%2Fpasswd", "/.%2e/x", "/../"]
    check(traversal.allSatisfy { p in TestPage.fileName(forPath: p).map { !$0.contains("/") && !$0.hasPrefix(".") } ?? true },
          "no path ever names anything outside the page folder")

    if let r = get("/") {
        check(r.status == 200 && r.body == index && r.header("Content-Type") == "text/html" && r.header("Content-Length") == String(index.count),
              "GET / serves index.html", "\(r.status)")
        check(r.header("Last-Modified") == TestPage.httpDate(mtime) && r.header("Date") == TestPage.httpDate(now), "200 dates")
    } else { check(false, "GET / answers") }
    if let r = get("/frame.html?x=1") { check(r.status == 200 && r.body == frame, "GET /frame.html?x=1 serves frame.html") }
    if let r = get("/", method: "HEAD") {
        check(r.status == 200 && r.body.isEmpty && r.header("Content-Length") == String(index.count), "HEAD /: headers, no body")
    }
    looked = []
    if let r = get("/../../README.md") {
        check(r.status == 404 && r.reason == "File not found" && r.header("Content-Type") == "text/html;charset=utf-8", "traversal attempt is 404")
        check(looked == ["README.md"], "traversal attempt only looks inside the page folder", "\(looked)")
    }
    if let r = get("/nope", method: "HEAD") {
        check(r.status == 404 && r.body.isEmpty && r.header("Content-Length") != nil, "HEAD 404: headers, no body")
    }
    if let r = get("/", method: "POST", extra: "Content-Length: 0\r\n") {
        check(r.status == 501 && r.reason == "Unsupported method ('POST')" && r.header("Connection") == "close", "POST is 501", r.reason)
    }
    if let r = ask("GET / HTTP/2.0\r\n\r\n") { check(r.status == 505 && !r.statusLine, "HTTP/2.0 is 505, body only (as serve.py)") }
    if let r = ask("GET / FTP/1.0\r\n\r\n") { check(r.status == 400 && r.reason == "Bad request version ('FTP/1.0')", "bad version is 400", r.reason) }
    if let r = ask("GET / x HTTP/1.1\r\n\r\n") { check(r.status == 400 && r.statusLine && r.reason.hasPrefix("Bad request syntax"), "four words is 400", r.reason) }
    if let r = ask("GET / HTTP/1.1 extra\r\n\r\n") { check(r.status == 400 && !r.statusLine, "unknown last word: 400, body only (as serve.py)") }
    if let r = ask("GET /\r\n\r\n") { check(r.status == 200 && !r.statusLine && r.body == index, "HTTP/0.9 GET: body only (as serve.py)") }
    check(ask("\r\n\r\n") == nil, "empty request line: no reply")
    let future = TestPage.httpDate(Date(timeIntervalSince1970: 1_800_000_000)), past = TestPage.httpDate(Date(timeIntervalSince1970: 1_700_000_000))
    if let r = get("/", extra: "If-Modified-Since: \(future)\r\n") { check(r.status == 304 && r.body.isEmpty, "If-Modified-Since after mtime: 304") }
    if let r = get("/", extra: "If-Modified-Since: \(past)\r\n") { check(r.status == 200, "If-Modified-Since before mtime: 200") }
    if let r = get("/", extra: "If-Modified-Since: \(future)\r\nIf-None-Match: \"x\"\r\n") { check(r.status == 200, "If-None-Match disables 304") }
    if let r = get("/", extra: "If-Modified-Since: \(TestPage.httpDate(mtime))\r\n") { check(r.status == 304, "If-Modified-Since equal to mtime (whole seconds): 304") }

    let every = ["GET / HTTP/1.1\r\n\r\n", "HEAD /frame.html HTTP/1.1\r\n\r\n", "GET /nope HTTP/1.0\r\n\r\n", "POST / HTTP/1.1\r\n\r\n",
                 "GET / x HTTP/1.1\r\n\r\n", "GET /%2e%2e/x HTTP/1.1\r\n\r\n", "GET / HTTP/1.1\r\nIf-Modified-Since: \(future)\r\n\r\n"]
    for raw in every {
        guard let r = ask(raw) else { check(false, "reply to \(raw)"); continue }
        let bytes = TestPage.serialize(r)
        let head = String(decoding: bytes, as: UTF8.self)
        check(head.hasPrefix("HTTP/1.0 ") && head.contains("\r\nCache-Control: no-store\r\n\r\n"), "Cache-Control: no-store on \(raw.prefix(20))")
    }
    check(TestPage.serialize(TestPage.tooLarge(Array(repeating: 65, count: 70_000), now: now)).starts(with: Array("HTTP/1.0 414 ".utf8)), "huge request line is 414")
    check(TestPage.headEnd(Array("GET / HTTP/1.1\r\nHost: x\r\n\r\nrest".utf8)) == 27 && TestPage.headEnd(Array("GET / HTTP/1.1\r\n".utf8)) == nil
          && TestPage.headEnd(Array("GET /\n\n".utf8)) == 7, "request head end")
    check(TestPage.contentType("index.html") == "text/html" && TestPage.contentType("serve.py") == "text/x-python"
          && TestPage.contentType("x.bin") == "application/octet-stream", "content types match serve.py")
    check(TestPage.errorBody(code: 404, message: "File not found", explain: "Nothing matches the given URI").count == 460, "404 page is Python 3.14's (460 bytes)")
    check(TestPage.httpDate(Date(timeIntervalSince1970: 784_111_777.9)) == "Sun, 06 Nov 1994 08:49:37 GMT", "HTTP date format")
    check(TestPage.parseHTTPDate("Sun, 06 Nov 1994 08:49:37 GMT") == Date(timeIntervalSince1970: 784_111_777)
          && TestPage.parseHTTPDate("Sun, 06 Nov 1994 08:49:37 +0100") == nil, "HTTP date parse (UTC only)")
}

do {
    var buf: [UInt8] = [3, 0, 0, 0]
    buf += Array("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome".utf8) + [0, 0, 0, 0]
    buf += Array("Google Chrome".utf8) + [0] + Array("--user-data-dir=/var/folders/zz/T/ddchrometest.X1".utf8) + [0] + Array("--no-first-run".utf8) + [0]
    buf += Array("SECRET_TOKEN=abc".utf8) + [0]
    let args = ProfileGate.parseProcArgs2(buf)
    check(args?.count == 3 && args?.contains(where: { $0.contains("SECRET") }) == false, "procargs: argv parsed, environment never decoded", "\(args ?? [])")
    let home = "/Users/someone"
    check(ProfileGate.evaluate(chromeCount: 1, args: args, home: home).ok, "throwaway profile accepted")
    check(ProfileGate.evaluate(chromeCount: 1, args: ["Google Chrome"], home: home) == .missingUserDataDir, "no --user-data-dir refused")
    check(ProfileGate.evaluate(chromeCount: 1, args: ["x", "--user-data-dir=\(home)/Library/Application Support/Google/Chrome/"], home: home) == .defaultProfile, "real profile folder refused")
    check(ProfileGate.evaluate(chromeCount: 2, args: args, home: home) == .multipleChrome(2), "two Chromes refused")
    check(ProfileGate.evaluate(chromeCount: 0, args: nil, home: home) == .notRunning, "no Chrome: refused, never launched")
    check(ProfileGate.evaluate(chromeCount: 1, args: nil, home: home) == .argumentsUnreadable, "unreadable args reported")
    check(ProfileGate.evaluate(chromeCount: 1, args: ["x", "--user-data-dir", "/tmp/p"], home: home).ok, "--user-data-dir with a separate value")
}

do {
    let s = Stats.of([10, 20, 30, 40, 50, 60, 70, 80, 90, 100])!
    check(s.median == 55 && s.p90 == 90 && s.max == 100, "stats", "\(s)")
    func fs(_ i: Int, _ focusedChrome: Bool, _ panel: Bool) -> FocusSample {
        FocusSample(ms: Double(i * 100), frontIsChrome: true, focusedIsChrome: focusedChrome, focusedBundle: focusedChrome ? "com.google.Chrome" : "com.apple.Spotlight",
                    panels: panel ? ["com.apple.Spotlight"] : [], secureInput: false)
    }
    let f = FocusSummary.of([fs(0, true, false), fs(1, false, true), fs(2, false, true), fs(3, true, true), fs(4, true, true), fs(5, true, false)])
    check(f.panelWhileChromeFront == 2 && f.leaks == 1 && f.focusElsewhereWhileChromeFront == 2, "focus summary counts a steady-panel leak", "\(f)")
    check(RaceResult(axChangedMs: 100, aeListedMs: 350, newWindowMode: "incognito", timedOut: false).lagMs == 250, "race lag")
    check(RaceResult(axChangedMs: 300, aeListedMs: 100, newWindowMode: "incognito", timedOut: false).lagMs == 0, "race: listed before focus moved")
    let gap = RaceResult(axChangedMs: 100, aeListedMs: 200, newWindowMode: "incognito", timedOut: false,
                         samples: [RaceSample(ms: 110, aeListed: 1, axStandard: 2, focusMoved: true, newListed: false, focusedInAXList: true),
                                   RaceSample(ms: 150, aeListed: 1, axStandard: 1, focusMoved: true, newListed: false, focusedInAXList: false),
                                   RaceSample(ms: 170, aeListed: 1, axStandard: nil, focusMoved: true, newListed: false, focusedInAXList: nil)])
    check(gap.dangerousSamples == 3 && gap.uncaughtSamples == 1, "race samples: unreadable counts as caught, equal counts do not", "\(gap.dangerousSamples) \(gap.uncaughtSamples)")
    let nat = FocusSummary.of([FocusSample(ms: 0, frontIsChrome: false, focusedIsChrome: false, focusedBundle: "com.apple.TextEdit", panels: [], secureInput: false, frontBundle: "com.apple.TextEdit", focusReadMs: 1),
                               FocusSample(ms: 100, frontIsChrome: false, focusedIsChrome: false, focusedBundle: "com.apple.Notes.helper", panels: [], secureInput: false, frontBundle: "com.apple.Notes", focusReadMs: 2),
                               FocusSample(ms: 200, frontIsChrome: false, focusedIsChrome: false, focusedBundle: "com.apple.Terminal", panels: [], secureInput: false, frontBundle: "com.apple.Terminal", focusReadMs: 3)])
    check(nat.nativeFront == 2 && nat.nativeAgree == 1 && nat.nativeFrontBundles == ["com.apple.Notes", "com.apple.TextEdit"] && nat.focusReadStats?.max == 3,
          "native focus summary counts TextEdit/Notes only", "\(nat.nativeFront) \(nat.nativeAgree)")
}

// MARK: - Grading

func joins(_ n: Int, chrome: () -> FakeChrome, ax: () -> FakeAX, labels: Bool = false) -> [JoinReport] {
    (0..<n).map { _ in rig(chrome(), ax(), labels: labels).join.run().report }
}
func goodSteps() -> [String: StepResult] {
    var s: [String: StepResult] = [:]
    func put(_ id: String, _ f: (inout StepResult) -> Void) { var r = StepResult(id: id); r.ran = true; f(&r); s[id] = r }
    let one = { FakeChrome([normalWindow()]) }
    let side = Rect(x: 1300, y: 25, w: 600, h: 800)
    let two = { FakeChrome([normalWindow(), normalWindow("21", bounds: side)]) }
    let twoAX = { () -> FakeAX in let a = FakeAX.page(); a.addWindow(20, frame: side); return a }
    put("descriptor") { $0.descriptor = DescriptorResult.probe(one()) }
    put("plain-input") { $0.joins = joins(10, chrome: one, ax: { FakeAX.page() }); $0.lightMs = Array(repeating: 2, count: 20); $0.lightOK = 20; $0.warmupMs = 120 }
    put("textarea") { $0.joins = joins(5, chrome: one, ax: { FakeAX.page(role: "AXTextArea") }) }
    put("contenteditable") { $0.joins = joins(5, chrome: one, ax: { FakeAX.page(role: "AXTextArea") }) }
    put("typing") { $0.joins = joins(20, chrome: one, ax: { FakeAX.page(role: "AXTextArea") }); $0.elementStable = Array(repeating: true, count: 19) }
    put("password-hidden") { $0.joins = joins(3, chrome: one, ax: { FakeAX.page(subrole: "AXSecureTextField") }) }
    put("password-shown") { $0.joins = joins(3, chrome: one, ax: { FakeAX.page(labels: FieldLabels(title: "Dummy password", domIdentifier: "dummy-password")) }, labels: true) }
    put("card") { $0.joins = joins(3, chrome: one, ax: { FakeAX.page(labels: FieldLabels(title: "Card number", domIdentifier: "card-number")) }, labels: true) }
    put("otp") { $0.joins = joins(3, chrome: one, ax: { FakeAX.page(labels: FieldLabels(title: "One-time code", domIdentifier: "otp")) }, labels: true) }
    put("terminal") { $0.joins = joins(3, chrome: one, ax: { FakeAX.page(role: "AXTextArea", labels: FieldLabels(description: "Terminal input", domIdentifier: "term-input", classList: ["xterm-helper-textarea"])) }, labels: true) }
    put("iframe-same") { $0.joins = joins(3, chrome: one, ax: { let a = FakeAX.page(); a.addIframe(frameURL: "http://127.0.0.1:8765/frame.html"); return a }) }
    put("iframe-cross") { $0.joins = joins(3, chrome: one, ax: { let a = FakeAX.page(); a.addIframe(frameURL: "http://localhost:8765/frame.html"); return a }) }
    put("address-bar") { $0.joins = joins(3, chrome: one, ax: { let a = FakeAX.page(); a.addAddressBar(); return a }) }
    put("two-windows-new") { $0.joins = joins(5, chrome: two, ax: twoAX) }
    put("two-windows-old") { $0.joins = joins(5, chrome: two, ax: twoAX) }
    put("two-windows-zoomed") { $0.joins = joins(5, chrome: { FakeChrome([normalWindow(), normalWindow("21")]) }, ax: { let a = FakeAX.page(); a.addWindow(20, frame: front); return a }) }
    put("minimized-window") { $0.joins = joins(5, chrome: two, ax: { let a = FakeAX.page(); a.addWindow(20, frame: side, minimized: true); return a }) }
    let ten = (0..<10).map { Rect(x: Double(40 * $0), y: 25 + Double(22 * $0), w: 1000, h: 700) }
    put("many-windows") { $0.joins = joins(10, chrome: { FakeChrome([normalWindow(bounds: front)] + (1..<10).map { normalWindow("w\($0)", bounds: ten[$0]) }) },
                                           ax: { let a = FakeAX.page(); for i in 1..<10 { a.addWindow(100 + 10 * i, frame: ten[i]) }; return a }) }
    put("native-editors") { $0.focus = FocusSummary.of((0..<10).map { i in
        FocusSample(ms: Double(i * 100), frontIsChrome: false, focusedIsChrome: false, focusedBundle: "com.apple.TextEdit", panels: [], secureInput: false,
                    frontBundle: "com.apple.TextEdit", focusReadMs: 1) }) }
    put("spotlight") { $0.focus = FocusSummary.of((0..<10).map { i in
        FocusSample(ms: Double(i * 100), frontIsChrome: true, focusedIsChrome: !(2...6).contains(i), focusedBundle: (2...6).contains(i) ? "com.apple.Spotlight" : "com.google.Chrome",
                    panels: (2...6).contains(i) ? ["com.apple.Spotlight"] : [], secureInput: false) }) }
    put("incognito-race") { $0.race = RaceResult(axChangedMs: 100, aeListedMs: 180, newWindowMode: "incognito", timedOut: false,
                                                 samples: [RaceSample(ms: 110, aeListed: 1, axStandard: 2, focusMoved: true, newListed: false, focusedInAXList: true),
                                                           RaceSample(ms: 150, aeListed: 1, axStandard: 2, focusMoved: true, newListed: false, focusedInAXList: true)])
        $0.joins = joins(3, chrome: { FakeChrome([incognitoWindow(), normalWindow()]) }, ax: { FakeAX.page() }) }
    put("incognito-background") { $0.joins = joins(3, chrome: { FakeChrome([normalWindow(), incognitoWindow()]) }, ax: { FakeAX.page() }) }
    put("incognito-closing") {
        // Listed and paused, then dropped from Apple Events while still on screen.
        let listed = joins(2, chrome: { FakeChrome([incognitoWindow(), normalWindow()]) }, ax: { FakeAX.page() })
        let dropped = joins(3, chrome: one, ax: { let a = FakeAX.page(); a.addWindow(20, frame: Rect(x: 40, y: 65, w: 1000, h: 700), focus: true); return a })
        $0.joins = listed + dropped
        $0.closing = ClosingResult(aeDroppedMs: 600, incognitoListed: [true, true, false, false, false], dialogConfirmed: true)
    }
    put("guest") { $0.guestConfirmed = true; $0.joins = joins(3, chrome: { FakeChrome([normalWindow(), incognitoWindow("31")]) }, ax: { FakeAX.page() }) }
    put("combo-input") { $0.joins = joins(5, chrome: one, ax: { FakeAX.page(role: "AXComboBox", editableSelf: true) }) }
    put("password-combo") { $0.joins = joins(3, chrome: one, ax: { let a = FakeAX.page(role: "AXComboBox", editableSelf: true); a.secure = true; return a }) }
    return s
}
let goodFacts = RunFacts(profileOK: true, profileNote: "throwaway", accessibilityTrusted: true, automation: "granted", chromeVersion: "153.0.8010.54",
                         chromeMajor: 153, signatureOK: true, probeLabels: true, auditViolations: 0,
                         aeReadStats: Stats.of([1, 2, 3]), axReadStats: Stats.of([1, 2, 3]),
                         replyTypes: ["window-list": ["list"], "mode": ["utxt"], "bounds": ["qdrt"], "name": ["utxt"], "tab-id": ["utxt"], "tab-url": ["utxt"]])
func gradeOf(_ c: [CriterionResult], _ id: String) -> Grade? { c.first { $0.id == id }?.grade }

do {
    tick = 100_000
    let c = Criteria.grade(goodSteps(), goodFacts)
    // The fake, like (we predict) real Chrome, rejects the pre-fix enum descriptor:
    // F1 then confirms the app's abso fix was needed.
    let bad = c.filter { $0.grade == .fail || $0.grade == .notRun || $0.grade == .fix }
    check(gradeOf(c, "F1") == .pass, "pre-fix enum descriptor failing confirms the fix (F1 PASS)")
    check(bad.isEmpty, "all-good synthetic run grades clean", bad.map { "\($0.id)=\($0.grade.rawValue): \($0.evidence)" }.joined(separator: " | "))
    check(Criteria.overall(c).hasPrefix("CONTINUE"), "all-good overall is CONTINUE", Criteria.overall(c))
    let report = RunReport(macOS: "26.5.2", facts: goodFacts, steps: Array(goodSteps().values))
    let json = String(decoding: try report.json(), as: UTF8.self)
    check(!json.contains("DayDream device test") && !json.contains("SECRET") && !json.contains("Card number") && !json.contains("8765/frame"), "report JSON holds no titles, labels or full URLs")

    var s = goodSteps()
    s["iframe-cross"]!.joins = joins(3, chrome: { FakeChrome([normalWindow()]) }, ax: { FakeAX.page() }) // looks like a top-level field
    let c2 = Criteria.grade(s, goodFacts)
    check(gradeOf(c2, "A11") == .fail && Criteria.overall(c2).hasPrefix("ABANDON"), "indistinguishable iframe field -> ABANDON", Criteria.overall(c2))

    s = goodSteps()
    s["spotlight"]!.focus = FocusSummary.of((0..<10).map { i in
        FocusSample(ms: Double(i * 100), frontIsChrome: true, focusedIsChrome: true, focusedBundle: "com.google.Chrome", panels: (2...6).contains(i) ? ["com.apple.Spotlight"] : [], secureInput: false) })
    check(gradeOf(Criteria.grade(s, goodFacts), "A10") == .fail, "Spotlight on screen but focus says Chrome -> FAIL")

    s = goodSteps()
    s["spotlight"]!.focus = FocusSummary.of([])
    check(gradeOf(Criteria.grade(s, goodFacts), "A10") == .notRun, "no Spotlight seen -> NOT RUN")

    // A4 (review I1): a listing gap passes only if the AX count covered all of it.
    func caught(_ ms: Double) -> RaceSample { RaceSample(ms: ms, aeListed: 1, axStandard: 2, focusMoved: true, newListed: false, focusedInAXList: true) }
    s = goodSteps()
    s["incognito-race"]!.race = RaceResult(axChangedMs: 100, aeListedMs: 600, newWindowMode: "incognito", timedOut: false, samples: [caught(110), caught(400)])
    check(gradeOf(Criteria.grade(s, goodFacts), "A4") == .pass, "500 ms gap fully covered by the AX count -> PASS")
    s["incognito-race"]!.race = RaceResult(axChangedMs: 100, aeListedMs: 1000, newWindowMode: "incognito", timedOut: false, samples: [caught(110), caught(900)])
    check(gradeOf(Criteria.grade(s, goodFacts), "A4") == .fix, "900 ms gap covered -> FIX")
    s["incognito-race"]!.race = RaceResult(axChangedMs: 100, aeListedMs: 150, newWindowMode: "incognito", timedOut: false,
                                           samples: [caught(110), RaceSample(ms: 120, aeListed: 1, axStandard: 1, focusMoved: true, newListed: false, focusedInAXList: false)])
    check(gradeOf(Criteria.grade(s, goodFacts), "A4") == .fail, "50 ms gap with one uncovered sample -> FAIL (lag alone is not a pass)")
    s["incognito-race"]!.race = RaceResult(axChangedMs: 100, aeListedMs: 150, newWindowMode: "incognito", timedOut: false)
    check(gradeOf(Criteria.grade(s, goodFacts), "A4") == .fail, "gap with no samples -> FAIL (unproven)")
    s["incognito-race"]!.race = RaceResult(axChangedMs: 100, aeListedMs: 100, newWindowMode: "incognito", timedOut: false)
    check(gradeOf(Criteria.grade(s, goodFacts), "A4") == .pass, "listed as focus moved -> PASS")
    s["incognito-race"]!.race = RaceResult(axChangedMs: 100, aeListedMs: nil, newWindowMode: nil, timedOut: true)
    check(gradeOf(Criteria.grade(s, goodFacts), "A4") == .fail, "never listed -> FAIL")

    // A14 closing window.
    s = goodSteps()
    s["incognito-closing"]!.joins.append(contentsOf: joins(1, chrome: { FakeChrome([normalWindow()]) }, ax: { FakeAX.page() }))
    s["incognito-closing"]!.closing!.incognitoListed.append(false)
    check(gradeOf(Criteria.grade(s, goodFacts), "A14") == .fail, "an allowed join while the closing window is on screen -> A14 FAIL")
    s = goodSteps(); s["incognito-closing"]!.closing!.dialogConfirmed = false
    check(gradeOf(Criteria.grade(s, goodFacts), "A14") == .notRun, "dialog not confirmed -> A14 NOT RUN")
    s = goodSteps()
    s["incognito-closing"]!.joins = joins(3, chrome: { FakeChrome([incognitoWindow(), normalWindow()]) }, ax: { FakeAX.page() })
    s["incognito-closing"]!.closing = ClosingResult(aeDroppedMs: nil, incognitoListed: [true, true, true], dialogConfirmed: true)
    check(gradeOf(Criteria.grade(s, goodFacts), "A14") == .pass, "closing window stays listed, every join paused -> A14 PASS")

    // F9 reply types, F10 terminal, F11 zoomed, F12 minimized, F13 many windows, F14 native focus.
    var f9 = goodFacts; f9.replyTypes!["tab-id"] = ["long"]
    check(gradeOf(Criteria.grade(goodSteps(), f9), "F9") == .fix, "tab ID answered as long (app wants text) -> F9 FIX")
    f9.replyTypes!["tab-id"] = ["utxt"]; f9.replyTypes!["bounds"] = ["tdta"]
    check(gradeOf(Criteria.grade(goodSteps(), f9), "F9") == .fix, "bounds as tdta (app wants qdrt/list) -> F9 FIX")
    s = goodSteps()
    s["terminal"]!.joins = joins(3, chrome: { FakeChrome([normalWindow()]) }, ax: { FakeAX.page(role: "AXTextArea", labels: FieldLabels(title: "Notes", domIdentifier: "notes")) }, labels: true)
    check(gradeOf(Criteria.grade(s, goodFacts), "F10") == .fix, "terminal not recognised -> F10 FIX")
    s = goodSteps()
    s["two-windows-zoomed"]!.joins = joins(5, chrome: { FakeChrome([normalWindow(), normalWindow("21")]) }, ax: { FakeAX.page() })
    check(gradeOf(Criteria.grade(s, goodFacts), "F11") == .notRun, "zoomed windows not sharing an AX frame -> F11 NOT RUN")
    s = goodSteps()
    s["minimized-window"]!.joins = joins(5, chrome: { FakeChrome([normalWindow(), normalWindow("21", bounds: Rect(x: 1300, y: 25, w: 600, h: 800))]) },
                                         ax: { let a = FakeAX.page(); a.addWindow(20, frame: Rect(x: 0, y: 900, w: 600, h: 100), minimized: true); return a })
    check(gradeOf(Criteria.grade(s, goodFacts), "F12") == .fix, "minimized window frame not pairing -> F12 FIX")
    s = goodSteps(); s["many-windows"]!.joins = joins(10, chrome: { FakeChrome([normalWindow()]) }, ax: { FakeAX.page() })
    check(gradeOf(Criteria.grade(s, goodFacts), "F13") == .notRun, "many-windows with one window -> F13 NOT RUN")
    s = goodSteps()
    s["native-editors"]!.focus = FocusSummary.of((0..<10).map { i in
        FocusSample(ms: Double(i * 100), frontIsChrome: false, focusedIsChrome: false, focusedBundle: i < 5 ? "com.apple.TextEdit" : nil, panels: [], secureInput: false,
                    frontBundle: "com.apple.TextEdit", focusReadMs: 1) })
    check(gradeOf(Criteria.grade(s, goodFacts), "F14") == .fix, "system-wide focus differs from TextEdit -> F14 FIX")

    s = goodSteps()
    s["guest"]!.joins = joins(3, chrome: { FakeChrome([normalWindow(), normalWindow("31")]) }, ax: { FakeAX.page() })
    check(gradeOf(Criteria.grade(s, goodFacts), "A3") == .fail, "Guest reporting normal -> FAIL")

    s = goodSteps()
    s["password-hidden"]!.joins = joins(3, chrome: { FakeChrome([normalWindow()]) }, ax: { FakeAX.page() })
    check(gradeOf(Criteria.grade(s, goodFacts), "A12") == .fail, "password field without secure subrole or secure input -> FAIL")

    // fix/web-textbox: combo boxes, as the app judges them.
    do {
        let own = rig(FakeChrome([normalWindow()]), FakeAX.page(role: "AXComboBox", editableSelf: true), labels: false).join.run().report
        check(own.verdict == .allow && own.fieldEditableSelf == true, "combo box that is its own editable root -> allowed", own.summary)
        let dropDown = FakeAX.page(role: "AXComboBox")
        let dd = rig(FakeChrome([normalWindow()]), dropDown, labels: false).join.run().report
        check(dd.verdict == .deny && dd.reasons.contains(.fieldRole) && dd.fieldEditableSelf == false && dropDown.editableReads == 1,
              "select-only combo box (no editable ancestor) -> denied fieldRole, after one AXEditableAncestor read", dd.summary)
        let field = FakeAX.page()
        let tf = rig(FakeChrome([normalWindow()]), field, labels: false).join.run().report
        check(tf.fieldEditableSelf == nil && field.editableReads == 0, "AXEditableAncestor is never read for a text field")
        let pw = rig(FakeChrome([normalWindow()]), FakeAX.page(role: "AXComboBox", subrole: "AXSecureTextField", editableSelf: true), labels: false).join.run().report
        check(pw.verdict == .deny && pw.reasons.contains(.fieldSecure), "combo box with a secure subrole -> denied")
    }
    s = goodSteps()
    s["password-combo"]!.joins = joins(3, chrome: { FakeChrome([normalWindow()]) }, ax: { FakeAX.page(role: "AXComboBox", editableSelf: true) })
    let openCombo = Criteria.grade(s, goodFacts)
    check(gradeOf(openCombo, "A15") == .fail && Criteria.overall(openCombo).hasPrefix("ABANDON"),
          "password combo box with no secure input and no secure subrole -> A15 FAIL, ABANDON", Criteria.overall(openCombo))
    s = goodSteps()
    s["password-combo"]!.joins = joins(3, chrome: { FakeChrome([normalWindow()]) }, ax: { FakeAX.page(role: "AXComboBox", subrole: "AXSecureTextField", editableSelf: true) })
    check(gradeOf(Criteria.grade(s, goodFacts), "A15") == .pass, "password combo box with a secure subrole, secure input off -> A15 PASS")
    s = goodSteps()
    s["combo-input"]!.joins = joins(5, chrome: { FakeChrome([normalWindow()]) }, ax: { FakeAX.page(role: "AXComboBox") })
    check(gradeOf(Criteria.grade(s, goodFacts), "F15") == .fix, "search combo box that is not its own editable root -> F15 FIX")
    s = goodSteps(); s["combo-input"] = nil; s["password-combo"] = nil
    let noCombo = Criteria.grade(s, goodFacts)
    check(gradeOf(noCombo, "F15") == .notRun && gradeOf(noCombo, "A15") == .notRun && Criteria.overall(noCombo).hasPrefix("INCOMPLETE"),
          "combo steps not run -> F15/A15 NOT RUN, INCOMPLETE", Criteria.overall(noCombo))

    s = goodSteps()
    s["typing"]!.elementStable = Array(repeating: false, count: 19)
    check(gradeOf(Criteria.grade(s, goodFacts), "A8") == .fail, "AX object not stable while typing -> FAIL")

    s = goodSteps()
    s["contenteditable"]!.joins = joins(5, chrome: { FakeChrome([normalWindow()]) }, ax: { FakeAX.page(role: "AXGroup") })
    check(gradeOf(Criteria.grade(s, goodFacts), "A6") == .fail, "contenteditable not a text role -> FAIL")

    s = goodSteps()
    s["address-bar"]!.joins = joins(3, chrome: { FakeChrome([normalWindow()]) }, ax: { FakeAX.page() })
    check(gradeOf(Criteria.grade(s, goodFacts), "A13") == .fail, "address bar accepted -> FAIL")

    s = goodSteps()
    s["two-windows-old"]!.joins = joins(5, chrome: { FakeChrome([normalWindow("21", bounds: Rect(x: 1300, y: 25, w: 600, h: 800)), normalWindow()]) }, ax: { FakeAX.page() })
    check(gradeOf(Criteria.grade(s, goodFacts), "A7") == .fail, "AX window is not the AE front window -> FAIL")

    tick = 5_000_000 // 5 ms per clock read: joins run far over budget
    s = goodSteps()
    let slow = Criteria.grade(s, goodFacts)
    check(gradeOf(slow, "A9") == .fail, "slow joins -> A9 FAIL", slow.first { $0.id == "A9" }?.evidence ?? "")
    check(gradeOf(slow, "F13") == .fix, "slow joins with ten windows -> F13 FIX", slow.first { $0.id == "F13" }?.evidence ?? "")
    tick = 100_000

    var facts = goodFacts; facts.auditViolations = 1
    check(Criteria.overall(Criteria.grade(goodSteps(), facts)).hasPrefix("RUN INVALID"), "audit violation invalidates the run")
    facts = goodFacts; facts.automation = "not decided"
    check(gradeOf(Criteria.grade(goodSteps(), facts), "G2") == .fail, "missing Automation fails the gate")

    s = goodSteps()
    s["plain-input"]!.joins = joins(10, chrome: { FakeChrome([normalWindow()]) }, ax: { let a = FakeAX.page(); a.frontPID = 555; return a })
    let staleFront = Criteria.grade(s, goodFacts)
    check(gradeOf(staleFront, "G4") == .fail && Criteria.overall(staleFront).hasPrefix("RUN INVALID"), "stale frontmost reading invalidates the run", Criteria.overall(staleFront))

    s = goodSteps(); s["guest"] = nil
    check(Criteria.overall(Criteria.grade(s, goodFacts)).hasPrefix("INCOMPLETE"), "missing step -> INCOMPLETE")
    s = goodSteps(); for id in Criteria.allowSteps { s[id] = nil }
    let partial = Criteria.grade(s, goodFacts)
    check(gradeOf(partial, "G4") == .notRun && Criteria.overall(partial).hasPrefix("INCOMPLETE"), "--only run without field steps is INCOMPLETE, not invalid", Criteria.overall(partial))
    s = goodSteps(); s["card"] = nil; s["otp"] = nil
    check(gradeOf(Criteria.grade(s, goodFacts), "F3") == .notRun, "card/OTP without --probe-labels -> NOT RUN")

    // Strict step with no Incognito window (kit `--only incognito-background`
    // in a new Chrome, or step 21 skipped): not run, so A2 is NOT RUN, not FAIL.
    check(Steps.strictPrecondition(modes: ["normal"]) != nil, "strict step, one normal window: nothing to measure")
    check(Steps.strictPrecondition(modes: ["normal", "normal"]) != nil, "strict step, two normal windows: nothing to measure")
    check(Steps.strictPrecondition(modes: []) != nil, "strict step, no window listed: nothing to measure")
    check(Steps.strictPrecondition(modes: ["normal", "incognito"]) == nil, "strict step runs with an Incognito window behind")
    check(Steps.strictPrecondition(modes: ["normal", ""]) == nil && Steps.strictPrecondition(modes: ["private", "normal"]) == nil,
          "strict step still runs (and grades) when a mode is unreadable or unknown")
    s = goodSteps()
    s["incognito-background"]!.ran = false
    s["incognito-background"]!.joins = []
    let noIncognito = Criteria.grade(s, goodFacts)
    check(gradeOf(noIncognito, "A2") == .notRun && Criteria.overall(noIncognito).hasPrefix("INCOMPLETE"),
          "incognito-background skipped for no Incognito window -> A2 NOT RUN, INCOMPLETE", Criteria.overall(noIncognito))
    s = goodSteps()
    s["incognito-background"]!.joins = joins(3, chrome: { FakeChrome([normalWindow(), normalWindow("21")]) }, ax: { FakeAX.page() })
    check(gradeOf(Criteria.grade(s, goodFacts), "A2") == .fail, "background joins that ran without pausing still FAIL A2")
    s = goodSteps()
    s["incognito-background"]!.ran = false
    s["incognito-race"]!.race!.newWindowMode = "normal"
    check(gradeOf(Criteria.grade(s, goodFacts), "A2") == .fail, "a new Incognito window reporting normal FAILS A2 even with background not run")
}

print("chrome-device-test selftest: \(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
