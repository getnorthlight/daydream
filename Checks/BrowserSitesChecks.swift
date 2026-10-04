import Foundation
import MemoryCore

/// Chrome page history site rules: the default list, the address decision and
/// the owner's site entries. Pure; nothing is read from a browser.
func runBrowserSitesChecks() throws {
    let defaults=BrowserSiteList.pageDefaults
    try check(defaults.count == 220,"page history: the default list has 220 sites")
    for d in defaults + BrowserSiteList.pinned {
        try check(BrowserSites.normalizedDomain(d) == d,"page history: default site is normalized: "+d)
    }
    try check(Set(defaults).count == defaults.count,"page history: the default list has no duplicates")
    try check(BrowserSiteList.categories.flatMap(\.domains) == defaults,"page history: every default site has exactly one category")
    try check(BrowserSiteList.categories.map(\.title) == ["Password managers","Sign-in pages","Banks and investing","Payments and crypto","Credit reports","Health","Sexual and reproductive health","Government and taxes"],"page history: category titles and order")
    try check(BrowserSiteList.categories.map(\.domains.count) == [18,16,59,25,5,26,22,49],"page history: category sizes")
    try check(BrowserSiteList.pinned == PrivacySettings.sensitiveDomains && BrowserSiteList.pinned.count == 11,"page history: pinned sites are the 11 app-wide sensitive sites")
    // No web consoles, IDEs or terminals in page defaults (typing-only extras).
    for d in ["shell.cloud.google.com","ssh.cloud.google.com","console.cloud.google.com","console.aws.amazon.com","shell.azure.com","portal.azure.com",
              "github.dev","vscode.dev","gitpod.io","replit.com","repl.co","codesandbox.io","csb.app","stackblitz.com","glitch.com","c9.io",
              "webcontainer.io","colab.research.google.com"] {
        try check(!defaults.contains(where:{ BrowserSites.matches(host:d,domain:$0) }),"page history: web console not in the default list: "+d)
    }
    for token in ["terminal","shell","ssh","console","cloudshell"] {
        try check(!BrowserSites.pathTokens.contains(token),"page history: console word is not a page path token: "+token)
    }
    for d in BrowserSiteList.reproductiveHealth {
        try check(BrowserSites.pageDecision("https://www."+d+"/",userBlocked:[]) == .blocked && BrowserSites.blockedByDefault(host:d),"page history: reproductive health site blocked: "+d)
    }
    try check(BrowserSiteList.reproductiveHealth.count == 22,"page history: 22 reproductive health sites")

    // pageDecision tables.
    let record=["https://docs.google.com/document/d/x":"https://docs.google.com","https://example.org/":"https://example.org",
                "https://example.org/articles/orchids?page=2":"https://example.org","https://EXAMPLE.org:443/a#b":"https://example.org",
                "http://localhost:8080/app":"http://localhost:8080","https://github.com/owner/repo/pull/12":"https://github.com",
                "https://en.wikipedia.org/wiki/Orchid":"https://en.wikipedia.org","https://news.ycombinator.com/item?id=1":"https://news.ycombinator.com",
                "https://www.youtube.com/watch?v=abc":"https://www.youtube.com","https://maps.google.com/":"https://maps.google.com",
                "https://calendar.google.com/calendar/r":"https://calendar.google.com","https://www.nytimes.com/section/science":"https://www.nytimes.com",
                "https://notchase.com/":"https://notchase.com","https://example.org/#inbox":"https://example.org"]
    for (url,origin) in record.sorted(by:{ $0.key < $1.key }) {
        try check(BrowserSites.pageDecision(url,userBlocked:[]) == .record(origin:origin),"page history: record: "+url)
    }
    let siteOnly=["https://www.google.com/search?q=x":"https://www.google.com","https://mail.google.com/":"https://mail.google.com",
                  "https://example.org/?q=x":"https://example.org","https://www.google.co.uk/":"https://www.google.co.uk",
                  "https://google.de/search?q=y":"https://google.de","https://www.bing.com/search?q=x":"https://www.bing.com",
                  "https://duckduckgo.com/?q=x":"https://duckduckgo.com","https://outlook.office.com/mail/":"https://outlook.office.com",
                  "https://app.slack.com/client/T1":"https://app.slack.com","https://chatgpt.com/c/abc":"https://chatgpt.com",
                  "https://claude.ai/chat/abc":"https://claude.ai","https://web.whatsapp.com/":"https://web.whatsapp.com",
                  "https://www.facebook.com/messages/t/1":"https://www.facebook.com","https://www.instagram.com/direct/inbox/":"https://www.instagram.com",
                  "https://x.com/messages":"https://x.com","https://x.com/i/chat/1":"https://x.com","https://www.linkedin.com/messaging/":"https://www.linkedin.com",
                  "https://www.reddit.com/message/inbox":"https://www.reddit.com","https://shop.example.org/list?Search=lamps":"https://shop.example.org",
                  "https://www.amazon.com/s?k=lamp":"https://www.amazon.com","https://discord.com/channels/1/2":"https://discord.com",
                  "https://www.icloud.com/mail":"https://www.icloud.com"]
    for (url,origin) in siteOnly.sorted(by:{ $0.key < $1.key }) {
        try check(BrowserSites.pageDecision(url,userBlocked:[]) == .siteOnly(origin:origin),"page history: site only: "+url)
    }
    // Review P3: common sites the first list missed (search words, email subjects, chat names).
    let reviewSiteOnly=["https://www.ebay.com/sch/i.html?_nkw=lamp":"https://www.ebay.com","https://www.amazon.de/s?field-keywords=lamp":"https://www.amazon.de",
                        "https://web.de/":"https://web.de","https://navigator-bs.gmx.de/mail":"https://navigator-bs.gmx.de","https://e.mail.ru/inbox/":"https://e.mail.ru",
                        "https://mail.yandex.ru/":"https://mail.yandex.ru","https://mail.qq.com/":"https://mail.qq.com","https://app.tuta.com/mail":"https://app.tuta.com",
                        "https://mail.superhuman.com/":"https://mail.superhuman.com","https://aistudio.google.com/prompts/1":"https://aistudio.google.com",
                        "https://chat.reddit.com/room/1":"https://chat.reddit.com","https://huggingface.co/chat/conversation/1":"https://huggingface.co",
                        "https://chat.qwen.ai/c/1":"https://chat.qwen.ai"]
    for (url,origin) in reviewSiteOnly.sorted(by:{ $0.key < $1.key }) {
        try check(BrowserSites.pageDecision(url,userBlocked:[]) == .siteOnly(origin:origin),"page history: site only (review list): "+url)
    }
    if case .record = BrowserSites.pageDecision("https://huggingface.co/models",userBlocked:[]) { try check(true,"page history: huggingface.co outside /chat keeps its title") }
    else { try check(false,"page history: huggingface.co outside /chat keeps its title") }
    for url in ["https://www.facebook.com/messagesfoo","https://x.com/imessages","https://example.org/?q=","https://www.reddit.com/r/orchids"] {
        if case .record = BrowserSites.pageDecision(url,userBlocked:[]) { try check(true,"page history: not a message or search page: "+url) }
        else { try check(false,"page history: not a message or search page: "+url) }
    }
    let blocked=["https://secure.chase.com/overview","https://example.org/login","https://tax.gob.mx","https://www.plannedparenthood.org/",
                 "https://accounts.google.com/signin","https://turbotax.intuit.com/","https://www.irs.gov/","https://portal.gov.xx/",
                 "https://my.bank.example/","https://shop.example.org/checkout/cart","https://example.org/account/login?next=/",
                 "https://example.org/#/login","https://example.org/#!/checkout","https://example.org/?next=%2Fsign%2Din",
                 "https://example.org/a?x=two+factor","https://clinic.example.org/abortion/services","https://example.org/birth-control",
                 "https://1password.com/","https://paypal.com/","https://www.mychart.org/"]
    for url in blocked {
        try check(BrowserSites.pageDecision(url,userBlocked:[]) == .blocked,"page history: blocked: "+url)
    }
    try check(BrowserSites.pageDecision("https://docs.example.org/",userBlocked:["example.org"]) == .blocked,"page history: blocked: a site on the owner's list covers its subdomains")
    try check(BrowserSites.pageDecision("https://docs.example.org/",userBlocked:["https://www.example.org/x"]) != .blocked,"page history: the owner's entries match as stored (www. is removed when the entry is added)")
    try check(BrowserSites.pageDecision("https://docs.example.org/",userBlocked:["docs.example.org"]) == .blocked,"page history: blocked: an owner entry for one subdomain")
    try check(BrowserSites.pageDecision("https://example.org/",userBlocked:["docs.example.org"]) != .blocked,"page history: an owner subdomain entry does not block the parent site")
    for url in ["chrome://newtab","file:///Users/x/a.html","about:blank","data:text/html,hi","http://[::1]:8080/","https://user:pw@example.org/",
                "https://user@example.org/","ftp://example.org/","not a url","","javascript:alert(1)","https://exa mple.org/",
                "https://"+String(repeating:"a",count:8200)+".org/"] {
        try check(BrowserSites.pageDecision(url,userBlocked:[]) == .invalid,"page history: invalid: "+(url.count > 60 ? "an 8 KB address" : url))
    }

    // Host rules used at read time.
    try check(BrowserSites.siteOnly(host:"www.google.com") && BrowserSites.siteOnly(host:"google.com.au") && !BrowserSites.siteOnly(host:"docs.google.com"),"page history: only exact Google search hosts are site only")
    try check(BrowserSites.siteOnly(host:"app.slack.com") && !BrowserSites.siteOnly(host:"notslack.com"),"page history: site-only hosts match as a dot-anchored suffix")
    try check(BrowserSites.blockedByDefault(host:"secure.chase.com") && !BrowserSites.blockedByDefault(host:"notchase.com"),"page history: default sites match as a dot-anchored suffix")
    try check(BrowserSites.origin("https://Example.org:8443/a?b#c") == "https://example.org:8443" && BrowserSites.host(of:"http://example.org:80/x") == "example.org","page history: origin keeps a non-default port only")
    try check(BrowserSites.matches(host:"a.example.org",domain:"example.org") && !BrowserSites.matches(host:"badexample.org",domain:"example.org"),"page history: one matching rule")

    // The owner's site entries.
    let entries:[String:String?]=["example.org":"example.org","  Example.ORG ":"example.org","https://www.example.org/path?q=1":"example.org",
        "www.example.org":"example.org","*.example.org":"example.org","docs.example.org":"docs.example.org",".example.org.":"example.org",
        "exa mple.org":nil,"*":nil,"":nil,"https://":nil,"example.org:8080":nil]
    for (raw,expected) in entries.sorted(by:{ $0.key < $1.key }) {
        try check(BrowserSites.siteEntry(raw) == expected,"page history: site entry: \""+raw+"\"")
    }
    try check(BrowserSites.siteEntry("bücher.de") == "xn--bcher-kva.de","page history: a non-ASCII site is stored in its ASCII form")
    try check(BrowserSites.siteEntry("www.Bücher.de") == "xn--bcher-kva.de","page history: a non-ASCII entry drops www. too")
    try check(BrowserSites.siteEntry("bad hostü") == nil,"page history: an invalid non-ASCII entry is refused")

    // websiteDenied applies the defaults and the same matching rule.
    let settings=PrivacySettings()
    for url in ["https://www.plannedparenthood.org/","https://turbotax.intuit.com/","https://secure.chase.com/","https://www.kp.org/","https://www.irs.gov/"] {
        try check(PreCapturePrivacy.websiteDenied(url,settings:settings),"page history: website denied by the default list: "+url)
    }
    try check(!PreCapturePrivacy.websiteDenied("https://notchase.com/",settings:settings) && !PreCapturePrivacy.websiteDenied("https://docs.example.org/",settings:settings),"page history: ordinary sites are not denied")
    var owner=PrivacySettings(); owner.blockedDomains=["example.org"]
    try check(PreCapturePrivacy.websiteDenied("https://docs.example.org/",settings:owner) && !PreCapturePrivacy.websiteDenied("https://badexample.org/",settings:owner),"page history: the owner's list uses the same suffix rule")
    owner.blockedDomains=[" Example.ORG "]
    try check(PreCapturePrivacy.websiteDenied("https://docs.example.org/",settings:owner),"page history: an older saved entry still blocks")
    // Review M2: every row read calls this; the lists are normalized once, not per row.
    var other=PrivacySettings(); other.blockedDomains=["other.example"]
    try check(!PreCapturePrivacy.websiteDenied("https://docs.example.org/",settings:other) && PreCapturePrivacy.websiteDenied("https://a.other.example/",settings:other)
              && PreCapturePrivacy.websiteDenied("https://docs.example.org/",settings:owner),"page history: a changed site list is used at once (no stale copy)")
    var many=PrivacySettings(); many.blockedDomains=(0..<256).map { "site\($0).example.net" }
    let started=Date()
    for i in 0..<2000 { _=PreCapturePrivacy.websiteDenied("https://page\(i % 50).example.org/a",settings:many) }
    let spent=Date().timeIntervalSince(started)
    try check(spent < 1.5,"page history: 2000 row reads of the site rules stay cheap with 256 owner sites (took \(String(format:"%.3f",spent)) s)")
    try check(PreCapturePrivacy.websiteDenied("https://site255.example.net/",settings:many),"page history: the last of 256 owner sites still blocks")
}
