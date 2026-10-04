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
    init(clock: SimClock) { self.clock = clock }
    func load() async throws { loads.append(clock.now); loaded = true; clock.advance(4) }
    func unload() async { loaded = false }
    func generate(instruction: String, evidence: String, maxTokens: Int) async throws -> Data {
        try await generate(instruction: instruction, evidence: evidence, maxTokens: maxTokens, prefill: "")
    }
    func generate(instruction: String, evidence: String, maxTokens: Int, prefill: String) async throws -> Data {
        answers.append(clock.now); clock.advance(5)
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

struct Scenario {
    var name: String
    var power: (Date) -> ModelPower
    var mcp: [Date] = []
    var start: Date, end: Date
    /// fix/sx-all round 3: things the person does to the store mid-day (Forget a range), at their times.
    var hooks: [(at: Date, run: (MemoryStore, Date) throws -> Void)] = []
}
struct HourRow: Codable { var hour: String; var runs = 0; var ordinaryRuns = 0; var liveRuns = 0; var finalRuns = 0; var mcpRuns = 0; var catchUpRuns = 0; var ordinaryTimerPasses = 0; var loads = 0; var passes = 0; var timerPasses = 0; var onDemand = 0; var catchUp = 0; var modelSeconds = 0.0 }
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
    var liveRuns = 0, finalRuns = 0, ordinaryRuns = 0, mcpRuns = 0, pastRuns = 0
    var evidenceErrors: [String] = []
}

/// Test-only oracle over scratch data. It never calls WriterQueueSource.discoverDay,
/// never acquires the scheduler's lock, and never trusts a product "run reason" label.
/// Literal contract times intentionally make a production cadence change require review.
@MainActor final class CadenceEvidence {
    enum Role: Equatable { case ordinary, live, final, mcp, catchUp }
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
        var liveDue: Date { max(start.addingTimeInterval(600), mark?.at.addingTimeInterval(600) ?? start.addingTimeInterval(600)) }
        var liveEligible: Bool { !closed && nonempty && activity.actionIDs.count <= 400 }
        var finalEligible: Bool { closed && nonempty && activity.actionIDs.count <= 400 && mark?.provisional == true }
    }
    struct View { let at: Date; let facts: [String: Fact]; let ledger: Ledger }
    struct Run {
        let item: ScheduledWriterTarget, role: Role, started: Date, ended: Date, fact: Fact
    }
    struct Armed {
        let at: Date, armedAt: Date
        let shortDeadline: Bool
        // Proof remains valid if later ingests postpone closure before the timer fires.
        let keys: Set<String>
    }
    let store: MemoryStore, days: [String], today: String
    var view: View?, activeMCP = false, nextAttempt = Date.distantPast
    var runs: [Run] = [], pending: [Run] = [], errors: [String] = []
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
        var facts: [String: Fact]=[:]
        for day in days {
            let layers=try store.dayLayers(day:day,timezone:zone,now:at)
            guard !layers.partial else { throw MemError.invalid("cadence oracle: partial canonical day") }
            let ends=try layers.activities.map { activity -> Date in
                guard let end=timestamp(activity.end) else { throw MemError.invalid("cadence oracle: bad end") };return end
            }
            for activity in layers.activities {
                guard let start=timestamp(activity.start),let end=timestamp(activity.end) else { throw MemError.invalid("cadence oracle: bad timestamps") }
                let closeAt=end.addingTimeInterval(ends.contains {$0>end} ? 120 : 600)
                let closed=day != today || at>=closeAt || (closing.map {$0>=end} ?? false)
                let item=ScheduledWriterTarget(target:WriterTarget(kind:.activity,day:day,timezone:zone,activityID:activity.id),inputRevision:activity.inputRevision,policyRevision:policy,lastActivity:end)
                let actions=try activity.actionIDs.map { id -> CanonicalAction in
                    guard let action=try store.action(id,now:at) else { throw MemError.invalid("cadence oracle: unavailable action \(id)") };return action
                }
                guard let bundles=activity.bundles else { throw MemError.invalid("cadence oracle: unknown bundle metadata") }
                let admitted=activity.apps.contains {!$0.isEmpty} || activity.sites.contains {!$0.isEmpty} || bundles.contains {!$0.isEmpty}
                let hasApp = !bundles.isEmpty || activity.apps.contains {!$0.isEmpty}
                let nonempty=admitted && hasApp && (actions.count>64 || actions.contains {!["idle","session.started","session.ended"].contains($0.kind)})
                let mark=ledger.written[item.key]
                let known=(activity.previous ?? activity.generated).map { Set($0.actionIDs) }
                let addedIDs=known.map { ids in activity.actionIDs.filter {!ids.contains($0)} }
                    ?? Array(activity.actionIDs.dropFirst(mark?.actions ?? activity.actionIDs.count))
                let newTyped=(mark.map { activity.actionIDs.count>$0.actions } ?? false) && actions.contains { addedIDs.contains($0.id) && ["keyboard.text_input","keyboard.submit"].contains($0.kind) }
                facts[item.key]=Fact(item:item,activity:activity,start:start,end:end,closeAt:closeAt,closed:closed,nonempty:nonempty,newTyped:newTyped,mark:mark)
            }
        }
        return View(at:at,facts:facts,ledger:ledger)
    }
    func begin(at: Date, idle: TimeInterval, mcp: Bool, timer: Bool) throws {
        // This driver has no lock/sleep events. Its only early close is independently simulated idle.
        closing = !mcp && idle>=300 ? at.addingTimeInterval(-idle+1) : nil
        view=try snapshot(at:at,closing:closing);activeMCP=mcp;nextAttempt=at;pending=[];servedRequired=0
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
        if fact.finalEligible { return .final }
        return .ordinary
    }
    func note(_ item: ScheduledWriterTarget, at: Date) {
        guard let view,let fact=view.facts[item.key],let role=Self.role(item,view:view,mcp:activeMCP,today:today) else { errors.append("unknown/stale run facts for \(item.key)");return }
        if role == .live || role == .final { servedRequired+=1 }
        if pending.contains(where:{$0.item.key==item.key}) { errors.append("duplicate run in one operation: \(item.key)") }
        if role == .ordinary {
            if !fact.closed || !fact.nonempty { errors.append("ordinary run is open/empty: \(item.key)") }
            if runs.contains(where:{$0.item.key==item.key}) { ordinaryRewrites+=1 }
            if let mark=fact.mark,!mark.provisional {
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
        if role == .ordinary || role == .mcp { nonMandatory[item.key,default:0]+=1 }
        let run=Run(item:item,role:role,started:nextAttempt,ended:at,fact:fact)
        // Only FakeModel.load/generate advance this clock during a driver operation.
        // beginBatch and all scheduler/core work leave it unchanged between note callbacks.
        nextAttempt=at;pending.append(run);runs.append(run)
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
        case .final:
            if mark.provisional { errors.append("closure did not finalize provisional mark: \(run.item.key)") }
        case .ordinary,.catchUp:
            if mark.provisional { errors.append("closed ordinary/catch-up mark remains provisional: \(run.item.key)") }
        case .mcp:
            if mark.provisional == run.fact.closed { errors.append("MCP provisional state mismatches closure: \(run.item.key)") }
        }
        return errors
    }
    static func arm(current: View, before view: View, nextWake: Date, lastTimer: Date, servedRequired: Int, background: Bool, today: String) -> (Armed,[String]) {
        let at=current.at
        var errors: [String]=[]
        let floor=max(lastTimer.addingTimeInterval(300),view.at.addingTimeInterval(1))
        var keys=Set<String>()
        if background && nextWake<floor {
            // Independent future candidates are computed before another ingest can change them.
            let candidates=current.facts.values.filter {$0.item.day==today && $0.liveEligible}.flatMap { fact -> [(Date,String)] in
                var values: [(Date,String)]=[]
                if fact.liveDue>at { values.append((fact.liveDue,fact.item.key)) }
                if fact.mark?.provisional==true && fact.closeAt>at { values.append((fact.closeAt,fact.item.key)) }
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
        let proof=Self.arm(current:current,before:view,nextWake:nextWake,lastTimer:lastTimer,servedRequired:servedRequired,background:background,today:today)
        armed=proof.0;errors+=proof.1
    }
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
    let model = FakeModel(clock: clock)
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
    env.unloadSleep = { _ in try await Task.sleep(nanoseconds: 1_000_000_000_000_000) }
    env.postDone = { world.done += 1 }
    env.automatic = false
    let files = CompatibleWriterFiles(model: home.appendingPathComponent("fake.model"), library: home.appendingPathComponent("fake.dylib"))
    var admission = LocalAdmission(restoreOffline: { _, _ in files }, checkWithApple: {}, signedBuild: { false })
    admission.download = { _, _ in files }
    let writer = WriterIntegration(modelRoot: home.appendingPathComponent("Models"), keyStore: NoKeys(), send: { _ in throw URLError(.notConnectedToInternet) },
                                   admission: admission, environment: env)
    writer.offerLocal = true
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
    writer.onNoteRun = { item in
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
    writer.configure(store: store)
    for _ in 0..<500 where writer.busy { try await Task.sleep(nanoseconds: 10_000_000) }
    var cursor = 0
    func ingest(until t: Date) throws {
        while cursor < events.count, let at = timestamp(events[cursor].at), at <= t {
            try put(events[cursor], now: at.addingTimeInterval(0.5)); world.lastInput = at
            if ["keyboard.text_input","keyboard.submit"].contains(events[cursor].kind) { world.lastTyping=at }
            cursor += 1
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
    if let batch = currentCatchUp, !batch.isEmpty { catchUpBatches.append(batch) }
    var mcp = scenario.mcp.sorted()
    var hooks = scenario.hooks.sorted { $0.at < $1.at }
    var lastPower = world.power
    let powerChanges = stride(from: scenario.start.timeIntervalSince1970, to: scenario.end.timeIntervalSince1970, by: 60).map { Date(timeIntervalSince1970: $0) }
        .filter { scenario.power($0) != scenario.power($0.addingTimeInterval(-60)) }
    var nextPowerChange = powerChanges.makeIterator(), pendingPower = nextPowerChange.next()
    let debug = ProcessInfo.processInfo.environment["CADENCE_DEBUG"] != nil
    while clock.now < scenario.end {
        let wake = writer.nextWake ?? scenario.end
        if debug { let l = await model.loaded; print("  t=\(BusyDay.iso(clock.now)) wake=\(writer.nextWake.map(BusyDay.iso) ?? "nil") loaded=\(l) loads=\(await model.snapshot().loads.count) runs=\(writer.counters.noteRuns) batches=\(writer.counters.batches)") }
        var next = min(wake, scenario.end)
        if let m = mcp.first { next = min(next, m) }
        if let h = hooks.first { next = min(next, h.at) }
        if let p = pendingPower { next = min(next, p) }
        next = max(next, clock.now)
        try ingest(until: next)
        clock.set(next)
        let loadsBefore = await model.snapshot().loads.count
        let catchBefore = writer.counters.catchUpNotes
        currentCatchUp = []
        if let h = hooks.first, h.at <= clock.now {
            hooks.removeFirst()
            try h.run(store, clock.now)
            try evidence.begin(at:clock.now,idle:env.idleSeconds(),mcp:false,timer:false)
            passTimes.append((clock.now, false)); await writer.pass(.explicit)
            try evidence.finish(at:clock.now,nextWake:writer.nextWake,background:world.power.allowsBackground,mcpBatch:false)
        } else if let p = pendingPower, p <= clock.now {
            pendingPower = nextPowerChange.next()
            world.power = scenario.power(clock.now)
            if world.power != lastPower {
                lastPower = world.power
                try evidence.begin(at:clock.now,idle:env.idleSeconds(),mcp:false,timer:false)
                passTimes.append((clock.now, false)); await writer.pass(.power)
                try evidence.finish(at:clock.now,nextWake:writer.nextWake,background:world.power.allowsBackground,mcpBatch:false)
            }
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
        } else { clock.advance(1) }
        if writer.counters.catchUpNotes > catchBefore, let batch = currentCatchUp, !batch.isEmpty { catchUpBatches.append(batch) }
        try ingest(until: clock.now)
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
        case .final: hours[h]!.finalRuns+=1
        case .mcp: hours[h]!.mcpRuns+=1
        case .catchUp: hours[h]!.catchUpRuns+=1
        }
    }
    for t in evidence.ordinaryTimers { hours[row(t),default:HourRow(hour:row(t))].ordinaryTimerPasses+=1 }
    for t in snap.loads { hours[row(t), default: HourRow(hour: row(t))].loads += 1; hours[row(t)]!.modelSeconds += 4 }
    for t in snap.answers { hours[row(t), default: HourRow(hour: row(t))].modelSeconds += 5 }
    for (t, timer) in passTimes { hours[row(t), default: HourRow(hour: row(t))].passes += 1; if timer { hours[row(t)]!.timerPasses += 1 } }
    for t in onDemandTimes { hours[row(t), default: HourRow(hour: row(t))].onDemand += 1 }
    let counts = Array(runsByMoment.values)
    let c = writer.counters
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
    result.finalRuns=hours.values.map(\.finalRuns).reduce(0,+)
    result.mcpRuns=hours.values.map(\.mcpRuns).reduce(0,+)
    result.pastRuns=hours.values.map(\.catchUpRuns).reduce(0,+)
    result.evidenceErrors=evidence.errors
    if result.noteRuns != result.ordinaryRuns+result.liveRuns+result.finalRuns+result.mcpRuns+result.pastRuns || result.noteRuns != c.noteRuns { result.evidenceErrors.append("run partition/callbacks do not equal total attempts") }
    if result.pastRuns != c.catchUpNotes || result.mcpBatchStarts.count != c.onDemandBatches { result.evidenceErrors.append("catch-up/MCP accounting mismatch") }
    if !result.evidenceErrors.isEmpty { throw MemError.invalid("cadence oracle: " + result.evidenceErrors.joined(separator:"; ")) }
    print("    proved partition ordinary/live/final/MCP/catch-up: \(result.ordinaryRuns)/\(result.liveRuns)/\(result.finalRuns)/\(result.mcpRuns)/\(result.pastRuns); ordinary rewrites \(result.ordinaryRewrites)")
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

@main struct WriterCadenceChecks {
    static var passed = 0, failed = 0
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") {
        if ok { passed += 1; print("PASS " + label) } else { failed += 1; print("FAIL " + label + (detail.isEmpty ? "" : " — " + detail)) }
    }
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        let args = Array(CommandLine.arguments.dropFirst())
        let base = ProcessInfo.processInfo.environment["CADENCE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let root = base.appendingPathComponent("writer-cadence-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            if args.first == "--sim" { try await simulate(Array(args.dropFirst()), root: root); return }
            try await checks(root: root)
        } catch { print("FAIL writer-cadence: \(error)"); failed += 1 }
        print("writer-cadence: \(passed) passed, \(failed) failed")
        if failed > 0 { try? FileManager.default.removeItem(at: root); exit(1) }
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
    /// fix/sx-all round 3: the rewrite rule on a short morning (CADENCE_ONLY_REJOIN runs only these).
    @MainActor static func rejoinChecks(root: URL) async throws {
        // fix/sx-all round 3 (P1): a closed moment pending again without growing a quarter is written once more, 15
        // minutes after its mark, so its block is never held for a day. A pull request read (a code note), Xcode, then 3
        // clicks back on the pull request (the moment rejoins); and Forget over part of a written moment.
        let rejoinStart = ISO8601DateFormatter().date(from: "2026-09-21T16:00:00Z")!
        let rejoinDay = RejoinDay.make(start: rejoinStart)
        let rejoin = try await run(Scenario(name: "rejoin", power: { _ in .ac }, start: rejoinStart.addingTimeInterval(-60), end: rejoinStart.addingTimeInterval(3 * 3600)),
                                   day: rejoinDay, history: [], root: root)
        check(rejoin.pendingClosed.isEmpty && rejoin.blocks >= 1 && rejoin.maxRunsPerMoment <= 3,
              "rejoin: a pull request left and rejoined with 3 clicks is written again once; nothing stays pending and its block is written",
              "pending \(rejoin.pendingClosed), blocks \(rejoin.blocks), max runs \(rejoin.maxRunsPerMoment)")
        let forgetAt = rejoinStart.addingTimeInterval(40 * 60)
        let forget = try await run(Scenario(name: "forget", power: { _ in .ac }, start: rejoinStart.addingTimeInterval(-60), end: rejoinStart.addingTimeInterval(3 * 3600),
                                            hooks: [(forgetAt, { store, now in
                                                // Forget 2 minutes in the middle of the pull request moment (it keeps its first action, so its id).
                                                let preview = try store.prepareDeletion(scope: .range(start: rejoinStart.addingTimeInterval(300), end: rejoinStart.addingTimeInterval(420), timezone: zone), now: now)
                                                _ = try store.executeDeletion(previewID: preview.id, confirmed: true, now: now)
                                            })]),
                                   day: rejoinDay, history: [], root: root)
        check(forget.pendingClosed.isEmpty && forget.blocks >= 1 && forget.maxRunsPerMoment <= 3 && forget.maxRunsPerMoment >= 2,
              "Forget: a written moment Forget shortened is written again once; nothing stays pending and its block is written",
              "pending \(forget.pendingClosed), blocks \(forget.blocks), max runs \(forget.maxRunsPerMoment)")
    }
    /// fix/sx-all round 3: an AI app asking 12 times an hour on power (CADENCE_ONLY_MCPAC runs only this).
    @MainActor static func mcpACCheck(root: URL, day: [[String: Any]], nine: Date) async throws {
        let mcpAC = try await run(scenario("mcp-ac", day: nine)!, day: day, history: [], root: root)
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
    }
    /// The acceptance, on a generated busy day (2026-09-20) and three days before it.
    @MainActor static func checks(root: URL) async throws {
        oracleChecks()
        if ProcessInfo.processInfo.environment["CADENCE_ONLY_MCPAC"] != nil {
            try await mcpACCheck(root: root, day: BusyDay.make(day: 20, seed: 11), nine: ISO8601DateFormatter().date(from: "2026-09-20T16:00:00Z")!); return
        }
        if ProcessInfo.processInfo.environment["CADENCE_ONLY_REJOIN"] != nil { try await rejoinChecks(root: root); return }
        let day = BusyDay.make(day: 20, seed: 11)
        let history = BusyDay.make(day: 17, seed: 24) + BusyDay.make(day: 18, seed: 25) + BusyDay.make(day: 19, seed: 26)
        let nine = ISO8601DateFormatter().date(from: "2026-09-20T16:00:00Z")!
        let busyHours = (9...17).map { String(format: "%02d", $0) }
        func perHour(_ r: Result, _ key: KeyPath<HourRow, Int>) -> [Int] { busyHours.map { h in r.hours.first { $0.hour == h }?[keyPath: key] ?? 0 } }

        let ac = try await run(scenario("ac", day: nine)!, day: day, history: [], root: root)
        if ProcessInfo.processInfo.environment["CADENCE_ONLY_AC"] != nil { return }
        let runs = perHour(ac, \.ordinaryRuns), loads = ac.hours.map(\.loads)
        let mean = Double(runs.reduce(0, +)) / Double(runs.count)
        // These targets bound ordinary closed-moment work; independently proved mandatory live/final
        // attempts remain in the total energy/load accounting above and are printed separately.
        print(String(format: "TARGET AC ordinary note runs per busy hour: mean %.1f (target 6), peak %d (target 9); %d moments, %d ordinary rewrites; total %d including live/final", mean, runs.max() ?? 0, ac.moments, ac.ordinaryRewrites, ac.noteRuns))
        check(Double(ac.ordinaryRewrites) <= 0.2 * Double(ac.moments),
              "AC: ordinary rewrites stay at most 1 in 5 moments; required live/final work independently proved", "\(ac.moments) moments, \(ac.ordinaryRewrites) ordinary rewrites")
        check(mean <= 7 && (runs.max() ?? 0) <= 12, "AC: ordinary note runs per busy hour mean <= 7, at most 12 in any hour", "mean \(mean) peak \(runs.max() ?? 0) \(runs)")
        check(ac.loads <= 40 && (loads.max() ?? 0) <= 4, "AC: model loads <= 40 a day and <= 4 an hour", "\(ac.loads) a day, peak \(loads.max() ?? 0)")
        check(ac.modelSeconds <= 900, "AC: model time <= 900 s a day", "\(ac.modelSeconds)")
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

        // fix/battery-summaries (owner 9/28): on battery (80%) the model writes in the background, in the same batches
        // as on power, never more often.
        let battery = try await run(scenario("battery", day: nine)!, day: day, history: [], root: root)
        let batteryRuns = battery.hours.filter { $0.hour < "19" }.map(\.runs).reduce(0, +)
        let bRuns = perHour(battery, \.ordinaryRuns), bLoads = battery.hours.map(\.loads)
        let bMean = Double(bRuns.reduce(0, +)) / Double(bRuns.count)
        check(batteryRuns > 0 && battery.moments > 0 && battery.noteRuns >= battery.moments,
              "battery 80%: the model writes in the background, every closed moment gets its note", "\(batteryRuns) runs, \(battery.moments) moments")
        check(bMean <= 7 && (bRuns.max() ?? 0) <= 12 && battery.loads <= 40 && (bLoads.max() ?? 0) <= 4,
              "battery 80%: the same ordinary batching as on power (mean <= 7 and <= 12 an hour, loads <= 40 a day and <= 4 an hour)",
              "mean \(bMean) \(bRuns), \(battery.loads) loads, peak \(bLoads.max() ?? 0)")
        check(battery.noteRuns <= ac.noteRuns && battery.loads <= ac.loads && battery.batches <= ac.batches,
              "battery 80%: never more runs, loads or batches than on power",
              "runs \(battery.noteRuns)/\(ac.noteRuns) loads \(battery.loads)/\(ac.loads) batches \(battery.batches)/\(ac.batches)")

        // Under 20%: nothing runs the model in the background; what waited is written once the Mac is plugged in.
        let lowBattery = try await run(scenario("battery-low", day: nine)!, day: day, history: [], root: root)
        let lowRuns = lowBattery.hours.filter { $0.hour < "19" }.map(\.runs).reduce(0, +)
        let lowLoads = lowBattery.hours.filter { $0.hour < "19" }.map(\.loads).reduce(0, +)
        check(lowRuns == 0 && lowLoads == 0, "battery 15%: no model runs and no loads in the background", "\(lowRuns) runs, \(lowLoads) loads")
        check(lowBattery.hours.filter { $0.hour >= "19" }.map(\.runs).reduce(0, +) > 0, "battery 15%: what waited is written once the Mac is plugged in")

        let mcp = try await run(scenario("mcp", day: nine)!, day: day, history: [], root: root)
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

        // fix/sx-all round 3 (P2): on power too, an AI app's requests rewrite a moment only once its note is 20 minutes old
        // and it grew by a quarter; before, they wrote and loaded the model about 10 times an hour.
        try await mcpACCheck(root: root, day: day, nine: nine)

        let low = try await run(scenario("lowpower", day: nine)!, day: day, history: [], root: root)
        check(low.noteRuns == 0 && low.loads == 0 && low.onDemandSkipped > 0, "Low Power Mode: no model runs, even for an AI app", "\(low.noteRuns) runs, \(low.loads) loads")

        try await rejoinChecks(root: root)

        let upBattery = try await run(scenario("catchup-battery", day: nine)!, day: day, history: history, root: root)
        let upAC = try await run(scenario("catchup-ac", day: nine)!, day: day, history: history, root: root)
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
}
