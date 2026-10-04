import Foundation
@testable import WriterBackend
private var pass=0,fail=0
private func check(_ b:Bool,_ label:String){print("\(b ? "PASS":"FAIL") \(label)");if b{pass+=1}else{fail+=1}}
private func action(_ id:String,_ words:String,title:String="daydream — claude",tool:String?="Claude Code",surface:String?="aiTool",at:Int=0)->NoteAction {
 NoteAction(id:id,at:iso(Date(timeIntervalSince1970:1800000000+Double(at))),kind:"keyboard.text_input",app:"Ghostty",site:"",title:title,description:"Typed a draft in Ghostty. "+words,state:"submitted",revision:id,surface:surface,send:"detected",sendBy:"return",to:tool,runID:id,field:"terminal")
}
private func request(_ actions:[NoteAction])throws->CanonicalNoteRequest{
 let data=try JSONSerialization.data(withJSONObject:["id":"synthetic","schemaVersion":1,"targetKind":"activity","targetID":"synthetic","day":"2027-01-15","timezone":"UTC","inputRevision":"fixture","policyRevision":"fixture","expiresAt":"2099-01-01T00:00:00Z","actions":try JSONSerialization.jsonObject(with:JSONEncoder().encode(actions)),"actionCount":actions.count]);return try JSONDecoder().decode(CanonicalNoteRequest.self,from:data)
}
@main struct Checks {static func main()throws{
 let words=["Review the DayDream design and plan fixes.","Explain the summary queue.","Inspect the local writer scheduling.","Check the summary detail order.","Review the owner preview privacy gates.","Find the stale summary status.","Inspect the terminal request capture.","Plan the ten minute refresh.","Review the typed burst pause.","Explain safe model cancellation.","Keep every captured request visible.","Check the duplicate summary excerpts.","Summarize the DayDream design fixes."]
 let acts=words.enumerated().map{action("p\($0.offset)",$0.element,at:$0.offset*100)}
 let req=try request(acts),view=try ModelView(request:req,actions:acts,localIntentSessions:true)
 let sessions=view.items.filter(\.requestSession)
 check(sessions.count==1 && sessions[0].parts.count==13,"thirteen actual captured requests form one summary-only contiguous AI session")
 check(view.items.flatMap(\.actions).map(\.id)==acts.map(\.id),"every action citation survives summary grouping")
 check(sessions[0].guards.count==13,"all independently captured copy guards survive")
 check(words.allSatisfy{view.text.contains($0)},"all thirteen complete short requests reach the prompt without one1600char concatenation cutoff")
 check(view.text.contains("Request 13:") && CanonicalGrounding.instruction(for:view).contains("shared intent"),"local prompt explicitly describes captured request intent")
 let cloud=try ModelView(request:req,actions:acts)
 check(cloud.items.filter{$0.kind == .typed}.count==13 && !CanonicalGrounding.instruction(for:cloud).contains("Own captured requests"),"cloud/default view and instruction retain separate typing behavior")
 let negative=[action("a","Review the design.",at:0),action("b","Inspect a different project.",title:"another — codex",tool:"Codex",at:1),action("c","Plan the design changes.",at:2)]
 let neg=try ModelView(request:request(negative),actions:negative,localIntentSessions:true)
 check(!neg.items.contains(where: \.requestSession),"intervening distinct tool/window context ends the session")
 let definition=[action("d1","The Astronomy Society Club (ASC) application is the one discussed.",at:0),action("d2","Could you inspect the ASC form?",at:1)]
 let defs=try ModelView(request:request(definition),actions:definition,localIntentSessions:true)
 check(CanonicalGrounding.explicitAliases("Asked Claude to inspect ASC.",defs.items)=="Asked Claude to inspect ASC.","a definition in another independently captured request cannot expand an abbreviation")
 let legacy=[action("l1","Review the queue.",tool:nil,surface:"text",at:0),action("l2","Explain its cancellation.",tool:nil,surface:nil,at:1)]
 let legacyView=try ModelView(request:request(legacy),actions:legacy,localIntentSessions:true)
 check(legacyView.items.first?.requestSession==true && legacyView.text.contains("Claude Code"),"legacy Ghostty text/nil surface with explicit claude process conservatively recognizes own AI requests")
 var unknown=legacy[0];unknown.title="daydream — zsh"
 let shell=try ModelView(request:request([unknown]),actions:[unknown],localIntentSessions:true)
 check(shell.items.first?.surface() != "aiTool","ordinary shell is never inferred as an AI conversation")
 let session=sessions[0]
 let copied="Asked Claude to "+words[0]
 check(CanonicalGrounding.copyProblem(copied,session)>0,"grouped sessions still reject excessive copies of any original run")
 var methodA=action("method-a","Inspect the local queue.",at:0),methodB=action("method-b","Review the local refresh.",at:1)
 methodA.sendBy="return";methodB.sendBy="button"
 let mixedMethods=try ModelView(request:request([methodA,methodB]),actions:[methodA,methodB],localIntentSessions:true)
 check(mixedMethods.items.first?.requestSession==true && mixedMethods.text.contains("each submission gesture observed") && !mixedMethods.text.contains("each sent with Return"),"mixed Return/button session never attributes the first observed method to every request")
 check(CanonicalGrounding.cloudVersion=="deepseek-v4-flash-0731-zdr-prompt20-validator26","cloud writer version is prompt20/validator26 (final-1004: one version above scrub-1004's prompt19/validator25)")
 check((try? QwenNoThinkingTemplate.render(instruction:CanonicalGrounding.instruction(for:view),evidence:view.text,prefill:CanonicalGrounding.prefill)) != nil,"local session instruction fits the unchanged8192-byte template bound")
 print("RESULT \(pass) passed \(fail) failed");if fail>0{exit(1)}
}}
private func iso(_ d:Date)->String{ISO8601DateFormatter().string(from:d)}
