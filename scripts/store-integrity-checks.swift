// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.
//
// A damaged history (gold G45, review round 1), on synthetic stores in a scratch folder:
//
// A. What SQLite says. Its whole-file check can list a problem in a history whose every row still reads (freed pages
//    lost from the free list, an orphaned table: "never used"; a damaged index). A history is only ever repaired after
//    SQLite itself failed a real open, read or write with SQLITE_CORRUPT or SQLITE_NOTADB (the note), never on that
//    check alone. A usual launch reads nothing (no whole-file check).
// B. The review's false positives stay in place, byte for byte, with every row readable: leaked free pages and an
//    orphaned table; and even with a note, their repair keeps every row, keeps no copy and says nothing. Damage in an
//    index only: every row comes back, nothing is kept or said.
// C. Real damage (pages overwritten, a zeroed header, a cut-off file, a damaged receipts page): every row SQLite can
//    still read, and every moment whose own page is whole, comes back with the same choices and identity; the damaged
//    file is kept byte for byte (with its crash journal) until the person deletes it. Deleted moments never come back.
//    A busy file, another DayDream's newer history and a failed repair change nothing and keep the note.
// D. A backup made before the damage restores into the repaired history.
// E. Final review (test 5). A table whose first page is damaged loses only that page's rows (the walk started below
//    every rowid and gave up, dropping the whole table): the deletions come back whole (from their index), so a backup
//    from before the deletions brings none back; when neither the deletions' pages nor their index read, no restore adds
//    a moment from before the repair. When the choices couldn't be kept, connected AI apps lose their keys.
import Foundation
import CryptoKit
import CSQLite
@testable import MemoryCore

/// The scratch folder: under $TMPDIR when it is set (the check runners point it into their own folder, and
/// Foundation's temporaryDirectory ignores it), else the system's. Removed before the check exits, pass or fail.
var scratchRoot = URL(fileURLWithPath: "/nonexistent")
func scratch(_ prefix: String) -> URL {
    let base = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent(prefix + UUID().uuidString)
}
func finishScratch(_ code: Int32) -> Never { try? FileManager.default.removeItem(at: scratchRoot); exit(code) }

@main struct StoreIntegrityChecks {
    static var passes = 0, failures = 0
    static func check(_ value: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if value { passes += 1; print("PASS " + name) } else { failures += 1; print("FAIL " + name + { let d = detail(); return d.isEmpty ? "" : ": " + d }()) }
    }
    static func sha(_ url: URL) -> String {
        SHA256.hash(data: (try? Data(contentsOf: url)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    static let now = Date()
    static let choices: PrivacySettings = {
        var p = PrivacySettings(); p.blockedApps = ["com.example.private-notes"]; p.blockedDomains = ["example.org"]; return p
    }()

    /// A history of `count` moments (ids m0…) with the person's own choices, one connected AI app (`token`), and
    /// `receipts` large receipts after them.
    @discardableResult
    static func history(_ home: URL, count: Int = 3000, pad: Int = 0, receipts: Int = 0) throws -> (policy: String, identity: String, token: String) {
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        try store.updatePolicy(choices, now: now)
        let token = try store.grant(client: "ai-app", recipient: "synthetic", scopes: ["search"])
        try store.transaction {
            for n in 0..<count {
                let e = Evidence(id: "m\(n)", at: iso(now.addingTimeInterval(-Double(n) * 60 - 30)), kind: "window.changed", app: "Notes",
                                 bundle: "com.apple.Notes", title: "Budget review \(n)" + (pad > 0 ? " " + String(repeating: "x", count: pad) : ""), synthetic: true)
                let body = try json(e)
                try store.exec("INSERT INTO records VALUES(?,?,?)", [e.id, body, fingerprint(body)])
            }
            for n in 0..<receipts { try store.exec("INSERT INTO receipts VALUES(?,?)", ["r\(n)", String(repeating: "r", count: 3000)]) }
            try store.invalidateDisclosure()
        }
        return (try store.rows("SELECT body FROM metadata WHERE id='policy'")[0][0], try store.coreStoreID()!, token)
    }
    /// The AI app connected in `history` is still let in (its grant came across).
    static func connected(_ home: URL, _ token: String) -> Bool {
        (try? MemoryStore(home: home).authorize(client: "ai-app", recipient: "synthetic", capability: token, scope: "search")) != nil
    }
    static func overwrite(_ file: URL, at offsets: [Int], with bytes: Data) throws {
        let handle = try FileHandle(forWritingTo: file)
        for offset in offsets { try handle.seek(toOffset: UInt64(offset)); try handle.write(contentsOf: bytes) }
        try handle.close()
    }
    static func size(_ file: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int) ?? 0 }
    /// SQLite's own words on a file, straight from a plain connection (what the review ran).
    static func raw(_ home: URL, _ sql: String) -> [String] {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open(home.appendingPathComponent("memory.sqlite").path, &db) == SQLITE_OK else { return ["open error"] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return ["error \(sqlite3_extended_errcode(db))"] }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_ROW { out.append(sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""); continue }
            if status != SQLITE_DONE { out.append("error \(sqlite3_extended_errcode(db))") }
            return out
        }
    }
    static func rootPage(_ home: URL, _ name: String) -> Int { Int(raw(home, "SELECT rootpage FROM sqlite_master WHERE name='\(name)'").first ?? "") ?? 0 }
    static func copies(_ home: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []).filter { $0.hasPrefix("Damaged") }
    }
    /// What the app does with a history every day: open it, save a moment, write summaries, read the day and its
    /// pages, look one moment up, count. Nil when all of it works; else the first failure.
    static func dailyUse(_ home: URL, _ tag: String) -> String? {
        do {
            let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
            _ = try store.ingest(Evidence(id: "new-" + tag, at: iso(now), kind: "window.changed", app: "Notes", title: "Today " + tag, synthetic: true), now: now)
            _ = try store.writePending(now: now)
            _ = try store.timeline(now: now, limit: 20)
            _ = try store.actions(limit: 200, now: now, descending: true)
            _ = try store.status()
            guard try store.action("m42", now: now) != nil else { return "m42 missing" }
            _ = try store.rows("SELECT count(*) FROM records")
            return nil
        } catch { return "\(error)" }
    }
    /// The leftmost leaf page (1-based) of the table or index b-tree whose root is `root`.
    static func firstLeaf(_ home: URL, root: Int) throws -> Int {
        let data = try Data(contentsOf: home.appendingPathComponent("memory.sqlite"))
        var page = root
        while true {
            let base = (page - 1) * 4096, header = page == 1 ? base + 100 : base
            if data[header] == 0x0d || data[header] == 0x0a { return page }
            guard data[header] == 0x05 || data[header] == 0x02 else { return 0 }
            let cell = base + (Int(data[header + 12]) << 8 | Int(data[header + 13]))
            page = Int(data[cell]) << 24 | Int(data[cell + 1]) << 16 | Int(data[cell + 2]) << 8 | Int(data[cell + 3])
        }
    }
    static func moments(_ home: URL) -> Int { Int((try? MemoryStore(home: home).rows("SELECT count(*) FROM records WHERE id LIKE 'm%'"))?[0][0] ?? "") ?? -1 }

    static func main() throws {
        setbuf(stdout, nil)
        let root = scratch("daydream-store-integrity-"); scratchRoot = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func at(_ name: String) -> URL { root.appendingPathComponent(name) }

        // A. What counts as damaged, and when anything is done about it.
        check(StoreIntegrity.health(home: at("none")) == .missing, "no history yet: missing, nothing to do")
        let sound = at("sound"); try history(sound, count: 200)
        let soundBytes = sha(sound.appendingPathComponent("memory.sqlite"))
        check(StoreIntegrity.health(home: sound) == .sound, "a sound history is sound")
        check(StoreIntegrity.repairIfNeeded(home: sound, now: now) == nil && sha(sound.appendingPathComponent("memory.sqlite")) == soundBytes
              && copies(sound).isEmpty && !StoreIntegrity.damageNoted(sound), "a usual launch: nothing noted, nothing read or moved")
        do {
            // Another connection holds the file (a long write): the check can't run, so it proves nothing.
            let holder = try MemoryStore(home: sound, writable: true, automaticallySyncSearch: false)
            try holder.exec("BEGIN EXCLUSIVE")
            let started = Date()
            let busy = StoreIntegrity.health(home: sound)
            // A write that fails on busy is not damage: nothing is noted.
            let blocked = (try? MemoryStore(home: sound, writable: true, automaticallySyncSearch: false).exec("INSERT INTO tombstones VALUES('busy')")) == nil
            try holder.exec("ROLLBACK")
            check(busy == .unknown, "a busy history is never called damaged", busy.rawValue)
            check(Date().timeIntervalSince(started) < 8, "…and the check gives up within seconds")
            check(blocked && !StoreIntegrity.damageNoted(sound), "a write that failed because the file was busy notes nothing")
        }
        StoreIntegrity.noteDamage(sound)
        check(StoreIntegrity.damageNoted(sound) && StoreIntegrity.repairIfNeeded(home: sound, now: now) == nil
              && sha(sound.appendingPathComponent("memory.sqlite")) == soundBytes && !StoreIntegrity.damageNoted(sound) && copies(sound).isEmpty,
              "a note on a history SQLite then finds sound: the note goes, the file stays exactly as it was")

        // B1. The correctness review's history: 4,000 moments, 1,000 deleted, the free list's trunk and count zeroed. Every
        // row still reads; SQLite's whole-file check says "Page N: never used".
        let leak = at("leaked pages")
        try history(leak, count: 4000, pad: 300)
        try MemoryStore(home: leak, writable: true, automaticallySyncSearch: false).exec("DELETE FROM records WHERE CAST(substr(id,2) AS INTEGER) >= 3000")
        try overwrite(leak.appendingPathComponent("memory.sqlite"), at: [32], with: Data(count: 8))
        let leakLines = raw(leak, "PRAGMA quick_check").joined(separator: "\n")
        check(leakLines.contains("never used") && StoreIntegrity.health(home: leak) == .damaged, "(leaked free pages: SQLite's check lists \"never used\" pages)",
              String(leakLines.prefix(80)))
        check(dailyUse(leak, "a") == nil && !StoreIntegrity.damageNoted(leak), "leaked free pages: every read and write the app does works, and nothing is noted",
              dailyUse(leak, "b") ?? "")
        let leakBytes = sha(leak.appendingPathComponent("memory.sqlite"))
        check(StoreIntegrity.repairIfNeeded(home: leak, now: now) == nil && sha(leak.appendingPathComponent("memory.sqlite")) == leakBytes && copies(leak).isEmpty,
              "…so launch leaves the history in place, byte for byte, and sets nothing aside")
        check(moments(leak) == 3000, "…with all 3,000 moments readable", "\(moments(leak))")
        // Even with a note (a transient report), the repair keeps every row and says nothing.
        StoreIntegrity.noteDamage(leak)
        let leakRepair = StoreIntegrity.repairIfNeeded(home: leak, now: now)
        check(leakRepair?.whole == true && leakRepair?.copy == nil && copies(leak).isEmpty && moments(leak) == 3000
              && raw(leak, "PRAGMA quick_check") == ["ok"] && dailyUse(leak, "c") == nil,
              "…and even after a note, its repair keeps all 3,000 moments, keeps no copy and says nothing",
              "\(String(describing: leakRepair)) \(moments(leak))")

        // B2. The owner review's history: a table's schema entry removed (its pages are orphaned, "never used").
        let orphan = at("orphaned table")
        do {
            try history(orphan, count: 3000)
            let store = try MemoryStore(home: orphan, writable: true, automaticallySyncSearch: false)
            try store.exec("CREATE TABLE scratch_leak(id TEXT PRIMARY KEY, body TEXT NOT NULL)")
            try store.transaction { for n in 0..<300 { try store.exec("INSERT INTO scratch_leak VALUES(?,?)", ["x\(n)", String(repeating: "z", count: 3000)]) } }
        }
        do {
            // The owner review's damage.py step (this SQLite refuses to edit its own schema table; Python's allows it).
            let python = Process()
            python.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            python.arguments = ["python3", "-c", "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('PRAGMA writable_schema=ON'); "
                                + "c.execute(\"DELETE FROM sqlite_master WHERE tbl_name='scratch_leak'\"); c.commit(); c.close()",
                                orphan.appendingPathComponent("memory.sqlite").path]
            try python.run(); python.waitUntilExit()
            check(python.terminationStatus == 0 && raw(orphan, "PRAGMA quick_check").joined().contains("never used"), "(an orphaned table: SQLite's check lists \"never used\" pages)",
                  "\(python.terminationStatus) \(raw(orphan, "PRAGMA quick_check").joined().prefix(120))")
        }
        check(dailyUse(orphan, "a") == nil && !StoreIntegrity.damageNoted(orphan), "an orphaned table: every read and write the app does works, and nothing is noted")
        let orphanBytes = sha(orphan.appendingPathComponent("memory.sqlite"))
        check(StoreIntegrity.repairIfNeeded(home: orphan, now: now) == nil && sha(orphan.appendingPathComponent("memory.sqlite")) == orphanBytes
              && copies(orphan).isEmpty && moments(orphan) == 3000,
              "…launch leaves it in place, byte for byte, with all 3,000 moments readable")

        // B3. Damage in an index only (the moments' id index): looking one moment up fails with SQLITE_CORRUPT, so it is
        // noted; every row is whole, so the repair brings every one back and keeps nothing.
        let index = at("index only")
        let indexKept = try history(index, count: 3000)
        let indexRoot = rootPage(index, "sqlite_autoindex_records_1")
        try overwrite(index.appendingPathComponent("memory.sqlite"), at: [(indexRoot - 1) * 4096 + 1], with: Data(repeating: 0xff, count: 7))
        do {
            let store = try MemoryStore(home: index, writable: true, automaticallySyncSearch: false)
            let failed: Int32? = { do { _ = try store.action("m42", now: now); return nil } catch { return (error as? MemError)?.sqliteCode } }()
            check(indexRoot > 1 && failed.map { $0 & 0xff } == SQLITE_CORRUPT && StoreIntegrity.damageNoted(index),
                  "an index damaged: looking a moment up fails with SQLite's own damage code, and that is noted", "\(String(describing: failed))")
        }
        let indexRepair = StoreIntegrity.repairIfNeeded(home: index, now: now)
        check(indexRepair?.whole == true && indexRepair?.copy == nil && copies(index).isEmpty && !StoreIntegrity.damageNoted(index),
              "…launch repairs it in place: nothing kept aside, nothing to say", "\(String(describing: indexRepair))")
        check(moments(index) == 3000 && dailyUse(index, "a") == nil && raw(index, "PRAGMA quick_check") == ["ok"],
              "…with all 3,000 moments readable, looked up and recorded after", "\(moments(index)) \(dailyUse(index, "b") ?? "")")
        check(try MemoryStore(home: index).rows("SELECT body FROM metadata WHERE id='policy'")[0][0] == indexKept.policy
              && (try MemoryStore(home: index).coreStoreID()) == indexKept.identity, "…with the same choices and identity")
        check(connected(index, indexKept.token), "…and the AI app connected to it stays connected")

        // C1. Pages overwritten in the middle (a torn write, a bad block), including a page of the moments' tree above
        // many others. Some moments are deleted first: they must never come back.
        let torn = at("torn history")
        let kept = try history(torn, count: 3000)
        do {
            let store = try MemoryStore(home: torn, writable: true, automaticallySyncSearch: false)
            for n in 1500..<1600 { try store.delete("m\(n)") }
        }
        let tornFile = torn.appendingPathComponent("memory.sqlite")
        let pages = size(tornFile) / 4096
        try overwrite(tornFile, at: [pages / 4, pages / 2, 3 * pages / 4].map { $0 * 4096 + 100 }, with: Data((0..<3000).map { UInt8(($0 * 37 + 11) % 251) }))
        check(StoreIntegrity.health(home: torn) == .damaged, "overwritten pages: damaged")
        check(dailyUse(torn, "a") != nil && StoreIntegrity.damageNoted(torn), "…the app's reads fail with SQLite's damage code, and that is noted")
        let damagedBytes = sha(tornFile)
        try Data("synthetic crash journal".utf8).write(to: torn.appendingPathComponent("memory.sqlite-journal"))
        let tornRepair = StoreIntegrity.repairIfNeeded(home: torn, now: now)
        let tornCopy = tornRepair?.copy
        check(tornRepair?.whole == false && tornCopy.map { sha($0.appendingPathComponent("memory.sqlite")) } == damagedBytes,
              "the damaged file is kept byte for byte, never deleted", "\(String(describing: tornRepair))")
        check(tornCopy.map { $0.deletingLastPathComponent().path == torn.path && $0.lastPathComponent.hasPrefix("Damaged history") } == true
              && StoreIntegrity.damagedCopies(home: torn) == [tornCopy!], "…in one folder inside the history folder", tornCopy?.path ?? "")
        check(!FileManager.default.fileExists(atPath: torn.appendingPathComponent("memory.sqlite-journal").path),
              "…and a crash journal is never left for the repaired history to replay (SQLite's own open settles it first)")
        let back = moments(torn)
        check(back >= 2850 && back <= 2900, "every moment SQLite or its own page can still give back is back (at least 2,850 of the 2,900 kept)", "\(back)")
        check(((try? MemoryStore(home: torn).rows("SELECT count(*) FROM records WHERE id LIKE 'm%' AND CAST(substr(id,2) AS INTEGER) BETWEEN 1500 AND 1599")) ?? [["x"]])[0][0] == "0",
              "…and no deleted moment comes back")
        check(StoreIntegrity.health(home: torn) == .sound && !StoreIntegrity.damageNoted(torn), "the repaired history is sound, and the note is gone")
        let repaired = try MemoryStore(home: torn, writable: true, automaticallySyncSearch: false)
        check(try tornRepair?.keptChoices == true && (repaired.rows("SELECT body FROM metadata WHERE id='policy'")[0][0]) == kept.policy,
              "it keeps the person's choices exactly (apps and sites left out, typing, how long history is kept)")
        check(try !repaired.nativeTypingChoicePending(), "…as choices already made, not setup's defaults")
        check(try tornRepair?.keptIdentity == true && (repaired.coreStoreID()) == kept.identity, "…and the history's identity (its backups restore, typed words stay readable)")
        check(connected(torn, kept.token), "…and the AI app connected to it stays connected (no Reconnect)")
        check(dailyUse(torn, "b") == nil, "recording, summaries and the day all work again")
        try StoreIntegrity.deleteDamagedCopies(home: torn)
        check(StoreIntegrity.damagedCopies(home: torn).isEmpty && moments(torn) == back, "deleting the damaged file removes it and nothing else")

        // C2. A zeroed header (SQLite won't open it: SQLITE_NOTADB). The open notes it; its moments, choices and identity
        // come back from their own pages.
        let header = at("header")
        let headerKept = try history(header, count: 500)
        let headerFile = header.appendingPathComponent("memory.sqlite")
        try overwrite(headerFile, at: [0], with: Data(count: 16))
        check(StoreIntegrity.health(home: header) == .damaged, "a zeroed header: damaged")
        let opened: Int32? = { do { _ = try MemoryStore(home: header, writable: true, automaticallySyncSearch: false); return nil } catch { return (error as? MemError)?.sqliteCode } }()
        check(opened.map { $0 & 0xff } == SQLITE_NOTADB && StoreIntegrity.damageNoted(header), "…opening it fails with SQLite's own code, and that is noted",
              "\(String(describing: opened))")
        let headerBytes = sha(headerFile)
        let lost = StoreIntegrity.repairIfNeeded(home: header, now: now)
        check(lost?.copy.map { sha($0.appendingPathComponent("memory.sqlite")) } == headerBytes, "…the damaged file is kept byte for byte")
        check(moments(header) == 500, "…all 500 moments come back from their own pages", "\(moments(header))")
        check(try lost?.keptChoices == true && lost?.keptIdentity == true
              && MemoryStore(home: header).rows("SELECT body FROM metadata WHERE id='policy'")[0][0] == headerKept.policy
              && MemoryStore(home: header).coreStoreID() == headerKept.identity, "…with the same choices and identity (setup doesn't ask again)")

        // C3. Nothing at all can be read back: a new history with setup's choices, and it says so (setup asks again).
        let blank = at("blank")
        try history(blank, count: 200)
        let blankFile = blank.appendingPathComponent("memory.sqlite")
        try overwrite(blankFile, at: [0], with: Data(count: size(blankFile)))
        StoreIntegrity.noteDamage(blank)
        let none = StoreIntegrity.repairIfNeeded(home: blank, now: now)
        check(none?.keptChoices == false && none?.keptIdentity == false && none?.copy != nil,
              "nothing readable: the file is kept, and the repair says its choices couldn't be kept (setup asks again)", "\(String(describing: none))")
        check(try MemoryStore(home: blank, writable: true, automaticallySyncSearch: false).nativeTypingChoicePending(), "…its choices are setup's, waiting to be made")

        // C4. A cut-off file: the open fails with SQLite's damage code; what the file still holds comes back.
        let cut = at("cut")
        // gold/int: receipts fill the second half, so the cut takes only receipts. perf-store's time indexes (made at every
        // writable open) put index pages beside the records' own; with 300 receipts the half-way cut reached some records.
        try history(cut, count: 3000, receipts: 900)
        let cutFile = cut.appendingPathComponent("memory.sqlite")
        let handle = try FileHandle(forWritingTo: cutFile); try handle.truncate(atOffset: UInt64(size(cutFile) / 2)); try handle.close()
        check(StoreIntegrity.health(home: cut) == .damaged, "a cut-off file: damaged")
        check((try? MemoryStore(home: cut, writable: true, automaticallySyncSearch: false)) == nil && StoreIntegrity.damageNoted(cut), "…its open fails and is noted")
        let cutRepair = StoreIntegrity.repairIfNeeded(home: cut, now: now)
        check(cutRepair?.copy != nil && moments(cut) == 3000 && cutRepair?.keptChoices == true && dailyUse(cut, "a") == nil,
              "…every moment in the part that's left comes back, with the choices, and it records again", "\(moments(cut)) \(String(describing: cutRepair))")

        // C5. One page of AI apps' receipts damaged (the owner review's second case). The app's own work never reads it:
        // nothing is noted and the history stays in use as it is. Once a read of it fails, it is repaired: every moment
        // and every other receipt is kept, and the damaged file too (a receipt couldn't be read).
        let receipts = at("receipts")
        try history(receipts, count: 3000, receipts: 300)
        let receiptsFile = receipts.appendingPathComponent("memory.sqlite")
        let data = try Data(contentsOf: receiptsFile)
        let marker = Data(repeating: UInt8(ascii: "r"), count: 1000)
        let leaves = (1..<(data.count / 4096)).filter { p in data[p * 4096] == 13 && data[(p * 4096)..<((p + 1) * 4096)].range(of: marker) != nil }
        try overwrite(receiptsFile, at: [leaves[leaves.count / 2] * 4096 + 1], with: Data(repeating: 0xff, count: 7))
        check(dailyUse(receipts, "a") == nil && !StoreIntegrity.damageNoted(receipts) && StoreIntegrity.repairIfNeeded(home: receipts, now: now) == nil
              && moments(receipts) == 3000 && copies(receipts).isEmpty,
              "a damaged receipts page: the app's own reads and writes work, nothing is noted, the history stays in use as it is")
        _ = try? MemoryStore(home: receipts).rows("SELECT count(*) FROM receipts WHERE length(body) > 0")
        let receiptsRepair = StoreIntegrity.repairIfNeeded(home: receipts, now: now)
        let receiptsLeft = Int((try? MemoryStore(home: receipts).rows("SELECT count(*) FROM receipts"))?[0][0] ?? "") ?? -1
        check(receiptsRepair?.copy != nil && moments(receipts) == 3000 && receiptsLeft >= 298 && dailyUse(receipts, "b") == nil,
              "…once a read of it fails, the repair keeps all 3,000 moments and every receipt it can read", "\(receiptsLeft) \(String(describing: receiptsRepair))")

        // C6. What never moves anything. Busy while launch looks: the note stays for the next launch.
        let busy = at("busy")
        try history(busy, count: 300)
        let busyFile = busy.appendingPathComponent("memory.sqlite")
        try overwrite(busyFile, at: [(rootPage(busy, "records") - 1) * 4096 + 1], with: Data(repeating: 0xff, count: 7))
        check(StoreIntegrity.health(home: busy) == .damaged, "(the moments' first page damaged)")
        StoreIntegrity.noteDamage(busy)
        do {
            var holder: OpaquePointer?
            sqlite3_open(busyFile.path, &holder)
            sqlite3_exec(holder, "BEGIN EXCLUSIVE", nil, nil, nil)
            let busyBytes = sha(busyFile)
            check(StoreIntegrity.repairIfNeeded(home: busy, now: now) == nil && sha(busyFile) == busyBytes && copies(busy).isEmpty && StoreIntegrity.damageNoted(busy),
                  "a history another connection holds: nothing moves, and the note stays for the next launch")
            sqlite3_exec(holder, "ROLLBACK", nil, nil, nil); sqlite3_close(holder)
        }
        // A newer DayDream's history is never rewritten in this build's format.
        _ = raw(busy, "PRAGMA user_version=\(MemoryStore.formatVersion + 1)")
        let newerBytes = sha(busyFile)
        check(StoreIntegrity.repairIfNeeded(home: busy, now: now) == nil && sha(busyFile) == newerBytes && copies(busy).isEmpty && StoreIntegrity.damageNoted(busy),
              "a damaged history a newer DayDream saved: never rewritten by this one", "\(raw(busy, "PRAGMA user_version")) \(copies(busy)) \(StoreIntegrity.damageNoted(busy))")
        // A repair that can't finish (the history folder is read-only) leaves everything as it was.
        let locked = at("locked")
        try history(locked, count: 300)
        let lockedFile = locked.appendingPathComponent("memory.sqlite")
        try overwrite(lockedFile, at: [(rootPage(locked, "records") - 1) * 4096 + 1], with: Data(repeating: 0xff, count: 7))
        StoreIntegrity.noteDamage(locked)
        let lockedBytes = sha(lockedFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        let failedRepair = StoreIntegrity.repairIfNeeded(home: locked, now: now)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        check(failedRepair == nil && sha(lockedFile) == lockedBytes && copies(locked).isEmpty && StoreIntegrity.damageNoted(locked),
              "a repair that can't finish leaves the history exactly as it was, and the note for the next launch")

        // D. A backup made before the damage restores into the repaired history (Settings › Backup and restore › Restore).
        let lived = at("lived")
        try history(lived, count: 1000)
        let backup = try MemoryStore(home: at("backup"), writable: true, automaticallySyncSearch: false)
        _ = try MemoryStore(home: lived).exportCanonicalSnapshot(to: backup, now: now)
        let livedFile = lived.appendingPathComponent("memory.sqlite")
        let livedPages = size(livedFile) / 4096
        try overwrite(livedFile, at: [livedPages / 4, livedPages / 2, 3 * livedPages / 4].map { $0 * 4096 + 64 }, with: Data((0..<3000).map { UInt8($0 % 199) }))
        StoreIntegrity.noteDamage(lived)
        guard StoreIntegrity.repairIfNeeded(home: lived, now: now) != nil else { check(false, "the lived-in history is repaired"); finish() }
        let current = try MemoryStore(home: lived, writable: true, automaticallySyncSearch: false)
        try FileManager.default.copyItem(at: at("backup"), to: at("staging"))
        do {
            let candidate = try MemoryStore(home: at("staging"), writable: true, automaticallySyncSearch: false)
            _ = try current.reconcileCanonicalSnapshot(candidate, expected: current.coreSnapshotFence(), now: now)
            let preview = try current.prepareCanonicalRestore(candidate, now: now)
            // gold/r2-copy-checks: nothing held back, so the preview gives no reason line.
            check(preview.heldBackBefore == nil, "…and its preview holds nothing back (no reason line)", preview.heldBackBefore ?? "")
            let before = Int(try current.rows("SELECT count(*) FROM records")[0][0]) ?? 0
            let receipt = try current.confirmCanonicalRestore(candidate, previewID: preview.id, confirmed: true, now: now)
            check(try before < 1000 && receipt.addedActionIDs.count == 1000 - before && (current.rows("SELECT count(*) FROM records")[0][0]) == "1000",
                  "a backup from before the damage restores every moment into the repaired history", (try? current.rows("SELECT count(*) FROM records")[0][0]) ?? "?")
        } catch { check(false, "a backup from before the damage restores every moment into the repaired history", "\(error)") }

        // E1. The deletions' first page damaged (the final data review's repro): 3,000 moments, a backup of all of them,
        // then the person deletes 2,000.
        func deletedHistory(_ home: URL, _ backupName: String) throws {
            try history(home, count: 3000)
            let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
            let backup = try MemoryStore(home: at(backupName), writable: true, automaticallySyncSearch: false)
            _ = try store.exportCanonicalSnapshot(to: backup, now: now)
            for n in 0..<2000 { try store.delete("m\(n)") }
        }
        /// Restores the backup the way Backup and restore does; the moments it brought back that the person had deleted.
        func restoreDeleted(_ home: URL, _ backupName: String) throws -> (added: Int, deletedBack: Int, heldBackBefore: String?) {
            let current = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
            try FileManager.default.copyItem(at: at(backupName), to: at(backupName + "-staging"))
            let candidate = try MemoryStore(home: at(backupName + "-staging"), writable: true, automaticallySyncSearch: false)
            _ = try current.reconcileCanonicalSnapshot(candidate, expected: current.coreSnapshotFence(), now: now)
            let preview = try current.prepareCanonicalRestore(candidate, now: now)
            let receipt = try current.confirmCanonicalRestore(candidate, previewID: preview.id, confirmed: true, now: now)
            let back = (0..<2000).filter { (try? current.action("m\($0)", now: now)) != nil }.count
            let rows = Int(try current.rows("SELECT count(*) FROM records WHERE id LIKE 'm%' AND CAST(substr(id,2) AS INTEGER) < 2000")[0][0]) ?? -1
            return (receipt.addedActionIDs.count, max(back, rows), preview.heldBackBefore)
        }
        let firstPage = at("deletions first page")
        try deletedHistory(firstPage, "deletions backup")
        let firstPageLeaf = try firstLeaf(firstPage, root: rootPage(firstPage, "tombstones"))
        check(firstPageLeaf > 1 && raw(firstPage, "SELECT count(*) FROM tombstones") == ["2000"] && firstPageLeaf != rootPage(firstPage, "tombstones"),
              "(2,000 deletions over several pages)", "\(firstPageLeaf) \(raw(firstPage, "SELECT count(*) FROM tombstones"))")
        try overwrite(firstPage.appendingPathComponent("memory.sqlite"), at: [(firstPageLeaf - 1) * 4096 + 1], with: Data(repeating: 0xff, count: 7))
        StoreIntegrity.noteDamage(firstPage)
        let firstPageRepair = StoreIntegrity.repairIfNeeded(home: firstPage, now: now)
        check(firstPageRepair != nil && raw(firstPage, "SELECT count(*) FROM tombstones") == ["2000"],
              "the deletions' first page damaged: the repair keeps every deletion", "\(raw(firstPage, "SELECT count(*) FROM tombstones")) \(String(describing: firstPageRepair))")
        check(moments(firstPage) == 1000, "…and every moment the person kept", "\(moments(firstPage))")
        check(raw(firstPage, "SELECT count(*) FROM metadata WHERE id='deletions_unknown_before'") == ["0"],
              "…so nothing limits a later restore")
        do {
            let restored = try restoreDeleted(firstPage, "deletions backup")
            check(restored.deletedBack == 0 && restored.added == 0, "a backup from before the deletions brings no deleted moment back",
                  "added \(restored.added), deleted back \(restored.deletedBack)")
            // gold/r2-copy-checks: the deletions came back whole, so nothing was held back and the preview gives no reason.
            check(restored.heldBackBefore == nil, "…and its preview gives no held-back reason (the deletions say it)", restored.heldBackBefore ?? "")
        } catch { check(false, "a backup from before the deletions brings no deleted moment back", "\(error)") }

        // E2. The first page of a table no page rescue reads (summaries written for moments): the rest of its rows survive.
        let notes = at("notes first page")
        do {
            try history(notes, count: 200)
            let store = try MemoryStore(home: notes, writable: true, automaticallySyncSearch: false)
            try store.exec("CREATE TABLE IF NOT EXISTS generated_notes(id TEXT NOT NULL,version INTEGER NOT NULL,input_revision TEXT NOT NULL,body TEXT NOT NULL,PRIMARY KEY(id,version))")
            try store.transaction { for n in 0..<400 { try store.exec("INSERT INTO generated_notes VALUES(?,1,'r',?)", ["note\(n)", String(repeating: "n", count: 900)]) } }
        }
        let notesLeaf = try firstLeaf(notes, root: rootPage(notes, "generated_notes"))
        let notesOnFirst: Int = try {
            let page = try Data(contentsOf: notes.appendingPathComponent("memory.sqlite"))[((notesLeaf - 1) * 4096)...]
            return Int(page[page.startIndex + 3]) << 8 | Int(page[page.startIndex + 4])
        }()
        try overwrite(notes.appendingPathComponent("memory.sqlite"), at: [(notesLeaf - 1) * 4096 + 1], with: Data(repeating: 0xff, count: 7))
        StoreIntegrity.noteDamage(notes)
        let notesRepair = StoreIntegrity.repairIfNeeded(home: notes, now: now)
        let notesLeft = Int(raw(notes, "SELECT count(*) FROM generated_notes").first ?? "") ?? -1
        check(notesLeaf > 1 && notesOnFirst > 0 && notesOnFirst < 20 && notesRepair?.copy != nil && notesLeft == 400 - notesOnFirst && moments(notes) == 200,
              "a table's first page damaged: only that page's rows are lost", "\(notesLeft) of 400, \(notesOnFirst) on the first page \(String(describing: notesRepair))")

        // E3. The deletions' first page and their index both damaged: nothing says which moments were deleted, so a restore
        // adds no moment from before the repair.
        let noList = at("no deletion list")
        try deletedHistory(noList, "no list backup")
        let noListIndex = rootPage(noList, "sqlite_autoindex_tombstones_1")
        let noListLeaf = try firstLeaf(noList, root: rootPage(noList, "tombstones"))
        try overwrite(noList.appendingPathComponent("memory.sqlite"), at: [(noListLeaf - 1) * 4096 + 1, (noListIndex - 1) * 4096 + 1], with: Data(repeating: 0xff, count: 7))
        StoreIntegrity.noteDamage(noList)
        let noListRepair = StoreIntegrity.repairIfNeeded(home: noList, now: now)
        check(noListIndex > 1 && noListRepair?.whole == false && moments(noList) == 1000, "(deletions and their index damaged: the repair keeps the 1,000 moments)",
              "\(moments(noList)) \(String(describing: noListRepair))")
        check(raw(noList, "SELECT body FROM metadata WHERE id='deletions_unknown_before'") == [iso(now)],
              "…and notes that deletions from before the repair are unknown", "\(raw(noList, "SELECT body FROM metadata WHERE id='deletions_unknown_before'"))")
        do {
            let restored = try restoreDeleted(noList, "no list backup")
            check(restored.deletedBack == 0 && restored.added == 0, "…and a backup from before the deletions still brings no deleted moment back",
                  "added \(restored.added), deleted back \(restored.deletedBack)")
            // gold/r2-copy-checks: "0 actions to add" with a reason: the preview names the repair's marker, so Backup and
            // restore can say older actions aren't added (BackupSettingsModel.heldBackLine, ui-copy-checks).
            check(restored.heldBackBefore == iso(now), "…and its preview says why: older actions were held back (\(iso(now)))",
                  restored.heldBackBefore ?? "nil")
        } catch { check(false, "…and a backup from before the deletions still brings no deleted moment back", "\(error)") }

        // E4. The page holding the choices damaged (the final data review's second repro): setup's defaults, so apps the
        // person left out would show; a connected AI app must connect again.
        let lostChoices = at("choices lost")
        let lostKept = try history(lostChoices, count: 600, receipts: 20)
        do {
            // An AI app's pending request for typed words, on a later page of the same table than the choices.
            let store = try MemoryStore(home: lostChoices, writable: true, automaticallySyncSearch: false)
            for n in 0..<3 { try store.exec("INSERT INTO metadata VALUES(?,?)", ["pad-\(n)", String(repeating: "p", count: 3000)]) }
            try store.exec("INSERT INTO metadata VALUES('typed-exact-requests-v1','[]')")
        }
        let lostFile = lostChoices.appendingPathComponent("memory.sqlite")
        let lostData = try Data(contentsOf: lostFile)
        let needle = Data("\"blockedApps\":[\"com.example.private-notes\"]".utf8)
        let policyPages = (0..<(lostData.count / 4096)).filter { p in lostData[(p * 4096)..<((p + 1) * 4096)].range(of: needle) != nil }
        let requestPages = (0..<(lostData.count / 4096)).filter { p in lostData[(p * 4096)..<((p + 1) * 4096)].range(of: Data("typed-exact-requests-v1".utf8)) != nil }
        check(connected(lostChoices, lostKept.token) && !policyPages.isEmpty && !requestPages.isEmpty && Set(requestPages).isDisjoint(with: policyPages),
              "(the AI app is connected before the damage; its request sits on another page)", "\(policyPages) \(requestPages)")
        try overwrite(lostFile, at: policyPages.map { $0 * 4096 + 1 }, with: Data(repeating: 0xff, count: 7))
        StoreIntegrity.noteDamage(lostChoices)
        let lostRepair = StoreIntegrity.repairIfNeeded(home: lostChoices, now: now)
        check(lostRepair?.keptChoices == false && moments(lostChoices) == 600, "(the choices couldn't be kept; every moment is)", "\(String(describing: lostRepair))")
        check(!connected(lostChoices, lostKept.token) && raw(lostChoices, "SELECT count(*) FROM grants") == ["0"],
              "choices lost: the AI app connected before can't read anything until it connects again")
        check(raw(lostChoices, "SELECT count(*) FROM receipts") == ["0"] && raw(lostChoices, "SELECT count(*) FROM metadata WHERE id='typed-exact-requests-v1'") == ["0"],
              "…and what it was given or asked for goes with its key")
        finish()
    }
    static func finish() -> Never {
        print("\(passes) store integrity checks passed, \(failures) failed. Synthetic histories only.")
        finishScratch(failures == 0 ? 0 : 1)
    }
}
