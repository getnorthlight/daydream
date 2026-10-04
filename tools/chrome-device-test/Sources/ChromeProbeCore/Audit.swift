import Foundation

/// Independent referee for the order of reads. It watches every Apple Event
/// reply itself (it does not trust the join's own bookkeeping) and records a
/// violation whenever a title, address, tab or Accessibility read happens
/// before every listed Chrome window has answered exactly "normal" in the
/// current pass. Strict mode: one Incognito/Guest window anywhere blocks all
/// such reads. Apple Events leave out a window that is still opening or
/// closing, so once the Accessibility side has shown more standard windows
/// than were listed, every later read is a violation too (review I1).
public final class ReadAudit {
    public private(set) var violations: [String] = []
    public private(set) var aeContentReads = 0
    public private(set) var axContentReads = 0
    private var listed: [String]?
    private var indexed: [Int: String] = [:]
    private var modes: [String: String] = [:]
    private var axStandard: Int?

    public init() {}

    /// Start of one join / one listing. Nothing from a previous pass counts.
    public func beginPass() { listed = nil; indexed = [:]; modes = [:]; axStandard = nil }

    /// The number of standard windows Chrome's AXWindows showed in this pass.
    public func noteAXWindows(standard: Int) { axStandard = standard }

    /// Accessibility showed a standard window that Apple Events did not list.
    public var unlistedWindowSeen: Bool {
        guard let n = axStandard, let listed else { return false }
        return n > listed.count
    }

    public func observe(_ q: AEQuery, _ r: AEReply) {
        switch q {
        case .window(.every, .id):
            listed = r.list
        case .window(.index(let i), .id):
            if let id = r.text, !id.isEmpty {
                indexed[i] = id
            } else if (1..<max(i, 1)).allSatisfy({ indexed[$0] != nil }) {
                // Contiguous 1..i-1 answered and i failed: the listing is complete.
                listed = (1..<max(i, 1)).map { indexed[$0]! }
            }
        case .window(.id(let id), .mode):
            modes[id] = r.text ?? ""
        default:
            break
        }
    }

    /// Every window in the latest complete listing has answered "normal".
    public var allListedNormal: Bool {
        guard let listed else { return false }
        return listed.allSatisfy { modes[$0] == "normal" }
    }

    public func willSend(_ q: AEQuery) {
        guard q.isContent else { return }
        aeContentReads += 1
        guard let target = q.targetWindowID, allListedNormal, listed?.contains(target) == true else {
            violations.append("\(q.label) sent before every listed window answered \"normal\"")
            return
        }
        if unlistedWindowSeen { violations.append("\(q.label) sent while Accessibility showed a window Apple Events did not list") }
    }

    public func willReadAX(_ what: String) {
        axContentReads += 1
        if !allListedNormal { violations.append("\(what) read before every listed window answered \"normal\"") }
        else if unlistedWindowSeen { violations.append("\(what) read while Accessibility showed a window Apple Events did not list") }
    }
}

public enum ReadKind: String, Codable { case ae, ax, system }

public struct TimedRead: Codable {
    public var kind: ReadKind
    public var label: String
    public var ms: Double
}

/// All read timings for the run, for the per-read budget criteria.
public final class TimingLog {
    public private(set) var ae: [Double] = []
    public private(set) var ax: [Double] = []
    public private(set) var system: [Double] = []
    public var echo: ((TimedRead) -> Void)?
    public init() {}
    public func record(_ kind: ReadKind, _ label: String, _ ms: Double) {
        switch kind {
        case .ae: ae.append(ms)
        case .ax: ax.append(ms)
        case .system: system.append(ms)
        }
        echo?(TimedRead(kind: kind, label: label, ms: ms))
    }
}

/// Wraps the Chrome transport: audits, then times, every Apple Event.
public final class AuditedPort: AppleEventPort {
    public let inner: AppleEventPort
    public let audit: ReadAudit
    public let timings: TimingLog
    public private(set) var sent: [AEQuery] = []
    /// Descriptor types of the successful replies, by property (F9, review C4).
    public private(set) var replyTypes: [String: Set<String>] = [:]
    public init(_ inner: AppleEventPort, audit: ReadAudit, timings: TimingLog) {
        self.inner = inner; self.audit = audit; self.timings = timings
    }
    public func send(_ q: AEQuery) -> AEReply {
        audit.willSend(q)
        let r = inner.send(q)
        sent.append(q)
        audit.observe(q, r)
        timings.record(.ae, q.label, milliseconds(r.nanos))
        if r.status == 0, r.value != nil, let t = r.rawType { replyTypes[q.replyKind, default: []].insert(t) }
        return r
    }
}

public struct Stats: Codable, CustomStringConvertible {
    public var count: Int, min: Double, median: Double, p90: Double, p95: Double, max: Double
    public static func of(_ values: [Double]) -> Stats? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        func rank(_ p: Double) -> Double { s[Swift.min(s.count - 1, Swift.max(0, Int((p * Double(s.count)).rounded(.up)) - 1))] }
        let median = s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        return Stats(count: s.count, min: s[0], median: median, p90: rank(0.9), p95: rank(0.95), max: s[s.count - 1])
    }
    public var description: String {
        String(format: "median %.1f p90 %.1f max %.1f ms (n=%d)", median, p90, max, count)
    }
}
