import Foundation
import MemoryCore
import PrivacyPolicy

/// page-links-1003 (owner decision 2026-10-03): a Chrome page row opens the exact page ("the exact YouTube video or X
/// post, not just the site"). `BrowserSites.pageLink` keeps a safe link: scheme, host and path; a YouTube video's v, t and
/// list; a Docs, Sheets or Slides document; an X post; GitHub, Wikipedia and news paths. Never a link for Incognito or
/// Guest, blocked, email, banking or auth pages, a signed or secret address, a token-like path, or a search or chat site
/// (site only). Fake URLs only: no Chrome, no Apple Event, no owner data.
func runPageLinkChecks(home: URL, now: Date) throws {
    // MARK: The owner's fixtures

    let youtube = "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s&utm_source=newsletter&utm_medium=email&feature=share&si=AbCdEf123GhIj"
    try check(BrowserSites.pageLink(youtube) == "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s",
              "page link: a YouTube video keeps v and t, drops utm_*, feature and si (\(String(describing: BrowserSites.pageLink(youtube))))")
    try check(BrowserSites.pageLink("https://www.youtube.com/watch?list=PLfake0123456789&v=dQw4w9WgXcQ&index=3&pp=ygUFZmFrZQ%3D%3D")
              == "https://www.youtube.com/watch?list=PLfake0123456789&v=dQw4w9WgXcQ", "page link: a video in a playlist keeps v and list, drops index and pp")
    try check(BrowserSites.pageLink("https://www.youtube.com/watch?utm_source=x") == nil, "page link: a YouTube watch page without its video keeps none")
    try check(BrowserSites.pageLink("https://www.youtube.com/watch?v=short&t=42") == nil, "page link: a malformed video ID is not kept (nor the page without it)")
    try check(BrowserSites.pageLink("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=12345678") == "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
              "page link: an odd time value is dropped")
    try check(BrowserSites.pageLink("https://youtu.be/dQw4w9WgXcQ?si=AbCdEf123GhIj&t=90") == "https://youtu.be/dQw4w9WgXcQ?t=90", "page link: a youtu.be link keeps its video and time")
    try check(BrowserSites.pageLink("https://www.youtube.com/shorts/dQw4w9WgXcQ?feature=share") == "https://www.youtube.com/shorts/dQw4w9WgXcQ", "page link: a Short keeps its ID")
    try check(BrowserSites.pageLink("https://www.youtube.com/playlist?list=PLfake0123456789&si=x") == "https://www.youtube.com/playlist?list=PLfake0123456789", "page link: a playlist keeps list")
    let x = "https://x.com/fixtureuser/status/1839123456789012344?s=20&t=Zx81kPq0aB7mNc2Lw9Rt4y"
    try check(BrowserSites.pageLink(x) == "https://x.com/fixtureuser/status/1839123456789012344", "page link: an X post keeps its path, drops s and t")
    try check(BrowserSites.pageDecision(x, userBlocked: []) == .record(origin: "https://x.com"),
              "page decision: an X post shared with ?s=20&t=… keeps its title (s on X is a share source, not search words)")
    try check(BrowserSites.pageDecision("https://x.com/search?q=fixture+words", userBlocked: []) == .siteOnly(origin: "https://x.com"), "page decision: an X search stays site only")
    try check(BrowserSites.pageLink("https://twitter.com/fixtureuser/status/4111111111111111") == "https://twitter.com/fixtureuser/status/4111111111111111",
              "page link: an X post number is never read as a card number")
    try check(BrowserSites.pageLink("https://github.com/example-org/example-repo?tab=readme-ov-file#readme") == "https://github.com/example-org/example-repo",
              "page link: a GitHub repo keeps its path only")
    try check(BrowserSites.pageLink("https://github.com/example-org/example-repo/commit/5f3a9c0e1b2d4f6a8b9c0d1e2f3a4b5c6d7e8f90") != nil,
              "page link: a GitHub commit keeps its hash")
    let search = "https://www.google.com/search?q=lighthouse+lenses&oq=lighthouse&sourceid=chrome"
    try check(BrowserSites.pageDecision(search, userBlocked: []) == .siteOnly(origin: "https://www.google.com") && BrowserSites.pageLink(search) == nil,
              "page link: a Google search keeps the site only, never the query")
    let gmail = "https://mail.google.com/mail/u/0/#inbox/FMfcgzQXJWvTkLqPfakeFakeFake"
    try check(BrowserSites.pageDecision(gmail, userBlocked: []) == .siteOnly(origin: "https://mail.google.com") && BrowserSites.pageLink(gmail) == nil,
              "page link: Gmail keeps none")
    try check(BrowserSites.pageDecision("https://app.example.com/oauth/callback?code=4%2F0AbCdEfFake&state=xyz", userBlocked: []) == .blocked,
              "page decision: an OAuth callback is blocked")
    try check(BrowserSites.pageLink("https://app.example.com/oauth/callback?code=4%2F0AbCdEfFake&state=xyz") == nil
              && BrowserSites.pageLink("https://app.example.com/callback?code=fakecode123&state=xyz") == nil
              && BrowserSites.pageLink("https://app.example.com/integrations/done?code=fakecode123") == nil,
              "page link: an auth callback with a code keeps none")
    let s3 = "https://example-bucket.s3.amazonaws.com/reports/q3.pdf?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAFAKE%2F20261003&X-Amz-Expires=900&X-Amz-Signature=abcdef0123456789"
    try check(BrowserSites.pageLink(s3) == nil, "page link: a signed S3 URL keeps none (never its path without the signature)")
    for signed in ["https://storage.googleapis.com/fake-bucket/a.pdf?GoogleAccessId=fake%40example.iam&Expires=1800000000&Signature=abc",
                   "https://fake.blob.core.windows.net/c/a.pdf?sv=2024-01-01&sr=b&sig=abc",
                   "https://d111111abcdef8.cloudfront.net/a.mp4?Expires=1800000000&Signature=abc&Key-Pair-Id=APKAFAKE",
                   "https://example.com/files/report?token=abc123", "https://example.com/doc?access_token=abc", "https://example.com/doc?x-goog-signature=abc"] {
        try check(BrowserSites.pageLink(signed) == nil, "page link: a signed or token URL keeps none: " + (URLComponents(string: signed)?.host ?? ""))
    }

    // MARK: Incognito, through the probe

    final class Fake {
        var url: String, title: String, modes: [String: String]
        init(_ url: String, title: String = "Fixture page", modes: [String: String] = [:]) { self.url = url; self.title = title; self.modes = modes }
        func ask(_ r: ChromePageRequest) -> ChromePageReply? {
            switch r {
            case .windowIDs: return .ids(["w1", "w2"])
            case .mode(let w): return .text(modes[w] ?? "normal")
            case .activeTabID: return .text("t1")
            case .tabURL: return .text(url)
            case .tabTitle: return .text(title)
            }
        }
        func read() -> ChromePageResult { ChromePageProbe.read(userBlocked: [], ask) }
    }
    try check(Fake(youtube, title: "Why do fixtures wear jackets? - YouTube").read()
              == .page(ChromePageRead(windowID: "w1", tabID: "t1", origin: "https://www.youtube.com", title: "Why do fixtures wear jackets? - YouTube",
                                      siteOnly: false, link: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s")),
              "probe: a YouTube video gives its title, origin and video link")
    for mode in ["incognito", "guest"] {
        try check(Fake(youtube, modes: ["w2": mode]).read() == .skipped(.notNormal), "probe: an \(mode) window anywhere saves nothing, no link")
    }
    if case .page(let r) = Fake(gmail).read() { try check(r.siteOnly && r.link == nil, "probe: Gmail is site only, no link") }
    else { try check(false, "probe: Gmail is read as a site") }
    if case .page(let r) = Fake(s3, title: "q3.pdf report").read() { try check(r.link == nil && r.origin == "https://example-bucket.s3.amazonaws.com", "probe: a signed S3 page keeps no link") }
    else { try check(true, "probe: a signed S3 page is not saved") }
    try check(Fake("https://secure.chase.com/web/auth/dashboard").read() == .skipped(.blocked), "probe: a bank page is blocked, no link")
    if case .page(let r) = Fake("https://claude.ai/chat/0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b").read() { try check(r.siteOnly && r.link == nil, "probe: a Claude chat keeps the site only") }
    else { try check(false, "probe: a Claude chat is read as a site") }
    if case .page(let r) = Fake("https://chatgpt.com/c/0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b").read() { try check(r.siteOnly && r.link == nil, "probe: a ChatGPT chat keeps the site only") }
    else { try check(false, "probe: a ChatGPT chat is read as a site") }

    // MARK: Ordinary pages, tokens and fragments

    try check(BrowserSites.pageLink("https://docs.google.com/document/d/1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789fake/edit?usp=sharing&resourcekey=0-fake#heading=h.abc")
              == "https://docs.google.com/document/d/1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789fake/edit", "page link: a Google Doc keeps its document, never resourcekey or the fragment")
    try check(BrowserSites.pageLink("https://docs.google.com/spreadsheets/u/0/d/1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789fake/edit#gid=12")
              == "https://docs.google.com/spreadsheets/u/0/d/1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789fake/edit#gid=12", "page link: a Sheet keeps its tab")
    try check(BrowserSites.pageLink("https://docs.google.com/presentation/d/1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789fake/view") != nil, "page link: Slides keep the deck")
    try check(BrowserSites.pageLink("https://docs.google.com/forms/d/e/1FAIpQLSfakefakefakefakefakefakefake/viewform") == nil, "page link: other docs.google.com pages keep none")
    try check(BrowserSites.pageLink("https://en.wikipedia.org/wiki/Mercury_(planet)#History")
              == "https://en.wikipedia.org/wiki/Mercury_(planet)#History", "page link: a Wikipedia article keeps its path and section")
    try check(BrowserSites.pageLink("https://en.wikipedia.org/wiki/Ender%27s_Game?wprov=sfla1") == "https://en.wikipedia.org/wiki/Ender%27s_Game", "page link: an article name with punctuation is not a secret")
    try check(BrowserSites.pageLink("https://www.example-news.com/2026/10/03/why-lighthouse-lenses-glow-2026?utm_source=x&fbclid=IwAR0fakefake")
              == "https://www.example-news.com/2026/10/03/why-lighthouse-lenses-glow-2026", "page link: a news story keeps its path, drops utm_* and fbclid")
    try check(BrowserSites.pageLink("https://example.org/plans/q3?id=7#top") == "https://example.org/plans/q3", "page link: another site keeps neither query nor fragment")
    try check(BrowserSites.pageLink("https://www.example-news.com/tech/iphone-17-pro-review-h1b-covid-19") != nil, "page link: a slug with model numbers is not a code")
    try check(BrowserSites.pageLink("https://en.wikipedia.org/wiki/Fixture#:~:text=private%20words") == "https://en.wikipedia.org/wiki/Fixture", "page link: a text fragment is dropped")
    for refused in ["https://user:pw@example.com/a/b", "https://example.com/share/eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl",
                    "https://example.com/s/Zx81kPq0aB7mNc2Lw9Rt4yUv", "https://example.com/d/5f3a9c0e1b2d4f6a8b9c0d1e2f3a4b5c",
                    "https://example.com/files/sk_live_abcdefghijklmnop", "https://example.com/reset/Zx81kPq0", "https://example.com/account/verify/abc",
                    "https://example.com/auth/confirm?x=1", "https://example.com/magiclink/abc", "https://example.com/unsubscribe/abc",
                    "https://shop.example.com/pay/4111111111111111", "https://example.com/k/a8F3-kd92-LsP0",
                    "https://example.com/item/0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b", "https://example.com/;jsessionid=ABC123", "https://example.com/",
                    "https://www.youtube.com/results?search_query=fixture+words", "https://www.reddit.com/message/inbox"] {
        try check(BrowserSites.pageLink(refused) == nil, "page link: refused: " + refused.replacingOccurrences(of: "https://", with: ""))
    }
    // Idempotent: a kept link read again (Privacy.sanitized, Open Original) is the same link.
    for url in [youtube, x, "https://youtu.be/dQw4w9WgXcQ?t=90", "https://en.wikipedia.org/wiki/Mercury_(planet)#History",
                "https://docs.google.com/spreadsheets/u/0/d/1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789fake/edit#gid=12"] {
        let once = BrowserSites.pageLink(url)
        try check(once != nil && BrowserSites.pageLink(once!) == once, "page link: idempotent: " + (once ?? "nil"))
    }

    // Search & AI sites keep the site only while search typing is on: no link either (TypedHistoryScrub).
    var chat = Evidence(id: "pl-chat", at: iso(now), kind: "window.changed", app: "Google Chrome", bundle: BrowserSafety.supportedBundle,
                        title: "", url: "https://claude.ai", synthetic: true)
    chat.page = "https://claude.ai/chat/0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b"
    try check(TypedHistoryScrub.apply(chat, searchTypingOn: true).page == nil, "search typing on: a Search & AI page keeps no link")

    // MARK: The short link a row shows

    try check(BrowserSites.shortLink("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s") == "youtube.com/watch…", "short link: youtube.com/watch…")
    try check(BrowserSites.shortLink("https://github.com/example-org/example-repo") == "github.com/example-org/example-repo", "short link: a GitHub repo in full")
    try check(BrowserSites.shortLink("https://x.com/fixtureuser/status/1839123456789012344") == "x.com/fixtureuser/status/18391234567…", "short link: cut at 36 with …")
    try check(BrowserSites.shortLink("https://example.org") == nil, "short link: none for a site")

    // MARK: Store: kept on this Mac, opened, never encoded; retention, Forget and the owner's blocks

    let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    func page(_ id: String, url: String, link: String?, title: String, at: Date) -> Evidence {
        var proof = BrowserVerification(mode: "normal", windowID: "1520", tabID: "1733", focusedRole: "", checkedAt: isoPrecise(at), provider: BrowserSafety.pageProvider)
        proof.policyRevision = "policy-fixture"
        var e = Evidence(id: id, at: isoPrecise(at), kind: "window.changed", app: "Google Chrome", bundle: BrowserSafety.supportedBundle,
                         title: title, url: url, browserVerification: proof)
        e.page = link
        return e
    }
    try check(try store.ingest(page("pl-yt", url: "https://www.youtube.com", link: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s",
                                    title: "Why do fixtures wear jackets? - YouTube", at: now.addingTimeInterval(-60)), now: now), "store: a YouTube page row with its link")
    try check(try store.ingest(page("pl-old", url: "https://www.youtube.com", link: nil, title: "An older video - YouTube", at: now.addingTimeInterval(-50)), now: now),
              "store: an older row saved without a link")
    try check(try store.ingest(page("pl-tok", url: "https://example.com", link: "https://example.com/files/report?token=abc123", title: "Report", at: now.addingTimeInterval(-40)), now: now),
              "store: a row whose link carries a token")
    try check(try store.read("pl-yt", now: now)?.evidence.page == "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s", "store: the video link is kept")
    try check(try store.read("pl-tok", now: now)?.evidence.page == nil, "store: a token link is never shown (read again through pageLink)")
    let action = try store.action("pl-yt", now: now)
    try check(action?.link == "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s" && action?.site == "www.youtube.com", "action: the app's action carries the link")
    let encoded = try String(decoding: JSONEncoder().encode(action), as: UTF8.self)
    try check(!encoded.contains("dQw4w9WgXcQ") && !encoded.contains("\"link\""), "action: an encoded action (MCP, CLI, consumers) never carries the link")
    try check(try store.readerItem("pl-yt", now: now)?.evidence.page == nil, "store: the CLI's read names the site only")
    struct Verifier: OriginalSourceVerifier {
        func verify(url: String, deadline: Date) throws -> OriginalSourceCheck { OriginalSourceCheck(url: url, exists: true, readOnly: true) }
    }
    try check(try store.originalSourceLink(actionID: "pl-yt", verifier: Verifier(), now: now).url == "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s",
              "Open Original: the row opens the exact video")
    try check(try store.originalSourceLink(actionID: "pl-old", verifier: Verifier(), now: now).url == "https://www.youtube.com",
              "Open Original: an old row without a link opens its site")
    try check(try store.originalSourceLink(actionID: "pl-tok", verifier: Verifier(), now: now).url == "https://example.com",
              "Open Original: a token link falls back to the site")
    // Forget: the row and its link are gone.
    let forget = try store.prepareDeletion(scope: MemoryActionScope(kind: "action", id: "pl-tok"), now: now)
    _ = try store.executeDeletion(previewID: forget.id, confirmed: true, now: now)
    try check(try store.read("pl-tok", now: now) == nil, "Forget: the row and its link are gone")
    // The owner blocks the site later: the row (and its link) is hidden.
    var settings = try store.policy()
    settings.blockedDomains = (settings.blockedDomains) + ["youtube.com"]
    try store.updatePolicy(settings, now: now)
    try check(try store.read("pl-yt", now: now) == nil, "blocked later: the row and its link are hidden")
    settings.blockedDomains.removeAll { $0 == "youtube.com" }
    try store.updatePolicy(settings, now: now)
    // Retention: a row past the retention window is not read, so its link never opens.
    try check(try store.ingest(page("pl-aged", url: "https://github.com", link: "https://github.com/example-org/example-repo", title: "example-repo",
                                    at: now.addingTimeInterval(-40 * 86_400)), now: now), "store: a 40-day-old row with its link")
    try check(try store.read("pl-aged", now: now)?.evidence.page == "https://github.com/example-org/example-repo", "store: kept while retention is Never")
    let review = try store.prepareRetentionChange(.days(30), now: now)
    _ = try store.confirmRetentionChange(review.id, confirmed: true, now: now)
    try check(try store.read("pl-aged", now: now) == nil, "retention: past 30 days the row and its link are gone")
    try check(try store.read("pl-yt", now: now)?.evidence.page != nil, "retention: a recent row keeps its link")
}
