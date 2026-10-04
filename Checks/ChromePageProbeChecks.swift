import Foundation
import MemoryCore

/// Chrome page history, capture side: the read order, the Incognito/Guest
/// rule, the re-check, title cleaning and the dwell/dedup tracker. A scripted
/// fake stands in for Chrome; nothing here sends an Apple Event.
private final class FakeChrome {
    var windows=["w1","w2"], tab="t1", title="Quarterly plan - Docs"
    var url="https://example.org/team/plans/report?id=4711&view=full#section-2"
    var modes:[String:String]=[:], noMode:Set<String>=[]
    /// (request, nth time it is asked) -> an override; `.some(nil)` means no reply.
    var change:((ChromePageRequest,Int)->ChromePageReply??)?
    private(set) var log:[ChromePageRequest]=[]
    private var seen:[String:Int]=[:]
    func ask(_ r:ChromePageRequest) -> ChromePageReply? {
        log.append(r)
        let n=(seen["\(r)"] ?? 0)+1; seen["\(r)"]=n
        if let c=change?(r,n) { return c }
        switch r {
        case .windowIDs: return .ids(windows)
        case .mode(let w): return noMode.contains(w) ? nil : .text(modes[w] ?? "normal")
        case .activeTabID(let w): return w == windows.first ? .text(tab) : nil
        case .tabURL(let w,let t): return w == windows.first && t == tab ? .text(url) : nil
        case .tabTitle(let w,let t): return w == windows.first && t == tab ? .text(title) : nil
        }
    }
    func read(_ blocked:[String]=[]) -> ChromePageResult { ChromePageProbe.read(userBlocked:blocked,ask) }
    var asksPage:Bool { log.contains { if case .tabURL = $0 { return true }; if case .tabTitle = $0 { return true }; return false } }
    var asksTitle:Bool { log.contains { if case .tabTitle = $0 { return true }; return false } }
    var asksTab:Bool { log.contains { if case .activeTabID = $0 { return true }; return false } }
}

func runChromePageProbeChecks() throws {
    // 1. Exact request order.
    var f=FakeChrome()
    let page=f.read()
    // fix/show-all: and its plain link (path only, never the query or fragment), kept on this Mac only for Open Original.
    try check(page == .page(ChromePageRead(windowID:"w1",tabID:"t1",origin:"https://example.org",title:"Quarterly plan - Docs",siteOnly:false,
                                           link:"https://example.org/team/plans/report")),
              "page history: a normal page gives title, origin and plain link only")
    try check(f.log == [.windowIDs,.mode("w1"),.mode("w2"),.activeTabID("w1"),.tabURL("w1","t1"),.tabTitle("w1","t1"),
                        .windowIDs,.mode("w1"),.mode("w2"),.activeTabID("w1"),.tabURL("w1","t1")],
              "page history: record read order is list, every mode, tab, address, title, then list, every mode, tab, address")
    let shown="\(page)"
    for part in ["4711","view=full","section-2","#","?"] {
        try check(!shown.contains(part),"page history: the query and fragment never leave the read: "+part)
    }
    f=FakeChrome(); f.url="https://www.google.com/search?q=private+medical+question"
    try check(f.read() == .skipped(.blocked) && !f.asksTitle,"page history: a search for a sensitive word is skipped, not saved as a site")
    f=FakeChrome(); f.url="https://www.google.com/search?q=weekend+weather"
    try check(f.read() == .page(ChromePageRead(windowID:"w1",tabID:"t1",origin:"https://www.google.com",title:"",siteOnly:true)),
              "page history: a search page is site only (no link)")
    try check(f.log == [.windowIDs,.mode("w1"),.mode("w2"),.activeTabID("w1"),.tabURL("w1","t1"),
                        .windowIDs,.mode("w1"),.mode("w2"),.activeTabID("w1"),.tabURL("w1","t1")],
              "page history: site-only read order never asks for the title")
    for url in ["https://mail.google.com/mail/u/0/#inbox/abc","https://example.org/?q=x","https://www.facebook.com/messages/t/123","https://chatgpt.com/c/abc","https://app.slack.com/client/T1/C2"] {
        f=FakeChrome(); f.url=url
        if case .page(let r)=f.read() { try check(r.siteOnly && r.title.isEmpty && !f.asksTitle,"page history: site only, no title asked: "+url) }
        else { try check(false,"page history: site-only page is read: "+url) }
    }
    // 2. Any Incognito or Guest window (Guest reports incognito) means nothing.
    for (index,name) in [(0,"front"),(1,"second"),(3,"last")] {
        for mode in ["incognito","guest",""] {
            f=FakeChrome(); f.windows=["w1","w2","w3","w4"]; f.modes[f.windows[index]]=mode
            try check(f.read() == .skipped(.notNormal) && !f.asksPage && !f.asksTab,
                      "page history: \(mode.isEmpty ? "unknown" : mode) window \(name): nothing saved, zero tab, URL or title requests")
        }
    }
    f=FakeChrome(); f.noMode=["w2"]
    try check(f.read() == .skipped(.unreadable) && !f.asksPage,"page history: a window whose mode does not answer: unreadable, no page read")
    // 3. Window list rules.
    f=FakeChrome(); f.windows=(1...65).map { "w\($0)" }
    try check(f.read() == .skipped(.tooManyWindows) && f.log == [.windowIDs],"page history: 65 windows: skipped with one request")
    f=FakeChrome(); f.windows=(1...64).map { "w\($0)" }
    if case .page=f.read() { try check(f.log.filter { if case .mode = $0 { return true }; return false }.count == 128,"page history: 64 windows: every mode read twice") }
    else { try check(false,"page history: 64 windows are read") }
    f=FakeChrome(); f.windows=[]
    try check(f.read() == .skipped(.noWindows) && f.log == [.windowIDs],"page history: no window: skipped")
    for (ids,name) in [(["w1","w1"],"duplicate IDs"),(["w1","a b"],"an invalid ID"),([""],"an empty ID")] {
        f=FakeChrome(); f.windows=ids
        try check(f.read() == .skipped(.unreadable) && f.log == [.windowIDs],"page history: window list with "+name+": unreadable")
    }
    f=FakeChrome(); f.change={ r,_ in r == .windowIDs ? .some(.text("w1")) : nil }
    try check(f.read() == .skipped(.unreadable),"page history: a window list that is not a list of IDs: unreadable")
    f=FakeChrome(); f.change={ _,_ in .some(nil) }
    try check(f.read() == .skipped(.unreadable) && f.log == [.windowIDs],"page history: no reply (timeout, denied): nothing more is asked")
    f=FakeChrome(); f.tab="bad tab"
    try check(f.read() == .skipped(.unreadable) && !f.asksPage,"page history: an invalid tab ID: unreadable, no address read")
    // 4. Address decisions; blocked and invalid never ask for the title.
    for (url,expected) in [("https://secure.chase.com/overview",ChromePageResult.skipped(.blocked)),("https://example.org/login",.skipped(.blocked)),
                           ("https://www.plannedparenthood.org/",.skipped(.blocked)),("https://tax.gob.mx",.skipped(.blocked)),
                           ("chrome://newtab",.skipped(.invalidAddress)),("file:///Users/x/a.pdf",.skipped(.invalidAddress)),
                           ("about:blank",.skipped(.invalidAddress)),("https://user:pw@example.org/",.skipped(.invalidAddress))] {
        f=FakeChrome(); f.url=url
        try check(f.read() == expected && !f.asksTitle,"page history: \(url) is skipped without asking for the title")
    }
    f=FakeChrome(); f.url="https://notes.example.org/today"
    try check(f.read(["example.org"]) == .skipped(.blocked) && !f.asksTitle,"page history: a site the owner added is skipped, subdomains too")
    f=FakeChrome(); f.title="InPrivate - notes"
    try check(f.read() == .skipped(.blocked),"page history: a title that looks private is skipped")
    // 5. Title and size limits.
    f=FakeChrome(); f.title="Loading..."
    try check(f.read() == .skipped(.unstableTitle),"page history: a half-loaded title is skipped as unstable")
    f=FakeChrome(); f.url="https://example.org/"+String(repeating:"a",count:ChromePageProbe.maxURLBytes-20)
    try check(f.url.utf8.count == ChromePageProbe.maxURLBytes && f.read() != .skipped(.unreadable),"page history: an 8192-byte address is read")
    f=FakeChrome(); f.url="https://example.org/"+String(repeating:"a",count:ChromePageProbe.maxURLBytes-19)
    try check(f.read() == .skipped(.unreadable) && !f.asksTitle,"page history: an oversized address: unreadable")
    f=FakeChrome(); f.title=String(repeating:"é",count:2049)
    try check(f.read() == .skipped(.unreadable),"page history: an oversized title (bytes): unreadable")
    // 6. Re-check: every difference discards the page.
    let changes:[(String,(ChromePageRequest,Int)->ChromePageReply??,ChromePageResult)]=[
        ("a window opened",{ r,n in r == .windowIDs && n == 2 ? .some(.ids(["w1","w2","w3"])) : nil },.skipped(.changed)),
        ("windows reordered",{ r,n in r == .windowIDs && n == 2 ? .some(.ids(["w2","w1"])) : nil },.skipped(.changed)),
        ("a window turned Incognito",{ r,n in r == .mode("w2") && n == 2 ? .some(.text("incognito")) : nil },.skipped(.notNormal)),
        ("the active tab changed",{ r,n in r == .activeTabID("w1") && n == 2 ? .some(.text("t2")) : nil },.skipped(.changed)),
        ("the page navigated",{ r,n in r == .tabURL("w1","t1") && n == 2 ? .some(.text("https://example.org/other")) : nil },.skipped(.changed)),
        ("only the fragment changed",{ r,n in r == .tabURL("w1","t1") && n == 2 ? .some(.text("https://example.org/team/plans/report?id=4711&view=full#section-3")) : nil },.skipped(.changed)),
        ("the list stopped answering",{ r,n in r == .windowIDs && n == 2 ? .some(nil) : nil },.skipped(.unreadable)),
        ("a mode stopped answering",{ r,n in r == .mode("w1") && n == 2 ? .some(nil) : nil },.skipped(.unreadable)),
        ("the address stopped answering",{ r,n in r == .tabURL("w1","t1") && n == 2 ? .some(nil) : nil },.skipped(.unreadable)),
    ]
    for (name,change,expected) in changes {
        f=FakeChrome(); f.change=change
        try check(f.read() == expected,"page history: re-check, \(name): nothing saved")
    }
    // Title cleaning table.
    let origin="https://example.org"
    for raw in ["","   ","example.org","https://example.org","https://example.org/page","http://x.test","HTTPS://EXAMPLE.ORG/A","New Tab","new tab","Untitled",
                "Loading…","Loading...","about:blank","(3)","• "] {
        try check(ChromePageTitle.clean(raw,origin:origin) == nil,"page history: title rejected: '\(raw)'")
    }
    for (raw,expected) in [("(3) Inbox - Mail","Inbox - Mail"),("(99+) Feed","Feed"),("• Chat room","Chat room"),("● Chat room","Chat room"),
                           ("(12345) Five digits","(12345) Five digits"),("  Plan \n  for\tQ3  ","Plan for Q3"),("(2) • Both","Both"),
                           ("Budget (3)","Budget (3)")] {
        try check(ChromePageTitle.clean(raw,origin:origin) == expected,"page history: title cleaned: '\(raw)'")
    }
    try check(ChromePageTitle.clean(String(repeating:"x",count:400),origin:origin)?.count == 160,"page history: titles are cut to 160 characters")
    // Review M1/P2: a page with no title of its own shows its address as the
    // title, without "http://". The path and query must never be saved that way.
    let addressTitles:[(String,String)]=[
        ("http://intranet.corp/reports/q3?employee=4411&team=hr","intranet.corp/reports/q3?employee=4411&team=hr"),
        ("http://192.168.1.20:8080/cases/2291","192.168.1.20:8080/cases/2291"),
        ("http://localhost:3000/api/users?id=5&team=acme","localhost:3000/api/users?id=5&team=acme"),
        ("http://intranet.example.com/hr/cases/4411?employee=jdoe","intranet.example.com/hr/cases/4411?employee=jdoe"),
        ("http://example.org:8080/a","example.org:8080/a"),
        ("http://localhost:3000/","localhost:3000"),
        ("http://localhost:3000/","localhost:3000/"),
        ("http://www.example.net/team?x=1","example.net/team?x=1"),
        ("http://www.example.net/team?x=1","www.example.net/team?x=1"),
        ("https://files.example.org/a/b#frag","files.example.org/a/b#frag"),
        ("https://files.example.org/a/b","https://files.example.org/a/b"),
        ("https://files.example.org/scans/Scan%202291.pdf","Scan 2291.pdf"),
        ("https://files.example.org/q?id=9","FILES.EXAMPLE.ORG/q?id=9"),
    ]
    for (url,raw) in addressTitles {
        let site=BrowserSites.origin(url)!
        try check(ChromePageTitle.clean(raw,origin:site,url:url) == nil,"page history: an address used as the title is refused: '\(raw)'")
        f=FakeChrome(); f.url=url; f.title=raw
        let result=f.read()
        try check(result == .skipped(.unstableTitle) && !"\(result)".contains("/"),"page history: the probe never saves an address-shaped title: '\(raw)'")
    }
    for (url,raw) in [("http://intranet.corp/reports","Quarterly reports"),("http://example.org/a","Example.org: home of examples"),
                      ("https://files.example.org/scans/a.pdf","Scan of the lease"),("http://localhost:3000/","Dev dashboard"),
                      ("https://example.org/about","example.org careers and jobs")] {
        let site=BrowserSites.origin(url)!
        try check(ChromePageTitle.clean(raw,origin:site,url:url) == raw,"page history: a real title on a plain site is kept: '\(raw)'")
    }
    // Dwell, dedup and flicker (ChromePageTracker).
    func read(_ title:String,tab:String="t1",site:String="https://example.org",siteOnly:Bool=false) -> ChromePageRead {
        ChromePageRead(windowID:"w1",tabID:tab,origin:site,title:siteOnly ? "" : title,siteOnly:siteOnly)
    }
    let t0=Date(timeIntervalSince1970:1_800_000_000)
    func at(_ s:Double) -> Date { t0.addingTimeInterval(s) }
    func waits(_ step:ChromePageStep,_ seconds:Double) -> Bool {
        if case .confirm(let after)=step { return abs(after-seconds) < 1e-6 }
        return false
    }
    var tracker=ChromePageTracker()
    let a=read("A"),b=read("B")
    try check(tracker.observe(a,at:at(0)) == .confirm(after:1.2),"page history: a new page is confirmed 1.2 s later, not saved")
    try check(waits(tracker.observe(a,at:at(0.5)),0.7),"page history: the same page too soon waits for the rest of the dwell")
    tracker=ChromePageTracker()
    _=tracker.observe(a,at:at(0))
    try check(waits(tracker.observe(a,at:at(0.95)),0.25),"page history: a short wait is the remaining dwell")
    tracker=ChromePageTracker(); _=tracker.observe(a,at:at(0))
    try check(waits(tracker.observe(a,at:at(0.999)),0.201),"page history: a read just short of the dwell waits about 0.2 s more")
    try check(tracker.observe(a,at:at(1.0)) == .record(a),"page history: two reads 1 s apart that agree save the page")
    try check(tracker.observe(a,at:at(4)) == .nothing && tracker.observe(a,at:at(9)) == .nothing,"page history: the same page is never saved twice in a row")
    try check(tracker.observe(b,at:at(10)) == .confirm(after:1.2),"page history: a title change is a new page")
    try check(tracker.observe(a,at:at(10.5)) == .nothing && !tracker.hasCandidate,"page history: flicker back to the saved page clears the candidate")
    try check(tracker.observe(b,at:at(11)) == .confirm(after:1.2),"page history: after a flicker the new page starts its dwell again")
    try check(tracker.observe(b,at:at(12.1)) == .record(b) && tracker.chain == 0,"page history: the new page is saved after its dwell")
    try check(tracker.observe(read("B",tab:"t2"),at:at(13)) == .confirm(after:1.2),"page history: the same title in another tab is another page")
    tracker=ChromePageTracker()
    for i in 1...5 { try check(tracker.observe(read("P\(i)"),at:at(Double(i))) == .confirm(after:1.2),"page history: chained confirm \(i) of 5") }
    try check(tracker.observe(read("P6"),at:at(6)) == .nothing,"page history: after five chained confirms no more are scheduled")
    try check(tracker.observe(read("P6"),at:at(9)) == .record(read("P6")),"page history: past the chain cap the poll still saves a page that stays")
    tracker=ChromePageTracker(); _=tracker.observe(a,at:at(0))
    try check(tracker.unstable(at:at(0.5)) == .confirm(after:1.2) && !tracker.hasCandidate,"page history: an unstable read clears the candidate and looks again")
    try check(tracker.observe(a,at:at(1.6)) == .confirm(after:1.2),"page history: after an unstable read the dwell starts again")
    tracker=ChromePageTracker()
    for i in 1...5 { try check(tracker.unstable(at:at(Double(i))) == .confirm(after:1.2),"page history: unstable confirm \(i) of 5") }
    try check(tracker.unstable(at:at(6)) == .nothing,"page history: unstable reads stop confirming after five")
    tracker=ChromePageTracker(); _=tracker.observe(a,at:at(0)); _=tracker.observe(a,at:at(1.2))
    try check(tracker.lastRecorded == ChromePageKey(a),"page history: the saved page is remembered")
    _=tracker.unstable(at:at(2))
    try check(tracker.lastRecorded == ChromePageKey(a) && tracker.observe(a,at:at(3)) == .nothing,"page history: an unstable read keeps the saved page (no duplicate)")
    tracker.skipped()
    try check(tracker.lastRecorded == nil && tracker.observe(a,at:at(4)) == .confirm(after:1.2),"page history: after an Incognito window or blocked page the same page is saved again")
    try check(tracker.observe(a,at:at(5)) == .record(a),"page history: the page is saved again after a skip")
    tracker.reset()
    try check(tracker.lastRecorded == nil && tracker.chain == 0 && !tracker.hasCandidate,"page history: reset forgets everything")
    // Review M3: a row the write gate refused is not counted as saved.
    tracker=ChromePageTracker(); _=tracker.observe(a,at:at(0))
    try check(tracker.observe(a,at:at(1.2)) == .record(a),"page history: refused-write fixture records")
    try check(tracker.notSaved(a,at:at(2.5)) == .confirm(after:1.2) && tracker.lastRecorded == nil,"page history: a refused write is not remembered as saved and looks again")
    try check(tracker.observe(a,at:at(3.7)) == .record(a),"page history: the next read that agrees saves the page after a refused write")
    try check(tracker.notSaved(b,at:at(4)) == .nothing && tracker.lastRecorded == ChromePageKey(a),"page history: a refusal for another page changes nothing")
    tracker=ChromePageTracker(); _=tracker.observe(a,at:at(0)); _=tracker.observe(a,at:at(1.2))
    _=tracker.observe(b,at:at(5)); _=tracker.observe(b,at:at(6.2))
    _=tracker.notSaved(b,at:at(6.3))
    try check(tracker.lastRecorded == ChromePageKey(a),"page history: after a refused write the page saved before it is the last page again")
    tracker=ChromePageTracker(); _=tracker.observe(a,at:at(0))
    var confirms=0,clock=1.2
    for _ in 0..<6 {
        guard tracker.observe(a,at:at(clock)) == .record(a) else { break }
        if case .confirm = tracker.notSaved(a,at:at(clock+0.1)) { confirms += 1 }
        clock += 1.3
    }
    try check(confirms == ChromePageTracker.maxRefused,"page history: a write refused again and again schedules at most 3 extra reads (then only the poll retries)")
    // Review m2: a title flipping between the same two titles is saved once per title.
    tracker=ChromePageTracker()
    var flips=0,time=0.0
    for i in 0..<16 {
        let page=i % 2 == 0 ? read("▶ Song"): read("Song")
        for _ in 0..<2 { if case .record = tracker.observe(page,at:at(time)) { flips += 1 }; time += 1.2 }
        time += 0.3
    }
    try check(flips == 2,"page history: a title flipping every 1.5 s gives 2 rows, not one per flip (got \(flips))")
    try check(tracker.observe(read("Other song"),at:at(time)) == .confirm(after:1.2),"page history: a new title after the flicker is a new page")
    tracker=ChromePageTracker(); _=tracker.observe(a,at:at(0)); _=tracker.observe(a,at:at(1.2))
    _=tracker.observe(b,at:at(2)); _=tracker.observe(b,at:at(3.2))
    try check(tracker.observe(a,at:at(30)) == .confirm(after:1.2),"page history: going back to a page after the flicker window saves it again")
    tracker=ChromePageTracker(); _=tracker.observe(a,at:at(0)); _=tracker.observe(a,at:at(1.2))
    _=tracker.observe(read("B",tab:"t2"),at:at(2)); _=tracker.observe(read("B",tab:"t2"),at:at(3.2))
    try check(tracker.observe(a,at:at(4)) == .confirm(after:1.2),"page history: switching back to another tab is never flicker")
    try check(ChromePageKey(read("Inbox",site:"https://mail.google.com",siteOnly:true)) == ChromePageKey(read("Other",site:"https://mail.google.com",siteOnly:true)),
              "page history: a site-only key ignores the title")
    try check(ChromePageKey(a).value == "w1|t1|https://example.org|A","page history: the key is window, tab, origin and title")
    // Target and reply decoding.
    try check(ChromePageTarget.bundleID == "com.google.Chrome" && ChromePageTarget.teamID == "EQHXZ8M8AV","page history: only Google Chrome stable signed by Google")
    try check(ChromePageTarget.requirement == "identifier \"com.google.Chrome\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"EQHXZ8M8AV\"",
              "page history: the signature requirement is the reviewed Chrome requirement")
    let list=NSAppleEventDescriptor.list()
    for (i,id) in ["11","12"].enumerated() { list.insert(NSAppleEventDescriptor(string:id),at:i+1) }
    try check(ChromePageRequest.windowIDs.decode(list) == .ids(["11","12"]),"page history: a list of window IDs decodes")
    let big=NSAppleEventDescriptor.list()
    for i in 1...65 { big.insert(NSAppleEventDescriptor(string:"\(i)"),at:i) }
    try check(ChromePageRequest.windowIDs.decode(big) == nil,"page history: more than 64 window IDs do not decode")
    try check(ChromePageRequest.mode("1").decode(NSAppleEventDescriptor(string:"normal")) == .text("normal"),"page history: text replies decode")
    for request in [ChromePageRequest.mode("1"),.activeTabID("1"),.tabURL("1","2"),.tabTitle("1","2")] {
        try check(request.decode(NSAppleEventDescriptor(int32:1)) == nil && request.decode(list) == nil,"page history: a non-text reply does not decode: \(request)")
    }
}

/// Live test (build 7): a headless or automation Chrome (`--headless=new`, Puppeteer, Playwright)
/// runs as a second `com.google.Chrome` process with no launch date and no window. It is never the one checked and
/// never counted, so the person's Chrome is read; two of the person's own Chromes still refuse (strict mode).
func runChromeProcessChecks() throws {
    // The live facts: the person's Chrome (regular, windows, launch date) and a headless one (regular policy, no window).
    let headless=ChromeProcess(pid:35563,regular:true,windows:false,frontmost:false,started:nil)
    var mine=ChromeProcess(pid:65479,regular:true,windows:true,frontmost:false,started:1_790_555_952.78)
    try check(ChromeProcesses.background(headless) && !ChromeProcesses.background(mine),"a headless Chrome (no window) is a background process; the person's is not")
    for order in [[headless,mine],[mine,headless]] {
        try check(ChromeProcesses.chosen(order)?.pid == 65479,"the person's Chrome is chosen, never the headless one, in either order")
        try check(ChromeProcesses.user(order).map(\.pid) == [65479],"only the person's Chrome is counted next to a headless one")
    }
    mine.frontmost=true
    try check(ChromeProcesses.chosen([headless,mine])?.pid == 65479 && ChromeProcesses.user([headless,mine]).count == 1,"the frontmost Chrome is chosen and counted once")
    // Not a regular app (an accessory or background-only helper with the bundle ID): not counted unless in front.
    let accessory=ChromeProcess(pid:40000,regular:false,windows:true,frontmost:false,started:5)
    try check(ChromeProcesses.user([accessory,mine]).map(\.pid) == [65479],"an accessory Chrome process is not counted")
    // The frontmost process is always the one checked, whatever it looks like: its own signature and launch identity
    // decide (nothing is loosened for it).
    let oddFront=ChromeProcess(pid:41000,regular:true,windows:false,frontmost:true,started:nil)
    try check(ChromeProcesses.chosen([oddFront,ChromeProcess(pid:42000,regular:true,windows:true,frontmost:false,started:9)])?.pid == 41000,
              "the frontmost Chrome is the one checked even with no window read")
    // Two of the person's own Chromes (a second profile folder with windows): both count, so strict mode refuses.
    let second=ChromeProcess(pid:50000,regular:true,windows:true,frontmost:false,started:1_790_600_000)
    try check(ChromeProcesses.user([headless,mine,second]).count == 2,"two of the person's Chromes both count (strict mode refuses)")
    mine.frontmost=false
    try check(ChromeProcesses.chosen([mine,second,headless])?.pid == 50000,"with none in front, the newest of the person's Chromes is checked")
    try check(ChromeProcesses.chosen([headless]) == nil && ChromeProcesses.user([headless]).isEmpty,"only a headless Chrome running: no Chrome to check")
    try check(ChromeProcesses.chosen([]) == nil,"no Chrome running: none chosen")
    // Launch identity: the kernel start time stands in for a missing launch date, so a PID is never trusted alone.
    let me=ProcessInfo.processInfo.processIdentifier
    let kernel=ProcessStart.kernelSeconds(pid:me)
    try check(kernel.map { $0 > 1_600_000_000 && $0 <= Date().timeIntervalSince1970+1 } ?? false,"this process's kernel start time reads")
    try check(ProcessStart.seconds(launchDate:nil,pid:me) == kernel,"a missing launch date falls back to the kernel start time")
    try check(ProcessStart.seconds(launchDate:Date(timeIntervalSince1970:1234),pid:me) == 1234,"a launch date, when macOS has one, is used as before")
    try check(ProcessStart.kernelSeconds(pid:0) == nil && ProcessStart.kernelSeconds(pid:-1) == nil,"no start time for an invalid PID")
}
