import Foundation
import WriterBackend
#if canImport(MemoryCore)
import MemoryCore
actor ActualCore {
    let store:MemoryStore,root:URL
    init(count:Int=2)throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("writer-adapter-store-"+UUID().uuidString)
        store=try MemoryStore(home:root,writable:true,automaticallySyncSearch:false)
        for index in 0..<count {_=try store.ingest(Evidence(id:"actual-\(index)",at:iso(Date()),kind:"mouse.click",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Research",synthetic:true))}
    }
    func wire<A:Encodable,B:Decodable>(_ a:A,_ type:B.Type)throws->B {try JSONDecoder().decode(type,from:JSONEncoder().encode(a))}
    func prepare(_ target:WriterTarget)throws->CanonicalNoteRequest {try wire(store.prepareNote(kind:target.kind.rawValue,day:target.day,timezone:target.timezone,activityID:target.activityID),CanonicalNoteRequest.self)}
    func page(_ id:String,_ offset:Int)throws->WriterActionPage {try wire(store.noteActions(requestID:id,after:offset),WriterActionPage.self)}
    func commit(_ output:CanonicalNoteOutput)throws->WriterCommitReceipt {try wire(store.commitNote(wire(output,NoteWriterOutput.self)),WriterCommitReceipt.self)}
    func cancel(_ id:String)throws {try store.cancelNote(id)}
    func permitted(_ request:CanonicalNoteRequest,_ actions:[NoteAction])->Bool {
        do {return try store.policy().revision==request.policyRevision && actions.allSatisfy {try store.action($0.id)?.revision==$0.revision}} catch {return false}
    }
    func cleanup()throws {try FileManager.default.removeItem(at:root)}
    func layers()throws->ActionDay {try store.dayLayers(day:DayScope.key(Date(),timezone:"America/New_York"),timezone:"America/New_York")}
    nonisolated func port()->CoreWriterPort {
        CoreWriterPort(prepare:{try await self.prepare($0)},page:{try await self.page($0,$1)},commit:{try await self.commit($0)},cancel:{try await self.cancel($0)},permitted:{await self.permitted($0,$1)})
    }
}
#endif

actor FakeCore {
    var prepares=0,pages=0,commits=0,cancels=0
    var allowed=true,targetID="day-id"
    let count:Int
    let badPage:Bool,windows:Bool,apps:Bool
    /// `windows`: one window per action (distinct titles); `apps`: each in its own app, so per-app folding cannot shrink the view.
    init(_ count:Int=2,badPage:Bool=false,windows:Bool=false,apps:Bool=false) {self.count=count;self.badPage=badPage;self.windows=windows;self.apps=apps}
    func action(_ index:Int)->NoteAction {
        windows ? NoteAction(id:"a\(index)",at:"2026-09-11T12:00:00Z",kind:"window.changed",app:apps ? "Tool\(index)":"TextEdit",site:"",title:"Draft \(index)",description:"Observed Draft \(index); reading is not established.",state:"observed",revision:"revision-\(index)")
                : NoteAction(id:"a\(index)",at:"2026-09-11T12:00:00Z",kind:"mouse.click",app:"TextEdit",site:"",title:"Research",description:"Recorded a mouse click in TextEdit.",state:"observed",revision:"revision-\(index)")
    }
    func prepare(_ target:WriterTarget)throws->CanonicalNoteRequest {
        prepares+=1;targetID=target.activityID ?? "day-id"
        let actions=(0..<min(count,100)).map(action)
        let encoded=try JSONSerialization.data(withJSONObject:["id":"request","schemaVersion":1,"targetKind":target.kind.rawValue,"targetID":target.activityID ?? "day-id","day":target.day,"timezone":target.timezone,"inputRevision":"inputs-v1","policyRevision":"policy-v1","expiresAt":"2099-01-01T00:00:00Z","actions":JSONSerialization.jsonObject(with:JSONEncoder().encode(actions)),"actionCount":count,"next":count>100 ? 100 : NSNull()])
        return try JSONDecoder().decode(CanonicalNoteRequest.self,from:encoded)
    }
    func page(_ id:String,_ offset:Int)->WriterActionPage {
        pages+=1
        if badPage {return WriterActionPage(actions:[],next:offset,actionCount:count)}
        let end=min(offset+100,count)
        return WriterActionPage(actions:(offset..<end).map(action),next:end<count ? end:nil,actionCount:count)
    }
    func commit(_ output:CanonicalNoteOutput)throws->WriterCommitReceipt {
        guard allowed else {throw WriterFailure.denied};commits+=1
        return WriterCommitReceipt(id:targetID,version:1,inputRevision:"inputs-v1",status:"generated_unverified",output:output)
    }
    func cancel(_ id:String) {cancels+=1}
    func deny() {allowed=false}
    func totals()->[Int] {[prepares,pages,commits,cancels]}
    nonisolated func port()->CoreWriterPort {
        CoreWriterPort(prepare:{try await self.prepare($0)},page:{await self.page($0,$1)},commit:{try await self.commit($0)},cancel:{await self.cancel($0)},permitted:{_,_ in await self.allowed})
    }
}
actor GenerationCounter {
    var calls=0
    func hit() {calls+=1}
}
@main struct AdapterChecks {
    static var passed=0
    static let target=WriterTarget(kind:.day,day:"2026-09-11",timezone:"America/New_York")
    static let settled=Date().addingTimeInterval(-3)
    static func check(_ yes:Bool,_ name:String)throws {guard yes else {throw NSError(domain:name,code:1)};passed+=1;print("PASS \(name)")}
    static func rejects(_ name:String,_ block:()async throws->Void)async throws {
        do {try await block()} catch {passed+=1;print("PASS \(name)");return};throw NSError(domain:name,code:2)
    }
    /// A prompt5 answer: one bullet citing every item of the ITEMS view, checked by validator7.
    static func answer(_ view:ModelView,_ text:String="Clicked through Research in TextEdit.")->String {
        #"{"title":"Research in TextEdit","bullets":[{"ids":["#+view.items.map {"\"\($0.alias)\""}.joined(separator:",")+#"],"text":"\#(text)"}]}"#
    }
    static func generate(_ request:CanonicalNoteRequest,_ actions:[NoteAction])throws->CanonicalNoteOutput {
        let view=try ModelView(request:request,actions:actions)
        return try CanonicalGrounding.validate(answer(view),request:request,view:view,provider:CanonicalLocalWriter.provider)
    }
    static func main()async throws {
        let source=FakeCore(),adapter=CoreWriterAdapter(core:source.port(),generate:{try generate($0,$1)})
        if case .committed(let result)=try await adapter.process(target,lastActivity:settled) {try check(result.version==1,"successful output goes through core commit")} else {throw WriterFailure.invalidOutput}
        try check(await source.totals()==[1,0,1,0],"only explicit target prepared; no history enumeration")
        try await rejects("unsettled activity does not prepare") {_=try await adapter.process(target,lastActivity:Date())}
        try check(await source.totals()==[1,0,1,0],"settle guard leaves core untouched")
        let unavailable=FakeCore(),failed=CoreWriterAdapter(core:unavailable.port(),generate:{_,_ in throw WriterFailure.unavailable})
        if case .pending(let result)=try await failed.process(target,lastActivity:settled) {
            try check(result.reason == .providerUnavailable && result.actionIDs.count==2 && result.fallback.count==2,"failure returns separate cited deterministic fallback")
        } else {throw WriterFailure.invalidOutput}
        try check(await unavailable.totals()==[1,0,0,0],"provider failure never fake-commits or cancels pending work")
        // claude/ready-1002 (owner): a moment over 400 actions is written in segments; over 2,000 it stays capacity.
        let large=FakeCore(2001),bounded=CoreWriterAdapter(core:large.port(),generate:{_,_ in throw WriterFailure.invalidOutput})
        if case .pending(let result)=try await bounded.process(target,lastActivity:settled) {
            try check(result.reason == .capacity && result.actionIDs.count==2001 && Set(result.actionIDs).count==2001 && result.fallback.count==2001,"over-capacity scope (2001 actions) retains all distinct action IDs")
        } else {throw WriterFailure.invalidOutput}
        try check(await large.totals()==[1,20,0,0],"all pages fetched, generation and commit skipped over capacity")
        let segmented=FakeCore(401),segCalls=GenerationCounter()
        let segRunner=CoreWriterAdapter(core:segmented.port(),generate:{_,_ in await segCalls.hit();throw WriterFailure.unavailable})
        if case .pending(let note)=try await segRunner.process(WriterTarget(kind:.activity,day:target.day,timezone:target.timezone,activityID:"activity-id"),lastActivity:settled) {
            let calls=await segCalls.calls
            try check(note.reason != .capacity && calls==1,"a 401-action moment is no longer capacity: it goes to the writer, which writes it in segments (reason \(note.reason) calls \(calls))")
        } else {throw WriterFailure.invalidOutput}
        for kind in [WriterTarget.Kind.activity,.day] {
            let scope=WriterTarget(kind:kind,day:target.day,timezone:target.timezone,activityID:kind == .activity ? "activity-id":nil)
            let overs=kind == .activity ? [(FakeCore(2001),"2001 actions")] : [(FakeCore(401),"401 actions"),(FakeCore(41,windows:true,apps:true),"41 items in 41 apps")]
            for (over,why) in overs {
                let counter=GenerationCounter()
                let runner=CoreWriterAdapter(core:over.port(),generate:{_,_ in await counter.hit();throw WriterFailure.unavailable})
                if case .pending(let note)=try await runner.process(scope,lastActivity:settled) {
                    try check(note.reason == .capacity && Set(note.actionIDs).count==over.count && note.fallback.count==over.count,"\(kind.rawValue) over capacity (\(why)) clearly pending with every action ID")
                } else {throw WriterFailure.invalidOutput}
                try check(await counter.calls==0,"\(kind.rawValue) over capacity (\(why)) never invokes generation")
                let totals=await over.totals()
                try check(totals[0]==1 && totals[2]==0 && totals[3]==0,"\(kind.rawValue) over capacity (\(why)) no commit or cancellation")
            }
            // 41 windows of one app used to be over capacity; the view now folds them into one item.
            let folded=FakeCore(41,windows:true),foldCalls=GenerationCounter()
            let folding=CoreWriterAdapter(core:folded.port(),generate:{request,actions in
                await foldCalls.hit()
                let view=try ModelView(request:request,actions:actions)
                return try CanonicalGrounding.validate(answer(view,"Clicked through several drafts in TextEdit."),request:request,view:view,provider:CanonicalLocalWriter.provider)
            })
            if case .committed(let receipt)=try await folding.process(scope,lastActivity:settled) {
                let foldCount=await foldCalls.calls
                try check(receipt.output.bullets.count==1 && receipt.output.bullets[0].actionIDs.count==41 && foldCount==1,"\(kind.rawValue) 41 windows of one app fold into one item, one call and one note")
            } else {throw WriterFailure.invalidOutput}
            // What used to be over capacity (21 actions, then 205) is now one call and one note.
            let whole=FakeCore(205),calls=GenerationCounter()
            let one=CoreWriterAdapter(core:whole.port(),generate:{request,actions in await calls.hit();return try generate(request,actions)})
            if case .committed(let receipt)=try await one.process(scope,lastActivity:settled) {
                try check(receipt.output.bullets.count==1 && receipt.output.bullets[0].actionIDs.count==205 && receipt.output.generatorVersion==CanonicalGrounding.localVersion,"\(kind.rawValue) 205 actions fold into one item and one grounded bullet")
            } else {throw WriterFailure.invalidOutput}
            try check(await calls.calls==1,"\(kind.rawValue) whole scope is one generation call")
        }
        // Invalid output after the repair turn is pending (greedy decoding would replay it), never committed.
        let invalid=FakeCore(),rejected=CoreWriterAdapter(core:invalid.port(),generate:{_,_ in throw WriterRejection(code:"send",reason:"x")})
        if case .pending(let result)=try await rejected.process(target,lastActivity:settled) {
            try check(result.reason == .invalidOutput && result.actionIDs.count==2,"a rejected answer leaves the note pending as invalidOutput")
        } else {throw WriterFailure.invalidOutput}
        let forged=FakeCore(),forger=CoreWriterAdapter(core:forged.port(),generate:{request,actions in
            var output=try generate(request,actions);output.bullets[0].assertion="sent";return output
        })
        if case .pending(let result)=try await forger.process(target,lastActivity:settled) {
            try check(result.reason == .invalidOutput,"a relabelled note fails the adapter's check() and is not committed")
        } else {throw WriterFailure.invalidOutput}
        let overclaim=FakeCore(),claimer=CoreWriterAdapter(core:overclaim.port(),generate:{request,actions in
            var output=try generate(request,actions);output.bullets[0].text="Sent the research to the team.";return output
        })
        if case .pending(let result)=try await claimer.process(target,lastActivity:settled) {
            try check(result.reason == .invalidOutput,"an invented send in a stored note fails check() before commit")
        } else {throw WriterFailure.invalidOutput}
        try check(await [invalid.totals(),forged.totals(),overclaim.totals()].allSatisfy {$0[2]==0 && $0[3]==0},"invalid output never commits or cancels")
        let malformed=FakeCore(101,badPage:true)
        try await rejects("empty or stalled page fails closed") {_=try await CoreWriterAdapter(core:malformed.port(),generate:{try generate($0,$1)}).process(target,lastActivity:settled)}
        let changed=FakeCore()
        try await rejects("policy change during generation prevents commit and fallback disclosure") {
            _=try await CoreWriterAdapter(core:changed.port(),generate:{request,actions in
                await changed.deny();return try generate(request,actions)
            }).process(target,lastActivity:settled)
        }
        try check(await changed.totals()==[1,0,0,0],"changed policy never commits")
        let slow=FakeCore(),single=CoreWriterAdapter(core:slow.port(),generate:{request,actions in
            try await Task.sleep(nanoseconds:2_000_000_000);return try generate(request,actions)
        })
        let running=Task {try await single.process(target,lastActivity:settled)}
        try await Task.sleep(nanoseconds:50_000_000)
        try await rejects("single flight rejects concurrent generation") {_=try await single.process(target,lastActivity:settled)}
        running.cancel()
        try await rejects("cancellation propagates") {_=try await running.value}
        try check(await slow.totals()==[1,0,0,1],"cancellation cancels core request without commit")
        #if canImport(MemoryCore)
        let actual=try ActualCore()
        do {
            let today=try DayScope.key(Date(),timezone:"America/New_York")
            let liveTarget=WriterTarget(kind:.day,day:today,timezone:"America/New_York")
            let integrated=CoreWriterAdapter(core:actual.port(),generate:{try generate($0,$1)})
            if case .committed(let receipt)=try await integrated.process(liveTarget,lastActivity:settled) {
                try check(receipt.status=="generated_unverified" && receipt.output.bullets.count==1 && receipt.output.bullets[0].actionIDs.count==2,"adapter invokes actual core prepare and validated commit")
            } else {throw WriterFailure.invalidOutput}
            try await actual.cleanup()
        } catch {try? await actual.cleanup();throw error}
        let actualLarge=try ActualCore(count:401)
        do {
            let before=try await actualLarge.layers()
            // claude/ready-1002: a 401-action moment is written in segments; a day that size is still capacity.
            for kind in [WriterTarget.Kind.day] {
                let scope=WriterTarget(kind:kind,day:before.summary.day,timezone:before.summary.timezone,activityID:kind == .activity ? before.activities.first!.id:nil)
                let counter=GenerationCounter()
                let runner=CoreWriterAdapter(core:actualLarge.port(),generate:{_,_ in await counter.hit();throw WriterFailure.unavailable})
                if case .pending(let note)=try await runner.process(scope,lastActivity:settled) {
                    // dayLayers pages its action list; the activity carries every ID.
                    try check(note.reason == .capacity && note.actionIDs.count==401 && Set(note.actionIDs)==Set(before.activities.flatMap(\.actionIDs)),"actual core \(kind.rawValue) over capacity (401 actions) retains all IDs pending")
                } else {throw WriterFailure.invalidOutput}
                let after=try await actualLarge.layers()
                try check(await counter.calls==0 && after.summary.generated==nil && after.activities.allSatisfy{$0.generated==nil},"actual core \(kind.rawValue) capacity never generates or publishes")
            }
            try await actualLarge.cleanup()
        } catch {try? await actualLarge.cleanup();throw error}
        #endif
        print("Adapter checks: \(passed) passed. Synthetic only; no inference, cloud or capture.")
    }
}
