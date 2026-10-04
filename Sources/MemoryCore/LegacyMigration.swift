import Foundation
import CryptoKit
import HistoryCore
import Darwin

public struct MigrationAttachment: Codable { public var path:String; public var sha256:String; public var bytes:Int }
public struct MigrationEntry: Codable {
    public var id:String; public var sourceID:String; public var family:String; public var format:String
    public var at:String; public var epochNanos:String; public var timezone:String
    public var raw:String; public var rawSHA256:String; public var deleted:Bool
    public var evidence:Evidence?; public var summary:String?; public var end:String?
    public var attachments:[MigrationAttachment]
}
public struct MigrationSourceDeletion:Codable {
    public var family:String; public var sourceID:String; public var id:String
    public init(family:String,sourceID:String,id:String) {self.family=family;self.sourceID=sourceID;self.id=id}
}
public struct MigrationSnapshot: Codable {
    public var version:Int; public var namespace:String; public var entries:[MigrationEntry]
    public var sourceDeletions:[MigrationSourceDeletion]? = nil
    public var deletionLedgerSHA256:String? = nil
}
public struct MigrationDecision: Codable { public var id:String; public var disposition:String }
public struct MigrationManifest: Codable {
    public var snapshotSHA256:String; public var policySHA256:String
    public var counts:[String:Int]; public var decisions:[MigrationDecision]; public var blocked:Bool
}
public struct MigrationProgress: Codable { public var snapshotSHA256:String; public var next:Int; public var total:Int; public var complete:Bool }
public struct MigratedPeriod: Codable {
    public var summary:String
    public var actions:[MemoryItem]
    public var historicalSummaries:[MigrationHistoricalSummary]
    public var next:String?
}
public struct MigrationHistoricalSummary: Codable { public var id:String; public var at:String; public var end:String?; public var text:String; public var provenance:String }

/// No discovery. Caller supplies a hash-pinned export and an explicitly initialized
/// isolated destination. Neither old collectors nor the Typesense service are used.
public enum LegacyMigration {
    public static func hash(_ data:Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    public static func load(_ url:URL, expected:String) throws -> MigrationSnapshot {
        let data=try file(url,limit:64*1024*1024)
        guard expected.count == 64, hash(data) == expected else { throw MemError.invalid("Snapshot hash mismatch") }
        let snapshot=try JSONDecoder().decode(MigrationSnapshot.self,from:data)
        _=try sourceDeletionIDs(snapshot)
        if snapshot.version==1 {
            let manifest=url.deletingLastPathComponent().appendingPathComponent("manifest.json")
            if FileManager.default.fileExists(atPath:manifest.path) {
                let value=try JSONSerialization.jsonObject(with:file(manifest,limit:1024*1024)) as? [String:Any]
                guard value?["snapshotSHA256"] as? String==expected,
                      let unmatched=value?["unmatchedDeletionRecords"] as? Int,unmatched==0 else {
                    throw MemError.invalid("Legacy export has unresolved deletion review; bind reviewed identities into a new v2 snapshot")
                }
            }
        }
        return snapshot
    }
    /// Snapshot hash pins exact reviewed identities, never fabricated evidence.
    public static func sourceDeletionIDs(_ snapshot:MigrationSnapshot) throws -> Set<String> {
        guard [1,2].contains(snapshot.version),!snapshot.namespace.isEmpty,snapshot.namespace.utf8.count<=100,
              snapshot.entries.count<=100000 else {throw MemError.invalid("Unsupported migration snapshot")}
        if snapshot.version==1 {
            guard snapshot.sourceDeletions==nil,snapshot.deletionLedgerSHA256==nil else {throw MemError.invalid("Deletion review requires snapshot v2")}
            return Set(snapshot.entries.filter(\.deleted).map(\.id))
        }
        guard let deletions=snapshot.sourceDeletions,deletions.count<=10000,
              let hash=snapshot.deletionLedgerSHA256,hash.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else {throw MemError.invalid("Missing or excessive deletion review")}
        var ids=Set<String>()
        for item in deletions {
            guard ["collector-event","activity-summary"].contains(item.family),!item.sourceID.isEmpty,item.sourceID.utf8.count<=500,
                  item.id == "legacy_"+fingerprint(try json([snapshot.namespace,item.family,item.sourceID])),ids.insert(item.id).inserted else {
                throw MemError.invalid("Invalid or duplicate scoped deletion identity")
            }
        }
        guard snapshot.entries.allSatisfy({$0.deleted == ids.contains($0.id)}) else {throw MemError.invalid("Entry deletion differs from reviewed scope")}
        return ids
    }
    public static func file(_ url:URL, limit:Int) throws -> Data {
        guard url.isFileURL else { throw MemError.invalid("Local snapshot file required") }
        let fd=open(url.path,O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw MemError.invalid("Missing or linked migration file") }; defer { close(fd) }
        var before=stat(); guard fstat(fd,&before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size <= limit else { throw MemError.invalid("Unsupported migration file") }
        var data=Data(), buffer=[UInt8](repeating:0,count:65536)
        while true {
            let count=Darwin.read(fd,&buffer,buffer.count)
            guard count >= 0, data.count+count <= limit else { throw MemError.invalid("Migration file read failed or exceeded bound") }
            if count == 0 { break }; data.append(contentsOf:buffer.prefix(count))
        }
        var after=stat()
        guard fstat(fd,&after) == 0, before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw MemError.invalid("Migration file changed") }
        return data
    }
    static func attachment(_ ref:MigrationAttachment, root:URL) throws -> Data {
        guard ref.sha256.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,
              ref.path == "attachments/"+ref.sha256, (0...64*1024*1024).contains(ref.bytes) else { throw MemError.invalid("Invalid attachment reference") }
        let url=root.appendingPathComponent(ref.path)
        let resolvedRoot=root.standardizedFileURL.resolvingSymlinksInPath().path+"/"
        guard url.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot) else { throw MemError.invalid("Attachment escaped snapshot") }
        let data=try file(url,limit:64*1024*1024)
        guard data.count == ref.bytes, hash(data) == ref.sha256 else { throw MemError.invalid("Missing or changed attachment") }
        return data
    }
    static func carriesTypedWords(_ entry:MigrationEntry) -> Bool {
        guard let evidence=entry.evidence, evidence.kind == "keyboard.text_input" else { return false }
        if !evidence.text.isEmpty { return true }
        let raw=(try? JSONSerialization.jsonObject(with:Data(entry.raw.utf8))) as? [String:Any] ?? [:]
        return ((raw["key"] as? [String:Any])?["text"] as? String).map { !$0.isEmpty } ?? false
    }
    static func stableID(_ entry:MigrationEntry, namespace:String) throws -> String {
        // Match exporter UTF-8 JSON identity without relying on input object ordering.
        "legacy_" + fingerprint(try json([namespace,entry.family,entry.sourceID]))
    }
    static func strings(_ value:Any) -> [String] {
        if let string=value as? String { return [string] }
        if let array=value as? [Any] { return array.flatMap(strings) }
        if let object=value as? [String:Any] { return object.values.flatMap(strings) }
        return []
    }
    static func policyReason(_ entry:MigrationEntry, settings:PrivacySettings, now:Date) -> String? {
        guard let at=timestamp(entry.at) else { return "unsupported_timestamp" }
        if !settings.retention.permits(at,now:now) { return "excluded_retention" }
        if at > now.addingTimeInterval(30) { return "unsupported_future_timestamp" }
        guard let raw=try? JSONSerialization.jsonObject(with:Data(entry.raw.utf8)) as? [String:Any] else { return "unsupported_raw_record" }
        if let evidence=entry.evidence {
            guard let clean=Privacy.sanitized(evidence,settings:settings,now:now) else { return "excluded_privacy_or_unverified_browser" }
            // Lossless import never quietly replaces originals with sanitized text.
            guard clean == evidence else { return "excluded_requires_redaction" }
            let key=raw["key"] as? [String:Any] ?? [:], element=raw["element"] as? [String:Any] ?? [:], selection=raw["selection"] as? [String:Any] ?? [:]
            let texts=[key["text"],element["value"],selection["selectedText"]].compactMap { $0 as? String }.filter { !$0.isEmpty }
            if !texts.isEmpty && !settings.captureText { return "excluded_text_not_allowed" }
            if !texts.isEmpty {
                guard evidence.kind == "keyboard.text_input", element["value"] == nil, selection["selectedText"] == nil,
                      PreCapturePrivacy.nativeTypingAllowed(bundle:evidence.bundle,role:element["role"] as? String ?? "",url:evidence.url,secure:evidence.secure,settings:settings) else { return "excluded_legacy_text_scope_unverified" }
            }
            let extraText=texts + [element["title"],element["identifier"],(raw["diagnostic"] as? [String:Any])?["message"]].compactMap { $0 as? String }
            if extraText.contains(where:Privacy.secret) { return "excluded_sensitive_text" }
            return nil
        }
        // Old summaries often embed typed/copy text and multiple apps/URLs. Never
        // use their headline alone as proof the entire source passes policy.
        let extra=(raw["extra"] as? String).flatMap { try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any] } ?? [:]
        let fields=extra.isEmpty ? raw : extra
        let app=(fields["primary_app"] as? String) ?? ""
        guard !app.isEmpty else { return "excluded_summary_app_unmapped" }
        let apps=(fields["apps"] as? [String] ?? [])+[app]
        if apps.contains(where: { settings.blockedApps.contains($0) || PrivacySettings.sensitiveApps.contains($0) || $0.range(of:"(?i)(chrome|safari|firefox|browser|password)",options:.regularExpression) != nil }) { return "excluded_summary_scope_unverified" }
        if !settings.blockedApps.isEmpty { return "excluded_summary_bundle_unmapped" }
        for url in (fields["urls"] as? [String] ?? [])+[(raw["uri"] as? String) ?? ""] where !url.isEmpty {
            let e=Evidence(id:entry.id,at:entry.at,kind:"window.changed",app:app,url:url)
            guard Privacy.sanitized(e,settings:settings,now:now) == e else { return "excluded_summary_url" }
        }
        let textFields=[raw["typed_text"],raw["copied_text"]].compactMap { $0 as? String }.filter { !$0.isEmpty }
        if !textFields.isEmpty || (entry.summary ?? "").contains("\n\nTyped:") || (entry.summary ?? "").contains("\n\nCopied:") {
            // Summary metadata cannot prove native field role or distinguish
            // authored text from selected/copied content under typed-only consent.
            return settings.captureText ? "excluded_legacy_text_scope_unverified" : "excluded_text_not_allowed"
        }
        if (textFields + [entry.summary ?? ""] + (fields["titles"] as? [String] ?? [])).contains(where:Privacy.secret) { return "excluded_sensitive_text" }
        return nil
    }
}

extension MemoryStore {
    public func initializeMigrationDestination() throws {
        try transaction {
            guard try rows("SELECT id FROM records LIMIT 1").isEmpty,
                  try rows("SELECT id FROM metadata WHERE id='capture'").isEmpty else { throw MemError.invalid("Destination is not unused") }
            try exec("CREATE TABLE IF NOT EXISTS migration_originals(id TEXT PRIMARY KEY, body TEXT NOT NULL, raw_hash TEXT NOT NULL, policy_hash TEXT NOT NULL)")
            try exec("CREATE TABLE IF NOT EXISTS migration_batches(id TEXT PRIMARY KEY, policy_hash TEXT NOT NULL, next INTEGER NOT NULL)")
            try exec("INSERT OR IGNORE INTO metadata VALUES('migration_destination','isolated-v1')")
        }
    }
    func validateMigrationDestination() throws {
        guard try rows("SELECT body FROM metadata WHERE id='migration_destination'").first?.first == "isolated-v1",
              try rows("SELECT id FROM metadata WHERE id='capture'").isEmpty,
              try rows("SELECT id FROM grants LIMIT 1").isEmpty,
              !FileManager.default.fileExists(atPath:home.appendingPathComponent("search-typesense.json").path) else { throw MemError.invalid("Requires isolated destination, no recorder, grants or search configuration") }
    }
    public func migrationDryRun(snapshot:MigrationSnapshot, hash:String, root:URL, now:Date=Date()) throws -> MigrationManifest {
        try validateMigrationDestination()
        let sourceDeleted=try LegacyMigration.sourceDeletionIDs(snapshot)
        let settings=try policy(), policyHash=fingerprint(try json(settings))
        var seen=[String:String](), decisions=[MigrationDecision](), counts=[String:Int](), blocked=false
        try checkSourceDeletionConflicts(sourceDeleted)
        if !sourceDeleted.isEmpty {counts["reviewed_source_deletions"]=sourceDeleted.count}
        for entry in snapshot.entries {
            var reason="accepted"
            if entry.id != (try LegacyMigration.stableID(entry,namespace:snapshot.namespace)) || fingerprint(entry.raw) != entry.rawSHA256 || timestamp(entry.at) == nil || !["collector-event","activity-summary"].contains(entry.family) {
                reason="unsupported_identity_or_hash"
            } else if let evidence=entry.evidence, evidence.id != entry.id || evidence.at != entry.at || evidence.synthetic || HistoryEventKind(rawValue:evidence.kind) == nil {
                reason="unsupported_event_projection"
            } else if (entry.family == "collector-event") != (entry.evidence != nil) || (entry.family == "activity-summary") != (entry.summary != nil) {
                reason="unsupported_record_family"
            } else if let prior=seen[entry.id], prior != entry.rawSHA256 { reason="conflicting_same_source_record" }
            else if let prior=try rows("SELECT raw_hash FROM migration_originals WHERE id=?",[entry.id]).first?.first, prior != entry.rawSHA256 { reason="conflicting_existing_source_record" }
            else if try entry.deleted || sourceDeleted.contains(entry.id) || !rows("SELECT id FROM tombstones WHERE id=?",[entry.id]).isEmpty { reason="excluded_deleted" }
            else if let policyReason=LegacyMigration.policyReason(entry,settings:settings,now:now) { reason=policyReason }
            // Imported originals keep their raw JSON, so typed words would stay
            // in plain text. Typed words are never imported.
            else if LegacyMigration.carriesTypedWords(entry) { reason="excluded_typed_text_not_imported" }
            else if seen[entry.id] != nil { reason="duplicate_same_source" }
            else if !(try rows("SELECT id FROM migration_originals WHERE id=?",[entry.id])).isEmpty { reason="already_imported" }
            if !reason.hasPrefix("unsupported") {
                do { for ref in entry.attachments { _=try LegacyMigration.attachment(ref,root:root) } }
                catch { reason="unsupported_missing_or_changed_attachment" }
            }
            if reason.hasPrefix("unsupported") || reason.hasPrefix("conflicting") { blocked=true }
            seen[entry.id]=entry.rawSHA256
            counts[reason,default:0] += 1
            decisions.append(MigrationDecision(id:entry.id,disposition:reason))
        }
        return MigrationManifest(snapshotSHA256:hash,policySHA256:policyHash,counts:counts,decisions:decisions,blocked:blocked)
    }
    /// One atomic chunk, including checkpoint. Safe to repeat after process death.
    public func importMigration(snapshot:MigrationSnapshot, hash:String, policyHash:String, root:URL, limit:Int=100, now:Date=Date(),expectedDisclosure:String?=nil) throws -> MigrationProgress {
        let manifest=try migrationDryRun(snapshot:snapshot,hash:hash,root:root,now:now)
        guard !manifest.blocked, manifest.policySHA256 == policyHash else { throw MemError.invalid("Dry run blocked or privacy policy changed") }
        let progress = try transaction {
            guard try expectedDisclosure == nil || expectedDisclosure == disclosureRevision() else { throw MemError.invalid("Destination changed since import preview") }
            try validateMigrationDestination()
            let sourceDeleted=try LegacyMigration.sourceDeletionIDs(snapshot)
            try checkSourceDeletionConflicts(sourceDeleted)
            // Atomic with each batch/checkpoint, including empty snapshots.
            // Existing tombstones already participate in backup and restore.
            for id in sourceDeleted {try exec("INSERT OR IGNORE INTO tombstones VALUES(?)",[id])}
            guard fingerprint(try json(policy())) == policyHash else { throw MemError.invalid("Privacy policy changed") }
            let previous=try rows("SELECT policy_hash,next FROM migration_batches WHERE id=?",[hash]).first
            guard previous == nil || previous![0] == policyHash else { throw MemError.invalid("Checkpoint policy mismatch") }
            let start=previous.flatMap { Int($0[1]) } ?? 0
            let end=min(snapshot.entries.count,start+max(1,min(500,limit)))
            for index in start..<end {
                let entry=snapshot.entries[index]
                if entry.deleted {
                    try exec("INSERT OR IGNORE INTO tombstones VALUES(?)",[entry.id])
                    try exec("DELETE FROM records WHERE id=?",[entry.id]); try exec("DELETE FROM summaries WHERE id=?",[entry.id])
                    try purgeMigrationOriginal(entry.id)
                    try purgeActionDerivatives(entry.id)
                    continue
                }
                guard manifest.decisions[index].disposition == "accepted" else { continue }
                // Repeat mutable checks under the write lock, not just at dry run.
                if !(try rows("SELECT id FROM tombstones WHERE id=?",[entry.id])).isEmpty { continue }
                if let prior=try rows("SELECT raw_hash FROM migration_originals WHERE id=?",[entry.id]).first?.first {
                    guard prior == entry.rawSHA256 else { throw MemError.invalid("Concurrent conflicting source record") }
                    continue
                }
                for ref in entry.attachments {
                    let data=try LegacyMigration.attachment(ref,root:root)
                    let directory=home.appendingPathComponent("migration-attachments")
                    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                    guard try directory.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true,
                          directory.resolvingSymlinksInPath().deletingLastPathComponent() == home.resolvingSymlinksInPath() else { throw MemError.invalid("Linked migration attachment directory rejected") }
                    let file=directory.appendingPathComponent(ref.sha256)
                    if FileManager.default.fileExists(atPath:file.path) {
                        guard LegacyMigration.hash(try LegacyMigration.file(file,limit:64*1024*1024)) == ref.sha256 else { throw MemError.invalid("Destination attachment mismatch") }
                    } else { try data.write(to:file,options:.withoutOverwriting); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path) }
                }
                try exec("INSERT INTO migration_originals VALUES(?,?,?,?)",[entry.id,json(entry),entry.rawSHA256,policyHash])
                if var evidence=entry.evidence {
                    evidence.id=entry.id
                    let body=try json(evidence)
                    guard try rows("SELECT id FROM records WHERE id=?",[entry.id]).isEmpty else { throw MemError.invalid("Canonical ID collision") }
                    try exec("INSERT INTO records VALUES(?,?,?)",[entry.id,body,fingerprint(body)])
                    legacyTypedClear = false // review G59: the next expiry scans for build 4 words again
                }
            }
            try exec("INSERT OR REPLACE INTO migration_batches VALUES(?,?,?)",[hash,policyHash,String(end)])
            try invalidateDisclosure()
            return MigrationProgress(snapshotSHA256:hash,next:end,total:snapshot.entries.count,complete:end == snapshot.entries.count)
        }
        cleanupMigrationAttachmentsAfterCommit()
        return progress
    }
    private func checkSourceDeletionConflicts(_ ids:Set<String>) throws {
        for id in ids {
            guard try rows("SELECT id FROM records WHERE id=? UNION ALL SELECT id FROM summaries WHERE id=? UNION ALL SELECT id FROM migration_originals WHERE id=?",[id,id,id]).isEmpty else {
                throw MemError.invalid("Reviewed source deletion conflicts with retained history; separate exact deletion review required")
            }
        }
    }
    /// All actions remain individually addressable; summary-only windows are separate.
    public func migratedPeriod(start:Date,end:Date,app:String?=nil,after:String?=nil,limit:Int=100,now:Date=Date()) throws -> MigratedPeriod {
        let disclosure=try disclosureRevision()
        let policyHash=fingerprint(try json(policy()))
        var cursor=["-9223372036854775808",""]
        if let after {
            guard after.count < 2048, let data=Data(base64Encoded:after), let parsed=try? JSONDecoder().decode([String].self,from:data), parsed.count == 2 else { throw MemError.invalid("Invalid migration cursor") }
            cursor=parsed
        }
        let rows=try rows("SELECT body FROM migration_originals WHERE CAST(json_extract(body,'$.epochNanos') AS INTEGER)>CAST(? AS INTEGER) OR (CAST(json_extract(body,'$.epochNanos') AS INTEGER)=CAST(? AS INTEGER) AND id>?) ORDER BY CAST(json_extract(body,'$.epochNanos') AS INTEGER),id LIMIT ?",[cursor[0],cursor[0],cursor[1],String(max(1,min(500,limit)))])
        var actions=[MemoryItem](), summaries=[MigrationHistoricalSummary](), last:String?
        for row in rows {
            let entry=try decode(MigrationEntry.self,row[0]); last=Data(try json([entry.epochNanos,entry.id]).utf8).base64EncodedString()
            guard let at=timestamp(entry.at), at >= start, at < end,
                  try self.rows("SELECT id FROM tombstones WHERE id=?",[entry.id]).isEmpty,
                  LegacyMigration.policyReason(entry,settings:try policy(),now:now) == nil else { continue }
            if entry.evidence != nil, let item=try read(entry.id,now:now) {
                if app == nil || item.evidence.app == app || item.evidence.bundle == app { actions.append(item) }
            } else if let summary=entry.summary {
                let raw=try JSONSerialization.jsonObject(with:Data(entry.raw.utf8)) as? [String:Any] ?? [:]
                let extra=(raw["extra"] as? String).flatMap { try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any] } ?? [:]
                if app == nil || (raw["primary_app"] as? String) == app || (extra["primary_app"] as? String) == app {
                    summaries.append(MigrationHistoricalSummary(id:entry.id,at:entry.at,end:entry.end,text:summary,provenance:"Historical derived summary; original actions unavailable"))
                }
            }
        }
        guard fingerprint(try json(policy())) == policyHash, try disclosure == disclosureRevision() else { throw MemError.invalid("Evidence changed during period read") }
        return MigratedPeriod(summary:"\(actions.count) distinct recorded actions and \(summaries.count) historical summaries in this page.",actions:actions,historicalSummaries:summaries,next:rows.count == max(1,min(500,limit)) ? last : nil)
    }
    public func migrationOriginal(_ id:String,now:Date=Date()) throws -> MigrationEntry? {
        let disclosure=try disclosureRevision()
        guard let row=try rows("SELECT body,policy_hash FROM migration_originals WHERE id=?",[id]).first,
              try rows("SELECT id FROM tombstones WHERE id=?",[id]).isEmpty,
              row[1] == fingerprint(try json(policy())) else { return nil }
        let entry=try decode(MigrationEntry.self,row[0])
        guard LegacyMigration.policyReason(entry,settings:try policy(),now:now) == nil, try disclosure == disclosureRevision() else { return nil }
        return entry
    }
    func purgeMigrationOriginal(_ id:String) throws {
        if !(try rows("SELECT name FROM sqlite_master WHERE type='table' AND name='migration_originals'")).isEmpty {
            try exec("DELETE FROM migration_originals WHERE id=?",[id])
        }
    }
    func expireMigrationOriginals(now:Date) throws {
        guard !(try rows("SELECT name FROM sqlite_master WHERE type='table' AND name='migration_originals'")).isEmpty else { return }
        guard let cutoff=try policy().retention.cutoff(now:now) else {return}
        for row in try rows("SELECT id,json_extract(body,'$.at') FROM migration_originals") {
            if let at=timestamp(row[1]), at < cutoff {
                try exec("INSERT OR IGNORE INTO tombstones VALUES(?)",[row[0]])
                try exec("DELETE FROM records WHERE id=?",[row[0]]); try exec("DELETE FROM summaries WHERE id=?",[row[0]])
                try purgeMigrationOriginal(row[0]); try invalidateDisclosure()
                try purgeActionDerivatives(row[0])
            }
        }
    }
    /// After a change has committed (summaries written, a moment deleted, a migration batch saved): tidy the
    /// attachment folder, but a folder that can't be tidied (files with no ledger to vouch for them, an unexpected file,
    /// a linked folder, a busy store) never fails the change that already happened. Nothing is removed then; every
    /// file stays for review and the next change tries again (gold G62: one leftover file made every summary pass and
    /// every delete fail, so the menu said the summary writer needed attention and a delete that worked said it didn't).
    /// A deletion that must report its cleanup uses `cleanupMigrationAttachments()` (MemoryControls).
    func cleanupMigrationAttachmentsAfterCommit() {
        do { try cleanupMigrationAttachments() } catch {}
    }
    public func cleanupMigrationAttachments() throws {
        guard writable else { throw MemError.denied }
        let directory=home.appendingPathComponent("migration-attachments")
        guard FileManager.default.fileExists(atPath:directory.path) else { return }
        guard try directory.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else { throw MemError.invalid("Linked migration attachment directory rejected") }
        // A cancelled restore may have reserved an empty asset directory before
        // any migration schema existed. There is nothing to clean in that case.
        // Without a ledger, nonempty directories must be preserved, not guessed.
        guard try !rows("SELECT name FROM sqlite_master WHERE type='table' AND name='migration_originals'").isEmpty else {
            guard try FileManager.default.contentsOfDirectory(atPath:directory.path).isEmpty else {
                throw MemError.invalid("Attachment ledger unavailable; untracked files preserved for review")
            }
            return
        }
        try transaction {
            let retained=try Set(rows("SELECT body FROM migration_originals").flatMap { try decode(MigrationEntry.self,$0[0]).attachments.map(\.sha256) })
            for file in try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil) {
                let name=file.lastPathComponent
                guard name.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil, !retained.contains(name) else { continue }
                guard LegacyMigration.hash(try LegacyMigration.file(file,limit:64*1024*1024)) == name else { throw MemError.invalid("Unexpected migration attachment; cleanup stopped") }
                try FileManager.default.removeItem(at:file)
            }
        }
    }
}
