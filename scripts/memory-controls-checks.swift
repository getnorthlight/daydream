import Foundation
import Darwin
@testable import MemoryCore

private final class LinkFixture:OriginalSourceVerifier {
    var exists=true, readOnly=true, wrong=false, calls=0
    var during:(() throws -> Void)?
    func verify(url:String,deadline:Date) throws -> OriginalSourceCheck {
        calls += 1; try during?()
        return OriginalSourceCheck(url:wrong ? "https://other.example/" : url,exists:exists,readOnly:readOnly)
    }
}
@main struct ControlsChecks {
    static var count=0
    static func check(_ value:@autoclosure () throws -> Bool,_ name:String) throws {
        guard try value() else { throw MemError.invalid("FAIL: "+name) }
        count += 1; print("PASS: "+name)
    }
    static func rejects(_ name:String,_ body:() throws -> Void) throws {
        do { try body() } catch { count += 1; print("PASS: "+name); return }
        throw MemError.invalid("FAIL: "+name)
    }
    static func main() throws {
        setbuf(stdout,nil)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("macmem-controls-check-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let now=Date(), day=try DayScope.key(now,timezone:"UTC")
        let store=try MemoryStore(home:root,writable:true,automaticallySyncSearch:false)
        func event(_ id:String,_ title:String="Research project",offset:Double=0) -> Evidence {
            Evidence(id:id,at:iso(now.addingTimeInterval(offset)),kind:"mouse.click",app:"TextEdit",bundle:"com.apple.TextEdit",title:title,url:"https://example.org/project",synthetic:true)
        }
        for n in 0..<5 { _=try store.ingest(event("a\(n)",offset:Double(n)-10),now:now) }
        _=try store.ingest(event("unrelated","Other work"),now:now)
        let original=try store.permittedOriginal("a0",now:now)!
        let first=try store.action("a0",now:now)!
        let correction=try store.correctAction(id:"a0",text:"This was planning, not an application submission.",expectedRevision:first.revision,now:now)
        let edited=try store.action("a0",now:now)!
        try check(correction.version == 1 && edited.observedDescription == first.description && edited.description.contains("User correction"),"action correction labelled separately from observed description")
        try check(try store.permittedOriginal("a0",now:now) == original,"correction never changes immutable evidence")
        try rejects("stale editor revision rejected") { _=try store.correctAction(id:"a0",text:"conflicting edit",expectedRevision:first.revision,now:now) }
        try rejects("secret-like correction refused") { _=try store.correctAction(id:"a0",text:"password=secretvalue",expectedRevision:edited.revision,now:now) }
        let reloaded=try MemoryStore(home:root)
        try check(try reloaded.action("a0",now:now)?.correction?.version == 1,"correction persists through reload")
        _=try store.writePending(now:now)
        try check(try store.read("a0",now:now)?.summary.contains("User correction") == true,"writer cannot overwrite action correction")
        let document=SearchDocument.make(try store.read("a0",now:now)!)!
        try check(document.summary.contains("planning") && document.summary.contains("not observed"),"index projection uses labelled explicit user correction")
        try check(try store.searchResult(MemorySearchQuery("planning"),now:now).items.map(\.id) == ["a0"],"corrected description searchable locally")
        let group=try store.dayLayers(day:day,timezone:"UTC",now:now).activities.first{$0.actionIDs.contains("a0")}!
        let noteScope=MemoryActionScope(kind:"activity",id:group.id,day:day,timezone:"UTC")
        _=try store.correctNote(scope:noteScope,text:"A planning session, not a completed application.",expectedRevision:group.inputRevision,now:now)
        try store.setActionSubject(["a0"],subject:"Separated planning",now:now)
        let moved=try store.dayLayers(day:day,timezone:"UTC",now:now)
        try check(moved.activities.first{$0.actionIDs.contains("a0")}?.corrections?.first?.text?.contains("planning") == true,"note correction survives regrouping by referenced action IDs")
        let request=try store.prepareNote(kind:"day",day:day,timezone:"UTC",now:now)
        try check(request.corrections?.count == 1 && request.actions.first{$0.id == "a0"}?.correction != nil,"provider input includes note and action corrections")
        try rejects("edited words cannot be emitted as observed evidence") {
            _=try store.commitNote(NoteWriterOutput(requestID:request.id,title:"Day",bullets:[NoteBullet(text:"Application planning happened",actionIDs:["a0"],assertion:"observed")],generator:"fixture",generatorVersion:"1"),now:now)
        }
        _=try store.commitNote(NoteWriterOutput(requestID:request.id,title:"Day",bullets:[NoteBullet(text:"User clarified this was planning.",actionIDs:["a0"],assertion:"interpretation")],generator:"fixture",generatorVersion:"1"),now:now)
        let beforeFailure=try store.action("a0",now:now)!
        try store.exec("CREATE TRIGGER fail_correction BEFORE INSERT ON user_corrections BEGIN SELECT RAISE(ABORT,'synthetic'); END")
        try rejects("editor write failure surfaced") { _=try store.correctAction(id:"a0",text:"not committed",expectedRevision:beforeFailure.revision,now:now) }
        try store.exec("DROP TRIGGER fail_correction")
        try check(try store.action("a0",now:now)?.revision == beforeFailure.revision,"editor failure is atomic")
        _=try store.correctAction(id:"a0",text:nil,expectedRevision:beforeFailure.revision,now:now)
        try check(try store.action("a0",now:now)?.correction == nil && store.correctionHistory(kind:"action",targetID:"a0",now:now).count == 2,"clearing correction restores observation and retains user version history")

        let link=LinkFixture()
        try check(try store.originalSourceLink(actionID:"a1",now:now).url == nil,"unverified original URL is not offered as openable")
        let verified=try store.originalSourceLink(actionID:"a1",verifier:link,now:now)
        try check(verified.url == "https://example.org/project" && link.calls == 1,"exact original URL exposed only after read-only existence check")
        link.wrong=true
        try check(try store.originalSourceLink(actionID:"a1",verifier:link,now:now).url == nil,"resolver cannot replace original destination")
        link.wrong=false; link.exists=false
        try check(try store.originalSourceLink(actionID:"a1",verifier:link,now:now).url == nil,"missing original reports unavailable")
        link.exists=true; link.readOnly=false
        try check(try store.originalSourceLink(actionID:"a1",verifier:link,now:now).url == nil,"mutating original route rejected")
        link.readOnly=true; link.during={ try store.delete("a1") }
        try rejects("source deletion during link verification rejected") { _=try store.originalSourceLink(actionID:"a1",verifier:link,now:now) }
        var unsafe=event("unsafe"); unsafe.url="javascript:alert(1)"; _=try store.ingest(unsafe,now:now)
        try rejects("arbitrary schemes rejected before any original can be reopened") { _=try store.originalSourceLink(actionID:"unsafe",verifier:LinkFixture(),now:now) }

        let stale=try store.prepareDeletion(scope:MemoryActionScope(kind:"action",id:"a2"),now:now)
        _=try store.ingest(event("new-arrival"),now:now)
        try rejects("concurrent ingest invalidates exact deletion preview") { _=try store.executeDeletion(previewID:stale.id,confirmed:true,now:now) }
        let regrouped=try store.prepareDeletion(scope:MemoryActionScope(kind:"action",id:"a2"),now:now)
        try store.setActionSubject(["unrelated"],subject:"Different unrelated session",now:now)
        try rejects("regrouping cannot widen a confirmed deletion scope") { _=try store.executeDeletion(previewID:regrouped.id,confirmed:true,now:now) }
        let expired=try store.prepareDeletion(scope:MemoryActionScope(kind:"action",id:"a2"),now:now)
        try rejects("expired destructive preview rejected") { _=try store.executeDeletion(previewID:expired.id,confirmed:true,now:now.addingTimeInterval(301)) }
        let cancelled=try store.prepareDeletion(scope:MemoryActionScope(kind:"action",id:"a2"),now:now)
        try store.cancelDeletion(cancelled.id)
        try rejects("cancelled deletion cannot execute") { _=try store.executeDeletion(previewID:cancelled.id,confirmed:true,now:now) }
        let activeGroup=try store.dayLayers(day:day,timezone:"UTC",now:now).activities.first{$0.actionIDs.contains("a2")}!
        let preview=try store.prepareDeletion(scope:MemoryActionScope(kind:"activity",id:activeGroup.id,day:day,timezone:"UTC"),now:now)
        try check(Set(preview.actionIDs) == Set(activeGroup.actionIDs),"activity preview lists exact underlying actions")
        try rejects("deletion requires explicit confirmation") { _=try store.executeDeletion(previewID:preview.id,confirmed:false,now:now) }
        try store.exec("CREATE TRIGGER fail_delete BEFORE DELETE ON records WHEN old.id='a3' BEGIN SELECT RAISE(ABORT,'synthetic'); END")
        let oldFence=try store.coreSnapshotFence()
        try rejects("mid-cascade storage failure surfaced") { _=try store.executeDeletion(previewID:preview.id,confirmed:true,now:now) }
        try store.exec("DROP TRIGGER fail_delete")
        try check(try store.coreSnapshotFence() == oldFence && store.action("a2",now:now) != nil,"failed cascade rolls back records, tombstones and derivatives")
        let receipt=try store.executeDeletion(previewID:preview.id,confirmed:true,now:now)
        try check(receipt.actionIDs == preview.actionIDs && receipt.attachmentCleanup == "complete","exact activity cascade commits and reports cleanup separately")
        try check(try store.executeDeletion(previewID:preview.id,confirmed:true,now:now).deletedAt == receipt.deletedAt,"repeated deletion confirmation idempotent")
        try check(try reloaded.deletionReceipt(previewID:preview.id)?.actionIDs == preview.actionIDs,"committed deletion receipt survives reload")
        for id in preview.actionIDs { try check(try store.action(id,now:now) == nil && !store.ingest(event(id),now:now),"deleted action cannot be reopened or re-ingested: "+id) }
        try check(try store.action("unrelated",now:now) != nil && store.action("a0",now:now) != nil,"unrelated actions preserved")
        try check(try store.dayLayers(day:day,timezone:"UTC",now:now).activities.allSatisfy{ $0.corrections?.isEmpty != false },"deleted referenced action invalidates containing note correction")
        try check(preview.warning == DeletionPreview.notRecalled && ["Backups","exported copies","AI apps","cloud summaries","aren't deleted"].allSatisfy { preview.warning.contains($0) } && !preview.warning.contains("owned evidence"),"a moment's forget preview says, in plain words, that backups, exports and what AI apps or cloud summaries got aren't deleted")
        let wholeDay=try store.prepareDeletion(scope:MemoryActionScope(kind:"day",day:day,timezone:"UTC"),now:now)
        try check(wholeDay.warning.contains("ALL selected-day actions") && wholeDay.actionCount == 2,"whole-day preview explicitly names full destructive scope")
        try store.cancelDeletion(wholeDay.id)

        let fence=try store.withSnapshotCoordination { $0 }
        try check(fence.tombstoneCount >= preview.actionCount && fence.actionCount == 2,"snapshot coordination exposes exact deletion and action counts")
        let candidate=try MemoryStore(home:root.appendingPathComponent("candidate"),writable:true,automaticallySyncSearch:false)
        try candidate.exec("UPDATE metadata SET body=? WHERE id='core_store_id'",[fence.storeID])
        try candidate.exec("UPDATE metadata SET body=? WHERE id='policy'",[json(store.policy())])
        _=try candidate.ingest(event("a2"),now:now)
        let review=try store.validateRestoreCandidate(candidate,expectedCurrent:fence)
        try check(!review.canAdopt && review.conflicts.contains("subsequent_deletions_require_tombstone_replay"),"stale restore cannot silently reintroduce deleted actions")
        for row in try store.rows("SELECT id FROM tombstones") { try candidate.delete(row[0]) }
        for row in try store.rows("SELECT id,body,revision FROM records") { try candidate.exec("INSERT INTO records VALUES(?,?,?)",row) }
        for row in try store.rows("SELECT kind,target,version,body FROM user_corrections") { try candidate.exec("INSERT INTO user_corrections VALUES(?,?,?,?)",row) }
        try check(try store.validateRestoreCandidate(candidate,expectedCurrent:fence).canAdopt,"candidate safety passes only after current deletion and correction replay")
        _=try candidate.grant(client:"fixture",recipient:"fixture",scopes:["context"])
        try check(try store.validateRestoreCandidate(candidate,expectedCurrent:fence).conflicts.contains("candidate_grants_must_be_removed"),"restoring backup cannot grant new disclosure access")
        _=try store.ingest(event("after-review"),now:now)
        try rejects("concurrent active changes reject restore adoption fence") { _=try store.withRestoreCoordination(expected:fence) { true } }

        let countBefore=try store.coreSnapshotFence().actionCount
        let skipped=try store.chooseOnboarding(.scratch)
        try check(skipped.choice.rawValue == "Start From Scratch" && skipped.retainedActionCount == countBefore && skipped.explanation.contains("retained"),"Start From Scratch skips import without erasing existing memory")
        try check(try store.chooseOnboarding(.understand).choice.rawValue == "Understand What You’ve Done So Far","exact optional-import onboarding label")
        try check(try store.coreSnapshotFence().actionCount == countBefore,"onboarding selection never deletes, captures or grants")
        let fresh=try MemoryStore(home:root.appendingPathComponent("fresh"),writable:true,automaticallySyncSearch:false)
        try check(try fresh.chooseOnboarding(.scratch).retainedActionCount == 0 && fresh.captureStatus()["state"] == "off","fresh skip-import remains empty with capture OFF")
        let cleanupStore=try MemoryStore(home:root.appendingPathComponent("cleanup"),writable:true,automaticallySyncSearch:false)
        _=try cleanupStore.ingest(event("cleanup-action"),now:now)
        let linked=cleanupStore.home.appendingPathComponent("migration-attachments")
        try FileManager.default.createDirectory(at:root.appendingPathComponent("not-owned"),withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:linked,withDestinationURL:root.appendingPathComponent("not-owned"))
        let cleanupPreview=try cleanupStore.prepareDeletion(scope:MemoryActionScope(kind:"action",id:"cleanup-action"),now:now)
        let incomplete=try cleanupStore.executeDeletion(previewID:cleanupPreview.id,confirmed:true,now:now)
        try check(incomplete.attachmentCleanup == "pending_retry_required" && cleanupStore.action("cleanup-action",now:now) == nil,"cleanup failure remains visible without undoing committed tombstone")
        try FileManager.default.removeItem(at:linked)
        try check(try cleanupStore.executeDeletion(previewID:cleanupPreview.id,confirmed:true,now:now).attachmentCleanup == "complete","attachment cleanup retry is safe and idempotent")
        let importHome=root.appendingPathComponent("imported"), exportRoot=root.appendingPathComponent("selected-export")
        let importer=try MemoryStore(home:importHome,writable:true,automaticallySyncSearch:false)
        let attachment=Data("fabricated shared evidence attachment".utf8), digest=LegacyMigration.hash(attachment)
        try FileManager.default.createDirectory(at:exportRoot.appendingPathComponent("attachments"),withIntermediateDirectories:true)
        let externalFile=exportRoot.appendingPathComponent("attachments/"+digest)
        try attachment.write(to:externalFile)
        var entries=[MigrationEntry]()
        for n in 0..<3 {
            let sourceID="source-\(n)", namespace="synthetic-onboarding"
            let id="legacy_"+fingerprint(try json([namespace,"collector-event",sourceID]))
            let evidence=Evidence(id:id,at:iso(now),kind:"mouse.click",app:n == 2 ? "Passwords" : "TextEdit",bundle:n == 2 ? "com.apple.Passwords" : "com.apple.TextEdit",title:"Imported action")
            let raw=try json(["id":sourceID,"kind":"mouse.click","timestamp":iso(now)])
            entries.append(MigrationEntry(id:id,sourceID:sourceID,family:"collector-event",format:"history-segment-v1",at:iso(now),epochNanos:String(Int64(now.timeIntervalSince1970)*1_000_000_000),timezone:"UTC",raw:raw,rawSHA256:fingerprint(raw),deleted:false,evidence:evidence,summary:nil,end:nil,attachments:n == 2 ? [] : [MigrationAttachment(path:"attachments/"+digest,sha256:digest,bytes:attachment.count)]))
        }
        let snapshot=MigrationSnapshot(version:1,namespace:"synthetic-onboarding",entries:entries)
        let snapshotData=Data(try json(snapshot).utf8), snapshotHash=LegacyMigration.hash(snapshotData)
        let snapshotURL=exportRoot.appendingPathComponent("snapshot.json"); try snapshotData.write(to:snapshotURL)
        let importPreview=try importer.prepareOnboardingImport(snapshotURL:snapshotURL,expectedHash:snapshotHash,now:now)
        try check(!importPreview.blocked && importPreview.counts["accepted"] == 2 && importPreview.start != nil && importPreview.end != nil,"explicit source dry run shows counts and date range")
        try check(importPreview.counts["excluded_privacy_or_unverified_browser"] == 1,"policy exclusions separate from data loss")
        try rejects("onboarding import never starts without confirmation") { _=try importer.confirmOnboardingImport(previewID:importPreview.id,confirmed:false,acceptPolicyExclusions:true,now:now) }
        try rejects("policy exclusions require explicit acknowledgement") { _=try importer.confirmOnboardingImport(previewID:importPreview.id,confirmed:true,acceptPolicyExclusions:false,now:now) }
        let batch=try importer.confirmOnboardingImport(previewID:importPreview.id,confirmed:true,acceptPolicyExclusions:true,limit:1,now:now)
        try check(batch.next == 1 && !batch.complete,"onboarding reuses bounded transactional migration checkpoint")
        let finished=try importer.confirmOnboardingImport(previewID:importPreview.id,confirmed:true,acceptPolicyExclusions:true,limit:10,now:now)
        try check(finished.complete && importer.actions(now:now).actions.count == 2,"confirmed import resumes and exposes every allowed local action")
        try check(try importer.captureStatus()["state"] == "off" && importer.currentActions(now:now).actions.isEmpty,"imported history locally readable while remote current disclosure stays OFF")
        try rejects("import cannot grant MCP or remote access") { try importer.authorize(client:"fixture",recipient:"fixture",capability:"invented",scope:"detail") }
        let firstDelete=try importer.prepareDeletion(scope:MemoryActionScope(kind:"action",id:entries[0].id),now:now)
        _=try importer.executeDeletion(previewID:firstDelete.id,confirmed:true,now:now)
        let ownedFile=importHome.appendingPathComponent("migration-attachments/"+digest)
        try check(FileManager.default.fileExists(atPath:ownedFile.path),"shared owned attachment retained while another action needs it")
        let lastDelete=try importer.prepareDeletion(scope:MemoryActionScope(kind:"action",id:entries[1].id),now:now)
        _=try importer.executeDeletion(previewID:lastDelete.id,confirmed:true,now:now)
        try check(!FileManager.default.fileExists(atPath:ownedFile.path),"last dependency removal cleans owned evidence attachment")
        try check(try Data(contentsOf:externalFile) == attachment && Data(contentsOf:snapshotURL) == snapshotData,"external original and exported snapshot untouched by cascade")
        let replay=try importer.migrationDryRun(snapshot:snapshot,hash:snapshotHash,root:exportRoot,now:now)
        try check(replay.counts["excluded_deleted"] == 2,"tombstones prevent onboarding importer resurrection")
        _=try importer.ingest(event("summary-overlap"),now:now)
        let historical=MigrationEntry(id:"summary-only",sourceID:"summary-only",family:"activity-summary",format:"legacy-summary",at:iso(now),epochNanos:"0",timezone:"UTC",raw:"{}",rawSHA256:fingerprint("{}"),deleted:false,evidence:nil,summary:"Unmapped historical summary",end:iso(now),attachments:[])
        try importer.exec("INSERT INTO migration_originals VALUES(?,?,?,?)",[historical.id,json(historical),historical.rawSHA256,fingerprint(json(importer.policy()))])
        try rejects("unmapped historical summary overlap blocks ambiguous cascade without guessing") { _=try importer.prepareDeletion(scope:MemoryActionScope(kind:"action",id:"summary-overlap"),now:now) }
        try rejects("legacy direct delete cannot bypass ambiguous dependency guard") { try importer.delete("summary-overlap") }
        try check(try importer.action("summary-overlap",now:now) != nil,"unsupported summary relation causes no partial deletion")
        _=try fresh.ingest(event("hidden-day-action"),now:now)
        var exclusion=try fresh.policy(); exclusion.blockedApps=["com.apple.TextEdit"]; try fresh.updatePolicy(exclusion,now:now)
        try rejects("whole-day operation cannot silently omit excluded records") { _=try fresh.prepareDeletion(scope:MemoryActionScope(kind:"day",day:day,timezone:"UTC"),now:now) }
        print("Memory controls: \(count) checks passed. Synthetic only; no backup runtime or external navigation.")
    }
}
