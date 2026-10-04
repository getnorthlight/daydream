import Foundation
@testable import MemoryCore
import WriterBackend
import PrivacyPolicy
import BrowserBridge

@main struct AdapterChecks {
    static var count=0
    static func check(_ value:Bool,_ label:String) {precondition(value,label);count+=1;print("PASS "+label)}
    static func wireAction(_ action:CanonicalAction) throws -> NoteAction {try JSONDecoder().decode(NoteAction.self,from:JSONEncoder().encode(action))}
    static func main() async throws {
        setbuf(stdout,nil)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("core-adapters-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(home:root,writable:true,automaticallySyncSearch:false),now=Date()
        _=try store.ingest(Evidence(id:"first",at:iso(now),kind:"window.changed",app:"Notes",title:"Research",synthetic:true))
        _=try store.correctAction(id:"first",text:"Corrected research topic",expectedRevision:store.action("first")!.revision)
        let day=String(iso(now).prefix(10)),target=WriterTarget(kind:.day,day:day,timezone:"UTC")
        let binding=CoreWriterBinding(store:store),port=binding.port()
        let request=try await port.prepare(target)
        check(request.actions[0].state=="reported","corrected source attributed in actual provider input")
        check(request.actions[0].description.contains("Corrected research topic"),"correction not dropped by writer wire subset")
        check(await port.permitted(request,request.actions),"actual durable core authorizes prepared dispatch")
        var substituted=request.actions;substituted[0].description="Fabricated replacement"
        check(!(await port.permitted(request,substituted)),"same revision cannot authorize substituted presentation")
        // A prompt5 answer (item ids and text); validator7 derives the label from the corrected state.
        let provider=CoreWriterAdapter(core:port,generate:{request,actions in
            let view=try ModelView(request:request,actions:actions)
            precondition(view.text.contains("YOUR NOTE"),"the correction reaches the writer as the user's note: \(view.text)")
            return try CanonicalGrounding.validate(#"{"title":"Research in Notes","bullets":[{"ids":["i1"],"text":"You noted a corrected research topic."}]}"#,request:request,view:view,provider:CanonicalLocalWriter.provider)
        })
        let result=try await provider.process(target,lastActivity:now.addingTimeInterval(-3))
        if case .committed(let receipt)=result {check(receipt.status=="generated_unverified" && receipt.output.bullets[0].assertion=="reported","actual adapter commits through canonical validator")} else {fatalError("not committed: \(result)")}
        check(try store.action("first")?.description.contains("Corrected research topic")==true,"regeneration preserves durable correction")
        _=try store.ingest(Evidence(id:"second",at:iso(Date()),kind:"window.changed",app:"Notes",title:"Research",synthetic:true))
        let resumed=try await CoreWriterBinding(store:store).port().prepare(target)
        let prepared=try await port.prepare(target)
        check(resumed.id==prepared.id,"new binding reuses durable pending request")
        try await port.cancel(prepared.id)
        check(!(await port.permitted(prepared,prepared.actions)),"cancel denies later provider dispatch")

        let capture=CoreCaptureBinding(store:store)
        var policy=try store.policy();policy.captureText=true;policy.typedConsentVersion=1
        try store.updatePolicy(policy);try store.setCaptureState("recording",reason:"synthetic fixture")
        // Safe typing B, the hard rule: the effective switch is consent AND a ready vault.
        check(!(try await capture.context()).policy.typedText,"consent without a vault keeps the effective typing switch off")
        let typedKeys=InMemoryTypedKeyStore();try store.attachVault(TypedTextVault(keyStore:typedKeys))
        check(!(try await capture.context()).policy.typedText,"a vault that is not set up keeps typing off")
        try store.setUpTypedVault()
        // Safe typing E/F: the build 4 answer and a ready key are not enough;
        // the safe-typing screen (consent v2) completes the master switch.
        check(!(try await capture.context()).policy.typedText,"a ready vault without the safe-typing screen keeps typing off")
        try store.acceptSafeTyping()
        let unlocked=try await capture.context()
        check(unlocked.policy.typedText,"consent, the safe-typing screen and a ready vault turn typing on")
        typedKeys.locked=true;_=try store.reconcileTypedVault()
        let lockedContext=try await capture.context()
        check(!lockedContext.policy.typedText && lockedContext.policy.version != unlocked.policy.version,"a locked Keychain turns typing off and is a policy boundary")
        var lockedProof=FocusProof();lockedProof.generation=lockedContext.generation;lockedProof.policyVersion=lockedContext.policy.version;lockedProof.checkedAt=10_000_000_000
        lockedProof.bundle="com.apple.Notes";lockedProof.windowID="native-window";lockedProof.focusID="native-field";lockedProof.role="AXTextArea"
        lockedProof.surface = .native;lockedProof.secureInput = .no;lockedProof.privateMode = .no
        lockedProof.verified=true;lockedProof.fieldStateVerified=true;lockedProof.frameAccessible=true;lockedProof.navigationStable=true
        var lockedRead=false
        let lockedDecision=try await capture.append(proof:lockedProof,now:10_000_000_000,readCharacters:{lockedRead=true;return "must not read while locked"})
        check(lockedDecision.outcome != .allowed && !lockedRead,"locked vault: no character is read")
        typedKeys.locked=false;_=try store.reconcileTypedVault()
        let context=try await capture.context(),mono:UInt64=10_000_000_000
        var proof=FocusProof();proof.generation=context.generation;proof.policyVersion=context.policy.version;proof.checkedAt=mono
        proof.bundle="com.apple.Notes";proof.windowID="native-window";proof.focusID="native-field";proof.role="AXTextArea"
        proof.surface = .native;proof.secureInput = .no;proof.privateMode = .no
        proof.verified=true;proof.fieldStateVerified=true;proof.frameAccessible=true;proof.navigationStable=true
        var read=false
        var denied=proof;denied.secureInput = .yes
        let denial=try await capture.append(proof:denied,now:mono,readCharacters:{read=true;return "must not read"})
        check(denial.outcome != .allowed && !read,"secure metadata blocks character acquisition closure")
        proof.generation=try await capture.context().generation
        let accepted=try await capture.append(proof:proof,now:mono,readCharacters:{"A harmless draft"})
        check(accepted.outcome == .allowed,"permitted native burst enters transient stage")
        check(try await capture.commitText(id:"native-draft",proof:proof,now:mono,wallTime:now),"actual native adapter durably commits permitted draft")
        check(try store.action("native-draft")?.state=="draft","typed event never becomes send evidence")
        check(try store.read("native-draft")?.evidence.text=="" && store.hydrateTypedText("native-draft",disclosure:.owner)=="A harmless draft" && store.rows("SELECT id FROM records WHERE body LIKE '%harmless draft%'").isEmpty,"the adapter's typed row is sealed: text \"\" in the body, words only through the store")
        proof.generation=try await capture.context().generation
        _=try await capture.append(proof:proof,now:mono,readCharacters:{"Another harmless draft"})
        try store.setCaptureState("paused",reason:"synthetic pause")
        do {_=try await capture.commitText(id:"paused-draft",proof:proof,now:mono,wallTime:now);fatalError("pause accepted")} catch {check(true,"pause before persistence rejects candidate")}
        check(try store.action("paused-draft")==nil,"paused text never reaches canonical actions")
        try store.setCaptureState("recording",reason:"synthetic fixture")
        proof.generation=try await capture.context().generation
        let secret=try await capture.append(proof:proof,now:mono,readCharacters:{"password: shouldneverpersist"})
        check(secret.outcome != .allowed,"classifier rejection before Evidence construction")
        check(!(try await capture.commitText(id:"secret",proof:proof,now:mono,wallTime:now)),"rejected burst cannot commit")
        check(try store.rows("SELECT id FROM records WHERE body LIKE '%shouldneverpersist%'").isEmpty,"rejected candidate absent from raw database")
        // Actual BrowserReceiver output, synthetic trusted native witness only.
        // No production release flags or browser configuration are changed.
        let browserContext=try await capture.context()
        let extensionID=String(repeating:"a",count:32),document=UUID().uuidString,focus=UUID().uuidString
        let receiver=BrowserReceiver(extensionID:extensionID)
        check(receiver.connect(NativePeer(extensionID:extensionID,callerOrigin:"chrome-extension://\(extensionID)/",browserBundle:"com.google.Chrome",verifiedLaunchIdentity:true)),"isolated receiver connects synthetic trusted identity")
        var bridgePolicy=BridgePolicy();bridgePolicy.revision=Int(browserContext.policy.version)
        bridgePolicy.metadataConsent=true;bridgePolicy.integrationValidated=true;bridgePolicy.physicalDeviceValidated=true;bridgePolicy.allowedOrigins=["https://example.test"]
        var preflight=NativePreflight();preflight.frontmostChrome=true;preflight.normalWindow=true;preflight.secureInputOff=true;preflight.permissionPresent=true;preflight.checkedAt=mono
        var witness=NativeWitness();witness.preflight=preflight;witness.nativeWindowID="native-window";witness.nativeFocusID="native-focus"
        witness.windowMappingVerified=true;witness.focusMappingVerified=true;witness.windowID=3;witness.tabID=9;witness.frameID=0;witness.documentID=document;witness.focusID=focus;witness.role="AXButton"
        proof.generation=browserContext.generation;proof.policyVersion=browserContext.policy.version;proof.surface = .browser;proof.bundle="com.google.Chrome"
        proof.windowID="3";proof.tabID="9";proof.frameID="0";proof.documentID=document;proof.focusID=focus;proof.role="AXButton";proof.url="https://example.test"
        let probe=receiver.request(policy:bridgePolicy,preflight:preflight,now:mono)!
        let payload:[String:Any]=["version":1,"kind":"observation","nonce":probe.nonce,"policyRevision":probe.policyRevision,"windowMode":"normal","tabMode":"normal","windowID":3,"tabID":9,"frameID":0,"documentID":document,"navigationGeneration":1,"focusID":focus,"focusGeneration":1,"role":"button","safety":"noneditable","origin":"https://example.test","textEnabled":false]
        let event=receiver.receive(try JSONSerialization.data(withJSONObject:payload),policy:bridgePolicy,witness:witness,now:mono,privacyAllowsMetadata:{_ in CaptureGate.metadata(proof,policy:browserContext.policy,generation:browserContext.generation,now:mono).outcome == .allowed})!
        check(try await capture.commitBrowser(event,proof:proof,now:mono,wallTime:now),"actual receiver event becomes canonical action")
        check(!(try await capture.commitBrowser(event,proof:proof,now:mono,wallTime:now)),"same verified event retry is idempotent")
        check(!(try await capture.commitBrowser(event,proof:proof,now:mono+500_000_000,wallTime:now.addingTimeInterval(0.5))),"retry with later wall clock cannot rewrite immutable observation")
        let browserRows=try store.rows("SELECT body FROM records WHERE json_extract(body,'$.kind')='browser.observed'")
        let browserEvidence=try decode(Evidence.self,browserRows[0][0])
        check(browserEvidence.browserVerification?.documentID==document && browserEvidence.browserVerification?.sessionID==event.sessionID,"browser provenance survives durable roundtrip")
        check(browserEvidence.text.isEmpty && browserEvidence.title.isEmpty && browserEvidence.url=="https://example.test","browser persistence contains origin only, no field/title/value")
        check(try store.action(browserEvidence.id)?.description.contains("reading is not established")==true,"brief browser observation not discarded or called reading")
        do {_=try await capture.commitBrowser(event,proof:proof,now:mono+1_000_000_001,wallTime:now);fatalError("stale accepted")} catch {check(true,"stale browser event denied")}
        var wrong=proof;wrong.documentID=UUID().uuidString
        do {_=try await capture.commitBrowser(event,proof:wrong,now:mono,wallTime:now);fatalError("wrong document accepted")} catch {check(true,"wrong document proof denied")}
        var charactersRead=false
        let browserDenied=try await capture.append(proof:proof,now:mono,readCharacters:{charactersRead=true;return "not read"})
        check(browserDenied.outcome != .allowed && !charactersRead,"browser typing remains blocked before acquisition")
        try typingCategoryChecks(root:root)
        try store.setCaptureState("off",reason:"fixture done")
        for index in 0..<105 {_=try store.ingest(Evidence(id:"page-\(index)",at:iso(now),kind:"window.changed",app:"Notes",title:"Research",synthetic:true))}
        let paged=try await port.prepare(target)
        check(paged.next==100 && paged.actions.count==100,"actual native writer first page bounded at 100")
        let next=try await port.page(paged.id,100)
        check(next.next==nil && next.actionCount==paged.actionCount,"actual native writer completes second durable page")
        check(await port.permitted(paged,paged.actions+next.actions),"complete paged request permitted")
        var newPolicy=try store.policy();newPolicy.blockedApps=["com.apple.Notes"];try store.updatePolicy(newPolicy)
        check(!(await port.permitted(paged,paged.actions+next.actions)),"privacy revision revokes prepared multi-page dispatch")
        try await typedWriterChecks(root:root,now:now,target:target)
        try await sendFactsChecks(root:root,now:now,target:target)
        try await recipientChecks(root:root,target:target)
        try await promptRowChecks(root:root,now:now)
        // Chrome page history: a cloud writer reads a Chrome page only as its cleaned title and host.
        let cloudRoot=root.appendingPathComponent("cloud-scope")
        let cloudStore=try MemoryStore(home:cloudRoot,writable:true,automaticallySyncSearch:false),at=Date()
        var pageProof=BrowserVerification(mode:"normal",windowID:"1520",tabID:"1733",focusedRole:"",checkedAt:isoPrecise(at),provider:BrowserSafety.pageProvider)
        pageProof.policyRevision="policy-fixture"
        // fix/show-all: the page keeps its own link on this Mac (Open Original); no writer, local or cloud, reads it.
        var chromePage=Evidence(id:"chrome-page",at:isoPrecise(at),kind:"window.changed",app:"Google Chrome",bundle:"com.google.Chrome",title:"Orchid pricing",url:"https://shop.example.org",browserVerification:pageProof)
        chromePage.page="https://shop.example.org/orchids/narwhalcart"
        check(try cloudStore.ingest(chromePage) && cloudStore.read("chrome-page")?.evidence.page=="https://shop.example.org/orchids/narwhalcart",
              "page history: a Chrome page row (with its own link) is saved for the adapter fixture")
        _=try cloudStore.ingest(Evidence(id:"notes-row",at:iso(at),kind:"window.changed",app:"Notes",bundle:"com.apple.Notes",title:"Orchid plan",synthetic:true))
        let cloudBinding=CoreWriterBinding(store:cloudStore)
        let cloudDay=WriterTarget(kind:.day,day:String(iso(at).prefix(10)),timezone:"UTC")
        let local=try await cloudBinding.port().prepare(cloudDay)
        check(local.actions.contains{$0.id=="chrome-page"},"page history: the local writer reads Chrome pages")
        check(!"\(local)".contains("narwhalcart"),"show-all: the local writer's request never carries a page's own link")
        try await cloudBinding.port().cancel(local.id)
        // fix/day-card (owner decision, 9/28): a cloud writer reads Chrome pages as their cleaned title and host.
        let cloudPort=cloudBinding.port(audience:.cloud)
        let cloudRequest=try await cloudPort.prepare(cloudDay)
        let cloudPage=cloudRequest.actions.first{$0.id=="chrome-page"}
        check(cloudPage?.title=="Orchid pricing" && cloudPage?.site=="shop.example.org" && cloudRequest.actions.contains{$0.id=="notes-row"},
              "page history: port(audience: .cloud) presents a Chrome page as its cleaned title and host")
        check(cloudRequest.actionCount==2,"page history: the cloud request counts the actions it may read")
        check(!"\(cloudRequest)".contains("narwhalcart") && !"\(cloudRequest)".contains("/orchids"),"show-all: the cloud (OpenRouter) request never carries a page's own link, only its host")
        check(await cloudPort.permitted(cloudRequest,cloudRequest.actions),"page history: the cloud port permits its own request")
        try await cloudPort.cancel(cloudRequest.id)
        let localAgain=try await cloudBinding.port().prepare(cloudDay)
        check(await cloudBinding.port().permitted(localAgain,localAgain.actions),"page history: the local port permits a request with a Chrome page")
        // Review P1: a day correction that covers a Chrome page (its text pre-filled
        // from a local note) never reaches the cloud writer's action descriptions.
        try await cloudBinding.port().cancel(localAgain.id)
        let dayNow=try cloudStore.dayLayers(day:cloudDay.day,timezone:"UTC")
        _=try cloudStore.correctNote(scope:MemoryActionScope(kind:"day",day:cloudDay.day,timezone:"UTC"),text:"Read Orchid pricing on shop.example.org",
                                     expectedRevision:dayNow.summary.inputRevision)
        let localCorrected=try await cloudBinding.port().prepare(cloudDay)
        check(localCorrected.actions.contains{$0.description.contains("Read Orchid pricing on shop.example.org")},"page history: the local writer sees the owner's day correction")
        try await cloudBinding.port().cancel(localCorrected.id)
        let cloudCorrected=try await cloudPort.prepare(cloudDay)
        check(!cloudCorrected.actions.contains{$0.description.contains("Read Orchid pricing on shop.example.org")},
              "page history: a correction that covers a Chrome page never reaches the cloud writer")
        check(await cloudPort.permitted(cloudCorrected,cloudCorrected.actions),"page history: the cloud request without that correction is still permitted")
        print("\(count) actual native adapter checks passed")
    }

    final class Clock:@unchecked Sendable {var now=Date()}
    /// Safe typing E/F in the actual capture binding: category and release
    /// exclusions (deny-only, no CaptureGate change), the typing pause
    /// dropping the unfinished draft, and the indicator agreeing with the gate.
    static func typingCategoryChecks(root:URL) throws {
        let store=try MemoryStore(home:root.appendingPathComponent("typing-categories"),writable:true,automaticallySyncSearch:false)
        var saved=try store.policy();saved.captureText=true;saved.typedConsentVersion=1;try store.updatePolicy(saved)
        try store.setCaptureState("recording",reason:"synthetic fixture")
        try store.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()));try store.setUpTypedVault();try store.acceptSafeTyping()
        let clock=Clock(),binding=CoreCaptureBinding(store:store);binding.wallClock={clock.now}
        let mono:UInt64=20_000_000_000
        func proof(_ bundle:String,field:String="field") throws -> FocusProof {
            let current=try binding.context()
            var p=FocusProof();p.generation=current.generation;p.policyVersion=current.policy.version;p.checkedAt=mono
            p.bundle=bundle;p.windowID="window-"+bundle;p.focusID=field;p.role="AXTextArea"
            p.surface = .native;p.secureInput = .no;p.privateMode = .no
            p.verified=true;p.fieldStateVerified=true;p.frameAccessible=true;p.navigationStable=true
            return p
        }
        func raw(_ words:String) throws -> Bool {try !store.rows("SELECT id FROM records WHERE body LIKE ?",["%"+words+"%"]).isEmpty}
        let c0=try binding.context()
        check(c0.policy.typedText,"categories: typing on with consent, the safe-typing screen and a ready vault")
        let gateExcluded=TypingCategories.excludedBundles(on:TypedCategoryChoices().isOn)
        check(c0.policy.excludedApps.isSuperset(of:gateExcluded) && c0.policy.excludedApps.isSuperset(of:PrivacySettings.sensitiveApps),"categories: every table app the release gate doesn't allow joins the excluded apps; the sensitive list is kept")
        check(!c0.policy.excludedApps.contains("com.apple.Notes") && !c0.policy.excludedApps.contains("com.apple.TextEdit"),"categories: Notes and TextEdit stay allowed (Writing on)")
        check(!c0.policy.excludedApps.contains(where:CaptureGate.isBrowser),"categories: no browser is excluded by typing categories (browser metadata unaffected)")
        // The release gate, before any character is read. Terminal and Claude are closed only in a narrow
        // (unflagged) build; the release compiles the owner typing flags and opens them through their category.
        let narrowOnly=["com.apple.Terminal","com.anthropic.claudefordesktop"]
        if OwnerTyping.enabled {
            check(narrowOnly.allSatisfy { !c0.policy.excludedApps.contains($0) && CaptureGate.nativeApps.contains($0) },"categories: release build: Terminal and Claude are not excluded (Code and Search on)")
        }
        for bundle in ["com.tinyspeck.slackmacgap","com.apple.systempreferences","com.googlecode.iterm2"] + (OwnerTyping.enabled ? [] : narrowOnly) {
            var read=false
            let decision=try binding.append(proof:proof(bundle),now:mono,readCharacters:{read=true;return "must not read"})
            check(decision.reason == .excludedApp && !read,"categories: \(bundle) typing is refused as excluded before any character is read")
        }
        // Notes is allowed and saves.
        let notes=try proof("com.apple.Notes")
        check(try binding.append(proof:notes,now:mono,readCharacters:{"weekly plan draft"}).outcome == .allowed,"categories: Notes typing is allowed")
        check(try binding.commitText(id:"cat-notes",proof:notes,now:mono) && store.hydrateTypedText("cat-notes",disclosure:.owner)=="weekly plan draft","categories: a Notes draft saves (sealed)")
        // Review G31: the typed row names the app the way people see it ("Typed in Notes"), never by its bundle ID,
        // in the stored row, its summary and the reader line; a row saved before the fix reads the same.
        if let item=try store.read("cat-notes"),let reader=try store.readerItem("cat-notes") {
            check(item.evidence.app == "Notes" && item.evidence.bundle == "com.apple.Notes" && !item.summary.contains("com.apple")
                  && reader.summary.hasPrefix("Typed in Notes,"),"categories (G31): the typed row says Notes, not com.apple.Notes (\(item.evidence.app); \(reader.summary))")
            var earlier=item.evidence;earlier.app="com.apple.Notes"
            check(MemoryStore.typedReaderLine(earlier,status:nil).hasPrefix("Typed in Notes,"),"categories (G31): a row saved with the bundle ID as its app still reads Typed in Notes")
        } else {check(false,"categories (G31): the Notes row reads back")}
        // Writing off: a policy boundary that drops the unfinished draft; Notes is then excluded.
        let before=try proof("com.apple.Notes",field:"second")
        _=try binding.append(proof:before,now:mono,readCharacters:{"unsaved writing words"})
        check(binding.hasPendingTyping,"categories: an unfinished draft is pending")
        try store.setTypingCategory(.writing,on:false)
        let c1=try binding.context()
        check(c1.policy.version != c0.policy.version && c1.policy.excludedApps.isSuperset(of:["com.apple.Notes","com.apple.TextEdit"]),"categories: Writing off excludes Notes and TextEdit and is a policy boundary")
        check(try !binding.hasPendingTyping && !(binding.commitText(id:"cat-writing-off",proof:proof("com.apple.Notes",field:"second"),now:mono)) && !(raw("unsaved writing words")) && store.read("cat-writing-off")==nil,"categories: turning Writing off drops the unfinished draft, never saved")
        var readOff=false
        check(try binding.append(proof:proof("com.apple.Notes"),now:mono,readCharacters:{readOff=true;return "x"}).reason == .excludedApp && !readOff,"categories: with Writing off no Notes character is read")
        try store.setTypingCategory(.writing,on:true)
        check(try !(binding.context()).policy.excludedApps.contains("com.apple.Notes"),"categories: Writing on again allows Notes")
        try store.setTypingCategory(.messagesAndEmail,on:true)
        check(try (binding.context()).policy.excludedApps.contains("com.tinyspeck.slackmacgap"),"categories: Messages on does not open Slack while the release gate is closed")
        try store.setTypingCategory(.messagesAndEmail,on:false)
        // A retention change is not a capture boundary: the live draft is kept.
        let steady=try binding.context().policy.version
        _=try binding.append(proof:proof("com.apple.Notes",field:"third"),now:mono,readCharacters:{"kept across retention"})
        var longer=try store.typedTextPolicy();longer.retention = .days30;try store.updateTypedTextPolicy(longer)
        check(try binding.context().policy.version==steady && binding.hasPendingTyping,"categories: changing how long words are kept doesn't drop the unfinished draft")
        check(try binding.commitText(id:"cat-kept",proof:proof("com.apple.Notes",field:"third"),now:mono),"categories: that draft still saves")
        // The typing pause: typing off, the unfinished draft dropped, stored, ends on time.
        _=try binding.append(proof:proof("com.apple.Notes",field:"fourth"),now:mono,readCharacters:{"draft before the pause"})
        let until=try binding.snoozeTyping()
        check(abs(until.timeIntervalSince(clock.now)-600)<1,"pause: ten minutes from the shortcut")
        let paused=try binding.context()
        check(!paused.policy.typedText && !binding.hasPendingTyping,"pause: typing is off and the unfinished draft is dropped")
        check(try !(binding.commitText(id:"cat-paused",proof:proof("com.apple.Notes",field:"fourth"),now:mono)) && !(raw("draft before the pause")) && store.read("cat-paused")==nil,"pause: the dropped draft is never saved")
        var readPaused=false
        let pausedDecision=try binding.append(proof:proof("com.apple.Notes"),now:mono,readCharacters:{readPaused=true;return "x"})
        check(pausedDecision.reason == .typingOff && !readPaused,"pause: no character is read while paused")
        check(try binding.snoozeTyping()==until,"pause: the shortcut again does not extend it")
        check(try store.typingIndicator(frontmostBundle:"com.apple.Notes",now:clock.now) == .snoozed(until:timestamp(iso(until))),"pause: the indicator shows the pause")
        let relaunched=CoreCaptureBinding(store:store);relaunched.wallClock={clock.now}
        check(try !(relaunched.context()).policy.typedText,"pause: a new binding (relaunch) keeps typing paused")
        clock.now=clock.now.addingTimeInterval(601)
        check(try binding.context().policy.typedText && relaunched.context().policy.typedText,"pause: typing records again when the ten minutes end")
        clock.now=Date()
        _=try binding.snoozeTyping();check(!(try binding.context()).policy.typedText,"pause again")
        try binding.resumeTyping()
        check(try binding.context().policy.typedText,"pause: \"Record typing again\" turns typing back on at once")
        // The dot agrees with the gate: recording exactly where typing can be read.
        let live=try binding.context()
        var agreed=0
        for bundle in TypingCategories.apps.map(\.bundle)+["com.example.Unknown","com.google.Chrome","com.apple.Passwords"] {
            let dot=try store.typingIndicator(frontmostBundle:bundle).showsDot
            let gate=live.policy.typedText && !live.policy.excludedApps.contains(bundle) && CaptureGate.nativeApps.contains(bundle)
            precondition(dot==gate,"indicator and gate disagree for \(bundle)");agreed+=1
        }
        check(agreed>20,"indicator: the dot shows exactly where the binding lets typing be read (\(agreed) apps)")
        try store.setCaptureState("off",reason:"fixture done")
    }

    /// fix/r1-writer: a name typed in Mail's To field (`unit.to` of an email unit) follows the typed words: sealed beside
    /// them and never written to the record in plain text, gone when they expire, with Forget what I typed and with a
    /// range Forget, never in a backup, and read only by a writer the typed-words disclosure allows while they are kept.
    /// fix/prompt-row: the timeline opening an AI ask for its row (`ownerMomentPrompts`) changes nothing a writer reads:
    /// the cloud request (OpenRouter) and the local one are the same text before and after, and with This Mac only chosen
    /// the cloud request carries none of the ask's words, before or after.
    static func promptRowChecks(root:URL,now:Date) async throws {
        let home=root.appendingPathComponent("prompt-row")
        let store=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false)
        var policy=try store.policy();policy.captureText=true;policy.typedConsentVersion=1;try store.updatePolicy(policy)
        try store.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()));try store.setUpTypedVault();try store.acceptSafeTyping()
        let words="how do I fix the export crash quokkaask in the build"
        // Public builds type in Notes and TextEdit only: the ask carries Notes' bundle with the AI send facts.
        var ask=Evidence(id:"prompt-ask",at:iso(now.addingTimeInterval(-2)),kind:"keyboard.text_input",app:"Notes",bundle:"com.apple.Notes",title:"ChatGPT",text:words,synthetic:true)
        var unit=TypedUnitProvenance(runID:"run-ask",part:1,sealReason:"submit",startedAt:iso(now.addingTimeInterval(-9)),keys:40,edits:0,withheld:0)
        unit.surface="ai";unit.send="detected";unit.version=TypedUnitProvenance.sendFactsVersion
        ask.captureProvenance=NativeCaptureProvenance(policyRevision:"r",classifierVersion:"sensitive-typing/v2+typed-scrub/v1",windowID:"w",focusID:"f",checkedAt:iso(now),generation:1,unit:unit)
        check(try store.ingest(Evidence(id:"prompt-window",at:iso(now.addingTimeInterval(-3)),kind:"window.changed",app:"Notes",bundle:"com.apple.Notes",title:"ChatGPT",synthetic:true))
              && store.ingest(ask),"prompt-row: fixture: an AI ask and its window")
        let target=WriterTarget(kind:.day,day:String(iso(now).prefix(10)),timezone:"UTC")
        let binding=CoreWriterBinding(store:store,typedWriter:.local)
        func views() async throws -> (cloud:String,local:String) {
            let cloud=try await typedView(binding.port(audience:.cloud),target),local=try await typedView(binding.port(),target)
            try await binding.port(audience:.cloud).cancel(cloud.request.id);try await binding.port().cancel(local.request.id)
            return (cloud.text,local.text)
        }
        func leaks(_ text:String) -> Bool {text.contains("quokkaask") || text.contains("export crash")}
        try store.setSummaryWriter("local")
        let before=try await views()
        let request=MomentPromptRequest(momentID:"m",actionIDs:["prompt-window","prompt-ask"],primaryBundle:"com.apple.Notes",site:nil)
        let opened=try store.ownerMomentPrompts(try store.momentPromptRows([request]))
        check(opened["m"]==words,"prompt-row: control: the app opens the ask for its row")
        let after=try await views()
        check(!leaks(before.cloud) && !leaks(after.cloud),"prompt-row: This Mac only: the cloud (OpenRouter) request carries no word of the ask, before or after the row opened it")
        check(before.cloud==after.cloud && before.local==after.local,"prompt-row: the cloud and local writer requests are the same text before and after the row opened the ask")
        // Cloud chosen (owner 9/27: the cloud reads typed words under ZDR): what it reads doesn't change either.
        try store.setSummaryWriter("cloud")
        let cloudBefore=try await views().cloud
        _=try store.ownerMomentPrompts(try store.momentPromptRows([request]))
        check(try await views().cloud==cloudBefore,"prompt-row: Cloud chosen: the cloud request is the same text before and after the row opened the ask")
        // fix/show-all: the moment's detail opening every typed word of the moment changes nothing a writer reads either.
        for writer in ["local","cloud"] {
            try store.setSummaryWriter(writer)
            let shownBefore=try await views()
            let blocks=try store.ownerMomentTyped(try store.momentTypedRows(["prompt-window","prompt-ask"]))
            check(blocks.first?.text==words,"show-all: control: the detail opens the moment's typed words (\(writer))")
            let shownAfter=try await views()
            check(shownBefore.cloud==shownAfter.cloud && shownBefore.local==shownAfter.local,
                  "show-all: \(writer) chosen: the cloud and local writer requests are the same text before and after the detail opened the typed words")
            if writer == "local" { check(!leaks(shownAfter.cloud),"show-all: This Mac only: the cloud request carries no typed word after the detail opened them") }
        }
        try store.setSummaryWriter("off")
    }
    static func recipientChecks(root:URL,target:WriterTarget) async throws {
        func mailStore(_ name:String) throws -> MemoryStore {
            let store=try MemoryStore(home:root.appendingPathComponent("recipient-"+name),writable:true,automaticallySyncSearch:false)
            var policy=try store.policy();policy.captureText=true;try store.updatePolicy(policy)
            try store.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()));try store.setUpTypedVault();try store.acceptSafeTyping()
            let at=Date()
            var mail=Evidence(id:"to-mail",at:iso(at.addingTimeInterval(-5)),kind:"keyboard.text_input",app:"Mail",bundle:"com.apple.Notes",title:"Budget",
                              text:"The budget is attached, see page two",synthetic:true)
            mail.captureProvenance=NativeCaptureProvenance(policyRevision:"p",classifierVersion:"c",windowID:"w",focusID:"f",checkedAt:iso(at),generation:1,
                unit:TypedUnitProvenance(runID:"run-to",part:1,sealReason:"mailSend",startedAt:iso(at),keys:nil,edits:nil,withheld:0,surface:"email",send:"detected",sendBy:"mailSend",to:"Priya Shah"))
            check(try store.ingest(mail),"fix/r1-writer fixture: the Mail unit with a typed recipient is saved (\(name))")
            return store
        }
        func plainOnDisk(_ store:MemoryStore) -> Bool {
            let files=["memory.sqlite","memory.sqlite-wal"].compactMap {try? Data(contentsOf:store.home.appendingPathComponent($0))}
            return files.contains {$0.range(of:Data("Priya Shah".utf8)) != nil}
        }
        // Kept while the words are: the writer on this Mac reads it; nobody else does; the cloud only with cloud on.
        let store=try mailStore("kept")
        check(try !plainOnDisk(store) && (store.typedUnit("to-mail"))?.to == nil && (store.typedRecipientCount()) == 1,
              "fix/r1-writer the typed Mail recipient is sealed with the words: not in the record in plain text, not read without a writer")
        check(try (store.typedUnit("to-mail",disclosure:.localWriter))?.to == "Priya Shah","fix/r1-writer the writer on this Mac reads the recipient while the words are kept")
        let request=try await CoreWriterBinding(store:store,typedWriter:.local).port().prepare(target)
        check(request.actions.first {$0.id=="to-mail"}?.to == "Priya Shah","fix/r1-writer the send line still names the recipient (Emailed Priya Shah ...) within typed retention")
        check(try (store.typedUnit("to-mail",disclosure:.cloudWriter))?.to == nil,"fix/r1-writer the cloud writer doesn't get the recipient while cloud summaries are off")
        try store.setSummaryWriter("cloud")
        check(try (store.typedUnit("to-mail",disclosure:.cloudWriter))?.to == "Priya Shah","fix/r1-writer the cloud writer gets the recipient only with cloud and typing on")
        var off=try store.policy();off.captureText=false;try store.updatePolicy(off)
        check(try (store.typedUnit("to-mail",disclosure:.cloudWriter))?.to == nil && (store.typedUnit("to-mail",disclosure:.localWriter))?.to == nil,
              "fix/r1-writer with typing off no writer gets the recipient")
        var on=try store.policy();on.captureText=true;try store.updatePolicy(on)
        // Never in a backup.
        let copy=try MemoryStore(home:root.appendingPathComponent("recipient-backup"),writable:true,automaticallySyncSearch:false)
        _=try store.exportCanonicalSnapshot(to:copy,now:Date())
        check(try (copy.typedRecipientCount()) == 0 && !plainOnDisk(copy) && (copy.typedUnit("to-mail",disclosure:.owner))?.to == nil,
              "fix/r1-writer a backup holds no typed recipient, as it holds no typed words")
        // Expires with the words.
        let report=try store.expireTypedText(now:Date().addingTimeInterval(8*86400))
        check(try report.expired == 1 && (store.typedRecipientCount()) == 0 && (store.typedUnit("to-mail",disclosure:.localWriter))?.to == nil,
              "fix/r1-writer the recipient is deleted when the typed words expire")
        // Forget what I typed.
        let forget=try mailStore("forget")
        _=try forget.forgetTypedText(confirmed:true)
        check(try (forget.typedRecipientCount()) == 0 && !plainOnDisk(forget),"fix/r1-writer Forget what I typed deletes the recipient")
        // Forget a time range.
        let range=try mailStore("range")
        let zone=TimeZone.current.identifier
        let preview=try range.prepareDeletion(scope:.range(start:Date().addingTimeInterval(-600),end:Date().addingTimeInterval(60),timezone:zone))
        _=try range.executeDeletion(previewID:preview.id,confirmed:true)
        check(try (range.typedRecipientCount()) == 0 && !plainOnDisk(range),"fix/r1-writer Forget a time range deletes the recipient")
    }

    /// summaries/v3: the binding hands the writer the seal's send facts (metadata, never words) and up to 1,600 typed
    /// characters; the view turns them into surfaces, "sent with ..." endings, leads and recipients; N7 salvages a note
    /// core refuses for copying typed words. Synthetic store, in-memory keys.
    static func sendFactsChecks(root:URL,now:Date,target:WriterTarget) async throws {
        let factsRoot=root.appendingPathComponent("send-facts")
        let store=try MemoryStore(home:factsRoot,writable:true,automaticallySyncSearch:false)
        var policy=try store.policy();policy.captureText=true;try store.updatePolicy(policy)
        try store.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()));try store.setUpTypedVault();try store.acceptSafeTyping()
        // Public builds type only in Notes and TextEdit: the rows are Notes rows named as Mail and Claude; the facts are what matter.
        let long=(1...260).map {"word\($0)"}.joined(separator:" ")   // about 2,000 characters
        func unit(_ run:String,_ surface:String,_ send:String,_ sendBy:String?,_ to:String?) -> NativeCaptureProvenance {
            NativeCaptureProvenance(policyRevision:"p",classifierVersion:"c",windowID:"w",focusID:"f",checkedAt:iso(now),generation:1,
                unit:TypedUnitProvenance(runID:run,part:1,sealReason:"submit",startedAt:iso(now),keys:nil,edits:nil,withheld:0,surface:surface,send:send,sendBy:sendBy,to:to))
        }
        var mail=Evidence(id:"facts-mail",at:iso(now.addingTimeInterval(-5)),kind:"keyboard.text_input",app:"Mail",bundle:"com.apple.Notes",title:"Friday meeting",
                          text:"Hi Sam, can we move the Friday meeting to 3pm? Thanks",synthetic:true)
        mail.captureProvenance=unit("run-mail","email","detected","mailSend","Sam")
        var claude=Evidence(id:"facts-claude",at:iso(now.addingTimeInterval(-4)),kind:"keyboard.text_input",app:"Claude",bundle:"com.apple.Notes",title:"Claude",
                            text:long,synthetic:true)
        claude.captureProvenance=unit("run-claude","ai","unknown",nil,nil)
        let saved1=try store.ingest(mail),saved2=try store.ingest(claude)
        check(saved1 && saved2,"fixture: the typed rows with send facts are saved (\(saved1) \(saved2))")
        let port=CoreWriterBinding(store:store,typedWriter:.local).port()
        let request=try await port.prepare(target)
        let m=request.actions.first {$0.id=="facts-mail"},c=request.actions.first {$0.id=="facts-claude"}
        check(m?.surface=="email" && m?.send=="detected" && m?.sendBy=="mailSend" && m?.to=="Sam" && m?.runID=="run-mail" && c?.surface=="ai" && c?.send=="unknown",
              "summaries/v3 facts: the binding passes the seal's surface, send, sendBy, to and runID into the writer's actions")
        check(c.map {$0.description.hasPrefix("Typed a draft in Claude. word1 ") && $0.description.count==("Typed a draft in Claude. ").count+1600}==true,
              "summaries/v3 1,600: a long draft reaches the writer on this Mac cut at 1,600 characters, not 240")
        check(await port.permitted(request,request.actions),"summaries/v3 facts: permitted accepts the presentation with its facts")
        var forged=request.actions;if let i=forged.firstIndex(where:{$0.id=="facts-claude"}) {forged[i].send="detected"}
        check(!(await port.permitted(request,forged)),"summaries/v3 facts: a request whose send facts were changed is not permitted")
        let view=try ModelView(request:request,actions:request.actions)
        check(view.text.contains("Mail (email): typed \"Hi Sam, can we move the Friday meeting to 3pm? Thanks\" to \"Sam\" in \"Friday meeting\"; sent with Command-Shift-D. Start with: Emailed")
              && view.text.contains("Claude (AI app): typed \"word1 word2") && view.text.contains("; sending unknown"),"summaries/v3 view: surfaces, the send ending and the lead come from the facts\n\(view.text)")
        let alias=view.items.first {$0.actions.contains {$0.id=="facts-mail"}}!.alias,claudeAlias=view.items.first {$0.actions.contains {$0.id=="facts-claude"}}!.alias
        func answer(_ mailLine:String,_ claudeLine:String) -> String {
            String(decoding:try! JSONSerialization.data(withJSONObject:["title":"Friday meeting","bullets":[["ids":[alias],"text":mailLine],["ids":[claudeAlias],"text":claudeLine]]]),as:UTF8.self)
        }
        let good=try CanonicalGrounding.validate(answer("Emailed Sam about moving the Friday meeting later.","Wrote a long list of numbered words to Claude."),request:request,view:view,provider:CanonicalLocalWriter.provider)
        check(good.bullets.first {$0.actionIDs==["facts-mail"]}?.text.hasPrefix("Emailed Sam")==true,"summaries/v3 verbs: a detected email send may start with Emailed and name the read recipient")
        func refusal(_ mailLine:String,_ claudeLine:String) -> String? {
            do {_=try CanonicalGrounding.validate(answer(mailLine,claudeLine),request:request,view:view,provider:CanonicalLocalWriter.provider);return nil}
            catch let r as WriterRejection {return r.code} catch {return "error"}
        }
        let codes=[refusal("Emailed Priya about moving the Friday meeting.","Wrote to Claude."),refusal("Texted Sam about the meeting.","Wrote to Claude."),
                   refusal("Drafted an email to Sam about Friday.","Asked Claude for a list of words.")]
        check(codes==["name","send","lead"],
              "summaries/v3 verbs: a recipient not read, a lead from another surface, or Asked for a send DayDream couldn't see are refused (\(codes))")
        // core: Emailed needs every cited typed row to be "submitted". Capture seals a detected send "submitted" (the mail
        // row) and anything else "draft" (the Claude row, sending unknown); an Emailed line on the draft is refused.
        check(try store.action("facts-mail")?.state=="submitted" && store.action("facts-claude")?.state=="draft",
              "summaries/v3 core: a detected send is sealed submitted, an unknown one stays a draft")
        var forgedNote=good
        if let i=forgedNote.bullets.firstIndex(where:{$0.actionIDs==["facts-claude"]}) {forgedNote.bullets[i].text="Emailed Claude a long list of numbered words."}
        var coreRefusal=""
        do {_=try await port.commit(forgedNote)} catch {coreRefusal=String(describing:error)}
        check(coreRefusal.contains("Send claim lacks a detected send"),"summaries/v3 core: \"Emailed\" is refused unless every typed row it cites was sealed with a detected send (state submitted)")
        // N7: a note core refuses for copying typed words is committed once more with code-written lines about the
        // typing (one model run, no scheduler retry). The refusal is simulated; everything else is the real store.
        let once=RefuseOnce()
        let wrapped=CoreWriterPort(prepare:port.prepare,page:port.page,commit:{output in
            if await once.first() {throw MemError.invalid("A note may not copy what the person typed: at most 5 words in a row, fewer for short drafts, and never a whole short draft.")}
            return try await port.commit(output)
        },cancel:port.cancel,permitted:port.permitted)
        let adapter=CoreWriterAdapter(core:wrapped,generate:{request,actions in
            let v=try ModelView(request:request,actions:actions)
            let a=v.items.first {$0.actions.contains {$0.id=="facts-mail"}}!.alias,b=v.items.first {$0.actions.contains {$0.id=="facts-claude"}}!.alias
            return try CanonicalGrounding.validate(String(decoding:try JSONSerialization.data(withJSONObject:["title":"Friday meeting","bullets":[
                // fix/summary-fallback: the mail row was sealed with its send key, so its line says Emailed ("Drafted" over a
                // send is now refused).
                ["ids":[a],"text":"Emailed Sam about the Friday meeting."],["ids":[b],"text":"Wrote a long list of numbered words to Claude."]]]),as:UTF8.self),
                request:request,view:v,provider:CanonicalLocalWriter.provider)
        })
        let result=try await adapter.process(target,lastActivity:now.addingTimeInterval(-3))
        guard case .committed(let saved)=result else {fatalError("N7: not committed: \(result)")}
        let commits=await once.calls
        // The owner build reads the Mail subject too, so its line may say what about ("Emailed Sam about Friday meeting.").
        let n7=saved.output.bullets.map(\.text).sorted()
        check(n7.count==2 && n7[0]=="Drafted a message to Claude." && ["Emailed Sam.","Emailed Sam about Friday meeting."].contains(n7[1]) && commits==2,
              "summaries/v3 N7: after a copy refusal the adapter commits the note once more with code-written typing lines (\(saved.output.bullets.map(\.text)))")
    }
    static func typedLeaks(_ text:String) -> Bool {text.contains("quokkamarmalade") || text.contains("garden party")}
    static func typedView(_ port:CoreWriterPort,_ target:WriterTarget) async throws -> (request:CanonicalNoteRequest,text:String,typed:NoteAction?) {
        let request=try await port.prepare(target)
        return (request,try ModelView(request:request,actions:request.actions).text,request.actions.first { $0.kind == "keyboard.text_input" })
    }
    static func typedOutput(_ requestID:String,_ text:String) throws -> CanonicalNoteOutput {
        try JSONDecoder().decode(CanonicalNoteOutput.self,from:JSONSerialization.data(withJSONObject:["requestID":requestID,"title":"Party planning","generator":"fixture","generatorVersion":"1",
            "bullets":[["text":text,"actionIDs":["typed-writer-1"],"assertion":"draft"],["text":"Had a Pricing note open in Notes.","actionIDs":["typed-writer-window"],"assertion":"observed"]]]))
    }
    /// writer/v2 (owner decision 2026-09-26): what each writer's model reads of typed text. Summaries on this Mac
    /// (the app binds them with `typedWriter: .local`, WriterIntegration.makeCoreBinding) read the saved words while
    /// typing is on: switch on, safe-typing consent, key ready. The saved "Let summaries read what you type" value
    /// is ignored. Cloud summaries get the words only while Cloud is the chosen writer (summaries/v3), and AI apps
    /// (MCP/CLI reads) only ever get the short note. Synthetic stores, in-memory keys.
    static func typedWriterChecks(root:URL,now:Date,target:WriterTarget) async throws {
        let typedRoot=root.appendingPathComponent("typed-writer")
        let typedStore=try MemoryStore(home:typedRoot,writable:true,automaticallySyncSearch:false)
        var typedPolicy=try typedStore.policy();typedPolicy.captureText=true;try typedStore.updatePolicy(typedPolicy)
        let writerKeys=InMemoryTypedKeyStore();try typedStore.attachVault(TypedTextVault(keyStore:writerKeys));try typedStore.setUpTypedVault();try typedStore.acceptSafeTyping()
        let draftWords="garden party menu ideas quokkamarmalade"
        _=try typedStore.ingest(Evidence(id:"typed-writer-1",at:iso(now.addingTimeInterval(-2)),kind:"keyboard.text_input",app:"Notes",bundle:"com.apple.Notes",title:"Pricing",text:draftWords,synthetic:true))
        _=try typedStore.ingest(Evidence(id:"typed-writer-window",at:iso(now.addingTimeInterval(-3)),kind:"window.changed",app:"Notes",bundle:"com.apple.Notes",title:"Pricing",synthetic:true))
        check(try typedStore.typedTextPolicy().shareWithSummaries == .off && typedStore.typedTextPolicy().consented,"fixture: typing on, the saved sharing value is the old default Off")
        // The app's binding: one CoreWriterBinding made for the writer on this Mac serves both ports.
        let localBinding=CoreWriterBinding(store:typedStore,typedWriter:.local)
        // 1. Local port: the words are in the presentation and permitted.
        let localPort=localBinding.port()
        let local=try await typedView(localPort,target)
        check(local.typed?.description == "Typed a draft in Notes. "+draftWords && local.text.contains("quokkamarmalade"),"writer/v2 local-typed-words: typing on, the local port's presentation carries the draft words (Off picker value ignored)")
        check(local.typed?.title == "Pricing","writer/v2 local-typed-words: the local writer keeps the typed row's window title")
        check(await localPort.permitted(local.request,local.request.actions),"writer/v2 local-typed-words: permitted accepts the local presentation with the words")
        check(try typedStore.rows("SELECT id FROM note_requests WHERE body LIKE '%quokkamarmalade%'").isEmpty && typedStore.rows("SELECT id FROM records WHERE body LIKE '%quokkamarmalade%'").isEmpty,
              "writer/v2 local-typed-words: the words are never written to note requests or records")
        // 2. Cloud port of the same .local binding: no words, no typed row title; a request carrying words is refused.
        let cloudPort=localBinding.port(audience:.cloud)
        let cloud=try await typedView(cloudPort,target)
        check(!typedLeaks(cloud.text) && !cloud.request.actions.contains { typedLeaks($0.description) || typedLeaks($0.title) } && cloud.typed?.description == "Typed a draft in Notes (a sentence).",
              "writer/v2 cloud-no-typed-words: the cloud port of a .local binding presents no words (\(cloud.typed?.description ?? "none"))")
        check(cloud.typed?.title == "Pricing","summaries/v3 C5: the cloud writer keeps the typed row's window title (the words still follow the typed-words disclosure)")
        check(await cloudPort.permitted(cloud.request,cloud.request.actions),"writer/v2 cloud-no-typed-words: control: the cloud port permits its own word-free request")
        var carrying=cloud.request.actions
        if let at=carrying.firstIndex(where:{ $0.kind == "keyboard.text_input" }) {carrying[at].description="Typed a draft in Notes. "+draftWords;carrying[at].title="Pricing"}
        check(!(await cloudPort.permitted(cloud.request,carrying)),"writer/v2 cloud-no-typed-words: a cloud request carrying the words is not permitted")
        check(!(await cloudPort.permitted(local.request,local.request.actions)),"writer/v2 cloud-no-typed-words: the cloud port refuses the local presentation with the words")
        let unknownKind=try await typedView(CoreWriterBinding(store:typedStore).port(),target)
        check(unknownKind.request.actions.allSatisfy { !typedLeaks($0.description) },"writer/v2 cloud-no-typed-words: a binding of unknown kind counts as cloud")
        // Old saved values: This Mac only, and a signed This Mac and cloud row, never give the cloud the words.
        var share=try typedStore.typedTextPolicy();share.shareWithSummaries = .localOnly;try typedStore.updateTypedTextPolicy(share)
        let oldCloud=try await typedView(cloudPort,target).text,oldLocal=try await typedView(localPort,target).text
        check(!typedLeaks(oldCloud) && oldLocal.contains("quokkamarmalade"),"writer/v2 cloud-no-typed-words: an old This Mac only value changes nothing")
        share.shareWithSummaries = .localAndCloud
        let cloudSaved=(try? typedStore.updateTypedTextPolicy(share,confirmed:true)) != nil
        let sharingAfter=try typedStore.typedTextPolicy().shareWithSummaries
        check(!cloudSaved && sharingAfter == .localOnly,"writer/v2: saving This Mac and cloud is still refused, even confirmed")
        var forged=try typedStore.typedTextPolicy();forged.shareWithSummaries = .localAndCloud
        try typedStore.transaction {try typedStore.saveTypedTextPolicyWithinTransaction(forged)}
        check(try typedStore.typedTextPolicyVerified() && typedStore.typedTextPolicy().shareWithSummaries == .localAndCloud,"fixture: a signed localAndCloud row")
        let forgedCloud=try await typedView(cloudPort,target).text,forgedLocal=try await typedView(localPort,target).text
        check(!typedLeaks(forgedCloud) && forgedLocal.contains("quokkamarmalade"),"writer/v2 cloud-no-typed-words: a signed This Mac and cloud row gives the cloud writer no words (the local writer reads as with any value)")
        // summaries/v3 (K7; owner 2026-09-27, decision 8 reversed): with Cloud the chosen writer (the app saves "cloud" only
        // after the v2 notice) and typing on, the cloud port reads the words and permits its own request; back off, none.
        try typedStore.setSummaryWriter("cloud")
        let chosen=try await typedView(cloudPort,target)
        let chosenPermitted=await cloudPort.permitted(chosen.request,chosen.request.actions)
        check(chosen.text.contains("quokkamarmalade") && chosenPermitted,
              "summaries/v3 cloud-typed-words: Cloud chosen, typing on: the cloud port presents the words and permits its request")
        try typedStore.setSummaryWriter("local")
        let localChosen=try await typedView(cloudPort,target).text
        check(!typedLeaks(localChosen),"summaries/v3 cloud-typed-words: This Mac only: the cloud port gets no words")
        try typedStore.setSummaryWriter("off")
        share.shareWithSummaries = .off;try typedStore.updateTypedTextPolicy(share)
        // 3. Typing off, a locked Keychain, no safe-typing consent, or no key in the process: the local port gets no words.
        let before=try await typedView(localPort,target)
        typedPolicy.captureText=false;try typedStore.updatePolicy(typedPolicy)
        check(!(await localPort.permitted(before.request,before.request.actions)),"writer/v2 local-no-words-when-off: switching typing off revokes a prepared request that holds the words")
        let seen1=try await typedView(localPort,target).text
        check(!typedLeaks(seen1),"writer/v2 local-no-words-when-off: typing switched off, the local port gets no words")
        typedPolicy.captureText=true;try typedStore.updatePolicy(typedPolicy)
        let seen2=try await typedView(localPort,target).text
        check(seen2.contains("quokkamarmalade"),"writer/v2: control: typing on again, the local port reads again")
        writerKeys.locked=true;_=try typedStore.reconcileTypedVault()
        let seen3=try await typedView(localPort,target).text
        check(!typedLeaks(seen3),"writer/v2 local-no-words-when-off: a locked Keychain (vault not ready) gives the local port no words")
        writerKeys.locked=false;_=try typedStore.reconcileTypedVault()
        let signedRow=try typedStore.rows("SELECT body FROM metadata WHERE id=?",[MemoryStore.typedPolicyMACID]).first?.first ?? ""
        try typedStore.exec("DELETE FROM metadata WHERE id=?",[MemoryStore.typedPolicyMACID])
        check(try !typedStore.typedTextPolicy().consented,"fixture: a typing row changed outside the app reads as no safe-typing consent")
        let seen4=try await typedView(localPort,target).text
        check(!typedLeaks(seen4),"writer/v2 local-no-words-when-off: without the safe-typing consent the local port gets no words")
        try typedStore.exec("INSERT OR REPLACE INTO metadata VALUES(?,?)",[MemoryStore.typedPolicyMACID,signedRow])
        let seen5=try await typedView(localPort,target).text
        check(seen5.contains("quokkamarmalade"),"writer/v2: control: the signed row back, the local port reads again")
        let keyless=try MemoryStore(home:typedRoot,writable:true,automaticallySyncSearch:false)
        let keylessView=try await typedView(CoreWriterBinding(store:keyless,typedWriter:.local).port(),target)
        check(!typedLeaks(keylessView.request.actions.map(\.description).joined()),"writer/v2 local-no-words-when-off: a process without the key never adds words")
        // 4. Verbatim guard at commit, through the local port: a note may not copy the draft; a paraphrase commits.
        let committing=try await typedView(localPort,target)
        let copying=try typedOutput(committing.request.id,"Wrote garden party menu ideas quokkamarmalade in Notes.")
        var refusal="committed"
        do {_=try await localPort.commit(copying)} catch {refusal="\(error)"}
        check(refusal.contains("may not copy"),"writer/v2 verbatim-guard: a local note that copies the draft is refused at commit")
        let paraphrase=try typedOutput(committing.request.id,"Planned the food for an outdoor get-together.")
        let receipt=try await localPort.commit(paraphrase)
        check(receipt.output.bullets.count == 2,"writer/v2 verbatim-guard: control: a paraphrase of the draft commits")
        // 5. What AI apps see (MCP/CLI reads, with a normal grant, in this process and in a keyless one): never the words.
        let token=try typedStore.grant(client:"claude-code",recipient:"local",scopes:["context","search","detail"])
        let reader=TypedReader(client:"claude-code",recipient:"local",capability:token)
        check(try typedStore.typedDisclosure(for:reader) == .summary && keyless.typedDisclosure(for:reader) == .summary,"writer/v2 ai-apps-no-typed-words: a normal grant discloses only the summary")
        for (name,reading) in [("app process",typedStore),("MCP process (no key)",keyless)] {
            let item=try reading.assistantItem("typed-writer-1",now:now,reader:reader)
            let surfaces=[try json(item ?? [:]),try json(reading.readerItem("typed-writer-1",now:now)),
                          try json(reading.searchReport(MemorySearchQuery("quokkamarmalade")).hits),try json(reading.searchReport(MemorySearchQuery("",app:"com.apple.Notes")).hits),
                          try reading.assistantContext(now:now),try reading.openActionResource("macmem://days/today.json?timezone=UTC",now:now,assistant:true)]
            check(item?["snippet"]?.hasPrefix("Typed in Notes") == true && !surfaces.contains(where:typedLeaks),
                  "writer/v2 ai-apps-no-typed-words: \(name): read, search, context and the day page never contain the words")
        }
        // claude/summary-1003 (owner decision 2026-10-03): the one intended path for the words is the app's bridge
        // (`assistantTypedWords`, served to `moment_details`/`search`), gated by "Let AI apps read what you typed". The
        // surfaces above stay word-free; the bridge gives nothing with the setting off, nor in a keyless process.
        let offWords=(try? typedStore.assistantTypedWords(["typed-writer-1"],reader:reader,enabled:false,now:now)) ?? [:]
        let keylessWords=(try? keyless.assistantTypedWords(["typed-writer-1"],reader:reader,enabled:true,now:now)) ?? [:]
        check(offWords.isEmpty && keylessWords.isEmpty,"owner decision 2026-10-03: the gated typed-read path gives no words with the setting off or without the key")
        try typedStore.revoke(client:"claude-code",recipient:"local")
        // 6. Pages: the words reach the local writer on a later page too; the cloud port's pages have none.
        let pagedStore=try MemoryStore(home:root.appendingPathComponent("typed-paged"),writable:true,automaticallySyncSearch:false)
        var pagedPolicy=try pagedStore.policy();pagedPolicy.captureText=true;try pagedStore.updatePolicy(pagedPolicy)
        try pagedStore.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()));try pagedStore.setUpTypedVault();try pagedStore.acceptSafeTyping()
        for index in 0..<104 {_=try pagedStore.ingest(Evidence(id:"paged-window-\(index)",at:iso(now.addingTimeInterval(Double(index)*0.01-40)),kind:"window.changed",app:"Notes",bundle:"com.apple.Notes",title:"Research",synthetic:true))}
        _=try pagedStore.ingest(Evidence(id:"paged-typed",at:iso(now.addingTimeInterval(-1)),kind:"keyboard.text_input",app:"Notes",bundle:"com.apple.Notes",title:"Pricing",text:draftWords,synthetic:true))
        let pagedBinding=CoreWriterBinding(store:pagedStore,typedWriter:.local),pagedLocal=pagedBinding.port()
        let first=try await pagedLocal.prepare(target)
        var later:[NoteAction]=[],cursor=first.next
        while let after=cursor {let page=try await pagedLocal.page(first.id,after);later+=page.actions;cursor=page.next}
        let all=first.actions+later
        check(first.next != nil && all.count == first.actionCount && Set(all.map(\.id)).count == all.count,"writer/v2 local-typed-words: fixture: the paged request spans more than one page")
        check(later.contains { $0.id == "paged-typed" && $0.description == "Typed a draft in Notes. "+draftWords },"writer/v2 local-typed-words: a later page of the local presentation carries the draft words")
        check(await pagedLocal.permitted(first,all),"writer/v2 local-typed-words: permitted accepts the complete paged local presentation")
        let pagedCloud=pagedBinding.port(audience:.cloud)
        let cloudFirst=try await pagedCloud.prepare(target)
        var cloudAll=cloudFirst.actions;cursor=cloudFirst.next
        while let after=cursor {let page=try await pagedCloud.page(cloudFirst.id,after);cloudAll+=page.actions;cursor=page.next}
        check(cloudAll.contains { $0.id == "paged-typed" } && !cloudAll.contains { typedLeaks($0.description) || typedLeaks($0.title) },"writer/v2 cloud-no-typed-words: the cloud port's pages carry no words")
        let withWords=cloudAll.map { action -> NoteAction in var a=action;if a.id=="paged-typed" {a.description="Typed a draft in Notes. "+draftWords};return a }
        let cloudOwn=await pagedCloud.permitted(cloudFirst,cloudAll),cloudWords=await pagedCloud.permitted(cloudFirst,withWords)
        check(cloudOwn && !cloudWords,
              "writer/v2 cloud-no-typed-words: the cloud port permits its paged request and refuses it with the words added")
    }
}

/// Refuses the first commit (N7 check).
actor RefuseOnce {
    var calls=0
    func first() -> Bool {calls+=1;return calls==1}
}
