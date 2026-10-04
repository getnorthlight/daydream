import Foundation
@testable import MemoryCore

@main struct OnboardingChecks {
    static var count=0
    static func check(_ value:Bool,_ name:String) {precondition(value,name);count+=1;print("PASS "+name)}
    static func rejects(_ name:String,_ operation:()throws->Void) {do {try operation();fatalError(name)} catch {check(true,name)}}
    static func main() throws {
        setbuf(stdout,nil)
        let root=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("onboarding-check-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let now=Date(),home=root.appendingPathComponent("current")
        let store=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false)
        let fence=try store.coreSnapshotFence()
        check(try MemoryStore(home:home).onboardingState()==nil,"read-only fresh getter returns nil")
        check(try store.coreSnapshotFence()==fence,"getter does not mutate store")
        _=try store.ingest(Evidence(id:"existing",at:iso(now),kind:"mouse.click",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Original",synthetic:true))
        let correction=try store.correctAction(id:"existing",text:"My correction",expectedRevision:store.action("existing")!.revision)
        _=try store.chooseOnboarding(.scratch)
        check(try MemoryStore(home:home).onboardingState()?.retainedActionCount==1,"skip state survives read-only reopen without erasing history")
        let namespace="isolated-fixture",snapshotURL=root.appendingPathComponent("source.json")
        var entries=[MigrationEntry]()
        let asset=Data("synthetic attachment".utf8),assetHash=LegacyMigration.hash(asset)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("attachments"),withIntermediateDirectories:true)
        try asset.write(to:root.appendingPathComponent("attachments/"+assetHash))
        for n in 0..<7 {
            let eventTime=n==6 ? now.addingTimeInterval(-86400):now
            let source="source-\(n)",family=n==6 ? "activity-summary":"collector-event"
            let id="legacy_"+fingerprint(try json([namespace,family,source]))
            let raw=try json(["id":source,"kind":"mouse.click","timestamp":iso(eventTime),"primary_app":"TextEdit"])
            let e=Evidence(id:id,at:iso(now),kind:"mouse.click",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Brief action \(n)")
            entries.append(MigrationEntry(id:id,sourceID:source,family:family,format:"history-segment-v1",at:iso(eventTime),epochNanos:String(Int64(eventTime.timeIntervalSince1970)*1_000_000_000+Int64(n)),timezone:"America/New_York",raw:raw,rawSHA256:fingerprint(raw),deleted:n==5,evidence:n==6 ? nil:e,summary:n==6 ? "Historical summary":nil,end:n==6 ? iso(eventTime.addingTimeInterval(60)):nil,attachments:n==0 ? [MigrationAttachment(path:"attachments/"+assetHash,sha256:assetHash,bytes:asset.count)]:[]))
        }
        let bytes=Data(try json(MigrationSnapshot(version:1,namespace:namespace,entries:entries)).utf8)
        try bytes.write(to:snapshotURL)
        let hash=LegacyMigration.hash(bytes)
        func prepare() throws -> StagedOnboardingImport {
            try store.prepareStagedOnboardingImport(snapshotURL:snapshotURL,expectedHash:hash,stagingURL:root.appendingPathComponent("stage-"+UUID().uuidString),now:now)
        }
        func stage(_ p:StagedOnboardingImport) throws -> StagedOnboardingImport {
            var result=p
            repeat {result=try store.stageOnboardingImport(id:p.id,confirmed:true,acceptPolicyExclusions:true,limit:2,now:now)} while result.progress?.complete != true
            return result
        }
        rejects("existing directory rejected") {_=try store.prepareStagedOnboardingImport(snapshotURL:snapshotURL,expectedHash:hash,stagingURL:home,now:now)}
        rejects("nested current-store destination rejected") {_=try store.prepareStagedOnboardingImport(snapshotURL:snapshotURL,expectedHash:hash,stagingURL:home.appendingPathComponent("stage"),now:now)}
        rejects("incorrect source pin rejected") {_=try store.prepareStagedOnboardingImport(snapshotURL:snapshotURL,expectedHash:String(repeating:"0",count:64),stagingURL:root.appendingPathComponent("wrong"),now:now)}
        let p=try prepare()
        print("Synthetic dispositions: \(p.source.counts)")
        check(p.source.counts["accepted"]==6 && p.source.counts["excluded_deleted"]==1,"review reports actions, historical summary and source deletion")
        check(try store.actions().actions.count==1,"preparation does not import into active memory")
        rejects("stage requires exact confirmation") {_=try store.stageOnboardingImport(id:p.id,confirmed:false,acceptPolicyExclusions:true,now:now)}
        rejects("policy exclusions require acceptance") {_=try store.stageOnboardingImport(id:p.id,confirmed:true,acceptPolicyExclusions:false,now:now)}
        rejects("incomplete stage cannot be adopted") {_=try store.prepareOnboardingAdoption(id:p.id,now:now)}
        let partial=try store.stageOnboardingImport(id:p.id,confirmed:true,acceptPolicyExclusions:true,limit:2,now:now)
        check(partial.progress?.next==2,"bounded staging commits one batch")
        let cold=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false)
        check(try cold.stagedOnboardingImport(id:p.id).progress?.next==2,"cold restart recovers stage identity and checkpoint")
        check(try MemoryStore(home:home).onboardingState()?.activeImportID==p.id,"getter recovers active import ID without UI-side saved state")
        _=try stage(partial)
        // Simulate response loss after stage commit but before active progress save.
        let savedBody=try store.rows("SELECT body FROM metadata WHERE id=?",["staged_import_"+p.id]).first![0]
        var savedObject=try JSONSerialization.jsonObject(with:Data(savedBody.utf8)) as! [String:Any]
        savedObject["view"]=try JSONSerialization.jsonObject(with:Data(try json(partial).utf8))
        try store.exec("UPDATE metadata SET body=? WHERE id=?",[String(decoding:try JSONSerialization.data(withJSONObject:savedObject),as:UTF8.self),"staged_import_"+p.id])
        let again=try store.stageOnboardingImport(id:p.id,confirmed:true,acceptPolicyExclusions:true,now:now)
        check(again.progress?.next==7,"completed staging retry remains idempotent")
        check(try store.actions().actions.count==1,"staged actions remain isolated")
        let review=try store.prepareOnboardingAdoption(id:p.id,now:now)
        check(review.adoption?.actionIDs.count==5 && review.adoption?.historicalSummaryIDs.count==1,"adoption reviews five distinct actions and separate historical summary")
        rejects("adoption requires separate confirmation") {_=try store.confirmOnboardingAdoption(id:p.id,confirmed:false,now:now)}
        let stageAsset=URL(fileURLWithPath:p.stagingPath).appendingPathComponent("migration-attachments/"+assetHash)
        try FileManager.default.moveItem(at:stageAsset,to:stageAsset.appendingPathExtension("held"))
        rejects("missing staged attachment rejects adoption") {_=try store.confirmOnboardingAdoption(id:p.id,confirmed:true,now:now)}
        check(try store.actions().actions.count==1,"missing attachment leaves current actions unchanged")
        try FileManager.default.moveItem(at:stageAsset.appendingPathExtension("held"),to:stageAsset)
        try store.exec("CREATE TRIGGER fail_import BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT,'synthetic'); END")
        rejects("persistence failure reports failed adoption") {_=try store.confirmOnboardingAdoption(id:p.id,confirmed:true,now:now)}
        check(try store.actions().actions.count==1 && store.stagedOnboardingImport(id:p.id).receipt==nil,"failed adoption rolls back actions and receipt")
        try store.exec("DROP TRIGGER fail_import")
        let receipt=try store.confirmOnboardingAdoption(id:p.id,confirmed:true,now:now)
        check(try receipt.actionIDs.count==5 && store.actions().actions.count==6,"adoption adds actions without replacing current store")
        check(try store.rows("SELECT body FROM user_corrections").first?.first==json(correction),"current correction ledger preserved byte-for-byte")
        check(try store.migrationOriginal(entries[0].id,now:now)?.raw==entries[0].raw,"immutable imported raw original preserved")
        check(try LegacyMigration.file(home.appendingPathComponent("migration-attachments/"+assetHash),limit:100)==asset,"verified owned attachment adopted")
        check(try store.rows("SELECT id FROM tombstones WHERE id=?",[entries[5].id]).count==1,"source absence tombstone retained against resurrection")
        check(try MemoryStore(home:home).onboardingState()?.status=="import_complete","read-only getter reports completed adoption")
        check(try store.captureStatus()["state"]=="off" && store.rows("SELECT id FROM grants").isEmpty,"adoption keeps capture and disclosure grants OFF")
        try FileManager.default.moveItem(at:URL(fileURLWithPath:p.stagingPath),to:root.appendingPathComponent("retained-stage"))
        check(try cold.confirmOnboardingAdoption(id:p.id,confirmed:true,now:now).revision==receipt.revision,"receipt retry works after stage disappears")
        rejects("completed adoption cannot be cancelled as if undone") {try store.cancelStagedOnboardingImport(id:p.id)}
        check(try Data(contentsOf:snapshotURL)==bytes,"source export remains unchanged")
        let cancelled=try prepare();try store.cancelStagedOnboardingImport(id:cancelled.id)
        rejects("cancel persists across reopen") {_=try cold.stageOnboardingImport(id:cancelled.id,confirmed:true,acceptPolicyExclusions:true,now:now)}
        let stale=try prepare();_=try stage(stale);_=try store.prepareOnboardingAdoption(id:stale.id,now:now)
        _=try store.correctAction(id:"existing",text:"New correction",expectedRevision:store.action("existing")!.revision)
        rejects("concurrent correction invalidates exact adoption") {_=try store.confirmOnboardingAdoption(id:stale.id,confirmed:true,now:now)}
        let deleted=try prepare();_=try stage(deleted);_=try store.prepareOnboardingAdoption(id:deleted.id,now:now)
        try store.delete(entries[4].id)
        rejects("deletion after review invalidates adoption") {_=try store.confirmOnboardingAdoption(id:deleted.id,confirmed:true,now:now)}
        let retry=try prepare();_=try stage(retry)
        let afterDelete=try store.prepareOnboardingAdoption(id:retry.id,now:now)
        check(afterDelete.source.counts["excluded_deleted"]==2 && afterDelete.adoption?.actionIDs.isEmpty==true,"current tombstones prevent reimport resurrection")
        let duplicate=try store.confirmOnboardingAdoption(id:retry.id,confirmed:true,now:now)
        check(try duplicate.actionIDs.isEmpty && store.action(entries[4].id)==nil,"repeat import cannot resurrect deleted action")
        let changed=try prepare();_=try stage(changed);_=try store.prepareOnboardingAdoption(id:changed.id,now:now)
        try Data("changed".utf8).write(to:snapshotURL)
        rejects("source mutation after review rejects adoption") {_=try store.confirmOnboardingAdoption(id:changed.id,confirmed:true,now:now)}
        try bytes.write(to:snapshotURL)
        let tampered=try prepare();_=try stage(tampered);_=try store.prepareOnboardingAdoption(id:tampered.id,now:now)
        let candidate=try MemoryStore(home:URL(fileURLWithPath:tampered.stagingPath),writable:true,automaticallySyncSearch:false)
        try candidate.exec("DELETE FROM records WHERE id=?",[entries[0].id])
        rejects("missing staged action cannot silently narrow adoption") {_=try store.confirmOnboardingAdoption(id:tampered.id,confirmed:true,now:now)}
        let expired=try prepare()
        rejects("expired review requires new review") {_=try store.stageOnboardingImport(id:expired.id,confirmed:true,acceptPolicyExclusions:true,now:now.addingTimeInterval(901))}
        try store.setCaptureState("recording",reason:"synthetic",now:now)
        rejects("capture ON blocks preparation") {_=try prepare()}
        try store.setCaptureState("off",reason:"synthetic",now:now)
        try store.exec("INSERT INTO grants VALUES('fixture','{}')")
        rejects("existing disclosure authority blocks preparation") {_=try prepare()}
        try store.exec("DELETE FROM grants")
        print("\(count) onboarding checks passed. Synthetic stores only; no capture, private import or grants enabled.")
    }
}
