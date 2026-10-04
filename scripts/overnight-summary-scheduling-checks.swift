import Foundation
import AppKit
import CryptoKit
@testable import MemoryUI
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
    private var afterNextRead:T?
    func transitionAfterNextRead(to value:T) {lock.lock();afterNextRead=value;lock.unlock()}
    init(_ v: T) { _value = v }
    var value: T { get { lock.lock(); defer { lock.unlock() }; let current=_value;if let next=afterNextRead {_value=next;afterNextRead=nil};return current } set { lock.lock(); _value = newValue; lock.unlock() } }
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
    nonisolated let onLoad = Box<@Sendable () -> Void>({})
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
    var prompts:[(String,String)]=[]
    var reply:String?
    func set(reply:String) {self.reply=reply}
    var valid = false
    func set(valid: Bool) { self.valid = valid }
    var loadAttempts = 0
    func load() async throws { loadAttempts += 1; if failLoad { throw WriterFailure.unavailable }; loads += 1; loaded = true;onLoad.value() }
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
        prompts.append((instruction,evidence))
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
            let text=reply ?? "Drafted the launch checklist in TextEdit."
            return Data((#"{"title":"DayDream design","bullets":[{"ids":["# + ids.joined(separator: ",") + #"],"text":""# + text + #""}]}"#).utf8)
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

@main struct OvernightSummarySchedulingChecks {
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
        do {try await realisticSession()} catch {check(false,"realistic session","\(error)")}
        do {try await powerSnapshotTransition()} catch {check(false,"tick power transition","\(error)")}
        do {try await powerAcquireTransition()} catch {check(false,"tick acquire power transition","\(error)")}
        do {try await powerDuringLoad()} catch {check(false,"power during actual local load","\(error)")}
        check(WriterIntegration.typingBurst==3,"actual typing burst threshold is three seconds")
        print("overnight-summary-scheduling: \(passed) passed, \(failed) failed; synthetic clock/store/fake model only; ACTUAL_MODEL_UNVERIFIED; LIVE_UI_UNVERIFIED")
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
    @MainActor static func realisticSession() async throws {
        let r=try await rig("overnight-thirteen")
        let prompts=["Review the DayDream design and plan fixes.","Explain the summary queue.","Inspect the local writer scheduling.","Check the summary detail order.","Review the owner preview privacy gates.","Find the stale summary status.","Inspect the terminal request capture.","Plan the ten minute refresh.","Review the typed burst pause.","Explain safe model cancellation.","Keep every captured request visible.","Check the duplicate summary excerpts.","Summarize the DayDream design fixes."]
        let start=r.clock.now,day=try DayScope.key(start,timezone:zone)
        let reply="Asked Claude Code to review the DayDream design and plan fixes."
        await r.model.set(valid:true);await r.model.set(reply:reply)
        var ids:[String]=[]
        func addPrompt(_ index:Int) throws {
            let at=iso(r.clock.now),id="overnight-request-\(index)";ids.append(id)
            var e=Evidence(id:id,at:at,kind:"keyboard.text_input",app:"Ghostty",bundle:"com.mitchellh.ghostty",title:"daydream — claude",text:prompts[index],synthetic:true)
            e.captureProvenance=NativeCaptureProvenance(policyRevision:try r.store.policy().revision,classifierVersion:"sensitive-typing/v2",windowID:"synthetic-window",focusID:"synthetic-field",checkedAt:at,generation:1,unit:TypedUnitProvenance(runID:id,part:1,sealReason:"submit",startedAt:at,keys:nil,edits:nil,withheld:0,surface:"text",field:"terminal",send:"detected",sendBy:"return",to:"Claude Code"))
            guard try r.store.ingest(e,now:r.clock.now) else {throw MemError.invalid("fixture prompt refused")}
        }
        func history(_ store:MemoryStore,at:Date) throws -> [MomentDetailEntry] {
            let previews=try store.ownerSourceMomentPreviewsForActions(ids,now:at)
            return OwnerSourceMomentProjection.history(try ids.compactMap{try store.action($0,now:at)},previews:previews)
        }
        try addPrompt(0);try await on(r)
        let chosen=try r.store.dayLayers(day:day,timezone:zone,now:r.clock.now).activities.first{$0.actionIDs.contains(ids[0])}!
        // Advance actual captured requests at100-second intervals, with independent pointer activity.
        for second in stride(from:100,through:600,by:100) {
            r.clock.set(start.addingTimeInterval(Double(second)));try addPrompt(second/100)
            r.idle.value=0;r.typing.value=99
            await r.writer.pass(.timer)
            if second<600 {check(r.writer.counters.noteRuns==0,"timeline: no model note before10min at\(second)s")}
        }
        let atTen=try r.store.dayLayers(day:day,timezone:zone,now:r.clock.now).activities.first{$0.id==chosen.id}!
        check(r.writer.counters.committedNotes>0 && atTen.generated != nil,"timeline: validated fake-local model summary commits by10min while still open")
        check(atTen.generated?.output.generator.hasPrefix("local/")==true && !(atTen.generated?.output.generatorVersion.contains("fallback") ?? true),"timeline: committed note is fake model pipeline output rather than code fallback")
        check(try mark(r,id:chosen.id)["provisional"] as? Bool==true,"timeline:10min note is explicitly provisional")
        check(try history(r.store,at:r.clock.now).flatMap(\.typed).map(\.text)==Array(prompts.prefix(7)),"timeline: first seven actual captured prompts survive model-summary commit")
        let promptTen=await r.model.prompts
        check(promptTen.first.map{ pair in Array(prompts.prefix(7)).allSatisfy{pair.1.contains($0)} && pair.0.contains("Own captured requests")} ?? false,"timeline: real local hydration and instruction reflect all seven own requests at10min")
        for second in stride(from:700,through:1100,by:100) {r.clock.set(start.addingTimeInterval(Double(second)));try addPrompt(second/100);r.idle.value=0;await r.writer.pass(.timer)}
        r.clock.set(start.addingTimeInterval(1200));try addPrompt(12)
        let previews=try r.store.ownerSourceMomentPreviewsForActions(ids,now:r.clock.now)
        let excerpts=OwnerSourceMomentProjection.standIn(previews)
        check(excerpts.count==5 && Set(excerpts.map(\.text)).count==5 && excerpts.first?.text==prompts.last,"timeline:13prompt stand-in has <=5 distinct newest-first captured excerpts")
        let beforeFinal=try history(r.store,at:r.clock.now)
        check(beforeFinal.map(\.id)==ids && beforeFinal.flatMap(\.typed).map(\.text)==prompts,"timeline: What happened retains all13 chronological captured entries before final refresh")
        // Park the real prepared generation during an actual typing burst, then quit.
        r.typing.value=0
        let answersBefore=await r.model.answers
        let pending=Task {await r.writer.pass(.timer)}
        await until {await r.model.answers>answersBefore}
        check(await r.model.answers>answersBefore && r.model.pausePredicate.value(),"timeline: due20min generation reaches fake inference and pauses for actual typing")
        check(r.writer.counters.committedNotes==1,"timeline: paused generation has not falsely committed")
        let queueBefore=try entries(r)
        check(queueBefore.contains{$0["status"] as? String=="running"},"timeline: prepared20min request is durably running before shutdown")
        await r.writer.shutdown();await pending.value
        let persisted=try entries(r),savedMark=try mark(r,id:chosen.id)
        check(!persisted.isEmpty && persisted.allSatisfy{$0["status"] as? String != "running"},"timeline: shutdown saves recoverable queue state without a stranded running request")
        check(savedMark["provisional"] as? Bool==true,"timeline: persisted provisional10min note survives interrupted20min generation")
        let nextModel=FakeModel();await nextModel.set(valid:true);await nextModel.set(reply:reply)
        try FileManager.default.createDirectory(at:r.home.appendingPathComponent("Models"),withIntermediateDirectories:true)
        let reopened=try await rig("overnight-reopen",clock:r.clock,home:r.home,suite:r.suite,keys:r.keys,model:nextModel)
        if reopened.writer.phase != .on(.local) {try await on(reopened)}
        check(reopened.writer.phase == .on(.local),"timeline: saved local provider resumes offline on relaunch with fake admission")
        reopened.idle.value=0;reopened.typing.value=3
        await reopened.writer.pass(.timer)
        let atTwenty=try reopened.store.dayLayers(day:day,timezone:zone,now:reopened.clock.now).activities.first{$0.id==chosen.id}!
        check(atTwenty.generated?.actionIDs==ids && reopened.writer.counters.committedNotes>0,"timeline: recovered20min request commits exact all13action coverage")
        check(try history(reopened.store,at:reopened.clock.now).flatMap(\.typed).map(\.text)==prompts,"timeline: What happened keeps all13 words after recovered summary arrives")
        let promptTwenty=await nextModel.prompts
        check(promptTwenty.contains{p in prompts.allSatisfy{p.1.contains($0)}},"timeline: resumed actual model prompt contains all13 own captured requests")
        let firstLoads=await r.model.loads,nextLoads=await nextModel.loads
        check(firstLoads==1 && nextLoads==1,"timeline: continuous20min session uses one load per lifecycle, no ten-minute churn")
        let runs=reopened.writer.counters.noteRuns
        reopened.clock.advance(1)
        await reopened.writer.pass(.lock)
        let ended=try mark(reopened,id:chosen.id)
        check(reopened.writer.counters.noteRuns==runs+1 && ended["provisional"] as? Bool==false,"timeline: explicit end finalizes within5min at unchanged all13revision")
        check(try history(reopened.store,at:reopened.clock.now).map(\.id)==ids,"timeline: final close never removes any real action")
        await finish(reopened)
    }

    @MainActor static func powerSnapshotTransition() async throws {
        for gate in ["critical","serious","low-power","low-battery"] {
            let r=try await rig("tick-power-snapshot-"+gate)
            await r.model.set(valid:true)
            let chosen=try moment(r,"power-stale","Launch plan",ago:0)
            let first=try r.store.dayLayers(day:chosen.day,timezone:zone,now:r.clock.now).activities.first {$0.id==chosen.id}!
            let start=timestamp(first.start)!
            try await on(r)
            for minute in 1...10 {r.clock.set(start.addingTimeInterval(Double(minute)*60));try pointer(r,"power-stale-pointer-\(minute)")}
            var blocked=ModelPower.ac
            switch gate {
            case "critical":blocked.thermal=ProcessInfo.ThermalState.critical.rawValue
            case "serious":blocked.thermal=ProcessInfo.ThermalState.serious.rawValue
            case "low-power":blocked.lowPowerMode=true
            default:blocked.onPower=false;blocked.battery=19
            }
            r.power.transitionAfterNextRead(to:blocked)
            await r.writer.pass(.timer)
            let answers=await r.model.answers,loads=await r.model.loads
            check(answers==0 && loads==0,"power transition \(gate): current gate prevents due background load and inference","answers=\(answers) loads=\(loads)")
            check(r.writer.nextWake != nil,"power transition \(gate): held due note retains bounded timer")
            r.power.value = .ac
            await r.writer.pass(.power)
            check(r.writer.counters.noteRuns>0,"power transition \(gate): deferred due note runs after power permits")
            await finish(r)
        }
    }
    @MainActor static func powerAcquireTransition() async throws {
        let r=try await rig("tick-acquire-power-transition")
        await r.model.set(valid:true)
        let first=try moment(r,"acquire-first","Launch plan",ago:900)
        try await on(r)
        try await r.writer.generate(day:first.day,timezone:zone,activityID:first.id,lastActivity:r.clock.now.addingTimeInterval(-900))
        await until {r.unloadSleeps.activeCount>0}
        check(r.unloadSleeps.activeCount>0,"power acquire: first manual batch starts production idle grace")
        r.clock.advance(100);r.idle.value=300
        let second=try moment(r,"acquire-second","Final checklist",ago:300)
        check(second.id != first.id,"power acquire: fresh closed moment is separate canonical target")
        let before=await r.model.answers,beforeLoads=await r.model.loads
        await r.model.set(holdUnload:true)
        let running=Task {await r.writer.pass(.timer)}
        await until {await r.model.unloads>0}
        let held=await r.model.unloads>0
        check(held,"power acquire: actual ordinary batch waits at overdue unload boundary")
        guard held else {await r.model.set(holdUnload:false);await running.value;await finish(r);return}
        var critical=ModelPower.ac;critical.thermal=ProcessInfo.ThermalState.critical.rawValue;r.power.value=critical
        await r.model.set(holdUnload:false);await running.value
        let after=await r.model.answers,afterLoads=await r.model.loads
        check(after==before && afterLoads==beforeLoads,"power acquire: critical transition during suspended acquire cannot reload or infer")
        check(r.writer.nextWake != nil,"power acquire: balanced declined acquire keeps a future timer")
        r.power.value = .ac;await r.writer.pass(.power)
        let resumed=await r.model.answers
        check(resumed>before,"power acquire: queued closed target remains runnable after power resumes")
        await finish(r)
    }

    @MainActor static func powerDuringLoad() async throws {
        let r=try await rig("power-during-local-load")
        await r.model.set(valid:true)
        let chosen=try moment(r,"load-boundary","Launch plan",ago:0)
        let first=try r.store.dayLayers(day:chosen.day,timezone:zone,now:r.clock.now).activities.first {$0.id==chosen.id}!
        let start=timestamp(first.start)!
        try await on(r)
        for minute in 1...10 {r.clock.set(start.addingTimeInterval(Double(minute)*60));try pointer(r,"load-boundary-pointer-\(minute)")}
        r.model.onLoad.value={var p=ModelPower.ac;p.thermal=ProcessInfo.ThermalState.critical.rawValue;r.power.value=p}
        await r.writer.pass(.timer)
        let loads=await r.model.loads,answers=await r.model.answers,loaded=await r.model.loaded
        check(loads==1 && answers==0 && !loaded,"runtime boundary: critical power change inside actual local load unloads without any inference")
        check(r.writer.counters.committedNotes==0 && r.writer.phase == .on(.local),"runtime boundary: held automatic generation never claims a summary or failed model")
        check(try entries(r).contains{$0["status"] as? String=="retry"},"runtime boundary: power-held target remains persistently retryable")
        r.model.onLoad.value={};r.power.value = .ac
        await r.writer.pass(.power)
        check(r.writer.counters.committedNotes>0,"runtime boundary: current due target commits after power permits")
        await finish(r)
    }

}
