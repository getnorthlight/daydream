// fix/layout-crash: the main window never loops its layout (owner, test build 7, twice on 9/28-29; 0.1.0 on 9/27 too).
// DayDream quit on an NSException from -[NSWindow(NSDisplayCycle) _postWindowNeedsUpdateConstraints]: "marked as
// needing another Update Constraints in Window pass, but it has already had more ... passes than there are views".
// Both backtraces are the window toolbar's SwiftUI item hosts (NSToolbarItemViewer > NSHostingView) re-dirtying the
// window inside its own display cycle: 9/29 `_willUpdateConstraintsForSubtree > cancelAsyncRendering > setNeedsUpdate`,
// 9/27 `layout > render > FocusBridge.updateDefaultKeyViewLoop > removeFromSuperview`. The one thing in those items
// that never settles was the recording capsule's live dot, whose halo breathed forever (`repeatForever`): an
// animation the host renders off the main thread (build 7) or, when it started in `withAnimation` (0.1.0), one that
// also animated the capsule's layout. Every constraints pass cancelled or re-sampled it and asked for one more.
//  - Sources: nothing in the app's UI animates forever (repeatForever, repeatCount, phase/keyframe animators,
//    symbol effects) and the live dot has no animation, state or timer (the crash's precondition).
//  - Live window: MemoryShell(chrome: .windowToolbar) in a real unified toolbar, live (no daydreamStatic, no pinned
//    clock), recording: rounds of expanding cards, the "Couldn't open the original" banner, resizes across the
//    toolbar's compact widths, recording state changes, collapses and day rereads, each while the last still lays
//    out. Any NSException fails the check (NSApplicationCrashOnExceptions is off only here).
// LIMIT: with the screen locked the window is occluded and SwiftUI's display link doesn't tick, so the animation half
// of the path can't run here; the check says so, and the source half still holds.
// Synthetic data only; no app launch, permission, store, network or Keychain. Run from the tree root.
import AppKit
import SwiftUI
import MemoryUI
import MemoryCore

final class LoopApp: NSApplication {
    static var reported: [String] = []
    override func reportException(_ exception: NSException) {
        LoopApp.reported.append("\(exception.name.rawValue): \(exception.reason ?? "")")
    }
}

@main @MainActor enum LayoutLoopChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ name: String, _ got: @autoclosure () -> String = "") {
        if ok { print("PASS " + name) } else {
            failures += 1; fflush(stdout)
            FileHandle.standardError.write(Data(("FAIL: " + name + (got().isEmpty ? "" : " (got: " + got() + ")") + "\n").utf8))
        }
    }
    static let la = TimeZone(identifier: "America/Los_Angeles")!
    static var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = la; return c }
    static func date(_ h: Int, _ m: Int, day: Int = 22) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 9, day: day, hour: h, minute: m))!
    }
    static let now = date(16, 21)
    static let todayKey = "2026-09-22"
    static func iso(_ d: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: d) }

    // MARK: Day fixture (dd-focus-list-checks' inline day reads)

    struct Spec {
        var id: String
        var from: (Int, Int), to: (Int, Int)
        var app: String, bundle: String, site: String = ""
        var count: Int
        var title: String? = nil
        var bullets: [String] = []
        var generator = "local/qwen3.5-4b-q4_k_m"
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
            n["generated"] = generated(id: "g-" + s.id, title: title, bullets: s.bullets, ids: ids, at: end.addingTimeInterval(120), generator: s.generator)
        }
        return (n, actions)
    }

    static func generated(id: String, title: String, bullets: [String], ids: [String], at: Date, generator: String) -> [String: Any] {
        ["id": id, "version": 1, "schemaVersion": 1, "generatedAt": iso(at), "inputRevision": "r1", "actionIDs": ids, "status": "generated_unverified",
         "output": ["requestID": "req-" + id, "title": title, "bullets": bullets.map { ["text": $0, "actionIDs": [ids[0]], "assertion": "observed"] },
                    "generator": generator, "generatorVersion": "1"]]
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

    static func browser() -> ActivityBrowser {
        let b = ActivityBrowser(calendar: cal)
        b.now = { now }
        b.summaries = SummaryAvailability(provider: .local, busy: false)
        b.loadCanonicalDay = { key, _ in key == todayKey ? day(key, todaySpecs) : day(key, []) }
        b.searchCanonical = { _, _ in throw CancellationError() }
        b.reopenCanonical = { _ in throw MemError.invalid("The original is gone") }
        b.openApp = { _ in }
        return b
    }

    static func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    @discardableResult static func wait(_ timeout: Double = 3, _ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { pump(0.02) }
        return done()
    }

    static func state(_ i: Int) -> CapturePresentation {
        let since = date(8, 40)
        let inputs: RecordingStateInputs
        switch i % 3 {
        case 0: inputs = RecordingStateInputs(recording: true, stopped: false, recordingSince: since, accessibilityGranted: true, inputMonitoringGranted: true)
        case 1: inputs = RecordingStateInputs(stopped: false, pausedAt: now, accessibilityGranted: true, inputMonitoringGranted: true)
        default: inputs = RecordingStateInputs(stoppedAt: now, accessibilityGranted: true, inputMonitoringGranted: true)
        }
        return CapturePresentation(inputs: inputs, permissions: PermissionSnapshot(accessibility: true, inputMonitoring: true))
    }

    /// The production composition: MemoryShell(chrome: .windowToolbar) bridged into a real unified toolbar, live
    /// (no `daydreamStatic`, no pinned clock), so the recording capsule draws exactly as in the app.
    static func window(_ b: ActivityBrowser, _ p: CapturePresentation, width: CGFloat) -> (NSWindow, NSHostingController<AnyView>) {
        let controller = NSHostingController(rootView: AnyView(MemoryShell(browser: b, state: p, actions: CaptureActions(), chrome: .windowToolbar)))
        controller.sceneBridgingOptions = [.toolbars, .title]
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -3000, width: width, height: 720),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.toolbarStyle = .unified
        w.titleVisibility = .hidden
        w.contentViewController = controller
        w.setContentSize(NSSize(width: width, height: 720))
        w.setFrameOrigin(NSPoint(x: -4000, y: -3000))
        w.orderFrontRegardless()
        return (w, controller)
    }

    // MARK: Sources

    /// Nothing in the app's UI animates forever, and the live dot (in the toolbar capsule, the popover and the menu bar
    /// panel) has no animation, state or timer.
    static func sources() {
        let banned = ["repeatForever", "repeatCount(", "phaseAnimator", "keyframeAnimator", "symbolEffect"]
        var hits: [String] = [], read = 0
        for dir in ["Sources/MemoryUI/", "Sources/MacMemApp/"] {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where file.hasSuffix(".swift") {
                guard let text = try? String(contentsOfFile: dir + file, encoding: .utf8) else { continue }
                read += 1
                for (n, line) in text.components(separatedBy: "\n").enumerated()
                    where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") && banned.contains(where: { line.contains($0) }) {
                    hits.append("\(file):\(n + 1)")
                }
            }
        }
        check(read > 50, "sources: the UI sources are readable from the tree root", "\(read)")
        check(hits.isEmpty, "sources: nothing in the app's UI animates forever (the layout-loop crash's precondition)", "\(hits)")
        let kit = (try? String(contentsOfFile: "Sources/MemoryUI/DaydreamKitStatus.swift", encoding: .utf8)) ?? ""
        if let start = kit.range(of: "struct LiveDot: View {"), let end = kit.range(of: "\n}\n", range: start.upperBound..<kit.endIndex) {
            let body = kit[start.lowerBound..<end.lowerBound].components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined()
            let found = ["@State", ".animation(", "withAnimation", "onAppear", "Timer", "TimelineView", "DispatchQueue"].filter { body.contains($0) }
            check(found.isEmpty, "sources: the live dot has no animation, state or timer", "\(found)")
        } else {
            check(false, "sources: LiveDot is found")
        }
    }

    static func main() {
        sources()
        UserDefaults.standard.set(false, forKey: "NSApplicationCrashOnExceptions")
        NSSetUncaughtExceptionHandler { e in
            FileHandle.standardError.write(Data("FAIL: the live window raised \(e.name.rawValue): \(e.reason ?? "")\n".utf8))
        }
        _ = LoopApp.shared
        NSApp.setActivationPolicy(.accessory)
        let rounds = Int(ProcessInfo.processInfo.environment["LAYOUT_LOOP_ROUNDS"] ?? "") ?? 40
        let b = browser()
        let (w, controller) = window(b, state(0), width: 1100)
        check(wait { b.today.snapshot != nil }, "the day loads")
        pump(0.5)
        if !w.occlusionState.contains(.visible) {
            print("LIMIT: the window is occluded (screen locked): SwiftUI's display link doesn't tick, so no animation runs here")
        }
        let ids = todaySpecs.map(\.id)
        let widths: [CGFloat] = [1100, 700, 560, 900, 1400, 640]
        let start = Date()
        for r in 0..<rounds {
            let id = ids[r % ids.count]
            // Expand a card (animated, as a click does), fail Open Original (the "Couldn't open the original" banner),
            // resize, change the recording state, collapse: each while the previous change still lays out.
            b.selectedMomentID = id; b.expandedMomentID = id
            pump(0.03)
            b.send(.openOriginal)
            pump(0.02)
            w.setContentSize(NSSize(width: widths[r % widths.count], height: 720 - CGFloat(r % 4) * 40))
            pump(0.02)
            if r % 5 == 4 { controller.rootView = AnyView(MemoryShell(browser: b, state: state(r / 5), actions: CaptureActions(), chrome: .windowToolbar)) }
            pump(0.03)
            b.expandedMomentID = r % 2 == 0 ? nil : ids[(r + 1) % ids.count]
            pump(0.05)
            if r % 7 == 6 { b.today.refresh(force: true) }
            pump(0.05)
            if !LoopApp.reported.isEmpty { break }
        }
        pump(0.5)
        check(LoopApp.reported.isEmpty, "\(rounds) rounds of expand, banner, resize, state change and collapse in the live window toolbar raise no exception",
              LoopApp.reported.first.map { String($0.prefix(300)) } ?? "")
        print(String(format: "rounds %d in %.1f s, exceptions %d", rounds, Date().timeIntervalSince(start), LoopApp.reported.count))
        w.orderOut(nil)
        if failures > 0 { print("FAIL layout-loop-checks: \(failures)"); exit(1) }
        print("PASS layout-loop-checks: no layout exception")
    }
}
