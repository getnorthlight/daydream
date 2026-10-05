// DD-RECIPE: APP (scroll bench; needs a screen, so it is not a runner step: run scripts/scroll-bench.sh)
//
// claude/perf3-1005 (owner 10/04, "still laggy AF"): scroll hitches in the real memory window, measured on screen.
// SYNTHETIC ONLY. `--seed <home>` writes about three weeks of made-up history into a scratch folder (busy days of
// 300+ moments, Chrome pages on many sites, installed and missing apps, moment notes, blocks, day and week notes, AI
// asks typed in Notes). Without it, the bench opens that history with the app's own model (MemoryViewModel, compiled
// from Sources/MacMemApp with DEVELOPMENT_SOURCE_CHECKS: typing keys in memory, no login item), shows MemoryWindow in a
// window on screen, starts recording the way the app does (the recorder's 0.5 s heartbeat, its status refresh and
// every timer run; scroll-bench.sh compiles a copy of EventCapture without the input tap, the Accessibility observer
// and Chrome page reads, so nothing outside the bench is read or recorded), and scrolls each surface programmatically,
// one step per display frame (the window's CADisplayLink), timing every frame.
//
// A frame is the time between two display-link callbacks on the main thread; a hitch is a frame that took longer than
// 1.5 refresh periods (at least one frame dropped). Results go to stdout as BENCH lines and to $SCROLL_BENCH_OUT.
// Nothing here prints a title, a typed word or a URL.
import AppKit
import QuartzCore
import SwiftUI
import MemoryCore
import HistoryCore
import MemoryUI

// MARK: - Seeding (synthetic)

enum BenchSeed {
    struct App { let name: String; let bundle: String; let titles: [String] }
    /// Installed system apps (real icons) and apps most Macs don't have (lettered tiles).
    static let apps: [App] = [
        App(name: "Mail", bundle: "com.apple.mail", titles: ["Inbox", "Re: Pilot with Northwind", "Invoice #3107 from Hostwell", "Re: Q3 numbers"]),
        App(name: "Xcode", bundle: "com.apple.dt.Xcode", titles: ["CaptureCoordinator.swift", "WeeklyExport.swift", "Rows.swift"]),
        App(name: "Slack", bundle: "com.tinyspeck.slackmacgap", titles: ["#launch - Tallybird", "Maya (DM)", "#eng - Tallybird"]),
        App(name: "Messages", bundle: "com.apple.MobileSMS", titles: ["Sam", "Maya", "Family"]),
        App(name: "Notes", bundle: "com.apple.Notes", titles: ["Weekly sync notes", "Ideas", "Launch day plan"]),
        App(name: "Terminal", bundle: "com.apple.Terminal", titles: ["zsh — tallybird", "swift build — tallybird"]),
        App(name: "Figma", bundle: "com.figma.Desktop", titles: ["Onboarding flow", "Day card v3"]),
        App(name: "Calendar", bundle: "com.apple.iCal", titles: ["Week of Sep 21", "Weekly sync"]),
        App(name: "Zed", bundle: "dev.zed.Zed", titles: ["ribbon.swift — tallybird", "store.swift — tallybird"]),
        App(name: "Safari", bundle: "com.apple.Safari", titles: ["Start Page", "Reading list"]),
        App(name: "Preview", bundle: "com.apple.Preview", titles: ["Lease.pdf", "Receipt.pdf"]),
        App(name: "Linear", bundle: "com.linear", titles: ["TAL-412 Capture pipeline", "My issues"]),
    ]
    /// Chrome pages: sites with bundled icons and sites without (a letter). Made-up paths.
    static let sites = ["https://docs.google.com", "https://github.com", "https://www.youtube.com", "https://mail.google.com",
                        "https://www.figma.com", "https://linear.app", "https://www.notion.so", "https://stackoverflow.com",
                        "https://www.reddit.com", "https://news.ycombinator.com", "https://www.amazon.com", "https://calendar.google.com",
                        "https://chatgpt.com", "https://claude.ai", "https://www.wikipedia.org", "https://x.com",
                        "https://tallybird.example", "https://northwind.example", "https://hostwell.example", "https://maple-ledger.example"]
    static let pageTitles = ["Q3 update", "Launch checklist", "Pull request #412", "Issues", "Swift concurrency talk", "Inbox",
                             "Design review", "Roadmap", "Answer: actor reentrancy", "Weekly thread", "Order #114-2", "Week view"]
    static let words = ["alpha", "harbor", "maple", "orbit", "cedar", "delta", "ember", "falcon", "garnet", "hazel", "indigo", "juniper",
                        "kestrel", "lagoon", "meadow", "nectar", "oasis", "pepper", "quartz", "raven", "sierra", "tundra", "umber", "velvet"]
    static let ask = "can you look at this crash log and tell me why the archive step fails\n\non the release configuration only? debug works fine"

    struct Seeded { let days: [String]; let rows: Int; let busyDays: [String] }

    static func iso(_ d: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: d) }

    /// Three weeks up to `now` in `zone`. Busy days (most weekdays): 7 AM to 9 PM, a window every 1-3 minutes, so
    /// 300-400 moments; light days (weekends): a morning. Today runs to `now`.
    static func seed(home: URL, now: Date, zone: TimeZone, days count: Int = 21) throws -> Seeded {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        let keys = InMemoryTypedKeyStore()
        let first = cal.date(byAdding: .day, value: -(count - 1), to: cal.startOfDay(for: now))!
        var policy = try store.policy(); policy.captureText = true; policy.typedConsentVersion = 1
        try store.updatePolicy(policy, now: first)
        try store.attachVault(TypedTextVault(keyStore: keys)); try store.acceptSafeTyping(now: first); try store.setUpTypedVault(now: first)
        var rng = SplitMix(seed: 20261005)
        var counter = 0, ingested = 0, stretch = 0
        var dayKeys = [String](), busy = [String]()
        let t0 = CACurrentMediaTime()
        for offset in 0..<count {
            let dayStart = cal.date(byAdding: .day, value: offset, to: first)!
            let weekday = cal.component(.weekday, from: dayStart)
            let isToday = offset == count - 1
            let heavy = isToday || (weekday != 1 && weekday != 7)
            var t = dayStart.addingTimeInterval((heavy ? 7 : 9.5) * 3600)
            var end = dayStart.addingTimeInterval((heavy ? 21 : 12.5) * 3600)
            if isToday { end = min(end, now.addingTimeInterval(-120)); if end <= t { t = dayStart.addingTimeInterval(60); end = max(t.addingTimeInterval(1800), now.addingTimeInterval(-60)) } }
            var evidence = [(Date, Evidence)]()
            var last = -1
            while t < end {
                stretch += 1
                let chrome = rng.next() % 3 == 0
                var pick = Int(rng.next() % UInt64(apps.count)); if pick == last { pick = (pick + 1) % apps.count }; last = chrome ? -1 : pick
                let app = apps[pick]
                let suffix = " – " + words[stretch % words.count] + " " + words[(stretch / words.count + 7) % words.count]
                let site = chrome ? sites[Int(rng.next() % UInt64(sites.count))] : ""
                let title = chrome ? pageTitles[Int(rng.next() % UInt64(pageTitles.count))] + suffix
                                   : app.titles[Int(rng.next() % UInt64(app.titles.count))] + suffix
                let minutes = heavy ? 1 + Int(rng.next() % 3) : 6 + Int(rng.next() % 8)
                let stop = min(end, t.addingTimeInterval(Double(minutes * 60)))
                var at = t, firstRow = true
                while at < stop {
                    counter += 1
                    let kind = firstRow ? "window.changed" : (counter % 10 == 0 ? "window.observed" : "mouse.click")
                    firstRow = false
                    let path = chrome ? site + "/" + words[counter % words.count] + "/" + String(counter % 97) : ""
                    evidence.append((at, Evidence(id: String(format: "bench-%07d", counter), at: iso(at), kind: kind,
                                                  app: chrome ? "Chrome" : app.name, bundle: chrome ? "com.google.Chrome" : app.bundle,
                                                  title: title, url: path, synthetic: true)))
                    at = at.addingTimeInterval(heavy ? 8 + Double(rng.next() % 6) : 45 + Double(rng.next() % 20))
                }
                if heavy, !chrome, app.bundle == "com.apple.Notes" {
                    counter += 1
                    var e = Evidence(id: String(format: "bench-%07d", counter), at: iso(stop.addingTimeInterval(-3)), kind: "keyboard.text_input",
                                     app: app.name, bundle: app.bundle, title: title, text: ask, synthetic: true)
                    var unit = TypedUnitProvenance(runID: "ask-\(counter)", part: 1, sealReason: "submit", startedAt: iso(stop.addingTimeInterval(-30)),
                                                   keys: 140, edits: 0, withheld: 0)
                    unit.surface = "ai"; unit.send = "detected"; unit.version = TypedUnitProvenance.sendFactsVersion
                    e.captureProvenance = NativeCaptureProvenance(policyRevision: "r", classifierVersion: "sensitive-typing/v2+typed-scrub/v1",
                                                                  windowID: "w", focusID: "f", checkedAt: iso(stop), generation: 1, unit: unit)
                    evidence.append((stop.addingTimeInterval(-3), e))
                }
                t = stop.addingTimeInterval(rng.next() % 50 == 0 ? 25 * 60 : 15)
            }
            for (at, e) in evidence where (try? store.ingest(e, now: at.addingTimeInterval(1))) == true { ingested += 1 }
            let key = try DayScope.key(dayStart.addingTimeInterval(12 * 3600), timezone: zone.identifier)
            dayKeys.append(key); if heavy { busy.append(key) }
            FileHandle.standardError.write(Data("seed: day \(offset + 1)/\(count) rows so far \(ingested)\n".utf8))
        }
        let t1 = CACurrentMediaTime()
        // Moment notes for most moments (a pending one now and then), as a summarizer that kept up would leave them.
        var notes = 0
        for key in dayKeys {
            let layers = try store.dayLayers(day: key, timezone: zone.identifier, limit: 1, now: now)
            for (i, m) in layers.activities.enumerated() where m.status != "ready" && i % 11 != 5 {
                guard let request = try? store.prepareNote(kind: "activity", day: key, timezone: zone.identifier, activityID: m.id, now: now) else { continue }
                let app = m.apps.first { !$0.isEmpty } ?? "an app"
                let subject = m.subject.trimmingCharacters(in: .whitespacesAndNewlines)
                let ids = request.actions.map(\.id)
                let half = max(1, ids.count / 2)
                let bullets = [NoteBullet(text: subject.isEmpty ? "Had \(app) open." : "Worked on \(subject) in \(app).", actionIDs: Array(ids.prefix(half))),
                               NoteBullet(text: "Kept going in \(app).", actionIDs: Array(ids.suffix(from: half)))]
                if (try? store.commitNote(NoteWriterOutput(requestID: request.id, title: subject.isEmpty ? app : subject, bullets: bullets,
                                                           generator: "code/bench-fixture", generatorVersion: "1"), now: now)) != nil { notes += 1 }
            }
            FileHandle.standardError.write(Data("seed: notes \(key) total \(notes)\n".utf8))
        }
        let t2 = CACurrentMediaTime()
        var levels = 0
        while levels < 800, let request = try store.levelWork(timezone: zone.identifier, now: now, backfillDays: count + 1, limit: 1).first {
            let (title, lines) = LevelGrounding.extractive(request)
            _ = try store.commitLevel(request, title: title, lines: lines, generator: LevelWriterVersion.extractive, now: now)
            levels += 1
        }
        // The typing key, so the bench's model opens the asks (synthetic key, scratch folder only).
        if let raw = keys.raw { try raw.write(to: home.appendingPathComponent("bench-typing-key.bin")) }
        print(String(format: "BENCH seed: %d rows, %d days (%d busy), %d notes, %d levels; rows %.0fs notes %.0fs levels %.0fs",
                     ingested, dayKeys.count, busy.count, notes, levels, t1 - t0, t2 - t1, CACurrentMediaTime() - t2))
        try (dayKeys.joined(separator: ",") + "\n" + busy.joined(separator: ",") + "\n").write(to: home.appendingPathComponent("bench-days.txt"), atomically: true, encoding: .utf8)
        return Seeded(days: dayKeys, rows: ingested, busyDays: busy)
    }
}

struct SplitMix: RandomNumberGenerator {
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

// MARK: - Frame timing

/// Every display-link callback's time on the main thread, and the run-loop turns that held the main thread.
@MainActor final class FrameClock: NSObject {
    private(set) var stamps: [CFTimeInterval] = []
    private(set) var period: CFTimeInterval = 1.0 / 60
    private var link: CADisplayLink?
    var onFrame: (() -> Void)?
    func start(on view: NSView) {
        stamps.removeAll()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    func stop() { link?.invalidate(); link = nil }
    @objc private func tick(_ link: CADisplayLink) {
        let p = link.targetTimestamp - link.timestamp
        if p > 0.002 && p < 0.05 { period = p }
        stamps.append(CACurrentMediaTime())
        onFrame?()
    }
}

/// Main-thread stalls: a background thread hands a no-op to the main queue every 5 ms and times how long the main thread
/// takes to run it. A stall of N ms shows as one wait of about N ms (the thread waits for its no-op, then sends the next).
/// (A run-loop observer can't tell: while frames and timers keep arriving the main run loop never goes to sleep, so
/// "turns" span whole scrolls while the main thread is in fact free.)
final class StallWatch: @unchecked Sendable {
    private let probe = KeyHandoffProbe(every: 0.005)
    private(set) var stalls: [Double] = []
    private(set) var waits: [Double] = []
    func start() { stalls.removeAll(); waits.removeAll(); probe.start() }
    func stop() { waits = probe.stop(); stalls = waits.filter { $0 > 25 } }
}

/// claude/perf3-1005 (coordinator): typing's view of the main thread. The input tap hands each key to the main thread
/// and waits for it (TapMainHandoff, 300 ms at most), and a key the main thread takes more than 150 ms to see is dropped
/// as late (`key.lateAtIntake`). This stands in for a person typing about 8 keys a second: a background thread hands
/// a no-op to the main queue every 120 ms and times how long the main thread takes to run it.
final class KeyHandoffProbe: @unchecked Sendable {
    private let every: TimeInterval
    init(every: TimeInterval = 0.12) { self.every = every }
    private let lock = NSLock()
    private var waits: [Double] = []
    private var running = false
    func start() {
        lock.lock(); waits.removeAll(); running = true; lock.unlock()
        Thread.detachNewThread { [self] in
            while true {
                lock.lock(); let on = running; lock.unlock()
                guard on else { return }
                let sent = CACurrentMediaTime(), done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { done.signal() }
                done.wait()
                let ms = (CACurrentMediaTime() - sent) * 1000
                lock.lock(); waits.append(ms); lock.unlock()
                Thread.sleep(forTimeInterval: every)
            }
        }
    }
    func stop() -> [Double] { lock.lock(); defer { lock.unlock() }; running = false; return waits }
}

struct FrameStats {
    let name: String
    let ms: [Double]
    let period: Double
    let stalls: [Double]
    var keys: [Double] = []
    var mainWaits: [Double] = []
    static func pct(_ v: [Double], _ p: Double) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))] }
    func pct(_ p: Double) -> Double { Self.pct(ms, p) }
    var mainLine: String {
        String(format: "BENCH %@ main-thread waits (5 ms ping): n=%d p50=%.2fms p99=%.2fms max=%.1fms over25ms=%d over100ms=%d",
               name, mainWaits.count, Self.pct(mainWaits, 0.5), Self.pct(mainWaits, 0.99), mainWaits.max() ?? 0,
               mainWaits.filter { $0 > 25 }.count, mainWaits.filter { $0 > 100 }.count)
    }
    var keyLine: String {
        String(format: "BENCH %@ key hand-off: keys=%d p50=%.2fms p99=%.2fms max=%.1fms over100ms=%d over150ms(dropped as late)=%d",
               name, keys.count, Self.pct(keys, 0.5), Self.pct(keys, 0.99), keys.max() ?? 0, keys.filter { $0 > 100 }.count, keys.filter { $0 > 150 }.count)
    }
    var hitches: Int { ms.filter { $0 > period * 1500 }.count }
    /// Time lost to late frames, per second of scrolling (Apple's "hitch time ratio", ms/s).
    var hitchRatio: Double {
        let total = ms.reduce(0, +); guard total > 0 else { return 0 }
        return ms.reduce(0) { $0 + max(0, $1 - period * 1000) } / (total / 1000)
    }
    var line: String {
        String(format: "BENCH %@: frames=%d refresh=%.1fms p50=%.2fms p95=%.2fms p99=%.2fms max=%.2fms hitches=%d hitch-ratio=%.1fms/s main-stalls>25ms=%d >100ms=%d (max %.0fms)",
               name, ms.count, period * 1000, pct(0.5), pct(0.95), pct(0.99), ms.max() ?? 0, hitches, hitchRatio, stalls.count, stalls.filter { $0 > 100 }.count, stalls.max() ?? 0)
    }
}

// MARK: - The bench

@MainActor final class ScrollBench: NSObject, NSApplicationDelegate {
    let home: URL
    let out: URL?
    var model: MemoryViewModel!
    var window: NSWindow!
    let clock = FrameClock()
    let keys = KeyHandoffProbe()
    let stalls = StallWatch()
    var results: [FrameStats] = []
    var dayKeys: [String] = []
    var busyDays: [String] = []
    let only: Set<String>
    let speed: CGFloat
    let passes: Int
    /// The rows' frames and the pointer (an off-screen pointer gets no hovers; the list's own probe moves it).
    let probe = FocusListProbe()

    init(home: URL) {
        self.home = home
        out = ProcessInfo.processInfo.environment["SCROLL_BENCH_OUT"].map { URL(fileURLWithPath: $0) }
        only = Set((ProcessInfo.processInfo.environment["SCROLL_BENCH_ONLY"] ?? "").split(separator: ",").map(String.init))
        speed = CGFloat(Double(ProcessInfo.processInfo.environment["SCROLL_BENCH_SPEED"] ?? "") ?? 2400)
        passes = Int(ProcessInfo.processInfo.environment["SCROLL_BENCH_PASSES"] ?? "") ?? 2
    }

    func log(_ s: String) { print(s); fflush(stdout); if let out { if let h = try? FileHandle(forWritingTo: out) { h.seekToEndOfFile(); h.write(Data((s + "\n").utf8)); try? h.close() } } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await self.run(); NSApp.terminate(nil) }
    }

    func pump(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
    func wait(_ timeout: Double, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { await pump(0.05) }
        return done()
    }

    /// The tallest visible scroll view whose document is longer than its viewport, under `view`.
    func scrollViews(in view: NSView) -> [NSScrollView] {
        var found = [NSScrollView]()
        if let s = view as? NSScrollView, let doc = s.documentView, doc.frame.height > s.contentView.bounds.height + 40, !s.isHiddenOrHasHiddenAncestor { found.append(s) }
        for v in view.subviews { found += scrollViews(in: v) }
        return found
    }

    func run() async {
        if let raw = try? Data(contentsOf: home.appendingPathComponent("bench-typing-key.bin")) {
            MemoryViewModel.typedKeyStore = { _ in InMemoryTypedKeyStore(item: raw) }
        }
        if let text = try? String(contentsOf: home.appendingPathComponent("bench-days.txt"), encoding: .utf8) {
            let lines = text.split(separator: "\n").map(String.init)
            dayKeys = lines.first?.split(separator: ",").map(String.init) ?? []
            busyDays = lines.count > 1 ? lines[1].split(separator: ",").map(String.init) : []
        }
        // The app's permission reads and recorder start, granted here (the bench's EventCapture copy installs no tap).
        MemoryViewModel.permissionRead = { PermissionSnapshot(accessibility: true, inputMonitoring: true) }
        MemoryViewModel.permissionsGranted = { true }
        MemoryViewModel.startInput = { $0.start() }
        MemoryViewModel.readLaunchLocation = { .applications }

        let t0 = CACurrentMediaTime()
        model = MemoryViewModel()
        // The bench often runs with the screen locked (an unattended Mac): the model would pause recording for the lock
        // and the heartbeat, the thing measured under a busy disk, would never run. The bench's model sees no lock.
        model.wakeSystem = WakeSystem(screenLocked: { false }, onConsole: { true }, after: WakeSystem.live.after, now: WakeSystem.live.now)
        log(String(format: "BENCH model made in %.0f ms", (CACurrentMediaTime() - t0) * 1000))
        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1100, height: 760), styleMask: [.titled, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "DayDream scroll bench (synthetic)"
        window.contentView = NSHostingView(rootView: MemoryWindow(model: model, chrome: .inline).environment(\.daydreamFocusListProbe, probe))
        window.orderFrontRegardless()
        if ProcessInfo.processInfo.environment["SCROLL_BENCH_RECORD"] != "0" {
            model.startCapture()
            _ = await wait(5) { self.model.recording }
            log("BENCH recording: \(model.recording)")
        }
        let browser = model.activity
        let loaded = await wait(60) { browser.today.snapshot != nil }
        log("BENCH today loaded: \(loaded) moments=\(browser.today.snapshot?.moments.count ?? -1)")
        await pump(3)

        // Idle: nothing scrolls; what the timers alone cost the main thread.
        if want("idle") { results.append(await measureIdle("idle (recording, window open)", seconds: 10)) }
        if want("today") { await scrollScenario("today") }
        if want("pointer") { await scrollScenario("today, the pointer resting on the list", pointer: true) }
        // Today read again every 1.5 s while scrolling, as it is after each saved click or window change and each note
        // the summarizer writes.
        if want("rereads") { await scrollScenario("today, read again every 1.5 s", rereadEvery: 1.5) }
        // A click in another app every 0.5 s while scrolling, through the recorder's own intake (Coordinator.record): the
        // per-event work the input tap hands the main thread (the choices read, the click's save, today read again).
        if want("clicks") { await scrollScenario("today, a click saved every 0.5 s", clickEvery: 0.5) }
        if let busy = busyDays.dropLast().last, want("past") {
            browser.focusedDay = busy
            _ = await wait(30) { self.scrollable() != nil && (self.scrollable()?.documentView?.frame.height ?? 0) > 3000 }
            await pump(2)
            await scrollScenario("busy past day")
            browser.focusedDay = nil
            await pump(2)
        }
        if want("expanded") {
            if let snap = browser.today.snapshot, let m = snap.moments.max(by: { $0.actionIDs.count < $1.actionIDs.count }) {
                browser.expandedMomentID = m.id
                await pump(2)
                await scrollScenario("today, a card open (What happened)")
                browser.expandedMomentID = nil
                await pump(1)
            }
        }
        if want("detail") {
            if let snap = browser.today.snapshot, let m = snap.moments.max(by: { $0.actionIDs.count < $1.actionIDs.count }) {
                let before = Set(scrollViews(in: window.contentView!).map(ObjectIdentifier.init))
                browser.selectedCanonicalActivity = m.id
                await pump(3)
                let fresh = scrollViews(in: window.contentView!).first { !before.contains(ObjectIdentifier($0)) }
                log("BENCH detail: moment actions=\(m.actionIDs.count) own scroll view=\(fresh != nil)")
                await scrollScenario("details page (What happened)", in: fresh)
                browser.selectedCanonicalActivity = nil
                await pump(1)
            }
        }
        if want("search") {
            let before = Set(scrollViews(in: window.contentView!).map(ObjectIdentifier.init))
            browser.query = "Chrome"
            _ = await wait(20) { self.scrollViews(in: self.window.contentView!).contains { !before.contains(ObjectIdentifier($0)) } }
            await pump(3)
            let fresh = scrollViews(in: window.contentView!).first { !before.contains(ObjectIdentifier($0)) }
            log("BENCH search: results scroll view=\(fresh != nil)")
            if let fresh { await scrollScenario("search results", in: fresh) }
            browser.query = ""
            await pump(1)
        }
        if want("idle") { results.append(await measureIdle("idle after", seconds: 5)) }
        log("BENCH summary:")
        for r in results { log(r.line); log(r.mainLine); log(r.keyLine) }
        let scrolling = results.filter { !$0.name.hasPrefix("idle") }
        if let p = results.first?.period {
            let all = FrameStats(name: "all scrolling", ms: scrolling.flatMap { $0.ms }, period: p, stalls: scrolling.flatMap { $0.stalls }, keys: scrolling.flatMap { $0.keys }, mainWaits: scrolling.flatMap { $0.mainWaits })
            log(all.line); log(all.mainLine); log(all.keyLine)
        }
    }

    func want(_ name: String) -> Bool { only.isEmpty || only.contains(name) }

    func scrollable() -> NSScrollView? {
        scrollViews(in: window.contentView!).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    func measureIdle(_ name: String, seconds: Double) async -> FrameStats {
        clock.onFrame = nil
        stalls.start(); keys.start(); clock.start(on: window.contentView!)
        await pump(seconds)
        clock.stop(); stalls.stop()
        return stats(name, keys: keys.stop())
    }

    func stats(_ name: String, keys: [Double]) -> FrameStats {
        let s = clock.stamps
        let ms = zip(s.dropFirst(), s).map { ($0 - $1) * 1000 }
        let r = FrameStats(name: name, ms: ms, period: clock.period, stalls: stalls.stalls, keys: keys, mainWaits: stalls.waits)
        log(r.line); log(r.mainLine); log(r.keyLine)
        return r
    }

    /// Down to the end and back up, `passes` times, `speed` points a second, one step per display frame.
    func scrollScenario(_ name: String, in given: NSScrollView? = nil, pointer: Bool = false, rereadEvery: Double? = nil, clickEvery: Double? = nil) async {
        guard let scroll = given ?? scrollable() else { log("BENCH \(name): no scroll view"); return }
        let clip = scroll.contentView
        let extent = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
        log(String(format: "BENCH %@: document=%.0fpt viewport=%.0fpt", name, scroll.documentView?.frame.height ?? 0, clip.bounds.height))
        clip.scroll(to: .zero); scroll.reflectScrolledClipView(clip)
        await pump(1)
        var direction: CGFloat = 1, pass = 0, last = CACurrentMediaTime(), lastReread = last, lastClick = last, clicks = 0
        var finished = false
        clock.onFrame = { [weak self] in
            guard let self, !finished else { return }
            let now = CACurrentMediaTime()
            // Distance follows wall time, as a trackpad's does: a late frame jumps further.
            let dy = self.speed * CGFloat(min(0.1, now - last)) * direction
            last = now
            if let every = rereadEvery, now - lastReread >= every { lastReread = now; self.model.activity.today.refresh(force: true) }
            if let every = clickEvery, now - lastClick >= every, let coordinator = self.model.coordinator {
                lastClick = now; clicks += 1
                let snap = AccessibilitySnapshot(focusID: "bench-focus-\(clicks % 7)", app: AppInfo(name: "Notes", bundleIdentifier: "com.apple.Notes"),
                                                 window: WindowInfo(title: "Fictional note \(clicks % 5)", url: nil),
                                                 element: ElementInfo(role: "AXTextArea", subrole: nil, title: nil, value: nil, identifier: nil),
                                                 secureInput: false, privateBrowsing: false, selectedText: nil, selectedLocation: nil, selectedLength: nil)
                coordinator.record(kind: clicks % 4 == 0 ? .windowChanged : .mouseClick, snapshot: snap)
            }
            let docHeight = scroll.documentView?.frame.height ?? 0
            let limit = max(0, docHeight - clip.bounds.height)
            var y = clip.bounds.origin.y + dy
            if y >= limit { y = limit; direction = -1 }
            if y <= 0 && direction < 0 { y = 0; direction = 1; pass += 1; if pass >= self.passes { finished = true } }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scroll.reflectScrolledClipView(clip)
            // The row now under a pointer resting mid-list takes the hover, as AppKit's tracking areas do.
            if pointer, let point = self.probe.point {
                let at = y + clip.bounds.height / 2
                point(self.probe.rowFrames.first { $0.value.minY <= at && at < $0.value.maxY }?.key, false)
            }
        }
        stalls.start(); keys.start(); clock.start(on: scroll)
        let deadline = Date().addingTimeInterval(Double(extent / speed) * Double(passes) * 2 + 20)
        while !finished && Date() < deadline { await pump(0.1) }
        clock.stop(); stalls.stop(); clock.onFrame = nil
        results.append(stats(name, keys: keys.stop()))
        log("BENCH \(name): recording at the end: \(model.recording) (\(model.status))")
    }
}

@main enum ScrollBenchMain {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--seed"), i + 1 < args.count {
            let home = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            do { _ = try BenchSeed.seed(home: home, now: Date(), zone: .current) } catch { FileHandle.standardError.write(Data("seed failed: \(error)\n".utf8)); exit(1) }
            exit(0)
        }
        guard let path = ProcessInfo.processInfo.environment["MAC_MEM_HOME"], path.hasPrefix("/"), !path.contains("Application Support/DayDream"),
              !path.contains("Mac Mem") else {
            FileHandle.standardError.write(Data("REFUSING: MAC_MEM_HOME must name a scratch history\n".utf8)); exit(2)
        }
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let bench = ScrollBench(home: URL(fileURLWithPath: path, isDirectory: true))
            app.delegate = bench
            withExtendedLifetime(bench) { app.run() }
        }
    }
}
