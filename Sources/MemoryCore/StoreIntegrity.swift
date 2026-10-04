import Foundation
import CryptoKit
import CSQLite

/// A damaged history (gold G45). DayDream keeps using a history until SQLite itself says, while opening or reading it,
/// that the file is damaged (SQLITE_CORRUPT or SQLITE_NOTADB: `noteDamage`, from every MemoryStore call). A line in
/// SQLite's whole-file check alone (a leaked page, a table no one reads) never moves anything: those histories stay in
/// place and in use. The next launch, before the history opens and only then, confirms the damage with that check and
/// repairs it: every row SQLite can still read goes into a new file that takes the old one's place, with the same choices
/// and identity. When every row came across, that is all; nothing is said. When some rows couldn't be read, the damaged
/// file is kept, as it was, in a folder beside the new one ("Damaged history …") until the person deletes it (Backup and
/// restore says so, with the button), so a restore or a later tool can still reach what it holds.
///
/// Final review (test 5): a table whose first page was damaged was dropped whole (the rowid walk started at `Int64.min`
/// and never reached the next page); it now loses only that page's rows. Deletions whose rows couldn't be read come back
/// from their index; when even that fails, the new history notes the time (`deletionsUnknownBefore`) and no restore adds
/// a moment from before it. When the choices or the identity couldn't be kept, AI apps' keys, receipts and requests go:
/// they were given under choices the new history doesn't have.
///
/// Before (review round 1): any line in the whole-file check set the whole history aside and started an empty one, so a
/// history whose every row still read (freed pages lost from the free list, a damaged index) lost all its moments from
/// view; and that check read the whole file on the main thread at every launch.
public enum StoreIntegrity {
    public enum Health: String, Equatable, Sendable {
        /// SQLite's own check passed.
        case sound
        /// No history yet.
        case missing
        /// SQLite says the file is broken.
        case damaged
        /// The check couldn't run (busy, locked, a permission or disk error): that proves nothing, so nothing moves.
        case unknown
    }

    /// SQLite's quick check of the whole file. `damaged` only when SQLite itself says so: the file is corrupt or is not
    /// a database (SQLITE_CORRUPT, SQLITE_NOTADB), or the check lists a problem. Opened read-write without creating
    /// anything (so a journal left by a crash is rolled back first, as any open would), else read-only.
    public static func health(home: URL) -> Health { examine(home).health }

    /// `health`, with the check's own lines (never shown or logged: they only tell a damaged index from damaged rows).
    static func examine(_ home: URL) -> (health: Health, lines: [String]) {
        let path = home.appendingPathComponent("memory.sqlite").path
        var info = stat()
        guard lstat(path, &info) == 0 else { return (errno == ENOENT ? .missing : .unknown, [stopped]) }
        guard info.st_mode & S_IFMT == S_IFREG else { return (.unknown, [stopped]) }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            sqlite3_close(db); db = nil
            let opened = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
            guard opened == SQLITE_OK else { return (classify(sqlite3_extended_errcode(db) != 0 ? sqlite3_extended_errcode(db) : opened), [stopped]) }
        }
        sqlite3_busy_timeout(db, 1500)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return (classify(sqlite3_extended_errcode(db)), [stopped])
        }
        defer { sqlite3_finalize(stmt) }
        var lines: [String] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { return (classify(sqlite3_extended_errcode(db)), lines + [stopped]) }
            lines.append(sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "")
        }
        return (lines == ["ok"] ? .sound : .damaged, lines)
    }
    static func classify(_ code: Int32) -> Health { isDamage(code) ? .damaged : .unknown }
    /// The check itself failed part way: what it didn't reach proves nothing whole.
    static let stopped = "(check stopped)"

    // MARK: SQLite said so

    /// SQLITE_CORRUPT or SQLITE_NOTADB (any extended form): the file itself is damaged. Busy, locked, full, I/O and
    /// permission errors are not.
    public static func isDamage(_ code: Int32) -> Bool {
        let primary = code & 0xff
        return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB
    }
    /// An empty file beside the history: SQLite reported it damaged, in any process (the app, an AI app's server, the
    /// backup helper). It holds nothing, and the next launch looks.
    static let damageNote = ".damage-seen"
    private final class Noted: @unchecked Sendable {
        let lock = NSLock()
        var homes = Set<String>()
    }
    private static let noted = Noted()
    /// Called by MemoryStore for every failed call whose code is `isDamage`: writes the note once per process and home.
    /// Never throws and never fails the call that saw the damage.
    public static func noteDamage(_ home: URL) {
        let path = home.appendingPathComponent(damageNote).path
        noted.lock.lock()
        let first = noted.homes.insert(path).inserted
        noted.lock.unlock()
        guard first else { return }
        let fd = open(path, O_CREAT | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd >= 0 { close(fd) }
    }
    /// True when SQLite reported this history damaged and it hasn't been looked at since (one `lstat`: every launch).
    public static func damageNoted(_ home: URL) -> Bool {
        var info = stat()
        return lstat(home.appendingPathComponent(damageNote).path, &info) == 0
    }
    static func clearDamageNote(_ home: URL) {
        let path = home.appendingPathComponent(damageNote).path
        unlink(path)
        noted.lock.lock(); noted.homes.remove(path); noted.lock.unlock()
    }

    // MARK: The repair at launch

    /// What a launch did with a history SQLite reported damaged.
    public struct Repair: Equatable, Sendable {
        /// Every row came across: the new file is the whole history, and nothing was kept or needs saying.
        public var whole: Bool
        /// When some rows couldn't be read: the folder inside the history folder that keeps the damaged file as it was.
        public var copy: URL?
        /// The new file keeps the person's choices (apps and sites left out, how long history is kept, typing and web
        /// pages). When they couldn't be read, it has DayDream's defaults and setup asks again before anything records.
        public var keptChoices: Bool
        /// The new file keeps the history's identity (its backups restore into it; typed words stay readable).
        public var keptIdentity: Bool
        /// Rows copied, places where rows couldn't be read, and moments read straight from their pages (counts only).
        public var rows: Int
        public var unreadable: Int
        public var rescued: Int
    }

    /// Launch, before the history opens, with the recorder lock held (no other copy of DayDream is using the file). Reads
    /// nothing unless SQLite reported the history damaged (`damageNoted`). Then SQLite's whole-file check confirms it:
    /// sound, the note goes and the file is used as it is; the check couldn't run, the note stays for the next launch;
    /// damaged, `rebuild`. nil when nothing changed on disk. A rebuild that fails leaves everything as it was.
    public static func repairIfNeeded(home: URL, now: Date = Date()) -> Repair? {
        guard damageNoted(home) else { return nil }
        let (health, lines) = examine(home)
        switch health {
        case .sound, .missing: clearDamageNote(home); return nil
        case .unknown: return nil
        case .damaged:
            guard let repair = try? rebuild(home: home, now: now, lines: lines) else { return nil }
            clearDamageNote(home)
            return repair
        }
    }

    /// The row a repair that lost something leaves in the new file for the app to say (MemoryStore.unsaidRepair).
    static let unsaidRepairID = "history-repair-unsaid-v1"
    struct UnsaidBody: Codable { var keptChoices: Bool }
    /// A row that can't be read says the choices weren't kept: setup asks for them again.
    static func unsaidKeptChoices(_ body: String) -> Bool {
        (try? JSONDecoder().decode(UnsaidBody.self, from: Data(body.utf8)))?.keptChoices ?? false
    }

    static let rebuildPrefix = ".rebuild-"
    static let copyPrefix = "Damaged history"
    /// The SQLite files beside a history that must never be left next to a different database file.
    static let companions = ["memory.sqlite-journal", "memory.sqlite-wal", "memory.sqlite-shm"]

    /// Copies every row SQLite can read from the history into a new file (built by this DayDream, so its tables and keys
    /// are sound), checks the new file, then puts it in the old one's place in one rename. The old file is kept, as it was,
    /// in "Damaged history <time>" when any row couldn't be read, and is otherwise gone. Throws, leaving everything as it
    /// was, when the new file can't be made or put in place, or when the history is a newer DayDream's.
    static func rebuild(home: URL, now: Date, lines: [String]) throws -> Repair {
        let fm = FileManager.default
        let file = home.appendingPathComponent("memory.sqlite")
        for name in (try? fm.contentsOfDirectory(atPath: home.path)) ?? [] where name.hasPrefix(rebuildPrefix) {
            try? fm.removeItem(at: home.appendingPathComponent(name))
        }
        let temp = home.appendingPathComponent(rebuildPrefix + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: temp) }
        do { _ = try MemoryStore(home: temp, writable: true, automaticallySyncSearch: false) }
        let target = temp.appendingPathComponent("memory.sqlite")
        let copied: Salvage.Result
        do {
            let salvage = try Salvage(from: file, to: target)
            copied = try salvage.run(lines: lines, now: now)
        }
        guard examine(temp).health == .sound else { throw MemError.database("rebuilt history failed its check") }
        // Into place. A damaged file that lost rows is kept first, as a second name for the same file, so there is never a
        // moment without a history file (a crash here leaves the old one in place and the note: the next launch repeats).
        var folder: URL?
        if !copied.whole {
            let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
            var candidate = home.appendingPathComponent(copyPrefix + " " + stamp, isDirectory: true)
            var suffix = 2
            while (try? candidate.checkResourceIsReachable()) == true {
                candidate = home.appendingPathComponent("\(copyPrefix) \(stamp) \(suffix)", isDirectory: true); suffix += 1
            }
            try fm.createDirectory(at: candidate, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            if link(file.path, candidate.appendingPathComponent("memory.sqlite").path) != 0 {
                do { try fm.copyItem(at: file, to: candidate.appendingPathComponent("memory.sqlite")) }
                catch { try? fm.removeItem(at: candidate); throw error }
            }
            folder = candidate
        }
        // A journal beside the old file is never left for the new one to replay: it goes with the kept copy, or away.
        var moved: [String] = []
        do {
            for name in companions {
                var info = stat()
                guard lstat(home.appendingPathComponent(name).path, &info) == 0 else { continue }
                if let folder { try fm.moveItem(at: home.appendingPathComponent(name), to: folder.appendingPathComponent(name)); moved.append(name) }
                else { try fm.removeItem(at: home.appendingPathComponent(name)) }
            }
            guard rename(target.path, file.path) == 0 else { throw MemError.database("rebuilt history could not be put in place") }
        } catch {
            if let folder {
                for name in moved { try? fm.moveItem(at: folder.appendingPathComponent(name), to: home.appendingPathComponent(name)) }
                try? fm.removeItem(at: folder)
            }
            throw error
        }
        let dir = open(home.path, O_RDONLY | O_CLOEXEC)
        if dir >= 0 { fsync(dir); close(dir) }
        return Repair(whole: copied.whole, copy: folder, keptChoices: copied.keptChoices, keptIdentity: copied.keptIdentity,
                      rows: copied.rows, unreadable: copied.unreadable, rescued: copied.rescued)
    }

    /// The damaged files kept beside the history (folders "Damaged history …"), oldest first.
    public static func damagedCopies(home: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []).filter { $0.hasPrefix(copyPrefix) }.sorted()
            .map { home.appendingPathComponent($0, isDirectory: true) }
    }
    /// Deletes every kept damaged file (Backup and restore's button). Throws when one couldn't be deleted.
    public static func deleteDamagedCopies(home: URL) throws {
        for folder in damagedCopies(home: home) { try FileManager.default.removeItem(at: folder) }
    }

    /// Whether every line of SQLite's whole-file check is about something no row lives in: pages lost from the free list,
    /// the free list itself, or an index (the new file builds its own). Anything else might have hidden rows. (One result
    /// row of the check can hold several lines.)
    static func onlyIndexOrFreeSpace(_ lines: [String], indexRoots: Set<Int64>, indexNames: Set<String>) -> Bool {
        lines.flatMap { $0.components(separatedBy: "\n") }.allSatisfy { line in
            if line == "ok" || line.isEmpty || line.hasPrefix("*** in database") || line.hasPrefix("Freelist:") { return true }
            if line.hasPrefix("Page "), line.hasSuffix(": never used") || line.hasSuffix(" is never used") { return true }
            for lead in ["wrong # of entries in index ", "non-unique entry in index "] where line.hasPrefix(lead) {
                return indexNames.contains(String(line.dropFirst(lead.count)))
            }
            if line.hasPrefix("row "), let range = line.range(of: " missing from index ") { return indexNames.contains(String(line[range.upperBound...])) }
            guard line.hasPrefix("Tree ") else { return false }
            let digits = line.dropFirst(5).prefix { $0.isNumber }
            guard let root = Int64(digits) else { return false }
            return indexRoots.contains(root)
        }
    }
}

/// Copies what SQLite can read of a damaged history into a new, empty history of this build's own making.
private final class Salvage {
    struct Result {
        var whole: Bool
        var keptChoices: Bool
        var keptIdentity: Bool
        var rows: Int
        var unreadable: Int
        var rescued: Int
    }
    private var src: OpaquePointer?
    private var dst: OpaquePointer?
    private var rows = 0
    /// Rows refused (garbled, or breaking a key) and places the walk couldn't read through.
    private var unreadable = 0
    /// A table, or the list of tables, couldn't be read or copied whole.
    private var partial = false
    private var keptChoices = false, keptIdentity = false
    private var probes = 0
    /// Every deletion (tombstone) came across, from its table or, where the table's pages couldn't be read, from its index.
    private var deletionsWhole = false
    /// The moments table couldn't be walked whole: its pages are read directly too (`rescue`).
    private var recordsDamaged = false
    private(set) var rescued = 0
    private let source: URL

    init(from source: URL, to target: URL) throws {
        self.source = source
        // Read-write only so a crash journal is rolled back as any open would; nothing is written (query_only).
        if sqlite3_open_v2(source.path, &src, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            sqlite3_close(src); src = nil
            guard sqlite3_open_v2(source.path, &src, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                sqlite3_close(src); src = nil; throw MemError.database("history could not be opened to repair")
            }
        }
        sqlite3_busy_timeout(src, 1500)
        sqlite3_exec(src, "PRAGMA query_only=1", nil, nil, nil)
        guard sqlite3_open_v2(target.path, &dst, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(dst); dst = nil; throw MemError.database("new history could not be opened")
        }
        try exec(dst, "PRAGMA secure_delete=ON")
        try exec(dst, "PRAGMA synchronous=FULL")
    }
    deinit { sqlite3_close(src); sqlite3_close(dst) }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw MemError.database("repair write failed (code \(sqlite3_extended_errcode(db)))") }
    }
    private static func quote(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    /// Rows of a query as text (nil for NULL); stops at the first error, which is returned with what was read.
    private func all(_ db: OpaquePointer?, _ sql: String) -> (rows: [[String?]], failed: Bool) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { sqlite3_finalize(stmt); return ([], true) }
        defer { sqlite3_finalize(stmt) }
        var result: [[String?]] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { return (result, false) }
            guard status == SQLITE_ROW else { return (result, true) }
            result.append((0..<sqlite3_column_count(stmt)).map { i in sqlite3_column_text(stmt, i).map { String(cString: $0) } })
        }
    }

    func run(lines: [String], now: Date) throws -> Result {
        // A history a newer DayDream saved is never rewritten in this build's format.
        if let version = all(src, "PRAGMA user_version").rows.first?.first.flatMap({ $0 }).flatMap({ Int32($0) }), version > MemoryStore.formatVersion {
            throw MemError.invalid(MemoryStore.newerStore)
        }
        let schema = all(src, "SELECT type, name, tbl_name, sql, rootpage FROM sqlite_master")
        if schema.failed { partial = true }
        let indexRoots = Set(schema.rows.filter { $0[0] == "index" }.compactMap { $0[4].flatMap { Int64($0) } })
        let indexNames = Set(schema.rows.filter { $0[0] == "index" }.compactMap { $0[1] })
        let existing = Set(all(dst, "SELECT name FROM sqlite_master").rows.compactMap { $0[0] })
        var whole = false
        try exec(dst, "BEGIN IMMEDIATE")
        do {
            // The new history's own first rows, for what the damaged one can't give back.
            let defaults = Dictionary(all(dst, "SELECT id, body FROM metadata").rows.compactMap { row in row[0].flatMap { id in row[1].map { (id, $0) } } },
                                      uniquingKeysWith: { a, _ in a })
            let tables = schema.rows.filter { $0[0] == "table" }.compactMap { $0[1] }
                .filter { !$0.hasPrefix("sqlite_") || $0 == "sqlite_sequence" }
            for table in tables {
                if !existing.contains(table) {
                    guard let sql = schema.rows.first(where: { $0[0] == "table" && $0[1] == table })?[3], sqlite3_exec(dst, sql, nil, nil, nil) == SQLITE_OK else {
                        partial = true; continue
                    }
                }
                let whole = try copy(table)
                if table == "tombstones" { deletionsWhole = whole }
            }
            // The list of deletions is what keeps a deleted moment from coming back (the rescue below, a restore of an older
            // backup). Where its table's pages couldn't be read, its index still holds every id (gold G45 final review).
            if !deletionsWhole { deletionsWhole = try recoverDeletions(schema.rows) }
            // Indexes, triggers and views of tables only the damaged history had.
            for row in schema.rows where row[0] != "table" {
                guard let name = row[1], let sql = row[3], !existing.contains(name) else { continue }
                if sqlite3_exec(dst, sql, nil, nil, nil) != SQLITE_OK { partial = true }
            }
            let recordsMissed = recordsDamaged || partial || !tables.contains("records")
            if recordsMissed || !keptChoices || !keptIdentity { try rescue(records: recordsMissed) }
            let kept = Set(all(dst, "SELECT id FROM metadata").rows.compactMap { $0[0] })
            if !keptChoices || !kept.contains("policy") {
                keptChoices = false
                try exec(dst, "DELETE FROM metadata WHERE id IN ('policy','native-typing-choice-pending-v1')")
                for id in ["policy", "native-typing-choice-pending-v1"] { if let body = defaults[id] { try insertMetadata(id, body) } }
            }
            if !keptIdentity || !kept.contains("core_store_id") {
                keptIdentity = false
                try exec(dst, "DELETE FROM metadata WHERE id='core_store_id'")
                try insertMetadata("core_store_id", defaults["core_store_id"] ?? UUID().uuidString)
            }
            // The choices or the identity couldn't be kept: AI apps were let in under choices the new history doesn't have
            // (apps left out now show). They connect again, with setup, as on a new history (gold G45 final review).
            if !keptChoices || !keptIdentity {
                try exec(dst, "DELETE FROM grants")
                try exec(dst, "DELETE FROM receipts")
                try exec(dst, "DELETE FROM metadata WHERE id='\(MemoryStore.typedWordsRequestsID)'")
            }
            // Some deletions couldn't be read back at all: no restore brings back a moment from before now.
            if !deletionsWhole { try insertMetadata(MemoryStore.deletionsUnknownBefore, iso(now)) }
            // What AI apps and the search index read must be read again (MemoryStore.invalidateDisclosure).
            try insertMetadata("action_read_epoch", UUID().uuidString)
            try insertMetadata("disclosure_revision", UUID().uuidString)
            try exec(dst, "DELETE FROM metadata WHERE id='search_cursor'")
            try exec(dst, "PRAGMA user_version=\(MemoryStore.formatVersion)")
            whole = !partial && unreadable == 0 && keptChoices && keptIdentity && deletionsWhole
                && StoreIntegrity.onlyIndexOrFreeSpace(lines, indexRoots: indexRoots, indexNames: indexNames)
            // Something was lost (the damaged file is kept, and maybe the choices): what the app says about it goes into
            // the new file, so it takes the old one's place with it in one rename and is said at the next open, however
            // the launch that repaired it ends (MemoryStore.unsaidRepair). A repair an earlier launch never said, carried
            // over in the damaged file's metadata, stays said: choices it couldn't keep are still not the person's.
            if !whole {
                let earlier = all(dst, "SELECT body FROM metadata WHERE id='\(StoreIntegrity.unsaidRepairID)'").rows.first?.first.flatMap { $0 }
                let unsaid = StoreIntegrity.UnsaidBody(keptChoices: keptChoices && earlier.map(StoreIntegrity.unsaidKeptChoices) != false)
                try insertMetadata(StoreIntegrity.unsaidRepairID, try json(unsaid))
            }
            try exec(dst, "COMMIT")
        } catch {
            sqlite3_exec(dst, "ROLLBACK", nil, nil, nil)
            throw error
        }
        return Result(whole: whole, keptChoices: keptChoices, keptIdentity: keptIdentity, rows: rows, unreadable: unreadable, rescued: rescued)
    }
    private func insertMetadata(_ id: String, _ body: String) throws {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(dst, "INSERT OR REPLACE INTO metadata(id, body) VALUES(?, ?)", -1, &stmt, nil) == SQLITE_OK else {
            throw MemError.database("repair write failed (code \(sqlite3_extended_errcode(dst)))")
        }
        sqlite3_bind_text(stmt, 1, id, -1, Self.transient); sqlite3_bind_text(stmt, 2, body, -1, Self.transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw MemError.database("repair write failed (code \(sqlite3_extended_errcode(dst)))") }
    }

    /// One table, in rowid order. Where SQLite can't read on, the walk finds the next row it can (doubling the jump,
    /// then halving back), so one damaged page costs only the rows on it. True when every row came across.
    @discardableResult
    private func copy(_ table: String) throws -> Bool {
        let q = Self.quote(table)
        let info = all(src, "PRAGMA table_info(\(q))")
        let target = Set(all(dst, "PRAGMA table_info(\(q))").rows.compactMap { $0[1] })
        let columns = info.rows.compactMap { $0[1] }
        guard !info.failed, !columns.isEmpty, columns.allSatisfy(target.contains) else { partial = true; return false }
        // An INTEGER PRIMARY KEY column is the rowid itself; otherwise the rowid is copied too, as it was.
        let keys = info.rows.filter { ($0[5].flatMap { Int($0) } ?? 0) > 0 }
        let aliased = keys.count == 1 && keys[0][2]?.uppercased() == "INTEGER"
        let list = columns.map(Self.quote).joined(separator: ", ")
        try exec(dst, "DELETE FROM \(q)")
        var insert: OpaquePointer?
        defer { sqlite3_finalize(insert) }
        let names = (aliased ? "" : "rowid, ") + list
        let marks = Array(repeating: "?", count: columns.count + (aliased ? 0 : 1)).joined(separator: ", ")
        guard sqlite3_prepare_v2(dst, "INSERT INTO \(q)(\(names)) VALUES(\(marks))", -1, &insert, nil) == SQLITE_OK, let insert else {
            partial = true; return false
        }
        var select: OpaquePointer?
        defer { sqlite3_finalize(select) }
        guard sqlite3_prepare_v2(src, "SELECT rowid, \(list) FROM \(q) WHERE rowid >= ? ORDER BY rowid", -1, &select, nil) == SQLITE_OK, let select else {
            partial = true; return false
        }
        let index = Dictionary(columns.enumerated().map { ($1, Int32($0 + 1)) }, uniquingKeysWith: { a, _ in a })
        probes = 0
        let before = unreadable
        var lost = false
        // `from`: the next rowid to read, inclusive.
        var from = Int64.min
        walk: while true {
            sqlite3_reset(select)
            sqlite3_bind_int64(select, 1, from)
            while true {
                let status = sqlite3_step(select)
                if status == SQLITE_DONE { break walk }
                guard status == SQLITE_ROW else {
                    unreadable += 1
                    // The next row's rowid reads but its content doesn't: skip just that row. Else find where reading
                    // can go on.
                    switch probe(table, from) {
                    case .row(let rowid):
                        guard rowid < Int64.max else { break walk }
                        from = rowid + 1; continue walk
                    case .end: break walk
                    case .failed:
                        guard let next = nextReadable(table, from) else { partial = true; lost = true; break walk }
                        from = next; continue walk
                    }
                }
                let rowid = sqlite3_column_int64(select, 0)
                guard rowid < Int64.max else { break walk }
                from = rowid + 1
                guard valid(table, select, index, columns.count) else { unreadable += 1; continue }
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                var slot: Int32 = 1
                if !aliased { sqlite3_bind_value(insert, slot, sqlite3_column_value(select, 0)); slot += 1 }
                for i in 1...Int32(columns.count) { sqlite3_bind_value(insert, slot, sqlite3_column_value(select, i)); slot += 1 }
                let written = sqlite3_step(insert)
                if written == SQLITE_DONE { rows += 1; continue }
                let primary = sqlite3_extended_errcode(dst) & 0xff
                // A garbled row that breaks a key or a NOT NULL is refused; anything else (a full disk) stops the repair.
                guard primary == SQLITE_CONSTRAINT || primary == SQLITE_MISMATCH else {
                    throw MemError.database("repair write failed (code \(sqlite3_extended_errcode(dst)))")
                }
                unreadable += 1
            }
        }
        if table == "records", unreadable > before || lost { recordsDamaged = true }
        return !lost && unreadable == before
    }
    private enum Probe { case row(Int64), end, failed }
    /// The first row at or after `rowid`, reading only its rowid.
    private func probe(_ table: String, _ rowid: Int64) -> Probe {
        probes += 1
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(src, "SELECT rowid FROM \(Self.quote(table)) WHERE rowid >= ? ORDER BY rowid LIMIT 1", -1, &stmt, nil) == SQLITE_OK else { return .failed }
        sqlite3_bind_int64(stmt, 1, rowid)
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return .row(sqlite3_column_int64(stmt, 0))
        case SQLITE_DONE: return .end
        default: return .failed
        }
    }
    /// The nearest rowid past `from` from which the table reads again (nil: none within reach). Doubles the jump until a
    /// read works, then halves back. The walk starts at the lowest rowid there could be; every rowid DayDream writes is
    /// 1 or more, so from there the search starts at 1 (gold G45 final review: from `Int64.min` the doubling never left
    /// the negative rowids before it overflowed, and a table whose first page was damaged was dropped whole).
    private func nextReadable(_ table: String, _ from: Int64) -> Int64? {
        var low = from, base = from, step: Int64 = 1
        var high: Int64?
        if from < 1 {
            if case .failed = probe(table, 1) { low = 1; base = 1 } else { high = 1 }
        }
        while high == nil {
            guard probes < 4096 else { return nil }
            let (x, over) = base.addingReportingOverflow(step)
            if over { return nil }
            if case .failed = probe(table, x) { low = x } else { high = x }
            let (next, again) = step.multipliedReportingOverflow(by: 2)
            if again, high == nil { return nil }
            step = next
        }
        guard var high else { return nil }
        // `high - low` can be wider than Int64 holds (from `Int64.min`): the gap is measured unsigned.
        while UInt64(bitPattern: high &- low) > 1, probes < 4096 {
            let mid = low &+ Int64(bitPattern: UInt64(bitPattern: high &- low) / 2)
            if case .failed = probe(table, mid) { low = mid } else { high = mid }
        }
        return high
    }
    /// The deletions whose table rows couldn't be read, from the table's own index of their ids (it holds every id, and
    /// reading it never touches the table's pages). True when the whole index read.
    private func recoverDeletions(_ schema: [[String?]]) throws -> Bool {
        var names = schema.filter { $0[0] == "index" && $0[2] == "tombstones" }.compactMap { $0[1] }
        if names.isEmpty { names = ["sqlite_autoindex_tombstones_1"] }
        var insert: OpaquePointer?
        defer { sqlite3_finalize(insert) }
        guard sqlite3_prepare_v2(dst, "INSERT OR IGNORE INTO tombstones(id) VALUES(?)", -1, &insert, nil) == SQLITE_OK, let insert else { return false }
        for name in names {
            var select: OpaquePointer?
            defer { sqlite3_finalize(select) }
            guard sqlite3_prepare_v2(src, "SELECT id FROM tombstones INDEXED BY \(Self.quote(name)) ORDER BY id", -1, &select, nil) == SQLITE_OK, let select else { continue }
            while true {
                let status = sqlite3_step(select)
                if status == SQLITE_DONE { return true }
                guard status == SQLITE_ROW else { break }
                guard sqlite3_column_type(select, 0) == SQLITE_TEXT else { continue }
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                sqlite3_bind_value(insert, 1, sqlite3_column_value(select, 0))
                guard sqlite3_step(insert) == SQLITE_DONE else { throw MemError.database("repair write failed (code \(sqlite3_extended_errcode(dst)))") }
            }
        }
        return false
    }
    /// Rows SQLite can't reach through its own tables (under a damaged page of a table's tree, or a damaged list of
    /// tables): their own pages may be whole. Every table leaf page of the file is read directly (never a page on the free
    /// list, as far as it reads). A cell becomes a moment only when it is exactly one: three text columns, the body's
    /// fingerprint is the revision and its id is the id; never one already copied or one deleted (every deletion, by the
    /// person or by the kept period, leaves a tombstone; `secure_delete` zeroes what it removed). Apps and sites left out
    /// hide moments rather than delete them, as the table itself does. The choices and the identity, when the metadata
    /// table couldn't be read, come back only when exactly one whole copy of each is found.
    private func rescue(records: Bool) throws {
        let fd = open(source.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return }
        func read(_ offset: Int, _ count: Int) -> [UInt8]? {
            var buffer = [UInt8](repeating: 0, count: count)
            let got = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
            return got == count ? buffer : nil
        }
        func be16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) << 8 | Int(b[o + 1]) }
        func be32(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) }
        let header = read(0, 100)
        var size = header.map { be16($0, 16) } ?? 0
        if size == 1 { size = 65536 }
        if size < 512 || size > 65536 || size & (size - 1) != 0 { size = 4096 }
        let usable = size - Int(header?[20] ?? 0)
        guard usable >= 480 else { return }
        let count = Int(info.st_size) / size
        guard count > 0 else { return }
        // The free list, as far as it reads: its pages hold nothing live.
        var free = Set<Int>()
        var trunk = header.map { be32($0, 32) } ?? 0
        while trunk > 0, trunk <= count, !free.contains(trunk), free.count <= count, let page = read((trunk - 1) * size, size) {
            free.insert(trunk)
            let leaves = be32(page, 4)
            guard leaves <= usable / 4 - 2 else { break }
            for j in 0..<leaves { free.insert(be32(page, 8 + 4 * j)) }
            trunk = be32(page, 0)
        }
        func varint(_ b: [UInt8], _ at: inout Int, _ end: Int) -> Int64? {
            var value: UInt64 = 0
            for i in 0..<9 {
                guard at < end else { return nil }
                let byte = b[at]; at += 1
                if i == 8 { value = value << 8 | UInt64(byte); return Int64(bitPattern: value) }
                value = value << 7 | UInt64(byte & 0x7f)
                if byte & 0x80 == 0 { return Int64(bitPattern: value) }
            }
            return nil
        }
        // A cell's whole payload: its local part, then its overflow pages.
        func payload(_ page: [UInt8], _ at: Int, _ total: Int) -> [UInt8]? {
            let most = usable - 35, least = (usable - 12) * 32 / 255 - 23
            var local = total
            if total > most { let k = least + (total - least) % (usable - 4); local = k <= most ? k : least }
            guard at + local <= usable else { return nil }
            var bytes = Array(page[at..<(at + local)])
            guard total > local else { return bytes }
            guard at + local + 4 <= usable else { return nil }
            var next = be32(page, at + local)
            var seen = Set<Int>()
            while bytes.count < total {
                guard next > 0, next <= count, seen.insert(next).inserted, let overflow = read((next - 1) * size, size) else { return nil }
                bytes += overflow[4..<min(usable, 4 + total - bytes.count)]
                next = be32(overflow, 0)
            }
            return bytes
        }
        func record(_ bytes: [UInt8]) -> [String]? {
            var at = 0
            guard let length = varint(bytes, &at, bytes.count), length > 0, Int(length) <= bytes.count else { return nil }
            var types: [Int64] = []
            while at < Int(length) { guard let type = varint(bytes, &at, Int(length)) else { return nil }; types.append(type) }
            guard (2...3).contains(types.count) else { return nil }
            var data = Int(length)
            var values: [String] = []
            for type in types {
                guard type >= 13, type % 2 == 1 else { return nil }
                let n = Int((type - 13) / 2)
                guard data + n <= bytes.count, let text = String(bytes: bytes[data..<(data + n)], encoding: .utf8) else { return nil }
                values.append(text); data += n
            }
            return values
        }
        /// Every live-looking table leaf cell whose columns are all text.
        func cells(_ each: ([String]) throws -> Void) rethrows {
            for number in 1...count where !free.contains(number) {
                guard let page = read((number - 1) * size, size) else { continue }
                let start = number == 1 ? 100 : 0
                guard page[start] == 0x0d else { continue }
                let cells = be16(page, start + 3), pointers = start + 8
                guard pointers + 2 * cells <= usable else { continue }
                for i in 0..<cells {
                    var at = be16(page, pointers + 2 * i)
                    guard at >= pointers + 2 * cells, at < usable, let total = varint(page, &at, usable), total > 0, total < 1 << 28,
                          varint(page, &at, usable) != nil, let bytes = payload(page, at, Int(total)), let values = record(bytes) else { continue }
                    try each(values)
                }
            }
        }
        if !keptChoices || !keptIdentity {
            var found: [String: Set<String>] = [:]
            cells { values in
                guard values.count == 2, ["policy", "core_store_id", "native-typing-choice-pending-v1"].contains(values[0]) else { return }
                found[values[0], default: []].insert(values[1])
            }
            if !keptChoices, let policies = found["policy"], policies.count == 1, let policy = policies.first,
               (try? decode(PrivacySettings.self, policy)) != nil {
                try insertMetadata("policy", policy)
                try exec(dst, "DELETE FROM metadata WHERE id='native-typing-choice-pending-v1'")
                if let pending = found["native-typing-choice-pending-v1"], pending.count == 1, let marker = pending.first {
                    try insertMetadata("native-typing-choice-pending-v1", marker)
                }
                keptChoices = true
            }
            if !keptIdentity, let identities = found["core_store_id"], identities.count == 1, let identity = identities.first, UUID(uuidString: identity) != nil {
                try insertMetadata("core_store_id", identity)
                keptIdentity = true
            }
        }
        guard records else { return }
        var known: OpaquePointer?, insert: OpaquePointer?
        defer { sqlite3_finalize(known); sqlite3_finalize(insert) }
        guard sqlite3_prepare_v2(dst, "SELECT (SELECT count(*) FROM records WHERE id=?1) + (SELECT count(*) FROM tombstones WHERE id=?1)", -1, &known, nil) == SQLITE_OK,
              sqlite3_prepare_v2(dst, "INSERT INTO records(id, body, revision) VALUES(?, ?, ?)", -1, &insert, nil) == SQLITE_OK else { return }
        try cells { values in
            guard values.count == 3 else { return }
            let (id, body, revision) = (values[0], values[1], values[2])
            guard Self.moment(id, body, revision) else { return }
            sqlite3_reset(known); sqlite3_bind_text(known, 1, id, -1, Self.transient)
            guard sqlite3_step(known) == SQLITE_ROW, sqlite3_column_int64(known, 0) == 0 else { return }
            sqlite3_reset(insert)
            for (slot, value) in [id, body, revision].enumerated() { sqlite3_bind_text(insert, Int32(slot + 1), value, -1, Self.transient) }
            if sqlite3_step(insert) == SQLITE_DONE { rescued += 1; rows += 1 }
            else if sqlite3_extended_errcode(dst) & 0xff != SQLITE_CONSTRAINT {
                throw MemError.database("repair write failed (code \(sqlite3_extended_errcode(dst)))")
            }
        }
    }
    /// A moment is whole: its body's fingerprint (`fingerprint`, SHA-256 in lowercase hex) is its revision, and the body's
    /// id is its id.
    static func moment(_ id: String, _ body: String, _ revision: String) -> Bool {
        let hex = Array(revision.utf8)
        guard hex.count == 64 else { return false }
        func nibble(_ c: UInt8) -> UInt8? { c >= 48 && c <= 57 ? c - 48 : c >= 97 && c <= 102 ? c - 87 : nil }
        var i = 0
        for byte in SHA256.hash(data: Data(body.utf8)) {
            guard let high = nibble(hex[i]), let low = nibble(hex[i + 1]), high << 4 | low == byte else { return false }
            i += 2
        }
        // `json` writes keys sorted and slashes as they are, so the id is usually there as written; else parse.
        if body.contains("\"id\":\"" + id + "\"") { return true }
        return ((try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any])?["id"] as? String == id
    }
    /// Text as SQLite wrote it is valid UTF-8 (DayDream only writes Swift strings); a garbled page often isn't. A moment
    /// must match its own fingerprint and id; the choices and identity must read back whole.
    private func valid(_ table: String, _ select: OpaquePointer, _ index: [String: Int32], _ count: Int) -> Bool {
        func text(_ i: Int32) -> String? {
            guard sqlite3_column_type(select, i) == SQLITE_TEXT, let bytes = sqlite3_column_text(select, i) else { return nil }
            return String(bytes: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(select, i))), encoding: .utf8)
        }
        for i in 1...Int32(count) where sqlite3_column_type(select, i) == SQLITE_TEXT {
            guard text(i) != nil else { return false }
        }
        func column(_ name: String) -> String? { index[name].flatMap(text) }
        switch table {
        case "records":
            guard let id = column("id"), let body = column("body"), let revision = column("revision") else { return false }
            return Self.moment(id, body, revision)
        case "metadata":
            guard let id = column("id"), let body = column("body") else { return false }
            switch id {
            case "policy":
                guard (try? decode(PrivacySettings.self, body)) != nil else { return false }
                keptChoices = true
            case "core_store_id":
                guard UUID(uuidString: body) != nil else { return false }
                keptIdentity = true
            default: break
            }
            return true
        default:
            return true
        }
    }
}

extension MemoryStore {
    /// The history's format (SQLite `user_version`) this build reads and writes (gold G61). A later build that changes
    /// the format so that this one would misread it raises the number; this build then refuses that history with
    /// `newerStore` instead of reading it wrongly. Histories from before this check are 0, the same format as 1.
    public static let formatVersion: Int32 = 1
    /// Why a history can't open: a newer DayDream saved it. The app and AI apps show these words.
    public static let newerStore = "Your history was saved by a newer DayDream. Update DayDream to open it."
    /// Metadata a repair leaves when it couldn't read back every deletion (gold G45 final review): the time of the repair.
    /// A restore never adds a moment captured at or before it, since any of those may be one the person deleted.
    static let deletionsUnknownBefore = "deletions_unknown_before"
    /// Every open checks the format first. A writable open marks an older history with this build's format, and only
    /// when it can at once: an open never waits on, or fails behind, another connection's write for it.
    func checkFormat() throws {
        let found = Int32(try rows("PRAGMA user_version").first?.first ?? "0") ?? 0
        guard found <= Self.formatVersion else { throw MemError.invalid(Self.newerStore) }
        if writable, found < Self.formatVersion { try? exec("PRAGMA user_version=\(Self.formatVersion)") }
    }
}
