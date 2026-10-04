import Foundation
import CryptoKit

/// How big a backup may be and how long one may take. A backup holds the whole history, however long it is: these
/// only stop a runaway far past any real one (a year of heavy use is under a tenth of them). They were 20,000 rows per
/// kind of record, 64 MiB and eight seconds, so a backup failed after about two weeks of use (gold G29). The helper
/// (BackupRestore) takes its file, time and message limits from here too, so the two never disagree.
public enum CanonicalBackupBounds {
    /// Canonical row bytes one snapshot holds in memory.
    public static let rowBytes = 2 * 1024 * 1024 * 1024
    /// The largest backup file (the rows plus SQLite's own pages and indexes).
    public static let fileBytes = 4 * 1024 * 1024 * 1024
    /// Wall-clock seconds for one backup, preview or restore.
    public static let seconds: Double = 1800
    /// The largest request or reply between the app and the helper: a restore preview lists every moment it adds.
    public static let messageBytes = 64 * 1024 * 1024
}

/// Core records only. BackupRestore owns the container, verified files and worker.
/// This is the existing canonical SQL schema, not an alternate memory store.
public struct CanonicalBackupAudit:Codable {
    public var schema:String = "macmem-canonical-v1"
    public var fence:CoreSnapshotFence
    public var counts:[String:Int]
    public var assets:[String]
    public var excluded:Int
    public var capture:String = "off"
    public var sourceFence:CoreSnapshotFence? = nil
    public var assetsVerified:Bool = false
    /// DayDream's own backups never hold the exact words anyone typed: `typed_text` is not
    /// exported, only `typed_after` stubs. Always false; nil in older manifests.
    public var typedTextExact:Bool? = false
}
public struct CanonicalRestorePreview:Codable {
    public var id:String
    public var authority:CoreSnapshotFence
    public var candidate:CoreSnapshotFence
    public var candidateDigest:String
    public var addedActionIDs:[String]
    public var expiresAt:String
    public var explanation:String
    /// A repair that couldn't read back every deletion (`deletions_unknown_before`, StoreIntegrity, gold G45) held back
    /// this backup's actions from before it: the marker's time, set only when at least one action was held back, so
    /// Backup and restore can say why fewer (often none) are added. nil otherwise; absent from older previews.
    public var heldBackBefore:String?=nil
}
public struct CanonicalRestoreReceipt:Codable {
    public var previewID:String
    public var addedActionIDs:[String]
    public var revision:String
    public var capture:String = "off"
}
private struct CanonicalRows {
    var tables:[String:[[String]]]
    var assets:[String]
    var excluded:Int
    var fence:CoreSnapshotFence
    /// Every table byte, hashed as it is read: the same rows give the same digest, and a long history is never copied
    /// into one JSON string first. Each value is length-prefixed, so no two different tables hash alike.
    var digest:String {
        var hash=SHA256()
        func add(_ text:String) {
            var size=UInt64(text.utf8.count).bigEndian, value=text
            withUnsafeBytes(of:&size){hash.update(bufferPointer:$0)}
            value.withUTF8{hash.update(bufferPointer:UnsafeRawBufferPointer($0))}
        }
        for (table,rows) in tables.sorted(by:{$0.key<$1.key}) {
            add(table);add(String(rows.count))
            for row in rows {add(String(row.count));row.forEach(add)}
        }
        return "rows-v2:"+hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
}
private let backupColumns:[String:String] = [
    "records":"id,body,revision","summaries":"id,body,revision","tombstones":"id",
    "action_group_edits":"sequence,action_id,subject","generated_notes":"id,version,input_revision,body",
    "user_corrections":"kind,target,version,body","migration_originals":"id,body,raw_hash,policy_hash",
    "migration_batches":"id,policy_hash,next",
    // Stubs only (word count, kept summary). Sealed words are never exported.
    "typed_after":"id,words,summary,source,ended_at"
]
/// `Privacy.sanitized(event, settings: policy, now: now, presenting: false) == event` for each record, remembered in this process by the
/// exact policy, the exact `now` and the record's own hash (its `revision`, checked against its body before it is
/// used here). A backup, a restore preview and a restore each check the same records several times over (the source,
/// the copy made from it, then the copy again after reconciling), and this check is most of a backup's time on a long
/// history. The answer is a function of those three inputs alone, so a remembered one is the same answer. Only the
/// last three policy/time pairs are kept, a million records each at most.
final class CanonicalPrivacyMemo {
    static let shared=CanonicalPrivacyMemo()
    final class Context {
        fileprivate let key:String
        private let lock=NSLock()
        private var known:[String:Bool]=[:]
        fileprivate init(key:String) {self.key=key}
        var count:Int {lock.lock();defer{lock.unlock()};return known.count}
        func unchanged(_ revision:String,_ compute:() -> Bool) -> Bool {
            lock.lock()
            if let value=known[revision] {lock.unlock();return value}
            lock.unlock()
            let value=compute()
            lock.lock();if known.count<Self.limit {known[revision]=value};lock.unlock()
            return value
        }
        static let limit=1_000_000
    }
    private let lock=NSLock()
    private var recent:[Context]=[]
    func context(policy:String,now:Date) -> Context {
        let key=fingerprint(policy)+"@"+String(now.timeIntervalSinceReferenceDate.bitPattern)
        lock.lock();defer{lock.unlock()}
        if let index=recent.firstIndex(where:{$0.key==key}) {let found=recent.remove(at:index);recent.append(found);return found}
        let made=Context(key:key);recent.append(made)
        if recent.count>3 {recent.removeFirst()}
        return made
    }
}
private struct BackupBound {
    let deadline=ProcessInfo.processInfo.systemUptime+CanonicalBackupBounds.seconds
    var bytes=0
    mutating func check(_ rows:[[String]]=[]) throws {
        bytes += rows.reduce(0){$0+$1.reduce(0){$0+$1.utf8.count}}
        guard bytes<=CanonicalBackupBounds.rowBytes,ProcessInfo.processInfo.systemUptime<deadline else { throw MemError.invalid("Canonical snapshot exceeds its size or time bound") }
    }
}
extension MemoryStore {
    private func canonicalRows(now:Date,strict:Bool) throws -> CanonicalRows {
        var bound=BackupBound(), data=[String:[[String]]](),excluded=0
        // Reject unexpected executable schema before executing table queries.
        let objects=try rows("SELECT type,name,coalesce(sql,'') FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'")
        // typed_text, typed_recipients (fix/r1-writer: a Mail recipient sealed with the words) and the level tables are
        // allowed, but never exported (not in backupColumns): levels are rebuilt.
        let allowed=Set(backupColumns.keys).union(["metadata","grants","receipts","search_index_state","note_requests","deletion_previews","typed_text","typed_recipients"]).union(MemoryStore.levelTables)
        // The store's own time indexes (MemoryStore.timeIndexes, exactly as made) are expected too; nothing else is.
        guard objects.allSatisfy({($0[0]=="table" && allowed.contains($0[1])) || ($0[0]=="index" && (MemoryStore.ownIndex(name:$0[1],sql:$0[2]) || MemoryStore.ownLevelIndex(name:$0[1],sql:$0[2])))}) else { throw MemError.invalid("Unsupported canonical schema object") }
        for (table,columns) in backupColumns.sorted(by:{$0.key<$1.key}) {
            if !objects.contains(where:{$0[1]==table}) {continue}
            let lengths=columns.split(separator:",").map{"coalesce(length(CAST(\($0) AS BLOB)),0)"}.joined(separator:"+")
            let size=try rows("SELECT count(*),coalesce(sum(\(lengths)),0) FROM \(table)").first!
            // Every row, however many (G29): only the byte bound applies, checked before the rows are read.
            guard (Int(size[1]) ?? Int.max)<=CanonicalBackupBounds.rowBytes-bound.bytes else {throw MemError.invalid("Canonical table exceeds snapshot bound")}
            let batch=try rows("SELECT \(columns) FROM \(table) ORDER BY \(columns)")
            try bound.check(batch);data[table]=batch
        }
        let policy=try policy(), tombstones=Set((data["tombstones"] ?? []).map{$0[0]})
        let privacy=CanonicalPrivacyMemo.shared.context(policy:try json(policy),now:now)
        let permitted=try (data["records"] ?? []).filter { row in
            let event=try decode(Evidence.self,row[1])
            guard event.id==row[0],fingerprint(row[1])==row[2] else {throw MemError.invalid("Canonical original hash mismatch")}
            // Build 4 plain-text typed rows (words still in the body, waiting
            // for the upgrade) are never exported: backups hold no typed words.
            let legacyTypedWords = event.kind == "keyboard.text_input" && !event.text.isEmpty
            let keep = !tombstones.contains(row[0]) && !legacyTypedWords && privacy.unchanged(row[2]) {Privacy.sanitized(event,settings:policy,now:now,presenting:false)==event}
            if !keep {excluded += 1};return keep
        }
        data["records"]=permitted
        let ids=Set(permitted.map{$0[0]})
        data["summaries"]=(data["summaries"] ?? []).filter{ids.contains($0[0])}
        data["action_group_edits"]=(data["action_group_edits"] ?? []).filter{ids.contains($0[1])}
        data["typed_after"]=(data["typed_after"] ?? []).filter{ids.contains($0[0])}
        data["user_corrections"]=try (data["user_corrections"] ?? []).filter { row in
            let correction=try decode(UserCorrection.self,row[3])
            guard correction.targetKind==row[0],correction.targetID==row[1],String(correction.version)==row[2],
                  correction.text.map({!Privacy.secret($0) && $0.utf8.count<=4000}) ?? true else {throw MemError.invalid("Invalid correction ledger")}
            return !correction.actionIDs.isEmpty && Set(correction.actionIDs).isSubset(of:ids)
        }
        data["generated_notes"]=try (data["generated_notes"] ?? []).filter { row in
            let note=try decode(GeneratedNote.self,row[3]);return !note.actionIDs.isEmpty && Set(note.actionIDs).isSubset(of:ids)
        }
        var assets=Set<String>()
        data["migration_originals"]=try (data["migration_originals"] ?? []).filter { row in
            let entry=try decode(MigrationEntry.self,row[1])
            guard entry.id==row[0],fingerprint(entry.raw)==entry.rawSHA256,entry.rawSHA256==row[2] else {throw MemError.invalid("Migration original hash mismatch")}
            guard !entry.deleted,!tombstones.contains(entry.id),LegacyMigration.policyReason(entry,settings:policy,now:now)==nil,
                  entry.evidence == nil || ids.contains(entry.id) else {excluded += 1;return false}
            for asset in entry.attachments {
                guard asset.path=="attachments/"+asset.sha256,asset.sha256.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else {throw MemError.invalid("Invalid canonical asset reference")}
                assets.insert(asset.sha256)
            }
            return true
        }
        if strict {
            guard excluded==0 else {throw MemError.invalid("Candidate includes forbidden or stale originals")}
            for table in ["summaries","action_group_edits","user_corrections","generated_notes","typed_after"] where objects.contains(where:{$0[1]==table}) {
                let count=Int(try rows("SELECT count(*) FROM \(table)").first![0])!
                guard count==data[table]?.count else {throw MemError.invalid("Candidate has dangling relationships")}
            }
        }
        try bound.check()
        return CanonicalRows(tables:data,assets:assets.sorted(),excluded:excluded,fence:try coreSnapshotFence())
    }
    private func insertCanonical(_ table:String,_ row:[String]) throws {
        guard let columns=backupColumns[table],row.count==columns.split(separator:",").count else {throw MemError.invalid("Unknown canonical table")}
        try exec("INSERT INTO \(table)(\(columns)) VALUES(\(row.map{_ in "?"}.joined(separator:",")))",row)
    }
    private func ensureMigrationTables() throws {
        try exec("CREATE TABLE IF NOT EXISTS migration_originals(id TEXT PRIMARY KEY, body TEXT NOT NULL, raw_hash TEXT NOT NULL, policy_hash TEXT NOT NULL)")
        try exec("CREATE TABLE IF NOT EXISTS migration_batches(id TEXT PRIMARY KEY, policy_hash TEXT NOT NULL, next INTEGER NOT NULL)")
    }
    /// Destination must be a NEW private empty core store supplied by the native
    /// container worker. Source remains untouched, including WAL and grants.
    public func exportCanonicalSnapshot(to destination:MemoryStore,now:Date=Date()) throws -> CanonicalBackupAudit {
        guard home.standardizedFileURL.resolvingSymlinksInPath() != destination.home.standardizedFileURL.resolvingSymlinksInPath() else {throw MemError.denied}
        return try readSnapshot {
            let snapshot=try canonicalRows(now:now,strict:false),policyJSON=try json(policy())
            try destination.transaction {
                var writeBound=BackupBound()
                let hasTypingDraft=try !destination.rows("SELECT id FROM metadata WHERE id='native-typing-choice-pending-v1'").isEmpty
                if hasTypingDraft {
                    let initial=try destination.policy()
                    guard try destination.nativeTypingChoicePending(),initial.blockedApps.isEmpty,
                          initial.blockedDomains.isEmpty,initial.retention == .never else {throw MemError.invalid("Snapshot destination is not new")}
                }
                guard try destination.rows("SELECT id FROM records UNION ALL SELECT id FROM tombstones UNION ALL SELECT id FROM grants LIMIT 1").isEmpty,
                      try destination.rows("SELECT id FROM metadata WHERE id NOT IN ('policy','core_store_id','native-typing-choice-pending-v1') LIMIT 1").isEmpty,
                      try destination.canonicalRows(now:now,strict:true).tables.values.allSatisfy(\.isEmpty),
                      try destination.rows("SELECT id FROM receipts UNION ALL SELECT id FROM search_index_state UNION ALL SELECT id FROM note_requests UNION ALL SELECT id FROM deletion_previews LIMIT 1").isEmpty else {throw MemError.invalid("Snapshot destination is not new")}
                try destination.ensureMigrationTables()
                for table in backupColumns.keys.sorted() {for row in snapshot.tables[table] ?? [] {try writeBound.check([row]);try destination.insertCanonical(table,row)}}
                // Restored policies are existing choices, never fresh onboarding
                // defaults. Keep the source marker and snapshot whitelist intact.
                try destination.exec("DELETE FROM metadata WHERE id='native-typing-choice-pending-v1'")
                try destination.exec("UPDATE metadata SET body=? WHERE id='policy'",[policyJSON])
                try destination.exec("UPDATE metadata SET body=? WHERE id='core_store_id'",[snapshot.fence.storeID])
                try destination.invalidateDisclosure()
            }
            return CanonicalBackupAudit(fence:try destination.coreSnapshotFence(),counts:snapshot.tables.mapValues(\.count),assets:snapshot.assets,excluded:snapshot.excluded,sourceFence:snapshot.fence)
        }
    }
    /// Exact canonical owned attachment only, never an arbitrary file path.
    /// Container owner must pin export.sourceFence for every asset, then recheck
    /// it before sealing the manifest. A changed/deleted source forces re-export.
    public func canonicalBackupAsset(sha256:String,expected:CoreSnapshotFence,now:Date=Date()) throws -> Data {
        try readSnapshot {
            let snapshot=try canonicalRows(now:now,strict:false)
            guard snapshot.fence==expected,snapshot.assets.contains(sha256) else {throw MemError.invalid("Backup asset authority changed or reference unavailable")}
            return try ownedBackupAsset(sha256)
        }
    }
    /// Every asset `canonicalBackupAsset` would give, from one pass over the history (the export reads them all; one
    /// pass per attachment made a long history with many attachments take that many passes). Same checks, in order.
    public func canonicalBackupAssets(expected:CoreSnapshotFence,now:Date=Date(),_ each:(String,Data) throws -> Void) throws {
        try readSnapshot {
            let snapshot=try canonicalRows(now:now,strict:false)
            guard snapshot.fence==expected else {throw MemError.invalid("Backup asset authority changed or reference unavailable")}
            for sha256 in snapshot.assets {try each(sha256,try ownedBackupAsset(sha256))}
        }
    }
    private func ownedBackupAsset(_ sha256:String) throws -> Data {
        let url=home.appendingPathComponent("migration-attachments/"+sha256)
        guard url.standardizedFileURL==url.resolvingSymlinksInPath() else {throw MemError.invalid("Backup asset path must not be linked")}
        let data=try LegacyMigration.file(url,limit:64*1024*1024)
        guard LegacyMigration.hash(data)==sha256 else {throw MemError.invalid("Backup asset hash mismatch")}
        return data
    }
    /// Validates the existing canonical store; container hashes/path checks must
    /// already have passed in BackupRestore before opening an untrusted snapshot.
    public func inspectCanonicalSnapshot(now:Date=Date()) throws -> CanonicalBackupAudit {
        try readSnapshot {
            let data=try canonicalRows(now:now,strict:true)
            guard try captureStatus()["state"]=="off",
                  try rows("SELECT id FROM grants UNION ALL SELECT id FROM receipts UNION ALL SELECT id FROM search_index_state LIMIT 1").isEmpty,
                  try rows("SELECT id FROM note_requests WHERE body<>'' LIMIT 1").isEmpty,
                  // A backup never carries sealed typed words.
                  try rows("SELECT name FROM sqlite_master WHERE type='table' AND name='typed_text'").isEmpty || rows("SELECT id FROM typed_text LIMIT 1").isEmpty,
                  // Nor level notes: they are derived here, never brought in (a crafted backup could carry made-up ones).
                  try rows("SELECT name FROM sqlite_master WHERE type='table' AND name='level_notes'").isEmpty || rows("SELECT id FROM level_notes LIMIT 1").isEmpty,
                  try rows("SELECT name FROM sqlite_master WHERE type='table' AND name='level_edges'").isEmpty || rows("SELECT parent FROM level_edges LIMIT 1").isEmpty,
                  try rows("SELECT name FROM sqlite_master WHERE type='table' AND name='review_clauses'").isEmpty || rows("SELECT id FROM review_clauses LIMIT 1").isEmpty,
                  try rows("SELECT id FROM deletion_previews WHERE state='pending' LIMIT 1").isEmpty,
                  try rows("SELECT id FROM metadata WHERE id NOT IN ('policy','core_store_id','disclosure_revision','action_read_epoch') LIMIT 1").isEmpty else {throw MemError.invalid("Snapshot contains runtime authority")}
            return CanonicalBackupAudit(fence:data.fence,counts:data.tables.mapValues(\.count),assets:data.assets,excluded:0)
        }
    }
    /// Current authority wins. A backup from another lineage never becomes safe
    /// merely because a destination is empty. Only isolated candidate is changed.
    public func reconcileCanonicalSnapshot(_ candidate:MemoryStore,expected:CoreSnapshotFence,now:Date=Date()) throws -> CanonicalBackupAudit {
        guard home.standardizedFileURL.resolvingSymlinksInPath() != candidate.home.standardizedFileURL.resolvingSymlinksInPath() else {throw MemError.denied}
        _=try candidate.inspectCanonicalSnapshot(now:now)
        try withSnapshotCoordination { fence in
            guard fence==expected,try candidate.coreSnapshotFence().storeID==fence.storeID else {throw MemError.invalid("Restore authority or lineage changed")}
            let current=try canonicalRows(now:now,strict:false),policyJSON=try json(policy())
            try candidate.transaction {
                var writeBound=BackupBound()
                try candidate.ensureMigrationTables()
                for row in current.tables["tombstones"] ?? [] {try writeBound.check([row]);try candidate.deleteActionWithinTransaction(row[0])}
                try candidate.exec("UPDATE metadata SET body=? WHERE id='policy'",[policyJSON])
                // Re-project against current policy before accepting any candidate.
                let clean=try candidate.canonicalRows(now:now,strict:false)
                let currentCorrections=Set((current.tables["user_corrections"] ?? []).map{$0[3]})
                guard (clean.tables["user_corrections"] ?? []).allSatisfy({currentCorrections.contains($0[3])}) else {throw MemError.invalid("Backup has correction versions absent from current authority; review required")}
                for table in backupColumns.keys {try candidate.exec("DELETE FROM \(table)")}
                for table in backupColumns.keys.sorted() where table != "user_corrections" && table != "generated_notes" {
                    for row in clean.tables[table] ?? [] {try writeBound.check([row]);try candidate.insertCanonical(table,row)}
                }
                // Never regress an edit or silently discard an edit's source.
                for row in current.tables["user_corrections"] ?? [] {
                    try writeBound.check([row])
                    let correction=try decode(UserCorrection.self,row[3])
                    for id in correction.actionIDs {
                        guard try !candidate.rows("SELECT id FROM records WHERE id=?",[id]).isEmpty else {throw MemError.invalid("Current correction refers to an action absent from backup; review required")}
                    }
                    try candidate.insertCanonical("user_corrections",row)
                }
                try candidate.invalidateDisclosure()
            }
        }
        return try candidate.inspectCanonicalSnapshot(now:now)
    }
    /// Merge restore: no active originals are overwritten or removed. Preview
    /// binds exact added IDs and every canonical table byte, not just counts.
    public func prepareCanonicalRestore(_ candidate:MemoryStore,now:Date=Date()) throws -> CanonicalRestorePreview {
        guard home.standardizedFileURL.resolvingSymlinksInPath() != candidate.home.standardizedFileURL.resolvingSymlinksInPath() else {throw MemError.denied}
        _=try candidate.inspectCanonicalSnapshot(now:now)
        let snapshot=try candidate.readSnapshot {try candidate.canonicalRows(now:now,strict:true)}
        return try transaction {
            let authority=try coreSnapshotFence()
            let safety=try validateRestoreCandidate(candidate,expectedCurrent:authority)
            guard safety.canAdopt,try captureStatus()["state"]=="off" else {throw MemError.invalid("Restore needs recording OFF and reconciled current authority: "+safety.conflicts.joined(separator:","))}
            var added=[String]()
            for row in snapshot.tables["tombstones"] ?? [] {
                guard try rows("SELECT id FROM records WHERE id=? UNION ALL SELECT id FROM summaries WHERE id=?",[row[0],row[0]]).isEmpty else {throw MemError.invalid("Backup tombstone conflicts with current evidence; explicit deletion review required")}
                if try !rows("SELECT name FROM sqlite_master WHERE name='migration_originals'").isEmpty {
                    guard try rows("SELECT id FROM migration_originals WHERE id=?",[row[0]]).isEmpty else {throw MemError.invalid("Backup tombstone conflicts with a current imported original; explicit deletion review required")}
                }
            }
            // A repair that couldn't read back every deletion (StoreIntegrity, gold G45): a moment from before it may be
            // one the person deleted, so none of those is added.
            let marker=try rows("SELECT body FROM metadata WHERE id=?",[Self.deletionsUnknownBefore]).first?.first
            let deletionsUnknownBefore=marker.map{timestamp($0) ?? .distantFuture}
            var heldBack=0
            for row in snapshot.tables["records"] ?? [] {
                let existing=try rows("SELECT body FROM records WHERE id=?",[row[0]]).first?.first
                guard existing==nil || existing==row[1] else {throw MemError.invalid("Same action ID has different immutable evidence")}
                guard existing==nil else {continue}
                if let deletionsUnknownBefore {
                    guard let at=(try? decode(Evidence.self,row[1])).flatMap({timestamp($0.at)}),at>deletionsUnknownBefore else {heldBack+=1;continue}
                }
                added.append(row[0])
            }
            var preview=CanonicalRestorePreview(id:UUID().uuidString,authority:authority,candidate:snapshot.fence,candidateDigest:snapshot.digest,addedActionIDs:added.sorted(),expiresAt:iso(now.addingTimeInterval(300)),explanation:"Merge these exact actions into current memory. Existing actions remain. Grants and recording are not restored; derived notes are regenerated. External backups remain unchanged.")
            // The preview says why it adds fewer than the backup holds only when the repair's marker is the reason.
            if heldBack>0 {preview.heldBackBefore=marker}
            try exec("INSERT INTO metadata VALUES(?,?)",["restore_preview_"+preview.id,json(preview)])
            return preview
        }
    }
    public func cancelCanonicalRestore(_ id:String) throws {try exec("DELETE FROM metadata WHERE id=?",["restore_preview_"+id])}
    public func confirmCanonicalRestore(_ candidate:MemoryStore,previewID:String,confirmed:Bool,now:Date=Date()) throws -> CanonicalRestoreReceipt {
        guard confirmed,home.standardizedFileURL.resolvingSymlinksInPath() != candidate.home.standardizedFileURL.resolvingSymlinksInPath() else {throw MemError.denied}
        // Candidate is read-locked throughout adoption. All writes to the active
        // SQLite store are one transaction, with no rename of an open database.
        return try candidate.readSnapshot {
            let snapshot=try candidate.canonicalRows(now:now,strict:true)
            return try transaction {
                var writeBound=BackupBound()
                if let body=try rows("SELECT body FROM metadata WHERE id=?",["restore_receipt_"+previewID]).first?.first {return try decode(CanonicalRestoreReceipt.self,body)}
                guard let body=try rows("SELECT body FROM metadata WHERE id=?",["restore_preview_"+previewID]).first?.first else {throw MemError.invalid("Restore preview missing or cancelled")}
                let preview=try decode(CanonicalRestorePreview.self,body)
                guard timestamp(preview.expiresAt).map({$0>=now})==true,try coreSnapshotFence()==preview.authority,
                      snapshot.fence==preview.candidate,snapshot.digest==preview.candidateDigest,
                      try captureStatus()["state"]=="off" else {throw MemError.invalid("Restore changed; review again")}
                try ensureMigrationTables()
                // The container worker stages required owned assets first. Never
                // adopt a dangling attachment reference or copy an external file.
                for row in snapshot.tables["migration_originals"] ?? [] {
                    let entry=try decode(MigrationEntry.self,row[1])
                    for asset in entry.attachments {
                        let url=home.appendingPathComponent("migration-attachments/"+asset.sha256)
                        guard url.standardizedFileURL==url.resolvingSymlinksInPath() else {throw MemError.invalid("Restore asset path must not be linked")}
                        let data=try LegacyMigration.file(url,limit:64*1024*1024)
                        guard data.count==asset.bytes,LegacyMigration.hash(data)==asset.sha256 else {throw MemError.invalid("Restore requires verified owned assets before adoption")}
                    }
                }
                let added=Set(preview.addedActionIDs)
                for row in snapshot.tables["records"] ?? [] where added.contains(row[0]) {try writeBound.check([row]);try insertCanonical("records",row)}
                for row in snapshot.tables["tombstones"] ?? [] {try writeBound.check([row]);try deleteActionWithinTransaction(row[0])}
                for row in snapshot.tables["migration_originals"] ?? [] {
                    try writeBound.check([row])
                    if let original=try rows("SELECT body FROM migration_originals WHERE id=?",[row[0]]).first?.first {
                        guard original==row[1] else {throw MemError.invalid("Migration original conflict")}
                    } else {try insertCanonical("migration_originals",row)}
                }
                for row in snapshot.tables["typed_after"] ?? [] where added.contains(row[0]) {try writeBound.check([row]);try insertCanonical("typed_after",row)}
                for row in snapshot.tables["action_group_edits"] ?? [] where added.contains(row[1]) {
                    try exec("INSERT INTO action_group_edits(action_id,subject) VALUES(?,?)",[row[1],row[2]])
                }
                try exec("DELETE FROM grants");try exec("DELETE FROM receipts")
                try invalidateAllNotes();try invalidateDisclosure()
                let receipt=CanonicalRestoreReceipt(previewID:previewID,addedActionIDs:preview.addedActionIDs,revision:try disclosureRevision())
                try exec("DELETE FROM metadata WHERE id=?",["restore_preview_"+previewID])
                try exec("INSERT INTO metadata VALUES(?,?)",["restore_receipt_"+previewID,json(receipt)])
                return receipt
            }
        }
    }
}
