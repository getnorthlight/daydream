import Foundation
import CSQLite

/// wal-1005: the history's journal. Through 0.1.4 the history kept SQLite's rollback journal (`journal_mode=delete`),
/// where a read in progress holds a save's commit up and a commit holds every read up: an AI app's read, the search
/// scan or a day read left the main thread's 25 ms saves failing busy ("Saving works again.", the heartbeat's busy
/// code 5). In SQLite's write-ahead log (WAL) a read never waits for a save and a save never waits for a read; two
/// saves still take turns.
///
/// - The switch is launch's (`HistoryPreparation`): once, off the main thread, before the app's model opens the history,
///   waiting at most `switchPatience` for the other connections to let go (it needs a moment with nothing reading); one
///   that couldn't is tried again at the next launch, and the history meanwhile works as before. A history the app makes
///   new is made in WAL at once (`MemoryStore(liveHistory:)`). Only the app's own history switches: backups, staging
///   folders and a repair's new file are never WAL (a backup is one file, `memory.sqlite`).
/// - The mode is the file's own (bytes 18 and 19 of its header): every process (the CLI, AI apps' servers, the search
///   supervisor, the backup helper, an older DayDream) follows it with the same system SQLite, from 3.7 on.
/// - The log and its index (`memory.sqlite-wal`, `-shm`) stay beside the history once made (the system SQLite keeps them
///   by default, `SQLITE_FCNTL_PERSIST_WAL`; each writable open asks for it too), emptied at the last close. The system
///   SQLite can't open a WAL history read-only while they're missing (SQLITE_CANTOPEN, checked on 3.51.0), so the switch
///   makes them at once (`MemoryStore.useJournal`) and a read-only open that finds them missing opens read-write with
///   `query_only` instead, which makes them.
/// - Nothing removed stays in the log (secure delete, as the rollback journal's deleted file did): a change is folded into
///   the history and the log emptied (`fold`, `PRAGMA wal_checkpoint(TRUNCATE)`) within `settleDelay`, and at once, off
///   the main thread, after Forget, a deletion and typed-words expiry (`MemoryStore.foldRemoved`). A fold never waits for
///   another connection: one that meets a read in progress tries again a moment later.
/// - `synchronous=FULL` stays (every commit is on disk when it returns, as before); SQLite's automatic checkpoint (every
///   1000 pages) stays, and `journal_size_limit` keeps an emptied log at most 16 MiB.
/// - Back to the rollback journal: `defaults write <DayDream's bundle id> DaydreamHistoryJournal delete`, then open
///   DayDream: launch's preparation switches the history back (for a build before 0.1.5, quit DayDream first).
public enum HistoryJournal {
    public enum Mode: String, Sendable, Equatable { case wal, delete }
    private static let lock = NSLock()
    private static var _wanted: Mode = .wal
    /// What launch's preparation leaves the app's history in (the app sets it from `defaultsKey` at launch).
    public static var wanted: Mode {
        get { lock.lock(); defer { lock.unlock() }; return _wanted }
        set { lock.lock(); _wanted = newValue; lock.unlock() }
    }
    /// The app's setting that puts the history back in the rollback journal ("delete"). Unset: WAL.
    public static let defaultsKey = "DaydreamHistoryJournal"
    public static func wanted(fromDefaults value: String?) -> Mode { value == "delete" ? .delete : .wal }
    /// How long launch's switch waits for other connections (AI apps' reads) to let go before leaving it to next launch.
    public static let switchPatience: TimeInterval = 1.5
    /// A change is folded into the history, and the log emptied, this long after it at most (`changed`).
    public static let settleDelay: TimeInterval = 20
    /// A log emptied by a checkpoint is cut back to this size at most.
    static let sizeLimit = 16 << 20

    /// The journal the file's header says (bytes 18 and 19: 2 for WAL, 1 for the rollback journal), read without SQLite
    /// or a lock. nil: no file, an empty file or not a SQLite header.
    public static func onDisk(_ path: String) -> Mode? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var header = [UInt8](repeating: 0, count: 20)
        guard pread(fd, &header, 20, 0) == 20, Array(header[0..<16]) == Array("SQLite format 3\0".utf8) else { return nil }
        if header[18] == 2 && header[19] == 2 { return .wal }
        if header[18] == 1 && header[19] == 1 { return .delete }
        return nil
    }
    /// The log or its index isn't beside the history (a read-only open of a WAL history can't make them).
    static func companionsMissing(_ path: String) -> Bool {
        var info = stat()
        return lstat(path + "-wal", &info) != 0 || lstat(path + "-shm", &info) != 0
    }

    /// One fold on a connection of its own: the log into the history, then the log emptied. Never waits for another
    /// connection (no busy handler): a read in progress or a save makes it return false at once. true when the log is
    /// empty now. Nothing to do (not WAL, no file) is true.
    static func foldOnce(_ path: String) -> Bool {
        guard onDisk(path) == .wal else { return true }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { return false }
        var persist: Int32 = 1
        _ = sqlite3_file_control(db, "main", SQLITE_FCNTL_PERSIST_WAL, &persist)
        // A connection opens the log at its first read: a checkpoint before it finds no log (log -1) and does nothing.
        guard sqlite3_exec(db, "SELECT count(*) FROM sqlite_master", nil, nil, nil) == SQLITE_OK else { return false }
        // The copy into the history and its sync first, without the save lock (PASSIVE); the emptying then holds the
        // app's saves only for what came in meanwhile and the cut (a TRUNCATE alone holds them through the copy and the
        // sync: saves waited up to 49 ms against 11 ms on 6000 frames here, longer on a busy disk).
        var log: Int32 = -1, folded: Int32 = -1
        _ = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_PASSIVE, &log, &folded)
        let rc = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, &log, &folded)
        return rc == SQLITE_OK && log == 0
    }
    /// A removal the person asked for: folds now, trying again every 50 ms for up to `patience`. Off the main thread only
    /// (the main thread schedules `changed` instead). false: left to `changed`'s tries.
    @discardableResult public static func foldNow(_ path: String, patience: TimeInterval = 3) -> Bool {
        let end = Date().addingTimeInterval(patience)
        repeat {
            if foldOnce(path) { return true }
            usleep(50_000)
        } while Date() < end
        changed(path, soon: true)
        return false
    }

    private static let queue = DispatchQueue(label: "DayDream.history-journal-fold", qos: .utility)
    private static var pending = Set<String>()
    /// A history in WAL changed (MemoryStore, after a write outside a transaction or a commit): a fold within
    /// `settleDelay` (`soon`: a second), then every 2 s until one lands, 30 tries at most (the next change starts again).
    /// Cheap on any thread: one lock and a set lookup.
    static func changed(_ path: String, soon: Bool = false) {
        lock.lock()
        let first = pending.insert(path).inserted
        lock.unlock()
        guard first else { return }
        queue.asyncAfter(deadline: .now() + (soon ? 1 : settleDelay)) { attempt(path, left: 30) }
    }
    private static func attempt(_ path: String, left: Int) {
        if foldOnce(path) || left <= 1 {
            lock.lock(); pending.remove(path); lock.unlock()
            return
        }
        queue.asyncAfter(deadline: .now() + 2) { attempt(path, left: left - 1) }
    }
    /// Checks: no fold is waiting.
    public static var foldPending: Bool { lock.lock(); defer { lock.unlock() }; return !pending.isEmpty }
}

extension MemoryStore {
    /// This connection's journal mode, as SQLite says it ("wal", "delete").
    public func journalMode() throws -> String { try rows("PRAGMA journal_mode").first?.first ?? "" }
    /// Puts the history in `mode` (launch's preparation and a new history only; it needs a moment with no other
    /// connection reading, and waits as this connection waits). Then reads, which makes the log and its index beside
    /// the file at once (a read-only open can't make them). true when the history is in `mode` now.
    @discardableResult public func useJournal(_ mode: HistoryJournal.Mode) throws -> Bool {
        guard writable else { throw MemError.denied }
        let now = try rows("PRAGMA journal_mode=\(mode.rawValue)").first?.first ?? ""
        _ = try rows("SELECT count(*) FROM sqlite_master")
        noteJournal()
        return now == mode.rawValue
    }
    /// After a removal the person asked for (Forget, delete, typed-words expiry): nothing removed is left in the log. Off
    /// the main thread, outside a transaction, it folds now (a few seconds at most); otherwise a fold follows in a second.
    func foldRemoved() {
        guard walMode else { return }
        if Thread.isMainThread || inTransaction { HistoryJournal.changed(file, soon: true) } else { HistoryJournal.foldNow(file) }
    }
}
