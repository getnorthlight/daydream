// DD-RECIPE: APP
// The menu bar (plan §5 A4; the owner's option A "Native menu", Sep 2026): the panel (`MenuBarMenu`), the Recording
// menu rows (`MenuBarRecordingMenu`) and the app wiring in MenuBarContent.swift (`DaydreamMenuBarLabel`,
// `DaydreamMenuBarPanel`, `DaydreamMenuBarIsolatedPanel`), on macOS 13 and later:
//   A. pure models: the header (status line, the one switch or the one fix button, Pause or Resume Now) for every
//      state and blocker, the Pause submenu items, the rows, the today line, the Recording menu rows;
//   B. the hosted panel: 320 pt in every state (long copy wraps), the same rows in every state, heights, and
//      synthetic clicks and hovers that reach exactly the expected closures (the submenu delivers 5/15/30/120);
//   C. key equivalents: ⌘O, ⌘, and ⌘Q; ⌘P pauses 15 minutes while recording and resumes while paused, nothing else;
//   D. the label: template marks and VoiceOver labels for the four states, the "!" while setup is needed, the typing
//      badge kept on top;
//   E. a Development Trial model hosting `DaydreamMenuBarPanel`: actions route to the model and recorders, Quit
//      cancels a timed pause before it terminates, opening calls nothing;
//   F. macOS 14.4+: an NSHostingMenu of `MenuBarRecordingMenu` delivers 5/15/30/120;
//   G. source guarantees for the three files;
//   H. content fits (rendered pixels and measured text): nothing leaves the 320 pt panel, the status glyph shows the
//      state's colour, no count line is cut.
// The Development Trial store lives under DD_CHECK_OUT (run-checks.sh sets it); the check refuses to
// run without it. It never starts capture, opens an app or window, requests a permission or terminates:
// every route is a recorder, and the model's pause and stop are checked by source, never called.
import AppKit
import SwiftUI
import MemoryCore
import MemoryUI

@MainActor final class MenuBarRecorder {
    var events: [String] = []
    var dismisses = 0
    /// Pause submenus the panel presented (never popped up: the checks stand in for NSMenu.popUp).
    var submenus: [(menu: NSMenu, anchor: NSView, point: NSPoint)] = []
    var actions: CaptureActions {
        var a = CaptureActions(pause: { [unowned self] in self.events.append("pause:\($0)") },
                               resume: { [unowned self] in self.events.append("resume") },
                               stop: { [unowned self] in self.events.append("stop") },
                               settings: { [unowned self] in self.events.append("settings") })
        a.openSystemSettings = { [unowned self] in self.events.append("system:" + ($0?.rawValue ?? "privacy")) }
        a.checkPermissions = { [unowned self] in self.events.append("check") }
        a.openSettingsSection = { [unowned self] in self.events.append("section:" + $0) }
        a.openMain = { [unowned self] in self.events.append("main") }
        a.openRecall = { [unowned self] in self.events.append("recall") }
        a.quit = { [unowned self] in self.events.append("quit") }
        a.retryIssue = { [unowned self] in self.events.append("retry") }
        return a
    }
    var typingActions: TypingMenuActions {
        TypingMenuActions(pause: { [unowned self] in self.events.append("typing:pause") },
                          resume: { [unowned self] in self.events.append("typing:resume") },
                          openSettings: { [unowned self] in self.events.append("typing:settings") })
    }
    func today() { events.append("today") }
    func setUp() { events.append("setup") }
    func dismiss() { dismisses += 1 }
    func present(_ menu: NSMenu, _ anchor: NSView, _ point: NSPoint) { submenus.append((menu, anchor, point)) }
    func reset() { events = []; dismisses = 0; submenus = [] }
}

/// A panel whose presentation changes while it is on screen.
@MainActor final class MenuBarStateBox: ObservableObject {
    @Published var presentation: CapturePresentation?
    init(_ p: CapturePresentation?) { presentation = p }
}
struct MenuBarLivePanel: View {
    @ObservedObject var box: MenuBarStateBox
    let make: (CapturePresentation?) -> MenuBarMenu
    var body: some View { make(box.presentation).environment(\.daydreamStatic, false) }
}

@main @MainActor enum DDMenuBarChecks {
    static var failures = 0

    static func check(_ ok: Bool, _ name: String, _ got: @autoclosure () -> String = "") {
        if ok { print("PASS " + name) } else {
            failures += 1
            fflush(stdout)
            FileHandle.standardError.write(Data(("FAIL: " + name + (got().isEmpty ? "" : " (got: " + got() + ")") + "\n").utf8))
        }
    }
    static func equal<T: Equatable>(_ got: T, _ want: T, _ name: String) { check(got == want, name, "\(got)") }

    static let la = TimeZone(identifier: "America/Los_Angeles")!
    static var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = la; return c }
    static func date(_ h: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: h, minute: m))! }
    static let now = date(16, 21)
    static let width: CGFloat = 320

    // MARK: Values

    enum Case: String, CaseIterable {
        case recording, recordingIssue, recordingInputIssue, paused, pausedOpen, pausedNoResume, pausedLongReason, pausedUnknownReason
        case off, offBlocked, offLongBlocker
        case offMove, offTrial, offAnotherCopy, offWake, offStorage, offReplacement
        case permission, permissionBoth, isolated
    }
    static let longBlocker = "Your pause ended because something changed. Review the replacement in Settings before recording again."
    /// A pause reason no table knows: passed through whole, so it wraps (taller, never wider).
    static let unknownPause = "Resume canceled: an unexpected check failed while the storage was verified again."
    static func off(_ reason: String) -> CapturePresentation {
        CapturePresentation(state: .off(since: date(16, 19), reason: reason), canResume: false, canStop: false)
    }
    static func presentation(_ c: Case) -> CapturePresentation? {
        let perms = PermissionSnapshot(accessibility: true, inputMonitoring: false)
        switch c {
        case .recording: return CapturePresentation(state: .recording(since: date(8, 40)), canResume: true, canStop: true)
        case .recordingIssue:
            return CapturePresentation(state: .recording(since: date(8, 40)), issue: "Summary writer needs attention", canResume: true, canStop: true)
        case .recordingInputIssue:
            return CapturePresentation(state: .recording(since: date(8, 40)), issue: "Input capture needs attention", canResume: true, canStop: true)
        case .paused: return CapturePresentation(state: .paused(until: date(16, 36), since: date(16, 18), reason: nil), canResume: true, canStop: true)
        case .pausedOpen: return CapturePresentation(state: .paused(until: nil, since: date(16, 18), reason: nil), canResume: true, canStop: true)
        case .pausedNoResume:
            return CapturePresentation(state: .paused(until: date(16, 36), since: date(16, 18), reason: nil), canResume: false, canStop: true)
        case .pausedLongReason:
            return CapturePresentation(state: .paused(until: nil, since: date(16, 18),
                                                      reason: RecordingCopy.pauseReason("Resume canceled: prerequisites changed. Review Settings.")),
                                       canResume: true, canStop: true)
        case .pausedUnknownReason:
            return CapturePresentation(state: .paused(until: nil, since: date(16, 18), reason: RecordingCopy.pauseReason(unknownPause)),
                                       canResume: true, canStop: true)
        case .off: return CapturePresentation(state: .off(since: date(16, 19), reason: nil), canResume: true, canStop: false)
        case .offBlocked:
            return CapturePresentation(state: .off(since: date(16, 19), reason: RecordingCopy.blocker("Setup required")), issue: "Setup required",
                                       canResume: false, canStop: false)
        case .offLongBlocker: return off(longBlocker)
        case .offMove: return off(RecordingCopy.moveToApplications)
        case .offTrial: return off(RecordingCopy.developmentTrial)
        case .offAnotherCopy: return off(RecordingCopy.anotherCopy)
        case .offWake: return off(RecordingCopy.blocker("Resume after waking"))
        case .offStorage: return off(RecordingCopy.blocker("Storage unavailable"))
        case .offReplacement: return off(RecordingCopy.blocker("Replacement in progress"))
        case .permission:
            return CapturePresentation(state: .needsPermission(missing: [.inputMonitoring]), issue: RecordingCopy.permissionBlocker,
                                       canResume: false, canStop: false, permissions: perms)
        case .permissionBoth:
            return CapturePresentation(state: .needsPermission(missing: [.accessibility, .inputMonitoring]), canResume: false, canStop: false,
                                       permissions: PermissionSnapshot(accessibility: false, inputMonitoring: false))
        case .isolated: return nil
        }
    }

    static func moment(_ id: String, _ h0: Int, _ m0: Int, _ h1: Int, _ m1: Int, bundle: String, app: String, title: String,
                       pending: Bool = false) -> MomentSlice {
        let start = date(h0, m0), end = date(h1, m1)
        return MomentSlice(id: id, dayKey: "2026-09-22", start: start, end: end, title: title, subject: title,
                           firstBullet: pending ? nil : "Worked on it.", bullets: pending ? [] : [MomentBullet(text: "Worked on it.")],
                           apps: [app], primaryBundle: bundle, bundles: [bundle], sites: [], actionIDs: (0..<12).map { "\(id)-\($0)" },
                           actionCount: 12, clusters: [start...end],
                           summary: pending ? .pending : .ready(generatedAt: nil, local: true), hasCorrection: false, primaryApp: app)
    }
    static let moments: [MomentSlice] = [
        moment("m-mail", 8, 42, 8, 57, bundle: "com.apple.mail", app: "Mail", title: "Roadmap reply"),
        moment("m-zed", 9, 55, 11, 40, bundle: "dev.zed.Zed", app: "Zed", title: "PermissionSetup.swift"),
        moment("m-ghostty", 15, 26, 15, 52, bundle: "com.mitchellh.ghostty", app: "Ghostty", title: "Render harness"),
        moment("m-freeform", 16, 5, 16, 18, bundle: "com.apple.freeform", app: "Freeform", title: "Menu bar sketches", pending: true),
    ]
    static let fixtureApps = [AppTally(id: "dev.zed.Zed", bundle: "dev.zed.Zed", name: "Zed", moments: 3, actions: 148),
                              AppTally(id: "com.mitchellh.ghostty", bundle: "com.mitchellh.ghostty", name: "Ghostty", moments: 1, actions: 37),
                              AppTally(id: "com.apple.Notes", bundle: "com.apple.Notes", name: "Notes", moments: 2, actions: 29),
                              AppTally(id: "com.apple.mail", bundle: "com.apple.mail", name: "Mail", moments: 1, actions: 9)]
    static func snapshot(_ moments: [MomentSlice], momentCount: Int? = nil, partial: Bool = false, apps: [AppTally]? = nil) -> TodaySnapshot {
        let apps = apps ?? fixtureApps
        return TodaySnapshot(dayKey: "2026-09-22", loadedAt: now, momentCount: momentCount ?? moments.count, actionCount: 223, countComplete: !partial,
                             partial: partial, moments: moments, headline: nil, headlineBullets: [], headlineGeneratedAt: nil, headlineLocal: nil,
                             firstObserved: moments.first?.start, lastObserved: moments.last?.end, topApps: moments.isEmpty ? [] : apps,
                             latest: moments.last, summaries: SummaryAvailability(provider: .local, busy: false),
                             readyCount: moments.filter { $0.summary != .pending }.count, pendingCount: moments.filter { $0.summary == .pending }.count,
                             tooLongCount: 0, appCount: moments.isEmpty ? 0 : apps.count)
    }
    static let today = snapshot(moments)
    static let emptyToday = snapshot([])

    static func typingRows(_ s: TypingIndicatorState, shortcut: String? = TypingPauseShortcut.display) -> TypingMenuRows {
        TypingMenuRows(state: s, shortcut: shortcut, timeZone: la, locale: Locale(identifier: "en_US"))
    }

    static func panel(_ c: Case, recorder r: MenuBarRecorder, snapshot: TodaySnapshot? = today, onboardingComplete: Bool = true,
                      development: Bool = false, setUp: Bool = true, typing: TypingMenuRows? = nil, highlighted: String? = nil,
                      submenuOpen: Bool = false, applications: Bool = true, browserHistory: BrowserHistoryLine = .off,
                      permissions: Bool = false, pointer: (() -> MenuBarMenu.Pointer)? = nil) -> MenuBarMenu {
        var p = presentation(c)
        p?.browserHistory = browserHistory
        var actions = r.actions
        if applications { actions.openApplications = { [unowned r] in r.events.append("applications") } }
        return MenuBarMenu(presentation: p, actions: actions, snapshot: c == .isolated ? nil : snapshot,
                           onboardingComplete: onboardingComplete, development: development, now: now, calendar: cal,
                           openToday: { r.today() }, openSetUp: setUp ? { r.setUp() } : nil,
                           openPermissions: permissions ? { [unowned r] in r.events.append("permissions") } : nil,
                           typing: typing, typingActions: r.typingActions,
                           highlighted: highlighted, submenuOpen: submenuOpen,
                           presentSubmenu: { r.present($0, $1, $2) }, pointer: pointer, dismiss: { r.dismiss() })
    }
    static func header(_ c: Case, setUp: Bool = true, applications: Bool = true, permissions: Bool = false) -> MenuBarMenu.Header {
        MenuBarMenu.header(presentation(c), now: now, timeZone: la, canSetUp: setUp, canOpenApplications: applications,
                           canOpenPermissions: permissions)
    }

    // MARK: Hosting

    static let window: NSWindow = {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 360, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        w.acceptsMouseMovedEvents = true
        // fix/menubar-red: renders are in sRGB whatever display is attached. Unpinned, the backing store takes the main
        // display's profile (a monitor's ICC, or the headless virtual display's sRGB when the monitor is off), and the
        // colour checks below measured a different panel on each.
        w.colorSpace = .sRGB
        w.orderFrontRegardless()
        offscreen(w)
        return w
    }()
    /// Ordering a titled window front pulls it onto the screen, where the real pointer can rest on a row and draw it
    /// highlighted in an "at rest" panel. Move it back off the displays (these checks synthesize every hover).
    static func offscreen(_ w: NSWindow) { w.setFrameOrigin(NSPoint(x: -4000, y: -4000)) }
    static func pump(_ s: Double = 0.15) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    static var hoverEvents = 0

    /// Fitting size of `view` (width unconstrained): what `MenuBarExtra(.window)` sizes its panel to.
    static func fitting<V: View>(_ view: V) -> NSSize {
        let h = NSHostingView(rootView: view.environment(\.daydreamNow, now).environment(\.daydreamStatic, true))
        return h.fittingSize
    }

    /// Hosts `view` at its fitting size in the offscreen window.
    @discardableResult
    static func host<V: View>(_ view: V) -> NSHostingView<AnyView> {
        let size = fitting(view)
        // The panels' own dismissal (a row or Quit) orders the host window out: show it again.
        if !window.isVisible { window.orderFrontRegardless(); offscreen(window) }
        let h = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height, alignment: .topLeading)
            .onContinuousHover { _ in hoverEvents += 1 }
            .environment(\.daydreamNow, now).environment(\.daydreamStatic, true)))
        window.setContentSize(size)
        window.contentView = h
        h.frame = NSRect(origin: .zero, size: size)
        pump(); h.layoutSubtreeIfNeeded(); pump(0.05)
        return h
    }

    /// A mouse down and up at a window point. The up is queued first, so an AppKit control that tracks the mouse in
    /// its own loop (the switch) finds it instead of waiting for the window server.
    static func send(click p: NSPoint) {
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: type == .leftMouseDown ? 1 : 0)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
        // A SwiftUI control does not track: hand it the queued up directly (nothing else runs NSApp's queue).
        if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            window.sendEvent(queued)
        }
    }

    struct Hit { let point: NSPoint; let events: [String]; let dismissed: Int; let submenus: Int }

    /// Synthetic clicks on a grid over the whole view; each click's closure calls, dismissals and submenus.
    /// (SwiftUI publishes no accessibility tree to an offscreen process, so clicks stand in for presses.)
    static func sweep(_ view: NSView, _ r: MenuBarRecorder, step: CGFloat = 6) -> [Hit] {
        var hits: [Hit] = []
        let b = view.bounds
        var y = b.minY + 2
        while y < b.maxY {
            var x = b.minX + 2
            while x < b.maxX {
                let before = r.events.count, dismissed = r.dismisses, submenus = r.submenus.count
                send(click: view.convert(NSPoint(x: x, y: y), to: nil))
                // The submenu opens on the next turn of the run loop (the row draws highlighted first).
                RunLoop.main.run(until: Date())
                if r.events.count > before || r.dismisses > dismissed || r.submenus.count > submenus {
                    // Top-down, whatever the view's flipping, for ordering.
                    let top = view.isFlipped ? y : b.maxY - y
                    hits.append(Hit(point: NSPoint(x: x, y: top), events: Array(r.events[before...]), dismissed: r.dismisses - dismissed,
                                    submenus: r.submenus.count - submenus))
                }
                x += step
            }
            y += step
        }
        pump(0.05)
        return hits
    }

    static func trackingAreas(_ view: NSView) -> [(NSTrackingArea, NSResponder)] {
        view.trackingAreas.compactMap { t in (t.owner as? NSResponder).map { (t, $0) } } + view.subviews.flatMap(trackingAreas)
    }

    static func enterExit(_ view: NSView, _ type: NSEvent.EventType, _ p: NSPoint) {
        for (area, owner) in trackingAreas(view) {
            guard let e = NSEvent.enterExitEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 trackingNumber: unsafeBitCast(area, to: Int.self), userData: nil) else { continue }
            if type == .mouseEntered { owner.mouseEntered(with: e) } else { owner.mouseExited(with: e) }
        }
    }
    static func move(_ view: NSView, to p: NSPoint) {
        var owners: [NSResponder] = []
        for (_, o) in trackingAreas(view) where !owners.contains(where: { $0 === o }) { owners.append(o) }
        guard let e = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { return }
        for o in owners { o.mouseMoved(with: e) }
    }

    /// Hover across the whole view as AppKit delivers it (entered, moves, exited) to the tracking areas' owners.
    static func hoverSweep(_ view: NSView) -> (moves: Int, delivered: Int) {
        let before = hoverEvents
        var moves = 0
        let b = view.bounds
        var entered = false, last = NSPoint.zero
        var y = b.minY + 4
        while y < b.maxY {
            var x = b.minX + 4
            while x < b.maxX {
                let p = view.convert(NSPoint(x: x, y: y), to: nil)
                if !entered { enterExit(view, .mouseEntered, p); entered = true }
                move(view, to: p)
                moves += 1
                RunLoop.main.run(until: Date())
                last = p
                x += 20
            }
            y += 10
        }
        if entered { enterExit(view, .mouseExited, last) }
        pump(0.1)
        return (moves, hoverEvents - before)
    }

    /// Every view of `type` under `view`.
    static func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    // MARK: Main

    static func main() async throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
            FileHandle.standardError.write(Data("FAIL: dd-menubar-checks watchdog expired after 300s\n".utf8))
            exit(2)
        }
        // Codex's shared roots, spelled so run-checks.sh's rewrite of the literal prefix leaves them intact.
        let shared = ["/private/tmp/" + "day" + "dream-", "/tmp/" + "day" + "dream-"]
        guard let outPath = ProcessInfo.processInfo.environment["DD_CHECK_OUT"], outPath.hasPrefix("/"),
              !shared.contains(where: { outPath.hasPrefix($0) }) else {
            FileHandle.standardError.write(Data("FAIL: DD_CHECK_OUT is not a private output directory; run this check through run-checks.sh\n".utf8))
            exit(1)
        }
        print("BEGIN dd-menubar-checks on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        var clock = Date()
        func lap(_ name: String) { print("TIME \(name) \(String(format: "%.1f", Date().timeIntervalSince(clock))) s"); clock = Date() }
        models(); lap("models")
        panelSizes(); lap("sizes")
        panelClicks(); lap("clicks")
        keyEquivalents(); lap("keys")
        label(); lap("label")
        try await developmentPanel(shared: shared); lap("development")
        nativeMenu(); lap("native menu")
        colourReadsAreDisplayIndependent(); contentFits(); lap("content fits")
        sources()
        window.orderOut(nil)
        if failures > 0 {
            FileHandle.standardError.write(Data("FAIL: \(failures) menu bar check(s) failed\n".utf8))
            exit(1)
        }
        print("PASS dd-menubar-checks: all menu bar checks passed")
    }

    // MARK: A. Models

    static func models() {
        typealias Menu = MenuBarMenu
        // The rows, the same in every state.
        equal(Menu.rows(isolated: false, onboardingComplete: true, development: false).map(\.title),
              ["Search…", "Open DayDream", "DayDream Settings…", "Quit DayDream"], "rows are Search…, Open DayDream, DayDream Settings…, Quit DayDream")
        equal(Menu.rows(isolated: false, onboardingComplete: true, development: false).map { $0.keys ?? "" },
              ["", "⌘O", "⌘,", "⌘Q"], "row shortcuts are ⌘O, ⌘, and ⌘Q; Search… has none")
        equal(Menu.rows(isolated: false, onboardingComplete: false, development: false).map(\.title),
              ["Search…", "Open DayDream", "DayDream Settings…", "Set Up DayDream…", "Quit DayDream"],
              "Set Up DayDream… appears while onboarding is incomplete, before Quit")
        check(!Menu.rows(isolated: false, onboardingComplete: false, development: true).contains { $0.action == .setUp },
              "Set Up DayDream… never appears in the Development Trial")
        check(!Menu.rows(isolated: false, onboardingComplete: false, development: false, canSetUp: false).contains { $0.action == .setUp },
              "Set Up DayDream… needs a host that can open setup")
        check(!Menu.rows(isolated: false, onboardingComplete: false, development: false, headerOffersSetUp: true).contains { $0.action == .setUp },
              "Set Up DayDream… is not repeated while the header's button already opens setup")
        equal(Menu.rows(isolated: true, onboardingComplete: false, development: false).map(\.title), ["Quit DayDream"],
              "the isolated preview offers Quit DayDream only")
        // report-1004: Report a Problem… sits right above Quit, with no shortcut, when the host can open the email.
        equal(Menu.rows(isolated: false, onboardingComplete: true, development: false, canReport: true).map(\.title),
              ["Search…", "Open DayDream", "DayDream Settings…", "Report a Problem…", "Quit DayDream"], "Report a Problem… is the row above Quit")
        equal(Menu.rows(isolated: false, onboardingComplete: false, development: false, canReport: true).map(\.title),
              ["Search…", "Open DayDream", "DayDream Settings…", "Set Up DayDream…", "Report a Problem…", "Quit DayDream"],
              "Report a Problem… stays above Quit, after Set Up DayDream…")
        check(Menu.rows(isolated: false, onboardingComplete: true, development: false, canReport: true).first { $0.action == .reportProblem }?.keys == nil,
              "Report a Problem… has no shortcut")
        equal(Menu.rows(isolated: true, onboardingComplete: true, development: false, canReport: true).map(\.title), ["Quit DayDream"],
              "the isolated preview still offers Quit DayDream only")
        equal(Menu.isolatedLine, "Isolated preview · Recording is off", "isolated line copy")
        equal(Menu.width, 320, "the panel is 320 pt wide")

        // The header, state by state: the status line in plain words, the one switch (on while recording or paused,
        // off while stopped) or, when recording can't start, the one button that fixes it.
        typealias H = Menu.Header
        typealias S = Menu.Status
        func want(_ c: Case, _ tone: S.Tone, _ text: String, detail: String? = nil, _ control: Menu.Control, _ row: Menu.StateRow?,
                  attention: String? = nil, setUp: Bool = true, applications: Bool = true, permissions: Bool = false, _ name: String) {
            equal(header(c, setUp: setUp, applications: applications, permissions: permissions),
                  H(status: S(tone: tone, text: text, detail: detail), attention: attention, control: control, stateRow: row), name)
        }
        want(.recording, .recording, "Recording since 8:40 AM", .toggle(on: true, enabled: true), .pause(enabled: true),
             "Recording: red, Recording since 8:40 AM, the switch on, Pause ›")
        want(.recordingIssue, .recording, "Recording since 8:40 AM", .toggle(on: true, enabled: true), .pause(enabled: true),
             attention: "Couldn't update your history", "Recording with an issue: the state stays, the issue is a second orange line in plain words")
        want(.recordingInputIssue, .recording, "Recording since 8:40 AM", .toggle(on: true, enabled: true), .pause(enabled: true),
             attention: "Keyboard and mouse need attention", "the keyboard and mouse issue in fewer words, room for its chevron")
        want(.paused, .paused, "Paused · resumes 4:36 PM", .toggle(on: true, enabled: true), .resume(enabled: true),
             "Paused: indigo, Paused · resumes 4:36 PM, the switch on, Resume Now")
        want(.pausedOpen, .paused, "Paused until you resume", .toggle(on: true, enabled: true), .resume(enabled: true),
             "open-ended pause: Paused until you resume")
        want(.pausedNoResume, .paused, "Paused · resumes 4:36 PM", .toggle(on: true, enabled: true), .resume(enabled: false),
             "a pause that can't resume: Resume Now disabled, the switch still stops")
        want(.pausedLongReason, .paused, "Paused · something changed", detail: "Your pause ended because something changed. Review Settings.",
             .toggle(on: true, enabled: true), .resume(enabled: true),
             "a long pause reason: one line beside the switch, the whole sentence kept as its detail (tooltip, VoiceOver)")
        want(.pausedUnknownReason, .paused, String(unknownPause.dropLast()), .toggle(on: true, enabled: true), .resume(enabled: true),
             "a pause reason no table knows is kept whole (its final period dropped)")
        want(.off, .off, "Not recording", .toggle(on: false, enabled: true), .pause(enabled: false),
             "Off: grey, Not recording, the switch off, Pause disabled")
        want(.offBlocked, .attention, "Setup isn't finished", .fix(title: "Finish Setup…", fix: .setUp), .pause(enabled: false),
             "setup not finished: orange Setup isn't finished, Finish Setup… opens setup")
        want(.offBlocked, .attention, "Setup isn't finished", .fix(title: "Review…", fix: .settings("Setup")), .pause(enabled: false),
             setUp: false, "setup not finished without a setup window: Review… opens DayDream Settings (the overview)")
        want(.offLongBlocker, .attention, longBlocker, .fix(title: "Review…", fix: .settings("Setup")), .pause(enabled: false),
             "an unknown blocker: its words, kept whole, and Review…")
        want(.offMove, .attention, "Move to Applications first", .fix(title: "Open Applications", fix: .applications), .pause(enabled: false),
             "download window: Move to Applications first, Open Applications")
        want(.offMove, .attention, "Move to Applications first", .toggle(on: false, enabled: false), .pause(enabled: false),
             applications: false, "download window without a Finder route: the words and a disabled switch")
        want(.offTrial, .off, "Recording is off in this trial", .toggle(on: false, enabled: false), .pause(enabled: false),
             "Development Trial: grey, a disabled switch, no setup button")
        want(.offAnotherCopy, .attention, "DayDream is already open", .toggle(on: false, enabled: false),
             .pause(enabled: false), "another copy open: one short line that tells nobody to quit anything; nothing here can fix it (it clears itself)")
        want(.offWake, .off, "Resume after your Mac wakes", .toggle(on: false, enabled: false), .pause(enabled: false),
             "waiting for wake: grey, a disabled switch")
        want(.offStorage, .attention, "Storage needs attention", .fix(title: "Review…", fix: .settings("Setup")), .pause(enabled: false),
             "storage: Storage needs attention, Review…")
        want(.offReplacement, .attention, "Replacement needs review", .fix(title: "Review…", fix: .settings("Advanced")),
             .pause(enabled: false), "replacement: Replacement needs review, Review… opens Advanced (said once)")
        // perm-1004 (owner 10/3): the line names every missing permission and the button the one it turns on.
        want(.permission, .attention, "Input Monitoring is off", .fix(title: "Turn on Input Monitoring", fix: .setUp), .pause(enabled: false),
             "Needs Permission: orange Input Monitoring is off, Turn on Input Monitoring opens setup at the permissions step")
        want(.permission, .attention, "Input Monitoring is off", .fix(title: "Turn on Input Monitoring", fix: .systemSettings(.inputMonitoring)),
             .pause(enabled: false), setUp: false, "Needs Permission without a setup window: that pane of System Settings")
        want(.permissionBoth, .attention, "Accessibility and Input Monitoring are off", .fix(title: "Turn on Accessibility", fix: .setUp), .pause(enabled: false),
             "both permissions off: one line naming both, Accessibility first")
        want(.permissionBoth, .attention, "Accessibility and Input Monitoring are off", .fix(title: "Turn on Accessibility", fix: .systemSettings(.accessibility)),
             .pause(enabled: false), setUp: false, "both off without a setup window: Accessibility's pane first")
        // Setup finished: the button opens the DayDream permissions window (the drag cards), never setup again.
        want(.permission, .attention, "Input Monitoring is off", .fix(title: "Turn on Input Monitoring", fix: .permissions), .pause(enabled: false),
             permissions: true, "Needs Permission after setup: opens the DayDream permissions window")
        want(.permissionBoth, .attention, "Accessibility and Input Monitoring are off", .fix(title: "Turn on Accessibility", fix: .permissions), .pause(enabled: false),
             setUp: false, permissions: true, "both off after setup: the permissions window, not System Settings")
        want(.offBlocked, .attention, "Setup isn't finished", .fix(title: "Finish Setup…", fix: .setUp), .pause(enabled: false),
             permissions: true, "setup not finished: Finish Setup… still opens setup (the permissions window is only for a permission)")
        equal(header(.isolated), H(status: S(tone: .off, text: Menu.isolatedLine), attention: nil, control: .none, stateRow: nil),
              "isolated preview: its line, no switch, no Pause row")
        equal(Menu.header(CapturePresentation(state: .recording(since: nil), canResume: true, canStop: true), now: now, timeZone: la,
                          canSetUp: true, canOpenApplications: false).status.text, "Recording", "Recording without a start time: Recording")
        equal(Menu.header(CapturePresentation(state: .paused(until: date(16, 0), since: date(15, 45), reason: nil), canResume: true, canStop: true),
                          now: now, timeZone: la, canSetUp: true, canOpenApplications: false).status.text, "Paused",
              "a pause past its end time never names that time")
        equal(Menu.header(CapturePresentation(state: .recording(since: date(8, 40)), canResume: true, canStop: false), now: now, timeZone: la,
                          canSetUp: true, canOpenApplications: false).control, .toggle(on: true, enabled: false),
              "the switch can't turn off what can't stop")
        equal(Menu.header(CapturePresentation(state: .needsPermission(missing: []), canResume: false, canStop: false), now: now, timeZone: la,
                          canSetUp: true, canOpenApplications: false).status.text, "A permission is off", "an unknown permission gap: A permission is off")
        equal(Menu.header(CapturePresentation(state: .paused(until: nil, since: nil, reason: RecordingCopy.pauseReason("Paused for screen lock. Resumes after unlock.")),
                                              canResume: true, canStop: true), now: now, timeZone: la, canSetUp: true, canOpenApplications: false).status.text,
              "Paused while your screen was locked", "a one-sentence pause reason drops its period")
        // A failed save while DayDream tries again by itself: Paused, one calm line in the menu's words (the sentence
        // kept as its detail), the switch on, Resume Now live (it tries at once), and no orange line.
        for (core, words) in [("Storage write failed. Retrying automatically.", "Paused · trying to save again"),
                              ("Storage keeps failing. Retrying every minute.", "Paused · can't save right now"),
                              ("Storage full. Retrying automatically.", "Paused · Mac is out of space"),
                              ("Storage health check failed. Resume explicitly.", "Paused · couldn't save")] {
            let reason = RecordingCopy.pauseReason(core)
            let saving = Menu.header(CapturePresentation(state: .paused(until: nil, since: nil, reason: reason), canResume: true, canStop: true),
                                     now: now, timeZone: la, canSetUp: true, canOpenApplications: false)
            equal(saving, H(status: S(tone: .paused, text: words, detail: reason), attention: nil, control: .toggle(on: true, enabled: true),
                            stateRow: .resume(enabled: true)), "a failed save: \(words), the switch on, Resume Now, no orange line")
            check(!saving.needsSetup, "a failed save draws no \"!\" on the menu bar icon: \(words)")
        }
        // Beside a lock, sleep or user-switch pause, the reason Start refused after the unlock still shows: it is the
        // only line that says why nothing resumes. (A stop notice is never the issue: the app model keeps it to the
        // notification, which recording-model-checks pins.)
        let refused = "Finish history operation before recording"
        for lockLine in ["Paused while your screen was locked.", "Paused while your Mac slept.", "Paused while you switched users.", RecordingCopy.notResumed] {
            let locked = CapturePresentation(state: .paused(until: nil, since: nil, reason: lockLine), issue: refused, canResume: true, canStop: true)
            equal(Menu.header(locked, now: now, timeZone: la, canSetUp: true, canOpenApplications: false).attention, refused,
                  "the reason Start refused shows beside \"\(lockLine)\"")
        }
        // Once recording won't start again by itself, the pause says so in the menu's words, and Resume Now tries.
        let notResumed = Menu.header(CapturePresentation(state: .paused(until: nil, since: nil, reason: RecordingCopy.notResumed), canResume: true, canStop: true),
                                     now: now, timeZone: la, canSetUp: true, canOpenApplications: false)
        equal(notResumed, H(status: S(tone: .paused, text: "Paused · didn't resume on its own", detail: RecordingCopy.notResumed), attention: nil,
                            control: .toggle(on: true, enabled: true), stateRow: .resume(enabled: true)),
              "a start that won't come: \"Paused · didn't resume on its own\", the switch on, Resume Now")
        // The recording state is never hidden: the switch is on exactly while recording or paused, the red dot exactly
        // while recording, Pause is live exactly while recording and Resume Now exactly while paused.
        for c in Case.allCases where c != .isolated {
            let h = header(c), kind = presentation(c)!.state.kind
            let on: Bool? = { if case .toggle(let on, _) = h.control { return on }; return nil }()
            check(on == nil || on == (kind == .recording || kind == .paused), "\(c.rawValue): the switch is on exactly while recording or paused")
            check(h.control != .none, "\(c.rawValue): the header always has its switch or its fix button")
            check((h.status.tone == .recording) == (kind == .recording), "\(c.rawValue): the red dot exactly while recording")
            check((h.status.tone == .paused) == (kind == .paused), "\(c.rawValue): the indigo pause exactly while paused")
            check((h.stateRow == .pause(enabled: true)) == (kind == .recording), "\(c.rawValue): Pause is live exactly while recording")
            if case .resume = h.stateRow { check(kind == .paused, "\(c.rawValue): Resume Now only while paused") }
            if case .fix = h.control { check(h.status.tone == .attention, "\(c.rawValue): a fix button comes with orange words") }
            // The menu bar icon's "!" follows the orange status line exactly, with or without a button that fixes it.
            check(h.needsSetup == (h.status.tone == .attention), "\(c.rawValue): the \"!\" exactly while the status is orange")
            // The switch's spoken value is the state: never Recording while paused or off.
            if case .toggle(let on, _) = h.control {
                let value = Menu.switchValue(on: on, tone: h.status.tone)
                equal(value, kind == .recording ? "Recording" : kind == .paused ? "Paused" : "Off", "\(c.rawValue): VoiceOver reads the switch as \(value)")
                check(kind == .paused ? Menu.switchHint(on: on, tone: h.status.tone) == "Turn off to stop DayDream" : true,
                      "\(c.rawValue): the paused switch's hint says it stops DayDream")
            }
        }
        // Every pause reason and blocker the app can show: its menu words fit one line beside the switch or button
        // (the hosted heights below confirm it on the real view); a shortened line keeps its whole sentence as the detail.
        for detail in RecordingCopy.pauseDetails {
            let h = Menu.header(CapturePresentation(state: .paused(until: nil, since: nil, reason: detail), canResume: true, canStop: true),
                                now: now, timeZone: la, canSetUp: true, canOpenApplications: true)
            check(h.status.tone == .paused && (h.status.text == Menu.sentence(detail) ? h.status.detail == nil : h.status.detail == detail),
                  "pause reason \(detail): \(h.status.text)")
        }
        for detail in RecordingCopy.blockerDetails where detail != RecordingCopy.developmentTrial {
            let h = Menu.header(off(detail), now: now, timeZone: la, canSetUp: true, canOpenApplications: true)
            // Waiting for a wake, or for an import or backup to end (test 5): nothing to fix, so grey, no "!" and no button.
            let waits = detail == RecordingCopy.blocker("Resume after waking") || detail == RecordingCopy.operationRunning
            check(h.status.tone == .attention || waits, "blocker \(detail): \(h.status.text), orange unless it waits for wake or an import")
        }
        let importing = Menu.header(off(RecordingCopy.operationRunning), now: now, timeZone: la, canSetUp: true, canOpenApplications: true)
        check(importing.status.tone == .off && !importing.needsSetup && importing.status.text == "Import or backup running",
              "an import or backup running: grey \"Import or backup running\", no \"!\" (it ends by itself)")
        if case .fix = importing.control { check(false, "an import or backup running offers no fix button") }
        check(presentation(.recordingIssue)?.attentionLine(now: now, timeZone: la) == "Couldn't update your history",
              "the attention line is the presentation's mapped issue")
        check(presentation(.permission)?.attentionLine(now: now, timeZone: la) == nil && presentation(.offBlocked)?.attentionLine(now: now, timeZone: la) == nil,
              "the permission gap or the blocker itself adds no attention line")
        for fix in [Menu.Fix.setUp, .permissions, .systemSettings(.inputMonitoring), .applications, .settings("Setup")] {
            check(!Menu.fixHint(fix).isEmpty, "the fix button explains itself to VoiceOver (\(fix))")
        }
        equal(Menu.fixHint(.setUp), "Opens DayDream setup at the step that's missing", "Allow… and Finish Setup… say where they go")
        equal(Menu.fixHint(.permissions), "Opens DayDream permissions, where you allow what's missing", "Allow… after setup says where it goes")
        // The orange attention line is one click to where it is dealt with.
        equal(RecordingCopy.issue("Input capture needs attention"), "Keyboard and mouse recording needs attention", "the keyboard and mouse issue's words")
        for words in ["Keyboard and mouse recording needs attention", "Keyboard and mouse need attention"] {
            equal(Menu.attentionSection(words), "General", "keyboard and mouse (\(words)): the overview, whose status line holds the fix")
        }
        // gold/r2-copy-checks: the history upkeep and a failed deletion end in Try Again (Summaries can't fix the upkeep).
        equal(Menu.attentionAction(RecordingCopy.issue("Summary writer needs attention")), .retry, "the summary writer: Try Again")
        equal(Menu.attentionAction(RecordingCopy.issue("Deletion failed")), .retry, "a failed deletion: Try Again")
        equal(Menu.attentionAction(Menu.historySetAsideLine), .open("Backup"), "history set aside: Backup and restore")
        equal(Menu.attentionAction("Keyboard and mouse need attention"), .open("General"), "anything else opens its page")
        equal(Menu.attentionSection("Memory read failed"), "General", "anything else: the overview, never Advanced")

        // The Pause submenu's place: right of the panel, or left when the right edge of the screen is too close.
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let leftIcon = CGRect(x: 200, y: 700, width: 320, height: 24), rightIcon = CGRect(x: 1180, y: 700, width: 320, height: 24)
        equal(Menu.submenuSide(row: leftIcon, menuWidth: 260, visible: screen), .right, "icon at the left of the menu bar: the submenu opens right")
        equal(Menu.submenuSide(row: rightIcon, menuWidth: 260, visible: screen), .left, "icon at the right of the menu bar: the submenu flips left")
        equal(Menu.submenuSide(row: CGRect(x: 940, y: 700, width: 320, height: 24), menuWidth: 260, visible: screen), .left,
              "past x≈940 on a 1512 pt screen there is no room on the right")
        equal(Menu.submenuSide(row: rightIcon, menuWidth: 260, visible: nil), .right, "no screen known: right")
        let local = CGRect(x: 0, y: 0, width: 320, height: 24)
        equal(Menu.submenuPoint(side: .right, row: local, menuWidth: 260, flipped: false), CGPoint(x: 316, y: 29), "right: 4 pt over the panel's edge")
        equal(Menu.submenuPoint(side: .left, row: local, menuWidth: 260, flipped: false), CGPoint(x: -256, y: 29), "left: 4 pt over the other edge")
        equal(Menu.submenuPoint(side: .left, row: local, menuWidth: 260, flipped: true), CGPoint(x: -256, y: -5), "flipped rows: 5 pt above")
        let flippedFrame = Menu.submenuFrame(topLeft: CGPoint(x: rightIcon.minX + 4 - 260, y: rightIcon.maxY + 5), size: CGSize(width: 260, height: 150),
                                             visible: screen)
        check(!flippedFrame.intersects(rightIcon.insetBy(dx: 5, dy: 0)) && flippedFrame.maxX <= rightIcon.minX + 4,
              "flipped left, the submenu never covers the panel's rows", "\(flippedFrame)")
        let clamped = Menu.submenuFrame(topLeft: CGPoint(x: rightIcon.maxX - 4, y: rightIcon.maxY + 5), size: CGSize(width: 260, height: 150), visible: screen)
        check(clamped.maxX == screen.maxX && clamped.intersects(rightIcon), "the frame AppKit would keep on screen covers the panel (why it flips)")
        // Resting on the submenu, or on one of its items drawn over the panel, never closes it; resting on another row does.
        let panel = CGRect(x: 1180, y: 500, width: 320, height: 250), otherRow = CGPoint(x: 1300, y: 600)
        check(Menu.pointerIsAway(otherRow, panel: panel, row: rightIcon, menu: flippedFrame, onItem: false), "resting on another row counts")
        check(!Menu.pointerIsAway(otherRow, panel: panel, row: rightIcon, menu: clamped, onItem: false), "on the submenu (even over the panel) it doesn't")
        check(!Menu.pointerIsAway(otherRow, panel: panel, row: rightIcon, menu: .zero, onItem: true), "on a submenu item it doesn't")
        check(!Menu.pointerIsAway(CGPoint(x: rightIcon.midX, y: rightIcon.midY), panel: panel, row: rightIcon, menu: .zero, onItem: false), "on the Pause row it doesn't")
        check(!Menu.pointerIsAway(CGPoint(x: 10, y: 10), panel: panel, row: rightIcon, menu: .zero, onItem: false), "off the panel it doesn't")
        // A click on the Pause row that ends the menu's tracking shows it again; Esc, a choice or a click elsewhere don't.
        let onRow = CGPoint(x: rightIcon.midX, y: rightIcon.midY)
        check(Menu.clickReopens(.init(location: onRow, leftButtonDown: true), row: rightIcon), "a click on Pause keeps its submenu open")
        check(!Menu.clickReopens(.init(location: onRow, leftButtonDown: false), row: rightIcon), "Esc with the pointer on Pause closes it")
        check(!Menu.clickReopens(.init(location: otherRow, leftButtonDown: true), row: rightIcon), "a click on another row closes it")

        // The Pause submenu.
        typealias Item = Menu.PauseItem
        let plain = Menu.pauseItems(typing: nil)
        equal(plain.map(\.title), ["For 5 Minutes", "For 15 Minutes", "For 30 Minutes", "For 2 Hours"], "Pause › For 5, 15, 30 Minutes, 2 Hours")
        equal(plain.map(\.action), [.pause(minutes: 5), .pause(minutes: 15), .pause(minutes: 30), .pause(minutes: 120)],
              "the submenu pauses 5, 15, 30 and 120 minutes")
        equal(plain.map { $0.keys ?? "" }, ["", "⌘P", "", ""], "⌘P is drawn beside For 15 Minutes only")
        check(plain.allSatisfy { !$0.separatorBefore }, "no separator among the lengths")
        equal(Menu.pauseKeys, "⌘P", "⌘P glyphs")
        equal(Menu.pauseKeyMinutes, 15, "⌘P pauses for 15 minutes")
        let typingOn = Menu.pauseItems(typing: typingRows(.recording(app: "Notes")))
        equal(typingOn.last, Item(title: "Pause Typing for 10 Minutes", keys: "⌃⌥⌘T", action: .typing(.pause), separatorBefore: true),
              "typing on: Pause Typing for 10 Minutes ⌃⌥⌘T after a separator")
        equal(Menu.pauseItems(typing: typingRows(.notHere)).last?.action, .typing(.pause), "typing on elsewhere: typing can still be paused")
        equal(Menu.pauseItems(typing: typingRows(.recording(app: "Notes"), shortcut: nil)).last?.keys, nil,
              "no shortcut is drawn while none is registered")
        equal(Menu.pauseItems(typing: typingRows(.snoozed(until: date(16, 31)))), plain,
              "typing paused: Pause › only pauses (Resume is on the typing line)")
        for s in [TypingIndicatorState.off, .locked(.notAccepted)] {
            equal(Menu.pauseItems(typing: typingRows(s)).count, 4, "typing \(s): no typing item")
        }

        // The today line.
        equal(Menu.todayLine(today), "4 moments remembered today", "today line: 4 moments remembered today")
        equal(Menu.todayLine(snapshot(Array(moments.prefix(1)))), "1 moment remembered today", "today line: 1 moment")
        equal(Menu.todayLine(snapshot(moments, momentCount: 24, partial: true)), "24+ moments remembered today", "today line: a partial day says 24+")
        equal(Menu.todayLine(emptyToday), "Nothing recorded yet today", "today line: an empty day")
        equal(Menu.todayApps(today).map(\.name), ["Zed", "Ghostty", "Notes"], "today line: up to three app icons, the day's top apps")
        let mystery = AppTally(id: "m", bundle: nil, name: "Mystery", moments: 2, actions: 12)
        equal(Menu.todayApps(snapshot(moments, apps: [mystery] + fixtureApps)).map(\.name), ["Zed", "Ghostty", "Notes"],
              "today line: an app without a bundle draws no icon")
        let unresolved = AppTally(id: "u", bundle: "com.example.mystery", name: "com.example.mystery", moments: 2, actions: 12, nameResolved: false)
        equal(SettingsStatusCardModel.Usage.displayName(unresolved), "Unknown app", "today line: VoiceOver never reads a bundle ID as a name")

        // Chrome pages: the line exactly while the presentation has one (pages being saved, or access off), never dropped:
        // it is the only live notice that Chrome pages are saved. One click opens Settings ▸ Apps to remember.
        for (line, want) in [(BrowserHistoryLine.off, nil), (.on, "Browser history on (Google Chrome)"),
                             (.needsAccess, "Browser history on, but Chrome access is off"),
                             (.paused, "Browser history paused: Chrome not verified"),
                             (.twoCopies, "Browser history paused: two Chromes open")] as [(BrowserHistoryLine, String?)] {
            var p = presentation(.recording)!
            p.browserHistory = line
            equal(Menu.chromeLine(p), want, "the Chrome line (\(line)): \(want ?? "none")")
        }
        equal(Menu.chromeLine(nil), nil, "no Chrome line in the isolated preview")
        equal(DaydreamSettingsPage(section: Menu.chromeSection), .apps, "the Chrome line opens Apps to remember")
        equal(Menu.permissionLine([.accessibility]), "Accessibility is off", "permission line: Accessibility is off")

        // Recording menu rows (the app's Recording menu, copy deck §8.8): unchanged by the panel.
        typealias RMenu = MenuBarRecordingMenu
        let recording = RMenu.items(state: .recording(since: date(8, 40)), canResume: true, canStop: true)
        // ux/declutter: one Pause for ▸ submenu (15 minutes was offered twice); its 15 Minutes carries the host's ⌘P.
        equal(recording.map(\.title), ["Pause for", "Start Recording", "Stop Recording"], "Recording menu titles while Recording")
        equal(recording[0].children.map(\.title), ["5 Minutes", "15 Minutes", "30 Minutes", "2 Hours"], "Pause for submenu titles")
        equal(recording[0].children.compactMap { if case .pause(let m)? = $0.action { return m }; return nil }, [5, 15, 30, 120],
              "Pause for submenu delivers 5, 15, 30 and 120 minutes")
        equal(recording[0].children[1].action, .pause(minutes: RMenu.shortcutMinutes), "the ⌘P row (15 Minutes) pauses 15 minutes")
        check(recording[0].enabled && recording[0].children.allSatisfy(\.enabled), "pause rows are enabled while Recording")
        check(!recording[1].enabled, "Start Recording is disabled while Recording")
        let paused = RMenu.items(state: .paused(until: date(16, 36), since: date(16, 18), reason: nil), canResume: true, canStop: true)
        equal(paused[1].title, "Resume Recording", "the start row reads Resume Recording while Paused")
        check(paused[1].enabled && paused[1].action == .resume, "Resume Recording is enabled when paused and resumable")
        check(!paused[0].enabled && paused[0].children.allSatisfy { !$0.enabled }, "pause rows are disabled while Paused")
        let pausedBlocked = RMenu.items(state: .paused(until: nil, since: nil, reason: nil), canResume: false, canStop: true)
        check(!pausedBlocked[1].enabled, "Resume Recording is disabled when the pause can't resume")
        let offRows = RMenu.items(state: .off(since: nil, reason: nil), canResume: true, canStop: false)
        check(offRows[1].title == "Start Recording" && offRows[1].enabled && offRows[1].action == .start, "Start Recording is enabled when Off and startable")
        check(!offRows[2].enabled, "Stop Recording follows canStop")
        let offBlocked = RMenu.items(state: .off(since: nil, reason: "Finish setup to start recording."), canResume: false, canStop: false)
        check(!offBlocked[1].enabled, "Start Recording is disabled when a blocker stops it")
        let permission = RMenu.items(state: .needsPermission(missing: [.inputMonitoring]), canResume: true, canStop: false)
        check(!permission[1].enabled && permission.allSatisfy { !$0.enabled }, "Needs Permission disables every Recording row")
        // G65 (test 5): nothing to stop in Off or Needs Permission, whatever the model's canStop says.
        check(!RMenu.items(state: .off(since: nil, reason: nil), canResume: true, canStop: true)[2].enabled
              && !RMenu.items(state: .needsPermission(missing: [.accessibility]), canResume: false, canStop: true)[2].enabled
              && RMenu.items(state: .paused(until: nil, since: nil, reason: nil), canResume: true, canStop: true)[2].enabled
              && recording[2].enabled,
              "G65: Stop Recording is enabled only while Recording or Paused")

        // One prominent control per state (Recording has none: Stop is never blue), for the surfaces that still draw them.
        let states: [RecordingState] = [.recording(since: nil), .paused(until: nil, since: nil, reason: nil), .off(since: nil, reason: nil),
                                        .needsPermission(missing: [.inputMonitoring])]
        for s in states {
            let prominent = RecordingControls.buttons(for: s, style: .menu).filter(\.prominent)
            equal(prominent.count, s.primaryAction == nil ? 0 : 1, "\(s.kind.title): one prominent control at most (\(s.primaryAction == nil ? "none" : "one"))")
        }
    }

    // MARK: B. Sizes

    static func panelSizes() {
        let r = MenuBarRecorder()
        var sizes: [Case: NSSize] = [:]
        for c in Case.allCases {
            let size = fitting(panel(c, recorder: r))
            sizes[c] = size
            print("SIZE \(c.rawValue) \(Int(size.width))x\(Int(size.height.rounded()))")
        }
        equal(Set(sizes.values.map(\.width)), [width], "the panel is 320 pt wide in every state, isolated included")
        for (label, snap) in [("empty today", emptyToday), ("no snapshot", nil as TodaySnapshot?)] {
            equal(fitting(panel(.recording, recorder: r, snapshot: snap)).width, width, "the panel is 320 pt wide with \(label)")
        }
        equal(fitting(panel(.off, recorder: r, onboardingComplete: false)).width, width, "the panel is 320 pt wide with Set Up DayDream…")
        func h(_ c: Case) -> CGFloat { sizes[c]?.height ?? .infinity }
        // A plain menu: the old card was about 480 pt Recording; this is the header, five rows and the today line.
        for c in Case.allCases where c != .isolated {
            check(h(c) <= 300, "\(c.rawValue): the panel is at most 300 pt tall", "\(h(c))")
        }
        check(h(.isolated) <= 90, "isolated: the status line and Quit", "\(h(.isolated))")
        // Nothing jumps: the same rows in every state, so the one-line states are the same height; a longer line
        // beside a button wraps to a second line (taller, never wider).
        for c in [Case.paused, .pausedOpen, .pausedNoResume, .pausedLongReason, .off, .offBlocked, .offTrial, .offWake, .offStorage, .permission,
                  .permissionBoth, .offMove, .offReplacement, .offAnotherCopy] {
            check(abs(h(c) - h(.recording)) <= 1, "\(c.rawValue): the same height as Recording (the same rows, one status line)", "\(h(c)) vs \(h(.recording))")
        }
        // Every pause reason and every blocker the app can show keeps the status on one line (the header never grows).
        for detail in RecordingCopy.pauseDetails {
            let p = CapturePresentation(state: .paused(until: nil, since: nil, reason: detail), canResume: true, canStop: true)
            let size = fitting(MenuBarMenu(presentation: p, actions: r.actions, snapshot: today, now: now, calendar: cal))
            check(size.width == width && abs(size.height - h(.pausedOpen)) <= 1, "pause reason on one line: \(MenuBarMenu.header(p, now: now, timeZone: la, canSetUp: true, canOpenApplications: true).status.text)",
                  "\(size) vs \(h(.pausedOpen))")
        }
        for detail in RecordingCopy.blockerDetails {
            for applications in [true, false] {
                var actions = r.actions
                if applications { actions.openApplications = {} }
                let p = off(detail)
                let size = fitting(MenuBarMenu(presentation: p, actions: actions, snapshot: today, now: now, calendar: cal, openSetUp: {}))
                check(size.width == width && abs(size.height - h(.offBlocked)) <= 1,
                      "blocker on one line\(applications ? "" : " (no Finder route)"): \(MenuBarMenu.header(p, now: now, timeZone: la, canSetUp: true, canOpenApplications: applications).status.text)",
                      "\(size) vs \(h(.offBlocked))")
            }
        }
        check(h(.offLongBlocker) > h(.offBlocked) + 10, "an unknown long blocker wraps (taller, never wider)", "\(h(.offLongBlocker)) vs \(h(.offBlocked))")
        check(h(.pausedUnknownReason) > h(.pausedOpen) + 10, "an unknown long pause reason wraps (taller, never wider)",
              "\(h(.pausedUnknownReason)) vs \(h(.pausedOpen))")
        for c in [Case.recordingIssue, .recordingInputIssue] {
            check(h(c) > h(.recording) + 10 && h(c) <= h(.recording) + 20, "\(c.rawValue): the operational issue adds one orange attention line",
                  "\(h(c)) vs \(h(.recording))")
        }
        // The typing line: under the status, only while typing is on.
        for (name, s) in [("recording", TypingIndicatorState.recording(app: "Notes")), ("not here", .notHere), ("paused", .snoozed(until: date(16, 31))),
                          ("locked", .locked(.notAccepted))] {
            let size = fitting(panel(.recording, recorder: r, typing: typingRows(s)))
            print("SIZE typing-\(name) \(Int(size.width))x\(Int(size.height.rounded()))")
            check(size.width == width && size.height > h(.recording) + 10 && size.height <= h(.recording) + 20,
                  "typing \(name): one quiet line under the status", "\(size) vs \(h(.recording))")
        }
        equal(fitting(panel(.recording, recorder: r, typing: typingRows(.off))).height, h(.recording), "typing off: no typing line")
        // Chrome pages: one quiet line while pages are saved, and while they would be but access is off; none otherwise.
        for line in [BrowserHistoryLine.on, .needsAccess, .paused, .twoCopies] {
            let size = fitting(panel(.recording, recorder: r, browserHistory: line))
            print("SIZE recording-\(line) \(Int(size.width))x\(Int(size.height.rounded()))")
            check(size.width == width && size.height > h(.recording) + 10 && size.height <= h(.recording) + 20,
                  "browser history line (\(line)): one short line under the status", "\(size) vs \(h(.recording))")
        }
        equal(fitting(panel(.recording, recorder: r, browserHistory: .off)).height, h(.recording), "browser history line: .off draws nothing")
        // BrowserHistoryLine itself.
        equal(BrowserHistoryLine.off.text, nil, "browser history line: off has no text")
        equal(BrowserHistoryLine.on.text, "Browser history on (Google Chrome)", "browser history line: on copy")
        equal(BrowserHistoryLine.make(recording: false, pagesOn: true, access: .allowed), .off, "browser history line: hidden when not recording")
        equal(BrowserHistoryLine.make(recording: true, pagesOn: false, access: .allowed), .off, "browser history line: hidden with Web pages in Chrome off")
        equal(BrowserHistoryLine.make(recording: true, pagesOn: true, access: .allowed), .on, "browser history line: on with access allowed")
        for a in [ChromeAccessState.denied, .notAsked] {
            equal(BrowserHistoryLine.make(recording: true, pagesOn: true, access: a), .needsAccess, "browser history line: access off (\(a)) says so")
        }
        for a in [ChromeAccessState.unknown, .checking, .chromeNotRunning] {
            equal(BrowserHistoryLine.make(recording: true, pagesOn: true, access: a), .on, "browser history line: \(a) is not called access off")
        }
        // Review G30: a Chrome that can't be verified saves nothing: the line says it is paused.
        equal(BrowserHistoryLine.make(recording: true, pagesOn: true, access: .unverified), .paused, "browser history line: an unverified Chrome is paused, never on")
        equal(BrowserHistoryLine.paused.text, "Browser history paused: Chrome not verified", "browser history line: paused copy")
        equal(BrowserHistoryLine.needsAccess.text, "Browser history on, but Chrome access is off", "browser history line: access-off copy")
        equal(BrowserHistoryLine.symbol, "globe", "browser history line: globe symbol")
        let menuText = (try? String(contentsOfFile: "Sources/MemoryUI/MenuBarMenu.swift", encoding: .utf8)) ?? ""
        check(menuText.contains("public static func chromeLine(_ p: CapturePresentation?) -> String? { p?.browserHistory.text }"),
              "browser history line: drawn exactly from the presentation's line")
        let modelText = (try? String(contentsOfFile: "Sources/MacMemApp/MacMemApp.swift", encoding: .utf8)) ?? ""
        check(modelText.contains("BrowserHistoryLine.make(recording:recording,pagesOn:browserPagesSaved,access:chromeAccessShown,chromeExcluded:chromeExcluded)")
              && modelText.contains("var chromeExcluded:Bool {savedPrivacy.blockedApps.contains(ChromePageTarget.bundleID)}"),
              "browser history line: the app computes it from the saved switch, the recording state and whether Google Chrome is excluded")
        let noToday = fitting(panel(.recording, recorder: r, snapshot: nil)).height
        check(noToday < h(.recording) - 20, "a nil snapshot hides the today line", "\(noToday) vs \(h(.recording))")
        equal(fitting(panel(.recording, recorder: r, snapshot: emptyToday)).height, h(.recording), "an empty day keeps the line: Nothing recorded yet today")
        let setUpRow = fitting(panel(.off, recorder: r, onboardingComplete: false)).height
        check(setUpRow > h(.off) + 20, "Set Up DayDream… adds one row", "\(setUpRow) vs \(h(.off))")
        check(r.events.isEmpty && r.dismisses == 0 && r.submenus.isEmpty, "measuring the panel calls no action and opens no submenu", "\(r.events)")
    }

    // MARK: B. Clicks and hovers

    static func panelClicks() {
        let r = MenuBarRecorder()
        struct Expect {
            let c: Case; var setUp = true
            let submenu: Bool; let resume: Bool; let stop: Bool
            var fix: String? = nil
            /// The orange attention line's one click (a Settings section).
            var line: String? = nil
            var permissions = false
        }
        let expectations = [
            Expect(c: .recording, submenu: true, resume: false, stop: true),
            Expect(c: .recordingIssue, submenu: true, resume: false, stop: true, line: "retry"),
            Expect(c: .recordingInputIssue, submenu: true, resume: false, stop: true, line: "section:General"),
            Expect(c: .paused, submenu: false, resume: true, stop: true),
            Expect(c: .pausedNoResume, submenu: false, resume: false, stop: true),
            Expect(c: .off, submenu: false, resume: true, stop: false),
            Expect(c: .offBlocked, submenu: false, resume: false, stop: false, fix: "setup"),
            Expect(c: .offBlocked, setUp: false, submenu: false, resume: false, stop: false, fix: "section:Setup"),
            Expect(c: .offMove, submenu: false, resume: false, stop: false, fix: "applications"),
            Expect(c: .offTrial, submenu: false, resume: false, stop: false),
            Expect(c: .offAnotherCopy, submenu: false, resume: false, stop: false),
            Expect(c: .offStorage, submenu: false, resume: false, stop: false, fix: "section:Setup"),
            Expect(c: .permission, submenu: false, resume: false, stop: false, fix: "setup"),
            Expect(c: .permission, setUp: false, submenu: false, resume: false, stop: false, fix: "system:inputMonitoring"),
            Expect(c: .permissionBoth, setUp: false, submenu: false, resume: false, stop: false, fix: "system:privacy"),
            Expect(c: .permission, submenu: false, resume: false, stop: false, fix: "permissions", permissions: true),
            Expect(c: .permissionBoth, setUp: false, submenu: false, resume: false, stop: false, fix: "permissions", permissions: true),
        ]
        let rows: Set<String> = ["recall", "main", "settings", "quit", "today"]
        var switchTried = 0
        for e in expectations {
            r.reset()
            let tag = e.c.rawValue + (e.setUp ? "" : " (no setup window)") + (e.permissions ? " (setup finished)" : "")
            let h = host(panel(e.c, recorder: r, setUp: e.setUp, permissions: e.permissions))
            // The one switch is the real system switch, drawn in the header's state.
            let switches = views(NSSwitch.self, in: h)
            if case .toggle(let on, let enabled) = header(e.c, setUp: e.setUp, permissions: e.permissions).control {
                check(switches.count == 1 && switches[0].state == (on ? .on : .off) && switches[0].isEnabled == enabled,
                      "\(tag): one system switch, \(on ? "on" : "off")\(enabled ? "" : ", disabled")",
                      "\(switches.map { "\($0.state.rawValue) \($0.isEnabled)" })")
                switchTried += switches.count
            } else {
                check(switches.isEmpty, "\(tag): the fix button stands in the switch's place (no switch)", "\(switches.count)")
            }
            let hover = hoverSweep(h)
            check(hover.moves > 50 && hover.delivered > 50, "\(tag): the hover sweep reaches SwiftUI", "\(hover)")
            check(r.events.isEmpty && r.dismisses == 0, "\(tag): opening and \(hover.moves) hover moves call no action", "\(r.events)")
            if e.submenu {
                check(r.submenus.allSatisfy { $0.menu.title == "Pause" }, "\(tag): hovering opens only the Pause submenu")
            } else {
                check(r.submenus.isEmpty, "\(tag): hovering opens no submenu (Pause is disabled)", "\(r.submenus.count)")
            }
            r.reset()
            let hits = sweep(h, r)
            check(hits.allSatisfy { $0.events.count <= 1 }, "\(tag): no click calls more than one action",
                  "\(hits.filter { $0.events.count > 1 }.map(\.events))")
            let events = Set(hits.flatMap(\.events))
            check(!events.contains { $0.hasPrefix("pause:") }, "\(tag): no click pauses directly (lengths live in the submenu)")
            check(hits.contains { $0.submenus > 0 } == e.submenu, "\(tag): Pause › \(e.submenu ? "opens its submenu" : "is disabled")")
            check(events.contains("resume") == e.resume, "\(tag): \(e.resume ? "the switch or Resume Now starts recording" : "nothing resumes or starts")")
            check(events.contains("stop") == e.stop, "\(tag): the switch \(e.stop ? "stops" : "can't stop") recording")
            let fixes = events.filter { ($0 == "setup" || $0 == "applications" || $0 == "permissions" || $0.hasPrefix("section:") || $0.hasPrefix("system:"))
                && $0 != e.line }
            equal(fixes, e.fix.map { [$0] } ?? [], "\(tag): the fix button \(e.fix.map { "runs " + $0 } ?? "is absent")")
            check(e.line.map { events.contains($0) } ?? true, "\(tag): the attention line \(e.line.map { "opens " + $0 } ?? "is absent")")
            check(!events.contains("check") && !events.contains { $0.hasPrefix("typing:") }, "\(tag): nothing else is clickable")
            // The switch keeps the panel open (it is a setting); every row and the fix button close it after their action.
            let switchHits = hits.filter { $0.events.contains("stop") || ($0.events.contains("resume") && $0.point.y < 40) }
            check(switchHits.allSatisfy { $0.dismissed == 0 }, "\(tag): the switch keeps the panel open")
            let rowHits = hits.filter { $0.events.contains { rows.contains($0) || fixes.contains($0) || $0 == e.line } || ($0.events.contains("resume") && $0.point.y >= 40) }
            check(!rowHits.isEmpty && rowHits.allSatisfy { $0.dismissed == 1 }, "\(tag): every row and the fix button dismiss after their action")
            check(hits.allSatisfy { !$0.events.isEmpty || $0.dismissed == 0 }, "\(tag): nothing dismisses without an action")
            check(hits.filter { $0.submenus > 0 }.allSatisfy { $0.events.isEmpty && $0.dismissed == 0 }, "\(tag): opening the submenu calls nothing")
            check(rows.isSubset(of: events), "\(tag): Search…, Open DayDream, DayDream Settings…, Quit DayDream and the today line are clickable",
                  "\(events.intersection(rows).sorted())")
            check(!events.contains("setup") || e.fix == "setup", "\(tag): Set Up DayDream… is hidden once onboarding is complete")
            // Top to bottom: the header, then Pause / Resume Now, then the today line, then the rows.
            let y = { (ev: String) in hits.filter { $0.events.contains(ev) }.map(\.point.y).min() ?? -1 }
            let pauseY = hits.filter { $0.submenus > 0 }.map(\.point.y).min()
            let resumeRowY = hits.filter { $0.events.contains("resume") && $0.point.y >= 40 }.map(\.point.y).min()
            if let stateY = pauseY ?? resumeRowY {
                check(stateY < y("today") && y("today") < y("recall") && y("recall") < y("main") && y("main") < y("settings") && y("settings") < y("quit"),
                      "\(tag): the order is header, \(pauseY != nil ? "Pause" : "Resume Now"), today, Search…, Open DayDream, Settings…, Quit")
            }
            if let s = hits.first(where: { $0.events.contains("stop") || ($0.events.contains("resume") && $0.point.y < 40) }) {
                check(s.point.x > width - 60 && s.point.y < 40, "\(tag): the switch sits at the right of the header", "\(s.point)")
            }
            if let fix = e.fix, let f = hits.first(where: { $0.events.contains(fix) }) {
                check(f.point.x > width / 2 && f.point.y < 40, "\(tag): the fix button sits where the switch would", "\(f.point)")
            }
            // The submenu: a real NSMenu beside the Pause row, each length pausing once and closing the panel.
            if e.submenu {
                guard let shown = r.submenus.last else { check(false, "\(tag): the submenu was presented"); continue }
                let items = shown.menu.items
                equal(items.map(\.title), ["For 5 Minutes", "For 15 Minutes", "For 30 Minutes", "For 2 Hours"], "\(tag): the submenu's items")
                equal(items.map(\.keyEquivalent), ["", "p", "", ""], "\(tag): the submenu's For 15 Minutes carries ⌘P")
                check(items[1].keyEquivalentModifierMask == [.command], "\(tag): ⌘P is Command-P", "\(items[1].keyEquivalentModifierMask)")
                check(items.allSatisfy(\.isEnabled), "\(tag): every length is enabled")
                // Where it opens: the anchor's right edge, overlapping the panel by 4 pt, its top 5 pt above the row.
                let inPanel = h.convert(shown.point, from: shown.anchor)
                let row = h.convert(shown.anchor.bounds, from: shown.anchor)
                check(abs(inPanel.x - (width - 4)) <= 1 && row.width >= width - 1, "\(tag): the submenu opens at the panel's right edge",
                      "\(inPanel) in \(row)")
                r.reset()
                for i in items.indices { shown.menu.performActionForItem(at: i) }
                pump(0.05)
                equal(r.events, ["pause:5", "pause:15", "pause:30", "pause:120"], "\(tag): the submenu delivers 5, 15, 30 and 120 minutes")
                equal(r.dismisses, 4, "\(tag): each length closes the panel after it pauses")
                // Hover opens it, as a submenu does: rest on the Pause row.
                if let py = pauseY {
                    r.reset()
                    let p = h.convert(NSPoint(x: 60, y: h.isFlipped ? py : h.bounds.maxY - py), to: nil)
                    enterExit(h, .mouseEntered, p); move(h, to: p)
                    pump(0.35)
                    check(r.submenus.count == 1 && r.events.isEmpty, "\(tag): resting on Pause opens its submenu once, calling nothing",
                          "\(r.submenus.count) \(r.events)")
                    enterExit(h, .mouseExited, p); pump(0.05)
                }
            }
        }
        check(switchTried == 8, "the switch was found in every switch state", "\(switchTried)")

        // One panel value hosted twice (a sizing pass, then the panel): each hosting keeps its own Pause submenu. The
        // sizing copy drawing its rows after the panel is up (as when app icons land off the main thread) must not move
        // the submenu's anchor out of the panel's window (fix/pause-menu: a shared `@State` submenu did).
        do {
            let r2 = MenuBarRecorder()
            let value = panel(.recording, recorder: r2)
            let sizing = NSHostingView(rootView: AnyView(value.environment(\.daydreamNow, now).environment(\.daydreamStatic, true)))
            let size = sizing.fittingSize
            let h = host(value)
            sizing.frame = NSRect(origin: .zero, size: size)
            sizing.layoutSubtreeIfNeeded(); sizing.display(); pump(0.05)
            let hits = sweep(h, r2)
            check(hits.contains { $0.submenus > 0 } && r2.submenus.last.map { $0.anchor.window === window } == true,
                  "one panel hosted twice: Pause › still opens beside the panel after the other copy draws",
                  "\(hits.filter { $0.submenus > 0 }.count) \(r2.submenus.map { String(describing: $0.anchor.window) })")
            withExtendedLifetime(sizing) {}
        }

        // The panel against the right edge of the screen (the menu bar icon at the right of the menu bar): Pause ›
        // opens its submenu to the left of the panel, 4 pt over its edge, so no item is drawn over the panel's rows.
        if let screen = NSScreen.main?.visibleFrame {
            r.reset()
            let h = host(panel(.recording, recorder: r))
            let saved = window.frame
            // Level with the screen's right edge, far below every display: nothing is drawn where anyone can see.
            window.setFrameOrigin(NSPoint(x: screen.maxX - window.frame.width, y: -6000))
            pump(0.1)
            let hits = sweep(h, r)
            if let shown = r.submenus.last {
                let inPanel = h.convert(shown.point, from: shown.anchor)
                check(abs(inPanel.x - (4 - shown.menu.size.width)) <= 1, "icon at the right: the submenu opens left of the panel",
                      "\(inPanel) width \(shown.menu.size.width)")
            } else { check(false, "icon at the right: the submenu was presented", "\(hits.count) hits") }
            window.setFrameOrigin(saved.origin)
            pump(0.05)
        } else { print("LIMIT: no screen; the submenu's side is checked through MenuBarMenu.submenuSide") }

        // A click on Pause while its submenu is open keeps it open: the pop-up ends on that click (the button still
        // down on the row), so the panel shows it again, once; nothing runs. Closing any other way never shows it again.
        r.reset()
        let quietHits = sweep(host(panel(.recording, recorder: r, pointer: { .init(location: .zero, leftButtonDown: false) })), r)
        check(!r.submenus.isEmpty && r.submenus.count == Set(r.submenus.map { ObjectIdentifier($0.menu) }).count,
              "closing without a click on Pause (Esc, a choice, a click elsewhere) never shows it again", "\(r.submenus.count)")
        if let py = quietHits.first(where: { $0.submenus > 0 })?.point.y {
            r.reset()
            var reads = 0
            let clickHost = host(panel(.recording, recorder: r, pointer: { [unowned r] in
                reads += 1
                guard reads == 1, let a = r.submenus.last?.anchor, let w = a.window else { return .init(location: .zero, leftButtonDown: false) }
                let row = w.convertToScreen(a.convert(a.bounds, to: nil))
                return .init(location: CGPoint(x: row.midX, y: row.midY), leftButtonDown: true)
            }))
            send(click: clickHost.convert(NSPoint(x: 60, y: clickHost.isFlipped ? py + 2 : clickHost.bounds.maxY - py - 2), to: nil))
            pump(0.1)
            check(r.submenus.count == 2 && r.submenus[0].menu === r.submenus[1].menu && r.events.isEmpty && r.dismisses == 0,
                  "a click on Pause that ends its submenu's tracking shows the same submenu again, once, calling nothing",
                  "\(r.submenus.count) \(r.events)")
        } else { check(false, "the Pause row was found for the click-to-keep-open check") }

        // The typing item: in the submenu while typing is on; it pauses typing only and closes the panel.
        r.reset()
        let typingHost = host(panel(.recording, recorder: r, typing: typingRows(.recording(app: "Notes"))))
        let typingHits = sweep(typingHost, r)
        check(!typingHits.flatMap(\.events).contains { $0.hasPrefix("typing:") }, "typing on: the typing line itself is not a button")
        if let shown = r.submenus.last {
            let items = shown.menu.items
            equal(items.map { $0.isSeparatorItem ? "—" : $0.title },
                  ["For 5 Minutes", "For 15 Minutes", "For 30 Minutes", "For 2 Hours", "—", "Pause Typing for 10 Minutes"],
                  "typing on: the submenu ends with Pause Typing for 10 Minutes after a separator")
            check(items.last?.keyEquivalent == "t" && items.last?.keyEquivalentModifierMask == [.control, .option, .command],
                  "typing on: Pause Typing shows ⌃⌥⌘T")
            r.reset()
            shown.menu.performActionForItem(at: items.count - 1)
            pump(0.05)
            check(r.events == ["typing:pause"] && r.dismisses == 1, "Pause Typing pauses typing only, then closes the panel", "\(r.events)")
        } else { check(false, "typing on: the submenu was presented") }
        // Locked typing: the line opens Settings, where typing is turned on.
        r.reset()
        let lockedEvents = sweep(host(panel(.recording, recorder: r, typing: typingRows(.locked(.notAccepted)))), r).filter { $0.events.contains("typing:settings") }
        check(!lockedEvents.isEmpty && lockedEvents.allSatisfy { $0.dismissed == 1 }, "typing locked: the line opens Settings and closes the panel")
        // Paused typing: the line itself resumes typing (it ends in Resume), one click, then closes the panel; Pause ›
        // only pauses.
        for until in [date(16, 31), nil] as [Date?] {
            r.reset()
            let snoozedHits = sweep(host(panel(.recording, recorder: r, typing: typingRows(.snoozed(until: until)))), r)
            let resumes = snoozedHits.filter { $0.events.contains("typing:resume") }
            check(!resumes.isEmpty && resumes.allSatisfy { $0.dismissed == 1 && $0.events == ["typing:resume"] } && resumes.allSatisfy { $0.point.y < 60 },
                  "typing paused\(until == nil ? " (no end time)" : ""): the typing line resumes typing and closes the panel",
                  "\(resumes.map(\.point))")
            check(!Set(snoozedHits.flatMap(\.events)).contains("typing:pause"), "typing paused: nothing pauses typing again")
            if let shown = r.submenus.last {
                equal(shown.menu.items.map(\.title), ["For 5 Minutes", "For 15 Minutes", "For 30 Minutes", "For 2 Hours"],
                      "typing paused: Pause › only pauses recording")
            } else { check(false, "typing paused: the submenu was presented") }
        }
        // The Chrome pages line: one click opens Settings ▸ Apps to remember, where the switch is.
        for line in [BrowserHistoryLine.on, .needsAccess, .paused, .twoCopies] {
            r.reset()
            let chromeHits = sweep(host(panel(.recording, recorder: r, browserHistory: line)), r).filter { $0.events.contains("section:Recording") }
            check(!chromeHits.isEmpty && chromeHits.allSatisfy { $0.dismissed == 1 && $0.events == ["section:Recording"] && $0.point.y < 60 },
                  "browser history line (\(line)): one click opens Apps to remember and closes the panel")
        }

        // Set Up DayDream…: onboarding incomplete, outside the Development Trial.
        r.reset()
        var events = Set(sweep(host(panel(.off, recorder: r, onboardingComplete: false)), r, step: 8).flatMap(\.events))
        check(events.contains("setup"), "Set Up DayDream… is clickable while onboarding is incomplete")
        r.reset()
        events = Set(sweep(host(panel(.off, recorder: r, onboardingComplete: false, development: true)), r, step: 8).flatMap(\.events))
        check(!events.contains("setup"), "Set Up DayDream… is absent in the Development Trial")

        // Isolated preview: Quit only.
        r.reset()
        let isolatedHits = sweep(host(panel(.isolated, recorder: r)), r, step: 4)
        equal(Set(isolatedHits.flatMap(\.events)), ["quit"], "isolated: Quit DayDream is the only action")

        // Without a host route, the today line opens DayDream.
        r.reset()
        let plain = MenuBarMenu(presentation: presentation(.recording), actions: r.actions, snapshot: today, now: now, calendar: cal,
                                presentSubmenu: { r.present($0, $1, $2) })
        events = Set(sweep(host(plain), r, step: 8).flatMap(\.events))
        check(!events.contains("today") && events.contains("main"), "without openToday the today line opens DayDream")

        // Recording → Paused while the panel is on screen: Resume Now replaces Pause, the switch stays on.
        let box = MenuBarStateBox(presentation(.recording))
        let live = MenuBarLivePanel(box: box) { p in
            MenuBarMenu(presentation: p, actions: r.actions, snapshot: today, now: now, calendar: cal, openToday: { r.today() },
                        presentSubmenu: { r.present($0, $1, $2) }, dismiss: { r.dismiss() })
        }
        let liveHost = host(live)
        box.presentation = presentation(.paused)
        pump(0.5)
        r.reset()
        let liveHits = sweep(liveHost, r, step: 6)
        let liveEvents = liveHits.flatMap(\.events)
        check(liveEvents.contains("resume") && liveEvents.contains("stop") && r.submenus.isEmpty && !liveEvents.contains { $0.hasPrefix("pause:") },
              "after Recording → Paused on screen, the panel offers Resume Now and the switch, no Pause", "\(Set(liveEvents).sorted())")
        check(views(NSSwitch.self, in: liveHost).first?.state == .on, "after Recording → Paused the switch stays on")
    }

    // MARK: C. Key equivalents

    static func keyEquivalents() {
        let r = MenuBarRecorder()
        func press(_ h: NSView, _ chars: String, _ code: UInt16) -> [String] {
            r.reset()
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: code) else { return ["no event"] }
            _ = window.performKeyEquivalent(with: e) || h.performKeyEquivalent(with: e)
            pump(0.05)
            return r.events
        }
        let rec = host(panel(.recording, recorder: r))
        equal(press(rec, "o", 31), ["main"], "⌘O opens DayDream from the panel")
        equal(press(rec, ",", 43), ["settings"], "⌘, opens DayDream Settings from the panel")
        equal(press(rec, "q", 12), ["quit"], "⌘Q quits from the panel")
        equal(press(rec, "p", 35), ["pause:15"], "⌘P while recording pauses for 15 minutes (For 15 Minutes ⌘P)")
        equal(r.dismisses, 1, "⌘P closes the panel after it pauses")
        check(r.submenus.isEmpty, "⌘P pauses without opening the submenu")
        equal(press(rec, "k", 40), [], "the panel installs no ⌘K")
        let paused = host(panel(.paused, recorder: r))
        equal(press(paused, "p", 35), ["resume"], "⌘P while paused resumes (Resume Now ⌘P)")
        let pausedNoResume = host(panel(.pausedNoResume, recorder: r))
        equal(press(pausedNoResume, "p", 35), [], "⌘P does nothing while the pause can't resume")
        for c in [Case.off, .offBlocked, .permission, .offTrial] {
            let h = host(panel(c, recorder: r))
            equal(press(h, "p", 35), [], "⌘P does nothing in \(c.rawValue) (it never starts recording)")
        }
        let isolated = host(panel(.isolated, recorder: r))
        equal(press(isolated, "q", 12), ["quit"], "isolated: ⌘Q quits")
        equal(press(isolated, "o", 31), [], "isolated: no ⌘O")
        equal(press(isolated, "p", 35), [], "isolated: no ⌘P")
    }

    // MARK: D. Label

    static func label() {
        let states: [(RecordingState, String)] = [
            (.recording(since: date(8, 40)), "DayDream: Recording"),
            (.paused(until: date(16, 36), since: date(16, 18), reason: nil), "DayDream: Paused until 4:36 PM"),
            (.off(since: nil, reason: nil), "DayDream: Off"),
            (.needsPermission(missing: [.inputMonitoring]), "DayDream: Turn on Input Monitoring"),   // perm-1004
        ]
        for (state, want) in states {
            let label = DaydreamMenuBarLabelImage(state: state, now: now, timeZone: la)
            equal(label.label, want, "\(state.kind.title): the menu bar label reads \(want)")
            equal(label.drawnState, state.kind, "\(state.kind.title): the label draws its state's mark")
            let image = DaydreamMenuBarMark.image(for: state.kind)
            check(image.isTemplate && image.size == NSSize(width: 18, height: 18), "\(state.kind.title): the label image is an 18 pt template")
            check(image.representations.count == 2, "\(state.kind.title): the label image carries 1x and 2x bitmaps")
        }
        // Four different marks: the state is readable from the icon alone.
        let bits = DaydreamCaptureState.allCases.map { s in DaydreamMenuBarMark.bitmap(s, scale: 2).flatMap { $0.tiffRepresentation } }
        check(Set(bits.compactMap { $0 }).count == 4, "the four states draw four different marks")
        // Setup needed: the "!" mark, and the label says what's missing.
        let setup = DaydreamMenuBarLabelImage(state: .off(since: nil, reason: RecordingCopy.blocker("Setup required")), now: now, timeZone: la,
                                              setup: "Setup isn't finished")
        check(setup.drawnState == .needsPermission && setup.label == "DayDream: Off. Setup isn't finished",
              "Off until setup is done: the \"!\" mark, DayDream: Off. Setup isn't finished", setup.label)
        let perm = DaydreamMenuBarLabelImage(state: .needsPermission(missing: [.inputMonitoring]), now: now, timeZone: la, setup: "Input Monitoring is off")
        check(perm.drawnState == .needsPermission && perm.label == "DayDream: Turn on Input Monitoring. Input Monitoring is off",
              "Needs Permission: the \"!\" mark and the missing permission in the label", perm.label)
        for state in [RecordingState.recording(since: date(8, 40)), .paused(until: nil, since: nil, reason: nil)] {
            let l = DaydreamMenuBarLabelImage(state: state, now: now, timeZone: la, setup: "Setup isn't finished")
            check(l.drawnState == state.kind && !l.label.contains("Setup"), "\(state.kind.title): a setup line never changes a live state's mark")
        }
        // The typing badge stays on top, whatever the mark: the "!" state keeps the dot or the ring.
        let dotted = DaydreamMenuBarLabelImage(state: .off(since: nil, reason: nil), now: now, timeZone: la, typing: .recording(app: "Notes"),
                                               setup: "Setup isn't finished")
        check(dotted.badge == .dot && dotted.label.hasSuffix("DayDream is recording what you type"),
              "the setup \"!\" never drops the typing dot or its words", dotted.label)
        let g = DaydreamMarkGeometry.standard, c = g.badgeCenter
        func alpha(_ rep: NSBitmapImageRep?, _ p: CGPoint, _ scale: CGFloat) -> CGFloat {
            rep?.colorAt(x: Int(p.x * scale), y: Int(p.y * scale))?.alphaComponent ?? 0
        }
        // The "!"'s own dot, left of the badge's clear gap (the part a crescent would keep).
        let bangDotLeft = CGPoint(x: g.bangDotCenter.x - 1, y: g.bangDotCenter.y)
        let stem = CGPoint(x: g.bangDotCenter.x, y: g.back.minY + 4)
        for scale in [1, 2] as [CGFloat] {
            let plain = DaydreamMenuBarMark.bitmap(.needsPermission, scale: scale)
            check(alpha(plain, bangDotLeft, scale) > 0.5 && alpha(plain, stem, scale) > 0.9, "the \"!\" mark alone has its stem and its dot at \(Int(scale))x")
            for badge in [DaydreamTypingBadge.dot, .ring] {
                let rep = DaydreamMenuBarMark.bitmap(.needsPermission, badge: badge, scale: scale)
                if badge == .dot { check(alpha(rep, c, scale) > 0.9, "the \"!\" mark with the typing dot draws the dot whole at \(Int(scale))x") }
                else {
                    check(max(alpha(rep, CGPoint(x: c.x - 1.6, y: c.y), scale), alpha(rep, CGPoint(x: c.x - 1.4, y: c.y), scale)) > 0.5
                          && alpha(rep, c, scale) < 0.1, "the \"!\" mark with the typing ring draws the ring whole at \(Int(scale))x")
                }
                check(alpha(rep, stem, scale) > 0.9, "the \"!\" keeps its stem under the typing \(badge.rawValue) at \(Int(scale))x")
                check(alpha(rep, bangDotLeft, scale) < 0.1, "under the typing \(badge.rawValue) the \"!\" drops its own dot: no crescent at \(Int(scale))x")
            }
        }
        // Another copy open: the status is orange with no button, and the icon still draws the "!" and names it.
        let copyHeader = header(.offAnotherCopy)
        let copy = DaydreamMenuBarLabelImage(state: presentation(.offAnotherCopy)!.state, now: now, timeZone: la,
                                             setup: copyHeader.needsSetup ? copyHeader.status.text : nil)
        check(copy.drawnState == .needsPermission && copy.label == "DayDream: Off. DayDream is already open",
              "another copy open: the \"!\" mark and its words in the label", copy.label)
        let move = header(.offMove, applications: false)
        check(move.needsSetup && DaydreamMenuBarLabelImage(state: presentation(.offMove)!.state, now: now, timeZone: la, setup: move.status.text).drawnState == .needsPermission,
              "Move to Applications without a Finder route: still the \"!\"")
        // Every orange status draws the "!" with those words in the label; no other status does.
        for c in Case.allCases where c != .isolated {
            let h = header(c), state = presentation(c)!.state
            let l = DaydreamMenuBarLabelImage(state: state, now: now, timeZone: la, setup: h.needsSetup ? h.status.text : nil)
            if h.status.tone == .attention {
                check(l.drawnState == .needsPermission && l.label.hasSuffix(h.status.text), "\(c.rawValue): orange status, \"!\" mark and its words", l.label)
            } else {
                check(l.drawnState == state.kind, "\(c.rawValue): no orange status, the state's own mark", "\(l.drawnState)")
            }
        }
        let isolated = DaydreamMenuBarIsolatedLabel().body as? DaydreamMenuBarLabelImage
        check(isolated?.drawnState == .off && isolated?.label == "DayDream: Off", "the isolated preview's label is the Off mark, DayDream: Off",
              "\(String(describing: isolated?.label))")
        let pausedOpen = DaydreamMenuBarLabelImage(state: .paused(until: nil, since: nil, reason: nil), now: now, timeZone: la)
        equal(pausedOpen.label, "DayDream: Paused", "an open-ended pause reads DayDream: Paused")
        let size = fitting(DaydreamMenuBarLabelImage(state: .recording(since: nil), now: now, timeZone: la))
        check(size == NSSize(width: 18, height: 18), "the label is the 18 × 18 pt mark, no title", "\(size)")
    }

    // MARK: E. Development Trial panel

    @MainActor final class RouteRecorder {
        var windows: [String] = [], activations = 0, urls: [String] = [], terminations = 0, reports = 0
        var pauseClearedAtTermination: Bool?
        var total: Int { windows.count + activations + urls.count + terminations + reports }
        func routes(_ model: MemoryViewModel) -> DaydreamMenuBarRoutes {
            DaydreamMenuBarRoutes(openWindow: { [unowned self] in self.windows.append($0) }, activate: { [unowned self] in self.activations += 1 },
                                  openURL: { [unowned self] in self.urls.append($0.absoluteString) },
                                  terminate: { [unowned self, unowned model] in
                                      self.terminations += 1
                                      self.pauseClearedAtTermination = model.pauseUntil == nil
                                  },
                                  reportProblem: { [unowned self] _ in self.reports += 1 })
        }
    }

    static func developmentPanel(shared: [String]) async throws {
        let root = URL(fileURLWithPath: "/private/tmp/daydream-development-trial-" + UUID().uuidString)
        check(!shared.contains(where: { root.path.hasPrefix($0) }), "development root is redirected to the private checks tree", root.path)
        guard !shared.contains(where: { root.path.hasPrefix($0) }) else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for name in ["memory", "preferences", "backups"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        try Data("synthetic-only\n".utf8).write(to: root.appendingPathComponent("DEVELOPMENT-ONLY"))
        setenv("DAYDREAM_DEVELOPMENT_ROOT", root.path, 1)
        setenv("MAC_MEM_HOME", root.appendingPathComponent("memory").path, 1)
        setenv("CFFIXED_USER_HOME", root.appendingPathComponent("preferences").path, 1)
        let trial = try DevelopmentTrial.validate()
        try trial.prepare()
        let model = MemoryViewModel(development: trial)
        for _ in 0..<100 { if !model.history.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }

        // Label from the live model: the Development Trial is Off, not "setup needed".
        let label = DaydreamMenuBarLabel(model: model).body as? DaydreamMenuBarLabelImage
        check(label?.drawnState == .off && label?.label == "DayDream: Off", "the Development Trial label is the Off mark, DayDream: Off",
              "\(String(describing: label?.label))")
        equal(DaydreamMenuBarPanel.setupLine(model: model, now: now, timeZone: la), nil, "the Development Trial draws no \"!\"")
        let routes = RouteRecorder()
        check(DaydreamMenuBarPanel.openSetUp(model: model, routes: routes.routes(model)) == nil, "the Development Trial offers no setup window")
        check(DaydreamMenuBarPanel.openPermissions(model: model, routes: routes.routes(model)) == nil, "the Development Trial offers no permissions window")
        let h = MenuBarMenu.header(model.presentation, now: now, timeZone: la, canSetUp: false, canOpenApplications: model.openApplicationsAction != nil)
        check(h.status.text == "Recording is off in this trial" && h.control == .toggle(on: false, enabled: false),
              "the Development Trial panel says Recording is off in this trial, beside a disabled switch", "\(h)")

        // Hosting the panel: 320 pt, refreshes today on appear, calls no route or action.
        var refreshes: [TimeInterval] = []
        let hooks = model.dayData
        model.dayData.refreshTodayIfStale = { refreshes.append($0) }
        let size = fitting(DaydreamMenuBarPanel(model: model, routes: routes.routes(model)))
        equal(size.width, width, "DaydreamMenuBarPanel is the 320 pt panel")
        let panelHost = host(DaydreamMenuBarPanel(model: model, routes: routes.routes(model)))
        check(!refreshes.isEmpty && refreshes.allSatisfy { $0 == 10 }, "opening the panel refreshes today if stale (10 s)", "\(refreshes)")
        let hover = hoverSweep(panelHost)
        check(routes.total == 0 && !model.settingsPresented && !model.activity.recallPresented && !model.recording && model.stopped,
              "opening the panel and \(hover.moves) hover moves call no route and change no model state",
              "routes \(routes.total), settings \(model.settingsPresented), recall \(model.activity.recallPresented)")
        model.dayData = hooks

        // Routes.
        let actions = DaydreamMenuBarPanel.actions(model: model, routes: routes.routes(model))
        actions.openMain()
        check(routes.windows == ["memory"] && routes.activations == 1, "Open DayDream opens the memory window and activates", "\(routes.windows)")
        actions.settings()
        check(routes.windows.last == "memory" && model.settingsPresented && model.settingsSection == "General",
              "DayDream Settings… opens the memory window on General settings")
        model.settingsPresented = false
        actions.openSettingsSection("Setup")
        check(model.settingsPresented && model.settingsSection == "Setup", "Review… opens DayDream Settings (Setup is the overview)")
        model.settingsPresented = false; model.settingsSection = "General"
        // Search… presents Recall only where search works (MemoryShell shows Recall only then).
        let savedSearch = model.activity.searchCanonical, savedQuery = model.activity.searchCanonicalQuery
        if !model.activity.canSearch {
            model.activity.searchCanonical = { _, _ in throw CocoaError(.featureUnsupported) }   // never called
        }
        actions.openRecall()
        check(model.activity.recallPresented && routes.windows.last == "memory", "Search… opens the memory window with Recall")
        model.activity.recallPresented = false
        model.activity.searchCanonical = nil; model.activity.searchCanonicalQuery = nil
        let windowsBefore = routes.windows.count
        actions.openRecall()
        check(!model.activity.canSearch && !model.activity.recallPresented && routes.windows.count == windowsBefore + 1 && routes.windows.last == "memory",
              "without search (storage-failure mode) Search… opens the memory window and leaves Recall closed")
        model.activity.searchCanonical = savedSearch; model.activity.searchCanonicalQuery = savedQuery
        // The today line: today's Focus List, Recall closed so it can't cover the list, nothing expanded.
        model.activity.focusedDay = "2026-09-20"
        model.activity.recallPresented = true
        model.activity.expandedMomentID = "m-old"
        let activationsBefore = routes.activations
        DaydreamMenuBarPanel.openToday(model: model, routes: routes.routes(model))
        check(model.activity.focusedDay == nil && model.activity.expandedMomentID == nil && routes.windows.last == "memory"
              && routes.activations == activationsBefore + 1, "the today line opens DayDream at today")
        check(!model.activity.recallPresented && model.activity.query.isEmpty && !model.activity.recallVisible,
              "the today line closes Recall, so today's list is visible")
        // Allow… in the Development Trial (no setup and no permissions window, so the fix is `.systemSettings`) shows
        // DayDream's drag cards in Settings › Permissions, where each card opens its own pane: the panel never opens
        // System Settings on its own.
        let urlsBefore = routes.urls.count
        for kind in [PermissionKind.accessibility, .inputMonitoring, nil] as [PermissionKind?] {
            model.settingsPresented = false; model.settingsSection = "General"
            actions.openSystemSettings(kind)
            check(routes.windows.last == "memory" && model.settingsPresented && model.settingsSection == "Permissions" && routes.urls.count == urlsBefore,
                  "Allow… without setup (\(kind?.title ?? "both")) opens the drag cards in Settings, not System Settings")
        }
        model.settingsPresented = false; model.settingsSection = "General"
        for (kind, pane) in [(PermissionKind.accessibility, "Privacy_Accessibility"), (.inputMonitoring, "Privacy_ListenEvent")] as [(PermissionKind, String)] {
            equal(MenuBarSystemSettings.url(kind).absoluteString, "x-apple.systempreferences:com.apple.preference.security?" + pane, "the \(kind.title) pane link")
        }
        actions.resume()
        check(!model.recording && model.stopped, "the switch in the Development Trial starts nothing")
        check(routes.terminations == 0, "no route terminated before Quit")
        // report-1004: Report a Problem… runs the report route only (a new email; here a counter): no window, page or quit.
        let beforeReport = (routes.windows.count, routes.urls.count, routes.activations)
        check(actions.reportProblem != nil && routes.reports == 0, "the panel offers Report a Problem…, and nothing reported before it")
        actions.reportProblem?()
        check(routes.reports == 1 && (routes.windows.count, routes.urls.count, routes.activations) == beforeReport && routes.terminations == 0,
              "Report a Problem… opens the email route only")

        // Quit: terminate, leaving the person's timed pause for the next launch (gold r3, gate item 4: quitting pauses
        // as DayDream's own and keeps the pause as the launch intent). Never the real NSApp.terminate here.
        model.pauseUntil = Date().addingTimeInterval(600)
        actions.quit()
        check(routes.terminations == 1 && routes.pauseClearedAtTermination == false, "Quit DayDream terminates and keeps the timed pause for the next launch",
              "terminations \(routes.terminations), cleared \(String(describing: routes.pauseClearedAtTermination))")

        // Isolated panel: 320 pt, Quit terminates through its injected route.
        var isolatedQuits = 0
        equal(fitting(DaydreamMenuBarIsolatedPanel(terminate: { isolatedQuits += 1 })).width, width, "the isolated panel is the 320 pt panel")
        let isolatedHost = host(DaydreamMenuBarIsolatedPanel(terminate: { isolatedQuits += 1 }))
        check(isolatedQuits == 0, "opening the isolated panel quits nothing")
        _ = sweep(isolatedHost, MenuBarRecorder(), step: 4)
        check(isolatedQuits > 0, "the isolated panel's Quit DayDream reaches terminate")
        check(!model.recording && model.stopped, "the Development Trial model ends stopped, not recording")
    }

    // MARK: F. NSHostingMenu (macOS 14.4+)

    static func nativeMenu() {
        guard #available(macOS 14.4, *) else {
            print("LIMIT: NSHostingMenu needs macOS 14.4; the Recording menu rows are checked through their model")
            return
        }
        let r = MenuBarRecorder()
        let anchor = host(Color.clear.frame(width: 200, height: 200))
        func menu(_ state: RecordingState, canResume: Bool, canStop: Bool) -> NSMenu {
            let m = NSHostingMenu(rootView: MenuBarRecordingMenu(state: state, canResume: canResume, canStop: canStop, actions: r.actions))
            m.update()
            if m.items.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { m.cancelTracking() }
                m.popUp(positioning: nil, at: NSPoint(x: 20, y: 100), in: anchor)
            }
            return m
        }
        let recording = menu(.recording(since: date(8, 40)), canResume: true, canStop: true)
        let titles = recording.items.filter { !$0.isSeparatorItem }.map(\.title)
        equal(titles, ["Pause for", "Start Recording", "Stop Recording"], "NSHostingMenu: Recording menu titles")
        let submenu = recording.items.first { $0.title == "Pause for" }?.submenu
        equal(submenu?.items.map(\.title) ?? [], ["5 Minutes", "15 Minutes", "30 Minutes", "2 Hours"], "NSHostingMenu: Pause for submenu")
        r.reset()
        if let submenu { for i in submenu.items.indices { submenu.performActionForItem(at: i) } }
        pump(0.05)
        equal(r.events, ["pause:5", "pause:15", "pause:30", "pause:120"], "NSHostingMenu: the Pause for submenu delivers 5, 15, 30 and 120")
        let paused = menu(.paused(until: date(16, 36), since: date(16, 18), reason: nil), canResume: true, canStop: true)
        check(paused.items.first { $0.title == "Resume Recording" }?.isEnabled == true, "NSHostingMenu: Resume Recording is enabled when paused")
        check(paused.items.first { $0.title == "Pause for" }.map { !$0.isEnabled || ($0.submenu?.items.allSatisfy { !$0.isEnabled } ?? false) } == true,
              "NSHostingMenu: pausing again is disabled while paused")
        print("SIZE native-recording-menu \(Int(recording.size.width))x\(Int(recording.size.height))")
        check(recording.size.width < 320, "NSHostingMenu: the Recording menu is narrower than 320 pt", "\(recording.size.width)")
    }

    // MARK: H. Content fits

    static let inkWidth: CGFloat = 420

    /// `view` drawn in the light appearance at its fitting size, left-aligned in a transparent host wider than the
    /// panel, so anything that overflows the panel is drawn (and found) right of it.
    static func ink<V: View>(_ view: V, dark: Bool = false) -> NSBitmapImageRep? {
        let size = fitting(view)
        let root = HStack(spacing: 0) {
            view.frame(width: size.width, height: size.height, alignment: .topLeading)
            Spacer(minLength: 0)
        }
        .frame(width: inkWidth, height: size.height, alignment: .topLeading)
        .environment(\.daydreamNow, now).environment(\.daydreamStatic, true)
        let h = NSHostingView(rootView: root)
        h.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setContentSize(NSSize(width: inkWidth, height: size.height))
        window.contentView = h
        h.frame = NSRect(x: 0, y: 0, width: inkWidth, height: size.height)
        pump(); h.layoutSubtreeIfNeeded(); pump(0.05)
        guard let rep = h.bitmapImageRepForCachingDisplay(in: h.bounds) else { return nil }
        h.cacheDisplay(in: h.bounds, to: rep)
        return rep
    }

    /// The leftmost and rightmost x (pt) of anything drawn opaque (alpha > 0.5).
    static func extent(_ rep: NSBitmapImageRep) -> (min: CGFloat, max: CGFloat) {
        let scale = CGFloat(rep.pixelsWide) / inkWidth
        let raw = rep.bitsPerSample == 8 && rep.hasAlpha && !rep.isPlanar ? rep.bitmapData : nil
        let spp = rep.samplesPerPixel, bpr = rep.bytesPerRow, ai = rep.bitmapFormat.contains(.alphaFirst) ? 0 : rep.samplesPerPixel - 1
        func opaque(_ x: Int, _ y: Int) -> Bool {
            if let raw { return raw[y * bpr + x * spp + ai] > 127 }
            return (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5
        }
        var lo = rep.pixelsWide, hi = -1
        for y in 0..<rep.pixelsHigh {
            if let x = (0..<rep.pixelsWide).first(where: { opaque($0, y) }) { lo = min(lo, x) }
            if let x = (0..<rep.pixelsWide).reversed().first(where: { opaque($0, y) }) { hi = max(hi, x) }
        }
        return (CGFloat(lo) / scale, CGFloat(hi + 1) / scale)
    }

    /// The pixel at (`x`, `y`) in sRGB. `colorAt` hands back the bitmap's numbers tagged Generic RGB (its colour space
    /// *name* is calibrated RGB), not in the space they were drawn in (`rep.colorSpace`), so converting its colour to
    /// sRGB shifted every channel by an amount that depended on the attached display (fix/menubar-red). The numbers
    /// are re-tagged with the bitmap's own space before the conversion.
    static func srgb(_ rep: NSBitmapImageRep, x: Int, y: Int) -> NSColor? {
        guard let raw = rep.colorAt(x: x, y: y) else { return nil }
        guard rep.colorSpace.colorSpaceModel == .rgb, let rgb = raw.usingType(.componentBased), rgb.numberOfComponents == 4 else {
            return raw.usingColorSpace(.sRGB)
        }
        var parts = [CGFloat](repeating: 0, count: 4)
        rgb.getComponents(&parts)
        return NSColor(colorSpace: rep.colorSpace, components: parts, count: 4).usingColorSpace(.sRGB)
    }

    /// sRGB pixels in `columns` and `rows` (pt, top-down) matching `test`.
    static func count(_ rep: NSBitmapImageRep, columns: ClosedRange<CGFloat>, rows: ClosedRange<CGFloat> = 0...10_000,
                      _ test: (NSColor) -> Bool) -> Int {
        let scale = CGFloat(rep.pixelsWide) / inkWidth
        var n = 0
        for x in max(0, Int(columns.lowerBound * scale))...min(rep.pixelsWide - 1, Int(columns.upperBound * scale)) {
            for y in max(0, Int(rows.lowerBound * scale))...min(rep.pixelsHigh - 1, Int(rows.upperBound * scale)) {
                if let c = srgb(rep, x: x, y: y), c.alphaComponent > 0.5, test(c) { n += 1 }
            }
        }
        return n
    }
    static func isRed(_ c: NSColor) -> Bool { c.redComponent > 0.75 && c.greenComponent < 0.45 && c.blueComponent < 0.45 }
    static func isIndigo(_ c: NSColor) -> Bool { c.blueComponent > 0.6 && c.redComponent < 0.5 && c.greenComponent < 0.5 }
    /// Pixels are read in sRGB (`srgb`): systemOrange reads about (1, 0.55, 0.16).
    static func isOrange(_ c: NSColor) -> Bool { c.redComponent > 0.8 && c.greenComponent > 0.48 && c.greenComponent < 0.72 && c.blueComponent < 0.4 }

    /// fix/menubar-red regression: the colour checks read what was drawn, whatever display is attached. Swatches of
    /// the panel's own colours, drawn through `ink`, read back within 0.02 of their sRGB values, and the dark orange
    /// text is not red (it read (0.79, 0.43, 0) with the monitor off and the headless virtual display in its place).
    static func colourReadsAreDisplayIndependent() {
        check(window.colorSpace == .sRGB, "the check window renders in sRGB whatever display is attached",
              window.colorSpace?.localizedName ?? "nil")
        let swatches: [(String, NSColor, String, (NSColor) -> Bool, Bool)] = [
            ("the orange text (light)", NSColor(srgbRed: 0.74, green: 0.35, blue: 0, alpha: 1), "red", isRed, false),
            ("the recording dot's red", NSColor(srgbRed: 0.94, green: 0.16, blue: 0.16, alpha: 1), "red", isRed, true),
            ("sRGB orange", NSColor(srgbRed: 1, green: 0.58, blue: 0, alpha: 1), "orange", isOrange, true),
        ]
        for (name, colour, kind, test, expected) in swatches {
            let swatch = Rectangle().fill(Color(nsColor: colour)).frame(width: 40, height: 20)
            guard let rep = ink(swatch), let c = srgb(rep, x: Int(20 * CGFloat(rep.pixelsWide) / inkWidth), y: Int(10 * CGFloat(rep.pixelsWide) / inkWidth)),
                  let want = colour.usingColorSpace(.sRGB) else { check(false, "\(name): the swatch renders"); continue }
            let off = max(abs(c.redComponent - want.redComponent), abs(c.greenComponent - want.greenComponent), abs(c.blueComponent - want.blueComponent))
            let got = String(format: "(%.3f, %.3f, %.3f)", c.redComponent, c.greenComponent, c.blueComponent)
            check(off < 0.02, "\(name) reads back as drawn in sRGB", got)
            check(test(c) == expected, "\(name) \(expected ? "counts" : "does not count") as \(kind)", got)
        }
    }

    static func contentFits() {
        let r = MenuBarRecorder()
        let busy = snapshot(moments, momentCount: 1204, apps: fixtureApps)
        // 1. Rendered: nothing leaves the panel. At rest text and controls keep the 14 pt margins; a highlighted row
        //    reaches 5 pt from each edge, as a menu's selection does.
        var rest: [(String, MenuBarMenu)] = Case.allCases.map { ($0.rawValue, panel($0, recorder: r)) }
        rest += [("busy day", panel(.recording, recorder: r, snapshot: busy)),
                 ("partial day", panel(.recording, recorder: r, snapshot: snapshot(moments, momentCount: 24, partial: true))),
                 ("typing on", panel(.recording, recorder: r, typing: typingRows(.recording(app: "Notes")))),
                 ("typing locked", panel(.recording, recorder: r, typing: typingRows(.locked(.keychainLocked)))),
                 ("typing paused", panel(.recording, recorder: r, typing: typingRows(.snoozed(until: date(22, 42))))),
                 ("Chrome access off", panel(.recording, recorder: r, browserHistory: .needsAccess)),
                 ("Chrome pages on", panel(.recording, recorder: r, browserHistory: .on)),
                 ("every line", panel(.recordingInputIssue, recorder: r, typing: typingRows(.snoozed(until: nil)), browserHistory: .needsAccess)),
                 ("Set Up DayDream…", panel(.off, recorder: r, onboardingComplete: false))]
        for (name, view) in rest {
            for dark in [false, true] {
                guard let rep = ink(view, dark: dark) else { check(false, "\(name): the panel renders to a bitmap"); continue }
                let e = extent(rep)
                print("SIZE ink \(name)\(dark ? " dark" : "") \(e.min)…\(e.max)")
                check(e.min >= 13 && e.max <= 307, "\(name)\(dark ? " (dark)" : ""): text and controls keep the 14 pt margins (\(Int(e.min))–\(Int(e.max)) pt)",
                      "\(e.min)…\(e.max)")
            }
        }
        for (name, view) in [("highlighted Quit", panel(.recording, recorder: r, highlighted: "Quit DayDream")),
                             ("Pause submenu open", panel(.recording, recorder: r, submenuOpen: true)),
                             ("highlighted today", panel(.recording, recorder: r, highlighted: "today"))] {
            guard let rep = ink(view) else { check(false, "\(name): the panel renders to a bitmap"); continue }
            let e = extent(rep)
            print("SIZE ink \(name) \(e.min)…\(e.max)")
            check(e.min >= 4.5 && e.min <= 5.5 && e.max >= 314.5 && e.max <= 315.5, "\(name): the highlight spans 5–315 pt, inside the panel", "\(e.min)…\(e.max)")
        }
        check(r.submenus.isEmpty, "drawing the Pause row open presents no submenu")

        // 2. The status glyph shows the state's colour, and nothing else does.
        let glyph: ClosedRange<CGFloat> = 13...27, top: ClosedRange<CGFloat> = 0...45
        for (c, red, indigo, orange) in [(Case.recording, true, false, false), (.paused, false, true, false), (.off, false, false, false),
                                         (.permission, false, false, true), (.offBlocked, false, false, true)] {
            guard let rep = ink(panel(c, recorder: r)) else { check(false, "\(c.rawValue): renders"); continue }
            let n = (count(rep, columns: glyph, rows: top, isRed), count(rep, columns: glyph, rows: top, isIndigo), count(rep, columns: glyph, rows: top, isOrange))
            check((n.0 > 8) == red && (n.1 > 8) == indigo && (n.2 > 8) == orange,
                  "\(c.rawValue): the status glyph is \(red ? "a red dot" : indigo ? "the indigo pause" : orange ? "an orange \"!\"" : "a grey ring")",
                  "red \(n.0), indigo \(n.1), orange \(n.2)")
        }
        // The red dot is Recording's alone: no other part of any panel is red.
        for c in Case.allCases {
            guard let rep = ink(panel(c, recorder: r)) else { continue }
            let red = count(rep, columns: 0...inkWidth, isRed)
            let recording = presentation(c)?.state.kind == .recording
            check(recording ? red > 8 : red == 0, "\(c.rawValue): red appears \(recording ? "only as the status dot" : "nowhere")",
                  "\(red)")
        }

        // 3. No line is cut: the today line beside three icons, the rows, the pause lengths.
        func line(_ s: String, _ size: CGFloat = 13, weight: Font.Weight = .regular) -> CGFloat {
            fitting(Text(s).font(.system(size: size, weight: weight)).fixedSize()).width
        }
        let rowText = width - 2 * 5 - 2 * 9     // 292: the row's width inside its highlight padding
        let icons: CGFloat = 3 * 17 + 2 * 3
        for (n, partial) in [(4, false), (124, false), (1204, false), (24, true), (3212, true)] {
            let text = DaydreamFormat.momentsRemembered(n, complete: !partial)!
            check(line(text) + 8 + icons <= rowText, "\(text) fits beside three app icons (\(Int(line(text))) pt)")
        }
        for t in ["Search…", "Open DayDream  ⌘O", "DayDream Settings…  ⌘,", "Set Up DayDream…", "Quit DayDream  ⌘Q", "Resume Now  ⌘P",
                  "Nothing recorded yet today"] {
            check(line(t) + 8 <= rowText, "the row \(t) fits on one line")
        }
        // The header: the status line on one line beside its control (the glyph and its gap are 17 pt, the least gap to
        // the control MenuBarMenu.controlGap, the margins 2 × 14 pt). The panel heights above confirm it on the real view.
        func control(_ title: String?) -> CGFloat {
            guard let title else { return fitting(Toggle("Recording", isOn: .constant(true)).toggleStyle(.switch).controlSize(.mini).labelsHidden()).width }
            return fitting(Button(title) {}.buttonStyle(.borderedProminent).controlSize(.small)).width
        }
        var statuses: [(MenuBarMenu.Status, String?)] = [(.init(tone: .recording, text: "Recording since 12:59 PM"), nil),
                                                          (.init(tone: .paused, text: "Paused · resumes 12:59 PM"), nil)]
        // Every header the cases draw, every pause reason and every blocker, beside the control it really has.
        var presentations = Case.allCases.compactMap(presentation)
        presentations += RecordingCopy.pauseDetails.map { CapturePresentation(state: .paused(until: nil, since: nil, reason: $0), canResume: true, canStop: true) }
        presentations += RecordingCopy.blockerDetails.map(off)
        for p in presentations {
            for (setUp, applications, permissions) in [(true, true, false), (false, false, false), (true, true, true)] {
                let h = MenuBarMenu.header(p, now: now, timeZone: la, canSetUp: setUp, canOpenApplications: applications, canOpenPermissions: permissions)
                if case .fix(let title, _) = h.control { statuses.append((h.status, title)) } else { statuses.append((h.status, nil)) }
            }
        }
        var fitted = Set<String>()
        for (status, button) in statuses where !fitted.contains(status.text + (button ?? ""))
            && status.text != longBlocker && status.text != MenuBarMenu.sentence(unknownPause) {
            fitted.insert(status.text + (button ?? ""))
            let words = line(status.text, 11.5, weight: status.tone == .attention ? .medium : .regular)
            check(words + 17 + MenuBarMenu.controlGap + control(button) <= width - 28,
                  "the status \(status.text) fits on one line beside \(button ?? "the switch") (\(Int(words)) pt)")
        }
        check(fitted.count >= 25, "every known status line was measured", "\(fitted.count)")
        // The lines under the status: each on one line with its chevron or Resume (the glyph and gap are 17 pt).
        for (s, trailing, weight) in [("Keyboard and mouse need attention", "›", Font.Weight.medium), (RecordingCopy.historyNotUpdated, "Try Again", .medium),
                                      (RecordingCopy.deletionNotFinished, "Try Again", .medium), (MenuBarMenu.historySetAsideLine, "›", .medium),
                                      (RecordingCopy.choicesUnsaved, "›", .medium),
                                      ("Browser history on (Google Chrome)", "›", .regular), ("Browser history on, but Chrome access is off", "›", .regular),
                                      ("Typing paused until 10:42 PM", "Resume", .regular), ("Typing is paused until you unlock your Mac.", "›", .regular),
                                      ("Typing is locked: turn it on in Settings", "›", .regular), ("Recording what you type in Notes", "", .regular)]
                as [(String, String, Font.Weight)] {
            let tail = trailing.isEmpty ? 0 : trailing == "›" ? 11 : 8 + line(trailing, 11.5, weight: .medium)
            check(line(s, 11.5, weight: weight) + 17 + tail <= width - 28, "the line \(s) fits on one line with its \(trailing.isEmpty ? "glyph" : trailing)")
        }
        check(r.events.isEmpty && r.dismisses == 0, "rendering and measuring the panel calls no action", "\(r.events)")
    }

    // MARK: G. Sources

    static let banned: [String] = {
        let remember = "Remem", cap = "cap" + "ture"
        return [remember + "bering", "remem" + "bering", "Start remem" + "bering", "Pause " + cap, "Resume " + cap, "Stop " + cap,
                "Never " + remember + "ber", "Tomor" + "row", "Mac" + " Mem", "Day" + "dream", "+15", "coming " + "soon", "Coming " + "soon"]
    }()

    /// String literals on non-comment code, single-line only; interpolations become a placeholder.
    static func literals(_ line: String) -> [String] {
        var out: [String] = [], current = ""
        var inQuote = false, escape = false, depth = 0, nested = false
        var prev: Character = " "
        for ch in line {
            if depth > 0 {
                if nested { if ch == "\"" { nested = false } }
                else if ch == "\"" { nested = true }
                else if ch == "(" { depth += 1 }
                else if ch == ")" { depth -= 1 }
            } else if inQuote {
                if escape {
                    escape = false
                    if ch == "(" { depth = 1; current.append("\u{FFFC}") } else { current.append(ch) }
                } else if ch == "\\" { escape = true }
                else if ch == "\"" { inQuote = false; out.append(current); current = "" }
                else { current.append(ch) }
            } else {
                if ch == "/" && prev == "/" { break }
                if ch == "\"" { inQuote = true }
            }
            prev = ch
        }
        return out
    }

    static func sources() {
        let files = ["Sources/MemoryUI/MenuBarMenu.swift", "Sources/MemoryUI/MenuBarRecordingMenu.swift", "Sources/MacMemApp/MenuBarContent.swift"]
        var texts: [String: String] = [:], codeLines: [String: [String]] = [:]
        // Stored keys are not copy: the onboarding flag keeps MemoryWindow's defaults key.
        let storedKeys: Set<String> = ["DaydreamOnboardingCompletedV1"]
        for f in files {
            guard let t = try? String(contentsOfFile: f, encoding: .utf8) else { check(false, "\(f) is readable from the worktree"); continue }
            texts[f] = t
            let code = t.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            codeLines[f] = code
            let lits = code.flatMap(literals).filter { !storedKeys.contains($0) }
            let hits = banned.filter { word in lits.contains { $0.contains(word) } }
            check(hits.isEmpty, "\(f): literals keep the Recording vocabulary and the DayDream casing", "\(hits)")
            check(!lits.contains { $0.lowercased().contains("cap" + "ture") }, "\(f): no literal uses the old recording verb")
            check(!lits.contains { $0.range(of: #"(?<![0-9] )remember"#, options: [.regularExpression, .caseInsensitive]) != nil },
                  "\(f): remember appears only after a count")
            // Every literal that names an SF Symbol draws on macOS 13.0.
            let symbols = lits.filter { $0.range(of: #"^[a-z][a-z0-9]*(\.[a-z0-9]+)+$"#, options: .regularExpression) != nil
                && NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
            let vetted: Set<String> = ["exclamationmark.triangle.fill", "chevron.right", "pause.circle.fill", "exclamationmark.circle.fill"]
            check(Set(symbols).isSubset(of: vetted), "\(f): SF Symbols are the vetted macOS 13 set", "\(Set(symbols).subtracting(vetted).sorted())")
            check(!t.contains("NSClassFromString") && !t.contains("NSStatusBarWindow") && !t.contains("_NS"), "\(f): no private class names")
        }
        let menuBar = texts[files[0]] ?? "", menu = texts[files[1]] ?? "", content = texts[files[2]] ?? ""
        check(menuBar.contains("title: \"Quit DayDream\""), "Quit DayDream lives in MenuBarMenu.swift")
        check(!menu.contains("Text(issue") && !menu.contains(".issue"), "MenuBarRecordingMenu shows no issue text (it can never widen the menu)")
        check(!menu.contains("KeyboardShortcut(\"") && !menu.contains(".keyboardShortcut(\""), "MenuBarRecordingMenu installs no key equivalent of its own")
        let menuCode = (codeLines[files[0]] ?? []).joined(separator: "\n")
        check(menuCode.components(separatedBy: "KeyboardShortcut(\"").count == 2 && menuCode.contains("static let pauseKey = KeyboardShortcut(\"p\", modifiers: .command)"),
              "MenuBarMenu's only literal shortcut is ⌘P (MenuBarMenu.pauseKey); the rows add ⌘O, ⌘, and ⌘Q")
        // The removed card: no big button, no chips, no Stop pill, no moments card, timeline, app grid, note or chip.
        for gone in ["RecordingControls(", "DDRibbon", "OnThisMacChip", "\"Stop Recording\"", "\"Pause for\"", "kitTile", "TypingMenuTile",
                     "latestLine", "topAppColumns"] {
            check(!menuCode.contains(gone), "the panel draws nothing of the old card (\(gone))")
        }
        check(menuCode.contains("Toggle(") && menuCode.contains(".toggleStyle(.switch)") && menuCode.contains(".controlSize(.mini)"),
              "the one switch is the system switch, mini (the size of the system menus' switches)")
        check(menuCode.contains("NSMenu(title: \"Pause\")") && menuCode.contains("menu.popUp(positioning: nil, at: point, in: anchor)"),
              "the Pause submenu is a real NSMenu popped up beside its row")
        check(menuCode.contains("MenuBarMenu.submenuSide(row: row, menuWidth: menu.size.width, visible: visible)")
              && menuCode.contains("MenuBarMenu.pointerIsAway(NSEvent.mouseLocation, panel: window.frame, row: row, menu: frame,")
              && menuCode.contains("onItem: menu.highlightedItem != nil)")
              && menuCode.contains("} while !chosen && shown < 8 && anchor.window != nil && MenuBarMenu.clickReopens(pointer(), row: row)"),
              "the submenu flips by MenuBarMenu.submenuSide, its watch uses pointerIsAway with the highlighted item, a click on Pause reopens it")
        check(menuCode.contains("Pointer(location: NSEvent.mouseLocation, leftButtonDown: NSEvent.pressedMouseButtons & 1 != 0)")
              && !menuCode.contains("NSApp.currentEvent"), "the reopen reads the button's live state, never a stale current event (Esc never reopens)")
        check(!menuCode.contains("UserDefaults") && !menuCode.contains("FileManager") && !menuCode.contains("NSWorkspace"),
              "the panel reads no store, file or workspace: the host passes everything")
        check(!menuCode.contains(".background(.") && !menuCode.contains("Material"), "the panel draws no background: the menu bar window's material shows")
        let contentCode = codeLines[files[2]] ?? []
        check(!contentCode.isEmpty && !contentCode.contains { $0.contains("@main") || $0.trimmingCharacters(in: .whitespaces).hasPrefix("#if") },
              "MenuBarContent.swift is outside #if and declares no @main")
        check(content.contains(".menuBarExtraStyle(.window)") && content.contains("DaydreamMenuBarLabel(model: model)")
              && content.contains("DaydreamMenuBarIsolatedLabel()"), "MenuBarContent.swift documents the MenuBarExtra scene for I1")
        for pin in ["pause: { model.pauseFor(minutes: $0) }", "resume: { model.requestStart { routes.openWindow(\"onboarding\"); routes.activate() } }", "stop: { model.stopCapture() }",
                    "actions.quit = { routes.terminate() }",
                    "model.development == nil ? { routes.openWindow(\"onboarding\"); routes.activate() } : nil",
                    "model.development == nil ? { routes.openWindow(\"permissions\"); routes.activate() } : nil",
                    "openPermissions: Self.openPermissions(model: model, routes: routes),",
                    "setup: DaydreamMenuBarPanel.setupLine(model: model, now: now, timeZone: zone)",
                    "typing: typing.indicator"] {
            check(content.contains(pin), "DaydreamMenuBarPanel wires \(pin)")
        }
        check(content.contains("func dismiss() { window?.orderOut(nil) }"), "the panel dismisses through its host window's orderOut")
        check(content.contains("calendar: model.activity.calendar,") && content.contains("timeZone: model.activity.calendar.timeZone"),
              "the panel and the label use the browser's calendar, the one today's snapshot was built with")
        check(content.contains("if model.recordingState.kind == .needsPermission { model.checkPermissions() }"),
              "opening the panel re-reads permissions while one is off (a read, as Check Again did)")
        check(!content.contains("requestAccess") && !content.contains("AXIsProcessTrustedWithOptions") && !content.contains("CGRequestListenEventAccess"),
              "the menu bar never requests a permission")
        // The install guide's troubleshooting quotes the panel's own words, so a reader finds the line they see.
        let install = (try? String(contentsOfFile: "docs/install.md", encoding: .utf8)) ?? ""
        func line(_ reason: String) -> String {
            MenuBarMenu.header(off(reason), now: now, timeZone: la, canSetUp: true, canOpenApplications: true).status.text
        }
        let move = line(RecordingCopy.moveToApplications), other = line(RecordingCopy.anotherCopy)
        check(move == "Move to Applications first" && other == "DayDream is already open", "the blocker lines the guide quotes", "\(move) / \(other)")
        for words in ["**\"\(move).\"**", "**\"\(other).\"**", "Choose **Resume Now** if it's paused, or turn the switch on if it's off"] {
            check(install.contains(words), "docs/install.md quotes the panel: \(words)")
        }
        check(!install.contains("Turn the switch back on to start again") && !install.contains("**\"Move DayDream to Applications first.\"**")
              && !install.contains("**\"Another copy of DayDream is open.\"**") && !install.contains("Quit the other DayDream first"),
              "docs/install.md quotes none of the old panel's lines")
    }
}
