// DD-RECIPE: APP
// A moment's "not allowed" at an automatic start (gold G33, final review), on the REAL MemoryViewModel with the check
// seams (in-memory typing keys, no event tap, no login item, private defaults, fake lock and console reads and a fake
// notice center; run-checks.sh sets a synthetic HOME and CFFIXED_USER_HOME). macOS's privacy service can answer "not
// allowed" for a few milliseconds, right after wake say. Every read inside that window says off (the start's own read
// and the snapshot read alike), not one isolated read. Nothing records: a "recording" session here is a row in a
// private store; no event tap, Accessibility read, Keychain item, login item, notification or Apple Event is used.
//   A. The wake start after an unlock, inside a 2, 10, 50 or 300 ms blip: recording comes back by itself, nothing is
//      said, and no line says a permission is off.
//   B. A timed pause's end inside a blip: recording comes back by itself.
//   C. The launch resume (and its first permission read) inside a blip: recording comes back by itself, and Start
//      doesn't go to Quit & Reopen afterwards (the blip isn't Input Monitoring turned on after launch).
//   D. An import ending (the start that waited for it) inside a blip: recording comes back by itself.
//   E. A permission really turned off still never starts recording: at the wake start, a timed pause's end and launch,
//      recording stays off, one notice says the permissions are off, and nothing keeps trying.
//   F. The person's own Start takes its read as it is: Needs Permission at once, nothing waits to start later.
//   G. (gold r2, V1) A launch with nothing to resume (the owner had stopped recording) whose first reads fall inside a
//      150-1200 ms blip, with no refresh from outside: 2.4 s later Start doesn't go to setup (Quit & Reopen), the state
//      isn't Needs Permission, and the person's Start records. Input Monitoring really off at launch and turned on later
//      still goes to Quit & Reopen (macOS needs the reopen then).
//   H. (gold r3, gate item 2) A 1.2, 1.8 or 2.5 s blip that starts at an unlock (its Input Monitoring reads fall in the
//      first seconds after the unlock): recording comes back, Start doesn't go to setup (Quit & Reopen), the owner's
//      Pause then Resume records, and a later automatic start (an import ending across a lock) records with nothing
//      said. A 2.5 s off read away from any wake still counts as Input Monitoring turned off and on (G32: Start goes
//      to Quit & Reopen), until keys reach the input tap: then Start and Resume record.
//   I. (gold r3, gate item 3) A 1.2, 2.0 or 3.0 s blip over the unlock's own start read: recording comes back, nothing
//      is said. A permission off for longer gets its one notice; both on again, recording starts by itself and the
//      notice goes. After the person's own Start read off, the state follows the reads (no "permissions are off" with
//      both on), and nothing starts by itself. The person's Stop ends the waiting. Input Monitoring really off at launch
//      and turned on: nothing starts (macOS needs the reopen), the notice goes, and Start goes to Quit & Reopen.
// Before this (6bd9e36): A, B, C and D stopped recording for good with a notice saying both permissions were off.
// Before gold r3 (3f70834): H's 1.8 and 2.5 s rows sent Resume to Quit & Reopen and the import's start failed with a
// notice; H's keys row stayed at Quit & Reopen; I's 1.2 and 2.0 s rows stopped recording for good with a notice, the
// loss row never came back, the person-Start row kept "permissions are off", and the launch-off row kept its notice.
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

/// What the seams read. `granted` false: the permissions are really off. `blipUntil`: every read before then says off.
enum Seams {
    nonisolated(unsafe) static var granted = true
    nonisolated(unsafe) static var blipUntil: Date?
    static var now: Bool { granted && (blipUntil.map { Date() >= $0 } ?? true) }
    nonisolated(unsafe) static var reads = 0
    /// The recorder the last start made (the seam starts no tap), so a row can hand it a key as the tap would.
    nonisolated(unsafe) static var capture: EventCapture?
    /// perm-1004: DayDream restarting itself for Input Monitoring (the seam restarts nothing).
    nonisolated(unsafe) static var autoRelaunches = 0
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
/// Lock and console reads, and the main queue's timers, held until the row runs them (`runPending`).
@MainActor final class FakeWake {
    var locked = false, onConsole = true
    var pending: [(TimeInterval, () -> Void)] = []
    var system: WakeSystem {
        WakeSystem(screenLocked: { self.locked }, onConsole: { self.onConsole },
                   after: { delay, work in self.pending.append((delay, work)) }, now: { Date() })
    }
    @discardableResult func runPending() -> [TimeInterval] {
        let jobs = pending; pending = []
        for (_, work) in jobs { work() }
        return jobs.map(\.0)
    }
}
struct Opened { let model: MemoryViewModel; let notices: FakeNotices; let wake: FakeWake; let home: URL }

@main @MainActor struct PermissionBlipChecks {
    static var out = URL(fileURLWithPath: "/")

    static func main() async throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 240) {
            FileHandle.standardError.write(Data("FAIL: permission-blip-checks watchdog expired after 240s\n".utf8)); exit(2)
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
        out = URL(fileURLWithPath: outPath, isDirectory: true).appendingPathComponent("permission-blip", isDirectory: true)
        try makePrivateDirectory(out)
        MemoryViewModel.permissionsGranted = { Seams.reads += 1; return Seams.now }
        MemoryViewModel.permissionRead = { PermissionSnapshot(accessibility: Seams.now, inputMonitoring: Seams.now) }
        MemoryViewModel.startInput = { capture in Seams.capture = capture; return true }
        MemoryViewModel.readLaunchLocation = { .applications }
        MemoryViewModel.canReopen = { true }
        // perm-1004: the automatic restart is recorded, never made; its cooldown time stays in memory.
        MemoryViewModel.performAutoRelaunch = { _ in Seams.autoRelaunches += 1; return true }
        MemoryViewModel.autoRelaunchDefaults = MemoryDefaults()
        // Setup finished, in the registration domain only (gold r2: in memory; nothing reaches any preferences file).
        UserDefaults.standard.register(defaults: [MemoryViewModel.setupCompletedKey: true])

        for w in [0.002, 0.01, 0.05, 0.3] { try await wakeBlip(w) }
        try await timedPauseBlip()
        try await launchBlip()
        try await operationBlip()
        try await lossAtWake()
        try await lossAtTimedPauseEnd()
        try await lossAtLaunch()
        try await personStart()
        for w in [0.15, 0.25, 0.4, 0.8, 1.2] { try await launchBlipNoIntent(w) }
        let relaunchesBefore = Seams.autoRelaunches
        check(relaunchesBefore == 0, "perm-1004-auto", "no blip, loss or person-Start row restarted DayDream by itself: \(relaunchesBefore)")
        try await offAtLaunchTurnedOn()
        // gold r3 (gate items 2 and 3)
        for w in [1.2, 1.8, 2.5] { try await unlockBlipLatch(w) }
        try await offAwayFromWakeThenKeys()
        for w in [1.2, 2.0, 3.0] { try await blipOverStartRead(w) }
        try await longLossComesBack()
        try await personStartReadsFollow()
        try await stopEndsWaiting()
        try await offAtLaunchTurnedOnWithIntent()
        try await timedPauseKeptThroughComeback()
        try await autoRelaunchFails()

        print("permission-blip: \(Report.passed) passed, \(Report.failed) failed")
        fflush(stdout)
        exit(Report.failed == 0 ? 0 : 1)
    }

    /// The launch intent, in memory (gold r2: a named suite would reach cfprefsd, which ignores CFFIXED_USER_HOME).
    static func suite(_ intent: [String: Any]?) -> UserDefaults {
        let defaults = MemoryDefaults()
        if let intent { defaults.set(intent, forKey: "DaydreamRecordingWantedV1") }
        return defaults
    }
    /// A model launched on a new private history (`intent`: the launch intent), once its launch work has run.
    /// `settle` false: returned at once, before any of the main queue's later work (a launch read's confirm read) runs.
    static func open(_ name: String, intent: UserDefaults? = nil, settle: Bool = true) async throws -> Opened {
        let memory = out.appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        try makePrivateDirectory(memory)
        setenv("MAC_MEM_HOME", memory.path, 1)
        MemoryViewModel.launchIntentDefaults = intent
        let model = MemoryViewModel()
        MemoryViewModel.launchIntentDefaults = nil
        let notices = FakeNotices(), wake = FakeWake()
        model.noticeCenter = notices.center
        model.wakeSystem = wake.system
        check(!model.anotherCopyOpen, "harness", "\(name) opened its own history")
        if settle {
            _ = try await waitFor(3) { !model.history.busy }
            try await tick(0.1)
        }
        return Opened(model: model, notices: notices, wake: wake, home: memory)
    }
    /// Runs what the model set to run later (a wake settle, a read again), as the main queue would after its delay,
    /// with `gap` seconds of real time before each round, until recording is on, a notice went out or nothing is left.
    static func settle(_ o: Opened, gap: Double = 0.1, rounds: Int = 30) async throws {
        var n = 0
        while !o.model.recording && o.notices.posted.isEmpty && !o.wake.pending.isEmpty && n < rounds {
            try await tick(gap); o.wake.runPending(); n += 1
        }
        try await tick(0.1) // a stop notice goes out on the next turn
    }
    /// No notice says a permission is off.
    static func saysOff(_ o: Opened) -> Bool {
        o.notices.posted.contains { $0.body.contains("off for DayDream") || $0.body.contains("Choose Allow") }
    }
    static func describe(_ o: Opened) -> String {
        "\(o.model.recordingState), wanted \(o.model.recordingWanted), notices \(o.notices.posted.map(\.body)), pending \(o.wake.pending.map(\.0))"
    }

    // MARK: A. The wake start

    static func wakeBlip(_ w: Double) async throws {
        let ms = Int(w * 1000)
        let o = try await open("wake-\(ms)")
        o.model.startCapture()
        guard o.model.recording else { check(false, "harness", "wake-\(ms) did not record"); return }
        o.wake.locked = true; o.model.suspend(.screenLock)
        o.wake.locked = false; o.model.unsuspend(.screenLock)
        Seams.blipUntil = Date().addingTimeInterval(w)
        o.wake.runPending() // the settle after the unlock: the start runs inside the blip
        if !o.model.recording {
            // Reading again: one calm state, nothing saying a permission is off.
            check(o.model.recordingState.kind != .needsPermission && o.model.presentation.issue == nil && o.notices.posted.isEmpty,
                  "G33-wake", "…while it reads again, nothing says a permission is off: \(o.model.recordingState), line \(String(describing: o.model.presentation.issue))")
        }
        try await tick(max(0.1, w))
        Seams.blipUntil = nil
        try await settle(o)
        check(o.model.recording && o.model.recordingWanted, "G33-wake", "a \(ms) ms blip at the wake start: recording comes back by itself: \(describe(o))")
        check(o.notices.posted.isEmpty, "G33-wake", "…and nothing is said: \(o.notices.posted.map(\.body))")
        check(o.model.recordingState.kind == .recording && o.model.presentation.issue == nil, "G33-wake", "…and the state is Recording, no line: \(o.model.recordingState)")
        o.model.stopCapture()
    }

    // MARK: B. A timed pause's end

    static func timedPauseBlip() async throws {
        let end = Date().addingTimeInterval(2)
        let o = try await open("timed", intent: suite(["until": end.timeIntervalSince1970]))
        check(o.model.pauseUntil != nil, "harness", "the timed pause was picked up at launch")
        while Date() < end.addingTimeInterval(-0.2) { try await tick(0.05) }
        // The pause's one-second timer reaches its end inside the blip.
        Seams.blipUntil = end.addingTimeInterval(1.2)
        _ = try await waitFor(3) { o.model.pauseUntil == nil }
        _ = try await waitFor(2) { Date() >= Seams.blipUntil! }
        Seams.blipUntil = nil
        try await settle(o)
        check(o.model.recording && o.notices.posted.isEmpty, "G33-timed", "a blip at a timed pause's end: recording comes back by itself, nothing said: \(describe(o))")
        o.model.stopCapture()
    }

    // MARK: C. Launch

    static func launchBlip() async throws {
        // The first permission read and the launch resume both fall inside it.
        Seams.blipUntil = Date().addingTimeInterval(0.4)
        let o = try await open("launch", intent: suite(["recording": true]))
        _ = try await waitFor(2) { Date() >= Seams.blipUntil! }
        Seams.blipUntil = nil
        try await settle(o)
        check(o.model.recording && o.notices.posted.isEmpty, "G33-launch", "a blip at launch: recording starts by itself, nothing said: \(describe(o))")
        o.model.stopCapture()
        check(o.model.setupStepForStart() == nil && o.model.permissionsAtLaunch?.inputMonitoring == true, "G33-launch",
              "…and Start doesn't go to Quit & Reopen afterwards: \(String(describing: o.model.setupStepForStart())), at launch \(String(describing: o.model.permissionsAtLaunch))")
    }

    // MARK: D. An import ending

    static func operationBlip() async throws {
        let o = try await open("import")
        o.model.startCapture()
        guard o.model.recording else { check(false, "harness", "import did not record"); return }
        o.wake.locked = true; o.model.suspend(.screenLock)
        o.model.history.busy = true // an import running (MemoryFlows sets this while it works)
        try await tick()
        o.wake.locked = false; o.model.unsuspend(.screenLock)
        o.wake.runPending()
        check(!o.model.recording && o.model.startWhenFree, "harness", "the unlock start waits for the import: \(describe(o))")
        Seams.blipUntil = Date().addingTimeInterval(0.02)
        o.model.history.busy = false // the import ends inside the blip; its start runs on this change
        _ = try await waitFor(1) { !o.wake.pending.isEmpty || o.model.recording || !o.notices.posted.isEmpty }
        try await tick(0.05)
        Seams.blipUntil = nil
        try await settle(o)
        check(o.model.recording && o.notices.posted.isEmpty, "G33-import", "a blip as the import ends: recording comes back by itself, nothing said: \(describe(o))")
        o.model.stopCapture()
    }

    // MARK: E. A permission really off

    static func lossAtWake() async throws {
        let o = try await open("loss-wake")
        o.model.startCapture()
        guard o.model.recording else { check(false, "harness", "loss-wake did not record"); return }
        o.wake.locked = true; o.model.suspend(.screenLock)
        Seams.granted = false
        defer { Seams.granted = true }
        o.wake.locked = false; o.model.unsuspend(.screenLock)
        o.wake.runPending()
        try await settle(o, gap: 0.4)
        check(!o.model.recording && o.notices.posted.count == 1 && saysOff(o) && !o.model.recordingWanted, "G33-loss",
              "permissions really off at the wake start: recording stays off, one notice says so: \(describe(o))")
        check(o.wake.pending.isEmpty && o.model.recordingState.kind == .needsPermission, "G33-loss", "…no start waits, and the state says why: \(describe(o))")
        // gold r3 (gate item 3): the reads go on; both on again, recording starts by itself and the notice goes.
        Seams.granted = true
        _ = try await waitFor(3.5) { o.model.recording }
        check(o.model.recording && o.model.stopNotice == nil && o.notices.posted.count == 1, "G33-loss",
              "…and allowing them again starts recording by itself, and the notice goes: \(describe(o)), notice \(String(describing: o.model.stopNotice))")
        o.model.stopCapture()
    }

    static func lossAtTimedPauseEnd() async throws {
        let end = Date().addingTimeInterval(2)
        let o = try await open("loss-timed", intent: suite(["until": end.timeIntervalSince1970]))
        check(o.model.pauseUntil != nil, "harness", "the timed pause was picked up at launch")
        while Date() < end.addingTimeInterval(-0.3) { try await tick(0.05) }
        Seams.granted = false
        defer { Seams.granted = true }
        _ = try await waitFor(3) { o.model.pauseUntil == nil }
        try await settle(o, gap: 0.4)
        check(!o.model.recording && o.notices.posted.count == 1 && saysOff(o) && !o.model.recordingWanted && o.wake.pending.isEmpty, "G33-loss",
              "permissions really off at a timed pause's end: recording stays off, one notice, nothing keeps trying: \(describe(o))")
        o.model.stopCapture() // gold r3: the reads go on after a loss; the person's Stop ends them (later rows share the seams)
    }

    static func lossAtLaunch() async throws {
        Seams.granted = false
        defer { Seams.granted = true }
        let o = try await open("loss-launch", intent: suite(["recording": true]))
        try await settle(o, gap: 0.4)
        check(!o.model.recording && o.notices.posted.count == 1 && saysOff(o) && !o.model.recordingWanted && o.wake.pending.isEmpty, "G33-loss",
              "permissions really off at launch: recording stays off, one notice, nothing keeps trying: \(describe(o))")
        check(o.model.recordingState.kind == .needsPermission, "G33-loss", "…and the state says why: \(o.model.recordingState)")
        o.model.stopCapture()
    }

    // MARK: F. The person's Start

    static func personStart() async throws {
        let o = try await open("person")
        Seams.blipUntil = Date().addingTimeInterval(0.2)
        o.model.startCapture()
        check(!o.model.recording && o.model.recordingState.kind == .needsPermission && o.wake.pending.isEmpty, "G33-person",
              "the person's own Start takes its read as it is: Needs Permission at once, nothing waits to start later: \(describe(o))")
        _ = try await waitFor(1) { Date() >= Seams.blipUntil! }
        Seams.blipUntil = nil
        o.wake.runPending(); try await tick(0.1)
        check(!o.model.recording && o.notices.posted.isEmpty, "G33-person", "…no notice, and nothing started behind it: \(describe(o))")
    }

    // MARK: G. A launch with nothing to resume (gold r2, V1)

    /// The owner had stopped recording; DayDream opens at login and the privacy service answers "not allowed" for the
    /// first reads. Nothing resumes, so nothing reads again but the launch read's own confirm read. Only real time passes
    /// (the main queue's own timers), as with the menu closed.
    static func launchBlipNoIntent(_ w: Double) async throws {
        let ms = Int(w * 1000)
        let t0 = Date()
        Seams.blipUntil = t0.addingTimeInterval(w)
        let o = try await open("launch-nointent-\(ms)", settle: false)
        check(o.model.permissionsAtLaunch?.inputMonitoring == false, "harness", "launch-nointent-\(ms): the first read fell inside the blip")
        while Date() < t0.addingTimeInterval(2.4) { try await tick(0.05) }
        Seams.blipUntil = nil
        let state = o.model.recordingState
        let step = o.model.setupStepForStart()
        check(step == nil && o.model.permissionsAtLaunch?.inputMonitoring == true, "G-launch-nointent",
              "a \(ms) ms blip at a launch with nothing to resume: 2.4 s later Start doesn't go to setup (Quit & Reopen): step \(String(describing: step)), at launch \(String(describing: o.model.permissionsAtLaunch))")
        check(state.kind != .needsPermission && o.model.presentation.issue == nil, "G-launch-nointent",
              "…and with nothing refreshing it, the state isn't Needs Permission and no line shows: \(state), line \(String(describing: o.model.presentation.issue))")
        o.model.requestStart(openSetup: {})
        check(o.model.recording && o.model.setupRequest == nil && o.notices.posted.isEmpty, "G-launch-nointent",
              "…and the person's Start records: \(describe(o)), setup \(String(describing: o.model.setupRequest))")
        o.model.stopCapture()
    }

    /// Input Monitoring really off at launch (both reads off), turned on later: macOS applies it only once DayDream reopens,
    /// so Start still goes to setup's Permissions page (Quit & Reopen). The blip rule must not take this for a blip.
    static func offAtLaunchTurnedOn() async throws {
        Seams.granted = false
        defer { Seams.granted = true }
        let t0 = Date()
        let o = try await open("launch-off-on", settle: false)
        while Date() < t0.addingTimeInterval(2.4) { try await tick(0.05) }
        Seams.granted = true
        o.model.refreshCaptureStatus()
        check(o.model.permissionsAtLaunch?.inputMonitoring == false && o.model.setupStepForStart() == .permissions, "G-launch-nointent",
              "Input Monitoring really off at launch and turned on 2.4 s later: Start still goes to Quit & Reopen: \(String(describing: o.model.setupStepForStart())), at launch \(String(describing: o.model.permissionsAtLaunch))")
        // perm-1004 (owner: no manual restart): both read on, so DayDream says so and restarts itself once.
        check(o.model.permissionAutoRelaunch && o.model.permissionRequests?.autoRelaunch == true, "perm-1004-auto",
              "…both on: the permission page says DayDream restarts by itself: \(o.model.permissionAutoRelaunch)")
        let before = Seams.autoRelaunches
        _ = try await waitFor(PermissionRelaunch.autoDelay + 1.5) { Seams.autoRelaunches > before }
        check(Seams.autoRelaunches == before + 1, "perm-1004-auto",
              "…and restarts itself once, \(PermissionRelaunch.autoDelay) s later: \(Seams.autoRelaunches - before) restart(s)")
        o.model.refreshCaptureStatus(); try await tick(PermissionRelaunch.autoDelay + 0.5)
        check(Seams.autoRelaunches == before + 1, "perm-1004-auto", "…never twice (cooldown): \(Seams.autoRelaunches - before) restart(s)")
    }

    // MARK: H. gold r3 (gate item 2): a blip at an unlock leaves no Quit & Reopen behind

    /// Lock, then a `w` s blip that starts as the screen unlocks: the unlock's own reads (and the Input Monitoring watch's
    /// confirm read 1.6 s later, on the real main queue) fall inside it. Then the unlock's start runs after it.
    static func unlockBlipLatch(_ w: Double) async throws {
        let ms = Int(w * 1000)
        let o = try await open("unlock-latch-\(ms)")
        o.model.startCapture()
        guard o.model.recording else { check(false, "harness", "unlock-latch-\(ms) did not record"); return }
        o.wake.locked = true; o.model.suspend(.screenLock)
        try await tick(0.2)
        let t0 = Date()
        Seams.blipUntil = t0.addingTimeInterval(w)
        o.wake.locked = false; o.model.unsuspend(.screenLock)
        while Date() < t0.addingTimeInterval(max(w, 1.7) + 0.3) { try await tick(0.05) }
        Seams.blipUntil = nil
        try await settle(o)
        check(o.model.recording && o.notices.posted.isEmpty, "r3-latch", "a \(ms) ms blip at an unlock: recording comes back, nothing said: \(describe(o))")
        check(o.model.setupStepForStart() == nil && o.model.permissionsAtLaunch?.inputMonitoring == true, "r3-latch",
              "…and Start doesn't go to setup (Quit & Reopen): \(String(describing: o.model.setupStepForStart())), at launch \(String(describing: o.model.permissionsAtLaunch))")
        // The owner's Pause, then Resume.
        o.model.pauseFor(minutes: 5)
        var opened = false
        o.model.requestStart(openSetup: { opened = true })
        check(o.model.recording && !opened, "r3-latch", "…the owner's Pause then Resume records: \(describe(o)), setup \(String(describing: opened ? o.model.setupRequest : nil))")
        if !o.model.recording { o.model.startCapture() }
        // An import across a lock: the start that waited for it records by itself, and nothing is said.
        o.wake.locked = true; o.model.suspend(.screenLock)
        o.model.history.busy = true
        try await tick()
        o.wake.locked = false; o.model.unsuspend(.screenLock)
        o.wake.runPending()
        o.model.history.busy = false
        _ = try await waitFor(1) { o.model.recording || !o.wake.pending.isEmpty || !o.notices.posted.isEmpty }
        try await settle(o)
        check(o.model.recording && o.notices.posted.isEmpty && o.model.recordingWanted, "r3-latch",
              "…and after an import across a lock, recording starts by itself with nothing said: \(describe(o))")
        o.model.stopCapture()
    }

    /// Input Monitoring reads off for 2.5 s with no wake near (as when it is turned off and on in System Settings): Start
    /// goes to Quit & Reopen (G32), until keys reach DayDream's input tap. Then it works: Start and Resume record.
    static func offAwayFromWakeThenKeys() async throws {
        let o = try await open("away-keys")
        o.model.startCapture()
        guard o.model.recording, let capture = Seams.capture else { check(false, "harness", "away-keys did not record"); return }
        let t0 = Date()
        Seams.blipUntil = t0.addingTimeInterval(2.5)
        o.model.checkPermissions()
        while Date() < t0.addingTimeInterval(2.7) { try await tick(0.05) }
        Seams.blipUntil = nil
        o.model.checkPermissions()
        o.model.pauseFor(minutes: 5)
        check(o.model.setupStepForStart() == .permissions, "r3-keys",
              "Input Monitoring read off for 2.5 s away from any wake, no key since: Start still goes to Quit & Reopen (G32): \(String(describing: o.model.setupStepForStart()))")
        o.model.startCapture()
        guard o.model.recording else { check(false, "harness", "away-keys: the second start did not record"); return }
        let recorder = Seams.capture ?? capture
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) { recorder.tapEventForChecks(.keyDown, down) }
        check(o.model.permissionsAtLaunch?.inputMonitoring == true, "r3-keys", "…a key reaching the input tap proves it works: at launch \(String(describing: o.model.permissionsAtLaunch))")
        o.model.pauseFor(minutes: 5)
        var opened = false
        o.model.requestStart(openSetup: { opened = true })
        check(o.model.recording && !opened, "r3-keys", "…then the owner's Pause and Resume record: \(describe(o)), setup \(opened)")
        o.model.stopCapture()
    }

    // MARK: I. gold r3 (gate item 3): a permission read off at an automatic start never stops recording for good

    /// Recording, lock, unlock; a `w` s blip starts as the unlock's start reads the permissions.
    static func blipOverStartRead(_ w: Double) async throws {
        let ms = Int(w * 1000)
        let o = try await open("start-read-\(ms)")
        o.model.startCapture()
        guard o.model.recording else { check(false, "harness", "start-read-\(ms) did not record"); return }
        o.wake.locked = true; o.model.suspend(.screenLock)
        o.wake.locked = false; o.model.unsuspend(.screenLock)
        let end = Date().addingTimeInterval(w)
        Seams.blipUntil = end
        o.wake.runPending() // the unlock's start, inside the blip
        var n = 0
        while !o.model.recording && o.notices.posted.isEmpty && n < 60 { try await tick(0.1); o.wake.runPending(); n += 1 }
        Seams.blipUntil = nil
        try await tick(0.1)
        check(o.model.recording && o.notices.posted.isEmpty && o.model.recordingWanted, "r3-settle",
              "a \(ms) ms blip over the unlock's start read: recording comes back, nothing is said: \(describe(o))")
        check(o.model.recordingState.kind == .recording && o.model.presentation.issue == nil, "r3-settle", "…and the state is Recording, no line: \(o.model.recordingState)")
        o.model.stopCapture()
    }

    /// Off at the unlock's start for 6 s: one notice once the hold gives up; both on again, recording starts by itself.
    static func longLossComesBack() async throws {
        let o = try await open("long-loss")
        o.model.startCapture()
        guard o.model.recording else { check(false, "harness", "long-loss did not record"); return }
        o.wake.locked = true; o.model.suspend(.screenLock)
        o.wake.locked = false; o.model.unsuspend(.screenLock)
        let end = Date().addingTimeInterval(6)
        Seams.blipUntil = end
        o.wake.runPending()
        try await settle(o, gap: 0.3, rounds: 40)
        check(!o.model.recording && o.notices.posted.count == 1 && saysOff(o), "r3-comeback", "off for 6 s at the unlock's start: one notice says so: \(describe(o))")
        _ = try await waitFor(2) { Date() >= end }
        Seams.blipUntil = nil
        _ = try await waitFor(3.5) { o.model.recording }
        check(o.model.recording && o.model.recordingWanted && o.model.stopNotice == nil && o.notices.posted.count == 1, "r3-comeback",
              "…both on again: recording starts by itself and the notice goes: \(describe(o)), notice \(String(describing: o.model.stopNotice))")
        o.model.stopCapture()
    }

    /// The person's own Start read off (Needs Permission at once, F). With nothing reading again, "permissions are off"
    /// stayed with both on. Now the state follows the reads; nothing starts by itself (it was their Start, read as is).
    static func personStartReadsFollow() async throws {
        let o = try await open("person-follow")
        Seams.blipUntil = Date().addingTimeInterval(0.3)
        o.model.startCapture()
        check(o.model.recordingState.kind == .needsPermission, "harness", "person-follow: Needs Permission at once: \(o.model.recordingState)")
        try await tick(3)
        Seams.blipUntil = nil
        check(o.model.recordingState.kind != .needsPermission && !o.model.recording && o.notices.posted.isEmpty, "r3-follow",
              "the person's Start read off, both on again 0.3 s later: 3 s on the state no longer says a permission is off, nothing started: \(o.model.recordingState)")
        o.model.stopCapture()
    }

    /// A permission stop, then the person's Stop: both on again later starts nothing.
    static func stopEndsWaiting() async throws {
        let o = try await open("stop-ends")
        o.model.startCapture()
        guard o.model.recording else { check(false, "harness", "stop-ends did not record"); return }
        o.wake.locked = true; o.model.suspend(.screenLock)
        Seams.granted = false
        defer { Seams.granted = true }
        o.wake.locked = false; o.model.unsuspend(.screenLock)
        o.wake.runPending()
        try await settle(o, gap: 0.3, rounds: 40)
        check(!o.model.recording && o.notices.posted.count == 1, "harness", "stop-ends: the loss was said: \(describe(o))")
        o.model.stopCapture()
        Seams.granted = true
        try await tick(3)
        check(!o.model.recording && o.model.recordingState.kind == .off, "r3-stop", "a permission stop, then the person's Stop: both on again starts nothing: \(describe(o))")
    }

    /// gold/int r3 review: the owner's "Pause for 5 minutes", a lock, a permission off at the unlock (the pause can't be
    /// picked up, one notice), then both on again well before the pause ends: the comeback picks the pause up until the
    /// same time; it never starts recording before the owner's pause ends.
    static func timedPauseKeptThroughComeback() async throws {
        let o = try await open("timed-comeback")
        o.model.startCapture()
        guard o.model.recording else { check(false, "harness", "timed-comeback did not record"); return }
        o.model.pauseFor(minutes: 5)
        guard let until = o.model.pauseUntil, !o.model.recording else { check(false, "harness", "timed-comeback: no timed pause"); return }
        // A permission turned off during the pause (read off for over a second: a settled loss), then a lock.
        Seams.granted = false
        defer { Seams.granted = true }
        for _ in 0..<5 { _ = o.model.resumeBlocker(); try await tick(0.3) }
        o.wake.locked = true; o.model.suspend(.screenLock)
        o.wake.locked = false; o.model.unsuspend(.screenLock)
        o.wake.runPending()
        try await settle(o, gap: 0.3, rounds: 40)
        check(!o.model.recording && o.notices.posted.count == 1, "r3-timed-comeback", "a permission off at the unlock during a timed pause: nothing records, one notice: \(describe(o))")
        Seams.granted = true
        try await tick(3.5)
        check(!o.model.recording, "r3-timed-comeback", "…both on again 4 minutes before the pause ends: recording doesn't start early: \(describe(o))")
        check(o.model.pauseUntil.map { abs($0.timeIntervalSince(until)) < 1 } == true && o.model.stopNotice == nil, "r3-timed-comeback",
              "…the owner's pause is picked up until the same time, and the stale notice goes: until \(String(describing: o.model.pauseUntil)) (was \(until)), notice \(String(describing: o.model.stopNotice))")
        o.model.stopCapture()
    }

    /// Input Monitoring really off at launch (with recording to resume), turned on later: macOS feeds it only after a
    /// reopen, so nothing starts; the "permissions are off" notice goes, and Start goes to Quit & Reopen.
    static func offAtLaunchTurnedOnWithIntent() async throws {
        Seams.granted = false
        defer { Seams.granted = true }
        let o = try await open("launch-off-intent", intent: suite(["recording": true]))
        try await settle(o, gap: 0.3, rounds: 40)
        check(!o.model.recording && o.notices.posted.count == 1 && saysOff(o), "harness", "launch-off-intent: one notice: \(describe(o))")
        Seams.granted = true
        try await tick(3)
        check(!o.model.recording && o.model.stopNotice == nil && o.notices.posted.count == 1, "r3-launch-off",
              "Input Monitoring off at launch, turned on: nothing starts (macOS needs the reopen) and the stale notice goes: \(describe(o)), notice \(String(describing: o.model.stopNotice))")
        check(o.model.setupStepForStart() == .permissions && o.model.recordingState.kind != .needsPermission, "r3-launch-off",
              "…Start goes to Quit & Reopen, and the state no longer says a permission is off: \(String(describing: o.model.setupStepForStart())), \(o.model.recordingState)")
    }

    /// perm-1004: a restart that couldn't start (DayDream can't reopen itself) takes the line back: Quit & Reopen stays.
    static func autoRelaunchFails() async throws {
        MemoryViewModel.autoRelaunchDefaults = MemoryDefaults()
        MemoryViewModel.performAutoRelaunch = { _ in false }
        defer { MemoryViewModel.performAutoRelaunch = { _ in Seams.autoRelaunches += 1; return true } }
        Seams.granted = false
        defer { Seams.granted = true }
        let t0 = Date()
        let o = try await open("launch-off-on-fails", settle: false)
        while Date() < t0.addingTimeInterval(2.4) { try await tick(0.05) }
        Seams.granted = true
        o.model.refreshCaptureStatus()
        check(o.model.permissionAutoRelaunch, "perm-1004-auto", "a restart that will fail is still tried: \(o.model.permissionAutoRelaunch)")
        try await tick(PermissionRelaunch.autoDelay + 0.6)
        check(!o.model.permissionAutoRelaunch && o.model.permissionRequests?.autoRelaunch == false && o.model.setupStepForStart() == .permissions,
              "perm-1004-auto", "…it couldn't start: no restart line, Start goes to Quit & Reopen: \(o.model.permissionAutoRelaunch), \(String(describing: o.model.setupStepForStart()))")
    }
}
