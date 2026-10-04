import Foundation
@testable import MemoryCore
import WriterBackend
import CoreIntegration

/// Fictional evolving evidence, encrypted synthetic stores and an in-memory
/// key store. No private history, model, network, live capture or UI.
@main struct SummaryRegenerationChecks {
    static var passed=0,failed=0
    static func check(_ ok:Bool,_ label:String) {
        if ok {passed+=1;print("PASS "+label)} else {failed+=1;print("FAIL "+label)}
    }
    // claude/int-1002: the fixtures put moments up to an hour before `now` on one UTC day; within two hours after UTC
    // midnight that hour straddles two days ("a second, later moment" failed at 00:43 UTC). Such a clock reads 22:00 UTC.
    static let zone="UTC", now:Date={ let d=Date(), into=d.timeIntervalSince1970.truncatingRemainder(dividingBy:86400)
        return into<7200 ? d.addingTimeInterval(-into-7200) : d }()
    static var root:URL!
    static func make(_ name:String,dayOffset:TimeInterval=0,typedParts:Int=1,markAge:TimeInterval=1800,typedAtOffset:TimeInterval=60,eventAge:TimeInterval=3600) async throws -> (MemoryStore,WriterQueueSource,ScheduledWriterTarget,WrittenMark) {
        let store=try MemoryStore(home:root.appendingPathComponent(name),writable:true,automaticallySyncSearch:false)
        var policy=try store.policy();policy.captureText=true;policy.typedConsentVersion=1;try store.updatePolicy(policy,now:now)
        try store.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()),now:now)
        try store.setUpTypedVault(now:now);try store.acceptSafeTyping(now:now)
        let at=now.addingTimeInterval(-eventAge+dayOffset),day=try DayScope.key(at,timezone:zone)
        for i in 0..<10 {
            _=try store.ingest(Evidence(id:"base-\(i)",at:iso(at.addingTimeInterval(Double(i))),kind:"window.changed",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Harbor worksheet",synthetic:true),now:now)
        }
        let source=WriterQueueSource(store:store)
        let initial=try store.dayLayers(day:day,timezone:zone,now:now).activities.first!
        let oldItem=ScheduledWriterTarget(target:WriterTarget(kind:.activity,day:day,timezone:zone,activityID:initial.id),inputRevision:initial.inputRevision,policyRevision:try store.policy().revision,lastActivity:timestamp(initial.end)!)
        let request=try store.prepareNote(kind:"activity",day:day,timezone:zone,activityID:initial.id,now:now)
        _=try store.commitNote(NoteWriterOutput(requestID:request.id,title:"Harbor worksheet",bullets:[NoteBullet(text:"Worked in TextEdit.",actionIDs:request.actions.map(\.id),assertion:"interpretation")],generator:"fixture",generatorVersion:NoteWriterVersions.current[0]),now:now)
        check(try store.dayLayers(day:day,timezone:zone,now:now).activities.first!.status == "ready",name+": original note is current")
        let mark=WrittenMark(actions:10,typed:0,at:now.addingTimeInterval(-markAge),end:timestamp(initial.end),revision:await source.markRevision(oldItem),writes:WriterQueueSource.maxWrites)
        for i in 0..<max(1,typedParts) {
            let words="The harbor worksheet needs revised categories. The volunteer handoff needs a clearer checklist."
            _=try store.ingest(Evidence(id:"clause-\(i)",at:iso(at.addingTimeInterval(typedAtOffset+Double(i))),kind:typedParts>0 ? "keyboard.text_input":"mouse.click",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Harbor worksheet",text:typedParts>0 ? words:"",synthetic:true),now:now)
        }
        let evolved=try store.dayLayers(day:day,timezone:zone,now:now).activities.first!
        let item=ScheduledWriterTarget(target:oldItem.target,inputRevision:evolved.inputRevision,policyRevision:try store.policy().revision,lastActivity:timestamp(evolved.end)!)
        check(evolved.inputRevision != initial.inputRevision && evolved.status == "pending",name+": new typed evidence invalidates old revision")
        check(evolved.previous?.inputRevision == initial.inputRevision && evolved.generated == nil,name+": old note is display-only while pending")
        return (store,source,item,mark)
    }
    static func main() async throws {
        setbuf(stdout,nil)
        let base=ProcessInfo.processInfo.environment["SUMMARY_REGEN_CHECK_ROOT"].map{URL(fileURLWithPath:$0,isDirectory:true)} ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        root=base.appendingPathComponent("summary-regeneration-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer {try? FileManager.default.removeItem(at:root)}
        for (name,parts,offset,time) in [("small-growth",1,0.0,60.0),("quarter-growth",4,0.0,60.0),("past-catchup",1,-86400.0,60.0),("late-arrival",1,0.0,5.0)] {
            let (store,source,item,mark)=try await make(name,dayOffset:offset,typedParts:parts,typedAtOffset:time)
            let discovery=try await source.discoverDay(item.day,now:now,timezone:zone,marks:[item.key:mark])
            check(discovery.targets.contains{$0.key==item.key},name+": new typed evidence queues after the historical write cap")
            check(!discovery.willNotWrite.contains(item.activityID!),name+": evolving evidence is not permanently excluded")
            let manual=try await source.selected(day:item.day,timezone:zone,activityID:item.activityID!,now:now)
            check(manual.item.inputRevision==item.inputRevision,name+": manual and automatic selection use same revision")
            let autoBinding=CoreWriterBinding(store:store,typedWriter:.local),manualBinding=CoreWriterBinding(store:store,typedWriter:.local)
            let autoPort=autoBinding.port(),manualPort=manualBinding.port()
            let automatic=try await autoPort.prepare(item.target),selected=try await manualPort.prepare(manual.item.target)
            let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
            let autoActions=try encoder.encode(automatic.actions),manualActions=try encoder.encode(selected.actions)
            check(automatic.inputRevision==selected.inputRevision && autoActions==manualActions,name+": manual and automatic read same hydrated actions")
            check(automatic.actions.filter{$0.kind=="keyboard.text_input"}.allSatisfy{$0.description.contains("revised categories") && $0.description.contains("clearer checklist")},name+": both meaningful clauses reach writer")
            try await autoPort.cancel(automatic.id)
            let folder=root.appendingPathComponent(name+"-ledger")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            var scheduler:PendingNoteScheduler?=try PendingNoteScheduler(file:folder.appendingPathComponent("pending.json"),baseRetry:0.05,now:{now})
            try await scheduler!.setWritten(key:item.key,mark)
            try await scheduler!.enqueue(item);try await scheduler!.start()
            _=try await scheduler!.runNext {_ in .retry}
            check(await scheduler!.snapshot().first?.status == .retry,name+": transient failure remains queued for retry")
            // Production explicitly retries after provider-wide backoff. Reopen
            // verifies queue/mark persistence rather than an in-memory assertion.
            scheduler=nil
            scheduler=try PendingNoteScheduler(file:folder.appendingPathComponent("pending.json"),baseRetry:0.05,now:{now})
            let reopened=await scheduler!.snapshot(),written=await scheduler!.writtenMarks()
            check(reopened.first?.status == .retry && written[item.key]?.writes==WriterQueueSource.maxWrites,name+": retry and historical count survive ledger reopen")
            try await scheduler!.retry(key:item.key);try await scheduler!.start()
            _=try await scheduler!.runNext {target in
                let req=try await autoPort.prepare(target.target)
                let body:[String:Any]=["requestID":req.id,"title":"Harbor planning","bullets":[["text":"Planned worksheet categories and a volunteer checklist.","actionIDs":req.actions.map(\.id),"assertion":"interpretation"]],"generator":"fixture","generatorVersion":"1"]
                let output=try JSONDecoder().decode(CanonicalNoteOutput.self,from:JSONSerialization.data(withJSONObject:body))
                _=try await autoPort.commit(output)
                return .committed
            }
            check(await scheduler!.snapshot().first?.status == .completed,name+": retry reaches committed canonical note")
            let refreshed=try store.dayLayers(day:item.day,timezone:zone,now:now).activities.first!
            check(refreshed.status=="ready" && refreshed.generated?.inputRevision==item.inputRevision,name+": new revision stored as ready")
            check(refreshed.generated?.output.bullets.first?.text.contains("worksheet categories") == true && refreshed.generated?.output.bullets.first?.text.contains("volunteer checklist") == true,name+": regenerated note keeps both fictional topics")
            check(try await source.discoverDay(item.day,now:now,timezone:zone,marks:[item.key:mark]).targets.isEmpty,name+": unchanged ready input never loops")
        }
        let (_,source,item,mark)=try await make("cooldown",markAge:600)
        let early=try await source.discoverDay(item.day,now:now,timezone:zone,marks:[item.key:mark])
        let due=mark.at.addingTimeInterval(WriterQueueSource.rewriteAfter)
        check(early.targets.isEmpty && early.nextRewrite==due,"new typed evidence preserves rewrite cooldown deadline")
        check(try await source.discoverDay(item.day,now:due,timezone:zone,marks:[item.key:mark]).targets.contains{$0.key==item.key},"new typed evidence queues exactly when cooldown expires")
        let (_,clickSource,clickItem,clickMark)=try await make("click-only",typedParts:0)
        let clicks=try await clickSource.discoverDay(clickItem.day,now:now,timezone:zone,marks:[clickItem.key:clickMark])
        check(clicks.targets.isEmpty && clicks.willNotWrite.contains(clickItem.activityID!),"ordinary click growth remains subject to historical write cap")
        let (_,openSource,openItem,openMark)=try await make("still-open",eventAge:90)
        let open=try await openSource.discoverDay(openItem.day,now:now,timezone:zone,marks:[openItem.key:openMark])
        check(open.targets.isEmpty && open.open.contains{$0.key==openItem.key},"new typed evidence waits for moment to close")
        let (versionStore,versionSource,versionItem,_)=try await make("old-writer",typedParts:0)
        let req=try versionStore.prepareNote(kind:"activity",day:versionItem.day,timezone:zone,activityID:versionItem.activityID,now:now)
        _=try versionStore.commitNote(NoteWriterOutput(requestID:req.id,title:"Harbor worksheet",bullets:[NoteBullet(text:"Worked in TextEdit.",actionIDs:req.actions.map(\.id),assertion:"interpretation")],generator:"fixture",generatorVersion:"qwen35-4b-q4-b9723-prompt9-validator11"),now:now)
        let legacyMark=WrittenMark(actions:req.actionCount,typed:0,at:now.addingTimeInterval(0.1),end:versionItem.lastActivity,revision:await versionSource.markRevision(versionItem),writes:WriterQueueSource.maxWrites)
        check(try versionStore.dayLayers(day:versionItem.day,timezone:zone,now:now).activities.first!.status=="pending","earlier writer version makes same evidence pending")
        let legacy=try JSONDecoder().decode(WrittenMark.self,from:JSONEncoder().encode(legacyMark))
        check(legacy.writerRevision==nil,"legacy written mark decodes without writer stamp")
        let refresh=try await versionSource.discoverDay(versionItem.day,now:now,timezone:zone,marks:[versionItem.key:legacy])
        check(refresh.targets.contains{$0.key==versionItem.key},"old-build mark written after old note still allows version refresh")
        var stamped=legacy;stamped.writerRevision=CanonicalGrounding.currentVersions.joined(separator:"|")
        check(try await versionSource.discoverDay(versionItem.day,now:now,timezone:zone,marks:[versionItem.key:stamped]).targets.isEmpty,"current-build failed attempt at same input never loops")
        stamped.writerRevision="older-fixed-version-set"
        check(try await versionSource.discoverDay(versionItem.day,now:now,timezone:zone,marks:[versionItem.key:stamped]).targets.contains{$0.key==versionItem.key},"earlier stamped writer version allows one new attempt")
        // claude/ready-1002 (owner): a version bump's rewrites are marked as such (they run only while the person isn't
        // typing) and come newest moment first, after new moments.
        check(refresh.rewriteKeys.contains(versionItem.key),"a version-bump rewrite is marked as a rewrite")
        let later=now.addingTimeInterval(-1200)
        for i in 0..<10 {
            _=try versionStore.ingest(Evidence(id:"later-\(i)",at:iso(later.addingTimeInterval(Double(i))),kind:"window.changed",app:"Numbers",bundle:"com.apple.iWork.Numbers",title:"Harbor budget",synthetic:true),now:now)
        }
        let layers=try versionStore.dayLayers(day:versionItem.day,timezone:zone,now:now)
        if let second=layers.activities.first(where:{$0.id != versionItem.activityID && $0.status != "ready"}) {
            let r2=try versionStore.prepareNote(kind:"activity",day:versionItem.day,timezone:zone,activityID:second.id,now:now)
            _=try versionStore.commitNote(NoteWriterOutput(requestID:r2.id,title:"Harbor budget",bullets:[NoteBullet(text:"Worked in Numbers.",actionIDs:r2.actions.map(\.id),assertion:"interpretation")],generator:"fixture",generatorVersion:"qwen35-4b-q4-b9723-prompt14-validator25"),now:now)
            let both=try await versionSource.discoverDay(versionItem.day,now:now,timezone:zone,marks:[versionItem.key:legacy])
            let order=both.targets.filter {both.rewriteKeys.contains($0.key)}.map(\.activityID)
            check(order.count==2 && order.first==second.id && order.last==versionItem.activityID,"version-bump rewrites come newest moment first (got \(order))")
            check(NoteWriterVersions.outdated("qwen35-4b-q4-b9723-prompt14-validator25") && NoteWriterVersions.outdated("code-fallback3-validator13")
                  && NoteWriterVersions.outdated("code-moment6-validator12") && NoteWriterVersions.outdated("deepseek-v4-flash-0731-zdr-prompt13-validator19"),
                  "the 10/1 build's notes (prompt14, moment6, fallback3, cloud prompt13) are rewritten by this build")
        } else {check(false,"fixture: a second, later moment")}
        // A long moment an earlier build set aside as too long is written once more (now in segments); this build's own
        // set-aside is final.
        let (longStore,longSource,_,_)=try await make("long-moment",typedParts:0)
        let longAt=now.addingTimeInterval(-900)
        for i in 0..<420 {
            _=try longStore.ingest(Evidence(id:"long-\(i)",at:iso(longAt.addingTimeInterval(Double(i)*0.5)),kind:"window.changed",app:"Ghostty",bundle:"com.mitchellh.ghostty",title:"harborline — zsh",synthetic:true),now:now)
        }
        let longDay=try DayScope.key(longAt,timezone:zone)
        if let long=try longStore.dayLayers(day:longDay,timezone:zone,now:now).activities.first(where:{$0.actionIDs.count>CanonicalGrounding.maxActions}) {
            let item=ScheduledWriterTarget(target:WriterTarget(kind:.activity,day:longDay,timezone:zone,activityID:long.id),inputRevision:long.inputRevision,policyRevision:try longStore.policy().revision,lastActivity:timestamp(long.end)!)
            var aside=WrittenMark(actions:long.actionIDs.count,typed:0,at:now.addingTimeInterval(-1800),skipped:true,end:timestamp(long.end),revision:await longSource.markRevision(item),writes:1,fallback:true,writerRevision:"older-fixed-version-set")
            let again=try await longSource.discoverDay(longDay,now:now,timezone:zone,marks:[item.key:aside])
            check(again.targets.contains{$0.key==item.key},"a \(long.actionIDs.count)-action moment an earlier build set aside as too long is queued again")
            aside.writerRevision=WriterQueueSource.writerRevision
            let own=try await longSource.discoverDay(longDay,now:now,timezone:zone,marks:[item.key:aside])
            check(!own.targets.contains{$0.key==item.key},"this build's own set-aside of a long moment never loops (targets \(own.targets.map(\.key)) item \(item.key))")
            check(try await longSource.discoverDay(longDay,now:now,timezone:zone).targets.contains{$0.key==item.key},"a long moment never written is queued (no longer filtered as too long)")
        } else {check(false,"fixture: a moment over 400 actions (got \(try longStore.dayLayers(day:longDay,timezone:zone,now:now).activities.map {$0.actionIDs.count}))")}
        print("summary-regeneration: \(passed) passed, \(failed) failed; fictional evidence, no model/network/private history")
        if failed>0 {exit(1)}
    }
}
