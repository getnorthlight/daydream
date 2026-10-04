import AppKit
@testable import MemoryUI

/// Website icons (owner 10/3: YouTube and other popular sites drew a letter tile in the Today cards, the
/// "Windows and pages" panel and the details page). Pure checks: the host table, its normalisation, the bundled
/// PNGs and their provenance, and source pins that nothing is fetched. No app, window, network or owner data.
@main @MainActor enum SiteIconChecks {
    static var checks = 0
    static var failures = 0
    static func require(_ ok: Bool, _ reason: String, _ got: @autoclosure () -> String = "") {
        checks += 1
        if !ok { failures += 1; FileHandle.standardError.write(Data("FAIL: \(reason) \(got())\n".utf8)) }
    }
    static func icon(_ site: String, _ expected: String?) {
        let got = SiteIconCatalog.iconName(site)
        require(got == expected, "\(site) → \(expected ?? "letter tile")", "got \(got ?? "nil")")
    }
    static func source(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
    static let iconDir = "Sources/MemoryUI/Resources/SiteIcons"

    static func main() {
        ownerReportedSites()
        popularSites()
        normalisation()
        unknownSitesKeepTheLetterTile()
        bundledFiles()
        noFetching()
        bundleLoading()
        guard failures == 0 else { print("site-icon: \(checks - failures) passed, \(failures) failed"); exit(1) }
        print("PASS: site-icon \(checks) checks; host table, bundled PNGs and source pins only, no windows or network")
    }

    /// The owner's screenshot and the audit of 10/3: these drew no icon.
    static func ownerReportedSites() {
        for s in ["youtube.com", "www.youtube.com", "m.youtube.com", "https://www.youtube.com/", "https://www.youtube.com/watch?v=abc",
                  "youtu.be", "YOUTUBE.COM", "youtube.com.", "youtube.com:443"] { icon(s, "youtube") }
        icon("music.youtube.com", "youtube-music")
        for s in ["reddit.com", "www.reddit.com", "old.reddit.com", "new.reddit.com", "https://www.reddit.com/r/swift/", "redd.it"] { icon(s, "reddit") }
        for s in ["outlook.cloud.microsoft", "https://outlook.cloud.microsoft/mail/", "outlook.live.com", "outlook.office.com",
                  "outlook.office365.com", "outlook.com"] { icon(s, "outlook") }
        for s in ["microsoft.com", "www.microsoft.com", "learn.microsoft.com", "support.microsoft.com"] { icon(s, "microsoft") }
    }

    static func popularSites() {
        let table: [(String, String)] = [
            ("google.com", "google"), ("www.google.com", "google"), ("accounts.google.com", "google"), ("google.co.uk", "google"),
            ("www.google.de", "google"), ("google.com.au", "google"), ("mail.google.com", "gmail"), ("gmail.com", "gmail"),
            ("docs.google.com", "google-docs"), ("https://docs.google.com/document/d/x/edit", "google-docs"),
            ("https://docs.google.com/spreadsheets/d/x/edit", "google-sheets"), ("https://docs.google.com/presentation/d/x", "google-slides"),
            ("https://docs.google.com/forms/d/x", "google-forms"), ("drive.google.com", "google-drive"),
            ("calendar.google.com", "google-calendar"), ("meet.google.com", "google-meet"), ("https://www.google.com/maps/place/x", "google-maps"),
            ("classroom.google.com", "google-classroom"), ("gemini.google.com", "gemini"), ("notebooklm.google.com", "notebooklm"),
            ("x.com", "x"), ("twitter.com", "x"), ("mobile.twitter.com", "x"), ("github.com", "github"), ("gist.github.com", "github"),
            ("chatgpt.com", "chatgpt"), ("chat.openai.com", "chatgpt"), ("claude.ai", "claude"), ("perplexity.ai", "perplexity"),
            ("www.perplexity.ai", "perplexity"), ("copilot.microsoft.com", "copilot"), ("linkedin.com", "linkedin"),
            ("instagram.com", "instagram"), ("facebook.com", "facebook"), ("m.facebook.com", "facebook"), ("tiktok.com", "tiktok"),
            ("netflix.com", "netflix"), ("amazon.com", "amazon"), ("smile.amazon.com", "amazon"), ("amazon.co.uk", "amazon"),
            ("amazon.de", "amazon"), ("aws.amazon.com", "aws"), ("en.wikipedia.org", "wikipedia"), ("en.m.wikipedia.org", "wikipedia"),
            ("stackoverflow.com", "stackoverflow"), ("notion.so", "notion"), ("www.notion.so", "notion"), ("figma.com", "figma"),
            ("app.slack.com", "slack"), ("acme.slack.com", "slack"), ("discord.com", "discord"), ("open.spotify.com", "spotify"),
            ("twitch.tv", "twitch"), ("apple.com", "apple"), ("developer.apple.com", "apple"), ("music.apple.com", "apple-music"),
            ("icloud.com", "icloud"), ("yahoo.com", "yahoo"), ("mail.yahoo.com", "yahoo"), ("uk.yahoo.com", "yahoo"), ("bing.com", "bing"),
            ("canvas.instructure.com", "canvas"), ("school.instructure.com", "canvas"), ("nytimes.com", "nytimes"), ("bbc.co.uk", "bbc"),
            ("www.bbc.co.uk", "bbc"), ("cnn.com", "cnn"), ("edition.cnn.com", "cnn"), ("amp.theguardian.com", "guardian"),
            ("news.ycombinator.com", "hackernews"), ("web.whatsapp.com", "whatsapp"), ("teams.microsoft.com", "teams"),
            ("onedrive.live.com", "onedrive"), ("contoso.sharepoint.com", "sharepoint"), ("acme.atlassian.net", "atlassian"),
            ("console.aws.amazon.com", "aws"), ("cursor.com", "cursor"),
        ]
        for (site, expected) in table { icon(site, expected) }
        require(SiteIconCatalog.allIconNames.count >= 150, "at least 150 distinct popular-site icons", "\(SiteIconCatalog.allIconNames.count)")
        // Every listed host resolves to its own row (no row is shadowed by normalisation).
        for host in SiteIconCatalog.allHosts {
            require(SiteIconCatalog.iconName(host) == SiteIconCatalog.hostIcons[host], "listed host \(host) resolves to its own icon",
                    SiteIconCatalog.iconName(host) ?? "nil")
        }
    }

    static func normalisation() {
        let cases: [(String, String, String)] = [
            ("HTTPS://WWW.YouTube.com:443/watch?v=1#t", "youtube.com", "/watch"), ("m.youtube.com/", "youtube.com", "/"),
            ("en.m.wikipedia.org", "en.wikipedia.org", ""), ("mail.google.co.uk", "mail.google.com", ""),
            ("user:pw@github.com/x", "github.com", "/x"), ("reddit.com.", "reddit.com", ""), ("  x.com  ", "x.com", ""),
            ("www.bbc.co.uk", "bbc.co.uk", ""), ("m.me", "m.me", ""), ("localhost:3000", "localhost", ""),
            ("//cdn.example.org/a", "cdn.example.org", "/a"), ("web.telegram.org", "telegram.org", ""),
        ]
        for (raw, host, path) in cases {
            let n = SiteIconCatalog.normalize(raw)
            require(n.host == host && n.path == path, "normalize \(raw)", "\(n.host) \(n.path)")
        }
        // The old exact-host map still holds (owner 9/30 X and Instagram, Google).
        require(KitSiteFavicons.resourceName("https://x.com/home") == "x", "KitSiteFavicons still resolves X")
        require(KitSiteFavicons.resourceName("www.instagram.com") == "instagram", "KitSiteFavicons still resolves Instagram")
        require(KitSiteFavicons.resourceName("www.youtube.com") == "youtube", "KitSiteFavicons resolves YouTube through the catalog")
    }

    static func unknownSitesKeepTheLetterTile() {
        for s in ["example.org", "fakeyoutube.com", "youtube.com.evil.net", "reddit.co", "localhost", "192.168.1.10", "", "   ",
                  "my-school.edu", "notgithub.io"] {
            icon(s, nil)
        }
        require(WebMonogramTile.monogramLetter("example.org") == "E", "an unknown site keeps its letter (E)")
        require(WebMonogramTile.monogramLetter("my-school.edu") == "M", "an unknown site keeps its letter (M)")
        let tile = source("Sources/MemoryUI/DaydreamKitIcons.swift")
        require(tile.contains("GridMonogram(name: KitBrowsers.siteName(domain), size: size)"), "WebMonogramTile falls back to the letter tile")
    }

    static func bundledFiles() {
        let fm = FileManager.default
        let pngs = Set(((try? fm.contentsOfDirectory(atPath: iconDir)) ?? []).filter { $0.hasSuffix(".png") }.map { String($0.dropLast(4)) })
        for name in SiteIconCatalog.allIconNames.sorted() {
            require(pngs.contains(name), "bundled PNG for \(name)")
        }
        let connectionOnly: Set<String> = ["claude-code"]
        for name in pngs.subtracting(SiteIconCatalog.allIconNames).subtracting(connectionOnly).sorted() {
            require(false, "no unreferenced site icon", name)
        }
        for name in pngs.sorted() {
            guard let image = NSImage(contentsOfFile: "\(iconDir)/\(name).png"),
                  let rep = image.representations.first as? NSBitmapImageRep else { require(false, "\(name).png decodes"); continue }
            require(rep.pixelsWide >= 16 && rep.pixelsHigh >= 16, "\(name).png is at least 16 px", "\(rep.pixelsWide)")
            require(rep.pixelsWide <= 256 && rep.pixelsHigh <= 256, "\(name).png is at most 256 px", "\(rep.pixelsWide)")
        }
        // Provenance: every bundled site icon is recorded with its source URL and hash.
        let rows = source("tools/site-icons/sources.tsv").split(separator: "\n").filter { !$0.hasPrefix("#") }
        let recorded = Set(rows.map { String($0.split(separator: "\t")[0]) })
        for name in SiteIconCatalog.allIconNames.sorted() {
            require(recorded.contains(name), "sources.tsv records \(name)")
        }
        let size = pngs.reduce(0) { $0 + (((try? fm.attributesOfItem(atPath: "\(iconDir)/\($1).png"))?[.size] as? Int) ?? 0) }
        require(size < 3_000_000, "bundled site icons stay small", "\(size) bytes")
        // The release audit allows every bundled icon (and only PNGs in SiteIcons).
        let release = source("scripts/release.py")
        require(release.contains("MacMem_MemoryUI.bundle/SiteIcons/"), "release audit names the SiteIcons folder")
    }

    /// When run next to a built `MacMem_MemoryUI.bundle` (copy the binary into the build's debug folder), every
    /// table icon loads from the bundle; otherwise this section is skipped and says so.
    static func bundleLoading() {
        guard SiteIconCatalog.resourceBundle != nil else { print("note: no MacMem_MemoryUI.bundle beside this binary; bundle loading skipped"); return }
        for name in SiteIconCatalog.allIconNames.sorted() {
            require(SiteIconCatalog.image(named: name) != nil, "\(name) loads from the built bundle")
        }
        for site in ["https://www.youtube.com/", "old.reddit.com", "outlook.cloud.microsoft", "www.microsoft.com"] {
            require(SiteIconCatalog.image(forSite: site) != nil, "\(site) draws a bundled icon")
        }
        require(SiteIconCatalog.image(forSite: "example.org") == nil, "an unknown site loads no icon")
    }

    /// Privacy rule: drawing a page's icon never requests anything. No favicon service, no URL loading.
    static func noFetching() {
        let catalog = source("Sources/MemoryUI/SiteIconCatalog.swift")
        let kit = source("Sources/MemoryUI/DaydreamKitIcons.swift")
        for (name, text) in [("SiteIconCatalog", catalog), ("DaydreamKitIcons", kit)] {
            for banned in ["URLSession", "URLRequest", "s2/favicons", "favicon.ico", "Data(contentsOf: URL(string", "WKWebView",
                           "google.com/s2", "icons.duckduckgo", "icon.horse", "favicone", "clearbit"] {
                require(!text.contains(banned), "\(name) makes no favicon request (\(banned))")
            }
        }
        require(catalog.contains("forResource: name, withExtension: \"png\", subdirectory: \"SiteIcons\""),
                "icons load only from the app's own bundle")
    }
}
