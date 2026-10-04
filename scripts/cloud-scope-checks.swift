// What of browser pages reaches cloud summaries: cleaned titles and hosts, never addresses, never a correction that
// covers a page (fix/day-card, owner decision 9/28). Compiles the actual app
// WriterScheduling.swift (like writer-retention-checks.swift). Synthetic stores
// only: no provider, network, key, capture or Apple Event.
import Foundation
@testable import MemoryCore
import WriterBackend

@main struct CloudScopeChecks {
    static var count=0
    static func check(_ value:Bool,_ name:String)throws {
        guard value else {throw MemError.invalid("FAIL: "+name)}
        count += 1;print("PASS: "+name)
    }
    static func refused(_ name:String,_ text:String,_ work:() throws -> Void) throws {
        do {try work();throw MemError.invalid("FAIL: "+name)}
        catch {try check("\(error)".contains(text),name)}
    }
    static func main() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("cloud-scope-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let now=timestamp("2026-09-14T12:00:00Z")!,at=now.addingTimeInterval(-180),day="2026-09-14"
        func store(_ name:String)throws->MemoryStore {try MemoryStore(home:root.appendingPathComponent(name),writable:true,automaticallySyncSearch:false)}
        func page(_ s:MemoryStore,_ id:String,_ title:String,_ site:String,_ when:Date)throws {
            var proof=BrowserVerification(mode:"normal",windowID:"1520",tabID:"1733",focusedRole:"",checkedAt:isoPrecise(when),provider:BrowserSafety.pageProvider)
            proof.policyRevision="policy-fixture"
            guard try s.ingest(Evidence(id:id,at:isoPrecise(when),kind:"window.changed",app:"Google Chrome",bundle:"com.google.Chrome",title:title,url:site,browserVerification:proof),now:now) else {throw MemError.invalid("FAIL: page fixture refused")}
        }
        func native(_ s:MemoryStore,_ id:String,_ title:String,_ when:Date)throws {
            _=try s.ingest(Evidence(id:id,at:iso(when),kind:"window.changed",app:"Notes",bundle:"com.apple.Notes",title:title,synthetic:true),now:now)
        }
        // fix/day-card (owner decision, 9/28): a cloud writer reads browser moments too, as their host and cleaned page
        // title (TitleClean: no address, unread count or app suffix), never the page's address. Corrections that cover a
        // browser page stay local (below). Neither audience writes a moment made only of idle rows.
        try check(NoteAudience.cloudEligible(bundle:"com.apple.Notes") && !NoteAudience.cloudEligible(bundle:"com.google.Chrome")
                  && !NoteAudience.cloudEligible(bundle:"com.apple.Safari") && !NoteAudience.cloudEligible(bundle:"com.google.Chrome.canary"),
                  "page history: every browser is still marked a browser (its titles are cleaned for the cloud, its corrections stay local)")

        let s=try store("mixed")
        try page(s,"chrome-only","(3) Orchid pricing - Orchid Shop","https://shop.example.org",at)
        try native(s,"mixed-notes","Garden budget",at.addingTimeInterval(1))
        try page(s,"mixed-chrome","Garden budget (4) - Google Sheets","https://sheets.example.net",at.addingTimeInterval(2))
        try s.setActionSubject(["mixed-notes","mixed-chrome"],subject:"Garden budget",now:now)
        let layers=try s.dayLayers(day:day,timezone:"UTC",now:now)
        guard let chromeOnly=layers.activities.first(where:{$0.actionIDs==["chrome-only"]}),
              let mixed=layers.activities.first(where:{Set($0.actionIDs)==["mixed-notes","mixed-chrome"]}) else {throw MemError.invalid("FAIL: fixture activities \(layers.activities.map(\.actionIDs))")}

        // noteTargets: the same moments for both audiences.
        let local=try s.noteTargets(day:day,timezone:"UTC",now:now)
        try check(try local.map(\.id) == s.noteTargets(day:day,timezone:"UTC",audience:.local,now:now).map(\.id),"page history: the default audience is local")
        try check(local.contains{$0.id==chromeOnly.id} && local.contains{$0.id==mixed.id} && local.contains{$0.kind=="day"},"page history: local targets are unchanged (Chrome pages included)")
        let cloud=try s.noteTargets(day:day,timezone:"UTC",audience:.cloud,now:now)
        try check(cloud.contains{$0.id==chromeOnly.id} && cloud.contains{$0.id==mixed.id} && cloud.contains{$0.kind=="day"},"page history: browser moments are cloud targets too")

        // prepareNote: a cloud request reads browser pages as host and cleaned title, never the address.
        let request=try s.prepareNote(kind:"activity",day:day,timezone:"UTC",activityID:mixed.id,audience:.cloud,now:now)
        let stored=try s.rows("SELECT body FROM note_requests WHERE id=?",[request.id]).first!.first!
        try check(Set(request.actions.map(\.id)) == ["mixed-notes","mixed-chrome"] && stored.contains("\"audience\":\"cloud\""),"page history: a mixed activity's cloud request has both actions and says cloud")
        let sentPage=request.actions.first{$0.id=="mixed-chrome"}!
        let sent=[sentPage.title,sentPage.subject,sentPage.description,sentPage.observedDescription ?? ""].joined(separator:"\n")
        try check(sentPage.title == "Garden budget" && !sent.contains("(4)") && !sent.contains("Google Sheets") && !sent.contains("https://"),
                  "page history: a cloud request carries the cleaned page title and site, never the address")
        let inbox=try s.prepareNote(kind:"activity",day:day,timezone:"UTC",activityID:chromeOnly.id,audience:.cloud,now:now)
        let inboxText=inbox.actions.map { [$0.title,$0.subject,$0.description,$0.observedDescription ?? ""].joined(separator:"\n") }.joined()
        try check(inbox.actions.map(\.id) == ["chrome-only"] && !inboxText.contains("(3)") && !inboxText.contains("https://"),
                  "page history: a Chrome-only activity reaches the cloud without its unread count or address")
        let localRequest=try s.prepareNote(kind:"activity",day:day,timezone:"UTC",activityID:mixed.id,now:now)
        try check(localRequest.id != request.id && localRequest.actions.first{$0.id=="mixed-chrome"}?.title == "Garden budget (4) - Google Sheets",
                  "page history: a local request is never a pending cloud request, and keeps the page as recorded")
        func output(_ id:String,_ ids:[String]) -> NoteWriterOutput {
            NoteWriterOutput(requestID:id,title:"Garden budget",bullets:[NoteBullet(text:"Worked on the garden budget.",actionIDs:ids,assertion:"observed")],generator:"fixture",generatorVersion:"1")
        }
        try s.cancelNote(localRequest.id)
        let cloudAgain=try s.prepareNote(kind:"activity",day:day,timezone:"UTC",activityID:mixed.id,audience:.cloud,now:now)
        let note=try s.commitNote(output(cloudAgain.id,["mixed-notes","mixed-chrome"]),now:now)
        try check(Set(note.actionIDs) == ["mixed-notes","mixed-chrome"],"page history: a cloud note may cite the pages it was given")

        // Idle rows alone are no one's work.
        let idle=try store("idle")
        for i in 0..<3 { _=try idle.ingest(Evidence(id:"idle-\(i)",at:iso(at.addingTimeInterval(Double(i*20))),kind:"idle",app:"",bundle:"",title:"",synthetic:true),now:now) }
        try native(idle,"i-notes","Garden budget",at.addingTimeInterval(1800))
        let idleLayers=try idle.dayLayers(day:day,timezone:"UTC",now:now.addingTimeInterval(3600))
        let idleOnly=idleLayers.activities.filter(NoteAudience.idleOnly)
        for audience in [NoteAudience.local,.cloud] {
            let targets=try idle.noteTargets(day:day,timezone:"UTC",audience:audience,now:now.addingTimeInterval(3600))
            try check(!targets.contains{ t in idleOnly.contains{$0.id==t.id} },"page history: no \(audience) writer is asked for a moment of idle rows only")
        }

        // WriterQueueSource: the same work for both audiences.
        let fresh=try store("queue")
        try page(fresh,"q-chrome","Orchid pricing","https://shop.example.org",at)
        try native(fresh,"q-notes","Garden budget",at.addingTimeInterval(1))
        let source=WriterQueueSource(store:fresh)
        let startAudience=await source.audience
        try check(startAudience == .local,"page history: the writer queue starts local")
        let localFound=try await source.discover(now:now,timezone:"UTC")
        guard let chromeItem=localFound.first(where:{ item in
            (try? fresh.dayLayers(day:day,timezone:"UTC",now:now).activities.first{$0.id==item.activityID}?.actionIDs) == ["q-chrome"] }) else {
            throw MemError.invalid("FAIL: local discovery should include the Chrome-only activity")
        }
        // fix/sx-engine-battery: moments only; a day's summary comes from its moments and blocks, never a whole-day note.
        try check(!localFound.contains{$0.kind=="day"},"page history: local discovery lists moments only, no whole-day note")
        let localCurrent=try await source.isCurrent(chromeItem),localObsolete=try await source.obsoleteKeys([chromeItem])
        try check(localCurrent && localObsolete.isEmpty,"page history: local queue keeps the Chrome-only activity")
        await source.setAudience(.cloud)
        let cloudFound=try await source.discover(now:now,timezone:"UTC")
        try check(cloudFound.contains{$0.key==chromeItem.key} && !cloudFound.contains{$0.kind=="day"},"page history: cloud discovery includes browser activities, moments only")
        let cloudCurrent=try await source.isCurrent(chromeItem)
        try check(cloudCurrent,"page history: a browser target stays current for the cloud")
        await source.setAudience(.local)

        // Review P1: a note correction pre-filled from a local note that was
        // written from Chrome pages never reaches a cloud writer.
        let corr=try store("correction")
        try native(corr,"k-notes","Garden budget",at.addingTimeInterval(1))
        try page(corr,"k-chrome","Garden budget","https://sheets.example.net",at.addingTimeInterval(2))
        try native(corr,"k-other","Seed order",at.addingTimeInterval(-3600))
        try corr.setActionSubject(["k-notes","k-chrome"],subject:"Garden budget",now:now)
        func mixedOf(_ s:MemoryStore)throws->ActivityNote {
            guard let m=try s.dayLayers(day:day,timezone:"UTC",now:now).activities.first(where:{Set($0.actionIDs)==["k-notes","k-chrome"]}) else {throw MemError.invalid("FAIL: correction fixture")}
            return m
        }
        let localNoteRequest=try corr.prepareNote(kind:"activity",day:day,timezone:"UTC",activityID:mixedOf(corr).id,now:now)
        _=try corr.commitNote(NoteWriterOutput(requestID:localNoteRequest.id,title:"Garden budget, then read Divorce lawyers near me",bullets:[NoteBullet(text:"Looked at the budget.",actionIDs:["k-notes","k-chrome"],assertion:"observed")],generator:"local",generatorVersion:"1"),now:now)
        let withNote=try mixedOf(corr)
        let prefill=withNote.generated?.output.title ?? withNote.subject
        try check(prefill.contains("Divorce lawyers"),"page history: the correction box would be pre-filled from a note written from a Chrome page")
        _=try corr.correctNote(scope:MemoryActionScope(kind:"activity",id:withNote.id,day:day,timezone:"UTC"),text:prefill,expectedRevision:withNote.inputRevision,now:now)
        let afterCorrection=try mixedOf(corr)
        let localWithCorrection=try corr.prepareNote(kind:"activity",day:day,timezone:"UTC",activityID:afterCorrection.id,now:now)
        try check((localWithCorrection.corrections ?? []).contains{$0.text == prefill},"page history: a local writer still gets the owner's correction")
        let cloudCorrected=try corr.prepareNote(kind:"activity",day:day,timezone:"UTC",activityID:afterCorrection.id,audience:.cloud,now:now)
        let cloudStored=try corr.rows("SELECT body FROM note_requests WHERE id=?",[cloudCorrected.id]).first!.first!
        try check((cloudCorrected.corrections ?? []).isEmpty && !cloudStored.contains("Divorce"),
                  "page history: a cloud activity request drops a correction that covers a Chrome page")
        let cloudDay=try corr.prepareNote(kind:"day",day:day,timezone:"UTC",audience:.cloud,now:now)
        try check((cloudDay.corrections ?? []).isEmpty,"page history: a cloud day request drops it too")
        // A correction on browser-free work still goes to the cloud writer.
        let seed=try corr.dayLayers(day:day,timezone:"UTC",now:now).activities.first{$0.actionIDs==["k-other"]}!
        _=try corr.correctNote(scope:MemoryActionScope(kind:"activity",id:seed.id,day:day,timezone:"UTC"),text:"Ordered tomato seeds",expectedRevision:seed.inputRevision,now:now)
        let seedCloud=try corr.prepareNote(kind:"activity",day:day,timezone:"UTC",activityID:seed.id,audience:.cloud,now:now)
        try check((seedCloud.corrections ?? []).map{$0.text} == ["Ordered tomato seeds"],"page history: a correction on browser-free work still reaches a cloud writer")
        // Defence in depth: a stored cloud request that carries such a correction cannot commit.
        let tampered=try corr.prepareNote(kind:"activity",day:day,timezone:"UTC",activityID:try mixedOf(corr).id,audience:.cloud,now:now)
        var tBody=try JSONSerialization.jsonObject(with:Data(corr.rows("SELECT body FROM note_requests WHERE id=?",[tampered.id]).first!.first!.utf8)) as! [String:Any]
        var tRequest=tBody["request"] as! [String:Any]
        tRequest["corrections"]=[["targetKind":"activity","targetID":"x","version":1,"text":"Divorce lawyers near me","actionIDs":["k-chrome","k-notes"],"authoredAt":iso(now),"attribution":"User correction, not observed evidence"]]
        tBody["request"]=tRequest
        try corr.exec("UPDATE note_requests SET body=? WHERE id=?",[String(decoding:JSONSerialization.data(withJSONObject:tBody),as:UTF8.self),tampered.id])
        try refused("page history: commitNote refuses a cloud request whose correction covers a Chrome page","Cloud note references browser activity") {
            _=try corr.commitNote(NoteWriterOutput(requestID:tampered.id,title:"Garden budget",bullets:[NoteBullet(text:"Worked on the garden budget.",actionIDs:["k-notes"],assertion:"reported")],generator:"fixture",generatorVersion:"1"),now:now)
        }
        print("PASS \(count) cloud scope checks; synthetic stores only")
    }
}
