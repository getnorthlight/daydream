import Foundation
import WriterBackend

func require(_ ok: Bool, _ name: String) { print("\(ok ? "PASS" : "FAIL") \(name)"); if !ok { failures += 1 } else { passes += 1 } }
var failures=0, passes=0
func action(_ id:String,_ text:String,state:String="submitted",run:String?=nil,to:String="Avery") -> NoteAction {
 NoteAction(id:id,at:"2026-09-30T15:00:00Z",kind:"keyboard.text_input",app:"Messages",site:"",title:to,description:"Typed a draft in Messages. "+text,state:state,revision:"fixture",surface:"text",send:state=="submitted" ? "detected":"unknown",sendBy:state=="submitted" ? "return":nil,to:to,runID:run ?? id,field:"message")
}
func request(_ id:String,_ actions:[NoteAction]) throws -> CanonicalNoteRequest {
 let data=try JSONSerialization.data(withJSONObject:["id":id,"schemaVersion":1,"targetKind":"activity","targetID":id,"day":"2026-09-30","timezone":"UTC","inputRevision":id,"policyRevision":"fixture","expiresAt":"2099-01-01T00:00:00Z","actions":try JSONSerialization.jsonObject(with:JSONEncoder().encode(actions)),"actionCount":actions.count])
 return try JSONDecoder().decode(CanonicalNoteRequest.self,from:data)
}
func raw(_ title:String,_ bullets:[([String],String)]) throws -> String {
 String(decoding:try JSONSerialization.data(withJSONObject:["title":title,"bullets":bullets.map {["ids":$0.0,"text":$0.1] as [String:Any]}]),as:UTF8.self)
}
func validate(_ title:String,_ bullets:[([String],String)],_ r:CanonicalNoteRequest,_ v:ModelView) -> CanonicalNoteOutput? {
 try? CanonicalGrounding.validate(raw(title,bullets),request:r,view:v,provider:CanonicalLocalWriter.provider)
}

actor ScriptedRuntime:LocalInference {
 let answers:[String];let failSecond:Bool;var calls=0;var loads=0
 init(_ answers:[String],failSecond:Bool=false){self.answers=answers;self.failSecond=failSecond}
 func load() async throws {loads+=1}
 func unload() async {}
 func generate(instruction:String,evidence:String,maxTokens:Int) async throws -> Data {
 calls+=1
 if calls==2 && failSecond {throw WriterFailure.unavailable}
 guard calls<=answers.count else {throw WriterFailure.invalidOutput}
 return Data(answers[calls-1].utf8)
 }
 func count()->Int {calls}
}
@main struct SoftAbsenceChecks {
 static func main() async throws {
 let r=try request("absence",[action("a","The outline still lacks examples; could you suggest a concrete opening and mark the repetitive sections?")])
 let first=try raw("Outline feedback",[(["i1"],"Texted Avery asking for concrete opening examples and marking repetitive sections.")])
 let rich=try raw("Outline feedback",[(["i1"],"Texted Avery that the outline lacks examples, asked for a concrete opening, and requested marking repetitive sections.")])
 let normal=ScriptedRuntime([first,rich]),w=CanonicalLocalWriter(runtime:normal,policy:{_,_ in true})
 let n=try await w.generate(r,completeActions:r.actions)
 require(await normal.count()==2 && n.bullets.first?.text.contains("lacks examples")==true,"safe omission triggers one local repair that restores stated absence")
 require(n.bullets.first?.actionIDs==["a"] && n.bullets.first?.assertion=="submitted","quality repair retains exact source IDs and gesture confidence")
 for (name,replies,failSecond) in [
 ("invalid repair",[first,"{}"],false),
 ("inference failure",[first,rich],true),
 ("continued absence omission",[first,first],false),
 ("lost question framing",[first,try raw("Outline feedback",[(["i1"],"Texted Avery that the outline needs examples.")])],false),
 ("dropped marking request",[first,try raw("Outline feedback",[(["i1"],"Texted Avery that the outline lacks examples and asked for a concrete opening.")])],false),
 ("dropped concrete qualifier",[first,try raw("Outline feedback",[(["i1"],"Texted Avery that the outline lacks examples, asked for an opening, and requested marking repetitive sections.")])],false),
 ("confirmed outcome",[first,try raw("Outline feedback",[(["i1"],"Sent Avery the outline, confirmed its examples, and asked for feedback.")])],false),
 ("privacy failure",[first,try raw("Outline feedback",[(["i1"],"Texted Avery that password=secret-value lacks examples and asked for feedback.")])],false)
 ] {
 let runtime=ScriptedRuntime(replies,failSecond:failSecond),writer=CanonicalLocalWriter(runtime:runtime,policy:{_,_ in true})
 let result=try await writer.generate(r,completeActions:r.actions)
 require(await runtime.count()==2 && result.bullets.first?.text=="Texted Avery asking for concrete opening examples and marking repetitive sections.","safe first retained after "+name)
 }
 for source in ["The outline does not lack examples.","The outline is not missing examples.","The outline might lack examples.","The outline may be missing examples.","Is the outline missing examples?","The outline is missing examples?","If the outline is missing examples, check it.","The requirement that the outline lacks examples was removed.","The notice saying the room is missing is old.","Could you check whether the outline is missing examples?","I noticed that the outline is missing examples."] {
 let request=try request("negative",[action("n",source)])
 let runtime=ScriptedRuntime([try raw("Outline feedback",[(["i1"],"Texted Avery about the outline.")])])
 let writer=CanonicalLocalWriter(runtime:runtime,policy:{_,_ in true})
 _=try await writer.generate(request,completeActions:request.actions)
 require(await runtime.count()==1,"ambiguous/negated/observer source gets no quality inference: "+source)
 }
 let hidden=try request("hidden",[action("h","The diagnosis lacks details. Could you inspect it?")])
 let hiddenRuntime=ScriptedRuntime([try raw("Health discussion",[(["i1"],"Texted Avery a health question.")])])
 _=try await CanonicalLocalWriter(runtime:hiddenRuntime,policy:{_,_ in true}).generate(hidden,completeActions:hidden.actions)
 require(await hiddenRuntime.count()==1,"hidden health source cannot demand detail")
 let tail=try request("tail",[action("t",String(repeating:"The garden is green. ",count:100)+"The outline lacks examples.")])
 let tailRuntime=ScriptedRuntime([try raw("Garden discussion",[(["i1"],"Texted Avery about the garden.")])])
 _=try await CanonicalLocalWriter(runtime:tailRuntime,policy:{_,_ in true}).generate(tail,completeActions:tail.actions)
 require(await tailRuntime.count()==1,"source beyond visible1600 cannot demand detail")
 let separate=try request("separate",[action("x","The garden is green."),action("y","The outline lacks examples.")])
 let pair=try raw("Garden and outline",[(["i1"],"Texted Avery about the garden."),(["i2"],"Texted Avery that the outline needs examples.")])
 let separatedRuntime=ScriptedRuntime([pair])
 let separated=try await CanonicalLocalWriter(runtime:separatedRuntime,policy:{_,_ in true}).generate(separate,completeActions:separate.actions)
 require(await separatedRuntime.count()==1 && separated.bullets.map(\.actionIDs)==[["x"],["y"]],"absence in other item does not create a repair or cross-item association")

 let multi=try request("multi",[action("m1","The outline still lacks examples; could you suggest a concrete opening and mark the repetitive sections?"),action("m2","The garden is green.")])
 let beforeMulti=try raw("Outline and garden",[(["i1"],"Texted Avery asking for concrete opening examples and marking repetitive sections."),(["i2"],"Texted Avery about the garden.")])
 let changedOther=try raw("Outline and garden",[(["i1"],"Texted Avery that the outline lacks examples, asked for a concrete opening, and requested marking repetitive sections."),(["i2"],"Texted Avery about garden planning.")])
 let multiRuntime=ScriptedRuntime([beforeMulti,changedOther])
 let multiResult=try await CanonicalLocalWriter(runtime:multiRuntime,policy:{_,_ in true}).generate(multi,completeActions:multi.actions)
 require(await multiRuntime.count()==2 && multiResult.bullets.map(\.text)==["Texted Avery asking for concrete opening examples and marking repetitive sections.","Texted Avery about the garden."],"quality repair cannot paraphrase another independent action")
 print("TOTAL \(passes) PASS \(failures) FAIL");if failures>0{exit(1)}
 }
}
