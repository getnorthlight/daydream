import Foundation
@testable import MemoryCore
import MemoryUI

/// Synthetic isolated stores only. No capture, AppKit activation, model or network.
@MainActor @main enum FallbackCompatibilityChecks {
    static var passed=0,failed=0
    static let zone="America/Chicago"
    static let legacy="code-fallback1-validator12", prior="code-fallback2-validator12", current=CodeFallbackNote.version
    static let line="Typed a draft in X."
    static let now=Date()
    static var root:URL!
    static func check(_ ok:Bool,_ label:String) {if ok {passed+=1;print("PASS "+label)} else {failed+=1;print("FAIL "+label)}}
    static func fixture(_ name:String,ageDays:Int=0) throws -> (MemoryStore,String,String) {
        let store=try MemoryStore(home:root.appendingPathComponent(name),writable:true,automaticallySyncSearch:false)
        let at=now.addingTimeInterval(-Double(ageDays)*86400-3600)
        _ = try store.ingest(Evidence(id:name+"-observation",at:iso(at),kind:"window.changed",app:"Google Chrome",bundle:"com.google.Chrome",title:"X",url:"https://x.com",synthetic:true),now:now)
        let day=try DayScope.key(at,timezone:zone)
        let activity=try store.dayLayers(day:day,timezone:zone,now:now).activities.first!
        return (store,day,activity.id)
    }
    static func output(_ request:NoteWriterRequest,provider:String,version:String)->NoteWriterOutput {
        NoteWriterOutput(requestID:request.id,title:"X",bullets:[NoteBullet(text:line,actionIDs:request.actions.map(\.id),assertion:"observed")],generator:provider,generatorVersion:version)
    }
    static func main() throws {
        setvbuf(stdout,nil,_IOLBF,0)
        let base=ProcessInfo.processInfo.environment["FALLBACK_CHECK_ROOT"].map{URL(fileURLWithPath:$0,isDirectory:true)} ?? FileManager.default.temporaryDirectory
        root=base.appendingPathComponent("fallback-compat-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer {try? FileManager.default.removeItem(at:root)}
        try providerPairs()
        try persistedDisplay(ageDays:0)
        try persistedDisplay(ageDays:6)
        check(NoteWriterVersions.current.contains(current) && !NoteWriterVersions.current.contains(legacy),"only the exact new fallback version remains current")
        check(NoteWriterVersions.outdated(legacy) && NoteWriterVersions.outdated(prior) && !NoteWriterVersions.outdated(current),"known fallback1 and fallback2 remain eligible for bounded recent rewrite")
        print("fallback-compat: \(passed) passed, \(failed) failed")
        if failed>0 {exit(1)}
    }
    static func providerPairs() throws {
        let pairs:[(String,String,Bool)]=[
            (CodeFallbackNote.provider,legacy,true),(CodeFallbackNote.provider,prior,true),(CodeFallbackNote.provider,current,true),
            (CodeFallbackNote.provider,"code-fallback4-validator13",false),(CodeFallbackNote.provider,"1",false),
            ("local/synthetic",legacy,false),("local/synthetic",current,false),("local/synthetic","code-fallback4-validator13",false),
            ("code/moment-notes",legacy,false),("code/moment-notes",current,false),
            ("local/synthetic","fixture1",true)]
        for (i,pair) in pairs.enumerated() {
            let (store,day,id)=try fixture("pair-\(i)")
            let request=try store.prepareNote(kind:"activity",day:day,timezone:zone,activityID:id,now:now)
            let out=output(request,provider:pair.0,version:pair.1)
            var accepted=false
            do {_ = try store.commitNote(out,now:now);accepted=true} catch {}
            check(accepted==pair.2,"core put pair \(pair.0) / \(pair.1): \(pair.2 ? "accepted" : "refused")")
            check(CodeFallbackNote.isFallback(out)==(pair.0==CodeFallbackNote.provider && [legacy,prior,current].contains(pair.1)),"display trusts only exact known fallback pair \(i)")
        }
    }
    static func persistedDisplay(ageDays:Int) throws {
        let (store,day,id)=try fixture("saved-\(ageDays)",ageDays:ageDays)
        let request=try store.prepareNote(kind:"activity",day:day,timezone:zone,activityID:id,now:now)
        var saved=try store.commitNote(output(request,provider:CodeFallbackNote.provider,version:current),now:now)
        // Mimic a historically committed fallback1 row in this isolated fixture; earlier builds wrote this exact pair.
        // This is not a production write path. Fresh-put compatibility is independently tested above.
        saved.output.generatorVersion=legacy
        let body=String(decoding:try JSONEncoder().encode(saved),as:UTF8.self)
        try store.exec("UPDATE generated_notes SET body=? WHERE id=? AND version=?",[body,id,String(saved.version)])
        check(try store.latestNote(id:id)?.output.generatorVersion==legacy,"legacy persisted note is readable at age\(ageDays)")
        let note=try store.dayLayers(day:day,timezone:zone,now:now).activities.first!
        check(ageDays==0 ? note.status=="pending" && note.previous?.output.generatorVersion==legacy : note.status=="ready" && note.generated?.output.generatorVersion==legacy,
              ageDays==0 ? "recent fallback1 becomes pending with previous note" : "old-day fallback1 stays ready as written")
        var cal=Calendar(identifier:.gregorian);cal.timeZone=TimeZone(identifier:zone)!
        let slice=MomentSlice.make(note:note,dayPartial:false,summaries:SummaryAvailability(provider:.local,busy:false),calendar:cal)
        check(slice.bullets.map(\.text)==[line],"legacy age\(ageDays) bullet stays visible")
        check(slice.byCode && !FocusListExpanded.showsModelMark(slice) && !FocusListExpanded.showsCloudKeyChip(slice),"legacy age\(ageDays) remains labeled as code, no model/cloud mark")
        check(FocusListExpanded.showsSummary(slice),"legacy age\(ageDays) still has expanded Summary")
        if ageDays==0 {
            check(slice.stale && slice.currentSummaryState == .pending,"legacy previous note does not count as current-ready")
        } else {check(!slice.stale,"old-day retained note is not labeled updating")}
        let snapshot=try MemoryStore(home:root.appendingPathComponent("snapshot-\(ageDays)"),writable:true,automaticallySyncSearch:false)
        _ = try store.exportCanonicalSnapshot(to:snapshot,now:now)
        check(try snapshot.latestNote(id:id)?.output.generatorVersion==legacy,"canonical snapshot retains exact legacy generation metadata age\(ageDays)")
        let imported=try snapshot.dayLayers(day:day,timezone:zone,now:now).activities.first!
        let importedSlice=MomentSlice.make(note:imported,dayPartial:false,summaries:SummaryAvailability(provider:.local,busy:false),calendar:cal)
        check(importedSlice.bullets.map(\.text)==[line] && importedSlice.byCode,"canonical snapshot legacy display preserved age\(ageDays)")
        let currentStore=try fixture("current-\(ageDays)",ageDays:ageDays)
        let currentRequest=try currentStore.0.prepareNote(kind:"activity",day:currentStore.1,timezone:zone,activityID:currentStore.2,now:now)
        _ = try currentStore.0.commitNote(output(currentRequest,provider:CodeFallbackNote.provider,version:current),now:now)
        let currentNote=try currentStore.0.dayLayers(day:currentStore.1,timezone:zone,now:now).activities.first!
        let currentSlice=MomentSlice.make(note:currentNote,dayPartial:false,summaries:SummaryAvailability(provider:.local,busy:false),calendar:cal)
        check(currentNote.status=="ready" && currentSlice.bullets.map(\.text)==[line] && currentSlice.byCode && !currentSlice.stale,"current fallback visible and ready age\(ageDays)")
    }
}
