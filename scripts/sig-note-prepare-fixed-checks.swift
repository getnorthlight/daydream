import Foundation
import CSQLite
import PrivacyPolicy
import WriterBackend
import CoreIntegration
@testable import MemoryCore

func require(_ value: @autoclosure () throws -> Bool, _ message:String="") rethrows { let good=try value();precondition(good,message) }

@main struct ModernCarryRepro {
 static func main() async throws {
  try require(CommandLine.arguments.count == 3)
  let home=URL(fileURLWithPath:CommandLine.arguments[1]),out=URL(fileURLWithPath:CommandLine.arguments[2])
  var cases=[[String:Any]]()
  for mode in ["discovery-only","prepare","adapter-notSent","prepare-reused","adapter-reused","unknown-write","external-write","strong-secret","read-trigger","protected-trigger","failed-trigger","invalid-prepare","cancel","page","expiry","stop-restart","typing-toggle","policy-toggle","wrong-part","wrong-run","unknown-phase-write","failed-phase","default-derived-write","discovery-checkpoint","raced-phase-retry"] {
   let setup=Date(),store=try MemoryStore(home:home.appendingPathComponent(mode),writable:true,automaticallySyncSearch:false)
   var policy=try store.policy();policy.captureText=true;policy.typedConsentVersion=1;try store.updatePolicy(policy,now:setup)
   try store.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()),now:setup);try store.setUpTypedVault(now:setup);_ = try store.acceptSafeTyping(now:setup);_ = try store.settleLegacyTypedText(now:setup)
   policy=try store.policy();try store.setCaptureState("recording",reason:"Fictional controlled fixture",now:setup)
   func evidence(_ text:String,id:String,part:Int,time:Date,old:Bool=false,reason:String="idle") -> Evidence {
    var e=Evidence(id:id,at:iso(time),kind:"keyboard.text_input",app:"TextEdit",bundle:"com.apple.TextEdit",title:old ? "Fictional astronomy scratch":"Fictional current scratch",text:text,synthetic:true)
    e.captureProvenance=NativeCaptureProvenance(policyRevision:policy.revision,classifierVersion:UnitClassifier.version,windowID:old ? "old-window":"current-window",focusID:old ? "old-field":"current-field",checkedAt:iso(time),generation:1,unit:TypedUnitProvenance(runID:old ? "old-run":"current-run",part:part,sealReason:reason,startedAt:iso(time),keys:20,edits:0,withheld:0,surface:"writing",field:"textArea",send:"unknown",pasted:false))
    return e
   }
   // Historical seed is synthetic; current fragments below use real fresh Date values.
   let oldAt=setup.addingTimeInterval(-900),old=evidence("Planning telescope observations for the Astronomy Society Club",id:"old-row",part:1,time:oldAt,old:true,reason:"submit")
   try require(try store.ingest(old,now:oldAt))
   _ = try store.writePending(now:setup)
   let day=try DayScope.key(setup,timezone:"UTC"),source=WriterQueueSource(store:store)
   let found=try await source.discoverDay(day,now:Date(),timezone:"UTC",marks:[:])
   let layers=try store.dayLayers(day:day,timezone:"UTC",now:Date())
   guard let oldActivity=layers.activities.first(where:{$0.actionIDs.contains(old.id)}),let item=found.targets.first(where:{$0.target.activityID == oldActivity.id}) else {preconditionFailure("actual closed eligible old target required")}
   if mode == "read-trigger" {try store.exec("CREATE TRIGGER fictional_note_read AFTER INSERT ON note_requests BEGIN SELECT 1; END")}
   if mode == "protected-trigger" {try store.exec("CREATE TRIGGER fictional_note_source AFTER INSERT ON note_requests BEGIN UPDATE records SET revision=revision; END")}
   if mode == "failed-trigger" {try store.exec("CREATE TRIGGER fictional_note_failure AFTER INSERT ON note_requests BEGIN SELECT RAISE(ABORT,'fictional failure'); END")}
   let binding=CoreWriterBinding(store:store,typedWriter:.local),port=binding.port()
   var preparedBefore:String?=nil
   if mode.hasSuffix("reused") || ["cancel","page"].contains(mode) {preparedBefore=try await port.prepare(item.target).id}
   let firstAt=Date(),first=evidence("i didn't like the ",id:"current-first",part:1,time:firstAt)
   try require(try store.ingest(first,now:firstAt,expectedPolicyRevision:policy.revision,requireRecording:true))
   try require(try store.hydrateTypedText(first.id,disclosure:.owner,now:Date()) == first.text)
   let currentDiscovery=try await source.discoverDay(day,now:Date(),timezone:"UTC",marks:[:])
   let currentLayers=try store.dayLayers(day:day,timezone:"UTC",now:Date())
   guard let currentActivity=currentLayers.activities.first(where:{$0.actionIDs.contains(first.id)}) else {preconditionFailure("current activity required")}
   try require(currentActivity.id != oldActivity.id && currentDiscovery.open.contains(where:{$0.target.activityID == currentActivity.id}),"current draft must remain open and separate")
   let changesBefore=try store.rows("SELECT total_changes() AS n").first?.first
   var requestID:String?=nil,pendingNotSent=false,generateReached=false
   switch mode {
   case "prepare","prepare-reused","read-trigger","protected-trigger","strong-secret":
    requestID=try store.prepareNote(kind:"activity",day:day,timezone:"UTC",activityID:oldActivity.id).id
   case "adapter-notSent","adapter-reused":
    // This is the provider-off codePass generate refusal, not inference or an external send.
    let adapter=CoreWriterAdapter(core:port,generate:{request,actions in
     let view=try ModelView(request:request,actions:actions,appNames:[:])
     try require(!CanonicalGrounding.codeWrites(view),"real synthetic typed target must need model")
     throw WriterFailure.notSent
    })
    let result=try await adapter.process(item.target,lastActivity:item.lastActivity,now:Date())
    guard case let .pending(p)=result else {preconditionFailure("must remain pending, no generated commit")}
    try require(p.reason == .notSent && p.actionIDs.contains(old.id))
    requestID=p.requestID;pendingNotSent=true;generateReached=true
   case "failed-trigger","invalid-prepare":
    var failed=false
    do {_ = try store.prepareNote(kind:"activity",day:day,timezone:"UTC",activityID:mode == "invalid-prepare" ? "fictional-missing-target":oldActivity.id)} catch {failed=true}
    try require(failed)
   case "cancel":try store.cancelNote(preparedBefore!)
   case "page":_ = try store.noteActions(requestID:preparedBefore!,after:0)
   case "expiry":_ = try store.expireTypedText(now:Date())
   case "stop-restart":try store.setCaptureState("paused",reason:"Fictional stop",now:Date());try store.setCaptureState("recording",reason:"Fictional restart",now:Date())
   case "typing-toggle":_ = try store.snoozeTyping(minutes:1,now:Date());try store.resumeTyping(now:Date())
   case "policy-toggle":var p=try store.policy();p.captureText=false;try store.updatePolicy(p,now:Date());p.captureText=true;try store.updatePolicy(p,now:Date());policy=try store.policy()
   case "unknown-phase-write":try store.pendingNotePreparationTransaction(now:Date()) {try store.exec("INSERT OR REPLACE INTO metadata VALUES('fictional-unknown','1')")}
   case "raced-phase-retry":do {try store.pendingNotePreparationTransaction(now:Date()) {throw MemError.invalid(MemoryStore.preparationRaced)}}catch{};requestID=try store.prepareNote(kind:"activity",day:day,timezone:"UTC",activityID:oldActivity.id).id
   case "failed-phase":var failed=false;do {try store.pendingNotePreparationTransaction(now:Date()) {try store.exec("INVALID FICTIONAL SQL")}}catch{failed=true};try require(failed)
   case "default-derived-write":try store.transaction {_ = try store.rows("SELECT id FROM note_requests")}
   case "discovery-checkpoint":_ = try store.nextWriterDiscoveryWindow(now:Date(),timezone:"UTC")
   case "unknown-write":try store.transaction {try store.exec("INSERT OR REPLACE INTO metadata VALUES('fictional-unrelated','1')")}
   case "external-write":let other=try MemoryStore(home:store.home,writable:true,automaticallySyncSearch:false);try other.transaction {try other.exec("INSERT OR REPLACE INTO metadata VALUES('fictional-external','1')")}
   default:break
   }
   let changesAfter=try store.rows("SELECT total_changes() AS n").first?.first
   let pendingCount=try store.rows("SELECT id FROM note_requests WHERE state='pending'").count
   let reused=preparedBefore != nil && requestID == preparedBefore
   if mode.hasSuffix("reused") {try require(reused && changesBefore == changesAfter,"exact pending reuse must perform zero SQL changes")}
   try await Task.sleep(nanoseconds:1_000_000_000)
   try store.setCaptureState("recording",reason:"Fictional healthy heartbeat",now:Date())
   let secondAt=Date(),text=mode == "strong-secret" ? "password: FictionalToken99!":"sig :(",secondInitial=evidence(text,id:"current-second",part:mode == "wrong-part" ? 3:2,time:secondAt,reason:"submit")
   var second=secondInitial
   if mode == "wrong-run" {second.captureProvenance!.unit!.runID="fictional-other-run"}
   try require(try store.ingest(second,now:secondAt,expectedPolicyRevision:policy.revision,requireRecording:true))
   let kept=try store.hydrateTypedText(second.id,disclosure:.owner,now:Date())
   let fresh=abs(secondAt.timeIntervalSince(timestamp(second.at)!)) <= 1 && abs(timestamp(second.captureProvenance!.checkedAt)!.timeIntervalSince(timestamp(second.at)!)) <= 1
   try require(fresh && secondAt.timeIntervalSince(firstAt) < 120)
   let exact=kept == text,withheld=kept?.contains("[withheld]") == true
   FileHandle.standardOutput.write(Data("CASE \(mode) exact=\(exact) withheld=\(withheld) pending=\(pendingCount) reuse=\(reused)\n".utf8))
   let generatedCount=try store.rows("SELECT id FROM generated_notes").count; try require(generatedCount == 0)
   if ["discovery-only","prepare","adapter-notSent","prepare-reused","adapter-reused"].contains(mode) {try require(exact && !withheld,"read-only modern discovery must preserve")}
   else if mode == "strong-secret" {try require(!exact && kept?.contains("FictionalToken99!") != true,"strong secret must stay protected")}
   else {try require(!exact && withheld,"actual modern or privacy boundary must reproduce withheld suffix")}
   if requestID != nil {try require(pendingCount == 1)}
   cases.append(["case":mode,"oldTargetEligibleClosed":true,"currentTargetOpenDistinct":true,"firstExact":true,"secondExact":exact,"secondHasWithheld":withheld,"strongSecretProtected":mode == "strong-secret" && kept?.contains("FictionalToken99!") != true,"freshCurrentEvidence":fresh,"realBetweenPartSeconds":secondAt.timeIntervalSince(firstAt),"pendingCount":pendingCount,"pendingNotSent":pendingNotSent,"generateReachedNoModel":generateReached,"samePendingRequestReused":reused,"zeroSQLChangesDuringReuse":mode.hasSuffix("reused") && changesBefore == changesAfter,"generatedNotesCommitted":generatedCount > 0])
  }
  var classifierCount=0
  func classify(_ action:Int32,_ first:String?,_ second:String?,_ database:String?,_ source:String?,_ statement:String?,expected:Bool) throws {
   try require(TypedNarrativeNotePreparation.permits(action:action,first:first,second:second,database:database,source:source,statement:statement) == expected);classifierCount += 1
  }
  try classify(SQLITE_INSERT,"note_requests",nil,"main",nil,TypedNarrativeNotePreparation.insert,expected:true)
  for column in ["state","body"] {try classify(SQLITE_UPDATE,"note_requests",column,"main",nil,TypedNarrativeNotePreparation.supersede,expected:true)}
  for action in [SQLITE_READ,SQLITE_SELECT,SQLITE_FUNCTION,SQLITE_RECURSIVE] {try classify(action,nil,nil,nil,nil,nil,expected:true)}
  try classify(SQLITE_PRAGMA,"data_version",nil,nil,nil,nil,expected:true)
  for table in ["records","typed_text","metadata","generated_notes","summaries","search_index_state"] {try classify(SQLITE_INSERT,table,nil,"main",nil,TypedNarrativeNotePreparation.insert,expected:false)}
  try classify(SQLITE_INSERT,"note_requests",nil,"temp",nil,TypedNarrativeNotePreparation.insert,expected:false)
  try classify(SQLITE_INSERT,"note_requests","body","main",nil,TypedNarrativeNotePreparation.insert,expected:false)
  try classify(SQLITE_UPDATE,"note_requests","id","main",nil,TypedNarrativeNotePreparation.supersede,expected:false)
  try classify(SQLITE_UPDATE,"note_requests","body","main",nil,TypedNarrativeNotePreparation.insert,expected:false)
  try classify(SQLITE_DELETE,"note_requests",nil,"main",nil,TypedNarrativeNotePreparation.supersede,expected:false)
  for source in ["fictional_trigger","fictional_view"] {try classify(SQLITE_READ,"records","id","main",source,nil,expected:false)}
  for action in [SQLITE_TRANSACTION,SQLITE_ATTACH,SQLITE_ALTER_TABLE,SQLITE_DROP_TABLE,SQLITE_CREATE_TRIGGER] {try classify(action,"note_requests",nil,"main",nil,nil,expected:false)}
  try classify(SQLITE_PRAGMA,"writable_schema","ON",nil,nil,nil,expected:false)
  let report:[String:Any]=["schema":"sig-pending-prepare-fixed-v1","baseline":"94d9568a8c680f8cdaef0f9584373969ca9546a5","cases":cases,"classifierControls":classifierCount,"actualAutomaticAppTimerExecuted":false,"actualCoreWriterBindingAdapterDiscovery":true,"physicalFreshTimestamps":true,"GUI":false,"model":false,"network":false,"privateHistory":false,"productionChanged":true]
  try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out)
  print("PENDING PREPARATION 25 STORE CONTROLS PASS; no model or GUI")
 }
}
