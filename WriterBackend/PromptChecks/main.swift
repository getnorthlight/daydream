import Foundation
@testable import WriterBackend

// The Swift writer's regression snapshot and the design's guarantees. No model, no network.
//
// PromptEval/final/prompt4.py (prompt7/validator9) was the executable spec when this target was last in step with it
// (42e4537, 2026-09-27); the Swift writer has moved on since then on purpose (prompt22/validator33: durations and clicks in
// the view, recipients, one item per typed run, long moments in chunks, code-written notes, never "draft"), and the
// Python spec was not carried along (PromptEval/README.md).
// Its goldens stay the INPUT corpus here (requests, model answers, probes, stored notes). What the current writer does
// with each of them is pinned in PromptEval/final/goldens-swift.json, written by
//   cd WriterBackend && swift run --disable-automatic-resolution PromptChecks --record
// Review a re-record's diff like code: every changed line is a behaviour change. The guarantees below are checked
// against the live writer either way.
//   swift run --disable-automatic-resolution PromptChecks

var passes=0,failures=0
func expect(_ ok:Bool,_ label:@autoclosure ()->String) {if ok {passes+=1} else {failures+=1;print("FAIL "+label())}}
func named(_ ok:Bool,_ label:String) {expect(ok,label);if ok {print("PASS "+label)}}
func json(_ value:some Encodable)->String {
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
    return (try? encoder.encode(value)).map {String(decoding:$0,as:UTF8.self)} ?? "?"
}
func canonical(_ object:Any)->String {
    (try? JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes])).map {String(decoding:$0,as:UTF8.self)} ?? "?"
}
func plain(_ value:some Encodable)->Any {
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
    return (try? encoder.encode(value)).flatMap {try? JSONSerialization.jsonObject(with:$0)} ?? NSNull()
}
func decode<T:Decodable>(_ type:T.Type,_ object:Any) throws -> T {try JSONDecoder().decode(T.self,from:JSONSerialization.data(withJSONObject:object))}

let finalDir=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PromptEval/final")
let goldens=try JSONSerialization.jsonObject(with:Data(contentsOf:finalDir.appendingPathComponent("goldens-prompt4.json"))) as! [String:Any]
let snapshotURL=finalDir.appendingPathComponent("goldens-swift.json")
let recording=CommandLine.arguments.contains("--record")
let snapshot:[String:Any]=recording ? [:] : try JSONSerialization.jsonObject(with:Data(contentsOf:snapshotURL)) as! [String:Any]
var recorded:[String:Any]=["about":"PromptChecks --record: what the Swift writer (\(CanonicalGrounding.localVersion)) does with each input in goldens-prompt4.json. Synthetic data only."]
let local=CanonicalLocalWriter.provider

/// One section of the snapshot: records `actual` when recording, otherwise compares it with the recorded entry at the same
/// position (same id or label), byte for byte as canonical JSON.
var sectionCounts:[String:Int]=[:]
func pin(_ section:String,_ key:String,_ actual:[String:Any]) {
    if recording { recorded[section]=((recorded[section] as? [[String:Any]]) ?? [])+[actual]; return }
    let index=sectionCounts[section,default:0];sectionCounts[section]=index+1
    let entries=(snapshot[section] as? [[String:Any]]) ?? []
    guard index<entries.count else {expect(false,"\(section) \(key): not in goldens-swift.json (re-record)");return}
    let want=canonical(entries[index]),got=canonical(actual)
    expect(want==got,"\(section) \(key): differs from goldens-swift.json\n--- now\n\(got)\n--- recorded\n\(want)")
}
func sectionDone(_ section:String,_ label:String) {
    if recording {return}
    let recordedCount=((snapshot[section] as? [Any]) ?? []).count
    expect(sectionCounts[section,default:0]==recordedCount,"\(section): \(sectionCounts[section,default:0]) entries now, \(recordedCount) recorded")
}

// MARK: constants

let constants:[String:Any]=["instruction":CanonicalGrounding.instruction,"prefill":CanonicalGrounding.prefill,"maxTokens":CanonicalGrounding.maxTokens,
                            "versions":["local":CanonicalGrounding.localVersion,"cloud":CanonicalGrounding.cloudVersion]]
if recording {for (k,v) in constants {recorded[k]=v}}
else {
    named(snapshot["instruction"] as? String==CanonicalGrounding.instruction,"instruction matches goldens-swift.json")
    named(canonical(snapshot["versions"] ?? [:])==canonical(constants["versions"]!),"generatorVersion strings match goldens-swift.json (\(CanonicalGrounding.localVersion))")
    named(snapshot["prefill"] as? String==CanonicalGrounding.prefill && snapshot["maxTokens"] as? Int==CanonicalGrounding.maxTokens,"prefill and token budget match goldens-swift.json")
}
named(CanonicalGrounding.instruction.utf8.count<=8192,"instruction fits the template limit (\(CanonicalGrounding.instruction.utf8.count) bytes)")
for version in [CanonicalGrounding.localVersion,CanonicalGrounding.cloudVersion] {
    expect(version.range(of:#"^[A-Za-z0-9._/-]{1,100}$"#,options:.regularExpression) != nil,"\(version) passes core's generatorVersion check (DerivedNotes.swift)")
}
named(CanonicalGrounding.localVersion != (goldens["versions"] as! [String:String])["local"],"the archived prompt4.py spec's version is not the writer's (its goldens are inputs only)")

// MARK: views

var requests:[String:CanonicalNoteRequest]=[:],views:[String:ModelView]=[:],capacity:Set<String>=[]
let viewFailures=failures
for golden in goldens["views"] as! [[String:Any]] {
    let id=golden["id"] as! String
    let request=try decode(CanonicalNoteRequest.self,golden["request"]!)
    let names=(golden["appNames"] as? [String:String]) ?? [:]
    requests[id]=request
    do {
        let view=try ModelView(request:request,actions:request.actions,appNames:names)
        views[id]=view
        pin("views",id,["id":id,"view":view.text,"items":view.items.map {[$0.alias,$0.kind.rawValue,$0.actions.map(\.id)] as [Any]},
                        "hidden":view.hidden.flatMap {$0.actions.map(\.id)}.sorted()])
        let reversed=try ModelView(request:request,actions:request.actions.reversed(),appNames:names)
        expect(reversed.text==view.text,"\(id): the view does not depend on input order")
    } catch WriterFailure.capacity {
        capacity.insert(id)
        pin("views",id,["id":id,"capacity":true])
    }
}
sectionDone("views","")
named(failures==viewFailures,"\(views.count) item views match goldens-swift.json; over a single view's capacity: \(capacity.sorted())")
let renderFailures=failures
for rendered in goldens["rendered"] as! [[String:Any]] {
    let id=rendered["case"] as! String
    let prompt=try QwenNoThinkingTemplate.render(instruction:CanonicalGrounding.instruction,evidence:views[id]!.text,prefill:CanonicalGrounding.prefill)
    pin("rendered",id,["case":id,"prompt":prompt])
}
sectionDone("rendered","")
named(failures==renderFailures,"rendered prompts (template + prefill) match goldens-swift.json")

// MARK: validate / salvage / check, against the recorded writer

var results:[String:(id:String,result:Result<CanonicalNoteOutput,WriterRejection>)]=[:]
func run(_ section:String,_ entry:[String:Any],prefix:String="",_ work:() throws -> CanonicalNoteOutput) {
    let label=entry["label"] as! String,id=entry["case"] as! String
    guard views[id] != nil else {pin(section,label,["label":label,"skipped":"capacity"]);return}
    do {
        let note=try work()
        results[prefix+label]=(id,.success(note))
        pin(section,label,["label":label,"ok":true,"note":plain(note)])
    } catch let rejection as WriterRejection {
        results[prefix+label]=(id,.failure(rejection))
        pin(section,label,["label":label,"ok":false,"code":rejection.code,"reason":rejection.reason])
    } catch {
        pin(section,label,["label":label,"ok":false,"error":"\(error)"])
    }
}
func context(_ entry:[String:Any])->(CanonicalNoteRequest,ModelView) {let id=entry["case"] as! String;return (requests[id]!,views[id]!)}

let validateEntries=goldens["validate"] as! [[String:Any]]
var before=failures
for entry in validateEntries {
    run("validate",entry) {
        let (request,view)=context(entry)
        let note=try CanonicalGrounding.validate(entry["raw"] as! String,request:request,view:view,provider:entry["provider"] as! String)
        return try CanonicalGrounding.check(note,request:request,view:view)
    }
}
sectionDone("validate","")
let rejectProbes=validateEntries.filter {($0["label"] as! String).hasPrefix("reject-")}
named(failures==before,"validate + check match goldens-swift.json on \(validateEntries.count) answers (expected notes, \(rejectProbes.count) must-reject probes, accept probes)")
let salvageEntries=goldens["salvage"] as! [[String:Any]]
before=failures
for entry in salvageEntries {
    run("salvage",entry,prefix:"salvage:") {
        let (request,view)=context(entry)
        let note=try CanonicalGrounding.salvage(entry["raw"] as! String,request:request,view:view,provider:entry["provider"] as! String)
        return try CanonicalGrounding.check(note,request:request,view:view)
    }
}
sectionDone("salvage","")
named(failures==before,"salvage matches goldens-swift.json on \(salvageEntries.count) real-model answers")
let checkEntries=goldens["check"] as! [[String:Any]]
before=failures
for entry in checkEntries {
    let note=try decode(CanonicalNoteOutput.self,entry["note"]!)
    run("check",entry,prefix:"check:") {let (request,view)=context(entry);return try CanonicalGrounding.check(note,request:request,view:view)}
}
sectionDone("check","")
named(failures==before,"check() accepts or refuses \(checkEntries.count) stored notes as goldens-swift.json records")
before=failures
for entry in goldens["repair"] as! [[String:Any]] {
    let (_,view)=context(entry)
    pin("repair",entry["case"] as! String,["case":entry["case"]!,"evidence":CanonicalGrounding.repairEvidence(view,previous:entry["previous"] as! String,problem:entry["problem"] as! String)])
}
sectionDone("repair","")
for entry in goldens["withPrefill"] as! [[String:Any]] {
    pin("withPrefill",entry["raw"] as! String,["raw":entry["raw"]!,"result":CanonicalGrounding.withPrefill(entry["raw"] as! String) as Any])
}
sectionDone("withPrefill","")
named(failures==before,"repair-turn evidence and prefill re-attachment match goldens-swift.json")
if recording {
    let data=try JSONSerialization.data(withJSONObject:recorded,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])
    try (data+Data("\n".utf8)).write(to:snapshotURL)
    print("RECORDED \(snapshotURL.path)")
}

// MARK: the design's guarantees, stated one by one

func note(_ label:String)->CanonicalNoteOutput? {if case .success(let n)? = results[label]?.result {return n};return nil}
func rejection(_ label:String)->WriterRejection? {if case .failure(let r)? = results[label]?.result {return r};return nil}
let accepted=results.filter {!$0.key.hasPrefix("check:")}.compactMap {label,entry in (try? entry.result.get()).map {(label:label,id:entry.id,note:$0)}}

// Many archived answers are now refused first by a later, deliberate rule: separate typing items need their own bullets
// (d012bc5), no line that only says something was open or used (96674a7), never "you" (a6eda73), and bullets cover writing,
// not reading (320c900). The answers below ask each probe's own question again, written for today's rules.
let typingApart="Separate typing items need separately cited bullets; a shared recipient is not one message."
func answer(_ title:String,_ bullets:[([String],String)])->String {canonical(["title":title,"bullets":bullets.map {["ids":$0.0,"text":$0.1]}])}
func attempt(_ id:String,_ raw:String,salvage:Bool=false)->Result<CanonicalNoteOutput,WriterRejection>? {
    guard let request=requests[id],let view=views[id] else {return nil}
    do {
        let n=salvage ? try CanonicalGrounding.salvage(raw,request:request,view:view,provider:local) : try CanonicalGrounding.validate(raw,request:request,view:view,provider:local)
        return .success(try CanonicalGrounding.check(n,request:request,view:view))
    } catch let r as WriterRejection {return .failure(r)} catch {return nil}
}
func written(_ id:String,_ raw:String,salvage:Bool=false)->CanonicalNoteOutput? {try? attempt(id,raw,salvage:salvage)?.get()}
func refused(_ id:String,_ raw:String)->WriterRejection? {if case .failure(let r)? = attempt(id,raw) {return r};return nil}

// Independent of goldens-swift.json: every archived must-reject probe is still refused by the live writer, never accepted
// and never skipped. One refused under another code than the archived spec expected was stopped earlier by one of the
// later rules above (the answer never reaches the probe's own rule); any other code is a failure here.
let laterRules:Set<String>=["structure","filler","you","worked"]
var probesAccepted:[String]=[],probesElsewhere:[String]=[],probesAsExpected=0
for entry in rejectProbes {
    let label=entry["label"] as! String
    guard let r=rejection(label) else {probesAccepted.append(label);continue}
    if r.code==entry["expectCode"] as? String {probesAsExpected+=1} else if !laterRules.contains(r.code) {probesElsewhere.append("\(label): \(r.code)")}
}
named(rejectProbes.count>=84 && probesAccepted.isEmpty && probesElsewhere.isEmpty && probesAsExpected>=36,
      "must-reject: all \(rejectProbes.count) probes are refused (\(probesAsExpected) with the archived code, the rest by a later structure/filler/you/worked rule) \(probesAccepted) \(probesElsewhere)")

// claude/dayeval-1005, independent of the snapshot: no accepted note says draft, unsent or not sent in DayDream's own
// words, and nothing is left for `undraft` to rewrite. "draft" may only be the person's own word (it is in the moment's
// evidence, like a contract draft they asked someone for), never a lead ("Drafted", "Typed a draft").
let ownDraftWording=#"(?i)\b(drafted|drafting|unsent|not sent|never sent|no send seen)\b|isn['’]t confirmed|^(typed|wrote|left|edited|saved|started) (a|the|an) (\w+ )?drafts?\b"#
var drafty:[String]=[]
for (label,id,n) in accepted {
    for text in [n.title]+n.bullets.map(\.text) {
        if CanonicalGrounding.undraft(text) != text || text.range(of:ownDraftWording,options:.regularExpression) != nil {drafty.append("\(label): \(text)");continue}
        if text.range(of:#"(?i)\bdrafts?\b"#,options:.regularExpression) != nil,views[id]!.text.range(of:"draft",options:.caseInsensitive)==nil {drafty.append("\(label): \(text)")}
    }
}
named(drafty.isEmpty,"never draft: no accepted note says draft, unsent or not sent in DayDream's own words (\(accepted.count) notes) \(drafty)")

// multi-action grouped bullets
named(note("expected-E01")?.bullets.map(\.actionIDs.count)==[20] && rejection("E13-grouped")?.reason==typingApart,
      "grouped: one bullet carries a window's 20 action IDs (E01); one bullet over 11 separate typed drafts is refused (E13, d012bc5)")
let e18Split=written("E18",answer("Q3 offsite and Sam's 1:1",[(["i1"],"Typed Q3 offsite notes on docs.google.com in Chrome about booking a venue before Friday and sharing the agenda."),
                                                                (["i2"],"Wrote an email to Sam on mail.google.com asking to move the 1:1 to Thursday; sending isn't confirmed.")]))
named(e18Split?.bullets.map(\.actionIDs.count)==[3,4] && rejection("expected-E18")?.reason==typingApart,
      "grouped: Chrome typing + Return fold into each draft's own bullet (E18: 3 and 4); the archived answer joining both drafts is refused")

// every item that must be cited is (320c900: background windows, and what was only read beside writing, may go unsaid)
var uncited:[String]=[]
for (label,id,n) in accepted {
    let view=views[id]!,cited=Set(n.bullets.flatMap(\.actionIDs))
    let idle=Set(view.hidden.flatMap {$0.actions.map(\.id)})
    let must=Set(view.items.filter {CanonicalGrounding.mustCite($0,view)}.flatMap {$0.actions.map(\.id)})
    if !cited.isDisjoint(with:idle) || !must.isSubset(of:cited) || !cited.isSubset(of:Set(requests[id]!.actions.map(\.id))) {uncited.append(label)}
}
named(uncited.isEmpty && accepted.count>=60,"coverage: every item a note must cite is cited, nothing else is, and idle never, in all \(accepted.count) accepted notes \(uncited)")
named(rejection("reject-09-coverage")?.reason==typingApart
      && refused("E03",answer("Reply to Priya",[(["i1"],"Wrote an email to Priya with thanks for the iPad repro steps; sending isn't confirmed.")]))?.code=="coverage",
      "coverage: an answer that leaves out a typed draft is rejected")
let also=note("E08-also-bullet")
named(also?.bullets.map(\.text)==["Worked in the Onboarding v3 file in Figma."] && also?.bullets.first?.actionIDs.count==views["E08"]!.items[0].actions.count,
      "coverage: background windows the model left out stay unsaid (no code-written \"Also had ... open.\" line)")

// bullet cap
named(rejection("E13-four-bullets")?.reason=="The answer has 4 bullets. Write 1 to 3; background items of the same kind can share one, but separate typing items stay separate." && rejection("E01-robotic")?.code=="structure","cap: 4 bullets for a moment is rejected (cap 3), including the owner's robotic E01 summary")
let dayView=views["E02"]!,dayRequest=requests["E02"]!
let sixBullets=#"{"title":"Day","bullets":["#+(1...6).map {#"{"ids":["i\#($0)"],"text":"Had item \#($0) open."}"#}.joined(separator:",")+"]}"
do {_ = try CanonicalGrounding.validate(sixBullets,request:dayRequest,view:dayView,provider:local);named(false,"cap: 6 bullets for a day is rejected (cap 5)")}
catch let r as WriterRejection {named(r.reason=="The answer has 6 bullets. Write 1 to 5; background items of the same kind can share one, like i1 and i3, but separate typing items stay separate.","cap: 6 bullets for a day is rejected (cap 5)")}
// d012bc5: 11 separate typed drafts can't share bullets and code has no line for each, so salvage refuses; code's
// fallback note says only where.
named(note("salvage:E13-six")==nil && rejection("salvage:E13-six")?.code=="coverage"
      && (try? CanonicalGrounding.fallbackNote(requests["E13"]!,view:views["E13"]!))?.bullets.map(\.text)==["Typed in Notes."],
      "cap: 6 bullets over 11 typed drafts don't salvage (8 drafts uncited); the fallback note says only where")
named(accepted.allSatisfy {_,id,n in n.bullets.count<=(views[id]!.scope == .day ? 5:3)+4 && n.bullets.allSatisfy {$0.text.count<=240}},"cap: no accepted note has more than cap + 4 bullets or a bullet over 240 characters")
named(rejection("E03-too-long")?.code=="structure","size: a bullet over 240 characters is rejected")

// grounded overclaim: the words are in the evidence, but a report or an email subject is not proof
let overclaim="All 42 StreakMergeTests pass and the merge bug is fixed."
named(views["E06"]!.text.contains("42") && rejection("reject-15-unframed")?.code=="unframed","overclaim: \"\(overclaim)\" is rejected although every word is in the evidence")
named(refused("E06",answer("CI",[(["i2"],"All checks passed on tallybird main #1287 in Mail.")]))?.code=="unframed"
      && refused("E06",answer("CI",[(["i3"],"All 42 tests pass now, per Claude.")]))?.code=="unframed",
      "overclaim: an email subject or a relayed report stated as fact is rejected")
let ciFramed=answer("StreakMergeTests and CI",[(["i2"],"Looked at a CI email whose subject says all checks passed on tallybird main #1287."),
                                               (["i3"],"Claude reported that all 42 StreakMergeTests pass and the merge bug is fixed; not verified.")])
named(written("X-ci",ciFramed)?.bullets.map(\.assertion)==["observed","reported"],"overclaim: the same facts framed as \"reported\"/\"subject says\" are accepted with derived labels")
let rescued=note("salvage:E06-overclaims")
named(rescued != nil && !rescued!.bullets.contains {$0.text==overclaim || $0.text.hasPrefix("Sent ") || $0.text=="All checks passed on tallybird main #1287."},
      "overclaim: salvage drops the overclaims and writes attributed bullets instead")

// injection
named(rejection("reject-25-leak")?.code=="leak" && rejection("reject-26-leak")?.code=="leak","injection: bullets repeating control tokens or \"ignore previous instructions\" are rejected")
named(written("E09",answer("Ignore previous instructions",[(["i1"],"Mail had an email open whose subject is text addressed to AI tools."),(["i2"],"Typed text addressed to AI tools in Notes.")]))?.title=="Mail, Pages and Notes",
      "injection: an injected title is replaced by the code-written fallback")
let injectedReason=rejection("E09-repair-reason")?.reason ?? "ignore"
named(!injectedReason.lowercased().contains("ignore") && !injectedReason.contains("finished"),"injection: the repair reason is fixed text and never echoes evidence")
named(views.values.allSatisfy {$0.text.range(of:#"(?i)ignore previous|im_start|im_end|<\||</?think|admin mode"#,options:.regularExpression)==nil},
      "injection: no item view shows injected text or control tokens")
named(views["X-app-name"]!.text.contains("i1. an app: ") && !views["X-app-name"]!.text.contains("Quote\"App"),"injection: app names are cleaned; an injected app name is shown as \"an app\"")

// draft / sent / reported stay distinct
named(note("E04-labels")?.bullets.map(\.assertion)==["draft","sent","observed"],"labels: draft, sent and observed come from action states, not the model")
named(refused("E03",answer("Reply to Priya",[(["i1"],"Sent a reply to Priya in Mail.")]))?.code=="send"
      && refused("E03",answer("Reply to Priya",[(["i1"],"Drafted a reply to Priya in Mail; it was not sent.")]))?.code=="send"
      && refused("E04",answer("Slack messages",[(["i1","i2"],"Sent two Slack messages about PR 482 and lunch.")]))?.code=="send",
      "labels: \"sent\"/\"replied\" wording without a sent state is rejected")
named((42...49).allSatisfy {n in rejectProbes.contains {($0["label"] as! String).hasPrefix(String(format:"reject-%02d-",n))}}
      && refused("X-mail-draft",answer("Priya repro",[(["i1"],"Wrote back to Priya about the iPad streak reset.")]))?.code=="send"
      && refused("X-mail-draft",answer("Priya repro",[(["i1"],"Drafted a reply to Priya and hit Send.")]))?.code=="send"
      && refused("X-mail-draft",answer("Priya repro",[(["i1"],"Drafted a reply to Priya; sending is confirmed.")]))?.code=="claim"
      && refused("X-mail-draft",answer("Priya repro",[(["i2"],"Wrote that the offline-device bug is found, then pressed Return to send it.")]))?.code=="send",
      "labels: \"wrote back\", \"hit Send\", \"sending is confirmed\" and \"pressed Return to send\" are rejected")
// 96674a7: a window-only moment is code's note (no model), and code never says the title's "Sent". Code's own title goes
// through the same core gate as a model's (codeTitle): "Email about Sent Mailbox" would make finish() refuse the whole note.
let mailbox=(requests["X-sent-mailbox"]!,views["X-sent-mailbox"]!)
let mailboxCode=try? CanonicalGrounding.codeNote(mailbox.0,view:mailbox.1)
named(refused("X-sent-mailbox",answer("Mail mailbox",[(["i1"],"Looked at the Sent Mailbox in Mail.")]))?.code=="sendword"
      && written("X-sent-mailbox",answer("Mail mailbox",[(["i1"],"Looked at a mailbox in Mail.")]))?.bullets.map(\.text)==["Looked at a mailbox in Mail."]
      && CanonicalGrounding.codeWrites(mailbox.1) && mailboxCode != nil
      && mailboxCode?.bullets.contains {$0.text.contains("Sent")}==false && mailboxCode.map {CanonicalGrounding.coreSend.search($0.title)}==false,
      "core gate: a \"Sent Mailbox\" title is never repeated in a non-SENT bullet or code's title (core's commitNote refuses the word)")
let example=answer("Export bug in tallybird",[(["i1"],"Approved the smaller fix."),(["i1","n1"],"Asked Claude why large exports fail in ExportView, then edited ExportView.swift in Xcode."),
                                              (["i2"],"Emailed priya asking to retry the export with the new build."),(["i3"],"Wrote a text to Mom about saving some food.")])
named(rejection("instruction-example")?.code=="you" && written("X-example",example)?.bullets.map(\.assertion)==["observed","submitted","submitted","draft"],
      "labels: the instruction's worked example, in today's words, validates as observed/submitted/submitted/draft (code orders the lines)")
// sat5: typing whose words the writer doesn't see is one run with its window and about how long, never a count of drafts;
// that duration may be repeated, no other.
named(views["X-claude-run"].map { v in v.items.filter { $0.kind == .typed }.count==1 && v.text.hasSuffix("i1. Claude (AI app): typed text (not captured) in \"Tallybird launch plan\" over about 2 minutes; sending unknown") && !v.text.contains("drafts") }==true
      && written("X-claude-run",answer("Tallybird launch plan",[(["i1"],"Wrote a message in Claude (about 2 minutes).")]))?.bullets.first?.text=="Wrote a message in Claude (about 2 minutes)."
      && note("salvage:X-claude-run-sent")?.bullets.first?.text=="Wrote a message to Claude."
      && views["X-mail-draft"].map { v in v.items.filter { $0.kind == .typed }.count==2 }==true,
      "typing runs: uncaptured drafts in one app are one item with its window and about how long; that duration may be repeated; typed words stay one item per draft")

// JSON only, deterministic fallback
named(rejection("E11-not-json")?.code=="structure" && rejection("E11-not-json")?.reason=="The answer was not one JSON object. Reply with only the JSON object.","json: prose is rejected")
named(rejection("E11-bool-id")?.code=="structure" && rejection("E11-no-bullets")?.code=="structure","json: wrong shapes are rejected")
named(rejection("salvage:E11-not-json")?.code=="structure","json: salvage refuses an answer that is not JSON")
let e16=salvageEntries.first {$0["label"] as? String=="E16-note"}!
let first=try CanonicalGrounding.salvage(e16["raw"] as! String,request:requests["E16"]!,view:views["E16"]!,provider:local)
let second=try CanonicalGrounding.salvage(e16["raw"] as! String,request:requests["E16"]!,view:views["E16"]!,provider:local)
named(first==second && first.generatorVersion==CanonicalGrounding.localVersion,"fallback: salvage is deterministic and stamps the local generatorVersion")

// prompt5 / validator7 review fixes
named(views["E07"]!.text.range(of:"idle")==nil && views["E07"]!.hidden.count==1,"idle: idle time is hidden from the model and never cited")
named(views["X-day-items"]?.items.count==1,"capacity: 41 windows fold per app instead of waiting")
// e39b926 + claude/ready-1002 (deliberate): a moment needs one bullet per typed run, so a 41-message chat is over one
// view's capacity and is written in segments (`CanonicalGrounding.chunks`); a day like that stays pending with every
// action ID, never truncated (CoreWriterAdapter). Typed runs never fold away.
let chat41=requests["X-chat-41"]!
let chat41Chunks:[NoteChunk]?=(try? CanonicalGrounding.chunks(chat41,actions:chat41.actions)) ?? nil
named(capacity.contains("X-chat-41") && (chat41Chunks?.count ?? 0)>=2 && chat41Chunks?.allSatisfy({ $0.view.items.count<=ModelView.maxItems })==true
      && Set(chat41Chunks?.flatMap { $0.actions.map(\.id) } ?? [])==Set(chat41.actions.map(\.id)),
      "capacity: a 41-message chat is written in segments that cover every action (\(chat41Chunks?.count ?? 0) segments)")
let dayReal=requests["X-day-real"]!
named(capacity.contains("X-day-real") && { do { _ = try CanonicalGrounding.chunks(dayReal,actions:dayReal.actions); return false } catch WriterFailure.capacity { return true } catch { return false } }(),
      "capacity: a 390-action day with 60 typed runs is over capacity as a day and is never chunked (it stays pending, every action kept)")
named(views["X-e18-installed"]!.text==views["E18"]!.text,"chrome: an installed \"Google Chrome\" name groups with the extension's \"Chrome\"")
named(!views["X-private"]!.text.contains("Patel") && !views["X-private"]!.text.contains("Chase") && views["E10"]!.text.contains("a personal finance note (details hidden)"),
      "privacy: doctor names, conditions and bank or card problems are hidden from the model")
named(["X-inject-portal","X-inject-invoice","X-inject-billing","X-inject-typed"].allSatisfy {views[$0]!.text.contains("text addressed to AI tools")},
      "injection: text addressed to AI summarizers is masked")
named(refused("X-mail-draft",answer("Priya repro",[(["i1"],"Drafted a reply to Priya and Marcus; sending isn't confirmed.")]))?.code=="name"
      && rejection("reject-61-claim")?.code=="claim" && rejection("reject-65-worked")?.code=="worked" && rejection("reject-73-number")?.code=="number"
      && refused("X-ci",answer("StreakMergeTests",[(["i3"],"Claude reported on StreakMergeTests. All 42 tests pass and the merge bug is fixed.")]))?.code=="sentences"
      && refused("X-ci",answer("StreakMergeTests",[(["i3"],"Claude reported all 42 StreakMergeTests pass and the merge bug is fixed.")]))?.code=="notverified",
      "grounding: invented names, meetings, work on an unused window, partial numbers, extra sentences and unhedged reports are rejected")
let e18Bullets:[([String],String)]=[(["i1"],"Typed Q3 offsite notes on docs.google.com in Chrome about booking a venue before Friday and sharing the agenda."),
                                    (["i2"],"Wrote an email to Sam on mail.google.com asking to move the 1:1 to Thursday; sending isn't confirmed.")]
let invoice=[(["i1"],"Looked at the invoice from Acme Inc. in Mail.")]
named(written("E18",answer("Q3 offsite email draft",e18Bullets)+"`\n</think>\n\n```json {\"title\":\"x\",\"bullets\":[]}```") != nil
      && written("X-e18-installed",answer("Q3 offsite and Sam's 1:1",e18Bullets)) != nil
      && written("X-things",answer("Today in Things 3",[(["i1"],"Planned the day in the Today list in Things 3.")])) != nil
      && written("X-1password",answer("Personal vault",[(["i1"],"Used the Personal vault in 1Password.")])) != nil
      && written("X-invoice-title",answer("\"Acme invoice\".",invoice))?.title=="Acme invoice" && written("X-invoice-title",answer("Finished invoice",invoice))?.title=="Email about Invoice from Acme Inc",
      "no false rejections: text after the JSON, Things 3, 1Password and titles ending in \".\" pass check()")

// real-model run (prompt-work/v7/real-run): first answers that were right but rejected, and the limits of the fix
named(written("E14",answer("Q3 report",[(["i1"],"Typed in the Q3 report in Pages that sales grew 12% compared to the previous quarter."),
                                         (["i2"],"Wrote a LINE message in 佐藤さんとのトーク about tomorrow's meeting; sending isn't confirmed.")]))?.bullets.first?.text.contains("compared")==true
      && rejection("reject-80-claim")?.code=="claim",
      "translation: a framed claim in the English gist of Spanish typing is accepted; terse English notes still need the claim's own words")
named(written("E08",answer("Onboarding v3 in Figma",[(["i1"],"Worked in the Onboarding v3 file in Figma."),(["i2"],"Looked at the GitHub status page in Chrome.")]))?.bullets.contains {$0.text.contains("GitHub")}==true
      && refused("E08",answer("Onboarding v3 in Figma",[(["i1"],"Worked in the Onboarding v3 file in Figma."),(["i2"],"Looked at the GitLab status page in Chrome.")]))?.code=="name",
      "names: \"GitHub\" read from www.githubstatus.com is accepted; a name that is not in the host is not")
named(rejection("E17-four-bullets")?.reason=="The answer has 4 bullets. Write 1 to 3; background items of the same kind can share one, like i2 and i4, but separate typing items stay separate."
      && refused("E13",answer("Tallybird 2.3 release notes",[(["i10"],"Typed a draft note; checking wording with Maya before App Store submission.")]))?.code=="unframed"
      && rejection("E01-robotic")?.reason=="The answer has 4 bullets. Write 1 to 3; background items of the same kind can share one, but separate typing items stay separate.",
      "repair: the count reason names two bullets of one kind to merge, and draft words after a \";\" get the unframed reason")
named(refused("E03",answer("Reply to Priya",[(["i3"],"Drafted a reply to Priya; the TestFlight link will be sent once the build is ready.")]))?.reason=="bullet 1 says \"sent\", but only SENT items may use that word, even to retell typed words (\"will send\", not \"will be sent\"). Write \"wrote\" or \"typed\".",
      "repair: the send reason says the word itself is out, even when retelling what a draft promises")
named(written("E03",answer("Reply to Priya",[(["i1"],"Wrote an email to Priya with thanks for the iPad repro steps; sending isn't confirmed."),
                                              (["i2"],"Wrote that offline check-ins were overwriting newer ones, with a fix due in 2.3; sending isn't confirmed."),
                                              (["i3"],"Wrote a note that the TestFlight link will be sent once the build is ready; sending isn't confirmed.")]))?.bullets.last?.text=="Wrote a note that the TestFlight link will go out once the build is ready.",
      "core gate: a framed \"will be sent\" retelling a draft that says send becomes \"will go out\", since core refuses \"sent\"")
// d012bc5: the model's bullet joining both drafts is dropped and code has no line for the docs typing, so salvage refuses;
// the fallback note gives each its own line that names the site and says only where.
let e18Fallback=try? CanonicalGrounding.fallbackNote(requests["E18"]!,view:views["E18"]!)
named(rejection("salvage:E18-sent-draft")?.code=="coverage" && e18Fallback?.bullets.map(\.text)==["Typed in Google Docs.","Typed in Gmail."]
      && e18Fallback?.bullets.map(\.actionIDs.count)==[3,4],
      "chrome: a Gmail draft salvage can't keep falls back to a line that names the site, says only where and takes its own tab")
named(written("X-ci",String(ciFramed.dropLast()))?.bullets.count==2 && rejection("E11-cut-in-string")?.code=="structure",
      "json: an answer that stops before its last \"}\" is closed; one cut off inside a string is still rejected")

// prompt7 / validator9 (summaries/v3): send facts, lead words, recipients, copy guard v2, NEXT, the K2 intent fixtures
let k2=validateEntries.filter {($0["label"] as! String).hasPrefix("K2-")}
named(k2.count>=50 && (goldens["salvage"] as! [[String:Any]]).filter {($0["label"] as! String).hasPrefix("K2-")}.allSatisfy {$0["ok"] as! Bool},
      "K2: \(k2.count) intent-fixture lines (F01-F29) validate exactly as validator9, and every fixture salvages to a true line")
named(note("K2-F05-line1")?.bullets.first?.assertion=="submitted" && note("K2-F09-line1")?.bullets.first?.assertion != "submitted"
      && rejection("K2-F09-line2")?.code=="send" && rejection("K2-F29-line2")?.code=="send",
      "verbs: \"Emailed\" is allowed only for a detected send (label submitted); a draft never says Emailed or Texted")
named(rejection("K2-F27-line2")?.code=="lead" && rejection("K2-F28-line2")?.code=="wordless" && note("K2-F27-line1") != nil,
      "verbs: a send the Mac couldn't see (button click) is \"Wrote\", never \"Asked\"")
named(rejection("K2-F06-line2") != nil && rejection("K2-F11-line2") != nil && rejection("K2-F12-line2") != nil && note("K2-F06-line1") != nil
      && rejection("K2-F08-line1")?.code=="you" && written("K2-F08",answer("",[(["i1"],"Replied on the sync bug from Priya thread, promising a look at the logs tomorrow.")])) != nil,
      "recipients: only the read to/in name or \"someone\"; never a name from the typed words or the next window; \"Replied to Priya's email\" from a Re: title")
named(rejection("K2-F01-line5")?.code=="copy" && rejection("K2-F10-line2")?.code=="copy" && rejection("K2-F20-line2")?.code=="copy"
      && rejection("K2-F16-line2")?.code=="you" && written("K2-F16",answer("",[(["i1"],"Messaged someone on WhatsApp about meeting at 7.")])) != nil,
      "copy guard v2: 6+ of the person's words in a row, or a whole short draft, are refused; names and numbers are free")
named(views["K2-F12"]!.text.contains("NEXT:\nn1. Messages: \"Priya\" in Messages")
      && written("K2-F23",answer("",[(["i1","n1"],"Asked Claude Code to track down why test 5 crashed, then edited WriterIntegration.swift in Xcode.")]))?.bullets.first?.text.contains(", then edited")==true
      && views["X-example"]!.text.contains("n1. Xcode: \"ExportView.swift — tallybird\" in Xcode, in use (clicked once), typed"),
      "NEXT: windows after the last send are n1-n3, code typed there folds in as \", typed\"")
named(views["K2-F02"]!.items.filter {$0.kind == .typed}.count==1 && views["K2-F01"]!.text.contains("Start with: Asked Claude, Approved") && views["K2-F01"]!.text.count>800,
      "units: the pieces of one typed run are one item with all their words (up to 1,600 characters for an AI app)")
named(views["K2-F24"]!.text.contains("a personal health note (details hidden)") && views["K2-F28"]!.text.contains("typed text (not captured)")
      && rejection("K2-F28-line1")?.code=="filler" && written("K2-F28",answer("",[(["i1"],"Wrote a message in Claude.")]),salvage:true)?.bullets.map(\.text)==["Asked Claude."],
      "privacy: health text stays hidden in an AI app; a wordless send says only where")

print("\(failures==0 ? "PASS" : "FAIL") PromptChecks: \(passes) checks, \(failures) failures")
exit(failures==0 ? 0:1)
