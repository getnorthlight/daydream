// DD-RECIPE: CORE (MemoryCore, HistoryCore, PrivacyPolicy and MemoryUI objects; as run-checks.sh "store-perf")
// fix/perf7: searching notes costs what matches, not a query per note. SYNTHETIC store under $TMPDIR only (a scratch
// day through the normal store: rows, moment notes; then the notes copied under new ids to make a history of about
// 2,000 moment notes). No app, permission, Keychain or model.
//   A. noteSearch returns exactly what the old per-note loop did (each note's action times read before the match),
//      for words that hit lines, titles only, nothing, and several words.
//   B. a search for a word no note has costs a fraction of the old loop (thread CPU ratio, so load doesn't matter).
//   C. DayScope.key: the same keys as a fresh formatter per call (zones, DST edges, day edges), from many threads at
//      once, and at least 5x cheaper per call.
// Before fix/perf7 (build/7, debug): noteSearch over ~2,000 moment notes took the same time for any word (see PERF).
import Foundation
@testable import MemoryCore

func fail(_ m: String) -> Never { fflush(stdout); FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)); exit(1) }
func threadCPU() -> Double {
    var info = thread_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
    let port = mach_thread_self(); defer { mach_port_deallocate(mach_task_self_, port) }
    _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) } }
    return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6 + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
}
func cost(_ n: Int = 3, _ body: () throws -> Void) rethrows -> Double {
    var best = Double.infinity
    for _ in 0..<n { let c = threadCPU(); try body(); best = min(best, threadCPU() - c) }
    return best * 1000
}

let zone = "America/Los_Angeles"
let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!; return c }()
func date(_ h: Int, _ m: Int, _ s: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: h, minute: m, second: s))! }
func iso(_ d: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: d) }
let now = date(21, 0)
let words = ["alpha", "harbor", "maple", "orbit", "cedar", "delta", "ember", "falcon", "garnet", "hazel", "indigo", "juniper"]
let apps = [("Mail", "com.apple.mail"), ("Xcode", "com.apple.dt.Xcode"), ("Notes", "com.apple.Notes"), ("Terminal", "com.apple.Terminal"), ("Slack", "com.tinyspeck.slackmacgap")]

/// The loop noteSearch ran before fix/perf7 for moment notes (times read for every note, then the match).
func oldMomentHits(_ store: MemoryStore, _ query: String) throws -> [String] {
    let w = MemoryStore.folded(query)
    var out = [String]()
    for row in try store.rows("SELECT g.body FROM generated_notes g WHERE g.version=(SELECT max(version) FROM generated_notes h WHERE h.id=g.id) AND g.id NOT LIKE 'day_%'") {
        guard let note = try? decode(GeneratedNote.self, row[0]) else { continue }
        let times = try store.rows("SELECT id,json_extract(body,'$.at') FROM records WHERE id IN (SELECT value FROM json_each(?))", [json(note.actionIDs)])
        var at = [String: String](); for r in times { at[r[0]] = r[1] }
        guard let first = at.values.min() else { continue }
        let day = (try? DayScope.key(timestamp(first) ?? now, timezone: zone)) ?? ""
        let open = "moment:\(note.id)@\(day)"
        var matched = false
        for b in note.output.bullets where MemoryStore.recallMatches(w, b.text) {
            let cited = b.actionIDs.filter { at[$0] != nil }.min { at[$0]! < at[$1]! }
            out.append("line|\(b.text)|\(note.output.title)|\(cited.flatMap { at[$0] } ?? first)|\(day)|\(open)|\(cited ?? note.actionIDs.first ?? "")")
            matched = true
        }
        if !matched, MemoryStore.recallMatches(w, note.output.title + " " + note.output.bullets.map(\.text).joined(separator: " ")) {
            out.append("moment|\(note.output.title)|-|\(first)|\(day)|\(open)|\(at.min { $0.value < $1.value }?.key ?? "")")
        }
    }
    return out.sorted()
}
func newMomentHits(_ store: MemoryStore, _ query: String) throws -> [String] {
    try store.noteSearch(query, timezone: zone, now: now, limit: 100_000).filter { $0.level == "moment" || $0.level == "line" }.map {
        "\($0.level)|\($0.text)|\($0.inTitle ?? "-")|\($0.at)|\($0.day)|\($0.open)|\($0.actionID ?? "")"
    }.sorted()
}

@main enum NoteSearchPerfChecks {
    static func main() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("note-search-perf-\(getpid())")
        try? FileManager.default.removeItem(at: root)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("memory", isDirectory: true)
        do {
            let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
            // One day: 48 windows of 3-5 minutes (a click every ~20 s), each its own moment.
            var n = 0, t = date(8, 0)
            for i in 0..<48 {
                let app = apps[i % apps.count], title = "\(words[i % words.count]) \(words[(i / words.count + 3) % words.count]) plan \(i)"
                let stop = t.addingTimeInterval(Double(180 + (i % 3) * 60))
                var first = true
                while t < stop {
                    n += 1
                    _ = try store.ingest(Evidence(id: String(format: "ns-%05d", n), at: iso(t), kind: first ? "window.changed" : "mouse.click", app: app.0, bundle: app.1,
                                                  title: title, url: "", synthetic: true), now: t.addingTimeInterval(1))
                    first = false; t = t.addingTimeInterval(20)
                }
                t = t.addingTimeInterval(i % 6 == 5 ? 45 * 60 : 30)
            }
            let key = try DayScope.key(date(12, 0), timezone: zone)
            var notes = 0
            for m in try store.dayLayers(day: key, timezone: zone, limit: 1, now: now).activities where m.status != "ready" {
                guard let r = try? store.prepareNote(kind: "activity", day: key, timezone: zone, activityID: m.id, now: now) else { continue }
                let ids = r.actions.map(\.id), half = max(1, ids.count / 2)
                let subject = m.subject.trimmingCharacters(in: .whitespaces)
                _ = try store.commitNote(NoteWriterOutput(requestID: r.id, title: subject.isEmpty ? "Work" : subject,
                    bullets: [NoteBullet(text: "Reviewed the \(subject) draft.", actionIDs: Array(ids.prefix(half)), assertion: "observed"),
                              NoteBullet(text: "Kept working in the harbor file.", actionIDs: Array(ids.suffix(from: half)), assertion: "observed")],
                    generator: "code/perf-fixture", generatorVersion: "1"), now: now)
                notes += 1
            }
            guard notes >= 40 else { fail("fixture: at least 40 moment notes (got \(notes))") }
            // Copy each note 49 more times under new ids (the same actions): about 2,000 moment notes.
            for c in 1...49 { try store.exec("INSERT INTO generated_notes SELECT id||'-c\(c)',version,input_revision,body FROM generated_notes WHERE id NOT LIKE '%-c%' AND id NOT LIKE 'day_%'") }
            let total = Int(try store.rows("SELECT count(*) FROM generated_notes WHERE id NOT LIKE 'day_%'").first![0])!
            print("fixture: \(n) rows, \(notes) moment notes, \(total) after copying")

            // A. The same hits.
            for q in ["harbor", "reviewed", "alpha", "zzqx", "plan 7", "kept working harbor", "HARB"] {
                let old = try oldMomentHits(store, q), new = try newMomentHits(store, q)
                guard old == new else { fail("A: noteSearch '\(q)' differs from the old loop: \(old.count) vs \(new.count) hits; first difference \(zip(old, new).first { $0 != $1 }.map { "\($0) / \($1)" } ?? "(count)")") }
                print("PASS A: noteSearch '\(q)': the same \(new.count) moment and line hits as before")
            }
            // B. A word no note has: the old loop against noteSearch now.
            let oldMiss = try cost { _ = try oldMomentHits(store, "zzqx") }
            let newMiss = try cost { _ = try store.noteSearch("zzqx", timezone: zone, now: now) }
            let newHit = try cost { _ = try store.noteSearch("reviewed", timezone: zone, now: now) }
            print(String(format: "PERF noteSearch over %d moment notes: a word no note has %.1f ms (the old loop %.1f ms), a word every note has %.1f ms", total, newMiss, oldMiss, newHit))
            guard newMiss * 3 <= oldMiss else { fail(String(format: "B: a search for a word no note has costs at most a third of the old loop (%.1f ms vs %.1f ms)", newMiss, oldMiss)) }
            print("PASS B: a search for a word no note has costs a fraction of the old loop")
        } catch { fail("store: \(error)") }

        // C. DayScope.key.
        func freshKey(_ d: Date, _ tz: String) -> String {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian); f.timeZone = TimeZone(identifier: tz)!; f.dateFormat = "yyyy-MM-dd"
            return f.string(from: d)
        }
        let zones = ["America/Los_Angeles", "America/Chicago", "Europe/London", "Asia/Tokyo", "Australia/Lord_Howe", "Pacific/Kiritimati", "UTC", "America/St_Johns"]
        var dates = [Date]()
        for base in [1_772_323_200.0, 1_773_525_600.0, 1_793_512_800.0, 1_798_761_599.0, 1_798_761_600.0, 1_761_955_200.0] {   // around DST changes and a year end
            for off in stride(from: -86_400.0, through: 86_400, by: 1_799) { dates.append(Date(timeIntervalSince1970: base + off)) }
        }
        for tz in zones { for d in dates { guard (try? DayScope.key(d, timezone: tz)) == freshKey(d, tz) else { fail("C: DayScope.key \(d) \(tz)") } } }
        guard (try? DayScope.key(Date(), timezone: "Not/AZone")) == nil else { fail("C: an unknown zone still throws") }
        let bad = NSLock(); var mismatches = 0
        DispatchQueue.concurrentPerform(iterations: 16) { i in
            let tz = zones[i % zones.count]
            for d in dates where (try? DayScope.key(d, timezone: tz)) != freshKey(d, tz) { bad.lock(); mismatches += 1; bad.unlock() }
        }
        guard mismatches == 0 else { fail("C: DayScope.key from many threads at once: \(mismatches) wrong keys") }
        print("PASS C: DayScope.key gives the same keys as a fresh formatter (\(zones.count) zones, \(dates.count) instants, 16 threads)")
        let d0 = Date()
        let fresh = cost { for _ in 0..<2000 { _ = freshKey(d0, zone) } }
        let cached = cost { for _ in 0..<2000 { _ = try? DayScope.key(d0, timezone: zone) } }
        print(String(format: "PERF DayScope.key: %.2f us a call (a fresh formatter: %.2f us)", cached / 2, fresh / 2))
        guard cached * 5 <= fresh else { fail(String(format: "C: DayScope.key at least 5x cheaper than a fresh formatter (%.2f vs %.2f ms per 2000)", cached, fresh)) }
        print("PASS C: DayScope.key at least 5x cheaper than a fresh formatter")
        print("PASS: all note search perf checks")
    }
}
