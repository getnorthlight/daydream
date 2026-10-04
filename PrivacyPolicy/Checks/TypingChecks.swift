import Foundation
import PrivacyPolicy

/// Synthetic typed-unit checks: a fake clock, a fake focus model and a fake
/// host that drives TypingSession the way EventCapture does (key map, proof
/// before read, live commit with a fresh proof, parked commit after settle).
/// No event tap, AX, timer, store or real input is involved.
final class TypingHarness {
    struct Field {
        var bundle="com.apple.Notes", window="w1", id="f1", role="AXTextArea", subrole="", label=""
        /// The window title the proof carries (`FocusProof.place`).
        var place=""
    }
    var policy=CapturePolicy()
    let s:TypingSession
    var clock:UInt64=1_000_000_000_000
    var keyMap=TypingKeyMap()
    var pressAndHold=true
    var focus=Field()
    /// A proof that lags behind the real focus (the AX read still sees it).
    var lagging:Field?
    var proofReadable=true
    var departureReadable=true
    var secureInput=false
    private(set) var rows:[TypingCommit]=[]
    private(set) var markers:[String]=[]
    private(set) var outcomes:[TypingOutcome]=[]
    private(set) var reads=0
    private(set) var notWritten=0

    init(limits:TypingLimits=TypingLimits(),promptLatchApps:@escaping @Sendable (String)->Bool = TypingSession.tablePromptLatch,
         gate:TypingSession.Gate? = nil) {
        s=gate.map {TypingSession(limits:limits,promptLatchApps:promptLatchApps,gate:$0)} ?? TypingSession(limits:limits,promptLatchApps:promptLatchApps)
        policy.typedText=true
    }

    static func ns(_ seconds:Double) -> UInt64 {UInt64(seconds*1_000_000_000)}
    func proof() -> FocusProof? {
        guard proofReadable else {return nil}
        let f=lagging ?? focus
        var p=FocusProof()
        p.bundle=f.bundle;p.windowID=f.window;p.focusID=f.id;p.role=f.role;p.subrole=f.subrole;p.fieldLabel=f.label;p.place=f.place
        p.surface = .native;p.secureInput=secureInput ? .yes : .no;p.privateMode = .no
        p.verified=true;p.fieldStateVerified=true;p.frameAccessible=true;p.navigationStable=true
        p.generation=s.generation;p.policyVersion=policy.version;p.checkedAt=clock
        return p
    }
    func departure() -> DepartureState {
        DepartureState(secureInput:secureInput ? .yes : .no,bundle:focus.bundle,
                       focusSecure:departureReadable ? (focus.subrole == "AXSecureTextField" ? .yes : .no) : .unknown)
    }
    /// The store pre-check the binding runs (Privacy.secret's label rule).
    private func write(_ c:TypingCommit) -> Bool {
        if c.text.range(of:#"(?i)(password|passwd|pwd|secret|token|api[_-]?key)\s*[:=]"#,options:.regularExpression) != nil {notWritten+=1;return false}
        rows.append(c);return true
    }
    private func marker(_ kind:String) {
        guard let p=proof(),s.typingGate(p,policy,s.generation,clock).outcome == .allowed else {return}
        markers.append(kind)
    }

    // MARK: Timers

    func advance(_ seconds:Double) {
        let target=clock+Self.ns(seconds)
        var guardCount=0
        while let n=[s.idleDeadline,s.nextParkedDeadline,s.housekeepingDeadline].compactMap({$0}).min(),n<=target {
            guardCount+=1;precondition(guardCount<10_000,"timer loop")
            clock=max(clock,n)
            if let p=s.nextParkedDeadline,p<=clock {resolve()}
            else if let i=s.idleDeadline,i<=clock {live(.idle)}
            else {s.expire(now:clock)}
        }
        clock=target
    }
    func live(_ reason:SealReason) {
        guard let p=proof() else {s.seal(reason,now:clock,focusMoved:false);return}
        outcomes.append(s.commitLive(fresh:p,reason:reason,policy:policy,now:clock,write:write))
    }
    func resolve(force:Bool=false) {
        while let o=s.resolveParked(destination:TypingDestination(proof:proof(),departure:departure()),secureInput:secureInput,policy:policy,now:clock,force:force,write:write) {
            outcomes.append(o)
        }
    }
    /// Pause, stop, sleep: live commit, resolve everything now, then pause.
    func suspend() {
        live(.suspend);resolve(force:true)
        s.invalidate(.pause)
    }

    // MARK: Keys

    func key(_ k:KeyStroke,_ characters:String="",age:Double=0) {
        let eventAt=clock-Self.ns(age)
        guard age<=1 else {s.seal(.gap,now:clock,focusMoved:false);keyMap.reset();return}
        switch keyMap.intent(k,pressAndHold:pressAndHold) {
        case .consume: return
        case .noop(let m): if m {marker("keyboard.shortcut")}
        case .retract: s.retract();marker("keyboard.shortcut")
        case .redo: live(.cursor);marker("keyboard.shortcut")
        case .accent(let letter):
            guard let p=proof() else {s.unproven(now:clock);return}
            let step=s.apply(.deleteBackward(.character),proof:p,policy:policy,eventAt:eventAt,now:clock)
            guard step.commit == nil,step.decision.outcome == .allowed else {if let c=step.commit {live(c)};return}
            insert(eventAt:eventAt) {letter}
        case .leave(let r,let m):
            // Esc goes to the session's search-panel rule, as EventCapture does.
            if r == .focusKey,k.keyCode == 53 {s.escape(now:clock,proof:proof())}
            else if let e=TypingKeyMap.lineErase(k),s.eraseLine(e,now:clock) {}
            else {s.seal(TypingKeyMap.switchReason(k) ?? r,now:clock,focusMoved:true)}
            keyMap.reset();if m {marker("keyboard.shortcut")}
        case .split(let r): live(r)
        case .submit: live(.submit);marker("keyboard.submit")
        case .paste: live(.paste);marker("keyboard.shortcut")
        case .edit(let op):
            guard let p=proof() else {s.unproven(now:clock);return}
            if let c=s.apply(op,proof:p,policy:policy,eventAt:eventAt,now:clock).commit {live(c)}
        case .insertText(let t): insert(eventAt:eventAt) {t}
        case .insert(let dead): insert(eventAt:eventAt) {dead.map {$0.compose(characters)} ?? characters}
        }
    }
    private func insert(eventAt:UInt64,read:() -> String) {
        guard let p=proof() else {s.unproven(now:clock);return}
        let gate=s.typingGate(p,policy,s.generation,clock)
        guard gate.outcome == .allowed else {s.refuse(gate,now:clock);return}
        if s.admit(p,now:clock) != nil {return}
        reads+=1
        if let c=s.insert(read(),proof:p,policy:policy,eventAt:eventAt,now:clock).commit {live(c)}
    }
    func type(_ text:String,every gap:Double=0.08) {
        for c in text {
            advance(gap)
            if c == "\n" {key(KeyStroke(keyCode:36,shift:true))} else {key(KeyStroke(keyCode:0),String(c))}
        }
    }
    func press(_ code:Int64,times:Int=1,cmd:Bool=false,ctrl:Bool=false,opt:Bool=false,shift:Bool=false,gap:Double=0.08) {
        for _ in 0..<times {advance(gap);key(KeyStroke(keyCode:code,command:cmd,control:ctrl,option:opt,shift:shift))}
    }
    func click(to field:Field?=nil) {
        s.seal(.pointer,now:clock,focusMoved:true);keyMap.reset()
        if let field {focus=field}
    }
    /// One key whose proof cannot be read (an AX timeout). With `newIDs` the
    /// field comes back under new IDs (the old witness behaviour).
    func hiccup(_ c:Character,newIDs:Bool=false) {
        proofReadable=false;advance(0.08);key(KeyStroke(keyCode:0),String(c));proofReadable=true
        if newIDs {focus.window+="-b";focus.id+="-b"}
    }
    /// Cmd-Tab to `field` (app activation seals too).
    func switchApp(to field:Field) {
        press(48,cmd:true);focus=field;s.seal(.app,now:clock,focusMoved:true);keyMap.reset()
    }
    var texts:[String] {rows.map(\.text)}
}


enum TypingChecks {
    static func check(_ ok:Bool,_ label:String) {if !ok {fatalError("Typing check failed: "+label)}}
    /// Synthetic fixtures only: TYPING_DEBUG=1 prints a harness's rows to stderr.
    static func debug(_ h:TypingHarness) {
        guard ProcessInfo.processInfo.environment["TYPING_DEBUG"] != nil else {return}
        FileHandle.standardError.write(Data("rows=\(h.texts) outcomes=\(h.outcomes)\n".utf8))
    }
    static var passed=0
    static func pass(_ ok:Bool,_ label:String) {check(ok,label);passed+=1}
    static let backspace:Int64=51, left:Int64=123, right:Int64=124, up:Int64=126, down:Int64=125, tab:Int64=48, ret:Int64=36, esc:Int64=53
    /// Past every idle but the open-tail one (the send floor, 30 s), and past the open-tail idle (60 s).
    static let idle=31.0, long=61.0
    static let textEdit=TypingHarness.Field(bundle:"com.apple.TextEdit",window:"t1",id:"t1",role:"AXTextArea")
    static let safari=TypingHarness.Field(bundle:"com.apple.Safari",window:"sw",id:"sf",role:"AXWebArea")
    /// No row contains any of `fragments`.
    static func clean(_ h:TypingHarness,_ fragments:[String]) -> Bool {!h.texts.contains {t in fragments.contains {t.contains($0)}}}

    static func run() throws {
        paragraphs();idleSeal();edits();caretModel();chat();departures();unconfirmed();probes();labels();sizes()
        suspendAndBoundaries();keyMap();latchAndContext();splitSecrets();numbers();prose();fifoAndGeneration();redaction();appGate();lateCut();lateBacklogs();try performance()
        print("PASS typed-unit session checks: \(passed) synthetic cases (fake clock, fake focus, no input values logged).")
    }

    /// typing-all apps track: the capture gate with each build's allowlists.
    /// The public build's are Notes and TextEdit only; the owner build's come
    /// from the same table with the gate open (`captureApps(expanded:probeBuild:)`).
    static func appGate() {
        let notesAndTextEdit:Set<String>=["com.apple.Notes","com.apple.TextEdit"]
        let owner=TypingCategories.captureApps(expanded:true,probeBuild:true)
        let narrow=TypingCategories.captureApps(expanded:false,probeBuild:false)
        pass(narrow.all == notesAndTextEdit && narrow.webContent.isEmpty && narrow.keyPanels.isEmpty,
             "apps: narrow build: the capture allowlist is Notes and TextEdit, with no web-content app and no panel")
        // public-typing/v1: every release stage compiles the owner typing flags, so the shipped build's lists are
        // the owner table's; a plain `swift build` (no flags) keeps the narrow lists.
        let built=OwnerTyping.enabled ? owner : narrow
        pass(CaptureGate.nativeApps == built.all && CaptureGate.webContentApps == built.webContent && CaptureGate.keyPanelApps == built.keyPanels,
             "apps: this build's capture allowlist is the \(OwnerTyping.enabled ? "shipped (flagged)" : "narrow (unflagged)") table")
        pass(TypingCategories.captureApps() == built && TypingCategories.captureApps().all == CaptureGate.nativeApps,
             "apps: the capture allowlist is the category table's allowed set")
        var policy=CapturePolicy();policy.typedText=true
        func proof(_ bundle:String,_ surface:AppSurface = .native,role:String="AXTextArea") -> FocusProof {
            var p=FocusProof();p.bundle=bundle;p.windowID="w";p.focusID="f";p.role=role;p.surface=surface;p.secureInput = .no;p.privateMode = .no
            p.verified=true;p.fieldStateVerified=true;p.frameAccessible=true;p.navigationStable=true;p.generation=1;p.policyVersion=1;p.checkedAt=100;return p
        }
        func gate(_ p:FocusProof,_ apps:TypingCaptureApps,_ policy:CapturePolicy) -> PrivacyDecision {CaptureGate.typing(p,policy:policy,generation:1,now:200,apps:apps)}
        func publicGate(_ p:FocusProof) -> PrivacyDecision {gate(p,narrow,policy)}
        func builtGate(_ p:FocusProof) -> PrivacyDecision {CaptureGate.typing(p,policy:policy,generation:1,now:200)}
        // Native first: Pages, Xcode, Terminal, Ghostty, Spotlight, Messages.
        for bundle in ["com.apple.Pages","com.apple.dt.Xcode","com.apple.Terminal","com.mitchellh.ghostty","com.apple.Spotlight","com.apple.MobileSMS","net.whatsapp.WhatsApp","com.openai.chat"] {
            pass(gate(proof(bundle),owner,policy).outcome == .allowed,"apps: owner build: a native proof in \(bundle) passes the gate")
            pass(publicGate(proof(bundle)).outcome != .allowed,"apps: narrow build: \(bundle) is refused")
            pass((builtGate(proof(bundle)).outcome == .allowed) == OwnerTyping.enabled,"apps: this build's own gate agrees with its table for \(bundle)")
        }
        // Then web content: Claude, ChatGPT, Mail, Obsidian and Cursor.
        for bundle in ["com.anthropic.claudefordesktop","com.openai.codex","com.apple.mail","md.obsidian","com.todesktop.230313mzl4w4u92"] {
            pass(gate(proof(bundle,.embeddedWeb),owner,policy).outcome == .allowed,"apps: owner build: a web-content proof in \(bundle) passes the gate")
            pass(publicGate(proof(bundle,.embeddedWeb)).reason == .browserTypingOff,"apps: narrow build: web content in \(bundle) is refused")
            pass((builtGate(proof(bundle,.embeddedWeb)).outcome == .allowed) == OwnerTyping.enabled,"apps: this build's own gate agrees with its table for web content in \(bundle)")
        }
        // Rows whose signer (or bundle ID) was never read stay closed in every build.
        for bundle in ["com.microsoft.Word","com.googlecode.iterm2","com.microsoft.VSCode","com.tinyspeck.slackmacgap","com.hnc.Discord","notion.id","com.raycast.macos","com.microsoft.Outlook","com.apple.iWork.Pages"] {
            let web=TypingCategories.app(bundle)?.support == .embeddedWeb
            pass(!owner.all.contains(bundle) && gate(proof(bundle,web ? .embeddedWeb:.native),owner,policy).outcome != .allowed,"apps: owner build: \(bundle) stays off until its signer is read")
        }
        pass(!owner.all.contains("dev.zed.Zed") && !owner.all.contains("dev.warp.Warp-Stable"),"apps: Zed and Warp (text not exposed) stay off")
        // Web content only where the build reads it through the web-content proof.
        pass(gate(proof("com.apple.Terminal",.embeddedWeb),owner,policy).reason == .browserTypingOff && gate(proof("com.apple.Notes",.embeddedWeb),owner,policy).reason == .browserTypingOff,
             "apps: web content in an app without the web-content proof is refused")
        pass(gate(proof("com.google.Chrome",.embeddedWeb),owner,policy).reason == .browserTypingOff && gate(proof("com.google.Chrome"),owner,policy).reason == .browserTypingOff,
             "apps: a browser is never an app with web content")
        pass(gate(proof("com.apple.mail",.embeddedWeb,role:"AXWebArea"),owner,policy).outcome == .allowed,"apps: Mail's editable message body (a web area) passes")
        pass(gate(proof("com.anthropic.claudefordesktop",.embeddedWeb,role:"AXWebArea"),owner,policy).outcome == .unknown && gate(proof("com.apple.mail",.native,role:"AXWebArea"),owner,policy).outcome == .unknown,
             "apps: a whole web area is a field only in Mail's message body")
        var secure=proof("com.anthropic.claudefordesktop",.embeddedWeb);secure.subrole="AXSecureTextField"
        pass(gate(secure,owner,policy).reason == .sensitiveField,"apps: a password field in an app's web content is refused (discarded)")
        for label in ["Password","one-time code","Card number"] {
            var labeled=proof("com.openai.codex",.embeddedWeb);labeled.fieldLabel=label
            pass(gate(labeled,owner,policy).reason == .sensitiveField,"apps: a field labelled \(label) is refused (discarded)")
        }
        // public-typing review: ChatGPT's integrated terminal is xterm.js, an ordinary editable text area in
        // the app's own page. Its input is refused like the Chrome join's web terminals, so a password typed
        // at a sudo prompt there is never kept (the prompt latch covers native terminals only).
        // Only the full-typing build (every release) reads app web content; a narrow build has no such path.
        pass(OwnerTyping.enabled ? CaptureGate.webTerminalWords.count == 5 : CaptureGate.webTerminalWords.isEmpty && CaptureGate.webContentApps.isEmpty,
             "apps: the web terminal words exist exactly where app web content is read")
        for label in ["Terminal input xterm-helper-textarea","xterm-helper-textarea","TERMINAL INPUT","inputarea monaco-mouse-cursor-text","Editor content"] where OwnerTyping.enabled {
            var terminal=proof("com.openai.codex",.embeddedWeb);terminal.fieldLabel=label
            pass(gate(terminal,owner,policy).reason == .sensitiveField && CaptureGate.typingDenyReasons.contains(.sensitiveField),
                 "apps: a terminal or code editor in an app's web content is refused and its words discarded: \(label)")
            var claude=proof("com.anthropic.claudefordesktop",.embeddedWeb);claude.fieldLabel=label
            pass(gate(claude,owner,policy).reason == .sensitiveField,"apps: the same field in Claude's web content is refused: \(label)")
            // fix/signers: Cursor (a VS Code fork, open since its signer was read) keeps VS Code's terminal and editor refusal.
            var cursor=proof("com.todesktop.230313mzl4w4u92",.embeddedWeb);cursor.fieldLabel=label
            pass(gate(cursor,owner,policy).reason == .sensitiveField,"apps: the same field in Cursor's web content is refused: \(label)")
        }
        var prompt=proof("com.openai.codex",.embeddedWeb);prompt.fieldLabel="Ask anything ProseMirror"
        pass(gate(prompt,owner,policy).outcome == .allowed,"apps: ChatGPT's own prompt box still passes the gate")
        var native=proof("com.apple.Terminal");native.fieldLabel="shell terminal"
        pass(gate(native,owner,policy).outcome == .allowed && TypingCategories.app("com.apple.Terminal")?.promptLatch == true,
             "apps: a native terminal is not refused by its label: the prompt latch covers it")
        var withURL=proof("com.anthropic.claudefordesktop",.embeddedWeb);withURL.url="https://claude.ai/new"
        pass(gate(withURL,owner,policy).outcome != .allowed,"apps: an app proof never carries a page URL")
        var frame=proof("com.anthropic.claudefordesktop",.embeddedWeb);frame.frameAccessible=false
        pass(gate(frame,owner,policy).outcome == .unknown,"apps: an unproven frame is refused")
        pass(gate(proof("com.1password.1password"),owner,policy).reason == .passwordManager && !owner.all.contains("com.apple.Passwords"),"apps: password managers are never typing apps")
        // The person's category choices: every category, Messages and email included, is on by default.
        var defaults=policy;defaults.excludedApps=TypingCategories.excludedBundles(on:{$0.defaultOn},expanded:true,probeBuild:true)
        for bundle in ["com.apple.Terminal","com.mitchellh.ghostty","com.apple.dt.Xcode"] {
            pass(gate(proof(bundle),owner,defaults).outcome == .allowed,"apps: Code is on by default: \(bundle)")
        }
        pass(gate(proof("com.apple.MobileSMS"),owner,defaults).outcome == .allowed && gate(proof("com.apple.mail",.embeddedWeb),owner,defaults).reason != .excludedApp,
             "apps: Messages and Mail are on by default")
        var messagesOff=policy;messagesOff.excludedApps=TypingCategories.excludedBundles(on:{$0 != .messagesAndEmail},expanded:true,probeBuild:true)
        pass(gate(proof("com.apple.MobileSMS"),owner,messagesOff).reason == .excludedApp && gate(proof("com.apple.mail",.embeddedWeb),owner,messagesOff).reason == .excludedApp,
             "apps: with Messages and email off, Messages and Mail are excluded before any character is read")
        // The vendor's own page (TypingWebContent.admits).
        let claude=TypingCategories.app("com.anthropic.claudefordesktop")!.web!,codex=TypingCategories.app("com.openai.codex")!.web!
        let mail=TypingCategories.app("com.apple.mail")!.web!,code=TypingCategories.app("com.microsoft.VSCode")!.web!
        pass(claude.admits(url:"https://claude.ai/new") && claude.admits(url:"https://www.claude.ai/") && !claude.admits(url:"https://claude.ai.example.com/")
             && !claude.admits(url:"http://claude.ai/") && !claude.admits(url:"https://example.com/") && !claude.admits(url:nil) && !claude.admits(url:"https://u:p@claude.ai/"),
             "apps: Claude's page is claude.ai over https, nothing else")
        pass(codex.admits(url:"app://-/index.html") && codex.admits(url:"file:///Applications/ChatGPT.app/x.html") && !codex.admits(url:"https://chatgpt.com/")
             && !codex.admits(url:"data:text/html,x") && !codex.admits(url:"javascript:void(0)") && !codex.admits(url:"about:blank"),
             "apps: ChatGPT's page is its bundled UI; its built-in browser pages are refused")
        pass(mail.admits(url:nil) && mail.admits(url:"") && !mail.admits(url:"https://example.com/") && !mail.admits(url:"about:blank") && !mail.admits(url:"file:///tmp/x.html"),
             "apps: Mail's message body has no URL; any page is refused")
        pass(code.admits(url:"vscode-file://vscode-app/workbench.html") && !code.admits(url:"file:///x") && !code.admits(url:"https://github.com/"),"apps: VS Code's page is its vscode-file UI")
        let cursorWeb=TypingCategories.app("com.todesktop.230313mzl4w4u92")!.web!,obsidian=TypingCategories.app("md.obsidian")!.web!
        pass(cursorWeb.admits(url:"vscode-file://vscode-app/Applications/Cursor.app/Contents/Resources/app/out/vs/code/electron-sandbox/workbench/workbench.html")
             && !cursorWeb.admits(url:"vscode-webview://abc/index.html") && !cursorWeb.admits(url:"https://cursor.com/") && !cursorWeb.admits(url:"file:///x"),
             "apps: Cursor's page is its vscode-file UI; webviews and web pages are refused")
        pass(obsidian.admits(url:"app://obsidian.md/index.html") && !obsidian.admits(url:"https://obsidian.md/") && !obsidian.admits(url:"about:blank"),
             "apps: Obsidian's page is its bundled app:// UI")
        pass(TypingCategories.apps.filter{$0.support == .embeddedWeb}.allSatisfy{$0.web != nil} && TypingCategories.apps.filter{$0.support != .embeddedWeb}.allSatisfy{$0.web == nil},
             "apps: exactly the web-content rows carry web-content rules")
        pass(!TypingCategories.releaseAllows(TypingApp("com.example.web","Example",.writing,.apple,.embeddedWeb),expanded:true,probeBuild:true),
             "apps: a web-content row without its rules is never allowed")
        pass(TypingCategories.apps.filter(\.keyPanel).allSatisfy{$0.category == .searchAndAI} && owner.keyPanels == ["com.apple.Spotlight"],"apps: only launcher panels (Spotlight) are key panels")
    }

    static func paragraphs() {
        let h=TypingHarness()
        let paragraph="Today I planned the garden beds, ordered seeds for the spring, and wrote down which tomatoes did well last year. "
        h.type(paragraph,every:0.05)            // about 6 s of typing
        h.advance(8)                            // a thinking pause, shorter than idle
        h.type("Next week I will build the trellis.",every:0.1)
        h.advance(idle)
        pass(h.rows.count == 1 && h.texts == [paragraph+"Next week I will build the trellis."],"a paragraph with an 8 s pause is one row")
        pass(h.rows[0].reason == .idle && h.rows[0].part == 1,"idle commit, first part")
        let pauses=TypingHarness()
        pauses.type("First sentence of my plan. ");pauses.advance(5);pauses.type("Second sentence adds detail. ");pauses.advance(6)
        pauses.type("Third sentence wraps it up.");pauses.advance(idle)
        pass(pauses.texts == ["First sentence of my plan. Second sentence adds detail. Third sentence wraps it up."],"C3: 5-6 s thinking pauses stay one row")
        let open=TypingHarness()
        open.type("half a thou",every:0.05);open.advance(12.5)
        pass(open.rows.isEmpty,"an open tail is not committed at the closed-tail idle")
        open.advance(3);pass(open.texts == ["half a thou"],"an open tail ending in a plain word commits whole after the mid-word idle")
        for text in ["Things to buy:","He said \"see you there.\"","Meeting moved to 3","Call Sam (tomorrow)","First, second,"] {
            let t=TypingHarness();t.type(text);t.advance(long)
            pass(t.texts == [text],"C4: a tail ending in punctuation or a short number is not split: \(t.texts.count) row")
        }
        let resume=TypingHarness()
        resume.type("Things to buy:");resume.advance(21);resume.type(" milk and eggs.");resume.advance(idle)
        pass(resume.texts == ["Things to buy: milk and eggs."],"C4: typing resumed after a 21 s pause joins the same row")
        let cut=TypingHarness()
        cut.type("the code Ab3x9",every:0.05);cut.advance(long)
        pass(cut.texts == ["the code [withheld]"],"PV2: a token that may be a secret cut off by the idle commit is withheld")
        cut.type("Qz ok.");cut.advance(idle)
        pass(cut.texts == ["the code [withheld]","[withheld] ok."] && cut.rows.map(\.part) == [1,2] && Set(cut.rows.map(\.runID)).count == 1,"PV2: its continuation is withheld too, same run")
    }

    /// Live test (build 7): a TextEdit draft was still unsaved 25 s after the last key (the idle was 30 s, 60 s mid-word),
    /// so rows, prompt rows and summaries missed it. Now a short pause commits (12 s at a natural stop, 15 s inside a plain
    /// word); a pause that splits a draft keeps its run, so a message typed with thinking pauses stays one draft.
    static func idleSeal() {
        let limits=TypingLimits()
        pass(limits.idleClosed == 12_000_000_000 && limits.idleWord == 15_000_000_000 && limits.idleOpen == 60_000_000_000
             && limits.idleSendFloor == 30_000_000_000 && limits.softRunJoin == 60_000_000_000,"idle: 12 s closed, 15 s mid-word, 60 s open, 30 s where Return sends, runs join for 60 s")
        let edit=TypingHarness();edit.focus=textEdit
        edit.type("lttextedit 011218 zebra");edit.advance(14.5)
        pass(edit.rows.isEmpty,"idle: a draft ending mid-word waits past 12 s")
        edit.advance(1)
        pass(edit.texts == ["lttextedit 011218 zebra"] && edit.rows[0].reason == .idle,"idle: the live test's TextEdit draft is saved 15 s after the last key (not after 60 s)")
        let stop=TypingHarness()
        stop.type("Pick up the kids at five. ");stop.advance(11.5)
        pass(stop.rows.isEmpty,"idle: 11.5 s at a natural stop is still one draft")
        stop.advance(1);pass(stop.texts == ["Pick up the kids at five. "],"idle: 12 s after a natural stop the draft is saved")
        // Pauses to think: pieces split by a pause continue one run (same runID, part + 1), even a 45 s pause.
        let think=TypingHarness()
        think.type("Dear Sam, I think we should");think.advance(20)
        think.type(" move the launch to Friday");think.advance(45)
        think.type(" and tell the team.");think.advance(idle)
        pass(think.rows.count == 3 && Set(think.rows.map(\.runID)).count == 1 && think.rows.map(\.part) == [1,2,3]
             && think.texts.joined() == "Dear Sam, I think we should move the launch to Friday and tell the team.",
             "idle: a message typed with 20 s and 45 s pauses is one run in three pieces, nothing lost at the seams")
        let apart=TypingHarness()
        apart.type("First note.");apart.advance(12+61)
        apart.type("Second, much later.");apart.advance(idle)
        pass(apart.rows.count == 2 && Set(apart.rows.map(\.runID)).count == 2,"idle: typing more than a minute after the split starts a new draft")
        let otherField=TypingHarness()
        otherField.type("One field.");otherField.advance(13);otherField.focus.id="f2"
        otherField.type("Another field.");otherField.advance(idle)
        pass(otherField.rows.count == 2 && Set(otherField.rows.map(\.runID)).count == 2,"idle: a split never continues into another field")
        // Where Return sends (Messages here, with the owner table's gate), a pause before the send doesn't take "sent" away.
        let owner=TypingCategories.captureApps(expanded:true,probeBuild:true)
        let text=TypingHarness(gate:{CaptureGate.typing($0,policy:$1,generation:$2,now:$3,apps:owner)})
        text.focus=TypingHarness.Field(bundle:"com.apple.MobileSMS",window:"m1",id:"m1",role:"AXTextField")
        text.type("see you at six");text.advance(20)
        pass(text.rows.isEmpty,"idle: a text still in the composer 20 s later is not split before its send")
        text.press(ret)
        pass(text.texts == ["see you at six"] && text.rows[0].reason == .submit,"idle: Return 20 s later sends it whole (the send is on the row)")
        text.type("running late");text.advance(idle)
        pass(text.texts == ["see you at six","running late"] && text.rows[1].reason == .idle,"idle: an unsent text is saved 30 s after the last key")
        // A label waiting for its value and the groups of one number keep the long idle (secrets stay one unit).
        let number=TypingHarness()
        number.type("card 4111 1111 ");number.advance(idle)
        pass(number.rows.isEmpty,"idle: a digit group keeps the 60 s idle")
        let label=TypingHarness()
        label.type("wifi password:");label.advance(idle)
        pass(label.rows.isEmpty,"idle: a label waiting for its value keeps the 60 s idle")
        let opaque=TypingHarness()
        opaque.type("the code Ab3x9");opaque.advance(20)
        pass(opaque.rows.isEmpty,"idle: a secret-shaped token keeps the 60 s idle")
    }

    static func edits() {
        let h=TypingHarness()
        h.type("Teh");h.press(backspace,times:3);h.type("The quikc");h.press(backspace,times:2);h.type("ck brown fox.")
        h.advance(idle)
        pass(h.texts == ["The quick brown fox."],"Backspace corrections are applied")
        let w=TypingHarness()
        w.type("hello wrold");w.press(backspace,opt:true);w.type("world")
        w.type("\nline two");w.press(backspace,cmd:true);w.type("second.")
        w.advance(idle)
        pass(w.texts == ["hello world\nsecond."],"Option-Backspace deletes a word, Cmd-Backspace deletes a short line")
        pass(w.markers.isEmpty,"edit chords write no marker")
        let wrapped=TypingHarness()
        let para="This is a long paragraph that would wrap across several visual lines in a Notes window of normal width. "
        wrapped.type(para,every:0.02);wrapped.type("last line mistake",every:0.02);wrapped.press(backspace,cmd:true);wrapped.type("fixed end.");wrapped.advance(idle)
        pass(wrapped.texts == [para+"last line mistake","fixed end."] && wrapped.rows.first?.reason == .cursor,"C2: Cmd-Backspace on a long line commits the text as typed, never a wrong deletion")
        let later=TypingHarness()
        later.type("Meet me at the libary tomorrow. ");later.advance(5);later.press(backspace,times:17);later.type("library tomorrow. ");later.advance(idle)
        pass(later.texts == ["Meet me at the library tomorrow. "],"C3: a correction 5 s after a sentence is applied")
        let afterIdle=TypingHarness()
        afterIdle.type("I will call Jon about it.");afterIdle.advance(idle);afterIdle.press(backspace,times:3,opt:true);afterIdle.type("John about it.");afterIdle.advance(idle)
        pass(afterIdle.texts == ["I will call Jon about it.","John about it."],"C3 (documented): a correction after the idle commit is a second row, not withheld")
        let word=TypingHarness()
        word.type("I will call Jon about it.");word.advance(5);word.press(backspace,times:3,opt:true);word.type("John about it.");word.advance(idle)
        pass(word.texts == ["I will call John about it."],"C3: Option-Backspace 5 s later is applied")
        let b=TypingHarness()
        b.press(backspace,times:2);b.type("abc");b.press(backspace,times:5);b.type("xyz.");b.advance(idle)
        pass(b.texts == ["xyz."],"Backspace before the run is ignored")
        let fwd=TypingHarness()
        fwd.type("abXcd");fwd.press(left,times:3);fwd.press(117);fwd.press(right,times:2);fwd.type(" ok.");fwd.advance(idle)
        pass(fwd.texts == ["abcd ok."],"forward delete inside the run")
    }

    static func caretModel() {
        let h=TypingHarness()
        h.type("See you tomorow at noon");h.press(left,times:10);h.type("r");h.press(right,times:10);h.type(".")
        h.advance(idle)
        pass(h.texts == ["See you tomorrow at noon."],"P7: in-run caret fix is one row")
        let u=TypingHarness()
        u.type("first line.");u.press(up);u.type("added above.");u.advance(idle)
        pass(u.texts == ["first line.","added above."],"up arrow splits into two rows")
        pass(u.rows.count == 2 && u.rows[0].proof.focusID == u.rows[1].proof.focusID && u.rows[0].proof.generation == u.rows[1].proof.generation,"split rows keep the same focusID")
        let sel=TypingHarness()
        sel.type("hello world");sel.press(left,opt:true,shift:true);sel.type("there.");sel.advance(idle)
        pass(sel.texts == ["hello there."],"a Shift-Option-Left selection is replaced")
        let out=TypingHarness()
        out.type("abc");out.press(left,times:4)
        pass(out.texts == ["abc"],"moving before the run commits it (cursor)")
    }

    static func chat() {
        let h=TypingHarness()
        h.type("hi");h.press(ret);h.type("how are you");h.press(ret);h.type("line one\nline two");h.press(ret)
        h.advance(5)
        pass(h.texts == ["hi","how are you","line one\nline two"],"chat: one row per message, Shift-Return stays inside")
        pass(h.markers.filter {$0 == "keyboard.submit"}.count == 3,"three submit markers")
        pass(Set(h.rows.map(\.runID)).count == 3,"each submit starts a new run")
    }

    static func departures() {
        let other=TypingHarness.Field(bundle:"com.example.Other",window:"o1",id:"o1",role:"AXTextArea")
        let a=TypingHarness()
        a.type("notes before switching");a.press(tab,cmd:true);a.focus=other
        a.advance(0.3);pass(a.rows.isEmpty,"Cmd-Tab: nothing before settle")
        a.advance(0.2);pass(a.texts == ["notes before switching"],"Cmd-Tab: a row after 0.4 s")
        pass(a.rows.first?.reason == .app,"Cmd-Tab seal reason (an app change since 2026-10-02: the terminal latch reads it as an interruption)")
        let pw=TypingHarness()
        pw.type("notes before switching");pw.press(tab,cmd:true);pw.focus.bundle="com.apple.Passwords";pw.advance(1)
        pass(pw.rows.isEmpty,"switching to Passwords: no row")
        let si=TypingHarness()
        si.type("notes before switching");si.press(tab,cmd:true);si.focus=other;si.advance(0.2);si.secureInput=true;si.advance(1)
        pass(si.rows.isEmpty,"secure input on before the deadline: no row")
        let sub=TypingHarness()
        sub.type("user name field");sub.press(tab);sub.focus.id="f2";sub.focus.subrole="AXSecureTextField";sub.advance(1)
        pass(sub.rows.isEmpty,"Tab into a secure field (proof): no row")
        let dep=TypingHarness()
        dep.type("user name field");dep.press(tab);dep.focus.id="f2";dep.focus.subrole="AXSecureTextField";dep.proofReadable=false;dep.advance(1)
        pass(dep.rows.isEmpty,"secure subrole in the same app (departure metadata): no row")
        let unk=TypingHarness()
        unk.type("user name field");unk.press(tab);unk.focus.id="f2";unk.proofReadable=false;unk.departureReadable=false;unk.advance(1)
        pass(unk.rows.isEmpty,"unreadable same-app focus: no row")
        let ok=TypingHarness()
        ok.type("first field text");ok.press(tab);ok.focus.id="f2";ok.advance(1)
        pass(ok.texts == ["first field text"],"Tab to a permitted field commits the old unit")
        let idleSecure=TypingHarness()
        idleSecure.type("draft while idle.");idleSecure.secureInput=true;idleSecure.advance(idle)
        pass(idleSecure.rows.isEmpty,"secure input while idle: no row")
        let late=TypingHarness()
        late.type("left behind");late.press(tab);late.focus.id="f2"
        late.clock+=TypingHarness.ns(3);late.resolve()
        pass(late.rows.isEmpty && late.outcomes.contains(.discarded(.staleProof)),"late resolution is discarded")
        let excluded=TypingHarness()
        excluded.type("going elsewhere");excluded.press(tab,cmd:true);excluded.focus=TypingHarness.Field(bundle:"com.example.Excluded",window:"x",id:"x")
        excluded.policy.excludedApps=["com.example.Excluded"];excluded.advance(1)
        pass(excluded.texts == ["going elsewhere"],"C9: leaving for an excluded app commits by departure metadata (the host does the same)")
    }

    static func unconfirmed() {
        let h=TypingHarness()
        var secure=h.focus;secure.id="pw";secure.subrole="AXSecureTextField"
        h.click(to:secure);h.lagging=TypingHarness.Field()   // the proof still shows the old field
        h.advance(0.05);h.key(KeyStroke(keyCode:0),"q")
        pass(h.s.hasLive,"a lagging proof starts an unconfirmed unit")
        h.advance(0.25);h.lagging=nil;var away=h.focus;away.id="f3";away.subrole="";h.click(to:away)
        h.advance(idle)
        pass(h.rows.isEmpty,"click into a secure field, lagging key, click away within 0.3 s: no row")
        let c=TypingHarness()
        c.type("before click. ");c.click();c.advance(0.05);c.type("after the click and more words.",every:0.05);c.advance(idle)
        pass(c.texts == ["before click. ","after the click and more words."],"a confirmed start after a click commits")
        let r=TypingHarness()
        r.click();r.advance(0.05);r.type("ok",every:0.05);r.press(ret,gap:0.05)
        pass(r.rows.isEmpty,"a live commit while unconfirmed waits")
        r.advance(0.5)
        pass(r.texts == ["ok"],"then commits with a proof of the same field")
        let moved=TypingHarness()
        moved.click();moved.advance(0.05);moved.type("ok",every:0.05);moved.press(ret,gap:0.05)
        moved.focus.id="elsewhere";moved.advance(0.5)
        pass(moved.rows.isEmpty,"unconfirmed and the field changed: no row")
        // C10 (documented): a reply typed and left inside the 0.4 s settle
        // after Cmd-Tab cannot be confirmed and is dropped.
        let quick=TypingHarness();let notes=quick.focus
        quick.type("alpha beta");quick.switchApp(to:textEdit);quick.type("ok",every:0.06);quick.switchApp(to:notes)
        quick.advance(1);quick.type("back in notes.");quick.advance(idle)
        pass(quick.texts == ["alpha beta","back in notes."],"C10: a burst inside the settle after a switch is dropped, the rest commits")
    }

    static func probes() {
        let p1=TypingHarness()
        p1.type("password: hun");p1.advance(2.5);p1.type("ter2 and more words");p1.advance(long)
        pass(p1.rows.isEmpty,"P1: split secret across a pause: no row")
        let p2=TypingHarness()
        p2.type("my code is Tr0ub");p2.advance(3);p2.type("4dor&3 ok");p2.advance(long)
        pass(clean(p2,["Tr0ub","4dor"]),"P2: no fragment of the secret is stored")
        pass(p2.texts.joined() == "my code is [withheld] ok","P2: the token typed across the pause is withheld")
        let p3=TypingHarness()
        p3.type("my wifi is ");p3.advance(1);p3.type("Xk9#mP2q");p3.advance(1);p3.type(" at home");p3.advance(long)
        pass(p3.texts.joined() == "my wifi is [withheld] at home","P3: the opaque token is withheld")
        let p4=TypingHarness()
        p4.type("Ship the MacBookPro16,1 units to Sam tomorrow.");p4.advance(idle)
        pass(p4.texts == ["Ship the [withheld] units to Sam tomorrow."],"P4: one token withheld, the rest kept")
        pass(p4.rows.first?.withheld == 1,"P4: withheld count")
        let p5=TypingHarness()
        p5.type("2026 ");p5.advance(1);p5.type("goals for the garden.");p5.advance(idle)
        pass(p5.texts == ["[withheld] goals for the garden."],"P5: a lone number typed as its own chunk is withheld")
        let p6=TypingHarness()
        p6.type("my password is hunter2 ok");p6.advance(long)
        pass(p6.rows.isEmpty,"P6: prose secret: no row")
        let key=TypingHarness()
        key.type("use sk-proj-abcdefghijklmnopqrstuvwxyz0123 today.");key.advance(idle)
        pass(key.rows.isEmpty,"API key pattern: no row")
        let email=TypingHarness()
        email.type("Mail Sam@example.com about ~/notes/Plan-2026.txt today.");email.advance(idle)
        pass(email.texts == ["Mail Sam@example.com about ~/notes/Plan-2026.txt today."],"emails and paths are not withheld")
    }

    static func labels() {
        let r=TypingHarness()
        r.type("password:");r.press(ret);r.type("hunter2");r.press(ret);r.advance(long)
        pass(r.rows.isEmpty,"password: then Return then hunter2: no row at all")
        let t=TypingHarness()
        t.type("Password:");t.press(tab);t.focus.id="f2";t.advance(0.5);t.type("hunter2");t.advance(long)
        pass(t.rows.isEmpty,"Password: then Tab to another field then hunter2: no row")
        let pause=TypingHarness()
        pause.type("pin is ");pause.advance(6);pause.type("4821 thanks");pause.advance(long)
        pass(pause.rows.isEmpty,"a pending label keeps the unit open across a pause")
        // PV5: a label waiting longer than 30 s for its value.
        let s9=TypingHarness()
        s9.type("wifi password: ");s9.advance(60);s9.type("sunshine42 is it.");s9.advance(idle)
        pass(s9.rows.isEmpty,"PV5: label, 60 s, value: no row")
        let ctx=TypingHarness()
        ctx.type("password:");ctx.press(ret);ctx.advance(31);ctx.type("hunter2 is my cat.");let ctxLatched=ctx.s.isLatched;ctx.advance(idle)
        pass(ctx.rows.isEmpty && ctxLatched,"PV5: a label guards the next line for 5 minutes, not 30 s")
        let expired=TypingHarness()
        expired.type("password:");expired.press(ret);expired.advance(301);expired.type("hunter2 is my cat.");expired.advance(idle)
        pass(expired.texts == ["hunter2 is my cat."],"the label context expires after 5 minutes")
        // PV4: short numeric secrets named by their label.
        for text in ["my bank pin: 4921 ok.","passcode: 552193 ok.","cvv: 123 ok.","2fa code: 482913 ok.","code: 482913 ok.","PIN 4921 ok.","iban: DE89370400440532013000 ok.","my pin is 4921","door code 1234 at the gate."] {
            let h=TypingHarness();h.type(text);let latched=h.s.isLatched;h.advance(long)
            pass(h.rows.isEmpty && latched,"PV4: labelled numeric secret latches: \(text.count) chars")
        }
        let token=TypingHarness()
        token.type("token: ab12cd34ef ok.");token.advance(idle)
        pass(token.rows.isEmpty,"PV4: token: value is not stored (store pre-check)")
        let split=TypingHarness()
        split.type("my pin is 49");split.advance(long);split.type("21 ok.");split.advance(idle)
        pass(clean(split,["49","21"]),"PV4: a short value after a label cut by the idle commit is withheld with its continuation")
        let s15=TypingHarness()
        s15.type("pin: 4");s15.press(ret);s15.type("921 is it");s15.advance(long)
        pass(clean(s15,["4","921"]),"S15: a value split by Return after a label is withheld on both lines")
    }

    static func sizes() {
        let long2=TypingHarness()
        long2.type("see "+String(repeating:"a",count:257)+" end.",every:0.01);long2.advance(idle)
        pass(long2.rows.isEmpty,"a token over 256 characters: no row")
        let plans=TypingHarness()
        plans.type("2026 plans for the house.");plans.advance(idle)
        pass(plans.texts == ["2026 plans for the house."],"2026 plans is kept")
        let year=TypingHarness()
        year.type("2026");year.press(ret)
        pass(year.rows.isEmpty,"2026 alone is rejected")
        // Soft split at a closed tail after 1800 characters: exact rejoin.
        let words=(0..<420).map {"word\($0 % 10) "}.joined()
        let soft=TypingHarness()
        soft.type(words,every:0.01);soft.advance(idle)
        pass(soft.rows.count == 2 && soft.texts.joined() == words,"soft split rejoins exactly")
        pass(soft.rows.first.map {$0.text.count >= 1800 && $0.reason == .size} == true,"soft split at 1800 characters")
        pass(Set(soft.rows.map(\.runID)).count == 1 && soft.rows.map(\.part) == [1,2],"soft split keeps runID, part+1")
        // Hard cap by bytes, cut at whitespace within 64 characters, carry the partial word.
        let cjk=(0..<300).map {_ in "漢字漢字 "}.joined()
        let hard=TypingHarness()
        hard.type(cjk,every:0.01);hard.advance(idle)
        pass(hard.rows.count == 2 && hard.texts.joined() == cjk,"byte cap rejoins exactly")
        pass(hard.rows.allSatisfy {$0.text.utf8.count <= 3584} && hard.rows.first?.text.last == " ","byte cap cuts at whitespace")
        pass(Set(hard.rows.map(\.runID)).count == 1 && hard.rows.map(\.part) == [1,2],"byte cap keeps runID, part+1")
        // Hard cap by characters inside a long word.
        let tail=String(repeating:"b",count:250)
        let prefix=(0..<358).map {_ in "word "}.joined()
        let chars=TypingHarness()
        chars.type(prefix+tail+" done.",every:0.01);chars.advance(idle)
        pass(chars.rows.count == 2 && chars.texts.joined() == prefix+tail+" done.","character cap rejoins exactly")
        pass(chars.rows.first?.text.count == 2000,"character cap at 2000")
    }

    static func suspendAndBoundaries() {
        let s=TypingHarness()
        s.type("draft one");s.suspend()
        pass(s.texts == ["draft one"],"suspend commits the live unit")
        pass(s.rows.first?.reason == .suspend,"suspend seal reason")
        let settle=TypingHarness()
        settle.type("draft two");settle.press(tab);settle.focus.id="f2";settle.advance(0.1);settle.suspend()
        pass(settle.texts == ["draft two"],"suspend during a settle commits")
        let fault=TypingHarness()
        fault.type("draft three");fault.s.invalidate(.pause);fault.advance(long)
        pass(fault.rows.isEmpty,"a fault discards")
        let policy=TypingHarness()
        policy.type("draft four");policy.press(tab);policy.focus.id="f2";policy.policy.version+=1;policy.advance(1)
        pass(policy.rows.isEmpty,"a policy change discards a parked unit")
        let prefs=TypingHarness()
        prefs.type("draft five");prefs.s.invalidate(.policy);prefs.policy.version+=1;prefs.advance(long)
        pass(prefs.rows.isEmpty,"a preferences save discards")
        let off=TypingHarness()
        off.type("draft six");off.policy.typedText=false;off.advance(long)
        pass(off.rows.isEmpty,"typing turned off discards")
        let gap=TypingHarness()
        gap.type("before gap.");gap.advance(0.1);gap.key(KeyStroke(keyCode:0),"x",age:1.5);gap.advance(1)
        pass(gap.texts == ["before gap."],"a delayed event seals with gap and is not applied")
        let excluded=TypingHarness()
        excluded.type("draft");excluded.policy.excludedApps=["com.apple.Notes"];excluded.type("x");excluded.advance(long)
        pass(excluded.rows.isEmpty,"excluding the app mid-unit discards")
        let turnsSecure=TypingHarness()
        turnsSecure.type("hello there");turnsSecure.focus.subrole="AXSecureTextField";turnsSecure.advance(long)
        pass(turnsSecure.rows.isEmpty,"S13: the field turning secure with no further key: no row")
        let suspended=TypingHarness()
        suspended.type("Xk9#mQ2$vL7!pZ");suspended.suspend()
        pass(suspended.rows.isEmpty,"S14: suspend with a lone opaque token: no row")
    }

    /// gold/r2-typing (golden 5 G7): keys the host handled late (after `markLateCut`) are never written before they are
    /// vouched for (`releaseLateCut`) or dropped (`rollBackLate`): not by a live commit, a settle, or a forced resolve.
    static func lateCut() {
        let vouched=TypingHarness()
        vouched.type("Hello there");vouched.s.markLateCut();vouched.type(" late");vouched.live(.idle)
        pass(vouched.rows.isEmpty && vouched.outcomes.last == .parked,"late cut: a live commit of a unit holding late keys is judged and kept, not written")
        vouched.advance(long);vouched.resolve(force:true)
        pass(vouched.rows.isEmpty && vouched.s.nextParkedDeadline == nil,"late cut: nothing writes it while its late keys are undecided (no deadline; a forced resolve skips it)")
        vouched.s.releaseLateCut();vouched.resolve()
        pass(vouched.texts == ["Hello there late"],"late cut: vouched for, it is written as it was judged")
        let dropped=TypingHarness()
        dropped.type("Hello there");dropped.s.markLateCut();dropped.type(" late");dropped.live(.idle)
        _=dropped.s.rollBackLate(now:dropped.clock,focusMoved:true);dropped.advance(1)
        pass(dropped.texts == ["Hello there"],"late cut: dropped, only the text typed before the cut is written")
        // A late key completes a secret: the clean head is parked with no settle (deadline now). Resolved at once, it
        // is judged and kept; the late keys found unsafe, it goes back to the text typed before the cut.
        let head=TypingHarness()
        head.type("Hello");head.s.markLateCut();head.type(" there. My password: Hunter2Zq9",every:0.02);head.resolve()
        pass(head.rows.isEmpty,"late cut: a clean head cut by a secret the late keys completed is not written at its zero-delay settle (was: \"Hello there.\")")
        _=head.s.rollBackLate(now:head.clock,focusMoved:true);head.advance(1)
        pass(head.texts == ["Hello"],"late cut: found unsafe, that clean head goes back to the text typed before the cut")
        let later=TypingHarness()
        later.type("Hello there");later.s.markLateCut();later.type(" late");later.live(.idle)
        later.type(" more");later.live(.idle)
        pass(later.rows.isEmpty,"late cut: a unit begun after the cut (it follows the late keys) waits too")
        later.s.releaseLateCut();later.resolve()
        pass(later.texts == ["Hello there late"," more"] || later.texts == ["Hello there late more"],"late cut: vouched for, both are written")
        let invalidated=TypingHarness()
        invalidated.type("Hello there");invalidated.s.markLateCut();invalidated.type(" late");invalidated.live(.idle)
        invalidated.s.invalidate(.pause);invalidated.s.releaseLateCut();invalidated.resolve(force:true)
        pass(invalidated.rows.isEmpty,"late cut: a privacy boundary while it waits drops it, never writes it")
    }

    /// gold/r2-typing review round 1 (golden 5 G7): one cut per backlog of late keys, each decided on its own; a unit
    /// that waits for one is never dropped to make room, and past `maxHeldForLateKeys` the oldest is decided the safe way.
    static func lateBacklogs() {
        // Seven lines ended while one backlog is undecided: all wait (the 4-unit parked list dropped the oldest three).
        let many=TypingHarness()
        many.type("Hello there");many.s.markLateCut();many.type(" late");many.live(.submit)
        let more=["line one","line two","line three","line four","line five","line six"]
        for m in more {many.type(m);many.live(.submit)}
        pass(many.rows.isEmpty,"late backlogs: seven lines ended while one backlog is undecided all wait")
        many.s.releaseLateCut();many.resolve()
        pass(many.texts == ["Hello there late"]+more,"late backlogs: none of them was dropped to make room; once vouched for, all seven are written in order (was, 7158fb4: the oldest three lost)")
        // Four lines wait, then a line ended by a click is parked for its settle: the parked list's cap counts only units
        // that don't wait, so it never drops one that does.
        let gap=TypingHarness()
        gap.type("Hello there");gap.s.markLateCut();gap.type(" late");gap.live(.submit)
        let lines=["line one","line two","line three"]
        for m in lines {gap.type(m);gap.live(.submit)}
        gap.type("clicked away");gap.click()
        pass(gap.rows.isEmpty,"late backlogs: four lines wait and a line ended by a click is parked, none written")
        gap.advance(1);gap.s.releaseLateCut();gap.advance(1);gap.resolve()
        pass(gap.texts == ["Hello there late"]+lines+["clicked away"],"late backlogs: a line parked by a click while four lines wait drops none of them; once vouched for, all five are written in order (was, 7158fb4: the oldest lost to the 4-unit cap)")
        // A newer backlog never keeps an older one waiting; dropping it keeps what was typed on time before it.
        let two=TypingHarness()
        two.type("first");let a=two.s.markLateCut();two.type(" late");two.live(.submit)
        two.type("second");let b=two.s.markLateCut();two.type(" late");two.live(.submit)
        two.s.releaseLateCut(through:a);two.resolve()
        pass(two.texts == ["first late"] && two.s.holdsLateCut(b) && !two.s.holdsLateCut(a),"late backlogs: the older backlog vouched for, its line is written while the newer one still waits")
        pass(!two.s.rollBackLate(from:a,now:two.clock,focusMoved:true) && two.texts == ["first late"] && two.s.holdsLateCut(b),"late backlogs: a backlog already decided is never rolled back again")
        two.s.rollBackLate(from:b,now:two.clock,focusMoved:true);two.resolve()
        pass(two.texts == ["first late","second"] && !two.s.hasLateCut,"late backlogs: the newer backlog dropped, its line goes back to what was typed on time and, judged on time already, is written at once")
        // Dropping an older backlog drops every newer one, and every line after it.
        let older=TypingHarness()
        older.type("first");let c=older.s.markLateCut();older.type(" late");older.live(.submit)
        older.type("second");older.s.markLateCut();older.type(" late");older.live(.submit)
        older.s.rollBackLate(from:c,now:older.clock,focusMoved:true);older.resolve()
        pass(older.texts == ["first"] && !older.s.hasLateCut,"late backlogs: the older backlog dropped, the newer one and the lines after it go too, the text typed on time before it is kept")
        // Past the bound, the oldest backlog is decided the safe way: dropped, the text typed on time before it kept.
        var small=TypingLimits();small.maxHeldForLateKeys=2
        let bound=TypingHarness(limits:small)
        bound.type("Hello there");bound.s.markLateCut();bound.type(" late");bound.live(.submit)
        bound.type("more");bound.live(.submit)
        pass(bound.rows.isEmpty && bound.s.hasLateCut,"late backlogs: within the bound, the lines wait")
        bound.type("again");bound.live(.submit);bound.resolve()
        pass(bound.texts == ["Hello there"] && !bound.s.hasLateCut,"late backlogs: one line past the bound, the oldest late keys are dropped with what followed them and the text typed on time is written")
        // A line begun just after a click (unconfirmed at the cut), then confirmed and judged: cut back to the text typed
        // on time, it stays confirmed and is written (restoring the cut's state must not unconfirm it).
        let fresh=TypingHarness()
        fresh.click();fresh.type("Hi",every:0.05);fresh.s.markLateCut();fresh.type(" yo",every:0.05);fresh.live(.submit)
        fresh.advance(1)
        pass(fresh.rows.isEmpty && fresh.s.hasLateCut,"late backlogs: a line begun just after a click is confirmed and judged at its settle, and waits")
        fresh.s.rollBackLate(now:fresh.clock,focusMoved:true);fresh.resolve()
        pass(fresh.texts == ["Hi"],"late backlogs: its late keys dropped, the text typed on time stays confirmed and is written")
    }

    static func keyMap() {
        let d=TypingHarness()
        d.press(14,opt:true);d.advance(0.08);d.key(KeyStroke(keyCode:14),"e");d.type("t");d.press(34,opt:true);d.advance(0.08);d.key(KeyStroke(keyCode:34),"\u{EE}");d.type("le.")
        d.advance(idle)
        pass(d.texts == ["\u{E9}t\u{EE}le."],"dead keys compose (either OS behaviour)")
        let o=TypingHarness()
        o.type("Brand");o.advance(0.08);o.key(KeyStroke(keyCode:19,option:true),"\u{2122}");o.type(" rocks.");o.advance(idle)
        pass(o.texts == ["Brand\u{2122} rocks."],"Option characters are text")
        let p=TypingHarness()
        p.type("cafe");p.advance(0.3);p.key(KeyStroke(keyCode:14,autorepeat:true),"e");p.advance(0.3);p.key(KeyStroke(keyCode:19),"2");p.type(" time.");p.advance(idle)
        pass(p.texts == ["caf\u{E9} time."],"C5: a press-and-hold popup pick replaces the held letter")
        let q=TypingHarness()
        q.type("caf");q.advance(0.08);q.key(KeyStroke(keyCode:14),"e")
        for _ in 0..<3 {q.advance(0.08);q.key(KeyStroke(keyCode:14,autorepeat:true),"e")}
        q.advance(0.2);q.key(KeyStroke(keyCode:19),"2");q.type(" au lait.");q.advance(idle)
        pass(q.texts == ["caf\u{E9} au lait."],"C5: the reviewer's popup sequence stores the chosen accent")
        let upper=TypingHarness()
        upper.advance(0.08);upper.key(KeyStroke(keyCode:14,shift:true),"E");upper.advance(0.3);upper.key(KeyStroke(keyCode:14,shift:true,autorepeat:true),"E")
        upper.advance(0.3);upper.key(KeyStroke(keyCode:19),"2");upper.type("cole.");upper.advance(idle)
        pass(upper.texts == ["\u{C9}cole."],"C5: Shift picks the capital accent")
        let none=TypingHarness()
        none.type("wal");none.advance(0.3);none.key(KeyStroke(keyCode:37,autorepeat:true),"l");none.advance(0.3);none.key(KeyStroke(keyCode:19),"2");none.type("s.");none.advance(idle)
        pass(none.texts == ["walls."] || none.texts == ["wals."],"C5: a digit past the popup's accents is consumed")
        let r=TypingHarness();r.pressAndHold=false
        r.type("zz");r.advance(0.3);r.key(KeyStroke(keyCode:6,autorepeat:true),"z");r.type(".");r.advance(idle)
        pass(r.texts == ["zzz."],"autorepeat applies when press-and-hold is off")
        let v=TypingHarness()
        v.type("see this: ");let before=v.reads;v.press(9,cmd:true);v.type("thanks.");v.advance(idle)
        pass(v.reads == before+"thanks.".count && v.texts == ["see this: ","thanks."],"paste commits and is never read")
        pass(v.markers == ["keyboard.shortcut"],"paste marker")
        let z=TypingHarness()
        z.type("typo here");z.press(6,cmd:true);z.advance(long)
        pass(z.rows.isEmpty && z.markers == ["keyboard.shortcut"],"C7: Cmd-Z drops the live unit (one undo group) and writes a marker")
        let redo=TypingHarness()
        redo.type("first part");redo.press(6,cmd:true,shift:true);redo.type(" after redo.");redo.advance(idle)
        pass(redo.texts == ["first part"," after redo."] && redo.rows.first?.reason == .cursor && redo.markers == ["keyboard.shortcut"],"C7: Cmd-Shift-Z commits what was typed and writes a marker")
        let c=TypingHarness()
        c.type("copy me");c.press(8,cmd:true);c.type(" please.");c.advance(idle)
        pass(c.texts == ["copy me please."] && c.markers == ["keyboard.shortcut"],"Cmd-C is a marker only")
        let x=TypingHarness()
        x.type("keep drop");x.press(left,times:4,shift:true);x.press(7,cmd:true);x.type("this.");x.advance(idle)
        pass(x.texts == ["keep this."],"Cmd-X cuts a known in-run selection")
        let f=TypingHarness()
        f.type("fn");f.advance(0.08);f.key(KeyStroke(keyCode:122),"\u{F704}");f.type(" key.");f.advance(idle)
        pass(f.texts == ["fn"," key."],"F-keys split and their characters are never text")
        let globe=TypingHarness()
        globe.type("smile");let globeReads=globe.reads;globe.advance(0.08);globe.key(KeyStroke(keyCode:14,fn:true),"e");globe.advance(1)
        pass(globe.texts == ["smile"] && globe.reads == globeReads && globe.markers == ["keyboard.shortcut"],"C8: Fn-E (emoji picker) seals, reads nothing and writes a marker")
        let fnArrow=TypingHarness()
        fnArrow.type("abc");fnArrow.advance(0.08);fnArrow.key(KeyStroke(keyCode:left,fn:true));fnArrow.type("X");fnArrow.advance(long)
        pass(fnArrow.texts == ["abXc"],"C8: arrows carry the Fn flag and still edit")
        let emacs=TypingHarness()
        emacs.type("abc def");emacs.press(11,ctrl:true);emacs.press(11,ctrl:true);emacs.press(40,ctrl:true);emacs.press(4,ctrl:true);emacs.type("X.");emacs.advance(idle)
        pass(emacs.texts == ["abc X."],"Ctrl-B, Ctrl-K and Ctrl-H edit the run")
        let tabs=TypingHarness()
        tabs.type("in a text area");tabs.press(tab);tabs.advance(1)
        pass(tabs.texts == ["in a text area"] && tabs.rows.first?.reason == .focusKey,"Tab always parks, even in text areas")
    }

    static func latchAndContext() {
        let l=TypingHarness()
        l.type("password: x");let reads=l.reads
        l.type("yz and more words here");l.press(backspace,times:3)
        pass(l.reads == reads && l.s.isLatched,"zero reads while latched")
        l.press(ret);l.type("fresh line.");l.advance(idle)
        pass(l.texts == ["fresh line."],"Return clears the latch")
        let tabbed=TypingHarness()
        tabbed.type("password: x");tabbed.press(tab);tabbed.focus.id="f2";tabbed.advance(0.5);tabbed.type("next field.");tabbed.advance(idle)
        pass(tabbed.texts == ["next field."],"Tab in the latched app clears the latch")
        let e=TypingHarness()
        e.type("password: x");e.advance(31);e.type("later words.");e.advance(idle)
        pass(e.texts == ["[withheld] words."],"PV1: the latch expires after 30 s without keys; the next first token is withheld")
        let soft=TypingHarness()
        soft.type("Tr0ub4dor&3");soft.advance(long);soft.type("more words.")
        pass(soft.rows.isEmpty && soft.s.isLatched,"a rejection at an idle split latches, and the latch survives it")
        soft.press(ret);soft.type("next.");soft.advance(idle)
        pass(soft.texts == ["next."],"Return clears that latch")
        let deleted=TypingHarness()
        deleted.type("note: password: ");deleted.press(backspace,times:10);deleted.type("ok.");deleted.advance(idle)
        pass(deleted.rows.isEmpty,"text typed then deleted is still classified (typing log)")
        let spaces=TypingHarness()
        spaces.type("   ");spaces.advance(idle);spaces.type("real text.");spaces.advance(idle)
        pass(spaces.texts == ["real text."],"a whitespace-only unit writes nothing and does not latch")
        let rejoin=TypingHarness()
        rejoin.type("abc.");rejoin.advance(idle);rejoin.type("Tr0ub4dor&3 ok.");rejoin.advance(idle)
        pass(clean(rejoin,["Tr0ub"]),"a lone opaque token after an idle split is withheld")
        // PV1: ordinary boundaries never clear the latch.
        let s3=TypingHarness()
        s3.type("password: hu");s3.hiccup("n",newIDs:true);s3.type("ter2isgreat and more words.");let s3Latched=s3.s.isLatched;s3.advance(long)
        pass(s3.rows.isEmpty && s3Latched,"PV1 S3: an AX failure that re-mints the field IDs keeps the latch")
        let s3b=TypingHarness()
        s3b.type("password: hu");s3b.hiccup("n");s3b.type("ter2isgreat and more words.");s3b.advance(long)
        pass(s3b.rows.isEmpty,"PV1 S3b: an unreadable key keeps the latch")
        let s4=TypingHarness()
        s4.type("password: hu");s4.advance(0.08);s4.key(KeyStroke(keyCode:0),"n",age:1.5);s4.type("ter2isgreat and more words.");s4.advance(long)
        pass(s4.rows.isEmpty,"PV1 S4: a main-thread stall (gap) keeps the latch")
        let s5=TypingHarness()
        s5.type("password: hu");s5.s.seal(.focus,now:s5.clock,focusMoved:false);s5.keyMap.reset();s5.type("nter2isgreat and more words.");s5.advance(long)
        pass(s5.rows.isEmpty,"PV1 S5: a spurious AX focus change keeps the latch")
        let s8=TypingHarness()
        s8.type("password: hunter2");s8.advance(1);s8.click();s8.advance(0.6);s8.type("hunter3 ");s8.advance(idle)
        pass(s8.rows.isEmpty,"PV1 S8: a click in the same app keeps the latch")
        let pb2=TypingHarness()
        pb2.type("wifi password: sun");pb2.switchApp(to:safari);pb2.advance(3);pb2.switchApp(to:TypingHarness.Field());pb2.advance(0.6)
        pb2.type("shine42 and the guest one is open.");let pb2Latched=pb2.s.isLatched(TypingHarness.Field().bundle);pb2.advance(long)
        pass(pb2.rows.isEmpty && pb2Latched,"PV1 Pb2: Cmd-Tab away and back keeps the latch")
        let otherApp=TypingHarness()
        otherApp.type("password: x");otherApp.switchApp(to:textEdit);otherApp.advance(0.6);otherApp.type("other app text.");otherApp.press(tab);otherApp.advance(1)
        otherApp.switchApp(to:TypingHarness.Field());otherApp.advance(0.6);otherApp.type("yz more");otherApp.advance(long)
        pass(otherApp.texts == ["other app text."],"PV1: the latch is per app; Tab in another app does not clear it")
        let po=TypingHarness()
        po.type("wifi password: sun");po.advance(35);po.type("shine42 and more.");po.advance(idle)
        pass(clean(po,["shine"]),"PV1 Po: after the latch expires mid-value, the rest of the value is withheld")
    }

    static func splitSecrets() {
        // PV2: a secret split by an ordinary seal leaves no fragment.
        let s6=TypingHarness()
        s6.type("wifi Xk9#mQ");s6.hiccup("2",newIDs:true);s6.type("$vL7!pZ ok.");s6.advance(idle)
        pass(clean(s6,["Xk9","vL7"]) && s6.texts.joined().contains("ok."),"PV2 S6: a token split by an AX failure with new IDs: no fragment")
        let same=TypingHarness()
        same.type("wifi Xk9#mQ");same.hiccup("2");same.type("$vL7!pZ ok.");same.advance(idle)
        pass(same.texts == ["wifi [withheld] ok."],"C6: one unreadable key does not split the unit")
        let s7=TypingHarness()
        s7.type("wifi Xk9#mQ");s7.s.seal(.focus,now:s7.clock,focusMoved:false);s7.keyMap.reset();s7.type("2$vL7!pZ ok.");s7.advance(idle)
        pass(clean(s7,["Xk9","vL7"]),"PV2 S7: a token split by a spurious AX focus change: no fragment")
        let s16=TypingHarness()
        s16.type("wifi Xk9#mQ");s16.advance(21);s16.s.seal(.focus,now:s16.clock,focusMoved:false);s16.keyMap.reset();s16.advance(1);s16.type("2$vL7!pZ ok.");s16.advance(idle)
        pass(clean(s16,["Xk9","vL7"]),"PV2 S16: pause then a spurious focus change: no fragment")
        let pb=TypingHarness()
        pb.type("wifi Xk9#m");pb.switchApp(to:safari);pb.advance(3);pb.switchApp(to:TypingHarness.Field());pb.advance(0.6);pb.type("Q2$vL7!pZ ok.");pb.advance(idle)
        pass(clean(pb,["Xk9","vL7"]),"PV2 Pb: Cmd-Tab mid-token to read the rest: no fragment")
        let pcarry=TypingHarness()
        pcarry.type("wifi Xk9#mQ");pcarry.advance(21);pcarry.switchApp(to:safari);pcarry.advance(2)
        pass(pcarry.texts == ["wifi [withheld]"],"PV2 Pcarry: the partial token is withheld when the user leaves")
        let seam=TypingHarness()
        seam.type("token sk-proj-abcdef",every:0.05);seam.advance(long);seam.type("ghijklmnop more",every:0.05);seam.advance(long)
        pass(seam.texts == ["token [withheld]","[withheld] more"],"a key prefix cut by the idle commit and its rest are both withheld")
        let p2=TypingHarness()
        p2.type("my code is Tr0ub");p2.advance(long);p2.type("4dor&3 ok");p2.advance(long)
        pass(clean(p2,["Tr0ub","4dor"]),"P2 with a 61 s pause: no fragment stored")
        let later=TypingHarness()
        later.type("my code is Tr0ub");later.advance(long);later.advance(120);later.type("4dor&3 ok");later.advance(long)
        pass(clean(later,["Tr0ub","4dor"]),"a withheld tail guards its continuation for 5 minutes")
        let plain=TypingHarness()
        plain.type("I went to the");plain.advance(long);plain.type("re and back.");plain.advance(idle)
        pass(plain.texts == ["I went to the","re and back."],"plain words cut by the idle commit are kept")
    }

    static func numbers() {
        // PV3: digit groups split by a pause.
        let s1=TypingHarness()
        s1.type("card 4111 1111 1111 ");s1.advance(5);s1.type("1111 exp soon.");s1.advance(long)
        pass(s1.rows.isEmpty,"PV3 S1: card groups with a 5 s pause stay one unit and are rejected")
        let s1l=TypingHarness()
        s1l.type("card 4111 1111 1111 ");s1l.advance(long);s1l.type("1111 exp soon.");s1l.advance(idle)
        pass(clean(s1l,["4111","1111"]),"PV3 S1: card groups split by the idle commit: no group stored")
        let s1b=TypingHarness()
        s1b.type("ssn 123 45 ");s1b.advance(5);s1b.type("6789 thanks.");s1b.advance(long)
        pass(s1b.rows.isEmpty,"PV3 S1b: SSN groups: no row")
        let s1c=TypingHarness()
        s1c.type("iban DE89 3704 0044 ");s1c.advance(5);s1c.type("0532 0130 00 ok.");s1c.advance(long)
        pass(s1c.rows.isEmpty,"PV3 S1c: IBAN groups: no row")
        let pc=TypingHarness()
        pc.type("backup codes\n1234 5678\n2345 6789\n");pc.advance(long)
        pass(pc.rows.isEmpty,"PV3 Pc: recovery codes typed one per line: no row")
        let groups=TypingHarness()
        groups.type("call 555 0199 or 555 0142 later.");groups.advance(idle)
        pass(clean(groups,["0199","0142"]),"PV3: runs of digit groups are withheld")
        let dates=TypingHarness()
        dates.type("On 2026-09-24 we met at 3 pm with 12 people.");dates.advance(idle)
        pass(dates.texts == ["On 2026-09-24 we met at 3 pm with 12 people."],"dates and small counts are kept")
        let s10=TypingHarness()
        for (i,d) in "482913".enumerated() {s10.focus.id="otp\(i)";s10.focus.role="AXTextField";s10.advance(0.3);s10.key(KeyStroke(keyCode:0),String(d))}
        s10.advance(long)
        pass(s10.rows.isEmpty,"PV9 S10: one digit per box, focus advancing by itself: no row")
        let box=TypingHarness()
        box.type("42");box.press(ret)
        pass(box.rows.isEmpty,"PV9: a unit of one to three digits alone is not a row")
    }

    static func prose() {
        // C1: ordinary prose that older rules rejected.
        let paragraphs=[
          "Notes from the planning meeting. We agreed the FY24 budget stays flat and the launch moves to May. Sam will draft the announcement and I will review it on Friday.",
          "Reminder for the trip: the pin is on the shared map, meet at the north gate, and bring snacks for everyone because the hike is long.",
          "Took CS50 last spring and it was a great course, the problem sets were hard but the lectures were excellent and I would recommend it.",
          "The secret: always salt the pasta water generously, and keep a cup of it for the sauce before you drain the noodles.",
          "The password is on the fridge and the zip code: 94110 is on the envelope.",
        ]
        for (i,p) in paragraphs.enumerated() {
            let h=TypingHarness()
            h.type(p+" Then more typing continues in the same note.",every:0.03);let latched=h.s.isLatched;h.advance(idle)
            // The store's own pre-check (Privacy.secret, unchanged) still
            // declines any row containing "secret:"; the classifier no longer
            // rejects or latches it.
            let stored=i == 3 ? h.rows.isEmpty && h.notWritten == 1 : h.texts == [p+" Then more typing continues in the same note."]
            pass(stored && !latched,"C1 FP\(i+1): ordinary prose is classified allowed and does not latch")
        }
        let salvage=TypingHarness()
        salvage.type("Groceries for the week are done. My password is hunter2 and more.");let salvaged=salvage.s.isLatched;salvage.advance(idle)
        pass(salvage.texts == ["Groceries for the week are done. "] && salvaged,"C1: the sentences before a secret are kept, the secret and the rest are not")
        let noSalvage=TypingHarness()
        noSalvage.type("Note to self pin 4921 then more.");noSalvage.advance(idle)
        pass(noSalvage.rows.isEmpty,"C1: no salvage inside one sentence")
    }

    static func fifoAndGeneration() {
        let h=TypingHarness()
        for i in 1...5 {h.focus.id="f\(i)";h.type("unit \(i)",every:0.01)}
        h.focus.id="f6";h.type("x",every:0.01)
        pass(h.s.parkedCount == 4,"parked FIFO holds at most 4")
        h.advance(1)
        pass(h.texts == ["unit 2","unit 3","unit 4","unit 5"],"overflow drops the oldest")
        let g=TypingHarness();let start=g.s.generation
        g.type("one.");g.press(ret);g.type("two.");g.advance(idle);g.type("three");g.press(tab);g.advance(1)
        pass(g.s.generation == start,"ordinary boundaries never advance the generation")
        let off=TypingHarness();off.policy.typedText=false;let gen=off.s.generation
        off.type("not captured")
        pass(off.s.generation == gen && off.reads == 0,"keys with typing off cause no reads and no generation churn")
        let switching=TypingHarness();let notes=switching.focus
        switching.type("alpha beta");switching.switchApp(to:textEdit);switching.type("gamma delta epsilon",every:0.06)
        switching.switchApp(to:notes);switching.type("zeta",every:0.06);switching.switchApp(to:textEdit);switching.type("eta theta",every:0.06);switching.advance(long)
        pass(switching.texts == ["alpha beta","gamma delta epsilon","eta theta"],"C-S8: rapid switching keeps each app's text in its own row; a 0.24 s burst inside the settle is dropped (C10)")
    }

    static func redaction() {
        let h=TypingHarness()
        h.type("some private words")
        pass(String(describing:h.s) == "TypingSession(redacted)" && !String(reflecting:h.s).contains("private"),"session diagnostics are redacted")
        pass(Mirror(reflecting:h.s).children.isEmpty,"session mirror is empty")
        h.press(ret)
        if let row=h.rows.first {
            pass(String(describing:row) == "TypingCommit(redacted)" && Mirror(reflecting:row).children.isEmpty,"commit diagnostics are redacted")
        } else {check(false,"row for redaction check")}
        let op=TypingOp.insert("private")
        pass(!String(describing:op).contains("private") && !String(reflecting:op).contains("private") && Mirror(reflecting:op).children.isEmpty,"PV10: TypingOp diagnostics are redacted")
        var model=TextEditModel();_=model.apply(.insert("private"))
        pass(!String(describing:model).contains("private") && !String(reflecting:model).contains("private") && Mirror(reflecting:model).children.isEmpty,"PV10: TextEditModel diagnostics are redacted")
        let verdict=UnitVerdict.allow("private words",withheld:1)
        pass(!String(describing:verdict).contains("private") && !String(reflecting:verdict).contains("private") && Mirror(reflecting:verdict).children.isEmpty,"PV10: UnitVerdict diagnostics are redacted")
        var dumped="";dump(h.s,to:&dumped);dump(op,to:&dumped);dump(model,to:&dumped);dump(verdict,to:&dumped)
        pass(!dumped.contains("private"),"PV10: dump() shows no text")
    }

    static func performance() throws {
        let h=TypingHarness()
        let text=String((0..<400).map {"word\($0 % 10) "}.joined().prefix(1790))
        let start=DispatchTime.now().uptimeNanoseconds
        h.type(text,every:0.01)
        let perKey=Double(DispatchTime.now().uptimeNanoseconds-start)/1e6/Double(text.count)
        // One whole-unit verdict at 2000 characters, 8 chunks, 400 tokens.
        let s=TypingSession()
        var policy=CapturePolicy();policy.typedText=true
        var p=h.proof()!;p.generation=s.generation;p.policyVersion=policy.version
        var t=p.checkedAt
        for (i,c) in String((0..<500).map {"ab\($0 % 10) "}.joined().prefix(2000)).enumerated() {
            t+=i % 250 == 0 ? 800_000_000 : 1_000_000
            p.checkedAt=t;_=s.insert(String(c),proof:p,policy:policy,eventAt:t,now:t)
        }
        let t0=DispatchTime.now().uptimeNanoseconds
        let out=s.commitLive(fresh:p,reason:.submit,policy:policy,now:t) {_ in true}
        let commit=Double(DispatchTime.now().uptimeNanoseconds-t0)/1e6
        check(out == .committed(withheld:0),"performance unit commits")
        let report:[String:Any]=["perKeyMs":(perKey*1000).rounded()/1000,"commitMs":(commit*1000).rounded()/1000,"characters":2000]
        FileHandle.standardError.write(try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]))
        FileHandle.standardError.write(Data("\n".utf8))
        #if DEBUG
        let (keyLimit,commitLimit)=(2.0,20.0)   // unoptimized build; the design targets are asserted in release
        #else
        let (keyLimit,commitLimit)=(1.0,10.0)
        #endif
        pass(perKey<keyLimit,"per key under \(keyLimit) ms")
        pass(commit<commitLimit,"commit under \(commitLimit) ms at 2000 characters")
    }
}
