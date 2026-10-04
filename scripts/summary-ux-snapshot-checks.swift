import Foundation
@testable import MemoryCore

/// Real core prepare/page/validate/commit paths, synthetic stores and clocks only.
/// No model, UI, owner data, network or plaintext diagnostics.
@main struct SummaryUXSnapshotChecks {
    static var passed=0,failed=0
    static var root:URL!
    static let base=Date().addingTimeInterval(2),zone="UTC"
    static var now:Date {base.addingTimeInterval(3600)}
    static var day:String {try! DayScope.key(base,timezone:zone)}
    struct Rig {let store:MemoryStore;let id:String}
    static func check(_ value:Bool,_ label:String) {print("\(value ? "PASS" : "FAIL") \(label)");if value {passed+=1}else{failed+=1}}
    static func rejected(_ label:String,_ work:() throws -> Void) {do {try work();check(false,label)}catch{check(true,label)}}
    static func add(_ s:MemoryStore,_ id:String,_ seconds:Double,_ title:String="Parser review") throws {
        _=try s.ingest(Evidence(id:id,at:iso(base.addingTimeInterval(seconds)),kind:"window.changed",
            app:"TextEdit",bundle:"com.apple.TextEdit",title:title,synthetic:true),now:now)
    }
    static func rig(_ label:String,count:Int=2) throws -> Rig {
        let s=try MemoryStore(home:root.appendingPathComponent(label),writable:true,automaticallySyncSearch:false)
        var p=try s.policy();p.continuationSince=base.addingTimeInterval(-1).timeIntervalSince1970;try s.updatePolicy(p,now:now)
        for n in 0..<count {try add(s,"original-\(n)",Double(n)*5)}
        let m=try s.dayLayers(day:day,timezone:zone,now:now).activities.first{$0.actionIDs.contains("original-0")}!
        return Rig(store:s,id:m.id)
    }
    static func prepare(_ r:Rig,allow:Bool=true,kind:String="activity",audience:NoteAudience = .local) throws -> NoteWriterRequest {
        try r.store.prepareNote(kind:kind,day:day,timezone:zone,activityID:kind == "activity" ? r.id:nil,
            audience:audience,now:now,allowGrowingSnapshot:allow)
    }
    static func revisions(_ request:NoteWriterRequest) -> [String:String] {Dictionary(uniqueKeysWithValues:request.actions.map{($0.id,$0.revision)})}
    static func output(_ request:NoteWriterRequest,_ ids:[String]?=nil) -> NoteWriterOutput {
        NoteWriterOutput(requestID:request.id,title:"Synthetic snapshot",bullets:[NoteBullet(text:"Synthetic interpretation",
            actionIDs:ids ?? request.actions.map(\.id),assertion:"interpretation")],generator:"fixture",generatorVersion:"1")
    }
    static func main() throws {
        root=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let a=try rig("additive"),q=try prepare(a)
        try add(a.store,"tail",20)
        try a.store.validatePreparedNote(q.id,revisions:revisions(q),now:now)
        check(true,"opted local snapshot stays permitted after additive capture")
        let generated=try a.store.commitNote(output(q),now:now)
        let current=try a.store.dayLayers(day:day,timezone:zone,now:now).activities.first{$0.id == a.id}!
        check(generated.inputRevision == q.inputRevision && generated.actionIDs == q.actions.map(\.id),"snapshot commit retains exact original coverage and revision")
        check(current.actionIDs.count == 3 && current.generated == nil && current.previous?.output == generated.output,
              "growing moment displays snapshot as previous without claiming tail coverage")
        check(try a.store.commitNote(output(q),now:now).output == generated.output,"committed retry revalidates original snapshot after input actions cleared")
        try add(a.store,"another-tail",30)
        check(try a.store.commitNote(output(q),now:now).output == generated.output,"retry accepts another append without widening coverage")
        try a.store.exec("UPDATE records SET body=json_set(body,'$.synthetic',json('false')) WHERE id='original-0'")
        try a.store.invalidateDisclosure()
        let retryGroup=try a.store.dayLayers(day:day,timezone:zone,now:now).activities.first{$0.id == a.id}
        check(retryGroup?.actionIDs == ["original-0","original-1","tail","another-tail"],"retry mutation leaves moment membership and ordering unchanged")
        rejected("retry after cleared input bodies rejects changed original metadata") {_=try a.store.commitNote(output(q),now:now)}
        for (label,allow,kind,audience) in [("default",false,"activity",NoteAudience.local),("cloud",true,"activity",NoteAudience.cloud),("day",true,"day",NoteAudience.local)] {
            let r=try rig(label),request=try prepare(r,allow:allow,kind:kind,audience:audience);try add(r.store,"tail",20)
            rejected("\(label) request retains strict whole-scope revision") {try r.store.validatePreparedNote(request.id,revisions:revisions(request),now:now)}
            rejected("\(label) changed scope cannot commit") {_=try r.store.commitNote(output(request),now:now)}
        }
        let old=try rig("legacy"),oldQ=try prepare(old)
        try old.store.exec("UPDATE note_requests SET body=json_remove(body,'$.allowGrowingSnapshot') WHERE id=?",[oldQ.id])
        try add(old.store,"tail",20)
        rejected("old stored request without private opt-in fails closed") {try old.store.validatePreparedNote(oldQ.id,revisions:revisions(oldQ),now:now)}
        let mode=try rig("dedup"),normal=try prepare(mode,allow:false),active=try prepare(mode)
        check(normal.id != active.id,"snapshot opt-in cannot reuse a strict pending request")
        let late=try rig("late"),lateQ=try prepare(late);try add(late.store,"inserted",2)
        rejected("late insertion between original actions is not additive tail capture") {try late.store.validatePreparedNote(lateQ.id,revisions:revisions(lateQ),now:now)}
        let name=try rig("name"),nameQ=try prepare(name);try add(name.store,"tail",20,"Parser review and migration")
        rejected("changed moment subject cannot relax snapshot grounding") {try name.store.validatePreparedNote(nameQ.id,revisions:revisions(nameQ),now:now)}
        let changed=try rig("changed"),changedQ=try prepare(changed);try add(changed.store,"tail",20)
        try changed.store.exec("UPDATE records SET body=json_set(body,'$.title','Changed original subject') WHERE id='original-0'")
        try changed.store.invalidateDisclosure()
        rejected("changed original action cannot commit a snapshot") {_=try changed.store.commitNote(output(changedQ),now:now)}
        let corrected=try rig("corrected"),correctedQ=try prepare(corrected);try add(corrected.store,"tail",20)
        _=try corrected.store.correctAction(id:"original-0",text:"Synthetic corrected intent",
            expectedRevision:corrected.store.action("original-0",now:now)!.revision,now:now)
        rejected("correction invalidates pending snapshot") {_=try corrected.store.commitNote(output(correctedQ),now:now)}
        let forgotten=try rig("forgotten"),forgottenQ=try prepare(forgotten);try add(forgotten.store,"tail",20)
        let deletion=try forgotten.store.prepareDeletion(scope:MemoryActionScope(kind:"action",id:"original-0"),now:now)
        _=try forgotten.store.executeDeletion(previewID:deletion.id,confirmed:true,now:now)
        rejected("Forget invalidates pending snapshot") {_=try forgotten.store.commitNote(output(forgottenQ),now:now)}
        let policy=try rig("policy"),policyQ=try prepare(policy);try add(policy.store,"tail",20)
        var p=try policy.store.policy();p.blockedApps.append("com.apple.TextEdit");try policy.store.updatePolicy(p,now:now)
        rejected("privacy policy change invalidates snapshot") {_=try policy.store.commitNote(output(policyQ),now:now)}
        let expiry=try rig("expiry"),expiryQ=try prepare(expiry);try add(expiry.store,"tail",20)
        rejected("original request expiry remains enforced") {_=try expiry.store.commitNote(output(expiryQ),now:now.addingTimeInterval(301))}
        let cancel=try rig("cancel"),cancelQ=try prepare(cancel);try add(cancel.store,"tail",20);try cancel.store.cancelNote(cancelQ.id)
        rejected("cancelled snapshot cannot commit") {_=try cancel.store.commitNote(output(cancelQ),now:now)}
        let paged=try rig("paged",count:101),pageQ=try prepare(paged);try add(paged.store,"tail",510)
        rejected("snapshot still requires reading every original input page") {_=try paged.store.commitNote(output(pageQ),now:now)}
        let page=try paged.store.noteActions(requestID:pageQ.id,after:100,now:now)
        let all=pageQ.actions+page.actions
        try paged.store.validatePreparedNote(pageQ.id,revisions:Dictionary(uniqueKeysWithValues:all.map{($0.id,$0.revision)}),now:now)
        check(page.actionCount == 101 && page.actions.count == 1 && page.next == nil,"paging after append returns only original snapshot tail")
        let pagedNote=try paged.store.commitNote(output(pageQ,all.map(\.id)),now:now)
        check(pagedNote.actionIDs.count == 101 && !pagedNote.actionIDs.contains("tail"),"fully paged snapshot commits exact original coverage")
        let persisted=try paged.store.rows("SELECT json_array_length(json_extract(body,'$.request.actions')) FROM note_requests WHERE id=?",[pageQ.id])
        check(persisted.first?.first == "0","committed snapshots retain no provider input action bodies")
        let laterPage=try rig("changed-beyond-page",count:101),laterQ=try prepare(laterPage)
        _=try laterPage.store.noteActions(requestID:laterQ.id,after:100,now:now)
        try add(laterPage.store,"tail",510)
        let originalLast=try laterPage.store.action("original-100",now:now)!.revision
        try laterPage.store.exec("UPDATE records SET body=json_set(body,'$.synthetic',json('false')) WHERE id='original-100'")
        try laterPage.store.invalidateDisclosure()
        let laterGroup=try laterPage.store.dayLayers(day:day,timezone:zone,now:now).activities.first{$0.id == laterPage.id}
        let changedLast=try laterPage.store.action("original-100",now:now)!.revision
        check(laterGroup?.actionIDs.count == 102 && laterGroup?.actionIDs.last == "tail" &&
              changedLast != originalLast,
              "beyond-first-page metadata mutation preserves exact original prefix and changes canonical revision")
        rejected("all-original snapshot hash rejects changed action beyond first page") {_=try laterPage.store.commitNote(output(laterQ,(0..<101).map{"original-\($0)"}),now:now)}
        print("\(passed) passed, \(failed) failed; synthetic core snapshot checks")
        if failed > 0 {exit(1)}
    }
}
