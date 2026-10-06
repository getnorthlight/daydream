import Foundation
import PrivacyPolicy

@main struct NativeFocusChecks {
    static func main() {
        var count=0
        func check(_ value:Bool,_ label:String) {precondition(value,label);count+=1;print("PASS "+label)}
        final class Fake {
            var time:UInt64=1_000_000_000,clockCalls=0,delay:UInt64=0
            var permitted=true,identity:String?="signed-native-process-1",bundle="com.apple.TextEdit"
            var focused=1,window=3,reads=0,focusReads=0,identityReads=0,parentReads=0
            var flipFocus=false,flipProcess=false,reparent=false
            // PID the system-wide Accessibility element reports as focused. 7 is the
            // Notes/TextEdit fixture; 99 stands in for Spotlight or another panel.
            var keyFocus:Int32?=7,keyFocusReads=0,panelOpensAtRead:Int?=nil,unknownAtRead:Int?=nil
            var roles=[1:"AXTextArea",2:"AXGroup",3:"AXWindow"]
            var subroles=[1:"",2:"",3:""]
            var owners:[Int:Int32]=[1:7,2:7,3:7]
            var parents=[1:2,2:3]
            var access:NativeFocusAccess<Int> {
                NativeFocusAccess(now:{self.clockCalls+=1;return self.time+(self.clockCalls % 2 == 0 ? self.delay:0)},ready:{self.permitted},identity:{self.identityReads+=1;return self.flipProcess && self.identityReads % 2 == 0 ? "changed-process":self.identity},focusedApplication:{self.keyFocusReads+=1;if self.keyFocusReads==self.panelOpensAtRead {self.keyFocus=99};return self.keyFocus},window:{self.reads+=1;return self.window},focus:{self.focusReads+=1;return self.flipFocus && self.focusReads % 2 == 0 ? 9:self.focused},owner:{self.owners[$0]},role:{self.roles[$0]},subrole:{self.subroles[$0]},parent:{self.parentReads+=1;return self.reparent && self.parentReads>2 ? 9:self.parents[$0]},equal:{$0==$1})
            }
        }
        let fake=Fake(),reader=NativeFocusWitness<Int>()
        func read(_ f:Fake,_ r:NativeFocusWitness<Int>,generation:UInt64=1,excluded:Set<String>=[]) -> FocusProof? {
            r.read(pid:7,bundle:f.bundle,generation:generation,policyVersion:1,excluded:excluded,access:f.access)
        }
        // messages-1003: Messages replaces its composer's element while the person types. With Messages' rule a new
        // element of the same role, subrole and labels in the same window keeps the focus ID (one unit, no mid-word cut);
        // a search or To box, other labels, another window or another app never does.
        if CaptureGate.nativeApps.contains("com.apple.MobileSMS") {
            let m=Fake();m.bundle="com.apple.MobileSMS";let r=NativeFocusWitness<Int>()
            var labels:[Int:[String]]=[1:["iMessage"],4:["iMessage"],5:["Search"],6:["To:"],7:["Text Message"]]
            func mread() -> FocusProof? {
                var a=m.access;a.labels={labels[$0]};a.sameField={SendRules.messagesSameField(old:$0,new:$1)}
                return r.read(pid:7,bundle:m.bundle,generation:1,policyVersion:1,access:a)
            }
            for n in [4,5,6,7] {m.roles[n]="AXTextField";m.subroles[n]="";m.owners[n]=7;m.parents[n]=2}
            m.roles[1]="AXTextField"
            let composer=mread()!
            check(composer.nativeLabels == ["iMessage"],"messages-1003: Messages proofs carry the field's labels")
            m.focused=4;let replaced=mread()!
            check(replaced.focusID == composer.focusID && replaced.windowID == composer.windowID,"messages-1003: a replaced composer element keeps its focus ID")
            m.focused=5;let search=mread()!
            check(search.focusID != composer.focusID,"messages-1003: the search box never continues the composer")
            m.focused=1;let back=mread()!
            check(back.focusID != composer.focusID,"messages-1003: leaving to search and back starts a new field")
            m.focused=6;check(mread()!.focusID != back.focusID,"messages-1003: a To box never continues the composer")
            m.focused=1;let c2=mread()!;m.focused=7
            check(mread()!.focusID != c2.focusID,"messages-1003: different labels are a different field")
            labels[1]=nil;labels[4]=nil
            m.focused=1;let unread=mread()!;m.focused=4
            check(mread()!.focusID != unread.focusID,"messages-1003: unreadable labels never continue a field")
            let t=Fake();t.roles[4]="AXTextArea";t.subroles[4]="";t.owners[4]=7;t.parents[4]=2;let tr=NativeFocusWitness<Int>()
            var ta=t.access;ta.labels={_ in ["Body"]};ta.sameField=nil
            let tf=tr.read(pid:7,bundle:t.bundle,generation:1,policyVersion:1,access:ta)!;t.focused=4;ta=t.access;ta.labels={_ in ["Body"]}
            check(tr.read(pid:7,bundle:t.bundle,generation:1,policyVersion:1,access:ta)!.focusID != tf.focusID,"messages-1003: other apps never continue a replaced element")
        }
        let first=read(fake,reader)!,second=read(fake,reader)!
        check(first.windowID==second.windowID && first.focusID==second.focusID,"same exact native objects retain opaque identity")
        check(first.documentID.isEmpty && first.tabID.isEmpty && first.url.isEmpty,"native focus is not fabricated browser or document identity")
        fake.focused=4;fake.roles[4]="AXTextArea";fake.subroles[4]="";fake.owners[4]=7;fake.parents[4]=2
        let changed=read(fake,reader)!
        check(changed.windowID==first.windowID && changed.focusID != first.focusID,"distinct same-role fields never merge")
        let boundary=read(fake,reader,generation:2)!
        check(boundary.windowID != changed.windowID && boundary.focusID != changed.focusID,"generation boundary resets retained object identity")
        reader.invalidate();check(read(fake,reader,generation:2)!.focusID != boundary.focusID,"explicit invalidation clears identity")
        let steady=read(fake,reader,generation:2)!
        fake.delay=1_000_000_001;check(read(fake,reader,generation:2)==nil,"a slow read of the same field denies")
        fake.delay=0
        let recovered=read(fake,reader,generation:2)!
        check(recovered.focusID==steady.focusID && recovered.windowID==steady.windowID,"one failed read keeps the same field's identity")
        fake.keyFocus=nil
        let readsBeforeUnknown=fake.reads
        check(read(fake,reader,generation:2)==nil && fake.reads==readsBeforeUnknown,"unknown system focus denies before reading window metadata")
        fake.keyFocus=7
        let afterUnknown=read(fake,reader,generation:2)!
        check(afterUnknown.focusID==recovered.focusID && afterUnknown.windowID==recovered.windowID,"a fresh exact-object proof after unknown focus retains identity without reusing authorization")
        fake.subroles[4]="AXSecureTextField";check(read(fake,reader,generation:2)==nil,"the same field turned secure denies")
        fake.subroles[4]="";fake.focused=1
        check(read(fake,reader,generation:2)!.focusID != recovered.focusID,"after a failed read a different field still gets a new identity")
        for (label,configure) in [
            ("browser denied before native reads",{(f:Fake) in f.bundle="com.google.Chrome"}),
            ("unsupported app denied",{f in f.bundle="org.example.copy"}),
            ("missing permission or secure input denies",{f in f.permitted=false}),
            ("unverified process denies",{f in f.identity=nil}),
            ("wrong native PID denies",{f in f.owners[1]=8}),
            ("wrong ancestor PID denies",{f in f.owners[2]=8}),
            ("secure field denies",{f in f.subroles[1]="AXSecureTextField"}),
            ("secure ancestor denies",{f in f.subroles[2]="AXSecureTextField"}),
            ("unknown subrole response denies",{f in f.subroles[1]=nil}),
            ("embedded web ancestry denies",{f in f.roles[2]="AXWebArea"}),
            ("unknown focus role denies",{f in f.roles[1]=nil}),
            ("unreached window denies",{f in f.parents[2]=nil}),
            ("ancestry cycle denies",{f in f.parents[2]=1}),
            ("focus changes mid observation deny",{f in f.flipFocus=true}),
            ("process changes mid observation deny",{f in f.flipProcess=true}),
            ("reparented same field denies",{f in f.reparent=true}),
            ("slow native observations deny",{f in f.delay=1_000_000_001}),
            ("Spotlight-style panel holding key focus while the app stays frontmost denies",{f in f.keyFocus=99}),
            ("unknown system-wide key focus denies",{f in f.keyFocus=nil}),
            ("panel taking key focus during the observation denies",{f in f.panelOpensAtRead=2})
        ] {
            let f=Fake();configure(f);check(read(f,NativeFocusWitness<Int>())==nil,label)
            if f.bundle=="com.google.Chrome" {check(f.reads==0,"browser rejection acquires no native window metadata")}
        }
        let endUnknown=Fake(),endReader=NativeFocusWitness<Int>()
        let beforeEndUnknown=read(endUnknown,endReader)!
        endUnknown.unknownAtRead=endUnknown.keyFocusReads+2
        let baseAccess=endUnknown.access
        let endAccess=NativeFocusAccess(now:baseAccess.now,ready:baseAccess.ready,identity:baseAccess.identity,
            focusedApplication:{let pid=baseAccess.focusedApplication();return endUnknown.keyFocusReads==endUnknown.unknownAtRead ? nil:pid},
            window:baseAccess.window,focus:baseAccess.focus,owner:baseAccess.owner,role:baseAccess.role,subrole:baseAccess.subrole,parent:baseAccess.parent,equal:baseAccess.equal)
        check(endReader.read(pid:7,bundle:endUnknown.bundle,generation:1,policyVersion:1,access:endAccess)==nil,"unknown system focus at the final read denies the entire proof")
        let afterEndUnknown=read(endUnknown,endReader)!
        check(afterEndUnknown.focusID==beforeEndUnknown.focusID && afterEndUnknown.windowID==beforeEndUnknown.windowID,"a fresh proof after final-read uncertainty retains exact object identity")
        let excluded=Fake();check(read(excluded,NativeFocusWitness<Int>(),excluded:[excluded.bundle])==nil && excluded.reads==0,"explicit exclusion rejects before metadata")
        let panel=Fake();panel.keyFocus=99
        check(read(panel,NativeFocusWitness<Int>())==nil && panel.reads==0 && panel.focusReads==0,"key focus elsewhere rejects before any window or field read")
        let returning=Fake(),kept=NativeFocusWitness<Int>()
        let before=read(returning,kept)!
        returning.keyFocus=99;check(read(returning,kept)==nil,"panel focus fails the proof")
        returning.keyFocus=7;let after=read(returning,kept)!
        check(after.focusID != before.focusID && after.windowID != before.windowID,"returning from a panel starts a new identity, never continuing the old one")
        // Live test (build 7): the Messages composer as macOS 26 reports it (read-only AX walk on macOS 26): an
        // AXTextField described "Message" with no subrole (kAXErrorNoValue, read as ""), four AXGroups, the Catalyst
        // "iOSContentGroup", then the AXStandardWindow. The proof holds wherever the build allows Messages (every
        // release: the owner flags); a secure field there is still refused.
        func messages() -> Fake {
            let f=Fake();f.bundle="com.apple.MobileSMS"
            f.roles=[1:"AXTextField",2:"AXGroup",3:"AXGroup",4:"AXGroup",5:"AXGroup",6:"AXGroup",7:"AXWindow"]
            f.subroles=[1:"",2:"",3:"",4:"",5:"",6:"iOSContentGroup",7:"AXStandardWindow"]
            f.owners=[1:7,2:7,3:7,4:7,5:7,6:7,7:7];f.parents=[1:2,2:3,3:4,4:5,5:6,6:7];f.window=7
            return f
        }
        let composer=read(messages(),NativeFocusWitness<Int>())
        var gatePolicy=CapturePolicy();gatePolicy.typedText=true
        if CaptureGate.nativeApps.contains("com.apple.MobileSMS") {
            check(composer?.role == "AXTextField" && composer?.subrole == "" && composer?.surface == .native,"Messages composer (AXTextField \"Message\", Catalyst groups) is proven")
            check(composer.map { CaptureGate.typing($0,policy:gatePolicy,generation:1,now:$0.checkedAt).outcome == .allowed } == true,"Messages composer passes the typing gate")
        } else {
            check(composer == nil,"public build: Messages is not in this build's allowlist")
        }
        let secureComposer=messages();secureComposer.subroles[1]="AXSecureTextField"
        check(read(secureComposer,NativeFocusWitness<Int>())==nil,"a secure field in Messages is still refused")
        let noIdentity=messages();noIdentity.identity=nil
        check(read(noIdentity,NativeFocusWitness<Int>())==nil,"Messages with no process identity is refused (the identity must be read)")
        var policy=CapturePolicy();policy.typedText=true
        check(CaptureGate.typing(first,policy:policy,generation:1,now:first.checkedAt).outcome == .allowed,"production witness feeds existing native privacy gate")
        policy.typedText=false
        check(CaptureGate.typing(first,policy:policy,generation:1,now:first.checkedAt).outcome == .blocked,"valid witness never grants typed consent")
        count+=WebContentChecks.run()
        print("\(count) native and web-content witness checks passed. Synthetic OS objects only; no AX, tap or recording.")
    }
}

/// typing-all apps track: the "vendor app with web content" proof, the
/// once-per-process AXManualAccessibility switch, the launcher-panel route and
/// a synthetic cost benchmark. Fake AX trees only.
enum WebContentChecks {
    static var count=0
    static func check(_ value:Bool,_ label:String) {precondition(value,label);count+=1;print("PASS web: "+label)}
    /// The owner build's web-content apps (the public build has none).
    static let owner:Set<String>=["com.anthropic.claudefordesktop","com.openai.codex","com.apple.mail"]
    /// An Electron-like tree: 1 window, 2 group, 3 web area, then `depth`
    /// groups, then the field (the highest id). Every read is counted.
    final class Tree {
        var time:UInt64=1_000_000_000,clockCalls=0,delay:UInt64=0
        var permitted=true,identity:String?="signed-web-process-1",keyFocus:Int32?=7
        var roles:[Int:String]=[:],subroles:[Int:String]=[:],owners:[Int:Int32]=[:],parents:[Int:Int]=[:]
        var editable:[Int:Bool]=[:],urls:[Int:String]=[:],labels:[Int:String]=[:],unreadableLabel:Set<Int>=[]
        var window=1,focused=0,reads=0,urlReads=0,labelReads=0
        var urlAfter:(reads:Int,url:String)?=nil,reparentAfter:Int?=nil,parentReads=0
        init(depth:Int=6,url:String?="https://claude.ai/new",fieldRole:String="AXTextArea") {
            roles[1]="AXWindow";roles[2]="AXGroup";roles[3]="AXWebArea";parents[2]=1;parents[3]=2
            if let url {urls[3]=url}
            var last=3
            for i in 0..<depth {let id=4+i;roles[id]="AXGroup";parents[id]=last;last=id}
            focused=last+1;roles[focused]=fieldRole;parents[focused]=last;editable[focused]=true
            for id in roles.keys {owners[id]=7;subroles[id]=""}
        }
        func addField(_ id:Int,parent:Int,role:String="AXTextArea") {roles[id]=role;subroles[id]="";owners[id]=7;parents[id]=parent;editable[id]=true}
        var access:WebContentAccess<Int> {
            WebContentAccess(base:NativeFocusAccess(now:{self.clockCalls+=1;return self.time+(self.clockCalls % 2 == 0 ? self.delay:0)},ready:{self.permitted},identity:{self.identity},
                focusedApplication:{self.reads+=1;return self.keyFocus},window:{self.reads+=1;return self.window},focus:{self.reads+=1;return self.focused},
                owner:{self.reads+=1;return self.owners[$0]},role:{self.reads+=1;return self.roles[$0]},subrole:{self.reads+=1;return self.subroles[$0]},
                parent:{self.reads+=1;self.parentReads+=1
                    if let after=self.reparentAfter,self.parentReads>after,$0==self.focused {return 999}
                    return self.parents[$0]},equal:{$0==$1}),
                editable:{self.reads+=1;return self.editable[$0]},
                url:{self.reads+=1;self.urlReads+=1
                    if let change=self.urlAfter,self.urlReads>change.reads {return .some(change.url)}
                    return self.urls[$0] == "unreadable" ? nil : .some(self.urls[$0])},
                // Four attributes a label (placeholder, description, DOM id, classes); nil: one failed to read.
                label:{self.reads+=4;self.labelReads+=1;return self.unreadableLabel.contains($0) ? nil : (self.labels[$0] ?? "")})
        }
    }
    static func read(_ t:Tree,_ w:WebContentFocusWitness<Int>,bundle:String="com.anthropic.claudefordesktop",allowed:Set<String>=owner,generation:UInt64=1,excluded:Set<String>=[]) -> FocusProof? {
        w.read(pid:7,bundle:bundle,generation:generation,policyVersion:1,allowed:allowed,excluded:excluded,access:t.access)
    }
    static func run() -> Int {
        // A narrow (unflagged) build reads no web-content app at all. Every release stage compiles the owner
        // typing flags (public-typing/v1), so the release reads the owner table's web-content apps and panels.
        let narrow=TypingCategories.captureApps(expanded:false,probeBuild:false)
        let shipped=TypingCategories.captureApps(expanded:true,probeBuild:true)
        check(narrow.webContent.isEmpty && narrow.keyPanels.isEmpty,"narrow build: no web-content app and no launcher panel is allowed")
        check(OwnerTyping.enabled ? CaptureGate.webContentApps == shipped.webContent && CaptureGate.keyPanelApps == shipped.keyPanels && !shipped.webContent.isEmpty
                                  : CaptureGate.webContentApps.isEmpty && CaptureGate.keyPanelApps.isEmpty,
              "this build's web-content apps and panels are its table's (\(OwnerTyping.enabled ? "release, flagged" : "narrow, unflagged"))")
        let pub=Tree()
        check(WebContentFocusWitness<Int>().read(pid:7,bundle:"com.anthropic.claudefordesktop",generation:1,policyVersion:1,allowed:narrow.webContent,access:pub.access)==nil && pub.reads==0,
              "narrow build: Claude is refused before any Accessibility read")
        // Terminal in a narrow build; iTerm2 (its signer is unconfirmed, so it is closed in every build) in the release.
        let closed=CaptureGate.nativeApps.contains("com.apple.Terminal") ? "com.googlecode.iterm2" : "com.apple.Terminal"
        let pubNative=Tree()
        check(!CaptureGate.nativeApps.contains(closed) && NativeFocusWitness<Int>().read(pid:7,bundle:closed,generation:1,policyVersion:1,access:pubNative.access.base)==nil && pubNative.reads==0,
              "an app outside this build's list (\(closed)) is refused by the native witness before any read")

        // The vendor's own page, one editable field.
        let t=Tree(),w=WebContentFocusWitness<Int>()
        let first=read(t,w)!
        check(first.surface == .embeddedWeb && first.url.isEmpty && first.role=="AXTextArea" && first.verified && first.frameAccessible && first.navigationStable,
              "Claude: an editable field in claude.ai passes as web content, with no URL in the proof")
        var policy=CapturePolicy();policy.typedText=true
        let ownerApps=TypingCategories.captureApps(expanded:true,probeBuild:true)
        check(CaptureGate.typing(first,policy:policy,generation:1,now:first.checkedAt,apps:ownerApps).outcome == .allowed,"owner build: the web-content proof passes the capture gate")
        check(CaptureGate.typing(first,policy:policy,generation:1,now:first.checkedAt,apps:narrow).reason == .browserTypingOff,"narrow build: the same proof is refused by the gate")
        check((CaptureGate.typing(first,policy:policy,generation:1,now:first.checkedAt).outcome == .allowed) == OwnerTyping.enabled,"this build's own gate agrees with its table")
        let second=read(t,w)!
        check(second.focusID==first.focusID && second.windowID==first.windowID && w.fullWalks==1,"the same field keeps its identity and is not walked again")
        t.addField(50,parent:t.focused-1)
        t.focused=50
        let other=read(t,w)!
        check(other.focusID != first.focusID && other.windowID==first.windowID && w.fullWalks==2,"another field in the same window gets a new identity and a full walk")
        // A native app can reuse the exact AX field for multiple web documents.
        // These are opaque boundaries, not persisted URLs or guessed thread names.
        let threadTree=Tree(url:"https://claude.ai/chat/thread-a"),threadWitness=WebContentFocusWitness<Int>()
        let threadA=read(threadTree,threadWitness)!
        let threadARepeat=read(threadTree,threadWitness)!
        check(threadARepeat.focusID==threadA.focusID && threadARepeat.windowID==threadA.windowID,
              "same embedded web document and AX field retain identity")
        threadTree.urls[3]="https://claude.ai/chat/thread-b"
        let threadB=read(threadTree,threadWitness)!
        check(threadB.focusID != threadA.focusID && threadB.windowID==threadA.windowID && threadWitness.fullWalks==1,
              "same AX composer navigating to another admitted thread splits identity on the cheap path")
        check(UUID(uuidString:threadB.focusID) != nil && threadB.url.isEmpty && threadB.documentID.isEmpty && threadB.tabID.isEmpty,
              "thread discriminator is opaque; no raw URL or invented browser IDs enter the proof")
        threadTree.urls[3]="https://claude.ai/chat/thread-a"
        check(read(threadTree,threadWitness)!.focusID != threadB.focusID,
              "returning to an earlier thread starts a fresh capture boundary")
        let tokenTree=Tree(url:"https://claude.ai/chat/thread-a?token=secret#private"),tokenWitness=WebContentFocusWitness<Int>()
        let tokenProof=read(tokenTree,tokenWitness)!
        check(tokenProof.url.isEmpty && tokenProof.documentID.isEmpty && UUID(uuidString:tokenProof.focusID) != nil,
              "admitted query and fragment metadata remain transient and never persist")
        tokenTree.urls[3]="https://claude.ai/chat/thread-a?token=different#other"
        check(read(tokenTree,tokenWitness)!.focusID != tokenProof.focusID,
              "changed admitted query or fragment creates an opaque boundary without changing admission")
        let areaTree=Tree(url:"https://claude.ai/chat/thread-a"),areaWitness=WebContentFocusWitness<Int>()
        let areaBefore=read(areaTree,areaWitness)!
        areaTree.roles[30]="AXWebArea";areaTree.subroles[30]="";areaTree.owners[30]=7;areaTree.parents[30]=2
        areaTree.urls[30]=areaTree.urls[3];areaTree.parents[4]=30;areaTree.time+=2_100_000_000
        let areaAfter=read(areaTree,areaWitness)!
        check(areaAfter.focusID != areaBefore.focusID && areaAfter.windowID==areaBefore.windowID,
              "different retained web area splits identity even at the same admitted URL")
        let midThread=Tree(url:"https://claude.ai/chat/thread-a")
        midThread.urlAfter=(1,"https://claude.ai/chat/thread-b")
        check(read(midThread,WebContentFocusWitness<Int>())==nil,
              "navigation between URL reads is still refused even when both threads are admitted")
        threadTree.urls[3]="https://example.com/chat/thread-b"
        check(read(threadTree,threadWitness)==nil,"a reused composer on an untrusted host remains refused")
        threadTree.urls[3]="unreadable"
        check(read(threadTree,threadWitness)==nil,"an unreadable reused thread URL remains refused")
        threadTree.urls[3]="http://claude.ai/chat/thread-b"
        check(read(threadTree,threadWitness)==nil,"a reused composer on an unapproved scheme remains refused")
        threadTree.urls[3]="https://claude.ai/chat/thread-b";threadTree.subroles[threadTree.focused]="AXSecureTextField"
        check(read(threadTree,threadWitness)==nil,"same thread and AX field never override secure-field refusal")
        // ChatGPT (Codex app): bundled UI yes, its built-in browser no.
        check(read(Tree(url:"app://-/index.html"),WebContentFocusWitness<Int>(),bundle:"com.openai.codex") != nil,"ChatGPT: a field in the app's bundled page passes")
        check(read(Tree(url:"https://chatgpt.com/"),WebContentFocusWitness<Int>(),bundle:"com.openai.codex")==nil,"ChatGPT: a page in its built-in browser is refused")
        for (label,url) in [("another host","https://example.com/login"),("plain http","http://claude.ai/"),("a look-alike host","https://claude.ai.example.com/"),
                            ("credentials in the URL","https://user:pw@claude.ai/"),("a data URL","data:text/html,hi"),("no URL","")] {
            let tree=Tree(url:url.isEmpty ? nil:url)
            check(read(tree,WebContentFocusWitness<Int>())==nil,"Claude: a page from \(label) is refused")
        }
        let unreadable=Tree(url:"unreadable");check(read(unreadable,WebContentFocusWitness<Int>())==nil,"an unreadable page URL is refused")
        // Frames, secure fields, non-editable content.
        let frame=Tree(depth:6);frame.roles[5]="AXWebArea";frame.urls[5]="https://claude.ai/embed"
        check(read(frame,WebContentFocusWitness<Int>())==nil,"a field inside a frame (two web areas) is refused")
        let secure=Tree();secure.subroles[secure.focused]="AXSecureTextField"
        check(read(secure,WebContentFocusWitness<Int>())==nil,"a password field (secure subrole) is refused")
        let secureRole=Tree();secureRole.roles[secureRole.focused]="AXSecureTextField"
        check(read(secureRole,WebContentFocusWitness<Int>())==nil,"a secure text field role is refused")
        let secureAncestor=Tree();secureAncestor.subroles[5]="AXSecureTextField"
        check(read(secureAncestor,WebContentFocusWitness<Int>())==nil,"a secure ancestor is refused")
        let notEditable=Tree();notEditable.editable[notEditable.focused]=false
        check(read(notEditable,WebContentFocusWitness<Int>())==nil,"a non-editable node is refused")
        let editUnknown=Tree();editUnknown.editable[editUnknown.focused]=nil
        check(read(editUnknown,WebContentFocusWitness<Int>())==nil,"an unreadable editable state is refused")
        let wholeArea=Tree();wholeArea.focused=3;wholeArea.editable[3]=true
        check(read(wholeArea,WebContentFocusWitness<Int>())==nil,"a whole web area is not a field in Claude")
        let pwLabel=Tree();pwLabel.labels[pwLabel.focused]="Enter your password"
        let labeled=read(pwLabel,WebContentFocusWitness<Int>())!
        check(labeled.fieldLabel=="Enter your password" && CaptureGate.typing(labeled,policy:policy,generation:1,now:labeled.checkedAt,apps:ownerApps).reason == .sensitiveField,
              "a field labelled as a password is refused by the gate as a sensitive field (discarded)")
        let longLabel=Tree();longLabel.labels[longLabel.focused]=String(repeating:"密",count:200)
        let clipped=read(longLabel,WebContentFocusWitness<Int>())!
        check(clipped.fieldLabel.utf8.count<=256 && CaptureGate.typing(clipped,policy:policy,generation:1,now:clipped.checkedAt,apps:ownerApps).outcome == .allowed,"a long label is clipped to the gate's 256-byte limit")
        // gold/int S2 (P1): embedded-web sensitive fields conveyed only by placeholder, description, DOM id or class
        // on a generic text field; the label must read without error, fresh for every key, judged in full.
        for (what,text) in [("placeholder \"Password\"","Password"),("description \"one-time code\"","one-time code"),
                            ("DOM id \"otp\"","otp"),("class \"password-input\"","composer password-input")] {
            for role in ["AXTextField","AXTextArea"] {
                let t=Tree(fieldRole:role);t.labels[t.focused]=text
                guard let p=read(t,WebContentFocusWitness<Int>()) else {check(false,"S2: \(what) on \(role) still proves");continue}
                check(CaptureGate.typing(p,policy:policy,generation:1,now:p.checkedAt,apps:ownerApps).reason == .sensitiveField,
                      "S2: a generic \(role) with \(what) is refused as a sensitive field (discarded)")
            }
        }
        let failedLabel=Tree();failedLabel.unreadableLabel=[failedLabel.focused]
        check(read(failedLabel,WebContentFocusWitness<Int>())==nil,"S2: a label attribute that fails to read refuses the field (never an empty, clean label)")
        let failsLater=Tree(),flw=WebContentFocusWitness<Int>()
        _=read(failsLater,flw)!;failsLater.time+=10_000_000;failsLater.unreadableLabel=[failsLater.focused]
        check(read(failsLater,flw)==nil,"S2: the same field whose label then fails to read is refused on the next key (no cached label)")
        let changes=Tree(),cw=WebContentFocusWitness<Int>()
        let clean=read(changes,cw)!
        check(CaptureGate.typing(clean,policy:policy,generation:1,now:clean.checkedAt,apps:ownerApps).outcome == .allowed,"S2: an unlabelled message field is allowed")
        changes.time+=100_000_000;changes.labels[changes.focused]="Enter the one-time code"
        let changed=read(changes,cw)!
        check(cw.fullWalks==1 && CaptureGate.typing(changed,policy:policy,generation:1,now:changed.checkedAt,apps:ownerApps).reason == .sensitiveField,
              "S2: the same field relabelled as a one-time code 100 ms later (inside the 2 s reuse) is refused at once")
        let tail=Tree();tail.labels[tail.focused]=String(repeating:"a",count:300)+" password"
        let tailProof=read(tail,WebContentFocusWitness<Int>())!
        check(tailProof.fieldLabel.utf8.count<=256 && !tailProof.fieldLabel.contains("password") && tailProof.fieldLabelDenied
              && CaptureGate.typing(tailProof,policy:policy,generation:1,now:tailProof.checkedAt,apps:ownerApps).reason == .sensitiveField,
              "S2: a sensitive word after byte 256 still refuses the field (judged before the label is clipped for storage)")
        let tailClasses=Tree();tailClasses.labels[tailClasses.focused]=(0..<40).map{"tw-class-\($0)"}.joined(separator:" ")+" otp-input"
        let tcProof=read(tailClasses,WebContentFocusWitness<Int>())!
        check(CaptureGate.typing(tcProof,policy:policy,generation:1,now:tcProof.checkedAt,apps:ownerApps).reason == .sensitiveField,
              "S2: a long class list ending in otp-input is refused")
        let huge=Tree();huge.labels[huge.focused]=String(repeating:"b",count:5000)
        check(read(huge,WebContentFocusWitness<Int>())==nil,"S2: an oversized label (over \(WebContentFocusWitness<Int>.labelReadLimit) bytes) refuses the field")
        let longClean=Tree();longClean.labels[longClean.focused]=(0..<40).map{"tw-class-\($0)"}.joined(separator:" ")
        let lc=read(longClean,WebContentFocusWitness<Int>())!
        check(!lc.fieldLabelDenied && CaptureGate.typing(lc,policy:policy,generation:1,now:lc.checkedAt,apps:ownerApps).outcome == .allowed,
              "S2: a long, ordinary class list (over 256 bytes) is still allowed")
        let nativeField=Tree(depth:0);nativeField.roles[3]="AXGroup";nativeField.roles[nativeField.focused]="AXTextField";nativeField.unreadableLabel=[nativeField.focused]
        let np=read(nativeField,WebContentFocusWitness<Int>())
        check(np != nil && np!.surface == .native,"S2 is narrow: a native field (outside web content) whose label can't be read keeps its native rules")
        let retry=Tree(),rw=WebContentFocusWitness<Int>();retry.unreadableLabel=[retry.focused]
        check(read(retry,rw)==nil,"S2: one Accessibility hiccup on the label skips that key")
        retry.time+=40_000_000;retry.unreadableLabel=[]
        check(read(retry,rw) != nil,"S2: the next key reads the label again and is proved (no latch, nothing said)")
        check(LabelAttributeRead.join([.absent,.text("Search"),.list(["a","b"])]) == "Search a b" && LabelAttributeRead.join([.text("x"),.unreadable,.absent]) == nil
              && LabelAttributeRead.join([.absent,.absent]) == "","S2: the producer's join: absent attributes add nothing, any unreadable one makes the label unreadable")
        // Process, focus and timing rules shared with the native proof.
        for (label,configure) in [
            ("key focus in another process",{(x:Tree) in x.keyFocus=99}),
            ("unknown key focus",{x in x.keyFocus=nil}),
            ("an unverified process",{x in x.identity=nil}),
            ("missing permission or secure input",{x in x.permitted=false}),
            ("a field owned by another process",{x in x.owners[x.focused]=8}),
            ("an ancestor owned by another process",{x in x.owners[4]=8}),
            ("an unreadable ancestor role",{x in x.roles[4]=nil}),
            ("an ancestry cycle",{x in x.parents[4]=x.focused}),
            ("a window never reached",{x in x.parents[2]=nil}),
            ("a slow read",{x in x.delay=1_000_000_001}),
            ("navigation during the read",{x in x.urlAfter=(1,"https://example.com/")}),
            ("a field reparented during the read",{x in x.reparentAfter=3}),
        ] {let x=Tree();configure(x);check(read(x,WebContentFocusWitness<Int>())==nil,"refused: "+label)}
        let excluded=Tree();check(read(excluded,WebContentFocusWitness<Int>(),excluded:["com.anthropic.claudefordesktop"])==nil && excluded.reads==0,"an excluded app is refused before any read")
        let notAllowed=Tree();check(read(notAllowed,WebContentFocusWitness<Int>(),bundle:"com.tinyspeck.slackmacgap")==nil && notAllowed.reads==0,"Slack (signer not read yet) is refused before any read")
        // fix/app-coverage: a desktop chat app's composer names its channel or person (send facts only), as on the web.
        func chat(_ url:String,_ labels:[String]?,bundle:String="com.tinyspeck.slackmacgap",denied:String="") -> (FocusProof?,Int) {
            let t=Tree(url:url);if !denied.isEmpty {t.labels[t.focused]=denied}
            var asked=0,a=t.access;a.composerLabels={_ in asked+=1;return labels}
            return (WebContentFocusWitness<Int>().read(pid:7,bundle:bundle,generation:1,policyVersion:1,allowed:[bundle],access:a),asked)
        }
        let slackChannel=chat("https://app.slack.com/client/T01/C01",["Message #general",""])
        check(slackChannel.0?.surface == .embeddedWeb && slackChannel.0?.sendPlace == "#general","Slack app: \"Message #general\" names the channel")
        check(chat("https://app.slack.com/client/T01/D01",["Message Sam Lee"]).0?.sendPlace == "Sam Lee","Slack app: a DM composer names the person")
        check(chat("https://discord.com/channels/1/2",["Message @riley"],bundle:"com.hnc.Discord").0?.sendPlace == "riley","Discord app: \"Message @riley\" names the person")
        check(chat("https://app.slack.com/client/T01/C01",["Message 555 0101"]).0?.sendPlace == "","Slack app: a label with a number names nobody")
        let claudeAsked=chat("https://claude.ai/new",["Message Claude"],bundle:"com.anthropic.claudefordesktop")
        check(claudeAsked.0 != nil && claudeAsked.0?.sendPlace == "" && claudeAsked.1 == 0,"Claude app: not a chat host, its composer labels are never read")
        let deniedPlace=chat("https://app.slack.com/client/T01/C01",["Message #general"],denied:"one-time code")
        check(deniedPlace.0?.fieldLabelDenied == true && deniedPlace.0?.sendPlace == "" && deniedPlace.1 == 0,"Slack app: a sensitive field's labels are never read for a place")
        // fix/signers: Cursor (a VS Code fork; signer read 2026-09-28). Its workbench is one vscode-file page. Its integrated
        // terminal is xterm.js in that page and its code editor is Monaco: the witness proves the field (it is an editable
        // text area) and carries the full label, and the full-typing build's gate refuses it and discards its words.
        let cursor="com.todesktop.230313mzl4w4u92",cursorPage="vscode-file://vscode-app/Applications/Cursor.app/Contents/Resources/app/out/vs/code/electron-sandbox/workbench/workbench.html"
        check(TypingCategories.captureApps(expanded:true,probeBuild:true).webContent.contains(cursor),"Cursor: read through the web-content proof in the full-typing build")
        let cursorChat=Tree(url:cursorPage);cursorChat.labels[cursorChat.focused]="Plan, search, build anything aislash-editor-input"
        let cc=read(cursorChat,WebContentFocusWitness<Int>(),bundle:cursor,allowed:[cursor])
        check(cc?.surface == .embeddedWeb && cc?.fieldLabelDenied == false && CaptureGate.typing(cc!,policy:policy,generation:1,now:cc!.checkedAt,apps:ownerApps).outcome == .allowed,
              "Cursor: a text box in its own vscode-file page passes")
        for label in ["Terminal 1, zsh xterm-helper-textarea","xterm-helper-textarea","inputarea monaco-mouse-cursor-text","Editor content"] {
            let term=Tree(url:cursorPage);term.labels[term.focused]=label
            guard let tp=read(term,WebContentFocusWitness<Int>(),bundle:cursor,allowed:[cursor]) else {check(false,"Cursor: \(label) still proves");continue}
            check(tp.fieldLabel == label && tp.fieldLabelDenied == OwnerTyping.enabled
                  && (!OwnerTyping.enabled || CaptureGate.typing(tp,policy:policy,generation:1,now:tp.checkedAt,apps:ownerApps).reason == .sensitiveField),
                  "Cursor: its terminal or code editor (\(label)) \(OwnerTyping.enabled ? "is refused as a sensitive field (discarded)" : "carries its full label to the gate")")
        }
        let cursorWebview=Tree(depth:6,url:cursorPage);cursorWebview.roles[6]="AXWebArea";cursorWebview.urls[6]="vscode-webview://abc/index.html"
        check(read(cursorWebview,WebContentFocusWitness<Int>(),bundle:cursor,allowed:[cursor])==nil,"Cursor: a field in an extension webview (a second web area) is refused")
        check(read(Tree(url:"vscode-webview://abc/index.html"),WebContentFocusWitness<Int>(),bundle:cursor,allowed:[cursor])==nil
              && read(Tree(url:"https://cursor.com/settings"),WebContentFocusWitness<Int>(),bundle:cursor,allowed:[cursor])==nil,"Cursor: a webview or web page is refused")
        // fix/signers: Obsidian (signer read 2026-09-28): its bundled app://obsidian.md page, nothing else.
        check(read(Tree(url:"app://obsidian.md/index.html"),WebContentFocusWitness<Int>(),bundle:"md.obsidian",allowed:["md.obsidian"]) != nil
              && read(Tree(url:"https://obsidian.md/"),WebContentFocusWitness<Int>(),bundle:"md.obsidian",allowed:["md.obsidian"])==nil,
              "Obsidian: a field in its bundled page passes; a web page is refused")
        // Same field, later: the short check still catches a moved field.
        let moved=Tree(),mw=WebContentFocusWitness<Int>()
        _=read(moved,mw)!;moved.parents[moved.focused]=4
        check(read(moved,mw)==nil,"the same field under a new parent is refused (short check)")
        let navigated=Tree(),nw=WebContentFocusWitness<Int>()
        _=read(navigated,nw)!;navigated.urls[3]="https://example.com/"
        check(read(navigated,nw)==nil,"the same field after its page navigated away is refused (short check)")
        let panel=Tree(),pw=WebContentFocusWitness<Int>()
        let before=read(panel,pw)!;panel.keyFocus=99;check(read(panel,pw)==nil,"a panel taking key focus fails the proof")
        panel.keyFocus=7;check(read(panel,pw)!.focusID != before.focusID,"after a panel the field starts a new identity")
        let stale=Tree(),sw=WebContentFocusWitness<Int>()
        _=read(stale,sw)!;stale.time+=WebContentFocusWitness<Int>.fullWalkNanoseconds+1;_=read(stale,sw)!
        check(sw.fullWalks==2,"the ancestry is walked again after \(WebContentFocusWitness<Int>.fullWalkNanoseconds/1_000_000) ms")
        // Mail: native To and Subject fields, and the editable message body.
        let mailField=Tree(url:nil);mailField.roles[3]="AXGroup";mailField.roles[mailField.focused]="AXTextField"
        let native=read(mailField,WebContentFocusWitness<Int>(),bundle:"com.apple.mail")!
        check(native.surface == .native && CaptureGate.typing(native,policy:policy,generation:1,now:native.checkedAt,apps:ownerApps).outcome == .allowed,"Mail: a native field (To, Subject) gets the native rules")
        let body=Tree(url:nil);body.focused=3;body.editable[3]=true
        let mailBody=read(body,WebContentFocusWitness<Int>(),bundle:"com.apple.mail")!
        check(mailBody.surface == .embeddedWeb && mailBody.role=="AXWebArea" && CaptureGate.typing(mailBody,policy:policy,generation:1,now:mailBody.checkedAt,apps:ownerApps).outcome == .allowed,
              "Mail: the editable message body (a web area with no URL) passes")
        let viewer=Tree(url:nil);viewer.focused=3;viewer.editable[3]=false
        check(read(viewer,WebContentFocusWitness<Int>(),bundle:"com.apple.mail")==nil,"Mail: a message being read (not editable) is refused")
        let remote=Tree(url:"https://example.com/newsletter");remote.focused=3;remote.editable[3]=true
        check(read(remote,WebContentFocusWitness<Int>(),bundle:"com.apple.mail")==nil,"Mail: a web area with a web URL is refused")

        manualSwitch();enhancedSwitch();keyPanels();benchmark()
        return count
    }
    static func manualSwitch() {
        let s=ManualAccessibilitySwitch()
        var on=false,writes=0
        check(!s.ensure(identity:"7:1:com.anthropic.claudefordesktop",read:{on},write:{writes+=1;on=true;return true}) && writes==1,
              "first key: the tree is turned on and that key is not read (the app builds its tree)")
        var later=0
        for _ in 0..<10_000 where s.ensure(identity:"7:1:com.anthropic.claudefordesktop",read:{later+=1;return on},write:{writes+=1;return true}) {}
        check(writes==1 && later==0 && s.writes==1,"10,000 more keys: no more reads or writes of the switch (set once per process)")
        var foreignWrites=0
        check(s.ensure(identity:"9:1:com.openai.codex",read:{true},write:{foreignWrites+=1;return true}) && foreignWrites==0 && s.states["9:1:com.openai.codex"] == .theirs,
              "an app whose tree is already on (a screen reader) is left alone")
        var failedWrites=0
        check(!s.ensure(identity:"11:1:com.openai.codex",read:{nil},write:{failedWrites+=1;return false}) &&
              !s.ensure(identity:"11:1:com.openai.codex",read:{nil},write:{failedWrites+=1;return false}) && failedWrites==1,
              "an app that refuses the switch is not asked again and gets no typing")
        // Live test (build 7): ChatGPT (com.openai.codex) has no AXManualAccessibility (read and set both "unsupported").
        // Its own tree decides: nothing is written, and the proof reads under its usual rules, from the first key.
        var noSwitchWrites=0
        check(s.ensure(identity:"13:1:com.openai.codex",read:{nil},unsupported:{true},write:{noSwitchWrites+=1;return false}) &&
              s.ensure(identity:"13:1:com.openai.codex",read:{nil},unsupported:{true},write:{noSwitchWrites+=1;return false}) &&
              noSwitchWrites==0 && s.states["13:1:com.openai.codex"] == ManualAccessibilitySwitch.State.none,
              "an app without the switch (ChatGPT) is read at once and never written to")
        check(!s.ensure(identity:"15:1:com.openai.codex",read:{nil},unsupported:{false},write:{false}) && s.states["15:1:com.openai.codex"] == .failed,
              "an unreadable switch the app does have is still written once and a refusal still fails closed")
        check(!s.ensure(identity:"7:2:com.anthropic.claudefordesktop",read:{false},write:{true}) && s.writes==4,"a relaunched app (same PID, new launch) is asked once again")
        for i in 0..<100 {_=s.ensure(identity:"p\(i)",read:{false},write:{true})}
        check(s.states.count<=ManualAccessibilitySwitch.limit,"the switch remembers a bounded number of processes")
    }
    /// chatgpt-capture: ChatGPT (no AXManualAccessibility) gets AXEnhancedUserInterface once per process, and it goes
    /// back off where DayDream turned it on.
    static func enhancedSwitch() {
        let s=EnhancedUserInterfaceSwitch()
        var on=false,writes=0
        check(!s.ensure(identity:"21:1:com.openai.codex",read:{on},write:{writes+=1;on=true;return true}) && writes==1 && s.states["21:1:com.openai.codex"] == .ours,
              "enhanced: the first key turns ChatGPT's tree on and is not read")
        var later=0
        for _ in 0..<10_000 where s.ensure(identity:"21:1:com.openai.codex",read:{later+=1;return on},write:{writes+=1;return true}) {}
        check(writes==1 && later==0 && s.holdsAny,"enhanced: 10,000 more keys: no more reads or writes (set once per process)")
        var foreign=0
        check(s.ensure(identity:"23:1:com.openai.codex",read:{true},write:{foreign+=1;return true}) && foreign==0 && s.states["23:1:com.openai.codex"] == .theirs,
              "enhanced: already on (VoiceOver): never written")
        var refused=0
        check(!s.ensure(identity:"25:1:com.openai.codex",read:{false},write:{refused+=1;return false}) &&
              !s.ensure(identity:"25:1:com.openai.codex",read:{false},write:{refused+=1;return false}) && refused==1,
              "enhanced: a refusal is not asked again and gets no typing")
        // Restore: only what DayDream turned on, never VoiceOver's, nothing for a process that quit.
        var offs:[String]=[]
        let kept=s.restore(keep:{_ in true},running:{_ in true},assistiveOn:false,read:{_ in true},write:{offs.append($0);return true})
        check(kept.isEmpty && offs.isEmpty && s.states["21:1:com.openai.codex"] == .ours,"enhanced: restore keeps what is still allowed")
        let off=s.restore(running:{_ in true},assistiveOn:false,read:{_ in true},write:{offs.append($0);on=false;return true})
        check(off == ["21:1:com.openai.codex"] && offs == ["21:1:com.openai.codex"] && s.states["21:1:com.openai.codex"] == nil
              && s.states["23:1:com.openai.codex"] == .theirs && !s.holdsAny,
              "enhanced: recording or typing off turns it back off only where DayDream turned it on (VoiceOver's stays)")
        check(!s.ensure(identity:"21:1:com.openai.codex",read:{on},write:{writes+=1;on=true;return true}) && writes==2,
              "enhanced: allowed again, the next key turns it on again")
        let screenReader=s.restore(running:{_ in true},assistiveOn:true,read:{_ in true},write:{offs.append($0);return true})
        check(screenReader.isEmpty && offs.count==1 && s.states["21:1:com.openai.codex"] == .theirs,
              "enhanced: while VoiceOver is on it is left on and handed over")
        _=s.ensure(identity:"27:1:com.openai.codex",read:{false},write:{true})
        let gone=s.restore(running:{$0 != "27:1:com.openai.codex"},assistiveOn:false,read:{_ in true},write:{offs.append($0);return true})
        check(gone.isEmpty && offs.count==1 && s.states["27:1:com.openai.codex"] == nil,"enhanced: a quit process is forgotten, never written")
        _=s.ensure(identity:"29:1:com.openai.codex",read:{false},write:{true})
        let already=s.restore(running:{_ in true},assistiveOn:false,read:{_ in false},write:{offs.append($0);return true})
        check(already.isEmpty && offs.count==1 && s.states["29:1:com.openai.codex"] == nil,"enhanced: a value someone else turned off is not written")
        for i in 0..<100 {_=s.ensure(identity:"e\(i)",read:{false},write:{true})}
        check(s.states.count<=EnhancedUserInterfaceSwitch.limit,"enhanced: the switch remembers a bounded number of processes")
    }
    static func keyPanels() {
        let names:[Int32:String]=[7:"com.apple.Notes",42:"com.apple.Spotlight",99:"com.1password.1password"]
        let panels:Set<String>=["com.apple.Spotlight"]
        check(KeyPanelRoute.target(frontmost:7,keyFocus:42,bundle:{names[$0]},panels:[])==7,"narrow build: no panel is followed (keys stay with the frontmost app, whose proof fails)")
        check(KeyPanelRoute.target(frontmost:7,keyFocus:42,bundle:{names[$0]})==(OwnerTyping.enabled ? 42:7),"this build follows Spotlight only if its table has the panel")
        check(KeyPanelRoute.target(frontmost:7,keyFocus:42,bundle:{names[$0]},panels:panels)==42,"owner build: Spotlight's keys are proved against Spotlight's own process")
        check(KeyPanelRoute.target(frontmost:7,keyFocus:99,bundle:{names[$0]},panels:panels)==7,"a password manager's panel is never followed")
        check(KeyPanelRoute.target(frontmost:7,keyFocus:nil,bundle:{names[$0]},panels:panels)==7 && KeyPanelRoute.target(frontmost:7,keyFocus:7,bundle:{names[$0]},panels:panels)==7,
              "unknown or same key focus stays with the frontmost app")
        check(KeyPanelRoute.target(frontmost:7,keyFocus:43,bundle:{_ in nil},panels:panels)==7,"a panel process with no bundle is not followed")
    }
    /// Synthetic cost: Accessibility reads per key for an Electron-deep tree
    /// (EventCapture proves each key twice), the switch writes, and the time
    /// the rules themselves take. The app's own CPU for building its tree is
    /// a device measurement (MacBook test).
    static func benchmark() {
        let keys=10_000,depth=28
        let t=Tree(depth:depth),w=WebContentFocusWitness<Int>(),s=ManualAccessibilitySwitch()
        var on=false
        let started=DispatchTime.now().uptimeNanoseconds
        var proved=0
        for _ in 0..<keys {
            t.time+=40_000_000   // a fast typist: 25 keys a second
            if s.ensure(identity:"7:1:com.anthropic.claudefordesktop",read:{on},write:{on=true;return true}) {
                if read(t,w) != nil,read(t,w) != nil {proved+=1}
            }
        }
        let elapsed=DispatchTime.now().uptimeNanoseconds-started
        let perKey=Double(t.reads)/Double(keys)
        // A full walk every proof would cost two ancestry passes of (depth+3) nodes, 4 reads each.
        let naive=Double(2*(depth+3)*4)
        print(String(format:"BENCH web-content proof: depth %d, %d keys, %.1f AX reads/key (full walk each proof: %.0f+/proof), %d full walks, %d switch writes, %.2f us/key of rule time",
                     depth,keys,perKey,naive,w.fullWalks,s.writes,Double(elapsed)/Double(keys)/1000))
        check(proved==keys-1,"benchmark: every key after the first is proved")
        check(s.writes==1,"benchmark: AXManualAccessibility is written once for the whole run")
        check(w.fullWalks<=keys*40_000_000/Int(WebContentFocusWitness<Int>.fullWalkNanoseconds)+2,"benchmark: at most one full walk per \(WebContentFocusWitness<Int>.fullWalkNanoseconds/1_000_000) ms of typing")
        check(perKey<=48,"benchmark: at most 48 Accessibility reads per key (two proofs), well under a full walk per proof")
        check(Double(elapsed)/Double(keys)<200_000,"benchmark: under 0.2 ms of rule time per key")
    }
}
