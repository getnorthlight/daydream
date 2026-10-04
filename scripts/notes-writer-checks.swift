import Foundation
import AppKit
@testable import MemoryCore
import WriterBackend
import MemoryUI

/// gold/notes regression checks for the summary writer as the app runs it (the real WriterIntegration, scheduler and
/// core binding): cloud work that can never be sent stays out of the queue (G25), a request that never left the Mac is
/// tried again (G26), the Retry count and every status line stay true (G73 and the status latches), a privacy save leaves
/// the Cloud summaries switch on (G21), and AI apps are never told "off" while cloud is on, or "cloud" after quit (G52).
/// Fake keys and a fake OpenRouter only: no Keychain, no network, no app, no capture.
actor TestKeys:WriterSecureKeyStore {
    var value=""
    func readSecret() async throws -> String {value}
    func saveSecret(_ value:String) async throws {self.value=value}
    func removeSecret() async throws {value=""}
}
actor FakeOpenRouter {
    /// fix/sx-engine-battery: `invalid` answers with a note that fails the checks (it waits for Retry); a 503 is tried
    /// again twice, then the writer backs off.
    enum Mode {case unavailable,offline,invalid}
    var mode=Mode.unavailable,calls=0
    func set(_ value:Mode) {mode=value}
    func send(_ request:URLRequest) throws -> CloudHTTPResponse {
        switch mode {
        case .offline:throw URLError(.notConnectedToInternet)
        case .unavailable:calls+=1;return CloudHTTPResponse(status:503,body:Data())
        case .invalid:
            calls+=1
            return CloudHTTPResponse(status:200,body:try JSONSerialization.data(withJSONObject:["model":CloudWriter.model,"choices":[["message":["content":"not a note"]]]]))
        }
    }
}
@main struct NotesWriterChecks {
    static var passed=0,failed=0
    static func check(_ value:Bool,_ label:String,_ detail:@autoclosure ()->String="") {
        if value {passed+=1;print("PASS "+label)} else {failed+=1;print("FAIL "+label+(detail().isEmpty ? "" : " — "+detail()))}
    }
    static var root:URL!
    /// The zone the app's writer works in (its discovery uses the Mac's zone), so Summarize Now and the poll agree.
    static let zone=TimeZone.current.identifier
    static func sleep(_ seconds:Double) async {try? await Task.sleep(nanoseconds:UInt64(seconds*1e9))}
    struct Rig {let home:URL,store:MemoryStore,writer:WriterIntegration,http:FakeOpenRouter}
    @MainActor static func rig(_ name:String,before:(URL,MemoryStore) throws -> Void={_,_ in}) async throws -> Rig {
        let home=root.appendingPathComponent(name)
        let store=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false)
        try before(home,store)
        let http=FakeOpenRouter()
        let writer=WriterIntegration(modelRoot:root.appendingPathComponent(name+"-no-model"),keyStore:TestKeys(),send:{try await http.send($0)})
        writer.configure(store:store)
        for _ in 0..<50 where writer.busy {await sleep(0.1)}
        return Rig(home:home,store:store,writer:writer,http:http)
    }
    @MainActor static func enable(_ rig:Rig) async throws {
        try await rig.writer.saveCloudKey("synthetic-test-only")
        try await rig.writer.enableCloud(acceptedDisclosureVersion:CloudActivation.disclosureVersion)
        await sleep(1.1)   // actions after this are after the cloud cutoff
    }
    /// One settled moment after the cutoff: (day, activity id).
    @MainActor static func moment(_ rig:Rig,_ id:String,_ title:String) async throws -> (String,String) {
        let at=Date()
        _=try rig.store.ingest(Evidence(id:id,at:iso(at),kind:"window.changed",app:"TextEdit",bundle:"com.apple.TextEdit",title:title,synthetic:true),now:at)
        // notes-quality: a window alone is written by code (no request); typing, even without its words, asks the writer.
        _=try rig.store.ingest(Evidence(id:id+"-k",at:iso(at.addingTimeInterval(0.1)),kind:"keyboard.text_input",app:"TextEdit",bundle:"com.apple.TextEdit",title:title,synthetic:true),now:at.addingTimeInterval(0.1))
        await sleep(2.2)
        let day=try DayScope.key(at,timezone:zone)
        return (day,try rig.store.dayLayers(day:day,timezone:zone).activities.first{$0.actionIDs.contains(id)}!.id)
    }
    /// Summarize Now for one moment. Waits out a poll that is running at that moment.
    @MainActor static func generate(_ rig:Rig,_ target:(String,String)) async throws {
        for attempt in 0..<40 {
            do {try await rig.writer.generate(day:target.0,timezone:zone,activityID:target.1,lastActivity:Date().addingTimeInterval(-3));return}
            catch MemError.invalid(let message) where message.hasPrefix("Enable a ready writer first") && attempt<39 {await sleep(0.25)}
            // claude/summary-fail-1003: a writer still starting or busy is a one-off now (`SummarizeNowFailure.once`).
            catch SummarizeNowFailure.once(_) where attempt<39 {await sleep(0.25)}
        }
    }
    static func ledger(_ rig:Rig) throws -> [[String:Any]] {
        let data=try Data(contentsOf:rig.home.appendingPathComponent("WriterScheduling/pending-v1.json"))
        return ((try JSONSerialization.jsonObject(with:data) as? [String:Any])?["entries"] as? [[String:Any]]) ?? []
    }
    static func entry(_ rig:Rig,_ activityID:String) throws -> [String:Any]? {
        try ledger(rig).first{(($0["item"] as? [String:Any])?["activityID"] as? String)==activityID}
    }
    @MainActor static func plain(_ rig:Rig) -> String {WriterStatusText.plain(rig.writer.status) ?? ""}

    @MainActor static func main() async throws {
        setvbuf(stdout,nil,_IOLBF,0)
        CloudWriter.retryDelays=[0,0]
        // The runner passes a folder of its own; the writer's ledger folder must not sit under a symlink (/var).
        let base=ProcessInfo.processInfo.environment["NOTES_CHECK_ROOT"].map{URL(fileURLWithPath:$0,isDirectory:true)} ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        root=base.appendingPathComponent("notes-writer-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer {try? FileManager.default.removeItem(at:root)}
        try await fullLedger()
        try await earlierHistory()
        try await offline()
        try await latch()
        try await narrowing()
        try await report()
        try levelWiring()
        check(WriterStatusText.plain("Writer queue full.") == "Too many summaries are waiting, so new moments wait too. Your activity is kept.",
              "G73 a full queue says new moments wait too, and promises nothing more")
        print("notes-writer: \(passed) passed, \(failed) failed")
        if failed>0 {try? FileManager.default.removeItem(at:root);exit(1)}
    }

    /// G25: a queue an earlier build filled with moments cloud can never be sent (all from before it was turned on)
    /// is cleared when cloud is turned on, so the next moment still gets its note request.
    @MainActor static func fullLedger() async throws {
        var old=Set<String>()
        let rig=try await rig("full-ledger") { home,store in
            let end=Date().addingTimeInterval(-3600)
            var entries:[[String:Any]]=[]
            let policy=try store.policy().revision
            for k in 0..<128 {
                let at=end.addingTimeInterval(-400*Double(k))
                _=try store.ingest(Evidence(id:"old-\(k)",at:iso(at),kind:"window.changed",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Report \(k)",synthetic:true),now:Date())
            }
            for k in 0..<128 {
                let at=end.addingTimeInterval(-400*Double(k)),day=try DayScope.key(at,timezone:zone)
                let moment=try store.dayLayers(day:day,timezone:zone).activities.first{$0.actionIDs.contains("old-\(k)")}!
                old.insert(moment.id)
                let stamp=at.timeIntervalSinceReferenceDate
                entries.append(["item":["kind":"activity","day":day,"timezone":zone,"activityID":moment.id,"inputRevision":moment.inputRevision,"policyRevision":policy,"lastActivity":stamp],
                                "status":"pending","attempts":1,"nextAttempt":stamp])
            }
            let folder=home.appendingPathComponent("WriterScheduling")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try JSONSerialization.data(withJSONObject:["version":1,"entries":entries,"localResumeEnabled":false]).write(to:folder.appendingPathComponent("pending-v1.json"))
        }
        try await enable(rig)
        let target=try await moment(rig,"fresh","Fresh plan")
        do {try await generate(rig,target)} catch {check(false,"G25 a new moment is summarized after cloud is turned on over a full test 4 queue","\(error)")}
        let calls=await rig.http.calls
        // A 503 is tried twice more (fix/sx-engine-battery): three requests for the one new moment.
        check(calls==3,"G25 a new moment is summarized after cloud is turned on over a full test 4 queue","\(calls) requests sent")
        check(try !ledger(rig).contains{old.contains((($0["item"] as? [String:Any])?["activityID"] as? String) ?? "")},
              "G25 the old queue entries, which could never be sent, are gone")
        await rig.writer.shutdown()
    }

    /// fix/r1-writer: the level note is written through `LevelRunner` (its checks run it with a slow model load), and
    /// turning a writer off or on stops it and waits for it first, so nothing is saved after Off and one model loads.
    static func levelWiring() throws {
        let source=try String(contentsOfFile:"Sources/MacMemApp/WriterIntegration.swift",encoding:.utf8)
        func body(_ signature:String) -> String {
            guard let start=source.range(of:signature),let open=source[start.upperBound...].firstIndex(of:"{") else {return ""}
            var depth=0,i=open
            while i<source.endIndex {
                if source[i]=="{" {depth+=1} else if source[i]=="}" {depth-=1;if depth==0 {return String(source[open...i])}}
                i=source.index(after:i)
            }
            return ""
        }
        check(body("private func stopProvider(").contains("await levelRunner.stop()"),"fix/r1-writer turning summaries off stops the level note being written and waits for it")
        check(body("private func activateLocal()").contains("await levelRunner.stop()"),"fix/r1-writer turning this Mac on waits for a level note still finishing (one model load)")
        let tick=body("private func tick(")
        check(tick.contains("levelRunner.step(") && !tick.contains("levels.step("),"fix/r1-writer the poll writes level notes only through the cancellable runner")
        // fix/r1-writer (b): the level model's backoff (LevelRunner, checked in level-binding-checks) starts over on a settings change.
        check(body("private func activateLocal()").contains("await levelRunner.reset()") && tick.range(of:#"revision != policyRevision \{[^}]*await levelRunner\.reset\(\)"#,options:.regularExpression) != nil,
              "fix/r1-writer a level model that kept failing is tried again at once after a settings change")
        // r2: one moment left pending (waiting for Retry) must not stop every level note: the level step is gated on
        // moments still moving (momentsWaiting) only, never on pendingCount (LevelChecks: the core leaves a stuck moment out).
        let gate=tick.components(separatedBy:"\n").first{$0.contains("if !momentsWaiting") && $0.contains("let levels")} ?? ""
        check(!gate.isEmpty && !gate.contains("pendingCount"),"r2 a pending moment never stops block, day, week and month notes (levels not gated on pendingCount)",gate)
    }

    /// G25: moments from before cloud was turned on are never queued, so they never sit "pending" or count for Retry.
    @MainActor static func earlierHistory() async throws {
        let rig=try await rig("earlier") { _,store in
            let at=Date().addingTimeInterval(-1800)
            for i in 0..<3 {
                _=try store.ingest(Evidence(id:"early-\(i)",at:iso(at.addingTimeInterval(Double(i*400))),kind:"window.changed",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Early \(i)",synthetic:true),now:Date())
            }
        }
        try await enable(rig)
        try? await rig.writer.retryPending()   // one more full pass
        await sleep(0.5)
        let queued=try ledger(rig).count
        check(queued==0 && rig.writer.pendingCount==0,"G25 moments from before cloud was turned on are never queued","\(queued) queued, \(rig.writer.pendingCount) waiting")
        await rig.writer.shutdown()
    }

    /// G26/G73: a request that never left the Mac waits for a retry (not for the Retry button), and is sent again.
    @MainActor static func offline() async throws {
        let rig=try await rig("offline")
        try await enable(rig)
        let target=try await moment(rig,"trip","Trip plan")
        await rig.http.set(.offline)
        try await generate(rig,target)
        let state=try entry(rig,target.1)?["status"] as? String
        // fix/sx-engine-battery: it is queued again and waits for the writer-wide back-off.
        check(state=="retry" || state=="queued","G26 no connection: the note is scheduled to be tried again, not left pending","status \(state ?? "none")")
        check(rig.writer.pendingCount==0,"G73 the Retry count leaves out notes that are already scheduled to retry","\(rig.writer.pendingCount)")
        check(plain(rig)=="Some notes are waiting. Your activity is kept.","G26 the line says notes are waiting","\(plain(rig))")
        await rig.http.set(.unavailable)
        var calls=0
        for _ in 0..<180 {calls=await rig.http.calls;if calls>0 {break};await sleep(0.5)}
        check(calls>=1,"G26 once the connection is back, the request is sent without anyone pressing Retry","\(calls) requests sent")
        await rig.writer.shutdown()
    }

    /// Status latches: "notes are waiting" goes away once nothing waits any more.
    @MainActor static func latch() async throws {
        let rig=try await rig("latch")
        try await enable(rig)
        let target=try await moment(rig,"gone","Draft to delete")
        await rig.http.set(.invalid)
        try await generate(rig,target)
        check(plain(rig)=="Some notes are waiting. Your activity is kept." && rig.writer.pendingCount==1,"latch fixture: a failed cloud reply leaves the note waiting","\(plain(rig)) \(rig.writer.pendingCount)")
        try rig.store.delete("gone")
        try await rig.writer.retryPending()
        check(rig.writer.pendingCount==0 && plain(rig)=="Cloud summaries are on, for new activity only.",
              "latch: once nothing waits, the waiting line goes back to the resting line","\(plain(rig)) \(rig.writer.pendingCount)")
        await rig.writer.shutdown()
    }

    /// G21: a privacy save stops the running cloud writer (its cutoff and policy binding are rebuilt), then cloud comes
    /// back on by itself: the switch stays on across privacy changes and only a disclosure-version bump turns it off.
    @MainActor static func narrowing() async throws {
        let rig=try await rig("narrowing")
        try await enable(rig)
        _=try rig.store.savePreferences(MemoryPreferences(blockedApps:["com.example.unused"],nativeTyping:false),expectedRevision:try rig.store.policy().revision)
        try? await rig.writer.retryPending()
        for _ in 0..<60 where rig.writer.provider != "cloud" || rig.writer.busy {await sleep(0.1)}
        check(rig.writer.provider=="cloud","G21 a privacy save leaves the Cloud summaries switch on (cloud resumes by itself)","\(rig.writer.provider) \(plain(rig))")
        check(try rig.store.summaryWriter()?.mode == "cloud","G21 AI apps are told cloud is on after the privacy save","\((try? rig.store.summaryWriter()?.mode) ?? "nothing")")
        await rig.writer.shutdown()
    }

    /// G52: what AI apps read always matches: never "off" while cloud is on, and "off" after quit.
    @MainActor static func report() async throws {
        let rig=try await rig("report")
        try await rig.writer.saveCloudKey("synthetic-test-only")
        // Another connection holds the database for writing, so saving the summary mode fails for a while.
        let blocker=try MemoryStore(home:rig.home,writable:true,automaticallySyncSearch:false)
        let released=DispatchSemaphore(value:0)
        DispatchQueue.global().async {_=try? blocker.transaction {Thread.sleep(forTimeInterval:4)};released.signal()}
        await sleep(0.3)
        var threw=false
        do {try await rig.writer.enableCloud(acceptedDisclosureVersion:CloudActivation.disclosureVersion)} catch {threw=true}
        let told=try rig.store.summaryWriter()?.mode
        check(rig.writer.provider != "cloud" || told == "cloud","G52 AI apps are never told summaries are off while cloud is on","provider \(rig.writer.provider), told \(told ?? "nothing")")
        check(threw && rig.writer.status=="Couldn't save the summary setting, so cloud stays off. Try again.","G52 when that can't be saved, cloud stays off and says so","\(rig.writer.status)")
        while released.wait(timeout:.now()) == .timedOut {await sleep(0.1)}
        await sleep(3)
        let caught=try rig.store.summaryWriter()?.mode
        check(caught == rig.writer.provider,"G52 the saved mode catches up once the database is free","told \(caught ?? "nothing")")
        try await rig.writer.enableCloud(acceptedDisclosureVersion:CloudActivation.disclosureVersion)
        check(try rig.store.summaryWriter()?.mode == "cloud","G52 fixture: cloud on is saved")
        NotificationCenter.default.post(name:NSApplication.willTerminateNotification,object:nil)
        await sleep(0.3)
        let atQuit=try rig.store.summaryWriter()?.mode
        check(atQuit == "off","G52 at quit AI apps are told summaries are off","told \(atQuit ?? "nothing")")
        await rig.writer.shutdown()
    }
}
