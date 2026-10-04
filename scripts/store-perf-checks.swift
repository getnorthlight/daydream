// DD-RECIPE: CORE+UI (MemoryCore, HistoryCore, PrivacyPolicy and MemoryUI objects; run-checks.sh "store-perf")
// Store work that runs while recording costs what is new, not the whole history (golden test 5, perf-store stream).
// Synthetic stores under $TMPDIR only; nothing here opens the real DayDream home, the Keychain or any permission.
//   A. G17  timestamp()/iso()/isoPrecise(): the same result as the old per-call formatters for DayDream's two forms,
//           edge cases, one-byte fuzz and other ISO forms, from many threads at once; at least 10x cheaper.
//   B. G16  Today's rebuild on the main actor (TodaySnapshot + DayDigest) for a 3000-action day: under 150 ms CPU.
//   C. G47  the time indexes exist exactly as made, the rollback journal stays, a store that can't take them still
//           opens, a backup of an indexed store exports, and time reads (timeline, one hour, today's layers) cost the
//           same with 10x the history.
//   D. G6   writePending: the same summaries as a whole-table pass (new, updated, another connection's, summaries
//           removed, policy changes, a record dated ahead, retention) and a cost that does not grow with history; its
//           whole-table check lets the heartbeat in between short transactions.
//   E. G60  a writable open of an existing store needs no write lock (another connection's long write never fails it).
//   F. G27 x G7 (final review)  a search for a word no row has, over 90,000 records, while the heartbeat writes: on the
//           recorder's own connection, on another connection and in another process (an AI app's search), the
//           heartbeat's longest wait is under 50 ms (one whole-history statement made it wait 0.6 s at two months), and
//           the search reads complete history through explicit bounded continuation (9dd9dc0 / df958b5).
//   G. r2-store-perf  an AI app's first Today read on a cold two-month history (the file cache empty, as after a restart),
//           while the heartbeat writes: in another process (the MCP server), on another connection in this process and
//           on the recorder's own connection, the heartbeat's longest wait is under 50 ms and no heartbeat fails (the
//           day's signature read every record in one statement: 1.6 s and busy failures at two and six months, and over
//           6 s on the recorder's own connection).
//   H. r2-store-perf  the day and action reads in short statements return exactly what one statement did: a day paged
//           through its cursors (ties in time across statements), rows added since it was read, rows removed behind its
//           back, action pages ascending and descending, of all apps, one app and an app seldom used, over a day and the
//           whole history, and all of it again without the time index and once another connection builds it.
// Thresholds are thread-CPU ratios or bounds, so a loaded machine does not change the verdict.
import Foundation
import SQLite3
@testable import MemoryCore
import MemoryUI

func fail(_ message: String) -> Never { fflush(stdout); FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
/// STORE_PERF_KEEP_GOING=1 reports every failed expectation instead of stopping at the first (to see each section
/// fail against an older tree); the exit status is 1 either way.
let keepGoing = ProcessInfo.processInfo.environment["STORE_PERF_KEEP_GOING"] == "1"
var failures = 0
func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
    guard !condition else { return }
    if !keepGoing { fail(message()) }
    failures += 1; print("FAIL: \(message())"); fflush(stdout)
}
var failuresAtLastPass = 0
func pass(_ message: String) {
    defer { failuresAtLastPass = failures }
    if failures > failuresAtLastPass { print("(no PASS: \(message))"); return }
    print("PASS: \(message)"); fflush(stdout)
}
func cpuNow() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
func wallNow() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
/// Thread CPU of `body` in ms, the best of `runs` (load moves wall time, hardly thread CPU).
func cpuMs(_ runs: Int = 3, _ body: () throws -> Void) rethrows -> Double {
    var best = Double.infinity
    for _ in 0..<runs { let c = cpuNow(); try body(); best = min(best, Double(cpuNow() - c) / 1e6) }
    return best
}
let SQLITE_TRANSIENT_ = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The functions as they were before test 5 (a formatter made per call), the reference for A.
enum Old {
    static func timestamp(_ text: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions.insert(.withFractionalSeconds)
        return f.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    static func isoPrecise(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: date)
    }
}
func same(_ a: Date?, _ b: Date?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (x?, y?): return x.timeIntervalSinceReferenceDate.bitPattern == y.timeIntervalSinceReferenceDate.bitPattern
    default: return false
    }
}

// MARK: Synthetic stores
let apps: [(String, String)] = [("Notes", "com.apple.Notes"), ("TextEdit", "com.apple.TextEdit"), ("Terminal", "com.apple.Terminal"),
                                ("Mail", "com.apple.mail"), ("Preview", "com.apple.Preview"), ("Calendar", "com.apple.iCal")]
func evidence(_ id: String, at: Date, _ seq: Int) -> Evidence {
    let app = apps[(seq / 40) % apps.count]
    return Evidence(id: id, at: iso(at), kind: seq % 3 == 0 ? "window.changed" : "mouse.click", app: app.0, bundle: app.1,
                    title: "Synthetic document \((seq / 40) % 97) - \(app.0)")
}
final class Raw {
    var db: OpaquePointer?
    init(_ home: URL) {
        guard sqlite3_open(home.appendingPathComponent("memory.sqlite").path, &db) == SQLITE_OK else { fail("raw open") }
        sqlite3_busy_timeout(db, 1500)
    }
    deinit { sqlite3_close(db) }
    @discardableResult func exec(_ sql: String, _ values: [String] = []) -> Int32 {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return sqlite3_errcode(db) }
        defer { sqlite3_finalize(st) }
        for (i, v) in values.enumerated() { sqlite3_bind_text(st, Int32(i + 1), v, -1, SQLITE_TRANSIENT_) }
        var rc = sqlite3_step(st)
        while rc == SQLITE_ROW { rc = sqlite3_step(st) }
        return rc == SQLITE_DONE ? SQLITE_OK : rc
    }
    func rows(_ sql: String, _ values: [String] = []) -> [[String]] {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { fail("raw prepare \(sql): \(String(cString: sqlite3_errmsg(db)))") }
        defer { sqlite3_finalize(st) }
        for (i, v) in values.enumerated() { sqlite3_bind_text(st, Int32(i + 1), v, -1, SQLITE_TRANSIENT_) }
        var out = [[String]]()
        while sqlite3_step(st) == SQLITE_ROW {
            out.append((0..<sqlite3_column_count(st)).map { sqlite3_column_text(st, $0).map { String(cString: $0) } ?? "" })
        }
        return out
    }
    /// A record (and its summary when `summarized`) exactly as ingest and writePending would store them.
    func insert(_ e: Evidence, summarized: Bool, now: Date) throws {
        let body = try json(e)
        guard exec("INSERT INTO records VALUES(?,?,?)", [e.id, body, fingerprint(body)]) == SQLITE_OK else { fail("raw insert: \(String(cString: sqlite3_errmsg(db)))") }
        if summarized {
            let item = IntentWriter.write(e, now: now)
            guard exec("INSERT OR REPLACE INTO summaries VALUES(?,?,?)", [item.id, try json(item), fingerprint(body)]) == SQLITE_OK else { fail("raw summary insert") }
        }
    }
}
/// A new store with `today` records spread over the last 10 hours, `yesterday` records a minute apart from 26 hours
/// ago, and `past` records 30 s apart from four days ago back, all summarized. Built with raw inserts (what
/// writePending would write), so building is fast on any build.
func makeStore(_ home: URL, today: Int, yesterday: Int = 0, past: Int, now: Date) throws {
    try? FileManager.default.removeItem(at: home)
    _ = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    let raw = Raw(home)
    raw.exec("BEGIN")
    for i in 0..<today { try raw.insert(evidence("native-today-\(i)", at: now.addingTimeInterval(-36_000 + 36_000 * Double(i) / Double(max(today, 1)) - 60), i), summarized: true, now: now) }
    for i in 0..<yesterday { try raw.insert(evidence("native-yesterday-\(i)", at: yesterdayStart(now).addingTimeInterval(Double(i) * 60), i), summarized: true, now: now) }
    for i in 0..<past { try raw.insert(evidence("native-past-\(i)", at: now.addingTimeInterval(-86_400 * 4 - Double(i) * 30), i), summarized: true, now: now) }
    raw.exec("COMMIT")
}
func yesterdayStart(_ now: Date) -> Date { now.addingTimeInterval(-26 * 3600) }
func pendingCount(_ raw: Raw) -> Int {
    Int(raw.rows("SELECT count(*) FROM records r LEFT JOIN summaries s ON r.id=s.id AND r.revision=s.revision WHERE s.id IS NULL")[0][0]) ?? -1
}
/// Writes summaries until a pass writes fewer than 100 (SummaryWorker's loop).
func drain(_ store: MemoryStore, now: Date = Date()) throws -> Int {
    var total = 0
    while true { let n = try store.writePending(now: now); total += n; if n < 100 { return total } }
}

@main struct StorePerfChecks {
    static func main() throws {
        // F's other process: an AI app's search of the same history (what its MCP server runs), then its answer.
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "search-child" {
            let result = try completeMissingSearch(MemoryStore(home: URL(fileURLWithPath: CommandLine.arguments[2])),word:CommandLine.arguments[3])
            print("items=\(result.items.count) next=\(result.next == nil ? "none" : "some") partial=\(result.partial)"); exit(0)
        }
        // G's other process: an AI app's first read of a day (macmem://days/today.json), then its answer.
        if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "day-child" {
            let day = try MemoryStore(home: URL(fileURLWithPath: CommandLine.arguments[2])).dayLayers(day: CommandLine.arguments[3], timezone: CommandLine.arguments[4], limit: 200)
            print("actions=\(day.summary.actionCount) revision=\(day.summary.inputRevision)"); exit(0)
        }
        // Complete bounded search now follows every page in both writer and read-only
        // subprocess lanes. Keep a finite aggregate watchdog; latency assertions below
        // still require each recorder heartbeat under 50ms and exact full coverage.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1800) { FileHandle.standardError.write(Data("FAIL: store-perf-checks watchdog expired after 1800s\n".utf8)); exit(2) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("store-perf-" + UUID().uuidString, isDirectory: true)
        guard !root.path.hasPrefix("/private/tmp/daydream-"), !root.path.hasPrefix("/tmp/daydream-") else { fail("TMPDIR must be a private scratch folder") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try timestamps()
        // A fixed clock, 23:00 yesterday: "today" (the ten hours before it), "yesterday" and the older days never
        // straddle midnight, whenever the check runs. Every store call below gets this `now`.
        let now = Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: Date().addingTimeInterval(-86_400))!
        let small = root.appendingPathComponent("small"), large = root.appendingPathComponent("large")
        try makeStore(small, today: 3000, yesterday: 60, past: 0, now: now)
        try makeStore(large, today: 3000, yesterday: 60, past: 27_000, now: now)
        pass("synthetic stores: 3,000 records today and 60 yesterday; the large one 27,000 more before")
        try todayRebuild(small, now: now)
        try indexes(root, small: small, large: large, now: now)
        try summaries(root, small: small, large: large, now: now)
        try openWithoutWriteLock(root, now: now)
        try searchLetsHeartbeatIn(root, now: now)
        try coldTodayRead(root, now: now)
        try shortReadsSameAnswers(root, now: now)
        if failures > 0 { fail("\(failures) expectations failed") }
        print("store-perf-checks passed")
    }

    // MARK: A. G17
    static func timestamps() throws {
        var rng = SystemRandomNumberGenerator()
        // Dates across 1621...2381, with sub-millisecond parts that isoPrecise must round the formatter's way.
        let dates = (0..<3000).map { _ in Date(timeIntervalSince1970: Double.random(in: -11_000_000_000...13_000_000_000, using: &rng)) }
            + [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: -0.0005), Date(timeIntervalSince1970: 0.9995), Date(timeIntervalSince1970: 951_782_400),
               Date(timeIntervalSinceReferenceDate: 0), Date(timeIntervalSince1970: 4_102_444_799.9999), Date()]
        for d in dates {
            expect(iso(d) == Old.iso(d), "iso(\(d.timeIntervalSince1970)): \(iso(d)) vs \(Old.iso(d))")
            expect(isoPrecise(d) == Old.isoPrecise(d), "isoPrecise(\(d.timeIntervalSince1970)): \(isoPrecise(d)) vs \(Old.isoPrecise(d))")
        }
        var texts = dates.flatMap { [Old.iso($0), Old.isoPrecise($0)] }
        texts += ["2024-02-29T12:00:00Z", "2023-02-29T12:00:00Z", "2100-02-29T00:00:00Z", "2000-02-29T00:00:00Z", "1600-01-01T00:00:00Z",
                  "1600-03-01T00:00:00.001Z", "1599-12-31T23:59:59Z", "1582-10-10T00:00:00Z", "0001-01-01T00:00:00Z", "0000-01-01T00:00:00Z",
                  "9999-12-31T23:59:59Z", "9999-12-31T23:59:59.999Z", "1970-01-01T00:00:00Z", "1969-12-31T23:59:59.999Z",
                  "2026-09-26T24:00:00Z", "2026-09-26T23:60:00Z", "2026-09-26T23:59:60Z", "2026-13-01T00:00:00Z", "2026-00-10T00:00:00Z",
                  "2026-01-00T00:00:00Z", "2026-01-32T00:00:00Z", "2026-04-31T00:00:00Z", "2026-09-26t12:00:00Z", "2026-09-26T12:00:00z",
                  "2026-09-26 12:00:00Z", "2026-09-26T12:00:00", "2026-09-26T12:00:00+00:00", "2026-09-26T12:00:00+05:30",
                  "2026-09-26T12:00:00-08:00", "2026-09-26T12:00:00.1Z", "2026-09-26T12:00:00.12Z", "2026-09-26T12:00:00.1234Z",
                  "2026-09-26T12:00:00.123456Z", "2026-09-26T12:00:00.123456789Z", "2026-09-26T12:00:00,123Z", "2026-09-26T12:00:00.12aZ",
                  "2026-09-26T12:00:00:123Z", "+2026-09-26T12:00:00Z", "-2026-09-26T12:00:00Z", "", "Z", "garbage", "2026-9-26T12:00:00Z",
                  "2026-09-26T1:00:00Z", " 2026-09-26T12:00:00Z", "2026-09-26T12:00:00Z ", "2026-09-26T12:00:00.000Z", "2026-09-26T12:00:00.999Z",
                  "20260926T120000Z", "2026-09-26", "2026-09-26T12:00Z", "2026-W39-6T12:00:00Z", "2026-269T12:00:00Z",
                  "2026-09-26T12:00:00.123+01:00", "2026-09-26T12:00:00.123-00:00", "2026-09-26T12:00:00Z\u{0}", "2026-09-26T12:00:0é",
                  "٢٠٢٦-٠٩-٢٦T12:00:00Z", "２０２６-09-26T12:00:00Z", "2026/09/26T12:00:00Z", "2026-09-26T12:00:00Y", "2026-09-26T12:00:00.12ZZ"]
        // One byte changed anywhere in either form.
        let printable = Array(" +-.:0123456789TZtz,/aé".unicodeScalars)
        for _ in 0..<2000 {
            let base = Bool.random(using: &rng) ? Old.iso(dates.randomElement(using: &rng)!) : Old.isoPrecise(dates.randomElement(using: &rng)!)
            var scalars = Array(base.unicodeScalars)
            scalars[Int.random(in: 0..<scalars.count, using: &rng)] = printable.randomElement(using: &rng)!
            texts.append(String(String.UnicodeScalarView(scalars)))
        }
        var expected = [Date?]()
        for text in texts {
            let old = Old.timestamp(text)
            expect(same(timestamp(text), old), "timestamp(\"\(text)\"): \(String(describing: timestamp(text))) vs \(String(describing: old))")
            expected.append(old)
        }
        pass("timestamp(), iso() and isoPrecise() give the old results: \(dates.count) dates both ways, \(texts.count - 2 * dates.count) edge and one-byte-changed strings")
        // Many threads at once (the Today build, the summary worker, readers and the main thread share them).
        let texts2 = texts, expected2 = expected, dates2 = dates
        let isoExpected = dates.map(Old.iso), preciseExpected = dates.map(Old.isoPrecise)
        let failures = NSLock(); var bad = 0
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            var wrong = 0
            for round in 0..<3 {
                for i in stride(from: (worker + round) % 8, to: texts2.count, by: 8) where !same(timestamp(texts2[i]), expected2[i]) { wrong += 1 }
                for i in stride(from: worker, to: dates2.count, by: 8) {
                    if iso(dates2[i]) != isoExpected[i] || isoPrecise(dates2[i]) != preciseExpected[i] { wrong += 1 }
                }
            }
            failures.lock(); bad += wrong; failures.unlock()
        }
        expect(bad == 0, "\(bad) wrong results with 8 threads at once")
        pass("8 threads at once: every timestamp(), iso() and isoPrecise() result still matches")
        // Cost: DayDream's own forms, as the Today build and the day's layers read them.
        let own = Array(texts.prefix(2 * dates.count).prefix(2000))
        let newRead = cpuMs { for t in own { _ = timestamp(t) } }, oldRead = cpuMs(1) { for t in own { _ = Old.timestamp(t) } }
        let someDates = Array(dates.prefix(1000))
        let newWrite = cpuMs { for d in someDates { _ = iso(d) } }, oldWrite = cpuMs(1) { for d in someDates { _ = Old.iso(d) } }
        print(String(format: "  timestamp() x%d: %.1f ms (old %.1f ms); iso() x%d: %.1f ms (old %.1f ms)", own.count, newRead, oldRead, someDates.count, newWrite, oldWrite))
        expect(newRead * 10 <= oldRead, String(format: "timestamp() costs %.1f ms for %d reads, the old way %.1f ms: not 10x cheaper", newRead, own.count, oldRead))
        expect(newWrite * 2 <= oldWrite, String(format: "iso() costs %.1f ms for %d writes, the old way %.1f ms: not 2x cheaper", newWrite, someDates.count, oldWrite))
        pass("timestamp() is at least 10x and iso() at least 2x cheaper than a formatter per call")
    }

    // MARK: B. G16
    static func todayRebuild(_ home: URL, now: Date) throws {
        let zone = TimeZone.current.identifier
        let day = try MemoryStore(home: home).dayLayers(day: try DayScope.key(now, timezone: zone), timezone: zone, after: nil, limit: 200, now: now)
        expect(day.summary.actionCount >= 2900, "today's layers hold \(day.summary.actionCount) actions, not about 3000")
        let summaries = SummaryAvailability(provider: .local, busy: false)
        let ms = cpuMs {
            _ = DayDigest.make(day: day, calendar: .current)
            _ = TodaySnapshot.make(day: day, summaries: summaries, calendar: .current, now: now)
        }
        print(String(format: "  TodaySnapshot + DayDigest for %d actions, %d moments: %.1f ms CPU", day.summary.actionCount, day.activities.count, ms))
        expect(ms < 150, String(format: "Today's rebuild on the main actor took %.0f ms CPU for %d actions (limit 150 ms)", ms, day.summary.actionCount))
        pass(String(format: "Today's rebuild on the main actor: %.0f ms CPU for %d actions (under 150 ms)", ms, day.summary.actionCount))
    }

    // MARK: C. G47
    static let indexSQL = [
        "records_at": "CREATE INDEX records_at ON records(json_extract(body,'$.at'))",
        "records_at_julian": "CREATE INDEX records_at_julian ON records(julianday(json_extract(body,'$.at')))",
        "summaries_generated_at": "CREATE INDEX summaries_generated_at ON summaries(json_extract(body,'$.generatedAt'))",
        "records_plain_typed": "CREATE INDEX records_plain_typed ON records(id) WHERE json_extract(body,'$.kind')='keyboard.text_input' AND coalesce(json_extract(body,'$.text'),'')<>'' AND json_extract(body,'$.typed') IS NULL",
        // The level tables' two indexes are checked on their own (MemoryStore.levelIndexes, below), not here.
    ]
    static func indexes(_ root: URL, small: URL, large: URL, now: Date) throws {
        for home in [small, large] { _ = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false) }
        let raw = Raw(large)
        var made = Dictionary(uniqueKeysWithValues: raw.rows("SELECT name,sql FROM sqlite_master WHERE type='index' AND sql IS NOT NULL").map { ($0[0], $0[1]) })
        // The level tables' two indexes (LevelNotes.levelIndexes) are made with those tables, not as launch work.
        let level = made.filter { MemoryStore.ownLevelIndex(name: $0.key, sql: $0.value) }
        expect(level.count == MemoryStore.levelIndexes.count, "the level tables' own indexes: \(level)")
        for name in level.keys { made[name] = nil }
        expect(made == indexSQL, "the store's own indexes: \(made)")
        expect(raw.rows("PRAGMA journal_mode")[0][0] == "delete", "the journal is no longer the rollback journal: \(raw.rows("PRAGMA journal_mode"))")
        pass("a writable open makes exactly the four time indexes and the two level-note indexes; the rollback journal stays")

        // Time reads cost the same with 10x the history: the newest records, ten minutes, and a 60-action day
        // (yesterday) read the same few records from either store, so only a read of the whole table can differ.
        let zone = TimeZone.current.identifier, yesterdayKey = try DayScope.key(yesterdayStart(now).addingTimeInterval(1800), timezone: zone)
        let windowStart = yesterdayStart(now).addingTimeInterval(20 * 60), windowEnd = windowStart.addingTimeInterval(10 * 60)
        var cost: [String: [Double]] = [:]
        for home in [small, large] {
            let store = try MemoryStore(home: home)
            let window = try store.activityDay(start: windowStart, end: windowEnd, now: now).count
            expect(window == 10, "ten minutes of yesterday hold \(window) records, not 10")
            cost["timeline(limit:5)", default: []].append(try cpuMs { _ = try store.timeline(now: now, limit: 5) })
            cost["activityDay(10 minutes)", default: []].append(try cpuMs { _ = try store.activityDay(start: windowStart, end: windowEnd, now: now) })
            cost["dayLayers(a 60-action day)", default: []].append(try cpuMs { _ = try MemoryStore(home: home).dayLayers(day: yesterdayKey, timezone: zone, after: nil, limit: 200, now: now) })
        }
        for (name, v) in cost.sorted(by: { $0.key < $1.key }) {
            print(String(format: "  %@: %.1f ms at 3,000 records, %.1f ms at 30,000", name, v[0], v[1]))
            expect(v[1] <= 2 * v[0] + 2, String(format: "%@ grows with history: %.1f ms at 3,000 records, %.1f ms at 30,000", name, v[0], v[1]))
        }
        pass("the newest records, ten minutes of actions and a day's layers cost the same with 10x the history")

        // A store that can't take an index (a record SQLite can't read as JSON) still opens; the next open tries again.
        let broken = root.appendingPathComponent("broken")
        try makeStore(broken, today: 10, past: 0, now: now)
        do {
            let r = Raw(broken)
            for name in indexSQL.keys { r.exec("DROP INDEX IF EXISTS \(name)") }
            r.exec("INSERT INTO records VALUES('broken-1','{not json','x')")
        }
        _ = try MemoryStore(home: broken, writable: true, automaticallySyncSearch: false)
        expect(Raw(broken).rows("SELECT count(*) FROM sqlite_master WHERE type='index' AND name='records_at'")[0][0] == "0", "an index over an unreadable record")
        pass("a store holding a record SQLite can't read as JSON still opens without the indexes")

        // A backup exports from an indexed store, and the new copy (indexed too) passes the restore inspection.
        let source = root.appendingPathComponent("backup-source"), copy = root.appendingPathComponent("backup-copy")
        try makeStore(source, today: 50, past: 0, now: now)
        do { let r = Raw(source); for sql in indexSQL.values { r.exec(sql.replacingOccurrences(of: "CREATE INDEX ", with: "CREATE INDEX IF NOT EXISTS ")) } }
        let from = try MemoryStore(home: source, writable: true, automaticallySyncSearch: false)
        let to = try MemoryStore(home: copy, writable: true, automaticallySyncSearch: false)
        do {
            let audit = try from.exportCanonicalSnapshot(to: to, now: now)
            expect(audit.counts["records"] == 50, "backup exported \(audit.counts)")
            do { _ = try to.inspectCanonicalSnapshot(now: now) } catch { expect(false, "restore inspection of an indexed backup: \(error)") }
        } catch { expect(false, "backup export of an indexed store: \(error)") }
        pass("a backup of an indexed store exports all 50 records, and the copy passes the restore inspection")
    }

    // MARK: D. G6
    static func summaries(_ root: URL, small: URL, large: URL, now: Date) throws {
        // Cost after capture: 20 new records, with 3,000 or 30,000 already summarized (the first pass of a new
        // connection checks the whole table once; the timed one is the next).
        var cost = [Double]()
        for home in [small, large] {
            let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
            _ = try drain(store, now: now)
            var ms = Double.infinity
            for round in 0..<3 {
                for i in 0..<20 { expect(try store.ingest(evidence("native-new-\(round)-\(i)", at: now.addingTimeInterval(-5), i), now: now), "ingest refused") }
                let c = cpuNow(); let n = try store.writePending(now: now); ms = min(ms, Double(cpuNow() - c) / 1e6)
                expect(n == 20, "writePending wrote \(n) of 20 new summaries")
            }
            expect(pendingCount(Raw(home)) == 0, "records left pending")
            cost.append(ms)
        }
        print(String(format: "  writePending after 20 new records: %.1f ms at 3,000 records, %.1f ms at 30,000", cost[0], cost[1]))
        expect(cost[1] <= 2 * cost[0] + 2, String(format: "writePending grows with history: %.1f ms at 3,000 records, %.1f ms at 30,000", cost[0], cost[1]))
        pass("writePending costs what is new: 20 summaries cost the same with 10x the history")

        // Same summaries as a whole-table pass, whatever made a record pending.
        let home = root.appendingPathComponent("queue")
        try makeStore(home, today: 400, past: 400, now: now)
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        let raw = Raw(home)
        expect(try drain(store, now: now) == 0 && pendingCount(raw) == 0, "a summarized store had work")
        // Own inserts, and a record changed in place (a new revision needs a new summary).
        for i in 0..<250 { expect(try store.ingest(evidence("native-own-\(i)", at: now.addingTimeInterval(-30), i), now: now), "ingest refused") }
        var changed = evidence("native-today-7", at: now.addingTimeInterval(-3000), 7); changed.title = "Changed in place"
        let changedBody = try json(changed)
        try store.exec("UPDATE records SET body=?,revision=? WHERE id=?", [changedBody, fingerprint(changedBody), changed.id])
        expect(try drain(store, now: now) == 251 && pendingCount(raw) == 0, "own inserts and an update: \(pendingCount(raw)) left pending")
        expect(raw.rows("SELECT revision FROM summaries WHERE id='native-today-7'")[0][0] == fingerprint(changedBody), "the changed record kept its old summary")
        // Another connection's record and another connection's summary removal.
        try raw.insert(evidence("native-other-1", at: now.addingTimeInterval(-40), 1), summarized: false, now: now)
        raw.exec("DELETE FROM summaries WHERE id IN ('native-past-3','native-today-9')")
        expect(try drain(store, now: now) == 3 && pendingCount(raw) == 0, "another connection's changes: \(pendingCount(raw)) left pending")
        // This connection's own summary removal.
        try store.exec("DELETE FROM summaries WHERE id='native-past-5'")
        expect(try drain(store, now: now) == 1 && pendingCount(raw) == 0, "own summary removal left it pending")
        // An app hidden, then shown again: what was hidden is summarized once it shows.
        var hidden = try store.policy(); hidden.blockedApps = ["com.apple.Notes"]
        try store.updatePolicy(hidden, now: now)
        let visible = try drain(store, now: now), stillHidden = pendingCount(raw)
        expect(stillHidden > 0 && visible > 0, "hiding Notes: \(visible) written, \(stillHidden) hidden")
        var shown = try store.policy(); shown.blockedApps = []
        try store.updatePolicy(shown, now: now)
        _ = try drain(store, now: now)
        expect(pendingCount(raw) == 0, "records hidden, then shown again: \(pendingCount(raw)) left pending")
        // A record dated an hour ahead (a clock moved back) is summarized once its time comes.
        try raw.insert(evidence("native-ahead-1", at: now.addingTimeInterval(3600), 2), summarized: false, now: now)
        try store.ingest(evidence("native-own-late", at: now.addingTimeInterval(-10), 3), now: now)
        _ = try drain(store, now: now)
        expect(pendingCount(raw) == 1, "the record dated ahead was summarized early, or others were left")
        _ = try drain(store, now: now.addingTimeInterval(7200))
        expect(pendingCount(raw) == 0, "the record dated ahead stayed pending after its time came")
        pass("writePending writes the same summaries as a whole-table pass: own and other connections' records, a changed record, removed summaries, an app hidden and shown, a record dated ahead")

        // Retention: exactly the records the old full pass removed (the same Swift check decides), whatever the time's form.
        let kept = root.appendingPathComponent("retention")
        try makeStore(kept, today: 0, past: 0, now: now)
        let r = Raw(kept)
        let cutoff = now.addingTimeInterval(-7 * 86_400)
        let times: [String] = [iso(cutoff.addingTimeInterval(-1)), iso(cutoff.addingTimeInterval(1)), isoPrecise(cutoff.addingTimeInterval(-0.5)),
                               isoPrecise(cutoff.addingTimeInterval(0.5)), iso(cutoff), iso(cutoff.addingTimeInterval(-30 * 86_400)),
                               iso(cutoff.addingTimeInterval(86_400 * 2)), "garbage", "",
                               ISO8601DateFormatter.string(from: cutoff.addingTimeInterval(-3600), timeZone: TimeZone(secondsFromGMT: 13 * 3600)!, formatOptions: [.withInternetDateTime]),
                               ISO8601DateFormatter.string(from: cutoff.addingTimeInterval(3600), timeZone: TimeZone(secondsFromGMT: -11 * 3600)!, formatOptions: [.withInternetDateTime]),
                               "2026-09-26T12:00:00.123456Z"]
        for (i, at) in times.enumerated() {
            var e = evidence("native-kept-\(i)", at: now, i); e.at = at
            let body = try json(e)
            r.exec("INSERT INTO records VALUES(?,?,?)", [e.id, body, fingerprint(body)])
        }
        let expectedGone = Set(times.enumerated().filter { timestamp($0.element).map { $0 < cutoff } ?? false }.map { "native-kept-\($0.offset)" })
        let keptStore = try MemoryStore(home: kept, writable: true, automaticallySyncSearch: false)
        var week = try keptStore.policy(); week.retention = .days(7)
        try keptStore.exec("UPDATE metadata SET body=? WHERE id='policy'", [json(week)])
        _ = try keptStore.writePending(now: now)
        let left = Set(r.rows("SELECT id FROM records").map { $0[0] }), tombstones = Set(r.rows("SELECT id FROM tombstones").map { $0[0] })
        expect(expectedGone.count >= 4, "the retention case removes too little to mean anything")
        expect(left == Set(times.indices.map { "native-kept-\($0)" }).subtracting(expectedGone) && tombstones == expectedGone,
               "retention removed \(Set(times.indices.map { "native-kept-\($0)" }).subtracting(left).sorted()), expected \(expectedGone.sorted())")
        pass("retention removes exactly the records older than the cutoff (\(expectedGone.count) of \(times.count), any time form), with tombstones")

        // The whole-table check of a new connection lets the heartbeat in: its longest wait is a short part of the run.
        let fresh = try MemoryStore(home: large, writable: true, automaticallySyncSearch: false)
        try fresh.setCaptureState("recording", reason: CaptureSession.recordingReason)
        let started = DispatchSemaphore(value: 0), done = DispatchGroup()
        var runWall = 0.0
        DispatchQueue.global(qos: .utility).async(group: done) {
            started.signal(); let t = wallNow(); _ = try? fresh.writePending(now: now); runWall = Double(wallNow() - t) / 1e6
        }
        started.wait()
        var waits = [Double]()
        while done.wait(timeout: .now()) != .success {
            let t = wallNow(); try fresh.setCaptureState("recording", reason: CaptureSession.recordingReason); waits.append(Double(wallNow() - t) / 1e6)
            usleep(300)
        }
        let longest = waits.max() ?? 0
        print(String(format: "  first writePending of a new connection at 30,000 records: %.0f ms wall; %d heartbeats, longest wait %.1f ms", runWall, waits.count, longest))
        expect(longest < 0.5 * runWall, String(format: "a heartbeat waited %.0f ms of a %.0f ms whole-table check", longest, runWall))
        pass("a new connection's whole-table check runs in short transactions: the heartbeat's longest wait is under half the run")
    }

    // MARK: F. G27 x G7
    /// The heartbeat (setCaptureState on the recorder's connection, as the main thread writes it) every half
    /// millisecond while `work` runs on another thread: its longest wait, how many, and the work's wall time.
    /// 9dd9dc0 / df958b5: explicit bounded pages still prove full missing-word coverage.
    static func completeMissingSearch(_ store:MemoryStore,word:String) throws -> MemorySearchResult {
        var query=MemorySearchQuery(word,limit:50)
        for _ in 0..<256 {
            let page=try store.searchResult(query)
            guard page.items.isEmpty && page.partial == (page.next != nil) else {throw MemError.invalid("Missing-word search returned incoherent coverage")}
            guard let next=page.next else {return page}
            query.after=next
        }
        throw MemError.invalid("Missing-word continuation did not finish within the fixture bound")
    }
    static func heartbeat(_ store: MemoryStore, _ work: @escaping () -> Void) throws -> (longest: Double, count: Int, workMs: Double) {
        let started = DispatchSemaphore(value: 0), done = DispatchGroup()
        var workMs = 0.0
        DispatchQueue.global(qos: .userInitiated).async(group: done) { started.signal(); let t = wallNow(); work(); workMs = Double(wallNow() - t) / 1e6 }
        started.wait()
        var waits = [Double]()
        while done.wait(timeout: .now()) != .success {
            let t = wallNow(); try store.setCaptureState("recording", reason: CaptureSession.recordingReason); waits.append(Double(wallNow() - t) / 1e6)
            usleep(500)
        }
        return (waits.max() ?? 0, waits.count, workMs)
    }
    static func searchLetsHeartbeatIn(_ root: URL, now: Date) throws {
        let home = root.appendingPathComponent("search")
        try? FileManager.default.removeItem(at: home)
        _ = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        do {
            // A month of history at DayDream's usual pace (about 3,000 a day), newest first.
            let raw = Raw(home)
            raw.exec("BEGIN")
            for i in 0..<90_000 {
                let e = evidence("native-search-\(i)", at: now.addingTimeInterval(-Double(i) * 29 - 1), i)
                let body = try json(e)
                guard raw.exec("INSERT INTO records VALUES(?,?,?)", [e.id, body, fingerprint(body)]) == SQLITE_OK else { fail("raw insert") }
            }
            raw.exec("COMMIT")
        }
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        try store.setCaptureState("recording", reason: CaptureSession.recordingReason)
        let word = "zqxjv"
        _ = try store.searchResult(MemorySearchQuery(word, limit: 50))
        var answer: MemorySearchResult?, failed: Error?
        // 9dd9dc0 / df958b5: typo matching has a bounded scan budget. Follow its
        // explicit continuation to prove completeness without monopolizing the recorder.
        let own = try heartbeat(store) {do {answer=try completeMissingSearch(store,word:word)} catch {failed=error}}
        print(String(format: "  search for a missing word on the recorder's connection: %.0f ms; %d heartbeats, longest wait %.1f ms", own.workMs, own.count, own.longest))
        expect(failed == nil && answer?.items.isEmpty == true && answer?.next == nil && answer?.partial == false,
               "the missing-word search did not finish coherent bounded continuation: \(String(describing: failed)) \(answer?.items.count ?? -1) \(answer?.next ?? "no continuation")")
        expect(own.longest < 50, String(format: "the heartbeat waited %.0f ms for a search on the recorder's connection (%.0f ms search)", own.longest, own.workMs))
        pass("a search for a missing word on the recorder's own connection completes all 90,000 records through bounded continuation, and the heartbeat waits under 50 ms")
        let reader = try heartbeat(store) { _ = try? MemoryStore(home: home).searchResult(MemorySearchQuery(word, limit: 50)) }
        print(String(format: "  …on another connection in this process: %.0f ms; longest wait %.1f ms", reader.workMs, reader.longest))
        expect(reader.longest < 50, String(format: "the heartbeat waited %.0f ms for a search on another connection (%.0f ms search)", reader.longest, reader.workMs))
        pass("…on another connection in this process, the heartbeat waits under 50 ms")
        var said = ""
        let other = try heartbeat(store) {
            let child = Process(), out = Pipe()
            child.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["search-child", home.path, word]
            child.standardOutput = out
            do { try child.run() } catch { said = "\(error)"; return }
            said = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            child.waitUntilExit()
        }
        print(String(format: "  …in another process (an AI app's search): %.0f ms; longest wait %.1f ms; it answered %@", other.workMs, other.longest, said))
        expect(said == "items=0 next=none partial=false", "the other process's complete bounded missing-word search answered \(said)")
        expect(other.longest < 50, String(format: "the heartbeat waited %.0f ms for another process's search", other.longest))
        pass("…and in another process (an AI app's search), the heartbeat waits under 50 ms and the search completes all bounded continuations")
    }

    // MARK: G. r2-store-perf: a cold Today read
    /// A copy of `source`'s history whose file cache is empty (an APFS clone is a new file to the cache), as the first
    /// read after a restart finds it. A plain copy where the volume can't clone (warm: the check is then weaker).
    static func coldCopy(_ source: URL, _ name: String, in root: URL) throws -> URL {
        let home = root.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: home)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let from = source.appendingPathComponent("memory.sqlite").path, to = home.appendingPathComponent("memory.sqlite").path
        if clonefile(from, to, 0) != 0 {
            print("  (the volume can't clone files: a plain copy, so its file cache may be warm)")
            try FileManager.default.copyItem(atPath: from, toPath: to)
        }
        return home
    }
    /// The heartbeat every half millisecond while `work` runs, as `heartbeat` does, counting heartbeats that failed
    /// (busy) instead of stopping.
    static func heartbeatCounting(_ store: MemoryStore, _ work: @escaping () -> Void) -> (longest: Double, count: Int, failed: Int, workMs: Double) {
        let started = DispatchSemaphore(value: 0), done = DispatchGroup()
        var workMs = 0.0
        DispatchQueue.global(qos: .userInitiated).async(group: done) { started.signal(); let t = wallNow(); work(); workMs = Double(wallNow() - t) / 1e6 }
        started.wait()
        var waits = [Double](), failed = 0
        while done.wait(timeout: .now()) != .success {
            let t = wallNow()
            do { try store.setCaptureState("recording", reason: CaptureSession.recordingReason) } catch { failed += 1 }
            waits.append(Double(wallNow() - t) / 1e6)
            usleep(500)
        }
        return (waits.max() ?? 0, waits.count, failed, workMs)
    }
    static func coldTodayRead(_ root: URL, now: Date) throws {
        // Two months at DayDream's pace, 3,000 moments a day, each with its summary written beside it as the app writes
        // them (so a record's pages are spread over the file as in a real history). Today: the ten hours before `now`.
        let source = root.appendingPathComponent("cold-source")
        try? FileManager.default.removeItem(at: source)
        _ = try MemoryStore(home: source, writable: true, automaticallySyncSearch: false)
        let zone = TimeZone.current.identifier, day = try DayScope.key(now, timezone: zone)
        do {
            let raw = Raw(source), filler = String(repeating: "Worked on a synthetic document in a synthetic app. ", count: 13)
            let calendar = Calendar.current
            raw.exec("BEGIN")
            for d in stride(from: 59, through: 0, by: -1) {
                let first = d == 0 ? now.addingTimeInterval(-36_060) : calendar.date(bySettingHour: 8, minute: 0, second: 0, of: now.addingTimeInterval(-86_400 * Double(d)))!
                for i in 0..<3000 {
                    let app = apps[(i / 40) % apps.count], id = "native-cold-\(d)-\(i)", at = iso(first.addingTimeInterval(Double(i) * 12))
                    let body = "{\"app\":\"\(app.0)\",\"at\":\"\(at)\",\"bundle\":\"\(app.1)\",\"id\":\"\(id)\",\"kind\":\"\(i % 3 == 0 ? "window.changed" : "mouse.click")\",\"privateWindow\":false,\"secure\":false,\"synthetic\":false,\"text\":\"\",\"title\":\"Synthetic document \((i / 40) % 97) - \(app.0)\",\"url\":\"\"}"
                    let revision = fingerprint(body)
                    guard raw.exec("INSERT INTO records VALUES(?,?,?)", [id, body, revision]) == SQLITE_OK,
                          raw.exec("INSERT INTO summaries VALUES(?,?,?)", [id, "{\"id\":\"\(id)\",\"summary\":\"\(filler)\"}", revision]) == SQLITE_OK else { fail("cold store insert") }
                }
            }
            raw.exec("COMMIT")
        }
        let reference = try MemoryStore(home: source).dayLayers(day: day, timezone: zone, limit: 200)
        expect(reference.summary.actionCount == 3000, "the cold store's today has \(reference.summary.actionCount) actions, expected 3,000")
        let places = ["another process (an AI app's first Today read)", "another connection in this process", "the recorder's own connection"]
        for (n, place) in places.enumerated() {
            let home = try coldCopy(source, "cold-\(n)", in: root)
            let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
            try store.setCaptureState("recording", reason: CaptureSession.recordingReason)
            var said = ""
            let run = heartbeatCounting(store) {
                switch n {
                case 0:
                    let child = Process(), out = Pipe()
                    child.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
                    child.arguments = ["day-child", home.path, day, zone]
                    child.standardOutput = out
                    do { try child.run() } catch { said = "\(error)"; return }
                    said = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    child.waitUntilExit()
                default:
                    // The day read first in this process: nothing of it is kept from before.
                    DayAssemblyCache.shared.removeAll()
                    do {
                        let read = try (n == 1 ? MemoryStore(home: home) : store).dayLayers(day: day, timezone: zone, limit: 200)
                        said = "actions=\(read.summary.actionCount) revision=\(read.summary.inputRevision)"
                    } catch { said = "\(error)" }
                }
            }
            print(String(format: "  cold Today read by %@: %.0f ms; %d heartbeats, longest wait %.1f ms, %d failed", place, run.workMs, run.count, run.longest, run.failed))
            expect(said == "actions=3000 revision=\(reference.summary.inputRevision)", "the cold Today read by \(place) answered \(said)")
            expect(run.failed == 0, "\(run.failed) heartbeats failed while \(place) read Today on a cold history")
            expect(run.longest < 50, String(format: "the heartbeat waited %.0f ms while %@ read Today on a cold history", run.longest, place))
            pass("a cold Today read by \(place): the whole day, the heartbeat waits under 50 ms, and no heartbeat fails")
            try? FileManager.default.removeItem(at: home)
        }
        DayAssemblyCache.shared.removeAll()
        try? FileManager.default.removeItem(at: source)
    }

    // MARK: H. r2-store-perf: short statements, the same answers
    static func firstDifference(_ a: [String], _ b: [String]) -> Int { zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(a.count, b.count) }
    /// The day's ids in `actions(start:end:)` order, read in one statement straight from the file (the reference).
    static func referenceIDs(_ raw: Raw, start: Date, end: Date, app: String = "", descending: Bool = false, top: String = "9223372036854775807") -> [String] {
        let order = descending ? "DESC" : "ASC", jd = "julianday(json_extract(body,'$.at'))"
        return raw.rows("SELECT id FROM records WHERE rowid<=? AND \(jd)>=julianday(?) AND \(jd)<julianday(?) AND (?='' OR json_extract(body,'$.app')=? OR json_extract(body,'$.bundle')=?) AND id NOT IN (SELECT id FROM tombstones) ORDER BY \(jd) \(order),id \(order)",
                        [top, MemoryStore.actionBound(start), MemoryStore.actionBound(end), app, app, app]).map { $0[0] }
    }
    /// Every action of a day, paged through `dayLayers`' cursors (`limit` at a time).
    static func dayIDs(_ store: MemoryStore, day: String, zone: String, now: Date, limit: Int = 200) throws -> (ids: [String], count: Int, members: Set<String>) {
        let first = try store.dayLayers(day: day, timezone: zone, limit: limit, now: now)
        var ids = first.actions.actions.map(\.id), next = first.actions.next, pages = 0
        while let after = next, pages < 1000 {
            let page = try store.dayLayers(day: day, timezone: zone, after: after, limit: limit, now: now)
            ids += page.actions.actions.map(\.id); next = page.actions.next; pages += 1
        }
        return (ids, first.summary.actionCount, Set(first.activities.flatMap(\.actionIDs)))
    }
    /// Every action `actions` returns, following its cursors; also each page's candidate count.
    static func actionIDs(_ store: MemoryStore, start: Date?, end: Date?, app: String?, descending: Bool, now: Date, limit: Int = 100) throws -> (ids: [String], candidates: [Int]) {
        var ids = [String](), candidates = [Int](), after: String?, pages = 0
        repeat {
            let page = try store.actions(start: start, end: end, app: app, after: after, limit: limit, now: now, descending: descending)
            ids += page.actions.map(\.id); candidates.append(page.candidates); after = page.next; pages += 1
        } while after != nil && pages < 2000
        return (ids, candidates)
    }
    static func shortReadsSameAnswers(_ root: URL, now: Date) throws {
        let home = root.appendingPathComponent("same-answers")
        try? FileManager.default.removeItem(at: home)
        _ = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        let zone = TimeZone.current.identifier, day = try DayScope.key(now, timezone: zone)
        let interval = try DayScope.interval(day: day, timezone: zone)
        let raw = Raw(home)
        // Today: 1,900 moments, with runs of up to 700 at the very same time (so the short statements, 500 rows each,
        // stop inside them), times written in DayDream's two forms and others SQLite reads (an offset, more fraction
        // digits), and one whose time can't be read. The days before: 9,000 more, and an app seldom used (Preview, one
        // moment in 2,500) whose moments sit at window edges too.
        raw.exec("BEGIN")
        var n = 0
        func add(_ at: String, app: (String, String)? = nil, _ seq: Int) throws {
            var e = evidence("native-same-\(String(format: "%05d", (n * 7919) % 100_000))-\(n)", at: now, seq)
            e.at = at
            if let app { e.app = app.0; e.bundle = app.1 }
            n += 1
            try raw.insert(e, summarized: false, now: now)
        }
        let dayStart = interval.start
        for i in 0..<400 { try add(iso(dayStart.addingTimeInterval(3600 + Double(i) * 7)), i) }
        let tie = iso(dayStart.addingTimeInterval(4 * 3600))
        for i in 0..<700 { try add(tie, i) }
        for i in 0..<300 { try add(isoPrecise(dayStart.addingTimeInterval(5 * 3600 + Double(i) * 0.4)), i) }
        for i in 0..<250 { try add(isoPrecise(dayStart.addingTimeInterval(6 * 3600)), i) }
        for i in 0..<240 {
            let d = dayStart.addingTimeInterval(7 * 3600 + Double(i) * 30)
            let f = ISO8601DateFormatter(); f.timeZone = TimeZone(secondsFromGMT: 5 * 3600 + 1800)
            try add(i % 2 == 0 ? f.string(from: d) : String(isoPrecise(d).dropLast()) + "123Z", i)
        }
        try add("not a time", 1)
        for i in 0..<9000 {
            let at = iso(dayStart.addingTimeInterval(-Double(i + 1) * 60))
            try add(at, app: i % 2500 == 0 ? ("Preview", "com.apple.Preview") : ("Terminal", "com.apple.Terminal"), i)
        }
        for i in 0..<3 { try add(iso(dayStart.addingTimeInterval(-Double(2500 * i + 1) * 60)), app: ("Preview", "com.apple.Preview"), i) }
        raw.exec("COMMIT")
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        let reader = try MemoryStore(home: home)

        func sameDay(_ label: String, _ s: MemoryStore) throws {
            DayAssemblyCache.shared.removeAll()
            let expected = referenceIDs(raw, start: interval.start, end: interval.end)
            for limit in [200, 37] {
                let got = try dayIDs(s, day: day, zone: zone, now: now, limit: limit)
                expect(got.ids == expected && got.count == expected.count && got.members == Set(expected),
                       "\(label): the day paged \(limit) at a time has \(got.ids.count) actions (\(got.count) counted), expected \(expected.count); first difference at \(firstDifference(got.ids, expected))")
            }
        }
        func sameActions(_ label: String, _ s: MemoryStore) throws {
            let yesterday = interval.start.addingTimeInterval(-86_400)
            for (start, end) in [(Optional(interval.start), Optional(interval.end)), (nil, nil), (Optional(yesterday), Optional(interval.start.addingTimeInterval(4 * 3600 + 1)))] {
                for app in [nil, "Terminal", "com.apple.Preview"] as [String?] {
                    for descending in [false, true] {
                        let expected = referenceIDs(raw, start: start ?? Date(timeIntervalSince1970: -62_135_596_800), end: end ?? Date(timeIntervalSince1970: 253_402_214_400),
                                                    app: app ?? "", descending: descending)
                        let got = try actionIDs(s, start: start, end: end, app: app, descending: descending, now: now)
                        let full = got.candidates.dropLast().allSatisfy { $0 == 100 }
                        expect(got.ids == expected && full, "\(label): actions \(start == nil ? "of the whole history" : "of a range"), app \(app ?? "any"), \(descending ? "newest" : "oldest") first: \(got.ids.count) actions, expected \(expected.count); first difference at \(firstDifference(got.ids, expected)); pages full \(full)")
                    }
                }
            }
        }
        try sameDay("the recorder's connection", store)
        try sameDay("a reader", reader)
        try sameActions("the recorder's connection", store)
        try sameActions("a reader", reader)
        pass("a day paged through its cursors, and action pages (both orders, any app, one app, an app seldom used, a day and the whole history), are exactly the rows one statement returns")

        // Rows added since the day was read (1,200: more than one short statement), after it: added in order.
        _ = try dayIDs(store, day: day, zone: zone, now: now)
        raw.exec("BEGIN")
        for i in 0..<1200 { try add(isoPrecise(dayStart.addingTimeInterval(8 * 3600 + Double(i / 3))), i) }
        raw.exec("COMMIT")
        var got = try dayIDs(store, day: day, zone: zone, now: now)
        var expected = referenceIDs(raw, start: interval.start, end: interval.end)
        expect(got.ids == expected && got.count == expected.count, "rows added since the day was read: \(got.ids.count) actions, expected \(expected.count)")
        // …and before its end (an import with older times): read again.
        raw.exec("BEGIN")
        for i in 0..<30 { try add(iso(dayStart.addingTimeInterval(1800 + Double(i))), i) }
        raw.exec("COMMIT")
        got = try dayIDs(store, day: day, zone: zone, now: now)
        expected = referenceIDs(raw, start: interval.start, end: interval.end)
        expect(got.ids == expected && got.count == expected.count, "rows added with earlier times: \(got.ids.count) actions, expected \(expected.count)")
        // A row removed behind the store's back (no change of epoch): today no longer shows it; one of another day
        // leaves today as it was.
        let gone = expected[expected.count / 2]
        raw.exec("DELETE FROM records WHERE id=?", [gone])
        raw.exec("DELETE FROM records WHERE id IN (SELECT id FROM records WHERE julianday(json_extract(body,'$.at'))<julianday(?) LIMIT 5)", [MemoryStore.actionBound(interval.start)])
        got = try dayIDs(store, day: day, zone: zone, now: now)
        expected = referenceIDs(raw, start: interval.start, end: interval.end)
        expect(!got.ids.contains(gone) && got.ids == expected, "a row removed behind the store's back: today has \(got.ids.count) actions, expected \(expected.count); it still shows it: \(got.ids.contains(gone))")
        pass("a cached day takes rows added since (in order, or read again when earlier), and a row removed behind its back is gone")

        // The snapshot fences (rowid up to the read's high-water mark): a cached day brought up to date reads only the
        // moments added since (the note writer's read inside its write transaction must find it warm, G26), and action
        // pages leave out rows added after their first page. Every value is bound as text, so a fence the index can't
        // use (`+rowid`) must still compare as a number. Uses only what a6944d3 has too.
        var stamp = 0
        func fences(_ label: String, _ s: MemoryStore) throws {
            func top() -> Int64 { Int64(raw.rows("SELECT coalesce(max(rowid),0) FROM records")[0][0]) ?? 0 }
            /// `count` moments after every other of today; with `earlier`, as many earlier today and the day before, in
            /// each app: inside pages still to come.
            func addLater(_ count: Int, earlier: Bool = true) throws {
                raw.exec("BEGIN")
                for i in 0..<count {
                    stamp += 1
                    try add(isoPrecise(dayStart.addingTimeInterval(9 * 3600 + Double(stamp))), i)
                    guard earlier else { continue }
                    try add(isoPrecise(dayStart.addingTimeInterval(1000 + Double(stamp) / 100)), app: ("Terminal", "com.apple.Terminal"), i)
                    try add(isoPrecise(dayStart.addingTimeInterval(-3000 - Double(stamp))), app: ("Preview", "com.apple.Preview"), i)
                }
                raw.exec("COMMIT")
            }
            DayAssemblyCache.shared.removeAll()
            _ = try dayIDs(s, day: day, zone: zone, now: now)
            // Moments after the day's last (as the recorder adds them): the warm day takes them without reading it again.
            try addLater(20, earlier: false)
            let expected = referenceIDs(raw, start: interval.start, end: interval.end)
            do {
                let warm = try s.assembleDay(day: day, timezone: zone, limit: 200, now: now, notes: false, warmOnly: true)
                expect(warm.day.summary.actionCount == expected.count, "\(label): the warm day brought up to date has \(warm.day.summary.actionCount) actions, expected \(expected.count)")
            } catch { expect(false, "\(label): a warm day with moments added since was read again instead of brought up to date (\(error))") }
            let got = try dayIDs(s, day: day, zone: zone, now: now)
            expect(got.ids == expected, "\(label): the day after moments were added has \(got.ids.count) actions, expected \(expected.count); first difference at \(firstDifference(got.ids, expected))")
            // Action pages keep the first page's snapshot while rows land between pages.
            let yesterday = interval.start.addingTimeInterval(-86_400)
            for (start, end) in [(Optional(interval.start), Optional(interval.end)), (nil, nil), (Optional(yesterday), Optional(interval.start.addingTimeInterval(4 * 3600 + 1)))] {
                for app in [nil, "Terminal", "com.apple.Preview"] as [String?] {
                    for descending in [false, true] {
                        let expected = referenceIDs(raw, start: start ?? Date(timeIntervalSince1970: -62_135_596_800), end: end ?? Date(timeIntervalSince1970: 253_402_214_400),
                                                    app: app ?? "", descending: descending, top: String(top()))
                        var ids = [String](), after: String?, pages = 0
                        repeat {
                            let page = try s.actions(start: start, end: end, app: app, after: after, limit: 100, now: now, descending: descending)
                            ids += page.actions.map(\.id); after = page.next; pages += 1
                            if pages <= 3 { try addLater(1) }
                        } while after != nil && pages < 2000
                        expect(ids == expected, "\(label): actions \(start == nil ? "of the whole history" : "of a range"), app \(app ?? "any"), \(descending ? "newest" : "oldest") first, with rows landing between pages: \(ids.count) actions, expected \(expected.count); first difference at \(firstDifference(ids, expected))")
                    }
                }
            }
        }
        try fences("the recorder's connection", store)
        try fences("a reader", reader)
        pass("reads up to a rowid leave out rows added after them: a cached day is brought up to date with only the new moments, and action pages keep their snapshot while rows land")

        // Without the time index (a history DayDream hasn't indexed yet): the same answers, then the index another
        // connection builds is used by the same stores.
        raw.exec("DROP INDEX records_at_julian")
        let unindexedStore = try MemoryStore(home: home)
        try sameDay("without the time index", unindexedStore)
        try sameActions("without the time index", unindexedStore)
        try fences("without the time index", unindexedStore)
        raw.exec(MemoryStore.timeIndexes[1])
        try sameDay("once another connection built the index", unindexedStore)
        try sameActions("once another connection built the index", unindexedStore)
        pass("without the time index the answers are the same, and an index built meanwhile gives the same answers")
        DayAssemblyCache.shared.removeAll()
    }

    // MARK: E. G60
    static func openWithoutWriteLock(_ root: URL, now: Date) throws {
        let home = root.appendingPathComponent("busy")
        try makeStore(home, today: 20, past: 0, now: now)
        _ = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        let other = Raw(home)
        expect(other.exec("BEGIN IMMEDIATE") == SQLITE_OK && other.exec("INSERT OR REPLACE INTO metadata VALUES('perf_probe','1')") == SQLITE_OK, "the other connection could not start its write")
        let t = wallNow()
        do { _ = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false) }
        catch { expect(false, "a writable open failed while another connection was writing: \(error)") }
        let ms = Double(wallNow() - t) / 1e6
        other.exec("ROLLBACK")
        expect(ms < 1000, String(format: "the open waited %.0f ms for the other connection's write", ms))
        pass(String(format: "a writable open of an existing store succeeds in %.0f ms while another connection holds the write lock", ms))
    }
}
