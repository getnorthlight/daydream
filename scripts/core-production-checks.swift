import Foundation
@testable import MemoryCore

@main struct Checks {
    static var count=0
    static func check(_ value:Bool,_ label:String) {precondition(value,label);count+=1;print("PASS "+label)}
    static func rejects(_ label:String,_ work:() throws -> Void) {do {try work();fatalError(label)} catch {check(true,label)}}
    static func main() throws {
        setbuf(stdout,nil)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("core-production-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer {try? FileManager.default.removeItem(at:root)}
        func store(_ name:String) throws -> MemoryStore {try MemoryStore(home:root.appendingPathComponent(name),writable:true,automaticallySyncSearch:false)}
        let now=Date(),source=try store("source")
        // WAL changes are read through SQLite, not by copying memory.sqlite.
        try source.exec("PRAGMA journal_mode=WAL")
        for index in 0..<5 {_=try source.ingest(Evidence(id:"a\(index)",at:iso(now.addingTimeInterval(-Double(index))),kind:"window.changed",app:"Notes",title:"Research",synthetic:true),now:now)}
        let original=try source.action("a0",now:now)!
        _=try source.correctAction(id:"a0",text:"Corrected research topic",expectedRevision:original.revision,now:now)
        try source.exec("INSERT INTO grants VALUES('private-grant','do not export')")
        try source.exec("INSERT INTO metadata VALUES('cloud-secret','do not export')")
        // A store with level notes (tables and indexes made by setupLevelNotes) still backs up; the notes stay behind.
        check(try source.hasLevelNotes(),"a writable store has the level tables")
        try source.exec("INSERT INTO level_notes VALUES('level-day-1','day','2026-09-27','2026-09-27T00:00:00Z',0,0,'{}')")
        try source.exec("INSERT INTO level_edges VALUES('level-day-1','a0')")
        let target=try store("snapshot"),reader=try MemoryStore(home:source.home)
        let audit=try reader.exportCanonicalSnapshot(to:target,now:now)
        check(audit.counts["records"]==5,"real read-only WAL snapshot contains all five actions")
        check(try target.rows("SELECT id FROM grants").isEmpty,"grants excluded from projection")
        check(try target.rows("SELECT id FROM metadata WHERE id='cloud-secret'").isEmpty,"cloud state not copied")
        check(try target.inspectCanonicalSnapshot(now:now).capture=="off","native inspection capture OFF")
        check(try target.rows("SELECT id FROM level_notes UNION ALL SELECT parent FROM level_edges").isEmpty,"level notes are not exported")
        let crafted=try store("crafted-levels")
        _=try MemoryStore(home:source.home).exportCanonicalSnapshot(to:crafted,now:now)
        try crafted.exec("INSERT INTO level_notes VALUES('made-up','day','2026-09-27','2026-09-27T00:00:00Z',0,0,'{}')")
        rejects("a snapshot carrying level notes is refused") {_=try crafted.inspectCanonicalSnapshot(now:now)}
        let craftedEdge=try store("crafted-edges")
        _=try MemoryStore(home:source.home).exportCanonicalSnapshot(to:craftedEdge,now:now)
        try craftedEdge.exec("INSERT INTO level_edges VALUES('made-up','a0')")
        rejects("a snapshot carrying level edges is refused") {_=try craftedEdge.inspectCanonicalSnapshot(now:now)}
        try craftedEdge.exec("DELETE FROM level_edges");try craftedEdge.exec("CREATE INDEX level_extra ON level_notes(start)")
        rejects("an unknown index on the level tables is refused") {_=try craftedEdge.inspectCanonicalSnapshot(now:now)}
        check(try target.action("a0",now:now)?.description.contains("Corrected research topic")==true,"correction survived snapshot")
        check(try target.rows("SELECT body FROM records WHERE id='a0'").first==source.rows("SELECT body FROM records WHERE id='a0'").first,"immutable original unchanged")
        rejects("existing destination not overwritten") {_=try source.exportCanonicalSnapshot(to:target,now:now)}
        try source.delete("a1")
        _=try source.correctAction(id:"a0",text:"Newer user correction",expectedRevision:source.action("a0",now:now)!.revision,now:now)
        let fence=try source.coreSnapshotFence()
        _=try source.reconcileCanonicalSnapshot(target,expected:fence,now:now)
        check(try target.action("a1",now:now)==nil,"subsequent tombstone removes backed-up action")
        check(try target.action("a0",now:now)?.description.contains("Newer user correction")==true,"current correction wins reconciliation")
        check(try target.correctionHistory(kind:"action",targetID:"a0",now:now).count==2,"all correction versions preserved")
        // Simulate a recoverable missing current record, not a deletion: no tombstone.
        try source.exec("DELETE FROM records WHERE id='a4'");try source.invalidateDisclosure()
        let preview=try source.prepareCanonicalRestore(target,now:now)
        check(preview.addedActionIDs==["a4"],"preview lists exact restored IDs")
        rejects("confirmation required") {_=try source.confirmCanonicalRestore(target,previewID:preview.id,confirmed:false,now:now)}
        try source.cancelCanonicalRestore(preview.id)
        rejects("cancel preserves originals") {_=try source.confirmCanonicalRestore(target,previewID:preview.id,confirmed:true,now:now)}
        let raced=try source.prepareCanonicalRestore(target,now:now)
        _=try source.ingest(Evidence(id:"late",at:iso(now),kind:"window.changed",app:"Notes",synthetic:true),now:now)
        rejects("concurrent action invalidates restore preview") {_=try source.confirmCanonicalRestore(target,previewID:raced.id,confirmed:true,now:now)}
        let fresh=try source.prepareCanonicalRestore(target,now:now)
        try source.exec("CREATE TRIGGER reject_restore BEFORE INSERT ON records WHEN NEW.id='a4' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END")
        rejects("restore write failure rolls back whole transaction") {_=try source.confirmCanonicalRestore(target,previewID:fresh.id,confirmed:true,now:now)}
        check(try source.action("a4",now:now)==nil && source.rows("SELECT id FROM grants").count==1,"failed adoption preserves authority and source")
        try source.exec("DROP TRIGGER reject_restore")
        let receipt=try source.confirmCanonicalRestore(target,previewID:fresh.id,confirmed:true,now:now)
        check(receipt.addedActionIDs==["a4"],"native transactional adoption restores missing action")
        check(try source.action("late",now:now) != nil,"adoption retains unrelated current action")
        check(try source.action("a1",now:now)==nil,"adoption does not resurrect tombstone")
        check(try source.rows("SELECT id FROM grants").isEmpty,"adoption never reinstates grants")
        check(try source.confirmCanonicalRestore(target,previewID:fresh.id,confirmed:true,now:now).revision==receipt.revision,"confirmation retry idempotent")
        check(try source.captureStatus()["state"]=="off","adoption keeps capture OFF")
        let wrong=try store("wrong")
        rejects("different lineage rejected") {_=try source.reconcileCanonicalSnapshot(wrong,expected:source.coreSnapshotFence(),now:now)}
        let note=try source.prepareNote(kind:"day",day:String(iso(now).prefix(10)),timezone:"UTC",now:now)
        try source.validatePreparedNote(note.id,revisions:Dictionary(uniqueKeysWithValues:note.actions.map{($0.id,$0.revision)}),now:now)
        check(true,"durable prepared note validates current revisions")
        try source.cancelNote(note.id)
        rejects("cancelled provider dispatch rejected") {try source.validatePreparedNote(note.id,revisions:Dictionary(uniqueKeysWithValues:note.actions.map{($0.id,$0.revision)}),now:now)}
        let current=try source.currentActions(now:now)
        // Off is honest, canonical reads remain locally available.
        check(current.status != "current","capture OFF never claims activity current")
        let result=try source.searchResult(MemorySearchQuery("Research"),now:now)
        check(!result.items.isEmpty,"brief last-ten-second action discoverable without writer/index")
        let quick=Date(),started=ProcessInfo.processInfo.systemUptime
        _=try source.ingest(Evidence(id:"quick",at:iso(quick),kind:"window.changed",app:"Notes",title:"Momentary status check",synthetic:true))
        let independent=try MemoryStore(home:source.home)
        let quickResult=try independent.searchResult(MemorySearchQuery("Momentary",start:quick.addingTimeInterval(-10)))
        let elapsed=(ProcessInfo.processInfo.systemUptime-started)*1000
        check(quickResult.items.contains(where:{$0.id=="quick"}),"independent reader finds newly committed last-ten-second action")
        print("Synthetic commit-to-search visibility: \(String(format:"%.2f",elapsed)) ms")
        // Real canonical migration rows and owned asset, not a backup-only schema.
        let assetSource=try store("asset-source");try assetSource.initializeMigrationDestination()
        let bytes=Data("synthetic owned attachment".utf8),hash=LegacyMigration.hash(bytes)
        let assetDirectory=assetSource.home.appendingPathComponent("migration-attachments")
        try FileManager.default.createDirectory(at:assetDirectory,withIntermediateDirectories:false)
        try bytes.write(to:assetDirectory.appendingPathComponent(hash))
        let evidence=Evidence(id:"asset-action",at:iso(now),kind:"window.changed",app:"Notes",synthetic:true)
        _=try assetSource.ingest(evidence,now:now)
        let entry=MigrationEntry(id:evidence.id,sourceID:"original",family:"collector-event",format:"history-segment-v1",at:evidence.at,epochNanos:"0",timezone:"UTC",raw:"{}",rawSHA256:fingerprint("{}"),deleted:false,evidence:evidence,summary:nil,end:nil,attachments:[MigrationAttachment(path:"attachments/"+hash,sha256:hash,bytes:bytes.count)])
        try assetSource.exec("INSERT INTO migration_originals VALUES(?,?,?,?)",[entry.id,json(entry),entry.rawSHA256,"synthetic-policy"])
        let assetSnapshot=try store("asset-snapshot"),assetAudit=try assetSource.exportCanonicalSnapshot(to:assetSnapshot,now:now)
        check(assetAudit.assets==[hash] && !assetAudit.assetsVerified,"export names owned asset and does not claim container verification")
        check(try assetSource.canonicalBackupAsset(sha256:hash,expected:assetAudit.sourceFence!,now:now)==bytes,"native asset export verifies source fence and content hash")
        rejects("arbitrary file selector rejected") {_=try assetSource.canonicalBackupAsset(sha256:"../../private",expected:assetAudit.sourceFence!,now:now)}
        try assetSource.delete(entry.id)
        rejects("deletion revokes old backup asset export") {_=try assetSource.canonicalBackupAsset(sha256:hash,expected:assetAudit.sourceFence!,now:now)}
        // Exact 0221 artifact regression: cancelled NativeBackup.confirm can
        // reserve this empty directory before migration tables are initialized.
        let noMigration=try store("cancelled-restore-cleanup")
        _=try noMigration.ingest(Evidence(id:"delete-after-cancel",at:iso(now),kind:"mouse.click",app:"Notes",synthetic:true),now:now)
        let emptyAssets=noMigration.home.appendingPathComponent("migration-attachments")
        try FileManager.default.createDirectory(at:emptyAssets,withIntermediateDirectories:false)
        check(try noMigration.rows("SELECT name FROM sqlite_master WHERE name='migration_originals'").isEmpty,"cancelled-restore fixture has no migration ledger")
        try noMigration.delete("delete-after-cancel")
        check(try noMigration.action("delete-after-cancel",now:now)==nil,"delete succeeds after cancelled restore's empty directory")
        _=try noMigration.ingest(Evidence(id:"ui-delete-after-cancel",at:iso(now),kind:"mouse.click",app:"Notes",synthetic:true),now:now)
        let cleanPreview=try noMigration.prepareDeletion(scope:MemoryActionScope(kind:"action",id:"ui-delete-after-cancel"),now:now)
        let cleanReceipt=try noMigration.executeDeletion(previewID:cleanPreview.id,confirmed:true,now:now)
        check(cleanReceipt.attachmentCleanup=="complete","UI deletion receipt reports empty-directory cleanup complete")
        let untracked=emptyAssets.appendingPathComponent("untracked-fixture")
        try Data("keep this synthetic file".utf8).write(to:untracked)
        rejects("missing ledger cannot authorize deletion of nonempty directory") {try noMigration.cleanupMigrationAttachments()}
        check(try String(contentsOf:untracked)=="keep this synthetic file","untracked bytes preserved for review")
        print("\(count) native core production checks passed")
    }
}
