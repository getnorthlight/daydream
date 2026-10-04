import Foundation
import PrivacyPolicy
import CSQLite
@testable import MemoryCore

private final class FixtureTransport:TypesenseTransport {
 var exists=false,imports=0,deletions=0,projectionsBodyFree=true
 var onImport:(()->Void)?,onGet:(()->Void)?
 var failure:String?
 func request(_ method:String,_ path:String,query:[URLQueryItem],body:Data?,deadline:Date)throws->TypesenseResponse {
  if method == "GET" {onGet?();if failure == "get" {throw SearchFailure.unavailable};return TypesenseResponse(status:exists ? 200:404,data:Data())}
  if method == "POST",path == "/collections" {exists=true;return TypesenseResponse(status:201,data:Data())}
  if method == "POST",path.hasSuffix("/documents/import") {
   imports+=1;onImport?()
   if failure == "import" {throw SearchFailure.unavailable}
   let text=String(decoding:body ?? Data(),as:UTF8.self)
   projectionsBodyFree = projectionsBodyFree && !text.contains("i didn't like the ") && !text.contains("sig :(")
   let lines=text.split(separator:"\n");return TypesenseResponse(status:200,data:Data(lines.map{_ in failure == "ack" ? "{\"success\":false}":"{\"success\":true}"}.joined(separator:"\n").utf8))
  }
  if method == "DELETE" {deletions+=1;if failure == "delete" {throw SearchFailure.unavailable}}
  return TypesenseResponse(status:200,data:Data())
 }
}
func tryRowCount(_ store:MemoryStore,_ sql:String)->Int {try! Int(store.rows(sql).first!.first!)!}
@main enum Checks {
 static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]),output=URL(fileURLWithPath:CommandLine.arguments[2]);var results=[[String:Any]]()
  for kind in ["originating","originating-repeat","standalone","other-connection","protected-trigger","familiar-trigger","failing-trigger","get-failure","import-failure","ack-failure","config-change","policy-change","external-write","direct-zero-write","direct-cancel","clock-write","no-config","strong-secret","originating-deletion","delete-failure"] {
   let now=timestamp(iso(Date()))!,home=root.appendingPathComponent(kind),store=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false)
   var policy=try store.policy();policy.captureText=true;policy.typedConsentVersion=1;try store.updatePolicy(policy,now:now)
   try store.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()),now:now);try store.setUpTypedVault(now:now);_ = try store.acceptSafeTyping(now:now);_ = try store.settleLegacyTypedText(now:now)
   policy=try store.policy();try store.setCaptureState("recording",reason:"Fictional fixture",now:now)
   var config=TypesenseConfiguration(home:home,port:28108,searchKeyFile:home.appendingPathComponent("fixture-search.key").path,syncKeyFile:home.appendingPathComponent("fixture-sync.key").path,enabled:true);config.syntheticOnly=true
   let configFile=home.appendingPathComponent("search-typesense.json")
   func saveConfig()throws {try JSONEncoder().encode(config).write(to:configFile);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:configFile.path)}
   try saveConfig()
   func evidence(_ text:String,id:String,part:Int,reason:String)->Evidence {
    var e=Evidence(id:id,at:iso(now),kind:"keyboard.text_input",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Fictional controlled scratch",text:text,synthetic:true)
    e.captureProvenance=NativeCaptureProvenance(policyRevision:policy.revision,classifierVersion:UnitClassifier.version,windowID:"fictional-window",focusID:"fictional-field",checkedAt:iso(now),generation:1,unit:TypedUnitProvenance(runID:"fictional-run",part:part,sealReason:reason,startedAt:iso(now),keys:20,edits:0,withheld:0,surface:"writing",field:"textArea",send:"unknown",pasted:false))
    return e
   }
   if kind == "protected-trigger" {try store.exec("CREATE TRIGGER fictional_search_mutation AFTER INSERT ON search_index_state BEGIN UPDATE metadata SET body=body WHERE id='policy'; END")}
   if kind == "familiar-trigger" {try store.exec("CREATE TRIGGER summary_queue_record_update AFTER INSERT ON search_index_state BEGIN UPDATE records SET revision=revision; END")}
   if kind == "failing-trigger" {try store.exec("CREATE TRIGGER fictional_search_fail AFTER INSERT ON search_index_state BEGIN SELECT RAISE(ABORT,'fictional controlled failure'); END")}
   let transport=FixtureTransport()
   if kind == "originating-deletion" || kind == "delete-failure" {
    let old=Evidence(id:"old-fictional",at:iso(now),kind:"window.changed",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Fictional old ledger source",synthetic:true)
    _ = try store.ingest(old,now:now);_ = try store.writePending(now:now)
    _ = try store.syncOriginatingSearchIndex(config:config,transport:transport,now:now)
    try store.delete(old.id)
    precondition(tryRowCount(store,"SELECT count(*) FROM search_index_state WHERE id='old-fictional'")==1,"uncertain deletion ledger must remain until acknowledgement")
   }
   let first=evidence("i didn't like the ",id:"first",part:1,reason:"idle")
   let firstSaved=try store.ingest(first,now:now,expectedPolicyRevision:policy.revision,requireRecording:true);precondition(firstSaved)
   let firstExact=try store.hydrateTypedText(first.id,disclosure:.owner,now:now)==first.text;precondition(firstExact)
   _ = try store.writePending(now:now)
   var lockFree=false,failed=false
   transport.onGet={
    let done=DispatchSemaphore(value:0)
    DispatchQueue.global().async {_ = try? store.rows("SELECT count(*) FROM records");done.signal()}
    lockFree=done.wait(timeout:.now()+1) == .success;precondition(lockFree,"HTTP must not hold StoreLock")
   }
   if kind == "get-failure" {transport.failure="get"}
   if kind == "import-failure" {transport.failure="import"}
   if kind == "delete-failure" {transport.failure="delete"}
   if kind == "ack-failure" {transport.failure="ack"}
   transport.onImport={
    if kind == "config-change" {config.enabled=false;try! saveConfig()}
    if kind == "policy-change" {var changed=try! store.policy();changed.captureText=false;try! store.updatePolicy(changed,now:now);changed.captureText=true;try! store.updatePolicy(changed,now:now)}
    if kind == "external-write" {let other=try! MemoryStore(home:home,writable:true,automaticallySyncSearch:false);try! other.transaction {try other.exec("INSERT OR REPLACE INTO metadata VALUES('fictional-external','1')")}}
    if kind == "direct-zero-write" {try! store.exec("UPDATE metadata SET body=body WHERE id='missing-fictional'")}
    if kind == "direct-cancel" {try! store.cancelNote("missing-fictional")}
    if kind == "clock-write" {store.saveTypedClock(now.addingTimeInterval(61))}
   }
   var sync:SearchSyncResult?
   do {
    if kind == "standalone" {sync=try store.syncSearchIndex(config:config,transport:transport,now:now)}
    else if kind == "other-connection" {let other=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false);sync=try other.syncSearchIndex(config:config,transport:transport,now:now)}
    else if kind == "no-config" {try FileManager.default.removeItem(at:configFile);sync=try store.syncOriginatingSearchIndex(now:now)}
    else {sync=try store.syncOriginatingSearchIndex(config:config,transport:transport,now:now);if kind == "originating-repeat" {sync=try store.syncOriginatingSearchIndex(config:config,transport:transport,now:now)}}
   } catch {failed=true}
   let text=kind == "strong-secret" ? "password: FictionalToken99!":"sig :("
   let second=evidence(text,id:"second",part:2,reason:"submit")
   let secondSaved=try store.ingest(second,now:now,expectedPolicyRevision:(try store.policy()).revision,requireRecording:true)
   let kept=secondSaved ? try store.hydrateTypedText(second.id,disclosure:.owner,now:now):nil
   let positive=["originating","originating-repeat","originating-deletion"].contains(kind)
   precondition(positive ? kept==text : kept != text,"search boundary changed "+kind)
   if kind == "strong-secret" {precondition(kept?.contains("FictionalToken99!") != true)}
   if positive {precondition(sync?.status == "synced" && transport.imports==(kind == "originating-deletion" ? 2:1) && !failed && lockFree)}
   if ["get-failure","import-failure","ack-failure","failing-trigger","config-change","policy-change","delete-failure"].contains(kind) {precondition(failed,"real failure effect required")}
   if kind == "originating-deletion" {precondition(sync?.deleted==1 && transport.deletions==1 && tryRowCount(store,"SELECT count(*) FROM search_index_state WHERE id='old-fictional'")==0)}
   if kind == "delete-failure" {precondition(tryRowCount(store,"SELECT count(*) FROM search_index_state WHERE id='old-fictional'")==1,"failed remote deletion retains ledger")}
   precondition(transport.projectionsBodyFree,"index projection must exclude typed body")
   results.append(["case":kind,"positive":positive,"firstExact":firstExact,"secondWritten":secondSaved,"secondExact":kept==text,"marker":kept?.contains("[withheld]")==true,"failed":failed,"lockFree":lockFree,"imports":transport.imports,"indexBodyFree":transport.projectionsBodyFree,"status":sync?.status ?? "failed"])
  }
  var owned:MemoryStore?=try MemoryStore(home:root.appendingPathComponent("lifetime"),writable:true,automaticallySyncSearch:false)
  let holder=OriginatingSearchStore(owned!),otherHolder=OriginatingSearchStore(owned!);precondition(holder.token != otherHolder.token)
  owned=nil;precondition(holder.store==nil && otherHolder.store==nil,"queued holder must not keep store alive")
  let scope=TypedNarrativeMaintenanceScope.search,statement="INSERT OR REPLACE INTO metadata VALUES('search_cursor',?)"
  precondition(scope.permits(action:SQLITE_INSERT,first:"metadata",second:nil,database:"main",source:nil,statement:statement))
  for table in ["records","typed_text","note_requests","generated_notes","tombstones"] {precondition(!scope.permits(action:SQLITE_INSERT,first:table,second:nil,database:"main",source:nil,statement:statement))}
  for source in ["fictional-trigger","summary_queue_record_update"] {precondition(!scope.permits(action:SQLITE_INSERT,first:"metadata",second:nil,database:"main",source:source,statement:statement))}
  for sql in ["INSERT OR REPLACE INTO metadata VALUES('policy',?)","INSERT OR REPLACE INTO metadata VALUES(?,?)","DELETE FROM metadata","DELETE FROM records"] {precondition(!scope.permits(action:SQLITE_INSERT,first:"metadata",second:nil,database:"main",source:nil,statement:sql))}
  try JSONSerialization.data(withJSONObject:["schema":"sig-originating-indexer-controls-v1","cases":results,"GUI":false,"realNetwork":false,"inference":false],options:[.prettyPrinted,.sortedKeys]).write(to:output)
  print("ORIGINATING INDEXER 20 STORE CONTROLS +14 CLASSIFIER/LIFETIME CONTROLS PASS; no network/GUI/model")
 }
}
