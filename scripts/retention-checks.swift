// Only disposable fabricated stores. Never opens the default memory directory.
import Foundation
@testable import MemoryCore

@main struct RetentionChecks {
    static var count=0
    static func check(_ value:@autoclosure () throws -> Bool,_ name:String) throws {
        guard try value() else {throw MemError.invalid("FAIL: "+name)}
        count += 1; print("PASS: "+name)
    }
    static func rejects(_ name:String,_ work:() throws -> Void) throws {
        do {try work()} catch {count += 1;print("PASS: "+name);return}
        throw MemError.invalid("FAIL: "+name)
    }
    static func main() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("retention-check-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let now=timestamp("2026-09-14T00:00:00Z")!, old=now.addingTimeInterval(-4000*86400)
        func store(_ name:String)throws->MemoryStore {try MemoryStore(home:root.appendingPathComponent(name),writable:true,automaticallySyncSearch:false)}
        func event(_ id:String,_ at:Date)->Evidence {Evidence(id:id,at:iso(at),kind:"window.changed",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Orchid research",synthetic:true)}
        let s=try store("main")
        try check(try s.policy().retention == .never && s.policy().retentionDays == nil,"new profile defaults to explicit Never")
        let encoded=try json(s.policy())
        try check(encoded.contains("\"kind\":\"never\"") && !encoded.contains("retentionDays"),"Never uses tagged wire value without numeric sentinel")
        let legacy="{\"blockedApps\":[],\"blockedDomains\":[],\"captureText\":false,\"revision\":\"saved\",\"retentionDays\":30}"
        let finite=try decode(PrivacySettings.self,legacy)
        try check(finite.retention == .days(30) && finite.revision == "saved","legacy explicit finite policy unchanged")
        try check(try decode(PrivacySettings.self,json(finite)).retention == .days(30),"finite wire roundtrip")
        let legacyStore=try store("legacy")
        try legacyStore.exec("UPDATE metadata SET body=? WHERE id='policy'",[legacy])
        let reopened=try MemoryStore(home:root.appendingPathComponent("legacy"))
        try check(try reopened.policy().retention == .days(30) && reopened.rows("SELECT body FROM metadata WHERE id='policy'")[0][0] == legacy,"opening saved finite store preserves policy bytes without migration")
        for value in ["0","-1","366","null","\"never\""] {
            try rejects("invalid legacy retention "+value) {_=try decode(PrivacySettings.self,legacy.replacingOccurrences(of:"30",with:value))}
        }
        try rejects("missing persisted policy field fails closed") {_=try decode(PrivacySettings.self,legacy.replacingOccurrences(of:",\"retentionDays\":30",with:""))}
        try rejects("conflicting old/new retention fails closed") {_=try decode(PrivacySettings.self,legacy.replacingOccurrences(of:"\"retentionDays\":30",with:"\"retentionDays\":30,\"retention\":{\"kind\":\"never\"}"))}
        for value in ["{\"kind\":\"never\",\"days\":0}","{\"kind\":\"unknown\"}","{\"kind\":\"days\",\"days\":0}"] {
            try rejects("invalid tagged retention "+value) {_=try decode(MemoryRetention.self,value)}
        }
        try check(try s.ingest(event("old",old),now:now),"Never accepts permitted old source")
        let capture=try CaptureSession(store:s)
        try check(capture.state == "off","Never does not start recording")
        try capture.start(permitted:true,now:now)
        try check(try capture.record(event("recent",now),focusedFieldKnown:true,permitted:true,now:now),"synthetic capture entry accepts current source with Never")
        var secret=event("secret",now);secret.secure=true
        try check(try !capture.record(secret,focusedFieldKnown:true,permitted:true,now:now),"Never preserves secure rejection")
        try check(try !capture.record(event("unknown",now),focusedFieldKnown:false,permitted:true,now:now),"Never preserves unknown focus rejection")
        try check(try s.currentActions(now:now).actions.allSatisfy{$0.id != "old"},"Never does not label old source current")
        try capture.stop(now:now)
        _=try s.writePending(now:now.addingTimeInterval(8000*86400))
        try check(try s.read("old",now:now) != nil && s.action("old",now:now) != nil,"Never maintenance retains old source and action")
        try check(try s.searchResult(MemorySearchQuery("Orchid"),now:now).items.count == 2,"old and recent Never actions searchable through production fallback")
        let backup=try store("backup")
        _=try s.exportCanonicalSnapshot(to:backup,now:now)
        _=try backup.inspectCanonicalSnapshot(now:now)
        try check(try backup.policy().retention == .never && backup.action("old",now:now) != nil,"backup snapshot preserves Never and old action")
        let restore=try s.prepareCanonicalRestore(backup,now:now)
        _=try s.confirmCanonicalRestore(backup,previewID:restore.id,confirmed:true,now:now)
        try check(try s.policy().retention == .never && s.action("old",now:now) != nil && s.captureStatus()["state"] == "off","reviewed synthetic backup adoption preserves Never and recording OFF")
        let prefs=try s.savePreferences(MemoryPreferences(blockedApps:[],nativeTyping:true),expectedRevision:s.policy().revision)
        try check(prefs.policy.retention == .never,"preference autosave preserves Never")
        var shortened=try s.policy();shortened.retention = .days(30)
        try rejects("generic policy update cannot shorten retention") {try s.updatePolicy(shortened,now:now)}
        let cancelled=try s.prepareRetentionChange(.days(30),now:now)
        try check(cancelled.affectedActionCount == 1,"review counts exact old action scope")
        try rejects("false confirmation does not apply") {_=try s.confirmRetentionChange(cancelled.id,confirmed:false,now:now)}
        try s.cancelRetentionChange(cancelled.id)
        try rejects("cancelled review cannot apply") {_=try s.confirmRetentionChange(cancelled.id,confirmed:true,now:now)}
        let expired=try s.prepareRetentionChange(.days(30),now:now)
        try rejects("review expiry enforced") {_=try s.confirmRetentionChange(expired.id,confirmed:true,now:now.addingTimeInterval(301))}
        let raced=try s.prepareRetentionChange(.days(30),now:now)
        _=try s.ingest(event("raced",now),now:now)
        try rejects("concurrent source revision requires new review") {_=try s.confirmRetentionChange(raced.id,confirmed:true,now:now)}
        let review=try s.prepareRetentionChange(.days(30),now:now)
        _=try s.confirmRetentionChange(review.id,confirmed:true,now:now)
        try check(try s.action("old",now:now) == nil && s.action("recent",now:now) != nil,"confirmed finite policy hides only expired source")
        try check(try s.rows("SELECT id FROM records WHERE id='old'").count == 1,"confirmation does not run cleanup")
        try rejects("consumed review cannot replay") {_=try s.confirmRetentionChange(review.id,confirmed:true,now:now)}
        _=try s.writePending(now:now)
        try check(try s.rows("SELECT id FROM records WHERE id='old'").isEmpty && s.rows("SELECT id FROM tombstones WHERE id='old'").count == 1,"synthetic finite maintenance expires and tombstones")
        try check(try s.searchResult(MemorySearchQuery("Orchid"),now:now).items.allSatisfy{$0.id != "old"},"search excludes expired source")
        var extended=try s.policy();extended.retention = .never;try s.updatePolicy(extended,now:now)
        try check(try !s.ingest(event("old",old),now:now),"extending to Never cannot resurrect tombstone")
        let edge=try store("edge")
        _=try edge.ingest(event("boundary",now.addingTimeInterval(-30*86400+1)),now:now)
        let er=try edge.prepareRetentionChange(.days(30),now:now)
        try rejects("newly crossed cutoff cannot widen reviewed scope") {_=try edge.confirmRetentionChange(er.id,confirmed:true,now:now.addingTimeInterval(2))}
        try edge.exec("UPDATE metadata SET body=? WHERE id='policy'",[legacy.replacingOccurrences(of:"30",with:"0")])
        try rejects("malformed saved policy blocks expiry") {_=try edge.writePending(now:now)}
        try check(try edge.rows("SELECT id FROM records").count == 1,"malformed policy does not purge records")
        try migration(root:root,now:now,old:old)
        print("PASS \(count) retention checks; all stores synthetic")
    }
    static func migration(root:URL,now:Date,old:Date)throws {
        let s=try MemoryStore(home:root.appendingPathComponent("migration"),writable:true,automaticallySyncSearch:false)
        try s.initializeMigrationDestination()
        let raw="{\"primary_app\":\"TextEdit\",\"text\":\"Historical Orchid summary\"}"
        var entry=MigrationEntry(id:"",sourceID:"fixture-summary",family:"activity-summary",format:"fixture",at:iso(old),epochNanos:"1",timezone:"UTC",raw:raw,rawSHA256:fingerprint(raw),deleted:false,evidence:nil,summary:"Historical Orchid summary",end:nil,attachments:[])
        entry.id=try LegacyMigration.stableID(entry,namespace:"retention-fixture")
        func actionEntry(_ id:String,_ at:Date)throws->MigrationEntry {
            var e=MigrationEntry(id:"",sourceID:id,family:"collector-event",format:"fixture",at:iso(at),epochNanos:"1",timezone:"UTC",raw:"{}",rawSHA256:fingerprint("{}"),deleted:false,evidence:nil,summary:nil,end:nil,attachments:[])
            e.id=try LegacyMigration.stableID(e,namespace:"retention-fixture")
            e.evidence=Evidence(id:e.id,at:e.at,kind:"window.changed",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Imported Orchid action")
            return e
        }
        let oldAction=try actionEntry("old-action",old), recentAction=try actionEntry("recent-action",now)
        let snapshot=MigrationSnapshot(version:1,namespace:"retention-fixture",entries:[entry,oldAction,recentAction]), hash=fingerprint(try json(snapshot))
        let plan=try s.migrationDryRun(snapshot:snapshot,hash:hash,root:root,now:now)
        try check(!plan.blocked && plan.counts["accepted"] == 3,"Never dry run accepts old summary plus old and recent actions")
        _=try s.importMigration(snapshot:snapshot,hash:hash,policyHash:plan.policySHA256,root:root,now:now)
        _=try s.importMigration(snapshot:snapshot,hash:hash,policyHash:plan.policySHA256,root:root,now:now)
        try s.expireMigrationOriginals(now:now.addingTimeInterval(8000*86400))
        try check(try s.migrationOriginal(entry.id,now:now) != nil && s.rows("SELECT id FROM migration_originals").count == 3,"Never originals survive expiry and repeated import")
        try check(try s.action(oldAction.id,now:now) != nil && s.action(recentAction.id,now:now) != nil,"imported old and recent actions visible under Never")
        let backup=try MemoryStore(home:root.appendingPathComponent("migration-backup"),writable:true,automaticallySyncSearch:false)
        _=try s.exportCanonicalSnapshot(to:backup,now:now)
        try check(try backup.migrationOriginal(entry.id,now:now) != nil && backup.action(oldAction.id,now:now) != nil,"Never backup preserves old imported original and action")
        let review=try s.prepareRetentionChange(.days(30),now:now)
        try check(review.affectedOriginalCount == 2 && review.affectedActionCount == 1,"retention review separately counts old originals and action")
        _=try s.confirmRetentionChange(review.id,confirmed:true,now:now)
        let finite=try s.migrationDryRun(snapshot:snapshot,hash:hash,root:root,now:now)
        try check(finite.counts["excluded_retention"] == 2,"finite dry run reports retention exclusions")
        try s.expireMigrationOriginals(now:now)
        try check(try s.rows("SELECT id FROM migration_originals").count == 1 && s.action(recentAction.id,now:now) != nil,"finite expiry preserves recent imported original and action")
    }
}
