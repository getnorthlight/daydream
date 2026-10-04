import Foundation

// Site rules shared by Chrome page history (public) and Chrome typing (private).
// All matching is ASCII and lowercase. Suffix matching: a domain blocks itself
// and every subdomain ("chase.com" blocks "secure.chase.com", not "notchase.com").
//
// Curation rules for BrowserSiteList (enforced by checks):
// - entries are BrowserSites.normalizedDomain output, with no duplicates across
//   all categories;
// - suffix match covers subdomains, so list the registrable domain unless one
//   subdomain is the sensitive part (accounts.google.com);
// - no web consoles, IDEs or terminals in page defaults (they are a
//   typing-only extra in the private build);
// - new entries need a category.

public enum BrowserPageDecision: Equatable, Sendable {
    /// Save the title and the origin.
    case record(origin: String)
    /// Save the origin only (search, email and chat pages).
    case siteOnly(origin: String)
    case blocked
    case invalid
}

/// The default "not recorded" sites for Chrome page history.
public enum BrowserSiteList {
    /// App-wide sensitive domains (Models.swift). Always blocked; can't be removed.
    public static var pinned: [String] { PrivacySettings.sensitiveDomains }
    /// Always applied, shown read-only in Settings. Not stored in the owner's list.
    public static let pageDefaults: [String] = passwordManagers + signIn + banking + payments + credit + health + reproductiveHealth + government
    public static let passwordManagers = ["1password.com", "1password.eu", "1password.ca", "bitwarden.com", "bitwarden.eu", "lastpass.com", "lastpass.eu",
        "dashlane.com", "keepersecurity.com", "keepersecurity.eu", "keeper.io", "nordpass.com", "pass.proton.me", "roboform.com", "enpass.io",
        "vault.zoho.com", "vault.zoho.eu", "passwords.google.com"]
    public static let signIn = ["accounts.google.com", "myaccount.google.com", "appleid.apple.com", "account.apple.com", "idmsa.apple.com",
        "login.microsoftonline.com", "login.live.com", "account.live.com", "account.microsoft.com", "login.yahoo.com",
        "okta.com", "auth0.com", "onelogin.com", "duosecurity.com", "pingidentity.com", "id.me"]
    public static let banking = ["chase.com", "bankofamerica.com", "wellsfargo.com", "citi.com", "citibank.com", "capitalone.com", "usbank.com",
        "pnc.com", "truist.com", "td.com", "tdbank.com", "ally.com", "discover.com", "americanexpress.com", "usaa.com", "navyfederal.org",
        "regions.com", "citizensbank.com", "key.com", "huntington.com", "mtb.com", "53.com", "schwab.com", "fidelity.com", "vanguard.com",
        "etrade.com", "morganstanley.com", "merrilledge.com", "ml.com", "robinhood.com", "interactivebrokers.com", "wealthfront.com",
        "betterment.com", "sofi.com", "chime.com", "marcus.com", "goldmansachs.com", "hsbc.com", "hsbc.co.uk", "barclays.com",
        "barclays.co.uk", "lloydsbank.com", "natwest.com", "santander.com", "santander.co.uk", "nationwide.co.uk", "monzo.com",
        "starlingbank.com", "revolut.com", "n26.com", "rbc.com", "royalbank.com", "scotiabank.com", "bmo.com", "cibc.com",
        "commbank.com.au", "westpac.com.au", "anz.com", "nab.com.au"]
    public static let payments = ["paypal.com", "venmo.com", "cash.app", "zellepay.com", "stripe.com", "squareup.com", "wise.com", "klarna.com",
        "affirm.com", "afterpay.com", "pay.google.com", "payments.google.com", "wallet.google.com", "pay.amazon.com", "westernunion.com",
        "remitly.com", "xoom.com", "coinbase.com", "kraken.com", "binance.com", "binance.us", "gemini.com", "crypto.com", "metamask.io",
        "blockchain.com"]
    public static let credit = ["equifax.com", "experian.com", "transunion.com", "creditkarma.com", "annualcreditreport.com"]
    public static let health = ["mychart.org", "followmyhealth.com", "kp.org", "kaiserpermanente.org", "onemedical.com", "zocdoc.com", "teladoc.com",
        "labcorp.com", "questdiagnostics.com", "athenahealth.com", "anthem.com", "uhc.com", "myuhc.com", "aetna.com", "cigna.com", "bcbs.com",
        "humana.com", "goodrx.com", "betterhelp.com", "talkspace.com", "23andme.com", "nhs.uk", "cvs.com", "walgreens.com", "hims.com", "forhers.com"]
    public static let reproductiveHealth = ["plannedparenthood.org", "abortionfinder.org", "aidaccess.org", "ineedana.com", "plancpills.org",
        "prochoice.org", "womenonweb.org", "heyjane.com", "carafem.org", "bedsider.org", "scarleteen.com", "flo.health", "helloclue.com",
        "naturalcycles.com", "nurx.com", "thepillclub.com", "stdcheck.com", "mylabbox.com", "folxhealth.com", "mistr.com", "kindbody.com",
        "progyny.com"]
    public static let government = ["gov", "mil", "gov.uk", "gc.ca", "canada.ca", "gov.au", "govt.nz", "gouv.fr", "gov.in", "europa.eu",
        "gov.br", "gob.mx", "gob.es", "gob.ar", "gob.cl", "gob.pe", "gov.co", "bund.de", "admin.ch", "gv.at", "go.jp", "go.kr",
        "gov.sg", "gov.hk", "gov.za", "gov.ie", "gov.il", "gov.it", "gov.pl", "gov.pt", "gov.ph", "gov.my", "gov.cn", "gouv.qc.ca",
        "belgium.be", "overheid.nl", "rijksoverheid.nl", "digid.nl", "service-public.fr", "elster.de", "skatteverket.se",
        "irs.gov", "ssa.gov", "login.gov", "turbotax.intuit.com", "hrblock.com", "taxact.com", "freetaxusa.com", "taxslayer.com"]
    /// The Settings read-only list, one heading per category.
    public static let categories: [(title: String, domains: [String])] = [
        ("Password managers", passwordManagers), ("Sign-in pages", signIn), ("Banks and investing", banking),
        ("Payments and crypto", payments), ("Credit reports", credit), ("Health", health),
        ("Sexual and reproductive health", reproductiveHealth), ("Government and taxes", government)]
}

public enum BrowserSites {
    /// Host substrings that always block (mirrors PreCapturePrivacy.websiteDenied, plus health portals).
    public static let hostKeywords = ["bank", "wallet", "password", "login", "signin", "sign-in", "oauth", "payment", "checkout",
        "mychart", "patientportal", "patient-portal", "abortion"]
    /// Whole host labels that always block: government and military hosts
    /// under any country code ("tax.gob.xx", "portal.gov.xx", "x.mil.xx").
    public static let hostLabels: Set<String> = ["gov", "gob", "gouv", "govt", "mil"]
    /// Path, query and hash-route substrings that always block: login,
    /// checkout and similar pages. `_` is read as `-` first.
    public static let pathKeywords = ["login", "log-in", "logon", "signin", "sign-in", "signup", "sign-up", "oauth", "authorize", "authenticate",
        "password", "passwd", "passkey", "webauthn", "checkout", "payment", "billing", "wallet", "bank", "mychart", "patient",
        "basket", "verification", "purchase", "two-factor"]
    /// Whole path segments that always block (too short for substring matching).
    public static let pathTokens: Set<String> = ["sso", "saml", "2fa", "mfa", "otp", "pay", "cart", "bag", "auth", "reset", "recover", "recovery",
        "verify", "tax", "taxes", "health", "medical", "pharmacy", "prescriptions", "session", "sessions", "donate", "invoice", "invoices",
        "abortion", "contraception", "miscarriage"]
    /// Adjacent tokens that always block ("sign.in", "Sign%20In", "log_in", "two-step").
    public static let tokenPairs: Set<String> = ["sign in", "log in", "sign on", "sign up", "two factor", "2 step", "two step",
        "multi factor", "one time", "check out", "birth control", "sexual health", "reproductive health", "morning after"]

    /// Common search, email and chat hosts: the site is saved, never the title, except an email page's cleaned title
    /// while "Save email subjects" is on (email-1003, owner decision 2026-10-03: `emailHosts`, `EmailTitle`).
    /// Dot-anchored suffix match. Exact Google search hosts are matched separately.
    /// Not complete (the wording says "common"); the owner can block any site.
    public static let siteOnlyHosts = searchHosts + emailHosts + chatHosts
    public static let searchHosts = [
        "bing.com", "duckduckgo.com", "search.yahoo.com", "search.brave.com", "ecosia.org", "startpage.com", "kagi.com", "yandex.com",
        "yandex.ru", "baidu.com", "search.aol.com"]
    /// Webmail. email-1003 (owner decision 2026-10-03): DayDream records what happens in email, so an email page keeps its
    /// cleaned title (the open email's subject or the folder: `EmailTitle.web`); search and chat sites stay site-only.
    public static let emailHosts = [
        "mail.google.com", "outlook.live.com", "outlook.office.com", "outlook.office365.com", "outlook.cloud.microsoft", "mail.yahoo.com",
        "mail.proton.me", "mail.aol.com", "icloud.com", "fastmail.com", "app.hey.com", "mail.zoho.com", "mail.zoho.eu", "gmx.com", "gmx.net",
        "mail.com", "gmx.de", "gmx.at", "gmx.ch", "web.de", "mail.ru", "mail.yandex.ru", "mail.yandex.com", "mail.yandex.com.tr",
        "mail.yandex.kz", "mail.yandex.by", "mail.qq.com", "app.tuta.com", "mail.tutanota.com", "mail.superhuman.com",
        "mail.yahoo.co.jp", "posteo.de", "mailbox.org", "mail.naver.com"]
    /// Chat and AI chat.
    public static let chatHosts = [
        "web.whatsapp.com", "messenger.com", "web.telegram.org", "discord.com", "slack.com", "teams.microsoft.com", "teams.live.com",
        "teams.cloud.microsoft", "chat.google.com", "messages.google.com", "web.skype.com", "chatgpt.com", "chat.openai.com", "claude.ai",
        "gemini.google.com", "copilot.microsoft.com", "perplexity.ai", "poe.com", "character.ai", "chat.mistral.ai", "meta.ai", "grok.com",
        "chat.deepseek.com", "you.com", "aistudio.google.com", "chat.reddit.com", "chat.qwen.ai", "pi.ai", "app.element.io",
        "copilot.cloud.microsoft"]
    /// Message pages on otherwise ordinary sites (capture time only, from the address that is read and dropped).
    public static let siteOnlyPaths: [(host: String, path: String)] = [
        ("facebook.com", "/messages"), ("instagram.com", "/direct"), ("x.com", "/messages"), ("x.com", "/i/chat"),
        ("twitter.com", "/messages"), ("linkedin.com", "/messaging"), ("reddit.com", "/message"), ("reddit.com", "/chat"),
        ("huggingface.co", "/chat"), ("m365.cloud.microsoft", "/chat")]
    /// A query item with one of these names and a non-empty value is a search (capture time only).
    public static let searchParameters: Set<String> = ["q", "query", "search", "search_query", "k", "p", "s", "term", "keywords", "text",
        "searchterm", "st", "_nkw", "field-keywords", "search_terms", "searchtext"]

    /// scheme://host[:port] for http(s) only; nil for anything else (deny).
    public static func origin(_ raw: String) -> String? {
        guard let (scheme, host, port, _) = parts(raw) else { return nil }
        return scheme + "://" + host + (port.map { ":\($0)" } ?? "")
    }
    public static func host(of raw: String) -> String? { parts(raw)?.host }
    static func parts(_ raw: String) -> (scheme: String, host: String, port: Int?, components: URLComponents)? {
        guard raw.utf8.count <= 8192, let u = URLComponents(string: raw), let scheme = u.scheme?.lowercased(),
              ["http", "https"].contains(scheme), u.user == nil, u.password == nil,
              let rawHost = u.host?.lowercased() else { return nil }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty, host.utf8.count <= 253, host.range(of: "^[a-z0-9-]+(\\.[a-z0-9-]+)*$", options: .regularExpression) != nil else { return nil }
        let port = u.port.flatMap { (scheme == "http" && $0 == 80) || (scheme == "https" && $0 == 443) ? nil : $0 }
        return (scheme, host, port, u)
    }
    /// "example.org", "https://example.org/x", "*.example.org", ".Example.org." -> "example.org".
    public static func normalizedDomain(_ entry: String) -> String? {
        var s = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.contains("://") { guard let h = URLComponents(string: s)?.host?.lowercased() else { return nil }; s = h }
        if s.hasPrefix("*.") { s.removeFirst(2) }
        s = String(s.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !s.isEmpty, s.utf8.count <= 253, s.range(of: "^[a-z0-9-]+(\\.[a-z0-9-]+)*$", options: .regularExpression) != nil else { return nil }
        return s
    }
    /// Dot-anchored suffix match: "chase.com" blocks "chase.com" and "secure.chase.com", not "notchase.com".
    public static func matches(host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }
    /// Deny-only reading of a path, query or route. Chrome typing passes its
    /// own path tokens (these plus the console words).
    public static func blocks(_ raw: String, pathTokens: Set<String> = pathTokens) -> Bool {
        var text = raw
        for _ in 0..<3 { guard let decoded = text.removingPercentEncoding, decoded != text else { break }; text = decoded }
        text = text.precomposedStringWithCompatibilityMapping.lowercased().replacingOccurrences(of: "_", with: "-")
        if pathKeywords.contains(where: text.contains) { return true }
        let tokens = text.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        if tokens.contains(where: pathTokens.contains) { return true }
        return zip(tokens, tokens.dropFirst()).contains { tokenPairs.contains($0 + " " + $1) }
    }

    /// The owner's "Sites not recorded" entry: "https://www.Bücher.de/x" -> "xn--bcher-kva.de".
    /// Covers the site and its subdomains. nil when the entry is not a site.
    public static func siteEntry(_ entry: String) -> String? {
        var s = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.unicodeScalars.contains(where: { !$0.isASCII }) {
            var c = URLComponents(); c.scheme = "https"; c.host = s; s = c.encodedHost ?? ""
        }
        guard var d = normalizedDomain(s) else { return nil }
        if d.hasPrefix("www.") { d.removeFirst(4) }
        return normalizedDomain(d) == d ? d : nil
    }
    /// Pinned and default sites, host keywords and government labels. Read time
    /// too, so a later default list also hides pages saved before it.
    public static func blockedByDefault(host: String) -> Bool {
        let h = host.lowercased()
        if (BrowserSiteList.pinned + BrowserSiteList.pageDefaults).contains(where: { matches(host: h, domain: $0) }) { return true }
        if hostKeywords.contains(where: h.contains) { return true }
        return h.split(whereSeparator: { $0 == "." || $0 == "-" }).contains(where: { hostLabels.contains(String($0)) })
    }
    /// Search, email and chat hosts (the read-time rule): the title is never kept, except an email page's (`emailHost`, email-1003).
    public static func siteOnly(host: String) -> Bool {
        let h = host.lowercased()
        if h.range(of: "^(www\\.)?google(\\.[a-z]{2,3}){1,2}$", options: .regularExpression) != nil { return true }
        return siteOnlyHosts.contains(where: { matches(host: h, domain: $0) })
    }
    /// email-1003: a webmail host (`emailHosts`; the most specific site-only entry decides, so a search or chat entry
    /// under the same domain never counts). Read time: the page row's title may be kept (`BrowserSafety`).
    public static func emailHost(host: String) -> Bool {
        let h = host.lowercased()
        guard let entry = siteOnlyHosts.filter({ matches(host: h, domain: $0) }).max(by: { $0.count < $1.count }) else { return false }
        return emailHosts.contains(entry)
    }
    /// Pages on a webmail host that are not mail: its chat, calendar, contacts and files (Gmail's /chat is a chat site,
    /// which stays site-only). iCloud keeps a title only under /mail (its Drive, Notes and Pages are not email).
    static let nonMailPaths = ["/chat", "/calendar", "/people", "/contacts", "/meet", "/files", "/tasks", "/todo", "/drive", "/notes", "/photos"]
    /// email-1003: whether the address is an email page whose title may be kept (capture time; the address is dropped).
    public static func emailPage(_ url: String) -> Bool {
        guard let p = parts(url), emailHost(host: p.host), !messagePath(host: p.host, path: p.components.path) else { return false }
        let path = p.components.path.lowercased()
        if nonMailPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return false }
        if matches(host: p.host, domain: "icloud.com") { return path == "/mail" || path.hasPrefix("/mail/") }
        return true
    }
    /// The capture-time decision for the address of the page in front. The
    /// address is read, decided on and dropped: only the origin is returned.
    public static func pageDecision(_ url: String, userBlocked: [String]) -> BrowserPageDecision {
        guard let p = parts(url), let origin = origin(url), !origin.contains("?"), !origin.contains("#") else { return .invalid }
        let domains = BrowserSiteList.pinned + BrowserSiteList.pageDefaults + userBlocked.compactMap(normalizedDomain)
        if domains.contains(where: { matches(host: p.host, domain: $0) }) { return .blocked }
        if blockedByDefault(host: p.host) { return .blocked }
        // Hash-routed apps ("#/login", "#!/checkout") carry their page path in
        // the fragment; it is checked as a path (deny-only), never stored.
        var texts = [p.components.percentEncodedPath]
        if let query = p.components.percentEncodedQuery { texts.append(query.replacingOccurrences(of: "+", with: " ")) }
        if var route = p.components.percentEncodedFragment {
            if route.hasPrefix("!") { route.removeFirst() }
            if route.hasPrefix("/") { texts.append(route) }
        }
        if texts.contains(where: { blocks($0) }) { return .blocked }
        if siteOnly(host: p.host) || messagePath(host: p.host, path: p.components.path) || searchQuery(p.components) {
            return .siteOnly(origin: origin)
        }
        return .record(origin: origin)
    }
    /// fix/show-all, page-links-1003 (owner decision 2026-10-03: a page row opens the exact page, "the exact YouTube video or
    /// X post, not just the site"): a page's own link as kept on this Mac for Open Original (`Evidence.page`). Kept: the
    /// scheme, host, port and path; from the query only the site's keys (`LinkSite.queryKeys`: a YouTube video's `v`, `t`
    /// and `list`), each value checked; the fragment only for a Sheets tab or a Wikipedia section (`safeAnchor`).
    /// Everything else is dropped (utm_*, fbclid, share IDs, every token). No link at all (nil) for:
    /// - a login, a search, email or chat site (`siteOnly`, message pages, a search query), a blocked site or path (`blocks`,
    ///   `blockedByDefault`) and auth pages: a path or fragment with `linkPathTokens` (callback, token, confirm, …);
    /// - a signed or secret address: any query key in `linkRefusedKeys` or starting `x-amz-`/`x-goog-` (S3 and GCS
    ///   signed URLs, OAuth `code`/`state`, `access_token`, `sig`, …);
    /// - a path part that looks like a token or secret (`tokenLike`: long random strings, JWTs, mixed-case codes, card
    ///   numbers, API keys); the resource IDs the owner named stay: a Google Docs, Sheets or Slides document ID, a
    ///   YouTube video or channel ID, an X post number, a GitHub commit;
    /// - a site's front page (the origin says it), a YouTube watch page without its video, a path over 400 bytes.
    public static func pageLink(_ url: String) -> String? {
        guard url.utf8.count <= maxURLBytes, let c = URLComponents(string: url), let scheme = c.scheme?.lowercased(),
              ["https", "http"].contains(scheme), c.user == nil, c.password == nil,
              let host = c.host?.lowercased(), !host.isEmpty, host.range(of: "^[a-z0-9-]+(\\.[a-z0-9-]+)*$", options: .regularExpression) != nil,
              !siteOnly(host: host), !blockedByDefault(host: host) else { return nil }
        var path = c.percentEncodedPath
        guard path.count > 1, path.utf8.count <= 400, !messagePath(host: host, path: c.path), !searchQuery(c),
              !blocks(path, pathTokens: pathTokens.union(linkPathTokens)) else { return nil }
        // Signed and secret addresses keep no link at all (never the path without its signature).
        let items = c.percentEncodedQueryItems ?? []
        guard !items.contains(where: { refusedKey($0.name) }) else { return nil }
        // Site rules: the resource IDs the owner named, then every other part checked as a possible token.
        let site = LinkSite(host: host)
        if site == .docs {
            guard let doc = docsPath(path) else { return nil }
            path = doc
        } else {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true).map { String($0).removingPercentEncoding ?? String($0) }
            for (i, part) in parts.enumerated() where !site.resourceID(parts, at: i) {
                if tokenLike(part) { return nil }
            }
        }
        // The query: only this site's keys, each value checked; the rest is dropped.
        let allowed = site.queryKeys(path: path)
        var kept: [URLQueryItem] = []
        for item in items where allowed.contains(item.name) && !kept.contains(where: { $0.name == item.name }) {
            if let value = item.value, site.validValue(item.name, value) { kept.append(URLQueryItem(name: item.name, value: value)) }
        }
        if site == .youtube, path.lowercased() == "/watch", !kept.contains(where: { $0.name == "v" }) { return nil }
        if site == .youtube, path.lowercased() == "/playlist", !kept.contains(where: { $0.name == "list" }) { return nil }
        // The fragment: a Sheets tab ("gid=0") or a Wikipedia section ("#History") only; a route, a text fragment
        // (#:~:text=…), a blocked word or anything else is dropped.
        var anchor: String?
        if let fragment = c.percentEncodedFragment, !fragment.isEmpty, site.keepsAnchors,
           !blocks(fragment, pathTokens: pathTokens.union(linkPathTokens)), safeAnchor(fragment, site: site, path: path) {
            anchor = fragment
        }
        var out = URLComponents()
        out.scheme = scheme; out.host = host; out.port = c.port
        out.percentEncodedPath = path
        out.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        out.percentEncodedFragment = anchor
        guard let link = out.string, link.utf8.count <= 600 else { return nil }
        return link
    }
    static let maxURLBytes = 8192
    /// page-links-1003: a page link as a row shows it beside the page's title: the site without "www." and the path,
    /// "…" in place of a query or fragment and past `shortLimit` characters ("youtube.com/watch…",
    /// "x.com/fixtureuser/status/1839…", "github.com/apple/swift/pull/418"). nil when there is no path to show.
    public static func shortLink(_ link: String) -> String? {
        guard let c = URLComponents(string: link), var host = c.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = c.path
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty else { return nil }
        var text = host + path
        var more = (c.percentEncodedQuery ?? "").isEmpty == false || (c.percentEncodedFragment ?? "").isEmpty == false
        if text.count > shortLimit { text = String(text.prefix(shortLimit)); more = true }
        return more ? text + "…" : text
    }
    public static let shortLimit = 36
    /// page-links-1003: path parts that make a page an auth or one-time page: no link is kept for it
    /// (the page row itself may still be saved, with its site). Read with `pathTokens`, through `blocks`.
    public static let linkPathTokens: Set<String> = ["callback", "callbacks", "oauth2", "token", "tokens", "magiclink",
        "confirm", "confirmation", "activate", "activation", "unsubscribe", "invite", "invitation", "invitations", "signed",
        "presigned", "sig", "signature", "logout", "signout", "unlock", "approve", "consent", "redeem"]
    /// page-links-1003: query keys that make an address signed or secret: no link at all.
    public static let linkRefusedKeys: Set<String> = ["code", "state", "token", "access_token", "id_token", "refresh_token", "auth",
        "auth_token", "authorization", "key", "apikey", "api_key", "api-key", "sig", "signature", "se", "sp", "sv", "skoid", "expires",
        "key-pair-id", "policy", "googleaccessid", "session", "sessionid", "session_id", "sid", "ticket", "otp", "nonce", "jwt",
        "password", "pwd", "secret", "client_secret", "assertion", "samlresponse", "samlrequest", "reset", "reset_token", "invite",
        "invite_code", "magic", "verification", "verify", "hmac", "credential", "credentials", "pass", "passcode", "pin"]
    static func refusedKey(_ raw: String) -> Bool {
        let name = (raw.removingPercentEncoding ?? raw).lowercased()
        return linkRefusedKeys.contains(name) || name.hasPrefix("x-amz-") || name.hasPrefix("x-goog-") || name.hasPrefix("x-ms-")
            || name.hasSuffix("_token") || name.hasSuffix("-token") || name.hasSuffix("secret")
    }
    /// A site whose resource IDs and query keys a page link keeps (page-links-1003).
    enum LinkSite: Equatable {
        case youtube, youtuBe, x, github, docs, wikipedia, other
        init(host: String) {
            if BrowserSites.matches(host: host, domain: "youtube.com") || BrowserSites.matches(host: host, domain: "youtube-nocookie.com") { self = .youtube }
            else if host == "youtu.be" { self = .youtuBe }
            else if ["x.com", "twitter.com"].contains(where: { BrowserSites.matches(host: host, domain: $0) }) { self = .x }
            else if host == "github.com" || host == "www.github.com" { self = .github }
            else if host == "docs.google.com" { self = .docs }
            else if BrowserSites.matches(host: host, domain: "wikipedia.org") { self = .wikipedia }
            else { self = .other }
        }
        /// Only a spreadsheet's tab and a Wikipedia section keep their fragment (`safeAnchor`).
        var keepsAnchors: Bool { [.docs, .wikipedia].contains(self) }
        /// The query keys this site keeps: a YouTube video, its time and its playlist; a youtu.be link's time.
        func queryKeys(path: String) -> Set<String> {
            switch self {
            case .youtube:
                switch path.lowercased() {
                case "/watch": return ["v", "t", "list"]
                case "/playlist": return ["list"]
                default: return []
                }
            case .youtuBe: return ["t"]
            default: return []
            }
        }
        func validValue(_ name: String, _ value: String) -> Bool {
            switch name {
            case "v": return value.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil
            case "t": return value.range(of: "^([0-9]{1,6}s?|([0-9]{1,2}h)?([0-9]{1,3}m)?([0-9]{1,3}s)?)$", options: .regularExpression) != nil && !value.isEmpty
            case "list": return value.range(of: "^[A-Za-z0-9_-]{2,64}$", options: .regularExpression) != nil
            default: return false
            }
        }
        /// Whether path part `i` is a resource ID this site names (never read as a token).
        func resourceID(_ parts: [String], at i: Int) -> Bool {
            let part = parts[i], previous = i > 0 ? parts[i - 1].lowercased() : ""
            switch self {
            case .youtube:
                if ["shorts", "live", "embed", "v"].contains(previous) { return part.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil }
                if previous == "channel" { return part.range(of: "^UC[A-Za-z0-9_-]{22}$", options: .regularExpression) != nil }
                return false
            case .youtuBe: return i == 0 && part.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil
            case .x:
                // "/<handle>/status/<id>" and "/i/web/status/<id>": the post's number (owner: fine as a path).
                return previous == "status" && part.range(of: "^[0-9]{1,20}$", options: .regularExpression) != nil
            case .github:
                // A commit, tree or blob at a commit: a public object name, not a secret.
                return ["commit", "tree", "blob", "commits"].contains(previous) && part.range(of: "^[0-9a-f]{7,40}$", options: .regularExpression) != nil
            case .docs, .wikipedia, .other: return false
            }
        }
    }
    /// A Google Docs, Sheets or Slides document: "/document/d/<id>/edit" (an optional "/u/<n>" account and "/edit",
    /// "/view" or "/preview" kept; anything after them dropped). nil for any other docs.google.com page.
    static func docsPath(_ path: String) -> String? {
        let pattern = "^/(document|spreadsheets|presentation)(/u/[0-9]{1,2})?/d/([A-Za-z0-9_-]{25,64})(/(edit|view|preview))?"
        guard let range = path.range(of: pattern, options: .regularExpression) else { return nil }
        let rest = path[range.upperBound...]
        guard rest.isEmpty || rest.hasPrefix("/") else { return nil }
        return String(path[range])
    }
    /// The fragments a link keeps, only where they name a part of the page: a Sheets tab ("gid=123") on a spreadsheet and
    /// a Wikipedia section ("#History", "#Early_life": a letter, then up to 63 letters, digits, "_", "-" or "." that read
    /// as words, not a code). Every other fragment is dropped (an app's route, a share or tracking ID, a text fragment).
    static func safeAnchor(_ fragment: String, site: LinkSite, path: String) -> Bool {
        switch site {
        case .docs: return path.hasPrefix("/spreadsheets/") && fragment.range(of: "^gid=[0-9]{1,12}$", options: .regularExpression) != nil
        case .wikipedia:
            guard fragment.range(of: "^[A-Za-z][A-Za-z0-9_.-]{0,63}$", options: .regularExpression) != nil else { return false }
            return !tokenLike(fragment)
        default: return false
        }
    }
    /// A path part that looks like a token or secret, read piece by piece (split at "-", "_", ".", "~", "'", "(", ")", ",",
    /// "+" and spaces, so "Mercury_(planet)" and a news slug are words): a JWT or a known key ("sk-…", "AKIA…", "ghp_…"),
    /// "name=value", a card number (13 to 19 digits passing Luhn), digits over 20, a piece of 8 or more characters mixing
    /// three of lower case, upper case, digits and symbols, 16 or more letters and digits mixed (hex IDs, session IDs),
    /// two or more pieces mixing letters and digits (a grouped code, a UUID), 32 or more letters, or a whole part of 24 or
    /// more mixed letters and digits that is not a slug of short words.
    public static func tokenLike(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return false }
        let secretPatterns = ["(?i)(password|passwd|pwd|secret|token|api[_-]?key)\\s*[:=]", "=",
                              "(sk-|sk_live_|sk_test_|pk_live_|rk_live_|ghp_|gho_|github_pat_|glpat-|xox[abprs]-|AKIA|ASIA|AIza|ya29\\.|Bearer\\s+)[A-Za-z0-9_./+-]{6,}",
                              "eyJ[A-Za-z0-9_-]+\\.", "^[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}$"]
        if secretPatterns.contains(where: { s.range(of: $0, options: .regularExpression) != nil }) { return true }
        if s.allSatisfy({ $0.isASCII && $0.isNumber }) { return s.count > 20 || ((13...19).contains(s.count) && luhn(s)) }
        // A whole part of 24 or more letters and digits (with "-" or "_") mixing both: a share key or session ID.
        if s.count >= 24, s.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
           s.rangeOfCharacter(from: .decimalDigits) != nil, s.rangeOfCharacter(from: .letters) != nil {
            // A slug of words and short numbers ("how-lighthouse-lenses-work-2024") is not one.
            // Model numbers in a slug ("h1b", "m4") are short; a code's pieces are long or many.
            let words = s.split(whereSeparator: { $0 == "-" || $0 == "_" })
            let mixed = words.filter { w in w.contains(where: \.isNumber) && w.contains(where: \.isLetter) }
            if words.count < 3 || words.contains(where: { $0.count > 12 }) || mixed.count > 1 || mixed.contains(where: { $0.count > 6 }) { return true }
        }
        let pieces = s.split(whereSeparator: { "-_.~'(),+ ".contains($0) }).map(String.init)
        // A code in groups ("a8F3-kd92-LsP0", a UUID): two or more pieces mixing letters and digits.
        if s.count >= 12, pieces.filter({ p in p.contains(where: { $0.isASCII && $0.isNumber }) && p.contains(where: \.isLetter) }).count >= 2 { return true }
        for p in pieces {
            let digits = p.contains(where: { $0.isASCII && $0.isNumber }), letters = p.contains(where: \.isLetter)
            if digits, !letters { if p.count > 20 || ((13...19).contains(p.count) && luhn(p)) { return true }; continue }
            if letters, !digits, p.allSatisfy(\.isLetter) { if p.count >= 32 { return true }; continue }
            let classes = [p.contains(where: \.isLowercase), p.contains(where: \.isUppercase), digits,
                           p.contains(where: { !$0.isLetter && !$0.isNumber })].filter { $0 }.count
            if p.count >= 8 && classes >= 3 { return true }
            if p.count >= 16 && digits && letters { return true }
        }
        return false
    }
    static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard var d = ch.wholeNumberValue else { return false }
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }
    static func messagePath(host: String, path: String) -> Bool {
        let lower = path.lowercased()
        return siteOnlyPaths.contains { rule in
            matches(host: host, domain: rule.host) && (lower == rule.path || lower.hasPrefix(rule.path + "/"))
        }
    }
    static func searchQuery(_ c: URLComponents) -> Bool {
        // page-links-1003: X's share links carry "?s=20&t=<share id>" on a post (a share source, never search words);
        // X searches are "/search?q=".
        let x = c.host.map { h in ["x.com", "twitter.com"].contains { matches(host: h.lowercased(), domain: $0) } } ?? false
        return (c.percentEncodedQueryItems ?? []).contains { item in
            let name = item.name.lowercased()
            return searchParameters.contains(name) && !(item.value ?? "").isEmpty && !(x && ["s", "t"].contains(name))
        }
    }
}
