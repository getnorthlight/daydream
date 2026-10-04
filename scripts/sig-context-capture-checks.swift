import Foundation
import PrivacyPolicy
import MemoryCore
@main struct Audit {
 static func main() throws {
  let now=Date(timeIntervalSince1970:1_800_000_000)
  let home=URL(fileURLWithPath:CommandLine.arguments[1])
  let store=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false),keys=InMemoryTypedKeyStore()
  var p=try store.policy();p.captureText=true;p.typedConsentVersion=1;try store.updatePolicy(p,now:now)
  try store.attachVault(TypedTextVault(keyStore:keys),now:now);try store.setUpTypedVault(now:now);try store.acceptSafeTyping(now:now)
  var records=[[String:Any]](),sequence=0
  func retained(_ commit:TypingCommit)->String? {
   sequence+=1
   var e=Evidence(id:"audit-\(sequence)",at:iso(now),kind:"keyboard.text_input",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Fictional controlled scratch",text:commit.text,synthetic:true)
   e.captureProvenance=NativeCaptureProvenance(policyRevision:"synthetic",classifierVersion:UnitClassifier.version,windowID:commit.proof.windowID,focusID:commit.proof.focusID,checkedAt:iso(now),generation:commit.proof.generation,unit:TypedUnitProvenance(runID:commit.runID,part:commit.part,sealReason:commit.reason.rawValue,startedAt:iso(now),keys:commit.keys,edits:commit.edits,withheld:commit.withheld,surface:"writing",field:"textArea",send:"unknown",pasted:false))
   guard (try? store.ingest(e,now:now))==true else{return nil}
   return try? store.hydrateTypedText(e.id,disclosure:.owner,now:now)
  }
  func run(_ name:String,_ pieces:[String],longPause:Bool,expected:String,control:Bool=false) {
   let h=TypingHarness();h.focus=TypingHarness.Field(bundle:"com.apple.TextEdit",window:"synthetic-w",id:"synthetic-f",role:"AXTextArea",place:"Fictional controlled scratch")
   for (i,piece) in pieces.enumerated(){h.type(piece);if i+1<pieces.count && longPause{h.advance(61)}}
   h.live(.submit)
   let captured=h.texts.joined(),scrubbed=h.texts.compactMap{TypedSecretScrubber.scrub($0).kept}.joined(),stored=h.rows.compactMap(retained).joined()
   let normalizedExpected=expected.split(whereSeparator:{$0.isWhitespace}).joined(separator:" ")
   let normalizedStored=stored.split(whereSeparator:{$0.isWhitespace}).joined(separator:" ")
   let nonWhitespaceExact=stored.filter{!$0.isWhitespace}==expected.filter{!$0.isWhitespace}
   let sameRun=h.rows.first.map{first in h.rows.allSatisfy{$0.runID==first.runID}} ?? false
   let reasons=h.texts.flatMap{TypedSecretScrubber.scrub($0).reasons.map(\.rawValue)}
   records.append(["case":name,"inputPieces":pieces.count,"captureRows":h.rows.count,"captureReads":h.reads,"captureExact":captured==expected,"captureWithheld":h.rows.map(\.withheld).reduce(0,+),"storeScrubExact":scrubbed==expected,"storeScrubReasons":reasons,"retentionExact":stored==expected,"retentionMarker":stored.contains("[withheld]"),"retentionWhitespaceNormalizedExact":normalizedStored==normalizedExpected,"sameRun":sameRun,"retentionNonWhitespaceExact":nonWhitespaceExact,"control":control])
  }
  let phrase="i didn't like the sig :("
  let full=phrase+"\nyea true that\nnot sure if i'll do it but we'll see\nr u gonna try the sig thing in winter?"
  run("full-original-multiline",[full],longPause:false,expected:full)
  run("sad-emoticon-whole",[phrase],longPause:false,expected:phrase)
  run("ordinary-email",["write to fictional.avery@example.com tomorrow"],longPause:false,expected:"write to fictional.avery@example.com tomorrow")
  run("ordinary-US-phone",["call 415-555-0123 tomorrow"],longPause:false,expected:"call 415-555-0123 tomorrow")
  run("ordinary-US-phone-spaces",["call (415) 555-0123 tomorrow"],longPause:false,expected:"call (415) 555-0123 tomorrow")
  for cut in 1..<phrase.count {
   let chars=Array(phrase);run("sad-emoticon-split-\(cut)",[String(chars[..<cut]),String(chars[cut...])],longPause:true,expected:phrase)
  }
  for (name,pieces,expected) in [
   ("email-domain-split",["write to fictional.avery@","example.com tomorrow"],"write to fictional.avery@example.com tomorrow"),
   ("phone-digit-split",["call 415-555-","0123 tomorrow"],"call 415-555-0123 tomorrow"),
   ("newline-message-split",[phrase+"\n","yea true that"],phrase+"\nyea true that")]{run(name,pieces,longPause:true,expected:expected)}
  for (name,text) in [("password","password: fictionalHorse42!"),("ssn","ssn 123-45-6789"),("card","card 4111 1111 1111 1111"),("signature","sig=FictionalToken99!")] {
   run("secret-control-"+name,[text],longPause:false,expected:text,control:true)
  }
  for r in records where ["sad-emoticon-whole","ordinary-email","ordinary-US-phone","ordinary-US-phone-spaces"].contains(r["case"] as! String) {
   precondition(r["captureExact"] as! Bool && r["retentionExact"] as! Bool && !(r["retentionMarker"] as! Bool) && (r["captureReads"] as! Int)>0,"ordinary complete synthetic text changed")
  }
  for r in records where ["full-original-multiline","newline-message-split"].contains(r["case"] as! String) {
   precondition(r["captureExact"] as! Bool && r["retentionNonWhitespaceExact"] as! Bool && !(r["retentionMarker"] as! Bool),"newline change exceeds whitespace normalization")
  }
  let splitFailures=records.filter{($0["case"] as! String).hasPrefix("sad-emoticon-split-") && ($0["retentionMarker"] as! Bool)}
  precondition(splitFailures.isEmpty && records.filter{($0["case"] as! String).hasPrefix("sad-emoticon-split-")}.allSatisfy{($0["captureExact"] as! Bool) && ($0["captureWithheld"] as! Int)==0 && ($0["retentionExact"] as! Bool)},"split-assignment finding not reproduced")
  precondition(records.filter{$0["control"] as! Bool}.allSatisfy{!($0["captureExact"] as! Bool) && !($0["retentionExact"] as! Bool)},"secret control became exact")
  let data=try JSONSerialization.data(withJSONObject:["schema":"typed-scrub-synthetic-audit-v1","sourceBase":"e8b1e44b2f2e04ad084af32038060ff2319afa63","candidate":"isolated-sig-context","cases":records,"syntheticOnly":true,"GUI":false,"modelInference":false,"userStoreRead":false],options:[.prettyPrinted,.sortedKeys])
  try data.write(to:URL(fileURLWithPath:CommandLine.arguments[2]),options:.atomic)
  for r in records {print("CASE \(r["case"]!) captureExact=\(r["captureExact"]!) captureWithheld=\(r["captureWithheld"]!) scrubExact=\(r["storeScrubExact"]!) retentionExact=\(r["retentionExact"]!) reasons=\(r["storeScrubReasons"]!)")}
 }
}
