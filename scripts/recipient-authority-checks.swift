import Foundation
@testable import MemoryCore
import PrivacyPolicy
import CoreIntegration
@testable import WriterBackend

/// Fictional stores through the actual native binding: no live input or model.
@main struct RecipientAuthorityChecks {
    static var passed=0,failed=0
    static func check(_ ok:Bool,_ label:String) {print("\(ok ? "PASS" : "FAIL") \(label)");if ok {passed+=1} else {failed+=1}}
    static func main() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("recipient-authority-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(home:root,writable:true,automaticallySyncSearch:false)
        try store.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()));try store.setUpTypedVault();try store.acceptSafeTyping()
        var policy=try store.policy();policy.captureText=true;policy.typedConsentVersion=1;try store.updatePolicy(policy)
        try store.setCaptureState("recording",reason:"fictional fixture")
        let binding=CoreCaptureBinding(store:store)
        var clock:UInt64=10_000_000_000
        func proof(_ field:String,_ window:String="mail",_ focus:String?=nil) throws -> FocusProof {
            let ctx=try binding.context();var p=FocusProof()
            p.generation=ctx.generation;p.policyVersion=ctx.policy.version;p.checkedAt=clock
            p.bundle=SendRules.mailApp;p.windowID=window;p.focusID=focus ?? field;p.role="AXTextArea";p.sendField=field;p.fieldLabel=field
            p.secureInput = .no;p.privateMode = .no;p.surface = .native;p.verified=true;p.fieldStateVerified=true;p.frameAccessible=true;p.navigationStable=true
            return p
        }
        @discardableResult func type(_ text:String,_ field:String,_ window:String="mail",_ focus:String?=nil) throws -> FocusProof {
            var p=try proof(field,window,focus)
            for c in text {clock+=80_000_000;p=try proof(field,window,focus);_ = try binding.insert(proof:p,eventAt:clock,now:clock,readCharacters:{String(c)})}
            return p
        }
        @discardableResult func save(_ id:String,_ text:String,_ field:String,_ window:String="mail") throws -> Bool {
            let p=try type(text,field,window);return try binding.commitText(id:id,proof:p,now:clock,reason:field=="to" ? .focusKey:.idle)
        }
        func to(_ id:String) throws -> String? {try store.typedUnit(id,disclosure:.owner)?.to}
        check(try save("initial-to","Avery","to"),"actual binding accepts a fictional named To")
        check(try save("initial-body","Could you review the garden sketch?","body"),"actual binding retains fictional body")
        check(try to("initial-body")=="Avery","valid To authority reaches its window's body")
        check(try !save("rejected-to","Riley2@ex","to"),"incomplete opaque To produces no saved row")
        _=try save("after-rejection","The north bed needs seedlings.","body")
        check(try to("after-rejection")==nil,"classifier-rejected To edit cannot inherit previous recipient")
        _=try save("new-to","Morgan","to")
        clock+=1_000_000_000
        let emptyTo=try proof("to")
        _=try binding.edit(.deleteBackward(.character),proof:emptyTo,eventAt:clock,now:clock)
        _=try save("after-backspace","The courier needs the parcel details.","body")
        check(try to("after-backspace")==nil,"backspace outside an empty run invalidates To without a row")
        _=try save("window-a-to","Avery","to","a");_=try save("window-b-to","Morgan","to","b")
        _=try save("window-a-invalid","Riley2@ex","to","a")
        _=try save("window-a-body","The sketch is ready for review.","body","a")
        _=try save("window-b-body","The parcel is ready for pickup.","body","b")
        check(try to("window-a-body")==nil && to("window-b-body")=="Morgan","native To edits are isolated by window ID")
        let old=try type("Avery","to","late","old-to")
        binding.seal(.focusKey,now:clock,focusMoved:true,proof:old)
        clock+=100_000_000
        _=try save("late-new-invalid","Riley2@ex","to","late")
        clock+=100_000_000
        let destination=TypingDestination(proof:try proof("body","late"),departure:DepartureState(secureInput:.no,bundle:SendRules.mailApp,focusSecure:.no))
        let lateResult=try binding.commitParked(id:"late-old-to",destination:destination,secureInput:false,now:clock,force:true)
        check(lateResult==true,"delayed old To still reaches the actual write callback within its deadline")
        _=try save("late-body","The revised sketch needs another review.","body","late")
        check(try to("late-body")==nil,"delayed old To cannot restore authority after later rejected edit")
        _=try save("contacts","Reach me at morgan@example.com or 415-555-0100.","body","contacts")
        let contactProse=try store.hydrateTypedText("contacts",disclosure:.owner)=="Reach me at morgan@example.com or 415-555-0100."
        print("OBSERVATION contact prose exact retention: \(contactProse); compare unchanged baseline separately")
        binding.invalidate(.focus)
        _=try save("ordinary-email","morgan@example.com","body","email")
        check(try store.hydrateTypedText("ordinary-email",disclosure:.owner)=="morgan@example.com","existing ordinary email capture remains permitted")
        binding.invalidate(.focus)
        _=try save("shift-to","Avery","to","shift")
        let earlier=Date().addingTimeInterval(-7_200),later=Date().addingTimeInterval(7_200)
        binding.wallClock={earlier}
        _=try save("backward-clock-body","The garden sketch remains under review.","body","shift")
        binding.wallClock={later}
        _=try save("forward-clock-body","The revised garden sketch is ready.","body","shift")
        check(try to("backward-clock-body")=="Avery" && to("forward-clock-body")=="Avery","wall-clock shifts cannot change monotonic recipient authority")
        binding.wallClock={Date()}
        var secure=try proof("to");secure.secureInput = .yes
        var reads=0
        let denied=try binding.insert(proof:secure,eventAt:clock,now:clock,readCharacters:{reads+=1;return "never read"})
        check(denied.decision.outcome != .allowed && reads==0,"secure input still denies before character read")
        _=try save("after-secure","The sketch has one new detail.","body","shift")
        check(try to("after-secure")==nil,"a privacy refusal also revokes previous recipient authority")
        #if !RECIPIENT_BASELINE
        #if !RECIPIENT_SHORTCUT_BASELINE
        let oldUnknown=try type("Avery","to","unknown-late")
        binding.seal(.focusKey,now:clock,focusMoved:true,proof:oldUnknown)
        clock+=100_000_000
        try binding.recipientExternallyEdited(proof:nil,eventAt:clock,now:clock)
        clock+=100_000_000
        let unknownDestination=TypingDestination(proof:try proof("body","unknown-late"),departure:DepartureState(secureInput:.no,bundle:SendRules.mailApp,focusSecure:.no))
        let unknownSaved=try binding.commitParked(id:"unknown-old-to",destination:unknownDestination,secureInput:false,now:clock,force:true)
        _=try save("unknown-late-body","The unproved edit removed old recipient authority.","body","unknown-late")
        check(try unknownSaved==true && to("unknown-late-body")==nil,"missing-proof mutation watermark survives delayed To write")
        #endif
        for deferred in [false,true] {
            var limits=TypingLimits();limits.maxCharacters=8
            let session=TypingSession(limits:limits)
            let event:UInt64=80_000_000_000,processed=event+100_000_000
            var p=try proof("to","carry");p.generation=session.generation;p.checkedAt=processed
            let capturePolicy=try binding.context().policy
            p.policyVersion=capturePolicy.version
            _=session.insert("AlexandriaMorgan",proof:p,policy:capturePolicy,eventAt:event,now:processed)
            var writes:[TypingCommit]=[]
            if deferred {_=session.deferCommit(.size,now:processed)}
            else {_=session.commitLive(fresh:p,reason:.size,policy:capturePolicy,now:processed,write:{writes.append($0);return true})}
            p.checkedAt=processed+100_000_000
            _=session.commitLive(fresh:p,reason:.focusKey,policy:capturePolicy,now:p.checkedAt,write:{writes.append($0);return true})
            let carry=writes.last
            check(carry?.text=="iaMorgan" && carry?.lastEditedAt==event,"\(deferred ? "deferred" : "direct") size carry preserves real key timestamp")
            let authority=RecipientMemory();authority.editedTo(window:"carry",now:event+1)
            if let carry {_=authority.observe(window:"carry",field:"to",text:carry.text,seal:.focusKey,now:p.checkedAt,lastEditedAt:carry.lastEditedAt)}
            check(authority.observe(window:"carry",field:"body",text:"fictional body",seal:.idle,now:p.checkedAt)==nil,"\(deferred ? "deferred" : "direct") size carry cannot cross a later recipient edit watermark")
        }
        let memory=RecipientMemory()
        memory.editedTo(window:"fictional",now:200)
        memory.editedTo(window:"fictional",now:150)
        _=memory.observe(window:"fictional",field:"to",text:"Avery",seal:.focusKey,now:210,lastEditedAt:150)
        check(memory.observe(window:"fictional",field:"body",text:"fictional body",seal:.idle,now:220)==nil,"older late edit cannot erase a newer monotonic invalidation watermark")
        memory.editedTo(window:"fictional",now:300)
        _=memory.observe(window:"fictional",field:"to",text:"Morgan",seal:.focusKey,now:310,lastEditedAt:300)
        memory.editedTo(window:"fictional",now:250)
        check(memory.observe(window:"fictional",field:"body",text:"fictional body",seal:.idle,now:320)=="Morgan","late older edit cannot erase a newer valid recipient")
        #endif
        let actions=[
            NoteAction(id:"field-to",at:"2026-09-30T15:00:00Z",kind:"keyboard.text_input",app:"Mail",site:"",title:"",description:"Typed a draft in Mail. Avery",state:"typed",revision:"fixture",surface:"email",send:"unknown",runID:"to-run",field:"to"),
            NoteAction(id:"field-subject",at:"2026-09-30T15:00:01Z",kind:"keyboard.text_input",app:"Mail",site:"",title:"",description:"Typed a draft in Mail. Garden proposal",state:"typed",revision:"fixture",surface:"email",send:"unknown",runID:"subject-run",field:"subject"),
            NoteAction(id:"field-body",at:"2026-09-30T15:00:02Z",kind:"keyboard.text_input",app:"Mail",site:"",title:"",description:"Typed a draft in Mail. Could you trace the missing parcel?",state:"typed",revision:"fixture",surface:"email",send:"unknown",runID:"body-run",field:"body")]
        let data=try JSONSerialization.data(withJSONObject:["id":"fields","schemaVersion":1,"targetKind":"activity","targetID":"fields","day":"2026-09-30","timezone":"UTC","inputRevision":"fixture","policyRevision":"fixture","expiresAt":"2099-01-01T00:00:00Z","actions":try JSONSerialization.jsonObject(with:JSONEncoder().encode(actions)),"actionCount":actions.count])
        let request=try JSONDecoder().decode(CanonicalNoteRequest.self,from:data),view=try ModelView(request:request,actions:actions)
        check(view.items.filter{$0.kind == .typed}.count==3,"unrelated email fields remain independent model items")
        let body=view.items.first{$0.actions.contains{$0.id=="field-body"}}
        check(body?.actions.map(\.id)==["field-body"] && body?.subject==nil,"unrelated heading cannot lend source ID or subject to a body")
        print("recipient-authority: \(passed) passed, \(failed) failed")
        if failed>0 {exit(1)}
    }
}
