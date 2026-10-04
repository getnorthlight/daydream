import Foundation
import Darwin

// Foundation may rewrite /private temporary paths to their /var or /tmp
// aliases after mkdir. Use the filesystem's canonical path both before and
// after creation, so a persisted stage survives a separate CLI invocation.
private func importPhysicalPath(_ url:URL, new:Bool=false) throws -> String {
    let probe=new ? url.deletingLastPathComponent():url
    guard url.isFileURL,let resolved=realpath(probe.path,nil) else {throw MemError.invalid("Import path unavailable")}
    defer {free(resolved)}
    let base=String(cString:resolved)
    let physical=new ? URL(fileURLWithPath:base).appendingPathComponent(url.lastPathComponent).path:base
    let path=url.standardizedFileURL.path
    // Only macOS's system aliases are equivalent. A linked child or arbitrary
    // user-created alias still fails, including a replaced database or asset.
    guard path==physical || ((path.hasPrefix("/var/") || path.hasPrefix("/tmp/")) && "/private"+path==physical) else {
        throw MemError.invalid("Linked import path")
    }
    return physical
}

public struct StagedOnboardingImport:Codable {
    public var id:String
    public var stagingPath:String
    public var source:OnboardingImportPreview
    public var status:String
    public var progress:MigrationProgress?
    public var adoption:OnboardingAdoptionPreview?
    public var receipt:OnboardingAdoptionReceipt?
}
public struct OnboardingAdoptionPreview:Codable {
    public var actionIDs:[String]
    public var historicalSummaryIDs:[String]
    public var originalCount:Int
    public var tombstoneIDs:[String]
    public var expiresAt:String
    public var digest:String
}
public struct OnboardingAdoptionReceipt:Codable {
    public var importID:String
    public var actionIDs:[String]
    public var historicalSummaryIDs:[String]
    public var revision:String
}
private struct ImportSession:Codable {
    var view:StagedOnboardingImport
    var authority:CoreSnapshotFence
    var stageID:String
}
private struct ImportPayload {
    var originals:[[String]]
    var records:[[String]]
    var tombstones:[[String]]
    var digest:String {get throws {fingerprint(try json([originals,records,tombstones]))}}
}
extension MemoryStore {
    private func importOff(now:Date) throws {
        guard try captureStatus(now:now)["state"]=="off",
              try rows("SELECT id FROM grants LIMIT 1").isEmpty,
              try rows("SELECT id FROM note_requests WHERE body<>'' AND state='pending' LIMIT 1").isEmpty else {
            throw MemError.invalid("Import requires capture OFF, no active disclosure grants and drained note requests")
        }
    }
    private func importSession(_ id:String) throws -> ImportSession {
        guard let body=try rows("SELECT body FROM metadata WHERE id=?",["staged_import_"+id]).first?.first else {throw MemError.missing}
        return try decode(ImportSession.self,body)
    }
    private func saveImport(_ session:ImportSession) throws {
        try exec("INSERT OR REPLACE INTO metadata VALUES(?,?)",["staged_import_"+session.view.id,json(session)])
    }
    public func stagedOnboardingImport(id:String) throws -> StagedOnboardingImport {try importSession(id).view}
    private func checkedImport(_ id:String,now:Date) throws -> ImportSession {
        let session=try importSession(id)
        guard !["cancelled","adopted"].contains(session.view.status),
              timestamp(session.view.source.expiresAt).map({$0>=now})==true,
              try coreSnapshotFence()==session.authority else {throw MemError.invalid("Import expired, cancelled or current memory changed; review a new stage")}
        try importOff(now:now)
        return session
    }
    private func openImportStage(_ session:ImportSession,writable:Bool) throws -> MemoryStore {
        let path=URL(fileURLWithPath:session.view.stagingPath)
        let active=try importPhysicalPath(home)
        let physical=try importPhysicalPath(path)
        guard physical != active,!physical.hasPrefix(active+"/"),
              FileManager.default.fileExists(atPath:path.appendingPathComponent("memory.sqlite").path),
              !(try importPhysicalPath(path.appendingPathComponent("memory.sqlite"))).isEmpty else {throw MemError.invalid("Stage missing or linked")}
        let stage=try MemoryStore(home:path,writable:writable,automaticallySyncSearch:false)
        guard try stage.coreSnapshotFence().storeID==session.stageID,
              try stage.rows("SELECT body FROM metadata WHERE id='onboarding_stage_owner'").first?.first==session.view.id else {throw MemError.invalid("Different stage identity")}
        try stage.validateMigrationDestination()
        return stage
    }
    private func pinnedImport(_ session:ImportSession) throws -> MigrationSnapshot {
        try LegacyMigration.load(URL(fileURLWithPath:session.view.source.snapshotPath),expected:session.view.source.snapshotSHA256)
    }
    /// stagingURL must be a NEW app-owned sibling temporary directory. Never the
    /// current store, its child, a reused directory, or a supplied database file.
    public func prepareStagedOnboardingImport(snapshotURL:URL,expectedHash:String,stagingURL:URL,now:Date=Date()) throws -> StagedOnboardingImport {
        let source=try LegacyMigration.load(snapshotURL,expected:expectedHash)
        guard source.entries.count<=10000 else {throw MemError.invalid("Import stage bound is 10000 source records")}
        var identities=[String:String]()
        for entry in source.entries {
            let body=try json(entry)
            guard identities[entry.id]==nil || identities[entry.id]==body else {throw MemError.invalid("Conflicting duplicate source identities")}
            identities[entry.id]=body
        }
        var assets=[String:Int]()
        for entry in source.entries {for asset in entry.attachments {
            guard asset.bytes>=0,asset.bytes<=64*1024*1024,assets[asset.sha256]==nil || assets[asset.sha256]==asset.bytes else {throw MemError.invalid("Invalid asset bound")}
            assets[asset.sha256]=asset.bytes
        }}
        guard assets.values.reduce(Int64(0),{ $0+Int64($1) })<=64*1024*1024 else {throw MemError.invalid("Import assets exceed 64 MiB")}
        let stagePath=stagingURL.standardizedFileURL,active=try importPhysicalPath(home),physical=try importPhysicalPath(stagePath,new:true)
        guard stagePath.isFileURL,physical != active,
              !physical.hasPrefix(active+"/"),!active.hasPrefix(physical+"/"),
              !FileManager.default.fileExists(atPath:stagePath.path) else {throw MemError.invalid("A new isolated staging directory is required")}
        return try transaction {
            try importOff(now:now)
            let authority=try coreSnapshotFence(),id=UUID().uuidString
            let deleted=try rows("SELECT id FROM tombstones ORDER BY id LIMIT 20001")
            guard deleted.count<=20000 else {throw MemError.invalid("Deletion ledger exceeds bounded stage; no import performed")}
            // Atomic mkdir refuses another process claiming the chosen path.
            guard mkdir(stagePath.path,0o700)==0 else {throw MemError.invalid("Could not reserve new staging directory")}
            let stage=try MemoryStore(home:stagePath,writable:true,automaticallySyncSearch:false)
            try stage.exec("UPDATE metadata SET body=? WHERE id='policy'",[json(policy())])
            try stage.initializeMigrationDestination()
            for row in deleted {try stage.exec("INSERT INTO tombstones VALUES(?)",row)}
            try stage.exec("INSERT INTO metadata VALUES('onboarding_stage_owner',?)",[id])
            let preview=try stage.prepareOnboardingImport(snapshotURL:snapshotURL,expectedHash:expectedHash,now:now)
            let view=StagedOnboardingImport(id:id,stagingPath:stagePath.path,source:preview,status:"review",progress:nil,adoption:nil,receipt:nil)
            try saveImport(ImportSession(view:view,authority:authority,stageID:stage.coreSnapshotFence().storeID))
            let state=MemoryOnboardingState(choice:.understand,status:"awaiting_import_confirmation",retainedActionCount:authority.actionCount,explanation:"Review the pinned source before staging; existing memory is retained.",activeImportID:id)
            try exec("INSERT OR REPLACE INTO metadata VALUES('onboarding',?)",[json(state)])
            return view
        }
    }
    /// One existing transactional migration batch. Crash between stage commit
    /// and response is recoverable from migration_batches, not a second import.
    public func stageOnboardingImport(id:String,confirmed:Bool,acceptPolicyExclusions:Bool,limit:Int=100,now:Date=Date()) throws -> StagedOnboardingImport {
        guard confirmed else {throw MemError.denied}
        return try transaction {
            var session=try checkedImport(id,now:now)
            guard !session.view.source.blocked,acceptPolicyExclusions || !session.view.source.counts.contains(where:{$0.key.hasPrefix("excluded") && $0.value>0}) else {throw MemError.denied}
            let stage=try openImportStage(session,writable:true),snapshot=try pinnedImport(session)
            let progress=try stage.importMigration(snapshot:snapshot,hash:session.view.source.snapshotSHA256,policyHash:session.view.source.policySHA256,root:URL(fileURLWithPath:session.view.source.snapshotPath).deletingLastPathComponent(),limit:limit,now:now)
            session.view.progress=progress;session.view.status=progress.complete ? "staged":"staging";session.view.adoption=nil
            try saveImport(session);return session.view
        }
    }
    private func importPayload(_ stage:MemoryStore,session:ImportSession,now:Date) throws -> ImportPayload {
        let snapshot=try pinnedImport(session)
        guard try json(stage.policy())==json(policy()),
              try stage.rows("SELECT next FROM migration_batches WHERE id=?",[session.view.source.snapshotSHA256]).first?.first==String(snapshot.entries.count) else {throw MemError.invalid("Staging incomplete or policy changed")}
        let entries=Dictionary(snapshot.entries.map{($0.id,$0)},uniquingKeysWith: {first,_ in first})
        let currentDeleted=Set(try rows("SELECT id FROM tombstones").map{$0[0]})
        let sourceDeleted=Set(snapshot.entries.filter(\.deleted).map(\.id)).union(try LegacyMigration.sourceDeletionIDs(snapshot))
        let stageDeleted=Set(try stage.rows("SELECT id FROM tombstones").map{$0[0]})
        guard stageDeleted==currentDeleted.union(sourceDeleted) else {throw MemError.invalid("Staged deletion ledger changed")}
        let settings=try policy()
        let expectedIDs=Set(entries.values.filter{entry in
            !stageDeleted.contains(entry.id) && LegacyMigration.policyReason(entry,settings:settings,now:now)==nil
        }.map(\.id))
        let originals=try stage.rows("SELECT id,body,raw_hash,policy_hash FROM migration_originals ORDER BY id LIMIT 10001")
        let records=try stage.rows("SELECT id,body,revision FROM records ORDER BY id LIMIT 10001")
        guard originals.count<=10000,records.count<=10000,Set(originals.map{$0[0]})==expectedIDs else {throw MemError.invalid("Staging incomplete or exceeds bound")}
        var expectedRecords=[String:String]()
        for row in originals {
            guard let entry=entries[row[0]],!entry.deleted,try json(entry)==row[1],entry.rawSHA256==row[2],
                  row[3]==session.view.source.policySHA256,LegacyMigration.policyReason(entry,settings:try policy(),now:now)==nil,
                  try rows("SELECT id FROM tombstones WHERE id=?",[entry.id]).isEmpty else {throw MemError.invalid("Staged original changed or no longer permitted")}
            if let evidence=entry.evidence {expectedRecords[entry.id]=try json(evidence)}
        }
        guard records.count==expectedRecords.count,records.allSatisfy({expectedRecords[$0[0]]==$0[1] && fingerprint($0[1])==$0[2]}) else {throw MemError.invalid("Staged canonical projection changed")}
        for row in records {
            let existing=try rows("SELECT body FROM records WHERE id=?",[row[0]]).first?.first
            guard existing==nil || existing==row[1] else {throw MemError.invalid("Immutable action ID conflict")}
        }
        for id in sourceDeleted {
            guard try rows("SELECT id FROM records WHERE id=? UNION ALL SELECT id FROM summaries WHERE id=?",[id,id]).isEmpty else {throw MemError.invalid("Source deletion conflicts with current history; separate deletion review required")}
            if try !rows("SELECT name FROM sqlite_master WHERE name='migration_originals'").isEmpty {
                guard try rows("SELECT id FROM migration_originals WHERE id=?",[id]).isEmpty else {throw MemError.invalid("Source deletion conflicts with current original")}
            }
        }
        return ImportPayload(originals:originals,records:records,tombstones:sourceDeleted.sorted().map{[$0]})
    }
    public func prepareOnboardingAdoption(id:String,now:Date=Date()) throws -> StagedOnboardingImport {
        var session=try checkedImport(id,now:now)
        let stage=try openImportStage(session,writable:false)
        return try stage.readSnapshot {try transaction {
            session=try checkedImport(id,now:now)
            let payload=try importPayload(stage,session:session,now:now)
            let added=try payload.records.filter{try rows("SELECT id FROM records WHERE id=?",[$0[0]]).isEmpty}.map{$0[0]}
            let summaries=try payload.originals.filter{try decode(MigrationEntry.self,$0[1]).summary != nil}.map{$0[0]}
            session.view.adoption=OnboardingAdoptionPreview(actionIDs:added,historicalSummaryIDs:summaries,originalCount:payload.originals.count,tombstoneIDs:payload.tombstones.map{$0[0]},expiresAt:iso(now.addingTimeInterval(300)),digest:try payload.digest)
            session.view.status="awaiting_adoption";try saveImport(session);return session.view
        }}
    }
    public func cancelStagedOnboardingImport(id:String) throws {
        try transaction {
            var session=try importSession(id)
            guard session.view.receipt==nil else {throw MemError.invalid("Already adopted; cancellation cannot undo history")}
            session.view.status="cancelled";session.view.adoption=nil;try saveImport(session)
            if let body=try rows("SELECT body FROM metadata WHERE id='onboarding'").first?.first {
                var state=try decode(MemoryOnboardingState.self,body)
                if state.activeImportID==id {state.activeImportID=nil;state.status="import_cancelled";try exec("UPDATE metadata SET body=? WHERE id='onboarding'",[json(state)])}
            }
        }
    }
    public func confirmOnboardingAdoption(id:String,confirmed:Bool,now:Date=Date()) throws -> OnboardingAdoptionReceipt {
        guard confirmed else {throw MemError.denied}
        let saved=try importSession(id)
        if let receipt=saved.view.receipt {return receipt} // Exact retry needs no surviving temp files.
        let stage=try openImportStage(saved,writable:false)
        return try stage.readSnapshot {try transaction {
            var session=try checkedImport(id,now:now)
            let payload=try importPayload(stage,session:session,now:now)
            guard let preview=session.view.adoption,timestamp(preview.expiresAt).map({$0>=now})==true,
                  try preview.digest==payload.digest else {throw MemError.invalid("Adoption missing, expired or changed; review again")}
            try exec("CREATE TABLE IF NOT EXISTS migration_originals(id TEXT PRIMARY KEY,body TEXT NOT NULL,raw_hash TEXT NOT NULL,policy_hash TEXT NOT NULL)")
            // Copy only reviewed, content-addressed owned assets, never source files.
            // An interrupted write can leave an unreferenced verified blob; retry
            // checks its hash. Canonical writes and receipt are one transaction.
            for row in payload.originals {
                let entry=try decode(MigrationEntry.self,row[1])
                for asset in entry.attachments {
                    let from=stage.home.appendingPathComponent("migration-attachments/"+asset.sha256)
                    _=try importPhysicalPath(from)
                    let data=try LegacyMigration.file(from,limit:64*1024*1024)
                    guard data.count==asset.bytes,LegacyMigration.hash(data)==asset.sha256 else {throw MemError.invalid("Staged asset changed")}
                    let directory=home.appendingPathComponent("migration-attachments")
                    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                    let target=directory.appendingPathComponent(asset.sha256)
                    _=try importPhysicalPath(target,new:!FileManager.default.fileExists(atPath:target.path))
                    if FileManager.default.fileExists(atPath:target.path) {
                        guard LegacyMigration.hash(try LegacyMigration.file(target,limit:64*1024*1024))==asset.sha256 else {throw MemError.invalid("Existing asset differs")}
                    } else {try data.write(to:target,options:.withoutOverwriting);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path)}
                }
                if let original=try rows("SELECT body FROM migration_originals WHERE id=?",[row[0]]).first?.first {
                    guard original==row[1] else {throw MemError.invalid("Existing immutable original differs")}
                } else {try exec("INSERT INTO migration_originals VALUES(?,?,?,?)",row)}
            }
            for row in payload.records where preview.actionIDs.contains(row[0]) {try exec("INSERT INTO records VALUES(?,?,?)",row)}
            legacyTypedClear = false // review G59: imported rows may hold build 4 words; the next expiry scans again
            // Only absence tombstones are adopted. Any conflict with current
            // evidence has already failed without deleting that evidence.
            for row in payload.tombstones {try exec("INSERT OR IGNORE INTO tombstones VALUES(?)",row)}
            try invalidateAllNotes();try invalidateDisclosure()
            let receipt=OnboardingAdoptionReceipt(importID:id,actionIDs:preview.actionIDs,historicalSummaryIDs:preview.historicalSummaryIDs,revision:try disclosureRevision())
            session.view.receipt=receipt;session.view.status="adopted";try saveImport(session)
            let state=MemoryOnboardingState(choice:.understand,status:"import_complete",retainedActionCount:Int(try rows("SELECT count(*) FROM records").first![0])!,explanation:"Reviewed history added. Existing memory retained. Capture and grants remain OFF.")
            try exec("INSERT OR REPLACE INTO metadata VALUES('onboarding',?)",[json(state)])
            return receipt
        }}
    }
}
