import Foundation
import PrivacyPolicy
@testable import MemoryCore

@main struct Repro {
 static func main() throws {
  let home=URL(fileURLWithPath:CommandLine.arguments[1]),output=URL(fileURLWithPath:CommandLine.arguments[2])
  var cases=[[String:Any]]()
  func run(_ name:String,maintenance:String,seal:String="idle",gap:TimeInterval=61,wrongRun:Bool=false,strong:Bool=false,physical:Bool=false)throws {
   let start=timestamp(iso(Date()))!;var later=start.addingTimeInterval(gap)
   let store=try MemoryStore(home:home.appendingPathComponent(name),writable:true,automaticallySyncSearch:false)
   var settings=try store.policy();settings.captureText=true;settings.typedConsentVersion=1;try store.updatePolicy(settings,now:start)
   try store.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()),now:start);try store.setUpTypedVault(now:start);_ = try store.acceptSafeTyping(now:start)
   _ = try store.settleLegacyTypedText(now:start)
   let policy=try store.policy()
   try store.setCaptureState("recording",reason:"Fictional fixture",now:start)
   func evidence(_ text:String,part:Int,time:Date,reason:String,run:String="fictional-run") -> Evidence {
    var e=Evidence(id:"part-\(part)",at:iso(time),kind:"keyboard.text_input",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Fictional controlled scratch",text:text,synthetic:true)
    e.captureProvenance=NativeCaptureProvenance(policyRevision:policy.revision,classifierVersion:UnitClassifier.version,windowID:"fictional-window",focusID:"fictional-field",checkedAt:iso(time),generation:1,unit:TypedUnitProvenance(runID:run,part:part,sealReason:reason,startedAt:iso(start),keys:20,edits:0,withheld:0,surface:"writing",field:"textArea",send:"unknown",pasted:false))
    return e
   }
   // Install only task-owned synthetic triggers before the certified prefix exists.
   if maintenance == "unknown-cleanup-trigger" {try store.exec("CREATE TRIGGER fictional_cleanup_read AFTER DELETE ON typed_recipients BEGIN SELECT 1; END")}
   if maintenance == "unknown-trigger" {try store.exec("CREATE TRIGGER fictional_summary_mutation AFTER INSERT ON summaries BEGIN UPDATE records SET revision=revision WHERE id=new.id; END")}
   if maintenance == "known-name-protected-trigger" {try store.exec("CREATE TEMP TRIGGER summary_queue_summary_update AFTER INSERT ON main.summaries BEGIN UPDATE records SET revision=revision WHERE id=new.id; END")}
   if maintenance == "readonly-unknown-trigger" {try store.exec("CREATE TRIGGER fictional_summary_read AFTER INSERT ON summaries BEGIN SELECT 1; END")}
   if maintenance == "failed-worker-trigger" {try store.exec("CREATE TRIGGER fictional_summary_fail AFTER INSERT ON summaries BEGIN SELECT RAISE(ABORT,'fictional controlled failure'); END")}
   if maintenance == "orphan-expiry" || maintenance == "actual-expiry" {
    var old=evidence("Fictional ordinary writing",part:1,time:start,reason:"submit",run:"old-fictional-run");old.id="old-fictional"
    let oldSaved=try store.ingest(old,now:start);precondition(oldSaved)
    if maintenance == "actual-expiry" {try store.exec("UPDATE typed_text SET created_at=? WHERE id='old-fictional'",[iso(start.addingTimeInterval(-8*86400))])}
    if maintenance == "orphan-expiry" {try store.exec("DELETE FROM records WHERE id='old-fictional'")}
   }
   let first=evidence("i didn't like the ",part:1,time:start,reason:seal)
   let savedFirst=try store.ingest(first,now:start,expectedPolicyRevision:policy.revision,requireRecording:true);precondition(savedFirst,"prefix must persist")
   let before=try store.hydrateTypedText(first.id,disclosure:.owner,now:start)
   let allowedBefore=try store.typedNarrativeMaintenanceAllowed(now:start)
   var workerCompleted=false,workerCount:Int?=nil,workerFailed=false,modernRequest=false,expired=0,orphans=0
   switch maintenance {
   case "worker","unknown-trigger","known-name-protected-trigger","readonly-unknown-trigger","failed-worker-trigger","unknown-cleanup-trigger":
    // Exact production callback effect: same-store SummaryWorker.schedule.
    // No AppKit, inference, host callbacks, or private input is involved.
    let worker=SummaryWorker(store:store),done=DispatchSemaphore(value:0)
    var result:Result<Int,Error>?
    worker.schedule {value in result=value;done.signal()}
    precondition(done.wait(timeout:.now()+20) == .success,"bounded worker must complete")
    if maintenance == "failed-worker-trigger" {if case .failure = result! {workerFailed=true}else{preconditionFailure("failing trigger must fail worker")}}
    else {workerCount=try result!.get()};workerCompleted=true
   case "orphan-expiry","actual-expiry":
    let report=try store.expireTypedTextForSummaryMaintenance(now:start);expired=report.expired;orphans=report.orphans
    precondition(maintenance == "orphan-expiry" ? orphans == 1 : expired == 1,"actual expiry effect required")
   case "modern-request":
    let day=try DayScope.key(start,timezone:"UTC"),layer=try store.dayLayers(day:day,timezone:"UTC",now:start)
    guard let activity=layer.activities.first else {preconditionFailure("real target required")}
    _ = try store.prepareNote(kind:"activity",day:day,timezone:"UTC",activityID:activity.id,now:start);modernRequest=true
    let pending=try store.rows("SELECT id FROM note_requests WHERE state='pending'");precondition(!pending.isEmpty)
   case "stop-restart": try store.setCaptureState("paused",reason:"Fictional pause",now:start);try store.setCaptureState("recording",reason:"Fictional restart",now:start)
   case "forget": _ = try store.forgetTypedText(confirmed:true,now:start);try store.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()),now:start);try store.setUpTypedVault(now:start);_ = try store.acceptSafeTyping(now:start)
   case "typing-toggle": _ = try store.snoozeTyping(minutes:1,now:start);try store.resumeTyping(now:start)
   case "expiry": _ = try store.expireTypedText(now:start)
   case "queue-only": _ = try store.writePending(now:start);_ = try store.writePending(now:start)
   case "unknown-write": try store.transaction {try store.exec("INSERT OR REPLACE INTO metadata VALUES('fictional-unrelated','1')")}
   case "failed-write": do {try store.transaction {try store.exec("INVALID FICTIONAL SQL")}} catch {}
   case "policy-toggle": settings.captureText=false;try store.updatePolicy(settings,now:start);settings.captureText=true;try store.updatePolicy(settings,now:start)
   case "external-write": let other=try MemoryStore(home:store.home,writable:true,automaticallySyncSearch:false);try other.transaction {try other.exec("INSERT OR REPLACE INTO metadata VALUES('fictional-external','1')")}
   default: break
   }
   let allowedAfter=try store.typedNarrativeMaintenanceAllowed(now:start)
   let waitStarted=Date()
   for second in 1...Int(gap) {
    if physical {Thread.sleep(forTimeInterval:1)}
    try store.setCaptureState("recording",reason:"Fictional healthy heartbeat",now:physical ? Date():start.addingTimeInterval(Double(second)))
   }
   let actualWait=Date().timeIntervalSince(waitStarted)
   if physical {later=Date();precondition(actualWait >= gap && actualWait < gap+10,"bounded physical elapsed control")}

   let text=strong ? "password: FictionalToken99!" : "sig :("
   let second=evidence(text,part:2,time:later,reason:"submit",run:wrongRun ? "other-fictional-run":"fictional-run")
   let fresh=abs(later.timeIntervalSince(timestamp(second.at)!))<=1 && abs(timestamp(second.captureProvenance!.checkedAt)!.timeIntervalSince(timestamp(second.at)!))<=1
   let wrote=try store.ingest(second,now:later,expectedPolicyRevision:(try store.policy()).revision,requireRecording:true),kept=wrote ? try store.hydrateTypedText(second.id,disclosure:.owner,now:later):nil
   let protected=strong ? kept?.contains("FictionalToken99!") != true : kept != text
   cases.append(["case":name,"maintenance":maintenance,"allowedBefore":allowedBefore,"allowedAfter":allowedAfter,"logicalElapsedSeconds":gap,"metadataFresh":fresh,"firstExact":before==first.text,"secondWritten":wrote,"secondExact":kept==text,"secondHasMarker":kept?.contains("[withheld]")==true,"secretOrBoundaryProtected":protected,"physicalElapsed":physical,"actualWaitSeconds":actualWait,"workerFailed":workerFailed,"modernPendingRequest":modernRequest,"expiredRows":expired,"orphanRows":orphans,"workerCompleted":workerCompleted,"workerCount":workerCount.map { $0 as Any } ?? NSNull()])
  }
  try run("idle-no-maintenance-positive",maintenance:"none")
  try run("size-no-maintenance-positive",maintenance:"none",seal:"size",gap:1)
  try run("idle-normal-onCommitted-worker",maintenance:"worker")
  try run("size-normal-onCommitted-worker",maintenance:"worker",seal:"size",gap:1)
  try run("idle-zero-expiry-pass",maintenance:"expiry")
  try run("idle-queue-noop-pass",maintenance:"queue-only")
  for m in ["unknown-write","failed-write","policy-toggle","external-write","unknown-trigger","known-name-protected-trigger","readonly-unknown-trigger","failed-worker-trigger","unknown-cleanup-trigger","orphan-expiry","actual-expiry","modern-request","stop-restart","forget","typing-toggle"] {try run("boundary-"+m,maintenance:m)}
  try run("different-run-negative",maintenance:"none",wrongRun:true)
  try run("ttl-expired-fresh-current-negative",maintenance:"none",gap:121)
  try run("strong-secret-worker-negative",maintenance:"worker",strong:true)
  try JSONSerialization.data(withJSONObject:cases,options:[.prettyPrinted,.sortedKeys]).write(to:output)
  try run("physical-idle-normal-onCommitted-worker",maintenance:"worker",physical:true)
  try run("physical-size-normal-onCommitted-worker",maintenance:"worker",seal:"size",gap:1,physical:true)
  precondition(cases.first{$0["case"] as? String == "idle-queue-noop-pass"}!["secondExact"] as! Bool,"known queue-only maintenance preserves")
  precondition(cases.first{$0["case"] as? String == "idle-zero-expiry-pass"}!["secondHasMarker"] as! Bool,"public expiry remains strict")
  precondition(cases.allSatisfy{$0["metadataFresh"] as! Bool && $0["firstExact"] as! Bool},"fixtures must be fresh and positive prefix persisted")
  precondition(cases.filter{($0["case"] as! String).hasSuffix("no-maintenance-positive")}.allSatisfy{$0["secondExact"] as! Bool},"positive baseline must retain")
  let normal=cases.filter{($0["case"] as! String).contains("normal-onCommitted-worker")}
  precondition(normal.count==4 && normal.allSatisfy{($0["workerCompleted"] as! Bool) && ($0["secondExact"] as! Bool) && !($0["secondHasMarker"] as! Bool)},"normal pipeline still loses certified parts")
  precondition(cases.filter{($0["case"] as! String).hasPrefix("boundary-") || ($0["case"] as! String).hasSuffix("negative")}.allSatisfy{$0["secretOrBoundaryProtected"] as! Bool},"privacy negative changed")
  let result:[String:Any]=["schema":"sig-normal-maintenance-repro-v1","baseline":"0f2c89d5e61fdf25aca286d19cbd7c4a5458145c","scope":"legacy worker-only; actual modern note request remains boundary; automatic external indexer remains excluded","positiveNormalPipelineRequirementPassed":true,"expectedFailureReproduced":false,"cases":cases,"clock":"logical-offset controls and separately marked actual physical61s/1s waits; fresh per-part timestamps, recording admission and healthy heartbeats","GUI":false,"inference":false,"userHistoryAccess":false]
  try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output)
  print("CERTIFIED LEGACY MAINTENANCE POSITIVE PASS; scoped controls verified")
 }
}
