import Foundation
import CryptoKit
import BrowserDiagnostic
import BrowserBridge
import Darwin

// Isolated fixture ONLY. Ephemeral keys and public setup files under caller's temp directory.
// No production key lookup, validation receipt, page data or service.
func configuration(_ directory:URL,_ browser:String,_ ext:P256.Signing.PublicKey)throws->(DiagnosticConfiguration,P256.Signing.PrivateKey) {
    let app=P256.Signing.PrivateKey()
    let id=browser=="chrome" ? String(repeating:"a",count:32) : "com.daydream.diagnostic.fixture"
    let b=MetadataBrowser(rawValue:browser)!
    let registration=try MetadataRegistration(browser:b,extensionID:id,publicKey:ext.x963Representation)
    try MetadataRegistrationFile(directory:directory).save(registration)
    let setup=try MetadataProductionSetup(directory:directory,appKey:app)
    _ = try setup.reviewConfiguration(registration:registration,relayDirectory:directory,
        deployment:String(repeating:"d",count:64),nativeHumanConfirmed:true)
    let c=try DiagnosticConfiguration.load(setupDirectory:directory,diagnosticDirectory:directory,browser:browser,
        extensionID:id,deployment:String(repeating:"d",count:64),trustedAppPublicKey:app.publicKey.x963Representation)
    let resolved=try setup.resolve(browser:b,expectedDeployment:c.binding.deployment)
    precondition(!resolved.integrationValidated && !resolved.physicalDeviceValidated)
    return (c,app)
}
func emit(_ value:[String:Any])throws {
    let data=try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
    print(String(decoding:data,as:UTF8.self));fflush(stdout)
}
func serve(_ directory:URL,_ browser:String)throws {
    guard let line=readLine(),let data=Data(base64Encoded:line) else {throw DiagnosticError.invalid}
    let ext=try P256.Signing.PublicKey(x963Representation:data),(c,app)=try configuration(directory,browser,ext)
    let endpoint=try DiagnosticEndpoint(configuration:c,appKey:app,configurationIsCurrent:{
        (try? DiagnosticConfiguration.load(setupDirectory:directory,diagnosticDirectory:directory,browser:browser,
            extensionID:c.binding.extensionID,deployment:c.binding.deployment,
            trustedAppPublicKey:app.publicKey.x963Representation).binding)==c.binding
    })
    try emit(["ticket":try JSONSerialization.jsonObject(with:DiagnosticFrame.encode(endpoint.attempt.ticket)),
              "appPublicKey":app.publicKey.x963Representation.base64EncodedString(),
              "extensionID":c.binding.extensionID,"deployment":c.binding.deployment])
    DispatchQueue.global().async {if readLine()=="cancel" {endpoint.cancel()}}
    do {let result=try endpoint.run();try emit(["status":result])}
    catch {try emit(["status":"rejected"])}
}
var count=0
func check(_ condition:Bool,_ name:String) {precondition(condition,name);count+=1}
func denies(_ name:String,_ action:()throws->Void) {
    do{try action();fatalError("accepted "+name)}catch{count+=1}
}
func checks()throws {
    let app=P256.Signing.PrivateKey(),ext=P256.Signing.PrivateKey(),wrong=P256.Signing.PrivateKey()
    let binding=try DiagnosticBinding(browser:"chrome",extensionID:String(repeating:"a",count:32),
        appFingerprint:DiagnosticBinding.digest(app.publicKey.x963Representation),
        extensionFingerprint:DiagnosticBinding.extensionDigest(browser:"chrome",extensionID:String(repeating:"a",count:32),key:ext.publicKey.x963Representation),
        deployment:String(repeating:"d",count:64),configuration:String(repeating:"c",count:64))
    func make(_ wall:@escaping()->Int64={1000},_ mono:@escaping()->UInt64={1000})throws->DiagnosticAttempt {
        try DiagnosticAttempt(binding:binding,appKey:app,extensionKey:ext.publicKey,wall:wall,monotonic:mono)
    }
    func request(_ a:DiagnosticAttempt,_ kind:String="hello",_ key:P256.Signing.PrivateKey?=nil,_ nonce:String=String(repeating:"b",count:32),_ attempt:String?=nil)throws->Data {
        try DiagnosticFrame.encode(DiagnosticFrame.sign(kind:kind,binding:binding,attemptID:attempt ?? a.ticket.attemptID,
            clientNonce:nonce,expiresAt:a.ticket.expiresAt,key:key ?? ext))
    }
    for kind in ["probe","Probe","metadata_hello","observation","policy","ticket","receipt","ack"] {
        let a=try make();denies(kind){_ = try a.receive(request(a,kind))}
    }
    do {
        let a=try make(),hello=try request(a)
        let challenge=try DiagnosticFrame.decode(a.receive(hello))
        check(challenge.kind=="challenge","challenge")
        try challenge.verify(app.publicKey,now:1000)
        let receipt=try DiagnosticFrame.decode(a.receive(request(a,"ack")))
        check(receipt.kind=="receipt" && a.acknowledged,"ack")
        denies("ack replay"){_ = try a.receive(request(a,"ack"))}
    }
    do {let a=try make();_ = try a.receive(request(a));denies("hello replay"){_ = try a.receive(request(a))}}
    do {let a=try make();denies("wrong key"){_ = try a.receive(request(a,"hello",wrong))}}
    do {let a=try make();denies("app key cannot pose as extension"){_ = try a.receive(request(a,"hello",app))}}
    do {let a=try make();a.cancel();denies("cancel"){_ = try a.receive(request(a))}}
    do {let a=try make(),old=try request(a),new=try make();denies("restart"){_ = try new.receive(old)}}
    do {let a=try make();_ = try a.receive(request(a));denies("nonce race"){_ = try a.receive(request(a,"ack",nil,String(repeating:"e",count:32)))}}
    var wall:Int64=1000
    do {let a=try make({wall});wall=32000;denies("expired"){_ = try a.receive(request(a))}}
    var mono:UInt64=1000
    do {let a=try make({1000},{mono});mono=31_000_001_000;denies("monotonic expiry"){_ = try a.receive(request(a))}}
    for property in ["url","text","tabID","integrationValidated","physicalDeviceValidated"] {
        let a=try make()
        var object=try JSONSerialization.jsonObject(with:request(a)) as! [String:Any];object[property]=true
        let data=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes])
        denies("extra "+property){_ = try a.receive(data)}
    }
    do {let a=try make();denies("size"){_ = try a.receive(Data(repeating:65,count:4097))}}
    do {let a=try make();denies("malformed"){_ = try a.receive(Data("{".utf8))}}
    do {let a=try make(),raw=try request(a);var s=String(decoding:raw,as:UTF8.self);s.insert(contentsOf:"\"kind\":\"hello\",",at:s.index(after:s.startIndex));denies("duplicate"){_ = try a.receive(Data(s.utf8))}}
    try emit(["checks":count,"status":"passed","scope":"ephemeral diagnostic protocol"])
}
do {
    let args=Array(CommandLine.arguments.dropFirst())
    if args==["--checks"] {try checks()}
    else if args.count==3,args[0]=="--serve",args[1].hasPrefix("/"),["chrome","safari"].contains(args[2]) {
        try serve(URL(fileURLWithPath:args[1]),args[2])
    } else if args.count==6,args[0]=="--exchange",let key=Data(base64Encoded:args[5]) {
        let id=args[2]=="chrome" ? String(repeating:"a",count:32) : "com.daydream.diagnostic.fixture"
        let c=try DiagnosticConfiguration.load(setupDirectory:URL(fileURLWithPath:args[1]),diagnosticDirectory:URL(fileURLWithPath:args[1]),
            browser:args[2],extensionID:id,deployment:args[3],trustedAppPublicKey:key)
        let end=DispatchTime.now().uptimeNanoseconds+2_000_000_000
        try DiagnosticWire.write(DiagnosticHost.exchange(DiagnosticWire.read(STDIN_FILENO,deadline:end),configuration:c),to:STDOUT_FILENO,deadline:end)
    } else {throw DiagnosticError.invalid}
} catch {fputs("diagnostic_fixture_rejected: "+String(describing:error)+"\n",stderr);exit(1)}
