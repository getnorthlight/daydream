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
@main struct AbsencePolarityChecks {
 static func main()throws {
 let source="The equipment checklist still lacks a calibration step; please check the cable label and flag the loose bracket."
 let owner=try item(source)
 let a=owner.actions[0]
 let data=try JSONSerialization.data(withJSONObject:["id":"fixture","schemaVersion":1,"targetKind":"activity","targetID":"fixture","day":"2026-09-30","timezone":"UTC","inputRevision":"fixture","policyRevision":"fixture","expiresAt":"2099-01-01T00:00:00Z","actions":try JSONSerialization.jsonObject(with:JSONEncoder().encode([a])),"actionCount":1])
 let req=try JSONDecoder().decode(CanonicalNoteRequest.self,from:data),view=try ModelView(request:req,actions:req.actions)
 for predicate in ["no longer lacks","does not lack","doesn't lack","is not missing"] {
  let text="Texted Avery that the equipment checklist "+predicate+" a calibration step, requested a check of the cable label, and asked to flag the loose bracket."
  check(CanonicalGrounding.changedNegativeStatement(text,[owner]),predicate+" cannot negate captured absence")
  check(!CanonicalGrounding.missingDetails(text,[owner]).isEmpty,predicate+" does not cover source absence")
  let raw=String(decoding:try JSONSerialization.data(withJSONObject:["title":"Texts with Avery","bullets":[["ids":["i1"],"text":text]]]),as:UTF8.self)
  var refused=false;do {_ = try CanonicalGrounding.validate(raw,request:req,view:view,provider:"local/qwen3.5-4b-q4_k_m")}catch {refused=true}
  check(refused,predicate+" full validator refuses")
 }
 let correct="Texted Avery that the equipment checklist lacks a calibration step, requested a check of the cable label, and asked to flag the loose bracket."
 check(!CanonicalGrounding.changedNegativeStatement(correct,[owner]),"ordinary missing fact still retained")
 check(!CanonicalGrounding.changedNegativeStatement(correct+" The other list does not lack an index.",[owner]),"unrelated subject cannot falsify original absence")
 check(!CanonicalGrounding.changedNegativeStatement(correct+" The equipment checklist does not lack an index.",[owner]),"different missing object cannot falsify calibration fact")
 check(CanonicalGrounding.changedNegativeStatement(correct+" And the equipment checklist does not lack a calibration step.",[owner]),"correct clause cannot rescue contradictory second same-subject object")
 print("SUMMARY_ABSENCE_POLARITY \(pass) PASS \(fail) FAIL");fflush(stdout)
 if fail>0 {throw WriterFailure.invalidOutput}
 }
}
