import Foundation
@testable import MemoryCore
import WriterBackend

/// gold/notes regression checks for the notes stream (test 5): day assembly cost and lock hold (G15/G18/G19), notes
/// kept across corrections, preference saves and the test 4 upgrade (G20/G21/G22), moment grouping (G23), the prepare
/// race (G26), bounded note tables and the note count AI apps read (G63/G52), hidden rows leaving "pending" (extra6),
/// and work the writer can never finish staying out of its queue (G25/G73, local).
/// Synthetic stores under NOTES_CHECK_ROOT (else the temporary folder) only: no app, no capture, no Keychain, no network.
@main struct NotesGoldenChecks {
    static var passed=0,failed=0
    static func check(_ value:Bool,_ label:String,_ detail:@autoclosure ()->String="") {
        if value {passed+=1;print("PASS "+label)} else {failed+=1;print("FAIL "+label+(detail().isEmpty ? "" : " — "+detail()))}
    }
    static func seconds(_ work:() throws -> Void) rethrows -> Double {
        let start=DispatchTime.now().uptimeNanoseconds;try work();return Double(DispatchTime.now().uptimeNanoseconds-start)/1e9
    }
    static let zone="UTC"
    static let now=Date()
    /// Yesterday (UTC) at 09:00: every fixture action is in the past, whatever the time of day.
    static let dayStart:Date={let today=try! DayScope.interval(day:try! DayScope.key(now,timezone:zone),timezone:zone).start;return today.addingTimeInterval(-86400+9*3600)}()
    static let day=try! DayScope.key(dayStart,timezone:zone)
    static var root:URL!
    static func store(_ name:String) throws -> MemoryStore {try MemoryStore(home:root.appendingPathComponent(name),writable:true,automaticallySyncSearch:false)}
    static func add(_ s:MemoryStore,_ id:String,_ at:Date,_ title:String,app:String="TextEdit",bundle:String="com.apple.TextEdit") throws {
        _=try s.ingest(Evidence(id:id,at:iso(at),kind:"window.changed",app:app,bundle:bundle,title:title,synthetic:true),now:now)
    }
    /// Prepares and commits a note through the core API, citing every action of the request.
    @discardableResult static func note(_ s:MemoryStore,_ kind:String,_ activityID:String?=nil,day:String=day) throws -> GeneratedNote {
        let request=try s.prepareNote(kind:kind,day:day,timezone:zone,activityID:activityID,now:now)
        var ids=request.actions.map(\.id),next=request.next
        while let offset=next {let page=try s.noteActions(requestID:request.id,after:offset,now:now);ids+=page.actions.map(\.id);next=page.next}
        return try s.commitNote(NoteWriterOutput(requestID:request.id,title:"Synthetic note",bullets:[NoteBullet(text:"Synthetic interpretation",actionIDs:ids,assertion:"interpretation")],generator:"fixture",generatorVersion:"1"),now:now)
    }
    static func activity(_ layers:ActionDay,containing id:String) -> ActivityNote? {layers.activities.first{$0.actionIDs.contains(id)}}

    static func main() async throws {
        setvbuf(stdout,nil,_IOLBF,0)
        let base=ProcessInfo.processInfo.environment["NOTES_CHECK_ROOT"].map{URL(fileURLWithPath:$0,isDirectory:true)} ?? FileManager.default.temporaryDirectory
        root=base.appendingPathComponent("notes-golden-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        try grouping()
        try upgrade()
        try corrections()
        try preferences()
        try bounded()
        try hidden()
        try await capacity()
        try race()
        try await cost()
        print("notes-golden: \(passed) passed, \(failed) failed")
        if failed>0 {try? FileManager.default.removeItem(at:root);exit(1)}
    }

    /// G23: continuation joins a window whose title grew, never two documents bridged by an untitled window.
    static func grouping() throws {
        for (name,titles,expected) in [("empty",["Budget","","Letter"],2),("app-name",["Budget","TextEdit","Letter"],2),
                                       ("number",["Untitled","Untitled 2"],2),("growth",["Groceries","Groceries and errands"],1)] {
            let s=try store("group-"+name)
            for (i,title) in titles.enumerated() {try add(s,"\(name)-\(i)",dayStart.addingTimeInterval(Double(i*30)),title)}
            let layers=try s.dayLayers(day:day,timezone:zone,now:now)
            check(layers.activities.count==expected,"G23 \(titles) in one app → \(expected) moment\(expected==1 ? "" : "s")","got \(layers.activities.map(\.subject))")
            if name=="empty" {
                check(activity(layers,containing:"empty-0")?.subject=="Budget","G23 the untitled window joins Budget and the moment keeps its name",
                      "got \(layers.activities.map(\.subject))")
            }
        }
    }

    /// G22: notes written by test 4 (whose grouping had no continuation) stay ready after test 5 opens the store.
    static func upgrade() throws {
        let home=root.appendingPathComponent("upgrade")
        let s=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false)
        // The policy as test 4 left it: no continuation stamp and no notes binding.
        var policy=try JSONSerialization.jsonObject(with:Data(try s.rows("SELECT body FROM metadata WHERE id='policy'")[0][0].utf8)) as! [String:Any]
        policy.removeValue(forKey:"continuationSince");policy.removeValue(forKey:"notesRevision")
        let legacy=String(data:try JSONSerialization.data(withJSONObject:policy,options:[.sortedKeys]),encoding:.utf8)!
        try s.exec("UPDATE metadata SET body=? WHERE id='policy'",[legacy])
        try add(s,"up-1",dayStart,"Budget",app:"Numbers",bundle:"com.apple.iWork.Numbers")
        try add(s,"up-2",dayStart.addingTimeInterval(60),"Budget and plan",app:"Numbers",bundle:"com.apple.iWork.Numbers")
        // Test 4's moments for these two actions, computed by its rules: one moment per title.
        let revision=policy["revision"] as! String
        var moments:[(id:String,input:String,actions:[String])]=[]
        for id in ["up-1","up-2"] {
            let action=try s.action(id,now:now)!
            let name=action.subject.isEmpty ? action.app : action.subject
            let normalized=name.lowercased().split(whereSeparator:{$0.isWhitespace}).joined(separator:" ")
            moments.append(("activity_"+fingerprint(try json([day,zone,normalized,id])),fingerprint(try json([action])+revision+name+json([UserCorrection]())),[id]))
        }
        let dayID="day_"+fingerprint(day+"|"+zone),dayInput=fingerprint(try json(moments.map{[$0.id,$0.input]})+revision)
        for (id,input,actions) in moments+[(dayID,dayInput,["up-1","up-2"])] {
            let note=GeneratedNote(id:id,version:1,schemaVersion:1,generatedAt:iso(now),inputRevision:input,actionIDs:actions,
                                   output:NoteWriterOutput(requestID:"test4-"+id,title:"Test 4 note",bullets:[NoteBullet(text:"Written by test 4",actionIDs:actions,assertion:"interpretation")],generator:"fixture",generatorVersion:"1"),status:"generated_unverified")
            try s.exec("INSERT INTO generated_notes VALUES(?,?,?,?)",[id,"1",input,json(note)])
        }
        // Test 5 opens the store for writing (the upgrade).
        let upgraded=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false)
        let layers=try upgraded.dayLayers(day:day,timezone:zone,now:now)
        check(layers.activities.count==2 && layers.activities.allSatisfy{$0.status=="ready"} && layers.summary.status=="ready",
              "G22 after the upgrade, test 4's moments and day note are all still ready",
              "moments \(layers.activities.map{"\($0.subject):\($0.status)"}), day \(layers.summary.status)")
        // Activity recorded after the upgrade uses the new rule: a title that grows continues its moment.
        let later=Date().addingTimeInterval(1),laterDay=try DayScope.key(later,timezone:zone),seen=later.addingTimeInterval(60)
        for (id,at,title) in [("up-3",later,"Letter"),("up-4",later.addingTimeInterval(20),"Letter to Sam")] {
            _=try upgraded.ingest(Evidence(id:id,at:iso(at),kind:"window.changed",app:"TextEdit",bundle:"com.apple.TextEdit",title:title,synthetic:true),now:seen)
        }
        let fresh=try upgraded.dayLayers(day:laterDay,timezone:zone,now:seen)
        check(activity(fresh,containing:"up-3")?.actionIDs.contains("up-4")==true,"G22 new activity after the upgrade still continues a moment whose title grew")
    }

    /// G20: a correction changes only the notes that hold the corrected action.
    static func corrections() throws {
        let s=try store("corrections")
        try add(s,"alpha",dayStart,"Alpha plan")
        try add(s,"beta",dayStart.addingTimeInterval(3600),"Beta notes",app:"Notes",bundle:"com.apple.Notes")
        var layers=try s.dayLayers(day:day,timezone:zone,now:now)
        let a=activity(layers,containing:"alpha")!,b=activity(layers,containing:"beta")!
        try note(s,"activity",a.id);try note(s,"activity",b.id)
        layers=try s.dayLayers(day:day,timezone:zone,now:now)
        check(layers.activities.allSatisfy{$0.status=="ready"},"G20 fixture: both moments have notes")
        _=try s.correctAction(id:"alpha",text:"Planned the alpha launch",expectedRevision:try s.action("alpha",now:now)!.revision,now:now)
        layers=try s.dayLayers(day:day,timezone:zone,now:now)
        check(activity(layers,containing:"alpha")?.status=="pending","G20 the corrected moment's note goes stale")
        check(activity(layers,containing:"beta")?.status=="ready","G20 a correction keeps every other moment's note",
              "beta is \(activity(layers,containing:"beta")?.status ?? "missing")")
    }

    /// G21: a preference save keeps every note whose actions it didn't change; typing off still hides them all.
    static func preferences() throws {
        let s=try store("preferences")
        try add(s,"pa",dayStart,"Alpha plan")
        try add(s,"pb",dayStart.addingTimeInterval(3600),"Beta notes",app:"Notes",bundle:"com.apple.Notes")
        var layers=try s.dayLayers(day:day,timezone:zone,now:now)
        try note(s,"activity",activity(layers,containing:"pa")!.id);try note(s,"activity",activity(layers,containing:"pb")!.id);try note(s,"day")
        func save(_ apps:[String],typing:Bool=false) throws {_=try s.savePreferences(MemoryPreferences(blockedApps:apps,nativeTyping:typing),expectedRevision:try s.policy().revision)}
        try save(["com.example.unused"])
        layers=try s.dayLayers(day:day,timezone:zone,now:now)
        check(layers.activities.allSatisfy{$0.status=="ready"} && layers.summary.status=="ready","G21 blocking an app with no history keeps every note",
              "moments \(layers.activities.map(\.status)), day \(layers.summary.status)")
        try save(["com.apple.Notes"])
        layers=try s.dayLayers(day:day,timezone:zone,now:now)
        check(layers.activities.count==1 && activity(layers,containing:"pa")?.status=="ready" && layers.summary.status=="pending",
              "G21 blocking a used app hides that moment and changes the day; the other moment keeps its note")
        try save([])
        layers=try s.dayLayers(day:day,timezone:zone,now:now)
        check(layers.activities.count==2 && layers.activities.allSatisfy{$0.status=="ready"} && layers.summary.status=="ready","G21 undoing the block brings the notes back")
        try save([],typing:true);try save([],typing:false)
        layers=try s.dayLayers(day:day,timezone:zone,now:now)
        check(layers.activities.allSatisfy{$0.status=="pending"} && layers.summary.status=="pending","G21 turning typing off still hides every note (typing privacy)")
    }

    /// G63: regenerating a note keeps one version and no stale writer requests; committed requests keep no action text.
    /// G52: the count AI apps read is moments and days with a note, not stored versions.
    static func bounded() throws {
        let s=try store("bounded")
        for i in 0..<3 {try add(s,"bd-\(i)",dayStart.addingTimeInterval(Double(i*20)),"Quarterly report")}
        let m=try s.dayLayers(day:day,timezone:zone,now:now).activities[0]
        for _ in 0..<6 {try note(s,"activity",m.id)}
        let versions=Int(try s.rows("SELECT count(*) FROM generated_notes WHERE id=?",[m.id])[0][0])!
        let requests=Int(try s.rows("SELECT count(*) FROM note_requests")[0][0])!
        check(versions==1,"G63 six regenerations keep one note version","\(versions) versions")
        check(requests<=1,"G63 old writer requests are removed","\(requests) rows")
        let kept=try s.rows("SELECT json_array_length(json_extract(body,'$.request.actions')),json_array_length(json_extract(body,'$.actionIDs')) FROM note_requests WHERE state='committed'")
        check(kept.count==1 && kept[0]==["0","3"],"G63 a committed request keeps its action ids, not the actions' text","\(kept)")
        check(try s.dayLayers(day:day,timezone:zone,now:now).activities[0].status=="ready","G63 the moment's note is still ready")
        // An older version citing other actions (as test 4 stores hold) is kept, and is still one noted moment.
        let old=GeneratedNote(id:m.id,version:0,schemaVersion:1,generatedAt:iso(now.addingTimeInterval(-600)),inputRevision:"older",actionIDs:["gone"],
                              output:NoteWriterOutput(requestID:"older",title:"Older",bullets:[NoteBullet(text:"Older",actionIDs:["gone"],assertion:"interpretation")],generator:"fixture",generatorVersion:"1"),status:"generated_unverified")
        try s.exec("INSERT INTO generated_notes VALUES(?,?,?,?)",[m.id,"0","older",json(old)])
        let notes=try s.assistantStatus(now:now)["notes"] ?? ""
        check(notes.hasPrefix("DayDream has written 1 note "),"G52 AI apps are told how many moments and days have a note, not how many versions","\(notes)")
    }

    /// extra6: rows a policy hides are looked at once per policy, and "pending" reaches 0.
    static func hidden() throws {
        let s=try store("hidden")
        for i in 0..<30 {try add(s,"hid-\(i)",dayStart.addingTimeInterval(Double(i)),"Hidden \(i)",app:"Secret",bundle:"com.example.hidden")}
        for i in 0..<5 {try add(s,"vis-\(i)",dayStart.addingTimeInterval(Double(100+i)),"Visible \(i)")}
        _=try s.savePreferences(MemoryPreferences(blockedApps:["com.example.hidden"],nativeTyping:false),expectedRevision:try s.policy().revision)
        let written=try s.writePending(now:now)
        check(written==5,"extra6 fixture: the visible rows are summarized","\(written)")
        let pending=try s.status()["pending"] ?? "?"
        check(pending=="0","extra6 rows the policy hides are no longer counted as pending","pending \(pending)")
        _=try s.savePreferences(MemoryPreferences(blockedApps:[],nativeTyping:false),expectedRevision:try s.policy().revision)
        check(try s.writePending(now:now)==30 && s.status()["pending"]=="0","extra6 unhiding them summarizes them after all")
    }

    /// G25/G73 (local): a moment over the writer's limit is never queued, and a queued one is dropped. claude/ready-1002
    /// (owner): the limit is the segment bound (2,000 actions); a 401-action moment is now queued and written in segments.
    static func capacity() async throws {
        let s=try store("capacity")
        for i in 0..<(CanonicalGrounding.maxChunkedActions+1) {try add(s,"cap-\(i)",dayStart.addingTimeInterval(Double(i)*0.5),"Big report")}
        try add(s,"small",dayStart.addingTimeInterval(3600),"Small note",app:"Notes",bundle:"com.apple.Notes")
        let layers=try s.dayLayers(day:day,timezone:zone,now:now)
        let big=activity(layers,containing:"cap-0")!,small=activity(layers,containing:"small")!
        let source=WriterQueueSource(store:s)
        var found:[ScheduledWriterTarget]=[]
        for _ in 0..<3 {found+=try await source.discover(now:now,timezone:zone)}
        check(!found.contains{$0.activityID==big.id},"G73 a moment over the 2,000-action segment bound is never queued for the writer")
        check(found.contains{$0.activityID==small.id},"G73 other moments are still queued")
        check(!found.contains{$0.kind=="day" && $0.day==day},"G73 a day over its bound is never queued either")
        let queued=ScheduledWriterTarget(target:WriterTarget(kind:.activity,day:day,timezone:zone,activityID:big.id),inputRevision:big.inputRevision,policyRevision:try s.policy().revision,lastActivity:now.addingTimeInterval(-3600))
        let obsolete=try await source.obsoleteKeys([queued])
        check(obsolete==[queued.key],"G73 an already queued over-limit moment is dropped from the queue")
    }

    /// G26: a capture landing while a note request is prepared no longer fails it.
    static func race() throws {
        let s=try store("race")
        for i in 0..<600 {try add(s,"race-\(i)",dayStart.addingTimeInterval(Double(i*2)),"Race \(i/100)")}
        let target=try s.dayLayers(day:day,timezone:zone,now:now).activities[0]
        let stop=DispatchSemaphore(value:0),done=DispatchSemaphore(value:0)
        // One store, as in the app: capture and the writer share it.
        DispatchQueue.global().async {
            var n=0
            while stop.wait(timeout:.now()+0.03) == .timedOut {
                try? add(s,"live-\(n)",dayStart.addingTimeInterval(7200+Double(n)),"Live \(n)",app:"Notes",bundle:"com.apple.Notes");n+=1
            }
            done.signal()
        }
        var raced=0,other=0
        for _ in 0..<10 {
            do {let request=try s.prepareNote(kind:"activity",day:day,timezone:zone,activityID:target.id,now:now);try s.cancelNote(request.id)}
            catch MemError.invalid(let message) where message.contains("changed before preparation") {raced+=1}
            catch {other+=1}
        }
        stop.signal();done.wait()
        check(raced==0 && other==0,"G26 note requests survive captures landing while they are prepared","\(raced) of 10 failed with the race, \(other) otherwise")
    }

    /// G15/G18/G19: a large day is read once and kept; the note writer never holds the store for a whole-day read.
    static func cost() async throws {
        let s=try store("cost")
        for i in 0..<1500 {try add(s,"c-\(i)",dayStart.addingTimeInterval(Double(i*2)),"Document \(i/60)")}
        try add(s,"elsewhere",dayStart.addingTimeInterval(-86400),"Other day")
        var pages=0
        let paging=try seconds {
            var page=try s.dayLayers(day:day,timezone:zone,limit:200,now:now);pages=1
            while let next=page.actions.next {page=try s.dayLayers(day:day,timezone:zone,after:next,limit:200,now:now);pages+=1}
        }
        check(pages>=8 && paging<8,"G15 all \(pages) pages of a 1500-action day in \(String(format:"%.2f",paging)) s (under 8 s)")
        let warm=try seconds {_=try s.dayLayers(day:day,timezone:zone,now:now)}
        check(warm<0.5,"G15 reading the unchanged day again takes \(String(format:"%.3f",warm)) s (under 0.5 s)")
        // G19: what one writer poll reads (discover, the obsolete sweep, the pre-run check) on an unchanged day.
        let source=WriterQueueSource(store:s)
        let first=try await source.discover(now:now,timezone:zone)
        var polls=0.0
        for _ in 0..<3 {
            let start=DispatchTime.now().uptimeNanoseconds
            let found=try await source.discover(now:now,timezone:zone)
            _=try await source.obsoleteKeys(Array(first.prefix(4)))
            if let item=found.first ?? first.first {_=try await source.isCurrent(item)}
            polls+=Double(DispatchTime.now().uptimeNanoseconds-start)/1e9
        }
        check(polls/3<1.0,"G19 a writer poll over an unchanged 1500-action day takes \(String(format:"%.2f",polls/3)) s (under 1 s)")
        // G18: while the writer reads a note request's pages and validates it, capture can still write.
        let request=try s.prepareNote(kind:"day",day:day,timezone:zone,now:now)
        try s.delete("elsewhere")   // another day's deletion: the day must be read again
        let finished=DispatchSemaphore(value:0)
        // One store, as in the app: the writer's reads and capture's writes share its lock.
        let reader=s
        DispatchQueue.global().async {
            _=try? reader.noteActions(requestID:request.id,after:100,now:now)
            _=try? reader.validatePreparedNote(request.id,revisions:[:],now:now)
            finished.signal()
        }
        var worst=0.0,n=0
        while finished.wait(timeout:.now()+0.02) == .timedOut {
            let took=try seconds {try add(s,"during-\(n)",dayStart.addingTimeInterval(-2*86400+Double(n)),"Capture \(n)")}
            worst=max(worst,took);n+=1
        }
        check(worst<0.75,"G18 capture waits at most \(String(format:"%.2f",worst)) s while the writer pages and validates a 1500-action day (under 0.75 s)","\(n) writes")
    }
}
