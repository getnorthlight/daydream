// DD-RECIPE: UI
//
// A3 toolbar, status capsule and popover checks (plan §5 A3, amendments A3). Values only: a fixed clock and
// time zone, views hosted offscreen in an NSWindow, no app, no permissions, no recording.
//  - Capsule: label, VoiceOver value and help for every state from real `pauseUntil` dates; compact (<720 pt)
//    keeps them; pinned toolbar widths.
//  - Popover: at most one blue control per state (exactly one where the state has a primary action); pause
//    presets only while Recording, delivering [5, 15, 30, 120]; every click calls at most one closure; the link
//    rows open their settings sections; unread permissions show no accessory; no `Checked` time.
//  - Toolbar row: rendering, hovering, resizing and opening/closing the popover call nothing; the gear calls
//    `settings` once; Off, the Start Recording pill takes the capsule's place (its label starts, its chevron opens the
//    popover); there is no download item (ux/declutter: its progress is in Settings › Summaries); the search trigger sets
//    `recallPresented` and never `query`; the day stepper sends day commands only when it may; the row fits 560 pt
//    and, at 560, the search never sits over the status controls.
//  - Window: WindowConfigurator removes the separator and tabs, puts the toolbar on the window colour, saves no
//    frame from a check, and never sets fullSizeContentView or isMovableByWindowBackground.
//  - Sources: one `memory-settings` control, no `CaptureStatusControl`, no Tomorrow/+15, no ShellButtonStyle in
//    the toolbar, the macOS 26 glass branch.
//  - Live dot (owner 9/28, the red dot travelling on a diagonal under "Recording"; launch build: solid, "nothing
//    moving, no status noise"): in the real window toolbar, live motion on, light and dark, the dot keeps one place
//    beside the label in every frame after Recording turns on or the window arrives already recording, and once the
//    toolbar has settled the glyph's pixels (core and halo) are the same in every frame: no breathing.
//  - Composite (macOS 14+): MemoryShell(chrome: .windowToolbar) bridged into a real unified toolbar (LIMIT when
//    the offscreen capture or the item identifiers are unavailable).
// SwiftUI's accessibility tree is not published to an offscreen process, so clicks stand in for presses and
// identifiers are checked in the sources and, where AppKit exposes them, in the view tree (else LIMIT).
import AppKit
import SwiftUI
import Combine
import MemoryUI

@MainActor final class Calls {
    var pauses: [Int] = [], resumes = 0, stops = 0, settings = 0, systemSettings: [PermissionKind?] = [], checks = 0
    var sections: [String] = [], mains = 0, recalls = 0, quits = 0, retries = 0
    var total: Int { pauses.count + resumes + stops + settings + systemSettings.count + checks + sections.count + mains + recalls + quits }
    var capture: Int { pauses.count + resumes + stops }
    func reset() {
        pauses = []; resumes = 0; stops = 0; settings = 0; systemSettings = []; checks = 0
        sections = []; mains = 0; recalls = 0; quits = 0; retries = 0
    }
    var summary: String { "pauses \(pauses) resumes \(resumes) stops \(stops) settings \(settings) system \(systemSettings) checks \(checks) sections \(sections) retries \(retries)" }
    var actions: CaptureActions {
        var a = CaptureActions(pause: { [unowned self] in self.pauses.append($0) }, resume: { [unowned self] in self.resumes += 1 },
                               stop: { [unowned self] in self.stops += 1 }, settings: { [unowned self] in self.settings += 1 })
        a.openSystemSettings = { [unowned self] in self.systemSettings.append($0) }
        a.checkPermissions = { [unowned self] in self.checks += 1 }
        a.openSettingsSection = { [unowned self] in self.sections.append($0) }
        a.openMain = { [unowned self] in self.mains += 1 }
        a.openRecall = { [unowned self] in self.recalls += 1 }
        a.quit = { [unowned self] in self.quits += 1 }
        a.retryIssue = { [unowned self] in self.retries += 1 }
        return a
    }
}

@main @MainActor enum DDStatusChecks {
    static var failures = 0

    static func check(_ ok: Bool, _ name: String, _ got: @autoclosure () -> String = "") {
        if ok { print("PASS " + name) } else {
            failures += 1
            fflush(stdout)
            FileHandle.standardError.write(Data(("FAIL: " + name + (got().isEmpty ? "" : " (got: " + got() + ")") + "\n").utf8))
        }
    }
    static func equal<T: Equatable>(_ got: T, _ want: T, _ name: String) { check(got == want, name, "\(got)") }

    // MARK: Values (the render fixture's clock: Tue 2026-09-22 4:21 PM, America/Los_Angeles)

    static let la = TimeZone(identifier: "America/Los_Angeles")!
    static var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = la; return c }
    static func date(_ h: Int, _ m: Int, day: Int = 22) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 9, day: day, hour: h, minute: m))!
    }
    static let now = date(16, 21)

    /// The render fixture's recording cases (`DDFixture.recording`): recording since 8:40 AM, a timed pause until
    /// 4:36 PM taken at 4:18 PM, stopped at 4:19 PM.
    enum Case: String, CaseIterable {
        case recording, pausedTimed, pausedOpen, off, offBlocked, needsInputMonitoring, needsUnknown, recordingWithIssue
    }
    static func inputs(_ c: Case) -> RecordingStateInputs {
        let since = date(8, 40), pausedAt = now.addingTimeInterval(-3 * 60), until = now.addingTimeInterval(15 * 60)
        let stoppedAt = now.addingTimeInterval(-2 * 60)
        switch c {
        case .recording: return RecordingStateInputs(recording: true, stopped: false, recordingSince: since, accessibilityGranted: true, inputMonitoringGranted: true)
        case .recordingWithIssue: return RecordingStateInputs(recording: true, stopped: false, recordingSince: since, accessibilityGranted: true,
                                                              inputMonitoringGranted: true, operationalIssue: "Summary writer needs attention")
        case .pausedTimed: return RecordingStateInputs(stopped: false, pauseUntil: until, pausedAt: pausedAt, accessibilityGranted: true, inputMonitoringGranted: true)
        case .pausedOpen: return RecordingStateInputs(stopped: false, pausedAt: pausedAt, accessibilityGranted: true, inputMonitoringGranted: true)
        case .off: return RecordingStateInputs(stoppedAt: stoppedAt, accessibilityGranted: true, inputMonitoringGranted: true)
        case .offBlocked: return RecordingStateInputs(stoppedAt: stoppedAt, resumeUnavailable: "Review replacement", accessibilityGranted: true, inputMonitoringGranted: true)
        case .needsInputMonitoring: return RecordingStateInputs(stoppedAt: stoppedAt, resumeUnavailable: "Permissions required",
                                                                accessibilityGranted: true, inputMonitoringGranted: false)
        case .needsUnknown: return RecordingStateInputs(stoppedAt: stoppedAt, resumeUnavailable: "Permissions required")
        }
    }
    static func permissions(_ c: Case) -> PermissionSnapshot {
        let i = inputs(c)
        return PermissionSnapshot(accessibility: i.accessibilityGranted, inputMonitoring: i.inputMonitoringGranted)
    }
    static func presentation(_ c: Case) -> CapturePresentation { CapturePresentation(inputs: inputs(c), permissions: permissions(c)) }

    static func snapshot(partial: Bool = false) -> TodaySnapshot {
        let moments = (0..<6).map { i -> MomentSlice in
            let start = date(9 + i, 5), end = date(9 + i, 40)
            return MomentSlice(id: "m\(i)", dayKey: "2026-09-22", start: start, end: end, title: "Moment \(i)", subject: "moment",
                               firstBullet: "Did a thing.", bullets: [MomentBullet(text: "Did a thing.")], apps: ["Zed"], primaryBundle: "dev.zed.Zed",
                               bundles: ["dev.zed.Zed"], sites: [], actionIDs: ["a\(i)"], actionCount: 1, clusters: [start...end],
                               summary: .ready(generatedAt: nil, local: true), hasCorrection: false, primaryApp: "Zed")
        }
        return TodaySnapshot(dayKey: "2026-09-22", loadedAt: now, momentCount: moments.count, actionCount: moments.count, countComplete: !partial,
                             partial: partial, moments: moments, headline: nil, headlineBullets: [], headlineGeneratedAt: nil, headlineLocal: nil,
                             firstObserved: moments.first?.start, lastObserved: moments.last?.end, topApps: [], latest: moments.last,
                             summaries: SummaryAvailability(provider: .local, busy: false), readyCount: moments.count, pendingCount: 0,
                             tooLongCount: 0, appCount: 1)
    }
    static let exclusions = ExclusionSummary(alwaysPrivate: ["com.apple.keychainaccess"], excludedByYou: ["com.apple.FaceTime", "com.apple.Music"])

    // MARK: Hosting

    static let window: NSWindow = {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1172, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        w.acceptsMouseMovedEvents = true
        w.orderFrontRegardless()
        return w
    }()

    static func pump(_ s: Double = 0.15) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    static var hoverEvents = 0

    @discardableResult
    static func host<V: View>(_ view: V, size: NSSize) -> NSHostingView<AnyView> {
        let h = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height, alignment: .topLeading)
            .onContinuousHover { _ in hoverEvents += 1 }
            .environment(\.daydreamNow, now).environment(\.daydreamStatic, true)))
        window.setContentSize(size)
        window.contentView = h
        h.frame = NSRect(origin: .zero, size: size)
        pump(); h.layoutSubtreeIfNeeded(); pump(0.05)
        return h
    }

    /// A click at `point` (top-left origin, in `view`'s coordinates).
    static func click(_ view: NSView, _ point: CGPoint, in target: NSWindow? = nil) {
        let win = target ?? view.window ?? window
        let flipped = view.isFlipped ? point : CGPoint(x: point.x, y: view.bounds.height - point.y)
        let p = view.convert(flipped, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                          pressure: type == .leftMouseDown ? 1 : 0) {
                win.sendEvent(e)
            }
        }
        pump(0.08)
    }

    /// Clicks on a grid over the whole view; the largest number of closure calls one click made.
    static func clickSweep(_ view: NSView, _ calls: Calls, step: CGFloat = 6, in target: NSWindow? = nil, stopAfter: Int? = nil) -> (clicks: Int, worst: Int) {
        let win = target ?? window
        var clicks = 0, worst = 0
        let b = view.bounds
        var y = b.minY + 2
        outer: while y < b.maxY {
            var x = b.minX + 2
            while x < b.maxX {
                let before = calls.total
                let p = view.convert(NSPoint(x: x, y: y), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                  pressure: type == .leftMouseDown ? 1 : 0) {
                        win.sendEvent(e)
                    }
                }
                RunLoop.main.run(until: Date())
                clicks += 1
                worst = max(worst, calls.total - before)
                if let stopAfter, calls.total >= stopAfter { break outer }
                x += step
            }
            y += step
        }
        pump(0.05)
        return (clicks, worst)
    }

    static func trackingAreas(_ view: NSView) -> [(NSTrackingArea, NSResponder)] {
        view.trackingAreas.compactMap { t in (t.owner as? NSResponder).map { (t, $0) } } + view.subviews.flatMap(trackingAreas)
    }

    /// Hover across the whole view as AppKit delivers it (entered, moves, exited): hovering must call nothing.
    static func hoverSweep(_ view: NSView) -> (moves: Int, delivered: Int) {
        let before = hoverEvents
        var moves = 0
        let areas = trackingAreas(view)
        var owners: [NSResponder] = []
        for (_, o) in areas where !owners.contains(where: { $0 === o }) { owners.append(o) }
        func enterExit(_ type: NSEvent.EventType, _ p: NSPoint) {
            for (area, owner) in areas {
                guard let e = NSEvent.enterExitEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                     trackingNumber: unsafeBitCast(area, to: Int.self), userData: nil) else { continue }
                if type == .mouseEntered { owner.mouseEntered(with: e) } else { owner.mouseExited(with: e) }
            }
        }
        let b = view.bounds
        var entered = false
        var last = NSPoint.zero
        var y = b.minY + 4
        while y < b.maxY {
            var x = b.minX + 4
            while x < b.maxX {
                let p = view.convert(NSPoint(x: x, y: y), to: nil)
                if !entered { enterExit(.mouseEntered, p); entered = true }
                if let e = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                    for o in owners { o.mouseMoved(with: e) }
                    moves += 1
                }
                RunLoop.main.run(until: Date())
                last = p
                x += 16
            }
            y += 8
        }
        if entered { enterExit(.mouseExited, last) }
        pump(0.1)
        return (moves, hoverEvents - before)
    }

    static func popoverWindows() -> [NSWindow] {
        NSApp.windows.filter { $0 !== window && $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
    }
    static func closePopovers() {
        for w in popoverWindows() { w.orderOut(nil) }
        pump(0.1)
    }

    static func browser(canonical: Bool = true, search: Bool = true) -> ActivityBrowser {
        let b = ActivityBrowser(calendar: cal)
        let clock = now
        b.now = { clock }
        b.summaries = SummaryAvailability(provider: .local, busy: false)
        b.exclusions = exclusions
        if canonical { b.loadCanonicalDay = { _, _ in throw CancellationError() } }
        if search { b.searchCanonical = { _, _ in throw CancellationError() } }
        return b
    }

    // MARK: Main

    static func main() {
        capsuleModel()
        capsuleHosted()
        popoverModel()
        copyModel()
        popoverHosted()
        toolbarRow()
        searchAndStepper()
        fits()
        windowChrome()
        sources()
        composite()
        closePopovers()
        window.orderOut(nil)
        fflush(stdout)
        if failures > 0 {
            FileHandle.standardError.write(Data("FAIL: \(failures) status check(s) failed\n".utf8))
            exit(1)
        }
        print("PASS dd-status-checks: all toolbar, capsule and popover checks passed")
    }

    // MARK: Capsule

    static func capsuleModel() {
        let expected: [Case: (label: String, value: String, help: String)] = [
            // ux/declutter: the tooltip is the state alone (no "Click to …").
            .recording: ("Recording", "Recording", "Recording since 8:40 AM"),
            .pausedTimed: ("Paused · 15m", "Paused until 4:36 PM, 15 minutes left", "Paused until 4:36 PM"),
            .pausedOpen: ("Paused", "Paused by you", "Paused"),
            .off: ("Off", "Off, Nothing is recorded until you start again.", "Off"),
            .offBlocked: ("Off", "Off, Review the replacement in Settings before recording.", "Off"),
            .needsInputMonitoring: ("Turn on Input Monitoring", "Needs permission: Input Monitoring", "Input Monitoring is off in System Settings."),
            .needsUnknown: ("Needs Permission", "Needs permission, Accessibility and Input Monitoring are required.", "Needs Permission"),
        ]
        for (c, want) in expected.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let p = presentation(c)
            equal(p.state.capsuleLabel(now: now), want.label, "capsule label, \(c.rawValue)")
            equal(p.state.accessibilityValue(now: now, timeZone: la), want.value, "capsule VoiceOver value, \(c.rawValue)")
            equal(StatusCapsule.help(for: p.state, canStart: p.canResume, timeZone: la), want.help, "capsule help, \(c.rawValue)")
        }
        // Unknown start: no "since".
        equal(StatusCapsule.help(for: .recording(since: nil), timeZone: la), "Recording", "capsule help omits an unknown start")
        // The countdown follows the real pause end: 1 minute left reads 1m, never 0m.
        let until = inputs(.pausedTimed).pauseUntil!
        equal(presentation(.pausedTimed).state.capsuleLabel(now: until.addingTimeInterval(-30)), "Paused · 1m", "capsule countdown rounds up in the last minute")
        // Pinned widths (window toolbar): stable across a countdown, wide enough for the longest label.
        let paused = presentation(.pausedTimed).state
        check(StatusCapsule.width(for: paused, compact: false) >= StatusCapsule.width(for: .paused(until: nil, since: nil, reason: nil), compact: false),
              "a timed pause reserves its longest countdown")
        equal(StatusCapsule.width(for: paused, compact: true), 32, "the compact capsule is 32 pt")
    }

    static func capsuleHosted() {
        for c in Case.allCases {
            let p = presentation(c)
            var opened = 0
            for compact in [false, true] {
                let capsule = StatusCapsule(state: p.state, canStart: p.canResume, compact: compact, timeZone: la) { opened += 1 }
                let probe = NSHostingView(rootView: capsule.environment(\.daydreamNow, now))
                let size = probe.fittingSize
                if compact {
                    check(abs(size.width - 32) < 0.5 && abs(size.height - 32) < 0.5, "\(c.rawValue): compact capsule is a 32 pt circle", "\(size)")
                } else {
                    check(abs(size.height - 32) < 0.5 && size.width > 60, "\(c.rawValue): capsule is 32 pt tall", "\(size)")
                    check(size.width <= StatusCapsule.width(for: p.state, compact: false) + 0.5,
                          "\(c.rawValue): the pinned toolbar width holds the capsule", "\(size.width) > \(StatusCapsule.width(for: p.state, compact: false))")
                }
                let h = host(capsule.padding(4), size: NSSize(width: size.width + 8, height: 40))
                // Help and VoiceOver keep the full state when compact: AppKit exposes the tooltip on the hosting view tree.
                let tips = toolTips(h)
                if tips.isEmpty {
                    if c == .recording && !compact { print("LIMIT: SwiftUI tooltips not exposed offscreen; help verified through StatusCapsule.help") }
                } else {
                    check(tips.contains(StatusCapsule.help(for: p.state, canStart: p.canResume, timeZone: la)),
                          "\(c.rawValue)\(compact ? " compact" : ""): the tooltip is the full state", tips.joined(separator: " | "))
                }
                let sweep = hoverSweep(h)
                check(sweep.delivered > 0, "\(c.rawValue)\(compact ? " compact" : ""): hover reaches the capsule", "\(sweep)")
                click(h, CGPoint(x: (size.width + 8) / 2, y: 20))
                closePopovers()
            }
            equal(opened, 2, "\(c.rawValue): a click on the capsule only asks to open the popover (full and compact)")
        }
    }

    static func toolTips(_ view: NSView) -> [String] {
        (view.toolTip.map { [$0] } ?? []) + view.subviews.flatMap(toolTips)
    }

    // MARK: Popover

    static func popoverModel() {
        for c in Case.allCases {
            let p = presentation(c)
            let buttons = RecordingControls.buttons(for: p.state, style: .popover, canStart: p.canResume, canStop: p.canStop)
            let prominent = buttons.filter(\.prominent)
            if let primary = p.state.primaryAction {
                check(prominent.count == 1 && prominent.first?.action == primary, "\(c.rawValue): exactly one blue control, the state's primary action",
                      prominent.map(\.title).joined(separator: ", "))
            } else {
                check(prominent.isEmpty, "\(c.rawValue): no blue control (Stop is never blue)", prominent.map(\.title).joined(separator: ", "))
            }
            let presets = buttons.compactMap { b -> Int? in if case .pause(let m) = b.action { return m }; return nil }
            equal(presets, p.state.kind == .recording ? [5, 15, 30, 120] : [], "\(c.rawValue): pause presets only while Recording")
            let titles = buttons.map(\.title).joined(separator: " ")
            check(!titles.contains("Tomorrow") && !titles.contains("+15"), "\(c.rawValue): no Tomorrow or +15", titles)
        }
        // Permissions accessory: nil reads show nothing, never "Both allowed".
        check(StatusPopover.permissionsText(nil) == nil, "unread permissions: no accessory")
        check(StatusPopover.permissionsText(PermissionSnapshot(accessibility: true, inputMonitoring: nil)) == nil, "one unread permission: no accessory")
        check(StatusPopover.permissionsText(PermissionSnapshot()) == nil, "both unread: no accessory")
        func text(_ a: Bool?, _ i: Bool?) -> String {
            StatusPopover.permissionsText(PermissionSnapshot(accessibility: a, inputMonitoring: i)).map { $0.title + ($0.missing ? " (orange)" : "") } ?? "none"
        }
        equal(text(true, true), "Both allowed", "both granted: Both allowed")
        equal(text(true, false), "Input Monitoring needed (orange)", "Input Monitoring off: Input Monitoring needed, orange")
        equal(text(false, nil), "Accessibility needed (orange)", "Accessibility off, Input Monitoring unread: Accessibility needed")
        equal(text(false, false), "Both needed (orange)", "both off: Both needed")
        // ux/declutter: the popover's one link row is Permissions, drawn only when a permission reads as missing while
        // the state isn't Needs Permission (there the header and Open System Settings say it).
        equal(StatusPopover.missingPermissions(state: presentation(.off).state, reads: PermissionSnapshot(accessibility: true, inputMonitoring: false)),
              "Input Monitoring needed", "Off with Input Monitoring read as missing: the Permissions row says so")
        equal(StatusPopover.missingPermissions(state: presentation(.off).state, reads: permissions(.off)), nil, "both allowed: no Permissions row")
        equal(StatusPopover.missingPermissions(state: presentation(.off).state, reads: nil), nil, "unread permissions: no Permissions row")
        equal(StatusPopover.missingPermissions(state: presentation(.needsInputMonitoring).state, reads: permissions(.needsInputMonitoring)), nil,
              "Needs Permission: no Permissions row (the header says it)")
        // The attention line: an operational issue the state doesn't already say.
        equal(presentation(.recordingWithIssue).attentionLine(now: now, timeZone: la), "Couldn't update your history", "operational issue: orange attention line, in plain words")
        equal(presentation(.offBlocked).attentionLine(now: now, timeZone: la), nil, "a blocker the Off detail already says: no attention line")
        equal(presentation(.needsInputMonitoring).attentionLine(now: now, timeZone: la), nil, "the permission gap: no attention line")
    }

    /// Gear help, the Advanced ▸ Recording control's line, the unread-exclusions rule and the partial-day footnote.
    static func copyModel() {
        // The gear names what the state or its attention line says, never the generic both-required sentence when the
        // reads name the missing permission.
        let gear: [Case: String] = [
            .recording: "Settings (⌘,)",
            .pausedTimed: "Settings (⌘,)",
            .off: "Settings (⌘,)",
            .recordingWithIssue: "Settings · Couldn't update your history",
            .offBlocked: "Settings · Review the replacement in Settings before recording.",
            .needsInputMonitoring: "Settings · Input Monitoring is off in System Settings.",
            .needsUnknown: "Settings · Accessibility and Input Monitoring are required.",
        ]
        for (c, want) in gear.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            equal(SettingsGearButton.help(for: presentation(c), now: now, timeZone: la), want, "gear help, \(c.rawValue)")
        }
        // Settings ▸ Advanced ▸ Recording: the four-state vocabulary under the toggle (the legacy titles are gone).
        let master: [Case: String?] = [
            .recording: nil,
            .pausedTimed: "Paused · nothing is recorded",
            .pausedOpen: "Paused · nothing is recorded",
            .off: "Off · nothing is recorded",
            .offBlocked: "Review the replacement in Settings before recording.",
            .needsInputMonitoring: "Turn on Input Monitoring",   // perm-1004
            .needsUnknown: "Needs Permission",
        ]
        for (c, want) in master.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            equal(RecordingMasterControl.subtitle(presentation(c).state), want, "Recording control line, \(c.rawValue)")
        }
        equal(RecordingMasterControl.subtitle(CapturePresentation(title: "Development Trial · OFF").state), "Development Trial · recording is disabled",
              "Recording control line, development trial (no 'OFF')")
        equal(RecordingMasterControl.subtitle(CapturePresentation(title: "Stopped").state), "Off · nothing is recorded",
              "Recording control line, legacy 'Stopped' reads Off")
        // ux/declutter: the popover repeats nothing the day card or Settings shows: no ribbon, moment count, partial
        // footnote, Checked time, Apps or Summaries rows.
        let popoverSource = (try? String(contentsOfFile: "Sources/MemoryUI/StatusPopover.swift", encoding: .utf8)) ?? ""
        check(!popoverSource.isEmpty && !popoverSource.contains("DDRibbon(") && !popoverSource.contains("momentsRemembered")
              && !popoverSource.contains("\"Checked \"") && !popoverSource.contains("LinkRow(\"Apps to remember\"")
              && !popoverSource.contains("LinkRow(\"Summaries\"") && !popoverSource.contains("Partial day coverage"),
              "the popover draws no ribbon, count, partial footnote, Checked time, Apps or Summaries row")
    }

    static func popover(_ c: Case, calls: Calls, permissions reads: PermissionSnapshot? = nil) -> some View {
        var p = presentation(c)
        if let reads { p = CapturePresentation(inputs: inputs(c), permissions: reads) }
        return StatusPopover(state: p.state, presentation: p, actions: calls.actions, now: now, calendar: cal)
    }

    static func popoverHosted() {
        let calls = Calls()
        struct Expect { let pauses: [Int]; let resumes: Int; let stops: Bool; let links: Bool; let system: Bool; let checks: Bool }
        let expectations: [Case: Expect] = [
            .recording: Expect(pauses: [5, 15, 30, 120], resumes: 0, stops: true, links: false, system: false, checks: false),
            .recordingWithIssue: Expect(pauses: [5, 15, 30, 120], resumes: 0, stops: true, links: false, system: false, checks: false),
            .pausedTimed: Expect(pauses: [], resumes: 1, stops: true, links: false, system: false, checks: false),
            .pausedOpen: Expect(pauses: [], resumes: 1, stops: true, links: false, system: false, checks: false),
            .off: Expect(pauses: [], resumes: 1, stops: false, links: false, system: false, checks: false),
            .offBlocked: Expect(pauses: [], resumes: 0, stops: false, links: false, system: false, checks: false),
            .needsInputMonitoring: Expect(pauses: [], resumes: 0, stops: false, links: false, system: true, checks: true),
            .needsUnknown: Expect(pauses: [], resumes: 0, stops: false, links: false, system: true, checks: true),
        ]
        for (c, e) in expectations.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            calls.reset()
            let view = popover(c, calls: calls)
            let height = max(200, NSHostingView(rootView: view.environment(\.daydreamNow, now)).fittingSize.height)
            let h = host(view, size: NSSize(width: StatusPopover.width, height: height))
            let hover = hoverSweep(h)
            check(calls.total == 0, "\(c.rawValue): rendering and \(hover.moves) hover moves call nothing", calls.summary)
            let sweep = clickSweep(h, calls)
            let tag = "popover \(c.rawValue)"
            check(sweep.worst <= 1, "\(tag): no click calls more than one closure", "\(sweep.worst)")
            equal(Set(calls.pauses), Set(e.pauses), "\(tag): presets pause for exactly [5, 15, 30, 120] only while Recording")
            check((calls.resumes > 0) == (e.resumes > 0), "\(tag): Start/Resume \(e.resumes > 0 ? "is" : "is not") clickable", calls.summary)
            check((calls.stops > 0) == e.stops, "\(tag): Stop Recording \(e.stops ? "is" : "is not") clickable", calls.summary)
            check((!calls.systemSettings.isEmpty) == e.system, "\(tag): Allow Permissions \(e.system ? "is" : "is not") offered", calls.summary)
            check((calls.checks > 0) == e.checks, "\(tag): Check Again \(e.checks ? "is" : "is not") offered", calls.summary)
            if e.links {
                equal(Set(calls.sections), ["Permissions"], "\(tag): the one link row opens Permissions")
            } else {
                check(calls.sections.isEmpty, "\(tag): no link rows (all allowed, or Needs Permission says it)", calls.summary)
            }
            check(calls.settings == 0 && calls.mains == 0 && calls.recalls == 0 && calls.quits == 0, "\(tag): never opens windows or quits", calls.summary)
            // r2: the orange line is its own fix; Try Again retries the history update (and only there).
            check((calls.retries > 0) == (c == .recordingWithIssue), "\(tag): Try Again \(c == .recordingWithIssue ? "is" : "is not") offered", calls.summary)
            if c == .needsInputMonitoring {
                equal(Set(calls.systemSettings.map { $0?.rawValue ?? "privacy" }), ["inputMonitoring"], "\(tag): Allow Permissions passes Input Monitoring")
            }
        }
        // Off with Input Monitoring read as missing (the state stays Off): the Permissions row is the one sign, and
        // it opens Permissions (a positive control for the link row).
        calls.reset()
        let missing = PermissionSnapshot(accessibility: true, inputMonitoring: false)
        let offMissing = popover(.off, calls: calls, permissions: missing)
        let missingHeight = max(200, NSHostingView(rootView: offMissing.environment(\.daydreamNow, now)).fittingSize.height)
        let hm = host(offMissing, size: NSSize(width: StatusPopover.width, height: missingHeight))
        _ = clickSweep(hm, calls)
        equal(Set(calls.sections), ["Permissions"], "Off with a missing permission: the Permissions row opens Permissions")
        let plain = NSHostingView(rootView: popover(.off, calls: calls).environment(\.daydreamNow, now)).fittingSize.height
        check(missingHeight > plain + 20, "the Permissions row shows only when a permission reads as missing", "\(missingHeight) vs \(plain)")
        check(abs(NSHostingView(rootView: popover(.pausedTimed, calls: calls).environment(\.daydreamNow, now)).fittingSize.width - 364) < 0.5,
              "the popover is 364 pt wide")
    }

    // MARK: Toolbar row

    static func row(_ c: Case, _ calls: Calls, browser b: ActivityBrowser, width: CGFloat) -> NSHostingView<AnyView> {
        host(DaydreamToolbarRow(browser: b, state: presentation(c), actions: calls.actions, width: width), size: NSSize(width: width, height: 52))
    }

    static func toolbarRow() {
        let calls = Calls()
        for c in Case.allCases {
            calls.reset()
            let b = browser()
            // Render and resize: nothing is called.
            var h = row(c, calls, browser: b, width: 1172)
            for w in [900, 720, 680, 600, 560, 1172] as [CGFloat] {
                window.setContentSize(NSSize(width: w, height: 52)); h.frame = NSRect(x: 0, y: 0, width: w, height: 52)
                h.rootView = AnyView(DaydreamToolbarRow(browser: b, state: presentation(c), actions: calls.actions, width: w)
                    .frame(width: w, height: 52).environment(\.daydreamNow, now).environment(\.daydreamStatic, true))
                pump(0.05)
            }
            h = row(c, calls, browser: b, width: 1172)
            let hover = hoverSweep(h)
            check(calls.total == 0, "row \(c.rawValue): rendering, resizing and \(hover.moves) hover moves call nothing", calls.summary)
            // The capsule: second from the trailing edge (gear 32, spacing 8, padding 16). Off and able to start, the
            // Start Recording pill takes its place; with an issue its chevron (the pill's trailing 24 pt) opens the
            // popover. ux/declutter: a plain Off's pill has no chevron (its popover only repeated Start Recording), so
            // there is no popover to open and the label is the whole pill.
            let p = presentation(c)
            let startShown = p.state.kind == .off && p.canResume
            let chevron = startShown && p.issue != nil
            let pillWidth = NSHostingView(rootView: StartRecordingButton(action: {}, more: chevron ? {} : nil)).fittingSize.width
            let capsuleWidth = startShown ? pillWidth
                : NSHostingView(rootView: StatusCapsule(state: p.state, canStart: p.canResume, timeZone: la).environment(\.daydreamNow, now)).fittingSize.width
            let capsuleCentre = startShown ? CGPoint(x: 1172 - 16 - 32 - 8 - 12, y: 26)   // the chevron: the pill's trailing 24 pt
                : CGPoint(x: 1172 - 16 - 32 - 8 - capsuleWidth / 2, y: 26)
            if !startShown || chevron { click(h, capsuleCentre) }
            pump(0.3)
            let opened = !popoverWindows().isEmpty
            if startShown && !chevron { check(!opened, "row \(c.rawValue): a plain Off has no popover to open") }
            if c == .recording && !opened { print("LIMIT: the popover window did not appear offscreen; opening is checked for callbacks only") }
            check(calls.total == 0, "row \(c.rawValue): opening the popover calls nothing", calls.summary)
            if opened, c == .recording, let pop = popoverWindows().first, let content = pop.contentView {
                // One press inside: exactly one capture call, and the popover closes.
                let sweep = clickSweep(content, calls, step: 5, in: pop, stopAfter: 1)
                pump(0.4)
                check(calls.total == 1 && sweep.worst == 1, "row recording: one press in the popover makes exactly one call", calls.summary)
                if calls.total == 1 && calls.checks == 0 {
                    check(popoverWindows().isEmpty, "row recording: the press closes the popover", calls.summary)
                }
                calls.reset()
            } else if opened {
                click(h, capsuleCentre)
                pump(0.3)
                check(calls.total == 0, "row \(c.rawValue): closing the popover calls nothing", calls.summary)
            }
            closePopovers()
            calls.reset()
            // The gear: settings once, nothing else.
            click(h, CGPoint(x: 1172 - 16 - 16, y: 26))
            check(calls.settings == 1 && calls.total == 1, "row \(c.rawValue): the gear calls settings once and no capture action", calls.summary)
            calls.reset()
            // Start Recording: the pill's label (Off with canResume only), one press, one start.
            if startShown {
                click(h, CGPoint(x: 1172 - 16 - 32 - 8 - pillWidth + 40, y: 26))
                check(calls.resumes == 1 && calls.total == 1, "row \(c.rawValue): Start Recording calls start once", calls.summary)
                calls.reset()
            }
            let sweep = clickSweep(h, calls, step: 8)
            closePopovers()
            check(sweep.worst <= 1, "row \(c.rawValue): no click calls more than one closure", "\(sweep.worst)")
            check(calls.capture == (startShown ? calls.resumes : 0) && calls.pauses.isEmpty && calls.stops == 0,
                  "row \(c.rawValue): the only capture control in the row is Start Recording (Off)", calls.summary)
        }
        // ux/declutter: no download item. A download's progress is in Settings › Summaries, so the row is the same
        // width with or without one.
        calls.reset()
        func fitting(_ b: ActivityBrowser) -> CGFloat {
            NSHostingView(rootView: DaydreamToolbarRow(browser: b, state: presentation(.recording), actions: calls.actions, width: 560)
                .environment(\.daydreamNow, now)).fittingSize.width
        }
        let downloading = browser()
        downloading.summaries = SummaryAvailability(provider: .local, busy: true, downloadProgress: 0.42)
        check(abs(fitting(downloading) - fitting(browser())) < 0.5, "a summary model download adds no toolbar item",
              "\(fitting(downloading)) vs \(fitting(browser()))")
    }

    static func searchAndStepper() {
        let calls = Calls()
        var commands: [DaydreamCommand] = []
        var bag: [AnyCancellable] = []
        let b = browser()
        b.commands.sink { commands.append($0) }.store(in: &bag)
        let h = row(.recording, calls, browser: b, width: 1172)
        // Search trigger at the centre: sets recallPresented, never query.
        click(h, CGPoint(x: 586, y: 26))
        check(b.recallPresented && b.query.isEmpty, "the search trigger presents Recall and leaves the query empty", "presented \(b.recallPresented) query '\(b.query)'")
        // While Recall is up the trigger is a disabled magnifier and the stepper is disabled: a click writes nothing
        // (an enabled trigger would set recallPresented again, which @Published reports even for the same value).
        b.query = ""
        pump(0.1)
        var presentedWrites = 0
        let watch = b.$recallPresented.dropFirst().sink { _ in presentedWrites += 1 }
        click(h, CGPoint(x: 586, y: 26))
        watch.cancel()
        check(presentedWrites == 0 && b.query.isEmpty, "the collapsed trigger is disabled while Recall is up: a click writes nothing",
              "recallPresented writes \(presentedWrites), query '\(b.query)'")
        click(h, CGPoint(x: 16 + 17, y: 26))
        check(commands.isEmpty, "the day stepper is disabled while Recall is up", "\(commands)")
        b.recallPresented = false
        pump(0.1)
        // Previous day; next is disabled on today.
        click(h, CGPoint(x: 16 + 17, y: 26))
        click(h, CGPoint(x: 16 + 35 + 17, y: 26))
        equal(commands, [.previousDay], "Previous Day sends .previousDay; Next Day is disabled on today")
        commands = []
        b.focusedDay = "2026-09-21"
        pump(0.1)
        click(h, CGPoint(x: 16 + 35 + 17, y: 26))
        equal(commands, [.nextDay], "Next Day sends .nextDay on an earlier day")
        commands = []
        check(calls.total == 0, "search and day controls call no capture action", calls.summary)
        // Without a search backend the trigger is disabled; without canonical days the stepper is.
        let legacy = browser(canonical: false, search: false)
        legacy.commands.sink { commands.append($0) }.store(in: &bag)
        let lh = row(.recording, calls, browser: legacy, width: 1172)
        click(lh, CGPoint(x: 586, y: 26))
        click(lh, CGPoint(x: 16 + 17, y: 26))
        check(!legacy.recallPresented && legacy.query.isEmpty && commands.isEmpty, "legacy mode: search and day controls are disabled",
              "presented \(legacy.recallPresented) commands \(commands)")
        // Narrow: the magnifier still presents Recall.
        let nb = browser()
        let nh = row(.recording, calls, browser: nb, width: 560)
        click(nh, CGPoint(x: 280, y: 26))
        check(nb.recallPresented && nb.query.isEmpty, "at 560 pt the magnifier presents Recall", "presented \(nb.recallPresented)")
    }

    static func fits() {
        let calls = Calls()
        let downloading = browser()
        downloading.summaries = SummaryAvailability(provider: .local, busy: true, downloadProgress: 0.42)
        for c in Case.allCases {
            for (b, tag) in [(browser(), ""), (downloading, ", downloading")] {
                for width in [560, 0] as [CGFloat] {
                    let fit = NSHostingView(rootView: DaydreamToolbarRow(browser: b, state: presentation(c), actions: calls.actions, width: width)
                        .environment(\.daydreamNow, now)).fittingSize
                    check(fit.width <= 560 && abs(fit.height - 52) < 0.5, "\(c.rawValue)\(tag): the row fits 560 pt at width \(Int(width))", "\(fit)")
                }
            }
        }
        // No overlap at 560: clicks across the status group never reach the search, and the magnifier is reachable
        // (centred, or beside the day stepper when centring would touch the status group).
        for c in Case.allCases {
            for dl in [false, true] {
                calls.reset()
                let b = browser()
                if dl { b.summaries = SummaryAvailability(provider: .local, busy: true, downloadProgress: 0.42) }
                let h = row(c, calls, browser: b, width: 560)
                let p = presentation(c)
                // The compact capsule (or the Start Recording pill in its place, with its chevron only with an issue) and the gear.
                let startWidth = NSHostingView(rootView: StartRecordingButton(action: {}, more: p.issue != nil ? {} : nil)).fittingSize.width
                let trailing: CGFloat = (p.state.kind == .off && p.canResume ? startWidth : 32) + 8 + 32
                var x = 560 - 16 - trailing + 2
                while x < 560 - 16 {
                    fastClick(h, CGPoint(x: x, y: 26))
                    x += 4
                }
                pump(0.1)
                closePopovers()
                let tag = "560 \(c.rawValue)\(dl ? ", downloading" : "")"
                check(!b.recallPresented, "\(tag): the search never sits over the status controls")
                b.recallPresented = false
                click(h, CGPoint(x: 280, y: 26))
                if !b.recallPresented { click(h, CGPoint(x: 16 + 69 + 8 + 16, y: 26)) }
                check(b.recallPresented && b.query.isEmpty, "\(tag): the magnifier presents Recall")
                closePopovers()
            }
        }
    }

    /// A click without the settle pump (sweeps).
    static func fastClick(_ view: NSView, _ point: CGPoint) {
        let flipped = view.isFlipped ? point : CGPoint(x: point.x, y: view.bounds.height - point.y)
        let p = view.convert(flipped, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                          pressure: type == .leftMouseDown ? 1 : 0) {
                window.sendEvent(e)
            }
        }
        RunLoop.main.run(until: Date())
    }

    // MARK: Window chrome

    static func windowChrome() {
        check(!WindowConfigurator.savesFrame, "an unbundled process saves no window frame")
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 600, height: 400), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: true)
        let mask = w.styleMask
        WindowConfigurator.configure(w, savesFrame: false)
        check(w.titlebarSeparatorStyle == .none, "WindowConfigurator: no title-bar separator")
        check(w.titlebarAppearsTransparent, "WindowConfigurator: the title bar shows the window colour")
        func rgb(_ appearance: NSAppearance.Name) -> String {
            var out = ""
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                let c = w.backgroundColor.usingColorSpace(.sRGB)!
                out = String(format: "%.3f %.3f %.3f", c.redComponent, c.greenComponent, c.blueComponent)
            }
            return out
        }
        equal(rgb(.aqua), "0.920 0.930 0.945", "WindowConfigurator: light window colour behind the toolbar")
        equal(rgb(.darkAqua), "0.140 0.140 0.140", "WindowConfigurator: dark window colour behind the toolbar")
        check(w.tabbingMode == .disallowed, "WindowConfigurator: no window tabs")
        check(w.styleMask == mask && !w.styleMask.contains(.fullSizeContentView), "WindowConfigurator: never fullSizeContentView")
        check(!w.isMovableByWindowBackground, "WindowConfigurator: never movable by the window background")
        check(w.frameAutosaveName.isEmpty, "WindowConfigurator: no autosave in checks")
    }

    // MARK: Sources

    static func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    static func sources() {
        let dir = "Sources/MemoryUI/"
        let ui = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".swift") }.sorted()
        check(!ui.isEmpty, "Sources/MemoryUI is readable from the worktree")
        let all = ui.map { (name: $0, text: read(dir + $0)) }
        let settings = all.reduce(0) { $0 + $1.text.components(separatedBy: "accessibilityIdentifier(\"memory-settings\")").count - 1 }
        equal(settings, 1, "exactly one memory-settings control")
        equal(all.filter { $0.text.contains("accessibilityIdentifier(\"capture-state\")") }.map(\.name).contains("StatusCapsule.swift"), true,
              "the capsule keeps the capture-state identifier")
        // ux/declutter: the Start pill's chevron only when the popover has an issue to say.
        check(all.contains { $0.name == "DaydreamToolbar.swift" && $0.text.contains("more: ToolbarLayout.startHasMore(state) ? { open.toggle() } : nil")
                             && $0.text.contains("!(state.issue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)")
                             && $0.text.contains("StartRecordingButton.width(more: startHasMore(state))") },
              "the toolbar draws the Start pill's chevron only with an issue, and budgets the pill as drawn")
        equal(all.filter { $0.text.contains("accessibilityIdentifier(\"toolbar-search\")") }.map(\.name), ["DaydreamToolbar.swift"], "toolbar-search identifier")
        // Launch build (perf audit): while recording nothing redraws the capsule. Only a timed pause runs its clock.
        let capsule = read(dir + "StatusCapsule.swift")
        check(capsule.contains("StatusClock(until: state.pauseUntil, ticks: state.pauseUntil != nil)") && capsule.contains("} else if !ticks {"),
              "the capsule runs no clock while recording (only a timed pause ticks)")
        let app = ((try? FileManager.default.contentsOfDirectory(atPath: "Sources/MacMemApp")) ?? []).filter { $0.hasSuffix(".swift") }
        let scripts = ((try? FileManager.default.contentsOfDirectory(atPath: "scripts")) ?? []).filter { $0 != "dd-status-checks.swift" }
        let everywhere = all.map(\.text) + app.map { read("Sources/MacMemApp/" + $0) } + scripts.map { read("scripts/" + $0) }
        check(!everywhere.contains { $0.contains("CaptureStatusControl") }, "CaptureStatusControl has no references")
        let owned = ["DaydreamToolbar.swift", "StatusCapsule.swift", "StatusPopover.swift", "WindowConfigurator.swift"]
        let ownedText = owned.map { read(dir + $0) }
        check(ownedText.allSatisfy { !$0.isEmpty }, "the toolbar sources are readable")
        let code = ownedText.map { $0.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }.joined(separator: "\n") }
        check(!code.contains { $0.contains("Tomorrow") || $0.contains("+15") }, "no Tomorrow or +15 in the toolbar and popover")
        check(!code.contains { $0.contains("ShellButtonStyle") }, "no ShellButtonStyle inside the toolbar")
        check(code.contains { $0.contains("#available(macOS 26") }, "the window toolbar has a macOS 26 glass branch")
        let chrome = code[3] + code[0]
        check(!chrome.contains("fullSizeContentView") && !chrome.contains("isMovableByWindowBackground"),
              "WindowConfigurator and the toolbar never set fullSizeContentView or isMovableByWindowBackground")
        check(!code[0].contains("SummaryDownloadButton") && !code[0].contains("downloadProgress"),
              "the toolbar has no download item (ux/declutter: Settings › Summaries shows the progress)")
        let master = read(dir + "CaptureControls.swift")
        check(master.contains("Paused · nothing is recorded") && !master.contains("nothing is being remembered"), "RecordingMasterControl reads 'Paused · nothing is recorded'")
        check(master.contains("get:{state.recording}") && master.contains("if state.canResume {actions.resume()}") && master.contains("else if state.recording {actions.pause(0)}"),
              "RecordingMasterControl keeps its toggle semantics")
    }

    // MARK: Composite window toolbar

    /// `MemoryShell(chrome: .windowToolbar)` bridged into a real unified toolbar. The scene's style
    /// (`.unified(showsTitle: false)`) is set before the controller is hosted, as a WindowGroup does: NSToolbar never
    /// recovers its item layout from a style or title change made after its items exist.
    @available(macOS 14, *)
    static func toolbarWindow(_ c: Case, browser b: ActivityBrowser, calls: Calls, width: CGFloat) -> NSWindow {
        let shell = MemoryShell(browser: b, state: presentation(c), actions: calls.actions, chrome: .windowToolbar)
            .environment(\.daydreamNow, now).environment(\.daydreamStatic, true)
        let controller = NSHostingController(rootView: AnyView(shell))
        controller.sceneBridgingOptions = [.toolbars, .title]
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -3000, width: width, height: 400),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.toolbarStyle = .unified
        w.titleVisibility = .hidden
        w.contentViewController = controller
        w.setContentSize(NSSize(width: width, height: 400))
        w.setFrameOrigin(NSPoint(x: -4000, y: -3000))
        w.orderFrontRegardless()
        return w
    }

    struct ToolbarReport {
        var items = 0, hidden: [String] = [], principal: CGRect?, trailing: [CGRect] = []
        var summary: String {
            "items \(items), hidden \(hidden), principal \(principal.map { "\(Int($0.minX))..\(Int($0.maxX))" } ?? "-"), "
                + "trailing \(trailing.map { "\(Int($0.minX))..\(Int($0.maxX))" })"
        }
    }

    /// Visibility and frames (window coordinates) of the toolbar items: the centred (principal) item, and the item
    /// views right of it (download, Start Recording, capsule, gear).
    @available(macOS 14, *)
    static func toolbarReport(_ w: NSWindow) -> ToolbarReport {
        var r = ToolbarReport()
        guard let toolbar = w.toolbar else { return r }
        r.items = toolbar.items.count
        let centred = toolbar.centeredItemIdentifiers
        var viewed: [(id: NSToolbarItem.Identifier, frame: CGRect)] = []
        for item in toolbar.items {
            if !item.isVisible { r.hidden.append(String(item.itemIdentifier.rawValue.suffix(12))) }
            if let v = item.view, v.window === w { viewed.append((item.itemIdentifier, v.convert(v.bounds, to: nil))) }
        }
        r.principal = viewed.first { centred.contains($0.id) }?.frame
        let edge = r.principal?.maxX ?? (w.contentView?.bounds.width ?? 0) / 2
        r.trailing = viewed.map(\.frame).filter { $0.minX >= edge }.sorted { $0.minX < $1.minX }
        return r
    }

    static func composite() {
        guard #available(macOS 14, *) else { print("LIMIT: composite toolbar check needs macOS 14"); return }
        compositeLook()
        compositeCapsule()
        compositeLiveDot()
        compositeWidths()
    }

    /// Every item stays in the toolbar (none in the overflow menu) at every width the window allows, in a window
    /// opened at that width and while one window is resized down to the minimum and back; the search field stays
    /// centred on the window; the capsule and the gear are separate items.
    @available(macOS 14, *)
    static func compositeWidths() {
        let calls = Calls()
        let widths: [CGFloat] = [560, 600, 640, 680, 700, 720, 760, 900, 1172]
        func assess(_ w: NSWindow, _ c: Case, download: Bool, _ tag: String) {
            let r = toolbarReport(w)
            let p = presentation(c)
            // ux/declutter: the capsule (Off and able to start: the Start Recording pill in its place) and the gear.
            _ = p
            let expected = 2
            let width = w.contentView?.bounds.width ?? 0
            check(r.items >= 2 + expected && r.hidden.isEmpty, "\(tag): every toolbar item is in the toolbar, none in overflow", r.summary)
            check(r.trailing.count == expected, "\(tag): the status controls are \(expected) separate items", r.summary)
            let overlaps = zip(r.trailing, r.trailing.dropFirst()).contains { $0.maxX > $1.minX + 0.5 }
            check(!overlaps && r.trailing.last.map { $0.maxX <= width } ?? false, "\(tag): the capsule and the gear have their own frames, inside the window",
                  r.summary)
            if let field = r.principal, field.width > 40 {
                check(abs(field.midX - width / 2) <= 2, "\(tag): the search field is centred on the window", "\(field.midX) vs \(width / 2)")
            }
        }
        var tags = 0
        for (c, download) in [(Case.recording, false), (.off, false), (.pausedTimed, false), (.needsInputMonitoring, false),
                              (.recording, true), (.off, true)] {
            let dl = download ? ", downloading" : ""
            for width in widths {
                let b = browser()
                if download { b.summaries = SummaryAvailability(provider: .local, busy: true, downloadProgress: 0.42) }
                let w = toolbarWindow(c, browser: b, calls: calls, width: width)
                pump(0.7)
                assess(w, c, download: download, "window toolbar \(c.rawValue)\(dl) at \(Int(width)) pt")
                w.orderOut(nil); w.contentViewController = nil
                tags += 1
            }
            // One window, resized 1172 → 560 → 1172.
            let b = browser()
            if download { b.summaries = SummaryAvailability(provider: .local, busy: true, downloadProgress: 0.42) }
            let w = toolbarWindow(c, browser: b, calls: calls, width: 1172)
            pump(0.7)
            for width in widths.reversed() + widths.dropFirst() {
                w.setContentSize(NSSize(width: width, height: 400))
                pump(0.35)
                assess(w, c, download: download, "window toolbar \(c.rawValue)\(dl), resized to \(Int(width)) pt")
            }
            w.orderOut(nil); w.contentViewController = nil
        }
        equal(calls.total, 0, "window toolbar: \(tags) windows and 6 resize sequences call nothing")
    }

    /// The capsule in the window toolbar opens its popover (state kept outside the toolbar item) and draws its
    /// pressed fill while it is open, also over macOS 26 glass; opening and closing call nothing.
    @available(macOS 14, *)
    static func compositeCapsule() {
        let calls = Calls()
        let w = toolbarWindow(.recording, browser: browser(), calls: calls, width: 1172)
        pump(0.8)
        let r = toolbarReport(w)
        guard r.trailing.count == 2, let theme = w.contentView?.superview else {
            check(false, "window toolbar: the capsule and the gear are found", r.summary); w.orderOut(nil); return
        }
        let capsule = r.trailing[0]
        func level() -> Double? {
            guard let rep = theme.bitmapImageRepForCachingDisplay(in: theme.bounds) else { return nil }
            theme.cacheDisplay(in: theme.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / max(1, theme.bounds.width)
            // Theme-frame coordinates are flipped against the window's: y from the top.
            let top = theme.bounds.height - capsule.maxY
            var sum = 0.0, n = 0
            // The capsule's right half, between the label and the chevron, clear of the red glyph.
            for y in stride(from: top + 6, to: top + capsule.height - 6, by: 1) {
                for x in stride(from: capsule.midX + 4, to: capsule.maxX - 30, by: 1) {
                    guard let c = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) else { continue }
                    // Skip label ink.
                    let l = (c.redComponent + c.greenComponent + c.blueComponent) / 3
                    if abs(l - 0.5) < 0.35 { continue }
                    sum += l; n += 1
                }
            }
            return n > 20 ? sum / Double(n) : nil
        }
        let before = level()
        let centre = NSPoint(x: capsule.minX + 24, y: capsule.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: centre, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                w.sendEvent(e)
            }
        }
        pump(0.5)
        let opened = NSApp.windows.contains { $0 !== w && $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
        if !opened {
            print("LIMIT: the window-toolbar capsule's popover did not open offscreen; checked for callbacks only")
        } else {
            check(true, "window toolbar: the capsule opens its popover")
            let after = level()
            let dark = w.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if let before, let after {
                check(dark ? after > before + 0.02 : after < before - 0.02, "window toolbar: the open capsule draws its pressed fill",
                      String(format: "level %.3f → %.3f (%@)", before, after, dark ? "dark" : "light"))
            } else {
                print("LIMIT: the capsule's pixels were not readable offscreen")
            }
        }
        check(calls.total == 0, "window toolbar: opening the capsule's popover calls nothing", calls.summary)
        for p in NSApp.windows where p !== w && p.isVisible && String(describing: type(of: p)).contains("Popover") { p.orderOut(nil) }
        pump(0.2)
        w.orderOut(nil); w.contentViewController = nil
    }

    final class LiveFlip: ObservableObject { @Published var recording = false; @Published var ready = true }
    struct LiveShell: View {
        @ObservedObject var flip: LiveFlip
        let browser: ActivityBrowser
        let actions: CaptureActions
        var body: some View {
            // As DaydreamMainWindowContent: "Getting ready…" first, then the memory window; no daydreamStatic, so
            // the dot draws with live motion, as in the app.
            if flip.ready {
                MemoryShell(browser: browser, state: presentation(flip.recording ? .recording : .pausedOpen), actions: actions, chrome: .windowToolbar)
                    .environment(\.daydreamNow, now)
            } else {
                Text("Getting ready…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The red dot's centre relative to the label's words (their left edge and vertical middle) inside the capsule's
    /// toolbar item, in points; nil when either isn't drawn.
    static func dotBesideLabel(_ theme: NSView, item: CGRect) -> CGPoint? {
        guard let rep = theme.bitmapImageRepForCachingDisplay(in: theme.bounds) else { return nil }
        theme.cacheDisplay(in: theme.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / max(1, theme.bounds.width)
        let top = theme.bounds.height - item.maxY
        var dx = 0.0, dy = 0.0, dn = 0.0, inkMinX = CGFloat.greatestFiniteMagnitude, inkY = 0.0, inkN = 0.0
        // The item and 12 pt around it: a dot that left the capsule is still found.
        let x0 = max(0, Int((item.minX - 12) * scale)), x1 = min(rep.pixelsWide, Int((item.maxX + 12) * scale))
        let y0 = max(0, Int((top - 12) * scale)), y1 = min(rep.pixelsHigh, Int((top + item.height + 12) * scale))
        guard x0 < x1, y0 < y1 else { return nil }
        for y in y0..<y1 { for x in x0..<x1 {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 else { continue }
            if c.redComponent > 0.85 && c.greenComponent < 0.45 && c.blueComponent < 0.45 { dx += Double(x); dy += Double(y); dn += 1 }
            let l = (c.redComponent + c.greenComponent + c.blueComponent) / 3
            let dark = w(isDark: theme) ? l > 0.7 : l < 0.5
            if dark && abs(c.redComponent - c.blueComponent) < 0.1 && x >= Int(item.minX * scale) && x <= Int(item.maxX * scale) {
                inkMinX = min(inkMinX, CGFloat(x)); inkY += Double(y); inkN += 1
            }
        } }
        guard dn > 0, inkN > 0 else { return nil }
        return CGPoint(x: (dx / dn - Double(inkMinX)) / Double(scale), y: (dy / dn - inkY / inkN) / Double(scale))
    }
    static func w(isDark v: NSView) -> Bool { v.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    /// The capsule's glyph end (its first 40 pt, the item's full height) as sRGB bytes, and the halo's pixel count in it
    /// (soft red around the core); nil when unreadable.
    static func glyphPatch(_ theme: NSView, item: CGRect) -> (bytes: [UInt8], halo: Int)? {
        guard let rep = theme.bitmapImageRepForCachingDisplay(in: theme.bounds) else { return nil }
        theme.cacheDisplay(in: theme.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / max(1, theme.bounds.width)
        let top = theme.bounds.height - item.maxY
        let x0 = max(0, Int(item.minX * scale)), x1 = min(rep.pixelsWide, Int((item.minX + 40) * scale))
        let y0 = max(0, Int(top * scale)), y1 = min(rep.pixelsHigh, Int((top + item.height) * scale))
        guard x0 < x1, y0 < y1 else { return nil }
        var bytes: [UInt8] = [], halo = 0
        bytes.reserveCapacity((x1 - x0) * (y1 - y0) * 4)
        for y in y0..<y1 { for x in x0..<x1 {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { bytes += [0, 0, 0, 0]; continue }
            bytes += [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map { UInt8(max(0, min(255, ($0 * 255).rounded()))) }
            let core = c.alphaComponent > 0.9 && c.redComponent > 0.85 && c.greenComponent < 0.45 && c.blueComponent < 0.45
            if !core && c.redComponent - c.blueComponent > 0.08 && c.redComponent - c.greenComponent > 0.06 { halo += 1 }
        } }
        return (bytes, halo)
    }

    /// In the real window toolbar (NSHostingController bridging the toolbar, as the app's WindowGroup does), with live
    /// motion, light and dark: Recording turned on from a pause, and the window arriving already recording. The dot
    /// keeps one place beside "Recording" in every frame for 2 s, left of the words and on their line; from 1 s on (the
    /// toolbar's own spring settled) the glyph's pixels, core and halo, are identical in every frame: the dot is solid.
    @available(macOS 14, *)
    static func compositeLiveDot() {
        let calls = Calls()
        for dark in [false, true] { for arrive in [false, true] {
            let tag = (arrive ? "window toolbar, arriving while recording" : "window toolbar, Recording turned on") + (dark ? " (dark)" : " (light)")
            let flip = LiveFlip()
            if arrive { flip.recording = true; flip.ready = false }
            let controller = NSHostingController(rootView: LiveShell(flip: flip, browser: browser(), actions: calls.actions))
            controller.sceneBridgingOptions = [.toolbars, .title]
            let w = NSWindow(contentRect: NSRect(x: -4000, y: -3000, width: 1000, height: 400),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            w.toolbarStyle = .unified
            w.titleVisibility = .hidden
            w.contentViewController = controller
            w.setContentSize(NSSize(width: 1000, height: 400))
            w.setFrameOrigin(NSPoint(x: -4000, y: -3000))
            w.orderFrontRegardless()
            pump(0.8)
            if arrive { flip.ready = true } else { flip.recording = true }
            var spots: [CGPoint] = [], frames = 0, patches: [[UInt8]] = [], halos: [Int] = []
            let t0 = Date()
            while Date().timeIntervalSince(t0) < 2.0 {
                pump(0.06); frames += 1
                let r = toolbarReport(w)
                guard let item = r.trailing.first, let theme = w.contentView?.superview else { continue }
                if let p = dotBesideLabel(theme, item: item) { spots.append(p) }
                if Date().timeIntervalSince(t0) > 1.0, let patch = glyphPatch(theme, item: item) { patches.append(patch.bytes); halos.append(patch.halo) }
            }
            w.orderOut(nil); w.contentViewController = nil
            guard spots.count >= frames / 2 else {
                print("LIMIT: \(tag): the capsule's dot and words were readable in \(spots.count) of \(frames) frames"); continue
            }
            let xs = spots.map(\.x), ys = spots.map(\.y)
            let travel = max((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
            check(travel <= 0.75, "\(tag): the live dot keeps one place in every frame", String(format: "travelled %.2f pt over %d frames", travel, spots.count))
            check(spots.allSatisfy { $0.x < -4 && abs($0.y) <= 3 }, "\(tag): the live dot sits left of \"Recording\", on its line",
                  spots.prefix(4).map { String(format: "(%.1f, %.1f)", $0.x, $0.y) }.joined(separator: " "))
            check(patches.count >= 8, "\(tag): the settled glyph was read in enough frames", "\(patches.count)")
            check((halos.min() ?? 0) > 0, "\(tag): the dot's soft halo is drawn", "\(halos.prefix(3))")
            check(Set(patches).count == 1, "\(tag): the solid dot is the same in every frame (no breathing halo)",
                  "\(Set(patches).count) distinct glyphs over \(patches.count) frames; halo px \(Set(halos).sorted())")
        } }
        equal(calls.total, 0, "window toolbar: the live-dot frames call nothing")
    }

    @available(macOS 14, *)
    static func compositeLook() {
        let calls = Calls()
        let b = browser()
        let w = toolbarWindow(.recording, browser: b, calls: calls, width: 1172)
        w.setContentSize(NSSize(width: 1172, height: 600))
        pump(0.8)
        let items = w.toolbar?.items ?? []
        let theme = w.contentView?.superview
        var ink = 0
        if let theme, let rep = theme.bitmapImageRepForCachingDisplay(in: theme.bounds) {
            theme.cacheDisplay(in: theme.bounds, to: rep)
            let top = min(rep.pixelsHigh, Int(Double(rep.pixelsHigh) * 60 / Double(max(1, theme.bounds.height))))
            for y in stride(from: 0, to: top, by: 2) { for x in stride(from: 0, to: rep.pixelsWide, by: 4) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { ink += 1 } }
            // The band between the stepper and the search, the row under the toolbar, and empty content: one colour.
            let scale = CGFloat(rep.pixelsWide) / max(1, theme.bounds.width)
            let bar = theme.bounds.height - 600
            func px(_ x: CGFloat, _ y: CGFloat) -> String {
                guard let c = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) else { return "?" }
                return String(format: "%.2f %.2f %.2f", c.redComponent, c.greenComponent, c.blueComponent)
            }
            if ink > 0 {
                let band = px(260, 8), under = px(260, bar - 1), content = px(260, theme.bounds.height - 20)
                check(band == content && under == content, "composite: the toolbar sits on the window colour with no separator",
                      "band \(band), under \(under), content \(content)")
                // The capsule's red Recording glyph, drawn in the toolbar band beside the gear (the item's identifier is not
                // readable offscreen; its pixels are).
                var red = 0
                for y in stride(from: 0, to: bar, by: 1) {
                    for x in stride(from: theme.bounds.width - 260, to: theme.bounds.width - 16, by: 1) {
                        guard let c = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) else { continue }
                        if c.redComponent > 0.8 && c.greenComponent < 0.45 && c.blueComponent < 0.45 { red += 1 }
                    }
                }
                check(red > 4, "composite: the status capsule draws in the window toolbar (its Recording glyph)", "\(red) red pixels")
            }
            if let dir = ProcessInfo.processInfo.environment["DD_CHECK_OUT"], let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("composite-toolbar.png"))
            }
        }
        if items.isEmpty || ink == 0 {
            print("LIMIT: the bridged window toolbar did not capture offscreen (items \(items.count), ink \(ink)); toolbar composition verified in sources")
        } else {
            check(items.count >= 3, "the window toolbar has the stepper, search and status items", "\(items.count)")
            // The capture-state identifier, where AppKit exposes it.
            var found = false
            func walk(_ v: NSView) { if v.accessibilityIdentifier() == "capture-state" { found = true }; v.subviews.forEach(walk) }
            if let theme { walk(theme) }
            for item in items { if let v = item.view { walk(v) } }
            var ax: [NSAccessibilityProtocol] = []
            func tree(_ e: Any, _ depth: Int) {
                guard depth < 40, let el = e as? NSAccessibilityProtocol else { return }
                ax.append(el)
                for c in el.accessibilityChildren() ?? [] { tree(c, depth + 1) }
            }
            if let theme { tree(theme, 0) }
            if ax.contains(where: { $0.accessibilityIdentifier() == "capture-state" }) { found = true }
            if found { check(true, "a toolbar item carries the capture-state identifier") }
            else { print("LIMIT: toolbar item identifiers not exposed offscreen (\(items.count) items bridged); identifier verified in sources") }
        }
        check(w.styleMask.contains(.fullSizeContentView) == false, "composite: the window keeps content below the toolbar")
        check(w.titlebarSeparatorStyle == .none && w.tabbingMode == .disallowed, "composite: WindowConfigurator configured the window")
        equal(calls.total, 0, "composite: hosting the window toolbar calls nothing")
        w.orderOut(nil); w.contentViewController = nil
    }
}
