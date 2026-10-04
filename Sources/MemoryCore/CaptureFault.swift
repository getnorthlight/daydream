import Foundation

/// What a failed capture write means for recording (Foundation only; the app's Coordinator acts on it).
///
/// One failed write used to stop recording until the person quit and reopened DayDream. Most failures are momentary
/// (another connection held the database, a heartbeat that ran late, a policy saved mid-commit): the unit that hit
/// one is dropped, never kept to write later, and recording goes on. A write that fails for a reason that won't pass
/// in a moment pauses recording, and the app starts it again by itself.
public enum CaptureFault: Equatable, Sendable {
    /// Only the unit that hit it is lost: the store refused it or couldn't take it now. Recording goes on.
    case dropUnit
    /// Typing's key can't be read now: that unit is dropped and typing waits for the key (TypingModel retries it);
    /// app history goes on, and this never pauses recording.
    case typingLocked
    /// Not a failed save: this unit wasn't allowed (a check that said no as it was written, typing not accepted yet, a
    /// store that isn't there to write to). The unit is dropped and recording goes on. Nothing is retried and nothing
    /// says "couldn't save": saving again wouldn't change the answer, and a real permission loss is the permission
    /// check's to say.
    case refused
    /// A write failed for a reason that won't pass in a moment (disk full, I/O, read-only, corrupt): recording pauses
    /// and the app tries again.
    case storage
    /// Anything else. Handled like `storage`, named apart in the log.
    case other

    /// True when recording goes on and only the unit is lost.
    public var dropsUnitOnly: Bool { self == .dropUnit || self == .typingLocked || self == .refused }

    /// Session reasons the app writes while it tries again (MemoryUI's RecordingCopy maps each to its line, and
    /// MacMemApp's RecordingStopCause.storageReasons lists them: both compile without this module, so they repeat the
    /// words, and scripts/recording-model-checks.swift pins them equal).
    public static let retryReason = "Storage write failed. Retrying automatically."
    /// It has kept failing for a while (`StorageRetry.persistentAfter`): tried once a minute.
    public static let persistentReason = "Storage keeps failing. Retrying every minute."
    /// The disk is full (SQLITE_FULL).
    public static let fullReason = "Storage full. Retrying automatically."

    /// Store refusals that mean "not this unit, not now". Each is thrown before anything is written.
    static let refusals: Set<String> = [
        "Capture is not recording",
        "Capture policy changed before commit",
        "Recording session changed before commit",
    ]

    /// - `sessionRecording`: the in-memory session still says recording. A heartbeat refusal ("Capture is not
    ///   recording") then means the heartbeat ran late, not that recording stopped.
    public static func classify(_ error: Error, sessionRecording: Bool) -> CaptureFault {
        if let typed = error as? TypedTextError {
            switch typed {
            case .typingLocked: return .typingLocked
            case .notAccepted: return .refused
            case .cannotSetUp, .openFailed: return .other
            }
        }
        guard let mem = error as? MemError else { return .other }
        switch mem {
        case .busy: return .dropUnit
        case .invalid(let text): return refusals.contains(text) ? .dropUnit : .other
        // A momentary code the store didn't name busy itself (see MemoryStore.momentary).
        case .database: return busy(mem) ? .dropUnit : .storage
        case .denied, .missing: return .refused
        }
    }

    /// The store refused a unit because the heartbeat is older than its freshness window while the session still
    /// records: the app writes a heartbeat now, so the next unit isn't refused too.
    public static func staleHeartbeat(_ error: Error, sessionRecording: Bool) -> Bool {
        guard sessionRecording, let mem = error as? MemError, case .invalid(let text) = mem else { return false }
        return text == "Capture is not recording"
    }

    /// The store couldn't take the write now (another connection held the database past the busy timeout, or its lock
    /// couldn't be taken): nothing was written, and the same write can succeed a moment later.
    public static func busy(_ error: Error) -> Bool {
        guard let mem = error as? MemError else { return false }
        if case .busy = mem { return true }
        if case .database = mem, let code = mem.sqliteCode { return MemoryStore.momentary(code) }
        return false
    }

    /// The disk is full (SQLITE_FULL): the line says so, since only freeing space fixes it.
    public static func diskFull(_ error: Error) -> Bool {
        guard let code = (error as? MemError)?.sqliteCode else { return false }
        return code & 0xff == 13
    }

    /// A short, content-free name for the log: the kind and the SQLite code, never SQL, values, titles or text.
    public static func logName(_ error: Error) -> String {
        switch error {
        case let mem as MemError:
            switch mem {
            case .busy: return "busy" + (mem.sqliteCode.map { " (code \($0))" } ?? "")
            case .database: return "database" + (mem.sqliteCode.map { " (code \($0))" } ?? "")
            case .invalid(let text): return refusals.contains(text) ? "refused: " + text : "invalid"
            case .denied: return "not allowed"
            case .missing: return "no store"
            }
        case let typed as TypedTextError:
            if case .typingLocked(let state) = typed { return "typing locked (\(state.rawValue))" }
            if case .notAccepted = typed { return "typing not accepted" }
            return "typed text"
        default:
            return String(describing: type(of: error))
        }
    }
}

/// Counts faults that only dropped a unit. Many in a short time mean something is wrong that dropping won't fix, so
/// recording pauses (and the app tries again) once.
public struct CaptureFaultBudget: Equatable, Sendable {
    public static let limit = 5
    public static let window: TimeInterval = 60
    private(set) var recent: [Date] = []
    public init() {}
    /// Notes one dropped unit. True once `limit` of them fell within `window`; the count then starts again.
    public mutating func dropped(at now: Date) -> Bool {
        recent = recent.filter { now.timeIntervalSince($0) < Self.window && $0 <= now } + [now]
        guard recent.count >= Self.limit else { return false }
        recent.removeAll()
        return true
    }
    public mutating func reset() { recent.removeAll() }
    public var count: Int { recent.count }
}

/// The recording permissions (Accessibility and Input Monitoring) as recording's lifecycle reads them. macOS can answer
/// "not allowed" for a single read while its privacy service is slow or restarting (right after wake, say), and one
/// such read, out of about twenty a second, used to stop recording for good. A loss counts only once the reads have
/// said so for `window`, across at least `reads` reads; any read that says allowed ends it. Before anything was
/// allowed, a read that says not allowed is the answer at once. Intake never waits for this: a unit read while a
/// permission reads off is dropped at once (Coordinator.isRunning is a fresh read).
public struct SettledPermission: Equatable, Sendable {
    public static let window: TimeInterval = 1
    public static let reads = 3
    public private(set) var allowed = false
    private var firstDenied: Date?
    private var denials = 0
    public init() {}
    /// Notes one read and returns the settled answer.
    public mutating func read(_ permitted: Bool, at now: Date) -> Bool {
        if permitted { allowed = true; firstDenied = nil; denials = 0; return true }
        guard allowed else { return false }
        if let first = firstDenied, first <= now { denials += 1 } else { firstDenied = now; denials = 1 }
        if denials >= Self.reads, let first = firstDenied, now.timeIntervalSince(first) >= Self.window {
            allowed = false; firstDenied = nil; denials = 0
        }
        return allowed
    }
}
