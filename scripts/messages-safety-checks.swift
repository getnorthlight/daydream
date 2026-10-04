import AppKit
import PrivacyPolicy

// No live AX access. Unexpected system reads fail the console fixture.
enum AccessibilityReader {
    static func systemFocusedApplication() -> pid_t? { fatalError("live AX forbidden") }
    static func focusedWindowTitle(pid: pid_t) -> String? { fatalError("live AX forbidden") }
}

@main struct MessagesSafetyChecks {
    static func main() {
        var checks=0, failures:[String]=[]
        func check(_ value:Bool,_ label:String) { checks += 1; if !value { failures.append(label) } }
        let bundle="com.apple.MobileSMS"
        var rowReads=0, windowReads=0
        MessagesConversation.rowTexts={_ in rowReads += 1; return ["Previous Fixture", "old fictional preview"]}
        MessagesConversation.windowKey={_ in windowReads += 1; return "one-window"}
        MessagesConversation.clock={Date(timeIntervalSince1970:100)}
        MessagesConversation.forget()
        for title:String? in ["New Message", "Messages", "Untitled", "", nil, "+1 (202) 555-0100"] {
            let place=NativeTypingRoute.place(title:title,bundle:bundle,pid:42)
            check(place == NativeTypingRoute.clip(title), "generic-current-title-no-row-lookup-\(title ?? "absent")")
            check(SendRules.facts(bundle:bundle,title:place ?? "",field:"oneLine",seal:.submit).to == nil,"unknown-recipient-not-selected-row")
        }
        check(rowReads == 0 && windowReads == 0,"generic-cold-path-zero-selected-row-and-cache-reads")
        // Prime the legacy seam with a fictional old conversation. Production
        // place lookup must not consult it even when its TTL is still valid.
        _=MessagesConversation.name(pid:42)
        let rowsBefore=rowReads, windowsBefore=windowReads
        check(NativeTypingRoute.place(title:"New Message",bundle:bundle,pid:42) == "New Message","new-composer-never-borrows-cached-recipient")
        check(rowReads == rowsBefore && windowReads == windowsBefore,"primed-cache-path-no-lookup")
        check(NativeTypingRoute.place(title:"Fixture Name",bundle:bundle,pid:42) == "Fixture Name","own-window-title-retained")
        check(NativeTypingRoute.place(title:"Fixture Note",bundle:"com.apple.Notes",pid:42) == "Fixture Note","other-app-place-unchanged")
        for field in ["unknown","oneLine","to","subject","search","invalid"] {
            let expected=field == "invalid" ? "unknown":field
            let facts=SendRules.facts(bundle:bundle,title:"New Message",field:field,seal:.submit)
            check(facts.field == expected,"unproven-field-not-promoted-\(field)")
            check(facts.send == "unknown" && facts.sendBy == nil && facts.to == nil,"facts-recipient-return-no-send-\(field)")
            check(SendRules.facts(bundle:bundle,title:"Previous Fixture",field:field,seal:.submit).to == nil,"unproven-field-no-window-recipient-\(field)")
            let direct=SendRules.send(surface:"text",field:field,seal:.submit,bundle:bundle)
            check(direct.send == "unknown" && direct.sendBy == nil,"direct-recipient-return-no-send-\(field)")
        }
        for field in ["textArea","message","body"] {
            // messages-1003: Return alone is never a send; the composer emptying after it is (`messagesClearedSend`).
            let facts=SendRules.facts(bundle:bundle,title:"New Message",field:field,seal:.submit)
            check(facts.send == "unknown" && facts.sendBy == nil && facts.to == nil,"positive-body-return-alone-no-send-\(field)")
            check(SendRules.messagesClearedSend(surface:facts.surface,field:facts.field,seal:"submit") == ("detected","return"),"positive-body-return-cleared-send-\(field)")
            check(facts.field == (field == "textArea" ? "message":field),"positive-field-retained-\(field)")
            for seal in [SealReason.focusKey,.idle,.pointer,.submitChord,.window,.app,.suspend] {
                let draft=SendRules.facts(bundle:bundle,title:"New Message",field:field,seal:seal)
                check(draft.send == "unknown" && draft.sendBy == nil,"non-return-preserves-draft-\(field)-\(seal)")
            }
        }
        let classified=SendRules.fieldClass(role:"AXTextField",labels:[])
        check(classified == "oneLine","actual-native-unlabelled-textfield-not-body-proof")
        check(SendRules.facts(bundle:bundle,field:classified,seal:.submit).send == "unknown","production-role-only-field-facts-no-send")
        check(SendRules.fieldClass(role:"AXTextField",labels:["To:"],composer:true) == "to","recipient-label-precedes-composer")
        var map=TypingKeyMap()
        check(map.intent(KeyStroke(keyCode:36,shift:true),pressAndHold:false) == .insertText("\n"),"shift-return-is-line-edit-never-send")
        check(map.intent(KeyStroke(keyCode:36),pressAndHold:false) == .submit,"plain-return-intent-still-seals")
        check(SendRules.facts(bundle:bundle,title:"Fixture Name",field:"message",seal:.submit).send != "sent","gesture-not-confirmed-delivery")
        MessagesConversation.forget()
        print("checks=\(checks) failures=\(failures.count)")
        for failure in failures {print("FAIL \(failure)")}
        if !failures.isEmpty && !CommandLine.arguments.contains("--baseline") {exit(1)}
    }
}
