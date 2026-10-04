import Foundation
import CryptoKit
import Darwin
import Security
@testable import MemoryCore
import BrowserBridge
import CoreIntegration

@main struct BrowserAppChecks {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let root=URL(fileURLWithPath:"/private/tmp/browser-app-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let store=try MemoryStore(home:root.appendingPathComponent("store"),writable:true,automaticallySyncSearch:false)
        let app=P256.Signing.PrivateKey(),key=P256.Signing.PrivateKey(),id=String(repeating:"a",count:32)
        let pins=MetadataPins(extensionID:id,extensionKey:key.publicKey,appKey:app)
        var permission=true,secure=false,front="com.google.Chrome",commits=0,checks=0
        let coordinator=try Coordinator(store:store,permissions:{permission},browserEnvironment:.init(frontmost:{front},secureInputOff:{!secure})) {commits+=1}
        func check(_ value:Bool,_ label:String) {precondition(value,label);checks+=1;print("PASS "+label)}
        func hello(_ nonce:String=String(repeating:"b",count:32))->Data {
            Data("{\"version\":3,\"kind\":\"metadata_hello\",\"browser\":\"chrome\",\"extensionID\":\"\(id)\",\"clientNonce\":\"\(nonce)\",\"textEnabled\":false}".utf8)
        }
        func response(_ request:Data,privateMode:Bool=false)throws->Data {
            let f=SignedMetadataFrame.decode(request)!,p=try JSONSerialization.jsonObject(with:Data(base64Encoded:f.payload)!) as! [String:Any]
            let observation:[String:Any]=["version":1,"kind":"observation","nonce":p["nonce"]!,"policyRevision":p["policyRevision"]!,"windowMode":privateMode ? "private":"normal","tabMode":"normal","windowID":3,"tabID":9,"frameID":0,"documentID":"11111111-1111-4111-8111-111111111111","navigationGeneration":1,"focusID":"22222222-2222-4222-8222-222222222222","focusGeneration":1,"role":"document","safety":"noneditable","origin":"https://example.test","textEnabled":false]
            return try SignedMetadataFrame.sign(payload:JSONSerialization.data(withJSONObject:observation),extensionID:id,clientNonce:f.clientNonce,sessionID:f.sessionID,sequence:f.sequence,direction:"extension-to-app",key:key)
        }
        try coordinator.start()
        check(!FileManager.default.fileExists(atPath:root.appendingPathComponent("browser-metadata.sock").path),"normal recording without provider starts no listener")
        let denied=CoreBrowserConnection(binding:coordinator.captureBinding,pins:pins)
        check(denied.acceptHello(hello()),"hello alone can open only an unvalidated core session")
        check(try coordinator.browserRequest(denied)==nil,"default release/device gates deny requests");denied.close()
        let connection=CoreBrowserConnection(binding:coordinator.captureBinding,pins:pins,integrationValidated:true,physicalDeviceValidated:true) // Synthetic fixture only.
        check(connection.acceptHello(hello()),"synthetic reviewed provider facade accepts exact hello")
        let request=try coordinator.browserRequest(connection)!,answer=try response(request)
        check(try coordinator.browserResponse(connection,request:request,response:answer),"actual Coordinator verifies and commits signed observation")
        let receipt=coordinator.browserReceipt!
        check(try store.action(receipt.actionID)?.revision==receipt.actionRevision && commits==1,"receipt names exact canonical action and schedules writer once")
        check(try !coordinator.browserResponse(connection,request:request,response:answer) && commits==1,"replay cannot publish receipt or reschedule")
        _=try store.correctAction(id:receipt.actionID,text:"Synthetic correction",expectedRevision:receipt.actionRevision)
        check(try BrowserReceiptReadback.read(store:store,request:request,now:Date())==nil,"corrected action cannot pass browser receipt readback")
        try await Task.sleep(nanoseconds:160_000_000)
        let q2=try coordinator.browserRequest(connection)!
        check(try !coordinator.browserResponse(connection,request:q2,response:response(q2,privateMode:true)),"private response denied")
        try await Task.sleep(nanoseconds:160_000_000)
        secure=true;check(try coordinator.browserRequest(connection)==nil,"secure input denies before request");secure=false
        permission=false;check(try coordinator.browserRequest(connection)==nil,"permission loss denies request");permission=true
        front="com.apple.TextEdit";check(try coordinator.browserRequest(connection)==nil,"non-browser foreground denied");front="com.google.Chrome"
        try await Task.sleep(nanoseconds:160_000_000)
        let failedRequest=try coordinator.browserRequest(connection)!
        try store.exec("CREATE TRIGGER fail_browser BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT,'synthetic failure'); END")
        do {_=try coordinator.browserResponse(connection,request:failedRequest,response:response(failedRequest));preconditionFailure("storage failure accepted")}
        catch {check(coordinator.browserReceipt==nil && commits==1,"failed canonical transaction cannot publish receipt or notify writer")}
        try store.exec("DROP TRIGGER fail_browser")
        connection.close();coordinator.stop()
        // Exercise actual listener + framed transport. Fresh in-memory fixture
        // keys and fake native facts only; no real browser or Keychain involved.
        coordinator.configureBrowserProvider(.init(directory:root,connection:{binding in CoreBrowserConnection(binding:binding,pins:pins,integrationValidated:true,physicalDeviceValidated:true)},validate:{true})) // Explicit synthetic fixture admission only.
        try coordinator.start()
        try await Task.sleep(nanoseconds:200_000_000)
        let helloBytes=hello(String(repeating:"c",count:32))
        let client=Task.detached { () throws -> Int32 in
            let fd=try MetadataLocalTransport.connect(directory:root,deadline:DispatchTime.now().uptimeNanoseconds+1_000_000_000)
            try MetadataRelay.writeFrame(helloBytes,to:fd,deadline:DispatchTime.now().uptimeNanoseconds+1_000_000_000)
            return fd
        }
        let fd=try await client.value
        let wireRequest=try await Task.detached {try MetadataRelay.readFrame(fd,deadline:DispatchTime.now().uptimeNanoseconds+1_000_000_000)}.value
        let wireResponse=try response(wireRequest)
        try await Task.detached {try MetadataRelay.writeFrame(wireResponse,to:fd,deadline:DispatchTime.now().uptimeNanoseconds+1_000_000_000)}.value
        try await Task.sleep(nanoseconds:100_000_000)
        check(commits==2 && coordinator.browserReceipt != nil,"real temporary socket reaches canonical receipt through owned app transport")
        coordinator.stop()
        check(coordinator.browserReceipt==nil && !coordinator.isRunning,"stop clears receipt and denies capture")
        Darwin.close(fd)
        try await Task.sleep(nanoseconds:300_000_000)
        check(!FileManager.default.fileExists(atPath:root.appendingPathComponent("browser-metadata.sock").path),"owned listener removes only its socket after stop")
        check(try store.rows("SELECT id FROM records").count==2,"only two authenticated harmless observations persisted")
        // typing-all final review (critical): the real Chrome signature call,
        // against this check's own running process (no Chrome is touched). It
        // once passed kSecCSDoNotValidateResources, which SecCodeCheckValidity
        // rejects with errSecCSInvalidFlags on every call.
        var me:SecCode?, onDisk:SecStaticCode?, designated:SecRequirement?, designatedText:CFString?
        check(SecCodeCopySelf([],&me) == errSecSuccess && SecCodeCopyStaticCode(me!,[],&onDisk) == errSecSuccess
              && SecCodeCopyDesignatedRequirement(onDisk!,[],&designated) == errSecSuccess
              && SecRequirementCopyString(designated!,[],&designatedText) == errSecSuccess,"the check reads its own designated requirement")
        let own=ChromeEventSender.signatureStatus(pid:getpid(),requirement:designatedText! as String)
        check(own == errSecSuccess,"the Chrome signature call accepts a running process that satisfies the requirement (status \(own))")
        let google=ChromeEventSender.signatureStatus(pid:getpid(),requirement:ChromePageTarget.requirement)
        check(google == errSecCSReqFailed,"a process not signed by Google fails on the requirement, never on the call's flags (status \(google))")
        check(ChromeEventSender.signatureFlags == SecCSFlags(rawValue:0),"the signature check passes no flags SecCodeCheckValidity rejects")
        print("PASS \(checks) browser app checks; fixture \(root.path). No real browser, keys, grants or capture.")
    }
}
