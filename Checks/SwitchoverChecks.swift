import Foundation
import MemoryCore

private final class FakeLauncher: LauncherControl {
    var state = LauncherState(loaded:true,disabled:false)
    var failStop = false, failRestore = false, lieRestore = false
    var changes = 0
    func inspect(_ launcher:LegacyLauncher) throws -> LauncherState { state }
    func stopAndDisable(_ launcher:LegacyLauncher) throws {
        changes += 1; state = LauncherState(loaded:false,disabled:true)
        if failStop { throw MemError.invalid("synthetic stop failure") }
    }
    func restore(_ launcher:LegacyLauncher,previous:LauncherState) throws {
        changes += 1
        if failRestore { throw MemError.invalid("synthetic restore failure") }
        if !lieRestore { state = previous }
    }
}
private final class SyntheticConsumer:ReplacementConsumerProbe {
    let identity="synthetic-before-turn", client="fixture", recipient="fixture-chat"
    let capability:String, store:MemoryStore
    var corrupt=false, calls=0
    init(_ store:MemoryStore) throws {
        self.store=store
        capability=try store.grant(client:client,recipient:recipient,scopes:["detail","context"])
    }
    func read(resource:String,nonce:String,deadline:Date) throws -> ConsumerReadback {
        calls += 1
        let body=try resource == "macmem://current-context" ? json(store.currentActions()) : store.openActionResource(resource)
        return ConsumerReadback(nonce:corrupt ? "wrong" : nonce,resource:resource,body:body)
    }
}
func runSwitchoverChecks(home:URL) throws {
    let store = try MemoryStore(home:home.appendingPathComponent("new"),writable:true)
    _ = try attachTestVault(store)
    var consent=try store.policy(); consent.captureText=true; try store.updatePolicy(consent)
    let old = home.appendingPathComponent("legacy")
    try FileManager.default.createDirectory(at:old,withIntermediateDirectories:true)
    let sentinel = old.appendingPathComponent("history-fixture.txt")
    try "synthetic old history must remain".write(to:sentinel,atomically:true,encoding:.utf8)
    let plist = home.appendingPathComponent("synthetic.plist")
    let manifest:[String:Any] = ["Label":"test.macmem.synthetic","ProgramArguments":["/synthetic/collector"]]
    try PropertyListSerialization.data(fromPropertyList:manifest,format:.xml,options:0).write(to:plist)
    let launcher = LegacyLauncher(label:"test.macmem.synthetic",plist:plist.path,executable:"/synthetic/collector",historyHome:old.path)
    let fake = FakeLauncher(), machine = Switchover(store:store,control:FakeLauncher())
    func denied(_ body:() throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
    try check(denied { try machine.prepare(launcher,approved:false,compatibilityReady:true) },"switch requires explicit approval")
    try check(denied { try machine.prepare(launcher,approved:true,compatibilityReady:false) },"switch requires consumer readiness")
    try check(denied { try machine.prepare(launcher,approved:true,compatibilityReady:true) },"checkbox alone cannot stop legacy without executable consumers")
    _=try store.ingest(Evidence(id:"probe-source",at:iso(Date()),kind:"window.changed",app:"Fixture",title:"Consumer fixture",synthetic:true))
    let probe=try SyntheticConsumer(store)
    let failingFlow = Switchover(store:store,control:fake,probes:[probe],requiredConsumers:[probe.identity])
    probe.corrupt=true
    try check(denied { try failingFlow.prepare(launcher,approved:true,compatibilityReady:true) } && fake.changes == 0,"consumer mismatch prevents any launcher change")
    probe.corrupt=false
    try check(denied { _=try store.verifyReplacementConsumers([probe],required:["other-route"]) },"missing configured consumer route rejected")
    try store.revoke(client:probe.client,recipient:probe.recipient)
    try check(denied { _=try store.verifyReplacementConsumers([probe],required:[probe.identity]) },"consumer grant revocation blocks read-back")
    let activeProbe=try SyntheticConsumer(store)
    let verifiedFlow=Switchover(store:store,control:fake,probes:[activeProbe],requiredConsumers:[activeProbe.identity])
    // Restore a current explicit synthetic token without touching any live grant.
    let flow=verifiedFlow
    try flow.prepare(launcher,approved:true,compatibilityReady:true)
    try check(try flow.record()?.phase == "awaiting_explicit_start","stop intent durable, capture requires separate start")
    try check(try flow.permitsStart(),"new capture permitted only after verified old stop")
    try check(try store.status()["capture"] == "off","preparing never starts new capture")
    try check(denied { try flow.commit() },"commit rejects absent recorder health")
    let recovered = Switchover(store:try MemoryStore(home:store.home,writable:true),control:fake,probes:[activeProbe],requiredConsumers:[activeProbe.identity])
    try check(try recovered.record()?.phase == "awaiting_explicit_start","restart restores migration intent without actions")
    try check(denied { try recovered.rollback(approved:true,stopNew:{},newIsStopped:{false}) },"rollback cannot double-record")
    try check(fake.state.disabled && !fake.state.loaded,"unsafe rollback leaves legacy stopped")
    try recovered.rollback(approved:true,stopNew:{},newIsStopped:{true})
    try check(fake.state == LauncherState(loaded:true,disabled:false),"rollback restores previous service state")
    let count = fake.changes
    try recovered.rollback(approved:true,stopNew:{},newIsStopped:{true})
    try check(fake.changes == count,"rollback idempotent")
    fake.failStop = true
    try check(denied { try flow.prepare(launcher,approved:true,compatibilityReady:true) },"stop failure surfaced")
    try check(try flow.record()?.phase == "rolled_back","stop failure restores old recorder")
    fake.failRestore = true
    try check(denied { try flow.prepare(launcher,approved:true,compatibilityReady:true) },"rollback failure surfaced")
    try check(try flow.record()?.phase == "rollback_required","failed rollback persists recovery gate")
    try check(try !flow.permitsStart(),"unresolved rollback blocks capture")
    fake.failRestore = false
    try flow.rollback(approved:true,stopNew:{},newIsStopped:{true})
    var wrong = launcher; wrong.executable = "/wrong"
    try check(denied { try flow.prepare(wrong,approved:true,compatibilityReady:true) },"launcher identity must match manifest")
    wrong = launcher; wrong.historyHome = store.home.appendingPathComponent("nested").path
    try check(denied { try flow.prepare(wrong,approved:true,compatibilityReady:true) },"nested history paths rejected")
    fake.lieRestore = true
    try check(denied { try flow.prepare(launcher,approved:true,compatibilityReady:true) },"lying restore still fails")
    try check(try flow.record()?.phase == "rollback_required","rollback requires observed health, not exit success")
    try check(try String(contentsOf:sentinel,encoding:.utf8) == "synthetic old history must remain","legacy history untouched throughout failures")
    fake.lieRestore = false; fake.failStop = false
    try flow.rollback(approved:true,stopNew:{},newIsStopped:{true})
    try flow.prepare(launcher,approved:true,compatibilityReady:true)
    // Mocked permission, never EventCapture.
    let session = try CaptureSession(store:store)
    try session.start(permitted:true)
    let observed = Date()
    _ = try session.record(Evidence(id:"healthy-switch",at:iso(observed),kind:"window.changed",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Synthetic replacement check",synthetic:true),focusedFieldKnown:true,permitted:true,now:observed)
    try flow.commit()
    try check(try flow.record()?.consumerReceipts?.count == 1 && activeProbe.calls >= 4,"prepare and commit execute scoped canonical and context reads")
    try check(try flow.record()?.phase == "committed","commit requires a new durable observation and recording health")
    try flow.rollback(approved:true,stopNew:{ try session.pause("synthetic rollback") },newIsStopped:{ session.state != "recording" })
    try check(try flow.record()?.phase == "rolled_back","committed replacement can be reversed")
    try store.delete("healthy-switch")
    try store.delete("probe-source")

    let now = Date()
    for i in 0..<205 {
        _ = try store.ingest(Evidence(id:"page-\(String(format:"%03d",i))",at:iso(now),kind:"keyboard.text_input",app:"TextEdit",bundle:"com.apple.TextEdit",text:"synthetic text",synthetic:true),now:now)
    }
    let first = try store.legacyPage(now:now)
    let second = try store.legacyPage(after:first.next,includeText:true,now:now)
    try check(first.events.count == 200 && second.events.count == 5,"reader cursor covers more than one bounded page")
    try check(first.events.allSatisfy { $0.key.isEmpty },"metadata reader omits text")
    // The reader process has no key: detail keeps source IDs but never the sealed words.
    try check(second.events.allSatisfy { ($0.key["text"] ?? "") == "" && $0.source_id == $0.id },"detail reader preserves original source IDs")
    try check(try store.hydrateTypedText(second.events[0].id,disclosure:.owner,now:now) == "synthetic text","the owner still opens the sealed words")
    try store.delete("page-000")
    try check(try store.legacyPage(now:now).revision != first.revision,"deletion invalidates reader snapshot")
}
