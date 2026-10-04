import Foundation
import CSQLite

/// One SQLite transaction boundary shared by app, CLI and local readers.
/// Never opens a legacy collector's home. Default files are private to this user.
public final class MemoryStore {
    private var db: OpaquePointer?
    /// gold r3-store: knows when the main thread waits for it (StoreWait.swift).
    let lock = StoreLock()
    /// This connection's busy handler (StoreWait.swift): SQLite's waits, bounded for the main thread's capture paths.
    private lazy var busyWait = BusyWait(patienceMs: Double(busyMilliseconds), lock: lock)
    /// The typed-text vault, attached only in the DayDream app process. Every
    /// other process (CLI, MCP, remote) runs without one and never reads words.
    private var vault: TypedTextVault?
    /// One bounded native narrative prefix; transaction lock protects it, never serialized.
    private var typedNarrativeCarry: TypedNarrativeCarry?
    private var typedNarrativeDataVersion: String?
    private var typedNarrativePreservingDepth=0
    private var typedNarrativeMaintenanceActive = false
    private var typedNarrativeMaintenanceScope:TypedNarrativeMaintenanceScope = .summary
    private var typedNarrativeMaintenanceStatement: String?
    private var typedNarrativeAuthorityAvailable = true
    var attachedVault: TypedTextVault? { lock.lock(); defer { lock.unlock() }; return vault }
    /// The latest clock this store instance used to open or expire typed
    /// words. Words hidden once stay hidden if the clock goes back.
    var typedClockSeen: Date?
    /// The high-water last read from or written to `metadata` by this instance.
    var typedClockStored: Date?
    /// This instance found no build 4 plain-text typed row left (review G59: the hourly expiry scanned every record
    /// for them). Memory only: a new process scans again, and so does the next expiry after an import.
    var legacyTypedClear = false
    /// The typed clock reset (`typed-clock-reset-v1`) this instance already knows (review G44).
    var typedClockResetSeen: String?
    /// This instance saw the time index day reads go through (`timeIndexed`, ActivityLayers.swift). Guarded by `lock`.
    var timeIndexSeen = false
    public let writable: Bool
    public let home: URL
    /// writePending's check of the whole table (see there); guarded by `summaryLock`, which writePending holds
    /// throughout (the store's `lock` only for each of its short transactions).
    private var summaryScan = SummaryScan()
    private var summaryQueueReady = false
    private let summaryLock = NSLock()
    private let automaticallySyncSearch: Bool
    /// A read-only store opened in a process that also has this database open for writing (the app reads its days,
    /// search and settings next to its recorder). See `init`.
    let inProcessReader: Bool
    /// This store's entry in `writers` (writable stores only, once open).
    private var writerKey: String?
    /// Who does launch's one-time work on a history an earlier DayDream saved: the time indexes (`timeIndexes`) and, in
    /// the owner build, the website typing settle (`settleWebsiteTypingRows`). Each takes seconds on a long history.
    public enum LaunchWork: Sendable, Equatable {
        /// This open builds any time index the history lacks, as every open always has (a store that can't take one,
        /// another connection busy for 1.5 s or an unreadable row, still opens; the next open tries again).
        case here
        /// Launch's preparation (HistoryPreparation.prepare), off the main thread before the app's model exists: this
        /// open builds nothing, and the preparation then builds what the history lacks, waiting for AI apps' reads.
        case preparation
        /// The app model's open after launch prepared the history (on the main thread): nothing is built here, and
        /// TypedTextLaunch leaves the website settle to the preparation too. Whatever the preparation couldn't finish
        /// waits for the next launch's preparation, never the main thread (gold r2-store-perf review round 1). The app's
        /// other writable opens of the history it holds (MemoryFlowStore: imports, onboarding) build nothing either.
        case prepared
    }
    public let launchWork: LaunchWork
    public init(home: URL, writable: Bool = false, automaticallySyncSearch: Bool = true, launchWork: LaunchWork = .here) throws {
        self.home = home; self.writable = writable; self.automaticallySyncSearch=automaticallySyncSearch; self.launchWork = launchWork
        if writable {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let path = home.appendingPathComponent("memory.sqlite").path
        guard writable || FileManager.default.fileExists(atPath: path) else { throw MemError.missing }
        // A reader in a process that also writes this file opens READWRITE with PRAGMA query_only. Opened
        // SQLITE_OPEN_READONLY, a read in progress holds the process's lock on the file through a descriptor that can't
        // take the write lock, so the recorder's next write fails at once with SQLITE_IOERR_LOCK (3850) instead of
        // waiting its turn. It still never writes: `writable` stays false (every write path refuses) and SQLite refuses
        // too. Every other reader (the CLI, MCP, another process, a legacy home) opens SQLITE_OPEN_READONLY as before.
        var reader = false
        if !writable, Self.writerOpen(path) {
            if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
               sqlite3_exec(db, "PRAGMA query_only=1", nil, nil, nil) == SQLITE_OK {
                reader = true
            } else { sqlite3_close(db); db = nil }
        }
        inProcessReader = reader
        if !reader {
            guard sqlite3_open_v2(path, &db, writable ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX : SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw MemError.database("open failed") }
        }
        // This process's readers know of a writer before its first write (gold r2-store-perf review round 1: registered
        // only at the end, a reader opened meanwhile, during launch's index build, read through SQLITE_OPEN_READONLY and
        // the build failed at once with SQLITE_IOERR_LOCK). An init that throws from here on unregisters it (deinit).
        if writable { writerKey = Self.registerWriter(path) }
        busyWait.install(db)
        try checkFormat() // StoreIntegrity.swift: a history a newer DayDream saved is refused, not misread (G61).
        if writable {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            try exec("PRAGMA secure_delete=ON")
            try exec("PRAGMA synchronous=FULL")
            try exec("CREATE TABLE IF NOT EXISTS records(id TEXT PRIMARY KEY, body TEXT NOT NULL, revision TEXT NOT NULL)")
            try exec("CREATE TABLE IF NOT EXISTS summaries(id TEXT PRIMARY KEY, body TEXT NOT NULL, revision TEXT NOT NULL)")
            try exec("CREATE TABLE IF NOT EXISTS tombstones(id TEXT PRIMARY KEY)")
            try exec("CREATE TABLE IF NOT EXISTS metadata(id TEXT PRIMARY KEY, body TEXT NOT NULL)")
            try exec("CREATE TABLE IF NOT EXISTS grants(id TEXT PRIMARY KEY, body TEXT NOT NULL)")
            try exec("CREATE TABLE IF NOT EXISTS receipts(id TEXT PRIMARY KEY, body TEXT NOT NULL)")
            try exec("CREATE TABLE IF NOT EXISTS search_index_state(id TEXT PRIMARY KEY, revision TEXT NOT NULL)")
            try setupActionLayers()
            try setupMemoryControls()
            try setupTypedTables()
            if launchWork == .here { createTimeIndexes() }
            if try rows("SELECT body FROM metadata WHERE id='policy'").isEmpty {
                try transaction {
                    guard try rows("SELECT body FROM metadata WHERE id='policy'").isEmpty else {return}
                    let initial=PrivacySettings()
                    try exec("INSERT INTO metadata VALUES('policy',?)", [json(initial)])
                    try exec("INSERT INTO metadata VALUES('native-typing-choice-pending-v1',?)", [initial.revision])
                }
            }
        }
    }
    deinit { if let writerKey { Self.unregisterWriter(writerKey) }; sqlite3_close(db) }
    /// Writable stores open in this process, by file (device and inode, so every spelling of a path is the same file).
    private static let writersLock = NSLock()
    private static var writers: [String: Int] = [:]
    private static func fileKey(_ path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }
    private static func registerWriter(_ path: String) -> String? {
        guard let key = fileKey(path) else { return nil }
        writersLock.lock(); defer { writersLock.unlock() }
        writers[key, default: 0] += 1
        return key
    }
    private static func unregisterWriter(_ key: String) {
        writersLock.lock(); defer { writersLock.unlock() }
        if let count = writers[key], count > 1 { writers[key] = count - 1 } else { writers[key] = nil }
    }
    private static func writerOpen(_ path: String) -> Bool {
        guard let key = fileKey(path) else { return false }
        writersLock.lock(); defer { writersLock.unlock() }
        return writers[key] != nil
    }
    func scheduleSearchRefresh() { if automaticallySyncSearch { LocalSearchIndexer.schedule(store:self) } }
    /// The error for a failed SQLite call, keeping its code (the extended code, read before anything else runs on this
    /// connection). A momentary code (`momentary`) is its own case, `.busy`: the same statement can succeed a moment
    /// later. Never includes SQL, values or paths. SQLite saying the file itself is damaged (corrupt, not a database) is
    /// noted beside it for the next launch to repair (StoreIntegrity, G45).
    private func failure(_ what: String) -> MemError {
        let code = sqlite3_extended_errcode(db)
        if StoreIntegrity.isDamage(code) { StoreIntegrity.noteDamage(home) }
        return Self.failure(what, code: code)
    }
    static func failure(_ what: String, code: Int32) -> MemError {
        momentary(code) ? .busy("\(what) (code \(code))") : .database("\(what) (code \(code))")
    }
    /// SQLite codes that mean "not now", not "broken": nothing was written, and the same statement can succeed a moment
    /// later. Busy and locked with every extended code (another connection held the file past the busy timeout, or a
    /// table), and the lock family of I/O errors: a lock that couldn't be taken or checked (SQLITE_IOERR_LOCK 3850,
    /// _RDLOCK 2314, _CHECKRESERVEDLOCK 3594, _SHMLOCK 5130). Any other I/O error, a full disk or a corrupt file is not.
    public static func momentary(_ code: Int32) -> Bool {
        let primary = code & 0xff
        if primary == SQLITE_BUSY || primary == SQLITE_LOCKED { return true }
        return [3850, 2314, 3594, 5130].contains(code)
    }
    private func statement(_ sql: String, _ values: [String]) throws -> OpaquePointer {
        if typedNarrativeMaintenanceActive { typedNarrativeMaintenanceStatement = sql }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure("statement failed") }
        if sqlite3_stmt_readonly(stmt) == 0 {
            if typedNarrativeMaintenanceActive {
                if !typedNarrativeMaintenanceScope.statements.contains(sql) {discardTypedNarrativeCarry()}
            } else if typedNarrativePreservingDepth == 0 {discardTypedNarrativeCarry()}
        }
        for (i, value) in values.enumerated() {
            let result = value.withCString { sqlite3_bind_text(stmt, Int32(i+1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            if result != SQLITE_OK { let error = failure("binding failed"); sqlite3_finalize(stmt); throw error }
        }
        return stmt
    }
    func exec(_ sql: String, _ values: [String] = []) throws {
        lock.lock(); defer { lock.unlock() }
        do {
            guard writable else { throw MemError.denied }
            let stmt = try statement(sql, values); defer { sqlite3_finalize(stmt) }
            var status = sqlite3_step(stmt)
            while status == SQLITE_ROW { status = sqlite3_step(stmt) }
            guard status == SQLITE_DONE else { throw failure("write failed") }
        } catch {discardTypedNarrativeCarry();throw error}
    }
    func rows(_ sql: String, _ values: [String] = []) throws -> [[String]] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try statement(sql, values); defer { sqlite3_finalize(stmt) }
        var result: [[String]] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw failure("read failed") }
            result.append((0..<sqlite3_column_count(stmt)).map { i in sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" })
        }
    }
    func discardTypedNarrativeCarry() {
        lock.lock(); defer { lock.unlock() }
        typedNarrativeCarry = nil; typedNarrativeDataVersion = nil
    }
    func typedNarrativeMutationCount() -> Int64 { lock.lock();defer{lock.unlock()};return sqlite3_total_changes64(db) }
    func typedNarrativeMaintenanceAllowed(now: Date) throws -> Bool {
        lock.lock();defer{lock.unlock()}
        guard typedNarrativeAuthorityAvailable, legacyTypedClear, let carry=typedNarrativeCarry, attachedVault?.state == .ready,
              let version=try rows("PRAGMA data_version").first?.first,version == typedNarrativeDataVersion else {return false}
        let settings=try policy(),typed=try typedTextPolicy(),capture=try captureStatus(now:now)
        return settings.captureText && typed.consented && !typed.snoozed(now:now) && capture["state"] == "recording" &&
            carry.maintenanceAllowed(capturePolicy:settings.revision,typedPolicy:typed.revision,recordingEpoch:capture["epoch"],now:now)
    }
    /// Only writePending uses this scope; the private connection has no other authorizer.
    /// Inspect actual compiled actions too, so an unknown trigger cannot hide a source mutation.
    private func summaryMaintenanceTransaction<T>(now: Date, _ body: () throws -> T) throws -> T {
        try transaction(preservingTypedNarrative:true) {try observingTypedNarrativeMaintenance(now:now,body)}
    }
    /// Pending preparation only; paging and generated-note publication remain ordinary boundaries.
    func pendingNotePreparationTransaction<T>(now:Date,_ body:() throws ->T) throws ->T {
        try transaction(preservingTypedNarrative:true) {try observingTypedNarrativeMaintenance(now:now,scope:.pendingPrepare,body)}
    }
    /// Explicit fixed derivation phases only. No SQL is denied.
    /// The private connection has no other authorizer; this scope owns installation and reset under StoreLock.
    func observingTypedNarrativeMaintenance<T>(now:Date,scope:TypedNarrativeMaintenanceScope = .summary,_ body:() throws ->T) throws ->T {
            lock.lock();defer{lock.unlock()}
            guard !typedNarrativeMaintenanceActive else {discardTypedNarrativeCarry();throw MemError.invalid("Nested summary maintenance")}
            if try !typedNarrativeMaintenanceAllowed(now:now) {discardTypedNarrativeCarry()}
            let installed=sqlite3_set_authorizer(db,{ pointer,action,first,second,database,source in
                guard let pointer else {return SQLITE_OK}
                let store=Unmanaged<MemoryStore>.fromOpaque(pointer).takeUnretainedValue()
                func string(_ p:UnsafePointer<CChar>?) -> String? {p.map{String(cString:$0)}}
                if !store.typedNarrativeMaintenanceScope.permits(action:action,first:string(first),second:string(second),database:string(database),source:string(source),statement:store.typedNarrativeMaintenanceStatement) {
                    // Memory only. Never modifies the connection inside its SQLite callback.
                    store.typedNarrativeCarry=nil;store.typedNarrativeDataVersion=nil
                }
                return SQLITE_OK
            },Unmanaged.passUnretained(self).toOpaque())
            guard installed == SQLITE_OK else {discardTypedNarrativeCarry();typedNarrativeAuthorityAvailable=false;throw MemError.invalid("Summary observer unavailable")}
            typedNarrativeMaintenanceScope=scope
            typedNarrativeMaintenanceActive=true
            defer {
                typedNarrativeMaintenanceActive=false;typedNarrativeMaintenanceStatement=nil;typedNarrativeMaintenanceScope = .summary
                if sqlite3_set_authorizer(db,nil,nil) != SQLITE_OK {discardTypedNarrativeCarry();typedNarrativeAuthorityAvailable=false}
            }
            do {return try body()} catch {discardTypedNarrativeCarry();throw error}
    }
    func transaction<T>(preservingTypedNarrative: Bool = false, _ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        // Policy, expiry, Forget, import, and any other intervening write are boundaries.
        // Ingest, a fresh recording heartbeat, and the fixed observed summary-maintenance scope may preserve adjacent parts.
        if !preservingTypedNarrative { discardTypedNarrativeCarry() }
        if preservingTypedNarrative {typedNarrativePreservingDepth+=1}
        defer {if preservingTypedNarrative {typedNarrativePreservingDepth-=1}}
        do { try exec("BEGIN IMMEDIATE") }
        catch { discardTypedNarrativeCarry(); throw error }
        do { let result = try body(); try exec("COMMIT"); return result }
        catch { discardTypedNarrativeCarry(); try? exec("ROLLBACK"); throw error }
    }
    /// A consistent SQLite read transaction, including WAL. No raw database copy
    /// and no write permission required on the source connection.
    func readSnapshot<T>(_ body:() throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard sqlite3_exec(db,"BEGIN",nil,nil,nil)==SQLITE_OK else { throw MemError.database("snapshot begin failed") }
        do {
            let value=try body()
            guard sqlite3_exec(db,"COMMIT",nil,nil,nil)==SQLITE_OK else { throw MemError.database("snapshot finish failed") }
            return value
        } catch { sqlite3_exec(db,"ROLLBACK",nil,nil,nil);throw error }
    }
    public func policy() throws -> PrivacySettings {
        guard let raw = try rows("SELECT body FROM metadata WHERE id='policy'").first?.first else { throw MemError.database("missing policy") }
        return try decode(PrivacySettings.self, raw)
    }
    /// True while a newly created, unchanged policy still awaits its first
    /// typing answer. Setup shows typing Off either way; saving the apps page
    /// consumes the marker with the explicit answer. Missing legacy markers are
    /// ambiguous and must preserve the saved choice.
    public func nativeTypingChoicePending() throws -> Bool {
        let current=try policy()
        guard !current.captureText,current.typedConsentVersion == nil else {return false}
        return try rows("SELECT body FROM metadata WHERE id='native-typing-choice-pending-v1'").first?.first == current.revision
    }
    /// This store's identity (`core_store_id`), which names its typing keyring
    /// (`keyring-v1:<id>`). nil for a store opened before core setup.
    public func coreStoreID() throws -> String? {
        try rows("SELECT body FROM metadata WHERE id='core_store_id'").first?.first
    }
    /// Attaches the app's typed-text vault and reconciles it with what is
    /// sealed (see `reconcileTypedVault`). Never creates a key: turning typing
    /// on is `setUpTypedVault`. Only writable stores take a vault.
    @discardableResult public func attachVault(_ typed: TypedTextVault, now: Date = Date()) throws -> TypedVaultState {
        lock.lock(); defer { lock.unlock() }
        guard writable else { throw MemError.denied }
        discardTypedNarrativeCarry()
        // The keyring belongs to this store only (dev, trial and real homes
        // never share or drop each other's keys).
        if let id = try rows("SELECT body FROM metadata WHERE id='core_store_id'").first?.first { try typed.bind(store: id) }
        vault = typed
        return try reconcileTypedVault(now: now)
    }
    @discardableResult public func ingest(_ evidence: Evidence, now: Date = Date(), expectedPolicyRevision:String?=nil, requireRecording:Bool=false, preserveExisting:Bool=false, expectedCaptureEpoch:String?=nil) throws -> Bool {
        defer { if automaticallySyncSearch { LocalSearchIndexer.schedule(store:self) } }
        do { return try transaction(preservingTypedNarrative: true) {
            let dataVersion = try rows("PRAGMA data_version").first?.first
            // Other connections' writes invalidate context without opening prior content.
            let previousNarrative = dataVersion != nil && dataVersion == typedNarrativeDataVersion ? typedNarrativeCarry : nil
            discardTypedNarrativeCarry()
            if evidence.browserVerification?.provider == "browser-extension-v3" {
                guard requireRecording,let revision=expectedPolicyRevision,let epoch=expectedCaptureEpoch,
                      revision==evidence.browserVerification?.policyRevision,epoch==evidence.browserVerification?.captureEpoch,
                      BrowserSafety.fresh(evidence,now:now) else {return false}
            }
            if let expectedPolicyRevision {
                guard try policy().revision == expectedPolicyRevision else { throw MemError.invalid("Capture policy changed before commit") }
            }
            if requireRecording { guard try captureStatus(now:now)["state"] == "recording" else { throw MemError.invalid("Capture is not recording") } }
            if let expectedCaptureEpoch {guard try captureStatus(now:now)["epoch"] == expectedCaptureEpoch else {throw MemError.invalid("Recording session changed before commit")}}
            // Safe typing C: typed words pass the store-side secret scrubber
            // first, while their lines are still lines. A unit that is only a
            // secret is dropped here and nothing is written.
            var incoming = evidence
            var contextPolicy: TypedTextPolicy?
            let recordingEpoch=evidence.kind == "keyboard.text_input" ? try captureStatus(now:now)["epoch"] : nil
            // Safe typing E/F: a typed row from an app the category policy
            // doesn't permit, or while typing is paused, is refused first.
            if evidence.kind == "keyboard.text_input" {
                guard try typedIngestPermitted(evidence, now: now) else { return false }
                contextPolicy = try typedTextPolicy()
            }
            if evidence.kind == "keyboard.text_input", !evidence.text.isEmpty {
                guard let scrubbed = TypedSecretScrubber.scrubbed(evidence, narrativePrefix: previousNarrative?.preceding(evidence, typedPolicy: contextPolicy?.revision ?? "", epoch: expectedCaptureEpoch, recordingEpoch: recordingEpoch, now: now)) else { return false }
                incoming = scrubbed
            }
            guard try rows("SELECT id FROM tombstones WHERE id=?", [evidence.id]).isEmpty,
                  var clean = Privacy.sanitized(incoming, settings: try policy(), now: now),
                  !["summary", "activity.note", "day.summary", "macmem.context"].contains(evidence.kind) else { return false }
            // A typed pointer is made here only, never taken from a caller.
            clean.typed = nil
            // Typed words in other history: Code app titles are scrubbed, and
            // search pages keep only the site while search typing is on.
            let typedPolicy = try contextPolicy ?? typedTextPolicy()
            clean = TypedHistoryScrub.apply(clean, searchTypingOn: typedPolicy.consented && typedPolicy.categories.searchAndAI)
            clean = TypedSecretScrubber.restoringOuterSpaces(from: evidence, sanitized: clean)
            let nextNarrative = typedNarrativeAuthorityAvailable ? TypedNarrativeCarry.advancing(evidence, sanitized: clean, previous: previousNarrative,
                typedPolicy: typedPolicy.revision, epoch: expectedCaptureEpoch, recordingEpoch: recordingEpoch, now: now) : nil
            // Typed words are sealed before anything is written, once per id.
            // Without a ready vault this throws and nothing is written: there
            // is no plain-text fallback.
            if clean.kind == "keyboard.text_input", !clean.text.isEmpty {
                guard try sealTypedWithinTransaction(&clean, now: now) else { return false }
            }
            // fix/r1-writer: a Mail recipient the person typed is never written to the record (sealed above, beside the
            // words, or dropped when there are none).
            if clean.kind == "keyboard.text_input" { try sealTypedRecipientWithinTransaction(&clean, epoch: nil) }
            let body = try json(clean), revision = fingerprint(body)
            let previous=try rows("SELECT revision FROM records WHERE id=?", [clean.id]).first?.first
            if preserveExisting, previous != nil { return false }
            if previous == revision { return false }
            try exec("INSERT INTO records VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET body=excluded.body, revision=excluded.revision", [clean.id, body, revision])
            try exec("DELETE FROM summaries WHERE id=? AND revision<>?", [clean.id, revision])
            try invalidateDisclosure(invalidateSnapshots:previous != nil)
            typedNarrativeCarry = nextNarrative
            typedNarrativeDataVersion = nextNarrative == nil ? nil : dataVersion
            return true
        } } catch {
            // BEGIN/COMMIT failure or refused persistence cannot certify the next part.
            discardTypedNarrativeCarry()
            throw error
        }
    }
    /// Durable queue: any record without a matching summary is pending. No model or network on ingest.
    /// Costs what is new, not the whole history, and never holds the store for long (it runs after capture commits, and
    /// the recorder's heartbeat and every capture save on the main thread wait for the store while it works):
    /// - retention reads only the rows at or before the cutoff (and rows whose time SQLite can't read), never every row;
    /// - pending rows come from `summary_queue`, which this connection's own inserts, updates and summary deletes fill
    ///   (SQLite triggers, so no writer can miss it);
    /// - the whole table is checked once per connection, and again when another connection changed the file
    ///   (`PRAGMA data_version`) or the policy changed (a hidden record may show again). That check walks the table in
    ///   short transactions of `summaryScanChunk` records, letting the recorder in between, and resumes where it stopped.
    @discardableResult public func writePending(now: Date = Date()) throws -> Int {
        defer { if automaticallySyncSearch { LocalSearchIndexer.schedule(store:self) } }
        // Safe typing D: exact typed words past their kept period are deleted
        // here too (and at launch and hourly), never waiting for a summarizer.
        try expireTypedTextForSummaryMaintenance(now:now)
        summaryLock.lock(); defer { summaryLock.unlock() }
        var count = 0, first = true, checked = false
        while true {
            let (written, scan, finished) = try summaryMaintenanceTransaction(now:now) { () -> (Int, SummaryScan, Bool) in
                let settings = try policy()
                if first {
                    let retentionCutoff = try settings.retention.cutoff(now:now)
                    try expireMigrationOriginals(now:now)
                    try expireLevels(now:now)
                    // Enforce retention on disk, not only while reading. This also
                    // removes stale writer inputs before the worker sees them. SQLite
                    // narrows the rows (a day of margin); the check below still decides.
                    if let cutoff=retentionCutoff {
                        for row in try rows("SELECT body FROM records WHERE julianday(json_extract(body,'$.at'))<julianday(?) OR julianday(json_extract(body,'$.at')) IS NULL", [iso(cutoff.addingTimeInterval(86_400))]) {
                            let source = try decode(Evidence.self, row[0])
                            if let at=timestamp(source.at), at < cutoff {
                                try exec("INSERT OR IGNORE INTO tombstones VALUES(?)", [source.id])
                                try exec("DELETE FROM records WHERE id=?", [source.id])
                                try exec("DELETE FROM summaries WHERE id=?", [source.id])
                                try purgeActionDerivatives(source.id,expired:true)
                                try invalidateDisclosure()
                            }
                        }
                    }
                }
                var written = 0
                var scan = summaryScan
                try prepareSummaryQueue()
                let target = SummaryScan.Target(dataVersion: try rows("PRAGMA data_version").first?.first ?? "", policy: settings.revision)
                // At most one whole check per call: a file another connection keeps changing costs one check per
                // call, as before, never an endless one.
                if scan.progress == nil && scan.done != target && !checked {
                    // A new check of the whole table. The queue is covered by it.
                    try exec("DELETE FROM summary_queue")
                    scan.progress = (target, "")
                }
                if let progress = scan.progress {
                    // The next `summaryScanChunk` records after the cursor (to the end of the table when fewer are left).
                    let end = try rows("SELECT id FROM records WHERE id>? ORDER BY id LIMIT 1 OFFSET \(Self.summaryScanChunk - 1)", [progress.cursor]).first?.first
                    let limit = 100 - count
                    let found = try rows(end == nil
                        ? "SELECT r.body,r.revision FROM records r LEFT JOIN summaries s ON \(Self.summaryDone) WHERE s.id IS NULL AND r.id>? ORDER BY r.id LIMIT \(limit)"
                        : "SELECT r.body,r.revision FROM records r LEFT JOIN summaries s ON \(Self.summaryDone) WHERE s.id IS NULL AND r.id>? AND r.id<=? ORDER BY r.id LIMIT \(limit)",
                        [settings.revision, progress.cursor] + (end.map { [$0] } ?? []))
                    var cursor = progress.cursor
                    for row in found {
                        let source = try decode(Evidence.self, row[0])
                        cursor = source.id
                        if try summarize(source, revision: row[1], settings: settings, now: now) { written += 1 }
                        else if Self.later(source, now: now) { try exec("INSERT OR IGNORE INTO summary_queue VALUES(?)", [source.id]) }
                    }
                    // A full page may leave more pending in this chunk: go on from the last record read.
                    if found.count == limit { scan.progress = (progress.target, cursor) }
                    else if let end { scan.progress = (progress.target, end) }
                    else {
                        // Done. What changed since this check began (another connection, the policy) starts the next.
                        scan.progress = nil; scan.done = progress.target; checked = true
                    }
                    return (written, scan, count + written == 100)
                }
                // What this connection changed since: each queued id once, then it leaves the queue.
                var after = ""
                queue: while count + written < 100 {
                    let ids = try rows("SELECT id FROM summary_queue WHERE id>? ORDER BY id LIMIT 100", [after])
                    if ids.isEmpty { break }
                    for row in ids {
                        after = row[0]
                        if let found = try rows("SELECT r.body,r.revision FROM records r LEFT JOIN summaries s ON \(Self.summaryDone) WHERE r.id=? AND s.id IS NULL", [settings.revision, row[0]]).first {
                            let source = try decode(Evidence.self, found[0])
                            if try summarize(source, revision: found[1], settings: settings, now: now) { written += 1 }
                            else if Self.later(source, now: now) { continue }
                        }
                        try exec("DELETE FROM summary_queue WHERE id=?", [row[0]])
                        if count + written == 100 { break queue }
                    }
                }
                return (written, scan, true)
            }
            // Only a committed pass counts: a rolled-back one leaves the queue and the check as they were.
            summaryScan = scan; summaryQueueReady = true
            count += written; first = false
            if finished { break }
            Self.letWaitersIn()
        }
        cleanupMigrationAttachmentsAfterCommit() // LegacyMigration.swift: tidying never fails the committed summaries (G62).
        return count
    }
    /// Records writePending's check of the whole table reads per transaction (a few ms at a time).
    static let summaryScanChunk = 5_000
    /// A moment between two of writePending's transactions. The store's lock does not queue its waiters: without a
    /// pause, a thread that unlocks and locks again at once keeps it, and the main thread's heartbeat and capture
    /// saves would still wait for the whole run.
    static func letWaitersIn() { usleep(1_000) }
    /// A read that goes on in short statements lets the recorder in between them (`letWaitersIn`): only on the
    /// recorder's own connection (another connection has its own lock) and outside a transaction (inside one this
    /// thread keeps the store's lock anyway).
    func letWaitersInBetweenReads() {
        guard writable else { return }
        lock.lock(); let inTransaction = sqlite3_get_autocommit(db) == 0; lock.unlock()
        if !inTransaction { Self.letWaitersIn() }
    }
    /// A record hidden now only because its time is still ahead (a clock moved back) shows once that time comes: it
    /// stays queued, as it would have stayed pending before.
    private static func later(_ source: Evidence, now: Date) -> Bool {
        timestamp(source.at).map { $0 > now.addingTimeInterval(30) } ?? false
    }
    /// A record's summary is done when it matches the record's revision, or (gold/notes extra6) when it is the marker
    /// for a record the current policy hides. Binds the policy revision first.
    static let summaryDone = "r.id=s.id AND (r.revision=s.revision OR s.revision='hidden|'||?||'|'||r.revision)"
    /// Writes the record's summary; false when the current policy hides the record. A hidden record gets a marker row
    /// (gold/notes extra6: `'{}'`, revision `hidden|<policy revision>|<record revision>`, no text), so it leaves
    /// "pending" and later passes skip it; a policy change or an edit to the record looks at it again. A record still
    /// ahead in time is not marked: it stays queued until its time comes (`later`).
    private func summarize(_ source: Evidence, revision: String, settings: PrivacySettings, now: Date) throws -> Bool {
        guard let clean = Privacy.sanitized(source, settings: settings, now: now) else {
            if let at = timestamp(source.at), at <= now.addingTimeInterval(30) {
                try exec("INSERT OR REPLACE INTO summaries VALUES(?,'{}',?)", [source.id, "hidden|"+settings.revision+"|"+revision])
            }
            return false
        }
        let item = IntentWriter.write(clean, now: now)
        try exec("INSERT OR REPLACE INTO summaries VALUES(?,?,?)", [item.id, json(item), fingerprint(try json(source))])
        return true
    }
    /// This connection's pending-summary queue (TEMP: never in the file, gone when the connection closes). Triggers
    /// fill it on every insert or update of a record and every summary removed or changed through this connection.
    private func prepareSummaryQueue() throws {
        guard !summaryQueueReady else { return }
        try exec("CREATE TEMP TABLE IF NOT EXISTS summary_queue(id TEXT PRIMARY KEY)")
        try exec("CREATE TEMP TRIGGER IF NOT EXISTS summary_queue_record_insert AFTER INSERT ON main.records BEGIN INSERT OR IGNORE INTO summary_queue VALUES(new.id); END")
        try exec("CREATE TEMP TRIGGER IF NOT EXISTS summary_queue_record_update AFTER UPDATE ON main.records BEGIN INSERT OR IGNORE INTO summary_queue VALUES(new.id); END")
        try exec("CREATE TEMP TRIGGER IF NOT EXISTS summary_queue_summary_delete AFTER DELETE ON main.summaries BEGIN INSERT OR IGNORE INTO summary_queue VALUES(old.id); END")
        try exec("CREATE TEMP TRIGGER IF NOT EXISTS summary_queue_summary_update AFTER UPDATE ON main.summaries BEGIN INSERT OR IGNORE INTO summary_queue VALUES(old.id); INSERT OR IGNORE INTO summary_queue VALUES(new.id); END")
    }
    /// Time indexes, made once: the day's actions, the timeline, retention and status read by time without parsing
    /// every row. A store that can't take them (another connection busy, an unreadable row) still opens and reads as
    /// before; the next open tries again. Rollback journal unchanged. CanonicalBackupBinding allows exactly these.
    static let timeIndexes = [
        "CREATE INDEX IF NOT EXISTS records_at ON records(json_extract(body,'$.at'))",
        "CREATE INDEX IF NOT EXISTS records_at_julian ON records(julianday(json_extract(body,'$.at')))",
        "CREATE INDEX IF NOT EXISTS summaries_generated_at ON summaries(json_extract(body,'$.generatedAt'))",
        // Build 4's plain-text typed rows, which typed-word expiry looks for on every summary pass (none once settled):
        // exactly the WHERE of TypedTextStore's settle query and LegacyTypedScrub's count, so both read this.
        "CREATE INDEX IF NOT EXISTS records_plain_typed ON records(id) WHERE json_extract(body,'$.kind')='keyboard.text_input' AND coalesce(json_extract(body,'$.text'),'')<>'' AND json_extract(body,'$.typed') IS NULL",
    ]
    /// The names of `timeIndexes` (HistoryPreparation looks for each).
    static let timeIndexNames: [String] = timeIndexes.compactMap { sql in
        sql.components(separatedBy: "INDEX IF NOT EXISTS ").dropFirst().first?.components(separatedBy: " ON ").first
    }
    private func createTimeIndexes() {
        for sql in Self.timeIndexes { try? exec(sql) }
    }
    /// The order launch's preparation builds them in (HistoryPreparation.finish): `records_at_julian` first. Until it
    /// exists an AI app's Today, action and search reads are single whole-table statements that hold the file for
    /// seconds, and each later build's commit has to wait for the reads in progress; after it they are short statements.
    static let preparationOrder: [String] = timeIndexNames.filter { $0 == "records_at_julian" } + timeIndexNames.filter { $0 != "records_at_julian" }
    /// The time index `name` exists as DayDream makes it (`ownIndex`).
    func hasTimeIndex(_ name: String) -> Bool {
        guard let sql = (try? rows("SELECT sql FROM sqlite_master WHERE type='index' AND name=?", [name]))?.first?.first else { return false }
        return Self.ownIndex(name: name, sql: sql)
    }
    /// One of `timeIndexes`, built by launch's preparation. Unlike `createTimeIndexes`, a failure is thrown.
    func buildTimeIndex(_ name: String) throws {
        guard let sql = Self.timeIndexes.first(where: { $0.contains("INDEX IF NOT EXISTS \(name) ON ") }) else { return }
        try exec(sql)
    }
    /// `body` with this connection waiting up to `seconds` for another connection's lock instead of 1.5 s. Launch's
    /// preparation only: nothing records through its connection, so its long wait holds no save up.
    func waiting<T>(_ seconds: TimeInterval, _ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        busyWait.patienceMs = max(0, min(seconds, 600)) * 1000
        defer { busyWait.patienceMs = Double(busyMilliseconds) }
        return try body()
    }
    /// How long a statement waits for another connection's lock: 1.5 s, so a save never waits long for an AI app's
    /// read. Launch's preparation, which nothing records through, waits as long as it would for its builds, the open's
    /// own schema writes included (HistoryPreparation.patience).
    private var busyMilliseconds: Int32 { launchWork == .preparation && writable ? Int32(HistoryPreparation.patience * 1000) : 1500 }
    /// A repair of a damaged history that lost something (StoreIntegrity.rebuild): written into the new file itself,
    /// so it takes the damaged file's place in the same rename (gold r2-store-perf review round 1: said only from memory,
    /// a quit, logout or second copy between the repair and the app's model lost it). The app says it at the first
    /// open that follows (MemoryViewModel.openHistory: setup again when the choices couldn't be read back, the menu's
    /// line for the kept damaged file), then clears it (`repairSaid`).
    public struct UnsaidRepair: Equatable, Sendable {
        public var keptChoices: Bool
    }
    public func unsaidRepair() -> UnsaidRepair? {
        guard let body = (try? rows("SELECT body FROM metadata WHERE id=?", [StoreIntegrity.unsaidRepairID]))?.first?.first else { return nil }
        return UnsaidRepair(keptChoices: StoreIntegrity.unsaidKeptChoices(body))
    }
    /// The app said the repair: cleared. One that fails is said again at the next open (saying it twice changes nothing).
    public func repairSaid() { try? exec("DELETE FROM metadata WHERE id=?", [StoreIntegrity.unsaidRepairID]) }
    /// One of `timeIndexes`, as SQLite keeps it (`sqlite_master.sql` drops "IF NOT EXISTS").
    static func ownIndex(name: String, sql: String) -> Bool {
        timeIndexes.contains { $0.replacingOccurrences(of: "IF NOT EXISTS ", with: "") == sql && $0.contains("INDEX IF NOT EXISTS \(name) ON ") }
    }
    public func timeline(query: String = "", now: Date = Date(), limit: Int = 20) throws -> [MemoryItem] {
        let settings = try policy()
        // Bound candidates as well as output. Original IDs and evidence are retained.
        let candidates = try rows("SELECT r.body,s.body FROM records r LEFT JOIN summaries s ON r.id=s.id AND r.revision=s.revision ORDER BY json_extract(r.body,'$.at') DESC LIMIT 1000")
        var result: [MemoryItem] = []
        for row in candidates {
            let raw = try decode(Evidence.self, row[0])
            guard let clean = Privacy.sanitized(raw, settings: settings, now: now) else { continue }
            var item = row[1].isEmpty ? IntentWriter.write(clean, now: now) : try decode(MemoryItem.self, row[1])
            // Never trust stale derived content following a policy revision.
            if clean != raw { item = IntentWriter.write(clean, now: now) }
            if row[1].isEmpty { item.writer = "pending-local-writer"; item.generatedAt = "" }
            if !query.isEmpty && !(item.summary + clean.app + clean.title + clean.text).localizedCaseInsensitiveContains(query) { continue }
            result.append(try applyCorrection(item))
            if result.count >= max(1, min(1000, limit)) { break }
        }
        return result
    }
    public func read(_ id: String, now: Date = Date()) throws -> MemoryItem? {
        guard let body = try rows("SELECT body FROM records WHERE id=?", [id]).first?.first,
              let clean = Privacy.sanitized(try decode(Evidence.self, body), settings: try policy(), now: now) else { return nil }
        let original = try decode(Evidence.self, body)
        if clean == original, let raw = try rows("SELECT body FROM summaries WHERE id=? AND revision=?", [id, fingerprint(body)]).first?.first {
            return try applyCorrection(decode(MemoryItem.self, raw))
        }
        var pending = IntentWriter.write(clean, now: now)
        pending.generatedAt = ""; pending.writer = "pending-local-writer"
        return try applyCorrection(pending)
    }
    /// Native selected-day drill-down must not inherit the recent timeline cap.
    public func activityDay(start: Date, end: Date, now: Date = Date()) throws -> [MemoryItem] {
        let ids = try rows("SELECT id FROM records WHERE julianday(json_extract(body,'$.at')) >= julianday(?) AND julianday(json_extract(body,'$.at')) < julianday(?) ORDER BY julianday(json_extract(body,'$.at'))", [iso(start),iso(end)])
        return try ids.compactMap { try read($0[0],now:now) }
    }
    public func delete(_ id: String) throws {
        defer { if automaticallySyncSearch { LocalSearchIndexer.schedule(store:self) } }
        try transaction {
            try requireKnownSummaryDependencies([id])
            try deleteActionWithinTransaction(id)
            try exec("DELETE FROM receipts")
            try invalidateDisclosure()
        }
        cleanupMigrationAttachmentsAfterCommit() // LegacyMigration.swift: tidying never fails the committed deletion (G62).
    }
    public func updatePolicy(_ settings: PrivacySettings, now: Date = Date()) throws {
        defer { if automaticallySyncSearch { LocalSearchIndexer.schedule(store:self) } }
        try settings.retention.validate()
        try transaction {
            guard !settings.retention.isShorter(than:try policy().retention) else {
                throw MemError.invalid("Shorter retention requires prepareRetentionChange and explicit confirmation")
            }
            var next = settings; next.revision = UUID().uuidString
            try exec("UPDATE metadata SET body=? WHERE id='policy'", [json(next)])
            // Exclusion is reversible visibility/intake policy, not deletion.
            // All readers and writers sanitize under the current policy. Explicit
            // deletion and the separately configured retention expiry purge data.
            try exec("DELETE FROM summaries"); try exec("DELETE FROM receipts")
            try invalidateAllNotes()
            try invalidateDisclosure()
        }
    }
    public func status() throws -> [String:String] {
        let pending = try rows("SELECT count(*) FROM records r LEFT JOIN summaries s ON r.id=s.id AND (r.revision=s.revision OR s.revision='hidden|'||coalesce((SELECT json_extract(body,'$.revision') FROM metadata WHERE id='policy'),'')||'|'||r.revision) WHERE s.id IS NULL").first?.first ?? "0"
        let capture = try captureStatus()
        // The cloud field is the setting the app last reported (`setSummaryWriter`), never a fixed value:
        // "on", "off", or "unknown" before the app has reported one.
        let cloud = try summaryWriter().map { $0.mode == "cloud" ? "on" : "off" } ?? "unknown"
        return ["capture":capture["state"] ?? "off", "reason":capture["reason"] ?? "", "pending":pending, "cloud":cloud,
                "automatic_context":"requires before-turn host adapter; MCP alone is manual",
                "observed_at":try rows("SELECT max(json_extract(body,'$.at')) FROM records").first?.first ?? "",
                "summary_generated_at":try rows("SELECT max(json_extract(body,'$.generatedAt')) FROM summaries").first?.first ?? ""]
    }
    public func disclosureRevision() throws -> String {
        try rows("SELECT body FROM metadata WHERE id='disclosure_revision'").first?.first ?? policy().revision
    }
    func actionReadEpoch() throws -> String {
        try rows("SELECT body FROM metadata WHERE id='action_read_epoch'").first?.first ?? policy().revision
    }
    func invalidateDisclosure(invalidateSnapshots:Bool=true) throws {
        if invalidateSnapshots {
            try exec("INSERT OR REPLACE INTO metadata VALUES('action_read_epoch',?)", [UUID().uuidString])
        }
        try exec("INSERT OR REPLACE INTO metadata VALUES('disclosure_revision',?)", [UUID().uuidString])
        // Revisit IDs earlier than the last index page after source/policy changes.
        // This also prioritizes outage deletions rather than waiting another cycle.
        try exec("DELETE FROM metadata WHERE id='search_cursor'")
    }
}

/// writePending's check of the whole records table: the state it last finished for, and one in progress.
struct SummaryScan {
    struct Target: Equatable { let dataVersion: String; let policy: String }
    var done: Target?
    var progress: (target: Target, cursor: String)?
}

public final class SummaryWorker {
    private let queue = DispatchQueue(label: "macmem.summary", qos: .utility)
    private let store: MemoryStore
    public init(store: MemoryStore) { self.store = store }
    public func schedule(completion: @escaping (Result<Int, Error>) -> Void = { _ in }) {
        queue.async { completion(Result {
            var total = 0
            while true {
                // gold r3-store: a pass waiting for another connection lets the main thread in (StoreWait.swift).
                let count = try StoreWait.lettingMainIn { try self.store.writePending() }; total += count
                if count < 100 { return total }
                MemoryStore.letWaitersIn()
            }
        }) }
    }
}
