import Foundation
import MemoryCore
import PrivacyPolicy
import CoreIntegration

/// Fictional fixtures only, through actual character-by-character binding and sealed store.
@main struct ContactShapePipelineChecks {
    static var passed=0, failed=0
    static func check(_ value:Bool,_ label:String) { print("\(value ? "PASS" : "FAIL") \(label)");if value {passed+=1}else{failed+=1} }
    static func saved(_ text:String,_ reason:SealReason = .idle, secure:VerifiedFlag = .no, verified:Bool=true) throws -> (String?,Int) {
        let home=FileManager.default.temporaryDirectory.appendingPathComponent("contact-shape-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:home)}
        let store=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false)
        try store.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()));try store.setUpTypedVault();try store.acceptSafeTyping()
        var policy=try store.policy();policy.captureText=true;policy.typedConsentVersion=1;try store.updatePolicy(policy)
        try store.setCaptureState("recording",reason:"fictional fixture")
        let binding=CoreCaptureBinding(store:store);var now:UInt64=10_000_000_000, reads=0
        func proof() throws -> FocusProof {
            let context=try binding.context();var p=FocusProof()
            p.generation=context.generation;p.policyVersion=context.policy.version;p.checkedAt=now
            p.bundle=SendRules.mailApp;p.windowID="fictional-mail";p.focusID="fictional-body";p.role="AXTextArea";p.sendField="body";p.fieldLabel="body"
            p.secureInput=secure;p.privateMode = .no;p.surface = .native;p.verified=verified;p.fieldStateVerified=verified;p.frameAccessible=true;p.navigationStable=true
            return p
        }
        for c in text {now+=80_000_000;_ = try binding.insert(proof:proof(),eventAt:now,now:now,readCharacters:{reads+=1;return String(c)})}
        _ = try binding.commitText(id:"fictional-source",proof:proof(),now:now,reason:reason)
        return (try store.hydrateTypedText("fictional-source",disclosure:.owner),reads)
    }
    static func main() throws {
        let permitted=[
            "Reach me at morgan@example.com or 415-555-0100.",
            "Reach me at Morgan.Example2+notes@example.com or 415-555-0100.",
            "Phone: 415-555-0100",
            "Call (415) 555-0100 tomorrow.",
            "Call 415 555 0100 tomorrow.",
            "Call 415.555.0100 tomorrow.",
            "Call +1 415-555-0100 tomorrow.",
            "Call +1 (415) 555-0100 tomorrow.",
            "Morgan.Example2+notes@example.com",
            "415-555-0100",
            "(415) 555-0100"
        ]
        for (i,text) in permitted.enumerated() {
            for reason:SealReason in [.idle,.submit] {
                let result=try saved(text,reason)
                check(result.0==text,"ordinary contact \(i) exact sealed retention \(reason.rawValue)")
            }
        }
        let malformed=[".Morgan2@example.com","Morgan2.@example.com","Morgan..Example2@example.com","Morgan2@-example.com","Morgan2@example-.com","Morgan2@example..com",String(repeating:"a",count:65)+"@example.com"]
        for (i,value) in malformed.enumerated() {check(!ContactShape.email(value),"malformed email \(i) cannot receive contact exemption")}
        for (i,value) in malformed.prefix(6).enumerated() {
            let result=try saved(value)
            check(result.0 != value,"malformed email \(i) cannot bypass production opaque-token denial")
        }
        for (i,text) in ["password: Morgan2@example.com","my password is Morgan2@example.com","PIN: 415-555-0100","verification code: 415-555-0100","SSN 123-45-6789","Card 4111 1111 1111 1111","Card 4155 5501 0041 1111","4111111111111111","1234567890","code: 1234567890","API key: Morgan2@example.com","token: 415-555-0100","password: 415-555-0100","sk-live-Example123456789","415-555-01","Morgan.Example2@"].enumerated() {
            let result=try saved(text)
            check(result.0==nil,"secret or unknown number \(i) produces no sealed source")
        }
        let privateField=try saved("415-555-0100",secure:.yes)
        check(privateField.0==nil && privateField.1==0,"secure field denied before reading ordinary-shaped phone")
        let unknownField=try saved("Morgan2@example.com",verified:false)
        check(unknownField.0==nil && unknownField.1==0,"unverified field denied before reading ordinary-shaped email")
        let unknownSecure=try saved("415-555-0100",secure:.unknown)
        check(unknownSecure.0==nil && unknownSecure.1==0,"unknown secure-input status denied before reading phone")
        print("contact-shape-pipeline: \(passed) passed, \(failed) failed")
        if failed>0 {exit(1)}
    }
}
