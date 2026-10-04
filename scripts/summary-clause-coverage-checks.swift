import Foundation
@testable import WriterBackend
var pass=0,fail=0
func check(_ ok:Bool,_ label:String){if ok{pass+=1}else{fail+=1;print("FAIL "+label)}}
func item(_ text:String,to:String="Avery",title:String="Avery",run:String?="fixture",state:String="submitted")throws->ModelItem {
 let a=NoteAction(id:"a1",at:"2026-09-30T15:00:00Z",kind:"keyboard.text_input",app:"Messages",site:"",title:title,description:"Typed a draft in Messages. "+text,state:state,revision:"fixture",surface:"text",send:state=="submitted" ? "detected":"unknown",sendBy:state=="submitted" ? "return":nil,to:to,runID:run,field:"message")
 let data=try JSONSerialization.data(withJSONObject:["id":"fixture","schemaVersion":1,"targetKind":"activity","targetID":"fixture","day":"2026-09-30","timezone":"UTC","inputRevision":"fixture","policyRevision":"fixture","expiresAt":"2099-01-01T00:00:00Z","actions":try JSONSerialization.jsonObject(with:JSONEncoder().encode([a])),"actionCount":1])
 let req=try JSONDecoder().decode(CanonicalNoteRequest.self,from:data)
 return try ModelView(request:req,actions:req.actions).items[0]
}
@main struct Checks {
 static func main()throws {
 let source="The equipment checklist still lacks a calibration step; please check the cable label and flag the loose bracket."
 let e=try item(source)
 check(CanonicalGrounding.sourceDetails(e).count==3,"three separate source clauses")
 let full="Texted Avery that the equipment checklist lacks a calibration step and asked to check the cable label and flag the loose bracket."
 check(CanonicalGrounding.missingDetails(full,[e]).isEmpty,"complete absence and both requests")
 check(CanonicalGrounding.missingDetails("Texted Avery about the missing calibration step in the equipment checklist.",[e]).count==2,"both requests missing detected")
 check(!CanonicalGrounding.missingDetails("Texted Avery that the equipment checklist lacks a calibration step and asked to flag the cable label and check the loose bracket.",[e]).isEmpty,"same nouns swapped verb-target relations refused")
 check(!CanonicalGrounding.missingDetails("Texted Avery asked to check the cable label and flag the loose bracket.",[e]).isEmpty,"missing reported absence")
 check(!CanonicalGrounding.missingDetails("Texted Avery checked the cable label and flagged the loose bracket.",[e]).isEmpty,"request cannot become completed action")
 check(!CanonicalGrounding.missingDetails("Texted Avery asked not to check the cable label and flag the loose bracket.",[e]).isEmpty,"request polarity cannot flip")
 check(!CanonicalGrounding.missingDetails("Texted Avery that the equipment checklist lacks a calibration step and asked to flag the cable label and checked the loose bracket.",[e]).isEmpty,"past-tense swapped request targets refused")
 check(CanonicalGrounding.missingDetails("Texted Avery that the equipment checklist lacks a calibration step and requested checking the cable label and flagging the loose bracket.",[e]).isEmpty,"controlled request inflections retain target pairs")
 check(!CanonicalGrounding.missingDetails("Texted Avery that the equipment checklist lacks a calibration step and asked to flag the cable label and requested checking the loose bracket.",[e]).isEmpty,"request wrappers cannot hide swapped targets")
 let notice=try item("I noticed that the meeting notice is missing the room number. Could you confirm its start time and add arrival directions?")
 check(CanonicalGrounding.sourceDetails(notice).count==3,"observed absence and requests separate")
 check(CanonicalGrounding.missingDetails("Texted Avery that the meeting notice lacks a room number and asked to confirm the start time and add arrival directions.",[notice]).isEmpty,"all meeting details")
 let route=try item("The route guide is missing a trail marker. Could you locate the junction and update the map?")
 check(!CanonicalGrounding.missingDetails("Texted Avery that the route guide lacks a trail marker and asked for the junction location.",[route]).isEmpty,"missing locate and update requests")
 check(CanonicalGrounding.missingDetails("Texted Avery that the route guide lacks a trail marker and asked to find the junction and refresh the map.",[route]).isEmpty,"finite requested-verb equivalents")
 let n=try item("The lobby is not reserved. Could you check its hours?")
 check(CanonicalGrounding.changedNegativeStatement("Texted Avery that the lobby is reserved and asked to check its hours.",[n]),"negated predicate cannot become affirmative")
 check(!CanonicalGrounding.changedNegativeStatement("Texted Avery that the lobby is not reserved and asked to check its hours.",[n]),"negated predicate retained")
 let gallery=try item("The gallery is unavailable. Could you review the Friday tickets?")
 check(CanonicalGrounding.changedNegativeStatement("Texted Avery that the gallery is booked and asked to review Friday tickets.",[gallery]),"negative availability cannot become invented outcome")
 check(!CanonicalGrounding.changedNegativeStatement("Texted Avery that the gallery is not available and asked to review Friday tickets.",[gallery]),"finite negative availability equivalent")
 check(CanonicalGrounding.missingDetails("Texted Avery that the gallery is unavailable and asked to review Saturday tickets.",[gallery]).count==1,"different day refused")
 check(CanonicalGrounding.changedNegativeStatement("Texted Avery that the gallery is not busy and asked to review Friday tickets.",[gallery]),"same negative polarity but changed predicate refused")
 let pantry=try item("The pantry is not empty. Please inspect the upper shelf.")
 check(CanonicalGrounding.changedNegativeStatement("Texted Avery that the pantry is empty and requested inspection of the upper shelf.",[pantry]),"opposite negated state refused")
 check(!CanonicalGrounding.changedNegativeStatement("Texted Avery that the pantry is not empty and asked to inspect the upper shelf.",[pantry]),"opposite state preserved")
 let a=try item("The checklist lacks a red label; please review the lower latch.",title:"blue label and upper latch")
 check(!CanonicalGrounding.missingDetails("Texted Avery that the checklist lacks a blue label and asked to review the upper latch.",[a]).isEmpty,"title never supplies missing targets")
 for to in ["unknown"," unknown ","[withheld]",""] {check(CanonicalGrounding.sourceDetails(try item(source,to:to)).isEmpty,"no recipient authority "+to)}
 check(CanonicalGrounding.sourceDetails(try item(source,run:nil)).isEmpty,"no run authority")
 check(CanonicalGrounding.sourceDetails(try item(source+String(repeating:" extra",count:70))).isEmpty,"long source ordinary pipeline")
 check(CanonicalGrounding.sourceDetails(try item("The checklist lacks [withheld]; please inspect a shelf.")).isEmpty,"masked source refused")
 check(CanonicalGrounding.sourceDetails(try item("The checklist lacks a label…; please inspect a shelf.")).isEmpty,"partial source refused")
 let mural=try item("The mural is not finished. Please review the corner pattern and mark the faint line.")
 check(!CanonicalGrounding.changedNegativeStatement("Texted Avery that the mural is unfinished and asked to review the corner pattern and mark the faint line.",[mural]),"finite ordinary negative equivalent retained")
 check(CanonicalGrounding.changedNegativeStatement("Texted Avery that the mural is finished and asked to review the corner pattern and mark the faint line.",[mural]),"same subject positive outcome refused")
 let inquiry=try item("The gallery is unavailable. I might visit the garden, but I'm unsure. Are there openings on Friday?")
 check(!CanonicalGrounding.missingDetails("Texted Avery that the gallery is unavailable, might visit the garden and reported Friday openings.",[inquiry]).isEmpty,"inquiry cannot become confirmed availability")
 check(!CanonicalGrounding.missingDetails("Texted Avery that the gallery is unavailable, might visit the garden and asked about Monday openings.",[inquiry]).isEmpty,"inquiry day preserved")
 check(CanonicalGrounding.missingDetails("Texted Avery that the gallery is unavailable, might visit the garden and asked about Friday openings.",[inquiry]).isEmpty,"complete direct inquiry")
 let hall=try item("The hall is unavailable. I might book the annex, but I'm unsure. Are there openings on Monday?")
 check(CanonicalGrounding.copyProblem("Texted Avery that the hall is unavailable, might book the annex, and asked about Monday openings.",hall)==0,"correct first raw factual projection no bag rejection")
 check(CanonicalGrounding.clausesMissing("Texted Avery that the gallery is unavailable and asked about Friday openings.",[inquiry]),"modality not waived by noun exemption")
 let draft=try item("Please inspect the upper shelf and mark the cracked tile.",state:"typed")
 check(CanonicalGrounding.missingDetails("Drafted a text to Avery asking to inspect the upper shelf and mark the cracked tile.",[draft]).isEmpty,"same draft requests without outcome promotion")
 check(!CanonicalGrounding.keepsQualityContent("Texted Avery asked to inspect the upper shelf and mark the cracked tile.","Texted Avery asked to inspect the upper shelf.",[draft]),"failed repair cannot lose original request")
 let associationRows=[
 ("room", "The room is unavailable. I might book the annex, but I'm unsure. Are there openings on Monday?", "Texted Avery that the room is booked, might try the annex, and asked whether Monday openings are unavailable."),
 ("diagram", "The diagram is not complete. Could you inspect the upper panel?", "Texted Avery that the diagram is complete, and asked not to inspect the upper panel."),
 ("question", "Are there openings on Monday?", "Texted Avery that Monday openings are confirmed, and asked about the weather.")]
 for (name,source,text) in associationRows {
  let owner=try item(source)
  check(CanonicalGrounding.changedNegativeStatement(text,[owner]),name+" independent false statement refused")
  check(!CanonicalGrounding.missingDetails(text,[owner]).isEmpty,name+" unrelated clause cannot supply coverage")
  let a=owner.actions[0]
  let data=try JSONSerialization.data(withJSONObject:["id":"fixture","schemaVersion":1,"targetKind":"activity","targetID":"fixture","day":"2026-09-30","timezone":"UTC","inputRevision":"fixture","policyRevision":"fixture","expiresAt":"2099-01-01T00:00:00Z","actions":try JSONSerialization.jsonObject(with:JSONEncoder().encode([a])),"actionCount":1])
  let req=try JSONDecoder().decode(CanonicalNoteRequest.self,from:data),view=try ModelView(request:req,actions:req.actions)
  let raw=String(decoding:try JSONSerialization.data(withJSONObject:["title":"Texts with Avery","bullets":[["ids":["i1"],"text":text]]]),as:UTF8.self)
  var refused=false
  do {_ = try CanonicalGrounding.validate(raw,request:req,view:view,provider:"local/qwen3.5-4b-q4_k_m")}catch {refused=true}
  check(refused,name+" full validator refuses false relation")
 }
 check(CanonicalGrounding.changedNegativeStatement("Texted Avery that the lobby is not reserved and the lobby is reserved.",[n]),"correct negative cannot rescue second opposite assertion")
 check(!CanonicalGrounding.missingDetails("Texted Avery checked the cable label and asked to flag the loose bracket.",[e]).isEmpty,"completed first action cannot borrow later inquiry")
 check(!CanonicalGrounding.changedNegativeStatement("Texted Avery that the room is unavailable and asked about Monday openings.",[try item("The room is unavailable. Are there openings on Monday?")]),"clause scoped truthful statement and inquiry retained")
 print("SUMMARY_CLAUSE_COVERAGE \(pass) PASS \(fail) FAIL")
 fflush(stdout)
 if fail>0 {throw WriterFailure.invalidOutput}
 }
}
