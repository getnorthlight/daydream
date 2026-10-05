// DD-RECIPE: APP
//
// A5 settings status line and overview (plan §5 A5, amendments A5; ux/declutter). Values only: a fixed clock
// and time zone (Tuesday 2026-09-22 4:21 PM, Los Angeles), fixture snapshots, views hosted offscreen; plus
// one recording-trial model on an empty private store under DD_CHECK_OUT to pin the app's wiring.
//  - Line text: the state lines (and the Needs Permission variants) and the orange issue line. ux/declutter
//    cut today's numbers, the week, the usage bars, the store size and Show in Finder from Settings: the
//    main window shows the day, and Help › Report a Problem reports the size.
//  - Laid-out elements (`SettingsStatusCardElements`): the state line always, the issue line only with an
//    issue, at most one button (ux/declutter review), the one action that fits the line: Allow… for Needs
//    Permission (the Permissions page, DayDream's drag cards, as the menu bar's Allow…; never System Settings
//    on its own and never a permission request), Start Recording (Off), Resume Recording (Paused), or the page
//    or folder that fixes an issue; one height in every state without an issue line.
//  - Click sweeps: every click calls at most one closure; the button calls its one action; rendering and
//    hovering call nothing. The overview, in the real 720×540 settings sheet, shows its four rows above the
//    scroll fade in every state, no status line while recording with nothing to act on, its privacy line
//    with Learn more (the FileVault clause only when FileVault is known to be off), and its clicks only navigate
//    (Advanced… and Allow… too), open Learn more, or run the status line's one action.
//  - The frame's header (ux/v1): Back answers a click anywhere in its 34 pt square (center and ±10 pt), ⌘[
//    presses it, the title beside it calls nothing; Done closes; the overview has Advanced… and no Back.
//    Setup's Back answers across its whole box too. The sheet's height fits a 13-inch MacBook Air.
//  - Sources: no Pause, Stop or other capture controls, day numbers, store size or Show in Finder in the line,
//    the overview or the app's overview host (Start and Resume Recording only as the line's one button, through
//    the app's one start call), and no lifetime moment total anywhere in them.
//  - storeBytes: memory.sqlite + -wal + -shm only (never a directory walk), nil on failure.
// Nothing starts or resumes capture (the start button is pressed only into a recording closure), nothing
// opens an app, Finder or System Settings, and no permission is requested.
import AppKit
import SwiftUI
import MemoryCore
import MemoryUI

@MainActor final class StatusCalls {
    var pages: [DaydreamSettingsPage] = []
    /// The status line's other button (start, resume, the Applications folder); a page it opens lands in `pages`.
    var actions: [SettingsStatusAction] = []
    var learnMore = 0
    var closes = 0
    var total: Int { pages.count + actions.count + learnMore + closes }
    func reset() { pages = []; actions = []; learnMore = 0; closes = 0 }
}

enum Fx {
    static let zone = TimeZone(identifier: "America/Los_Angeles")!
    static var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = zone; return c }
    static func at(_ day: Int, _ hour: Int, _ minute: Int, month: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }
    static let now = at(22, 16, 21)
    static let local = SummaryAvailability(provider: .local, busy: false)
    static let off = SummaryAvailability(provider: .off, busy: false)
    static let both = PermissionSnapshot(accessibility: true, inputMonitoring: true)
    static let exclusions = ExclusionSummary(
        alwaysPrivate: ["com.1password.1password", "com.apple.Passwords", "com.apple.keychainaccess", "com.bitwarden.desktop", "com.lastpass.LastPass"],
        excludedByYou: ["com.spotify.client", "com.apple.Music", "com.valvesoftware.steam"])
    static func snapshot(_ state: RecordingState, issue: String? = nil, summaries: SummaryAvailability = local,
                         permissions: PermissionSnapshot? = both, canResume: Bool = true) -> SettingsStatusSnapshot {
        SettingsStatusSnapshot(state: state, issue: issue, permissions: permissions, summaries: summaries, exclusions: exclusions, connections: nil,
                               canResume: canResume)
    }
    static let recording = RecordingState.recording(since: at(22, 8, 40))
    static let pausedTimed = RecordingState.paused(until: now.addingTimeInterval(900), since: at(22, 16, 10), reason: nil)
    static let offPlain = RecordingState.off(since: nil, reason: nil)
    static let offBlocked = RecordingState.off(since: nil, reason: "Finish setup to start recording.")
    static let needsInput = RecordingState.needsPermission(missing: [.inputMonitoring])
}

/// The hosted root's frame in the same global space the card reports its elements in.
struct RootFrameKey: PreferenceKey {
    static var defaultValue: CGRect { .zero }
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { let next = nextValue(); if next != .zero { value = next } }
}

@MainActor @main enum DDSettingsStatusChecks {
    static var failures = 0
    static var passes = 0
    static func check(_ ok: Bool, _ name: String, _ got: @autoclosure () -> String = "") {
        if ok { passes += 1; print("PASS " + name) } else {
            failures += 1
            print("FAIL: " + name + (got().isEmpty ? "" : " (got: " + got() + ")"))
        }
        fflush(stdout)
    }
    static func equal<T: Equatable>(_ got: T, _ want: T, _ name: String) { check(got == want, name, "\(got)") }

    static func model(_ s: SettingsStatusSnapshot) -> SettingsStatusCardModel {
        SettingsStatusCardModel(s, calendar: Fx.calendar, now: Fx.now)
    }

    /// A line's width as the card draws it (system font, monospaced digits).
    static func textWidth(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)]).size().width)
    }

    // MARK: Hosting

    static let window: NSWindow = {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 760, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        w.acceptsMouseMovedEvents = true
        w.orderFrontRegardless()
        return w
    }()
    static func pump(_ s: Double = 0.15) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    static var elements: [String: SettingsStatusCardElement] = [:]
    static var rootFrame = CGRect.zero
    static var hoverEvents = 0

    /// An element's frame relative to the hosted root (the card's own bounds).
    static func local(_ key: String) -> CGRect? {
        elements[key].map { $0.frame.offsetBy(dx: -rootFrame.minX, dy: -rootFrame.minY) }
    }

    @discardableResult
    static func host<V: View>(_ view: V, size: NSSize) -> NSHostingView<AnyView> {
        elements = [:]
        rootFrame = .zero
        let h = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(GeometryReader { Color.clear.preference(key: RootFrameKey.self, value: $0.frame(in: .global)) })
            .onContinuousHover { _ in hoverEvents += 1 }
            .onPreferenceChange(SettingsStatusCardElements.self) { elements = $0 }
            .onPreferenceChange(RootFrameKey.self) { rootFrame = $0 }
            .environment(\.daydreamNow, Fx.now).environment(\.daydreamStatic, true)))
        window.setContentSize(size)
        window.contentView = h
        h.frame = NSRect(origin: .zero, size: size)
        pump(); h.layoutSubtreeIfNeeded(); pump(0.05)
        return h
    }

    /// The card's width in the settings sheet (the sheet less the frame's side margins).
    static let cardWidth = DaydreamSettingsLayout.width - 2 * DaydreamSettingsLayout.horizontalPadding
    static func card(_ s: SettingsStatusSnapshot, _ calls: StatusCalls, width: CGFloat = cardWidth) -> NSHostingView<AnyView> {
        let view = SettingsStatusCard(s, calendar: Fx.calendar, act: { calls.actions.append($0) })
        let probe = NSHostingView(rootView: view.frame(width: width).environment(\.daydreamNow, Fx.now))
        return host(view, size: NSSize(width: width, height: max(40, ceil(probe.fittingSize.height))))
    }

    /// A mouse down and up at a window point. The up is queued first, so an AppKit control that tracks
    /// the mouse in its own loop (a link-style button) finds it instead of waiting for the window server.
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

    /// One click at `point` in the hosted root's top-left coordinates. Returns the closure calls it made.
    @discardableResult
    static func click(_ view: NSView, _ calls: StatusCalls, at point: CGPoint) -> Int {
        let before = calls.total
        let inView = view.isFlipped ? NSPoint(x: point.x, y: point.y) : NSPoint(x: point.x, y: view.bounds.height - point.y)
        send(click: view.convert(inView, to: nil))
        pump(0.03)
        return calls.total - before
    }

    /// Clicks the center of a laid-out element; returns the closure calls it made.
    static func press(_ view: NSView, _ calls: StatusCalls, _ key: String) -> Int {
        guard let frame = local(key) else { return -1 }
        return click(view, calls, at: CGPoint(x: frame.midX, y: frame.midY))
    }

    /// A coarse grid of clicks over the whole view (the controls themselves are pressed directly).
    static func clickSweep(_ view: NSView, _ calls: StatusCalls, step: CGFloat = 14) -> (clicks: Int, worst: Int) {
        var clicks = 0, worst = 0
        let b = view.bounds
        var y = b.minY + 2
        while y < b.maxY {
            var x = b.minX + 2
            while x < b.maxX {
                let before = calls.total
                send(click: view.convert(NSPoint(x: x, y: y), to: nil))
                RunLoop.main.run(until: Date())
                clicks += 1
                worst = max(worst, calls.total - before)
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

    /// Entered + moved events to the hosting view's tracking areas (the window server never routes hover
    /// to an offscreen window). Returns the moves sent and the hover events SwiftUI delivered to the root.
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
                x += 24
            }
            y += 12
        }
        if entered { enterExit(.mouseExited, last) }
        pump(0.1)
        return (moves, hoverEvents - before)
    }

    // MARK: Main

    static func main() async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
            FileHandle.standardError.write(Data("FAIL: dd-settings-status-checks watchdog expired after 300s\n".utf8))
            exit(2)
        }
        // Codex's shared roots, spelled so run-checks.sh's rewrite of the literal prefix leaves them intact.
        let shared = ["/private/tmp/" + "day" + "dream-", "/tmp/" + "day" + "dream-"]
        guard let outPath = ProcessInfo.processInfo.environment["DD_CHECK_OUT"], outPath.hasPrefix("/"),
              !shared.contains(where: { outPath.hasPrefix($0) }) else {
            print("FAIL: DD_CHECK_OUT is not a private output directory; run this check through run-checks.sh")
            exit(1)
        }
        let out = URL(fileURLWithPath: outPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        stateLines()
        storage(out)
        rows()
        noLifetimeTotal()
        laidOut()
        sweeps()
        overview()
        frameButtons()
        sheetHeight()
        sources()
        await appHost(out)
        window.orderOut(nil)
        if failures > 0 {
            print("FAIL: \(failures) settings status checks failed")
            exit(1)
        }
        print("PASS: \(passes) settings status checks; state line, at most one button (Allow… for Needs Permission opens Permissions, else the line's one action), frame header, sheet height, no day numbers, store size, Pause or Stop, or lifetime total, store size from three files")
    }

    // MARK: Line text

    static func stateLines() {
        // ux/declutter: Recording has no detail (its start time is trivia); the rest say what to do.
        let lines: [(RecordingState, String)] = [
            (Fx.recording, "Recording"),
            (Fx.pausedTimed, "Paused · Until 4:36 PM"),
            (Fx.offPlain, "Off"),
            (Fx.needsInput, "Turn on Input Monitoring"),   // perm-1004: the title names it
            (Fx.offBlocked, "Off · Finish setup to start recording."),
        ]
        for (state, line) in lines {
            equal(model(Fx.snapshot(state)).stateLine, line, "state line: " + line)
        }
        equal(model(Fx.snapshot(.recording(since: nil))).stateLine, "Recording", "state line: Recording with an unknown start")
        equal(model(Fx.snapshot(.paused(until: nil, since: nil, reason: nil))).stateLine, "Paused · Until you resume",
              "state line: an open-ended pause")
        equal(model(Fx.snapshot(.paused(until: nil, since: nil, reason: "Paused while your Mac slept."))).stateLine,
              "Paused · While your Mac slept.", "state line: a pause reason never says Paused twice")
        equal(model(Fx.snapshot(.needsPermission(missing: [.accessibility]))).stateLine, "Turn on Accessibility",
              "state line: Accessibility missing")
        equal(model(Fx.snapshot(.needsPermission(missing: [.accessibility, .inputMonitoring]))).stateLine,
              "Turn on Accessibility · Input Monitoring is off too", "state line: both missing")
        equal(model(Fx.snapshot(.needsPermission(missing: []))).stateLine,
              "Needs Permission · Accessibility and Input Monitoring are required", "state line: an unknown missing set")
        check(model(Fx.snapshot(Fx.needsInput)).stateNeedsAttention && !model(Fx.snapshot(Fx.recording)).stateNeedsAttention,
              "only Needs Permission draws the state word orange")
        equal(model(Fx.snapshot(Fx.pausedTimed, issue: "Summaries could not be saved.")).accessibilityLabel,
              "DayDream, Paused · Until 4:36 PM. Summaries could not be saved.", "VoiceOver reads the state line, then the issue")

        // ux/declutter review: at most one button, the one that acts on the line. Off: Start Recording (its detail
        // no longer points elsewhere); Paused: Resume Recording; an issue a page or folder fixes: that page or
        // folder; a blocker nothing here fixes: none; Recording with nothing to act on: none, and the overview
        // draws no card at all (`quiet`).
        func button(_ s: SettingsStatusSnapshot) -> SettingsStatusButton? { model(s).button }
        equal(button(Fx.snapshot(Fx.offPlain)), SettingsStatusButton("Start Recording", .start), "Off: Start Recording")
        equal(button(Fx.snapshot(Fx.pausedTimed)), SettingsStatusButton("Resume Recording", .resume), "Paused: Resume Recording")
        equal(button(Fx.snapshot(Fx.pausedTimed, canResume: false)), nil, "Paused while something blocks a start: no Resume")
        equal(button(Fx.snapshot(Fx.offBlocked)), nil, "Off for a reason nothing here fixes: no button")
        equal(button(Fx.snapshot(Fx.recording)), nil, "Recording: no button")
        check(model(Fx.snapshot(Fx.recording)).quiet && !model(Fx.snapshot(Fx.recording, issue: "Memory read failed")).quiet
              && !model(Fx.snapshot(Fx.offPlain)).quiet && !model(Fx.snapshot(Fx.needsInput)).quiet,
              "only Recording with nothing to act on is quiet")
        equal(button(Fx.snapshot(Fx.needsInput)), SettingsStatusButton("Allow…", .open(.permissions)),
              "Needs Permission: Allow… opens Permissions (DayDream's drag cards)")
        equal(button(Fx.snapshot(.off(since: nil, reason: RecordingCopy.moveToApplications), issue: "Move DayDream to Applications first", canResume: false)),
              SettingsStatusButton("Open Applications Folder", .openApplications), "the download window: Open Applications Folder")
        equal(button(Fx.snapshot(.off(since: nil, reason: "Review the replacement in Settings before recording."), issue: "Review replacement", canResume: false)),
              SettingsStatusButton("Open Advanced", .open(.advanced)), "a replacement to review: Open Advanced")
        equal(button(Fx.snapshot(Fx.offPlain, issue: RecordingCopy.choicesUnsaved)),
              SettingsStatusButton("Open Apps to remember", .open(.apps)), "unsaved app choices: Open Apps to remember")
        // gold/r2-copy-checks: the history upkeep and a failed deletion: Try Again runs the job (Summaries can't fix the
        // upkeep); a history set aside at launch: Backup and restore, as the menu bar's line.
        equal(button(Fx.snapshot(Fx.recording, issue: "Summary writer needs attention")), SettingsStatusButton("Try Again", .retry),
              "the history upkeep: Try Again")
        equal(button(Fx.snapshot(Fx.pausedTimed, issue: "Deletion failed")), SettingsStatusButton("Try Again", .retry),
              "a failed deletion: Try Again")
        equal(button(Fx.snapshot(Fx.recording, issue: MenuBarMenu.historySetAsideLine)), SettingsStatusButton("Open Backup and restore", .open(.backup)),
              "history set aside at launch: Open Backup and restore")
        equal(button(Fx.snapshot(Fx.recording, issue: "Memory read failed")), nil, "an issue nothing here fixes: the line stands alone")
        equal(button(Fx.snapshot(Fx.offPlain, issue: "Memory read failed")), SettingsStatusButton("Start Recording", .start),
              "Off with an unrelated issue still offers Start Recording")

        // Integration (ux/v1 drag cards, ux/menubar Allow…): Needs Permission's one button is Allow…, which opens the
        // Permissions page with DayDream's drag cards, whatever is missing and whatever the issue. No state's button
        // opens System Settings on its own or asks macOS for a permission.
        for missing in [[PermissionKind.inputMonitoring], [.accessibility], [.accessibility, .inputMonitoring], []] as [Set<PermissionKind>] {
            equal(button(Fx.snapshot(.needsPermission(missing: missing))), SettingsStatusButton("Allow…", .open(.permissions)),
                  "Needs Permission (\(missing.count) missing): Allow… opens Permissions")
        }
        equal(button(Fx.snapshot(Fx.needsInput, issue: "Summary writer needs attention")), SettingsStatusButton("Allow…", .open(.permissions)),
              "Needs Permission with another issue: still Allow… first")
        for state in [Fx.recording, Fx.pausedTimed, Fx.offPlain, Fx.offBlocked] {
            check(button(Fx.snapshot(state))?.action != .open(.permissions), "no Allow… button: \(state.kind.title)")
        }

        // The operational issue is its own orange line unless the state already says it.
        equal(model(Fx.snapshot(Fx.recording, issue: "Summaries could not be saved.")).attention, "Summaries could not be saved.",
              "an operational issue shows as the attention line")
        equal(model(Fx.snapshot(Fx.needsInput, issue: RecordingCopy.permissionBlocker)).attention, nil,
              "the permission blocker is not repeated as an attention line")
        equal(model(Fx.snapshot(Fx.offBlocked, issue: "Finish setup to start recording.")).attention, nil,
              "a blocker the Off line already says is not repeated")
        equal(model(Fx.snapshot(Fx.recording)).attention, nil, "no issue, no attention line")
    }

    // MARK: Storage (Report a Problem)

    static func storage(_ out: URL) {
        let fm = FileManager.default
        let root = out.appendingPathComponent("store-" + UUID().uuidString, isDirectory: true)
        func write(_ name: String, _ bytes: Int, in dir: URL) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data(count: bytes))
        }
        let full = root.appendingPathComponent("full", isDirectory: true)
        write("memory.sqlite", 1_000, in: full); write("memory.sqlite-wal", 200, in: full); write("memory.sqlite-shm", 32, in: full)
        write("big.gguf", 300_000, in: full.appendingPathComponent("Models", isDirectory: true))
        write("memory.sqlite.original", 5_000, in: full)
        write("memory-backup.sqlite", 7_000, in: full)
        equal(SettingsStatusSnapshot.storeBytes(home: full), 1_232, "store size is memory.sqlite + -wal + -shm only")
        let closed = root.appendingPathComponent("closed", isDirectory: true)
        write("memory.sqlite", 4_096, in: closed)
        equal(SettingsStatusSnapshot.storeBytes(home: closed), 4_096, "a checkpointed store without -wal or -shm")
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        write("memory.sqlite-wal", 64, in: missing)
        equal(SettingsStatusSnapshot.storeBytes(home: missing), nil, "no memory.sqlite: hidden")
        equal(SettingsStatusSnapshot.storeBytes(home: root.appendingPathComponent("absent")), nil, "no memory home: hidden")
        let odd = root.appendingPathComponent("odd", isDirectory: true)
        write("memory.sqlite", 100, in: odd)
        try? fm.createDirectory(at: odd.appendingPathComponent("memory.sqlite-wal"), withIntermediateDirectories: true)
        equal(SettingsStatusSnapshot.storeBytes(home: odd), nil, "a -wal that is not a regular file: hidden, not a wrong size")
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        write("real.sqlite", 100, in: linked)
        try? fm.createSymbolicLink(at: linked.appendingPathComponent("memory.sqlite"), withDestinationURL: linked.appendingPathComponent("real.sqlite"))
        equal(SettingsStatusSnapshot.storeBytes(home: linked), nil, "a symbolic link is not the store: hidden")
        equal(SettingsStatusSnapshot.storeFiles, ["memory.sqlite", "memory.sqlite-wal", "memory.sqlite-shm"], "the three store files")

        // ux/declutter: Settings no longer shows the size. report-1004: Report a Problem's email holds states and counts only, so
        // it doesn't read the store's files either.
        check(!code("Sources/MacMemApp/ReportProblem.swift").contains("storeBytes") && !code("Sources/MacMemApp/ReportProblem.swift").contains("MemoryStore("),
              "Report a Problem reads no store files")
        try? fm.removeItem(at: root)
    }

    static func rows() {
        equal(SettingsRowsSnapshot.permissionsLabel(nil)?.text, nil, "permissions not read: no accessory")
        check(SettingsRowsSnapshot.permissionsLabel(PermissionSnapshot(accessibility: nil, inputMonitoring: nil)) == nil,
              "permissions with no reads: no accessory")
        let im = SettingsRowsSnapshot.permissionsLabel(PermissionSnapshot(accessibility: true, inputMonitoring: false))
        check(im?.text == "Input Monitoring needed" && im?.problem == true, "Input Monitoring needed is a problem pill")
        equal(im?.short, "Input Monitoring", "a narrow window's pill drops needed")
        let ax = SettingsRowsSnapshot.permissionsLabel(PermissionSnapshot(accessibility: false, inputMonitoring: true))
        check(ax?.text == "Accessibility needed" && ax?.short == "Accessibility" && ax?.problem == true, "Accessibility needed is a problem pill")
        let neither = SettingsRowsSnapshot.permissionsLabel(PermissionSnapshot(accessibility: false, inputMonitoring: false))
        check(neither?.text == "Both needed" && neither?.short == "Both needed" && neither?.problem == true, "Both needed is a problem pill")
        let ok = SettingsRowsSnapshot.permissionsLabel(Fx.both)
        check(ok?.text == "Both allowed" && ok?.problem == false, "Both allowed is quiet")
        let rows = SettingsRowsSnapshot(Fx.snapshot(Fx.recording))
        equal(rows.summaries, "On this Mac", "summaries row: local")
        // fix/setup-status: the Summaries row reads the one summaries state; it never says "Not set up" while the model
        // downloads or is checked.
        equal(SettingsRowsSnapshot(Fx.snapshot(Fx.recording, summaries: Fx.off)).summaries, "Off", "summaries row: off")
        equal(SettingsRowsSnapshot(Fx.snapshot(Fx.recording, summaries: SummaryAvailability(provider: .cloud, busy: false))).summaries, "OpenRouter",
              "summaries row: OpenRouter")
        equal(SettingsRowsSnapshot(Fx.snapshot(Fx.recording, summaries: SummaryAvailability(provider: .off, busy: true, downloadProgress: 0.44))).summaries,
              "Downloading…", "summaries row: downloading")
        equal(SettingsRowsSnapshot(Fx.snapshot(Fx.recording, summaries: SummaryAvailability(provider: .off, busy: true))).summaries, "Checking…",
              "summaries row: checking the model")
        equal(rows.connections, "Not set up", "connections row without a connection")
        equal(rows.exclusions, Fx.exclusions, "apps row counts come from the exclusions")
    }

    static func noLifetimeTotal() {
        let labels = Mirror(reflecting: Fx.snapshot(Fx.recording)).children.compactMap(\.label)
        check(!labels.contains { $0.lowercased().contains("total") }, "the snapshot has no lifetime total", labels.joined(separator: ","))
        let modelLabels = Mirror(reflecting: model(Fx.snapshot(Fx.recording))).children.compactMap(\.label)
        check(!modelLabels.contains { $0.lowercased().contains("total") }, "the line's model has no lifetime total", modelLabels.joined(separator: ","))
        // ux/declutter: the snapshot carries the state, the issue, the rows' values and whether Resume can run only
        // (chromeask-1005: and whether Chrome pages aren't being saved, for the calm line with Ask again or Fix).
        equal(labels, ["state", "issue", "permissions", "summaries", "exclusions", "connections", "canResume", "chromeOff", "chromeAskAgain"], "the snapshot has no day numbers, week, usage or store size")
    }

    // MARK: Laid out

    static func laidOut() {
        let calls = StatusCalls()
        let everyday = card(Fx.snapshot(Fx.recording), calls)
        equal(Set(elements.keys), ["state"], "Recording lays out the state line only")
        equal(elements["state"]?.text, "Recording", "drawn Recording line")
        let bounds = everyday.bounds.insetBy(dx: -0.5, dy: -0.5)
        check(rootFrame.width == everyday.bounds.width, "the hosted root reports its frame", "\(rootFrame)")
        if let state = local("state") {
            check(state.width > 1 && state.height > 1 && bounds.contains(state), "the state line is laid out inside the card", "\(state) in \(everyday.bounds)")
        }
        check(everyday.fittingSize.height <= 60, "the line is one short row", "\(everyday.fittingSize.height)")

        // One height in every state without an issue line, so the rows below never move.
        let plain: [(String, SettingsStatusSnapshot)] = [
            ("recording", Fx.snapshot(Fx.recording)),
            ("paused", Fx.snapshot(Fx.pausedTimed)),
            ("off", Fx.snapshot(Fx.offPlain)),
            ("off blocked", Fx.snapshot(Fx.offBlocked)),
            ("writer off", Fx.snapshot(Fx.recording, summaries: Fx.off)),
            ("needs input", Fx.snapshot(Fx.needsInput, permissions: PermissionSnapshot(accessibility: true, inputMonitoring: false))),
            ("needs both", Fx.snapshot(.needsPermission(missing: [.accessibility, .inputMonitoring]), permissions: PermissionSnapshot(accessibility: false, inputMonitoring: false))),
            ("needs unknown", Fx.snapshot(.needsPermission(missing: []), permissions: nil)),
        ]
        var measured: [String: CGFloat] = [:]
        for (name, snapshot) in plain {
            let view = card(snapshot, calls)
            measured[name] = view.fittingSize.height
            check(elements["attention"] == nil, "\(name): no issue, no attention line")
            check(elements["system-settings"] == nil, "\(name): no Open System Settings button")
            check((elements["action"] != nil) == (name == "paused" || name == "off" || name.hasPrefix("needs")),
                  "\(name): a button only while Off (Start), Paused (Resume) or Needs Permission (Allow…)")
        }
        _ = card(Fx.snapshot(Fx.offPlain), calls)
        equal(elements["action"]?.text, "Start Recording", "Off lays out Start Recording")
        _ = card(Fx.snapshot(Fx.pausedTimed), calls)
        equal(elements["action"]?.text, "Resume Recording", "Paused lays out Resume Recording")
        let base = measured["recording"] ?? 0
        let moved = measured.filter { abs($0.value - base) > 0.5 }
        check(moved.isEmpty, "the line is one height in every state without an issue", "\(base) \(moved)")

        // An issue adds its orange line under the state, at most two lines, inside the card.
        for (name, snapshot) in [("issue", Fx.snapshot(Fx.recording, issue: "Summaries could not be saved.")),
                                 ("long issue", Fx.snapshot(Fx.recording, issue: String(repeating: "The summary writer stopped and needs attention before it can continue. ", count: 3))),
                                 ("needs with issue", Fx.snapshot(Fx.needsInput, issue: "Summaries could not be saved."))] {
            let view = card(snapshot, calls)
            if let state = local("state"), let attention = local("attention") {
                check(attention.minY >= state.maxY - 0.5 && view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(attention),
                      "\(name): the attention line sits under the state line, inside the card", "\(state) \(attention)")
                check(attention.height < 36, "\(name): the attention line is at most two lines", "\(attention.height)")
            } else { check(false, "\(name): the state and attention lines are laid out") }
        }
        _ = card(Fx.snapshot(Fx.recording, issue: "Summaries could not be saved."), calls)
        equal(elements["attention"]?.text, "Summaries could not be saved.", "the operational issue line is drawn")

        _ = card(Fx.snapshot(Fx.needsInput, permissions: PermissionSnapshot(accessibility: true, inputMonitoring: false)), calls)
        equal(elements["action"]?.text, "Allow…", "Needs Permission lays out Allow…")
        equal(elements["state"]?.text, "Turn on Input Monitoring", "drawn Needs Permission line (perm-1004: names it)")
        if let state = local("state"), let button = local("action") {
            check(button.minX > state.minX && abs(button.midY - state.midY) < 16, "the button sits beside the state line", "\(state) \(button)")
        }
        check(calls.total == 0, "laying out the line calls nothing", "\(calls.total)")
    }

    // MARK: Sweeps

    static func sweeps() {
        let calls = StatusCalls()
        let cases: [(String, SettingsStatusSnapshot, Bool)] = [
            ("everyday", Fx.snapshot(Fx.recording), false),
            ("paused", Fx.snapshot(Fx.pausedTimed), false),
            ("off", Fx.snapshot(Fx.offPlain), false),
            ("off blocked", Fx.snapshot(Fx.offBlocked), false),
            ("writer off", Fx.snapshot(Fx.recording, summaries: Fx.off), false),
            ("needs permission", Fx.snapshot(Fx.needsInput, permissions: PermissionSnapshot(accessibility: true, inputMonitoring: false)), true),
            ("needs both", Fx.snapshot(.needsPermission(missing: [.accessibility, .inputMonitoring]), permissions: PermissionSnapshot(accessibility: false, inputMonitoring: false)), true),
            ("needs unknown", Fx.snapshot(.needsPermission(missing: []), permissions: nil), true),
            ("issue", Fx.snapshot(Fx.recording, issue: "Summaries could not be saved."), false),
        ]
        for (name, snapshot, blue) in cases {
            calls.reset()
            let view = card(snapshot, calls)
            check(calls.total == 0, "\(name): rendering calls nothing")
            let hover = hoverSweep(view)
            check(hover.moves > 0 && hover.delivered > 0 && calls.total == 0, "\(name): hovering is delivered and calls nothing", "\(hover) calls \(calls.total)")
            check(elements["system-settings"] == nil, "\(name): no Open System Settings on the line")
            if elements["action"] != nil {
                equal(press(view, calls, "action"), 1, "\(name): the line's button calls its closure once")
                equal(calls.actions.last, model(snapshot).button?.action, "\(name): the line's button runs its own action")
            }
            for key in ["state", "attention"] where elements[key] != nil {
                equal(press(view, calls, key), 0, "\(name): clicking \(key) calls nothing")
            }
            let sweep = clickSweep(view, calls)
            check(sweep.worst <= 1, "\(name): every click calls at most one closure", "\(sweep)")
            check(calls.actions.contains(.open(.permissions)) == blue, "\(name): Allow… is reachable exactly for Needs Permission and opens Permissions",
                  "\(calls.actions)")
            check(calls.pages.isEmpty && calls.learnMore == 0, "\(name): the line never navigates on its own (a page goes through `act`)", "\(calls.pages)")
            let expected = model(snapshot).button?.action
            check(calls.actions.allSatisfy { $0 == expected }, "\(name): no click runs any other action", "\(calls.actions)")
        }
    }

    /// The overview exactly as the app shows it: the real settings frame at its full 720×540 (14pt), with the
    /// header's Advanced… button.
    static let sheetSize = NSSize(width: DaydreamSettingsLayout.width, height: DaydreamSettingsLayout.maxHeight)
    static func settingsSheet(_ snapshot: SettingsStatusSnapshot?, rows: SettingsRowsSnapshot, _ calls: StatusCalls,
                              size: NSSize = sheetSize, fileVaultOn: Bool? = nil,
                              report: @escaping (CGRect, [CGRect]) -> Void) -> NSHostingView<AnyView> {
        host(DaydreamSettingsFrame(title: "Settings", advanced: { calls.pages.append(.advanced) }, close: { calls.closes += 1 }) {
                DaydreamSettingsOverview(status: snapshot, rows: rows, calendar: Fx.calendar,
                                         select: { calls.pages.append($0) },
                                         act: { calls.actions.append($0) }, learnMore: { calls.learnMore += 1 }, fileVaultOn: fileVaultOn)
                    .reportingRowFrames(report)
             }
             .font(.system(size: 14)), size: size)
    }

    static func overview() {
        let calls = StatusCalls()
        var viewport = CGRect.zero
        var rowFrames: [CGRect] = []
        let cases: [(String, SettingsStatusSnapshot)] = [
            ("everyday", Fx.snapshot(Fx.recording)),
            ("needs permission", Fx.snapshot(Fx.needsInput, permissions: PermissionSnapshot(accessibility: true, inputMonitoring: false))),
            ("needs both", Fx.snapshot(.needsPermission(missing: [.accessibility, .inputMonitoring]), permissions: PermissionSnapshot(accessibility: false, inputMonitoring: false))),
            ("needs unknown", Fx.snapshot(.needsPermission(missing: []), permissions: nil)),
            ("issue", Fx.snapshot(Fx.recording, issue: "Summaries could not be saved.")),
            ("long issue", Fx.snapshot(Fx.recording, issue: String(repeating: "The summary writer stopped and needs attention. ", count: 4))),
            ("off", Fx.snapshot(Fx.offPlain)),
            ("off, writer off", Fx.snapshot(Fx.offPlain, summaries: Fx.off)),
        ]
        for (name, snapshot) in cases {
            calls.reset()
            let view = settingsSheet(snapshot, rows: SettingsRowsSnapshot(snapshot), calls, fileVaultOn: false) { viewport = $0; rowFrames = $1 }
            check(calls.total == 0, "overview \(name): rendering calls nothing")
            // Fully visible: inside the scroll viewport and above its bottom fade.
            let visible = CGRect(x: viewport.minX, y: viewport.minY, width: viewport.width,
                                 height: viewport.height - DaydreamSettingsScroll<EmptyView>.fadeHeight).insetBy(dx: -0.5, dy: -0.5)
            check(rowFrames.count == 4 && rowFrames.allSatisfy { visible.contains($0) },
                  "overview \(name): the four grouped rows are visible above the fade at 720×540", "\(viewport) \(rowFrames)")
            equal(elements["footer"]?.text, DaydreamSettingsOverview.storageFooterFileVaultOff + " " + DaydreamSettingsOverview.learnMoreTitle,
                  "overview \(name): the privacy line (FileVault reads as off: its clause) and Learn more are drawn")
            // Recording with nothing to act on: no status line (the menu bar and toolbar say it).
            check((elements["state"] == nil) == (name == "everyday"), "overview \(name): the status line only when it has something to say")
            for (index, row) in rowFrames.enumerated() {
                let local = row.offsetBy(dx: -rootFrame.minX, dy: -rootFrame.minY)
                equal(click(view, calls, at: CGPoint(x: local.midX, y: local.midY)), 1, "overview \(name): row \(index) navigates once")
            }
            equal(calls.pages, [.permissions, .summaries, .apps, .connections], "overview \(name): rows open their areas in order")
            // The header (ux/v1): Advanced… and Done at the top right; no Back on the overview.
            check(elements["frame.back"] == nil, "overview \(name): no Back on the overview")
            equal(press(view, calls, "frame.advanced"), 1, "overview \(name): Advanced… calls once")
            equal(calls.pages.last, .advanced, "overview \(name): Advanced… opens Advanced")
            equal(press(view, calls, "frame.done"), 1, "overview \(name): Done calls once")
            equal(calls.closes, 1, "overview \(name): Done closes")
            let sweep = clickSweep(view, calls, step: 24)
            check(sweep.worst <= 1, "overview \(name): every click calls at most one closure", "\(sweep)")
            let pages = Set(calls.pages)
            check(pages == [.permissions, .summaries, .apps, .connections, .advanced],
                  "overview \(name): clicks only navigate to the areas (or open Learn more)", "\(pages)")
            let expectedAction: SettingsStatusAction? = name.hasPrefix("off") ? .start : nil
            check(calls.actions.allSatisfy { $0 == expectedAction } && (expectedAction == nil || !calls.actions.isEmpty),
                  "overview \(name): the only action is the line's own (Start Recording while Off)", "\(calls.actions)")
            // Needs Permission: the line's Allow… opens Permissions (the drag cards), like the Permissions row; nothing on
            // the overview opens System Settings.
            check(elements["system-settings"] == nil, "overview \(name): no Open System Settings")
            check((elements["action"]?.text == "Allow…") == name.hasPrefix("needs"), "overview \(name): Allow… only for Needs Permission")
            if name.hasPrefix("needs") {
                calls.pages = []
                equal(press(view, calls, "action"), 1, "overview \(name): Allow… calls once")
                equal(calls.pages, [.permissions], "overview \(name): Allow… opens Permissions")
            }
            // Row accessories are laid out exactly when their values are known. Needs Permission: the line above says
            // what is missing, beside its button, so the Permissions row says nothing (ux/declutter review).
            equal(elements["row.permissions"]?.text, name.hasPrefix("needs") ? nil : SettingsRowsSnapshot.permissionsLabel(snapshot.permissions)?.text,
                  "overview \(name): the permissions accessory follows the reads (the full label at 720pt), none beside Needs Permission")
            equal(elements["row.apps"]?.text, SettingsRowsSnapshot.appsLabel(Fx.exclusions), "overview \(name): the apps accessory counts the exclusions")
        }
        // FileVault on, or not known (not read yet, or the read failed): the line has no FileVault clause and keeps
        // the rest (Saturday test 5: the reminder only when FileVault is known to be off, as in setup).
        for fileVaultOn in [true, nil] as [Bool?] {
            _ = settingsSheet(Fx.snapshot(Fx.recording), rows: SettingsRowsSnapshot(Fx.snapshot(Fx.recording)), calls, fileVaultOn: fileVaultOn) { _, _ in }
            equal(elements["footer"]?.text, DaydreamSettingsOverview.storageFooter + " " + DaydreamSettingsOverview.learnMoreTitle,
                  "overview: FileVault \(fileVaultOn.map { $0 ? "on" : "off" } ?? "unknown") drops the FileVault clause")
        }
        check(!DaydreamSettingsOverview.storageFooter.contains("FileVault") && DaydreamSettingsOverview.storageFooterFileVaultOff.contains("turn on FileVault")
              && DaydreamSettingsOverview.footer(fileVaultOn: false) == DaydreamSettingsOverview.storageFooterFileVaultOff
              && DaydreamSettingsOverview.footer(fileVaultOn: nil) == DaydreamSettingsOverview.storageFooter
              && DaydreamSettingsOverview.footer(fileVaultOn: true) == DaydreamSettingsOverview.storageFooter,
              "overview: the FileVault clause shows only when FileVault is known to be off")
        // Unknown values draw no accessory: no guessed "0 excluded" and no unread permission state.
        _ = settingsSheet(Fx.snapshot(Fx.recording, permissions: nil),
                          rows: SettingsRowsSnapshot(permissions: nil, summaries: "On this Mac", exclusions: nil, connections: "Not set up"), calls) { _, _ in }
        check(elements["row.apps"] == nil && elements["row.permissions"] == nil, "overview: an unread policy and unread permissions draw no accessory",
              elements.keys.filter { $0.hasPrefix("row.") }.sorted().joined(separator: ","))
        equal(elements["row.summaries"]?.text, "On this Mac", "overview: the summaries accessory")
        equal(elements["row.connections"]?.text, "Not set up", "overview: the connections accessory")

        // The 600×400 minimum: the rows scroll between the header and the bottom margin.
        calls.reset()
        _ = settingsSheet(Fx.snapshot(Fx.offPlain, permissions: PermissionSnapshot(accessibility: true, inputMonitoring: false)),
                          rows: SettingsRowsSnapshot(Fx.snapshot(Fx.offPlain, permissions: PermissionSnapshot(accessibility: true, inputMonitoring: false))),
                          calls, size: NSSize(width: 600, height: DaydreamSettingsLayout.minHeight)) { viewport = $0; rowFrames = $1 }
        let L = DaydreamSettingsLayout.self
        check(viewport.maxY <= rootFrame.maxY - L.bottomPadding + DaydreamSettingsScroll<EmptyView>.bottomRoom + 0.5
              && viewport.minY >= rootFrame.minY + L.topPadding + L.headerHeight + L.headerGap - DaydreamSettingsScroll<EmptyView>.topRoom - 0.5,
              "600×400: the scroll viewport sits between the header and the bottom margin", "\(viewport) \(rootFrame)")
        if let done = elements["frame.done"] {
            check(done.frame.maxY <= viewport.minY + DaydreamSettingsScroll<EmptyView>.topRoom + 0.5, "600×400: nothing scrolls under Done", "\(done.frame) \(viewport)")
        }
        // Off with a permission read as missing: the orange pill is the hub's only warning. A narrow window
        // may draw the short branch; either way it is one of the two.
        let pill = elements["row.permissions"]
        check(pill?.text == "Input Monitoring needed" || pill?.text == "Input Monitoring",
              "600×400: the permissions pill draws one of its two branches", "\(String(describing: pill?.text))")

        _ = host(DaydreamSettingsOverview(summaries: "Not set up", select: { calls.pages.append($0) }), size: NSSize(width: 696, height: 432))
        check(elements.keys.allSatisfy { $0.hasPrefix("row.") || $0 == "footer" }, "overview without a status snapshot draws no status line",
              "\(elements.keys.sorted())")
        check(Set(elements.keys) == ["row.summaries", "footer"] && elements["row.summaries"]?.text == "Not set up",
              "overview without a status snapshot: the summaries accessory and the privacy line", "\(elements.keys.sorted())")
    }

    // MARK: The frame's header and setup's Back

    static func frameButtons() {
        let calls = StatusCalls()
        var backs = 0
        func page(_ title: String) -> NSHostingView<AnyView> {
            host(DaydreamSettingsFrame(title: title, back: { backs += 1 }, close: { calls.closes += 1 }) {
                DaydreamSettingsScroll { Text("Page").frame(maxWidth: .infinity, alignment: .leading) }
            }.font(.system(size: 14)), size: sheetSize)
        }
        for title in ["Permissions", "Apps to remember", "Connections", "Advanced", "Summaries"] {
            backs = 0; calls.reset()
            let view = page(title)
            guard let back = local("frame.back") else { check(false, "\(title): Back is laid out"); continue }
            check(back.width >= 34 - 0.5 && back.height >= 34 - 0.5, "\(title): Back is a 34 pt square", "\(back)")
            let L = DaydreamSettingsLayout.self
            check(abs(back.minX - L.horizontalPadding) < 1 && abs(back.midY - (L.topPadding + L.headerHeight / 2)) < 1,
                  "\(title): Back sits at the header's leading edge", "\(back)")
            var hits = 0
            for (dx, dy) in [(0.0, 0.0), (-10.0, -10.0), (10.0, -10.0), (-10.0, 10.0), (10.0, 10.0), (-15.0, 0.0), (15.0, 0.0)] {
                let before = backs
                _ = click(view, calls, at: CGPoint(x: back.midX + dx, y: back.midY + dy))
                if backs == before + 1 { hits += 1 }
            }
            equal(hits, 7, "\(title): Back answers a click anywhere in its square (center, ±10 pt corners, ±15 pt sides)")
            let before = backs
            _ = click(view, calls, at: CGPoint(x: back.maxX + 60, y: back.midY))
            check(backs == before && calls.closes == 0, "\(title): a click on the title does nothing")
            let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber,
                                       context: nil, characters: "[", charactersIgnoringModifiers: "[", isARepeat: false, keyCode: 33)!
            let handled = window.performKeyEquivalent(with: key)
            pump(0.05)
            check(handled && backs == before + 1, "\(title): ⌘[ goes back", "handled \(handled) backs \(backs - before)")
            check(elements["frame.advanced"] == nil, "\(title): a sub-page has no Advanced…")
            equal(press(view, calls, "frame.done"), 1, "\(title): Done calls once")
            equal(calls.closes, 1, "\(title): Done closes")
        }
        // Setup's Back: the whole 36 pt box answers, not just the chevron and the word.
        backs = 0
        let setup = host(DaydreamOnboardingShell(title: "Summaries", back: { backs += 1 }, continueAction: { calls.closes += 1 }) {
            Text("Page")
        }, size: NSSize(width: 660, height: 600))
        if let back = local("setup.back") {
            check(back.width >= 74 - 0.5 && back.height >= 36 - 0.5, "setup: Back is at least 74×36", "\(back)")
            var hits = 0
            for (dx, dy) in [(0.0, 0.0), (-(back.width / 2 - 4), 0.0), (back.width / 2 - 4, 0.0), (0.0, -14.0), (0.0, 14.0)] {
                let before = backs
                _ = click(setup, calls, at: CGPoint(x: back.midX + dx, y: back.midY + dy))
                if backs == before + 1 { hits += 1 }
            }
            equal(hits, 5, "setup: Back answers across its whole box")
        } else {
            check(false, "setup: Back is laid out")
        }
        window.contentView = nil
    }

    /// The sheet's height: 540 at most, never taller than the window under it (less 12) or the screen (less 120),
    /// and 400 at least. A 13-inch MacBook Air (1470×956 points, 919 below the menu bar) gets the full 540.
    static func sheetHeight() {
        let L = DaydreamSettingsLayout.self
        equal(L.width, 720, "the sheet is 720 pt wide")
        equal(L.height(windowContentHeight: nil, screenHeight: nil), 540, "no window or screen: 540")
        equal(L.height(windowContentHeight: 700, screenHeight: 919), 540, "13-inch MacBook Air, a tall window: 540")
        equal(L.height(windowContentHeight: 480, screenHeight: 919), 468, "a 480 pt window: 12 pt shorter than the window")
        equal(L.height(windowContentHeight: 300, screenHeight: 919), 400, "a small window: the 400 pt floor")
        equal(L.height(windowContentHeight: nil, screenHeight: 600), 480, "a short screen: 120 pt of room")
        equal(L.height(windowContentHeight: .infinity, screenHeight: -1), 540, "nonsense sizes don't limit it")
        check(L.maxHeight + 28 + 120 <= 919, "the tallest sheet, with its title bar, leaves 120 pt free on a 13-inch MacBook Air")
        equal(L.viewport(540), 454, "a 540 pt sheet leaves 454 pt for the page")
        let app = code("Sources/MacMemApp/MacMemApp.swift")
        check(app.contains("MemorySettings(model:model,height:DaydreamSettingsLayout.height(windowContentHeight:contentHeight))"),
              "the app sizes the sheet from its window")
    }

    // MARK: Sources

    /// The text of the first `{…}` block after `signature` (brace counting).
    static func body(of signature: String, in source: String) -> String? {
        guard let start = source.range(of: signature), let open = source[start.lowerBound...].firstIndex(of: "{") else { return nil }
        var depth = 0, index = open
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" { depth -= 1; if depth == 0 { return String(source[open...index]) } }
            index = source.index(after: index)
        }
        return nil
    }

    static func code(_ path: String) -> String {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { check(false, "read \(path)"); return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
            .joined(separator: "\n")
    }

    static func sources() {
        let card = code("Sources/MemoryUI/SettingsStatusCard.swift")
        let hub = code("Sources/MemoryUI/SettingsHub.swift")
        let app = code("Sources/MacMemApp/DaydreamSettings.swift")
        guard let overview = body(of: "public struct DaydreamSettingsOverview", in: hub),
              let host = body(of: "private struct DaydreamSettingsOverviewHost", in: app) else {
            return check(false, "found the overview and its app host")
        }
        // A3 deleted the old toolbar status control, and dd-status-checks asserts that no source or script
        // spells its name, so this banned token is assembled instead of written out (wave-2 gate integration fix).
        let deletedStatusControl = ["CaptureStatus", "Control"].joined()
        // ux/declutter review: the line's one button may be Start Recording (Off) or Resume Recording (Paused), named
        // once as `startTitle`/`resumeTitle` in the card; the host runs them through the app's one start call. Pause,
        // Stop and every capture control stay out.
        let banned = ["RecordingControls", "RecordingControlButton", "RecordingMasterControl", "CaptureControls", "CaptureActions",
                      "PauseCaptureMenu", deletedStatusControl, "CaptureMenuRows", "\"Start\"", "\"Pause\"", "\"Pause ",
                      "\"Pause…", "\"Resume\"", "\"Stop\"", "\"Stop ", "startCapture", "pauseCapture", "resumeCapture", "stopCapture", "momentsTotal"]
        // ux/declutter: nor today's numbers, the week, usage, the store size or Show in Finder.
        let cut = ["Show in Finder", "showInFinder", "activateFileViewerSelecting", "Memory on this Mac", "remembered today", "Last 7 days",
                   "Most used", "TodaySnapshot", "DayDigest", "storageBytes", "Checked"]
        for (name, text) in [("SettingsStatusCard.swift", card), ("DaydreamSettingsOverview", overview), ("DaydreamSettingsOverviewHost", host)] {
            let found = (banned + cut).filter { text.contains($0) }
            check(found.isEmpty, "\(name) has no capture controls, day numbers, store size, Show in Finder or lifetime total", found.joined(separator: ", "))
        }
        check(!card.contains("enumerator(") && !card.contains("contentsOfDirectory") && !card.contains("subpaths"),
              "storeBytes never walks a directory")
        check(!app.contains("activateFileViewerSelecting") && !app.contains("Show in Finder"), "Settings has no Show in Finder")
        check(host.contains("learnMore: { NSWorkspace.shared.open(PrivacyPromise.policyURL) }"), "Learn more opens PRIVACY.md, only when pressed")
        check(card.components(separatedBy: "\"Start Recording\"").count == 2 && card.components(separatedBy: "\"Resume Recording\"").count == 2
              && !hub.contains("\"Start Recording\"") && !host.contains("\"Start Recording\""),
              "Start and Resume Recording are named once, in the card")
        check(host.contains("case .start, .resume: model.requestStart {") && !host.contains(".pause(") && !host.contains(".stop("),
              "the host runs Start and Resume through the app's one start call (requestStart, which opens setup when a step there must be done first), and never pauses or stops")
        check(host.contains("case .open(let page): select(page)") && !host.contains("openSystemSettings"),
              "the host opens a page for the line's page buttons (Allow… opens Permissions) and never System Settings")
        if let actionEnum = body(of: "public enum SettingsStatusAction", in: card) {
            check(!actionEnum.contains("pause") && !actionEnum.contains("stop"), "the line's actions have no pause or stop")
        } else { check(false, "found SettingsStatusAction") }
        // Start and Stop live in the menu bar and the main window only (ux/v1): Advanced has no second Start/Stop.
        check(!app.contains("RecordingMasterControl") && !app.contains("Launch at login"), "Settings has no recording controls and no greyed-out Launch at login")
        // Saving an app or typing choice stops recording while it saves and starts it again after (ux/v1), so the page
        // has no paragraph about it, and never says pause.
        guard let appsPage = body(of: "private struct DaydreamAppSettings", in: app) else { return check(false, "found the apps page") }
        check(!appsPage.contains("stops recording while the change is saved") && !appsPage.contains("pauses recording"),
              "the apps page has no standing note about stopping recording")
        check(host.contains("preferencesAvailable") && host.contains("preferencesUnresolved") && host.contains("rows.exclusions = nil"),
              "the overview host hides the apps accessory until the policy is read and saved")
        check(app.contains("advanced: page == .overview"), "the overview's header offers Advanced…")
        check(!hub.contains("\"every moment and day\""), "the Summaries row doesn't promise a summary of every moment")
    }

    // MARK: App host (recording trial, private store)

    static func appHost(_ out: URL) async {
        let home = out.appendingPathComponent("trial-" + UUID().uuidString, isDirectory: true)
        let memory = home.appendingPathComponent("memory", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        } catch { return check(false, "private trial store", "\(error)") }
        setenv("MAC_MEM_HOME", memory.path, 1)
        guard MemPaths.home().standardizedFileURL.path == memory.standardizedFileURL.path else {
            return check(false, "the trial model uses the private store", MemPaths.home().path)
        }
        let model = MemoryViewModel(recordingTrial: true)
        check(model.recordingTrial && !model.recording && model.stopped, "the recording trial opened without recording")
        let view = host(MemorySettings(model: model), size: sheetSize)
        for _ in 0..<60 where elements["state"] == nil || elements["row.connections"] == nil { pump(0.05) }
        let state = model.presentation.state
        // perm-1004 (72d5565): the card's title is the state's title (`Turn on Accessibility` while a permission is missing).
        check(elements["state"]?.text.hasPrefix(state.title) == true, "the app's line shows the model's state", elements["state"]?.text ?? "none")
        var needs = false
        if case .needsPermission = state { needs = true }
        check(elements["system-settings"] == nil && (elements["action"]?.text == "Allow…") == needs,
              "the app's line offers Allow… exactly for Needs Permission, and never Open System Settings")
        check(elements["storage"] == nil && elements["finder"] == nil && elements["week"] == nil && elements["today"] == nil && elements["today.empty"] == nil,
              "the app's Settings shows no store size, Show in Finder, week or day numbers", elements.keys.sorted().joined(separator: ","))
        // The app reads FileVault once, off the main thread; the line is one of its two forms.
        check([DaydreamSettingsOverview.storageFooter, DaydreamSettingsOverview.storageFooterFileVaultOff]
                .map { $0 + " " + DaydreamSettingsOverview.learnMoreTitle }.contains(elements["footer"]?.text ?? ""), "the app's privacy line",
              elements["footer"]?.text ?? "none")
        check((elements["row.apps"] != nil) == (model.preferencesAvailable && !model.preferencesUnresolved),
              "the app's apps accessory appears only once the policy is read and saved",
              "row.apps \(elements["row.apps"]?.text ?? "none"), available \(model.preferencesAvailable), unresolved \(model.preferencesUnresolved)")
        check(elements["row.permissions"]?.text == (needs ? nil : SettingsRowsSnapshot.permissionsLabel(model.presentation.permissions)?.text),
              "the app's permissions accessory follows the model's reads", elements["row.permissions"]?.text ?? "none")
        check(!model.recording && model.stopped, "showing Settings started nothing")
        _ = view
        window.contentView = nil
        pump(0.05)
    }
}
