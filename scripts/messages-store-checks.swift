import Foundation
import MemoryCore
import PrivacyPolicy

// Actual CoreCaptureBinding source + sealed isolated MemoryStore. Synthetic
// proof and characters only; no AX, event posting, default home or Keychain.
@main struct MessagesStoreChecks {
    static func main() throws {
        let home=FileManager.default.temporaryDirectory.appendingPathComponent("messages-store-fixture-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let keys=InMemoryTypedKeyStore(),store=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false)
        try store.attachVault(TypedTextVault(keyStore:keys));try store.acceptSafeTyping();try store.setUpTypedVault()
        var policy=try store.policy();policy.captureText=true;policy.typedConsentVersion=1;try store.updatePolicy(policy)
        try store.setCaptureState("recording",reason:"synthetic controlled fixture")
        let binding=CoreCaptureBinding(store:store)
        var count=0,mono:UInt64=10_000_000_000
        func check(_ value:Bool,_ label:String) {precondition(value,label);count += 1}
        // messages-1003: Return alone never detects a send, whatever the field; the composer emptying does (below).
        let cases:[(String,String,String,String)]=[("oneLine","AXTextField","","unknown"),("to","AXTextField","To:","unknown"),("body","AXTextArea","","unknown")]
        for (id,role,label,send) in cases {
            mono += 2_000_000_000
            let context=try binding.context()
            var p=FocusProof();p.bundle="com.apple.MobileSMS";p.windowID="owned-window";p.focusID="field-"+id;p.role=role;p.fieldLabel=label;p.place="New Message"
            p.surface = .native;p.secureInput = .no;p.privateMode = .no;p.verified=true;p.fieldStateVerified=true;p.frameAccessible=true;p.navigationStable=true
            p.generation=context.generation;p.policyVersion=context.policy.version;p.checkedAt=mono
            let text="harmless fixture draft for "+id
            check(try binding.insert(proof:p,eventAt:mono,now:mono,readCharacters:{text}).decision.outcome == .allowed,"safe field captures")
            check(try binding.commitText(id:id,proof:p,now:mono,wallTime:Date(),reason:.submit),"safe draft saved despite unknown recipient")
            let event=try store.read(id)!.evidence
            check(event.text.isEmpty && event.captureProvenance?.unit?.send == send && event.captureProvenance?.unit?.to == nil,"sealed metadata does not invent recipient/send")
            let state=try store.action(id)?.state
            check(state == (send == "detected" ? "submitted":"draft") && state != "sent","unknown stays draft; positive gesture is submitted, never confirmed sent")
            check(try store.hydrateTypedText(id,disclosure:.owner) == text,"exact saved draft hydration")
        }
        // messages-1003 scenarios (synthetic text, fictional names). `proof` is what the app's proof closure builds:
        // the witness's labels, then `SendRules.messagesField` with the window title (`MessagesComposer.classify`).
        var unitSeq=0
        func proof(title:String,labels:[String],focus:String,window:String="owned-window") throws -> FocusProof {
            let context=try binding.context()
            var p=FocusProof();p.bundle="com.apple.MobileSMS";p.windowID=window;p.focusID=focus;p.role="AXTextField";p.subrole=""
            p.nativeLabels=labels;p.place=title;p.sendField=SendRules.messagesField(role:p.role,subrole:p.subrole,labels:labels,title:title)
            p.surface = .native;p.secureInput = .no;p.privateMode = .no;p.verified=true;p.fieldStateVerified=true;p.frameAccessible=true;p.navigationStable=true
            p.generation=context.generation;p.policyVersion=context.policy.version;p.checkedAt=mono
            return p
        }
        /// Types `keys` one string per key, then Return (`sent`: the field's value at Return; `cleared`: the re-read after it).
        func message(_ keys:[String],title:String="Sam",labels:[String]=["iMessage"],focus:String="composer",window:String="owned-window",
                     sent:String?=nil,cleared:Bool=true,seal:SealReason = .submit) throws -> String {
            unitSeq += 1;let id="m1003-\(unitSeq)"
            for k in keys {
                mono += 50_000_000
                let p=try proof(title:title,labels:labels,focus:focus,window:window)
                check(try binding.insert(proof:p,eventAt:mono,now:mono,readCharacters:{k}).decision.outcome == .allowed,"messages-1003 key allowed")
            }
            mono += 50_000_000
            let p=try proof(title:title,labels:labels,focus:focus,window:window)
            check(try binding.commitText(id:id,proof:p,now:mono,wallTime:Date(),reason:seal,sentText:sent.map {v in {v}}),"messages-1003 unit written")
            check(try store.action(id)?.state == "draft","messages-1003: Return alone leaves a draft")
            if cleared {_=try binding.markComposerSent(id:id,windowID:window)}
            return id
        }
        func unit(_ id:String) throws -> TypedUnitProvenance? {try store.read(id)?.evidence.captureProvenance?.unit}
        func chars(_ s:String) -> [String] {s.map(String.init)}
        // 1. Three sends in one conversation; the field's value (autocorrect, capitals) is what is stored.
        let s1=try message(chars("me and my friendsr going to ZUX tmrw"),sent:"Me and my friendr going to ZUX tmrw")
        let s2=try message(chars("wanna meet us there?"),sent:"Wanna meet us there?")
        let s3=try message(chars("were gonna have a great time"),sent:"Were gonna have a great time")
        for (id,text) in [(s1,"Me and my friendr going to ZUX tmrw"),(s2,"Wanna meet us there?"),(s3,"Were gonna have a great time")] {
            let u=try unit(id)
            check(u?.send == "detected" && u?.sendBy == "return" && u?.field == "message" && u?.to == "Sam" && u?.surface == "text","messages-1003: a cleared composer after Return is a send to Sam")
            check(try store.action(id)?.state == "submitted" && store.action(id)?.title == "Sam","messages-1003: the action is submitted and titled with the conversation")
            check(try store.hydrateTypedText(id,disclosure:.owner) == text,"messages-1003: the sent text is the field's value, not the keys' reconstruction")
        }
        check(try binding.markComposerSent(id:s1,windowID:"owned-window") == false,"messages-1003: a row is marked once")
        // 2. A send, then an unsent draft (Return pressed but the field never emptied; or no Return at all).
        let sent2=try message(chars("see you at 7"),sent:"See you at 7")
        let draftReturn=try message(chars("actually make it 8"),sent:"Actually make it 8",cleared:false)
        let draftIdle=try message(chars("or later tonight"),focus:"composer-idle",cleared:false,seal:.idle)
        check(try store.action(sent2)?.state == "submitted","messages-1003: the send stays a send")
        check(try store.action(draftReturn)?.state == "draft" && unit(draftReturn)?.send == "unknown" && unit(draftReturn)?.to == "Sam","messages-1003: Return with the text still there stays a draft, still Sam's")
        check(try store.action(draftIdle)?.state == "draft" && binding.markComposerSent(id:draftIdle,windowID:"owned-window") == false,"messages-1003: an idle seal is never marked sent")
        check(try store.hydrateTypedText(draftIdle,disclosure:.owner) == "or later tonight","messages-1003: a draft keeps its typed text")
        // 3. Shift-Return is a newline inside one message (the key map never seals on it); one unit, one send.
        var keyMap=TypingKeyMap()
        check(keyMap.intent(KeyStroke(keyCode:36,shift:true),pressAndHold:false) == .insertText("\n") && keyMap.intent(KeyStroke(keyCode:36,option:true),pressAndHold:false) == .insertText("\n"),"messages-1003: Shift/Option-Return insert a newline")
        let multi=try message(chars("first line")+["\n"]+chars("second line"),sent:"First line\nsecond line")
        check(try store.action(multi)?.state == "submitted","messages-1003: a Shift-Return message is sent")
        let multiText=try store.hydrateTypedText(multi,disclosure:.owner) ?? ""
        // The store keeps a typed row on one line (its newline is a space), as for every typed row.
        check(try ["First line\nsecond line","First line second line"].contains(multiText) && unit(multi)?.part == 1,"messages-1003: a Shift-Return message is one unit, the composer's value")
        // 3b. The composer's value is refused when it would withhold anything: after a draft ending in a digit ("or 9"),
        // "First" would continue it as "9First" (the 7c seam rule), so the keys' text stays.
        _=try message(chars("or 9"),focus:"composer-idle",cleared:false,seal:.idle)
        let seam=try message(chars("first thing"),sent:"First thing")
        check(try store.hydrateTypedText(seam,disclosure:.owner) == "first thing" && store.action(seam)?.state == "submitted","messages-1003: a value the classifier would withhold is never adopted; the send still counts")
        // 4. New Message with an empty To: no recipient is ever borrowed. Unlabelled: no proof of a message box, never a send.
        let anon=try message(chars("hello there"),title:"New Message",labels:[],focus:"new-body",sent:"Hello there")
        check(try unit(anon)?.field == "oneLine" && unit(anon)?.send == "unknown" && unit(anon)?.to == nil && store.action(anon)?.title == "Messages","messages-1003: New Message, unlabelled box: a draft with no name")
        let labelled=try message(chars("hello again"),title:"New Message",labels:["iMessage"],focus:"new-body2",sent:"Hello again")
        check(try unit(labelled)?.send == "detected" && unit(labelled)?.to == nil && store.action(labelled)?.title == "Messages","messages-1003: New Message, iMessage box: a send to someone, never another conversation's name")
        let toBox=try message(chars("Maya"),title:"New Message",labels:["To:"],focus:"to-box",sent:"")
        check(try unit(toBox)?.field == "to" && unit(toBox)?.send == "unknown" && store.action(toBox)?.state == "draft","messages-1003: Return in the To box empties it but is never a send")
        // 5. Two conversations in one window: each unit names its own.
        let toSam=try message(chars("lunch?"),title:"Sam",sent:"Lunch?")
        let toMaya=try message(chars("running late"),title:"Maya",focus:"composer-maya",sent:"Running late")
        check(try unit(toSam)?.to == "Sam" && unit(toMaya)?.to == "Maya","messages-1003: two conversations keep their own names")
        // 6. Another window: the re-read must prove the row's own window.
        let other=try message(chars("ok"),title:"Sam",window:"window-b",sent:"Ok",cleared:false)
        check(try binding.markComposerSent(id:other,windowID:"owned-window") == false && store.action(other)?.state == "draft","messages-1003: an empty composer in another window proves nothing")
        // 7. Mid-word interruption: the composer's element is replaced (same focus ID from the witness's same-field rule),
        // so keys before and after it stay one unit, and the field's value is the message.
        let mid=try message(chars("wanna me")+chars("et us there?"),sent:"Wanna meet us there?")
        check(try store.hydrateTypedText(mid,disclosure:.owner) == "Wanna meet us there?" && unit(mid)?.part == 1,"messages-1003: no mid-word split")
        // The search box: never a message, never a send.
        let search=try message(chars("Jamie"),title:"Sam",labels:["Search"],focus:"search",sent:"Jamie")
        check(try unit(search)?.field == "search" && store.action(search)?.state == "draft" && unit(search)?.to == nil,"messages-1003: the sidebar search box is never a message or a send")
        // A value that can't stand for the keys (an older draft already in the box): the keys' text stays.
        let old=try message(chars("ok"),sent:"this is a much older draft that was already sitting in the composer box")
        check(try store.hydrateTypedText(old,disclosure:.owner) == "ok","messages-1003: an unrelated value never replaces the keys' text")
        // compose-send/v1: the one line every view uses.
        func line(_ id:String) throws -> String? {try store.read(id).flatMap {ComposeView.line($0.evidence)}}
        check(try [s1,s2,s3].map(line) == Array(repeating:"Sent to Sam",count:3),"compose-send: three sends read Sent to Sam")
        check(try line(draftReturn) == "Typed to Sam","compose-send: words not sent read Typed to Sam, never draft")
        check(try line(anon) == "Typed in Messages" && line(labelled) == "Sent to someone","compose-send: New Message: no borrowed name")
        check(try line(toMaya) == "Sent to Maya","compose-send: the second conversation")
        check(try unit(s1)?.confirm == "fieldCleared" && unit(draftReturn)?.confirm == nil,"compose-send: the confirmation is stored")
        // claude/messages2-1003 (owner 10/3: "the card knows who"): a conversation known only by its number or address
        // (fictional 555 number). Capture never stores it as a recipient (rule 7); the row's own window title names it, formatted.
        let num="+1 (555) 010-0142"
        let ph=try message(chars("does the plan still work"),title:"+15550100142",focus:"composer-num",sent:"Does the plan still work")
        check(try unit(ph)?.send == "detected" && unit(ph)?.field == "message" && unit(ph)?.to == nil,"messages2-1003: a number conversation's send; capture stores no recipient")
        check(try line(ph) == "Sent to "+num && store.read(ph).flatMap {ComposeView.outcome($0.evidence)}?.destination.name == num,"messages2-1003: Sent to the formatted number, never someone")
        check(try store.typedUnit(ph)?.to == num,"messages2-1003: the writer's unit names the number (code only; the model never sees it)")
        let em=try message(chars("see you there"),title:"sam@example.com",focus:"composer-mail",sent:"See you there")
        check(try line(em) == "Sent to sam@example.com","messages2-1003: an address conversation is named by its address")
        let numDraft=try message(chars("maybe later"),title:"+15550100142",focus:"composer-num2",sent:"Maybe later",cleared:false)
        check(try line(numDraft) == "Typed to "+num,"messages2-1003: a number conversation's unsent words name it too")
        // Never from a search box, a To box or a New Message window, whatever the title.
        let numSearch=try message(chars("dinner"),title:"+15550100142",labels:["Search"],focus:"search-num",sent:"dinner")
        check(try store.read(numSearch).flatMap {ComposeView.outcome($0.evidence)}?.destination.name == nil && store.typedUnit(numSearch)?.to == nil,"messages2-1003: a search box never names a number")
        check(try line(labelled) == "Sent to someone" && store.typedUnit(labelled)?.to == nil,"messages2-1003: New Message still names no one")
        // The gesture that sealed a text: Return for a send and for an unconfirmed text; never for an idle seal.
        func sealed(_ id:String) throws -> ComposeGesture? {try store.read(id).flatMap {ComposeView.outcome($0.evidence)}?.sealedBy}
        check(try sealed(s1) == .returnKey && sealed(draftReturn) == .returnKey && sealed(draftIdle) == nil,"messages2-1003: sealedBy is Return only for a Return seal")
        // Owner previews: one per text, and a Return-sealed text says so (it never starts the next one).
        let previews=try store.ownerSourceMomentPreviewsForActions([sent2,draftReturn,draftIdle])
        check(previews.count == 3 && previews.first {$0.actionIDs == [draftReturn]}?.sealedByReturn == true
              && previews.first {$0.actionIDs == [draftIdle]}?.sealedByReturn == false && previews.first {$0.actionIDs == [sent2]}?.state == "submitted",
              "messages2-1003: one preview per text; the Return-sealed draft is marked")
        let reopened=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false)
        try reopened.attachVault(TypedTextVault(keyStore:keys))
        for (id,_,_,_) in cases {
            check(try reopened.hydrateTypedText(id,disclosure:.owner) == "harmless fixture draft for "+id,"second connection exact draft")
        }
        print("\(count) synthetic production-binding/store checks passed; isolated fixture retained at \(home.path)")
    }
}
