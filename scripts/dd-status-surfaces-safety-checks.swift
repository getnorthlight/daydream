// DD-RECIPE: UI
//
// I2 no-implicit-capture check (plan §5 I2 (c); §6 "(new) no implicit capture"). Every surface that shows or
// controls recording is hosted offscreen with counting `CaptureActions`, and only the interactions that must
// never start, pause, resume or stop recording are performed. The pause/resume/stop counters stay 0 (and, where
// the interaction presses nothing, every other closure too):
//  - MemoryShell (inline chrome, canonical day from a temp MemoryStore) in every recording state: render,
//    resize, the status popover opened from the capsule and closed with Esc, Esc in the Focus List,
//    send(.previousDay) / send(.nextDay), Recall opened by a query and by ⌘K's flag and closed with Esc,
//    and midnight (NSCalendarDayChanged on the fixed clock).
//  - StatusPopover and the menu bar panel (MenuBarMenu) alone, in every state: render, resize, Esc, and the Pause
//    row drawn with its submenu open (the submenu is never popped up here: nothing chosen, nothing called).
//  - RecallHost alone: open with a query, results, Esc, close.
//  - SettingsStatusCard inside the settings overview and frame: render, resize, Esc, Return (Done closes once).
//    The card, overview and frame take no CaptureActions at all, so no capture action is reachable from them by
//    construction; that is pinned from their source declarations, and their own closures stay 0. (SwiftUI's
//    onExitCommand does not fire offscreen, so Esc can only be shown to call nothing else here: LIMIT.)
//  - ⌘P: `MenuBarRecordingMenu`'s `Pause for ▸ 15 Minutes` row carries the app's pause shortcut. While Off (and
//    Paused, Needs Permission) it is disabled and ⌘P calls nothing: the item model, the rows hosted in a window,
//    and (macOS 14.4+) the native NSHostingMenu the app's Recording menu is. While Recording, ⌘P pauses for
//    exactly 15 minutes (the positive control that the key path reaches the row at all).
//  - The panel's switch, as VoiceOver reads it: its value is the state (Recording, Paused, Off), so a switch that
//    stays on through a pause is never read as recording while nothing is recorded.
//  - ⌘P in the menu bar panel (the owner's native-menu design: `For 15 Minutes ⌘P`, `Resume Now ⌘P`): it never
//    starts recording. While Off, blocked or Needs Permission it calls nothing; while Recording it pauses for exactly
//    15 minutes and while Paused it resumes (each exactly one call, the positive controls).
// Positive controls prove each interaction happened: the capsule click (see capsulePoint)
// really opens the status popover and Esc closes it, the day really moves and the view loads the other day, Recall
// really opens with the store's results and closes, Esc really collapses the expanded moment, Return closes Settings.
// Synthetic data only: a temp store under DD_CHECK_OUT, no app, no permissions, no recording.
import AppKit
import SwiftUI
import Combine
import MemoryCore
import MemoryUI

/// Reports itself key (the key router and SwiftUI focus act as in the app) and stays offscreen.
final class SafetyWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Counts every `CaptureActions` closure.
@MainActor final class SafetyCalls {
    var pauses: [Int] = [], resumes = 0, stops = 0, settings = 0, system = 0, checks = 0, sections: [String] = []
    var mains = 0, recalls = 0, quits = 0
    var capture: Int { pauses.count + resumes + stops }
    var total: Int { capture + settings + system + checks + sections.count + mains + recalls + quits }
    var summary: String {
        "pauses \(pauses) resumes \(resumes) stops \(stops) settings \(settings) system \(system) checks \(checks) sections \(sections) main \(mains) recall \(recalls) quit \(quits)"
    }
    func reset() { pauses = []; resumes = 0; stops = 0; settings = 0; system = 0; checks = 0; sections = []; mains = 0; recalls = 0; quits = 0 }
    var actions: CaptureActions {
        var a = CaptureActions(pause: { [unowned self] in self.pauses.append($0) }, resume: { [unowned self] in self.resumes += 1 },
                               stop: { [unowned self] in self.stops += 1 }, settings: { [unowned self] in self.settings += 1 })
        a.openSystemSettings = { [unowned self] _ in self.system += 1 }
        a.checkPermissions = { [unowned self] in self.checks += 1 }
        a.openSettingsSection = { [unowned self] in self.sections.append($0) }
        a.openMain = { [unowned self] in self.mains += 1 }
        a.openRecall = { [unowned self] in self.recalls += 1 }
        a.quit = { [unowned self] in self.quits += 1 }
        return a
    }
}

@main @MainActor enum DDStatusSurfacesSafetyChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ name: String, _ got: @autoclosure () -> String = "") {
        if ok { print("PASS " + name) } else {
            failures += 1
            fflush(stdout)
            FileHandle.standardError.write(Data(("FAIL: " + name + (got().isEmpty ? "" : " (got: " + got() + ")") + "\n").utf8))
        }
    }
    static func equal<T: Equatable>(_ got: T, _ want: T, _ name: String) { check(got == want, name, "\(got)") }
    static func limit(_ text: String) { print("LIMIT " + text) }

    // MARK: Clock, zone, fixture

    static let zone = "America/Los_Angeles"
    static let la = TimeZone(identifier: zone)!
    static var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = la; return c }
    static func d(_ day: Int, _ h: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 9, day: day, hour: h, minute: m))! }
    static let start = d(22, 16, 21)
    /// The browsers read this clock; the midnight step moves it.
    static var clock = start
    static let todayKey = "2026-09-22", yesterdayKey = "2026-09-21"

    enum Case: String, CaseIterable { case recording, pausedTimed, pausedSleep, off, offBlocked, needsPermission }
    static func inputs(_ c: Case) -> RecordingStateInputs {
        let now = start
        switch c {
        case .recording:
            return RecordingStateInputs(recording: true, stopped: false, recordingSince: d(22, 8, 40), accessibilityGranted: true, inputMonitoringGranted: true)
        case .pausedTimed:
            return RecordingStateInputs(stopped: false, pauseUntil: now.addingTimeInterval(15 * 60), pausedAt: now.addingTimeInterval(-180),
                                        accessibilityGranted: true, inputMonitoringGranted: true)
        case .pausedSleep:
            return RecordingStateInputs(stopped: false, pausedAt: now.addingTimeInterval(-180), sessionReason: "Paused for sleep. Resume explicitly after waking.",
                                        accessibilityGranted: true, inputMonitoringGranted: true)
        case .off:
            return RecordingStateInputs(stoppedAt: now.addingTimeInterval(-120), accessibilityGranted: true, inputMonitoringGranted: true)
        case .offBlocked:
            return RecordingStateInputs(stoppedAt: now.addingTimeInterval(-120), resumeUnavailable: "Review replacement",
                                        accessibilityGranted: true, inputMonitoringGranted: true)
        case .needsPermission:
            return RecordingStateInputs(stoppedAt: now.addingTimeInterval(-120), resumeUnavailable: "Permissions required",
                                        accessibilityGranted: true, inputMonitoringGranted: false)
        }
    }
    static func permissions(_ c: Case) -> PermissionSnapshot {
        let i = inputs(c)
        return PermissionSnapshot(accessibility: i.accessibilityGranted, inputMonitoring: i.inputMonitoringGranted)
    }
    static func presentation(_ c: Case) -> CapturePresentation { CapturePresentation(inputs: inputs(c), permissions: permissions(c)) }

    static let summaries = SummaryAvailability(provider: .local, busy: false)
    static let exclusions = ExclusionSummary(alwaysPrivate: ["com.apple.keychainaccess"], excludedByYou: ["com.apple.Music"])

    static var root: URL!
    static var store: MemoryStore!
    static var todaySnapshot: TodaySnapshot?

    static func seed() throws {
        let home = root.appendingPathComponent("safety", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        var n = 0
        func moment(_ day: Int, _ h: Int, _ m: Int, _ app: String, _ bundle: String, _ title: String, url: String = "") throws {
            for k in 0..<2 {
                n += 1
                _ = try store.ingest(Evidence(id: "s\(n)", at: iso(d(day, h, m + 3 * k)), kind: "window.changed", app: app, bundle: bundle,
                                              title: title, url: url, synthetic: true), now: start)
            }
        }
        try moment(22, 9, 10, "Zed", "dev.zed.Zed", "Sensor calibration notes")
        try moment(22, 10, 30, "Safari", "com.apple.Safari", "Sensor research", url: "https://example.com/sensors")
        try moment(22, 13, 0, "Notes", "com.apple.Notes", "Weekly plan")
        try moment(22, 15, 40, "Terminal", "com.apple.Terminal", "build logs")
        try moment(21, 10, 0, "Safari", "com.apple.Safari", "Sensor datasheet", url: "https://example.com/datasheet")
        try moment(21, 14, 0, "Numbers", "com.apple.iWork.Numbers", "Budget sheet")
        let today = try store.dayLayers(day: todayKey, timezone: zone, limit: 200, now: start)
        let yesterday = try store.dayLayers(day: yesterdayKey, timezone: zone, limit: 200, now: start)
        check(today.activities.count == 4 && yesterday.activities.count == 2, "fixture: four moments today and two yesterday in the temp store",
              "\(today.activities.count) / \(yesterday.activities.count)")
    }

    static func makeBrowser() -> ActivityBrowser {
        let b = ActivityBrowser(calendar: cal)
        let source = store!
        b.now = { DDStatusSurfacesSafetyChecks.clock }
        b.summaries = summaries
        b.exclusions = exclusions
        b.loadCanonicalDay = { day, cursor in try source.dayLayers(day: day, timezone: zone, after: cursor, limit: 200, now: start) }
        b.searchCanonicalQuery = { q in try source.searchResult(q, now: start) }
        b.reopenCanonical = { _ in }
        b.openApp = { _ in }
        return b
    }

    // MARK: Hosting and input

    static let window: SafetyWindow = {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let w = SafetyWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1172, height: 792), styleMask: [.titled, .resizable],
                             backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.acceptsMouseMovedEvents = true
        w.orderFrontRegardless()
        return w
    }()

    static func pump(_ s: Double = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    @discardableResult
    static func wait(_ seconds: Double = 5, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > end { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return true
    }

    @discardableResult
    static func host<V: View>(_ view: V, size: NSSize) -> NSHostingView<AnyView> {
        let h = NSHostingView(rootView: AnyView(view.environment(\.daydreamNow, clock).environment(\.daydreamStatic, true)))
        window.setContentSize(size)
        window.contentView = h
        h.frame = NSRect(origin: .zero, size: size)
        pump(0.2); h.layoutSubtreeIfNeeded(); pump(0.05)
        return h
    }
    static func resize(_ h: NSView, _ sizes: [NSSize]) {
        for size in sizes {
            window.setContentSize(size)
            h.frame = NSRect(origin: .zero, size: size)
            h.layoutSubtreeIfNeeded()
            pump(0.08)
        }
    }

    /// A key, delivered as the window server does: through the app (local monitors), then the event's window.
    static func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = [], to target: NSWindow? = nil) {
        let w = target ?? window
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                       isARepeat: false, keyCode: code) else { return }
        NSApp.sendEvent(e)
        pump(0.1)
    }
    static func escape(to target: NSWindow? = nil) { key(53, "\u{1b}", to: target) }
    static func commandP() -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: "p", charactersIgnoringModifiers: "p",
                         isARepeat: false, keyCode: 35)!
    }

    /// The accessibility tree under `root`.
    static func elements(_ root: Any, depth: Int = 0, into out: inout [NSAccessibilityProtocol]) {
        guard depth < 40, let e = root as? NSAccessibilityProtocol else { return }
        out.append(e)
        for child in e.accessibilityChildren() ?? [] { elements(child, depth: depth + 1, into: &out) }
    }
    /// Where to click the status capsule, in window coordinates.
    /// - The rendered `capture-state` element's frame, when SwiftUI exposes an accessibility tree and that element
    ///   lies in the 52 pt toolbar row.
    /// - Offscreen SwiftUI exposes no tree here (the hosting view has no accessibility children; UIRender logs one
    ///   native node, dd-focus-list prints LIMITs for the same reason), so otherwise the row's layout: the capsule
    ///   (its own rendered width) is second from the trailing edge, after 16 pt padding, the 32 pt gear and 8 pt
    ///   spacing, on the row's centre line.
    /// Either way the popover must then open (a hard check), so a point that misses the capsule fails the row
    /// instead of quietly dropping the open/close step.
    static func capsulePoint(_ view: NSView, _ p: CapturePresentation) -> (point: CGPoint, source: String) {
        let bounds = view.convert(view.bounds, to: nil)
        let row = NSRect(x: bounds.minX, y: bounds.maxY - 52, width: bounds.width, height: 52)
        var all: [NSAccessibilityProtocol] = []
        elements(view, into: &all)
        if let capsule = all.first(where: { $0.accessibilityIdentifier() == "capture-state" }) {
            let frame = window.convertFromScreen(capsule.accessibilityFrame())
            let centre = CGPoint(x: frame.midX, y: frame.midY)
            if frame.width > 0, frame.height > 0, row.contains(centre) { return (centre, "accessibility frame") }
        }
        // ux/declutter: Off and able to start, the Start Recording pill takes the capsule's place; with an issue its
        // chevron (the pill's trailing 24 pt, identifier capture-state) opens the popover, and its label would start
        // recording. A plain Off's pill has no chevron and no popover (see `opensPopover`).
        if p.state.kind == .off && p.canResume { return (CGPoint(x: row.maxX - 16 - 32 - 8 - 12, y: row.midY), "toolbar layout (pill chevron)") }
        let width = NSHostingView(rootView: StatusCapsule(state: p.state, canStart: p.canResume, timeZone: la)
            .environment(\.daydreamNow, clock)).fittingSize.width
        return (CGPoint(x: row.maxX - 16 - 32 - 8 - width / 2, y: row.midY), "toolbar layout")
    }

    /// A click at `p` in window coordinates.
    static func clickWindow(_ p: CGPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                          pressure: type == .leftMouseDown ? 1 : 0) {
                window.sendEvent(e)
            }
        }
        pump(0.1)
    }
    static func popoverWindows() -> [NSWindow] {
        NSApp.windows.filter { $0 !== window && $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
    }

    // MARK: Main

    static func main() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
            FileHandle.standardError.write(Data("FAIL: dd-status-surfaces-safety watchdog expired\n".utf8)); exit(2)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        // Codex's shared roots, spelled so run-checks.sh's rewrite of the literal prefix leaves them intact.
        let shared = ["/private/tmp/" + "day" + "dream-", "/tmp/" + "day" + "dream-"]
        guard let out = ProcessInfo.processInfo.environment["DD_CHECK_OUT"], out.hasPrefix("/"), !shared.contains(where: { out.hasPrefix($0) }) else {
            FileHandle.standardError.write(Data("FAIL: DD_CHECK_OUT is not a private output directory; run this check through run-checks.sh\n".utf8))
            exit(1)
        }
        root = URL(fileURLWithPath: out, isDirectory: true).appendingPathComponent("stores", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        _ = window
        do {
            try seed()
            shell()
            statusPopover()
            menuBarCard()
            recallHost()
            settingsCard()
            pauseShortcut()
            panelShortcut()
            switchSpeech()
        } catch {
            check(false, "check setup", "\(error)")
        }
        window.orderOut(nil)
        try? FileManager.default.removeItem(at: root)
        if failures > 0 {
            FileHandle.standardError.write(Data("FAIL: \(failures) dd-status-surfaces-safety check(s) failed\n".utf8)); exit(1)
        }
        print("PASS dd-status-surfaces-safety-checks: no status surface starts, pauses, resumes or stops recording on its own; synthetic temp store only, no recording")
        exit(0)
    }

    // MARK: 1. MemoryShell (inline chrome, canonical day)

    static func shell() {
        let calls = SafetyCalls()
        let size = NSSize(width: 1172, height: 792)
        for c in Case.allCases {
            calls.reset()
            clock = start
            let b = makeBrowser()
            let p = presentation(c)
            let h = host(MemoryShell(browser: b, state: p, actions: calls.actions, chrome: .inline), size: size)
            let loaded = wait(6) { (b.today.snapshot?.momentCount ?? 0) > 0 }
            if c == .recording {
                check(loaded && b.today.snapshot?.momentCount == 4, "shell: the canonical day loads today's four moments from the store",
                      "\(String(describing: b.today.snapshot?.momentCount))")
                todaySnapshot = b.today.snapshot
            }
            check(calls.total == 0, "shell \(c.rawValue): rendering calls nothing", calls.summary)

            resize(h, [NSSize(width: 1600, height: 1000), NSSize(width: 900, height: 620), NSSize(width: 680, height: 480), size])
            check(calls.total == 0, "shell \(c.rawValue): resizing 1600×1000 → 900×620 → 680×480 → 1172×792 calls nothing", calls.summary)

            // The status popover, from the capsule (see capsulePoint). Opening and closing are positive controls:
            // a popover that never opens, or that Esc does not close, fails here. This click is also the window's
            // first mouse event; offscreen, the Recall Esc steps below fail without it (seen with the click removed),
            // so a missed click shows up there as well.
            // ux/declutter: a plain Off's Start Recording pill has no chevron (its popover only repeated Start
            // Recording), so there the first mouse event is a click on an empty stretch of the toolbar row, between
            // the search field and the pill, which must open nothing and call nothing.
            let plainOff = p.state.kind == .off && p.canResume && p.issue == nil
            let capsule = capsulePoint(h, p)
            if plainOff {
                let bounds = h.convert(h.bounds, to: nil)
                let empty = CGPoint(x: bounds.maxX - 16 - 32 - 8 - NSHostingView(rootView: StartRecordingButton(action: {}, more: nil)).fittingSize.width - 40, y: bounds.maxY - 26)
                clickWindow(empty)
                check(!wait(0.5) { !popoverWindows().isEmpty }, "shell \(c.rawValue): a plain Off has no status popover to open")
                check(calls.total == 0, "shell \(c.rawValue): clicking the empty toolbar row calls nothing", calls.summary)
            }
            let opened = plainOff ? false : { clickWindow(capsule.point); return wait(1.5) { !popoverWindows().isEmpty } }()
            if !plainOff {
                check(opened, "shell \(c.rawValue): clicking the capsule opens the status popover", "at \(capsule.point) from the \(capsule.source)")
            }
            check(calls.total == 0, "shell \(c.rawValue): opening the status popover calls nothing", calls.summary)
            if opened, let pop = popoverWindows().first {
                escape(to: pop)
                let closed = wait(1.5) { popoverWindows().isEmpty }
                check(closed, "shell \(c.rawValue): Esc closes the status popover", "\(popoverWindows().count) popover window(s)")
                check(calls.total == 0, "shell \(c.rawValue): closing the status popover (Esc) calls nothing", calls.summary)
            }
            for w in popoverWindows() { w.orderOut(nil) }
            pump(0.1)

            // Esc in the Focus List: collapses the expanded moment, calls nothing.
            if let id = b.today.snapshot?.moments.last?.id {
                b.selectedMomentID = id; b.expandedMomentID = id
                pump(0.2)
                escape()
                let collapsed = wait(1.5) { b.expandedMomentID == nil }
                check(collapsed, "shell \(c.rawValue): Esc reaches the Focus List (the expanded moment collapses)",
                      "\(String(describing: b.expandedMomentID))")
                escape()
                check(calls.total == 0, "shell \(c.rawValue): Esc in the Focus List calls nothing", calls.summary)
            } else {
                check(false, "shell \(c.rawValue): today's moments for the Esc step", "no snapshot")
            }

            // Day change: ⌘[ and ⌘] as the Go menu sends them. `send` moves `focusedDay` at once, so the positive
            // control is the view's own read: the Focus List loads yesterday through the day cache (only a drawn
            // past day does), then the run loop turns so anything the view does on a day change has happened.
            b.send(.previousDay)
            let back = wait(3) { b.focusedDay == yesterdayKey && b.dayCache.cachedDay(yesterdayKey) != nil }
            pump(0.3)
            check(back, "shell \(c.rawValue): send(.previousDay) shows yesterday (the view loads it from the store)",
                  "focused \(String(describing: b.focusedDay)) cached \(b.dayCache.cachedDay(yesterdayKey)?.activities.count ?? -1)")
            check(calls.total == 0, "shell \(c.rawValue): moving to yesterday calls nothing", calls.summary)
            b.send(.nextDay)
            let returned = wait(3) { b.focusedDay == nil }
            pump(0.3)
            check(returned, "shell \(c.rawValue): send(.nextDay) returns to today", "\(String(describing: b.focusedDay))")
            check(calls.total == 0, "shell \(c.rawValue): changing the day calls nothing", calls.summary)

            // Recall by query: opens with the store's results; Esc closes it.
            b.query = "sensor"
            let found = wait(4) { b.recallVisible && !b.recallModel.busy && b.recallModel.searchedText == "sensor" && !b.recallModel.items.isEmpty }
            check(found, "shell \(c.rawValue): a query opens Recall with the store's results",
                  "visible \(b.recallVisible) busy \(b.recallModel.busy) searched \(b.recallModel.searchedText) items \(b.recallModel.items.count)")
            for _ in 0..<3 where b.recallVisible { escape() }
            check(!b.recallVisible, "shell \(c.rawValue): Esc closes Recall", "presented \(b.recallPresented) query \(b.query)")
            // Recall by ⌘K's flag (no query): opens and closes.
            b.recallPresented = true
            pump(0.3)
            let presented = b.recallVisible
            for _ in 0..<3 where b.recallVisible { escape() }
            check(presented && !b.recallVisible, "shell \(c.rawValue): Recall opened empty closes with Esc", "presented \(b.recallPresented)")
            check(calls.total == 0, "shell \(c.rawValue): opening, searching and closing Recall calls nothing", calls.summary)

            // Midnight on the fixed clock: today moves to the 23rd.
            clock = d(23, 0, 2)
            NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
            let moved = wait(3) { b.dayCache.todayKey == "2026-09-23" }
            pump(0.3)
            check(moved, "shell \(c.rawValue): midnight moves today to the next day", "\(String(describing: b.dayCache.todayKey))")
            check(calls.total == 0, "shell \(c.rawValue): midnight calls nothing", calls.summary)
            clock = start

            check(calls.capture == 0, "shell \(c.rawValue): render, resize, popover open/close, Esc, day change, Recall and midnight never pause, resume or stop",
                  calls.summary)
            window.contentView = NSView()
            pump(0.1)
        }
    }

    // MARK: 2. StatusPopover alone

    static func statusPopover() {
        let calls = SafetyCalls()
        for c in Case.allCases {
            calls.reset()
            let p = presentation(c)
            let view = StatusPopover(state: p.state, presentation: p, actions: calls.actions, now: start, calendar: cal)
            let fit = NSHostingView(rootView: view.environment(\.daydreamNow, start).environment(\.daydreamStatic, true)).fittingSize
            let h = host(view.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading), size: fit)
            check(fit.width == StatusPopover.width, "popover \(c.rawValue): \(Int(StatusPopover.width)) pt wide", "\(fit)")
            resize(h, [NSSize(width: fit.width, height: fit.height + 120), fit])
            escape()
            check(calls.total == 0 && calls.capture == 0, "popover \(c.rawValue): render, resize and Esc call nothing", calls.summary)
        }
    }

    // MARK: 3. The menu bar panel alone

    static func panel(_ c: Case, _ calls: SafetyCalls, other: @escaping () -> Void, submenuOpen: Bool = false) -> MenuBarMenu {
        MenuBarMenu(presentation: presentation(c), actions: calls.actions, snapshot: todaySnapshot, now: start, calendar: cal,
                    openToday: other, openSetUp: other,
                    typing: TypingMenuRows(state: c == .recording ? .recording(app: "Notes") : .off, shortcut: "⌃⌥⌘T", timeZone: la),
                    typingActions: TypingMenuActions(pause: other, resume: other, openSettings: other), submenuOpen: submenuOpen,
                    presentSubmenu: { _, _, _ in other() }, dismiss: {})
    }

    static func menuBarCard() {
        let calls = SafetyCalls()
        var other = 0
        for c in Case.allCases {
            for open in [false, true] {
                calls.reset(); other = 0
                let view = panel(c, calls, other: { other += 1 }, submenuOpen: open)
                let fit = NSHostingView(rootView: view.environment(\.daydreamNow, start).environment(\.daydreamStatic, true)).fittingSize
                check(fit.width == MenuBarMenu.width, "menu bar panel \(c.rawValue): \(Int(MenuBarMenu.width)) pt wide", "\(fit)")
                let h = host(view.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading), size: fit)
                resize(h, [NSSize(width: fit.width, height: fit.height + 80), fit])
                escape()
                check(calls.total == 0 && calls.capture == 0 && other == 0,
                      "menu bar panel \(c.rawValue)\(open ? " (Pause drawn open)" : ""): render, resize and Esc call nothing",
                      calls.summary + " other \(other)")
            }
        }
    }

    // MARK: 4. RecallHost alone

    static func recallHost() {
        let calls = SafetyCalls()
        let b = makeBrowser()
        let size = NSSize(width: 1172, height: 792)
        b.query = "sensor"
        let h = host(RecallHost(browser: b, state: presentation(.recording), actions: calls.actions), size: size)
        let found = wait(4) { !b.recallModel.busy && b.recallModel.searchedText == "sensor" && !b.recallModel.items.isEmpty }
        check(found, "Recall alone: the query shows the store's results", "items \(b.recallModel.items.count)")
        resize(h, [NSSize(width: 900, height: 620), NSSize(width: 680, height: 480), size])
        escape()
        b.recallPresented = false; b.query = ""
        pump(0.3)
        check(calls.total == 0, "Recall alone: open, search, resize, Esc and close call nothing", calls.summary)
        window.contentView = NSView()
        pump(0.1)
    }

    // MARK: 5. SettingsStatusCard in the settings overview and frame

    static func settingsCard() {
        // The overview has no System Settings or Finder button: Needs Permission's Allow… opens Permissions (a select).
        var closes = 0, selects = 0, acts = 0, learn = 0, advanced = 0
        // The card, the overview and the frame take no CaptureActions, so no capture action can be reached from
        // them. That is a property of their declarations, pinned from source (it fails if one gains the parameter).
        let hub = read("Sources/MemoryUI/SettingsHub.swift"), card = read("Sources/MemoryUI/SettingsStatusCard.swift")
        let declarations = [declaration(card, "SettingsStatusCard"), declaration(hub, "DaydreamSettingsOverview"), declaration(hub, "DaydreamSettingsFrame")]
        check(declarations.allSatisfy { !$0.isEmpty }, "settings: the status card, overview and frame sources are readable",
              declarations.map { "\($0.count)" }.joined(separator: " / "))
        check(!card.contains("CaptureActions") && declarations.allSatisfy { !$0.contains("CaptureActions") },
              "settings: SettingsStatusCard, DaydreamSettingsOverview and DaydreamSettingsFrame take no CaptureActions (source)")
        let size = NSSize(width: DaydreamSettingsLayout.width, height: DaydreamSettingsLayout.maxHeight)
        for c in Case.allCases {
            closes = 0; selects = 0; acts = 0; learn = 0; advanced = 0
            let p = presentation(c)
            let status = SettingsStatusSnapshot(state: p.state, issue: p.issue, permissions: permissions(c),
                                                summaries: summaries, exclusions: exclusions)
            let view = DaydreamSettingsFrame(title: "Settings", advanced: { advanced += 1 }, close: { closes += 1 }) {
                DaydreamSettingsOverview(status: status, rows: SettingsRowsSnapshot(status), calendar: cal,
                                         select: { _ in selects += 1 }, act: { _ in acts += 1 }, learnMore: { learn += 1 })
            }
            let h = host(view, size: size)
            resize(h, [NSSize(width: 600, height: DaydreamSettingsLayout.minHeight), size])
            check(closes + selects + acts + learn + advanced == 0, "settings \(c.rawValue): the status card renders and resizes without calling anything",
                  "close \(closes) select \(selects) act \(acts) learn \(learn) advanced \(advanced)")
            window.makeFirstResponder(h)
            escape()
            if closes == 0 && c == .recording {
                limit("settings: SwiftUI's onExitCommand does not fire in an offscreen, inactive process (a probe with a focused control and "
                      + "onExitCommand does not fire either), so Esc is checked for calling nothing else; `.onExitCommand(perform: close)` "
                      + "is source-pinned by settings-0013-checks and Esc-closes-Settings stays an on-screen QA item")
            }
            check(closes <= 1 && selects + acts + learn + advanced == 0, "settings \(c.rawValue): Esc closes the frame at most once and calls nothing else",
                  "close \(closes) select \(selects) act \(acts) learn \(learn) advanced \(advanced)")
            let beforeReturn = closes
            let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                         isARepeat: false, keyCode: 36)!
            _ = window.performKeyEquivalent(with: enter)
            pump(0.1)
            check(closes == beforeReturn + 1 && selects + acts + learn + advanced == 0,
                  "settings \(c.rawValue): Return is Done (closes once) and does nothing else", "close \(closes - beforeReturn)")
        }
    }
    static func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
    /// The text of the top-level `struct name` declaration in `source`: from its line to the next top-level line.
    static func declaration(_ source: String, _ name: String) -> String {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { !$0.hasPrefix(" ") && ($0.contains("struct \(name):") || $0.contains("struct \(name)<")) })
        else { return "" }
        var end = start + 1
        while end < lines.count, lines[end].isEmpty || lines[end].hasPrefix(" ") || lines[end].hasPrefix("}") { end += 1 }
        return lines[start..<end].joined(separator: "\n")
    }

    // MARK: 6. ⌘P through MenuBarRecordingMenu

    static func pauseShortcut() {
        let shortcut = KeyboardShortcut("p", modifiers: .command)
        // The item model the menu draws.
        for c in Case.allCases {
            let p = presentation(c)
            let submenu = MenuBarRecordingMenu.items(state: p.state, canResume: p.canResume, canStop: p.canStop)[0]
            let first = submenu.children.first { $0.action == .pause(minutes: MenuBarRecordingMenu.shortcutMinutes) }
            let recording = p.state.kind == .recording
            check(submenu.title == "Pause for" && first?.title == "15 Minutes" && first?.enabled == recording && submenu.enabled == recording,
                  "⌘P row \(c.rawValue): `Pause for ▸ 15 Minutes` is " + (recording ? "enabled while Recording" : "disabled"),
                  "\(submenu)")
        }
        // The rows hosted in a window, with the app's shortcut attached. ⌘P now sits on a pull-down's child
        // (`Pause for ▸ 15 Minutes`), and a pull-down in a window does not answer key equivalents, so here ⌘P must
        // never do anything but a 15-minute pause while Recording, and nothing in any other state. The app hosts these
        // rows only in its native Recording menu; the positive control is that menu, below.
        let calls = SafetyCalls()
        func rows(_ c: Case) -> some View {
            VStack(alignment: .leading, spacing: 8) { MenuBarRecordingMenu(presentation: presentation(c), actions: calls.actions, pauseShortcut: shortcut) }
                .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        for c in Case.allCases {
            calls.reset()
            host(rows(c), size: NSSize(width: 320, height: 220))
            _ = window.performKeyEquivalent(with: commandP())
            pump(0.15)
            if c == .recording {
                check(calls.total == 0 || (calls.pauses == [15] && calls.total == 1),
                      "⌘P in the window while Recording does nothing but a 15-minute pause", calls.summary)
            } else {
                check(calls.total == 0, "⌘P in the window while \(c.rawValue) calls nothing", calls.summary)
            }
        }
        window.contentView = NSView()
        pump(0.1)
        // The native menu the app's Recording menu is.
        if #available(macOS 14.4, *) {
            for c in Case.allCases {
                calls.reset()
                let menu = NSHostingMenu(rootView: MenuBarRecordingMenu(presentation: presentation(c), actions: calls.actions, pauseShortcut: shortcut))
                menu.update()
                pump(0.1)
                guard let parent = menu.items.first(where: { $0.title == "Pause for" }),
                      let item = parent.submenu?.items.first(where: { $0.title == "15 Minutes" }) else {
                    check(false, "native ⌘P \(c.rawValue): the menu has `Pause for ▸ 15 Minutes`", menu.items.map(\.title).joined(separator: ", "))
                    continue
                }
                let recording = c == .recording
                check(item.keyEquivalent == "p" && item.keyEquivalentModifierMask == .command && (item.isEnabled && parent.isEnabled) == recording,
                      "native ⌘P \(c.rawValue): `Pause for ▸ 15 Minutes` carries ⌘P and is " + (recording ? "enabled" : "disabled"),
                      "key \(item.keyEquivalent) mask \(item.keyEquivalentModifierMask.rawValue) enabled \(item.isEnabled) parent \(parent.isEnabled)")
                _ = menu.performKeyEquivalent(with: commandP())
                pump(0.15)
                if recording {
                    check(calls.pauses == [15] && calls.total == 1, "native ⌘P while Recording pauses for exactly 15 minutes (positive control)", calls.summary)
                } else {
                    check(calls.total == 0, "native ⌘P while \(c.rawValue) calls nothing", calls.summary)
                }
            }
        } else {
            check(false, "native ⌘P positive control needs NSHostingMenu (macOS 14.4 or later)", ProcessInfo.processInfo.operatingSystemVersionString)
        }
    }
    // MARK: 7. ⌘P in the menu bar panel

    static func panelShortcut() {
        let calls = SafetyCalls()
        var other = 0
        for c in Case.allCases {
            calls.reset(); other = 0
            let p = presentation(c)
            let view = panel(c, calls, other: { other += 1 })
            let fit = NSHostingView(rootView: view.environment(\.daydreamNow, start).environment(\.daydreamStatic, true)).fittingSize
            host(view.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading), size: fit)
            _ = window.performKeyEquivalent(with: commandP())
            pump(0.15)
            switch p.state.kind {
            case .recording:
                check(calls.pauses == [15] && calls.total == 1 && other == 0, "panel ⌘P while Recording pauses for exactly 15 minutes (positive control)",
                      calls.summary + " other \(other)")
            case .paused where p.canResume:
                check(calls.resumes == 1 && calls.total == 1 && other == 0, "panel ⌘P while \(c.rawValue) resumes, once (Resume Now ⌘P)",
                      calls.summary + " other \(other)")
            default:
                check(calls.total == 0 && other == 0, "panel ⌘P while \(c.rawValue) calls nothing: it never starts recording", calls.summary + " other \(other)")
            }
        }
        window.contentView = NSView()
        pump(0.1)
    }

    // MARK: 8. The switch, as VoiceOver reads it

    /// The switch stays on through a pause (DayDream is on, taking a break), so what it says must be the state:
    /// "Recording" only while recording, "Paused" for every pause (timed, with any reason), "Off" while off.
    static func switchSpeech() {
        var presentations = Case.allCases.map { (c: $0.rawValue, p: presentation($0)) }
        for detail in RecordingCopy.pauseDetails {
            presentations.append((c: "paused: \(detail)", p: CapturePresentation(state: .paused(until: nil, since: start, reason: detail), canResume: true, canStop: true)))
        }
        presentations.append((c: "paused, no resume", p: CapturePresentation(state: .paused(until: nil, since: start, reason: nil), canResume: false, canStop: true)))
        for (name, p) in presentations {
            let h = MenuBarMenu.header(p, now: start, timeZone: la, canSetUp: true, canOpenApplications: true)
            guard case .toggle(let on, _) = h.control else {
                check(p.state.kind != .recording, "switch \(name): a button in the switch's place, never while Recording", "\(h.control)")
                continue
            }
            let value = MenuBarMenu.switchValue(on: on, tone: h.status.tone), hint = MenuBarMenu.switchHint(on: on, tone: h.status.tone)
            switch p.state.kind {
            case .recording:
                check(on && value == "Recording" && hint == "Turn off to stop recording", "switch \(name): VoiceOver reads Recording", "\(on) \(value) \(hint)")
            case .paused:
                check(value == "Paused" && hint == "Turn off to stop DayDream", "switch \(name): VoiceOver reads Paused, never Recording", "\(on) \(value) \(hint)")
            default:
                check(!on && value == "Off" && hint == "Turn on to start recording", "switch \(name): VoiceOver reads Off", "\(on) \(value) \(hint)")
            }
        }
        // The drawn switch carries exactly these words (source): SwiftUI exposes no accessibility tree offscreen.
        let menu = read("Sources/MemoryUI/MenuBarMenu.swift")
        check(menu.contains("control(h.control, tone: h.status.tone)") && menu.contains(".accessibilityLabel(\"DayDream\")")
              && menu.contains(".accessibilityValue(Self.switchValue(on: on, tone: tone))") && menu.contains(".accessibilityHint(Self.switchHint(on: on, tone: tone))"),
              "switch: the panel's Toggle speaks switchValue and switchHint for the header's tone (source)")
        limit("switch speech: offscreen, SwiftUI builds no accessibility tree for the hosted panel (the window has one empty group), "
              + "so the spoken value is checked from the words the Toggle is given and pinned from source; VoiceOver on the live panel stays an on-screen QA item")
    }
}
