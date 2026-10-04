import Foundation
@testable import MemoryCore
import CoreIntegration
import PrivacyPolicy

@main struct Checks {
    static func main() throws {
        let root=URL(fileURLWithPath:"/private/tmp/daydream-native-receipts-"+UUID().uuidString)
        let store=try MemoryStore(home:root,writable:true,automaticallySyncSearch:false)
        try store.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()));try store.setUpTypedVault();try store.acceptSafeTyping()
        let ledger=NativeCaptureReceipts();let now=Date();var checks=0
        func check(_ result:Bool,_ label:String) {precondition(result,label);checks+=1;print("PASS "+label)}
        func evidence(_ id:String,synthetic:Bool=false)->Evidence {Evidence(id:id,at:iso(now),kind:"window.changed",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Dummy trial",synthetic:synthetic)}
        check(try ledger.commit(store:store,path:.metadata,write:{_ in fatalError("inactive closure")})==nil,"inactive never writes")
        ledger.begin()
        check(try ledger.commit(store:store,path:.metadata,write:{_ in true})==nil,"callback true without record denied")
        check(try ledger.commit(store:store,path:.metadata,write:{_ in false})==nil,"declined commit denied")
        let first=try ledger.commit(store:store,path:.metadata) {try store.ingest(evidence($0))}!
        check(first.sequence==3 && first.actionID.contains(first.captureSessionID),"exact issued ID/session/sequence")
        check(try ledger.validated(store:store)?.0==first,"durable exact readback")
        _=try store.correctAction(id:first.actionID,text:"Correction",expectedRevision:first.actionRevision)
        check(try ledger.validated(store:store)==nil,"correction invalidates receipt")
        check(try ledger.commit(store:store,path:.metadata,write:{try store.ingest(evidence($0,synthetic:true))})==nil,"synthetic denied even with issued ID")
        var rolledID=""
        do {
            _=try ledger.commit(store:store,path:.metadata) {id in
                rolledID=id
                return try store.transaction {try store.ingest(evidence(id));throw MemError.denied}
            };fatalError("rollback not thrown")
        } catch {check(try store.action(rolledID)==nil && ledger.validated(store:store)==nil,"actual transaction rollback has no receipt")}
        let second=try ledger.commit(store:store,path:.metadata) {try store.ingest(evidence($0))}!
        try store.delete(second.actionID)
        check(try ledger.validated(store:store)==nil,"deleted action denied")
        let third=try ledger.commit(store:store,path:.metadata) {try store.ingest(evidence($0))}!
        ledger.invalidate();check(try ledger.validated(store:store)==nil,"pause cancels authority")
        ledger.begin();check(try ledger.validated(store:store)==nil,"restart never adopts old receipt")
        let fourth=try ledger.commit(store:store,path:.metadata) {try store.ingest(evidence($0))}!
        check(fourth.captureSessionID != third.captureSessionID && fourth.sequence==1,"new capture session starts fresh")
        check(try NativeCaptureReceipts().validated(store:store)==nil,"imported/existing native records cannot mint proof")
        var policy=try store.policy();policy.blockedApps.append("com.apple.TextEdit");try store.updatePolicy(policy)
        check(try ledger.validated(store:store)==nil,"policy exclusion revokes proof")
        policy.blockedApps.removeAll{$0=="com.apple.TextEdit"};policy.captureText=true;policy.typedConsentVersion=1;try store.updatePolicy(policy)
        try store.setCaptureState("recording",reason:"synthetic test only")
        let binding=CoreCaptureBinding(store:store);let context=try binding.context();let mono:UInt64=10_000_000_000
        var proof=FocusProof();proof.generation=context.generation;proof.policyVersion=context.policy.version;proof.checkedAt=mono
        proof.bundle="com.apple.TextEdit";proof.windowID="fixture-window";proof.focusID="fixture-field";proof.role="AXTextArea";proof.surface = .native
        proof.secureInput = .no;proof.privateMode = .no;proof.verified=true;proof.fieldStateVerified=true;proof.frameAccessible=true;proof.navigationStable=true
        let accepted=try binding.append(proof:proof,now:mono,readCharacters:{"Harmless draft"})
        check(accepted.outcome == .allowed,"actual core accepts synthetic native proof")
        let typed=try ledger.commit(store:store,path:.typedText) {try binding.commitText(id:$0,proof:proof,now:mono)}
        check(typed?.path == .typedText,"actual typed core commit attributed")
        check(try ledger.validated(store:store)?.1.state=="draft","typed receipt never claims sent")
        ledger.begin()
        check(try ledger.commit(store:store,path:.typedText,write:{try store.ingest(evidence($0))})==nil,"metadata cannot pretend typed path")
        check(try ledger.commit(store:store,path:.metadata,write:{id in let saved=try store.ingest(evidence(id));ledger.invalidate();return saved})==nil,"cancellation during write cannot publish")
        // Chrome page history: page rows get a metadata receipt; no other Chrome row does.
        func page(_ id:String,provider:String=BrowserSafety.pageProvider,kind:String="window.changed")->Evidence {
            let at=Date()
            var proof=BrowserVerification(mode:"normal",windowID:"1520",tabID:"1733",focusedRole:provider == BrowserSafety.pageProvider ? "" : "AXLink",checkedAt:isoPrecise(at),provider:provider)
            proof.policyRevision="policy-fixture"
            return Evidence(id:id,at:isoPrecise(at),kind:kind,app:"Google Chrome",bundle:"com.google.Chrome",title:"Orchid pricing",url:"https://shop.example.org",browserVerification:proof)
        }
        ledger.begin()
        let pageReceipt=try ledger.commit(store:store,path:.metadata) {try store.ingest(page($0))}
        check(try pageReceipt?.path == .metadata && (ledger.validated(store:store)?.1.bundle) == "com.google.Chrome","page history: a page row gets a metadata receipt")
        check(try ledger.commit(store:store,path:.typedText) {try store.ingest(page($0))}==nil,"page history: a page row is never a typed-text receipt")
        check(try ledger.commit(store:store,path:.keyMarker) {try store.ingest(page($0))}==nil,"page history: a page row is never a key receipt")
        for provider in ["chrome-appleevents-v1","chrome-native-bridge-v1","browser-extension-v3","title-heuristic"] {
            check(try ledger.commit(store:store,path:.metadata) {try store.ingest(page($0,provider:provider))}==nil,"page history: a Chrome row with another provider gets no receipt: "+provider)
        }
        check(try ledger.commit(store:store,path:.metadata) {try store.ingest(page($0,kind:"app.activated"))}==nil,"page history: a Chrome app activation gets no receipt")
        // Coordinator.allowsApp: Chrome follows the switch; other browsers never count.
        let appsHome=URL(fileURLWithPath:"/private/tmp/daydream-native-receipts-apps-"+UUID().uuidString)
        let appsStore=try MemoryStore(home:appsHome,writable:true,automaticallySyncSearch:false)
        let coordinator=try Coordinator(store:appsStore,permissions:{true},onCommitted:{})
        check(!coordinator.allowsApp("com.google.Chrome") && coordinator.allowsApp("com.apple.TextEdit"),"page history: allowsApp(Chrome) is false while the switch is off")
        // The consent this build's Chrome card asks for: 1 in a narrow build, 2 in the release (its text names website typing).
        var pagesPolicy=try appsStore.policy();pagesPolicy.browserPages=true;pagesPolicy.browserPagesConsentVersion=PrivacySettings.browserPagesConsentCurrent;try appsStore.updatePolicy(pagesPolicy)
        check(coordinator.allowsApp("com.google.Chrome"),"page history: allowsApp(Chrome) is true with the switch on")
        if PrivacySettings.browserPagesConsentCurrent != 1 {
            pagesPolicy=try appsStore.policy();pagesPolicy.browserPagesConsentVersion=1;try appsStore.updatePolicy(pagesPolicy)
            check(!coordinator.allowsApp("com.google.Chrome"),"page history: release build: a consent to the older Chrome text (1) does not count")
            pagesPolicy=try appsStore.policy();pagesPolicy.browserPagesConsentVersion=PrivacySettings.browserPagesConsentCurrent;try appsStore.updatePolicy(pagesPolicy)
        }
        for other in ["com.google.Chrome.beta","com.google.Chrome.canary","com.google.Chrome.dev","com.google.Chrome.app.Default-abcdefghijklmnopabcdefghijklmnop","com.apple.Safari","org.mozilla.firefox",""] {
            check(!coordinator.allowsApp(other),"page history: allowsApp stays false for another browser: "+other)
        }
        pagesPolicy=try appsStore.policy();pagesPolicy.blockedApps=["com.google.Chrome"];try appsStore.updatePolicy(pagesPolicy)
        check(!coordinator.allowsApp("com.google.Chrome"),"page history: Exclude Google Chrome wins over the switch")
        pagesPolicy=try appsStore.policy();pagesPolicy.blockedApps=[];pagesPolicy.browserPagesConsentVersion=nil;try appsStore.updatePolicy(pagesPolicy)
        check(!coordinator.allowsApp("com.google.Chrome"),"page history: the switch without a consent version does not count")
        print("PASS \(checks) checks. Fixture \(root.path). No OS capture/grants/keys.")
    }
}
