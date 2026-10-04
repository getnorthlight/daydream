import Foundation
import ApplicationServices
import HistoryCore
@testable import MemoryCore
import PrivacyPolicy

@main struct ProductionCaptureChecks {
    static var checks=0
    static func check(_ condition:Bool,_ name:String) {precondition(condition,name);checks+=1;print("PASS "+name)}
    static func redundantNativeFocusNotifications() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("redundant-native-focus-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(home:root,writable:true,automaticallySyncSearch:false)
        try store.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()))
        try store.setUpTypedVault();try store.acceptSafeTyping()
        var policy=try store.policy();policy.captureText=true;policy.typedConsentVersion=1;try store.updatePolicy(policy)
        let coordinator=try Coordinator(store:store,permissions:{true}) {}
        coordinator.captureText=true
        try coordinator.start()
        var now:UInt64=10_000_000_000,focus="field-a",window="window-a",known=true,secure=false,reads=0
        let capture=EventCapture(coordinator:coordinator,typingEnvironment:.init(now:{now},proof:{generation,version in
            guard known else {return nil}
            var p=FocusProof();p.generation=generation;p.policyVersion=version;p.checkedAt=now
            p.bundle="com.apple.TextEdit";p.windowID=window;p.focusID=focus;p.role="AXTextArea"
            p.surface = .native;p.secureInput=secure ? .yes:.no;p.privateMode = .no
            p.verified=true;p.fieldStateVerified=true;p.frameAccessible=true;p.navigationStable=true
            return p
        },schedule:{_,_ in},secureInput:{secure},departure:{DepartureState(secureInput:.no,bundle:"com.apple.TextEdit",focusSecure:.no)},pressAndHold:{true}))
        func type(_ text:String,notifications:Bool=true) {
            for c in text {
                now += 100_000_000
                capture.handleNativeKey(eventAt:now,keyCode:0,shortcut:false) {reads+=1;return String(c)}
                if notifications {
                    capture.handleAX(kAXFocusedUIElementChangedNotification as String)
                    capture.handleAX(kAXFocusedWindowChangedNotification as String)
                }
            }
        }
        func words() throws -> [String] {
            try store.rows("SELECT id FROM typed_text ORDER BY id").compactMap{try store.hydrateTypedText($0[0],disclosure:.owner)}
        }
        let draft="Asked for a review of the cedar app design."
        type(draft);capture.flushNativeText()
        check(try words()==[draft],"repeated same-field AX notifications retain one intact native draft")
        type("First field draft.",notifications:false)
        focus="field-b"
        capture.handleAX(kAXFocusedUIElementChangedNotification as String)
        now += 500_000_000;capture.resolveParkedTyping(force:true)
        type("Second field draft.");capture.flushNativeText()
        check(try Array(words().suffix(2))==["First field draft.","Second field draft."],"different exact fields still seal separate drafts")
        type("First window draft.",notifications:false)
        window="window-b"
        capture.handleAX(kAXFocusedWindowChangedNotification as String)
        now += 500_000_000;capture.resolveParkedTyping(force:true)
        type("Second window draft.");capture.flushNativeText()
        check(try Array(words().suffix(2))==["First window draft.","Second window draft."],"different exact windows still seal separate drafts")
        let before=reads
        known=false;capture.handleAX(kAXFocusedUIElementChangedNotification as String)
        type("unknown",notifications:false)
        check(reads==before,"unknown focus never acquires characters")
        known=true;secure=true;capture.handleAX(kAXFocusedWindowChangedNotification as String)
        type("secret",notifications:false)
        check(reads==before,"secure focus never acquires characters after AX notifications")
        secure=false;coordinator.stop()
    }
    /// messages-1003: Return in Messages through the real EventCapture: the composer's value at Return is the sent text,
    /// and the row becomes a send only when a scheduled re-read finds the same window's composer empty. Synthetic only.
    static func messagesSendDetection() throws {
        guard CaptureGate.nativeApps.contains("com.apple.MobileSMS") else {print("SKIP messages-1003 send detection: Messages typing is not in this build");return}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("messages-send-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(home:root,writable:true,automaticallySyncSearch:false)
        try store.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()))
        try store.setUpTypedVault();try store.acceptSafeTyping()
        var policy=try store.policy();policy.captureText=true;policy.typedConsentVersion=1;try store.updatePolicy(policy)
        let coordinator=try Coordinator(store:store,permissions:{true}) {}
        coordinator.captureText=true
        try coordinator.start()
        var now:UInt64=10_000_000_000,title="Sam",labels=["iMessage"],focus="composer",window="window-a"
        var fieldValue="",empty:Bool?=false,valueReads=0
        var timers:[(at:UInt64,work:()->Void)]=[]
        func advance(_ seconds:Double) {
            let target=now+UInt64(seconds*1_000_000_000)
            while let i=timers.indices.filter({timers[$0].at<=target}).min(by:{timers[$0].at<timers[$1].at}) {
                let t=timers.remove(at:i);now=max(now,t.at);t.work()
            }
            now=target
        }
        var env=EventCapture.TypingEnvironment(now:{now},proof:{generation,version in
            var p=FocusProof();p.generation=generation;p.policyVersion=version;p.checkedAt=now
            p.bundle="com.apple.MobileSMS";p.windowID=window;p.focusID=focus;p.role="AXTextField";p.place=title;p.nativeLabels=labels
            p.sendField=SendRules.messagesField(role:p.role,subrole:p.subrole,labels:labels,title:title)
            p.surface = .native;p.secureInput = .no;p.privateMode = .no
            p.verified=true;p.fieldStateVerified=true;p.frameAccessible=true;p.navigationStable=true
            return p
        },schedule:{delay,work in timers.append((now+UInt64(delay*1_000_000_000),work))},secureInput:{false},
          departure:{DepartureState(secureInput:.no,bundle:"com.apple.MobileSMS",focusSecure:.no)},pressAndHold:{true})
        env.composerValue={valueReads+=1;return fieldValue}
        env.composerEmpty={empty}
        let capture=EventCapture(coordinator:coordinator,typingEnvironment:env)
        func type(_ text:String) {for c in text {now+=80_000_000;capture.handleNativeKey(eventAt:now,keyCode:0,shortcut:false) {String(c)}}}
        func shiftReturn() {now+=80_000_000;capture.handleNativeKey(eventAt:now,stroke:KeyStroke(keyCode:36,shift:true)) {"\r"}}
        /// Return, with the field's value at Return, and whether Messages empties it (after `clearAfter` seconds).
        func send(value:String,clears:Bool,clearAfter:Double=0.05) {
            fieldValue=value;empty=false
            now+=80_000_000;capture.handleNativeKey(eventAt:now,stroke:KeyStroke(keyCode:36)) {"\r"}
            if clears {timers.append((now+UInt64(clearAfter*1_000_000_000),{fieldValue="";empty=true}))}
            advance(1.0)
        }
        func typed() throws -> [(id:String,text:String,unit:TypedUnitProvenance?,state:String?)] {
            try store.rows("SELECT id FROM records WHERE json_extract(body,'$.kind')='keyboard.text_input' ORDER BY rowid").map {row in
                (row[0],try store.hydrateTypedText(row[0],disclosure:.owner) ?? "",try store.read(row[0])?.evidence.captureProvenance?.unit,try store.action(row[0])?.state)
            }
        }
        // Three sends in one conversation; the composer's value (capitals, autocorrect) is what was sent.
        type("me and my friendsr going to ZUX tmrw");send(value:"Me and my friendr going to ZUX tmrw",clears:true)
        type("wanna meet us there?");send(value:"Wanna meet us there?",clears:true)
        type("were gonna have a great time");send(value:"Were gonna have a great time",clears:true)
        var rows=try typed()
        check(rows.count == 3 && rows.allSatisfy {$0.state == "submitted" && $0.unit?.send == "detected" && $0.unit?.sendBy == "return" && $0.unit?.to == "Sam"},"messages-1003: three Returns that empty the composer are three sends to Sam")
        check(rows.map(\.text) == ["Me and my friendr going to ZUX tmrw","Wanna meet us there?","Were gonna have a great time"],"messages-1003: each send's text is the composer's value at Return")
        check(valueReads == 3,"messages-1003: the value is read once per Return, never per key")
        // A send, then a draft: Return, but the composer keeps its text (not sent).
        type("see you at 7");send(value:"See you at 7",clears:true)
        type("actually 8");send(value:"actually 8",clears:false)
        rows=try typed()
        check(rows[3].state == "submitted" && rows[4].state == "draft" && rows[4].unit?.send == "unknown","messages-1003: a composer that never empties leaves a draft (time alone never marks a send)")
        // The composer empties only late (after the last re-read): still a draft.
        type("late one");send(value:"late one",clears:true,clearAfter:0.9)
        check(try typed()[5].state == "draft","messages-1003: an empty composer after the confirmation window proves nothing")
        // A key typed right after Return ends the checks (the next message started).
        type("quick");fieldValue="quick";empty=false
        now+=80_000_000;capture.handleNativeKey(eventAt:now,stroke:KeyStroke(keyCode:36)) {"\r"}
        type("ok then.");timers.append((now+10_000_000,{empty=true}));advance(1.0)
        check(try typed()[6].state == "draft","messages-1003: keys after Return stop the re-reads: no send claimed")
        capture.flushNativeText(reason:.idle)
        // Shift-Return: a newline inside one message, one unit, one send.
        // In a fresh composer element: typing on in the same one would continue the idle piece's run (part 2,
        // never adopted: only a whole message is replaced by the composer's value).
        focus="composer-2"
        type("first line");shiftReturn();type("second line");send(value:"First line\nsecond line",clears:true)
        rows=try typed()
        check(["First line\nsecond line","First line second line"].contains(rows.last?.text ?? "") && rows.last?.state == "submitted","messages-1003: Shift-Return is a newline, not a send")
        // New Message with an empty To: no name ever; an unlabelled box is never a send.
        title="New Message";labels=[];focus="new-body"
        type("hello there");send(value:"Hello there",clears:true)
        rows=try typed()
        check(rows.last?.state == "draft" && rows.last?.unit?.to == nil && rows.last?.unit?.field == "oneLine","messages-1003: New Message, unproven box: a draft, no recipient")
        labels=["iMessage"];focus="new-body-2"
        type("hello again");send(value:"Hello again",clears:true)
        rows=try typed()
        check(rows.last?.state == "submitted" && rows.last?.unit?.to == nil,"messages-1003: New Message composer: a send to someone, no borrowed name")
        labels=["To:"];focus="to-box"
        type("Maya");send(value:"Maya",clears:true)
        check(try typed().last?.state == "draft","messages-1003: Return in the To box empties it but is never a send")
        // Two conversations.
        title="Maya";labels=["iMessage"];focus="composer-maya"
        type("running late");send(value:"Running late",clears:true)
        rows=try typed()
        check(rows.last?.unit?.to == "Maya" && rows.last?.state == "submitted" && rows[0].unit?.to == "Sam","messages-1003: each conversation keeps its own name")
        // Another window in front at the re-read: nothing proven.
        type("wrong window");fieldValue="wrong window";empty=false
        now+=80_000_000;capture.handleNativeKey(eventAt:now,stroke:KeyStroke(keyCode:36)) {"\r"}
        window="window-b";empty=true;advance(1.0)
        check(try typed().last?.state == "draft","messages-1003: an empty composer in another window proves nothing")
        window="window-a"
        // Mid-word: the witness keeps the composer's focus ID across Messages' element swap, so no "focus" seal.
        type("wanna me");capture.handleAX(kAXFocusedUIElementChangedNotification as String);type("et us there?")
        send(value:"Wanna meet us there?",clears:true)
        rows=try typed()
        check(rows.last?.text == "Wanna meet us there?" && rows.last?.unit?.part == 1 && rows.last?.state == "submitted","messages-1003: a repeated focus notification on the same composer never cuts a word")
        // Nothing typed went into a raw record body.
        let raw=try store.rows("SELECT body FROM records").compactMap {$0.first}.joined(separator:"\n")
        check(!raw.contains("friendr") && !raw.contains("Wanna meet"),"messages-1003: sent text stays sealed")
        coordinator.stop()
    }
    static func main() throws {
        setbuf(stdout,nil)
        try redundantNativeFocusNotifications()
        try messagesSendDetection()
        #if DAYDREAM_OWNER_TYPING
        // Owner build: website typing never uses the live Chrome witness here.
        installFakeWebRoute()
        if ProcessInfo.processInfo.environment["RECIPIENT_ROUTE_ONLY"] == "1" || ProcessInfo.processInfo.environment["RECIPIENT_SHORTCUT_ONLY"] == "1" || ProcessInfo.processInfo.environment["RECIPIENT_WEB_SHORTCUT_ONLY"] == "1" {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("production-recipient-route-"+UUID().uuidString)
            defer {try? FileManager.default.removeItem(at:root)}
            if ProcessInfo.processInfo.environment["RECIPIENT_WEB_SHORTCUT_ONLY"] != "1" {try nativeRecipientShortcuts(root:root.appendingPathComponent("native"))}
            try websiteRecipientAuthority(root:root.appendingPathComponent("web"))
            print("\(checks) actual recipient route checks passed.");return
        }
        if ProcessInfo.processInfo.environment["Q4_TITLE_ONLY"] == "1" {
            let liveFocus=NativeTypingRoute.keyFocus
            NativeTypingRoute.keyFocus={WebFakeChrome.pid}
            defer {NativeTypingRoute.keyFocus=liveFocus}
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("production-capture-q4-title-"+UUID().uuidString)
            defer {try? FileManager.default.removeItem(at:root)}
            try websiteTyping(root:root)
            print("\(checks) Q-4 synchronous saved-title checks passed.");return
        }
        // QF-17: only the bracketed route checks (the TSan run, R11: the rest is single-threaded and wall-clock paced).
        if ProcessInfo.processInfo.environment["QF17_ROUTE_ONLY"] != nil {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("production-capture-qf17-"+UUID().uuidString)
            defer {try? FileManager.default.removeItem(at:root)}
            try websiteTypingBracketed(root:root)
            if ProcessInfo.processInfo.environment["QF1_LIFECYCLE_ONLY"] != nil {try reopenChromeLifecycle(root:root)}
            print("\(checks) QF-17 route checks passed.")
            return
        }
        #endif
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("production-capture-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(home:root,writable:true,automaticallySyncSearch:false)
        // Safe typing B: typed words are sealed; checks use an in-memory key store.
        try store.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()));try store.setUpTypedVault();try store.acceptSafeTyping()
        var permission=true,notifications=0,reads=0
        let coordinator=try Coordinator(store:store,permissions:{permission}) {notifications+=1}
        // The status line (Settings › Diagnostics, Report a Problem) follows the saved summary setting.
        try store.setSummaryWriter("cloud")
        check(coordinator.label.contains("Cloud summaries ON (OpenRouter)") && !coordinator.label.contains("Cloud OFF"),"status label says cloud summaries are on when they are: \(coordinator.label)")
        try store.setSummaryWriter("off")
        check(coordinator.label.contains("Cloud OFF") && !coordinator.label.contains("Cloud summaries ON"),"status label says Cloud OFF only when cloud summaries are off")
        var nativeReceipts=[NativeCaptureReceipt]()
        coordinator.onNativeCommitted={nativeReceipts.append($0)}
        var mono:UInt64=10_000_000_000,focus="field-a",bundle="com.apple.Notes",secure=false,known=true,age:UInt64=0
        var proofCalls=0,flipAt:Int?=nil,failProofs=0
        // The window title read with the proof, and the field's subrole.
        var place="",subrole=""
        // Fake scheduler: timers run only when the fake clock is advanced.
        var timers:[(at:UInt64,work:()->Void)]=[]
        func schedule(_ delay:TimeInterval,_ work:@escaping ()->Void) {timers.append((mono+UInt64(delay*1_000_000_000),work))}
        func advance(_ seconds:Double) {
            let target=mono+UInt64(seconds*1_000_000_000)
            while let i=timers.indices.filter({timers[$0].at<=target}).min(by:{timers[$0].at<timers[$1].at}) {
                let timer=timers.remove(at:i);mono=max(mono,timer.at);timer.work()
            }
            mono=target
        }
        let environment=EventCapture.TypingEnvironment(now:{mono},proof:{generation,version in
            proofCalls+=1
            if proofCalls==flipAt {focus="raced-field";flipAt=nil}
            if failProofs>0 {failProofs-=1;return nil}
            guard known else {return nil}
            var p=FocusProof();p.generation=generation;p.policyVersion=version;p.checkedAt=mono-age
            p.bundle=bundle;p.windowID="window";p.focusID=focus;p.role="AXTextArea";p.subrole=subrole;p.place=place
            p.surface = bundle == "com.google.Chrome" ? .browser:.native
            p.secureInput=secure ? .yes:.no;p.privateMode = .no
            p.verified=true;p.fieldStateVerified=true;p.frameAccessible=true;p.navigationStable=true
            return p
        },schedule:schedule,secureInput:{secure},departure:{DepartureState(secureInput:secure ? .yes : .no,bundle:bundle,focusSecure:.unknown)},pressAndHold:{true})
        let capture=EventCapture(coordinator:coordinator,typingEnvironment:environment)
        func key(_ text:String,at:UInt64?=nil,code:Int64=0,shortcut:Bool=false) {
            capture.handleNativeKey(eventAt:at ?? mono,keyCode:code,shortcut:shortcut) {reads+=1;return text}
        }
        /// One key per character at a typing pace, timers firing in between.
        func type(_ text:String,every:Double=0.08) {
            for c in text {
                advance(every)
                if c == "\u{8}" {capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:51)) {reads+=1;return ""}}
                else {key(String(c))}
            }
        }
        /// The exact words of every typed row, read back through the store (the
        /// only way: record bodies hold text "" and a sealed pointer).
        func typedWords(_ s:MemoryStore) throws -> [String] {try s.rows("SELECT id FROM typed_text ORDER BY id").compactMap {try s.hydrateTypedText($0[0],disclosure:.owner)}}
        func words(_ s:MemoryStore,_ id:String) throws -> String {try s.hydrateTypedText(id,disclosure:.owner) ?? ""}
        func bodies() throws -> [String] {try typedWords(store)}
        func rawBodies(_ s:MemoryStore) throws -> [String] {try s.rows("SELECT body FROM records").compactMap {$0.first}}
        /// No saved typed word appears in any raw record body, and every typed
        /// row's body has text "".
        func noPlainText(_ s:MemoryStore) throws -> Bool {
            let raw=try rawBodies(s).joined(separator:"\n"),saved=try typedWords(s)
            let typedBodies=try s.rows("SELECT body FROM records WHERE json_extract(body,'$.kind')='keyboard.text_input'").map {try decode(Evidence.self,$0[0])}
            return !saved.isEmpty && !saved.contains {raw.contains($0)} && typedBodies.allSatisfy {$0.text.isEmpty && $0.typed != nil}
        }
        func count() throws -> Int {try store.actions(limit:200).actions.count}
        // Key timestamps: mach ticks on Apple silicon, nanoseconds on a 1:1 timebase.
        let silicon:(numer:UInt32,denom:UInt32)=(125,3),uptime:UInt64=224_751_472_873_625
        let ticks=uptime*3/125-2_400 // a key typed 100 us ago, in ticks
        check(EventCapture.eventNanoseconds(ticks,now:uptime,timebase:silicon)<=uptime &&
              uptime-EventCapture.eventNanoseconds(ticks,now:uptime,timebase:silicon)<1_000_000,
              "Apple silicon tick timestamps convert to uptime nanoseconds")
        check(EventCapture.eventNanoseconds(uptime-50_000,now:uptime,timebase:silicon)==uptime-50_000,
              "nanosecond timestamps pass through on Apple silicon")
        check(EventCapture.eventNanoseconds(uptime-50_000,now:uptime,timebase:(1,1))==uptime-50_000,
              "a 1:1 timebase leaves timestamps unchanged")
        check(EventCapture.eventNanoseconds(UInt64.max,now:uptime,timebase:silicon)==UInt64.max,
              "an overflowing timestamp is not converted")
        key("off text");capture.flushNativeText()
        check(try reads==0 && count()==0,"construction and default OFF produce zero reads and recordings")
        try coordinator.start();key("no consent");capture.flushNativeText()
        check(try reads==0 && count()==0,"recording alone is not typed-text opt-in")
        var policy=try store.policy();policy.captureText=true;policy.typedConsentVersion=1;try store.updatePolicy(policy)
        coordinator.captureText=true
        key("ordinary draft");capture.flushNativeText()
        check(try reads==1 && count()==1,"actual EventCapture entry commits permitted text once")
        check(notifications==1,"one existing commit callback, no second writer")
        let first=try store.actions(limit:10).actions.first!
        check(nativeReceipts.count==1 && nativeReceipts[0].actionID==first.id && nativeReceipts[0].path == .typedText,"EventCapture callback attributes exact persisted typed action")
        check(try coordinator.nativeReceipts.validated(store:store)?.0==nativeReceipts[0],"callback independently matches exact durable receipt readback")
        check(first.state=="draft","production typing stays a draft")
        let item=try store.read(first.id)!
        // Safe typing C: the store appends its own scrubber version to the capture classifier's.
        check(item.evidence.captureProvenance?.classifierVersion=="sensitive-typing/v2+typed-scrub/v1","production persistence includes privacy provenance (capture classifier + store scrubber)")
        capture.flushNativeText();check(try count()==1 && notifications==1,"duplicate flush does not write or schedule again")
        key("old focus candidate");focus="field-b";key("new focus draft");capture.flushNativeText()
        let actions=try store.actions(limit:20).actions
        check(try actions.count==2 && !typedWords(store).contains(where:{$0.contains("old focus")}),"focus switch parks the old unit without mixing fields")
        advance(0.4)
        let separate=try store.actions(limit:20).actions
        check(try separate.count==3 && typedWords(store).contains(where:{$0.contains("old focus candidate") && !$0.contains("new focus")}),"the old field becomes its own row after the 0.4 s settle")
        secure=true;let beforeSecure=reads;key("secure secret");capture.flushNativeText()
        check(try reads==beforeSecure && count()==3,"secure focus rejects before acquisition")
        secure=false;known=false;key("unknown");check(reads==beforeSecure,"unknown focus rejects before acquisition");known=true
        age=1_000_000_001;key("stale");check(reads==beforeSecure,"stale native proof rejects before acquisition");age=0
        key("old event",at:mono-1_000_000_001);check(reads==beforeSecure,"delayed OS event rejects before acquisition")
        bundle="com.google.Chrome";key("browser text");check(reads==beforeSecure,"browser text never acquired without native direct-field proof");bundle="com.apple.Notes"
        // Review I2: keys are judged when processed. A key processed more than
        // 150 ms after it was typed (unless nothing could have moved focus since
        // a key read on time in its field: capture-input-checks), and any key
        // typed within 400 ms of a denied or late key, is dropped before its
        // characters are read.
        key("typed just after a denial");check(reads==beforeSecure,"quiet period: key typed right after a denial is not read")
        mono += 600_000_000
        key("prompt key",at:mono-120_000_000);check(reads==beforeSecure+1,"key processed 120 ms after it was typed is read")
        key("late key",at:mono-150_000_001);check(reads==beforeSecure+1,"key processed more than 150 ms after it was typed, before the last key read on time, is not read")
        mono += 100_000_000;key("backlog");check(reads==beforeSecure+1,"backlog typed within 400 ms of a late key is not read")
        advance(0.5);check(try count()==4 && bodies().contains{$0.contains("prompt key")},"the unit typed on time before the late key is kept (golden 5 G7: the quiet period drops only the keys typed in it)")
        mono += 350_000_000;key("after quiet");check(reads==beforeSecure+2,"keys typed after the quiet period are read again");capture.flushNativeText()
        check(try count()==5,"the post-quiet unit commits on its own")
        capture.handleAX(kAXFocusedUIElementChangedNotification as String)
        key("password: do-not-persist");capture.flushNativeText()
        check(try count()==5,"secret classifier rejection produces no canonical record")
        key("suffix after secret");capture.flushNativeText()
        check(try count()==5,"secret rejection stays latched until a boundary")
        let beforeAX=reads
        capture.handleAX(kAXFocusedUIElementChangedNotification as String)
        key("after an AX focus change");capture.flushNativeText()
        check(try reads==beforeAX && count()==5,"an AX focus change alone does not clear the latch (the value may go on)")
        capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:48)) {reads+=1;return ""};advance(0.5)
        key("after real boundary");capture.flushNativeText();check(try count()==6,"Tab ends the value: the latch clears and a new harmless unit commits")
        key("pending pause");coordinator.pause("synthetic pause");capture.flushNativeText()
        check(try count()==6,"pause discards pending candidate")
        let beforePaused=reads;key("paused");check(reads==beforePaused,"paused key cannot read characters")
        try coordinator.start();key("pending revoke");permission=false;capture.flushNativeText()
        check(try count()==6,"permission revocation before flush blocks persistence")
        key("revoked key");check(try count()==6,"revoked keys remain blocked")
        permission=true;try coordinator.start()
        key("pending exclusion");policy=try store.policy();policy.blockedApps=["com.apple.Notes"];try store.updatePolicy(policy);capture.flushNativeText()
        check(try store.actions(limit:20).actions.isEmpty,"exclusion immediately hides earlier actions and cancels pending typing")
        let beforeExcluded=reads;key("excluded");check(reads==beforeExcluded,"excluded application rejects before acquisition")
        policy.blockedApps=[];try store.updatePolicy(policy);mono += 450_000_000
        key("pending sleep");capture.handleSuspension();capture.flushNativeText()
        check(try count()==7 && !coordinator.isRunning,"sleep commits the typed unit, then pauses without auto-resume")
        try coordinator.start();key("current candidate");capture.flushNativeText(expectedEpoch:0)
        check(try count()==7,"obsolete delayed callback cannot flush current candidate")
        capture.flushNativeText();check(try count()==8,"current callback commits exactly once")
        key("not acquired",code:36);check(try count()==9,"Return records one marker without acquiring characters")
        check(try store.actions(limit:20).actions.filter{$0.kind=="keyboard.submit"}.allSatisfy{$0.state=="draft"},"Return marker never implies send")
        key("discard on stop");coordinator.stop();capture.flushNativeText()
        check(try count()==9,"a direct Coordinator stop discards pending text")
        check(notifications==9,"one callback per committed action throughout lifecycle")
        try coordinator.start()
        policy=try store.policy();policy.captureText=false;try store.updatePolicy(policy)
        let beforeOptOut=reads;key("opted out");check(reads==beforeOptOut,"stored typed-text opt-out overrides runtime switch")
        policy.captureText=true;try store.updatePolicy(policy);mono += 450_000_000
        try store.exec("CREATE TRIGGER reject_capture BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT,'synthetic storage failure'); END")
        key("failed storage candidate");capture.flushNativeText()
        check(!coordinator.isRunning && notifications==9,"write failure pauses capture without notifying writer")
        try store.exec("DROP TRIGGER reject_capture")
        check(try count()==9,"write failure leaves no partial canonical action")
        try coordinator.start()
        key("draft before Return");key("not acquired",code:36)
        check(try count()==11,"Return commits a fresh draft and a separate non-send marker")
        check(notifications==11,"Return does not create a duplicate writer or duplicate action")
        let beforeRace=reads;flipAt=proofCalls+2;key("wrong focus race")
        check(reads==beforeRace && coordinator.isRunning,"focus race immediately before acquisition drops event without pausing healthy capture")
        let serialized=try json(store.actions(limit:200))
        check(!serialized.contains("do-not-persist") && !serialized.contains("pending revoke"),"rejected text absent from canonical reads")
        check(try store.rows("SELECT id FROM records WHERE body LIKE '%do-not-persist%' OR body LIKE '%pending revoke%' OR body LIKE '%failed storage candidate%'").isEmpty,"rejected candidates absent from raw SQLite records")
        check(try !typedWords(store).contains {$0.contains("do-not-persist") || $0.contains("pending revoke") || $0.contains("failed storage candidate")},"rejected candidates absent from the sealed words too")
        check(try noPlainText(store),"typed rows keep text \"\" in the body; no saved word is in any raw record")
        // Typed units through the actual EventCapture, one key per character.
        let beforeUnits=try count()
        advance(30);type("Teh\u{8}\u{8}\u{8}The quikc\u{8}\u{8}ck brown fox.");advance(31)
        check(try count()==beforeUnits+1 && bodies().contains(where:{$0.contains("The quick brown fox.")}),"Backspace corrections give one clean row")
        type("my wifi is ");advance(1);type("Xk9#mP2q");advance(1);type(" at home.");advance(31)
        check(try bodies().contains(where:{$0.contains("my wifi is [withheld] at home.")}),"an opaque token typed as its own stretch is withheld")
        type("password: hun");advance(2.5);type("ter2 and more words");advance(25);key("",code:36)
        type("my code is Tr0ub");advance(3);type("4dor&3 ok");advance(61)
        type("my password is hunter2 ok");advance(25);key("",code:36)
        check(try store.rows("SELECT id FROM records WHERE body LIKE '%hun%' OR body LIKE '%ter2%' OR body LIKE '%Tr0ub%' OR body LIKE '%4dor%'").isEmpty && !typedWords(store).contains {$0.contains("hun") || $0.contains("ter2") || $0.contains("Tr0ub") || $0.contains("4dor")},"raw SQLite and the sealed words never contain the P1, P2 or P6 secrets")
        type("notes before switching.");capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:48,command:true)) {reads+=1;return ""}
        let beforeSwitch=try count();bundle="com.example.Other";known=false
        advance(0.3);check(try count()==beforeSwitch,"Cmd-Tab: nothing before the settle")
        advance(0.2);check(try bodies().contains(where:{$0.contains("notes before switching.")}),"Cmd-Tab: the unit commits 0.4 s later when focus left for another app")
        bundle="com.apple.Notes";known=true
        type("typed then passwords");capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:48,command:true)) {reads+=1;return ""}
        bundle="com.apple.Passwords";known=false;advance(1);bundle="com.apple.Notes";known=true
        check(try !bodies().contains(where:{$0.contains("typed then passwords")}),"switching to a password manager discards the unit")
        type("settle then sleep");capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:48)) {reads+=1;return ""}
        focus="field-c";advance(0.1);capture.handleSuspension()
        check(try bodies().contains(where:{$0.contains("settle then sleep")}) && !coordinator.isRunning,"sleep during a settle commits the parked unit")
        let typedRows=try store.actions(limit:200).actions.compactMap {try store.read($0.id)}.filter {$0.evidence.kind=="keyboard.text_input"}
        // summaries/v3: rows sealed now carry the send facts (typed-unit/v3; spec §2).
        check(!typedRows.isEmpty && typedRows.allSatisfy {$0.evidence.captureProvenance?.unit?.version=="typed-unit/v3" && $0.evidence.captureProvenance?.classifierVersion=="sensitive-typing/v2+typed-scrub/v1"},"every typed row carries typed-unit provenance and passed the store scrubber")
        // summaries/v3 (spec §3): through the real EventCapture, Notes is a writing surface: Return there is never a send,
        // so every Notes row is a draft whose facts say send none, and no row is submitted or sent.
        let notesRows=typedRows.filter {$0.evidence.bundle=="com.apple.Notes"}
        check(!notesRows.isEmpty && notesRows.allSatisfy {$0.evidence.captureProvenance?.unit?.surface=="writing" && $0.evidence.captureProvenance?.unit?.send=="none" && $0.evidence.captureProvenance?.unit?.sendBy==nil},
              "summaries/v3: Notes rows store surface writing and send none")
        check(try store.actions(limit:200).actions.filter {$0.kind=="keyboard.text_input"}.allSatisfy {$0.state=="draft"},"summaries/v3: no Notes row is submitted or sent")
        let returnSealed=notesRows.filter {$0.evidence.captureProvenance?.unit?.sealReason=="submit"}
        check(!returnSealed.isEmpty && returnSealed.allSatisfy {$0.evidence.captureProvenance?.unit?.field != nil},"summaries/v3: a Return-sealed Notes row keeps its field class and seal")
        let withheldRow=try typedRows.first {try words(store,$0.id).contains("my wifi is [withheld] at home.")}?.evidence.captureProvenance?.unit
        let cleanRow=try typedRows.first {try words(store,$0.id).contains("The quick brown fox.")}?.evidence.captureProvenance?.unit
        check(withheldRow?.withheld == 1 && withheldRow?.keys == nil && withheldRow?.edits == nil,"PV7: a row with withheld text records no key or edit counts")
        check(cleanRow?.keys != nil && cleanRow?.edits == 5 && cleanRow?.withheld == 0,"a row with nothing withheld keeps its counts")
        try coordinator.start()
        // C9: the host judges a parked unit by departure metadata when focus
        // went to an excluded app (it no longer discards it).
        policy=try store.policy();policy.blockedApps=["com.apple.TextEdit"];try store.updatePolicy(policy)
        type("notes before a blocked app.");capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:48,command:true)) {reads+=1;return ""}
        bundle="com.apple.TextEdit";advance(0.5)
        check(try bodies().contains(where:{$0.contains("notes before a blocked app.")}) && coordinator.isRunning,"C9: switching from Notes to an excluded TextEdit commits the Notes unit")
        let beforeBlocked=reads;key("typed in the blocked app");check(reads==beforeBlocked,"keys in the excluded app are never read")
        bundle="com.apple.Notes";policy.blockedApps=[];try store.updatePolicy(policy)
        // C6: one unreadable proof is read again once.
        advance(1);type("hello ");failProofs=1;type("w");type("orld.");advance(31)
        check(try bodies().contains(where:{$0.contains("hello world.")}),"C6: one failed proof read is retried, the key is kept")
        // C5: a press-and-hold popup pick is applied without reading anything.
        type("caf");advance(0.08);key("e",code:14)
        for _ in 0..<3 {advance(0.08);capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:14,autorepeat:true)) {reads+=1;return "e"}}
        let beforeAccent=reads;advance(0.2);capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:19)) {reads+=1;return "2"}
        check(reads==beforeAccent,"C5: the popup digit is not read")
        type(" au lait.");advance(31)
        check(try bodies().contains(where:{$0.contains("caf\u{E9} au lait.")}),"C5: the chosen accent replaces the held letter")
        // C7: redo commits what was typed and writes a marker.
        let beforeRedo=try count()
        type("before redo");capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:6,command:true,shift:true)) {reads+=1;return ""}
        check(try count()==beforeRedo+2 && bodies().contains(where:{$0.contains("before redo")}),"C7: Cmd-Shift-Z commits the unit and writes one marker")
        // C8: Fn/Globe with a letter seals and reads nothing.
        type("before globe");let beforeGlobe=reads
        capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:14,fn:true)) {reads+=1;return "e"};advance(0.5)
        check(try reads==beforeGlobe && bodies().contains(where:{$0.contains("before globe")}),"C8: Fn-E seals the unit without reading the key")
        // W0: the typing pause chord (Control-Option-Command-T) leaves no shortcut row.
        func markers(_ kind:String) throws -> Int {Int(try store.rows("SELECT count(*) FROM records WHERE json_extract(body,'$.kind')='\(kind)'")[0][0]) ?? -1}
        advance(1);let shortcutsBefore=try markers("keyboard.shortcut"),chordReads=reads
        type("before the pause chord");capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:17,command:true,control:true,option:true)) {reads+=1;return "t"};advance(0.5)
        check(try markers("keyboard.shortcut")==shortcutsBefore && bodies().contains(where:{$0.contains("before the pause chord")}) && reads==chordReads+22,
              "W0: Control-Option-Command-T writes no keyboard.shortcut row (the unit before it is still kept, the chord is not read)")
        capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:15,command:true,control:true,option:true)) {reads+=1;return "r"};advance(0.5)
        check(try markers("keyboard.shortcut")==shortcutsBefore+1,"W0 control: Control-Option-Command-R still writes one keyboard.shortcut row")
        capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:17,command:true,control:true,option:true,shift:true)) {reads+=1;return "t"};advance(0.5)
        check(try markers("keyboard.shortcut")==shortcutsBefore+2,"W0 control: the chord with Shift added still writes its row")
        // W0: Esc in a search field discards the unfinished search.
        subrole="AXSearchField";focus="search-field"
        type("half typed search words");capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:53)) {reads+=1;return ""};advance(31)
        check(try !bodies().contains(where:{$0.contains("half typed search words")}),"W0: Esc in a search field discards the search, never saved")
        type("submitted search words");key("",code:36);advance(1)
        check(try bodies().contains(where:{$0.contains("submitted search words")}),"W0 control: Return in the same search field keeps the search")
        subrole="";focus="field-esc"
        type("note text before esc.");capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:53)) {reads+=1;return ""};advance(1)
        check(try bodies().contains(where:{$0.contains("note text before esc.")}),"W0 control: Esc in an ordinary field parks the unit, which is kept")
        // W0: the window title read with the proof is the row's place label,
        // through the store's title rules and scrubber.
        func rowTitle(_ text:String) throws -> String? {
            try store.rows("SELECT id FROM typed_text ORDER BY id").map {$0[0]}.first {try words(store,$0).contains(text)}.flatMap {try store.read($0)?.evidence.title}
        }
        place="Groceries \u{2014} Notes";focus="field-place"
        type("milk and eggs today.");advance(31)
        check(try rowTitle("milk and eggs today.")=="Groceries \u{2014} Notes","W0: the window title reaches the typed row as its place label")
        let placeToken="ghp_"+String(repeating:"Q7x",count:12)
        place="deploy "+placeToken;focus="field-secret-place"
        type("rotate the deploy key soon.");advance(31)
        let secretTitle=try rowTitle("rotate the deploy key soon.")
        let rawHasToken=try rawBodies(store).joined().contains(placeToken)
        check(secretTitle != nil && !(secretTitle ?? "").contains(placeToken) && !rawHasToken,
              "W0: a secret-looking place label is scrubbed before it is saved")
        place="";focus="field-a"
        // New native reader -> actual EventCapture -> CoreCaptureBinding -> DB.
        // The only replacement is the OS metadata provider, never the reader.
        let nativeStore=try MemoryStore(home:root.appendingPathComponent("native-reader"),writable:true,automaticallySyncSearch:false)
        let nativeKeys=InMemoryTypedKeyStore();try nativeStore.attachVault(TypedTextVault(keyStore:nativeKeys))
        var nativeReads=0,nativeNotices=0,safeNative=true,nativeFocus=1
        let nativeCoordinator=try Coordinator(store:nativeStore,permissions:{true}) {nativeNotices+=1}
        let witness=NativeFocusWitness<Int>()
        let nativeAccess=NativeFocusAccess<Int>(now:{mono},ready:{safeNative},identity:{"synthetic-signed-native-process"},focusedApplication:{7},window:{3},focus:{nativeFocus},owner:{_ in 7},role:{$0==3 ? "AXWindow":"AXTextArea"},subrole:{_ in ""},parent:{_ in 3},equal:{$0==$1})
        let nativeCapture=EventCapture(coordinator:nativeCoordinator,typingEnvironment:.init(now:{mono},proof:{generation,version in
            witness.read(pid:7,bundle:"com.apple.TextEdit",generation:generation,policyVersion:version,access:nativeAccess)
        },schedule:schedule,secureInput:{!safeNative},departure:{DepartureState(secureInput:.no,bundle:"com.apple.TextEdit",focusSecure:.no)},pressAndHold:{true}))
        func nativeKey(_ text:String) {nativeCapture.handleNativeKey(eventAt:mono,keyCode:0,shortcut:false){nativeReads+=1;return text}}
        nativeKey("off");check(nativeReads==0,"combined native binding remains unread at default OFF")
        var nativePolicy=try nativeStore.policy();nativePolicy.captureText=true;nativePolicy.typedConsentVersion=1;try nativeStore.updatePolicy(nativePolicy)
        nativeCoordinator.captureText=true;try nativeCoordinator.start()
        // Hard rule: consent is not enough while typed text can't be encrypted.
        nativeKey("no vault yet");nativeCapture.flushNativeText()
        check(try nativeReads==0 && nativeStore.actions(limit:10).actions.isEmpty,"consent without a ready vault reads no characters")
        try nativeStore.setUpTypedVault();mono += 450_000_000
        // Safe typing E/F: a ready key is not consent; the safe-typing screen (v2) is.
        nativeKey("no safe-typing consent yet");nativeCapture.flushNativeText()
        check(try nativeReads==0 && nativeStore.actions(limit:10).actions.isEmpty,"a ready vault without the safe-typing screen reads no characters")
        try nativeStore.acceptSafeTyping();mono += 450_000_000
        nativeKey("dummy native draft");nativeCapture.flushNativeText()
        check(try nativeStore.actions(limit:10).actions.count==1 && nativeNotices==1,"actual native witness reaches canonical store once")
        nativeKey("prior old field");nativeFocus=2;nativeKey("new native field");nativeCapture.flushNativeText()
        let nativeActions=try nativeStore.actions(limit:10).actions
        check(try nativeActions.count==2 && !typedWords(nativeStore).contains{$0.contains("prior old")},"exact native object change parks the prior unit, never mixed")
        advance(0.4)
        check(try nativeStore.actions(limit:10).actions.count==3,"the prior native field becomes its own row after the settle")
        safeNative=false;let priorNativeReads=nativeReads;nativeKey("secure boundary");nativeCapture.flushNativeText()
        check(nativeReads==priorNativeReads,"combined native proof failure rejects before characters")
        safeNative=true;mono += 450_000_000;nativeKey("pending native sleep");nativeCapture.handleSuspension();nativeCapture.flushNativeText()
        check(try nativeStore.actions(limit:10).actions.count==4 && !nativeCoordinator.isRunning,"combined native sleep commits the unit, then pauses")
        check(nativeNotices==4,"combined reader introduces no duplicate capture writer")
        check(try noPlainText(nativeStore),"native reader: typed rows are sealed, no word in raw records")
        nativeKeys.locked=true;_=try nativeStore.reconcileTypedVault();try nativeCoordinator.start();mono += 450_000_000
        let beforeLocked=nativeReads;nativeKey("locked keychain");nativeCapture.flushNativeText()
        check(try nativeReads==beforeLocked && nativeStore.actions(limit:10).actions.count==4,"a locked Keychain stops reading characters (typing locked)")
        nativeKeys.locked=false;_=try nativeStore.reconcileTypedVault()
        // Spotlight-style panel: it takes key focus while Notes stays frontmost, so
        // `ready` (frontmost, permissions, secure input) stays true throughout and only
        // the system-wide focused application changes. Actual EventCapture and witness.
        let panelStore=try MemoryStore(home:root.appendingPathComponent("panel-focus"),writable:true,automaticallySyncSearch:false)
        try panelStore.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()));try panelStore.setUpTypedVault();try panelStore.acceptSafeTyping()
        var panelReads=0,keyFocus:Int32?=7
        let panelCoordinator=try Coordinator(store:panelStore,permissions:{true}) {}
        let panelWitness=NativeFocusWitness<Int>()
        let notesAccess=NativeFocusAccess<Int>(now:{mono},ready:{true},identity:{"synthetic-signed-notes"},focusedApplication:{keyFocus},window:{3},focus:{1},owner:{_ in 7},role:{$0==3 ? "AXWindow":"AXTextArea"},subrole:{_ in ""},parent:{_ in 3},equal:{$0==$1})
        let panelCapture=EventCapture(coordinator:panelCoordinator,typingEnvironment:.init(now:{mono},proof:{generation,version in
            panelWitness.read(pid:7,bundle:"com.apple.Notes",generation:generation,policyVersion:version,access:notesAccess)
        }))
        func notesKey(_ text:String,code:Int64=0) {panelCapture.handleNativeKey(eventAt:mono,keyCode:code,shortcut:false){panelReads+=1;return text}}
        /// Typed rows are read back through the store (their descriptions hold no words).
        func panelActions(_ kind:String) throws -> [String] {try panelStore.actions(limit:20).actions.filter{$0.kind==kind}.map{kind=="keyboard.text_input" ? try words(panelStore,$0.id) : $0.description}}
        var panelPolicy=try panelStore.policy();panelPolicy.captureText=true;panelPolicy.typedConsentVersion=1;try panelStore.updatePolicy(panelPolicy)
        panelCoordinator.captureText=true;try panelCoordinator.start()
        keyFocus=99;notesKey("spotlight query at start");panelCapture.flushNativeText()
        check(try panelReads==0 && panelActions("keyboard.text_input").isEmpty,"burst start: no key is read while a panel holds key focus over frontmost Notes")
        keyFocus=7;mono += 450_000_000;notesKey("notes line before panel")
        check(panelReads==1,"ordinary Notes key is read while Notes holds key focus")
        keyFocus=99;notesKey("weather tomorrow");notesKey("",code:36)
        check(panelReads==1,"every key: keys typed into the panel are never read")
        panelCapture.flushNativeText()
        check(try panelActions("keyboard.text_input").isEmpty,"panel keys discard the pending Notes burst")
        check(try panelActions("keyboard.submit").isEmpty,"Return pressed in the panel records no Notes marker")
        keyFocus=7;mono += 450_000_000;notesKey("second notes line")
        keyFocus=99;panelCapture.flushNativeText()
        check(try panelActions("keyboard.text_input").isEmpty,"save: a burst whose save runs while a panel holds key focus is discarded")
        keyFocus=nil;notesKey("unknown focus line");panelCapture.flushNativeText()
        check(try panelActions("keyboard.text_input").isEmpty,"unknown system-wide key focus fails closed")
        keyFocus=7;mono += 450_000_000;notesKey("fresh notes line");panelCapture.flushNativeText()
        let panelSaved=try panelActions("keyboard.text_input")
        check(panelSaved.count==1 && panelSaved[0].contains("fresh notes line"),"back in Notes, a new burst saves")
        check(!panelSaved.contains{$0.contains("spotlight") || $0.contains("weather") || $0.contains("before panel") || $0.contains("second notes") || $0.contains("unknown focus")},"nothing typed before or inside the panel reaches the saved burst")
        check(try panelStore.rows("SELECT id FROM records WHERE body LIKE '%weather tomorrow%' OR body LIKE '%spotlight query%'").isEmpty && !typedWords(panelStore).contains{$0.contains("weather tomorrow") || $0.contains("spotlight query")},"panel text absent from raw SQLite records and the sealed words")
        // Review I2: Spotlight closed before the key was processed. The proof
        // (Notes has key focus again) describes processing time, not typing time.
        // Command-Space opened it (handled late too, just before the key).
        mono += 450_000_000;let beforeLate=panelReads
        keyFocus=7;panelCapture.handleNativeKey(eventAt:mono-320_000_000,stroke:KeyStroke(keyCode:49,command:true)){""}
        panelCapture.handleNativeKey(eventAt:mono-300_000_000,keyCode:0,shortcut:false){panelReads+=1;return "typed into spotlight, processed late"}
        check(panelReads==beforeLate,"a key typed into Spotlight and processed 300 ms later, after it closed, is not read")
        mono += 450_000_000
        keyFocus=99;notesKey("spotlight key processed while open")
        keyFocus=7;mono += 100_000_000
        panelCapture.handleNativeKey(eventAt:mono-20_000_000,keyCode:0,shortcut:false){panelReads+=1;return "typed into spotlight just before it closed"}
        check(panelReads==beforeLate,"a key typed into Spotlight just before it closed, processed promptly after, is not read (quiet after the denial)")
        panelCapture.flushNativeText()
        check(try panelStore.rows("SELECT id FROM records WHERE body LIKE '%typed into spotlight%'").isEmpty && !typedWords(panelStore).contains{$0.contains("typed into spotlight")},"late Spotlight keys absent from raw SQLite records")
        check(try noPlainText(panelStore) && noPlainText(store),"every typed row in every fixture store is sealed")
        mono += 1_000_000_000
        try chromePages(root:root)
        #if DAYDREAM_OWNER_TYPING
        try websiteTyping(root:root)
        try websitePostGesture(root:root)
        try websiteComposeConfirm(root:root)
        try websiteSwitchShortcuts(root:root)
        try websiteDiagnosticsUniform(root:root)
        witnessChildren()
        try websiteTypingBracketed(root:root)
        #endif
        print("\(checks) production EventCapture checks passed. No tap, AX read, OS grant, Apple Event or real capture started.")
    }

    /// Chrome page history through the actual EventCapture, Coordinator and
    /// store, with a fake ChromePageEnvironment: zero Apple Events, no signature
    /// or Automation check, no OS read of Chrome.
    static func chromePages(root:URL) throws {
        let store=try MemoryStore(home:root.appendingPathComponent("chrome-pages"),writable:true,automaticallySyncSearch:false)
        let coordinator=try Coordinator(store:store,permissions:{true}) {}
        var receipts=[NativeCaptureReceipt]()
        coordinator.onNativeCommitted={receipts.append($0)}
        let chrome:pid_t=99_999 // above macOS's highest pid: never a real process
        var front:(pid:pid_t,bundle:String,launch:String,name:String)?=(chrome,"com.google.Chrome","99999:1:com.google.Chrome","Google Chrome")
        var instances=1,secure=false,signed=true,access:OSStatus=noErr,unreadable=false
        var verifies=0,permissions=0,sessions=0,events=[ChromePageRequest]()
        var windows=["w1"],modes=[String:String](),title="Q3 plan - Docs"
        let url="https://example.org/plans/q3?id=7#top"
        var deferred:[()->Void]?=nil // non-nil: background work waits here until run
        var hop=0.0 // > 0: the return to the main thread takes this long (review M3)
        var idle:TimeInterval=0 // seconds since the last key, click or mouse move (review m3)
        var timers:[(at:Date,work:()->Void)]=[]
        func advance(_ seconds:Double) {
            Thread.sleep(forTimeInterval:seconds)
            while let i=timers.indices.filter({timers[$0].at<=Date()}).min(by:{timers[$0].at<timers[$1].at}) {timers.remove(at:i).work()}
        }
        func runDeferred() {let work=deferred ?? [];deferred=[];work.forEach {$0()}}
        let environment=ChromePageEnvironment(
            frontmost:{front},instances:{instances},secureInput:{secure},
            verify:{_,_ in verifies+=1;return signed},
            permission:{_ in permissions+=1;return access},
            transport:{_ in
                sessions+=1
                return {request in
                    events.append(request)
                    if unreadable {return nil}
                    switch request {
                    case .windowIDs:return .ids(windows)
                    case .mode(let w):return .text(modes[w] ?? "normal")
                    case .activeTabID:return .text("t1")
                    case .tabURL:return .text(url)
                    case .tabTitle:return .text(title)
                    }
                }
            },
            background:{work in if deferred != nil {deferred!.append(work)} else {work()}},
            main:{work in if hop > 0 {timers.append((Date().addingTimeInterval(hop),work))} else {work()}},
            schedule:{delay,work in timers.append((Date().addingTimeInterval(delay),work))},
            now:{Date()},
            idleSeconds:{idle})
        var reads=0,chromeProof=false
        let typing=EventCapture.TypingEnvironment(proof:{generation,version in
            // Production gives Chrome no typing proof; the forged one is a browser surface.
            guard chromeProof else {return nil}
            var p=FocusProof();p.generation=generation;p.policyVersion=version;p.checkedAt=DispatchTime.now().uptimeNanoseconds
            p.bundle="com.google.Chrome";p.windowID="window";p.focusID="field";p.role="AXTextArea";p.surface = .browser
            p.secureInput = .no;p.privateMode = .no;p.verified=true;p.fieldStateVerified=true;p.frameAccessible=true;p.navigationStable=true
            return p
        },schedule:{_,_ in})
        let capture=EventCapture(coordinator:coordinator,typingEnvironment:typing,pageEnvironment:environment)
        func key() {capture.handleNativeKey(eventAt:DispatchTime.now().uptimeNanoseconds,keyCode:0,shortcut:false) {reads+=1;return "x"}}
        func toChrome() {front=(chrome,"com.google.Chrome","99999:1:com.google.Chrome","Google Chrome");capture.switchFrontmost(pid:chrome,bundle:"com.google.Chrome") {_,_ in}}
        func pages() throws -> [Evidence] {
            try store.actions(limit:200).actions.compactMap {try store.read($0.id)?.evidence}.filter {$0.bundle == "com.google.Chrome"}
        }
        func appTimes() throws -> [Evidence] {try pages().filter {$0.browserVerification?.provider == BrowserSafety.appTimeProvider}}
        func setPages(_ on:Bool) throws {var p=try store.policy();p.browserPages=on;p.browserPagesConsentVersion=on ? PrivacySettings.browserPagesConsentCurrent:nil;try store.updatePolicy(p)}
        func pageEvents(_ list:[ChromePageRequest]) -> Int {list.filter {if case .tabURL = $0 {return true};if case .tabTitle = $0 {return true};return false}.count}
        func spin(_ seconds:Double) {RunLoop.main.run(until:Date().addingTimeInterval(seconds))}
        try coordinator.start()
        // Switch off (the default): Chrome is not recorded and nothing is asked.
        var observedChrome:Bool?
        capture.switchFrontmost(pid:chrome,bundle:"com.google.Chrome") {_,isChrome in observedChrome=isChrome}
        for _ in 0..<20 {capture.pages.tick()}
        capture.handleAX(kAXTitleChangedNotification as String);spin(0.25)
        check(try capture.pages.probes == 0 && verifies == 0 && permissions == 0 && sessions == 0 && events.isEmpty && pages().isEmpty,
              "page history: switch off: no read, zero signature, Automation or Apple Event calls")
        check(observedChrome == true,"page history: Chrome is observed as Chrome (window and title notifications only)")
        // Switch on: app switch -> read -> confirm -> exactly one row.
        try setPages(true)
        toChrome()
        check(try capture.pages.probes == 1 && pages().isEmpty && timers.count == 1,"page history: app switch to Chrome reads once and saves nothing before the dwell")
        check(events == [.windowIDs,.mode("w1"),.activeTabID("w1"),.tabURL("w1","t1"),.tabTitle("w1","t1"),.windowIDs,.mode("w1"),.activeTabID("w1"),.tabURL("w1","t1")],
              "page history: the live read order is list, mode, tab, address, title, then the re-check")
        check(AccessibilityReader.status == ChromePageRecorder.status,"page history: the status line is the neutral Chrome pages text")
        advance(1.3)
        var saved=try pages()
        check(saved.count == 1 && capture.pages.probes == 2,"page history: the confirm read 1.2 s later saves exactly one row")
        let revisionNow=try store.policy().revision,latestID=try store.actions(limit:5).actions.first?.id
        if let row=saved.first {
            check(row.kind == "window.changed" && row.title == "Q3 plan - Docs" && row.url == "https://example.org" && row.text.isEmpty && !row.secure && !row.privateWindow,
                  "page history: the row is title, origin and time only")
            check(row.browserVerification?.provider == BrowserSafety.pageProvider && row.browserVerification?.mode == "normal" && row.browserVerification?.focusedRole == ""
                  && row.browserVerification?.policyRevision == revisionNow && row.app == "Google Chrome",
                  "page history: the row carries the page proof and the policy revision")
        } else {check(false,"page history: a page row exists")}
        check(receipts.last?.path == .metadata && receipts.last?.actionID == latestID,"page history: the page row has a metadata receipt")
        // fix/show-all: the row keeps the page's own link (scheme, host and path) on this Mac for Open Original; the query and
        // fragment never reach SQLite, and the path only as that link (`Evidence.page`), never in the title, url or text.
        check(try store.rows("SELECT id FROM records WHERE body LIKE '%id=7%' OR body LIKE '%#top%'").isEmpty,
              "page history: the query and fragment never reach SQLite")
        if let row=saved.first {
            check(row.page == "https://example.org/plans/q3" && !row.url.contains("plans") && !row.title.contains("plans") && !row.text.contains("plans"),
                  "page history: the path is kept only as the row's local page link")
        }
        // Poll: every 6th tick (3 s); the same page is not saved again.
        var before=capture.pages.probes
        for _ in 0..<5 {capture.pages.tick()}
        check(capture.pages.probes == before,"page history: no poll read before 3 s")
        capture.pages.tick()
        check(try capture.pages.probes == before+1 && pages().count == 1 && timers.isEmpty,"page history: the same page on the poll: no second row")
        // A title change: the AX title notification reads, the dwell saves a new row.
        title="Q4 plan - Docs"
        capture.handleAX(kAXTitleChangedNotification as String);spin(0.25)
        check(try capture.pages.probes == before+2 && pages().count == 1,"page history: a title change reads the page again")
        advance(1.3)
        saved=try pages()
        check(saved.count == 2 && saved.contains {$0.title == "Q4 plan - Docs"},"page history: a title change is a new row after the dwell")
        // Keys, value, selection and focused-element changes never start a read.
        before=capture.pages.probes
        for _ in 0..<5 {key()}
        for note in [kAXValueChangedNotification,kAXSelectedTextChangedNotification,kAXFocusedUIElementChangedNotification] {capture.handleAX(note as String)}
        spin(0.25)
        check(try capture.pages.probes == before && reads == 0 && pages().count == 2,"page history: keys, value, selection and focus changes in Chrome start no read")
        // Any Incognito window: nothing, and no address or title is asked.
        windows=["w1","w2"];modes["w2"]="incognito";title="Q5 plan - Docs";events=[]
        for _ in 0..<6 {capture.pages.tick()}
        advance(1.3);for _ in 0..<6 {capture.pages.tick()}
        check(try pages().count == 2 && pageEvents(events) == 0 && !events.isEmpty,"page history: an Incognito window open: no row, no address or title asked")
        windows=["w1"];modes=[:];title="Q4 plan - Docs"
        for _ in 0..<6 {capture.pages.tick()}
        advance(1.3)
        check(try pages().count == 3,"page history: the same page after the Incognito window closes is saved again")
        // Review G30: every read that still counts tells the app what it learned about Chrome access
        // (the menu bar line follows it), never a page, a site or a mode.
        var told:[ChromePageRecorder.Access]=[]
        capture.pages.onAccess={told.append($0)}
        // Automation denied (-1743): zero Apple Events, the poll slows to 30 s.
        access = -1743;var sessionsBefore=sessions,eventsBefore=events.count
        let appTimeBefore=try appTimes().count
        toChrome()
        // Live test (build 7): Chrome's page can't be read, so Chrome's time is saved as the app's name only.
        let appTime=try appTimes()
        check(appTime.count == appTimeBefore+1,"Chrome app time: access off still saves one Chrome app row")
        let policyNow=try store.policy()
        if let row=appTime.last {
            check(row.kind == "app.activated" && row.app == "Google Chrome" && row.title.isEmpty && row.url.isEmpty && row.text.isEmpty
                  && row.browserVerification?.windowID == "" && row.browserVerification?.tabID == "" && row.browserVerification?.policyRevision == policyNow.revision,
                  "Chrome app time: the row is the app's name and the time, nothing else")
            check(BrowserSafety.valid(row) && Privacy.sanitized(row,settings:policyNow) != nil,"Chrome app time: the row is valid and shown at read time")
            var titled=row;titled.title="Inbox";var addressed=row;addressed.url="https://example.org";var windowed=row;windowed.browserVerification?.windowID="w1"
            var clicked=row;clicked.kind="mouse.clicked"
            check([titled,addressed,windowed,clicked].allSatisfy {!BrowserSafety.valid($0)},"Chrome app time: a title, an address, a window or another kind is refused")
        }
        for _ in 0..<130 {capture.pages.tick()}
        check(try appTimes().count == appTimeBefore+1,"Chrome app time: once per stint in front, not per poll")
        check(sessions == sessionsBefore && events.count == eventsBefore && capture.pages.lastPermission == -1743 && capture.pages.pollPeriod == 30,
              "page history: Chrome access off (-1743): zero Apple Events, poll every 30 s")
        check(told.last == .status(-1743),"page history (G30): a read that finds Chrome access off tells the app")
        access=noErr
        // Signature fails: no Automation check and zero Apple Events.
        signed=false;let permissionsBefore=permissions;sessionsBefore=sessions
        toChrome()
        check(permissions == permissionsBefore && sessions == sessionsBefore && capture.pages.lastVerified == false,
              "page history: a Chrome that is not signed by Google: zero Apple Events")
        check(told.last == .unverified,"page history (G30): a read that can't verify Chrome tells the app")
        check(try appTimes().count == appTimeBefore+2 && appTimes().last?.app == "Google Chrome","Chrome app time: an unverified Chrome is saved by the fixed name only")
        signed=true
        toChrome()
        check(told.last == .status(noErr),"page history (G30): a read that works tells the app access is on again")
        // Two of the person's own Chrome processes (another profile directory): no read at all, and Settings is told
        // (live test, build 7: never the "Chrome just updated" line). A headless Chrome is not counted (ChromeProcesses).
        instances=2;before=capture.pages.probes;let verifiesBefore=verifies;told=[]
        toChrome();for _ in 0..<20 {capture.pages.tick()}
        check(capture.pages.probes == before && verifies == verifiesBefore,"page history: two Chrome processes: no read")
        check(!told.isEmpty && told.allSatisfy { $0 == .twoCopies },"page history: two of the person's Chromes tell the app so (\(told.count))")
        check(try appTimes().count == appTimeBefore+3,"Chrome app time: two copies of Chrome still save Chrome's time, once")
        capture.pages.onAccess=nil
        instances=1
        // Secure input: no read; turned on during a read: the result is dropped.
        secure=true;before=capture.pages.probes;instances=2;let appTimeSecure=try appTimes().count
        toChrome()
        check(capture.pages.probes == before,"page history: secure input on: no read")
        check(try appTimes().count == appTimeSecure,"Chrome app time: secure input on: no row");instances=1
        secure=false;timers=[];title="Q6 plan - Docs";deferred=[]
        var count=try pages().count
        toChrome();secure=true;runDeferred();secure=false
        check(try pages().count == count && timers.isEmpty,"page history: secure input turned on during a read: result dropped")
        // A result that arrives after an app switch or a pause is dropped.
        toChrome()
        front=(4_242,"com.apple.Notes","4242:1:com.apple.Notes","Notes");capture.switchFrontmost(pid:4_242,bundle:"com.apple.Notes") {_,_ in}
        runDeferred()
        check(try pages().count == count && timers.isEmpty,"page history: a result that arrives after switching to another app is dropped")
        toChrome();coordinator.pause("synthetic pause");runDeferred()
        check(try pages().count == count && timers.isEmpty,"page history: a result that arrives after recording paused is dropped")
        try coordinator.start();deferred=nil
        // Unreadable (timeout): the poll backs off 6, 12, 24, 30 s and resets on success.
        func ticksToNextRead() -> Int {let b=capture.pages.probes;var n=0;while capture.pages.probes == b && n < 200 {capture.pages.tick();n += 1};return n}
        unreadable=true;toChrome()
        check(capture.pages.pollPeriod == 6,"page history: after a timeout the poll waits 6 s")
        check(ticksToNextRead() == 12 && capture.pages.pollPeriod == 12,"page history: then 12 s")
        check(ticksToNextRead() == 24 && capture.pages.pollPeriod == 24,"page history: then 24 s")
        check(ticksToNextRead() == 48 && capture.pages.pollPeriod == 30,"page history: then 30 s")
        check(ticksToNextRead() == 60 && capture.pages.pollPeriod == 30,"page history: the poll never waits longer than 30 s")
        unreadable=false
        check(ticksToNextRead() == 60 && capture.pages.pollPeriod == 3,"page history: a successful read resets the poll to 3 s")
        timers=[]
        // Switch off again: no read; rows saved while it was on stay readable.
        count=try pages().count;try setPages(false);before=capture.pages.probes;eventsBefore=events.count
        toChrome();for _ in 0..<20 {capture.pages.tick()}
        check(try capture.pages.probes == before && events.count == eventsBefore && pages().count == count && count >= 3,
              "page history: switch turned off: no read, saved pages stay until deleted or hidden")
        // Browser text is never acquired, even with Chrome pages on.
        try setPages(true)
        var policy=try store.policy();policy.captureText=true;policy.typedConsentVersion=1;try store.updatePolicy(policy)
        coordinator.captureText=true;toChrome()
        key();chromeProof=true;key();key();chromeProof=false
        check(reads == 0,"page history: browser text never acquired even with Chrome pages on")
        coordinator.captureText=false
        // Duplicate-row fix (every app): keys with typing off keep the window
        // signature, so the same Notes window is not written twice.
        front=(4_242,"com.apple.Notes","4242:1:com.apple.Notes","Notes");capture.switchFrontmost(pid:4_242,bundle:"com.apple.Notes") {_,_ in}
        let notes=AccessibilitySnapshot(focusID:"notes-field",app:AppInfo(name:"Notes",bundleIdentifier:"com.apple.Notes"),window:WindowInfo(title:"Groceries",url:nil),
                                        element:ElementInfo(role:"AXTextArea"),secureInput:false,privateBrowsing:false,selectedText:nil,selectedLocation:nil,selectedLength:nil)
        func notesRows() throws -> Int {try store.actions(limit:200).actions.filter {$0.kind == "window.changed" && $0.bundle == "com.apple.Notes"}.count}
        capture.emitWindowChangeIfNeeded(notes)
        check(try notesRows() == 1,"page history: a Notes window change is written once")
        for _ in 0..<3 {key()}
        capture.emitWindowChangeIfNeeded(notes)
        check(try notesRows() == 1 && reads == 0,"page history: keys with typing off in Notes write no duplicate window row")
        coordinator.pause("synthetic boundary");try coordinator.start()
        capture.emitWindowChangeIfNeeded(notes)
        check(try notesRows() == 2,"page history: a pause (privacy boundary) still starts a fresh window row")
        // claude/title-spinner-1003 (audit B1): a title tick that only moves a status glyph ("✳ / ◐ / ◑ Groceries", Claude
        // Code's terminal spinner, about once a second) is the same title in the same window: no row. The fixture alternates
        // two glyphs 2,000 times (about 50 minutes of spinner at the 10/02 rate of 38 rows a minute); a real change is kept.
        func titled(_ title:String) -> AccessibilitySnapshot {
            AccessibilitySnapshot(focusID:"notes-field",app:AppInfo(name:"Notes",bundleIdentifier:"com.apple.Notes"),window:WindowInfo(title:title,url:nil),
                                  element:ElementInfo(role:"AXTextArea"),secureInput:false,privateBrowsing:false,selectedText:nil,selectedLocation:nil,selectedLength:nil)
        }
        let spinStarted=Date()
        for i in 0..<2_000 {capture.emitWindowChangeIfNeeded(titled(i == 0 ? "✳ Groceries" : i % 2 == 0 ? "◐ Groceries" : "◑ Groceries"))}
        let spinSeconds=Date().timeIntervalSince(spinStarted)
        check(try notesRows() == 2,"title spinner: 2,000 glyph ticks on an unchanged title write no row (before: 2,000 rows)")
        capture.emitWindowChangeIfNeeded(titled("◐ Groceries and errands"))
        let spinTitles=try store.actions(limit:200).actions.filter {$0.kind == "window.changed" && $0.bundle == "com.apple.Notes"}.map(\.title)
        // The owner build may withhold a Notes title while typing is on (it can be typed words), so only the count and the
        // absence of a glyph are checked in both lanes.
        check(spinTitles.count == 3 && !spinTitles.contains(where: {$0.contains("◐") || $0.contains("✳")}),
              "title spinner: a real title change is still written, and saved without its glyph (\(spinTitles.count) rows)")
        capture.emitWindowChangeIfNeeded(titled("◑ Groceries and errands"))
        check(try notesRows() == 3,"title spinner: the next tick on the new title writes nothing")
        print(String(format:"PERF title spinner capture: 2,000 ticks -> 0 rows in %.2f s (%.0f µs a tick); before this fix each tick was a saved row",spinSeconds,spinSeconds/2_000*1e6))
        // Live wiring: signature, Automation and Apple Events run off the main
        // thread; the frontmost, process and secure-input checks run on it.
        var threads=[String:[Bool]]()
        func note(_ name:String) {threads[name,default:[]].append(Thread.isMainThread)}
        front=(chrome,"com.google.Chrome","99999:1:com.google.Chrome","Google Chrome")
        let live=ChromePageEnvironment.live
        let wired=ChromePageRecorder(coordinator:coordinator,environment:ChromePageEnvironment(
            frontmost:{note("frontmost");return front},instances:{note("instances");return 1},secureInput:{note("secure");return false},
            verify:{_,_ in note("verify");return true},permission:{_ in note("permission");return noErr},
            transport:{_ in note("transport");return {request in note("event");switch request {
                case .windowIDs:return .ids(["w1"]);case .mode:return .text("normal");case .activeTabID:return .text("t1")
                case .tabURL:return .text("https://example.net/a");case .tabTitle:return .text("Wiring")}}},
            background:live.background,main:live.main,schedule:live.schedule,now:{Date()}))
        wired.trigger(.appSwitch)
        let deadline=Date().addingTimeInterval(5)
        while wired.lastPermission == nil && Date() < deadline {spin(0.02)}
        wired.reset()
        check(wired.lastPermission == noErr && ["verify","permission","transport","event"].allSatisfy {threads[$0]?.isEmpty == false && threads[$0]!.allSatisfy {!$0}},
              "page history: no signature check, Automation check or Apple Event on the main thread")
        check(["frontmost","instances","secure"].allSatisfy {threads[$0]?.isEmpty == false && threads[$0]!.allSatisfy {$0}},"page history: frontmost, process and secure-input checks run on main")
        check(ChromePageEnvironment.queue.label == "daydream.chrome-pages" && ChromePageEnvironment.queue.qos == .utility,"page history: reads run on the serial utility queue")
        check(ChromeEventSender.pageEventTimeout == 0.2 && ChromeEventSender.pageProbeBudget == 0.75,"page history: 0.2 s per Apple Event, 0.75 s per read")

        /// Release sweep: the rows this live path saved, as the timeline, search,
        /// AI apps and cloud summaries see them; then a site on the owner's list.
        func endToEnd() throws {
            let saved=try pages(),ids=Set(saved.map(\.id))
            let day=try DayScope.key(Date(),timezone:"UTC")
            let layers=try store.dayLayers(day:day,timezone:"UTC")
            check(ids.count >= 3 && ids.isSubset(of:Set(layers.activities.flatMap(\.actionIDs))),"page history: end to end: saved pages are in the day's timeline")
            check(try store.searchReport(MemorySearchQuery("Q3")).hits.contains {ids.contains($0["id"] ?? "")},"page history: end to end: search finds a saved page by its title")
            if let q3=saved.first(where:{$0.title == "Q3 plan - Docs"}),let action=try store.action(q3.id) {
                check(AssistantView.line(action) == "Google Chrome page “Q3 plan - Docs” (example.org)" && action.site == "example.org",
                      "page history: end to end: an AI app reads the page as its title and site")
            } else {check(false,"page history: end to end: the first page is readable as an action")}
            // Cloud summaries (fix/day-card, owner 9/28): Chrome-only activities are note targets for both audiences,
            // and a cloud request for the day carries the pages as their cleaned title and site, never the address.
            let local=try store.noteTargets(day:day,timezone:"UTC"),cloud=try store.noteTargets(day:day,timezone:"UTC",audience:.cloud)
            let chromeOnly=layers.activities.filter {$0.actionIDs.allSatisfy(ids.contains)}.map(\.id)
            check(!chromeOnly.isEmpty && chromeOnly.allSatisfy {id in local.contains {$0.id == id} && cloud.contains {$0.id == id}},
                  "page history: end to end: Chrome-only activities are note targets for both audiences")
            let request=try store.prepareNote(kind:"day",day:day,timezone:"UTC",audience:.cloud)
            check(!request.actions.isEmpty && request.actions.filter {ids.contains($0.id)}.allSatisfy {!$0.title.isEmpty && !$0.description.contains("://") && $0.observedDescription == nil},
                  "page history: end to end: a cloud request for the day holds Chrome pages as title and site only")
            try store.cancelNote(request.id)
            // A site on the owner's list: the address is judged and dropped, the title is never asked for,
            // nothing is saved, and its past pages are hidden.
            var policy=try store.policy();policy.blockedDomains=["example.org"];try store.updatePolicy(policy)
            events=[];title="Q7 plan - Docs";timers=[]
            toChrome();advance(1.3)
            // Chrome app time (the app's name only) is not a page: it stays.
            check(try pages().allSatisfy {$0.browserVerification?.provider == BrowserSafety.appTimeProvider} && events.contains(.tabURL("w1","t1")) && !events.contains(.tabTitle("w1","t1")) && timers.isEmpty,
                  "page history: end to end: a site on your list: no title asked, nothing saved, past pages hidden")
            policy=try store.policy();policy.blockedDomains=[];try store.updatePolicy(policy)
            check(try pages().count == ids.count,"page history: end to end: removing the site shows its pages again")
        }
        try endToEnd()

        // Review M3: a row refused for arriving late (the return to the main
        // thread took over 1 s) is not lost; the page is read again and saved.
        title="R1 page";timers=[];hop=1.1;events=[]
        let beforeLate=try pages().count
        toChrome();advance(1.2)          // first read lands late: candidate only
        advance(1.3);advance(1.2)        // confirm read lands late: the write gate refuses it
        check(try pages().count == beforeLate && !timers.isEmpty,"page history: a late row is refused and another read is scheduled")
        hop=0;advance(1.3)
        check(try pages().count == beforeLate+1 && pages().contains {$0.title == "R1 page"},"page history: after a refused late row the page is saved on the next read")
        // Review m1: a key right after a title change never cancels its read.
        timers=[];title="K1 page";var probesBefore=capture.pages.probes
        capture.handleAX(kAXTitleChangedNotification as String);key();key()
        check(capture.pages.probes == probesBefore+1,"page history: a key right after a title change keeps the read")
        title="K2 page"
        capture.handleAX(kAXTitleChangedNotification as String);key()
        check(capture.pages.probes == probesBefore+1 && !timers.isEmpty,"page history: a second title change within 1.5 s waits for the gap")
        advance(1.6)
        check(capture.pages.probes >= probesBefore+2,"page history: the waiting title read still runs after keys")
        advance(1.3)
        check(try pages().contains {$0.title == "K2 page"},"page history: the page after a key-interrupted title change is saved")
        // Review m2: many title changes start a bounded number of reads.
        advance(1.6);timers=[];probesBefore=capture.pages.probes
        let eventsBefore2=events.count
        for i in 0..<12 {title="Tick \(i)";capture.handleAX(kAXTitleChangedNotification as String);advance(0.25)}
        let churn=capture.pages.probes-probesBefore
        check(churn >= 2 && churn <= 8,"page history: 12 title changes in 3 s start at most 8 reads (got \(churn))")
        check(events.count-eventsBefore2 <= 8*9,"page history: title churn sends a bounded number of Apple Events")
        advance(1.6);advance(1.3);timers=[]
        // Review m3: away from the Mac, the poll stops; a title change still reads.
        idle=120;probesBefore=capture.pages.probes
        for _ in 0..<24 {capture.pages.tick()}
        check(capture.pages.probes == probesBefore,"page history: no poll after a minute without input")
        advance(1.6);title="Idle title";capture.handleAX(kAXTitleChangedNotification as String)
        check(capture.pages.probes == probesBefore+1,"page history: a title change still reads while idle")
        idle=0;advance(1.6);timers=[];probesBefore=capture.pages.probes
        for _ in 0..<6 {capture.pages.tick()}
        check(capture.pages.probes == probesBefore+1,"page history: the poll resumes once input comes back")
        timers=[]
    }
}

#if DAYDREAM_OWNER_TYPING
// Owner build only (typing-all SPEC-LATER 4.2): website typing through the
// actual EventCapture, WebTypingRoute, Coordinator and store, with the real
// Chrome join against a fake Chrome (Apple Event replies and an Accessibility
// tree in memory). No Apple Event, Accessibility call, signature or
// Automation check, event tap or Chrome launch happens here.
final class WebFakeNode {
    let name:String
    var role:String,subrole:String
    var parent:WebFakeNode? {didSet {oldValue?.kids.removeAll {$0 === self};parent?.kids.append(self)}}
    var kids:[WebFakeNode]=[]
    var frame:ChromeBounds?
    var title:String?,url:String?
    var labels:BrowserTypingFieldLabels?=BrowserTypingFieldLabels(texts:[],identifiers:[])
    /// fix/chrome-capture: AXEnabled and AXDescription (a control's names are its title and description).
    var enabled:Bool?=true,desc:String?
    init(_ name:String,role:String,subrole:String="",parent:WebFakeNode?=nil) {self.name=name;self.role=role;self.subrole=subrole;self.parent=parent;parent?.kids.append(self)}
}
final class WebFakeChrome {
    struct Window {var id:String;var mode:String?;var bounds:ChromeBounds;var name:String;var tab:String;var url:String}
    static let pid:Int32=99_998 // above macOS's highest pid: never a real process
    let facts=ChromeTargetFacts(pid:pid,bundleID:"com.google.Chrome",launchIdentity:"99998:1790000000:com.google.Chrome",signatureValid:true,
                                bundleVersion:"153.0.8010.54",frameworkVersions:["153.0.8010.54"],instances:1)
    var windows:[Window]
    var axWindows:[WebFakeNode]
    let window:WebFakeNode,web:WebFakeNode,field:WebFakeNode
    /// Saturday test 5: what a click can focus instead of the field (nil: the field).
    let button:WebFakeNode,otherField:WebFakeNode,toolbar:WebFakeNode
    var focus:WebFakeNode?
    /// fix/chrome-capture: what Accessibility's hit test finds under the pointer.
    var hit:WebFakeNode?
    /// fix/chrome-capture (QF-2): the frontmost and system-focused app when not Chrome (after Command-Tab).
    var frontPID:Int32?
    var appleEvents=0,ax=0
    static let bounds=ChromeBounds(left:0,top:25,right:1440,bottom:900)
    init(url:String) {
        window=WebFakeNode("window-101",role:"AXWindow",subrole:"AXStandardWindow");window.frame=ChromeBounds(x:0,y:25,width:1440,height:875)
        // QF-10: Chrome's AXTitle is the window's Apple Events name, " - Google Chrome" and a profile.
        window.title="Plans - Google Chrome - Work"
        let scroll=WebFakeNode("scroll",role:"AXScrollArea",parent:window)
        web=WebFakeNode("web",role:"AXWebArea",parent:scroll);web.url=url
        field=WebFakeNode("field",role:"AXTextArea",parent:WebFakeNode("group",role:"AXGroup",parent:web))
        // Codex 06:10: an unlabelled box is refused; the notes box has its label.
        field.labels=BrowserTypingFieldLabels(texts:["Notes"],identifiers:[])
        button=WebFakeNode("send",role:"AXButton",parent:WebFakeNode("actions",role:"AXGroup",parent:web))
        otherField=WebFakeNode("subject",role:"AXTextField",parent:WebFakeNode("header",role:"AXGroup",parent:web))
        // QF-4: a one-line box has a label (an unlabelled one is refused).
        otherField.labels=BrowserTypingFieldLabels(texts:["Subject"],identifiers:[])
        toolbar=WebFakeNode("omnibox",role:"AXTextField",parent:WebFakeNode("toolbar",role:"AXToolbar",parent:window))
        windows=[Window(id:"101",mode:"normal",bounds:Self.bounds,name:"Plans",tab:"7",url:url)];axWindows=[window]
    }
    func page(_ url:String) {windows[windows.count-1].url=url;web.url=url}
    func addWindow(_ id:String,mode:String?) {
        let bounds=ChromeBounds(left:200,top:100,right:1000,bottom:700)
        windows.insert(Window(id:id,mode:mode,bounds:bounds,name:"Private",tab:"9"+id,url:"https://private.example.net/secret"),at:0)
        let node=WebFakeNode("window-"+id,role:"AXWindow",subrole:"AXStandardWindow");node.frame=bounds;node.title="Private";axWindows.append(node)
    }
    func removeWindow(_ id:String) {windows.removeAll {$0.id == id};axWindows.removeAll {$0.name == "window-"+id}}
    func environment(now:@escaping ()->UInt64,enabled:@escaping ()->Bool) -> ChromeJoinEnvironment {
        ChromeJoinEnvironment(now:now,enabled:enabled,target:{self.facts},automationPermitted:{$0 == Self.pid},launchIdentity:{$0 == Self.pid ? self.facts.launchIdentity : nil})
    }
    func ae(_ r:ChromeJoinRequest) -> ChromeJoinReply? {
        appleEvents+=1
        let w=r.windowID.flatMap {id in windows.first {$0.id == id}}
        switch r {
        case .windowIDs:return .ids(windows.map(\.id))
        case .modes:return .texts(windows.compactMap(\.mode))
        case .allBounds:return .boundsList(windows.map(\.bounds))
        case .mode:return w?.mode.map {.text($0)}
        case .bounds:return w.map {.bounds($0.bounds)}
        case .name:return w.map {.text($0.name)}
        case .activeTabID:return w.map {.text($0.tab)}
        case .tabURL(_,let t):return w.flatMap {$0.tab == t ? .text($0.url) : nil}
        }
    }
    var access:ChromeAXAccess<WebFakeNode> {
        ChromeAXAccess<WebFakeNode>(frontmostPID:{self.frontPID ?? Self.pid},systemFocusedPID:{self.frontPID ?? Self.pid},secureInput:{false},
            focusedWindow:{self.ax+=1;return self.window},windows:{self.axWindows},focusedElement:{self.focus ?? self.field},owner:{_ in Self.pid},
            role:{$0.role},subrole:{$0.subrole},parent:{$0.parent},frame:{$0.frame},minimized:{_ in false},title:{$0.title},url:{$0.url},
            fieldLabels:{$0.labels},equal:{$0 === $1},elementAt:{_,_ in self.hit},enabled:{$0.enabled},controlNames:{[$0.title ?? "",$0.desc ?? ""]},children:{$0.kids})
    }
}
extension ProductionCaptureChecks {
    /// Installed before the first key of the run: every join is refused and
    /// nothing is scheduled, so no check can reach the live witness.
    static func installFakeWebRoute() {
        WebTypingRoute.shared=WebTypingRoute(environment:WebTypingRoute.Environment(now:{DispatchTime.now().uptimeNanoseconds},join:{_,_,_ in .denied(.disabled)},
            schedule:{_,_ in},secureInput:{false},pressAndHold:{true},secondsSinceMouseDown:{nil},directKeyboardInput:{true}))
    }
    /// Actual native EventCapture shortcut dispatch with fictional proofs.
    /// currentPID is never installed, so native target routing performs no AX read.
    static func nativeRecipientShortcuts(root:URL) throws {
        let store=try MemoryStore(home:root,writable:true,automaticallySyncSearch:false)
        try store.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()));try store.setUpTypedVault();try store.acceptSafeTyping()
        let coordinator=try Coordinator(store:store,permissions:{true}) {}
        var mono:UInt64=20_000_000_000,field="body",window="a",reads=0,known=true,secure=false
        var timers:[(at:UInt64,work:()->Void)]=[]
        func schedule(_ delay:TimeInterval,_ work:@escaping ()->Void) {timers.append((mono+UInt64(delay*1_000_000_000),work))}
        func advance(_ seconds:Double) {
            let target=mono+UInt64(seconds*1_000_000_000)
            while let i=timers.indices.filter({timers[$0].at<=target}).min(by:{timers[$0].at<timers[$1].at}) {
                let timer=timers.remove(at:i);mono=max(mono,timer.at);timer.work()
            }
            mono=target
        }
        let env=EventCapture.TypingEnvironment(now:{mono},proof:{generation,version in
            guard known else {return nil}
            var p=FocusProof();p.generation=generation;p.policyVersion=version;p.checkedAt=mono
            p.bundle=SendRules.mailApp;p.windowID=window;p.focusID=field;p.role="AXTextArea";p.sendField=field;p.fieldLabel=field
            p.surface = .native;p.secureInput=secure ? .yes:.no;p.privateMode = .no
            p.verified=true;p.fieldStateVerified=true;p.frameAccessible=true;p.navigationStable=true;return p
        },schedule:schedule,secureInput:{secure},departure:{DepartureState(secureInput:secure ? .yes:.no,bundle:SendRules.mailApp,focusSecure:secure ? .yes:.no)},pressAndHold:{true})
        let capture=EventCapture(coordinator:coordinator,typingEnvironment:env)
        try coordinator.start();var policy=try store.policy();policy.captureText=true;policy.typedConsentVersion=1;try store.updatePolicy(policy);coordinator.captureText=true
        func key(_ text:String="",code:Int64=0,command:Bool=false,shift:Bool=false) {advance(0.08);capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:code,command:command,shift:shift)) {reads+=1;return text}}
        func type(_ text:String) {for c in text {key(String(c))}}
        func selectTo(_ w:String="a") {window=w;field="to";advance(0.6)}
        func leaveTo() {key(code:48);field="body";advance(0.6)}
        func rows() throws -> [Evidence] {try store.actions(limit:500).actions.compactMap {a in
            guard var e=try store.read(a.id)?.evidence,e.kind=="keyboard.text_input" else {return nil}
            e.captureProvenance?.unit=try store.typedUnit(e.id,disclosure:.owner);return e
        }}
        func body(_ text:String) throws -> Evidence? {type(text);capture.flushNativeText(reason:.idle);return try rows().first {try store.hydrateTypedText($0.id,disclosure:.owner)==text}}
        for (code,shift,label) in [(Int64(9),false,"paste"),(Int64(6),false,"undo"),(Int64(6),true,"redo")] {
            selectTo();type("Avery");leaveTo()
            let initial=try body("The known native recipient precedes " + label + ".")
            check(initial?.captureProvenance?.unit?.to == "Avery","actual native To setup before " + label)
            selectTo();let before=reads,count=try rows().count
            key(code:code,command:true,shift:shift);leaveTo()
            check(try reads==before && rows().count==count,"actual native " + label + " reads no characters and creates no typed row")
            let changed=try body("The changed native draft follows " + label + ".")
            check(changed != nil && changed?.captureProvenance?.unit?.to == nil,"actual native " + label + " invalidates an empty To without a row")
        }
        selectTo();type("Morgan");key(code:48);key(code:9,command:true);field="body";advance(0.6)
        let parked=try body("The native parked recipient cannot return after paste.")
        check(try parked != nil && parked?.captureProvenance?.unit?.to == nil && rows().contains {try store.hydrateTypedText($0.id,disclosure:.owner)=="Morgan"},"actual native saved old parked To cannot resurrect after paste")
        selectTo("a");type("Avery");leaveTo();_=try body("The first native draft has a recipient.")
        selectTo("b");type("Morgan");leaveTo();_=try body("The second native draft has a recipient.")
        selectTo("b");key(code:6,command:true,shift:true);leaveTo()
        window="a";field="body";advance(0.6);let isolated=try body("The first window survives another window redo.")
        check(isolated?.captureProvenance?.unit?.to == "Avery","actual native shortcut invalidation respects window scope")
        for (code,text,label,mutating) in [(Int64(0),"x","insert",true),(Int64(51),"","backspace",true),(Int64(123),"","caret",false)] {
            selectTo();type("Avery");leaveTo()
            let setup=try body("The native missing proof setup precedes " + label + ".")
            check(setup?.captureProvenance?.unit?.to == "Avery","actual native known recipient before unproved " + label)
            selectTo();known=false;let noProofReads=reads;key(text,code:code);known=true;leaveTo()
            check(reads==noProofReads,"actual native unproved " + label + " reads no characters")
            let changed=try body("The native missing proof result follows " + label + ".")
            check(changed != nil && changed?.captureProvenance?.unit?.to == (mutating ? nil:"Avery"),"actual native unproved " + label + (mutating ? " revokes recipient authority":" preserves recipient for caret movement"))
        }
        selectTo();type("Avery");leaveTo();_=try body("The known native recipient precedes an accent edit.")
        key("e",code:14)
        for _ in 0..<3 {advance(0.08);capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:14,autorepeat:true)) {reads+=1;return "e"}}
        field="to";known=false;let accentReads=reads;key(code:19)
        check(reads==accentReads,"actual native unproved accent selection never reads characters")
        known=true;capture.flushNativeText(reason:.cursor);leaveTo()
        let afterAccent=try body("The unknown accent selection changes recipient authority.")
        check(reads>accentReads && afterAccent != nil && afterAccent?.captureProvenance?.unit?.to == nil,"actual native unproved accent selection revokes recipient authority")
        let morganBefore=try rows().filter {try store.hydrateTypedText($0.id,disclosure:.owner)=="Morgan"}.count
        selectTo();type("Morgan");key(code:48);known=false;let noProofParkedReads=reads;key("x")
        check(reads==noProofParkedReads,"actual native unproved parked edit never reads characters")
        known=true;field="body";advance(0.6)
        let noProofParked=try body("The dropped edit prevents a parked recipient resurrection.")
        check(try noProofParked != nil && noProofParked?.captureProvenance?.unit?.to == nil && rows().filter {try store.hydrateTypedText($0.id,disclosure:.owner)=="Morgan"}.count==morganBefore+1,"actual native saved parked To cannot resurrect after an unproved insert")
        check(reads>noProofParkedReads,"actual native body after unproved parked edit remains capturable")
        selectTo("a");known=false;let before=reads;key(code:9,command:true);known=true;leaveTo()
        let unknown=try body("An unproved paste cannot retain recipient authority.")
        check(unknown != nil && unknown?.captureProvenance?.unit?.to == nil && reads>before,"actual native missing proof paste revokes authority without reading clipboard")
        selectTo();secure=true;let deniedReads=reads;key(code:9,command:true);secure=false;leaveTo()
        check(reads==deniedReads,"actual native secure paste never reads characters")
        check(try rows().allSatisfy {$0.sendVerification==nil},"native shortcut fixture invents no confirmed delivery")
        coordinator.stop()
    }
    /// Real synchronous WebTypingRoute and sealed store, with the existing
    /// fake Chrome witness. No GUI, AX/AE, live contacts or send operation.
    static func websiteRecipientAuthority(root:URL) throws {
        let store=try MemoryStore(home:root,writable:true,automaticallySyncSearch:false)
        try store.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()));try store.setUpTypedVault();try store.acceptSafeTyping()
        let coordinator=try Coordinator(store:store,permissions:{true}) {}
        var mono:UInt64=80_000_000_000,reads=0
        var timers:[(at:UInt64,work:()->Void)]=[]
        func schedule(_ delay:TimeInterval,_ work:@escaping ()->Void) {timers.append((mono+UInt64(delay*1_000_000_000),work))}
        func advance(_ seconds:Double) {
            let target=mono+UInt64(seconds*1_000_000_000)
            while let i=timers.indices.filter({timers[$0].at<=target}).min(by:{timers[$0].at<timers[$1].at}) {
                let timer=timers.remove(at:i);mono=max(mono,timer.at);timer.work()
            }
            mono=target
        }
        let chrome=WebFakeChrome(url:"https://mail.google.com/mail/u/0/#inbox"),join=BrowserTypingJoin<WebFakeNode>()
        var env=WebTypingRoute.Environment(now:{mono},wall:{Date()},join:{pid,sites,enabled in
            guard pid == WebFakeChrome.pid else {return .denied(.untrustedTarget)}
            let result=join.join(environment:chrome.environment(now:{mono},enabled:enabled),appleEvents:chrome.ae,accessibility:chrome.access,
                             blockList:sites.blockList,alwaysBlocked:sites.alwaysBlocked,sites:sites.permits(url:),field:sites.permits(url:field:))
            return result
        },light:{pid,sites,enabled in
            guard pid == WebFakeChrome.pid else {return nil}
            return join.light(environment:chrome.environment(now:{mono},enabled:enabled),appleEvents:chrome.ae,accessibility:chrome.access,
                              blockList:sites.blockList,alwaysBlocked:sites.alwaysBlocked,sites:sites.permits(url:),field:sites.permits(url:field:))
        },schedule:schedule,secureInput:{false},pressAndHold:{true},secondsSinceMouseDown:{nil},directKeyboardInput:{true})
        env.design = .synchronous
        let route=WebTypingRoute(environment:env)
        try coordinator.start()
        var policy=try store.policy();policy.captureText=true;policy.typedConsentVersion=1;policy.browserPages=true;policy.browserPagesConsentVersion=PrivacySettings.browserPagesConsentCurrent;try store.updatePolicy(policy);coordinator.captureText=true
        func key(_ text:String="",code:Int64=0,command:Bool=false,shift:Bool=false) {advance(0.08);_ = route.handle(eventAt:mono,stroke:KeyStroke(keyCode:code,command:command,shift:shift),bundle:"com.google.Chrome",pid:WebFakeChrome.pid,coordinator:coordinator,keyFocus:.some(WebFakeChrome.pid),acquire:{reads+=1;return text})}
        func type(_ text:String) {for c in text {key(String(c))}}
        func selectTo(_ tab:String="7") {chrome.windows[0].tab=tab;chrome.focus=chrome.otherField;chrome.otherField.labels=BrowserTypingFieldLabels(texts:["To"],identifiers:[]);advance(0.6)}
        func leaveTo() {key(code:48);chrome.focus=chrome.field;chrome.field.labels=BrowserTypingFieldLabels(texts:["Message body"],identifiers:[]);advance(0.6)}
        func rows() throws -> [Evidence] {
            try store.actions(limit:500).actions.compactMap { action in
                guard var e=try store.read(action.id)?.evidence,e.kind == "keyboard.text_input" else {return nil}
                e.captureProvenance?.unit=try store.typedUnit(e.id,disclosure:.owner)
                return e
            }
        }
        func body(_ text:String) throws -> Evidence? {type(text);key(code:36);advance(0.6);return try rows().first {try store.hydrateTypedText($0.id,disclosure:.owner)==text}}
        selectTo();type("Avery");leaveTo()
        let initial=try body("Please review the garden sketch.")
        check(initial?.captureProvenance?.unit?.to == "Avery","actual web route: valid To authority reaches body")
        for (code,shift,label) in [(Int64(9),false,"paste"),(Int64(6),false,"undo"),(Int64(6),true,"redo")] {
            selectTo();type("Avery");leaveTo();_=try body("The known recipient precedes " + label + ".")
            selectTo();let before=reads,count=try rows().count
            key(code:code,command:true,shift:shift);leaveTo()
            check(try reads==before && rows().count==count,"actual web " + label + " reads no characters and creates no typed row")
            let changed=try body("The changed draft follows " + label + ".")
            check(changed != nil && changed?.captureProvenance?.unit?.to == nil,"actual web " + label + " invalidates an empty To without a text row")
        }
        selectTo();type("Morgan");key(code:48);key(code:9,command:true)
        chrome.focus=chrome.field;advance(0.6)
        let afterParked=try body("The parked recipient cannot return after paste.")
        check(try afterParked != nil && afterParked?.captureProvenance?.unit?.to == nil && rows().contains {try store.hydrateTypedText($0.id,disclosure:.owner)=="Morgan"},"actual web saved old parked To cannot resurrect after paste")
        if ProcessInfo.processInfo.environment["RECIPIENT_SHORTCUT_ONLY"] == "1" || ProcessInfo.processInfo.environment["RECIPIENT_WEB_SHORTCUT_ONLY"] == "1" {coordinator.stop();return}
        selectTo("7");type("Avery");leaveTo();_=try body("Restore a known first draft before rejection.")
        selectTo();type("Riley2@ex");leaveTo()
        let invalid=try body("The north bed needs seedlings.")
        check(invalid != nil && invalid?.captureProvenance?.unit?.to == nil,"actual web route: rejected To edit clears previous recipient")
        check(try !rows().contains {try store.hydrateTypedText($0.id,disclosure:.owner)=="Riley2@ex"},"actual web route: incomplete opaque To has no saved text row")
        selectTo();type("Morgan");leaveTo();_=try body("Please trace the missing parcel.")
        selectTo();key(code:51);leaveTo()
        let deleted=try body("The courier needs another detail.")
        check(deleted != nil && deleted?.captureProvenance?.unit?.to == nil,"actual web route: empty-run backspace clears previous recipient")
        selectTo("9");type("Morgan");leaveTo();_=try body("The parcel belongs to the second draft.")
        selectTo("7");type("Riley2@ex");leaveTo();_=try body("The first draft has no proven recipient.")
        chrome.windows[0].tab="9";chrome.focus=chrome.field;advance(0.6)
        let isolated=try body("The second draft keeps its known recipient.")
        check(isolated?.captureProvenance?.unit?.to == "Morgan","actual web route: invalidating another tab cannot clear this tab's recipient")
        let contacts=try body("Reach me at morgan@example.com or 415-555-0100.")
        print("OBSERVATION route contact prose exact retention: \(contacts != nil); unchanged baseline limitation")
        route.drop(.focus);advance(0.6)
        let email=try body("morgan@example.com")
        check(email != nil,"actual web route: existing ordinary email capture remains permitted")
        check(try rows().allSatisfy {$0.sendVerification == nil},"actual web route: Return fixture never invents delivery receipts")
        coordinator.stop()
    }

    static func websiteTyping(root:URL) throws {
        let store=try MemoryStore(home:root.appendingPathComponent("website-typing"),writable:true,automaticallySyncSearch:false)
        try store.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()));try store.setUpTypedVault();try store.acceptSafeTyping()
        let coordinator=try Coordinator(store:store,permissions:{true}) {}
        var mono:UInt64=80_000_000_000,reads=0,joins=0,proofReads=0,lights=0,holdChecks=0
        // Review G12, round 1: click joins taken, and how many of the next ones fail (an Apple Event that times out).
        var pageJoins=0,failPageJoins=0
        // The keyboard input source (typingfix F3): true is a direct layout (US, ABC or British).
        var direct=true
        // Secure input (a password field anywhere on the Mac), as the route reads it (gold/r2-typing).
        var secureOn=false
        var timers:[(at:UInt64,work:()->Void)]=[]
        func schedule(_ delay:TimeInterval,_ work:@escaping ()->Void) {timers.append((mono+UInt64(delay*1_000_000_000),work))}
        func advance(_ seconds:Double) {
            let target=mono+UInt64(seconds*1_000_000_000)
            while let i=timers.indices.filter({timers[$0].at<=target}).min(by:{timers[$0].at<timers[$1].at}) {
                let timer=timers.remove(at:i);mono=max(mono,timer.at);timer.work()
            }
            mono=target
        }
        let chrome=WebFakeChrome(url:"https://notes.example.org/pad/7?view=1#top")
        let join=BrowserTypingJoin<WebFakeNode>()
        WebTypingRoute.shared=WebTypingRoute(environment:WebTypingRoute.Environment(now:{mono},wall:{Date()},join:{pid,sites,enabled in
            joins+=1
            guard pid == WebFakeChrome.pid else {return .denied(.untrustedTarget)}
            return join.join(environment:chrome.environment(now:{mono},enabled:enabled),appleEvents:chrome.ae,accessibility:chrome.access,
                             blockList:sites.blockList,alwaysBlocked:sites.alwaysBlocked,sites:sites.permits(url:),field:sites.permits(url:field:))
        },pointerJoin:{pid,sites,enabled in
            joins+=1;pageJoins+=1
            guard pid == WebFakeChrome.pid else {return .denied(.untrustedTarget)}
            let failing=failPageJoins>0;if failing {failPageJoins-=1}
            return join.join(environment:chrome.environment(now:{mono},enabled:enabled),
                             appleEvents:{r in if failing {switch r {case .bounds,.allBounds:return nil;default:break}};return chrome.ae(r)},accessibility:chrome.access,
                             blockList:sites.blockList,alwaysBlocked:sites.alwaysBlocked,sites:sites.permits(url:),anyFocus:true)
        },light:{pid,sites,enabled in
            // Review G51: keys of an open burst take the light per-key check first.
            lights+=1
            guard pid == WebFakeChrome.pid else {return nil}
            return join.light(environment:chrome.environment(now:{mono},enabled:enabled),appleEvents:chrome.ae,accessibility:chrome.access,
                              blockList:sites.blockList,alwaysBlocked:sites.alwaysBlocked,sites:sites.permits(url:),field:sites.permits(url:field:))
        },fieldHeld:{pid in
            // Codex 07:10 (field hold): the witness's focus-only check of a refused box.
            holdChecks+=1
            return pid == WebFakeChrome.pid ? join.holdsRefusedBox(accessibility:chrome.access) : false
        },schedule:schedule,secureInput:{secureOn},pressAndHold:{true},secondsSinceMouseDown:{nil},directKeyboardInput:{direct}))
        // Page history's environment: an unsigned Chrome, so it sends nothing.
        let pageEnvironment=ChromePageEnvironment(frontmost:{(WebFakeChrome.pid,"com.google.Chrome","99998:1:com.google.Chrome","Google Chrome")},instances:{1},
            secureInput:{false},verify:{_,_ in false},permission:{_ in OSStatus(-1743)},transport:{_ in {_ in nil}},
            background:{$0()},main:{$0()},schedule:{_,_ in},now:{Date()})
        // Google Chrome gets no native typing proof (production reads none for browsers).
        let typing=EventCapture.TypingEnvironment(now:{mono},proof:{_,_ in proofReads+=1;return nil},schedule:schedule,secureInput:{false},pressAndHold:{true})
        let capture=EventCapture(coordinator:coordinator,typingEnvironment:typing,pageEnvironment:pageEnvironment)
        func key(_ text:String) {capture.handleNativeKey(eventAt:mono,keyCode:0,shortcut:false) {reads+=1;return text}}
        func type(_ text:String) {for c in text {advance(0.08);key(String(c))}}
        func submit() {advance(0.08);capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:36)) {reads+=1;return "\r"};advance(0.5)}
        func rows() throws -> [Evidence] {
            try store.actions(limit:500).actions.compactMap {try store.read($0.id)?.evidence}.filter {$0.bundle == "com.google.Chrome" && $0.kind == "keyboard.text_input"}
        }
        func words() throws -> [String] {try rows().compactMap {try store.hydrateTypedText($0.id,disclosure:.owner)}}
        func raw() throws -> String {try store.rows("SELECT body FROM records").compactMap {$0.first}.joined(separator:"\n")}
        func setPages(_ on:Bool) throws {var p=try store.policy();p.browserPages=on;p.browserPagesConsentVersion=on ? PrivacySettings.browserPagesConsentCurrent:nil;try store.updatePolicy(p)}
        /// No saved website word appears in any raw record body.
        func sealed() throws -> Bool {let r=try raw(),w=try words();return !w.isEmpty && !w.contains {r.contains($0)}}
        func typingSwitch(_ on:Bool) throws {var p=try store.policy();p.captureText=on;p.typedConsentVersion=on ? 1:nil;try store.updatePolicy(p);coordinator.captureText=on}
        func choices(_ change:(inout TypedCategoryChoices)->Void) throws {var t=try store.typedTextPolicy();change(&t.categories);try store.updateTypedTextPolicy(t,confirmed:true)}
        func unchanged(_ name:String,_ body:() throws -> Void) throws {
            let before=(reads,try rows().count);try body()
            check(try reads == before.0 && rows().count == before.1,name)
        }

        check(OwnerTyping.enabled && TypingRelease.open && !TypingRelease.expandedApproved,"website typing: the owner build opens the gate; the legal gate itself stays closed")
        try coordinator.start()
        check(coordinator.session.reason == WebTypingText.recording && !coordinator.session.reason.contains("what you type in browsers is never saved"),
              "website typing: the owner build's recording line says what it records")
        try setPages(true)
        capture.switchFrontmost(pid:WebFakeChrome.pid,bundle:"com.google.Chrome") {_,_ in}
        func dot() throws -> TypingIndicatorState {try store.typingIndicator(frontmostBundle:"com.google.Chrome")}
        // Typing off: no join, nothing read.
        try unchanged("website typing: typing off: no join and nothing read") {type("typing is off");submit()}
        check(joins == 0,"website typing: typing off starts no join")
        try typingSwitch(true)
        // "Web pages in Chrome" off: website typing is off too (no join, no read).
        try setPages(false)
        try unchanged("website typing: Web pages in Chrome off: nothing read") {type("pages are off");submit()}
        check(joins == 0,"website typing: Web pages in Chrome off starts no join")
        try setPages(true)
        // An unknown site with the default choices: saved, sealed, origin only.
        advance(1);type("ship the pricing page friday");submit()
        var saved=try rows()
        check(try saved.count == 1 && words() == ["ship the pricing page friday"] && reads == 28,"website typing: an unknown site with the defaults: Return saves the words, each key read after its join")
        check(lights >= 20 && joins <= 6,"website typing (G51): a steady burst takes a few full joins and the light check for the other keys (\(joins) joins, \(lights) light checks)")
        if let row=saved.first {
            // fix/typing-e2e L5: the page's title as page history saves it ("Plans"), so the typing joins the page's moment.
            check(row.url == "https://notes.example.org" && row.title == "notes.example.org" && row.app == "Google Chrome" && row.text.isEmpty && row.typed != nil,
                  "website typing: an under-60 ms title is site-only (no path or query), and its words are sealed")
            check(row.browserVerification?.provider == WebTypedRow.provider && row.browserVerification?.mode == "normal" && BrowserSafety.valid(row) && WebTypedRow.valid(row),
                  "website typing: the row carries the join's normal-window proof")
        }
        if ProcessInfo.processInfo.environment["Q4_TITLE_ONLY"] == "1" {capture.stop(reason:"Q-4 fixture completed");return}
        // fix/typing-e2e L5: the page's title is kept as page history keeps it (checked on the row above); the typed
        // words and the page's path never reach a raw record.
        check(try !raw().contains("pricing page") && !raw().contains("/pad/7"),"website typing: no typed word or path in any raw record")
        check(try store.typingIndicator(frontmostBundle:"com.google.Chrome") == .recording(app:"Google Chrome"),"website typing: the menu dot shows in Google Chrome")
        // typing-all final review: the dot shows only after a join that allowed typing in this Chrome.
        var indicatorPosts=0
        let postWatch=NotificationCenter.default.addObserver(forName:.typingIndicatorInputsChanged,object:nil,queue:nil) {_ in indicatorPosts+=1}
        capture.switchFrontmost(pid:4_243,bundle:"com.apple.Notes") {_,_ in}
        capture.switchFrontmost(pid:WebFakeChrome.pid,bundle:"com.google.Chrome") {_,_ in}
        check(try dot() == .notHere,"website typing: back in Chrome, no dot until a join allows typing")
        advance(1);type("again");submit()
        check(try dot() == .recording(app:"Google Chrome"),"website typing: a key in Chrome with an allowed join brings the dot back")
        TypingFocus.mayHaveMoved()   // what EventCapture reports for a click
        check(try dot() == .notHere,"website typing: after a click in Chrome, no dot until the next join")
        if Thread.isMainThread {check(indicatorPosts >= 3,"website typing: the menu is told each time the dot's Chrome judgement changes (\(indicatorPosts))")}
        NotificationCenter.default.removeObserver(postWatch)
        check(try store.rows("SELECT body FROM records WHERE json_extract(body,'$.browserVerification.provider')='\(BrowserSafety.pageProvider)'").allSatisfy {!($0.first ?? "").contains("pricing")},
              "website typing: page history rows never carry typed words")
        // A pause in typing saves with a fresh join.
        advance(1);type("second thought");advance(5)
        check(try words().contains("second thought"),"website typing: a pause saves the words (idle save with a fresh join)")
        // Saturday test 5 (b): a click mid-typing never loses the unfinished words. The mouse-down
        // (what EventCapture reports through TypingPointer) saves them first, with a click join of
        // the same page and window list, wherever the click put focus in the page.
        advance(1);type("send this now")
        check(WebTypingRoute.shared.burst.session.hasLive,"website typing (click): the unfinished words are held before the click")
        chrome.focus=chrome.button
        TypingPointer.down(at:mono)
        check(try words().contains("send this now") && !WebTypingRoute.shared.burst.session.hasLive,
              "website typing (click): a click on Send before the idle save saves the unfinished words")
        advance(5)
        check(try words().filter {$0 == "send this now"}.count == 1,"website typing (click): saved once (no second row after the click)")
        chrome.focus=nil
        advance(1);type("first field")
        chrome.focus=chrome.otherField
        TypingPointer.down(at:mono)
        check(try words().contains("first field"),"website typing (click): a click into another field saves the unfinished words")
        advance(1);type("second field");submit()
        check(try words().contains("second field") && !words().contains {$0.contains("first fieldsecond")},"website typing (click): the next field's words are their own row")
        chrome.focus=nil
        advance(1);type("caret moved here")
        TypingPointer.down(at:mono)
        check(try words().contains("caret moved here"),"website typing (click): a click inside the same field saves the words typed so far")
        // Nothing is saved by a click the join can't prove: an Incognito window that opened while both
        // views lagged (the words are dropped, as at an idle save), another page, or focus outside the page.
        advance(1);type("lagging private words")
        chrome.addWindow("707",mode:"incognito")
        TypingPointer.down(at:mono);advance(5)
        check(try !words().contains {$0.contains("lagging private words")} && !WebTypingRoute.shared.burst.session.hasLive,
              "website typing (click): an Incognito window open at the click drops the unsaved words")
        chrome.removeWindow("707")
        advance(1);type("other page words")
        chrome.page("https://notes.example.org/pad/12")
        TypingPointer.down(at:mono)
        check(try !words().contains {$0.contains("other page words")},"website typing (click): a click join of another page saves nothing")
        advance(5);chrome.page("https://notes.example.org/pad/7?view=1#top")
        advance(1);type("toolbar words")
        chrome.focus=chrome.toolbar
        TypingPointer.down(at:mono)
        check(try !words().contains {$0.contains("toolbar words")} && WebTypingRoute.shared.burst.session.hasLive,
              "website typing (click): focus outside the page proves nothing: the click saves nothing")
        chrome.focus=nil;advance(5)
        // Review G12: Tab to the next field, Tab to a button and Command-Return no longer lose the
        // unfinished words; a password field, an Incognito window or the address bar still drop them.
        func press(_ stroke:KeyStroke) {advance(0.08);capture.handleNativeKey(eventAt:mono,stroke:stroke) {reads+=1;return ""}}
        advance(1);type("first name")
        chrome.focus=chrome.otherField;press(KeyStroke(keyCode:48));advance(5)
        check(try words().contains("first name"),"website typing (G12): Tab to the next field saves the unfinished words after the settle")
        chrome.focus=nil;advance(1);type("see you then")
        chrome.focus=chrome.button;press(KeyStroke(keyCode:48));advance(5)
        check(try words().contains("see you then"),"website typing (G12): Tab to a button saves the unfinished words after the settle")
        chrome.focus=nil;advance(1);type("command return")
        chrome.focus=chrome.button;press(KeyStroke(keyCode:36,command:true))
        check(try words().contains("command return") && !WebTypingRoute.shared.burst.session.hasLive,"website typing (G12): Command-Return saves the unfinished words at once")
        advance(5)
        check(try words().filter {$0 == "command return"}.count == 1,"website typing (G12): Command-Return: saved once")
        let password=WebFakeNode("password",role:"AXTextField",subrole:"AXSecureTextField",parent:chrome.otherField.parent)
        chrome.focus=nil;advance(1);type("user name")
        chrome.focus=password;press(KeyStroke(keyCode:48));advance(5)
        check(try !words().contains {$0.contains("user name")},"website typing (G12): Tab into a password field drops the words typed before it")
        // Review R9-1: the password field leaves the page again. It sat beside the page's other field groups, and with
        // the page root scanned it would (correctly) refuse the compose field for the rest of this run.
        password.parent=nil
        chrome.focus=nil;advance(1);type("tab private")
        chrome.focus=chrome.otherField;press(KeyStroke(keyCode:48));chrome.addWindow("808",mode:"incognito");advance(5)
        check(try !words().contains {$0.contains("tab private")},"website typing (G12): an Incognito window open at the settle drops the words")
        chrome.removeWindow("808")
        chrome.focus=nil;advance(1);type("to the omnibox")
        chrome.focus=chrome.toolbar;press(KeyStroke(keyCode:37,command:true));advance(5)
        check(try !words().contains {$0.contains("to the omnibox")},"website typing (G12): focus in the address bar proves nothing: nothing is saved")
        chrome.focus=nil;advance(5)
        // Review G12, round 1: the settle takes the full join first. A shortcut that keeps focus in the field
        // (Command-S) parks the words; a click join that would fail once is never taken while the full join
        // proves the field, so nothing can make that join forget the page and the words are saved, as on base.
        advance(1);type("draft for the launch")
        var pageJoinsBefore=pageJoins;failPageJoins=1
        press(KeyStroke(keyCode:1,command:true));advance(5)
        check(try words().contains("draft for the launch"),
              "website typing (G12): a shortcut that keeps focus: the words are saved after the settle, even with a click join that would fail once")
        check(pageJoins == pageJoinsBefore,"website typing (G12): a settle in the same field takes the full join only, no click join")
        failPageJoins=0
        // Tab to a button: the click join is compared with the page from before the full join's denial.
        advance(1);type("button after tab")
        pageJoinsBefore=pageJoins
        chrome.focus=chrome.button;press(KeyStroke(keyCode:48));advance(5)
        check(try words().contains("button after tab") && pageJoins == pageJoinsBefore+1,
              "website typing (G12): Tab to a button: one click join after the full join proves the page and saves the words")
        // Tab to a button while that click join fails: nothing proves the page, so nothing is saved (as at a click).
        chrome.focus=nil;advance(1);type("unproven button")
        chrome.focus=chrome.button;failPageJoins=1;press(KeyStroke(keyCode:48));advance(5)
        check(try !words().contains {$0.contains("unproven button")},"website typing (G12): Tab to a button with a click join that fails: nothing is saved")
        failPageJoins=0;chrome.focus=nil;advance(5)
        // gold/r2-typing (golden 5 G12): Command-Return or Control-Return with focus kept in the field, its click join
        // refused once (an Apple Event that times out). That join saves nothing and proves nothing, and no longer makes
        // the page forgotten: the settle's full join allows the same field and saves the words, as before the chorded
        // Return took a click join. Every privacy refusal at the settle still drops them.
        func chordedReturn(_ text:String,_ stroke:KeyStroke,atSettle:()->Void={}) throws {
            chrome.focus=nil;advance(1);type(text)
            let before=pageJoins;failPageJoins=1
            press(stroke)
            check(try pageJoins == before+1 && failPageJoins == 0 && !words().contains(text),"website typing (G12): setup: the chorded Return's click join fails, nothing is saved at once")
            atSettle();advance(5)
        }
        try chordedReturn("send with command return",KeyStroke(keyCode:36,command:true))
        check(try words().filter {$0 == "send with command return"}.count == 1,
              "website typing (G12): Command-Return with focus kept, its click join timed out once: saved once after the settle (was: dropped)")
        try chordedReturn("send with control return",KeyStroke(keyCode:36,control:true))
        check(try words().filter {$0 == "send with control return"}.count == 1,"website typing (G12): the same with Control-Return: saved once after the settle")
        try chordedReturn("send with command enter",KeyStroke(keyCode:76,command:true))
        check(try words().filter {$0 == "send with command enter"}.count == 1,"website typing (G12): the same with Command-Enter on the keypad: saved once after the settle")
        try chordedReturn("return then incognito",KeyStroke(keyCode:36,command:true)) {chrome.addWindow("919",mode:"incognito")}
        check(try !words().contains {$0.contains("return then incognito")} && !WebTypingRoute.shared.burst.session.hasLive && WebTypingRoute.shared.burst.session.parkedCount == 0,
              "website typing (G12): the same with an Incognito window open at the settle: dropped")
        chrome.removeWindow("919")
        try chordedReturn("return then guest",KeyStroke(keyCode:36,command:true)) {chrome.addWindow("920",mode:"guest")}
        check(try !words().contains {$0.contains("return then guest")},"website typing (G12): the same with a Guest window open at the settle: dropped")
        chrome.removeWindow("920")
        try chordedReturn("return then blocked",KeyStroke(keyCode:36,command:true)) {
            if var p=try? store.policy() {p.blockedDomains=["example.org"];try? store.updatePolicy(p)}
        }
        check(try !words().contains {$0.contains("return then blocked")},"website typing (G12): the same on a site blocked at the settle: dropped")
        do {var p=try store.policy();p.blockedDomains=[];try store.updatePolicy(p)}
        try chordedReturn("return then card",KeyStroke(keyCode:36,command:true)) {chrome.field.labels=BrowserTypingFieldLabels(texts:["Card number"],identifiers:["cc-number"])}
        check(try !words().contains {$0.contains("return then card")},"website typing (G12): the same in a card number field at the settle: dropped")
        chrome.field.labels=BrowserTypingFieldLabels(texts:["Notes"],identifiers:[])
        try chordedReturn("return then code",KeyStroke(keyCode:36,command:true)) {chrome.field.labels=BrowserTypingFieldLabels(texts:["Verification code"],identifiers:["otp"])}
        check(try !words().contains {$0.contains("return then code")},"website typing (G12): the same in a verification code field at the settle: dropped")
        chrome.field.labels=BrowserTypingFieldLabels(texts:["Notes"],identifiers:[])
        // fix/chrome-capture (QF-11): focus moves to a password field of the page at the settle. (Turning the typed
        // field itself secure and back would now refuse that field for good: a password shown as text.)
        try chordedReturn("return then password",KeyStroke(keyCode:36,command:true)) {
            chrome.focus=WebFakeNode("password",role:"AXTextField",subrole:"AXSecureTextField",parent:chrome.field.parent)
        }
        check(try !words().contains {$0.contains("return then password")},"website typing (G12): the same in a password field at the settle: dropped")
        chrome.focus?.parent=nil;chrome.focus=nil
        try chordedReturn("return then secure input",KeyStroke(keyCode:36,command:true)) {secureOn=true}
        check(try !words().contains {$0.contains("return then secure input")},"website typing (G12): the same with secure input on at the settle: dropped")
        secureOn=false
        try chordedReturn("return then other page",KeyStroke(keyCode:36,command:true)) {chrome.page("https://notes.example.org/pad/12")}
        check(try !words().contains {$0.contains("return then other page")},"website typing (G12): the same on another page at the settle: dropped")
        chrome.page("https://notes.example.org/pad/7?view=1#top");chrome.focus=nil;advance(5)
        // Review G51: a key capture drops as late is never read, and the words on either side of it are never saved as one.
        advance(1);type("ship the pricin")
        capture.handleNativeKey(eventAt:mono-200_000_000,keyCode:0,shortcut:false) {reads+=1;return "g"}
        advance(0.5);type(" page friday");submit()
        check(try !words().contains {$0.contains("pricin page")} && words().contains("ship the pricin"),
              "website typing (G51): a key dropped as late never splices the words on either side of it")
        // Incognito or Guest: any such window open means nothing, and drops the unsaved words.
        advance(1);type("before private")
        chrome.addWindow("202",mode:"incognito")
        try unchanged("website typing: an Incognito window open: nothing read or saved") {type("while private");submit();advance(5)}
        check(try !words().contains {$0.contains("before private") || $0.contains("while private")},"website typing: the unsaved words typed before the Incognito window opened are dropped")
        check(try dot() == .notHere && !dot().showsDot,"website typing: with an Incognito window open the dot is off and the menu says not recording")
        chrome.removeWindow("202");chrome.addWindow("303",mode:"guest")
        try unchanged("website typing: a Guest window open: nothing read or saved") {advance(1);type("guest words");submit()}
        chrome.removeWindow("303")
        // Password fields.
        // (A separate password field: the typed field turned secure and back would stay refused, QF-11.)
        let passwordField=WebFakeNode("password",role:"AXTextField",subrole:"AXSecureTextField",parent:chrome.field.parent)
        chrome.focus=passwordField
        try unchanged("website typing: a password field: nothing read or saved") {advance(1);type("hunter2hunter2");submit()}
        passwordField.parent=nil;chrome.focus=nil
        // QF-11: the same password field shown as text ("Show password") is refused too.
        passwordField.subrole="";passwordField.parent=chrome.field.parent;chrome.focus=passwordField
        try unchanged("website typing (QF-11): the password field shown as text: nothing read or saved") {advance(1);type("hunter3hunter3");submit()}
        passwordField.parent=nil;chrome.focus=nil
        // Secrets in an ordinary field: the scrubber applies.
        advance(1);type("the code is sk-live-4eC39HqLyjWDarjtT1zdp7dc ok");submit()
        check(try !words().joined().contains("4eC39HqLyjWDarjtT1zdp7dc") && !raw().contains("4eC39HqLyjWDarjtT1zdp7dc"),"website typing: an API key typed in an ordinary field is never saved (scrubber)")
        // Other websites off: an unknown site types nothing.
        try choices {$0.otherWebsites=false}
        try unchanged("website typing: Other websites off: nothing typed on an unknown site") {advance(1);type("other off");submit()}
        try choices {$0.otherWebsites=true}
        // Categories: email follows its switch (on by default since fix/typing-e2e L1, turned off here); search follows its switch.
        chrome.page("https://mail.google.com/mail/u/0/?compose=new#inbox")
        try choices {$0.messagesAndEmail=false}
        try unchanged("website typing: email off: nothing typed in Gmail") {advance(1);type("dear team");submit()}
        try choices {$0.messagesAndEmail=true}
        advance(1);type("dear team");submit()
        check(try words().contains("dear team") && rows().contains {$0.url == "https://mail.google.com"},"website typing: email on: Gmail is typed, with its site only")
        try choices {$0.messagesAndEmail=false}
        chrome.page("https://www.google.com/search?q=red+boots")
        try choices {$0.searchAndAI=false}
        try unchanged("website typing: Search and AI off: nothing typed on a search page") {advance(1);type("blue boots");submit()}
        try choices {$0.searchAndAI=true}
        // typingfix (owner/v1 review F1): Messages and email off holds on messaging websites, on every
        // page of the site (a feed or home page too), and in message composers on unlisted sites.
        for url in ["https://www.facebook.com/","https://www.linkedin.com/feed/","https://x.com/home","https://voice.google.com/"] {
            chrome.page(url)
            try unchanged("website typing: Messages and email off (the default): nothing typed on \(url)") {advance(1);type("see you at six");submit()}
            check(try dot() == .notHere,"website typing: no dot on a messaging site while Messages and email is off: \(url)")
        }
        try choices {$0.messagesAndEmail=true}
        // typingfix review: the messaging rule never widens. Messages and email on with Other websites off
        // (facebook.com/ is not listed) or Search and AI off (a search on x.com) still types nothing.
        try choices {$0.otherWebsites=false}
        chrome.page("https://www.facebook.com/")
        try unchanged("website typing: Messages and email on, Other websites off: nothing typed on facebook.com/") {advance(1);type("feed post words");submit()}
        try choices {$0.otherWebsites=true;$0.searchAndAI=false}
        chrome.page("https://x.com/search?q=secret")
        try unchanged("website typing: Messages and email on, Search and AI off: nothing typed on an x.com search") {advance(1);type("search words");submit()}
        try choices {$0.searchAndAI=true}
        chrome.page("https://www.facebook.com/")
        advance(1);type("see you at six");submit()
        check(try words().contains("see you at six") && rows().contains {$0.url == "https://www.facebook.com"},"website typing: Messages and email on: a messaging site is typed, with its site only")
        if let facebook=try rows().first(where:{$0.url == "https://www.facebook.com"}),var linkedin=try rows().first(where:{$0.url == "https://notes.example.org"}) {
            linkedin.url="https://www.linkedin.com";linkedin.title="www.linkedin.com"
            check(try store.typedTextPolicy().permitsWebsiteRow(facebook,settings:store.policy()) && store.typedTextPolicy().permitsWebsiteRow(linkedin,settings:store.policy()),
                  "website typing: with Messages and email on, the store takes a messaging site's row")
            try choices {$0.messagesAndEmail=false}
            check(try !store.typedTextPolicy().permitsWebsiteRow(facebook,settings:store.policy()) && !store.typedTextPolicy().permitsWebsiteRow(linkedin,settings:store.policy()),
                  "website typing: with Messages and email off, the store refuses a messaging site's row (a feed page's too)")
        } else {check(false,"website typing: the rows the store check needs were saved")}
        try choices {$0.messagesAndEmail=false}
        chrome.page("https://shop.example.org/help")
        chrome.field.labels=BrowserTypingFieldLabels(texts:["Write a message"],identifiers:["composer"])
        try unchanged("website typing: a message composer on an unlisted site follows Messages and email (off): nothing typed") {advance(1);type("hello there");submit()}
        check(try dot() == .notHere,"website typing: no dot in a message composer while Messages and email is off")
        chrome.field.labels=BrowserTypingFieldLabels(texts:["Notes"],identifiers:[])
        advance(1);type("order 1142 is late");submit()
        check(try words().contains("order 1142 is late"),"website typing: an ordinary field on the same site is typed")
        // Blocked sites: Chrome page history's list and the typing blocks.
        for url in ["https://www.chase.com/","https://www.plannedparenthood.org/","https://accounts.google.com/","https://shell.cloud.google.com/"] {
            chrome.page(url)
            try unchanged("website typing: a blocked site types nothing: \(url)") {advance(1);type("blocked words");submit()}
            check(try dot() == .notHere,"website typing: no dot on a blocked site: \(url)")
        }
        // "Don't record this site" (the owner's site list) stops typing on it at once.
        chrome.page("https://notes.example.org/pad/8")
        advance(1);type("half a thought")
        var p=try store.policy();p.blockedDomains=["example.org"];try store.updatePolicy(p)
        try unchanged("website typing: Don't record this site: nothing typed on it") {type(" more");submit();advance(5)}
        check(try !words().contains {$0.contains("half a thought")},"website typing: Don't record this site drops the unsaved words")
        p=try store.policy();p.blockedDomains=[];try store.updatePolicy(p)
        // Don't record typing for 10 minutes.
        try store.snoozeTyping(minutes:10)
        try unchanged("website typing: typing paused: nothing read") {advance(1);type("paused words");submit()}
        try store.resumeTyping()
        // typingfix (owner/v1 review F2): consent covers a scope. A consent saved before scopes were
        // kept (Notes and TextEdit, no websites) or for fewer places types nothing until "Turn on typing"
        // accepts this build's scope.
        chrome.page("https://notes.example.org/pad/11")
        var older=try store.typedTextPolicy();older.acceptedScope=nil
        try store.transaction {try store.saveTypedTextPolicyWithinTransaction(older)}
        check(try !store.typedTextPolicy().consented && store.typedTextPolicy().scopeWidened,"website typing: a consent from before website typing does not cover it")
        try unchanged("website typing: an older consent (apps only): nothing read or saved on a website") {advance(1);type("older consent");submit();advance(5)}
        check(try dot() == .locked(.notAccepted),"website typing: the menu says typing is locked until it is turned on again")
        for narrow in [TypedConsentScope(apps:CaptureGate.nativeApps,websites:false),TypedConsentScope(apps:["com.apple.Notes"],websites:true)] {
            try store.acceptSafeTyping(scope:narrow)
            try unchanged("website typing: a consent for fewer places (websites \(narrow.websites)): nothing read or saved") {advance(1);type("narrow consent");submit();advance(5)}
        }
        try store.acceptSafeTyping()
        advance(1);type("accepted again");submit()
        check(try words().contains("accepted again") && store.typedTextPolicy().acceptedScope == .current,"website typing: accepting this build's scope types again")
        // typingfix (owner/v1 review F3): native typing's direct-keyboard rule. Under an input method
        // a key is unproven before any join read: no join, no Apple Event, nothing read or saved.
        direct=false
        let imeJoins=joins,imeEvents=chrome.appleEvents,imeAX=chrome.ax
        try unchanged("website typing: an input method: nothing read or saved") {advance(1);type("nihongo");submit();advance(5)}
        check(joins == imeJoins && chrome.appleEvents == imeEvents && chrome.ax == imeAX,"website typing: an input method starts no join read")
        check(try dot() == .notHere,"website typing: no dot under an input method")
        direct=true
        advance(1);type("direct again");submit()
        check(try words().contains("direct again"),"website typing: a direct layout again: typed")
        // A change of input source seals the unfinished website words, as native typing seals its unit:
        // between direct layouts the settle's fresh join saves them; into an input method it drops them.
        advance(1);type("typed on abc")
        check(WebTypingRoute.shared.burst.session.hasLive,"website typing: the unfinished words are held")
        capture.inputSourceChanged()
        check(!WebTypingRoute.shared.burst.session.hasLive,"website typing: an input source change seals the unfinished words")
        advance(5)
        check(try words().contains("typed on abc"),"website typing: sealed between direct layouts, the settle's fresh join saves them")
        advance(1);type("typed before ime")
        direct=false
        capture.inputSourceChanged()
        check(!WebTypingRoute.shared.burst.session.hasLive,"website typing: switching to an input method seals the unfinished words")
        advance(5)
        check(try !words().contains {$0.contains("typed before ime")},"website typing: under the input method the sealed words are never saved")
        direct=true
        // Codex 07:10 (field hold): an unlabelled box refused as `field` holds the refusal with no join per key; an
        // input-source change (nothing unfinished) ends the hold, and the box, labelled by then, is typed.
        chrome.field.labels=BrowserTypingFieldLabels(texts:[],identifiers:[])
        advance(1);type("ab");advance(0.3)
        let holdJoins=joins,holdEvents=chrome.appleEvents,holdAsked=holdChecks
        try unchanged("website typing (field hold): keys in a refused unlabelled box: nothing read or saved") {type("held words")}
        check(joins == holdJoins && chrome.appleEvents == holdEvents && holdChecks > holdAsked && holdChecks <= holdAsked+10,
              "website typing (field hold): 10 keys in the refused box take no join and no Apple Event")
        try unchanged("website typing (field hold): Return and the settle save nothing typed during the hold") {submit();advance(5)}
        advance(1);type("cd");advance(0.3)
        chrome.field.labels=BrowserTypingFieldLabels(texts:["Notes"],identifiers:[])
        let heldAgain=joins
        type("x")
        check(joins == heldAgain,"website typing (field hold): the box labelled mid-burst stays held until a boundary (stated cost)")
        capture.inputSourceChanged()
        // (Review FH-1: the last held drop started a quiet period; typing resumes after it.)
        advance(0.5)
        type("typed after the input source");submit()
        check(try words().contains("typed after the input source") && joins > heldAgain,"website typing (field hold): an input-source change ends the hold; the labelled box is typed")
        // typing-all final review: Spotlight over Chrome. Keys go to Spotlight
        // (native typing), never to a Chrome join, and the menu follows it.
        chrome.page("https://notes.example.org/pad/9")
        advance(1);type("in chrome");submit()
        let spotlight:pid_t=5_151,liveFocus=NativeTypingRoute.keyFocus,liveBundleOf=NativeTypingRoute.bundleOf
        NativeTypingRoute.keyFocus={spotlight}
        NativeTypingRoute.bundleOf={$0 == spotlight ? "com.apple.Spotlight" : $0 == WebFakeChrome.pid ? "com.google.Chrome" : nil}
        var targets:[String]=[]
        coordinator.onKeyTarget={targets.append($0)}
        let spotJoins=joins,spotProofs=proofReads,spotLights=lights
        advance(1);type("quarterly report")
        check(joins == spotJoins && lights == spotLights && proofReads >= spotProofs+16 && targets.last == "com.apple.Spotlight",
              "website typing: a Spotlight search over Chrome goes to native typing in Spotlight, never to a Chrome join (\(joins-spotJoins) joins)")
        check(try store.typingIndicator(frontmostBundle:"com.apple.Spotlight") == .recording(app:"Spotlight"),"website typing: the dot is judged for Spotlight")
        NativeTypingRoute.keyFocus={WebFakeChrome.pid}
        advance(1);type("back")
        check(joins > spotJoins && targets.last == "com.google.Chrome","website typing: Spotlight closed: keys go to Chrome's join again")
        NativeTypingRoute.keyFocus=liveFocus
        NativeTypingRoute.bundleOf=liveBundleOf
        coordinator.onKeyTarget=nil
        // Another app in front: website typing takes no key.
        let joinsBefore=joins,lightsBefore=lights
        capture.switchFrontmost(pid:4_243,bundle:"com.apple.Notes") {_,_ in}
        type("in notes")
        check(joins == joinsBefore && lights == lightsBefore,"website typing: keys in another app start no Chrome join")
        saved=try rows()
        check(try saved.allSatisfy {WebTypedRow.valid($0) && $0.url.hasPrefix("https://") && $0.text.isEmpty} && sealed(),"website typing: every website row is a sealed, origin-only join row")
        try websiteSettle(store:store,rows:rows,choices:choices)
    }
    /// fix/chrome-capture: X's composer through the actual EventCapture, WebTypingRoute, Coordinator and store, with the
    /// real join and Post check against a fake X page. Only a plain click proven on the composer's own Post button, and
    /// released on it, marks the composer's saved rows submitted (sendBy "button"); everything else leaves them drafts.
    /// The rows are marked in place: never a second row, the words untouched, other rows' revisions unchanged.
    /// fix/chrome-capture (QF-2): typing, then within a second a shortcut to another app (Command-Tab), the address bar
    /// (Command-L) or a new tab (Command-T). The text is saved at the shortcut's key-down, while its page is still in
    /// front; before, the unit was parked and its settle join (Chrome no longer in front, focus in the address bar or
    /// a new tab) dropped it. Command-Shift-N (Incognito), an Incognito window already open when the shortcut's join
    /// runs, a new window, and secure input still save nothing.
    static func websiteSwitchShortcuts(root:URL) throws {
        let store=try MemoryStore(home:root.appendingPathComponent("website-switch"),writable:true,automaticallySyncSearch:false)
        try store.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()));try store.setUpTypedVault();try store.acceptSafeTyping()
        let coordinator=try Coordinator(store:store,permissions:{true}) {}
        var mono:UInt64=95_000_000_000,secureOn=false,reads=0
        var timers:[(at:UInt64,work:()->Void)]=[]
        func schedule(_ delay:TimeInterval,_ work:@escaping ()->Void) {timers.append((mono+UInt64(delay*1_000_000_000),work))}
        func advance(_ seconds:Double) {
            let target=mono+UInt64(seconds*1_000_000_000)
            while let i=timers.indices.filter({timers[$0].at<=target}).min(by:{timers[$0].at<timers[$1].at}) {
                let timer=timers.remove(at:i);mono=max(mono,timer.at);timer.work()
            }
            mono=target
        }
        let chrome=WebFakeChrome(url:"http://127.0.0.1:8793/plain.html")
        chrome.window.title="Plans - Google Chrome";chrome.focus=chrome.field
        let join=BrowserTypingJoin<WebFakeNode>()
        WebTypingRoute.shared=WebTypingRoute(environment:WebTypingRoute.Environment(now:{mono},wall:{Date()},join:{pid,sites,enabled in
            join.join(environment:chrome.environment(now:{mono},enabled:enabled),appleEvents:chrome.ae,accessibility:chrome.access,
                      blockList:sites.blockList,alwaysBlocked:sites.alwaysBlocked,sites:sites.permits(url:),field:sites.permits(url:field:))
        },pointerJoin:{pid,sites,enabled in
            join.join(environment:chrome.environment(now:{mono},enabled:enabled),appleEvents:chrome.ae,accessibility:chrome.access,
                      blockList:sites.blockList,alwaysBlocked:sites.alwaysBlocked,sites:sites.permits(url:),anyFocus:true)
        },light:{pid,sites,enabled in
            join.light(environment:chrome.environment(now:{mono},enabled:enabled),appleEvents:chrome.ae,accessibility:chrome.access,
                       blockList:sites.blockList,alwaysBlocked:sites.alwaysBlocked,sites:sites.permits(url:),field:sites.permits(url:field:))
        },schedule:schedule,secureInput:{secureOn},pressAndHold:{true},secondsSinceMouseDown:{nil},directKeyboardInput:{true}))
        let pageEnvironment=ChromePageEnvironment(frontmost:{(WebFakeChrome.pid,"com.google.Chrome","99998:1:com.google.Chrome","Google Chrome")},instances:{1},
            secureInput:{false},verify:{_,_ in false},permission:{_ in OSStatus(-1743)},transport:{_ in {_ in nil}},
            background:{$0()},main:{$0()},schedule:{_,_ in},now:{Date()})
        let typing=EventCapture.TypingEnvironment(now:{mono},proof:{_,_ in nil},schedule:schedule,secureInput:{false},pressAndHold:{true})
        let capture=EventCapture(coordinator:coordinator,typingEnvironment:typing,pageEnvironment:pageEnvironment)
        func type(_ text:String) {for c in text {advance(0.08);capture.handleNativeKey(eventAt:mono,keyCode:0,shortcut:false) {reads+=1;return String(c)}}}
        func press(_ stroke:KeyStroke) {advance(0.08);capture.handleNativeKey(eventAt:mono,stroke:stroke) {reads+=1;return ""}}
        func rows() throws -> [Evidence] {
            try store.actions(limit:500).actions.compactMap {try store.read($0.id)?.evidence}.filter {$0.bundle == "com.google.Chrome" && $0.kind == "keyboard.text_input"}
        }
        func texts() throws -> [String] {try rows().compactMap {try store.hydrateTypedText($0.id,disclosure:.owner)}}
        func toChrome() {chrome.frontPID=nil;capture.switchFrontmost(pid:WebFakeChrome.pid,bundle:"com.google.Chrome") {_,_ in}}
        try coordinator.start()
        var p=try store.policy();p.captureText=true;p.typedConsentVersion=1;p.browserPages=true;p.browserPagesConsentVersion=PrivacySettings.browserPagesConsentCurrent
        try store.updatePolicy(p);coordinator.captureText=true
        toChrome()
        let diagnostics=CaptureDiagnostics.shared
        diagnostics.setEnabled(true)
        defer {diagnostics.setEnabled(false)}
        // A control first: the idle save.
        advance(1);type("plain idle words");advance(5)
        check(try texts() == ["plain idle words"],"switch: the idle save works on this page (\(try texts()))")
        // Command-Tab: the switcher takes Chrome out of front right after the key-down.
        advance(1);type("cmd tab words");press(KeyStroke(keyCode:48,command:true))
        chrome.frontPID=4_101;capture.switchFrontmost(pid:4_101,bundle:"com.apple.TextEdit") {_,_ in};advance(5);toChrome()
        check(try texts().contains("cmd tab words"),"switch (Command-Tab within a second): the Chrome text is saved at the key-down")
        // Command-L: focus moves to the address bar.
        advance(1);type("cmd l words");press(KeyStroke(keyCode:37,command:true));chrome.focus=chrome.toolbar;advance(5);chrome.focus=chrome.field
        check(try texts().contains("cmd l words"),"switch (Command-L): the page text is saved at the key-down")
        // Command-T: a new tab comes to the front with the address bar focused.
        advance(1);type("cmd t words");press(KeyStroke(keyCode:17,command:true))
        chrome.windows[0].tab="8";chrome.page("chrome://newtab/");chrome.focus=chrome.toolbar;advance(5)
        chrome.windows[0].tab="7";chrome.page("http://127.0.0.1:8793/plain.html");chrome.focus=chrome.field
        check(try texts().contains("cmd t words"),"switch (Command-T): the page text is saved at the key-down")
        let saved=try rows()
        check(saved.count == 4 && saved.allSatisfy {$0.browserVerification?.windowID == "101" && $0.browserVerification?.tabID == "7" && $0.captureProvenance?.unit?.send != "detected"},
              "switch: every row is of the page it was typed in (window 101, tab 7), a draft, never a send (\(saved.count))")
        // Command-Shift-N: not a switch shortcut here; the Incognito window it opens drops the parked text.
        let before=try rows().count
        advance(1);type("incognito shortcut words");press(KeyStroke(keyCode:45,command:true,shift:true))
        chrome.addWindow("303",mode:"incognito");advance(5);chrome.removeWindow("303")
        check(try rows().count == before,"switch (Command-Shift-N): nothing is saved")
        // The shortcut's own join finds an Incognito window (it opened first): everything unsaved is dropped.
        advance(1);type("incognito race words");chrome.addWindow("304",mode:"incognito");press(KeyStroke(keyCode:17,command:true))
        advance(5);chrome.removeWindow("304")
        check(try rows().count == before,"switch (Command-T, an Incognito window already open at the join): nothing is saved")
        // A normal window opened before the join: another window list, so the text isn't proven and stays parked; it is dropped.
        advance(1);type("new window words");chrome.addWindow("305",mode:"normal");press(KeyStroke(keyCode:48,command:true))
        chrome.frontPID=4_101;capture.switchFrontmost(pid:4_101,bundle:"com.apple.TextEdit") {_,_ in};advance(5);chrome.removeWindow("305");toChrome()
        check(try rows().count == before,"switch (Command-Tab, a window opened before the join): nothing is saved")
        // Secure input on at the shortcut (a password field): nothing is saved.
        advance(1);type("secure shortcut words");secureOn=true;press(KeyStroke(keyCode:37,command:true));advance(5);secureOn=false
        check(try rows().count == before,"switch (Command-L with secure input on): nothing is saved")
        // Not a switch shortcut: Command-W (close tab) stays a parked boundary; the settle finds the page gone.
        advance(1);type("close tab words");press(KeyStroke(keyCode:13,command:true));chrome.windows[0].tab="9";chrome.page("https://other.example.org/");advance(5)
        chrome.windows[0].tab="7";chrome.page("http://127.0.0.1:8793/plain.html")
        check(try rows().count == before,"switch (Command-W): not saved at the key-down; the page it left is gone")
        check(diagnostics.snapshot()["seal.reason.shortcut"] == 1,"switch: diagnostics note the key-down saves with their rows (seen, not counted)")
        let rowTexts=try texts()
        check(reads > 0 && !rowTexts.contains {$0.contains("incognito") || $0.contains("secure") || $0.contains("window") || $0.contains("close")},
              "switch: no refused text in any row")
    }
    /// Review of the (i) set, B5-1 and B5-2: a diagnostics line can't tell a privacy refusal apart. Every join denial
    /// reason, whatever the join noted on its way and however long it took, leaves the same line; a secret withheld
    /// before the store leaves the same line as a piece that saved nothing.
    /// Review RB-M: the form scan's children read. Unsupported and no value are unreadable (the scan denies, field),
    /// never an empty list; a successful empty list is empty; more than 256 is unreadable.
    static func witnessChildren() {
        let node=AXUIElementCreateApplication(getpid())
        let empty:CFArray=[] as CFArray
        check(ChromeTypingWitness.childList(ChromeTypingWitness.copied(.attributeUnsupported,nil)) == nil,
              "witness (RB-M): AXChildren unsupported: unreadable, never []")
        check(ChromeTypingWitness.childList(ChromeTypingWitness.copied(.noValue,nil)) == nil,"witness (RB-M): AXChildren with no value: unreadable, never []")
        check(ChromeTypingWitness.childList(ChromeTypingWitness.copied(.attributeUnsupported,empty)) == nil,
              "witness (RB-M): unsupported, even with a value: unreadable")
        check(ChromeTypingWitness.childList(ChromeTypingWitness.copied(.failure,nil)) == nil
              && ChromeTypingWitness.childList(ChromeTypingWitness.copied(.cannotComplete,nil)) == nil
              && ChromeTypingWitness.childList(ChromeTypingWitness.copied(.success,nil)) == nil,"witness: a failed read: unreadable")
        check(ChromeTypingWitness.childList(ChromeTypingWitness.copied(.success,empty))?.isEmpty == true,"witness: a successful empty list: empty")
        let n256=Array(repeating:node,count:256) as CFArray,n257=Array(repeating:node,count:257) as CFArray
        check(ChromeTypingWitness.childList(ChromeTypingWitness.copied(.success,n256))?.count == 256
              && ChromeTypingWitness.childList(ChromeTypingWitness.copied(.success,n257)) == nil,"witness: 256 children read, 257 unreadable")
        check(ChromeTypingWitness.childList(ChromeTypingWitness.copied(.success,["x"] as CFArray)) == nil
              && ChromeTypingWitness.childList(ChromeTypingWitness.copied(.success,"x" as CFString)) == nil,"witness: a non-element child or a non-list: unreadable")
        // The join side (a container whose children can't be read denies, field): ChromeTypingChecks checkFormScan.
    }
    static func websiteDiagnosticsUniform(root:URL) throws {
        let store=try MemoryStore(home:root.appendingPathComponent("website-diagnostics"),writable:true,automaticallySyncSearch:false)
        try store.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()));try store.setUpTypedVault();try store.acceptSafeTyping()
        let coordinator=try Coordinator(store:store,permissions:{true}) {}
        var mono:UInt64=97_000_000_000
        var forced:BrowserTypingDenial?,joinTook:UInt64=0
        var timers:[(at:UInt64,work:()->Void)]=[]
        func schedule(_ delay:TimeInterval,_ work:@escaping ()->Void) {timers.append((mono+UInt64(delay*1_000_000_000),work))}
        func advance(_ seconds:Double) {
            let target=mono+UInt64(seconds*1_000_000_000)
            while let i=timers.indices.filter({timers[$0].at<=target}).min(by:{timers[$0].at<timers[$1].at}) {
                let timer=timers.remove(at:i);mono=max(mono,timer.at);timer.work()
            }
            mono=target
        }
        let chrome=WebFakeChrome(url:"http://127.0.0.1:8793/plain.html")
        chrome.window.title="Plans - Google Chrome - Work";chrome.focus=chrome.field
        let join=BrowserTypingJoin<WebFakeNode>()
        // A forced denial first notes what a real join notes on its way (its title shape, its form scan) and takes its time.
        func denied(_ d:BrowserTypingDenial) -> BrowserTypingJoinResult {
            CaptureDiagnostics.shared.hold("join.title",ChromeWindowMatching.TitleShape.profile)
            CaptureDiagnostics.shared.hold("join.formScan",BrowserFormScanResult.exhausted)
            mono+=joinTook
            return .denied(d)
        }
        WebTypingRoute.shared=WebTypingRoute(environment:WebTypingRoute.Environment(now:{mono},wall:{Date()},join:{pid,sites,enabled in
            if let d=forced {return denied(d)}
            return join.join(environment:chrome.environment(now:{mono},enabled:enabled),appleEvents:chrome.ae,accessibility:chrome.access,
                             blockList:sites.blockList,alwaysBlocked:sites.alwaysBlocked,sites:sites.permits(url:),field:sites.permits(url:field:))
        },pointerJoin:{pid,sites,enabled in
            if let d=forced {return denied(d)}
            return join.join(environment:chrome.environment(now:{mono},enabled:enabled),appleEvents:chrome.ae,accessibility:chrome.access,
                             blockList:sites.blockList,alwaysBlocked:sites.alwaysBlocked,sites:sites.permits(url:),anyFocus:true)
        },light:{pid,sites,enabled in
            if forced != nil {return nil}
            return join.light(environment:chrome.environment(now:{mono},enabled:enabled),appleEvents:chrome.ae,accessibility:chrome.access,
                              blockList:sites.blockList,alwaysBlocked:sites.alwaysBlocked,sites:sites.permits(url:),field:sites.permits(url:field:))
        },schedule:schedule,secureInput:{false},pressAndHold:{true},secondsSinceMouseDown:{nil},directKeyboardInput:{true}))
        let pageEnvironment=ChromePageEnvironment(frontmost:{(WebFakeChrome.pid,"com.google.Chrome","99998:1:com.google.Chrome","Google Chrome")},instances:{1},
            secureInput:{false},verify:{_,_ in false},permission:{_ in OSStatus(-1743)},transport:{_ in {_ in nil}},
            background:{$0()},main:{$0()},schedule:{_,_ in},now:{Date()})
        let typing=EventCapture.TypingEnvironment(now:{mono},proof:{_,_ in nil},schedule:schedule,secureInput:{false},pressAndHold:{true})
        let capture=EventCapture(coordinator:coordinator,typingEnvironment:typing,pageEnvironment:pageEnvironment)
        func type(_ text:String) {for c in text {advance(0.08);capture.handleNativeKey(eventAt:mono,keyCode:0,shortcut:false) {String(c)}}}
        func press(_ stroke:KeyStroke) {advance(0.08);capture.handleNativeKey(eventAt:mono,stroke:stroke) {""}}
        func rows() throws -> Int {
            try store.actions(limit:500).actions.compactMap {try store.read($0.id)?.evidence}.filter {$0.bundle == "com.google.Chrome" && $0.kind == "keyboard.text_input"}.count
        }
        try coordinator.start()
        var p=try store.policy();p.captureText=true;p.typedConsentVersion=1;p.browserPages=true;p.browserPagesConsentVersion=PrivacySettings.browserPagesConsentCurrent
        try store.updatePolicy(p);coordinator.captureText=true
        capture.switchFrontmost(pid:WebFakeChrome.pid,bundle:"com.google.Chrome") {_,_ in}
        let diagnostics=CaptureDiagnostics.shared
        var clock=Date()
        /// The line one piece of typing leaves, without its sequence number.
        func line(_ body:() throws -> Void) rethrows -> String {
            diagnostics.setEnabled(false);diagnostics.setEnabled(true)
            advance(6);try body();advance(6)
            clock=clock.addingTimeInterval(60)
            let l=diagnostics.flush(now:clock,context:{nil},system:{nil}) ?? ""
            return l.components(separatedBy:" ").filter {!$0.hasPrefix("seq=")}.joined(separator:" ")
        }
        defer {diagnostics.setEnabled(false)}
        // Control: an allowed join names what it noted and how long it took.
        let allowed=line {type("allowed control words")}
        check(allowed.contains("join.full.allowed") && allowed.contains("join.title.profile") && allowed.contains("write.saved")
              && allowed.contains("join.full.ms.") && allowed.contains("seal.reason.idle"),
              "diagnostics B5-1 control: an allowed join names its title shape, its time and the saved row (\(allowed))")
        // B5-1: every denial reason, at join times in every bucket, leaves one and the same line.
        var lines:[String:[String]]=[:]
        for (i,reason) in BrowserTypingDenial.allCases.enumerated() where reason != .inputMethod {
            forced=reason;joinTook=[0,20_000_000,100_000_000,400_000_000][i%4]
            // Keys (a full join) and a plain left click on the field (a click join).
            let l=line {
                type("denied words");advance(1);chrome.hit=chrome.field
                TypingPointer.press(TypingPress(x:1030,y:315,left:true,clicks:1,modified:false));TypingPointer.down(at:mono)
                advance(0.1);TypingPointer.up(at:mono,x:1030,y:315,left:true)
            }
            lines[l,default:[]].append(reason.rawValue)
        }
        forced=nil;joinTook=0
        check(lines.count == 1 && lines.keys.first.map {$0.contains("join.full.denied") && !$0.contains("join.title") && !$0.contains("formScan")
                                                         && !$0.contains(".ms.") && !$0.contains("denied.")} == true,
              "diagnostics B5-1: every join denial reason leaves the same line, with no reason, title, scan or time (\(lines))")
        // B5-2: a secret withheld before the store, a piece the classifier refused and a piece erased to nothing: one line.
        let before=try rows()
        let erased=line {type("ab");press(KeyStroke(keyCode:51));press(KeyStroke(keyCode:51))}
        let scrubbed=line {type("4821")}
        let refused=line {type("sk-abcdefghijkl0123")}
        check(try rows() == before,"diagnostics B5-2 setup: none of the three pieces saved a row")
        // B5-3: keys typed on in a field after a card number latched it read like ordinary typing (5.8 s each, mid-burst).
        func window(_ body:() -> Void) -> String {
            body();clock=clock.addingTimeInterval(60)
            let l=diagnostics.flush(now:clock,context:{nil},system:{nil}) ?? ""
            return l.components(separatedBy:" ").filter {!$0.hasPrefix("seq=")}.joined(separator:" ")
        }
        let words=String(repeating:"abcdefgh ",count:8)
        diagnostics.setEnabled(false);diagnostics.setEnabled(true);advance(6)
        _=window {type("plain opening words ")}
        let ordinary=window {type(words)}
        advance(6)
        diagnostics.setEnabled(false);diagnostics.setEnabled(true);advance(6)
        _=window {type("4111 1111 1111 1111 ")}
        let latched=window {type(words)}
        advance(6)
        check(ordinary == latched && !ordinary.contains("burst.typed"),
              "diagnostics B5-3: keys refused after an allowed join (a latched card number) read like typed keys (\(ordinary) | \(latched))")
        check(scrubbed == refused && refused == erased && !scrubbed.contains("seal.reason") && !scrubbed.contains("write.") && !scrubbed.contains("commit."),
              "diagnostics B5-2: a withheld secret and a piece that saved nothing leave the same line (\(scrubbed) | \(refused) | \(erased))")
    }
    /// claude/int-1003 (compose-send/v1 + fix/chrome-x's compose signals + email-compose/v1): through the actual
    /// EventCapture, WebTypingRoute, Coordinator and store, with a fake Chrome. A Command-Return row stores who it went
    /// to and what it answered; the composer is read again at 0.12/0.35/0.8 s (webmail: until the compose's close
    /// window) and the first confirmation marks the row (`markComposerSent`). Nothing else marks it.
    static func websiteComposeConfirm(root:URL) throws {
        let store=try MemoryStore(home:root.appendingPathComponent("website-compose"),writable:true,automaticallySyncSearch:false)
        try store.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()));try store.setUpTypedVault();try store.acceptSafeTyping()
        let coordinator=try Coordinator(store:store,permissions:{true}) {}
        var mono:UInt64=95_000_000_000,boxValue="",snapshots=0
        var timers:[(at:UInt64,work:()->Void)]=[]
        func schedule(_ delay:TimeInterval,_ work:@escaping ()->Void) {timers.append((mono+UInt64(delay*1_000_000_000),work))}
        func advance(_ seconds:Double) {
            let target=mono+UInt64(seconds*1_000_000_000)
            while let i=timers.indices.filter({timers[$0].at<=target}).min(by:{timers[$0].at<timers[$1].at}) {
                let timer=timers.remove(at:i);mono=max(mono,timer.at);timer.work()
            }
            mono=target
        }
        let chrome=WebFakeChrome(url:"https://x.com/ada/status/1839")
        let group=chrome.field.parent
        func page(_ url:String,name:String,label:String) {
            chrome.page(url);chrome.windows[0].name=name;chrome.window.title=name+" - Google Chrome - Work"
            chrome.field.parent=group;chrome.field.labels=BrowserTypingFieldLabels(texts:[label],identifiers:[]);chrome.focus=chrome.field
        }
        chrome.field.role="AXTextArea"
        let join=BrowserTypingJoin<WebFakeNode>()
        // A live join starts a little after its key: the join's clock starts 61 ms later, so the window title it reads
        // is past the key's settle (`settledMetadata`) and the row keeps the post's title, as a live join of an X post does.
        var joinStart=false
        func joinClock() -> UInt64 {if joinStart {joinStart=false;mono+=61_000_000};return mono}
        var env=WebTypingRoute.Environment(now:{mono},wall:{Date()},join:{pid,sites,enabled in
            joinStart=true;defer {joinStart=false}
            return join.join(environment:chrome.environment(now:joinClock,enabled:enabled),appleEvents:chrome.ae,accessibility:chrome.access,
                      blockList:sites.blockList,alwaysBlocked:sites.alwaysBlocked,sites:sites.permits(url:),field:sites.permits(url:field:))
        },pointerJoin:{pid,sites,enabled in
            join.join(environment:chrome.environment(now:{mono},enabled:enabled),appleEvents:chrome.ae,accessibility:chrome.access,
                      blockList:sites.blockList,alwaysBlocked:sites.alwaysBlocked,sites:sites.permits(url:),anyFocus:true)
        },schedule:schedule,secureInput:{false},pressAndHold:{true},secondsSinceMouseDown:{nil},directKeyboardInput:{true})
        // The re-read: Accessibility only (the fake's tree), the field's emptiness from the fixture's value.
        env.composeSnapshot={_ in snapshots+=1;return join.composeSnapshot(accessibility:chrome.access,value:{_ in boxValue})}
        WebTypingRoute.shared=WebTypingRoute(environment:env)
        let pageEnvironment=ChromePageEnvironment(frontmost:{(WebFakeChrome.pid,"com.google.Chrome","99998:1:com.google.Chrome","Google Chrome")},instances:{1},
            secureInput:{false},verify:{_,_ in false},permission:{_ in OSStatus(-1743)},transport:{_ in {_ in nil}},
            background:{$0()},main:{$0()},schedule:{_,_ in},now:{Date()})
        let typing=EventCapture.TypingEnvironment(now:{mono},proof:{_,_ in nil},schedule:schedule,secureInput:{false},pressAndHold:{true})
        let capture=EventCapture(coordinator:coordinator,typingEnvironment:typing,pageEnvironment:pageEnvironment)
        func type(_ text:String) {for c in text {advance(0.08);boxValue+=String(c);capture.handleNativeKey(eventAt:mono,keyCode:0,shortcut:false) {String(c)}}}
        func chord() {advance(0.08);capture.handleNativeKey(eventAt:mono,stroke:KeyStroke(keyCode:36,command:true)) {""}}
        func row(_ text:String) throws -> Evidence? {
            try store.actions(limit:200).actions.compactMap {try store.read($0.id)?.evidence}
                .first {$0.bundle == "com.google.Chrome" && $0.kind == "keyboard.text_input" && (try? store.hydrateTypedText($0.id,disclosure:.owner)) == text}
        }
        func unit(_ text:String) throws -> TypedUnitProvenance? {try row(text)?.captureProvenance?.unit}
        try coordinator.start()
        var p=try store.policy();p.captureText=true;p.typedConsentVersion=1;p.browserPages=true;p.browserPagesConsentVersion=PrivacySettings.browserPagesConsentCurrent
        try store.updatePolicy(p);coordinator.captureText=true
        capture.switchFrontmost(pid:WebFakeChrome.pid,bundle:"com.google.Chrome") {_,_ in}

        // 1. An X reply on a post's page, Command-Return, the composer empties: sent, confirmed, with its handle and context.
        page("https://x.com/ada/status/1839",name:"Ada on X: \"Small tools beat big frameworks every time\" / X",label:"Post your reply")
        advance(1);boxValue="";type("agreed on all of it");chord()
        let atGesture=try unit("agreed on all of it")
        check(atGesture?.send == "detected" && atGesture?.sendBy == "commandReturn" && atGesture?.confirm == nil,
              "compose (X): at the gesture the row is X's Command-Return send, not yet confirmed (\(String(describing:atGesture?.confirm)))")
        check(atGesture?.handle == "ada" && atGesture?.contextAuthor == "Ada" && atGesture?.contextExcerpt == "Small tools beat big frameworks every time",
              "compose (X): the row stores the @handle and the replied-to post's author and excerpt, from the page facts the join read (\(String(describing:atGesture?.handle)) \(String(describing:atGesture?.contextAuthor)) \(try row("agreed on all of it")?.title ?? "-"))")
        advance(0.05);boxValue="";advance(1)
        let x=try unit("agreed on all of it")
        check(x?.send == "detected" && x?.sendBy == "commandReturn" && x?.confirm == "fieldCleared","compose (X): the emptied composer confirms it (\(String(describing:x?.confirm)))")
        check(try row("agreed on all of it").flatMap {ComposeView.line($0)} == "Replied to Ada's post on X","compose (X): the card's line names the post it answered")
        // 2. X, Command-Return, the words stay (a blocked post): no confirmation by the last read.
        advance(1);boxValue="";type("still in the box");chord();advance(2)
        check(try unit("still in the box")?.confirm == nil,"compose (X): a composer still holding the words confirms nothing")
        // 3. Gmail, Command-Return, the compose closes at 0.3 s: a send, confirmed by the close, subject and context stored.
        page("https://mail.google.com/mail/u/0/#inbox/FMfcgz",name:"Re: Pricing - sam@example.com - Gmail",label:"Message Body")
        advance(1);boxValue="";type("sounds good to me");chord()
        let draft=try unit("sounds good to me")
        check(draft != nil && draft?.send == "unknown" && draft?.sendBy == nil,"compose (Gmail): at Command-Return the row is a draft (\(String(describing:draft?.send)))")
        check(draft?.subject == "Pricing" && draft?.contextExcerpt == "Pricing","compose (Gmail): the bare subject and the thread it answers are stored")
        advance(0.3);chrome.field.parent=nil;advance(3)
        let sent=try unit("sounds good to me")
        check(sent?.send == "detected" && sent?.sendBy == "commandReturn" && sent?.confirm == "composerClosed",
              "compose (Gmail): the compose closing within its window marks the send (\(String(describing:sent?.send)) \(String(describing:sent?.confirm)))")
        check(try row("sounds good to me").flatMap {try store.action($0.id)?.state} == "submitted","compose (Gmail): its action is submitted")
        // 4. Gmail, Command-Return, the body empties but the compose stays open (no recipient): a draft.
        page("https://mail.google.com/mail/u/0/#inbox/FMfcgz",name:"Re: Pricing - sam@example.com - Gmail",label:"Message Body")
        advance(1);boxValue="";type("missing recipient words");chord();advance(0.1);boxValue="";advance(3)
        check(try unit("missing recipient words")?.send == "unknown","compose (Gmail): an emptied body in a compose that stays open is not a send")
        // 5. A key typed after the gesture ends the re-reads: a close after it proves nothing.
        advance(1);boxValue="";type("then kept typing");chord();advance(0.05);type("x");chrome.field.parent=nil;advance(3)
        check(try unit("then kept typing")?.send == "unknown","compose (Gmail): keys typed after the gesture end its re-reads")
        chrome.field.parent=group
        check(snapshots > 0,"compose: the re-reads ran (Accessibility only)")
    }
    static func websitePostGesture(root:URL) throws {
        let home=root.appendingPathComponent("website-post")
        let store=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false)
        try store.attachVault(TypedTextVault(keyStore:InMemoryTypedKeyStore()));try store.setUpTypedVault();try store.acceptSafeTyping()
        let coordinator=try Coordinator(store:store,permissions:{true}) {}
        var mono:UInt64=90_000_000_000,secureOn=false,reads=0
        var timers:[(at:UInt64,work:()->Void)]=[]
        func schedule(_ delay:TimeInterval,_ work:@escaping ()->Void) {timers.append((mono+UInt64(delay*1_000_000_000),work))}
        func advance(_ seconds:Double) {
            let target=mono+UInt64(seconds*1_000_000_000)
            while let i=timers.indices.filter({timers[$0].at<=target}).min(by:{timers[$0].at<timers[$1].at}) {
                let timer=timers.remove(at:i);mono=max(mono,timer.at);timer.work()
            }
            mono=target
        }
        // X's home page: the post box and its toolbar (Post, emoji) in main, the navigation's Post link, the search box.
        let chrome=WebFakeChrome(url:"https://x.com/home")
        // QF-10: Chrome's real AXTitle carries " - Google Chrome" and a profile after the window's Apple Events name.
        chrome.window.title="Home / X - Google Chrome - Work";chrome.windows[0].name="Home / X"
        let main=WebFakeNode("main",role:"AXGroup",subrole:"AXLandmarkMain",parent:chrome.web)
        let composer=WebFakeNode("composer",role:"AXGroup",parent:WebFakeNode("column",role:"AXGroup",parent:main))
        let box=WebFakeNode("post-box",role:"AXTextArea",parent:WebFakeNode("editor",role:"AXGroup",parent:composer))
        box.labels=BrowserTypingFieldLabels(texts:["Post text"],identifiers:["notranslate","public-DraftEditor-content"])
        let toolbar=WebFakeNode("toolbar",role:"AXGroup",parent:composer)
        let post=WebFakeNode("post",role:"AXButton",parent:toolbar);post.title="Post";post.frame=ChromeBounds(x:1000,y:300,width:60,height:30)
        let postLabel=WebFakeNode("post-label",role:"AXStaticText",parent:post)
        let emoji=WebFakeNode("emoji",role:"AXButton",parent:toolbar);emoji.desc="Add emoji";emoji.frame=ChromeBounds(x:900,y:300,width:30,height:30)
        let nav=WebFakeNode("nav",role:"AXGroup",subrole:"AXLandmarkNavigation",parent:chrome.web)
        let navPost=WebFakeNode("nav-post",role:"AXLink",parent:nav);navPost.title="Post";navPost.frame=ChromeBounds(x:100,y:600,width:200,height:50)
        let search=WebFakeNode("search",role:"AXTextField",parent:WebFakeNode("search-form",role:"AXGroup",subrole:"AXLandmarkSearch",parent:chrome.web))
        search.labels=BrowserTypingFieldLabels(texts:["Search query"],identifiers:[])
        chrome.focus=box
        let join=BrowserTypingJoin<WebFakeNode>()
        WebTypingRoute.shared=WebTypingRoute(environment:WebTypingRoute.Environment(now:{mono},wall:{Date()},join:{pid,sites,enabled in
            join.join(environment:chrome.environment(now:{mono},enabled:enabled),appleEvents:chrome.ae,accessibility:chrome.access,
                      blockList:sites.blockList,alwaysBlocked:sites.alwaysBlocked,sites:sites.permits(url:),field:sites.permits(url:field:))
        },pointerJoin:{pid,sites,enabled in
            join.join(environment:chrome.environment(now:{mono},enabled:enabled),appleEvents:chrome.ae,accessibility:chrome.access,
                      blockList:sites.blockList,alwaysBlocked:sites.alwaysBlocked,sites:sites.permits(url:),anyFocus:true)
        },light:{pid,sites,enabled in
            join.light(environment:chrome.environment(now:{mono},enabled:enabled),appleEvents:chrome.ae,accessibility:chrome.access,
                       blockList:sites.blockList,alwaysBlocked:sites.alwaysBlocked,sites:sites.permits(url:),field:sites.permits(url:field:))
        },schedule:schedule,secureInput:{secureOn},pressAndHold:{true},secondsSinceMouseDown:{nil},directKeyboardInput:{true},
        submitControl:{pid,x,y,page,focusID,names,enabled in
            join.submitControl(at:x,y,pid:pid,page:page,focusID:focusID,names:names,environment:chrome.environment(now:{mono},enabled:enabled),
                               accessibility:chrome.access)
        }))
        let route=WebTypingRoute.shared
        let pageEnvironment=ChromePageEnvironment(frontmost:{(WebFakeChrome.pid,"com.google.Chrome","99998:1:com.google.Chrome","Google Chrome")},instances:{1},
            secureInput:{false},verify:{_,_ in false},permission:{_ in OSStatus(-1743)},transport:{_ in {_ in nil}},
            background:{$0()},main:{$0()},schedule:{_,_ in},now:{Date()})
        let typing=EventCapture.TypingEnvironment(now:{mono},proof:{_,_ in nil},schedule:schedule,secureInput:{false},pressAndHold:{true})
        let capture=EventCapture(coordinator:coordinator,typingEnvironment:typing,pageEnvironment:pageEnvironment)
        func type(_ text:String) {for c in text {advance(0.08);capture.handleNativeKey(eventAt:mono,keyCode:0,shortcut:false) {reads+=1;return String(c)}}}
        func press(_ stroke:KeyStroke) {advance(0.08);capture.handleNativeKey(eventAt:mono,stroke:stroke) {reads+=1;return ""}}
        func rows() throws -> [Evidence] {
            try store.actions(limit:500).actions.compactMap {try store.read($0.id)?.evidence}.filter {$0.bundle == "com.google.Chrome" && $0.kind == "keyboard.text_input"}
        }
        func row(_ text:String) throws -> Evidence? {try rows().first {try store.hydrateTypedText($0.id,disclosure:.owner) == text}}
        func state(_ text:String) throws -> String {try row(text).flatMap {try store.action($0.id)?.state} ?? "missing"}
        func revision(_ id:String) throws -> String {try store.rows("SELECT revision FROM records WHERE id=?",[id]).first?.first ?? ""}
        /// A press and release at a point (the Post button's middle unless stated), with what happens in between.
        func click(_ node:WebFakeNode?,x:Double=1030,y:Double=315,upX:Double?=nil,upY:Double?=nil,hold:Double=0.1,left:Bool=true,clicks:Int=1,
                   modified:Bool=false,between:()->Void={}) {
            advance(0.3);chrome.hit=node
            TypingPointer.press(TypingPress(x:x,y:y,left:left,clicks:clicks,modified:modified))
            TypingPointer.down(at:mono)
            between()
            advance(hold)
            TypingPointer.up(at:mono,x:upX ?? x,y:upY ?? y,left:left)
        }
        let diagnostics=CaptureDiagnostics.shared
        diagnostics.setEnabled(true)
        defer {diagnostics.setEnabled(false)}
        try coordinator.start()
        var p=try store.policy();p.captureText=true;p.typedConsentVersion=1;p.browserPages=true;p.browserPagesConsentVersion=PrivacySettings.browserPagesConsentCurrent
        try store.updatePolicy(p);coordinator.captureText=true
        capture.switchFrontmost(pid:WebFakeChrome.pid,bundle:"com.google.Chrome") {_,_ in}

        // The mouse-down on Post saves the unfinished words first (a draft, as before); the release on the button marks it.
        advance(1);type("shipping the new build today")
        var down:String?
        click(postLabel) {down=try? state("shipping the new build today")}
        let shipped=try row("shipping the new build today")
        check(down == "draft","post (click): the mouse-down saved the unfinished words as a draft first (\(down ?? "none"))")
        let unit=shipped?.captureProvenance?.unit
        check(unit?.send == "detected" && unit?.sendBy == "button" && unit?.sendControl == "post" && unit?.surface == "social" && unit?.sealReason == "pointer",
              "post (click): released on the composer's Post button, the row is marked a send gesture by its Post button (\(String(describing:unit)))")
        let shippedAction=try shipped.flatMap {try store.action($0.id)}
        check(shippedAction?.state == "submitted" && shippedAction?.description == "Typed in Google Chrome, then clicked its Post button (a sentence).",
              "post (click): its action is submitted, described as a click on Post, never as sent (\(shippedAction?.description ?? ""))")
        check(try rows().count == 1 && route.marked == 1,"post (click): one row, marked in place (no second row)")
        // A pause saved the words before the click: the click marks the saved row.
        advance(1);type("idle then post");advance(5)
        check(try state("idle then post") == "draft","post (pause): the pause saves a draft")
        let idleRevision=try revision(try row("idle then post")!.id)
        click(postLabel)
        check(try state("idle then post") == "submitted" && rows().count == 2,"post (pause): the Post click marks the saved row, still one row")
        check(try revision(try row("idle then post")!.id) != idleRevision,"post (pause): the marked row's revision moved (its summary is written again)")
        // Pieces of one post (a pause, a Return new line): the click marks every piece of that composer.
        let shippedRevision=try revision(shipped!.id)
        advance(1);type("first line here");press(KeyStroke(keyCode:36))
        check(try state("first line here") == "draft","post (Return): Return in X's composer is a new line, never a post (draft)")
        advance(1);type("second piece");advance(5);type("third piece")
        click(postLabel)
        let pieces=try ["first line here","second piece","third piece"].map {try state($0)}
        check(pieces.allSatisfy {$0 == "submitted"},"post (pieces): the Post click marks each saved piece of the post (\(pieces); \(try rows().map {[$0.captureProvenance?.unit?.sealReason ?? "",$0.captureProvenance?.unit?.send ?? "",String($0.browserVerification?.focusID?.prefix(4) ?? "")]}))")
        check(try revision(shipped!.id) == shippedRevision,"post (pieces): an earlier post's row is not touched (its revision is unchanged)")
        // Command-Return posts on X: already a send gesture; a later click adds nothing.
        advance(1);type("chord post");press(KeyStroke(keyCode:36,command:true));advance(3)
        let chord=try row("chord post")?.captureProvenance?.unit
        check(chord?.send == "detected" && chord?.sendBy == "commandReturn","post (chord): Command-Return is X's posting chord (detected, commandReturn)")
        let before=try rows().count
        click(postLabel)
        check(try row("chord post")?.captureProvenance?.unit?.sendBy == "commandReturn" && rows().count == before,"post (chord): a later Post click changes nothing")
        // claude/livefix-1004 (owner, live test 10/3: an X reply that really posted was saved as 11 drafts, none sent).
        // A click inside the post box mid-draft (to move the caret) used to forget the pieces before it (the Post check
        // found no button there and cleared them) and started a new run: one reply, two drafts. Now the click in the
        // box keeps them, the reply stays one run, and the Reply/Post click marks every piece.
        advance(1);type("reply piece one")
        click(box,x:700,y:200)
        advance(0.5);type("reply piece two")
        click(postLabel)
        let midClick=try ["reply piece one","reply piece two"].map {try state($0)}
        check(midClick.allSatisfy {$0 == "submitted"},"post (mid-draft click in the box): the Post click marks the pieces before and after it (\(midClick))")
        let midRuns=Set(try ["reply piece one","reply piece two"].compactMap {try row($0)?.captureProvenance?.unit?.runID})
        let midParts=try ["reply piece one","reply piece two"].compactMap {try row($0)?.captureProvenance?.unit?.part}
        check(midRuns.count == 1 && midParts == [1,2],"post (mid-draft click in the box): one reply is one run in two parts (\(midRuns.count) runs, parts \(midParts))")
        // X re-creates its post box between pieces (a new element, the same page and composer): the pieces in both
        // elements are one post; the Post click is checked against the box in use now and marks them all. (Keys of one
        // burst that moves to another element are still dropped as another burst: unchanged privacy rule.)
        advance(1);type("before the redraw");advance(5)
        let redrawn=WebFakeNode("post-box-redrawn",role:"AXTextArea",parent:box.parent);redrawn.labels=box.labels
        chrome.focus=redrawn
        advance(1);type("after the redraw")
        click(postLabel)
        let redraw=try ["before the redraw","after the redraw"].map {try state($0)}
        check(redraw.allSatisfy {$0 == "submitted"},"post (box re-created): the Post click marks the pieces typed in both elements (\(redraw))")
        let redrawFields=Set(try ["before the redraw","after the redraw"].compactMap {try row($0)?.browserVerification?.focusID})
        check(redrawFields.count == 2,"post (box re-created): the two pieces really were typed in two elements (\(redrawFields.count))")
        chrome.focus=box;redrawn.parent=nil
        // Command-Return after a mid-draft click: the chord sends the whole reply, the piece before the click too.
        advance(1);type("chord piece one")
        click(box,x:700,y:200)
        advance(0.5);type("chord piece two");press(KeyStroke(keyCode:36,command:true));advance(3)
        let chordPieces=try ["chord piece one","chord piece two"].map {try row($0)?.captureProvenance?.unit}
        check(chordPieces.allSatisfy {$0?.send == "detected" && $0?.sendBy == "commandReturn"},
              "post (chord after a mid-draft click): Command-Return marks every piece of the reply (\(chordPieces.map {[$0?.send ?? "",$0?.sendBy ?? ""]}))")
        check(try ["chord piece one","chord piece two"].allSatisfy {try state($0) == "submitted"},"post (chord after a mid-draft click): both pieces read submitted")
        // Everything else leaves the rows drafts, and forgets them (a later click on Post can't mark them).
        func stays(_ name:String,_ text:String,idle:Bool=true,_ act:() throws -> Void) throws {
            advance(1);type(text);if idle {advance(5)}
            try act()
            advance(5)
            check(try state(text) == "draft","post (\(name)): the row stays a draft")
        }
        try stays("X's navigation Post link","nav link words") {click(navPost,x:150,y:620)}
        check(try state("nav link words") == "draft","post (nav link): still a draft")
        click(postLabel)
        check(try state("nav link words") == "draft","post (nav link): a Post click after an unrelated click can't mark rows it forgot")
        post.enabled=false
        try stays("a disabled Post button","disabled words") {click(postLabel)}
        post.enabled=true
        try stays("the emoji button","emoji words") {click(emoji,x:910,y:310)}
        try stays("a drag off the button","drag words") {click(postLabel,upX:1075)}
        try stays("a release just off the button (cancel)","cancel words") {click(postLabel,y:328,upY:334)}
        try stays("a long press","long press words") {click(postLabel,hold:4)}
        try stays("a right click","right click words") {click(postLabel,left:false)}
        try stays("a double click","double click words") {click(postLabel,clicks:2)}
        try stays("a Command-click","modified click words") {click(postLabel,modified:true)}
        try stays("a key between press and release","key between words") {click(postLabel) {press(KeyStroke(keyCode:53))}}
        try stays("another page (a stale composer)","stale page words") {chrome.page("https://x.com/i/bookmarks");click(postLabel);chrome.page("https://x.com/home")}
        try stays("rows over two minutes old","old words") {advance(130);click(postLabel)}
        try stays("an Incognito window at the click","incognito words") {chrome.addWindow("808",mode:"incognito");click(postLabel);chrome.removeWindow("808")}
        try stays("secure input at the click","secure words") {secureOn=true;click(postLabel);secureOn=false}
        advance(1);type("secure live words");secureOn=true;click(postLabel);secureOn=false;advance(5)
        check(try row("secure live words") == nil,"post (secure input): unfinished words at a click under secure input are dropped, not saved or marked")
        chrome.focus=search
        advance(1);type("search words");advance(5)
        chrome.focus=box
        click(postLabel)
        check(try state("search words") == "draft","post (search box): X's search box is never a post")
        // Reopened: the marks and the drafts are what the store kept; no duplicate row anywhere.
        let reopened=try MemoryStore(home:home,writable:true,automaticallySyncSearch:false)
        let marked=try reopened.actions(limit:500).actions.filter {$0.bundle == "com.google.Chrome" && $0.kind == "keyboard.text_input"}
        check(marked.filter {$0.state == "submitted"}.count == 12 && marked.filter {$0.description.contains("clicked its Post button")}.count == 9,
              "post (reopen): after reopening, the nine clicked rows and the three chord rows are submitted (\(marked.map(\.state)))")
        let texts=try rows().compactMap {try store.hydrateTypedText($0.id,disclosure:.owner)}
        check(Set(texts).count == texts.count && texts.count == marked.count,"post: every piece is one row (no duplicates)")
        check(try rows().allSatisfy {WebTypedRow.valid($0) && $0.text.isEmpty},"post: every row is still a valid, sealed join row")
        check(try store.rows("SELECT body FROM records").allSatisfy {row in !texts.contains {row.first?.contains($0) == true}},"post: no typed word in any raw record")
        // Diagnostics: counts only, named in code.
        let counts=diagnostics.snapshot()
        // Privacy review B5: names seen, never how many; no privacy refusal told apart (this run had an Incognito
        // window, a secure-input field and secret words).
        // Review of the (i) set, B5-1: denials name no reason (never post.denied.link or join.click.denied.window).
        let seenNames=["post.pressed","post.marked","post.denied",
                       "post.release.notClick","post.skip.notPlainClick","write.saved","join.full.allowed",
                       "join.click.denied","seal.reason.pointer","join.title.profile"]
        check(seenNames.allSatisfy {counts[$0] == 1} && counts.values.allSatisfy {$0 == 1} && counts.keys.allSatisfy(CaptureDiagnostics.allowed.contains),
              "diagnostics: the Post gesture's and the writes' outcomes are seen, never counted (\(counts.keys.sorted().joined(separator:" ")))")
        check(!counts.keys.contains {["notNormal","sensitiveField","blockedSite","secure","private","secret","held","latch","gate","notFocused","denied."]
                                     .contains(where:$0.contains)},"diagnostics: no privacy refusal is named")
        let line=diagnostics.flush(now:Date(),context:{CaptureDiagnostics.Context(generation:1,policyRevision:"revision",captureEpoch:"epoch")},system:{nil}) ?? ""
        let words=["shipping","build","today","first","second","third","piece","double","modified","incognito","bookmarks","x.com","Home"]
        check(line.hasPrefix("capture-diagnostics run=") && !words.contains {line.contains($0)} && !line.contains("revision")
              && line.allSatisfy {$0.isASCII && ($0.isLetter || $0.isNumber || " .=-".contains($0))},
              "diagnostics: the log line has counter names and numbers only: no typed word, site or revision (\(line.prefix(200)))")
        let names=line.components(separatedBy:" ").drop {!$0.hasPrefix("epoch=")}.dropFirst()
        check(!names.isEmpty && names.allSatisfy {!$0.contains("=") && CaptureDiagnostics.allowed.contains($0)},
              "diagnostics: after the header, only allowed names, with no count")
    }
    /// typingfix review: website rows an earlier owner build saved on a messaging site (every page of
    /// facebook.com, a webmail host) while Messages and email was off are deleted once, at launch, with
    /// their words, stub and summary. Other rows, rows saved later and later switch changes are left alone.
    static func websiteSettle(store:MemoryStore,rows:() throws -> [Evidence],choices:((inout TypedCategoryChoices)->Void) throws -> Void) throws {
        guard let template=try rows().first(where:{$0.url == "https://notes.example.org"}) else {check(false,"website settle: a saved row to copy");return}
        try choices {$0.messagesAndEmail=true}
        func earlier(_ id:String,_ origin:String,_ text:String) throws {
            var e=template;e.id=id;e.url=origin;e.title=BrowserSites.host(of:origin) ?? "";e.text=text;e.typed=nil
            check(try store.ingest(e),"website settle setup: an earlier build's row on \(origin)")
        }
        try earlier("web-earlier-feed","https://www.facebook.com","dm typed on the feed")
        try earlier("web-earlier-mail","https://mail.zoho.in","subject typed in webmail")
        try earlier("web-earlier-notes","https://notes.example.org","ordinary notes words")
        try store.exec("INSERT INTO summaries VALUES(?,?,?)",["web-earlier-feed","{}","r1"])
        func messaging() throws -> [String] {try rows().filter {BrowserTypingSites.messagingSite(host:BrowserSites.host(of:$0.url) ?? "")}.map(\.id).sorted()}
        let doomed=try messaging()
        check(doomed.count >= 3 && doomed.contains("web-earlier-feed") && doomed.contains("web-earlier-mail"),"website settle setup: messaging-site rows saved (\(doomed.count))")
        // Messages and email on at launch: every row stays (the owner allows them now), and the step is done.
        check(try store.settleWebsiteTypingRows() == 0 && messaging() == doomed,"website settle: with Messages and email on, nothing is deleted")
        try store.exec("DELETE FROM metadata WHERE id='typed-web-settle-v1'")
        // Messages and email off at launch: the messaging-site rows go, everything else stays.
        try choices {$0.messagesAndEmail=false}
        let others=try rows().map(\.id).filter {!doomed.contains($0)}
        check(try store.settleWebsiteTypingRows() == doomed.count,"website settle: Messages and email off: the \(doomed.count) messaging-site rows are deleted")
        check(try messaging().isEmpty && rows().map(\.id) == others && store.hydrateTypedText("web-earlier-notes",disclosure:.owner) == "ordinary notes words",
              "website settle: other website rows stay and still open")
        for id in doomed {
            check(try store.read(id) == nil && store.hydrateTypedText(id,disclosure:.owner) == nil && store.typedAfter(id) == nil
                  && store.rows("SELECT id FROM typed_text WHERE id=? UNION ALL SELECT id FROM summaries WHERE id=?",[id,id]).isEmpty
                  && !store.rows("SELECT id FROM tombstones WHERE id=?",[id]).isEmpty,
                  "website settle: \(id): the record, its sealed words, stub and summary are gone")
        }
        // Once only: a later row, and a later switch change, are never settled away.
        try choices {$0.messagesAndEmail=true}
        try earlier("web-later-feed","https://www.facebook.com","typed after the update")
        try choices {$0.messagesAndEmail=false}
        check(try store.settleWebsiteTypingRows() == 0 && store.hydrateTypedText("web-later-feed",disclosure:.owner) == "typed after the update",
              "website settle: runs once; rows saved later stay")
    }
}
// MARK: - QF-17 bracketed design, route level (prototype)
// The actual EventCapture, WebTypingRoute (design pinned to .bracketed on its own environment; the global switch
// is never touched) and store, with a fake Chrome whose every Apple Event costs time on the checks' clock. Reads
// run on the checks' timer queue (background/toMain seams); keys are timers too, so they land inside reads.
final class BracketFakeChrome {
    struct Window {var id:String;var mode:String?;var bounds:ChromeBounds;var name:String;var tab:String;var url:String}
    static let pid:Int32=WebFakeChrome.pid
    var facts=ChromeTargetFacts(pid:pid,bundleID:"com.google.Chrome",launchIdentity:"99998:1790000000:com.google.Chrome",signatureValid:true,
                                bundleVersion:"153.0.8010.54",frameworkVersions:["153.0.8010.54"],instances:1)
    var windows:[Window]
    var axWindows:[WebFakeNode]
    let window:WebFakeNode,web:WebFakeNode,field:WebFakeNode
    var focusedWindow:WebFakeNode
    var focus:WebFakeNode?
    var frontmost:Int32=pid,systemFocused:Int32=pid,secure=false
    /// Per Apple Event (ns); `hung`: every event times out (60 ms, the bracketed session's per-event timeout).
    var latency:UInt64=12_000_000,hung=false
    /// QF-17 silent-loss repro: each frontmost-app read (a read's opening focus check, before any Apple Event) takes
    /// this long, as real Chrome's AX calls do (b+ on 939e6df: 32 ms p50 reads). 0: instant, as before.
    var focusDelay:UInt64=0
    /// Apple Event number that stalls for `stall` ns first (a frozen Chrome that recovers).
    var stallAt:Int?=nil,stall:UInt64=0
    /// The key-time identity reader paused or timed out (nil refs).
    var identityPaused=false
    var appleEvents=0
    var wait:(UInt64)->Void={_ in}
    var onAppleEvent:((Int)->Void)?
    static let bounds=ChromeBounds(left:0,top:25,right:1440,bottom:900)
    init(url:String) {
        window=WebFakeNode("window-101",role:"AXWindow",subrole:"AXStandardWindow");window.frame=ChromeBounds(x:0,y:25,width:1440,height:875);window.title="Plans"
        let scroll=WebFakeNode("scroll",role:"AXScrollArea",parent:window)
        web=WebFakeNode("web",role:"AXWebArea",parent:scroll);web.url=url
        field=WebFakeNode("field",role:"AXTextArea",parent:WebFakeNode("group",role:"AXGroup",parent:web))
        // Codex 06:10 (c68da12): an unlabelled box is refused; the notes box has its label, as in WebFakeChrome.
        field.labels=BrowserTypingFieldLabels(texts:["Notes"],identifiers:[])
        windows=[Window(id:"101",mode:"normal",bounds:Self.bounds,name:"Plans",tab:"7",url:url)];axWindows=[window];focusedWindow=window
    }
    @discardableResult func addWindow(_ id:String,mode:String?) -> WebFakeNode {
        let bounds=ChromeBounds(left:200,top:100,right:1000,bottom:700)
        windows.insert(Window(id:id,mode:mode,bounds:bounds,name:"Private",tab:"9"+id,url:"https://private.example.net/secret"),at:0)
        let node=WebFakeNode("window-"+id,role:"AXWindow",subrole:"AXStandardWindow");node.frame=bounds;node.title="Private";axWindows.append(node)
        return node
    }
    func removeWindow(_ id:String) {windows.removeAll {$0.id == id};axWindows.removeAll {$0.name == "window-"+id}}
    func environment(now:@escaping ()->UInt64,enabled:@escaping ()->Bool) -> ChromeJoinEnvironment {
        ChromeJoinEnvironment(now:now,enabled:enabled,target:{self.facts},automationPermitted:{$0 == Self.pid},launchIdentity:{$0 == Self.pid ? self.facts.launchIdentity : nil})
    }
    func ae(_ r:ChromeJoinRequest) -> ChromeJoinReply? {
        appleEvents+=1
        onAppleEvent?(appleEvents)
        if appleEvents == stallAt {wait(stall)}
        if hung {wait(60_000_000);return nil}
        wait(latency)
        let w=r.windowID.flatMap {id in windows.first {$0.id == id}}
        switch r {
        case .windowIDs:return .ids(windows.map(\.id))
        case .modes:return .texts(windows.compactMap(\.mode))
        case .allBounds:return .boundsList(windows.map(\.bounds))
        case .mode:return w?.mode.map {.text($0)}
        case .bounds:return w.map {.bounds($0.bounds)}
        case .name:return w.map {.text($0.name)}
        case .activeTabID:return w.map {.text($0.tab)}
        case .tabURL(_,let t):return w.flatMap {$0.tab == t ? .text($0.url) : nil}
        }
    }
    var access:ChromeAXAccess<WebFakeNode> {
        ChromeAXAccess<WebFakeNode>(frontmostPID:{if self.focusDelay > 0 {self.wait(self.focusDelay)};return self.frontmost},systemFocusedPID:{self.systemFocused},secureInput:{self.secure},
            focusedWindow:{self.focusedWindow},windows:{self.axWindows},focusedElement:{self.focus ?? self.field},owner:{_ in Self.pid},
            role:{$0.role},subrole:{$0.subrole},parent:{$0.parent},frame:{$0.frame},minimized:{_ in false},title:{$0.title},url:{$0.url},
            fieldLabels:{$0.labels},equal:{$0 === $1},controlNames:{[$0.title ?? "",$0.desc ?? ""]},children:{$0.kids})
    }
    func identity() -> ChromeKeyIdentity {
        ChromeKeyIdentity(frontmostPID:frontmost,secureInput:secure,window:identityPaused ? nil : focusedWindow,focus:identityPaused ? nil : (focus ?? field))
    }
}
extension ProductionCaptureChecks {
    /// A check that documents a source bug found by these checks instead of stopping the run (reported to the implementer).
    static var sourceBugs:[String]=[]
    static func expectSource(_ condition:Bool,_ name:String) {
        if condition {checks+=1;print("PASS "+name)} else {sourceBugs.append(name);print("KNOWN SOURCE BUG (QF-17 route, reported) "+name)}
    }
    /// RB-M in the bracketed read (fix/chrome-capture 7d043a9): the bracketed read uses the witness's own
    /// `ChromeTypingWitness.access`, whose AXChildren is `childList(copy(...))`. Here the fake's container answers
    /// through those two functions: a container whose AXChildren has no value (or is unsupported) makes the bracketed
    /// read refuse as `field`, in the full shape and the lean prototype; a successful read of its children verifies.
    static func bracketedWitnessChildren() {
        let before=ChromeReadShape.current
        defer {ChromeReadShape.current=before}
        for shape in [ChromeReadShape.full,.lean] {
            ChromeReadShape.current=shape
            let name=shape == .full ? "full shape" : "lean prototype"
            for (answer,label,verifies) in [(AXError.noValue,"no value",false),(.attributeUnsupported,"unsupported",false),(.success,"read (control)",true)] {
                let chrome=BracketFakeChrome(url:"https://notes.example.org/pad/7?view=1#top")
                let container=chrome.field.parent!
                let base=chrome.access
                var access=base
                access.children={node in
                    guard node === container else {return base.children(node)}
                    // The witness's decision for this answer; the fake's own list stands in for the element refs.
                    let refs:CFArray=[] as CFArray
                    return ChromeTypingWitness.childList(ChromeTypingWitness.copied(answer,answer == .success ? refs:nil)) == nil ? nil : node.kids
                }
                var clock:UInt64=1_000_000_000
                let r=BrowserTypingJoin<WebFakeNode>(design:.bracketed).join(environment:chrome.environment(now:{clock+=1_000_000;return clock},enabled:{true}),
                    appleEvents:chrome.ae,accessibility:access,blockList:BrowserTypingBlockList(),alwaysBlocked:PrivacySettings.sensitiveDomains)
                if verifies {
                    check(r.proof?.bracket != nil,"RB-M bracketed (\(name)): the field's container children \(label): the read verifies")
                } else {
                    check(r.proof == nil && r.denial == .field,"RB-M bracketed (\(name)): the field's container AXChildren \(label): the bracketed read refuses (field), never reads it as empty")
                }
            }
        }
    }
    struct ChromeLifecycleSnapshot {
        let keys:InMemoryTypedKeyStore
        let serialized:[String:String]
        let words:[String:String]
    }
    static var chromeLifecycleSnapshot:ChromeLifecycleSnapshot?
    /// Called only after the writer harness has returned and its route/timers are gone.
    /// This checks store/vault reconstruction, not macOS Keychain or a real app relaunch.
    static func reopenChromeLifecycle(root:URL) throws {
        guard let expected=chromeLifecycleSnapshot else {check(false,"lifecycle: completed writer snapshot exists");return}
        chromeLifecycleSnapshot=nil
        let reopened=try MemoryStore(home:root.appendingPathComponent("website-typing-bracketed"),writable:true,automaticallySyncSearch:false)
        try reopened.attachVault(TypedTextVault(keyStore:expected.keys))
        check(reopened.typingUnlocked,"lifecycle reopen: persisted consent and original in-memory vault unlock")
        let actions=try reopened.actions(limit:2000).actions.filter {$0.bundle == "com.google.Chrome" && $0.kind == "keyboard.text_input"}
        check(Set(actions.map(\.id)) == Set(expected.words.keys) && actions.count == expected.words.count,
              "lifecycle reopen: exactly the same Chrome row IDs survive with no duplicates")
        for action in actions {
            guard let row=try reopened.read(action.id)?.evidence else {check(false,"lifecycle reopen: original row exists");continue}
            check(try reopened.hydrateTypedText(action.id,disclosure:.owner) == expected.words[action.id],
                  "lifecycle reopen: original sealed Chrome characters hydrate exactly")
            check(try json(row) == expected.serialized[action.id] && row.text.isEmpty && row.browserVerification != nil,
                  "lifecycle reopen: attribution and sealed metadata remain unchanged")
        }
        let repeated=try reopened.actions(limit:2000).actions.filter {$0.bundle == "com.google.Chrome" && $0.kind == "keyboard.text_input"}
        check(repeated.map(\.id) == actions.map(\.id),"lifecycle reopen: repeated retrieval creates no duplicate rows")
        let raw=try reopened.rows("SELECT body FROM records").compactMap {$0.first}.joined()
        check(!expected.words.values.contains {raw.contains($0)},"lifecycle reopen: raw records contain no saved words")
        let rebuiltCoordinator=try Coordinator(store:reopened,permissions:{true}) {}
        check(!rebuiltCoordinator.isRunning,"lifecycle reopen: reconstructed recorder remains OFF until explicitly started")
        print("\(checks) focused Chrome lifecycle checks passed.")
    }
    static func websiteTypingBracketed(root:URL) throws {
        bracketedWitnessChildren()
        // Feasibility prototype numbers (QF17_SHAPE=lean): the lean read shape for the metrics loop only.
        if ProcessInfo.processInfo.environment["QF17_SHAPE"] == "lean" { ChromeReadShape.current = .lean }
        let store=try MemoryStore(home:root.appendingPathComponent("website-typing-bracketed"),writable:true,automaticallySyncSearch:false)
        let chromeVaultKeys=InMemoryTypedKeyStore()
        try store.attachVault(TypedTextVault(keyStore:chromeVaultKeys));try store.setUpTypedVault();try store.acceptSafeTyping()
        var permitted=true,nativeSecure=false
        let coordinator=try Coordinator(store:store,permissions:{permitted}) {}
        let designBefore=ChromeJoinDesign.current
        var mono:UInt64=300_000_000_000
        var timers:[(at:UInt64,seq:Int,work:()->Void)]=[],seq=0
        func schedule(_ delay:TimeInterval,_ work:@escaping ()->Void) {seq+=1;timers.append((mono+UInt64(max(0,delay)*1_000_000_000),seq,work))}
        func at(_ t:UInt64,_ work:@escaping ()->Void) {seq+=1;timers.append((max(t,mono),seq,work))}
        var timerRuns=0
        func run(until target:UInt64) {
            while let i=timers.indices.filter({timers[$0].at<=target}).min(by:{(timers[$0].at,timers[$0].seq) < (timers[$1].at,timers[$1].seq)}) {
                let timer=timers.remove(at:i);mono=max(mono,timer.at);timerRuns+=1;timer.work()
            }
            mono=max(mono,target)
            // The app's 0.5 s heartbeat keeps capture "recording" in wall time (a save needs it <= 5 s old); the fake
            // clock doesn't run it, so beat here, as the QA harness does. Without it a loaded machine fails saves late
            // in the run ("Capture is not recording"): the wholeRead 12 ms admitted-vs-saved gap.
            coordinator.reconcileResume()
        }
        func advance(_ seconds:Double) {run(until:mono+UInt64(seconds*1_000_000_000))}
        let ms:UInt64=1_000_000
        // Per-scenario state.
        var chrome=BracketFakeChrome(url:"https://notes.example.org/pad/7?view=1#top")
        var acquires=0,joinCalls=0,pageCalls=0
        var joinStarts:[UInt64]=[]
        var records:[ChromeReadRecord]=[]
        var typed:[(t:UInt64,c:String)]=[]
        var beforeDeliver:(()->Void)?=nil,afterDeliver:(()->Void)?=nil
        var holdDeliveries=false, delayedDeliveries:[()->Void]=[]
        var finishExecutorProbe=false, executorChecks=0
        var mainDeliveryDelay:TimeInterval=0, readStartDelay:TimeInterval=0
        var osInput:UInt64=0
        var seenRows=Set<String>()
        let liveFocus=NativeTypingRoute.keyFocus
        NativeTypingRoute.keyFocus={chrome.systemFocused}
        defer {NativeTypingRoute.keyFocus=liveFocus}
        func route() -> WebTypingRoute {WebTypingRoute.shared}
        var routeMade=false
        /// QF-17 key accounting, in every scenario of every lane (b+ silent loss on 939e6df): admitted = saved + dropped +
        /// pending, and no bookkeeping error. `finished`: the burst is over, so pending is 0 too.
        func accountingCheck(_ label:String,finished:Bool=false) {
            guard routeMade else {return}
            let r=route(),d=r.bracketDiagnostics,pending=r.burst.session.pendingUnits
            check(d.balanced(sessionPending:pending) && (!finished || pending == 0),
                  "QF-17 key accounting (\(label)): admitted = saved + dropped + pending\(finished ? ", pending 0" : "") (admitted units \(d.admittedUnits), saved \(d.savedUnits), dropped \(d.dropped), pending \(pending), errors \(d.ledgerErrors))")
        }
        defer {accountingCheck("last scenario")}
        func makeRoute(_ rule:ChromeBracketRule,latencyMs:UInt64=12,focusMs:UInt64=0,recoverQuiet:Bool=false) {
            accountingCheck("scenario before a new route")
            routeMade=true
            timers.removeAll()
            chrome=BracketFakeChrome(url:"https://notes.example.org/pad/7?view=1#top")
            chrome.latency=latencyMs*ms;chrome.focusDelay=focusMs*ms
            chrome.wait={ns in run(until:mono+ns)}
            acquires=0;joinCalls=0;pageCalls=0;joinStarts=[];records=[];typed=[];beforeDeliver=nil;afterDeliver=nil;mainDeliveryDelay=0;readStartDelay=0
            holdDeliveries=false;delayedDeliveries=[];finishExecutorProbe=false;executorChecks=0
            let selectedDesign:ChromeJoinDesign=ProcessInfo.processInfo.environment["QF1_LIFECYCLE_DESIGN"] == "sync" ? .synchronous:.bracketed
            let c=chrome,join=BrowserTypingJoin<WebFakeNode>(design:selectedDesign)
            var env=WebTypingRoute.Environment(now:{mono},wall:{Date()},join:{pid,sites,enabled in
                joinCalls+=1;joinStarts.append(mono)
                if finishExecutorProbe {
                    // Exercise the real adapter's executor guard without AX/AE:
                    // enabled=false must be reached only on its owning main executor.
                    let witness=ChromeTypingWitness(design:.synchronous)
                    var consentChecks=0
                    _=witness.read(pid:pid,enabled:{consentChecks+=1;return false},blockList:sites.blockList,alwaysBlocked:sites.alwaysBlocked)
                    executorChecks+=consentChecks
                    guard consentChecks == 1 else {return .denied(.disabled)}
                    var offMainConsent=0
                    let offMainGroup=DispatchGroup();offMainGroup.enter()
                    DispatchQueue(label:"lifecycle.real-witness.off-main-control").async {
                        _=witness.read(pid:pid,enabled:{offMainConsent+=1;return false},blockList:sites.blockList,alwaysBlocked:sites.alwaysBlocked)
                        offMainGroup.leave()
                    }
                    check(offMainGroup.wait(timeout:.now()+1) == .success,"lifecycle real off-main guard control completes without any AX/AE")
                    check(offMainConsent == 0,"lifecycle real synchronous Witness refuses worker read before consent or AX/AE")
                }
                guard pid == BracketFakeChrome.pid else {return .denied(.untrustedTarget)}
                let r=join.join(environment:c.environment(now:{mono},enabled:enabled),appleEvents:c.ae,accessibility:c.access,
                                blockList:sites.blockList,alwaysBlocked:sites.alwaysBlocked,sites:sites.permits(url:),field:sites.permits(url:field:))
                if let record=r.proof?.bracket {records.append(record)}
                return r
            },pointerJoin:{pid,sites,enabled in
                pageCalls+=1;joinStarts.append(mono)
                guard pid == BracketFakeChrome.pid else {return .denied(.untrustedTarget)}
                return join.join(environment:c.environment(now:{mono},enabled:enabled),appleEvents:c.ae,accessibility:c.access,
                                 blockList:sites.blockList,alwaysBlocked:sites.alwaysBlocked,sites:sites.permits(url:),anyFocus:true)
            },schedule:schedule,secureInput:{c.secure},pressAndHold:{true},secondsSinceMouseDown:{nil},directKeyboardInput:{true})
            env.design = selectedDesign
            env.recoverBracketedBoundaries = recoverQuiet
            env.background={work in
                if finishExecutorProbe {
                    // Test-only executor probe: the real witness refuses before
                    // AX/AE. Production has no synchronous background wait.
                    let group=DispatchGroup();group.enter()
                    DispatchQueue(label:"lifecycle.executor.negative-control").async {work();group.leave()}
                    check(group.wait(timeout:.now()+1) == .success,"lifecycle executor negative control is bounded and performs no AX/AE")
                }
                else {schedule(readStartDelay,work)}
            }
            env.toMain={work in schedule(mainDeliveryDelay) {
                if holdDeliveries {delayedDeliveries.append(work)}
                else {beforeDeliver?();work();afterDeliver?()}
            }}
            env.keyIdentity={_ in c.identity()}
            env.refusedBox={_ in join.refusedBoxRefs(accessibility:c.access)}
            env.latestInput={osInput}
            env.frontmostPID={c.frontmost}
            env.systemFocus={c.systemFocused}
            WebTypingRoute.shared=WebTypingRoute(environment:env)
            WebTypingRoute.shared.engine.rule=rule
        }
        // The store, the coordinator and capture (as the synchronous website checks set them up).
        func setPages(_ on:Bool) throws {var p=try store.policy();p.browserPages=on;p.browserPagesConsentVersion=on ? PrivacySettings.browserPagesConsentCurrent:nil;try store.updatePolicy(p)}
        func typingSwitch(_ on:Bool) throws {var p=try store.policy();p.captureText=on;p.typedConsentVersion=on ? 1:nil;try store.updatePolicy(p);coordinator.captureText=on}
        let pageEnvironment=ChromePageEnvironment(frontmost:{(WebFakeChrome.pid,"com.google.Chrome","99998:1:com.google.Chrome","Google Chrome")},instances:{1},
            secureInput:{false},verify:{_,_ in false},permission:{_ in OSStatus(-1743)},transport:{_ in {_ in nil}},
            background:{$0()},main:{$0()},schedule:{_,_ in},now:{Date()})
        let typing=EventCapture.TypingEnvironment(now:{mono},proof:{_,_ in nil},schedule:schedule,secureInput:{nativeSecure},pressAndHold:{true})
        var capture=EventCapture(coordinator:coordinator,typingEnvironment:typing,pageEnvironment:pageEnvironment)
        func rows() throws -> [Evidence] {
            try store.actions(limit:2000).actions.compactMap {try store.read($0.id)?.evidence}.filter {$0.bundle == "com.google.Chrome" && $0.kind == "keyboard.text_input"}
        }
        /// Words saved since the last call (never printed).
        func newWords() throws -> [String] {
            let fresh=try rows().filter {!seenRows.contains($0.id)}
            for r in fresh {seenRows.insert(r.id)}
            return try fresh.compactMap {try store.hydrateTypedText($0.id,disclosure:.owner)}
        }
        func raw() throws -> String {try store.rows("SELECT body FROM records").compactMap {$0.first}.joined(separator:"\n")}
        func keyAt(_ t:UInt64,_ c:String) {
            at(t) {typed.append((t,c));osInput=max(osInput,t);capture.handleNativeKey(eventAt:t,keyCode:0,shortcut:false) {acquires+=1;return c}}
        }
        func strokeAt(_ t:UInt64,_ s:KeyStroke) {at(t) {osInput=max(osInput,t);capture.handleNativeKey(eventAt:t,stroke:s) {acquires+=1;return ""}}}
        @discardableResult func typeRun(_ text:String,from t0:UInt64,every:UInt64) -> UInt64 {
            for (i,ch) in text.enumerated() {keyAt(t0+UInt64(i)*every,String(ch))}
            return t0+UInt64(text.count)*every
        }
        func diag() -> [String:Double] {route().bracketDiagnostics.snapshot()}
        /// The bracket the rule gives a key typed at t, from the verified reads this scenario recorded (an independent
        /// mirror of B1 + rev 3.1: per-fact containment, reply < t < send, and each fact's span <= 150 ms).
        func bracketOf(_ t:UInt64,_ rule:ChromeBracketRule) -> (lo:Int,hi:Int)? {
            var lo=Int.max,hi = -1
            switch rule {
            case .wholeRead:
                guard let ia=records.lastIndex(where:{$0.end<t}),let ib=records.firstIndex(where:{$0.start>t}) else {return nil}
                for f in (records.last?.facts ?? ChromeFact.allCases) {
                    guard let x=records[ia].times[f]?.last,let y=records[ib].times[f]?.first,y.received>=x.sent,y.received-x.sent<=ChromeBracketTiming.spanNanoseconds else {return nil}
                }
                return (ia,ib)
            case .perFact:
                for f in (records.last?.facts ?? ChromeFact.allCases) {
                    guard let ia=records.lastIndex(where:{$0.times[f]?.contains {$0.received<t} ?? false}),
                          let ib=records.firstIndex(where:{$0.times[f]?.contains {$0.sent>t} ?? false}),
                          let x=records[ia].times[f]?.last(where:{$0.received<t}),let y=records[ib].times[f]?.first(where:{$0.sent>t}),
                          y.received>=x.sent,y.received-x.sent<=ChromeBracketTiming.spanNanoseconds else {return nil}
                    lo=min(lo,ia);hi=max(hi,ib)
                }
                return (lo,hi)
            }
        }
        /// Typed times of every saved character (letters are unique within a scenario's typed text).
        func savedTimes(_ words:[String]) -> [UInt64] {
            words.flatMap {w in w.compactMap {ch in typed.first {$0.c == String(ch)}?.t}}
        }
        func joinedAcross(_ words:[String],_ a:String,_ b:String) -> Bool {
            words.contains {w in w.contains {a.contains($0)} && w.contains {b.contains($0)}}
        }
        func prime() -> UInt64 {let t=mono+10*ms;keyAt(t,"!");return t}

        try coordinator.start()
        try typingSwitch(true)
        try setPages(true)
        capture.switchFrontmost(pid:WebFakeChrome.pid,bundle:"com.google.Chrome") {_,_ in}
        _=try newWords()

        if ProcessInfo.processInfo.environment["Q4_SETTLE_ONLY"] == "1" {
            ChromeReadShape.current = .lean
            for rule in [ChromeBracketRule.wholeRead,.perFact] {
                makeRoute(rule,latencyMs:3)
                let warmAt=mono+500*ms
                var guardedBeforeSettle=false,armed=false
                afterDeliver={
                    guard !armed,mono>=warmAt else {return}
                    armed=true;afterDeliver=nil
                    let key=mono+1*ms
                    keyAt(key,"v")
                    at(key) {chrome.windows[0].url="https://notes.example.org/pad/7#/checkout"}
                    at(key+40*ms) {
                        route().pump()
                        guardedBeforeSettle = route().held.count == 1 && route().bracketDiagnostics.admittedUnits == 0
                    }
                    at(key+60*ms) {chrome.web.url=chrome.windows[0].url}
                }
                _=prime();run(until:mono+6_000*ms)
                let words=try newWords()
                check(armed && acquires == 1 && guardedBeforeSettle,
                      "Q-4 route (\(rule)): stale AX hash URL never admits the acquired key before inclusive 60 ms floor")
                check(words.isEmpty && route().held.allZero && route().held.count == 0 && route().bracketDiagnostics.admittedUnits == 0,
                      "Q-4 route (\(rule)): fresh blocked hash cancels held bytes, zero admitted/saved rows")
                accountingCheck("Q-4 blocked route",finished:true)
            }
            ChromeReadShape.current = .full;return
        }

        if ProcessInfo.processInfo.environment["PENDING_READ_ONLY"] == "1" {
            for deliveryDelay in [0.2, 1.2] {
            for rule in [ChromeBracketRule.wholeRead, .perFact] {
                makeRoute(rule,latencyMs:3)
                readStartDelay=0.065
                var deliveries=0, waitingWhileDelayed=false
                let warmAt=mono+500*ms
                afterDeliver={
                    if deliveries == 0 && mono >= warmAt {
                        deliveries=1
                        mainDeliveryDelay=deliveryDelay
                        keyAt(mono+1*ms,"v")
                        at(mono+180*ms) {
                            route().pump()
                            waitingWhileDelayed = route().held.count == 1 && route().bracketDiagnostics.admittedUnits == 0
                        }
                        if deliveryDelay > 1 {at(mono+1_002*ms) {route().pump()}}
                    } else if deliveries == 1 {deliveries=2;mainDeliveryDelay=0;afterDeliver=nil}
                }
                // Start the full-read loop without a fabricated key needing an a-side.
                _=prime()
                run(until:mono+6_000*ms)
                let words=try newWords(), d=diag()
                check(waitingWhileDelayed,"pending-read route (\(rule)): late main delivery keeps the key unreadmitted and held beyond 150 ms")
                if deliveryDelay < 1 {
                    check(words == ["v"] && d["keys.admitted"] == 1 && d["keys.saved"] == 1 && d["keys.lost"] == 0,
                          "pending-read route (\(rule)): actual timely facts save exactly the held key after delayed delivery")
                } else {
                    check(words.isEmpty && route().held.allZero && route().held.count == 0
                          && d["keys.admitted"] == 0 && d["keys.saved"] == 0 && d["keys.lost"] == 1,
                          "pending-read route (\(rule)): independent 1 s hold cap wipes delayed key, zero saved even with timely facts")
                }
                check(savedTimes(words).allSatisfy {bracketOf($0,rule) != nil},
                      "pending-read route (\(rule)): saved key independently meets unchanged containment/span")
                accountingCheck("pending delivery",finished:true)
            }
            }
            ChromeReadShape.current = .full;return
        }

        // Codex recorder QA: one isolated scenario per process, using production EventCapture,
        // route proofs and sealed storage. No OS event injection or personal store access.
        if ProcessInfo.processInfo.environment["QF1_LIFECYCLE_ONLY"] != nil {
            let selected=ProcessInfo.processInfo.environment["QF1_LIFECYCLE_CASE"] ?? "completed"
            let queuedCases=["queuedSubmit","queuedSubmitMoved","queuedSave","queuedIdle","queuedSettle","queuedClick","queuedSaveRevoke","queuedIdleSecure","queuedSettleSleep"]
            check((["completed","stop","pause","suspend","timeout","revoke","secure","sleepDrain","restart","newInput","tapFault","pointer","ax","focusReturn","policy","parkedStop","repeatStop","secureRequest","syncExecutor","deferredAutoSplit","stoppedCompletion","finishTitle"]+queuedCases).contains(selected),"lifecycle: recognized focused case")
            makeRoute(.perFact,latencyMs:3)
            check(!route().burst.recoverBracketedBoundaries,"lifecycle: boundary recovery remains default OFF")
            makeRoute(.perFact,latencyMs:3,recoverQuiet:true)
            let boundaryAt=prime()+200*ms
            strokeAt(boundaryAt,KeyStroke(keyCode:36))
            // The synchronous cold primer is itself recorded on Return; it is
            // setup, not part of the measured pending draft. Bracketed intake
            // refuses that cold primer. Consume its rows before measurement.
            if route().environment.design == .synchronous {at(boundaryAt+300*ms) {_ = try! newWords()}}
            let initial="abcdefghijklmnopqrstuvwx"
            let end=typeRun(initial,from:boundaryAt+(ProcessInfo.processInfo.environment["QF1_LIFECYCLE_DESIGN"] == "sync" ? 500:100)*ms,every:80*ms)
            var pendingBefore=false,admittedBefore=0,interrupted=false,finishCompletions=0
            var acquiresAtCutoff=0
            if queuedCases.contains(selected) {
                let queueAt=end+(selected.hasPrefix("queuedSettle") ? 450:40)*ms
                at(end+40*ms) {
                    holdDeliveries=true
                    if selected.hasPrefix("queuedSettle") {route().burst.boundary(.focusKey,at:mono,now:mono,focusMoved:true)}
                }
                at(queueAt) {
                    let kind:WebTypingRoute.Op.Kind=selected.hasPrefix("queuedSubmit") ? .save(.submit)
                        :selected.hasPrefix("queuedSave") ? .save(.paste)
                        :selected.hasPrefix("queuedIdle") ? .idle:selected.hasPrefix("queuedSettle") ? .settle:.click(.pointer)
                    route().enqueue(WebTypingRoute.Op(kind,at:mono))
                    check(!route().ops.isEmpty,"lifecycle queued operation waits for a genuinely delayed fresh result")
                }
            }
            if selected == "parkedStop" {strokeAt(end+40*ms,KeyStroke(keyCode:48))}
            if selected != "completed" {
                at(end+(selected.hasPrefix("queuedSettle") ? 460:50)*ms) {
                    pendingBefore=route().burst.session.hasLive || route().burst.session.parkedCount > 0
                    admittedBefore=route().environment.design == .synchronous ? initial.count:Int(diag()["keys.admitted"] ?? -1)
                    acquiresAtCutoff=acquires
                    interrupted=true
                    if selected == "deferredAutoSplit" {
                        // Transaction control using allowed fixture reads;
                        // this does not claim a live key or OS event.
                        let ps=route().proofs.values.sorted {$0.checkedAt < $1.checkedAt}
                        check(ps.count >= 2,"lifecycle automatic-part control has real fixture proofs")
                        let pa=ps[ps.count-2],pb=ps[ps.count-1],t=pa.checkedAt+(pb.checkedAt-pa.checkedAt)/2
                        var small=WebTypingRoute.limits;small.maxCharacters=8
                        let policy=try! coordinator.captureBinding.context().policy
                        let deferred=BrowserTypingBurst(sites:route().burst.sites,limits:small);deferred.bracketed=true
                        var writes=0,words="",reason:SealReason?=nil
                        _=try! deferred.bracketedKey(.insertText("abcdefgh"),ra:pa,rb:pb,typedAt:t,now:mono,policy:policy,deferCommit:true) {_ in writes+=1;return false}
                        check(writes == 0 && deferred.session.pendingUnits == 1 && deferred.session.parkedCount == 1,
                              "lifecycle pre-cutoff automatic size part parks without consuming a suppressed write")
                        _=try! deferred.resolveParked(.allowed(pb),secureInput:false,now:mono,policy:policy,force:true) {c in words=c.text;reason=c.reason;return true}
                        check(words == "abcdefgh" && reason == .size && deferred.session.pendingUnits == 0,
                              "lifecycle deferred automatic part preserves exact text and original size reason")
                        for text in ["abcdefghijklmnopqrst", "éééééééééé"] {
                            var caps=small;caps.maxBytes=8
                            let parts=BrowserTypingBurst(sites:route().burst.sites,limits:caps);parts.bracketed=true
                            var commits:[TypingCommit]=[]
                            _=try! parts.bracketedKey(.insertText(text),ra:pa,rb:pb,typedAt:t,now:mono,policy:policy,deferCommit:true) {_ in writes+=1;return false}
                            _=try! parts.resolveParked(.allowed(pb),secureInput:false,now:mono,policy:policy,force:true) {commits.append($0);return true}
                            for _ in 0...caps.maxParked {
                                guard parts.session.hasLive else {break}
                                _=try! parts.commit(.allowed(pb),typedAt:nil,processedAt:mono,reason:parts.session.liveAtCap ? .size:.suspend,policy:policy) {commits.append($0);return true}
                            }
                            check(commits.map(\.text).joined() == text && commits.allSatisfy {$0.text.count<=caps.maxCharacters && $0.text.utf8.count<=caps.maxBytes},
                                  "lifecycle deferred overflow preserves exact characters and UTF8 caps")
                            check(commits.count>=2 && Set(commits.map(\.runID)).count == 1 && commits.map(\.part) == Array(commits.first!.part..<(commits.first!.part+commits.count)),
                                  "lifecycle deferred overflow preserves run identity and ordered part numbers")
                        }
                        let control=BrowserTypingBurst(sites:route().burst.sites,limits:small);control.bracketed=true
                        _=try! control.bracketedKey(.insertText("abcdefgh"),ra:pa,rb:pb,typedAt:t,now:mono,policy:policy) {_ in writes+=1;return false}
                        check(writes == 1 && control.session.pendingUnits == 0,
                              "lifecycle negative control: ordinary automatic commit consumes its part when writer refuses")
                    }
                    if selected == "suspend" {capture.handleSuspension()}
                    else {
                        // Same ordering as the app's user Stop and ordinary pause paths:
                        // drain pending typing while recording is still on, then stop/pause.
                        if selected == "secureRequest" {nativeSecure=true;chrome.secure=true}
                        if selected == "timeout" {chrome.stallAt=chrome.appleEvents+1;chrome.stall=2_000*ms}
                        if selected == "syncExecutor" {finishExecutorProbe=true}
                        if selected == "queuedSubmitMoved" {
                            let other=WebFakeNode("finish-other-box",role:"AXTextArea",parent:WebFakeNode("finish-other-group",role:"AXGroup",parent:chrome.web))
                            other.labels=chrome.field.labels;chrome.focus=other
                        }
                        if selected == "finishTitle" {chrome.window.title="QA Previous Draft - Google Chrome";chrome.windows[0].name="QA Previous Draft"}
                        if queuedCases.contains(selected) {
                            at(mono+ms) {
                                if selected == "queuedSaveRevoke" {permitted=false}
                                if selected == "queuedIdleSecure" {chrome.secure=true}
                                if selected == "queuedSettleSleep" {capture.handleSuspension()}
                                holdDeliveries=false
                                let waiting=delayedDeliveries;delayedDeliveries=[]
                                for work in waiting {work()}
                                check((try! newWords()).isEmpty,"lifecycle old delayed result cannot authorize a finish-period write before the cutoff-fresh read")
                            }
                        }
                        if ["revoke","secure","sleepDrain","restart","newInput","tapFault","pointer","ax","focusReturn","policy"].contains(selected) {
                            at(mono+ms) {
                                if selected == "revoke" {permitted=false}
                                if selected == "secure" {chrome.secure=true}
                                if selected == "policy" {try! typingSwitch(false)}
                                if selected == "newInput" {capture.handleNativeKey(eventAt:mono,keyCode:0,shortcut:false) {acquires+=1;return "Z"}}
                                if selected == "tapFault" {capture.tapEventForChecks(.tapDisabledByTimeout,CGEvent(source:nil)!)}
                                if selected == "pointer" {capture.handlePointerDown(eventAt:mono)}
                                if selected == "ax" {capture.handleAX(kAXTitleChangedNotification)}
                                if selected == "focusReturn" {
                                    capture.switchFrontmost(pid:12345,bundle:"com.apple.TextEdit") {_,_ in check(false,"lifecycle: no observer during cutoff")}
                                    capture.switchFrontmost(pid:WebFakeChrome.pid,bundle:"com.google.Chrome") {_,_ in check(false,"lifecycle: no observer during cutoff")}
                                }
                                if selected == "sleepDrain" {capture.handleSuspension()}
                                if selected == "restart" {
                                    capture.stop(reason:"Synthetic replacement cancels drain")
                                    try! coordinator.start()
                                    capture=EventCapture(coordinator:coordinator,typingEnvironment:typing,pageEnvironment:pageEnvironment)
                                    coordinator.stop()
                                }
                            }
                        }
                        if selected == "repeatStop" {capture.finishPendingTyping {check(false,"lifecycle repeat Stop: obsolete transition is not called")}}
                        capture.finishPendingTyping {
                            finishCompletions+=1
                            if selected == "stop" || selected == "parkedStop" || selected == "repeatStop" {coordinator.stop();capture.stop(reason:"Synthetic user stop")}
                            else {coordinator.pause("Synthetic user pause");capture.stop(reason:"Synthetic user pause")}
                        }

                    }
                }
            }
            run(until:end+6_000*ms)
            if selected != "completed" && selected != "suspend" {
                check(acquires == acquiresAtCutoff,"lifecycle \(selected): intake freezes at the ordinary cutoff")
                check(finishCompletions == (["sleepDrain","restart","queuedSettleSleep"].contains(selected) ? 0:1),
                      "lifecycle \(selected): finish completes exactly once, or cancellation invalidates its old capture token")
                check(route().ops.isEmpty && route().held.allZero,"lifecycle \(selected): finish clears queued operations and held bytes")
            }
            let initialWords=try newWords()
            let initialSaved=initialWords.joined()
            if selected == "stoppedCompletion" {
                let readsBefore=joinCalls+pageCalls,rowsBefore=try rows().count
                var done=0
                capture.finishPendingTyping {done+=1}
                let rowsAfter=try rows().count
                check(done == 1 && joinCalls+pageCalls == readsBefore && rowsAfter == rowsBefore,
                      "lifecycle already-stopped finish completes once without any proof read or write")
            }
            if ["queuedSave","queuedIdle","queuedSettle","queuedClick"].contains(selected) {
                let expected:SealReason=selected == "queuedSave" ? .paste:selected == "queuedIdle" ? .idle:selected == "queuedSettle" ? .focusKey:.pointer
                let saved=try rows().filter {try store.hydrateTypedText($0.id,disclosure:.owner) == initial}
                check(saved.count == 1 && saved.first?.captureProvenance?.unit?.sealReason == expected.rawValue,
                      "lifecycle queued operation preserves original part reason and writes once")
            }
            if selected.hasPrefix("queuedSubmit") {
                let saved=try rows().filter {try store.hydrateTypedText($0.id,disclosure:.owner) == initial}
                check(saved.count == 1 && saved.first?.captureProvenance?.unit?.sealReason == SealReason.focusKey.rawValue
                      && saved.first?.captureProvenance?.unit?.send != "detected" && saved.first?.captureProvenance?.unit?.sendBy == nil,
                      "lifecycle queued Return preserves draft after safe field departure without creating a submit claim")
            }
            if selected == "syncExecutor" {check(executorChecks == 1,"lifecycle sync finish reaches real Witness consent guard on main; off-main negative control refuses before consent")}
            if selected == "finishTitle" {
                let saved=try rows().filter {try store.hydrateTypedText($0.id,disclosure:.owner) == initial}
                check(saved.count == 1 && saved.first?.title == "notes.example.org",
                      "lifecycle direct synchronous finish uses cutoff-settled site-only title on the stored row")
            }
            print("LIFECYCLE result: case=\(selected) design=\(route().environment.design) saved=\(initialSaved.count) acquires=\(acquires)")
            if selected == "completed" {
                check(initialSaved == initial,"lifecycle completed: recovered Chrome characters save exactly once")
                check(route().environment.design == .synchronous || savedTimes(initialWords).allSatisfy {bracketOf($0,.perFact) != nil},
                      "lifecycle completed: every saved character has an independent bracket")
            } else {
                check(interrupted && pendingBefore && admittedBefore == initial.count,
                      "lifecycle \(selected): control has a fully admitted live Chrome unit before interruption")
                check(!coordinator.isRunning,"lifecycle \(selected): recording stays off without explicit resume")
                permitted=true;nativeSecure=false;chrome.secure=false;chrome.stallAt=nil;chrome.stall=0
                let beforePausedRows=try rows().count,priorAcquires=acquires
                keyAt(mono+10*ms,"Z")
                advance(1)
                let afterPausedRows=try rows().count
                check(acquires == priorAcquires && afterPausedRows == beforePausedRows,
                      "lifecycle \(selected): paused keys read nothing and stale callbacks write nothing")
                check(route().held.allZero && !route().burst.session.hasLive,
                      "lifecycle \(selected): outstanding Chrome buffers clear after interruption")
                try typingSwitch(true)
                try coordinator.start()
                capture=EventCapture(coordinator:coordinator,typingEnvironment:typing,pageEnvironment:pageEnvironment)
                capture.switchFrontmost(pid:WebFakeChrome.pid,bundle:"com.google.Chrome") {_,_ in}
                makeRoute(.perFact,latencyMs:3,recoverQuiet:true)
                let resumeBoundary=prime()+200*ms
                strokeAt(resumeBoundary,KeyStroke(keyCode:36))
                if route().environment.design == .synchronous {at(resumeBoundary+300*ms) {_ = try! newWords()}}
                let resumed="yzabcdefghijklmnopqrstuv"
                let resumeEnd=typeRun(resumed,from:resumeBoundary+(ProcessInfo.processInfo.environment["QF1_LIFECYCLE_DESIGN"] == "sync" ? 500:100)*ms,every:80*ms)
                run(until:resumeEnd+6_000*ms)
                let resumedWords=try newWords()
                print("LIFECYCLE resume result: case=\(selected) saved=\(resumedWords.joined().count) acquires=\(acquires)")
                check(resumedWords.joined() == resumed,
                      "lifecycle \(selected): explicit resume records a new complete unit without bridging old pending text")
                if ["stop","pause","parkedStop","repeatStop"].contains(selected) {
                    let savedRows=try rows()
                    let initialIDs=try savedRows.filter {try store.hydrateTypedText($0.id,disclosure:.owner) == initial}.compactMap {$0.captureProvenance?.unit?.runID}
                    let resumedIDs=try savedRows.filter {try store.hydrateTypedText($0.id,disclosure:.owner) == resumed}.compactMap {$0.captureProvenance?.unit?.runID}
                    check(!initialIDs.isEmpty && !resumedIDs.isEmpty && Set(initialIDs).isDisjoint(with:Set(resumedIDs)),
                          "lifecycle \(selected): resume preserves separate run IDs instead of merging drafts by time")
                }
                accountingCheck("lifecycle \(selected) resumed",finished:true)
                print("LIFECYCLE FINDING: case=\(selected) admittedBefore=\(admittedBefore) savedBefore=\(initialSaved.count) resumedSaved=\(resumedWords.joined().count)")
                if ["suspend","timeout","revoke","secure","sleepDrain","restart","newInput","tapFault","pointer","ax","focusReturn","policy","secureRequest","queuedSaveRevoke","queuedIdleSecure","queuedSettleSleep"].contains(selected) {
                    check(initialSaved.isEmpty,"lifecycle \(selected): canceled, expired or suspended drain saves no pending text")
                } else {
                    check(initialSaved == initial,
                          "lifecycle \(selected): ordinary interruption preserves the admitted pending Chrome unit")
                }
            }
            let finalRows=try rows()
            var hydrated:[String:String]=[:],serialized:[String:String]=[:]
            for row in finalRows {
                guard let words=try store.hydrateTypedText(row.id,disclosure:.owner) else {
                    check(false,"lifecycle: every Chrome row hydrates before reopen");continue
                }
                hydrated[row.id]=words;serialized[row.id]=try json(row)
            }
            check(!finalRows.isEmpty && Set(finalRows.map(\.id)).count == finalRows.count,
                  "lifecycle: saved Chrome row identities are unique before reopen")
            chromeLifecycleSnapshot=ChromeLifecycleSnapshot(keys:chromeVaultKeys,serialized:serialized,words:hydrated)
            route().drop(.focus)
            coordinator.stop()
            timers.removeAll()
            installFakeWebRoute()
            return
        }

        // Codex QF-1: compare real EventCapture -> route -> isolated store
        // before and after the opt-in. No OS events or content in diagnostics.
        for rule in [ChromeBracketRule.wholeRead, .perFact] {
            for boundary in ["return", "tab", "click", "paste"] {
                for recover in [false, true] {
                    // Lean's two-event read must clear the existing 5 ms scheduler
                    // floor. Sub-5 ms success backoff is a separate recorded finding.
                    makeRoute(rule,latencyMs:3,recoverQuiet:recover)
                    let boundaryAt=prime()+200*ms
                    if boundary == "click" {
                        at(boundaryAt) {osInput=max(osInput,boundaryAt);route().pointerDown(at:boundaryAt)}
                    } else {
                        let code:Int64=boundary == "return" ? 36 : boundary == "tab" ? 48 : 9
                        strokeAt(boundaryAt,KeyStroke(keyCode:code,command:boundary == "paste"))
                    }
                    let text="abcdefghijklmnopqrstuvwx"
                    let end=typeRun(text,from:boundaryAt+100*ms,every:80*ms)
                    run(until:end+6_000*ms)
                    let words=try newWords()
                    let saved=words.joined()
                    if recover {
                        if saved != text {
                            let d=route().bracketDiagnostics.snapshot()
                            print("QF1 TEST FINDING: shape=\(ChromeReadShape.current) rule=\(rule) boundary=\(boundary) joins=\(joinCalls) verified=\(d["reads.verified"] ?? -1) denied=\(d["reads.denied"] ?? -1) admitted=\(d["keys.admitted"] ?? -1) saved=\(d["keys.saved"] ?? -1) lost=\(d["keys.lost"] ?? -1) quiet=\(route().burst.recoversBracketedQuiet)")
                        }
                        check(saved == text,"QF-1 (\(rule), \(boundary)): every early character saved after verified boundary recovery")
                        check(savedTimes(words).allSatisfy {bracketOf($0,rule) != nil},
                              "QF-1 (\(rule), \(boundary)): all saved characters retain independent bracket containment")
                    } else {
                        check(!saved.hasPrefix("abcd"),"QF-1 baseline (\(rule), \(boundary)): 400 ms wait loses the prefix")
                    }
                    accountingCheck("QF-1 \(rule) \(boundary) recovery=\(recover)",finished:true)
                }
            }
        }

        if ProcessInfo.processInfo.environment["QF1_BOUNDARY_ONLY"] != nil {
            print("\(checks) QF-1 boundary route checks passed.")
            return
        }

        // ---- Positive control + R6 + the aggregate numbers (both rules, 12 and 23 ms per event).
        let alphabet="abcdefghijklmnopqrstuvwxyz"
        // The last three rows: the silent-loss repro (b+ on 939e6df), each read's opening focus check takes 4 ms (reads
        // of about 32 ms in the lean shape, as b+ measured on real Chrome).
        for (lat,rule,pace,focus) in [(UInt64(12),ChromeBracketRule.perFact,UInt64(80),UInt64(0)),(12,.perFact,40,0),(12,.wholeRead,80,0),(12,.wholeRead,40,0),
                                      (23,.perFact,80,0),(23,.wholeRead,80,0),(12,.perFact,80,4),(12,.perFact,40,4),(12,.wholeRead,80,4)] {
            makeRoute(rule,latencyMs:lat,focusMs:focus)
            var savedChars=0,typedKeys=0,contained=true,wordsSaved=0
            for _ in 0..<3 {
                typed=[];let s0=prime()+200*ms
                let end=typeRun(alphabet,from:s0,every:pace*ms);typedKeys+=alphabet.count
                run(until:end+6_000*ms)
                let w=try newWords();wordsSaved+=w.count
                let times=savedTimes(w);savedChars+=times.count
                if ProcessInfo.processInfo.environment["QF17_DEBUG"] != nil {
                    // Aggregate only: how many typed keys the recorded verified reads could bracket under this rule
                    // (the mirror), how many were read at intake, and the engine's boundaries in the segment.
                    let keyTimes=typed.filter {alphabet.contains($0.c)}.map(\.t)
                    let bracketable=keyTimes.filter {bracketOf($0,rule) != nil}.count
                    let inSegment=route().engine.boundaries.filter {$0 >= s0 && $0 <= end}.count
                    print("QF17 DEBUG rule=\(rule) ae=\(lat) pace=\(pace): keys=\(keyTimes.count) bracketable(mirror)=\(bracketable) saved=\(times.count) acquires=\(acquires) boundariesInSegment=\(inSegment) ops=\(route().ops.count)")
                }
                contained=contained && times.allSatisfy {bracketOf($0,rule) != nil}
            }
            let d=diag()
            accountingCheck("\(rule), \(lat) ms/event, \(pace) ms/key, focus \(focus) ms",finished:true)
            if focus > 0 && rule == .perFact && ChromeReadShape.current == .lean {
                // The fix: a key typed in a read's opening observation is admitted, so nothing admitted is retracted.
                check((d["keys.lost.admission"] ?? -1) == 0 && (route().bracketDiagnostics.droppedByReason[.retract] ?? 0) == 0 && (d["keys.saved"] ?? 0) + (d["keys.dropped"] ?? 0) == (d["keys.admitted"] ?? -1),
                      "QF-17 silent loss (perFact, focus check 4 ms, \(pace) ms/key): no admission recheck refuses, nothing admitted is retracted, saved + dropped = admitted")
            }
            print("QF17 METRIC route rule=\(rule) ae=\(lat)ms\(focus > 0 ? " focus=\(focus)ms" : "") pace=\(pace)ms typed=\(typedKeys) admitted=\(Int(d["keys.admitted"] ?? -1)) lost=\(Int(d["keys.lost"] ?? -1)) saved=\(savedChars) units=\(wordsSaved) reads.verified=\(Int(d["reads.verified"] ?? -1)) reads.denied=\(Int(d["reads.denied"] ?? -1)) joins=\(joinCalls) read.ms.p50=\(d["read.ms.p50"] ?? -1) intake.us.p95=\(d["intake.us.p95"] ?? -1) keys.saved=\(Int(d["keys.saved"] ?? -1)) keys.dropped=\(Int(d["keys.dropped"] ?? -1)) (inside: retract \(route().bracketDiagnostics.droppedByReason[.retract] ?? 0), save \(route().bracketDiagnostics.droppedByReason[.save] ?? 0), privacy \(route().bracketDiagnostics.droppedByReason[.privacy] ?? 0), departure \(route().bracketDiagnostics.droppedByReason[.departure] ?? 0), empty \(route().bracketDiagnostics.droppedByReason[.empty] ?? 0), capacity \(route().bracketDiagnostics.droppedByReason[.capacity] ?? 0)) lost.admission=\(Int(d["keys.lost.admission"] ?? -1)) keys.pending=\(Int(d["keys.pending"] ?? -1))")
            check(contained,"QF-17 R6 (\(rule), \(lat) ms/event, \(pace) ms/key): every saved key lies inside a verified bracket (per-fact containment, span <= 150 ms)")
            if lat == 12 && rule == .perFact && pace == 80 && focus == 0 {
                expectSource(savedChars > 0 && (d["keys.admitted"] ?? 0) > 0,"QF-17 positive control: 12 ms/event, per-fact rule: steady typing admits and saves keys")
            }
            if lat == 23 && ChromeReadShape.current == .full {
                check(savedChars == 0,"QF-17 (\(rule)) 23 ms/event: a 7-event read is over the 150 ms read budget: nothing is admitted (measured infeasibility)")
            }
        }
        // ---- Round-2 lean conditions L1, L3, L4 (run in the default full shape, and in the lean prototype with
        //      QF17_SHAPE=lean). No window notification is fired in these rows: the worst case, where Chrome's
        //      notification is late or missing.
        let shapeName=ChromeReadShape.current == .lean ? "lean prototype" : "full shape"
        let rowLatencies:[UInt64]=ChromeReadShape.current == .lean ? [12,23] : [12]
        // L3: a short-lived Incognito window. (a) It takes focus, takes keys, and closes before the next read: the
        //     key-time identity (its AXWindow and focus refs) differs from the reads', so none of its keys is read.
        //     (b) It opens in the background while typing continues in the normal window: a read that sees it is
        //     refused at the mode gate (no content read); keys to the normal window are kept only between two reads
        //     that both saw the normal window only.
        for lat in rowLatencies {
            for rule in [ChromeBracketRule.perFact,.wholeRead] {
                for focused in [true,false] {
                    makeRoute(rule,latencyMs:lat)
                    let s0=prime()+200*ms,a="abcdefgh",inc="mnop",b="qrstuvwx"
                    // The text before is typed and left idle (saved by the idle seal) before the window opens; the text
                    // after starts once the quiet period and refusal hold after the refused reads are over.
                    let open=typeRun(a,from:s0,every:40*ms)+7_000*ms
                    if ProcessInfo.processInfo.environment["QF17_DEBUG"] != nil {at(open-1) {print("QF17 DEBUG L3 before open: rows=\((try? rows().count) ?? -1) admitted=\(diag()["keys.admitted"] ?? -1)")}}
                    let incNode=WebFakeNode("window-303",role:"AXWindow",subrole:"AXStandardWindow")
                    incNode.frame=ChromeBounds(left:200,top:100,right:1000,bottom:700);incNode.title="New Incognito Tab"
                    let incField=WebFakeNode("inc-field",role:"AXTextField",parent:WebFakeNode("inc-web",role:"AXWebArea",parent:WebFakeNode("inc-scroll",role:"AXScrollArea",parent:incNode)))
                    var readsWhileOpen=0,verifiedWhileOpen=0,openAt:UInt64=0,closeAt:UInt64=0
                    at(open) {
                        openAt=mono
                        chrome.windows.insert(BracketFakeChrome.Window(id:"303",mode:"incognito",bounds:incNode.frame!,name:"New Incognito Tab",tab:"9303",url:"https://private.example.net/secret"),at:focused ? 0:chrome.windows.count)
                        chrome.axWindows.append(incNode)
                        if focused {chrome.focusedWindow=incNode;chrome.focus=incField}
                        readsWhileOpen=joinCalls;verifiedWhileOpen=records.count
                    }
                    // Its keys (unique letters), 20 ms apart; it closes 30 ms after the last one.
                    typeRun(inc,from:open+10*ms,every:20*ms)
                    let close=open+10*ms+UInt64(inc.count)*20*ms+30*ms
                    at(close) {
                        closeAt=mono
                        chrome.removeWindow("303");chrome.focusedWindow=chrome.window;chrome.focus=nil
                        readsWhileOpen=joinCalls-readsWhileOpen;verifiedWhileOpen=records.count-verifiedWhileOpen
                    }
                    run(until:typeRun(b,from:close+1_500*ms,every:40*ms)+7_000*ms)
                    let w=try newWords()
                    let saved=savedTimes(w)
                    let incSaved=w.contains {$0.contains {inc.contains($0)}}
                    let during=saved.filter {$0 > openAt && $0 < closeAt}.count
                    let tag="\(shapeName), \(rule), \(lat) ms/event"
                    if ProcessInfo.processInfo.environment["QF17_DEBUG"] != nil {
                        print("QF17 DEBUG L3: acquires=\(acquires) typed=\(typed.count) actions=\(try store.actions(limit:100000).actions.count) rows=\(try rows().count) diag=\(diag()) cd=\(CaptureDiagnostics.shared.snapshot())")
                    }
                    print("QF17 METRIC L3 \(focused ? "focused":"background") incognito (\(tag)): window open \((closeAt-openAt)/ms) ms, reads started while open=\(readsWhileOpen) verified=\(verifiedWhileOpen), normal keys saved=\(saved.count) of \(a.count+b.count+(focused ? 0:inc.count)), saved while open=\(during)")
                    if focused {
                        check(!incSaved && !joinedAcross(w,a,b) && (ChromeReadShape.current == .full || saved.count > 0),"QF-17 L3 (\(tag)): no key typed into a short-lived focused Incognito window (closed before the next read) is saved; text before and after it is never one unit")
                    } else {
                        // Background: its letters went to the normal window. Any key saved while it was open lies between
                        // two verified reads that listed no Incognito window (every verified read passed the mode gate).
                        let sawIt=records.filter {r in r.times[.modes]?.contains {$0.sent > openAt && $0.received < closeAt} ?? false}.count
                        check(sawIt == 0 && saved.allSatisfy {t in bracketOf(t,rule) != nil} && (ChromeReadShape.current == .full || saved.count > 0),
                              "QF-17 L3 (\(tag)): with a short-lived background Incognito window, no read whose mode event ran while it was open verified, and every saved key lies inside a verified bracket")
                    }
                }
            }
        }
        // L1: three tabs on the same URL with the same field, switched at random between and during reads (no
        //     notification). Each tab types its own letters. A saved unit never mixes tabs, and every saved key lies
        //     between reads whose focus ref is that tab's field. Seeded, so the run is reproducible.
        for lat in rowLatencies {
            for rule in [ChromeBracketRule.perFact,.wholeRead] {
                makeRoute(rule,latencyMs:lat)
                let url="https://notes.example.org/pad/7?view=1#top"
                let scroll=chrome.web.parent!
                var webs=[chrome.web],fields=[chrome.field]
                for i in 1...2 {
                    let web=WebFakeNode("web-\(i)",role:"AXWebArea");web.url=url
                    webs.append(web);fields.append(WebFakeNode("field-\(i)",role:"AXTextArea",parent:WebFakeNode("group-\(i)",role:"AXGroup",parent:web)))
                }
                for f in fields {f.labels=chrome.field.labels}
                let alphabets=["abcdefgh","ijklmnop","qrstuvwx"]
                var tab=0,truth:[(t:UInt64,tab:Int)]=[],seed:UInt64=0x5eed_0f_17
                func rnd(_ n:UInt64) -> UInt64 {seed=seed &* 6364136223846793005 &+ 1442695040888963407;return (seed >> 33) % n}
                func switchTo(_ i:Int) {
                    webs[tab].parent=nil;webs[i].parent=scroll;tab=i
                    chrome.focus=fields[i];chrome.windows[0].tab=String(7+i)
                }
                // 30 segments: a burst of 6-16 keys in the current tab, then either a 7.5 s pause (the unit is saved) or
                // none; then a switch to another tab at a random nanosecond offset (it lands during reads as often as
                // between them), or, every third segment, in the middle of the next burst.
                let s0=prime()+200*ms
                var t=s0,switches=0
                for seg in 0..<30 {
                    let n=6+Int(rnd(11)),midBurst=seg % 3 == 2
                    for k in 0..<n {
                        if midBurst && k == n/2 {
                            let to=(tab+1+Int(rnd(2)))%3,when=t+UInt64(rnd(30_000_000))
                            at(when) {switchTo(to)};switches+=1;tab=to;t=when+UInt64(20+rnd(40))*ms
                        }
                        let kt=t;truth.append((kt,tab))
                        keyAt(kt,k % 6 == 5 ? " " : String(Array(alphabets[tab])[Int(rnd(8))]))
                        t+=UInt64(35+rnd(30))*ms
                    }
                    if !midBurst {
                        if rnd(2) == 0 {t+=7_500*ms}
                        let to=(tab+1+Int(rnd(2)))%3,when=t+UInt64(rnd(60_000_000))
                        at(when) {switchTo(to)};switches+=1;tab=to;t=when+UInt64(20+rnd(80))*ms
                    }
                }
                let end=t
                tab=0   // the scheduled switches replay from tab 0
                run(until:end+7_000*ms)
                let w=try newWords()
                let mixed=w.contains {word in word.split(separator:" ").contains {unit in Set(unit.compactMap {c in alphabets.firstIndex {$0.contains(c)}}).count > 1}}
                let savedLetters=w.reduce(0) {$0+$1.filter {$0 != " "}.count}
                // No two verified reads of different tabs' fields compare equal (so no bracket spans a switch).
                var crossEqual=0,pairs=0
                for i in records.indices {for j in (i+1)..<min(i+40,records.count) where !records[i].focus.matches(records[j].focus) {
                    pairs+=1;if records[i].sameFacts(as:records[j]) {crossEqual+=1}
                }}
                let attributed=crossEqual == 0 && pairs > 0 && (ChromeReadShape.current == .full || savedLetters > 0)
                let tag="\(shapeName), \(rule), \(lat) ms/event"
                print("QF17 METRIC L1 same-URL tabs (\(tag)): keys=\(truth.count) switches=\(switches) savedLetters=\(savedLetters) units=\(w.count) reads.verified=\(records.count) crossTabPairs=\(pairs) crossTabEqual=\(crossEqual)")
                check(!mixed && attributed,"QF-17 L1 (\(tag)): three tabs on one URL switched at random (\(switches) switches, no notification): no saved unit mixes tabs, and no two reads of different tabs' fields compare equal")
            }
        }
        // L4: a second normal window with exactly the focused window's bounds. The lean prototype has no window name
        //     to tell them apart and refuses every read (counted as loss); the full shape tells them apart by name.
        for lat in rowLatencies {
            makeRoute(.perFact,latencyMs:lat)
            chrome.windows.append(BracketFakeChrome.Window(id:"404",mode:"normal",bounds:BracketFakeChrome.bounds,name:"Other page",tab:"9404",url:"https://other.example.org/"))
            let twin=WebFakeNode("window-404",role:"AXWindow",subrole:"AXStandardWindow");twin.frame=chrome.window.frame;twin.title="Other page";chrome.axWindows.append(twin)
            let s0=prime()+200*ms
            typeRun(alphabet,from:s0,every:80*ms);advance(7)
            let saved=savedTimes(try newWords()).count
            let d=diag()
            print("QF17 METRIC L4 identical bounds (\(shapeName), \(lat) ms/event): typed=\(alphabet.count) saved=\(saved) reads.verified=\(records.count) reads.denied=\(Int(d["reads.denied"] ?? -1)) keys.lost=\(Int(d["keys.lost"] ?? -1))")
            if ChromeReadShape.current == .lean {
                check(saved == 0 && records.isEmpty,"QF-17 L4 (\(shapeName), \(lat) ms/event): two normal windows with identical bounds: every read is refused and nothing is saved: a loss of \(alphabet.count) of \(alphabet.count) keys (counted here from the known input; the route's keys.lost excludes keys dropped unread at a refused read, by PM6a)")
            }
        }

        // ---- QF-17 active window (b+ LIVELOCK, ruling 2026-09-30): no read starts after the last input event + 5 s
        //      (`activeNanoseconds`), Return and other non-text keys included, on the event clock (typedAt). Keys, then
        //      Return 80 ms after the last letter (as b+ types): reads may start after the last letter + 5 s (inside the
        //      Return's own window) and none after the Return + 5 s. Negative control: a Tab 2 s after the Return keeps
        //      reads running to the Tab + 5 s, and the same Return + 5 s measure reports them (it can fail).
        for rule in [ChromeBracketRule.wholeRead,.perFact] {
            let active=ChromeBracketTiming.activeNanoseconds
            makeRoute(rule,latencyMs:3)
            let s0=prime()+200*ms
            let returnAt=typeRun("livelock",from:s0,every:80*ms),lastLetter=returnAt-80*ms
            strokeAt(returnAt,KeyStroke(keyCode:36))
            run(until:returnAt+active+2_000*ms)
            let pastReturn=joinStarts.filter {$0 > returnAt+active}.count
            let insideReturnWindow=joinStarts.filter {$0 > lastLetter+active && $0 <= returnAt+active}.count
            let stopped = !route().control.running
            check(pastReturn == 0 && stopped && !joinStarts.isEmpty,
                  "QF-17 active window (\(shapeName), \(rule)): no read starts after the Return + 5 s on the event clock (\(joinStarts.count) reads; after the last letter + 5 s, inside the Return's window: \(insideReturnWindow)); the loop stops")
            accountingCheck("active window (\(shapeName), \(rule))",finished:true)
            _=try newWords()   // the saved text of this scenario is not the next scenario's
            makeRoute(rule,latencyMs:3)
            let c0=prime()+200*ms
            let controlReturn=typeRun("control",from:c0,every:80*ms),tabAt=controlReturn+2_000*ms
            strokeAt(controlReturn,KeyStroke(keyCode:36))
            strokeAt(tabAt,KeyStroke(keyCode:48))
            run(until:tabAt+active+2_000*ms)
            let controlPastReturn=joinStarts.filter {$0 > controlReturn+active}.count
            let controlPastTab=joinStarts.filter {$0 > tabAt+active}.count
            check(controlPastReturn > 0 && controlPastTab == 0 && !route().control.running,
                  "QF-17 active window negative control (\(shapeName), \(rule)): a Tab 2 s after the Return: \(controlPastReturn) reads start after the Return + 5 s (the measure above reports them), none after the Tab + 5 s")
            accountingCheck("active window control (\(shapeName), \(rule))",finished:true)
            _=try newWords()   // the saved text of this scenario is not the next scenario's
        }

        // ---- QF-17 bracketed field hold (Codex 07:10 as in f1d0445; review FH-1), in both shapes. A full read that
        //      refused an unlabelled box as `field` after a completed scan holds it: plain keys in that box, less than
        //      1 s apart, are dropped unread and start no read; nothing is counted; every boundary and a pause end it.
        let unlabelled=BrowserTypingFieldLabels(texts:[],identifiers:[]),notes=BrowserTypingFieldLabels(texts:["Notes"],identifiers:[])
        do {
            makeRoute(.perFact,latencyMs:4)
            chrome.field.labels=unlabelled
            let t0=prime();run(until:t0+300*ms)
            let started=route().fieldHold != nil && joinCalls > 0
            // Held keys every 200 ms for 7 s: the reads the first key started stop after activeNanoseconds (5 s).
            var t=t0+400*ms
            for _ in 0..<35 {keyAt(t,"h");t+=200*ms}
            run(until:t0+6_000*ms)
            let joinsAt6=joinCalls
            run(until:t)
            let quiet=joinCalls == joinsAt6 && !route().control.running
            // Stated cost (as f1d0445): a box labelled mid-burst stays held until a boundary or a pause.
            chrome.field.labels=notes
            for _ in 0..<4 {keyAt(t,"h");t+=200*ms}
            run(until:t)
            // Each held key in the same box starts the quiet period again: denial quiet (9de7d09 `noteDenied`; review
            // 10:35 Q-2: never the intake boundary, which QF-1 recovery may shorten).
            let stillHeld=route().fieldHold != nil && joinCalls == joinsAt6 && route().burst.quietFrom == t-200*ms && !route().burst.recoversBracketedQuiet
            advance(7)
            let none=try newWords().isEmpty
            check(started && quiet && stillHeld && acquires == 0 && route().held.isEmpty && (diag()["keys.lost"] ?? -1) == 0 && (diag()["keys.admitted"] ?? -1) == 0 && none,
                  "QF-17 field hold (\(shapeName)): keys in a box a full read refused as field (unlabelled) are dropped unread: no read starts for them (joins \(joinsAt6) unchanged once the loop stopped), nothing is read, held, admitted, counted lost or saved; each starts the quiet period again; a box labelled mid-burst stays held")
            accountingCheck("field hold (\(shapeName))",finished:true)
        }
        for kind in ["Tab","mouse down","chord","Return","input source","window notification","key lost (gap)","pause of 1 s","key in another app (FH-2)","secure input on mid-hold (FH-3)"] {
            makeRoute(.perFact,latencyMs:4)
            chrome.field.labels=unlabelled
            let t0=prime();var t=t0+400*ms
            for _ in 0..<5 {keyAt(t,"h");t+=200*ms}
            run(until:t)
            let held=route().fieldHold != nil && acquires == 0
            let acquiredBefore=acquires
            chrome.field.labels=notes
            let b=t
            switch kind {
            case "Tab":strokeAt(b,KeyStroke(keyCode:48))
            case "mouse down":at(b) {osInput=max(osInput,b);TypingPointer.down(at:b)}
            case "chord":strokeAt(b,KeyStroke(keyCode:8,command:true))
            case "Return":strokeAt(b,KeyStroke(keyCode:36))
            case "input source":at(b) {capture.inputSourceChanged()}
            case "window notification":at(b) {route().chromeWindowNotification()}
            case "key lost (gap)":at(b) {TypingKeyGap.lost(at:b)}
            case "key in another app (FH-2)":at(b) {_=route().handle(eventAt:b,stroke:KeyStroke(keyCode:0),bundle:"com.apple.TextEdit",pid:4_243,coordinator:coordinator) {acquires+=1;return "x"}}
            case "secure input on mid-hold (FH-3)":
                // The next key is dropped and ends the hold; reads refuse while secure input is on.
                at(b) {chrome.secure=true};keyAt(b+50*ms,"h");at(b+300*ms) {chrome.secure=false}
            default:break
            }
            let s1=kind == "pause of 1 s" ? b+1_000*ms : b+500*ms
            run(until:s1-1*ms)
            let ended=kind == "pause of 1 s" || route().fieldHold == nil
            // Review 11:05 FHB-1: a non-user event that ends the hold starts denial quiet at it.
            let nonUser=["input source","window notification","key lost (gap)"].contains(kind)
            let fhb = !nonUser || ((route().burst.quietFrom ?? 0) >= b && !route().burst.recoversBracketedQuiet)
            typeRun("typed after the boundary",from:s1,every:80*ms);advance(7)
            let w=try newWords()
            if ProcessInfo.processInfo.environment["QF17_DEBUG"] != nil {print("QF17 DEBUG hold \(kind): held=\(held) ended=\(ended) hold=\(route().fieldHold != nil) words=\(w.map(\.count)) boundary=\(w.contains {$0.contains("boundary")}) d=\(diag())")}
            check(held && ended && fhb && route().fieldHold == nil && w.contains {$0.contains("boundary")} && (kind.hasPrefix("key in another") || acquires > acquiredBefore),
                  "QF-17 field hold (\(shapeName)): \(kind) ends the hold; the box, labelled by then, is typed")
            accountingCheck("field hold, \(kind) (\(shapeName))",finished:true)
        }
        // FH-1 (review 09:40): a scripted focus move from the held box to a labelled one, more than 400 ms into the
        // hold. The next key may have been typed in the refused box: dropped unread, a boundary, the quiet period renewed.
        for loopRunning in [true,false] {
            makeRoute(.perFact,latencyMs:4)
            chrome.field.labels=unlabelled
            let box2=WebFakeNode("box2",role:"AXTextArea",parent:WebFakeNode("group2",role:"AXGroup",parent:chrome.web));box2.labels=notes
            var move:UInt64=0,zAt:UInt64=0,joinsBefore=0,holding=false
            func typeZ() {
                zAt=mono+1*ms;joinsBefore=joinCalls
                at(zAt) {typed.append((zAt,"z"));osInput=max(osInput,zAt);capture.handleNativeKey(eventAt:zAt,keyCode:0,shortcut:false) {acquires+=1;return "z"}}
            }
            let t0=prime()
            if loopRunning {
                // Held keys, then the move: more than 400 ms into the hold, just before the loop's next read (refused
                // reads pause it 20 ms, doubling, up to 640 ms). The key follows the first verified read of the labelled
                // box at once: without FH-1 it would be bracketed there and saved.
                for i in 0..<4 {keyAt(t0+UInt64(100+150*i)*ms,"h")}
                var refusals=0,holdFrom:UInt64=0
                afterDeliver={
                    guard let last=route().results.last else {return}
                    if last.result.denial != nil {
                        refusals+=1
                        if holdFrom == 0,route().fieldHold != nil {holdFrom=mono}
                        let next=mono+min(ChromeBracketTiming.retryNanoseconds<<UInt64(refusals-1),ChromeBracketTiming.retryMaxNanoseconds)
                        if move == 0,holdFrom > 0,next > holdFrom+460*ms {
                            move=next-30*ms
                            at(move) {holding=route().fieldHold != nil;chrome.focus=box2}
                        }
                    } else if move > 0,zAt == 0,records.contains(where:{$0.focus.matches(object:box2)}) {typeZ()}
                }
                run(until:t0+3_000*ms)
            } else {
                var t=t0+400*ms
                for _ in 0..<30 {keyAt(t,"h");t+=200*ms}
                run(until:t)
                holding=route().fieldHold != nil
                move=t;at(move) {chrome.focus=box2}
                run(until:move+150*ms)
                typeZ()
            }
            afterDeliver=nil
            run(until:zAt+1*ms)
            let within=zAt > move && zAt-move < 400*ms
            let discriminating = !loopRunning || records.contains {$0.focus.matches(object:box2) && $0.end < zAt}
            let noRead=acquires == 0 && route().held.isEmpty && route().fieldHold == nil && (loopRunning || joinCalls == joinsBefore)
            typeRun("typed in the new box",from:max(zAt+600*ms,mono+10*ms),every:80*ms);advance(7)
            let w=try newWords()
            if ProcessInfo.processInfo.environment["QF17_DEBUG"] != nil {print("QF17 DEBUG FH-1 \(loopRunning): holding=\(holding) within=\(within) \((zAt &- move)/ms) ms disc=\(discriminating) noRead=\(noRead) z=\(w.contains {$0.contains("z")}) newbox=\(w.contains {$0.contains("new box")}) words=\(w.map(\.count)) lost=\(diag()["keys.lost"] ?? -1) recs=\(records.count)")}
            check(holding && within && discriminating && noRead && !w.contains {$0.contains("z")} && w.contains {$0.contains("new box")},
                  "QF-17 FH-1 field hold (\(shapeName), \(loopRunning ? "reads still running" : "reads stopped")): after a scripted move to a labelled box more than 400 ms into the hold, a key within 400 ms of the move is dropped unread (\(loopRunning ? "never bracket-admitted, though a verified read of the new box ended before it" : "no read")) and not saved; the hold ends; the new box is typed after the quiet period")
            accountingCheck("FH-1 (\(shapeName))",finished:true)
        }
        // Never held: labels that can't be read (field before any scan) and a timeout.
        for name in ["labels that can't be read","every read runs out of time"] {
            // A read's opening focus check that takes 160 ms leaves it past its 150 ms budget: `timeout`.
            makeRoute(.perFact,latencyMs:4,focusMs:name.hasPrefix("labels") ? 0 : 160)
            chrome.field.labels=name.hasPrefix("labels") ? nil : unlabelled
            var everHeld=false
            afterDeliver={if route().fieldHold != nil {everHeld=true}}
            let t0=prime();var t=t0+400*ms
            for _ in 0..<8 {keyAt(t,"h");t+=200*ms}
            run(until:t+200*ms)
            let expected:BrowserTypingDenial=name.hasPrefix("labels") ? .field : .timeout
            let refused=route().results.contains {$0.result.denial == expected}
            let neverHeld = !everHeld && route().fieldHold == nil
            afterDeliver=nil;chrome.field.labels=notes;chrome.focusDelay=0;advance(7);_=try newWords()
            check(refused && neverHeld,"QF-17 field hold (\(shapeName)): \(name): refused, never held")
            accountingCheck("field hold never set, \(name) (\(shapeName))",finished:true)
        }

        // ---- Review 10:35 (Codex QF-1 x the bracketed field hold), recovery ON. The hold's quiet periods are denial
        //      quiet: a key less than 400 ms after a held drop or the FH-1 end is refused even with a complete bracket
        //      after it; a later real Tab recovers only with a read that started strictly after it.
        for shortCircuit in [false,true] {
            // Test 2: a same-box drop, then a key < 400 ms later with a post-drop bracket. `shortCircuit`: the test
            // ends the hold by hand, so only the denial quiet stands between the key and admission.
            makeRoute(.perFact,latencyMs:4,recoverQuiet:true)
            chrome.field.labels=unlabelled
            var dropAt:UInt64=0,keyAt2:UInt64=0,relabelled=false
            afterDeliver={
                if dropAt == 0,route().fieldHold != nil {
                    dropAt=mono+2*ms
                    at(dropAt) {typed.append((dropAt,"h"));osInput=max(osInput,dropAt);capture.handleNativeKey(eventAt:dropAt,keyCode:0,shortcut:false) {acquires+=1;return "h"}}
                    at(dropAt+1*ms) {chrome.field.labels=notes;relabelled=true}
                } else if relabelled,keyAt2 == 0,records.contains(where:{$0.start > dropAt}) {
                    if shortCircuit {route().fieldHold=nil}
                    keyAt2=mono+1*ms
                    at(keyAt2) {typed.append((keyAt2,"k"));osInput=max(osInput,keyAt2);capture.handleNativeKey(eventAt:keyAt2,keyCode:0,shortcut:false) {acquires+=1;return "k"}}
                }
            }
            let t0=prime();run(until:t0+1_500*ms)
            afterDeliver=nil
            let bracketed=keyAt2 > 0 && records.contains {$0.start > dropAt && $0.end < keyAt2} && records.contains {$0.start > keyAt2}
            let refused=acquires == 0 && keyAt2 > dropAt && keyAt2-dropAt < 400*ms && (route().burst.quietFrom ?? 0) >= dropAt && !route().burst.recoversBracketedQuiet
            advance(7)
            let w=try newWords()
            check(bracketed && refused && !w.contains {$0.contains("k")},
                  "QF-1 x field hold (\(shapeName), recovery on\(shortCircuit ? ", hold ended by hand" : "")): a key \((keyAt2 &- dropAt)/ms) ms after a same-box held drop, with a complete bracket of reads started after the drop, is refused (denial quiet) and not saved")
            accountingCheck("QF-1 x field hold, test 2 (\(shapeName))",finished:true)
        }
        do {
            // Test 3: the FH-1 end (focus moved to a labelled box), then a key < 400 ms later with a bracket of the new box.
            makeRoute(.perFact,latencyMs:4,recoverQuiet:true)
            chrome.field.labels=unlabelled
            let box2=WebFakeNode("box2",role:"AXTextArea",parent:WebFakeNode("group2",role:"AXGroup",parent:chrome.web));box2.labels=notes
            var move:UInt64=0,zAt:UInt64=0,kAt:UInt64=0,refusals=0,holdFrom:UInt64=0
            func hit(_ c:String,_ t:UInt64) {at(t) {typed.append((t,c));osInput=max(osInput,t);capture.handleNativeKey(eventAt:t,keyCode:0,shortcut:false) {acquires+=1;return c}}}
            afterDeliver={
                guard let last=route().results.last else {return}
                if last.result.denial != nil {
                    refusals+=1
                    if holdFrom == 0,route().fieldHold != nil {holdFrom=mono}
                    let next=mono+min(ChromeBracketTiming.retryNanoseconds<<UInt64(refusals-1),ChromeBracketTiming.retryMaxNanoseconds)
                    if move == 0,holdFrom > 0,next > holdFrom+460*ms {move=next-30*ms;at(move) {chrome.focus=box2}}
                } else if move > 0,zAt == 0,records.contains(where:{$0.focus.matches(object:box2)}) {
                    zAt=mono+1*ms;hit("z",zAt)
                } else if zAt > 0,kAt == 0,records.contains(where:{$0.start > zAt && $0.focus.matches(object:box2)}) {
                    kAt=mono+1*ms;hit("k",kAt)
                }
            }
            let t0=prime();run(until:t0+3_000*ms)
            afterDeliver=nil
            let bracketed=kAt > 0 && records.contains {$0.start > zAt && $0.end < kAt} && records.contains {$0.start > kAt}
            let refused=acquires == 0 && kAt > zAt && kAt-zAt < 400*ms && !route().burst.recoversBracketedQuiet && route().fieldHold == nil
            advance(7)
            let w=try newWords()
            check(bracketed && refused && !w.contains {$0.contains("z") || $0.contains("k")},
                  "QF-1 x field hold (\(shapeName), recovery on): after the FH-1 end, a key \((kAt &- zAt)/ms) ms later with a complete bracket of the new box is refused (denial quiet) and not saved")
            accountingCheck("QF-1 x field hold, test 3 (\(shapeName))",finished:true)
        }
        do {
            // Test 4: a held drop, then a real Tab: recovery only with a read that started strictly after the Tab.
            makeRoute(.perFact,latencyMs:4,recoverQuiet:true)
            chrome.field.labels=unlabelled
            var dropAt:UInt64=0,tabAt:UInt64=0,early:UInt64=0,wAt:UInt64=0
            func hit(_ c:String,_ t:UInt64) {at(t) {typed.append((t,c));osInput=max(osInput,t);capture.handleNativeKey(eventAt:t,keyCode:0,shortcut:false) {acquires+=1;return c}}}
            afterDeliver={
                if dropAt == 0,route().fieldHold != nil {
                    dropAt=mono+2*ms;hit("h",dropAt)
                    tabAt=dropAt+20*ms
                    at(tabAt) {chrome.field.labels=notes};strokeAt(tabAt,KeyStroke(keyCode:48))
                    early=tabAt+1*ms;hit("q",early)
                } else if tabAt > 0,wAt == 0,mono > early,records.contains(where:{$0.start > tabAt}) {
                    wAt=mono+1*ms
                    for (i,c) in "wxyz".enumerated() {hit(String(c),wAt+UInt64(i)*40*ms)}
                }
            }
            let t0=prime();run(until:t0+1_500*ms)
            afterDeliver=nil
            let recovered=route().burst.recoversBracketedQuiet && route().burst.quietFrom == tabAt && wAt > tabAt && wAt-tabAt < 400*ms
            let priorBeforeTab = !records.contains {$0.start > tabAt && $0.end < early}
            advance(7)
            let w=try newWords()
            check(recovered && priorBeforeTab && w.contains {$0.contains("w")} && !w.contains {$0.contains("q")},
                  "QF-1 x field hold (\(shapeName), recovery on): after a held drop, a real Tab recovers: a key with no read started after the Tab is refused; a key \((wAt &- tabAt)/ms) ms after it, after a read that started strictly after it, is saved")
            accountingCheck("QF-1 x field hold, test 4 (\(shapeName))",finished:true)
        }

        // QF17_SHAPE=lean: the feasibility prototype's numbers only (not a check run).
        if ChromeReadShape.current == .lean { print("QF17 METRIC lean shape: metrics only, stopping"); ChromeReadShape.current = .full; return }

        // ---- D3 / R1: keys during R0, and a key with no read in flight, are dropped unread (acquire never called).
        makeRoute(.perFact)
        let r0=mono+10*ms;keyAt(r0,"q");keyAt(r0+30*ms,"r")
        run(until:r0+40*ms)
        check(acquires == 0 && route().held.isEmpty,"QF-17 D3/R1: keys typed before any verified read (during R0) are dropped unread: acquire never called")
        advance(7)
        check(try newWords().isEmpty && !route().control.running,"QF-17 D3/R1: nothing from R0 is ever admitted by a later read; the loop stops when idle")
        keyAt(mono+10*ms,"s");run(until:mono+11*ms)
        check(acquires == 0,"QF-17 PM3: a key after the loop stopped (last verified read stale) reads nothing at the key")
        advance(7);_=try newWords()

        // ---- D4: a window/title notification after a result was posted, before its admission: held keys discarded.
        makeRoute(.perFact)
        do {
            var fired=false,heldAt:[UInt64]=[],zero=false
            let s0=prime()+200*ms
            beforeDeliver={
                if !fired && !route().held.isEmpty && mono > s0 {
                    fired=true;heldAt=route().held.keys.map(\.typedAt)
                    route().chromeWindowNotification()
                    zero=route().held.isEmpty && route().held.allZero
                }
            }
            typeRun("abcdefghijkl",from:s0,every:20*ms);advance(7)
            let times=Set(savedTimes(try newWords()))
            check(fired && !heldAt.isEmpty && heldAt.allSatisfy {!times.contains($0)} && zero,
                  "QF-17 D4: a Chrome window/title notification received after a read's result was posted but before admission discards every held key (buffer zeroed)")
        }

        // ---- PM1 / PM2 / PM6b: key-time identity mismatches, one key right after a verified read (inside the freshness window).
        func afterRead(_ body:@escaping ()->Void) {
            var fired=false
            afterDeliver={if !fired && route().engine.lastVerified != nil {fired=true;at(mono+1*ms,body)}}
        }
        let otherWindow=WebFakeNode("other-window",role:"AXWindow",subrole:"AXStandardWindow")
        for (name,apply,revert) in [("frontmost is not Chrome",{chrome.frontmost=4_243},{chrome.frontmost=BracketFakeChrome.pid}),
                                    ("secure input on",{chrome.secure=true},{chrome.secure=false}),
                                    ("another window's refs (Incognito or a second window)",{chrome.focusedWindow=otherWindow},{chrome.focusedWindow=chrome.window}),
                                    ("PM2: the system-focused app is not Chrome",{chrome.systemFocused=99_997},{chrome.systemFocused=BracketFakeChrome.pid})] as [(String,()->Void,()->Void)] {
            makeRoute(.perFact)
            var tried=false,acquired=0,wiped=false
            afterRead {
                tried=true;apply();let before=acquires,t=mono
                typed.append((t,"x"));capture.handleNativeKey(eventAt:t,keyCode:0,shortcut:false) {acquires+=1;return "x"}
                acquired=acquires-before;wiped=route().held.isEmpty && route().held.allZero;revert()
            }
            _=prime();advance(7)
            let lost=diag()["keys.lost"] ?? -1
            let none=try newWords().isEmpty
            check(tried && acquired == 0 && wiped && lost == 0 && none,
                  "QF-17 PM1/B2 (\(name)): the key is not read or held, the buffer is wiped, and nothing is counted as lost")
        }
        makeRoute(.perFact)
        do {
            var tried=false
            afterRead {tried=true;chrome.identityPaused=true;let t=mono;capture.handleNativeKey(eventAt:t,keyCode:0,shortcut:false) {acquires+=1;return "x"};chrome.identityPaused=false}
            _=prime();advance(7)
            check(tried && acquires == 0 && diag()["keys.lost"] == 1,"QF-17 PM6b: a key while the identity reader is paused (nil refs) is a counted loss (aggregate only)")
        }
        // R3: text before and after an excursion (frontmost not Chrome for one key) is never one unit.
        makeRoute(.perFact)
        do {
            let s0=prime()+200*ms,a="abcdefgh",b="ijklmnop"
            let mid=typeRun(a,from:s0,every:30*ms)
            at(mid) {chrome.frontmost=4_243;capture.handleNativeKey(eventAt:mid,keyCode:0,shortcut:false) {acquires+=1;return "x"};chrome.frontmost=BracketFakeChrome.pid}
            typeRun(b,from:mid+30*ms,every:30*ms);advance(7)
            let w=try newWords()
            check(!joinedAcross(w,a,b) && !w.contains {$0.contains("x")},"QF-17 R3/PM1: text before and after a key-time excursion is never joined into one unit; the excursion key is not saved")
        }

        // ---- PM5 + R4: each boundary inside the interval: nothing saved spans it and nothing is joined across it.
        for kind in ["mouse down","chord","Tab","Return","Left arrow","input source","secure input","key lost (gap)","window notification","mouse down processed after the result arrived"] {
            makeRoute(.perFact)
            let s0=prime()+200*ms,a="abcdefgh",b="ijklmnop"
            let mid=typeRun(a,from:s0,every:25*ms),boundaryAt=mid-5*ms
            var bStart=mid+10*ms
            switch kind {
            case "mouse down":at(boundaryAt) {osInput=max(osInput,boundaryAt);TypingPointer.down(at:boundaryAt)}
            case "chord":strokeAt(boundaryAt,KeyStroke(keyCode:8,command:true))
            case "Tab":strokeAt(boundaryAt,KeyStroke(keyCode:48))
            case "Return":strokeAt(boundaryAt,KeyStroke(keyCode:36))
            case "Left arrow":strokeAt(boundaryAt,KeyStroke(keyCode:123))
            case "input source":at(boundaryAt) {capture.inputSourceChanged()}
            case "secure input":at(boundaryAt) {chrome.secure=true};at(boundaryAt+60*ms) {chrome.secure=false};bStart=boundaryAt+80*ms
            case "key lost (gap)":at(boundaryAt) {TypingKeyGap.lost(at:boundaryAt)}
            case "window notification":at(boundaryAt) {route().chromeWindowNotification()}
            default:
                // The OS saw the mouse down at boundaryAt; main handles it 35 ms later (after read results arrived).
                at(boundaryAt) {osInput=max(osInput,boundaryAt)}
                at(boundaryAt+35*ms) {TypingPointer.down(at:boundaryAt)}
                bStart=boundaryAt+50*ms
            }
            typeRun(b,from:bStart,every:25*ms);advance(7)
            let w=try newWords()
            let spanning=savedTimes(w).filter {t in bracketOf(t,.perFact).map {records[$0.lo].start <= boundaryAt && boundaryAt <= records[$0.hi].end} ?? true}
            let recorded=kind == "secure input" || route().engine.boundaries.contains(boundaryAt) || kind == "window notification"
            check(spanning.isEmpty && !joinedAcross(w,a,b) && recorded && route().held.allZero,
                  "QF-17 R4\(kind == "Left arrow" ? "/PM5" : ""): \(kind) inside the interval: no saved key's bracket spans it, nothing joined across it")
        }

        // ---- PM6a: Incognito keys never feed keys.lost.
        makeRoute(.perFact)
        do {
            let s0=prime()+200*ms
            let tI=typeRun("abcd",from:s0,every:30*ms)+20*ms
            var lostBefore:Double = -1,zero=false
            let incog=WebFakeNode("incog-field",role:"AXTextArea",parent:nil)
            at(tI) {lostBefore=diag()["keys.lost"] ?? -1;let n=chrome.addWindow("707",mode:"incognito");chrome.focusedWindow=n;incog.parent=n;chrome.focus=incog}
            typeRun("wxyz",from:tI+10*ms,every:30*ms)
            at(tI+400*ms) {zero=route().held.allZero}
            at(tI+1_500*ms) {chrome.removeWindow("707");chrome.focusedWindow=chrome.window;chrome.focus=nil}
            keyAt(tI+1_600*ms,"!")
            advance(8)
            let w=try newWords()
            check(lostBefore >= 0 && diag()["keys.lost"] == lostBefore && !w.contains {$0.contains {"wxyz".contains($0)}} && zero,
                  "QF-17 PM6a/B5: keys typed in an Incognito window are never counted as lost, never saved; the buffer is wiped at the refusal")
        }

        // ---- PM8: typing turned off while a read is in flight: that read completes, no other join starts, nothing saved.
        makeRoute(.perFact)
        do {
            var switched=false,joinsAtSwitch=0
            chrome.onAppleEvent={n in if n == 20 && !switched {switched=true;joinsAtSwitch=joinCalls;try? typingSwitch(false)}}
            let s0=prime()+200*ms
            typeRun("abcdefghijkl",from:s0,every:30*ms);advance(7)
            let none=try newWords().isEmpty
            check(switched && joinCalls == joinsAtSwitch && none && route().held.allZero,
                  "QF-17 PM8: typing off during a read: only the read in flight completes, no further join starts, nothing is saved")
            try typingSwitch(true)
        }
        // Between reads (the loop's 20 ms retry pause after a refused read): no read may start after the revocation.
        makeRoute(.perFact)
        do {
            chrome.secure=true
            _=prime();advance(0.3)
            let joinsAtSwitch=joinCalls
            try typingSwitch(false)
            advance(2)
            expectSource(joinCalls == joinsAtSwitch,"QF-17 PM8: typing off during the loop's retry pause: no further join starts (\(joinCalls-joinsAtSwitch) started)")
            try typingSwitch(true)
            chrome.secure=false
        }

        // ---- Busy loop: reads refused before any Apple Event (secure input on) are paced and bounded.
        makeRoute(.perFact)
        do {
            chrome.secure=true
            let t0=mono;var t=t0+10*ms
            while t < t0+10_000*ms {keyAt(t,"k");t+=400*ms}
            let runsBefore=timerRuns
            run(until:t0+10_000*ms)
            let joins=joinCalls,runs=timerRuns-runsBefore
            print("QF17 METRIC busy-loop secure-input 10 s: joins=\(joins) timer runs=\(runs) appleEvents=\(chrome.appleEvents)")
            check(joins > 0 && joins <= 600 && chrome.appleEvents == 0,"busy-loop (fake clock): refused-before-AE reads are paced and bounded (\(joins) joins in 10 s)")
            let atOff=joinCalls
            try typingSwitch(false)
            advance(3)
            check(joinCalls-atOff <= 1,"busy-loop (fake clock): once typing is off the loop makes at most one more join call (\(joinCalls-atOff))")
            expectSource(joinCalls == atOff,"busy-loop (fake clock): once typing is off (control bumped) the loop makes no further join calls (\(joinCalls-atOff) after)")
            try typingSwitch(true);chrome.secure=false
            advance(7)
        }

        // ---- R7: hung Chrome and 200 ms per event: nothing saved, buffer zero, intake stays small; no retry salvages it.
        for (name,hung,lat) in [("hung (every event times out)",true,UInt64(12)),("200 ms per event",false,UInt64(200))] {
            makeRoute(.perFact,latencyMs:lat);chrome.hung=hung
            let s0=prime()+200*ms
            typeRun("abcdefghij",from:s0,every:30*ms);advance(7)
            let d=diag()
            print("QF17 METRIC R7 \(name): intake.us.p50=\(d["intake.us.p50"] ?? -1) intake.us.p95=\(d["intake.us.p95"] ?? -1) intake.us.max=\(d["intake.us.max"] ?? -1) joins=\(joinCalls)")
            chrome.hung=false;chrome.latency=12*ms;advance(7)
            check(try newWords().isEmpty && route().held.isEmpty && route().held.allZero && (d["intake.us.p95"] ?? 1e9) < 5_000,
                  "QF-17 R7 (\(name)): nothing saved, the buffer is zero, no later read salvages it, key intake p95 < 5 ms")
        }

        // ---- B4 caps: the 1 s age cap (Chrome stalls 1.2 s mid-read) and the 64-key overflow.
        makeRoute(.perFact)
        do {
            var armed=false
            afterRead {chrome.stallAt=chrome.appleEvents+3;chrome.stall=1_200*ms;armed=true}
            let s0=prime()+200*ms
            typeRun("abcdefghijklmnop",from:s0,every:15*ms);advance(8)
            let times=savedTimes(try newWords())
            let stalledFrom=records.first.map {_ in s0} ?? s0
            check(armed && route().held.allZero && times.allSatisfy {bracketOf($0,.perFact) != nil} && stalledFrom > 0,
                  "QF-17 B4 age cap: a 1.2 s stall mid-read: keys held across it are never admitted late; the buffer is zeroed")
        }
        makeRoute(.perFact)
        do {
            var burst=false
            // 70 keys 0.5 ms apart right after a read: all inside the D3 freshness window (a verified Ra that began
            // under SPAN before each key), so the 65th really overflows the 64-key cap.
            afterRead {burst=true;for i in 0..<70 {keyAt(mono+UInt64(1+i)*ms/2,"v")}}
            _=prime();advance(8)
            let saved=try newWords()
            if ProcessInfo.processInfo.environment["QF17_DEBUG"] != nil {
                print("QF17 DEBUG overflow: burst=\(burst) savedV=\(saved.reduce(0) {$0+$1.filter {$0 == "v"}.count}) allZero=\(route().held.allZero) held=\(route().held.count) acquires=\(acquires)")
            }
            check(burst && !saved.contains {$0.contains("v")} && route().held.allZero,"QF-17 B4 overflow: 70 keys inside one bracket (cap 64): none saved; the buffer is zeroed")
        }

        // ---- Explicit drop: the buffer is zeroed.
        makeRoute(.perFact)
        do {
            var held=false,zero=false
            afterRead {at(mono+1*ms) {}}
            let s0=prime()+200*ms
            typeRun("abcdefgh",from:s0,every:10*ms)
            at(s0+45*ms) {held = !route().held.isEmpty;route().drop(.focus);zero=route().held.isEmpty && route().held.allZero}
            advance(7);_=try newWords()
            check(zero,"QF-17 B4: drop (leaving Chrome, a policy change) zeroes the held buffer (held before: \(held))")
        }

        // ---- P04 / P08 / P12 (merge gate): must save nothing.
        for (id,text,make) in [("P04 password shown as text (unlabelled field next to 'Show password')","hunterpassword",{() -> WebFakeNode in
                                    let g=WebFakeNode("pwg",role:"AXGroup",parent:chrome.web)
                                    let b=WebFakeNode("pwshow",role:"AXButton",parent:g);b.labels=BrowserTypingFieldLabels(texts:["Show password"],identifiers:[])
                                    return WebFakeNode("pwtext",role:"AXTextField",parent:g)}),
                               ("P08 card number in a field labelled only 'Number'","4242424242424242",{() -> WebFakeNode in
                                    let n=WebFakeNode("ccn",role:"AXTextField",parent:WebFakeNode("ccg",role:"AXGroup",parent:chrome.web))
                                    n.labels=BrowserTypingFieldLabels(texts:["Number"],identifiers:[]);return n}),
                               ("P12 one-time code in an unlabelled field","482913",{() -> WebFakeNode in
                                    WebFakeNode("otp",role:"AXTextField",parent:WebFakeNode("otpg",role:"AXGroup",parent:chrome.web))})] as [(String,String,()->WebFakeNode)] {
            makeRoute(.perFact)
            chrome.focus=make()
            let s0=prime()+200*ms
            typeRun(text,from:s0,every:40*ms);advance(7)
            let saved=try newWords().reduce(0) {$0+$1.count}
            let admitted=Int(diag()["keys.admitted"] ?? -1)
            if saved == 0 && admitted == 0 {
                check(true,"QF-17 merge gate \(id): nothing admitted, nothing saved")
            } else {
                print("KNOWN GAP (PB2, needs A's QF-11 form scan) \(id): admitted=\(admitted) savedCharacters=\(saved) of \(text.count) typed\(saved == 0 ? " (only the store's secret scrubber stopped the row)" : "")")
            }
        }

        // ---- Sentinel: a denied scenario (Incognito open) and a lost scenario (whole-read rule): the sentinel appears
        // in no log line, diagnostic, error string or raw record.
        let sentinel="zqxsentinel"
        let logBefore=Set(DiagnosticsLog.shared.recent(100_000))
        var surfaces:[String]=[]
        for (name,rule,incognito) in [("denied (Incognito open)",ChromeBracketRule.perFact,true),("lost (whole-read rule)",.wholeRead,false)] {
            makeRoute(rule)
            if incognito {chrome.addWindow("808",mode:"incognito")}
            let s0=prime()+200*ms
            typeRun(sentinel,from:s0,every:30*ms)
            at(s0+150*ms) {surfaces.append(String(reflecting:route().held));surfaces.append(route().held.keys.map {String(reflecting:$0)}.joined())}
            advance(7)
            surfaces.append(diag().description)
            surfaces.append(route().results.map {String(reflecting:$0.result)}.joined(separator:"|"))
            surfaces.append(route().ops.map {String(reflecting:$0.kind)}.joined())
            let w=try newWords()
            if !w.isEmpty {print("QF17 NOTE sentinel scenario \(name): \(w.count) unit(s) saved (sealed; checked below only for logs)")}
        }
        surfaces.append(contentsOf:DiagnosticsLog.shared.recent(100_000).filter {!logBefore.contains($0)})
        surfaces.append(coordinator.label);surfaces.append(coordinator.session.reason)
        surfaces.append(try raw())
        check(!surfaces.contains {$0.contains(sentinel) || $0.contains("zqxs")},"QF-17 sentinel: typed text appears in no log line, diagnostic, error or result string, or raw record")
        check(Set(diag().keys).isSubset(of:ChromeBracketDiagnostics.allowedKeys),"QF-17 B5: diagnostics carry only the pinned aggregate keys")

        check(ChromeJoinDesign.current == designBefore,"QF-17: the checks never changed the global design switch")
        try websiteTypingBracketedRealLoop(store:store,coordinator:coordinator,typingSwitch:typingSwitch)
        installFakeWebRoute()
        if !sourceBugs.isEmpty {print("QF-17 route checks: \(sourceBugs.count) known source bug(s) reported above")}
    }
    /// Busy-loop regressions on the REAL production scheduler path (coordinator blocker from QA): reads on a real serial
    /// queue (as `witness.queue.async`), results on `DispatchQueue.main.async`, pauses on `DispatchQueue.main.asyncAfter`,
    /// the real uptime clock, and the main run loop driven for 10 s per case. Each case bounds the join calls and the
    /// process's CPU time (getrusage user+sys over wall time). A spin fails; the watchdog stops a runaway case and fails it.
    static func websiteTypingBracketedRealLoop(store:MemoryStore,coordinator:Coordinator,typingSwitch:(Bool) throws -> Void) throws {
        final class Count {private let lock=NSLock();private var v=0;func add() {lock.lock();v+=1;lock.unlock()};var value:Int {lock.lock();defer {lock.unlock()};return v}}
        let keepAlive=Timer(timeInterval:3600,repeats:true) {_ in}
        RunLoop.main.add(keepAlive,forMode:.default)
        defer {keepAlive.invalidate()}
        let queue=DispatchQueue(label:"checks.chrome-typing.join")
        let liveFocus=NativeTypingRoute.keyFocus
        NativeTypingRoute.keyFocus={BracketFakeChrome.pid}
        defer {NativeTypingRoute.keyFocus=liveFocus}
        func cpuSeconds() -> Double {
            var u=rusage();getrusage(RUSAGE_SELF,&u)
            return Double(u.ru_utime.tv_sec)+Double(u.ru_utime.tv_usec)/1e6+Double(u.ru_stime.tv_sec)+Double(u.ru_stime.tv_usec)/1e6
        }
        func now() -> UInt64 {DispatchTime.now().uptimeNanoseconds}
        enum Change {case none,bump,typingOff,pause}
        for (name,setup,change,keyEvery) in [("secure input on, keys at the start",{(c:BracketFakeChrome) in c.secure=true},Change.none,0.0),
                                             ("secure input on, a key every 500 ms",{(c:BracketFakeChrome) in c.secure=true},.none,0.5),
                                             ("an immediate refusal before any Apple Event (untrusted target)",{(c:BracketFakeChrome) in c.facts.signatureValid=false},.none,0.0),
                                             ("a stale epoch (control bumped while reads run)",{(_:BracketFakeChrome) in},.bump,0.0),
                                             ("typing turned off while reads run",{(_:BracketFakeChrome) in},.typingOff,0.0),
                                             ("recording paused while reads run",{(_:BracketFakeChrome) in},.pause,0.0)] as [(String,(BracketFakeChrome)->Void,Change,Double)] {
            let chrome=BracketFakeChrome(url:"https://notes.example.org/pad/7?view=1#top")
            chrome.wait={ns in usleep(UInt32(ns/1000))}
            setup(chrome)
            let joins=Count(),aes=Count()
            let join=BrowserTypingJoin<WebFakeNode>(design:.bracketed)
            var env=WebTypingRoute.Environment(join:{pid,sites,enabled in
                joins.add()
                return join.join(environment:chrome.environment(now:now,enabled:enabled),appleEvents:{aes.add();return chrome.ae($0)},accessibility:chrome.access,
                                 blockList:sites.blockList,alwaysBlocked:sites.alwaysBlocked,sites:sites.permits(url:),field:sites.permits(url:field:))
            })
            env.secureInput={false};env.pressAndHold={true};env.secondsSinceMouseDown={nil};env.directKeyboardInput={true}
            env.design = .bracketed
            env.background={work in queue.async(execute:work)}
            env.toMain={work in DispatchQueue.main.async(execute:work)}
            env.keyIdentity={_ in nil}   // no key is ever held here: these cases are about the read loop only
            env.frontmostPID={BracketFakeChrome.pid}
            env.systemFocus={BracketFakeChrome.pid}
            WebTypingRoute.shared=WebTypingRoute(environment:env)
            let route=WebTypingRoute.shared
            func key() {_=route.handle(eventAt:now(),stroke:KeyStroke(keyCode:0),bundle:"com.google.Chrome",pid:BracketFakeChrome.pid,coordinator:coordinator,keyFocus:.some(BracketFakeChrome.pid)) {"k"}}
            let wallStart=Date(),cpuStart=cpuSeconds(),end=wallStart.addingTimeInterval(10)
            var nextKey=wallStart,changed=false,joinsAtChange=0,aborted=false
            for _ in 0..<3 {key()}
            while Date() < end {
                if keyEvery > 0, Date() >= nextKey {key();nextKey=nextKey.addingTimeInterval(keyEvery)}
                if change != .none, !changed, Date() >= wallStart.addingTimeInterval(1) {
                    changed=true;joinsAtChange=joins.value
                    switch change {
                    case .bump:route.control.bump()
                    case .typingOff:try typingSwitch(false)
                    case .pause:coordinator.pause("checks")
                    case .none:break
                    }
                }
                RunLoop.main.run(until:min(Date().addingTimeInterval(0.05),end))
                if joins.value > 2_000 {aborted=true;break}   // watchdog: a spin; reported as a FAIL below
            }
            let wall=Date().timeIntervalSince(wallStart),cpu=(cpuSeconds()-cpuStart)/wall
            // Let any read in flight finish before the next case replaces the route.
            queue.sync {};RunLoop.main.run(until:Date().addingTimeInterval(0.1))
            let after=joins.value-joinsAtChange
            print("QF17 METRIC busy-loop real scheduler (\(name)): joins=\(joins.value) appleEvents=\(aes.value) cpu=\(String(format:"%.2f",cpu*100))% wall=\(String(format:"%.1f",wall))s\(change == .none ? "" : " joinsAfterChange=\(after)")")
            check(!aborted,"busy-loop real scheduler (\(name)): the watchdog never fired (no spin)")
            if change == .none {
                check(joins.value > 0 && joins.value <= 40,"busy-loop: refused-before-AE reads are paced and bounded on the real scheduler (\(name): \(joins.value) joins in 10 s)")
            } else {
                check(changed && after <= 1,"busy-loop real scheduler (\(name)): after the change at most the read in flight completes (\(after) joins after)")
            }
            check(cpu < 0.05,"busy-loop real scheduler (\(name)): near-idle CPU (\(String(format:"%.2f",cpu*100))% < 5%)")
            check(route.bracketDiagnostics.balanced(sessionPending:route.burst.session.pendingUnits),
                  "QF-17 key accounting (busy-loop real scheduler, \(name)): admitted = saved + dropped + pending")
            switch change {
            case .typingOff:try typingSwitch(true)
            case .pause:try coordinator.start()
            default:break
            }
        }
    }
}
#endif
