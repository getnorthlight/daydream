// Synthetic provider DTOs against real canonical core APIs. No model/cloud/capture.
import Foundation
import MemoryCore
import WriterBackend

@main struct CoreChecks {
    static var passed=0
    static func check(_ condition:@autoclosure () throws -> Bool,_ label:String) throws {
        guard try condition() else {throw NSError(domain:"CoreChecks",code:1,userInfo:[NSLocalizedDescriptionKey:label])}
        passed += 1; print("PASS \(label)")
    }
    static func rejects(_ label:String,_ operation:() throws -> Void) throws {
        do {try operation()} catch {passed += 1; print("PASS \(label)");return}
        throw NSError(domain:"CoreChecks",code:2,userInfo:[NSLocalizedDescriptionKey:label])
    }
    static func wire<T:Encodable,U:Decodable>(_ source:T,_ type:U.Type) throws -> U {
        try JSONDecoder().decode(type,from:JSONEncoder().encode(source))
    }
    /// A prompt4 answer: one bullet per item of the ITEMS view, ids and text only.
    static func answer(_ view:ModelView)->String {
        let bullets=view.items.map {item in #"{"ids":["\#(item.alias)"],"text":"Clicked through \#(item.title.isEmpty ? item.app : item.title+" in "+item.app)."}"#}
        return #"{"title":"Research in TextEdit","bullets":["#+bullets.joined(separator:",")+"]}"
    }
    static func response(_ request:CanonicalNoteRequest) throws -> CanonicalNoteOutput {
        let view=try ModelView(request:request,actions:request.actions)
        return try CanonicalGrounding.check(CanonicalGrounding.validate(answer(view),request:request,view:view,provider:CanonicalLocalWriter.provider),request:request,view:view)
    }
    /// The check's "now": noon in `zone` today, or yesterday while it is still morning there. Every synthetic time below
    /// (the day's visits from 1 AM included) is then already past and inside one day, whatever the wall clock or the
    /// Mac's time zone. It was `Date()`: from midnight to 1 AM in New York the visits were still ahead, and the check
    /// failed (gold/r2-copy-checks; the runner's wb-core-clock step runs it at those times with a shifted clock).
    static func recentNoon(_ zone:String,now:Date=Date()) -> Date {
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:zone)!
        let noon=calendar.date(bySettingHour:12,minute:0,second:0,of:now)!
        return noon<=now ? noon:calendar.date(byAdding:.day,value:-1,to:noon)!
    }
    static func main() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("writer-core-check-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let zone="America/New_York",now=recentNoon(zone),day=try DayScope.key(now,timezone:zone)
        let store=try MemoryStore(home:root,writable:true,automaticallySyncSearch:false)
        func ingest(_ id:String) throws {
            let evidence=Evidence(id:id,at:iso(now),kind:"mouse.click",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Research",synthetic:true)
            try check(try store.ingest(evidence,now:now),"synthetic action accepted \(id)")
        }
        try ingest("one");try ingest("two")
        let core=try store.prepareNote(kind:"day",day:day,timezone:zone,now:now)
        let request=try wire(core,CanonicalNoteRequest.self)
        try check(request.actions.count==2 && request.actions[0].revision==core.actions[0].revision,"core request DTO preserves string revisions and actions")
        let output=try response(request)
        try check(output.bullets.allSatisfy { bullet in !request.actions.contains{$0.description==bullet.text} },"structured prose is not exact source quotation")
        let coreOutput=try wire(output,NoteWriterOutput.self)
        let saved=try store.commitNote(coreOutput,now:now)
        try check(Set(saved.actionIDs)==Set(request.actions.map(\.id)) && saved.status=="generated_unverified","actual core accepts fully cited structured prose")
        try check(try store.commitNote(coreOutput,now:now).version==saved.version,"identical commit retry idempotent")
        var conflict=coreOutput;conflict.title="Different retry"
        try rejects("conflicting committed retry rejected") {_=try store.commitNote(conflict,now:now)}
        let view=try ModelView(request:request,actions:request.actions)
        var dropped=output;dropped.bullets[0].actionIDs.removeLast()
        try rejects("provider rejects a note that drops an action") {_=try CanonicalGrounding.check(dropped,request:request,view:view)}
        let sent=#"{"title":"Research","bullets":[{"ids":["i1"],"text":"Sent a message about the research."}]}"#
        try rejects("provider rejects invented send") {_=try CanonicalGrounding.validate(sent,request:request,view:view,provider:"synthetic")}
        var relabelled=output;relabelled.bullets[0].assertion="sent"
        try rejects("provider rejects a label the action states do not support") {_=try CanonicalGrounding.check(relabelled,request:request,view:view)}
        try ingest("late")
        try rejects("late action invalidates committed acknowledgement") {_=try store.commitNote(coreOutput,now:now)}
        let fresh=try wire(store.prepareNote(kind:"day",day:day,timezone:zone,now:now),CanonicalNoteRequest.self)
        let freshOutput=try wire(response(fresh),NoteWriterOutput.self)
        var policy=try store.policy();policy.blockedApps=["com.apple.TextEdit"];try store.updatePolicy(policy,now:now)
        try rejects("changed policy prevents publication") {_=try store.commitNote(freshOutput,now:now)}
        policy.blockedApps=[];try store.updatePolicy(policy,now:now)
        let cancel=try store.prepareNote(kind:"day",day:day,timezone:zone,now:now)
        let cancelOutput=try wire(response(wire(cancel,CanonicalNoteRequest.self)),NoteWriterOutput.self)
        try store.cancelNote(cancel.id)
        try rejects("cancelled request cannot publish") {_=try store.commitNote(cancelOutput,now:now)}
        let expired=try store.prepareNote(kind:"day",day:day,timezone:zone,now:now)
        let expiredOutput=try wire(response(wire(expired,CanonicalNoteRequest.self)),NoteWriterOutput.self)
        try rejects("expired request cannot publish") {_=try store.commitNote(expiredOutput,now:now.addingTimeInterval(301))}
        let paged=try MemoryStore(home:root.appendingPathComponent("pages"),writable:true,automaticallySyncSearch:false)
        for i in 0..<101 {_=try paged.ingest(Evidence(id:"page-\(i)",at:iso(now),kind:"mouse.click",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Research",synthetic:true),now:now)}
        let first=try paged.prepareNote(kind:"day",day:day,timezone:zone,now:now)
        try check(first.actions.count==100 && first.next==100,"core input requires pagination beyond first hundred")
        let last=try paged.noteActions(requestID:first.id,after:first.next!,now:now)
        try check(last.actions.count==1 && last.next==nil && last.actionCount==101,"actual core final page retains remaining action")
        let pagedRequest=try wire(first,CanonicalNoteRequest.self),pagedActions=try wire(first.actions+last.actions,[NoteAction].self)
        let pagedView=try ModelView(request:pagedRequest,actions:pagedActions)
        try check(pagedView.items.flatMap(\.actions).count==101,"one ITEMS view covers every paged action (101 clicks fold into one item)")
        let overCapacity=(0..<401).map {index->NoteAction in var action=pagedActions[0];action.id="capacity-\(index)";return action}
        try rejects("provider leaves an over-capacity scope (401 actions) pending rather than truncate") {_=try ModelView(request:pagedRequest,actions:overCapacity)}

        // Mutations occur after request preparation, representing in-flight generation.
        // These call the real core ingest/delete APIs, never private SQL or live capture.
        let revised=try MemoryStore(home:root.appendingPathComponent("revised"),writable:true,automaticallySyncSearch:false)
        var changing=Evidence(id:"changing",at:iso(now),kind:"mouse.click",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Research",synthetic:true)
        _=try revised.ingest(changing,now:now)
        let beforeRevision=try revised.action(changing.id,now:now)!.revision
        let revisionRequest=try wire(revised.prepareNote(kind:"day",day:day,timezone:zone,now:now),CanonicalNoteRequest.self)
        let revisionOutput=try wire(response(revisionRequest),NoteWriterOutput.self)
        changing.title="Revised research"
        _=try revised.ingest(changing,now:now)
        try check(try revised.action(changing.id,now:now)!.revision != beforeRevision,"existing action revision changes during synthetic generation")
        try rejects("mid-generation source revision rejects stale output") {_=try revised.commitNote(revisionOutput,now:now)}
        try check(try revised.dayLayers(day:day,timezone:zone,now:now).summary.generated==nil,"stale source result never becomes generated day note")
        let deletionRequest=try wire(revised.prepareNote(kind:"day",day:day,timezone:zone,now:now),CanonicalNoteRequest.self)
        let deletionOutput=try wire(response(deletionRequest),NoteWriterOutput.self)
        try revised.delete(changing.id)
        try rejects("mid-generation deletion rejects late output") {_=try revised.commitNote(deletionOutput,now:now)}
        try check(try revised.action(changing.id,now:now)==nil && revised.dayLayers(day:day,timezone:zone,now:now).summary.actionCount==0,"deleted action absent from canonical read and day count")

        let visits=try MemoryStore(home:root.appendingPathComponent("visits"),writable:true,automaticallySyncSearch:false)
        let sequence:[(String,String,String,String)]=[
            ("visit-1","browser.tab_opened","Research","Chrome"),
            ("visit-2","window.observed","Research","TextEdit"),
            ("visit-3","browser.tab_opened","Brief status","Chrome"),
            ("visit-4","browser.tab_visited","Research","Chrome"),
            ("visit-5","mouse.click","Research","TextEdit")
        ]
        // Keep this deterministic sequence within the requested calendar day.
        let start=try DayScope.interval(day:day,timezone:zone).start.addingTimeInterval(3600)
        for (index,event) in sequence.enumerated() {
            _=try visits.ingest(Evidence(id:event.0,at:iso(start.addingTimeInterval(Double(index))),kind:event.1,app:event.3,bundle:event.3=="Chrome" ? "com.google.Chrome":"com.apple.TextEdit",title:event.2,synthetic:true),now:now)
        }
        let original=try visits.actions(now:now).actions
        let layers=try visits.dayLayers(day:day,timezone:zone,now:now)
        try check(original.map(\.id)==sequence.map{$0.0},"five actions remain chronological before any note generation")
        try check(layers.summary.actionCount==5 && layers.summary.generated==nil && layers.activities.flatMap(\.actionIDs).count==5,"writer pending does not hide five actions")
        try check(layers.activities.contains{$0.actionIDs.contains("visit-3") && !$0.actionIDs.contains("visit-1")},"one-second unrelated visit remains distinct from research")
        try check(original.first{$0.id=="visit-4"}?.kind=="browser.tab_visited","return after interruption retains explicit revisit")
        let visitRequest=try wire(visits.prepareNote(kind:"day",day:day,timezone:zone,now:now),CanonicalNoteRequest.self)
        let visitOutput=try response(visitRequest)
        let visitSaved=try visits.commitNote(wire(visitOutput,NoteWriterOutput.self),now:now)
        let cited=visitSaved.output.bullets.map {Set($0.actionIDs)}
        try check(cited.count==3 && Set(cited.flatMap {$0})==Set(sequence.map{$0.0}),"generated note cites all five events in three item bullets")
        try check(cited.contains(["visit-1","visit-4"]) && cited.contains(["visit-3"]) && cited.contains(["visit-2","visit-5"]),"the revisit folds into its tab, the click into its window, and the one-second visit keeps its own bullet")
        try check(try visits.actions(now:now).actions==original,"note generation never overwrites or drops original canonical actions")
        let restartRoot=root.appendingPathComponent("restart")
        // Scope exits release the initial store; reopen from durable files, not a retained object.
        func prepareBeforeRestart()throws->NoteWriterRequest {
            let initial=try MemoryStore(home:restartRoot,writable:true,automaticallySyncSearch:false)
            _=try initial.ingest(Evidence(id:"restart-action",at:iso(now),kind:"mouse.click",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Research",synthetic:true),now:now)
            return try initial.prepareNote(kind:"day",day:day,timezone:zone,now:now)
        }
        let durableRequest=try prepareBeforeRestart()
        func commitAfterRestart()throws {
            let reopened=try MemoryStore(home:restartRoot,writable:true,automaticallySyncSearch:false)
            let resumed=try reopened.prepareNote(kind:"day",day:day,timezone:zone,now:now)
            try check(resumed.id==durableRequest.id && resumed.inputRevision==durableRequest.inputRevision,"reopened store resumes identical pending request")
            let resumedOutput=try wire(response(wire(resumed,CanonicalNoteRequest.self)),NoteWriterOutput.self)
            let committed=try reopened.commitNote(resumedOutput,now:now)
            try check(committed.output.requestID==durableRequest.id && committed.version==1,"reopened pending request accepts validated commit")
        }
        try commitAfterRestart()
        func cancelBeforeRestart()throws->NoteWriterOutput {
            let initial=try MemoryStore(home:restartRoot,writable:true,automaticallySyncSearch:false)
            let request=try initial.prepareNote(kind:"day",day:day,timezone:zone,now:now)
            let output=try wire(response(wire(request,CanonicalNoteRequest.self)),NoteWriterOutput.self)
            try initial.cancelNote(request.id)
            return output
        }
        let durableCancelled=try cancelBeforeRestart()
        let afterCancellation=try MemoryStore(home:restartRoot,writable:true,automaticallySyncSearch:false)
        try rejects("cancelled request remains rejected after store reopen") {_=try afterCancellation.commitNote(durableCancelled,now:now)}
        try check(try afterCancellation.action("restart-action",now:now) != nil,"cancel and reopen retain canonical source action")
        // r1 summaries-quality: a moment's code-written fallback title never copies the account address or unread count.
        let inboxActions=(0..<3).map {i in NoteAction(id:"inbox-\(i)",at:iso(now.addingTimeInterval(Double(i*60))),kind:"window.changed",app:"Google Chrome",site:"mail.google.com",
                                                     title:"Inbox (23) - alex@acme.com - Gmail",description:"",state:"observed",revision:"1")}
        let inboxJSON:[String:Any]=["id":"inbox-request","schemaVersion":1,"targetKind":"activity","targetID":"activity_inbox","day":day,"timezone":zone,"inputRevision":"r",
                                    "policyRevision":"p","expiresAt":iso(now.addingTimeInterval(300)),"actions":[],"actionCount":3]
        var inboxRequest=try JSONDecoder().decode(CanonicalNoteRequest.self,from:JSONSerialization.data(withJSONObject:inboxJSON))
        inboxRequest.actions=inboxActions
        let inboxView=try ModelView(request:inboxRequest,actions:inboxActions)
        let inboxNote=try CanonicalGrounding.salvage(#"{"title":"","bullets":[{"ids":["i1"],"text":"Had the inbox open."}]}"#,request:inboxRequest,view:inboxView,provider:CanonicalLocalWriter.provider)
        try check(!inboxNote.title.contains("@") && !inboxNote.title.contains("(23)") && !inboxNote.title.contains(" - Gmail") && inboxNote.title=="Email in Gmail",
                  "moment fallback title drops the account address, unread count and site suffix (\(inboxNote.title))")
        print("Core/provider integration: \(passed) checks passed. Synthetic only; no model, cloud, capture or search scheduling.")
    }
}
