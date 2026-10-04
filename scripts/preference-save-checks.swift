import Foundation
@testable import MemoryCore

@main struct PreferenceSaveChecks {
    static var count=0
    static func check(_ value:Bool,_ name:String) {precondition(value,name);count += 1;print("PASS "+name)}
    static func rejects(_ name:String,_ work:() throws -> Void) {do{try work();fatalError(name)}catch{check(true,name)}}
    static func main() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("preferences-synthetic-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer{try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(home:root.appendingPathComponent("source"),writable:true,automaticallySyncSearch:false)
        let session=try CaptureSession(store:store),now=Date()
        let initial=try store.policy()
        let enabled=try session.savePreferences(MemoryPreferences(blockedApps:[],nativeTyping:true),expectedRevision:initial.revision,now:now)
        check(enabled.changed && enabled.policy.retentionDays==initial.retentionDays,"typing preference changes without retention change")
        _=try store.ingest(Evidence(id:"private",at:iso(now),kind:"window.changed",app:"Notes",bundle:"com.apple.Notes",title:"Synthetic project",text:"Synthetic typed sentence",synthetic:true),now:now)
        _=try store.ingest(Evidence(id:"public",at:iso(now),kind:"window.changed",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Public fixture",synthetic:true),now:now)
        _=try store.writePending(now:now)
        try store.setActionSubject(["private"],subject:"Synthetic grouping",now:now)
        let action=try store.action("private",now:now)!
        _=try store.correctAction(id:"private",text:"Synthetic corrected sentence",expectedRevision:action.revision,now:now)
        let day=String(iso(now).prefix(10))
        let request=try store.prepareNote(kind:"day",day:day,timezone:"UTC",now:now)
        let output=NoteWriterOutput(requestID:request.id,title:"Synthetic note",bullets:[NoteBullet(text:"Synthetic interpretation",actionIDs:["private"],assertion:"interpretation")],generator:"fixture",generatorVersion:"1")
        _=try store.commitNote(output,now:now)
        try store.exec("INSERT INTO receipts VALUES('historical','opaque immutable fixture')")
        let token=try store.grant(client:"synthetic",recipient:"fixture",scopes:["search","context","detail"])
        let tables=["records","summaries","user_corrections","generated_notes","action_group_edits","receipts"]
        var saved=[String:[[String]]]()
        for table in tables{saved[table]=try store.rows("SELECT * FROM \(table) ORDER BY 1")}
        let requestBody=try store.rows("SELECT body FROM note_requests WHERE id=?",[request.id])
        let epoch=try store.disclosureRevision()
        let restricted=try session.savePreferences(MemoryPreferences(blockedApps:["com.apple.Notes","com.apple.Notes"],nativeTyping:false),expectedRevision:enabled.policy.revision,now:now)
        check(restricted.revokedGrantCount==0 && restricted.policy.blockedApps==["com.apple.Notes"],"restrict commits canonical app set and keeps AI apps connected (it only hides more)")
        for table in tables{check(try saved[table]==store.rows("SELECT * FROM \(table) ORDER BY 1"),"preserved "+table)}
        check(try requestBody==store.rows("SELECT body FROM note_requests WHERE id=?",[request.id]),"writer request body preserved as history")
        check(try store.disclosureRevision() != epoch,"disclosure epoch changed")
        check(try store.action("private",now:now)==nil && store.read("private",now:now)==nil,"excluded action and summary denied")
        check(try !store.searchReport(MemorySearchQuery("Synthetic")).hits.contains(where:{$0["id"]=="private"}),"search filters excluded action")
        check(try !store.context(now:now).sourceIDs.contains("private"),"MCP context excludes restricted action")
        check(try store.dayLayers(day:day,timezone:"UTC",now:now).summary.generated==nil,"old day note cannot disclose after restriction")
        // gold/connections-storage G48: hiding more keeps the AI app's key, and every read it makes is filtered at once.
        check((try? store.authorize(client:"synthetic",recipient:"fixture",capability:token,scope:"detail")) != nil,"a restricting save keeps the AI app's key working")
        check(try !store.searchReport(MemorySearchQuery("Synthetic")).hits.contains(where:{$0["id"]=="private"}) && store.action("private",now:now)==nil,
              "the key that still works reads nothing the restriction hides")
        rejects("committed writer receipt cannot replay") {_=try store.commitNote(output,now:now)}
        let target=try MemoryStore(home:root.appendingPathComponent("snapshot"),writable:true,automaticallySyncSearch:false)
        let audit=try store.exportCanonicalSnapshot(to:target,now:now)
        check(audit.counts["records"]==1,"restricted backup includes only allowed original")
        check(try target.rows("SELECT id FROM receipts").isEmpty && target.rows("SELECT id FROM grants").isEmpty,"backup excludes authority and disclosure receipts")
        check(try target.inspectCanonicalSnapshot(now:now).capture=="off","backup inspection remains recording OFF")
        let restoreOwner=try MemoryStore(home:root.appendingPathComponent("restore-owner"),writable:true,automaticallySyncSearch:false)
        try restoreOwner.setCaptureState("off",reason:"Synthetic restore fixture",now:now)
        let restoreCandidate=try MemoryStore(home:root.appendingPathComponent("restore-candidate"),writable:true,automaticallySyncSearch:false)
        _=try restoreOwner.exportCanonicalSnapshot(to:restoreCandidate,now:now)
        let restorePreview=try restoreOwner.prepareCanonicalRestore(restoreCandidate,now:now)
        _=try restoreOwner.savePreferences(MemoryPreferences(blockedApps:["com.apple.TextEdit"],nativeTyping:false),expectedRevision:restoreOwner.policy().revision)
        let unrestricted=try session.savePreferences(MemoryPreferences(blockedApps:[],nativeTyping:true),expectedRevision:restricted.policy.revision,now:now)
        rejects("old restore preview cannot roll back changed privacy") {_=try restoreOwner.confirmCanonicalRestore(restoreCandidate,previewID:restorePreview.id,confirmed:true,now:now)}
        check(try store.action("private",now:now) != nil,"explicit unrestrict restores permitted evidence without reimport")
        check(try store.dayLayers(day:day,timezone:"UTC",now:now).summary.generated==nil,"unrestrict cannot resurrect old generated note validity")
        rejects("unrestrict cannot resurrect old grant") {try store.authorize(client:"synthetic",recipient:"fixture",capability:token,scope:"context")}
        rejects("unrestrict cannot replay old writer acknowledgement") {_=try store.commitNote(output,now:now)}
        for table in tables{check(try saved[table]==store.rows("SELECT * FROM \(table) ORDER BY 1"),"roundtrip preserves "+table)}
        let textOff=try session.savePreferences(MemoryPreferences(blockedApps:[],nativeTyping:false),expectedRevision:unrestricted.policy.revision,now:now)
        check(try store.read("private",now:now)?.evidence.text=="","typing-only restriction withholds original typed body")
        check(try store.dayLayers(day:day,timezone:"UTC",now:now).summary.generated==nil,"typing-only restriction invalidates generated day note")
        let restored=try session.savePreferences(MemoryPreferences(blockedApps:[],nativeTyping:true),expectedRevision:textOff.policy.revision,now:now)
        let before=try store.rows("SELECT * FROM metadata ORDER BY id")
        let noop=try session.savePreferences(MemoryPreferences(blockedApps:[],nativeTyping:true),expectedRevision:restored.policy.revision,now:now)
        check(try !noop.changed && store.rows("SELECT * FROM metadata ORDER BY id")==before,"no-op has no revision or metadata churn")
        rejects("stale expected revision denied") {_=try store.savePreferences(MemoryPreferences(blockedApps:[],nativeTyping:false),expectedRevision:initial.revision)}
        rejects("invalid app identifier denied") {_=try store.savePreferences(MemoryPreferences(blockedApps:["*"],nativeTyping:false),expectedRevision:restored.policy.revision)}
        // Inject SQLite transaction failure after policy write, proving rollback.
        try store.exec("CREATE TRIGGER fail_preferences BEFORE INSERT ON metadata WHEN NEW.id='disclosure_revision' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END")
        _=try store.grant(client:"failure",recipient:"fixture",scopes:["context"])
        rejects("SQLite failure reports unsaved") {_=try session.savePreferences(MemoryPreferences(blockedApps:[],nativeTyping:false),expectedRevision:restored.policy.revision,now:now)}
        check(try store.policy()==restored.policy,"failed transaction rolls policy and version back together")
        check(session.state != "recording","save failure leaves session stopped")
        try store.exec("DROP TRIGGER fail_preferences")
        // A failure even to persist pause must still stop in-memory intake.
        try session.start(permitted:true,now:now)
        let recordingRevision=try store.disclosureRevision()
        _=try session.savePreferences(MemoryPreferences(blockedApps:[],nativeTyping:true),expectedRevision:restored.policy.revision,now:now)
        check(try session.state=="recording" && store.disclosureRevision()==recordingRevision,"recording no-op neither pauses nor changes authority")
        rejects("direct store save refuses active recorder") {_=try store.savePreferences(MemoryPreferences(blockedApps:[],nativeTyping:false),expectedRevision:restored.policy.revision)}
        try store.exec("CREATE TRIGGER fail_pause BEFORE INSERT ON metadata WHEN NEW.id='capture' BEGIN SELECT RAISE(ABORT,'synthetic pause failure'); END")
        rejects("pause persistence failure prevents preference write") {_=try session.savePreferences(MemoryPreferences(blockedApps:[],nativeTyping:false),expectedRevision:restored.policy.revision,now:now)}
        check(session.state=="error","unpersistable pause stops session in memory")
        check(try !session.record(Evidence(id:"denied",at:iso(now),kind:"window.changed",app:"Notes",bundle:"com.apple.Notes",synthetic:true),focusedFieldKnown:true,permitted:true,now:now),"no intake after failed pause")
        try store.exec("DROP TRIGGER fail_pause");try session.pause(now:now)
        let other=try MemoryStore(home:store.home,writable:true,automaticallySyncSearch:false)
        let group=DispatchGroup(),resultLock=NSLock();var successes=0,conflicts=0
        for connection in [store,other] {group.enter();DispatchQueue.global().async {
            defer{group.leave()}
            do{_=try connection.savePreferences(MemoryPreferences(blockedApps:["com.apple.Notes"],nativeTyping:false),expectedRevision:restored.policy.revision);resultLock.lock();successes += 1;resultLock.unlock()}
            catch PreferenceSaveError.revisionConflict{resultLock.lock();conflicts += 1;resultLock.unlock()}
            catch{fatalError("unexpected race error")}
        }}
        group.wait();check(successes==1 && conflicts==1,"independent connections serialize with one expected-revision winner")
        // Chrome page history: the switch and the owner's sites take the same
        // heavy save as Exclude App (recording stops, AI apps are disconnected).
        let pagesStore=try MemoryStore(home:root.appendingPathComponent("pages"),writable:true,automaticallySyncSearch:false)
        let pagesSession=try CaptureSession(store:pagesStore)
        func notes(_ s:MemoryStore) throws -> Int {Int(try s.rows("SELECT count(*) FROM note_requests WHERE state<>'invalidated'").first![0]) ?? 0}
        func prepared(_ s:MemoryStore) throws {
            _=try s.ingest(Evidence(id:"pages-\(UUID().uuidString)",at:iso(now),kind:"window.changed",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Synthetic page fixture",synthetic:true),now:now)
            _=try s.prepareNote(kind:"day",day:day,timezone:"UTC",now:now)
        }
        let start=try pagesStore.policy()
        check(!start.browserPages && start.browserPagesConsentVersion==nil && !start.browserPagesOn,"page history: a new policy has the switch off")
        // Setup's first answer saves its default-on switches without revoking keys (consent audit 9/28,
        // onboarding-typing-choice-checks); these cases are the later changes, so the first answer is given first.
        let firstAnswer=try pagesSession.savePreferences(MemoryPreferences(blockedApps:start.blockedApps,nativeTyping:false,typingChoiceShown:true),expectedRevision:start.revision,now:now)
        check(!firstAnswer.changed && firstAnswer.policy.revision==start.revision,"page history: the first answer (Off) changes nothing")
        try pagesSession.start(permitted:true,now:now)
        _=try pagesStore.grant(client:"pages",recipient:"fixture",scopes:["context"]);try prepared(pagesStore)
        let on=try pagesSession.savePreferences(MemoryPreferences(blockedApps:[],nativeTyping:false,blockedDomains:["example.org","docs.example.net","example.org"],browserPages:true),expectedRevision:start.revision,now:now)
        check(on.changed && on.policy.browserPages && on.policy.browserPagesConsentVersion==PrivacySettings.browserPagesConsentCurrent && on.policy.browserPagesOn,"page history: switch on saves with this build's consent version (\(PrivacySettings.browserPagesConsentCurrent))")
        check(on.policy.blockedDomains==["docs.example.net","example.org"],"page history: sites save sorted and unique")
        check(pagesSession.state=="paused","page history: turning the switch on stops recording")
        check(try on.revokedGrantCount==1 && (try pagesStore.rows("SELECT id FROM grants").isEmpty),"page history: turning the switch on disconnects AI apps")
        check(try notes(pagesStore)==0,"page history: turning the switch on invalidates note requests")
        check(on.policy.revision != start.revision,"page history: a switch change is a new policy revision")
        let kept=try pagesSession.savePreferences(MemoryPreferences(blockedApps:[],nativeTyping:false),expectedRevision:on.policy.revision,now:now)
        check(!kept.changed && kept.policy==on.policy,"page history: nil sites and nil switch keep the saved values (fast path)")
        let same=try pagesSession.savePreferences(MemoryPreferences(blockedApps:[],nativeTyping:false,blockedDomains:["example.org","docs.example.net"],browserPages:true),expectedRevision:on.policy.revision,now:now)
        check(!same.changed && same.policy.revision==on.policy.revision,"page history: the same sites in another order and the same switch are no change")
        try pagesSession.start(permitted:true,now:now)
        _=try pagesStore.grant(client:"pages",recipient:"fixture",scopes:["context"]);try prepared(pagesStore)
        let untouched=try pagesSession.savePreferences(MemoryPreferences(blockedApps:[],nativeTyping:false,blockedDomains:nil,browserPages:true),expectedRevision:on.policy.revision,now:now)
        check(try !untouched.changed && pagesSession.state=="recording" && !(try pagesStore.rows("SELECT id FROM grants").isEmpty) && (try notes(pagesStore))>0,"page history: no change keeps recording, AI apps and note requests")
        let added=try pagesSession.savePreferences(MemoryPreferences(blockedApps:[],nativeTyping:false,blockedDomains:["docs.example.net","example.org","xn--bcher-kva.de"]),expectedRevision:on.policy.revision,now:now)
        check(added.changed && added.policy.blockedDomains==["docs.example.net","example.org","xn--bcher-kva.de"] && added.policy.browserPagesOn,"page history: adding a site keeps the switch")
        check(try pagesSession.state=="paused" && added.revokedGrantCount==0 && !(try pagesStore.rows("SELECT id FROM grants").isEmpty) && (try notes(pagesStore))==0,"page history: adding a site stops recording and invalidates notes, and keeps AI apps connected")
        _=try pagesStore.grant(client:"pages",recipient:"fixture",scopes:["context"]);try prepared(pagesStore)
        let removed=try pagesSession.savePreferences(MemoryPreferences(blockedApps:[],nativeTyping:false,blockedDomains:["example.org"]),expectedRevision:added.policy.revision,now:now)
        check(try removed.changed && removed.policy.blockedDomains==["example.org"] && removed.revokedGrantCount==1 && (try notes(pagesStore))==0,"page history: removing a site revokes grants and invalidates notes")
        _=try pagesStore.grant(client:"pages",recipient:"fixture",scopes:["context"])
        let off=try pagesSession.savePreferences(MemoryPreferences(blockedApps:[],nativeTyping:false,browserPages:false),expectedRevision:removed.policy.revision,now:now)
        check(off.changed && !off.policy.browserPages && off.policy.browserPagesConsentVersion==nil && !off.policy.browserPagesOn,"page history: switch off clears the consent version")
        check(try off.policy.blockedDomains==["example.org"] && off.revokedGrantCount==0 && !(try pagesStore.rows("SELECT id FROM grants").isEmpty),"page history: switch off keeps the sites and keeps AI apps connected")
        // gold/connections-storage G48: typing. On shares more (every key off); off keeps plain keys and drops exact-word access.
        let typingStore=try MemoryStore(home:root.appendingPathComponent("typing-grants"),writable:true,automaticallySyncSearch:false)
        let typingSession=try CaptureSession(store:typingStore)
        let typingStart=try typingStore.policy()
        _=try typingSession.savePreferences(MemoryPreferences(blockedApps:typingStart.blockedApps,nativeTyping:false,typingChoiceShown:true),expectedRevision:typingStart.revision,now:now)
        let plainKey=try typingStore.grant(client:"plain",recipient:"fixture",scopes:["context","search","detail"])
        let typingOn=try typingSession.savePreferences(MemoryPreferences(blockedApps:[],nativeTyping:true),expectedRevision:typingStore.policy().revision,now:now)
        check(try typingOn.revokedGrantCount==1 && (try typingStore.rows("SELECT id FROM grants").isEmpty),"typing on shares more: every AI app key is turned off")
        let keptKey=try typingStore.grant(client:"plain",recipient:"fixture",scopes:["context","search","detail"])
        let exactKey=UUID().uuidString
        try typingStore.exec("INSERT OR REPLACE INTO grants VALUES(?,?)",["exact\u{1f}fixture",json(ClientGrant(client:"exact",recipient:"fixture",scopes:["context","search","detail",MemoryStore.typedExactScope],capabilityHash:fingerprint(exactKey),mac:"synthetic"))])
        try typingStore.exec("INSERT OR REPLACE INTO metadata VALUES(?,?)",[MemoryStore.typedWordsRequestsID,"[]"])
        let typingOff=try typingSession.savePreferences(MemoryPreferences(blockedApps:[],nativeTyping:false),expectedRevision:typingOn.policy.revision,now:now)
        check(typingOff.changed && typingOff.revokedGrantCount==0 && (try? typingStore.authorize(client:"plain",recipient:"fixture",capability:keptKey,scope:"detail")) != nil
              && (try? typingStore.authorize(client:"exact",recipient:"fixture",capability:exactKey,scope:"search")) != nil,"typing off keeps AI apps connected")
        check(try typingStore.grantScopes(client:"exact",recipient:"fixture") == ["context","search","detail"] && (try typingStore.rows("SELECT body FROM grants WHERE id=?",["exact\u{1f}fixture"]).first?.first.map{!$0.contains("\"mac\"")} ?? false)
              && (try typingStore.rows("SELECT id FROM metadata WHERE id=?",[MemoryStore.typedWordsRequestsID]).isEmpty),"typing off drops every exact-word access and request")
        _=plainKey
        let unblock=try typingSession.savePreferences(MemoryPreferences(blockedApps:["com.apple.Notes"],nativeTyping:false),expectedRevision:typingOff.policy.revision,now:now)
        check(unblock.revokedGrantCount==0,"excluding an app keeps AI apps connected")
        let unblocked=try typingSession.savePreferences(MemoryPreferences(blockedApps:[],nativeTyping:false),expectedRevision:unblock.policy.revision,now:now)
        check(try unblocked.revokedGrantCount==2 && (try typingStore.rows("SELECT id FROM grants").isEmpty),"an app no longer excluded shares more: every AI app key is turned off")
        for bad in [["Example.org"],["www.example.org"],["https://example.org"],["exa mple.org"],["bücher.de"],[""],["*.example.org"],(0...256).map{"site\($0).example.org"}] {
            rejects("page history: invalid sites refused: \(bad.first ?? "")\(bad.count > 1 ? " (257 sites)" : "")") {_=try pagesStore.savePreferences(MemoryPreferences(blockedApps:[],nativeTyping:false,blockedDomains:bad),expectedRevision:off.policy.revision)}
        }
        check(try pagesStore.policy()==off.policy,"page history: a refused save changes nothing")
        let full=try pagesStore.savePreferences(MemoryPreferences(blockedApps:[],nativeTyping:false,blockedDomains:(0..<256).map{"site\($0).example.org"}),expectedRevision:off.policy.revision)
        check(full.policy.blockedDomains.count==256,"page history: 256 sites can be saved")
        try pagesSession.start(permitted:true,now:now)
        rejects("page history: the store refuses a site change while recording") {_=try pagesStore.savePreferences(MemoryPreferences(blockedApps:[],nativeTyping:false,blockedDomains:[]),expectedRevision:full.policy.revision)}
        rejects("page history: the store refuses a switch change while recording") {_=try pagesStore.savePreferences(MemoryPreferences(blockedApps:[],nativeTyping:false,browserPages:true),expectedRevision:full.policy.revision)}
        var legacy=try JSONSerialization.jsonObject(with:Data(json(full.policy).utf8)) as! [String:Any]
        legacy.removeValue(forKey:"browserPages");legacy.removeValue(forKey:"browserPagesConsentVersion")
        let decoded=try JSONDecoder().decode(PrivacySettings.self,from:JSONSerialization.data(withJSONObject:legacy))
        check(!decoded.browserPages && !decoded.browserPagesOn && decoded.blockedDomains==full.policy.blockedDomains,"page history: an older saved policy decodes with the switch off")
        var unconsented=full.policy;unconsented.browserPages=true;unconsented.browserPagesConsentVersion=nil
        check(!unconsented.browserPagesOn,"page history: the switch without a consent version reads Off")
        print("PASSED \(count) synthetic preference checks")
    }
}
