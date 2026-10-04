// DD-RECIPE: APP
// Chrome page history, UI slice (SPEC §8.3, §9, §11): the real MemoryViewModel on a private store
// under DD_CHECK_OUT, with a fake ChromeAccessEnvironment in place of the Automation calls.
//   A. every string: ChromeAccessState rows, the card, the site errors, diagnostics, the menu line;
//   B. the card: it reads access only while the saved switch is on, and never asks;
//   C. the switch and the owner's sites through the production save path (recording stops, AI apps
//      are disconnected only by a change that shares more, every error text), and the "Don't Record <site>…" hook;
//   D. Chrome access: a read never asks; Allow asks exactly once, off the main thread, and only after
//      Chrome is running and verified;
//   E. Settings › Apps to remember hosted on the production model: reads access, never asks;
//   F. source guarantees (the one prompt call, inside allowChromeAccess).
// It never starts capture, never opens an app, never requests a permission and sends no Apple Event:
// the fake stands in for every Chrome call, and the live environment is never used here.
import AppKit
import Carbon
import SwiftUI
import MemoryCore
import MemoryUI

func fail(_ message:String) -> Never {
    fflush(stdout)
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}
@MainActor func expect(_ condition:Bool,_ message:@autoclosure ()->String) { if !condition {fail(message())} }
func pass(_ message:String) { print("PASS: \(message)"); fflush(stdout) }
@MainActor func thrownText(_ body:() throws -> Void) -> String? {
    do {try body();return nil}
    catch let site as ChromeSiteMessage {return site.text}
    catch MemError.invalid(let message) {return message}
    catch {return "\(error)"}
}
@MainActor func tick(_ seconds:Double=0.05) async throws { try await Task.sleep(nanoseconds:UInt64(seconds*1_000_000_000)) }
@MainActor func waitUntil(_ timeout:Double=3,_ done:() -> Bool) async throws -> Bool {
    let end=Date().addingTimeInterval(timeout)
    while Date() < end { if done() {return true}; try await tick(0.02) }
    return done()
}
func makePrivateDirectory(_ url:URL) throws {
    try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
    try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:url.path)
}
/// The text of the first `{…}` block after `signature` (brace counting).
func body(of signature:String,in source:String) -> String {
    guard let start=source.range(of:signature),let open=source[start.lowerBound...].firstIndex(of:"{") else {fail("source: \(signature) not found")}
    var depth=0,index=open
    while index < source.endIndex {
        if source[index] == "{" {depth += 1}
        if source[index] == "}" {depth -= 1;if depth == 0 {return String(source[open...index])}}
        index=source.index(after:index)
    }
    fail("source: \(signature) has no closing brace")
}

/// Stands in for Chrome and macOS: counts every call and records whether it ran off the main thread.
final class FakeChrome:@unchecked Sendable {
    private let lock=NSLock()
    private let queue=DispatchQueue(label:"checks.fake-chrome-access")
    private var _pid:pid_t?=4242, _verified=true, _status:OSStatus=0, _answer:OSStatus=0, _copies=1
    /// How long the stand-in macOS question takes to be answered (a person answering: 5 s; no question shown: 0.1 s).
    private var _askSeconds:TimeInterval=5, _clock:TimeInterval=1000
    private var counts=["running":0,"verify":0,"status":0,"ask":0]
    private var onMain:[String]=[]
    /// Setup's ask while Chrome isn't running waits here for "Chrome came to the front" (fired by the check).
    private var activations:[()->Void]=[]
    /// Setup's Chrome step: Google Chrome installed, and what opening it does (the pid it then runs as; nil: it didn't open).
    private var _installed=true, _opensAs:pid_t?=4343, _opens=0
    var opens:Int { locked {_opens} }
    func set(installed:Bool,opensAs:pid_t?) { locked {_installed=installed;_opensAs=opensAs} }
    var waitingActivations:Int { locked {activations.count} }
    func activateChrome() { let waiting=locked { () -> [()->Void] in let all=activations;activations=[];return all }; waiting.forEach { $0() } }
    private func locked<T>(_ work:()->T) -> T { lock.lock(); defer {lock.unlock()}; return work() }
    func set(pid:pid_t?=4242,verified:Bool=true,status:OSStatus=0,answer:OSStatus=0,copies:Int=1,askSeconds:TimeInterval=5) {
        locked {_pid=pid;_verified=verified;_status=status;_answer=answer;_copies=copies;_askSeconds=askSeconds}
    }
    func reset() { locked {counts=["running":0,"verify":0,"status":0,"ask":0];onMain=[];_opens=0} }
    func count(_ name:String) -> Int { locked {counts[name] ?? 0} }
    var mainThreadCalls:[String] { locked {onMain} }
    private func note(_ name:String,mustBeOffMain:Bool) {
        let main=Thread.isMainThread
        locked {counts[name,default:0] += 1; if mustBeOffMain && main {onMain.append(name)}}
    }
    func environment() -> ChromeAccessEnvironment {
        ChromeAccessEnvironment(
            running:{ [self] in note("running",mustBeOffMain:false); return locked {_pid} },
            copies:{ [self] in locked {_copies} },
            verify:{ [self] _ in note("verify",mustBeOffMain:true); return locked {_verified} },
            status:{ [self] _ in note("status",mustBeOffMain:true); return locked {_status} },
            ask:{ [self] _ in note("ask",mustBeOffMain:true); return locked {_clock += _askSeconds;return _answer} },
            background:{ [queue] work in queue.async(execute:work) },
            main:{ work in DispatchQueue.main.async(execute:work) },
            onNextChromeActivation:{ [self] action in locked {activations.append(action)} },
            uptime:{ [self] in locked {_clock} },
            installed:{ [self] in locked {_installed} },
            openChrome:{ [self] done in
                let opened=locked { () -> Bool in _opens += 1; if let pid=_opensAs {_pid=pid;return true}; return false }
                DispatchQueue.main.async {done(opened)}
            })
    }
}

@main @MainActor struct ChromePagesUIChecks {
    static let window:NSWindow = {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let w=NSWindow(contentRect:NSRect(x:-4000,y:-4000,width:760,height:600),styleMask:[.titled],backing:.buffered,defer:false)
        return w
    }()

    static func main() async throws {
        DispatchQueue.global().asyncAfter(deadline:.now()+120) {
            FileHandle.standardError.write(Data("FAIL: chrome-pages-ui-checks watchdog expired after 120s\n".utf8))
            exit(2)
        }
        // Codex's shared roots, spelled so run-checks.sh's rewrite of the literal prefix leaves them intact.
        let shared=["/private/tmp/"+"day"+"dream-","/tmp/"+"day"+"dream-"]
        guard let outPath=ProcessInfo.processInfo.environment["DD_CHECK_OUT"],outPath.hasPrefix("/"),
              !shared.contains(where:{outPath.hasPrefix($0)}) else {
            fail("DD_CHECK_OUT is not a private output directory; run this check through run-checks.sh")
        }
        print("BEGIN chrome-pages-ui-checks on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let out=URL(fileURLWithPath:outPath,isDirectory:true)
        try makePrivateDirectory(out)

        strings()
        try await card()
        sources()
        let fake=FakeChrome()
        let (model,memory)=try await productionModel(out:out,fake:fake)
        try await switchAndSites(model:model,memory:memory,fake:fake)
        try await access(model:model,fake:fake)
        try await upgradeAccess(model:model,fake:fake,out:out)
        try await grantTurnsOnPages(model:model,fake:fake)
        try await hostedSettings(model:model,fake:fake)
        try await switchOff(model:model,memory:memory,fake:fake)
        expect(!model.recording && model.stopped && model.noteWriter.provider == "off",
               "the model ended recording=\(model.recording) stopped=\(model.stopped) provider=\(model.noteWriter.provider)")
        window.contentView=nil
        pass("end: the model is stopped and not recording; nothing started, opened or asked outside the fake")
    }

    // MARK: A. Strings (SPEC §8.3, §9, §11.1, §11.3–11.5)

    static func strings() {
        typealias S=ChromeAccessState
        let rows:[(S,String,String?,String?)]=[
            (.checking,"Checking…",nil,nil),
            (.allowed,"Allowed",nil,nil),
            // The full-typing build (every release stage) also reads where Chrome's windows are, for the typing join.
            (.notAsked,"Not allowed yet","Allow…",TypingSettingsText.ownerBuild
                ? "macOS will ask to let DayDream control Google Chrome. DayDream only reads the page title, the address, where Chrome's windows are and whether a window is Incognito."
                : "macOS will ask to let DayDream control Google Chrome. DayDream only reads the page title, the address and whether a window is Incognito."),
            (.denied,"Not allowed","Allow…","Chrome access isn’t permitted. Check DayDream in Privacy & Security › Automation."),
            (.chromeNotRunning,"Open Google Chrome to check","Allow…","Open Google Chrome, then press Allow."),
            (.unverified,"Can't verify this copy of Chrome","Try Again","DayDream couldn't confirm this Chrome is from Google, so its pages aren't saved. Quit and reopen Chrome, then press Try Again."),
            (.askFailed,"Not allowed","Allow…","Chrome access is off. Press Allow…, or turn on Google Chrome for DayDream in Automation."),
            (.unknown,"Couldn't check","Try Again",nil),
        ]
        for (state,value,button,helper) in rows {
            expect(state.value == value,"\(state) value: \(state.value)")
            expect(state.buttonTitle == button,"\(state) button: \(state.buttonTitle ?? "none")")
            expect(state.helper == helper,"\(state) helper: \(state.helper ?? "none")")
        }
        expect(S.notAsked.action == .allow && S.chromeNotRunning.action == .allow && S.denied.action == .allow
               && S.unknown.action == .tryAgain && S.unverified.action == .tryAgain && S.askFailed.action == .allow
               && [S.checking,.allowed,.twoCopies].allSatisfy {$0.action == nil},"access row actions")
        expect(S.denied.offersSystemSettings && S.askFailed.offersSystemSettings
               && !S.notAsked.offersSystemSettings && !S.unverified.offersSystemSettings,
               "refused access offers both Allow and System Settings")
        pass("Chrome access: every state's value, button and helper text (§11.1 table)")
        expect(S.from(status:0) == .allowed && S.from(status:-1744) == .notAsked && S.from(status:-1743) == .denied
               && S.from(status:-600) == .chromeNotRunning && S.from(status:-1) == .unknown && S.from(status:-1728) == .unknown,"status mapping")
        expect(S.denied.accessOff && S.notAsked.accessOff && S.askFailed.accessOff && ![S.allowed,.checking,.unknown,.chromeNotRunning,.unverified].contains {$0.accessOff},"accessOff")
        expect(S.systemSettingsURL.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation","System Settings URL")
        pass("Chrome access: noErr allowed, −1744 not asked, −1743 turned off, −600 Chrome not running, else unknown; Automation pane URL")

        expect(S.diagnostics(on:false,access:.allowed) == "Off" && S.diagnostics(on:false,access:.denied) == "Off","diagnostics off")
        for a in [S.allowed,.checking,.unknown] {expect(S.diagnostics(on:true,access:a) == "On","diagnostics \(a)")}
        for a in [S.denied,.notAsked,.askFailed] {expect(S.diagnostics(on:true,access:a) == "On, but Chrome access is off","diagnostics \(a)")}
        expect(S.diagnostics(on:true,access:.unverified) == "On, but this copy of Chrome can't be verified","diagnostics unverified")
        expect(S.diagnostics(on:true,access:.chromeNotRunning) == "On. Open Google Chrome to check access.","diagnostics not running")
        // Review H6: Google Chrome excluded means nothing is saved; nothing says "on" as if it were.
        expect(S.diagnostics(on:true,access:.allowed,chromeExcluded:true) == "On, but Google Chrome is excluded"
               && S.diagnostics(on:false,access:.allowed,chromeExcluded:true) == "Off","diagnostics with Chrome excluded")
        pass("diagnostics row: Off / On / On, but Chrome access is off / can't be verified / Open Google Chrome to check access")

        typealias C=ChromePagesCard
        expect(C.title == "Web pages in Chrome" && C.switchLabel == "Save web pages in Google Chrome","card title and switch label")
        expect(C.detail(on:false) == C.setupLine && C.offDetail == "Off. Saves the title and site of the Chrome pages you look at."
               && C.detail(on:true) == "On. Saves the title and site of the Chrome page in front."
               && C.detail(on:true,chromeExcluded:true) == "On, but Google Chrome is excluded, so nothing is saved."
               && C.detail(on:false,chromeExcluded:true) == C.setupLine,"card details")
        // The full-typing build (every release stage) says website typing is saved, as consent text 2; a narrow build
        // says typing never is, as consent text 1.
        let opening:[String]=TypingSettingsText.ownerBuild
            ? ["When on, DayDream saves the title, site and link of the page in front in Google Chrome, and when. Links keep no search terms and stay on this Mac. It never saves what's on the page or your clicks.",
               "What you type on websites in Google Chrome is saved while typing is on and a website category is on in Typing, never on blocked sites or in Incognito or Guest windows."]
            : ["When on, DayDream saves the title, site and link of the page in front in Google Chrome, and when. Links keep no search terms and stay on this Mac. It never saves what's on the page, what you type, or your clicks."]
        expect(TypingSettingsText.ownerBuild == (PrivacySettings.browserPagesConsentCurrent == 2),"the card's consent version follows its text")
        expect(C.explanation == opening + [
            "While any Incognito or Guest window is open, DayDream saves nothing from Chrome.",
            // fix/public-web-typing: the full-typing (release) build's line names webmail typing's subject (fix/sx-all round 2).
            // email-1003 (owner decision 2026-10-03): email sites keep the folder or subject while Save email subjects is on.
            TypingSettingsText.ownerBuild
                ? "Common search and chat sites save the site only. Email sites save the folder or the open email's subject while Save email subjects is on (never codes, passwords, sign-ins or bank mail), and typing in webmail keeps the open email's subject."
                : "Common search and chat sites save the site only. Email sites save the folder or the open email's subject while Save email subjects is on (never codes, passwords, sign-ins or bank mail).",
            "Common banking, password, sign-in, payment, health and government sites are skipped. You can add your own below.",
            "Page titles can include other people's words, like email subjects or chat names.",
            "Work and personal Chrome profiles are both saved. Pages are kept on this Mac, unencrypted. AI apps you connect can read them, and what they read goes to their AI provider. Cloud summaries, when you turn them on, get their titles and sites.",
            // Honesty track (H8): a browser DayDream doesn't know by name is now skipped too (BrowserLookalike).
            "Other browsers, including Chrome Beta and Canary, aren't recorded in this version. A browser DayDream doesn't know by name is skipped too if it opens web links.",
            "Turning this on or removing a site disconnects the AI apps you connected until you reconnect them. If recording was off, it stays off.",
        ],"card explanation lines")
        expect(C.accessLabel == "Chrome access" && C.sitesHeader == "Sites not recorded" && C.fieldPlaceholder == "Add a site, like example.com"
               && C.fieldLabel == "Site to stop recording" && C.emptySites == "No sites added yet."
               && C.defaultsLine == "Also skipped: common banking, password, sign-in, payment, health and government sites."
               && C.showList == "Show the list" && C.unavailable == "Settings changes unavailable until safe saving is ready."
               && C.removeLabel("example.com") == "Record example.com again","card section strings")
        expect(ChromeSiteMessage.invalid.text == "Type a site like example.com." && ChromeSiteMessage.alreadyListed.text == "That site is already on your list."
               && ChromeSiteMessage.alreadySkipped.text == "That site is already skipped." && ChromeSiteMessage.full.text == "You can add up to 256 sites.","site errors")
        expect(C.message(ChromeSiteMessage.full) == "You can add up to 256 sites." && C.message(MemError.invalid("Saved text")) == "Saved text"
               && C.message(MemError.missing) == "Not saved. Try again.","card error text")
        let never=C.explanation.joined(separator:" ")
        // Typing's never, per build: a narrow build never saves what you type; the release never saves it on
        // blocked sites or in Incognito or Guest windows.
        let typingNever=TypingSettingsText.ownerBuild ? "never on blocked sites or in Incognito or Guest windows" : "what you type"
        // fix/sx-all (owner 9/28): cloud summaries get page titles and sites, and the card says so.
        expect(!never.contains("never sent to cloud summaries") && never.contains("Cloud summaries, when you turn them on, get their titles and sites."),
               "the card says cloud summaries get page titles and sites")
        for word in ["Incognito",typingNever,"Other browsers","what's on the page","Common search","doesn't know","stays off"] {
            expect(never.contains(word),"the explanation keeps the never: \(word)")
        }
        pass("card: title, details, switch label, the \(C.explanation.count) explanation lines (every never kept), site section and error texts")

        // fix/apps-declutter (owner 9/29): the card draws no line under its title and no Learn more; only the excluded
        // problem line is drawn. summaries/v3 (owner 9/28): no Turn on question; the switch goes to the host both ways.
        let cardSource=(try? String(contentsOfFile:"Sources/MemoryUI/ChromePagesSettings.swift",encoding:.utf8)) ?? ""
        expect(!cardSource.contains("Button(explanationShown") && !cardSource.contains("Text(Self.detail(") && !cardSource.contains("Text(Self.defaultsLine)")
               && !cardSource.contains("DisclosureGroup(Self.showList") && !cardSource.contains("Text(Self.emptySites)")
               && cardSource.contains("Text(Self.excludedDetail)"),"the card draws no line, Learn more, defaults line, list or empty line")
        pass("card: no line under the title and no Learn more; the switch turns on and off at once, without asking")

        // ux/declutter: the Privacy page (a count of these sites pointing here) was folded into Advanced; the
        // sites are listed and changed only in this card.
        let surfaces=(try? String(contentsOfFile:"Sources/MemoryUI/SettingsSurfaces.swift",encoding:.utf8)) ?? ""
        let host=(try? String(contentsOfFile:"Sources/MacMemApp/DaydreamSettings.swift",encoding:.utf8)) ?? ""
        expect(!surfaces.isEmpty && !host.isEmpty && !(surfaces+host).contains("Sites not recorded") && !(surfaces+host).contains("PrivacySettingsForm"),
               "no second page counts the sites")
        pass("sites: listed and changed only in Apps to remember › Web pages in Chrome")

        expect(BrowserHistoryLine.make(recording:true,pagesOn:true,access:.allowed).text == "Browser history on (Google Chrome)"
               && BrowserHistoryLine.make(recording:true,pagesOn:true,access:.denied).text == "Browser history on, but Chrome access is off"
               && BrowserHistoryLine.make(recording:true,pagesOn:true,access:.notAsked) == .needsAccess
               && BrowserHistoryLine.make(recording:false,pagesOn:true,access:.allowed) == .off
               && BrowserHistoryLine.make(recording:true,pagesOn:false,access:.allowed) == .off && BrowserHistoryLine.symbol == "globe"
               && BrowserHistoryLine.make(recording:true,pagesOn:true,access:.allowed,chromeExcluded:true) == .off,"menu line")
        // Review G30: a Chrome that can't be verified saves nothing, so the line never says on.
        expect(BrowserHistoryLine.make(recording:true,pagesOn:true,access:.unverified) != .on
               && BrowserHistoryLine.make(recording:true,pagesOn:true,access:.unverified).text == "Browser history paused: Chrome not verified",
               "menu line: an unverified Chrome is called on")
        pass("menu bar line: on / access off / paused only while recording with the switch on")

        let request=ExcludeSiteRequest(site:"example.com")
        expect(request.title == "Don't record example.com?" && request.menuTitle == "Don't Record example.com…"
               && ExcludeSiteRequest.cancelTitle == "Cancel" && ExcludeSiteRequest.confirmTitle == "Don't Record"
               && request.message == "DayDream will stop saving pages from example.com and hide the ones it already saved.",
               "exclude-site strings")
        // gold/connections-storage G48: hiding more keeps AI apps connected, so neither message says they are disconnected.
        expect(ExcludeAppRequest(bundle:"dev.zed.Zed",appName:"Zed").message == "DayDream will skip Zed from now on, and its past moments are hidden. Summaries are rewritten."
               && !request.message.contains("disconnect"),"Exclude App message no longer says AI apps are disconnected")
        pass("Don't Record <site>… and Exclude App copy (§9)")
    }

    // MARK: B. The card reads access only while the saved switch is on, and never asks

    static func host<V:View>(_ view:V,size:NSSize=NSSize(width:560,height:900)) async throws {
        let h=NSHostingView(rootView:view.frame(width:size.width,height:size.height).environment(\.controlActiveState,.active))
        window.setContentSize(size)
        window.contentView=h
        h.frame=NSRect(origin:.zero,size:size)
        h.layoutSubtreeIfNeeded()
        try await tick(0.3)
    }

    static func card() async throws {
        var checks=0,allows=0,opens=0,edits=0
        func make(savedOn:Bool,access:ChromeAccessState) -> ChromePagesCard {
            ChromePagesCard(on:.constant(savedOn),savedOn:savedOn,access:access,sites:["example.com"],enabled:true,
                            add:{_ in edits += 1},remove:{_ in edits += 1},allow:{allows += 1},openSystemSettings:{opens += 1},checkAccess:{checks += 1})
        }
        try await host(make(savedOn:false,access:.unknown))
        expect(checks == 0 && allows == 0 && opens == 0 && edits == 0,"the card read access with the switch off: checks \(checks) allows \(allows)")
        for state in [ChromeAccessState.notAsked,.chromeNotRunning,.denied,.askFailed,.unverified,.unknown,.allowed] {
            checks=0
            try await host(make(savedOn:true,access:state))
            expect(checks >= 1 && allows == 0 && opens == 0 && edits == 0,"the card with \(state): checks \(checks) allows \(allows) opens \(opens)")
        }
        // Owner decision 2026-10-03: in Settings the card is a row that opens its settings; open or closed, the card itself
        // reads access on appear, without a prompt (int-1003, 3d844d0).
        for open in [false,true] {
            checks=0
            try await host(ChromePagesCard(on:.constant(true),savedOn:true,access:.notAsked,sites:["example.com"],enabled:true,expanded:.constant(open),
                                           add:{_ in edits += 1},remove:{_ in edits += 1},allow:{allows += 1},openSystemSettings:{opens += 1},checkAccess:{checks += 1}))
            expect(checks >= 1 && allows == 0 && opens == 0 && edits == 0,"the card with its row \(open ? "open" : "closed"): checks \(checks) allows \(allows) opens \(opens)")
        }
        window.contentView=nil
        pass("card: appears → reads access only while the saved switch is on, its Settings row open or closed; showing it never asks macOS, opens System Settings or edits sites")

        // Off, the card is the title and the switch; on adds the site field, and Chrome access only while it needs a click.
        func height(on:Bool,savedOn:Bool,access:ChromeAccessState = .allowed) -> CGFloat {
            let card=ChromePagesCard(on:.constant(on),savedOn:savedOn,access:access,sites:[],enabled:true,
                                     add:{_ in},remove:{_ in},allow:{},openSystemSettings:{},checkAccess:{})
            return NSHostingView(rootView:card.frame(width:560)).fittingSize.height
        }
        let off=height(on:false,savedOn:false),on=height(on:true,savedOn:true),asking=height(on:true,savedOn:true,access:.notAsked)
        expect(off <= 60,"the off card is one row: \(off)")
        expect(on > off + 40 && on < off + 110,"on, access allowed: the site field only: \(on) vs \(off)")
        expect(asking > on + 20,"on, access not asked: the access row with Allow… too: \(asking) vs \(on)")
        pass("card: off is one row (\(Int(off)) pt); on shows the site field, and Chrome access only while it needs a click")

        // Disabled, the card says why on its own, except where the page already does (unavailableNote: false).
        func disabled(note: Bool) -> CGFloat {
            let card=ChromePagesCard(on:.constant(false),savedOn:false,access:.unknown,sites:[],enabled:false,unavailableNote:note,
                                     add:{_ in},remove:{_ in},allow:{},openSystemSettings:{},checkAccess:{})
            return NSHostingView(rootView:card.frame(width:560)).fittingSize.height
        }
        let withNote=disabled(note:true),quiet=disabled(note:false)
        expect(withNote > quiet + 8 && abs(quiet - off) < 1,"a disabled card adds its note only when asked: \(withNote) vs \(quiet) (enabled \(off))")
        pass("card: disabled, it shows its own note by default and none where the page already says why")
    }

    // MARK: F. Sources

    static func sources() {
        let app=(try? String(contentsOfFile:"Sources/MacMemApp/MacMemApp.swift",encoding:.utf8)) ?? ""
        let settings=(try? String(contentsOfFile:"Sources/MacMemApp/DaydreamSettings.swift",encoding:.utf8)) ?? ""
        let card=(try? String(contentsOfFile:"Sources/MemoryUI/ChromePagesSettings.swift",encoding:.utf8)) ?? ""
        let sender=(try? String(contentsOfFile:"Sources/MacMemApp/ChromeEventSender.swift",encoding:.utf8)) ?? ""
        let send=body(of:"static func send(",in:sender)
        expect(send.contains("noConsentPrompt") && !send.contains("permissionStatus") && !send.contains("AEDeterminePermission"),
               "capture sends suppress prompts without adding a per-event permission preflight")
        expect(ChromeEventSender.noConsentPrompt.rawValue == UInt(kAEDoNotPromptForUserConsent),"SDK consent-suppression bit")
        expect(body(of:"static var live:ChromeAccessEnvironment",in:app).contains("signatureValid(pid:$0,refresh:true)"),
               "Try Again reruns dynamic verification instead of reusing a cached failure")
        expect(card.contains("if access.offersSystemSettings") && card.contains("if let helper = access.helper"),
               "card renders recovery settings and helper guidance")
        expect(app.components(separatedBy:"ChromeEventSender.askForChromeAccess(").count == 2,"MacMemApp.swift calls askForChromeAccess once")
        let allow=body(of:"func allowChromeAccess(",in:app)
        expect(allow.contains("ChromeEventSender.askForChromeAccess(pid:pid)") && allow.contains("env.background"),"the prompt call is in allowChromeAccess, in the background")
        let check=body(of:"func checkChromeAccess()",in:app)
        expect(!check.contains("ask?(") && !check.contains("askForChromeAccess") && check.contains("env.status(pid)"),"checkChromeAccess only reads the status")
        expect(body(of:"static var live:ChromeAccessEnvironment",in:app).contains("ask:nil"),"the live environment has no stand-in prompt")
        // Owner, 10/2: two pressed routes in Settings, the Apps card and the Permissions row; both are allowChromeAccess.
        expect(settings.components(separatedBy:"model.allowChromeAccess()").count == 3 && settings.contains("allow: { model.allowChromeAccess() }")
               && settings.contains("allow: { pressed = true; model.allowChromeAccess() }"),
               "Settings' only Allow routes are the card's and the Permissions row's allow closures")
        expect(!card.contains("askForChromeAccess") && !card.contains("AEDetermine") && !card.contains("ChromeEventSender"),"the card never asks macOS itself")
        expect(settings.contains("enabled: model.preferencesAvailable && model.development == nil && !model.preferencesUnresolved,")
               && settings.contains("unavailableNote: false,") && card.contains("if !enabled && unavailableNote {"),
               "Apps to remember keeps the card disabled while choices can't save, with the page's own problem line as the only reason")
        expect(card.contains("Toggle(Self.title, isOn: switchBinding)") && card.contains("Binding(get: { on }, set: { new in on = new })")
               && !card.contains(".alert(") && !card.contains("confirmTitle"),
               "the switch writes straight to the host, with no Turn on question")
        // Setup's Start Recording asks macOS for Chrome access (pages are on by default): through allowChromeAccess, after
        // recording started, never before (consent audit 9/28).
        let onboarding=(try? String(contentsOfFile:"Sources/MacMemApp/DaydreamOnboarding.swift",encoding:.utf8)) ?? ""
        // fix/setup-status: Start Recording (once it started) and what's-new's Done (while recording) both end in finish().
        // Owner, 10/2: finish() follows up only on the Chrome row's own press (askChromeAccessAfterSetup's guard).
        let finish=onboarding.components(separatedBy:"private func finish() {").dropFirst().first?.components(separatedBy:"\n    }").first ?? ""
        let afterSetup=body(of:"func askChromeAccessAfterSetup()",in:app)
        expect(onboarding.components(separatedBy:"askChromeAccessAfterSetup()").count == 2 && finish.contains("model.askChromeAccessAfterSetup()")
               && afterSetup.contains("guard chromeSetupAsked else {return}") && afterSetup.contains("allowChromeAccess()"),
               "finishing setup asks only after the Chrome row's unanswered press, through allowChromeAccess")
        // Setup's Chrome row: its Allow is the only other route, through allowChromeAccess; the views never ask.
        let setupAsk=body(of:"func askChromeAccessInSetup()",in:app)
        let stepView=(try? String(contentsOfFile:"Sources/MemoryUI/OnboardingScreens.swift",encoding:.utf8)) ?? ""
        let cards=(try? String(contentsOfFile:"Sources/MemoryUI/PermissionSetup.swift",encoding:.utf8)) ?? ""
        expect(onboarding.components(separatedBy:"model.askChromeAccessInSetup()").count == 2
               && onboarding.contains("allow: { chromeRowLatched = true; chromeAsked = true; model.askChromeAccessInSetup() }")
               && onboarding.contains("chromeRow: chromeRow, showsAIReadsToggle: true, onStatusChange: permissionChanged")
               // Never stuck: the Chrome row never holds Continue on Permissions.
               && onboarding.contains("case .permissions: return permitted || chromeCard")
               && !onboarding.contains("case .chrome")
               && setupAsk.contains("allowChromeAccess()") && setupAsk.contains("!chromeExcluded")
               && !setupAsk.contains("askForChromeAccess") && !stepView.contains("askForChromeAccess") && !stepView.contains("AEDetermine")
               && !cards.contains("askForChromeAccess") && !cards.contains("AEDetermine") && cards.contains("Button(PermissionChromeRow.allowTitle) { row.allow() }")
               && body(of:"static var live:ChromeAccessEnvironment",in:app).contains("configuration.activates=false"),
               "setup's Chrome row on the Permissions card asks only from its Allow, through allowChromeAccess; Chrome opens in the background")
        pass("sources: askForChromeAccess is called once, inside allowChromeAccess, off main; the card only reaches it through Allow…")
    }

    // MARK: C. Production model: the switch and the owner's sites

    static func productionModel(out:URL,fake:FakeChrome) async throws -> (MemoryViewModel,URL) {
        let home=out.appendingPathComponent("chrome-pages-"+UUID().uuidString,isDirectory:true)
        let memory=home.appendingPathComponent("memory",isDirectory:true)
        try makePrivateDirectory(home);try makePrivateDirectory(memory)
        setenv("MAC_MEM_HOME",memory.path,1)
        let model=MemoryViewModel()
        model.chromeAccessEnvironment=fake.environment()
        try await tick()
        expect(!model.recordingTrial && model.development == nil && model.preferencesAvailable,"production model did not open its private store: \(model.status)")
        expect(!model.browserPages && !model.browserPagesSaved && model.savedSites.isEmpty && model.chromeAccess == .unknown,"a new store starts with Web pages in Chrome off")
        expect(model.chromePagesDiagnostics == "Off" && model.presentation.browserHistory == .off,"off: diagnostics Off, no menu line")
        expect(model.activity.excludeApp != nil && model.activity.excludeSite != nil,"production offers Exclude App and Don't Record <site>")
        pass("production model: private store, switch off, both exclusion hooks wired")
        return (model,memory)
    }

    static func sideStore(_ memory:URL) throws -> MemoryStore { try MemoryStore(home:memory,writable:true,automaticallySyncSearch:false) }
    static func connected(_ store:MemoryStore) throws -> () -> Bool {
        let token=try store.grant(client:"chrome-pages-ui",recipient:"fixture",scopes:["context"])
        return { (try? store.authorize(client:"chrome-pages-ui",recipient:"fixture",capability:token,scope:"context")) != nil }
    }

    static func switchAndSites(model:MemoryViewModel,memory:URL,fake:FakeChrome) async throws {
        let store=try sideStore(memory)
        fake.reset()
        // Setup's first answer keeps keys made before Start (consent audit 9/28); this is a later Settings change, so the
        // first answer (Off, nothing changed) is given first, as setup does.
        let first=try store.policy()
        _=try store.savePreferences(MemoryPreferences(blockedApps:first.blockedApps,nativeTyping:false,typingChoiceShown:true),expectedRevision:first.revision)
        expect(try !store.nativeTypingChoicePending() && store.policy().revision == first.revision,"the first answer (Off) is given and changes nothing")
        var aiApp=try connected(store)
        expect(aiApp(),"the fixture AI app is connected before the change")
        model.stopped=false // as if recording had been on: the save path must stop it at once
        model.setBrowserPages(true)
        expect(model.stopped,"turning the switch on did not stop recording synchronously")
        expect(model.browserPages && !model.browserPagesSaved && model.preferencesUnresolved,"the switch is a draft until the debounce saves it")
        expect(try await waitUntil {!model.preferencesUnresolved},"the switch never saved: \(model.privacySaveStatus)")
        let saved=try store.policy()
        expect(model.browserPagesSaved && saved.browserPages && saved.browserPagesConsentVersion == PrivacySettings.browserPagesConsentCurrent && saved.browserPagesOn,"the switch did not save with this build's consent version (\(PrivacySettings.browserPagesConsentCurrent))")
        expect(!aiApp(),"turning the switch on left an AI app connected")
        // Apps to remember says which AI apps were disconnected (one line, with Reconnect), and Connections says why.
        // Connections gives the Apps change as the reason while a key it lists is stopped; the reason is dropped once none
        // is (gold latch fix), and this fixture's AI app isn't one Connections lists, so its re-read may already have.
        expect(model.aiAppsDisconnected && (model.connection.disconnectedByAppsChange
                                            || !model.connection.rows.contains { $0.state == .needsAttention(.keyStopped) }),
               "the save that disconnected an AI app left no line on Apps to remember")
        expect(model.privacySaveStatus.contains("Recording is stopped.") && model.privacySaveStatus.contains("Connections need separate approval again."),
               "save status: \(model.privacySaveStatus)")
        expect(!model.recording && model.presentation.browserHistory == .off,"the menu line shows while not recording")
        expect(fake.count("ask") == 0 && fake.count("status") == 0,"saving the switch touched Chrome access")
        pass("switch on: saved with this build's consent version through the autosave path, recording stopped first, AI apps disconnected, no Chrome call")

        // Add.
        aiApp=try connected(store)
        try model.addSite("  Example.COM ")
        let addedSites=try store.policy().blockedDomains
        expect(model.savedSites == ["example.com"] && addedSites == ["example.com"],"addSite did not save: \(model.savedSites)")
        expect(aiApp() && model.stopped && !model.preferencesUnresolved,"addSite did not take the save path, or it disconnected an AI app")
        expect(!model.privacySaveStatus.contains("Connections need separate approval again."),"adding a site says connections need approval: \(model.privacySaveStatus)")
        expect(thrownText {try model.addSite("not a site")} == "Type a site like example.com.","invalid site")
        expect(thrownText {try model.addSite("")} == "Type a site like example.com.","empty site")
        expect(thrownText {try model.addSite("www.example.com")} == "That site is already on your list.","already listed")
        expect(thrownText {try model.addSite("plannedparenthood.org")} == "That site is already skipped.","default-skipped site")
        try model.addSite("news.example.org")
        expect(model.savedSites == ["example.com","news.example.org"],"second site: \(model.savedSites)")
        pass("addSite: saves the site entry now (recording stops, AI apps stay connected); invalid, already listed and already skipped say so")

        // Remove.
        aiApp=try connected(store)
        try model.removeSite("news.example.org")
        let removedSites=try store.policy().blockedDomains
        expect(model.savedSites == ["example.com"] && removedSites == ["example.com"] && !aiApp(),"removeSite: \(model.savedSites)")
        let revision=try store.policy().revision
        try model.removeSite("not-listed.example")
        expect((try store.policy().revision) == revision,"removing an unlisted site saved something")
        pass("removeSite: records a site again through the same save; an unlisted site changes nothing")

        // Don't Record <site>… through the hook the timeline and the Moment menu use.
        guard let hook=model.activity.excludeSite else {fail("the excludeSite hook is missing")}
        aiApp=try connected(store)
        try await hook("www.github.com")
        expect(model.savedSites == ["example.com","github.com"] && aiApp(),"the hook did not save github.com, or it disconnected an AI app: \(model.savedSites)")
        let afterHook=try store.policy().revision
        try await hook("github.com")
        try await hook("plannedparenthood.org")
        expect((try store.policy().revision) == afterHook,"an already skipped site saved again")
        var hookError:String?
        do {try await hook("not a site")} catch MemError.invalid(let text) {hookError=text} catch {hookError="\(error)"}
        expect(hookError == "This site can't be skipped. Nothing was saved.","invalid hook site: \(hookError ?? "no error")")
        pass("Don't Record <site>… hook: saves the site, returns silently when already skipped, refuses an invalid site")

        // Guards: unsaved preferences block every site change and hide the hooks.
        let apps=model.blockedApps
        model.blockedApps="dev.zed.Zed"
        try await tick()
        // The one sentence Settings shows for it (PreferenceProblem.changedElsewhere), and what didn't happen.
        expect(thrownText {try model.addSite("new.example.org")} == "Your saved choices changed while this page was open. Nothing was changed.","addSite over unsaved preferences")
        expect(thrownText {try model.excludeSite("new.example.org")} == "Your saved choices changed while this page was open. Nothing was changed.","excludeSite over unsaved preferences")
        expect(model.activity.excludeSite == nil && model.activity.excludeApp == nil,"the hooks stayed over unsaved preferences")
        model.blockedApps=apps
        try await tick()
        expect(model.activity.excludeSite != nil,"the site hook did not come back")
        pass("guards: unsaved preferences refuse site changes and hide Don't Record, like Exclude App")

        // A full list: 256 sites saved elsewhere, then reloaded.
        let current=try store.policy()
        let many=(0..<256).map {"s\($0).example.org"}
        _=try store.savePreferences(MemoryPreferences(blockedApps:current.blockedApps,nativeTyping:current.captureText && current.typedConsentVersion == 1,
                                                      blockedDomains:many),expectedRevision:current.revision)
        model.reloadPreferences()
        try await tick()
        expect(model.savedSites.count == 256 && !model.preferencesUnresolved,"reload did not pick up 256 sites: \(model.savedSites.count)")
        expect(thrownText {try model.addSite("new.example.org")} == "You can add up to 256 sites.","full list")
        expect(thrownText {try model.addSite("s1.example.org")} == "That site is already on your list.","full list, listed site")
        expect(thrownText {try model.excludeSite("new.example.org")} == "You can add up to 256 sites.","full list, excludeSite")
        try model.removeSite("s1.example.org")
        try model.addSite("new.example.org")
        expect(model.savedSites.count == 256 && model.savedSites.contains("new.example.org"),"a freed slot takes a new site")
        let restored=try store.policy()
        _=try store.savePreferences(MemoryPreferences(blockedApps:restored.blockedApps,nativeTyping:restored.captureText && restored.typedConsentVersion == 1,
                                                      blockedDomains:["example.com","github.com"]),expectedRevision:restored.revision)
        model.reloadPreferences()
        try await tick()
        expect(model.savedSites == ["example.com","github.com"] && model.browserPagesSaved,"restore: \(model.savedSites)")
        pass("full list: 256 sites refuse another with the exact text; removing one frees a slot")

        // An unrelated save keeps the sites (they go only when they changed).
        aiApp=try connected(store)
        model.blockedApps=apps.isEmpty ? "dev.zed.Zed" : apps+", dev.zed.Zed"
        model.savePolicy()
        try await tick()
        expect(try await waitUntil {!model.preferencesUnresolved},"the app save never landed: \(model.privacySaveStatus)")
        expect(model.savedSites == ["example.com","github.com"] && model.browserPagesSaved,"an app change moved the sites or the switch")
        model.blockedApps=apps
        model.savePolicy()
        expect(try await waitUntil {!model.preferencesUnresolved},"the app save never landed")
        pass("an app change keeps the saved sites and the switch")
    }

    // MARK: D. Chrome access with the fake

    static func access(model:MemoryViewModel,fake:FakeChrome) async throws {
        // Not running: no background call at all.
        fake.reset();fake.set(pid:nil)
        model.checkChromeAccess()
        expect(model.chromeAccess == .chromeNotRunning && fake.count("verify") == 0 && fake.count("status") == 0 && fake.count("ask") == 0,
               "not running: \(model.chromeAccess)")
        expect(model.chromePagesDiagnostics == "On. Open Google Chrome to check access.","diagnostics while Chrome is closed")
        // Each status, read without a prompt.
        for (status,state) in [(OSStatus(0),ChromeAccessState.allowed),(-1744,.notAsked),(-1743,.denied),(-600,.chromeNotRunning),(-50,.unknown)] {
            fake.reset();fake.set(status:status)
            model.checkChromeAccess()
            expect(model.chromeAccess == .checking,"a read shows Checking… while it runs")
            expect(try await waitUntil {model.chromeAccess != .checking},"the read never finished")
            expect(model.chromeAccess == state,"status \(status) read as \(model.chromeAccess)")
            expect(fake.count("verify") == 1 && fake.count("status") == 1 && fake.count("ask") == 0,"a read asked: \(fake.count("ask"))")
        }
        expect(fake.mainThreadCalls.isEmpty,"a Chrome call ran on the main thread: \(fake.mainThreadCalls)")
        expect(model.chromePagesDiagnostics == "On","diagnostics after an unknown read: \(model.chromePagesDiagnostics)")
        fake.reset();fake.set(verified:false)
        model.checkChromeAccess()
        expect(try await waitUntil {model.chromeAccess != .checking} && model.chromeAccess == .unverified,"unverified: \(model.chromeAccess)")
        expect(fake.count("status") == 0 && fake.count("ask") == 0,"an unverified Chrome was asked for its status")
        expect(model.chromePagesDiagnostics == "On, but this copy of Chrome can't be verified","diagnostics unverified")
        fake.reset();fake.set(status:-1743)
        model.checkChromeAccess()
        expect(try await waitUntil {model.chromeAccess == .denied},"denied read")
        expect(model.chromePagesDiagnostics == "On, but Chrome access is off","diagnostics denied")
        pass("check: never asks; off main; noErr / −1744 / −1743 / −600 / other map to their states; not running or unverified reads nothing")

        // Allow…: running → verified → ask, once, off main.
        fake.reset();fake.set(status:-1744,answer:0)
        model.allowChromeAccess()
        model.allowChromeAccess() // a second press while macOS is asking does nothing
        model.checkChromeAccess() // nor does a read
        expect(try await waitUntil {model.chromeAccess == .allowed},"Allow did not end allowed: \(model.chromeAccess)")
        try await tick(0.1)
        expect(fake.count("ask") == 1 && fake.count("verify") == 1 && fake.count("status") == 0,"Allow asked \(fake.count("ask")) times, read \(fake.count("status"))")
        expect(fake.mainThreadCalls.isEmpty,"Allow asked on the main thread")
        fake.reset();fake.set(answer:-1743)
        model.allowChromeAccess()
        expect(try await waitUntil {model.chromeAccess == .denied} && fake.count("ask") == 1,"a declined prompt: \(model.chromeAccess)")
        // Live test (build 7): Allow… refused at once, with no question from macOS: say where to allow it, and keep
        // saying so while later reads say "not asked" or "turned off"; allowed clears it.
        fake.reset();fake.set(answer:-1743,askSeconds:0.1)
        model.allowChromeAccess()
        expect(try await waitUntil {model.chromeAccess == .askFailed} && fake.count("ask") == 1,"Allow refused with no question: \(model.chromeAccess)")
        expect(model.chromeAccess.buttonTitle == "Allow…" && model.chromeAccess.offersSystemSettings && model.chromeAccess.helper?.contains("Press Allow…") == true
               && model.chromePagesDiagnostics == "On, but Chrome access is off","no question: the plain line and the System Settings button")
        fake.reset();fake.set(status:-1744)
        model.checkChromeAccess()
        try await tick(0.2)
        expect(try await waitUntil {model.chromeAccess == .askFailed},"no question, then a read says not asked: still System Settings: \(model.chromeAccess)")
        model.chromeAccessFromPages(.status(-1743))
        expect(model.chromeAccess == .askFailed,"no question, then a page read says turned off: still System Settings: \(model.chromeAccess)")
        fake.reset();fake.set(answer:-1744,askSeconds:0.1)
        model.allowChromeAccess()
        expect(try await waitUntil {model.chromeAccess == .askFailed},"Allow answered not asked: System Settings: \(model.chromeAccess)")
        fake.reset();fake.set(status:0)
        model.checkChromeAccess()
        expect(try await waitUntil {model.chromeAccess == .allowed},"allowed in System Settings: \(model.chromeAccess)")
        fake.reset();fake.set(status:-1744)
        model.checkChromeAccess()
        expect(try await waitUntil {model.chromeAccess == .notAsked},"after allowed, a reset reads not asked again: \(model.chromeAccess)")
        fake.reset();fake.set(pid:nil)
        model.allowChromeAccess()
        expect(model.chromeAccess == .chromeNotRunning && fake.count("ask") == 0 && fake.count("verify") == 0,"Allow with Chrome closed asked")
        fake.reset();fake.set(verified:false)
        model.allowChromeAccess()
        expect(try await waitUntil {model.chromeAccess == .unverified} && fake.count("ask") == 0,"Allow asked an unverified Chrome")
        pass("Allow…: asks exactly once, off main, only when Chrome is running and verified; the answer is the new state")

        // Owner, 10/2: setup's Start Recording never asks by itself. Without a press of the Chrome row's Allow, nothing
        // asks now or when Chrome next comes forward (Settings' Allow… stays the way).
        expect(model.browserPagesSaved,"the fixture: Web pages in Chrome is saved on")
        fake.reset();fake.set(status:-1744,answer:0)
        model.askChromeAccessAfterSetup()
        try await tick(0.2)
        expect(fake.count("ask") == 0 && fake.waitingActivations == 0 && !model.chromeSetupAsked,
               "setup without the row's press asks nothing: asks=\(fake.count("ask")) waiting=\(fake.waitingActivations)")
        fake.reset();fake.set(pid:nil)
        model.askChromeAccessAfterSetup()
        expect(fake.count("ask") == 0 && fake.waitingActivations == 0,"setup without the press never waits for Chrome to ask")
        pass("setup's Start Recording asks nothing by itself: macOS's question only follows the Chrome row's Allow")

        // Setup's Chrome row (owner, 10/2; was its own page 10/1): its Allow asks now; with Chrome closed it opens Chrome
        // first, then asks. Once macOS answered there, finishing setup asks nothing more.
        expect(!MemoryViewModel.chromeAnswered(.checking) && !MemoryViewModel.chromeAnswered(.chromeNotRunning)
               && !MemoryViewModel.chromeAnswered(.notAsked) && MemoryViewModel.chromeAnswered(.allowed)
               && MemoryViewModel.chromeAnswered(.denied) && MemoryViewModel.chromeAnswered(.askFailed),"answered: allowed, denied or ask failed only")
        fake.reset();fake.set(status:-1744,answer:0);fake.set(installed:true,opensAs:4343)
        model.askChromeAccessInSetup()
        expect(try await waitUntil {model.chromeAccess == .allowed} && fake.count("ask") == 1 && fake.opens == 0 && model.chromeSetupAsked,
               "setup step with Chrome running asks once and opens nothing: \(model.chromeAccess) asks=\(fake.count("ask")) opens=\(fake.opens)")
        model.askChromeAccessAfterSetup()
        try await tick(0.2)
        expect(fake.count("ask") == 1 && fake.waitingActivations == 0,"finishing setup after the step's answer asked again")
        fake.reset();fake.set(pid:nil,status:-1744,answer:-1743);fake.set(installed:true,opensAs:4343)
        model.askChromeAccessInSetup();model.askChromeAccessInSetup()
        expect(try await waitUntil {model.chromeAccess == .denied} && fake.count("ask") == 1 && fake.opens == 1 && fake.mainThreadCalls.isEmpty,
               "setup step with Chrome closed opens Chrome once (a second press while it opens adds nothing), then asks once off main: \(model.chromeAccess) asks=\(fake.count("ask")) opens=\(fake.opens)")
        fake.reset();fake.set(pid:nil);fake.set(installed:true,opensAs:nil)
        model.askChromeAccessInSetup()
        expect(try await waitUntil {model.chromeAccess == .chromeNotRunning} && fake.count("ask") == 0 && fake.opens == 1,
               "setup row: Chrome that doesn't open asks nothing: \(model.chromeAccess)")
        expect(DaydreamChromeStepContent.line(access:.chromeNotRunning,asked:true) == DaydreamChromeStepContent.laterLine
               && DaydreamChromeStepContent.line(access:.chromeNotRunning,asked:false) == nil
               && DaydreamChromeStepContent.line(access:.denied,asked:true) == nil && DaydreamChromeStepContent.line(access:.checking,asked:true) == nil
               && DaydreamChromeStepContent.line(access:.unverified,asked:true) == ChromeAccessState.unverified.helper,
               "setup step: no line before the press or after an answer; a press macOS couldn't answer says why")
        // A press macOS couldn't answer (Chrome didn't open): finishing setup asks once, when Chrome next comes forward.
        model.askChromeAccessAfterSetup();model.askChromeAccessAfterSetup()
        expect(fake.count("ask") == 0 && fake.waitingActivations == 1,"pressed, unanswered: finishing setup waits once for Chrome")
        fake.set(pid:4242,status:-1744,answer:0)
        fake.activateChrome()
        expect(try await waitUntil {model.chromeAccess == .allowed} && fake.count("ask") == 1,
               "pressed, unanswered: Chrome's next activation asks once: \(model.chromeAccess) asks=\(fake.count("ask"))")
        fake.reset();fake.set(pid:nil);fake.set(installed:false,opensAs:4343)
        model.askChromeAccessInSetup()
        expect(model.chromeAccess == .chromeNotRunning && fake.opens == 0 && fake.count("ask") == 0 && !model.chromeInstalled,
               "setup row: Chrome not installed opens and asks nothing")
        fake.set(installed:true,opensAs:4343)
        // The row's control and line for every state: each has a way on, none holds Continue.
        typealias Row = PermissionChromeRow
        expect(Row.trailing(access:.checking) == .progress && Row.trailing(access:.allowed) == .allowed
               && Row.trailing(access:.denied) == .refused && Row.trailing(access:.askFailed) == .refused
               && [ChromeAccessState.unknown,.notAsked,.chromeNotRunning,.unverified,.twoCopies].allSatisfy {Row.trailing(access:$0) == .allow},
               "setup row: spinner while asking, Allowed, System Settings once refused, else Allow")
        expect(Row.line(access:.notAsked,asked:false) == nil && Row.line(access:.chromeNotRunning,asked:true) == DaydreamChromeStepContent.laterLine
               && Row.line(access:.unverified,asked:true) == ChromeAccessState.unverified.helper
               && Row.line(access:.denied,asked:true) == ChromeAccessState.denied.helper && Row.line(access:.denied,asked:false) == nil
               && Row.line(access:.allowed,asked:true) == nil,
               "setup row: no line before the press; after it, why macOS gave no answer or where to allow it")
        expect(Row.title == "Google Chrome" && Row.allowTitle == "Allow" && Row.reason == ChromePagesCard.setupLine,"setup row: its words")
        pass("setup's Chrome row asks once on its press (opening a closed Chrome first); finishing setup asks only after an unanswered press")

        // A late read never overwrites a newer one.
        fake.reset();fake.set(status:-1743)
        model.checkChromeAccess()
        fake.set(pid:nil)
        model.checkChromeAccess()
        try await tick(0.2)
        expect(model.chromeAccess == .chromeNotRunning,"an older read overwrote a newer one: \(model.chromeAccess)")
        pass("check: a read that finishes late never replaces a newer one")

        // Review G30: the menu bar line follows what page history's own reads learn (Chrome can't be verified,
        // access turned off, working again), and keeps the last answer while a check runs (never flips).
        func line() -> BrowserHistoryLine {BrowserHistoryLine.make(recording:true,pagesOn:true,access:model.chromeAccessShown)}
        fake.reset();fake.set(status:0)
        model.checkChromeAccess()
        expect(try await waitUntil {model.chromeAccess == .allowed} && line() == .on,"allowed: \(model.chromeAccess)")
        model.chromeAccessFromPages(.unverified)
        expect(model.chromeAccess == .unverified && line() == .paused,"a page read that can't verify Chrome: \(model.chromeAccess) \(line())")
        model.chromeAccessFromPages(.status(-1743))
        expect(model.chromeAccess == .denied && line() == .needsAccess,"a page read with access off: \(model.chromeAccess) \(line())")
        fake.reset();fake.set(status:-1743)
        model.checkChromeAccess()
        expect(model.chromeAccess == .checking && line() == .needsAccess,"the line changed while a check ran: \(line())")
        expect(try await waitUntil {model.chromeAccess == .denied} && line() == .needsAccess,"denied read: \(model.chromeAccess)")
        model.chromeAccessFromPages(.status(0))
        expect(model.chromeAccess == .allowed && line() == .on,"a page read that works: \(model.chromeAccess)")
        fake.reset();fake.set(status:0)
        model.checkChromeAccess()
        model.chromeAccessFromPages(.status(-1743))
        try await tick(0.2)
        expect(model.chromeAccess == .denied,"a check started before a page read overwrote it: \(model.chromeAccess)")
        let host=(try? String(contentsOfFile:"Sources/MacMemApp/MacMemApp.swift",encoding:.utf8)) ?? ""
        expect(host.contains("next.pages.onAccess = { [weak self] access in MainActor.assumeIsolated { self?.chromeAccessFromPages(access) } }")
               && host.contains("access:chromeAccessShown,chromeExcluded:chromeExcluded)"),"the app wires page history's reads to the menu line")
        pass("menu line (G30): follows page history's reads, and keeps the last answer while a check runs")

        // Live test (build 7): two of the person's own Chromes (a headless one is never counted: ChromeProcesses) say
        // so, never "If Chrome just updated": the one in front is checked, and nothing is read until one quits.
        fake.reset();fake.set(status:0,copies:2)
        model.checkChromeAccess()
        expect(try await waitUntil {model.chromeAccess == .twoCopies} && line() == .twoCopies,"two copies: \(model.chromeAccess) \(line())")
        expect(model.chromeAccess.helper?.contains("just updated") == false && model.chromePagesDiagnostics == "On, but two copies of Chrome are open",
               "two copies: \(model.chromeAccess.helper ?? "") / \(model.chromePagesDiagnostics)")
        fake.reset();fake.set(status:-1743,copies:2)
        model.checkChromeAccess()
        expect(try await waitUntil {model.chromeAccess == .denied},"two copies with access off still says access is off: \(model.chromeAccess)")
        model.chromeAccessFromPages(.twoCopies)
        expect(model.chromeAccess == .twoCopies && line() == .twoCopies,"page history's two-copies read: \(model.chromeAccess)")
        model.chromeAccessFromPages(.status(0))
        expect(model.chromeAccess == .allowed && line() == .on,"one copy again: \(model.chromeAccess)")
        expect(body(of:"static var live:ChromeAccessEnvironment",in:host).contains("running:{ChromeEventSender.chosenProcess()}"),
               "the live environment checks the person's Chrome, never the first process")
        pass("two copies of Chrome: said plainly in Settings, Diagnostics and the menu line; never the Chrome-updated line")
    }

    /// Owner, 10/2: an upgrade never asks by itself. A finished setup (v2) whose verified Chrome reads "not asked" gets
    /// setup's Permissions card once (`DaydreamChromeCard`, a persistent receipt); allowed, denied, unverified, not installed,
    /// excluded or page history off: nothing opens and nothing asks. Real model, private UserDefaults, fake Chrome calls.
    static func upgradeAccess(model:MemoryViewModel,fake:FakeChrome,out:URL) async throws {
        let suite="checks.chrome-upgrade."+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite);model.chromeAccessEnvironment=fake.environment();model.openSetupWindow=nil}
        var finished=true,opened=0
        model.openSetupWindow={opened += 1}
        func environment(_ store:UserDefaults=defaults) -> ChromeAccessEnvironment {
            var env=fake.environment()
            env.version={"0.1.4"}
            env.setupFinished={finished}
            env.cardShown={store.bool(forKey:DaydreamChromeCard.shownKey)}
            env.markCardShown={store.set(true,forKey:DaydreamChromeCard.shownKey)}
            return env
        }
        func reset() {defaults.removeObject(forKey:DaydreamChromeCard.shownKey);model.chromeCardRequested=false;opened=0}
        model.chromeAccessEnvironment=environment()
        // v2 user, Chrome allowed / denied / unverified: nothing opens, nothing asks.
        for (status,verified,state) in [(Int32(0),true,ChromeAccessState.allowed),(-1743,true,.denied),(-1744,false,.unverified)] {
            reset();fake.reset();fake.set(verified:verified,status:status)
            model.checkChromeAccess()
            expect(try await waitUntil {model.chromeAccess == state} && fake.count("ask") == 0 && !model.chromeCardRequested && opened == 0,
                   "upgrade with Chrome \(state): no card, no question (asks=\(fake.count("ask")) card=\(model.chromeCardRequested))")
        }
        // v2 user, Chrome not asked: the card opens once; macOS isn't asked (the card's Allow asks).
        reset();fake.reset();fake.set(status:-1744,answer:0)
        model.checkChromeAccess()
        expect(try await waitUntil {model.chromeAccess == .notAsked} && model.chromeCardRequested && opened == 1 && fake.count("ask") == 0
               && defaults.bool(forKey:DaydreamChromeCard.shownKey),"upgrade with Chrome not asked: the Permissions card opens, nothing asks")
        model.chromeCardRequested=false
        model.checkChromeAccess()
        expect(try await waitUntil {model.chromeAccess == .notAsked} && !model.chromeCardRequested && opened == 1 && fake.count("ask") == 0,
               "the card opens once: a second read opens nothing")
        let reopened=UserDefaults(suiteName:suite)!
        model.chromeAccessEnvironment=environment(reopened)
        model.checkChromeAccess()
        expect(try await waitUntil {model.chromeAccess == .notAsked} && !model.chromeCardRequested && fake.count("ask") == 0,"the card's receipt survives reopening defaults")
        model.chromeAccessEnvironment=environment()
        // The card's Allow is the one ask (setup's row press).
        fake.reset();fake.set(status:-1744,answer:0)
        model.askChromeAccessInSetup()
        expect(try await waitUntil {model.chromeAccess == .allowed} && fake.count("ask") == 1 && fake.mainThreadCalls.isEmpty,"the card's Allow asks once, off main")
        // Not installed: nothing opens.
        reset();fake.reset();fake.set(status:-1744);fake.set(installed:false,opensAs:nil)
        model.checkChromeAccess()
        expect(try await waitUntil {model.chromeAccess == .notAsked} && !model.chromeCardRequested && opened == 0 && fake.count("ask") == 0,
               "upgrade without Chrome installed: no card")
        fake.set(installed:true,opensAs:4343)
        // A first setup still in progress has the row: no separate card.
        reset();finished=false;fake.reset();fake.set(status:-1744)
        model.checkChromeAccess()
        expect(try await waitUntil {model.chromeAccess == .notAsked} && !model.chromeCardRequested && fake.count("ask") == 0,"setup not finished: no card")
        finished=true
        // Chrome closed: nothing now; Chrome's next activation reads, then the card opens (never a question).
        reset();fake.reset();fake.set(pid:nil,status:-1744)
        model.checkChromeAccess();model.checkChromeAccess()
        expect(fake.waitingActivations == 1 && fake.count("ask") == 0 && !model.chromeCardRequested,"Chrome closed waits for just one activation")
        fake.set(pid:4242,status:-1744)
        fake.activateChrome()
        expect(try await waitUntil {model.chromeCardRequested} && fake.count("ask") == 0 && opened == 1,"Chrome's next activation opens the card, asks nothing")
        // Excluded Chrome and page history off: no card.
        let originalApps=model.blockedApps
        model.blockedApps=ChromePageTarget.bundleID
        model.savePolicy()
        expect(try await waitUntil {!model.preferencesUnresolved} && model.chromeExcluded,"fixture excluded Chrome")
        reset();fake.reset();fake.set(status:-1744)
        model.checkChromeAccess()
        expect(try await waitUntil {model.chromeAccess == .notAsked} && fake.count("ask") == 0 && !model.chromeCardRequested,"excluded Chrome: no card")
        model.blockedApps=originalApps;model.savePolicy()
        expect(try await waitUntil {!model.preferencesUnresolved},"fixture restored app choices")
        model.setBrowserPages(false)
        expect(try await waitUntil {!model.preferencesUnresolved} && !model.browserPagesSaved,"fixture pages off")
        reset();fake.reset();fake.set(status:-1744)
        model.checkChromeAccess()
        expect(try await waitUntil {model.chromeAccess == .notAsked} && fake.count("ask") == 0 && !model.chromeCardRequested,"pages off: no card")
        model.chromeAccessEnvironment=fake.environment()
        model.setBrowserPages(true)
        expect(try await waitUntil {!model.preferencesUnresolved} && model.browserPagesSaved,"fixture pages restored")
        // Sources: no read asks; the only automatic path left is the card.
        let app=(try? String(contentsOfFile:"Sources/MacMemApp/MacMemApp.swift",encoding:.utf8)) ?? ""
        let read=body(of:"private func chromeAccessRead(",in:app)
        expect(!read.contains("allowChromeAccess(") && read.contains("DaydreamChromeCard.opens("),"sources: a read never asks; it may only open the card")
        pass("upgrade: v2 with Chrome not asked gets the Permissions card once (receipt kept); allowed, denied, unverified, not installed, excluded, pages off and an unfinished setup get nothing; nothing ever asks without the card")
    }

    // MARK: D3. Owner, 10/2: Chrome on Settings › Permissions; access granted turns recording Chrome on

    static func grantTurnsOnPages(model:MemoryViewModel,fake:FakeChrome) async throws {
        typealias Row=PermissionChromeRow
        func pages(_ on:Bool) async throws {
            model.setBrowserPages(on)
            expect(try await waitUntil {!model.preferencesUnresolved} && model.browserPagesSaved == on,"fixture: pages \(on ? "on" : "off") saved")
        }
        // Already on: a grant leaves it on and saves nothing.
        try await pages(true)
        fake.reset();fake.set(status:-1744,answer:0)
        model.allowChromeAccess()
        expect(try await waitUntil {model.chromeAccess == .allowed} && fake.count("ask") == 1,"grant (pages on): allowed after one question")
        try await tick(0.1)
        expect(model.browserPages && model.browserPagesSaved && !model.preferencesUnresolved,"grant with pages already on: unchanged, no save queued")
        pass("grant with Save web pages already on: it stays on, nothing is saved again")
        // Off: Settings' Allow, granted, turns it on and saves it.
        try await pages(false)
        fake.reset();fake.set(status:-1744,answer:0)
        model.allowChromeAccess()
        expect(try await waitUntil {model.chromeAccess == .allowed} && fake.count("ask") == 1,"grant (pages off): allowed after one question")
        expect(try await waitUntil {model.browserPagesSaved && !model.preferencesUnresolved} && model.browserPages,"grant with pages off: Save web pages turned on and saved")
        pass("grant from Settings' Allow: Save web pages in Google Chrome turns on and is saved")
        // Off, denied: the toggle stays off; the row offers System Settings and says where.
        try await pages(false)
        fake.reset();fake.set(status:-1744,answer:-1743)
        model.allowChromeAccess()
        expect(try await waitUntil {model.chromeAccess == .denied} && fake.count("ask") == 1,"denied: \(model.chromeAccess)")
        try await tick(0.2)
        expect(!model.browserPages && !model.browserPagesSaved,"denied: the toggle stays off")
        expect(Row.trailing(access:.denied,pagesOn:false,canTurnOn:true) == .refused && ChromeAccessState.denied.offersSystemSettings
               && Row.line(access:.denied,asked:false,pagesOn:false,settings:true) == ChromeAccessState.denied.helper
               && Row.line(access:.askFailed,asked:false,pagesOn:true,settings:true) == ChromeAccessState.askFailed.helper,
               "denied: System Settings and the line saying where to allow it")
        pass("denied: the toggle is unchanged; the row's way on is Open System Settings with its line")
        // Allowed (in System Settings), pages off: a read never turns it on; the row says so and offers Turn On.
        fake.reset();fake.set(status:0)
        model.checkChromeAccess()
        expect(try await waitUntil {model.chromeAccess == .allowed} && fake.count("ask") == 0,"allowed read: \(model.chromeAccess)")
        try await tick(0.2)
        expect(!model.browserPages && !model.browserPagesSaved,"a read of allowed access never turns recording on")
        expect(Row.trailing(access:.allowed,pagesOn:false,canTurnOn:true) == .turnOn && Row.turnOnTitle == "Turn On"
               && Row.line(access:.allowed,asked:false,pagesOn:false,settings:true) == Row.pagesOffLine
               && Row.trailing(access:.allowed,pagesOn:true,canTurnOn:true) == .allowed && Row.line(access:.allowed,asked:false,pagesOn:true,settings:true) == nil
               && Row.trailing(access:.allowed,pagesOn:false,canTurnOn:false) == .allowed,
               "allowed with pages off: Turn On and its line; on: Allowed and no line; setup's row (no Turn On): Allowed")
        let row=Row(icon:nil,access:model.chromeAccess,asked:false,allow:{},openSettings:{},pagesOn:model.browserPages,turnOn:{model.setBrowserPages(true)},settings:true)
        row.turnOn?()
        expect(try await waitUntil {model.browserPagesSaved && !model.preferencesUnresolved},"Turn On: one click turns recording Chrome on")
        pass("allowed with recording off: the row says so and Turn On turns it on in one click")
        // Turning recording off revokes nothing and asks nothing.
        fake.reset();fake.set(status:0)
        try await pages(false)
        expect(model.chromeAccess == .allowed && fake.count("ask") == 0,"turning recording off changed access: \(model.chromeAccess)")
        pass("turning Save web pages off leaves Chrome access as it is")
        // Setup's card Allow with pages off (Chrome running, then closed and opened by the press): asks, then turns it on.
        for closed in [false,true] {
            try await pages(false)
            fake.reset();fake.set(pid:closed ? nil : 4242,status:-1744,answer:0);fake.set(installed:true,opensAs:4343)
            model.askChromeAccessInSetup()
            expect(try await waitUntil {model.chromeAccess == .allowed} && fake.count("ask") == 1 && fake.opens == (closed ? 1 : 0),
                   "setup card Allow (Chrome \(closed ? "closed" : "running"), pages off): asked once: \(model.chromeAccess) asks=\(fake.count("ask"))")
            expect(try await waitUntil {model.browserPagesSaved && !model.preferencesUnresolved},"setup card grant turns Save web pages on")
        }
        fake.set(pid:4242);fake.set(installed:true,opensAs:4343)
        pass("setup card's Allow with recording off: asks once (opening Chrome if closed), and the grant turns it on")
        // Sources: Settings › Permissions has the row; its Allow is the app's one ask path; shown whenever Chrome is installed.
        let settings=(try? String(contentsOfFile:"Sources/MacMemApp/DaydreamSettings.swift",encoding:.utf8)) ?? ""
        let perms=body(of:"struct DaydreamSettingsPermissions",in:settings)
        expect(settings.contains("DaydreamSettingsScroll { DaydreamSettingsPermissions(model: model) }") && perms.contains("chromeRow: chromeRow")
               && perms.contains("model.allowChromeAccess()") && !perms.contains("askForChromeAccess") && !perms.contains("AEDetermine")
               && perms.contains("DaydreamChromeGrant.settingsRowShown(") && perms.contains("turnOn: { model.setBrowserPages(true) }"),
               "sources: Settings › Permissions shows the Chrome row; Allow is allowChromeAccess; Turn On sets the switch")
        expect(DaydreamChromeGrant.settingsRowShown(release:true,installed:true) && !DaydreamChromeGrant.settingsRowShown(release:true,installed:false)
               && !DaydreamChromeGrant.settingsRowShown(release:false,installed:true),"the Settings row shows whenever Chrome is installed")
        try await pages(true)
        pass("Settings › Permissions: Chrome is a row like Accessibility, always there while Chrome is installed")
    }

    // MARK: E. Settings › Apps to remember on the production model

    static func hostedSettings(model:MemoryViewModel,fake:FakeChrome) async throws {
        fake.reset();fake.set(status:-1744)
        model.settingsSection="Recording"
        try await host(MemorySettings(model:model),size:NSSize(width:760,height:600))
        expect(try await waitUntil {fake.count("status") >= 1},"Apps to remember did not read Chrome access with the switch on")
        expect(try await waitUntil {model.chromeAccess == .notAsked},"the hosted card did not show the read: \(model.chromeAccess)")
        try await tick(0.2)
        expect(fake.count("ask") == 0,"showing Apps to remember asked macOS")
        window.contentView=nil
        try await tick(0.1)
        pass("Settings › Apps to remember: the card reads access on appear (no prompt) and shows Not allowed yet")
    }

    static func switchOff(model:MemoryViewModel,memory:URL,fake:FakeChrome) async throws {
        let store=try sideStore(memory)
        let aiApp=try connected(store)
        model.setBrowserPages(false)
        expect(model.stopped,"turning the switch off did not stop recording first")
        expect(try await waitUntil {!model.preferencesUnresolved},"switch off never saved")
        let saved=try store.policy()
        expect(!model.browserPagesSaved && !saved.browserPages && saved.browserPagesConsentVersion == nil && aiApp(),"switch off: \(saved.browserPages)")
        expect(saved.blockedDomains == ["example.com","github.com"],"switch off dropped the owner's sites")
        expect(model.chromePagesDiagnostics == "Off" && model.presentation.browserHistory == .off,"switch off: diagnostics \(model.chromePagesDiagnostics)")
        fake.reset()
        try await host(MemorySettings(model:model),size:NSSize(width:760,height:600))
        try await tick(0.3)
        expect(fake.count("status") == 0 && fake.count("ask") == 0 && fake.count("running") == 0,"Apps to remember read Chrome with the switch off")
        window.contentView=nil
        pass("switch off: saved, consent cleared, sites kept, AI apps stay connected; Apps to remember no longer reads Chrome")
    }
}
