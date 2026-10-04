// Production APIs over temporary fabricated stores. No capture/provider/server calls.
import Foundation
import MemoryCore

@main struct ActionChecks {
    static var count=0
    static func check(_ value:@autoclosure () throws -> Bool,_ label:String) throws {
        guard try value() else { throw MemError.invalid("FAIL: "+label) }
        count += 1; print("PASS: "+label)
    }
    static func rejects(_ label:String,_ work:() throws -> Void) throws {
        do { try work() } catch { count += 1; print("PASS: "+label); return }
        throw MemError.invalid("FAIL: "+label)
    }
    static func main() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("macmem-action-check-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let now=Date(), zone="America/New_York", day=try DayScope.key(now,timezone:"America/New_York")
        let store=try MemoryStore(home:root,writable:true,automaticallySyncSearch:false)
        let retentionReview=try store.prepareRetentionChange(.days(365))
        _=try store.confirmRetentionChange(retentionReview.id,confirmed:true)
        var policy=try store.policy(); policy.captureText=true; policy.typedConsentVersion=1; policy.retentionDays=365
        try store.updatePolicy(policy,now:now)
        func event(_ id:String,_ kind:String="window.changed",_ title:String="Sensor research",_ offset:Double=0,_ app:String="TextEdit") -> Evidence {
            Evidence(id:id,at:iso(now.addingTimeInterval(offset)),kind:kind,app:app,bundle:app == "Safari" ? "com.apple.Safari" : "com.apple.TextEdit",title:title,synthetic:true)
        }
        let start=DispatchTime.now().uptimeNanoseconds
        for i in 0..<5 { _=try store.ingest(event("action-\(i)","mouse.click","Sensor research",Double(i-5)),now:now) }
        let reader=try MemoryStore(home:root)
        try check(try reader.actions(now:now).actions.count == 5,"five actions visible with writer and index OFF")
        let latency=Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
        print(String(format:"MEASURE five durable commits plus independent action read: %.2f ms",latency))
        try check(latency < 3000,"canonical visibility under three seconds in synthetic store")
        let initial=try store.dayLayers(day:day,timezone:zone,now:now)
        try check(initial.activities.count == 1 && initial.activities[0].actionIDs.count == 5,"one activity retains all five action IDs")
        let group=initial.activities[0]
        try check(initial.summary.status == "pending" && group.generated == nil,"offline writer leaves notes pending, not missing actions")
        _=try store.ingest(event("status-check","window.changed","Build status",-4),now:now)
        _=try store.ingest(event("brief-tab","browser.tab_opened","Sensor research",-3,"Safari"),now:now)
        _=try store.ingest(event("tab-revisit","browser.tab_visited","Sensor research",-1,"Safari"),now:now)
        let related=try store.dayLayers(day:day,timezone:zone,now:now)
        try check(related.activities.count == 2,"short unrelated check retained without splitting research")
        try check(related.activities.first{$0.subject == "Sensor research"}?.apps == ["Safari","TextEdit"],"research links exact shared subject across apps")
        try check(try reader.action("brief-tab",now:now)?.kind == "browser.tab_opened" && reader.action("tab-revisit",now:now) != nil,"brief tab open and revisit retained without dwell threshold")
        let notes=try store.prepareNote(kind:"activity",day:day,timezone:zone,activityID:group.id,now:now)
        try check(try store.prepareNote(kind:"activity",day:day,timezone:zone,activityID:group.id,now:now).id == notes.id,"preparing the same pending work does not duplicate requests")
        let output=NoteWriterOutput(requestID:notes.id,title:"Sensor research",bullets:[NoteBullet(text:"Related research observations across two apps.",actionIDs:notes.actions.map(\.id),assertion:"interpretation")],generator:"synthetic-local",generatorVersion:"1")
        let saved=try store.commitNote(output,now:now)
        try check(saved.version == 1 && saved.actionIDs.count == 7,"structured note references all current group actions")
        try check(try store.commitNote(output,now:now).version == 1,"writer retry is idempotent")
        _=try store.ingest(event("late-action","mouse.click","Sensor research",-2),now:now)
        try check(try store.dayLayers(day:day,timezone:zone,now:now).activities.first{$0.id == group.id}?.status == "pending","late event invalidates derived note without changing activity ID")
        try rejects("stale committed retry cannot disclose old note") { _=try store.commitNote(output,now:now) }
        let refreshed=try store.prepareNote(kind:"activity",day:day,timezone:zone,activityID:group.id,now:now)
        let updated=NoteWriterOutput(requestID:refreshed.id,title:"Updated research",bullets:[NoteBullet(text:"Additional related observation.",actionIDs:refreshed.actions.map(\.id))],generator:"synthetic-local",generatorVersion:"2")
        try check(try store.commitNote(updated,now:now).version == 2,"regeneration appends version and preserves references")
        try check(try !store.noteTargets(day:day,timezone:zone,now:now).contains{$0.id == group.id},"current generated group absent from pending writer targets")
        let cancelled=try store.prepareNote(kind:"day",day:day,timezone:zone,now:now); try store.cancelNote(cancelled.id)
        try rejects("cancelled provider output cannot publish") { _=try store.commitNote(NoteWriterOutput(requestID:cancelled.id,title:"Day",bullets:[NoteBullet(text:"Observed actions.",actionIDs:["action-0"])],generator:"fixture",generatorVersion:"1"),now:now) }
        let invalid=try store.prepareNote(kind:"day",day:day,timezone:zone,now:now)
        try rejects("foreign action IDs rejected") { _=try store.commitNote(NoteWriterOutput(requestID:invalid.id,title:"Day",bullets:[NoteBullet(text:"Observed actions.",actionIDs:["not-in-request"])],generator:"fixture",generatorVersion:"1"),now:now) }
        try rejects("draft-to-sent hallucination rejected") { _=try store.commitNote(NoteWriterOutput(requestID:invalid.id,title:"Sent email",bullets:[NoteBullet(text:"Sent the result.",actionIDs:["action-0"],assertion:"sent")],generator:"fixture",generatorVersion:"1"),now:now) }
        try rejects("idle duration not promoted to work") { _=try store.commitNote(NoteWriterOutput(requestID:invalid.id,title:"Day",bullets:[NoteBullet(text:"Spent 20 minutes reading.",actionIDs:["action-0"])],generator:"fixture",generatorVersion:"1"),now:now) }
        try rejects("expired request rejected") { _=try store.commitNote(NoteWriterOutput(requestID:invalid.id,title:"Day",bullets:[NoteBullet(text:"Observed actions.",actionIDs:["action-0"])],generator:"fixture",generatorVersion:"1"),now:now.addingTimeInterval(301)) }
        var draft=event("draft","keyboard.text_input","Draft",-1); draft.text="Please send the proposal"
        _=try store.ingest(draft,now:now); _=try store.ingest(event("return","keyboard.submit","Draft",0),now:now)
        _=try store.ingest(event("unverified-send","message.sent","Draft",0),now:now)
        var sent=event("verified-send","message.sent","Draft",0)
        sent.sendVerification=SendVerification(evidenceID:sent.id,messageID:"fabricated-receipt",source:"connector-send-result",confirmedAt:sent.at)
        _=try store.ingest(sent,now:now)
        try check(try store.action("draft",now:now)?.state == "draft" && store.action("return",now:now)?.state == "draft","typing and Return stay drafts")
        try check(try store.action("unverified-send",now:now)?.state == "unverified" && store.action("verified-send",now:now)?.state == "sent","sent state requires explicit verified receipt")
        _=try store.ingest(event("idle","idle","Idle",0),now:now)
        try check(try store.action("idle",now:now)?.description.contains("no reading or work duration") == true,"idle is not evidence of attention")
        _=try store.ingest(event("sample-a","window.observed","Stable window",-20),now:now)
        _=try store.ingest(event("sample-b","window.observed","Stable window",-19),now:now)
        _=try store.ingest(event("interrupt","mouse.click","Elsewhere",-18),now:now)
        _=try store.ingest(event("sample-c","window.observed","Stable window",-17),now:now)
        let stable=try store.dayLayers(day:day,timezone:zone,now:now).activities.first{$0.subject == "Stable window"}!
        try check(stable.actionIDs.count == 3 && stable.clusters.map(\.actionIDs.count) == [2,1],"coalescing retains IDs and a revisit after interruption")
        var urlA=event("url-a","window.observed","Same title",-15), urlB=event("url-b","window.observed","Same title",-14)
        urlA.url="https://example.org/first"; urlB.url="https://example.org/second"
        _=try store.ingest(urlA,now:now); _=try store.ingest(urlB,now:now)
        try check(try store.dayLayers(day:day,timezone:zone,now:now).activities.first{$0.subject == "Same title"}?.clusters.count == 2,"same title/site with different page is not an unchanged observation")
        try store.setActionSubject(["status-check"],subject:"Sensor research",now:now)
        try check(try store.dayLayers(day:day,timezone:zone,now:now).activities.first{$0.id == group.id}!.actionIDs.contains("status-check"),"explicit grouping changes relationship, not evidence")
        try store.setActionSubject(["status-check"],subject:nil,now:now)
        try check(try store.action("status-check",now:now)?.title == "Build status","grouping undo preserves original action")
        let page=try store.actions(limit:2,now:now)
        try check(page.next != nil,"bounded actions expose cursor")
        _=try store.ingest(event("cursor-change"),now:now)
        try check(try store.actions(after:page.next,limit:2,now:now).snapshot == page.snapshot,"append preserves stable page snapshot")
        try store.setCaptureState("recording",reason:"synthetic heartbeat",now:now)
        try check(try store.currentActions(now:now).status == "recent_observations","fresh context reads canonical actions")
        try check(try store.context(now:now).status == "capture_recording","legacy Horizon status contract retained")
        try store.setCaptureState("paused",reason:"synthetic pause",now:now)
        try check(try store.currentActions(now:now).actions.isEmpty && store.context(now:now).sourceIDs.isEmpty,"pause exposes no old activity as current")
        try store.setCaptureState("recording",reason:"synthetic heartbeat",now:now)
        try check(try store.currentActions(now:now.addingTimeInterval(6)).status == "capture_unavailable","expired heartbeat is unavailable")
        try store.setCaptureState("recording",reason:"synthetic later heartbeat",now:now.addingTimeInterval(60))
        try check(try store.currentActions(now:now.addingTimeInterval(60)).status == "stale","fresh heartbeat with old actions is stale")
        let resource=try reader.openActionResource(ActionResources.actionURI("action-0"),now:now)
        try check(resource.contains("evidenceIDs") && !resource.contains("browserVerification") && !resource.contains("\"evidence\":"),"action resource omits private raw evidence object")
        try rejects("resource filesystem access rejected") { _=try reader.openActionResource("file:///etc/passwd",now:now) }
        try rejects("resource path traversal rejected") { _=try reader.openActionResource("macmem://actions/../../private.json",now:now) }
        let token=try store.grant(client:"fixture",recipient:"synthetic",scopes:["detail"])
        try store.authorize(client:"fixture",recipient:"synthetic",capability:token,scope:"detail")
        try store.revoke(client:"fixture",recipient:"synthetic")
        try rejects("revocation prevents resource access") { try reader.authorize(client:"fixture",recipient:"synthetic",capability:token,scope:"detail") }
        try check(try store.dayLayers(day:day,timezone:zone,now:now).activities.allSatisfy{$0.generated == nil},"revocation invalidates generated derivative cache")
        try store.delete("action-0")
        try check(try reader.action("action-0",now:now) == nil,"deleted original absent from action read")
        policy=try store.policy(); policy.blockedApps=["com.apple.TextEdit"]; try store.updatePolicy(policy,now:now)
        try check(try reader.actions(now:now).actions.allSatisfy{$0.bundle != "com.apple.TextEdit"},"current exclusions revalidate actions")
        let spring=try DayScope.interval(day:"2026-03-08",timezone:zone), fall=try DayScope.interval(day:"2026-11-01",timezone:zone)
        try check(spring.duration == 23*3600 && fall.duration == 25*3600,"DST day boundaries are 23 and 25 hours")
        let nepal=try DayScope.interval(day:"2026-09-11",timezone:"Asia/Kathmandu")
        try check(try DayScope.key(nepal.start.addingTimeInterval(-0.001),timezone:"Asia/Kathmandu") == "2026-09-10","quarter-hour timezone midnight boundary")
        let yesterday=try DayScope.key(now.addingTimeInterval(-86400),timezone:zone)
        try check(try store.dayLayers(day:yesterday,timezone:zone,now:now).defaultLayer == "day_summary","past days default to day summaries without removing action API")
        let busy=try MemoryStore(home:root.appendingPathComponent("busy"),writable:true,automaticallySyncSearch:false)
        for n in 0..<205 { _=try busy.ingest(event("busy-\(n)","mouse.click","Busy research"),now:now) }
        let busyRequest=try busy.prepareNote(kind:"day",day:day,timezone:zone,now:now)
        try check(busyRequest.actionCount == 205 && busyRequest.actions.count == 100 && busyRequest.next == 100,"busy day writer input is paginated, not truncated")
        let busyOutput=NoteWriterOutput(requestID:busyRequest.id,title:"Busy research",bullets:[NoteBullet(text:"Multiple research observations.",actionIDs:[busyRequest.actions[0].id])],generator:"synthetic-local",generatorVersion:"1")
        try rejects("cannot publish day coverage before all input pages") { _=try busy.commitNote(busyOutput,now:now) }
        try rejects("writer cannot skip input pages") { _=try busy.noteActions(requestID:busyRequest.id,after:200,now:now) }
        let middle=try busy.noteActions(requestID:busyRequest.id,after:100,now:now)
        let last=try busy.noteActions(requestID:busyRequest.id,after:middle.next!,now:now)
        try check(last.actions.count == 5 && last.next == nil,"final writer page retains the remaining actions")
        try check(try busy.commitNote(busyOutput,now:now).actionIDs.count == 205,"day note retains complete action relationships")
        let busyResource=try busy.openActionResource(ActionResources.dayURI(day,timezone:zone),now:now)
        try check(busyResource.utf8.count < 128_000 && busyResource.contains("205"),"busy day resource stays bounded without inventing counts")
        let pending=try busy.prepareNote(kind:"activity",day:day,timezone:zone,activityID:busy.dayLayers(day:day,timezone:zone,now:now).activities[0].id,now:now)
        try busy.delete(pending.actions[0].id)
        try rejects("deletion cancels remaining writer pages") { _=try busy.noteActions(requestID:pending.id,after:100,now:now) }
        try check(try busy.dayLayers(day:day,timezone:zone,now:now).summary.generated == nil,"deletion removes dependent day summary")
        try check(try !busy.ingest(event("derived-feedback","activity.note"),now:now),"generated note cannot enter canonical evidence ingest")
        let boundary=try MemoryStore(home:root.appendingPathComponent("midnight"),writable:true,automaticallySyncSearch:false)
        let boundaryNow=nepal.end.addingTimeInterval(5)
        var before=event("before-midnight"), after=event("after-midnight")
        before.at=iso(nepal.end.addingTimeInterval(-1)); after.at=iso(nepal.end.addingTimeInterval(1))
        _=try boundary.ingest(before,now:boundaryNow); _=try boundary.ingest(after,now:boundaryNow)
        let earlier=try boundary.dayLayers(day:"2026-09-11",timezone:"Asia/Kathmandu",now:boundaryNow)
        let later=try boundary.dayLayers(day:"2026-09-12",timezone:"Asia/Kathmandu",now:boundaryNow)
        try check(earlier.summary.actionCount == 1 && later.summary.actionCount == 1,"actual action grouping separates local midnight without dropping either side")
        let dst=try MemoryStore(home:root.appendingPathComponent("dst"),writable:true,automaticallySyncSearch:false)
        var first=event("fall-first"), second=event("fall-second")
        first.at="2026-11-01T01:30:00-04:00"; second.at="2026-11-01T01:30:00-05:00"
        _=try dst.ingest(first,now:fall.end); _=try dst.ingest(second,now:fall.end)
        let repeated=try dst.dayLayers(day:"2026-11-01",timezone:zone,now:fall.end)
        try check(repeated.actions.actions.map(\.id) == ["fall-first","fall-second"],"repeated DST hour retains distinct actions and absolute-time ordering")
        print("Action architecture checks: \(count) passed. Synthetic source only; no provider, capture or live index.")
    }
}
