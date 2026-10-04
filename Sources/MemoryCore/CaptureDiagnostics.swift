import Foundation

/// fix/chrome-capture: opt-in capture diagnostics. Off unless the person (or a
/// tester on their own Mac) turns it on:
///
///     defaults write com.getnorthlight.daydream CaptureDiagnostics -bool true
///
/// While on, the app counts where keys and clicks went on the way from the
/// event tap to the store (the tap, the key's lag, which app it was sent to,
/// the typing policy, the input source and secure input, each Chrome join's
/// answer and how long it took, what ended each piece of typing, and what the
/// write and the store said), and every few seconds, when a count changed,
/// writes one line to the unified log (subsystem com.getnorthlight.daydream,
/// category capture-diagnostics):
///
///     /usr/bin/log show --last 10m --predicate 'subsystem == "com.getnorthlight.daydream" AND category == "capture-diagnostics"'
///
/// A line holds only this run's random id, a sequence number, the capture
/// binding's generation, short fingerprints of the policy revision and the
/// capture epoch, and the names of the events seen since the last line. Every
/// name is a string literal in DayDream's own code (`StaticString`) and one of
/// `allowed`: no key, key code, character, word, field value or length,
/// clipboard, title, address, query, site or window content can become a name.
///
/// Privacy review B5 (2026-09-30): a line never says how many times anything
/// happened (a count of keys would give a card number's or a code's length),
/// only that it happened in those few seconds; and no name tells a privacy
/// refusal apart: an Incognito or Guest window, a password, card or code field,
/// secure input, a blocked site or a secret pattern are never named (only the
/// undifferentiated `join.full.denied`). `allowed` is pinned by the checks.
/// Review of the (i) set, B5-1: no denial names its reason, not even a harmless
/// one (a named harmless reason would make the unnamed ones private by
/// elimination), and a denied join leaves no timing bucket and none of the
/// names the join noted along the way (`hold`): every denied join, whatever
/// its reason, leaves the same line. B5-2: what ended a piece is named only
/// with a saved row, so a withheld secret leaves the same line as a piece that
/// saved nothing.
/// Nothing is written to disk by DayDream, kept past the process, or sent
/// anywhere; the unified log keeps what it is given.
public final class CaptureDiagnostics: @unchecked Sendable {
    public static let shared = CaptureDiagnostics()
    /// The app's own defaults key (Boolean).
    public static let defaultsKey = "CaptureDiagnostics"
    /// At most one line per this many seconds.
    public static let flushInterval: TimeInterval = 5
    /// Names are literals in the code, so this bound is never reached; it keeps the table small whatever happens.
    public static let maxNames = 256

    private let lock = NSLock()
    private var on = false
    private var seen: Set<String> = []
    /// Names a join noted on its way (its title shape, its form scan): kept only if the join allows (`settleHeld`).
    private var held: Set<String> = []
    private var lastFlush: Date?
    private var sequence = 0
    /// This process's run: random, never derived from the Mac, the person or the store.
    public let run: String

    public init(run: String = String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))) {
        self.run = run
    }

    public var enabled: Bool { lock.lock(); defer { lock.unlock() }; return on }
    /// Turning it off forgets every count.
    public func setEnabled(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        if !value { seen = []; held = [] }
        on = value
    }

    /// An event of a kind named in code happened (only `allowed` names are kept; never how many times).
    public func count(_ name: StaticString, _ n: Int = 1) {
        guard n > 0 else { return }
        note(name.description)
    }
    private func note(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        guard on, Self.allowed.contains(key), seen.count < Self.maxNames else { return }
        seen.insert(key)
    }

    /// One event named by a code prefix and a case of a fixed enum of DayDream's own (a join denial, a drop reason):
    /// the case's raw value is a literal in code too. Anything but letters and digits is never a name.
    public func count<E: CaseIterable & RawRepresentable>(_ prefix: StaticString, _ value: E) where E.RawValue == String {
        guard enabled else { return }
        let raw = value.rawValue
        guard !raw.isEmpty, raw.count <= 32, raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return }
        note(prefix.description + "." + raw)
    }
    /// Like `count(_:_:)`, for a join on its way: the name reaches a line only if that join allows typing
    /// (`settleHeld(allowed: true)`); a denied join's names are forgotten, so they can't tell its reason (B5-1).
    public func hold<E: CaseIterable & RawRepresentable>(_ prefix: StaticString, _ value: E) where E.RawValue == String {
        guard enabled else { return }
        let raw = value.rawValue
        guard !raw.isEmpty, raw.count <= 32, raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return }
        let key = prefix.description + "." + raw
        lock.lock(); defer { lock.unlock() }
        guard on, Self.allowed.contains(key), held.count < Self.maxNames else { return }
        held.insert(key)
    }
    /// The join that held names is over: keep them only if it allowed typing. Always empties what was held.
    public func settleHeld(allowed: Bool) {
        lock.lock(); defer { lock.unlock() }
        if allowed, on { for key in held where seen.count < Self.maxNames { seen.insert(key) } }
        held = []
    }
    /// A key's lag from its event time to its processing (the tap's backlog), bucketed.
    public func keyLag(eventAt: UInt64, now: UInt64) {
        guard enabled else { return }
        if eventAt > now { count("key.lag.future"); return }
        switch now - eventAt {
        case ...30_000_000: count("key.lag.le30ms")
        case ...150_000_000: count("key.lag.le150ms")
        case ...1_000_000_000: count("key.lag.le1s")
        default: count("key.lag.gt1s")
        }
    }
    /// How long a Chrome join or check took, bucketed.
    public func joinTime(_ prefix: JoinKind, from began: UInt64, to ended: UInt64) {
        guard enabled else { return }
        let took = ended >= began ? ended - began : 0
        switch (prefix, took) {
        case (.full, ...30_000_000): count("join.full.ms.le30")
        case (.full, ...150_000_000): count("join.full.ms.le150")
        case (.full, _): count("join.full.ms.gt150")
        case (.click, ...30_000_000): count("join.click.ms.le30")
        case (.click, ...150_000_000): count("join.click.ms.le150")
        case (.click, _): count("join.click.ms.gt150")
        case (.light, ...30_000_000): count("join.light.ms.le30")
        case (.light, _): count("join.light.ms.gt30")
        case (.submit, ...60_000_000): count("post.check.ms.le60")
        case (.submit, _): count("post.check.ms.gt60")
        }
    }
    public enum JoinKind: Sendable { case full, click, light, submit }

    /// The correlation fields of a line: never a revision or epoch itself, only a short fingerprint of each.
    public struct Context: Equatable, Sendable {
        public var generation: UInt64
        public var policy: String
        public var epoch: String
        public init(generation: UInt64, policyRevision: String, captureEpoch: String) {
            self.generation = generation
            policy = policyRevision.isEmpty ? "none" : String(fingerprint("diag|" + policyRevision).prefix(8))
            epoch = captureEpoch.isEmpty ? "none" : String(fingerprint("diag|" + captureEpoch).prefix(8))
        }
    }
    /// Counts macOS keeps for the whole login session (`CGEventSource.counterForEventType`), as deltas since the last
    /// line: key downs the hardware produced and key downs posted in the session. With `tap.key` they tell a tap that
    /// hears nothing from keys that never reached the session.
    public struct System: Equatable, Sendable {
        public var hidKeys: Int, sessionKeys: Int
        public init(hidKeys: Int, sessionKeys: Int) { self.hidKeys = hidKeys; self.sessionKeys = sessionKeys }
    }

    /// The next line, when diagnostics are on, `flushInterval` has passed and something was seen; it starts over.
    public func flush(now: Date = Date(), context: () -> Context?, system: () -> System?) -> String? {
        lock.lock()
        guard on, lastFlush.map({ now.timeIntervalSince($0) >= Self.flushInterval || now < $0 }) ?? true else { lock.unlock(); return nil }
        lock.unlock()
        let sys = system()
        lock.lock(); defer { lock.unlock() }
        if let sys {
            if sys.hidKeys > 0 { seen.insert("sys.hid.keys") }
            if sys.sessionKeys > 0 { seen.insert("sys.session.keys") }
        }
        guard !seen.isEmpty else { return nil }
        lastFlush = now
        sequence += 1
        let c = context()
        var line = "capture-diagnostics run=\(run) seq=\(sequence)"
        if let c { line += " gen=\(c.generation) policy=\(c.policy) epoch=\(c.epoch)" } else { line += " gen=none policy=none epoch=none" }
        for key in seen.sorted() { line += " " + key }
        seen = []
        return line
    }
    /// For checks: the names held by a join that hasn't settled.
    public func heldSnapshot() -> Set<String> { lock.lock(); defer { lock.unlock() }; return held }
    /// For checks: the names not yet flushed (each 1: seen).
    public func snapshot() -> [String: Int] { lock.lock(); defer { lock.unlock() }; return Dictionary(uniqueKeysWithValues: seen.map { ($0, 1) }) }

    /// Every name a line may hold. Pinned by the checks: none tells a privacy refusal apart (B5).
    public static let allowed: Set<String> = {
        var a: Set<String> = [
            "tap.key", "tap.mouse", "tap.disabled.timeout", "tap.disabled.userInput", "sys.hid.keys", "sys.session.keys",
            "key.lag.future", "key.lag.le30ms", "key.lag.le150ms", "key.lag.le1s", "key.lag.gt1s", "key.late.refused",
            "key.target.chrome", "key.target.other", "key.target.missedChrome", "key.target.notFrontmost",
            "web.key", "web.inputMethod", "web.chromeRelaunched", "web.policyChanged", "web.siteChoicesChanged",
            "web.off.notRecording", "web.off.typingOff", "web.off.chromeExcluded", "web.off.policyUnread", "web.off.noConsent",
            "web.off.paused", "web.off.vaultOrSwitch", "web.off.typedTextOff", "web.off.settingsUnread",
            "join.full.allowed", "join.full.denied", "join.click.allowed", "join.click.denied",
            "join.full.ms.le30", "join.full.ms.le150", "join.full.ms.gt150", "join.click.ms.le30", "join.click.ms.le150",
            "join.click.ms.gt150", "join.light.ms.le30", "join.light.ms.gt30", "post.check.ms.le60", "post.check.ms.gt60",
            "join.title.exact", "join.title.suffix", "join.title.profile", "join.title.none",
            "burst.sealed", "burst.ignored", "burst.dropped.quiet", "burst.dropped.late", "burst.dropped.stale",
            "burst.dropped.otherBurst", "burst.dropped.lightStart",
            // B5-2: what happens to an unfinished piece is named only with its saved row (`seal.reason.*`): a secret ends
            // the piece, so a name that needs one (a click or idle save, a drop, a settle) would tell it apart.
            "commit.saved",
            "seal.clickSinceKey", "seal.escape",
            "write.saved", "write.noRow", "write.invalidRow", "write.storeRefused", "write.storeThrew", "write.threw",
            "post.pressed", "post.marked", "post.denied", "post.chord.marked", "post.cancel.key", "post.release.notClick", "post.release.policyChanged",
            "post.skip.noControls", "post.skip.notPlainClick", "post.storeRefused", "post.storeThrew",
        ]
        // B5-1: no join or Post denial names its reason (only `join.full.denied`, `join.click.denied`, `post.denied`).
        // What ended a piece (never `sensitive`: a secret pattern).
        for reason in ["idle", "size", "submit", "cursor", "paste", "pointer", "focusKey", "shortcut", "focus", "window", "app",
                       "inputSource", "gap", "suspend", "submitChord", "mailSend"] {
            a.insert("seal.leave." + reason); a.insert("seal.reason." + reason)
        }
        return a
    }()
}
