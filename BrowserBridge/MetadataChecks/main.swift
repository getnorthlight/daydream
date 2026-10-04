// Synthetic executable only. Never packaged as the production native host.
import Foundation
import CryptoKit
import BrowserBridge
import Darwin

let extensionID = String(repeating: "a", count: 32)
let clientNonce = String(repeating: "b", count: 32)
func policy() -> BridgePolicy {
    var p = BridgePolicy(); p.metadataConsent = true; p.integrationValidated = true
    p.physicalDeviceValidated = true; p.allowedOrigins = ["https://example.test"]; return p
}
func gate(_ now: UInt64) -> MetadataGate {
    var g = MetadataGate(); g.frontmostChrome = true; g.secureInputOff = true; g.permissionPresent = true
    g.captureEnabled = true; g.excluded = false; g.generation = 1; g.checkedAt = now; return g
}
func observation(_ request: Data) -> [String: Any] {
    let envelope = SignedMetadataFrame.decode(request)!
    let p = try! JSONSerialization.jsonObject(with: Data(base64Encoded: envelope.payload)!) as! [String: Any]
    return ["version":1,"kind":"observation","nonce":p["nonce"]!,"policyRevision":1,
        "windowMode":"normal","tabMode":"normal","windowID":3,"tabID":9,"frameID":0,
        "documentID":"11111111-1111-4111-8111-111111111111","navigationGeneration":1,
        "focusID":"22222222-2222-4222-8222-222222222222","focusGeneration":1,
        "role":"button","safety":"noneditable","origin":"https://example.test","textEnabled":false]
}
func response(_ request: Data, key: P256.Signing.PrivateKey, mutate: (inout [String:Any]) -> Void = {_ in}) -> Data {
    let f = SignedMetadataFrame.decode(request)!
    var e = observation(request); mutate(&e)
    return try! SignedMetadataFrame.sign(payload: JSONSerialization.data(withJSONObject: e), extensionID: f.extensionID,
        clientNonce: f.clientNonce, sessionID: f.sessionID, sequence: f.sequence, direction: "extension-to-app", key: key, browser: f.browser)
}
func send(_ data: Data) throws { try FileHandle.standardOutput.write(contentsOf: NativeFrames.encode(data)) }

if CommandLine.arguments.contains("--synthetic-wire") {
    // Public test registration comes over fixture pipes only; never a runtime
    // enrollment path. Production host does not link or invoke this executable.
    let setup = try JSONSerialization.jsonObject(with: NativeFrames.read(from: .standardInput)!) as! [String: String]
    let appKey = P256.Signing.PrivateKey()
    let publicKey = try P256.Signing.PublicKey(x963Representation: Data(base64Encoded: setup["extensionPublicKey"]!)!)
    let browser = MetadataBrowser(rawValue:setup["browser"] ?? "chrome")!
    let session = AuthenticatedMetadataSession(pins: MetadataPins(extensionID: setup["extensionID"] ?? extensionID, extensionKey: publicKey, appKey: appKey, browser:browser), clientNonce: setup["clientNonce"]!)!
    try send(JSONSerialization.data(withJSONObject: ["appPublicKey":appKey.publicKey.x963Representation.base64EncodedString()]))
    let now: UInt64 = 1_000_000_000, p = policy();var g = gate(now);g.frontmostBrowserBundle=browser.bundle
    let request = session.request(policy:p, gate:g, now:now, privacyAllowsOrigins:{_ in true})!
    try send(request)
    let reply = try NativeFrames.read(from:.standardInput)!
    let accepted = session.receive(reply, policy:p, gate:g, now:now, privacyAllowsMetadata:{_ in true})
    let replay = session.receive(reply, policy:p, gate:g, now:now, privacyAllowsMetadata:{_ in true})
    try send(JSONSerialization.data(withJSONObject: ["accepted":accepted != nil,"replayDenied":replay == nil,
        "kind":accepted?.kind ?? "denied", "textEnabled":session.textEnabled]))
    exit(accepted != nil && replay == nil ? 0 : 1)
}

var checks = 0
func check(_ value: Bool, _ name: String) { precondition(value, name); checks += 1 }
let appKey = P256.Signing.PrivateKey(), extKey = P256.Signing.PrivateKey(), attacker = P256.Signing.PrivateKey()
let pins = MetadataPins(extensionID:extensionID,extensionKey:extKey.publicKey,appKey:appKey)
let now:UInt64 = 1_000_000_000, p = policy(), g = gate(now)
func fresh() -> AuthenticatedMetadataSession { AuthenticatedMetadataSession(pins:pins,clientNonce:clientNonce)! }
func request(_ s: AuthenticatedMetadataSession) -> Data { s.request(policy:p,gate:g,now:now,privacyAllowsOrigins:{_ in true})! }

let good=fresh(), q=request(good), answer=response(q,key:extKey)
let event=good.receive(answer,policy:p,gate:g,now:now,privacyAllowsMetadata:{_ in true})
check(event?.kind == "browser.extension_observed", "browser-owned positive, no native ID join")
check(!good.textEnabled, "typing always OFF")
check(good.receive(answer,policy:p,gate:g,now:now,privacyAllowsMetadata:{_ in true}) == nil,"replay")
for mutation in [ ["windowMode":"private"], ["tabMode":"private"], ["documentID":"unknown"], ["role":"textbox"],
                  ["safety":"sensitive"], ["origin":"https://example.test/?secret=x"], ["text":"forbidden"],
                  ["kind":"sent"], ["focusID":"unknown"] ] {
    let s=fresh(), r=request(s)
    let a=response(r,key:extKey) { value in for (key,item) in mutation {value[key]=item} }
    check(s.receive(a,policy:p,gate:g,now:now,privacyAllowsMetadata:{_ in true}) == nil,"strict observation denies \(mutation.keys)")
}
let invalid=fresh(), invalidRequest=request(invalid)
check(invalid.receive(response(invalidRequest,key:attacker),policy:p,gate:g,now:now,privacyAllowsMetadata:{_ in true}) == nil,"wrong signing key")
let other=fresh();_ = request(other)
check(other.receive(answer,policy:p,gate:g,now:now,privacyAllowsMetadata:{_ in true}) == nil,"other session")
for mismatch in ["direction","client","extension","sequence","payload"] {
    let s=fresh(), r=request(s), f=SignedMetadataFrame.decode(r)!
    var reply=try! SignedMetadataFrame.sign(payload:JSONSerialization.data(withJSONObject:observation(r)),
        extensionID:mismatch == "extension" ? String(repeating:"e",count:32) : extensionID,
        clientNonce:mismatch == "client" ? String(repeating:"f",count:32) : clientNonce,
        sessionID:f.sessionID,sequence:mismatch == "sequence" ? f.sequence+1 : f.sequence,
        direction:mismatch == "direction" ? "app-to-extension" : "extension-to-app",key:extKey)
    if mismatch == "payload" {
        var json=try! JSONSerialization.jsonObject(with:reply) as! [String:Any]
        json["payload"]=Data("{}".utf8).base64EncodedString();reply=try! JSONSerialization.data(withJSONObject:json)
    }
    check(s.receive(reply,policy:p,gate:g,now:now,privacyAllowsMetadata:{_ in true}) == nil,"signed envelope binding \(mismatch)")
}
for field in ["generation","excluded","permission","secure","chrome","enabled","stale"] {
    let s=fresh(), r=request(s);var changed=g
    switch field {case "generation":changed.generation+=1;case "excluded":changed.excluded=true
    case "permission":changed.permissionPresent=false;case "secure":changed.secureInputOff=false
    case "chrome":changed.frontmostChrome=false;case "enabled":changed.captureEnabled=false
    default:changed.checkedAt=0}
    check(s.receive(response(r,key:extKey),policy:p,gate:changed,now:now,privacyAllowsMetadata:{_ in true}) == nil,"fresh gate \(field)")
    check(fresh().request(policy:p,gate:changed,now:now,privacyAllowsOrigins:{_ in true}) == nil || field == "generation","pre-acquisition gate \(field)")
}
let blocked=fresh();check(blocked.request(policy:p,gate:g,now:now,privacyAllowsOrigins:{_ in false}) == nil,"privacy before request")
let finalGate=fresh(), finalRequest=request(finalGate)
check(finalGate.receive(response(finalRequest,key:extKey),policy:p,gate:g,now:now,privacyAllowsMetadata:{_ in false}) == nil,"privacy at acceptance")
let timeout=fresh(), tq=request(timeout)
check(timeout.receive(response(tq,key:extKey),policy:p,gate:gate(now+2_000_000_000),now:now+2_000_000_000,privacyAllowsMetadata:{_ in true}) == nil,"deadline")
let disconnected=fresh(), dq=request(disconnected);disconnected.close()
check(disconnected.receive(response(dq,key:extKey),policy:p,gate:g,now:now,privacyAllowsMetadata:{_ in true}) == nil,"disconnect discards")
check(disconnected.request(policy:p,gate:g,now:now,privacyAllowsOrigins:{_ in true}) == nil,"closed cannot reconnect")
let changedPolicy=fresh(), pq=request(changedPolicy);var p2=p;p2.revision+=1
check(changedPolicy.receive(response(pq,key:extKey),policy:p2,gate:g,now:now,privacyAllowsMetadata:{_ in true}) == nil,"policy changed")
let inactive=fresh();check(inactive.request(policy:BridgePolicy(),gate:g,now:now,privacyAllowsOrigins:{_ in true}) == nil,"default disabled")
let overlap=fresh();_ = request(overlap)
check(overlap.request(policy:p,gate:g,now:now+1,privacyAllowsOrigins:{_ in true}) == nil,"no overlap")
let visiting=fresh();var visits=0
for index in 0...22 {
    let time=now+UInt64(index)*500_000_000, current=gate(time)
    let r=visiting.request(policy:p,gate:current,now:time,privacyAllowsOrigins:{_ in true})!
    let e=visiting.receive(response(r,key:extKey),policy:p,gate:current,now:time,privacyAllowsMetadata:{_ in true})!
    if e.kind == "browser.extension_tab_visited" {visits+=1}
}
check(visits==1,"one ten-second continuous visit")
visiting.invalidate()
let later=now+20_000_000_000, laterGate=gate(later)
let vq=visiting.request(policy:p,gate:laterGate,now:later,privacyAllowsOrigins:{_ in true})!
check(visiting.receive(response(vq,key:extKey),policy:p,gate:laterGate,now:later,privacyAllowsMetadata:{_ in true})?.continuousNanoseconds==0,"invalidation resets visit")
check(SignedMetadataFrame.decode(Data(repeating:65,count:4097)) == nil,"bounded decoder")
for browser in [MetadataBrowser.chrome,.safari] {
    let id=browser == .chrome ? extensionID : "com.daydream.browser.fixture"
    let browserPins=MetadataPins(extensionID:id,extensionKey:extKey.publicKey,appKey:appKey,browser:browser)
    var active=gate(now);active.frontmostBrowserBundle=browser.bundle
    let s=AuthenticatedMetadataSession(pins:browserPins,clientNonce:clientNonce)!
    let ordinary=BridgePolicy.masterRecording(true,integrationValidated:true,physicalDeviceValidated:true,revision:1,excludedDomains:["excluded.test"])
    let r=s.request(policy:ordinary,gate:active,now:now,privacyAllowsOrigins:{_ in false},privacyAllowsOrdinaryMetadata:{true})!
    let e=s.receive(response(r,key:extKey){$0["role"]="document"},policy:ordinary,gate:active,now:now,privacyAllowsMetadata:{_ in true})
    check(e?.browser==browser && e?.observation.role=="document","ordinary safe page with master consent \(browser)")
    let wrong=AuthenticatedMetadataSession(pins:browserPins,clientNonce:clientNonce)!
    active.frontmostBrowserBundle=browser == .chrome ? MetadataBrowser.safari.bundle : MetadataBrowser.chrome.bundle
    check(wrong.request(policy:ordinary,gate:active,now:now,privacyAllowsOrigins:{_ in true},privacyAllowsOrdinaryMetadata:{true})==nil,"wrong foreground browser \(browser)")
}
let registryDir=FileManager.default.temporaryDirectory.appendingPathComponent("browser-enrollment-"+UUID().uuidString)
try FileManager.default.createDirectory(at:registryDir,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
let registry=try MetadataRegistrationFile(directory:registryDir)
let enrollment=MetadataEnrollment(appKey:appKey,load:{try registry.load(browser:$0,extensionID:$1)},save:{try registry.save($0)})
for browser in [MetadataBrowser.chrome,.safari] {
    let id=browser == .chrome ? extensionID : "com.daydream.browser.fixture"
    let registration=try MetadataRegistration(browser:browser,extensionID:id,publicKey:extKey.publicKey.x963Representation)
    let challenge=try enrollment.begin(registration,now:now)
    check(try enrollment.begin(registration,now:now).nonce==challenge.nonce,"pending enrollment reused")
    let signature=try extKey.signature(for:challenge.signedBytes).rawRepresentation
    let approved=try enrollment.approve(browser:browser,nonce:challenge.nonce,displayedFingerprint:challenge.fingerprint,displayedAppFingerprint:challenge.appFingerprint,possessionSignature:signature,now:now)
    check(approved.browser==browser,"enrollment approved only after proof")
    let reopened=try MetadataRegistrationFile(directory:registryDir)
    check(try reopened.load(browser:browser,extensionID:id)==registration,"durable public registration")
    do {_ = try enrollment.approve(browser:browser,nonce:challenge.nonce,displayedFingerprint:challenge.fingerprint,displayedAppFingerprint:challenge.appFingerprint,possessionSignature:signature,now:now);check(false,"enrollment replay accepted")}catch{check(true,"enrollment replay denied")}
    let changed=try MetadataRegistration(browser:browser,extensionID:id,publicKey:attacker.publicKey.x963Representation)
    do {_ = try enrollment.begin(changed,now:now);check(false,"changed pin accepted")}catch{check(true,"changed pin denied")}
    let retry=try enrollment.begin(registration,now:now);enrollment.cancel(browser)
    do {_ = try enrollment.approve(browser:browser,nonce:retry.nonce,displayedFingerprint:retry.fingerprint,displayedAppFingerprint:retry.appFingerprint,possessionSignature:signature,now:now);check(false,"cancel accepted")}catch{check(true,"cancel denied")}
    for failure in ["expired","fingerprint","appFingerprint","nonce","forgedProof"] {
        let held=try enrollment.begin(registration,now:now)
        let signer=failure == "forgedProof" ? attacker : extKey
        let proof=try signer.signature(for:held.signedBytes).rawRepresentation
        do {
            _ = try enrollment.approve(browser:browser,
                nonce:failure == "nonce" ? UUID().uuidString.lowercased() : held.nonce,
                displayedFingerprint:failure == "fingerprint" ? String(repeating:"0",count:64) : held.fingerprint,
                displayedAppFingerprint:failure == "appFingerprint" ? String(repeating:"0",count:64) : held.appFingerprint,
                possessionSignature:proof,now:failure == "expired" ? held.expiresAt : now)
            check(false,"enrollment \(failure) accepted \(browser)")
        } catch {check(true,"enrollment \(failure) denied \(browser)")}
    }
}
var input:[Int32]=[0,0],output:[Int32]=[0,0];precondition(pipe(&input)==0 && pipe(&output)==0)
let deadline=DispatchTime.now().uptimeNanoseconds+1_000_000_000
try MetadataRelay.writeFrame(answer,to:input[1],deadline:deadline)
try MetadataRelay.forward(from:input[0],to:output[1],deadline:deadline)
check(try MetadataRelay.readFrame(output[0],deadline:deadline)==answer,"real pipe relay preserves signed frame")
do {_ = try MetadataRelay.readFrame(input[0],deadline:DispatchTime.now().uptimeNanoseconds+10_000_000);check(false,"idle read did not expire")}catch{check(true,"bounded idle read")}
Darwin.close(output[0]);do {try MetadataRelay.writeFrame(answer,to:output[1],deadline:deadline);check(false,"closed peer accepted")}catch{check(true,"disconnect rejects without SIGPIPE")}
for fd in [input[0],input[1],output[1]] {Darwin.close(fd)}
print("PASS \(checks) authenticated metadata Swift checks")
