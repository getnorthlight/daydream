// DD-RECIPE: APP
// One DayDream at a time (gold r2, OtherCopy.swift), with a fake for the other running copy: nothing here looks for,
// opens, activates or quits a real app, and no process exits. The rest is the REAL launch router and MemoryViewModel
// with the check seams (run-checks.sh sets a synthetic HOME and CFFIXED_USER_HOME); nothing records.
//   A. A second copy finds the running one: that one is brought forward and this one leaves before it moves, opens or
//      saves anything (no model, no history file, no recorder lock). No message.
//   B. The running copy can't be reached: this copy opens, and (the lock held) says only "DayDream is already open.",
//      in the window too: that line alone, with no "Activity could not be loaded" and no Try again (review round 1).
//   C. The download window: a copy there hands off to the running one; a copy that can record opens instead of handing
//      off to a copy in the download window, waits for it quietly (no line), and opens the history once it lets go. The
//      download-window copy steps aside for a copy that can record, and only for one.
//   D. (gold/int round 2) Launch prepared the history before the download-window copy's model existed (a time index to
//      build, off the main thread): a copy that can record opened meanwhile is stepped aside for once the model exists.
// Before this (a6944d3) there was no hand-off: every second copy opened and said "Another copy of DayDream is open.
// Quit it, then open this one."
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

/// Launch-intent defaults kept in memory only (no suite, nothing reaches cfprefsd), as the app has its own: a Start
/// pressed while the history is still opening is kept there until it opens.
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

/// The other copy, as the fake sees it, and what this copy did about it.
@MainActor final class FakeOther {
    var running: OtherCopy.Running?
    var reachable = true
    var broughtForward: [OtherCopy.Running] = []
    var left = 0, steppedAside = 0
    /// A copy opened after this one (where it runs from), as the model asks when it is made.
    var later: LaunchLocation?
    var seam: OtherCopy {
        OtherCopy(find: { MainActor.assumeIsolated { self.running } },
                  bringForward: { other in MainActor.assumeIsolated { self.broughtForward.append(other); return self.reachable } },
                  leave: { MainActor.assumeIsolated { self.left += 1 } },
                  stepAside: { MainActor.assumeIsolated { self.steppedAside += 1 } },
                  openedLater: { MainActor.assumeIsolated { self.later } })
    }
}

@main @MainActor struct SingleCopyChecks {
    static var out = URL(fileURLWithPath: "/")
    static let la = TimeZone(identifier: "America/Los_Angeles")!

    static func main() async throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
            FileHandle.standardError.write(Data("FAIL: single-copy-checks watchdog expired after 180s\n".utf8)); exit(2)
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
        out = URL(fileURLWithPath: outPath, isDirectory: true).appendingPathComponent("single-copy", isDirectory: true)
        try makePrivateDirectory(out)
        MemoryViewModel.permissionsGranted = { true }
        MemoryViewModel.permissionRead = { PermissionSnapshot(accessibility: true, inputMonitoring: true) }
        MemoryViewModel.startInput = { _ in true }
        MemoryViewModel.readLaunchLocation = { .applications }
        MemoryViewModel.canReopen = { true }
        UserDefaults.standard.register(defaults: [MemoryViewModel.setupCompletedKey: true])
        check(OtherCopy.current.find() == nil && !OtherCopy.current.bringForward(OtherCopy.Running(pid: 1, bundleURL: nil, location: .applications)),
              "seam", "check builds find no other copy and reach none (the inert seam)")
        let source = (try? String(contentsOfFile: "Sources/MacMemApp/OtherCopy.swift", encoding: .utf8)) ?? ""
        check(source.contains("#if DEVELOPMENT_SOURCE_CHECKS\n    static var current = OtherCopy.inert\n    #else\n    static var current = OtherCopy.live\n    #endif"),
              "seam", "only the app looks for a real copy")
        check(!source.contains("NSAppleEventDescriptor") && !source.contains("AESend") && !source.contains("terminate()")
              && source.contains("createsNewApplicationInstance") == false && source.contains("answer == other.pid"),
              "seam", "the live hand-off sends no Apple Event, quits nobody, and counts a newly started copy as not reached")

        decisions()
        try await handsOff()
        try await unreachable()
        try await downloadWindowHandsOff()
        try await stepsAsideQuietly()
        try await stepAsideRule()
        try await stepsAsideAfterPreparing()

        print("single-copy: \(Report.passed) passed, \(Report.failed) failed")
        fflush(stdout)
        exit(Report.failed == 0 ? 0 : 1)
    }

    static func home(_ name: String) throws -> URL {
        let memory = out.appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        try makePrivateDirectory(memory)
        setenv("MAC_MEM_HOME", memory.path, 1)
        return memory
    }
    static func running(_ location: LaunchLocation) -> OtherCopy.Running {
        OtherCopy.Running(pid: 4242, bundleURL: URL(fileURLWithPath: "/Applications/DayDream.app"), location: location)
    }
    static func files(_ memory: URL) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: memory.path)) ?? [] }

    static func decisions() {
        check(OtherCopy.decide(mine: .applications, other: nil) == .open, "decide", "no other copy: open")
        check(OtherCopy.decide(mine: .applications, other: running(.applications)) == .handOff, "decide", "another copy in Applications: hand off")
        check(OtherCopy.decide(mine: .elsewhere, other: running(.applications)) == .handOff, "decide", "a copy elsewhere, another running: hand off")
        check(OtherCopy.decide(mine: .diskImage, other: running(.applications)) == .handOff
              && OtherCopy.decide(mine: .translocated, other: running(.elsewhere)) == .handOff, "decide", "a copy in the download window: hand off")
        check(OtherCopy.decide(mine: .applications, other: running(.diskImage)) == .open
              && OtherCopy.decide(mine: .applications, other: running(.translocated)) == .open, "decide",
              "a copy that can record doesn't hand off to one in the download window")
        check(OtherCopy.decide(mine: .diskImage, other: running(.diskImage)) == .handOff, "decide", "two in the download window: the second hands off")
    }

    static func handsOff() async throws {
        let fake = FakeOther(); fake.running = running(.applications)
        OtherCopy.current = fake.seam
        defer { OtherCopy.current = .inert }
        let memory = try home("hand-off")
        let session = DaydreamLaunchSession(arguments: ["DayDream"])
        check(fake.broughtForward == [running(.applications)] && fake.left == 1, "hand-off",
              "a second copy brings the running one forward and leaves: forward \(fake.broughtForward.count), left \(fake.left)")
        check(session.model == nil && session.failure == nil, "hand-off", "…having made no model and shown no message")
        try await tick(0.3)
        check(files(memory).isEmpty, "hand-off", "…and before it opened or wrote anything (no history, no recorder lock): \(files(memory))")
        let trial = DaydreamLaunchSession(arguments: ["DayDream", "--isolated-interactive-trial"])
        #if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
        check(trial.isolated && trial.model == nil && fake.broughtForward.count == 1 && fake.left == 1, "hand-off", "the explicit QA isolated trial never hands off")
        #else
        // c92de61: a normal build ignores QA-only arguments and still enforces one copy.
        check(!trial.isolated && trial.model == nil && fake.broughtForward.count == 2 && fake.left == 2, "hand-off", "normal builds ignore the QA isolated argument and hand off")
        #endif
    }

    static func unreachable() async throws {
        let fake = FakeOther(); fake.running = running(.applications); fake.reachable = false
        OtherCopy.current = fake.seam
        defer { OtherCopy.current = .inert }
        let memory = try home("unreachable")
        let fd = Darwin.open(memory.appendingPathComponent("capture.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { check(false, "harness", "unreachable: the lock could not be taken"); return }
        let session = DaydreamLaunchSession(arguments: ["DayDream"])
        guard let model = session.model else { check(false, "unreachable", "a copy that couldn't reach the running one opens"); close(fd); return }
        check(fake.broughtForward.count == 1 && fake.left == 0, "unreachable", "the running copy couldn't be reached: this one stays")
        try await tick(0.2)
        var line = ""
        if case .off(_, let reason) = model.recordingState { line = reason ?? "" }
        let header = MenuBarMenu.header(model.presentation, now: Date(), timeZone: la, canSetUp: true, canOpenApplications: false)
        check(model.anotherCopyOpen && line == RecordingCopy.anotherCopy && line == "DayDream is already open.", "unreachable",
              "…with one short line: \"\(line)\"")
        check(header.status.text == "DayDream is already open" && header.status.detail == nil && header.control == .toggle(on: false, enabled: false), "unreachable",
              "…the menu says only that, with nothing to press: \(header.status.text) / \(header.control)")
        window(model, "unreachable")
        close(fd)
        _ = try await waitFor(6) { model.historyStoreID != nil }
        check(!model.anotherCopyOpen && model.historyStoreID != nil && model.resumeUnavailable == nil, "unreachable",
              "…and it clears itself: the history opens once the other copy lets go: \(model.recordingState)")
    }

    /// The window (ActivityTimelineView draws exactly `stateContent`) while another copy holds the history: the one line,
    /// no title, nothing to press. Try again there called `refresh`, which does nothing while another copy has the history.
    static func window(_ model: MemoryViewModel, _ id: String) {
        let shown = ActivityTimelineView.stateContent(model.activity.phase)
        check(shown == ActivityTimelineView.StateContent(title: nil, line: RecordingCopy.anotherCopy, retry: false), id,
              "…the window shows only that line, with no title and nothing to press: \(String(describing: shown))")
        let failed = ActivityTimelineView.stateContent(.failed("Local activity could not be read. Try again."))
        check(failed?.title != nil && failed?.retry == true, id, "…(a read that failed still has its title and Try again: \(String(describing: failed)))")
    }

    static func downloadWindowHandsOff() async throws {
        let fake = FakeOther(); fake.running = running(.applications)
        OtherCopy.current = fake.seam
        MemoryViewModel.readLaunchLocation = { .diskImage }
        defer { OtherCopy.current = .inert; MemoryViewModel.readLaunchLocation = { .applications } }
        let memory = try home("download-hand-off")
        let session = DaydreamLaunchSession(arguments: ["DayDream"])
        check(session.model == nil && fake.left == 1 && files(memory).isEmpty, "download", "a copy opened from the download window hands off to the running one")
    }

    static func stepsAsideQuietly() async throws {
        let fake = FakeOther(); fake.running = running(.diskImage)
        OtherCopy.current = fake.seam
        defer { OtherCopy.current = .inert }
        let memory = try home("steps-aside")
        let fd = Darwin.open(memory.appendingPathComponent("capture.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { check(false, "harness", "steps-aside: the lock could not be taken"); return }
        let session = DaydreamLaunchSession(arguments: ["DayDream"])
        guard let model = session.model else { check(false, "download", "a copy in Applications opens while one in the download window runs"); close(fd); return }
        check(fake.left == 0 && fake.broughtForward.isEmpty, "download", "a copy in Applications doesn't hand off to one in the download window")
        var loud = false
        let release = Date().addingTimeInterval(1.5)
        while Date() < release {
            if model.anotherCopyOpen || model.resumeUnavailable != nil || model.presentation.issue != nil || model.recordingState != .off(since: nil, reason: nil) { loud = true }
            try await tick(0.05)
        }
        check(!loud && model.historyOpening, "download", "…it waits for that copy to step aside with no line: \(model.recordingState)")
        close(fd) // the download-window copy quit
        _ = try await waitFor(6) { model.historyStoreID != nil }
        check(model.historyStoreID != nil && !model.historyOpening && !model.anotherCopyOpen && model.resumeUnavailable == nil, "download",
              "…and opens the history once it has: \(model.recordingState)")
        model.requestStart(openSetup: {})
        check(model.recording, "download", "…and Start records")
        model.stopCapture()

        // Start pressed during the quiet wait (review round 1): nothing failed to save, so nothing says so. The app's own
        // launch-intent defaults (in memory here) keep that Start until the history opens.
        MemoryViewModel.launchIntentDefaults = MemoryDefaults()
        defer { MemoryViewModel.launchIntentDefaults = nil }
        let pressed = try home("start-while-stepping-aside")
        let fd3 = Darwin.open(pressed.appendingPathComponent("capture.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd3 >= 0, flock(fd3, LOCK_EX | LOCK_NB) == 0 else { check(false, "harness", "start-while-stepping-aside: the lock could not be taken"); return }
        let third = DaydreamLaunchSession(arguments: ["DayDream"])
        guard let starter = third.model else { check(false, "download", "the copy in Applications opens"); close(fd3); return }
        // An unlocked screen (this check must not read the live lock state, which decides whether a launch start waits).
        starter.wakeSystem = WakeSystem(screenLocked: { false }, onConsole: { true },
                                        after: { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }, now: { Date() })
        try await tick(0.3)
        starter.requestStart(openSetup: {})
        var lines: [String] = []
        let watch = Date().addingTimeInterval(1.5)
        while Date() < watch {
            let h = MenuBarMenu.header(starter.presentation, now: Date(), timeZone: la, canSetUp: true, canOpenApplications: false)
            let line = "\(starter.recordingState) \(h.status.text) \(h.status.detail ?? "")"
            if lines.last != line { lines.append(line) }
            try await tick(0.1)
        }
        check(!lines.contains { $0.contains(RecordingCopy.savingRetry) || $0.localizedCaseInsensitiveContains("save") } && starter.presentation.issue == nil, "download",
              "Start during the quiet wait: no surface says a save failed (nothing did): \(lines)")
        close(fd3)
        _ = try await waitFor(6) { starter.recording }
        check(starter.recording, "download", "…and once that copy has quit, the person's Start records: \(starter.recordingState)")
        starter.stopCapture()

        // A copy that never steps aside (an older build): after the grace, the one short line, which clears itself.
        let slow = try home("never-steps-aside")
        let fd2 = Darwin.open(slow.appendingPathComponent("capture.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd2 >= 0, flock(fd2, LOCK_EX | LOCK_NB) == 0 else { check(false, "harness", "never-steps-aside: the lock could not be taken"); return }
        let later = DaydreamLaunchSession(arguments: ["DayDream"])
        guard let waiting = later.model else { check(false, "download", "the second copy opens"); close(fd2); return }
        _ = try await waitFor(MemoryViewModel.anotherCopyGrace + 4) { waiting.anotherCopyOpen }
        var line = ""
        if case .off(_, let reason) = waiting.recordingState { line = reason ?? "" }
        check(waiting.anotherCopyOpen && line == RecordingCopy.anotherCopy, "download",
              "a download-window copy that doesn't step aside: after \(Int(MemoryViewModel.anotherCopyGrace)) s the one short line: \"\(line)\"")
        window(waiting, "download")
        close(fd2)
        _ = try await waitFor(6) { waiting.historyStoreID != nil }
        check(waiting.historyStoreID != nil && !waiting.anotherCopyOpen, "download", "…and it clears itself once that copy quits")
    }

    static func stepAsideRule() async throws {
        let fake = FakeOther()
        OtherCopy.current = fake.seam
        MemoryViewModel.readLaunchLocation = { .diskImage }
        defer { OtherCopy.current = .inert; MemoryViewModel.readLaunchLocation = { .applications } }
        _ = try home("download-copy")
        let session = DaydreamLaunchSession(arguments: ["DayDream"])
        guard let model = session.model else { check(false, "step-aside", "the download-window copy opens (nothing else runs)"); return }
        _ = try await waitFor(3) { !model.history.busy }
        model.otherCopyOpened(.diskImage)
        model.otherCopyOpened(.translocated)
        model.otherCopyOpened(.notAnApp)
        check(fake.steppedAside == 0, "step-aside", "a download-window copy doesn't step aside for another download-window copy (or a tool)")
        model.history.busy = true
        model.otherCopyOpened(.applications)
        check(fake.steppedAside == 0, "step-aside", "…nor while an import runs in it")
        model.history.busy = false
        model.launchWarningPresented = true
        model.otherCopyOpened(.applications)
        check(fake.steppedAside == 1 && !model.launchWarningPresented, "step-aside",
              "it steps aside (quits) for a copy that can record, closing its own alert first")
        MemoryViewModel.readLaunchLocation = { .applications }
        _ = try home("applications-copy")
        let installed = MemoryViewModel()
        _ = try await waitFor(3) { !installed.history.busy }
        installed.otherCopyOpened(.applications)
        installed.otherCopyOpened(.diskImage)
        check(fake.steppedAside == 1, "step-aside", "a copy that can record never steps aside")
    }
    /// D (gold/int round 2). Launch prepares the history off the main thread before the model exists when it has long
    /// work (here: a time index an earlier version never built), so the download-window copy's watch for a copy that can
    /// record (`otherCopyOpened`, made with the model) wasn't there yet. A copy opened from Applications meanwhile found
    /// this one first and waited for its lock: before this, this copy stayed and held the history, and that copy said
    /// "DayDream is already open." until someone quit this one. Now the model, once made, steps aside for it.
    static func stepsAsideAfterPreparing() async throws {
        let fake = FakeOther()
        OtherCopy.current = fake.seam
        defer { OtherCopy.current = .inert; MemoryViewModel.readLaunchLocation = { .applications } }
        let memory = try home("prepared-download-copy")
        var first: MemoryViewModel? = MemoryViewModel()
        _ = try await waitFor(3) { first?.history.busy == false }
        check(first?.historyStoreID != nil, "harness", "prepared-later: the history was made")
        first = nil
        try await tick(0.3)
        var db: OpaquePointer?
        sqlite3_open_v2(memory.appendingPathComponent("memory.sqlite").path, &db, SQLITE_OPEN_READWRITE, nil)
        sqlite3_exec(db, "DROP INDEX records_at", nil, nil, nil)
        sqlite3_close(db)
        check(HistoryPreparation.needed(home: memory), "harness", "prepared-later: launch has a time index to build")

        MemoryViewModel.readLaunchLocation = { .diskImage }
        let session = DaydreamLaunchSession(arguments: ["DayDream"])
        check(session.preparing && session.model == nil, "harness", "prepared-later: launch prepares the history before the model exists")
        fake.later = .applications
        _ = try await waitFor(15) { session.model != nil }
        _ = try await waitFor(3) { fake.steppedAside > 0 }
        check(session.model != nil && fake.steppedAside == 1, "prepared-later",
              "a download-window copy steps aside for a copy that can record opened while launch prepared its history (was: it stayed; that copy said \"DayDream is already open.\" until this one was quit)")

        // Only for a copy that can record, only from a copy in the download window, and never at an ordinary launch.
        var before = fake.steppedAside
        fake.later = .diskImage
        _ = try home("prepared-later-other")
        let other = MemoryViewModel()
        fake.later = nil
        _ = try home("prepared-later-alone")
        let alone = MemoryViewModel()
        MemoryViewModel.readLaunchLocation = { .applications }
        fake.later = .applications
        _ = try home("prepared-later-installed")
        let installed = MemoryViewModel()
        try await tick(MemoryViewModel.anotherCopyRecheck + 0.5)
        check(fake.steppedAside == before, "prepared-later",
              "…not for another download-window copy, not when none opened, and a copy that can record never steps aside")

        // A copy that can record opening during an import here: not then, but once the import ends (it asks again while
        // that copy runs). Was: never, and that copy said "DayDream is already open." until this one was quit.
        MemoryViewModel.readLaunchLocation = { .diskImage }
        fake.later = nil
        _ = try home("prepared-later-import")
        let importing = MemoryViewModel()
        _ = try await waitFor(3) { !importing.history.busy }
        before = fake.steppedAside
        importing.history.busy = true
        fake.later = .applications
        importing.otherCopyOpened(.applications)
        try await tick(MemoryViewModel.anotherCopyRecheck + 0.5)
        check(fake.steppedAside == before, "prepared-later", "a download-window copy doesn't step aside while an import runs in it")
        importing.history.busy = false
        _ = try await waitFor(MemoryViewModel.anotherCopyRecheck * 2 + 1) { fake.steppedAside == before + 1 }
        check(fake.steppedAside == before + 1, "prepared-later", "…and steps aside once it ends, while that copy still runs")
        fake.later = nil
        _ = (other, alone, installed, importing)
    }
}
