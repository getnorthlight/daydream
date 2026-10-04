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
@main struct NominalRequestChecks {
 static func main()throws {
 let i=try item("The outline still lacks examples; could you suggest a concrete opening and mark the repetitive sections?")
 let correct="Texted Avery that the outline lacks examples, asked for a concrete opening suggestion, and requested marking of repetitive sections."
 check(CanonicalGrounding.missingDetails(correct,[i]).isEmpty,"nominal suggestion retains source-directed opening request")
 check(CanonicalGrounding.missingDetails("Texted Avery that the outline lacks examples, requested a suggestion for a concrete opening, and asked to mark the repetitive sections.",[i]).isEmpty,"preposed nominal same owned request")
 check(!CanonicalGrounding.missingDetails("Texted Avery that the outline lacks examples, asked to review a concrete opening suggestion, and requested marking repetitive sections.",[i]).isEmpty,"review over suggestion cannot become suggest action")
 check(!CanonicalGrounding.missingDetails("Texted Avery that the outline lacks examples, asked for a repetitive section suggestion, and requested marking the concrete opening.",[i]).isEmpty,"same nouns swapped nominal request targets refused")
 check(!CanonicalGrounding.missingDetails("Texted Avery that the outline lacks examples, reported a concrete opening suggestion, and asked to mark repetitive sections.",[i]).isEmpty,"reported suggestion cannot become requested suggestion")
 check(!CanonicalGrounding.missingDetails("Texted Avery that the outline lacks examples, asked for a vague closing suggestion, and requested marking repetitive sections.",[i]).isEmpty,"qualifier and object preserved")
 check(!CanonicalGrounding.missingDetails("Texted Avery that the outline lacks examples and asked for a concrete opening suggestion.",[i]).isEmpty,"nominal opening cannot hide lost marking request")
 let checkSource=try item("Could you check the concrete opening suggestion?")
 check(!CanonicalGrounding.missingDetails("Texted Avery asking for a concrete opening suggestion.",[checkSource]).isEmpty,"noun suggestion cannot replace captured check action")
 check(CanonicalGrounding.sourceDetails(try item(i.text ?? "",to:"unknown")).isEmpty,"nominal grammar never grants unknown authority")
 let old="Texted Avery asking for concrete opening examples and marking repetitive sections."
 check(CanonicalGrounding.keepsSourceQualityContent(old,correct,[i]),"actual rich model repair preserves original tokens")
 print("SUMMARY_REQUEST_NOMINAL \(pass) PASS \(fail) FAIL");fflush(stdout)
 if fail>0 {throw WriterFailure.invalidOutput}
 }
}
