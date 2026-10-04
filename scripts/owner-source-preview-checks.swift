import Foundation
import MemoryCore

var passed = 0, failed = 0
func check(_ ok: Bool, _ label: String) { print("\(ok ? "PASS" : "FAIL") \(label)"); if ok { passed += 1 } else { failed += 1 } }
let epoch = Date(timeIntervalSince1970: 1_800_000_000)
let base = URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
func fixture(_ name: String) throws -> (MemoryStore, InMemoryTypedKeyStore) {
    let store = try MemoryStore(home:base.appendingPathComponent(name),writable:true,automaticallySyncSearch:false)
    var settings = try store.policy(); settings.captureText = true; settings.typedConsentVersion = 1
    try store.updatePolicy(settings,now:epoch)
    let keys = InMemoryTypedKeyStore()
    try store.attachVault(TypedTextVault(keyStore:keys),now:epoch)
    try store.setUpTypedVault(now:epoch); try store.acceptSafeTyping(now:epoch)
    return (store,keys)
}
func row(_ id: String,_ text: String,run: String? = nil,part: Int = 1,send: Bool = true,window: String = "w",focus: String = "f",field: String = "message",surface: String = "text",to: String = "Avery",title: String = "Avery",generation:UInt64 = 1,app:String = "Messages",bundle:String = "com.apple.MobileSMS",url:String = "",version:String = "typed-unit/v3",withheld:Int = 0) -> Evidence {
    var evidence = Evidence(id:id,at:iso(epoch.addingTimeInterval(Double(part-1))),kind:"keyboard.text_input",app:app,bundle:bundle,title:title,url:url,text:text,synthetic:true)
    if let run {
        var unit = TypedUnitProvenance(runID:run,part:part,sealReason:send ? "submit":"idle",startedAt:iso(epoch),keys:nil,edits:nil,withheld:withheld,surface:surface,field:field,send:send ? "detected":"unknown",sendBy:send ? "return":nil,to:to)
        unit.version = version
        evidence.captureProvenance = NativeCaptureProvenance(policyRevision:"r",classifierVersion:"sensitive-typing/v2",windowID:window,focusID:focus,checkedAt:iso(epoch),generation:generation,unit:unit)
    }
    return evidence
}
@main struct PreviewChecks {
 static func main() throws {
    let (store,keys) = try fixture("main")
    let text = "The outline still lacks examples; could you suggest a concrete opening and mark the repetitive sections?"
    check(try store.ingest(row("one",text,run:"one"),now:epoch),"fictional short source ingests sealed")
    let one = try store.ownerSourcePreviews(["one"],now:epoch.addingTimeInterval(2))
    check(one.count==1 && one[0].parts.map(\.text)==[text],"short quote retains exact absence and both requests")
    check(one.first?.actionIDs==["one"] && one.first?.runID=="one","source IDs and verified run retained")
    check(one.first?.state=="submitted" && one.first?.parts.first?.state=="submitted" && one.first?.lead=="Submitted text to Avery in Messages","send gesture remains submitted, never delivery")
    check(one.first?.expiresAt==epoch.addingTimeInterval(7*86400),"projection exposes current earliest retention deadline")
    check(String(describing:one[0])=="OwnerSourcePreview(redacted)" && Mirror(reflecting:one[0]).children.isEmpty,"default diagnostic presentation redacts quote")
    check(try store.read("one",now:epoch)?.evidence.text=="" && store.action("one",now:epoch)?.description.contains("examples")==false,"projection writes no raw text into canonical records or actions")
    check(try store.searchResult(MemorySearchQuery("repetitive"),now:epoch).items.isEmpty,"preview text is not added to search")
    check(try store.ownerSourcePreviews(["one","one"],now:epoch).count==1,"duplicate requested ID never duplicates quote")
    check(try store.ownerSourcePreviews(["one"],now:epoch,characterLimit:20).isEmpty,"short limit never clips a clause into a misleading quote")
    check(try store.ownerSourcePreviews(["one"],now:epoch,characterLimit:401).isEmpty,"caller cannot broaden short-source bound")
    check(try store.ingest(row("long",String(repeating:"Review the plan. ",count:40),run:"long"),now:epoch),"fictional long source ingests")
    check(try store.ownerSourcePreviews(["long"],now:epoch).isEmpty,"long source remains on existing model-summary path")
    let first = "The Astronomy Society Club (ASC) application is the one discussed."
    let second = "I did not get into ASC. I might apply again, but I am unsure. Do they recruit in spring?"
    _ = try store.ingest(row("r1",first,run:"verified",part:1,send:false),now:epoch)
    _ = try store.ingest(row("r2",second,run:"verified",part:2),now:epoch)
    let joined = try store.ownerSourcePreviews(["r2","r1"],now:epoch.addingTimeInterval(2))
    check(joined.count==1 && joined[0].parts.map(\.text)==[first,second] && joined[0].actionIDs==["r1","r2"],"same verified run retains every exact part and ID in recorded part order")
    check(joined.first?.state=="submitted" && joined.first?.parts.map(\.state)==["draft","submitted"],"run lead follows last observed gesture while preserving each part's state")
    check(try store.ownerSourcePreviews(["r2"],now:epoch.addingTimeInterval(2)).isEmpty,"missing initial run part cannot become a complete quote")
    for (label,a,b) in [
      ("same title distinct runs",row("a1","First draft.",run:"different-1",send:false),row("a2","Second draft.",run:"different-2",send:false)),
      ("changed focus",row("f1","First draft.",run:"shared-f",send:false),row("f2","Second draft.",run:"shared-f",send:false,focus:"other")),
      ("changed sealed email recipient",row("m1","First draft.",run:"shared-m",send:false,surface:"email"),row("m2","Second draft.",run:"shared-m",send:false,surface:"email",to:"Blake")),
      ("changed window",row("b1","First draft.",run:"shared-b",send:false),row("b2","Second draft.",run:"shared-b",send:false,window:"other")),
      ("changed field",row("c1","First draft.",run:"shared-c",send:false),row("c2","Second draft.",run:"shared-c",send:false,field:"body")),
      ("changed recipient",row("d1","First draft.",run:"shared-d",send:false),row("d2","Second draft.",run:"shared-d",send:false,to:"Blake")),
      ("same text no verified run",row("e1","Same draft.",send:false),row("e2","Same draft.",send:false)),
      ("changed generation",row("g1","First draft.",run:"shared-g",send:false),row("g2","Second draft.",run:"shared-g",send:false,generation:2)),
      ("changed page same host",row("p1","First draft.",run:"shared-p",send:false,url:"https://example.test/one"),row("p2","Second draft.",run:"shared-p",send:false,url:"https://example.test/two"))
    ] {
      _ = try store.ingest(a,now:epoch); _ = try store.ingest(b,now:epoch)
      let values = try store.ownerSourcePreviews([a.id,b.id],now:epoch)
      check(values.count==2 && values.allSatisfy{$0.actionIDs.count==1 && $0.state=="draft"},label+" does not merge unrelated drafts")
    }
    _ = try store.ingest(row("rename1","First piece.",run:"rename",send:false,title:"Original title"),now:epoch)
    _ = try store.ingest(row("rename2","Next piece.",run:"rename",part:2,title:"Renamed title"),now:epoch)
    check(try store.ownerSourcePreviews(["rename1","rename2"],now:epoch.addingTimeInterval(3)).count==1,"renamed title retains verified source run without title inference")
    _ = try store.ingest(row("closed1","First finished message.",run:"closed"),now:epoch)
    _ = try store.ingest(row("closed2","Next separate message.",run:"closed",part:2),now:epoch)
    // claude/messages2-1003 (owner 10/3: "every sent text must appear"): a run whose earlier part was sent is two messages,
    // each its own preview ending at its send; never one merged quote (before: nothing at all).
    let closed = try store.ownerSourcePreviews(["closed1","closed2"],now:epoch.addingTimeInterval(3))
    check(closed.count==2 && closed.allSatisfy { $0.actionIDs.count==1 && $0.state=="submitted" } && Set(closed.flatMap(\.actionIDs))==["closed1","closed2"],
          "a prior submitted part cannot merge a later message")
    var secure=row("secure","A private field.",run:"secure"); secure.secure=true
    _ = try store.ingest(secure,now:epoch)
    check(try store.ownerSourcePreviews(["secure"],now:epoch).isEmpty,"secure source never supplies owner quote")
    var privateRow=row("private","A private window.",run:"private"); privateRow.privateWindow=true
    _ = try store.ingest(privateRow,now:epoch)
    check(try store.ownerSourcePreviews(["private"],now:epoch).isEmpty,"private-window source never supplies owner quote")
    _ = try store.ingest(row("withheld","Incomplete visible words.",run:"withheld",withheld:1),now:epoch)
    check(try store.ownerSourcePreviews(["withheld"],now:epoch).isEmpty,"withheld source is refused rather than quoted as complete")
    _ = try store.ingest(row("badpart","Missing initial piece.",run:"partial",part:2),now:epoch)
    check(try store.ownerSourcePreviews(["badpart"],now:epoch.addingTimeInterval(3)).isEmpty,"part gap refused")
    _ = try store.ingest(row("dup1","First piece.",run:"duplicate",send:false),now:epoch)
    _ = try store.ingest(row("dup2","Second piece.",run:"duplicate",send:false),now:epoch)
    check(try store.ownerSourcePreviews(["dup1","dup2"],now:epoch).isEmpty,"duplicate part numbers never choose arbitrary content")
    let fixtureToken="ghp_"+String(repeating:"Q7x",count:12)
    _ = try store.ingest(row("legacy-marker","deploy with "+fixtureToken+" today",send:false),now:epoch)
    let legacyWords=try store.hydrateTypedText("legacy-marker",disclosure:.owner,now:epoch)
    let legacyUnit=try store.typedUnit("legacy-marker",disclosure:.owner)
    check(legacyWords?.contains(TypedSecretScrubber.marker)==true && legacyUnit==nil,"legacy no-unit source really retains scrubber marker without withheld metadata")
    check(try store.ownerSourcePreviews(["legacy-marker"],now:epoch).isEmpty,"legacy marker source is refused as incomplete")
    _ = try store.ingest(row("literal-marker","deploy [withheld] today",run:"literal-marker",send:false),now:epoch)
    check(try store.ownerSourcePreviews(["literal-marker"],now:epoch).isEmpty,"literal marker conservatively refuses apparently complete metadata")
    _ = try store.ingest(row("future","Future metadata.",run:"future",version:"typed-unit/v99"),now:epoch)
    check(try store.ownerSourcePreviews(["future"],now:epoch).isEmpty,"unknown future unit refused")
    _ = try store.ingest(row("header","Avery",run:"header",field:"to"),now:epoch)
    check(try store.ownerSourcePreviews(["header"],now:epoch).isEmpty,"composer recipient field never becomes message quote")
    check(try store.ownerSourcePreviews(["one","missing-id"],now:epoch).isEmpty,"missing selected source invalidates partial read")
    try store.delete("one")
    check(try store.ownerSourcePreviews(["one"],now:epoch).isEmpty,"deleted source quote disappears")
    var policy=try store.policy();policy.captureText=false;try store.updatePolicy(policy,now:epoch)
    check(try store.ownerSourcePreviews(["r1","r2"],now:epoch).isEmpty,"typing disabled withholds retained quote immediately")
    let (blocked,_)=try fixture("blocked")
    _ = try blocked.ingest(row("blocked","An ordinary retained draft.",run:"blocked",send:false),now:epoch)
    check(try blocked.ownerSourcePreviews(["blocked"],now:epoch).count==1,"source is visible before current app exclusion")
    var blockedPolicy=try blocked.policy();blockedPolicy.blockedApps=["com.apple.MobileSMS"]
    try blocked.updatePolicy(blockedPolicy,now:epoch)
    check(try blocked.ownerSourcePreviews(["blocked"],now:epoch).isEmpty,"new app exclusion withholds existing source")
    check(try one.first?.disclosureRevision != store.disclosureRevision(),"caller can invalidate a prior in-memory quote after policy changes")
    let (locked,lockedKeys)=try fixture("locked")
    _ = try locked.ingest(row("locked","Drafted words remain local.",run:"locked",send:false),now:epoch)
    lockedKeys.locked=true; _ = try locked.attachVault(TypedTextVault(keyStore:lockedKeys),now:epoch)
    check(try locked.ownerSourcePreviews(["locked"],now:epoch).isEmpty,"locked vault never falls back to stored plaintext")
    let reader=try MemoryStore(home:base.appendingPathComponent("locked"))
    check(try reader.ownerSourcePreviews(["locked"],now:epoch).isEmpty,"reader process without ready owner vault receives no quote")
    let (expired,_)=try fixture("expired")
    _ = try expired.ingest(row("expiry",text,run:"expiry"),now:epoch)
    let after=epoch.addingTimeInterval(7*86400+1)
    check(try expired.ownerSourcePreviews(["expiry"],now:after).isEmpty,"read-time expiry hides quote before deletion job")
    check(try expired.ownerSourcePreviews(["expiry"],now:epoch).isEmpty,"clock rollback cannot restore expired quote")
    let (forgot,_)=try fixture("forgot")
    _ = try forgot.ingest(row("forgot","Keep the private draft only here.",run:"forgot",send:false),now:epoch)
    _ = try forgot.forgetTypedText(confirmed:true,now:epoch)
    check(try forgot.ownerSourcePreviews(["forgot"],now:epoch).isEmpty,"Forget removes quote and owner key access")
    _ = keys
    print("TOTAL \(passed) PASS \(failed) FAIL")
    if failed>0{exit(1)}
 }
}
