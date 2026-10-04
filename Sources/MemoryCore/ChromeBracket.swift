#if DAYDREAM_CHROME_TYPING
// Compiled only with -DDAYDREAM_CHROME_TYPING: every release build defines it; a plain swift build leaves this file out.
//
// QF-17 PROTOTYPE (bracketed Chrome join). Off by default (ChromeJoinDesign.synchronous); not used until it passes a privacy review.
//
// Chrome answers an Apple Event in about 12 ms (23 ms tail), so a join can't run in the key path. With
// `ChromeJoinDesign.bracketed` the join runs as single batched reads off the main thread, and a key is admitted
// only when verified reads bracket it (B1), its key-time identity matches them (B2), no boundary falls inside the
// bracket (B3), and its characters, held unproven in an owned buffer until then (B4), are handed to the typing
// session. Everything here is pure bookkeeping: no OS call, no log, no string of typed text.
import Foundation
import PrivacyPolicy

// MARK: - Switches and limits

/// Which join design website typing runs. `.synchronous` is the 4108ea4 behaviour (a double-read join per key on
/// the main thread; a key's characters are read only after it). `.bracketed` is the QF-17 prototype.
/// Review ruling (point 1, condition f): the switch defaults to the current synchronous behaviour.
public enum ChromeJoinDesign: Sendable, Equatable {
    case synchronous
    case bracketed
    private static let lock = NSLock()
    private static var value: ChromeJoinDesign = .synchronous
    /// Read once when a route or join is made (and by the join per call). Checks and the QA harness set it.
    public static var current: ChromeJoinDesign {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// Where a key must sit relative to its bracketing reads.
/// - `wholeRead` (rev 3 B1 as written): Ra.end < t < Rb.start, whole reads.
/// - `perFact` (the privacy review's B1 "required rule"; rev 3 calls the whole-read form its conservative
///   equivalent): for every fact f, an observation of f replied before t and a later one sent after t.
/// Both use the same per-fact span limit (rev 3.1) and the same equality, boundary and identity rules.
public enum ChromeBracketRule: Sendable, Equatable {
    case wholeRead
    case perFact
    private static let lock = NSLock()
    private static var value: ChromeBracketRule = .wholeRead
    public static var current: ChromeBracketRule {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// QF-17 feasibility prototype, NOT reviewed and never the default: which facts one bracketed read asks Chrome.
/// `full` (rev 3.1): IDs, modes, bounds, IDs again, name, active tab, URL: 7 Apple Events. `lean`: only `mode` and
/// `bounds` of every window (2 Apple Events); the focused window is bound to a listed window by bounds alone (exactly
/// one), and the page is the web area's AXURL alone. Measured to answer rev 3.1's "if 150 ms is infeasible, cut the
/// facts per read" (at 7 events a fact in flight at a key needs about 2 x 84 + 12 ms at 12 ms/event).
public enum ChromeReadShape: Sendable, Equatable {
    case full
    case lean
    private static let lock = NSLock()
    private static var value: ChromeReadShape = .full
    public static var current: ChromeReadShape {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

public enum ChromeBracketTiming {
    /// SPAN (M1 + the owner's rev 3.1): for every fact f of an admitted key's bracket,
    /// obs_b(f).replyReceived - obs_a(f).sendStarted <= SPAN. The earliest possible a-side observation (its send)
    /// and the latest possible b-side observation (its reply) are used, so the uncertainty is inside the limit.
    /// 150 ms, conservative. 300 ms is NOT approved. This is the only place the number lives.
    public static let spanNanoseconds: UInt64 = 150_000_000
    /// Q-4: measured AX URL/title settle floor; observation START, inclusive. Prototype flags stay off.
    public static let metadataSettleNanoseconds: UInt64 = 60_000_000
    /// B4: at most this many keys are held unproven, and none longer than `holdMaxNanoseconds` (and never past its
    /// bracket, which the span already bounds). Past either cap the whole buffer is wiped and discarded.
    public static let holdMaxKeys = 64
    public static let holdMaxNanoseconds: UInt64 = 1_000_000_000
    /// Bytes one held key may carry (a composed accent or a soft newline is at most a few UTF-8 bytes).
    public static let holdMaxBytesPerKey = 16
    /// A read that takes longer than the span can never bracket anything: it is stopped at this budget.
    public static let readBudgetNanoseconds: UInt64 = spanNanoseconds
    /// Per Apple Event timeout inside a bracketed read (the measured tail is 23 ms; 20 ms timed out, QF-17).
    public static let eventTimeoutNanoseconds: UInt64 = 60_000_000
    /// Reads run back to back for this long after the last key, click or Tab in Chrome (review point 2), counted
    /// from event times. Never without such a signal (the owner's 9/28 rejection of idle reads).
    public static let activeNanoseconds: UInt64 = 5_000_000_000
    /// B3 barrier: an OS input event this much newer than the last one main processed is still pending.
    public static let pendingInputSlackNanoseconds: UInt64 = 2_000_000
    /// B3 barrier: how long admission may wait for a pending input event to reach main before it discards.
    public static let barrierWaitNanoseconds: UInt64 = 40_000_000
    /// The read loop's pause after a refused read or one that ended almost at once (nothing was asked of Chrome):
    /// a fast-failing read never spins (found by the QA harness: a secure-input refusal looped at one instant).
    /// Each further refusal in a row doubles the pause, up to `retryMaxNanoseconds`; a verified read resets it. With
    /// secure input on for 10 s that is at most about 20 reads, and none once the activity window (5 s) ends.
    public static let retryNanoseconds: UInt64 = 20_000_000
    public static let retryMaxNanoseconds: UInt64 = 640_000_000
    public static let minimumReadNanoseconds: UInt64 = 5_000_000
}

// MARK: - Facts and read records

/// The facts one read observes (B1). Every fact is observed in every read (M7: sensitivity too).
public enum ChromeFact: Int, CaseIterable, Sendable, Comparable {
    /// Frontmost == system-focused == Chrome, no secure input (read at the start and the end of a read).
    case focusState
    /// `ID of every window` (read before and after the batched mode and bounds reads).
    case windowIDs
    /// `mode of every window`: every value exactly "normal".
    case modes
    /// Accessibility geometry: the focused window, every AX window's subrole and frame.
    case axWindows
    /// `bounds of every window`.
    case bounds
    /// The bounds-matched candidate's name (compared with the AX window title).
    case name
    /// `ID of active tab of window id W`.
    case tab
    /// `URL of tab id T of window id W` (origin, path and query; compared as a digest only).
    case url
    /// The focused element, its role, subrole and ancestry to the window (field identity and kind).
    case focus
    /// The one AXWebArea's AXURL.
    case axURL
    /// The field rules and the person's site/field choices on the labels, and (A's QF-11/QF-3) form scan.
    case sensitivity
    public static func < (a: ChromeFact, b: ChromeFact) -> Bool { a.rawValue < b.rawValue }
}

/// When a fact was observed within one read: the first request for it was sent at `sent`, the last reply for it
/// arrived at `received` (uptime nanoseconds, the same clock as a key's typed time; N3).
public struct ChromeFactTimes: Equatable, Sendable {
    public var sent: UInt64
    public var received: UInt64
    public init(sent: UInt64, received: UInt64) { self.sent = sent; self.received = received }
}

/// An Accessibility object reference (the focused window or element), compared with the join's own equality
/// (CFEqual in production). No attribute of it is read through this type.
public struct ChromeRef: @unchecked Sendable {
    public let object: AnyObject
    private let same: (AnyObject) -> Bool
    public init(_ object: AnyObject, same: @escaping (AnyObject) -> Bool) { self.object = object; self.same = same }
    public func matches(_ other: ChromeRef) -> Bool { same(other.object) }
    public func matches(object other: AnyObject) -> Bool { same(other) }
}

/// Digest of a transient fact value (a URL, a title, labels). Seeded per process (Hasher): equal within this
/// process only, never stored, never shown. The value itself is dropped by the join after hashing.
public enum ChromeFactDigest {
    public static func of(_ parts: [String]) -> UInt64 {
        var h = Hasher()
        h.combine(parts.count)
        for p in parts { h.combine(p) }
        return UInt64(bitPattern: Int64(h.finalize()))
    }
    public static func of(_ bounds: [ChromeBounds]) -> UInt64 {
        of(bounds.map { "\($0.left),\($0.top),\($0.right),\($0.bottom)" })
    }
}

/// One completed, verified read (B1): the digest of every fact, every observation of each (a fact read twice in
/// one read, like the window IDs, has two), and the AX refs it proved. No typed text, title, URL or label:
/// digests only. Equality is identity.
public final class ChromeReadRecord: @unchecked Sendable, Equatable {
    public let id = UUID()
    public let pid: Int32
    public let launch: String
    public let start: UInt64
    public let end: UInt64
    public let digest: [ChromeFact: UInt64]
    /// Every observation of each fact, in order.
    public let times: [ChromeFact: [ChromeFactTimes]]
    public let window: ChromeRef
    public let focus: ChromeRef
    /// PM4: every node of the focused element's ancestry, the one AXWebArea included, up to the window (the
    /// synchronous design's `unchanged` compared each by CFEqual; so does `sameFacts`).
    public let chain: [ChromeRef]
    /// Apple Events this read sent (diagnostics: the event rate).
    public var appleEvents = 0
    public init(pid: Int32, launch: String, start: UInt64, end: UInt64, digest: [ChromeFact: UInt64], times: [ChromeFact: [ChromeFactTimes]],
                window: ChromeRef, focus: ChromeRef, chain: [ChromeRef] = []) {
        self.pid = pid; self.launch = launch; self.start = start; self.end = end; self.digest = digest; self.times = times
        self.window = window; self.focus = focus; self.chain = chain
    }
    /// The facts this read observed (all of them for the `full` shape; `lean` has no IDs, tab or AE URL).
    public var facts: [ChromeFact] { ChromeFact.allCases.filter { digest[$0] != nil } }
    /// The facts every read must observe, whatever its shape.
    public static let required: [ChromeFact] = [.focusState, .modes, .axWindows, .bounds, .name, .focus, .axURL, .sensitivity]
    /// Every fact observed at least once, with sane times inside the read.
    public var complete: Bool {
        Self.required.allSatisfy { digest[$0] != nil } && facts.allSatisfy { f in
            guard digest[f] != nil, let obs = times[f], !obs.isEmpty else { return false }
            return obs.allSatisfy { $0.sent >= start && $0.received >= $0.sent && $0.received <= end }
        }
    }
    /// Every fact equal (B1), the same Chrome launch, and the same window and field objects (B2).
    public func sameFacts(as o: ChromeReadRecord) -> Bool {
        pid == o.pid && launch == o.launch && digest == o.digest && window.matches(o.window) && focus.matches(o.focus)
            && chain.count == o.chain.count && zip(chain, o.chain).allSatisfy { $0.matches($1) }
    }
    public static func == (a: ChromeReadRecord, b: ChromeReadRecord) -> Bool { a.id == b.id }
}

/// Records per-fact observation times while one read runs (the join's AE and AX calls go through it). Consecutive
/// calls for the same fact (an ancestry walk) are one observation; a fact read again later is a new one.
public final class ChromeFactClock {
    private let now: () -> UInt64
    private var list: [(fact: ChromeFact, times: ChromeFactTimes)] = []
    public init(now: @escaping () -> UInt64) { self.now = now }
    public func observe<T>(_ fact: ChromeFact, _ body: () -> T) -> T {
        let sent = now()
        let value = body()
        let received = max(now(), sent)
        if let last = list.last, last.fact == fact { list[list.count - 1].times.received = received }
        else { list.append((fact, ChromeFactTimes(sent: sent, received: received))) }
        return value
    }
    public var times: [ChromeFact: [ChromeFactTimes]] {
        var out: [ChromeFact: [ChromeFactTimes]] = [:]
        for o in list { out[o.fact, default: []].append(o.times) }
        return out
    }
    /// Apple Events counted by the join (diagnostics: the event rate).
    public var events = 0
}

// MARK: - The bracket engine (B1, B3 recorded boundaries, M3)

/// Main-thread bookkeeping of the reads of one chain and the boundaries between them. Pure: it decides, per key
/// typed at t, whether verified reads bracket it. Light checks never enter it (M3: they neither admit nor bridge).
/// Click-join reads (focus anywhere) never enter it either.
public final class ChromeBracketEngine {
    public enum Decision: Equatable {
        case admit(ra: ChromeReadRecord, rb: ChromeReadRecord)
        /// Not decidable yet: a read that could complete the bracket is running or due.
        case wait
        /// Can never be admitted (no read before it, a failed or unequal read inside its bracket, a boundary
        /// inside it, a span over the limit, or no possible later read).
        case discard
    }
    struct Entry {
        let start: UInt64
        let end: UInt64
        /// nil: the read failed or was refused.
        let record: ChromeReadRecord?
    }
    public var rule: ChromeBracketRule
    public let span: UInt64
    private(set) var entries: [Entry] = []
    /// Start of the read in flight (at most one; M9).
    public private(set) var inFlight: UInt64?
    /// Boundary times (typed/event times) since the chain began. A boundary inside the bracket discards.
    private(set) var boundaries: [UInt64] = []
    public init(rule: ChromeBracketRule = ChromeBracketRule.current, span: UInt64 = ChromeBracketTiming.spanNanoseconds) {
        self.rule = rule; self.span = span
    }
    public var readCount: Int { entries.count }
    public var lastVerified: ChromeReadRecord? { entries.last?.record }
    /// D3: the read a key typed at `t` would take as Ra: the latest delivered read that ended strictly before `t`,
    /// if it was verified (nil if it failed or none did). Not simply the latest read: a read that ended after the
    /// key may have been delivered on main before the key was processed.
    public func verified(endingBefore t: UInt64) -> ChromeReadRecord? { entries.last(where: { $0.end < t })?.record }

    public func readStarted(at t: UInt64) { inFlight = t }
    /// A read ended. `record` nil for any refusal or failure (it breaks every bracket it overlaps).
    public func readFinished(start: UInt64, end: UInt64, record: ChromeReadRecord?) {
        inFlight = nil
        entries.append(Entry(start: start, end: end, record: record.flatMap { $0.complete ? $0 : nil }))
        if entries.count > 64 { entries.removeFirst(entries.count - 64) }
    }
    /// A boundary event (B3) at its event time.
    public func boundary(at t: UInt64) {
        boundaries.append(t)
        if boundaries.count > 256 { boundaries.removeFirst(boundaries.count - 256) }
    }
    /// Starts over: nothing before now can be bracketed (a privacy denial, a policy change, leaving Chrome).
    public func reset() { entries.removeAll(); boundaries.removeAll(); inFlight = nil }

    /// Whether the key typed at `t` is admitted now, can't be decided yet, or never can be.
    public func decide(typedAt t: UInt64, now: UInt64, minimumBSent: [ChromeFact: UInt64] = [:]) -> Decision {
        // The a-side and b-side observation of every fact, as entry index + observation.
        var a: [ChromeFact: (i: Int, o: ChromeFactTimes)] = [:], b: [ChromeFact: (i: Int, o: ChromeFactTimes)] = [:]
        // The fact set: the latest verified read's (reads of another shape never compare equal: `sameFacts`).
        guard let shape = entries.last(where: { $0.record != nil })?.record?.facts else { return inFlight.map { $0 < t } == true ? .wait : .discard }
        switch rule {
        case .wholeRead:
            // Ra: the latest read that ended strictly before t; Rb: the first read that started strictly after t.
            // Its last observation of f before t and Rb's first after t are the tightest pair (rev 3.1 span).
            if let ia = entries.lastIndex(where: { $0.end < t }) {
                guard let ra = entries[ia].record else { return .discard }
                for f in shape { guard let o = ra.times[f]?.last else { return .discard }; a[f] = (ia, o) }
                if let ib = entries.indices.first(where: { i in
                    i > ia && entries[i].start > t && minimumBSent.allSatisfy { f, floor in
                        entries[i].record?.times[f]?.first.map { $0.sent >= floor } == true
                    }
                }) {
                    guard let rb = entries[ib].record else { return .discard }
                    for f in shape { guard let o = rb.times[f]?.first else { return .discard }; b[f] = (ib, o) }
                }
            }
        case .perFact:
            // For each fact: the latest observation (in any delivered read) replied strictly before t, and the
            // first sent strictly after t. A failed read has no observations; one in range discards (below).
            for f in shape {
                for i in entries.indices.reversed() {
                    guard let r = entries[i].record else { if entries[i].end < t { break } else { continue } }
                    guard let obs = r.times[f] else { return .discard }
                    if let o = obs.last(where: { $0.received < t }) { a[f] = (i, o); break }
                }
                for i in entries.indices {
                    guard let r = entries[i].record else { continue }
                    guard let obs = r.times[f] else { return .discard }
                    if let o = obs.first(where: { $0.sent > t && $0.sent >= (minimumBSent[f] ?? 0) }) { b[f] = (i, o); break }
                }
            }
        }
        guard a.count == shape.count else {
            // Some fact has no observation before t: only the read still running (started before t) could give one.
            return inFlight.map { $0 < t } == true ? .wait : .discard
        }
        let lo = a.values.map(\.i).min()!
        guard let first = entries[lo].record else { return .discard }
        guard b.count == shape.count else {
            // No complete b-side yet: every read after the a-side so far verified and equal, no boundary since, and a
            // later observation (its reply after now) still able to meet the span for every fact.
            for e in entries[lo...] { guard let r = e.record, r.sameFacts(as: first) else { return .discard } }
            if boundaries.contains(where: { $0 >= first.start && $0 <= now }) { return .discard }
            // Facts whose b-side has arrived must already meet the rule; the rest must still be able to (review fork,
            // source bug 1: the timeout was applied to every fact, discarding brackets still validly waiting).
            for (f, x) in a {
                if let y = b[f] {
                    guard y.o.sent > t, x.o.received < t, y.o.received >= x.o.sent, y.o.received - x.o.sent <= span else { return .discard }
                } else {
                    // Wall time alone cannot expire an observation whose read began in time but is still
                    // undelivered. This only delays a decision: delivered facts still must meet the original
                    // 150 ms span, equality and boundary rules below. Held keys retain their separate 1 s cap.
                    let pendingCanSupplyB = inFlight.map { started in
                        started < x.o.sent &+ span && (rule != .wholeRead || started > t)
                    } ?? false
                    guard now < x.o.sent &+ span || pendingCanSupplyB else { return .discard }
                }
            }
            return .wait
        }
        let hi = b.values.map(\.i).max()!
        guard hi >= lo, let last = entries[hi].record else { return .discard }
        // Every read from the a-side through the b-side verified, with every fact equal (B1).
        for e in entries[lo...hi] { guard let r = e.record, r.sameFacts(as: first) else { return .discard } }
        // No boundary inside the bracket, taken as whole reads (B3; conservative).
        if boundaries.contains(where: { $0 >= first.start && $0 <= last.end }) { return .discard }
        // Every fact's span (rev 3.1): later reply - earlier send.
        for f in shape {
            let (x, y) = (a[f]!.o, b[f]!.o)
            guard y.sent > t, x.received < t, y.received >= x.sent, y.received - x.sent <= span else { return .discard }
        }
        admittedBSideSent = b.values.map(\.o.sent).min()
        return .admit(ra: first, rb: last)
    }
    /// The earliest b-side observation's send time of the last `.admit` (every fact's b-side was sent after the key:
    /// this is the burst's witness for "the b-side is after the key" under either rule).
    public private(set) var admittedBSideSent: UInt64?
}

// MARK: - Held keys (B4)

/// What a held key does once admitted. Metadata only; its characters stay in the owned byte buffer.
public enum ChromeHeldKind: Equatable, Sendable {
    /// Characters (a typed, dead-key-composed or soft-newline key).
    case text
    /// A press-and-hold accent: delete one character, then insert the held characters.
    case accent
    /// An edit of the unit (delete backward and friends): no characters.
    case edit(TypingOp)
}

/// B4: a key's characters held in memory, unproven, until its bracket is decided. A fixed-capacity byte buffer
/// owned by this object: not `String`, not `Codable`, no description or mirror of its bytes. Wiped with
/// `memset_s` whenever keys are discarded or handed on. "Zeroed" is claimed only for this buffer: never for the
/// CGEvent, the acquire temporaries or the typing session's copy after admission.
public final class ChromeHeldKeys {
    public struct Key {
        public let typedAt: UInt64
        public let kind: ChromeHeldKind
        fileprivate let offset: Int
        fileprivate let length: Int
        /// B2: the key-time focused window and element refs (compared with its bracketing reads).
        public let window: ChromeRef
        public let focus: ChromeRef
    }
    public let capacityKeys: Int
    public let maxAge: UInt64
    private let bytesPerKey: Int
    private let storage: UnsafeMutableRawPointer
    private let storageSize: Int
    private var used = 0
    public private(set) var keys: [Key] = []
    public init(capacityKeys: Int = ChromeBracketTiming.holdMaxKeys, maxAge: UInt64 = ChromeBracketTiming.holdMaxNanoseconds,
                bytesPerKey: Int = ChromeBracketTiming.holdMaxBytesPerKey) {
        self.capacityKeys = capacityKeys; self.maxAge = maxAge; self.bytesPerKey = bytesPerKey
        storageSize = capacityKeys * bytesPerKey
        storage = UnsafeMutableRawPointer.allocate(byteCount: storageSize, alignment: 16)
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: storageSize)
    }
    deinit { wipe(); storage.deallocate() }
    public var isEmpty: Bool { keys.isEmpty }
    public var count: Int { keys.count }
    public var oldest: UInt64? { keys.first?.typedAt }

    public enum Append: Equatable { case held, overflow }
    /// Holds one key. `characters` writes its UTF-8 into the owned buffer. Over the key cap, the byte cap, or the
    /// age cap: `.overflow`, and the caller wipes everything.
    public func append(typedAt: UInt64, kind: ChromeHeldKind, window: ChromeRef, focus: ChromeRef, characters: String) -> Append {
        guard keys.count < capacityKeys, oldest.map({ typedAt >= $0 && typedAt - $0 <= maxAge }) ?? true else { return .overflow }
        var utf8 = Array(characters.utf8)
        defer { utf8.withUnsafeMutableBytes { raw in if let base = raw.baseAddress { _ = memset_s(base, raw.count, 0, raw.count) } } }
        guard utf8.count <= bytesPerKey, used + utf8.count <= storageSize else { return .overflow }
        utf8.withUnsafeBytes { raw in if let base = raw.baseAddress { (storage + used).copyMemory(from: base, byteCount: raw.count) } }
        keys.append(Key(typedAt: typedAt, kind: kind, offset: used, length: utf8.count, window: window, focus: focus))
        used += utf8.count
        return .held
    }
    /// The held characters of the first key as a String (a copy this type does not own), and removes that key,
    /// wiping its bytes.
    public func takeFirst() -> (key: Key, characters: String)? {
        guard let k = keys.first else { return nil }
        let s = String(decoding: UnsafeRawBufferPointer(start: storage + k.offset, count: k.length), as: UTF8.self)
        _ = memset_s(storage + k.offset, k.length, 0, k.length)
        keys.removeFirst()
        if keys.isEmpty { used = 0 }
        return (k, s)
    }
    /// Drops the first key unread, wiping its bytes.
    public func dropFirst() {
        guard let k = keys.first else { return }
        _ = memset_s(storage + k.offset, k.length, 0, k.length)
        keys.removeFirst()
        if keys.isEmpty { used = 0 }
    }
    /// Wipes every held byte and forgets every key.
    public func wipe() {
        _ = memset_s(storage, storageSize, 0, storageSize)
        keys.removeAll(); used = 0
    }
    /// Checks only: whether every byte of the owned buffer is zero.
    public var allZero: Bool {
        let p = storage.assumingMemoryBound(to: UInt8.self)
        return (0..<storageSize).allSatisfy { p[$0] == 0 }
    }
}

// MARK: - Diagnostics (B5)

/// Aggregate-only counters of the bracketed design, for checks and harness runs. Never a per-key, per-field,
/// per-site or per-reason split; privacy-denied keys are never counted (their pending count is dropped).
/// `lost` counts keys that were not admitted for non-privacy reasons only (uncovered, boundary, overflow,
/// timeout, chain broken, late), and is committed only after a later read proved no privacy refusal.
public final class ChromeBracketDiagnostics {
    /// The pinned keys (B5): `snapshot()` never has any other.
    /// QF-17 silent-loss fix (b+ real-Chrome self-check on 939e6df; approved as a step, switched off, 08:29):
    /// `keys.lost.<reason>` (keys NOT admitted), `keys.dropped` (admitted keys whose text never reached the store: ONE
    /// undivided total, review 08:29; its reasons stay inside, `droppedByReason`, never in the snapshot), `keys.saved`
    /// and `keys.pending`. Invariant: admitted = saved + dropped + pending (in the session's units: a typed key 1, an
    /// accent 2 (its delete and insert), an edit that changed nothing 0), and pending is 0 once the burst is over.
    /// A B5 review is required before `snapshot()` is ever logged or shown (totals per long window only).
    public static let allowedKeys: Set<String> = Set(["keys.admitted", "keys.lost", "keys.saved", "keys.dropped", "keys.pending",
                                                      "reads.verified", "reads.denied", "ae.events",
                                                      "read.ms.p50", "read.ms.p95", "read.ms.max", "intake.us.p50", "intake.us.p95", "intake.us.max"]
                                                     + LossReason.allCases.map { "keys.lost." + $0.rawValue })
    /// Why a key was NOT admitted (non-privacy reasons only; nothing around a privacy refusal is counted, B5).
    public enum LossReason: String, CaseIterable, Sendable {
        /// Dropped at intake with nothing read for it (no fresh read, the identity reader paused, the loop stopped).
        case unread
        /// Held, then never bracketed (a discard, the hold cap, a failed or unequal read, a non-privacy denial).
        case bracket
        /// Bracketed by the engine, then refused by the burst's own admission check (fail closed).
        case admission
    }
    /// Why an ADMITTED key's text never reached the store.
    public enum DropReason: String, CaseIterable, Sendable {
        /// Its unit was retracted or expired unwritten (a failed admission recheck retracts the unit; a key in the quiet
        /// period, an idle save that could not be made), with no privacy cause.
        case retract
        /// The store or the row checks refused its unit's row.
        case save
        /// A privacy refusal, boundary, drop, gate, latch or secret ended it (a classifier rejection included: an opaque
        /// token is refused as a secret would be). One merged reason, and inside only: the snapshot has the undivided
        /// `keys.dropped` (B5-2: a drop names no reason; review 08:29).
        case privacy
        /// QF-17 attribution (10:00): the settle couldn't prove where its unit went (departure denied, focus unconfirmed,
        /// judged too late). Fail closed, not a privacy refusal.
        case departure
        /// Its unit had nothing but whitespace left (or only deletions) when it was sealed or saved: nothing to write.
        case empty
        /// The parked FIFO was full (`TypingLimits.maxParked`): the oldest unit was evicted. A capacity cost.
        case capacity
    }
    public private(set) var admitted = 0
    public private(set) var lost = 0
    private var pendingLost = 0
    private var pendingByReason: [LossReason: Int] = [:]
    public private(set) var lostByReason: [LossReason: Int] = [:]
    /// Admitted keys' units that entered the session (the ledger's admitted side).
    public private(set) var admittedUnits = 0
    /// Units written to the store (`keys.saved`).
    public private(set) var savedUnits = 0
    public private(set) var droppedByReason: [DropReason: Int] = [:]
    public var dropped: Int { droppedByReason.values.reduce(0, +) }
    /// The session's unwritten units at the last reconciliation (`keys.pending`).
    public private(set) var pending = 0
    /// Reconciliations that found more accounted than admitted (a bookkeeping bug; must stay 0). Counted, never a crash
    /// (review 08:29: a bookkeeping bug must not stop an owner build while someone types); the checks assert it is 0.
    public private(set) var ledgerErrors = 0
    public private(set) var readsVerified = 0
    public private(set) var readsDenied = 0
    public private(set) var appleEvents = 0
    private var readMs: [Double] = []
    private var intakeMicros: [Double] = []
    public init() {}
    public func keyAdmitted() { admitted += 1 }
    /// A key NOT admitted, for a non-privacy reason. Held until the next read says no privacy refusal (`confirm`).
    public func keyLost(_ n: Int = 1, _ reason: LossReason) {
        guard n > 0 else { return }
        pendingLost += n; pendingByReason[reason, default: 0] += n
    }
    /// A read verified: pending losses were not privacy losses.
    public func confirm() {
        lost += pendingLost; pendingLost = 0
        for (r, n) in pendingByReason { lostByReason[r, default: 0] += n }
        pendingByReason = [:]
    }
    /// A privacy refusal: no key around it is counted lost.
    public func privacyRefusal() { pendingLost = 0; pendingByReason = [:] }
    /// An admitted key's units entered the session.
    public func admitUnits(_ n: Int) { admittedUnits += max(0, n) }
    /// A row was written with these units.
    public func saved(_ n: Int) { savedUnits += max(0, n) }
    /// Admitted units not saved, dropped or pending in the session (`sessionPending`): 0 when balanced.
    public func unaccounted(sessionPending: Int) -> Int { admittedUnits - savedUnits - dropped - sessionPending }
    /// After any work that can change the session: admitted text that left it unwritten is counted dropped now, with
    /// `reason`. Nothing admitted can leave the session silently.
    /// `named`: the session's own tally of why units left (`TypingSession.takeUnitDrops`), which names them first;
    /// `reason` names the rest.
    public func reconcile(sessionPending: Int, reason: DropReason, named: [DropReason: Int] = [:]) {
        let gap = unaccounted(sessionPending: sessionPending)
        var rest = gap
        for r in DropReason.allCases where rest > 0 {
            let n = min(rest, named[r] ?? 0)
            if n > 0 { droppedByReason[r, default: 0] += n; rest -= n }
        }
        if rest > 0 { droppedByReason[reason, default: 0] += rest }
        if gap < 0 { ledgerErrors += 1 }
        pending = sessionPending
    }
    /// admitted = saved + dropped + pending, with no bookkeeping error.
    public func balanced(sessionPending: Int) -> Bool { ledgerErrors == 0 && unaccounted(sessionPending: sessionPending) == 0 }
    public func read(verified: Bool, milliseconds: Double, events: Int) {
        // B5-1 (fix/chrome-capture 42d966e): a refused read leaves only the count, no timing and no event count (a
        // refusal's time can tell its reason: the mode gate refuses after one event, a sensitive field after all).
        guard verified else { readsDenied += 1; return }
        readsVerified += 1
        readMs.append(milliseconds); appleEvents += events
        if readMs.count > 4096 { readMs.removeFirst(readMs.count - 4096) }
    }
    public func intake(microseconds: Double) {
        intakeMicros.append(microseconds)
        if intakeMicros.count > 4096 { intakeMicros.removeFirst(intakeMicros.count - 4096) }
    }
    static func percentile(_ v: [Double], _ p: Double) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted(); return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
    }
    public func snapshot() -> [String: Double] {
        var out: [String: Double] = ["keys.admitted": Double(admitted), "keys.lost": Double(lost), "keys.saved": Double(savedUnits),
            "keys.dropped": Double(dropped), "keys.pending": Double(pending), "reads.verified": Double(readsVerified),
            "reads.denied": Double(readsDenied), "ae.events": Double(appleEvents),
            "read.ms.p50": Self.percentile(readMs, 0.5), "read.ms.p95": Self.percentile(readMs, 0.95), "read.ms.max": readMs.max() ?? 0,
            "intake.us.p50": Self.percentile(intakeMicros, 0.5), "intake.us.p95": Self.percentile(intakeMicros, 0.95), "intake.us.max": intakeMicros.max() ?? 0]
        for r in LossReason.allCases { out["keys.lost." + r.rawValue] = Double(lostByReason[r] ?? 0) }
        precondition(Set(out.keys).isSubset(of: Self.allowedKeys), "bracket diagnostics: unpinned key")
        return out
    }
}
#endif

#if DAYDREAM_CHROME_TYPING
// MARK: - Key-time identity (B2) and the read loop's shared control (M4, M9)

/// B2: captured on main at the key, before its characters are acquired. Only the frontmost PID (no AX), secure
/// input, and the focused window and element REFS of Chrome's application element (M8: read only after a
/// verified read passed the mode gate; 25 ms timeout; no attribute of the refs is read). nil refs: unreadable.
/// The system-wide focused application is not read here (M9: it has no timeout). PM2: the route checks the one
/// `NativeTypingRoute.keyTarget` already read on main for this key, and every read observes it too (`focusState`).
public struct ChromeKeyIdentity {
    public var frontmostPID: Int32?
    public var secureInput: Bool
    public var window: AnyObject?
    public var focus: AnyObject?
    public init(frontmostPID: Int32?, secureInput: Bool, window: AnyObject?, focus: AnyObject?) {
        self.frontmostPID = frontmostPID; self.secureInput = secureInput; self.window = window; self.focus = focus
    }
}

/// State the main thread and the read loop share, behind one lock. Main writes; the loop reads. Everything else a
/// read uses is an immutable snapshot taken when the loop starts (policy, sites, consent), re-checked on main
/// (epoch, generation, version, PID) before any result is used.
public final class ChromeReadControl: @unchecked Sendable {
    private let lock = NSLock()
    private var epochValue: UInt64 = 0
    private var activeUntilValue: UInt64 = 0
    private var enabledValue = false
    private var pageReadWanted = false
    private var fullReadWanted = false
    private var runningValue = false
    /// Recent reads' start and end (end nil while running), for B4's "a read that started before the key is running".
    private var spans: [(id: UInt64, start: UInt64, end: UInt64?, full: Bool)] = []
    private var nextSpan: UInt64 = 0
    public init() {}
    public var epoch: UInt64 { lock.lock(); defer { lock.unlock() }; return epochValue }
    /// Stops every read loop started before (their results are ignored) and clears requests.
    public func bump() { lock.lock(); epochValue &+= 1; activeUntilValue = 0; pageReadWanted = false; fullReadWanted = false; spans.removeAll(); lock.unlock() }
    public func setEnabled(_ on: Bool) { lock.lock(); enabledValue = on; lock.unlock() }
    public func enabled(epoch: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return enabledValue && epochValue == epoch }
    public func extend(until t: UInt64) { lock.lock(); activeUntilValue = max(activeUntilValue, t); lock.unlock() }
    public func wantPage() { lock.lock(); pageReadWanted = true; lock.unlock() }
    public func wantFull() { lock.lock(); fullReadWanted = true; lock.unlock() }
    /// Marks the loop running; false if one already is (at most one read in flight: M9).
    public func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if runningValue { return false }; runningValue = true; return true }
    public var running: Bool { lock.lock(); defer { lock.unlock() }; return runningValue }
    public enum Next: Equatable { case full, page, stop, stale }
    /// The loop's next step (on the loop's thread): a requested click join, a full read while active or
    /// requested, or stop (`stale`: stopped because the epoch moved on; the route starts a loop for the new one).
    public func next(epoch: UInt64, now: UInt64) -> Next {
        lock.lock(); defer { lock.unlock() }
        guard epochValue == epoch, enabledValue else { runningValue = false; return enabledValue ? .stale : .stop }
        if pageReadWanted { pageReadWanted = false; return .page }
        if fullReadWanted || now < activeUntilValue { fullReadWanted = false; return .full }
        runningValue = false
        return .stop
    }
    /// A read of this epoch began at `t` (on the loop's thread); returns its token for `ended`.
    public func began(_ t: UInt64, epoch: UInt64, full: Bool = true) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard epoch == epochValue else { return nil }
        nextSpan &+= 1; spans.append((nextSpan, t, nil, full)); if spans.count > 16 { spans.removeFirst(spans.count - 16) }
        return nextSpan
    }
    public func ended(_ token: UInt64?, at t: UInt64) {
        lock.lock(); if let token, let i = spans.firstIndex(where: { $0.id == token }) { spans[i].end = t }; lock.unlock()
    }
    /// A full read not yet delivered to the main-owned engine. Physical completion is not delivery: a valid
    /// observation can already have finished while its main-queue callback is delayed. Page reads cannot bracket
    /// keys. PM8 permits only one undelivered read; an epoch reset or disabled capture invalidates its metadata.
    public func undeliveredFullReadStart(after delivered: UInt64?, epoch: UInt64) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard enabledValue, epochValue == epoch else { return nil }
        return spans.last { s in s.full && (delivered.map { s.start > $0 } ?? true) }?.start
    }
    /// Whether a read started after `after` (exclusive; nil: any) and strictly before `before`.
    public func startedBetween(after: UInt64?, before: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return spans.contains { s in s.start < before && after.map { s.start > $0 } ?? true }
    }
    /// B4 (a): some read started strictly before `t` and had not ended by `t`.
    public func readRunning(at t: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return spans.contains { $0.start < t && ($0.end.map { $0 > t } ?? true) }
    }
}
#endif
