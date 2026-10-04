// DD-RECIPE: APP
// gold r3-store (golden test 5, gate item 5): the main thread is never held over 100 ms by the history in the owner's
// everyday actions, and no click is lost while another connection holds the history. On the REAL MemoryViewModel with
// the check seams (no event tap, no login item, in-memory launch-intent defaults, fake lock and console reads and a fake
// notice center; run-checks.sh sets a synthetic HOME and CFFIXED_USER_HOME). Nothing records: a "recording" session is
// rows in a private store made here (synthetic rows only), and the clicks are fed to the recorder as EventCapture feeds
// them. The recorder's 0.5 s heartbeat runs as EventCapture.start makes it (reconcileResume on a common-modes timer).
// The main thread's hold is measured by a thread that pings the main queue every few milliseconds (the longest wait for
// a ping inside the row's window).
//   H1 (save)    A saved app choice on a history with a few thousand rows: the timeline read after it (1000 rows)
//                held the main thread 116-243 ms. Now: under 100 ms, and the list then leaves the app out.
//   H2 (forget)  Correct a moment, then Forget it through the real alert (momentForgetConfirmation on the model's own
//                browser): the preview held the main thread 467-525 ms, and the commit (it checks the scope again) and
//                the list read after it more. Now each under 100 ms (AppKit putting the alert up or taking it down is
//                left out: a wait whose stack shows only the alert, or that began after the preview was written); the
//                alert asks with the preview's count and Forget deletes exactly that many actions. Races: the moment changed while its
//                preview is made asks about the new one only, and a request cleared meanwhile asks nothing; neither
//                leaves a preview token open.
//   H3 (slow save)  Three 0.9 s holds while clicking: each click waited on the main thread for the hold (up to 977 ms).
//                Now under 100 ms, and every click is saved.
//   H4 (lost click) A 2.5 s hold while clicking: a click waited 1.5 s and was then dropped (fed 40, saved 39). Now none
//                is lost, none waits on the main thread over 100 ms, recording stays on and nothing is said.
//   H5 (order)   The clicks of H4 are saved in the order they were made, each once.
//   H6 (pause)   Pause during a hold: the clicks made before it are saved, none after it.
//   H7 (long hold) An 8 s hold: recording is still on at 3 s, pauses after about 4.5 s held (three heartbeats' busy
//                timeouts, as before), and starts again by itself once the history is free.
//   H8 (policy)  An app excluded by another connection (mac-mem, another window) is not saved from the next click on.
// Before this (3f70834): H1, H2, H3 and H4 fail (the holds above; H4 also loses a click, fed 40, saved 39), and H7 too:
// the clicks and heartbeats held the main thread in turn for the whole hold, so it couldn't look at 3 s and the pause
// came only after the hold. H5, H6, H8 and the race rows pass on both: they guard the order, pause and privacy behaviour
// the fix must keep.
import AppKit
import CSQLite
import HistoryCore
import MemoryCore
import MemoryUI
import PrivacyPolicy
import SwiftUI

@MainActor enum Report {
    static var passed = 0, failed = 0
    static func check(_ ok: Bool, _ id: String, _ message: @autoclosure () -> String) {
        if ok { passed += 1; print("PASS [\(id)] \(message())") } else { failed += 1; print("FAIL [\(id)] \(message())") }
        fflush(stdout)
    }
}
@MainActor func check(_ ok: Bool, _ id: String, _ message: @autoclosure () -> String) { Report.check(ok, id, message()) }
func note(_ s: String) { print("NOTE \(s)"); fflush(stdout) }
func stop(_ message: String) -> Never { fflush(stdout); FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
@MainActor func tick(_ seconds: Double = 0.05) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
@MainActor @discardableResult func waitFor(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if condition() { return true }; await tick(0.02) }
    return condition()
}
func makePrivateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

/// Launch-intent defaults kept in memory only (no suite, nothing reaches cfprefsd).
final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    init(inMemory: Void = ()) { super.init(suiteName: nil)! }
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) {
        if let value { values[defaultName] = value } else { values.removeValue(forKey: defaultName) }
    }
    override func removeObject(forKey defaultName: String) { values.removeValue(forKey: defaultName) }
    override func dictionary(forKey defaultName: String) -> [String: Any]? { values[defaultName] as? [String: Any] }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func bool(forKey defaultName: String) -> Bool { (values[defaultName] as? NSNumber)?.boolValue ?? false }
    override func set(_ value: Bool, forKey defaultName: String) { values[defaultName] = value }
    override func double(forKey defaultName: String) -> Double { (values[defaultName] as? NSNumber)?.doubleValue ?? 0 }
    override func set(_ value: Double, forKey defaultName: String) { values[defaultName] = value }
    override func integer(forKey defaultName: String) -> Int { (values[defaultName] as? NSNumber)?.intValue ?? 0 }
    override func set(_ value: Int, forKey defaultName: String) { values[defaultName] = value }
}
@MainActor final class FakeNotices {
    var posted: [RecordingNotice] = []
    var center: RecordingNoticeCenter { RecordingNoticeCenter(prepare: {}, post: { self.posted.append($0) }, clear: {}) }
}
@MainActor final class FakeWake {
    var system: WakeSystem {
        WakeSystem(screenLocked: { false }, onConsole: { true },
                   after: { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }, now: { Date() })
    }
}

// MARK: - The main thread's longest wait (a ping to the main queue every few milliseconds, its stack by a signal)

final class Flag: @unchecked Sendable {
    private let l = NSLock(); private var v = false
    func set() { l.lock(); v = true; l.unlock() }
    func get() -> Bool { l.lock(); defer { l.unlock() }; return v }
}
nonisolated(unsafe) let stallBuffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 128)
nonisolated(unsafe) var stallDepth: Int32 = 0
nonisolated(unsafe) var stallTaken: Int32 = 0
func stallSignal(_ signal: Int32) { stallDepth = backtrace(stallBuffer, 128); stallTaken = 1 }
final class MainHold: @unchecked Sendable {
    static let shared = MainHold()
    private let lock = NSLock()
    private var armed = false
    private var main: pthread_t?
    /// When the ping in flight was sent (0: none): a wait still going on at `end` counts too.
    private var pendingSince: UInt64 = 0
    struct Wait { let ms: Double; let frames: [String]; var at: UInt64 = 0 }
    private var waits: [Wait] = []
    /// The longest wait of 100 ms or less (the longer ones are in `waits`).
    private var worst = 0.0
    func start() {
        main = pthread_self()
        var action = sigaction()
        action.__sigaction_u.__sa_handler = stallSignal
        action.sa_flags = SA_RESTART
        sigemptyset(&action.sa_mask)
        sigaction(SIGUSR2, &action, nil)
        let t = Thread { [self] in
            while true {
                let box = Flag()
                let sent = DispatchTime.now().uptimeNanoseconds
                lock.lock(); pendingSince = sent; lock.unlock()
                DispatchQueue.main.async { box.set() }
                var signals = 0
                while !box.get() {
                    usleep(500)
                    // The main thread's stack, taken by a signal once it has waited 60 ms (again every 20 ms while no
                    // stack came back: a signal can land while the thread can't take it).
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1e6
                    if let main, stallTaken == 0 || signals == 0, ms > 60 + Double(signals) * 20, signals < 8 {
                        if signals == 0 { stallTaken = 0 }
                        signals += 1; pthread_kill(main, SIGUSR2)
                    }
                }
                let waited = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1e6
                var frames: [String] = []
                if waited > 100, stallTaken == 1, let symbols = backtrace_symbols(stallBuffer, stallDepth) {
                    for i in 0..<Int(stallDepth) {
                        guard let c = symbols[i] else { continue }
                        let f = String(cString: c).split(separator: " ").dropFirst(3).prefix(1).joined()
                        if !f.contains("stallSignal") && f != "_sigtramp" { frames.append(String(f.prefix(120))) }
                    }
                    free(symbols)
                }
                lock.lock()
                pendingSince = 0
                if armed {
                    if waited > 100 { waits.append(Wait(ms: waited, frames: frames, at: sent)) } else { worst = max(worst, waited) }
                }
                lock.unlock()
                usleep(3000)
            }
        }
        t.name = "store-main-hold-monitor"
        t.start()
    }
    func begin() { lock.lock(); worst = 0; waits = []; armed = true; lock.unlock() }
    /// A wait that is only SwiftUI putting an alert up or taking it down (no store frame in its stack) is not the
    /// store's; every other wait over 100 ms counts, one whose stack couldn't be taken included.
    static func alertOnly(_ w: Wait) -> Bool {
        let text = w.frames.joined(separator: " ")
        let store = text.contains("MemoryCore") || text.contains("sqlite3") || text.contains("StoreLock")
        return !store && (text.contains("AppKitDialogBridge") || text.contains("NSAlert") || text.contains("_NSAlert"))
    }
    /// The longest the main thread took to answer a ping since `begin`, in ms, alert presentation left out, and the
    /// stack of each wait over 100 ms printed. A wait still going on counts too (one that ended just now is recorded
    /// a moment later).
    /// - after: waits that began after this time (uptime ns) are left out too (`forget`: AppKit putting the alert up
    ///   once the preview was written).
    @MainActor func end(after: UInt64? = nil) async -> Double {
        lock.lock()
        armed = false
        let pending = pendingSince != 0 ? Double(DispatchTime.now().uptimeNanoseconds - pendingSince) / 1e6 : 0
        lock.unlock()
        await tick(0.05)
        lock.lock()
        var all = waits
        if pending > 100, !all.contains(where: { abs($0.ms - pending) < 60 }) { all.append(Wait(ms: pending, frames: ["(still waiting at the end)"])) }
        waits = []
        lock.unlock()
        var counted = worst
        for w in all {
            let alert = Self.alertOnly(w) || (after.map { w.at > $0 } ?? false)
            if !alert { counted = max(counted, w.ms) }
            note("STALL \(Int(w.ms)) ms\(alert ? " (the alert going up or down, not counted)" : ""): " + w.frames.filter { $0.hasPrefix("$s") || $0.contains("sqlite") || $0.contains("NSAlert") }.prefix(12).joined(separator: " < "))
        }
        return counted
    }
}

// MARK: - Another connection (reads off the main thread; holds on their own thread)

final class SQL: @unchecked Sendable {
    let path: String
    init(_ path: String) { self.path = path }
    func rows(_ sql: String, _ args: [String] = []) -> [[String?]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 10000)
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [["ERR " + String(cString: sqlite3_errmsg(db))]] }
        defer { sqlite3_finalize(st) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() { sqlite3_bind_text(st, Int32(i + 1), a, -1, transient) }
        var out: [[String?]] = []
        while sqlite3_step(st) == SQLITE_ROW {
            var row: [String?] = []
            for c in 0..<sqlite3_column_count(st) { row.append(sqlite3_column_text(st, c).map { String(cString: $0) }) }
            out.append(row)
        }
        return out
    }
    /// Holds the write lock (BEGIN EXCLUSIVE) for `seconds` on its own thread; returns once it is held.
    func hold(_ seconds: Double) -> Flag {
        let held = DispatchSemaphore(value: 0), done = Flag(), path = path
        Thread.detachNewThread {
            var db: OpaquePointer?
            sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil)
            sqlite3_busy_timeout(db, 10000)
            sqlite3_exec(db, "BEGIN EXCLUSIVE", nil, nil, nil)
            held.signal()
            Thread.sleep(forTimeInterval: seconds)
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
            sqlite3_close(db)
            done.set()
        }
        held.wait()
        return done
    }
}

/// The moment a Forget preview is written (a pending row in deletion_previews), seen from another connection.
final class PreviewWatch: @unchecked Sendable {
    private let l = NSLock(); private var seen: UInt64?; private var done = false
    var at: UInt64? { l.lock(); defer { l.unlock() }; return seen }
    func stop() { l.lock(); done = true; l.unlock() }
    init(_ path: String) {
        let reader = SQL(path)
        Thread.detachNewThread { [self] in
            while true {
                l.lock(); let finished = done || seen != nil; l.unlock()
                if finished { return }
                if let n = Int((reader.rows("SELECT count(*) FROM deletion_previews WHERE state='pending'").first?.first ?? nil) ?? ""), n > 0 {
                    l.lock(); seen = DispatchTime.now().uptimeNanoseconds; l.unlock()
                }
                usleep(2000)
            }
        }
    }
}

// MARK: - The recorder's heartbeat, as EventCapture.start adds it beside the tap (the check never starts a tap)

@MainActor enum Rec {
    static var model: MemoryViewModel?
    static var capture: EventCapture?
    static var captures = 0
    static var beats = 0
    static var activity: NSObjectProtocol?
    static var fed: [String: Int] = [:]
}
@MainActor func attachRecorder(_ capture: EventCapture) {
    Rec.capture = capture; Rec.captures += 1
    weak var model = Rec.model
    let timer = Timer(timeInterval: 0.5, repeats: true) { [weak capture] t in
        MainActor.assumeIsolated {
            guard let capture, !capture.isStopped, let c = model?.coordinator else { t.invalidate(); return }
            c.reconcileResume(); Rec.beats += 1
            if !c.recordingSettled { capture.stop(reason: "Recording stopped") }
        }
    }
    timer.tolerance = 0.1
    RunLoop.main.add(timer, forMode: .common)
}

// MARK: - Hosting the Forget alert (as dd-kit-checks does)

final class ForgetBox: ObservableObject { @Published var request: MomentForgetRequest?; var errors: [String] = [] }
struct ForgetHost: View {
    @ObservedObject var box: ForgetBox
    let browser: ActivityBrowser
    let forgotten: (String) -> Void
    var body: some View {
        Color.clear.frame(width: 320, height: 200)
            .momentForgetConfirmation(browser: browser, request: $box.request, onForgotten: forgotten, onError: { box.errors.append($0) })
    }
}

@main @MainActor struct StoreMainHoldChecks {
    static var out = URL(fileURLWithPath: "/")
    static var home = URL(fileURLWithPath: "/")
    static var sql = SQL("/")
    static let limit = 100.0
    static var notices = FakeNotices()
    static let apps: [(String, String)] = [
        ("Notes", "com.apple.Notes"), ("Terminal", "com.apple.Terminal"), ("Xcode", "com.apple.dt.Xcode"),
        ("Mail", "com.apple.mail"), ("Preview", "com.apple.Preview"), ("Pages", "com.apple.iWork.Pages"),
    ]

    static func main() async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 420) {
            FileHandle.standardError.write(Data("FAIL: store-main-hold-checks watchdog expired after 420s\n".utf8)); exit(2)
        }
        let env = ProcessInfo.processInfo.environment
        let shared = ["/private/tmp/" + "day" + "dream-", "/tmp/" + "day" + "dream-"]
        guard let outPath = env["DD_CHECK_OUT"], outPath.hasPrefix("/"), !shared.contains(where: { outPath.hasPrefix($0) }) else {
            stop("DD_CHECK_OUT is not a private output directory; run this check through run-checks.sh")
        }
        guard let fixed = env["CFFIXED_USER_HOME"], env["HOME"] == fixed, fixed != "/Users/" + NSUserName(),
              FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path == URL(fileURLWithPath: fixed).standardizedFileURL.path else {
            stop("HOME and CFFIXED_USER_HOME must name one synthetic home; run this check through run-checks.sh")
        }
        out = URL(fileURLWithPath: outPath, isDirectory: true).appendingPathComponent("store-main-hold", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        do { try makePrivateDirectory(out) } catch { stop("output: \(error)") }
        MemoryViewModel.permissionsGranted = { true }
        MemoryViewModel.permissionRead = { PermissionSnapshot(accessibility: true, inputMonitoring: true) }
        MemoryViewModel.startInput = { capture in MainActor.assumeIsolated { attachRecorder(capture) }; return true }
        MemoryViewModel.readLaunchLocation = { .applications }
        MemoryViewModel.canReopen = { true }
        UserDefaults.standard.register(defaults: [MemoryViewModel.setupCompletedKey: true])
        EventCapture.reenableTap = { _ in note("REAL TAP?!"); return false }
        EventCapture.remakeTap = { _ in note("REAL TAP?!"); return false }
        EventCapture.registerAX = { _, _, _ in note("REAL AX?!"); return (nil, true) }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        MainHold.shared.start()
        // What EventCapture.start holds while recording (no App Nap: the heartbeat's timer runs on time).
        Rec.activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "store-main-hold-checks")

        home = out.appendingPathComponent("history-" + UUID().uuidString, isDirectory: true)
        do { try makePrivateDirectory(home); try seed(home) } catch { stop("seed: \(error)") }
        sql = SQL(home.appendingPathComponent("memory.sqlite").path)
        setenv("MAC_MEM_HOME", home.path, 1)
        MemoryViewModel.launchIntentDefaults = MemoryDefaults()
        let model = MemoryViewModel()
        MemoryViewModel.launchIntentDefaults = nil
        model.noticeCenter = notices.center
        model.wakeSystem = FakeWake().system
        Rec.model = model
        guard await waitFor(20, { !model.history.busy && !model.items.isEmpty }) else { stop("the seeded history didn't open: \(model.items.count) items") }
        await tick(1.0)

        // HOLD_ONLY=H7 (a comma list) runs only those rows, for a focused look; the runner runs them all.
        let only = env["HOLD_ONLY"].flatMap { $0.isEmpty ? nil : $0 }.map { Set($0.split(separator: ",").map(String.init)) }
        func want(_ row: String) -> Bool { only?.contains(row) ?? true }
        if want("H1") { await saveChoice(model) }
        if want("H2") { await forget(model); await forgetRaces(model) }
        model.startCapture()
        guard await waitFor(5, { model.recording && Rec.capture != nil && model.coordinator?.isRunning == true }) else { stop("recording didn't start: \(model.recordingState)") }
        await tick(0.6)
        if want("H3") { await slowSaves(model) }
        if want("H4") { await lostClick(model) }
        if want("H6") { await pauseDuringHold(model) }
        if want("H7") { await longHold(model) }
        if want("H8") { await externalPolicy(model) }

        print("store-main-hold: \(Report.passed) passed, \(Report.failed) failed")
        fflush(stdout)
        exit(Report.failed == 0 ? 0 : 1)
    }

    // MARK: A history of a few thousand synthetic rows (yesterday 08:00-18:00, and today)

    static func seed(_ home: URL) throws {
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        let settings = try store.policy()
        var db: OpaquePointer?
        guard sqlite3_open(home.appendingPathComponent("memory.sqlite").path, &db) == SQLITE_OK else { throw MemError.missing }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 10000)
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var insR: OpaquePointer?, insS: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO records VALUES(?,?,?)", -1, &insR, nil)
        sqlite3_prepare_v2(db, "INSERT INTO summaries VALUES(?,?,?)", -1, &insS, nil)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        func bind(_ st: OpaquePointer?, _ values: [String]) throws {
            sqlite3_reset(st)
            for (i, v) in values.enumerated() { sqlite3_bind_text(st, Int32(i + 1), v, -1, transient) }
            guard sqlite3_step(st) == SQLITE_DONE else { throw MemError.invalid(String(cString: sqlite3_errmsg(db))) }
        }
        let now = Date(), cal = Calendar.current
        let kinds = ["mouse.click", "mouse.click", "window.changed", "app.activated", "keyboard.shortcut", "mouse.click"]
        let yesterday = cal.date(bySettingHour: 8, minute: 0, second: 0, of: cal.date(byAdding: .day, value: -1, to: now)!)!
        let today = max(cal.startOfDay(for: now).addingTimeInterval(60), now.addingTimeInterval(-3 * 3600))
        var total = 0
        for (start, span, count) in [(yesterday, 10.0 * 3600, 2400), (today, now.addingTimeInterval(-300).timeIntervalSince(today), 1200)] {
            let session = UUID().uuidString
            for i in 0..<count {
                let block = i / 40
                let app = apps[(block * 5 + i / 300) % apps.count]
                let at = start.addingTimeInterval(span * Double(i) / Double(count))
                let e = Evidence(id: "native-\(session)-\(i)", at: iso(at), kind: kinds[i % kinds.count], app: app.0, bundle: app.1,
                                 title: "Synthetic document \(block % 53) - \(app.0) - quarterly planning notes, draft \(i % 7), shared folder review and follow-ups")
                guard let clean = Privacy.sanitized(e, settings: settings, now: now) else { continue }
                let body = try json(clean)
                try bind(insR, [clean.id, body, fingerprint(body)])
                let item = IntentWriter.write(clean, now: now)
                try bind(insS, [item.id, try json(item), fingerprint(body)])
                total += 1
            }
        }
        sqlite3_finalize(insR); sqlite3_finalize(insS)
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw MemError.invalid("seed commit") }
        note("seeded \(total) synthetic rows")
    }
    static func count(_ query: String, _ args: [String] = []) async -> Int {
        let s = sql
        let r = await withCheckedContinuation { c in DispatchQueue.global().async { c.resume(returning: s.rows(query, args)) } }
        return Int((r.first?.first ?? nil) ?? "-1") ?? -1
    }
    static func saved(_ tag: String) async -> Int {
        await count("SELECT count(*) FROM records WHERE instr(body, ?) > 0", ["hold-row \(tag) "])
    }
    static func describe(_ m: MemoryViewModel) -> String {
        "\(m.recordingState), session \(m.coordinator?.session.state ?? "none")/\(m.coordinator?.session.reason ?? ""), notices \(notices.posted.map(\.body))"
    }

    // MARK: H1. A saved app choice

    static func saveChoice(_ m: MemoryViewModel) async {
        let bundle = "com.apple.Notes"
        let before = m.items.filter { $0.evidence.bundle == bundle }.count
        check(before > 0 && m.items.count >= 900, "harness", "the list shows the seeded history (\(m.items.count) items, \(before) from Notes)")
        MainHold.shared.begin()
        m.exclusionPreference.wrappedValue = bundle
        m.saveWaitingChoices()
        let gone = await waitFor(10) { !m.items.isEmpty && !m.items.contains { $0.evidence.bundle == bundle } && !m.preferencesUnresolved }
        await tick(0.8)
        let worst = await MainHold.shared.end()
        check(gone, "H1-save", "the saved app choice lands and the list leaves the app out (\(m.items.count) items)")
        check(worst < limit, "H1-save-hold", "saving an app choice holds the main thread under \(Int(limit)) ms: longest \(Int(worst)) ms")
    }

    // MARK: H2. Correct, then Forget through the real alert

    static let window: NSWindow = {
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 420, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        w.orderFrontRegardless()
        return w
    }()
    static func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
    static func sheet() -> (texts: [String], buttons: [NSButton])? {
        guard let s = window.attachedSheet, let cv = s.contentView else { return nil }
        let all = views(cv)
        return (all.compactMap { ($0 as? NSTextField)?.stringValue }.filter { !$0.isEmpty }, all.compactMap { $0 as? NSButton })
    }
    static func click(_ title: String) async -> Bool {
        guard let b = sheet()?.buttons.first(where: { $0.title == title }) else { return false }
        b.performClick(nil)
        await tick(0.3)
        return true
    }
    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
    static func slice(_ a: ActivityNote) -> MomentSlice? {
        guard let start = date(a.start), let end = date(a.end) else { return nil }
        return MomentSlice(id: a.id, dayKey: a.day, start: start, end: end, title: a.subject, subject: a.subject, firstBullet: nil,
                           bullets: [], apps: a.apps, primaryBundle: nil, bundles: [], sites: a.sites, actionIDs: a.actionIDs,
                           actionCount: a.actionIDs.count, clusters: [start...end], summary: .pending, hasCorrection: false,
                           timeZoneID: a.timezone)
    }
    static var box = ForgetBox()
    static var forgotten: [String] = []
    static func host(_ m: MemoryViewModel) async {
        box = ForgetBox()
        window.contentView = NSHostingView(rootView: ForgetHost(box: box, browser: m.activity, forgotten: { forgotten.append($0) }))
        await tick(0.4)
    }
    static func yesterday(_ m: MemoryViewModel) async -> [ActivityNote] {
        guard let load = m.activity.loadCanonicalDay,
              let day = try? DayScope.key(Date().addingTimeInterval(-86_400), timezone: TimeZone.current.identifier),
              let loaded = try? await load(day, nil) else { return [] }
        return loaded.activities
    }
    static func pendingPreviews() async -> Int { await count("SELECT count(*) FROM deletion_previews WHERE state='pending'") }

    static func forget(_ m: MemoryViewModel) async {
        let moments = await yesterday(m)
        guard moments.count > 8, let a = slice(moments[3]) else { check(false, "H2-forget", "yesterday has moments (\(moments.count))"); return }
        let scope = MemoryActionScope(kind: "activity", id: moments[3].id, day: moments[3].day, timezone: moments[3].timezone)
        await host(m)
        // The first alert SwiftUI puts up in this process takes a few hundred ms to make (AppKit's own work, not the
        // store's): one for another moment, cancelled, first (before the Correct, so the day is read again after it).
        if let warm = slice(moments[1]) {
            box.request = MomentForgetRequest(moment: warm, timeZone: .current)
            _ = await waitFor(10) { sheet() != nil }
            await tick(0.3)
            _ = await click("Cancel")
            _ = await waitFor(3) { box.request == nil && sheet() == nil }
            await tick(0.5)
        }
        // Correct (CanonicalTimeline.saveCorrection runs it on the main thread), then Forget the same moment.
        do { try m.activity.correctCanonical?(scope, "Hold check corrected moment", moments[3].inputRevision); check(true, "H2-correct", "Correct saved") }
        catch { check(false, "H2-correct", "Correct failed: \(error)") }
        await tick(0.6)
        let before = await count("SELECT count(*) FROM records")
        // When the preview is written (another connection looks every few ms): the store's part of the question ends
        // there, and what follows is AppKit putting the alert up.
        let written = PreviewWatch(sql.path)
        MainHold.shared.begin()
        box.request = MomentForgetRequest(moment: a, timeZone: .current)
        var asked = await waitFor(10) { sheet() != nil || !box.errors.isEmpty }
        if sheet() == nil, !box.errors.isEmpty {
            // 3f70834 sometimes can't make the preview right after a Correct (the day changed under its read); the
            // owner would ask again. Both waits count.
            note("the first preview failed: \(box.errors); asking again")
            box.errors = []
            box.request = MomentForgetRequest(moment: a, timeZone: .current)
            asked = await waitFor(10) { sheet() != nil }
        }
        asked = sheet() != nil
        await tick(0.2)
        let worst = await MainHold.shared.end(after: written.at)
        written.stop()
        let texts = sheet()?.texts ?? []
        let text = texts.first { $0.hasPrefix("This permanently deletes") } ?? ""
        let n = Int(text.dropFirst("This permanently deletes ".count).prefix { $0.isNumber || $0 == "," }.filter(\.isNumber)) ?? -1
        check(asked && texts.contains("Forget this moment?") && n > 0, "H2-forget", "the alert asks with the preview's count: \(texts) \(box.errors)")
        check(worst < limit, "H2-forget-hold", "Forget's preview after a Correct holds the main thread under \(Int(limit)) ms: longest \(Int(worst)) ms")
        MainHold.shared.begin()
        let pressed = await click("Forget")
        _ = await waitFor(3) { box.request == nil }
        await tick(0.8)
        let commitWorst = await MainHold.shared.end()
        check(commitWorst < limit, "H2-forget-commit-hold", "Forget itself (after the question) holds the main thread under \(Int(limit)) ms: longest \(Int(commitWorst)) ms")
        let after = await count("SELECT count(*) FROM records")
        check(pressed && before - after == n && forgotten == [a.id], "H2-forget-deletes", "Forget deletes exactly the \(n) actions it asked about: before \(before), after \(after), forgotten \(forgotten)")
        let openAfterForget = await pendingPreviews()
        check(openAfterForget == 0, "H2-forget-token", "no preview is left open")
        window.contentView = nil
        await tick(0.2)
    }

    static func forgetRaces(_ m: MemoryViewModel) async {
        let moments = await yesterday(m)
        guard moments.count > 10, let x = slice(moments[6]), let y = slice(moments[9]) else { check(false, "H2-race", "yesterday has moments (\(moments.count))"); return }
        await host(m)
        // The moment changed while its preview is made: the alert asks about the new one only.
        box.request = MomentForgetRequest(moment: x, timeZone: .current)
        await tick(0.02)
        box.request = MomentForgetRequest(moment: y, timeZone: .current)
        let asked = await waitFor(10) { sheet() != nil }
        await tick(0.5)
        let text = (sheet()?.texts ?? []).first { $0.hasPrefix("This permanently deletes") } ?? ""
        let yText = MomentForgetRequest(moment: y, timeZone: .current).message(actionCount: y.actionCount, warning: "")
        check(asked && text.hasPrefix(yText.replacingOccurrences(of: " This can't be undone.", with: "")), "H2-race-switch",
              "a moment changed while its preview is made asks about the new one (\(y.actionCount) actions): \(text)")
        let cancelled = await click("Cancel")
        _ = await waitFor(3) { box.request == nil }
        let openAfterSwitch = await pendingPreviews()
        check(cancelled && openAfterSwitch == 0, "H2-race-switch-token", "Cancel leaves no preview open, the first moment's included")
        // A request cleared while its preview is made asks nothing and leaves no token.
        box.request = MomentForgetRequest(moment: x, timeZone: .current)
        await tick(0.02)
        box.request = nil
        await tick(2.0)
        check(sheet() == nil && window.attachedSheet == nil, "H2-race-clear", "a request cleared while its preview is made asks nothing")
        let openAfterClear = await pendingPreviews()
        check(openAfterClear == 0, "H2-race-clear-token", "and leaves no preview open")
        let records = await count("SELECT count(*) FROM records")
        check(records > 0 && forgotten.count == 1, "H2-race-nothing", "neither race deletes anything (forgotten \(forgotten))")
        window.contentView = nil
        await tick(0.2)
    }

    // MARK: Clicks while another connection holds the history

    static func snap(_ tag: String, _ i: Int) -> AccessibilitySnapshot {
        AccessibilitySnapshot(focusID: "hold-focus-\(i)", app: AppInfo(name: "TextEdit", bundleIdentifier: "com.apple.TextEdit"),
                              window: WindowInfo(title: "hold-row \(tag) \(i)", url: nil),
                              element: ElementInfo(role: "AXTextArea"), secureInput: false, privateBrowsing: false,
                              selectedText: nil, selectedLocation: nil, selectedLength: nil)
    }
    static func feed(_ tag: String, _ n: Int, every: Double) async {
        for i in 0..<n {
            if let m = Rec.model, let c = m.coordinator, let cap = Rec.capture, !cap.isStopped, c.isRunning {
                c.record(kind: .mouseClick, snapshot: snap(tag, (Rec.fed[tag] ?? 0)), mouse: MouseInfo(button: "left", clickCount: 1))
                Rec.fed[tag, default: 0] += 1
            }
            if i < n - 1 { await tick(every) }
        }
    }
    static func allSaved(_ tag: String) async -> (fed: Int, saved: Int) {
        let fed = Rec.fed[tag] ?? 0
        var have = await saved(tag)
        let end = Date().addingTimeInterval(6)
        while have < fed && Date() < end { await tick(0.2); have = await saved(tag) }
        return (fed, have)
    }

    static func slowSaves(_ m: MemoryViewModel) async {
        MainHold.shared.begin()
        for _ in 0..<3 {
            let done = sql.hold(0.9)
            await feed("H3", 20, every: 0.05)
            _ = await waitFor(3) { done.get() }
            await tick(0.3)
        }
        await tick(0.5)
        let worst = await MainHold.shared.end()
        let (fed, have) = await allSaved("H3")
        check(worst < limit, "H3-slow-save-hold", "clicks during three 0.9 s holds hold the main thread under \(Int(limit)) ms: longest \(Int(worst)) ms")
        check(fed == 60 && have == fed && m.recording, "H3-slow-save", "every click is saved: fed \(fed), saved \(have), \(describe(m))")
    }

    static func lostClick(_ m: MemoryViewModel) async {
        let noticesBefore = notices.posted.count
        MainHold.shared.begin()
        let done = sql.hold(2.5)
        await feed("H4", 40, every: 0.06)
        _ = await waitFor(4) { done.get() }
        await tick(1.0)
        let worst = await MainHold.shared.end()
        let (fed, have) = await allSaved("H4")
        check(fed == 40 && have == fed, "H4-lost-click", "no click is lost under a 2.5 s hold: fed \(fed), saved \(have)")
        check(worst < limit, "H4-lost-click-hold", "and none holds the main thread over \(Int(limit)) ms: longest \(Int(worst)) ms")
        check(m.recording && m.coordinator?.session.state == "recording" && notices.posted.count == noticesBefore, "H4-still-recording",
              "recording stays on and nothing is said: \(describe(m))")
        // H5. In the order they were made.
        let s = sql
        let rows = await withCheckedContinuation { c in
            DispatchQueue.global().async { c.resume(returning: s.rows("SELECT body FROM records WHERE instr(body, 'hold-row H4 ') > 0 ORDER BY rowid")) }
        }
        let order: [Int] = rows.compactMap { row in
            guard let body = row.first ?? nil, let r = body.range(of: "hold-row H4 ") else { return nil }
            return Int(body[r.upperBound...].prefix { $0.isNumber })
        }
        let ats: [String] = rows.compactMap { row in (row.first ?? nil).flatMap { try? decode(Evidence.self, $0).at } }
        check(order == order.sorted() && Set(order).count == order.count && order.count == have && ats == ats.sorted(), "H5-order",
              "the clicks are saved in the order they were made (\(order.count) rows)")
    }

    static func pauseDuringHold(_ m: MemoryViewModel) async {
        let done = sql.hold(1.2)
        await feed("H6", 8, every: 0.05)
        m.pauseCapture()
        let fedBefore = Rec.fed["H6"] ?? 0
        await feed("H6", 4, every: 0.05) // not fed while paused (the recorder isn't running)
        _ = await waitFor(4) { done.get() }
        await tick(0.8)
        let have = await saved("H6")
        check(fedBefore == 8 && Rec.fed["H6"] == 8 && have == 8 && !m.recording, "H6-pause", "pausing during a hold keeps every click made before it: fed \(fedBefore), saved \(have), \(describe(m))")
        m.startCapture()
        _ = await waitFor(5) { m.recording && m.coordinator?.isRunning == true && Rec.capture?.isStopped == false }
        await tick(0.6)
        check(m.recording, "H6-start", "Start records again: \(describe(m))")
    }

    static func longHold(_ m: MemoryViewModel) async {
        let beats0 = Rec.beats
        let start = Date()
        MainHold.shared.begin()
        let done = sql.hold(8.0)
        var stateBefore3 = "", pausedAt: Double?
        while !done.get() {
            await feed("H7", 1, every: 0)
            await tick(0.1)
            let t = Date().timeIntervalSince(start)
            let state = m.coordinator?.session.state ?? "none"
            if t < 3.0 { stateBefore3 = state }
            if pausedAt == nil && state != "recording" { pausedAt = t }
        }
        let worst = await MainHold.shared.end()
        note("H7: longest main-thread hold \(Int(worst)) ms")
        note("H7: fed \(Rec.fed["H7"] ?? 0), heartbeats \(Rec.beats - beats0), captures \(Rec.captures)")
        check(stateBefore3 == "recording", "H7-long-hold", "recording is still on 3 s into an 8 s hold (\(stateBefore3))")
        check((pausedAt ?? 0) > 3.8 && (pausedAt ?? 99) < 7.5, "H7-long-hold-pause",
              "it pauses once the history has been held about 4.5 s (three heartbeats' busy timeouts): at \(pausedAt.map { String(format: "%.1f", $0) } ?? "never") s")
        let back = await waitFor(20) { m.recording && m.coordinator?.session.state == "recording" && Rec.capture?.isStopped == false }
        check(back, "H7-long-hold-back", "and starts again by itself once the history is free: \(describe(m))")
        await tick(0.6)
    }

    static func externalPolicy(_ m: MemoryViewModel) async {
        let h = home
        let wrote: Bool = await withCheckedContinuation { c in
            DispatchQueue.global().async {
                do {
                    let other = try MemoryStore(home: h, writable: true, automaticallySyncSearch: false)
                    var s = try other.policy()
                    s.blockedApps.append("com.apple.TextEdit")
                    try other.updatePolicy(s)
                    c.resume(returning: true)
                } catch { c.resume(returning: false) }
            }
        }
        await feed("H8", 3, every: 0.1)
        await tick(1.5)
        let have = await saved("H8")
        check(wrote && Rec.fed["H8"] == 3 && have == 0, "H8-policy", "an app excluded by another connection is not saved from the next click on: fed \(Rec.fed["H8"] ?? 0), saved \(have)")
    }
}
