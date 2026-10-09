// Summary clause checks: what a model's summary line must keep of what was typed (each request, a stated absence or
// negation, its subject and qualifiers), and what the validator and the local writer's one repair do about it.
// One file for what were five (clause coverage, absence polarity, clause retention, nominal requests, soft absence);
// each is one function below, and every assertion reports. Synthetic text only; the local writer runs on a scripted
// runtime (no model is loaded).
import Foundation
@testable import WriterBackend

var passes = 0, failures = 0
func check(_ ok: Bool, _ label: String) { print((ok ? "PASS " : "FAIL ") + label); if ok { passes += 1 } else { failures += 1 } }
func item(_ text:String,to:String="Avery",title:String="Avery",run:String?="fixture",state:String="submitted")throws->ModelItem {
 let a=NoteAction(id:"a1",at:"2026-09-30T15:00:00Z",kind:"keyboard.text_input",app:"Messages",site:"",title:title,description:"Typed a draft in Messages. "+text,state:state,revision:"fixture",surface:"text",send:state=="submitted" ? "detected":"unknown",sendBy:state=="submitted" ? "return":nil,to:to,runID:run,field:"message")
 let data=try JSONSerialization.data(withJSONObject:["id":"fixture","schemaVersion":1,"targetKind":"activity","targetID":"fixture","day":"2026-09-30","timezone":"UTC","inputRevision":"fixture","policyRevision":"fixture","expiresAt":"2099-01-01T00:00:00Z","actions":try JSONSerialization.jsonObject(with:JSONEncoder().encode([a])),"actionCount":1])
 let req=try JSONDecoder().decode(CanonicalNoteRequest.self,from:data)
 return try ModelView(request:req,actions:req.actions).items[0]
}
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

/// Each source clause (a stated absence, each request) is covered once, with its own verb, target and polarity.
func clauseCoverage() throws {
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
}

/// A captured absence ("still lacks") is never summarised as present.
func absencePolarity() throws {
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
}

/// A rewrite of a summary line keeps every clause of what was typed, in a finite or a nominal form.
func clauseRetention() throws {
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
 // A text's gist ("Texted Avery to ...") keeps core's own copy rule since 1f22c5b (owner, messages-1003): it may say
 // what was sent in its words. Any other lead still has the writer's copy rule, which this repair feedback serves.
 check(CanonicalGrounding.copyProblem("Texted Avery to confirm the meeting start time and add arrival directions.",notice)==0,
       "a sent text's gist may keep its content words (owner rule, 10/03)")
 let malformed="Messaged Avery to confirm the meeting start time and add arrival directions."
 check(CanonicalGrounding.copyProblem(malformed,notice)>0,"malformed copied candidate remains refused")
 let hint=CanonicalGrounding.repeatedContentHint(malformed,[notice])
 check(hint.contains("Missing source clauses:") && hint.contains("room") && hint.contains("confirm"),"source eligible repair feedback keeps omitted source clauses")
 check(CanonicalGrounding.copyProblem(malformed,notice)>0,"repair hint never changes copy admission")
 check(!CanonicalGrounding.repeatedContentHint(malformed,[try item(notice.text ?? "",to:"unknown")]).contains("Missing source clauses:"),"hint cannot invent unknown recipient authority")
}

/// A request said as a noun ("asked for a concrete opening suggestion") covers the same request, nothing more.
func requestNominal() throws {
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
}

/// The local writer's one quality repair: only when a stated absence was dropped, and never at a safe line's expense.
func softAbsence() async throws {
 let r=try request("absence",[action("a","The outline still lacks examples; could you suggest a concrete opening and mark the repetitive sections?")])
 let first=try raw("Outline feedback",[(["i1"],"Texted Avery asking for concrete opening examples and marking repetitive sections.")])
 // The repair names every clause, the suggestion as a noun (83ba79c); "asked for a concrete opening" alone drops the
 // "suggest" request, which a03ea84's detail rule refuses.
 let rich=try raw("Outline feedback",[(["i1"],"Texted Avery that the outline lacks examples, asked for a concrete opening suggestion, and requested marking of repetitive sections.")])
 let normal=ScriptedRuntime([first,rich]),w=CanonicalLocalWriter(runtime:normal,policy:{_,_ in true})
 let n=try await w.generate(r,completeActions:r.actions)
 check(await normal.count()==2 && n.bullets.first?.text.contains("lacks examples")==true,"safe omission triggers one local repair that restores stated absence")
 check(n.bullets.first?.actionIDs==["a"] && n.bullets.first?.assertion=="submitted","quality repair retains exact source IDs and gesture confidence")
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
 check(await runtime.count()==2 && result.bullets.first?.text=="Texted Avery asking for concrete opening examples and marking repetitive sections.","safe first retained after "+name)
 }
 for source in ["The outline does not lack examples.","The outline is not missing examples.","The outline might lack examples.","The outline may be missing examples.","Is the outline missing examples?","The outline is missing examples?","If the outline is missing examples, check it.","The requirement that the outline lacks examples was removed.","The notice saying the room is missing is old.","Could you check whether the outline is missing examples?","I noticed that the outline is missing examples."] {
 let request=try request("negative",[action("n",source)])
 let runtime=ScriptedRuntime([try raw("Outline feedback",[(["i1"],"Texted Avery about the outline.")])])
 let writer=CanonicalLocalWriter(runtime:runtime,policy:{_,_ in true})
 let result=try await writer.generate(request,completeActions:request.actions)
 // a03ea84 asks for one repair when a negative or uncertain clause is missing too (preserve it, never flip it); the
 // repair here fails, and what matters is that nothing infers an absence: the safe line stays as it was.
 check(await runtime.count()<=2 && result.bullets.map(\.text)==["Texted Avery about the outline."],
       "ambiguous/negated/observer source: no absence inferred, the safe line stays: "+source)
 }
 let hidden=try request("hidden",[action("h","The diagnosis lacks details. Could you inspect it?")])
 let hiddenRuntime=ScriptedRuntime([try raw("Health discussion",[(["i1"],"Texted Avery a health question.")])])
 _=try await CanonicalLocalWriter(runtime:hiddenRuntime,policy:{_,_ in true}).generate(hidden,completeActions:hidden.actions)
 check(await hiddenRuntime.count()==1,"hidden health source cannot demand detail")
 let tail=try request("tail",[action("t",String(repeating:"The garden is green. ",count:100)+"The outline lacks examples.")])
 let tailRuntime=ScriptedRuntime([try raw("Garden discussion",[(["i1"],"Texted Avery about the garden.")])])
 _=try await CanonicalLocalWriter(runtime:tailRuntime,policy:{_,_ in true}).generate(tail,completeActions:tail.actions)
 check(await tailRuntime.count()==1,"source beyond visible1600 cannot demand detail")
 // Two people, two conversations. Since b2e7d34 the local writer writes each typed run on its own view (one call each,
 // so nothing can cross between them), and since 1f22c5b texts to one person are one conversation.
 let separate=try request("separate",[action("x","The garden is green.",to:"Blake"),action("y","The outline lacks examples.")])
 let separatedRuntime=ScriptedRuntime([try raw("Garden",[(["i1"],"Texted Blake about the garden.")]),
                                       try raw("Outline",[(["i1"],"Texted Avery that the outline needs examples.")])])
 let separated=try await CanonicalLocalWriter(runtime:separatedRuntime,policy:{_,_ in true}).generate(separate,completeActions:separate.actions)
 check(await separatedRuntime.count()==2 && separated.bullets.map(\.actionIDs)==[["x"],["y"]],
       "an absence said in other words gets no repair, and each conversation keeps its own line")

 let multi=try request("multi",[action("m1","The outline still lacks examples; could you suggest a concrete opening and mark the repetitive sections?"),action("m2","The garden is green.",to:"Blake")])
 let multiRuntime=ScriptedRuntime([try raw("Outline",[(["i1"],"Texted Avery asking for concrete opening examples and marking repetitive sections.")]),
                                   rich, try raw("Garden",[(["i1"],"Texted Blake about the garden.")])])
 let multiResult=try await CanonicalLocalWriter(runtime:multiRuntime,policy:{_,_ in true}).generate(multi,completeActions:multi.actions)
 check(await multiRuntime.count()==3 && multiResult.bullets.map(\.text)==["Texted Avery that the outline lacks examples, asked for a concrete opening suggestion, and requested marking of repetitive sections.","Texted Blake about the garden."]
       && multiResult.bullets.map(\.actionIDs)==[["m1"],["m2"]],
       "a quality repair changes only its own conversation's line")
}

@main struct SummaryClauseChecks {
 static func main() async {
  setvbuf(stdout, nil, _IOLBF, 0)
  let sync: [(String, () throws -> Void)] = [("clause coverage", clauseCoverage), ("absence polarity", absencePolarity),
                                             ("clause retention", clauseRetention), ("nominal requests", requestNominal)]
  for (name, run) in sync {
   do { try run() } catch { check(false, name + " stopped: \(error)") }
  }
  do { try await softAbsence() } catch { check(false, "soft absence stopped: \(error)") }
  print("\(passes) summary clause checks passed, \(failures) failed. Synthetic text only; no model loaded.")
  if failures > 0 { exit(1) }
 }
}
