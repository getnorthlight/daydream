import Foundation

/// fix/chrome-root (2026-10-02): an always-on tally of what website typing (owner build) did with Chrome keys, so a
/// live test can see why nothing was saved without turning on `CaptureDiagnostics`. The live test of build
/// 20261002150428 saved no Chrome typing and could not say why: the only record of a refusal was opt-in.
///
/// Read with `mac-mem --local web-typing-refusals` (the app's own defaults, `defaultsKey`).
///
/// What it can hold (privacy):
/// - only names from `names`, literals in DayDream's code: never a key, character, word, length, title, address,
///   site, window or field;
/// - EPISODES, not keys: each kind of outcome (`stream`: the checks before a read, the join's answer, Apple Event
///   failures, the burst's drops, keys lost at intake) is counted only when it differs from that kind's previous
///   outcome (`note`), so a run of keys refused for the same reason counts once, and no count can tell how long a
///   field's text, a code or a password was (review B5: a count of keys would give a card number's length). A count
///   is how many times that outcome began, a lower bound. Saved rows are counted one by one (`saved`): a row is
///   already in the store;
/// - privacy refusals are one name, `join.privacy` (an Incognito or Guest window, a sensitive field, a blocked site
///   or one whose switch is off): it never says which (review B5-1);
/// - nothing is sent anywhere or logged; the counts stay in the app's defaults on this Mac until `reset`.
public final class WebTypingRefusals: @unchecked Sendable {
    public static let shared = WebTypingRefusals()
    /// The app's defaults key: a dictionary of name -> count, plus `sinceKey` (when counting started).
    public static let defaultsKey = "DaydreamWebTypingOutcomes"
    public static let sinceKey = "since"

    /// Every name the tally can hold. Anything else is ignored.
    public static let names: Set<String> = [
        // Before any read: what the route's own checks said (`WebTypingRoute.active`).
        "off.notRecording", "off.typingOff", "off.chromePagesOff", "off.typedTextOff", "off.policyUnread", "inputMethod",
        // The full join's answer (`BrowserTypingDenial`, privacy reasons as one name).
        "join.allowed", "join.privacy", "join.disabled", "join.untrustedTarget", "join.noPermission", "join.notFocused",
        "join.windowList", "join.window", "join.unlistedWindow", "join.ambiguousWindow", "join.field", "join.frame",
        "join.url", "join.changed", "join.timeout",
        // An Apple Event to Chrome that timed out or failed during a join (the join then refused).
        "appleEvent.failed",
        // The burst rules after an allowed join (`BrowserTypingDrop`): a key late, stale, in a quiet period, held...
        // Never `gate` or `latch` (a refusal of what was typed: review B5-3), never a drop after a denied join (B5-1).
        "drop.late", "drop.stale", "drop.quiet", "drop.held", "drop.otherBurst", "drop.lightStart",
        // A key lost before website typing saw it: processed too late after it was typed (`TypingKeyGap`).
        "key.lateAtIntake",
        // Writes.
        "saved", "store.refused",
        // claude/typing-1004: which step of a full join refused `window` or `frame`, or let the window through on its
        // bounds alone (`step`). Window geometry and title shape only: never a title, a size, a site or a privacy fact.
        "step.window.focused", "step.window.bounds", "step.window.noBounds", "step.window.name", "step.window.axTitle",
        "step.window.title", "step.window.titleUnmatched", "step.frame.chain", "step.frame.chromeUI", "step.frame.nested",
        // claude/typing-1004: keys the Mac saw while recording never reached DayDream's input tap (`KeyArrivalWatch`).
        "tap.noKeys",
        // claude/xtyping-1005: a full join found Chrome's accessibility asleep and woke it (`BrowserTypingJoin.read`),
        // and how many times website typing woke it when Chrome came to the front (`BrowserTypingJoin.wake`).
        "step.focus.asleep", "wake.chrome",
        // claude/xtyping-1005: typing sessions in Chrome (keys after `burstGapNanoseconds` without one), counted one by
        // one. Each one starts every stream's episode again, so an outcome that repeats the last session's (a refusal
        // that never changes) is counted again: before, a laptop test that failed exactly as the one before moved no
        // counter at all. A count of sessions, never of keys.
        "burst",
    ]
    /// The `step` names a join may note (without the "step." prefix).
    public static let stepNames: Set<String> = Set(names.filter { $0.hasPrefix("step.") }.map { String($0.dropFirst(5)) })
    /// Join refusals that are privacy facts: never named apart (review B5-1).
    public static let privacyDenials: Set<String> = ["notNormal", "sensitiveField", "blockedSite"]

    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    /// The last outcome of each stream (`stream`).
    private var last: [String: String] = [:]
    private var pendingTransport = false
    /// The step a full join noted on its way (`step`), counted with its answer.
    private var pendingStep: String?
    private var since: Date?
    private var dirty = false
    /// Where `flush` writes the counts (the app: its own defaults, from capture's heartbeat; checks: their own).
    public var persist: (([String: Int], Date) -> Void)?
    public init() {}

    /// One outcome of the episode stream (keys, joins, drops). Counted only when it differs from the previous one.
    public func note(_ name: StaticString) { record(name.description, episode: true) }
    /// A full join's answer. A failed Apple Event noted during it (`transportFailed`) is counted once with it.
    public func join(denial: String?) {
        lock.lock(); let transport = pendingTransport; pendingTransport = false; let step = pendingStep; pendingStep = nil; lock.unlock()
        // Its own stream: a join with no failed event ends the episode, so the next failure counts again.
        record(transport ? "appleEvent.failed" : "appleEvent.ok", episode: true)
        defer {
            // The step's own stream: a join that noted none ends its episode, so the next one counts again.
            if let step { record("step." + step, episode: true) } else { lock.lock(); last["step"] = nil; lock.unlock() }
        }
        guard let denial else { record("join.allowed", episode: true); return }
        record(Self.privacyDenials.contains(denial) ? "join.privacy" : "join." + denial, episode: true)
    }
    /// claude/typing-1004: the step of the full join under way that refused `window` or `frame` (or admitted a window on
    /// its bounds alone), counted with that join's answer (`join`). Only names from `stepNames`.
    public func step(_ name: StaticString) {
        let n = name.description
        guard Self.stepNames.contains(n) else { return }
        lock.lock(); pendingStep = n; lock.unlock()
    }
    /// An Apple Event of a join got no answer in time (or an error). Counted with the join's answer.
    public func transportFailed() { lock.lock(); pendingTransport = true; lock.unlock() }
    /// A row was written: counted one by one.
    public func saved() { record("saved", episode: false) }
    /// claude/xtyping-1005: website typing woke Chrome's accessibility when Chrome came to the front. Counted one by one.
    public func woke() { record("wake.chrome", episode: false) }

    /// claude/xtyping-1005: a Chrome key reached website typing (or was lost on its way: `key.lateAtIntake`) at `at`
    /// (uptime nanoseconds). More than this after the previous one starts a new typing session: `burst` is counted and
    /// every stream's episode ends, so the session's outcomes are counted even when they repeat the last session's.
    public static let burstGapNanoseconds: UInt64 = 3_000_000_000
    private var lastKeyAt: UInt64?
    public func keyArrived(at: UInt64) {
        lock.lock()
        let fresh = lastKeyAt.map { at < $0 || at - $0 > Self.burstGapNanoseconds } ?? true
        lastKeyAt = at
        if fresh { last = [:] }
        lock.unlock()
        if fresh { record("burst", episode: false) }
    }

    /// The stream a name belongs to: its prefix ("join", "drop", "off", "appleEvent", "key"); `inputMethod` is a check
    /// before any read, as "off" is.
    public static func stream(_ name: String) -> String {
        name == "inputMethod" ? "off" : String(name.split(separator: ".", maxSplits: 1).first ?? "")
    }
    private func record(_ name: String, episode: Bool) {
        guard Self.names.contains(name) || name == "appleEvent.ok" else { return }
        lock.lock()
        if episode {
            let stream = Self.stream(name)
            guard last[stream] != name else { lock.unlock(); return }
            last[stream] = name
        }
        // "appleEvent.ok" only ends a failure episode; it is never counted.
        guard Self.names.contains(name) else { lock.unlock(); return }
        counts[name, default: 0] += 1
        if since == nil { since = Date() }
        dirty = true
        lock.unlock()
    }

    public func snapshot() -> [String: Int] { lock.lock(); defer { lock.unlock() }; return counts }
    /// Writes the counts if they changed.
    public func flush() {
        lock.lock()
        guard dirty, let since else { lock.unlock(); return }
        dirty = false
        let copy = counts
        lock.unlock()
        persist?(copy, since)
    }
    public func reset() { lock.lock(); counts = [:]; last = [:]; pendingTransport = false; pendingStep = nil; since = nil; dirty = false; lastKeyAt = nil; lock.unlock() }

    // MARK: Storage (the app's own defaults)

    /// The dictionary saved in the defaults: the counts and when counting started.
    public static func encoded(_ counts: [String: Int], since: Date) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in counts where names.contains(k) { out[k] = v }
        out[sinceKey] = ISO8601DateFormatter().string(from: since)
        return out
    }
    /// Reads what `encoded` saved, keeping only known names and whole counts.
    public static func decoded(_ value: Any?) -> (counts: [String: Int], since: String?)? {
        guard let d = value as? [String: Any] else { return nil }
        var counts: [String: Int] = [:]
        for (k, v) in d where names.contains(k) { if let n = v as? Int, n >= 0 { counts[k] = n } }
        return (counts, d[sinceKey] as? String)
    }
    /// The CLI's read of the app's defaults domain (read-only; never writes).
    public static func read(domain: String = DaydreamIdentity.bundleID) -> (counts: [String: Int], since: String?)? {
        decoded(CFPreferencesCopyAppValue(defaultsKey as CFString, domain as CFString))
    }
    /// The app's wiring: `flush` writes the counts to its own defaults.
    public func persistToDefaults(_ defaults: UserDefaults = .standard) {
        persist = { counts, since in defaults.set(Self.encoded(counts, since: since), forKey: Self.defaultsKey) }
        // Keep counting from what an earlier run saved, so one test can span a relaunch.
        if let saved = Self.decoded(defaults.dictionary(forKey: Self.defaultsKey)) {
            lock.lock()
            for (k, v) in saved.counts { counts[k, default: 0] += v }
            since = saved.since.flatMap { ISO8601DateFormatter().date(from: $0) } ?? since
            lock.unlock()
        }
    }
}
