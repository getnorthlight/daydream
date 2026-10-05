import Foundation
import AppKit
@testable import MemoryCore
@testable import WriterBackend

/// perf2-1005 (owner 10/04: DayDream "took like 10 seconds" to open, keys dropped while a 577-note backlog ran): the
/// app's background note writer (`WriterEnvironment.app`). REAL WriterIntegration, an instant fake model, a simulated
/// clock and SYNTHETIC busy days (the same generator as writer-spin). No model, no network, no Keychain, no real history.
///   Q1. while DayDream opens or the person types (`quietFor` > 0) a look writes nothing, reads nothing and looks again
///       once it is quiet
///   Q2. control (the checks' environment, `pastDayNotes` true): catch-up writes past days' moments and leaves more queued
///   Q3. the app's environment (`pastDayNotes` false) on the same history: the past days' queued entries are dropped,
///       never run, and the look writes only today's moments
///   Q4. a batch stops between notes once typing starts, and the writer looks again when it is quiet
///   Q5. the app's environment: utility priority, the launch quiet ends 10 s after Today shows (a minute at most)
let zone = "America/Los_Angeles"

final class SimClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date) { value = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ date: Date) { lock.lock(); if date > value { value = date }; lock.unlock() }
    func advance(_ seconds: TimeInterval) { lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock() }
}
final class SimWorld: @unchecked Sendable {
    private let lock = NSLock()
    private var _power = ModelPower.ac
    private var _lastInput = Date.distantPast
    var power: ModelPower { get { lock.lock(); defer { lock.unlock() }; return _power } set { lock.lock(); _power = newValue; lock.unlock() } }
    var lastInput: Date { get { lock.lock(); defer { lock.unlock() }; return _lastInput } set { lock.lock(); _lastInput = newValue; lock.unlock() } }
    var done = 0
}

actor NoKeys: WriterSecureKeyStore {
    func readSecret() async throws -> String { "" }
    func saveSecret(_ value: String) async throws {}
    func removeSecret() async throws {}
}

/// A Swift port of sx-diag-energy/gen_busy.py (same shape: ChatGPT, Slack, Chrome, Xcode, Messages and Terminal
/// stretches, 09:00-18:00 with a lunch gap), seeded, so the check needs no file.
struct BusyDay {
    struct RNG { var s: UInt64; mutating func next() -> Double { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; z ^= z >> 31; return Double(z >> 11) / Double(1 << 53) } }
    var rng: RNG
    var rows: [[String: Any]] = []
    var seq = 0, runs = 0
    var t: Date
    let day: Int
    static let bundles = ["ChatGPT": "com.openai.chat", "Xcode": "com.apple.dt.Xcode", "Messages": "com.apple.MobileSMS",
                          "Slack": "com.tinyspeck.slackmacgap", "Google Chrome": "com.google.Chrome", "Terminal": "com.apple.Terminal"]
    init(day: Int, seed: UInt64) {
        rng = RNG(s: seed); self.day = day
        t = ISO8601DateFormatter().date(from: String(format: "2026-09-%02dT16:00:00Z", day))!
    }
    mutating func uniform(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * rng.next() }
    mutating func int(_ lo: Int, _ hi: Int) -> Int { lo + Int(rng.next() * Double(hi - lo + 1)) }
    mutating func adv(_ s: Double) -> Date { t = t.addingTimeInterval(s); return t }
    static func iso(_ d: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: d) }
    mutating func ev(_ at: Date, _ kind: String, _ app: String, _ title: String = "", _ url: String = "", _ text: String = "", unit: [String: Any]? = nil) {
        seq += 1
        var e: [String: Any] = ["id": String(format: "busy-%d-%05d", day, seq), "at": Self.iso(at), "kind": kind, "app": app, "bundle": Self.bundles[app]!,
                                "title": title, "url": url, "text": text, "secure": false, "privateWindow": false, "synthetic": true]
        if let unit {
            e["captureProvenance"] = ["policyRevision": "synthetic", "classifierVersion": "sensitive-typing/v2", "windowID": "w", "focusID": "f",
                                      "checkedAt": Self.iso(at), "generation": 1, "unit": unit] as [String: Any]
        }
        rows.append(e)
    }
    mutating func typed(_ at: Date, _ app: String, _ title: String, _ text: String, _ surface: String, url: String = "", to: String? = nil, send: Bool = true) {
        runs += 1
        var unit: [String: Any] = ["version": "typed-unit/v3", "runID": "run-\(runs)", "part": 1, "sealReason": send ? "submit" : "idle",
                                   "startedAt": Self.iso(at.addingTimeInterval(-20)), "withheld": 0, "surface": surface, "send": send ? "detected" : "none"]
        if send { unit["sendBy"] = "return" }
        if let to { unit["to"] = to }
        ev(at, "keyboard.text_input", app, title, url, text, unit: unit)
        if send { ev(at.addingTimeInterval(0.3), "keyboard.submit", app, title, url) }
    }
    mutating func switchTo(_ app: String, _ title: String, _ url: String = "") {
        ev(adv(uniform(0.5, 2)), "app.activated", app, title, url); ev(adv(0.2), "window.changed", app, title, url)
    }
    mutating func clicks(_ app: String, _ title: String, _ url: String, _ n: Int, _ lo: Double = 3, _ hi: Double = 14) {
        for _ in 0..<max(0, n) { ev(adv(uniform(lo, hi)), "mouse.click", app, title, url) }
    }
    mutating func read(_ lo: Double = 35, _ hi: Double = 120) { _ = adv(uniform(lo, hi)) }
    mutating func pick<T>(_ list: [T]) -> T { list[min(list.count - 1, Int(rng.next() * Double(list.count)))] }
    mutating func block(until end: Date) {
        let chats = ["Export view memory fix", "Show HN launch checklist", "Pricing for yearly plan", "Actor deadlock in writer", "Launch post intro"]
        while t < end {
            let r = rng.next()
            if r < 0.32 {
                let title = pick(chats); switchTo("ChatGPT", "ChatGPT"); clicks("ChatGPT", "ChatGPT", "", 1)
                let stop = t.addingTimeInterval(uniform(4, 14) * 60); var first = true
                while t < stop {
                    typed(adv(uniform(15, 45)), "ChatGPT", first ? "ChatGPT" : title, "how do I stop the export view from loading every row", "ai", to: "ChatGPT")
                    if first { ev(adv(3), "window.changed", "ChatGPT", title); first = false }
                    read(30, 110); clicks("ChatGPT", title, "", int(0, 3))
                    if rng.next() < 0.3 { read(30, 90) }
                }
            } else if r < 0.47 {
                let title = pick(["#eng", "#launch", "Riley", "Sam"]) + " - Tallybird - Slack"; switchTo("Slack", title)
                let stop = t.addingTimeInterval(uniform(1, 5) * 60)
                while t < stop {
                    clicks("Slack", title, "", int(1, 4), 2, 10)
                    if rng.next() < 0.6 { typed(adv(uniform(10, 40)), "Slack", title, "sounds good, pushing the fix after lunch", "chat", to: "Sam") }
                    if rng.next() < 0.4 { read(30, 70) }
                }
            } else if r < 0.65 {
                let page = pick([("Weekly summaries export · Pull Request #418 · tallybird/app", "https://github.com"), ("Inbox (14) - Gmail", "https://mail.google.com"),
                                 ("FileHandle | Apple Developer Documentation", "https://developer.apple.com"), ("Hacker News", "https://news.ycombinator.com")])
                switchTo("Google Chrome", page.0, page.1)
                let stop = t.addingTimeInterval(uniform(2, 9) * 60)
                while t < stop { clicks("Google Chrome", page.0, page.1, int(1, 5), 3, 12); if rng.next() < 0.5 { read(30, 100) } }
            } else if r < 0.85 {
                let title = pick(["ExportView.swift", "SyncQueue.swift", "ExportTests.swift"]) + " — Tallybird"; switchTo("Xcode", title)
                let stop = t.addingTimeInterval(uniform(5, 18) * 60)
                while t < stop {
                    clicks("Xcode", title, "", int(2, 6), 2, 9)
                    if rng.next() < 0.5 { typed(adv(uniform(20, 60)), "Xcode", title, "for chunk in rows.chunked(500) { try handle.write(chunk.csv) }", "code", send: false) }
                    if rng.next() < 0.35 { read(30, 80) }
                }
            } else if r < 0.93 {
                let who = pick(["Riley", "Sam"]); switchTo("Messages", who); clicks("Messages", who, "", int(1, 2))
                typed(adv(uniform(8, 25)), "Messages", who, "running 10 min late, save me a seat", "text", to: who)
            } else {
                switchTo("Terminal", "tallybird — zsh")
                let stop = t.addingTimeInterval(uniform(2, 5) * 60)
                while t < stop { typed(adv(uniform(10, 30)), "Terminal", "tallybird — zsh", "swift test --filter ExportTests", "code"); read(20, 60) }
            }
        }
    }
    static func make(day: Int, seed: UInt64) -> [[String: Any]] {
        var d = BusyDay(day: day, seed: seed)
        let day0 = d.t
        d.block(until: day0.addingTimeInterval(3.5 * 3600))
        d.t = max(d.t, day0.addingTimeInterval(4.25 * 3600))
        d.block(until: day0.addingTimeInterval(9 * 3600))
        return d.rows.sorted { ($0["at"] as! String) < ($1["at"] as! String) }
    }
}



actor InstantModel: LocalInference {
    var answers = 0
    func load() async throws {}
    func unload() async {}
    func generate(instruction: String, evidence: String, maxTokens: Int) async throws -> Data {
        try await generate(instruction: instruction, evidence: evidence, maxTokens: maxTokens, prefill: "")
    }
    func generate(instruction: String, evidence: String, maxTokens: Int, prefill: String) async throws -> Data {
        answers += 1
        return Data(#"{"title":"","bullets":[]}"#.utf8)
    }
}
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } }
}

@main struct WriterQuietChecks {
    static var passed = 0, failed = 0
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") {
        if ok { passed += 1; print("PASS " + label) } else { failed += 1; print("FAIL " + label + (detail.isEmpty ? "" : " — " + detail)) }
    }
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        let base = ProcessInfo.processInfo.environment["CADENCE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let root = base.appendingPathComponent("writer-quiet-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        do { try await checks(root: root) } catch { print("FAIL writer-quiet: \(error)"); failed += 1 }
        print("writer-quiet: \(passed) passed, \(failed) failed")
        if failed > 0 { try? FileManager.default.removeItem(at: root); exit(1) }
    }

    @MainActor static func checks(root: URL) async throws {
        let today = BusyDay.make(day: 20, seed: 11)
        let history = BusyDay.make(day: 17, seed: 24) + BusyDay.make(day: 18, seed: 25) + BusyDay.make(day: 19, seed: 26)
        let nine = ISO8601DateFormatter().date(from: "2026-09-20T16:00:00Z")!
        let todayKey = "2026-09-20"
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        let decode = { (row: [String: Any]) throws -> Evidence in try JSONDecoder().decode(Evidence.self, from: JSONSerialization.data(withJSONObject: row)) }
        let noon = nine.addingTimeInterval(3 * 3600), late = nine.addingTimeInterval(8 * 3600)
        var ingested = 0
        func record(_ rows: [[String: Any]], through end: Date, after start: Date = .distantPast) throws {
            for row in rows { let e = try decode(row); guard let at = timestamp(e.at), at > start, at <= end else { continue }; _ = try store.ingest(e, now: at.addingTimeInterval(0.5)); ingested += 1 }
        }
        try record(history + today, through: noon)
        let clock = Box(noon), lastKey = Box(Date.distantPast), quiet = Box(0.0)
        let model = InstantModel()
        let suite = "writer-quiet-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func environment(app: Bool) -> WriterEnvironment {
            var env = WriterEnvironment()
            env.now = { clock.value }
            env.power = { .ac }
            env.idleSeconds = { 3600 }
            env.typingSeconds = { max(0, clock.value.timeIntervalSince(lastKey.value)) }
            env.timezone = { zone }
            env.defaults = defaults
            env.makeRuntime = { _ in model }
            env.unloadSleep = { _ in try await Task.sleep(nanoseconds: 1_000_000_000_000_000) }
            env.postDone = {}
            env.automatic = false
            if app {
                // As `WriterEnvironment.app`, with the launch quiet played by `quiet` (the real one reads the process clock).
                env.pastDayNotes = false
                env.workPriority = .utility
                let typing = env.typingSeconds
                env.quietFor = { max(quiet.value, WriterIntegration.typingBurst - max(0, typing())) }
            }
            return env
        }
        let files = CompatibleWriterFiles(model: home.appendingPathComponent("fake.model"), library: home.appendingPathComponent("fake.dylib"))
        var admission = LocalAdmission(restoreOffline: { _, _ in files }, checkWithApple: {}, signedBuild: { false })
        admission.download = { _, _ in files }
        func writer(app: Bool) async throws -> WriterIntegration {
            let w = WriterIntegration(modelRoot: home.appendingPathComponent("Models"), keyStore: NoKeys(), send: { _ in throw URLError(.notConnectedToInternet) },
                                      admission: admission, environment: environment(app: app))
            w.offerLocal = true
            w.configure(store: store)
            for _ in 0..<500 where w.busy { try await Task.sleep(nanoseconds: 10_000_000) }
            if case .on = w.phase {} else { w.chooseLocal() }
            for _ in 0..<500 { if case .on = w.phase { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            guard case .on(.local) = w.phase else { throw MemError.invalid("writer did not turn on: \(w.phase) \(w.status)") }
            return w
        }
        print("fixture: \(ingested) rows recorded (3 past days, today to 12:00)")

        // Q2. Control: the checks' environment catches up past days and leaves the rest queued.
        let control = try await writer(app: false)
        var controlDays: [String: Int] = [:]
        control.onNoteRun = { item in controlDays[item.day, default: 0] += 1 }
        await control.pass(.lock)
        for _ in 0..<3 { clock.value = clock.value.addingTimeInterval(31 * 60); await control.pass(.timer) }
        let controlPast = controlDays.filter { $0.key != todayKey }.values.reduce(0, +)
        let controlPending = control.pendingCount
        check(controlPast > 0, "Q2 control: catch-up writes past days' moments", "\(controlDays)")
        let controlQueued = control.queue?.writing.count ?? 0
        print("control: notes by day \(controlDays.sorted { $0.key < $1.key }), queued after \(controlQueued), pending \(controlPending)")
        await control.shutdown()

        // More of today is recorded (12:00-17:00): moments the next look has to write.
        try record(today, through: late, after: noon)
        clock.value = late.addingTimeInterval(20 * 60)

        // Q1. The app's environment while DayDream opens: the look writes nothing and looks again once quiet.
        let app = try await writer(app: true)
        var appDays: [String: Int] = [:]
        app.onNoteRun = { item in appDays[item.day, default: 0] += 1 }
        quiet.value = 7
        let q0 = app.counters
        await app.pass(.lock)
        let q1 = app.counters
        check(q1.noteRuns == q0.noteRuns && q1.sourceReads == q0.sourceReads && q1.quietDeferrals == q0.quietDeferrals + 1,
              "Q1: while DayDream opens a look writes and reads nothing", "runs \(q0.noteRuns)->\(q1.noteRuns) deferrals \(q0.quietDeferrals)->\(q1.quietDeferrals)")
        let wake = app.nextWake.map { $0.timeIntervalSince(clock.value) } ?? -1
        check(wake >= 7 && wake <= 8.5, "Q1: and looks again once the launch quiet ends", String(format: "next look in %.1f s", wake))
        // Typing: keys in the last 3 s hold it the same way.
        quiet.value = 0; lastKey.value = clock.value.addingTimeInterval(-1)
        await app.pass(.timer)
        let q2 = app.counters
        let typingWake = app.nextWake.map { $0.timeIntervalSince(clock.value) } ?? -1
        check(q2.noteRuns == q1.noteRuns && q2.quietDeferrals == q1.quietDeferrals + 1 && typingWake > 1.5 && typingWake <= 3,
              "Q1: keys typed a second ago hold the look too, until 3 s after the last key", String(format: "runs %d->%d, next look in %.1f s", q1.noteRuns, q2.noteRuns, typingWake))

        // Q3. Quiet: the past days' queued entries are dropped and only today's moments are written.
        lastKey.value = .distantPast
        await app.pass(.lock)
        for _ in 0..<2 { clock.value = clock.value.addingTimeInterval(31 * 60); await app.pass(.timer) }
        let appPast = appDays.filter { $0.key != todayKey }.values.reduce(0, +)
        check((appDays[todayKey] ?? 0) > 0, "Q3: the app's writer writes today's moments", "\(appDays)")
        check(appPast == 0, "Q3: and no past day's moment (no catch-up, queued past entries never run)", "\(appDays)")
        check(controlQueued == 0 || app.counters.pastSetAside > 0, "Q3: the past days' entries the control left queued are dropped",
              "control queued \(controlQueued), dropped \(app.counters.pastSetAside)")
        check(app.pendingCount <= controlPending, "Q3: the writer's pending count does not grow with past days",
              "control \(controlPending) -> app \(app.pendingCount)")
        print("app: notes by day \(appDays.sorted { $0.key < $1.key }), past entries dropped \(app.counters.pastSetAside), pending \(app.pendingCount) (control \(controlPending))")

        // Q4. A batch stops between notes once a key is typed, and looks again when quiet.
        try record(today, through: late.addingTimeInterval(3600), after: late)
        clock.value = clock.value.addingTimeInterval(3600)
        let before4 = app.counters.noteRuns
        app.onNoteRun = { item in
            appDays[item.day, default: 0] += 1
            lastKey.value = clock.value   // the person starts typing as the first note is written
        }
        await app.pass(.lock)
        let ran4 = app.counters.noteRuns - before4
        let wake4 = app.nextWake.map { $0.timeIntervalSince(clock.value) } ?? -1
        print(String(format: "Q4: %d note(s) ran before typing stopped the batch; next look in %.1f s", ran4, wake4))
        check(ran4 == 1, "Q4: a batch stops after the note it is writing once the person types", "\(ran4) notes ran")
        check(wake4 > 0 && wake4 <= 4, "Q4: and the writer looks again once typing is quiet", String(format: "next look in %.1f s", wake4))
        app.onNoteRun = nil
        await app.shutdown()

        // Q5. The app's own environment and the launch quiet.
        let live = WriterEnvironment.app
        check(live.workPriority == .utility && !live.pastDayNotes, "Q5: the app's writer runs at utility priority and writes today only")
        let start = LaunchTrace.processStart
        check(abs(LaunchQuiet.remaining(now: start.addingTimeInterval(5)) - (LaunchQuiet.cap - 5)) < 0.01,
              "Q5: before Today shows, the launch quiet lasts up to a minute after the process started")
        let shown = Date()
        LaunchQuiet.todayShown(at: shown)
        let left = LaunchQuiet.remaining(now: shown.addingTimeInterval(4))
        check(abs(left - min(6, max(0, start.addingTimeInterval(LaunchQuiet.cap).timeIntervalSince(shown.addingTimeInterval(4))))) < 0.01,
              "Q5: once Today shows, it ends 10 s later", String(format: "%.2f s left 4 s after Today showed", left))
        check(LaunchQuiet.remaining(now: shown.addingTimeInterval(11)) == 0, "Q5: and is over 11 s after Today showed")
    }
}
