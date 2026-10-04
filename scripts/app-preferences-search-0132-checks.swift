import Foundation
@testable import MemoryCore
import PrivacyPolicy

@main struct AppBindingChecks {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let root=URL(fileURLWithPath:"/private/tmp/daydream-app-bindings-"+UUID().uuidString)
        let store=try MemoryStore(home:root,writable:true,automaticallySyncSearch:false)
        // A ready vault, so the pending burst below could otherwise be saved.
        try store.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()));try store.setUpTypedVault();try store.acceptSafeTyping()
        var checks=0,stops=0
        func check(_ value:Bool,_ label:String) {precondition(value,label);checks+=1;print("PASS "+label)}
        _=try store.ingest(Evidence(id:"original",at:iso(Date()),kind:"window.changed",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Harmless orchard",synthetic:true))
        let action=try store.action("original")!
        _=try store.correctAction(id:action.id,text:"Orchard correction",expectedRevision:action.revision)
        let originals=try store.rows("SELECT * FROM records ORDER BY id")
        let coordinator=try Coordinator(store:store,permissions:{true},onCommitted:{})
        let saver=try PreferenceAutosave(store:store,stopProducer:{stops+=1;coordinator.stopForPreferences(capture:nil)})
        let initial=saver.policy.revision
        saver.submit(.init(blockedApps:["com.apple.Notes"],nativeTyping:false))
        check(stops==1 && !coordinator.isRunning,"actual coordinator stops synchronously before debounce")
        check(try store.policy().revision==initial && saver.draft != nil,"pending draft is not reported persisted")
        saver.submit(.init(blockedApps:["com.apple.TextEdit"],nativeTyping:false))
        saver.flush()
        check(try store.policy().blockedApps==["com.apple.TextEdit"] && saver.draft==nil,"rapid toggles coalesce to latest exact draft")
        check(try store.rows("SELECT * FROM records ORDER BY id")==originals,"preference save preserves originals byte for byte")
        check(try store.action("original")==nil,"excluded corrected action hidden by canonical reader")
        saver.submit(.init(blockedApps:[],nativeTyping:true));saver.flush()
        check(try store.action("original")?.correction != nil,"unexclude preserves correction")
        check(try store.policy().captureText && store.policy().typedConsentVersion==1 && !coordinator.isRunning,"explicit typing opt-in saves consent without resuming")
        let restarted=try PreferenceAutosave(store:store,stopProducer:{coordinator.stopForPreferences(capture:nil)})
        check(restarted.policy.captureText && restarted.draft==nil,"fresh binding reloads committed preference")
        saver.submit(.init(blockedApps:["com.apple.Notes"],nativeTyping:true))
        saver.submit(.init(blockedApps:[],nativeTyping:false))
        try await Task.sleep(nanoseconds:300_000_000)
        check(saver.draft==nil && !saver.policy.captureText && saver.policy.blockedApps.isEmpty,"actual debounce timer commits only latest rapid intent")
        let external=try MemoryStore(home:root,writable:true,automaticallySyncSearch:false)
        _=try external.savePreferences(.init(blockedApps:["com.apple.Notes"],nativeTyping:false),expectedRevision:try external.policy().revision)
        saver.submit(.init(blockedApps:[],nativeTyping:true));saver.flush()
        check(saver.error == .revisionConflict && saver.draft != nil,"stale save remains unsaved")
        saver.flush();check(try store.policy().blockedApps==["com.apple.Notes"],"retry cannot silently rebase stale intent")
        saver.reload();check(saver.draft==nil && saver.policy.blockedApps==["com.apple.Notes"],"explicit reload discards stale draft and adopts revision")
        try store.exec("CREATE TRIGGER fail_preference BEFORE UPDATE ON metadata WHEN NEW.id='policy' BEGIN SELECT RAISE(ABORT,'fixture failure'); END")
        let beforeFailure=try store.policy().revision
        saver.submit(.init(blockedApps:["com.apple.TextEdit"],nativeTyping:false));saver.flush()
        check(saver.error == .storageUnavailable && saver.draft != nil && !coordinator.isRunning,"failed real transaction retains dirty draft and stopped intake")
        check(try store.policy().revision==beforeFailure,"failed save does not advance durable revision")
        try store.exec("DROP TRIGGER fail_preference")
        saver.flush();check(saver.error==nil && saver.draft==nil,"explicit retry succeeds with original unchanged revision")
        try coordinator.start()
        try store.exec("CREATE TRIGGER fail_pause BEFORE INSERT ON metadata WHEN NEW.id='capture' BEGIN SELECT RAISE(ABORT,'fixture pause failure'); END")
        saver.submit(.init(blockedApps:[],nativeTyping:false));saver.flush()
        check(!coordinator.isRunning && saver.draft != nil,"pause write failure leaves actual intake stopped and preference unsaved")
        try store.exec("DROP TRIGGER fail_pause")
        saver.flush();check(saver.draft==nil,"explicit retry persists stop before changed preference")
        saver.submit(.init(blockedApps:[],nativeTyping:true));saver.flush()
        let mono:UInt64=10_000_000_000
        let capture=EventCapture(coordinator:coordinator,typingEnvironment:.init(now:{mono},proof:{generation,version in
            var p=FocusProof();p.generation=generation;p.policyVersion=version;p.checkedAt=mono
            p.bundle="com.apple.TextEdit";p.windowID="dummy";p.focusID="dummy";p.role="AXTextArea";p.surface = .native
            p.secureInput = .no;p.privateMode = .no;p.verified=true;p.fieldStateVerified=true;p.frameAccessible=true;p.navigationStable=true;return p
        }))
        try coordinator.start();coordinator.captureText=true
        capture.handleNativeKey(eventAt:mono,keyCode:0,shortcut:false) {"uncommitted harmless draft"}
        let pendingSaver=try PreferenceAutosave(store:store,stopProducer:{coordinator.stopForPreferences(capture:capture)})
        pendingSaver.submit(.init(blockedApps:["com.apple.TextEdit"],nativeTyping:false));pendingSaver.flush()
        capture.flushNativeText()
        // Typed rows are sealed, so the body text can't show a save: check that no typed row exists at all.
        check(try store.rows("SELECT id FROM records WHERE body LIKE '%uncommitted harmless draft%' OR json_extract(body,'$.kind')='keyboard.text_input' UNION ALL SELECT id FROM typed_text").isEmpty,"actual EventCapture pending burst discarded before preference transaction")
        check(!coordinator.isRunning,"save never automatically restarts capture")
        pendingSaver.submit(.init(blockedApps:[],nativeTyping:false));pendingSaver.flush()
        let search=AppSearchBinding(store:store)
        let first=try await search.search(.init("orchard"))
        check(first.items.contains{$0.evidence.id=="original"},"actual retained app search binding queries SQLite before begin")
        search.begin(bundle:root.appendingPathComponent("Missing.app")) {_ in}
        try await Task.sleep(nanoseconds:100_000_000)
        check(search.snapshot.phase=="fallback","missing bundled runtime gives honest fallback")
        let fallback=try await search.search(.init("orchard"))
        check(!fallback.items.isEmpty,"runtime absence does not block browsing")
        _=try store.savePreferences(.init(blockedApps:["com.apple.TextEdit"],nativeTyping:false),expectedRevision:try store.policy().revision)
        let excluded=try await search.search(.init("orchard"))
        check(excluded.items.isEmpty,"search revalidates current exclusion immediately")
        search.stop();check(search.snapshot.phase=="stopped" || search.snapshot.phase=="fallback","app teardown stops its own binding")
        let nextSearch=AppSearchBinding(store:try MemoryStore(home:root,automaticallySyncSearch:false))
        let afterRestart=try await nextSearch.search(.init("orchard"))
        check(afterRestart.items.isEmpty,"fresh search binding preserves policy on restart")
        print("PASS \(checks) app binding checks. Fixture \(root.path). No tap, grants, runtime process or personal data.")
    }
}
