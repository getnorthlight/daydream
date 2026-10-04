import Foundation
import MemoryCore
@testable import WriterBackend
@testable import MemoryUI
final class Burst: @unchecked Sendable {
 private let lock=NSLock();private var value=true
 func set(_ v:Bool){lock.lock();value=v;lock.unlock()}
 func get()->Bool{lock.lock();defer{lock.unlock()};return value}
}
actor Recording:LocalInference {
 let base:LlamaInference
 init(_ b:LlamaInference){base=b}
 func load()async throws{try await base.load()}
 func unload()async{await base.unload()}
 func generate(instruction:String,evidence:String,maxTokens:Int)async throws->Data{try await generate(instruction:instruction,evidence:evidence,maxTokens:maxTokens,prefill:"")}
 func generate(instruction:String,evidence:String,maxTokens:Int,prefill:String)async throws->Data{
 print("PROMPT_BYTES instruction \(instruction.utf8.count) evidence \(evidence.utf8.count)");print("ACTUAL_INSTRUCTION "+instruction);print("ACTUAL_EVIDENCE "+evidence);fflush(stdout)
 let raw:Data
 do {raw=try await base.generate(instruction:instruction,evidence:evidence,maxTokens:maxTokens,prefill:prefill)}
 catch {print("INFERENCE_FAILURE \(error) bridge_status \(base.lastGenerationStatus())");fflush(stdout);throw error}
 print("ACTUAL_MODEL_RAW "+CanonicalGrounding.withPrefill(String(decoding:raw,as:UTF8.self),prefill));fflush(stdout);return raw
 }
}
private func check(_ ok:Bool,_ label:String)throws{print("\(ok ? "PASS":"FAIL") \(label)");fflush(stdout);if !ok{throw WriterFailure.invalidOutput}}
@main @MainActor struct ModelCheck {
 static func main()async throws {
 let root=URL(fileURLWithPath:CommandLine.arguments[1]),runtimeDir=URL(fileURLWithPath:CommandLine.arguments[2])
 let manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:runtimeDir.appendingPathComponent("daydream-qwen35-b9723-macos15-v2.json"))) as! [String:Any]
 for e in manifest["files"] as! [[String:Any]] {try ModelIdentity.verify(runtimeDir.appendingPathComponent(e["name"] as! String),bytes:(e["signedBytes"] as! NSNumber).int64Value,hash:e["signedSHA256"] as! String)}
 guard let model=try await PersistentModelCache.discover(in:[root.appendingPathComponent("models")])else{throw WriterFailure.unavailable}
 let files=CompatibleWriterFiles(model:model,library:runtimeDir.appendingPathComponent("libllama.0.dylib"))
 let burst=Burst(),runtime=LlamaInference(files:files,shouldPause:{burst.get()}),recording=Recording(runtime)
 let store=try MemoryStore(home:root.appendingPathComponent("model-fixture-"+UUID().uuidString),writable:true,automaticallySyncSearch:false)
 let now=Date(),start=now.addingTimeInterval(-1200)
 var policy=try store.policy();policy.captureText=true;policy.typedConsentVersion=1;try store.updatePolicy(policy,now:now)
 try store.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()),now:now);try store.setUpTypedVault(now:now);try store.acceptSafeTyping(now:now)
 let prompts=["Review the DayDream design and plan fixes.","Explain the summary queue.","Inspect the local writer scheduling.","Check the summary detail order.","Review the owner preview privacy gates.","Find the stale summary status.","Inspect the terminal request capture.","Plan the ten minute refresh.","Review the typed burst pause.","Explain safe model cancellation.","Keep every captured request visible.","Check the duplicate summary excerpts.","Summarize the DayDream design fixes."]
 var ids:[String]=[]
 for (i,words) in prompts.enumerated(){
 let at=iso(start.addingTimeInterval(Double(i)*100));let id="request-\(i)";ids.append(id)
 var e=Evidence(id:id,at:at,kind:"keyboard.text_input",app:"Ghostty",bundle:"com.mitchellh.ghostty",title:"daydream — claude",text:words,synthetic:true)
 let unit=TypedUnitProvenance(runID:id,part:1,sealReason:"submit",startedAt:at,keys:nil,edits:nil,withheld:0,surface:"aiTool",field:"terminal",send:"detected",sendBy:"return",to:"Claude Code")
 e.captureProvenance=NativeCaptureProvenance(policyRevision:policy.revision,classifierVersion:"sensitive-typing/v2",windowID:"fixture-window",focusID:"fixture-input",checkedAt:at,generation:1,unit:unit)
 _=try store.ingest(e,now:now)
 }
 let day=try DayScope.key(now,timezone:"UTC"),layers=try store.dayLayers(day:day,timezone:"UTC",now:now)
 guard let moment=layers.activities.first(where:{$0.actionIDs.count==13})else{throw WriterFailure.invalidInput}
 let before=try store.ownerSourceMomentPreviewsForActions(ids,now:now)
 try check(OwnerSourceMomentProjection.standIn(before).count==5,"20-minute fixture has five newest distinct short captured excerpts before inference")
 let source=WriterQueueSource(store:store)
 let discovery=try await source.discoverDay(day,now:now,timezone:"UTC")
 try check(discovery.open.contains{$0.activityID==moment.id},"twenty-minute fixture is still open when the model summary starts")
 let binding=CoreWriterBinding(store:store,typedWriter:.local),port=binding.port()
 let writer=CanonicalLocalWriter(runtime:recording,policy:port.permitted)
 let adapter=CoreWriterAdapter(core:port,generate:{try await writer.generate($0,completeActions:$1)},localIntentSessions:true)
 let target=WriterTarget(kind:.activity,day:day,timezone:"UTC",activityID:moment.id,allowGrowingSnapshot:true)
 try await runtime.load()
 print("PRELOADED_OFFLOAD \(await runtime.offloadEvidence())");fflush(stdout)
 let job=Task{try await adapter.process(target,lastActivity:now,now:now,allowActive:true)}
 var paused=false
 for _ in 0..<1000 {if runtime.executionPhase()==4{paused=true;break};try await Task.sleep(nanoseconds:20_000_000)}
 try check(paused,"copied shipped model reaches phase4 during a synthetic typing burst")
 burst.set(false)
 let result=try await job.value
 print("BRIDGE_GENERATION_STATUS \(runtime.lastGenerationStatus())");print("MODEL_RESULT \(result)");fflush(stdout)
 guard case .committed(let receipt)=result else {print("RESULT pending \(result)");throw WriterFailure.invalidOutput}
 print("PIPELINE_FINAL "+String(decoding:try JSONEncoder().encode(receipt.output),as:UTF8.self));fflush(stdout)
 try check(receipt.output.generator.hasPrefix("local/") && receipt.output.generatorVersion==CanonicalGrounding.localVersion,"summary is actual local model output rather than bounded code fallback")
 try check(Set(receipt.output.bullets.flatMap(\.actionIDs))==Set(ids),"model summary accounts for all thirteen source actions")
 try check(receipt.output.bullets.contains{$0.text.contains("Asked") && !$0.text.contains("Typed a draft")},"model summary names own captured intent rather than generic typing")
 let after=try store.dayLayers(day:day,timezone:"UTC")
 let ready=after.activities.first{$0.id==moment.id}!
 try check(ready.generated != nil,"real local model summary is stored before the open moment ends")
 let stillOpen=try await source.selected(day:day,timezone:"UTC",activityID:moment.id,now:Date())
 try check(stillOpen.open,"post-inference canonical discovery confirms the summarized moment has not ended")
 let previews=try store.ownerSourceMomentPreviewsForActions(ids),actions=try ids.compactMap{try store.action($0)}
 try check(OwnerSourceMomentProjection.history(actions,previews:previews).count==13 && OwnerSourceMomentProjection.history(actions,previews:previews).flatMap(\.typed).map(\.text)==prompts,"What happened retains all thirteen actual prompts after the model summary arrives")
 var mixedIDs=ids
 for (id,words) in [("secret","export API_TOKEN=sk-live-synthetic-abcdefghijklmnopqrstuvwxyz0123456789"),("otp","Your verification code is 123456")] {
     var e=Evidence(id:id,at:iso(Date()),kind:"keyboard.text_input",app:"Ghostty",bundle:"com.mitchellh.ghostty",title:"daydream — claude",text:words,synthetic:true)
     let at=e.at
     let unit=TypedUnitProvenance(runID:id,part:1,sealReason:"submit",startedAt:at,keys:nil,edits:nil,withheld:0,surface:"aiTool",field:"terminal",send:"detected",sendBy:"return",to:"Claude Code")
     e.captureProvenance=NativeCaptureProvenance(policyRevision:policy.revision,classifierVersion:"sensitive-typing/v2",windowID:"fixture-window",focusID:"fixture-input",checkedAt:at,generation:1,unit:unit)
     _=try store.ingest(e);mixedIDs.append(id)
 }
 let mixedPreviews=try store.ownerSourceMomentPreviewsForActions(mixedIDs),mixedActions=try mixedIDs.compactMap{try store.action($0)}
 let mixedHistory=OwnerSourceMomentProjection.history(mixedActions,previews:mixedPreviews)
 try check(mixedPreviews.count==13 && mixedHistory.count==15 && mixedHistory.flatMap(\.typed).count==13 && OwnerSourceMomentProjection.standIn(mixedPreviews).count==5,"same model session keeps thirteen safe prompts plus secret/OTP metadata while their wording stays hidden")
 try check(!mixedHistory.flatMap(\.typed).contains{$0.text.contains("123456") || $0.text.contains("sk-live")},"secret and one-time code never appear in the owner projection after summary arrives")
 await runtime.unload()
 print("RESULT actual model and owner history checks PASS; timing CONTAMINATED")
 }
}
