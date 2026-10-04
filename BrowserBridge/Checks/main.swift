import Foundation
import BrowserBridge

var checks=0
func check(_ condition:Bool,_ label:String) {
    if !condition {fatalError("Synthetic bridge check failed: \(label)")};checks+=1
}
let id=String(repeating:"a",count:32),document="11111111-1111-4111-8111-111111111111",focus="22222222-2222-4222-8222-222222222222"
let peer=NativePeer(extensionID:id,callerOrigin:"chrome-extension://\(id)/",browserBundle:"com.google.Chrome",verifiedLaunchIdentity:true)
func policy()->BridgePolicy {var p=BridgePolicy();p.metadataConsent=true;p.integrationValidated=true;p.physicalDeviceValidated=true;p.allowedOrigins=["https://example.test"];return p}
func preflight(_ now:UInt64)->NativePreflight {var p=NativePreflight();p.frontmostChrome=true;p.normalWindow=true;p.secureInputOff=true;p.permissionPresent=true;p.checkedAt=now;return p}
func witness(_ now:UInt64)->NativeWitness {var w=NativeWitness();w.preflight=preflight(now);w.nativeWindowID="native-window";w.nativeFocusID="native-focus";w.windowMappingVerified=true;w.focusMappingVerified=true;w.windowID=3;w.tabID=9;w.frameID=0;w.documentID=document;w.focusID=focus;w.role="AXButton";return w}
func payload(_ request:Probe,_ changes:[String:Any]=[:])->Data {
    var e:[String:Any]=["version":1,"kind":"observation","nonce":request.nonce,"policyRevision":request.policyRevision,
        "windowMode":"normal","tabMode":"normal","windowID":3,"tabID":9,"frameID":0,"documentID":document,
        "navigationGeneration":1,"focusID":focus,"focusGeneration":1,"role":"button","safety":"noneditable","origin":"https://example.test","textEnabled":false]
    e.merge(changes,uniquingKeysWith:{$1});return try! JSONSerialization.data(withJSONObject:e)
}
func receiver()->BrowserReceiver {let r=BrowserReceiver(extensionID:id);check(r.connect(peer),"trusted synthetic peer connected");return r}

// This is a test executable only, not the host product. Fixed fake native
// identities must agree with the JS fixture; no authority is copied from JSON.
if CommandLine.arguments.contains("--wire-fixture") {
    let hello=try NativeFrames.read(from:.standardInput) ?? Data()
    let h=try JSONSerialization.jsonObject(with:hello) as? [String:Any]
    guard h?["kind"] as? String == "hello",h?["extensionID"] as? String == id,h?["textEnabled"] as? Bool == false else {exit(2)}
    let wire=BrowserReceiver(extensionID:id);guard wire.connect(peer) else {exit(2)}
    let req=wire.request(policy:policy(),preflight:preflight(0),now:0)!
    try FileHandle.standardOutput.write(contentsOf:NativeFrames.encode(JSONEncoder().encode(req)))
    let data=try NativeFrames.read(from:.standardInput) ?? Data()
    let accepted=wire.receive(data,policy:policy(),witness:witness(500_000_000),now:500_000_000,privacyAllowsMetadata:{_ in true})
    let reply=try JSONSerialization.data(withJSONObject:["accepted":accepted != nil,"kind":accepted?.kind ?? "denied","textEnabled":wire.textEnabled])
    try FileHandle.standardOutput.write(contentsOf:NativeFrames.encode(reply));exit(accepted == nil ? 1:0)
}

let r=receiver();check(!r.textEnabled,"browser typing stays off")
check(r.request(policy:BridgePolicy(),preflight:preflight(0),now:0)==nil,"default policy disabled")
for setting in [0,1,2] {var p=policy();if setting==0 {p.metadataConsent=false};if setting==1 {p.integrationValidated=false};if setting==2 {p.physicalDeviceValidated=false};check(receiver().request(policy:p,preflight:preflight(0),now:0)==nil,"separate release gates")}
for invalid in [NativePeer(extensionID:"page",callerOrigin:"https://example.test",browserBundle:"com.google.Chrome",verifiedLaunchIdentity:true),
 NativePeer(extensionID:id,callerOrigin:"chrome-extension://\(id)/",browserBundle:"org.mozilla.firefox",verifiedLaunchIdentity:true),
 NativePeer(extensionID:id,callerOrigin:"chrome-extension://\(id)/",browserBundle:"com.google.Chrome",verifiedLaunchIdentity:false),
 NativePeer(extensionID:id,callerOrigin:"chrome-extension://\(String(repeating:"b",count:32))/",browserBundle:"com.google.Chrome",verifiedLaunchIdentity:true)] {
 check(!BrowserReceiver(extensionID:id).connect(invalid),"invalid sender or unsupported browser")
}
for field in [0,1,2,3] {var p=preflight(0);if field==0{p.normalWindow=false};if field==1{p.secureInputOff=false};if field==2{p.permissionPresent=false};if field==3{p.frontmostChrome=false};check(receiver().request(policy:policy(),preflight:p,now:0)==nil,"native preflight prevents DOM request")}
let valid=receiver(),p=policy(),q=valid.request(policy:p,preflight:preflight(0),now:0)!
let accepted=valid.receive(payload(q),policy:p,witness:witness(0),now:0,privacyAllowsMetadata:{_ in true})
check(accepted?.kind=="browser.observed","verified metadata observation")
check(accepted?.origin=="https://example.test","origin only")
check(valid.receive(payload(q),policy:p,witness:witness(0),now:0,privacyAllowsMetadata:{_ in true})==nil,"nonce replay denied")
for changes:[String:Any] in [["text":"must-not-persist"],["textEnabled":true],["title":"private-title"],["kind":"sent"],["kind":"draft"],
 ["windowMode":"private"],["tabMode":"unknown"],["documentID":""],["frameID":1],["role":"textbox"],["safety":"unknown"],
 ["origin":"https://example.test/?q=secret"],["origin":"https://example.test/path"],["origin":"https://other.test"],["navigationGeneration":0],
 ["nonce":"forged"],["policyRevision":2]] {
 let a=receiver(),req=a.request(policy:p,preflight:preflight(0),now:0)!
 check(a.receive(payload(req,changes),policy:p,witness:witness(0),now:0,privacyAllowsMetadata:{_ in true})==nil,"malformed/unsafe payload rejected")
}
for change in 0..<8 {
 let a=receiver(),req=a.request(policy:p,preflight:preflight(0),now:0)!;var w=witness(0),pol=p;var now:UInt64=0
 switch change {case 0:w.windowMappingVerified=false;case 1:w.focusMappingVerified=false;case 2:w.documentID="other";case 3:w.preflight.normalWindow=false;case 4:w.preflight.secureInputOff=false;case 5:pol.revision+=1;case 6:now=1_000_000_001;default:w.role="AXTextField"}
 check(a.receive(payload(req),policy:pol,witness:w,now:now,privacyAllowsMetadata:{_ in true})==nil,"fresh independent native corroboration mandatory")
}
let deny=receiver(),dq=deny.request(policy:p,preflight:preflight(0),now:0)!
check(deny.receive(payload(dq),policy:p,witness:witness(0),now:0,privacyAllowsMetadata:{_ in false})==nil,"Phone privacy policy can veto")
// Ten seconds is measured on native monotonic receipt times, never claimed by a page.
let visits=receiver();var kinds:[String]=[]
for second in 0...12 {let now=UInt64(second)*1_000_000_000,req=visits.request(policy:p,preflight:preflight(now),now:now)!
 let value=visits.receive(payload(req),policy:p,witness:witness(now),now:now,privacyAllowsMetadata:{_ in true})!;kinds.append(value.kind)
 if second<10 {check(value.kind=="browser.observed","less than 10s not visited")}}
check(kinds.filter{$0=="browser.tab_visited"}.count==1 && kinds[10]=="browser.tab_visited","one visit at ten continuous seconds")
var now:UInt64=15_000_000_000
let gap=visits.request(policy:p,preflight:preflight(now),now:now)!
check(visits.receive(payload(gap),policy:p,witness:witness(now),now:now,privacyAllowsMetadata:{_ in true})?.continuousNanoseconds==0,"missing heartbeat resets visit duration")
now+=1_000_000_000;let nav=visits.request(policy:p,preflight:preflight(now),now:now)!
check(visits.receive(payload(nav,["navigationGeneration":2]),policy:p,witness:witness(now),now:now,privacyAllowsMetadata:{_ in true})?.continuousNanoseconds==0,"redirect generation resets visit")
now+=1_000_000_000;let old=visits.request(policy:p,preflight:preflight(now),now:now)!
check(visits.receive(payload(old),policy:p,witness:witness(now),now:now,privacyAllowsMetadata:{_ in true})==nil,"old generation denied")
visits.disconnect();check(visits.receive(payload(old),policy:p,witness:witness(now),now:now,privacyAllowsMetadata:{_ in true})==nil,"disconnect removes authority")
check(visits.connect(peer),"reconnect requires peer verification")
let restart=visits.request(policy:p,preflight:preflight(now),now:now)!
check(visits.receive(payload(restart),policy:p,witness:witness(now),now:now,privacyAllowsMetadata:{_ in true})?.continuousNanoseconds==0,"new connection starts new visit")
for raw in ["https://user:secret@example.test","https://example.test/","https://example.test?q=secret","https://example.test#secret","file:///tmp/x"] {check(!BrowserReceiver.originOnly(raw),"unsafe origin rejected")}
let bytes=Data("{}".utf8),framed=try NativeFrames.encode(bytes);check(framed.count==6,"native frame byte count")
let pipe=Pipe();try pipe.fileHandleForWriting.write(contentsOf:framed);try pipe.fileHandleForWriting.close()
check(try NativeFrames.read(from:pipe.fileHandleForReading)==bytes,"native frame roundtrip")
check(try NativeFrames.read(from:pipe.fileHandleForReading)==nil,"clean EOF")
let oversized=Pipe();var size:UInt32=4097
try oversized.fileHandleForWriting.write(contentsOf:withUnsafeBytes(of:&size){Data($0)});try oversized.fileHandleForWriting.close()
do {_=try NativeFrames.read(from:oversized.fileHandleForReading);check(false,"oversize rejected")}catch {check(true,"oversize header rejected without payload")}
let truncated=Pipe();try truncated.fileHandleForWriting.write(contentsOf:framed.prefix(5));try truncated.fileHandleForWriting.close()
do {_=try NativeFrames.read(from:truncated.fileHandleForReading);check(false,"truncation rejected")}catch {check(true,"partial payload rejected")}
print("BrowserBridge: \(checks) synthetic native checks passed. No device capture, text, permissions, installation or core integration.")
