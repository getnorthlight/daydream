import Foundation

// Pure oracles for 0.2.0's recording rows (scripts/harness/README.md, "0.2.0 readiness"): what the store must hold
// after a timeline is replayed, computed from the timeline alone. No app code, no store, no clock.
//
// - expectedSamples: one sample row a minute while DayDream records: the app in front, seconds since the last input,
//   whether the microphone is in use.
// - expectedSessionEvents: the sleep, lock and pause intervals (start and end), closed when DayDream quits, never
//   overlapping.
// - RecordingRowsAdapter: the one protocol 0.2.0's store implements so a replay can read its rows back and compare.

/// One sample: taken at each whole minute (absolute time: 60 real seconds apart across a DST change) while DayDream
/// runs, recording is on, and nothing suspends it (no pause, sleep or lock).
struct SampleRow: Equatable, Codable, CustomStringConvertible {
    /// Seconds after the timeline's start.
    let at: Double
    /// The minute in the timeline's zone, with its offset ("2026-11-01T01:30-05:00"): the label repeats across a fall-back
    /// hour with another offset, and skips the spring-forward hour.
    let minute: String
    /// The app in front (nil: none known yet).
    let bundle: String?
    let app: String?
    /// Whole seconds since the last input (a key, a click, an app/window/tab/field switch); nil: none yet.
    let secondsSinceInput: Int?
    let micInUse: Bool
    var description: String { "\(minute) \(bundle ?? "-") idle=\(secondsSinceInput.map(String.init) ?? "-") mic=\(micInUse)" }
}

/// One suspension interval. `end` is nil while it is still open when the timeline ends.
struct SessionEventRow: Equatable, Codable, CustomStringConvertible {
    enum Kind: String, Codable, Comparable { case pause, lock, sleep
        /// Sleep hides a lock, a lock hides a pause: at most one interval is open at a time (the highest).
        var rank: Int { switch self { case .pause: return 1; case .lock: return 2; case .sleep: return 3 } }
        static func < (a: Kind, b: Kind) -> Bool { a.rank < b.rank }
    }
    let kind: Kind
    let start: Double
    let end: Double?
    /// What ended it: "wake", "unlock", "resume", "timed-pause-end", "quit", "recording-off", or the kind that hid it
    /// ("lock", "sleep"). nil while open.
    let endedBy: String?
    var description: String { "\(kind.rawValue)[\(start)-\(end.map { String($0) } ?? "open") \(endedBy ?? "")]" }
}

/// What 0.2.0's store rows read back as, for one replayed timeline. 0.2.0's recorder implements this over its sample
/// and session-event tables (one adapter, see scripts/harness/README.md); the harness then compares it with the
/// oracles (`RecordingRowsComparison`). 0.1.8 has no such rows: `NoRecordingRowsYet` says so.
protocol RecordingRowsAdapter {
    /// Whether this build writes the rows at all (false: the comparison is skipped and says why).
    var writesRows: Bool { get }
    /// Every sample row the store holds, oldest first, as seconds after `timelineStart`.
    func sampleRows(timelineStart: Date) throws -> [SampleRow]
    /// Every sleep, lock and pause row, oldest first.
    func sessionEventRows(timelineStart: Date) throws -> [SessionEventRow]
}
struct NoRecordingRowsYet: RecordingRowsAdapter {
    var writesRows: Bool { false }
    func sampleRows(timelineStart: Date) throws -> [SampleRow] { [] }
    func sessionEventRows(timelineStart: Date) throws -> [SessionEventRow] { [] }
}

/// Expected against read-back rows. `slack`: a real recorder's timer fires a moment after the minute, so a sample's
/// time and its seconds-since-input may be late by up to `slack` seconds.
enum RecordingRowsComparison {
    static func samples(expected: [SampleRow], actual: [SampleRow], slack: Double = 2) -> [String] {
        var diffs: [String] = []
        if expected.count != actual.count { diffs.append("sample rows: \(actual.count), want \(expected.count)") }
        for (i, (e, a)) in zip(expected, actual).enumerated() {
            if a.at < e.at - 1e-6 || a.at > e.at + slack { diffs.append("sample \(i): at \(a.at), want \(e.at)") }
            if a.minute != e.minute { diffs.append("sample \(i): minute \(a.minute), want \(e.minute)") }
            if a.bundle != e.bundle { diffs.append("sample \(i): front \(a.bundle ?? "-"), want \(e.bundle ?? "-")") }
            if a.micInUse != e.micInUse { diffs.append("sample \(i): mic \(a.micInUse), want \(e.micInUse)") }
            switch (e.secondsSinceInput, a.secondsSinceInput) {
            case (nil, nil): break
            case (let x?, let y?) where Double(y) >= Double(x) && Double(y) <= Double(x) + slack: break
            default: diffs.append("sample \(i): idle \(a.secondsSinceInput.map(String.init) ?? "-"), want \(e.secondsSinceInput.map(String.init) ?? "-")")
            }
        }
        return diffs
    }
    static func sessionEvents(expected: [SessionEventRow], actual: [SessionEventRow], slack: Double = 2) -> [String] {
        var diffs: [String] = []
        if expected.count != actual.count { diffs.append("session rows: \(actual.count), want \(expected.count)") }
        func near(_ a: Double?, _ e: Double?) -> Bool {
            switch (a, e) { case (nil, nil): return true; case (let x?, let y?): return abs(x - y) <= slack; default: return false }
        }
        for (i, (e, a)) in zip(expected, actual).enumerated() where a.kind != e.kind || !near(a.start, e.start) || !near(a.end, e.end) {
            diffs.append("session row \(i): \(a), want \(e)")
        }
        diffs += RecordingOracle.overlaps(actual).map { "read-back rows overlap: " + $0 }
        return diffs
    }
}

enum RecordingOracle {
    /// The person's inputs, as the sample's "seconds since the last input" counts them.
    static let inputOps: Set<TimelineEvent.Op> = [.type, .backspace, .key, .input, .front, .window, .tab, .focus]

    private enum Atom {
        case launch, quit, record(Bool), front(String, String), input, mic(Bool), sleep, wake, lock, unlock
        case pause(token: Int), resume, pauseEnds(token: Int)
    }
    private struct State {
        var running = false, recording = false, asleep = false, locked = false, mic = false
        var paused: Int?
        var front: (app: String, bundle: String)?
        var lastInput: Double?
        var sampling: Bool { running && recording && paused == nil && !asleep && !locked }
        /// The interval open now (only while DayDream runs with recording on).
        var top: SessionEventRow.Kind? {
            guard running && recording else { return nil }
            return asleep ? .sleep : locked ? .lock : paused != nil ? .pause : nil
        }
    }

    /// The timeline as instants, in order (a typing event is one input per key; a timed pause ends by itself).
    private static func atoms(_ t: Timeline) -> [(at: Double, order: Int, atom: Atom)] {
        var out: [(Double, Int, Atom)] = []
        var order = 0, token = 0
        func add(_ at: Double, _ a: Atom) { out.append((at, order, a)); order += 1 }
        for e in t.events {
            switch e.op {
            case .launch: add(e.at, .launch)
            case .quit: add(e.at, .quit)
            case .record: add(e.at, .record(e.on ?? true))
            case .front: add(e.at, .front(e.app ?? "", e.bundle ?? "")); add(e.at, .input)
            case .mic: add(e.at, .mic(e.on ?? false))
            case .sleep: add(e.at, .sleep)
            case .wake: add(e.at, .wake)
            case .lock: add(e.at, .lock)
            case .unlock: add(e.at, .unlock)
            case .pause:
                token += 1; add(e.at, .pause(token: token))
                if let s = e.seconds { add(e.at + s, .pauseEnds(token: token)) }
            case .resume: add(e.at, .resume)
            case .type, .backspace, .key: for k in e.keyTimes { add(k, .input) }
            case .input, .window, .tab, .focus: add(e.at, .input)
            case .writer, .hold: break
            }
        }
        return out.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map { (at: $0.0, order: $0.1, atom: $0.2) }
    }
    private static func apply(_ a: Atom, at: Double, _ s: inout State) -> String? {
        switch a {
        case .launch: s.running = true; s.asleep = false; return nil
        case .quit: s.running = false; return "quit"
        case .record(let on): s.recording = on; return on ? nil : "recording-off"
        case .front(let app, let bundle): s.front = (app, bundle); return nil
        case .input: s.lastInput = at; return nil
        case .mic(let on): s.mic = on; return nil
        case .sleep: s.asleep = true; return nil
        case .wake: s.asleep = false; return "wake"
        case .lock: s.locked = true; return nil
        case .unlock: s.locked = false; return "unlock"
        case .pause(let token): s.paused = token; return nil
        case .resume: s.paused = nil; return "resume"
        case .pauseEnds(let token): if s.paused == token { s.paused = nil; return "timed-pause-end" }; return nil
        }
    }

    static func expectedSamples(_ t: Timeline) throws -> [SampleRow] {
        let start = try t.startDate, zone = try t.zone, end = t.end
        let epoch0 = start.timeIntervalSince1970
        let label = DateFormatter()
        label.locale = Locale(identifier: "en_US_POSIX"); label.timeZone = zone; label.dateFormat = "yyyy-MM-dd'T'HH:mmXXXXX"
        let list = atoms(t)
        var s = State(), next = 0, rows: [SampleRow] = []
        var boundary = (epoch0 / 60).rounded(.up) * 60
        while boundary - epoch0 <= end + 1e-9 {
            let offset = boundary - epoch0
            // Events at the minute itself take effect first.
            while next < list.count, list[next].at <= offset + 1e-9 { _ = apply(list[next].atom, at: list[next].at, &s); next += 1 }
            if s.sampling {
                rows.append(SampleRow(at: offset, minute: label.string(from: Date(timeIntervalSince1970: boundary)),
                                      bundle: s.front?.bundle, app: s.front?.app,
                                      secondsSinceInput: s.lastInput.map { Int((offset - $0 + 1e-9).rounded(.down)) }, micInUse: s.mic))
            }
            boundary += 60
        }
        return rows
    }

    static func expectedSessionEvents(_ t: Timeline) throws -> [SessionEventRow] {
        _ = try t.startDate
        let list = atoms(t)
        var s = State(), rows: [SessionEventRow] = [], open: (kind: SessionEventRow.Kind, start: Double)?
        var i = 0
        while i < list.count {
            let at = list[i].at
            var endings: [String] = []
            // Every instant at the same time first, then one decision (a lock and a sleep at once open one interval).
            while i < list.count, abs(list[i].at - at) < 1e-9 {
                if let why = apply(list[i].atom, at: at, &s) { endings.append(why) }
                i += 1
            }
            let top = s.top
            guard top != open?.kind else { continue }
            if let o = open {
                let why: String
                if endings.contains("quit") { why = "quit" }
                else if endings.contains("recording-off") { why = "recording-off" }
                else if let t = top, t > o.kind { why = t.rawValue }
                else {
                    let mine: [SessionEventRow.Kind: [String]] = [.sleep: ["wake"], .lock: ["unlock"], .pause: ["resume", "timed-pause-end"]]
                    why = endings.first { mine[o.kind]?.contains($0) == true } ?? endings.first ?? "changed"
                }
                rows.append(SessionEventRow(kind: o.kind, start: o.start, end: at, endedBy: why))
            }
            open = top.map { ($0, at) }
        }
        if let o = open { rows.append(SessionEventRow(kind: o.kind, start: o.start, end: nil, endedBy: nil)) }
        return rows
    }

    /// Rows that overlap or run backwards (none may).
    static func overlaps(_ rows: [SessionEventRow]) -> [String] {
        var out: [String] = []
        for (i, r) in rows.enumerated() {
            if let e = r.end, e <= r.start { out.append("\(r) ends before it starts") }
            if i > 0, let prev = rows[i - 1].end ?? Optional(Double.infinity), prev > r.start + 1e-9 { out.append("\(rows[i - 1]) overlaps \(r)") }
            if i < rows.count - 1, r.end == nil { out.append("\(r) is open but not last") }
        }
        return out
    }
}
