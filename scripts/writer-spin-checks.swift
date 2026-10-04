import Foundation
import AppKit
@testable import MemoryCore
@testable import WriterBackend

/// fix/perf7: the writer's pass never spins the main thread while another run holds the writer.
/// (Written with fix/perf7; fitted to build/7's fix, 172423c "a pass that finds the writer held returns".)
/// Before: `pass` looped `while let current=next { rerun=nil; await tick(...); next=rerun }`, and `tick`'s busy guard
/// (an AI app's on-demand batch, Summarize Now or a mode switch holding the writer) set `rerun` and returned WITHOUT
/// suspending, so the scheduled timer's `pass(.timer)` (or a power/lock wake during a model check) spun the main actor
/// at 100% forever: the app froze and the batch that held the writer could never resume. REAL WriterIntegration, a
/// fake model that holds its answer until released, a simulated clock, a SYNTHETIC busy day. No model, no network,
/// no Keychain, no real history.
///   A. the screen locks (every moment closes) and the batch starts writing; the timer set by the pass before fires
///      mid-batch: that pass returns at once (a watchdog thread fails the check after 5 s)
///   B. the look it deferred runs once the batch ends (the writer is not left without its timer)
///   D. a battery-percent change is not a power change the writer looks again for; the source, Low Power Mode, the
///      thermal state and the battery crossing 20% are; background writing runs on battery too, and waits in Low Power
///      Mode, under 20% and while hot (fix/battery-summaries)
///   E. the timer firing while an AI app's on-demand batch holds the writer: it stops at once and the writer looks
///      again within a minute
///   C. printed: the main-thread cost of a pass with nothing to write, on the busy day (every power-source change)
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


/// Holds each answer until `release()`; counts calls.
actor GatedModel: LocalInference {
    let clock: SimClock
    var loads = 0, answers = 0, held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false
    init(clock: SimClock) { self.clock = clock }
    func load() async throws { loads += 1 }
    func unload() async {}
    func generate(instruction: String, evidence: String, maxTokens: Int) async throws -> Data {
        try await generate(instruction: instruction, evidence: evidence, maxTokens: maxTokens, prefill: "")
    }
    func generate(instruction: String, evidence: String, maxTokens: Int, prefill: String) async throws -> Data {
        answers += 1
                return Data(#"{"title":"","bullets":[]}"#.utf8)
    }
    func release() { open = true; let w = waiters; waiters = []; for c in w { c.resume() } }
    func isHeld() -> Bool { held }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    var value: Bool { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } }
}

@main struct WriterSpinChecks {
    static var passed = 0, failed = 0
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") {
        if ok { passed += 1; print("PASS " + label) } else { failed += 1; print("FAIL " + label + (detail.isEmpty ? "" : " — " + detail)) }
    }
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        let base = ProcessInfo.processInfo.environment["CADENCE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let root = base.appendingPathComponent("writer-spin-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        do { try await checks(root: root) } catch { print("FAIL writer-spin: \(error)"); failed += 1 }
        print("writer-spin: \(passed) passed, \(failed) failed")
        if failed > 0 { try? FileManager.default.removeItem(at: root); exit(1) }
    }
    static func cpu() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u); return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6 }

    @MainActor static func checks(root: URL) async throws {
        let rows = BusyDay.make(day: 20, seed: 11)
        let history = BusyDay.make(day: 17, seed: 24) + BusyDay.make(day: 18, seed: 25) + BusyDay.make(day: 19, seed: 26)
        let nine = ISO8601DateFormatter().date(from: "2026-09-20T16:00:00Z")!
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        var consent = try store.policy(); consent.captureText = true; consent.typedConsentVersion = 1; try store.updatePolicy(consent)
        try store.attachVault(TypedTextVault(keyStore: InMemoryTypedKeyStore())); try store.setUpTypedVault(); try store.acceptSafeTyping()
        var typed = try store.typedTextPolicy()
        typed.retention = .days30
        typed.categories = TypedCategoryChoices(searchAndAI: true, writing: true, code: true, messagesAndEmail: true, otherWebsites: true)
        typed.shareWithSummaries = .localOnly
        _ = try store.updateTypedTextPolicy(typed, confirmed: true)
        let decode = { (row: [String: Any]) throws -> Evidence in try JSONDecoder().decode(Evidence.self, from: JSONSerialization.data(withJSONObject: row)) }
        // The day up to 15:00 (and three days before it), all recorded; the clock at 15:00.
        let now = nine.addingTimeInterval(6 * 3600)
        var ingested = 0
        for row in history + rows { let e = try decode(row); guard let at = timestamp(e.at), at <= now else { continue }; _ = try store.ingest(e, now: at.addingTimeInterval(0.5)); ingested += 1 }
        let clock = SimClock(now), world = SimWorld()
        world.power = .ac; world.lastInput = now
        let model = GatedModel(clock: clock)
        let suite = "writer-spin-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var env = WriterEnvironment()
        env.now = { clock.now }
        env.power = { world.power }
        env.idleSeconds = { max(0, clock.now.timeIntervalSince(world.lastInput)) }
        env.timezone = { zone }
        env.defaults = defaults
        env.makeRuntime = { _ in model }
        env.unloadSleep = { _ in try await Task.sleep(nanoseconds: 1_000_000_000_000_000) }
        env.postDone = { world.done += 1 }
        env.automatic = false
        let files = CompatibleWriterFiles(model: home.appendingPathComponent("fake.model"), library: home.appendingPathComponent("fake.dylib"))
        var admission = LocalAdmission(restoreOffline: { _, _ in files }, checkWithApple: {}, signedBuild: { false })
        admission.download = { _, _ in files }
        let writer = WriterIntegration(modelRoot: home.appendingPathComponent("Models"), keyStore: NoKeys(), send: { _ in throw URLError(.notConnectedToInternet) },
                                       admission: admission, environment: env)
        writer.offerLocal = true
        writer.configure(store: store)
        for _ in 0..<500 where writer.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        writer.chooseLocal()
        for _ in 0..<500 { if case .on = writer.phase { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        guard case .on(.local) = writer.phase else { throw MemError.invalid("writer did not turn on: \(writer.phase) \(writer.status)") }
        print("fixture: \(ingested) rows recorded")

        // A. The screen locks: every moment closes and one batch writes them. After its first note, while the batch still
        // holds the writer, the timer the pass before set fires (as the app's timer Task does: `pass(.timer)`).
        let returned = Flag(), started = Flag()
        var timerMs = -1.0, timerCPU = 0.0
        let before = writer.counters
        writer.onNoteRun = { _ in
            guard !started.value else { return }
            started.value = true
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                guard !returned.value else { return }
                print("FAIL A: a timer pass during a batch spun the main thread for 5 s (it never returned; the app would hang)")
                print("writer-spin: \(passed) passed, \(failed + 1) failed")
                exit(1)
            }
            Task { @MainActor in
                let c0 = cpu(), t0 = CFAbsoluteTimeGetCurrent()
                await writer.pass(.timer)
                timerMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000; timerCPU = (cpu() - c0) * 1000
                returned.value = true
            }
        }
        await writer.pass(.lock)
        for _ in 0..<500 where !returned.value { try await Task.sleep(nanoseconds: 10_000_000) }
        writer.onNoteRun = nil
        let after = writer.counters
        check(started.value && after.noteRuns >= before.noteRuns + 2, "fixture: the lock's batch wrote notes", "runs \(before.noteRuns) -> \(after.noteRuns)")
        check(returned.value && timerMs < 1000, "A: a timer pass while a batch holds the writer returns at once", String(format: "%.0f ms", timerMs))
        print(String(format: "PERF A: the timer pass during the batch took %.2f ms wall", timerMs))
        // B. The look the timer asked for is not lost: the batch's pass looked again and set the next wake-up.
        check(writer.nextWake != nil, "B: after the batch the writer has its next wake-up")

        // E. An AI app asks (on demand) and the timer fires while its batch holds the writer: that pass returns at once
        // (172423c: a pass refused by a hold that isn't a pass stops, and the timer looks again within a minute).
        let beforeE = writer.counters
        let demand = Task { @MainActor in await writer.onDemand() }
        let timerE = Task { @MainActor in await writer.pass(.timer) }
        await timerE.value
        let during = writer.counters
        await demand.value
        let afterE = writer.counters
        check(afterE.onDemandSkipped == beforeE.onDemandSkipped, "fixture: the AI app's request was taken (not skipped)", "\(afterE)")
        check(during.heldPasses == beforeE.heldPasses + 1, "E: the timer's pass during the AI app's batch finds the writer held and stops",
              "held passes \(beforeE.heldPasses) -> \(during.heldPasses)")
        check(writer.nextWake.map { $0 <= clock.now.addingTimeInterval(60) } == true, "E: and the writer looks again within a minute",
              "next wake \(writer.nextWake.map { "\($0.timeIntervalSince(clock.now)) s" } ?? "none")")

        // C. A pass with nothing new to write (what each power-source change used to cost), on AC and on battery.
        for (label, power) in [("AC", ModelPower.ac), ("battery", ModelPower.battery)] {
            world.power = power
            await writer.pass(.power)
            var times: [Double] = []
            for _ in 0..<10 { let t = CFAbsoluteTimeGetCurrent(); await writer.pass(.power); times.append((CFAbsoluteTimeGetCurrent() - t) * 1000) }
            times.sort()
            print(String(format: "PERF C: a power pass with nothing new (%@): median %.1f ms, max %.1f ms wall", label, times[times.count / 2], times.last!))
        }
        await writer.shutdown()

        // D. What a power notification must change before the writer looks again (IOPS calls on every percent).
        var b80 = ModelPower.battery; b80.battery = 80
        var b79 = b80; b79.battery = 79
        var b19 = b80; b19.battery = 19
        var low = b80; low.lowPowerMode = true
        var hot = b80; hot.thermal = 2
        check(b80.decision == b79.decision, "D: 80% -> 79% on battery is not a change the writer looks again for")
        check(b80.decision != b19.decision && b80.decision != low.decision && b80.decision != hot.decision && b80.decision != ModelPower.ac.decision,
              "D: plugging in, Low Power Mode, heat and the battery crossing 20% are")
        check(b19.decision.allowsOnDemand == b19.allowsOnDemand && b80.decision.allowsOnDemand == b80.allowsOnDemand && low.decision.allowsBackground == low.allowsBackground
              && b19.decision.allowsBackground == b19.allowsBackground && b80.decision.allowsBackground == b80.allowsBackground && hot.decision.allowsBackground == hot.allowsBackground,
              "D: the bucketed power allows exactly what the real one does")
        // fix/battery-summaries (owner 9/28): background writing on battery too, unless Low Power Mode, under 20% or hot.
        var b20 = b80; b20.battery = 20
        var acLow = ModelPower.ac; acLow.lowPowerMode = true
        var acHot = ModelPower.ac; acHot.thermal = 2
        var warm = b80; warm.thermal = 1
        check(ModelPower.ac.allowsBackground && b80.allowsBackground && b20.allowsBackground && warm.allowsBackground,
              "D: background writing on power, and on battery at 80% and 20% (warm too)")
        check(!b19.allowsBackground && !low.allowsBackground && !hot.allowsBackground && !acLow.allowsBackground && !acHot.allowsBackground,
              "D: background writing waits under 20%, in Low Power Mode and while hot (on power too)")
    }
}
