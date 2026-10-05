import Foundation
import SQLite3

/// Launch's work on the history before the app opens it (gold r2-store-perf): the repair of a history SQLite reported
/// damaged (G45, `StoreIntegrity.repairIfNeeded`), the one-time build of the time indexes (G47,
/// `MemoryStore.timeIndexes`, made by the first writable open of a history an earlier DayDream saved) and, in the owner
/// build, the one-time settle of website typing rows (`settleWebsiteTypingRows`, which reads every record). Each can
/// take seconds on a long history (on a cold six-month history: the index build 10 s, the settle 7.9 s), and each ran
/// inside the app model's init on the main thread, so the app hung at launch. SQLite builds an index in one statement that
/// holds the file's write lock throughout, so it can't go in short steps beside the recorder (every save would fail
/// busy); it runs before the recorder exists instead, off the main thread: the app says one calm line meanwhile,
/// nothing records (there is no recorder yet, and the recorder lock is held so no other copy of DayDream records
/// either), AI apps keep reading (slower until the indexes exist), and the model's own open then finds nothing left
/// to do.
public enum HistoryPreparation {
    /// What the app does with a preparation, on the main thread.
    public struct Outcome: Equatable, Sendable {
        /// The repair, when one changed the file. The app says it from the new file itself, at its open
        /// (`MemoryStore.unsaidRepair`), not from here: this is only what happened.
        public var repair: StoreIntegrity.Repair?
        /// The preparation ran (this copy held the recorder lock). False when another copy of DayDream holds it: that
        /// copy's history is left as it is, and the app then says another copy is open.
        public var prepared: Bool
        /// Everything launch had to do is done: the history opened, it has every time index and (owner build) its website
        /// typing rows are settled, so `needed` now says no. False when a read held the history for the whole
        /// `patience`, a build failed or the history wouldn't open: the model's open still builds nothing on the main
        /// thread (`MemoryStore.LaunchWork.prepared`), and the next launch's preparation tries again.
        public var complete: Bool
        public init(repair: StoreIntegrity.Repair? = nil, prepared: Bool, complete: Bool = false) {
            self.repair = repair; self.prepared = prepared; self.complete = complete
        }
    }

    /// How long the preparation waits for another connection's lock before it leaves the rest to the next launch. The
    /// connection it waits for is an AI app's read: before the time indexes exist, a Today read is one whole-table
    /// statement of up to 10 s on a cold six-month history. Nothing records meanwhile, so the wait holds no save up;
    /// the app says "Getting ready…" throughout.
    public static let patience: TimeInterval = 30

    /// Launch has work to do before the history opens: SQLite reported it damaged (`StoreIntegrity.damageNoted`), or it
    /// lacks one of the time indexes, or (owner build) its website typing rows were never settled, or it can't be read
    /// (the open that follows will say why). A usual launch: one `lstat` and a read of the schema (and one metadata
    /// row). Never writes and never takes a lock another connection waits for (a reader that gives up after 100 ms).
    public static func needed(home: URL) -> Bool {
        if StoreIntegrity.damageNoted(home) { return true }
        let path = home.appendingPathComponent("memory.sqlite").path
        var info = stat()
        // No history yet: the first open makes an empty one, indexes and all, at once.
        guard lstat(path, &info) == 0 else { return false }
        // wal-1005: a history not yet in the journal the app keeps it in (HistoryJournal.swift) switches here, once.
        if let journal = HistoryJournal.onDisk(path), journal != HistoryJournal.wanted { return true }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { return true }
        sqlite3_busy_timeout(db, 100)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT name,sql FROM sqlite_master WHERE type='index' AND sql IS NOT NULL", -1, &statement, nil) == SQLITE_OK else { return true }
        var found = [String: String]()
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW, let name = sqlite3_column_text(statement, 0), let sql = sqlite3_column_text(statement, 1) else { return true }
            found[String(cString: name)] = String(cString: sql)
        }
        guard MemoryStore.timeIndexNames.allSatisfy({ name in found[name].map { MemoryStore.ownIndex(name: name, sql: $0) } ?? false }) else { return true }
        guard MemoryStore.websiteRows != nil else { return false }
        var settled: OpaquePointer?
        defer { sqlite3_finalize(settled) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM metadata WHERE id='\(MemoryStore.websiteSettleID)'", -1, &settled, nil) == SQLITE_OK else { return true }
        return sqlite3_step(settled) != SQLITE_ROW
    }

    /// Off the main thread, before the app's model exists. With the recorder lock held (`capture.lock`, which the
    /// recorder holds while DayDream runs): repairs a history SQLite reported damaged, then opens it writable once with
    /// `open` as the app opens it (with `MemoryStore.LaunchWork.preparation`: the open builds nothing itself) and
    /// finishes launch's work on it (`finish`: the time indexes, then the owner build's website typing settle), and
    /// closes it. An open that fails on damage is repaired and tried once more, as the app's open does. The lock is let
    /// go before this returns. Nothing happens when another copy of DayDream holds the lock. An open that still fails is
    /// left for the app's own open, which says why.
    public static func prepare(home: URL, patience: TimeInterval = patience, open: (URL) throws -> MemoryStore) -> Outcome {
        withRecorderLock(home) {
            var repair = StoreIntegrity.repairIfNeeded(home: home)
            var store: MemoryStore?
            do { store = try opened(home, patience: patience, open) }
            catch where StoreIntegrity.damageNoted(home) {
                if let again = StoreIntegrity.repairIfNeeded(home: home) { repair = again }
                store = try? opened(home, patience: patience, open)
            } catch {}
            guard let store else { return Outcome(repair: repair, prepared: true) }
            return Outcome(repair: repair, prepared: true, complete: finish(store, patience: patience))
        } ?? Outcome(prepared: false)
    }

    /// The preparation's work on the history it opened, until it is done (gold r2-store-perf review round 1: the build
    /// ran once with a 1.5 s limit, so one AI app's read across a build's commit left that index unbuilt, and the
    /// model's open on the main thread built it). Each time index the history lacks, `records_at_julian` first
    /// (`MemoryStore.preparationOrder`), then (owner build) the website typing settle. Each waits up to `patience` for
    /// another connection's lock: its commit waits for the reads in progress to end, and new reads wait for it (the
    /// pending lock), briefly. One that fails at once on a lock (SQLITE_IOERR_LOCK: a reader in this process that opened
    /// read-only before this writer) is tried again after a pause. A read that held the history for the whole patience
    /// leaves the rest to the next launch; so does a build that can't be made (an unreadable row). True when all is done.
    static func finish(_ store: MemoryStore, patience: TimeInterval) -> Bool {
        // wal-1005: first the journal (HistoryJournal.swift), so the builds below already let AI apps read beside them.
        // It needs a moment with no other connection reading or saving: one that doesn't come within `switchPatience`
        // leaves the history as it is (it works as before). When builds followed (they wait out the reads in their way),
        // it is tried once more after them; otherwise the next launch tries again.
        let journal = min(patience, HistoryJournal.switchPatience)
        var switched = switchJournal(store, HistoryJournal.wanted, within: journal)
        var built = false
        var complete = true
        for name in MemoryStore.preparationOrder where !store.hasTimeIndex(name) {
            built = true
            switch patiently(store, patience, { try store.buildTimeIndex(name) }, done: { store.hasTimeIndex(name) }) {
            case .done: continue
            case .failed: complete = false
            case .held: return false
            }
        }
        if MemoryStore.websiteRows != nil, !store.websiteRowsSettled() {
            built = true
            if patiently(store, patience, { _ = try store.settleWebsiteTypingRows() }, done: { store.websiteRowsSettled() }) != .done {
                complete = false
            }
        }
        if !switched && built { switched = switchJournal(store, HistoryJournal.wanted, within: journal) }
        return complete && switched
    }
    /// wal-1005: puts the history in `wanted` (`MemoryStore.useJournal`), trying every 10 ms for up to `patience`, each
    /// try waiting at most a quarter second for other connections. A try that meets another connection's save fails at
    /// once (SQLite doesn't wait there: the switch reads first), so it is tried again often rather than waited on: the
    /// gap between two saves is short. true when the history is in `wanted`.
    static func switchJournal(_ store: MemoryStore, _ wanted: HistoryJournal.Mode, within patience: TimeInterval) -> Bool {
        if HistoryJournal.onDisk(store.file) == wanted { return true }
        let end = Date().addingTimeInterval(patience)
        repeat {
            do {
                if try store.waiting(max(0.01, min(end.timeIntervalSinceNow, 0.25)), { try store.useJournal(wanted) }) { return true }
            } catch where CaptureFault.busy(error) {
            } catch { return false }
            usleep(10_000)
        } while Date() < end
        return HistoryJournal.onDisk(store.file) == wanted
    }
    /// `open`, tried again after a pause when it failed on a lock sooner than the patience (a reader in this process
    /// that opened read-only before this writer fails its first write at once: SQLITE_IOERR_LOCK), as `patiently` does.
    static func opened(_ home: URL, patience: TimeInterval, _ open: (URL) throws -> MemoryStore) throws -> MemoryStore {
        var pause: TimeInterval = 0.05
        for _ in 0..<7 {
            let started = Date()
            do { return try open(home) }
            catch let error where CaptureFault.busy(error) && Date().timeIntervalSince(started) < patience * 0.9 {
                Thread.sleep(forTimeInterval: pause)
                pause = min(pause * 2, 1)
            }
        }
        return try open(home)
    }
    enum Step { case done, failed, held }
    /// `body` on the preparation's connection, waiting up to `patience` for another connection's lock; a lock failure that
    /// came sooner is tried again, up to eight times, after pauses of 50 ms doubling to 1 s.
    static func patiently(_ store: MemoryStore, _ patience: TimeInterval, _ body: () throws -> Void, done: () -> Bool) -> Step {
        var pause: TimeInterval = 0.05
        for _ in 0..<8 {
            let started = Date()
            do {
                try store.waiting(patience, body)
                return done() ? .done : .failed
            } catch let error where CaptureFault.busy(error) {
                if Date().timeIntervalSince(started) >= patience * 0.9 { return .held }
                Thread.sleep(forTimeInterval: pause)
                pause = min(pause * 2, 1)
            } catch { return .failed }
        }
        return .failed
    }

    /// The repair alone (the app's open, `MemoryViewModel.repairDamagedHistory`): only while no other copy records
    /// into the history. nil when another copy holds the recorder lock or nothing changed.
    public static func repair(home: URL) -> StoreIntegrity.Repair? {
        guard StoreIntegrity.damageNoted(home) else { return nil }
        return withRecorderLock(home) { StoreIntegrity.repairIfNeeded(home: home) } ?? nil
    }

    /// `body` with the recorder lock held; nil (and `body` not run) when another copy of DayDream holds it or the lock
    /// file can't be opened.
    static func withRecorderLock<T>(_ home: URL, _ body: () -> T) -> T? {
        let lock = Darwin.open(home.appendingPathComponent("capture.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { return nil }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return nil }
        return body()
    }
}
