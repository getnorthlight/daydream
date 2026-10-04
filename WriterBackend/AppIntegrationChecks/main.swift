import Foundation
import MemoryCore
import WriterBackend
import MemoryUI

actor TestKeys:WriterSecureKeyStore {
    var value="";var reads=0
    func readSecret() async throws -> String {reads+=1;return value}
    func saveSecret(_ value:String) async throws {self.value=value}
    func removeSecret() async throws {value=""}
}
actor TestHTTP {
    var calls=0
    func send(_ request:URLRequest) throws -> CloudHTTPResponse {
        calls+=1
        let body=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
        let provider=body["provider"] as! [String:Any]
        precondition(provider["zdr"] as? Bool==true && provider["data_collection"] as? String=="deny")
        precondition(provider["allow_fallbacks"] as? Bool==false)
        return CloudHTTPResponse(status:503,body:Data())
    }
}
/// Keeps every cloud request body a fake sees, and fails each one (nothing is committed).
actor BodyHTTP {
    var bodies:[String]=[]
    func send(_ request:URLRequest) throws -> CloudHTTPResponse {
        bodies.append(String(decoding:request.httpBody ?? Data(),as:UTF8.self))
        return CloudHTTPResponse(status:503,body:Data())
    }
}
/// Counts every admission call a fake sees. `checkWithApple` stands for the only network use.
actor AdmissionLog {
    var restores=0,appleChecks=0
    func restored() {restores+=1}
    func checked() {appleChecks+=1}
}
@main struct AppIntegrationChecks {
    static func seedResume(_ queue:URL,_ value:Bool) async throws {
        let ledger=try PendingNoteScheduler(file:queue.appendingPathComponent("pending-v1.json"))
        try await ledger.setResumeLocal(value)
    }
    /// A relaunch with a saved On this Mac preference. The fake admission always fails with `failure`
    /// (CompatibleWriterFiles can't be made outside WriterBackend, so a real admission isn't faked).
    @MainActor static func relaunch(root:URL,name:String,resume:Bool?,modelPresent:Bool,failure:WriterFailure,log:AdmissionLog,keys:TestKeys) async throws -> WriterIntegration {
        let home=root.appendingPathComponent(name,isDirectory:true)
        let store=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false)
        let queue=home.appendingPathComponent("WriterScheduling",isDirectory:true)
        try FileManager.default.createDirectory(at:queue,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        if let resume {try await seedResume(queue,resume)}
        // fix/sx-engine-battery: the saved choice now lives in DaydreamWriterIntent; with none saved (an update from a
        // build before it) the ledger's switch says what was on, as these fixtures seed it.
        UserDefaults.standard.removeObject(forKey:WriterIntegration.intentKey)
        UserDefaults.standard.removeObject(forKey:WriterIntegration.downloadingKey)
        let models=home.appendingPathComponent("Models",isDirectory:true)
        if modelPresent {try FileManager.default.createDirectory(at:models,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}
        var admission=LocalAdmission(restoreOffline:{_,_ in await log.restored();throw failure},
                                     checkWithApple:{await log.checked()},signedBuild:{true})
        // Never the network: a download here fails at once.
        admission.download={_,_ in throw WriterFailure.notSent}
        let writer=WriterIntegration(modelRoot:models,keyStore:keys,send:{_ in throw WriterFailure.denied},admission:admission)
        writer.configure(store:store)
        for _ in 0..<250 where writer.busy {try await Task.sleep(nanoseconds:20_000_000)}
        precondition(!writer.busy && writer.provider=="off" && !writer.ready && !writer.cloudEnabled)
        return writer
    }
    /// Owner decision 2026-09-26: after a restart On this Mac comes back by itself using only what is on
    /// this Mac. A launch never asks Apple; only a click does.
    @MainActor static func autoResumeNeverGoesOnline(root:URL) async throws {
        let keys=TestKeys()
        // Saved on, certificate status expired: stays off, one plain line, no network.
        var log=AdmissionLog()
        var writer=try await relaunch(root:root,name:"resume-expired",resume:true,modelPresent:true,failure:.trustEvidenceUnavailable,log:log,keys:keys)
        var restores=await log.restores,checks=await log.appleChecks
        precondition(restores==1 && checks==0,"a launch asked Apple")
        precondition(writer.needsAppleCheck && writer.modelOnMac && writer.status==WriterIntegration.appleCheckLine)
        precondition(WriterIntegration.appleCheckLine=="On this Mac is off until DayDream checks its signature with Apple.")
        // The click (Settings › Turn on): the one Apple check, then everything offline again.
        do {try await writer.useLocal();fatalError("turned on without admitted files")} catch {}
        restores=await log.restores;checks=await log.appleChecks
        precondition(restores==3 && checks==1 && writer.provider=="off","Turn on must ask Apple exactly once, then recheck offline")
        await writer.shutdown()
        // Saved off, certificate status expired: no line, no network.
        log=AdmissionLog()
        writer=try await relaunch(root:root,name:"off-expired",resume:false,modelPresent:true,failure:.trustEvidenceUnavailable,log:log,keys:keys)
        restores=await log.restores;checks=await log.appleChecks
        // fix/sx-engine-battery (hash once per activation): with summaries off, a launch doesn't check the model at all.
        precondition(restores==0 && checks==0 && !writer.needsAppleCheck)
        await writer.shutdown()
        // Saved on, no model: nothing is checked, downloaded or asked.
        log=AdmissionLog()
        writer=try await relaunch(root:root,name:"resume-no-model",resume:true,modelPresent:false,failure:.trustEvidenceUnavailable,log:log,keys:keys)
        restores=await log.restores;checks=await log.appleChecks
        precondition(restores==0 && checks==0 && !writer.needsAppleCheck && !writer.modelOnMac)
        precondition(writer.status=="The model for summaries on this Mac isn't downloaded.")
        await writer.shutdown()
        // Saved on, a damaged file: stays off, says so plainly, no network.
        log=AdmissionLog()
        writer=try await relaunch(root:root,name:"resume-damaged",resume:true,modelPresent:true,failure:.integrity,log:log,keys:keys)
        restores=await log.restores;checks=await log.appleChecks
        precondition(restores==1 && checks==0 && !writer.needsAppleCheck && !writer.modelOnMac)
        precondition(writer.status=="A file for summaries on this Mac didn't pass its check. Nothing was deleted.")
        await writer.shutdown()
        let reads=await keys.reads;precondition(reads==0)
        print("PASS relaunch with On this Mac saved on: offline check only; expired certificate status waits for a click that asks Apple once; no model or a damaged file stays off; no network, key read or download at launch.")
    }
    /// summaries/v3 (K7; owner 2026-09-27, decision 8 reversed): the binding the app makes (`makeCoreBinding`) gives
    /// summaries on this Mac the saved typed words while typing is on; the cloud writer gets them only while Cloud is the
    /// chosen writer (notice v2 accepted, typing consented). Typing off, or This Mac only, sends no words; accepting the
    /// v1 notice never turns cloud on; website typing goes with its host only, never a Chrome page title.
    /// Synthetic store, in-memory typing key, fake cloud key and HTTP.
    @MainActor static func typedWordsStayOnThisMac(root:URL) async throws {
        let home=root.appendingPathComponent("typed-words",isDirectory:true)
        let store=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false)
        var policy=try store.policy();policy.captureText=true;try store.updatePolicy(policy)
        try store.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()));try store.setUpTypedVault();try store.acceptSafeTyping()
        let words="shorten the typing warning in setup quokkamarmalade",title="Warning draft zzqtitle"
        func hasWords(_ text:String)->Bool {text.contains("quokkamarmalade")}
        let http=BodyHTTP(),keys=TestKeys()
        let writer=WriterIntegration(modelRoot:root.appendingPathComponent("absent-model-typed"),keyStore:keys,send:{try await http.send($0)})
        writer.configure(store:store)
        for _ in 0..<250 where writer.busy {try await Task.sleep(nanoseconds:20_000_000)}
        try await writer.saveCloudKey("synthetic-test-only")
        // The v1 notice said cloud never gets the words: accepting it no longer turns cloud on.
        do {try await writer.enableCloud(acceptedDisclosureVersion:1);fatalError("the v1 notice turned cloud on")} catch {}
        precondition(!writer.cloudEnabled && writer.provider=="off")
        // A second store (so nothing recorded before cloud was on joins the moment below): off and This Mac only.
        let before=try MemoryStore(home:root.appendingPathComponent("typed-words-before",isDirectory:true),writable:true,automaticallySyncSearch:false)
        var beforePolicy=try before.policy();beforePolicy.captureText=true;try before.updatePolicy(beforePolicy)
        try before.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()));try before.setUpTypedVault();try before.acceptSafeTyping()
        _=try before.ingest(Evidence(id:"typed-before",at:iso(Date()),kind:"keyboard.text_input",app:"Notes",bundle:"com.apple.Notes",title:title,text:words,synthetic:true))
        let offRead=try before.hydrateTypedText("typed-before",disclosure:.cloudWriter)
        precondition(offRead==nil,"summaries off: the cloud writer reads nothing")
        try before.setSummaryWriter("local")
        let macCloud=try before.hydrateTypedText("typed-before",disclosure:.cloudWriter),macLocal=try before.hydrateTypedText("typed-before",disclosure:.localWriter)
        precondition(macCloud==nil && macLocal==words,
                     "This Mac only: the writer on this Mac reads the words, the cloud writer nothing")
        try await writer.enableCloud(acceptedDisclosureVersion:CloudActivation.disclosureVersion)
        let savedMode=try store.summaryWriter()?.mode
        precondition(writer.cloudEnabled && writer.provider=="cloud" && savedMode=="cloud")
        try await Task.sleep(nanoseconds:1_100_000_000)
        let at=Date()
        _=try store.ingest(Evidence(id:"typed-window",at:iso(at.addingTimeInterval(-0.2)),kind:"window.changed",app:"Notes",bundle:"com.apple.Notes",title:"Setup copy",synthetic:true))
        _=try store.ingest(Evidence(id:"typed-draft",at:iso(at),kind:"keyboard.text_input",app:"Notes",bundle:"com.apple.Notes",title:title,text:words,synthetic:true))
        let sealed=try store.hydrateTypedText("typed-draft",disclosure:.owner);precondition(sealed==words,"fixture: the draft is sealed and typing is on")
        // The app's own binding: the local port reads the words, and its presentation is permitted.
        let binding=WriterIntegration.makeCoreBinding(store:store)
        let day=try DayScope.key(at,timezone:"UTC"),target=WriterTarget(kind:.day,day:day,timezone:"UTC")
        let local=try await binding.port().prepare(target)
        precondition(local.actions.contains{$0.id=="typed-draft" && $0.description.contains(words)},"the app's local binding reads the words")
        let localPermitted=await binding.port().permitted(local,local.actions);precondition(localPermitted)
        // Cloud chosen, notice v2, typing on: the cloud port reads the words too.
        let cloud=try await binding.port(audience:.cloud).prepare(target)
        precondition(cloud.actions.contains{$0.id=="typed-draft" && hasWords($0.description)},"Cloud chosen: the cloud port gets the typed words")
        // The real cloud flow carries the words.
        try await Task.sleep(nanoseconds:2_100_000_000)
        let layers=try store.dayLayers(day:day,timezone:"UTC")
        guard let activity=layers.activities.first(where:{$0.actionIDs.contains("typed-draft")}) else {fatalError("fixture: the draft forms an activity")}
        try await writer.generate(day:day,timezone:"UTC",activityID:activity.id,lastActivity:at)
        let bodies=await http.bodies
        precondition(!bodies.isEmpty && bodies.allSatisfy{$0.contains("Notes")} && bodies.contains(where:hasWords),"a cloud request with Cloud chosen carries the typed words")
        // Browser rows (fix/day-card, owner 9/28): a cloud writer reads them with the page title cleaned (NoteAudience.cloudView).
        func action(_ fields:[String:Any]) throws -> CanonicalAction {
            let base:[String:Any]=["id":"x","evidenceIDs":["x"],"at":iso(Date()),"app":"Google Chrome","bundle":"com.google.Chrome","description":"d","state":"draft","revision":"r","subject":"s","observationKey":"k"]
            return try JSONDecoder().decode(CanonicalAction.self,from:JSONSerialization.data(withJSONObject:base.merging(fields){$1}))
        }
        let webTyped=try action(["kind":"keyboard.text_input","site":"mail.google.com","title":"mail.google.com"])
        let titled=try action(["kind":"keyboard.text_input","site":"mail.google.com","title":"Inbox (3) zzqpagetitle"])
        let page=try action(["kind":"window.changed","site":"mail.google.com","title":"Private page zzqpagetitle","state":"observed"])
        let notes=try action(["kind":"keyboard.text_input","bundle":"com.apple.Notes","app":"Notes","site":"","title":"Draft"])
        precondition(NoteAudience.cloudEligible(webTyped) && NoteAudience.cloudEligible(titled) && NoteAudience.cloudEligible(page) && NoteAudience.cloudEligible(notes)
                     && !NoteAudience.cloudView(titled).title.contains("(3)") && NoteAudience.cloudView(notes).title == "Draft",
                     "browser rows reach the cloud with their page title cleaned; other rows are unchanged")
        // Typing off: no words for any writer.
        var off=try store.policy();off.captureText=false;try store.updatePolicy(off)
        let offWords=try store.hydrateTypedText("typed-draft",disclosure:.cloudWriter)
        precondition(offWords==nil,"typing off: the cloud writer reads nothing")
        await writer.disableCloud();try await writer.deleteCloudKey();await writer.shutdown()
        print("PASS summaries/v3 K7: v1 notice refused; off and This Mac only give the cloud writer nothing; Cloud chosen (v2) + typing on: the cloud port and \(bodies.count) real cloud request(s) carry the words; browser rows with cleaned page titles; typing off gives nothing. Fake HTTP/keys, in-memory typing key.")
    }
    @MainActor static func main() async throws {
        CloudWriter.retryDelays=[0,0]
        UserDefaults.standard.removeObject(forKey:WriterIntegration.intentKey)
        UserDefaults.standard.removeObject(forKey:WriterIntegration.downloadingKey)
        let root=URL(fileURLWithPath:"/private/tmp/writer-app-check-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer{try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(home:root.appendingPathComponent("memory"),writable:true,automaticallySyncSearch:false)
        // fix/sx-all: typing on before the writer starts (a privacy change later would restart cloud summaries).
        var consent=try store.policy();consent.captureText=true;consent.typedConsentVersion=1;try store.updatePolicy(consent)
        try store.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()));try store.setUpTypedVault();try store.acceptSafeTyping()
        var typing=try store.typedTextPolicy()
        typing.categories=TypedCategoryChoices(searchAndAI:true,writing:true,code:true,messagesAndEmail:true,otherWebsites:true)
        _=try store.updateTypedTextPolicy(typing,confirmed:true)
        let keys=TestKeys(),http=TestHTTP()
        let writer=WriterIntegration(modelRoot:root.appendingPathComponent("absent-model"),keyStore:keys,send:{try await http.send($0)})
        writer.configure(store:store)
        try await Task.sleep(nanoseconds:100_000_000)
        precondition(!writer.ready && writer.provider=="off")
        let initialReads=await keys.reads;precondition(initialReads==0)
        try await writer.saveCloudKey("synthetic-test-only")
        precondition(!writer.cloudEnabled && writer.provider=="off")
        do {try await writer.enableCloud(acceptedDisclosureVersion:0);fatalError("consent bypass")}catch{}
        try await writer.enableCloud(acceptedDisclosureVersion:CloudActivation.disclosureVersion)
        precondition(writer.cloudEnabled && writer.provider=="cloud")
        // Actions are synthetic and timestamped AFTER explicit consent. They are
        // ordinary core inputs, not raw keystrokes or imported private memory.
        try await Task.sleep(nanoseconds:1_100_000_000)
        let at=Date()
        // fix/sx-all: one typed draft among the clicks, so the moment needs a model (a moment of clicks alone gets a code
        // note and never reaches OpenRouter, fix/notes-quality).
        let unit:[String:Any]=["version":"typed-unit/v3","runID":"test-run","part":1,"sealReason":"idle","startedAt":iso(at.addingTimeInterval(-20)),
                               "withheld":0,"surface":"writing","field":"unknown","send":"none"]
        let typedRow:[String:Any]=["id":"test-0","at":iso(at),"kind":"keyboard.text_input","app":"TextEdit","bundle":"com.apple.TextEdit","title":"Synthetic study",
                                   "url":"","text":"Outline the synthetic study plan","secure":false,"privateWindow":false,"synthetic":true,
                                   "captureProvenance":["policyRevision":"synthetic","classifierVersion":"sensitive-typing/v2","windowID":"w","focusID":"f",
                                                        "checkedAt":iso(at),"generation":1,"unit":unit]]
        let typedKept=try store.ingest(try JSONDecoder().decode(Evidence.self,from:JSONSerialization.data(withJSONObject:typedRow)))
        precondition(typedKept)
        for index in 1..<21 {
            _=try store.ingest(Evidence(id:"test-\(index)",at:iso(at),kind:"mouse.click",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Synthetic study",synthetic:true))
        }
        let day=try DayScope.key(at,timezone:"UTC")
        let before=try store.dayLayers(day:day,timezone:"UTC")
        precondition(before.summary.actionCount==21)
        let discovery=WriterQueueSource(store:store)
        let early=try await discovery.discover(now:at.addingTimeInterval(20),timezone:"UTC")
        precondition(early.isEmpty)
        let activityDue=try await discovery.discover(now:at.addingTimeInterval(35),timezone:"UTC")
        precondition(activityDue.contains{$0.target.kind == .activity} && !activityDue.contains{$0.target.kind == .day})
        let dayDue=try await discovery.discover(now:at.addingTimeInterval(125),timezone:"UTC")
        // fix/sx-engine-battery: no whole-day note runs; the day's summary comes from its moments and blocks.
        precondition(!dayDue.contains{$0.target.kind == .day})
        try await Task.sleep(nanoseconds:2_100_000_000)
        try await writer.generate(day:day,timezone:"UTC",activityID:before.activities[0].id,lastActivity:at)
        // fix/sx-engine-battery: a 503 is tried twice more, then the note waits for the writer's back-off (Can't reach
        // OpenRouter, with Try Again), not for a per-note Retry.
        let calls=await http.calls;precondition(calls==3)
        precondition(writer.pendingCount==0 && writer.provider=="cloud" && writer.phase == .failed(.cloudOffline))
        let after=try store.dayLayers(day:day,timezone:"UTC")
        precondition(after.summary.actionCount==21 && after.activities[0].generated==nil)
        // An explicit retry makes another strictly guarded synthetic request (tried again the same way).
        try await writer.generate(day:day,timezone:"UTC",activityID:before.activities[0].id,lastActivity:at)
        let retried=await http.calls;precondition(retried==6)
        await writer.disableCloud();precondition(writer.provider=="off")
        try await writer.deleteCloudKey()
        let stored=await keys.value;precondition(stored.isEmpty)
        await writer.shutdown()
        let restarted=WriterIntegration(modelRoot:root.appendingPathComponent("absent-model"),keyStore:keys,send:{try await http.send($0)})
        precondition(!restarted.cloudEnabled && restarted.provider=="off")
        // No configure while the original controller owns the process lock.
        // Scheduler's restart fixture exercises its on-disk handoff separately.
        await restarted.shutdown()
        try await autoResumeNeverGoesOnline(root:root)
        try await typedWordsStayOnThisMac(root:root)
        print("PASS real WriterIntegration + CoreWriterBinding: missing-model offline startup, no launch key read, separate consent, 30s activity discovery and no day note, 21-action eligible-ZDR 503 tried three times then backs off, explicit retry, no fallback, action retention, disable/delete, restart cloud off. Fake HTTP/keys only.")
    }
}
