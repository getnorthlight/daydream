// DD-RECIPE: APP
// Launch and save states that must never latch (gold r2, launch-state), on the REAL MemoryViewModel with the check seams
// (in-memory typing keys, no event tap, no login item, in-memory launch-intent defaults, fake lock and console reads and
// a fake notice center; run-checks.sh sets a synthetic HOME and CFFIXED_USER_HOME). Nothing records: a "recording"
// session is a row in a private store; no event tap, Keychain item, login item, notification or Apple Event is used.
// Setup counts as finished through the registration domain only (in memory; nothing is written to any preferences).
//   A. (timed-save) A saved app choice during a timed pause keeps the pause: Paused until the same time, and recording
//      starts by itself at its end. Also when the save meets a busy file, and when the pause ends while that save is
//      still being tried again (recording starts once it lands; nothing is said).
//   B. (save behind the lock) A save that stopped recording and lands while the screen is locked (the lock noticed or
//      not yet): the state is "Paused while your screen was locked.", not Off, and the unlock records. A save during
//      the lock's own pause leaves that pause, and a timed pause the lock interrupted is picked up at the unlock.
//   C. (ADV-8) Another connection holds the history for a few seconds as DayDream opens: the history opens by itself
//      once it is free, the launch intent is kept (recording starts), and meanwhile the state is the calm "trying
//      again" pause (or Off with nothing to resume), never "Storage needs attention". Start during the hold records
//      once it is free.
//      A lock and unlock, or a sleep and wake, during the hold (review round 1): nothing is said, the state stays the
//      calm pause (not Off), and recording starts once the history is free. The history opening while the screen is
//      locked (its notice come or not) or the Mac sleeps: the state is that pause, nothing is said, and the unlock or
//      wake runs the launch plan (recording, or the timed pause until the same time). A launch behind the lock screen
//      with no busy file reads the same pause, not Off.
//   D. (another copy) The recorder lock held by another copy that couldn't be brought forward: one short line that
//      tells nobody to quit anything, the window shows only that line (no "could not be loaded", no Try again that
//      does nothing), and the history opens by itself once the lock is free.
//   E. (launch order, review round 1) A launch that settles choices an older version saved (a site saved as
//      "www.Example.com" becomes "example.com", with a new revision): the model and its saver read the settled choices,
//      so the first saved choice lands (no "changed in another window"), setup's Start isn't held back, and recording
//      that was on starts again.
//   F. (gold/int round 2: r2-store-perf with r2-launch-state) Launch prepared the history off the main thread
//      (HistoryPreparation, as DaydreamLaunchSession does) and left one time index for the next launch. Nothing at this
//      launch builds it, before or beside the recorder: not the model's open, not its open again after a busy file
//      (ADV-8: launchWork .prepared and repairs false on every open), and not launch's look for a paused import
//      (MemoryFlowStore, which built it off the main thread while recording started, so the recorder's saves failed
//      busy for the whole build). Recording that was on starts. It needs HistoryPreparation, so it does not compile on
//      a6944d3; on 9ef3755 (the round 2 merges) both rows fail: MemoryFlowStore built the index.
//   G. (gold r3, gate item 4) The person pauses for 15 minutes and quits from the menu bar (its Quit, and the Quit
//      DayDream command, ⌘Q): the launch intent keeps the pause, and the next launch picks it up until the same time,
//      as after a logout. A pause that ended while DayDream was closed records at launch. On 3f70834 the menu's Quit
//      removed the intent (the next launch was Off, "Not recording"), and ⌘Q ended the pause first as well.
// Before this (a6944d3): A and B ended as Off, C latched "Storage needs attention. Nothing is recorded." until the next
// launch, and D said "Another copy of DayDream is open. Quit it, then open this one." until the next launch. E passes
// on a6944d3 and failed on 7e7aca4 (the first round of this branch read the choices before the settlement); the C lock
// and sleep rows failed on 7e7aca4 with "Recording didn't start again…" and Off, or recorded through a timed pause.
import AppKit
import CSQLite
import MemoryCore
import MemoryUI

@MainActor enum Report {
    static var passed = 0, failed = 0
    static func check(_ ok: Bool, _ id: String, _ message: @autoclosure () -> String) {
        if ok { passed += 1; print("PASS [\(id)] \(message())") } else { failed += 1; print("FAIL [\(id)] \(message())") }
        fflush(stdout)
    }
}
@MainActor func check(_ ok: Bool, _ id: String, _ message: @autoclosure () -> String) { Report.check(ok, id, message()) }
func stop(_ message: String) -> Never { fflush(stdout); FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
@MainActor func tick(_ seconds: Double = 0.05) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
@MainActor func waitFor(_ seconds: Double, _ condition: () -> Bool) async throws -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if condition() { return true }; try await tick(0.05) }
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
/// Lock and console reads, and the model's timers, held until the row runs them (`runPending`).
@MainActor final class FakeWake {
    var locked = false, onConsole = true
    var pending: [(TimeInterval, () -> Void)] = []
    var system: WakeSystem {
        WakeSystem(screenLocked: { self.locked }, onConsole: { self.onConsole },
                   after: { delay, work in self.pending.append((delay, work)) }, now: { Date() })
    }
    @discardableResult func runPending() -> Int {
        let jobs = pending; pending = []
        for (_, work) in jobs { work() }
        return jobs.count
    }
}
struct Opened { let model: MemoryViewModel; let notices: FakeNotices; let wake: FakeWake; let home: URL; let defaults: MemoryDefaults }

/// Another connection holding the history with an exclusive transaction for `seconds`, as another process would.
/// The main thread is never blocked waiting for it (`waitReleased`), so the model's timers and retries run meanwhile.
final class Hold: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var released: Bool { lock.lock(); defer { lock.unlock() }; return done }
    init(_ path: String, seconds: Double) {
        let held = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [self] in
            var db: OpaquePointer?
            sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil)
            sqlite3_exec(db, "BEGIN EXCLUSIVE", nil, nil, nil)
            held.signal()
            Thread.sleep(forTimeInterval: seconds)
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
            sqlite3_close(db)
            lock.lock(); done = true; lock.unlock()
        }
        held.wait()
    }
    @MainActor func waitReleased(_ seconds: Double) async throws { _ = try await waitFor(seconds) { released } }
}

@main @MainActor struct LaunchStateChecks {
    static var out = URL(fileURLWithPath: "/")
    static let lockLine = "Paused while your screen was locked."
    static let la = TimeZone(identifier: "America/Los_Angeles")!

    static func main() async throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
            FileHandle.standardError.write(Data("FAIL: launch-state-checks watchdog expired after 300s\n".utf8)); exit(2)
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
        out = URL(fileURLWithPath: outPath, isDirectory: true).appendingPathComponent("launch-state", isDirectory: true)
        try makePrivateDirectory(out)
        MemoryViewModel.permissionsGranted = { true }
        MemoryViewModel.permissionRead = { PermissionSnapshot(accessibility: true, inputMonitoring: true) }
        MemoryViewModel.startInput = { _ in true }
        MemoryViewModel.readLaunchLocation = { .applications }
        MemoryViewModel.canReopen = { true }
        // Setup finished, in the registration domain only (in memory; nothing is written).
        UserDefaults.standard.register(defaults: [MemoryViewModel.setupCompletedKey: true])

        // A. A saved choice during a timed pause
        try await timedPauseAtLaunchThenSave()
        try await personTimedPauseThenSave()
        try await busySaveDuringTimedPause()
        try await timedPauseEndsWhileSaveRetries()
        // B. A save and the screen lock
        try await saveLandsBehindNoticedLock()
        try await saveLandsBehindUnnoticedLock()
        try await saveDuringLockPause()
        try await saveDuringLockOverTimedPause()
        // C. A busy history at launch (ADV-8)
        try await busyAtLaunchWithIntent()
        try await busyAtLaunchNothingToResume()
        try await startWhileBusyAtLaunch()
        try await busyAtLaunchTimedPause()
        try await busyLockUnlockDuringHold()
        try await busySleepWakeDuringHold()
        try await busyOpensBehindLock(timed: false)
        try await busyOpensBehindLock(timed: true)
        try await busyOpensAsleep(timed: false)
        try await busyOpensAsleep(timed: true)
        try await busyOpensBehindUnnoticedLock()
        try await launchBehindLock()
        // D. Another copy holds the history
        try await anotherCopyHoldsTheLock()
        // E. Launch settles older choices before reading them
        try await legacySitesSettledAtLaunch()
        try await legacySitesWithRecordingIntent()
        // F. A prepared launch meets a busy history (gold/int round 2)
        try await preparedLaunchBusyAtOpen()
        try await preparedLaunchQuiet()
        // G. Quit during a timed pause (gold r3)
        try await quitDuringTimedPause()
        try await quitCommandKeepsTimedPause()

        print("launch-state: \(Report.passed) passed, \(Report.failed) failed")
        fflush(stdout)
        exit(Report.failed == 0 ? 0 : 1)
    }

    static func intent(_ d: MemoryDefaults) -> [String: Any]? { d.dictionary(forKey: LaunchResume.key) }
    static func defaults(_ value: [String: Any]?) -> MemoryDefaults {
        let d = MemoryDefaults()
        if let value { d.set(value, forKey: LaunchResume.key) }
        return d
    }
    static func home(_ name: String) throws -> URL {
        let memory = out.appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        try makePrivateDirectory(memory)
        return memory
    }
    /// A history made once and closed, so a later launch opens an existing file.
    static func existingHistory(_ name: String) async throws -> URL {
        let memory = try home(name)
        setenv("MAC_MEM_HOME", memory.path, 1)
        var first: MemoryViewModel? = MemoryViewModel()
        _ = try await waitFor(3) { first?.history.busy == false }
        check(first?.historyStoreID != nil, "harness", "\(name): the history was made")
        first = nil
        try await tick(0.3)
        return memory
    }
    /// A model launched on `home` (a new one by default) with the launch intent `intent`. `settle`: its launch work ran.
    static func open(_ name: String, home existing: URL? = nil, intent: [String: Any]? = nil, settle: Bool = true, locked: Bool = false) async throws -> Opened {
        let memory = try existing ?? home(name)
        setenv("MAC_MEM_HOME", memory.path, 1)
        let d = defaults(intent)
        MemoryViewModel.launchIntentDefaults = d
        let model = MemoryViewModel()
        MemoryViewModel.launchIntentDefaults = nil
        let notices = FakeNotices(), wake = FakeWake()
        wake.locked = locked // read from launch's next turn on (`resumeAtLaunch`)
        model.noticeCenter = notices.center
        model.wakeSystem = wake.system
        if settle {
            _ = try await waitFor(3) { !model.history.busy }
            try await tick(0.1)
        }
        return Opened(model: model, notices: notices, wake: wake, home: memory, defaults: d)
    }
    static func describe(_ o: Opened) -> String {
        "\(o.model.recordingState), wanted \(o.model.recordingWanted), session \(o.model.coordinator?.session.state ?? "none")/\(o.model.coordinator?.session.reason ?? ""), notices \(o.notices.posted.map(\.body)), blocker \(String(describing: o.model.resumeUnavailable))"
    }
    static func header(_ o: Opened) -> MenuBarMenu.Header {
        MenuBarMenu.header(o.model.presentation, now: Date(), timeZone: la, canSetUp: true, canOpenApplications: false)
    }
    static func pausedUntil(_ o: Opened) -> Date? {
        if case .paused(let until, _, _) = o.model.recordingState { return until }
        return nil
    }
    static func pausedReason(_ o: Opened) -> String? {
        if case .paused(_, _, let reason) = o.model.recordingState { return reason }
        return nil
    }
    static func saveChoice(_ o: Opened, _ bundle: String = "com.example.editor") {
        o.model.exclusionPreference.wrappedValue = bundle
        o.model.saveWaitingChoices()
    }
    /// Unlock and let the wake rules run their settle (and any read again).
    static func unlock(_ o: Opened) async throws {
        o.wake.locked = false
        o.model.unsuspend(.screenLock)
        var n = 0
        while !o.model.recording && !o.wake.pending.isEmpty && n < 8 { try await tick(0.1); o.wake.runPending(); n += 1 }
        try await tick(0.1)
    }

    // MARK: A. A saved choice during a timed pause

    static func timedPauseAtLaunchThenSave() async throws {
        let end = Date().addingTimeInterval(3)
        let o = try await open("timed-launch", intent: ["until": end.timeIntervalSince1970])
        let until = o.model.pauseUntil
        check(until != nil, "harness", "the timed pause was picked up at launch: \(describe(o))")
        saveChoice(o)
        _ = try await waitFor(2) { !o.model.preferencesUnresolved }
        check(o.model.blockedApps.contains("com.example.editor") && !o.model.preferencesUnresolved, "harness", "the choice saved: \(o.model.blockedApps)")
        check(o.model.pauseUntil == until && pausedUntil(o) == until && o.model.coordinator?.session.state == "paused", "timed-save",
              "a choice saved during a timed pause keeps it: Paused until the same time: \(describe(o))")
        check(o.notices.posted.isEmpty && o.model.presentation.issue == nil, "timed-save", "…nothing is said and no line shows: \(describe(o))")
        check((intent(o.defaults)?["until"] as? Double).map { abs($0 - end.timeIntervalSince1970) < 1 } == true, "timed-save",
              "…and the launch intent is still the timed pause: \(String(describing: intent(o.defaults)))")
        _ = try await waitFor(5) { o.model.recording }
        check(o.model.recording && o.notices.posted.isEmpty, "timed-save", "…and at its end recording starts by itself: \(describe(o))")
        o.model.stopCapture()
    }

    static func personTimedPauseThenSave() async throws {
        let o = try await open("timed-person")
        o.model.startCapture()
        guard o.model.recording else { check(false, "harness", "timed-person did not record"); return }
        o.model.pauseFor(minutes: 5)
        let until = o.model.pauseUntil
        check(until != nil, "harness", "Pause for 5 minutes: \(describe(o))")
        saveChoice(o, "com.example.mail")
        _ = try await waitFor(2) { !o.model.preferencesUnresolved }
        try await tick(0.1)
        check(o.model.blockedApps.contains("com.example.mail") && o.model.pauseUntil == until && pausedUntil(o) == until
              && o.model.coordinator?.session.state == "paused" && !o.model.recording, "timed-save",
              "the person's Pause for 5 minutes, then a saved choice: still Paused until the same time: \(describe(o))")
        check(o.notices.posted.isEmpty && header(o).status.tone == .paused, "timed-save", "…the menu still says it resumes then: \(header(o).status.text)")
        o.model.stopCapture()
    }

    static func busySaveDuringTimedPause() async throws {
        let memory = try await existingHistory("timed-busy")
        let end = Date().addingTimeInterval(7)
        let o = try await open("timed-busy", home: memory, intent: ["until": end.timeIntervalSince1970])
        let until = o.model.pauseUntil
        check(until != nil, "harness", "timed-busy: the timed pause was picked up: \(describe(o))")
        let hold = Hold(memory.appendingPathComponent("memory.sqlite").path, seconds: 2.5)
        saveChoice(o, "com.example.notes")
        try await hold.waitReleased(5)
        _ = try await waitFor(8) { !o.model.preferencesUnresolved && o.model.blockedApps.contains("com.example.notes") }
        try await tick(0.2)
        check(o.model.blockedApps.contains("com.example.notes") && o.model.pauseUntil == until && pausedUntil(o) == until, "timed-save",
              "a choice saved during a timed pause while the file was busy lands, and the pause stands: \(describe(o))")
        check(o.notices.posted.isEmpty && o.model.presentation.issue == nil, "timed-save", "…nothing is said: \(describe(o))")
        _ = try await waitFor(8) { o.model.recording }
        check(o.model.recording && o.notices.posted.isEmpty, "timed-save", "…and recording starts at the pause's end: \(describe(o))")
        o.model.stopCapture()
    }

    static func timedPauseEndsWhileSaveRetries() async throws {
        let memory = try await existingHistory("timed-ends")
        let end = Date().addingTimeInterval(2.5)
        let o = try await open("timed-ends", home: memory, intent: ["until": end.timeIntervalSince1970])
        check(o.model.pauseUntil != nil, "harness", "timed-ends: the timed pause was picked up: \(describe(o))")
        let hold = Hold(memory.appendingPathComponent("memory.sqlite").path, seconds: 4.5)
        saveChoice(o, "com.example.calendar")
        try await hold.waitReleased(8)
        _ = try await waitFor(10) { o.model.recording }
        check(o.model.recording && o.model.blockedApps.contains("com.example.calendar"), "timed-save",
              "a timed pause ending while its saved choice is still being tried again: recording starts once it lands: \(describe(o))")
        check(o.notices.posted.isEmpty, "timed-save", "…and nothing said it didn't resume: \(o.notices.posted.map(\.body))")
        o.model.stopCapture()
    }

    // MARK: B. A save and the screen lock

    static func saveLandsBehindNoticedLock() async throws {
        let o = try await open("lock-noticed")
        o.model.startCapture()
        guard o.model.recording else { check(false, "harness", "lock-noticed did not record"); return }
        o.model.exclusionPreference.wrappedValue = "com.example.editor" // stops recording now; saves after a short delay
        o.wake.locked = true
        o.model.suspend(.screenLock)
        _ = try await waitFor(2) { !o.model.preferencesUnresolved }
        try await tick(0.1)
        check(o.model.blockedApps.contains("com.example.editor"), "harness", "lock-noticed: the choice saved")
        check(!o.model.recording && pausedReason(o) == lockLine && o.model.presentation.issue == nil && o.notices.posted.isEmpty, "save-lock",
              "a save that stopped recording lands behind the lock: \"\(lockLine)\", not Off: \(describe(o))")
        try await unlock(o)
        check(o.model.recording && o.notices.posted.isEmpty, "save-lock", "…and the unlock records: \(describe(o))")
        o.model.stopCapture()
    }

    static func saveLandsBehindUnnoticedLock() async throws {
        let o = try await open("lock-unnoticed")
        o.model.startCapture()
        guard o.model.recording else { check(false, "harness", "lock-unnoticed did not record"); return }
        o.model.exclusionPreference.wrappedValue = "com.example.editor"
        o.wake.locked = true // the lock notice hasn't come yet
        _ = try await waitFor(2) { !o.model.preferencesUnresolved }
        try await tick(0.1)
        check(!o.model.recording && pausedReason(o) == lockLine && o.notices.posted.isEmpty, "save-lock",
              "a save that lands while the screen is locked before its notice: \"\(lockLine)\", not Off: \(describe(o))")
        try await unlock(o)
        check(o.model.recording && o.notices.posted.isEmpty, "save-lock", "…and the unlock records: \(describe(o))")
        o.model.stopCapture()
    }

    static func saveDuringLockPause() async throws {
        let o = try await open("lock-pause")
        o.model.startCapture()
        guard o.model.recording else { check(false, "harness", "lock-pause did not record"); return }
        o.wake.locked = true
        o.model.suspend(.screenLock)
        check(pausedReason(o) == lockLine, "harness", "the lock paused recording: \(describe(o))")
        saveChoice(o)
        _ = try await waitFor(2) { !o.model.preferencesUnresolved }
        try await tick(0.1)
        check(o.model.blockedApps.contains("com.example.editor") && pausedReason(o) == lockLine && o.notices.posted.isEmpty, "save-lock",
              "a choice saved during the lock's pause leaves that pause (not Off): \(describe(o))")
        try await unlock(o)
        check(o.model.recording && o.notices.posted.isEmpty, "save-lock", "…and the unlock records: \(describe(o))")
        o.model.stopCapture()
    }

    static func saveDuringLockOverTimedPause() async throws {
        let end = Date().addingTimeInterval(120)
        let o = try await open("lock-timed", intent: ["until": end.timeIntervalSince1970])
        let until = o.model.pauseUntil
        check(until != nil, "harness", "lock-timed: the timed pause was picked up: \(describe(o))")
        o.wake.locked = true
        o.model.suspend(.screenLock)
        saveChoice(o)
        _ = try await waitFor(2) { !o.model.preferencesUnresolved }
        try await tick(0.1)
        check(o.model.blockedApps.contains("com.example.editor") && !o.model.recording && o.model.recordingState.kind == .paused, "save-lock",
              "a choice saved while a lock interrupted a timed pause: still paused: \(describe(o))")
        try await unlock(o)
        check(o.model.pauseUntil == until && pausedUntil(o) == until && o.notices.posted.isEmpty, "save-lock",
              "…and the unlock picks the timed pause up until the same time: \(describe(o)), until \(String(describing: o.model.pauseUntil))")
        o.model.stopCapture()
    }

    // MARK: C. A busy history at launch (ADV-8)

    /// No latched storage line, no orange line, and nothing that says storage.
    static func calm(_ o: Opened) -> Bool {
        let h = header(o)
        return o.model.resumeUnavailable == nil && o.model.presentation.issue == nil && h.status.tone != .attention
            && !h.status.text.localizedCaseInsensitiveContains("storage")
    }

    /// `calm` behind a suspension: the model keeps its internal "Resume after waking" blocker (Start waits), which no
    /// surface shows; nothing else stands, and no line is orange or says storage.
    static func calmSuspended(_ o: Opened) -> Bool {
        let h = header(o)
        return [nil, "Resume after waking"].contains(o.model.resumeUnavailable) && o.model.presentation.issue == nil && h.status.tone != .attention
            && !h.status.text.localizedCaseInsensitiveContains("storage")
    }

    static func busyAtLaunchWithIntent() async throws {
        let memory = try await existingHistory("busy-intent")
        let hold = Hold(memory.appendingPathComponent("memory.sqlite").path, seconds: 3)
        let o = try await open("busy-intent", home: memory, intent: ["recording": true], settle: false)
        check(!o.model.recording && calm(o) && pausedReason(o) == RecordingCopy.savingRetry, "ADV-8",
              "a history held as DayDream opens (recording was on): the calm \"\(RecordingCopy.savingRetry)\" pause, not storage attention: \(describe(o)), menu \(header(o).status.text)")
        check(o.notices.posted.isEmpty && (intent(o.defaults)?["recording"] as? Bool) == true, "ADV-8",
              "…nothing is said, and the launch intent is kept: \(String(describing: intent(o.defaults)))")
        try await hold.waitReleased(5)
        _ = try await waitFor(10) { o.model.recording }
        check(o.model.recording && o.model.historyStoreID != nil && o.notices.posted.isEmpty, "ADV-8",
              "…and once the file is free the history opens by itself and recording starts: \(describe(o))")
        check(o.model.recordingState.kind == .recording && o.model.presentation.issue == nil && calm(o), "ADV-8", "…with no line left behind: \(describe(o))")
        o.model.stopCapture()
        check(intent(o.defaults) == nil, "ADV-8", "…and the person's Stop is saved as the intent afterwards: \(String(describing: intent(o.defaults)))")
    }

    static func busyAtLaunchNothingToResume() async throws {
        let memory = try await existingHistory("busy-none")
        let hold = Hold(memory.appendingPathComponent("memory.sqlite").path, seconds: 3)
        let o = try await open("busy-none", home: memory, settle: false)
        check(!o.model.recording && calm(o) && o.model.recordingState == .off(since: nil, reason: nil), "ADV-8",
              "a history held as DayDream opens with nothing to resume: Off, nothing about storage: \(describe(o)), menu \(header(o).status.text)")
        try await hold.waitReleased(5)
        _ = try await waitFor(10) { o.model.historyStoreID != nil && o.model.preferencesAvailable }
        try await tick(0.2)
        check(o.model.historyStoreID != nil && o.model.preferencesAvailable && calm(o) && !o.model.recording, "ADV-8",
              "…the history opens by itself once free, and nothing starts: \(describe(o))")
        o.model.requestStart(openSetup: {})
        check(o.model.recording && o.model.setupRequest == nil && o.notices.posted.isEmpty, "ADV-8", "…and Start records: \(describe(o))")
        o.model.stopCapture()
    }

    static func startWhileBusyAtLaunch() async throws {
        let memory = try await existingHistory("busy-start")
        let hold = Hold(memory.appendingPathComponent("memory.sqlite").path, seconds: 4)
        let o = try await open("busy-start", home: memory, settle: false)
        o.model.requestStart(openSetup: {})
        check(!o.model.recording && calm(o) && o.model.setupRequest == nil, "ADV-8",
              "Start while the history is still held: nothing about storage, no setup: \(describe(o))")
        try await hold.waitReleased(6)
        _ = try await waitFor(10) { o.model.recording }
        check(o.model.recording && o.notices.posted.isEmpty && o.model.setupRequest == nil, "ADV-8",
              "…and once the file is free the person's Start records: \(describe(o))")
        check((intent(o.defaults)?["recording"] as? Bool) == true, "ADV-8", "…and is the launch intent: \(String(describing: intent(o.defaults)))")
        o.model.stopCapture()
    }

    static func busyAtLaunchTimedPause() async throws {
        let memory = try await existingHistory("busy-timed")
        let end = Date().addingTimeInterval(60)
        let hold = Hold(memory.appendingPathComponent("memory.sqlite").path, seconds: 3)
        let o = try await open("busy-timed", home: memory, intent: ["until": end.timeIntervalSince1970], settle: false)
        check(!o.model.recording && calm(o), "ADV-8", "a timed pause saved and a history held at launch: nothing about storage: \(describe(o))")
        try await hold.waitReleased(5)
        _ = try await waitFor(10) { o.model.pauseUntil != nil }
        try await tick(0.1)
        let until = o.model.pauseUntil
        check(until.map { abs($0.timeIntervalSince(end)) < 1 } == true && pausedUntil(o) == until && o.notices.posted.isEmpty, "ADV-8",
              "…once free, the timed pause is picked up until the same time: \(describe(o))")
        o.model.stopCapture()
    }

    /// The screen locks and unlocks while the history is still held at launch (recording was on).
    static func busyLockUnlockDuringHold() async throws {
        let memory = try await existingHistory("busy-lock")
        let hold = Hold(memory.appendingPathComponent("memory.sqlite").path, seconds: 6)
        let o = try await open("busy-lock", home: memory, intent: ["recording": true], settle: false)
        try await tick(0.5)
        o.wake.locked = true
        o.model.suspend(.screenLock)
        try await tick(0.5)
        try await unlock(o)
        check(!hold.released, "harness", "busy-lock: the history is still held after the unlock")
        check(o.notices.posted.isEmpty && !o.model.recording && o.model.recordingWanted && pausedReason(o) == RecordingCopy.savingRetry && calm(o), "ADV-8-lock",
              "a lock and unlock while the history is still held: nothing is said, and the state is still the calm \"\(RecordingCopy.savingRetry)\" pause (not Off): \(describe(o)), menu \(header(o).status.text)")
        try await hold.waitReleased(8)
        _ = try await waitFor(20) { o.model.recording }
        check(o.model.recording && o.notices.posted.isEmpty && calm(o), "ADV-8-lock", "…and once the history is free recording starts, and nothing was said: \(describe(o))")
        o.model.stopCapture()
    }

    /// The Mac sleeps and wakes while the history is still held at launch (recording was on).
    static func busySleepWakeDuringHold() async throws {
        let memory = try await existingHistory("busy-sleep")
        let hold = Hold(memory.appendingPathComponent("memory.sqlite").path, seconds: 6)
        let o = try await open("busy-sleep", home: memory, intent: ["recording": true], settle: false)
        try await tick(0.5)
        o.model.suspend(.sleep)
        try await tick(0.5)
        o.model.unsuspend(.sleep)
        var n = 0
        while !o.wake.pending.isEmpty && n < 8 { try await tick(0.1); o.wake.runPending(); n += 1 }
        try await tick(0.1)
        check(!hold.released, "harness", "busy-sleep: the history is still held after the wake")
        check(o.notices.posted.isEmpty && !o.model.recording && o.model.recordingWanted && pausedReason(o) == RecordingCopy.savingRetry && calm(o), "ADV-8-sleep",
              "a sleep and wake while the history is still held: nothing is said, and the state is still the calm \"\(RecordingCopy.savingRetry)\" pause (not Off): \(describe(o)), menu \(header(o).status.text)")
        try await hold.waitReleased(8)
        _ = try await waitFor(20) { o.model.recording }
        check(o.model.recording && o.notices.posted.isEmpty && calm(o), "ADV-8-sleep", "…and once the history is free recording starts, and nothing was said: \(describe(o))")
        o.model.stopCapture()
    }

    /// The screen locks during the hold and the history opens behind it (recording was on, or a timed pause was saved).
    static func busyOpensBehindLock(timed: Bool) async throws {
        let id = timed ? "ADV-8-lock-timed" : "ADV-8-lock-open"
        let memory = try await existingHistory(id)
        let end = Date().addingTimeInterval(90)
        let hold = Hold(memory.appendingPathComponent("memory.sqlite").path, seconds: 2.5)
        let o = try await open(id, home: memory, intent: timed ? ["until": end.timeIntervalSince1970] : ["recording": true], settle: false)
        try await tick(0.3)
        o.wake.locked = true
        o.model.suspend(.screenLock)
        try await hold.waitReleased(5)
        _ = try await waitFor(12) { o.model.historyStoreID != nil }
        try await tick(0.3)
        check(o.model.historyStoreID != nil && !o.model.recording && pausedReason(o) == lockLine && o.notices.posted.isEmpty && calmSuspended(o), id,
              "the history opens behind a lock taken while it was held: \"\(lockLine)\", nothing records, nothing is said: \(describe(o)), menu \(header(o).status.text)")
        try await unlock(o)
        if timed {
            check(!o.model.recording && o.model.pauseUntil.map { abs($0.timeIntervalSince(end)) < 1 } == true && pausedUntil(o) == o.model.pauseUntil && o.notices.posted.isEmpty, id,
                  "…and the unlock picks the timed pause up until the same time (nothing records before it ends): \(describe(o)), until \(String(describing: o.model.pauseUntil))")
            check((intent(o.defaults)?["until"] as? Double).map { abs($0 - end.timeIntervalSince1970) < 1 } == true, id,
                  "…and the launch intent is still the timed pause: \(String(describing: intent(o.defaults)))")
        } else {
            check(o.model.recording && o.notices.posted.isEmpty, id, "…and the unlock records: \(describe(o))")
        }
        o.model.stopCapture()
    }

    /// The screen locks during the hold before its notice comes, and the history opens behind it (recording was on).
    static func busyOpensBehindUnnoticedLock() async throws {
        let memory = try await existingHistory("busy-unnoticed")
        let hold = Hold(memory.appendingPathComponent("memory.sqlite").path, seconds: 2.5)
        let o = try await open("busy-unnoticed", home: memory, intent: ["recording": true], settle: false)
        o.wake.locked = true // the lock notice hasn't come yet
        try await hold.waitReleased(5)
        _ = try await waitFor(12) { o.model.historyStoreID != nil }
        try await tick(0.4)
        check(o.model.historyStoreID != nil && !o.model.recording && pausedReason(o) == lockLine && o.notices.posted.isEmpty && calmSuspended(o), "ADV-8-lock-unnoticed",
              "the history opens behind a lock whose notice hasn't come: \"\(lockLine)\", not Off, nothing records, nothing is said: \(describe(o)), menu \(header(o).status.text)")
        try await unlock(o)
        check(o.model.recording && o.notices.posted.isEmpty, "ADV-8-lock-unnoticed", "…and the unlock records: \(describe(o))")
        o.model.stopCapture()
    }

    /// DayDream opens behind the lock screen (at login, or an update's relaunch) with recording on, no busy file.
    static func launchBehindLock() async throws {
        let o = try await open("launch-locked", intent: ["recording": true], locked: true)
        try await tick(0.3)
        check(!o.model.recording && pausedReason(o) == lockLine && o.model.recordingWanted && o.notices.posted.isEmpty && calmSuspended(o), "launch-locked",
              "a launch behind the lock screen with recording on: \"\(lockLine)\" (not Off, then recording by itself): \(describe(o)), menu \(header(o).status.text)")
        try await unlock(o)
        check(o.model.recording && o.notices.posted.isEmpty, "launch-locked", "…and the unlock records: \(describe(o))")
        o.model.stopCapture()
    }

    /// The Mac sleeps during the hold and the history opens while it sleeps (recording was on, or a timed pause was saved).
    static func busyOpensAsleep(timed: Bool) async throws {
        let id = timed ? "ADV-8-sleep-timed" : "ADV-8-sleep-open"
        let memory = try await existingHistory(id)
        let end = Date().addingTimeInterval(90)
        let hold = Hold(memory.appendingPathComponent("memory.sqlite").path, seconds: 2.5)
        let o = try await open(id, home: memory, intent: timed ? ["until": end.timeIntervalSince1970] : ["recording": true], settle: false)
        try await tick(0.3)
        o.model.suspend(.sleep)
        try await hold.waitReleased(5)
        _ = try await waitFor(12) { o.model.historyStoreID != nil }
        try await tick(0.3)
        check(o.model.historyStoreID != nil && !o.model.recording && o.model.recordingState.kind == .paused && o.notices.posted.isEmpty && calmSuspended(o), id,
              "the history opens while the Mac sleeps: paused, nothing records, and nothing says it didn't start: \(describe(o)), menu \(header(o).status.text)")
        o.model.unsuspend(.sleep)
        var n = 0
        while !o.model.recording && !o.wake.pending.isEmpty && n < 8 { try await tick(0.1); o.wake.runPending(); n += 1 }
        try await tick(0.1)
        if timed {
            check(!o.model.recording && o.model.pauseUntil.map { abs($0.timeIntervalSince(end)) < 1 } == true && pausedUntil(o) == o.model.pauseUntil && o.notices.posted.isEmpty, id,
                  "…and the wake picks the timed pause up until the same time (nothing records before it ends): \(describe(o)), until \(String(describing: o.model.pauseUntil))")
        } else {
            check(o.model.recording && o.notices.posted.isEmpty, id, "…and the wake records: \(describe(o))")
        }
        o.model.stopCapture()
    }

    // MARK: D. Another copy holds the history

    static func anotherCopyHoldsTheLock() async throws {
        let memory = try home("copy")
        let fd = Darwin.open(memory.appendingPathComponent("capture.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { check(false, "harness", "copy: the lock could not be taken"); return }
        let o = try await open("copy", home: memory, settle: false)
        try await tick(0.3)
        var line = ""
        if case .off(_, let reason) = o.model.recordingState { line = reason ?? "" }
        let h = header(o)
        // The window's phase, whatever its case: `.failed` is drawn as "Activity could not be loaded", the line and Try again
        // (ActivityTimelineView), and Try again (`refresh`) does nothing while another copy holds the history.
        let phase = String(describing: o.model.activity.phase)
        var failed = false
        if case .failed = o.model.activity.phase { failed = true }
        let label = DaydreamMenuBarLabelImage(state: o.model.recordingState, now: Date(), timeZone: la, setup: h.needsSetup ? h.status.text : nil).label
        check(o.model.anotherCopyOpen && o.model.historyStoreID == nil && !line.isEmpty, "copy", "another copy holds the lock: this one opened nothing: \(describe(o))")
        check(!failed && phase.contains(line), "copy-window",
              "the window shows only the one line: not \"Activity could not be loaded\" with a Try again that does nothing: \(phase)")
        for (surface, text) in [("state", line), ("menu", h.status.text + " " + (h.status.detail ?? "")), ("window", phase), ("menu bar label", label)] {
            check(!text.localizedCaseInsensitiveContains("quit") && !text.localizedCaseInsensitiveContains("then open"), "copy",
                  "the \(surface) line tells nobody to quit anything: \"\(text)\"")
        }
        check(line.split(separator: " ").count <= 6 && h.status.detail == nil, "copy", "…one short line: \"\(line)\", detail \(String(describing: h.status.detail))")
        close(fd)
        _ = try await waitFor(6) { o.model.historyStoreID != nil }
        try await tick(0.2)
        check(!o.model.anotherCopyOpen && o.model.historyStoreID != nil && o.model.recordingState == .off(since: nil, reason: nil) && calm(o), "copy",
              "once the other copy lets go, the history opens by itself and the line clears: \(describe(o))")
        var ready = false
        if case .ready = o.model.activity.phase { ready = true }
        check(ready, "copy-window", "…and the window shows the day once the history opens: \(o.model.activity.phase)")
        o.model.requestStart(openSetup: {})
        check(o.model.recording, "copy", "…and Start records: \(describe(o))")
        o.model.stopCapture()
    }

    // MARK: E. Launch settles older choices before reading them

    /// A history whose site entry an older version saved as "www.Example.com" (no other change, so no notice is written).
    static func legacySitesHistory(_ name: String) throws -> (URL, String) {
        let memory = try home(name)
        let store = try MemoryStore(home: memory, writable: true, automaticallySyncSearch: false)
        var policy = try store.policy()
        policy.blockedDomains = ["www.Example.com"]
        try store.updatePolicy(policy)
        return (memory, try store.policy().revision)
    }

    static func legacySitesSettledAtLaunch() async throws {
        let (memory, before) = try legacySitesHistory("legacy-sites")
        let o = try await open("legacy-sites", home: memory)
        let saved = try MemoryStore(home: memory, automaticallySyncSearch: false).policy()
        check(saved.blockedDomains == ["example.com"] && saved.revision != before, "harness", "launch settled the older site form: \(saved.blockedDomains)")
        check(o.model.blockedDomains == "example.com" && o.model.onboardingPreferencesCurrent && o.model.preferenceProblem == nil && o.model.preferenceNotice == nil, "launch-order",
              "after launch settles an older site form, the model reads the settled choices: sites \(o.model.blockedDomains), current \(o.model.onboardingPreferencesCurrent), problem \(String(describing: o.model.preferenceProblem?.text))")
        check(o.model.setupStepForStart() == nil, "launch-order", "…so setup's Start isn't held back: \(String(describing: o.model.setupStepForStart()))")
        saveChoice(o, "com.example.mail")
        _ = try await waitFor(3) { !o.model.preferencesUnresolved || o.model.preferenceProblem != nil }
        try await tick(0.2)
        let after = try MemoryStore(home: memory, automaticallySyncSearch: false).policy()
        check(after.blockedApps.contains("com.example.mail") && after.blockedDomains == ["example.com"] && o.model.preferenceProblem == nil && !o.model.preferencesUnresolved, "launch-order",
              "…and the first app choice saved after that launch lands (not \"changed in another window\"): saved \(after.blockedApps), problem \(String(describing: o.model.preferenceProblem?.text)), status \(o.model.privacySaveStatus)")
        o.model.requestStart(openSetup: {})
        check(o.model.recording && o.model.setupRequest == nil && o.notices.posted.isEmpty, "launch-order", "…and Start records: \(describe(o))")
        o.model.stopCapture()
    }

    static func legacySitesWithRecordingIntent() async throws {
        let (memory, _) = try legacySitesHistory("legacy-intent")
        let o = try await open("legacy-intent", home: memory, intent: ["recording": true])
        _ = try await waitFor(3) { o.model.recording }
        check(o.model.recording && o.notices.posted.isEmpty && o.model.blockedDomains == "example.com", "launch-order",
              "recording that was on starts again at a launch that settles an older site form, and nothing is said: \(describe(o)), sites \(o.model.blockedDomains)")
        o.model.stopCapture()
    }

    // MARK: F. A prepared launch meets a busy history (gold/int round 2)

    static func indexExists(_ memory: URL, _ name: String) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(memory.appendingPathComponent("memory.sqlite").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return false }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master WHERE type='index' AND name='\(name)'", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 1
    }

    static func preparedLaunchBusyAtOpen() async throws {
        let memory = try await existingHistory("prepared-busy")
        // What DaydreamLaunchSession does before the model: the preparation, off the main thread, under the recorder lock.
        let outcome: HistoryPreparation.Outcome = await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                done.resume(returning: HistoryPreparation.prepare(home: memory) {
                    try MemoryStore(home: $0, writable: true, automaticallySyncSearch: false, launchWork: .preparation)
                })
            }
        }
        check(outcome.prepared && outcome.complete && indexExists(memory, "records_at"), "harness", "prepared-busy: launch prepared the history: \(outcome)")
        // One time index left for the next launch's preparation (as when a long AI read outlasts its patience): only the
        // model's open could build it now, on the main thread.
        var db: OpaquePointer?
        sqlite3_open_v2(memory.appendingPathComponent("memory.sqlite").path, &db, SQLITE_OPEN_READWRITE, nil)
        sqlite3_exec(db, "DROP INDEX records_at", nil, nil, nil)
        sqlite3_close(db)
        check(!indexExists(memory, "records_at"), "harness", "prepared-busy: the index is gone")
        let hold = Hold(memory.appendingPathComponent("memory.sqlite").path, seconds: 3)
        setenv("MAC_MEM_HOME", memory.path, 1)
        let d = defaults(["recording": true])
        MemoryViewModel.launchIntentDefaults = d
        let model = MemoryViewModel(prepared: outcome)
        MemoryViewModel.launchIntentDefaults = nil
        let notices = FakeNotices(), wake = FakeWake()
        model.noticeCenter = notices.center
        model.wakeSystem = wake.system
        let o = Opened(model: model, notices: notices, wake: wake, home: memory, defaults: d)
        check(!model.recording && model.historyStoreID == nil && calm(o) && pausedReason(o) == RecordingCopy.savingRetry, "prepared-busy",
              "launch prepared the history and the model's open met a busy file: the calm \"\(RecordingCopy.savingRetry)\" pause: \(describe(o))")
        try await hold.waitReleased(5)
        _ = try await waitFor(10) { model.recording }
        check(model.recording && model.historyStoreID != nil && notices.posted.isEmpty && calm(o), "prepared-busy",
              "…once the file is free the history opens by itself and recording starts, with nothing said: \(describe(o))")
        check(!indexExists(memory, "records_at"), "prepared-busy",
              "…and nothing at this launch built the time index launch left for the next launch's preparation: not the open again after the busy file, not the look for a paused import beside the recorder (was: built by MemoryFlowStore)")
        model.stopCapture()
    }

    /// A launch that prepared the history (one time index left for the next launch) and meets no busy file.
    static func preparedLaunchQuiet() async throws {
        let memory = try await existingHistory("prepared-quiet")
        let outcome: HistoryPreparation.Outcome = await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                done.resume(returning: HistoryPreparation.prepare(home: memory) {
                    try MemoryStore(home: $0, writable: true, automaticallySyncSearch: false, launchWork: .preparation)
                })
            }
        }
        var db: OpaquePointer?
        sqlite3_open_v2(memory.appendingPathComponent("memory.sqlite").path, &db, SQLITE_OPEN_READWRITE, nil)
        sqlite3_exec(db, "DROP INDEX records_at", nil, nil, nil)
        sqlite3_close(db)
        check(outcome.prepared && !indexExists(memory, "records_at"), "harness", "prepared-quiet: launch prepared the history, one index left: \(outcome)")
        setenv("MAC_MEM_HOME", memory.path, 1)
        let d = defaults(["recording": true])
        MemoryViewModel.launchIntentDefaults = d
        let model = MemoryViewModel(prepared: outcome)
        MemoryViewModel.launchIntentDefaults = nil
        let notices = FakeNotices(), wake = FakeWake()
        model.noticeCenter = notices.center
        model.wakeSystem = wake.system
        let o = Opened(model: model, notices: notices, wake: wake, home: memory, defaults: d)
        _ = try await waitFor(3) { model.recording && !model.history.busy }
        try await tick(0.5)
        check(model.recording && notices.posted.isEmpty && calm(o), "prepared-quiet", "a launch that prepared the history records, with nothing said: \(describe(o))")
        check(!indexExists(memory, "records_at"), "prepared-quiet",
              "…and nothing beside the recorder built the time index launch left for the next launch's preparation (was: built by the look for a paused import, MemoryFlowStore)")
        model.stopCapture()
    }

    // MARK: G. Quit during a timed pause (gold r3, gate item 4)

    /// What AppKit's terminate does for the menu bar's routes (AppQuit: the model closes Settings, then willTerminate).
    static func terminate() {
        AppQuit.willQuit()
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
    }

    static func quitDuringTimedPause() async throws {
        let memory = try await existingHistory("quit-timed")
        let kept: MemoryDefaults, until: Date
        weak var quit: MemoryViewModel?
        do {
            let o = try await open("quit-timed", home: memory)
            quit = o.model
            o.model.startCapture()
            guard o.model.recording else { check(false, "harness", "quit-timed did not record"); return }
            o.model.pauseFor(minutes: 15)
            guard let end = o.model.pauseUntil else { check(false, "harness", "quit-timed: no timed pause: \(describe(o))"); return }
            until = end
            let routes = DaydreamMenuBarRoutes(openWindow: { _ in }, activate: {}, openURL: { _ in }, terminate: { MainActor.assumeIsolated { terminate() } })
            DaydreamMenuBarPanel.actions(model: o.model, routes: routes).quit()
            let saved = intent(o.defaults)
            check((saved?["until"] as? Double).map { abs($0 - end.timeIntervalSince1970) < 1 } == true, "r3-quit",
                  "Pause for 15 minutes, then the menu bar's Quit: the launch intent keeps the pause: \(String(describing: saved))")
            kept = o.defaults
        }
        // The process ends: the quit model (and its recorder lock) goes.
        _ = try await waitFor(5) { quit == nil }
        check(quit == nil, "harness", "quit-timed: the quit model is gone")
        try await tick(0.3)
        // The next launch, on the same history, with what the quit left.
        setenv("MAC_MEM_HOME", memory.path, 1)
        MemoryViewModel.launchIntentDefaults = kept
        let model = MemoryViewModel()
        MemoryViewModel.launchIntentDefaults = nil
        let notices = FakeNotices(), wake = FakeWake()
        model.noticeCenter = notices.center
        model.wakeSystem = wake.system
        _ = try await waitFor(3) { !model.history.busy }
        try await tick(0.3)
        let next = Opened(model: model, notices: notices, wake: wake, home: memory, defaults: kept)
        check(!model.anotherCopyOpen && model.pauseUntil.map { abs($0.timeIntervalSince(until)) < 1 } == true && pausedUntil(next) != nil
              && model.recordingState.kind == .paused && notices.posted.isEmpty, "r3-quit",
              "…and the next launch picks it up: Paused until the same time, nothing said: \(describe(next))")
        model.stopCapture()
        // A pause that ended while DayDream was closed records at launch.
        let ended = try await open("quit-timed-ended", intent: ["until": Date().addingTimeInterval(-30).timeIntervalSince1970])
        _ = try await waitFor(3) { ended.model.recording }
        check(ended.model.recording && ended.notices.posted.isEmpty, "r3-quit", "a pause that ended while DayDream was closed records at launch: \(describe(ended))")
        ended.model.stopCapture()
    }

    /// DayDream › Quit DayDream (⌘Q) quits the same way: it doesn't end the person's pause first.
    static func quitCommandKeepsTimedPause() async throws {
        let o = try await open("quit-command")
        o.model.startCapture()
        o.model.pauseFor(minutes: 15)
        let until = o.model.pauseUntil
        var quits = 0
        let command = DaydreamQuitCommand(model: o.model, quit: { quits += 1 })
        // The command's button action (DayDream › Quit DayDream and ⌘Q). On 3f70834 it was
        // `{ model?.cancelTimedPause(); quit() }`: R3_BASE runs that there, where `run` doesn't exist.
        #if R3_BASE
        o.model.cancelTimedPause(); command.quit()
        #else
        DaydreamQuitCommand.run(model: o.model, quit: command.quit)
        #endif
        check(quits == 1 && o.model.pauseUntil == until && until != nil && (intent(o.defaults)?["until"] as? Double) != nil, "r3-quit",
              "Quit DayDream (⌘Q) during a timed pause keeps the pause for the next launch: until \(String(describing: o.model.pauseUntil)), intent \(String(describing: intent(o.defaults)))")
        o.model.stopCapture()
    }
}
