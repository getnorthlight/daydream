import Foundation
import AppKit
@testable import MemoryCore
@testable import WriterBackend
import PrivacyPolicy

/// fix/sx-engine-battery: how often the summary writer runs the model, measured on the REAL WriterIntegration (its
/// scheduling, WriterQueueSource, PendingNoteScheduler, CoreWriterBinding/Adapter, CanonicalLocalWriter, BatchRuntime,
/// LevelWriterBinding/LevelRunner) with a fake model that counts loads and answers, on a simulated clock, over a
/// SYNTHETIC busy day (made-up person, apps and messages). No model, no network, no Keychain, no real history.
///
///   writer-cadence-checks                       asserts the cadence acceptance on a generated day (the runner step)
///   writer-cadence-checks --sim <scenario> <busy.json> <out.json> [history.json]
///                                               one scenario on a recorded synthetic day (sx-engine-battery/sim)
/// Scenarios: ac, battery (80%), battery-low (15% until plugged in at 19:00), mcp (battery, an AI app asking 12 times an
/// hour), mcp-ac (the same on power), lowpower (the same in Low Power Mode), catchup-ac and catchup-battery (three earlier
/// days recorded before an update, then the day).
///
/// test-p2 cadence-shard: every day simulation is an independent shard (`Shard.all`). The runner step re-executes this
/// binary once per shard (`--shard <name> <dir>`), CADENCE_SHARDS at a time (default min(cores/2, 6)), and prints each
/// shard's output and the checks over its result in the same fixed order as the serial run. CADENCE_SHARDS=1 is the
/// serial run in this process, as before. A shard that crashes, exits without a result or runs past
/// CADENCE_SHARD_TIMEOUT seconds (default 1500) is a named FAIL line and the run exits 1.
///   CADENCE_ONLY=ac,owner-day     only those shards and the checks that need nothing else (CADENCE_ONLY_AC, _MCPAC and
///                                 _REJOIN are the old names for ac, mcp-ac and rejoin+forget)
///   CADENCE_SHARD_INJECT=<name>   one more shard, read last and always a child: selftest-crash, selftest-hang or an
///                                 unknown name each make the run print "FAIL writer-cadence shard <name>: ..." and exit 1
///                                 (with CADENCE_SHARD_TIMEOUT=5 for the hang). `shardRunnerChecks` runs the same three
///                                 on every run and prints PASS lines for them.
///   CADENCE_SHARD_TIMES=<file>    appends "<shard> <wall seconds>" for each shard read (`Shard.launchOrder` is the
///                                 longest first, from these)
/// owner-day also sends the app's `sourceChanged()` as rows land, so the writer's source discovery (the second site
/// 9eaa6f4 fixed) runs at its own debounce and read spacing on the simulated clock (`SourceGate`) and the oracle proves
/// any wake it arms (`CadenceEvidence.rearm`). scripts/mutations.d/cadence-shard.tsv puts 9eaa6f4's code back.
/// owner-day (owner bug 10, 9eaa6f4): the owner's real workday with a screen lock, a lid-close sleep, plugging in, a
/// quit and reopen and three quick looks back at something already written, on the shipped writer (no model for moments,
/// the model writes the day review's clauses).
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
    private var _lastTyping = Date.distantPast
    var power: ModelPower { get { lock.lock(); defer { lock.unlock() }; return _power } set { lock.lock(); _power = newValue; lock.unlock() } }
    var lastInput: Date { get { lock.lock(); defer { lock.unlock() }; return _lastInput } set { lock.lock(); _lastInput = newValue; lock.unlock() } }
    var lastTyping: Date { get { lock.lock(); defer { lock.unlock() }; return _lastTyping } set { lock.lock(); _lastTyping = newValue; lock.unlock() } }
    var done = 0
}

/// Counts every load and answer. An answer takes 5 simulated seconds and a load 4 (as sx-diag-energy's sim2: a note
/// run of two answers is 10 s). The answer is an empty note, which the checks refuse, so each moment takes the repair
/// turn and ends with the code note. Ordinary closed moments wait for growth/revision;
/// mandatory local live refresh and provisional finalization still run at their deadlines.
actor FakeModel: LocalInference {
    let clock: SimClock
    var loads: [Date] = [], answers: [Date] = []
    var loaded = false
    /// claude/int-016: answer a day-review clause request with a valid clause (`{"clause":""}`, which the clause rules
    /// call a good answer) instead of a note-shaped answer every clause check refuses (two answers, then the clause is
    /// asked again an hour later). Only the shipped scenario sets it; every other scenario keeps the old answers.
    let validClauses: Bool
    init(clock: SimClock, validClauses: Bool = false) { self.clock = clock; self.validClauses = validClauses }
    func load() async throws { loads.append(clock.now); loaded = true; clock.advance(4) }
    func unload() async { loaded = false }
    func generate(instruction: String, evidence: String, maxTokens: Int) async throws -> Data {
        try await generate(instruction: instruction, evidence: evidence, maxTokens: maxTokens, prefill: "")
    }
    func generate(instruction: String, evidence: String, maxTokens: Int, prefill: String) async throws -> Data {
        answers.append(clock.now); clock.advance(5)
        if validClauses, instruction == DayReviewClauses.activeInstruction, prefill == DayReviewClauses.prefill { return Data(#"{"clause":""}"#.utf8) }
        return Data(#"{"title":"","bullets":[]}"#.utf8)
    }
    func snapshot() -> (loads: [Date], answers: [Date]) { (loads, answers) }
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
    // The ChatGPT desktop app as the release's typing table lists it (com.openai.codex); "com.openai.chat" is on no list,
    // so its typed rows never reached the store and the sim's asks never needed the model.
    static let bundles = ["ChatGPT": "com.openai.codex", "Xcode": "com.apple.dt.Xcode", "Messages": "com.apple.MobileSMS",
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
    /// `block`, stopping at `end` exactly: what it made after `end` is dropped (the person stopped there).
    mutating func blockCut(until end: Date) {
        let kept = rows.count, cut = Self.iso(end)
        block(until: end)
        rows = Array(rows[..<kept]) + rows[kept...].filter { ($0["at"] as! String) < cut }
        t = end
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

/// fix/sx-all round 3: a short synthetic morning: a pull request read for about 10 minutes (a code note), Xcode for about
/// 8, then back on the pull request for 3 clicks (the moment rejoins, growing well under a quarter), then nothing.
enum RejoinDay {
    static func make(start: Date) -> [[String: Any]] {
        var d = BusyDay(day: 21, seed: 7)
        d.t = start
        let pr = ("Resume interrupted uploads by sam · Pull Request #911 · tallybird/harborline", "https://github.com")
        d.switchTo("Google Chrome", pr.0, pr.1); d.clicks("Google Chrome", pr.0, pr.1, 40, 10, 20)
        d.switchTo("Xcode", "Uploader.swift — Harborline"); d.clicks("Xcode", "Uploader.swift — Harborline", "", 32, 10, 20)
        d.switchTo("Google Chrome", pr.0, pr.1); d.clicks("Google Chrome", pr.0, pr.1, 3, 5, 10)
        return d.rows.sorted { ($0["at"] as! String) < ($1["at"] as! String) }
    }
}

/// test-p2 cadence-shard, owner bug 10 (the summaries writer didn't wake on schedule; 9eaa6f4): the owner's real workday,
/// made up (seeded) like `BusyDay`: on battery (80%) from 09:00; a message to Riley typed and left unsent, then the screen
/// locked for a coffee (10:31-10:52); back, the same draft finished and sent; the lid closed for lunch (12:15-13:20);
/// plugged in at 14:05; DayDream quit and opened again mid-afternoon (15:40-15:44); work until 18:00. Nothing is recorded
/// while the screen is locked, the Mac sleeps or DayDream is quit, so those stretches have no rows.
/// Three times in the afternoon, on power, the owner looks back at something a few minutes after leaving it (Jordan's
/// reply, answered; the pull request's checks; the chat's answer): the moment already has its note, grows again for half
/// a minute and closes again, so it is due a rewrite 15 minutes after its note (9eaa6f4: an ordinary wake, never a
/// one-second one). Their titles are the owner's own (no busy-day block uses them), so nothing else joins them.
enum OwnerDay {
    static let nine = ISO8601DateFormatter().date(from: "2026-09-22T16:00:00Z")!
    static func at(_ hour: Int, _ minute: Int) -> Date { nine.addingTimeInterval(Double((hour - 9) * 3600 + minute * 60)) }
    static let lock = (at(10, 31), at(10, 52)), sleep = (at(12, 15), at(13, 20)), plugIn = at(14, 5), quit = (at(15, 40), at(15, 44))
    static let glanceNames = ["Jordan's reply", "the pull request's checks", "the chat's answer"]
    /// Away in Xcode for seven minutes (the moment left closes and gets its note), then back for a few clicks (and a
    /// short reply when `reply` is set), then away again.
    static func glance(_ d: inout BusyDay, _ app: String, _ title: String, _ url: String = "", reply: String? = nil, to: String? = nil) -> Date {
        let left = d.t, file = "WriterWake.swift — Tallybird"
        d.switchTo("Xcode", file)
        while d.t < left.addingTimeInterval(420) { d.clicks("Xcode", file, "", 1, 12, 24) }
        d.switchTo(app, title, url); let back = d.t
        d.clicks(app, title, url, 3, 3, 8)
        if let reply { d.typed(d.adv(12), app, title, reply, "text", url: url, to: to) }
        d.switchTo("Xcode", file); d.clicks("Xcode", file, "", 6, 12, 24)
        return back
    }
    static func plan() -> (rows: [[String: Any]], glances: [Date]) {
        var d = BusyDay(day: 22, seed: 31)
        var glances: [Date] = []
        d.blockCut(until: at(10, 29))
        // A text started and left unsent (no submit), then the screen locked.
        d.switchTo("Messages", "Riley"); d.clicks("Messages", "Riley", "", 1)
        d.typed(d.adv(14), "Messages", "Riley", "can we move the export review to", "text", to: "Riley", send: false)
        d.t = max(d.t, lock.1.addingTimeInterval(20))
        // Back after unlocking: the same draft, finished and sent, then the morning's work again.
        d.switchTo("Messages", "Riley")
        d.typed(d.adv(18), "Messages", "Riley", "can we move the export review to 3? still chasing the memory fix", "text", to: "Riley")
        d.blockCut(until: sleep.0.addingTimeInterval(-60))
        d.t = max(d.t, sleep.1.addingTimeInterval(25))
        // After lunch: back on the same pull request first.
        let pr = ("Weekly summaries export · Pull Request #418 · tallybird/app", "https://github.com")
        d.switchTo("Google Chrome", pr.0, pr.1); d.clicks("Google Chrome", pr.0, pr.1, 6, 5, 15)
        d.blockCut(until: plugIn.addingTimeInterval(120))
        // Plugged in: a text to Jordan, and a look back at the reply seven minutes later, answered.
        d.switchTo("Messages", "Jordan"); d.clicks("Messages", "Jordan", "", 1)
        d.typed(d.adv(16), "Messages", "Jordan", "is the 4pm design review still on?", "text", to: "Jordan")
        glances.append(glance(&d, "Messages", "Jordan", reply: "great, see you then", to: "Jordan"))
        // A pull request read, and a look back at its checks.
        let checks = ("Space the writer's wakes · Pull Request #431 · tallybird/app", "https://github.com")
        d.switchTo("Google Chrome", checks.0, checks.1); d.clicks("Google Chrome", checks.0, checks.1, 6, 5, 15)
        glances.append(glance(&d, "Google Chrome", checks.0, checks.1))
        d.blockCut(until: quit.0.addingTimeInterval(-30))
        d.t = max(d.t, quit.1.addingTimeInterval(30))
        // Reopened: a question in a chat, and a look back at its answer.
        let chat = "Writer wake after relaunch"
        d.switchTo("ChatGPT", chat); d.clicks("ChatGPT", chat, "", 1)
        d.typed(d.adv(25), "ChatGPT", chat, "why does the writer's pass wait on the store actor after a relaunch", "ai", to: "ChatGPT")
        d.clicks("ChatGPT", chat, "", 3, 8, 20)
        glances.append(glance(&d, "ChatGPT", chat))
        d.blockCut(until: at(18, 0))
        return (d.rows.sorted { ($0["at"] as! String) < ($1["at"] as! String) }, glances)
    }
    static func make() -> [[String: Any]] { plan().rows }
    static func scenario() -> Scenario {
        var s = Scenario(name: "owner-day", power: { $0 < plugIn ? .battery : .ac }, start: nine.addingTimeInterval(-60), end: nine.addingTimeInterval(12 * 3600))
        s.momentModel = false; s.validClauses = true; s.collectErrors = true; s.sourceSignals = true
        s.locks = [lock]; s.sleeps = [sleep]; s.quits = [quit]
        // What the checks read: today's moments still waiting for a note 15 minutes after each event.
        s.probes = [lock.1, sleep.1, plugIn, quit.1].map { $0.addingTimeInterval(900) }
        return s
    }
}

struct Scenario {
    var name: String
    var power: (Date) -> ModelPower
    var mcp: [Date] = []
    var start: Date, end: Date
    /// fix/sx-all round 3: things the person does to the store mid-day (Forget a range), at their times.
    var hooks: [(at: Date, run: (MemoryStore, Date) throws -> Void)] = []
    /// claude/notesfix-015: false is the shipped app (`WriterEnvironment.app`: no model writes a moment or level note).
    var momentModel = true
    /// claude/int-016: the fake model writes valid day-review clauses (`FakeModel.validClauses`).
    var validClauses = false
    /// test-p2 cadence-shard (owner bug 10): the screen locked and unlocked, the lid closed and opened, DayDream quit and
    /// opened again, each (start, end). A lock and a sleep reach the writer as the app sends them (`pass(.lock)`,
    /// `pass(.sleep)`, `pass(.wake)`; an unlock sends nothing); no timer fires while the Mac sleeps; a quit shuts the
    /// writer down and the reopen is a new WriterIntegration over the same store, ledger and preferences.
    var locks: [(Date, Date)] = [], sleeps: [(Date, Date)] = [], quits: [(Date, Date)] = []
    /// Times at which the run records today's moments still waiting for a note (`Result.probes`).
    var probes: [Date] = []
    /// Keep the oracle's findings in the result (with their times) instead of throwing at the end.
    var collectErrors = false
    /// The app's own signal after rows land (`sourceChanged()`, MacMemApp's historyAdded): the writer's source discovery
    /// runs at its debounce and read spacing on the simulated clock (`SourceGate`), and may arm a service wake by itself.
    var sourceSignals = false
}
/// test-p2 cadence-shard: the writer's source-discovery sleep (`WriterEnvironment.sourceChangeSleep`) on the simulated
/// clock. The discovery task waits here until the driver reaches `due` and lets it go (`release`), so a discovery runs at
/// its time and never beside a pass.
final class SourceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Void, Error>?
    private var dueAt: Date?
    var due: Date? { lock.lock(); defer { lock.unlock() }; return dueAt }
    func sleep(until date: Date) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock(); waiting = c; dueAt = date; lock.unlock()
            }
        } onCancel: { self.end(throwing: CancellationError()) }
    }
    func release() { end(throwing: nil) }
    func end(throwing error: Error?) {
        lock.lock(); let c = waiting; waiting = nil; dueAt = nil; lock.unlock()
        if let error { c?.resume(throwing: error) } else { c?.resume() }
    }
}
/// test-p2 cadence-shard: what the driver saw, for the owner-day checks.
struct PassEntry: Codable { var at: Date; var reason: String; var nextWake: Date? }
struct ProbeEntry: Codable { var at: Date; var pending: [String]; var pendingEnds: [Date] }
struct ShortWake: Codable { var at: Date; var wake: Date; var oneSecond: Bool; var proved: Bool; var firstNoteWork: Bool; var rewritesOnly: Bool }
struct ErrorEntry: Codable { var at: Date; var text: String }
/// A rewrite of a note written for good: when it ran, the moment (its subject and last action) and when its note was.
struct RewriteEntry: Codable { var at: Date; var subject: String; var end: Date; var markAt: Date }
struct HourRow: Codable { var hour: String; var runs = 0; var ordinaryRuns = 0; var liveRuns = 0; var serviceRuns = 0; var staleTurns = 0; var finalRuns = 0; var mcpRuns = 0; var catchUpRuns = 0; var ordinaryTimerPasses = 0; var loads = 0; var passes = 0; var timerPasses = 0; var onDemand = 0; var catchUp = 0; var modelSeconds = 0.0 }
struct Result: Codable {
    var scenario: String
    var events: Int
    var hours: [HourRow]
    var noteRuns: Int, loads: Int, answers: Int, modelSeconds: Double
    var batches: Int, onDemandBatches: Int, onDemandSkipped: Int, modelLevels: Int, codeLevels: Int, catchUpNotes: Int
    var timerPasses: Int, eventPasses: Int
    var moments: Int, maxRunsPerMoment: Int, rewritesBeyondFirst: Int, dayNoteRuns: Int
    /// Note runs in each catch-up batch, and whether each batch took the newest day first.
    var catchUpBatches: [[String]]
    var loadsPerOnDemandBatch: [Int]
    /// Typed rows offered to `ingest`, and those its typed gate kept.
    var typedRows = 0, typedKept = 0
    /// Apps whose typed rows the gate refused.
    var typedRefusedApps: [String] = []
    /// fix/sx-all round 3: at the end, today's moments still pending that ended over 30 minutes before (a block waits for
    /// them), and the block notes stored for today.
    var pendingClosed: [String] = []
    var blocks = 0
    /// Note runs an AI app's requests made, most for any one moment.
    var maxOnDemandRunsPerMoment = 0
    // All original totals remain measured. Only independently proved mandatory work is separated.
    var ordinaryRewrites = 0, maxNonMandatoryRunsPerMoment = 0
    var maxMCPRunsPerBatch = 0, mcpBatchStarts: [Date] = []
    var liveRuns = 0, serviceRuns = 0, staleTurns = 0, finalRuns = 0, ordinaryRuns = 0, mcpRuns = 0, pastRuns = 0
    var evidenceErrors: [String] = []
    /// test-p2 cadence-shard (owner bug 10): every pass (its reason and the wake it armed), the probes, every wake armed
    /// under the 5-minute spacing of ordinary wakes, the oracle's findings with their times, and today's entries still
    /// in the writer's queue at the end.
    var passLog: [PassEntry] = [], probes: [ProbeEntry] = [], shortWakes: [ShortWake] = [], errorLog: [ErrorEntry] = []
    var endQueued: [String] = []
    var reopened = 0, sourceDiscoveries = 0
    /// Every rewrite of a note written for good, and the looks (source discoveries; the end of a pass) that found a
    /// rewrite due by the rewrite rule and no first-note, live or final work: the wait 9eaa6f4 keeps ordinary.
    var rewriteLog: [RewriteEntry] = [], rewriteWaitLooks: [Date] = [], rewriteWaitsAfterPass: [Date] = []
}

/// Test-only oracle over scratch data. It never calls WriterQueueSource.discoverDay,
/// never acquires the scheduler's lock, and never trusts a product "run reason" label.
/// Literal contract times intentionally make a production cadence change require review.
@MainActor final class CadenceEvidence {
    enum Role: Equatable { case ordinary, live, service, final, mcp, catchUp }
    struct Ledger: Decodable {
        let version: Int; let written: [String: WrittenMark]; let entries: [ScheduledWriterState]
        enum CodingKeys: String, CodingKey { case version, written, entries }
        init(version: Int, written: [String: WrittenMark], entries: [ScheduledWriterState]) {
            self.version=version;self.written=written;self.entries=entries
        }
        init(from decoder: Decoder) throws {
            let values=try decoder.container(keyedBy:CodingKeys.self)
            version=try values.decode(Int.self,forKey:.version)
            entries=try values.decode([ScheduledWriterState].self,forKey:.entries)
            // Version1 omits the optional dictionary before its first written mark.
            written=try values.decodeIfPresent([String:WrittenMark].self,forKey:.written) ?? [:]
        }
    }
    struct Fact {
        let item: ScheduledWriterTarget, activity: ActivityNote
        let start: Date, end: Date, closeAt: Date, closed: Bool, nonempty: Bool, newTyped: Bool
        let mark: WrittenMark?
        /// The moment showed a current note when the operation began.
        var ready: Bool { activity.status == "ready" }
        var liveDue: Date { max(start.addingTimeInterval(600), mark?.at.addingTimeInterval(600) ?? start.addingTimeInterval(600)) }
        var liveEligible: Bool { !closed && nonempty && activity.actionIDs.count <= 400 }
        var finalEligible: Bool { closed && nonempty && activity.actionIDs.count <= 400 && mark?.provisional == true }
        /// 03beb17 first-note service: an open moment with no current note is due a provisional note three minutes after
        /// its last action (five-minute service deadline less two minutes of generation reserve), before it closes.
        var serviceDue: Date { end.addingTimeInterval(180) }
        var serviceEligible: Bool { !closed && nonempty && !ready }
    }
    struct View { let at: Date; let facts: [String: Fact]; let ledger: Ledger }
    struct Run {
        let item: ScheduledWriterTarget, role: Role, started: Date, ended: Date, fact: Fact
    }
    /// 03beb17's first-note service queues an OPEN moment. When a hold (power, the load budget) keeps its batch from
    /// running and the person carries on in the moment, the queued entry is at a revision core no longer has, and the
    /// pass does not route the moment again until it is due again. At its turn the writer finds the entry stale
    /// (`WriterQueueSource.isCurrent`), runs nothing and drops it; `onNoteRun` still reports the turn. Not an attempt:
    /// `staleErrors` and `staleAfterErrors` prove nothing ran and nothing was written.
    struct StaleTurn {
        let item: ScheduledWriterTarget, started: Date, ended: Date, fact: Fact
    }
    struct Armed {
        let at: Date, armedAt: Date
        let shortDeadline: Bool
        // Proof remains valid if later ingests postpone closure before the timer fires.
        let keys: Set<String>
    }
    let store: MemoryStore, days: [String], today: String
    /// Each action's kind, read from the store the first time `snapshot` saw the action, while the store's action read
    /// epoch stays `kindsEpoch`. A Forget, a privacy change or anything else that can make an action unavailable moves
    /// the epoch, and the next snapshot reads every action again: the oracle's "unavailable action" check (a moment still
    /// listing a forgotten action) holds after it as it did before the cache.
    var kinds: [String: String] = [:], kindsEpoch: String?
    var view: View?, activeMCP = false, nextAttempt = Date.distantPast
    var runs: [Run] = [], pending: [Run] = []
    /// Each finding, and (test-p2 cadence-shard) the time of the operation that found it (`errorTimes`).
    var errors: [String] = [] { didSet { while errorTimes.count < errors.count { errorTimes.append(view?.at ?? .distantPast) } } }
    var errorTimes: [Date] = []
    /// test-p2 cadence-shard (owner bug 10): the writer's own close (`closedBy`: the last lock or sleep, gone with a
    /// relaunch), mirrored, and every wake armed under the 5-minute spacing of ordinary wakes.
    var closedBy: Date?
    var shortWakes: [ShortWake] = []
    /// Rewrites run, and the looks that found only a rewrite due (`rewritesDue`, `dueNow`): source discoveries and ends
    /// of passes.
    var rewriteLog: [RewriteEntry] = [], rewriteWaitLooks: [Date] = [], rewriteWaitsAfterPass: [Date] = []
    var staleTurns: [StaleTurn] = [], pendingStale: [StaleTurn] = []
    var ordinaryRewrites = 0, nonMandatory: [String: Int] = [:]
    var mcpBatchSizes: [Int] = [], mcpBatchStarts: [Date] = []
    var ordinaryTimers: [Date] = [], lastTimer = Date.distantPast, armed: Armed?
    var closing: Date?, servedRequired = 0
    init(store: MemoryStore, days: [String], today: String) { self.store=store;self.days=days;self.today=today }
    func ledger() throws -> Ledger {
        let value=try JSONDecoder().decode(Ledger.self,from:Data(contentsOf:store.home.appendingPathComponent("WriterScheduling/pending-v1.json")))
        guard value.version==1 else { throw MemError.invalid("cadence oracle: unknown ledger version") }
        return value
    }
    func snapshot(at: Date, closing: Date?) throws -> View {
        let ledger=try ledger(), policy=try store.policy().revision
        let epoch=try store.actionReadEpoch()
        if epoch != kindsEpoch { kinds=[:];kindsEpoch=epoch }
        var facts: [String: Fact]=[:]
        for day in days {
            let layers=try store.dayLayers(day:day,timezone:zone,now:at)
            guard !layers.partial else { throw MemError.invalid("cadence oracle: partial canonical day") }
            let ends=try layers.activities.map { activity -> Date in
                guard let end=timestamp(activity.end) else { throw MemError.invalid("cadence oracle: bad end") };return end
            }
            let latest=ends.max()
            // test-p2 cadence-shard: an action's kind is read from the store once, the first time the oracle sees the
            // action (it must exist then, as every read here checked before), and kept until the store's action read
            // epoch moves (`kindsEpoch`: a Forget or a privacy change); then every action is read, and checked, again.
            // One store read per action per operation was most of a catch-up day's time.
            func kind(_ id: String) throws -> String {
                if let known=kinds[id] { return known }
                guard let read=try store.action(id,now:at) else { throw MemError.invalid("cadence oracle: unavailable action \(id)") }
                kinds[id]=read.kind
                return read.kind
            }
            for activity in layers.activities {
                guard let start=timestamp(activity.start),let end=timestamp(activity.end) else { throw MemError.invalid("cadence oracle: bad timestamps") }
                let closeAt=end.addingTimeInterval((latest.map {$0>end} ?? false) ? 120 : 600)
                let closed=day != today || at>=closeAt || (closing.map {$0>=end} ?? false)
                let item=ScheduledWriterTarget(target:WriterTarget(kind:.activity,day:day,timezone:zone,activityID:activity.id),inputRevision:activity.inputRevision,policyRevision:policy,lastActivity:end)
                let actions=try activity.actionIDs.map { (id: $0, kind: try kind($0)) }
                guard let bundles=activity.bundles else { throw MemError.invalid("cadence oracle: unknown bundle metadata") }
                let admitted=activity.apps.contains {!$0.isEmpty} || activity.sites.contains {!$0.isEmpty} || bundles.contains {!$0.isEmpty}
                let hasApp = !bundles.isEmpty || activity.apps.contains {!$0.isEmpty}
                let nonempty=admitted && hasApp && (actions.count>64 || actions.contains {!["idle","session.started","session.ended"].contains($0.kind)})
                let mark=ledger.written[item.key]
                let known=(activity.previous ?? activity.generated).map { Set($0.actionIDs) }
                let addedIDs=known.map { ids in activity.actionIDs.filter {!ids.contains($0)} }
                    ?? Array(activity.actionIDs.dropFirst(mark?.actions ?? activity.actionIDs.count))
                let added=Set(addedIDs)
                let newTyped=(mark.map { activity.actionIDs.count>$0.actions } ?? false) && actions.contains { added.contains($0.id) && ["keyboard.text_input","keyboard.submit"].contains($0.kind) }
                facts[item.key]=Fact(item:item,activity:activity,start:start,end:end,closeAt:closeAt,closed:closed,nonempty:nonempty,newTyped:newTyped,mark:mark)
            }
        }
        return View(at:at,facts:facts,ledger:ledger)
    }
    func begin(at: Date, idle: TimeInterval, mcp: Bool, timer: Bool) throws {
        // The writer closes what ended before its last lock or sleep (`closedBy`, test-p2 cadence-shard: only the
        // owner-day driver sends them), and, outside an AI app's request, what ended before 5 idle minutes.
        closing = closedBy
        if !mcp && idle>=300 { closing=max(closing ?? .distantPast,at.addingTimeInterval(-idle+1)) }
        view=try snapshot(at:at,closing:closing);activeMCP=mcp;nextAttempt=at;pending=[];pendingStale=[];servedRequired=0
        if timer {
            errors+=Self.timerErrors(armed:armed,at:at,lastTimer:lastTimer)
            if armed?.shortDeadline != true { ordinaryTimers.append(at) }
            lastTimer=at
        }
    }
    static func timerErrors(armed: Armed?, at: Date, lastTimer: Date) -> [String] {
        guard let armed,armed.at<=at,armed.armedAt<=at else { return ["timer has no matching prior armed evidence at \(at)"] }
        if !armed.shortDeadline && at.timeIntervalSince(lastTimer)<300 { return ["ordinary timer violates explicit 300-second spacing at \(at)"] }
        if armed.shortDeadline && armed.keys.isEmpty { return ["short timer has no proved deadline key at \(at)"] }
        return []
    }
    static func role(_ item: ScheduledWriterTarget, view: View, mcp: Bool, today: String) -> Role? {
        guard let fact=view.facts[item.key],fact.item==item else { return nil }
        if mcp { return .mcp }
        if item.day != today { return .catchUp }
        if fact.liveEligible && fact.liveDue<=view.at { return .live }
        if fact.serviceEligible && fact.serviceDue<=view.at { return .service }
        if fact.finalEligible { return .final }
        return .ordinary
    }
    func note(_ item: ScheduledWriterTarget, at: Date) {
        guard let view,let fact=view.facts[item.key] else { errors.append("unknown run facts for \(item.key)");return }
        if fact.item != item {
            let turn=StaleTurn(item:item,started:nextAttempt,ended:at,fact:fact)
            errors+=Self.staleErrors(turn,view:view,mcp:activeMCP,today:today,seen:staleTurns)
            nextAttempt=at;pendingStale.append(turn);staleTurns.append(turn)
            return
        }
        guard let role=Self.role(item,view:view,mcp:activeMCP,today:today) else { errors.append("unknown/stale run facts for \(item.key)");return }
        if role == .live || role == .final { servedRequired+=1 }
        if pending.contains(where:{$0.item.key==item.key}) { errors.append("duplicate run in one operation: \(item.key)") }
        if role == .ordinary {
            if !fact.closed || !fact.nonempty { errors.append("ordinary run is open/empty: \(item.key)") }
            if runs.contains(where:{$0.item.key==item.key}) { ordinaryRewrites+=1 }
            if let mark=fact.mark,!mark.provisional {
                rewriteLog.append(RewriteEntry(at:at,subject:fact.activity.subject,end:fact.end,markAt:mark.at))
                if view.at.timeIntervalSince(mark.at)<900 { errors.append("ordinary rewrite before 15-minute cooldown: \(item.key)") }
                let parts=mark.revision?.components(separatedBy:"|") ?? []
                if parts.count != 3 { errors.append("unknown prior revision: \(item.key)") }
                let added=fact.activity.actionIDs.count-mark.actions
                let grew=added>0 && Double(fact.activity.actionIDs.count)>=Double(mark.actions)*1.25
                let longer=added>=3 && fact.end>=(mark.end ?? mark.at).addingTimeInterval(180)
                let changed=parts.count==3 && (parts[1] != item.policyRevision || parts[2] != "local" || (added<=0 && parts[0] != item.inputRevision))
                let writes=mark.writes ?? (mark.skipped ? 0 : 1)
                if !changed && !fact.newTyped && !((grew || longer) && writes<3) { errors.append("ordinary rewrite lacks growth, new typed evidence, or revision change: \(item.key)") }
            }
        }
        if role == .ordinary || role == .service || role == .mcp { nonMandatory[item.key,default:0]+=1 }
        let run=Run(item:item,role:role,started:nextAttempt,ended:at,fact:fact)
        // Only FakeModel.load/generate advance this clock during a driver operation.
        // beginBatch and all scheduler/core work leave it unchanged between note callbacks.
        nextAttempt=at;pending.append(run);runs.append(run)
    }
    /// A stale turn, judged from what was true when the operation began.
    static func staleErrors(_ turn: StaleTurn, view: View, mcp: Bool, today: String, seen: [StaleTurn]) -> [String] {
        var errors: [String]=[]
        let key=turn.item.key,fact=turn.fact
        // The same moment at another revision: it changed after the entry was queued.
        if fact.item.key != key || (fact.item.inputRevision==turn.item.inputRevision && fact.item.policyRevision==turn.item.policyRevision) { errors.append("stale turn at the moment's current revision: \(key)") }
        // Queued before this operation began, at exactly that revision (never chosen and gone stale within it).
        if !view.ledger.entries.contains(where:{ $0.item==turn.item && ($0.status == .queued || $0.status == .retry) }) { errors.append("stale turn was not queued before the operation: \(key)") }
        // Only today's open moment that this pass does not route again keeps such an entry: a closed moment, or one due
        // live or first-note work, is queued again at its current revision, which replaces the entry.
        if mcp || turn.item.day != today || fact.closed || (fact.liveEligible && fact.liveDue<=view.at) || (fact.serviceEligible && fact.serviceDue<=view.at) {
            errors.append("stale turn for a moment the operation routes at its current revision: \(key)")
        }
        // Only FakeModel.load/generate advance the clock: the turn took no time, so no model ran for it.
        if turn.ended != turn.started { errors.append("stale turn used the model: \(key)") }
        if seen.contains(where:{ $0.item==turn.item }) { errors.append("stale entry had more than one turn: \(key)") }
        return errors
    }
    /// And from the ledger afterwards: the entry is gone and the moment's written mark is as it was.
    static func staleAfterErrors(_ turn: StaleTurn, before: Ledger, after: Ledger) -> [String] {
        var errors: [String]=[]
        let key=turn.item.key
        if after.entries.contains(where:{ $0.item==turn.item }) { errors.append("stale entry was not dropped: \(key)") }
        if after.written[key] != before.written[key] { errors.append("stale turn changed the written mark: \(key)") }
        return errors
    }
    static func postErrors(_ run: Run, mark: WrittenMark?) -> [String] {
        var errors: [String]=[]
        guard let mark else { return ["attempt produced no written mark: \(run.item.key)"] }
        let revision=[run.item.inputRevision,run.item.policyRevision,"local"].joined(separator:"|")
        if mark.revision != revision || mark.actions != run.fact.activity.actionIDs.count || mark.end != run.fact.end {
            errors.append("post-mark revision/coverage mismatch: \(run.item.key)")
        }
        if mark.writerRevision != WriterQueueSource.writerRevision || mark.at<run.started || mark.at>run.ended { errors.append("unknown writer/timestamp: \(run.item.key)") }
        switch run.role {
        case .live:
            if !mark.provisional || mark.at != run.started || run.started<run.fact.liveDue { errors.append("invalid live cadence mark: \(run.item.key)") }
        case .service:
            if !mark.provisional || run.started<run.fact.serviceDue { errors.append("invalid first-note service mark: \(run.item.key)") }
        case .final:
            if mark.provisional { errors.append("closure did not finalize provisional mark: \(run.item.key)") }
        case .ordinary,.catchUp:
            if mark.provisional { errors.append("closed ordinary/catch-up mark remains provisional: \(run.item.key)") }
        case .mcp:
            if mark.provisional == run.fact.closed { errors.append("MCP provisional state mismatches closure: \(run.item.key)") }
        }
        return errors
    }
    static func arm(current: View, before view: View, nextWake: Date, lastTimer: Date, servedRequired: Int, ran: Int = 0, background: Bool, today: String, discovered: Set<String> = []) -> (Armed,[String]) {
        let at=current.at
        var errors: [String]=[]
        let floor=max(lastTimer.addingTimeInterval(300),view.at.addingTimeInterval(1))
        var keys=Set<String>()
        if background && nextWake<floor {
            // Independent future candidates are computed before another ingest can change them.
            let candidates=current.facts.values.filter {$0.item.day==today && ($0.liveEligible || $0.serviceEligible)}.flatMap { fact -> [(Date,String)] in
                var values: [(Date,String)]=[]
                if fact.liveEligible && fact.liveDue>at { values.append((fact.liveDue,fact.item.key)) }
                if fact.liveEligible && fact.mark?.provisional==true && fact.closeAt>at { values.append((fact.closeAt,fact.item.key)) }
                if fact.serviceEligible && fact.serviceDue>at { values.append((fact.serviceDue,fact.item.key)) }
                return values
            }
            let first=candidates.map(\.0).min()
            if first==nextWake { keys.formUnion(candidates.filter {$0.0==nextWake}.map(\.1)) }
            // A one-second continuation needs proof: either a deadline crossed during finite
            // fake inference, or due live backlog after a full 12-note mandatory batch. A due
            // key that was already due before an unfilled batch never gets a retry exemption.
            if nextWake==at.addingTimeInterval(1) {
                let due=Set(current.facts.values.filter {$0.item.day==today && $0.liveEligible && $0.liveDue<=at}.map { $0.item.key })
                let newlyDue=Set(view.facts.values.filter {$0.item.day==today && $0.liveEligible && $0.liveDue>view.at && $0.liveDue<=at}.map {$0.item.key})
                keys.formUnion(due.intersection(newlyDue))
                // 03beb17: first-note service that became due while fake inference ran (an open moment passing its
                // three-minute mark, or a moment with no current note closing) continues on the next second.
                let serviceNewly=current.facts.values.filter { fact in
                    guard fact.item.day==today,fact.nonempty,!fact.ready,let before=view.facts[fact.item.key],!before.closed else { return false }
                    return fact.closed || (fact.serviceEligible && fact.serviceDue<=at && before.serviceDue>view.at)
                }
                keys.formUnion(serviceNewly.map { $0.item.key })
                // test-p2 cadence-shard: a one-second wake armed by source discovery (between passes) for work due now.
                keys.formUnion(discovered)
                // A full 12-note batch with first-note work still due (a backlog released by power) continues too.
                if ran==12 {
                    keys.formUnion(current.facts.values.filter {$0.item.day==today && $0.nonempty && !$0.ready &&
                        ($0.closed || ($0.serviceEligible && $0.serviceDue<=at))}.map { $0.item.key })
                }
                if servedRequired==12 {
                    let queued=Set(current.ledger.entries.filter {
                        ($0.status == .queued || $0.status == .retry) && $0.nextAttempt<=at && current.facts[$0.item.key]?.item==$0.item
                    }.map {$0.item.key})
                    keys.formUnion(due.intersection(queued))
                }
            }
        }
        if nextWake<floor && keys.isEmpty { errors.append("unproved deadline below ordinary floor: \(nextWake)") }
        return (Armed(at:nextWake,armedAt:at,shortDeadline:nextWake<floor && !keys.isEmpty,keys:keys),errors)
    }
    func finish(at: Date, nextWake: Date?, background: Bool, mcpBatch: Bool) throws {
        let after=try ledger()
        for run in pending { errors+=Self.postErrors(run,mark:after.written[run.item.key]) }
        guard let view else { throw MemError.invalid("cadence oracle: finish without begin") }
        for turn in pendingStale { errors+=Self.staleAfterErrors(turn,before:view.ledger,after:after) }
        if !activeMCP && background {
            let required=Set(view.facts.values.filter {$0.item.day==today && (($0.liveEligible && $0.liveDue<=view.at) || $0.finalEligible)}.map {$0.item.key})
            let served=Set(pending.filter {$0.role == .live || $0.role == .final}.map {$0.item.key})
            if required.count<=12 && served != required { errors.append("due mandatory work missed: \(required.subtracting(served).sorted())") }
            if required.count>12 && served.count != 12 { errors.append("mandatory backlog did not fill bounded 12-note batch") }
        }
        if activeMCP {
            if mcpBatch { mcpBatchSizes.append(pending.count);mcpBatchStarts.append(view.at) }
            else if !pending.isEmpty { errors.append("MCP runs without an accounted on-demand batch") }
            // onDemand does not rearm the timer. Preserve its original arming proof.
            return
        }
        guard let nextWake else { armed=nil;return }
        let current=try snapshot(at:at,closing:closing)
        let proof=Self.arm(current:current,before:view,nextWake:nextWake,lastTimer:lastTimer,servedRequired:servedRequired,ran:pending.count,background:background,today:today)
        armed=proof.0;errors+=proof.1
        if !rewritesDue(current,at:at).isEmpty && dueNow(current,at:at).isEmpty { rewriteWaitsAfterPass.append(at) }
        logShortWake(current:current,from:view.at,at:at,nextWake:nextWake,proved:proof.1.isEmpty)
    }
    /// test-p2 cadence-shard (owner bug 10): today's closed moments whose note, written for good, is due again now by the
    /// rewrite rule as `note` judges an ordinary rewrite (grew by a quarter, or by 3 actions and 3 minutes; new typed rows;
    /// another revision), 15 minutes after that note. Ordinary work: never what a one-second wake is for (9eaa6f4).
    func rewritesDue(_ current: View, at: Date) -> Set<String> {
        Set(current.facts.values.filter { fact in
            guard fact.item.day==today,fact.closed,fact.nonempty,!fact.ready,let mark=fact.mark,!mark.provisional,
                  at.timeIntervalSince(mark.at)>=900 else { return false }
            let parts=mark.revision?.components(separatedBy:"|") ?? []
            let added=fact.activity.actionIDs.count-mark.actions
            let grew=added>0 && Double(fact.activity.actionIDs.count)>=Double(mark.actions)*1.25
            let longer=added>=3 && fact.end>=(mark.end ?? mark.at).addingTimeInterval(180)
            let changed=parts.count==3 && (parts[1] != fact.item.policyRevision || parts[2] != "local" || (added<=0 && parts[0] != fact.item.inputRevision))
            let writes=mark.writes ?? (mark.skipped ? 0 : 1)
            return changed || fact.newTyped || ((grew || longer) && writes<3)
        }.map { $0.item.key })
    }
    /// test-p2 cadence-shard (owner bug 10): today's moments with work due now that a one-second wake may serve: first-note
    /// work (an open moment past its three-minute mark, or a closed one, with no note yet or only a provisional one) and
    /// live or final work. Never a rewrite of a note written for good.
    func dueNow(_ current: View, at: Date) -> Set<String> {
        Set(current.facts.values.filter { fact in
            guard fact.item.day==today else { return false }
            let firstNote=fact.nonempty && !fact.ready && (fact.mark.map { $0.provisional } ?? true) && (fact.closed || (fact.serviceEligible && fact.serviceDue<=at))
            return firstNote || (fact.liveEligible && fact.liveDue<=at) || fact.finalEligible
        }.map { $0.item.key })
    }
    /// A wake under the 5-minute spacing of ordinary wakes (the one-second wake among them), what was due when it was
    /// armed, and whether the oracle proved it.
    func logShortWake(current: View, from: Date, at: Date, nextWake: Date, proved: Bool) {
        guard nextWake<max(lastTimer.addingTimeInterval(300),from.addingTimeInterval(1)) else { return }
        let firstNote = !dueNow(current,at:at).isEmpty
        let rewrites=current.facts.values.contains { $0.item.day==today && $0.nonempty && !$0.ready && $0.closed && $0.mark.map { !$0.provisional } == true }
        let oneSecond=nextWake<=at.addingTimeInterval(1)
        shortWakes.append(ShortWake(at:at,wake:nextWake,oneSecond:oneSecond,proved:proved,firstNoteWork:firstNote,rewritesOnly:oneSecond && rewrites && !firstNote))
    }
    /// test-p2 cadence-shard: the writer's source discovery ran between passes and may have armed another wake. Its
    /// proof: a deadline the facts show (as after a pass), or, for a one-second wake, work due now (`dueNow`).
    func rearm(at: Date, idle: TimeInterval, nextWake: Date?, background: Bool) throws {
        var closing=closedBy
        if idle>=300 { closing=max(closing ?? .distantPast,at.addingTimeInterval(-idle+1)) }
        let current=try snapshot(at:at,closing:closing)
        if !rewritesDue(current,at:at).isEmpty && dueNow(current,at:at).isEmpty { rewriteWaitLooks.append(at) }
        guard let nextWake else { armed=nil;return }
        if let armed,armed.at==nextWake { return }
        view=current
        let proof=Self.arm(current:current,before:current,nextWake:nextWake,lastTimer:lastTimer,servedRequired:0,background:background,today:today,discovered:dueNow(current,at:at))
        armed=proof.0;errors+=proof.1
        logShortWake(current:current,from:at,at:at,nextWake:nextWake,proved:proof.1.isEmpty)
    }
}

/// The counters of a writer and the one before it (a quit and reopen), as the totals read them.
func add(_ a: WriterIntegration.Counters, _ b: WriterIntegration.Counters) -> WriterIntegration.Counters {
    var c = b
    c.timerPasses += a.timerPasses; c.eventPasses += a.eventPasses; c.batches += a.batches; c.onDemandBatches += a.onDemandBatches
    c.onDemandSkipped += a.onDemandSkipped; c.noteRuns += a.noteRuns; c.modelLevels += a.modelLevels; c.codeLevels += a.codeLevels
    c.catchUpNotes += a.catchUpNotes
    return c
}

@MainActor
func run(_ scenario: Scenario, day rows: [[String: Any]], history: [[String: Any]], root: URL) async throws -> Result {
    let home = root.appendingPathComponent(scenario.name)
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    // fix/sx-all round 2: typing is turned on the way the app does it (`MemoryStore.turnOnTyping`: this build's consent
    // scope, the key, every category), and each typed row goes through `ingest`'s own typed gate; the sim counts what it
    // kept, so a sim whose typed rows were silently refused (nothing for the model) can't pass the battery bounds.
    try store.attachVault(TypedTextVault(keyStore: InMemoryTypedKeyStore()))
    let consentAt = ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z")!
    try store.turnOnTyping(now: consentAt)
    // Then the typing switch through the app's own preference path (`TypingModel.saveSwitch`).
    _ = try store.savePreferences(MemoryPreferences(blockedApps: [], nativeTyping: true), expectedRevision: try store.policy().revision)
    var typed = try store.typedTextPolicy()
    typed.retention = .days30
    typed.shareWithSummaries = .localOnly
    _ = try store.updateTypedTextPolicy(typed, confirmed: true, now: consentAt)
    var typedRows = 0, typedKept = 0, refusedApps = Set<String>()
    func put(_ e: Evidence, now: Date) throws {
        let kept = try store.ingest(e, now: now)
        if e.kind == "keyboard.text_input" { typedRows += 1; if kept { typedKept += 1 } else { refusedApps.insert(e.bundle) } }
    }
    let decode = { (row: [String: Any]) throws -> Evidence in try JSONDecoder().decode(Evidence.self, from: JSONSerialization.data(withJSONObject: row)) }
    for row in history { let e = try decode(row); try put(e, now: timestamp(e.at)!.addingTimeInterval(0.5)) }
    let events = try rows.map(decode).sorted { $0.at < $1.at }

    let clock = SimClock(scenario.start), world = SimWorld()
    world.power = scenario.power(scenario.start)
    let model = FakeModel(clock: clock, validClauses: scenario.validClauses)
    let suite = "writer-cadence-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName:suite) }
    var env = WriterEnvironment()
    env.now = { clock.now }
    env.power = { world.power }
    env.idleSeconds = { max(0, clock.now.timeIntervalSince(world.lastInput)) }
    env.typingSeconds = { max(0, clock.now.timeIntervalSince(world.lastTyping)) }
    env.timezone = { zone }
    env.defaults = defaults
    env.makeRuntime = { _ in model }
    env.momentModel = scenario.momentModel
    env.unloadSleep = { _ in try await Task.sleep(nanoseconds: 1_000_000_000_000_000) }
    env.postDone = { world.done += 1 }
    env.automatic = false
    let gate = SourceGate()
    if scenario.sourceSignals { env.sourceChangeSleep = { seconds in try await gate.sleep(until: clock.now.addingTimeInterval(seconds)) } }
    let files = CompatibleWriterFiles(model: home.appendingPathComponent("fake.model"), library: home.appendingPathComponent("fake.dylib"))
    var admission = LocalAdmission(restoreOffline: { _, _ in files }, checkWithApple: {}, signedBuild: { false })
    admission.download = { _, _ in files }
    let modelRoot = home.appendingPathComponent("Models")
    let makeWriter = {
        let made = WriterIntegration(modelRoot: modelRoot, keyStore: NoKeys(), send: { _ in throw URLError(.notConnectedToInternet) },
                                     admission: admission, environment: env)
        made.offerLocal = true
        return made
    }
    var writer = makeWriter()
    var passTimes: [(Date, Bool)] = [], onDemandTimes: [Date] = [], loadsPerOnDemand: [Int] = []
    var runsByMoment: [String: Int] = [:], dayNoteRuns = 0
    var onDemandRuns: [String: Int] = [:], inOnDemand = false
    var runTimes: [Date] = []
    var catchUpBatches: [[String]] = [], currentCatchUp: [String]? = nil
    let today = try DayScope.key(scenario.start.addingTimeInterval(12 * 3600), timezone: zone)
    let evidenceDays=Set(try history.map { row -> String in
        guard let text=row["at"] as? String,let date=timestamp(text) else { throw MemError.invalid("cadence oracle: bad history timestamp") }
        return try DayScope.key(date,timezone:zone)
    }).union([today]).sorted()
    let evidence=CadenceEvidence(store:store,days:evidenceDays,today:today)
    // Ordinary cold-load exhaustion is independently exercised by summary-ux-scheduling's
    // backlog fixture; these acceptance totals still include every mandatory cold load.
    let showRuns = ProcessInfo.processInfo.environment["CADENCE_RUNS"] != nil
    let onNoteRun = { (item: ScheduledWriterTarget) in
        evidence.note(item,at:clock.now)
        runTimes.append(clock.now)
        if showRuns, let m = try? store.dayLayers(day: item.day, timezone: zone, now: clock.now).activities.first(where: { $0.id == item.activityID }) {
            let kinds = Dictionary(grouping: m.actionIDs.compactMap { try? store.action($0)?.kind }, by: { $0 }).mapValues(\.count)
            print("    run \(BusyDay.iso(clock.now)) \(item.activityID!.suffix(8)) \(m.subject.prefix(30)) n=\(m.actionIDs.count) \(m.start.suffix(14))-\(m.end.suffix(14)) \(kinds)")
        }
        if item.kind != "activity" { dayNoteRuns += 1 }
        runsByMoment[item.key, default: 0] += 1
        if inOnDemand { onDemandRuns[item.key, default: 0] += 1 }
        if item.day != today { currentCatchUp?.append(item.day) }
    }
    writer.onNoteRun = onNoteRun
    writer.configure(store: store)
    for _ in 0..<500 where writer.busy { try await Task.sleep(nanoseconds: 10_000_000) }
    var cursor = 0, landed = 0
    func ingest(until t: Date) throws {
        while cursor < events.count, let at = timestamp(events[cursor].at), at <= t {
            try put(events[cursor], now: at.addingTimeInterval(0.5)); world.lastInput = at
            if ["keyboard.text_input","keyboard.submit"].contains(events[cursor].kind) { world.lastTyping=at }
            cursor += 1; landed += 1
        }
    }
    try ingest(until: scenario.start)
    // Summaries on this Mac turned on (or, after an update, back on) at the start.
    currentCatchUp = []
    writer.chooseLocal()
    for _ in 0..<500 { if case .on = writer.phase { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    guard case .on(.local) = writer.phase else { throw MemError.invalid("writer did not turn on: \(writer.phase) \(writer.status)") }
    // The first pass after turning on (the app's startPolling does this; here the driver runs every pass).
    try evidence.begin(at:clock.now,idle:env.idleSeconds(),mcp:false,timer:false)
    passTimes.append((clock.now, false)); await writer.pass(.explicit)
    try evidence.finish(at:clock.now,nextWake:writer.nextWake,background:world.power.allowsBackground,mcpBatch:false)
    var passLog = [PassEntry(at: evidence.view!.at, reason: "explicit", nextWake: writer.nextWake)]
    if let batch = currentCatchUp, !batch.isEmpty { catchUpBatches.append(batch) }
    var mcp = scenario.mcp.sorted()
    var hooks = scenario.hooks.sorted { $0.at < $1.at }
    var lastPower = world.power
    let powerChanges = stride(from: scenario.start.timeIntervalSince1970, to: scenario.end.timeIntervalSince1970, by: 60).map { Date(timeIntervalSince1970: $0) }
        .filter { scenario.power($0) != scenario.power($0.addingTimeInterval(-60)) }
    var nextPowerChange = powerChanges.makeIterator(), pendingPower = nextPowerChange.next()
    let debug = ProcessInfo.processInfo.environment["CADENCE_DEBUG"] != nil
    // test-p2 cadence-shard (owner bug 10): the Mac's and DayDream's own events, at their times.
    var lifecycle = (scenario.locks.flatMap { [($0.0, "lock"), ($0.1, "unlock")] } + scenario.sleeps.flatMap { [($0.0, "sleep"), ($0.1, "wake")] }
                     + scenario.quits.flatMap { [($0.0, "quit"), ($0.1, "reopen")] } + scenario.probes.map { ($0, "probe") }).sorted { $0.0 < $1.0 }
    var asleep = false, running = true, earlier = WriterIntegration.Counters(), reopened = 0, sourceReads = 0
    var probes: [ProbeEntry] = []
    /// One event pass, as the app sends it, between the oracle's begin and finish.
    func eventPass(_ reason: WakeReason, _ name: String) async throws {
        try evidence.begin(at:clock.now,idle:env.idleSeconds(),mcp:false,timer:false)
        passTimes.append((clock.now, false)); await writer.pass(reason)
        try evidence.finish(at:clock.now,nextWake:writer.nextWake,background:world.power.allowsBackground,mcpBatch:false)
        passLog.append(PassEntry(at: evidence.view!.at, reason: name, nextWake: writer.nextWake))
    }
    while clock.now < scenario.end {
        // No timer fires while the Mac sleeps or DayDream is quit.
        let wake = asleep || !running ? scenario.end : writer.nextWake ?? scenario.end
        if debug { let l = await model.loaded; print("  t=\(BusyDay.iso(clock.now)) wake=\(writer.nextWake.map(BusyDay.iso) ?? "nil") loaded=\(l) loads=\(await model.snapshot().loads.count) runs=\(writer.counters.noteRuns) batches=\(writer.counters.batches)") }
        var next = min(wake, scenario.end)
        if let m = mcp.first { next = min(next, m) }
        if let h = hooks.first { next = min(next, h.at) }
        if let p = pendingPower { next = min(next, p) }
        if let l = lifecycle.first { next = min(next, l.0) }
        if running, let due = gate.due { next = min(next, due) }
        next = max(next, clock.now)
        try ingest(until: next)
        clock.set(next)
        let loadsBefore = await model.snapshot().loads.count
        let catchBefore = writer.counters.catchUpNotes
        currentCatchUp = []
        if running, let due = gate.due, due <= clock.now {
            // The writer's source discovery, at its time: let it go and wait (real time, bounded) for its read.
            let reads = writer.counters.sourceReads
            gate.release()
            for _ in 0..<5000 where writer.counters.sourceReads == reads { try await Task.sleep(nanoseconds: 1_000_000) }
            if writer.counters.sourceReads == reads { evidence.errors.append("source discovery at \(BusyDay.iso(clock.now)) did not read the day") }
            try evidence.rearm(at: clock.now, idle: env.idleSeconds(), nextWake: writer.nextWake, background: world.power.allowsBackground)
            sourceReads += 1
        } else if let l = lifecycle.first, l.0 <= clock.now {
            lifecycle.removeFirst()
            switch l.1 {
            case "lock", "sleep":
                // The app's own close (`pass` sets `closedBy`), mirrored for the oracle.
                evidence.closedBy = clock.now
                try await eventPass(l.1 == "lock" ? .lock : .sleep, l.1)
                if l.1 == "sleep" { asleep = true }
            case "wake":
                asleep = false
                try await eventPass(.wake, "wake")
            case "quit":
                gate.end(throwing: CancellationError())
                await writer.shutdown()
                earlier = add(earlier, writer.counters); running = false; evidence.armed = nil
            case "reopen":
                // A new launch: a new writer over the same store, ledger and preferences. The saved choice turns it back
                // on by itself (`configure`: the offline check of the model already on this Mac), then the app's first look.
                try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
                writer = makeWriter(); writer.onNoteRun = onNoteRun
                writer.configure(store: store)
                for _ in 0..<500 where writer.busy { try await Task.sleep(nanoseconds: 10_000_000) }
                for _ in 0..<500 { if case .on = writer.phase { break }; try await Task.sleep(nanoseconds: 10_000_000) }
                guard case .on(.local) = writer.phase else { throw MemError.invalid("the reopened writer did not turn back on: \(writer.phase) \(writer.status)") }
                running = true; reopened += 1
                evidence.closedBy = nil; evidence.lastTimer = .distantPast; evidence.armed = nil
                try await eventPass(.explicit, "reopen")
            case "probe":
                var closing = evidence.closedBy
                let idle = env.idleSeconds()
                if idle >= 300 { closing = max(closing ?? .distantPast, clock.now.addingTimeInterval(-idle + 1)) }
                let view = try evidence.snapshot(at: clock.now, closing: closing)
                let waiting = view.facts.values.filter { $0.item.day == today && $0.closed && $0.nonempty && !$0.ready }.sorted { $0.end < $1.end }
                probes.append(ProbeEntry(at: clock.now, pending: waiting.map { "\($0.activity.subject) n=\($0.activity.actionIDs.count)" }, pendingEnds: waiting.map(\.end)))
            default: break  // unlock: the app sends the writer nothing
            }
        } else if let h = hooks.first, h.at <= clock.now {
            hooks.removeFirst()
            try h.run(store, clock.now)
            try evidence.begin(at:clock.now,idle:env.idleSeconds(),mcp:false,timer:false)
            passTimes.append((clock.now, false)); await writer.pass(.explicit)
            try evidence.finish(at:clock.now,nextWake:writer.nextWake,background:world.power.allowsBackground,mcpBatch:false)
        } else if let p = pendingPower, p <= clock.now {
            pendingPower = nextPowerChange.next()
            world.power = scenario.power(clock.now)
            if world.power != lastPower && running && !asleep {
                lastPower = world.power
                try await eventPass(.power, "power")
            } else { lastPower = world.power }
        } else if let m = mcp.first, m <= clock.now {
            mcp.removeFirst()
            let before = writer.counters.onDemandBatches
            try evidence.begin(at:clock.now,idle:env.idleSeconds(),mcp:true,timer:false)
            inOnDemand = true
            await writer.onDemand()
            inOnDemand = false
            try evidence.finish(at:clock.now,nextWake:writer.nextWake,background:world.power.allowsBackground,mcpBatch:writer.counters.onDemandBatches>before)
            if writer.counters.onDemandBatches > before {
                onDemandTimes.append(evidence.view!.at)
                loadsPerOnDemand.append(await model.snapshot().loads.count - loadsBefore)
            }
        } else if wake <= clock.now {
            try evidence.begin(at:clock.now,idle:env.idleSeconds(),mcp:false,timer:true)
            passTimes.append((clock.now, true)); await writer.pass(.timer)
            try evidence.finish(at:clock.now,nextWake:writer.nextWake,background:world.power.allowsBackground,mcpBatch:false)
            passLog.append(PassEntry(at: evidence.view!.at, reason: "timer", nextWake: writer.nextWake))
        } else { clock.advance(1) }
        if writer.counters.catchUpNotes > catchBefore, let batch = currentCatchUp, !batch.isEmpty { catchUpBatches.append(batch) }
        try ingest(until: clock.now)
        // The app tells the writer when rows land (historyAdded); the discovery it starts waits on the gate.
        if scenario.sourceSignals && landed > 0 && running && !asleep {
            landed = 0; writer.sourceChanged()
            for _ in 0..<1000 where gate.due == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        }
    }
    let snap = await model.snapshot()
    let modelSeconds = Double(snap.answers.count) * 5 + Double(snap.loads.count) * 4
    let f = DateFormatter(); f.timeZone = TimeZone(identifier: zone); f.dateFormat = "HH"
    var hours: [String: HourRow] = [:]
    func row(_ d: Date) -> String { f.string(from: d) }
    for t in runTimes { hours[row(t), default: HourRow(hour: row(t))].runs += 1 }
    for run in evidence.runs {
        let h=row(run.ended)
        switch run.role {
        case .ordinary: hours[h]!.ordinaryRuns+=1
        case .live: hours[h]!.liveRuns+=1
        case .service: hours[h]!.serviceRuns+=1
        case .final: hours[h]!.finalRuns+=1
        case .mcp: hours[h]!.mcpRuns+=1
        case .catchUp: hours[h]!.catchUpRuns+=1
        }
    }
    for turn in evidence.staleTurns { hours[row(turn.ended)]!.staleTurns+=1 }
    for t in evidence.ordinaryTimers { hours[row(t),default:HourRow(hour:row(t))].ordinaryTimerPasses+=1 }
    for t in snap.loads { hours[row(t), default: HourRow(hour: row(t))].loads += 1; hours[row(t)]!.modelSeconds += 4 }
    for t in snap.answers { hours[row(t), default: HourRow(hour: row(t))].modelSeconds += 5 }
    for (t, timer) in passTimes { hours[row(t), default: HourRow(hour: row(t))].passes += 1; if timer { hours[row(t)]!.timerPasses += 1 } }
    for t in onDemandTimes { hours[row(t), default: HourRow(hour: row(t))].onDemand += 1 }
    let counts = Array(runsByMoment.values)
    let c = add(earlier, writer.counters)
    let endQueued = try evidence.ledger().entries.filter { $0.item.day == today && ![.cancelled, .completed].contains($0.status) }.map(\.item.key).sorted()
    let endLayers = try store.dayLayers(day: today, timezone: zone, now: clock.now)
    let pendingClosed = endLayers.activities.filter { $0.status == "pending" && (timestamp($0.end).map { clock.now.timeIntervalSince($0) > 30 * 60 } ?? false) }
        .map { "\($0.subject) n=\($0.actionIDs.count)" }
    let blockCount = try store.dayLevels(day: today, timezone: zone, now: clock.now).blocks.count
    await writer.shutdown()
    defaults.removePersistentDomain(forName: suite)
    var result = Result(scenario: scenario.name, events: events.count, hours: hours.values.sorted { $0.hour < $1.hour },
                  noteRuns: runTimes.count, loads: snap.loads.count, answers: snap.answers.count, modelSeconds: modelSeconds,
                  batches: c.batches, onDemandBatches: c.onDemandBatches, onDemandSkipped: c.onDemandSkipped, modelLevels: c.modelLevels, codeLevels: c.codeLevels,
                  catchUpNotes: c.catchUpNotes, timerPasses: c.timerPasses, eventPasses: c.eventPasses,
                  moments: counts.count, maxRunsPerMoment: counts.max() ?? 0, rewritesBeyondFirst: counts.reduce(0) { $0 + $1 - 1 }, dayNoteRuns: dayNoteRuns,
                  catchUpBatches: catchUpBatches, loadsPerOnDemandBatch: loadsPerOnDemand, typedRows: typedRows, typedKept: typedKept, typedRefusedApps: refusedApps.sorted(),
                  pendingClosed: pendingClosed, blocks: blockCount, maxOnDemandRunsPerMoment: onDemandRuns.values.max() ?? 0)
    result.ordinaryRewrites=evidence.ordinaryRewrites
    result.maxNonMandatoryRunsPerMoment=evidence.nonMandatory.values.max() ?? 0
    result.maxMCPRunsPerBatch=evidence.mcpBatchSizes.max() ?? 0
    result.mcpBatchStarts=evidence.mcpBatchStarts
    result.ordinaryRuns=hours.values.map(\.ordinaryRuns).reduce(0,+)
    result.liveRuns=hours.values.map(\.liveRuns).reduce(0,+)
    result.serviceRuns=hours.values.map(\.serviceRuns).reduce(0,+)
    result.staleTurns=hours.values.map(\.staleTurns).reduce(0,+)
    result.finalRuns=hours.values.map(\.finalRuns).reduce(0,+)
    result.mcpRuns=hours.values.map(\.mcpRuns).reduce(0,+)
    result.pastRuns=hours.values.map(\.catchUpRuns).reduce(0,+)
    result.evidenceErrors=evidence.errors
    result.passLog=passLog; result.probes=probes; result.shortWakes=evidence.shortWakes; result.endQueued=endQueued; result.reopened=reopened; result.sourceDiscoveries=sourceReads
    result.errorLog=zip(evidence.errorTimes,evidence.errors).map { ErrorEntry(at:$0.0,text:$0.1) }
    result.rewriteLog=evidence.rewriteLog; result.rewriteWaitLooks=evidence.rewriteWaitLooks; result.rewriteWaitsAfterPass=evidence.rewriteWaitsAfterPass
    if result.noteRuns != result.ordinaryRuns+result.liveRuns+result.serviceRuns+result.staleTurns+result.finalRuns+result.mcpRuns+result.pastRuns || result.noteRuns != c.noteRuns { result.evidenceErrors.append("run partition/callbacks do not equal total attempts") }
    if result.pastRuns != c.catchUpNotes || result.mcpBatchStarts.count != c.onDemandBatches { result.evidenceErrors.append("catch-up/MCP accounting mismatch") }
    if !result.evidenceErrors.isEmpty && !scenario.collectErrors { throw MemError.invalid("cadence oracle: " + result.evidenceErrors.joined(separator:"; ")) }
    print("    proved partition ordinary/live/service/final/MCP/catch-up: \(result.ordinaryRuns)/\(result.liveRuns)/\(result.serviceRuns)/\(result.finalRuns)/\(result.mcpRuns)/\(result.pastRuns); ordinary rewrites \(result.ordinaryRewrites); stale turns (nothing ran) \(result.staleTurns)")
    print("  \(scenario.name): runs=\(result.noteRuns) loads=\(result.loads) modelSeconds=\(Int(result.modelSeconds)) batches=\(result.batches) onDemand=\(result.onDemandBatches)/skipped \(result.onDemandSkipped) passes=\(result.timerPasses)+\(result.eventPasses) levels=\(result.modelLevels)/\(result.codeLevels) moments=\(result.moments) maxRuns=\(result.maxRunsPerMoment) catchUp=\(result.catchUpNotes) \(result.catchUpBatches.map(\.count)) typed=\(typedKept)/\(typedRows) refused=\(refusedApps.sorted())")
    print("    hour runs loads passes(timer) onDemand: " + result.hours.map { "\($0.hour):\($0.runs)/\($0.loads)/\($0.passes)(\($0.timerPasses))/\($0.onDemand)" }.joined(separator: " "))
    return result
}

func scenario(_ name: String, day: Date) -> Scenario? {
    // `day` is 09:00 local on the busy day. The run covers 08:59 to 21:00.
    let start = day.addingTimeInterval(-60), end = day.addingTimeInterval(12 * 3600)
    let plugIn = day.addingTimeInterval(10 * 3600)   // 19:00: plugged in after a day on battery
    var lowBattery = ModelPower.battery; lowBattery.battery = 15
    let busy = (0..<(9 * 12)).map { day.addingTimeInterval(Double($0) * 300 + 150) }   // 12 an hour, 09:00-18:00
    switch name {
    case "ac", "catchup-ac": return Scenario(name: name, power: { _ in .ac }, start: start, end: end)
    case "battery", "catchup-battery": return Scenario(name: name, power: { $0 < plugIn ? .battery : .ac }, start: start, end: end)
    case "battery-low": return Scenario(name: name, power: { $0 < plugIn ? lowBattery : .ac }, start: start, end: end)
    case "mcp": return Scenario(name: name, power: { $0 < plugIn ? .battery : .ac }, mcp: busy, start: start, end: end)
    // fix/sx-all round 3: an AI app asking 12 times an hour on power.
    case "mcp-ac": return Scenario(name: name, power: { _ in .ac }, mcp: busy, start: start, end: end)
    case "lowpower":
        var low = ModelPower.battery; low.lowPowerMode = true
        return Scenario(name: name, power: { $0 < plugIn ? low : .ac }, mcp: busy, start: start, end: plugIn)
    default: return nil
    }
}

/// test-p2 cadence-shard: the day simulations by name. Each is independent of the others (its own store, clock, fake model
/// and preferences), so a shard builds its scenario and rows the same way in this process or in a child (`spec`).
enum Shard {
    /// The serial run's order, which is also the order of the output.
    static let all = ["ac", "shipped", "refused", "battery", "battery-low", "mcp", "mcp-ac", "lowpower", "rejoin", "forget",
                      "catchup-battery", "catchup-ac", "owner-day"]
    /// The order the children start in: the longest first (measured on the Mac mini), so the last to start are short.
    static let launchOrder = ["catchup-battery", "catchup-ac", "mcp", "mcp-ac", "owner-day", "ac", "battery", "refused", "shipped",
                              "battery-low", "lowpower", "forget", "rejoin"]
    /// The runner's self-test shards (`CADENCE_SHARD_INJECT`, `shardRunnerChecks`): a crash and a hang.
    static let selfTests = ["selftest-crash", "selftest-hang"]
    static let nine = ISO8601DateFormatter().date(from: "2026-09-20T16:00:00Z")!
    static let rejoinStart = ISO8601DateFormatter().date(from: "2026-09-21T16:00:00Z")!
    static func spec(_ name: String) -> (scenario: Scenario, day: [[String: Any]], history: [[String: Any]])? {
        switch name {
        case "ac", "battery", "battery-low", "mcp", "mcp-ac", "lowpower":
            return (scenario(name, day: nine)!, BusyDay.make(day: 20, seed: 11), [])
        // claude/notesfix-015 (owner 10/05, 0.1.6: no model rewrite of a moment card): the shipped app, where no model
        // writes a moment (`WriterEnvironment.app`, momentModel false). claude/int-016: on the shipped day the model writes
        // only the day review's clauses, so the fake answers them as a model that writes them would ("shipped"); the day
        // where every clause is refused ("refused") is the worst case.
        case "shipped", "refused":
            var s = scenario("ac", day: nine)!; s.momentModel = false; s.validClauses = name == "shipped"
            return (s, BusyDay.make(day: 20, seed: 11), [])
        case "catchup-battery", "catchup-ac":
            let history = BusyDay.make(day: 17, seed: 24) + BusyDay.make(day: 18, seed: 25) + BusyDay.make(day: 19, seed: 26)
            return (scenario(name, day: nine)!, BusyDay.make(day: 20, seed: 11), history)
        case "rejoin":
            return (Scenario(name: "rejoin", power: { _ in .ac }, start: rejoinStart.addingTimeInterval(-60), end: rejoinStart.addingTimeInterval(3 * 3600)),
                    RejoinDay.make(start: rejoinStart), [])
        case "forget":
            let forgetAt = rejoinStart.addingTimeInterval(40 * 60), start = rejoinStart
            return (Scenario(name: "forget", power: { _ in .ac }, start: start.addingTimeInterval(-60), end: start.addingTimeInterval(3 * 3600),
                             hooks: [(forgetAt, { store, now in
                                 // Forget 2 minutes in the middle of the pull request moment (it keeps its first action, so its id).
                                 let preview = try store.prepareDeletion(scope: .range(start: start.addingTimeInterval(300), end: start.addingTimeInterval(420), timezone: zone), now: now)
                                 _ = try store.executeDeletion(previewID: preview.id, confirmed: true, now: now)
                             })]),
                    RejoinDay.make(start: rejoinStart), [])
        case "owner-day": return (OwnerDay.scenario(), OwnerDay.make(), [])
        default: return nil
        }
    }
}
/// A day simulation's own error (the oracle's finding, say), as the serial run would have thrown it.
struct ShardError: Error, CustomStringConvertible { let description: String }
/// A shard that crashed, hung or ended without a result: already a named FAIL line.
struct ShardBroken: Error, CustomStringConvertible { let description: String }

/// test-p2 cadence-shard: the results of the day simulations. With one shard (CADENCE_SHARDS=1) each runs in this
/// process when asked for, as before. Otherwise every selected shard runs as a child process of this binary
/// (`--shard <name> <dir>`), `width` at a time, longest first; `get` waits for its child, prints what the child printed
/// and returns its result, so the output keeps the serial order whatever order the children end in.
@MainActor final class ShardResults {
    final class Child {
        let name: String, dir: URL
        var process: Process?, started = Date.distantPast, ended: Date?, timedOut = false
        init(name: String, dir: URL) { self.name = name; self.dir = dir }
    }
    let root: URL, width: Int, timeout: TimeInterval
    /// false: a broken shard's FAIL line is not printed or counted (the runner's own self-test reads `broken`).
    var report = true
    var children: [String: Child] = [:], queue: [String] = []
    var broken: [String: String] = [:]
    init(root: URL, width: Int, timeout: TimeInterval) { self.root = root; self.width = width; self.timeout = timeout }
    /// Starts the children of `names` (sharded runs only), in `Shard.launchOrder` and then the order given.
    func start(_ names: [String]) {
        guard width > 1 else { return }
        let ordered = Shard.launchOrder.filter(names.contains) + names.filter { !Shard.launchOrder.contains($0) }
        for name in ordered where children[name] == nil {
            children[name] = Child(name: name, dir: root.appendingPathComponent("shard-" + name, isDirectory: true)); queue.append(name)
        }
        pump()
    }
    private var running: [Child] { children.values.filter { $0.process?.isRunning == true } }
    /// Ends children past the timeout and starts queued ones while fewer than `width` run.
    private func pump() {
        let now = Date()
        for child in children.values where child.ended == nil && child.process?.isRunning == false { child.ended = now }
        for child in running where now.timeIntervalSince(child.started) > timeout {
            child.timedOut = true; kill(child.process!.processIdentifier, SIGKILL)
        }
        while running.count < width, !queue.isEmpty {
            let child = children[queue.removeFirst()]!
            try? FileManager.default.removeItem(at: child.dir)
            try? FileManager.default.createDirectory(at: child.dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let process = Process()
            process.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--shard", child.name, child.dir.path]
            FileManager.default.createFile(atPath: child.dir.appendingPathComponent("output.log").path, contents: nil)
            let log = FileHandle(forWritingAtPath: child.dir.appendingPathComponent("output.log").path)
            process.standardOutput = log; process.standardError = log
            child.started = Date()
            do { try process.run() } catch { broken[child.name] = "could not start: \(error)"; continue }
            child.process = process
        }
    }
    /// Stops every child still running (a run that ended early).
    func stopAll() {
        queue.removeAll()
        for child in running { kill(child.process!.processIdentifier, SIGKILL); child.process!.waitUntilExit() }
    }
    func get(_ name: String) async throws -> Result {
        if width <= 1 {
            guard let spec = Shard.spec(name) else { throw ShardError(description: "unknown shard \(name)") }
            // The scenario's own error reads as it always did ("\(error)"), sharded or not.
            do { return try await run(spec.scenario, day: spec.day, history: spec.history, root: root) }
            catch { throw ShardError(description: "\(error)") }
        }
        if children[name] == nil { start([name]) }
        let child = children[name]!
        while broken[name] == nil, child.process == nil || child.process!.isRunning {
            pump(); try await Task.sleep(nanoseconds: 100_000_000)
        }
        if let why = broken[name] { return try fail(name, why) }
        let process = child.process!
        process.waitUntilExit()
        let output = (try? String(contentsOf: child.dir.appendingPathComponent("output.log"), encoding: .utf8)) ?? ""
        if report { print(output, terminator: "") }
        let seconds = Int((child.ended ?? Date()).timeIntervalSince(child.started))
        // CADENCE_SHARD_TIMES=<file>: each shard's wall time, for the launch order and the runner's timings.
        if let path = ProcessInfo.processInfo.environment["CADENCE_SHARD_TIMES"], let line = "\(name) \(seconds)\n".data(using: .utf8) {
            if let handle = FileHandle(forWritingAtPath: path) { handle.seekToEndOfFile(); handle.write(line); try? handle.close() }
            else { FileManager.default.createFile(atPath: path, contents: line) }
        }
        if child.timedOut { return try fail(name, "timed out after \(Int(timeout)) s (CADENCE_SHARD_TIMEOUT), killed") }
        if process.terminationReason == .uncaughtSignal { return try fail(name, "crashed (signal \(process.terminationStatus)) after \(seconds) s") }
        if process.terminationStatus == 3, let error = try? String(contentsOf: child.dir.appendingPathComponent("error.txt"), encoding: .utf8) {
            throw ShardError(description: error)
        }
        guard process.terminationStatus == 0, let data = try? Data(contentsOf: child.dir.appendingPathComponent("result.json")),
              let result = try? JSONDecoder().decode(Result.self, from: data) else {
            return try fail(name, "exited \(process.terminationStatus) without a result after \(seconds) s")
        }
        return result
    }
    private func fail(_ name: String, _ why: String) throws -> Result {
        broken[name] = why
        if report { WriterCadenceChecks.check(false, "writer-cadence shard \(name): \(why)") }
        throw ShardBroken(description: "shard \(name): \(why)")
    }
}

@main struct WriterCadenceChecks {
    static var passed = 0, failed = 0
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") {
        if ok { passed += 1; print("PASS " + label) } else { failed += 1; print("FAIL " + label + (detail.isEmpty ? "" : " — " + detail)) }
    }
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--shard", args.count == 3 { await shardChild(args[1], dir: URL(fileURLWithPath: args[2], isDirectory: true)) }
        let base = ProcessInfo.processInfo.environment["CADENCE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let root = base.appendingPathComponent("writer-cadence-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ProcessInfo.processInfo.environment
        let width = environment["CADENCE_SHARDS"].flatMap(Int.init) ?? min(max(1, ProcessInfo.processInfo.activeProcessorCount / 2), 6)
        let results = ShardResults(root: root, width: max(1, width), timeout: environment["CADENCE_SHARD_TIMEOUT"].flatMap(TimeInterval.init) ?? 1500)
        do {
            if args.first == "--sim" { try await simulate(Array(args.dropFirst()), root: root); return }
            try await checks(results)
        } catch is ShardBroken {
            // Its FAIL line is printed.
        } catch { print("FAIL writer-cadence: \(error)"); failed += 1 }
        results.stopAll()
        print("writer-cadence: \(passed) passed, \(failed) failed")
        if failed > 0 { try? FileManager.default.removeItem(at: root); exit(1) }
    }
    /// A child: one shard's simulation; its result in `dir`/result.json (exit 0), or the scenario's own error in
    /// `dir`/error.txt (exit 3). An unknown shard exits 2. The self-test shards crash or hang.
    @MainActor static func shardChild(_ name: String, dir: URL) async -> Never {
        switch name {
        case "selftest-crash": raise(SIGKILL); exit(1)
        case "selftest-hang": while true { sleep(3600) }
        default: break
        }
        guard let spec = Shard.spec(name) else { print("writer-cadence: unknown shard \(name)"); exit(2) }
        do {
            let result = try await run(spec.scenario, day: spec.day, history: spec.history, root: dir)
            try JSONEncoder().encode(result).write(to: dir.appendingPathComponent("result.json"))
            fflush(stdout); exit(0)
        } catch {
            try? Data("\(error)".utf8).write(to: dir.appendingPathComponent("error.txt"))
            fflush(stdout); exit(3)
        }
    }
    @MainActor static func simulate(_ a: [String], root: URL) async throws {
        let load = { (path: String) throws -> [[String: Any]] in
            (try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any])["evidence"] as! [[String: Any]]
        }
        let rows = try load(a[1]), history = a.count > 3 ? try load(a[3]) : []
        let first = timestamp(rows.map { $0["at"] as! String }.min()!)!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zone)!
        let day = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: first)!
        guard let s = scenario(a[0], day: day) else { throw MemError.invalid("unknown scenario \(a[0])") }
        let result = try await run(s, day: rows, history: history, root: root)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: URL(fileURLWithPath: a[2]))
        print("\(s.name): runs=\(result.noteRuns) loads=\(result.loads) modelSeconds=\(Int(result.modelSeconds)) batches=\(result.batches) onDemand=\(result.onDemandBatches) passes=\(result.timerPasses)+\(result.eventPasses) levels=\(result.modelLevels)/\(result.codeLevels)")
    }
    /// fix/sx-all round 3: the rewrite rule on a short morning (CADENCE_ONLY=rejoin,forget runs only these).
    @MainActor static func rejoinChecks(_ results: ShardResults, forget withForget: Bool) async throws {
        // fix/sx-all round 3 (P1): a closed moment pending again without growing a quarter is written once more, 15
        // minutes after its mark, so its block is never held for a day. A pull request read (a code note), Xcode, then 3
        // clicks back on the pull request (the moment rejoins); and Forget over part of a written moment.
        // 03beb17 (first-note service): the 3 clicks leave the open pull request without a current note, so it gets a new
        // provisional note three minutes after them, before its final note at closure: the rejoined moment is written 3
        // times (provisional, provisional again, final), and Forget adds exactly one rewrite to that.
        let rejoin = try await results.get("rejoin")
        check(rejoin.pendingClosed.isEmpty && rejoin.blocks >= 1 && rejoin.maxRunsPerMoment <= 3,
              "rejoin: a pull request left and rejoined with 3 clicks is written again once; nothing stays pending and its block is written",
              "pending \(rejoin.pendingClosed), blocks \(rejoin.blocks), max runs \(rejoin.maxRunsPerMoment)")
        guard withForget else { return }
        let forget = try await results.get("forget")
        check(forget.pendingClosed.isEmpty && forget.blocks >= 1 && forget.maxRunsPerMoment == rejoin.maxRunsPerMoment + 1 && forget.maxRunsPerMoment <= 4,
              "Forget: a written moment Forget shortened is written again once (one run more than the same morning without Forget); nothing stays pending and its block is written",
              "pending \(forget.pendingClosed), blocks \(forget.blocks), max runs \(forget.maxRunsPerMoment) (rejoin \(rejoin.maxRunsPerMoment))")
    }
    /// fix/sx-all round 3: an AI app asking 12 times an hour on power (CADENCE_ONLY=mcp-ac runs only this).
    @MainActor static func mcpACCheck(_ results: ShardResults) async throws {
        let mcpAC = try await results.get("mcp-ac")
        let mcpACLoads = mcpAC.hours.map(\.loads)
        // A request writes a moment only while it has no note (once); the background rule rewrites what grew or changed.
        check((mcpACLoads.max() ?? 0) <= 4 && mcpAC.maxOnDemandRunsPerMoment <= 1 && mcpAC.maxNonMandatoryRunsPerMoment <= 3 && mcpAC.onDemandBatches > 0,
              "power + AI app 12 times an hour: the model loads at most 4 times an hour; a request writes a moment at most once, ordinary + MCP work writes a moment at most 3 times; proved mandatory live/final work is separate",
              "loads \(mcpACLoads) on-demand per moment \(mcpAC.maxOnDemandRunsPerMoment) nonmandatory per moment \(mcpAC.maxNonMandatoryRunsPerMoment) batches \(mcpAC.onDemandBatches)")
    }
    @MainActor static func oracleChecks() {
        typealias O=CadenceEvidence
        let start=Date(timeIntervalSince1970:1_800_000_000),due=start.addingTimeInterval(600),end=start.addingTimeInterval(500),day="2026-09-20"
        let activity=ActivityNote(id:"oracle",day:day,timezone:zone,subject:"Synthetic plan",actionIDs:["a","b"],apps:["TextEdit"],sites:[],start:BusyDay.iso(start),end:BusyDay.iso(end),clusters:[],inputRevision:"input",status:"pending",generated:nil,corrections:nil)
        let item=ScheduledWriterTarget(target:WriterTarget(kind:.activity,day:day,timezone:zone,activityID:activity.id),inputRevision:"input",policyRevision:"policy",lastActivity:end)
        func fact(_ activity:ActivityNote, shiftedStart:Date?=nil, nonempty:Bool=true, closed:Bool=false, mark:WrittenMark?=nil) -> O.Fact {
            O.Fact(item:item,activity:activity,start:shiftedStart ?? start,end:end,closeAt:end.addingTimeInterval(600),closed:closed,nonempty:nonempty,newTyped:false,mark:mark)
        }
        let base=fact(activity)
        func view(_ at:Date,_ f:O.Fact?=nil,entries:[ScheduledWriterState]=[]) -> O.View {
            O.View(at:at,facts:[item.key:f ?? base],ledger:O.Ledger(version:1,written:[:],entries:entries))
        }
        let run=O.Run(item:item,role:.live,started:due,ended:due.addingTimeInterval(10),fact:base)
        var mark=WrittenMark(actions:2,typed:0,at:due,provisional:true,end:end,revision:"input|policy|local",writes:1,writerRevision:WriterQueueSource.writerRevision)
        check(O.role(item,view:view(due),mcp:false,today:day) == .live && O.postErrors(run,mark:mark).isEmpty,"oracle: valid due live run and exact post-mark accepted")
        let early=O.Run(item:item,role:.live,started:due,ended:due.addingTimeInterval(10),fact:fact(activity,shiftedStart:start.addingTimeInterval(1)))
        check(!O.postErrors(early,mark:mark).isEmpty,"oracle: wrong live deadline rejects early service")
        mark.actions=1
        check(!O.postErrors(run,mark:mark).isEmpty,"oracle: incomplete coverage rejects live exemption")
        mark.actions=2;mark.revision="other|policy|local"
        check(!O.postErrors(run,mark:mark).isEmpty,"oracle: wrong revision rejects live exemption")
        mark.revision="input|policy|local";mark.provisional=false
        check(!O.postErrors(run,mark:mark).isEmpty,"oracle: lost provisional state rejects live exemption")
        mark.provisional=true;mark.at=run.ended
        check(!O.postErrors(run,mark:mark).isEmpty,"oracle: completion timestamp rejects cadence drift")
        check(!O.postErrors(run,mark:nil).isEmpty,"oracle: missing post-mark rejects unknown callback outcome")
        mark.at=due;mark.skipped=true;mark.fallback=true
        check(O.postErrors(run,mark:mark).isEmpty,"oracle: code-final/fallback attempt accepted only with coherent current mark")
        let finalAt=end.addingTimeInterval(600),prior=mark
        mark.provisional=false;mark.at=finalAt
        let finalRun=O.Run(item:item,role:.final,started:finalAt,ended:finalAt,fact:fact(activity,closed:true,mark:prior))
        check(O.role(item,view:view(finalAt,finalRun.fact),mcp:false,today:day) == .final && O.postErrors(finalRun,mark:mark).isEmpty,"oracle: provisional closure accepted at unchanged revision")
        mark.provisional=true
        check(!O.postErrors(finalRun,mark:mark).isEmpty,"oracle: final mark retaining provisional state rejected")
        mark.provisional=true;mark.at=start
        check(!O.postErrors(run,mark:mark).isEmpty,"oracle: unchanged stale mark cannot prove a new attempt")
        let unknown=ScheduledWriterTarget(target:WriterTarget(kind:.activity,day:day,timezone:zone,activityID:"unknown"),inputRevision:"input",policyRevision:"policy",lastActivity:end)
        check(O.role(unknown,view:view(due),mcp:false,today:day)==nil,"oracle: unknown target gets no role exemption")
        var large=activity;large.actionIDs=Array(repeating:"x",count:401)
        check(!fact(large).liveEligible && !fact(large,closed:true,mark:mark).finalEligible && !fact(activity,nonempty:false).liveEligible,"oracle: too-long and empty facts are excluded from required work")
        let before=view(start.addingTimeInterval(500)),last=start.addingTimeInterval(400)
        let valid=O.arm(current:before,before:before,nextWake:due,lastTimer:last,servedRequired:0,background:true,today:day)
        check(valid.1.isEmpty && valid.0.shortDeadline && valid.0.keys==Set([item.key]),"oracle: independently earliest armed live deadline accepted")
        let wrong=O.arm(current:before,before:before,nextWake:due.addingTimeInterval(-1),lastTimer:last,servedRequired:0,background:true,today:day)
        check(!wrong.1.isEmpty,"oracle: fabricated short wake fails arming proof")
        let ordinary=O.Armed(at:due,armedAt:last,shortDeadline:false,keys:[])
        check(!O.timerErrors(armed:ordinary,at:due,lastTimer:last).isEmpty && !O.timerErrors(armed:nil,at:due,lastTimer:last).isEmpty,"oracle: ordinary sub-300s and missing armed proof rejected")
        let newly=O.arm(current:view(due.addingTimeInterval(10)),before:view(due.addingTimeInterval(-10)),nextWake:due.addingTimeInterval(11),lastTimer:due.addingTimeInterval(-10),servedRequired:0,background:true,today:day)
        check(newly.1.isEmpty && newly.0.shortDeadline,"oracle: deadline crossed during finite inference gets one-second continuation")
        let unfilled=O.arm(current:view(due.addingTimeInterval(10)),before:view(due),nextWake:due.addingTimeInterval(11),lastTimer:due,servedRequired:0,background:true,today:day)
        check(!unfilled.1.isEmpty,"oracle: existing due backlog without filled mandatory batch rejects retry exemption")
        let queued=ScheduledWriterState(item:item,status:.queued,attempts:0,nextAttempt:due)
        let full=O.arm(current:view(due.addingTimeInterval(10),entries:[queued]),before:view(due),nextWake:due.addingTimeInterval(11),lastTimer:due,servedRequired:12,background:true,today:day)
        check(full.1.isEmpty && full.0.shortDeadline,"oracle: bounded full mandatory batch plus matching due queue proves continuation")
        let unqueued=O.arm(current:view(due.addingTimeInterval(10)),before:view(due),nextWake:due.addingTimeInterval(11),lastTimer:due,servedRequired:12,background:true,today:day)
        check(!unqueued.1.isEmpty,"oracle: full batch without matching residual queue does not prove continuation")
        // 03beb17 first-note service: an open moment with no current note, three minutes after its last action.
        let young=end.addingTimeInterval(-10),serviceAt=end.addingTimeInterval(180)
        let waiting=fact(activity,shiftedStart:young)
        let serviceRun=O.Run(item:item,role:.service,started:serviceAt,ended:serviceAt.addingTimeInterval(10),fact:waiting)
        var serviceMark=WrittenMark(actions:2,typed:0,at:serviceAt,provisional:true,end:end,revision:"input|policy|local",writes:1,writerRevision:WriterQueueSource.writerRevision)
        check(O.role(item,view:view(serviceAt,waiting),mcp:false,today:day) == .service && O.postErrors(serviceRun,mark:serviceMark).isEmpty,
              "oracle: first-note service accepted three minutes after an open moment's last action, with a provisional mark")
        check(O.role(item,view:view(serviceAt.addingTimeInterval(-1),waiting),mcp:false,today:day) == .ordinary
              && !O.postErrors(O.Run(item:item,role:.service,started:serviceAt.addingTimeInterval(-1),ended:serviceAt,fact:waiting),mark:serviceMark).isEmpty,
              "oracle: a run before the three-minute mark gets no service role (an ordinary run of an open moment is an error)")
        serviceMark.provisional=false
        check(!O.postErrors(serviceRun,mark:serviceMark).isEmpty,"oracle: a first note of an open moment that is not provisional is rejected")
        var noted=activity;noted.status="ready"
        let current=fact(noted,shiftedStart:young)
        check(!current.serviceEligible && O.role(item,view:view(serviceAt,current),mcp:false,today:day) == .ordinary
              && !fact(activity,shiftedStart:young,closed:true).serviceEligible && !fact(activity,shiftedStart:young,nonempty:false).serviceEligible,
              "oracle: a moment with a current note, a closed one and an empty one get no first-note service")
        let quiet=view(end.addingTimeInterval(60),waiting),quietTimer=end.addingTimeInterval(50)
        let serviceArmed=O.arm(current:quiet,before:quiet,nextWake:serviceAt,lastTimer:quietTimer,servedRequired:0,background:true,today:day)
        check(serviceArmed.1.isEmpty && serviceArmed.0.shortDeadline && serviceArmed.0.keys==Set([item.key]),"oracle: a wake at the earliest first-note service time is a proved short deadline")
        let serviceEarly=O.arm(current:quiet,before:quiet,nextWake:serviceAt.addingTimeInterval(-1),lastTimer:quietTimer,servedRequired:0,background:true,today:day)
        let notedQuiet=view(end.addingTimeInterval(60),current)
        let serviceNoted=O.arm(current:notedQuiet,before:notedQuiet,nextWake:serviceAt,lastTimer:quietTimer,servedRequired:0,background:true,today:day)
        check(!serviceEarly.1.isEmpty && !serviceNoted.1.isEmpty,"oracle: a fabricated service wake, or one for a moment with a current note, fails arming proof")
        let crossed=O.arm(current:view(serviceAt.addingTimeInterval(5),waiting),before:view(serviceAt.addingTimeInterval(-5),waiting),nextWake:serviceAt.addingTimeInterval(6),lastTimer:serviceAt.addingTimeInterval(-5),servedRequired:0,background:true,today:day)
        let already=O.arm(current:view(serviceAt.addingTimeInterval(15),waiting),before:view(serviceAt.addingTimeInterval(5),waiting),nextWake:serviceAt.addingTimeInterval(16),lastTimer:serviceAt.addingTimeInterval(5),servedRequired:0,background:true,today:day)
        check(crossed.1.isEmpty && crossed.0.shortDeadline && !already.1.isEmpty,
              "oracle: a service time crossed during finite inference continues on the next second; one already due before an unfilled batch does not")
        let backlog=O.arm(current:view(serviceAt.addingTimeInterval(15),waiting),before:view(serviceAt.addingTimeInterval(5),waiting),nextWake:serviceAt.addingTimeInterval(16),lastTimer:serviceAt.addingTimeInterval(5),servedRequired:0,ran:12,background:true,today:day)
        check(backlog.1.isEmpty && backlog.0.shortDeadline,"oracle: a full 12-note batch with first-note work still due proves continuation")
        // A stale turn: the entry queued for first-note service at "older", the open moment now at "input" and not due again.
        let older=ScheduledWriterTarget(target:WriterTarget(kind:.activity,day:day,timezone:zone,activityID:activity.id),inputRevision:"older",policyRevision:"policy",lastActivity:end.addingTimeInterval(-60))
        let olderQueued=ScheduledWriterState(item:older,status:.queued,attempts:0,nextAttempt:end)
        let turnAt=end.addingTimeInterval(60)
        let held=view(turnAt,waiting,entries:[olderQueued])
        let turn=O.StaleTurn(item:older,started:turnAt,ended:turnAt,fact:waiting)
        let gone=O.Ledger(version:1,written:[:],entries:[])
        check(O.staleErrors(turn,view:held,mcp:false,today:day,seen:[]).isEmpty && O.staleAfterErrors(turn,before:held.ledger,after:gone).isEmpty,
              "oracle: a stale turn is accepted when the entry was queued before, the open moment moved on and isn't due, nothing ran and the entry is dropped")
        check(!O.staleErrors(O.StaleTurn(item:older,started:turnAt,ended:turnAt.addingTimeInterval(5),fact:waiting),view:held,mcp:false,today:day,seen:[]).isEmpty,
              "oracle: a stale turn that took model time is rejected")
        check(!O.staleErrors(turn,view:view(turnAt,waiting),mcp:false,today:day,seen:[]).isEmpty
              && !O.staleErrors(O.StaleTurn(item:item,started:turnAt,ended:turnAt,fact:waiting),view:view(turnAt,waiting,entries:[queued]),mcp:false,today:day,seen:[]).isEmpty,
              "oracle: a stale turn needs an entry queued before the operation, at a revision the moment no longer has")
        let dueView=view(serviceAt,waiting,entries:[olderQueued]),closedFact=fact(activity,shiftedStart:young,closed:true)
        check(!O.staleErrors(O.StaleTurn(item:older,started:serviceAt,ended:serviceAt,fact:waiting),view:dueView,mcp:false,today:day,seen:[]).isEmpty
              && !O.staleErrors(O.StaleTurn(item:older,started:turnAt,ended:turnAt,fact:closedFact),view:view(turnAt,closedFact,entries:[olderQueued]),mcp:false,today:day,seen:[]).isEmpty
              && !O.staleErrors(turn,view:held,mcp:true,today:day,seen:[]).isEmpty,
              "oracle: a moment due first-note work, a closed one or an AI app's batch gets no stale turn (each is queued again at its current revision)")
        let written=O.Ledger(version:1,written:[older.key:serviceMark],entries:[])
        check(!O.staleAfterErrors(turn,before:held.ledger,after:O.Ledger(version:1,written:[:],entries:[olderQueued])).isEmpty
              && !O.staleAfterErrors(turn,before:held.ledger,after:written).isEmpty && !O.staleErrors(turn,view:held,mcp:false,today:day,seen:[turn]).isEmpty,
              "oracle: a stale entry left queued, a written mark changed by the turn, or a second turn of the same entry is rejected")
    }
    /// The shards CADENCE_ONLY (or its old names) selects; nil: all of them.
    static func selection() throws -> Set<String>? {
        let environment = ProcessInfo.processInfo.environment
        var names = Set<String>()
        if let only = environment["CADENCE_ONLY"] {
            names.formUnion(only.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "oracle" })
        }
        if environment["CADENCE_ONLY_AC"] != nil { names.insert("ac") }
        if environment["CADENCE_ONLY_MCPAC"] != nil { names.insert("mcp-ac") }
        if environment["CADENCE_ONLY_REJOIN"] != nil { names.formUnion(["rejoin", "forget"]) }
        let unknown = names.subtracting(Shard.all)
        guard unknown.isEmpty else { throw ShardError(description: "CADENCE_ONLY names no shard: \(unknown.sorted()); the shards are \(Shard.all)") }
        let asked = environment["CADENCE_ONLY"] != nil || ["CADENCE_ONLY_AC", "CADENCE_ONLY_MCPAC", "CADENCE_ONLY_REJOIN"].contains { environment[$0] != nil }
        return asked ? names : nil
    }
    /// test-p2 cadence-shard: the runner's own self-test. A shard that crashes and one that hangs past its timeout are each
    /// reported broken by name, and so is a shard name no child knows. (A real run prints that as a FAIL line and exits 1:
    /// CADENCE_SHARD_INJECT=selftest-crash shows it end to end.)
    @MainActor static func shardRunnerChecks(root: URL) async {
        let probe = ShardResults(root: root.appendingPathComponent("shard-selftest", isDirectory: true), width: 3, timeout: 5)
        probe.report = false
        let names = Shard.selfTests + ["selftest-no-such-shard"]
        probe.start(names)
        for name in names { _ = try? await probe.get(name) }
        check(probe.broken["selftest-crash"]?.hasPrefix("crashed (signal 9)") == true,
              "shard runner: a shard that crashes is reported broken by name (a FAIL line, and the run exits 1)", "\(probe.broken)")
        check(probe.broken["selftest-hang"]?.hasPrefix("timed out after 5 s") == true,
              "shard runner: a shard that hangs is killed at its timeout and reported broken by name", "\(probe.broken)")
        check(probe.broken["selftest-no-such-shard"]?.hasPrefix("exited 2 without a result") == true,
              "shard runner: a shard that exits without a result (an unknown shard name) is reported broken by name", "\(probe.broken)")
    }
    /// The acceptance, on a generated busy day (2026-09-20) and three days before it.
    @MainActor static func checks(_ results: ShardResults) async throws {
        oracleChecks()
        let selected = try selection()
        let want = { (names: [String]) in selected.map { s in names.allSatisfy(s.contains) } ?? true }
        results.start(Shard.all.filter { selected?.contains($0) ?? true })
        // CADENCE_SHARD_INJECT: one more shard, always a child process (whatever CADENCE_SHARDS says), read last.
        let injected = ProcessInfo.processInfo.environment["CADENCE_SHARD_INJECT"].map { name -> (String, ShardResults) in
            let probe = ShardResults(root: results.root.appendingPathComponent("inject", isDirectory: true), width: 2, timeout: results.timeout)
            probe.start([name]); return (name, probe)
        }
        let busyHours = (9...17).map { String(format: "%02d", $0) }
        func perHour(_ r: Result, _ key: KeyPath<HourRow, Int>) -> [Int] { busyHours.map { h in r.hours.first { $0.hour == h }?[keyPath: key] ?? 0 } }
        let ac = want(["ac"]) ? try await results.get("ac") : nil
        if let ac {
        let runs = perHour(ac, \.ordinaryRuns), loads = ac.hours.map(\.loads)
        let mean = Double(runs.reduce(0, +)) / Double(runs.count)
        // These targets bound ordinary closed-moment work; independently proved mandatory live/final
        // attempts remain in the total energy/load accounting above and are printed separately.
        print(String(format: "TARGET AC ordinary note runs per busy hour: mean %.1f (target 6), peak %d (target 9); %d moments, %d ordinary rewrites; total %d including live/final", mean, runs.max() ?? 0, ac.moments, ac.ordinaryRewrites, ac.noteRuns))
        check(Double(ac.ordinaryRewrites) <= 0.2 * Double(ac.moments),
              "AC: ordinary rewrites stay at most 1 in 5 moments; required live/final work independently proved", "\(ac.moments) moments, \(ac.ordinaryRewrites) ordinary rewrites")
        check(mean <= 7 && (runs.max() ?? 0) <= 12, "AC: ordinary note runs per busy hour mean <= 7, at most 12 in any hour", "mean \(mean) peak \(runs.max() ?? 0) \(runs)")
        check(ac.loads <= 40 && (loads.max() ?? 0) <= 4, "AC: model loads <= 40 a day and <= 4 an hour", "\(ac.loads) a day, peak \(loads.max() ?? 0)")
        // claude/notesfix-015 (owner 10/05, 0.1.6: no model rewrite of a moment card): the 900 s budget is the shipped
        // app's, where no model writes a moment (`WriterEnvironment.app`, momentModel false). The per-moment model day
        // (the hidden DayDreamMomentSummaries default, never shipped) is printed, not held to it.
        print("TARGET AC model time with per-moment model notes (hidden default, not shipped): \(Int(ac.modelSeconds)) s")
        }
        // claude/int-016: on the shipped day the model writes only the day review's clauses, so the fake answers them as a
        // model that writes them would ("shipped"); the day where every clause is refused ("refused": two answers each,
        // asked again hourly) is measured too and printed: the worst case, not held to the budget.
        // The oracle's own failure (a cadence rule broken on the shipped day) is one FAIL here, so the checks below still run.
        if want(["shipped"]) {
        do {
            let shipped = try await results.get("shipped")
            print("TARGET AC (shipped) model time: \(Int(shipped.modelSeconds)) s, \(shipped.loads) loads, \(shipped.answers) answers (all day-review clauses)")
            check(shipped.modelSeconds <= 900, "AC: model time <= 900 s a day (shipped: no model for moments)", "\(shipped.modelSeconds)")
            check(shipped.answers > 0, "AC (shipped): the model still writes the day review's clauses", "\(shipped.answers) answers")
            if let ac {
            check(shipped.modelSeconds < ac.modelSeconds || ac.modelSeconds == 0, "AC: the shipped day spends less model time than per-moment model notes",
                  "\(shipped.modelSeconds) vs \(ac.modelSeconds)")
            }
            check(shipped.moments > 0 && shipped.noteRuns >= shipped.moments, "AC (shipped): every closed moment still gets its (code) note", "\(shipped.moments) moments, \(shipped.noteRuns) runs")
        } catch let error as ShardError {
            check(false, "AC (shipped): the shipped day passes the cadence oracle", "\(error)")
        }
        }
        if want(["refused"]) {
        do {
            let refused = try await results.get("refused")
            print("TARGET AC (shipped, every clause refused: worst case, not held) model time: \(Int(refused.modelSeconds)) s, \(refused.loads) loads, \(refused.answers) answers")
        } catch let error as ShardError {
            check(false, "AC (shipped, every clause refused): the day passes the cadence oracle", "\(error)")
        }
        }
        if let ac {
        check(ac.maxNonMandatoryRunsPerMoment - 1 <= 5, "AC: at most 5 ordinary rewrites after a first ordinary note; all live/final exceptions independently proved", "ordinary max \(ac.maxNonMandatoryRunsPerMoment), total max \(ac.maxRunsPerMoment)")
        check(ac.dayNoteRuns == 0, "AC: no whole-day note runs", "\(ac.dayNoteRuns)")
        let timer = perHour(ac, \.ordinaryTimerPasses)
        check((timer.max() ?? 0) <= 12, "AC: at most 12 ordinary scheduled wake-ups an hour; short live/final deadlines independently proved", "\(timer)")
        check(ac.moments > 0 && ac.noteRuns >= ac.moments, "AC: fixture: every closed moment got its note run", "\(ac.moments) moments")
        // fix/sx-all round 2: the typed rows went through the real typed gate, and moments that need the model exist (the
        // fake model answered), so the bounds below measure model work, not code notes only.
        // The release build (owner typing) records typing in these apps; a build with the narrow app list refuses them all.
        if TypingRelease.open {
            // Refused only where the release records no typing: the Slack desktop app (not on the app list).
            check(ac.typedKept > 0 && Set(ac.typedRefusedApps).isSubset(of: ["com.tinyspeck.slackmacgap"]),
                  "fixture: the typed rows pass the real typed gate (turnOnTyping, ingest), refused only where typing isn't recorded", "\(ac.typedKept) of \(ac.typedRows), refused in \(ac.typedRefusedApps)")
        } else {
            check(ac.typedKept == 0, "fixture: a build without owner typing refuses the sim's typed rows at the real gate", "\(ac.typedKept) of \(ac.typedRows)")
        }
        check(ac.answers > 0 && ac.loads > 0, "fixture: moments that need the model exist (the model answered)", "\(ac.answers) answers, \(ac.loads) loads")
        }

        // fix/battery-summaries (owner 9/28): on battery (80%) the model writes in the background, in the same batches
        // as on power, never more often.
        let battery = want(["battery"]) ? try await results.get("battery") : nil
        if let battery {
        let batteryRuns = battery.hours.filter { $0.hour < "19" }.map(\.runs).reduce(0, +)
        let bRuns = perHour(battery, \.ordinaryRuns), bLoads = battery.hours.map(\.loads)
        let bMean = Double(bRuns.reduce(0, +)) / Double(bRuns.count)
        check(batteryRuns > 0 && battery.moments > 0 && battery.noteRuns >= battery.moments,
              "battery 80%: the model writes in the background, every closed moment gets its note", "\(batteryRuns) runs, \(battery.moments) moments")
        check(bMean <= 7 && (bRuns.max() ?? 0) <= 12 && battery.loads <= 40 && (bLoads.max() ?? 0) <= 4,
              "battery 80%: the same ordinary batching as on power (mean <= 7 and <= 12 an hour, loads <= 40 a day and <= 4 an hour)",
              "mean \(bMean) \(bRuns), \(battery.loads) loads, peak \(bLoads.max() ?? 0)")
        }
        if let battery, let ac {
        check(battery.noteRuns <= ac.noteRuns && battery.loads <= ac.loads && battery.batches <= ac.batches,
              "battery 80%: never more runs, loads or batches than on power",
              "runs \(battery.noteRuns)/\(ac.noteRuns) loads \(battery.loads)/\(ac.loads) batches \(battery.batches)/\(ac.batches)")
        }

        // Under 20%: nothing runs the model in the background; what waited is written once the Mac is plugged in.
        let lowBattery = want(["battery-low"]) ? try await results.get("battery-low") : nil
        if let lowBattery {
        let lowRuns = lowBattery.hours.filter { $0.hour < "19" }.map(\.runs).reduce(0, +)
        let lowLoads = lowBattery.hours.filter { $0.hour < "19" }.map(\.loads).reduce(0, +)
        check(lowRuns == 0 && lowLoads == 0, "battery 15%: no model runs and no loads in the background", "\(lowRuns) runs, \(lowLoads) loads")
        check(lowBattery.hours.filter { $0.hour >= "19" }.map(\.runs).reduce(0, +) > 0, "battery 15%: what waited is written once the Mac is plugged in")
        }
        // 03beb17: a first note queued for an open moment while the low battery held its batch can go stale (the person
        // carried on in the moment). Its turn runs nothing and drops it (`staleErrors`); with no hold nothing goes stale.
        if let ac, let battery, let lowBattery {
        check(ac.staleTurns == 0 && battery.staleTurns == 0 && lowBattery.staleTurns <= 1 && lowBattery.hours.filter { $0.hour < "19" }.map(\.staleTurns).reduce(0, +) == 0,
              "stale turns: none on power or at 80%; at 15% at most the one moment open at plug-in, where nothing runs for it",
              "ac \(ac.staleTurns) battery \(battery.staleTurns) battery-low \(lowBattery.staleTurns)")
        }

        if want(["mcp"]) {
        let mcp = try await results.get("mcp")
        let perHourOnDemand = perHour(mcp, \.onDemand)
        check((perHourOnDemand.max() ?? 0) <= 12 && mcp.onDemandBatches > 0, "battery + an AI app 12 times an hour: at most 12 on-demand batches an hour", "\(perHourOnDemand)")
        check(mcp.loadsPerOnDemandBatch.allSatisfy { $0 <= 1 }, "battery + AI app: each on-demand batch loads the model at most once", "\(mcp.loadsPerOnDemandBatch)")
        // fix/sx-all round 1: on battery a request writes at most 3 notes, at most every 15 minutes, and never rewrites a
        // moment it wrote in the last 20 minutes (the same growing moment was rewritten at every request).
        let mcpRuns = perHour(mcp, \.mcpRuns)
        check((perHourOnDemand.max() ?? 0) <= 4 && (mcpRuns.max() ?? 0) <= 12 && mcp.maxNonMandatoryRunsPerMoment <= 3 && mcp.maxMCPRunsPerBatch <= 3,
              "battery + AI app: at most 4 batches/hour, 3 actual MCP runs/batch, 12 MCP runs/hour, 3 nonmandatory runs/moment", "batches \(perHourOnDemand) runs \(mcpRuns) nonmandatory per moment \(mcp.maxNonMandatoryRunsPerMoment) max batch \(mcp.maxMCPRunsPerBatch)")

        let mcpLoads = mcp.hours.filter { $0.hour < "19" }.map(\.loads)
        check((mcpLoads.max() ?? 0) <= 4 && (mcpLoads.contains { $0 > 0 } && mcp.typedKept > 0 || !TypingRelease.open),
              "battery + AI app: the model loads in some hour, at most 4 times in any hour on battery", "\(mcpLoads)")
        check((mcp.hours.filter { $0.hour < "19" }.map(\.mcpRuns).max() ?? 0) <= 12, "battery + AI app: at most 12 MCP note runs in any hour on battery")
        }

        // fix/sx-all round 3 (P2): on power too, an AI app's requests rewrite a moment only once its note is 20 minutes old
        // and it grew by a quarter; before, they wrote and loaded the model about 10 times an hour.
        if want(["mcp-ac"]) { try await mcpACCheck(results) }

        if want(["lowpower"]) {
        let low = try await results.get("lowpower")
        check(low.noteRuns == 0 && low.loads == 0 && low.onDemandSkipped > 0, "Low Power Mode: no model runs, even for an AI app", "\(low.noteRuns) runs, \(low.loads) loads")
        }

        if want(["rejoin"]) { try await rejoinChecks(results, forget: want(["forget"])) }

        if want(["catchup-battery", "catchup-ac"]) {
        let upBattery = try await results.get("catchup-battery")
        let upAC = try await results.get("catchup-ac")
        // fix/battery-summaries: catch-up runs on battery too, in the same 10-note batches as on power (it was 124 runs in
        // the first hour before fix/sx-engine-battery).
        let firstHours = { (r: Result) in r.hours.filter { $0.hour == "08" || $0.hour == "09" }.map(\.runs).reduce(0, +) }
        check(upBattery.catchUpNotes > 0 && upBattery.catchUpBatches.allSatisfy { $0.count <= 10 } && firstHours(upBattery) <= firstHours(upAC),
              "update catch-up on battery: at most 10 notes a batch, no more in the first hour than on power",
              "\(upBattery.catchUpBatches.map(\.count)); first hour \(firstHours(upBattery)) vs \(firstHours(upAC))")
        check(upAC.catchUpNotes > 0 && upAC.catchUpBatches.allSatisfy { $0.count <= 10 }, "update catch-up on power: at most 10 notes a batch", "\(upAC.catchUpBatches.map(\.count))")
        check(upAC.catchUpBatches.allSatisfy { $0 == $0.sorted(by: >) }, "update catch-up on power: newest day first", "\(upAC.catchUpBatches.prefix(3))")
        check(upAC.catchUpBatches.flatMap { $0 }.allSatisfy { $0 >= "2026-09-13" }, "update catch-up: at most 7 days back")
        }

        if want(["owner-day"]) { try await ownerDayChecks(results) }
        await shardRunnerChecks(root: results.root)
        // The injected shard last (the runner's self-test: a broken one is a named FAIL and the run exits 1).
        if let (name, probe) = injected { _ = try await probe.get(name) }
    }
    /// test-p2 cadence-shard, owner bug 10 (the summaries writer didn't wake on schedule; fixed in 9eaa6f4): the owner's
    /// workday (`OwnerDay`) on the shipped writer. After each event the writer looks within its scheduled bound (the
    /// event's own pass, or for an unlock, which the app doesn't send, the wake armed before it), arms its next wake at
    /// most 15 minutes later (`quietWake`), and has written every moment that ended before the event 15 minutes after it;
    /// a wake under the 5-minute spacing of ordinary wakes is armed only when the oracle proves it, and a one-second wake
    /// only for first-note (or live/final) work, never for a rewrite alone; the oracle finds nothing in the hour after.
    @MainActor static func ownerDayChecks(_ results: ShardResults) async throws {
        let day = try await results.get("owner-day")
        let iso = { (d: Date) in BusyDay.iso(d) }
        func after(_ t: Date, event: String?, label: String) {
            var problems: [String] = []
            // The writer's look: the event's own pass at its time, or (an unlock) the first pass after it.
            let look = event.map { e in day.passLog.first { $0.reason == e && abs($0.at.timeIntervalSince(t)) < 1 } }
                ?? day.passLog.first { $0.at >= t }
            if let look {
                if look.at.timeIntervalSince(t) > 900 { problems.append("first look \(Int(look.at.timeIntervalSince(t))) s after it") }
                if let wake = look.nextWake { if wake.timeIntervalSince(look.at) > 900 { problems.append("next wake \(Int(wake.timeIntervalSince(look.at))) s after its look") } }
                else { problems.append("no wake armed after its look") }
            } else { problems.append("no \(event ?? "timer") pass") }
            if let probe = day.probes.first(where: { abs($0.at.timeIntervalSince(t.addingTimeInterval(900))) < 1 }) {
                let waiting = zip(probe.pending, probe.pendingEnds).filter { $0.1 < t }.map(\.0)
                if !waiting.isEmpty { problems.append("still without a note 15 minutes later: \(waiting)") }
            } else { problems.append("no probe 15 minutes after it") }
            let hour = { (d: Date) in d >= t && d < t.addingTimeInterval(3600) }
            let unproved = day.shortWakes.filter { hour($0.at) && (!$0.proved || ($0.oneSecond && !$0.firstNoteWork)) }
            if !unproved.isEmpty { problems.append("wakes under the 5-minute spacing not for first-note work: \(unproved.map { "\(iso($0.at))->\(iso($0.wake))\($0.rewritesOnly ? " (a rewrite only)" : "")" })") }
            let found = day.errorLog.filter { hour($0.at) }
            if !found.isEmpty { problems.append("oracle: \(found.prefix(3).map { "\(iso($0.at)) \($0.text)" })") }
            check(problems.isEmpty, label, problems.joined(separator: "; "))
        }
        print("  owner-day: passes \(day.passLog.count) (\(Dictionary(grouping: day.passLog, by: \.reason).mapValues(\.count).sorted { $0.key < $1.key })), short wakes \(day.shortWakes.count) (one-second \(day.shortWakes.filter(\.oneSecond).count)), reopened \(day.reopened), source discoveries \(day.sourceDiscoveries)")
        after(OwnerDay.lock.1, event: nil,
              label: "owner day (bug 10): after unlocking the screen (locked 10:31-10:52, a text left unsent) the writer looks on schedule, everything before the lock is written within 15 minutes, and no wake is armed early except for first-note work")
        after(OwnerDay.sleep.1, event: "wake",
              label: "owner day (bug 10): after a lid-close sleep (12:15-13:20) the writer looks at wake, arms its next wake within 15 minutes, everything before the sleep is written within 15 minutes, and the one-second wake fires only for first-note work")
        after(OwnerDay.plugIn, event: "power",
              label: "owner day (bug 10): after plugging in (14:05, battery to power) the writer looks at once, arms its next wake within 15 minutes and has written everything before it within 15 minutes; no early wake except for first-note work")
        after(OwnerDay.quit.1, event: "reopen",
              label: "owner day (bug 10): after DayDream is quit and opened again (15:40-15:44) summaries turn back on by themselves, the writer looks at once, arms its next wake within 15 minutes and writes what came before the quit within 15 minutes")
        // The lock's and the sleep's own passes close what ended before them and write it then (the app's eventCloses).
        let closes = ["lock": OwnerDay.lock.0, "sleep": OwnerDay.sleep.0].compactMap { (name, t) -> String? in
            day.passLog.contains { $0.reason == name && abs($0.at.timeIntervalSince(t)) < 1 && $0.nextWake != nil } ? nil : name
        }
        check(closes.isEmpty && day.reopened == 1, "owner day (bug 10): the screen lock and the lid close each reach the writer as a pass that keeps a wake armed; DayDream reopened once",
              "missing \(closes), reopened \(day.reopened)")
        check(day.pendingClosed.isEmpty && day.endQueued.isEmpty && day.blocks >= 1 && day.moments > 0 && day.noteRuns >= day.moments,
              "owner day (bug 10): nothing stays pending at the end of the day: every closed moment has its note, the writer's queue is empty and the day's blocks are written",
              "pending \(day.pendingClosed), queued \(day.endQueued), blocks \(day.blocks), \(day.moments) moments, \(day.noteRuns) runs")
        // The three looks back (Jordan's reply, the pull request's checks, the chat's answer): each moment already had its
        // note, grew for half a minute and closed again, so its rewrite is due 15 minutes after that note. 9eaa6f4: that is
        // ordinary work; the writer's own looks while only it waits (source discovery as rows land, the end of a pass)
        // never arm a one-second wake for it.
        let glances = OwnerDay.plan().glances
        print("  owner-day: rewrites \(day.rewriteLog.map { "\(iso($0.at)) \($0.subject.prefix(28)) (note \(iso($0.markAt)))" }); looks with only a rewrite due \(day.rewriteWaitLooks.count) (ends of passes \(day.rewriteWaitsAfterPass.count))")
        var rewriteProblems: [String] = []
        for (name, t) in zip(OwnerDay.glanceNames, glances) {
            if !day.rewriteLog.contains(where: { $0.at >= t && $0.end >= t && $0.at < t.addingTimeInterval(45 * 60) }) {
                rewriteProblems.append("\(name) (\(iso(t))): not written again within 45 minutes")
            }
        }
        if day.rewriteWaitLooks.isEmpty { rewriteProblems.append("fixture: the writer never looked while only a rewrite was due") }
        let rewriteWakes = day.shortWakes.filter(\.rewritesOnly)
        if !rewriteWakes.isEmpty { rewriteProblems.append("one-second wakes for a rewrite only: \(rewriteWakes.prefix(4).map { "\(iso($0.at))->\(iso($0.wake))" })") }
        check(rewriteProblems.isEmpty, "owner day (bug 10): a quick look back at a moment already written (Jordan's reply, the pull request's checks, the chat's answer) is written again on the ordinary cadence; while only that rewrite waits, no look arms a one-second wake for it",
              rewriteProblems.joined(separator: "; "))
        let unprovedAllDay = day.shortWakes.filter { !$0.proved || ($0.oneSecond && !$0.firstNoteWork) }
        check(day.errorLog.isEmpty && unprovedAllDay.isEmpty && day.answers > 0,
              "owner day (bug 10): the cadence oracle proves every run, timer and wake all day (lock, sleep, plug-in and a relaunch included); the model still writes the day review's clauses",
              "\(day.errorLog.count) findings \(day.errorLog.prefix(3).map { "\(iso($0.at)) \($0.text)" }); unproved short wakes \(unprovedAllDay.count); \(day.answers) answers")
    }
}
