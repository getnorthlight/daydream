// DD-RECIPE: APP
// The permission screen never flashes (claude/permflash-015; owner's laptop, macOS 15.7.2, 10/04: "occasionally I see
// the permission screen flash for like 2 frames even though everything was enabled and it is working perfectly").
// macOS's privacy service can answer "not allowed" for a moment (permission-blip-checks: 2 ms to 3 s, right after a
// wake or an unlock say). Recording already rides through that; these rows are about what is SHOWN meanwhile, on the
// REAL MemoryViewModel with the check seams (in-memory typing keys, no event tap, no login item, private defaults,
// fake lock and console reads, a fake notice center; run-checks.sh sets a synthetic HOME and CFFIXED_USER_HOME).
// Nothing records: a "recording" session is a row in a private store. No window is ordered on screen (H hosts its views
// in a window never shown), no event is posted, and no permission is read from macOS (every read is the seam's).
//
// What is shown is sampled the way a view draws it: after every change the model publishes (on the next turn of the
// main queue) and every few milliseconds. A sample "says a permission is off" when any surface would:
//   state    Needs Permission (the toolbar capsule, the status popover's permission rows, the menu's header and its
//            Turn on … button, the ribbon, the Settings status card)
//   menubar  the menu bar mark's "!"
//   line     the orange line names the permissions
//   rows     a "… needed" row (the status popover's Permissions row, Settings' Permissions row)
//   start    Start or Resume drawn but disabled, for the permissions
//   status   the status footnote says "Permissions required"
// Rows:
//   A. One off read between on reads, at each read a refresh makes: recording, paused, stopped, and never started.
//   B. Off reads for 2, 10, 50, 300 ms and 1.2 s as DayDream comes to the front or its window reopens (the refresh
//      both make), in the same four states.
//   C. The same blips over a launch's first reads, with recording to resume and with nothing to resume.
//   D. The same blips as the screen unlocks: recording before the lock, and stopped before it; and the 1.8, 2.5 and
//      3 s blips permission-blip-checks models right after an unlock.
//   E. A permission really turned off shows: within 2.5 s while recording, paused, stopped and never started; at
//      launch; and at an unlock once the start that read it gives up (its one notice goes out then).
//   F. The person's own Start takes its read as it is: Needs Permission at once (permission-blip-checks F).
//   G. The rule itself (`PermissionSettle`), pinned on a fake clock.
//   H. The permission page's own reads (Settings › Permissions, the permissions window, setup) and setup's first page.
//   I. A brand-new install (setup never finished, permissions never allowed): setup's first page is Permissions at once,
//      with no blank window while an off read waits to settle (there is nothing to flash away from).
import AppKit
import Combine
import CSQLite
import MemoryCore
import MemoryUI
import SwiftUI

@MainActor enum Report {
    static var passed = 0, failed = 0
    static func check(_ ok: Bool, _ id: String, _ message: @autoclosure () -> String) {
        if ok { passed += 1; print("PASS [\(id)] \(message())") } else { failed += 1; print("FAIL [\(id)] \(message())") }
        fflush(stdout)
    }
}
@MainActor func check(_ ok: Bool, _ id: String, _ message: @autoclosure () -> String) { Report.check(ok, id, message()) }
func stop(_ message: String) -> Never { fflush(stdout); FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
@MainActor func tick(_ seconds: Double = 0.01) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
func makePrivateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

/// What the seams read. `granted` false: the permissions are really off. `blipUntil`: every read before then says off.
/// `offReads`: these reads (counted from `arm`) say off, the others on (one off read between on reads).
enum Seams {
    nonisolated(unsafe) static var granted = true
    nonisolated(unsafe) static var blipUntil: Date?
    nonisolated(unsafe) static var offReads: Set<Int> = []
    nonisolated(unsafe) static var reads = 0
    static func arm(off: Set<Int>) { reads = 0; offReads = off }
    static func read() -> Bool {
        reads += 1
        if !granted || offReads.contains(reads) { return false }
        return blipUntil.map { Date() >= $0 } ?? true
    }
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
/// Lock and console reads, and the main queue's timers: each runs once its delay has passed (`runDue`).
@MainActor final class FakeWake {
    var locked = false, onConsole = true
    var pending: [(due: Date, work: () -> Void)] = []
    var system: WakeSystem {
        WakeSystem(screenLocked: { self.locked }, onConsole: { self.onConsole },
                   after: { delay, work in self.pending.append((Date().addingTimeInterval(delay), work)) }, now: { Date() })
    }
    func runDue() {
        let now = Date()
        let due = pending.filter { $0.due <= now }
        pending.removeAll { $0.due <= now }
        for job in due { job.work() }
    }
}

/// What the surfaces show of `model` now, as the names in the header.
@MainActor enum Shown {
    static func surfaces(_ model: MemoryViewModel) -> Set<String> {
        var out = Set<String>()
        let p = model.presentation
        let kind = p.state.kind
        if kind == .needsPermission { out.insert("state") }
        if DaydreamMenuBarLabel.image(model: model).drawnState == .needsPermission { out.insert("menubar") }
        if let line = p.issue, line.contains("ermission") { out.insert("line") }
        if let reads = p.permissions, !reads.missing.isEmpty { out.insert("rows") }
        if kind != .needsPermission, kind != .recording, !p.canResume, model.resumeUnavailable == RecordingCopy.permissionBlocker { out.insert("start") }
        if model.status.contains("Permissions required") { out.insert("status") }
        return out
    }
}
/// Samples what is shown after every published change (on the next main-queue turn, as a view draws) and every 4 ms.
@MainActor final class Watch {
    let model: MemoryViewModel
    private(set) var spans: [(start: Date, end: Date, surfaces: Set<String>)] = []
    private var open: (start: Date, surfaces: Set<String>)?
    private var sink: AnyCancellable?
    private var timer: Timer?
    private(set) var samples = 0
    init(_ model: MemoryViewModel) {
        self.model = model
        sink = model.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.sample() } } }
        let timer = Timer(timeInterval: 0.004, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sample() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        sample()
    }
    func sample() {
        samples += 1
        let now = Date(), shown = Shown.surfaces(model)
        if shown.isEmpty {
            if let o = open { spans.append((o.start, now, o.surfaces)); open = nil }
        } else if let o = open { open = (o.start, o.surfaces.union(shown)) } else { open = (now, shown) }
    }
    /// Ends the watch; the spans in which a surface said a permission was off.
    func end() -> [(start: Date, end: Date, surfaces: Set<String>)] {
        sample()
        timer?.invalidate(); sink = nil
        if let o = open { spans.append((o.start, Date(), o.surfaces)); open = nil }
        return spans
    }
    /// When a surface first said so, if any did.
    var firstShown: Date? { spans.first?.start ?? open?.start }
    static func describe(_ spans: [(start: Date, end: Date, surfaces: Set<String>)]) -> String {
        guard !spans.isEmpty else { return "never shown" }
        let longest = spans.map { $0.end.timeIntervalSince($0.start) }.max() ?? 0
        let all = spans.reduce(into: Set<String>()) { $0.formUnion($1.surfaces) }.sorted().joined(separator: ",")
        return "shown \(spans.count)x, longest \(Int(longest * 1000)) ms [\(all)]"
    }
}
struct Opened { let model: MemoryViewModel; let notices: FakeNotices; let wake: FakeWake }

@main @MainActor struct PermissionFlashChecks {
    static var out = URL(fileURLWithPath: "/")
    static let blips: [Double] = [0.002, 0.01, 0.05, 0.3, 1.2]

    static func main() async throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 540) {
            FileHandle.standardError.write(Data("FAIL: permission-flash-checks watchdog expired after 540s\n".utf8)); exit(2)
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
        out = URL(fileURLWithPath: outPath, isDirectory: true).appendingPathComponent("permission-flash", isDirectory: true)
        try makePrivateDirectory(out)
        MemoryViewModel.permissionsGranted = { Seams.read() }
        MemoryViewModel.permissionRead = { let on = Seams.read(); return PermissionSnapshot(accessibility: on, inputMonitoring: on) }
        DaydreamOnboarding.readPermissions = { let on = Seams.read(); return (on, on) }
        MemoryViewModel.startInput = { _ in true }
        MemoryViewModel.readLaunchLocation = { .applications }
        MemoryViewModel.canReopen = { true }
        MemoryViewModel.performAutoRelaunch = { _ in Seams.autoRelaunches += 1; return true }
        MemoryViewModel.autoRelaunchDefaults = MemoryDefaults()
        // Setup finished, in the registration domain only (in memory; nothing reaches any preferences file).
        UserDefaults.standard.register(defaults: [MemoryViewModel.setupCompletedKey: true])

        let only = env["DD_FLASH_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        func runs(_ part: String) -> Bool { only?.contains(part) ?? true }
        if runs("A") { for state in Situation.allCases { try await oneOffRead(state) } }
        if runs("B") { for state in Situation.allCases { for w in blips { try await frontBlip(state, w) } } }
        if runs("C") { for intent in [true, false] { for w in blips { try await launchBlip(w, resumes: intent) } } }
        if runs("D") { for before in [Situation.recording, .stopped] { for w in blips + [1.8, 2.5, 3.0] { try await unlockBlip(before, w) } } }
        if runs("E") {
            for state in Situation.allCases { try await reallyOff(state) }
            try await reallyOffAtLaunch(resumes: true)
            try await reallyOffAtLaunch(resumes: false)
            try await reallyOffAtUnlock()
        }
        if runs("F") { try await personStart() }
        if runs("G") { rule() }
        if runs("H") {
            try await pageReads()
            for w in [0.0, 0.3, 1.2] { try await setupOpens(blip: w) }
            try await setupOpensReallyOff()
        }
        if runs("I") { try await newInstallSetup() }

        print("permission-flash: \(Report.passed) passed, \(Report.failed) failed")
        fflush(stdout)
        exit(Report.failed == 0 ? 0 : 1)
    }

    // MARK: Harness

    static func suite(_ intent: [String: Any]?) -> UserDefaults {
        let defaults = MemoryDefaults()
        if let intent { defaults.set(intent, forKey: "DaydreamRecordingWantedV1") }
        return defaults
    }
    /// A model launched on a new private history (`intent`: the launch intent). `settle`: once its launch work has run.
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
        if model.anotherCopyOpen { check(false, "harness", "\(name) opened its own history") }
        let o = Opened(model: model, notices: notices, wake: wake)
        if settle {
            let end = Date().addingTimeInterval(3)
            while model.history.busy, Date() < end { try await tick(0.05) }
            try await run(o, 0.15)
        }
        return o
    }
    /// Real time passes: what the model set to run later runs once it is due, and while recording the recorder's 0.5 s
    /// heartbeat runs (the seam starts no timer of its own).
    static func run(_ o: Opened, _ seconds: Double, until done: (() -> Bool)? = nil) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            o.wake.runDue()
            if o.model.recording, Date() >= nextBeat { o.model.coordinator?.reconcileResume(); nextBeat = Date().addingTimeInterval(0.5) }
            if done?() == true { return }
            try await tick(0.01)
        }
    }
    static var nextBeat = Date.distantPast

    /// Where the person is when the reads go wrong.
    enum Situation: String, CaseIterable { case recording, paused, stopped, neverStarted = "never started" }
    /// A model in `situation`, with both permissions on and everything settled.
    static func ready(_ situation: Situation, _ name: String) async throws -> Opened? {
        let o = try await open(name)
        if situation != .neverStarted {
            o.model.startCapture()
            guard o.model.recording else { check(false, "harness", "\(name) did not record"); return nil }
            try await run(o, 0.6)
            if situation == .paused { o.model.pauseFor(minutes: 5) }
            if situation == .stopped { o.model.stopCapture() }
            try await run(o, 0.2)
            let kind = o.model.recordingState.kind
            let want: DaydreamCaptureState = situation == .recording ? .recording : situation == .paused ? .paused : .off
            guard kind == want else { check(false, "harness", "\(name) is \(kind), not \(want)"); return nil }
        }
        return o
    }
    static func close(_ o: Opened) async throws {
        Seams.granted = true; Seams.blipUntil = nil; Seams.offReads = []
        o.model.stopCapture()
        try await run(o, 0.1)
    }
    static func ms(_ w: Double) -> String { w < 1 ? "\(Int(w * 1000)) ms" : "\(w) s" }

    // MARK: A. One off read between on reads

    static func oneOffRead(_ situation: Situation) async throws {
        // A refresh makes a handful of reads (the recorder's settled read, the blocker's, the snapshot's): each in turn.
        var shown: [String] = []
        for n in 1...6 {
            guard let o = try await ready(situation, "one-\(situation.rawValue)-\(n)") else { return }
            let watch = Watch(o.model)
            Seams.arm(off: [n])
            o.model.refreshCaptureStatus()
            try await run(o, 2.6)
            let spans = watch.end()
            if !spans.isEmpty { shown.append("read \(n): " + Watch.describe(spans)) }
            try await close(o)
        }
        check(shown.isEmpty, "A-one-read", "\(situation.rawValue): one off read between on reads never shows a permission as off: \(shown.isEmpty ? "never shown" : shown.joined(separator: "; "))")
    }

    // MARK: B. Coming to the front, the window reopening

    static func frontBlip(_ situation: Situation, _ w: Double) async throws {
        guard let o = try await ready(situation, "front-\(situation.rawValue)-\(Int(w * 1000))") else { return }
        let watch = Watch(o.model)
        Seams.blipUntil = Date().addingTimeInterval(w)
        // DayDream comes to the front (or its window reopens): the model reads again; a page in view reads a moment later.
        o.model.refreshCaptureStatus()
        try await run(o, 0.03)
        o.model.checkPermissions()
        try await run(o, w + 2.6)
        let spans = watch.end()
        check(spans.isEmpty, "B-front", "\(situation.rawValue), off for \(ms(w)) as DayDream comes to the front: \(Watch.describe(spans))")
        if w < 1 {
            let kind = o.model.recordingState.kind
            let want: DaydreamCaptureState = situation == .recording ? .recording : situation == .paused ? .paused : .off
            check(kind == want && o.notices.posted.isEmpty, "B-front", "…and it is still \(want), nothing said: \(kind), notices \(o.notices.posted.map(\.body))")
        }
        try await close(o)
    }

    // MARK: C. Launch

    static func launchBlip(_ w: Double, resumes: Bool) async throws {
        Seams.blipUntil = Date().addingTimeInterval(w)
        let o = try await open("launch-\(resumes)-\(Int(w * 1000))", intent: resumes ? suite(["recording": true]) : nil, settle: false)
        let watch = Watch(o.model)
        try await run(o, w + 3.0)
        let spans = watch.end()
        let what = resumes ? "recording to resume" : "nothing to resume"
        check(spans.isEmpty, "C-launch", "launch with \(what), its first reads off for \(ms(w)): \(Watch.describe(spans))")
        if resumes { check(o.model.recording && o.notices.posted.isEmpty, "C-launch", "…and recording started by itself, nothing said: \(o.model.recordingState)") }
        try await close(o)
    }

    // MARK: D. Wake and unlock

    static func unlockBlip(_ before: Situation, _ w: Double) async throws {
        guard let o = try await ready(before, "unlock-\(before.rawValue)-\(Int(w * 1000))") else { return }
        o.wake.locked = true; o.model.suspend(.screenLock)
        try await run(o, 0.2)
        let watch = Watch(o.model)
        Seams.blipUntil = Date().addingTimeInterval(w)
        o.wake.locked = false; o.model.unsuspend(.screenLock)
        try await run(o, w + 3.2)
        let spans = watch.end()
        check(spans.isEmpty, "D-unlock", "\(before.rawValue) before the lock, off for \(ms(w)) as the screen unlocks: \(Watch.describe(spans))")
        if before == .recording {
            check(o.model.recording && o.notices.posted.isEmpty, "D-unlock", "…and recording came back by itself, nothing said: \(o.model.recordingState), notices \(o.notices.posted.map(\.body))")
        }
        try await close(o)
    }

    // MARK: E. Really off

    static func reallyOff(_ situation: Situation) async throws {
        guard let o = try await ready(situation, "off-\(situation.rawValue)") else { return }
        let watch = Watch(o.model)
        let t0 = Date()
        Seams.granted = false
        // Turned off in System Settings; the person comes back to DayDream (while recording, the heartbeat reads anyway).
        o.model.refreshCaptureStatus()
        try await run(o, 3.2) { Shown.surfaces(o.model).contains("state") }
        let after = Date().timeIntervalSince(t0)
        let state = o.model.recordingState
        _ = watch.end()
        check(state.kind == .needsPermission && after <= 2.5, "E-off", "\(situation.rawValue), a permission really turned off: Needs Permission shows after \(Int(after * 1000)) ms: \(state)")
        if case .needsPermission(let missing) = state {
            check(missing == [.accessibility, .inputMonitoring], "E-off", "…and it names what is off: \(missing.map(\.title).sorted())")
        }
        // Turned on again: the state follows at the next read.
        Seams.granted = true
        o.model.refreshCaptureStatus()
        try await run(o, 0.1)
        check(o.model.recordingState.kind != .needsPermission && Shown.surfaces(o.model).isEmpty, "E-off", "…and turned on again, the next read shows it: \(o.model.recordingState) \(Shown.surfaces(o.model).sorted())")
        try await close(o)
    }
    static func reallyOffAtLaunch(resumes: Bool) async throws {
        Seams.granted = false
        let t0 = Date()
        let o = try await open("off-launch-\(resumes)", intent: resumes ? suite(["recording": true]) : nil, settle: false)
        try await run(o, 3.2) { Shown.surfaces(o.model).contains("state") }
        let after = Date().timeIntervalSince(t0)
        check(o.model.recordingState.kind == .needsPermission && after <= 2.5, "E-off-launch",
              "launch with \(resumes ? "recording to resume" : "nothing to resume"), a permission really off: Needs Permission shows after \(Int(after * 1000)) ms: \(o.model.recordingState)")
        try await close(o)
    }
    static func reallyOffAtUnlock() async throws {
        guard let o = try await ready(.recording, "off-unlock") else { return }
        o.wake.locked = true; o.model.suspend(.screenLock)
        try await run(o, 0.2)
        Seams.granted = false
        let t0 = Date()
        o.wake.locked = false; o.model.unsuspend(.screenLock)
        try await run(o, 9) { !o.notices.posted.isEmpty && Shown.surfaces(o.model).contains("state") }
        let after = Date().timeIntervalSince(t0)
        check(o.model.recordingState.kind == .needsPermission && o.notices.posted.count == 1, "E-off-unlock",
              "recording before the lock, a permission really off at the unlock: Needs Permission and its one notice after \(Int(after * 1000)) ms: \(o.model.recordingState), notices \(o.notices.posted.count)")
        try await close(o)
    }

    // MARK: F. The person's own Start

    static func personStart() async throws {
        let o = try await open("person")
        Seams.blipUntil = Date().addingTimeInterval(0.2)
        o.model.startCapture()
        check(!o.model.recording && o.model.recordingState.kind == .needsPermission, "F-person",
              "the person's own Start takes its read as it is: Needs Permission at once: \(o.model.recordingState)")
        try await run(o, 3)
        check(o.model.recordingState.kind != .needsPermission && !o.model.recording && Shown.surfaces(o.model).isEmpty, "F-person",
              "…and with both on again the state follows the reads; nothing started behind it: \(o.model.recordingState) \(Shown.surfaces(o.model).sorted())")
        try await close(o)
    }
}

// MARK: G. The rule

extension PermissionFlashChecks {
    static func rule() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
        // Allowed before: an off read holds only once the reads have stayed off for `settle`.
        var p = PermissionSettle(shown: true)
        check(p.read(false, at: at(0)) == true && p.unsettled, "G-rule", "known allowed, one off read: still shows allowed, and waits")
        check(p.read(false, at: at(1.4)) == true, "G-rule", "…off again 1.4 s later: still allowed")
        check(p.read(false, at: at(1.5)) == false && !p.unsettled, "G-rule", "…off again at \(PermissionSettle.settle) s: shows off, settled")
        check(p.read(false, at: at(9)) == false, "G-rule", "…and stays off while the reads say so")
        check(p.read(true, at: at(10)) == true, "G-rule", "…an on read shows at once")
        // An on read in between starts the wait over.
        p = PermissionSettle(shown: true)
        _ = p.read(false, at: at(0)); _ = p.read(false, at: at(1.0)); _ = p.read(true, at: at(1.2)); _ = p.read(false, at: at(1.4))
        check(p.read(false, at: at(2.8)) == true, "G-rule", "an on read between off reads starts the wait over: 1.4 s after it, still allowed")
        check(p.read(false, at: at(2.9)) == false, "G-rule", "…1.5 s after it: off")
        // Nothing known yet, allowed before (setup finished): nil until a read says on or the off reads hold.
        p = PermissionSettle()
        check(p.read(false, at: at(0)) == nil && p.unsettled, "G-rule", "nothing known, allowed before, off read: still nothing shown (never off at once)")
        check(p.read(false, at: at(1.5)) == false, "G-rule", "…held for \(PermissionSettle.settle) s: off")
        p = PermissionSettle()
        check(p.read(true, at: at(0)) == true, "G-rule", "nothing known, on read: allowed at once")
        // Never allowed (a first setup): the first off read is the answer, and only an on read changes the rule.
        p = PermissionSettle(allowedBefore: false)
        check(p.read(false, at: at(0)) == false, "G-rule", "never allowed, off read: off at once")
        _ = p.read(true, at: at(1))
        check(p.read(false, at: at(2)) == true && p.read(false, at: at(3.6)) == false, "G-rule", "…allowed once: an off read then waits \(PermissionSettle.settle) s like everyone's")
        // Reads that don't count (asleep, locked), interruptions and the person's own Start.
        p = PermissionSettle(shown: true)
        _ = p.read(false, at: at(0))
        check(p.read(false, at: at(0.5), counts: false) == true && !p.unsettled, "G-rule", "a read that doesn't count (asleep, locked) says nothing and ends the wait")
        _ = p.read(false, at: at(1)); p.interrupted()
        check(!p.unsettled && p.read(false, at: at(2.4)) == true, "G-rule", "a sleep or lock interrupting the wait: the off read before it holds nothing after")
        p.take(false)
        check(p.shown == false, "G-rule", "the person's own Start read off: off at once")
        p.take(true)
        check(p.shown == true, "G-rule", "…and read on: on at once")
        // After a wake: longer.
        p = PermissionSettle(shown: true)
        _ = p.read(false, at: at(0), settle: PermissionSettle.settleAfterWake)
        check(p.read(false, at: at(3.0), settle: PermissionSettle.settleAfterWake) == true, "G-rule", "after a wake a 3 s off still shows allowed")
        check(p.read(false, at: at(4.0), settle: PermissionSettle.settleAfterWake) == false, "G-rule", "…and holds at \(PermissionSettle.settleAfterWake) s")
        check(PermissionSettle.settle > 1.2 && PermissionSettle.settle <= 2 && PermissionSettle.settleAfterWake > 3 && PermissionSettle.settleAfterWake <= MemoryViewModel.permissionHoldQuiet,
              "G-rule", "the settle times cover the blips the checks model (1.2 s; 3 s after an unlock) and a real off still shows within 2 s (4 s after a wake, when the held start says so too)")
        // Both permissions.
        var both = ShownPermissions(known: PermissionSnapshot(accessibility: true, inputMonitoring: true))
        check(both.read(PermissionSnapshot(accessibility: true, inputMonitoring: false), at: at(0)).allGranted == true && both.unsettled, "G-rule", "both: one reads off, both still show allowed")
        check(both.read(PermissionSnapshot(accessibility: nil, inputMonitoring: false), at: at(1.6)).missing == [.inputMonitoring], "G-rule", "…held: that one shows off; a nil read leaves the other as it was")
        check(both.take(PermissionSnapshot(accessibility: false, inputMonitoring: true)).missing == [.accessibility], "G-rule", "…taken as read: both follow at once")
    }
}

// MARK: H. The permission page and setup

extension PermissionFlashChecks {
    /// A hidden window hosting `view`; never ordered on screen.
    static func host<V: View>(_ view: V, size: NSSize = NSSize(width: 660, height: 600)) -> (NSWindow, NSHostingView<V>) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }
    /// The permission cards' own reads (Settings › Permissions, the permissions window, setup's page), hosted hidden with
    /// the seam reads: an Allowed card never becomes its Open System Settings button over a blip; a first setup's card
    /// reads off at once; a real off shows within the settle.
    static func pageReads() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        final class Page { var on = true; var reads = 0; var reported: [(Date, Bool, Bool)] = [] }
        let page = Page()
        let view = PermissionGrantView(enabled: true, appURL: URL(fileURLWithPath: "/Applications/DayDream.app"),
                                       readAccessibility: { page.reads += 1; return page.on }, readInputMonitoring: { page.on },
                                       embedded: true, known: PermissionSnapshot(accessibility: true, inputMonitoring: true), allowedBefore: true,
                                       onStatusChange: { page.reported.append((Date(), $0, $1)) })
        let (window, _) = host(view)
        defer { window.contentView = nil }
        let end = Date().addingTimeInterval(3)
        while page.reported.isEmpty, Date() < end { try await tick(0.02) }
        check(page.reported.last.map { $0.1 && $0.2 } == true, "H-page", "the page opened on what the app showed (both allowed), and its first read agreed: \(page.reported.count) reports")
        for w in blips {
            page.reported = []
            page.on = false
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp) // its activation read
            try await tick(w)
            page.on = true
            try await tick(2.2) // past its 2 s timer read and the settle read
            let off = page.reported.filter { !$0.1 || !$0.2 }
            check(off.isEmpty && !page.reported.isEmpty, "H-page", "the page's reads off for \(ms(w)): its cards never say not allowed (\(page.reported.count) reads, \(off.count) off)")
        }
        // Really off: shown within the settle (its own read again, before its 2 s timer), both cards.
        page.reported = []
        let t0 = Date()
        page.on = false
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        let until = Date().addingTimeInterval(3)
        while !page.reported.contains(where: { !$0.1 }), Date() < until { try await tick(0.02) }
        let shownAt = page.reported.first { !$0.1 }?.0.timeIntervalSince(t0)
        check(shownAt.map { $0 <= 2.0 } == true, "H-page", "a permission really turned off: the cards show it after \(shownAt.map { Int($0 * 1000) } ?? -1) ms")
        page.on = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try await tick(0.1)
        check(page.reported.last.map { $0.1 && $0.2 } == true, "H-page", "…and allowed again shows at once")
        check(!window.isVisible, "H-page", "the hosting window was never shown")
        // A first setup (never allowed): the first off read shows at once, so the page says what to allow with no wait.
        final class Fresh { var reported: [(Bool, Bool)] = [] }
        let fresh = Fresh()
        let first = PermissionGrantView(enabled: true, appURL: URL(fileURLWithPath: "/Applications/DayDream.app"),
                                        readAccessibility: { false }, readInputMonitoring: { false }, embedded: true,
                                        onStatusChange: { fresh.reported.append(($0, $1)) })
        let (window2, _) = host(first)
        defer { window2.contentView = nil }
        let end2 = Date().addingTimeInterval(2)
        while fresh.reported.isEmpty, Date() < end2 { try await tick(0.02) }
        check(fresh.reported.first.map { !$0.0 && !$0.1 } == true, "H-page", "a first setup's page: the first off read shows at once: \(fresh.reported)")
    }
    /// Setup opens with both permissions allowed (setup finished before): the page drawn is never Permissions, even when
    /// its first reads fall in a blip of `blip` seconds.
    static func setupOpens(blip: Double) async throws {
        let o = try await open("setup-\(Int(blip * 1000))")
        o.model.chromeAccessEnvironment = ChromeAccessEnvironment(running: { nil }, verify: { _ in false }, status: { _ in 0 }, ask: { _ in 0 },
                                                                  background: { $0() }, main: { $0() })
        check(o.model.permissionSnapshot.allGranted == true, "harness", "setup-\(Int(blip * 1000)): the app shows both allowed before setup opens")
        let until = Date().addingTimeInterval(blip)
        DaydreamOnboarding.readPermissions = { let on = Date() >= until; return (on, on) }
        defer { DaydreamOnboarding.readPermissions = { let on = Seams.read(); return (on, on) } }
        DaydreamOnboarding.drawnPagesForChecks = []
        let (window, _) = host(DaydreamOnboarding(model: o.model))
        try await run(o, blip + 2.3)
        let pages = DaydreamOnboarding.drawnPagesForChecks
        check(!pages.isEmpty && !pages.contains(.permissions) && pages.last != nil, "H-setup",
              "setup opens (both allowed, its first reads off for \(ms(blip))): Permissions is never drawn, and a page is: \(pages.map { $0.map(String.init(describing:)) ?? "none" })")
        check(!window.isVisible, "H-setup", "the hosting window was never shown")
        window.contentView = nil
        try await close(o)
    }
    /// Setup opens with a permission really off (setup finished before): the app already shows it, so Permissions is the
    /// first page drawn, with no other page first. And the race: the permission goes off as setup opens while the app
    /// still shows it allowed, so setup draws no page until its off reads have held, then Permissions (never Summaries).
    /// int-015 (coordinator 10/05): a brand-new user. Setup was never finished, so neither the model nor setup holds an
    /// off read: setup draws Permissions within a frame or two, never a blank window for the settle (1.5 s) or longer.
    static func newInstallSetup() async throws {
        UserDefaults.standard.set(false, forKey: MemoryViewModel.setupCompletedKey)   // scratch HOME; removed below
        defer { UserDefaults.standard.removeObject(forKey: MemoryViewModel.setupCompletedKey) }
        Seams.granted = false
        let o = try await open("setup-new")
        o.model.chromeAccessEnvironment = ChromeAccessEnvironment(running: { nil }, verify: { _ in false }, status: { _ in 0 }, ask: { _ in 0 },
                                                                  background: { $0() }, main: { $0() })
        check(!o.model.permissionsAllowedBefore, "harness", "setup-new: setup was never finished")
        DaydreamOnboarding.drawnPagesForChecks = []
        let t0 = Date()
        let (window, _) = host(DaydreamOnboarding(model: o.model))
        try await run(o, 2.5) { DaydreamOnboarding.drawnPagesForChecks.last == .permissions }
        let after = Date().timeIntervalSince(t0)
        let pages = DaydreamOnboarding.drawnPagesForChecks
        let blank = pages.prefix { $0 == nil }.count
        check(pages.last == .permissions && after <= 0.3 && blank <= 1 && pages.allSatisfy { $0 == nil || $0 == .permissions }, "I-new",
              "a brand-new install: setup draws Permissions after \(Int(after * 1000)) ms (\(blank) blank draw(s) first), no other page: \(pages.map { $0.map(String.init(describing:)) ?? "none" })")
        check(!window.isVisible, "I-new", "the hosting window was never shown")
        window.contentView = nil
        try await close(o)
    }
    static func setupOpensReallyOff() async throws {
        let o = try await open("setup-off")
        o.model.chromeAccessEnvironment = ChromeAccessEnvironment(running: { nil }, verify: { _ in false }, status: { _ in 0 }, ask: { _ in 0 },
                                                                  background: { $0() }, main: { $0() })
        Seams.granted = false
        o.model.refreshCaptureStatus()
        try await run(o, 2.5) { o.model.permissionSnapshot.missing.count == 2 }
        check(o.model.permissionSnapshot.missing.count == 2, "harness", "setup-off: the app shows both off before setup opens")
        DaydreamOnboarding.drawnPagesForChecks = []
        let t0 = Date()
        let (window, _) = host(DaydreamOnboarding(model: o.model))
        try await run(o, 2.5) { DaydreamOnboarding.drawnPagesForChecks.last == .permissions }
        let after = Date().timeIntervalSince(t0)
        let pages = DaydreamOnboarding.drawnPagesForChecks
        check(pages.last == .permissions && after <= 1 && pages.allSatisfy { $0 == nil || $0 == .permissions }, "H-setup",
              "setup opens with a permission really off: Permissions after \(Int(after * 1000)) ms, no other page first: \(pages.map { $0.map(String.init(describing:)) ?? "none" })")
        window.contentView = nil
        try await close(o)
        // The race.
        let r = try await open("setup-off-race")
        r.model.chromeAccessEnvironment = ChromeAccessEnvironment(running: { nil }, verify: { _ in false }, status: { _ in 0 }, ask: { _ in 0 },
                                                                  background: { $0() }, main: { $0() })
        Seams.granted = false
        DaydreamOnboarding.drawnPagesForChecks = []
        let t1 = Date()
        let (window2, _) = host(DaydreamOnboarding(model: r.model))
        try await run(r, 5) { DaydreamOnboarding.drawnPagesForChecks.last == .permissions }
        let after2 = Date().timeIntervalSince(t1)
        let pages2 = DaydreamOnboarding.drawnPagesForChecks
        check(pages2.last == .permissions && after2 <= 2.5 && pages2.allSatisfy { $0 == nil || $0 == .permissions }, "H-setup",
              "a permission goes off as setup opens: no page until its off reads hold, then Permissions after \(Int(after2 * 1000)) ms, no other page first: \(pages2.map { $0.map(String.init(describing:)) ?? "none" })")
        window2.contentView = nil
        try await close(r)
    }
}
