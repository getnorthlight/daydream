import Foundation
import MemoryCore

func runBrowserChecks(home:URL,now:Date) throws {
    // Chrome page history read (ChromePageProbe) with a scripted fake of the
    // Apple Event layer. Same guarantees as the retired metadata probe.
    var calls:[ChromePageRequest]=[]
    func probe(mode:String?="normal",changedWindow:Bool=false,changedTab:Bool=false,changedURL:Bool=false,fail:Bool=false) -> ChromePageResult {
        calls=[]; var listReads=0,tabReads=0,urlReads=0
        return ChromePageProbe.read(userBlocked:[]) { request in
            calls.append(request)
            if fail { return nil }
            switch request {
            case .windowIDs: listReads += 1; return .ids(changedWindow && listReads > 1 ? ["private-window","normal-window"] : ["normal-window"])
            case .mode("normal-window"): return mode.map { .text($0) }
            case .activeTabID("normal-window"): tabReads += 1; return .text(changedTab && tabReads > 1 ? "other-tab" : "tab-a")
            case .tabTitle("normal-window","tab-a"): return .text("Fabricated research question")
            case .tabURL("normal-window","tab-a"): urlReads += 1; return .text(changedURL && urlReads > 1 ? "https://example.org/other" : "https://example.org/research/notes")
            default: return nil
            }
        }
    }
    func asksPage() -> Bool { calls.contains { if case .tabURL = $0 { return true }; if case .tabTitle = $0 { return true }; return false } }
    // fix/show-all: plus the page's plain link (no query or fragment), kept on this Mac only for Open Original.
    try check(probe() == .page(ChromePageRead(windowID:"normal-window",tabID:"tab-a",origin:"https://example.org",title:"Fabricated research question",siteOnly:false,
                                              link:"https://example.org/research/notes")),
              "page history: Chrome read accepts a normal window with a stable tab, origin and plain link only")
    for mode:String? in ["incognito","private","","Normal",nil] {
        try check(probe(mode:mode) == (mode == nil ? .skipped(.unreadable) : .skipped(.notNormal)),"page history: private or unknown Chrome mode saves nothing")
        try check(!asksPage(),"page history: private or unknown mode never asks for title or URL")
    }
    try check(probe(changedWindow:true) == .skipped(.changed),"page history: a window opening during the read discards it")
    try check(probe(changedTab:true) == .skipped(.changed),"page history: active tab change discards the read")
    try check(probe(changedURL:true) == .skipped(.changed),"page history: navigation during the read discards it")
    try check(probe(fail:true) == .skipped(.unreadable) && calls == [.windowIDs],"page history: permission or timeout failure gives nothing and asks nothing more")
    // Intake of Chrome page history rows (chrome-appleevents-page-v1): the only
    // Chrome rows that can be saved. Every other "never" still holds.
    let store=try MemoryStore(home:home,writable:true), session=try CaptureSession(store:MemoryStore(home:home,writable:true))
    func event(_ id:String="browser",title:String="Fabricated research",url:String="https://example.org") -> Evidence {
        var proof=BrowserVerification(mode:"normal",windowID:"w",tabID:"t",focusedRole:"",checkedAt:isoPrecise(now),provider:BrowserSafety.pageProvider)
        proof.policyRevision="policy-fixture"
        return Evidence(id:id,at:isoPrecise(now),kind:"window.changed",app:"Google Chrome",bundle:BrowserSafety.supportedBundle,
            title:title,url:url,browserVerification:proof)
    }
    func record(_ e:Evidence,permitted:Bool=true,date:Date?=nil) throws -> Bool {
        try session.record(e,focusedFieldKnown:true,permitted:permitted,now:date ?? now)
    }
    func pages(_ on:Bool) throws {
        var policy=try store.policy(); policy.browserPages=on; policy.browserPagesConsentVersion=on ? PrivacySettings.browserPagesConsentCurrent : nil
        try store.updatePolicy(policy,now:now)
    }
    try check(try !record(event()),"page history: a page cannot record while capture OFF")
    try session.start(permitted:true,now:now)
    try check(try !record(event()),"page history: a verified page is refused while the switch is off")
    try pages(true)
    try check(try record(event()),"page history: a verified page persists through real intake with the switch on")
    try check(try !record(event()),"page history: the same page row is idempotent")
    var e=event("bad"); e.browserVerification=nil
    try check(try !record(e),"page history: absence of private title is not a normal-window proof")
    try check(try !store.ingest(e,now:now),"page history: direct durable intake also rejects unverified real browser records")
    e=event("bad"); e.browserVerification?.mode="incognito"
    try check(try !record(e),"page history: private proof never persists")
    e=event("bad"); e.privateWindow=true
    try check(try !record(e),"page history: private flag overrides a claimed normal proof")
    for role in ["AXSecureTextField","AXTextField","AXTextArea","AXWebArea","AXGroup","AXLink"] {
        e=event("bad"); e.browserVerification?.focusedRole=role
        try check(try !record(e),"page history: a focused element role is refused: " + role)
    }
    e=event("bad"); e.secure=true
    try check(try !record(e),"page history: global secure-input state overrides normal mode")
    e=event("bad"); e.text="fabricated browser typing"
    try check(try !record(e),"page history: browser text refused even with normal proof")
    for kind in ["keyboard.text_input","keyboard.submit","keyboard.shortcut","selection.changed","mouse.click","mouse.clicked","app.activated"] {
        e=event("bad"); e.kind=kind
        try check(try !record(e),"page history: page support cannot become a text/submit/click recorder: " + kind)
    }
    for bundle in ["com.apple.Safari","com.google.Chrome.beta","com.google.Chrome.canary","com.microsoft.edgemac"] {
        e=event("bad"); e.bundle=bundle
        try check(try !record(e),"page history: Chrome proof cannot authorize another browser: " + bundle)
    }
    e=event("bad"); e.browserVerification?.provider="title-heuristic"
    try check(try !record(e),"page history: title-based proof provider refused")
    e=event("retired"); e.browserVerification?.provider="chrome-appleevents-v1"; e.browserVerification?.focusedRole="AXLink"
    try check(try !record(e) && !store.ingest(e,now:now),"page history: the retired chrome-appleevents-v1 provider is refused at write")
    e=event("bad",url:"https://example.org/?q=fabricated+research")
    try check(try !record(e),"page history: a full address with a query is refused")
    try check(try record(event("search",title:"",url:"https://www.google.com")),"page history: a search page is saved as the site alone")
    try check(try !record(event("search-titled",title:"fabricated research - Google Search",url:"https://www.google.com")),"page history: a search page with a title is refused")
    try check(try !record(event("old"),date:now.addingTimeInterval(2)),"page history: stale mode proof cannot be reused")
    var burst=CaptureBurst()
    burst.append("fabricated native draft",context:"native-field",safe:true)
    try check(burst.drain(context:"chrome-normal",safe:false) == nil,"transition into browser discards native buffered text")
    burst.append("not collected",context:"chrome-normal",safe:false)
    try check(burst.drain(context:"chrome-private",safe:false) == nil,"normal/private browser transitions cannot release text")
    try session.pause("sleep",now:now)
    try check(try !record(event("sleep")),"page history: sleep/pause blocks page rows")
    try session.health(permitted:true,now:now)
    try check(try !record(event("wake")),"page history: wake does not resume page recording")
    try session.start(permitted:true,now:now)
    try check(try !record(event("revoked"),permitted:false),"page history: permission loss blocks pages before persistence")
    try session.health(permitted:true,now:now)
    try check(try !record(event("restored")),"page history: permission restoration still requires explicit resume")
    let restarted=try CaptureSession(store:store)
    try check(restarted.state == "off","page history: restart does not enable recording")
    try check(try store.writePending(now:now) == 2,"page history: withheld observations never enter writer queue")
    let item=try store.read("browser",now:now)
    try check(item?.evidence.browserVerification?.mode == "normal" && item?.evidence.text == "","page history: summary retains per-app source proof without page text")
    try check(item?.summary == "Viewed Fabricated research (example.org) in Google Chrome." && item?.actionState == "observed","page history: the summary says viewed, not completed")
    let search=try store.read("search",now:now)
    try check(search?.evidence.title == "" && search?.evidence.url == "https://www.google.com" && search?.actionState != "viewed_search","page history: a search page is site only: no title and no query stored")
    try check(Privacy.searchValue("C%2B%2B+reference") == "C++ reference","search query preserves encoded plus while decoding form spaces")
    try session.start(permitted:true,now:now)
    // Chrome app time (chrome-app-time-v1, live test build 7): the app's name and the time while the page can't
    // be read. Only while "Web pages in Chrome" is on; never a title, an address, a window, a tab or another kind.
    func appTime(_ id:String) -> Evidence {
        var proof=BrowserVerification(mode:"",windowID:"",tabID:"",focusedRole:"",checkedAt:isoPrecise(now),provider:BrowserSafety.appTimeProvider)
        proof.policyRevision="policy-fixture"
        return Evidence(id:id,at:isoPrecise(now),kind:"app.activated",app:"Google Chrome",bundle:BrowserSafety.supportedBundle,title:"",url:"",browserVerification:proof)
    }
    try check(BrowserSafety.appTimeProvider == "chrome-app-time-v1","Chrome app time: the provider name is fixed")
    try pages(false)
    try check(try !record(appTime("app-off")),"Chrome app time: refused while Web pages in Chrome is off")
    try pages(true)
    try check(try record(appTime("app-on")),"Chrome app time: saved while Web pages in Chrome is on")
    try check(try store.read("app-on",now:now)?.evidence.title == "","Chrome app time: saved with no title")
    var bad=appTime("bad-title"); bad.title="Inbox (3)"
    try check(try !record(bad),"Chrome app time: a title is refused")
    bad=appTime("bad-url"); bad.url="https://example.org"
    try check(try !record(bad),"Chrome app time: an address is refused")
    bad=appTime("bad-window"); bad.browserVerification?.windowID="1520"; bad.browserVerification?.tabID="1733"
    try check(try !record(bad),"Chrome app time: a window or tab is refused")
    bad=appTime("bad-mode"); bad.browserVerification?.mode="normal"
    try check(try !record(bad),"Chrome app time: a claimed mode is refused")
    bad=appTime("bad-text"); bad.text="typed"
    try check(try !record(bad),"Chrome app time: text is refused")
    bad=appTime("bad-private"); bad.privateWindow=true
    try check(try !record(bad),"Chrome app time: a private window is refused")
    for kind in ["window.changed","mouse.clicked","keyboard.text_input","keyboard.submit"] {
        bad=appTime("bad-"+kind); bad.kind=kind
        try check(try !record(bad),"Chrome app time: only an app activation: " + kind)
    }
    for bundle in ["com.apple.Safari","com.google.Chrome.beta","company.thebrowser.Browser"] {
        bad=appTime("bad-"+bundle); bad.bundle=bundle
        try check(try !record(bad),"Chrome app time: another browser is refused: " + bundle)
    }
    bad=appTime("bad-revision"); bad.browserVerification?.policyRevision=nil
    try check(try !record(bad),"Chrome app time: a row without the policy revision is refused")
    try check(try !record(appTime("app-stale"),date:now.addingTimeInterval(2)),"Chrome app time: a stale proof is refused")
    try check(try store.context(now:now).sourceIDs.contains("browser"),"page history: a fresh page reaches context")
    try store.delete("browser")
    try check(try store.read("browser",now:now) == nil && !store.context(now:now).sourceIDs.contains("browser"),"page history: deletion removes original, summary and next context")
    try check(try !record(event()),"page history: a deleted page cannot return through retry")
    var policy=try store.policy(); policy.blockedDomains=["example.org"]
    try store.updatePolicy(policy,now:now)
    try check(try !record(event("excluded")),"page history: domain exclusions apply before persistence")
    try pages(false)
    try check(try !record(event("switched-off",url:"https://example.net")),"page history: switch off refuses new pages")
    try check(try store.read("search",now:now) != nil,"page history: pages saved earlier stay readable with the switch off")
}
