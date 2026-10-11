import Foundation
import AppKit
import MemoryUI
@testable import MemoryCore
@testable import WriterBackend

/// test-p2-int, owner bug 4 ("This Mac only" did nothing for typed words: WriterIntegration bound its writer with
/// CoreWriterBinding's default typed writer, `.cloud`, so the choice silently fell back to the cloud default and the
/// writer on this Mac never read the words). The window-only honesty-ui pins it by reading the source; this check drives
/// the same code with no window: the REAL WriterIntegration, its binding and scheduler, and the choice Settings' switch
/// makes (`SummaryControls.live`, the closures the Summarizer switches call), with a fake model, installer and
/// OpenRouter. No download, model, network, Keychain, app, window or capture.
///
/// What it proves: choosing summaries on this Mac (and coming back to it from OpenRouter, and a relaunch) saves "local"
/// and gives the writer on this Mac the typed words; the cloud-audience port never gets them while "local" is chosen.
let zone = TimeZone.current.identifier

final class Clock: @unchecked Sendable {
    private let lock = NSLock(); private var value: Date
    init(_ start: Date) { value = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ s: TimeInterval) { lock.lock(); value = value.addingTimeInterval(s); lock.unlock() }
}
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock(); private var _value: T
    init(_ v: T) { _value = v }
    var value: T { get { lock.lock(); defer { lock.unlock() }; return _value } set { lock.lock(); _value = newValue; lock.unlock() } }
}
/// A model that records the evidence it is given and answers a note citing every item.
actor FakeModel: LocalInference {
    var evidence: [String] = []
    func load() async throws {}
    func unload() async {}
    func generate(instruction: String, evidence: String, maxTokens: Int) async throws -> Data {
        try await generate(instruction: instruction, evidence: evidence, maxTokens: maxTokens, prefill: "")
    }
    func generate(instruction: String, evidence: String, maxTokens: Int, prefill: String) async throws -> Data {
        self.evidence.append(evidence)
        let rx = try! NSRegularExpression(pattern: #"(?m)^([in]\d+)\. "#)
        let ids = rx.matches(in: evidence, range: NSRange(evidence.startIndex..., in: evidence)).map { "\"" + (evidence as NSString).substring(with: $0.range(at: 1)) + "\"" }
        return Data((#"{"title":"Launch checklist","bullets":[{"ids":["# + ids.joined(separator: ",") + #"],"text":"Drafted the launch checklist in TextEdit."}]}"#).utf8)
    }
    func saw(_ words: String) -> Bool { evidence.contains { $0.contains(words) } }
}
actor TestKeys: WriterSecureKeyStore {
    var value = ""
    func readSecret() async throws -> String { value }
    func saveSecret(_ value: String) async throws { self.value = value }
    func removeSecret() async throws { value = "" }
}
actor FakeOpenRouter {
    var bodies: [Data] = []
    func send(_ request: URLRequest) throws -> CloudHTTPResponse {
        bodies.append(request.httpBody ?? Data())
        return CloudHTTPResponse(status: 200, body: Data(#"{"model":"deepseek/deepseek-v4-flash-0731","choices":[{"message":{"content":"OK"}}]}"#.utf8))
    }
}

@main struct SummariesThisMacChecks {
    static var passed = 0, failed = 0
    static func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1; print("PASS " + label) } else { failed += 1; print("FAIL " + label + { let d = detail(); return d.isEmpty ? "" : " — " + d }()) }
    }
    static func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    struct Rig { let store: MemoryStore, writer: WriterIntegration, model: FakeModel, http: FakeOpenRouter, keys: TestKeys, defaults: UserDefaults }
    static let typedKeys = InMemoryTypedKeyStore()
    static var root: URL!
    /// Three hours back (as writer-state's rig): inside typed words' keep period; a start outside 01:00-20:00 moves to the
    /// nearest earlier noon, so no scenario crosses local midnight.
    static let clock: Clock = {
        let start = Date().addingTimeInterval(-3 * 3600), calendar = Calendar.current
        let hour = calendar.component(.hour, from: start)
        guard hour < 1 || hour >= 20 else { return Clock(start) }
        let day = calendar.startOfDay(for: start)
        return Clock(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: hour < 1 ? calendar.date(byAdding: .day, value: -1, to: day)! : day)!)
    }()

    /// The writer over the store at `home` (a relaunch when `fresh` is false: same store, defaults, keys and model).
    @MainActor static func rig(fresh: Bool, suite: String, keys: TestKeys, model: FakeModel) throws -> Rig {
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        try store.attachVault(TypedTextVault(keyStore: typedKeys))
        if fresh {
            var consent = try store.policy(); consent.captureText = true; consent.typedConsentVersion = 1; try store.updatePolicy(consent)
            try store.setUpTypedVault(); try store.acceptSafeTyping()
            var typed = try store.typedTextPolicy()
            typed.categories = TypedCategoryChoices(searchAndAI: true, writing: true, code: true, messagesAndEmail: true, otherWebsites: true)
            _ = try store.updateTypedTextPolicy(typed, confirmed: true)
        }
        let http = FakeOpenRouter()
        let defaults = UserDefaults(suiteName: suite)!
        let idle = WriterIntegration.idleClose + 60
        var env = WriterEnvironment()
        env.now = { clock.now }; env.power = { .ac }; env.idleSeconds = { idle }; env.typingSeconds = { 1_000_000 }
        env.defaults = defaults; env.makeRuntime = { _ in model }; env.automatic = false
        env.unloadSleep = { _ in try await Task.sleep(nanoseconds: 1_000_000_000_000) }
        env.freeBytes = { _ in 100_000_000_000 }
        let fake = CompatibleWriterFiles(model: home.appendingPathComponent("fake.model"), library: home.appendingPathComponent("fake.dylib"))
        var admission = LocalAdmission(restoreOffline: { _, _ in fake }, checkWithApple: {}, signedBuild: { false })
        admission.download = { _, progress in progress(.downloading(1, 1)); return fake }
        let writer = WriterIntegration(modelRoot: home.appendingPathComponent("Models"), keyStore: keys, send: { try await http.send($0) },
                                       admission: admission, environment: env)
        writer.offerLocal = true
        writer.configure(store: store)
        return Rig(store: store, writer: writer, model: model, http: http, keys: keys, defaults: defaults)
    }
    @MainActor static func settle(_ rig: Rig) async { for _ in 0..<300 where rig.writer.busy { await sleep(0.02) } }
    @MainActor static func waitOn(_ rig: Rig, _ mode: SummaryMode) async -> Bool {
        for _ in 0..<300 { if rig.writer.phase == .on(mode) { return true }; await sleep(0.02) }
        return false
    }

    /// One closed moment ending `ago` seconds before the clock, with a typed draft holding `words`.
    static func moment(_ store: MemoryStore, _ id: String, words: String, ago: TimeInterval = 900) throws {
        let end = clock.now.addingTimeInterval(-ago)
        for k in 0..<3 {
            let at = end.addingTimeInterval(-Double(2 - k) * 2)
            if k == 1 {
                let unit: [String: Any] = ["version": "typed-unit/v3", "runID": "\(id)-run", "part": 1, "sealReason": "idle", "startedAt": iso(at.addingTimeInterval(-20)),
                                           "withheld": 0, "surface": "writing", "field": "unknown", "send": "none"]
                let row: [String: Any] = ["id": "\(id)-\(k)", "at": iso(at), "kind": "keyboard.text_input", "app": "TextEdit", "bundle": "com.apple.TextEdit",
                                          "title": "Launch", "url": "", "text": "Outline the launch checklist \(words)", "secure": false, "privateWindow": false,
                                          "synthetic": true,
                                          "captureProvenance": ["policyRevision": "synthetic", "classifierVersion": "sensitive-typing/v2", "windowID": "w", "focusID": "f",
                                                                "checkedAt": iso(at), "generation": 1, "unit": unit]]
                let e = try JSONDecoder().decode(Evidence.self, from: JSONSerialization.data(withJSONObject: row))
                guard try store.ingest(e, now: at.addingTimeInterval(0.5)) else { throw MemError.invalid("fixture: the typed row was refused at ingest") }
                continue
            }
            _ = try store.ingest(Evidence(id: "\(id)-\(k)", at: iso(at), kind: k == 0 ? "window.changed" : "mouse.click", app: "TextEdit",
                                          bundle: "com.apple.TextEdit", title: "Launch", synthetic: true), now: at.addingTimeInterval(0.5))
        }
    }
    /// Whether the cloud-audience port of the binding WriterIntegration makes reads `words` for today.
    static func cloudPortReads(_ store: MemoryStore, _ words: String) async -> Bool {
        let target = WriterTarget(kind: .day, day: (try? DayScope.key(clock.now, timezone: zone)) ?? "", timezone: zone)
        guard let prepared = try? await WriterIntegration.makeCoreBinding(store: store).port(audience: .cloud).prepare(target) else { return false }
        return prepared.actions.contains { $0.description.contains(words) }
    }
    static func mode(_ store: MemoryStore) -> String { (try? store.summaryWriter()?.mode) ?? "nil" }

    @MainActor static func run() async throws {
        let suite = "summaries-this-mac-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let keys = TestKeys(), model = FakeModel()
        let controls = SummaryControls.live  // the closures Settings' Summarizer switches call

        // 1. This Mac only, chosen in Settings.
        var rig = try rig(fresh: true, suite: suite, keys: keys, model: model)
        await settle(rig)
        controls.chooseLocal(rig.writer)
        let on = await waitOn(rig, .local)
        check(on, "This Mac only: the Settings switch turns summaries on this Mac on", "\(rig.writer.phase) \(rig.writer.status)")
        check(rig.defaults.string(forKey: WriterIntegration.intentKey) == "local", "This Mac only: the choice is saved as local (not the cloud default)",
              rig.defaults.string(forKey: WriterIntegration.intentKey) ?? "nil")
        check(mode(rig.store) == "local", "This Mac only: AI apps are told local", mode(rig.store))
        try moment(rig.store, "m1", words: "zzqthismacone", ago: 300)
        await rig.writer.pass(.timer)
        let first = await model.saw("zzqthismacone"), looks = await model.evidence.count
        check(first, "This Mac only: the writer on this Mac reads the typed words (the binding is made for the local writer)",
              "\(looks) model calls, none with the words")
        let cloudFirst = await cloudPortReads(rig.store, "zzqthismacone")
        check(!cloudFirst, "This Mac only: the cloud-audience port gets no typed words")

        // 2. A relaunch keeps This Mac only: it never binds back to the cloud default.
        await rig.writer.shutdown()
        rig = try Self.rig(fresh: false, suite: suite, keys: keys, model: model)
        await settle(rig)
        if !(await waitOn(rig, .local)) { controls.chooseLocal(rig.writer) }
        let back = await waitOn(rig, .local)
        check(back && rig.defaults.string(forKey: WriterIntegration.intentKey) == "local",
              "relaunch: summaries on this Mac come back on, still local", "\(rig.writer.phase)")
        clock.advance(1800)  // a moment of its own, half an hour on (never a rewrite of the first)
        try moment(rig.store, "m2", words: "zzqthismactwo", ago: 300)
        await rig.writer.pass(.timer)
        let second = await model.saw("zzqthismactwo")
        check(second, "relaunch: the writer on this Mac still reads the typed words")
        check(mode(rig.store) == "local", "relaunch: AI apps are still told local", mode(rig.store))

        // 3. OpenRouter chosen, then back to This Mac only through the same switch.
        let problem = await controls.chooseCloud(rig.writer, "sk-or-test")
        check(problem == nil && rig.writer.phase == .on(.cloud), "OpenRouter: a working key turns cloud summaries on",
              "\(String(describing: problem)) \(rig.writer.phase)")
        controls.chooseLocal(rig.writer)
        let local3 = await waitOn(rig, .local)
        check(local3 && rig.defaults.string(forKey: WriterIntegration.intentKey) == "local" && mode(rig.store) == "local",
              "back to This Mac only: local is saved and AI apps are told local", "\(rig.writer.phase) \(mode(rig.store))")
        clock.advance(1800)
        try moment(rig.store, "m3", words: "zzqthismacthree", ago: 300)
        await rig.writer.pass(.timer)
        let third = await model.saw("zzqthismacthree")
        check(third, "back to This Mac only: the writer on this Mac reads the typed words again")
        let cloudThird = await cloudPortReads(rig.store, "zzqthismacthree")
        check(!cloudThird, "back to This Mac only: the cloud-audience port gets no typed words")
        await rig.writer.shutdown()
    }

    @MainActor static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        let given = ProcessInfo.processInfo.environment["STATE_CHECK_ROOT"] ?? NSTemporaryDirectory()
        var resolved = given
        if let real = realpath(given, nil) { resolved = String(cString: real); free(real) }
        root = URL(fileURLWithPath: resolved, isDirectory: true).appendingPathComponent("summaries-this-mac-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        do { try await run() } catch { check(false, "summaries-this-mac", "\(error)") }
        print("summaries-this-mac: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
