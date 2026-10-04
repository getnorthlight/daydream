import AppKit

/// Which bundled website icon a recorded page draws (owner 10/3: "every popular site should have its real icon").
///
/// The icons are the sites' own declared favicons, bundled once in `Resources/SiteIcons` (provenance in
/// `tools/site-icons/sources.tsv`). Matching is pure string work on the recorded host: nothing is fetched, no
/// visited domain leaves this Mac. A site that is not in the table keeps its letter tile (`GridMonogram`).
public enum SiteIconCatalog {
    /// One row: a host (matched exactly or as a parent domain), an optional path prefix, the icon's resource name.
    public struct Rule: Equatable {
        public let host: String
        public let path: String?
        public let icon: String
    }

    /// Host-only rows: `"youtube.com": "youtube"` matches youtube.com and every subdomain of it.
    /// The most specific host wins (`music.youtube.com` → youtube-music before `youtube.com` → youtube).
    static let hostIcons: [String: String] = [
        // Google and its products. Country domains (google.co.uk, …) are folded to .com first.
        "google.com": "google", "mail.google.com": "gmail", "gmail.com": "gmail", "inbox.google.com": "gmail",
        "docs.google.com": "google-docs", "sheets.google.com": "google-sheets", "slides.google.com": "google-slides",
        "forms.google.com": "google-forms", "forms.gle": "google-forms", "drive.google.com": "google-drive",
        "calendar.google.com": "google-calendar", "meet.google.com": "google-meet", "maps.google.com": "google-maps",
        "maps.app.goo.gl": "google-maps", "photos.google.com": "google-photos", "classroom.google.com": "google-classroom",
        "keep.google.com": "google-keep", "translate.google.com": "google-translate", "news.google.com": "google-news",
        "gemini.google.com": "gemini", "bard.google.com": "gemini", "aistudio.google.com": "gemini",
        "notebooklm.google.com": "notebooklm", "notebooklm.google": "notebooklm", "colab.research.google.com": "colab",
        "firebase.google.com": "firebase", "console.firebase.google.com": "firebase", "firebase.com": "firebase",
        "youtube.com": "youtube", "youtu.be": "youtube", "youtube-nocookie.com": "youtube", "music.youtube.com": "youtube-music",
        // AI.
        "chatgpt.com": "chatgpt", "chat.openai.com": "chatgpt", "openai.com": "openai", "platform.openai.com": "openai",
        "claude.ai": "claude", "claude.com": "claude", "anthropic.com": "anthropic", "console.anthropic.com": "anthropic",
        "perplexity.ai": "perplexity", "copilot.microsoft.com": "copilot", "copilot.cloud.microsoft": "copilot",
        "grok.com": "grok", "x.ai": "grok", "mistral.ai": "mistral", "chat.mistral.ai": "mistral",
        "deepseek.com": "deepseek", "chat.deepseek.com": "deepseek", "poe.com": "poe", "character.ai": "characterai",
        "huggingface.co": "huggingface", "meta.ai": "meta-ai",
        // Microsoft.
        "microsoft.com": "microsoft", "outlook.com": "outlook", "outlook.live.com": "outlook", "outlook.office.com": "outlook",
        "outlook.office365.com": "outlook", "outlook.cloud.microsoft": "outlook", "hotmail.com": "outlook", "live.com": "outlook",
        "office.com": "microsoft365", "microsoft365.com": "microsoft365", "m365.cloud.microsoft": "microsoft365",
        "cloud.microsoft": "microsoft365", "office365.com": "microsoft365",
        "onedrive.live.com": "onedrive", "onedrive.com": "onedrive", "1drv.ms": "onedrive", "sharepoint.com": "sharepoint",
        "teams.microsoft.com": "teams", "teams.live.com": "teams", "teams.cloud.microsoft": "teams",
        "bing.com": "bing", "azure.com": "azure", "azure.microsoft.com": "azure", "portal.azure.com": "azure",
        // Social and messaging.
        "x.com": "x", "twitter.com": "x", "t.co": "x", "reddit.com": "reddit", "redd.it": "reddit", "redditmedia.com": "reddit",
        "linkedin.com": "linkedin", "lnkd.in": "linkedin", "instagram.com": "instagram", "facebook.com": "facebook",
        "fb.com": "facebook", "fb.watch": "facebook", "whatsapp.com": "whatsapp",
        "threads.net": "threads", "threads.com": "threads", "tiktok.com": "tiktok", "snapchat.com": "snapchat",
        "pinterest.com": "pinterest", "pin.it": "pinterest", "tumblr.com": "tumblr", "bsky.app": "bluesky",
        "mastodon.social": "mastodon", "discord.com": "discord", "discord.gg": "discord", "discordapp.com": "discord",
        "slack.com": "slack", "telegram.org": "telegram", "t.me": "telegram", "zoom.us": "zoom", "zoom.com": "zoom",
        "quora.com": "quora",
        // Video, music.
        "netflix.com": "netflix", "hulu.com": "hulu", "disneyplus.com": "disneyplus", "max.com": "max", "hbomax.com": "max",
        "primevideo.com": "primevideo", "spotify.com": "spotify", "twitch.tv": "twitch", "soundcloud.com": "soundcloud",
        "imdb.com": "imdb",
        // Apple.
        "apple.com": "apple", "icloud.com": "icloud", "music.apple.com": "apple-music",
        // Shopping, travel, money, everyday.
        "amazon.com": "amazon", "amzn.to": "amazon", "a.co": "amazon", "aws.amazon.com": "aws",
        "console.aws.amazon.com": "aws", "amazonaws.com": "aws", "ebay.com": "ebay", "etsy.com": "etsy",
        "walmart.com": "walmart", "target.com": "target", "bestbuy.com": "bestbuy", "costco.com": "costco",
        "aliexpress.com": "aliexpress", "aliexpress.us": "aliexpress", "temu.com": "temu", "shopify.com": "shopify",
        "myshopify.com": "shopify", "ikea.com": "ikea", "airbnb.com": "airbnb", "booking.com": "booking",
        "expedia.com": "expedia", "tripadvisor.com": "tripadvisor", "yelp.com": "yelp", "uber.com": "uber",
        "instacart.com": "instacart", "craigslist.org": "craigslist", "zillow.com": "zillow", "indeed.com": "indeed",
        "glassdoor.com": "glassdoor", "weather.com": "weather", "archive.org": "archive",
        "paypal.com": "paypal", "venmo.com": "venmo", "chase.com": "chase", "bankofamerica.com": "bankofamerica",
        "wellsfargo.com": "wellsfargo", "capitalone.com": "capitalone", "americanexpress.com": "amex",
        "robinhood.com": "robinhood", "coinbase.com": "coinbase", "fidelity.com": "fidelity", "schwab.com": "schwab",
        // Reference, search, mail.
        "wikipedia.org": "wikipedia", "stackoverflow.com": "stackoverflow", "stackexchange.com": "stackexchange",
        "superuser.com": "stackexchange", "serverfault.com": "stackexchange", "askubuntu.com": "stackexchange",
        "yahoo.com": "yahoo", "duckduckgo.com": "duckduckgo", "proton.me": "proton", "protonmail.com": "proton",
        // Work.
        "notion.so": "notion", "notion.com": "notion", "notion.site": "notion", "figma.com": "figma", "canva.com": "canva",
        "miro.com": "miro", "trello.com": "trello", "asana.com": "asana", "linear.app": "linear",
        "atlassian.com": "atlassian", "atlassian.net": "atlassian", "monday.com": "monday", "clickup.com": "clickup",
        "airtable.com": "airtable", "dropbox.com": "dropbox", "box.com": "box", "grammarly.com": "grammarly",
        // School.
        "instructure.com": "canvas", "canvaslms.com": "canvas", "blackboard.com": "blackboard",
        "brightspace.com": "brightspace", "d2l.com": "brightspace", "moodle.org": "moodle", "moodlecloud.com": "moodle",
        "khanacademy.org": "khanacademy", "quizlet.com": "quizlet", "coursera.org": "coursera", "edx.org": "edx",
        "duolingo.com": "duolingo", "chegg.com": "chegg", "desmos.com": "desmos", "overleaf.com": "overleaf",
        // News.
        "nytimes.com": "nytimes", "nyti.ms": "nytimes", "wsj.com": "wsj", "washingtonpost.com": "washingtonpost",
        "cnn.com": "cnn", "bbc.com": "bbc", "bbc.co.uk": "bbc", "theguardian.com": "guardian", "reuters.com": "reuters",
        "apnews.com": "apnews", "bloomberg.com": "bloomberg", "npr.org": "npr", "foxnews.com": "foxnews",
        "nbcnews.com": "nbcnews", "cnbc.com": "cnbc", "forbes.com": "forbes", "theverge.com": "theverge",
        "techcrunch.com": "techcrunch", "wired.com": "wired", "arstechnica.com": "arstechnica",
        "theatlantic.com": "theatlantic", "axios.com": "axios", "politico.com": "politico", "usatoday.com": "usatoday",
        "economist.com": "economist", "ft.com": "ft", "businessinsider.com": "businessinsider", "espn.com": "espn",
        "news.ycombinator.com": "hackernews", "substack.com": "substack",
        // Developers.
        "github.com": "github", "githubusercontent.com": "github", "gitlab.com": "gitlab", "vercel.com": "vercel",
        "netlify.com": "netlify", "netlify.app": "netlify", "cloudflare.com": "cloudflare", "pypi.org": "pypi",
        "python.org": "python", "developer.mozilla.org": "mdn", "kaggle.com": "kaggle", "replit.com": "replit",
        "leetcode.com": "leetcode", "docker.com": "docker", "stripe.com": "stripe", "supabase.com": "supabase",
        "supabase.co": "supabase", "cursor.com": "cursor", "cursor.sh": "cursor",
    ]

    /// Path-specific rows, checked before the host-only ones: one host serving several products.
    static let pathRules: [Rule] = [
        Rule(host: "docs.google.com", path: "/spreadsheets", icon: "google-sheets"),
        Rule(host: "docs.google.com", path: "/presentation", icon: "google-slides"),
        Rule(host: "docs.google.com", path: "/forms", icon: "google-forms"),
        Rule(host: "google.com", path: "/maps", icon: "google-maps"),
    ]

    /// Brands whose sites live under many country domains: `google.co.uk`, `amazon.de`, `uk.yahoo.com` → `.com`.
    private static let countryBrands: Set<String> = ["google", "amazon", "ebay", "yahoo", "ikea", "booking", "bing", "tripadvisor", "expedia"]

    /// Leading labels that are only a mobile, AMP or web prefix of the same site.
    private static let aliasLabels: Set<String> = ["www", "www1", "www2", "www3", "m", "mobile", "amp", "web", "touch"]

    /// "HTTPS://WWW.YouTube.com:443/watch?v=1" → ("youtube.com", "/watch"); "m.youtube.com/" → ("youtube.com", "/");
    /// "en.m.wikipedia.org" → ("en.wikipedia.org", ""); "mail.google.co.uk" → ("mail.google.com", "").
    /// Scheme, credentials, port, query, fragment, case and a trailing dot are dropped.
    public static func normalize(_ raw: String) -> (host: String, path: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        else if s.hasPrefix("//") { s.removeFirst(2) }
        var path = ""
        if let cut = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            let rest = String(s[cut...])
            s = String(s[..<cut])
            if rest.hasPrefix("/") { path = String(rest.prefix { $0 != "?" && $0 != "#" }) }
        }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if s.hasPrefix("[") { return (s, path) }  // IPv6 literal
        if let colon = s.lastIndex(of: ":"), s[s.index(after: colon)...].allSatisfy(\.isNumber) { s = String(s[..<colon]) }
        while s.hasSuffix(".") { s.removeLast() }
        var labels = s.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
        // Drop alias labels anywhere before the registrable domain (`m.youtube.com`, `en.m.wikipedia.org`).
        var i = 0
        while i < labels.count - 2 {
            if aliasLabels.contains(labels[i]) { labels.remove(at: i) } else { i += 1 }
        }
        let host = labels.joined(separator: ".")
        return (foldCountry(host), path)
    }

    /// `google.co.uk` → `google.com`, `uk.yahoo.com` → `yahoo.com`, `amazon.de` → `amazon.com`; others unchanged.
    private static func foldCountry(_ host: String) -> String {
        let name = KitBrowsers.siteName(host)
        guard countryBrands.contains(name) else { return host }
        let labels = host.split(separator: ".").map(String.init)
        guard let at = labels.lastIndex(of: name) else { return host }
        var prefix = Array(labels[..<at])
        // `uk.yahoo.com`, `de.yahoo.com`: a two-letter country edition is the same site.
        if prefix.count == 1, prefix[0].count == 2, name == "yahoo" { prefix = [] }
        return (prefix + [name, "com"]).joined(separator: ".")
    }

    /// The bundled icon's resource name for a recorded site (a host, origin or URL), nil for a site not in the table.
    public static func iconName(_ site: String) -> String? {
        let (host, path) = normalize(site)
        guard !host.isEmpty else { return nil }
        var best: (length: Int, icon: String)?
        for rule in pathRules where matches(host, rule.host) {
            if let p = rule.path, path == p || path.hasPrefix(p + "/"), rule.host.count > (best?.length ?? -1) {
                best = (rule.host.count, rule.icon)
            }
        }
        if let best { return best.icon }
        // The most specific listed host first: `music.youtube.com`, then `youtube.com`.
        var labels = host.split(separator: ".")
        while labels.count >= 2 {
            if let icon = hostIcons[labels.joined(separator: ".")] { return icon }
            labels.removeFirst()
        }
        return nil
    }

    private static func matches(_ host: String, _ base: String) -> Bool { host == base || host.hasSuffix("." + base) }

    /// Every icon the table names (each must be a bundled PNG; the checks hold the two in step).
    public static var allIconNames: Set<String> {
        Set(hostIcons.values).union(pathRules.map(\.icon))
    }
    /// Every host the table names, for the checks.
    public static var allHosts: [String] { Array(hostIcons.keys) }

    // MARK: Loading

    static let bundleName = "MacMem_MemoryUI"
    static var resourceBundle: Bundle? {
        let bases = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        for base in bases {
            if let bundle = Bundle(url: base.appendingPathComponent(bundleName + ".bundle")) { return bundle }
        }
        return nil
    }
    /// Loaded lazily, once per icon (a few KB each), and kept: a site that misses is remembered too.
    @MainActor private static var cache: [String: NSImage?] = [:]
    @MainActor public static func image(named name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        let image = resourceBundle?.url(forResource: name, withExtension: "png", subdirectory: "SiteIcons").flatMap(NSImage.init(contentsOf:))
        cache[name] = image
        return image
    }
    /// The bundled icon for a recorded site, nil when it has none (the caller draws the letter tile).
    @MainActor public static func image(forSite site: String) -> NSImage? {
        iconName(site).flatMap(image(named:))
    }
}
