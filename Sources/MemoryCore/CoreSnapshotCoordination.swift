import Foundation
import CryptoKit

public struct CoreSnapshotFence:Codable,Equatable {
    public var storeID:String
    public var disclosureRevision:String
    public var policyRevision:String
    public var deletionRevision:String
    public var correctionRevision:String
    public var actionCount:Int
    public var tombstoneCount:Int
}
public struct TombstonePage:Codable { public var ids:[String]; public var next:String?; public var revision:String }
public struct RestoreSafetyReview:Codable {
    /// Core policy checks only. Not backup integrity or active-file adoption proof.
    public var canAdopt:Bool
    public var conflicts:[String]
    public var active:CoreSnapshotFence
    public var candidate:CoreSnapshotFence
}
extension MemoryStore {
    /// Hash in bounded pages; includes pre-upgrade and migration tombstones.
    public func deletionRevision() throws -> String {
        var hash=SHA256(), after=""
        while true {
            let batch=try rows("SELECT id FROM tombstones WHERE id>? ORDER BY id LIMIT 500",[after])
            for row in batch { hash.update(data:Data((try json(row[0])+"\n").utf8)) }
            guard batch.count == 500 else { break }; after=batch.last![0]
        }
        return hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
    func correctionRevision() throws -> String {
        guard try hasMemoryControls() else { return fingerprint("") }
        var hash=SHA256(), offset=0
        while true {
            let batch=try rows("SELECT body FROM user_corrections ORDER BY kind,target,version LIMIT 100 OFFSET ?",[String(offset)])
            for row in batch { hash.update(data:Data((row[0]+"\n").utf8)) }
            guard batch.count == 100 else { break }; offset += batch.count
        }
        return hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
    public func coreSnapshotFence() throws -> CoreSnapshotFence {
        let revision=try disclosureRevision()
        guard let identity=try rows("SELECT body FROM metadata WHERE id='core_store_id'").first?.first else { throw MemError.invalid("Store needs core schema initialization before backup coordination") }
        let result=CoreSnapshotFence(storeID:identity,disclosureRevision:revision,policyRevision:try policy().revision,deletionRevision:try deletionRevision(),correctionRevision:try correctionRevision(),actionCount:Int(try rows("SELECT count(*) FROM records").first![0])!,tombstoneCount:Int(try rows("SELECT count(*) FROM tombstones").first![0])!)
        guard try revision == disclosureRevision() else { throw MemError.invalid("Snapshot changed while reading fence") }
        return result
    }
    public func tombstonePage(after:String?=nil,limit:Int=500) throws -> TombstonePage {
        let revision=try disclosureRevision(), size=max(1,min(500,limit))
        let batch=try rows("SELECT id FROM tombstones WHERE id>? ORDER BY id LIMIT ?",[after ?? "",String(size+1)]).map{$0[0]}
        let digest=try deletionRevision()
        guard try revision == disclosureRevision() else { throw MemError.invalid("Deletion ledger changed; restart snapshot") }
        return TombstonePage(ids:Array(batch.prefix(size)),next:batch.count > size ? batch[size-1] : nil,revision:digest)
    }
    /// Coordination only, not a backup implementation. BackupRestore owns SQLite
    /// backup, hash verification, bounded I/O, filesystem adoption and reopen.
    public func withSnapshotCoordination<T>(_ operation:(CoreSnapshotFence) throws -> T) throws -> T {
        try transaction {
            let fence=try coreSnapshotFence(), result=try operation(fence)
            guard try fence == coreSnapshotFence() else { throw MemError.invalid("Snapshot changed during coordinated operation") }
            return result
        }
    }
    /// Validate/stage only. Never rename or replace an open SQLite database inside
    /// this callback. BackupRestore must separately drain/close every handle under
    /// its process-wide adoption lease, adopt atomically, reopen and verify.
    public func withRestoreCoordination<T>(expected:CoreSnapshotFence,operation:() throws -> T) throws -> T {
        try transaction {
            guard try coreSnapshotFence() == expected else { throw MemError.invalid("Active store changed; restore requires new review") }
            return try operation()
        }
    }
    public func validateRestoreCandidate(_ candidate:MemoryStore,expectedCurrent:CoreSnapshotFence) throws -> RestoreSafetyReview {
        let current=try coreSnapshotFence(), proposed=try candidate.coreSnapshotFence()
        guard current == expectedCurrent else { throw MemError.invalid("Active memory changed; repeat restore review") }
        var conflicts=[String]()
        if current.storeID != proposed.storeID { conflicts.append("different_store_identity") }
        if try json(policy()) != json(candidate.policy()) { conflicts.append("current_policy_must_be_preserved") }
        if current.correctionRevision != proposed.correctionRevision { conflicts.append("current_correction_history_requires_replay_or_review") }
        if try candidate.hasMemoryControls(), try !candidate.rows("SELECT c.target FROM user_corrections c,json_each(c.body,'$.actionIDs') refs LEFT JOIN records r ON r.id=refs.value WHERE r.id IS NULL LIMIT 1").isEmpty { conflicts.append("candidate_corrections_reference_missing_actions") }
        var after:String?
        repeat {
            let page=try tombstonePage(after:after)
            for id in page.ids {
                if try candidate.rows("SELECT id FROM tombstones WHERE id=?",[id]).isEmpty { conflicts.append("subsequent_deletions_require_tombstone_replay"); break }
            }
            after=page.next
        } while after != nil && !conflicts.contains("subsequent_deletions_require_tombstone_replay")
        if try !candidate.rows("SELECT records.id FROM records JOIN tombstones USING(id) LIMIT 1").isEmpty { conflicts.append("candidate_contains_deleted_actions") }
        if try !candidate.rows("SELECT name FROM sqlite_master WHERE name='migration_originals'").isEmpty,
           try !candidate.rows("SELECT migration_originals.id FROM migration_originals JOIN tombstones USING(id) LIMIT 1").isEmpty { conflicts.append("candidate_contains_deleted_migration_evidence") }
        if try !candidate.rows("SELECT id FROM grants LIMIT 1").isEmpty { conflicts.append("candidate_grants_must_be_removed") }
        if try !candidate.rows("SELECT id FROM receipts LIMIT 1").isEmpty { conflicts.append("candidate_disclosure_receipts_must_be_removed") }
        if try candidate.hasMemoryControls(), try !candidate.rows("SELECT id FROM deletion_previews WHERE state='pending' LIMIT 1").isEmpty { conflicts.append("candidate_pending_deletions_must_be_cancelled") }
        if try !candidate.rows("SELECT id FROM metadata WHERE id LIKE 'onboarding_import_%' OR id='switchover' LIMIT 1").isEmpty { conflicts.append("candidate_runtime_intents_require_review") }
        if try candidate.captureStatus()["state"] != "off" { conflicts.append("candidate_capture_must_be_off") }
        if try !candidate.rows("SELECT id FROM search_index_state LIMIT 1").isEmpty { conflicts.append("candidate_index_ledger_requires_reset") }
        if try !candidate.rows("SELECT id FROM metadata WHERE id LIKE 'search_%' LIMIT 1").isEmpty { conflicts.append("candidate_search_state_requires_reset") }
        if try candidate.hasActionLayers(), try !candidate.rows("SELECT id FROM generated_notes LIMIT 1").isEmpty || !candidate.rows("SELECT id FROM note_requests WHERE body<>'' LIMIT 1").isEmpty { conflicts.append("candidate_generated_caches_require_invalidation") }
        if FileManager.default.fileExists(atPath:candidate.home.appendingPathComponent("search-typesense.json").path) { conflicts.append("candidate_search_activation_requires_explicit_review") }
        guard try current == coreSnapshotFence(), try proposed == candidate.coreSnapshotFence() else { throw MemError.invalid("Restore review changed; repeat") }
        return RestoreSafetyReview(canAdopt:conflicts.isEmpty,conflicts:Array(Set(conflicts)).sorted(),active:current,candidate:proposed)
    }
}
