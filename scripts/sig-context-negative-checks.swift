import Foundation
import PrivacyPolicy
@testable import MemoryCore
var passes=0
func check(_ ok:Bool,_ label:String){precondition(ok,"FAILED "+label);passes+=1;print("PASS "+label)}
@main struct Negatives {
 static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]),now=Date(timeIntervalSince1970:1_800_000_000)
  func evidence(_ text:String,part:Int=1,seal:String="idle",run:String="synthetic-run",id:String="prefix")->Evidence {
   var e=Evidence(id:id,at:iso(now),kind:"keyboard.text_input",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Fictional controlled scratch",text:text,synthetic:true)
   e.captureProvenance=NativeCaptureProvenance(policyRevision:"synthetic-policy",classifierVersion:UnitClassifier.version,windowID:"synthetic-window",focusID:"synthetic-field",checkedAt:iso(now),generation:1,unit:TypedUnitProvenance(runID:run,part:part,sealReason:seal,startedAt:iso(now),keys:30,edits:0,withheld:0,surface:"writing",field:"textArea",send:"unknown",pasted:false))
   return e
  }
  let prefix=evidence("i didn't like the "),following=evidence("sig :(",part:2,seal:"submit",id:"face")
  let safe=TypedSecretScrubber.scrubbed(prefix)!
  // Restore only the already qualified ASCII boundary for this pure carrier fixture.
  let preserved=TypedSecretScrubber.restoringOuterSpaces(from:prefix,sanitized:safe)
  let carry=TypedNarrativeCarry.advancing(prefix,sanitized:preserved,previous:nil,typedPolicy:"typed-policy",epoch:"epoch",now:now)!
  check(carry.preceding(following,typedPolicy:"typed-policy",epoch:"epoch",now:now)==prefix.text,"positive certified adjacent native part")
  let variants:[(String,(inout Evidence)->Void)]=[
   ("different-run",{$0.captureProvenance?.unit?.runID="other-run"}),
   ("missing-part",{$0.captureProvenance?.unit?.part=3}),
   ("repeated-part",{$0.captureProvenance?.unit?.part=1}),
   ("zero-part",{$0.captureProvenance?.unit?.part=0}),
   ("different-window",{$0.captureProvenance?.windowID="other-window"}),
   ("different-field-identity",{$0.captureProvenance?.focusID="other-field"}),
   ("different-field-class",{$0.captureProvenance?.unit?.field="message"}),
   ("different-generation",{$0.captureProvenance?.generation=2}),
   ("different-capture-policy",{$0.captureProvenance?.policyRevision="other-policy"}),
   ("missing-capture-policy",{$0.captureProvenance?.policyRevision=""}),
   ("missing-provenance",{$0.captureProvenance=nil}),
   ("missing-unit",{$0.captureProvenance?.unit=nil}),
   ("legacy-unit",{$0.captureProvenance?.unit?.version="typed-unit/v2"}),
   ("unknown-unit",{$0.captureProvenance?.unit?.version="unknown"}),
   ("unknown-field",{$0.captureProvenance?.unit?.field="unknown"}),
   ("missing-field",{$0.captureProvenance?.unit?.field=nil}),
   ("zero-generation",{$0.captureProvenance?.generation=0}),
   ("different-classifier",{$0.captureProvenance?.classifierVersion="unknown"}),
   ("prior-withholding",{$0.captureProvenance?.unit?.withheld=1}),
   ("paste",{$0.captureProvenance?.unit?.pasted=true}),
   ("missing-paste-fact",{$0.captureProvenance?.unit?.pasted=nil}),
   ("stale-current-event",{$0.at=iso(now.addingTimeInterval(-2));$0.captureProvenance?.checkedAt=$0.at}),
   ("secure",{$0.secure=true}),
   ("other-app",{$0.bundle="com.apple.Notes"}),
   ("unknown-app",{$0.bundle="fictional.unknown"}),
   ("chrome-without-proof",{$0.bundle="com.google.Chrome"}),
   ("safari-without-proof",{$0.bundle="com.apple.Safari"}),
   ("browser",{$0.browserVerification=BrowserVerification(mode:"normal",windowID:"w",tabID:"t",focusedRole:"AXTextArea",checkedAt:iso(now),provider:"synthetic")}),
   ("stale-proof",{$0.captureProvenance?.checkedAt=iso(now.addingTimeInterval(-2))})]
  for (name,mutate) in variants {var e=following;mutate(&e);check(carry.preceding(e,typedPolicy:"typed-policy",epoch:"epoch",now:now)==nil,"carrier refuses "+name)}
  check(carry.preceding(following,typedPolicy:"other",epoch:"epoch",now:now)==nil,"typed policy transition")
  check(carry.preceding(following,typedPolicy:"typed-policy",epoch:"other",now:now)==nil,"capture epoch transition")
  var fresh=following;fresh.at=iso(now.addingTimeInterval(121));fresh.captureProvenance?.checkedAt=fresh.at
  check(carry.preceding(fresh,typedPolicy:"typed-policy",epoch:"epoch",now:now.addingTimeInterval(121))==nil,"expired carry with fresh current proof")
  check(carry.preceding(following,typedPolicy:"typed-policy",epoch:"epoch",now:now.addingTimeInterval(-1))==nil,"clock reversal")
  var noFirst=prefix;noFirst.captureProvenance?.unit?.part=2
  check(TypedNarrativeCarry.advancing(noFirst,sanitized:preserved,previous:nil,typedPolicy:"typed-policy",epoch:"epoch",now:now)==nil,"missing first part cannot bootstrap carry")
  var stopped=prefix;stopped.captureProvenance?.unit?.sealReason="suspend"
  check(TypedNarrativeCarry.advancing(stopped,sanitized:preserved,previous:nil,typedPolicy:"typed-policy",epoch:"epoch",now:now)==nil,"stopped part cannot continue narrative")
  let long=evidence("i "+String(repeating:"fictionalword ",count:11));let longSafe=TypedSecretScrubber.scrubbed(long)!
  check(TypedNarrativeCarry.advancing(long,sanitized:longSafe,previous:nil,typedPolicy:"typed-policy",epoch:"epoch",now:now)==nil,"prefix bounded to128 characters")
  var dumped="";dump(carry,to:&dumped)
  check(!dumped.contains(prefix.text) && !String(describing:carry).contains(prefix.text),"carrier diagnostics never expose prefix")
  func store(_ name:String)throws->MemoryStore {
   let s=try MemoryStore(home:root.appendingPathComponent(name),writable:true,automaticallySyncSearch:false),keys=InMemoryTypedKeyStore()
   var p=try s.policy();p.captureText=true;p.typedConsentVersion=1;try s.updatePolicy(p,now:now)
   try s.attachVault(TypedTextVault(keyStore:keys),now:now);try s.setUpTypedVault(now:now);try s.acceptSafeTyping(now:now)
   return s
  }
  func opened(_ s:MemoryStore,_ e:Evidence)->String? {guard (try? s.ingest(e,now:now))==true else{return nil};return try? s.hydrateTypedText(e.id,disclosure:.owner,now:now)}
  let good=try store("positive")
  check(opened(good,prefix)==prefix.text && opened(good,following)==following.text,"actual sealed adjacent parts exact")
  let triple=try store("three-parts"),a=evidence("i didn't "),b=evidence("like the ",part:2,id:"middle"),c=evidence("sig :(",part:3,seal:"submit",id:"last")
  check(opened(triple,a)==a.text && opened(triple,b)==b.text && opened(triple,c)==c.text,"actual three-part same-run narrative exact")
  for name in ["different-run","missing-part","different-window","different-field-identity","different-generation","different-capture-policy","legacy-unit","paste"] {
   let s=try store("sealed-"+name);check(opened(s,prefix)==prefix.text,"sealed negative prefix "+name)
   var e=following;variants.first{$0.0==name}!.1(&e)
   let text=opened(s,e);check(text?.contains("[withheld]")==true,"sealed negative remains redacted "+name)
  }
  for (name,text,secret) in [("password","password: fictionalHorse42!","fictionalHorse42!"),("secret","secret: FictionalToken99!","FictionalToken99!"),("otp","otp: 4921","4921"),("card","card 4111 1111 1111 1111","4111"),("ssn","ssn 123-45-6789","123-45-6789"),("sig-token","sig : FictionalToken99!","FictionalToken99!"),("sig-equals","sig=FictionalToken99!","FictionalToken99!")] {
   let s=try store("strong-"+name);_ = opened(s,prefix)
   let e=evidence(text,part:2,seal:"submit",id:"strong");check(opened(s,e)?.contains(secret) != true,"actual same-run strong-secret protected "+name)
  }
  for name in ["intervening-window","intervening-refused-typed","duplicate-prefix","missing-first-part"] {
   let s=try store(name)
   if name=="missing-first-part" {var e=prefix;e.captureProvenance?.unit?.part=2;_ = opened(s,e);var f=following;f.captureProvenance?.unit?.part=3;check(opened(s,f)?.contains("[withheld]")==true,"actual missing-first cannot bootstrap")}
   else {
    _ = opened(s,prefix)
    if name=="intervening-window" {_ = try s.ingest(Evidence(id:"window",at:iso(now),kind:"window.changed",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Fictional scratch",synthetic:true),now:now)}
    if name=="intervening-refused-typed" {var e=evidence("fictional",id:"refused");e.secure=true;check(try !s.ingest(e,now:now),"intervening secure part refused")}
    if name=="duplicate-prefix" {check(try !s.ingest(prefix,now:now),"duplicate does not certify another part")}
    check(opened(s,following)?.contains("[withheld]")==true,"actual intervening event clears "+name)
   }
  }
  check(carry.preceding(following,typedPolicy:"typed-policy",epoch:nil,now:now)==nil,"present epoch cannot match absent epoch")
  let absent=TypedNarrativeCarry.advancing(prefix,sanitized:preserved,previous:nil,typedPolicy:"typed-policy",epoch:nil,now:now)!
  check(absent.preceding(following,typedPolicy:"typed-policy",epoch:"epoch",now:now)==nil,"absent epoch cannot match present epoch")
  check(absent.preceding(following,typedPolicy:"typed-policy",epoch:nil,now:now) != nil,"both absent epoch equality")
  for (name,text) in [("quoted", "\"sig\" :("),("capitalized", "SIG :("),("sig-secret", "sig : FictionalToken99!"),("otp-fragment", "sig : 4921"),("phone-fragment", "sig : 7714"),("not-finite", "sig : ("),("equals", "sig=:(")] {
   let s=try store("context-rule-"+name);_ = opened(s,prefix)
   let e=evidence(text,part:2,seal:"submit",id:"rule")
   check(opened(s,e)?.contains("[withheld]")==true,"context refuses "+name)
  }
  for name in ["other-write","failed-write","capture-stop","stale-heartbeat","expiry-pass","consent-toggle","typing-toggle","external-write","redacted-part"] {
   let s=try store("boundary-"+name)
   if name=="capture-stop" || name=="stale-heartbeat" {try s.setCaptureState("recording",reason:"Fictional fixture",now:now)}
   _ = opened(s,prefix)
   switch name {
   case "other-write": try s.transaction {try s.exec("INSERT OR REPLACE INTO metadata VALUES('fictional-boundary','1')")}
   case "failed-write": do {try s.transaction {try s.exec("INVALID FICTIONAL SQL")}} catch {}
   case "capture-stop": try s.setCaptureState("paused",reason:"Fictional fixture",now:now);try s.setCaptureState("recording",reason:"Fictional fixture",now:now)
   case "stale-heartbeat": try s.setCaptureState("recording",reason:"Fictional fixture",now:now.addingTimeInterval(6))
   case "expiry-pass": _ = try s.expireTypedText(now:now)
   case "consent-toggle": var p=try s.policy();p.captureText=false;try s.updatePolicy(p,now:now);p.captureText=true;try s.updatePolicy(p,now:now)
   case "typing-toggle": _ = try s.snoozeTyping(minutes:1,now:now);try s.resumeTyping(now:now)
   case "external-write": let other=try MemoryStore(home:s.home,writable:true,automaticallySyncSearch:false);try other.transaction {try other.exec("INSERT OR REPLACE INTO metadata VALUES('fictional-external-boundary','1')")}
   case "redacted-part": let red=evidence("password: FictionalToken99!",part:2,id:"redacted");_ = opened(s,red)
   default: break
   }
   var e=following;if name=="redacted-part" {e.captureProvenance?.unit?.part=3}
   check(opened(s,e)?.contains("[withheld]")==true,"sealed lifecycle boundary refuses "+name)
  }
  let heartbeat=try store("fresh-heartbeat");try heartbeat.setCaptureState("recording",reason:"Fictional fixture",now:now);_ = opened(heartbeat,prefix)
  try heartbeat.setCaptureState("recording",reason:"Fictional fixture",now:now.addingTimeInterval(1))
  check(opened(heartbeat,following)==following.text,"fresh recording heartbeat preserves same adjacent scope")
  let forgotten=try store("forgotten");_ = opened(forgotten,prefix);_ = try forgotten.forgetTypedText(confirmed:true,now:now)
  let newKeys=InMemoryTypedKeyStore();try forgotten.attachVault(TypedTextVault(keyStore:newKeys),now:now);try forgotten.setUpTypedVault(now:now);_ = try forgotten.acceptSafeTyping(now:now)
  check(opened(forgotten,following)?.contains("[withheld]")==true,"Forget and reconsent cannot revive narrative")
  print("TOTAL \(passes) PASS 0 FAIL")
 }
}
