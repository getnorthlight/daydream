import Foundation
import CryptoKit
@testable import MemoryCore
import PrivacyPolicy
import BrowserBridge

@main struct BrowserCoreChecks {
    static var checks=0
    static func check(_ value:Bool,_ name:String){precondition(value,name);checks+=1}
    final class Fixture {
        let store:MemoryStore,binding:CoreCaptureBinding,browser:MetadataBrowser
        let key=P256.Signing.PrivateKey(),app=P256.Signing.PrivateKey()
        var handle="",tick:UInt64=1_000_000_000,wall=Date()
        var id:String {browser == .chrome ? String(repeating:"a",count:32) : "com.daydream.fixture"}
        init(_ browser:MetadataBrowser,validated:Bool=true)throws {
            self.browser=browser
            let home=URL(fileURLWithPath:"/private/tmp/browser-store-"+UUID().uuidString,isDirectory:true)
            store=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false)
            binding=CoreCaptureBinding(store:store)
            try store.setCaptureState("recording",reason:"isolated synthetic fixture",now:wall)
            handle=binding.openBrowser(pins:MetadataPins(extensionID:id,extensionKey:key.publicKey,appKey:app,browser:browser),clientNonce:String(repeating:"b",count:32),integrationValidated:validated,physicalDeviceValidated:validated)!
        }
        func native()throws->MetadataGate {
            var n=MetadataGate();n.frontmostBrowserBundle=browser.bundle;n.secureInputOff=true;n.permissionPresent=true
            n.captureEnabled=true;n.excluded=false;n.generation=Int(try binding.context().generation);n.checkedAt=tick;return n
        }
        func request()throws->Data? {try binding.requestBrowser(handle,native:native(),now:tick,wallTime:wall)}
        func response(_ request:Data,forged:Bool=false,mutate:(inout [String:Any])->Void={_ in})throws->Data {
            let f=SignedMetadataFrame.decode(request)!,p=try JSONSerialization.jsonObject(with:Data(base64Encoded:f.payload)!) as! [String:Any]
            var observation:[String:Any]=["version":1,"kind":"observation","nonce":p["nonce"]!,"policyRevision":p["policyRevision"]!,
                "windowMode":"normal","tabMode":"normal","windowID":3,"tabID":9,"frameID":0,
                "documentID":"11111111-1111-4111-8111-111111111111","navigationGeneration":1,
                "focusID":"22222222-2222-4222-8222-222222222222","focusGeneration":1,"role":"document","safety":"noneditable","origin":"https://example.test","textEnabled":false]
            mutate(&observation)
            return try SignedMetadataFrame.sign(payload:JSONSerialization.data(withJSONObject:observation),extensionID:id,clientNonce:f.clientNonce,sessionID:f.sessionID,sequence:f.sequence,direction:"extension-to-app",key:forged ? P256.Signing.PrivateKey() : key,browser:browser)
        }
        func receive(_ frame:Data,native:MetadataGate?=nil)throws->Bool {try binding.receiveBrowser(handle,frame:frame,native:native ?? self.native(),now:tick,wallTime:wall)}
        func actions()throws->[CanonicalAction] {try store.actions(now:wall).actions}
        func advance()throws {tick+=500_000_000;wall=wall.addingTimeInterval(0.5);try store.setCaptureState("recording",reason:"fixture heartbeat",now:wall)}
    }
    static func main()throws {
        for browser in [MetadataBrowser.chrome,.safari] {
            let f=try Fixture(browser),q=try f.request()!,answer=try f.response(q)
            check(try f.receive(answer),"first observation commits immediately \(browser)")
            let actions=try f.actions()
            check(actions.count==1 && actions[0].kind=="browser.extension_observed" && actions[0].site=="example.test" && actions[0].state=="observed" && actions[0].title.isEmpty,"canonical action without writer \(browser)")
            check(actions[0].description.contains("reading is not established"),"no reading claim")
            let stored=try decode(Evidence.self,f.store.rows("SELECT body FROM records")[0][0])
            check(!stored.synthetic && stored.text.isEmpty && stored.title.isEmpty && stored.browserVerification?.provider=="browser-extension-v3","real canonical proof shape, not synthetic bypass")
            check(try !f.store.ingest(stored,now:f.wall),"store rejects browser commit without required policy/recording contract")
            do {let saved=try f.store.ingest(stored,now:f.wall,expectedPolicyRevision:stored.browserVerification!.policyRevision,requireRecording:true,expectedCaptureEpoch:"changed");check(!saved,"store rejects wrong recording epoch")}
            catch{check(true,"store atomically rejects changed epoch")}
            check(try !f.receive(answer) && f.actions().count==1,"replay cannot duplicate")
            for _ in 1...21 {try f.advance();check(try f.receive(f.response(f.request()!)),"continuous observation")}
            check(try f.actions().filter{$0.kind=="browser.extension_tab_visited"}.count==1,"canonical ten-second visit")
            for (field,value) in [("windowMode","private"),("tabMode","private"),("role","unknown"),("role","AXButton"),("safety","sensitive"),("documentID","unknown"),("origin","https://example.test/?token=secret"),("origin","https://bank.example"),("text","private"),("kind","sent")] {
                let denied=try Fixture(browser),r=try denied.response(denied.request()!){$0[field]=value}
                check(try !denied.receive(r) && denied.actions().isEmpty,"canonical denies \(field) \(value)")
            }
            for mutation in ["secure","permission","background","generation","expired","paused","pauseResume","policy","excludedSite","excludedApp","disconnect","forged"] {
                let denied=try Fixture(browser),r=try denied.response(denied.request()!,forged:mutation=="forged")
                var n=try denied.native()
                switch mutation {
                case "secure":n.secureInputOff=false
                case "permission":n.permissionPresent=false
                case "background":n.frontmostBrowserBundle="com.apple.TextEdit"
                case "generation":denied.binding.invalidate(.focus)
                case "expired":denied.tick+=2_000_000_000;n.checkedAt=denied.tick
                case "paused":try denied.store.setCaptureState("paused",reason:"fixture",now:denied.wall)
                case "pauseResume":try denied.store.setCaptureState("paused",reason:"fixture",now:denied.wall);try denied.store.setCaptureState("recording",reason:"fixture",now:denied.wall)
                case "policy","excludedSite","excludedApp":
                    var p=try denied.store.policy()
                    if mutation=="excludedSite" {p.blockedDomains.append("example.test")}
                    if mutation=="excludedApp" {p.blockedApps.append(browser.bundle)}
                    try denied.store.updatePolicy(p,now:denied.wall);n=try denied.native()
                case "disconnect":denied.binding.closeBrowser(denied.handle)
                default:break
                }
                check(try !denied.receive(r,native:n) && denied.actions().isEmpty,"canonical rejects \(mutation)")
            }
            let disabled=try Fixture(browser,validated:false)
            check(try disabled.request()==nil && disabled.actions().isEmpty,"mocks do not change production validation default")
            let blocked=try Fixture(browser);var p=try blocked.store.policy();p.blockedApps.append(browser.bundle);try blocked.store.updatePolicy(p,now:blocked.wall)
            check(try blocked.request()==nil,"app excluded before browser request")
            let direct=Evidence(id:"forged",at:iso(f.wall),kind:"browser.extension_observed",app:"Browser",bundle:browser.bundle)
            check(try !f.store.ingest(direct,now:f.wall),"raw browser evidence without verification rejected")
            f.binding.closeBrowser(f.handle)
            let pins=MetadataPins(extensionID:f.id,extensionKey:f.key.publicKey,appKey:f.app,browser:browser)
            let connection=CoreBrowserConnection(binding:f.binding,pins:pins,integrationValidated:true,physicalDeviceValidated:true)
            let hello=try JSONSerialization.data(withJSONObject:["version":3,"kind":"metadata_hello","browser":browser.rawValue,"extensionID":f.id,"clientNonce":String(repeating:"c",count:32),"textEnabled":false])
            check(connection.acceptHello(hello),"callable facade accepts bound hello")
            check(!connection.acceptHello(hello),"duplicate hello cannot reset current session")
            let request=try connection.request(native:f.native(),now:f.tick,wallTime:f.wall)!
            check(try connection.receive(f.response(request),native:f.native(),now:f.tick,wallTime:f.wall),"facade signature through canonical store")
            connection.close()
            check(try connection.request(native:f.native(),now:f.tick,wallTime:f.wall)==nil,"facade teardown denies further requests")
        }
        var nativeProof=FocusProof();nativeProof.bundle="com.apple.Safari";nativeProof.surface = .browser
        var policy=CapturePolicy();policy.typedText=true
        check(CaptureGate.typing(nativeProof,policy:policy,generation:0,now:0).outcome != .allowed,"browser typing still denied")
        print("PASS \(checks) canonical browser ingestion checks; temporary stores, no real capture")
    }
}
