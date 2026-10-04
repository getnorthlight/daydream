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
/// A model that answers after `delay` (or waits until cancelled when `hang`), counting loads and answers.
actor FakeModel: LocalInference {
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
    func unload() async { unloads += 1; loaded = false }
    func generate(instruction: String, evidence: String, maxTokens: Int) async throws -> Data {
        try await generate(instruction: instruction, evidence: evidence, maxTokens: maxTokens, prefill: "")
    }
    func generate(instruction: String, evidence: String, maxTokens: Int, prefill: String) async throws -> Data {
        answers += 1
        if failCapacity { throw WriterFailure.capacity }
        while held { try await Task.sleep(nanoseconds: 10_000_000) }
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

@main struct WriterStateChecks {
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
        let clock: Clock, power: Box<ModelPower>, idle: Box<TimeInterval>, done: Box<Int>, defaults: UserDefaults, suite: String
        /// claude/catchup-1003: seconds since the last key press (the rig's, never the Mac's own keyboard): not typing.
        var typing = Box<TimeInterval>(1_000_000)
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
        let power = Box(ModelPower.ac), idle = Box<TimeInterval>(0), done = Box(0)
        let suite = reuseSuite ?? "writer-state-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        var env = WriterEnvironment()
        let typing = Box<TimeInterval>(1_000_000)
        env.now = { clock.now }; env.power = { power.value }; env.idleSeconds = { idle.value }; env.typingSeconds = { typing.value }
        env.defaults = defaults; env.makeRuntime = { _ in model }; env.postDone = { done.value += 1 }; env.automatic = false
        env.unloadSleep = { _ in try await Task.sleep(nanoseconds: 1_000_000_000_000) }
        let fake = files(home)
        var local = admission ?? LocalAdmission(restoreOffline: { _, _ in fake }, checkWithApple: {}, signedBuild: { false })
        if admission == nil { local.download = { _, progress in progress(.downloading(1, 2)); progress(.downloading(2, 2)); return fake } }
        let writer = WriterIntegration(modelRoot: home.appendingPathComponent("Models"), keyStore: keys, send: { try await http.send($0) }, admission: local, environment: env)
        writer.offerLocal = true
        writer.configure(store: store)
        for _ in 0..<300 where writer.busy { await sleep(0.02) }
        return Rig(home: home, store: store, writer: writer, model: model, http: http, keys: keys, clock: clock, power: power, idle: idle, done: done, defaults: defaults, suite: suite, typing: typing)
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
        setvbuf(stdout, nil, _IOLBF, 0)
        let base = ProcessInfo.processInfo.environment["STATE_CHECK_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        root = base.appendingPathComponent("writer-state-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        CloudWriter.retryDelays = [0.01, 0.01]
        let all: [(String, @MainActor () async throws -> Void)] = [
            ("failure lines", failureLines), ("model hash", modelHash), ("off during a note", offDuringNote),
            ("closed windows during the download", downloadWithoutWindows), ("cancel then on", cancelThenOn),
            ("bad download", badDownload), ("Apple check", appleCheck), ("relaunch mid-download", relaunchMidDownload),
            ("relaunch after a stopped download", relaunchAfterStop),
            ("model won't start", modelWontStart), ("closed moments only", closedOnly), ("battery", battery), ("on demand", onDemand),
            ("cloud key test", cloudKeyTest), ("cloud note failures", cloudNoteFailures), ("cloud cutoff kept", cloudCutoffKept),
            ("no spin while the writer is held", heldNoSpin), ("Summarize Now and rewrites", resummarize),
            ("Summarize Now during a long batch", clickDuringLongBatch),
            ("OpenRouter during a download", cloudDuringDownload),
            ("no spin while busy", noSpinWhileBusy), ("key during a download", keyDuringDownload), ("old cloud notice", oldCloudNotice),
            ("on demand on battery", onDemandBattery), ("memory problem", memoryProblem),
            ("writing only while queued", writingForever), ("today's moment always gets a place", queueRoom),
            ("a moment set aside by an earlier build", recoverSetAside),
            ("a revoked key across midnight", revokedAcrossMidnight),
            ("local overdue during typing", overdueDuringTyping), ("local overdue power guard", overduePowerGuard),
            ("past rewrite cooldown", catchUpRewriteCooldown), ("empty catch-up quiet", catchUpEmptyQuiet),
            ("catch-up beside today's rewrites", catchUpBesideTodayRewrites), ("catch-up never while typing", catchUpNotWhileTyping),
            ("writer version refresh", writerVersionRefresh),
        ]
        let focused = Set(["writer version refresh", "past rewrite cooldown", "Summarize Now and rewrites"])
        let selected = CommandLine.arguments.contains("--only-regeneration") ? all.filter { focused.contains($0.0) } : all
        for (name, run) in selected {
            do { try await run() } catch { check(false, name, "\(error)") }
        }
        print("writer-state: \(passed) passed, \(failed) failed")
        if failed > 0 { try? FileManager.default.removeItem(at: root); exit(1) }
    }

    /// The older writer saved its mark just after committing its note. The
    /// current writer must refresh it once, stamp that attempt and keep the stamp
    /// through relaunch, rather than infer writer identity from timestamps.
    @MainActor static func writerVersionRefresh() async throws {
        for capacity in [false, true] {
        let name = capacity ? "version-refresh-final" : "version-refresh-commit"
        let first = try await rig(name)
        await first.model.set(failCapacity: capacity)
        try await on(first)
        let m = try moment(first, "vr", "Launch worksheet", ago: 3000)
        let request = try first.store.prepareNote(kind: "activity", day: m.day, timezone: zone, activityID: m.id, now: first.clock.now)
        _ = try first.store.commitNote(NoteWriterOutput(requestID: request.id, title: "Launch worksheet",
            bullets: [NoteBullet(text: "Worked in TextEdit.", actionIDs: request.actions.map(\.id), assertion: "interpretation")],
            generator: "fixture", generatorVersion: "qwen35-4b-q4-b9723-prompt9-validator11"), now: first.clock.now)
        let key = ["activity", m.day, zone, m.id].joined(separator: "\u{1f}")
        let revision = try "\(request.inputRevision)|\(first.store.policy().revision)|local"
        await finish(first)
        let file = first.home.appendingPathComponent("WriterScheduling/pending-v1.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var marks = json["written"] as? [String: Any] ?? [:]
        marks[key] = ["actions": request.actionCount, "typed": 0,
            "at": first.clock.now.addingTimeInterval(0.1).timeIntervalSinceReferenceDate,
            "provisional": false, "skipped": false, "revision": revision, "writes": 3]
        json["written"] = marks
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let current = try await rig(name, clock: first.clock, home: first.home, suite: first.suite, keys: first.keys, model: first.model)
        try await on(current)
        current.idle.value = WriterIntegration.idleClose
        let before = current.writer.counters.noteRuns
        await current.writer.pass(.timer)
        let after = current.writer.counters.noteRuns
        let note = try current.store.dayLayers(day: m.day, timezone: zone, now: current.clock.now).activities.first { $0.id == m.id }
        let expectedStatus = capacity ? "pending" : "ready"
        check(after == before + 1 && note?.status == expectedStatus, "actual writer attempts legacy after-note mark once (" + name + ")", "\(before)->\(after), \(note?.status ?? "?")")
        let saved = (try ledger(current)["written"] as? [String: [String: Any]])?[key]
        check(saved?["writerRevision"] as? String == WriterQueueSource.writerRevision, "actual writer attempt persists current writer version stamp")
        // Distinguish a stored current note from a terminal capacity refusal.
        if capacity {
            check(saved?["fallback"] as? Bool == true && saved?["skipped"] as? Bool == true, "terminal capacity refusal persists a final stamp without claiming a new note")
        } else {
            check(note?.generated?.inputRevision == request.inputRevision && NoteWriterVersions.current.contains(note?.generated?.output.generatorVersion ?? ""), "automatic upgrade stores a current canonical note for the same evidence")
        }
        await finish(current)
        let reopened = try await rig(name, clock: first.clock, home: first.home, suite: first.suite, keys: first.keys, model: first.model)
        try await on(reopened)
        reopened.idle.value = WriterIntegration.idleClose
        let retained = (try ledger(reopened)["written"] as? [String: [String: Any]])?[key]
        check(retained?["writerRevision"] as? String == WriterQueueSource.writerRevision, "actual writer version stamp survives relaunch")
        await reopened.writer.pass(.timer)
        check(reopened.writer.counters.noteRuns == 0, "actual writer never loops after same-revision refresh and relaunch")
        await finish(reopened)
        }
    }

    /// fix/summary-fallback (QF-16): a moment an earlier build set aside because every answer failed (its mark says skipped,
    /// with no `fallback`: pending for good, no note) is written once more by this build, then never again at that revision.
    @MainActor static func recoverSetAside() async throws {
        let first = try await rig("recover")
        try await on(first)
        let m = try moment(first, "rc", "Launch memo", ago: 3000)
        let key = ["activity", m.day, zone, m.id].joined(separator: "\u{1f}")
        let revision = try "\(first.store.dayLayers(day: m.day, timezone: zone, now: first.clock.now).activities.first { $0.id == m.id }!.inputRevision)|\(first.store.policy().revision)|local"
        await finish(first)
        // The mark an earlier build left: set aside at this same revision, 40 minutes ago, with no fallback field.
        let file = first.home.appendingPathComponent("WriterScheduling/pending-v1.json")
        var json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]) ?? ["version": 1, "entries": [Any]()]
        var written = json["written"] as? [String: Any] ?? [:]
        written[key] = ["actions": 3, "typed": 0, "at": first.clock.now.addingTimeInterval(-2400).timeIntervalSinceReferenceDate, "provisional": false,
                        "skipped": true, "revision": revision, "writes": 0]
        json["written"] = written
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let rig = try await Self.rig("recover", clock: first.clock, home: first.home, suite: first.suite, keys: first.keys, model: first.model)
        try await on(rig)
        check(rig.writer.skippedMoments.isEmpty, "legacy set-aside mark is recoverable, never published as permanently skipped", "\(rig.writer.skippedMoments)")
        let before = await rig.model.answers
        await rig.writer.pass(.timer)
        let after = await rig.model.answers
        let status = try rig.store.dayLayers(day: m.day, timezone: zone, now: rig.clock.now).activities.first { $0.id == m.id }?.status
        check(after > before && status == "ready", "a moment an earlier build set aside is written once more (it now gets at least the fallback note)",
              "answers \(before)->\(after), status \(status ?? "?")")
        rig.clock.advance(WriterQueueSource.rewriteAfter + 60)
        await rig.writer.pass(.timer)
        let final = await rig.model.answers
        check(final == after, "and not again", "answers \(final)")
        await finish(rig)
    }

    /// A past-day moment due after the rewrite cooldown is not an empty history. The REAL source discovers
    /// its deadline and the REAL writer must revisit it, preserving the power/load gates and single-write rule.
    /// Real integration, continuous activity (zero idle), no model/network or app lifecycle.
    @MainActor static func overdueDuringTyping() async throws {
        let r = try await rig("overdue-typing")
        defer { r.defaults.removePersistentDomain(forName: r.suite) }
        try await on(r)
        _ = try moment(r, "overdue-first", "First draft")
        await r.writer.pass(.explicit)
        let before = await r.model.answers
        r.clock.advance(60)
        _ = try moment(r, "overdue-second", "Second draft", ago: 601)
        r.idle.value = 0
        await r.writer.pass(.power)
        check(await r.model.answers == before, "overdue: cadence holds a newly queued closed moment during typing")
        let queuedAt = r.clock.now
        check(r.writer.nextWake == queuedAt.addingTimeInterval(WriterIntegration.overdueAfter), "overdue: one timer targets bounded deadline")
        r.clock.advance(WriterIntegration.overdueAfter - 1)
        await r.writer.pass(.power)
        check(await r.model.answers == before, "overdue: no inference before deadline")
        r.clock.advance(1)
        await r.writer.pass(.timer)
        check(await r.model.answers > before, "overdue: closed queued moment runs at five minutes with zero idle")
        await finish(r)
    }
    @MainActor static func overduePowerGuard() async throws {
        let r = try await rig("overdue-power")
        defer { r.defaults.removePersistentDomain(forName: r.suite) }
        try await on(r)
        r.power.value = ModelPower(onPower: false, lowPowerMode: false, thermal: 0, battery: 15)
        _ = try moment(r, "overdue-low", "Battery draft")
        await r.writer.pass(.power)
        r.clock.advance(WriterIntegration.overdueAfter + 1)
        await r.writer.pass(.timer)
        check(await r.model.answers == 0, "overdue: low battery still prohibits background inference")
        r.power.value = .ac
        await r.writer.pass(.power)
        check(await r.model.answers > 0, "overdue: power recovery runs waiting closed moment without idle")
        await finish(r)
    }
    @MainActor static func catchUpRewriteCooldown() async throws {
        // Keep the simulated deadline before wall time: CoreWriterBinding prepares real five-minute expiries.
        let now = Date().addingTimeInterval(-3600)
        let first = try await rig("past-cooldown", clock: Clock(now))
        try await on(first)
        let yesterdayEnd = Calendar.current.startOfDay(for: now).addingTimeInterval(-900)
        let m = try moment(first, "pc", "Release outline", ago: now.timeIntervalSince(yesterdayEnd))
        check(m.day != (try DayScope.key(now, timezone: zone)), "past cooldown fixture belongs to yesterday")
        let key = ["activity", m.day, zone, m.id].joined(separator: "\u{1f}")
        let revision = try "\(first.store.dayLayers(day: m.day, timezone: zone, now: now).activities.first { $0.id == m.id }!.inputRevision)|\(first.store.policy().revision)|local"
        await finish(first)
        let markedAt = now.addingTimeInterval(-600), due = markedAt.addingTimeInterval(WriterQueueSource.rewriteAfter)
        let file = first.home.appendingPathComponent("WriterScheduling/pending-v1.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var written = json["written"] as? [String: Any] ?? [:]
        written[key] = ["actions": 3, "typed": 0, "at": markedAt.timeIntervalSinceReferenceDate,
                        "provisional": false, "skipped": true, "revision": revision, "writes": 0]
        json["written"] = written
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let rig = try await Self.rig("past-cooldown", clock: first.clock, home: first.home, suite: first.suite, keys: first.keys, model: first.model)
        try await on(rig)
        let source = WriterQueueSource(store: rig.store)
        let mark = WrittenMark(actions: 3, typed: 0, at: markedAt, skipped: true, revision: revision, writes: 0)
        let discovered = try await source.discoverDay(m.day, now: now, timezone: zone, marks: [key: mark])
        check(discovered.targets.isEmpty && discovered.nextRewrite == due,
              "past cooldown has a real future rewrite, no due target yet")
        rig.idle.value = WriterIntegration.idleClose
        let before = rig.writer.counters.noteRuns
        await rig.writer.pass(.timer)
        check(rig.writer.counters.noteRuns == before, "past cooldown never rewrites early")
        check(rig.writer.nextWake == due, "next wake honors the past rewrite deadline and five-minute floor", "\(String(describing: rig.writer.nextWake)) vs \(due)")
        rig.clock.set(due.addingTimeInterval(-1))
        await rig.writer.pass(.explicit)
        check(rig.writer.counters.noteRuns == before, "one second before past cooldown: still no rewrite")
        rig.clock.set(due)
        var blocked = ModelPower.battery; blocked.lowPowerMode = true
        rig.power.value = blocked
        await rig.writer.pass(.power)
        check(rig.writer.counters.noteRuns == before, "due past rewrite obeys Low Power Mode")
        blocked.lowPowerMode = false; blocked.battery = 19; rig.power.value = blocked
        await rig.writer.pass(.power)
        check(rig.writer.counters.noteRuns == before, "due past rewrite obeys the battery 20-percent floor")
        rig.power.value = ModelPower.battery
        await rig.writer.pass(.power)
        let after = rig.writer.counters.noteRuns
        let status = try rig.store.dayLayers(day: m.day, timezone: zone, now: rig.clock.now).activities.first { $0.id == m.id }?.status
        check(after == before + 1 && status == "ready", "past rewrite runs once when due and power permits", "\(before)->\(after), \(status ?? "?")")
        rig.clock.advance(WriterIntegration.batchEvery)
        await rig.writer.pass(.timer)
        check(rig.writer.counters.noteRuns == after, "same past revision is not rewritten again")
        check(await rig.model.loads <= WriterIntegration.loadsPerHour, "past rewrite retains the hourly load cap")
        await finish(rig)
    }
    /// A genuinely empty scan keeps its six-hour discovery hold. A new isolated past row demonstrates that
    /// ordinary passes do not quietly shorten the hold; it is found once that hold expires.
    @MainActor static func catchUpEmptyQuiet() async throws {
        let rig = try await rig("empty-catchup", clock: Clock(Date().addingTimeInterval(-7 * 3600)))
        try await on(rig)
        rig.idle.value = WriterIntegration.idleClose
        let start = rig.clock.now
        await rig.writer.pass(.timer)
        let before = rig.writer.counters.noteRuns
        let pastEnd = Calendar.current.startOfDay(for: start).addingTimeInterval(-900)
        let m = try moment(rig, "eq", "Release checklist", ago: start.timeIntervalSince(pastEnd))
        rig.clock.advance(WriterIntegration.batchEvery)
        await rig.writer.pass(.timer)
        check(rig.writer.counters.noteRuns == before, "genuinely empty catch-up retains six-hour quiet")
        rig.clock.set(start.addingTimeInterval(6 * 3600))
        await rig.writer.pass(.timer)
        let status = try rig.store.dayLayers(day: m.day, timezone: zone, now: rig.clock.now).activities.first { $0.id == m.id }?.status
        let loads = await rig.model.loads
        check(rig.writer.counters.noteRuns == before + 1 && status == "ready", "empty catch-up discovers new isolated past work after quiet expires", "runs \(before)->\(rig.writer.counters.noteRuns), status \(status ?? "?"), phase \(rig.writer.phase), loads \(loads)")
        await finish(rig)
    }
    /// claude/catchup-1003: past days used to wait until today had nothing left, and today's version-bump rewrites (or an
    /// open moment) kept "today" busy for hours, so yesterday stayed "Summarizing…". Now a past moment is written while
    /// the person uses the Mac (not typing), after today's closed first notes; today's rewrites don't hold it back.
    static func pastMoment(_ r: Rig, _ id: String, before: TimeInterval = 900) throws -> (day: String, id: String) {
        let pastEnd = Calendar.current.startOfDay(for: r.clock.now).addingTimeInterval(-before)
        return try moment(r, id, "Packing list \(id)", ago: r.clock.now.timeIntervalSince(pastEnd))
    }
    static func status(_ r: Rig, _ m: (day: String, id: String)) -> String? {
        (try? r.store.dayLayers(day: m.day, timezone: zone, now: r.clock.now))?.activities.first { $0.id == m.id }?.status
    }
    @MainActor static func catchUpBesideTodayRewrites() async throws {
        let r = try await rig("catchup-rewrites")
        defer { r.defaults.removePersistentDomain(forName: r.suite) }
        // Today: 13 closed moments an earlier writer version wrote (each due a rewrite); yesterday: one never written.
        var today: [(day: String, id: String)] = []
        for i in 0..<13 { today.append(try moment(r, "rw\(i)", "Draft \(i)", ago: Double(1800 - i * 60))) }
        for m in today {
            let request = try r.store.prepareNote(kind: "activity", day: m.day, timezone: zone, activityID: m.id, now: r.clock.now)
            _ = try r.store.commitNote(NoteWriterOutput(requestID: request.id, title: "Draft", bullets: [NoteBullet(text: "Typed a draft in TextEdit.", actionIDs: request.actions.map(\.id), assertion: "observed")],
                                                        generator: "local/synthetic", generatorVersion: "qwen35-4b-q4-b9723-prompt1-validator1"), now: r.clock.now)
        }
        let past = try pastMoment(r, "cr")
        check(today.allSatisfy { status(r, $0) == "pending" } && (status(r, past)) == "pending", "fixture: today's 13 notes are an earlier writer's; yesterday's moment has none")
        try await on(r)
        r.idle.value = 0
        await r.writer.pass(.timer)
        let loads = await r.model.loads
        check(status(r, past) == "ready", "catch-up: yesterday is written while today's version-bump rewrites remain (person active, not typing)",
              "\(status(r, past) ?? "?"), catch-up notes \(r.writer.counters.catchUpNotes), runs \(r.writer.counters.noteRuns), today \(today.map { status(r, $0) ?? "?" }), phase \(r.writer.phase), loads \(loads)")
        await finish(r)
    }
    @MainActor static func catchUpNotWhileTyping() async throws {
        let r = try await rig("catchup-typing")
        defer { r.defaults.removePersistentDomain(forName: r.suite) }
        let past = try pastMoment(r, "ct")
        try await on(r)
        r.idle.value = WriterIntegration.idleClose
        r.typing.value = 0.5
        await r.writer.pass(.timer)
        check(status(r, past) == "pending" && r.writer.counters.catchUpNotes == 0, "catch-up: nothing past is written while the person is typing")
        r.typing.value = WriterIntegration.typingBurst
        r.clock.advance(WriterIntegration.typingBurst)
        await r.writer.pass(.timer)
        check(status(r, past) == "ready", "catch-up: it runs once typing has been quiet", "\(status(r, past) ?? "?")")
        // On battery: past days at most every 30 minutes.
        let second = try pastMoment(r, "ct2", before: 4 * 3600)
        r.power.value = .battery
        r.clock.advance(WriterIntegration.batchEvery)
        await r.writer.pass(.timer)
        check(status(r, second) == "pending", "catch-up on battery: not again within 30 minutes")
        r.clock.advance(WriterIntegration.catchUpBatteryEvery - WriterIntegration.batchEvery + 1)
        await r.writer.pass(.timer)
        check(status(r, second) == "ready", "catch-up on battery: again after 30 minutes", "\(status(r, second) ?? "?")")
        await finish(r)
    }
    /// Every setup failure line has its problem (one line, one button), and every failure maps to one.
    @MainActor static func failureLines() async throws {
        let rig = try await rig("lines")
        let errors: [Error] = [WriterFailure.busy, WriterFailure.integrity, WriterFailure.capacity, WriterFailure.trustEvidenceUnavailable,
                               DownloadDamaged(), URLError(.networkConnectionLost), WriterFailure.unavailable, CancellationError()]
        let unmapped = errors.map { rig.writer.setupFailureStatus($0) }.filter { WriterIntegration.problem(forStatus: $0) == nil }
        check(unmapped.isEmpty, "every setup failure line maps to one problem and its button", "\(unmapped)")
        check(WriterIntegration.problem(DownloadDamaged(), stage: .download) == .badDownload
              && WriterIntegration.problem(WriterFailure.capacity, stage: .download) == .noSpace
              && WriterIntegration.problem(URLError(.networkConnectionLost), stage: .download) == .downloadStopped
              && WriterIntegration.problem(WriterFailure.trustEvidenceUnavailable, stage: .check) == .appleCheck
              && WriterIntegration.problem(WriterFailure.unavailable, stage: .load) == .modelWontStart,
              "download, space, damaged file, Apple check and model failures each get their own problem")
        // A signed app in a folder its runtime refuses (SignedRuntimeLoader.safePath): one short line of its own.
        check(WriterIntegration.problem(forStatus: SummaryProblem.moveApp.line) == .moveApp
              && SummaryProblem.moveApp.line == "Move DayDream to Applications to use summaries on this Mac."
              && WriterIntegration.setupFailureLines.filter { $0.problem == .moveApp }.count == 1
              && !WriterIntegration.appLocationBlocksRuntime,
              "app location: its own setup line and problem; an unsigned check build is never blocked by it")
        await finish(rig)
    }
    /// D: the model file is hashed once per identity; an unchanged file is never hashed again, a changed one is.
    @MainActor static func modelHash() async throws {
        let file = root.appendingPathComponent("tiny.model")
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        try bytes.write(to: file)
        let hash = SHA256Hex.of(bytes)
        let before = ModelIdentity.fullHashes
        try ModelIdentity.verify(file, bytes: Int64(bytes.count), hash: hash)
        try ModelIdentity.verify(file, bytes: Int64(bytes.count), hash: hash)
        try ModelIdentity.verify(file, bytes: Int64(bytes.count), hash: hash)
        check(ModelIdentity.fullHashes - before == 1, "the model is hashed once, then each load checks only its identity", "\(ModelIdentity.fullHashes - before) full hashes")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: file.path)
        try ModelIdentity.verify(file, bytes: Int64(bytes.count), hash: hash)
        check(ModelIdentity.fullHashes - before == 2, "a changed model file is hashed again")
    }
    /// Off while a note is being written: `.off` before turnOff returns, the model unloaded, nothing marked cancelled.
    @MainActor static func offDuringNote() async throws {
        let rig = try await rig("off-note")
        try await on(rig)
        let target = try moment(rig, "off", "Budget draft")
        await rig.model.set(hang: true)
        let note = Task { try await rig.writer.generate(day: target.day, timezone: zone, activityID: target.id, lastActivity: rig.clock.now.addingTimeInterval(-900)) }
        for _ in 0..<200 where await rig.model.answers == 0 { await sleep(0.01) }
        rig.writer.turnOff()
        let same = rig.writer.phase == .off && rig.writer.provider == "off" && !rig.writer.busy
        check(same, "Off during a note: off in the same turn, and never shown busy", "\(rig.writer.phase) \(rig.writer.provider) busy \(rig.writer.busy)")
        _ = try? await note.value
        await rig.writer.disableCloud()   // waits for the stop to finish
        let loaded = await rig.model.loaded
        check(!loaded, "Off during a note: the model is unloaded")
        let states = try statuses(rig)
        check(!states.contains("cancelled") && !states.contains("running"), "Off during a note: nothing queued is marked cancelled", "\(states)")
        check(rig.defaults.string(forKey: WriterIntegration.intentKey) == "off", "Off is saved as the choice")
        await finish(rig)
    }
    /// B: the download finishes and summaries turn on with no window open; progress is published at most once a second.
    @MainActor static func downloadWithoutWindows() async throws {
        let total: Int64 = 2_740_000_000
        let gate = Box(false)
        var admission = LocalAdmission(restoreOffline: { _, _ in throw WriterFailure.unavailable }, checkWithApple: {}, signedBuild: { false })
        let home = root.appendingPathComponent("no-windows")
        let fake = files(home)
        admission.download = { _, progress in
            var received: Int64 = 0
            while received < total { received = min(total, received + 1_048_576); progress(.downloading(received, total)) }
            while !gate.value { try await Task.sleep(nanoseconds: 10_000_000) }
            return fake
        }
        let rig = try await rig("no-windows", admission: admission)
        var phases = 0
        let sink = rig.writer.$phase.sink { _ in phases += 1 }
        rig.writer.chooseLocal()
        check(rig.writer.busy, "the download shows at once (busy while downloading)")
        for _ in 0..<200 { if case .downloading = rig.writer.phase { break }; await sleep(0.01) }
        await sleep(0.3)
        check(phases < 40, "download progress is published at most once a second or every 0.1 GB", "\(phases) phase changes for 2,613 pieces")
        check(rig.defaults.string(forKey: WriterIntegration.intentKey) == "local", "the choice is saved before the download ends")
        gate.value = true
        for _ in 0..<300 { if case .on = rig.writer.phase { break }; await sleep(0.02) }
        check(rig.writer.phase == .on(.local) && rig.writer.provider == "local" && rig.writer.modelOnMac && !rig.writer.busy,
              "with no window open, the finished download turns summaries on this Mac on", "\(rig.writer.phase)")
        sink.cancel()
        await finish(rig)
    }
    /// Cancel, then On at once: the queue drains, nothing is stranded, one model.
    @MainActor static func cancelThenOn() async throws {
        let rig = try await rig("cancel-on")
        try await on(rig)
        let target = try moment(rig, "c", "Invoice notes")
        await rig.model.set(hang: true)
        let note = Task { try await rig.writer.generate(day: target.day, timezone: zone, activityID: target.id, lastActivity: rig.clock.now.addingTimeInterval(-900)) }
        for _ in 0..<200 where await rig.model.answers == 0 { await sleep(0.01) }
        rig.writer.cancel()
        await rig.model.set(hang: false)
        rig.writer.chooseLocal()
        _ = try? await note.value
        for _ in 0..<300 { if case .on(.local) = rig.writer.phase, rig.writer.provider == "local" { break }; await sleep(0.02) }
        check(rig.writer.phase == .on(.local), "Cancel then On: summaries are on again", "\(rig.writer.phase)")
        await rig.writer.pass(.explicit)
        let states = try statuses(rig)
        check(!states.contains("cancelled") && !states.contains("running") && !states.contains("queued") && !states.contains("retry"),
              "Cancel then On: the moment is written again, nothing stranded", "\(states)")
        await finish(rig)
    }
    /// C: a whole download whose hash is wrong: the partial file is deleted and the line says the download was damaged.
    @MainActor static func badDownload() async throws {
        let home = root.appendingPathComponent("bad-hash")
        let asset = PinnedAsset(url: URL(string: "https://example.invalid/model")!, bytes: 3_000_000, sha256: String(repeating: "a", count: 64))
        var admission = LocalAdmission(restoreOffline: { _, _ in throw WriterFailure.unavailable }, checkWithApple: {}, signedBuild: { true })
        admission.download = { root, progress in
            _ = try await PersistentModelCache.acquire(asset: asset, root: root, priorRoots: [], chunks: { _, offset in
                AsyncThrowingStream { c in
                    var left = asset.bytes - offset
                    while left > 0 { let n = Int(min(left, 1_048_576)); c.yield(Data(count: n)); left -= Int64(n) }
                    c.finish()
                }
            }, progress: progress)
            return nil
        }
        let rig = try await rig("bad-hash", admission: admission)
        rig.writer.chooseLocal()
        for _ in 0..<300 { if case .failed = rig.writer.phase { break }; await sleep(0.02) }
        let partial = home.appendingPathComponent("Models/" + asset.sha256 + ".partial")
        check(rig.writer.phase == .failed(.badDownload) && !FileManager.default.fileExists(atPath: partial.path) && !rig.writer.modelOnMac,
              "a damaged download: the partial file is deleted and it says so, with Try Again", "\(rig.writer.phase) partial kept \(FileManager.default.fileExists(atPath: partial.path))")
        await finish(rig)
    }
    /// C: the model downloaded and matched its hash, but Apple couldn't be asked: the Apple-check line, model on this Mac.
    @MainActor static func appleCheck() async throws {
        var admission = LocalAdmission(restoreOffline: { _, _ in throw WriterFailure.trustEvidenceUnavailable },
                                       checkWithApple: { throw URLError(.notConnectedToInternet) }, signedBuild: { true })
        admission.download = { _, progress in progress(.downloading(10, 10)); return nil }
        let rig = try await rig("apple", admission: admission)
        rig.writer.chooseLocal()
        for _ in 0..<300 { if case .failed = rig.writer.phase { break }; await sleep(0.02) }
        check(rig.writer.phase == .failed(.appleCheck) && rig.writer.modelOnMac, "Apple check failed: its own line, and the model counts as on this Mac", "\(rig.writer.phase) modelOnMac \(rig.writer.modelOnMac)")
        await finish(rig)
    }
    /// B: quit mid-download, relaunch: the saved choice shows as being checked (never off) and the download finishes on.
    @MainActor static func relaunchMidDownload() async throws {
        let home = root.appendingPathComponent("relaunch")
        let fake = files(home)
        var hanging = LocalAdmission(restoreOffline: { _, _ in throw WriterFailure.unavailable }, checkWithApple: {}, signedBuild: { false })
        hanging.download = { _, progress in progress(.downloading(5, 10)); while true { try await Task.sleep(nanoseconds: 10_000_000) } }
        let first = try await rig("relaunch", admission: hanging)
        first.writer.chooseLocal()
        for _ in 0..<200 { if case .downloading = first.writer.phase { break }; await sleep(0.01) }
        await first.writer.shutdown()
        var finishing = LocalAdmission(restoreOffline: { _, _ in throw WriterFailure.unavailable }, checkWithApple: {}, signedBuild: { false })
        finishing.download = { _, progress in progress(.downloading(10, 10)); return fake }
        let second = try await rig("relaunch", admission: finishing, home: home, suite: first.suite)
        var sawOff = false
        let sink = second.writer.$phase.dropFirst().sink { if $0 == .off { sawOff = true } }
        for _ in 0..<300 { if case .on = second.writer.phase { break }; await sleep(0.02) }
        check(second.writer.phase == .on(.local) && !sawOff, "relaunch mid-download: never shown off, the download finishes and summaries turn on", "\(second.writer.phase) sawOff \(sawOff)")
        sink.cancel()
        await finish(second)
    }
    /// fix/model-download: a download that stopped (after its own retries) is tried again at the next launch from the
    /// partial file: never "the model couldn't start", never off.
    @MainActor static func relaunchAfterStop() async throws {
        let home = root.appendingPathComponent("relaunch-stop")
        let fake = files(home)
        var stopping = LocalAdmission(restoreOffline: { _, _ in throw WriterFailure.unavailable }, checkWithApple: {}, signedBuild: { false })
        stopping.download = { _, progress in progress(.downloading(5, 10)); throw URLError(.networkConnectionLost) }
        let first = try await rig("relaunch-stop", admission: stopping)
        first.writer.chooseLocal()
        for _ in 0..<300 { if case .failed = first.writer.phase { break }; await sleep(0.01) }
        check(first.writer.phase == .failed(.downloadStopped) && first.defaults.bool(forKey: WriterIntegration.downloadingKey),
              "a stopped download says so, and the download mark stays for the next launch", "\(first.writer.phase)")
        await first.writer.shutdown()
        var finishing = LocalAdmission(restoreOffline: { _, _ in throw WriterFailure.unavailable }, checkWithApple: {}, signedBuild: { false })
        finishing.download = { _, progress in progress(.downloading(10, 10)); return fake }
        let second = try await rig("relaunch-stop", admission: finishing, home: home, suite: first.suite)
        var sawProblem = false
        let sink = second.writer.$phase.dropFirst().sink { if $0 == .off || $0 == .failed(.modelWontStart) { sawProblem = true } }
        for _ in 0..<300 { if case .on = second.writer.phase { break }; await sleep(0.02) }
        check(second.writer.phase == .on(.local) && !sawProblem && !second.defaults.bool(forKey: WriterIntegration.downloadingKey),
              "relaunch after a stopped download: tried again, finishes, summaries turn on (never off or 'couldn't start')", "\(second.writer.phase) problem \(sawProblem)")
        sink.cancel()
        await finish(second)
    }
    /// The model can't load twice in a row: its line and Try Again; a load that works clears it.
    @MainActor static func modelWontStart() async throws {
        let rig = try await rig("wont-start")
        try await on(rig)
        await rig.model.set(failLoad: true)
        try moment(rig, "w1", "Plan A")
        await rig.writer.pass(.explicit)
        rig.clock.advance(120)
        try moment(rig, "w2", "Plan B", ago: 700)
        await rig.writer.pass(.explicit)
        check(rig.writer.phase == .failed(.modelWontStart), "a model that won't load: The model couldn't start, with Try Again", "\(rig.writer.phase)")
        let states = try statuses(rig)
        check(!states.contains("pending"), "a model that won't load leaves nothing waiting for a Retry button", "\(states)")
        await rig.model.set(failLoad: false)
        rig.writer.retry()
        for _ in 0..<100 { if await rig.model.loads > 0 { break }; await sleep(0.02) }
        await sleep(0.2)
        check(rig.writer.phase == .on(.local), "Try Again: the model loads and summaries are on", "\(rig.writer.phase)")
        // fix/sx-all round 2: Try Again forgets the loads that failed before: one more failed load after it is not the
        // line again (it took two in a row), so the switch never snaps back at the next pass.
        await rig.model.set(failLoad: true)
        for (i, name) in ["Plan C", "Plan D"].enumerated() { rig.clock.advance(120); try moment(rig, "w\(i + 3)", name, ago: 700); await rig.writer.pass(.explicit) }
        check(rig.writer.phase == .failed(.modelWontStart), "two failed loads in a row: the line again", "\(rig.writer.phase)")
        rig.clock.advance(120); try moment(rig, "w5", "Plan E", ago: 700)
        let before = await rig.model.loadAttempts
        rig.writer.retry()
        await sleep(0.3)
        let triedAgain = await rig.model.loadAttempts - before
        check(rig.writer.phase == .on(.local) && triedAgain > 0, "Try Again resets the failed loads: its own failed load keeps the switch on", "\(rig.writer.phase)")
        rig.clock.advance(120); try moment(rig, "w6", "Plan F", ago: 700); await rig.writer.pass(.explicit)
        check(rig.writer.phase == .failed(.modelWontStart), "…and a second failed load says it again", "\(rig.writer.phase)")
        // build/launch (fix/battery-summaries): on battery the model runs in the background too, so Try Again tries it
        // now (no waiting line). Only where background writing waits (Low Power Mode, under 20%, hot) does Try Again say
        // the model is tried when the Mac is plugged in.
        rig.power.value = .battery
        rig.writer.retry()
        await sleep(0.3)
        check(rig.writer.phase == .on(.local) && !rig.writer.retryWaitsForPower,
              "Try Again on battery: the switch on, the model tried now (no waiting line)", "\(rig.writer.phase) \(rig.writer.retryWaitsForPower)")
        await rig.model.set(failLoad: true)
        rig.clock.advance(120); try moment(rig, "w7", "Plan G", ago: 700); await rig.writer.pass(.explicit)
        rig.clock.advance(120); try moment(rig, "w8", "Plan H", ago: 700); await rig.writer.pass(.explicit)
        var lowPower = ModelPower.battery; lowPower.lowPowerMode = true
        rig.power.value = lowPower
        rig.writer.retry()
        await sleep(0.3)
        check(rig.writer.phase == .on(.local) && rig.writer.retryWaitsForPower
              && WriterPreferences.waitsForPowerLine == "The model is tried again when your Mac is plugged in.",
              "Try Again in Low Power Mode: the switch on, and its line says the model is tried when the Mac is plugged in", "\(rig.writer.phase)")
        rig.power.value = .ac
        await rig.model.set(failLoad: false)
        await rig.writer.pass(.power)
        check(!rig.writer.retryWaitsForPower, "plugged in: the line goes", "\(rig.writer.phase)")
        await finish(rig)
    }
    /// F: an open moment is never written in the background; it is once it closes. No busy while writing.
    @MainActor static func closedOnly() async throws {
        let rig = try await rig("closed")
        try await on(rig)
        let target = try moment(rig, "open", "Quarterly letter", ago: 60)
        var busySeen = false
        let sink = rig.writer.$busy.sink { if $0 { busySeen = true } }
        await rig.writer.pass(.explicit)
        let early = await rig.model.answers
        check(early == 0, "an open moment (last action a minute ago) is not written", "\(early) answers")
        rig.clock.advance(600)
        await rig.writer.pass(.timer)
        let later = await rig.model.answers
        check(later > 0, "once it closed (10 minutes), it is written", "\(rig.writer.status) \(rig.writer.counters) \((try? statuses(rig)) ?? [])")
        check(!busySeen, "writing notes never shows busy")
        sink.cancel()
        await finish(rig)
        // fix/bugs7-late: a moment the writer gave up on for good (its written mark says skipped: a local note that failed
        // its last try, so the code note stands) is published as skipped after a relaunch, so the Today page never shows it
        // as pending. (This fixture's empty answer is salvaged into a committed note, so the mark is set by hand.)
        let file = rig.home.appendingPathComponent("WriterScheduling/pending-v1.json")
        var json = try ledger(rig)
        var written = json["written"] as? [String: Any] ?? [:]
        let key = written.keys.first { $0.hasSuffix(target.id) }
        if let key, var mark = written[key] as? [String: Any] { mark["skipped"] = true; mark["fallback"] = true; written[key] = mark }
        json["written"] = written
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let again = try await Self.rig("closed", home: rig.home, suite: rig.suite, keys: rig.keys, model: rig.model)
        check(key != nil && again.writer.skippedMoments == [target.id], "a moment the writer gave up on is published as skipped (never pending)",
              "\(again.writer.skippedMoments) \(written.keys)")
        await finish(again)
    }
    /// fix/bugs7: a pass (the one timer, an event) that finds the writer held returns at once instead of looping on
    /// the main actor forever, and the running pass takes its reason and looks again when its tick ends.
    @MainActor static func heldNoSpin() async throws {
        // A spinning main actor can't run anything else, so the watchdog is a thread of its own.
        let finished = Box(false)
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 60)
            if !finished.value { print("FAIL held writer: a pass spun on the main actor (no progress in 60 s)"); exit(1) }
        }
        defer { finished.value = true }
        let rig = try await rig("held")
        try await on(rig)
        // 1. The one timer fires while a pass is writing a batch.
        try moment(rig, "h1", "Launch checklist")
        rig.idle.value = 600
        await rig.model.set(held: true)
        let ticksBefore = rig.writer.counters.passTicks
        let first = Task { await rig.writer.pass(.explicit) }
        for _ in 0..<300 where await rig.model.answers == 0 { await sleep(0.01) }
        check(await rig.model.answers > 0, "held: the first pass is writing (fixture)")
        let timerBefore = rig.writer.counters.timerPasses
        await rig.writer.pass(.timer)
        check(rig.writer.counters.timerPasses == timerBefore + 1, "held: the timer's pass during a batch returns at once")
        rig.writer.wake(.power)
        await sleep(0.05)
        check(rig.writer.counters.passTicks == ticksBefore + 1, "held: nothing else ticked while the batch ran", "\(rig.writer.counters)")
        await rig.model.set(held: false)
        await first.value
        check(rig.writer.counters.passTicks == ticksBefore + 2,
              "held: the running pass took the timer's and the event's reason and looked again once when its tick ended", "\(rig.writer.counters)")
        // 2. The timer and an event during Summarize Now (a hold that isn't a pass).
        let target = try moment(rig, "h3", "Budget draft", ago: 800)
        await rig.model.set(held: true)
        let answersBefore = await rig.model.answers
        let note = Task { try await rig.writer.generate(day: target.day, timezone: zone, activityID: target.id, lastActivity: rig.clock.now.addingTimeInterval(-800)) }
        for _ in 0..<300 where await rig.model.answers == answersBefore { await sleep(0.01) }
        let heldBefore = rig.writer.counters.heldPasses
        await rig.writer.pass(.timer)
        check(rig.writer.counters.heldPasses == heldBefore + 1, "held: the timer's pass during Summarize Now returns at once")
        check(rig.writer.nextWake.map { $0.timeIntervalSince(rig.clock.now) <= WriterIntegration.heldRetry + 1 } ?? false,
              "held: it looks again within a minute", "\(String(describing: rig.writer.nextWake))")
        rig.writer.wake(.lock)
        await sleep(0.05)
        await rig.model.set(held: false)
        _ = try? await note.value
        await rig.writer.pass(.timer)
        check(true, "held: the main actor never spun (the watchdog stayed quiet)")
        await finish(rig)
    }
    /// fix/bugs7-late: OpenRouter chosen while the model downloads (the key works): the download stops, the key is saved,
    /// cloud is on, and the stopped download never turns summaries on this Mac on afterwards.
    @MainActor static func cloudDuringDownload() async throws {
        let gate = Box(false)
        var admission = LocalAdmission(restoreOffline: { _, _ in throw WriterFailure.unavailable }, checkWithApple: {}, signedBuild: { false })
        let home = root.appendingPathComponent("cloud-dl")
        let fake = files(home)
        admission.download = { _, progress in
            progress(.downloading(1, 2_740_000_000))
            while !gate.value { try await Task.sleep(nanoseconds: 10_000_000) }
            return fake
        }
        let rig = try await rig("cloud-dl", admission: admission)
        rig.writer.chooseLocal()
        for _ in 0..<200 { if case .downloading = rig.writer.phase { break }; await sleep(0.01) }
        let problem = await rig.writer.chooseCloud(key: "sk-or-test")
        let saved = await rig.keys.value
        check(problem != nil || rig.writer.provider == "cloud", "OpenRouter chosen during a download: either on, or a problem is said", "problem nil, provider \(rig.writer.provider), phase \(rig.writer.phase), key saved \(!saved.isEmpty)")
        check(!saved.isEmpty && rig.writer.phase == .on(.cloud), "OpenRouter chosen during a download: the key is saved and cloud is on", "\(rig.writer.phase)")
        gate.value = true
        await sleep(0.5)
        check(rig.writer.provider == "cloud" && rig.writer.phase == .on(.cloud), "the stopped download never turns summaries on this Mac on afterwards", "\(rig.writer.provider) \(rig.writer.phase)")
        await finish(rig)
    }
    /// claude/summary-fail-1003 (owner 10/3, installed 20261003140001): Summarize Now during a background batch of several
    /// notes (the day rewritten after a version bump) waited a minute, threw, and the card said "Couldn't summarize. Check
    /// Summaries in Settings." Now the batch stops after the note it is writing and the click runs next; a click still
    /// refused by a busy writer is a one-off (`SummarizeNowFailure.once`) whose moment stays queued, never a setup error.
    @MainActor static func clickDuringLongBatch() async throws {
        let saved = WriterIntegration.generateWait
        defer { WriterIntegration.generateWait = saved }
        let rig = try await rig("long-batch")
        try await on(rig)
        await rig.model.set(valid: true)
        var order: [String] = []
        rig.writer.onNoteRun = { order.append($0.activityID ?? "") }
        let a = try moment(rig, "lb-a", "Click target", ago: 1500)
        let b = try moment(rig, "lb-b", "Batch one", ago: 1200), c = try moment(rig, "lb-c", "Batch two", ago: 1100), d = try moment(rig, "lb-d", "Batch three", ago: 1000)
        rig.idle.value = 600
        // 1. The batch is writing its first note; the click waits for that note only, then runs before the rest.
        WriterIntegration.generateWait = 5
        await rig.model.set(held: true)
        let batch = Task { await rig.writer.pass(.explicit) }
        for _ in 0..<300 where await rig.model.answers == 0 { await sleep(0.01) }
        let clicked = Task { try await rig.writer.generate(day: a.day, timezone: zone, activityID: a.id, lastActivity: rig.clock.now.addingTimeInterval(-1500)) }
        await sleep(0.2)
        await rig.model.set(held: false)
        var ok = true
        do { try await clicked.value } catch { ok = false }
        await batch.value
        let background = Set([b.id, c.id, d.id])
        let firstClick = order.firstIndex(of: a.id)
        check(ok && firstClick != nil, "long batch: Summarize Now writes its moment", "\(order.count) runs")
        check(firstClick.map { order[..<$0].filter { background.contains($0) }.count <= 1 } ?? false,
              "long batch: the batch stops after the note it was writing; the click runs next, not after the whole batch",
              "\(order.map { [a.id: "a", b.id: "b", c.id: "c", d.id: "d"][$0] ?? "?" })")
        // The rest is written by the next look (nothing is lost by stopping).
        rig.clock.advance(5)
        await rig.writer.pass(.explicit)
        check(background.allSatisfy { order.contains($0) }, "long batch: the moments the batch left are written by the next look",
              "\(order.map { [a.id: "a", b.id: "b", c.id: "c", d.id: "d"][$0] ?? "?" })")
        // 2. A writer still busy after the wait: a one-off, never a setup error, and the moment is queued for the next look.
        let e = try moment(rig, "lb-e", "Still busy", ago: 900), f = try moment(rig, "lb-f", "Busy batch", ago: 800)
        _ = f
        WriterIntegration.generateWait = 0.5
        await rig.model.set(held: true)
        let answersBefore = await rig.model.answers
        let busy = Task { await rig.writer.pass(.explicit) }
        for _ in 0..<300 where await rig.model.answers == answersBefore { await sleep(0.01) }
        var failure: Error?
        do { try await rig.writer.generate(day: e.day, timezone: zone, activityID: e.id, lastActivity: rig.clock.now.addingTimeInterval(-900)) } catch { failure = error }
        check((failure as? SummarizeNowFailure) == .once("writer-busy"), "busy writer: a one-off (SummarizeNowFailure.once), not \"check Settings\"", "\(String(describing: failure))")
        check(SummarizeNowNotice.banner(for: failure ?? MemError.missing, summaries: SummaryAvailability(provider: .local, busy: false, phase: rig.writer.phase)) == nil,
              "busy writer: the card shows no banner (summaries are on)", "\(rig.writer.phase)")
        await rig.model.set(held: false)
        await busy.value
        rig.clock.advance(5)
        await rig.writer.pass(.explicit)
        check(order.contains(e.id), "busy writer: the clicked moment is written by the next look")
        // 3. Summaries off: the one setup failure.
        await finish(rig)
        let off = try await Self.rig("long-batch-off")
        var offError: Error?
        do { try await off.writer.generate(day: e.day, timezone: zone, activityID: e.id, lastActivity: off.clock.now) } catch { offError = error }
        check((offError as? SummarizeNowFailure) == .setup("Summaries are off."), "summaries off: a setup failure naming it", "\(String(describing: offError))")
        await finish(off)
    }
    /// fix/resummarize (owner, test 7: "The summary is not letting me update the summary for claude"): Summarize Now writes
    /// a fresh note for a written moment and for an open one (provisional: written again once it closes); a written moment
    /// used a few more minutes is rewritten once at the next batch, and not again without new activity.
    @MainActor static func resummarize() async throws {
        let rig = try await rig("resummarize")
        try await on(rig)
        await rig.model.set(valid: true)
        var runs: [String: Int] = [:]
        rig.writer.onNoteRun = { runs[$0.activityID ?? "", default: 0] += 1 }
        func activity(_ t: (day: String, id: String)) throws -> ActivityNote? {
            try rig.store.dayLayers(day: t.day, timezone: zone, now: rig.clock.now).activities.first { $0.id == t.id }
        }
        func version(_ t: (day: String, id: String)) throws -> Int { try rig.store.latestNote(id: t.id)?.version ?? 0 }
        func mark(_ t: (day: String, id: String)) throws -> [String: Any]? {
            ((try ledger(rig)["written"] as? [String: Any]) ?? [:]).first { $0.key.hasSuffix(t.id) }?.value as? [String: Any]
        }
        // 1. A written moment: Summarize Now writes it again (it did nothing before: its note was current).
        let a = try moment(rig, "rs-a", "Launch plan", ago: 900)
        try await rig.writer.generate(day: a.day, timezone: zone, activityID: a.id, lastActivity: rig.clock.now.addingTimeInterval(-900))
        let a1 = try activity(a)?.status, v1 = try version(a)
        check(try mark(a)?["writerRevision"] as? String == WriterQueueSource.writerRevision, "ordinary committed note persists current writer version stamp")
        check(a1 == "ready" && v1 == 1, "fixture: Summarize Now writes a moment's first note",
              "\((try? activity(a))?.status ?? "?") v\((try? version(a)) ?? -1) \(rig.writer.status)")
        rig.clock.advance(5)
        try await rig.writer.generate(day: a.day, timezone: zone, activityID: a.id, lastActivity: rig.clock.now.addingTimeInterval(-900))
        let a2 = try activity(a)?.status, v2 = try version(a)
        check(runs[a.id] == 2 && v2 == 2 && a2 == "ready",
              "Summarize Now on a written moment writes a fresh note (the row shows it once stored)", "runs \(runs[a.id] ?? 0), v\((try? version(a)) ?? -1)")
        // 2. An open moment (its last action 30 seconds ago): written now, provisionally.
        let b = try moment(rig, "rs-b", "Pricing chat", ago: 30)
        try await rig.writer.generate(day: b.day, timezone: zone, activityID: b.id, lastActivity: rig.clock.now.addingTimeInterval(-30))
        let b1 = try activity(b)?.status, bm = try mark(b)
        check(runs[b.id] == 1 && b1 == "ready", "Summarize Now on an open moment writes it", "runs \(runs[b.id] ?? 0)")
        check(bm?["provisional"] as? Bool == true, "Summarize Now on an open moment: provisional, written again once it closes", "\(String(describing: try? mark(b)))")
        // 3. During a background batch, a click waits for it instead of failing.
        let c = try moment(rig, "rs-c", "Budget memo", ago: 900)
        rig.idle.value = 600
        await rig.model.set(held: true)
        let batch = Task { await rig.writer.pass(.explicit) }
        for _ in 0..<300 where await rig.model.answers == 0 { await sleep(0.01) }
        let clicked = Task { try await rig.writer.generate(day: a.day, timezone: zone, activityID: a.id, lastActivity: rig.clock.now.addingTimeInterval(-900)) }
        await sleep(0.2)
        await rig.model.set(held: false)
        await batch.value
        var waited = true
        do { try await clicked.value } catch { waited = false }
        check(waited && runs[a.id] == 3, "Summarize Now during a background batch waits for it, then writes", "runs \(runs[a.id] ?? 0)")
        _ = c
        // 4. A click always runs: Low Power Mode at 10% on battery (background waits there); only a critically hot Mac refuses.
        var low = ModelPower.battery; low.lowPowerMode = true; low.battery = 10
        rig.power.value = low
        try await rig.writer.generate(day: a.day, timezone: zone, activityID: a.id, lastActivity: rig.clock.now.addingTimeInterval(-900))
        check(runs[a.id] == 4, "Summarize Now runs in Low Power Mode at 10% (a click always works)", "runs \(runs[a.id] ?? 0)")
        var hot = ModelPower.ac; hot.thermal = ProcessInfo.ThermalState.critical.rawValue
        rig.power.value = hot
        var refused = false
        do { try await rig.writer.generate(day: a.day, timezone: zone, activityID: a.id, lastActivity: rig.clock.now.addingTimeInterval(-900)) } catch { refused = true }
        check(refused && runs[a.id] == 4, "Summarize Now refuses only while the Mac is critically hot", "runs \(runs[a.id] ?? 0)")
        rig.power.value = .ac
        await finish(rig)

        // 4. The rewrite rule: a written 60-action moment gets 4 more minutes of clicks (13% more, nothing typed).
        let g = try await Self.rig("rewrite")
        try await on(g)
        await g.model.set(valid: true)
        var gruns: [String: Int] = [:]
        g.writer.onNoteRun = { gruns[$0.activityID ?? "", default: 0] += 1 }
        g.idle.value = 600
        let m = try moment(g, "rw", "Claude chat", count: 60, ago: 1500)
        await g.writer.pass(.explicit)
        let written = try g.store.dayLayers(day: m.day, timezone: zone, now: g.clock.now).activities.first { $0.id == m.id }
        check(gruns[m.id] == 1 && written?.status == "ready", "fixture: the closed moment is written by the batch", "runs \(gruns[m.id] ?? 0) \(written?.status ?? "?")")
        let end = timestamp(written!.end)!
        func click(_ n: Int, at: Date) throws {
            _ = try g.store.ingest(Evidence(id: "rw-more-\(n)", at: iso(at), kind: "mouse.click", app: "TextEdit", bundle: "com.apple.TextEdit", title: "Claude chat", synthetic: true), now: at.addingTimeInterval(0.5))
        }
        // One more click only: not enough to rewrite (no extra model run).
        try click(0, at: end.addingTimeInterval(20))
        g.clock.advance(WriterQueueSource.rewriteAfter + 60)
        await g.writer.pass(.timer)
        check(gruns[m.id] == 1, "one more action is not enough: no rewrite", "runs \(gruns[m.id] ?? 0)")
        for k in 1...8 { try click(k, at: end.addingTimeInterval(20 + Double(k) * 30)) }
        let grown = try g.store.dayLayers(day: m.day, timezone: zone, now: g.clock.now).activities.first { $0.id == m.id }
        check(grown?.actionIDs.count == 69 && grown?.status == "pending", "fixture: the clicks joined the written moment (it shows its previous note)", "\(grown?.actionIDs.count ?? 0) \(grown?.status ?? "?")")
        g.clock.advance(60)
        await g.writer.pass(.timer)
        let rewritten = try g.store.dayLayers(day: m.day, timezone: zone, now: g.clock.now).activities.first { $0.id == m.id }
        check(gruns[m.id] == 2 && rewritten?.status == "ready", "a written moment used 4 more minutes is rewritten at the next batch", "runs \(gruns[m.id] ?? 0) \(rewritten?.status ?? "?")")
        for _ in 0..<3 {
            g.clock.advance(WriterQueueSource.rewriteAfter + 60)
            await g.writer.pass(.timer)
        }
        check(gruns[m.id] == 2, "and not again without new activity", "runs \(gruns[m.id] ?? 0)")
        await finish(g)
    }
    /// G (fix/battery-summaries, owner 9/28): on battery at 80% the model writes in the background, in the same batches;
    /// under 20%, in Low Power Mode or while the Mac is hot it waits, and what waited is written as soon as it may run
    /// again (plugged in, Low Power Mode off, cooler), without waiting for the next 20-minute batch.
    @MainActor static func battery() async throws {
        let rig = try await rig("battery")
        try await on(rig)
        rig.power.value = .battery
        await rig.writer.pass(.power)
        func written(_ target: (day: String, id: String)) throws -> Bool {
            let marks = try ledger(rig)["written"] as? [String: [String: Any]] ?? [:]
            return marks.keys.contains { $0.hasSuffix(target.id) }
        }
        // Moments 15 minutes apart, all closed (ended over 10 minutes ago), the clock moving a minute a step, so after
        // the first batch no step is due by time: only the power change starts one.
        var b80 = ModelPower.battery; b80.battery = 80
        rig.power.value = b80
        let a = try moment(rig, "ba", "Travel plan", ago: 3600)
        await rig.writer.pass(.timer)
        let first = await rig.model.answers
        check(try written(a) && first > 0, "battery 80%: the model writes in the background", "\(first) answers")

        // Under 20%: waits, then plugging in writes what waited.
        rig.clock.advance(60)
        var b15 = b80; b15.battery = 15
        rig.power.value = b15
        let b = try moment(rig, "bb", "Hotel list", ago: 2700)
        var before = await rig.model.answers
        rig.idle.value = 600
        await rig.writer.pass(.timer)
        rig.idle.value = 0
        var after = await rig.model.answers
        check(!(try written(b)) && after == before, "battery 15%: no model runs, even while idle; the moment waits", "\(after - before) answers")
        rig.clock.advance(60)
        rig.power.value = .ac
        await rig.writer.pass(.power)
        check(try written(b), "plugged in after waiting: what waited is written at once")

        // Low Power Mode (on battery at 80%): waits; turning it off writes what waited, still on battery.
        rig.clock.advance(60)
        var low = b80; low.lowPowerMode = true
        rig.power.value = low
        let c = try moment(rig, "bc", "Packing list", ago: 1800)
        before = await rig.model.answers
        rig.idle.value = 600
        await rig.writer.pass(.timer)
        rig.idle.value = 0
        after = await rig.model.answers
        check(!(try written(c)) && after == before, "Low Power Mode: no model runs; the moment waits", "\(after - before) answers")
        rig.clock.advance(60)
        rig.power.value = b80
        await rig.writer.pass(.power)
        check(try written(c), "Low Power Mode off, on battery: what waited is written")

        // Hot (thermal serious) on battery: waits; cooler writes what waited.
        rig.clock.advance(60)
        var hot = b80; hot.thermal = ProcessInfo.ThermalState.serious.rawValue
        rig.power.value = hot
        let d = try moment(rig, "bd", "Visa form", ago: 900)
        before = await rig.model.answers
        rig.idle.value = 600
        await rig.writer.pass(.timer)
        rig.idle.value = 0
        after = await rig.model.answers
        check(!(try written(d)) && after == before, "hot: no model runs; the moment waits", "\(after - before) answers")
        rig.clock.advance(60)
        rig.power.value = b80
        await rig.writer.pass(.power)
        check(try written(d), "cooler, on battery: what waited is written")
        await finish(rig)
    }
    /// H: an AI app's request writes the last hour, open moments too (provisionally), then says done; at most every
    /// 5 minutes; always says done; not in Low Power Mode.
    @MainActor static func onDemand() async throws {
        let rig = try await rig("on-demand")
        try await on(rig)
        rig.power.value = .battery
        await rig.writer.pass(.power)
        let target = try moment(rig, "d", "Board memo", ago: 30)
        await rig.writer.onDemand()
        let answers = await rig.model.answers
        let marks = try ledger(rig)["written"] as? [String: [String: Any]] ?? [:]
        let mark = marks.first { $0.key.hasSuffix(target.id) }?.value
        check(answers > 0 && rig.done.value == 1, "an AI app's request on battery writes the open moment and says done", "\(answers) answers, done \(rig.done.value)")
        check(mark?["provisional"] as? Bool == true, "that note is provisional: it is written again once the moment closes")
        try moment(rig, "d2", "Board memo 2", ago: 20)
        await rig.writer.onDemand()
        check(rig.done.value == 2 && rig.writer.counters.onDemandBatches == 1, "a second request within 5 minutes writes nothing but still says done")
        rig.clock.advance(400)
        var low = ModelPower.battery; low.lowPowerMode = true
        rig.power.value = low
        await rig.writer.onDemand()
        check(rig.done.value == 3 && rig.writer.counters.onDemandBatches == 1, "in Low Power Mode nothing runs, and it says done")
        rig.power.value = .ac
        rig.clock.advance(700)
        let before = await rig.model.answers
        await rig.writer.pass(.timer)
        let after = await rig.model.answers
        check(after > before, "the provisional note is written again once its moment closed")
        await finish(rig)
    }
    /// I: the key is tried once before cloud turns on; each failure is typed and nothing turns on.
    @MainActor static func cloudKeyTest() async throws {
        let rig = try await rig("cloud-key")
        let cases: [(Int, String, SummaryProblem)] = [(401, "", .cloudKey), (403, "", .cloudKey), (402, "", .cloudCredits), (404, "", .cloudHost),
            (400, #"{"error":{"message":"No endpoints found matching your data policy"}}"#, .cloudHost), (429, "", .cloudOffline), (503, "", .cloudOffline)]
        for (status, body, expected) in cases {
            await rig.http.set([(status, body)])
            let problem = await rig.writer.chooseCloud(key: "sk-or-test")
            check(problem == expected && rig.writer.provider == "off" && rig.writer.phase == .failed(expected), "key test \(status): \(expected), and cloud stays off", "\(String(describing: problem)) \(rig.writer.provider) \(rig.writer.phase)")
        }
        let saved = await rig.keys.value
        check(saved.isEmpty, "a key that failed its test is not saved")
        let calls = await rig.http.calls
        check(calls == cases.count, "each key test is one request", "\(calls)")
        let body = String(decoding: await rig.http.bodies.last ?? Data(), as: UTF8.self)
        check(body.contains("\"max_tokens\":1") && body.replacingOccurrences(of: "\\/", with: "/").contains("deepseek/deepseek-v4-flash") && body.contains(CloudWriter.probeInstruction) && body.contains("\"zdr\":true"),
              "the key test is one output token, same model and host rules, a fixed prompt", body)
        await rig.http.set([(200, #"{"model":"deepseek/deepseek-v4-flash-0731","choices":[{"message":{"content":"OK"}}]}"#)])
        let ok = await rig.writer.chooseCloud(key: "sk-or-test")
        check(ok == nil && rig.writer.phase == .on(.cloud) && rig.writer.provider == "cloud", "a working key turns cloud summaries on", "\(rig.writer.phase)")
        await finish(rig)
    }
    /// I: failures while writing: a revoked key shows Change Key; null answers are tried again, then back off; 150
    /// actions are written in one request (no 100-action cap).
    @MainActor static func cloudNoteFailures() async throws {
        let clock = recentClock(7200)
        let rig = try await rig("cloud-notes", clock: clock)
        let problem = await rig.writer.chooseCloud(key: "sk-or-test")
        check(problem == nil, "cloud fixture on", "\(String(describing: problem))")
        clock.advance(2)
        try moment(rig, "long", "Grant proposal", count: 150, ago: -300)
        clock.advance(1200)
        await rig.http.set([(200, #"{"model":"deepseek/deepseek-v4-flash-0731","choices":[{"message":{"content":null}}]}"#)])
        let before = await rig.http.calls
        await rig.writer.pass(.explicit)
        let tries = await rig.http.calls - before
        check(tries == 3, "a null answer is tried again twice, then the writer backs off", "\(tries) requests")
        let body = String(decoding: await rig.http.bodies.last ?? Data(), as: UTF8.self)
        check(body.contains("Grant proposal"), "a 150-action moment is sent in one request (no 100-action cap)")
        let states = try statuses(rig)
        check(!states.contains("pending"), "after a null answer the note waits for the back-off, not for Retry", "\(states)")
        await rig.http.set([(401, "")])
        clock.advance(120)
        await rig.writer.pass(.timer)
        check(rig.writer.phase == .failed(.cloudKey), "a key revoked while writing: OpenRouter didn't accept this key, with Change Key", "\(rig.writer.phase)")
        await rig.http.set([(429, ""), (429, ""), (429, "")])
        rig.writer.retry()
        // fix/writing-forever: waits for Try Again's key test to end (up to 10 s) instead of a fixed 0.3 s.
        await until { rig.writer.phase != .failed(.cloudKey) }
        check(rig.writer.phase == .failed(.cloudOffline), "Try Again while OpenRouter keeps answering 429: Can't reach OpenRouter", "\(rig.writer.phase)")
        await finish(rig)
    }
    /// fix/writing-forever (coordinator, 9/30): the midnight crossing on purpose, on the rig clock (the same at any wall
    /// time). A cloud moment that ended at 23:45 fails (null answers) after midnight and backs off; its key is then revoked.
    /// It is a past day's moment, so today's batch never tries it again: the phase stays on(cloud), with no request, only
    /// until catch-up is due (20 minutes after the last catch-up, or once the Mac is idle 5 minutes); that first request
    /// says Change Key. Then Try Again while OpenRouter keeps answering 429 says Can't reach OpenRouter (the day doesn't matter).
    @MainActor static func revokedAcrossMidnight() async throws {
        let midnight = Calendar.current.startOfDay(for: Date())
        for idleWay in [false, true] {
            // 23:35 yesterday: before now at any wall time (at most about 24.5 hours back).
            let clock = Clock(midnight.addingTimeInterval(-1500))
            let rig = try await rig(idleWay ? "midnight-idle" : "midnight", clock: clock)
            let way = idleWay ? "idle" : "20 minutes"
            let problem = await rig.writer.chooseCloud(key: "sk-or-test")
            check(problem == nil, "midnight (\(way)): cloud fixture on", "\(String(describing: problem))")
            clock.advance(602)
            let late = try moment(rig, "late", "Board memo", ago: 0)
            let today = try DayScope.key(midnight, timezone: zone)
            check(late.day != today, "midnight (\(way)): the moment ended before midnight (fixture)", "\(late.day)")
            clock.set(midnight.addingTimeInterval(300))
            await rig.http.set([(200, #"{"model":"deepseek/deepseek-v4-flash-0731","choices":[{"message":{"content":null}}]}"#)])
            var before = await rig.http.calls
            await rig.writer.pass(.explicit)
            let catchUpAt = clock.now
            var sent = await rig.http.calls - before
            check(sent == 3 && rig.writer.phase == .on(.cloud),
                  "midnight (\(way)): after midnight catch-up tries yesterday's moment (null answers, 3 tries) and backs off", "\(sent) requests, \(rig.writer.phase)")
            await rig.http.set([(401, "")])
            clock.advance(120)
            before = await rig.http.calls
            await rig.writer.pass(.timer)
            sent = await rig.http.calls - before
            check(sent == 0 && rig.writer.phase == .on(.cloud),
                  "midnight (\(way)): back-off over, key revoked: today's batch doesn't try yesterday's moment; on(cloud), no request",
                  "\(sent) requests, \(rig.writer.phase)")
            if idleWay {
                rig.idle.value = TimeInterval(WriterIntegration.idleClose)
            } else {
                clock.set(catchUpAt.addingTimeInterval(WriterIntegration.batchEvery - 1))
                await rig.writer.pass(.timer)
                sent = await rig.http.calls - before
                check(sent == 0 && rig.writer.phase == .on(.cloud),
                      "midnight (20 minutes): a second before catch-up is due, still on(cloud) and no request", "\(sent) requests, \(rig.writer.phase)")
                clock.set(catchUpAt.addingTimeInterval(WriterIntegration.batchEvery))
            }
            await rig.writer.pass(.timer)
            sent = await rig.http.calls - before
            check(sent > 0 && rig.writer.phase == .failed(.cloudKey),
                  "midnight (\(way)): once catch-up is due, its first request says OpenRouter didn't accept this key (Change Key)",
                  "\(sent) requests, \(rig.writer.phase)")
            if !idleWay {
                await rig.http.set([(429, ""), (429, ""), (429, "")])
                rig.writer.retry()
                await until { rig.writer.phase != .failed(.cloudKey) }
                check(rig.writer.phase == .failed(.cloudOffline),
                      "midnight: from Change Key, Try Again while OpenRouter keeps answering 429 says Can't reach OpenRouter (yesterday's moment)",
                      "\(rig.writer.phase)")
            }
            await finish(rig)
        }
    }
    /// I: the first activation's cutoff survives a relaunch and a privacy change.
    @MainActor static func cloudCutoffKept() async throws {
        let clock = recentClock(7200)
        let keys = TestKeys()
        let first = try await rig("cutoff", clock: clock, keys: keys)
        _ = await first.writer.chooseCloud(key: "sk-or-test")
        let cutoff = try ledger(first)["cloudCutoff"] as? Double
        await first.writer.shutdown()
        clock.advance(1800)
        let second = try await rig("cutoff", clock: clock, home: first.home, suite: first.suite, keys: keys)
        for _ in 0..<100 where second.writer.provider != "cloud" { await sleep(0.02) }
        let kept = try ledger(second)["cloudCutoff"] as? Double
        check(second.writer.provider == "cloud" && cutoff != nil && kept == cutoff, "cloud comes back on after a relaunch with its first cutoff", "\(String(describing: cutoff)) \(String(describing: kept))")
        _ = try second.store.savePreferences(MemoryPreferences(blockedApps: ["com.example.unused"], nativeTyping: false), expectedRevision: try second.store.policy().revision)
        await second.writer.pass(.explicit)
        for _ in 0..<100 where second.writer.provider != "cloud" { await sleep(0.02) }
        let afterPrivacy = try ledger(second)["cloudCutoff"] as? Double
        check(second.writer.provider == "cloud" && afterPrivacy == cutoff, "a privacy change keeps the first cutoff", "\(String(describing: afterPrivacy))")
        await finish(second)
    }

    /// fix/sx-all round 1 (P0): a pass while the writer is busy (an AI app's request writing a note) returns at once and
    /// runs once the request ends. Before, pass() looped on the refused tick with no suspension and the main thread spun
    /// for good (a watchdog thread catches that here).
    @MainActor static func noSpinWhileBusy() async throws {
        let rig = try await rig("no-spin")
        try await on(rig)
        try moment(rig, "s", "Launch checklist", ago: 30)
        await rig.model.set(paused: true)
        let request = Task { await rig.writer.onDemand() }
        for _ in 0..<300 where await rig.model.answers == 0 { await sleep(0.01) }
        // fix/writing-forever: the check needs the AI app's request to be writing (the model is paused mid-answer). Run at
        // 03:00 with a clock 3 hours back, the moment fell on the day before: the request wrote nothing, and the pass below
        // ran catch-up into the paused model, which the watchdog then reported as a spin. Say that instead.
        guard await rig.model.answers > 0 else {
            check(false, "no spin: the AI app's request is writing (fixture)", "no answer started; clock \(iso(rig.clock.now))")
            await rig.model.set(paused: false); await request.value; await finish(rig); return
        }
        let returned = Box(false)
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            if !returned.value { print("FAIL a pass while the writer is busy spins the main thread (no return in 10 s)"); exit(1) }
        }
        let passes = rig.writer.counters.eventPasses
        await rig.writer.pass(.explicit)
        returned.value = true
        check(rig.writer.counters.eventPasses == passes + 1, "a pass while an AI app's request writes returns at once (no spin)")
        await rig.model.set(paused: false)
        await request.value
        for _ in 0..<100 where rig.writer.counters.eventPasses < passes + 2 { await sleep(0.02) }
        check(rig.writer.counters.eventPasses >= passes + 2, "the deferred look runs once the request ends", "\(rig.writer.counters.eventPasses - passes) passes")
        await finish(rig)
    }
    /// fix/sx-all round 1: a key pasted while the model downloads stops the download and turns cloud summaries on; before,
    /// the key was dropped with no word (chooseCloud returned nil).
    @MainActor static func keyDuringDownload() async throws {
        var hanging = LocalAdmission(restoreOffline: { _, _ in throw WriterFailure.unavailable }, checkWithApple: {}, signedBuild: { false })
        hanging.download = { _, progress in progress(.downloading(5, 10)); while true { try await Task.sleep(nanoseconds: 10_000_000) } }
        let rig = try await rig("key-download", admission: hanging)
        rig.writer.chooseLocal()
        for _ in 0..<200 { if case .downloading = rig.writer.phase { break }; await sleep(0.01) }
        let problem = await rig.writer.chooseCloud(key: "sk-or-test")
        let saved = await rig.keys.value
        check(problem == nil && rig.writer.phase == .on(.cloud) && rig.writer.provider == "cloud" && saved == "sk-or-test",
              "a key pasted during the download: the download stops, the key is saved and cloud summaries are on", "\(String(describing: problem)) \(rig.writer.phase) saved \(!saved.isEmpty)")
        await finish(rig)
    }
    /// fix/sx-all round 1: a cloud switch saved under the v2 notice (before page titles were named) never turns itself back on.
    @MainActor static func oldCloudNotice() async throws {
        let keys = TestKeys()
        let first = try await rig("old-notice", keys: keys)
        _ = await first.writer.chooseCloud(key: "sk-or-test")
        await first.writer.shutdown()
        let url = first.home.appendingPathComponent("WriterScheduling/pending-v1.json")
        var ledger = (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
        check(ledger["cloudResumeVersion"] as? Int == CloudConsent.currentVersion && CloudConsent.currentVersion >= 3, "the switch is saved with the v3 notice (page titles named)")
        ledger["cloudResumeVersion"] = 2
        try JSONSerialization.data(withJSONObject: ledger).write(to: url)
        let second = try await rig("old-notice", home: first.home, suite: first.suite, keys: keys)
        await sleep(0.3)
        let after = (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
        check(second.writer.provider == "off" && second.writer.phase != .on(.cloud) && after["cloudResumeVersion"] == nil,
              "a switch saved under the v2 notice stays off after a relaunch, and is reset", "\(second.writer.provider) \(second.writer.phase)")
        let calls = await second.http.calls
        check(calls == 0, "nothing is sent for it", "\(calls)")
        await finish(second)
    }
    /// fix/sx-all round 1: on battery an AI app's request writes new moments only, at most 3, at most every 15 minutes;
    /// a moment it wrote is rewritten only once that note is 20 minutes old and the moment grew by a quarter.
    @MainActor static func onDemandBattery() async throws {
        // Noon yesterday: the moments below (up to 50 minutes back) never fall on the day before (the default clock is 3
        // hours ago, which just after midnight put them on another day than the request looks at).
        let rig = try await rig("demand-battery", clock: Clock(Calendar.current.startOfDay(for: Date()).addingTimeInterval(-12 * 3600)))
        try await on(rig)
        rig.power.value = .battery
        await rig.writer.pass(.power)
        for i in 0..<5 { try moment(rig, "m\(i)", "Draft \(i)", ago: Double(3000 - i * 400)) }
        await rig.writer.onDemand()
        let first = await rig.model.answers
        check(first > 0 && rig.writer.counters.noteRuns <= 3, "on battery one request writes at most 3 notes", "\(rig.writer.counters.noteRuns) notes")
        rig.clock.advance(6 * 60)
        let runs = rig.writer.counters.noteRuns
        await rig.writer.onDemand()
        check(rig.writer.counters.noteRuns == runs && rig.done.value == 2, "on battery a second request within 15 minutes writes nothing and says done")
        rig.clock.advance(10 * 60)
        await rig.writer.onDemand()
        let third = rig.writer.counters.noteRuns - runs
        check(third <= 3, "after 15 minutes: at most 3 more", "\(third)")
        rig.clock.advance(16 * 60)
        let before = rig.writer.counters.noteRuns
        await rig.writer.onDemand()
        await rig.writer.onDemand()
        check(rig.writer.counters.noteRuns - before <= 2, "moments already written and not grown are not written again on battery", "\(rig.writer.counters.noteRuns - before)")
        await finish(rig)
    }
    /// fix/writing-forever (owner, launch day, 0.1.3 on battery): Today said "Writing the summary…" for every moment without
    /// a note while summaries were on. The writer now publishes what it has queued: the moment still going is open (never
    /// "writing"), a closed one is queued, and in Low Power Mode, under 20% or hot the queue says why it waits.
    @MainActor static func writingForever() async throws {
        let rig = try await rig("writing-forever")
        try await on(rig)
        var b80 = ModelPower.battery; b80.battery = 80
        var low = b80; low.lowPowerMode = true
        rig.power.value = low
        await rig.writer.pass(.power)
        let open = try moment(rig, "wo", "Launch notes", ago: 60)
        let closed = try moment(rig, "wc", "Press list", ago: 1800)
        await rig.writer.pass(.timer)
        let q = rig.writer.queue
        check(q?.open.contains(open.id) == true && q?.writing.contains(open.id) == false,
              "the moment still going is open, never writing", "\(String(describing: q))")
        check(q?.writing.contains(closed.id) == true && q?.wait == .lowPower,
              "Low Power Mode: a closed moment is queued and the queue says it waits for Low Power Mode", "\(String(describing: q))")
        rig.power.value = b80
        await rig.writer.pass(.power)
        let written = rig.writer.queue
        check(written?.writing.contains(closed.id) == false && written?.wait == nil,
              "on battery at 80%: the queued moment is written and leaves the queue", "\(String(describing: written)) \(rig.writer.status)")
        var b15 = b80; b15.battery = 15
        rig.power.value = b15
        rig.clock.advance(60)
        let later = try moment(rig, "wl", "Guest list", ago: 30)
        rig.clock.advance(15 * 60)
        await rig.writer.pass(.power)
        check(rig.writer.queue?.writing.contains(later.id) == true && rig.writer.queue?.wait == .battery,
              "under 20%: the closed moment waits for power, and says so", "\(String(describing: rig.writer.queue))")
        rig.writer.turnOff()
        check(rig.writer.queue == nil, "summaries off: no queue (Today says Summaries are off)")
        await finish(rig)
    }
    /// fix/writing-forever: the queue holds 128 entries and only a completed one gave way, so past days' catch-up entries
    /// (queued, or waiting for Retry) could refuse today's moments for good; today's batch then had nothing to run and
    /// catch-up (which waits for today) never ran: no note was ever written again. Today's moment now takes the place of
    /// the past-day entry that ended longest ago; a queue full of today's moments is still full.
    @MainActor static func queueRoom() async throws {
        let dir = root.appendingPathComponent("queue-room", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let scheduler = try PendingNoteScheduler(file: dir.appendingPathComponent("pending-v1.json"), limit: 3)
        func item(_ day: String, _ id: String, _ at: TimeInterval) -> ScheduledWriterTarget {
            ScheduledWriterTarget(target: WriterTarget(kind: .activity, day: day, timezone: zone, activityID: id), inputRevision: "r", policyRevision: "p",
                                  lastActivity: Date(timeIntervalSince1970: at))
        }
        let today = "2026-09-29"
        try await scheduler.enqueue(item("2026-09-27", "old", 100))
        try await scheduler.enqueue(item("2026-09-28", "older", 50))
        try await scheduler.enqueue(item("2026-09-28", "newer", 200))
        var refused = false
        do { try await scheduler.enqueue(item(today, "t1", 300)) } catch WriterFailure.capacity { refused = true }
        check(refused, "before: a queue full of past days' entries refuses today's moment")
        try await WriterIntegration.enqueueToday(item(today, "t1", 300), scheduler: scheduler, today: today)
        var ids = Set(await scheduler.snapshot().compactMap(\.item.activityID))
        check(ids == ["old", "newer", "t1"], "today's moment takes the place of the past-day entry that ended longest ago", "\(ids)")
        try await WriterIntegration.enqueueToday(item(today, "t2", 400), scheduler: scheduler, today: today)
        try await WriterIntegration.enqueueToday(item(today, "t3", 500), scheduler: scheduler, today: today)
        ids = Set(await scheduler.snapshot().compactMap(\.item.activityID))
        check(ids == ["t1", "t2", "t3"], "each new moment of today gets a place while past days hold one", "\(ids)")
        refused = false
        do { try await WriterIntegration.enqueueToday(item(today, "t4", 600), scheduler: scheduler, today: today) } catch WriterFailure.capacity { refused = true }
        check(refused, "a queue full of today's moments is still full")
        // Owner lane (fix/writing-forever): a moment's notes are counted in its mark; the background and AI apps stop at 3.
        check(WriterQueueSource.writes(nil) == 0 && WriterQueueSource.writes(WrittenMark(actions: 5, typed: 0, at: Date())) == 1
              && WriterQueueSource.writes(WrittenMark(actions: 5, typed: 0, at: Date(), skipped: true)) == 0
              && WriterQueueSource.writes(WrittenMark(actions: 5, typed: 0, at: Date(), writes: 3)) == 3 && WriterQueueSource.maxWrites == 3,
              "a mark counts the moment's notes (older marks: 1 for a note, 0 set aside); at most 3 in the background")
    }
    /// fix/sx-all round 1: too little memory is its own problem, and its button is the key switch (Try Again can't fix it).
    @MainActor static func memoryProblem() async throws {
        check(SummaryProblem.noMemory.button == CloudSummariesText.title && SummaryProblem.noMemory.line == "Summaries on this Mac need 8 GB of memory."
              && SummaryProblem.noSpace.line.contains("2.8 GB") && !SummaryProblem.noSpace.line.contains("memory"),
              "memory: its own line, with \"Use an OpenRouter key instead\"; free space says about 2.8 GB")
        check(WriterIntegration.problem(forStatus: "Summaries on this Mac need 8 GB of memory.") == .noMemory, "memory: the setup line maps to its problem")
    }
}
enum SHA256Hex {
    static func of(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
