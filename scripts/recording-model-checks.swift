// DD-RECIPE: APP
// SPEC 6.3 on real MemoryViewModel instances (private stores under DD_CHECK_OUT, fake clock, fake
// notification center, fake lock reads). Capture is never started: the wake resume runs on a model in
// the download window, where Start refuses before anything records, and every other step keeps
// recording off.
//   A. Download window: the blocker, the Off state and its line, Start refuses and shows the warning,
//      Open Applications Folder is offered in the menu bar card and the permission view.
//   B. Wake: a model that wanted recording pauses for sleep, waits for wake and the settle, tries to start,
//      and when it can't, gives one notice with the reason and what to do; the menu bar's state line says why
//      (one line: the notice is never repeated under it as an orange line).
//   C. Sleep while the person had stopped: nothing is planned, nothing is said.
//   D. A stop the person didn't ask for gives one notice; the person's Stop clears it.
//   E. Sources: the observers route through the wake rules and the person's stops carry their intent; the lock
//      is heard while DayDream is in the background; a failed save never latches.
//   F. A save that failed, then a late lock: recording stays wanted, the lock doesn't write over why it paused,
//      no stale notice, the state says it is trying again, one notice only if it keeps failing, and the person's
//      Stop ends the retries. A real failed save (Coordinator.captureFailed) followed by the recorder's last
//      heartbeat, which saves while paused: the retry is still due and runs. (Nothing here reaches Start: the retry
//      is held back by a missing permission.)
//   G. A lock resume Start refuses (app choices that didn't save): the wake rules try twice, then one notice; the
//      pause line stops promising a start, and the reason Start refused is the orange line beside it. (An import or
//      backup still running is not a refusal: scripts/lifecycle-model-checks.swift has that wait.)
import AppKit
import SwiftUI
import MemoryCore
import MemoryUI

func fail(_ message: String) -> Never {
    fflush(stdout)
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}
@MainActor func expect(_ condition: Bool, _ message: @autoclosure () -> String) { if !condition { fail(message()) } }
func pass(_ message: String) { print("PASS: \(message)"); fflush(stdout) }
@MainActor func tick(_ seconds: Double = 0.05) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
func makePrivateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

@MainActor final class FakeNotices {
    var posted: [RecordingNotice] = []
    var cleared = 0, prepared = 0
    var center: RecordingNoticeCenter {
        RecordingNoticeCenter(prepare: { self.prepared += 1 }, post: { self.posted.append($0) }, clear: { self.cleared += 1 })
    }
}
@MainActor final class FakeWake {
    var locked = false, onConsole = true
    var now = Date(timeIntervalSince1970: 1_790_000_000)
    var pending: [(TimeInterval, () -> Void)] = []
    var system: WakeSystem {
        WakeSystem(screenLocked: { self.locked }, onConsole: { self.onConsole },
                   after: { delay, work in self.pending.append((delay, work)) }, now: { self.now })
    }
    /// Runs the settle work scheduled so far (as the main queue would after its delay).
    func runPending() -> [TimeInterval] {
        let jobs = pending; pending = []
        for (_, work) in jobs { work() }
        return jobs.map(\.0)
    }
}

@main @MainActor struct RecordingModelChecks {
    static func main() async throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
            FileHandle.standardError.write(Data("FAIL: recording-model-checks watchdog expired after 90s\n".utf8))
            exit(2)
        }
        let shared = ["/private/tmp/" + "day" + "dream-", "/tmp/" + "day" + "dream-"]
        guard let outPath = ProcessInfo.processInfo.environment["DD_CHECK_OUT"], outPath.hasPrefix("/"),
              !shared.contains(where: { outPath.hasPrefix($0) }) else {
            fail("DD_CHECK_OUT is not a private output directory; run this check through run-checks.sh")
        }
        let out = URL(fileURLWithPath: outPath, isDirectory: true).appendingPathComponent("recording-model", isDirectory: true)
        try makePrivateDirectory(out)
        try sources()
        let download = try await downloadWindow(out: out)
        let normal = try await applicationsModel(out: out)
        let saving = try await storageFault(out: out)
        let refused = try await lockResumeRefused(out: out)
        for (name, model) in [("download", download), ("applications", normal), ("storage", saving), ("refused", refused)] {
            expect(!model.recording, "\(name) model is recording")
        }
        pass("end: no model recorded; no notification, prompt or System Settings window was shown")
    }

    static func model(out: URL, name: String, location: LaunchLocation) async throws -> (MemoryViewModel, FakeNotices, FakeWake) {
        let memory = out.appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        try makePrivateDirectory(memory)
        setenv("MAC_MEM_HOME", memory.path, 1)
        MemoryViewModel.readLaunchLocation = { location }
        let model = MemoryViewModel()
        MemoryViewModel.readLaunchLocation = { LaunchLocation.read() }
        let notices = FakeNotices(), wake = FakeWake()
        model.noticeCenter = notices.center
        model.wakeSystem = wake.system
        try await tick()
        expect(model.preferencesAvailable && model.development == nil, "\(name): the private store did not open: \(model.status)")
        return (model, notices, wake)
    }

    // MARK: A + B. The download window, and a wake resume that can't start
    static func downloadWindow(out: URL) async throws -> MemoryViewModel {
        let (model, notices, wake) = try await model(out: out, name: "download", location: .diskImage)
        expect(model.launchLocation == .diskImage, "the injected location did not stick")
        expect(model.resumeBlocker() == "Move DayDream to Applications first", "blocker: \(model.resumeBlocker() ?? "nil")")
        expect(model.recordingState == .off(since: nil, reason: "Move DayDream to Applications first."), "state: \(model.recordingState)")
        expect(!model.presentation.canResume, "Start is offered from the download window")
        expect(model.captureActions.openApplications != nil
               && MenuBarMenu.header(model.presentation, now: Date(), timeZone: .current, canSetUp: true,
                                     canOpenApplications: model.captureActions.openApplications != nil).control
               == .fix(title: "Open Applications", fix: .applications),
               "the menu bar panel does not offer Open Applications in the switch's place")
        expect(DaydreamMenuBarPanel.setupLine(model: model, now: Date(), timeZone: .current) == "Move to Applications first",
               "the menu bar icon does not draw its \"!\" with Move to Applications first")
        let menuActions = DaydreamMenuBarPanel.actions(model: model, routes: DaydreamMenuBarRoutes(openWindow: { _ in }))
        expect(menuActions.openApplications != nil, "the menu bar panel's actions lack Open Applications Folder")
        expect(model.permissionRequests?.moveWarning == "Move DayDream to Applications first.", "the permission view gets no move warning")
        model.launchWarningPresented = false
        model.startCapture()
        expect(!model.recording && model.launchWarningPresented, "Start from the download window did not show the warning")
        pass("download window: blocker \"Move DayDream to Applications first\", Off with that line, Start refuses and shows the warning; Open Applications Folder in the menu bar card and the permission view")

        // B. Recording was on (as far as the model knows), the Mac sleeps and wakes.
        model.noteRecording(true)
        expect(model.recordingWanted && notices.prepared == 1, "a start did not mark recording as wanted or prepare the notice center once")
        model.suspend(.sleep)
        expect(model.wake.plan == .record && model.wake.suspended, "sleep did not plan a resume: \(model.wake.plan)")
        expect(model.recordingWanted && notices.posted.isEmpty && model.stopNotice == nil, "sleep itself gave a notice or dropped the wish to record")
        model.unsuspend(.sleep)
        expect(wake.pending.count == 1 && wake.pending.first?.0 == WakeResumeMachine.settleDelay, "wake did not wait the settle delay: \(wake.pending.map(\.0))")
        expect(notices.posted.isEmpty, "a notice before the settle")
        model.launchWarningPresented = false
        _ = wake.runPending()
        expect(!model.recording && model.launchWarningPresented, "the wake resume did not go through Start")
        let expected = RecordingNotice(title: "DayDream didn't start recording again",
            body: "Recording didn't start again after your Mac woke. It stopped because DayDream is running from the download window. Move DayDream to Applications first, then open it from there.")
        expect(notices.posted == [expected], "the resume failure notice: \(notices.posted)")
        expect(wake.pending.isEmpty, "a problem that won't pass by itself was retried")
        // One state, one explanation: the card's state line already says why (Off, "Move DayDream to Applications
        // first."), so the notice is the notification only, never an orange line repeating it.
        expect(model.stopNotice == expected && model.shownIssue == nil && model.recordingInputs.operationalIssue == nil,
               "the notice became the menu bar's orange line: \(model.shownIssue ?? "nil")")
        expect(model.presentation.attentionLine(now: wake.now) == nil, "the menu bar card shows an orange line beside the state: \(model.presentation.attentionLine(now: wake.now) ?? "nil")")
        guard case .off(_, let offLine) = model.recordingState, offLine == LaunchLocation.warning else { fail("the state line does not say why: \(model.recordingState)") }
        expect(!model.recordingWanted && model.wake.plan == .nothing, "the plan outlived its notice")
        pass("wake: sleep plans a resume, wake waits \(WakeResumeMachine.settleDelay) s, Start is tried, and one notice says why and what to do; the menu bar's state line says why, with no orange line")

        // The person's Stop clears the notice (and its notification).
        model.stopCapture()
        expect(model.stopNotice == nil && notices.cleared == 1, "Stop did not clear the notice")
        pass("the person's Stop clears the notice and the delivered notification")
        return model
    }

    // MARK: C + D. Sleep while stopped; a stop the person didn't ask for
    static func applicationsModel(out: URL) async throws -> MemoryViewModel {
        let (model, notices, wake) = try await model(out: out, name: "applications", location: .applications)
        expect(model.launchLocation == .applications && model.resumeBlocker() != "Move DayDream to Applications first", "Applications blocks recording")
        expect(model.captureActions.openApplications == nil && model.permissionRequests?.moveWarning == nil, "Applications offers the move button")
        let before = model.recordingState
        model.suspend(.sleep)
        expect(model.wake.plan == .nothing && model.resumeBlocker() == "Resume after waking", "sleep while stopped planned a resume")
        model.suspend(.screenLock)
        model.unsuspend(.sleep)
        expect(model.wake.suspended && wake.pending.isEmpty, "wake to a locked screen scheduled a start")
        model.unsuspend(.screenLock)
        expect(!model.wake.suspended && wake.pending.isEmpty && notices.posted.isEmpty, "wake while stopped did something")
        expect(model.recordingState == before, "wake changed the state the person left: \(model.recordingState)")
        pass("sleep, lock, wake and unlock while stopped: nothing planned, nothing started, nothing said, the state is unchanged")

        // D. Recording "stops" with no intent: one notice once the recorder settles.
        model.noteRecording(true)
        model.noteRecording(false)
        expect(notices.posted.isEmpty, "the notice went out before the recorder settled")
        try await tick()
        expect(notices.posted.count == 1 && notices.posted[0].title == "DayDream stopped recording", "one stop notice: \(notices.posted)")
        expect(model.stopNotice == notices.posted.first && !model.recordingWanted, "the menu bar line or the wish to record is wrong")
        // The notice is the notification; the menu bar never repeats it as an orange line (the state says why).
        expect(model.shownIssue == nil && model.recordingInputs.operationalIssue == nil, "the stop notice became an orange line: \(model.shownIssue ?? "nil")")
        // A later Start refused for another reason (what startCapture sets) names the real blocker, over the notice.
        for blocker in [MemoryViewModel.choicesUnsavedIssue, MemoryViewModel.summaryIssue, MemoryViewModel.deletionIssue] {
            model.operationalIssue = blocker
            expect(model.presentation.issue == blocker && model.recordingInputs.operationalIssue == blocker,
                   "the stop notice hides the new blocker \(blocker): \(model.presentation.issue ?? "nil")")
        }
        model.operationalIssue = nil
        expect(model.shownIssue == nil && model.recordingInputs.operationalIssue == nil, "with the blocker gone a stale notice line came back")
        model.noteRecording(true)
        expect(model.stopNotice == nil && notices.cleared == 1 && notices.prepared == 1, "recording again did not clear the notice (or asked twice)")
        model.noteRecording(false)
        try await tick()
        expect(notices.posted.count == 2, "a second stop gave no notice")
        model.pauseFor(minutes: 15)
        expect(model.stopNotice == nil && notices.cleared == 2, "the person's Pause did not clear the notice")
        pass("a stop on its own: one notice after the recorder settles, cleared when recording starts again or the person pauses")
        return model
    }

    // MARK: F. A save that failed, then a late lock
    static func storageFault(out: URL) async throws -> MemoryViewModel {
        let (model, notices, wake) = try await model(out: out, name: "storage", location: .applications)
        // Every retry here is held back by a missing permission (setup's Permissions step), so no try reaches Start,
        // whatever this process is allowed.
        let granted = MemoryViewModel.permissionsGranted
        MemoryViewModel.permissionsGranted = { false }
        defer { MemoryViewModel.permissionsGranted = granted }
        guard let coordinator = model.coordinator else { fail("the storage model has no coordinator") }
        model.noteRecording(true)
        expect(model.recordingWanted && !model.recording, "the storage model did not mark recording as wanted")

        // What Coordinator.storageFault does after a failed save: the session pauses with the retry reason, and the app
        // hears of it (twice here, as the session and the heartbeat can both report it at once).
        try coordinator.session.pause(CaptureFault.retryReason)
        coordinator.onStorageFault?()
        coordinator.onStorageFault?()
        expect(model.storageRetry.active && model.storageRetry.failures == 1, "a failed save reported twice at once did not count once: \(model.storageRetry)")
        expect(model.recordingWanted && notices.posted.isEmpty && model.stopNotice == nil, "a failed save gave a notice or dropped the wish to record")
        expect(wake.pending.map(\.0) == [StorageRetry.delays[0]], "the first try is not due in \(StorageRetry.delays[0]) s: \(wake.pending.map(\.0))")
        var inputs = model.recordingInputs
        expect(!inputs.stopped && inputs.sessionState == "paused" && inputs.sessionReason == CaptureFault.retryReason && inputs.operationalIssue == nil,
               "the retry is not shown as a pause with its reason: \(inputs)")
        // This process has no Accessibility (a person recording does): read the state as they see it.
        inputs.resumeUnavailable = nil
        let state = RecordingState.derive(inputs)
        expect(state == .paused(until: nil, since: inputs.pausedAt, reason: "Couldn't save for a moment. Trying again."), "the retry state: \(state)")
        expect(state.attentionLine(issue: inputs.issue, now: wake.now, timeZone: .current) == nil && state.primaryAction == .resume, "the retry state has an orange line or no Resume")
        // A try held back by something the person must fix waits and looks again; it never starts anything.
        _ = wake.runPending()
        expect(!model.recording && coordinator.session.reason == CaptureFault.retryReason && wake.pending.count == 1,
               "a held-back try did not wait for the next one: \(wake.pending.map(\.0))")
        wake.pending = []
        pass("a failed save: recording stays wanted, no notice, Paused \"Couldn't save for a moment. Trying again.\" with no orange line, the first try in \(Int(StorageRetry.delays[0])) s")

        // The lock notice arrives after the failure. Nothing is live, so nothing is paused over the save's reason, and
        // unlocking plans the start.
        model.suspend(.screenLock)
        expect(coordinator.session.reason == CaptureFault.retryReason, "the lock wrote over why recording paused: \(coordinator.session.reason)")
        expect(model.wake.plan == .record && model.recordingWanted && model.stopNotice == nil && notices.posted.isEmpty,
               "the late lock dropped the wish to record or gave a notice: plan \(model.wake.plan)")
        model.unsuspend(.screenLock)
        expect(wake.pending.map(\.0).contains(WakeResumeMachine.settleDelay), "the unlock did not plan the start: \(wake.pending.map(\.0))")
        wake.pending = [] // never run here: the settle would call Start
        expect(model.shownIssue == nil && model.stopNotice == nil, "a stale notice sits beside the pause")
        pass("a late lock after a failed save: the save's reason stays, the unlock plans the start, no stale \"couldn't save your history\" line")

        // It keeps failing for two minutes: one calm notice, and the line says it tries every minute.
        wake.now = wake.now.addingTimeInterval(StorageRetry.persistentAfter + 10)
        model.storageFaulted()
        expect(notices.posted == [RecordingNotice.storageRetrying] && model.stopNotice == .storageRetrying, "two minutes of failing: \(notices.posted)")
        expect(model.shownIssue == nil, "the notice became an orange line")
        inputs = model.recordingInputs; inputs.resumeUnavailable = nil
        expect(RecordingState.derive(inputs).detail(now: wake.now, timeZone: .current) == "Can't save right now. Trying again every minute.",
               "the persistent line: \(RecordingState.derive(inputs))")
        wake.now = wake.now.addingTimeInterval(60)
        model.storageFaulted()
        expect(notices.posted.count == 1, "a second notice went out")
        expect(wake.pending.last?.0 == 60, "tries are not once a minute: \(wake.pending.map(\.0))")
        wake.pending = []
        // Recording starts again: the notice goes.
        let cleared = notices.cleared
        model.noteRecording(true)
        expect(model.stopNotice == nil && notices.cleared == cleared + 1 && !model.storageRetry.active, "recording again did not clear the notice")
        pass("saves that keep failing: one notice after two minutes (\"\(RecordingNotice.storageRetrying.title)\"), tries once a minute, cleared when recording starts again")

        // A real failed save, through the coordinator, then the recorder's last heartbeat: EventCapture's timer runs
        // reconcileResume once more before it stops itself, and that heartbeat saves (the file is fine by then). It is
        // no recovery: the try is still due, and it runs. The same for five busy saves in a minute. (The status refresh
        // is left out, as its permission read varies by Mac.)
        let refresh = coordinator.onStateChanged
        coordinator.onStateChanged = nil
        let faults: [(String, () -> Void)] = [
            ("a failed save", { coordinator.captureFailed(MemError.database("write failed (code 10)"), recording: true) }),
            ("five busy saves in a minute", { for _ in 0..<CaptureFaultBudget.limit { coordinator.captureFailed(MemError.busy("write failed (code 5)"), recording: true) } }),
        ]
        for (name, fault) in faults {
            model.storageRecovered()
            wake.now = wake.now.addingTimeInterval(StorageRetry.stableAfter + 1) // a new run of failures
            fault()
            expect(coordinator.session.state == "paused" && coordinator.session.reason == CaptureFault.retryReason && model.storageRetry.active
                   && model.recordingWanted && wake.pending.map(\.0) == [StorageRetry.delays[0]],
                   "\(name) did not pause for a try in \(StorageRetry.delays[0]) s: \(coordinator.session.reason), \(model.storageRetry), \(wake.pending.map(\.0))")
            coordinator.reconcileResume()
            expect(model.storageRetry.active && model.recordingWanted, "\(name): the heartbeat while paused ended the retry: \(model.storageRetry)")
            inputs = model.recordingInputs; inputs.resumeUnavailable = nil
            expect(RecordingState.derive(inputs).detail(now: wake.now, timeZone: .current) == RecordingCopy.savingRetry,
                   "\(name): the line after the heartbeat: \(RecordingState.derive(inputs))")
            // The try runs (held back by the missing permission, it looks again in a minute). A try the heartbeat had
            // cancelled would do nothing, and nothing would ever try again.
            _ = wake.runPending()
            expect(wake.pending.map(\.0) == [StorageRetry.waitDelay], "\(name): the try did not run after the heartbeat: \(wake.pending.map(\.0))")
            wake.pending = []
        }
        coordinator.onStateChanged = refresh
        // A due try while the screen is locked (its notice not handled yet) starts nothing: the wake rules take it.
        wake.locked = true
        wake.now = wake.now.addingTimeInterval(StorageRetry.waitDelay)
        model.storageFaulted()
        _ = wake.runPending()
        expect(model.wake.active.contains(.screenLock) && model.wake.plan == .record && model.recordingWanted && model.storageRetry.active,
               "a try behind the lock screen did not go to the wake rules: \(model.wake.active), plan \(model.wake.plan)")
        wake.pending = []
        model.unsuspend(.screenLock)
        wake.locked = false
        wake.pending = [] // never run here: the settle would call Start
        pass("a failed save through the coordinator, then the recorder's last heartbeat: the try is still due and runs (also after five busy saves); behind the lock screen the wake rules take it")

        // The person's Stop ends the retries, and nothing pending starts anything. (The session reports the next failed
        // save the way the coordinator does; the status refresh is left out, as its permission read varies by Mac.)
        try coordinator.session.pause(CaptureFault.retryReason)
        coordinator.onStorageFault?()
        expect(model.storageRetry.active, "a new failure did not start the retries again")
        model.stopCapture()
        guard !model.storageRetry.active, !model.recordingWanted, model.wake.plan == .nothing else { fail("the person's Stop did not end the retries") }
        _ = wake.runPending()
        expect(!model.recording && coordinator.session.state == "off" && wake.pending.isEmpty, "a try ran after the person's Stop")
        pass("the person's Stop ends the retries; nothing pending starts again")
        return model
    }

    // MARK: G. A lock resume that Start refuses
    static func lockResumeRefused(out: URL) async throws -> MemoryViewModel {
        let (model, notices, wake) = try await model(out: out, name: "refused", location: .applications)
        guard let coordinator = model.coordinator else { fail("the refused model has no coordinator") }
        // Recording was on, and the screen locked: the live recorder paused with the lock's reason (written here as the
        // recorder's pause writes it; nothing records in this check).
        model.noteRecording(true)
        model.suspend(.screenLock)
        try coordinator.session.pause(WakeSuspension.screenLock.pauseReason)
        model.stopped = false // a pause, not a stop (pauseCapture of a live recorder)
        expect(model.wake.plan == .record, "the lock did not plan a resume: \(model.wake.plan)")
        // Unlocked while an app choice differs from the saved one: Start refuses with that reason (startCapture's
        // operational issue), which stays until the choice is saved or undone.
        let savedApps = model.blockedApps
        model.blockedApps = "com.example.unsaved"
        defer { model.blockedApps = savedApps }
        model.unsuspend(.screenLock)
        try await tick()
        expect(wake.runPending() == [WakeResumeMachine.settleDelay], "the unlock did not settle first")
        let issue = MemoryViewModel.choicesUnsavedIssue
        expect(!model.recording && model.operationalIssue == issue, "Start did not refuse for the unsaved choice: \(model.operationalIssue ?? "nil")")
        expect(wake.pending.map(\.0) == [WakeResumeMachine.retryDelay] && notices.posted.isEmpty, "the refused start was not tried once more: \(wake.pending.map(\.0))")
        _ = wake.runPending()
        expect(notices.posted.count == 1 && notices.posted[0].title == RecordingNotice.notRestartedTitle && !model.recordingWanted && model.wake.plan == .nothing,
               "the second refusal did not end in one notice: \(notices.posted)")
        // The pause no longer says the lock (nothing resumes it now): it says recording didn't start again, and why Start
        // refused is the orange line beside it. The notice itself is the notification, never that line.
        expect(coordinator.session.state == "paused" && coordinator.session.reason == RecordingStopCause.notResumedReason,
               "the lock's reason still promises a resume: \(coordinator.session.reason)")
        var inputs = model.recordingInputs
        inputs.resumeUnavailable = nil // this process has no Accessibility (a person recording does)
        let state = RecordingState.derive(inputs)
        expect(state == .paused(until: nil, since: inputs.pausedAt, reason: RecordingCopy.notResumed) && state.primaryAction == .resume,
               "the state after the refused resume: \(state)")
        expect(model.shownIssue == issue && state.attentionLine(issue: inputs.issue, now: wake.now, timeZone: .current) == RecordingCopy.issue(issue),
               "the reason Start refused is hidden beside the pause: \(state.attentionLine(issue: inputs.issue, now: wake.now, timeZone: .current) ?? "nil")")
        pass("a lock resume Start refuses: tried twice, one notice, the pause says \"\(RecordingCopy.notResumed)\" and the orange line says why (\"\(issue)\")")
        model.stopCapture()
        return model
    }

    // MARK: E. Sources
    static func sources() throws {
        let app = try String(contentsOfFile: "Sources/MacMemApp/MacMemApp.swift", encoding: .utf8)
        for pin in ["self?.suspend(.sleep)", "self?.unsuspend(.sleep)", "self?.suspend(.userSwitch)", "self?.unsuspend(.userSwitch)",
                    "self?.suspend(.screenLock)", "self?.unsuspend(.screenLock)", "noteRecording(recording)",
                    "withStopIntent(.person) { pauseCapture(\"Paused by you\",commitTyping:true) }",
                    "self?.leaving=true;self?.withStopIntent(.person) { self?.pauseCapture(\"App closed.\",commitTyping:true) }",
                    "guard !launchLocation.blocksRecording else {launchWarningPresented=true;refreshCaptureStatus();return}",
                    "if launchLocation.blocksRecording { resumeExplanation=LaunchLocation.detail; return LaunchLocation.blockerValue }",
                    ".alert(LaunchLocation.warning,isPresented:$model.launchWarningPresented)"] {
            expect(app.contains(pin), "MacMemApp.swift lost: \(pin)")
        }
        expect(!app.contains("Awake. Resume explicitly after sleep."), "wake still pauses a second time")
        // golden test 5 (G9): nothing pauses for an update before DayDream quits; the quit's own pause (above) does it.
        expect(!app.contains("pauseForUpdate") && !app.contains("pauseCapture(\"Paused for update."), "an update still pauses recording before the quit")
        let stop = app.components(separatedBy: "func stopCapture() {")[1].components(separatedBy: "func startCapture()")[0]
        expect(stop.contains("personActed()") && stop.contains("withStopIntent(.person) {"), "Stop is not the person's")
        let producer = app.components(separatedBy: "stopProducer:{")[1].components(separatedBy: "preferenceSave?.onChange")[0]
        expect(producer.contains("self.withStopIntent(.person) {"), "a saved setting's stop is not the person's")
        // Setup's "Open Settings" brings the one main window forward and opens the page for the issue: the
        // overview (whose status line says what stops recording) for a blocker, never Advanced.
        // int/v1: setup keeps ux/v1's start blocker, so the link shows only for a blocker setup can't fix
        // itself (`issue.settings`) and routes by that blocker's text.
        let onboarding = try String(contentsOfFile: "Sources/MacMemApp/DaydreamOnboarding.swift", encoding: .utf8)
        expect(!onboarding.contains("openWindow(id: \"memory\")") && onboarding.contains("DaydreamMainWindow.show(openWindow)"),
               "setup opens a second main window for Settings")
        expect(DaydreamOnboarding.openSettingsTitle == "Open Settings"
               && onboarding.contains("if let issue = startBlocker, issue.settings {")
               && onboarding.contains("Button(Self.openSettingsTitle) { showSettings(Self.settingsSection(for: issue.text)) }")
               && DaydreamSettingsPage(section: DaydreamOnboarding.settingsSection(for: "Move DayDream to Applications first. Review Recording settings before starting.")) == .overview
               && DaydreamSettingsPage(section: DaydreamOnboarding.settingsSection(for: "Review and save your app choices before recording.")) == .apps
               && DaydreamSettingsPage(section: DaydreamOnboarding.settingsSection(for: "Finish the current history, backup, or replacement operation first.")) == .advanced
               && DaydreamSettingsPage(section: DaydreamOnboarding.settingsSection(for: "Storage unavailable. Review Recording settings before starting.")) == .overview
               && DaydreamSettingsPage(section: DaydreamOnboarding.settingsSection(for: nil)) == .overview,
               "setup's Open Settings goes to the wrong page")
        // The lock is heard while DayDream is in the background (the block observers' default suspension behavior held
        // it until the person clicked into DayDream), and a missed one is read from the system while something is live.
        let wakeSystem = try String(contentsOfFile: "Sources/MacMemApp/WakeSystem.swift", encoding: .utf8)
        expect(wakeSystem.components(separatedBy: "suspensionBehavior: .deliverImmediately").count == 3, "the lock and unlock observers are not delivered immediately")
        expect(app.contains("lockObserver=ScreenLockObserver(") && !app.contains("addObserver(forName:WakeSystem.screenLocked")
               && !app.contains("addObserver(forName:WakeSystem.screenUnlocked"), "the lock still goes through a block observer")
        expect(app.contains("suspended:wake.suspended || !awake || wakeSystem.screenLocked()"), "a stop while the screen is locked is not read as the lock")
        expect(app.contains("RunLoop.main.add(timer,forMode:.common)") && app.contains("private func catchUpSuspension()"), "no lock watch while recording")
        // Only what is live pauses for a lock, and a failed save never blocks Start or latches.
        expect(app.contains("let active=recording || pauseUntil != nil") && !app.contains("capture != nil || pauseUntil"), "a stopped recorder still counts as live")
        let blocker = app.components(separatedBy: "func resumeBlocker(waiting:Bool=false,permission:Bool=true)->String? {")[1].components(separatedBy: "func cancelTimedPause()")[0]
        expect(!blocker.contains("\"error\"") && !blocker.contains("Storage needs attention"), "a failed save still blocks Start")
        expect(!app.contains("Memory read failed. Recording paused."), "a failed timeline read still pauses recording")
        expect(app.contains("var shownIssue:String? { operationalIssue }"), "a stop notice is shown as an orange line again")
        expect(app.contains("coordinator?.onHealthy = { [weak self] in guard let self, self.recording else {return}; self.storageRecovered() }"),
               "a heartbeat while paused can end the save retries")
        expect(RecordingStopCause.infer(sessionState: "paused", sessionReason: RecordingStopCause.notResumedReason, accessibility: true,
                                        inputMonitoring: true, blocker: nil, suspended: false) == .other
               && WakeSuspension.allCases.allSatisfy { RecordingStopCause.resumesByItself.contains($0.pauseReason) }
               && [CaptureFault.retryReason, CaptureFault.persistentReason, CaptureFault.fullReason].allSatisfy(RecordingStopCause.resumesByItself.contains)
               && RecordingCopy.pauseReason(RecordingStopCause.notResumedReason) == RecordingCopy.notResumed,
               "the reason for a start that won't come is not its own")
        for file in ["Coordinator", "EventCapture", "WebTypingRoute"] {
            let text = try String(contentsOfFile: "Sources/MacMemApp/\(file).swift", encoding: .utf8)
            expect(!text.contains("captureFailed()"), "\(file).swift reports a failed write without its error")
        }
        // The retry reasons are one set of words in three places (MemoryCore, the wake rules, the menu bar copy).
        for (reason, line) in [(CaptureFault.retryReason, RecordingCopy.savingRetry), (CaptureFault.persistentReason, RecordingCopy.savingRetryPersistent),
                               (CaptureFault.fullReason, RecordingCopy.savingRetryFull)] {
            expect(RecordingStopCause.storageReasons.contains(reason), "the wake rules don't know \(reason)")
            expect(RecordingCopy.pauseReason(reason) == line, "the menu bar copy doesn't map \(reason)")
        }
        let notices = [RecordingNotice.storageRetrying] + [RecordingStopCause.storage, .other, .input].compactMap { RecordingNotice.stopped($0, resumeTitle: "Resume Recording") }
        expect(notices.allSatisfy { !$0.body.contains("Quit and reopen") }, "a notice still says to quit and reopen")
        let menu = try String(contentsOfFile: "Sources/MacMemApp/MenuBarContent.swift", encoding: .utf8)
        expect(menu.contains("actions.openApplications = model.openApplicationsAction"), "the menu bar card lacks Open Applications Folder")
        pass("sources: sleep, lock and user-switch observers go through the wake rules; the lock is delivered immediately; the person's stops carry their intent; a failed save never latches; the download window blocks Start")
    }
}
