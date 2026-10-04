import Foundation
import CryptoKit
import BrowserBridge

@main struct SetupChecks {
    static var count=0
    static func check(_ value:Bool,_ label:String){precondition(value,label);count+=1}
    static func rejects(_ label:String,_ body:()throws->Void){do{try body();fatalError(label)}catch{count+=1}}
    static func main()throws {
        for browser in [MetadataBrowser.chrome,.safari] {
            let dir=URL(fileURLWithPath:"/private/tmp/browser-setup-check-"+UUID().uuidString,isDirectory:true)
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            let app=P256.Signing.PrivateKey(),ext=P256.Signing.PrivateKey(),attacker=P256.Signing.PrivateKey()
            let id=browser == .chrome ? String(repeating:"a",count:32) : "com.daydream.fixture"
            let deployment=String(repeating:"d",count:64),date=Date()
            let reg=try MetadataRegistration(browser:browser,extensionID:id,publicKey:ext.publicKey.x963Representation)
            let setup=try MetadataProductionSetup(directory:dir,appKey:app),registry=try MetadataRegistrationFile(directory:dir)
            rejects("missing config"){_ = try setup.resolve(browser:browser,expectedDeployment:deployment)}
            rejects("not enrolled"){_ = try setup.reviewConfiguration(registration:reg,relayDirectory:dir,deployment:deployment,nativeHumanConfirmed:true)}
            let enrollment=MetadataEnrollment(appKey:app,load:{try registry.load(browser:$0,extensionID:$1)},save:{try registry.save($0)})
            let challenge=try enrollment.begin(reg,now:1)
            _=try enrollment.approve(browser:browser,nonce:challenge.nonce,displayedFingerprint:challenge.fingerprint,displayedAppFingerprint:challenge.appFingerprint,possessionSignature:ext.signature(for:challenge.signedBytes).rawRepresentation,now:2)
            rejects("configuration requires human review"){_ = try setup.reviewConfiguration(registration:reg,relayDirectory:dir,deployment:deployment,nativeHumanConfirmed:false)}
            let config=try setup.reviewConfiguration(registration:reg,relayDirectory:dir,deployment:deployment,nativeHumanConfirmed:true)
            check(try setup.reviewConfiguration(registration:reg,relayDirectory:dir,deployment:deployment,nativeHumanConfirmed:true)==config,"matching config reused")
            let resolved=try setup.resolve(browser:browser,expectedDeployment:deployment)
            check(!resolved.integrationValidated && !resolved.physicalDeviceValidated,"enrollment cannot validate")
            rejects("deployment mismatch"){_ = try setup.resolve(browser:browser,expectedDeployment:String(repeating:"e",count:64))}
            rejects("configuration changes require new review"){_ = try setup.reviewConfiguration(registration:reg,relayDirectory:dir,deployment:String(repeating:"e",count:64),nativeHumanConfirmed:true)}
            let diagnostic=MetadataDiagnosticSession(pins:resolved.pins,clientNonce:String(repeating:"b",count:32),deployment:deployment)!
            let request=try diagnostic.request(now:date),q=SignedMetadataFrame.decode(request)!
            var value=try JSONSerialization.jsonObject(with:Data(base64Encoded:q.payload)!) as! [String:Any]
            value["kind"]="diagnostic_ack";value["runtimeID"]=id;value["contentRead"]=false
            func response(_ key:P256.Signing.PrivateKey)throws->Data {
                try SignedMetadataFrame.sign(payload:JSONSerialization.data(withJSONObject:value),extensionID:id,clientNonce:q.clientNonce,sessionID:q.sessionID,sequence:q.sequence,direction:"extension-to-app",key:key,browser:browser)
            }
            let answer=try response(ext)
            check(diagnostic.accept(answer,now:date),"signed no-content ack")
            check(!diagnostic.accept(answer,now:date),"diagnostic ack one-use")
            rejects("transport alone not physical review"){try setup.recordValidation(browser:browser,expectedDeployment:deployment,request:request,response:answer,reviewedChecks:MetadataProductionSetup.requiredChecks,nativeHumanConfirmed:false,now:date)}
            rejects("missing physical checks"){try setup.recordValidation(browser:browser,expectedDeployment:deployment,request:request,response:answer,reviewedChecks:[],nativeHumanConfirmed:true,now:date)}
            rejects("forged diagnostic"){try setup.recordValidation(browser:browser,expectedDeployment:deployment,request:request,response:response(attacker),reviewedChecks:MetadataProductionSetup.requiredChecks,nativeHumanConfirmed:true,now:date)}
            rejects("stale diagnostic"){try setup.recordValidation(browser:browser,expectedDeployment:deployment,request:request,response:answer,reviewedChecks:MetadataProductionSetup.requiredChecks,nativeHumanConfirmed:true,now:date.addingTimeInterval(121))}
            try setup.recordValidation(browser:browser,expectedDeployment:deployment,request:request,response:answer,reviewedChecks:MetadataProductionSetup.requiredChecks,nativeHumanConfirmed:true,now:date)
            let validated=try setup.resolve(browser:browser,expectedDeployment:deployment,now:date)
            check(validated.integrationValidated && validated.physicalDeviceValidated,"signed fixture operator review resolved")
            let reopened=try MetadataProductionSetup(directory:dir,appKey:app)
            check(try reopened.resolve(browser:browser,expectedDeployment:deployment,now:date).physicalDeviceValidated,"durable signed fixture review")
            check(try !reopened.resolve(browser:browser,expectedDeployment:deployment,now:date.addingTimeInterval(31*86400)).physicalDeviceValidated,"review expires")
            let wrong=try MetadataProductionSetup(directory:dir,appKey:attacker)
            rejects("wrong app key"){_ = try wrong.resolve(browser:browser,expectedDeployment:deployment,now:date)}
            try Data("{}".utf8).write(to:dir.appendingPathComponent(browser.rawValue+"-validation.json"))
            check(try !setup.resolve(browser:browser,expectedDeployment:deployment,now:date).physicalDeviceValidated,"unsigned validation denied")
        }
        print("PASS \(count) production setup negatives/roundtrips; ephemeral keys and synthetic operator reviews only, no Keychain or real browser validation")
    }
}
