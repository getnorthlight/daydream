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
actor LoadCounter:LocalInference {
 var loads=0
 func load() async throws {loads+=1}
 func unload() async {}
 func generate(instruction:String,evidence:String,maxTokens:Int) async throws -> Data {Data("{}".utf8)}
 func count()->Int {loads}
}
@main struct SummaryCoherenceChecks {
 static func main() async throws {
  let garden=try request("garden",[action("g1","The north bed needs seedlings soon; could you look over my planting sketch?")])
  let gv=try ModelView(request:garden,actions:garden.actions)
  let a=gv.items[0].alias
  let duplicate=[([a],"Texted Avery about the garden plan."),([a],"Texted Avery asking about the garden layout.")]
  require(validate("Garden planning",duplicate,garden,gv)==nil,"same action's messaging paraphrases require one coherent bullet")
  let good=validate("Garden planning",[duplicate[0]],garden,gv)
  require(good != nil,"one supported messaging bullet remains valid")
  let wrongTitle=validate("Drafted a text to Avery",[duplicate[0]],garden,gv)
  require(wrongTitle != nil && !(wrongTitle!.title.lowercased().hasPrefix("drafted")),"draft title cannot hide an observed submission")
  require(wrongTitle?.bullets.first?.assertion=="submitted","gesture remains submitted, never confirmed sent")
  require(validate("Garden planning",[([a],"Sent Avery the garden plan.")],garden,gv)==nil,"confirmed-send wording still requires receipt")
  let draft=try request("draft",[action("d1","The planter might arrive tomorrow; the sketch is still unfinished.",state:"typed")])
  let dv=try ModelView(request:draft,actions:draft.actions)
  let da=dv.items[0].alias
  require(validate("Garden planning",[([da],"Drafted a text to Avery about the garden plan.")],draft,dv) != nil,"genuine draft remains a draft")
  require(validate("Garden planning",[([da],"Texted Avery about the garden plan.")],draft,dv)==nil,"draft cannot acquire a submission")
  let separate=try request("separate",[action("s1","Could you look over the planting sketch?"),action("s2","The courier lost my parcel; can you check the delivery desk?",to:"Blair")])
  let sv=try ModelView(request:separate,actions:separate.actions)
  require(sv.items.filter {$0.kind == .typed}.count==2 && sv.items.filter {$0.kind == .typed}.allSatisfy {$0.actions.count==1},"distinct messages to different people retain independent items")
  // messages-1003 (owner 10/3): texts to one person are one conversation item, its texts in order.
  let convo=try request("convo",[action("c1","Could you look over the planting sketch?"),action("c2","The courier lost my parcel; can you check the delivery desk?")])
  let cvw=try ModelView(request:convo,actions:convo.actions)
  require(cvw.items.filter {$0.kind == .typed}.count==1 && cvw.items.first(where:{$0.kind == .typed})?.actions.count==2,"texts to the same person are one conversation item")
  if sv.items.filter({$0.kind == .typed}).count==2 {
   let ids=sv.items.filter {$0.kind == .typed}.map(\.alias)
   require(validate("Garden and delivery",[(ids,"Texted Avery about the garden and delivery.")],separate,sv)==nil,"shared words cannot merge messages to different people")
   require(validate("Garden and delivery",[([ids[0]],"Texted Avery about the garden plan."),([ids[1]],"Texted Blair about a missing parcel.")],separate,sv) != nil,"separate facts retain separately cited summary bullets")
  }
  let split=try request("split",[action("r1","Could you look over the planting",state:"typed",run:"same-run"),action("r2","sketch when you have time?",run:"same-run")])
  let rv=try ModelView(request:split,actions:split.actions)
  require(rv.items.filter {$0.kind == .typed}.count==1 && Set(rv.items[0].actions.map(\.id))==["r1","r2"],"observable typing run still keeps all child IDs")
  let clubText="Hey Avery, I didn't get into ASC this round. I might apply again, but I'm not sure. Do they recruit in spring?"
  let club=try request("club",[action("c1",clubText)])
  let cv=try ModelView(request:club,actions:club.actions)
  let rich="Texted Avery that the ASC application was unsuccessful, might reapply, and asked about spring recruitment."
  let cn=validate("ASC application and recruitment",[([cv.items[0].alias],rich)],club,cv)
  require(cn != nil,"supported result, uncertainty, and next-season question fit one concise summary")
  require(cv.items[0].text==clubText,"writer view preserves the entire permitted short fixture")
  let defined=try request("defined",[action("e1","The Astronomy Society Club (ASC) application is the one we discussed.",run:"club-run"),action("e2",clubText,run:"club-run")])
  let ev=try ModelView(request:defined,actions:defined.actions)
  let expanded="Texted Avery that the Astronomy Society Club application was unsuccessful, might reapply, and asked about spring recruitment."
  let en=validate("Club application and recruitment",[([ev.items[0].alias],expanded)],defined,ev)
  require(ev.items.count==1 && Set(ev.items[0].actions.map(\.id))==["e1","e2"] && en != nil,"explicit captured same-run definition supports expansion with both source IDs")
  let normalized=validate("ASC application",[( [ev.items[0].alias],rich)],defined,ev)
  require(normalized?.bullets.first?.text.contains("Astronomy Society Club")==true && normalized?.title=="ASC application","same cited visible definition restores full name in bullet without expanding the title")
  require(normalized?.bullets.first?.actionIDs==["e1","e2"] && normalized?.bullets.first?.assertion=="submitted","explicit expansion preserves original child IDs and submission confidence")
  require(cn?.bullets.first?.text.contains("Astronomy")==false && cn?.bullets.first?.text.contains("ASC")==true,"undefined acronym remains exactly its captured abbreviation")
  let conflicting=try request("conflicting",[action("cf1","Astronomy Society Club (ASC) is an application. Advanced Systems Council (ASC) is another application.")]),conflictView=try ModelView(request:conflicting,actions:conflicting.actions)
  let conflictNote=validate("ASC application",[([conflictView.items[0].alias],"Texted Avery about the ASC application.")],conflicting,conflictView)
  require(conflictNote != nil && conflictNote!.bullets.first!.text.contains("ASC") && !conflictNote!.bullets.first!.text.contains("Astronomy"),"conflicting explicit definitions never choose an expansion")
  let hiddenAlias=try request("hidden-alias",[action("ha1",String(repeating:"The garden needs more shade. ",count:80)+"Astronomy Society Club (ASC) application.")]),hiddenAliasView=try ModelView(request:hiddenAlias,actions:hiddenAlias.actions)
  let hiddenAliasNote=validate("ASC application",[([hiddenAliasView.items[0].alias],"Texted Avery about the ASC application.")],hiddenAlias,hiddenAliasView)
  require(hiddenAliasNote?.bullets.first?.text.contains("Astronomy Society Club") != true,"definition after the visible1600-character boundary cannot expand a bullet")
  let longName=String(repeating:"Extraordinarily ",count:10)+"Long Council"
  let longConflict=try request("long-conflict",[action("lc1","Astronomy Society Club (ASC). "+longName+" (ASC).")]),longConflictView=try ModelView(request:longConflict,actions:longConflict.actions)
  let longConflictNote=validate("ASC discussion",[([longConflictView.items[0].alias],"Texted Avery about ASC.")],longConflict,longConflictView)
  require(longConflictNote != nil && longConflictNote!.bullets.first!.text.contains("ASC") && !longConflictNote!.bullets.first!.text.contains("Astronomy"),"an over-budget conflicting definition is counted instead of silently choosing a shorter name")
  let recursive=try request("recursive-alias",[action("ra1","Artificial Intelligence (AI). AI Council (AIC).")]),recursiveView=try ModelView(request:recursive,actions:recursive.actions)
  let recursiveNote=validate("Council discussion",[([recursiveView.items[0].alias],"Texted Avery about AIC.")],recursive,recursiveView)
  require(recursiveNote?.bullets.first?.text.contains("AI Council")==true && recursiveNote?.bullets.first?.text.contains("Artificial Intelligence Council")==false,"inserted full names are never recursively expanded through other definitions")
  for (id,source,alias,expected) in [
   ("for","The Center for Atmospheric Research (CAR) application was discussed.","CAR","Center for Atmospheric Research"),
   ("in","The Council in Natural Sciences (CNS) application was discussed.","CNS","Council in Natural Sciences"),
   ("at","The Center at River Junction (CRJ) application was discussed.","CRJ","Center at River Junction")
  ] {
   let r=try request("connector-"+id,[action("connector-"+id,source)]),v=try ModelView(request:r,actions:r.actions)
   let n=validate("Council application",[([v.items[0].alias],"Texted Avery about "+alias+".")],r,v)
   require(n?.bullets.first?.text=="Texted Avery about "+expected+".","full explicit name retains "+id+" connector without selecting a suffix")
  }
  let unsupported=try request("unsupported-name",[action("un1","The Center under Atmospheric Research (CAR) application was discussed.")]),unsupportedView=try ModelView(request:unsupported,actions:unsupported.actions)
  let unsupportedNote=validate("Council application",[([unsupportedView.items[0].alias],"Texted Avery about CAR.")],unsupported,unsupportedView)
  require(unsupportedNote?.bullets.first?.text=="Texted Avery about CAR.","unsupported name phrase never expands to its capitalized suffix")
  let partialConflict=try request("partial-conflict",[action("pc1","Astronomy Society Club (ASC). The Center under Astronomy Research (ASC).")]),partialConflictView=try ModelView(request:partialConflict,actions:partialConflict.actions)
  let partialConflictNote=validate("ASC discussion",[([partialConflictView.items[0].alias],"Texted Avery about ASC.")],partialConflict,partialConflictView)
  require(partialConflictNote?.bullets.first?.text=="Texted Avery about ASC.","recognized plus unsupported same-alias definition remains ambiguous")
  let overlong=try request("overlong-name",[action("ol1",longName+" (ELC) application was discussed.")]),overlongView=try ModelView(request:overlong,actions:overlong.actions)
  let overlongNote=validate("Council application",[([overlongView.items[0].alias],"Texted Avery about ELC.")],overlong,overlongView)
  require(overlongNote?.bullets.first?.text=="Texted Avery about ELC.","unique definition above120 characters stays abbreviated without suffix expansion")
  let privacyAlias=try request("privacy-alias",[action("pa1","The Medical Research Council (MRC) lab results arrived.")]),privacyAliasView=try ModelView(request:privacyAlias,actions:privacyAlias.actions)
  let privacyAliasNote=validate("Medical inquiry",[([privacyAliasView.items[0].alias],"Texted Avery about MRC.")],privacyAlias,privacyAliasView)
  require(privacyAliasNote?.bullets.first?.text.contains("Medical Research Council") != true,"masked medical definition never grants full-name expansion")
  require(validate("Club application",[([cv.items[0].alias],expanded)],club,cv)==nil,"unknown acronym never acquires an outside expansion")
  let unrelated=try request("unrelated",[action("z1","The Astronomy Society Club (ASC) application is the one we discussed."),action("z2",clubText,to:"Blair")])
  let uv=try ModelView(request:unrelated,actions:unrelated.actions)
  if let later=uv.items.first(where:{$0.actions.contains(where:{$0.id=="z2"})}) {
   require(validate("Club application",[([later.alias],expanded.replacingOccurrences(of:"Avery",with:"Blair"))],unrelated,uv)==nil,"another conversation cannot establish the acronym")
  } else {require(false,"later independent item remains available")}
  let splitNote=validate("Separate club messages",[([uv.items[0].alias],"Texted Avery about the Astronomy Society Club application."),([uv.items[1].alias],rich.replacingOccurrences(of:"Avery",with:"Blair"))],unrelated,uv)
  require(splitNote != nil && splitNote!.bullets.first(where:{$0.actionIDs==["z2"]})!.text.contains("ASC") && !splitNote!.bullets.first(where:{$0.actionIDs==["z2"]})!.text.contains("Astronomy"),"definition in another independently cited item never expands the later bullet")
  let mixed=try request("mixed",[action("m1","Could you check the seed order?"),action("m2","I might need another planter.",state:"typed",to:"Blair")])
  let mv=try ModelView(request:mixed,actions:mixed.actions)
  let ma=mv.items.first(where:{$0.actions.contains(where:{$0.id=="m1"})})!.alias
  let md=mv.items.first(where:{$0.actions.contains(where:{$0.id=="m2"})})!.alias
  let mn=validate("Drafted a text to Avery",[([ma],"Texted Avery about the seed order."),([md],"Drafted a text to Blair about another planter.")],mixed,mv)
  require(mn != nil && !mn!.title.lowercased().hasPrefix("drafted") && Set(mn!.bullets.map(\.assertion))==["submitted","draft"],"mixed draft and submission keep separately cited outcomes and coherent title")
  require(validate("ASC application",[([cv.items[0].alias],"Texted Avery about applying to ASC again.")],club,cv)==nil,"topic-only account cannot discard a captured uncertain plan and question")
  // These are actual rejection contracts, not simulated model quality claims.
  func rejection(_ title:String,_ line:String,_ r:CanonicalNoteRequest,_ v:ModelView)->WriterRejection? {
   do {_ = try CanonicalGrounding.validate(raw(title,[([v.items[0].alias],line)]),request:r,view:v,provider:CanonicalLocalWriter.provider);return nil}
   catch {return error as? WriterRejection}
  }
  let userRepair=rejection("ASC application","Texted Avery that the user might apply again and asked about spring recruitment.",club,cv)
  require(userRepair?.code=="user" && userRepair!.reason.contains("never write") && !userRepair!.reason.contains("implied"),"pronoun repair gives the same no-personal-subject contract as validation")
  let parcel=try request("parcel-copy",[action("p1","The courier lost my parcel; can you check the delivery desk?")])
  let pv=try ModelView(request:parcel,actions:parcel.actions)
  let copyRepair=rejection("Parcel inquiry","Texted Avery about the lost parcel and asked to check the delivery desk.",parcel,pv)
  require(copyRepair?.code=="copy" && copyRepair!.reason.contains("preserving every captured statement and request") && !copyRepair!.reason.contains("8 words"),"copy repair retains facts and requests without an eight-word bullet demand")
  require(copyRepair?.reason.contains("Repeated ordinary content words by item: i1:")==true && copyRepair!.reason.contains("\"parcel\"") && copyRepair!.reason.contains("\"desk\""),"copy repair names visible repeated content words with their exact item owner")
  require(copyRepair?.reason.contains("\"courier\"")==false && copyRepair?.reason.contains("\"avery\"")==false,"replacement targets exclude uncopied content and exact recipient names")
  let owner=try request("copy-owner",[action("owner1","The courier lost my parcel; can you check the delivery desk?"),action("owner2","The courier lost my parcel; can you check the delivery desk?")]),ownerView=try ModelView(request:owner,actions:owner.actions)
  let ownedRepair=rejection("Parcel inquiry","Texted Avery about the lost parcel and asked to check the delivery desk.",owner,ownerView)
  require(ownedRepair?.code=="copy" && ownedRepair!.reason.contains("i1:") && !ownedRepair!.reason.contains("i2:"),"copy hints cannot attach uncited independent typing owners")
  let tail=try request("unseen-copy",[action("z9",String(repeating:"The garden needs more shade. ",count:80)+"The hidden orchard sentinel phrase.")]),tailView=try ModelView(request:tail,actions:tail.actions)
  let tailRepair=rejection("Question for Avery","Texted Avery about the hidden orchard sentinel phrase.",tail,tailView)
  // messages-1003: a text's gist may echo its words (the writer's raw copy rule is skipped; core's verbatim guard still
  // decides at commit), so this line may pass; when a copy repair comes, it never hints at words the model couldn't see.
  require(tailRepair == nil || (tailRepair?.code=="copy" && !tailRepair!.reason.contains("Repeated ordinary content words")),"copy hints never add source words after the model-visible truncation boundary")
  let masked=try request("masked-copy",[action("z8","The lab results arrived. I might call again, although I am unsure. Can someone help?")]),maskedView=try ModelView(request:masked,actions:masked.actions)
  let maskedRepair=rejection("Health inquiry","Texted Avery about the lab results and asked for help.",masked,maskedView)
  require(maskedRepair != nil && !maskedRepair!.reason.contains("Repeated ordinary content words"),"copy hints never disclose masked health source words")
  require(validate("Parcel inquiry",[([pv.items[0].alias],"Texted Avery about a missing package and requested an inspection of the delivery counter.")],parcel,pv) != nil,"both parcel facts can survive the unchanged copy gate through paraphrase")
  let repairedParcel=try raw("Parcel inquiry",[([pv.items[0].alias],"Texted Avery that the courier lost the parcel and asked to check the delivery desk.")])
  let salvagedParcel=try? CanonicalGrounding.salvage(repairedParcel,request:parcel,view:pv,provider:CanonicalLocalWriter.provider)
  require(salvagedParcel?.bullets.allSatisfy {$0.text != "Texted Avery that the courier lost the parcel."} ?? true,"salvage never turns a failed multi-clause typed account into a misleading clipped statement")
  let separateRepair=try raw("Parcel and sketch with Avery",[([sv.items[0].alias],"Texted Avery to review the planting sketch."),([sv.items[1].alias],"Texted Blair that the courier lost the parcel and asked to check the delivery desk.")])
  let separateSalvage=try? CanonicalGrounding.salvage(separateRepair,request:separate,view:sv,provider:CanonicalLocalWriter.provider)
  require(separateSalvage?.bullets.filter {$0.actionIDs==["s2"]}.allSatisfy {!$0.text.lowercased().contains("sketch")} ?? true,"whole-note title cannot carry one independent message's subject into another salvaged message")
  let light=try request("light-qualifier",[action("h1","The rear light stopped working. I might replace the battery, although I am unsure. Is the repair stall open on Sunday?")]),lightView=try ModelView(request:light,actions:light.actions)
  require(validate("Rear light repair",[([lightView.items[0].alias],"Texted Avery that the rear light failed, considering a battery swap, and inquired about Sunday stall hours.")],light,lightView) != nil,"actual local repair's considering qualifier keeps the plan unsettled under the same copy gate")
  require(validate("Rear light repair",[([lightView.items[0].alias],"Texted Avery that the rear light failed, will replace the battery, and asked about Sunday stall hours.")],light,lightView)==nil,"a settled battery plan still cannot replace captured uncertainty")
  require((try? QwenNoThinkingTemplate.render(instruction:CanonicalGrounding.instruction(for:ev),evidence:ev.text,prefill:CanonicalGrounding.prefill)) != nil,"production local instruction fits the actual8192-byte runtime admission limit")
  let unnamed=try request("unnamed-bound",[action("ub","Could someone check the seed tray?",to:"")]),unnamedView=try ModelView(request:unnamed,actions:unnamed.actions)
  require((try? QwenNoThinkingTemplate.render(instruction:CanonicalGrounding.instruction(for:unnamedView),evidence:unnamedView.text,prefill:CanonicalGrounding.prefill)) != nil,"unnamed-recipient instruction also fits actual runtime admission")
  print("INSTRUCTION_BYTES named=\(CanonicalGrounding.instruction(for:ev).utf8.count) unnamed=\(CanonicalGrounding.instruction(for:unnamedView).utf8.count)")
  let midSource=String(repeating:"The garden needs more shade. ",count:12)+"I might try a screen, although I am unsure. Is the stall open on Sunday?"
  let mid=try request("visible-tail",[action("v1",midSource)]),midView=try ModelView(request:mid,actions:mid.actions)
  require(validate("Garden inquiry",[([midView.items[0].alias],"Texted Avery about the garden plan.")],mid,midView)==nil,"uncertainty and question after240 but within1600 remain required when visible to model")
  require(validate("Garden inquiry",[([midView.items[0].alias],"Texted Avery about the garden plan, might try a screen, and asked about Sunday availability.")],mid,midView) != nil,"visible later uncertainty and question can be preserved within existing bounds")
  let oversized=try request("oversized",(0..<41).map {action("o\($0)","Please check the distinct fixture note \($0).",to:"Friend \($0)")})
  do {_ = try ModelView(request:oversized,actions:oversized.actions);require(false,"capacity must not blend independent typing items")}
  catch {require((error as? WriterFailure) == .capacity,"capacity refuses oversized independent typing instead of inventing shared context")}
  let bounded=try request("twenty",(0..<20).map {action("t\($0)","Please check the distinct fixture note \(String(UnicodeScalar(65+$0)!)).")})
  let bv=try ModelView(request:bounded,actions:bounded.actions),bn=try CanonicalGrounding.fallbackNote(bounded,view:bv)
  // claude/ready-1002: code's fallback says one place line once ("Used the send key in Messages."), citing every run it
  // stands for (six identical lines on the owner's Mac); every run's own IDs are still cited, none invented.
  require(bn.bullets.count==1 && bn.bullets[0].actionIDs.count==20 && Set(bn.bullets.flatMap(\.actionIDs))==Set(bounded.actions.map(\.id)),"twenty independent runs: one fallback line citing each run's exact IDs")
  require(try CanonicalGrounding.check(bn,request:bounded,view:bv)==bn,"twenty-run fallback remains valid at the actual core bound")
  // messages-1003: texts to one person are one conversation item, so independent items here are 21 people.
  let tooMany=try request("twenty-one",(0..<21).map {action("t\($0)","Please check the distinct fixture note \(String(UnicodeScalar(65+$0)!)).",to:"Friend \(String(UnicodeScalar(65+$0)!))")})
  do {_ = try ModelView(request:tooMany,actions:tooMany.actions);require(false,"twenty-one runs require terminal capacity before model or commit")}
  catch {require((error as? WriterFailure) == .capacity,"twenty-one independent runs fail terminal capacity before model or core commit")}
  let counter=LoadCounter(),writer=CanonicalLocalWriter(runtime:counter,policy:{_,_ in true})
  // claude/ready-1002 (owner: long moments get summaries): a moment one view can't hold is written in segments, each
  // on its own view (every run stays its own item), and merged; nothing blends independent typing.
  do {
    let merged=try await writer.generate(tooMany,completeActions:tooMany.actions)
    require(Set(merged.bullets.flatMap(\.actionIDs))==Set(tooMany.actions.map(\.id)) && merged.bullets.count<=CanonicalGrounding.maxBullets,"oversized independent-run moment is written in segments, every run cited")
    let chunks=try CanonicalGrounding.chunks(tooMany,actions:tooMany.actions)
    require(chunks.map {$0.count>=2 && $0.allSatisfy {$0.view.items.filter {$0.kind == .typed}.count<=CanonicalGrounding.maxBullets}} ?? false,"each segment is its own view within the typed-item bound")
  } catch {require(false,"oversized independent-run moment is written in segments (threw \(error))")}
  require(await counter.count()>0,"segments are written by the model (each its own view)")
  for (name,source,line) in [
   ("masked-health","The lab results arrived. I might call again, although I'm unsure. Can someone help?","Texted Avery about a health question."),
   ("masked-money","My card was declined. I might call again, although I'm unsure. Can someone help?","Texted Avery about money."),
   ("truncated-tail",String(repeating:"The garden needs more shade. ",count:80)+"I might try again, although I'm unsure. Can someone help?","Texted Avery about the garden.")
  ] {
   let r=try request(name,[action(name,source)]),v=try ModelView(request:r,actions:r.actions)
   require(validate("Question for Avery",[([v.items[0].alias],line)],r,v) != nil,"richness checks never demand masked or truncated text: \(name)")
  }
  let fallback=try CanonicalGrounding.fallbackNote(club,view:cv)
  require(fallback.bullets.allSatisfy {$0.assertion != "sent"},"fallback remains truthful when no model answer is usable")
  require(try CanonicalGrounding.check(fallback,request:club,view:cv)==fallback,"fallback roundtrip remains valid")
  print("FALLBACK_FIXTURE "+String(decoding:try JSONEncoder().encode(fallback),as:UTF8.self))
  print("RESULT \(passes) passed, \(failures) failed; synthetic offline checks only")
  exit(failures==0 ? 0:1)
 }
}
