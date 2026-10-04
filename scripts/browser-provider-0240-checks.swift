import Foundation
import CryptoKit
@testable import MemoryCore
import BrowserBridge
import CoreIntegration

@main struct ProviderChecks {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let root=URL(fileURLWithPath:"/private/tmp/browser-provider-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let app=P256.Signing.PrivateKey(),key=P256.Signing.PrivateKey(),id=String(repeating:"a",count:32),deployment=String(repeating:"d",count:64)
        let registration=try MetadataRegistration(browser:.chrome,extensionID:id,publicKey:key.publicKey.x963Representation)
        let config=BrowserProviderConfiguration(directory:root,keychainService:"fixture.browser.keys",deployment:deployment,extensionID:id)
        let setup=try MetadataProductionSetup(directory:root,appKey:app)
        var clock=Date(),checks=0
        func check(_ value:Bool,_ label:String) {precondition(value,label);checks+=1;print("PASS "+label)}
        func rejects(_ label:String,_ body:()throws->Void) {do {try body();preconditionFailure(label)} catch {check(true,label)}}
        func resolve(_ configuration:BrowserProviderConfiguration?=nil)throws->BrowserCaptureProvider {try BrowserProviderResolver.resolve(configuration:configuration ?? config,load:{setup},now:{clock})}
        rejects("missing reviewed configuration denied") {_=try resolve()}
        let review=try BrowserEnrollmentReview(directory:root,deployment:deployment,appKey:app)
        let challenge=try review.prepare(registration,now:1)
        check(!FileManager.default.fileExists(atPath:root.appendingPathComponent("registrations.json").path),"prepare does not save registration")
        check(!FileManager.default.fileExists(atPath:root.appendingPathComponent("chrome-configuration.json").path),"prepare does not save configuration")
        review.cancel()
        rejects("cancelled enrollment cannot confirm") {_=try review.confirm(displayedFingerprint:challenge.fingerprint,displayedAppFingerprint:challenge.appFingerprint,extensionSignature:key.signature(for:challenge.signedBytes).rawRepresentation,now:2)}
        let wrong=try review.prepare(registration,now:3)
        rejects("wrong displayed fingerprint denied") {_=try review.confirm(displayedFingerprint:"wrong",displayedAppFingerprint:wrong.appFingerprint,extensionSignature:key.signature(for:wrong.signedBytes).rawRepresentation,now:4)}
        let next=try review.prepare(registration,now:5)
        _=try review.confirm(displayedFingerprint:next.fingerprint,displayedAppFingerprint:next.appFingerprint,extensionSignature:key.signature(for:next.signedBytes).rawRepresentation,now:6)
        check(FileManager.default.fileExists(atPath:root.appendingPathComponent("chrome-configuration.json").path),"actual possession approval saves signed producer configuration")
        rejects("confirmation cannot replay") {_=try review.confirm(displayedFingerprint:next.fingerprint,displayedAppFingerprint:next.appFingerprint,extensionSignature:key.signature(for:next.signedBytes).rawRepresentation,now:7)}
        let unvalidated=try setup.resolve(browser:.chrome,expectedDeployment:deployment,now:clock)
        check(!unvalidated.integrationValidated && !unvalidated.physicalDeviceValidated,"enrollment does not mint device validation")
        rejects("app resolver denies enrolled but unvalidated provider") {_=try resolve()}
        let diagnostic=MetadataDiagnosticSession(pins:unvalidated.pins,clientNonce:String(repeating:"b",count:32),deployment:deployment)!
        let request=try diagnostic.request(now:clock),frame=SignedMetadataFrame.decode(request)!
        let object=try JSONSerialization.jsonObject(with:Data(base64Encoded:frame.payload)!) as! [String:Any]
        let ack:[String:Any]=["kind":"diagnostic_ack","nonce":object["nonce"]!,"deployment":deployment,"issuedAt":object["issuedAt"]!,"runtimeID":id,"contentRead":false]
        let response=try SignedMetadataFrame.sign(payload:JSONSerialization.data(withJSONObject:ack),extensionID:id,clientNonce:frame.clientNonce,sessionID:frame.sessionID,sequence:frame.sequence,direction:"extension-to-app",key:key)
        rejects("wire diagnostic alone cannot record unreviewed validation") {try setup.recordValidation(browser:.chrome,expectedDeployment:deployment,request:request,response:response,reviewedChecks:MetadataProductionSetup.requiredChecks,nativeHumanConfirmed:false,now:clock)}
        // Explicit disposable simulation of producer-native operator review.
        // This is NOT a real device receipt and never enters production storage.
        try setup.recordValidation(browser:.chrome,expectedDeployment:deployment,request:request,response:response,reviewedChecks:MetadataProductionSetup.requiredChecks,nativeHumanConfirmed:true,now:clock)
        let provider=try resolve()
        check(provider.validate(),"actual app consumer accepts producer API's valid fixture receipt")
        let store=try MemoryStore(home:root.appendingPathComponent("store"),writable:true,automaticallySyncSearch:false)
        let coordinator=try Coordinator(store:store,permissions:{true},browserEnvironment:.init(frontmost:{"com.google.Chrome"},secureInputOff:{true}),onCommitted:{})
        try coordinator.start()
        let connection=provider.connection(coordinator.captureBinding)
        let hello=Data("{\"version\":3,\"kind\":\"metadata_hello\",\"browser\":\"chrome\",\"extensionID\":\"\(id)\",\"clientNonce\":\"\(String(repeating:"c",count:32))\",\"textEnabled\":false}".utf8)
        check(connection.acceptHello(hello),"resolved provider accepts exact core hello")
        let probe=try coordinator.browserRequest(connection)!,q=SignedMetadataFrame.decode(probe)!
        let p=try JSONSerialization.jsonObject(with:Data(base64Encoded:q.payload)!) as! [String:Any]
        let observation:[String:Any]=["version":1,"kind":"observation","nonce":p["nonce"]!,"policyRevision":p["policyRevision"]!,"windowMode":"normal","tabMode":"normal","windowID":3,"tabID":9,"frameID":0,"documentID":"11111111-1111-4111-8111-111111111111","navigationGeneration":1,"focusID":"22222222-2222-4222-8222-222222222222","focusGeneration":1,"role":"document","safety":"noneditable","origin":"https://example.test","textEnabled":false]
        let observed=try SignedMetadataFrame.sign(payload:JSONSerialization.data(withJSONObject:observation),extensionID:id,clientNonce:q.clientNonce,sessionID:q.sessionID,sequence:q.sequence,direction:"extension-to-app",key:key)
        check(try coordinator.browserResponse(connection,request:probe,response:observed) && coordinator.browserReceipt != nil,"actual resolved provider reaches signed canonical commit and exact receipt")
        connection.close();coordinator.stop()
        let restarted=try MetadataProductionSetup(directory:root,appKey:app)
        let loaded=try BrowserProviderResolver.resolve(configuration:config,load:{restarted},now:{clock})
        check(loaded.validate(),"fresh app consumer verifies persisted signed records on restart")
        rejects("wrong deployment denied") {_=try resolve(.init(directory:root,keychainService:config.keychainService,deployment:String(repeating:"e",count:64),extensionID:id))}
        rejects("wrong extension ID denied") {_=try resolve(.init(directory:root,keychainService:config.keychainService,deployment:deployment,extensionID:String(repeating:"f",count:32)))}
        rejects("missing existing key stays unavailable without fallback") {_=try BrowserProviderResolver.resolve(configuration:config,load:{throw BrowserProviderError.missing},now:{clock})}
        clock=clock.addingTimeInterval(31*86400)
        check(!provider.validate(),"expired validation closes retained admission")
        rejects("expired receipt cannot freshly resolve") {_=try resolve()}
        clock=Date()
        let receiptURL=root.appendingPathComponent("chrome-validation.json"),receipt=try Data(contentsOf:receiptURL)
        try Data("tampered".utf8).write(to:receiptURL)
        check(!provider.validate(),"tampered signed receipt invalidates active provider")
        try receipt.write(to:receiptURL);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:receiptURL.path)
        let refreshed=try resolve();check(refreshed.validate(),"exact fixture restoration passes fresh verification")
        try FileManager.default.removeItem(at:receiptURL)
        check(!refreshed.validate(),"removed validation authority denies retained provider")
        check(try store.captureStatus()["state"] != "recording","enrollment and resolver do not leave capture active")
        print("PASS \(checks) actual producer/app consumer checks. Fixture signatures/operator review only; no real keys, browser, capture or enrollment. \(root.path)")
    }
}
