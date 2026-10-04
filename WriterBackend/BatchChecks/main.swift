import Foundation
import WriterBackend

// Whole-scope generation (prompt5/validator7): one model call per moment or day, up to 400 actions and 40 items,
// one atomic commit, every action ID cited. Formerly the 20-action batch checks; the batch path is gone.
actor Source {
    let count:Int,mixed:Bool
    var commits=0,cancels=0,calls=0
    init(_ count:Int,mixed:Bool=false){self.count=count;self.mixed=mixed}
    /// A Pages window with clicks; `mixed` adds a typed draft every twentieth action.
    /// fix/sx-all: one action every 40 seconds, so the window is in use long enough for "Worked on" (fix/notes-quality).
    static func at(_ n:Int)->String {let f=ISO8601DateFormatter();return f.string(from:Date(timeIntervalSince1970:1_789_128_000+Double(n)*40))}
    func actions(_ range:Range<Int>)->[NoteAction] {range.map {n in
        if n==0 {return NoteAction(id:"a0",at:Self.at(0),kind:"window.changed",app:"com.apple.iWork.Pages",site:"",title:"Plan",description:"Observed Plan in Pages; reading is not established.",state:"observed",revision:"r")}
        if mixed && n%20==5 {return NoteAction(id:"a\(n)",at:Self.at(n),kind:"keyboard.text_input",app:"com.apple.iWork.Pages",site:"",title:"Launch steps",description:"Typed a draft in Pages. step \(n/20)",state:"draft",revision:"r")}
        return NoteAction(id:"a\(n)",at:Self.at(n),kind:"mouse.click",app:"com.apple.iWork.Pages",site:"",title:"Plan",description:"Recorded a mouse click in Pages.",state:"observed",revision:"r")
    }}
    func prepare(_ t:WriterTarget)throws->CanonicalNoteRequest {
        try JSONDecoder().decode(CanonicalNoteRequest.self,from:JSONSerialization.data(withJSONObject:["id":"r","schemaVersion":1,"targetKind":t.kind.rawValue,"targetID":t.activityID ?? "day","day":t.day,"timezone":t.timezone,"inputRevision":"v","policyRevision":"p","expiresAt":"2099-01-01T00:00:00Z","actions":JSONSerialization.jsonObject(with:JSONEncoder().encode(actions(0..<min(100,count)))),"actionCount":count,"next":count>100 ? 100:NSNull()]))
    }
    func page(_ offset:Int)->WriterActionPage {let end=min(offset+100,count);return WriterActionPage(actions:actions(offset..<end),next:end<count ? end:nil,actionCount:count)}
    func commit(_ o:CanonicalNoteOutput)->WriterCommitReceipt {commits+=1;return WriterCommitReceipt(id:"day",version:1,inputRevision:"v",status:"generated_unverified",output:o)}
    func cancel(){cancels+=1}
    func hit(){calls+=1}
    func totals()->[Int]{[calls,commits,cancels]}
    nonisolated func port()->CoreWriterPort {CoreWriterPort(prepare:{try await self.prepare($0)},page:{_,offset in await self.page(offset)},commit:{await self.commit($0)},cancel:{_ in await self.cancel()},permitted:{r,a in r.actionCount==a.count})}
}
@main struct BatchChecks {
    static let target=WriterTarget(kind:.day,day:"2026-09-11",timezone:"UTC")
    /// A prompt4 answer from the ITEMS view: the typed drafts in one bullet, the window in another (fix/sx-all: in the
    /// owner's words, which fix/notes-quality's validator requires; "Had ... open" is filler).
    static func generate(_ r:CanonicalNoteRequest,_ a:[NoteAction])throws->CanonicalNoteOutput {
        let view=try ModelView(request:r,actions:a)
        let typed=view.items.filter {$0.kind == .typed}.map {"\"\($0.alias)\""},window=view.items.filter {$0.kind != .typed}.map {"\"\($0.alias)\""}
        // fix/notes-quality: with typed content the view leaves the window out (code covers it), so its bullet goes too.
        var bullets=window.isEmpty ? [] : [#"{"ids":[\#(window.joined(separator:","))],"text":"Worked on Plan in Pages."}"#]
        if !typed.isEmpty {bullets.append(#"{"ids":[\#(typed.joined(separator:","))],"text":"Drafted Launch steps in Pages."}"#)}
        return try CanonicalGrounding.validate(#"{"title":"Plan in Pages","bullets":["#+bullets.joined(separator:",")+"]}",request:r,view:view,provider:CanonicalLocalWriter.provider)
    }
    static func check(_ yes:Bool,_ text:String)throws{guard yes else{throw NSError(domain:text,code:1)};print("PASS \(text)")}
    static func run(_ source:Source,mode:String="normal")async throws->CoreWriterResult {
        let adapter=CoreWriterAdapter(core:source.port(),generate:{r,a in
            await source.hit()
            if mode=="fail" {throw WriterFailure.unavailable}
            if mode=="cancel" {try await Task.sleep(nanoseconds:5_000_000_000)}
            var output=try generate(r,a)
            if mode=="malformed" {output.bullets[0].actionIDs.removeLast()}
            if mode=="relabel" {output.bullets[0].assertion="sent"}
            return output
        })
        return try await adapter.process(target,lastActivity:Date().addingTimeInterval(-3))
    }
    static func main()async throws {
        for (n,mixed) in [(21,false),(100,false),(205,true),(400,true)] {
            let source=Source(n,mixed:mixed)
            if case .committed(let receipt)=try await run(source) {
                let ids=receipt.output.bullets.flatMap(\.actionIDs)
                try check(ids.count==n && Set(ids).count==n,"\(n) actions: complete ID coverage, each cited once")
                // fix/notes-quality: a moment with typed content is one typed bullet; the validator folds the window's
                // clicks into it, and the label is derived from every cited state (window actions keep it "observed").
                try check(receipt.output.bullets.count==1 && receipt.output.generatorVersion==CanonicalGrounding.localVersion,"\(n) actions: one grouped bullet, \(CanonicalGrounding.localVersion)")
                try check(receipt.output.bullets[0].text==(mixed ? "Drafted Launch steps in Pages.":"Worked on Plan in Pages.") && receipt.output.bullets[0].assertion=="observed","\(n) \(mixed ? "mixed":"window"): the model's words kept, label derived from action states")
            } else {throw WriterFailure.invalidOutput}
            try check(await source.totals()==[1,1,0],"\(n) actions: one model call, one atomic commit")
        }
        for (n,mode,reason) in [(401,"normal",PendingWriterNote.Reason.capacity),(40,"fail",.providerUnavailable),(40,"malformed",.invalidOutput),(40,"relabel",.invalidOutput)] {
            let source=Source(n,mixed:true)
            if case .pending(let pending)=try await run(source,mode:mode) {
                try check(pending.actionIDs.count==n && pending.fallback.count==n && pending.reason==reason,"\(n) \(mode): pending (\(reason.rawValue)) with every action")
                try check(await source.commits==0,"\(mode): no partial commit")
            } else {throw WriterFailure.invalidOutput}
        }
        let source=Source(40),task=Task{try await run(source,mode:"cancel")}
        try await Task.sleep(nanoseconds:50_000_000);task.cancel()
        do {_=try await task.value;throw WriterFailure.invalidOutput} catch is CancellationError {}
        try check(await source.totals()==[1,0,1],"cancellation cancels prepared request without commit")
    }
}
