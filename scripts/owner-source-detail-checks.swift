import Foundation
import MemoryCore
@testable import MemoryUI

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
@main @MainActor struct DetailChecks {
 static func main() async throws {
    check(!OwnerSourceDetailState.closesOwnWindow(own:1,closing:2),"unrelated settings window close does not disable selected detail")
    check(OwnerSourceDetailState.closesOwnWindow(own:1,closing:1),"own window close clears selected detail")
    check(OwnerSourceDetailState.closesOwnWindow(own:nil,closing:1),"unknown owning window conservatively clears source")
    let (store,keys)=try fixture("detail")
    let text="The recipe lacks an oven temperature; could you add it and check the pan size?"
    _ = try store.ingest(row("short",text,run:"short"),now:epoch)
    _ = try store.ingest(Evidence(id:"window",at:iso(epoch),kind:"window.observed",app:"Messages",bundle:"com.apple.MobileSMS",title:"Avery",text:"",synthetic:true),now:epoch)
    let selected=["window","short"]
    let found=try store.ownerSourcePreviewsForActions(selected,now:epoch)
    let access=try store.ownerSourcePreviewRevision(expiresAt:found.first?.expiresAt,now:epoch)
    var state=OwnerSourceDetailState()
    var ticket=state.begin(scope:"day|moment",actionIDs:selected)
    check(state.accept(found,ticket:ticket,revision:access,now:epoch) && state.previews.first?.parts.first?.text==text,"selected detail shows exact absent fact and both requests")
    check(state.previews.first?.actionIDs==["short"] && state.previews.first?.lead=="Submitted text to Avery in Messages","typed source ownership and gesture-only caption preserved")
    let noteJSON = """
    {"id":"fixture","version":1,"schemaVersion":1,"generatedAt":"2026-09-30T15:00:00Z","inputRevision":"fixture","actionIDs":["short"],"status":"generated_unverified","output":{"requestID":"fixture","title":"Recipe","bullets":[{"text":"Texted Avery about recipe.","actionIDs":["short"],"assertion":"submitted"}],"generator":"local/qwen3.5-4b-q4_k_m","generatorVersion":"qwen35-4b-q4-b9723-prompt13-validator18"}}
    """
    let adapted=DaydreamNotes.bullets(try JSONDecoder().decode(GeneratedNote.self,from:Data(noteJSON.utf8)))
    check(adapted.first?.actionIDs==["short"],"real note-to-UI adapter retains persisted source ownership")
    let same = MomentBullet(text:"Texted Avery about the recipe.", actionIDs:["short"])
    let unrelated = MomentBullet(text:"Drafted a long report.", actionIDs:["other"])
    let correction = MomentBullet(text:"My correction.", correction:true)
    let primary = OwnerSourceSummaryProjection.previews(found, bullets:[same,unrelated,correction])
    check(primary==found && primary.first?.parts.first?.text==text,"primary Summary preserves complete exact short source instead of lossy topic")
    check(OwnerSourceSummaryProjection.remaining([same,unrelated,correction],previews:primary)==[unrelated,correction],"only fully source-covered model account removed; unrelated abstract and correction retained")
    check(OwnerSourceSummaryProjection.previews(found,bullets:[MomentBullet(text:"Legacy summary.")]).isEmpty,"unknown legacy bullet ownership leaves existing model summary intact")
    check(OwnerSourceSummaryProjection.previews(found,bullets:[MomentBullet(text:"Merged report.",actionIDs:["short","other"])]).isEmpty,"partial or mixed ownership cannot replace a multi-action summary")
    check(OwnerSourceSummaryProjection.previews(found,bullets:[]).first?.parts.first?.text==text,"short source can be useful primary Summary while local abstract pending")
    check(OwnerSourceSummaryProjection.remaining([same],previews:[]).first==same,"expiry or denied source restores existing local summary")
    let exactCases = [
      "Hey Avery, I didn't get into ASC this round. I might apply again, but I'm not sure. Do they recruit in spring?",
      "The Astronomy Society Club (ASC) application is the one we discussed. Hey Avery, I didn't get into ASC this round. I might apply again, but I'm not sure. Do they recruit in spring?",
      "The workshop ran out of places. I might try next month, although I am unsure. Can you ask whether they offer evening sessions?",
      "Could you look over the planting sketch?",
      "The courier lost my parcel; can you check the delivery desk?",
      "The rear light stopped working. I might replace the battery, although I am unsure. Is the repair stall open on Sunday?",
      "The outline still lacks examples; could you suggest a concrete opening and mark the repetitive sections?",
      "I noticed that the meeting notice is missing the room number. Could you confirm its start time and add arrival directions?",
      "The equipment checklist still lacks a calibration step; please check the cable label and flag the loose bracket.",
      "The recipe lacks an oven temperature; could you add it and check the pan size?",
      "The route guide is missing a trail marker. Could you locate the junction and update the map?"
    ]
    for (n,words) in exactCases.enumerated() {
      let (sample,_) = try fixture("exact-\(n)")
      let id="exact-\(n)"
      _=try sample.ingest(row(id,words,run:id,send:n%2==0),now:epoch)
      let source=try sample.ownerSourcePreviewsForActions([id],now:epoch)
      let projected=OwnerSourceSummaryProjection.previews(source,bullets:[MomentBullet(text:"Lossy topic.",actionIDs:[id])])
      check(projected.first?.parts.first?.text==words && projected.first?.actionIDs==[id] &&
            projected.first?.state==(n%2==0 ? "submitted":"draft") &&
            projected.first?.lead.contains("to Avery")==true,
            "deterministic exact Summary case \(n) retains every source clause, observed recipient and draft/gesture state")
    }
    let (unnamed,_) = try fixture("unnamed")
    _=try unnamed.ingest(row("unnamed","Please ask Morgan about the route.",run:"unnamed",to:""),now:epoch)
    let noRecipient=try unnamed.ownerSourcePreviewsForActions(["unnamed"],now:epoch)
    check(noRecipient.first?.lead=="Submitted text in Messages" &&
          noRecipient.first?.parts.first?.text=="Please ask Morgan about the route.",
          "typed body name remains source, never inferred action recipient")
    let (unsafeName,_) = try fixture("unsafe-name")
    _=try unsafeName.ingest(row("unsafe-name","Please review the route.",run:"unsafe-name",to:"password: secret"),now:epoch)
    let hiddenRecipient=try unsafeName.ownerSourcePreviewsForActions(["unsafe-name"],now:epoch)
    check(hiddenRecipient.allSatisfy { !$0.lead.contains("password:") },
          "sensitive recipient value never enters action lead")
    check(try store.ownerSourcePreviewsForActions(["short","missing"],now:epoch).isEmpty,"missing selected member cannot silently become partial quote")
    state.clear()
    check(state.previews.isEmpty && !state.active && !state.accept(found,ticket:ticket,revision:access,now:epoch),"close clears source and rejects late hydration")
    ticket=state.begin(scope:"day|moment",actionIDs:selected)
    _=state.accept(found,ticket:ticket,revision:access,now:epoch)
    let old=ticket;ticket=state.begin(scope:"other-day|other-moment",actionIDs:["other"])
    check(state.previews.isEmpty && !state.accept(found,ticket:old,revision:access,now:epoch),"selection and day replacement clear old quote and fence late result")
    check(!state.accept(found,ticket:ticket,revision:access,now:epoch) && state.previews.isEmpty,"foreign source ID never enters current detail")
    for label in ["window close","app resign","day cache clear","Forget notification","policy notification"] {
        ticket=state.begin(scope:"day|moment",actionIDs:selected)
        _=state.accept(found,ticket:ticket,revision:access,now:epoch)
        state.clear()
        check(state.previews.isEmpty && !state.accept(found,ticket:ticket,revision:access,now:epoch),label+" uses same clear fence")
    }
    ticket=state.begin(scope:"day|moment",actionIDs:selected)
    _=state.accept(found,ticket:ticket,revision:access,now:epoch)
    check(!state.revalidate(access,now:epoch.addingTimeInterval(7*86400)) && state.previews.isEmpty,"deadline clears quote without waiting for expiry job")
    ticket=state.begin(scope:"day|moment",actionIDs:selected)
    check(!state.accept(found,ticket:ticket,revision:access,now:epoch.addingTimeInterval(7*86400)),"expired hydration never enters detail")
    ticket=state.begin(scope:"day|moment",actionIDs:selected)
    _=state.accept(found,ticket:ticket,revision:access,now:epoch)
    check(!state.revalidate("different",now:epoch) && state.previews.isEmpty,"disclosure change discards prior exact text")
    ticket=state.begin(scope:"day|moment",actionIDs:selected)
    _=state.accept(found,ticket:ticket,revision:access,now:epoch)
    check(!state.revalidate(nil,now:epoch) && state.previews.isEmpty,"failed access read clears instead of keeping last quote")
    _=try store.ingest(row("legacy","Ordinary legacy words.",send:false),now:epoch)
    let legacy=try store.ownerSourcePreviewsForActions(["legacy"],now:epoch)
    check(legacy.count==1 && legacy.first?.runID==nil,"unknown identity fixture really opens through owner producer")
    let legacyAccess=try store.ownerSourcePreviewRevision(now:epoch)
    ticket=state.begin(scope:"day|legacy",actionIDs:["legacy"])
    let legacyAccepted=state.accept(legacy,ticket:ticket,revision:legacyAccess,now:epoch)
    check(legacyAccepted && state.active && state.previews.isEmpty,"unknown source stays on existing summary route with valid fresh owner access")
    _=try store.ingest(row("long",String(repeating:"Review the plan. ",count:40),run:"long"),now:epoch)
    check(try store.ownerSourcePreviewsForActions(["long"],now:epoch).isEmpty,"long source leaves summary unchanged")
    var p=try store.policy();p.captureText=false;try store.updatePolicy(p,now:epoch)
    ticket=state.begin(scope:"day|moment",actionIDs:selected)
    _=state.accept(found,ticket:ticket,revision:access,now:epoch)
    let off=try store.ownerSourcePreviewRevision(now:epoch)
    check(off==nil && !state.revalidate(off,now:epoch) && state.previews.isEmpty,"actual typing-off access clears current plaintext")
    p.captureText=true;try store.updatePolicy(p,now:epoch)
    let refreshed=try store.ownerSourcePreviewsForActions(selected,now:epoch)
    let newAccess=try store.ownerSourcePreviewRevision(now:epoch)
    ticket=state.begin(scope:"day|moment",actionIDs:selected)
    check(state.accept(refreshed,ticket:ticket,revision:newAccess,now:epoch) && !state.previews.isEmpty,"fresh scoped read required after typing returns")
    keys.locked=true;_=try store.attachVault(TypedTextVault(keyStore:keys),now:epoch)
    let locked=try store.ownerSourcePreviewRevision(now:epoch)
    check(locked==nil && !state.revalidate(locked,now:epoch) && state.previews.isEmpty,"actual current locked-vault state clears quote")
    let (expired,_)=try fixture("expiry")
    _=try expired.ingest(row("expiry",text,run:"expiry"),now:epoch)
    let before=try expired.ownerSourcePreviewsForActions(["expiry"],now:epoch)
    let deadline=before.first?.expiresAt
    check(try expired.ownerSourcePreviewRevision(expiresAt:deadline,now:epoch.addingTimeInterval(7*86400+1))==nil,"metadata watch checks authoritative monotonic expiry")
    check(try expired.ownerSourcePreviewRevision(expiresAt:deadline,now:epoch)==nil,"clock rollback cannot resurrect access lease")
    let (deleted,_)=try fixture("deleted")
    _=try deleted.ingest(row("delete",text,run:"delete"),now:epoch)
    let prior=try deleted.ownerSourcePreviewsForActions(["delete"],now:epoch)
    let priorRevision=try deleted.ownerSourcePreviewRevision(now:epoch)
    ticket=state.begin(scope:"day|delete",actionIDs:["delete"]);_=state.accept(prior,ticket:ticket,revision:priorRevision,now:epoch)
    try deleted.delete("delete")
    let deleteRevision=try deleted.ownerSourcePreviewRevision(now:epoch)
    check(!state.revalidate(deleteRevision,now:epoch) && state.previews.isEmpty,"actual deletion revision clears previously open quote")
    check(try deleted.ownerSourcePreviewsForActions(["delete"],now:epoch).isEmpty,"deleted selected source cannot rehydrate")
    let (forgot,_)=try fixture("forgot")
    _=try forgot.ingest(row("forget",text,run:"forget"),now:epoch)
    let keep=try forgot.ownerSourcePreviewsForActions(["forget"],now:epoch)
    let keepRevision=try forgot.ownerSourcePreviewRevision(now:epoch)
    ticket=state.begin(scope:"day|forget",actionIDs:["forget"]);_=state.accept(keep,ticket:ticket,revision:keepRevision,now:epoch)
    _=try forgot.forgetTypedText(confirmed:true,now:epoch)
    let forgetRevision=try forgot.ownerSourcePreviewRevision(now:epoch)
    check(!state.revalidate(forgetRevision,now:epoch) && state.previews.isEmpty,"actual Forget clears open quote through disclosure revision")
    let (asyncStore,_)=try fixture("async")
    _=try asyncStore.ingest(row("async-a",text,run:"async-a"),now:epoch)
    _=try asyncStore.ingest(row("async-b","Please review the planting sketch.",run:"async-b",send:false),now:epoch)
    let asyncA=try asyncStore.ownerSourcePreviewsForActions(["async-a"],now:epoch)
    let asyncB=try asyncStore.ownerSourcePreviewsForActions(["async-b"],now:epoch)
    let asyncRevision=try asyncStore.ownerSourcePreviewRevision(now:epoch)
    let session=OwnerSourceDetailSession()
    session.open(scope:"day|A",actionIDs:["async-a"],load:{_ in
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline:.now()+0.1) { continuation.resume(returning:asyncA) }
        }
    },revision:{_ in asyncRevision},now:{epoch})
    session.open(scope:"day|B",actionIDs:["async-b"],load:{_ in asyncB},revision:{_ in asyncRevision},now:{epoch})
    try await Task.sleep(nanoseconds:200_000_000)
    check(session.state.previews.first?.actionIDs==["async-b"],"actual async session rejects late previous-selection hydration")
    session.close()
    check(session.state.previews.isEmpty && !session.state.active,"actual session close clears plaintext")
    session.open(scope:"day|A",actionIDs:["async-a"],load:{_ in
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline:.now()+0.1) { continuation.resume(returning:asyncA) }
        }
    },revision:{_ in asyncRevision},now:{epoch})
    session.close()
    try await Task.sleep(nanoseconds:200_000_000)
    check(session.state.previews.isEmpty,"actual session cannot restore quote after close during owner read")
    var revisionCalls=0
    let deadlineNow=asyncA[0].expiresAt!.addingTimeInterval(-0.6)
    session.open(scope:"day|deadline",actionIDs:["async-a"],load:{_ in asyncA},revision:{_ in
        revisionCalls += 1
        if revisionCalls > 1 {
            await withCheckedContinuation { (continuation:CheckedContinuation<Void,Never>) in
                DispatchQueue.global().asyncAfter(deadline:.now()+1) { continuation.resume() }
            }
        }
        return asyncRevision
    },now:{deadlineNow})
    try await Task.sleep(nanoseconds:750_000_000)
    check(revisionCalls==2 && session.state.previews.isEmpty && !session.state.active,"independent deadline clears while metadata revalidation is stalled")
    try await Task.sleep(nanoseconds:1_000_000_000)
    check(session.state.previews.isEmpty,"late stalled metadata response cannot restore expired quote")
    var pollRevision=asyncRevision
    session.open(scope:"day|revision",actionIDs:["async-a"],load:{_ in asyncA},revision:{_ in pollRevision},now:{epoch})
    try await Task.sleep(nanoseconds:100_000_000)
    check(!session.state.previews.isEmpty,"actual active detail really receives quote before revocation")
    pollRevision=nil
    try await Task.sleep(nanoseconds:650_000_000)
    check(session.state.previews.isEmpty,"actual bounded access poll clears unannounced revocation")
    session.close()
    print("TOTAL \(passed) PASS \(failed) FAIL")
    if failed>0{exit(1)}
 }
}
