// DD-RECIPE: APP
// Test 5 lifecycle (gold/lifecycle), on the REAL MemoryViewModel: every model opens a private history under
// DD_CHECK_OUT, in a synthetic home (HOME and CFFIXED_USER_HOME, set by run-checks.sh). The check builds' seams stand in
// for macOS: in-memory typing keys (MemoryViewModel.typedKeyStore), an input start that installs no event tap
// (startInput), permission reads (permissionsGranted, permissionRead), a login item that records calls and registers
// nothing (loginItem), the launch intent in private defaults suites (launchIntentDefaults), fake lock and console reads
// (wakeSystem) and a fake notice center. Nothing records: a "recording" session here is a row in the private store; no
// event tap, Accessibility read, Keychain item, login item, notification or Apple Event is ever used.
//   A. [Extra 1, G10] An update relaunch records again (the launch-time history read holds nothing back), no latched line.
//   B. [G10] Recording that was on when DayDream crashed, quit or the Mac restarted starts again at launch; the person's
//      Stop clears that, and a timed pause saves its end.
//   C. [G42] A timed pause running when DayDream quit is picked up until the same time, and records at its end; one
//      that ended meanwhile records at once. A launch that can't record gives one notice and never tries again.
//   D. [Extra 2, lock-fix nit, G35] An import running at unlock (or when a save retry is due) holds the start, with no
//      latched line and no counted failure, and recording starts when it ends. Behind the lock screen the state is Paused.
//   E. [Extra 4] A restore preview that ran out while DayDream was closed is closed at launch; one still waiting is a
//      blocker with its own line and one notice that names Review…, and it clears itself when the preview closes.
//   F. [Extra 3] A replacement read that fails for a moment doesn't end a timed pause or read as a replacement to review.
//   G. [G4] A failed delete or summary job never cancels a timed pause; each line clears once the next one works.
//   H. [G36, G56] Keyboard and mouse that couldn't start latch no line; a wake start that stops at once gives no stop
//      notice while its retry is pending.
//   I. [G65] Needs Permission offers no Stop (the model and the Recording menu).
//   J. [G39] A second copy opens no history, attaches no typing key and runs no recovery.
//   K. [critic gap] A saved app choice pauses for the save and records again (the real model, no mirror).
//   L. [G10b] Open at login: turned on once (setup finishing, or the first launch after it), one switch, no System
//      Settings unless asked, never outside Applications.
//   M. [invariant] Sources: every orange line has a path that clears it; the seams stay check-only.
//   N. [review round 1] The person's Stop after an update pause that didn't quit is saved (G10); a copy in the download
//      window leaves the launch intent for the copy in Applications (G10/G42); a timed pause whose pause write fails
//      for a moment keeps its end, from Pause for… and at launch (G4/G42); an import during a timed pause is no orange
//      warning beside it (ADV-3).
import AppKit
import CSQLite
import MemoryCore
import MemoryUI

let intentKey = "DaydreamRecordingWantedV1"

@MainActor enum Report {
    static var passed = 0, failed = 0
    static func check(_ ok: Bool, _ id: String, _ message: @autoclosure () -> String) {
        if ok { passed += 1; print("PASS [\(id)] \(message())") } else { failed += 1; print("FAIL [\(id)] \(message())") }
        fflush(stdout)
    }
}
@MainActor func check(_ ok: Bool, _ id: String, _ message: @autoclosure () -> String) { Report.check(ok, id, message()) }
func stop(_ message: String) -> Never {
    fflush(stdout)
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}
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

/// What the check builds' seams read. Plain statics: the seams are called on the main thread.
enum Seams {
    nonisolated(unsafe) static var granted = true
    nonisolated(unsafe) static var tapWorks = true
    nonisolated(unsafe) static var keyCalls = 0
    nonisolated(unsafe) static weak var tapModel: MemoryViewModel?
}

@MainActor final class FakeNotices {
    var posted: [RecordingNotice] = []
    var center: RecordingNoticeCenter { RecordingNoticeCenter(prepare: {}, post: { self.posted.append($0) }, clear: {}) }
}
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
@MainActor final class FakeLogin {
    var status: LoginItemControl.Status = .off
    var needsApproval = false
    var registered = 0, unregistered = 0, opened = 0
    var control: LoginItemControl {
        LoginItemControl(status: { MainActor.assumeIsolated { self.status } },
                         register: { MainActor.assumeIsolated { self.registered += 1; self.status = self.needsApproval ? .requiresApproval : .enabled } },
                         unregister: { MainActor.assumeIsolated { self.unregistered += 1; self.status = .off } },
                         openSettings: { MainActor.assumeIsolated { self.opened += 1 } })
    }
}

/// Raw SQL on a private check store (a second connection, as another process would have).
func sql(_ home: URL, _ statement: String) -> Bool {
    var db: OpaquePointer?
    guard sqlite3_open_v2(home.appendingPathComponent("memory.sqlite").path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { sqlite3_close(db); return false }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 5000)
    return sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK
}

/// One integer from a private check store (a second connection).
func sqlCount(_ home: URL, _ query: String) -> Int? {
    var db: OpaquePointer?, statement: OpaquePointer?
    guard sqlite3_open_v2(home.appendingPathComponent("memory.sqlite").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
    defer { sqlite3_finalize(statement); sqlite3_close(db) }
    sqlite3_busy_timeout(db, 5000)
    guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return Int(sqlite3_column_int64(statement, 0))
}

struct Opened { let model: MemoryViewModel; let notices: FakeNotices; let wake: FakeWake; let home: URL }

@main @MainActor struct LifecycleModelChecks {
    static var out = URL(fileURLWithPath: "/")
    static var suites: [String] = []

    static func main() async throws {
        let args = CommandLine.arguments
        if args.count == 4, args[1] == "--hold" { holdChild(args[2], Double(args[3]) ?? 2) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 240) {
            FileHandle.standardError.write(Data("FAIL: lifecycle-model-checks watchdog expired after 240s\n".utf8))
            exit(2)
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
        out = URL(fileURLWithPath: outPath, isDirectory: true).appendingPathComponent("lifecycle-model", isDirectory: true)
        try makePrivateDirectory(out)
        installSeams()
        // Setup was finished (the synthetic home's preferences).
        UserDefaults.standard.set(true, forKey: MemoryViewModel.setupCompletedKey)

        try sources()
        try await updateRelaunch()
        try await restartAndQuit()
        try await timedPauseAcrossLaunch()
        try await blockedLaunch()
        try await importAtUnlock()
        try await retryDuringImport()
        try await restorePreview()
        try await replacementReadError()
        try await failedDeleteAndSummary()
        try await inputStart()
        try await needsPermission()
        try await secondCopy()
        try await preferenceSave()
        try await openAtLogin()
        try await stopAfterUpdatePause()
        try await downloadWindowFirst()
        try await pauseWriteFails()
        try await timedPauseDuringImport()
        try await retryTapFails()
        try await saveLandsWhileLocked()

        for name in suites { UserDefaults.standard.removePersistentDomain(forName: name) }
        UserDefaults.standard.removeObject(forKey: MemoryViewModel.setupCompletedKey)
        print("lifecycle-model: \(Report.passed) passed, \(Report.failed) failed")
        fflush(stdout)
        exit(Report.failed == 0 ? 0 : 1)
    }

    static func installSeams() {
        MemoryViewModel.permissionsGranted = { Seams.granted }
        MemoryViewModel.permissionRead = { PermissionSnapshot(accessibility: Seams.granted, inputMonitoring: Seams.granted) }
        MemoryViewModel.startInput = { _ in
            if Seams.tapWorks { return true }
            // What EventCapture.start does when macOS gives it no event tap (none is installed here either way).
            MainActor.assumeIsolated { Seams.tapModel?.coordinator?.pause("Input event tap unavailable. No recording started.") }
            return false
        }
        MemoryViewModel.readLaunchLocation = { .applications }
        let keys = MemoryViewModel.typedKeyStore
        MemoryViewModel.typedKeyStore = { id in Seams.keyCalls += 1; return keys(id) }
        MemoryViewModel.loginItem = FakeLogin().control
    }

    static func suite(_ intent: [String: Any]? = nil) -> UserDefaults {
        let name = "lifecycle-check-" + UUID().uuidString
        suites.append(name)
        let defaults = UserDefaults(suiteName: name)!
        if let intent { defaults.set(intent, forKey: intentKey) }
        return defaults
    }
    static func home(_ name: String) throws -> URL {
        let memory = out.appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        try makePrivateDirectory(memory)
        return memory
    }
    /// A model launched on `home` with the launch intent in `intent`, once its launch work has run.
    static func open(_ name: String, home existing: URL? = nil, intent: UserDefaults?) async throws -> Opened {
        let memory = try existing ?? home(name)
        setenv("MAC_MEM_HOME", memory.path, 1)
        MemoryViewModel.launchIntentDefaults = intent
        let model = MemoryViewModel()
        MemoryViewModel.launchIntentDefaults = nil
        let notices = FakeNotices(), wake = FakeWake()
        model.noticeCenter = notices.center
        model.wakeSystem = wake.system
        Seams.tapModel = model
        check(!model.anotherCopyOpen, "harness", "\(name) opened its own history (no earlier model still holds it)")
        _ = try await waitFor(3) { !model.history.busy }
        try await tick(0.1)
        return Opened(model: model, notices: notices, wake: wake, home: memory)
    }
    static func intent(_ defaults: UserDefaults) -> [String: Any]? { defaults.dictionary(forKey: intentKey) }
    static func pausedReason(_ model: MemoryViewModel) -> String? {
        if case .paused(_, _, let reason) = model.recordingState { return reason }
        return nil
    }

    // MARK: A. An update relaunch

    static func updateRelaunch() async throws {
        // sat5's marker, left by Sparkle's relaunch, in the preferences the app reads it from.
        let standard = UserDefaults.standard
        standard.set(UpdateResume.marker(build: "check", at: Date()), forKey: UpdateResume.key)
        let o = try await open("update", intent: standard)
        _ = try await waitFor(3) { o.model.recording }
        check(o.model.recording, "Extra1/G10", "an update relaunch records again at launch (the launch-time history read holds nothing back)")
        check(o.model.operationalIssue == nil && o.model.shownIssue == nil,
              "Extra1", "no latched line after the update relaunch: \(o.model.operationalIssue ?? "nil")")
        check(o.notices.posted.isEmpty, "Extra1", "no notice after the update relaunch: \(o.notices.posted.map(\.body))")
        check(standard.dictionary(forKey: UpdateResume.key) == nil, "Extra1", "the update marker is read once")
        check(intent(standard)?["recording"] as? Bool == true, "G10", "recording on is saved as the launch intent")
        o.model.stopCapture()
        check(intent(standard) == nil, "G10", "the person's Stop clears the launch intent")
        standard.removeObject(forKey: intentKey)
    }

    // MARK: B. A crash, a quit, Stop and Pause

    static func restartAndQuit() async throws {
        let defaults = suite()
        let memory = try home("restart")
        var first: Opened? = try await open("restart-a", home: memory, intent: defaults)
        first?.model.startCapture()
        check(first?.model.recording == true, "harness", "Start records on a check model (no event tap: the input seam)")
        check(intent(defaults)?["recording"] as? Bool == true, "G10", "Start saves the launch intent")
        // A crash (or a restart that never reached the quit handler): the model is simply gone.
        weak var gone = first?.model
        first = nil
        try await tick(0.2)
        check(gone == nil, "harness", "the crashed model is gone and its recorder lock is free")
        var second: Opened? = try await open("restart-b", home: memory, intent: defaults)
        _ = try await waitFor(3) { second?.model.recording == true }
        check(second?.model.recording == true && second?.notices.posted.isEmpty == true, "G10",
              "after a crash or a restart, recording that was on starts again at launch, with no notice")

        // Quitting (a restart and a logout quit DayDream too) keeps the intent.
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        try await tick(0.1)
        check(second?.model.recording == false, "G10", "quitting pauses recording")
        check(intent(defaults)?["recording"] as? Bool == true, "G10", "quitting keeps the launch intent: \(intent(defaults) ?? [:])")
        weak var quit = second?.model
        second = nil
        try await tick(0.2)
        check(quit == nil, "harness", "the quit model is gone")
        var third: Opened? = try await open("restart-c", home: memory, intent: defaults)
        _ = try await waitFor(3) { third?.model.recording == true }
        check(third?.model.recording == true && third?.notices.posted.isEmpty == true, "G10", "after a quit, the next launch records again")

        // The person's Stop: the next launch leaves recording off, silently.
        third?.model.stopCapture()
        check(intent(defaults) == nil, "G10", "the person's Stop clears the launch intent")
        third = nil
        try await tick(0.2)
        let fourth = try await open("restart-d", home: memory, intent: defaults)
        try await tick(0.2)
        check(!fourth.model.recording && fourth.notices.posted.isEmpty && fourth.model.stopped, "G10",
              "after the person's Stop, launch leaves recording off and says nothing")

        // The person's timed pause: its end is the intent.
        fourth.model.startCapture()
        fourth.model.pauseFor(minutes: 15)
        let until = intent(defaults)?["until"] as? Double
        check(until.map { abs($0 - Date().addingTimeInterval(15 * 60).timeIntervalSince1970) < 5 } == true && intent(defaults)?["recording"] == nil,
              "G10/G42", "a timed pause saves its end as the launch intent: \(intent(defaults) ?? [:])")
        fourth.model.stopCapture()
        check(intent(defaults) == nil, "G10", "Stop during a timed pause clears it")
    }

    // MARK: C. A timed pause across a launch, and a launch that can't record

    static func timedPauseAcrossLaunch() async throws {
        let end = Date().addingTimeInterval(3)
        let defaults = suite(["until": end.timeIntervalSince1970])
        let o = try await open("timed", intent: defaults)
        check(!o.model.recording && o.model.pauseUntil.map { abs($0.timeIntervalSince(end)) < 1 } == true && o.model.recordingState.kind == .paused,
              "G42", "a timed pause running when DayDream quit is picked up until the same time: \(o.model.recordingState)")
        check(o.notices.posted.isEmpty && intent(defaults)?["until"] != nil, "G42", "no notice, and the pause's end is still the intent")
        _ = try await waitFor(6) { o.model.recording }
        check(o.model.recording && o.model.pauseUntil == nil && o.notices.posted.isEmpty, "G42",
              "at its end the pause records again by itself (the timed-pause end on the real model)")
        check(intent(defaults)?["recording"] as? Bool == true, "G42", "recording again is the intent")
        o.model.stopCapture()

        let ended = suite(["until": Date().addingTimeInterval(-60).timeIntervalSince1970])
        let late = try await open("timed-ended", intent: ended)
        _ = try await waitFor(3) { late.model.recording }
        check(late.model.recording && late.notices.posted.isEmpty, "G42", "a timed pause that ended while DayDream was closed records at launch")
        late.model.stopCapture()
    }

    static func blockedLaunch() async throws {
        Seams.granted = false
        defer { Seams.granted = true }
        let defaults = suite(["recording": true])
        let o = try await open("blocked", intent: defaults)
        // gold/int final review (G33): the launch start reads the permissions again for about a second before it gives up
        // (a moment's "not allowed" never stops recording for good); the reads again run here as the main queue would.
        var rounds = 0
        // gold r3 (gate item 3): for `permissionHoldQuiet` (4 s) now, so more rounds.
        while o.notices.posted.isEmpty && !o.wake.pending.isEmpty && rounds < 30 { try await tick(0.4); o.wake.runPending(); rounds += 1 }
        try await tick(0.2)
        check(!o.model.recording && o.wake.pending.isEmpty, "G42", "a launch without the permissions records nothing, and nothing keeps trying")
        check(o.notices.posted.count == 1 && o.notices.posted.first?.title == RecordingNotice.notRestartedTitle
              && o.notices.posted.first?.body.hasPrefix("Recording didn't start again when DayDream opened.") == true
              && o.notices.posted.first?.body.hasSuffix("Choose Turn on Accessibility from DayDream in the menu bar.") == true,
              "G42", "one notice says recording didn't start again and how: \(o.notices.posted.map(\.body))")
        check(intent(defaults) == nil && !o.model.recordingWanted, "G42", "one try only: the intent is cleared, nothing starts later by itself")
        check(o.model.recordingState.kind == .needsPermission, "G42", "the state says why: \(o.model.recordingState)")
        let again = try await open("blocked-again", intent: defaults)
        try await tick(0.2)
        check(again.notices.posted.isEmpty && !again.model.recording, "G42", "the next launch says nothing again")
    }

    // MARK: D. An import running when an automatic start is due

    static func importAtUnlock() async throws {
        let o = try await open("import", intent: nil)
        o.model.startCapture()
        check(o.model.recording, "harness", "recording before the lock")
        o.wake.locked = true
        o.model.suspend(.screenLock)
        check(!o.model.recording && o.model.wake.plan == .record, "harness", "the lock paused recording and planned the start")
        // G35: behind the lock screen the state is a pause that starts again, not Off with the wake blocker.
        check(o.model.recordingState.kind == .paused && o.model.presentation.issue == nil && o.model.shortState != "Setup required"
              && o.model.recordingInputs.resumeUnavailable == nil,
              "G35", "behind the lock screen: Paused, no \"Resume after your Mac wakes.\" and no gear dot: \(o.model.recordingState), \(o.model.shortState)")
        check(!o.model.presentation.canResume, "G35", "Start stays refused behind the lock screen")

        o.model.history.busy = true // an import running (MemoryFlows sets this while it works)
        try await tick()
        o.wake.locked = false
        o.model.unsuspend(.screenLock)
        check(o.wake.runPending() == [WakeResumeMachine.settleDelay], "harness", "the unlock settles first")
        check(!o.model.recording && o.model.operationalIssue == nil && o.model.shownIssue == nil, "Extra2",
              "an import running at unlock latches no line: \(o.model.operationalIssue ?? "nil")")
        check(o.wake.pending.isEmpty && o.notices.posted.isEmpty, "Extra2", "no retry and no notice: nothing went wrong")
        check(o.model.recordingWanted && o.model.startWhenFree && pausedReason(o.model) == "Paused until your import or backup finishes.",
              "Extra2", "Paused, saying it starts when the import finishes: \(o.model.recordingState)")
        check(o.model.presentation.issue == nil && o.model.presentation.canStop, "Extra2", "no orange line; Stop is offered")
        o.model.history.busy = false
        _ = try await waitFor(2) { o.model.recording }
        check(o.model.recording && o.notices.posted.isEmpty && o.model.operationalIssue == nil, "Extra2",
              "when the import ends, recording starts again by itself")
        o.model.stopCapture()

        // Without a start waiting, an import is Off with its own line, and it clears itself.
        o.model.history.busy = true
        try await tick(0.1)
        check(o.model.recordingState == .off(since: o.model.stoppedAt, reason: "An import or backup is running.") && o.model.operationalIssue == nil,
              "nit", "an import running while Off: its own line, not a save failure: \(o.model.recordingState)")
        o.model.history.busy = false
        try await tick(0.1)
        check(o.model.recordingState == .off(since: o.model.stoppedAt, reason: nil), "nit", "the line clears itself when the import ends: \(o.model.recordingState)")
    }

    static func retryDuringImport() async throws {
        let o = try await open("retry-import", intent: nil)
        o.model.startCapture()
        guard let coordinator = o.model.coordinator, o.model.recording else { check(false, "harness", "retry model did not record"); return }
        // A failed save, through the coordinator.
        coordinator.captureFailed(MemError.database("write failed (code 10)"), recording: true)
        check(o.model.storageRetry.active && o.model.storageRetry.failures == 1 && o.wake.pending.map(\.0) == [StorageRetry.delays[0]],
              "harness", "a failed save set the first try: \(o.model.storageRetry)")
        o.model.history.busy = true
        o.wake.runPending()
        check(o.model.storageRetry.failures == 1 && o.model.operationalIssue == nil && o.wake.pending.isEmpty && o.notices.posted.isEmpty,
              "nit", "a try that finds an import running is not a failed save: not counted, no line, no notice (\(o.model.storageRetry), \(o.model.operationalIssue ?? "nil"))")
        check(pausedReason(o.model) == "Paused until your import or backup finishes.", "nit", "it says it waits for the import: \(o.model.recordingState)")
        o.model.history.busy = false
        _ = try await waitFor(2) { o.model.recording }
        check(o.model.recording && !o.model.storageRetry.active, "nit", "when the import ends, recording starts again and the retries end")
        o.model.stopCapture()
    }

    // MARK: E. A restore preview saved before DayDream quit

    /// Writes the pending restore preview BackupSettingsModel reads at launch, with its staging folder.
    static func pendingPreview(_ memory: URL, expires: Date) throws -> URL { try pendingPreviewWithID(memory, expires: expires).parent }
    static func pendingPreviewWithID(_ memory: URL, expires: Date) throws -> (parent: URL, id: String) {
        let parent = try physicalDirectory(FileManager.default.temporaryDirectory).appendingPathComponent("macmem-restore-" + UUID().uuidString, isDirectory: true)
        let candidate = parent.appendingPathComponent("candidate", isDirectory: true)
        try makePrivateDirectory(candidate)
        let fence: [String: Any] = ["storeID": "check", "disclosureRevision": "1", "policyRevision": "1", "deletionRevision": "1",
                                    "correctionRevision": "1", "actionCount": 0, "tombstoneCount": 0]
        let id = UUID().uuidString
        let preview: [String: Any] = ["id": id, "authority": fence, "candidate": fence, "candidateDigest": "check",
                                      "addedActionIDs": [String](), "expiresAt": iso(expires), "explanation": "check"]
        let prepared: [String: Any] = ["staging": candidate.path, "databaseSHA256": String(repeating: "0", count: 64), "preview": preview]
        try JSONSerialization.data(withJSONObject: prepared).write(to: memory.appendingPathComponent("backup-pending-v1.json"))
        return (parent, id)
    }

    static func restorePreview() async throws {
        // One that ran out while DayDream was closed: closed at launch, and recording that was on starts again.
        let oldHome = try home("restore-old")
        let staging = try pendingPreview(oldHome, expires: Date().addingTimeInterval(-3600))
        let old = try await open("restore-old", home: oldHome, intent: suite(["recording": true]))
        _ = try await waitFor(3) { old.model.recording }
        check(old.model.backups.prepared == nil && old.model.backups.status == "The restore preview expired. Nothing was restored."
              && !FileManager.default.fileExists(atPath: oldHome.appendingPathComponent("backup-pending-v1.json").path)
              && !FileManager.default.fileExists(atPath: staging.path),
              "Extra4", "a restore preview that ran out while DayDream was closed is closed at launch; nothing is restored (\(old.model.backups.status))")
        check(old.model.recording && old.notices.posted.isEmpty, "Extra4", "and recording that was on starts again")
        old.model.stopCapture()

        // One still waiting: a blocker with its own line, one notice that names Review…, and it clears itself.
        let newHome = try home("restore-new")
        let waiting = try pendingPreviewWithID(newHome, expires: Date().addingTimeInterval(300))
        defer { try? FileManager.default.removeItem(at: waiting.parent) }
        let o = try await open("restore-new", home: newHome, intent: suite(["recording": true]))
        try await tick(0.2)
        check(!o.model.recording && o.model.backups.prepared != nil, "Extra4", "a restore waiting for review holds recording")
        check(o.model.resumeUnavailable == "Restore waiting for review" && o.model.recordingState.kind == .off
              && o.model.recordingState == .off(since: o.model.stoppedAt, reason: "Finish or cancel the restore in Settings."),
              "Extra4", "its own line: \(o.model.recordingState)")
        check(o.notices.posted.map(\.body) == ["Recording didn't start again when DayDream opened. It stopped because a restore is waiting for review. Choose Review… from DayDream in the menu bar."],
              "Extra4", "one notice, naming the menu bar's Review…: \(o.notices.posted.map(\.body))")
        check(o.model.operationalIssue == nil, "Extra4", "no save-failure line")
        // Cancel while the backup helper can't run (notes on, say): the preview closes all the same, inside the app.
        let row = "restore_preview_" + waiting.id
        check(sql(newHome, "INSERT OR REPLACE INTO metadata VALUES('\(row)','check')") && sqlCount(newHome, "SELECT count(*) FROM metadata WHERE id='\(row)'") == 1,
              "harness", "the preview's row is in the history")
        o.model.backups.permitted = { false }
        o.model.backups.cancel()
        try await tick(0.2)
        check(o.model.backups.prepared == nil && o.model.backups.status == "Preview closed." && !FileManager.default.fileExists(atPath: waiting.parent.path)
              && sqlCount(newHome, "SELECT count(*) FROM metadata WHERE id='\(row)'") == 0,
              "Extra4", "Cancel closes the preview even while the backup helper can't run: \(o.model.backups.status)")
        check(o.model.resumeUnavailable == nil && o.model.recordingState == .off(since: o.model.stoppedAt, reason: nil) && o.notices.posted.count == 1 && !o.model.recording,
              "Extra4", "closing the preview clears the blocker by itself; nothing starts (the notice said so): \(o.model.recordingState)")
        o.model.stopCapture()

        // One whose five minutes run out while DayDream is open: closed at the next look, so it holds nothing back.
        let lateHome = try home("restore-late")
        let lateEnd = Date().addingTimeInterval(3)
        let late = try pendingPreview(lateHome, expires: lateEnd)
        defer { try? FileManager.default.removeItem(at: late) }
        let l = try await open("restore-late", home: lateHome, intent: suite())
        check(l.model.resumeUnavailable == "Restore waiting for review", "Extra4", "a live preview holds recording: \(String(describing: l.model.resumeUnavailable))")
        try await tick(max(0, lateEnd.timeIntervalSinceNow) + 0.2)
        l.model.checkPermissions()
        try await tick(0.2)
        check(l.model.backups.prepared == nil && l.model.backups.status == "The restore preview expired. Nothing was restored." && l.model.resumeUnavailable == nil
              && !FileManager.default.fileExists(atPath: late.path),
              "Extra4", "a preview that ran out while DayDream was open no longer holds recording: \(String(describing: l.model.resumeUnavailable)), \(l.model.backups.status)")
        l.model.startCapture()
        check(l.model.recording, "Extra4", "and Start records")
        l.model.stopCapture()
    }

    // MARK: F. A replacement read that fails for a moment

    static func replacementReadError() async throws {
        let o = try await open("replacement", intent: nil)
        o.model.startCapture()
        o.model.pauseFor(minutes: 5)
        let end = o.model.pauseUntil
        check(end != nil, "harness", "the timed pause is running")
        check(sql(o.home, "INSERT OR REPLACE INTO metadata VALUES('switchover','not a record')"), "harness", "the replacement row reads as an error")
        try await tick(1.6) // the pause's one-second timer ticks at least once
        check(o.model.pauseUntil == end && o.model.recordingState.kind == .paused && o.notices.posted.isEmpty, "Extra3",
              "a replacement read that fails for a moment doesn't end the timed pause: \(o.model.recordingState)")
        check(o.model.resumeUnavailable != "Review replacement" && o.model.presentation.issue == nil, "Extra3",
              "and it doesn't read as a replacement to review: \(o.model.resumeUnavailable ?? "nil")")
        o.model.startCapture()
        check(!o.model.recording, "Extra3", "Start records nothing while the read fails (fail closed)")
        check(sql(o.home, "DELETE FROM metadata WHERE id='switchover'"), "harness", "the replacement row is removed")
        o.model.stopCapture()
    }

    // MARK: G. A failed delete or summary job during a timed pause

    static func failedDeleteAndSummary() async throws {
        let o = try await open("g4", intent: nil)
        let side = try MemoryStore(home: o.home, writable: true, automaticallySyncSearch: false)
        for n in 1...3 {
            _ = try side.ingest(Evidence(id: "lifecycle-\(n)", at: iso(Date()), kind: "mouse.click", app: "TextEdit", title: "Synthetic action \(n)", synthetic: true))
        }
        o.model.startCapture()
        o.model.pauseFor(minutes: 5)
        let end = o.model.pauseUntil
        check(end != nil, "harness", "the timed pause is running")

        // A delete that fails (the store refuses the tombstone).
        check(sql(o.home, "CREATE TRIGGER lifecycle_no_delete BEFORE INSERT ON tombstones BEGIN SELECT RAISE(ABORT,'check'); END"), "harness", "delete refusal armed")
        o.model.selected = "lifecycle-1"
        o.model.remove()
        check(o.model.operationalIssue == "Deletion failed" && o.model.pauseUntil == end && o.model.recordingState.kind == .paused, "G4",
              "a failed delete says so and leaves the timed pause running: \(o.model.operationalIssue ?? "nil"), \(o.model.recordingState)")
        check(sql(o.home, "DROP TRIGGER lifecycle_no_delete"), "harness", "delete refusal removed")
        o.model.removeSource("lifecycle-1")
        check(o.model.operationalIssue == nil, "G4", "the next delete that works clears the line")

        // Summary jobs that fail (the store refuses the summary). One says nothing; three in a row show the line.
        check(sql(o.home, "CREATE TRIGGER lifecycle_no_summary BEFORE INSERT ON summaries BEGIN SELECT RAISE(ABORT,'check'); END"), "harness", "summary refusal armed")
        for n in 1...3 {
            o.model.coordinator?.session.onCommitted?()
            try await tick(0.8)
            if n == 1 {
                check(o.model.operationalIssue == nil && o.model.pauseUntil == end, "G4",
                      "one failed summary job changes nothing: no line, the timed pause keeps running (\(o.model.operationalIssue ?? "nil"))")
            }
        }
        check(o.model.operationalIssue == "Summary writer needs attention" && o.model.pauseUntil == end, "G4",
              "summary jobs that keep failing show the line; the timed pause still runs: \(o.model.operationalIssue ?? "nil")")
        check(sql(o.home, "DROP TRIGGER lifecycle_no_summary"), "harness", "summary refusal removed")
        o.model.coordinator?.session.onCommitted?()
        _ = try await waitFor(3) { o.model.operationalIssue == nil }
        check(o.model.operationalIssue == nil && o.model.pauseUntil == end, "G4", "the next summary job that works clears it")
        o.model.stopCapture()
    }

    // MARK: H. Keyboard and mouse that couldn't start

    static func inputStart() async throws {
        let o = try await open("input", intent: nil)
        Seams.tapWorks = false
        o.model.startCapture()
        check(!o.model.recording && o.model.operationalIssue == nil && o.model.shownIssue == nil, "G36",
              "keyboard and mouse that couldn't start leave no \"Input capture needs attention\" line: \(o.model.operationalIssue ?? "nil")")
        // gold/int: ui-copy (G11) gives this pause its words; Resume then goes to Quit & Reopen where DayDream can reopen.
        check(pausedReason(o.model) == RecordingCopy.inputUnreachable, "G36", "the pause says it once, with Resume: \(o.model.recordingState)")
        try await tick(0.1)
        check(o.notices.posted.isEmpty, "G36", "the person's own Start that couldn't start the input sends no \"stopped recording\" notice: the state says it")
        o.model.stopCapture()
        check(o.model.operationalIssue == nil && o.model.presentation.issue == nil, "G36", "after Stop nothing is left")
        Seams.tapWorks = true
        o.model.startCapture()
        check(o.model.recording && o.model.operationalIssue == nil, "G36", "Start works once the input starts")

        // G56: a wake start whose input stops at once: no stop notice while the wake retry is pending.
        o.wake.locked = true
        o.model.suspend(.screenLock)
        Seams.tapWorks = false
        o.wake.locked = false
        o.model.unsuspend(.screenLock)
        check(o.wake.runPending() == [WakeResumeMachine.settleDelay], "harness", "the unlock settles first")
        try await tick(0.1) // a stop notice would go out on the next turn
        check(o.notices.posted.isEmpty && o.wake.pending.map(\.0) == [WakeResumeMachine.retryDelay], "G56",
              "no stop notice while the wake retry is pending: \(o.notices.posted.map(\.title)), \(o.wake.pending.map(\.0))")
        o.wake.runPending()
        try await tick(0.1)
        check(o.notices.posted.count == 1 && o.notices.posted.first?.title == RecordingNotice.notRestartedTitle, "G56",
              "the retry that fails too gives one notice: \(o.notices.posted.map(\.title))")
        Seams.tapWorks = true
        o.model.stopCapture()
    }

    /// [G56 review, gold/int] A save retry whose start can't reach the keyboard and mouse: the start began and stopped at
    /// once, so its token moved; that stop is still said once, and nothing tries again by itself.
    static func retryTapFails() async throws {
        let o = try await open("retry-tap", intent: nil)
        o.model.startCapture()
        guard let coordinator = o.model.coordinator, o.model.recording else { check(false, "harness", "retry-tap model did not record"); return }
        coordinator.captureFailed(MemError.database("write failed (code 10)"), recording: true)
        check(o.model.storageRetry.active && o.wake.pending.map(\.0) == [StorageRetry.delays[0]], "harness",
              "a failed save set the first try: \(o.model.storageRetry)")
        Seams.tapWorks = false
        defer { Seams.tapWorks = true }
        o.wake.runPending()
        try await tick(0.1) // a stop notice would go out on the next turn
        check(!o.model.recording && o.notices.posted.count == 1 && !o.model.recordingWanted && o.wake.pending.isEmpty, "G56",
              "a save retry whose start can't reach the keyboard and mouse says so once and stops trying: \(o.notices.posted.map(\.title)), wanted \(o.model.recordingWanted), pending \(o.wake.pending.map(\.0))")
        o.model.stopCapture()
    }

    // MARK: I. Needs Permission

    static func needsPermission() async throws {
        Seams.granted = false
        defer { Seams.granted = true }
        let o = try await open("permission", intent: nil)
        o.model.startCapture() // the session records a denial
        let p = o.model.presentation
        check(o.model.recordingState.kind == .needsPermission && !p.canStop, "G65", "Needs Permission offers no Stop: \(o.model.recordingState), canStop \(p.canStop)")
        let stopItem = { (items: [MenuBarRecordingMenu.Item]) in items.first { $0.title == "Stop Recording" }?.enabled }
        check(stopItem(MenuBarRecordingMenu.items(state: p.state, canResume: p.canResume, canStop: p.canStop)) == false, "G65", "the Recording menu's Stop Recording is off")
        check(stopItem(MenuBarRecordingMenu.items(state: .needsPermission(missing: []), canResume: false, canStop: true)) == false
              && stopItem(MenuBarRecordingMenu.items(state: .off(since: nil, reason: nil), canResume: true, canStop: true)) == false
              && stopItem(MenuBarRecordingMenu.items(state: .paused(until: nil, since: nil, reason: nil), canResume: true, canStop: true)) == true,
              "G65", "Stop Recording is on only while Recording or Paused")
    }

    // MARK: J. A second copy

    static func secondCopy() async throws {
        let first = try await open("copy", intent: nil)
        let keys = Seams.keyCalls
        setenv("MAC_MEM_HOME", first.home.path, 1)
        let second = MemoryViewModel()
        let recoveryStarted = second.history.busy // MemoryFlows is busy while its recovery (a writable open) runs
        try await tick(0.3)
        check(second.anotherCopyOpen && second.status.hasPrefix("Another copy of DayDream is open."), "harness", "the second copy knows it is one: \(second.status)")
        check(second.historyStoreID == nil && second.coordinator == nil, "G39", "a second copy opens no history")
        check(Seams.keyCalls == keys, "G39", "a second copy attaches no typing key")
        check(!recoveryStarted && !second.history.busy && second.history.status.isEmpty && second.history.session == nil, "G39",
              "a second copy runs no history recovery (it would open the history for writing): \(second.history.status)")
        check(!second.openAtLoginAvailable, "G39", "a second copy has no Open at login switch")
        check(first.model.coordinator != nil && first.model.historyStoreID != nil, "G39", "the first copy keeps its history")
    }

    // MARK: K. A saved app choice

    static func preferenceSave() async throws {
        let defaults = suite()
        let o = try await open("prefs", intent: defaults)
        o.model.startCapture()
        o.model.exclusionPreference.wrappedValue = "com.example.editor"
        o.model.saveWaitingChoices()
        _ = try await waitFor(3) { o.model.recording && !o.model.preferencesUnresolved }
        check(o.model.recording && o.model.blockedApps.contains("com.example.editor") && o.notices.posted.isEmpty && o.model.operationalIssue == nil,
              "critic", "a saved app choice pauses for the save and records again (real model): \(o.model.recordingState)")
        check(intent(defaults)?["recording"] as? Bool == true, "G10", "recording again after the save is still the launch intent")
        o.model.stopCapture()
    }

    // MARK: L. Open at login

    static func openAtLogin() async throws {
        let login = FakeLogin()
        MemoryViewModel.loginItem = login.control
        defer { MemoryViewModel.loginItem = FakeLogin().control }
        let defaults = suite()
        var first: Opened? = try await open("login-a", intent: defaults)
        check(login.registered == 1 && login.opened == 0 && first?.model.openAtLogin == true, "G10b",
              "the first launch after setup turns Open at login on, once, without opening System Settings (registered \(login.registered))")
        first = nil
        try await tick(0.2)
        let second = try await open("login-b", intent: defaults)
        check(login.registered == 1 && second.model.openAtLogin, "G10b", "never again at launch: the person's switch rules after")
        second.model.setOpenAtLogin(false)
        check(login.unregistered == 1 && !second.model.openAtLogin, "G10b", "the switch turns it off")
        login.needsApproval = true
        second.model.setOpenAtLogin(true)
        check(login.registered == 2 && login.opened == 1 && !second.model.openAtLogin, "G10b",
              "turned on while macOS wants approval: Login Items opens, and the switch reads off until they allow it")
        login.needsApproval = false

        // Setup not finished: nothing at launch; finishing setup turns it on.
        UserDefaults.standard.set(false, forKey: MemoryViewModel.setupCompletedKey)
        let fresh = try await open("login-c", intent: suite())
        check(login.registered == 2, "G10b", "before setup finishes nothing is registered")
        UserDefaults.standard.set(true, forKey: MemoryViewModel.setupCompletedKey)
        fresh.model.setupFinished()
        check(login.registered == 3 && fresh.model.openAtLogin, "G10b", "setup finishing turns Open at login on")
        fresh.model.setupFinished()
        check(login.registered == 3, "G10b", "only once")

        // Not in Applications: no switch, nothing registered.
        MemoryViewModel.readLaunchLocation = { .diskImage }
        let download = try await open("login-d", intent: suite())
        MemoryViewModel.readLaunchLocation = { .applications }
        download.model.setupFinished()
        check(!download.model.openAtLoginAvailable && login.registered == 3, "G10b", "from the download window: no switch and nothing registered")
    }

    // MARK: N. Review round 1

    /// [G10] Sparkle began the relaunch after an install, but the quit didn't happen, then the person's own Stop. The
    /// app's own preferences hold the intent and sat5's marker (as in A), so the base, which reads the marker, runs it too.
    /// gold/int: updates-release (G9) removed `updates.pauseForUpdate` (nothing pauses before the quit; the quit pauses,
    /// willTerminate), so these rows drive Sparkle's relaunch hook, `updates.relaunching()`, which leaves the marker.
    static func stopAfterUpdatePause() async throws {
        let standard = UserDefaults.standard
        standard.removeObject(forKey: intentKey)
        standard.removeObject(forKey: UpdateResume.key)
        defer { standard.removeObject(forKey: intentKey); standard.removeObject(forKey: UpdateResume.key) }
        let memory = try home("update-stop")
        var a: Opened? = try await open("update-stop-a", home: memory, intent: standard)
        a?.model.startCapture()
        check(a?.model.recording == true, "harness", "recording before the update")
        // Sparkle leaves its relaunch marker (updaterWillRelaunchApplication); then the quit doesn't happen.
        a?.model.updates.prepareToQuit = {}
        a?.model.updates.relaunching()
        check(standard.dictionary(forKey: UpdateResume.key) != nil, "harness", "Sparkle's relaunch left its marker")
        check(a?.model.recording == true && a?.model.presentation.canStop == true, "harness", "nothing pauses before the quit, Stop offered")
        a?.model.stopCapture()
        check(intent(standard) == nil, "R1/G10", "the person's Stop after an update pause clears the launch intent: \(intent(standard) ?? [:])")
        check(standard.dictionary(forKey: UpdateResume.key) == nil, "R1/G10", "and the update marker: the person's Stop wins over the relaunch")
        weak var gone = a?.model
        a = nil
        try await tick(0.2)
        check(gone == nil, "harness", "the model is gone and its recorder lock is free")
        let b = try await open("update-stop-b", home: memory, intent: standard)
        _ = try await waitFor(1) { b.model.recording }
        check(!b.model.recording && b.notices.posted.isEmpty && b.model.stopped, "R1/G10",
              "the next launch leaves recording off after the person's Stop, and says nothing: \(b.model.recordingState)")
        // Resume, then Stop, after an update pause.
        b.model.updates.prepareToQuit = {}
        b.model.startCapture()
        b.model.updates.relaunching()
        b.model.startCapture()
        check(b.model.recording && intent(standard)?["recording"] as? Bool == true, "R1/G10", "Resume after an update relaunch is saved: \(intent(standard) ?? [:])")
        b.model.stopCapture()
        check(intent(standard) == nil, "R1/G10", "Resume then Stop after an update pause clears the intent: \(intent(standard) ?? [:])")
        // The person's Pause after Sparkle began a relaunch that didn't happen (recording carried on: a timed pause).
        b.model.startCapture()
        b.model.updates.relaunching()
        check(standard.dictionary(forKey: UpdateResume.key) != nil, "harness", "Sparkle's relaunch left its marker again")
        b.model.pauseFor(minutes: 15)
        check(standard.dictionary(forKey: UpdateResume.key) == nil && b.model.pauseUntil != nil, "R1/G10",
              "the person's Pause after Sparkle's relaunch began removes the update marker: \(intent(standard) ?? [:])")
        b.model.stopCapture()
    }

    /// [G10/G42] The owner opens the new disk image's copy by mistake (SPEC 6.3 R3), then the copy in Applications.
    static func downloadWindowFirst() async throws {
        let defaults = suite(["recording": true])
        defaults.set(UpdateResume.marker(build: "check", at: Date()), forKey: UpdateResume.key)
        let memory = try home("dmg")
        MemoryViewModel.readLaunchLocation = { .diskImage }
        var dmg: Opened? = try await open("dmg-a", home: memory, intent: defaults)
        MemoryViewModel.readLaunchLocation = { .applications }
        try await tick(0.3)
        check(dmg?.model.recording == false && dmg?.notices.posted.isEmpty == true, "R1/G10",
              "a copy in the download window records nothing and posts no notice (its alert is the one message): \(dmg?.notices.posted.map(\.body) ?? [])")
        check(intent(defaults)?["recording"] as? Bool == true && defaults.dictionary(forKey: UpdateResume.key) != nil, "R1/G10",
              "it leaves the launch intent and the update marker for the copy in Applications: \(intent(defaults) ?? [:])")
        dmg?.model.startCapture()
        check(dmg?.model.recording == false && intent(defaults)?["recording"] as? Bool == true, "R1/G10", "its refused Start saves nothing")
        weak var gone = dmg?.model
        dmg = nil
        try await tick(0.3)
        check(gone == nil, "harness", "the download-window copy is gone")
        let apps = try await open("dmg-b", home: memory, intent: defaults)
        _ = try await waitFor(3) { apps.model.recording }
        check(apps.model.recording && apps.notices.posted.isEmpty, "R1/G10",
              "the copy in Applications then records again, with no notice: \(apps.model.recordingState)")
        check(defaults.dictionary(forKey: UpdateResume.key) == nil, "R1/G10", "and it reads the update marker, once")
        apps.model.stopCapture()
    }

    /// [G4/G42] A pause write that fails for a moment (another connection held the file past the busy wait): the timed
    /// pause keeps its end, from Pause for… and when it is picked up at launch.
    static func pauseWriteFails() async throws {
        let refuse = "CREATE TRIGGER lifecycle_no_pause BEFORE INSERT ON metadata WHEN NEW.id='capture' AND instr(NEW.body,'\"state\":\"paused\"')>0 BEGIN SELECT RAISE(ABORT,'check'); END"
        let defaults = suite()
        let o = try await open("pause-write", intent: defaults)
        o.model.startCapture()
        check(o.model.recording && sql(o.home, refuse), "harness", "recording; pause refusal armed")
        o.model.pauseFor(minutes: 15)
        let end = o.model.pauseUntil
        check(end != nil && o.model.coordinator?.session.state == "error", "harness",
              "the pause write failed: \(o.model.coordinator?.session.state ?? "nil"), until \(String(describing: end))")
        check(sql(o.home, "DROP TRIGGER lifecycle_no_pause"), "harness", "pause refusal removed")
        o.model.refreshCaptureStatus() // what a summary job, a commit or becoming active does next
        try await tick(1.2) // the pause's one-second timer ticks too
        check(end != nil && o.model.pauseUntil == end && !o.model.recording, "R1/G4",
              "a pause whose write failed for a moment keeps its end: \(o.model.recordingState)")
        check(o.model.recordingState == .paused(until: end, since: o.model.pausedAt, reason: nil) && o.model.presentation.issue == nil
              && o.notices.posted.isEmpty && o.model.operationalIssue == nil, "R1/G4",
              "one state, Paused until its end: no \"Couldn't save\" line, no notice: \(o.model.recordingState)")
        check((intent(defaults)?["until"] as? Double).map { abs($0 - (end?.timeIntervalSince1970 ?? 0)) < 1 } == true, "R1/G4",
              "its end is still the launch intent: \(intent(defaults) ?? [:])")
        o.model.stopCapture()
        check(o.model.pauseUntil == nil && intent(defaults) == nil && !o.model.recording, "R1/G4", "the person's Stop still ends it")

        // At launch: the timed pause saved at quit is picked up, and its pause write fails for a moment.
        let memory = try home("launch-pause-write")
        var first: Opened? = try await open("launch-pause-write-a", home: memory, intent: nil)
        weak var gone = first?.model
        first = nil
        try await tick(0.3)
        check(gone == nil && sql(memory, refuse), "harness", "the first model is gone; pause refusal armed")
        let until = Date().addingTimeInterval(3)
        let saved = suite(["until": until.timeIntervalSince1970])
        let l = try await open("launch-pause-write-b", home: memory, intent: saved)
        check(l.model.coordinator?.session.state == "error", "harness", "the launch pause write failed: \(l.model.coordinator?.session.state ?? "nil")")
        check(sql(memory, "DROP TRIGGER lifecycle_no_pause"), "harness", "pause refusal removed")
        l.model.refreshCaptureStatus()
        check(l.model.pauseUntil.map { abs($0.timeIntervalSince(until)) < 1 } == true && !l.model.recording && l.notices.posted.isEmpty
              && l.model.recordingState.kind == .paused && l.model.presentation.issue == nil, "R1/G42",
              "a timed pause picked up at launch keeps its end when its pause write fails: \(l.model.recordingState)")
        check(intent(saved)?["until"] != nil, "R1/G42", "its end is still the launch intent: \(intent(saved) ?? [:])")
        _ = try await waitFor(6) { l.model.recording }
        check(l.model.recording && l.notices.posted.isEmpty && l.model.pauseUntil == nil, "R1/G42", "at its end it records by itself")
        l.model.stopCapture()
    }

    /// Another process holds a read transaction (SQLite's SHARED lock) on the store's file for `seconds` (a child copy
    /// of this binary, as in save-path-app-checks).
    static func hold(_ memory: URL, seconds: Double) throws -> Process {
        let child = Process(), out = Pipe()
        child.executableURL = Bundle.main.executableURL
        child.arguments = ["--hold", memory.appendingPathComponent("memory.sqlite").path, String(seconds)]
        child.standardOutput = out
        try child.run()
        var buffer = Data()
        while !String(decoding: buffer, as: UTF8.self).contains("held") {
            let more = out.fileHandleForReading.availableData
            if more.isEmpty { break }
            buffer.append(more)
        }
        return child
    }
    static func holdChild(_ path: String, _ seconds: Double) -> Never {
        // wal-1005: another connection's save holds the file (the write lock). The app's history keeps SQLite's
        // write-ahead log now, where a read (an AI app's) never makes a save busy.
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(db, "SELECT count(*) FROM sqlite_master", nil, nil, nil) == SQLITE_OK else { exit(3) }
        print("held"); fflush(stdout)
        Thread.sleep(forTimeInterval: seconds)
        sqlite3_exec(db, "COMMIT", nil, nil, nil); sqlite3_close(db)
        exit(0)
    }

    /// [save-path CRITIC-GAP-autosave, gold/int] A site added while recording meets a busy file: recording stops for the
    /// save, which is tried again quietly. The screen locks before it lands: the landed save never starts recording
    /// behind the lock screen; the unlock does. The same with a lock whose notice hasn't come yet.
    static func saveLandsWhileLocked() async throws {
        for noticed in [true, false] {
            let name = noticed ? "save-lock" : "save-lock-unnoticed"
            let o = try await open(name, intent: nil)
            o.model.startCapture()
            guard o.model.recording else { check(false, "harness", "\(name) model did not record"); continue }
            let holder = try hold(o.home, seconds: 9)
            let added: String? = { do { try o.model.addSite("example.net"); return nil } catch { return "\(error)" } }()
            check(added == nil && !o.model.recording && o.model.preferencesUnresolved, "harness",
                  "\(name): the save met the busy file and recording stopped for it (\(added ?? "nothing thrown"), recording \(o.model.recording))")
            o.wake.locked = true
            if noticed { o.model.suspend(.screenLock) }
            _ = try await waitFor(20) { !o.model.preferencesUnresolved }
            holder.waitUntilExit()
            try await tick(0.2)
            check(!o.model.preferencesUnresolved && o.model.savedSites.contains("example.net"), "harness", "\(name): the save landed")
            check(!o.model.recording, "critic",
                  "\(name): a save that lands behind the lock screen doesn't start recording there: \(o.model.recordingState)")
            o.wake.locked = false
            if noticed || o.model.wake.suspended { o.model.unsuspend(.screenLock) }
            check(o.wake.runPending().contains(WakeResumeMachine.settleDelay), "critic", "\(name): the unlock settles, then starts")
            check(o.model.recording && o.notices.posted.isEmpty, "critic",
                  "\(name): recording starts again after the unlock, with no notice: \(o.model.recordingState), \(o.notices.posted.map(\.title))")
            o.model.stopCapture()
        }
    }

    /// [ADV-3] An import or backup running during a timed pause: Paused until its end is the one line (no orange
    /// "An import or backup is running." under it); at the end the pause waits for the import, then records.
    static func timedPauseDuringImport() async throws {
        let end = Date().addingTimeInterval(2.5)
        let o = try await open("overlap", intent: suite(["until": end.timeIntervalSince1970]))
        o.model.history.busy = true // an import running (MemoryFlows sets this while it works)
        try await tick(0.2)
        let p = o.model.presentation
        let header = MenuBarMenu.header(p, now: Date(), timeZone: .current, canSetUp: true, canOpenApplications: false)
        check(o.model.recordingState.kind == .paused && p.attentionLine(now: Date()) == nil && header.attention == nil
              && header.status.text.hasPrefix("Paused · resumes ") && o.model.shortState.hasPrefix("Paused until "), "R1/ADV-3",
              "a timed pause during an import shows one line, no orange warning: \(header.status.text) / \(header.attention ?? "nil") / \(o.model.shortState)")
        check(!p.canResume, "R1/ADV-3", "Resume stays refused until the import ends")
        _ = try await waitFor(4) { o.model.pauseUntil == nil }
        try await tick(0.2)
        check(pausedReason(o.model) == "Paused until your import or backup finishes." && o.notices.posted.isEmpty
              && o.model.presentation.attentionLine(now: Date()) == nil, "R1/ADV-3",
              "at its end the pause waits for the import, saying so once: \(o.model.recordingState)")
        o.model.history.busy = false
        _ = try await waitFor(2) { o.model.recording }
        check(o.model.recording && o.notices.posted.isEmpty, "R1/ADV-3", "and records when the import ends")
        o.model.stopCapture()
    }

    // MARK: M. Sources

    static func sources() throws {
        let app = try String(contentsOfFile: "Sources/MacMemApp/MacMemApp.swift", encoding: .utf8)
        // Every orange line has a path that clears it: each value set is one of three, and each has its clearing line.
        let assigned = app.components(separatedBy: "operationalIssue=").dropFirst().map { String($0.prefix(while: { $0 != ";" && $0 != "}" && $0 != "\n" })) }
        let values = Set(assigned.map { $0.trimmingCharacters(in: .whitespaces) }).subtracting(["nil"])
        check(values == ["Self.choicesUnsavedIssue", "Self.summaryIssue", "Self.deletionIssue"], "invariant",
              "operationalIssue is set only to the three lines that clear: \(values.sorted())")
        for value in ["Self.choicesUnsavedIssue", "Self.summaryIssue", "Self.deletionIssue"] {
            check(app.contains("if operationalIssue == \(value) {operationalIssue=nil}") || app.contains("if self.operationalIssue == \(value) {self.operationalIssue=nil}"),
                  "invariant", "\(value) has a line that clears it")
        }
        check(!app.contains("Finish history operation before recording") && !app.contains("Input capture needs attention"), "Extra2/G36",
              "no latched history or input line is left")
        // The seams stay check-only: the app attaches the Keychain, the real event tap, macOS reads and SMAppService.
        check(app.contains("#if DEVELOPMENT_SOURCE_CHECKS\n    static var loginItem=LoginItemControl.inert\n    #else\n    static var loginItem=LoginItemControl.live\n    #endif"),
              "G10b", "check builds get the login item that registers nothing")
        check(app.contains("#if DEVELOPMENT_SOURCE_CHECKS\n    static var launchIntentDefaults:UserDefaults? = nil\n    #else\n    static var launchIntentDefaults:UserDefaults? = .standard\n    #endif"),
              "G10", "check builds save and read no launch intent unless a check injects one")
        check(app.contains("static var startInput:(EventCapture)->Bool = { $0.start() }"), "seam", "the app starts the real input")
        // Quitting (and an update's pause) keep the intent; the person's Pause and Stop clear it.
        // gold/int: updates-release (G9) removed the update's own pause; an update pauses only through the quit.
        check(app.contains("self?.leaving=true;self?.withStopIntent(.person) { self?.pauseCapture(\"App closed.\",commitTyping:true) }")
              && !app.contains("pauseForUpdate"), "G10", "quit and update keep the launch intent")
        check(app.contains("if development == nil && !recordingTrial && !anotherCopyOpen {updates.start()}"), "G39", "Sparkle starts only in the copy that holds the history")
        // Settings › Advanced: one switch, no subtext.
        let settings = try String(contentsOfFile: "Sources/MacMemApp/DaydreamSettings.swift", encoding: .utf8)
        let card = settings.components(separatedBy: "if model.openAtLoginAvailable {").dropFirst().first?.components(separatedBy: "SettingsListCard {").first ?? ""
        check(settings.contains("static let openAtLoginTitle = \"Open at login\"") && card.components(separatedBy: "Text(").count == 2
              && card.contains("Toggle(isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))"),
              "G10b", "Settings › Advanced has one switch, \"Open at login\", with no subtext")
        let onboarding = try String(contentsOfFile: "Sources/MacMemApp/DaydreamOnboarding.swift", encoding: .utf8)
        // fix/setup-status: Start Recording and what's-new's Done both end in `finish()`.
        let finish = onboarding.components(separatedBy: "private func finish() {").dropFirst().first?.components(separatedBy: "\n    }").first ?? ""
        check(finish.contains("completed = true\n        model.setupFinished()") && finish.contains("dismiss()") && !finish.contains("Chrome"), "G10b", "setup finishing turns Open at login on (and asks nothing about Chrome)")
    }
}
