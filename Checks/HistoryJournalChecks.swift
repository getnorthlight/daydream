import Foundation
import CSQLite
import MemoryCore
import HistoryCore

/// wal-1005: the app's history keeps SQLite's write-ahead log (HistoryJournal.swift). Synthetic stores under the checks'
/// temporary folder only; raw SQLite connections stand in for AI apps' reads and another process.
func runHistoryJournalChecks(home root: URL, now fixed: Date) throws {
    // Moments read back with action(id) are the past's: these use the clock (minus an hour), not the checks' fixed time.
    let now = Date().addingTimeInterval(-3600)
    let fm = FileManager.default
    func file(_ home: URL) -> String { home.appendingPathComponent("memory.sqlite").path }
    func exists(_ path: String) -> Bool { var info = stat(); return lstat(path, &info) == 0 }
    func evidence(_ id: String, _ title: String, _ at: Date) -> Evidence {
        Evidence(id: id, at: iso(at), kind: "window.changed", app: "Notes", bundle: "com.apple.Notes", title: title, url: "", synthetic: true)
    }
    func bytes(_ path: String) -> Data { (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data() }
    func raw(_ path: String, _ flags: Int32) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else { throw MemError.invalid("FAILED: raw open") }
        return db
    }
    func offMain<T>(_ body: @escaping () throws -> T) throws -> T {
        var result: Result<T, Error>!
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { result = Result { try body() }; done.signal() }
        done.wait()
        return try result.get()
    }
    try check(HistoryJournal.wanted == .wal, "the app keeps its history in the write-ahead log unless told otherwise")
    try check(HistoryJournal.wanted(fromDefaults: "delete") == .delete && HistoryJournal.wanted(fromDefaults: nil) == .wal
              && HistoryJournal.wanted(fromDefaults: "wal") == .wal, "the setting DaydreamHistoryJournal=delete is the only way back")

    // MARK: a new history
    let fresh = root.appendingPathComponent("fresh")
    do {
        let store = try MemoryStore(home: fresh, writable: true, automaticallySyncSearch: false, liveHistory: true)
        try check(try store.journalMode() == "wal" && HistoryJournal.onDisk(file(fresh)) == .wal, "the app's new history is made in WAL")
        _ = try store.ingest(evidence("fresh-1", "Fresh", now), now: now)
        // As the app leaves it after its first launch (the owner build settles website typing rows once).
        _ = try store.settleWebsiteTypingRows(now: now)
    }
    try check(exists(file(fresh) + "-wal") && exists(file(fresh) + "-shm"), "the log and its index stay beside the history after the last close")
    try check(bytes(file(fresh) + "-wal").isEmpty, "the last close leaves the log empty (folded into the history)")
    let other = root.appendingPathComponent("not-live")
    do { _ = try MemoryStore(home: other, writable: true, automaticallySyncSearch: false) }
    try check(HistoryJournal.onDisk(file(other)) == .delete && !exists(file(other) + "-wal"),
              "any other new history (a backup, a staging folder, a repair's new file) keeps the rollback journal: one file")
    try check(!HistoryPreparation.needed(home: fresh), "a new WAL history needs no launch preparation")

    // MARK: read-only opens (the CLI, AI apps, the search supervisor)
    do {
        let reader = try MemoryStore(home: fresh)
        try check(try reader.action("fresh-1") != nil, "a read-only open reads a WAL history")
        var denied = false
        do { try reader.delete("fresh-1") } catch { denied = true }
        try check(denied, "a read-only open never writes")
    }
    // The log and its index gone (all connections closed, the log empty): the system SQLite can't read the history
    // through a read-only open any more; DayDream's reader opens read-write with query_only and makes them again.
    try fm.removeItem(atPath: file(fresh) + "-wal"); try fm.removeItem(atPath: file(fresh) + "-shm")
    do {
        let db = try raw(file(fresh), SQLITE_OPEN_READONLY)
        let rc = sqlite3_exec(db, "SELECT count(*) FROM records", nil, nil, nil)
        print("NOTE: system SQLite \(String(cString: sqlite3_libversion())): a read-only open of a WAL history without its log reads with code \(rc)")
        sqlite3_close(db)
    }
    do {
        let reader = try MemoryStore(home: fresh)
        try check(try reader.action("fresh-1") != nil, "a reader opens a WAL history whose log is missing")
        var denied = false
        do { try reader.delete("fresh-1") } catch { denied = true }
        try check(denied && (try reader.action("fresh-1")) != nil, "that reader never writes either")
    }
    try check(exists(file(fresh) + "-wal") && exists(file(fresh) + "-shm"), "the reader made the log and its index again")
    do {
        let db = try raw(file(fresh), SQLITE_OPEN_READONLY)
        try check(sqlite3_exec(db, "SELECT count(*) FROM records", nil, nil, nil) == SQLITE_OK, "after that, a plain read-only open (an older DayDream's AI app server) reads it")
        sqlite3_close(db)
    }

    // MARK: launch's switch
    let old = root.appendingPathComponent("old")
    do {
        let store = try MemoryStore(home: old, writable: true, automaticallySyncSearch: false)
        for i in 0..<20 { _ = try store.ingest(evidence("old-\(i)", "Old \(i)", now.addingTimeInterval(Double(i))), now: now) }
    }
    try check(HistoryJournal.onDisk(file(old)) == .delete && HistoryPreparation.needed(home: old), "a history 0.1.4 saved (rollback journal) needs launch's preparation")
    // An AI app reads throughout: the switch waits a moment, then leaves the history as it is for the next launch.
    let holder = try raw(file(old), SQLITE_OPEN_READONLY)
    try check(sqlite3_exec(holder, "BEGIN", nil, nil, nil) == SQLITE_OK && sqlite3_exec(holder, "SELECT count(*) FROM records", nil, nil, nil) == SQLITE_OK, "an AI app's read is in progress")
    let started = Date()
    let held = HistoryPreparation.prepare(home: old, patience: 0.4) { try MemoryStore(home: $0, writable: true, automaticallySyncSearch: false, launchWork: .preparation, liveHistory: true) }
    try check(held.prepared && !held.complete && HistoryJournal.onDisk(file(old)) == .delete && Date().timeIntervalSince(started) < 10,
              "a read held throughout: the history stays as it was, launch goes on, the next launch tries again")
    sqlite3_exec(holder, "COMMIT", nil, nil, nil)
    let switched = HistoryPreparation.prepare(home: old) { try MemoryStore(home: $0, writable: true, automaticallySyncSearch: false, launchWork: .preparation, liveHistory: true) }
    try check(switched.prepared && switched.complete && HistoryJournal.onDisk(file(old)) == .wal && !HistoryPreparation.needed(home: old),
              "launch's preparation switches the history to WAL once; the next launch has nothing to do")
    try check(exists(file(old) + "-wal") && exists(file(old) + "-shm"), "the switch makes the log and its index at once")
    try check(sqlite3_exec(holder, "SELECT count(*) FROM records", nil, nil, nil) == SQLITE_OK, "a connection open across the switch (an AI app's server) reads on")
    sqlite3_close(holder)
    do {
        let reader = try MemoryStore(home: old)
        try check((0..<20).allSatisfy { (try? reader.action("old-\($0)")) != nil }, "every moment is there after the switch")
    }

    // MARK: reads never hold a save up (the fix), saves still take turns
    do {
        let store = try MemoryStore(home: old, writable: true, automaticallySyncSearch: false)
        let reader = try raw(file(old), SQLITE_OPEN_READONLY)
        defer { sqlite3_close(reader) }
        try check(sqlite3_exec(reader, "BEGIN", nil, nil, nil) == SQLITE_OK && sqlite3_exec(reader, "SELECT count(*) FROM records", nil, nil, nil) == SQLITE_OK, "a read is in progress")
        let save = StoreWait.bounded(StoreWait.mainBudget) { try store.ingest(evidence("old-save", "Saved beside a read", now), now: now) }
        try check((try? save.result.get()) == true, "a main-thread save (25 ms) lands while another connection reads")
        sqlite3_exec(reader, "COMMIT", nil, nil, nil)
        let writer = try raw(file(old), SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(writer) }
        try check(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK, "another connection saves")
        let blocked = StoreWait.bounded(StoreWait.mainBudget) { try store.ingest(evidence("old-blocked", "Waits its turn", now), now: now) }
        var busy = false
        if case .failure(let error) = blocked.result { busy = CaptureFault.busy(error) }
        try check(busy, "two saves still take turns (busy, as before)")
        sqlite3_exec(writer, "COMMIT", nil, nil, nil)
    }
    // The same read in the rollback journal held the save up (what 0.1.4 did).
    do {
        let legacy = root.appendingPathComponent("legacy")
        let store = try MemoryStore(home: legacy, writable: true, automaticallySyncSearch: false)
        _ = try store.ingest(evidence("legacy-1", "Legacy", now), now: now)
        let reader = try raw(file(legacy), SQLITE_OPEN_READONLY)
        defer { sqlite3_close(reader) }
        try check(sqlite3_exec(reader, "BEGIN", nil, nil, nil) == SQLITE_OK && sqlite3_exec(reader, "SELECT count(*) FROM records", nil, nil, nil) == SQLITE_OK, "control: a read in the rollback journal")
        let save = StoreWait.bounded(StoreWait.mainBudget) { try store.ingest(evidence("legacy-2", "Held up", now), now: now) }
        var busy = false
        if case .failure(let error) = save.result { busy = CaptureFault.busy(error) }
        try check(busy, "control: in the rollback journal that read held the save up (busy)")
        sqlite3_exec(reader, "COMMIT", nil, nil, nil)
    }

    // MARK: nothing removed stays in the log (secure delete)
    let forget = root.appendingPathComponent("forget")
    let words = ["Quokkawalnut", "Ibexmarigold"]
    do {
        let store = try MemoryStore(home: forget, writable: true, automaticallySyncSearch: false, liveHistory: true)
        for (i, word) in words.enumerated() { _ = try store.ingest(evidence("forget-\(i)", word + " plans", now.addingTimeInterval(Double(i))), now: now) }
        _ = try store.ingest(evidence("keep-1", "Kept page", now.addingTimeInterval(5)), now: now)
        // An AI app's server keeps the history open (as it does): the last close never folds the log.
        let server = try raw(file(forget), SQLITE_OPEN_READONLY)
        defer { sqlite3_close(server) }
        try check(sqlite3_exec(server, "SELECT count(*) FROM records", nil, nil, nil) == SQLITE_OK, "an AI app's server has the history open")
        let both = bytes(file(forget)) + bytes(file(forget) + "-wal")
        try check(words.allSatisfy { both.range(of: Data($0.utf8)) != nil }, "control: the files hold the words before Forget")
        let zone = "UTC"
        let scope = MemoryActionScope.range(start: now.addingTimeInterval(-1), end: now.addingTimeInterval(2), timezone: zone)
        let preview = try store.prepareDeletion(scope: scope, now: now)
        try check(Set(preview.actionIDs) == ["forget-0", "forget-1"], "Forget's preview is the two moments")
        _ = try offMain { try store.executeDeletion(previewID: preview.id, confirmed: true, now: now) }
        let after = bytes(file(forget)) + bytes(file(forget) + "-wal")
        try check(bytes(file(forget) + "-wal").isEmpty, "after Forget the log is folded into the history and emptied")
        try check(words.allSatisfy { after.range(of: Data($0.utf8)) == nil }, "after Forget no file keeps the forgotten words")
        try check(try store.action("keep-1") != nil, "what wasn't forgotten stays")
        // A save on the main thread schedules a fold (a change folds within HistoryJournal.settleDelay).
        _ = try store.ingest(evidence("keep-2", "Another page", now.addingTimeInterval(6)), now: now)
        try check(HistoryJournal.foldPending, "a change in a WAL history is folded soon after")
        try store.delete("keep-2")
        try check(try offMain { HistoryJournal.foldNow(file(forget)) } && bytes(file(forget) + "-wal").isEmpty, "a fold empties the log")
    }

    // MARK: back to the rollback journal (the setting)
    HistoryJournal.wanted = .delete
    defer { HistoryJournal.wanted = .wal }
    try check(HistoryPreparation.needed(home: old), "with the setting, a WAL history needs launch's preparation")
    let back = HistoryPreparation.prepare(home: old) { try MemoryStore(home: $0, writable: true, automaticallySyncSearch: false, launchWork: .preparation, liveHistory: true) }
    try check(back.complete && HistoryJournal.onDisk(file(old)) == .delete && !HistoryPreparation.needed(home: old), "the setting puts the history back in the rollback journal")
    do {
        let db = try raw(file(old), SQLITE_OPEN_READONLY)
        try check(sqlite3_exec(db, "SELECT count(*) FROM records", nil, nil, nil) == SQLITE_OK, "a plain read-only open (0.1.4's CLI and AI app servers) reads it")
        sqlite3_close(db)
    }
    HistoryJournal.wanted = .wal
    do {
        let made = root.appendingPathComponent("made-delete")
        HistoryJournal.wanted = .delete
        _ = try MemoryStore(home: made, writable: true, automaticallySyncSearch: false, liveHistory: true)
        HistoryJournal.wanted = .wal
        try check(HistoryJournal.onDisk(file(made)) == .delete, "with the setting, a new history keeps the rollback journal")
    }
}
