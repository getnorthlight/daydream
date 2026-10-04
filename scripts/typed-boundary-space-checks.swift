// Synthetic production TypingSession -> sealed store regression; no UI/event tap/default home.
import Foundation
import PrivacyPolicy
@testable import MemoryCore
var passed=0,failed=0
func check(_ ok:Bool,_ label:String){print("\(ok ? "PASS":"FAIL") \(label)");if ok{passed+=1}else{failed+=1}}
@main struct BoundaryChecks {
 static func main() throws {
  let base=URL(fileURLWithPath:CommandLine.arguments[1]),now=Date(timeIntervalSince1970:1_800_000_000)
  let store=try MemoryStore(home:base,writable:true,automaticallySyncSearch:false),keys=InMemoryTypedKeyStore()
  var p=try store.policy();p.captureText=true;p.typedConsentVersion=1;try store.updatePolicy(p,now:now)
  try store.attachVault(TypedTextVault(keyStore:keys),now:now);try store.setUpTypedVault(now:now);try store.acceptSafeTyping(now:now)
  var saved=[(String,String)]()
  func evidence(_ id:String,_ text:String)->Evidence {
   var e=Evidence(id:id,at:iso(now),kind:"keyboard.text_input",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Owned fictional scratch",text:text,synthetic:true)
   e.captureProvenance=NativeCaptureProvenance(policyRevision:"fixture",classifierVersion:UnitClassifier.version,windowID:"fixture-A",focusID:"fixture-field-A",checkedAt:iso(now),generation:1,unit:TypedUnitProvenance(runID:id,part:1,sealReason:"window",startedAt:iso(now),keys:nil,edits:nil,withheld:0,surface:"writing",field:"textArea",send:"unknown"))
   return e
  }
  func save(_ e:Evidence)->String? {
   guard (try? store.ingest(e,now:now))==true else{return nil}
   return try? store.hydrateTypedText(e.id,disclosure:.owner,now:now)
  }
  let cases=[
   ["alpha draft starts","beta draft stays separate"," and finishes here"],
   ["i started a chess club note","write the morning plan"," about the vote and support"],
   ["i started a chess club note","write the morning plan"," about the vote and support"]]
  for (n,texts) in cases.enumerated() {
   let h=TypingHarness()
   let a=TypingHarness.Field(bundle:"com.apple.TextEdit",window:"fixture-A",id:"fixture-field-A",role:"AXTextArea",place:"Owned fictional A")
   let b=TypingHarness.Field(bundle:"com.apple.TextEdit",window:"fixture-B",id:"fixture-field-B",role:"AXTextArea",place:"Owned fictional B")
   for i in 0..<3 {
    h.focus=i==1 ? b:a;h.type(texts[i])
    if n==2 && i != 1 {h.type("x");h.press(51)}
    h.live(i==2 ? .suspend:.window)
   }
   check(h.texts==texts && h.rows.count==3,"capture classifier preserves complete per-visit case-\(n)")
   var opened=[String](),ids=[String]()
   for (i,c) in h.rows.enumerated() {
    let id="case-\(n)-\(i)";ids.append(id)
    var e=evidence(id,c.text)
    e.captureProvenance=NativeCaptureProvenance(policyRevision:"fixture",classifierVersion:UnitClassifier.version,windowID:c.proof.windowID,focusID:c.proof.focusID,checkedAt:iso(now),generation:c.proof.generation,unit:TypedUnitProvenance(runID:c.runID,part:c.part,sealReason:c.reason.rawValue,startedAt:iso(now),keys:c.keys,edits:c.edits,withheld:c.withheld))
    let field=SendRules.fieldClass(role:c.proof.role,labels:[c.proof.fieldLabel])
    e.captureProvenance?.unit?.apply(SendRules.facts(bundle:c.proof.bundle,host:nil,title:c.proof.place,field:field,seal:c.reason),pasted:false)
    opened.append(save(e) ?? "")
    saved.append((id,texts[i]))
    check(try store.read(id,now:now)?.evidence.text=="" && store.read(id,now:now)?.evidence.typed != nil,"captured piece sealed and canonical body empty case-\(n)-\(i)")
   }
   check(opened==texts,"sealed ingest exact per-visit case-\(n)")
   check(opened.count==3 && opened[0]+opened[2]==texts[0]+texts[2],"returned A exact concatenation case-\(n)")
   check(opened.count==3 && opened[1]==texts[1],"interruption B remains exact case-\(n)")
   let actions=try store.actions(limit:100,now:now).actions.filter{!Set($0.evidenceIDs).isDisjoint(with:ids)}
   check(actions.count==3 && actions.allSatisfy{$0.state=="draft"},"source-only sequence never claims submission case-\(n)")
  }
  for (n,text) in ["  bounded leading","bounded trailing  ","  both edges  ","\nnext line\n"," lead\u{00a0}\u{00a0}  next\u{200b} "].enumerated() {
   let expected=["  bounded leading","bounded trailing  ","  both edges  ","next line"," lead next "][n],id="edge-\(n)"
   check(save(evidence(id,text))==expected,"safe structured outer ASCII space case-\(n)")
   saved.append((id,expected))
  }
  let ordinary="  ordinary words  "
  for n in 0..<11 {
   var e=evidence("unknown-\(n)",ordinary)
   switch n {
    case 0:e.captureProvenance=nil
    case 1:e.captureProvenance?.unit?.version="future/unknown"
    case 2:e.captureProvenance?.unit?.withheld=1
    case 3:e.captureProvenance?.windowID=""
    case 4:e.captureProvenance?.focusID=""
    case 5:e.captureProvenance?.generation=0
    case 6:e.captureProvenance?.unit?.runID=""
    case 7:e.captureProvenance?.unit?.part=0
    case 8:e.captureProvenance?.unit?.field=nil
    case 9:e.captureProvenance?.unit?.field="unknown"
    default:e.captureProvenance?.unit?.field="future-field"
   }
   check(save(e)=="ordinary words","legacy or unstructured normalization unchanged case-\(n)")
  }
  check(save(evidence("literal-marker","  before [withheld] after  "))=="before [withheld] after","literal withheld marker retains conservative normalization")
  check(TypedSecretScrubber.scrub("  ordinary words  ") == .keep("ordinary words",redactions:[]),"public security normalization remains canonical")
  let controls:[(String,String)]=[
   ("  password: fictionalHorse42!  ","fictionalHorse42!"),
   ("  card 4111 1111 1111 1111  ","4111 1111"),
   ("  ssn 123-45-6789  ","123-45-6789"),
   ("  token sk-proj-abcdefghijklmnopqrstuv1234567890  ","abcdefghijklmnopqrstuv1234567890"),
   ("  sudo whoami\nfictionalHorse42!  ","fictionalHorse42!"),
   ("  123456  ","123456"),
   ("  password:\nfictionalHorse42!  ","fictionalHorse42!")]
  for (n,pair) in controls.enumerated() {
   let (text,secret)=pair,actual=save(evidence("secret-\(n)",text)),canonical=TypedSecretScrubber.scrub(text).kept.map {Privacy.secret($0) ? "" : Privacy.clean($0)}
   check(actual?.contains(secret) != true,"outer spaces cannot disclose protected secret case-\(n)")
   check(actual==nil || actual==canonical,"redacted result retains canonical safety bytes case-\(n)")
  }
  let h=TypingHarness();h.secureInput=true;h.type(" ordinary words ")
  check(h.reads==0 && h.texts.isEmpty,"Secure Input refuses before acquiring characters")
  let secure=TypingHarness();secure.focus.subrole="AXSecureTextField";secure.type(" ordinary words ")
  check(secure.reads==0 && secure.texts.isEmpty,"secure field refuses before acquiring characters")
  for (n,text) in ["\tordinary words\t","\u{00a0}ordinary words\u{00a0}","\u{0001} ordinary words \u{0002}"].enumerated() {
   check(save(evidence("control-edge-\(n)",text))=="ordinary words","non-ASCII/control boundaries retain canonical normalization case-\(n)")
  }
  let huge=evidence("huge",String(repeating:" ",count:2001)+"bounded words")
  check(save(huge)=="bounded words","boundary restoration beyond existing stored cap retains canonical safety bytes")
  let reopened=try MemoryStore(home:base,writable:true,automaticallySyncSearch:false);try reopened.attachVault(TypedTextVault(keyStore:keys),now:now)
  for (id,expected) in saved {check(try reopened.hydrateTypedText(id,disclosure:.owner,now:now)==expected,"second connection exact fixture-\(id)")}
  print("TOTAL \(passed) PASS \(failed) FAIL")
  if failed>0{exit(1)}
 }
}
