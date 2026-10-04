import Foundation
import AppKit
import CryptoKit
import MemoryUI
@testable import MemoryCore
@testable import WriterBackend

/// fix/sx-engine-battery: the summaries state machine as the app runs it (the REAL WriterIntegration, scheduler, core
/// binding and adapters) with a fake installer, a fake model and a fake OpenRouter. No download, no model, no network,
/// no Keychain, no app, no capture. The clock is simulated where closing moments needs it.
let zone = TimeZone.current.identifier

final class Clock: @unchecked Sendable {
    private let lock = NSLock(); private var value: Date
    init(_ start: Date) { value = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ date: Date) { lock.lock(); value = date; lock.unlock() }
    func advance(_ s: TimeInterval) { lock.lock(); value = value.addingTimeInterval(s); lock.unlock() }
}
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock(); private var _value: T
    init(_ v: T) { _value = v }
    var value: T { get { lock.lock(); defer { lock.unlock() }; return _value } set { lock.lock(); _value = newValue; lock.unlock() } }
}
/// The actual unloadSleep callback acknowledges that BatchRuntime already set idleSince and installed its timer.
/// Cancel synchronously removes a transient sleep when a following batch cancels that timer, even if its sleeping
/// task has not resumed yet. A cancellation before registration also cannot publish a spurious active sleep.
final class UnloadSleeps: @unchecked Sendable {
    private let lock=NSLock()
    private var active=Set<UUID>(),cancelled=Set<UUID>()
    func begin(_ id:UUID) {lock.lock();defer {lock.unlock()};if !cancelled.contains(id) {active.insert(id)}}
    func cancel(_ id:UUID) {lock.lock();defer {lock.unlock()};cancelled.insert(id);active.remove(id)}
    func finish(_ id:UUID) {lock.lock();defer {lock.unlock()};active.remove(id);cancelled.remove(id)}
    var activeCount:Int {lock.lock();defer {lock.unlock()};return active.count}
}

/// A model that answers after `delay` (or waits until cancelled when `hang`), counting loads and answers.
actor FakeModel: LocalInference {
    nonisolated let pausePredicate = Box<@Sendable () -> Bool>({ false })
    nonisolated let onGenerate = Box<@Sendable () -> Void>({})
    var loads = 0, unloads = 0, answers = 0, loaded = false
    var hang = false, paused = false
    var failLoad = false
    var failCapacity = false
    func set(failCapacity: Bool) { self.failCapacity = failCapacity }
    /// fix/bugs7: answers wait while held (a slow batch), then go on when released.
    var held = false
    func set(held: Bool) { self.held = held }
    func set(hang: Bool) { self.hang = hang }
    func set(paused: Bool) { self.paused = paused }
    func set(failLoad: Bool) { self.failLoad = failLoad }
    /// fix/resummarize: answer a moment's note that passes the checks (one line citing every item), so notes are stored.
    var valid = false
    func set(valid: Bool) { self.valid = valid }
    var loadAttempts = 0
    func load() async throws { loadAttempts += 1; if failLoad { throw WriterFailure.unavailable }; loads += 1; loaded = true }
    /// Deterministically suspend the actual BatchRuntime overdue-unload path for the replacement race check.
    var holdUnload = false
    func set(holdUnload: Bool) { self.holdUnload = holdUnload }
    func unload() async {
        unloads += 1; loaded = false
        while holdUnload { try? await Task.sleep(nanoseconds: 10_000_000) }
    }
    func generate(instruction: String, evidence: String, maxTokens: Int) async throws -> Data {
        try await generate(instruction: instruction, evidence: evidence, maxTokens: maxTokens, prefill: "")
    }
    func generate(instruction: String, evidence: String, maxTokens: Int, prefill: String) async throws -> Data {
        answers += 1
        onGenerate.value()
        if failCapacity { throw WriterFailure.capacity }
        while held { try await Task.sleep(nanoseconds: 10_000_000) }
        while pausePredicate.value() { try await Task.sleep(nanoseconds: 10_000_000) }
        while paused { try await Task.sleep(nanoseconds: 10_000_000) }
        if hang { while true { try await Task.sleep(nanoseconds: 20_000_000) } }
        if valid {
            let rx = try! NSRegularExpression(pattern: #"(?m)^([in]\d+)\. "#)
            let ids = rx.matches(in: evidence, range: NSRange(evidence.startIndex..., in: evidence)).map { "\"" + (evidence as NSString).substring(with: $0.range(at: 1)) + "\"" }
            return Data((#"{"title":"Launch checklist","bullets":[{"ids":["# + ids.joined(separator: ",") + #"],"text":"Drafted the launch checklist in TextEdit."}]}"#).utf8)
        }
        return Data(#"{"title":"","bullets":[]}"#.utf8)
    }
}
actor TestKeys: WriterSecureKeyStore {
    var value = ""
    func readSecret() async throws -> String { value }
    func saveSecret(_ value: String) async throws { self.value = value }
    func removeSecret() async throws { value = "" }
}
/// OpenRouter: answers each request with the next queued reply (the last one repeats).
actor FakeOpenRouter {
    var replies: [(Int, String)] = [(200, #"{"model":"deepseek/deepseek-v4-flash-0731","choices":[{"message":{"content":"OK"}}]}"#)]
    var calls = 0, bodies: [Data] = []
    func set(_ list: [(Int, String)]) { replies = list }
    func send(_ request: URLRequest) throws -> CloudHTTPResponse {
        calls += 1; bodies.append(request.httpBody ?? Data())
        let reply = replies.count > 1 ? replies.removeFirst() : replies[0]
        if reply.0 == 0 { throw URLError(.timedOut) }
        return CloudHTTPResponse(status: reply.0, body: Data(reply.1.utf8))
    }
}

@main struct SummaryUXSchedulingChecks {
    static var passed = 0, failed = 0
    static func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1; print("PASS " + label) } else { failed += 1; print("FAIL " + label + { let d = detail(); return d.isEmpty ? "" : " — " + d }()) }
    }
    static var root: URL!
    static var typingKeys: [String: InMemoryTypedKeyStore] = [:]
    static func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
    /// Waits (real time, at most `limit` seconds) until `done` holds: a state change, never a fixed sleep.
    @MainActor static func until(_ limit: Double = 10, _ done: @MainActor () async -> Bool) async {
        let deadline = Date().addingTimeInterval(limit)
        while await !done(), Date() < deadline { await sleep(0.01) }
    }
    struct Rig {
        let home: URL, store: MemoryStore, writer: WriterIntegration, model: FakeModel, http: FakeOpenRouter, keys: TestKeys
        let modelChoice: Box<FakeModel>
        let unloadSleeps: UnloadSleeps
        let clock: Clock, power: Box<ModelPower>, idle: Box<TimeInterval>, typing: Box<TimeInterval>, done: Box<Int>, defaults: UserDefaults, suite: String
    }
    static func files(_ home: URL) -> CompatibleWriterFiles { CompatibleWriterFiles(model: home.appendingPathComponent("fake.model"), library: home.appendingPathComponent("fake.dylib")) }
    /// A writer over a fresh store (or `home` again, for a relaunch), with a fake installer unless `admission` is given.
    /// fix/writing-forever: a rig clock `back` seconds before now that never crosses local midnight during a scenario.
    /// Before, a clock 2-3 hours back crossed it when the check ran between about 01:40 and 03:00 local time: a moment
    /// then ended on the day before the writer's "today", so the next pass (today's batch) never tried it again and
    /// "a key revoked while writing" read on(cloud) (and "Try Again while OpenRouter keeps answering 429" after it);
    /// run at 01:56 the moment fixture itself found no moment. A start outside 01:00-20:00 moves to the nearest earlier
    /// noon (still under 16 hours back, well inside typed words' 24 hours); scenarios move the clock under 4 hours.
    static func recentClock(_ back: TimeInterval) -> Clock {
        let start = Date().addingTimeInterval(-back), calendar = Calendar.current
        let hour = calendar.component(.hour, from: start)
        guard hour < 1 || hour >= 20 else { return Clock(start) }
        let day = calendar.startOfDay(for: start)
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: hour < 1 ? calendar.date(byAdding: .day, value: -1, to: day)! : day)!
        return Clock(noon)
    }
    @MainActor static func rig(_ name: String, clock: Clock = recentClock(3 * 3600), admission: LocalAdmission? = nil, home reuse: URL? = nil,
                               suite reuseSuite: String? = nil, keys reuseKeys: TestKeys? = nil, model reuseModel: FakeModel? = nil) async throws -> Rig {
        let home = reuse ?? root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        // fix/sx-all: typing on (as the owner's default), so each moment holds a typed row and needs the model; a moment
        // of windows alone gets a code note and never loads it (fix/notes-quality).
        let vaultKeys = typingKeys[home.path] ?? InMemoryTypedKeyStore()
        typingKeys[home.path] = vaultKeys
        try store.attachVault(TypedTextVault(keyStore: vaultKeys))
        if reuse == nil {
            var consent = try store.policy(); consent.captureText = true; consent.typedConsentVersion = 1; try store.updatePolicy(consent)
            try store.setUpTypedVault(); try store.acceptSafeTyping()
            var typed = try store.typedTextPolicy()
            typed.categories = TypedCategoryChoices(searchAndAI: true, writing: true, code: true, messagesAndEmail: true, otherWebsites: true)
            _ = try store.updateTypedTextPolicy(typed, confirmed: true)
        }
        let model = reuseModel ?? FakeModel(), http = FakeOpenRouter(), keys = reuseKeys ?? TestKeys()
        let modelChoice = Box(model)
        let unloadSleeps = UnloadSleeps()
        let power = Box(ModelPower.ac), idle = Box<TimeInterval>(0), typing = Box<TimeInterval>(99), done = Box(0)
        let suite = reuseSuite ?? "writer-state-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        var env = WriterEnvironment()
        env.now = { clock.now }; env.power = { power.value }; env.idleSeconds = { idle.value }
        env.typingSeconds = { typing.value }; env.defaults = defaults; env.makeRuntime = { _ in modelChoice.value }; env.postDone = { done.value += 1 }; env.automatic = false
        env.makeRuntimeWithPause = { _, predicate in let chosen=modelChoice.value; chosen.pausePredicate.value=predicate; return chosen }
        env.unloadSleep = { _ in
            let id=UUID()
            try await withTaskCancellationHandler(operation:{
                unloadSleeps.begin(id);defer {unloadSleeps.finish(id)}
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds:1_000_000_000_000)
            },onCancel:{unloadSleeps.cancel(id)})
        }
        let fake = files(home)
        var local = admission ?? LocalAdmission(restoreOffline: { _, _ in fake }, checkWithApple: {}, signedBuild: { false })
        if admission == nil { local.download = { _, progress in progress(.downloading(1, 2)); progress(.downloading(2, 2)); return fake } }
        let writer = WriterIntegration(modelRoot: home.appendingPathComponent("Models"), keyStore: keys, send: { try await http.send($0) }, admission: local, environment: env)
        writer.offerLocal = true
        writer.configure(store: store)
        for _ in 0..<300 where writer.busy { await sleep(0.02) }
        return Rig(home: home, store: store, writer: writer, model: model, http: http, keys: keys, modelChoice: modelChoice, unloadSleeps: unloadSleeps, clock: clock, power: power, idle: idle, typing: typing, done: done, defaults: defaults, suite: suite)
    }
    @MainActor static func on(_ rig: Rig) async throws {
        rig.writer.chooseLocal()
        for _ in 0..<300 { if case .on(.local) = rig.writer.phase { return }; await sleep(0.02) }
        throw MemError.invalid("didn't turn on: \(rig.writer.phase) \(rig.writer.status)")
    }
    /// One moment of `count` actions ending at the clock's time minus `ago` seconds.
    @discardableResult static func moment(_ rig: Rig, _ id: String, _ title: String, count: Int = 3, ago: TimeInterval = 900, app: String = "TextEdit", bundle: String = "com.apple.TextEdit") throws -> (day: String, id: String) {
        let end = rig.clock.now.addingTimeInterval(-ago)
        for k in 0..<count {
            let at = end.addingTimeInterval(-Double(count - 1 - k) * 2)
            if k == 1 {
                // A typed draft (fix/sx-all): the moment needs the model.
                let unit: [String: Any] = ["version": "typed-unit/v3", "runID": "\(id)-run", "part": 1, "sealReason": "idle", "startedAt": iso(at.addingTimeInterval(-20)),
                                           "withheld": 0, "surface": "writing", "field": "unknown", "send": "none"]
                let row: [String: Any] = ["id": "\(id)-\(k)", "at": iso(at), "kind": "keyboard.text_input", "app": app, "bundle": bundle, "title": title, "url": "",
                                          "text": "Outline the launch checklist for \(title)", "secure": false, "privateWindow": false, "synthetic": true,
                                          "captureProvenance": ["policyRevision": "synthetic", "classifierVersion": "sensitive-typing/v2", "windowID": "w", "focusID": "f",
                                                                "checkedAt": iso(at), "generation": 1, "unit": unit]]
                let e = try JSONDecoder().decode(Evidence.self, from: JSONSerialization.data(withJSONObject: row))
                guard try rig.store.ingest(e, now: at.addingTimeInterval(0.5)) else { throw MemError.invalid("typed row refused at ingest") }
                continue
            }
            _ = try rig.store.ingest(Evidence(id: "\(id)-\(k)", at: iso(at), kind: k == 0 ? "window.changed" : "mouse.click", app: app, bundle: bundle, title: title, synthetic: true), now: at.addingTimeInterval(0.5))
        }
        // fix/writing-forever: the moment is looked up on the day of its FIRST action. Its actions can straddle local midnight
        // (150 actions, 2 s apart, ending just after it): run at 01:55 the end's day held no "-0" action and the
        // force-unwrap crashed the whole check. A moment that still can't be found fails its check with a message.
        let first = end.addingTimeInterval(-Double(count - 1) * 2)
        let day = try DayScope.key(first, timezone: zone)
        guard let found = try rig.store.dayLayers(day: day, timezone: zone, now: rig.clock.now).activities.first(where: { $0.actionIDs.contains("\(id)-0") }) else {
            throw MemError.invalid("fixture: no moment holds \(id)-0 on \(day) (actions \(iso(first)) to \(iso(end)), clock \(iso(rig.clock.now)))")
        }
        return (day, found.id)
    }
    static func ledger(_ rig: Rig) throws -> [String: Any] {
        let data = try Data(contentsOf: rig.home.appendingPathComponent("WriterScheduling/pending-v1.json"))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
    static func entries(_ rig: Rig) throws -> [[String: Any]] { (try ledger(rig)["entries"] as? [[String: Any]]) ?? [] }
    static func statuses(_ rig: Rig) throws -> [String] { try entries(rig).compactMap { $0["status"] as? String } }
    @MainActor static func finish(_ rig: Rig) async {
        await rig.writer.shutdown()
        rig.defaults.removePersistentDomain(forName: rig.suite)
    }


    @MainActor static func main() async {
        setvbuf(stdout,nil,_IOLBF,0)
        let base=ProcessInfo.processInfo.environment["STATE_CHECK_ROOT"].map {URL(fileURLWithPath:$0,isDirectory:true)} ?? URL(fileURLWithPath:FileManager.default.currentDirectoryPath,isDirectory:true).appendingPathComponent("work",isDirectory:true)
        try? FileManager.default.createDirectory(at:base,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        root=base.appendingPathComponent("summary-ux-scheduling-"+UUID().uuidString)
        try? FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer {try? FileManager.default.removeItem(at:root)}
        for (name,run) in [("twenty minutes",twentyMinutes),("sixty minutes",sixtyMinutes),("load cap",loadCap),("typing burst",typingBurst),("power hold",powerHold),("natural close",naturalClose),("full backlog",fullBacklog),("generation duration",generationDuration),("cold short lease",coldShortLease),("MCP short lease",mcpShortLease),("lease releases",leaseReleases),("lease lifecycle",leaseLifecycle),("lease acquire replacement",leaseAcquireReplacement),("lease acquire idle transition",leaseAcquireIdleTransition),("lease acquire battery transition",leaseAcquireBatteryTransition)] {
            do {try await run()} catch {check(false,name,"\(error)")}
        }
        check(WriterIntegration.typingBurst==3,"actual typing burst threshold is three seconds")
        print("summary-ux-scheduling: \(passed) passed, \(failed) failed; synthetic clock/store/model only")
        if failed>0 {exit(1)}
    }
    static func pointer(_ r:Rig,_ id:String,at:Date?=nil) throws {
        let date=at ?? r.clock.now
        _=try r.store.ingest(Evidence(id:id,at:iso(date),kind:"mouse.click",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Launch plan",synthetic:true),now:date.addingTimeInterval(0.5))
    }
    static func mark(_ r:Rig,id:String) throws -> [String:Any] {
        let written=(try ledger(r)["written"] as? [String:[String:Any]]) ?? [:]
        return written.first {$0.key.components(separatedBy:"\u{1f}").last==id}?.value ?? [:]
    }
    @MainActor static func cadence(_ name:String,minutes:Int) async throws {
        let r=try await rig(name)
        await r.model.set(valid:true)
        let chosen=try moment(r,"live","Launch plan",ago:0)
        let first=try r.store.dayLayers(day:chosen.day,timezone:zone,now:r.clock.now).activities.first {$0.id==chosen.id}!
        let start=timestamp(first.start)!
        try await on(r)
        let before=r.writer.counters.noteRuns
        for minute in 1...minutes {
            r.clock.set(start.addingTimeInterval(Double(minute)*60))
            try pointer(r,"pointer-\(minute)")
            r.idle.value=0 // Continuous pointer use must never suppress live cadence.
            if minute==9 {
                r.clock.advance(59);try pointer(r,"pointer-599")
                await r.writer.pass(.timer)
                check(r.writer.counters.noteRuns==before,"\(name): no provisional note before ten minutes")
                check(r.writer.nextWake==start.addingTimeInterval(600),"\(name): live deadline bypasses five-minute wake floor","\(String(describing:r.writer.nextWake))")
            } else if minute % 10==0 {
                await r.writer.pass(.timer)
                check(r.writer.counters.noteRuns==before+minute/10,"\(name): live refresh at minute \(minute)","\(r.writer.counters) \(r.writer.status)")
            }
        }
        let after=try mark(r,id:chosen.id)
        check(after["provisional"] as? Bool==true,"\(name): active note remains provisional")
        check(after["writes"] as? Int==minutes/10,"\(name): ten-minute refreshes exceed lifetime write cap","\(after)")
        check(await r.model.loads==1,"\(name): mature active moment keeps one warm model load")
        let source=WriterQueueSource(store:r.store)
        let layers=try r.store.dayLayers(day:chosen.day,timezone:zone,now:r.clock.now)
        check(layers.activities.first {$0.id==chosen.id}?.status=="ready","\(name): stored local note is ready")
        let policy=try r.store.policy().revision
        let target=ScheduledWriterTarget(target:WriterTarget(kind:.activity,day:chosen.day,timezone:zone,activityID:chosen.id),inputRevision:layers.activities.first {$0.id==chosen.id}!.inputRevision,policyRevision:policy,lastActivity:r.clock.now)
        let oldMark=WrittenMark(actions:layers.activities.first {$0.id==chosen.id}!.actionIDs.count,typed:0,at:r.clock.now.addingTimeInterval(-600),provisional:true,writes:99,writerRevision:WriterQueueSource.writerRevision)
        let ready=try await source.discoverDay(chosen.day,now:r.clock.now,timezone:zone,marks:[target.key:oldMark])
        check(ready.live.contains {$0.activityID==chosen.id},"\(name): ready open moment with old mark remains eligible after 99 writes")
        await source.setAudience(.cloud)
        let cloud=try await source.discoverDay(chosen.day,now:r.clock.now,timezone:zone,marks:[target.key:oldMark])
        check(cloud.live.isEmpty && cloud.nextLive==nil && !cloud.keepLocalWarm,"\(name): cloud retains no automatic open-moment cadence")
        let runs=r.writer.counters.noteRuns
        r.clock.advance(1)
        await r.writer.pass(.lock)
        let final=try mark(r,id:chosen.id)
        check(r.writer.counters.noteRuns==runs+1 && final["provisional"] as? Bool==false,"\(name): closure writes final note at unchanged ready revision")
        await r.writer.pass(.timer)
        check(r.writer.counters.noteRuns==runs+1,"\(name): closed final note does not spin")
        await finish(r)
    }

    @MainActor static func loadCap() async throws {
        let r=try await rig("cold-load-cap")
        await r.model.set(valid:true)
        let chosen=try moment(r,"cap","Launch plan",ago:0)
        let first=try r.store.dayLayers(day:chosen.day,timezone:zone,now:r.clock.now).activities.first {$0.id==chosen.id}!
        let start=timestamp(first.start)!
        try await on(r)
        for minute in [3,5,7,9] {
            r.clock.set(start.addingTimeInterval(Double(minute)*60));try pointer(r,"manual-pointer-\(minute)",at:r.clock.now.addingTimeInterval(-3))
            try await r.writer.generate(day:chosen.day,timezone:zone,activityID:chosen.id,lastActivity:r.clock.now.addingTimeInterval(-3))
        }
        check(await r.model.loads==4,"cap: four manual cold loads fill legacy hourly budget")
        let before=r.writer.counters.noteRuns
        for minute in 10...19 {r.clock.set(start.addingTimeInterval(Double(minute)*60));try pointer(r,"cap-pointer-\(minute)")}
        await r.writer.pass(.timer)
        let loadsAfterFirst=await r.model.loads
        check(r.writer.counters.noteRuns==before+1 && loadsAfterFirst==5,"cap: due local live refresh can perform fifth cold load")
        for minute in 20...29 {r.clock.set(start.addingTimeInterval(Double(minute)*60));try pointer(r,"cap-pointer-\(minute)")}
        await r.writer.pass(.timer)
        let loadsAfterSecond=await r.model.loads
        check(r.writer.counters.noteRuns==before+2 && loadsAfterSecond==5,"cap: following live refresh reuses warm fifth load")
        await finish(r)
    }
    @MainActor static func typingBurst() async throws {
        let r=try await rig("typing-burst")
        await r.model.set(valid:true)
        let chosen=try moment(r,"burst","Launch plan",ago:0)
        let first=try r.store.dayLayers(day:chosen.day,timezone:zone,now:r.clock.now).activities.first {$0.id==chosen.id}!
        let start=timestamp(first.start)!
        try await on(r)
        for minute in 1...10 {r.clock.set(start.addingTimeInterval(Double(minute)*60));try pointer(r,"typing-pointer-\(minute)")}
        r.typing.value=0
        let before=r.writer.counters.noteRuns
        let running=Task {await r.writer.pass(.timer)}
        await until {await r.model.answers>0}
        check(await r.model.answers>0 && r.writer.counters.noteRuns==before,"typing: due generation starts then parks during actual burst")
        check(r.model.pausePredicate.value(),"typing: zero key-down age pauses inference")
        r.clock.advance(1);try pointer(r,"in-flight-pointer")
        r.typing.value=2.99
        check(r.model.pausePredicate.value(),"typing: key-down age below three seconds stays paused")
        r.typing.value=3;r.idle.value=0
        check(!r.model.pausePredicate.value(),"typing: three-second key-down age releases despite continuous pointer activity")
        await running.value
        let finalLoads=await r.model.loads
        check(r.writer.counters.noteRuns==before+1 && finalLoads==1,"typing: release completes same generation without reload")
        check(r.writer.counters.committedNotes>0,"typing: local prepared snapshot commits despite additive pointer growth")
        await finish(r)
    }

    @MainActor static func powerHold() async throws {
        let r=try await rig("power-hold")
        await r.model.set(valid:true)
        let chosen=try moment(r,"power","Launch plan",ago:0)
        let first=try r.store.dayLayers(day:chosen.day,timezone:zone,now:r.clock.now).activities.first {$0.id==chosen.id}!
        let start=timestamp(first.start)!
        try await on(r)
        for minute in 1...10 {r.clock.set(start.addingTimeInterval(Double(minute)*60));try pointer(r,"power-pointer-\(minute)")}
        await r.writer.pass(.timer)
        let before=r.writer.counters.noteRuns
        var held=ModelPower.ac;held.lowPowerMode=true;r.power.value=held
        r.clock.advance(60);try pointer(r,"power-pointer-11");await r.writer.pass(.power)
        for minute in 12...20 {r.clock.set(start.addingTimeInterval(Double(minute)*60));try pointer(r,"power-pointer-\(minute)")}
        await r.writer.pass(.timer)
        check(r.writer.counters.noteRuns==before,"power: local live cadence remains held in Low Power Mode")
        r.power.value = .ac;await r.writer.pass(.power)
        check(r.writer.counters.noteRuns==before+1,"power: due live refresh runs when background power permits")
        check(await r.model.loads==2,"power: power hold releases warm lease before resumed cold load")
        await finish(r)
    }

    @MainActor static func naturalClose() async throws {
        let r=try await rig("natural-close")
        await r.model.set(valid:true)
        let chosen=try moment(r,"natural","Launch plan",ago:0)
        let first=try r.store.dayLayers(day:chosen.day,timezone:zone,now:r.clock.now).activities.first {$0.id==chosen.id}!
        let start=timestamp(first.start)!
        try await on(r)
        for minute in 1...9 {r.clock.set(start.addingTimeInterval(Double(minute)*60));try pointer(r,"natural-pointer-\(minute)")}
        r.clock.set(start.addingTimeInterval(600));await r.writer.pass(.timer)
        let before=r.writer.counters.noteRuns
        r.clock.set(start.addingTimeInterval(19*60-1));await r.writer.pass(.timer)
        check(r.writer.nextWake==start.addingTimeInterval(19*60),"natural close: provisional final deadline bypasses five-minute wake floor")
        r.clock.advance(1);await r.writer.pass(.timer)
        let final=try mark(r,id:chosen.id)
        check(r.writer.counters.noteRuns==before+1 && final["provisional"] as? Bool==false,"natural close: unchanged ready input receives final note at exact close time")
        await finish(r)
    }

    @MainActor static func fullBacklog() async throws {
        let r=try await rig("full-backlog")
        await r.model.set(valid:true)
        let chosen=try moment(r,"priority","Launch plan",ago:0)
        let first=try r.store.dayLayers(day:chosen.day,timezone:zone,now:r.clock.now).activities.first {$0.id==chosen.id}!
        let start=timestamp(first.start)!
        try await on(r)
        for minute in [3,5,7,9] {
            r.clock.set(start.addingTimeInterval(Double(minute)*60));try pointer(r,"priority-pointer-\(minute)",at:r.clock.now.addingTimeInterval(-3))
            try await r.writer.generate(day:chosen.day,timezone:zone,activityID:chosen.id,lastActivity:r.clock.now.addingTimeInterval(-3))
        }
        // A blocked-power discovery fills all 128 routing slots with older,
        // same-day closed moments. Core remains their durable authority.
        for index in 0..<128 {try moment(r,"backlog-\(index)","Backlog document \(index)",ago:1200+Double(index)*60)}
        var held=ModelPower.ac;held.lowPowerMode=true;r.power.value=held
        await r.writer.pass(.power)
        let queued=try entries(r).filter {$0["status"] as? String=="queued"}
        check(queued.count==128,"backlog: all 128 routing slots contain old queued moments","\(queued.count)")
        let before=r.writer.counters.noteRuns
        let served=Box<[String]>([])
        r.writer.onNoteRun = {served.value.append($0.activityID ?? "")}
        for minute in 10...19 {r.clock.set(start.addingTimeInterval(Double(minute)*60));try pointer(r,"priority-pointer-\(minute)")}
        r.power.value = .ac;await r.writer.pass(.power)
        check(served.value==[chosen.id],"backlog: due active moment gets first and only budget-bypass slot","\(served.value)")
        check(r.writer.counters.noteRuns==before+1,"backlog: unrelated closed notes remain held by exhausted load budget")
        check(await r.model.loads==5,"backlog: only due live note performs fifth cold load")
        let remaining=try entries(r).filter {$0["status"] as? String=="queued"}
        check(remaining.count==127,"backlog: displaced routing entry leaves 127 old notes queued; core can rediscover it","\(remaining.count)")
        await finish(r)
    }

    @MainActor static func generationDuration() async throws {
        let r=try await rig("generation-duration")
        await r.model.set(valid:true)
        let chosen=try moment(r,"duration","Launch plan",ago:0)
        let first=try r.store.dayLayers(day:chosen.day,timezone:zone,now:r.clock.now).activities.first {$0.id==chosen.id}!
        let start=timestamp(first.start)!
        try await on(r)
        for minute in 1...10 {r.clock.set(start.addingTimeInterval(Double(minute)*60));try pointer(r,"duration-pointer-\(minute)")}
        r.model.onGenerate.value = {r.clock.advance(60)}
        await r.writer.pass(.timer)
        let written=try mark(r,id:chosen.id)
        check((written["at"] as? Double).map {Date(timeIntervalSinceReferenceDate:$0)}==start.addingTimeInterval(600),"duration: local provisional cadence mark uses attempt start")
        check(r.writer.nextWake==start.addingTimeInterval(1200),"duration: nonzero inference time does not drift next ten-minute refresh")
        r.model.onGenerate.value = {}
        await finish(r)
    }
    @MainActor static func coldShortLease() async throws {
        let r=try await rig("cold-short-lease")
        let chosen=try moment(r,"short","Launch plan",ago:3)
        try await on(r)
        let source=WriterQueueSource(store:r.store)
        let found=try await source.discoverDay(chosen.day,now:r.clock.now,timezone:zone)
        check(found.keepLocalWarm && found.live.isEmpty,"lease: writable short open moment is warm-eligible without becoming due")
        await r.writer.pass(.timer)
        let loads=await r.model.loads,answers=await r.model.answers
        check(loads==0 && answers==0,"lease: cold short-moment timer acquire does not load or generate")
        check(r.writer.nextWake != nil,"lease: cold short moment retains its future timer")
        await finish(r)
    }

    @MainActor static func mcpShortLease() async throws {
        let r=try await rig("mcp-short-lease")
        await r.model.set(valid:true)
        try moment(r,"mcp-first","Launch plan",ago:3)
        try await on(r)
        // No timer has run: MCP itself must acquire the persistent lease before its ordinary batch.
        await r.writer.onDemand()
        let firstLoads=await r.model.loads,firstAnswers=await r.model.answers
        check(firstLoads==1 && firstAnswers>0,"lease: MCP discovers and writes a short open moment before the first timer")
        r.clock.advance(301)
        try moment(r,"mcp-second","Launch follow-up",ago:3)
        await r.writer.onDemand()
        let loads=await r.model.loads,answers=await r.model.answers
        check(loads==1 && answers>firstAnswers,"lease: a second short MCP moment reuses weights past the 90-second grace without a timer")
        await finish(r)
    }

    @MainActor static func leaseReleases() async throws {
        for condition in ["idle","low-power","low-battery","serious-thermal","critical-thermal","closure"] {
            let r=try await rig("lease-release-"+condition)
            await r.model.set(valid:true)
            try moment(r,"release-first","Launch plan",ago:3)
            try await on(r);await r.writer.onDemand()
            let firstAnswers=await r.model.answers
            check(await r.model.loads==1,"lease \(condition): fixture initially loads once")
            r.clock.advance(1)
            var power=ModelPower.ac
            switch condition {
            case "idle":r.idle.value=300
            case "low-power":power.lowPowerMode=true
            case "low-battery":power.onPower=false;power.battery=19
            case "serious-thermal":power.thermal=ProcessInfo.ThermalState.serious.rawValue
            case "critical-thermal":power.thermal=ProcessInfo.ThermalState.critical.rawValue
            default:break
            }
            r.power.value=power
            if condition=="closure" {
                await r.writer.pass(.lock)
                // tick's final batch is balanced by a deferred Task. Keep the synthetic clock still until that
                // real endBatch has recorded idleSince and registered a live (not cancelled) unload grace.
                await until {r.unloadSleeps.activeCount>0}
                let graceStarted=r.unloadSleeps.activeCount>0
                check(graceStarted,"lease closure: final batch actually enters unload grace before advancing synthetic time")
                guard graceStarted else {await finish(r);return}
            }
            else {
                // Inside the five-minute MCP limit: release must happen before its decline guard.
                await r.writer.onDemand()
                check(await r.model.answers==firstAnswers,"lease \(condition): declined request releases without generating")
            }
            r.power.value = .ac;r.idle.value=0
            r.clock.advance(301)
            try moment(r,"release-second","Launch follow-up",ago:3)
            await r.writer.onDemand()
            let loads=await r.model.loads
            check(loads==2,"lease \(condition): release permits the unchanged idle grace to expire before the next cold load","loads=\(loads)")
            await finish(r)
        }
    }

    @MainActor static func leaseLifecycle() async throws {
        for transition in ["off","cloud","shutdown"] {
            let r=try await rig("lease-lifecycle-"+transition)
            await r.model.set(valid:true)
            try moment(r,"lifecycle","Launch plan",ago:3)
            try await on(r);await r.writer.onDemand()
            check(await r.model.loaded,"lease \(transition): weights initially warm")
            switch transition {
            case "off":
                r.writer.turnOff()
                await until {await r.model.unloads>0}
            case "cloud":
                let problem=await r.writer.chooseCloud(key:"synthetic-fixture-key")
                check(problem==nil,"lease: provider replacement uses only the fixture OpenRouter/key store")
                if case .on(.cloud)=r.writer.phase {check(true,"lease: cloud provider enabled")}
                else {check(false,"lease: cloud provider enabled","\(r.writer.phase)")}
            default:await r.writer.shutdown()
            }
            let loaded=await r.model.loaded,unloads=await r.model.unloads,loads=await r.model.loads
            check(!loaded && unloads==1 && loads==1,"lease \(transition): lifecycle unloads immediately without an extra load")
            await finish(r)
        }
    }

    @MainActor static func leaseAcquireReplacement() async throws {
        for path in ["MCP","timer"] {
            let r=try await rig("lease-acquire-replacement-"+path)
            await r.model.set(valid:true)
            let chosen=try moment(r,"race-old","Launch plan",ago:3)
            try await on(r)
            // An ordinary manual note leaves no persistent lease. A later acquire first awaits overdue unload.
            try await r.writer.generate(day:chosen.day,timezone:zone,activityID:chosen.id,lastActivity:r.clock.now.addingTimeInterval(-3))
            r.clock.advance(100);try pointer(r,"race-active",at:r.clock.now.addingTimeInterval(-3))
            await r.model.set(holdUnload:true)
            let oldRequest=Task {if path=="MCP" {await r.writer.onDemand()} else {await r.writer.pass(.timer)}}
            await until {await r.model.unloads>0}
            let suspended=await r.model.unloads>0
            check(suspended,"lease race: acquire suspended in the production overdue-unload boundary")
            guard suspended else {
                await r.model.set(holdUnload:false);await oldRequest.value;await finish(r);return
            }
            let replacement=FakeModel();await replacement.set(valid:true)
            r.writer.turnOff()
            r.modelChoice.value=replacement
            do {try await on(r)} catch {
                await r.model.set(holdUnload:false);await oldRequest.value;await finish(r);throw error
            }
            let newLoads=await replacement.loads,newAnswers=await replacement.answers
            check(newLoads==0 && newAnswers==0,"lease race: replacement becomes ready while old acquire is suspended, without loading")
            let replacementWake=r.writer.nextWake
            await r.model.set(holdUnload:false)
            await oldRequest.value
            check(r.writer.nextWake==replacementWake,"lease race \(path): stale acquire does not change replacement timer")
            check(await r.model.loads==1,"lease race \(path): stale acquire does not reload the retired runtime")
            r.clock.advance(301);try moment(r,"race-new-first","Launch replacement",ago:3)
            await r.writer.onDemand()
            let firstAnswers=await replacement.answers
            r.clock.advance(301);try moment(r,"race-new-second","Launch follow-up",ago:3)
            await r.writer.onDemand()
            let loads=await replacement.loads,answers=await replacement.answers
            check(loads==1 && answers>firstAnswers,"lease race: stale acquire cannot poison replacement lease; two new MCP batches retain one load")
            await finish(r)
        }
    }

    @MainActor static func leaseAcquireIdleTransition() async throws {
        let r=try await rig("lease-acquire-idle-transition")
        await r.model.set(valid:true)
        let chosen=try moment(r,"idle-race","Launch plan",ago:3)
        try await on(r)
        try await r.writer.generate(day:chosen.day,timezone:zone,activityID:chosen.id,lastActivity:r.clock.now.addingTimeInterval(-3))
        r.clock.advance(100);try pointer(r,"idle-race-active",at:r.clock.now.addingTimeInterval(-3))
        let beforeAnswers=await r.model.answers,beforeCommitted=r.writer.counters.committedNotes
        // With automatic dispatch disabled, no timer is installed: this models the fired timer's consumed state.
        check(r.writer.nextWake==nil,"lease idle race: dispatched timer starts with no future timer")
        await r.model.set(holdUnload:true)
        let running=Task {await r.writer.pass(.timer)}
        await until {await r.model.unloads>0}
        let suspended=await r.model.unloads>0
        check(suspended,"lease idle race: timer acquire suspended at production overdue-unload boundary")
        guard suspended else {
            await r.model.set(holdUnload:false);await running.value;await finish(r);return
        }
        // No input has arrived during these five minutes: the originally open moment must now close on idle.
        r.clock.advance(300);r.idle.value=300
        check(await r.model.answers==beforeAnswers,"lease idle race: suspension and idle transition do not generate")
        await r.model.set(holdUnload:false)
        await running.value
        let afterAnswers=await r.model.answers,afterLoads=await r.model.loads
        check(afterAnswers==beforeAnswers && afterLoads==1,"lease idle race: interrupted acquire releases without loading or generating")
        let retry=r.writer.nextWake
        check(retry.map {$0>r.clock.now && $0<=r.clock.now.addingTimeInterval(WriterIntegration.heldRetry)} ?? false,
              "lease idle race: same-provider interrupted acquire rearms a bounded future timer","\(String(describing:retry))")
        guard let retry,retry>r.clock.now else {await finish(r);return}
        let elapsed=retry.timeIntervalSince(r.clock.now)
        r.clock.set(retry);r.idle.value+=elapsed
        await r.writer.pass(.timer)
        let final=try mark(r,id:chosen.id),finalAnswers=await r.model.answers
        check(final["provisional"] as? Bool==false && r.writer.counters.committedNotes>beforeCommitted && finalAnswers>beforeAnswers,
              "lease idle race: rearmed timer freshly discovers idle closure and commits a real final note")
        await finish(r)
    }

    @MainActor static func leaseAcquireBatteryTransition() async throws {
        let r=try await rig("lease-acquire-battery-transition")
        await r.model.set(valid:true)
        try moment(r,"battery-history","Launch plan",ago:3)
        try await on(r);await r.writer.onDemand()
        let acceptedAt=r.clock.now,beforeAnswers=await r.model.answers,beforeBatches=r.writer.counters.onDemandBatches
        check(await r.model.loads==1 && beforeBatches==1,"lease battery race: one accepted AC MCP establishes recent history")
        r.clock.advance(1);r.idle.value=300
        await r.writer.onDemand() // Rate limited; release the persistent lease without inference.
        r.idle.value=0;r.clock.advance(301)
        for index in 0..<5 {try moment(r,"battery-candidate-\(index)","Window \(index)",ago:3+Double(index)*10)}
        let day=try DayScope.key(r.clock.now,timezone:zone)
        let source=WriterQueueSource(store:r.store)
        let found=try await source.discoverDay(day,now:r.clock.now,timezone:zone)
        check(found.open.count>=5,"lease battery race: at least five short open candidates exceed battery batch size")
        await r.model.set(holdUnload:true)
        let running=Task {await r.writer.onDemand()}
        await until {await r.model.unloads>0}
        let suspended=await r.model.unloads>0
        check(suspended,"lease battery race: AC request suspends in persistent acquire after its initial five-minute gate")
        guard suspended else {
            await r.model.set(holdUnload:false);await running.value;await finish(r);return
        }
        r.power.value = .battery // 80%: background eligible, but MCP spacing and batch size become battery's.
        await r.model.set(holdUnload:false);await running.value
        let declinedAnswers=await r.model.answers,declinedLoads=await r.model.loads
        check(declinedAnswers==beforeAnswers && declinedLoads==1 && r.writer.counters.onDemandBatches==beforeBatches,
              "lease battery race: fresh battery snapshot rejects the 302-second request without loading or generating")
        // The declined request must not have consumed the accepted-request timestamp.
        r.clock.set(acceptedAt.addingTimeInterval(901))
        for index in 0..<5 {try moment(r,"battery-eligible-\(index)","Followup \(index)",ago:3+Double(index)*10)}
        let beforeRuns=r.writer.counters.noteRuns
        await r.writer.onDemand()
        check(r.writer.counters.onDemandBatches==beforeBatches+1 && r.writer.counters.noteRuns-beforeRuns==WriterIntegration.onDemandBatteryNotes,
              "lease battery race: fifteen-minute eligibility uses the unchanged three-note battery batch","\(r.writer.counters)")
        check(WriterIntegration.onDemandBatteryNotes==3 && WriterIntegration.onDemandBatteryEvery==900,
              "lease battery race: production battery acceptance limits remain three notes and fifteen minutes")
        await finish(r)
    }

    @MainActor static func twentyMinutes() async throws {try await cadence("20-minute pointer",minutes:20)}
    @MainActor static func sixtyMinutes() async throws {try await cadence("60-minute pointer",minutes:60)}
}
