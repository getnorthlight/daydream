#if DAYDREAM_CHROME_TYPING
// Compiled only with -DDAYDREAM_CHROME_TYPING: every release build defines it; a plain swift build leaves this file out.
// Chrome-typing builds only. QF-17 bracketed-join prototype checks. Fully synthetic: a fake clock, synthetic read records and the fake
// Chrome world of ChromeTypingChecks.swift. No Apple Event, AX call, event tap or permission request.
// Every check names the review item it answers (R1-R11, D1-D6, PB/PM, the rev 3.1 counterexample).
import AppKit
import Foundation
import MemoryCore
import PrivacyPolicy

private let ms: UInt64 = 1_000_000

/// A stand-in AX object (identity is the ref comparison, as CFEqual is in production).
private final class Obj {}
private func ref(_ o: AnyObject) -> ChromeRef { ChromeRef(o, same: { $0 === o }) }

/// A synthetic verified read over [start, end] (ms): every fact observed once, in fact order, evenly spread, with
/// `focusState` and `windowIDs` observed twice as the real read does. `times` overrides single facts.
private func record(_ start: UInt64, _ end: UInt64, pid: Int32 = 4242, launch: String = "L", digest: UInt64 = 1,
                    window: AnyObject, focus: AnyObject, chain: [AnyObject] = [],
                    times override: [ChromeFact: [ChromeFactTimes]] = [:]) -> ChromeReadRecord {
    let s = start * ms, e = end * ms
    var times: [ChromeFact: [ChromeFactTimes]] = [:]
    let facts = ChromeFact.allCases
    let step = (e - s) / UInt64(facts.count + 2)
    for (i, f) in facts.enumerated() {
        let sent = s + UInt64(i) * step
        times[f] = [ChromeFactTimes(sent: sent, received: sent + step)]
    }
    times[.windowIDs]!.append(ChromeFactTimes(sent: s + UInt64(facts.count) * step, received: s + UInt64(facts.count) * step + step / 2))
    times[.focusState]!.append(ChromeFactTimes(sent: e - step / 2, received: e))
    for (f, t) in override { times[f] = t }
    var d: [ChromeFact: UInt64] = [:]
    for f in facts { d[f] = digest &+ UInt64(f.rawValue) }
    return ChromeReadRecord(pid: pid, launch: launch, start: s, end: e, digest: d, times: times, window: ref(window), focus: ref(focus),
                            chain: chain.map(ref))
}

private func engine(_ rule: ChromeBracketRule, _ reads: [ChromeReadRecord?], starts: [(UInt64, UInt64)] = []) -> ChromeBracketEngine {
    let e = ChromeBracketEngine(rule: rule)
    for (i, r) in reads.enumerated() {
        if let r { e.readFinished(start: r.start, end: r.end, record: r) } else { e.readFinished(start: starts[i].0 * ms, end: starts[i].1 * ms, record: nil) }
    }
    return e
}
private func admitted(_ d: ChromeBracketEngine.Decision) -> Bool { if case .admit = d { return true }; return false }

func runChromeBracketChecks() throws {
    let before = ChromeJoinDesign.current
    defer { ChromeJoinDesign.current = before }
    try checkDesignSwitch()
    try checkCounterexample()
    try checkTimestamps()
    try checkFirstRead()
    try checkChain()
    try checkBoundaries()
    try checkHeldKeys()
    try checkDiagnostics()
    try checkAudit()
    try checkBracketedJoin()
    try checkBracketedJoinR2()
    try checkBracketedJoinCapture()
    try checkLeanShape()
    try checkRoleChange()
    try checkNoReadsAfterRead()
    try checkFormScanFailsClosed()
    try checkUnlabelledOneLine()
    try checkPageRootScan()
    try checkPerFactOpeningAdmission()
    try checkBracketedBoundaryRecovery()
    try checkUndeliveredReadExpiry()
    try checkMetadataSettle()
}

// MARK: - R9-1 (fix/chrome-capture d4470a8): the bracketed read inherits the page-root scan, every design and shape

/// The synchronous join and the bracketed read (full and lean shapes) share `BrowserFormScan`. Each row runs all three.
private func checkPageRootScan() throws {
    let before = ChromeReadShape.current
    defer { ChromeReadShape.current = before }
    let pid = FakeChromeWorld.chromePID
    func secure(_ name: String, parent: FakeAXNode) { _ = FakeAXNode(name, role: "AXTextField", subrole: "AXSecureTextField", parent: parent, owner: pid) }
    /// Runs `make` fresh for the synchronous join and each bracketed shape; returns the three results.
    func all(_ make: () -> FakeChromeWorld) -> [(String, BrowserTypingJoinResult)] {
        var out: [(String, BrowserTypingJoinResult)] = []
        ChromeReadShape.current = .full
        out.append(("synchronous", make().run(BrowserTypingJoin<FakeAXNode>(design: .synchronous))))
        out.append(("bracketed full", make().run(BrowserTypingJoin<FakeAXNode>(design: .bracketed))))
        ChromeReadShape.current = .lean
        out.append(("bracketed lean", make().run(BrowserTypingJoin<FakeAXNode>(design: .bracketed))))
        ChromeReadShape.current = .full
        return out
    }
    // r9 (QA qf17-r9-password-inserted): the field two levels under the page, a password field a direct child of it.
    for (name, r) in all({ let w = FakeChromeWorld(); secure("pw-root", parent: w.web); return w }) {
        try check(r.denial == .sensitiveField, "R9-1 (\(name)): a password field that is a direct child of the AXWebArea denies the field (sensitiveField)")
    }
    // A password in another subtree of the page (web > div > pw), the field at web > group > field.
    for (name, r) in all({ let w = FakeChromeWorld(); secure("pw-side", parent: FakeAXNode("side", role: "AXGroup", parent: w.web, owner: pid)); return w }) {
        try check(r.denial == .sensitiveField, "R9-1 (\(name)): a password field in a sibling subtree of the page root denies")
    }
    // A field that is itself a direct child of the page (a bare login form: <body><input><input type=password>).
    for (name, r) in all({ let w = FakeChromeWorld(); w.field.parent = w.web; secure("pw-bare", parent: w.web); return w }) {
        try check(r.denial == .sensitiveField, "R9-1 (\(name)): a field directly under the page, next to a password field there: denied (was never scanned)")
    }
    // A "Show password" control at the page root.
    for (name, r) in all({ let w = FakeChromeWorld(); let b = FakeAXNode("reveal", role: "AXButton", parent: w.web, owner: pid); b.title = "Show password"; return w }) {
        try check(r.denial == .sensitiveField, "R9-1 (\(name)): a show-password control at the page root denies")
    }
    // Controls: small page, nothing sensitive: allowed.
    for (name, r) in all({ let w = FakeChromeWorld(); for i in 0..<20 { _ = FakeAXNode("t\(i)", role: "AXStaticText", parent: w.web, owner: pid) }; return w }) {
        try check(r.proof != nil, "R9-1 (\(name)): control: 20 other nodes at the page root, nothing sensitive: allowed")
    }
    for (name, r) in all({ let w = FakeChromeWorld(); let f = FakeAXNode("frame-web", role: "AXWebArea", parent: FakeAXNode("frame", role: "AXGroup", parent: w.web, owner: pid), owner: pid)
                           secure("pw-in-frame", parent: f); return w }) {
        try check(r.denial == .sensitiveField, "Codex 07:10 (\(name)): a password field inside an iframe's page (a nested web area) is seen: denied (sensitiveField; fix/chrome-capture d98c2c9)")
    }
    // Review Q6-2 (fix/chrome-capture 6cb12bf): control names are read inside frames too: a "Show password" control
    // in a frame refuses the field.
    for (name, r) in all({ let w = FakeChromeWorld(); let f = FakeAXNode("frame-web", role: "AXWebArea", parent: FakeAXNode("frame", role: "AXGroup", parent: w.web, owner: pid), owner: pid)
                           let b = FakeAXNode("reveal-in-frame", role: "AXButton", parent: f, owner: pid); b.title = "Show password"; return w }) {
        try check(r.denial == .sensitiveField, "Q6-2 (\(name)): a 'Show password' control inside a frame: sensitiveField")
    }
    // Review Q6-1 (6cb12bf): frames are scanned after the page, so a page's password field behind an early frame (40
    // nodes, or more than the child cap) is found (sensitiveField), never `exhausted`, in every design and shape.
    for (rows, label) in [(40, "a 40-node frame"), (300, "a 300-child frame")] {
        for (name, r) in all({ let w = FakeChromeWorld()
                               let f = FakeAXNode("frame-web", role: "AXWebArea", parent: w.web, owner: pid)
                               for i in 0..<rows { _ = FakeAXNode("frame-row\(i)", role: "AXStaticText", parent: f, owner: pid) }
                               let box = FakeAXNode("pw-box", role: "AXGroup", parent: w.web, owner: pid)
                               for i in 0..<30 { _ = FakeAXNode("page-row\(i)", role: "AXStaticText", parent: w.web, owner: pid) }
                               secure("page-pw", parent: box); return w }) {
            try check(r.denial == .sensitiveField, "Q6-1 (\(name)): a page password field behind \(label) and 30 page nodes: sensitiveField (frames after the page)")
        }
    }
    for (name, r) in all({ let w = FakeChromeWorld(); let f = FakeAXNode("frame-web", role: "AXWebArea", parent: FakeAXNode("frame", role: "AXGroup", parent: w.web, owner: pid), owner: pid)
                           for i in 0..<100 { _ = FakeAXNode("ft\(i)", role: "AXStaticText", parent: f, owner: pid) }; return w }) {
        try check(r.denial == .field, "Codex 07:10 COST (\(name)): a frame of 100 nodes beside the field: exhausted, denied (field)")
    }
    // The stated cost: a shallow field (within 3 levels of the page) on a page with more than 64 other nodes is
    // refused as `field` (the scan is exhausted). Since C1 (fix/chrome-capture b5efe69) deep fields are too (below).
    for (name, r) in all({ let w = FakeChromeWorld(); for i in 0..<80 { _ = FakeAXNode("t\(i)", role: "AXStaticText", parent: FakeAXNode("p\(i)", role: "AXGroup", parent: w.web, owner: pid), owner: pid) }; return w }) {
        try check(r.denial == .field, "R9-1 COST (\(name)): a field 2 levels under a page with 160 other nodes: exhausted, denied (field)")
    }
    func deepBigPage() -> FakeChromeWorld {
        let w = FakeChromeWorld()
        var parent = w.web
        for i in 0..<3 { parent = FakeAXNode("deep\(i)", role: "AXGroup", parent: parent, owner: pid) }
        w.group.parent = parent
        for i in 0..<80 { _ = FakeAXNode("t\(i)", role: "AXStaticText", parent: FakeAXNode("p\(i)", role: "AXGroup", parent: w.web, owner: pid), owner: pid) }
        return w
    }
    // The reason (review 11:27): the shared scan itself, over the field's whole ancestry up to the window, runs out of budget.
    let deep = deepBigPage()
    var deepChain: [FakeAXNode] = [deep.field], up = deep.field.parent
    while let n = up { deepChain.append(n); if n === deep.window { break }; up = n.parent }
    let deepScan = BrowserFormScan.scan(chain: deepChain, ax: deep.access, late: { false })
    for (name, r) in all(deepBigPage) {
        // C1 closure (fix/chrome-capture b5efe69): every ancestor up to the page is scanned, so the deep field's big page
        // exhausts the budget too. Was: "the page level is not reached; allowed (the level-4 gap C1 stays documented)".
        try check(r.denial == .field && deepScan == .exhausted,
                  "C1 (\(name)): the same big page with the field 5 levels deep: the whole ancestry is scanned, the budget runs out (scan: \(deepScan.rawValue)), denied (field; C1's stated cost)")
    }
    // C1 closure, inherited by the bracketed read (one shared `BrowserFormScan.scan`, no 3-level copy): a password field or a
    // Show password control 4 or more levels above a deep field on a small page is seen; with no password, the field is typed.
    // `levels` is [level 2, level 3, ..., level `depth` (right under the page), level 1 (the field's own group)]: the
    // holder of level `at` (>= 2) is `levels[at - 2]` (review 11:27 TB-1: was `levels[depth - at]`, which put two of
    // these rows at level 3, inside the pre-C1 scan).
    for (depth, at, reveal) in [(5, 4, false), (8, 6, false), (6, 5, true), (5, 4, true)] {
        var holderLevel = 0
        func make() -> FakeChromeWorld {
            let w = FakeChromeWorld()
            var levels: [FakeAXNode] = [w.group], parent = w.web
            w.web.kids.removeAll { $0 === w.group }
            for i in stride(from: depth, to: 1, by: -1) { parent = FakeAXNode("level\(i)", role: "AXGroup", parent: parent, owner: pid); levels.insert(parent, at: 0) }
            w.group.parent = parent; parent.kids.append(w.group)
            let holder = levels[at - 2]
            // The holder's ancestor level, counted from the field (its own group is level 1).
            var n: FakeAXNode? = w.field.parent; holderLevel = 1
            while let x = n, x !== holder { n = x.parent; holderLevel += 1 }
            if reveal { let b = FakeAXNode("reveal-at\(at)", role: "AXButton", parent: holder, owner: pid); b.title = "Show password" }
            else { secure("pw-at\(at)", parent: holder) }
            return w
        }
        for (name, r) in all(make) {
            try check(holderLevel == at && r.denial == .sensitiveField, "C1 (\(name)): \(reveal ? "a Show password control" : "a password field") under the field's level-\(at) ancestor (counted: \(holderLevel)), the field \(depth) levels deep: sensitiveField (was the level-4 gap)")
        }
    }
    for (name, r) in all({ let w = FakeChromeWorld()
                           var parent = w.web
                           w.web.kids.removeAll { $0 === w.group }
                           for i in 0..<6 { parent = FakeAXNode("clean\(i)", role: "AXGroup", parent: parent, owner: pid) }
                           w.group.parent = parent; parent.kids.append(w.group)
                           return w }) {
        try check(r.proof != nil, "C1 (\(name)): a field 7 levels deep on a small page with no password: typed (control)")
    }
}

// MARK: - QF-4 option (a) in every bracketed read (fix/chrome-capture 89058ee)

private func checkUnlabelledOneLine() throws {
    let before = ChromeReadShape.current
    defer { ChromeReadShape.current = before }
    for shape in [ChromeReadShape.full, .lean] {
        ChromeReadShape.current = shape
        let name = shape == .full ? "full" : "lean"
        func run(_ role: String, _ subrole: String = "", texts: [String]) -> BrowserTypingJoinResult {
            let w = FakeChromeWorld(); w.field.role = role; w.field.subrole = subrole
            w.field.labels = BrowserTypingFieldLabels(texts: texts, identifiers: ["f"])
            return w.run(BrowserTypingJoin<FakeAXNode>(design: .bracketed))
        }
        try check(run("AXTextField", texts: []).denial == .field, "QF-4 (bracketed \(name)): an unlabelled one-line box: the read refuses (field)")
        try check(run("AXComboBox", texts: [" "]).denial == .field, "QF-4 (bracketed \(name)): an unlabelled editable combo box (blank label): field")
        try check(run("AXTextField", texts: ["Name of thing"]).proof?.bracket != nil, "QF-4 (bracketed \(name)): control: a labelled one-line box verifies")
        try check(run("AXTextField", "AXSearchField", texts: []).denial == .field, "QF-4 Q4-1 (bracketed \(name)): an unlabelled search field: field (fix/chrome-capture 63e1fa7)")
        try check(run("AXTextField", texts: ["Enter code"]).denial == .sensitiveField && run("AXTextField", texts: ["Promo code"]).proof?.bracket != nil,
                  "QF-4 Q4-1 (bracketed \(name)): the label word 'code' is sensitive ('Enter code'); 'Promo code' verifies (through denies())")
        try check(run("AXTextArea", texts: []).denial == .field && run("AXTextArea", texts: ["Notes"]).proof?.bracket != nil,
                  "QF-4 Codex 06:10 (bracketed \(name)): an unlabelled text area: field (fix/chrome-capture c68da12); a labelled one verifies")
        try check(run("AXTextField", texts: ["Enter a value"]).denial == .sensitiveField && run("AXTextArea", texts: ["Number:"]).denial == .sensitiveField
                  && run("AXTextField", texts: ["Order number"]).proof?.bracket != nil,
                  "QF-4 Codex 06:10 (bracketed \(name)): a label of only 'Number' or 'Value': sensitiveField (through denies()); 'Order number' verifies")
        try check(run("AXTextField", texts: ["•••• •••• •••• ••••"]).denial == .sensitiveField, "QF-4 (bracketed \(name)): a mask-like label (maskLike, through denies()): sensitiveField")
        // The field loses its label between two reads (same element): the later read refuses, so no key between is admitted.
        for rule in [ChromeBracketRule.wholeRead, .perFact] {
            let w = FakeChromeWorld(); w.tick = 2 * ms; w.field.role = "AXTextField"
            w.field.labels = BrowserTypingFieldLabels(texts: ["Title"], identifiers: ["f"])
            let join = BrowserTypingJoin<FakeAXNode>(design: .bracketed), e = ChromeBracketEngine(rule: rule)
            func read() -> ChromeReadRecord? {
                let s = w.clock; e.readStarted(at: s); let r = w.run(join).proof?.bracket
                e.readFinished(start: s, end: w.clock, record: r); w.clock += 2 * ms; return r
            }
            let a = read(), key = w.clock; w.clock += 1 * ms
            w.field.labels = BrowserTypingFieldLabels(texts: [], identifiers: ["f"])
            let b = read()
            try check(a != nil && b == nil && !admitted(e.decide(typedAt: key, now: w.clock + 1)),
                      "QF-4 (bracketed \(name), \(rule == .wholeRead ? "wholeRead" : "perFact")): the box loses its label between reads: the later read refuses; the key between is not admitted")
        }
    }
}

// MARK: - RB1: a bracketed read's form scan fails closed (fix/chrome-capture 50c6a45), for every kind of box

private func checkFormScanFailsClosed() throws {
    let before = ChromeReadShape.current
    defer { ChromeReadShape.current = before }
    let pid = FakeChromeWorld.chromePID
    /// The field inside a form of `fillers` rows (and a password field last when `password`).
    func world(role: String, subrole: String = "", fillers: Int, password: Bool = false, wide: Int = 0) -> FakeChromeWorld {
        let w = FakeChromeWorld()
        let form = FakeAXNode("form", role: "AXGroup", parent: w.web, owner: pid)
        w.group.parent = form
        w.field.role = role; w.field.subrole = subrole
        w.field.labels = BrowserTypingFieldLabels(texts: ["Name of thing"], identifiers: ["curtext"])   // labelled: QF-4 (a) refuses an unlabelled one-line box
        for i in 0..<fillers { _ = FakeAXNode("t\(i)", role: "AXStaticText", parent: FakeAXNode("p\(i)", role: "AXGroup", parent: form, owner: pid), owner: pid) }
        for i in 0..<wide { _ = FakeAXNode("w\(i)", role: "AXStaticText", parent: w.group, owner: pid) }
        if password { _ = FakeAXNode("pw", role: "AXTextField", subrole: "AXSecureTextField", parent: FakeAXNode("p-pw", role: "AXGroup", parent: form, owner: pid), owner: pid) }
        return w
    }
    func run(_ w: FakeChromeWorld) -> BrowserTypingJoinResult { w.run(BrowserTypingJoin<FakeAXNode>(design: .bracketed)) }
    for shape in [ChromeReadShape.full, .lean] {
        ChromeReadShape.current = shape
        let name = shape == .full ? "full" : "lean"
        for (role, subrole, kind) in [("AXTextField", "", "one-line box"), ("AXTextArea", "", "text area"), ("AXTextField", "AXSearchField", "search field")] {
            try check(run(world(role: role, subrole: subrole, fillers: 20)).proof?.bracket != nil,
                      "RB1 (\(name), \(kind)): control: 20 rows, no password field: the read verifies")
            try check(run(world(role: role, subrole: subrole, fillers: 200)).denial == .field,
                      "RB1 (\(name), \(kind)): more than 64 nodes in scope, no password field: the scan is exhausted and the read fails closed (field), never clear")
            try check(run(world(role: role, subrole: subrole, fillers: 200, password: true)).denial == .field,
                      "RB1 (\(name), \(kind)): a password field past node 64: the read fails closed (field)")
            try check(run(world(role: role, subrole: subrole, fillers: 0, wide: 257)).denial == .field,
                      "RB1 (\(name), \(kind)): a container of more than 256 children: the read fails closed (field)")
            let u = world(role: role, subrole: subrole, fillers: 5); u.childrenUnreadable = true
            try check(run(u).denial == .field, "RB1 (\(name), \(kind)): children can't be read: the read fails closed (field)")
        }
        // A key between a clear read and an exhausted read (rows added between the reads) is never admitted, and a
        // key between a text-area read and a text-field read is never admitted (checkRoleChange).
        for rule in [ChromeBracketRule.wholeRead, .perFact] {
            let w = world(role: "AXTextArea", fillers: 20); w.tick = 2 * ms
            let join = BrowserTypingJoin<FakeAXNode>(design: .bracketed), e = ChromeBracketEngine(rule: rule)
            func read() -> ChromeReadRecord? {
                let s = w.clock; e.readStarted(at: s)
                let r = w.run(join).proof?.bracket
                e.readFinished(start: s, end: w.clock, record: r); w.clock += 2 * ms
                return r
            }
            let a = read(), key = w.clock
            w.clock += 1 * ms
            if let form = w.group.parent { for i in 0..<60 { _ = FakeAXNode("late\(i)", role: "AXStaticText", parent: form, owner: pid) } }
            let b = read(), c = read()
            try check(a != nil && b == nil && c == nil && !admitted(e.decide(typedAt: key, now: w.clock + 1)),
                      "RB1 (\(name), \(rule == .wholeRead ? "wholeRead" : "perFact")): rows added past node 64 between two reads: the later reads fail closed and the key between is not admitted")
        }
    }
}

// MARK: - RB2: nothing is read after the read ends; an unreadable ancestor role fails the read

private func checkNoReadsAfterRead() throws {
    let before = ChromeReadShape.current
    defer { ChromeReadShape.current = before }
    for shape in [ChromeReadShape.full, .lean] {
        ChromeReadShape.current = shape
        let name = shape == .full ? "full" : "lean"
        let w = FakeChromeWorld()
        let r = w.run(BrowserTypingJoin<FakeAXNode>(design: .bracketed))
        let end = w.log.lastIndex(of: "env:launch") ?? -1
        try check(r.proof?.bracket != nil && end >= 0 && !w.log[(end + 1)...].contains { $0.hasPrefix("ax:") || $0.hasPrefix("ae:") },
                  "RB2 (\(name)): no Accessibility or Apple Event read after the read's closing observation (the digest uses what the walk read)")
        let roleReads = w.log.filter { $0.hasPrefix("ax:role:") }
        try check(Set(roleReads).count == roleReads.count || roleReads.filter { $0 == "ax:role:group" }.count <= 2,
                  "RB2 (\(name)): ancestor roles are read once by the walk, not again for the digest")
        // An ancestor whose role can't be read fails the read (no "?" placeholder in the digest).
        let u = FakeChromeWorld()
        var access = u.access
        let plain = access.role
        access.role = { $0 === u.group ? nil : plain($0) }
        let d = BrowserTypingJoin<FakeAXNode>(design: .bracketed).join(environment: u.environment, appleEvents: u.ae, accessibility: access,
                                                                      blockList: BrowserTypingBlockList(), alwaysBlocked: PrivacySettings.sensitiveDomains)
        try check(d.proof == nil && d.denial != nil, "RB2 (\(name)): an ancestor role that can't be read fails the read")
    }
}

// MARK: - The reviewer's role check: each read uses its own role and subrole

/// A key typed between a read that saw a text area and a read that saw a text field (the same element changed kind,
/// or focus moved to a field of another kind with the same ref) is never admitted: the focus fact differs, so the
/// reads are not equal (B1), whatever the rule or read shape.
private func checkRoleChange() throws {
    let before = ChromeReadShape.current
    defer { ChromeReadShape.current = before }
    for shape in [ChromeReadShape.full, .lean] {
        ChromeReadShape.current = shape
        for rule in [ChromeBracketRule.wholeRead, .perFact] {
            let w = FakeChromeWorld(); w.tick = 2 * ms
            let join = BrowserTypingJoin<FakeAXNode>(design: .bracketed)
            let e = ChromeBracketEngine(rule: rule)
            func read() -> ChromeReadRecord? {
                let s = w.clock; e.readStarted(at: s)
                let r = w.run(join).proof?.bracket
                e.readFinished(start: s, end: w.clock, record: r); w.clock += 2 * ms
                return r
            }
            let a = read()
            let key = w.clock
            w.clock += 1 * ms
            w.field.role = "AXTextField"
            let b = read(), c = read()
            let name = "\(shape == .full ? "full" : "lean"), \(rule == .wholeRead ? "wholeRead" : "perFact")"
            try check(a != nil && b != nil && c != nil && a?.sameFacts(as: b!) == false,
                      "role check (\(name)): a text-area read and a text-field read of the same element are not equal")
            try check(!admitted(e.decide(typedAt: key, now: w.clock + 1)),
                      "role check (\(name)): a key typed between a text-area read and a text-field read is not admitted")
            try check(b?.sameFacts(as: c!) == true, "role check (\(name)): two text-field reads are equal (control)")
        }
    }
}

// MARK: - Feasibility prototype (ChromeReadShape.lean, not reviewed): 2 Apple Events per read

private func checkLeanShape() throws {
    let before = ChromeReadShape.current
    ChromeReadShape.current = .lean
    defer { ChromeReadShape.current = before }
    var w = FakeChromeWorld()
    let r = w.run(BrowserTypingJoin<FakeAXNode>(design: .bracketed))
    try check(r.proof?.bracket?.complete == true && w.aeCount == 2 && !w.log.contains { $0.hasPrefix("ae:name") || $0.hasPrefix("ae:url") || $0.hasPrefix("ae:activeTab") },
              "lean prototype: one read is 2 Apple Events (mode and bounds of every window), no name, tab or URL event")
    try check((w.log.firstIndex(of: "ae:modes") ?? Int.max) < (w.log.firstIndex { FakeChromeWorld.isContent($0) } ?? Int.max),
              "lean prototype: the mode gate still comes before any content read")
    w = FakeChromeWorld(); w.addWindow("202", mode: "incognito", front: false)
    try check(w.run(BrowserTypingJoin<FakeAXNode>(design: .bracketed)).denial == .notNormal, "lean prototype: an Incognito window refuses at the mode gate")
    w = FakeChromeWorld(); w.addWindow("202", mode: "normal", front: false, bounds: FakeChromeWorld.bounds)
    try check(w.run(BrowserTypingJoin<FakeAXNode>(design: .bracketed)).proof == nil, "lean prototype: two windows with the focused window's bounds refuse (no name to tell them apart)")
    // A full-shape read and a lean read never bracket together.
    // Feasibility (measured on the fake clock): a key typed during a read, 3 reads back to back.
    for rule in [ChromeBracketRule.wholeRead, .perFact] {
        for tick: UInt64 in [12, 23] {
            let w = FakeChromeWorld(); w.tick = tick * ms
            let join = BrowserTypingJoin<FakeAXNode>(design: .bracketed)
            let e = ChromeBracketEngine(rule: rule)
            var key: UInt64 = 0, read = 0
            w.onAppleEvent = { r, _ in if read == 1 && r == .modes && key == 0 { key = w.clock - tick * ms / 2 } }
            for i in 0..<3 {
                read = i
                let s = w.clock; e.readStarted(at: s)
                let res = w.run(join)
                e.readFinished(start: s, end: w.clock, record: res.proof?.bracket)
                w.clock += 1 * ms
            }
            let name = rule == .wholeRead ? "wholeRead" : "perFact"
            let d = e.decide(typedAt: key, now: 10_000 * ms)
            try check(admitted(d),
                      "lean prototype (\(name), \(tick) ms/event): a key typed while the mode event is in flight is \(admitted(d) ? "admitted" : "not admitted") (measured)")
        }
    }
}

// MARK: - PB2: fix/chrome-capture's QF-10 title match and QF-11/QF-3 checks in every bracketed read

private func checkBracketedJoinCapture() throws {
    func read(_ w: FakeChromeWorld, _ j: BrowserTypingJoin<FakeAXNode>) -> BrowserTypingJoinResult { w.run(j) }
    // QF-10: Chrome's AX title carries " - Google Chrome" (and a profile): the same match as the synchronous join.
    for suffix in [" - Google Chrome", " - Google Chrome - Work"] {
        let w = FakeChromeWorld(); w.window.title = FakeChromeWorld.title + suffix
        try check(read(w, BrowserTypingJoin(design: .bracketed)).proof?.bracket != nil, "PB2/QF-10: the bracketed read matches an AX title with '\(suffix)'")
    }
    // QF-11 / QF-3 (P04): a password field in the field's form, or a show-password control beside it.
    var w = FakeChromeWorld()
    _ = FakeAXNode("form-pw", role: "AXTextField", subrole: "AXSecureTextField", parent: w.group, owner: FakeChromeWorld.chromePID)
    try check(read(w, BrowserTypingJoin(design: .bracketed)).denial == .sensitiveField, "PB2/QF-11 (P04): a password field in the form refuses the bracketed read")
    w = FakeChromeWorld()
    let b = FakeAXNode("toggle", role: "AXButton", parent: w.group, owner: FakeChromeWorld.chromePID); b.title = "Show password"
    try check(read(w, BrowserTypingJoin(design: .bracketed)).denial == .sensitiveField, "PB2/QF-11: a show-password control beside the field refuses the bracketed read")
    w = FakeChromeWorld(); w.childrenUnreadable = true
    try check(read(w, BrowserTypingJoin(design: .bracketed)).denial == .field, "PB2/QF-11: the form scan fails closed when children can't be read")
    // M7: in every read, not only the first: a password field added after a verified read refuses the next one.
    w = FakeChromeWorld()
    let j = BrowserTypingJoin<FakeAXNode>(design: .bracketed)
    try check(read(w, j).proof?.bracket != nil, "PB2/M7: the first bracketed read is verified")
    _ = FakeAXNode("late-pw", role: "AXTextField", subrole: "AXSecureTextField", parent: w.group, owner: FakeChromeWorld.chromePID)
    try check(read(w, j).denial == .sensitiveField, "PB2/M7: a password field added after a verified read refuses the next read")
    // QF-11 secure-focus memory: the same field, secure then shown as text.
    w = FakeChromeWorld(); w.field.role = "AXTextField"; w.field.subrole = "AXSecureTextField"
    let k = BrowserTypingJoin<FakeAXNode>(design: .bracketed)
    try check(read(w, k).denial == .field, "PB2/QF-11: a secure focused field refuses the bracketed read")
    w.field.subrole = ""
    try check(read(w, k).denial == .sensitiveField, "PB2/QF-11: the same field shown as text is remembered and refused (secure-focus memory)")
    // QF-3: a sign-in username on its own.
    w = FakeChromeWorld(); w.field.labels = BrowserTypingFieldLabels(texts: ["Username"], identifiers: [])
    try check(read(w, BrowserTypingJoin(design: .bracketed)).denial == .sensitiveField, "PB2/QF-3: a username field refuses the bracketed read")
}

// MARK: - PB3 / N-B3: the switch

private func checkDesignSwitch() throws {
    try check(ChromeJoinDesign.current == .synchronous, "PB3: the design switch defaults to the synchronous (4108ea4) join")
    try check(BrowserTypingJoin<FakeAXNode>().design == .synchronous, "PB3: a join made without a design is synchronous")
    try check(ChromeBracketRule.current == .wholeRead, "B1: the bracket rule defaults to the conservative whole-read form")
    try check(ChromeBracketTiming.spanNanoseconds == 150 * ms, "B1 (rev 3.1): SPAN is 150 ms, one named constant (300 ms is not approved)")
    // The synchronous join keeps its double read and takes no bracket record. fix/chrome-root: it now asks every
    // window's mode and bounds in one event each (QF-17's batched reads; per-window events overran every budget on a
    // real Mac), so it is 16 Apple Events whatever the window count (it was 16 for one window, 26 for three).
    let w = FakeChromeWorld()
    let r = w.run(BrowserTypingJoin<FakeAXNode>(design: .synchronous))
    try check(r.proof != nil && r.proof?.bracket == nil && w.aeCount == 16 && w.log.filter({ $0 == "ae:modes" }).count == 3
              && w.log.filter({ $0 == "ae:allBounds" }).count == 2 && !w.log.contains(where: { $0.hasPrefix("ae:mode:") && !$0.contains("=") }),
              "PB3: the synchronous join is a double read with batched mode and bounds reads (16 Apple Events, no bracket record)")
}

// MARK: - B1 rev 3.1: the per-fact span and the owner's counterexample

private func checkCounterexample() throws {
    let w = Obj(), f = Obj()
    for rule in [ChromeBracketRule.wholeRead, .perFact] {
        let name = rule == .wholeRead ? "wholeRead" : "perFact"
        // The owner's counterexample: two ~120 ms reads, a 150 ms gap, a key in the gap.
        var e = engine(rule, [record(0, 120, window: w, focus: f), record(270, 390, window: w, focus: f)])
        try check(e.decide(typedAt: 195 * ms, now: 400 * ms) == .discard, "rev 3.1 counterexample (\(name)): two 120 ms reads, 150 ms gap, key in the gap: discarded")
        // A gap under 150 ms is still refused when the per-fact span is over it (never a gap-only limit).
        e = engine(rule, [record(0, 120, window: w, focus: f), record(160, 280, window: w, focus: f)])
        try check(e.decide(typedAt: 140 * ms, now: 300 * ms) == .discard, "rev 3.1 counterexample (\(name)): 40 ms gap, 120 ms reads (per-fact span > 150 ms): discarded")
        e = engine(rule, [record(0, 140, window: w, focus: f), record(150, 290, window: w, focus: f)])
        try check(e.decide(typedAt: 145 * ms, now: 300 * ms) == .discard, "rev 3.1 counterexample (\(name)): 10 ms gap, 140 ms reads (span 150 + one observation): discarded")
        // Just inside: 60 ms reads, 20 ms gap: every fact's span is under 150 ms.
        e = engine(rule, [record(0, 60, window: w, focus: f), record(80, 140, window: w, focus: f)])
        let d = e.decide(typedAt: 70 * ms, now: 150 * ms)
        try check(admitted(d), "rev 3.1 just inside (\(name)): 60 ms reads, 20 ms gap: admitted")
        // D2: a key typed during Ri needs R(i-1) and R(i+1) (whole reads); with 80 ms reads that is over the span.
        e = engine(rule, [record(0, 80, window: w, focus: f), record(82, 162, window: w, focus: f), record(164, 244, window: w, focus: f)])
        let during = e.decide(typedAt: 120 * ms, now: 250 * ms)
        // perFact too: the observation in flight at the key (sent before it, answered after it) can be neither side,
        // so that fact's bracket is R(i-1)..R(i+1): about two reads.
        try check(during == .discard, "D2 (\(name)): a key typed during Ri with 80 ms reads (the straddled fact spans two reads): discarded")
        e = engine(rule, [record(0, 40, window: w, focus: f), record(42, 82, window: w, focus: f), record(84, 124, window: w, focus: f)])
        let short = e.decide(typedAt: 60 * ms, now: 130 * ms)
        try check(admitted(short), "D2 (\(name)): a key typed during Ri with 40 ms reads (R(i-1)..R(i+1) within the span): admitted")
        // Ties go to discard: a key at Ra's last reply tick or Rb's first send tick is not admitted. (Per fact the
        // tie is per observation, so every fact here is one observation spanning its whole read.)
        func whole(_ a: UInt64, _ b: UInt64) -> [ChromeFact: [ChromeFactTimes]] {
            Dictionary(uniqueKeysWithValues: ChromeFact.allCases.map { ($0, [ChromeFactTimes(sent: a * ms, received: b * ms)]) })
        }
        e = engine(rule, [record(0, 60, window: w, focus: f, times: whole(0, 60)), record(80, 140, window: w, focus: f, times: whole(80, 140))])
        try check(!admitted(e.decide(typedAt: 60 * ms, now: 150 * ms)) && !admitted(e.decide(typedAt: 80 * ms, now: 150 * ms)),
                  "B1 (\(name)): a key at the exact endpoint tick is not admitted")
        // Unequal facts across the bracket (another URL digest): discarded.
        e = engine(rule, [record(0, 60, window: w, focus: f), record(80, 140, digest: 2, window: w, focus: f)])
        try check(e.decide(typedAt: 70 * ms, now: 150 * ms) == .discard, "B1 (\(name)): a fact that differs between the bracketing reads: discarded")
        // A failed or refused read inside the bracket: discarded.
        e = engine(rule, [record(0, 40, window: w, focus: f), nil, record(80, 120, window: w, focus: f)], starts: [(0, 0), (45, 75), (0, 0)])
        try check(e.decide(typedAt: 42 * ms, now: 150 * ms) == .discard && e.decide(typedAt: 77 * ms, now: 150 * ms) == .discard,
                  "B1 (\(name)): a failed read between the bracketing reads breaks the chain")
        // Waiting: no b-side yet but still feasible; infeasible once the span can no longer be met.
        e = engine(rule, [record(0, 60, window: w, focus: f)])
        e.readStarted(at: 80 * ms)
        try check(e.decide(typedAt: 70 * ms, now: 90 * ms) == .wait, "B1 (\(name)): no later read yet, span still feasible: waits")
        try check(e.decide(typedAt: 70 * ms, now: 200 * ms) == .wait, "B1 (\(name)): qualifying pending read waits for actual facts even after delivery delay")
        e.readFinished(start: 80 * ms, end: 220 * ms, record: record(80, 220, window: w, focus: f))
        try check(e.decide(typedAt: 70 * ms, now: 221 * ms) == .discard, "B1 (\(name)): actual late facts still exceed the original span and discard")
    }
}

// MARK: - D1: which timestamp goes where

private func checkTimestamps() throws {
    let w = Obj(), f = Obj()
    for rule in [ChromeBracketRule.wholeRead, .perFact] {
        let name = rule == .wholeRead ? "wholeRead" : "perFact"
        // The span uses obs_a.sendStarted: a slow a-side reply (sent 0, received 40) and a b-side reply at 180 is a
        // span of 180 ms even though the replies are only 140 ms apart.
        let slowA: [ChromeFact: [ChromeFactTimes]] = [.url: [ChromeFactTimes(sent: 0, received: 40 * ms)]]
        let lateB: [ChromeFact: [ChromeFactTimes]] = [.url: [ChromeFactTimes(sent: 160 * ms, received: 180 * ms)]]
        var e = engine(rule, [record(0, 50, window: w, focus: f, times: slowA), record(100, 190, window: w, focus: f, times: lateB)])
        try check(e.decide(typedAt: 70 * ms, now: 200 * ms) == .discard, "D1 (\(name)): the span runs from the a-side SEND to the b-side REPLY (replies 140 ms apart, span 180 ms): discarded")
        // Containment uses the a-side REPLY: an observation sent before the key but answered after it can't be Ra.
        if rule == .perFact {
            let straddle: [ChromeFact: [ChromeFactTimes]] = [.url: [ChromeFactTimes(sent: 20 * ms, received: 60 * ms)]]
            e = engine(rule, [record(0, 70, window: w, focus: f, times: straddle), record(90, 150, window: w, focus: f)])
            try check(!admitted(e.decide(typedAt: 50 * ms, now: 160 * ms)), "D1 (perFact): an observation replied after the key is not its a-side")
        }
    }
    // Every observation keeps its own times: IDs and focus state are observed twice in one read.
    let fw = FakeChromeWorld()
    let r = fw.run(BrowserTypingJoin<FakeAXNode>(design: .bracketed))
    let rec = r.proof?.bracket
    try check(rec?.times[.windowIDs]?.count == 2 && rec?.times[.focusState]?.count == 2 && rec?.complete == true,
              "D1: a read keeps a separate observation (send and reply time) for each read of a fact")
    try check(rec.map { r in r.times.values.allSatisfy { $0.allSatisfy { $0.sent >= r.start && $0.received >= $0.sent && $0.received <= r.end } } } == true,
              "D1/N3: every observation is timed on the read's clock, inside the read")
}

// MARK: - R1 / D3: keys before the first verified read

private func checkFirstRead() throws {
    let w = Obj(), f = Obj()
    for rule in [ChromeBracketRule.wholeRead, .perFact] {
        let name = rule == .wholeRead ? "wholeRead" : "perFact"
        let e = ChromeBracketEngine(rule: rule)
        e.readStarted(at: 0)
        try check(e.decide(typedAt: 5 * ms, now: 6 * ms) != .discard || rule == .wholeRead, "R1 (\(name)): a key during R0 is undecided while R0 runs")
        e.readFinished(start: 0, end: 60 * ms, record: record(0, 60, window: w, focus: f))
        e.readFinished(start: 62 * ms, end: 120 * ms, record: record(62, 120, window: w, focus: f))
        e.readFinished(start: 122 * ms, end: 180 * ms, record: record(122, 180, window: w, focus: f))
        try check(e.decide(typedAt: 5 * ms, now: 200 * ms) == .discard, "R1 (\(name)): a key typed during R0 is never admitted from later reads")
        let none = ChromeBracketEngine(rule: rule)
        try check(none.decide(typedAt: 5 * ms, now: 6 * ms) == .discard, "R1 (\(name)): a key with no read in flight is discarded")
    }
}

// MARK: - B2 / PM4: refs and the ancestry chain

private func checkChain() throws {
    let w = Obj(), f = Obj(), web = Obj(), g1 = Obj(), g2 = Obj()
    for rule in [ChromeBracketRule.wholeRead, .perFact] {
        let name = rule == .wholeRead ? "wholeRead" : "perFact"
        var e = engine(rule, [record(0, 60, window: w, focus: f, chain: [f, g1, web, w]), record(80, 140, window: w, focus: f, chain: [f, g1, web, w])])
        try check(admitted(e.decide(typedAt: 70 * ms, now: 150 * ms)), "PM4 (\(name)): the same ancestry objects: admitted")
        e = engine(rule, [record(0, 60, window: w, focus: f, chain: [f, g1, web, w]), record(80, 140, window: w, focus: f, chain: [f, g2, web, w])])
        try check(e.decide(typedAt: 70 * ms, now: 150 * ms) == .discard, "PM4 (\(name)): another ancestry node (same roles): discarded")
        e = engine(rule, [record(0, 60, window: w, focus: f), record(80, 140, window: w, focus: Obj())])
        try check(e.decide(typedAt: 70 * ms, now: 150 * ms) == .discard, "B2 (\(name)): another focused element between the reads: discarded")
        e = engine(rule, [record(0, 60, window: w, focus: f), record(80, 140, pid: 4343, window: w, focus: f)])
        try check(e.decide(typedAt: 70 * ms, now: 150 * ms) == .discard, "B2 (\(name)): another Chrome process between the reads: discarded")
        e = engine(rule, [record(0, 60, window: w, focus: f), record(80, 140, launch: "M", window: w, focus: f)])
        try check(e.decide(typedAt: 70 * ms, now: 150 * ms) == .discard, "B2 (\(name)): a relaunched Chrome between the reads: discarded")
    }
}

// MARK: - B3 / R4 / D4: boundaries

private func checkBoundaries() throws {
    let w = Obj(), f = Obj()
    for rule in [ChromeBracketRule.wholeRead, .perFact] {
        let name = rule == .wholeRead ? "wholeRead" : "perFact"
        var e = engine(rule, [record(0, 60, window: w, focus: f), record(80, 140, window: w, focus: f)])
        e.boundary(at: 75 * ms)
        try check(e.decide(typedAt: 70 * ms, now: 150 * ms) == .discard, "R4 (\(name)): a boundary after the key, inside the bracket: discarded")
        e = engine(rule, [record(0, 60, window: w, focus: f), record(80, 140, window: w, focus: f)])
        e.boundary(at: 30 * ms)
        try check(e.decide(typedAt: 70 * ms, now: 150 * ms) == .discard, "R4 (\(name)): a boundary inside Ra (before the key): discarded")
        e = engine(rule, [record(0, 60, window: w, focus: f), record(80, 140, window: w, focus: f)])
        // D4: an AX notification carries no time; received after Ra.start and before the decision, it is stamped
        // at receipt, which is inside [Ra.start, now]: the key waiting for its bracket is discarded.
        let waiting = engine(rule, [record(0, 60, window: w, focus: f)])
        waiting.readStarted(at: 80 * ms)
        waiting.boundary(at: 85 * ms)            // the notification, received while the b-side read runs
        try check(waiting.decide(typedAt: 70 * ms, now: 90 * ms) == .discard, "D4 (\(name)): a window/title notification received before admission: discarded")
        e.boundary(at: 145 * ms)                 // after the bracket: no effect on it
        try check(admitted(e.decide(typedAt: 70 * ms, now: 150 * ms)), "B3 (\(name)): a boundary after the bracket does not affect it")
        try check(e.verified(endingBefore: 70 * ms)?.end == 60 * ms && e.verified(endingBefore: 50 * ms) == nil,
                  "D3: a key's Ra is the latest read that ended before it, even when a later read was delivered first")
        e.reset()
        try check(e.decide(typedAt: 70 * ms, now: 150 * ms) == .discard && e.lastVerified == nil, "B3: a reset (privacy denial, policy change) forgets every read")
    }
}

// MARK: - B4 / R8: held keys

private func checkHeldKeys() throws {
    let sentinel = "ZQXSENTINEL"
    let w = ref(Obj()), f = ref(Obj())
    var held = ChromeHeldKeys()
    try check(held.allZero, "B4: the owned buffer starts zeroed")
    for (i, ch) in sentinel.enumerated() { _ = held.append(typedAt: UInt64(i) * ms, kind: .text, window: w, focus: f, characters: String(ch)) }
    try check(!held.allZero && held.count == sentinel.count, "B4: held characters live in the owned buffer")
    var dumped = ""; dump(held, to: &dumped)
    try check(!dumped.contains(sentinel) && !dumped.contains("ZQX") && !String(describing: held.keys).contains("ZQX"),
              "B4/R8: no description or mirror of the held keys shows their characters")
    var back = ""
    while let (k, c) = held.takeFirst() { back += c; _ = k }
    try check(back == sentinel && held.allZero, "B4: admitted keys come out in order and the buffer is zero after the last")
    // Every discard path leaves the buffer zero.
    for path in ["wipe", "dropFirst", "overflow-keys", "overflow-age", "overflow-bytes", "deinit"] {
        held = ChromeHeldKeys()
        for i in 0..<5 { _ = held.append(typedAt: UInt64(i) * ms, kind: .text, window: w, focus: f, characters: "Q\(i)") }
        switch path {
        case "wipe": held.wipe()
        case "dropFirst": while !held.isEmpty { held.dropFirst() }
        case "overflow-keys":
            var r = ChromeHeldKeys.Append.held
            for i in 5..<70 where r == .held { r = held.append(typedAt: UInt64(i) * ms, kind: .text, window: w, focus: f, characters: "x") }
            try check(r == .overflow && held.count == ChromeBracketTiming.holdMaxKeys, "R8: the 65th held key overflows (64-key cap)")
            held.wipe()
        case "overflow-age":
            try check(held.append(typedAt: 1_100 * ms, kind: .text, window: w, focus: f, characters: "x") == .overflow, "R8: a key over 1 s after the oldest held key overflows")
            held.wipe()
        case "overflow-bytes":
            try check(held.append(typedAt: 6 * ms, kind: .text, window: w, focus: f, characters: String(repeating: "é", count: 9)) == .overflow,
                      "B4: a key over 16 bytes overflows")
            held.wipe()
        default:
            // deinit wipes before freeing (checked through a buffer that is then dropped).
            weak var gone: ChromeHeldKeys?
            do { let h = ChromeHeldKeys(); _ = h.append(typedAt: 0, kind: .text, window: w, focus: f, characters: "Q"); gone = h }
            try check(gone == nil, "B4: the buffer is freed with its owner (deinit wipes it first)")
            continue
        }
        try check(held.allZero && held.isEmpty, "B4: the held buffer is all zero after \(path)")
    }
    try check(ChromeBracketTiming.holdMaxKeys == 64 && ChromeBracketTiming.holdMaxNanoseconds == 1_000 * ms, "B4: the caps are 64 keys and 1 s")
    // TypingOp (an edit held with no characters) never prints its content.
    try check(String(describing: ChromeHeldKind.edit(.insert(sentinel))).contains(sentinel) == false, "B5: a held edit's description shows no text")
}

// MARK: - B5 / D6: diagnostics

private func checkDiagnostics() throws {
    let d = ChromeBracketDiagnostics()
    d.keyAdmitted(); d.keyLost(3, .bracket); d.privacyRefusal()
    try check(d.snapshot()["keys.lost"] == 0, "D6/B5: keys lost before a privacy refusal are never counted")
    d.keyLost(2, .unread); d.confirm()
    try check(d.snapshot()["keys.lost"] == 2 && d.snapshot()["keys.admitted"] == 1 && d.snapshot()["keys.lost.unread"] == 2,
              "B5: a loss is counted once a later read proves no privacy refusal, under its reason")
    // QF-17 key accounting (b+ silent loss on 939e6df): admitted = saved + dropped + pending; what leaves the session
    // unwritten is counted dropped with a reason, never silently.
    let k = ChromeBracketDiagnostics()
    for _ in 0..<5 { k.keyAdmitted() }; k.admitUnits(5); k.saved(2)
    k.reconcile(sessionPending: 1, reason: .retract)
    try check(k.droppedByReason[.retract] == 2 && k.snapshot()["keys.dropped"] == 2 && k.snapshot()["keys.saved"] == 2 && k.snapshot()["keys.pending"] == 1
              && k.balanced(sessionPending: 1) && !k.balanced(sessionPending: 0),
              "key accounting: 5 admitted, 2 saved, 1 pending: the 2 retracted are dropped (retract); admitted = saved + dropped + pending")
    k.reconcile(sessionPending: 0, reason: .privacy)
    try check(k.droppedByReason[.privacy] == 1 && k.snapshot()["keys.dropped"] == 3 && k.snapshot()["keys.lost"] == 0 && k.balanced(sessionPending: 0)
              && !k.snapshot().keys.contains { $0.hasPrefix("keys.dropped.") },
              "key accounting: a pending key dropped by a privacy boundary is counted in the undivided keys.dropped (its reason stays inside), never lost")
    // Review 08:29: an over-count is a counted bookkeeping error, never a crash.
    let over = ChromeBracketDiagnostics(); over.reconcile(sessionPending: 1, reason: .retract)
    try check(over.ledgerErrors == 1 && !over.balanced(sessionPending: 1), "key accounting: more accounted than admitted is counted (ledgerErrors), not a crash")
    d.read(verified: true, milliseconds: 84, events: 7); d.intake(microseconds: 40)
    // B5-1 (fix/chrome-capture 42d966e): a refused read leaves the same line whatever its reason: only reads.denied
    // moves; no timing and no event count (a mode-gate refusal after one event and a field refusal after seven would
    // otherwise differ).
    let quick = ChromeBracketDiagnostics(), slow = ChromeBracketDiagnostics()
    quick.read(verified: true, milliseconds: 84, events: 7); slow.read(verified: true, milliseconds: 84, events: 7)
    quick.read(verified: false, milliseconds: 12, events: 1); slow.read(verified: false, milliseconds: 150, events: 7)
    try check(quick.snapshot() == slow.snapshot() && quick.snapshot()["reads.denied"] == 1,
              "B5-1: a refused read's time and event count leave no trace (a quick mode-gate refusal and a slow field refusal read alike)")
    let snap = d.snapshot()
    // QF-17 silent-loss fix (review 08:29): 11 pinned keys + keys.saved, keys.dropped (undivided), keys.pending and one
    // key per fixed loss reason (never per key, field or site; never a drop reason).
    try check(Set(snap.keys) == ChromeBracketDiagnostics.allowedKeys && ChromeBracketDiagnostics.allowedKeys.count == 17,
              "B5: diagnostics have only the 17 pinned aggregate keys (no per-key, per-field or per-site split; no drop reason)")
    try check(!ChromeBracketDiagnostics.allowedKeys.contains { $0.contains("reason") || $0.contains("site") || $0.contains("field") || $0.contains("held") },
              "B5/D6: no per-reason or held-drop counter")
    let text = String(describing: snap) + String(reflecting: d)
    try check(!text.contains("ZQX") && !text.contains("http") && !text.contains("mail"), "R8: the diagnostics line carries no text, title or address")
}

// MARK: - M6 / PM7: the audit

private func checkAudit() throws {
    func code(_ s: String) -> UInt32 { ChromeAppleEvents.code(s) }
    func obj(_ want: String, _ form: String, _ key: NSAppleEventDescriptor, _ from: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        let r = NSAppleEventDescriptor.record()
        r.setDescriptor(NSAppleEventDescriptor(typeCode: code(want)), forKeyword: code("want"))
        r.setDescriptor(NSAppleEventDescriptor(enumCode: code(form)), forKeyword: code("form"))
        r.setDescriptor(key, forKeyword: code("seld")); r.setDescriptor(from, forKeyword: code("from"))
        return r.coerce(toDescriptorType: code("obj "))
    }
    var all = code("all ")
    guard let abso = NSAppleEventDescriptor(descriptorType: code("abso"), bytes: &all, length: 4),
          let every = obj("cwin", "indx", abso, .null()) else { throw MemError.invalid("FAILED: audit fixture") }
    func prop(_ p: String) -> NSAppleEventDescriptor? { obj("prop", "prop", NSAppleEventDescriptor(typeCode: code(p)), every) }
    let typing = ChromeJoinRequest.everyWindow
    try check(prop("ID  ").map { ChromeAppleEvents.audit($0) } == true, "PM7: ID of every window passes the default audit (fixture control)")
    for p in ["mode", "pbnd"] {
        try check(prop(p).map { ChromeAppleEvents.audit($0) } == false, "PM7: \(p) of every window is refused for page history and every other default caller")
        try check(prop(p).map { ChromeAppleEvents.audit($0, everyWindow: typing) } == true, "PM7: \(p) of every window is accepted for Chrome typing's batched read")
    }
    for p in ["pnam", "URL ", "acTa"] {
        try check(prop(p).map { ChromeAppleEvents.audit($0, everyWindow: typing) } == false && prop(p).map { ChromeAppleEvents.audit($0, everyWindow: [p]) } == false,
                  "PM7: \(p) of every window is refused, whatever the caller passes")
    }
    try check(ChromeJoinRequest.modes.specifier != nil && ChromeJoinRequest.allBounds.specifier != nil && typing == ["ID  ", "mode", "pbnd"],
              "M6: the batched mode and bounds requests build audited specifiers")
}

// MARK: - The bracketed read against the fake Chrome

private func checkBracketedJoin() throws {
    var w = FakeChromeWorld()
    var join = BrowserTypingJoin<FakeAXNode>(design: .bracketed)
    let r = w.run(join)
    guard let rec = r.proof?.bracket else { throw MemError.invalid("FAILED: bracketed baseline read refused: \(String(describing: r.denial))") }
    try check(rec.complete && w.aeCount == 7, "M6: one bracketed read is 7 Apple Events (IDs, modes, bounds, IDs, name, tab, URL) with every fact observed")
    let firstContent = w.log.firstIndex { FakeChromeWorld.isContent($0) } ?? Int.max
    try check((w.log.firstIndex(of: "ae:modes") ?? Int.max) < firstContent, "M6: every window's mode is read before any bounds, name, tab, URL or AX content")
    try check((w.log.firstIndex { $0.hasPrefix("ax:url:") } ?? Int.max) < (w.log.firstIndex { $0.hasPrefix("ax:labels:") } ?? -1),
              "M7: the field's labels are read after the page URLs agree")
    try check(r.proof.map { !Mirror(reflecting: $0).children.map { "\($0.value)" }.joined().contains("compose") } == true,
              "the bracketed proof carries no path, title or label")
    // The mode gate: an Incognito or unreadable window refuses before any content read.
    for mode in ["incognito", nil] as [String?] {
        w = FakeChromeWorld(); w.addWindow("202", mode: mode, front: false); join = BrowserTypingJoin<FakeAXNode>(design: .bracketed)
        let d = w.run(join)
        try check(d.denial == .notNormal && !w.log.contains { FakeChromeWorld.isContent($0) },
                  "M6: \(mode ?? "an unreadable") window refuses at the mode gate before any content read")
    }
    // M7: sensitivity in every read, not only the first.
    w = FakeChromeWorld(); join = BrowserTypingJoin<FakeAXNode>(design: .bracketed)
    _ = w.run(join)
    w.field.labels = BrowserTypingFieldLabels(texts: ["Password"], identifiers: [])
    try check(w.run(join).denial == .sensitiveField, "M7: a field that becomes sensitive is refused by the next read")
    // A blocked site: no label is read.
    w = FakeChromeWorld(); join = BrowserTypingJoin<FakeAXNode>(design: .bracketed)
    let b = w.run(join, alwaysBlocked: ["mail.google.com"])
    try check(b.denial == .blockedSite && !w.log.contains { $0.hasPrefix("ax:labels:") }, "M7: a blocked site refuses before any label is read")
    // M9: a read over its budget is refused. 12 ms per event fits (7 x 12 = 84 ms); 23 ms per event does NOT
    // (7 x 23 = 161 ms > the 150 ms budget: the measured tail makes every read time out); 60 ms neither.
    for (tick, ok) in [(12, true), (23, false), (60, false)] {
        w = FakeChromeWorld(); w.tick = UInt64(tick) * ms; join = BrowserTypingJoin<FakeAXNode>(design: .bracketed)
        let t = w.run(join)
        try check((t.proof?.bracket != nil) == ok && (ok || t.denial == .timeout), "M9: \(tick) ms per Apple Event: the read is \(ok ? "verified" : "refused at its 150 ms budget")")
    }
    // M3: the light check never runs in the bracketed design.
    w = FakeChromeWorld(); join = BrowserTypingJoin<FakeAXNode>(design: .bracketed)
    _ = w.run(join)
    let light = join.light(environment: w.environment, appleEvents: w.ae, accessibility: w.access, blockList: BrowserTypingBlockList(), alwaysBlocked: [])
    try check(light == nil, "M3: the light check never admits or bridges in the bracketed design")
}

// MARK: - R2 / R5 / R9: changes during a read, against the fake Chrome

private func checkBracketedJoinR2() throws {
    for rule in [ChromeBracketRule.wholeRead, .perFact] {
        let name = rule == .wholeRead ? "wholeRead" : "perFact"
        for tick: UInt64 in [5, 12] {
            // Three reads back to back; the key is typed early in R1 (after its IDs, before its URL step).
            func run(_ during: @escaping (FakeChromeWorld, ChromeJoinRequest) -> Void) -> (ChromeBracketEngine, UInt64) {
                let w = FakeChromeWorld(); w.tick = tick * ms
                let join = BrowserTypingJoin<FakeAXNode>(design: .bracketed)
                let e = ChromeBracketEngine(rule: rule)
                var key: UInt64 = 0, read = 0
                w.onAppleEvent = { r, _ in
                    if read == 1 && r == .windowIDs && key == 0 { key = w.clock + 1 }
                    if read == 1 { during(w, r) }
                }
                for i in 0..<3 {
                    read = i
                    let s = w.clock; e.readStarted(at: s)
                    let res = w.run(join)
                    e.readFinished(start: s, end: w.clock, record: res.proof?.bracket)
                    w.clock += 2 * ms
                }
                return (e, key)
            }
            var (e, key) = run({ _, _ in })
            let control = e.decide(typedAt: key, now: 10_000 * ms)
            if tick == 5 {
                // Control: 7 events x 5 ms = 35 ms reads: R0..R2 within the span, so an unchanged page admits the key.
                try check(admitted(control), "R6 control (\(name), 5 ms/event): an unchanged page brackets a key typed during a read")
            } else {
                // Measured infeasibility (rev 3.1 asks for it): at 12 ms/event a read is 84 ms, and a key typed while an
                // Apple Event is in flight needs R(i-1)..R(i+1) for that fact: about 180 ms > SPAN. Not admitted.
                try check(!admitted(control), "D2 measured (\(name), 12 ms/event): a key typed during an Apple Event of a 7-event read is over the span")
            }
            if case .admit(let ra, let rb) = control {
                try check(ra.start < key && rb.end > key, "R6 (\(name), \(tick) ms/event): the admitted key lies inside its bracket")
            }
            // R2: the path changes to /login before R1's URL step.
            (e, key) = run({ w, r in if case .activeTabID = r { w.windows[0].url = "https://mail.google.com/login"; w.web.url = "https://mail.google.com/login" } })
            try check(!admitted(e.decide(typedAt: key, now: 10_000 * ms)), "R2 (\(name), \(tick) ms/event): a path change before the URL step of the key's read: not admitted")
            // R2: the label turns into a code field before R1's sensitivity step.
            (e, key) = run({ w, r in if case .tabURL = r { w.field.labels = BrowserTypingFieldLabels(texts: ["Verification code"], identifiers: []) } })
            try check(!admitted(e.decide(typedAt: key, now: 10_000 * ms)), "R2 (\(name), \(tick) ms/event): a label change before the sensitivity step: not admitted")
            // R2/R9: a password field is inserted (focus moves to it) between reads.
            (e, key) = run({ w, r in
                if case .tabURL = r {
                    let p = FakeAXNode("pw", role: "AXSecureTextField", parent: w.group, owner: FakeChromeWorld.chromePID); w.axFocus = p
                }
            })
            try check(!admitted(e.decide(typedAt: key, now: 10_000 * ms)), "R9 (\(name), \(tick) ms/event): a password field inserted between reads: not admitted")
            // R2: an Incognito window opens after R1's mode step.
            (e, key) = run({ w, r in if case .allBounds = r, w.windows.count == 1 { w.addWindow("909", mode: "incognito", front: false) } })
            try check(!admitted(e.decide(typedAt: key, now: 10_000 * ms)), "R2 (\(name), \(tick) ms/event): an Incognito window opened after the mode step: not admitted")
            // R5: an Incognito window opened and closed inside R1 (ABA, no boundary): the documented behaviour is that
            // its IDs re-read catches it only if still open; when fully gone before any step sees it, keys are only
            // admitted if every fact of every read is equal (it is: nothing about the page changed).
            (e, key) = run({ w, r in
                if case .allBounds = r { w.addWindow("808", mode: "incognito", front: false) }
                if case .name = r { w.removeWindow("808") }
            })
            try check(!admitted(e.decide(typedAt: key, now: 10_000 * ms)), "R5 (\(name), \(tick) ms/event): an Incognito window open across R1's ID re-read: not admitted")
        }
    }
}

// MARK: - QF-17 silent-loss fix: perFact admission of a key typed in a read's opening observation

/// b+ real-Chrome self-check on 939e6df: lean-perFact saved 2 of 16 keys with 14 admitted and 0 lost. A key typed
/// during a read's opening observation (focusState: the frontmost, system-focus and secure-input checks, before any
/// Apple Event) is bracketed per fact with that same read as its b-side; the burst's check `rb.checkedAt > typedAt`
/// (the read's START) refused it and retracted the unit. Tier a never saw it: the fake's AX reads took no time.
private func checkPerFactOpeningAdmission() throws {
    let before = ChromeReadShape.current
    defer { ChromeReadShape.current = before }
    for shape in [ChromeReadShape.full, .lean] {
        ChromeReadShape.current = shape
        let name = shape == .full ? "full" : "lean"
        let w = FakeChromeWorld(); w.tick = shape == .full ? 2 * ms : 8 * ms; w.focusTick = 4 * ms
        let join = BrowserTypingJoin<FakeAXNode>(design: .bracketed)
        var proofs: [UUID: BrowserTypingJoinProof] = [:], starts: [UInt64] = []
        let per = ChromeBracketEngine(rule: .perFact), whole = ChromeBracketEngine(rule: .wholeRead)
        for _ in 0..<3 {
            let s = w.clock; starts.append(s); per.readStarted(at: s); whole.readStarted(at: s)
            let r = w.run(join)
            if let p = r.proof, let b = p.bracket { proofs[b.id] = p }
            per.readFinished(start: s, end: w.clock, record: r.proof?.bracket); whole.readFinished(start: s, end: w.clock, record: r.proof?.bracket)
        }
        // The key: 1 ms into R1, inside its opening observation (which takes 4 ms here).
        let key = starts[1] + 1 * ms, now = w.clock
        guard case .admit(let ra, let rb) = per.decide(typedAt: key, now: now), let pa = proofs[ra.id], let pb = proofs[rb.id],
              let bSide = per.admittedBSideSent else {
            try check(false, "silent loss (\(name)): control: the per-fact rule brackets a key typed in a read's opening observation"); continue
        }
        try check(rb.start < key && bSide > key,
                  "silent loss (\(name)): perFact brackets a key typed in R1's opening observation with R1 itself as the b-side (it started before the key; every fact's b-side observation was sent after it)")
        let old = BrowserTypingBurst(); old.bracketed = true
        try check(!old.admitBracketed(ra: pa, rb: pb, typedAt: key, processedAt: now),
                  "silent loss (\(name)): the whole-read check (rb's start after the key) refuses that key: the unit was retracted (the b+ finding)")
        let fixed = BrowserTypingBurst(); fixed.bracketed = true
        try check(fixed.admitBracketed(ra: pa, rb: pb, typedAt: key, processedAt: now, bSideSent: bSide),
                  "silent loss (\(name)): with the per-fact witness (earliest b-side send after the key) the burst admits it")
        let early = BrowserTypingBurst(); early.bracketed = true
        try check(!early.admitBracketed(ra: pa, rb: pb, typedAt: key, processedAt: now, bSideSent: key - 1),
                  "silent loss (\(name)): a b-side observation sent before the key is still refused (the witness must be after the key)")
        // wholeRead is unchanged: its b-side read starts after the key (or there is none).
        if case .admit(_, let wb) = whole.decide(typedAt: key, now: now) {
            try check(wb.start > key, "silent loss (\(name)): wholeRead's b-side read starts after the key (its check is unchanged)")
        } else {
            try check(true, "silent loss (\(name)): wholeRead does not bracket that key (unchanged)")
        }
    }
}


// MARK: - Codex QF-1: only complete post-boundary bracket proofs recover quiet

/// These are pure joins and clocked engine decisions, not a claim about real keyboard events.
/// Return, Tab, paste and click share noteDisruptive; the route's event wiring is checked separately.
private func checkBracketedBoundaryRecovery() throws {
    let previousShape = ChromeReadShape.current
    defer { ChromeReadShape.current = previousShape }
    let quiet = BrowserTypingTiming.quietNanoseconds
    for shape in [ChromeReadShape.full, .lean] {
        ChromeReadShape.current = shape
        for rule in [ChromeBracketRule.wholeRead, .perFact] {
            let name = "\(shape == .full ? "full" : "lean"), \(rule == .wholeRead ? "wholeRead" : "perFact")"
            for boundaryName in ["Return", "Tab", "paste", "click"] {
                let w = FakeChromeWorld(); w.tick = 2 * ms
                let join = BrowserTypingJoin<FakeAXNode>(design: .bracketed)
                let e = ChromeBracketEngine(rule: rule), boundary = w.clock
                e.boundary(at: boundary)
                var proofs: [UUID: BrowserTypingJoinProof] = [:]
                func read() -> BrowserTypingJoinProof? {
                    let start = w.clock
                    e.readStarted(at: start)
                    let result = w.run(join)
                    if let p = result.proof, let r = p.bracket { proofs[r.id] = p }
                    e.readFinished(start: start, end: w.clock, record: result.proof?.bracket)
                    return result.proof
                }
                w.clock += 2 * ms
                let a = read()
                w.clock += 2 * ms
                let key = w.clock
                w.clock += 2 * ms
                let b = read()
                guard let a, let b, case .admit(let ra, let rb) = e.decide(typedAt: key, now: w.clock),
                      let pa = proofs[ra.id], let pb = proofs[rb.id] else {
                    try check(false, "QF-1 (\(name), \(boundaryName)): control: complete fresh equal reads bracket the key")
                    continue
                }
                try check(a.checkedAt > boundary && key > boundary && key < boundary + quiet
                          && b.checkedAt > key && ra.complete && rb.complete,
                          "QF-1 (\(name), \(boundaryName)): complete full proofs on both sides precede 400 ms")
                let burst = BrowserTypingBurst()
                burst.bracketed = true; burst.recoverBracketedBoundaries = true
                burst.noteDisruptive(at: boundary)
                try check(!burst.dropsUnread(typedAt: key)
                          && burst.bracketedIntakeAdmits(typedAt: key, priorReadStartedAt: a.checkedAt, boundaryAt: boundary)
                          && burst.admitBracketed(ra: pa, rb: pb, typedAt: key, processedAt: w.clock,
                                                  bSideSent: rule == .perFact ? e.admittedBSideSent : nil),
                          "QF-1 (\(name), \(boundaryName)): opt-in recovers the first proved post-boundary key before 400 ms")
                let original = BrowserTypingBurst(); original.bracketed = true; original.noteDisruptive(at: boundary)
                try check(!original.recoverBracketedBoundaries && original.dropsUnread(typedAt: key)
                          && !original.bracketedIntakeAdmits(typedAt: key, priorReadStartedAt: a.checkedAt, boundaryAt: boundary)
                          && !original.admitBracketed(ra: pa, rb: pb, typedAt: key, processedAt: w.clock,
                                                     bSideSent: rule == .perFact ? e.admittedBSideSent : nil),
                          "QF-1 (\(name), \(boundaryName)): default-off retains the original 400 ms gate")
                let sync = BrowserTypingBurst(); sync.recoverBracketedBoundaries = true; sync.noteDisruptive(at: boundary)
                try check(sync.dropsUnread(typedAt: key) && !sync.quietAdmits(a, typedAt: key)
                          && !sync.bracketedIntakeAdmits(typedAt: key, priorReadStartedAt: a.checkedAt, boundaryAt: boundary),
                          "QF-1 (\(name), \(boundaryName)): opt-in alone never recovers the synchronous route")
                try check(!burst.bracketedIntakeAdmits(typedAt: key, priorReadStartedAt: boundary - 1, boundaryAt: boundary)
                          && !burst.bracketedIntakeAdmits(typedAt: key, priorReadStartedAt: boundary, boundaryAt: boundary)
                          && !burst.bracketedIntakeAdmits(typedAt: boundary, priorReadStartedAt: a.checkedAt, boundaryAt: boundary)
                          && !burst.bracketedIntakeAdmits(typedAt: boundary - 1, priorReadStartedAt: a.checkedAt, boundaryAt: boundary),
                          "QF-1 (\(name), \(boundaryName)): key acquisition needs both key and prior full-read start strictly after the boundary")
                // Use the same real proof while moving the boundary to its start. Equal-time and
                // older proofs must fail even when a caller gets past the pre-byte intake gate.
                let stale = BrowserTypingBurst(); stale.bracketed = true; stale.recoverBracketedBoundaries = true
                stale.noteDisruptive(at: a.checkedAt)
                try check(!stale.quietAdmits(a, typedAt: key)
                          && !stale.admitBracketed(ra: pa, rb: pb, typedAt: key, processedAt: w.clock,
                                                   bSideSent: rule == .perFact ? e.admittedBSideSent : nil),
                          "QF-1 (\(name), \(boundaryName)): a proof starting exactly at the boundary cannot admit")
                stale.noteDisruptive(at: a.checkedAt + 1)
                try check(!stale.quietAdmits(a, typedAt: key),
                          "QF-1 (\(name), \(boundaryName)): a proof starting before the boundary cannot admit")
                let denied = BrowserTypingBurst(); denied.bracketed = true; denied.recoverBracketedBoundaries = true
                denied.noteDisruptive(at: boundary - 2 * ms)
                denied.noteDenied(at: boundary)
                try check(denied.dropsUnread(typedAt: key) && !denied.quietAdmits(a, typedAt: key)
                          && !denied.bracketedIntakeAdmits(typedAt: key, priorReadStartedAt: a.checkedAt, boundaryAt: boundary)
                          && !denied.admitBracketed(ra: pa, rb: pb, typedAt: key, processedAt: w.clock,
                                                    bSideSent: rule == .perFact ? e.admittedBSideSent : nil),
                          "QF-1 (\(name), \(boundaryName)): denial quiet is not shortened by opt-in")
                denied.noteDisruptive(at: boundary - 1)
                try check(!denied.recoversBracketedQuiet && denied.quietFrom == boundary && denied.dropsUnread(typedAt: key),
                          "QF-1 (\(name), \(boundaryName)): an older delayed boundary cannot reopen denial quiet")
                denied.noteDisruptive(at: boundary)
                try check(!denied.recoversBracketedQuiet && denied.quietFrom == boundary && denied.dropsUnread(typedAt: key),
                          "QF-1 (\(name), \(boundaryName)): a same-tick boundary cannot reopen denial quiet")
                denied.noteDisruptive(at: boundary + 1)
                try check(denied.recoversBracketedQuiet && denied.quietAdmits(a, typedAt: key),
                          "QF-1 (\(name), \(boundaryName)): a genuinely later boundary may start a new proof-gated recovery")

                // Recovery must not turn an engine refusal into admission. These are fresh actual
                // FakeChromeWorld proofs; the world changes between reads, rather than fabricated records.
                for failure in ["failed read", "mismatched page", "boundary inside bracket"] {
                    let fw = FakeChromeWorld(); fw.tick = 2 * ms
                    let fj = BrowserTypingJoin<FakeAXNode>(design: .bracketed), fe = ChromeBracketEngine(rule: rule)
                    let fb = fw.clock, refusedBurst = BrowserTypingBurst()
                    refusedBurst.bracketed = true; refusedBurst.recoverBracketedBoundaries = true
                    refusedBurst.noteDisruptive(at: fb); fe.boundary(at: fb)
                    func failingRead() -> BrowserTypingJoinProof? {
                        let started = fw.clock; fe.readStarted(at: started)
                        let p = fw.run(fj).proof
                        fe.readFinished(start: started, end: fw.clock, record: p?.bracket)
                        return p
                    }
                    fw.clock += 2 * ms
                    let first = failingRead()
                    fw.clock += 2 * ms
                    let typed = fw.clock
                    if failure == "failed read" { fw.failing.insert("modes") }
                    if failure == "mismatched page" {
                        fw.windows[0].url = "https://mail.google.com/mail/u/1/?compose=new"
                        fw.web.url = fw.windows[0].url
                    }
                    if failure == "boundary inside bracket" { fe.boundary(at: typed + 1) }
                    fw.clock += 2 * ms
                    let second = failingRead()
                    try check(first?.bracket != nil && typed < fb + quiet
                              && refusedBurst.bracketedIntakeAdmits(typedAt: typed, priorReadStartedAt: first!.checkedAt, boundaryAt: fb)
                              && fe.decide(typedAt: typed, now: fw.clock) == .discard
                              && !refusedBurst.pending
                              && (failure == "failed read" ? second == nil : second?.bracket != nil),
                              "QF-1 (\(name), \(boundaryName)): intake recovery still refuses \(failure), no pending burst")
                }
            }
            // After 400 ms the default path resumes, but requires a proof that itself starts
            // after quiet ends, even when the key's delivery is delayed across the endpoint.
            let w = FakeChromeWorld(), j = BrowserTypingJoin<FakeAXNode>(design: .bracketed)
            let q = w.clock, retained = BrowserTypingBurst()
            retained.bracketed = true; retained.noteDisruptive(at: q)
            w.clock = q + quiet - 1
            let beforeEnd = w.run(j).proof!
            w.clock = q + quiet + 1
            let afterEnd = w.run(j).proof!
            try check(!retained.quietAdmits(beforeEnd, typedAt: q + quiet + 1)
                      && retained.quietAdmits(afterEnd, typedAt: q + quiet + 1),
                      "QF-1 (\(name)): default 400 ms endpoint still requires a fresh proof")
            let denialEndpoint = BrowserTypingBurst()
            denialEndpoint.bracketed = true; denialEndpoint.recoverBracketedBoundaries = true
            denialEndpoint.noteDenied(at: q)
            try check(denialEndpoint.dropsUnread(typedAt: q + quiet - 1)
                      && !denialEndpoint.dropsUnread(typedAt: q + quiet)
                      && !denialEndpoint.quietAdmits(beforeEnd, typedAt: q + quiet + 1)
                      && denialEndpoint.quietAdmits(afterEnd, typedAt: q + quiet + 1),
                      "QF-1 (\(name)): denial retains all 400 ms and resumes only with a fresh proof")
        }
    }
    // A delayed boundary must not erase a sensitive-field hold, even after ordinary quiet ends.
    let sensitive = BrowserTypingBurst(), deniedAt: UInt64 = 5_000 * ms
    sensitive.bracketed = true; sensitive.recoverBracketedBoundaries = true
    sensitive.denied(.sensitiveField, at: deniedAt)
    let expectedHold = deniedAt + BrowserTypingTiming.refusedHoldNanoseconds
    let afterQuiet = deniedAt + quiet + 1
    sensitive.noteDisruptive(at: deniedAt - 1)
    let olderPreservesHold = sensitive.heldUntil == expectedHold && sensitive.dropsUnread(typedAt: afterQuiet)
    sensitive.noteDisruptive(at: deniedAt)
    try check(olderPreservesHold && sensitive.heldUntil == expectedHold
              && !sensitive.recoversBracketedQuiet && afterQuiet < expectedHold
              && sensitive.dropsUnread(typedAt: afterQuiet),
              "QF-1: older and same-time boundaries preserve sensitive-field hold beyond 400 ms until refusedHold ends")
    // N-98-1 (review 10:26): a later denial (the field hold's drop of a held key, a timeout) keeps the sensitive-field
    // hold; a later user boundary, `endHolds` and invalidation still end it. Both settings of QF-1 recovery.
    for recover in [false, true] {
        func fresh() -> BrowserTypingBurst {
            let b = BrowserTypingBurst(); b.bracketed = true; b.recoverBracketedBoundaries = recover
            b.denied(.sensitiveField, at: deniedAt); return b
        }
        let later = deniedAt + 100 * ms, pastQuiet = later + quiet + 1
        let byDenial = fresh()
        byDenial.noteDenied(at: later)
        let timeout = fresh()
        timeout.denied(.timeout, at: later)
        try check(byDenial.heldUntil == expectedHold && byDenial.quietFrom == later && pastQuiet < expectedHold
                  && byDenial.dropsUnread(typedAt: pastQuiet) && !byDenial.dropsUnread(typedAt: expectedHold)
                  && timeout.heldUntil == expectedHold && timeout.dropsUnread(typedAt: pastQuiet),
                  "N-98-1 (recovery \(recover)): a later denial keeps the sensitive-field hold to its 1 s end (400 ms denial quiet, then the hold)")
        let byUser = fresh(), byEnd = fresh(), byInvalidate = fresh()
        byUser.noteDenied(at: later); byUser.noteDisruptive(at: later + 1)
        byEnd.noteDenied(at: later); byEnd.endHolds()
        byInvalidate.noteDenied(at: later); byInvalidate.invalidate(.focus)
        try check(byUser.heldUntil == nil && byEnd.heldUntil == nil && byInvalidate.heldUntil == nil
                  && !byUser.dropsUnread(typedAt: later + 1 + quiet),
                  "N-98-1 (recovery \(recover)): a later user boundary, endHolds or invalidation still ends the hold")
    }
}
// Pure delayed-delivery regression: no OS reads, keys or personal store.
private func checkUndeliveredReadExpiry() throws {
    let w = Obj(), f = Obj()
    for rule in [ChromeBracketRule.wholeRead, .perFact] {
        let name = String(describing: rule), key = 70 * ms
        func waiting(_ start: UInt64 = 80) -> ChromeBracketEngine {
            let e = engine(rule, [record(0, 60, window: w, focus: f)])
            e.readStarted(at: start * ms); return e
        }
        let delayed = waiting()
        try check(delayed.decide(typedAt: key, now: 240 * ms) == .wait,
                  "pending-read (\(name)): completed but undelivered B can wait beyond wall deadline, never admit from start metadata")
        delayed.readFinished(start: 80 * ms, end: 140 * ms, record: record(80, 140, window: w, focus: f))
        try check(admitted(delayed.decide(typedAt: key, now: 240 * ms)),
                  "pending-read (\(name)): actual valid 140 ms facts admit after delayed delivery without widening span")
        let none = engine(rule, [record(0, 60, window: w, focus: f)])
        try check(none.decide(typedAt: key, now: 240 * ms) == .discard
                  && waiting(220).decide(typedAt: key, now: 240 * ms) == .discard,
                  "pending-read (\(name)): absent or late-starting full read cannot extend expiry")
        for bad in ["failed", "changed", "boundary", "late"] {
            let e = waiting()
            let r: ChromeReadRecord? = bad == "failed" ? nil : record(80, bad == "late" ? 220 : 140,
                digest: bad == "changed" ? 2 : 1, window: w, focus: f)
            if bad == "boundary" { e.boundary(at: 75 * ms) }
            e.readFinished(start: 80 * ms, end: r?.end ?? 140 * ms, record: r)
            try check(e.decide(typedAt: key, now: 240 * ms) == .discard,
                      "pending-read (\(name)): delayed \(bad) facts fail closed")
        }
        if rule == .wholeRead {
            try check(waiting(70).decide(typedAt: key, now: 240 * ms) == .discard,
                      "pending-read wholeRead: a read starting at the key cannot supply its strict B side")
        }
    }
    let c = ChromeReadControl(); c.setEnabled(true); let epoch = c.epoch
    let token = c.began(80 * ms, epoch: epoch)
    c.ended(token, at: 140 * ms)
    try check(c.undeliveredFullReadStart(after: 60 * ms, epoch: epoch) == 80 * ms,
              "pending-read control: physical completion remains pending until main delivery")
    try check(c.undeliveredFullReadStart(after: 80 * ms, epoch: epoch) == nil,
              "pending-read control: handled read cannot resurrect")
    _ = c.began(160 * ms, epoch: epoch, full: false)
    try check(c.undeliveredFullReadStart(after: 80 * ms, epoch: epoch) == nil,
              "pending-read control: page read never supplies full-read bracket")
    c.setEnabled(false)
    try check(c.undeliveredFullReadStart(after: nil, epoch: epoch) == nil,
              "pending-read control: disabled capture suppresses pending proof metadata")
    c.setEnabled(true); c.bump()
    try check(c.undeliveredFullReadStart(after: nil, epoch: epoch) == nil
              && c.undeliveredFullReadStart(after: nil, epoch: c.epoch) == nil,
              "pending-read control: epoch reset wipes pending reads; stale epoch cannot revive them")
}
// Q-4 uses observation START, inclusive at 60 ms, without widening B1 or waiting on main.
private func checkMetadataSettle() throws {
    let w = Obj(), f = Obj(), key = 70 * ms, floor = key + 60 * ms
    for rule in [ChromeBracketRule.wholeRead, .perFact] {
        let before = record(0, 60, window: w, focus: f)
        for delta in [UInt64(59_900_000), 60 * ms] {
            let sent = key + delta
            let b = record(80, 140, window: w, focus: f,
                           times: [.axURL: [ChromeFactTimes(sent: sent, received: 140 * ms)]])
            let e = engine(rule, [before, b])
            let decision = e.decide(typedAt: key, now: 141 * ms, minimumBSent: [.axURL: floor])
            try check(admitted(decision) == (delta == 60 * ms),
                      "Q-4 (\(rule)): AX URL 59.9 / inclusive 60.0 ms is judged by observation start")
        }
        let early = record(80, 140, window: w, focus: f,
                           times: [.axURL: [ChromeFactTimes(sent: floor - 1, received: floor + 5 * ms)]])
        let e = engine(rule, [before, early])
        try check(e.decide(typedAt: key, now: 141 * ms, minimumBSent: [.axURL: floor]) == .wait,
                  "Q-4 (\(rule)): an AX URL starting before floor and completing after floor cannot admit")
        e.readFinished(start: 140 * ms, end: 149 * ms, record: record(140, 149, window: w, focus: f))
        try check(admitted(e.decide(typedAt: key, now: 150 * ms, minimumBSent: [.axURL: floor])),
                  "Q-4 (\(rule)): later settled equal facts can supply B, original 150 ms span unchanged")
        let failed = engine(rule, [before, early, nil, record(140, 149, window: w, focus: f)],
                            starts: [(0,0),(0,0),(140,140),(0,0)])
        try check(failed.decide(typedAt: key, now: 150 * ms, minimumBSent: [.axURL: floor]) == .discard,
                  "Q-4 (\(rule)): waiting for settlement never skips a failed intermediate read")
    }
    func notesWorld() -> FakeChromeWorld {
        let x=FakeChromeWorld();x.windows[0].url="https://notes.example.org/pad";x.web.url=x.windows[0].url
        x.window.title="Old private conversation";x.windows[0].name=x.window.title!
        x.field.labels=BrowserTypingFieldLabels(texts:["Notes"],identifiers:[]);return x
    }
    var proof = notesWorld().run(BrowserTypingJoin<FakeAXNode>(design:.synchronous)).proof!
    proof.pageTitle = "Old private conversation";proof.titleObservedAt = floor - 1
    for lean in [false,true] {
        proof.leanRead = lean;proof.axURLObservedAt = floor
        let stripped = proof.settledMetadata(anchor:key)
        try check(stripped?.pageTitle == ""
                  && stripped.map {BrowserTypingBurst.focusProof($0,generation:1,policyVersion:1).place} == "notes.example.org",
                  "Q-4 (lean \(lean)): agreeing but too-early old title yields site-only saved place")
        proof.titleObservedAt = floor
        try check(proof.settledMetadata(anchor:key)?.pageTitle == "Old private conversation",
                  "Q-4 (lean \(lean)): exactly settled title start can be kept")
        proof.titleObservedAt = floor - 1
    }
    proof.leanRead=true;proof.axURLObservedAt=floor-1
    try check(proof.settledMetadata(anchor:key) == nil && proof.settledMetadata(anchor:key,requireURL:false)?.pageTitle == "",
              "Q-4: early lean B/save URL refuses, A only strips title and cannot become B authority")
    proof.leanRead=false
    try check(proof.settledMetadata(anchor:key) != nil,
              "Q-4: full/sync fresh AE and AX URL checks remain exempt from the lean URL floor")
    let laterBoundary=key+10*ms
    proof.leanRead=true;proof.axURLObservedAt=floor
    try check(proof.settledMetadata(anchor:max(key,laterBoundary)) == nil,
              "Q-4: max boundary/key floor prevents recovery from bypassing per-key settlement")
    let shapeBefore=ChromeReadShape.current
    defer {ChromeReadShape.current=shapeBefore}
    ChromeReadShape.current = .full
    for design in [ChromeJoinDesign.synchronous,.bracketed] {
        let x=notesWorld(),anchor=x.clock
        let got=x.run(BrowserTypingJoin<FakeAXNode>(design:design))
        try check(got.proof?.pageTitle == "Old private conversation" && got.proof?.titleObservedAt != nil
                  && got.proof?.settledMetadata(anchor:anchor)?.pageTitle == "",
                  "Q-4 (\(design)): real agreeing AE/AX old title in early read becomes site-only")
    }
    ChromeReadShape.current = .lean
    for rule in [ChromeBracketRule.wholeRead,.perFact] {
        let x=notesWorld();x.tick=0
        let join=BrowserTypingJoin<FakeAXNode>(design:.bracketed),base=x.clock,t=base+1*ms
        let a=x.run(join).proof!.bracket!
        // Fresh AE URL has a blocked hash route; lean's stale AX URL still says ordinary notes at +20 ms.
        x.windows[0].url="https://notes.example.org/pad#/checkout";x.clock=t+20*ms
        let early=x.run(join)
        try check(early.proof != nil && early.proof?.settledMetadata(anchor:t) == nil,
                  "Q-4 lean (\(rule)): stale AX URL at +20 ms cannot admit blocked hash transition")
        let e=engine(rule,[a,early.proof!.bracket!])
        try check(!admitted(e.decide(typedAt:t,now:x.clock,minimumBSent:[.axURL:t+60*ms])),
                  "Q-4 lean (\(rule)): route floor rejects stale +20 ms proof under both bracket rules")
        x.web.url=x.windows[0].url;x.clock=t+60*ms
        let blocked=x.run(join)
        e.readFinished(start:x.clock,end:x.clock,record:blocked.proof?.bracket)
        try check(blocked.denial == .blockedSite && e.decide(typedAt:t,now:x.clock,minimumBSent:[.axURL:t+60*ms]) == .discard,
                  "Q-4 lean (\(rule)): fresh settled blocked route denies and cannot be skipped by later B")
    }
    ChromeReadShape.current = .full
    // Real fake-world joins still compare AX title with AE name, even after a fresh title starts.
    let world = FakeChromeWorld()
    world.window.title="Fresh title";world.windows[0].name="Old title"
    let r=world.run(BrowserTypingJoin<FakeAXNode>(design:.synchronous))
    try check(r.proof == nil && r.denial == .window,
              "Q-4: fresh AX title with lagging AE name still refuses under the full synchronous match")
}
#endif
