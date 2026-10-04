import Foundation
import ApplicationServices
import HistoryCore
@testable import MemoryCore
import PrivacyPolicy

// claude/chrome-offmain-1003 (PERF-1003 risk 1): website typing's Chrome join and per-key checks moved off the main
// thread (`TypingKeyHandoff`, `TypingRouteExecutor`). This replays one synthetic, recorded-shape key stream through the
// real EventCapture, WebTypingRoute, Coordinator and sealed store twice: once with the route on the caller (the main
// thread, as before) and once with the route on its executor and each key's work handed back to a separate "tap"
// thread, as the event tap thread runs it. Every saved row, table by table, must be byte-identical (record ids,
// which are random, numbered in order of first appearance; sealed text compared as its plaintext). The stream has
// mid-typing tab switches (with and without a key or click), refusals in the middle (an Incognito window, a blocked
// site, a password field, an input method), the speaker and "Audio playing" tab state, Command-Return confirmations
// (0.12 / 0.35 / 0.8 s re-reads), a click save, a Post click, and fix/chrome-x2's send grace and results-page searches.
// Fake Chrome only: no Apple Event, Accessibility call, event tap, permission, Chrome launch or real history.
// It also prints the main-thread time per allowed Chrome key in the owner test model (an X reply, 12.5 ms per Apple
// Event), from the fake clock and measured with real 12.5 ms waits per Apple Event.

#if DAYDREAM_OWNER_TYPING
final class OffNode {
    let name: String
    var role: String, subrole: String
    var parent: OffNode? { didSet { oldValue?.kids.removeAll { $0 === self }; parent?.kids.append(self) } }
    var kids: [OffNode] = []
    var frame: ChromeBounds?
    var title: String?, url: String?
    var labels: BrowserTypingFieldLabels? = BrowserTypingFieldLabels(texts: [], identifiers: [])
    var enabled: Bool? = true, desc: String?
    /// Chrome's AXEditableAncestor (an editable combo box is its own).
    weak var editableAncestor: OffNode?
    init(_ name: String, role: String, subrole: String = "", parent: OffNode? = nil) {
        self.name = name; self.role = role; self.subrole = subrole; self.parent = parent; parent?.kids.append(self)
    }
}

/// The fake clock. Each Apple Event and Accessibility read the fake Chrome answers spends time on it, counted against
/// the thread that made it (the main thread or not); with `sleep`, the same time is also really waited.
final class OffClock {
    var mono: UInt64 = 100_000_000_000
    var mainNs: UInt64 = 0, offNs: UInt64 = 0
    var sleep = false
    func spend(_ ns: UInt64) {
        mono &+= ns
        if Thread.isMainThread { mainNs &+= ns } else { offNs &+= ns }
        if sleep { usleep(UInt32(ns / 1000)) }
    }
}

final class OffTab {
    let id: String
    var url: String, name: String
    /// The speaker Chrome appends to the window's Apple Events name while the tab plays sound.
    var indicator: String?
    /// The tab state Chrome's accessible title adds after the page title (" - Audio playing").
    var state: String?
    let web: OffNode, group: OffNode, field: OffNode
    var focus: OffNode?
    init(_ id: String, url: String, name: String, label: String, role: String = "AXTextArea", identifiers: [String] = []) {
        self.id = id; self.url = url; self.name = name
        web = OffNode("web-" + id, role: "AXWebArea"); web.url = url
        group = OffNode("group-" + id, role: "AXGroup", parent: web)
        field = OffNode("field-" + id, role: role, parent: group)
        field.labels = BrowserTypingFieldLabels(texts: [label], identifiers: identifiers)
        if role == "AXComboBox" { field.editableAncestor = field }
    }
    var aeName: String { name + (indicator.map { " " + $0 } ?? "") }
    var axTitle: String { name + (state.map { " - " + $0 } ?? "") + " - Google Chrome - Sam" }
}

final class OffChrome {
    struct Window { var id: String; var mode: String?; var bounds: ChromeBounds; var name: String; var tab: String; var url: String }
    static let pid: Int32 = 99_997 // above macOS's highest pid: never a real process
    let facts = ChromeTargetFacts(pid: pid, bundleID: "com.google.Chrome", launchIdentity: "99997:1790000000:com.google.Chrome", signatureValid: true,
                                  bundleVersion: "153.0.8010.54", frameworkVersions: ["153.0.8010.54"], instances: 1)
    static let bounds = ChromeBounds(left: 0, top: 25, right: 1440, bottom: 900)
    let clock: OffClock
    var windows: [Window]
    var axWindows: [OffNode]
    let window: OffNode, scroll: OffNode, toolbar: OffNode
    private(set) var tab: OffTab
    /// Focus elsewhere than the tab's own focus (a password field, a button, the page).
    var hit: OffNode?
    var aeTick: UInt64 = 12_500_000, axTick: UInt64 = 100_000
    var appleEvents = 0
    init(clock: OffClock, first: OffTab) {
        self.clock = clock
        window = OffNode("window-101", role: "AXWindow", subrole: "AXStandardWindow"); window.frame = ChromeBounds(x: 0, y: 25, width: 1440, height: 875)
        scroll = OffNode("scroll", role: "AXScrollArea", parent: window)
        toolbar = OffNode("omnibox", role: "AXTextField", parent: OffNode("toolbar", role: "AXToolbar", parent: window))
        tab = first
        windows = [Window(id: "101", mode: "normal", bounds: Self.bounds, name: first.aeName, tab: first.id, url: first.url)]
        axWindows = [window]
        show(first)
    }
    var main: Int { windows.count - 1 }
    /// The window's active tab becomes `t` (what a tab switch does; no event of its own).
    func show(_ t: OffTab) {
        tab.web.parent = nil; t.web.parent = scroll; tab = t
        windows[main].tab = t.id; windows[main].url = t.url; windows[main].name = t.aeName; window.title = t.axTitle; t.web.url = t.url
    }
    /// The page in the active tab changes (its address and title).
    func navigate(_ url: String, name: String? = nil) {
        tab.url = url; if let name { tab.name = name }
        show(tab)
    }
    func retitle() { show(tab) }
    func addWindow(_ id: String, mode: String?) {
        let b = ChromeBounds(left: 200, top: 100, right: 1000, bottom: 700)
        windows.insert(Window(id: id, mode: mode, bounds: b, name: "Private", tab: "9" + id, url: "https://private.example.net/secret"), at: 0)
        let node = OffNode("window-" + id, role: "AXWindow", subrole: "AXStandardWindow"); node.frame = b; node.title = "Private"; axWindows.append(node)
    }
    func removeWindow(_ id: String) { windows.removeAll { $0.id == id }; axWindows.removeAll { $0.name == "window-" + id } }
    func environment(enabled: @escaping () -> Bool) -> ChromeJoinEnvironment {
        ChromeJoinEnvironment(now: { self.clock.mono }, enabled: enabled, target: { self.facts }, automationPermitted: { $0 == Self.pid },
                              launchIdentity: { $0 == Self.pid ? self.facts.launchIdentity : nil })
    }
    func ae(_ r: ChromeJoinRequest) -> ChromeJoinReply? {
        appleEvents += 1; clock.spend(aeTick)
        let w = r.windowID.flatMap { id in windows.first { $0.id == id } }
        switch r {
        case .windowIDs: return .ids(windows.map(\.id))
        case .modes: return .texts(windows.compactMap(\.mode))
        case .allBounds: return .boundsList(windows.map(\.bounds))
        case .mode: return w?.mode.map { .text($0) }
        case .bounds: return w.map { .bounds($0.bounds) }
        case .name: return w.map { .text($0.name) }
        case .activeTabID: return w.map { .text($0.tab) }
        case .tabURL(_, let t): return w.flatMap { $0.tab == t ? .text($0.url) : nil }
        }
    }
    var access: ChromeAXAccess<OffNode> {
        ChromeAXAccess<OffNode>(frontmostPID: { Self.pid }, systemFocusedPID: { Self.pid }, secureInput: { false },
            focusedWindow: { self.clock.spend(self.axTick); return self.window }, windows: { self.axWindows },
            focusedElement: { self.clock.spend(self.axTick); return self.tab.focus ?? self.tab.field }, owner: { _ in Self.pid },
            role: { $0.role }, subrole: { $0.subrole }, parent: { $0.parent }, frame: { $0.frame }, minimized: { _ in false }, title: { $0.title }, url: { $0.url },
            fieldLabels: { $0.labels }, equal: { $0 === $1 }, editableAncestor: { $0.editableAncestor }, elementAt: { _, _ in self.hit },
            enabled: { $0.enabled }, controlNames: { [$0.title ?? "", $0.desc ?? ""] }, children: { $0.kids })
    }
}

/// The event tap thread's part, for the off-main replay: runs a key's handed-back work on a thread of its own while the
/// caller waits, as the tap thread runs it before taking its next event.
final class OffTapThread {
    private let go = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
    private var job: (() -> Void)?
    init() {
        let t = Thread { [unowned self] in while true { self.go.wait(); self.job?(); self.job = nil; self.done.signal() } }
        t.name = "chrome-offmain-checks tap"; t.start()
    }
    func run(_ work: @escaping () -> Void) { job = work; go.signal(); done.wait() }
}

struct OffRun {
    var dump = ""
    var words: [String] = []
    var reads = 0, joins = 0, lights = 0
    /// claude/typing-1004: key reads made off the main queue (the tap thread, the route's executor).
    var offMainReads = 0
    var benchKeys = 0, benchJoins = 0, benchLights = 0
    var benchMainModelNs: UInt64 = 0, benchMainWallNs: UInt64 = 0, benchKeyWallNs: UInt64 = 0
    var sleptMainWallNs: UInt64 = 0, sleptKeyWallNs: UInt64 = 0, sleptKeys = 0, fastKeys = 0
    var finished = false
    /// Each typed row's tab, and its confirmation, by its words; search rows.
    var tabs: [String: String] = [:], confirms: [String: String] = [:]
    var searches = 0
}

@main struct ChromeOffMainChecks {
    static var checks = 0
    static func check(_ condition: Bool, _ name: String) { precondition(condition, name); checks += 1; print("PASS " + name) }

    /// claude/typing-1004: AppKit's key reading called off the main queue (it traps on macOS 15).
    static var appKitOffMain = 0
    static func keyEvent(_ text: String) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        let units = Array(text.utf16)
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        return event
    }

    static func main() throws {
        setbuf(stdout, nil)
        check(OwnerTyping.enabled, "chrome-offmain: the owner build")
        EventCapture.appKitCharacters = { event in
            if !MainQueue.isCurrent { appKitOffMain += 1 }
            return EventCapture.eventCharacters(event)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-offmain-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // One wall clock origin for both replays (the store refuses rows dated before its consent and recording).
        let wallBase = Date().addingTimeInterval(60)
        let before = try replay(root: root.appendingPathComponent("before"), offMain: false, wallBase: wallBase)
        let after = try replay(root: root.appendingPathComponent("after"), offMain: true, wallBase: wallBase)
        if let dir = ProcessInfo.processInfo.environment["CHROME_OFFMAIN_DUMP"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try before.dump.write(toFile: dir + "/before.txt", atomically: true, encoding: .utf8)
            try after.dump.write(toFile: dir + "/after.txt", atomically: true, encoding: .utf8)
        }
        print("REPLAY before: \(before.words.count) typed rows, \(before.reads) key reads, \(before.joins) full joins, \(before.lights) light checks")
        print("REPLAY after:  \(after.words.count) typed rows, \(after.reads) key reads, \(after.joins) full joins, \(after.lights) light checks")
        for (i, w) in before.words.enumerated() { print("ROW \(i + 1): \(w)") }

        // What the stream saves (with the route on main, as before). The product's rules, unchanged: words left in a tab
        // that changed under them with no key or click are dropped (no fresh join can prove their field any more), and
        // the first keys after a switch or a refusal fall in its quiet period.
        let w = before.words
        func has(_ s: String) -> Bool { w.contains(s) }
        check(has("a normal reply typed at about twelve keys a second"), "replay: the owner-model X reply (speaker and Audio playing tab state) is saved")
        check(before.tabs["econd tab "] == "8" && before.tabs["back on the first "] == "7" && before.tabs["more in two"] == "8",
              "replay: mid-typing tab switches (Control-Tab, a click on a tab) save each tab's words with that tab (\(before.tabs))")
        check(!w.contains { $0.contains("first tab words") }, "replay: words left in a tab that changed under them (no event) are dropped, not given to the new tab")
        check(!w.contains { $0.contains("words second") || $0.contains("tab back") || $0.contains("first more") },
              "replay: no row joins words typed in two tabs")
        check(!w.contains { $0.contains("hidden") || $0.contains("bank") || $0.contains("hunter") || $0.contains("kana") },
              "replay: nothing typed during a refusal in the middle (Incognito, blocked site, password field, input method) is saved")
        check(has("after incognito") && has("safe again") && has("visible"), "replay: typing after each refusal is saved")
        check(!w.contains { $0.contains("boundary") }, "replay: a privacy boundary from the main thread mid-typing drops the unsaved words")
        check(has("agreed on all of it") && has("still in the box") && has("sounds good to me") && has("then kept typing"),
              "replay: Command-Return sends are saved")
        check(before.confirms["agreed on all of it"] == "fieldCleared" && before.confirms["a normal reply typed at about twelve keys a second"] == "fieldCleared"
              && before.confirms["still in the box"] == nil && before.confirms["sounds good to me"] == "composerClosed" && before.confirms["then kept typing"] == nil,
              "replay: the composer re-reads confirm the emptied X box and the closed Gmail compose, and nothing else (\(before.confirms))")
        check(has("shipping the launch build today") && has("launch notes from the timeline"),
              "replay (fix/chrome-x2): send grace saves the X posts the page reacted to")
        check(w.filter { $0 == "red boots size 10" }.count == 1 && before.tabs["red boots size 10"] == "15",
              "replay (fix/chrome-x2): Return in Google's box as the results page loads: the typed search is saved once")
        check(before.searches == 1, "replay (fix/chrome-x2): the results page of that search adds nothing; another results page is one search row (\(before.searches))")
        check(has("posting with the button") && has("cut by a lost key "), "replay: a Post click and a lost key's cut")
        check(has("left behind at the stop"), "replay: the stop's finish saves the words still pending")
        check(before.finished && after.finished, "replay: the stop's finish completes in both modes")

        // The comparison.
        check(before.dump == after.dump,
              "replay: every saved row is byte-identical with the route on main and off main (\(before.dump.utf8.count) bytes, \(before.words.count) typed rows)")
        check(before.reads == after.reads, "replay: the same keys' characters are read (\(before.reads) / \(after.reads))")
        // claude/typing-1004 (owner laptop 10/04, macOS 15.7.2: SIGTRAP under TSMTranslateKeyEvent on the route's queue).
        check(before.offMainReads == 0 && after.offMainReads > 0,
              "replay: off main, the keys' characters are read off the main queue (\(after.offMainReads) of \(after.reads))")
        check(appKitOffMain == 0, "replay: AppKit's key reading (TSM) never runs off the main queue (\(appKitOffMain))")
        check(before.joins == after.joins && before.lights == after.lights,
              "replay: the same joins and light checks are made (\(before.joins)/\(after.joins) joins, \(before.lights)/\(after.lights) light)")

        // The owner test model's numbers.
        func ms(_ ns: UInt64, _ n: Int) -> Double { Double(ns) / Double(max(1, n)) / 1e6 }
        print(String(format: "BENCH chrome-offmain owner model (X reply, %d keys, %d full joins, %d light, 12.5 ms per Apple Event): main-thread ms/key from the fake clock before %.1f, after %.1f",
                     before.benchKeys, before.benchJoins, before.benchLights, ms(before.benchMainModelNs, before.benchKeys), ms(after.benchMainModelNs, after.benchKeys)))
        print(String(format: "BENCH chrome-offmain measured (real 12.5 ms waits per Apple Event, %d keys): main-thread ms/key before %.2f, after %.2f; whole key ms/key before %.2f, after %.2f",
                     before.sleptKeys, ms(before.sleptMainWallNs, before.sleptKeys), ms(after.sleptMainWallNs, after.sleptKeys),
                     ms(before.sleptKeyWallNs, before.sleptKeys), ms(after.sleptKeyWallNs, after.sleptKeys)))
        print(String(format: "BENCH chrome-offmain measured (no waits, the model's other %d keys): main-thread ms/key before %.3f, after %.3f",
                     before.fastKeys, ms(before.benchMainWallNs, before.fastKeys), ms(after.benchMainWallNs, after.fastKeys)))
        check(before.benchKeys == 51 && after.benchKeys == 51, "bench: the owner model's 51 keys")
        check(ms(before.benchMainModelNs, before.benchKeys) > 20, "bench: on main, an allowed Chrome key costs the main thread its Apple Events")
        check(ms(after.benchMainModelNs, after.benchKeys) < 3 && ms(after.sleptMainWallNs, after.sleptKeys) < 3,
              "bench: off main, an allowed Chrome key costs the main thread under 3 ms (model and measured)")
        print("\(checks) chrome-offmain checks passed. No tap, AX read, Apple Event, permission or real history.")
    }

    // MARK: - One replay

    static func replay(root: URL, offMain: Bool, wallBase: Date) throws -> OffRun {
        var run = OffRun()
        let store = try MemoryStore(home: root, writable: true, automaticallySyncSearch: false)
        try store.attachVault(TypedTextVault(keyStore: InMemoryTypedKeyStore())); try store.setUpTypedVault(); try store.acceptSafeTyping()
        let coordinator = try Coordinator(store: store, permissions: { true }) {}
        let clock = OffClock()
        let monoBase = clock.mono
        func wall() -> Date { wallBase.addingTimeInterval(Double(clock.mono &- monoBase) / 1e9) }
        var direct = true, secureOn = false, boxValue = ""
        // Timers: capture's (run on main) and the route's (run on its executor off main), in time order.
        let timerLock = NSLock()
        var timers: [(at: UInt64, seq: Int, route: Bool, work: () -> Void)] = [], seq = 0
        func addTimer(_ delay: TimeInterval, route: Bool, _ work: @escaping () -> Void) {
            timerLock.lock(); seq += 1; timers.append((clock.mono &+ UInt64(max(0, delay) * 1_000_000_000), seq, route, work)); timerLock.unlock()
        }
        func nextTimer(upTo target: UInt64) -> (at: UInt64, seq: Int, route: Bool, work: () -> Void)? {
            timerLock.lock(); defer { timerLock.unlock() }
            guard let i = timers.indices.filter({ timers[$0].at <= target }).min(by: { (timers[$0].at, timers[$0].seq) < (timers[$1].at, timers[$1].seq) }) else { return nil }
            return timers.remove(at: i)
        }

        // Tabs.
        let notes = OffTab("7", url: "https://notes.example.org/pad/7?view=1", name: "Plans", label: "Notes")
        let docs = OffTab("8", url: "https://docs.example.com/d/42/edit", name: "Launch draft - Docs", label: "Document body")
        let post = "Ada on X: \"launch day notes\" / X"
        let xReply = OffTab("11", url: "https://x.com/ada/status/1839", name: post, label: "Post your reply")
        xReply.indicator = "\u{1F50A}"; xReply.state = "Audio playing"
        let xHome = OffTab("12", url: "https://x.com/home", name: "(3) Home / X", label: "Post text", identifiers: ["notranslate", "public-DraftEditor-content"])
        let gmail = OffTab("13", url: "https://mail.google.com/mail/u/0/#inbox/FMfcgz", name: "Re: Pricing - sam@example.com - Gmail", label: "Message Body")
        let bank = OffTab("14", url: "https://www.chase.com/account", name: "Chase", label: "Memo")
        let google = OffTab("15", url: "https://www.google.com/", name: "Google", label: "Search", role: "AXComboBox", identifiers: ["APjFqb"])
        let chrome = OffChrome(clock: clock, first: notes)
        // X's home composer with its Post button (a click on Post marks the words sent).
        let toolbarX = OffNode("x-toolbar", role: "AXGroup", parent: xHome.group)
        let postButton = OffNode("post", role: "AXButton", parent: toolbarX); postButton.title = "Post"; postButton.frame = ChromeBounds(x: 1000, y: 300, width: 60, height: 30)
        let password = OffNode("password", role: "AXTextField", subrole: "AXSecureTextField")

        // The route, with the real join against the fake Chrome.
        let join = BrowserTypingJoin<OffNode>()
        var env = WebTypingRoute.Environment(now: { clock.mono }, wall: wall, join: { pid, sites, enabled in
            run.joins += 1
            guard pid == OffChrome.pid else { return .denied(.untrustedTarget) }
            return join.join(environment: chrome.environment(enabled: enabled), appleEvents: chrome.ae, accessibility: chrome.access,
                             blockList: sites.blockList, alwaysBlocked: sites.alwaysBlocked, sites: sites.permits(url:), field: sites.permits(url:field:))
        }, pointerJoin: { pid, sites, enabled in
            run.joins += 1
            guard pid == OffChrome.pid else { return .denied(.untrustedTarget) }
            return join.join(environment: chrome.environment(enabled: enabled), appleEvents: chrome.ae, accessibility: chrome.access,
                             blockList: sites.blockList, alwaysBlocked: sites.alwaysBlocked, sites: sites.permits(url:), anyFocus: true)
        }, light: { pid, sites, enabled in
            run.lights += 1
            guard pid == OffChrome.pid else { return nil }
            return join.light(environment: chrome.environment(enabled: enabled), appleEvents: chrome.ae, accessibility: chrome.access,
                              blockList: sites.blockList, alwaysBlocked: sites.alwaysBlocked, sites: sites.permits(url:), field: sites.permits(url:field:))
        }, fieldHeld: { pid in
            pid == OffChrome.pid ? join.holdsRefusedBox(accessibility: chrome.access) : false
        }, schedule: { delay, work in addTimer(delay, route: true, work) }, secureInput: { secureOn }, pressAndHold: { true },
           secondsSinceMouseDown: { nil }, directKeyboardInput: { direct },
           submitControl: { pid, x, y, page, focusID, names, enabled in
            join.submitControl(at: x, y, pid: pid, page: page, focusID: focusID, names: names, environment: chrome.environment(enabled: enabled),
                               accessibility: chrome.access)
        })
        env.composeSnapshot = { _ in join.composeSnapshot(accessibility: chrome.access, value: { _ in boxValue }) }
        env.design = .synchronous
        env.frontmostPID = { OffChrome.pid }
        var executor: TypingRouteExecutor?
        if offMain {
            // As `Environment.live` sets it up: the executor, and the input source read on main and kept for the executor.
            let e = TypingRouteExecutor(label: "chrome-offmain-checks.route")
            executor = e; env.executor = e
            let memory = DirectInputMemory()
            env.directKeyboardInput = { memory.read({ direct }) }
        }
        let route = WebTypingRoute(environment: env)
        WebTypingRoute.shared = route
        let tap = OffTapThread()
        /// Waits for everything the main thread gave the route so far (off main; nothing to wait for on main).
        func drain() { executor?.sync {} }

        let pageEnvironment = ChromePageEnvironment(frontmost: { (OffChrome.pid, "com.google.Chrome", "99997:1:com.google.Chrome", "Google Chrome") }, instances: { 1 },
            secureInput: { false }, verify: { _, _ in false }, permission: { _ in OSStatus(-1743) }, transport: { _ in { _ in nil } },
            background: { $0() }, main: { $0() }, schedule: { _, _ in }, now: wall)
        let typing = EventCapture.TypingEnvironment(now: { clock.mono }, proof: { _, _ in nil }, schedule: { delay, work in addTimer(delay, route: false, work) },
                                                    secureInput: { false }, pressAndHold: { true })
        let capture = EventCapture(coordinator: coordinator, typingEnvironment: typing, pageEnvironment: pageEnvironment)

        /// The recorder's heartbeat on the fake wall clock (the store takes rows only within 5 s of it), on main.
        func beat() { try? coordinator.session.health(permitted: true, now: wall()) }
        func advance(_ seconds: Double) {
            let target = clock.mono &+ UInt64(seconds * 1_000_000_000)
            while let t = nextTimer(upTo: target) {
                clock.mono = max(clock.mono, t.at)
                beat()
                if t.route, let executor { executor.async(t.work); drain() } else { t.work() }
            }
            clock.mono = max(clock.mono, target)
            beat()
        }
        var benchOn = false
        /// One key down, as the tap delivers it: on main as before, or (off main) handled on main with its route work
        /// handed back and run on the tap thread.
        func key(_ stroke: KeyStroke, _ text: String) {
            let at = clock.mono, model = clock.mainNs
            let start = DispatchTime.now().uptimeNanoseconds
            var mainEnd = start
            // claude/typing-1004: the key's characters come from a real key event through EventCapture's own reader
            // (`keyCharacters`), whose AppKit half counts any call off the main queue (macOS 15 traps there).
            let event = keyEvent(text)
            func read() -> String {
                run.reads += 1
                if !MainQueue.isCurrent { run.offMainReads += 1 }
                return EventCapture.keyCharacters(event)
            }
            if let _ = executor {
                TypingKeyHandoff.arm()
                capture.handleNativeKey(eventAt: at, stroke: stroke) { read() }
                let work = TypingKeyHandoff.take()
                mainEnd = DispatchTime.now().uptimeNanoseconds
                if let work { tap.run { work { read() } } }
                drain()
            } else {
                capture.handleNativeKey(eventAt: at, stroke: stroke) { read() }
                mainEnd = DispatchTime.now().uptimeNanoseconds
            }
            let end = DispatchTime.now().uptimeNanoseconds
            if benchOn {
                run.benchKeys += 1; run.benchMainModelNs += clock.mainNs - model
                if clock.sleep { run.sleptKeys += 1; run.sleptMainWallNs += mainEnd - start; run.sleptKeyWallNs += end - start }
                else { run.fastKeys += 1; run.benchMainWallNs += mainEnd - start }
            }
        }
        func type(_ text: String) { for c in text { advance(0.08); boxValue += String(c); key(KeyStroke(keyCode: 0), String(c)) } }
        func ret() { advance(0.08); key(KeyStroke(keyCode: 36), "\r") }
        func commandReturn() { advance(0.08); key(KeyStroke(keyCode: 36, command: true), "") }
        func controlTab() { advance(0.08); key(KeyStroke(keyCode: 48, control: true), "") }
        func click(_ node: OffNode?, x: Double = 1030, y: Double = 315, then: () -> Void = {}) {
            advance(0.3); chrome.hit = node
            TypingPointer.press(TypingPress(x: x, y: y, left: true, clicks: 1, modified: false))
            TypingPointer.down(at: clock.mono); drain()
            then()
            advance(0.1)
            TypingPointer.up(at: clock.mono, x: x, y: y, left: true); drain()
        }
        func inputSource(direct d: Bool) { direct = d; TypingInputSource.changed(); drain() }

        try coordinator.start()
        var p = try store.policy(); p.captureText = true; p.typedConsentVersion = 1; p.browserPages = true
        p.browserPagesConsentVersion = PrivacySettings.browserPagesConsentCurrent; try store.updatePolicy(p); coordinator.captureText = true
        capture.switchFrontmost(pid: OffChrome.pid, bundle: "com.google.Chrome") { _, _ in }
        drain()

        // 1. The owner test model: an X reply on a post page that plays sound (the speaker on the Apple Events name,
        //    "Audio playing" on the accessible title), about twelve keys a second, Command-Return; X empties the box
        //    at 0.1 s (confirmed by the re-reads). The second half really waits 12.5 ms per Apple Event.
        chrome.show(xReply)
        advance(1); boxValue = ""
        benchOn = true
        for (i, c) in "a normal reply typed at about twelve keys a second".enumerated() {
            clock.sleep = i >= 25
            advance(0.08); boxValue += String(c); key(KeyStroke(keyCode: 0), String(c))
        }
        commandReturn()
        benchOn = false; clock.sleep = false
        run.benchJoins = run.joins; run.benchLights = run.lights
        advance(0.1); boxValue = ""; advance(1)

        // 2. Mid-typing tab switches: one with no event at all (a page's own tab switch, between two keys), one with
        //    Control-Tab, one with a click on the tab strip (the click comes before Chrome shows the tab).
        chrome.show(notes); notes.focus = nil
        advance(1); type("first tab words ")
        chrome.show(docs)
        type("second tab ")
        controlTab(); chrome.show(notes); advance(0.6)
        type("back on the first ")
        click(chrome.toolbar, x: 300, y: 40) { chrome.show(docs) }
        advance(0.6); type("more in two"); ret(); advance(1)

        // 3. Refusals in the middle of typing: an Incognito window opens and closes, a blocked site's tab, a password
        //    field, an input method; each with words on both sides.
        chrome.show(notes)
        advance(1); type("before incognito ")
        chrome.addWindow("202", mode: "incognito")
        type("hidden words")
        chrome.removeWindow("202")
        advance(1); type("after incognito"); ret(); advance(1)
        type("safe words ")
        chrome.show(bank); type("bank words")
        chrome.show(notes); advance(1); type("safe again"); ret(); advance(1)
        password.parent = notes.group; notes.focus = password
        type("hunter2hunter2")
        notes.focus = nil; password.parent = nil
        advance(1); type("visible"); ret(); advance(1)
        inputSource(direct: false); type("kana kana"); inputSource(direct: true)
        advance(1)

        // 4. Command-Return confirmations: X empties its box at 0.05 s; X keeps the words; Gmail's compose closes at
        //    0.3 s; a key typed after the gesture ends the re-reads.
        chrome.show(xReply); xReply.focus = nil
        advance(1); boxValue = ""; type("agreed on all of it"); commandReturn()
        advance(0.05); boxValue = ""; advance(1)
        advance(1); boxValue = ""; type("still in the box"); commandReturn(); advance(2)
        chrome.show(gmail)
        advance(1); boxValue = ""; type("sounds good to me"); commandReturn()
        advance(0.3); gmail.field.parent = nil; advance(3); gmail.field.parent = gmail.group
        advance(1); boxValue = ""; type("then kept typing"); commandReturn(); advance(0.05); type("x"); gmail.field.parent = nil; advance(3)
        gmail.field.parent = gmail.group

        // 5. fix/chrome-x2 send grace. X's home composer: X empties it and moves focus to Post before the click join.
        chrome.show(xHome); xHome.focus = nil
        advance(1); boxValue = ""; type("shipping the launch build today")
        xHome.focus = postButton; boxValue = ""
        commandReturn(); advance(1)
        xHome.focus = nil
        // The /compose/post window closes onto the timeline before the click join: parked, saved at the settle.
        chrome.navigate("https://x.com/compose/post")
        advance(1); boxValue = ""; type("launch notes from the timeline")
        chrome.navigate("https://x.com/home"); boxValue = ""
        commandReturn(); advance(1)
        // Google's own box: Return as the results page loads (parked), saved once the results page is in; then page
        // history's read of that results page (the same search: saved once) and of another one (a search of its own).
        chrome.show(google); google.focus = nil
        advance(1); type("red boots size 10")
        chrome.windows[chrome.main].url = "https://www.google.com/search?q=red+boots+size+10"
        ret()
        chrome.navigate("https://www.google.com/search?q=red+boots+size+10", name: "red boots size 10 - Google Search"); google.focus = google.web
        advance(1)
        var read = ChromePageRead(windowID: "101", tabID: google.id, origin: "https://www.google.com", title: "", siteOnly: true)
        read.search = ("Google", "red boots size 10")
        route.recordSearch(read, coordinator: coordinator); drain()
        advance(2)
        read.search = ("Google", "weather in austin")
        route.recordSearch(read, coordinator: coordinator); drain()
        google.focus = nil
        advance(1)

        // A privacy boundary from the main thread mid-typing (what capture does at a pause or secure input): nothing saved.
        chrome.show(notes); notes.focus = nil
        advance(1); type("dropped at the boundary"); route.drop(.policy); advance(6)

        // 6. A Post click on X's home composer (the press saves the words; the release on Post marks them sent), a key
        //    lost at intake and a Chrome window notification mid-typing, then the stop's finish with words pending.
        chrome.show(xHome); xHome.focus = nil; boxValue = ""
        advance(1); type("posting with the button")
        click(postButton); advance(1)
        chrome.show(notes); notes.focus = nil
        advance(1); type("cut by a lost key "); TypingKeyGap.lost(at: clock.mono); drain(); type("after the gap")
        route.chromeWindowNotification(); drain(); ret(); advance(1)
        type("left behind at the stop")
        var finished = false
        capture.finishPendingTyping { finished = true }
        drain()
        let deadline = Date().addingTimeInterval(5)
        while !finished && Date() < deadline { advance(0.05); RunLoop.main.run(until: Date().addingTimeInterval(0.01)); drain() }
        run.finished = finished
        drain()

        run.words = try store.rows("SELECT id FROM records WHERE json_extract(body,'$.kind')='keyboard.text_input' ORDER BY rowid")
            .compactMap { try store.hydrateTypedText($0[0], disclosure: .owner, now: wall()) }
        run.dump = try dump(store, now: wall())
        for id in try store.rows("SELECT id FROM records WHERE json_extract(body,'$.kind')='keyboard.text_input' ORDER BY rowid").map({ $0[0] }) {
            if id.hasPrefix("web-search-") { run.searches += 1 }
            guard let text = try store.hydrateTypedText(id, disclosure: .owner, now: wall()) else { continue }
            run.tabs[text] = try store.rows("SELECT json_extract(body,'$.browserVerification.tabID') FROM records WHERE id=?", [id]).first?.first
            if let c = try store.typedUnit(id, disclosure: .owner)?.confirm { run.confirms[text] = c }
        }
        capture.stop(reason: "chrome-offmain replay done")
        coordinator.stop()
        drain()
        return run
    }

    /// Every table's rows in insertion order: random ids numbered by first appearance, sealed text as its plaintext.
    static func dump(_ store: MemoryStore, now: Date) throws -> String {
        var ordinals: [String: Int] = [:]
        let uuid = try NSRegularExpression(pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
        func canon(_ s: String) -> String {
            let ns = s as NSString
            var out = "", last = 0
            for m in uuid.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let id = ns.substring(with: m.range).lowercased()
                if ordinals[id] == nil { ordinals[id] = ordinals.count + 1 }
                out += "<id\(ordinals[id]!)>"
                last = m.range.location + m.range.length
            }
            return out + ns.substring(from: last)
        }
        var out = ""
        for table in try store.rows("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").map({ $0[0] }) {
            let columns = try store.rows("SELECT name FROM pragma_table_info(?)", [table]).map { $0[0] }
            guard let rows = try? store.rows("SELECT * FROM \"\(table)\" ORDER BY rowid") else { continue }
            out += "== \(table) (\(columns.joined(separator: ","))) \(rows.count) rows\n"
            for row in rows {
                var fields: [String] = []
                for (i, value) in row.enumerated() {
                    let column = i < columns.count ? columns[i] : "\(i)"
                    if (table == "typed_text" || table == "typed_recipients"), column == "sealed" {
                        let plain = table == "typed_text" ? ((try? store.hydrateTypedText(row[0], disclosure: .owner, now: now)) ?? nil) : nil
                        fields.append("sealed=<plaintext:\(plain ?? "?")>")
                    } else if table == "records", column == "revision" {
                        fields.append("revision=<hash of the body>")
                    } else {
                        // The typed words' digest is keyed by the store's own typing key (random per store): the words
                        // themselves are compared as plaintext in typed_text.
                        fields.append(column + "=" + value.replacingOccurrences(of: "\"digest\":\"[0-9a-f]{64}\"", with: "\"digest\":\"<keyed>\"",
                                                                                 options: .regularExpression))
                    }
                }
                let line = canon(fields.joined(separator: " | "))
                // Setup, before the replay, on the real clock (not the route's): the typing consent and its seal, and
                // the app switch to Chrome. Listed, not compared.
                if table == "metadata", ["typed-text-policy-v1", "typed-text-policy-mac-v1"].contains(row[0]) { out += "(setup, real clock) id=\(row[0])\n"; continue }
                if table == "records", line.contains("\"kind\":\"app.activated\"") { out += "(setup, real clock) app.activated\n"; continue }
                out += line + "\n"
            }
        }
        // Each typed row as the app reads it: its unit facts (send, confirmation, context) and its action's state.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        out += "== typed units\n"
        for id in try store.rows("SELECT id FROM records WHERE json_extract(body,'$.kind')='keyboard.text_input' ORDER BY rowid").map({ $0[0] }) {
            let unit = try store.typedUnit(id, disclosure: .owner).flatMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? "nil"
            let state = (try? store.action(id, now: now))??.state ?? "nil"
            out += canon("id=\(id) | state=\(state) | unit=\(unit)") + "\n"
        }
        return out
    }
}
#else
@main struct ChromeOffMainChecks {
    static func main() { print("SKIP chrome-offmain: website typing is in owner builds only") }
}
#endif
