import Foundation
import CryptoKit
import BrowserBridge
import Darwin

func fail(_ value:String)->Never {FileHandle.standardError.write(Data((value+"\n").utf8));exit(1)}
func line(_ prompt:String)throws->String {
    print(prompt);guard isatty(STDIN_FILENO)==1,let value=readLine(),value.utf8.count<=4096 else {throw MetadataSetupError.unreviewed};return value
}
func output(_ value:Any)throws {print(String(data:try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),encoding:.utf8)!)}
let args=Array(CommandLine.arguments.dropFirst())
if args==["--help"] || args.isEmpty {
    print("BrowserBridgeSetup status|enroll --directory PATH --relay-directory PATH --service KEYCHAIN_SERVICE --browser chrome|safari --deployment SHA256")
    print("enroll requires an interactive human, existing private directories and exact build identity. Public registrations only; no capture, install or grants.")
    exit(0)
}
do {
    guard let command=args.first,["status","enroll"].contains(command),args.count==11 else {throw MetadataSetupError.invalid}
    var options:[String:String]=[:]
    for i in stride(from:1,to:args.count,by:2){guard options[args[i]]==nil else {throw MetadataSetupError.invalid};options[args[i]]=args[i+1]}
    guard Set(options.keys)==["--directory","--relay-directory","--service","--browser","--deployment"],
          let browser=MetadataBrowser(rawValue:options["--browser"]!),options["--directory"]!.hasPrefix("/"),options["--relay-directory"]!.hasPrefix("/") else {throw MetadataSetupError.invalid}
    let directory=URL(fileURLWithPath:options["--directory"]!,isDirectory:true),relay=URL(fileURLWithPath:options["--relay-directory"]!,isDirectory:true)
    let registry=try MetadataRegistrationFile(directory:directory)
    if command=="status" {
        let setup=try MetadataProductionSetup.existing(directory:directory,keychainService:options["--service"]!)
        let provider=try setup.resolve(browser:browser,expectedDeployment:options["--deployment"]!)
        try output(["status":provider.status,"browser":browser.rawValue,"extensionID":provider.pins.extensionID,"relayDirectory":provider.directory.path,"registrationFingerprint":provider.configuration.registrationFingerprint,"appFingerprint":provider.configuration.appFingerprint,"integrationValidated":provider.integrationValidated,"physicalDeviceValidated":provider.physicalDeviceValidated])
        exit(0)
    }
    guard try line("Prepare or reuse the native app key in service \(options["--service"]!). Type PREPARE to approve; no capture or installation follows.")=="PREPARE" else {throw MetadataSetupError.unreviewed}
    let key=try MetadataAppKeychain.loadOrCreate(service:options["--service"]!)
    let data=Data(try line("Paste the public registration from this browser extension's setup page:").utf8)
    let registration=try JSONDecoder().decode(MetadataRegistration.self,from:data)
    guard registration.browser==browser else {throw MetadataSetupError.invalid}
    let enrollment=MetadataEnrollment(appKey:key,load:{try registry.load(browser:$0,extensionID:$1)},save:{try registry.save($0)})
    let challenge=try enrollment.begin(registration,now:DispatchTime.now().uptimeNanoseconds)
    print("Compare app fingerprint: \(challenge.appFingerprint)")
    print("Compare extension fingerprint: \(challenge.fingerprint)")
    print("Paste this challenge into the extension setup. It expires in two minutes:")
    try output(["browser":browser.rawValue,"extensionID":registration.extensionID,"nonce":challenge.nonce,"fingerprint":challenge.fingerprint,"appFingerprint":challenge.appFingerprint,"appPublicKey":key.publicKey.x963Representation.base64EncodedString()])
    let proofData=Data(try line("Paste the extension's signed proof:").utf8)
    guard let proof=try JSONSerialization.jsonObject(with:proofData) as? [String:String],Set(proof.keys)==["nonce","fingerprint","appFingerprint","signature"],let signature=Data(base64Encoded:proof["signature"]!) else {throw MetadataSetupError.invalid}
    guard try line("Approve exact relay \(relay.path) and deployment \(options["--deployment"]!). Type the extension fingerprint to confirm:")==challenge.fingerprint else {enrollment.cancel(browser);throw MetadataSetupError.unreviewed}
    _=try enrollment.approve(browser:browser,nonce:proof["nonce"]!,displayedFingerprint:proof["fingerprint"]!,displayedAppFingerprint:proof["appFingerprint"]!,possessionSignature:signature,now:DispatchTime.now().uptimeNanoseconds)
    let setup=try MetadataProductionSetup(directory:directory,appKey:key)
    _=try setup.reviewConfiguration(registration:registration,relayDirectory:relay,deployment:options["--deployment"]!,nativeHumanConfirmed:true)
    try output(["status":"enrolled_validation_required","browser":browser.rawValue,"extensionID":registration.extensionID,"integrationValidated":false,"physicalDeviceValidated":false])
} catch {fail("Browser setup unavailable or unapproved: \(error). Existing keys and registrations were not reset.")}
