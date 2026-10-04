import Foundation
import ApplicationServices
import HistoryCore
@testable import MemoryCore
import PrivacyPolicy

private struct Trace: Decodable {
    let schemaVersion: Int
    let synthetic: Bool
    let pieces: [Piece]
}
private struct Piece: Decodable {
    let name: String
    let events: [Event]
    let expectNewWords: [String]
    let expectPending: Bool
    let expectNoAcquisition: Bool
}
private struct Event: Decodable {
    let op: String
    var text: String?; var code: Int64?; var seconds: Double?
    var focus: String?; var window: String?; var known: Bool?; var secure: Bool?
    var privateMode: Bool?; var autocomplete: String?; var fieldLabel: String?
    var notification: String?; var redundantAX: Bool?; var captureText: Bool?
    enum CodingKeys: String, CodingKey {
        case op, text, code, seconds, focus, window, known, secure, autocomplete, fieldLabel
        case privateMode = "private"
        case notification, redundantAX, captureText
    }
}
private struct ReplayError: Error, CustomStringConvertible { let description: String }
private final class Clock {
    var mono: UInt64 = 10_000_000_000
    let wallBase = Date()
    var wall: Date { wallBase.addingTimeInterval(Double(mono - 10_000_000_000) / 1e9) }
    var timers: [(at: UInt64, work: () -> Void)] = []
    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        timers.append((mono + UInt64(max(0, delay) * 1e9), work))
    }
    func advance(_ seconds: Double) throws {
        guard seconds >= 0, seconds <= 60 else { throw ReplayError(description: "Invalid synthetic advance") }
        let target = mono + UInt64(seconds * 1e9)
        var fired = 0
        while let index = timers.indices.filter({timers[$0].at <= target}).min(by: {timers[$0].at < timers[$1].at}) {
            fired += 1
            guard fired <= 10_000 else { throw ReplayError(description: "Synthetic scheduler did not settle") }
            let timer = timers.remove(at: index)
            mono = max(mono, timer.at); timer.work()
        }
        mono = target
    }
}
private final class Metadata {
    var focus = "field-a", window = "window-a", known = true, secure = false, privateMode = false
    var autocomplete = "", fieldLabel = ""
    func proof(_ generation: UInt64, _ version: UInt64, now: UInt64) -> FocusProof? {
        guard known else { return nil }
        var p = FocusProof(); p.generation = generation; p.policyVersion = version; p.checkedAt = now
        p.bundle = "com.apple.TextEdit"; p.windowID = window; p.focusID = focus; p.role = "AXTextArea"
        p.surface = .native; p.secureInput = secure ? .yes : .no; p.privateMode = privateMode ? .yes : .no
        p.autocomplete = autocomplete; p.fieldLabel = fieldLabel
        p.verified = true; p.fieldStateVerified = true; p.frameAccessible = true; p.navigationStable = true
        return p
    }
}
@main private struct SessionReplay {
    static func main() {
        setbuf(stdout, nil)
        do { try run() }
        catch {
            FileHandle.standardError.write(Data(("FAIL replay: " + String(describing: error) + "\n").utf8))
            exit(1)
        }
    }
    static func run() throws {
        guard CommandLine.arguments.count == 3 else { throw ReplayError(description: "usage: session-replay TRACE.json OWN-SCRATCH") }
        let trace = try JSONDecoder().decode(Trace.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        guard trace.schemaVersion == 1, trace.synthetic else { throw ReplayError(description: "Only explicitly synthetic schema 1 traces are accepted") }
        let root = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        // The wrapper creates a fresh run directory. Refuse an existing memory database.
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("on/memory.sqlite").path),
              !FileManager.default.fileExists(atPath: root.appendingPathComponent("off/memory.sqlite").path) else {
            throw ReplayError(description: "Replay root already contains a store")
        }
        for enabled in [true, false] { try replay(trace, enabled: enabled, root: root.appendingPathComponent(enabled ? "on" : "off")) }
        print("PASS same fabricated transcript replayed with capture text ON and OFF")
    }
    static func replay(_ trace: Trace, enabled: Bool, root: URL) throws {
        let store = try MemoryStore(home: root, writable: true, automaticallySyncSearch: false)
        try store.attachVault(TypedTextVault(keyStore: InMemoryTypedKeyStore()))
        try store.setUpTypedVault(); try store.acceptSafeTyping()
        let clock = Clock(), metadata = Metadata()
        let coordinator = try Coordinator(store: store, permissions: { true }) {}
        // No real permission reads, event tap, AX observer, workspace observer or capture.start().
        let oldKeyFocus = NativeTypingRoute.keyFocus, oldBundleOf = NativeTypingRoute.bundleOf
        NativeTypingRoute.keyFocus = { nil }; NativeTypingRoute.bundleOf = { _ in nil }
        defer { NativeTypingRoute.keyFocus = oldKeyFocus; NativeTypingRoute.bundleOf = oldBundleOf }
        coordinator.captureBinding.wallClock = { clock.wall }
        func setting(_ requested: Bool) throws {
            var policy = try store.policy(); policy.captureText = enabled && requested; policy.typedConsentVersion = 1
            try store.updatePolicy(policy); coordinator.policyChanged(); coordinator.captureText = enabled && requested
        }
        try setting(true); try coordinator.start(permitted: true)
        // Every page-system closure is inert, even if a future routing change reaches it.
        let page = ChromePageEnvironment(frontmost: { nil }, instances: { 0 }, secureInput: { false },
            verify: { _, _ in false }, permission: { _ in -1 }, transport: { _ in { _ in nil } },
            background: { _ in }, main: { _ in }, schedule: { _, _ in }, now: { clock.wall })
        let capture = EventCapture(coordinator: coordinator, typingEnvironment: .init(now: { clock.mono },
            proof: { generation, version in metadata.proof(generation, version, now: clock.mono) },
            schedule: clock.schedule, secureInput: { metadata.secure },
            departure: { DepartureState(secureInput: metadata.secure ? .yes : .no, bundle: "com.apple.TextEdit", focusSecure: metadata.secure ? .yes : .no) },
            pressAndHold: { true }), pageEnvironment: page)
        var attempted = 0, acquired = 0, failures = 0
        func persistedIDs() throws -> [String] {
            try store.rows("SELECT id FROM records WHERE json_extract(body,'$.kind')='keyboard.text_input' ORDER BY rowid").map { $0[0] }
        }
        func visibleWords(_ ids: [String]) throws -> [String] {
            try ids.compactMap { try store.hydrateTypedText($0, disclosure: .owner) }
        }
        func assertion(_ ok: Bool, _ description: String) {
            if !ok { failures += 1; print("FAIL \(enabled ? "on" : "off") \(description)") }
        }
        func key(_ text: String, code: Int64 = 0) throws {
            try clock.advance(0.08); attempted += text.count
            capture.handleNativeKey(eventAt: clock.mono, stroke: KeyStroke(keyCode: code)) {
                acquired += text.count; return text
            }
        }
        var expected = [String]()
        for piece in trace.pieces {
            let beforeIDs = try persistedIDs(), attemptedBefore = attempted, acquiredBefore = acquired
            for event in piece.events {
                switch event.op {
                case "type":
                    for character in event.text ?? "" {
                        try key(String(character))
                        if event.redundantAX == true {
                            capture.handleAX(kAXFocusedUIElementChangedNotification as String)
                            capture.handleAX(kAXFocusedWindowChangedNotification as String)
                        }
                    }
                case "key": try key(event.text ?? "", code: event.code ?? 0)
                case "metadata":
                    if let value = event.focus { metadata.focus = value }
                    if let value = event.window { metadata.window = value }
                    if let value = event.known { metadata.known = value }
                    if let value = event.secure { metadata.secure = value }
                    if let value = event.privateMode { metadata.privateMode = value }
                    if let value = event.autocomplete { metadata.autocomplete = value }
                    if let value = event.fieldLabel { metadata.fieldLabel = value }
                case "ax":
                    guard ["focus", "window"].contains(event.notification ?? "") else { throw ReplayError(description: "Unknown AX fixture notification") }
                    capture.handleAX(event.notification == "focus" ? kAXFocusedUIElementChangedNotification as String : kAXFocusedWindowChangedNotification as String)
                case "wait": try clock.advance(event.seconds ?? 0)
                case "resolve": capture.resolveParkedTyping(force: true)
                case "flush": capture.flushNativeText()
                case "settings": try setting(event.captureText ?? false)
                case "pause": coordinator.pause("Synthetic replay paused.")
                case "resume":
                    try coordinator.start(permitted: true)
                    let savedPolicy = try store.policy(); coordinator.captureText = enabled && savedPolicy.captureText
                default: throw ReplayError(description: "Unknown fixture operation: " + event.op)
                }
            }
            if enabled { expected.append(contentsOf: piece.expectNewWords) }
            let afterIDs = try persistedIDs(), beforeSet = Set(beforeIDs)
            let newIDs = afterIDs.filter { !beforeSet.contains($0) }
            let after = try visibleWords(afterIDs), newWords = try visibleWords(newIDs)
            let typingVisible = (try store.policy()).captureText
            let expectedVisible = typingVisible ? expected : []
            let expectedNew = enabled ? piece.expectNewWords : []
            let offered = attempted - attemptedBefore, read = acquired - acquiredBefore
            assertion(after == expectedVisible, piece.name + " exact policy-visible words mismatch")
            assertion(newWords == expectedNew, piece.name + " exact newly persisted words mismatch")
            assertion(afterIDs.count == expected.count, piece.name + " persisted typed row count mismatch")
            assertion(beforeSet.isSubset(of: Set(afterIDs)), piece.name + " prior persisted rows were deleted")
            assertion(newIDs.count == expectedNew.count, piece.name + " newly persisted row count mismatch")
            assertion(coordinator.captureBinding.hasPendingTyping == (enabled && piece.expectPending), piece.name + " pending-live mismatch")
            if piece.expectNoAcquisition || !enabled { assertion(read == 0, piece.name + " denied input acquired characters") }
            let raw = try store.rows("SELECT body FROM records").map { $0[0] }.joined(separator: "\n")
            for word in expected { assertion(!raw.contains(word), piece.name + " typed body leaked into raw records") }
            for secret in ["sk-abcdefghijkl0123", "482913", "fabricated-password-cedar"] {
                assertion(!raw.contains(secret) && !after.contains(where: { $0.contains(secret) }), piece.name + " synthetic sentinel leaked")
            }
            let receipt: [String: Any] = ["policy": enabled ? "on" : "off", "piece": piece.name,
                "attemptedCharacters": offered, "acquiredCharacters": read, "droppedBeforeAcquisitionCharacters": offered - read,
                "savedPieces": newIDs.count, "persistedRows": afterIDs.count, "visibleRows": after.count,
                "typingPolicyVisible": typingVisible, "priorRowsRetained": beforeSet.isSubset(of: Set(afterIDs)),
                "pendingLive": coordinator.captureBinding.hasPendingTyping,
                "parkedDeadlinePresent": coordinator.captureBinding.typingDeadlines().parked != nil,
                "exactSavedWordsMatch": after == expectedVisible && newWords == expectedNew,
                "failuresSoFar": failures]
            print(String(decoding: try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]), as: UTF8.self))
        }
        coordinator.stop(); clock.timers.removeAll()
        guard failures == 0 else { throw ReplayError(description: "Replay had \(failures) assertion failures") }
    }
}
