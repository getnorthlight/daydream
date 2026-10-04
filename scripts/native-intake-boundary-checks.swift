import Foundation
import ApplicationServices
import HistoryCore
import MemoryCore
import PrivacyPolicy

// Production EventCapture -> CoreCaptureBinding -> sealed store, controlled
// metadata and characters only. Not OS-event/AX notification delivery evidence.
@main struct NativeBoundaryChecks {
 static var pass=0,fail=0
 static func main() throws {
  for mode in 0..<36 {try scenario(mode)}
  print("TOTAL \(pass) PASS \(fail) FAIL")
  if fail>0 {exit(1)}
 }
 static func check(_ ok:Bool,_ name:String){print("\(ok ? "PASS":"FAIL") "+name);if ok{pass+=1}else{fail+=1}}
 static func scenario(_ mode:Int) throws {
  let home=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("case-\(mode)")
  let store=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false)
  let keys=InMemoryTypedKeyStore()
  try store.attachVault(TypedTextVault(keyStore:keys));try store.setUpTypedVault();try store.acceptSafeTyping()
  var policy=try store.policy();policy.captureText=true;policy.typedConsentVersion=1;try store.updatePolicy(policy)
  let coordinator=try Coordinator(store:store,permissions:{true}) {}
  var committed=[NativeCaptureReceipt]()
  coordinator.onNativeCommitted={if $0.path == .typedText {committed.append($0)}}
  try coordinator.start();coordinator.captureText=true
  var mono:UInt64=10_000_000_000,field="A",reads=0,known=true,secure=false,proofCalls=0,flipAt=0
  var timers:[(UInt64,()->Void)]=[]
  let env=EventCapture.TypingEnvironment(now:{mono},proof:{generation,version in
   proofCalls+=1;if proofCalls==flipAt{field="C"}
   guard known else{return nil}
   var p=FocusProof();p.bundle="com.apple.TextEdit";p.windowID="owned-"+field;p.focusID="field-"+field;p.role="AXTextArea";p.place="Fictional scratch"
   p.generation=generation;p.policyVersion=version;p.checkedAt=mono;p.surface = .native
   p.secureInput = secure ? .yes:.no;p.privateMode = .no;p.verified=true;p.fieldStateVerified=true;p.frameAccessible=true;p.navigationStable=true
   return p
  },schedule:{delay,work in timers.append((mono+UInt64(delay*1_000_000_000),work))},secureInput:{secure},departure:{DepartureState(secureInput:secure ? .yes:.no,bundle:"com.apple.TextEdit",focusSecure:.no)},pressAndHold:{false})
  let capture=EventCapture(coordinator:coordinator,typingEnvironment:env)
  func advance(_ seconds:Double){
   let target=mono+UInt64(seconds*1_000_000_000)
   while let i=timers.indices.filter({timers[$0].0<=target}).min(by:{timers[$0].0<timers[$1].0}) {let t=timers.remove(at:i);mono=max(mono,t.0);t.1()}
   mono=target
  }
  func type(_ text:String,eventAge:UInt64=0){for c in text{advance(0.08);capture.handleNativeKey(eventAt:mono-eventAge,stroke:KeyStroke(keyCode:c==" " ? 49:0)){reads+=1;return String(c)}}}
  type("alpha draft starts")
  field="B";capture.handleAX(kAXFocusedWindowChangedNotification);advance(0.5)
  type("beta draft stays separate")
  field="A";capture.handleAX(kAXFocusedWindowChangedNotification);advance(0.5)
  if mode==22 {capture.sealTyping(.focusKey,focusMoved:true)}
  if mode==23 {_=coordinator.captureBinding.markLateCut()}
  if mode>=34 {advance(0.2)}
  type(mode == 33 ? String(repeating:" ",count:3) : mode == 12 ? "\t" : mode == 13 ? String(repeating:" ",count:17) : mode == 15 ? String(repeating:" ",count:16) : " ",eventAge:mode>=34 ? 100_000_000:0)
  if mode<24 || mode>=34 {capture.handleAX(kAXFocusedUIElementChangedNotification)}
  var expectsSpace=mode==0 || mode==1 || mode==33 || mode==35
  switch mode {
   case 1:advance(0.08);capture.handleAX(kAXFocusedWindowChangedNotification)
   case 2:advance(0.35);capture.handleAX(kAXFocusedWindowChangedNotification) // original deadline cannot renew
   case 3:advance(0.5)
   case 4:
    field="C";type("separate note.");capture.handleAX(kAXFocusedWindowChangedNotification);field="A";advance(0.05)
   case 5:
    known=false;capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:0)){reads+=1;return "unproven"}
    known=true
   case 6:
    secure=true;capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:0)){reads+=1;return "fictional protected"}
    secure=false;advance(0.6)
   case 7:coordinator.captureBinding.unproven(now:mono)
   case 8:capture.sealTyping(.gap,focusMoved:false)
   case 9:capture.sealTyping(.pointer,focusMoved:true);advance(0.5)
   case 10:coordinator.captureBinding.retract()
   case 11:
    var changed=try store.policy();changed.blockedApps.append("com.synthetic.unused");try store.updatePolicy(changed)
   case 14:advance(0.5)
   case 15:expectsSpace=true
   case 16:capture.sealTyping(.inputSource,focusMoved:true);advance(0.5)
   case 17:
    capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:48,command:true)){reads+=1;return "not acquired"}
    advance(0.5)
   case 18:
    capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:0)){reads+=1;return ""}
   case 19:
    capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:51)){reads+=1;return "not acquired"}
   case 20:
    flipAt=proofCalls+2
    capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:0)){reads+=1;return "not acquired"}
    field="A";flipAt=0
   case 21:
    capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:0)){reads+=1;return "\u{0001}"}
   case 24:
    known=false;capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:0)){reads+=1;return "not acquired"}
    known=true;capture.handleAX(kAXFocusedUIElementChangedNotification)
   case 25:
    flipAt=proofCalls+2
    capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:0)){reads+=1;return "not acquired"}
    field="A";flipAt=0;capture.handleAX(kAXFocusedUIElementChangedNotification)
   case 26:
    let context=try coordinator.captureBinding.context()
    var stale=FocusProof();stale.bundle="com.apple.TextEdit";stale.windowID="owned-A";stale.focusID="field-A";stale.role="AXTextArea";stale.place="Fictional scratch"
    stale.generation=context.generation;stale.policyVersion=context.policy.version;stale.checkedAt=mono-1_000_000_001;stale.surface = .native
    stale.secureInput = .no;stale.privateMode = .no;stale.verified=true;stale.fieldStateVerified=true;stale.frameAccessible=true;stale.navigationStable=true
    let step=try coordinator.captureBinding.insert(proof:stale,eventAt:mono,now:mono){reads+=1;return "not acquired"}
    check(step.decision.reason == .staleProof && step.decision.outcome == .unknown,"live nonprivacy refusal really reached stale-proof gate")
    capture.handleAX(kAXFocusedUIElementChangedNotification)
   case 27:
    let context=try coordinator.captureBinding.context()
    var p=FocusProof();p.bundle="com.apple.TextEdit";p.windowID="owned-A";p.focusID="field-A";p.role="AXTextArea";p.place="Fictional scratch"
    p.generation=context.generation;p.policyVersion=context.policy.version;p.checkedAt=mono;p.surface = .native
    p.secureInput = .no;p.privateMode = .no;p.verified=true;p.fieldStateVerified=true;p.frameAccessible=true;p.navigationStable=true
    _=try coordinator.captureBinding.insert(proof:p,eventAt:mono,now:mono,compositionFinal:false){reads+=1;return "not acquired"}
    capture.handleAX(kAXFocusedUIElementChangedNotification)
   case 28:
    capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:0)){reads+=1;return ""}
    capture.handleAX(kAXFocusedUIElementChangedNotification)
   case 29:
    capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:0)){reads+=1;return "\u{0001}"}
    capture.handleAX(kAXFocusedUIElementChangedNotification)
   case 30:
    secure=true;capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:0)){reads+=1;return "not acquired"}
    secure=false;capture.handleAX(kAXFocusedUIElementChangedNotification);advance(0.6)
   case 31:
    var changed=try store.policy();changed.blockedApps.append("com.synthetic.unused");try store.updatePolicy(changed)
    capture.handleAX(kAXFocusedUIElementChangedNotification)
   case 32:
    capture.sealTyping(.gap,focusMoved:false);capture.handleAX(kAXFocusedUIElementChangedNotification)
   case 33:
    capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:51)){reads+=1;return "not acquired"}
   case 34:advance(0.25)
   case 35:advance(0.15)
   default:break
  }
  // Whitespace/control/oversize negatives do not carry even on the same field.
  if mode==12 || mode==13 {expectsSpace=false}
  if mode==23 {type("a");coordinator.captureBinding.releaseLateCut();type("nd finishes here")}
  else if mode != 14 {type("and finishes here")}
  capture.commitPendingTyping()
  let actions=try committed.compactMap{try store.action($0.actionID)}
  check(actions.count==committed.count,"every production callback matches saved action case-\(mode)")
  let parts=try actions.map{a -> (String,String) in
    let e=try store.read(a.id)!.evidence
    let t=try store.hydrateTypedText(a.id,disclosure:.owner) ?? ""
    return (e.captureProvenance?.windowID ?? "",t)
  }
  let a=parts.filter{$0.0=="owned-A"}.map{$0.1}.joined()
  let b=parts.filter{$0.0=="owned-B"}.map{$0.1}.joined()
  let expectedA=mode == 14 ? "alpha draft starts" : "alpha draft starts"+(expectsSpace ? (mode == 15 ? String(repeating:" ",count:16) : mode == 33 ? "  " : " ") : "")+"and finishes here"
  let exactA=a==expectedA
  let exactB=b=="beta draft stays separate"
  check(exactA,"production sealed A boundary case-\(mode)")
  check(exactB,"production sealed B separate case-\(mode)")
  check(try actions.allSatisfy{let e=try store.read($0.id)!.evidence;return e.text.isEmpty && e.typed != nil},"canonical typed bodies remain sealed case-\(mode)")
  check(actions.allSatisfy{$0.state=="draft"},"production source never invents send case-\(mode)")
  check(parts.allSatisfy{!$0.1.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty},"space-only pieces never persisted case-\(mode)")
  if mode==0 || mode==1 {check(reads==61,"all61 authorized raw characters acquired case-\(mode)")}
  if [5,6,24,25,26,30].contains(mode) {check(reads==61,"unknown/secure refuses additional character acquisition case-\(mode)")}
  if mode==4 {check(parts.filter{$0.0=="owned-C"}.map{$0.1}.joined()=="separate note.","same-role/title different-document never receives held space")}
  let reopened=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false);try reopened.attachVault(TypedTextVault(keyStore:keys))
  for action in actions {
   let first=try store.hydrateTypedText(action.id,disclosure:.owner)
   check(try reopened.hydrateTypedText(action.id,disclosure:.owner)==first,"second connection exact case-\(mode)")
  }
 }
}
