import Foundation
import MemoryCore
import WriterBackend

actor Fixture {
    let root:URL,store:MemoryStore,binding:CoreWriterBinding
    let now=Date(),zone="UTC"
    var mutations=0
    init(_ count:Int)throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("writer-binding-"+UUID().uuidString)
        store=try MemoryStore(home:root,writable:true,automaticallySyncSearch:false)
        binding=CoreWriterBinding(store:store)
        for n in 0..<count {
            _=try store.ingest(Evidence(id:"event-\(n)",at:iso(now.addingTimeInterval(Double(n)/1000)),kind:"mouse.click",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Research",synthetic:true))
        }
    }
    func target(_ kind:WriterTarget.Kind)throws->WriterTarget {
        let day=try DayScope.key(now,timezone:zone),layers=try store.dayLayers(day:day,timezone:zone)
        return WriterTarget(kind:kind,day:day,timezone:zone,activityID:kind == .activity ? layers.activities.first!.id:nil)
    }
    func mutate(_ mode:String)throws {
        mutations+=1;guard mutations==1 else{return}
        if mode=="delete" {try store.delete("event-0")}
        if mode=="revision" {_=try store.ingest(Evidence(id:"event-0",at:iso(now),kind:"mouse.click",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Changed",synthetic:true))}
    }
    func correct()throws {_=try store.correctAction(id:"event-0",text:"User clarified the observed event.",expectedRevision:store.action("event-0")!.revision)}
    func state(_ kind:WriterTarget.Kind)throws->(Int,GeneratedNote?) {
        let layers=try store.dayLayers(day:DayScope.key(now,timezone:zone),timezone:zone)
        return (layers.summary.actionCount,kind == .day ? layers.summary.generated:layers.activities.first?.generated)
    }
    func checkExpiry(_ output:CanonicalNoteOutput)throws->Bool {
        let wire=try JSONDecoder().decode(NoteWriterOutput.self,from:JSONEncoder().encode(output))
        do {_=try store.commitNote(wire,now:Date().addingTimeInterval(301));return false} catch{return true}
    }
    func cleanup()throws {try FileManager.default.removeItem(at:root)}
}
actor FakeInference:LocalInference {
    let fixture:Fixture,mode:String
    var calls=0
    init(_ fixture:Fixture,mode:String="normal"){self.fixture=fixture;self.mode=mode}
    func load(){}
    func unload(){}
    /// Answers the ITEMS view the way prompt4 asks (item ids and text only): the user's note gets its own attributed
    /// bullet, everything else one bullet. It never sees action IDs, states or labels.
    func generate(instruction:String,evidence:String,maxTokens:Int)async throws->Data {
        calls+=1
        if mode=="fail" {throw WriterFailure.unavailable}
        try await fixture.mutate(mode)
        if mode=="prose" {return Data("Here is a summary of your research.".utf8)}
        var notes:[String]=[],other:[String]=[]
        for line in evidence.split(separator:"\n") where line.range(of:#"^i\d+\. "#,options:.regularExpression) != nil {
            let alias="\""+line.prefix {$0 != "."}+"\""
            if line.contains("YOUR NOTE") {notes.append(alias)} else {other.append(alias)}
        }
        var bullets=notes.map {#"{"ids":[\#($0)],"text":"You noted a clarification about the research."}"#}
        if !other.isEmpty {bullets.append(#"{"ids":[\#(other.joined(separator:","))],"text":"Had Research open in TextEdit, with clicks."}"#)}
        return Data((#"{"title":"Research in TextEdit","bullets":["#+bullets.joined(separator:",")+"]}").utf8)
    }
}
@main struct BindingChecks {
    static var passed=0
    static func check(_ yes:Bool,_ name:String)throws {guard yes else {throw NSError(domain:name,code:1)};passed+=1;print("PASS \(name)")}
    static func run(_ f:Fixture,_ kind:WriterTarget.Kind,mode:String="normal")async throws->CoreWriterResult {
        let binding=f.binding,port=binding.port(),provider=CanonicalLocalWriter(runtime:FakeInference(f,mode:mode),policy:port.permitted)
        let adapter=CoreWriterAdapter(core:port,generate:{try await provider.generate($0,completeActions:$1)})
        return try await adapter.process(f.target(kind),lastActivity:Date().addingTimeInterval(-3))
    }
    static func main()async throws {
        for kind in [WriterTarget.Kind.activity,.day] {for count in [21,100,250] {
            let f=try Fixture(count)
            if case .committed(let receipt)=try await run(f,kind) {
                try check(receipt.status=="generated_unverified" && Set(receipt.output.bullets.flatMap(\.actionIDs))==Set((0..<count).map{"event-\($0)"}),"real binding \(kind.rawValue) \(count) commit complete IDs")
                let state=try await f.state(kind)
                try check(state.0==count && state.1?.actionIDs.count==count && state.1?.status=="generated_unverified","real core \(kind.rawValue) \(count) persisted unverified note and all actions")
                try check(receipt.output.bullets.count==1 && receipt.output.generatorVersion==CanonicalGrounding.localVersion,"real binding \(kind.rawValue) \(count) clicks fold into one grounded bullet (prompt5-validator7)")
            } else {throw WriterFailure.invalidOutput}
            try await f.cleanup()
        }}
        let corrected=try Fixture(21);try await corrected.correct()
        if case .committed(let receipt)=try await run(corrected,.day) {
            let bullet=receipt.output.bullets.first{$0.actionIDs.contains("event-0")}
            try check(bullet?.assertion=="reported" && bullet?.actionIDs==["event-0"],"binding correction reaches provider as the user's note (reported, its own bullet), not observation")
        } else {throw WriterFailure.invalidOutput}
        try await corrected.cleanup()
        for mode in ["delete","revision"] {
            let f=try Fixture(21)
            do {_=try await run(f,.day,mode:mode);throw NSError(domain:"mutation accepted",code:2)} catch WriterFailure.denied {try check(true,"\(mode) during inference denied by real binding")}
            try check(try await f.state(.day).1==nil,"\(mode) never commits stale note")
            try await f.cleanup()
        }
        let failing=try Fixture(40)
        if case .pending(let note)=try await run(failing,.day,mode:"fail") {try check(note.actionIDs.count==40 && note.reason == .providerUnavailable,"provider failure retains all 40 actions pending")}else{throw WriterFailure.invalidOutput}
        try check(try await failing.state(.day).1==nil,"failed provider never commits")
        try await failing.cleanup()
        let prose=try Fixture(21)
        if case .pending(let note)=try await run(prose,.day,mode:"prose") {try check(note.actionIDs.count==21 && note.reason == .invalidOutput,"an answer that is not JSON (after the repair turn) stays pending as invalidOutput")}else{throw WriterFailure.invalidOutput}
        try check(try await prose.state(.day).1==nil,"invalid output never commits")
        try await prose.cleanup()
        // Core expiry uses its public injected clock; no five-minute sleep or private SQL.
        let expired=try Fixture(21),binding=expired.binding,port=binding.port()
        let request=try await port.prepare(expired.target(.day)),runtime=FakeInference(expired),provider=CanonicalLocalWriter(runtime:runtime,policy:port.permitted)
        let output=try await provider.generate(request,completeActions:request.actions)
        try check(await runtime.calls==1,"a valid first answer needs no repair turn")
        try check(try await expired.checkExpiry(output),"actual core rejects commit after expiry with injected clock")
        try check(try await expired.state(.day).1==nil,"expiry leaves canonical actions without generated note")
        try await expired.cleanup()
        print("BindingChecks: \(passed) passed. Actual CoreWriterBinding and MemoryStore; fake inference, no real model/cloud/private data.")
    }
}
