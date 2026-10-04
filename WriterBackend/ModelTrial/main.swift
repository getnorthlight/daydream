import Foundation
import WriterBackend
/// Counts model calls per note: 1 means the first answer passed, 2 means the repair turn ran.
actor CountingRuntime: LocalInference {
    let base:LlamaInference;var calls=0
    init(_ base:LlamaInference) {self.base=base}
    func load() async throws {try await base.load()}
    func unload() async {await base.unload()}
    func generate(instruction:String,evidence:String,maxTokens:Int) async throws -> Data {calls+=1;return try await base.generate(instruction:instruction,evidence:evidence,maxTokens:maxTokens)}
    func generate(instruction:String,evidence:String,maxTokens:Int,prefill:String) async throws -> Data {calls+=1;return try await base.generate(instruction:instruction,evidence:evidence,maxTokens:maxTokens,prefill:prefill)}
    func take()->Int {defer{calls=0};return calls}
}
@main struct Trial {
 static func main() async {
    do {try await run()} catch {print("MODEL_TRIAL_FAILED: \(error is WriterFailure ? String(describing:error) : "bounded validation/runtime failure")");fflush(stdout);exit(1)}
 }
 static func run() async throws {
    let files:CompatibleWriterFiles
    if CommandLine.arguments.count==4,CommandLine.arguments[1]=="--macos15" {
        files=try MacOS15Runtime.validateTrial(model:URL(fileURLWithPath:CommandLine.arguments[3]),directory:URL(fileURLWithPath:CommandLine.arguments[2]))
    } else {
        guard CommandLine.arguments.count==3 else {throw WriterFailure.invalidInput}
        let model=URL(fileURLWithPath:CommandLine.arguments[2])
        let library=try CompatibleInstallation.extractRuntime(archive:URL(fileURLWithPath:CommandLine.arguments[1]),root:model.deletingLastPathComponent())
        files=try CompatibleInstallation.validate(model:model,runtimeDirectory:library.deletingLastPathComponent())
    }
    let runtime=LlamaInference(files:files)
    let start=Date();try await runtime.load();let loaded=Date()
    let offload=await runtime.offloadEvidence()
    print("RUNTIME_OFFLOAD layers=\(offload.layers) total=\(offload.total)");fflush(stdout)
    await runtime.unload()
    // prompt5/validator7 through the production writer (prefill, one repair turn, salvage, check()) on the
    // PromptEval cases. Quality is scored by `python3 PromptEval/final/prompt4.py run`; this trial measures the Swift path
    // and keeps a meaning check: each case's mustNotSay patterns (and the global ones) must not match, and its mustMention
    // groups are counted.
    let eval=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PromptEval")
    var requests:[CanonicalNoteRequest]=[],mustNotSay:[String:[String]]=[:],mustMention:[String:[[String]]]=[:]
    for file in ["cases.json","final/cases-chrome.json"] {
        let object=try JSONSerialization.jsonObject(with:Data(contentsOf:eval.appendingPathComponent(file))) as! [String:Any]
        let global=((object["globalMustNotSay"] as? [[String:Any]]) ?? []).compactMap {$0["pattern"] as? String}
        for item in object["cases"] as! [[String:Any]] {
            var request=try JSONDecoder().decode(CanonicalNoteRequest.self,from:JSONSerialization.data(withJSONObject:item["request"]!))
            request.expiresAt=ISO8601DateFormatter().string(from:Date().addingTimeInterval(900))
            requests.append(request)
            let checks=(item["checks"] as? [String:Any]) ?? [:]
            mustNotSay[request.id]=global+((checks["mustNotSay"] as? [[String:Any]]) ?? []).compactMap {$0["pattern"] as? String}
            mustMention[request.id]=(checks["mustMention"] as? [[String]]) ?? []
        }
    }
    /// (no forbidden claim, every mustMention group present) for a note's title and bullets.
    func meaning(_ note:CanonicalNoteOutput,_ id:String)->(clean:Bool,mentions:Bool) {
        let text=([note.title]+note.bullets.map(\.text)).joined(separator:"\n")
        let clean=(mustNotSay[id] ?? []).allSatisfy {text.range(of:"(?im)"+$0,options:.regularExpression)==nil}
        let mentions=(mustMention[id] ?? []).allSatisfy {group in group.contains {text.lowercased().contains($0.lowercased())}}
        return (clean,mentions)
    }
    let counting=CountingRuntime(runtime),writer=CanonicalLocalWriter(runtime:counting,policy:{_,_ in true})
    var timings:[Double]=[],passed=0,firstPass=0,cleanPassed=0,meaningPassed=0
    for request in requests {
      let begin=Date()
      do {
        let note=try await writer.generate(request,completeActions:request.actions)
        timings.append(Date().timeIntervalSince(begin));passed += 1
        let calls=await counting.take();if calls==1 {firstPass += 1}
        let m=meaning(note,request.id);if m.clean {cleanPassed += 1};if m.clean && m.mentions {meaningPassed += 1}
        print("case=\(request.id) validated=1 model_calls=\(calls) seconds=\(timings.last!) no_forbidden_claim=\(m.clean) curated_meaning=\(m.clean && m.mentions) \(String(decoding:try JSONEncoder().encode(note),as:UTF8.self))")
      }
      catch {timings.append(Date().timeIntervalSince(begin));print("case=\(request.id) validated=0 model_calls=\(await counting.take()) error=\(error)")}
      fflush(stdout)
    }
    try await runtime.load()
    // Cancellation cannot publish a partial generation. Next load permits retry.
    let cancellation=Task {try await runtime.generate(instruction:"Return a JSON array containing every integer from 1 to 2000.",evidence:String(repeating:"Synthetic cancellation trial. ",count:512),maxTokens:1024)}
    for _ in 0..<5000 {
        if runtime.executionPhase()>=2 {break}
        try await Task.sleep(nanoseconds:1_000_000)
    }
    let cancelPhase=runtime.executionPhase(),cancelStart=Date();cancellation.cancel()
    var cancelled=false;do {_ = try await cancellation.value} catch {cancelled=true}
    print("cancelled=\(cancelled) cancel_phase=\(cancelPhase) cancel_return_seconds=\(Date().timeIntervalSince(cancelStart))")
    await runtime.unload()
    try await runtime.load()
    let retry=try await runtime.generate(instruction:"Return JSON only: {\"ok\":true}",evidence:"Synthetic offline retry after cancellation",maxTokens:64)
    let retryOK=(try? JSONSerialization.jsonObject(with:retry) as? [String:Bool])?["ok"]==true
    await runtime.unload()
    timings.sort();print("REAL_MODEL load_seconds=\(loaded.timeIntervalSince(start)) n=\(timings.count) median_seconds=\(timings[timings.count/2]) p95_seconds=\(timings.last!) validated=\(passed)/\(requests.count) first_pass=\(firstPass)/\(requests.count) no_forbidden_claim=\(cleanPassed)/\(passed) curated_meaning=\(meaningPassed)/\(requests.count) cancel_retry=\(retryOK)")
    guard passed==requests.count,cleanPassed==passed,cancelled,cancelPhase>=2,retryOK else {throw WriterFailure.invalidOutput}
 }
}
