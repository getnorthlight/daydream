// DD-RECIPE: CAPTURE
// Synthetic integration through actual EventCapture → Coordinator → CoreCaptureBinding → sealed MemoryStore.
// No EventCapture.start(), OS input/tap, AX read, owner home/preferences, Keychain or model. Logical clock only.
import Foundation
import AppKit
import ApplicationServices
import HistoryCore
@testable import MemoryCore
import PrivacyPolicy

final class MessagesRecorderRig {
    var mono: UInt64 = 10_000_000_000
    var bundle = "com.apple.MobileSMS", window = "window", focus = "body", place = "New Message"
    var role = "AXTextArea", fieldLabel = "", known = true, secure = false, privateMode = false
    var reads = 0, proofReads = 0
    var proofTransform: ((inout FocusProof,Int)->Void)?
    var timers: [(at:UInt64, work:()->Void)] = []
    let store:MemoryStore, coordinator:Coordinator
    var capture:EventCapture!
    init(_ root:URL,_ name:String) throws {
        store=try MemoryStore(home:root.appendingPathComponent(name),writable:true,automaticallySyncSearch:false)
        try store.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()));try store.setUpTypedVault();try store.acceptSafeTyping()
        var policy=try store.policy();policy.captureText=true;policy.typedConsentVersion=1;try store.updatePolicy(policy)
        coordinator=try Coordinator(store:store,permissions:{true}) {};coordinator.captureText=true
        capture=EventCapture(coordinator:coordinator,typingEnvironment:.init(now:{[unowned self] in self.mono},proof:{[unowned self] g,v in
            guard self.known else{return nil}
            var p=FocusProof();p.generation=g;p.policyVersion=v;p.checkedAt=self.mono;p.bundle=self.bundle;p.windowID=self.window;p.focusID=self.focus
            p.role=self.role;p.fieldLabel=self.fieldLabel;p.place=self.place;p.surface = .native;p.secureInput=self.secure ? .yes:.no;p.privateMode=self.privateMode ? .yes:.no
            p.verified=true;p.fieldStateVerified=true;p.frameAccessible=true;p.navigationStable=true
            self.proofReads += 1;self.proofTransform?(&p,self.proofReads)
            return p
        },schedule:{[unowned self] d,w in self.timers.append((self.mono+UInt64(d*1_000_000_000),w))},secureInput:{[unowned self] in self.secure},departure:{[unowned self] in
            DepartureState(secureInput:self.secure ? .yes:.no,bundle:self.bundle,focusSecure:self.secure ? .yes:.no)
        },pressAndHold:{true}))
        NativeTypingRoute.keyFocus={4242};NativeTypingRoute.bundleOf={[unowned self] _ in self.bundle}
        try coordinator.start()
    }
    func advance(_ seconds:Double) {
        let end=mono+UInt64(seconds*1_000_000_000)
        while let i=timers.indices.filter({timers[$0].at<=end}).min(by:{timers[$0].at<timers[$1].at}) {let t=timers.remove(at:i);mono=max(mono,t.at);t.work()}
        mono=end
    }
    func type(_ text:String,notifications:Bool=false) {
        for c in text {
            advance(0.1);capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:0)){self.reads+=1;return String(c)};advance(0)
            if notifications {capture.handleAX(kAXFocusedUIElementChangedNotification as String);capture.handleAX(kAXFocusedWindowChangedNotification as String)}
        }
    }
    func settle() {capture.flushNativeText();advance(1);capture.resolveParkedTyping(force:true)}
    func rows() throws -> [(Evidence,String)] {
        try store.rows("SELECT id FROM typed_text ORDER BY rowid").map {row in (try store.read(row[0])!.evidence,try store.hydrateTypedText(row[0],disclosure:.owner)!)}
    }
}
@main struct MessagesRecorderChecks {
    static var checks=0,failures=0
    static func check(_ condition:Bool,_ label:String) {checks+=1;if condition {print("PASS "+label)} else {failures+=1;print("FAIL "+label)}}
    static func checkRows(_ rig:MessagesRecorderRig,_ words:[String],_ recipients:[String?],_ label:String) throws {
        let rows=try rig.rows()
        check(rows.map{$0.1}==words,label+": exact saved pieces")
        check(rows.map{$0.0.captureProvenance?.unit?.to}==recipients,label+": own recipient authority only")
        check(rows.allSatisfy{$0.0.text.isEmpty && $0.0.synthetic == false},label+": sealed production rows")
        check(rows.allSatisfy{($0.0.captureProvenance?.unit?.send ?? "unknown") != "sent"},label+": no delivery fabricated")
        let titles=try rows.map {try rig.store.action($0.0.id)!.title}
        check(titles==recipients.map{$0 ?? "Messages"},label+": canonical titles match only own recipient")
        let runs=rows.map{$0.0.captureProvenance?.unit?.runID ?? ""}
        for i in recipients.indices.dropFirst() where recipients[i] != recipients[i-1] {
            check(runs[i] != runs[i-1],label+": conversation change starts distinct run")
        }
        check(!rig.coordinator.captureBinding.hasPendingTyping,label+": no pending live text")
    }
    static func main() throws {
        setbuf(stdout,nil)
        #if DAYDREAM_OWNER_TYPING
        WebTypingRoute.shared=WebTypingRoute(environment:.init(now:{DispatchTime.now().uptimeNanoseconds},join:{_,_,_ in .denied(.disabled)},schedule:{_,_ in},secureInput:{false},pressAndHold:{true},secondsSinceMouseDown:{nil},directKeyboardInput:{true}))
        #endif
        EventCapture.reenableTap={_ in fatalError("OS tap forbidden")};EventCapture.remakeTap={_ in fatalError("OS tap forbidden")};EventCapture.registerAX={_,_,_ in fatalError("live AX registration forbidden")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("messages-recorder-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        #if DAYDREAM_OWNER_TYPING
        do {let r=try MessagesRecorderRig(root,"anonymous");r.type("Unaddressed cedar draft.",notifications:true);r.settle();try checkRows(r,["Unaddressed cedar draft."],[nil],"anonymous repeated focus notifications")}
        do {let r=try MessagesRecorderRig(root,"recipient-appears-after-edit");r.type("Before recipient. ");r.place="Maya";r.type("After recipient.");r.settle();try checkRows(r,["Before recipient. ","After recipient."],[nil,"Maya"],"recipient appears in same exact field")}
        do {let r=try MessagesRecorderRig(root,"recipient-appears-at-flush");r.type("Unaddressed before naming.");r.place="Maya";r.settle();try checkRows(r,["Unaddressed before naming."],[nil],"recipient appears only at flush")}
        do {let r=try MessagesRecorderRig(root,"recipient-changes");r.place="Maya";r.type("Cedar plan for Maya. ");r.place="Sam";r.type("Maple plan for Sam.",notifications:true);r.settle();try checkRows(r,["Cedar plan for Maya. ","Maple plan for Sam."],["Maya","Sam"],"conversation change reuses window and field")}
        do {let r=try MessagesRecorderRig(root,"recipient-changes-at-flush");r.place="Maya";r.type("Maya owns this draft.");r.place="Sam";r.capture.handleAX(kAXFocusedWindowChangedNotification as String);r.settle();try checkRows(r,["Maya owns this draft."],["Maya"],"conversation changes only at notification and flush")}
        do {let r=try MessagesRecorderRig(root,"switches");r.place="Maya";r.type("First Maya draft.");r.focus="sam-body";r.place="Sam";r.capture.handleAX(kAXFocusedUIElementChangedNotification as String);r.advance(1);r.type("Sam draft.");r.window="other-window";r.place="Maya";r.focus="maya-body";r.capture.handleAX(kAXFocusedWindowChangedNotification as String);r.advance(1);r.type("Second Maya draft.");r.settle();try checkRows(r,["First Maya draft.","Sam draft.","Second Maya draft."],["Maya","Sam","Maya"],"genuine field and window switches")}
        for seconds in [30.0,300.0,1200.0] {
            for name in ["New Message","Maya"] {
                let r=try MessagesRecorderRig(root,"idle-\(Int(seconds))-\(name)");r.place=name;r.type("Cedar first piece. ");r.advance(seconds);r.type("Maple resumed piece.",notifications:true);r.settle()
                try checkRows(r,["Cedar first piece. ","Maple resumed piece."],[name=="Maya" ? "Maya":nil,name=="Maya" ? "Maya":nil],"\(Int(seconds))s interrupted \(name) draft")
            }
        }
        for label in ["iMessage","text message","Delivered","Read","To:","Messages"] {
            let r=try MessagesRecorderRig(root,"generic-"+label);r.place=label;r.type("Unaddressed status label draft.");r.settle()
            try checkRows(r,["Unaddressed status label draft."],[nil],"generic label "+label)
        }
        do {let r=try MessagesRecorderRig(root,"unproved-field");r.role="AXTextField";r.place="Maya";r.type("Unproved one line.");r.settle();try checkRows(r,["Unproved one line."],[nil],"unproved field cannot borrow named title")
            check(try r.store.actions(limit:10).actions.filter{$0.kind=="keyboard.text_input"}.allSatisfy{$0.title=="Messages"},"unproved field canonical title stays generic")}
        do {let r=try MessagesRecorderRig(root,"privacy");r.type("Safe saved draft.");r.settle();let before=r.reads
            r.secure=true;r.type("blocked secure fictional words");r.secure=false;r.privateMode=true;r.type("blocked private fictional words");r.privateMode=false;r.known=false;r.type("blocked unknown fictional words");r.known=true
            check(r.reads==before,"secure/private/unknown proofs read no characters");r.advance(1);r.type("Safe resumed draft.");r.settle();try checkRows(r,["Safe saved draft.","Safe resumed draft."],[nil,nil],"privacy denial and recovery")}
        for (label,before,after) in [("named","Maya","Sam"),("anonymous","New Message","Maya")] {
            let r=try MessagesRecorderRig(root,"final-proof-race-"+label);r.place=before;r.type("Already proven draft.");let readBefore=r.reads;r.proofReads=0
            r.proofTransform={p,ordinal in if ordinal==2 {p.place=after}}
            r.type("X");r.proofTransform=nil;r.settle()
            check(r.reads==readBefore,"final proof recipient race "+label+": character acquisition stays zero")
            try checkRows(r,["Already proven draft."],[before=="Maya" ? "Maya":nil],"final proof recipient race "+label)
        }
        do {let r=try MessagesRecorderRig(root,"secret");r.type("password=fictional-secret-value");r.settle();check(try r.rows().isEmpty,"synthetic credential pattern never saved")}
        #else
        let r=try MessagesRecorderRig(root,"public-gate");r.type("Blocked public Messages draft.");r.settle();check(try r.reads==0 && r.rows().isEmpty,"public build does not admit owner-only Messages")
        #endif
        print("checks=\(checks) failures=\(failures); synthetic recorder only; real Messages GUI UNVERIFIED")
        if failures>0 {exit(1)}
    }
}
