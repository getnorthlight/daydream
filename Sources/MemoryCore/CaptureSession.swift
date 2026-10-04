import Foundation
import HistoryCore

/// Testable policy/state boundary with a single locked intake.
/// No OS permission request, timer, event tap or network here.
public final class CaptureSession {
    /// Browsers skipped by capture: the same shared `KnownBrowsers` list that
    /// `ObservationPolicy` uses (Tor, DuckDuckGo, LibreWolf and Dia included, and
    /// every Brave, Vivaldi and Opera edition, such as Brave Beta and Opera GX).
    public static let excludedBrowsers: BrowserBundleList = KnownBrowsers.list
    private let lock = NSRecursiveLock()
    private let store: MemoryStore
    private let persist: (Evidence, Date) throws -> Bool
    /// The status while recording. It names Chrome pages only in a release that has them (`ReleaseFeatures`).
    #if DAYDREAM_OWNER_TYPING
    // Owner build: website typing in Google Chrome exists, so say so.
    public static let recordingReason = WebTypingText.recording
    #else
    public static let recordingReason = ReleaseFeatures.chromePageHistory
        ? "Recording apps. Chrome page titles and sites are saved only if you turn them on. What's on web pages and what you type in browsers is never saved."
        : "Recording apps. Web browsers are skipped: what's on web pages and what you type in browsers is never saved."
    #endif
    public private(set) var state = "off"
    public private(set) var reason = "Recording is off."
    public var onCommitted: (() -> Void)?
    /// fix/chrome-capture (opt-in diagnostics): this recording session's epoch, "" when it can't be read.
    public func captureEpoch() -> String { lock.lock(); defer { lock.unlock() }; return (try? store.captureStatus())?["epoch"] ?? "" }
    public init(store: MemoryStore, persist: ((Evidence, Date) throws -> Bool)? = nil) throws {
        self.store = store
        self.persist = persist ?? { try store.ingest($0, now: $1) }
        try store.setCaptureState(state, reason: reason)
    }
    public func start(permitted: Bool, now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        state = permitted ? "recording" : "permission_denied"
        reason = permitted ? Self.recordingReason : "Accessibility and Input Monitoring permission are required. No permission was requested."
        do { try store.setCaptureState(state, reason: reason, now: now) }
        catch { state = "error"; reason = "Storage unavailable; recording stopped."; throw error }
    }
    public func pause(_ why: String = "Paused by you", now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        state = "paused"; reason = why
        do { try store.setCaptureState(state, reason: reason, now: now) }
        catch { state="error"; reason="Pause could not be persisted. Recording stopped; check storage before resuming."; throw error }
    }
    public func stop(now:Date=Date()) throws {
        lock.lock(); defer { lock.unlock() }
        state="off"; reason="Stopped by you. Resume explicitly."
        try store.setCaptureState(state,reason:reason,now:now)
    }
    /// Serialized with this session's start/record/health. Failure leaves the
    /// in-memory intake stopped even if disk cannot persist the pause.
    public func savePreferences(_ preferences: MemoryPreferences, expectedRevision: String, now: Date = Date()) throws -> PreferenceSaveResult {
        lock.lock(); defer { lock.unlock() }
        do {
            let current = try store.policy()
            if current.captureText == preferences.nativeTyping,
               (current.captureText && current.typedConsentVersion == 1) == preferences.nativeTyping,
               Set(current.blockedApps) == Set(preferences.blockedApps),
               preferences.blockedDomains.map({ Set($0) == Set(current.blockedDomains) }) ?? true,
               preferences.browserPages.map({ $0 == current.browserPages && $0 == current.browserPagesOn }) ?? true {
                return try store.savePreferences(preferences, expectedRevision: expectedRevision)
            }
            try pause("Paused for preference save; resume explicitly.", now: now)
            return try store.savePreferences(preferences, expectedRevision: expectedRevision)
        } catch let error as PreferenceSaveError {
            if error == .storageUnavailable { state = "error"; reason = "Preference save failed. Recording stopped; resume explicitly." }
            throw error
        } catch {
            state = "error"; reason = "Preference save failed. Recording stopped; resume explicitly."
            throw PreferenceSaveError.storageUnavailable
        }
    }
    /// The heartbeat. `now` defaults to the time the lock was taken, not the time of the call: a heartbeat that waited
    /// for a commit holding the lock must not write a `checked_at` that is already stale.
    public func health(permitted: Bool, now given: Date? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        let now = given ?? Date()
        if state == "recording", !permitted {
            state = "permission_denied"; reason = "Permission was revoked. Resume explicitly after granting it."
        }
        try store.setCaptureState(state, reason: reason, now: now)
    }
    public static func accepts(_ evidence: Evidence, focusedFieldKnown: Bool, settings: PrivacySettings, now: Date = Date()) -> Bool {
        // AX has no universal affirmative "not private" signal. Never persist
        // browser activity based merely on absence of an Incognito title.
        focusedFieldKnown && !evidence.bundle.isEmpty &&
        (!excludedBrowsers.contains(evidence.bundle) || BrowserSafety.fresh(evidence,now:now)) &&
        // A browser DayDream doesn't know by name (it opens web links) is skipped like a known one.
        !BrowserLookalike.isUnknownBrowser(evidence.bundle) &&
        // Chrome page rows and Chrome app time are written only while "Web pages in Chrome" is on.
        // Read time never checks the switch: saved pages stay until deleted or hidden.
        (![BrowserSafety.pageProvider,BrowserSafety.appTimeProvider].contains(evidence.browserVerification?.provider ?? "") || settings.browserPagesOn) &&
        !ObservationPolicy.titleLooksPrivate(evidence.title) &&
        Privacy.sanitized(evidence, settings: settings, now: now) != nil
    }
    @discardableResult public func record(_ evidence: Evidence, focusedFieldKnown: Bool, permitted: Bool, now: Date = Date()) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state == "recording" else { return false }
        if !permitted { try health(permitted: false, now: now); return false }
        guard Self.accepts(evidence, focusedFieldKnown: focusedFieldKnown, settings: try store.policy(), now: now) else { return false }
        do {
            let saved = try persist(evidence, now)
            if saved { onCommitted?() }
            return saved
        } catch {
            // A row the store refused or couldn't take now (another connection held the file, say) is dropped, never
            // kept to write later, and recording goes on. Any other failed write stops intake at once. It is a pause,
            // not an error latch: the app tries again by starting recording again, which rewrites this state.
            if !CaptureFault.classify(error, sessionRecording: true).dropsUnitOnly {
                state = "paused"; reason = CaptureFault.retryReason
                try? store.setCaptureState(state, reason: reason, now: now)
            }
            throw error
        }
    }
}

/// A focus change or unsafe input discards the entire pending burst. Callers
/// check safety BEFORE obtaining characters from a native event.
public struct CaptureBurst {
    public private(set) var context: String?
    private var text = ""
    public init() {}
    public mutating func discard() { context = nil; text = "" }
    public mutating func append(_ characters: String, context next: String?, safe: Bool) {
        guard safe, let next else { discard(); return }
        if context != next { discard() }
        context = next
        text = String((text + characters).prefix(2000))
    }
    public mutating func drain(context current: String?, safe: Bool) -> String? {
        defer { discard() }
        guard safe, current != nil, current == context, !text.isEmpty else { return nil }
        return text
    }
}

extension MemoryStore {
    public func setCaptureState(_ state: String, reason: String, now: Date = Date()) throws {
        try transaction(preservingTypedNarrative: true) {
            let previous = try rows("SELECT body FROM metadata WHERE id='capture'").first?.first
            let previousFields = try previous.map { try decode([String:String].self,$0) }
            let previousState = previousFields?["state"]
            let checked = timestamp(previousFields?["checked_at"] ?? "")
            if state != "recording" || previousState != state || checked.map({ now.timeIntervalSince($0) < 0 || now.timeIntervalSince($0) > 5 }) ?? true {
                discardTypedNarrativeCarry()
            }
            let epoch = previousState == state ? (previousFields?["epoch"] ?? UUID().uuidString) : UUID().uuidString
            try exec("INSERT OR REPLACE INTO metadata VALUES('capture',?)", [json(["state":state,"reason":reason,"checked_at":iso(now),"epoch":epoch])])
            if previousState != state { try invalidateDisclosure() }
        }
    }
    public func captureStatus(now: Date = Date()) throws -> [String:String] {
        guard let body = try rows("SELECT body FROM metadata WHERE id='capture'").first?.first else {
            return ["state":"off", "reason":"Capture has not been started."]
        }
        var status = try decode([String:String].self, body)
        if status["state"] == "recording", timestamp(status["checked_at"] ?? "").map({ now.timeIntervalSince($0) > 5 || $0 > now.addingTimeInterval(1) }) ?? true {
            status["state"] = "unavailable"
            status["reason"] = "Recorder heartbeat expired. This is not live context."
        }
        return status
    }
}

#if DAYDREAM_OWNER_TYPING
/// Owner build only: website typing (typing-all SPEC-LATER 4.2) reads its
/// choices and writes its rows through the recording session's store, under
/// the session lock, only while recording.
extension CaptureSession {
    /// The saved settings and typing choices the website rules are built from.
    public func webTypingPolicy() throws -> (settings: PrivacySettings, typed: TypedTextPolicy) {
        lock.lock(); defer { lock.unlock() }
        return (try store.policy(), try store.typedTextPolicy())
    }
    /// One website typing row. Only a valid join row, only while recording,
    /// bound to the policy revision it was decided under. The store then runs
    /// its own checks (typing pause, site rules, scrubber, sealing).
    @discardableResult public func recordWebTyping(_ e: Evidence, expectedPolicyRevision: String, now: Date = Date()) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state == "recording", WebTypedRow.valid(e) else { return false }
        let wrote = try store.ingest(e, now: now, expectedPolicyRevision: expectedPolicyRevision, requireRecording: true)
        if wrote { onCommitted?() }
        return wrote
    }
    /// fix/chrome-capture: marks rows a proven Post click ended, only while recording (`MemoryStore.markWebTypingSubmitted`).
    @discardableResult public func recordWebSubmitGesture(ids: [String], documentID: String, focusID: String, control: String,
                                                          expectedPolicyRevision: String, chord: Bool = false, now: Date = Date()) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard state == "recording" else { return [] }
        let marked = try store.markWebTypingSubmitted(ids: ids, documentID: documentID, focusID: focusID, control: control,
                                                      expectedPolicyRevision: expectedPolicyRevision, chord: chord, now: now)
        if !marked.isEmpty { onCommitted?() }
        return marked
    }
}
#endif
