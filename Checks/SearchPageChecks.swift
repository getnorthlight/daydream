import Foundation
import MemoryCore
import PrivacyPolicy

/// claude/search-1005 (owner decision 2026-10-04: "I went to different google sites so it is retarded that that was not
/// saved"): a search engine's results page keeps its search words as the Chrome page row's title, one row per distinct
/// search, in every build (public and owner alike, with or without typing). Never any other part of the address; never
/// from an Incognito or Guest window or a blocked site; never words that look secret. Email and chat pages stay
/// site-only. Synthetic only: made-up searches, a scripted fake Chrome, scratch stores. No Apple Event, no real history.
func runSearchPageChecks(home: URL, now: Date) throws {
    // 1. The words, from the engine's own parameter on its results path only; nothing else of the address.
    let cases: [(String, (String, String)?)] = [
        ("https://www.google.com/search?q=fixture+boots+size+10&oq=fixture+boots&sourceid=chrome&ie=UTF-8&sca_esv=abc123", ("Google", "fixture boots size 10")),
        ("https://www.google.co.uk/search?q=caf%C3%A9%20fixture", ("Google", "café fixture")),
        ("https://google.com/search?client=safari&q=two++spaces%20fixture", ("Google", "two spaces fixture")),
        ("https://www.bing.com/search?q=swift+async+let&form=QBLH", ("Bing", "swift async let")),
        ("https://duckduckgo.com/?q=boom+bap+fixture&ia=web", ("DuckDuckGo", "boom bap fixture")),
        ("https://search.yahoo.com/search?p=weather+fixtureville", ("Yahoo", "weather fixtureville")),
        ("https://search.brave.com/search?q=fixture+recipe&source=web", ("Brave Search", "fixture recipe")),
        ("https://www.startpage.com/do/search?query=fixture+maps", ("Startpage", "fixture maps")),
        ("https://yandex.com/search/?text=fixture+river", ("Yandex", "fixture river")),
        ("https://www.baidu.com/s?wd=fixture+tea", ("Baidu", "fixture tea")),
        // Not a results page, or no words: nothing.
        ("https://www.google.com/", nil), ("https://www.google.com/maps?q=coffee", nil), ("https://www.google.com/search?tbm=isch", nil),
        ("https://www.bing.com/?q=x", nil), ("https://notgoogle.example.com/search?q=x", nil), ("https://www.youtube.com/results?search_query=x", nil),
        ("https://x.com/search?q=fixture", nil), ("https://example.org/?q=fixture", nil),
        // Words that are never kept: a secret, a code of digits, an email address, more than one line, too long.
        ("https://www.google.com/search?q=password%3A+hunter2", nil), ("https://www.google.com/search?q=482913", nil),
        ("https://www.google.com/search?q=sam%40example.com+invoice", nil), ("https://www.google.com/search?q=sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789", nil),
        ("https://www.google.com/search?q=line+one%0Aline+two", nil),
        ("https://www.google.com/search?q=" + String(repeating: "a", count: 170), nil),
    ]
    for (url, want) in cases {
        let got = SearchPage.query(url)
        try check(got?.engine == want?.0 && got?.query == want?.1,
                  "search words: \(want == nil ? "none" : "the words") from a \(URLComponents(string: url)?.host ?? "?") address (\(got?.engine ?? "nil"))")
    }
    // The tab title, only when the address has none, and only on a results page.
    try check(SearchPage.titleQuery("fixture boots - Google Search", url: "https://www.google.com/search#fixture")?.query == "fixture boots"
              && SearchPage.titleQuery("fixture boots at DuckDuckGo", url: "https://duckduckgo.com/")?.query == "fixture boots"
              && SearchPage.titleQuery("fixture boots - Google Search", url: "https://www.google.com/maps") == nil
              && SearchPage.titleQuery("Google", url: "https://www.google.com/search") == nil
              && SearchPage.titleQuery(" - Google Search", url: "https://www.google.com/search") == nil,
              "search words: from the title \"<words> - Google Search\" on a results page only")

    // 2. The page read: the words become the row's title; no link, no other part of the address, title not asked.
    final class Fake {
        var windows = ["w1", "w2"], modes: [String: String] = [:], url = "", title = "fixture boots - Google Search"
        var log: [ChromePageRequest] = []
        func ask(_ r: ChromePageRequest) -> ChromePageReply? {
            log.append(r)
            switch r {
            case .windowIDs: return .ids(windows)
            case .mode(let w): return .text(modes[w] ?? "normal")
            case .activeTabID: return .text("t1")
            case .tabURL: return .text(url)
            case .tabTitle: return .text(title)
            }
        }
        func read(_ blocked: [String] = [], subjects: Bool = false) -> ChromePageResult { ChromePageProbe.read(userBlocked: blocked, emailSubjects: subjects, ask) }
        var asksTitle: Bool { log.contains { if case .tabTitle = $0 { return true }; return false } }
        var asksURL: Bool { log.contains { if case .tabURL = $0 { return true }; return false } }
    }
    var f = Fake(); f.url = "https://www.google.com/search?q=fixture+boots&sca_esv=abc123&ei=XyZ&ved=0ahUKE"
    try check(f.read() == .page(ChromePageRead(windowID: "w1", tabID: "t1", origin: "https://www.google.com", title: "fixture boots", siteOnly: true))
              && !f.asksTitle,
              "search page: the row is the site and the search words, no link; the title is never asked when the address has the words")
    let shown = "\(f.read())"
    for part in ["sca_esv", "abc123", "XyZ", "0ahUKE", "?", "/search"] {
        try check(!shown.contains(part), "search page: no other part of the address leaves the read: " + part)
    }
    f = Fake(); f.url = "https://www.google.com/search"
    if case .page(let r) = f.read() {
        try check(r.title == "fixture boots" && r.siteOnly && r.link == nil && f.log.filter({ if case .tabTitle = $0 { return true }; return false }).count == 1,
                  "search page: an address without the words takes them from its title (asked once)")
    } else { try check(false, "search page: an address without the words is still read") }
    f = Fake(); f.url = "https://www.google.com/search?q=sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"
    f.title = "sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789 - Google Search"
    if case .page(let r) = f.read() { try check(r.title.isEmpty && r.siteOnly, "search page: secret-looking words: the site only, never the words") }
    else { try check(false, "search page: secret-looking words still save the site") }
    f = Fake(); f.url = "https://www.google.com/"
    if case .page(let r) = f.read() { try check(r.title.isEmpty && r.siteOnly && !f.asksTitle, "search page: the engine's home page is the site only, title not asked") }
    else { try check(false, "search page: the home page is read") }
    // Incognito or Guest anywhere: nothing, and the address is never asked for.
    for mode in ["incognito", "guest", ""] {
        f = Fake(); f.url = "https://www.google.com/search?q=fixture+boots"; f.modes["w2"] = mode
        try check(f.read() == .skipped(.notNormal) && !f.asksURL && !f.asksTitle,
                  "search page: an \(mode.isEmpty ? "unknown" : mode) window: nothing saved, no address or title asked")
    }
    // The blocklist (the owner's, the defaults and blocked words in the search) comes first.
    f = Fake(); f.url = "https://www.google.com/search?q=fixture+boots"
    try check(f.read(["google.com"]) == .skipped(.blocked) && !f.asksTitle, "search page: a blocked engine saves nothing")
    f = Fake(); f.url = "https://www.google.com/search?q=chase+bank+login"
    try check(f.read() == .skipped(.blocked), "search page: a search with a blocked word saves nothing")
    // Email and chat pages stay site-only; the email rule is unchanged.
    for url in ["https://chatgpt.com/?q=fixture+question", "https://claude.ai/new?q=fixture", "https://www.perplexity.ai/search?q=fixture",
                "https://mail.google.com/mail/u/0/#search/fixture"] {
        f = Fake(); f.url = url
        if case .page(let r) = f.read() { try check(r.siteOnly && r.title.isEmpty && !f.asksTitle, "search page: chat and email stay site only: " + url) }
        else { try check(false, "search page: chat or email page read: " + url) }
    }
    // Two different searches are two rows; the same search seen again in the same tab is one.
    var tracker = ChromePageTracker()
    let a = ChromePageRead(windowID: "w1", tabID: "t1", origin: "https://www.google.com", title: "fixture boots", siteOnly: true)
    let b = ChromePageRead(windowID: "w1", tabID: "t1", origin: "https://www.google.com", title: "fixture laces", siteOnly: true)
    var saved: [String] = []
    var t = now
    for read in [a, a, b, b, b] {
        if case .record(let r) = tracker.observe(read, at: t) { saved.append(r.title) }
        t = t.addingTimeInterval(1.5)
    }
    try check(saved == ["fixture boots", "fixture laces"], "search page: two different searches are two rows (\(saved.count))")

    // 3. The store: the row is valid with its words, refused with anything else, and kept with search-box typing on.
    func row(_ id: String, title: String, url: String = "https://www.google.com", at: Date? = nil) -> Evidence {
        var proof = BrowserVerification(mode: "normal", windowID: "1520", tabID: "1733", focusedRole: "", checkedAt: isoPrecise(at ?? now),
                                        provider: BrowserSafety.pageProvider)
        proof.policyRevision = "policy-fixture"
        return Evidence(id: id, at: isoPrecise(at ?? now), kind: "window.changed", app: "Google Chrome", bundle: BrowserSafety.supportedBundle,
                        title: title, url: url, browserVerification: proof)
    }
    try check(BrowserSafety.valid(row("v1", title: "fixture boots")) && BrowserSafety.valid(row("v2", title: "fixture boots", url: "https://duckduckgo.com")),
              "search store: a search engine's page row with its words is valid")
    for (title, why) in [("fixture boots - Google Search", "the engine's title"), ("482913", "a code"), ("sam@example.com invoice", "an email address"),
                         ("password: hunter2", "a secret"), (String(repeating: "a", count: 161), "too long")] {
        try check(!BrowserSafety.valid(row("bad", title: title)), "search store: refused: " + why)
    }
    try check(!BrowserSafety.valid(row("chat", title: "fixture question", url: "https://chatgpt.com"))
              && !BrowserSafety.valid(row("mail", title: "fixture boots", url: "https://www.messenger.com")),
              "search store: a chat site's page row with a title is still refused")
    try check(!BrowserSafety.valid(row("q", title: "fixture boots", url: "https://www.google.com/search?q=fixture+boots")),
              "search store: never the search address itself")
    try check(ActionProjection.make(row("d", title: "fixture boots")).description
                == "Observed search results for fixture boots in Google Chrome; submission and reading are not established.",
              "search store: the action says it was a search")
    try check(ThreadEntities.entity(app: "Google Chrome", bundle: BrowserSafety.supportedBundle, site: "www.google.com", title: "fixture boots").kind == "search",
              "search store: a search row joins Web searches")
    try check(SearchPage.line("fixture boots") == "Searched \u{201C}fixture boots\u{201D}", "search card: \"Searched “…”\"")

    let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    var policy = try store.policy(); policy.browserPages = true; policy.browserPagesConsentVersion = PrivacySettings.browserPagesConsentCurrent
    try store.updatePolicy(policy, now: now)
    try check(try store.ingest(row("s1", title: "fixture boots"), now: now) && store.ingest(row("s2", title: "fixture laces"), now: now),
              "search store: two searches are saved")
    try check(try store.read("s1", now: now)?.evidence.title == "fixture boots" && store.read("s1", now: now)?.evidence.url == "https://www.google.com"
              && store.read("s2", now: now)?.evidence.title == "fixture laces",
              "search store: each row reads back with its own words and the site only")
    try check(try store.action("s2", now: now)?.description.contains("search results for fixture laces") == true,
              "search store: the saved action names the search")
    try check(try !store.ingest(row("s3", title: "fixture boots - Google Search"), now: now), "search store: the engine's own title is refused at write")
    // Search-box typing on (consent v2, Search and AI): page rows of Search & AI sites lose their titles at ingest, except a
    // search engine's search words.
    try store.acceptSafeTyping(now: now)
    let typed = try store.typedTextPolicy()
    try check(typed.consented && typed.categories.searchAndAI, "search store: fixture: search-box typing is on")
    try check(try store.ingest(row("s4", title: "fixture socks"), now: now) && store.read("s4", now: now)?.evidence.title == "fixture socks",
              "search store: search-box typing on keeps a search row's words")
    let scrubbed = TypedHistoryScrub.apply(row("s5", title: "fixture question", url: "https://www.perplexity.ai"), searchTypingOn: true)
    try check(scrubbed.title.isEmpty, "search store: search-box typing on still drops an AI chat page's title")
    // Blocking the engine afterwards hides its searches.
    policy = try store.policy(); policy.blockedDomains = ["google.com"]
    try store.updatePolicy(policy, now: now)
    try check(try store.read("s1", now: now) == nil && store.read("s4", now: now) == nil, "search store: blocking the engine hides its searches")
}
