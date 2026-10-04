// DD-RECIPE: SRC Sources/MemoryUI/DaydreamCaptureState.swift
//
// Pins the recording state model (plan §4.1, copy deck §8.1/§8.2, amendments F0a):
// the derivation order, each blocker → Off, permission sets, one prominent action per state,
// the pause presets, capsule/detail/VoiceOver/menu-bar strings and the operationalIssue
// attention line. Pure: fixed clock and time zone, no app, no permissions, no capture.
import Foundation

@main enum DDRecordingStateChecks {
    static var failures = 0
    static var outputs: [String] = []

    static func check(_ ok: Bool, _ name: String, _ got: @autoclosure () -> String = "") {
        if ok { print("PASS " + name) } else {
            failures += 1
            FileHandle.standardError.write(Data(("FAIL: " + name + (got().isEmpty ? "" : " (got: " + got() + ")") + "\n").utf8))
        }
    }
    static func equal<T: Equatable>(_ got: T, _ want: T, _ name: String) {
        check(got == want, name, "\(got)")
    }

    static let la = TimeZone(identifier: "America/Los_Angeles")!
    static func date(_ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = la
        return c.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: h, minute: m, second: s))!
    }
    static let now = date(16, 24)

    /// Every string a state produces, collected for the vocabulary sweep.
    static func strings(_ s: RecordingState, issue: String? = nil) -> [String] {
        var out = [s.kind.title, s.capsuleLabel(now: now), s.accessibilityValue(now: now, timeZone: la),
                   s.menuBarAccessibilityLabel(now: now, timeZone: la)]
        if let d = s.detail(now: now, timeZone: la) { out.append(d) }
        if let a = s.attentionLine(issue: issue, now: now, timeZone: la) { out.append(a) }
        outputs += out
        return out
    }

    static func main() {
        let until = date(16, 36), pausedAt = date(16, 6), since = date(8, 40), stoppedAt = date(12, 0)

        // MARK: Derivation order (§4.1 steps 1–7)
        let plain = RecordingState.derive(RecordingStateInputs())
        equal(plain, .off(since: nil, reason: nil), "defaults derive plain Off")
        equal(RecordingState.derive(RecordingStateInputs(stoppedAt: stoppedAt)), .off(since: stoppedAt, reason: nil), "stopped derives Off since stoppedAt")

        let dev = RecordingState.derive(RecordingStateInputs(recording: true, development: true, resumeUnavailable: "Permissions required"))
        equal(dev, .off(since: nil, reason: "Development Trial · recording is disabled"), "1 development wins over recording and permissions")

        equal(RecordingState.derive(RecordingStateInputs(recording: true, stopped: false, pauseUntil: until, recordingSince: since, resumeUnavailable: "Permissions required", sessionState: "permission_denied")),
              .recording(since: since), "2 recording wins over permissions, pause and blockers")
        equal(RecordingState.derive(RecordingStateInputs(recording: true)), .recording(since: nil), "2 recording with unknown start")

        equal(RecordingState.derive(RecordingStateInputs(pauseUntil: until, resumeUnavailable: "Permissions required", accessibilityGranted: false, inputMonitoringGranted: true)),
              .needsPermission(missing: [.accessibility]), "3 Permissions required wins over a timed pause; missing = Accessibility")
        equal(RecordingState.derive(RecordingStateInputs(sessionState: "permission_denied", inputMonitoringGranted: false)),
              .needsPermission(missing: [.inputMonitoring]), "3 session permission_denied; missing = Input Monitoring")
        equal(RecordingState.derive(RecordingStateInputs(resumeUnavailable: "Permissions required", accessibilityGranted: false, inputMonitoringGranted: false)),
              .needsPermission(missing: [.accessibility, .inputMonitoring]), "3 both permissions read false")
        equal(RecordingState.derive(RecordingStateInputs(resumeUnavailable: "Permissions required", accessibilityGranted: true, inputMonitoringGranted: nil)),
              .needsPermission(missing: []), "3 unknown or granted reads are not reported missing")
        equal(RecordingState.derive(RecordingStateInputs(stopped: false, sessionState: "permission_denied")),
              .needsPermission(missing: []), "3 permission_denied wins over an open pause")

        equal(RecordingState.derive(RecordingStateInputs(stopped: false, pauseUntil: until, pausedAt: pausedAt, resumeUnavailable: "Setup required", sessionReason: "Paused for sleep. Resume explicitly after waking.")),
              .paused(until: until, since: pausedAt, reason: nil), "4 timed pause wins over blockers and session reasons")

        let blockers: [(String, String)] = [
            ("Setup required", "Finish setup to start recording."),
            ("Storage unavailable", "Storage needs attention. Nothing is recorded."),
            ("Storage needs attention", "Storage needs attention. Nothing is recorded."),
            // A second copy of DayDream holds the recorder lock (MacMemApp's MemoryViewModel.anotherCopyBlocker).
            // gold r2: one short line that tells nobody to quit anything (it clears itself once the lock is free).
            ("Another copy of DayDream is open", "DayDream is already open."),
            ("Review replacement", "Review the replacement in Settings before recording."),
            ("Replacement in progress", "Review the replacement in Settings before recording."),
            ("Resume after waking", "Resume after your Mac wakes."),
            // SPEC 6.3 R3: the download window (MacMemApp's LaunchLocation.blockerValue).
            ("Move DayDream to Applications first", "Move DayDream to Applications first."),
            ("Disabled in Development Trial", "Development Trial · recording is disabled"),
            ("Recording backend offline", "Recording backend offline"),
        ]
        for (core, ui) in blockers {
            let s = RecordingState.derive(RecordingStateInputs(stopped: false, stoppedAt: stoppedAt, resumeUnavailable: core, accessibilityGranted: false))
            equal(s, .off(since: stoppedAt, reason: ui), "5 blocker \"\(core)\" → Off, never Needs Permission")
            equal(s.detail(now: now, timeZone: la), ui, "5 blocker \"\(core)\" detail")
            equal(s.accessibilityValue(now: now, timeZone: la), "Off, " + ui, "5 blocker \"\(core)\" VoiceOver")
            equal(s.primaryAction, .start, "5 blocker \"\(core)\" primary action is Start")
            _ = strings(s)
        }

        let reasons: [(String?, String)] = [
            ("Paused for sleep. Resume explicitly after waking.", "Paused while your Mac slept."),
            ("Paused for update. Start recording explicitly after restart.", "Paused while DayDream updates."),
            ("Paused for preference save; resume explicitly.", "Paused while settings were saved."),
            ("Timed pause ended without safe focus. Resume explicitly.", "Your pause ended. Resume when you're ready."),
            ("Resume canceled: prerequisites changed. Review Settings.", "Your pause ended because something changed. Review Settings."),
            // Every other reason the app and core write when they pause (MacMemApp, EventCapture, Coordinator,
            // CaptureSession): none reaches a surface as "Resume explicitly".
            ("Awake. Resume explicitly after sleep.", "Paused while your Mac slept."),
            ("System slept or session became inactive. Resume explicitly.", "Paused while your Mac slept or you switched users."),
            ("Paused when your login session became inactive. Resume explicitly.", "Paused while you switched users."),
            // SPEC 6.3 R1: the screen-lock pause (MacMemApp's WakeSuspension.screenLock.pauseReason).
            ("Paused for screen lock. Resumes after unlock.", "Paused while your screen was locked."),
            ("Input tap was disabled. Resume explicitly.", "Keyboard and mouse input was interrupted. Resume when you're ready."),
            // A failed save while DayDream tries again by itself (MemoryCore's CaptureFault reasons): one calm line.
            ("Storage write failed. Retrying automatically.", "Couldn't save for a moment. Trying again."),
            ("Storage keeps failing. Retrying every minute.", "Can't save right now. Trying again every minute."),
            ("Storage full. Retrying automatically.", "Your Mac is out of space. Trying again."),
            // Older storage pauses: Resume (always offered while Paused) tries again. Never "Storage needs attention"
            // or "Quit and reopen" over a pause.
            ("Storage health check failed. Resume explicitly.", "Couldn't save. Resume to try again."),
            ("Capture storage or proof failed. Nothing retried; resume explicitly.", "Couldn't save. Resume to try again."),
            ("Preference save failed. Recording stopped; resume explicitly.", "Couldn't save. Resume to try again."),
            ("A durable write failed. Recording stopped; resume explicitly.", "Couldn't save. Resume to try again."),
            ("Pause could not be persisted. Recording stopped; check storage before resuming.", "Couldn't save. Resume to try again."),
            ("Recording could not start. Check local storage.", "Couldn't save. Resume to try again."),
            ("Storage unavailable; recording stopped.", "Couldn't save. Resume to try again."),
            // Recording didn't start again by itself (MacMemApp's RecordingStopCause.notResumedReason): no promise left.
            ("Recording didn't start again by itself. Resume explicitly.", "Didn't start again. Resume when you're ready."),
            ("Paused by the session for an unlisted reason.", "Paused by the session for an unlisted reason."),
            (nil, "Paused by you"),
            ("   ", "Paused by you"),
        ]
        for (core, ui) in reasons {
            let s = RecordingState.derive(RecordingStateInputs(stopped: false, pausedAt: pausedAt, sessionReason: core))
            let mapped = core.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : ui }
            equal(s, .paused(until: nil, since: pausedAt, reason: mapped), "6 open pause reason \(core.map { "\"\($0)\"" } ?? "nil")")
            equal(s.detail(now: now, timeZone: la), ui, "6 open pause detail \"\(ui)\"")
            equal(s.accessibilityValue(now: now, timeZone: la), ui.hasPrefix("Paused") ? ui : "Paused, " + ui, "6 open pause VoiceOver \"\(ui)\"")
            equal(s.capsuleLabel(now: now), "Paused", "6 open pause capsule")
            equal(s.menuBarAccessibilityLabel(now: now, timeZone: la), "DayDream: Paused", "6 open pause menu bar label")
            _ = strings(s)
        }
        let internalWords = reasons.compactMap(\.0).filter { $0 != "Paused by the session for an unlisted reason." }
            .map { RecordingCopy.pauseReason($0) ?? "" }.filter { $0.lowercased().contains("explicitly") || $0.lowercased().contains("capture") }
        check(internalWords.isEmpty, "6 no app or core pause reason reaches a surface with \"explicitly\" or \"capture\"", internalWords.joined(separator: " | "))
        // One state, one calm line: no pause says to quit and reopen, and a save line fits the popover on one line.
        let pauseDetails = reasons.compactMap(\.0).compactMap { RecordingCopy.pauseReason($0) }
        let alarming = pauseDetails.filter { $0.contains("Quit") || $0.contains("reopen") || $0.contains("Resume explicitly") || $0.contains("needs attention") }
        check(alarming.isEmpty, "6 no pause detail says quit, reopen, resume explicitly or needs attention", alarming.joined(separator: " | "))
        let saveLines = [RecordingCopy.savingRetry, RecordingCopy.savingRetryPersistent, RecordingCopy.savingRetryFull, RecordingCopy.savingFailed]
        check(saveLines.allSatisfy { $0.count <= 50 }, "6 every save line is at most 50 characters", saveLines.filter { $0.count > 50 }.joined(separator: " | "))
        // Beside a pause for sleep, a lock or a user switch, a real issue still shows: after the unlock Start can refuse
        // (a history job still running, app choices that didn't save), and that is the only line that says why nothing
        // resumes. (A stop notice never reaches here: the app model keeps it to the notification.)
        for core in ["Paused for screen lock. Resumes after unlock.", "Paused for sleep. Resume explicitly after waking.",
                     "System slept or session became inactive. Resume explicitly.", "Paused when your login session became inactive. Resume explicitly.",
                     "Recording didn't start again by itself. Resume explicitly."] {
            for issue in ["Finish history operation before recording", "Your app choices didn't save"] {
                let s = RecordingState.derive(RecordingStateInputs(stopped: false, pausedAt: pausedAt, sessionReason: core, operationalIssue: issue))
                equal(s.attentionLine(issue: issue, now: now, timeZone: la), RecordingCopy.issue(issue),
                      "6 the orange line \"\(issue)\" shows beside the pause \"\(core)\"")
            }
        }
        let notResumed = RecordingState.derive(RecordingStateInputs(stopped: false, pausedAt: pausedAt, sessionState: "paused",
                                                                    sessionReason: "Recording didn't start again by itself. Resume explicitly."))
        check(notResumed.kind == .paused && notResumed.primaryAction == .resume && notResumed.detail(now: now, timeZone: la) == RecordingCopy.notResumed
              && RecordingCopy.notResumed.count <= 50 && !RecordingCopy.notResumed.contains("unlock") && !RecordingCopy.notResumed.contains("Trying"),
              "6 a start that won't come: Paused, Resume, one line that promises nothing", "\(notResumed)")
        // A save retry shows its one line and no other: the state says it, so the same words never repeat below.
        let retrying = RecordingState.derive(RecordingStateInputs(stopped: false, pausedAt: pausedAt, sessionState: "paused",
                                                                  sessionReason: "Storage write failed. Retrying automatically."))
        equal(retrying.kind.title, "Paused", "6 a save retry is Paused")
        equal(retrying.primaryAction, .resume, "6 a save retry still offers Resume (it tries at once)")
        equal(retrying.attentionLine(issue: nil, now: now, timeZone: la), nil, "6 a save retry has no orange line")
        // Sleep then wake: the app pauses for sleep, then again on wake with its own reason, which is what a person
        // sees after opening the lid. It shows the §8.2 sleep row.
        let slept = RecordingState.derive(RecordingStateInputs(stopped: false, pausedAt: pausedAt, sessionReason: "Paused for sleep. Resume explicitly after waking."))
        let woke = RecordingState.derive(RecordingStateInputs(stopped: false, pausedAt: pausedAt, sessionReason: "Awake. Resume explicitly after sleep."))
        check(slept == woke && woke.detail(now: now, timeZone: la) == "Paused while your Mac slept.",
              "6 after sleep and wake the paused detail is the §8.2 sleep row", "\(woke)")
        equal(RecordingState.derive(RecordingStateInputs(stopped: false, resumeUnavailable: "Storage unavailable")),
              .off(since: nil, reason: "Storage needs attention. Nothing is recorded."), "5 before 6: a blocker wins over an open pause")
        equal(RecordingState.derive(RecordingStateInputs(stopped: true, sessionReason: "Paused for sleep. Resume explicitly after waking.")),
              .off(since: nil, reason: nil), "7 stopped ignores session reasons")

        // MARK: One prominent action per state
        equal(RecordingState.recording(since: nil).primaryAction, nil, "Recording has no prominent action")
        equal(RecordingState.paused(until: until, since: nil, reason: nil).primaryAction, .resume, "Paused → Resume")
        equal(RecordingState.paused(until: nil, since: nil, reason: nil).primaryAction, .resume, "open Paused → Resume")
        equal(RecordingState.off(since: nil, reason: nil).primaryAction, .start, "Off → Start")
        equal(RecordingState.needsPermission(missing: []).primaryAction, .openSystemSettings, "Needs Permission → Open System Settings")
        equal(RecordingState.pausePresets, [5, 15, 30, 120], "pause presets are exactly 5/15/30/120 minutes")

        // MARK: Titles
        equal(DaydreamCaptureState.allCases.map(\.title), ["Recording", "Paused", "Off", "Needs Permission"], "state titles")
        equal(PermissionKind.allCases.map(\.title), ["Accessibility", "Input Monitoring"], "permission titles")
        equal(RecordingState.needsPermission(missing: [.accessibility]).kind, .needsPermission, "kind of Needs Permission")

        // MARK: Recording strings (§8.1)
        let rec = RecordingState.recording(since: since)
        equal(rec.capsuleLabel(now: now), "Recording", "Recording capsule")
        equal(rec.detail(now: now, timeZone: la), "Since 8:40 AM", "Recording detail")
        equal(RecordingState.recording(since: nil).detail(now: now, timeZone: la), nil, "Recording detail omitted when the start is unknown")
        equal(rec.accessibilityValue(now: now, timeZone: la), "Recording", "Recording VoiceOver")
        equal(rec.menuBarAccessibilityLabel(now: now, timeZone: la), "DayDream: Recording", "Recording menu bar label")
        _ = strings(rec); _ = strings(.recording(since: nil))

        // MARK: Timed pause strings
        let timed = RecordingState.paused(until: until, since: pausedAt, reason: nil)
        equal(timed.capsuleLabel(now: now), "Paused · 12m", "timed pause capsule at 12m left")
        equal(timed.detail(now: now, timeZone: la), "Until 4:36 PM · 12 minutes left", "timed pause detail")
        equal(timed.accessibilityValue(now: now, timeZone: la), "Paused until 4:36 PM, 12 minutes left", "timed pause VoiceOver")
        equal(timed.menuBarAccessibilityLabel(now: now, timeZone: la), "DayDream: Paused until 4:36 PM", "timed pause menu bar label")
        equal(timed.detail(now: now, timeZone: TimeZone(identifier: "Asia/Tokyo")!), "Until 8:36 AM · 12 minutes left", "timed pause detail follows the time zone")
        _ = strings(timed)

        let clock: [(Date, String, String)] = [
            (date(16, 35, 30), "Paused · 12m", "12 minutes"),          // 11m30s left rounds up
            (date(16, 35, 10), "Paused · 12m", "12 minutes"),          // 11m10s left: up, not to nearest
            (date(16, 24, 20), "Paused · 1m", "1 minute"),             // 20s left never reads 0m
            (date(16, 24, 1), "Paused · 1m", "1 minute"),              // 1s left never reads 0m
            (date(18, 24), "Paused · 2h", "2 hours"),
            (date(18, 9), "Paused · 1h 45m", "1 hour 45 minutes"),
            (date(16, 25), "Paused · 1m", "1 minute"),
            (date(17, 25), "Paused · 1h 1m", "1 hour 1 minute"),
        ]
        for (end, capsule, spoken) in clock {
            let s = RecordingState.paused(until: end, since: nil, reason: nil)
            let left = "\(Int(end.timeIntervalSince(now)))s left"
            equal(s.capsuleLabel(now: now), capsule, "capsule \(capsule) at \(left)")
            check(s.detail(now: now, timeZone: la)?.hasSuffix(" · " + spoken + " left") == true, "detail spells out \(spoken) at \(left)", s.detail(now: now, timeZone: la) ?? "nil")
            check(s.accessibilityValue(now: now, timeZone: la).hasSuffix(", " + spoken + " left"), "VoiceOver spells out \(spoken) at \(left)", s.accessibilityValue(now: now, timeZone: la))
            _ = strings(s)
        }
        let ended = RecordingState.paused(until: date(16, 20), since: nil, reason: nil)
        equal(ended.capsuleLabel(now: now), "Paused", "an ended pause shows no countdown")
        equal(ended.detail(now: now, timeZone: la), "Until 4:20 PM", "an ended pause has no minutes left")
        equal(ended.accessibilityValue(now: now, timeZone: la), "Paused until 4:20 PM", "an ended pause VoiceOver")
        equal(RecordingState.paused(until: now, since: nil, reason: nil).capsuleLabel(now: now), "Paused", "a pause ending now shows no countdown")
        _ = strings(ended)

        // MARK: Off and Needs Permission strings
        let off = RecordingState.off(since: stoppedAt, reason: nil)
        equal(off.capsuleLabel(now: now), "Off", "Off capsule")
        equal(off.detail(now: now, timeZone: la), "Nothing is recorded until you start again.", "Off detail")
        equal(off.accessibilityValue(now: now, timeZone: la), "Off, Nothing is recorded until you start again.", "Off VoiceOver")
        equal(off.menuBarAccessibilityLabel(now: now, timeZone: la), "DayDream: Off", "Off menu bar label")
        equal(dev.detail(now: now, timeZone: la), "Development Trial · recording is disabled", "Development detail")
        _ = strings(off); _ = strings(dev)

        // perm-1004 (owner 10/3): the capsule and the menu bar name the permission to turn on (Accessibility first);
        // "Needs Permission" only while which one is missing isn't known.
        let permissionCases: [(Set<PermissionKind>, String, String, String)] = [
            ([.inputMonitoring], "Input Monitoring is off in System Settings.", "Needs permission: Input Monitoring", "Turn on Input Monitoring"),
            ([.accessibility], "Accessibility is off in System Settings.", "Needs permission: Accessibility", "Turn on Accessibility"),
            // Both read as off: a known fact, said as the single-permission lines say it (and as the Settings card
            // does); "…are required." is only for an unknown set.
            ([.accessibility, .inputMonitoring], "Accessibility and Input Monitoring are off in System Settings.", "Needs permission: Accessibility and Input Monitoring", "Turn on Accessibility"),
            ([], "Accessibility and Input Monitoring are required.", "Needs permission, Accessibility and Input Monitoring are required.", "Needs Permission"),
        ]
        for (missing, detail, spoken, capsule) in permissionCases {
            let s = RecordingState.needsPermission(missing: missing)
            let label = missing.map(\.rawValue).sorted().joined(separator: "+")
            equal(s.capsuleLabel(now: now), capsule, "Needs Permission capsule [\(label)]")
            equal(s.detail(now: now, timeZone: la), detail, "Needs Permission detail [\(label)]")
            equal(s.accessibilityValue(now: now, timeZone: la), spoken, "Needs Permission VoiceOver [\(label)]")
            equal(s.menuBarAccessibilityLabel(now: now, timeZone: la), "DayDream: " + capsule, "Needs Permission menu bar label [\(label)]")
            _ = strings(s)
        }

        // MARK: Copy tables (§8.2)
        equal(RecordingCopy.pauseReason(nil), nil, "no session reason maps to nil")
        equal(RecordingCopy.pauseReason(" \n"), nil, "a blank session reason maps to nil")
        equal(RecordingCopy.blocker("Something new"), "Something new", "unknown blockers pass through verbatim")
        equal(RecordingCopy.knownBlocker("Setup required"), "Finish setup to start recording.", "knownBlocker: a table blocker")
        equal(RecordingCopy.knownBlocker(" Review replacement "), "Review the replacement in Settings before recording.", "knownBlocker: trimmed")
        equal(RecordingCopy.knownBlocker("Summary writer needs attention"), nil, "knownBlocker: an operational issue is not a blocker")
        equal(RecordingCopy.knownBlocker("Permissions required"), nil, "knownBlocker: the permission gap is not an Off blocker")
        equal(RecordingCopy.knownBlocker(nil), nil, "knownBlocker: nil")
        equal(RecordingCopy.issue("Permissions required"), "Accessibility and Input Monitoring are required.", "issue: permissions")
        equal(RecordingCopy.issue("Resume after waking"), "Resume after your Mac wakes.", "issue: blocker table")
        equal(RecordingCopy.issue("Paused for update. Start recording explicitly after restart."), "Paused while DayDream updates.", "issue: pause reason table")
        equal(RecordingCopy.issue("Writer stopped responding"), "Writer stopped responding", "issue: unknown text verbatim")
        equal(RecordingCopy.issue("Input capture needs attention"), "Keyboard and mouse recording needs attention",
              "issue: the app's input issue in Recording words")
        equal(RecordingCopy.issue("Awake. Resume explicitly after sleep."), "Paused while your Mac slept.", "issue: the wake reason is mapped too")

        // MARK: operationalIssue → presentation issue and attention line (amendments F0a)
        let opInputs = RecordingStateInputs(recording: true, recordingSince: since, resumeUnavailable: "Setup required", operationalIssue: "Input events are delayed")
        equal(opInputs.issue, "Input events are delayed", "issue = operationalIssue ?? resumeUnavailable (operational first)")
        equal(RecordingStateInputs(resumeUnavailable: "Setup required").issue, "Setup required", "issue falls back to resumeUnavailable")
        equal(RecordingStateInputs().issue, nil, "no issue without either")
        var withoutOp = opInputs; withoutOp.operationalIssue = nil
        equal(RecordingState.derive(opInputs), RecordingState.derive(withoutOp), "operationalIssue never changes the state")

        let recState = RecordingState.derive(opInputs)
        equal(recState.attentionLine(issue: opInputs.issue, now: now, timeZone: la), "Input events are delayed", "attention line while Recording")
        _ = strings(recState, issue: opInputs.issue)
        let inputIssue = RecordingStateInputs(recording: true, recordingSince: since, operationalIssue: "Input capture needs attention")
        equal(RecordingState.derive(inputIssue).attentionLine(issue: inputIssue.issue, now: now, timeZone: la), "Keyboard and mouse recording needs attention",
              "the input issue's attention line is in Recording words")
        _ = strings(RecordingState.derive(inputIssue), issue: inputIssue.issue)

        let blocked = RecordingStateInputs(resumeUnavailable: "Storage unavailable")
        let blockedState = RecordingState.derive(blocked)
        equal(blockedState.attentionLine(issue: blocked.issue, now: now, timeZone: la), nil, "no attention line when the issue is the Off detail")
        var blockedOp = blocked; blockedOp.operationalIssue = "Setup required"
        equal(blockedState.attentionLine(issue: blockedOp.issue, now: now, timeZone: la), "Finish setup to start recording.", "a different issue on Off is mapped and shown")
        equal(blockedState.detail(now: now, timeZone: la), "Storage needs attention. Nothing is recorded.", "the Off detail keeps the blocker")

        let permission = RecordingStateInputs(resumeUnavailable: "Permissions required", inputMonitoringGranted: false)
        let permissionState = RecordingState.derive(permission)
        equal(permissionState.attentionLine(issue: permission.issue, now: now, timeZone: la), nil, "no attention line for the permission gap itself")
        var permissionOp = permission; permissionOp.operationalIssue = "Storage unavailable"
        equal(permissionState.attentionLine(issue: permissionOp.issue, now: now, timeZone: la), "Storage needs attention. Nothing is recorded.", "an operational issue shows on Needs Permission")

        let sleepy = RecordingStateInputs(stopped: false, sessionReason: "Paused for sleep. Resume explicitly after waking.", operationalIssue: "Paused for sleep. Resume explicitly after waking.")
        equal(RecordingState.derive(sleepy).attentionLine(issue: sleepy.issue, now: now, timeZone: la), nil, "no attention line when the issue repeats the pause reason")
        equal(timed.attentionLine(issue: "  ", now: now, timeZone: la), nil, "a blank issue shows nothing")
        equal(timed.attentionLine(issue: "Writer model unavailable", now: now, timeZone: la), "Writer model unavailable", "an issue on a timed pause shows verbatim")
        _ = strings(timed, issue: "Writer model unavailable")

        // MARK: Vocabulary sweep over every produced string
        let menuLabels = outputs.filter { $0.hasPrefix("Day") && $0.contains(": ") && !$0.hasPrefix("Development") }
        check(!menuLabels.isEmpty && menuLabels.allSatisfy { $0.hasPrefix("DayDream: ") }, "menu bar labels use the DayDream casing")
        check(!outputs.contains { $0.contains("Daydream") }, "no output uses the wrong brand casing")
        let banned = outputs.filter { let l = $0.lowercased(); return l.contains("remember") || l.contains("capture") }
        check(banned.isEmpty, "no state string uses remember or capture vocabulary", banned.joined(separator: " | "))
        check(outputs.count > 100, "vocabulary sweep covered \(outputs.count) strings")

        if failures > 0 {
            FileHandle.standardError.write(Data("FAIL: \(failures) recording state assertion(s) failed\n".utf8))
            exit(1)
        }
        print("dd-recording-state-checks: all assertions passed")
    }
}
