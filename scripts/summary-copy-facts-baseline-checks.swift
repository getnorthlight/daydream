// Same useful abstraction expectations against new and exact old production objects.
// BASELINE changes only the unavailable recipient-argument API; all inputs/oracles are identical.
import Foundation
import PrivacyPolicy
@testable import MemoryCore
@testable import WriterBackend
var pass=0,fail=0
func check(_ ok:Bool,_ label:String){if ok{pass+=1}else{fail+=1;print("FAIL "+label)}}
func copied(_ summary:String,_ source:String)->Bool {
#if BASELINE
 return TypedVerbatimGuard.copies(summary,from:source,places:["Avery"])
#else
 return TypedVerbatimGuard.copies(summary,from:source,places:["Avery"],summaryRecipient:"Avery")
#endif
}
func writerCopy(_ summary:String,_ source:String)throws->Bool {
 let a=NoteAction(id:"a1",at:"2026-09-30T15:00:00Z",kind:"keyboard.text_input",app:"Messages",site:"",title:"Avery",description:"Typed a draft in Messages. "+source,state:"submitted",revision:"fixture",surface:"text",send:"detected",sendBy:"return",to:"Avery",runID:"single",field:"message")
 let o:[String:Any]=["id":"fixture","schemaVersion":1,"targetKind":"activity","targetID":"fixture","day":"2026-09-30","timezone":"UTC","inputRevision":"fixture","policyRevision":"fixture","expiresAt":"2099-01-01T00:00:00Z","actions":try JSONSerialization.jsonObject(with:JSONEncoder().encode([a])),"actionCount":1]
 let req=try JSONDecoder().decode(CanonicalNoteRequest.self,from:JSONSerialization.data(withJSONObject:o))
 return CanonicalGrounding.copyProblem(summary,try ModelView(request:req,actions:req.actions).items[0])>0
}
@main struct NegativeControl {
 static func main()throws {
 let parcel="The courier lost my parcel; can you check the delivery desk?"
 let account="Texted Avery that the courier lost the parcel and asked to check the delivery desk."
 let positives=[(parcel,account),("The recipe lacks an oven temperature; could you add it and check the pan size?","Texted Avery that the recipe lacks an oven temperature and asked to add it and check the pan size.")]
 for (source,summary) in positives {check(!copied(summary,source),"shared useful abstraction");check(try !writerCopy(summary,source),"writer useful abstraction")}
 let negatives=[(parcel,"Texted Avery: "+parcel),(parcel,"Texted Avery that the courier lost my parcel and asked to check the delivery desk."),
 ("Please review the amber copper violet indigo silver bronze inspection labels.","Texted Avery asking to review the amber copper violet indigo silver bronze inspection labels.")]
 for (source,summary) in negatives {check(copied(summary,source),"shared raw/near-full/long span");check(try writerCopy(summary,source),"writer raw/near-full/long span")}
 let root=FileManager.default.temporaryDirectory.appendingPathComponent("copy-baseline-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
 let now=Date(timeIntervalSince1970:1_800_000_000),store=try MemoryStore(home:root,writable:true,automaticallySyncSearch:false)
 var policy=try store.policy();policy.captureText=true;policy.typedConsentVersion=1;try store.updatePolicy(policy,now:now)
 try store.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()),now:now);try store.setUpTypedVault(now:now);try store.acceptSafeTyping(now:now)
 var e=Evidence(id:"a1",at:iso(now),kind:"keyboard.text_input",app:"Notes",bundle:"com.apple.Notes",title:"Avery",text:parcel,synthetic:true)
 let unit=TypedUnitProvenance(runID:"single",part:1,sealReason:"idle",startedAt:iso(now),keys:nil,edits:nil,withheld:0,surface:"text",field:"message",send:"detected",sendBy:"return",to:"Avery")
 e.captureProvenance=NativeCaptureProvenance(policyRevision:"fixture",classifierVersion:"sensitive-typing/v2",windowID:"synthetic",focusID:"synthetic",checkedAt:iso(now),generation:1,unit:unit)
 check(try store.ingest(e,now:now),"identical v3 source acquired")
 _=try store.writePending(now:now)
 let req=try store.prepareNote(kind:"day",day:TypedTextVault.epoch(for:now),timezone:"UTC",now:now)
 do {
  let n=try store.commitNote(NoteWriterOutput(requestID:req.id,title:"Fictional request",bullets:[NoteBullet(text:account,actionIDs:["a1"],assertion:"submitted")],generator:"fixture",generatorVersion:"1"),now:now)
  check(n.output.bullets[0].text==account,"real core useful abstraction commit")
 }catch{
  check(false,"real core useful abstraction commit "+String(describing:error))
  check(String(describing:error).contains("may not copy"),"baseline rejection is actual copy guard")
 }
 print("SUMMARY_COPY_BASELINE \(pass) PASS \(fail) FAIL")
 if fail>0{throw MemError.invalid("expected baseline fails when BASELINE is set")}
 }
}
