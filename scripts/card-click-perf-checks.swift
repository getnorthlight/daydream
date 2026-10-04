// DD-RECIPE: UI
//
// perf-1005 (owner 10/4, laptop on 0.1.4): "clicking cards in DayDream is glitchy", "scrolling is laggy", "Clicking on
// cards in day… loading in what happened took so long", worst on days with lots of data. SYNTHETIC ONLY: a scratch history
// under $TMPDIR is seeded through the normal store: one big day (hundreds of moments, thousands of actions, ChatGPT runs of
// clicks in the same minute) and the day before it. No app, no permission, no recording, no Keychain, no model.
//
// The Today view (`CanonicalTimeline`, as MemoryShell mounts it) is hosted offscreen and driven one change at a time.
// "Main stall" is the longest single run-loop turn while a change settles (what the person feels as a hitch); "loaded"
// is the wall time until the card's What happened (its member actions) is read and drawn. Checks:
//  - a card click (select + expand): the click frame and the longest stall within CARD_CLICK_BUDGET_MS (default 200),
//    What happened loaded within CARD_LOAD_BUDGET_MS (default 1000) for every card, late ones included;
//  - the details page ("Show details"): loaded within CARD_LOAD_BUDGET_MS, longest stall within CARD_CLICK_BUDGET_MS;
//  - scrolling the big day with a card open: p95 frame within 2 × 16 ms;
//  - the list's row frames settle: a click hands them to the list at most 4 times (a big day's card opens at once, never
//    re-anchoring every animation frame), and they stop changing once the card is open (no layout feedback loop);
//  - member actions are read in one store read per card (never a page walk over the day).
// PERF lines print the numbers. PERF_HOME keeps a seeded history between runs. Release build (0.1.4 at fb2f3af, Mac mini):
// What happened 13-20 s per card (the page walk; 930 day reads for 12 clicks), details 13.7 s, click frame ~120 ms.
// perf-1005: What happened ~0.3 s, details ~0.3 s, 3 row-frame rounds per click (12-15 before), click frame ~115 ms.
// Not in the headless runner (it hosts an offscreen window); what-happened-fold-checks covers the one read headless.
import AppKit
import QuartzCore
import SwiftUI
import MemoryUI
import MemoryCore

final class PerfWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

@main @MainActor enum CardClickPerfChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ name: String, _ got: @autoclosure () -> String = "") {
        if ok { print("PASS " + name) } else {
            failures += 1
            fflush(stdout)
            FileHandle.standardError.write(Data(("FAIL: " + name + (got().isEmpty ? "" : " (got: " + got() + ")") + "\n").utf8))
        }
    }
    static func env(_ name: String, _ fallback: Double) -> Double { Double(ProcessInfo.processInfo.environment[name] ?? "") ?? fallback }
    static let clickBudget = env("CARD_CLICK_BUDGET_MS", 200)
    static let loadBudget = env("CARD_LOAD_BUDGET_MS", 1000)
    static let frameBudget = env("CARD_FRAME_BUDGET_MS", 32)

    static let zone = "America/Los_Angeles"
    static let la = TimeZone(identifier: zone)!
    static var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = la; return c }
    static func date(_ day: Int, _ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 9, day: day, hour: h, minute: m, second: s))!
    }
    /// Tuesday 2026-09-22, 11:50 PM: the big day runs 7:00 AM to 11:30 PM.
    static let now = date(22, 23, 50)
    static let todayDay = 22

    // MARK: Seeding

    struct App { let name: String; let bundle: String; let site: String; let titles: [String] }
    static let apps: [App] = [
        App(name: "Mail", bundle: "com.apple.mail", site: "", titles: ["Inbox – iCloud", "Re: Pilot with Northwind", "Invoice #3107 from Hostwell"]),
        App(name: "Chrome", bundle: "com.google.Chrome", site: "https://docs.google.com", titles: ["Q3 investor update - Google Docs", "Launch checklist - Google Docs"]),
        App(name: "Chrome", bundle: "com.google.Chrome", site: "https://chatgpt.com", titles: ["ChatGPT", "Archive step fails - ChatGPT"]),
        App(name: "Chrome", bundle: "com.google.Chrome", site: "https://github.com", titles: ["Pull request #412: capture pipeline", "Issues · tallybird/app"]),
        App(name: "Xcode", bundle: "com.apple.dt.Xcode", site: "", titles: ["CaptureCoordinator.swift", "FocusListRows.swift"]),
        App(name: "Slack", bundle: "com.tinyspeck.slackmacgap", site: "", titles: ["#launch - Tallybird", "Maya (DM) - Tallybird"]),
        App(name: "Notes", bundle: "com.apple.Notes", site: "", titles: ["Weekly sync notes", "Launch day plan"]),
        App(name: "Terminal", bundle: "com.apple.Terminal", site: "", titles: ["zsh — tallybird", "swift build — tallybird"]),
        App(name: "Figma", bundle: "com.figma.Desktop", site: "", titles: ["Onboarding flow", "Day card v3"]),
    ]
    static let words = ["alpha", "harbor", "maple", "orbit", "cedar", "delta", "ember", "falcon", "garnet", "hazel", "indigo", "juniper",
                        "kestrel", "lagoon", "meadow", "nectar", "oasis", "pepper", "quartz", "raven", "sierra", "tundra", "umber", "velvet"]
    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: d)
    }

    /// The big day and the day before. Each window is used 1-3 minutes, a click every 3-6 s; ChatGPT stretches are 15
    /// clicks in one minute (the owner's "15 ChatGPT · Clicked rows").
    static func seed(home: URL) throws -> (days: [String], ingested: Int) {
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        var rng = SystemRandomNumberGenerator.Seeded(seed: 20261005)
        var ingested = 0, counter = 0
        var days = [String]()
        let t0 = CACurrentMediaTime()
        for day in (todayDay - 1)...todayDay {
            let full = day == todayDay
            var t = full ? date(day, 7, 0) : date(day, 9, 0)
            let end = full ? date(day, 23, 30) : date(day, 13, 0)
            var last = -1, stretch = 0
            var evidence = [(Date, Evidence)]()
            while t < end {
                var pick = Int(rng.next() % UInt64(apps.count))
                if pick == last { pick = (pick + 1) % apps.count }
                last = pick
                let app = apps[pick]
                stretch += 1
                let title = app.titles[Int(rng.next() % UInt64(app.titles.count))] + " – " + words[stretch % words.count] + " " + words[(stretch / words.count + 5) % words.count]
                let chat = app.site == "https://chatgpt.com"
                let minutes = full ? 1 + Int(rng.next() % 3) : 6 + Int(rng.next() % 6)
                let stop = min(end, t.addingTimeInterval(Double(minutes * 60)))
                var at = t, first = true
                while at < stop {
                    counter += 1
                    let kind = first ? "window.changed" : (counter % 9 == 0 ? "window.observed" : "mouse.click")
                    first = false
                    evidence.append((at, Evidence(id: String(format: "click-%06d", counter), at: iso(at), kind: kind, app: app.name, bundle: app.bundle,
                                                  title: chat ? "ChatGPT" : title, url: app.site, synthetic: true)))
                    at = at.addingTimeInterval(chat ? 4 : (full ? 3 + Double(rng.next() % 4) : 40 + Double(rng.next() % 20)))
                }
                t = stop.addingTimeInterval(rng.next() % 14 == 0 ? 25 * 60 : 15)
            }
            for (at, e) in evidence where (try? store.ingest(e, now: at.addingTimeInterval(1))) == true { ingested += 1 }
            days.append(try DayScope.key(date(day, 12, 0), timezone: zone))
        }
        let tNotes = CACurrentMediaTime()
        for key in days {
            for (i, m) in try store.dayLayers(day: key, timezone: zone, limit: 1, now: now).activities.enumerated() where m.status != "ready" && i % 7 != 3 {
                guard let request = try? store.prepareNote(kind: "activity", day: key, timezone: zone, activityID: m.id, now: now) else { continue }
                let app = m.apps.first { !$0.isEmpty } ?? "an app"
                let ids = request.actions.map(\.id), half = max(1, ids.count / 2)
                let bullets = [NoteBullet(text: "Had \(m.subject.isEmpty ? app : m.subject) open in \(app).", actionIDs: Array(ids.prefix(half)), assertion: "observed"),
                               NoteBullet(text: "Kept working in \(app).", actionIDs: Array(ids.suffix(from: half)), assertion: "observed")]
                _ = try? store.commitNote(NoteWriterOutput(requestID: request.id, title: m.subject.isEmpty ? app : m.subject, bullets: bullets,
                                                          generator: "code/perf-fixture", generatorVersion: "1"), now: now)
            }
        }
        let tLevels = CACurrentMediaTime()
        var guardCount = 0
        while guardCount < 200, let request = try store.levelWork(timezone: zone, now: now, backfillDays: 3, limit: 1).first {
            guardCount += 1
            let (title, lines) = LevelGrounding.extractive(request)
            _ = try store.commitLevel(request, title: title, lines: lines, generator: LevelWriterVersion.extractive, now: now)
        }
        print(String(format: "PERF seed phases: rows %.1fs, notes %.1fs, levels %.1fs (%d)", tNotes - t0, tLevels - tNotes, CACurrentMediaTime() - tLevels, guardCount))
        return (days, ingested)
    }

    // MARK: Hosting

    static let window: PerfWindow = {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let w = PerfWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1000, height: 820), styleMask: [.borderless], backing: .buffered, defer: false)
        w.acceptsMouseMovedEvents = true
        w.orderFrontRegardless()
        return w
    }()
    static func pump(_ s: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    static func scrollView(in view: NSView) -> NSScrollView? {
        if let s = view as? NSScrollView, s.documentView != nil, (s.documentView?.frame.height ?? 0) > 2000 { return s }
        for v in view.subviews { if let s = scrollView(in: v) { return s } }
        return nil
    }
    static func settle(_ host: NSView) {
        RunLoop.main.run(mode: .default, before: Date())
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    /// Turns the run loop until `done` (or `timeout`), one source at a time, drawing between turns. Returns the wall time
    /// and the longest single turn (a turn is one handler, one layout or one draw: what the main thread could not interrupt).
    static func until(_ host: NSView, timeout: Double, _ done: () -> Bool) -> (ok: Bool, wall: Double, stall: Double) {
        let start = CACurrentMediaTime(), end = start + timeout
        var stall = 0.0
        while !done() && CACurrentMediaTime() < end {
            let t = CACurrentMediaTime()
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            stall = max(stall, (CACurrentMediaTime() - t) * 1000)
        }
        return (done(), (CACurrentMediaTime() - start) * 1000, stall)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        func add() { lock.lock(); n += 1; lock.unlock() }
    }

    struct Stats {
        var ms: [Double] = []
        mutating func add(_ v: Double) { ms.append(v) }
        func pct(_ p: Double) -> Double { let s = ms.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count - 1) * p))] }
        var max: Double { ms.max() ?? 0 }
        var mean: Double { ms.isEmpty ? 0 : ms.reduce(0, +) / Double(ms.count) }
        func line(_ name: String) -> String {
            String(format: "PERF %@: n=%d mean=%.1fms p50=%.1fms p95=%.1fms max=%.1fms", name, ms.count, mean, pct(0.5), pct(0.95), max)
        }
    }

    // MARK: Main

    static func main() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("card-click-perf-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: tmp)
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let kept = ProcessInfo.processInfo.environment["PERF_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let home = kept ?? tmp.appendingPathComponent("memory", isDirectory: true)
        let seedStart = CACurrentMediaTime()
        let seeded: (days: [String], ingested: Int)
        if let kept, FileManager.default.fileExists(atPath: kept.appendingPathComponent("memory.sqlite").path) {
            seeded = (((todayDay - 1)...todayDay).map { String(format: "2026-09-%02d", $0) }, 0)
        } else {
            if let kept { try? FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true) }
            do { seeded = try seed(home: home) } catch { check(false, "seed the synthetic days", "\(error)"); exit(1) }
        }
        let reader = try! MemoryStore(home: home)
        let todayKey = seeded.days.last!
        let today = try! reader.dayLayers(day: todayKey, timezone: zone, limit: 200, now: now)
        print(String(format: "PERF seed: %d rows, %.1fs", seeded.ingested, CACurrentMediaTime() - seedStart))
        print("PERF big day: actions=\(today.summary.actionCount) moments=\(today.activities.count)")
        check(today.summary.actionCount >= 3000, "fixture: the big day has thousands of actions (≥ 3,000)", "\(today.summary.actionCount)")
        check(today.activities.count >= 200, "fixture: the big day has hundreds of moments (≥ 200)", "\(today.activities.count)")

        let dayReads = Counter(), memberReads = Counter()
        let browser = ActivityBrowser(calendar: cal)
        browser.now = { now }
        browser.summaries = SummaryAvailability(provider: .local, busy: false)
        browser.loadCanonicalDay = { key, cursor in
            dayReads.add()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        let r = try MemoryStore(home: home)
                        var read = try r.dayLayers(day: key, timezone: zone, after: cursor, limit: 200, now: now)
                        read.levels = try? r.dayLevels(day: key, timezone: zone)
                        return read
                    })
                }
            }
        }
        // perf-1005: a card's member actions in one read (the app wires the same store call). BEGIN member-read
        if ProcessInfo.processInfo.environment["PERF_NO_MEMBER_READ"] == nil {
            browser.loadMemberActions = { key, ids in
                memberReads.add()
                return try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(with: Result { try MemoryStore(home: home).memberActions(day: key, timezone: zone, ids: ids, now: now) })
                    }
                }
            }
        } // END member-read
        browser.reopenCanonical = { _ in }
        browser.openApp = { _ in }
        browser.generateCanonicalNote = { _, _, _, _ in }

        let size = NSSize(width: 1000, height: 820)
        let probe = FocusListProbe()
        let host = NSHostingView(rootView: AnyView(CanonicalTimeline(browser: browser)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .environment(\.daydreamFocusListProbe, probe)))
        window.setContentSize(size)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        let open = until(host, timeout: 30) { probe.rowFrames.count >= 150 }
        check(open.ok, "hosted: the big day's rows lay out", "\(probe.rowFrames.count) rows")
        print(String(format: "PERF day open: rows=%d wall=%.0fms longest stall=%.0fms", probe.rowFrames.count, open.wall, open.stall))
        pump(0.5)
        guard let scroll = scrollView(in: host) else { check(false, "hosted: the list's scroll view"); exit(1) }

        // Cards across the day, the late ones last (their actions are deep in the day).
        let moments = browser.today.snapshot?.moments ?? []
        let picks = stride(from: 0, to: moments.count, by: max(1, moments.count / 12)).map { moments[$0] }.filter { $0.actionIDs.count >= 3 }
        // PERF_SPIN=<seconds> (investigation only): keep clicking cards open and shut so a sampler can watch.
        if let spin = ProcessInfo.processInfo.environment["PERF_SPIN"].flatMap(Double.init) {
            print("PERF spinning pid=\(ProcessInfo.processInfo.processIdentifier)"); fflush(stdout)
            let end = CACurrentMediaTime() + spin
            var i = 0
            while CACurrentMediaTime() < end {
                let m = picks[i % picks.count]; i += 1
                browser.selectedMomentID = m.id; browser.expandedMomentID = m.id
                _ = until(host, timeout: 0.5) { false }
            }
        }
        var clickFrame = Stats(), clickStall = Stats(), loaded = Stats(), frameUpdates = Stats()
        var slowest = (id: "", ms: 0.0)
        for m in picks {
            // As a click does: select, then expand under the list's animation.
            let before = memberReads.count, updatesBefore = probe.rowFrameUpdates
            let t0 = CACurrentMediaTime()
            // As the list does: a big day's card opens at once (`CanonicalTimeline.animatedOpenLimit`), else over 0.16 s.
            withAnimation(moments.count > CanonicalTimeline.animatedOpenLimit ? nil : .easeInOut(duration: 0.16)) {
                browser.selectedMomentID = m.id
                browser.expandedMomentID = m.id
            }
            settle(host)
            clickFrame.add((CACurrentMediaTime() - t0) * 1000)
            // The card's What happened is read for its anchor (the card's newest member), which may be another moment of it.
            let known = Set(probe.sources.keys)
            let r = until(host, timeout: 20) {
                probe.sources[m.id] != nil || !Set(probe.sources.keys).subtracting(known).isEmpty
                    // A moment of the card already open (its anchor was read by an earlier click): nothing to read.
                    || (memberReads.count == before && CACurrentMediaTime() - t0 > 1 && ProcessInfo.processInfo.environment["PERF_NO_MEMBER_READ"] == nil)
            }
            if memberReads.count == before && ProcessInfo.processInfo.environment["PERF_NO_MEMBER_READ"] == nil { continue }
            let total = (CACurrentMediaTime() - t0) * 1000
            check(r.ok, "click: \(m.id)'s What happened loads")
            loaded.add(total)
            clickStall.add(r.stall)
            if total > slowest.ms { slowest = (m.id, total) }
            // Let the open animation and the reveal finish, then count how often the row frames changed for this click.
            _ = until(host, timeout: 0.4) { false }
            frameUpdates.add(Double(probe.rowFrameUpdates - updatesBefore))
            if ProcessInfo.processInfo.environment["PERF_NO_MEMBER_READ"] == nil {
                check(memberReads.count - before <= 1, "click: one member read for \(m.id) (the open card is never read again)", "\(memberReads.count - before)")
            }
            // Quiet: the frames preference stops changing once the card is open (no feedback loop).
            let quiet = probe.rowFrameUpdates
            _ = until(host, timeout: 0.3) { false }
            check(probe.rowFrameUpdates == quiet, "click: the row frames settle after \(m.id) opens", "\(probe.rowFrameUpdates - quiet) more updates")
        }
        print(clickFrame.line("card click frame (select + expand)"))
        print(clickStall.line("card click longest main stall until What happened shows"))
        print(loaded.line("card click to What happened loaded"))
        print(frameUpdates.line("row-frame preference updates per click").replacingOccurrences(of: "ms", with: ""))
        print("PERF slowest card: \(slowest.id) \(Int(slowest.ms))ms, day reads so far \(dayReads.count), member reads \(memberReads.count)")

        // Scrolling the big day with the last card open.
        var scrollFrames = Stats()
        let extent = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
        for y in stride(from: CGFloat(0), through: extent, by: 37) {
            let t0 = CACurrentMediaTime()
            let clip = scroll.contentView
            clip.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(clip)
            settle(host)
            scrollFrames.add((CACurrentMediaTime() - t0) * 1000)
        }
        print(scrollFrames.line("scroll frame with a card open"))
        print(String(format: "PERF list: document=%.0fpt", scroll.documentView?.frame.height ?? 0))

        // The details page of the late cards (Show details), and back.
        var detailLoaded = Stats(), detailStall = Stats()
        for m in picks.suffix(4) {
            let members = Set(m.actionIDs)
            let t0 = CACurrentMediaTime()
            browser.selectedCanonicalActivity = m.id
            let r = until(host, timeout: 20) { probe.detailMomentID == m.id && probe.detailActions.contains { members.contains($0.id) } }
            check(r.ok, "details: \(m.id)'s actions load")
            detailLoaded.add((CACurrentMediaTime() - t0) * 1000)
            detailStall.add(r.stall)
            _ = until(host, timeout: 0.3) { false }
            browser.selectedCanonicalActivity = nil
            _ = until(host, timeout: 0.3) { false }
        }
        print(detailLoaded.line("details page to actions loaded"))
        print(detailStall.line("details page longest main stall"))

        check(frameUpdates.max <= 4, "click: a card open hands the row frames to the list at most 4 times (no per-frame re-anchoring)", frameUpdates.line("updates"))
        check(clickFrame.pct(0.95) <= clickBudget, String(format: "click: 95%% of click frames ≤ %.0f ms", clickBudget), clickFrame.line("click"))
        check(clickStall.pct(0.95) <= clickBudget, String(format: "click: 95%% of longest stalls ≤ %.0f ms", clickBudget), clickStall.line("stall"))
        check(loaded.max <= loadBudget, String(format: "click: every card's What happened within %.0f ms", loadBudget), loaded.line("loaded"))
        check(detailLoaded.max <= loadBudget, String(format: "details: every details page within %.0f ms", loadBudget), detailLoaded.line("details"))
        check(detailStall.max <= clickBudget, String(format: "details: longest stall ≤ %.0f ms", clickBudget), detailStall.line("details stall"))
        check(scrollFrames.pct(0.95) <= frameBudget, String(format: "scroll: 95%% of frames with a card open ≤ %.0f ms", frameBudget), scrollFrames.line("scroll"))

        if failures > 0 {
            FileHandle.standardError.write(Data("FAIL: \(failures) card click perf check(s) failed\n".utf8))
            exit(1)
        }
        print("PASS: all card click perf checks")
    }
}

extension SystemRandomNumberGenerator {
    /// A seeded generator (splitmix64), so the synthetic days are the same on every run.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
}
