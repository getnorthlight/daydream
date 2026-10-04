// DD-RECIPE: UI
//
// A1a Focus List checks (spec §3, plan §5 A1, amendments A1). Values only: a fixed clock
// (Tue 2026-09-22 16:21, America/Los_Angeles), day reads built inline as `ActionDay` JSON, views
// hosted offscreen in a window that reports itself key. No app, no store, no permissions, no recording.
//  - Honesty: the headline only from a ready, non-generic day note; stat values equal the snapshot;
//    no active-time cell; the summary cell's gating (locality / Pending / {g} of {n} / Off / hidden),
//    including the 442-action moment, a ~600-action day and a ready day note with the generic
//    "Day summary" title (summarized, never Pending); an empty day has no chip icon and no ribbon
//    segments; chips count only loaded days; the pending chip only for pending moments; an app known
//    only by its bundle ID is never named; Latest is the last observation; the empty Today's line
//    follows the recording state (nothing while paused, the blocker while Off for a reason); a failed
//    Exclude shows the app's own text.
//  - Rows: one VoiceOver element with `{title}, {app}, {range}, {spoken span}` and Expanded/Collapsed
//    (through the public hooks, and the AX tree when SwiftUI exposes it offscreen), a real mouse
//    down/up toggles expansion.
//  - Keys through NSApp.sendEvent (where the router's local monitor runs): ↑ ↓ select, Return
//    toggles, Esc collapses, ⌘C writes to a private pasteboard only when the moment has a summary.
//  - Commands: ⌘[ ⌘] move a day and stop at today, the day's selection comes back, Recall visible
//    blocks them, Find Related posts the filter then presents Recall; commandContext follows.
//  - A refresh that drops the selected moment re-selects the nearest start.
//  - Another surface writing focusedDay with selectedMomentID/expandedMomentID (Recall's Show in
//    <Weekday> and Show in Today) keeps those ids, and the day left keeps its own.
//  - selectedCanonicalActivity: opens the moment's detail once its day loads, never after it was
//    cleared, and a moment on no loaded day drops the request instead of opening later.
//  - The paused row: only for a live pause; Resume calls `resume` exactly once, only when pressed.
//  - Rendering, day changes, expansion and Esc call no capture action.
//  - The footer is hints only (no capture-state, no Pause; through the AX tree when exposed, and its
//    source); `CanonicalTimeline(browser:` is still what MemoryShell mounts; no key equivalent with
//    modifiers in the Focus List files.
//  A1b additions (amendments A1):
//  - The expanded body follows MomentSummaryState: Pending draws a skeleton and says "Summarizing on
//    this Mac" only for the local writer and ≤400 actions; Off, too long and partial say so, never
//    on this Mac. A ready note's bullets show.
//  - The action bar (fix/show-all: no open button; the entries open), Copy Summary ⌘C (Summarize Now, no keycap),
//    Find Related Moments ⌘R, Forget This Moment…; the VoiceOver named actions, only while they can run.
//  - Windows and pages: one source per page host or window, the three with most actions, listed by first
//    seen, each opening its latest action with that action's evidence; never a bundle ID or "edited".
//  - Hosted with a FocusListProbe: expanding lists the sources, one row expanded at a time, the detail
//    loads the moment's actions oldest first, and nothing calls a capture action.
//  A1b review round:
//  - Pending with a cloud writer (or over 400 actions) reads "{n} actions · summary pending" (copy deck
//    §8.5); the model mark only beside model text (ready, pending), never off / too long / partial.
//  - A source read short of every member says "Some windows and pages may be missing." and gives its
//    span as "from <first>"; the detail's Load More shows only while more can exist, and a read that
//    ran out of pages says actions may be missing. A failed detail read says so (Try Again), never a
//    bare "0 of N". A failed action from the expanded bar shows its notice in the card.
//  - The row button carries the plan §2.10 identifier `focus-list-row`.
import AppKit
import SwiftUI
import MemoryUI
import MemoryCore

final class ProbeWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    override var attachedSheet: NSWindow? { nil }
}

/// Capture actions that only count.
final class CaptureCalls {
    var pauses = 0, resumes = 0, stops = 0, settings = 0, other = 0
    var total: Int { pauses + resumes + stops + settings + other }
    var actions: CaptureActions {
        var a = CaptureActions(pause: { [unowned self] _ in self.pauses += 1 }, resume: { [unowned self] in self.resumes += 1 },
                               stop: { [unowned self] in self.stops += 1 }, settings: { [unowned self] in self.settings += 1 })
        a.openSystemSettings = { [unowned self] _ in self.other += 1 }
        a.checkPermissions = { [unowned self] in self.other += 1 }
        a.openSettingsSection = { [unowned self] _ in self.other += 1 }
        a.openMain = { [unowned self] in self.other += 1 }
        a.openRecall = { [unowned self] in self.other += 1 }
        a.quit = { [unowned self] in self.other += 1 }
        return a
    }
}

final class FlagBox: @unchecked Sendable { var open = false; var fail = false }
@main @MainActor enum DDFocusListChecks {
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
    static func date(_ h: Int, _ m: Int, day: Int = 22) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 9, day: day, hour: h, minute: m))!
    }
    static let now = date(16, 21)
    static let todayKey = "2026-09-22", yesterdayKey = "2026-09-21"

    // MARK: Inline day reads

    struct Spec {
        var id: String
        var from: (Int, Int), to: (Int, Int)
        var app: String, bundle: String, site: String = ""
        var count: Int
        var title: String? = nil
        var bullets: [String] = []
        var generator = "local/qwen3.5-4b-q4_k_m"
        var version = "1"
    }

    static func note(_ s: Spec, day: Int, key: String) -> (note: [String: Any], actions: [[String: Any]]) {
        let start = date(s.from.0, s.from.1, day: day), end = date(s.to.0, s.to.1, day: day)
        let ids = (0..<s.count).map { "\(s.id)-a\($0)" }
        let step = s.count > 1 ? end.timeIntervalSince(start) / Double(s.count - 1) : 0
        let actions: [[String: Any]] = ids.enumerated().map { i, id in
            ["id": id, "evidenceIDs": [id + "-e"], "at": iso(start.addingTimeInterval(step * Double(i))), "kind": s.site.isEmpty ? "window.changed" : "browser.observed",
             "app": s.app, "bundle": s.bundle, "site": s.site, "title": s.title ?? s.app, "description": "Observed in \(s.app)",
             "state": "observed", "revision": "r1", "subject": s.title ?? s.app, "observationKey": id]
        }
        var n: [String: Any] = ["id": s.id, "day": key, "timezone": la.identifier, "subject": s.title ?? s.app, "actionIDs": ids,
                                "apps": [s.app], "sites": s.site.isEmpty ? [] : [s.site], "start": iso(start), "end": iso(end),
                                "clusters": [["actionIDs": ids, "firstObservedAt": iso(start), "lastObservedAt": iso(end)]],
                                "inputRevision": "r1", "status": s.title == nil ? "pending" : "ready",
                                "bundles": [s.bundle], "bundleActionCounts": [s.bundle: s.count]]
        if let title = s.title {
            n["generated"] = generated(id: "g-" + s.id, title: title, bullets: s.bullets, ids: ids, at: end.addingTimeInterval(120), generator: s.generator,
                                     version: s.version)
        }
        return (n, actions)
    }

    static func generated(id: String, title: String, bullets: [String], ids: [String], at: Date, generator: String, version: String = "1") -> [String: Any] {
        ["id": id, "version": 1, "schemaVersion": 1, "generatedAt": iso(at), "inputRevision": "r1", "actionIDs": ids, "status": "generated_unverified",
         "output": ["requestID": "req-" + id, "title": title, "bullets": bullets.map { ["text": $0, "actionIDs": [ids[0]], "assertion": "observed"] },
                    "generator": generator, "generatorVersion": version]]
    }

    /// The fixture's first-page size. Today's four moments (476 actions, the 442-action one over the writer's 400 limit)
    /// fit in it; `expandedIncomplete` adds a moment only its first few actions reach.
    static let pageSize = 500

    static func day(_ key: String, _ specs: [Spec], dayNote: String? = nil, partial: Bool = false) -> ActionDay {
        let dayNumber = Int(key.suffix(2)) ?? 22
        let built = specs.map { note($0, day: dayNumber, key: key) }
        let actions = built.flatMap(\.actions).sorted { ($0["at"] as! String) < ($1["at"] as! String) }
        let interval = try! DayScope.interval(day: key, timezone: la.identifier)
        var summary: [String: Any] = ["day": key, "timezone": la.identifier, "start": iso(interval.start), "end": iso(interval.end),
                                      "activityIDs": specs.map(\.id), "actionCount": actions.count, "countIsComplete": true,
                                      "inputRevision": "r1", "status": dayNote == nil ? "pending" : "ready"]
        if let dayNote {
            summary["generated"] = generated(id: "day-" + key, title: dayNote, bullets: ["Reviewed the capture pipeline."],
                                             ids: actions.prefix(3).map { $0["id"] as! String }, at: date(9, 14, day: dayNumber),
                                             generator: "local/qwen3.5-4b-q4_k_m")
        }
        let value: [String: Any] = ["summary": summary, "activities": built.map(\.note),
                                    "actions": ["actions": Array(actions.prefix(pageSize)), "revision": "r1",
                                                "snapshot": ["epoch": "e1", "highWater": actions.count], "candidates": actions.count],
                                    "defaultLayer": "activity_notes", "partial": partial]
        return try! JSONDecoder().decode(ActionDay.self, from: JSONSerialization.data(withJSONObject: value))
    }

    static let mail = Spec(id: "t-mail", from: (8, 42), to: (9, 10), app: "Mail", bundle: "com.apple.mail", count: 12,
                           title: "Weekly digest in Mail", bullets: ["Read the weekly digest."])
    static let zed = Spec(id: "t-zed", from: (13, 5), to: (14, 20), app: "Zed", bundle: "dev.zed.Zed", count: 442)
    static let chrome = Spec(id: "t-chrome", from: (14, 30), to: (15, 20), app: "Google Chrome", bundle: "com.google.Chrome", site: "github.com",
                             count: 17, title: "Reviewing the launch plan", bullets: ["Commented on the launch plan.", "Opened the beta checklist."])
    static let notes = Spec(id: "t-notes", from: (15, 40), to: (16, 18), app: "Notes", bundle: "com.apple.Notes", count: 5)
    static var todaySpecs = [mail, zed, chrome, notes]

    static func browser(summaries: SummaryAvailability = SummaryAvailability(provider: .local, busy: false),
                        failing: Bool = false) -> ActivityBrowser {
        let b = ActivityBrowser(calendar: cal)
        b.now = { now }
        b.summaries = summaries
        b.loadCanonicalDay = { key, _ in
            if failing { throw MemError.database("Memory read failed") }
            switch key {
            case todayKey: return day(key, todaySpecs)
            case yesterdayKey:
                return day(key, [Spec(id: "y-safari", from: (10, 0), to: (10, 30), app: "Safari", bundle: "com.apple.Safari", site: "developer.apple.com",
                                      count: 6, title: "Reading the capture docs", bullets: ["Read about event taps."])],
                           dayNote: "Capture pipeline review and permission wording")
            default: return day(key, [])
            }
        }
        b.reopenCanonical = { _ in }
        b.openApp = { _ in }
        return b
    }

    // MARK: Hosting

    static let window: ProbeWindow = {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let w = ProbeWindow(contentRect: NSRect(x: -4000, y: -4000, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        w.acceptsMouseMovedEvents = true
        w.orderFrontRegardless()
        return w
    }()
    static let pasteboard = NSPasteboard(name: NSPasteboard.Name("dd-focus-list-checks-\(ProcessInfo.processInfo.processIdentifier)"))

    static func pump(_ s: Double = 0.12) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    @discardableResult static func wait(_ timeout: Double = 3, _ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { pump(0.03) }
        return done()
    }

    @discardableResult
    static func host<V: View>(_ view: V, size: NSSize = NSSize(width: 900, height: 700)) -> NSHostingView<AnyView> {
        let h = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height, alignment: .topLeading)
            .environment(\.daydreamNow, now).environment(\.daydreamStatic, true).environment(\.daydreamPasteboard, pasteboard)))
        window.setContentSize(size)
        window.contentView = h
        h.frame = NSRect(origin: .zero, size: size)
        pump(); h.layoutSubtreeIfNeeded(); pump(0.05)
        return h
    }

    static func tree(_ root: Any, depth: Int = 0, into out: inout [NSAccessibilityProtocol]) {
        guard depth < 40, let e = root as? NSAccessibilityProtocol else { return }
        out.append(e)
        for child in e.accessibilityChildren() ?? [] { tree(child, depth: depth + 1, into: &out) }
    }
    static func elements(_ view: NSView) -> [NSAccessibilityProtocol] {
        var out: [NSAccessibilityProtocol] = []
        tree(view, into: &out)
        return out
    }

    static func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: window.windowNumber, context: nil, characters: characters,
                                 charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        NSApp.sendEvent(e)
        pump(0.08)
    }
    static let up = String(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!), down = String(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!)
    static func pressUp() { key(126, up, [.numericPad, .function]) }
    static func pressDown() { key(125, down, [.numericPad, .function]) }
    static func pressReturn() { key(36, "\r") }
    static func pressEscape() { key(53, "\u{1b}") }
    static func pressCopy() { key(8, "c", .command) }

    static func click(_ view: NSView, at point: NSPoint) {
        let p = view.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                          pressure: type == .leftMouseDown ? 1 : 0) {
                window.sendEvent(e)
            }
        }
        pump(0.06)
    }

    // MARK: Main

    static func main() {
        honesty()
        summaryGating()
        dayNoteHonesty()
        bundleIDNames()
        emptyDayAndChips()
        rowHooks()
        copyAndPausedHooks()
        timelineKeysAndCommands()
        handoffs()
        detailRequests()
        expandedRules()
        expandedHosted()
        rowClicks()
        failedToday()
        pausedRowPress()
        footer()
        sources()
        if failures > 0 {
            FileHandle.standardError.write(Data("FAIL: \(failures) focus list check(s) failed\n".utf8))
            exit(1)
        }
        print("PASS: all focus list checks")
    }

    // MARK: Honesty

    static func snapshot(_ d: ActionDay, _ provider: SummaryAvailability.Provider = .local) -> TodaySnapshot {
        TodaySnapshot.make(day: d, summaries: SummaryAvailability(provider: provider, busy: false), calendar: cal, now: now)
    }

    static func honesty() {
        let today = snapshot(day(todayKey, todaySpecs))
        let word = DayWord.today
        // fix/day-card: never a count. Without a day note or the day's threads (a read without levels), the moment
        // with the most time, by its name.
        switch FocusListSummaryCard.headline(for: today, day: word, timeZone: la) {
        case .ready(let title, _, let locality):
            equal(title, today.moments.first { $0.id == "t-zed" }!.title, "headline: no day note → the moment with the most time, by name")
            check(!title.hasSuffix("moments") && locality == nil, "headline: no day note → never a count, no locality chip", title)
        default: check(false, "headline: a day with moments always has a headline")
        }
        let ready = snapshot(day(yesterdayKey, [Spec(id: "y1", from: (10, 0), to: (10, 30), app: "Safari", bundle: "com.apple.Safari", count: 6)],
                                 dayNote: "Capture pipeline review"))
        if case .ready(let title, _, let locality) = FocusListSummaryCard.headline(for: ready, day: .yesterday, timeZone: la) {
            equal(title, "Capture pipeline review", "headline: a ready day note shows its title")
            equal(locality, .local, "headline: a local/ generator is On this Mac")
        } else { check(false, "headline: a ready day note shows") }
        let generic = snapshot(day(yesterdayKey, [Spec(id: "y1", from: (10, 0), to: (10, 30), app: "Safari", bundle: "com.apple.Safari", count: 6)],
                                   dayNote: "Day summary"))
        check({ if case .ready(let t, _, _) = FocusListSummaryCard.headline(for: generic, day: .yesterday, timeZone: la) { return t != "Day summary" && !t.isEmpty }; return false }(),
              "headline: the writer's generic \"Day summary\" is never a headline")

        // ux/declutter: no stat grid (its counts repeated the headline, the rows and their icons), no Latest or
        // Most actions line, no "Updated" time.
        equal(today.actionCount, 476, "fixture: today has 476 actions")
        let card = source("Sources/MemoryUI/FocusListSummaryCard.swift")
        for gone in ["statCells", "summaryCell", "topAppsText", "latestText", "factLabel(", "Text(\"Updated", "\"Most actions", "\"Latest"] {
            check(!card.contains(gone), "summary card: draws no \(gone) (declutter)")
        }
        // A partial day's count is a lower bound: "24+ moments", read by VoiceOver as "at least".
        let lowerBound = TodaySnapshot(dayKey: todayKey, loadedAt: now, momentCount: 24, actionCount: 1204, countComplete: false, partial: true,
                                       moments: [], headline: nil, headlineBullets: [], headlineGeneratedAt: nil, headlineLocal: nil,
                                       firstObserved: date(9, 0), lastObserved: date(12, 0), topApps: [], latest: nil,
                                       summaries: SummaryAvailability(provider: .local, busy: false), readyCount: 0, pendingCount: 0,
                                       tooLongCount: 0, appCount: 3)
        equal(FocusListSummaryCard.headline(for: lowerBound, day: word, timeZone: la), .none,
              "headline: never a count (\"24+ moments\"): no named moment, no headline")
        let lowerModel = RibbonModel.make(snapshot: lowerBound, state: nil, now: now, calendar: cal, isToday: true)
        if !lowerModel.empty {
            check(FocusListSummaryCard.ribbonAccessibility(lowerBound, model: lowerModel, timeZone: la).label.hasSuffix("at least 24 moments"),
                  "ribbon: VoiceOver reads a partial day's count as at least")
        }
    }

    static func summarySnapshot(actions: Int, ready: Int, pending: Int, tooLong: Int = 0, provider: SummaryAvailability.Provider = .local,
                                headline: String? = nil, local: Bool? = nil, partial: Bool = false, download: Double? = nil) -> TodaySnapshot {
        TodaySnapshot(dayKey: todayKey, loadedAt: now, momentCount: ready + pending + tooLong, actionCount: actions, countComplete: true,
                      partial: partial, moments: [], headline: headline, headlineBullets: [], headlineGeneratedAt: nil, headlineLocal: local,
                      firstObserved: nil, lastObserved: nil, topApps: [], latest: nil,
                      summaries: SummaryAvailability(provider: provider, busy: false, downloadProgress: download), readyCount: ready, pendingCount: pending,
                      tooLongCount: tooLong, appCount: 8)
    }

    static func summaryGating() {
        typealias Card = FocusListSummaryCard
        // ux/declutter: the card has one pending signal (the chip under the count) and no summary cell.
        // The ~600-action day: 12 ready, 11 pending, 1 too long. The writer won't summarize it as a day.
        // fix/day-card: no pending chip, no "Summary pending", no skeleton. At most one line under the headline, from
        // the summaries phase: its own line while downloading or checking, a problem with its one button, or
        // "Summaries are off" (never on the preview's sample); nothing while on.
        equal(Card.partialFootnote(isToday: true), "Some of today may be missing.", "summary card: today's partial-day line")
        equal(Card.partialFootnote(isToday: false), "Some of this day may be missing.", "summary card: a past day's partial-day line")
        let cardSource = source("Sources/MemoryUI/FocusListSummaryCard.swift")
        // claude/day-review-1003: the day review is a third lead, with the same line.
        check(cardSource.components(separatedBy: "if snapshot.partial { partialNote").count == 4,
              "summary card: every lead (the day review, a headline or none) draws the partial-day line")
        for gone in ["PendingChip(", "SkeletonLines(", "showsPendingDay", "pendingChipText", "Summary pending", ".fallback("] {
            check(!cardSource.contains(gone), "summary card: no \(gone) (fix/day-card)")
        }
        check(!source("Sources/MemoryUI/CanonicalTimeline.swift").contains("Some of today may be missing"),
              "timeline: the partial-day line lives in the card, not below the list")
        equal(Card.phaseLine(SummaryAvailability(provider: .local, busy: false)), .none, "phase line: nothing while summaries are on")
        equal(Card.phaseLine(SummaryAvailability(provider: .off, busy: false)), .off, "phase line: Summaries are off")
        equal(Card.phaseLine(SummaryAvailability(provider: .off, busy: false), sample: true), .none, "phase line: never on the preview's sample")
        equal(Card.phaseLine(SummaryAvailability(provider: .off, busy: false, phase: .downloading(received: 1_200_000_000, total: 2_700_000_000))),
              .status("Downloading 1.2 of 2.7 GB"), "phase line: the download's own line, with its real progress")
        equal(Card.phaseLine(SummaryAvailability(provider: .off, busy: false, phase: .on(.local))), .none, "phase line: nothing once on")
        check({ if case .problem = Card.phaseLine(SummaryAvailability(provider: .off, busy: false, phase: .failed(.downloadStopped))) { return true }; return false }(),
              "phase line: a problem with its one button")
        check(cardSource.contains("fixSummaries"), "summary card: the problem's one button calls fixSummaries")
        equal(Card.headline(for: summarySnapshot(actions: 60, ready: 1, pending: 0, headline: "A day", local: true), day: .today, timeZone: la),
              .ready(title: "A day", bullets: [], locality: .local), "headline: a ready local day note is local (the card draws no chip for it)")
        check(source("Sources/MemoryUI/FocusListSummaryCard.swift").contains("if locality == .cloudKey { OnThisMacChip(.cloudKey, size: .small) }"),
              "summary card: the day note's chip only when the person's cloud key wrote it")
        // ux/declutter: the day card's ribbon draws a now tick only with Now (recording, an open pause) or inside a
        // live pause's hatch; Off and Needs Permission draw no bare tick.
        let ribbonNow = { (state: RecordingState) in RibbonModel.make(snapshot: nil, state: state, now: now, calendar: cal, isToday: true).dayCard }
        let offRibbon = ribbonNow(.off(since: now.addingTimeInterval(-600), reason: nil))
        check(offRibbon.now == nil && offRibbon.flag == .none, "day card ribbon: Off draws no now tick")
        check(ribbonNow(.needsPermission(missing: [.inputMonitoring])).now == nil, "day card ribbon: Needs Permission draws no now tick")
        let recRibbon = ribbonNow(.recording(since: nil))
        check(recRibbon.now != nil && recRibbon.flag == .now, "day card ribbon: Recording keeps Now")
        let pausedRibbon = ribbonNow(.paused(until: now.addingTimeInterval(900), since: now.addingTimeInterval(-300), reason: nil))
        check(pausedRibbon.now != nil && pausedRibbon.pause != nil && pausedRibbon.flag == .none, "day card ribbon: a timed pause keeps its hatch and tick, no countdown")
        equal(Card.headline(for: summarySnapshot(actions: 60, ready: 1, pending: 0, headline: "A day", local: false), day: .today, timeZone: la),
              .ready(title: "A day", bullets: [], locality: .cloudKey), "headline: a ready cloud day note → Cloud (N17)")

        // claude/ready-1002 (owner): the 442-action moment is written in segments, so it is never "too long" (that starts
        // over DaydreamSummaryLimit.actions, 2,000); it waits like any moment, and with summaries off it is off.
        let d = day(todayKey, todaySpecs)
        for provider in [SummaryAvailability.Provider.local, .off] {
            let s = snapshot(d, provider)
            let long = s.moments.first { $0.id == "t-zed" }!
            equal(long.summary, provider == .local ? .pending : .summariesOff, "442-action moment is summarized in segments (\(provider))")
            check(DaydreamSummaryLimit.actions == 2000, "the too-long bound is the writer's segment bound")
            let small = s.moments.first { $0.id == "t-notes" }!
            check(MomentSubtitle.rowText(for: small) != "Summary pending", "a 5-action moment never says pending (\(provider))", "\(small.summary)")
        }
    }

    /// A day note stored with the old batch writer's generic "Day summary" title (21–100 actions): the snapshot has no
    /// headline, yet the day is summarized. It must never read Pending (the writer won't rewrite it).
    static func dayNoteHonesty() {
        typealias Card = FocusListSummaryCard
        let specs = [Spec(id: "g1", from: (10, 0), to: (10, 40), app: "Safari", bundle: "com.apple.Safari", count: 25),
                     Spec(id: "g2", from: (11, 0), to: (11, 30), app: "Notes", bundle: "com.apple.Notes", count: 20)]
        let generic = day(yesterdayKey, specs, dayNote: "Day summary")
        let s = snapshot(generic)
        equal(s.actionCount, 45, "fixture: the generic-note day has 45 actions")
        equal(s.headline, nil, "generic day note: no headline")
        equal(FocusDayNote.make(generic), .ready(local: true), "day note: a ready generic note is still a stored note")
        equal(Card.headline(for: s, day: .yesterday, timeZone: la), .ready(title: s.moments.first { $0.id == "g1" }!.title, bullets: [], locality: nil),
              "generic day note: the moment with the most time, not the generic title or a count")
        var cloud = generic
        cloud.summary.generated?.output.generator = "deepseek/deepseek-v4-flash-0731"
        equal(FocusDayNote.make(cloud), .ready(local: false), "day note: a cloud generator is Cloud (N17)")
        let pending = day(yesterdayKey, specs)
        equal(FocusDayNote.make(pending), FocusDayNote.none, "day note: a pending day has no stored note")
        let timeline = source("Sources/MemoryUI/CanonicalTimeline.swift")
        check(timeline.contains("dayNote: dayNote(key)") && timeline.contains("FocusDayNote.make(day)"),
              "CanonicalTimeline passes the day read's note state to the summary card")
    }

    /// Typed-text evidence can name its app only by bundle ID: such an app is drawn but never named.
    static func bundleIDNames() {
        let tool = Spec(id: "u-tool", from: (13, 0), to: (13, 40), app: "com.example.Tool", bundle: "com.example.Tool", count: 30)
        let mailSpec = Spec(id: "u-mail", from: (9, 0), to: (9, 20), app: "Mail", bundle: "com.apple.mail", count: 12)
        let notesSpec = Spec(id: "u-notes", from: (10, 0), to: (10, 10), app: "Notes", bundle: "com.apple.Notes", count: 5)
        let d = day(todayKey, [tool, mailSpec, notesSpec])
        let s = snapshot(d)
        check(s.topApps.first?.nameResolved == false, "fixture: the top app is known only by its bundle ID", "\(s.topApps.map(\.name))")
        // ux/declutter: the card has no Most actions line, so it names no app at all (checked in honesty()).
        let m = s.moments.first { $0.id == "u-tool" }!
        equal(FocusListLayout.appName(m), nil, "row: a bundle ID is never the row's app name")
        equal(FocusListLayout.rowAccessibilityLabel(m, timeZone: la), "com.example.Tool, 1:00 to 1:40 PM, 40 minutes",
              "row: VoiceOver skips an app known only by its bundle ID")
        let chips = FocusListHeader.chipModels(keys: [todayKey], digests: [todayKey: DayDigest.make(day: d, calendar: cal)], calendar: cal)
        check(chips.first?.topBundle == "com.example.Tool" && chips.first?.topName == nil, "chips: an unnamed top app keeps its icon, not its bundle ID as a name",
              "\(String(describing: chips.first))")
    }

    static func emptyDayAndChips() {
        let empty = snapshot(day("2026-09-20", []))
        let model = RibbonModel.make(snapshot: empty, state: .recording(since: nil), now: now, calendar: cal, isToday: false)
        check(model.segments.isEmpty && model.empty, "ribbon: an empty day has no segments")
        let spoken = FocusListSummaryCard.ribbonAccessibility(empty, model: model, timeZone: la)
        equal(spoken.label, "Activity", "ribbon: an empty day's VoiceOver label")
        let full = snapshot(day(todayKey, todaySpecs))
        let fullModel = RibbonModel.make(snapshot: full, state: .recording(since: nil), now: now, calendar: cal, isToday: true)
        equal(FocusListSummaryCard.ribbonAccessibility(full, model: fullModel, timeZone: la).label,
              "Activity from 8:42 AM to 4:18 PM, 4 moments", "ribbon: one VoiceOver element, range and moments")

        let digest = DayDigest.make(day: day("2026-09-20", []), calendar: cal)
        let loaded = DayDigest.make(day: day(todayKey, todaySpecs), calendar: cal)
        let chips = FocusListHeader.chipModels(keys: ["2026-09-19", "2026-09-20", todayKey],
                                               digests: ["2026-09-20": digest, todayKey: loaded], calendar: cal)
        equal(chips.map(\.id), ["2026-09-19", "2026-09-20", todayKey], "chips: one per key, oldest first")
        equal(chips[0].moments, nil, "chips: a day not read yet has no count (no guessed icon)")
        check(chips[0].topBundle == nil && chips[0].topName == nil, "chips: a day not read yet has no app icon")
        equal(chips[1].moments, 0, "chips: an empty day counts 0")
        check(chips[1].topBundle == nil && chips[1].topName == nil, "chips: an empty day has no app icon")
        check(chips[2].topBundle != nil, "chips: a loaded day shows its top app", "\(chips[2])")
        equal(FocusListHeader.chipKeys(focused: todayKey, today: todayKey, count: 5, calendar: cal),
              ["2026-09-18", "2026-09-19", "2026-09-20", "2026-09-21", todayKey], "chips: five days ending today")
        equal(FocusListHeader.chipKeys(focused: todayKey, today: todayKey, count: 3, calendar: cal),
              ["2026-09-20", "2026-09-21", todayKey], "chips: three days when narrow")
        check(!FocusListHeader.chipKeys(focused: "2026-09-01", today: todayKey, count: 5, calendar: cal).contains { $0 > todayKey },
              "chips: never past today")
        check(FocusListHeader.chipKeys(focused: "2026-09-01", today: todayKey, count: 5, calendar: cal).contains("2026-09-01"),
              "chips: an older focused day is among the chips")
        equal(FocusListHeader.jumpLabel(date(12, 0), calendar: cal), "Jump to date, Tuesday, September 22", "header: calendar tile's full-date label")
    }

    static func rowHooks() {
        let s = snapshot(day(todayKey, todaySpecs))
        let chrome = s.moments.first { $0.id == "t-chrome" }!
        equal(FocusListLayout.rowAccessibilityLabel(chrome, timeZone: la),
              "Reviewing the launch plan, Google Chrome, 2:30 to 3:20 PM, 50 minutes", "row: VoiceOver label is title, app, range, span")
        equal(FocusListLayout.rowAccessibilityValue(expanded: true), "Expanded", "row: expanded value")
        equal(FocusListLayout.rowAccessibilityValue(expanded: false), "Collapsed", "row: collapsed value")
        let sections = FocusListLayout.sections(s.moments, calendar: cal)
        equal(sections.map(\.part), [.afternoon, .morning], "sections: newest part first")
        equal(FocusListLayout.order(sections).map(\.id), ["t-notes", "t-chrome", "t-zed", "t-mail"], "rows: newest first within a part")
        // ux/declutter: a section header is its part's name alone (the rows carry their times).
        let timelineSource = source("Sources/MemoryUI/CanonicalTimeline.swift")
        check(timelineSource.contains("SectionHeader(section.part)") && !timelineSource.contains("FocusListLayout.detail("),
              "section: the header names the part, with no time range")
        equal(FocusListLayout.nearest(to: date(14, 34), in: s.moments)?.id, "t-chrome", "refresh: nearest start re-selects")
    }

    static func copyAndPausedHooks() {
        let s = snapshot(day(todayKey, todaySpecs))
        let chrome = s.moments.first { $0.id == "t-chrome" }!, notes = s.moments.first { $0.id == "t-notes" }!
        equal(FocusListLayout.copyText(chrome), "Reviewing the launch plan\n• Commented on the launch plan.\n• Opened the beta checklist.",
              "copy: title then bullets")
        equal(FocusListLayout.copyText(notes), nil, "copy: nothing to copy without a summary")
        equal(FocusListFailureCard.text(isToday: true), "Today couldn't be loaded.", "failure: today's copy")
        equal(FocusListFailureCard.text(isToday: false), "This day couldn't be loaded.", "failure: another day's copy")
        equal(FocusListEmptyCard.copy(isToday: false, state: nil).title, "Nothing recorded this day.", "empty: a past day never claims recording was off")
        equal(FocusListEmptyCard.copy(isToday: false, state: nil).detail, nil, "empty: a past day has no detail line")
        // ux/declutter: plain Off and Needs Permission add no line; the Start Recording pill and the orange
        // capsule right above say it.
        equal(FocusListEmptyCard.copy(isToday: true, state: .off(since: nil, reason: nil)).detail, nil, "empty: today while Off adds no line")
        equal(FocusListEmptyCard.copy(isToday: true, state: .needsPermission(missing: [])).detail, nil, "empty: today while Needs Permission adds no line")
        equal(FocusListEmptyCard.copy(isToday: true, state: .recording(since: nil)).detail, "Moments appear here as you work.", "empty: today while recording")
        equal(FocusListEmptyCard.copy(isToday: true, state: .paused(until: date(16, 36), since: date(16, 18), reason: nil)).detail, nil,
              "empty: today while paused adds no line (the paused row says nothing is recorded)")
        equal(FocusListEmptyCard.copy(isToday: true, state: .paused(until: nil, since: nil, reason: nil)).detail, nil, "empty: open-ended pause adds no line")
        equal(FocusListEmptyCard.copy(isToday: true, state: .off(since: nil, reason: "Development Trial · recording is disabled")).detail,
              "Development Trial · recording is disabled", "empty: Off for a reason shows the reason, not a start instruction")
        equal(FocusListEmptyCard.copy(isToday: true, state: .off(since: nil, reason: "Finish setup to start recording.")).detail,
              "Finish setup to start recording.", "empty: Off for setup shows the blocker")

        // The ribbon carries the day's last observation (the card's Latest line is gone, ux/declutter).
        let latestDay = snapshot(day(todayKey, todaySpecs))
        equal(latestDay.lastObserved, date(16, 18), "the day's last observation is the end of the ribbon's range")

        equal(CanonicalTimeline.excludeFailureMessage(MemError.invalid("Not saved. Recording is stopped. Retry.")), "Not saved. Recording is stopped. Retry.",
              "exclude: a failed save shows the app's status (recording stopped)")
        equal(CanonicalTimeline.excludeFailureMessage(MemError.invalid("This app is always private.")), "This app is always private.",
              "exclude: a guard's own text is shown")
        equal(CanonicalTimeline.excludeFailureMessage(MemError.missing), "The app wasn't excluded. Review exclusions in Settings.",
              "exclude: no hook → the generic line")
        check(source("Sources/MemoryUI/CanonicalTimeline.swift").contains("onError: { notice = .message(Self.excludeFailureMessage($0)) }"),
              "exclude: the confirmation's error reaches the notice through excludeFailureMessage")

        check(FocusListPausedRow.pause(in: .recording(since: nil)) == nil, "paused row: none while recording")
        check(FocusListPausedRow.pause(in: .off(since: nil, reason: nil)) == nil, "paused row: none while Off (the capsule owns it)")
        check(FocusListPausedRow.pause(in: .needsPermission(missing: [.inputMonitoring])) == nil, "paused row: none for Needs Permission")
        check(FocusListPausedRow.pause(in: nil) == nil, "paused row: none without a state")
        check(FocusListPausedRow.pause(in: .paused(until: date(16, 36), since: date(16, 18), reason: nil))?.until == date(16, 36), "paused row: timed pause")
        check(FocusListPausedRow.pause(in: .paused(until: nil, since: nil, reason: nil)) != nil, "paused row: open-ended pause")
        equal(FocusListPausedRow.title(until: date(16, 36), now: now, timeZone: la), "Paused until 4:36 PM", "paused row: timed title")
        equal(FocusListPausedRow.title(until: nil, now: now, timeZone: la), "Paused", "paused row: open-ended title")
        equal(FocusListPausedRow.title(until: date(16, 0), now: now, timeZone: la), "Paused", "paused row: a pause end already past is not claimed")
    }

    // MARK: The timeline, driven

    static func timelineKeysAndCommands() {
        todaySpecs = [mail, zed, chrome, notes]
        let calls = CaptureCalls()
        let b = browser()
        let state = CapturePresentation(state: .recording(since: date(8, 40)), canStop: true)
        let h = host(CanonicalTimeline(browser: b, state: state, actions: calls.actions))
        check(wait { b.today.snapshot?.dayKey == todayKey }, "timeline: today loads through the day cache")
        pump(0.2)
        equal(calls.total, 0, "capture: rendering calls no capture action")

        // Row VoiceOver, when SwiftUI exposes the tree offscreen.
        let chromeLabel = "Reviewing the launch plan, Google Chrome, 2:30 to 3:20 PM, 50 minutes"
        let rows = elements(h).filter { $0.accessibilityLabel() == chromeLabel }
        if rows.isEmpty {
            print("LIMIT: SwiftUI exposes no accessibility tree offscreen here; row labels checked through FocusListLayout, toggling through clicks and keys")
        } else {
            equal(rows.count, 1, "row: one VoiceOver element per row")
            equal(rows.first?.accessibilityValue() as? String, "Collapsed", "row: VoiceOver value before expanding")
            _ = rows.first?.accessibilityPerformPress(); pump()
            equal(b.expandedMomentID, "t-chrome", "row: VoiceOver press expands")
            _ = elements(h).first { $0.accessibilityLabel() == chromeLabel }?.accessibilityPerformPress(); pump()
            equal(b.expandedMomentID, nil, "row: VoiceOver press collapses")
        }

        pressDown()
        equal(b.selectedMomentID, "t-notes", "↓ with no selection selects the first row")
        pressDown()
        equal(b.selectedMomentID, "t-chrome", "↓ moves to the next row")
        pressDown(); pressUp()
        equal(b.selectedMomentID, "t-chrome", "↑ moves back")
        check(b.commandContext.hasSelection && b.commandContext.hasSummary, "commandContext: a selected summarized moment",
              "\(b.commandContext)")
        equal(b.commandContext.openTitle, "Open Original", "commandContext: a web moment opens its original")
        pressReturn()
        equal(b.expandedMomentID, "t-chrome", "Return expands the selected row")
        pressReturn()
        equal(b.expandedMomentID, nil, "Return again collapses it")
        pressReturn(); pressEscape()
        equal(b.expandedMomentID, nil, "Esc collapses")
        equal(b.selectedMomentID, "t-chrome", "Esc keeps the selection")

        pasteboard.clearContents()
        let general = NSPasteboard.general.changeCount
        pressCopy()
        equal(pasteboard.string(forType: .string), FocusListLayout.copyText(snapshot(day(todayKey, todaySpecs)).moments.first { $0.id == "t-chrome" }!),
              "⌘C copies the summary to the injected pasteboard")
        equal(NSPasteboard.general.changeCount, general, "⌘C leaves the general pasteboard alone when another is injected")
        pressUp()
        equal(b.selectedMomentID, "t-notes", "↑ to the pending row")
        check(!b.commandContext.hasSummary, "commandContext: a pending moment has no summary")
        pasteboard.clearContents()
        pressCopy()
        equal(pasteboard.string(forType: .string), nil, "⌘C copies nothing without a summary")

        // Days: ⌘[ ⌘] through the command stream; stop at today; the day's selection comes back.
        pressDown()
        equal(b.selectedMomentID, "t-chrome", "select before changing day")
        b.send(.previousDay); pump(0.2)
        equal(b.focusedDay, yesterdayKey, "⌘[ moves to yesterday")
        check(wait { b.selectedMomentID == nil }, "yesterday starts with no selection", "\(String(describing: b.selectedMomentID))")
        pressDown()
        check(wait { b.selectedMomentID == "y-safari" }, "↓ selects on yesterday once it loads", "\(String(describing: b.selectedMomentID))")
        b.send(.nextDay); pump(0.2)
        equal(b.focusedDay, nil, "⌘] returns to today")
        equal(b.selectedMomentID, "t-chrome", "today's selection comes back")
        b.send(.nextDay); pump(0.2)
        equal(b.focusedDay, nil, "⌘] stops at today")
        b.send(.previousDay); pump(0.1)
        equal(b.selectedMomentID, "y-safari", "yesterday's selection comes back")
        b.send(.today); pump(0.2)
        equal(b.focusedDay, nil, "Today returns to today")

        b.recallPresented = true; pump(0.1)
        b.send(.previousDay); pump(0.1)
        equal(b.focusedDay, nil, "commands are Recall's while Recall is visible")
        pressDown()
        equal(b.selectedMomentID, "t-chrome", "keys are Recall's while Recall is visible")
        b.recallPresented = false; pump(0.1)

        var posted: [String: String]? = nil
        let token = NotificationCenter.default.addObserver(forName: .daydreamRecallFilter, object: nil, queue: nil) { note in
            posted = note.userInfo as? [String: String]
        }
        b.send(.findRelated); pump(0.1)
        NotificationCenter.default.removeObserver(token)
        equal(posted?["site"], "github.com", "Find Related posts the site filter")
        check(b.recallPresented, "Find Related presents Recall")
        b.recallPresented = false; pump(0.1)

        // A refresh that drops the selected moment re-selects the one nearest its start.
        var moved = chrome
        moved.id = "t-chrome-2"; moved.from = (14, 35)
        todaySpecs = [mail, zed, moved, notes]
        b.dayCache.invalidate(todayKey)
        check(wait { b.today.snapshot?.moments.contains { $0.id == "t-chrome-2" } == true }, "refresh: today rereads after an invalidation")
        check(wait { b.selectedMomentID == "t-chrome-2" }, "refresh: a dropped selection re-selects the nearest start",
              "\(String(describing: b.selectedMomentID))")
        todaySpecs = [mail, zed, chrome, notes]

        equal(calls.total, 0, "capture: keys, day changes, expansion and Esc call no capture action")
        withExtendedLifetime(h) {}
    }

    /// Recall's Show in <Weekday> and Show in Today write the day and the ids together.
    static func handoffs() {
        todaySpecs = [mail, zed, chrome, notes]
        let b = browser()
        let h = host(CanonicalTimeline(browser: b, state: CapturePresentation(state: .recording(since: nil)), actions: CaptureActions()))
        _ = wait { b.today.snapshot?.dayKey == todayKey }
        pump(0.2)
        pressDown(); pressDown()
        equal(b.selectedMomentID, "t-chrome", "handoff: today's selection before")
        // Show in Monday: focusedDay, selectedMomentID and expandedMomentID in one go.
        b.focusedDay = yesterdayKey
        b.selectedMomentID = "y-safari"
        b.expandedMomentID = "y-safari"
        _ = wait { b.dayCache.cachedDay(yesterdayKey) != nil }
        pump(0.3)
        equal(b.focusedDay, yesterdayKey, "handoff: the past day shows")
        equal(b.selectedMomentID, "y-safari", "handoff: the handed-over selection survives the day's load")
        equal(b.expandedMomentID, "y-safari", "handoff: the handed-over expansion survives the day's load")
        b.send(.nextDay); pump(0.3)
        equal(b.selectedMomentID, "t-chrome", "handoff: today keeps the selection it had (not the handed-over id)")
        equal(b.expandedMomentID, nil, "handoff: today keeps its expansion")
        b.send(.previousDay); pump(0.3)
        equal(b.selectedMomentID, "y-safari", "handoff: the past day remembers the handed-over selection")
        equal(b.expandedMomentID, "y-safari", "handoff: the past day remembers the handed-over expansion")
        // Recall's Show in Today, while a past day shows: focusedDay = nil with the moment's id.
        b.focusedDay = nil
        b.expandedMomentID = "t-notes"
        pump(0.4)
        equal(b.focusedDay, nil, "handoff back to today: today shows")
        equal(b.expandedMomentID, "t-notes", "handoff back to today: the expansion survives")
        equal(b.selectedMomentID, "t-notes", "handoff back to today: a lone expansion is also the selection")
        b.send(.previousDay); pump(0.3)
        equal(b.selectedMomentID, "y-safari", "handoff back to today: the past day keeps its own selection")
        // A handed-over id the day doesn't have is cleared once the day is read.
        b.focusedDay = nil
        b.selectedMomentID = "no-such-moment"
        pump(0.4)
        equal(b.selectedMomentID, nil, "handoff: an id the day doesn't have is cleared")
        // A moment handed to today (Show in Today) is newer than today's last read (read 30 s ago): the id waits for
        // the reread instead of being dropped against the stale rows.
        b.send(.previousDay); pump(0.3)
        todaySpecs = [mail, zed, chrome, notes, Spec(id: "t-late", from: (16, 19), to: (16, 21), app: "Notes", bundle: "com.apple.Notes", count: 2)]
        b.now = { now.addingTimeInterval(30) }
        b.focusedDay = nil
        b.expandedMomentID = "t-late"
        _ = wait { b.today.snapshot?.moments.contains { $0.id == "t-late" } == true }
        pump(0.3)
        equal(b.expandedMomentID, "t-late", "handoff onto a stale today: the newer moment's expansion survives the reread")
        equal(b.selectedMomentID, "t-late", "handoff onto a stale today: the newer moment is selected")
        b.now = { now }
        todaySpecs = [mail, zed, chrome, notes]
        withExtendedLifetime(h) {}
    }

    /// `selectedCanonicalActivity`: shows the moment's detail once its day loads; nil before the load cancels it;
    /// an id on no day read so far is dropped instead of opening later.
    static func detailRequests() {
        todaySpecs = [mail, zed, chrome, notes]
        func slowBrowser() -> ActivityBrowser {
            let b = browser()
            let load = b.loadCanonicalDay!
            b.loadCanonicalDay = { key, cursor in
                try await Task.sleep(nanoseconds: 400_000_000)
                if key == "2026-09-10" {
                    return day(key, [Spec(id: "old-1", from: (10, 0), to: (10, 20), app: "Notes", bundle: "com.apple.Notes", count: 3)])
                }
                return try await load(key, cursor)
            }
            return b
        }
        // Asked for before today loads, kept: the detail opens (the list's keys pause under it).
        let a = slowBrowser()
        let ha = host(CanonicalTimeline(browser: a, state: CapturePresentation(state: .recording(since: nil)), actions: CaptureActions()))
        a.selectedCanonicalActivity = "t-chrome"
        _ = wait { a.today.snapshot?.dayKey == todayKey }
        pump(0.3)
        check(a.selectedMomentID == "t-chrome" && a.expandedMomentID == "t-chrome", "detail request: opens its moment once the day loads",
              "\(String(describing: a.selectedMomentID)) \(String(describing: a.expandedMomentID))")
        pressDown()
        equal(a.selectedMomentID, "t-chrome", "detail request: the pushed detail covers the list (keys go to the detail)")
        a.selectedCanonicalActivity = nil; pump(0.2)
        pressDown()
        equal(a.selectedMomentID, "t-zed", "detail request: nil pops the detail and the list's keys work again")
        withExtendedLifetime(ha) {}

        // Asked for, then cleared before today loads: nothing opens.
        let b = slowBrowser()
        let hb = host(CanonicalTimeline(browser: b, state: CapturePresentation(state: .recording(since: nil)), actions: CaptureActions()))
        b.selectedCanonicalActivity = "t-chrome"
        pump(0.1)
        b.selectedCanonicalActivity = nil
        _ = wait { b.today.snapshot?.dayKey == todayKey }
        pump(0.6)
        equal(b.selectedCanonicalActivity, nil, "detail request cancelled: stays cancelled")
        check(b.expandedMomentID != "t-chrome", "detail request cancelled: the moment isn't opened after the load")
        pressDown()
        equal(b.selectedMomentID, "t-notes", "detail request cancelled: no detail covers the list")
        withExtendedLifetime(hb) {}

        // A moment on a day no read has seen: looked for in a fresh read of the focused day, then dropped.
        let c = slowBrowser()
        let hc = host(CanonicalTimeline(browser: c, state: CapturePresentation(state: .recording(since: nil)), actions: CaptureActions()))
        _ = wait { c.today.snapshot?.dayKey == todayKey }
        pump(0.2)
        c.selectedCanonicalActivity = "old-1"
        check(wait(3) { c.selectedCanonicalActivity == nil }, "detail request on an unread day: dropped after the focused day is reread")
        equal(c.focusedDay, nil, "detail request on an unread day: the day doesn't change")
        c.focusedDay = "2026-09-10"
        _ = wait { c.dayCache.cachedDay("2026-09-10") != nil }
        pump(0.4)
        check(c.selectedMomentID == nil && c.expandedMomentID == nil, "detail request on an unread day: visiting that day later opens nothing",
              "\(String(describing: c.selectedMomentID)) \(String(describing: c.expandedMomentID))")
        pressDown()
        equal(c.selectedMomentID, "old-1", "detail request on an unread day: no detail covers that day's list")
        withExtendedLifetime(hc) {}
    }

    // MARK: Expanded body and detail (A1b)

    static func slice(_ id: String, summary: MomentSummaryState, count: Int, bullets: [String] = [], sites: [String] = [],
                      bundle: String = "com.apple.Notes", app: String = "Notes") -> MomentSlice {
        MomentSlice(id: id, dayKey: todayKey, start: date(14, 30), end: date(15, 20), title: "Moment \(id)", subject: "Moment \(id)",
                    firstBullet: bullets.first, bullets: bullets.map { MomentBullet(text: $0, correction: false) },
                    apps: [app], primaryBundle: bundle, bundles: [bundle], sites: sites,
                    actionIDs: (0..<count).map { "\(id)-a\($0)" }, actionCount: count, clusters: [date(14, 30)...date(15, 20)],
                    summary: summary, hasCorrection: false, primaryApp: app)
    }

    static func action(_ id: String, _ h: Int, _ m: Int, app: String, bundle: String, site: String = "", title: String) -> CanonicalAction {
        let value: [String: Any] = ["id": id, "evidenceIDs": [id + "-e"], "at": iso(date(h, m)), "kind": site.isEmpty ? "window.changed" : "browser.observed",
                                    "app": app, "bundle": bundle, "site": site, "title": title, "description": "Observed in \(app)",
                                    "state": "observed", "revision": "r1", "subject": title, "observationKey": id]
        return try! JSONDecoder().decode(CanonicalAction.self, from: JSONSerialization.data(withJSONObject: value))
    }

    /// fix/expanded-summary: which summary the open card shows and which bar it gets, for each summary state.
    static func expandedSummaryRules() {
        typealias E = FocusListExpanded
        let ready = MomentSummaryState.ready(generatedAt: nil, local: true)
        let caps = MomentActions.Capabilities(reopen: true, openApp: true, excludeApp: true, generate: true, delete: true, correct: true,
                                              summaries: SummaryAvailability(provider: .local, busy: false), calendar: cal, now: now)
        func bar(_ m: MomentSlice, _ c: MomentActions.Capabilities? = nil) -> [String] {
            E.barItems(MomentActions.items(for: m, context: .focusList, browser: c ?? caps), moment: m).map(\.title)
        }
        func sends(_ m: MomentSlice, _ lines: [String]) -> MomentSlice {
            var m = m; m.live = LiveMoment(label: "", kind: "", sends: lines, seconds: 600, idle: false, communication: true); return m
        }

        // 1. The owner's "Email in Gmail" card, through the real pipeline (note JSON → TodaySnapshot → MomentSlice): its
        // one bullet is its collapsed subtitle. Before: no Summary section, Summarize Now in place of Copy Summary.
        let gmailSpec = Spec(id: "t-gmail", from: (13, 0), to: (13, 12), app: "Google Chrome", bundle: "com.google.Chrome",
                             site: "mail.google.com", count: 6, title: "Email in Gmail", bullets: ["Went through the Gmail inbox."])
        let chatSpec = Spec(id: "t-gpt", from: (13, 20), to: (13, 40), app: "ChatGPT", bundle: "com.openai.chat", count: 9,
                            title: "Clarifying vision and delta with ChatGPT",
                            bullets: ["Asked ChatGPT to clarify the product vision.", "Compared the delta between the two plans."])
        let owner = snapshot(day(todayKey, [gmailSpec, chatSpec]))
        let gmail = owner.moments.first { $0.id == "t-gmail" }!
        check(gmail.summary.isReady, "expanded summary (Gmail): the fixture's note is ready", "\(gmail.summary)")
        equal(MomentSubtitle.text(for: gmail), "Went through the Gmail inbox", "expanded summary (Gmail): the collapsed subtitle is the one bullet")
        check(E.showsSummary(gmail), "expanded summary (Gmail): one bullet equal to the subtitle still shows the Summary section")
        equal(E.summaryStatus(for: gmail, provider: .local), nil, "expanded summary (Gmail): the bullet itself shows, not a status line")
        equal(bar(gmail), ["Copy Summary", "Forget This Moment…"], "expanded summary (Gmail): Copy Summary in the bar, no Summarize Now")
        check(!FocusListLayout.expandedMeta(gmail, timeZone: la).contains("Gmail inbox"),
              "expanded summary (Gmail): the open header's line is the time range, so the Summary is the only place the line shows")
        // 2. Two bullets (the ChatGPT card that already worked): unchanged.
        let gpt = owner.moments.first { $0.id == "t-gpt" }!
        equal(gpt.bullets.map(\.text).count, 2, "expanded summary (two bullets): the fixture's note has two bullets")
        check(E.showsSummary(gpt) && E.summaryStatus(for: gpt, provider: .local) == nil, "expanded summary (two bullets): shows both bullets")
        equal(bar(gpt), ["Copy Summary", "Forget This Moment…"], "expanded summary (two bullets): Copy Summary in the bar")

        // 3. Hand-built slices: one bullet equal to the subtitle, one bullet that isn't, two bullets, lines only.
        let same = slice("f2", summary: ready, count: 3, bullets: ["Asked Claude to shorten the intro."])
        equal(MomentSubtitle.text(for: same), "Asked Claude to shorten the intro", "expanded summary: the one bullet is the subtitle (fixture)")
        check(E.showsSummary(same), "expanded summary: one bullet equal to the subtitle shows")
        equal(bar(same), ["Copy Summary", "Forget This Moment…"], "expanded summary: one bullet equal to the subtitle keeps Copy Summary")
        // A bullet that differs from the subtitle: the title already says it, so the subtitle falls to the time.
        let other = slice("f4", summary: ready, count: 3, bullets: ["Moment f4"])
        check(MomentSubtitle.text(for: other) != "Moment f4", "expanded summary: fixture's one bullet differs from the subtitle",
              MomentSubtitle.text(for: other))
        check(E.showsSummary(other) && E.summaryStatus(for: other, provider: .local) == nil, "expanded summary: one bullet unlike the subtitle shows")
        equal(bar(other), ["Copy Summary", "Forget This Moment…"], "expanded summary: one bullet unlike the subtitle keeps Copy Summary")
        let two = slice("f3", summary: ready, count: 3, bullets: ["Asked Claude to shorten the intro.", "Read the Claude reply about the outline."])
        check(E.showsSummary(two), "expanded summary: two bullets show")
        equal(bar(two), ["Copy Summary", "Forget This Moment…"], "expanded summary: two bullets keep Copy Summary")
        // Ready, every bullet dropped as filler, the sends by code stand in (`MomentSlice.lines`).
        let linesOnly = sends(slice("f5", summary: ready, count: 3), ["Emailed Sam"])
        equal(linesOnly.lines, ["Emailed Sam"], "expanded summary: fixture's ready note has only lines")
        check(E.showsSummary(linesOnly) && E.summaryStatus(for: linesOnly, provider: .local) == nil,
              "expanded summary: a ready note with only lines shows them")
        equal(bar(linesOnly), ["Copy Summary", "Forget This Moment…"], "expanded summary: a ready note with only lines keeps Copy Summary")
        // Copy Summary whenever a ready summary exists: every ready slice above, and one with a correction.
        for m in [gmail, gpt, same, other, two, linesOnly] {
            check(m.hasSummary && bar(m).contains("Copy Summary") && !bar(m).contains("Summarize Now"),
                  "expanded summary: a ready summary always has Copy Summary in the bar (\(m.id))")
        }

        // 4. Not ready: unchanged. Pending, off and failed ("never written") show only sends by code, never Copy Summary.
        for (state, name) in [(MomentSummaryState.pending, "pending"), (.summariesOff, "off"), (.notWritten, "failed")] {
            let bare = slice("n-\(name)", summary: state, count: 5)
            check(!E.showsSummary(bare), "expanded summary: \(name) with no sends → no summary area")
            equal(E.summaryStatus(for: bare, provider: .local), FocusSummaryStatus(text: ""), "expanded summary: \(name) says nothing")
            let sent = sends(bare, ["Texted Q7"])
            check(E.showsSummary(sent) && E.summaryStatus(for: sent, provider: .local) == nil, "expanded summary: \(name) with sends shows them")
            check(!bar(bare).contains("Copy Summary") && !bar(sent).contains("Copy Summary"), "expanded summary: \(name) has no Copy Summary",
                  "\(bar(sent))")
        }
        equal(bar(slice("n-pending", summary: .pending, count: 5)), ["Summarize Now", "Forget This Moment…"],
              "expanded summary: pending keeps Summarize Now")
        var offCaps = caps; offCaps.summaries = SummaryAvailability(provider: .off, busy: false)
        equal(bar(slice("n-off", summary: .summariesOff, count: 5), offCaps), ["Forget This Moment…"],
              "expanded summary: summaries off has neither Copy Summary nor Summarize Now")
        check(!E.showsSummary(slice("n-long", summary: .tooLong, count: 442)) && E.showsSummary(slice("n-inc", summary: .incomplete, count: 5)),
              "expanded summary: too long hides the area and partial says why (unchanged)")
    }

    /// fix/summary-fallback (Codex directed fix, 9/30): the writer's code fallback note (every model answer failed) names only
    /// a place: "Typed a draft in Notes.". The filler rule dropped it, so the QA copy's TextEdit, Terminal and Notes moments
    /// showed a title and nothing under it. Only that note's own lines, under its own provider and version, show; the same
    /// words from a model, and any other place-only line, are still filler.
    static func fallbackSummaryRules() {
        typealias E = FocusListExpanded
        let fb = (gen: "code/fallback-notes", ver: "code-fallback2-validator12")
        func spec(_ id: String, _ app: String, _ bundle: String, _ title: String, _ bullets: [String], gen: String, ver: String, site: String = "") -> Spec {
            var s = Spec(id: id, from: (11, 0), to: (11, 10), app: app, bundle: bundle, site: site, count: 4, title: title, bullets: bullets)
            s.generator = gen; s.version = ver; return s
        }
        // The QA copy's three title-only moments, as code's fallback note wrote them (titles and lines from qf16-fb).
        let cases: [(id: String, app: String, bundle: String, title: String, line: String)] = [
            ("fb-textedit", "TextEdit", "com.apple.TextEdit", "TextEdit", "Typed a draft in TextEdit."),
            ("fb-terminal", "Terminal", "com.apple.Terminal", "Terminal in qa", "Typed a draft in Terminal."),
            ("fb-notes", "Notes", "com.apple.Notes", "Notes", "Typed a draft in Notes.")]
        let code = snapshot(day(todayKey, cases.map { spec($0.id, $0.app, $0.bundle, $0.title, [$0.line], gen: fb.gen, ver: fb.ver) }))
        for c in cases {
            let m = code.moments.first { $0.id == c.id }!
            equal(m.bullets.map(\.text), [c.line], "fallback summary (\(c.app)): code's line is the moment's one bullet")
            equal(MomentSubtitle.text(for: m), String(c.line.dropLast()), "fallback summary (\(c.app)): collapsed, the line is the subtitle")
            check(E.showsSummary(m) && E.summaryStatus(for: m, provider: .local) == nil,
                  "fallback summary (\(c.app)): expanded, the Summary section shows the line (no status line)")
            check(m.hasSummary, "fallback summary (\(c.app)): Copy Summary has the line to copy")
            let words = (c.title + " " + m.bullets.map(\.text).joined(separator: " ")).lowercased()
            check(!["sent", "delivered", "posted", "published", "about", "emailed", "texted", "replied"].contains { words.range(of: "\\b\($0)\\b", options: .regularExpression) != nil },
                  "fallback summary (\(c.app)): no delivery, publication or topic words", words)
        }
        // The same words from a model are filler, as before: nothing under the title, no Summary section.
        let model = snapshot(day(todayKey, cases.map { spec($0.id, $0.app, $0.bundle, $0.title, [$0.line], gen: "local/qwen3.5-4b-q4_k_m", ver: "qwen35-4b-q4-b9723-prompt10-validator12") }))
        for c in cases {
            let m = model.moments.first { $0.id == c.id }!
            equal(m.bullets.map(\.text), [], "fallback summary (\(c.app)): the model's same line is still filler")
            check(!E.showsSummary(m), "fallback summary (\(c.app)): the model's filler line shows no Summary section")
        }
        // Only the pair: code's provider with another version, or the version under another provider, is ordinary.
        let halves = snapshot(day(todayKey, [spec("h1", "TextEdit", "com.apple.TextEdit", "TextEdit", ["Typed a draft in TextEdit."], gen: fb.gen, ver: "code-moment6-validator12"),
                                             spec("h2", "Notes", "com.apple.Notes", "Notes", ["Typed a draft in Notes."], gen: "code/moment-notes", ver: fb.ver),
                                             spec("h3", "Terminal", "com.apple.Terminal", "Terminal", ["Typed a draft in Terminal."], gen: "local/qwen3.5-4b-q4_k_m", ver: fb.ver)]))
        for m in halves.moments { equal(m.bullets.map(\.text), [], "fallback summary: half the pair (\(m.id)) is ordinary filler") }
        // In code's note, only code's own place lines: another place-only line is still filler, and a real line stays.
        let mixed = snapshot(day(todayKey, [spec("mx", "TextEdit", "com.apple.TextEdit", "TextEdit",
                                                 ["Typed a draft in TextEdit.", "Used TextEdit.", "In TextEdit."], gen: fb.gen, ver: fb.ver),
                                            spec("mx-x", "Google Chrome", "com.google.Chrome", "Post on X",
                                                 ["Typed a draft in X.", "Used the send key in X."], gen: fb.gen, ver: fb.ver, site: "x.com")]))
        equal(mixed.moments.first { $0.id == "mx" }!.bullets.map(\.text), ["Typed a draft in TextEdit."],
              "fallback summary: code's note keeps its own line and still drops other filler")
        equal(mixed.moments.first { $0.id == "mx-x" }!.bullets.map(\.text), ["Typed a draft in X.", "Used the send key in X."],
              "fallback summary (X): the draft line and the send-key line both show, nothing more")
        // Attribution as rendered: side by side in one day, code's fallback note, the moment writer by code, the local
        // model's note and the cloud model's note. Only the model's carry the model's mark; only the cloud one the chip.
        let side = snapshot(day(todayKey, [spec("at-fb", "TextEdit", "com.apple.TextEdit", "TextEdit", ["Typed a draft in TextEdit."], gen: fb.gen, ver: fb.ver),
                                           spec("at-code", "Notes", "com.apple.Notes", "Notes", ["Wrote in Notes."], gen: "code/moment-notes", ver: "code-moment6-validator12"),
                                           spec("at-local", "Pages", "com.apple.iWork.Pages", "Plan", ["Outlined the launch plan."], gen: "local/qwen3.5-4b-q4_k_m", ver: "qwen35-4b-q4-b9723-prompt10-validator12"),
                                           spec("at-cloud", "Keynote", "com.apple.iWork.Keynote", "Deck", ["Reworked the launch deck."], gen: "openrouter/deepseek/deepseek-v4-flash", ver: "deepseek-v4-flash-0731-zdr-prompt10-validator12")]))
        let mark = Dictionary(uniqueKeysWithValues: side.moments.map { ($0.id, (E.showsModelMark($0), E.showsCloudKeyChip($0), $0.byCode)) })
        check(mark["at-fb"].map { !$0.0 && !$0.1 && $0.2 } ?? false, "fallback summary: code's fallback note carries no model mark and no chip", "\(String(describing: mark["at-fb"]))")
        check(mark["at-code"].map { !$0.0 && !$0.1 && $0.2 } ?? false, "fallback summary: the moment writer by code carries no model mark", "\(String(describing: mark["at-code"]))")
        check(mark["at-local"].map { $0.0 && !$0.1 && !$0.2 } ?? false, "fallback summary: the local model's note keeps the model mark (no cloud chip)", "\(String(describing: mark["at-local"]))")
        check(mark["at-cloud"].map { $0.0 && $0.1 && !$0.2 } ?? false, "fallback summary: the cloud model's note keeps the model mark and the cloud-key chip", "\(String(describing: mark["at-cloud"]))")
    }

    static func expandedRules() {
        typealias E = FocusListExpanded
        // Summary state (amendments A1): the body follows MomentSummaryState. fix/day-card: pending has no skeleton and
        // no text; the moment's sends by code show instead when it has some (`MomentSlice.lines`).
        let pending = slice("p", summary: .pending, count: 17)
        for provider in [SummaryAvailability.Provider.local, .cloud] {
            equal(E.summaryStatus(for: pending, provider: provider), FocusSummaryStatus(text: ""),
                  "expanded: pending → no skeleton, no text (\(provider))")
        }
        equal(E.summaryStatus(for: slice("p2", summary: .pending, count: 401), provider: .local), FocusSummaryStatus(text: ""),
              "expanded: pending over 400 actions claims no writer either")
        check(!E.showsSummary(pending), "expanded: pending with no sends and no correction → no summary area")
        // Summaries off: the summary area shows only a correction (`showsSummary`); the day card has the Turn On link.
        check(!E.showsSummary(slice("o", summary: .summariesOff, count: 17)), "expanded: summaries off and no correction → no summary area")
        equal(E.summaryStatus(for: slice("o", summary: .summariesOff, count: 17), provider: .off), FocusSummaryStatus(text: ""),
              "expanded: summaries off with a correction shows the correction alone")
        let long = E.summaryStatus(for: slice("l", summary: .tooLong, count: 442), provider: .local)
        equal(long, FocusSummaryStatus(text: "Too long to summarize"), "expanded: too long, no skeleton, no limit line")
        // ux/declutter: a too-long moment has no summary area unless a correction of the person's is there to show
        // (then this line heads it); nothing will come and nothing there can change it.
        check(!E.showsSummary(slice("l2", summary: .tooLong, count: 442)), "expanded: too long and no correction → no summary area")
        // N16: a ready note whose every bullet was dropped as filler has no "Summary" header over nothing.
        check(!E.showsSummary(slice("f", summary: .ready(generatedAt: nil, local: true), count: 3)), "expanded: a ready note with no bullets left → no summary area (N16)")
        // fix/expanded-summary (owner, 9/30; supersedes fix/sx-all round 1's "no repeated summary"): a ready note always
        // shows in the open card, one bullet or many, even when that bullet is the collapsed row's subtitle: open, the
        // header's line is the time range (`FocusListLayout.expandedMeta`), so the summary is nowhere else on the card.
        expandedSummaryRules()
        fallbackSummaryRules()
        let partial = E.summaryStatus(for: slice("i", summary: .incomplete, count: 12), provider: .local)
        equal(partial?.text, "Summary unavailable. Some of this moment may be missing.", "expanded: a partial day's moment says why and what's missing")
        check(partial?.skeleton == false && partial?.settingsLink == false, "expanded: partial has no skeleton and no Settings link")
        equal(E.summaryStatus(for: slice("r", summary: .ready(generatedAt: nil, local: true), count: 17, bullets: ["Read the plan."]), provider: .local), nil,
              "expanded: a ready note's bullets show (no status line)")
        check(E.summaryStatus(for: slice("r2", summary: .ready(generatedAt: nil, local: true), count: 17), provider: .local)?.skeleton == false,
              "expanded: a ready note without bullets shows its subtitle, not a skeleton")
        for provider in SummaryAvailability.Provider.allCases {
            for state in [MomentSummaryState.summariesOff, .tooLong, .incomplete] {
                let text = E.summaryStatus(for: slice("x", summary: state, count: 442), provider: provider)?.text ?? ""
                check(!text.contains("on this Mac"), "expanded: \(state) never claims on this Mac (\(provider))", text)
            }
        }
        // The model mark (spec §1.2): only beside text the model wrote or is writing.
        check(E.showsModelMark(slice("mm", summary: .ready(generatedAt: nil, local: true), count: 3, bullets: ["Read the plan."])),
              "expanded: the model mark shows for a ready summary the model wrote")
        check(![MomentSummaryState.pending, .summariesOff, .tooLong, .incomplete, .notWritten].contains { E.showsModelMark(slice("mm", summary: $0, count: 3)) },
              "expanded: no model mark on lines by code (pending, off, too long, partial, never written)")

        // The fixture's own moments, through TodaySnapshot.
        let s = snapshot(day(todayKey, todaySpecs))
        equal(E.summaryStatus(for: s.moments.first { $0.id == "t-zed" }!, provider: .local), FocusSummaryStatus(text: ""),
              "expanded: the 442-action moment waits for its segmented summary like any pending moment (claude/ready-1002)")
        equal(E.summaryStatus(for: s.moments.first { $0.id == "t-notes" }!, provider: .local), FocusSummaryStatus(text: ""),
              "expanded: the 5-action pending moment shows no skeleton")

        // Action bar and VoiceOver named actions.
        let caps = MomentActions.Capabilities(reopen: true, openApp: true, excludeApp: true, generate: true, delete: true, correct: true,
                                              summaries: SummaryAvailability(provider: .local, busy: false), calendar: cal, now: now)
        let chrome = s.moments.first { $0.id == "t-chrome" }!
        let web = MomentActions.items(for: chrome, context: .focusList, browser: caps)
        // ux/declutter: Find Related Moments moved to the context and Moment menus (⌘R still works there).
        // fix/show-all (owner): no Open Original button; each Windows and pages entry opens its own page (⌘↩ stays in the menus).
        equal(E.barItems(web).map(\.title), ["Copy Summary", "Forget This Moment…"],
              "bar: Copy Summary, then Forget This Moment… (no Open Original button)")
        equal(E.barItems(web).map { $0.keys ?? "" }, ["⌘C", ""], "bar: ⌘C hint, none on Forget")
        check(web.contains { $0.id == .openOriginal && $0.keys == "⌘↩" }, "menus: Open Original keeps ⌘↩")
        check(web.contains { $0.id == .findRelated && $0.keys == "⌘R" }, "menus: Find Related Moments keeps ⌘R")
        check(!E.barItems(web).contains { [.editCorrection, .exclude].contains($0.id) }, "bar: Edit Correction and Exclude stay in the menus")
        equal(E.accessibilityActions(web).map(\.title), ["Open Original", "Copy Summary", "Forget This Moment…"],
              "VoiceOver: the body's named actions (no Find Related Moments in a moment's detail, owner 9/30)")
        let notes = s.moments.first { $0.id == "t-notes" }!
        let native = MomentActions.items(for: notes, context: .focusList, browser: caps)
        equal(E.barItems(native).map(\.title), ["Summarize Now", "Forget This Moment…"],
              "bar: a pending window moment offers Summarize Now (no Open <App> button)")
        equal(E.barItems(native).first { $0.id == .summarizeNow }?.keys, nil, "bar: Summarize Now has no keycap")
        equal(native.first { $0.id == .openApp }?.keys, "⌘↩", "menus: Open <App> is ⌘↩")
        equal(E.accessibilityActions(native).map(\.title), ["Open Notes", "Forget This Moment…"],
              "VoiceOver: no Copy Summary without a summary")
        let partialDay = snapshot(day(todayKey, todaySpecs, partial: true)).moments.first { $0.id == "t-notes" }!
        equal(partialDay.summary, .incomplete, "fixture: an unsummarized moment on a partial day is incomplete")
        let partialItems = MomentActions.items(for: partialDay, context: .focusList, browser: caps)
        check(E.barItems(partialItems).contains { $0.id == .forget && !$0.enabled }, "bar: Forget is shown disabled on a partial day")
        check(!E.accessibilityActions(partialItems).contains { $0.id == .forget }, "VoiceOver: no Forget action while it can't run")
        let bare = MomentActions.items(for: chrome, context: .focusList, browser: MomentActions.Capabilities(calendar: cal, now: now))
        equal(E.barItems(bare).map(\.id), [.copySummary], "bar: only what the browser can do")

        // fix/resummarize (owner, test 7): a moment that already has a summary offers Summarize Now in its menus (a fresh
        // note from everything in it now); the bar keeps Copy Summary alone.
        equal(web.filter { [.copySummary, .summarizeNow].contains($0.id) }.map(\.title), ["Copy Summary", "Summarize Now"],
              "menus: a summarized moment offers Copy Summary and Summarize Now")
        check(!E.barItems(web).contains { $0.id == .summarizeNow }, "bar: a summarized moment's bar keeps Copy Summary, no Summarize Now")
        check(MomentActions.canSummarizeNow(chrome, caps: caps) && MomentActions.canSummarizeNow(notes, caps: caps),
              "Summarize Now: a written moment and a pending one")
        var cloudCaps = caps
        cloudCaps.summaries = SummaryAvailability(provider: .cloud, busy: false, writesFrom: chrome.start.addingTimeInterval(60))
        check(!MomentActions.items(for: chrome, context: .focusList, browser: cloudCaps).contains { $0.id == .summarizeNow },
              "Summarize Now: never for a moment from before cloud summaries were turned on")
        var offCaps = caps
        offCaps.summaries = SummaryAvailability(provider: .off, busy: false)
        check(!MomentActions.items(for: chrome, context: .focusList, browser: offCaps).contains { $0.id == .summarizeNow },
              "Summarize Now: never while summaries are off")
        // fix/resummarize: how long is never the summary ("Under a minute." was the owner's x.com moment's only line).
        let short = Spec(id: "t-x", from: (16, 30), to: (16, 30), app: "Google Chrome", bundle: "com.google.Chrome", site: "x.com", count: 2,
                         title: "Post on X", bullets: ["Under a minute."])
        let longer = Spec(id: "t-y", from: (16, 40), to: (16, 46), app: "Google Chrome", bundle: "com.google.Chrome", site: "x.com", count: 3,
                          title: "Post on X", bullets: ["About 6 minutes."])
        let viewed = Spec(id: "t-z", from: (16, 50), to: (16, 50), app: "Google Chrome", bundle: "com.google.Chrome", site: "x.com", count: 2,
                          title: "Post on X", bullets: ["Viewed fixtureuser's post on X."])
        let durations = snapshot(day(todayKey, [short, longer, viewed]))
        for id in ["t-x", "t-y"] {
            let m = durations.moments.first { $0.id == id }!
            check(m.bullets.isEmpty && !E.showsSummary(m) && !MomentSubtitle.text(for: m).lowercased().contains("under a minute"),
                  "summary: a duration line is no summary (\(id): nothing shown, never \"Under a minute.\")", "\(m.bullets)")
        }
        let page = durations.moments.first { $0.id == "t-z" }!
        equal(page.bullets.map(\.text), ["Viewed fixtureuser's post on X."], "summary: a line naming the page stays")
        // fix/resummarize: while Summarize Now runs, that moment only says "Updating…" (its line kept, dimmed, on the same
        // line; the expanded header's range gains it), and it clears when the writer returns, stored or failed.
        equal(MomentSubtitle.rowText(for: chrome, updating: true), MomentSubtitle.rowText(for: chrome) + " · Updating\u{2026}",
              "updating: the row keeps its line and adds Updating…")
        equal(MomentSubtitle.rowText(for: chrome, updating: false), MomentSubtitle.rowText(for: chrome), "updating: other rows unchanged")
        equal(FocusListLayout.expandedMeta(chrome, timeZone: la, updating: true), "2:30\u{2013}3:20 PM · Updating\u{2026}",
              "updating: the expanded header's range line says Updating…")
        let ub = browser()
        let gate = FlagBox()
        var seenDuring: Set<String> = []
        ub.generateCanonicalNote = { [weak ub] _, _, _, _ in
            seenDuring = ub?.updatingMoments ?? []
            while !gate.open { try await Task.sleep(nanoseconds: 10_000_000) }
            if gate.fail { throw MemError.missing }
        }
        Task { @MainActor in try? await ub.summarizeNow(day: todayKey, timeZone: la.identifier, id: "t-chrome", end: chrome.end) }
        _ = wait { !seenDuring.isEmpty }
        check(seenDuring == ["t-chrome"] && ub.updatingMoments == ["t-chrome"], "updating: only the clicked moment is updating while it runs", "\(seenDuring)")
        gate.open = true
        _ = wait { ub.updatingMoments.isEmpty }
        check(ub.updatingMoments.isEmpty, "updating: clears when the new note is stored")
        gate.open = false; gate.fail = true; seenDuring = []
        var failed = false
        Task { @MainActor in do { try await ub.summarizeNow(day: todayKey, timeZone: la.identifier, id: "t-notes", end: notes.end) } catch { failed = true } }
        _ = wait { !seenDuring.isEmpty }
        gate.open = true
        _ = wait { failed }
        check(failed && ub.updatingMoments.isEmpty, "updating: clears on a failure (the Couldn't summarize notice follows)")

        // Row header when expanded: the range alone (ux/declutter: the action count was internal).
        equal(FocusListLayout.expandedMeta(chrome, timeZone: la), "2:30\u{2013}3:20 PM", "expanded row: the range")
        equal(FocusListLayout.expandedMeta(s.moments.first { $0.id == "t-zed" }!, timeZone: la), "1:05\u{2013}2:20 PM",
              "expanded row: a long moment shows no count")

        // Windows and pages.
        let visits = (0..<5).map { action("v\($0)", 10, 2 * $0, app: "Safari", bundle: "com.apple.Safari", site: "developer.apple.com",
                                          title: "Event taps \($0)") }
        let one = E.sources(from: visits.reversed())
        equal(one.count, 1, "sources: five visits of one page are one source")
        equal(one.first?.count, 5, "sources: the page counts its five visits")
        equal(one.first?.openActionID, "v4", "sources: a page opens its latest visit")
        equal(one.first?.evidenceIDs, ["v4-e"], "sources: the latest visit's own evidence")
        equal(one.first?.title, "Event taps 4", "sources: the latest title")
        check(one.first.map { $0.first == date(10, 0) && $0.last == date(10, 8) } == true, "sources: first and last seen")
        var mixed = [
            action("m0", 9, 0, app: "TextEdit", bundle: "com.apple.TextEdit", title: "Bench notes"),
            action("m1", 9, 5, app: "Safari", bundle: "com.apple.Safari", site: "https://example.org/sensors", title: "Sensor research"),
            action("m2", 9, 10, app: "com.example.Tool", bundle: "com.example.Tool", title: "Untitled"),
            action("m3", 9, 15, app: "Google Chrome", bundle: "com.google.Chrome", site: "github.com", title: "sensors"),
            action("m4", 9, 20, app: "Notes", bundle: "com.apple.Notes", title: "Checklist"),
            action("m5", 9, 25, app: "Mail", bundle: "com.apple.mail", title: "Inbox"),
            action("m6", 9, 30, app: "Safari", bundle: "com.apple.Safari", site: "example.org", title: "Sensor research, part 2"),
            action("m7", 9, 35, app: "TextEdit", bundle: "com.apple.TextEdit", title: "Bench notes"),
            action("m8", 9, 40, app: "Freeform", bundle: "com.apple.freeform", title: "Board"),
            action("m9", 9, 45, app: "com.example.Tool", bundle: "com.example.Tool", title: "Untitled"),
            action("m10", 9, 50, app: "Google Chrome", bundle: "com.google.Chrome", site: "github.com", title: "sensors"),
        ]
        mixed.append(action("m11", 9, 55, app: "Safari", bundle: "com.apple.Safari", site: "example.org", title: "Sensor research, part 3"))
        let list = E.sources(from: mixed.shuffled())
        equal(list.count, E.sourceLimit, "sources: at most three")
        equal(E.sourceLimit, 3, "sources: the limit is three")
        equal(list.map(\.openActionID), ["m7", "m11", "m10"],
              "sources: the three with the most actions, listed by first seen (ties keep the earlier)")
        check(zip(list, list.dropFirst()).allSatisfy { $0.first <= $1.first }, "sources: chronological")
        equal(list.first { $0.openActionID == "m11" }?.site, "example.org", "sources: a page is one per host (URL and host agree)")
        equal(list.first { $0.openActionID == "m11" }?.count, 3, "sources: a host's visits add up")
        let tool = E.sources(from: [action("m9", 9, 45, app: "com.example.Tool", bundle: "com.example.Tool", title: "Untitled")]).first
        equal(tool?.app, nil, "sources: an app known only by its bundle ID has no name")
        check(tool.map { !$0.detail(la).contains("com.example") && !$0.title.contains("com.example") } == true,
              "sources: a bundle ID is never shown", tool.map { $0.title + " / " + $0.detail(la) } ?? "")
        // ux/declutter: the icon names the app, so a window's line is its span alone.
        equal(list.first { $0.bundle == "com.apple.TextEdit" }?.detail(la), "9:00\u{2013}9:35 AM", "sources: a window's span")
        equal(list.first { $0.site == "github.com" }?.detail(la), "github.com · 9:15\u{2013}9:50 AM", "sources: a page's host and span")
        check(!list.contains { $0.detail(la).localizedCaseInsensitiveContains("edited") }, "sources: never claims edited")
        equal(list.first { $0.bundle == "com.apple.TextEdit" }?.detail(la, complete: false), "",
              "sources: a read short of every member claims no time")
        equal(list.first { $0.site == "github.com" }?.detail(la, complete: false), "github.com", "sources: a short read keeps a page's host, no time")
        check(!source("Sources/MemoryUI/FocusListExpanded.swift").contains("incompleteNote"),
              "sources: no separate incomplete note (the moment's summary line says it may be missing)")
        let notesSource = E.sources(from: [action("n0", 9, 0, app: "Notes", bundle: "com.apple.Notes", title: "")]).first
        equal(notesSource?.title, "Notes", "sources: an untitled window falls back to its app")
        equal(E.sources(from: []), [], "sources: none without actions")

        // Detail order.
        let unordered = [action("d2", 11, 0, app: "Notes", bundle: "com.apple.Notes", title: "b"),
                         action("d0", 9, 0, app: "Notes", bundle: "com.apple.Notes", title: "a"),
                         action("d1", 10, 0, app: "Notes", bundle: "com.apple.Notes", title: "c")]
        equal(FocusListDetail.chronological(unordered).map(\.id), ["d0", "d1", "d2"], "detail: oldest first")

        // Load More Actions only while more can exist.
        typealias D = FocusListDetail
        check(D.canLoadMore(shown: 50, complete: false, exhausted: false), "detail: 50 of 442 found → Load More Actions")
        check(!D.canLoadMore(shown: 17, complete: true, exhausted: false), "detail: all found → no Load More Actions")
        check(!D.canLoadMore(shown: 26, complete: false, exhausted: true), "detail: pages ran out → no Load More Actions")
        check(!D.canLoadMore(shown: 0, complete: false, exhausted: false), "detail: nothing shown (loading or failed) → no Load More Actions")
        check(D.isExhausted(found: 26, complete: false, wanted: 50, members: 250), "detail: fewer than asked, not all → exhausted")
        check(!D.isExhausted(found: 50, complete: false, wanted: 50, members: 250), "detail: as many as asked → more may exist")
        check(!D.isExhausted(found: 17, complete: true, wanted: 50, members: 17), "detail: all found is never exhausted")
        check(D.isExhausted(found: 200, complete: false, wanted: 250, members: 250), "detail: a Load More that finds fewer than asked → exhausted")
    }

    static func expandedHosted() {
        todaySpecs = [mail, zed, chrome, notes]
        let calls = CaptureCalls()
        let b = browser()
        let probe = FocusListProbe()
        let h = host(CanonicalTimeline(browser: b, state: CapturePresentation(state: .recording(since: nil)), actions: calls.actions)
            .environment(\.daydreamFocusListProbe, probe))
        _ = wait { b.today.snapshot != nil }
        pump(0.2)
        let collapsed = probe.rowFrames["t-chrome"]?.height ?? 0
        check(abs(collapsed - 52) < 1, "hosted: a collapsed row is 52 pt", "\(collapsed)")
        b.selectedMomentID = "t-chrome"; b.expandedMomentID = "t-chrome"
        check(wait { probe.sources["t-chrome"] != nil }, "hosted: the expanded body lists its windows and pages")
        pump(0.2)
        let listed = probe.sources["t-chrome"] ?? []
        equal(listed.map(\.site), ["github.com"], "hosted: the 17 github.com actions are one page")
        equal(listed.first?.count, 17, "hosted: the page counts all 17 actions")
        equal(listed.first?.openActionID, "t-chrome-a16", "hosted: the page opens its latest action")
        equal(listed.first?.app, "Google Chrome", "hosted: the page names its browser")
        check((probe.rowFrames["t-chrome"]?.height ?? 0) > 120, "hosted: the expanded card is taller than the row",
              "\(String(describing: probe.rowFrames["t-chrome"]))")
        check(abs((probe.rowFrames["t-zed"]?.height ?? 0) - 52) < 1, "hosted: one row expanded at a time")
        b.expandedMomentID = "t-notes"
        check(wait { probe.sources["t-notes"] != nil }, "hosted: expanding another row loads its sources")
        pump(0.2)
        check(abs((probe.rowFrames["t-chrome"]?.height ?? 0) - 52) < 1, "hosted: expanding another row collapses the first")
        equal(probe.sources["t-notes"]?.first?.app, "Notes", "hosted: a window names its app")

        // The pushed detail. fix/show-all: it asks for the moment's sends and typed words (the app's owner-only loader),
        // off the main thread, and drops them when the day's memory changes (a Forget, typing turned off).
        var typedAsks = [[String]](), typingOn = true
        b.loadMomentTyped = { ids, _ in
            await MainActor.run { typedAsks.append(ids) }
            guard await MainActor.run(body: { typingOn }) else { return MomentTypedLoad() }
            return MomentTypedLoad(sends: ["t-chrome-a3": "Posted on github.com"],
                                   blocks: [MomentTypedBlock(id: "t-chrome-a3", at: "2026-09-22T21:05:00Z", app: "Google Chrome", bundle: "com.google.Chrome",
                                                             host: "github.com", title: "", text: "LGTM, ship it", send: "Posted on github.com")])
        }
        b.selectedCanonicalActivity = "t-chrome"
        check(wait { probe.detailMomentID == "t-chrome" && probe.detailActions.count == 17 }, "hosted: the detail opens with the moment's actions",
              "\(String(describing: probe.detailMomentID)) \(probe.detailActions.count)")
        check(wait { probe.detailTyped?.blocks.first?.text == "LGTM, ship it" }, "show all: the detail reads what was typed in the moment",
              "\(String(describing: probe.detailTyped))")
        equal(typedAsks.last?.count, 17, "show all: it asks about the moment's own actions only")
        typingOn = false
        b.dayCache.invalidate(todayKey)
        check(wait { probe.detailTyped != nil && probe.detailTyped?.blocks.isEmpty == true }, "show all: typing turned off (the day's memory changed): the words go at once",
              "\(String(describing: probe.detailTyped))")
        typingOn = true
        b.loadMomentTyped = nil
        equal(probe.detailActions.map(\.id), (0..<17).map { "t-chrome-a\($0)" }, "hosted: the detail lists oldest first")
        check(probe.detailComplete, "hosted: 17 actions fit the first page (no Load More Actions)")
        check(!probe.detailCanLoadMore && !probe.detailMissingNote && !probe.detailFailed, "hosted: a complete detail has no Load More and no notice")
        b.selectedCanonicalActivity = nil
        pump(0.3)
        b.selectedCanonicalActivity = "t-zed"
        // fix/show-all: the first read takes 400 (what a summary covers), so a moment's places are whole on open.
        check(wait { probe.detailMomentID == "t-zed" && probe.detailActions.count == 400 }, "hosted: a 442-action detail reads its first 400",
              "\(String(describing: probe.detailMomentID)) \(probe.detailActions.count)")
        check(probe.detailCanLoadMore && !probe.detailMissingNote, "hosted: 400 of 442 offers Load More Actions")
        b.selectedCanonicalActivity = nil
        pump(0.3)
        equal(b.focusedDay, nil, "hosted: expanding and the detail change no day")

        // A failed action from the expanded bar shows its notice in the card, in view.
        b.reopenCanonical = { _ in throw MemError.invalid("The original is gone") }
        b.selectedMomentID = "t-chrome"; b.expandedMomentID = "t-chrome"
        check(wait { probe.sources["t-chrome"] != nil && (probe.rowFrames["t-chrome"]?.height ?? 0) > 120 }, "hosted: the card expands again")
        b.send(.openOriginal)
        check(wait { probe.noticeFrame != nil }, "hosted: a failed Open Original shows a notice")
        pump(0.2)
        let card = probe.rowFrames["t-chrome"] ?? .zero, notice = probe.noticeFrame ?? .zero
        check(card.insetBy(dx: -0.5, dy: -0.5).contains(notice), "hosted: the expanded bar's failure shows in its card",
              "card \(card) notice \(notice)")
        b.expandedMomentID = nil
        check(wait { probe.noticeFrame == nil }, "hosted: collapsing the card clears its notice")
        b.reopenCanonical = { _ in }
        equal(calls.total, 0, "capture: expanding rows and the detail call no capture action")
        withExtendedLifetime(h) {}
        expandedIncomplete()
        detailFailure()
    }

    /// A day whose pages run out before a moment's end (a partial scan): 250 actions from 4:00 PM, of which
    /// the first page (`pageSize` actions) holds only the first few.
    static func expandedIncomplete() {
        let big = Spec(id: "t-big", from: (16, 0), to: (16, 20), app: "Numbers", bundle: "com.apple.iWork.Numbers", count: 250)
        todaySpecs = [mail, zed, chrome, notes, big]
        defer { todaySpecs = [mail, zed, chrome, notes] }
        let b = browser()
        let probe = FocusListProbe()
        let h = host(CanonicalTimeline(browser: b, state: CapturePresentation(state: .recording(since: nil)), actions: CaptureCalls().actions)
            .environment(\.daydreamFocusListProbe, probe))
        _ = wait { b.today.snapshot != nil }
        pump(0.2)
        b.selectedMomentID = "t-big"; b.expandedMomentID = "t-big"
        check(wait { probe.sources["t-big"] != nil }, "incomplete: the expanded body lists what it found")
        equal(probe.sourcesComplete["t-big"], false, "incomplete: the sources read did not find every member")
        let found = probe.sources["t-big"]?.first
        check(found.map { $0.count < 250 && !$0.detail(la, complete: false).contains("\u{2013}") } == true,
              "incomplete: the source claims no span it didn't read", found.map { "\($0.count) \($0.detail(la, complete: false))" } ?? "")
        b.selectedCanonicalActivity = "t-big"
        check(wait { probe.detailMomentID == "t-big" && !probe.detailActions.isEmpty }, "incomplete: the detail shows what it found")
        check(probe.detailActions.count < 50 && !probe.detailComplete, "incomplete: fewer than a page, not all", "\(probe.detailActions.count)")
        check(probe.detailMissingNote && !probe.detailCanLoadMore, "incomplete: says actions may be missing and offers no Load More Actions")
        b.selectedCanonicalActivity = nil
        pump(0.2)
        withExtendedLifetime(h) {}
    }

    /// The detail's read fails: it says so and offers Try Again, never a bare "0 of N".
    static func detailFailure() {
        var failing = false
        let b = browser()
        let good = b.loadCanonicalDay
        b.loadCanonicalDay = { key, cursor in
            if failing { throw MemError.database("Memory read failed") }
            return try await good!(key, cursor)
        }
        let probe = FocusListProbe()
        let h = host(CanonicalTimeline(browser: b, state: CapturePresentation(state: .recording(since: nil)), actions: CaptureCalls().actions)
            .environment(\.daydreamFocusListProbe, probe))
        _ = wait { b.today.snapshot != nil }
        pump(0.2)
        failing = true
        b.dayCache.invalidate(todayKey)
        b.selectedCanonicalActivity = "t-chrome"
        check(wait { probe.detailMomentID == "t-chrome" && probe.detailFailed }, "detail failure: a failed read is reported")
        check(probe.detailActions.isEmpty && !probe.detailCanLoadMore && !probe.detailMissingNote,
              "detail failure: nothing shown, no Load More Actions, no missing note")
        failing = false
        func isRetry(_ e: NSAccessibilityProtocol) -> Bool {
            let label: String = e.accessibilityLabel() ?? ""
            return label == "Try Again"
        }
        if let retry = elements(h).first(where: isRetry) {
            _ = retry.accessibilityPerformPress()
            check(wait { !probe.detailFailed && probe.detailActions.count == 17 }, "detail failure: Try Again reads the actions")
        } else {
            print("LIMIT: SwiftUI exposes no accessibility tree offscreen here; Try Again checked through the probe's failure state")
        }
        b.selectedCanonicalActivity = nil
        pump(0.2)
        withExtendedLifetime(h) {}
    }

    static func rowClicks() {
        todaySpecs = [mail, zed, chrome, notes]
        let calls = CaptureCalls()
        let b = browser()
        let h = host(CanonicalTimeline(browser: b, state: CapturePresentation(state: .recording(since: nil)), actions: calls.actions))
        _ = wait { b.today.snapshot != nil }
        pump(0.2)
        // Walk down the left of the column (titles, never a control) until a click expands a row.
        var hit: CGFloat?
        var y: CGFloat = 60
        while y < 680, hit == nil {
            click(h, at: NSPoint(x: 220, y: y))
            if b.expandedMomentID != nil { hit = y }
            y += 8
        }
        if let hit {
            let expanded = b.expandedMomentID
            check(expanded != nil && b.selectedMomentID == expanded, "click: a mouse down/up on a row selects and expands it")
            // The sweep found the row's top edge; the expanded card insets its header by 6 pt, so click inside it.
            click(h, at: NSPoint(x: 220, y: hit + 20))
            equal(b.expandedMomentID, nil, "click: a second click on the row collapses it")
        } else {
            check(false, "click: some row toggles under a mouse down/up")
        }
        equal(b.focusedDay, nil, "click: the sweep changed no day")
        equal(calls.total, 0, "capture: clicking rows calls no capture action")
        withExtendedLifetime(h) {}
    }

    static func failedToday() {
        let b = browser(failing: true)
        let h = host(CanonicalTimeline(browser: b, state: CapturePresentation(state: .recording(since: nil)), actions: CaptureActions()))
        check(wait { b.today.failed }, "failure: a failed read of today is reported, not hidden")
        let texts = elements(h).compactMap { $0.accessibilityLabel() }
        if texts.contains(where: { $0.contains("Today couldn't be loaded.") }) { print("PASS failure: the card reads Today couldn't be loaded.") }
        else { print("LIMIT: no offscreen accessibility tree; the failure card copy is checked through FocusListFailureCard.text") }
        withExtendedLifetime(h) {}
    }

    static func pausedRowPress() {
        var resumes = 0
        let h = host(FocusListPausedRow(until: date(16, 36), now: now, timeZone: la, canResume: true, resume: { resumes += 1 }),
                     size: NSSize(width: 600, height: 44))
        equal(resumes, 0, "paused row: drawing calls no resume")
        var worst = 0, total = 0
        var y: CGFloat = 4
        while y < 44 {
            var x: CGFloat = 4
            while x < 600 {
                let before = resumes
                click(h, at: NSPoint(x: x, y: y))
                worst = max(worst, resumes - before)
                x += 6
            }
            y += 6
        }
        total = resumes
        check(total > 0, "paused row: pressing Resume calls resume", "\(total)")
        equal(worst, 1, "paused row: one press calls resume exactly once")
        var disabled = 0
        let d = host(FocusListPausedRow(until: nil, now: now, timeZone: la, canResume: false, resume: { disabled += 1 }),
                     size: NSSize(width: 600, height: 44))
        var x: CGFloat = 4
        while x < 600 { click(d, at: NSPoint(x: x, y: 14)); click(d, at: NSPoint(x: x, y: 22)); x += 6 }
        equal(disabled, 0, "paused row: Resume is disabled when recording can't resume")
        withExtendedLifetime([h, d]) {}
    }

    static func footer() {
        // ux/declutter: the Focus List has no key-hint footer. Its keys stay in the menus (check_shortcuts).
        let timeline = source("Sources/MemoryUI/CanonicalTimeline.swift")
        check(!FileManager.default.fileExists(atPath: "Sources/MemoryUI/FocusListFooter.swift"), "footer: FocusListFooter is gone")
        check(!timeline.contains("FocusListFooter") && !timeline.contains("showsFooterHints"), "footer: the timeline draws no footer")
        // Empty Today while paused: the card first, the paused row under it (the reference's order).
        if let card = timeline.range(of: "FocusListEmptyCard(isToday:"), let row = timeline.range(of: "if isToday, let paused = pausedRow") {
            check(card.lowerBound < row.lowerBound, "empty Today: the paused row sits under the empty card")
        } else { check(false, "empty Today: the empty card and its paused row are found in the timeline") }
    }

    // MARK: Sources

    static func source(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    static func sources() {
        let shell = source("Sources/MemoryUI/MemoryShell.swift")
        check(shell.contains("CanonicalTimeline(browser:"), "MemoryShell still mounts CanonicalTimeline(browser:")
        let files = ["CanonicalTimeline", "FocusListHeader", "FocusListSummaryCard", "FocusListRows", "FocusListPausedRow",
                     "FocusListExpanded", "FocusListDetail"]
        for name in files {
            let text = source("Sources/MemoryUI/\(name).swift")
            check(!text.isEmpty, "\(name).swift is readable")
            let lines = text.split(separator: "\n").filter { $0.contains(".keyboardShortcut(") }
            check(!lines.contains { $0.contains("modifiers:") && !$0.contains("modifiers: []") && !$0.contains("modifiers:[]") },
                  "\(name).swift binds no key equivalent with modifiers", lines.joined(separator: " | "))
            check(!text.contains("Mac Mem"), "\(name).swift uses no retired brand name")
        }
        let timeline = source("Sources/MemoryUI/CanonicalTimeline.swift")
        check(timeline.contains("public struct CanonicalTimeline"), "CanonicalTimeline keeps its name")
        check(timeline.contains("public init(browser: ActivityBrowser)") && timeline.contains("public init(browser: ActivityBrowser, state: CapturePresentation, actions: CaptureActions)"),
              "CanonicalTimeline keeps both initializers")
        check(timeline.contains("\"canonical-history\"") && timeline.contains("\"canonical-app-detail\""), "CanonicalTimeline keeps its identifiers")
        check(!timeline.contains("loadCanonicalDay"), "CanonicalTimeline reads days only through the day cache")
        check(source("Sources/MemoryUI/FocusListRows.swift").contains("\"focus-list-row\""), "FocusListRows carries the plan §2.10 identifier focus-list-row")
    }
}
