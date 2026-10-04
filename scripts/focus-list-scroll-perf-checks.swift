// DD-RECIPE: UI
//
// Focus List scroll performance on a full synthetic day (fix/scroll-perf). The owner: "the scrolling got really slow and
// laggy ... when it got even slightly full". SYNTHETIC ONLY: a scratch history under $TMPDIR is seeded through the normal
// store (window rows, code notes, the level code's extractive writer: blocks, threads, day and week notes), about 2,400
// actions and 130 moments today plus six earlier days. No app, no permission, no recording, no Keychain, no model.
//
// The Today view (`CanonicalTimeline`, as MemoryShell mounts it) is hosted offscreen and driven one change at a time;
// each change's main-thread work (SwiftUI body, layout, display) is timed. The pointer is moved with
// `FocusListProbe.point` (an offscreen window gets no tracking-area hovers). Checks, against `FOCUS_SCROLL_BUDGET_MS`
// (default 16 ms, one 60 Hz frame):
//  - scrolling top to bottom and back: every frame within the budget, and no store read while scrolling;
//  - the same with the pointer resting mid-list (each frame another row passes under it): every frame within it;
//  - the pointer moving row to row (the ribbon lights each span) and along the ribbon (each span lights its row):
//    95% of the changes within it;
//  - the selection moving one row: 95% within two frames; a click-to-reference highlight on or off (every row tints
//    or dims, under a 250 ms fade): 95% within four.
// Printed only (PERF lines): today's reread and the writer's busy flag flipping.
// Before fix/scroll-perf (debug build): a scroll frame took ~150 ms, a selection ~570 ms, a highlight ~230 ms.
import AppKit
import QuartzCore
import SwiftUI
import MemoryUI
import MemoryCore

final class PerfWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

@main @MainActor enum FocusListScrollPerfChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ name: String, _ got: @autoclosure () -> String = "") {
        if ok { print("PASS " + name) } else {
            failures += 1
            fflush(stdout)
            FileHandle.standardError.write(Data(("FAIL: " + name + (got().isEmpty ? "" : " (got: " + got() + ")") + "\n").utf8))
        }
    }

    static let zone = "America/Los_Angeles"
    static let la = TimeZone(identifier: zone)!
    static var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = la; return c }
    static func date(_ day: Int, _ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 9, day: day, hour: h, minute: m, second: s))!
    }
    /// Tuesday 2026-09-22, 7:20 PM: today's rows run 7:40 AM to 6:30 PM, so every block is closed and the day note written.
    static let now = date(22, 19, 20)
    static let todayDay = 22
    static let budget = Double(ProcessInfo.processInfo.environment["FOCUS_SCROLL_BUDGET_MS"] ?? "") ?? 16

    // MARK: Seeding

    struct App { let name: String; let bundle: String; let site: String; let titles: [String] }
    static let apps: [App] = [
        App(name: "Mail", bundle: "com.apple.mail", site: "", titles: ["Inbox – iCloud", "Re: Pilot with Northwind", "Invoice #3107 from Hostwell", "Re: Q3 numbers for the board"]),
        App(name: "Chrome", bundle: "com.google.Chrome", site: "https://docs.google.com", titles: ["Q3 investor update - Google Docs", "Launch checklist - Google Docs", "Hiring plan - Google Docs"]),
        App(name: "Chrome", bundle: "com.google.Chrome", site: "https://github.com", titles: ["Pull request #412: capture pipeline", "Issues · tallybird/app", "Actions · tallybird/app"]),
        App(name: "Chrome", bundle: "com.google.Chrome", site: "https://www.youtube.com", titles: ["Swift concurrency talk - YouTube", "Lo-fi beats - YouTube"]),
        App(name: "Xcode", bundle: "com.apple.dt.Xcode", site: "", titles: ["CaptureCoordinator.swift", "WeeklySummaryExport.swift", "FocusListRows.swift"]),
        App(name: "Slack", bundle: "com.tinyspeck.slackmacgap", site: "", titles: ["#launch - Tallybird", "Maya (DM) - Tallybird", "#eng - Tallybird"]),
        App(name: "Messages", bundle: "com.apple.MobileSMS", site: "", titles: ["Sam", "Maya", "Family"]),
        App(name: "Notes", bundle: "com.apple.Notes", site: "", titles: ["Weekly sync notes", "Ideas", "Launch day plan"]),
        App(name: "Terminal", bundle: "com.apple.Terminal", site: "", titles: ["zsh — tallybird", "swift build — tallybird"]),
        App(name: "Figma", bundle: "com.figma.Desktop", site: "", titles: ["Onboarding flow", "Day card v3"]),
        App(name: "Calendar", bundle: "com.apple.iCal", site: "", titles: ["Week of Sep 21", "Weekly sync"]),
        App(name: "Zed", bundle: "dev.zed.Zed", site: "", titles: ["ribbon.swift — tallybird", "store.swift — tallybird"]),
    ]

    static let words = ["alpha", "harbor", "maple", "orbit", "cedar", "delta", "ember", "falcon", "garnet", "hazel", "indigo", "juniper",
                        "kestrel", "lagoon", "meadow", "nectar", "oasis", "pepper", "quartz", "raven", "sierra", "tundra", "umber", "velvet"]

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: d)
    }

    /// fix/prompt-row: what the harness types to "AI" in today's Notes stretches (a long ask over several lines, so each
    /// such row draws a cut `PromptLine`).
    static let ask = "can you look at this crash log and tell me why the archive step fails\n\non the release configuration only?   debug works fine every time and the logs say nothing useful"
    /// The seeding store holds the typing key (in memory): the prompt loader opens asks through it, as the app's store does.
    static var typedStore: MemoryStore?

    /// Seeds `home` with seven days: `todayDay` (full: ~2,000 actions in 100+ moments) and the six before it (lighter).
    /// fix/prompt-row: typing on with an in-memory key, and today's Notes stretches end with a sent AI ask.
    static func seed(home: URL) throws -> (days: [String], ingested: Int) {
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        var policy = try store.policy(); policy.captureText = true; policy.typedConsentVersion = 1; try store.updatePolicy(policy, now: date(todayDay - 6, 8, 0))
        try store.attachVault(TypedTextVault(keyStore: InMemoryTypedKeyStore())); try store.acceptSafeTyping(); try store.setUpTypedVault()
        typedStore = store
        let tStart = CACurrentMediaTime()
        var rng = SystemRandomNumberGenerator.Seeded(seed: 20260922)
        var ingested = 0, counter = 0
        var days = [String]()
        for day in (todayDay - 6)...todayDay {
            let full = day == todayDay
            var t = full ? date(day, 7, 40) : date(day, 9, 0)
            let end = full ? date(day, 18, 30) : date(day, 12, 30)
            var last = -1, stretch = 0
            var evidence = [(Date, Evidence)]()
            while t < end {
                // A window used for 2-6 minutes: opened, a click every ~12 s, a sample every 2 minutes.
                var pick = Int(rng.next() % UInt64(apps.count))
                if pick == last { pick = (pick + 1) % apps.count }
                last = pick
                let app = apps[pick]
                // Each window its own document, page or chat (a title seen again within 20 minutes joins its moment).
                stretch += 1
                let title = app.titles[Int(rng.next() % UInt64(app.titles.count))] + " – " + words[stretch % words.count] + " " + words[(stretch / words.count + 7) % words.count]
                let minutes = full ? 1 + Int(rng.next() % 4) : 8 + Int(rng.next() % 8)
                let stop = min(end, t.addingTimeInterval(Double(minutes * 60)))
                var at = t, first = true
                while at < stop {
                    counter += 1
                    let kind = first ? "window.changed" : (counter % 10 == 0 ? "window.observed" : "mouse.click")
                    first = false
                    evidence.append((at, Evidence(id: String(format: "perf-%06d", counter), at: iso(at), kind: kind, app: app.name, bundle: app.bundle,
                                                  title: title, url: app.site, synthetic: true)))
                    at = at.addingTimeInterval(full ? 7 + Double(rng.next() % 5) : 50 + Double(rng.next() % 20))
                }
                // fix/prompt-row: today's Notes stretches end with a sent AI ask (Notes' bundle with the AI send facts: public
                // builds type in Notes and TextEdit only).
                if full, app.bundle == "com.apple.Notes" {
                    counter += 1
                    var e = Evidence(id: String(format: "perf-%06d", counter), at: iso(stop.addingTimeInterval(-3)), kind: "keyboard.text_input", app: app.name,
                                     bundle: app.bundle, title: title, text: ask, synthetic: true)
                    var unit = TypedUnitProvenance(runID: "ask-\(counter)", part: 1, sealReason: "submit", startedAt: iso(stop.addingTimeInterval(-30)), keys: 160, edits: 0, withheld: 0)
                    unit.surface = "ai"; unit.send = "detected"; unit.version = TypedUnitProvenance.sendFactsVersion
                    e.captureProvenance = NativeCaptureProvenance(policyRevision: "r", classifierVersion: "sensitive-typing/v2+typed-scrub/v1", windowID: "w", focusID: "f",
                                                                  checkedAt: iso(stop), generation: 1, unit: unit)
                    evidence.append((stop.addingTimeInterval(-3), e))
                }
                // A short gap now and then (lunch, a walk), so the day has blocks.
                t = stop.addingTimeInterval(rng.next() % 12 == 0 ? 50 * 60 : 20)
            }
            for (at, e) in evidence where (try? store.ingest(e, now: at.addingTimeInterval(1))) == true { ingested += 1 }
            days.append(try DayScope.key(date(day, 12, 0), timezone: zone))
        }
        let tNotes = CACurrentMediaTime()
        // Moment notes for most moments (a code note naming what was open); every 9th stays pending, and (fix/prompt-row)
        // today's Notes moments too, so their rows show the ask.
        for key in days {
            for (i, m) in try store.dayLayers(day: key, timezone: zone, limit: 1, now: now).activities.enumerated() where m.status != "ready" && i % 9 != 4 && !(key == days.last && m.apps.contains("Notes")) {
                guard let request = try? store.prepareNote(kind: "activity", day: key, timezone: zone, activityID: m.id, now: now) else { continue }
                let app = m.apps.first { !$0.isEmpty } ?? "an app"
                let subject = m.subject.trimmingCharacters(in: .whitespacesAndNewlines)
                let ids = request.actions.map(\.id)
                let half = max(1, ids.count / 2)
                let bullets = [NoteBullet(text: subject.isEmpty ? "Had \(app) open." : "Had \(subject) open in \(app).", actionIDs: Array(ids.prefix(half)), assertion: "observed"),
                               NoteBullet(text: "Kept working in \(app).", actionIDs: Array(ids.suffix(from: half)), assertion: "observed")]
                _ = try? store.commitNote(NoteWriterOutput(requestID: request.id, title: subject.isEmpty ? app : subject, bullets: bullets,
                                                          generator: "code/perf-fixture", generatorVersion: "1"), now: now)
            }
        }
        let tLevels = CACurrentMediaTime()
        // Levels: blocks, then days and weeks, from the level code's own extractive writer.
        var guardCount = 0, levels = [String: Int]()
        while guardCount < 200, let request = try store.levelWork(timezone: zone, now: now, backfillDays: 8, limit: 1).first {
            guardCount += 1
            let (title, lines) = LevelGrounding.extractive(request)
            let note = try store.commitLevel(request, title: title, lines: lines, generator: LevelWriterVersion.extractive, now: now)
            levels[note.level.rawValue, default: 0] += 1
        }
        print(String(format: "PERF seed phases: rows %.1fs, notes %.1fs, levels %.1fs %@", tNotes - tStart, tLevels - tNotes, CACurrentMediaTime() - tLevels, levels.description))
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
    @discardableResult static func wait(_ timeout: Double, _ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { pump(0.03) }
        return done()
    }
    static func scrollView(in view: NSView) -> NSScrollView? {
        if let s = view as? NSScrollView, s.documentView != nil, (s.documentView?.frame.height ?? 0) > 2000 { return s }
        for v in view.subviews { if let s = scrollView(in: v) { return s } }
        return nil
    }

    /// The store reads the view asks for (the app's `loadCanonicalDay`, off the main thread as in the app).
    final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        func add() { lock.lock(); n += 1; lock.unlock() }
    }

    struct Frames {
        var ms: [Double] = []
        /// Wall time of the whole run over its frames (everything the main thread did, between frames too).
        var wall: Double = 0
        mutating func add(_ v: Double) { ms.append(v) }
        var sorted: [Double] { ms.sorted() }
        func pct(_ p: Double) -> Double { let s = sorted; return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count - 1) * p))] }
        var max: Double { ms.max() ?? 0 }
        var mean: Double { ms.isEmpty ? 0 : ms.reduce(0, +) / Double(ms.count) }
        var over: Int { ms.filter { $0 > budget }.count }
        func line(_ name: String) -> String {
            String(format: "PERF %@: frames=%d mean=%.2fms p50=%.2fms p95=%.2fms max=%.2fms over%.0fms=%d wall/frame=%.2fms", name, ms.count, mean, pct(0.5), pct(0.95), max, budget, over, ms.isEmpty ? 0 : wall / Double(ms.count))
        }
    }

    /// One frame: the scroll moves, then SwiftUI updates, lays out and draws.
    static func frame(_ host: NSView, _ scroll: NSScrollView, to y: CGFloat, pointer: ((CGFloat) -> Void)? = nil) -> Double {
        let clip = scroll.contentView
        let t0 = CACurrentMediaTime()
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(clip)
        // The pointer resting over the list: the row now under it takes the hover (as AppKit's tracking areas do).
        pointer?(y)
        settle(host)
        return (CACurrentMediaTime() - t0) * 1000
    }

    /// Lets SwiftUI apply a change and draw it: one run-loop turn, layout, display.
    static func settle(_ host: NSView) {
        RunLoop.main.run(mode: .default, before: Date())
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    static func sweep(_ host: NSView, _ scroll: NSScrollView, step: CGFloat = 23, pointer: ((CGFloat) -> Void)? = nil) -> Frames {
        var frames = Frames()
        let extent = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
        var ys = Array(stride(from: CGFloat(0), through: extent, by: step))
        ys += ys.reversed()
        let t0 = CACurrentMediaTime()
        for y in ys { frames.add(frame(host, scroll, to: y, pointer: pointer)) }
        frames.wall = (CACurrentMediaTime() - t0) * 1000
        return frames
    }

    // MARK: Main

    static func main() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focus-scroll-perf-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: tmp)
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // FOCUS_SCROLL_HOME (investigation only): a seeded history kept between runs.
        let kept = ProcessInfo.processInfo.environment["FOCUS_SCROLL_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let home = kept ?? tmp.appendingPathComponent("memory", isDirectory: true)
        let seedStart = CACurrentMediaTime()
        let seeded: (days: [String], ingested: Int)
        if let kept, FileManager.default.fileExists(atPath: kept.appendingPathComponent("memory.sqlite").path) {
            seeded = (((todayDay - 6)...todayDay).map { String(format: "2026-09-%02d", $0) }, 0)
        } else {
            do { seeded = try seed(home: home) } catch { check(false, "seed the synthetic week", "\(error)"); exit(1) }
        }
        let reader = try! MemoryStore(home: home)
        let todayKey = seeded.days.last!
        let today = try! reader.dayLayers(day: todayKey, timezone: zone, limit: 200, now: now)
        let levels = try? reader.dayLevels(day: todayKey, timezone: zone)
        print(String(format: "PERF seed: %d rows, %d days, %.1fs", seeded.ingested, seeded.days.count, CACurrentMediaTime() - seedStart))
        print("PERF today: actions=\(today.summary.actionCount) moments=\(today.activities.count) blocks=\(levels?.blocks.count ?? 0) dayNote=\(levels?.day != nil)")
        if ProcessInfo.processInfo.environment["FOCUS_SCROLL_DEBUG"] != nil {
            for m in today.activities.prefix(40) { print("DEBUG moment \(m.subject) apps=\(m.apps) n=\(m.actionIDs.count) \(m.start)-\(m.end)") }
        }
        check(today.summary.actionCount >= 1500, "fixture: today is a full day (≥ 1,500 actions)", "\(today.summary.actionCount)")
        check(today.activities.count >= 100, "fixture: today has 100+ moments", "\(today.activities.count)")
        check((levels?.blocks.count ?? 0) >= 1, "fixture: today has level blocks", "\(levels?.blocks.count ?? 0)")

        // The app's reader, counted.
        let reads = Reads()
        let browser = ActivityBrowser(calendar: cal)
        browser.now = { now }
        browser.summaries = SummaryAvailability(provider: .local, busy: false)
        browser.loadCanonicalDay = { key, cursor in
            reads.add()
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
        browser.reopenCanonical = { _ in }
        browser.openApp = { _ in }
        browser.generateCanonicalNote = { _, _, _, _ in }
        // fix/prompt-row: the app's prompt loader (a reader picks the asks, the key-holding store opens them, off the main thread).
        let promptTimes = Reads(), promptStore = typedStore
        var promptMS = [Double]()
        let promptLock = NSLock()
        browser.loadMomentPrompts = { requests in
            promptTimes.add()
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let t0 = CACurrentMediaTime()
                    var prompts = [String: String]()
                    if let promptStore, promptStore.typingUnlocked, let asks = try? MemoryStore(home: home).momentPromptRows(requests), !asks.isEmpty {
                        prompts = (try? StoreWait.lettingMainIn { try promptStore.ownerMomentPrompts(asks, now: now) }) ?? [:]
                    }
                    promptLock.lock(); promptMS.append((CACurrentMediaTime() - t0) * 1000); promptLock.unlock()
                    continuation.resume(returning: prompts)
                }
            }
        }

        let size = NSSize(width: 1000, height: 820)
        let probe = FocusListProbe()
        let host = NSHostingView(rootView: AnyView(CanonicalTimeline(browser: browser)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .environment(\.daydreamFocusListProbe, probe)))
        window.setContentSize(size)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        let loaded = wait(20) { probe.rowFrames.count >= 100 }
        check(loaded, "hosted: today's rows lay out", "\(probe.rowFrames.count) rows")
        // fix/prompt-row: the asks land on their rows (off the main thread), cut to one line.
        let asked = wait(20) { (browser.today.snapshot?.moments.filter { $0.prompt != nil }.count ?? 0) >= 5 }
        let promptRows = browser.today.snapshot?.moments.filter { $0.prompt != nil } ?? []
        let shownAsks = promptRows.filter { MomentSubtitle.shownPrompt($0) != nil }.count
        check(asked && promptRows.allSatisfy { !($0.prompt ?? "").contains("\n") && ($0.prompt ?? "").hasPrefix("can you look at this crash log") },
              "hosted: today's AI asks land on their rows, one line each", "\(promptRows.count) asks")
        if typedStore == nil { print("PERF prompts: a kept history (FOCUS_SCROLL_HOME) has no key in this process: no asks") }
        promptLock.lock(); let loads = promptMS; promptLock.unlock()
        print(String(format: "PERF prompts: %d moments with an ask (%d shown; the rest have a note line), loader off the main thread %.1f ms (%d loads)",
                     promptRows.count, shownAsks, loads.max() ?? 0, promptTimes.count))
        pump(0.5)
        guard let scroll = scrollView(in: host) else { check(false, "hosted: the list's scroll view"); exit(1) }
        print(String(format: "PERF list: rows=%d document=%.0fpt visible=%.0fpt", probe.rowFrames.count,
                     scroll.documentView?.frame.height ?? 0, scroll.contentView.bounds.height))

        // Warm up (icons, fonts, first layouts), then measure.
        _ = sweep(host, scroll, step: 120)
        // FOCUS_SCROLL_SPIN=<seconds> (investigation only): keep scrolling so a sampler can watch.
        if let spin = ProcessInfo.processInfo.environment["FOCUS_SCROLL_SPIN"].flatMap(Double.init) {
            print("PERF spinning pid=\(ProcessInfo.processInfo.processIdentifier)"); fflush(stdout)
            let end = CACurrentMediaTime() + spin
            var flip = false
            while CACurrentMediaTime() < end {
                if ProcessInfo.processInfo.environment["FOCUS_SCROLL_SPIN_MODE"] == "select" {
                    let ids = browser.today.snapshot?.moments.map(\.id) ?? []
                    flip.toggle()
                    browser.selectedMomentID = flip ? ids.first : ids.last
                    settle(host)
                } else if ProcessInfo.processInfo.environment["FOCUS_SCROLL_SPIN_MODE"] == "hover" {
                    let ids = browser.today.snapshot?.moments.map(\.id) ?? []
                    flip.toggle()
                    probe.point?(flip ? ids.first : ids.last, false)
                    settle(host)
                } else if ProcessInfo.processInfo.environment["FOCUS_SCROLL_SPIN_MODE"] == "busy" {
                    flip.toggle()
                    browser.summaries = SummaryAvailability(provider: .local, busy: flip)
                    settle(host)
                } else { _ = sweep(host, scroll) }
            }
        }
        pump(0.3)
        let readsBefore = reads.count
        let still = sweep(host, scroll)
        let readsDuring = reads.count - readsBefore
        print(still.line("scroll"))
        print("PERF store reads while scrolling: \(readsDuring)")

        // The same sweep with the pointer resting mid-list: each frame the row now under it takes the hover.
        guard let point = probe.point else { check(false, "hosted: the probe's pointer hook"); exit(1) }
        let rows = probe.rowFrames, pointerY = scroll.contentView.bounds.height / 2
        var lit = Set<String>()
        let pointed = sweep(host, scroll) { y in
            let id = rows.first { $0.value.minY <= y + pointerY && y + pointerY < $0.value.maxY }?.key
            if let id { lit.insert(id) }
            point(id, false)
        }
        point(nil, false); settle(host)
        print(pointed.line("scroll with the pointer over the list"))
        print("PERF rows the pointer crossed: \(lit.count)")

        // Row to row: the selection moving one row (↓, or the pointer over the next row: the hover and the lit ribbon span
        // are the same kind of change), then a click-to-reference highlight lighting a few rows and going away.
        let ids = today.activities.map(\.id)
        var select = Frames()
        let selectStart = CACurrentMediaTime()
        for id in ids.prefix(60) {
            let t0 = CACurrentMediaTime()
            browser.selectedMomentID = id
            settle(host)
            select.add((CACurrentMediaTime() - t0) * 1000)
        }
        select.wall = (CACurrentMediaTime() - selectStart) * 1000
        print(select.line("selection moves one row"))
        // The pointer from row to row (the ribbon lights each one's span), then along the ribbon (each span lights its row).
        var rowHover = Frames(), spanHover = Frames()
        for (onRibbon, id) in ids.prefix(60).map({ (false, $0) }) + ids.prefix(60).map({ (true, $0) }) {
            let t0 = CACurrentMediaTime()
            point(id, onRibbon)
            settle(host)
            if onRibbon { spanHover.add((CACurrentMediaTime() - t0) * 1000) } else { rowHover.add((CACurrentMediaTime() - t0) * 1000) }
        }
        point(nil, true); settle(host)
        print(rowHover.line("pointer moves one row"))
        print(spanHover.line("pointer moves one ribbon span"))
        var highlight = Frames()
        for i in 0..<20 {
            let t0 = CACurrentMediaTime()
            browser.reference = i % 2 == 0 ? MomentReference(key: "perf:\(i)", day: todayKey, moments: Array(ids[(i * 3)..<(i * 3 + 4)])) : nil
            settle(host)
            highlight.add((CACurrentMediaTime() - t0) * 1000)
        }
        print(highlight.line("reference highlight on/off"))

        // Today reread while the list shows (a capture commit's refresh, at most every 10 s while recording).
        var refresh = Frames()
        for _ in 0..<5 {
            let before = reads.count
            browser.today.refresh(force: true)
            _ = wait(5) { reads.count > before }
            let t0 = CACurrentMediaTime()
            pump(0.3)
            refresh.add((CACurrentMediaTime() - t0) * 1000 - 300)
        }
        print(refresh.line("today reread (main-thread share)"))
        // The writer's busy flag flipping (each local model load and batch): the page redraws.
        var busy = Frames()
        for i in 0..<10 {
            let t0 = CACurrentMediaTime()
            browser.summaries = SummaryAvailability(provider: .local, busy: i % 2 == 0)
            settle(host)
            busy.add((CACurrentMediaTime() - t0) * 1000)
        }
        print(busy.line("summaries busy flip"))

        check(readsDuring == 0, "scroll: no store read while scrolling", "\(readsDuring) reads")
        check(still.max <= budget, String(format: "scroll: every frame ≤ %.0f ms", budget), still.line("scroll"))
        check(lit.count >= 20, "scroll with the pointer: the pointer crosses rows", "\(lit.count) rows")
        check(pointed.max <= budget, String(format: "scroll with the pointer over the list: every frame ≤ %.0f ms", budget), pointed.line("pointer scroll"))
        check(rowHover.pct(0.95) <= budget, String(format: "the pointer moving a row: 95%% of changes ≤ %.0f ms", budget), rowHover.line("row hover"))
        check(spanHover.pct(0.95) <= budget, String(format: "the pointer moving along the ribbon: 95%% of changes ≤ %.0f ms", budget), spanHover.line("span hover"))
        check(select.pct(0.95) <= 2 * budget, String(format: "the selection moving a row: 95%% of changes ≤ %.0f ms", 2 * budget), select.line("selection"))
        check(highlight.pct(0.95) <= 4 * budget, String(format: "a reference highlight on or off: 95%% of changes ≤ %.0f ms", 4 * budget), highlight.line("highlight"))

        if failures > 0 {
            FileHandle.standardError.write(Data("FAIL: \(failures) focus list scroll perf check(s) failed\n".utf8))
            exit(1)
        }
        print("PASS: all focus list scroll perf checks")
    }
}

extension SystemRandomNumberGenerator {
    /// A seeded generator (splitmix64), so the synthetic week is the same on every run.
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
