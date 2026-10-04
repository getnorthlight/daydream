// Explicit synthetic local-model trial. No capture, history, settings, downloads or cloud.
// An ad-hoc developer host verifies only the pinned model cache and supplied manifest-pinned runtime.
// Raw answers are actual inference; PIPELINE_FINAL may be code fallback, identified by generator.
import Foundation
@testable import WriterBackend
actor RecordingRuntime:LocalInference {
 let base:LlamaInference
 init(_ base:LlamaInference){self.base=base}
 func load() async throws {try await base.load()}
 func unload() async {await base.unload()}
 func generate(instruction:String,evidence:String,maxTokens:Int) async throws -> Data {try await generate(instruction:instruction,evidence:evidence,maxTokens:maxTokens,prefill:"")}
 func generate(instruction:String,evidence:String,maxTokens:Int,prefill:String) async throws -> Data {
  print("ACTUAL_INSTRUCTION "+instruction); print("ACTUAL_EVIDENCE "+evidence);fflush(stdout)
  let data=try await base.generate(instruction:instruction,evidence:evidence,maxTokens:maxTokens,prefill:prefill)
  print("ACTUAL_MODEL_RAW "+CanonicalGrounding.withPrefill(String(decoding:data,as:UTF8.self),prefill));fflush(stdout)
  return data
 }
}
func action(_ id:String,_ text:String,run:String?=nil) -> NoteAction {
 NoteAction(id:id,at:"2026-09-30T15:00:00Z",kind:"keyboard.text_input",app:"Messages",site:"",title:"Avery",description:"Typed a draft in Messages. "+text,state:"submitted",revision:"fixture",surface:"text",send:"detected",sendBy:"return",to:"Avery",runID:run ?? id,field:"message")
}
func request(_ id:String,_ actions:[NoteAction]) throws -> CanonicalNoteRequest {
 let data=try JSONSerialization.data(withJSONObject:["id":id,"schemaVersion":1,"targetKind":"activity","targetID":id,"day":"2026-09-30","timezone":"UTC","inputRevision":id,"policyRevision":"fixture","expiresAt":"2099-01-01T00:00:00Z","actions":try JSONSerialization.jsonObject(with:JSONEncoder().encode(actions)),"actionCount":actions.count])
 return try JSONDecoder().decode(CanonicalNoteRequest.self,from:data)
}
@main struct Trial {
 static func main() async throws {
  guard try !WriterRuntimeAdmission.requiresSignedDistribution() else {throw WriterFailure.denied}
  let dir=URL(fileURLWithPath:CommandLine.arguments[1])
  let manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:dir.appendingPathComponent("daydream-qwen35-b9723-macos15-v2.json"))) as! [String:Any]
  for entry in manifest["files"] as! [[String:Any]] {
   print("VERIFY_RUNTIME "+(entry["name"] as! String));fflush(stdout)
   try ModelIdentity.verify(dir.appendingPathComponent(entry["name"] as! String),bytes:(entry["signedBytes"] as! NSNumber).int64Value,hash:entry["signedSHA256"] as! String)
  }
  let roots=PersistentModelCache.knownRoots(applicationSupport:FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0])
  guard let model=try await PersistentModelCache.discover(in:roots) else {throw WriterFailure.unavailable}
  let files=CompatibleWriterFiles(model:model,library:dir.appendingPathComponent("libllama.0.dylib"))
  let runtime=LlamaInference(files:files),recording=RecordingRuntime(runtime)
  let writer=CanonicalLocalWriter(runtime:recording,policy:{_,_ in true})
  let later="Hey Avery, I didn't get into ASC this round. I might apply again, but I'm not sure. Do they recruit in spring?"
  let cases=[
   try request("unknown-acronym",[action("u1",later)]),
   try request("same-run-definition",[action("c1","The Astronomy Society Club (ASC) application is the one we discussed.",run:"club-run"),action("c2",later,run:"club-run")]),
   try request("different-run-definition",[action("x1","The Astronomy Society Club (ASC) application is the one we discussed."),action("x2",later)]),
   try request("workshop-generalization",[action("w1","The workshop ran out of places. I might try next month, although I am unsure. Can you ask whether they offer evening sessions?")]),
   try request("separate-messages",[action("s1","Could you look over the planting sketch?"),action("s2","The courier lost my parcel; can you check the delivery desk?")]),
   try request("repair-stall-holdout",[action("h1","The rear light stopped working. I might replace the battery, although I am unsure. Is the repair stall open on Sunday?")]),
   try request("document-review-holdout",[action("h2","The outline still lacks examples; could you suggest a concrete opening and mark the repetitive sections?")])
  ]
  for c in cases where CommandLine.arguments.count<3 || c.id==CommandLine.arguments[2] {
   print("CASE \(c.id) VERSION \(CanonicalGrounding.localVersion)");fflush(stdout)
   let start=Date(),view=try ModelView(request:c,actions:c.actions)
   print("MODEL_EVIDENCE "+view.text);fflush(stdout)
   let note=try await writer.generate(c,completeActions:c.actions)
   print("PIPELINE_FINAL "+String(decoding:try JSONEncoder().encode(note),as:UTF8.self));fflush(stdout)
   let fallback=try CanonicalGrounding.fallbackNote(c,view:view)
   print("DETERMINISTIC_FALLBACK "+String(decoding:try JSONEncoder().encode(fallback),as:UTF8.self))
   print("CASE_SECONDS \(Date().timeIntervalSince(start))");fflush(stdout)
  }
 }
}
