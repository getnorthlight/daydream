import Foundation
import CSQLite
import MemoryCore
import PrivacyPolicy

/// Chrome page history, store side: the one proof a Chrome row can carry, the
/// write-time switch, read-time hiding and the display strings. Synthetic only:
/// no Apple Event, no Chrome, no capture tap.
func runChromePageStoreChecks(home:URL,now:Date) throws {
    let chrome=BrowserSafety.supportedBundle
    func page(_ id:String="page",title:String="Quarterly plan",url:String="https://docs.example.org",at:Date?=nil,checked:Date?=nil) -> Evidence {
        var proof=BrowserVerification(mode:"normal",windowID:"1520",tabID:"1733",focusedRole:"",checkedAt:isoPrecise(checked ?? at ?? now),provider:BrowserSafety.pageProvider)
        proof.policyRevision="policy-fixture"
        return Evidence(id:id,at:isoPrecise(at ?? now),kind:"window.changed",app:"Google Chrome",bundle:chrome,title:title,url:url,browserVerification:proof)
    }
    // A row written straight to disk, as an older build (or a bug) could have left it.
    func plant(_ store:MemoryStore,_ e:Evidence) throws {
        var db:OpaquePointer?
        guard sqlite3_open(store.home.appendingPathComponent("memory.sqlite").path,&db) == SQLITE_OK else { throw MemError.database("fixture open") }
        defer { sqlite3_close(db) }
        var stmt:OpaquePointer?
        guard sqlite3_prepare_v2(db,"INSERT OR REPLACE INTO records VALUES(?,?,?)",-1,&stmt,nil) == SQLITE_OK else { throw MemError.database("fixture statement") }
        defer { sqlite3_finalize(stmt) }
        let body=try json(e)
        for (i,value) in [e.id,body,fingerprint(body)].enumerated() {
            _ = value.withCString { sqlite3_bind_text(stmt,Int32(i+1),$0,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self)) }
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw MemError.database("fixture write") }
    }

    // §4.2 BrowserSafety.valid: the page branch.
    try check(BrowserSafety.pageProvider == "chrome-appleevents-page-v1","page history: the page provider name is fixed")
    try check(BrowserSafety.valid(page()),"page history: a verified page row is valid")
    try check(BrowserSafety.valid(page(title:"")),"page history: a page row with no title is valid")
    try check(BrowserSafety.valid(page(url:"http://localhost:8080")),"page history: a non-default port is part of the site")
    var e=page(); e.bundle="com.google.Chrome.beta"
    try check(!BrowserSafety.valid(e),"page history: refused: Chrome Beta bundle")
    for bundle in ["com.google.Chrome.canary","com.google.Chrome.dev","com.google.Chrome.app.Default-abcdefghijklmnopabcdefghijklmnop","com.apple.Safari","com.microsoft.edgemac",""] {
        e=page(); e.bundle=bundle
        try check(!BrowserSafety.valid(e),"page history: refused: another browser or app: "+bundle)
    }
    e=page(); e.browserVerification?.provider="chrome-appleevents-v1"
    try check(!BrowserSafety.valid(e),"page history: refused: the retired chrome-appleevents-v1 provider")
    e=page(); e.browserVerification=nil
    try check(!BrowserSafety.valid(e),"page history: refused: no proof")
    for mode in ["incognito","guest","","Normal"] {
        e=page(); e.browserVerification?.mode=mode
        try check(!BrowserSafety.valid(e),"page history: refused: window mode "+(mode.isEmpty ? "(empty)" : mode))
    }
    for id in ["","has space",String(repeating:"9",count:81),"tab\u{7f}"] {
        e=page(); e.browserVerification?.windowID=id
        try check(!BrowserSafety.valid(e),"page history: refused: invalid window id")
        e=page(); e.browserVerification?.tabID=id
        try check(!BrowserSafety.valid(e),"page history: refused: invalid tab id")
    }
    for role in ["AXLink","AXTextField","AXWebArea"] {
        e=page(); e.browserVerification?.focusedRole=role
        try check(!BrowserSafety.valid(e),"page history: refused: a focused element role ("+role+")")
    }
    for revision:String? in [nil,"",String(repeating:"r",count:257)] {
        e=page(); e.browserVerification?.policyRevision=revision
        try check(!BrowserSafety.valid(e),"page history: refused: missing or oversized policy revision")
    }
    for kind in ["app.activated","window.observed","mouse.click","mouse.clicked","keyboard.text_input","keyboard.submit","keyboard.shortcut","selection.changed","browser.observed","browser.tab_visited"] {
        e=page(); e.kind=kind
        try check(!BrowserSafety.valid(e),"page history: refused: kind "+kind)
    }
    try check(!BrowserSafety.valid(page(at:now,checked:now.addingTimeInterval(1.5))),"page history: refused: proof checked more than a second from the row")
    try check(BrowserSafety.valid(page(at:now,checked:now.addingTimeInterval(0.9))),"page history: a proof checked within a second is valid")
    e=page(); e.text="typed words"
    try check(!BrowserSafety.valid(e),"page history: refused: any page text")
    e=page(); e.secure=true
    try check(!BrowserSafety.valid(e),"page history: refused: secure input")
    e=page(); e.privateWindow=true
    try check(!BrowserSafety.valid(e),"page history: refused: private window flag")
    try check(!BrowserSafety.valid(page(title:String(repeating:"t",count:161))),"page history: refused: a title over 160 characters")
    try check(BrowserSafety.valid(page(title:String(repeating:"t",count:160))),"page history: a 160-character title is valid")
    // Origin only: scheme://host[:port], nothing else.
    for url in ["https://docs.example.org/document/d/x","https://docs.example.org/?q=plans","https://docs.example.org#section",
                "https://user:pass@docs.example.org","https://docs.example.org:443","http://docs.example.org:80",
                "https://Docs.Example.org","ftp://docs.example.org","chrome://newtab","file:///Users/x","about:blank","",
                "https://docs.example.org//","https://docs.example.org/?","https://docs.example.org/#","https://docs.example.org/x",
                "https://Docs.Example.org/","https://docs.example.org:443/"] {
        try check(!BrowserSafety.valid(page(url:url)),"page history: refused: not a bare origin: "+(url.isEmpty ? "(empty)" : url))
    }
    // fix/chrome-root (coordinator decision 10-02, row 8b): the origin plus exactly "/" was refused here until 0.1.4; it is
    // now accepted for PAGE rows only, so Search & AI page rows an earlier build stored as "https://chatgpt.com/" are
    // restored read-side (never by writing to the store), and shown as the bare origin. Website typing rows already
    // accepted origin + "/" (WebTypedRow.valid), so nothing changes for typed rows.
    try check(BrowserSafety.valid(page(url:"https://docs.example.org/")),"page history: the origin plus exactly \"/\" is accepted for a page row")
    try check(Privacy.sanitized(page(url:"https://docs.example.org/"),settings:PrivacySettings(),now:now)?.url == "https://docs.example.org",
              "page history: a page row stored with a trailing \"/\" is shown as the bare origin")
    // Defaults and site-only hosts.
    for url in ["https://secure.chase.com","https://www.plannedparenthood.org","https://accounts.google.com","https://tax.gob.mx","https://my.bank.example"] {
        try check(!BrowserSafety.valid(page(url:url)),"page history: refused: a default blocked site: "+url)
    }
    try check(!BrowserSafety.valid(page(title:"Inbox (3) - someone@example.org",url:"https://mail.google.com")),"page history: refused: a site-only host with a title")
    try check(BrowserSafety.valid(page(title:"",url:"https://mail.google.com")),"page history: a site-only host without a title is valid")
    try check(!BrowserSafety.valid(page(title:"x - Google Search",url:"https://www.google.com")),"page history: refused: a Google search host with a title")
    try check(BrowserSafety.valid(page(title:"Budget",url:"https://docs.google.com")),"page history: other Google hosts keep their title")
    try check(!BrowserSafety.fresh(page(checked:now),now:now.addingTimeInterval(2)),"page history: a stale proof is not fresh")
    try check(BrowserSafety.fresh(page(checked:now),now:now.addingTimeInterval(0.5)),"page history: a proof checked half a second ago is fresh")

    // §4.3 Intake: the switch is a write-time rule only.
    let store=try MemoryStore(home:home,writable:true), session=try CaptureSession(store:store)
    var policy=try store.policy()
    try check(!policy.browserPages && !policy.browserPagesOn,"page history: the switch is off by default")
    try session.start(permitted:true,now:now)
    // The full-typing build (every release stage) also says when website typing is saved; a narrow build says browsers' typing never is.
    try check(session.reason == CaptureSession.recordingReason && session.reason.contains("Chrome page titles and sites are saved only if you turn them on.")
              && (OwnerTyping.enabled ? session.reason.contains("What you type on websites in Google Chrome is saved only while typing and Web pages in Chrome are both on")
                                      : session.reason == "Recording apps. Chrome page titles and sites are saved only if you turn them on. What's on web pages and what you type in browsers is never saved."),
              "page history: the recording reason says Chrome pages are off unless turned on")
    try check(try !session.record(page("off"),focusedFieldKnown:true,permitted:true,now:now),"page history: switch off refuses a verified page at write")
    policy.browserPages=true
    try store.updatePolicy(policy,now:now)
    try check(try !store.policy().browserPagesOn && !session.record(page("unconsented"),focusedFieldKnown:true,permitted:true,now:now),"page history: the switch without consent version 1 refuses pages")
    // The consent version this build's Chrome card asks for (2 in the full-typing build: its text names website typing).
    let pagesConsent=PrivacySettings.browserPagesConsentCurrent
    try check(pagesConsent == (OwnerTyping.enabled ? 2 : 1),"page history: this build's Chrome pages consent version")
    if OwnerTyping.enabled {
        policy=try store.policy(); policy.browserPages=true; policy.browserPagesConsentVersion=1
        try store.updatePolicy(policy,now:now)
        try check(try !store.policy().browserPagesOn && !session.record(page("old-consent"),focusedFieldKnown:true,permitted:true,now:now),
                  "page history: full-typing build: a consent given to the older text (version 1, no website typing) refuses pages")
    }
    policy=try store.policy(); policy.browserPages=true; policy.browserPagesConsentVersion=pagesConsent
    try store.updatePolicy(policy,now:now)
    try check(try store.policy().browserPagesOn,"page history: switch and consent version 1 turn page history on")
    try check(try session.record(page("on"),focusedFieldKnown:true,permitted:true,now:now),"page history: switch on accepts a verified page")
    try check(try session.record(page("site-only",title:"",url:"https://www.google.com"),focusedFieldKnown:true,permitted:true,now:now),"page history: a search page is saved as site only")
    let searchRow=try store.read("site-only",now:now)
    try check(searchRow?.evidence.title == "" && searchRow?.evidence.url == "https://www.google.com" && searchRow?.actionState != "viewed_search","page history: a search page is site only: no title and no query stored")
    try check(try !session.record(page("query",title:"",url:"https://www.google.com/search?q=private+words"),focusedFieldKnown:true,permitted:true,now:now),"page history: a search address with its query is refused")
    let saved=try store.read("on",now:now)
    try check(saved?.evidence.url == "https://docs.example.org" && saved?.evidence.title == "Quarterly plan" && saved?.evidence.text == "","page history: the saved row holds the title and the site only")
    policy=try store.policy(); policy.browserPages=false; policy.browserPagesConsentVersion=nil
    try store.updatePolicy(policy,now:now)
    try check(try !session.record(page("after-off"),focusedFieldKnown:true,permitted:true,now:now),"page history: switch off again refuses new pages")
    try check(try store.read("on",now:now) != nil && store.action("on",now:now) != nil,"page history: pages saved while on stay readable after the switch is off")
    try check(try !store.ingest(page("direct-bad",url:"https://docs.example.org/private/path"),now:now),"page history: direct intake also refuses a full address")

    // Retired provider and later defaults: hidden at read time.
    var legacy=page("legacy-v1",url:"https://docs.example.org"); legacy.browserVerification?.provider="chrome-appleevents-v1"
    try check(try !store.ingest(legacy,now:now),"page history: the retired provider is refused at write")
    try plant(store,legacy)
    try check(try store.read("legacy-v1",now:now) == nil && store.action("legacy-v1",now:now) == nil,"page history: the retired provider is hidden at read")
    try plant(store,page("default-host",url:"https://www.plannedparenthood.org"))
    try check(try store.read("default-host",now:now) == nil,"page history: a default blocked host is hidden at read")
    try plant(store,page("titled-mail",title:"Inbox - someone@example.org",url:"https://mail.google.com"))
    try check(try store.read("titled-mail",now:now) == nil,"page history: a site-only host with a title is hidden at read")

    // §4.4 Display strings.
    let titled=IntentWriter.write(page(),now:now), bare=IntentWriter.write(page(title:"",url:"https://mail.google.com"),now:now)
    try check(titled.summary == "Viewed Quarterly plan (docs.example.org) in Google Chrome.","page history: summary names the title and the site")
    try check(bare.summary == "Viewed mail.google.com in Google Chrome.","page history: site-only summary names the site")
    let native=IntentWriter.write(Evidence(id:"n",at:iso(now),kind:"window.changed",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Notes"),now:now)
    try check(native.summary == "Viewed Notes in TextEdit.","page history: other rows keep their summary")
    try check(ActionProjection.make(page()).description == "Observed Quarterly plan on docs.example.org in Google Chrome; reading is not established.","page history: action says observed, not read")
    try check(ActionProjection.make(page(title:"",url:"https://mail.google.com")).description == "Observed mail.google.com in Google Chrome; reading is not established.","page history: site-only action names the site")
    try check(ActionProjection.make(page()).site == "docs.example.org","page history: the action site is the host")
    // B2 review changes Messages/search projection v4 only; browser-page canonical revisions stay byte-identical.
    try check(try ActionProjection.make(page()).revision == fingerprint("canonical-action-v3" + json(page())),"page history: the page action's revision is unchanged")

    // Exclude Google Chrome hides every page; a blocked site hides its pages everywhere.
    let live=try MemoryStore(home:home.appendingPathComponent("hide"),writable:true,automaticallySyncSearch:false)
    let t=Date()
    var livePolicy=try live.policy(); livePolicy.browserPages=true; livePolicy.browserPagesConsentVersion=PrivacySettings.browserPagesConsentCurrent
    try live.updatePolicy(livePolicy,now:t)
    try check(try live.ingest(page("hide-a",title:"Orchid roadmap",url:"https://plans.example.org",at:t),now:t),"page history: page A saved")
    try check(try live.ingest(page("hide-b",title:"Orchid budget",url:"https://sheets.example.net",at:t),now:t),"page history: page B saved")
    try live.setCaptureState("recording",reason:"synthetic fixture",now:t)
    let day=try DayScope.key(t,timezone:"UTC")
    func visible(_ id:String) throws -> [Bool] {
        let layers=try live.dayLayers(day:day,timezone:"UTC",now:t)
        return [try live.action(id,now:t) != nil,try live.read(id,now:t) != nil,
                layers.activities.contains { $0.actionIDs.contains(id) },
                try live.searchReport(MemorySearchQuery("Orchid")).hits.contains { $0["id"] == id },
                try live.context(now:t).sourceIDs.contains(id)]
    }
    try check(try visible("hide-a") == [true,true,true,true,true],"page history: a saved page reaches action, read, day, search and context")
    // fix/chrome-root (live matrix 10-02, row 8b): with search-box typing on, a Search & AI site's page row (site only)
    // must stay its exact origin through ingest's scrub, or the read-time shape check hides it everywhere. 0.1.4 wrote
    // "https://chatgpt.com/" and no chatgpt.com or claude.ai page was ever shown.
    try live.acceptSafeTyping(now:t)
    let typingOn=try live.typedTextPolicy()
    try check(typingOn.consented && typingOn.categories.searchAndAI,"page history: fixture: search-box typing is on")
    for (id,site) in [("ai-chatgpt","https://chatgpt.com"),("ai-claude","https://claude.ai"),("ai-gemini","https://gemini.google.com"),("ai-perplexity","https://www.perplexity.ai")] {
        try check(try live.ingest(page(id,title:"",url:site,at:t),now:t),"page history: a Search & AI site's page row is saved: "+site)
        try check(try live.read(id,now:t)?.evidence.url == site,"page history: a Search & AI site's page row keeps its exact origin: "+site)
        let shown=try visible(id)
        try check(shown[0] && shown[1] && shown[2],"page history: a Search & AI site's page row reaches action, read and day: "+site)
    }
    // fix/chrome-root (coordinator decision 10-02): a page row an earlier build stored as "https://chatgpt.com/" (planted
    // straight to disk, as 0.1.4 left it) is shown again in actions, day and search, as the bare origin.
    var legacyAI=page("ai-legacy-slash",title:"",url:"https://chatgpt.com",at:t); legacyAI.url="https://chatgpt.com/"
    try plant(live,legacyAI)
    let legacyShown=try visible("ai-legacy-slash")
    let legacyDay=try live.dayLayers(day:day,timezone:"UTC",now:t).activities.contains { $0.actionIDs.contains("ai-legacy-slash") }
    let legacySearch=try live.searchReport(MemorySearchQuery("chatgpt.com")).hits.contains { $0["id"] == "ai-legacy-slash" }
    try check(legacyShown[0] && legacyShown[1] && legacyDay && legacySearch,"page history: an earlier build's \"https://chatgpt.com/\" page row shows in actions, day and search")
    try check(try live.read("ai-legacy-slash",now:t)?.evidence.url == "https://chatgpt.com","page history: an earlier build's trailing-slash page row reads as the bare origin")
    // The scrub itself: an origin stays an origin; an address with a path or query keeps only the site and "/".
    var scrubRow=page("scrub",title:"",url:"https://chatgpt.com")
    try check(TypedHistoryScrub.apply(scrubRow,searchTypingOn:true).url == "https://chatgpt.com" && BrowserSafety.valid(TypedHistoryScrub.apply(scrubRow,searchTypingOn:true)),
              "page history: the Search & AI scrub leaves an origin-only page row valid")
    scrubRow.url="https://chatgpt.com/c/abc?model=x#frag"
    try check(TypedHistoryScrub.apply(scrubRow,searchTypingOn:true).url == "https://chatgpt.com/","page history: the Search & AI scrub still cuts a path, query and fragment to the site")
    scrubRow.url="https://chatgpt.com/"
    try check(TypedHistoryScrub.apply(scrubRow,searchTypingOn:true).url == "https://chatgpt.com/","page history: the Search & AI scrub keeps a typed row's site-with-slash as it was")
    livePolicy=try live.policy(); livePolicy.blockedDomains=["example.org"]
    try live.updatePolicy(livePolicy,now:t)
    try check(try visible("hide-a") == [false,false,false,false,false],"page history: a blocked site hides its past pages from action, read, day, search and context")
    try check(try visible("hide-b") == [true,true,true,true,true],"page history: other sites stay visible")
    livePolicy=try live.policy(); livePolicy.blockedDomains=[]; livePolicy.blockedApps=[chrome]
    try live.updatePolicy(livePolicy,now:t)
    try check(try visible("hide-a") == [false,false,false,false,false] && visible("hide-b") == [false,false,false,false,false],"page history: excluding Google Chrome hides every page")
    try live.setCaptureState("off",reason:"fixture done",now:t)

    // Old policy JSON decodes with the switch off.
    var legacyPolicy=PrivacySettings(); legacyPolicy.revision="r1"
    var body=try JSONSerialization.jsonObject(with:Data(json(legacyPolicy).utf8)) as! [String:Any]
    body.removeValue(forKey:"browserPages"); body.removeValue(forKey:"browserPagesConsentVersion")
    let decoded=try JSONDecoder().decode(PrivacySettings.self,from:JSONSerialization.data(withJSONObject:body))
    try check(!decoded.browserPages && decoded.browserPagesConsentVersion == nil && !decoded.browserPagesOn,"page history: an older policy decodes with the switch off")
    var roundtrip=PrivacySettings(); roundtrip.browserPages=true; roundtrip.browserPagesConsentVersion=PrivacySettings.browserPagesConsentCurrent
    try check(try decode(PrivacySettings.self,json(roundtrip)).browserPagesOn,"page history: the switch survives a save and load")
    try check(try !json(PrivacySettings()).contains("browserPagesConsentVersion") && json(PrivacySettings()).contains("\"browserPages\":false"),"page history: the switch is always written, the consent version only when set")
    try check(isoPrecise(now).contains(".") && timestamp(isoPrecise(now.addingTimeInterval(0.25))).map { abs($0.timeIntervalSince(now)-0.25) < 0.01 } == true,"page history: page times keep fractions of a second")
}
