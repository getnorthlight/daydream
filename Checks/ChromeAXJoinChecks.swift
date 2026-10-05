#if DAYDREAM_CHROME_TYPING
// Compiled only with -DDAYDREAM_CHROME_TYPING. Fully synthetic (the fake Chrome of ChromeTypingChecks.swift): no Apple
// Event, AX call, event tap, Chrome launch or permission request.
//
// claude/axjoin-1005: the Accessibility join (a validated Chrome build): every window's mode by Apple Events still opens
// and closes the join (every Space, fullscreen), the focused window's own Incognito/Guest signals can only refuse, a
// window with no profile button takes the full Apple Events join, and every other build or adapter is unchanged.
import Foundation
import MemoryCore
import PrivacyPolicy

/// A fake Chrome 154 whose window has Chrome's toolbar views and profile button, and an adapter with every
/// Accessibility-join seam.
private final class AXJoinWorld {
    let w = FakeChromeWorld()
    var root: FakeAXNode!, toolbar: FakeAXNode!, button: FakeAXNode!
    var documentReads = 0
    var onDocument: ((Int) -> Void)?
    var seams: Set<String> = ["document", "identity", "classes", "described"]
    var identity: String? = "6409"

    init(fullscreen: Bool = false) {
        let pid = FakeChromeWorld.chromePID
        w.facts.bundleVersion = "154.0.8037.93"; w.facts.frameworkVersions = ["154.0.8037.58", "154.0.8037.93"]
        w.window.title = FakeChromeWorld.title + " - Google Chrome"
        w.window.document = FakeChromeWorld.url
        func view(_ name: String, _ cls: [String], parent: FakeAXNode, role: String = "AXGroup") -> FakeAXNode {
            let n = FakeAXNode(name, role: role, parent: parent, owner: pid); n.classes = cls; return n
        }
        if fullscreen {
            // Fullscreen: the toolbar sits in an overlay below an unnamed group right under the window.
            let host = view("fs-host", [], parent: w.window)
            root = view("fs-root", ["RootView"], parent: host)
            let overlay = view("overlay", ["TopContainerOverlayView"], parent: root)
            let top = view("top", ["TopContainerView"], parent: overlay)
            toolbar = view("toolbar", ["ToolbarView"], parent: top, role: "AXToolbar")
        } else {
            root = view("root", ["BrowserRootView"], parent: w.window)
            let nonClient = view("nonclient", ["NonClientView"], parent: root)
            let frame = view("frame", ["BrowserFrameView"], parent: nonClient)
            let browser = view("browser", ["BrowserView"], parent: frame)
            _ = view("tabstrip", ["TabStripRegionView"], parent: browser)
            let top = view("top", ["TopContainerView"], parent: browser)
            toolbar = view("toolbar", ["ToolbarView"], parent: top, role: "AXToolbar")
        }
        _ = view("back", ["ToolbarButton"], parent: toolbar, role: "AXButton")
        _ = view("omnibox", ["OmniboxViewViews"], parent: toolbar, role: "AXTextField")
        button = view("avatar", ["AvatarToolbarButton"], parent: toolbar, role: "AXButton")
        button.title = "You"
    }
    var access: ChromeAXAccess<FakeAXNode> {
        var a = w.access
        let w = self.w
        if seams.contains("document") {
            a.document = { n in w.log.append("ax:document:" + n.name); self.documentReads += 1; self.onDocument?(self.documentReads); return n.document }
        }
        if seams.contains("identity") { a.windowIdentity = { n in w.log.append("ax:identity:" + n.name); return n === w.window ? self.identity : n.windowNumber } }
        if seams.contains("classes") { a.viewClasses = { n in w.log.append("ax:classes:" + n.name); return n.classes } }
        if seams.contains("described") { a.described = { n in w.log.append("ax:described:" + n.name); return n.described } }
        return a
    }
    var environment: ChromeJoinEnvironment {
        var e = w.environment
        e.accessibilityJoin = { ChromeAXJoinPolicy.validated($0) }
        return e
    }
    func run(_ join: BrowserTypingJoin<FakeAXNode> = BrowserTypingJoin<FakeAXNode>()) -> BrowserTypingJoinResult {
        w.log = []; w.aeCount = 0
        return join.join(environment: environment, appleEvents: w.ae, accessibility: access, blockList: BrowserTypingBlockList(),
                         alwaysBlocked: PrivacySettings.sensitiveDomains)
    }
    var aeKinds: [String] { w.log.filter { $0.hasPrefix("ae:") && !$0.hasPrefix("ae:mode:") && !$0.hasPrefix("ae:bounds:") } }
    /// The full Apple Events join ran (the window's bounds, name, tab and URL by Apple Events).
    var tookAppleEventsJoin: Bool { w.log.contains { $0.hasPrefix("ae:url:") || $0.hasPrefix("ae:name:") || $0.hasPrefix("ae:activeTab:") } }
    static func isContent(_ e: String) -> Bool {
        FakeChromeWorld.isContent(e) || ["ax:document:", "ax:classes:", "ax:described:", "ax:identity:", "ax:children:"].contains { e.hasPrefix($0) }
    }
}

func checkAccessibilityJoin() throws {
    let saved = ChromeAXJoinPolicy.enabled
    defer { ChromeAXJoinPolicy.enabled = saved }
    ChromeAXJoinPolicy.enabled = true

    // Tables: every UI language of Chrome 154, numbers in a button label.
    try check(ChromePrivateWindow.titleTags.count == 93 && ChromePrivateWindow.buttonLabels.count == 186,
              "AX join: the Incognito/Guest title tags (93) and button labels (186) are Chrome 154's, every language")
    for t in ["Page - Google Chrome (Incognito)", "Page - Google Chrome (Guest)", "Page A - Google Chrome（シークレット モード）",
              "Page - Google Chrome (Navigation privée)", "SPA home - Chrome(게스트)", "Page - Google Chrome (Incognito) "] {
        try check(ChromePrivateWindow.titleTagged(t), "AX join: title tag found: \(t)")
    }
    for t in ["Page - Google Chrome", "Incognito mode explained - Google Chrome", "My (Incognito) notes - Google Chrome", ""] {
        try check(!ChromePrivateWindow.titleTagged(t), "AX join: no title tag: \(t)")
    }
    for l in ["Incognito", "Incognito (2)", "Incognito (12)", "Guest", "Gast (3)", "2 окна в режиме инкогнито", " Incognito "] {
        try check(ChromePrivateWindow.privateLabel(l), "AX join: private profile-button label: \(l)")
    }
    for l in ["You", "Nicholas", "Work", "Incognito notes", "Paused", ""] {
        try check(!ChromePrivateWindow.privateLabel(l), "AX join: a profile's own button label is not private: \(l)")
    }

    // The version gate: Chrome 154 only, every framework on disk 154; the process switch; an adapter without the seams.
    let base = AXJoinWorld().w.facts
    try check(ChromeAXJoinPolicy.validated(base), "AX join: Chrome 154 validated")
    var f = base; f.bundleVersion = "155.0.8100.1"; f.frameworkVersions = ["155.0.8100.1"]
    try check(!ChromeAXJoinPolicy.validated(f), "AX join: an unvalidated Chrome major takes the full Apple Events join")
    f = base; f.frameworkVersions = ["154.0.8037.93", "155.0.8100.1"]
    try check(!ChromeAXJoinPolicy.validated(f), "AX join: a newer framework on disk (an update waiting) takes the full Apple Events join")
    f = base; f.bundleVersion = nil
    try check(!ChromeAXJoinPolicy.validated(f), "AX join: an unreadable version takes the full Apple Events join")
    ChromeAXJoinPolicy.enabled = false
    try check(!ChromeAXJoinPolicy.validated(base), "AX join: the process switch turns it off")
    ChromeAXJoinPolicy.enabled = true

    // 1. A normal window: allowed with 4 Apple Events (ids and modes, opening and closing), none about a window or tab.
    do {
        let x = AXJoinWorld(), join = BrowserTypingJoin<FakeAXNode>()
        let r = x.run(join)
        guard let p = r.proof else { throw MemError.invalid("FAILED: AX join: a normal window is allowed (\(r))") }
        try check(p.origin == "https://mail.google.com" && p.windowID == "ax-window-6409" && p.tabID == "ax-tab-1" && p.windowList == ["101"],
                  "AX join: the proof names the window server's window and the page's tab (\(p.windowID) \(p.tabID))")
        try check(x.w.aeCount == 4 && x.aeKinds == ["ae:ids", "ae:modes", "ae:ids", "ae:modes"],
                  "AX join: 4 Apple Events, the window list and every mode, twice (\(x.aeKinds))")
        try check(!x.tookAppleEventsJoin && !x.w.log.contains { $0.hasPrefix("ae:bounds") },
                  "AX join: no window bounds, name, tab or URL by Apple Events")
        let log = x.w.log
        let firstModes = log.firstIndex(of: "ae:modes")!, lastModes = log.lastIndex(of: "ae:modes")!
        let firstContent = log.firstIndex(where: AXJoinWorld.isContent)!
        try check(firstModes < firstContent, "AX join: every window's mode is read before any window, page or field content")
        let lastPage = log.lastIndex(where: { FakeChromeWorld.isPageContent($0) || $0.hasPrefix("ax:document:") || $0.hasPrefix("ax:described:") })!
        try check(lastModes > lastPage, "AX join: the confirming read re-reads every mode after all page content")
        try check(log.firstIndex(where: { $0.hasPrefix("ax:described:") })! < log.firstIndex(where: { $0.hasPrefix("ax:focusedElement") })!,
                  "AX join: the window's Incognito/Guest signals are read before the focused field")
        try check(x.documentReads == 2, "AX join: the window's address is read on both reads")
        // The profile button found once is reused (still re-read: its parent, description and title).
        let again = x.run(join)
        try check(again.proof?.tabID == "ax-tab-1" && !x.w.log.contains("ax:children:root"),
                  "AX join: the same page keeps its tab; the profile button is reused, not searched again")
        x.button.title = "Incognito (2)"
        try check(x.run(join).denial == .notNormal, "AX join: a reused profile button is read again (a private label now refuses)")
        x.button.title = "You"; x.button.described = true
        let fell = x.run(join)
        try check(fell.proof?.windowID == "101" && x.tookAppleEventsJoin,
                  "AX join: a reused profile button is read again (a description now takes the full Apple Events join) (\(fell))")
    }
    // Fullscreen: the toolbar in its overlay.
    do {
        let x = AXJoinWorld(fullscreen: true)
        try check(x.run().proof?.windowID == "ax-window-6409", "AX join: fullscreen (toolbar overlay) is allowed")
    }

    // 2. Defense in depth: the focused window's own signals refuse although every mode answered "normal".
    for (what, setUp) in [("its title's Incognito tag", { (x: AXJoinWorld) in x.w.window.title = "Page - Google Chrome (Incognito)" }),
                          ("its title's Guest tag (Japanese)", { x in x.w.window.title = "Page - Google Chrome（ゲスト）" }),
                          ("its title's Incognito tag, with a described button", { x in
                              x.w.window.title = "Page - Google Chrome (Incognito)"; x.button.described = true }),
                          ("a Guest label on a described button", { x in x.button.title = "Guest"; x.button.described = true }),
                          ("an Incognito label on a described button", { x in x.button.title = "Incognito"; x.button.described = true }),
                          ("an Incognito profile button", { x in x.button.title = "Incognito (2)" }),
                          ("a Guest profile button", { x in x.button.title = "Guest" })] as [(String, (AXJoinWorld) -> Void)] {
        let x = AXJoinWorld(); setUp(x)
        let r = x.run()
        try check(r.denial == .notNormal && x.w.aeCount == 2 && !x.tookAppleEventsJoin
                  && !x.w.log.contains { $0.hasPrefix("ax:focusedElement") || $0.hasPrefix("ax:url:") || $0.hasPrefix("ax:document:") },
                  "AX join: \(what) refuses (modes all normal), no fallback, no field or page read (\(r))")
    }
    do {
        let x = AXJoinWorld(); x.w.window.title = "Page - Google Chrome (Incognito)"
        _ = x.run()
        try check(!x.w.log.contains { $0.hasPrefix("ax:children:") || $0.hasPrefix("ax:classes:") }, "AX join: a title tag refuses before any view is read")
    }

    // 3. A description alone (a normal window's button carries one for a few seconds after Chrome starts) proves
    //    nothing: the full Apple Events join decides, by its own mode read.
    do {
        let x = AXJoinWorld(); x.button.described = true
        let r = x.run()
        try check(r.proof?.windowID == "101" && r.proof?.tabID == "7" && x.tookAppleEventsJoin,
                  "AX join: a description alone takes the full Apple Events join, which allows a normal window (\(r))")
        let y = AXJoinWorld(); y.button.described = true
        y.w.onAppleEvent = { _, n in if n == 3 { y.w.windows[0].mode = "incognito" } }
        try check(y.run().denial == .notNormal, "AX join: a description alone: the Apple Events mode decides (incognito refuses)")
        let z = AXJoinWorld(); z.button.described = true; z.w.addWindow("202", mode: "incognito", front: false, onThisSpace: false)
        try check(z.run().denial == .notNormal && !z.w.log.contains(where: AXJoinWorld.isContent),
                  "AX join: a description alone with an Incognito window on another Space refuses before any content")
    }
    // No profile button proven normal (a popup, Picture-in-Picture, a read error): the full Apple Events join.
    for (what, setUp) in [("no profile button (a popup)", { (x: AXJoinWorld) in x.root.parent = nil }),
                          ("a profile button outside the toolbar", { x in x.button.parent = x.root }),
                          ("an unreadable description", { x in x.button.described = nil }),
                          ("an unreadable view class", { x in x.root.classes = nil }),
                          ("two profile buttons that disagree", { x in
                              let b = FakeAXNode("avatar2", role: "AXButton", parent: x.toolbar, owner: FakeChromeWorld.chromePID)
                              b.classes = ["AvatarToolbarButton"]; b.title = "Work" }),
                          ("a page's own element named like the button", { x in
                              x.root.parent = nil
                              let fake = FakeAXNode("page-avatar", role: "AXButton", parent: x.w.group, owner: FakeChromeWorld.chromePID)
                              fake.classes = ["AvatarToolbarButton"]; fake.title = "You" })] as [(String, (AXJoinWorld) -> Void)] {
        let x = AXJoinWorld(); setUp(x)
        let r = x.run()
        try check(r.proof?.windowID == "101" && r.proof?.tabID == "7" && x.tookAppleEventsJoin,
                  "AX join: \(what): the full Apple Events join decides (\(r))")
        try check(!x.w.log.contains("ax:classes:page-avatar") && !x.w.log.contains("ax:classes:compose-body"),
                  "AX join: \(what): the search never enters the page")
    }
    for (what, setUp) in [("an Incognito popup (title tag, no button)", { (x: AXJoinWorld) in
                              x.root.parent = nil; x.w.window.title = "Page - Google Chrome (Incognito)" }),
                          ("a popup whose window Apple Events calls incognito", { x in
                              x.root.parent = nil; x.w.windows[0].mode = "incognito" })] as [(String, (AXJoinWorld) -> Void)] {
        let x = AXJoinWorld(); setUp(x)
        try check(x.run().denial == .notNormal, "AX join: \(what) refuses")
    }
    do {
        // The fallback's own private signals: AE says normal at the first read, incognito when the fallback asks.
        let x = AXJoinWorld(); x.root.parent = nil
        x.w.onAppleEvent = { _, n in if n == 3 { x.w.windows[0].mode = "incognito" } }
        try check(x.run().denial == .notNormal, "AX join: the fallback re-reads every mode itself")
    }

    // 4. The every-Space mode gate is the Apple Events one, unchanged: an Incognito window on another Space or in
    //    fullscreen (not in AXWindows) refuses, before any content.
    do {
        let x = AXJoinWorld(); x.w.addWindow("202", mode: "incognito", front: false, onThisSpace: false)
        let r = x.run()
        try check(r.denial == .notNormal && !x.w.log.contains(where: AXJoinWorld.isContent),
                  "AX join: an Incognito window on another Space refuses before any content (\(r))")
        let y = AXJoinWorld(); y.w.windows[0].mode = nil
        try check(y.run().denial == .notNormal, "AX join: a window whose mode can't be read refuses")
        let z = AXJoinWorld(); z.w.failing = ["mode"]
        try check(z.run().denial != nil && !z.w.log.contains(where: AXJoinWorld.isContent), "AX join: a mode read that times out refuses")
    }
    // The confirming read's closing re-read: a window turns private or appears while the page was read.
    do {
        let x = AXJoinWorld(); x.onDocument = { n in if n == 2 { x.w.windows[0].mode = "incognito" } }
        try check(x.run().denial == .notNormal, "AX join: a mode that changed during the page reads refuses (closing re-read)")
        let y = AXJoinWorld(); y.onDocument = { n in if n == 2 { y.w.addWindow("303", mode: "incognito", front: false, onThisSpace: false) } }
        try check(y.run().denial == .changed, "AX join: a window opened during the page reads refuses (closing re-read)")
        let z = AXJoinWorld(); z.onDocument = { n in if n == 1 { z.w.windows[0].mode = "incognito" } }
        try check(z.run().denial == .notNormal, "AX join: a mode that changed between the reads refuses")
    }
    // X rewrites its title (an unread count, a post's "… on X: …"): the Accessibility join binds the window by its
    // number and the page by its address and web area, so a title changed between the reads is not a changed window;
    // the place is then the site only. The full join's title still binds its window: unchanged (`changed`).
    do {
        let x = AXJoinWorld(); x.w.web.title = "Home / X"; x.w.window.title = "Home / X - Google Chrome"
        let steady = x.run()
        try check(steady.proof?.pageTitle.isEmpty == false, "AX join: a steady title is saved as the place (\(steady.proof?.pageTitle ?? "nil"))")
        let y = AXJoinWorld(); y.w.web.title = "Home / X"; y.w.window.title = "Home / X - Google Chrome"
        y.onDocument = { n in if n == 1 { y.w.web.title = "(3) Home / X"; y.w.window.title = "(3) Home / X - Google Chrome" } }
        let churn = y.run()
        try check(churn.proof?.windowID == "ax-window-6409" && churn.proof?.pageTitle == "" && y.w.aeCount == 4,
                  "AX join: X's title changing between the reads is allowed, site only, no Apple Events join (\(churn))")
        let z = AXJoinWorld(); z.w.window.title = "Home / X - Google Chrome"
        z.onDocument = { n in if n == 1 { z.w.window.title = "Home / X - Google Chrome (Incognito)" } }
        try check(z.run().denial == .notNormal, "AX join: a title that turns Incognito between the reads still refuses")
        // The full join (Chrome 153, a popup's fallback): one window with the focused window's bounds binds by bounds, so
        // a title changed between its reads is allowed (site only); with a same-bounds window on another Space the title
        // decided which window, and a title changed between the reads still refuses.
        func old(_ twin: Bool) -> (AXJoinWorld, BrowserTypingJoinResult) {
            let o = AXJoinWorld(); o.w.facts.bundleVersion = "153.0.8010.54"; o.w.facts.frameworkVersions = ["153.0.8010.54"]
            o.w.windows[0].name = "Home / X"; o.w.window.title = "Home / X - Google Chrome"
            if twin { o.w.addWindow("202", mode: "normal", front: false, bounds: FakeChromeWorld.bounds, name: "Other page", onThisSpace: false) }
            o.w.onAppleEvent = { r, n in
                if case .windowIDs = r, n > 2, o.w.windows[0].name == "Home / X", o.w.log.contains(where: { $0.hasPrefix("ae:url:") }) {
                    o.w.window.title = "(3) Home / X - Google Chrome"; o.w.windows[0].name = "(3) Home / X"
                }
            }
            return (o, o.run())
        }
        let (o1, r1) = old(false)
        try check(r1.proof?.windowID == "101" && r1.proof?.pageTitle == "" && o1.tookAppleEventsJoin,
                  "AX join: the full join with one same-bounds window allows X's title changing between its reads, site only (\(r1))")
        let (_, r2) = old(true)
        try check(r2.denial == .changed, "AX join: the full join whose title chose among same-bounds windows still refuses a changed title (\(r2))")
        let (o3, r3) = old(false); _ = o3
        try check(r3.proof != nil, "AX join: the full join's title churn check is repeatable")
    }
    // More standard windows on this Space than Apple Events lists on every Space (an Incognito window opening).
    do {
        let x = AXJoinWorld()
        x.w.axWindows?.append(x.w.axOnlyWindow("ax-only", frame: ChromeBounds(left: 10, top: 10, right: 500, bottom: 500), title: "x"))
        try check(x.run().denial == .unlistedWindow, "AX join: a standard window Apple Events doesn't list refuses")
    }

    // 5. Same page on both sides: the window's AXDocument (browser process) and the page's AXURL.
    for (what, doc) in [("another path", "https://mail.google.com/mail/u/1/?compose=new"),
                        ("another query", "https://mail.google.com/mail/u/0/?compose=old"),
                        ("another origin", "https://evil.example.com/mail/u/0/?compose=new"),
                        ("no address", nil)] as [(String, String?)] {
        let x = AXJoinWorld(); x.w.window.document = doc
        try check(x.run().denial == .url, "AX join: the window's address and the page's differ (\(what)) refuses")
    }
    do {
        let x = AXJoinWorld(); x.w.window.document = "https://mail.google.com/mail/u/0/?compose=new#other"
        try check(x.run().proof != nil, "AX join: the fragment alone may differ (as the full join)")
        let y = AXJoinWorld(); y.w.window.document = "https://accounts.google.com/signin"; y.w.web.url = "https://accounts.google.com/signin"
        try check(y.run().denial == .blockedSite, "AX join: an always-blocked site refuses")
    }
    // 6. Window identity, focus, frames and fields: the full join's rules.
    do {
        let x = AXJoinWorld(); x.identity = nil
        try check(x.run().denial == .window, "AX join: a window without its number refuses")
        let y = AXJoinWorld(); y.identity = String(repeating: "9", count: 41)
        try check(y.run().denial == .window, "AX join: an oversized window number refuses")
        let z = AXJoinWorld(); z.w.secure = true
        try check(z.run().denial != nil && !z.w.log.contains(where: AXJoinWorld.isContent), "AX join: secure input refuses before any content")
        let s = AXJoinWorld(); s.w.field.subrole = "AXSecureTextField"
        try check(s.run().denial == .field, "AX join: a password field refuses")
        let l = AXJoinWorld(); l.w.field.labels = BrowserTypingFieldLabels(texts: ["Password"], identifiers: ["pass"])
        try check(l.run().denial == .sensitiveField, "AX join: a sensitive field refuses")
        let n = AXJoinWorld()
        let inner = FakeAXNode("inner-web", role: "AXWebArea", parent: n.w.group, owner: FakeChromeWorld.chromePID)
        n.w.field.parent = inner; inner.url = n.w.web.url
        try check(n.run().denial == .frame, "AX join: a field in a frame (two web areas) refuses")
        let o = AXJoinWorld(); o.w.axFocus = o.toolbar.kids.first { $0.name == "omnibox" }
        try check(o.run().denial != nil, "AX join: the address bar refuses")
        let m = AXJoinWorld(); m.w.window.minimized = true
        try check(m.run().denial == .window, "AX join: a minimized focused window refuses")
        let d = AXJoinWorld(); d.w.enabled = false
        try check(d.run().denial == .disabled && d.w.aeCount == 0, "AX join: typing off asks nothing")
    }
    // 7. Unchanged elsewhere: another build, the switch off, or an adapter without every seam takes the full join.
    for (what, setUp) in [("Chrome 153", { (x: AXJoinWorld) in x.w.facts.bundleVersion = "153.0.8010.54"; x.w.facts.frameworkVersions = ["153.0.8010.54"] }),
                          ("the switch off", { _ in ChromeAXJoinPolicy.enabled = false }),
                          ("no AXDocument seam", { x in x.seams.remove("document") }),
                          ("no window number seam", { x in x.seams.remove("identity") }),
                          ("no view class seam", { x in x.seams.remove("classes") }),
                          ("no description seam", { x in x.seams.remove("described") })] as [(String, (AXJoinWorld) -> Void)] {
        let x = AXJoinWorld(); setUp(x)
        let r = x.run()
        ChromeAXJoinPolicy.enabled = true
        try check(r.proof?.windowID == "101" && x.tookAppleEventsJoin && !x.w.log.contains { $0.hasPrefix("ax:document:") || $0.hasPrefix("ax:described:") },
                  "AX join: \(what): the full Apple Events join, unchanged (\(r))")
    }
    do {
        // The default environment (fixtures, no policy wired) never takes the Accessibility join.
        let x = AXJoinWorld()
        let r = BrowserTypingJoin<FakeAXNode>().join(environment: x.w.environment, appleEvents: x.w.ae, accessibility: x.access,
                                                     blockList: BrowserTypingBlockList(), alwaysBlocked: PrivacySettings.sensitiveDomains)
        try check(r.proof?.windowID == "101", "AX join: off unless the environment opts in")
    }
}
#endif
