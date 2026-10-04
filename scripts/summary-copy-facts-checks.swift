// Source/copy/persistence controls use synthetic evidence and in-memory keys only.
import Foundation
import PrivacyPolicy
@testable import MemoryCore
@testable import WriterBackend
var count=0,failures=0
func check(_ ok:Bool,_ label:String){if ok{count+=1;print("PASS "+label)}else{failures+=1;print("FAIL "+label)}}
func refuses(_ label:String,_ text:String,_ body:()throws->Void) {
 do{try body();check(false,label)}catch{check(String(describing:error).contains(text),label)}
}
func action(_ id:String,_ source:String,to:String?="Avery",run:String?=nil)->NoteAction {
 NoteAction(id:id,at:"2026-09-30T15:00:00Z",kind:"keyboard.text_input",app:"Messages",site:"",title:"Avery",description:"Typed a draft in Messages. "+source,state:"submitted",revision:"fixture",surface:"text",send:"detected",sendBy:"return",to:to,runID:run ?? id,field:"message")
}
func request(_ actions:[NoteAction])throws->CanonicalNoteRequest {
 let obj:[String:Any]=["id":"copy-fixture","schemaVersion":1,"targetKind":"activity","targetID":"copy-fixture","day":"2026-09-30","timezone":"UTC","inputRevision":"copy-fixture","policyRevision":"fixture","expiresAt":"2099-01-01T00:00:00Z","actions":try JSONSerialization.jsonObject(with:JSONEncoder().encode(actions)),"actionCount":actions.count]
 return try JSONDecoder().decode(CanonicalNoteRequest.self,from:JSONSerialization.data(withJSONObject:obj))
}
let parcel="The courier lost my parcel; can you check the delivery desk?"
let account="Texted Avery that the courier lost the parcel and asked to check the delivery desk."
let recipe="The recipe lacks an oven temperature; could you add it and check the pan size?"
let recipeAccount="Texted Avery that the recipe lacks an oven temperature and asked to add it and check the pan size."
@main struct CopyControls {
 static func main() throws {
  for (source,summary) in [(parcel,account),(recipe,recipeAccount),
   ("The equipment checklist still lacks a calibration step; please check the cable label and flag the loose bracket.","Texted Avery that the equipment checklist lacks a calibration step, asking to inspect the cable label and mark the loose bracket.")] {
   let req=try request([action("p1",source)]),view=try ModelView(request:req,actions:req.actions),item=view.items[0]
   check(CanonicalGrounding.copyProblem(summary,item)==0,"writer factual nouns/request targets survive")
   check(!TypedVerbatimGuard.copies(summary,from:source,places:["Avery"],summaryRecipient:"Avery"),"shared factual nouns/request targets survive")
   check(TypedVerbatimGuard.copies(summary,from:source,places:["Avery"]),"legacy policy without authority remains strict")
   check(TypedVerbatimGuard.summaryNouns(summary,source,recipient:"Avery")==CanonicalGrounding.summaryNouns(summary,source,recipient:"Avery"),"pure noun eligibility parity")
  }
  let negatives=[
   (parcel,"Texted Avery: "+parcel,"raw quote after lead"),
   (parcel,"Texted Avery that the courier lost my parcel and asked to check the delivery desk.","near-full first-person sentence"),
   (parcel,"Texted Avery that the courier lost the parcel; can you check the delivery desk?","direct second-person transcript"),
   ("Please review the amber copper violet indigo silver bronze inspection labels.","Texted Avery asking to review the amber copper violet indigo silver bronze inspection labels.","long contiguous content span"),
   ("Please check the cable label.","Texted Avery asking to check the cable label.","short-source contiguous fraction"),
   ("divorce lawyer near me","Searched for divorce lawyer near me","whole short search")
  ]
  for (source,summary,label) in negatives {
   let req=try request([action("n1",source)]),view=try ModelView(request:req,actions:req.actions)
   check(TypedVerbatimGuard.copies(summary,from:source,places:["Avery"],summaryRecipient:"Avery"),"shared rejects "+label)
   check(CanonicalGrounding.copyProblem(summary,view.items[0])>0,"writer rejects "+label)
  }
  check(TypedVerbatimGuard.copies(account,from:parcel,places:["Avery"],summaryRecipient:nil),"arbitrary window/title is not authority")
  let unknown=try request([action("u1",parcel,to:nil)])
  check(CanonicalGrounding.copyProblem(account,try ModelView(request:unknown,actions:unknown.actions).items[0])>0,"unknown captured recipient is not inherited from title")
  let mixed=try request([action("x1",parcel,to:"Avery",run:"shared"),action("x2","Please review the display notes.",to:"Rowan",run:"shared")])
  let mixedView=try ModelView(request:mixed,actions:mixed.actions)
  check(CanonicalGrounding.summaryRecipient(mixedView.items[0])==nil,"split/mixed item refuses exception")
  check(TypedVerbatimGuard.summaryNouns(account,parcel+" [withheld]",recipient:"Avery")==nil,"masked source refuses exception")
  check(TypedVerbatimGuard.summaryNouns(account,parcel+"…",recipient:"Avery")==nil,"truncated source refuses exception")
  check(TypedVerbatimGuard.summaryNouns(account,String(repeating:parcel,count:10),recipient:"Avery")==nil,"long full run refuses exception")
  check(!TypedVerbatimGuard.copies("Avery",fromAny:["Avery"],places:[],field:"to"),"To field's existing naming contract unchanged")
  check(TypedVerbatimGuard.copies("amber copper violet indigo silver bronze",fromAny:["amber copper violet indigo silver bronze and later notes"],field:"subject"),"subject still has five-content-word cap")
  let longSource="Please review amber copper violet indigo silver bronze."
  let longSummary="Texted Avery asking to review amber copper violet indigo silver bronze."
  let title="amber copper violet indigo silver bronze"
  var titled=action("title",longSource);titled.title=title
  let titledRequest=try request([titled]),titledView=try ModelView(request:titledRequest,actions:titledRequest.actions)
  check(CanonicalGrounding.copyProblem(longSummary,titledView.items[0])>0,"recorded window title cannot free a seven-word copied request")
  check(TypedVerbatimGuard.copies(longSummary,from:longSource,places:["Avery",title],summaryRecipient:"Avery"),"shared ordinary contiguous bound ignores window/title free words")
  let unknownSummary=account.replacingOccurrences(of:"Avery",with:"unknown")
  let unknownRequest=try request([action("unknown",parcel,to:" unknown ")])
  let unknownView=try ModelView(request:unknownRequest,actions:unknownRequest.actions)
  check(CanonicalGrounding.summaryRecipient(unknownView.items[0])==nil,"writer trims and refuses padded unknown authority")
  check(CanonicalGrounding.copyProblem(unknownSummary,unknownView.items[0])>0,"writer refuses padded-unknown copy exception")
  let timedSource="The meeting notice lacks a room number; could you confirm the start time at 9:00?"
  let timedSummary="Texted Avery that the meeting notice lacks a room number and asked to verify the start time at 9:00."
  check(TypedVerbatimGuard.summaryNouns(timedSummary,timedSource,recipient:"Avery") != nil,"clock punctuation does not suppress captured target nouns")
  check(!TypedVerbatimGuard.copies(timedSummary,from:timedSource,places:["Avery"],summaryRecipient:"Avery"),"shared preserves captured clock plus subject/request qualifiers")
  let timedRequest=try request([action("clock",timedSource)])
  check(CanonicalGrounding.copyProblem(timedSummary,try ModelView(request:timedRequest,actions:timedRequest.actions).items[0])==0,"writer preserves captured clock plus subject/request qualifiers")
  try storeControls()
  print("SUMMARY_COPY_FACTS \(count) PASS \(failures) FAIL")
  if failures>0{throw MemError.invalid("copy facts controls failed")}
 }
 static func storeControls()throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("copy-facts-"+UUID().uuidString)
  defer{try? FileManager.default.removeItem(at:root)}
  let now=Date(timeIntervalSince1970:1_800_000_000),day=86400.0
  func ready(_ name:String)throws->MemoryStore {
   let store=try MemoryStore(home:root.appendingPathComponent(name),writable:true,automaticallySyncSearch:false)
   var policy=try store.policy();policy.captureText=true;policy.typedConsentVersion=1;try store.updatePolicy(policy,now:now)
   try store.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()),now:now);try store.setUpTypedVault(now:now);try store.acceptSafeTyping(now:now)
   return store
  }
  func evidence(_ id:String,_ text:String,run:String,part:Int=1,to:String?="Avery",legacy:Bool=false)->Evidence {
   var e=Evidence(id:id,at:iso(now),kind:"keyboard.text_input",app:"Notes",bundle:"com.apple.Notes",title:"Avery",text:text,synthetic:true)
   var unit=TypedUnitProvenance(runID:run,part:part,sealReason:"idle",startedAt:iso(now),keys:nil,edits:nil,withheld:0,surface:"text",field:"message",send:"detected",sendBy:"return",to:to)
   if legacy{unit.version="typed-unit/v2"}
   e.captureProvenance=NativeCaptureProvenance(policyRevision:"fixture",classifierVersion:"sensitive-typing/v2",windowID:"synthetic",focusID:"synthetic",checkedAt:iso(now),generation:1,unit:unit)
   return e
  }
  func output(_ id:String,_ row:String,_ text:String)->NoteWriterOutput {
   NoteWriterOutput(requestID:id,title:"Fictional delivery request",bullets:[NoteBullet(text:text,actionIDs:[row],assertion:"submitted")],generator:"fixture",generatorVersion:"1")
  }
  let store=try ready("valid")
  check(try store.ingest(evidence("v1",parcel,run:"valid"),now:now),"sealed fictional source saved")
  check(try store.typedSummaryRecipient(for:"v1")=="Avery","core recipient authority is captured unit")
  _=try store.writePending(now:now)
  let req=try store.prepareNote(kind:"day",day:TypedTextVault.epoch(for:now),timezone:"UTC",now:now)
  refuses("actual commit rejects direct source transcript","may not copy") {_=try store.commitNote(output(req.id,"v1","Texted Avery: "+parcel),now:now)}
  let saved=try store.commitNote(output(req.id,"v1",account),now:now)
  check(saved.output.bullets[0].text==account,"actual commit accepts attributed fact/request")
  check(try store.noteSummary(for:"v1",words:parcel)==account,"expiry projection reuses exact shared policy")
  let bad=GeneratedNote(id:"unsafe-old",version:1,schemaVersion:1,generatedAt:iso(now),inputRevision:"old",actionIDs:["v1"],output:output("old","v1","Texted Avery: "+parcel),status:"generated_unverified")
  try store.exec("INSERT INTO generated_notes VALUES(?,?,?,?)",["unsafe-old","1","old",json(bad)])
  let expiry=try store.expireTypedText(now:now.addingTimeInterval(9*day))
  check(expiry.expired==1 && expiry.removedNotes==1,"expiry deletes source and copied old note")
  check(try store.rows("SELECT id FROM generated_notes WHERE id='unsafe-old'").isEmpty,"copied note is absent after expiry")
  check(try store.typedAfter("v1")?.summary==account,"only safe attributed summary survives source expiry")
  check(try store.hydrateTypedText("v1",disclosure:.owner,now:now.addingTimeInterval(9*day))==nil,"expired source cannot hydrate")
  _=try store.forgetTypedText(confirmed:true,now:now.addingTimeInterval(9*day))
  check(try store.rows("SELECT id FROM generated_notes").isEmpty && store.rows("SELECT * FROM typed_after").isEmpty,"Forget removes source-linked notes and after summaries")
  for (name,to,legacy) in [("unknown",nil,false),("legacy",Optional("Avery"),true),("padded-unknown",Optional(" unknown "),false)] {
   let denied=try ready(name)
   check(try denied.ingest(evidence("d1",parcel,run:name,to:to,legacy:legacy),now:now),"negative sealed source saved "+name)
   check(try denied.typedSummaryRecipient(for:"d1")==nil,"core authority refused "+name)
   _=try denied.writePending(now:now)
   let r=try denied.prepareNote(kind:"day",day:TypedTextVault.epoch(for:now),timezone:"UTC",now:now)
   refuses("actual commit refuses title-only/legacy exemption "+name,"may not copy") {_=try denied.commitNote(output(r.id,"d1",name=="padded-unknown" ? account.replacingOccurrences(of:"Avery",with:"unknown"):account),now:now)}
  }
  let titleStore=try ready("title")
  let titleSource="Please review amber copper violet indigo silver bronze."
  let titleSummary="Texted Avery asking to review amber copper violet indigo silver bronze."
  var te=evidence("title",titleSource,run:"title");te.title="amber copper violet indigo silver bronze"
  check(try titleStore.ingest(te,now:now),"long-span title fixture sealed")
  _=try titleStore.writePending(now:now)
  let tr=try titleStore.prepareNote(kind:"day",day:TypedTextVault.epoch(for:now),timezone:"UTC",now:now)
  refuses("actual commit refuses ordinary long span despite window title","may not copy") {_=try titleStore.commitNote(output(tr.id,"title",titleSummary),now:now)}
  let unsafeTitle=GeneratedNote(id:"unsafe-title",version:1,schemaVersion:1,generatedAt:iso(now),inputRevision:"old",actionIDs:["title"],output:output("old","title",titleSummary),status:"generated_unverified")
  try titleStore.exec("INSERT INTO generated_notes VALUES(?,?,?,?)",["unsafe-title","1","old",json(unsafeTitle)])
  let titleExpired=try titleStore.expireTypedText(now:now.addingTimeInterval(9*day))
  check(titleExpired.expired==1 && titleExpired.removedNotes==1,"expiry removes old long-span note despite window title")
  check(try titleStore.typedAfter("title")?.summary=="","expired title fixture keeps no copied after-summary")
  let split=try ready("split")
  check(try split.ingest(evidence("s1",parcel,run:"split",part:1),now:now),"first split source saved")
  check(try split.ingest(evidence("s2","Please review the display notes.",run:"split",part:2),now:now),"second split source saved")
  check(try split.typedSummaryRecipient(for:"s1")==nil,"core full-run count refuses short-part exception")
  _=try split.writePending(now:now)
  let sr=try split.prepareNote(kind:"day",day:TypedTextVault.epoch(for:now),timezone:"UTC",now:now)
  refuses("actual commit keeps whole-run/split copy policy","may not copy") {_=try split.commitNote(output(sr.id,"s1",account),now:now)}
 }
}
