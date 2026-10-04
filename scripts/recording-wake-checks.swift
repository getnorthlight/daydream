// DD-RECIPE: SRC Sources/MacMemApp/WakeResume.swift Sources/MacMemApp/LaunchLocation.swift
//
// SPEC 6.3 R1 and R3, pure: the sleep / screen lock / user switch state machine, the rule for when a
// person gets a "stopped recording" notice (and its exact text), and the download-window detection.
// Compiled with only the two app files above (Foundation). No app, no permissions, no capture, no
// notification, no clock: every date is fixed.
//
//   swiftc -parse-as-library Sources/MacMemApp/WakeResume.swift Sources/MacMemApp/LaunchLocation.swift \
//     scripts/recording-wake-checks.swift -o recording-wake && ./recording-wake
import Foundation

@main enum RecordingWakeChecks {
    static var failures = 0
    static var passes = 0
    static func check(_ ok: Bool, _ name: String, _ got: @autoclosure () -> String = "") {
        if ok { passes += 1; print("PASS " + name) } else {
            failures += 1
            FileHandle.standardError.write(Data(("FAIL: " + name + (got().isEmpty ? "" : " (got: " + got() + ")") + "\n").utf8))
        }
    }
    static func equal<T: Equatable>(_ got: T, _ want: T, _ name: String) { check(got == want, name, "\(got)") }

    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    typealias M = WakeResumeMachine
    static let settle = M.settleDelay

    static func main() {
        machine()
        stopCauses()
        notices()
        storageRetry()
        launchLocation()
        newEpisodeRetries()
        launchResume()
        if failures > 0 { FileHandle.standardError.write(Data("\(failures) recording-wake checks failed\n".utf8)); exit(1) }
        print("PASS all \(passes) recording-wake checks")
    }

    // MARK: The state machine

    static func machine() {
        // 1. Recording, sleep, wake: pause, settle 3 s, start again, done.
        var m = M()
        equal(m.begin(.sleep, wantsRecording: true, timedPauseUntil: nil, recorderActive: true), [.pause(.sleep)], "sleep while recording pauses")
        check(m.suspended && m.plan == .record, "sleep while recording plans a resume", "\(m.plan)")
        var effects = m.end(.sleep)
        guard case .settle(let delay, let token)? = effects.first, effects.count == 1 else { return check(false, "wake settles first", "\(effects)") }
        equal(delay, settle, "wake waits the settle delay before starting")
        equal(m.settled(token: token, screenLocked: false, onConsole: true, now: t0), [.start], "after the settle, recording starts again by itself")
        equal(m.started(succeeded: true, cause: .other, resumeTitle: "Resume Recording"), [], "a start that worked says nothing")
        equal(m.plan, .nothing, "the plan is used once")

        // 2. Paused or stopped by the person: sleep and wake leave it alone and say nothing.
        m = M()
        equal(m.begin(.sleep, wantsRecording: false, timedPauseUntil: nil, recorderActive: false), [], "sleep while off does nothing")
        equal(m.end(.sleep), [], "wake while off does nothing (no notice, no start)")
        equal(m.plan, .nothing, "nothing planned when the person had paused")

        // 3. A suspension that already paused recording (EventCapture's own observer ran first) still counts as on.
        m = M()
        equal(m.begin(.sleep, wantsRecording: true, timedPauseUntil: nil, recorderActive: false), [], "nothing left to pause")
        equal(m.plan, .record, "wanted recording is resumed even when the recorder had already paused")

        // 4. Lock, then sleep, then wake, then unlock: recording waits for the unlock.
        m = M()
        equal(m.begin(.screenLock, wantsRecording: true, timedPauseUntil: nil, recorderActive: true), [.pause(.screenLock)], "lock pauses")
        equal(m.begin(.sleep, wantsRecording: false, timedPauseUntil: nil, recorderActive: false), [], "sleep after lock: nothing more to pause")
        equal(m.plan, .record, "a second suspension keeps the first plan")
        equal(m.end(.sleep), [], "wake to a locked screen does not start")
        effects = m.end(.screenLock)
        guard case .settle(_, let t2)? = effects.first else { return check(false, "unlock settles", "\(effects)") }
        equal(m.settled(token: t2, screenLocked: false, onConsole: true, now: t0), [.start], "unlock after wake starts again")

        // 5. Woke to a lock screen without a lock notice: the settle read catches it and waits for unlock.
        m = M()
        _ = m.begin(.sleep, wantsRecording: true, timedPauseUntil: nil, recorderActive: true)
        guard case .settle(_, let t3)? = m.end(.sleep).first else { return check(false, "wake settles") }
        equal(m.settled(token: t3, screenLocked: true, onConsole: true, now: t0), [], "a locked screen after wake: no start yet")
        check(m.active == [.screenLock], "the lock is now a suspension", "\(m.active)")
        guard case .settle(_, let t4)? = m.end(.screenLock).first else { return check(false, "unlock settles") }
        equal(m.settled(token: t4, screenLocked: false, onConsole: true, now: t0), [.start], "the unlock then starts recording")

        // 6. Fast user switching: away and back.
        m = M()
        equal(m.begin(.userSwitch, wantsRecording: true, timedPauseUntil: nil, recorderActive: true), [.pause(.userSwitch)], "switching users pauses")
        guard case .settle(_, let t5)? = m.end(.userSwitch).first else { return check(false, "switch back settles") }
        equal(m.settled(token: t5, screenLocked: false, onConsole: false, now: t0), [], "not on screen yet: wait")
        check(m.active == [.userSwitch], "another user on screen is a suspension", "\(m.active)")
        equal(m.reconcile(screenLocked: false, onConsole: false), [], "reconcile keeps it while another user is on screen")
        effects = m.reconcile(screenLocked: false, onConsole: true)
        guard case .settle(_, let t6)? = effects.first else { return check(false, "a missed switch-back notice is caught by the reconcile read", "\(effects)") }
        equal(m.settled(token: t6, screenLocked: false, onConsole: true, now: t0), [.start], "back on screen: start again")

        // 7. A missed unlock notice is caught too; sleep is never cleared by a read.
        m = M()
        _ = m.begin(.screenLock, wantsRecording: true, timedPauseUntil: nil, recorderActive: true)
        _ = m.begin(.sleep, wantsRecording: true, timedPauseUntil: nil, recorderActive: false)
        equal(m.reconcile(screenLocked: false, onConsole: true), [], "a read never ends sleep")
        check(m.active == [.sleep], "the unlock read cleared the lock only", "\(m.active)")

        // 8. A stale settle never starts anything: the Mac slept again before it ran.
        m = M()
        _ = m.begin(.sleep, wantsRecording: true, timedPauseUntil: nil, recorderActive: true)
        guard case .settle(_, let old)? = m.end(.sleep).first else { return check(false, "wake settles") }
        _ = m.begin(.sleep, wantsRecording: true, timedPauseUntil: nil, recorderActive: false)
        equal(m.settled(token: old, screenLocked: false, onConsole: true, now: t0), [], "a settle from before the next sleep is ignored")
        guard case .settle(_, let new)? = m.end(.sleep).first else { return check(false, "the second wake settles") }
        equal(m.settled(token: new, screenLocked: false, onConsole: true, now: t0), [.start], "the latest wake starts")

        // 9. The person acts during the settle: their choice wins.
        m = M()
        _ = m.begin(.sleep, wantsRecording: true, timedPauseUntil: nil, recorderActive: true)
        guard case .settle(_, let t7)? = m.end(.sleep).first else { return check(false, "wake settles") }
        m.personActed()
        equal(m.settled(token: t7, screenLocked: false, onConsole: true, now: t0), [], "a pause or stop during the settle cancels the resume")

        // 10. A wake with no sleep before it does nothing.
        m = M()
        equal(m.end(.sleep), [], "a wake notice without a sleep is ignored")
        equal(m.end(.screenLock), [], "an unlock without a lock is ignored")

        // 11. A timed pause: picked up until the same time, or recording starts if it ended meanwhile.
        let until = t0.addingTimeInterval(15 * 60)
        m = M()
        equal(m.begin(.sleep, wantsRecording: false, timedPauseUntil: until, recorderActive: true), [.pause(.sleep)], "sleep during a timed pause pauses it")
        equal(m.plan, .timedPause(until: until), "the timed pause's end is kept")
        guard case .settle(_, let t8)? = m.end(.sleep).first else { return check(false, "wake settles") }
        equal(m.settled(token: t8, screenLocked: false, onConsole: true, now: t0.addingTimeInterval(60)), [.resumeTimedPause(until: until)],
              "woke before the pause ended: the pause goes on until the same time")
        equal(m.started(succeeded: true, cause: .other, resumeTitle: "Resume Recording"), [], "the picked-up pause says nothing")
        m = M()
        _ = m.begin(.sleep, wantsRecording: false, timedPauseUntil: until, recorderActive: true)
        guard case .settle(_, let t9)? = m.end(.sleep).first else { return check(false, "wake settles") }
        equal(m.settled(token: t9, screenLocked: false, onConsole: true, now: until.addingTimeInterval(1)), [.start],
              "woke after the pause ended: recording starts, as the pause promised")
        // A second suspension during the settle keeps the timed plan (the pause was already cancelled).
        m = M()
        _ = m.begin(.sleep, wantsRecording: false, timedPauseUntil: until, recorderActive: true)
        _ = m.end(.sleep)
        _ = m.begin(.screenLock, wantsRecording: false, timedPauseUntil: nil, recorderActive: false)
        equal(m.plan, .timedPause(until: until), "a lock during the settle keeps the timed pause's plan")

        // 12. It can't start again: one retry for a passing problem, then one notice.
        m = M()
        _ = m.begin(.sleep, wantsRecording: true, timedPauseUntil: nil, recorderActive: true)
        guard case .settle(_, let ta)? = m.end(.sleep).first else { return check(false, "wake settles") }
        _ = m.settled(token: ta, screenLocked: false, onConsole: true, now: t0)
        effects = m.started(succeeded: false, cause: .other, resumeTitle: "Resume Recording")
        guard case .settle(let retry, let tb)? = effects.first else { return check(false, "a failed start is tried once more", "\(effects)") }
        equal(retry, M.retryDelay, "the retry waits the retry delay")
        equal(m.settled(token: tb, screenLocked: false, onConsole: true, now: t0), [.start], "the retry starts")
        effects = m.started(succeeded: false, cause: .other, resumeTitle: "Resume Recording")
        equal(effects, [.notify(RecordingNotice(title: "DayDream didn't start recording again",
                                                body: "Recording didn't start again after your Mac woke. Choose Resume Now from DayDream in the menu bar."))],
              "the second failure gives one notice")
        equal(m.plan, .nothing, "no more tries after the notice")
        equal(m.started(succeeded: false, cause: .other, resumeTitle: "Resume Recording"), [], "never a second notice")

        // 13. A missing permission is not retried: the notice says which one and what to do.
        m = M()
        _ = m.begin(.screenLock, wantsRecording: true, timedPauseUntil: nil, recorderActive: true)
        guard case .settle(_, let tc)? = m.end(.screenLock).first else { return check(false, "unlock settles") }
        _ = m.settled(token: tc, screenLocked: false, onConsole: true, now: t0)
        equal(m.started(succeeded: false, cause: .permission(accessibility: true, inputMonitoring: false), resumeTitle: "Start Recording"),
              [.notify(RecordingNotice(title: "DayDream didn't start recording again",
                                       body: "Recording didn't start again after you unlocked your Mac. It stopped because Accessibility is off for DayDream. Choose Turn on Accessibility from DayDream in the menu bar."))],
              "permission lost while locked: one notice at once, no retry")

        // 14. A start that failed on a save: StorageRetry takes over. No notice, no settle retry.
        m = M()
        _ = m.begin(.sleep, wantsRecording: true, timedPauseUntil: nil, recorderActive: true)
        guard case .settle(_, let td)? = m.end(.sleep).first else { return check(false, "wake settles") }
        _ = m.settled(token: td, screenLocked: false, onConsole: true, now: t0)
        equal(m.started(succeeded: false, cause: .storage, resumeTitle: "Resume Recording"), [.retryStorage],
              "a save that failed after wake hands over to the storage retry, with no notice")
        equal(m.plan, .nothing, "the wake plan is done once the storage retry has it")

        // 15. The lock pause says "Resumes after unlock", so a live recorder always gets a plan that resumes, even
        // when the person's choice was lost (a fault cleared it, or a late lock arrived after one).
        m = M()
        equal(m.begin(.screenLock, wantsRecording: false, timedPauseUntil: nil, recorderActive: true), [.pause(.screenLock)],
              "a live recorder is paused by the lock")
        equal(m.plan, .record, "a live recorder paused by the lock resumes after unlock")
        guard case .settle(_, let te)? = m.end(.screenLock).first else { return check(false, "unlock settles after a lock that paused a live recorder") }
        equal(m.settled(token: te, screenLocked: false, onConsole: true, now: t0), [.start], "unlock starts the recorder the lock paused")
        m = M()
        equal(m.begin(.screenLock, wantsRecording: false, timedPauseUntil: nil, recorderActive: false), [], "nothing live: the lock pauses nothing")
        equal(m.plan, .nothing, "nothing live and nothing wanted: no plan")
        equal(m.end(.screenLock), [], "and the unlock starts nothing")
    }

    // MARK: Why recording stopped

    static func stopCauses() {
        func infer(state: String? = "paused", reason: String? = nil, ax: Bool? = true, im: Bool? = true, blocker: String? = nil, suspended: Bool = false) -> RecordingStopCause {
            RecordingStopCause.infer(sessionState: state, sessionReason: reason, accessibility: ax, inputMonitoring: im, blocker: blocker, suspended: suspended)
        }
        equal(infer(suspended: true), .suspension, "any stop during a suspension is the suspension")
        equal(infer(reason: "System slept or session became inactive. Resume explicitly."), .suspension, "EventCapture's own sleep pause is a suspension")
        for s in WakeSuspension.allCases { equal(infer(reason: s.pauseReason), .suspension, "the \(s) pause reason is a suspension") }
        equal(infer(reason: "Paused for preference save; resume explicitly."), .person, "a saved setting is the person's")
        for r in RecordingStopCause.personReasons { equal(infer(state: "paused", reason: r, ax: false), .person, "the person's own stop, even with a permission off: " + r) }
        equal(infer(blocker: "Move DayDream to Applications first"), .moveApp, "the download window")
        equal(infer(blocker: RecordingStopCause.restoreBlocker), .restore, "a restore waiting for review (Extra 4)")
        equal(infer(state: "recording", ax: false), .permission(accessibility: true, inputMonitoring: false), "Accessibility turned off while recording")
        equal(infer(state: "permission_denied", reason: "Permission was revoked. Resume explicitly after granting it.", im: false),
              .permission(accessibility: false, inputMonitoring: true), "Input Monitoring revoked")
        equal(infer(state: "permission_denied", ax: nil, im: nil), .permission(accessibility: false, inputMonitoring: false), "denied, reads unknown")
        equal(infer(state: "error", reason: "A durable write failed. Recording stopped; resume explicitly."), .storage, "a failed write")
        for r in RecordingStopCause.storageReasons { equal(infer(reason: r), .storage, "storage reason: " + r) }
        equal(infer(blocker: "Storage needs attention"), .storage, "the storage blocker")
        equal(infer(reason: "Input tap was disabled. Resume explicitly."), .input, "the input tap was disabled")
        equal(infer(reason: "Input event tap unavailable. No recording started."), .input, "the input tap was unavailable")
        equal(infer(reason: "Something new"), .other, "anything else")
        // Once recording won't start again by itself, the app rewrites a pause reason that promised it would. The new
        // reason is neither a suspension nor a failed save, so nothing reads it as one that resumes.
        equal(infer(state: "paused", reason: RecordingStopCause.notResumedReason), .other, "a start that won't come is not a suspension or a save")
        check(!RecordingStopCause.resumesByItself.contains(RecordingStopCause.notResumedReason), "the reason for a start that won't come promises nothing")
        for s in WakeSuspension.allCases { check(RecordingStopCause.resumesByItself.contains(s.pauseReason), "the \(s) pause promises a start: " + s.pauseReason) }
        check(RecordingStopCause.resumesByItself.contains(RecordingStopCause.captureSuspensionReason), "EventCapture's own sleep pause promises a start")
        for r in ["Storage write failed. Retrying automatically.", "Storage keeps failing. Retrying every minute.", "Storage full. Retrying automatically."] {
            check(RecordingStopCause.resumesByItself.contains(r) && RecordingStopCause.storageReasons.contains(r), "the save retry promises a start: " + r)
        }
        check(RecordingStopCause.resumesByItself.isDisjoint(with: RecordingStopCause.personReasons), "no pause of the person's promises a start")
        check(!RecordingStopCause.permission(accessibility: true, inputMonitoring: true).retryable && !RecordingStopCause.moveApp.retryable && !RecordingStopCause.restore.retryable
              && RecordingStopCause.storage.retryable && RecordingStopCause.other.retryable, "only passing problems are retried")
    }

    // MARK: Notices

    static func notices() {
        let r = "Resume Recording", s = "Start Recording"
        equal(RecordingNotice.stopped(.person, resumeTitle: r), nil, "no notice when the person paused, stopped or quit")
        equal(RecordingNotice.stopped(.suspension, resumeTitle: r), nil, "no notice for sleep, lock or a user switch (it resumes)")
        let expected: [(RecordingStopCause, String, String)] = [
            (.permission(accessibility: true, inputMonitoring: false), s,
             "Recording stopped because Accessibility is off for DayDream. Choose Turn on Accessibility from DayDream in the menu bar."),
            (.permission(accessibility: false, inputMonitoring: true), s,
             "Recording stopped because Input Monitoring is off for DayDream. Choose Turn on Input Monitoring from DayDream in the menu bar."),
            (.permission(accessibility: true, inputMonitoring: true), s,
             "Recording stopped because Accessibility and Input Monitoring are off for DayDream. Choose Turn on Accessibility from DayDream in the menu bar."),
            (.permission(accessibility: false, inputMonitoring: false), s,
             "Recording stopped because a macOS permission is off for DayDream. Choose Allow… from DayDream in the menu bar."),
            // gold/r2-copy-checks: a lost keyboard and mouse connection leaves recording Paused (EventCapture.tapDisabled):
            // the notice says paused, as the menu bar does, in its words, and names its Resume Now.
            (.input, r, "Recording paused because DayDream can't see your keys or clicks. Choose Resume Now from DayDream in the menu bar."),
            (.input, s, "Recording stopped because DayDream can't see your keys or clicks. Turn DayDream on in the menu bar."),
            (.moveApp, s, "Recording stopped because DayDream is running from the download window. Move DayDream to Applications first, then open it from there."),
            (.other, r, "Recording paused on its own. Choose Resume Now from DayDream in the menu bar."),
            // Off (nothing paused): the panel's switch.
            (.other, s, "Recording stopped on its own. Turn DayDream on in the menu bar."),
        ]
        var all: [RecordingNotice] = []
        for (cause, title, body) in expected {
            guard let notice = RecordingNotice.stopped(cause, resumeTitle: title) else { check(false, "a notice for \(cause)"); continue }
            // Paused (Resume Recording) says paused; Off says stopped: the notice never says a state the menu bar doesn't.
            equal(notice.title, title == r ? "DayDream paused recording" : "DayDream stopped recording", "stop notice title for \(cause) (\(title))")
            equal(notice.body, body, "stop notice text for \(cause)")
            equal(notice.line, notice.body, "the line is the notice text for \(cause)")
            all.append(notice)
        }
        all.append(RecordingNotice.resumeFailed(after: [.sleep, .screenLock], cause: .moveApp, resumeTitle: s))
        equal(all.last?.body, "Recording didn't start again after your Mac woke. It stopped because DayDream is running from the download window. Move DayDream to Applications first, then open it from there.",
              "sleep wins the wording when the Mac also locked")
        // A failed save is never a "stopped" notice: recording starts again by itself, and only saves that keep
        // failing give the one calm notice. No "Quit and reopen": there is nothing for the person to do.
        equal(RecordingNotice.stopped(.storage, resumeTitle: s), nil, "no stop notice for a failed save (it starts again by itself)")
        equal(RecordingNotice.resumeFailed(after: [.screenLock], cause: .storage, resumeTitle: s), .storageRetrying,
              "a failed save after unlock gives the retrying notice, not a stop notice")
        equal(RecordingNotice.timedPauseEnded(cause: .storage, resumeTitle: r), .storageRetrying, "a failed save after a timed pause: the retrying notice")
        let retrying = RecordingNotice.storageRetrying
        equal(retrying.title, "DayDream can't save right now", "the retrying notice title")
        equal(retrying.body, "Recording is paused and starts again by itself.", "the retrying notice text")
        check(retrying.body.hasSuffix(".") && retrying.title.hasPrefix("DayDream "), "the retrying notice is complete")
        for banned in ["Quit", "reopen", "explicitly", "error", "history", "storage", "Storage", "Choose "] {
            check(!retrying.body.contains(banned) && !retrying.title.contains(banned), "the retrying notice avoids \"\(banned)\"")
        }
        all.append(RecordingNotice.resumeFailed(after: [.userSwitch], cause: .input, resumeTitle: r))
        equal(all.last?.body, "Recording didn't start again after you switched back. It stopped because DayDream can't see your keys or clicks. Choose Resume Now from DayDream in the menu bar.",
              "user switch wording")
        all.append(RecordingNotice.timedPauseEnded(cause: .permission(accessibility: false, inputMonitoring: true), resumeTitle: s))
        equal(all.last?.body, "Your pause ended, but recording didn't start again. It stopped because Input Monitoring is off for DayDream. Choose Turn on Input Monitoring from DayDream in the menu bar.",
              "a timed pause that couldn't resume")
        equal(all.last?.title, "DayDream didn't start recording again", "timed pause notice title")
        // G42 / G10: recording that was on when DayDream or the Mac last quit, and couldn't start again at launch.
        all.append(RecordingNotice.reopenFailed(cause: .permission(accessibility: true, inputMonitoring: false), resumeTitle: s))
        equal(all.last?.body, "Recording didn't start again when DayDream opened. It stopped because Accessibility is off for DayDream. Choose Turn on Accessibility from DayDream in the menu bar.",
              "launch: a permission off")
        equal(all.last?.title, "DayDream didn't start recording again", "launch notice title")
        all.append(RecordingNotice.reopenFailed(cause: .other, resumeTitle: s))
        equal(all.last?.body, "Recording didn't start again when DayDream opened. Turn DayDream on in the menu bar.", "launch: anything else")
        equal(RecordingNotice.reopenFailed(cause: .storage, resumeTitle: s), .storageRetrying, "launch: a failed save gives the retrying notice")
        // Extra 4: a restore preview waiting for review names the menu bar's Review… button (its blocker's fix).
        all.append(RecordingNotice.reopenFailed(cause: .restore, resumeTitle: s))
        equal(all.last?.body, "Recording didn't start again when DayDream opened. It stopped because a restore is waiting for review. Choose Review… from DayDream in the menu bar.",
              "launch: a restore waiting for review")
        all.append(RecordingNotice.afterOperation(cause: .other, resumeTitle: s))
        equal(all.last?.body, "Recording didn't start again after the import or backup. Turn DayDream on in the menu bar.", "after an import or backup")
        // G54: every notice names what the menu bar panel shows then (MenuBarMenu: the switch, Resume Now, Allow…), never
        // "the DayDream menu", whose Start and Resume items the panel doesn't have.
        for n in all {
            check(!n.body.contains("DayDream menu") && !n.body.contains("Start Recording") && !n.body.contains("Resume Recording"),
                  "G54: no item the menu bar panel lacks: " + n.body)
        }
        // Plain words: every notice names DayDream, ends with a full stop, says what to do, and never uses internal wording.
        for n in all {
            check(n.body.contains("DayDream") && n.body.hasSuffix(".") && n.title.hasPrefix("DayDream "), "notice is complete: " + n.body)
            check(["Choose Resume Now from DayDream in the menu bar.", "Choose Allow… from DayDream in the menu bar.",
                   "Choose Turn on Accessibility from DayDream in the menu bar.", "Choose Turn on Input Monitoring from DayDream in the menu bar.", "Turn DayDream on in the menu bar.",
                   "Choose Review… from DayDream in the menu bar.",
                   "Move DayDream"].contains(where: n.body.contains), "notice says how to start again, naming a control the menu bar panel has: " + n.body)
            for banned in ["explicitly", "Resume explicitly", "tap", "session", "error", "Daydream ", "Mac Mem"] {
                check(!n.body.contains(banned) && !n.title.contains(banned), "notice avoids \"\(banned)\": " + n.body)
            }
            check(!n.body.contains("Quit and reopen"), "no notice asks to quit and reopen: " + n.body)
            // gold/r2-copy-checks: "input" is the code's word; the person's is keys and clicks (Input Monitoring is a name).
            check(!n.body.replacingOccurrences(of: "Input Monitoring", with: "").lowercased().contains("input"),
                  "notice says keys and clicks, never input: " + n.body)
        }
    }

    // MARK: G55: a new sleep or lock during the 10 s retry gets its own tries

    static func newEpisodeRetries() {
        // A failed start after unlock is retried once in 10 s. The screen locks again before that retry: the next unlock
        // is a new episode, and its first failure is retried too (not a notice at once).
        var m = M()
        _ = m.begin(.screenLock, wantsRecording: true, timedPauseUntil: nil, recorderActive: true)
        guard case .settle(_, let a)? = m.end(.screenLock).first else { return check(false, "G55: unlock settles") }
        _ = m.settled(token: a, screenLocked: false, onConsole: true, now: t0)
        guard case .settle(M.retryDelay, _)? = m.started(succeeded: false, cause: .other, resumeTitle: "Resume Recording").first else {
            return check(false, "G55: the first failure is retried")
        }
        _ = m.begin(.screenLock, wantsRecording: true, timedPauseUntil: nil, recorderActive: false)
        equal(m.attempts, 0, "G55: a lock during the pending retry starts a new episode with its own tries")
        guard case .settle(_, let b)? = m.end(.screenLock).first else { return check(false, "G55: the second unlock settles") }
        equal(m.settled(token: b, screenLocked: false, onConsole: true, now: t0), [.start], "G55: the second unlock starts")
        let effects = m.started(succeeded: false, cause: .other, resumeTitle: "Resume Recording")
        guard case .settle(let delay, _)? = effects.first else { return check(false, "G55: the new episode's first failure is retried, not a notice", "\(effects)") }
        equal(delay, M.retryDelay, "G55: the new episode's retry waits the retry delay")

        // The retry's own settle finds the screen locked: its unlock gets its own tries too.
        m = M()
        _ = m.begin(.sleep, wantsRecording: true, timedPauseUntil: nil, recorderActive: true)
        guard case .settle(_, let c)? = m.end(.sleep).first else { return check(false, "G55: wake settles") }
        _ = m.settled(token: c, screenLocked: false, onConsole: true, now: t0)
        guard case .settle(_, let d)? = m.started(succeeded: false, cause: .other, resumeTitle: "Resume Recording").first else {
            return check(false, "G55: the wake failure is retried")
        }
        equal(m.settled(token: d, screenLocked: true, onConsole: true, now: t0), [], "G55: the retry finds the screen locked and waits")
        equal(m.attempts, 0, "G55: waiting for that unlock is a new episode")
        guard case .settle(_, let e)? = m.end(.screenLock).first else { return check(false, "G55: that unlock settles") }
        _ = m.settled(token: e, screenLocked: false, onConsole: true, now: t0)
        guard case .settle(_, let f)? = m.started(succeeded: false, cause: .other, resumeTitle: "Resume Recording").first else {
            return check(false, "G55: after the unlock the first failure is retried again")
        }
        // Still at most two starts per episode: the retry's failure is the one notice.
        equal(m.settled(token: f, screenLocked: false, onConsole: true, now: t0), [.start], "G55: the retry starts")
        guard case .notify? = m.started(succeeded: false, cause: .other, resumeTitle: "Resume Recording").first else {
            return check(false, "G55: the episode still ends in one notice after two tries")
        }
        check(true, "G55: two tries per episode, then one notice")

        // An import or backup still running when the wake starts recording: the model takes it over, and the plan ends.
        m = M()
        _ = m.begin(.sleep, wantsRecording: true, timedPauseUntil: nil, recorderActive: true)
        guard case .settle(_, let g)? = m.end(.sleep).first else { return check(false, "hand-off: wake settles") }
        _ = m.settled(token: g, screenLocked: false, onConsole: true, now: t0)
        m.handedOff()
        check(m.plan == .nothing && m.attempts == 0, "hand-off: the wake plan ends with no retry and no notice", "\(m.plan)")
        equal(m.started(succeeded: false, cause: .other, resumeTitle: "Resume Recording"), [], "hand-off: nothing more from the wake rules")
    }

    // MARK: G10: recording that was on starts again at the next launch

    static func launchResume() {
        typealias L = LaunchResume
        let until = t0.addingTimeInterval(15 * 60)
        check(L.value(wanted: false, pauseUntil: nil) == nil, "G10: nothing wanted saves nothing")
        equal(L.value(wanted: true, pauseUntil: nil)?["recording"] as? Bool, true, "G10: recording wanted is saved")
        equal(L.value(wanted: false, pauseUntil: until)?["until"] as? Double, until.timeIntervalSince1970, "G10/G42: a timed pause saves its end")
        equal(L.value(wanted: true, pauseUntil: until)?["until"] as? Double, until.timeIntervalSince1970, "G10: a timed pause wins over a plain wish")
        equal(L.plan(saved: nil, updated: false, now: t0), .none, "G10: nothing saved, no update: recording stays off at launch")
        equal(L.plan(saved: ["recording": true], updated: false, now: t0), .record, "G10: recording on at the last quit starts again")
        equal(L.plan(saved: nil, updated: true, now: t0), .record, "G10: sat5's update marker still starts it again")
        equal(L.plan(saved: ["until": until.timeIntervalSince1970], updated: false, now: t0), .timedPause(until: until),
              "G42: a timed pause running at the quit goes on until the same time")
        equal(L.plan(saved: ["until": until.timeIntervalSince1970], updated: true, now: until.addingTimeInterval(1)), .record,
              "G42: a timed pause that ended meanwhile starts recording, as it promised")
        equal(L.plan(saved: ["recording": false], updated: false, now: t0), .none, "G10: a false flag is nothing")
        equal(L.plan(saved: ["until": "soon"], updated: false, now: t0), .none, "G10: an unreadable value is nothing")
        check(RecordingStopCause.personReasons.contains("App closed.") && !RecordingStopCause.personReasons.contains { $0.contains("OFF next time") },
              "G10: quitting no longer claims recording starts off next time")
    }

    // MARK: Saves that failed

    static func storageRetry() {
        typealias R = StorageRetry
        var r = R()
        check(!r.active, "no retry until a save fails")
        equal(r.step(recording: false, wanted: true, suspended: false, blocked: false), .none, "nothing due before a failure")
        // Waits 2, 5, 15, 30, then 60 seconds, and stays at 60.
        var delays: [TimeInterval] = []
        var at = t0
        for _ in 0..<7 {
            _ = r.failed(now: at)
            delays.append(r.nextDelay)
            at = at.addingTimeInterval(r.nextDelay)
        }
        equal(delays, [2, 5, 15, 30, 60, 60, 60], "the waits back off to once a minute")
        check(r.active, "a failed save starts the retries")

        // Two paths reporting the same fault a moment apart count once.
        r = R()
        _ = r.failed(now: t0)
        _ = r.failed(now: t0.addingTimeInterval(0.2))
        equal(r.failures, 1, "the same fault reported twice within a second is one failure")
        equal(r.nextDelay, 2, "so the first wait is still 2 seconds")

        // Persistent after two minutes: true exactly once (the one notice).
        r = R()
        check(!r.failed(now: t0), "the first failure posts nothing")
        check(!r.failed(now: t0.addingTimeInterval(60)), "a minute of failing posts nothing")
        check(!r.persistent(now: t0.addingTimeInterval(119)), "not persistent before two minutes")
        check(r.failed(now: t0.addingTimeInterval(R.persistentAfter)), "two minutes of failing posts the one notice")
        check(r.persistent(now: t0.addingTimeInterval(R.persistentAfter)), "and is persistent")
        equal(r.nextDelay(now: t0.addingTimeInterval(R.persistentAfter)), 60, "once persistent, tries are a minute apart (what its line says)")
        check(!r.failed(now: t0.addingTimeInterval(R.persistentAfter + 60)), "never a second notice")
        check(r.succeeded(now: t0.addingTimeInterval(R.persistentAfter + 70)), "recording again says the notice was out (so it is cleared)")
        check(!r.active, "recording again: no try is due")

        // A fault that comes back right after every start keeps backing off (no start every 2 s), and still gets
        // the one notice after two minutes.
        r = R()
        at = t0
        var waits: [TimeInterval] = []
        var posted = 0
        for _ in 0..<8 {
            if r.failed(now: at) { posted += 1 }
            waits.append(r.nextDelay)
            at = at.addingTimeInterval(r.nextDelay)
            r.succeeded(now: at)          // the try starts recording...
            at = at.addingTimeInterval(1) // ...and the next save fails a second later
        }
        equal(waits, [2, 5, 15, 30, 60, 60, 60, 60], "a fault that returns after each start still backs off")
        equal(posted, 1, "and gets one notice once it has gone on for two minutes")

        // Recording for a minute ends the run: the next failure starts again at 2 s, with its own two minutes.
        r = R()
        _ = r.failed(now: t0); _ = r.failed(now: t0.addingTimeInterval(2)); _ = r.failed(now: t0.addingTimeInterval(7))
        equal(r.nextDelay, 15, "third failure waits 15 seconds")
        check(!r.succeeded(now: t0.addingTimeInterval(22)), "a success with no notice out clears nothing")
        _ = r.failed(now: t0.addingTimeInterval(22 + R.stableAfter))
        equal(r.nextDelay, 2, "after a minute of recording the waits start again at 2 seconds")
        equal(r.failures, 1, "and the count starts again")
        check(!r.persistent(now: t0.addingTimeInterval(22 + R.stableAfter + 119)), "and the two minutes count from the new failure")

        // What a due try does.
        r = R()
        _ = r.failed(now: t0)
        equal(r.step(recording: false, wanted: true, suspended: false, blocked: false), .start, "a due try starts recording")
        equal(r.step(recording: false, wanted: true, suspended: true, blocked: false), .leaveToWake, "asleep, locked or switched away: the wake rules start it")
        equal(r.step(recording: false, wanted: true, suspended: false, blocked: true), .wait, "a permission or unsaved choice stands: look again later")
        equal(r.step(recording: true, wanted: true, suspended: false, blocked: false), .none, "already recording: nothing")
        equal(r.step(recording: false, wanted: false, suspended: false, blocked: false), .none, "the person turned it off: nothing")
        r.personActed()
        check(!r.active, "the person pausing or stopping ends the retries")
        equal(r.step(recording: false, wanted: true, suspended: false, blocked: false), .none, "and nothing is tried after")
    }

    // MARK: The download window

    static func launchLocation() {
        let cases: [(String, Bool, LaunchLocation)] = [
            ("/Applications/DayDream.app", false, .applications),
            ("/Applications/DayDream.app/", false, .applications),
            ("/Applications/Utilities/DayDream.app", false, .applications),
            ("/Users/someone/Applications/DayDream.app", false, .applications),
            ("/Volumes/DayDream/DayDream.app", true, .diskImage),
            ("/Volumes/DayDream 1/DayDream.app", true, .diskImage),
            ("/Volumes/Applications/DayDream.app", true, .diskImage),
            ("/Volumes/Work/builds/DayDream.app", false, .elsewhere),
            ("/private/var/folders/xy/abc123/T/AppTranslocation/0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0/d/DayDream.app", true, .translocated),
            ("/var/folders/xy/abc123/T/AppTranslocation/0F1E2D3C/d/DayDream.app", false, .translocated),
            ("/Users/someone/Downloads/DayDream.app", false, .elsewhere),
            ("/Users/someone/Desktop/DayDream.app", false, .elsewhere),
            ("/Volumes/Work/dev/build/debug", false, .notAnApp),
            ("/usr/local/bin", true, .notAnApp),
        ]
        for (path, readOnly, want) in cases {
            equal(LaunchLocation.classify(bundlePath: path, readOnlyVolume: readOnly), want, "location: \(path) (read-only \(readOnly))")
        }
        for location in [LaunchLocation.applications, .elsewhere, .diskImage, .translocated, .notAnApp] {
            equal(location.blocksRecording, location == .diskImage || location == .translocated, "only the download window blocks recording: \(location)")
        }
        equal(LaunchLocation.warning, "Move DayDream to Applications first.", "the warning, word for word")
        equal(LaunchLocation.blockerValue + ".", LaunchLocation.warning, "the blocker value maps to the warning")
        equal(LaunchLocation.applicationsFolder.path, "/Applications", "the button opens /Applications")
        check(LaunchLocation.detail.contains("Applications") && LaunchLocation.detail.contains("won't record"), "the detail says where to move it and that nothing records")
        // The copy in the download window holds the recorder lock: it must be quit before the moved copy opens.
        check(LaunchLocation.detail.range(of: "Quit DayDream").map { quit in LaunchLocation.detail.range(of: "drag it").map { quit.lowerBound < $0.lowerBound } ?? false } ?? false,
              "the detail says to quit DayDream before dragging it to Applications")
        equal(LaunchLocation.quitTitle, "Quit DayDream", "the warning offers Quit DayDream")
    }
}
