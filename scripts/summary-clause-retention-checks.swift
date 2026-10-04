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
@main struct RetentionChecks {
 static func main()throws {
 let e=try item("The equipment checklist still lacks a calibration step; please check the cable label and flag the loose bracket.")
 let old="Texted Avery about the missing calibration step in the equipment checklist."
 let complete="Texted Avery that the equipment checklist lacks a calibration step, requested a check of the cable label, and asked to flag the loose bracket."
 check(!CanonicalGrounding.keepsQualityContent(old,complete,[e]),"ordinary lexical before guard refuses finite absence form")
 check(CanonicalGrounding.keepsSourceQualityContent(old,complete,[e]),"same captured absence finite form preserves useful requests")
 check(CanonicalGrounding.keepsSourceQualityContent(complete,complete.replacingOccurrences(of:"lacks",with:"is missing"),[e]),"same captured absence reverse finite form")
 check(!CanonicalGrounding.keepsSourceQualityContent(old,"Texted Avery that the calibration step is present in the equipment checklist.",[e]),"absence cannot become affirmative")
 check(!CanonicalGrounding.keepsSourceQualityContent(old,"Texted Avery that the unrelated checklist lacks a calibration step.",[e]),"absence subject cannot change")
 check(!CanonicalGrounding.keepsSourceQualityContent(complete,"Texted Avery about the missing calibration step in the equipment checklist and requested checking the cable label.",[e]),"finite absence form cannot drop second request")
 let m=try item("The mural is not finished. Please review the corner pattern and mark the faint line.")
 let mo="Texted Avery that the mural is unfinished and asked for a review of the corner pattern and faint line."
 let mr="Texted Avery that the mural is not finished, requested a review of the corner pattern, and asked to mark the faint line."
 check(!CanonicalGrounding.keepsQualityContent(mo,mr,[m]),"ordinary lexical before guard refuses finite negative form")
 check(CanonicalGrounding.keepsSourceQualityContent(mo,mr,[m]),"same captured negative finite form preserves added mark request")
 check(CanonicalGrounding.keepsSourceQualityContent(mr,"Texted Avery that the mural is unfinished, requested a review of the corner pattern, and asked to mark the faint line.",[m]),"same captured negative reverse finite form")
 check(!CanonicalGrounding.keepsSourceQualityContent(mo,"Texted Avery that the mural is finished and asked for a review of the corner pattern and faint line.",[m]),"negative finite form cannot become finished")
 check(!CanonicalGrounding.keepsSourceQualityContent(mo,"Texted Avery that the diagram is not finished and asked for a review of the corner pattern and faint line.",[m]),"negative finite form cannot borrow another subject")
 check(!CanonicalGrounding.keepsSourceQualityContent(mr,"Texted Avery that the mural is unfinished and asked to review the corner pattern.",[m]),"negative finite form cannot drop faint-line request")
 let unknown=try item("The mural is not finished. Please review the corner pattern and mark the faint line.",to:"unknown")
 check(!CanonicalGrounding.keepsSourceQualityContent(mo,mr,[unknown]),"unknown recipient gains no finite exception")
 let long=try item("The mural is not finished. Please review the corner pattern and mark the faint line."+String(repeating:" extra",count:70))
 check(!CanonicalGrounding.keepsSourceQualityContent(mo,mr,[long]),"long source gains no finite exception")
 let contextualOld=old+" Might check Monday."
 check(!CanonicalGrounding.keepsSourceQualityContent(contextualOld,complete+" Check Monday.",[e]),"uncertainty content preserved")
 check(!CanonicalGrounding.keepsSourceQualityContent(contextualOld,complete+" Might check Tuesday.",[e]),"day qualifier preserved")
 let notice=try item("I noticed that the meeting notice is missing the room number. Could you confirm its start time and add arrival directions?")
 let malformed="Texted Avery to confirm the meeting start time and add arrival directions."
 check(CanonicalGrounding.copyProblem(malformed,notice)>0,"malformed copied candidate remains refused")
 let hint=CanonicalGrounding.repeatedContentHint(malformed,[notice])
 check(hint.contains("Missing source clauses:") && hint.contains("room") && hint.contains("confirm"),"source eligible repair feedback keeps omitted source clauses")
 check(CanonicalGrounding.copyProblem(malformed,notice)>0,"repair hint never changes copy admission")
 check(!CanonicalGrounding.repeatedContentHint(malformed,[try item(notice.text ?? "",to:"unknown")]).contains("Missing source clauses:"),"hint cannot invent unknown recipient authority")
 print("SUMMARY_CLAUSE_RETENTION \(pass) PASS \(fail) FAIL");fflush(stdout)
 if fail>0 {throw WriterFailure.invalidOutput}
 }
}
