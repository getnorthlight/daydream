import Foundation
import WriterBackend

// prompt7/validator9 parity and safety checks. No model, no network.
// PromptEval/final/prompt4.py is the executable spec; `python3 final/prompt4.py goldens` records what it does with every
// case, probe and salvage input, and this target checks that the Swift writer does exactly the same.
//   swift run --disable-automatic-resolution PromptChecks

var passes=0,failures=0
func expect(_ ok:Bool,_ label:@autoclosure ()->String) {if ok {passes+=1} else {failures+=1;print("FAIL "+label())}}
func named(_ ok:Bool,_ label:String) {expect(ok,label);if ok {print("PASS "+label)}}
func json(_ value:some Encodable)->String {
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
    return (try? encoder.encode(value)).map {String(decoding:$0,as:UTF8.self)} ?? "?"
}
func decode<T:Decodable>(_ type:T.Type,_ object:Any) throws -> T {try JSONDecoder().decode(T.self,from:JSONSerialization.data(withJSONObject:object))}

let finalDir=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PromptEval/final")
let goldens=try JSONSerialization.jsonObject(with:Data(contentsOf:finalDir.appendingPathComponent("goldens-prompt4.json"))) as! [String:Any]
let promptFile=try String(contentsOf:finalDir.appendingPathComponent("prompt4.txt"),encoding:.utf8)
let local=CanonicalLocalWriter.provider

// MARK: constants

named(CanonicalGrounding.instruction+"\n"==promptFile && goldens["instruction"] as? String==promptFile,"instruction is PromptEval/final/prompt4.txt")
named(CanonicalGrounding.instruction.utf8.count<=8192,"instruction fits the template limit (\(CanonicalGrounding.instruction.utf8.count) bytes)")
let versions=goldens["versions"] as! [String:String]
named(CanonicalGrounding.localVersion==versions["local"] && CanonicalGrounding.cloudVersion==versions["cloud"],"generatorVersion strings match the spec")
for version in [CanonicalGrounding.localVersion,CanonicalGrounding.cloudVersion] {
    expect(version.range(of:#"^[A-Za-z0-9._/-]{1,100}$"#,options:.regularExpression) != nil,"\(version) passes core's generatorVersion check (DerivedNotes.swift)")
}
named(CanonicalGrounding.prefill==goldens["prefill"] as? String && CanonicalGrounding.maxTokens==goldens["maxTokens"] as? Int,"prefill and token budget match the spec")

// MARK: views

var requests:[String:CanonicalNoteRequest]=[:],views:[String:ModelView]=[:]
let viewFailures=failures
for golden in goldens["views"] as! [[String:Any]] {
    let id=golden["id"] as! String
    let request=try decode(CanonicalNoteRequest.self,golden["request"]!)
    let names=(golden["appNames"] as? [String:String]) ?? [:]
    requests[id]=request
    do {
        let view=try ModelView(request:request,actions:request.actions,appNames:names)
        views[id]=view
        expect(golden["capacity"]==nil,"\(id): Swift built a view; Python said \(golden["capacity"] ?? "")")
        expect(view.text==golden["view"] as? String,"\(id): view differs\n--- swift\n\(view.text)\n--- python\n\(golden["view"] ?? "")")
        let items=(golden["items"] as? [[Any]]) ?? []
        expect(items.count==view.items.count && zip(items,view.items).allSatisfy {g,it in
            g[0] as? String==it.alias && g[1] as? String==it.kind.rawValue && g[2] as? [String]==it.actions.map(\.id)
        },"\(id): items differ: \(view.items.map {"\($0.alias) \($0.kind.rawValue) \($0.actions.map(\.id))"})")
        expect(view.hidden.flatMap {$0.actions.map(\.id)}.sorted()==(golden["hidden"] as? [String] ?? []),"\(id): hidden idle actions differ")
        let reversed=try ModelView(request:request,actions:request.actions.reversed(),appNames:names)
        expect(reversed.text==view.text,"\(id): the view does not depend on input order")
    } catch WriterFailure.capacity {
        expect(golden["capacity"] != nil,"\(id): Swift said capacity; Python built a view")
    }
}
named(failures==viewFailures && views.count+1==(goldens["views"] as! [Any]).count,"\(views.count) item views match prompt4.py byte for byte; only the 401-action request is over capacity in both")
let renderFailures=failures
for rendered in goldens["rendered"] as! [[String:Any]] {
    let id=rendered["case"] as! String
    let prompt=try QwenNoThinkingTemplate.render(instruction:CanonicalGrounding.instruction,evidence:views[id]!.text,prefill:CanonicalGrounding.prefill)
    expect(prompt==rendered["prompt"] as? String,"\(id): rendered prompt differs")
}
named(failures==renderFailures,"rendered prompts (template + prefill) match prompt4.py")

// MARK: validate / salvage / check parity

var results:[String:(id:String,result:Result<CanonicalNoteOutput,WriterRejection>)]=[:]
func compare(_ entry:[String:Any],prefix:String="",_ work:() throws -> CanonicalNoteOutput) {
    let label=entry["label"] as! String,id=entry["case"] as! String
    let wantOK=entry["ok"] as! Bool
    do {
        let note=try work()
        results[prefix+label]=(id,.success(note))
        if wantOK {
            let want=try? decode(CanonicalNoteOutput.self,entry["note"]!)
            expect(note==want,"\(label): note differs\n swift  \(json(note))\n python \(want.map {json($0)} ?? "?")")
        } else {
            expect(false,"\(label): Swift accepted, Python rejected (\(entry["code"] ?? "")): \(json(note))")
        }
    } catch let rejection as WriterRejection {
        results[prefix+label]=(id,.failure(rejection))
        expect(!wantOK && rejection.code==entry["code"] as? String && rejection.reason==entry["reason"] as? String,
               "\(label): Swift rejected (\(rejection.code)) \(rejection.reason); Python ok=\(wantOK) \(entry["code"] ?? "") \(entry["reason"] ?? "")")
    } catch {
        expect(false,"\(label): unexpected error \(error)")
    }
}
func context(_ entry:[String:Any])->(CanonicalNoteRequest,ModelView) {let id=entry["case"] as! String;return (requests[id]!,views[id]!)}

let validateEntries=goldens["validate"] as! [[String:Any]]
var before=failures
for entry in validateEntries {
    let (request,view)=context(entry)
    compare(entry) {
        let note=try CanonicalGrounding.validate(entry["raw"] as! String,request:request,view:view,provider:entry["provider"] as! String)
        return try CanonicalGrounding.check(note,request:request,view:view)
    }
}
let rejectProbes=validateEntries.filter {($0["label"] as! String).hasPrefix("reject-")}
named(failures==before && rejectProbes.allSatisfy {!($0["ok"] as! Bool) && $0["code"] as? String==$0["expectCode"] as? String},
      "validate + check agree with validator8 on \(validateEntries.count) answers (expected notes, \(rejectProbes.count) must-reject probes with the expected codes, accept probes)")
let salvageEntries=goldens["salvage"] as! [[String:Any]]
before=failures
for entry in salvageEntries {
    let (request,view)=context(entry)
    compare(entry,prefix:"salvage:") {
        let note=try CanonicalGrounding.salvage(entry["raw"] as! String,request:request,view:view,provider:entry["provider"] as! String)
        return try CanonicalGrounding.check(note,request:request,view:view)
    }
}
named(failures==before,"salvage agrees with salvage6 on \(salvageEntries.count) real-model answers")
let checkEntries=goldens["check"] as! [[String:Any]]
before=failures
for entry in checkEntries {
    let (request,view)=context(entry)
    let note=try decode(CanonicalNoteOutput.self,entry["note"]!)
    compare(entry,prefix:"check:") {try CanonicalGrounding.check(note,request:request,view:view)}
}
named(failures==before,"check() accepts or refuses \(checkEntries.count) stored notes exactly as prompt4.py does")
named(checkEntries.first {$0["label"] as? String=="cites-idle"}?["code"] as? String=="check" && checkEntries.first {$0["label"] as? String=="old-version"}?["ok"] as? Bool==false,
      "check(): a bullet citing hidden idle time, or a prompt4-era note, is refused")
before=failures
for entry in goldens["repair"] as! [[String:Any]] {
    let (_,view)=context(entry)
    let evidence=CanonicalGrounding.repairEvidence(view,previous:entry["previous"] as! String,problem:entry["problem"] as! String)
    expect(evidence==entry["evidence"] as? String,"repair evidence differs for \(entry["case"]!)\n\(evidence)")
}
for entry in goldens["withPrefill"] as! [[String:Any]] {
    expect(CanonicalGrounding.withPrefill(entry["raw"] as! String)==entry["result"] as? String,"withPrefill(\(entry["raw"]!))")
}
named(failures==before,"repair-turn evidence and prefill re-attachment match")

// MARK: the design's guarantees, stated one by one

func note(_ label:String)->CanonicalNoteOutput? {if case .success(let n)? = results[label]?.result {return n};return nil}
func rejection(_ label:String)->WriterRejection? {if case .failure(let r)? = results[label]?.result {return r};return nil}
let accepted=results.filter {!$0.key.hasPrefix("check:")}.compactMap {label,entry in (try? entry.result.get()).map {(label:label,id:entry.id,note:$0)}}

// multi-action grouped bullets
let grouped=note("E13-grouped")
named(grouped?.bullets.count==1 && grouped?.bullets[0].actionIDs.count==20,"grouped: one bullet may cite 11 items and carries all 20 action IDs")
named(note("expected-E01")?.bullets.map(\.actionIDs.count)==[20] && note("expected-E18")?.bullets.map(\.actionIDs.count)==[3,4],
      "grouped: a window's clicks, shortcuts and Return presses fold into one bullet (E01: 20 actions); Chrome typing + Return (E18: 3 and 4)")

// every action cited at least once
var uncited:[String]=[]
for (label,id,n) in accepted {
    let idle=Set(views[id]!.hidden.flatMap {$0.actions.map(\.id)})
    if Set(n.bullets.flatMap(\.actionIDs)) != Set(requests[id]!.actions.map(\.id)).subtracting(idle) {uncited.append(label)}
}
named(uncited.isEmpty && accepted.count>=60,"coverage: every action except idle time is cited, and idle never, in all \(accepted.count) accepted notes \(uncited)")
named(rejection("reject-09-coverage")?.code=="coverage","coverage: an answer that leaves out a typed draft is rejected")
let also=note("E08-also-bullet")
named(also?.bullets.last?.text.hasPrefix("Also had ")==true && Set(also!.bullets.flatMap(\.actionIDs)).count==requests["E08"]!.actions.count,
      "coverage: windows the model left out get a code-written \"Also had ... open.\" bullet")

// bullet cap
named(rejection("E13-four-bullets")?.reason=="The answer has 4 bullets. Write 1 to 3; items of the same kind can share one, like i1 and i2." && rejection("E01-robotic")?.code=="structure","cap: 4 bullets for a moment is rejected (cap 3), including the owner's robotic E01 summary")
let dayView=views["E02"]!,dayRequest=requests["E02"]!
let sixBullets=#"{"title":"Day","bullets":["#+(1...6).map {#"{"ids":["i\#($0)"],"text":"Had item \#($0) open."}"#}.joined(separator:",")+"]}"
do {_ = try CanonicalGrounding.validate(sixBullets,request:dayRequest,view:dayView,provider:local);named(false,"cap: 6 bullets for a day is rejected (cap 5)")}
catch let r as WriterRejection {named(r.reason=="The answer has 6 bullets. Write 1 to 5; items of the same kind can share one, like i1 and i3.","cap: 6 bullets for a day is rejected (cap 5)")}
let salvagedSix=note("salvage:E13-six")
named(salvagedSix?.bullets.count==4,"cap: salvage keeps the first 3 model bullets of 6 and writes the rest as one code bullet")
named(accepted.allSatisfy {_,id,n in n.bullets.count<=(views[id]!.scope == .day ? 5:3)+4 && n.bullets.allSatisfy {$0.text.count<=240}},"cap: no accepted note has more than cap + 4 bullets or a bullet over 240 characters")
named(rejection("E03-too-long")?.code=="structure","size: a bullet over 240 characters is rejected")

// grounded overclaim: the words are in the evidence, but a report or an email subject is not proof
let overclaim="All 42 StreakMergeTests pass and the merge bug is fixed."
named(views["E06"]!.text.contains("42") && rejection("reject-15-unframed")?.code=="unframed","overclaim: \"\(overclaim)\" is rejected although every word is in the evidence")
named(rejection("reject-16-unframed")?.code=="unframed" && rejection("reject-19-unframed")?.code=="unframed","overclaim: an email subject or a relayed report stated as fact is rejected")
let relays=note("E06-framed-relays")
named(relays?.bullets.map(\.assertion)==["observed","observed","reported","draft"],"overclaim: the same facts framed as \"reported\"/\"subject says\" are accepted with derived labels")
let rescued=note("salvage:E06-overclaims")
named(rescued != nil && !rescued!.bullets.contains {$0.text==overclaim || $0.text.hasPrefix("Sent ") || $0.text=="All checks passed on tallybird main #1287."},
      "overclaim: salvage drops the overclaims and writes attributed bullets instead")

// injection
named(rejection("reject-25-leak")?.code=="leak" && rejection("reject-26-leak")?.code=="leak","injection: bullets repeating control tokens or \"ignore previous instructions\" are rejected")
named(note("E09-injected-title")?.title=="Mail, Pages and Notes","injection: an injected title is replaced by the code-written fallback")
let injectedReason=rejection("E09-repair-reason")?.reason ?? "ignore"
named(!injectedReason.lowercased().contains("ignore") && !injectedReason.contains("finished"),"injection: the repair reason is fixed text and never echoes evidence")
named(views.values.allSatisfy {$0.text.range(of:#"(?i)ignore previous|im_start|im_end|<\||</?think|admin mode"#,options:.regularExpression)==nil},
      "injection: no item view shows injected text or control tokens")
named(views["X-app-name"]!.text.contains("i1. an app: ") && !views["X-app-name"]!.text.contains("Quote\"App"),"injection: app names are cleaned; an injected app name is shown as \"an app\"")

// draft / sent / reported stay distinct
named(note("E04-labels")?.bullets.map(\.assertion)==["draft","sent","observed"],"labels: draft, sent and observed come from action states, not the model")
named(rejection("reject-06-send")?.code=="send" && rejection("reject-07-send")?.code=="send" && rejection("reject-12-send")?.code=="send",
      "labels: \"sent\"/\"replied\" wording without a sent state is rejected")
named((42...49).allSatisfy {n in rejectProbes.contains {($0["label"] as! String).hasPrefix(String(format:"reject-%02d-",n))}} && rejection("reject-42-send")?.code=="send"
      && rejection("reject-44-send")?.code=="send" && rejection("reject-45-claim")?.code=="claim" && rejection("reject-49-send")?.code=="send",
      "labels: \"wrote back\", \"hit Send\", \"sending is confirmed\" and \"pressed Return to send\" are rejected")
named(rejection("reject-79-sendword")?.code=="sendword" && note("X-sent-mailbox")?.bullets.map(\.text)==["Had a mailbox open in Mail."]
      && note("salvage:X-sent-mailbox-only")?.bullets.map(\.text)==["Had Mail open."],
      "core gate: a \"Sent Mailbox\" title is never repeated in a non-SENT bullet (core's commitNote refuses the word)")
named(note("instruction-example")?.bullets.map(\.assertion)==["submitted","observed","submitted","draft"],"labels: the instruction's worked example validates as submitted/observed/submitted/draft")
// sat5: typing whose words the writer doesn't see is one run with its window and about how long, never a count of drafts;
// that duration may be repeated, no other.
named(views["X-claude-run"].map { v in v.items.filter { $0.kind == .typed }.count==1 && v.text.hasSuffix("i3. Claude (AI app): typed text (not captured) in \"Tallybird launch plan\" over about 2 minutes; sending unknown") && !v.text.contains("drafts") }==true
      && note("X-claude-run-plain")?.bullets.first?.text=="Wrote a message in Claude (about 2 minutes)."
      && note("salvage:X-claude-run-sent")?.bullets.first?.text=="Typed a draft in Claude (about 2 minutes)."
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
named(views["X-day-items"]!.items.count==1 && views["X-chat-41"]!.items.count==2 && views["X-day-real"]!.items.count<=ModelView.maxItems,
      "capacity: 41 windows, a 41-message chat and a 390-action day fold per app instead of waiting")
named(views["X-e18-installed"]!.text==views["E18"]!.text,"chrome: an installed \"Google Chrome\" name groups with the extension's \"Chrome\"")
named(!views["X-private"]!.text.contains("Patel") && !views["X-private"]!.text.contains("Chase") && views["E10"]!.text.contains("a personal finance note (details hidden)"),
      "privacy: doctor names, conditions and bank or card problems are hidden from the model")
named(["X-inject-portal","X-inject-invoice","X-inject-billing","X-inject-typed"].allSatisfy {views[$0]!.text.contains("text addressed to AI tools")},
      "injection: text addressed to AI summarizers is masked")
named(rejection("reject-52-name")?.code=="name" && rejection("reject-61-claim")?.code=="claim" && rejection("reject-65-worked")?.code=="worked"
      && rejection("reject-73-number")?.code=="number" && rejection("reject-55-sentences")?.code=="sentences" && rejection("reject-59-notverified")?.code=="notverified",
      "grounding: invented names, meetings, work on an unused window, partial numbers, extra sentences and unhedged reports are rejected")
named(note("E18-trailing-text") != nil && note("X-e18-installed") != nil && note("X-things") != nil && note("X-1password") != nil
      && note("X-invoice-quoted")?.title=="Acme invoice" && note("X-invoice-fallback")?.title=="Invoice from Acme Inc",
      "no false rejections: text after the JSON, Things 3, 1Password and titles ending in \".\" pass check()")

// real-model run (prompt-work/v7/real-run): first answers that were right but rejected, and the limits of the fix
named(note("E14-translated")?.bullets.first?.text.contains("compared")==true && rejection("reject-80-claim")?.code=="claim",
      "translation: a framed claim in the English gist of Spanish typing is accepted; terse English notes still need the claim's own words")
named(note("E08-host-name")?.bullets.contains {$0.text.contains("GitHub")}==true && rejection("reject-81-name")?.code=="name",
      "names: \"GitHub\" read from www.githubstatus.com is accepted; a name that is not in the host is not")
named(rejection("E17-four-bullets")?.reason=="The answer has 4 bullets. Write 1 to 3; items of the same kind can share one, like i2 and i4."
      && rejection("E13-unframed")?.code=="unframed" && rejection("E01-robotic")?.reason=="The answer has 4 bullets. Write 1 to 3; items of the same kind can share one.",
      "repair: the count reason names two bullets of one kind to merge, and draft words after a \";\" get the unframed reason")
named(rejection("reject-82-send")?.reason=="bullet 1 says \"sent\", but only SENT items may use that word, even to retell a draft (\"will send\", not \"will be sent\"). Write \"drafted\" or \"typed\", and \"sending isn't confirmed\" when the item says so.",
      "repair: the send reason says the word itself is out, even when retelling what a draft promises")
named(note("E03-will-go-out")?.bullets.first?.text=="Drafted a reply thanking Priya for the iPad streak reset repro, noting the TestFlight link will go out once the build is ready; sending isn't confirmed.",
      "core gate: a framed \"will be sent\" retelling a draft that says send becomes \"will go out\", since core refuses \"sent\"")
named(note("salvage:E18-sent-draft")?.bullets.map(\.text)==["Typed Q3 offsite notes on docs.google.com in Chrome: book the venue by Friday and send the agenda.","Wrote a message on mail.google.com in Chrome."]
      && note("salvage:E18-sent-draft")?.bullets.last?.actionIDs.count==4,
      "chrome: a salvaged Gmail draft names the site, says only where (validator9) and takes its own tab")
named(note("E06-missing-brace")?.bullets.count==4 && rejection("E11-cut-in-string")?.code=="structure",
      "json: an answer that stops before its last \"}\" is closed; one cut off inside a string is still rejected")

// prompt7 / validator9 (summaries/v3): send facts, lead words, recipients, copy guard v2, NEXT, the K2 intent fixtures
let k2=validateEntries.filter {($0["label"] as! String).hasPrefix("K2-")}
named(k2.count>=50 && (goldens["salvage"] as! [[String:Any]]).filter {($0["label"] as! String).hasPrefix("K2-")}.allSatisfy {$0["ok"] as! Bool},
      "K2: \(k2.count) intent-fixture lines (F01-F29) validate exactly as validator9, and every fixture salvages to a true line")
named(note("K2-F05-line1")?.bullets.first?.assertion=="submitted" && note("K2-F09-line1")?.bullets.first?.assertion != "submitted"
      && rejection("K2-F09-line2")?.code=="send" && rejection("K2-F29-line2")?.code=="send",
      "verbs: \"Emailed\" is allowed only for a detected send (label submitted); a draft never says Emailed or Texted")
named(rejection("K2-F27-line2")?.code=="lead" && rejection("K2-F28-line2")?.code=="lead" && note("K2-F27-line1") != nil,
      "verbs: a send the Mac couldn't see (button click) is \"Wrote\", never \"Asked\"")
named(rejection("K2-F06-line2") != nil && rejection("K2-F11-line2") != nil && rejection("K2-F12-line2") != nil && note("K2-F08-line1") != nil && note("K2-F06-line1") != nil,
      "recipients: only the read to/in name or \"someone\"; never a name from the typed words or the next window; \"Replied to Priya's email\" from a Re: title")
named(rejection("K2-F01-line5")?.code=="copy" && rejection("K2-F10-line2")?.code=="copy" && rejection("K2-F20-line2")?.code=="copy" && note("K2-F16-line2") != nil,
      "copy guard v2: 6+ of the person's words in a row, or a whole short draft, are refused; names and numbers are free")
named(views["K2-F12"]!.text.contains("NEXT:\nn1. Messages: \"Priya\" open") && note("K2-F23-line1")?.bullets.first?.text.contains(", then edited")==true
      && views["X-example"]!.text.contains("n1. Xcode: \"ExportView.swift — tallybird\" open and in use, typed"),
      "NEXT: windows after the last send are n1-n3, code typed there folds in as \", typed\"")
named(views["K2-F02"]!.items.filter {$0.kind == .typed}.count==1 && views["K2-F01"]!.text.contains("Start with: Asked, Approved") && views["K2-F01"]!.text.count>800,
      "units: the pieces of one typed run are one item with all their words (up to 1,600 characters for an AI app)")
named(views["K2-F24"]!.text.contains("a personal health note (details hidden)") && views["K2-F28"]!.text.contains("typed text (not captured)") && note("K2-F28-line1") != nil,
      "privacy: health text stays hidden in an AI app; a wordless send says only where")

print("\(failures==0 ? "PASS" : "FAIL") PromptChecks: \(passes) checks, \(failures) failures")
exit(failures==0 ? 0:1)
