import Foundation

// Sleep, screen lock and user switching (SPEC 6.3 R1, owner decision 6), as pure rules.
//
// - When the Mac sleeps, the screen locks or the person switches to another user, recording pauses.
// - When every one of those has ended, and the Mac has settled for a moment, recording starts again by
//   itself if it was on before. A timed pause that was running picks up where it was (or ends, if its
//   time passed meanwhile).
// - If it can't start again, or recording stops for any reason other than the person pausing,
//   stopping or quitting, the person gets one notification and the menu bar says why and what to do.
// - A save that failed is not one of those: recording stays wanted and StorageRetry starts it again by itself,
//   with no notification unless it keeps failing for two minutes.
// - Nothing here reads the system, starts recording or posts a notification: MemoryViewModel runs the
//   effects. Foundation only, so scripts/recording-wake-checks.swift compiles this file on its own.

/// What took the Mac away from the person.
enum WakeSuspension: String, CaseIterable, Sendable {
    case sleep, screenLock, userSwitch

    /// The reason written into the capture session when recording pauses for it.
    var pauseReason: String {
        switch self {
        case .sleep: return "Paused for sleep. Resume explicitly after waking."
        case .screenLock: return "Paused for screen lock. Resumes after unlock."
        case .userSwitch: return "Paused when your login session became inactive. Resume explicitly."
        }
    }
}

/// What to do once every suspension has ended.
enum WakeResumePlan: Equatable, Sendable {
    /// Recording was off or paused by the person: leave it as it is.
    case nothing
    /// Recording was on: start it again.
    case record
    /// A timed pause was running: pick it up until the same time, or start recording if that time passed.
    case timedPause(until: Date)
}

/// The sleep, lock and user-switch state machine. The model feeds it events and runs the effects.
struct WakeResumeMachine: Equatable {
    enum Effect: Equatable {
        /// Pause the recorder now (commit typed text first), with the suspension's reason.
        case pause(WakeSuspension)
        /// Read the lock and console state after `after` seconds, then call `settled(token:…)`.
        case settle(after: TimeInterval, token: Int)
        /// Start recording again (the same path as the person's Start), then call `started(succeeded:…)`.
        case start
        /// Pick up the timed pause until this time, then call `started(succeeded:…)`.
        case resumeTimedPause(until: Date)
        /// Tell the person recording didn't start again.
        case notify(RecordingNotice)
        /// The start failed on a save: StorageRetry keeps trying by itself (no notice).
        case retryStorage
    }

    /// How long the Mac settles after the last suspension ends, before recording starts again.
    static let settleDelay: TimeInterval = 3
    /// A start that fails right after wake is tried once more after this long (not for a missing permission).
    static let retryDelay: TimeInterval = 10
    static let maxAttempts = 2

    private(set) var active: Set<WakeSuspension> = []
    private(set) var plan: WakeResumePlan = .nothing
    /// Every suspension since the plan was made, for the notice's wording.
    private(set) var episode: Set<WakeSuspension> = []
    private(set) var attempts = 0
    private(set) var token = 0

    var suspended: Bool { !active.isEmpty }

    /// A suspension began.
    /// - `wantsRecording`: the person had recording on (a suspension that already paused it counts as on).
    /// - `timedPauseUntil`: the end of the person's timed pause, if one is running.
    /// - `recorderActive`: something is live and must pause: a recorder that is recording, or a timed pause. A
    ///   recorder that already stopped on its own is not.
    ///
    /// The pause it asks for says "Resumes after unlock", so it is asked for only with a plan that resumes: a live
    /// recorder the person hadn't paused always gets one.
    mutating func begin(_ suspension: WakeSuspension, wantsRecording: Bool, timedPauseUntil: Date?, recorderActive: Bool) -> [Effect] {
        let first = active.isEmpty
        active.insert(suspension)
        token += 1 // a pending settle or retry no longer applies
        if first && plan == .nothing {
            plan = wantsRecording ? .record : timedPauseUntil.map { .timedPause(until: $0) } ?? .nothing
            episode = []
            attempts = 0
        } else if first {
            // A pending settle or 10 s retry no longer applies (the token above): the next wake gets its own tries.
            attempts = 0
        }
        // Something live that no plan covers can only be recording the person left on.
        if recorderActive && plan == .nothing { plan = .record; episode = []; attempts = 0 }
        if plan != .nothing { episode.insert(suspension) }
        return recorderActive ? [.pause(suspension)] : []
    }

    /// A suspension ended. Once the last one has, the Mac settles before anything starts.
    mutating func end(_ suspension: WakeSuspension) -> [Effect] {
        guard active.remove(suspension) != nil, active.isEmpty else { return [] }
        token += 1
        return plan == .nothing ? [] : [.settle(after: Self.settleDelay, token: token)]
    }

    /// Clears a lock or user switch the system no longer reports (an unlock or switch-back notice that never
    /// came). Sleep is cleared only by the wake notice.
    mutating func reconcile(screenLocked: Bool, onConsole: Bool) -> [Effect] {
        var cleared = false
        if !screenLocked, active.remove(.screenLock) != nil { cleared = true }
        if onConsole, active.remove(.userSwitch) != nil { cleared = true }
        guard cleared, active.isEmpty else { return [] }
        token += 1
        return plan == .nothing ? [] : [.settle(after: Self.settleDelay, token: token)]
    }

    /// The settle read. A Mac that woke to a locked screen, or to another user, waits for that too.
    mutating func settled(token: Int, screenLocked: Bool, onConsole: Bool, now: Date) -> [Effect] {
        guard token == self.token, active.isEmpty, plan != .nothing else { return [] }
        // Woke to a locked screen or another user: a new wait, so its end gets its own tries.
        if screenLocked { active.insert(.screenLock); episode.insert(.screenLock); attempts = 0; return [] }
        if !onConsole { active.insert(.userSwitch); episode.insert(.userSwitch); attempts = 0; return [] }
        switch plan {
        case .nothing:
            return []
        case .record:
            attempts += 1
            return [.start]
        case .timedPause(let until):
            attempts += 1
            return until > now ? [.resumeTimedPause(until: until)] : [.start]
        }
    }

    /// What `.start` or `.resumeTimedPause` did. `succeeded`: recording, or the timed pause, is running
    /// again. `cause`: why not, otherwise. `resumeTitle`: the menu's name for starting again.
    mutating func started(succeeded: Bool, cause: RecordingStopCause, resumeTitle: String) -> [Effect] {
        guard plan != .nothing else { return [] }
        if succeeded { plan = .nothing; attempts = 0; return [] }
        // A save that failed: StorageRetry takes over and keeps trying by itself, without a notice.
        if cause == .storage { plan = .nothing; attempts = 0; return [.retryStorage] }
        if attempts < Self.maxAttempts && cause.retryable {
            token += 1
            return [.settle(after: Self.retryDelay, token: token)]
        }
        let notice = RecordingNotice.resumeFailed(after: episode, cause: cause, resumeTitle: resumeTitle)
        plan = .nothing; attempts = 0
        return [.notify(notice)]
    }

    /// The person started, paused or stopped recording: their choice replaces the plan.
    mutating func personActed() {
        plan = .nothing; attempts = 0; episode = []
        token += 1
    }

    /// gold/int (save-path CRITIC-GAP-autosave): recording became wanted while suspended (a save that stopped it
    /// landed behind the lock screen). The end of the suspension starts it, with its own tries.
    mutating func wantsRecording() {
        guard suspended, plan == .nothing else { return }
        plan = .record; episode = active; attempts = 0
    }

    /// gold r2 review 1: the history opened during a suspension (after a busy moment at launch, or once another copy let
    /// go), with the launch plan. That plan replaces the one the suspension began with (made while the history was still
    /// opening): the end of the suspension runs it, with its own tries, as for a launch behind the lock screen.
    mutating func adopt(_ plan: WakeResumePlan) {
        guard suspended else { return }
        self.plan = plan; episode = plan == .nothing ? [] : active; attempts = 0
    }

    /// The start found an import or backup still running: the model starts recording once it ends
    /// (`MemoryViewModel.startWhenFree`), so the plan ends here, with no retry and no notice.
    mutating func handedOff() {
        plan = .nothing; attempts = 0; episode = []
        token += 1
    }
}

/// Recording the person had on when DayDream or the Mac last quit starts again at the next launch (owner decision,
/// test 5): a restart, a logout, a crash, an update or a quit all keep it. Only their own Pause or Stop (or a stop on
/// its own they were told about) clears it. A timed pause is kept until its end. Pure: the model saves `value` and reads
/// `plan` once at launch; the start itself goes through the same guards as Start.
enum LaunchResume {
    /// The saved intent (UserDefaults): ["recording": true], or ["until": seconds since 1970] for a timed pause.
    static let key = "DaydreamRecordingWantedV1"

    enum Plan: Equatable, Sendable {
        case none
        case record
        /// Pick the timed pause up until the same time (recording starts if that has passed).
        case timedPause(until: Date)
    }

    /// What to save for the model's state now; nil removes the saved intent.
    static func value(wanted: Bool, pauseUntil: Date?) -> [String: Any]? {
        if let pauseUntil { return ["until": pauseUntil.timeIntervalSince1970] }
        return wanted ? ["recording": true] : nil
    }

    /// The launch plan from the saved intent and `updated` (sat5's update marker, `UpdateResume`, read once).
    static func plan(saved: [String: Any]?, updated: Bool, now: Date) -> Plan {
        if let until = saved?["until"] as? Double {
            let end = Date(timeIntervalSince1970: until)
            return end > now ? .timedPause(until: end) : .record
        }
        return saved?["recording"] as? Bool == true || updated ? .record : .none
    }
}

/// Recording paused because a save failed, and starts again by itself (the model runs the ordinary Start after each
/// wait). Pure: the model feeds it failures and successes and reads when to try.
///
/// - Waits 2, 5, 15, 30, then 60 seconds between tries, until recording starts again or the person pauses or stops.
/// - A save that fails again within `stableAfter` of recording starting again continues the same run of failures, so
///   a fault that comes back after every start still backs off to once a minute instead of starting every 2 s.
/// - After two minutes of failing it is persistent: one notice goes out (`RecordingNotice.storageRetrying`), and the
///   line says it tries every minute. The notice goes once recording starts again.
/// - Nothing is replayed: every try is a fresh Start, which reads the saved choices again.
struct StorageRetry: Equatable {
    static let delays: [TimeInterval] = [2, 5, 15, 30, 60]
    static let persistentAfter: TimeInterval = 120
    /// Failures closer together than this are one failure: the same fault, reported by more than one path.
    static let sameFailure: TimeInterval = 1
    /// Recording this long after starting again without a failed save ends the run of failures.
    static let stableAfter: TimeInterval = 60

    private(set) var firstFailure: Date?
    private(set) var lastFailure: Date?
    private(set) var failures = 0
    /// The persistent notice went out in this run of failures (never twice).
    private(set) var notified = false
    /// When recording last started again during this run of failures.
    private(set) var recovered: Date?

    /// Recording is paused for a failed save and a try is due.
    var active: Bool { firstFailure != nil && recovered == nil }
    /// It has failed for `persistentAfter` without recording for `stableAfter`.
    func persistent(now: Date) -> Bool { firstFailure.map { now.timeIntervalSince($0) >= Self.persistentAfter } ?? false }
    /// The wait before the next try.
    var nextDelay: TimeInterval { Self.delays[min(max(failures - 1, 0), Self.delays.count - 1)] }
    /// The wait before the next try, once a minute when persistent (what its line says).
    func nextDelay(now: Date) -> TimeInterval { persistent(now: now) ? Self.delays[Self.delays.count - 1] : nextDelay }
    /// How long a try that something the person must fix held back waits before looking again.
    static let waitDelay: TimeInterval = 60

    /// A save failed, or a try did. True exactly once per run of failures: when they have lasted `persistentAfter`
    /// (post the notice).
    mutating func failed(now: Date) -> Bool {
        if let since = recovered {
            if now.timeIntervalSince(since) >= Self.stableAfter { self = StorageRetry() } else { recovered = nil }
        }
        if firstFailure == nil { firstFailure = now }
        if failures == 0 || lastFailure.map({ abs(now.timeIntervalSince($0)) >= Self.sameFailure }) ?? true {
            failures += 1
            lastFailure = now
        }
        guard !notified, persistent(now: now) else { return false }
        notified = true
        return true
    }
    /// Recording started again, or a heartbeat saved after a fault: no try is due. True if the persistent notice is
    /// out (clear it). The run of failures ends once recording has lasted `stableAfter` (`failed` checks).
    @discardableResult mutating func succeeded(now: Date) -> Bool {
        guard firstFailure != nil else { return false }
        if recovered == nil { recovered = now }
        return notified
    }
    /// The person paused, stopped or quit: their choice ends the retries.
    mutating func personActed() { self = StorageRetry() }

    enum Step: Equatable {
        /// Nothing to do: no retry is due, recording is on, or the person doesn't want it.
        case none
        /// Start recording now.
        case start
        /// Asleep, locked or switched away: the wake rules start recording after that ends (a failed start comes back).
        case leaveToWake
        /// Something the person must fix stands (a permission, unsaved choices): look again after the next wait.
        case wait
    }
    /// What a due try does now.
    func step(recording: Bool, wanted: Bool, suspended: Bool, blocked: Bool) -> Step {
        guard active, !recording, wanted else { return .none }
        if suspended { return .leaveToWake }
        return blocked ? .wait : .start
    }
}

/// Why recording stopped when the person didn't stop it.
enum RecordingStopCause: Equatable, Sendable {
    /// The person paused, stopped, quit, installed an update or saved a setting that stops recording.
    case person
    /// Sleep, screen lock or a user switch: WakeResumeMachine starts it again.
    case suspension
    /// A macOS permission is off. The two flags say which (both false: unknown).
    case permission(accessibility: Bool, inputMonitoring: Bool)
    /// The history couldn't be written.
    case storage
    /// Keyboard and mouse input stopped reaching DayDream.
    case input
    /// DayDream runs from the download window.
    case moveApp
    /// A restore preview waits for Confirm or Cancel (Settings › Backup and restore).
    case restore
    /// Anything else.
    case other

    /// For the log: the kind only.
    var logName: String {
        switch self {
        case .person: return "by the person"
        case .suspension: return "sleep, lock or user switch"
        case .permission: return "permission off"
        case .storage: return "save failed"
        case .input: return "input stopped"
        case .moveApp: return "download window"
        case .restore: return "restore waiting"
        case .other: return "other"
        }
    }

    /// Worth one more try after wake: a permission or the download window won't fix itself in seconds.
    var retryable: Bool {
        switch self {
        case .permission, .moveApp, .restore, .person: return false
        default: return true
        }
    }

    /// The reason EventCapture writes when the Mac sleeps or the session goes inactive (its own observer).
    static let captureSuspensionReason = "System slept or session became inactive. Resume explicitly."
    static let preferenceSaveReason = "Paused for preference save; resume explicitly."
    /// Reasons the app writes for the person's own pauses and stops (Pause, Stop, a setting they saved,
    /// an update they installed, quitting, a rollback or an uninstall they started). No notice for these.
    static let personReasons: Set<String> = [
        "Paused by you",
        "Stopped by you. Resume explicitly.",
        preferenceSaveReason,
        "Preferences changed. Resume explicitly.",
        "Paused for update. Start recording explicitly after restart.",
        "App closed.",
        "Paused for explicit rollback",
        "Paused for uninstall",
    ]
    /// The reason the app writes once recording won't start again by itself (the wake rules or the save retries gave
    /// up): a pause line that promised a start is no longer true. RecordingCopy says "Didn't start again. Resume when
    /// you're ready."; the reason Start refused shows beside it.
    /// The model's resume blocker while a restore preview waits for review (`MemoryViewModel.restoreBlocker`).
    static let restoreBlocker = "Restore waiting for review"
    static let notResumedReason = "Recording didn't start again by itself. Resume explicitly."
    /// Pause reasons whose line says, or implies, that recording starts again by itself: the sleep, lock and
    /// user-switch pauses and the save retries (CaptureFault's reasons; this file compiles without MemoryCore).
    static let resumesByItself: Set<String> = Set(WakeSuspension.allCases.map(\.pauseReason)).union([
        captureSuspensionReason,
        "Storage write failed. Retrying automatically.",
        "Storage keeps failing. Retrying every minute.",
        "Storage full. Retrying automatically.",
    ])
    static let storageReasons: Set<String> = [
        // CaptureFault's reasons while the app tries again (MemoryCore; this file compiles without it).
        "Storage write failed. Retrying automatically.",
        "Storage keeps failing. Retrying every minute.",
        "Storage full. Retrying automatically.",
        "Storage health check failed. Resume explicitly.",
        "Capture storage or proof failed. Nothing retried; resume explicitly.",
        "Preference save failed. Recording stopped; resume explicitly.",
        "A durable write failed. Recording stopped; resume explicitly.",
        "Pause could not be persisted. Recording stopped; check storage before resuming.",
        "Storage unavailable; recording stopped.",
        "Recording could not start. Check local storage.",
        "Memory read failed. Recording paused.",
    ]

    /// Why recording is not on, from what the model can read. `accessibility`/`inputMonitoring`: the last
    /// permission reads (nil = not read). `blocker`: the model's resume blocker. `suspended`: a sleep,
    /// lock or user switch is under way.
    static func infer(sessionState: String?, sessionReason: String?, accessibility: Bool?, inputMonitoring: Bool?,
                      blocker: String?, suspended: Bool) -> RecordingStopCause {
        let reason = sessionReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if suspended || reason == captureSuspensionReason || WakeSuspension.allCases.contains(where: { $0.pauseReason == reason }) {
            return .suspension
        }
        if personReasons.contains(reason) || reason.hasPrefix("Paused for uninstall") { return .person }
        if blocker == LaunchLocation.blockerValue { return .moveApp }
        if blocker == restoreBlocker { return .restore }
        // A denial the session kept while both permissions read on describes nothing (the popover reads it as Off, and
        // Start works): it is not a permission stop, so no notice says a permission is off.
        let bothOn = accessibility == true && inputMonitoring == true
        if accessibility == false || inputMonitoring == false || (sessionState == "permission_denied" && !bothOn) || blocker == "Permissions required" {
            return .permission(accessibility: accessibility == false, inputMonitoring: inputMonitoring == false)
        }
        if sessionState == "error" || storageReasons.contains(reason) || blocker == "Storage needs attention" || blocker == "Storage unavailable" {
            return .storage
        }
        if reason.hasPrefix("Input tap") || reason.hasPrefix("Input event tap") { return .input }
        return .other
    }
}

/// One notification, and the line the menu bar shows until recording starts again. Plain words; each
/// says what happened and what to do.
struct RecordingNotice: Equatable, Sendable {
    let title: String
    /// The notification's text.
    let body: String
    /// The same text (the menu bar card no longer shows it: the state's own line says why).
    var line: String { body }

    static let stoppedTitle = "DayDream stopped recording"
    /// A stop that left recording Paused (a lost keyboard and mouse connection, a recorder replaced): the notice says
    /// what the menu bar says, Paused, and names its Resume Now.
    static let pausedTitle = "DayDream paused recording"
    static let notRestartedTitle = "DayDream didn't start recording again"

    /// The one notice for saves that keep failing (StorageRetry has tried for two minutes). It goes when saving works
    /// again. Nothing for the person to do: recording starts again by itself.
    static let storageRetrying = RecordingNotice(title: "DayDream can't save right now", body: "Recording is paused and starts again by itself.")

    /// A stop the person didn't ask for. nil for the person's own stops, for suspensions, and for a failed save
    /// (StorageRetry starts recording again by itself; `storageRetrying` goes out only if it keeps failing).
    /// `resumeTitle`: the menu's name for starting again ("Start Recording" or "Resume Recording"). "Resume Recording"
    /// means the state is Paused (the switch stays on): the notice then says paused, never stopped, as the menu bar does.
    static func stopped(_ cause: RecordingStopCause, resumeTitle: String) -> RecordingNotice? {
        switch cause {
        case .person, .suspension, .storage: return nil
        default:
            let paused = resumeTitle == "Resume Recording"
            return RecordingNotice(title: paused ? pausedTitle : stoppedTitle,
                                   body: why(cause, lead: paused ? "Recording paused" : "Recording stopped") + " " + how(cause, resumeTitle: resumeTitle))
        }
    }

    /// Recording was on before the Mac slept, locked or switched users, and it couldn't start again.
    static func resumeFailed(after episode: Set<WakeSuspension>, cause: RecordingStopCause, resumeTitle: String) -> RecordingNotice {
        if cause == .storage { return storageRetrying }
        let when: String
        if episode.contains(.sleep) { when = "after your Mac woke" }
        else if episode.contains(.screenLock) { when = "after you unlocked your Mac" }
        else { when = "after you switched back" }
        let why: String
        switch cause {
        case .permission, .input, .moveApp, .restore: why = " " + Self.why(cause, lead: "It stopped")
        default: why = ""
        }
        return RecordingNotice(title: notRestartedTitle,
                               body: "Recording didn't start again " + when + "." + why + " " + how(cause, resumeTitle: resumeTitle))
    }

    /// A timed pause ended and recording couldn't start again.
    static func timedPauseEnded(cause: RecordingStopCause, resumeTitle: String) -> RecordingNotice {
        notRestarted("Your pause ended, but recording didn't start again.", cause: cause, resumeTitle: resumeTitle)
    }

    /// Recording was on when DayDream or the Mac last quit, and it couldn't start again when DayDream opened.
    static func reopenFailed(cause: RecordingStopCause, resumeTitle: String) -> RecordingNotice {
        notRestarted("Recording didn't start again when DayDream opened.", cause: cause, resumeTitle: resumeTitle)
    }

    /// Recording waited for an import or backup to finish, and then couldn't start.
    static func afterOperation(cause: RecordingStopCause, resumeTitle: String) -> RecordingNotice {
        notRestarted("Recording didn't start again after the import or backup.", cause: cause, resumeTitle: resumeTitle)
    }

    private static func notRestarted(_ lead: String, cause: RecordingStopCause, resumeTitle: String) -> RecordingNotice {
        if cause == .storage { return storageRetrying }
        let why: String
        switch cause {
        case .permission, .input, .moveApp, .restore: why = " " + Self.why(cause, lead: "It stopped")
        default: why = ""
        }
        return RecordingNotice(title: notRestartedTitle, body: lead + why + " " + how(cause, resumeTitle: resumeTitle))
    }

    private static func why(_ cause: RecordingStopCause, lead: String) -> String {
        switch cause {
        case .permission(let accessibility, let inputMonitoring):
            if accessibility && inputMonitoring { return lead + " because Accessibility and Input Monitoring are off for DayDream." }
            if accessibility { return lead + " because Accessibility is off for DayDream." }
            if inputMonitoring { return lead + " because Input Monitoring is off for DayDream." }
            return lead + " because a macOS permission is off for DayDream."
        // The menu bar's own words for it ("Paused · can't see keys or clicks"), never "input" or "tap".
        case .input: return lead + " because DayDream can't see your keys or clicks."
        case .moveApp: return lead + " because DayDream is running from the download window."
        case .restore: return lead + " because a restore is waiting for review."
        case .person, .suspension, .storage, .other: return lead + " on its own."
        }
    }

    /// What to do, naming what the menu bar panel shows then (MenuBarMenu): the missing permission's own button while a
    /// permission is off (perm-1004: "Turn on Accessibility", Accessibility first; Allow… when which is unknown), Resume
    /// Now while paused, and otherwise whatever the panel offers in the switch's place (the switch, or the one button
    /// that fixes what stands).
    private static func how(_ cause: RecordingStopCause, resumeTitle: String) -> String {
        switch cause {
        case .permission(let accessibility, let inputMonitoring):
            let button = accessibility ? "Turn on Accessibility" : inputMonitoring ? "Turn on Input Monitoring" : "Allow…"
            return "Choose \(button) from DayDream in the menu bar."
        case .moveApp: return "Move DayDream to Applications first, then open it from there."
        case .restore: return "Choose Review… from DayDream in the menu bar."
        default:
            return resumeTitle == "Resume Recording" ? "Choose Resume Now from DayDream in the menu bar."
                : "Turn DayDream on in the menu bar."
        }
    }
}
