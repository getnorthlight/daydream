// Focused synthetic-only regression. Compile with PrivacyPolicy/Checks/TypingChecks.swift
// (reuses TypingHarness), fresh MemoryCore/PrivacyPolicy/HistoryCore objects and CSQLite.
// Pass a fresh scratch home as the sole argument. In-memory keys; no UI, default home,
// history, network or settings. Preserve the scratch store for receipt inspection.
import Foundation
import PrivacyPolicy
@testable import MemoryCore
var pass=0,fail=0
func check(_ ok:Bool,_ label:String){print("\(ok ? "PASS":"FAIL") \(label)");if ok{pass+=1}else{fail+=1}}
func afterStore(_ text:String)->String?{TypedSecretScrubber.scrub(text).kept}
@main struct EmoticonChecks {
 static func main() throws {
  let base=URL(fileURLWithPath:CommandLine.arguments[1]); let now=Date(timeIntervalSince1970:1_800_000_000)
  let keys=InMemoryTypedKeyStore(); let store=try MemoryStore(home:base,writable:true,automaticallySyncSearch:false)
  var policy=try store.policy();policy.captureText=true;policy.typedConsentVersion=1;try store.updatePolicy(policy,now:now)
  try store.attachVault(TypedTextVault(keyStore:keys),now:now);try store.setUpTypedVault(now:now);try store.acceptSafeTyping(now:now)
  var exactRows:[(String,String)]=[]
  func save(_ id:String,_ text:String) throws -> String? {
   let e=Evidence(id:id,at:iso(now),kind:"keyboard.text_input",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Fictional scratch",text:text,synthetic:true)
   guard try store.ingest(e,now:now) else {return nil};return try store.hydrateTypedText(id,disclosure:.owner,now:now)
  }
  let faces=[":(",":-(",":)",":-)", ";)", ";-)", ":/", ":\\", ":|", ":P", ":p", ":D", ":'(", ">:(", "XD", "<3", "🙂", "😞", ":["]
  for (i,face) in faces.enumerated() {
   let source="i didn't like the sig "+face
   let h=TypingHarness();h.focus=TypingHarness.Field(bundle:"com.apple.MobileSMS",window:"fictional-w",id:"fictional-f",role:"AXTextArea",place:"Fictional counterpart")
   h.type(source);h.live(.submit)
   check(h.texts==[source] && h.rows.allSatisfy{$0.withheld==0},"capture phrase-emoticon case-\(i)")
   check(afterStore(source)==source && TypedSecretScrubber.scrub(source).reasons.isEmpty,"store phrase-emoticon case-\(i)")
   check(h.texts.compactMap(afterStore)==[source],"capture then store case-\(i)")
   let stored=try save("face-\(i)",source);exactRows.append(("face-\(i)",source))
   check(stored==source,"actual sealed store ingest/readback case-\(i)")
  }
  let pieces=["i didn't like the sig :(","yea true that","not sure if i'll do it but we'll see","r u gonna try the sig thing in winter?"]
  let h=TypingHarness();h.focus=TypingHarness.Field(bundle:"com.apple.MobileSMS",window:"fictional-w",id:"fictional-f",role:"AXTextArea")
  for text in pieces {h.type(text);h.press(36)}
  check(h.texts==pieces && h.rows.allSatisfy{$0.withheld==0},"four successive fresh fictional messages preserve exact text")
  check(h.texts.compactMap(afterStore)==pieces,"four successive messages capture-plus-store scrub retains all")
  let controls:[(String,String,String)]=[
   ("password","password: fictionalHorse42!","fictionalHorse42!"),
   ("card","card 4111 1111 1111 1111","4111"),
   ("ssn","ssn 123-45-6789","123-45-6789"),
   ("token","key sk-proj-abcdefghijklmnopqrstuv1234567890","abcdefghijklmnopqrstuv1234567890")]
  for (name,text,secret) in controls {
   let s=TypingHarness();s.type(text);s.live(.submit)
   check(!s.texts.joined().contains(secret),"capture control-"+name)
   check(afterStore(text)?.contains(secret) != true,"store control-"+name)
  }
  let denied:[(String,String)]=[
   ("standalone signature","sig :("),
   ("space separated signature","i discussed sig : ("),
   ("newline separated signature","i discussed sig :\n("),
   ("attached signature","i didn't like the sig:("),
   ("upper signature","i didn't like the SIG :("),
   ("code context","let sig :("),
   ("equals signature","i didn't like the sig = :("),
   ("quoted signature","i didn't like the sig : \"(\""),
   ("extended value","i didn't like the sig :(FictionalToken99"),
   ("strong password","i didn't get into password :("),
   ("strong secret","i didn't get into secret :("),
   ("strong token","i didn't get into token :("),
   ("real signature","i didn't like the sig : FictionalToken99!"),
   ("real signature equals","sig=FictionalToken99!")]
  for (i,pair) in denied.enumerated() {
   let (_,text)=pair
   check(afterStore(text) != text,"no emoticon exception "+pair.0)
   let saved=try save("deny-\(i)",text)
   check(saved == nil || saved?.contains(TypedSecretScrubber.marker) == true,"actual store still protects "+pair.0)
  }
  for (i,text) in ["we talked about sig :-(","you mentioned sig :(","they talked about sig :)"].enumerated() {
   check(afterStore(text)==text,"ordinary narrative positive-\(i)")
   check(try save("narrative-\(i)",text)==text,"actual narrative store-\(i)")
  }
  for (name,text,secret) in controls {
   let saved=try save("control-"+name,text)
   check(saved?.contains(secret) != true,"actual store secret control-"+name)
  }
  let reopened=try MemoryStore(home:base,writable:true,automaticallySyncSearch:false)
  try reopened.attachVault(TypedTextVault(keyStore:keys),now:now)
  for (id,text) in exactRows {
   check(try reopened.hydrateTypedText(id,disclosure:.owner,now:now)==text,"reopened exact fictional text "+id)
  }
  let blocked=TypingHarness();blocked.focus.label="Password";blocked.type("i didn't like the sig :(");blocked.live(.submit)
  check(blocked.texts.isEmpty && blocked.reads==0,"secure-labeled field never acquires fictional emoticon text")
  let secure=Evidence(id:"secure-field",at:iso(now),kind:"keyboard.text_input",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Fictional scratch",text:"i didn't like the sig :(",secure:true,synthetic:true)
  check(try !store.ingest(secure,now:now),"actual store denies secure field")
  let split=TypingHarness();split.type("i didn't like the sig :");split.advance(61);split.type("(");split.live(.submit)
  print("DIAGNOSTIC long-idle-split rows=\(split.rows.count) exact-full-phrase=\(split.texts.joined()==pieces[0]) markers=\(split.texts.filter{$0.contains("[withheld]")}.count)")
  let solo=TypingHarness();solo.type(":(");solo.live(.submit)
  print("DIAGNOSTIC standalone-emoticon rows=\(solo.rows.count) exact-retained=\(solo.texts==[":("])")
  print("TOTAL \(pass) PASS \(fail) FAIL");if fail>0{exit(1)}
 }
}
