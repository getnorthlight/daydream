import Foundation

// Recording state shared by every surface: toolbar capsule, status popover, menu bar,
// settings and the Focus List paused row. Foundation only, so it compiles on its own
// (scripts/dd-recording-state-checks.swift builds this file alone). Tints live in the kit.
//
// Copy is the DayDream copy deck (English only). Times are fixed to `h:mm a` in
// en_US_POSIX so the strings match the deck on every system locale.

/// The four states a person sees. Non-permission blockers are `off` plus a detail line.
public enum DaydreamCaptureState: String, CaseIterable, Sendable {
    case recording, paused, off, needsPermission
    public var title: String {
        switch self {
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .off: return "Off"
        case .needsPermission: return "Needs Permission"
        }
    }
}

public enum PermissionKind: String, CaseIterable, Hashable, Sendable {
    case accessibility, inputMonitoring
    public var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        }
    }
    /// perm-1004 (owner 10/3: "Needs Permission" said nothing about which one): the words a surface shows for the
    /// one permission to turn on next, `Turn on Accessibility` or `Turn on Input Monitoring`.
    public var turnOnTitle: String { "Turn on " + title }
    /// The permission to turn on first: Accessibility before Input Monitoring (Input Monitoring turned on later needs
    /// DayDream to restart, which it does by itself once both read on). nil when none is known to be missing.
    public static func next(_ missing: Set<PermissionKind>) -> PermissionKind? {
        allCases.first(where: missing.contains)
    }
    /// System Settings at this permission's Privacy & Security pane; nil opens Privacy & Security
    /// itself. The one public table (contract request W2-21); opening it is the caller's job, only on
    /// a press, and it never requests a permission.
    public static func settingsURL(_ kind: PermissionKind?) -> URL {
        let base = "x-apple.systempreferences:com.apple.preference.security"
        switch kind {
        case .accessibility?: return URL(string: base + "?Privacy_Accessibility")!
        case .inputMonitoring?: return URL(string: base + "?Privacy_ListenEvent")!
        case nil: return URL(string: base)!
        }
    }
}

/// What a recording control asks for. Each maps to exactly one `CaptureActions` closure.
public enum RecordingAction: Equatable, Sendable {
    case start, resume, stop, pause(minutes: Int), openSystemSettings, checkAgain
}

public enum RecordingState: Equatable, Sendable {
    case recording(since: Date?)
    /// `until == nil` is an open-ended pause. `reason` is already UI copy (`RecordingCopy.pauseReason`).
    case paused(until: Date?, since: Date?, reason: String?)
    /// `reason` is the blocker detail (`RecordingCopy.blocker`); nil is a plain Off.
    case off(since: Date?, reason: String?)
    /// Empty set: which permission is missing is unknown.
    case needsPermission(missing: Set<PermissionKind>)

    /// The only durations `TimedPause.begin` accepts. There is no "Tomorrow" and no "+15 min".
    public static let pausePresets = [5, 15, 30, 120]

    public var kind: DaydreamCaptureState {
        switch self {
        case .recording: return .recording
        case .paused: return .paused
        case .off: return .off
        case .needsPermission: return .needsPermission
        }
    }

    /// The single prominent action for the state. Recording has none: Stop is never blue.
    public var primaryAction: RecordingAction? {
        switch self {
        case .recording: return nil
        case .paused: return .resume
        case .off: return .start
        case .needsPermission: return .openSystemSettings
        }
    }

    /// The permission to turn on next while Needs Permission names one (`PermissionKind.next`); nil otherwise.
    public var nextPermission: PermissionKind? {
        if case .needsPermission(let missing) = self { return PermissionKind.next(missing) }
        return nil
    }

    /// The state's title where a surface shows one word or phrase: `Turn on Accessibility` (or `Turn on Input
    /// Monitoring`) while Needs Permission knows which permission is missing (perm-1004); else `kind.title`.
    public var title: String { nextPermission?.turnOnTitle ?? kind.title }

    /// "Recording" | "Paused · 12m" | "Paused" | "Off" | "Turn on Accessibility" | "Turn on Input Monitoring" |
    /// "Needs Permission" (which one is missing isn't known).
    public func capsuleLabel(now: Date) -> String {
        if case .paused(let until?, _, _) = self, let left = RecordingClock.minutesLeft(until: until, now: now) {
            return "Paused · " + RecordingClock.compact(minutes: left)
        }
        return title
    }

    /// The state's detail line (copy deck §8.1). nil only for Recording with an unknown start.
    public func detail(now: Date, timeZone: TimeZone) -> String? {
        switch self {
        case .recording(let since):
            return since.map { "Since " + RecordingClock.time($0, timeZone) }
        case .paused(let until?, _, _):
            let line = "Until " + RecordingClock.time(until, timeZone)
            guard let left = RecordingClock.minutesLeft(until: until, now: now) else { return line }
            return line + " · " + RecordingClock.spoken(minutes: left) + " left"
        case .paused(nil, _, let reason):
            return reason ?? "Paused by you"
        case .off(_, let reason):
            return reason ?? "Nothing is recorded until you start again."
        case .needsPermission(let missing):
            if missing == [.inputMonitoring] { return "Input Monitoring is off in System Settings." }
            if missing == [.accessibility] { return "Accessibility is off in System Settings." }
            // Both read as off: say so, as the single-permission lines and the Settings card do. The generic
            // "…are required." is only for an unknown set.
            if missing == Set(PermissionKind.allCases) { return RecordingCopy.permissionsOff }
            return RecordingCopy.permissionsRequired
        }
    }

    /// VoiceOver value for the capsule and status tiles.
    public func accessibilityValue(now: Date, timeZone: TimeZone) -> String {
        switch self {
        case .recording:
            return kind.title
        case .paused(let until?, _, _):
            let value = "Paused until " + RecordingClock.time(until, timeZone)
            guard let left = RecordingClock.minutesLeft(until: until, now: now) else { return value }
            return value + ", " + RecordingClock.spoken(minutes: left) + " left"
        case .paused(nil, _, _):
            // Mapped reasons usually start with "Paused"; don't say it twice.
            let reason = detail(now: now, timeZone: timeZone) ?? ""
            return reason.hasPrefix("Paused") ? reason : "Paused, " + reason
        case .off:
            return "Off, " + (detail(now: now, timeZone: timeZone) ?? "")
        case .needsPermission(let missing):
            guard !missing.isEmpty else { return "Needs permission, " + RecordingCopy.permissionsRequired }
            return "Needs permission: " + PermissionKind.allCases.filter(missing.contains).map(\.title).joined(separator: " and ")
        }
    }

    /// Menu bar item label: "DayDream: Recording", "DayDream: Paused until 4:36 PM", …
    public func menuBarAccessibilityLabel(now: Date, timeZone: TimeZone) -> String {
        if case .paused(let until?, _, _) = self {
            return "DayDream: Paused until " + RecordingClock.time(until, timeZone)
        }
        return "DayDream: " + title
    }

    /// The orange attention line for `issue` (`RecordingStateInputs.issue`, the value
    /// `CapturePresentation.issue` carries). nil when there is no issue or when the state
    /// already says it: the issue is the blocker or permission gap the state was derived from.
    /// A stop notice is never an issue (the app model keeps it to the notification), so beside any pause, a sleep,
    /// lock or user-switch one included, this line is a real reason, such as why Start was refused.
    public func attentionLine(issue: String?, now: Date, timeZone: TimeZone) -> String? {
        guard let raw = issue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if case .needsPermission = self, raw == RecordingCopy.permissionBlocker { return nil }
        // A keyboard-and-mouse pause already says what the app's input issue would: one line, not two.
        if case .paused(nil, _, let reason?) = self, raw == RecordingCopy.inputIssue,
           reason == RecordingCopy.inputUnreachable || reason == RecordingCopy.inputInterrupted { return nil }
        let line = RecordingCopy.issue(raw)
        return line == detail(now: now, timeZone: timeZone) ? nil : line
    }
}

/// Everything `derive` reads. Values come from the app model (F2); nothing here reads the OS.
public struct RecordingStateInputs: Equatable, Sendable {
    public var recording: Bool, stopped: Bool, development: Bool
    public var pauseUntil: Date?, pausedAt: Date?, recordingSince: Date?, stoppedAt: Date?
    public var resumeUnavailable: String?, sessionState: String?, sessionReason: String?
    public var accessibilityGranted: Bool?, inputMonitoringGranted: Bool?
    /// `MemoryViewModel.operationalIssue` (failed start, writer or input problems). It never
    /// changes the state; it becomes the attention line through `issue`.
    public var operationalIssue: String?
    /// "DayDream Preview" (`--preview-sample`): `development` too, said as the preview's own line.
    public var preview: Bool = false

    public init(recording: Bool = false, stopped: Bool = true, development: Bool = false,
                pauseUntil: Date? = nil, pausedAt: Date? = nil, recordingSince: Date? = nil, stoppedAt: Date? = nil,
                resumeUnavailable: String? = nil, sessionState: String? = nil, sessionReason: String? = nil,
                accessibilityGranted: Bool? = nil, inputMonitoringGranted: Bool? = nil,
                operationalIssue: String? = nil) {
        self.recording = recording; self.stopped = stopped; self.development = development
        self.pauseUntil = pauseUntil; self.pausedAt = pausedAt; self.recordingSince = recordingSince; self.stoppedAt = stoppedAt
        self.resumeUnavailable = resumeUnavailable; self.sessionState = sessionState; self.sessionReason = sessionReason
        self.accessibilityGranted = accessibilityGranted; self.inputMonitoringGranted = inputMonitoringGranted
        self.operationalIssue = operationalIssue
    }

    /// The presentation issue, exactly as the app model builds it: `operationalIssue ?? resumeUnavailable`.
    public var issue: String? { operationalIssue ?? resumeUnavailable }

    /// Permissions read as not granted. Unknown (nil) reads are left out.
    public var missingPermissions: Set<PermissionKind> {
        var missing = Set<PermissionKind>()
        if accessibilityGranted == false { missing.insert(.accessibility) }
        if inputMonitoringGranted == false { missing.insert(.inputMonitoring) }
        return missing
    }
}

public extension RecordingState {
    /// Pure derivation, in this order (the checks pin it):
    /// 1. development → Off "Development Trial · recording is disabled"
    /// 2. recording → Recording
    /// 3. "Permissions required" or session "permission_denied" → Needs Permission
    /// 4. a timed pause → Paused until
    /// 5. any other blocker → Off + mapped blocker
    /// 6. not stopped → open-ended Paused + mapped reason
    /// 7. otherwise → Off
    static func derive(_ i: RecordingStateInputs) -> RecordingState {
        if i.development { return .off(since: nil, reason: i.preview ? RecordingCopy.previewSample : RecordingCopy.developmentTrial) }
        if i.recording { return .recording(since: i.recordingSince) }
        if i.resumeUnavailable == RecordingCopy.permissionBlocker || i.sessionState == "permission_denied" {
            return .needsPermission(missing: i.missingPermissions)
        }
        if let until = i.pauseUntil { return .paused(until: until, since: i.pausedAt, reason: nil) }
        if let blocker = i.resumeUnavailable { return .off(since: i.stoppedAt, reason: RecordingCopy.blocker(blocker)) }
        if !i.stopped { return .paused(until: nil, since: i.pausedAt, reason: RecordingCopy.pauseReason(i.sessionReason)) }
        return .off(since: i.stoppedAt, reason: nil)
    }
}

/// Core strings → user copy (copy deck §8.2). Unknown strings pass through verbatim.
public enum RecordingCopy {
    /// The `resumeUnavailable` value that means a permission gap, not a blocker.
    public static let permissionBlocker = "Permissions required"
    public static let permissionsRequired = "Accessibility and Input Monitoring are required."
    /// Needs Permission with both permissions read as off.
    public static let permissionsOff = "Accessibility and Input Monitoring are off in System Settings."
    public static let developmentTrial = "Development Trial · recording is disabled"
    /// "DayDream Preview" (PreviewSample.line): sample data, and nothing records.
    public static let previewSample = "Preview: sample data, not recording"
    static let sleptPause = "Paused while your Mac slept."
    /// The download-window warning (MacMemApp's `LaunchLocation`): the Off detail while DayDream runs from its
    /// disk image or a translocated copy. The menu bar card offers Open Applications Folder beside it.
    public static let moveToApplications = "Move DayDream to Applications first."
    static let storageAttention = "Storage needs attention. Nothing is recorded."
    /// A failed save while DayDream tries again by itself (MemoryCore's CaptureFault reasons).
    public static let savingRetry = "Couldn't save for a moment. Trying again."
    public static let savingRetryPersistent = "Can't save right now. Trying again every minute."
    public static let savingRetryFull = "Your Mac is out of space. Trying again."
    /// An older storage pause nothing retries by itself: Resume, which the Paused state always shows, tries again.
    public static let savingFailed = "Couldn't save. Resume to try again."
    /// Recording didn't start again after sleep, a lock or a user switch (or after its save retries): the pause no
    /// longer promises a start. Why Start was refused, if the app knows, is the orange line beside it.
    public static let notResumed = "Didn't start again. Resume when you're ready."
    /// A second copy of DayDream (for example one still open in the download window) holds the recorder lock, and it
    /// couldn't be brought forward (a copy that can reach it hands off and exits instead). One short line that asks
    /// nothing of the person: the history opens by itself once the other copy lets go of it (gold r2).
    public static let anotherCopy = "DayDream is already open."
    /// An automatic start waits for an import or backup to end, then records by itself (MacMemApp's waitingReason).
    public static let waitingForOperation = "Paused until your import or backup finishes."
    /// Off while an import or backup runs (it clears itself), and while a restore preview waits for Confirm or Cancel.
    public static let operationRunning = "An import or backup is running."
    public static let restorePending = "Finish or cancel the restore in Settings."
    /// The person's own pause, and every pause they started some other way (an uninstall, a rollback, quitting).
    public static let pausedByYou = "Paused by you"
    /// Start couldn't reach the keyboard and mouse (EventCapture couldn't install its event tap although both
    /// permissions read as allowed): macOS lets DayDream see them only after it reopens, so Resume goes to the one
    /// button that does that (MacMemApp's `setupStepForStart`).
    public static let inputUnreachable = "Keyboard and mouse aren't reaching DayDream."
    /// Keyboard and mouse input stopped reaching DayDream while it recorded (macOS turned its event tap off).
    public static let inputInterrupted = "Keyboard and mouse input was interrupted. Resume when you're ready."
    /// Recording stopped on its own for a moment (a permission read that came back, a recorder replaced).
    public static let interrupted = "Recording was interrupted. Resume when you're ready."
    /// DayDream is installing an update and reopens by itself.
    public static let updating = "Paused while DayDream updates."
    /// The app model's issue (`MemoryViewModel.choicesUnsavedIssue`) when Start was refused over app choices that
    /// didn't save. Apps to remember shows the problem and its one fix.
    public static let choicesUnsaved = "Your app choices didn't save"
    /// The app model's issue when the keyboard and mouse can't be reached (`operationalIssue`).
    public static let inputIssue = "Input capture needs attention"
    /// The app model's issue when its history upkeep failed three times in a row (MacMemApp's `MemoryViewModel.summaryIssue`,
    /// "Summary writer needs attention": MemoryCore's SummaryWorker, which keeps what search and AI apps read, the kept
    /// period and typed text past its time up to date). Settings › Summaries can't fix it; running it again can. It runs
    /// again after every save and every minute and clears the first time it works; Try Again runs it now.
    public static let historyNotUpdated = "Couldn't update your history"
    /// The app model's issue when a deletion didn't go through (`MemoryViewModel.deletionIssue`, "Deletion failed").
    /// DayDream tries that deletion again every minute and the line clears once it works; Try Again tries now.
    public static let deletionNotFinished = "Couldn't finish deleting"
    /// The issue lines whose one fix is to run the same job again: the orange line ends in Try Again
    /// (`MenuBarMenu.attentionAction`) and so does the Settings card (`SettingsStatusAction.retry`).
    public static let retriedIssues: Set<String> = [historyNotUpdated, deletionNotFinished]
    public static let retryTitle = "Try Again"
    /// A replacement (or an older collector) stops Start until it is reviewed in Settings › Advanced.
    public static let replacementReview = "Review the replacement in Settings before recording."

    /// Every reason the app or core writes into the capture session (MacMemApp, EventCapture, Coordinator,
    /// CaptureSession, WakeResume, CaptureFault, InstallationReview), so none reaches a surface as internal wording
    /// such as "Resume explicitly" or "Input event tap unavailable". scripts/ui-copy-checks.swift finds every reason
    /// the sources can write and fails when one is missing here. Every line that starts with "Paused " is "Paused by
    /// you" or "Paused while …", so the Settings card's "Paused · …" never reads as a fragment.
    private static let pauseReasons: [String: String] = [
        "Paused for sleep. Resume explicitly after waking.": sleptPause,
        // On wake the app pauses again with its own reason, which is the one a person sees after opening the lid.
        "Awake. Resume explicitly after sleep.": sleptPause,
        "System slept or session became inactive. Resume explicitly.": "Paused while your Mac slept or you switched users.",
        "Paused when your login session became inactive. Resume explicitly.": "Paused while you switched users.",
        "Paused for screen lock. Resumes after unlock.": "Paused while your screen was locked.",
        // MacMemApp's RecordingStopCause.notResumedReason: the wake rules or the save retries gave up.
        "Recording didn't start again by itself. Resume explicitly.": notResumed,
        "Paused for update. Start recording explicitly after restart.": updating,
        "Paused for preference save; resume explicitly.": "Paused while settings were saved.",
        "Preferences changed. Resume explicitly.": "Paused while settings were saved.",
        "Timed pause ended without safe focus. Resume explicitly.": "Your pause ended. Resume when you're ready.",
        "Resume canceled: prerequisites changed. Review Settings.": "Your pause ended because something changed. Review Settings.",
        "Input tap was disabled. Resume explicitly.": inputInterrupted,
        "Input tap disabled": inputInterrupted,
        // EventCapture.start couldn't install its tap (gold/int: ui-copy's words; lifecycle's "couldn't start. Resume to
        // try again" is gone because Resume now leads to Quit & Reopen where DayDream can reopen itself).
        "Input event tap unavailable. No recording started.": inputUnreachable,
        // MacMemApp's MemoryViewModel.waitingReason.
        "Waiting for an import or backup to finish.": waitingForOperation,
        "Recording stopped": interrupted,
        "Replacing stopped capture": interrupted,
        // The person's own pauses and stops, however they started them.
        "Paused by you": pausedByYou,
        "Stopped by you": pausedByYou,
        "Stopped by you. Resume explicitly.": pausedByYou,
        "Paused for uninstall": pausedByYou,
        "Paused for explicit rollback": pausedByYou,
        "App closed. Capture starts OFF next time.": pausedByYou,
        // gold/lifecycle's quit reason (the launch intent starts recording again when it was on).
        "App closed.": pausedByYou,
        // The launch state before any Start: nothing records until one.
        "Start recording explicitly. Restart never resumes capture.": "Nothing is recorded until you start again.",
        "Recording is off.": "Nothing is recorded until you start again.",
        // Permission reasons (a Needs Permission state shows its own line; these are here so none can leak).
        "Accessibility and Input Monitoring permission are required. No permission was requested.": permissionsRequired,
        "Permission was revoked. Resume explicitly after granting it.": permissionsRequired,
        // A replacement or an older collector blocks Start ("Review replacement" says so as the Off line).
        "Resolve replacement or rollback before recording.": replacementReview,
        "Legacy collector footprint detected. Recording is blocked until a verified replacement preserves its consumers. Nothing was stopped or imported.": replacementReview,
        // CaptureFault's reasons while the app tries again (MemoryCore; this file compiles without it).
        "Storage write failed. Retrying automatically.": savingRetry,
        "Storage keeps failing. Retrying every minute.": savingRetryPersistent,
        "Storage full. Retrying automatically.": savingRetryFull,
        // Older storage reasons. Never "Quit and reopen" or "Storage needs attention" over a pause: Resume tries again.
        "Storage health check failed. Resume explicitly.": savingFailed,
        "Capture storage or proof failed. Nothing retried; resume explicitly.": savingFailed,
        "Preference save failed. Recording stopped; resume explicitly.": savingFailed,
        "A durable write failed. Recording stopped; resume explicitly.": savingFailed,
        "Pause could not be persisted. Recording stopped; check storage before resuming.": savingFailed,
        "Recording could not start. Check local storage.": savingFailed,
        "Storage unavailable; recording stopped.": savingFailed,
        // Listed with the storage reasons in MacMemApp's RecordingStopCause; a read, not a save, so not "Couldn't save".
        "Memory read failed. Recording paused.": interrupted,
    ]
    /// Operational issues the app model raises (`operationalIssue`), in plain words. The app keeps its own names for
    /// them (MacMemApp's `summaryIssue` and `deletionIssue`); no surface shows those. scripts/ui-copy-checks.swift finds
    /// every issue the app can set and fails when one reaches a surface without its own words, its one button or a way
    /// to clear by itself.
    private static let operationalIssues: [String: String] = [
        inputIssue: "Keyboard and mouse recording needs attention",
        "Summary writer needs attention": historyNotUpdated,
        "Deletion failed": deletionNotFinished,
    ]
    private static let blockers: [String: String] = [
        "Setup required": "Finish setup to start recording.",
        "Storage unavailable": storageAttention,
        "Storage needs attention": storageAttention,
        // MacMemApp's MemoryViewModel.anotherCopyBlocker: a second copy holds the recorder lock.
        "Another copy of DayDream is open": anotherCopy,
        "Review replacement": replacementReview,
        "Replacement in progress": replacementReview,
        "Resume after waking": "Resume after your Mac wakes.",
        // MacMemApp's MemoryViewModel.operationBlocker and restoreBlocker.
        "Import or backup running": operationRunning,
        "Restore waiting for review": restorePending,
        "Move DayDream to Applications first": moveToApplications,
        "Disabled in Development Trial": developmentTrial
    ]

    /// Every pause reason's UI detail and every known blocker's Off detail (sorted, each once): what a surface can be
    /// asked to show in place of the state's own words, so the checks can fit each one.
    public static var pauseDetails: [String] { Array(Set(pauseReasons.values)).sorted() }
    public static var blockerDetails: [String] { Array(Set(blockers.values)).sorted() }

    /// Session pause reason → UI detail. nil or blank stays nil.
    public static func pauseReason(_ core: String?) -> String? {
        guard let core = core?.trimmingCharacters(in: .whitespacesAndNewlines), !core.isEmpty else { return nil }
        return pauseReasons[core] ?? core
    }

    /// Non-permission `resumeUnavailable` value → Off detail.
    public static func blocker(_ resumeUnavailable: String) -> String {
        blockers[resumeUnavailable] ?? resumeUnavailable
    }

    /// The Off detail for a blocker the table knows; nil for anything else, such as an
    /// operational issue, which is not why recording is off.
    public static func knownBlocker(_ core: String?) -> String? {
        guard let core = core?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return blockers[core]
    }

    /// Any presentation issue (operational issue, blocker or pause reason) → attention-line copy.
    public static func issue(_ core: String) -> String {
        if core == permissionBlocker { return permissionsRequired }
        return blockers[core] ?? pauseReasons[core] ?? operationalIssues[core] ?? core
    }
}

/// Clock copy for this file only (it must compile without DaydreamFormat).
private enum RecordingClock {
    static func time(_ date: Date, _ zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = zone; f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
    /// Whole minutes left, rounded up so a running pause never reads "0m". nil once it has ended.
    static func minutesLeft(until: Date, now: Date) -> Int? {
        let seconds = until.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        return Int((seconds / 60).rounded(.up))
    }
    /// "12m", "1h 45m", "2h".
    static func compact(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
    /// "12 minutes", "1 minute", "1 hour 45 minutes", "2 hours".
    static func spoken(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        let hours = h == 1 ? "1 hour" : "\(h) hours", mins = m == 1 ? "1 minute" : "\(m) minutes"
        if h == 0 { return mins }
        return m == 0 ? hours : hours + " " + mins
    }
}
