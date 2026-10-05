import Foundation
import CryptoKit
import PrivacyPolicy

// agent-tools v2, WP-B (plan §5.2): what one action is about, parsed at read time from the action's own app, site,
// title, tool and typed-unit facts. Nothing is stored and no table is read; the same action always gives the same
// entity. Typed words are never an input.
//
//   Google Docs/Sheets/Slides/Forms/Drive, form sites, form titles  -> .document (kind .form for forms)
//   Google (and the other engines in SearchPage)                      -> .webSearch, the words from the title or address
//   claude.ai, chatgpt.com, gemini … and the Claude/ChatGPT apps     -> .aiChat (content: the typed prompts, later)
//   Messages (window title or the typed unit's own recipient), DMs    -> .person
//   Mail and webmail                                                  -> .email (a mailbox view has no subject)
//   Terminal apps                                                     -> .terminal; user@host, IPs, ssh hosts -> host-xxxx
//   X, YouTube home, Reddit, LinkedIn feed, HN front page …          -> .feed (one reading line per site)
//   Finder                                                            -> .app("Finder", folder)
//   any other page                                                    -> .page
//   anything else                                                     -> .app; system UI and DayDream flagged lowValue
extension AgentEntities {
    public static func entity(_ action: CanonicalAction, unit: TypedUnitProvenance?) -> AgentEntity {
        let app = action.app.trimmingCharacters(in: .whitespacesAndNewlines)
        let appLower = app.lowercased()
        let bundle = action.bundle
        let title = cleanTitle(action.title)
        if DaydreamIdentity.ownBundleIDs.contains(bundle) || ownAppNames.contains(appLower) {
            let t = AgentTitles.normalized(title, app: app, site: "")
            return .app(name: "DayDream", title: t.isEmpty || t.lowercased() == "daydream" ? "DayDream" : t, lowValue: true)
        }
        // A typed row's own code-read recipient names who it went to, before any window or site.
        if action.kind == "keyboard.text_input", let name = typedRecipient(action, unit: unit) { return .person(name: name) }
        var host = TitleClean.hostName(action.site)
        if host.isEmpty, isBrowser(app: appLower, bundle: bundle) { host = inferredHost(title) ?? "" }
        if !host.isEmpty { return web(action, host: host, title: title, unit: unit) }
        return native(action, app: app, title: title, unit: unit)
    }

    /// The name an item is called by: what a person would say ("Q3 plan", "red boots", "Sam", "harborline").
    public static func name(_ entity: AgentEntity) -> String {
        switch entity {
        case .document(_, let name): return name
        case .webSearch(let engine, let query): return query ?? engine
        case .aiChat(let app, let title): return title ?? app
        case .person(let name): return name
        case .email(let subject): return subject ?? "Email"
        case .terminal(let tool, let project, _): return project ?? tool ?? "Terminal"
        case .feed(let site): return site
        case .page(let title, _): return title
        case .app(let name, let title, _): return title.isEmpty ? name : title
        }
    }

    /// The stable alias a terminal shows instead of a host name or address: `host-` and 4 base32 characters of its hash.
    /// The same host is always the same alias; the alias never contains the host.
    public static func hostAlias(_ host: String) -> String {
        let digest = Array(SHA256.hash(data: Data(("daydream-host\n" + host.lowercased()).utf8)))
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var bits = 0, value = 0, out = ""
        for byte in digest where out.count < 4 {
            value = (value << 8) | Int(byte); bits += 8
            while bits >= 5 && out.count < 4 { bits -= 5; out.append(alphabet[(value >> bits) & 31]) }
            value &= (1 << bits) - 1
        }
        return "host-" + out
    }

    // MARK: - Tables

    static let ownAppNames: Set<String> = ["daydream", "mac mem", "macmem", "mac-mem"]
    static let browserBundles: Set<String> = ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
                                              "com.apple.Safari", "com.apple.SafariTechnologyPreview", "company.thebrowser.Browser",
                                              "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera",
                                              "com.vivaldi.Vivaldi", "org.chromium.Chromium"]
    static let browserApps: Set<String> = ["google chrome", "chrome", "safari", "arc", "firefox", "microsoft edge", "brave browser", "opera",
                                           "vivaldi", "chromium", "google chrome beta", "google chrome canary"]
    static let aiHosts: [(domain: String, app: String)] = [
        ("claude.ai", "Claude"), ("chatgpt.com", "ChatGPT"), ("chat.openai.com", "ChatGPT"), ("gemini.google.com", "Gemini"),
        ("aistudio.google.com", "Gemini"), ("copilot.microsoft.com", "Copilot"), ("copilot.cloud.microsoft", "Copilot"),
        ("perplexity.ai", "Perplexity"), ("poe.com", "Poe"), ("chat.mistral.ai", "Mistral"), ("meta.ai", "Meta AI"), ("grok.com", "Grok"),
        ("chat.deepseek.com", "DeepSeek"), ("chat.qwen.ai", "Qwen"), ("pi.ai", "Pi"), ("character.ai", "Character.AI"), ("you.com", "You.com")]
    static let aiBundles: [String: String] = ["com.anthropic.claudefordesktop": "Claude", "com.openai.chat": "ChatGPT", "com.openai.codex": "Codex",
                                              "ai.perplexity.mac": "Perplexity"]
    static let aiAppNames: [String: String] = ["claude": "Claude", "chatgpt": "ChatGPT", "codex": "Codex", "perplexity": "Perplexity"]
    static let docSuffixes: [(suffix: String, kind: AgentEntity.DocumentKind)] = [
        ("google docs", .doc), ("google sheets", .sheet), ("google slides", .slides), ("google forms", .form), ("google drive", .drive)]
    static let formHosts = ["typeform.com", "jotform.com", "tally.so", "forms.office.com", "forms.microsoft.com", "surveymonkey.com",
                            "formstack.com", "cognitoforms.com", "wufoo.com", "paperform.co", "fillout.com", "forms.gle"]
    /// A page title that names a form or an application ("Studio residency application", "Apply now", "Registration").
    static let formTitle = #"\b(apply|application form|registration|survey|questionnaire|form)\b|\b(job|grant|residency|scholarship|visa|rental|loan|membership|college|admissions?|internship|fellowship|program|housing|permit)\s+application\b|\bapplication\s+(for|portal)\b|^application\b"#
    static let feedHosts: [(domain: String, name: String)] = [
        ("x.com", "X"), ("twitter.com", "X"), ("youtube.com", "YouTube"), ("reddit.com", "Reddit"), ("linkedin.com", "LinkedIn"),
        ("news.ycombinator.com", "Hacker News"), ("instagram.com", "Instagram"), ("facebook.com", "Facebook"), ("tiktok.com", "TikTok"),
        ("bsky.app", "Bluesky"), ("threads.net", "Threads"), ("threads.com", "Threads"), ("mastodon.social", "Mastodon")]
    /// Feed sites whose titled pages are a post or a video (a page); the rest are a feed whatever the title.
    static let feedHomeTitles: [String: Set<String>] = [
        "YouTube": ["", "youtube", "home", "subscriptions", "shorts", "history", "watch later", "trending", "explore", "library", "you"],
        "Reddit": ["", "reddit", "home", "popular", "all", "reddit - dive into anything", "dive into anything", "reddit - the heart of the internet"],
        "LinkedIn": ["", "linkedin", "feed", "notifications", "my network", "jobs", "messaging"],
        "Hacker News": ["", "hacker news", "new links", "ask", "show", "jobs", "comments", "past", "ask hn", "show hn"]]
    static let mailApps: Set<String> = ["mail", "outlook", "microsoft outlook", "spark", "spark desktop", "superhuman", "mimestream", "airmail", "canary mail"]
    static let mailBundles: Set<String> = ["com.apple.mail", "com.microsoft.Outlook"]
    static let terminalBundles: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
                                               "io.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm", "co.zeit.hyper"]
    static let systemApps: Set<String> = ["system settings", "system preferences", "loginwindow", "spotlight", "control center", "notification center",
                                          "notificationcenter", "dock", "windowmanager", "window server", "screenshot", "securityagent",
                                          "coreservicesuiagent", "usernotificationcenter", "universalaccessauthwarn", "activity monitor",
                                          "archive utility", "installer", "software update", "launchpad", "mission control", "screen time"]
    static let systemBundles: Set<String> = ["com.apple.systempreferences", "com.apple.loginwindow", "com.apple.Spotlight", "com.apple.controlcenter",
                                             "com.apple.notificationcenterui", "com.apple.dock", "com.apple.WindowManager", "com.apple.screenshot.launcher",
                                             "com.apple.SecurityAgent", "com.apple.ActivityMonitor"]
    /// Finder views that are places, not a folder someone works in.
    static let finderViews: Set<String> = ["", "finder", "recents", "desktop", "downloads", "documents", "applications", "airdrop", "icloud drive",
                                           "trash", "home", "network", "computer", "shared", "tags", "macintosh hd"]
    static let officeApps: [String: AgentEntity.DocumentKind] = [
        "pages": .pages, "microsoft word": .word, "word": .word, "textedit": .textedit, "numbers": .numbers, "microsoft excel": .excel, "excel": .excel,
        "keynote": .keynote, "microsoft powerpoint": .powerpoint, "powerpoint": .powerpoint]
    /// Integrator: document sites outside Google Workspace. A Chrome window with no recorded site whose title ends with
    /// the product ("Q3 plan - Notion") is the same document as its page rows (`inferredHost`).
    static let documentHosts: [(domain: String, kind: AgentEntity.DocumentKind)] = [("notion.so", .notion), ("notion.site", .notion), ("airtable.com", .airtable)]
    /// Title suffixes ("<name> - Tally", "<name> | Typeform") -> the site, for windows with no recorded site.
    static let productHosts: [(suffix: String, host: String)] = [
        ("tally", "tally.so"), ("typeform", "typeform.com"), ("jotform", "jotform.com"), ("airtable", "airtable.com"), ("notion", "notion.so")]
    static let placeholders: Set<String> = ["new tab", "untitled", "loading…", "loading...", "about:blank", "start page", "favorites", "new private tab"]

    // MARK: - Web

    static func web(_ a: CanonicalAction, host: String, title: String, unit: TypedUnitProvenance?) -> AgentEntity {
        let app = a.app
        // Google Workspace files and forms.
        if let doc = googleDocument(a, host: host, title: title) { return doc }
        // Search engines: the words from the title or the address, never anything else.
        if let engine = SearchPage.engine(host: host) {
            return .webSearch(engine: engine, query: searchWords(a, host: host, title: title))
        }
        if let ai = aiHosts.first(where: { BrowserSites.matches(host: host, domain: $0.domain) }) {
            return .aiChat(app: ai.app, title: chatTitle(title, app: ai.app, appName: app, site: host))
        }
        if BrowserSites.emailHosts.contains(where: { BrowserSites.matches(host: host, domain: $0) }) {
            if let subject = unitSubject(unit) { return .email(subject: subject) }
            return .email(subject: EmailTitle.web(title, host: host).flatMap(subject))
        }
        if let feed = feedHosts.first(where: { BrowserSites.matches(host: host, domain: $0.domain) }) {
            let name = AgentTitles.normalized(title, app: app, site: host)
            if let homes = feedHomeTitles[feed.name], !homes.contains(name.lowercased()), !name.isEmpty, name.lowercased() != host {
                return .page(title: name, site: host)
            }
            return .feed(site: feed.name)
        }
        if BrowserSites.chatHosts.contains(where: { BrowserSites.matches(host: host, domain: $0) }) {
            let site = TitleClean.friendlyHost(host)
            if title.contains("(DM)") || title.contains("(Group DM)"), let who = personName(TitleClean.clean(title, app: "", site: host)) {
                return .person(name: who)
            }
            return .app(name: site, title: site, lowValue: false)
        }
        let name = AgentTitles.normalized(title, app: app, site: host)
        if placeholders.contains(name.lowercased()) { return .app(name: app.isEmpty ? "Browser" : app, title: name, lowValue: true) }
        if formHosts.contains(where: { BrowserSites.matches(host: host, domain: $0) }) || isFormTitle(name) {
            return .document(kind: .form, name: name.isEmpty ? TitleClean.friendlyHost(host) : name)
        }
        if let doc = documentHosts.first(where: { BrowserSites.matches(host: host, domain: $0.domain) }), !name.isEmpty {
            return .document(kind: doc.kind, name: name)
        }
        return .page(title: name.isEmpty ? TitleClean.friendlyHost(host) : name, site: host)
    }

    static func googleDocument(_ a: CanonicalAction, host: String, title: String) -> AgentEntity? {
        let suffix = docSuffix(title)
        let google = ["docs.google.com", "drive.google.com", "sheets.google.com", "slides.google.com", "forms.google.com", "forms.gle"]
            .contains(where: { BrowserSites.matches(host: host, domain: $0) })
        guard google || suffix != nil else { return nil }
        var kind = suffix?.kind
        if kind == nil, let path = a.link.flatMap({ URLComponents(string: $0)?.path }) {
            if path.hasPrefix("/document/") { kind = .doc }
            else if path.hasPrefix("/spreadsheets/") { kind = .sheet }
            else if path.hasPrefix("/presentation/") { kind = .slides }
            else if path.hasPrefix("/forms/") { kind = .form }
        }
        if kind == nil {
            if host.hasPrefix("forms.") || host == "forms.gle" { kind = .form }
            else if host.hasPrefix("sheets.") { kind = .sheet }
            else if host.hasPrefix("slides.") { kind = .slides }
            else if host.hasPrefix("drive.") { kind = .drive }
            else { kind = .doc }
        }
        let base = suffix.map { String(title.dropLast($0.length)) } ?? title
        var name = AgentTitles.normalized(base, app: a.app, site: host)
        if name.isEmpty || placeholders.contains(name.lowercased()) {
            switch kind ?? .doc {
            case .doc: name = "Untitled document"
            case .sheet: name = "Untitled spreadsheet"
            case .slides: name = "Untitled presentation"
            case .form: name = "Untitled form"
            case .drive: name = "Google Drive"
            default: name = "Untitled document"
            }
        }
        return .document(kind: kind ?? .doc, name: name)
    }

    /// " - Google Docs" (any dash) at the end of a title, after a browser suffix: the kind and how many characters it is.
    static func docSuffix(_ title: String) -> (kind: AgentEntity.DocumentKind, length: Int)? {
        let t = withoutBrowser(title)
        let lower = t.lowercased()
        for sep in [" - ", " – ", " — "] {
            for (suffix, kind) in docSuffixes where lower.hasSuffix(sep + suffix) && t.count > (sep + suffix).count {
                return (kind, title.count - t.count + (sep + suffix).count)
            }
        }
        return nil
    }

    static func withoutBrowser(_ title: String) -> String {
        var t = title
        for sep in [" - ", " – ", " — "] {
            for browser in ["Google Chrome", "Safari", "Microsoft Edge", "Brave Browser", "Arc", "Firefox"] where t.hasSuffix(sep + browser) {
                t = String(t.dropLast((sep + browser).count))
            }
        }
        return t
    }

    static func searchWords(_ a: CanonicalAction, host: String, title: String) -> String? {
        let t = withoutBrowser(title).trimmingCharacters(in: .whitespacesAndNewlines)
        // "<words> - Google Search" (the tab title), or the words alone (claude/search-1005 keeps them as the title).
        let suffixes = SearchPage.googleSuffixes + SearchPage.engines.flatMap(\.suffixes)
        if let suffix = suffixes.first(where: { t.hasSuffix($0) && t.count > $0.count }), let q = SearchPage.keepable(String(t.dropLast(suffix.count))) {
            return q
        }
        if SearchPage.keepsTitle(host: host, title: t), !isEngineHome(t, host: host) { return t }
        // The address's query parameters (the action's own page link, read only here and never kept).
        if let link = a.link, let found = SearchPage.query(link) { return found.query }
        // The canonical description says the words when the address had them ("Observed search results for … in …;").
        let prefix = "Observed search results for "
        if a.description.hasPrefix(prefix), let r = a.description.range(of: " in ", options: .backwards), r.lowerBound > a.description.index(a.description.startIndex, offsetBy: prefix.count) {
            let words = String(a.description[a.description.index(a.description.startIndex, offsetBy: prefix.count)..<r.lowerBound])
            // The engine's own home page ("Google") has no words.
            if let q = SearchPage.keepable(words), !isEngineHome(q, host: host) { return q }
        }
        return nil
    }

    /// The engine's own page title ("Google", "Bing"): no words.
    static func isEngineHome(_ title: String, host: String) -> Bool {
        let lower = title.lowercased()
        if let engine = SearchPage.engine(host: host), lower == engine.lowercased() { return true }
        return ["google", "bing", "duckduckgo", "new tab", "google search", "search"].contains(lower) || lower == host
    }

    static func chatTitle(_ title: String, app: String, appName: String, site: String) -> String? {
        let t = AgentTitles.normalized(title, app: appName, site: site)
        let lower = t.lowercased()
        let generic: Set<String> = ["", "new chat", "claude", "chatgpt", "gemini", "google gemini", "copilot", "microsoft copilot", "perplexity",
                                    "poe", "grok", "meta ai", "deepseek", "mistral", "le chat", "home", "recents", "chats", "projects", "codex",
                                    app.lowercased(), site.lowercased()]
        return generic.contains(lower) ? nil : t
    }

    /// The site a browser window with no recorded site is on, from its title's own suffix; nil when the title says none.
    static func inferredHost(_ title: String) -> String? {
        let t = withoutBrowser(title).trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        if let doc = docSuffix(t) {
            switch doc.kind {
            case .doc: return "docs.google.com"
            case .sheet: return "docs.google.com"
            case .slides: return "docs.google.com"
            case .form: return "docs.google.com"
            case .drive: return "drive.google.com"
            default: return nil
            }
        }
        if SearchPage.googleSuffixes.contains(where: { t.hasSuffix($0) && t.count > $0.count }) { return "google.com" }
        if lower.hasSuffix(" / x") || lower == "x" || lower.hasSuffix(" on x") || lower.hasSuffix(" / twitter") { return "x.com" }
        if lower.hasSuffix(" - youtube") || lower == "youtube" { return "youtube.com" }
        if lower.hasSuffix(" - gmail") || lower == "gmail" { return "mail.google.com" }
        if lower.hasSuffix(" | linkedin") || lower == "linkedin" { return "linkedin.com" }
        if lower.hasSuffix(" : reddit") || lower.contains(" : r/") || lower == "reddit" || lower.hasPrefix("reddit - ") { return "reddit.com" }
        if lower.hasSuffix(" | hacker news") || lower == "hacker news" { return "news.ycombinator.com" }
        if lower == "claude" || lower.hasSuffix(" - claude") || lower.hasSuffix(" | claude") { return "claude.ai" }
        if lower == "chatgpt" || lower.hasSuffix(" - chatgpt") || lower.hasSuffix(" | chatgpt") { return "chatgpt.com" }
        if lower == "gemini" || lower == "google gemini" || lower.hasSuffix(" - gemini") { return "gemini.google.com" }
        for (product, host) in productHosts {
            for sep in [" - ", " – ", " — ", " | "] where lower.hasSuffix(sep + product) && lower.count > (sep + product).count { return host }
        }
        return nil
    }

    static func isFormTitle(_ name: String) -> Bool {
        name.range(of: formTitle, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Native apps

    static func native(_ a: CanonicalAction, app: String, title: String, unit: TypedUnitProvenance?) -> AgentEntity {
        let appLower = app.lowercased(), bundle = a.bundle
        if let ai = aiBundles[bundle] ?? aiAppNames[appLower] {
            return .aiChat(app: ai, title: chatTitle(title, app: ai, appName: app, site: ""))
        }
        if MessagesMomentIdentity.applies(bundle: bundle, app: app) { return messages(a, title: title) }
        if mailApps.contains(appLower) || mailBundles.contains(bundle) {
            if let subject = unitSubject(unit) { return .email(subject: subject) }
            return .email(subject: EmailTitle.mailApp(title).flatMap(subject))
        }
        if TitleClean.terminalApps.contains(appLower) || terminalBundles.contains(bundle) { return terminal(a, title: title) }
        if appLower == "slack" || bundle == "com.tinyspeck.slackmacgap" {
            let cleaned = TitleClean.clean(title, app: "Slack")
            if title.contains("(DM)") || title.contains("(Group DM)"), let who = personName(cleaned) { return .person(name: who) }
            return .app(name: "Slack", title: cleaned == "Slack" ? "" : cleaned, lowValue: false)
        }
        if appLower.contains("teams") || bundle == "com.microsoft.teams2" || bundle == "com.microsoft.teams" {
            if title.lowercased().hasPrefix("chat |"), let who = personName(TitleClean.clean(title, app: app)) { return .person(name: who) }
        }
        if appLower == "finder" || bundle == "com.apple.finder" {
            let folder = AgentTitles.normalized(title, app: app, site: "")
            return .app(name: "Finder", title: folder.isEmpty ? "" : folder, lowValue: finderViews.contains(folder.lowercased()))
        }
        let name = AgentTitles.normalized(title, app: app, site: "")
        if systemApps.contains(appLower) || systemBundles.contains(bundle) {
            return .app(name: app.isEmpty ? "System" : app, title: name, lowValue: true)
        }
        if let kind = officeApps[appLower] ?? officeBundleKind(bundle), !name.isEmpty {
            return .document(kind: kind, name: withoutExtension(name))
        }
        return .app(name: app.isEmpty ? (bundle.isEmpty ? "App" : bundle) : app, title: name == app ? "" : name, lowValue: false)
    }

    static func officeBundleKind(_ bundle: String) -> AgentEntity.DocumentKind? {
        switch bundle {
        case "com.apple.iWork.Pages": return .pages
        case "com.microsoft.Word": return .word
        case "com.apple.TextEdit": return .textedit
        case "com.apple.iWork.Numbers": return .numbers
        case "com.microsoft.Excel": return .excel
        case "com.apple.iWork.Keynote": return .keynote
        case "com.microsoft.Powerpoint": return .powerpoint
        default: return nil
        }
    }

    static func withoutExtension(_ name: String) -> String {
        let out = name.replacingOccurrences(of: #"\.(docx?|pages|rtf|txt|md|xlsx?|numbers|csv|key|pptx?)$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return out.isEmpty ? name : out
    }

    /// Messages: the conversation its window shows (a contact name or a group, else the number or address the window
    /// shows). The app's own list or a New Message window names nobody.
    static func messages(_ a: CanonicalAction, title: String) -> AgentEntity {
        if a.kind == "keyboard.text_input" {
            // A typed row's identity is its own recipient only (MessagesMomentIdentity, B2): never a nearby title.
            return .app(name: "Messages", title: "", lowValue: false)
        }
        // The app's own windows ("Messages", "New Message", "New iMessage") name nobody; TitleClean calls them "Email".
        let generic: Set<String> = ["", "messages", "new message", "new imessage", "imessage", "email"]
        guard !generic.contains(title.lowercased()) else { return .app(name: "Messages", title: "", lowValue: false) }
        let cleaned = TitleClean.clean(title, app: "Messages")
        if !generic.contains(cleaned.lowercased()), let who = personName(cleaned) { return .person(name: who) }
        if let handle = SendRules.messagesHandle(title) { return .person(name: handle) }
        return .app(name: "Messages", title: "", lowValue: false)
    }

    /// A conversation title as a person (or group) name: `SendRules.conversationName`, plus groups of up to 6 words
    /// ("Maya, Sam & 2 more").
    static func personName(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name = SendRules.conversationName(s) { return name }
        guard s.contains(",") || s.contains("&"), (1...60).contains(s.count), !s.contains("@"), s.filter(\.isNumber).count < 5,
              s.first?.isLetter == true, s.split(separator: " ").count <= 6 else { return nil }
        return s
    }

    static func typedRecipient(_ a: CanonicalAction, unit: TypedUnitProvenance?) -> String? {
        if MessagesMomentIdentity.applies(bundle: a.bundle, app: a.app) {
            if let name = MessagesMomentIdentity.recipient(unit) { return name }
            return nil
        }
        // Chat surfaces elsewhere (Slack, WhatsApp, a web chat) with a code-read recipient.
        guard let unit, ["text", "chat"].contains(unit.surface ?? ""), ["message", "body", "textArea"].contains(unit.field ?? "") else { return nil }
        return unit.to.flatMap(SendRules.conversationName)
    }

    static func unitSubject(_ unit: TypedUnitProvenance?) -> String? {
        guard let unit, unit.surface == "email", let raw = unit.subject else { return nil }
        return subject(raw)
    }

    /// An email subject as written ("Re: Pilot pricing": the reply prefix says what it is); a mailbox view ("Inbox",
    /// "Sent") is none. One thread is one item: `threadName` (the key) drops the reply and forward prefixes.
    static func subject(_ raw: String) -> String? {
        let s = AgentTitles.collapsed(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        if Set(EmailTitle.views.values).contains(s) || EmailTitle.views[s.lowercased()] != nil { return nil }
        return s.isEmpty ? nil : s
    }

    /// The thread an email subject belongs to: no reply or forward prefix.
    static func threadName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed {
            changed = false
            if let r = s.range(of: #"^(re|fwd?|aw|wg|tr|sv|vs)\s*(\[\d+\])?\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) {
                s.removeSubrange(r); changed = true
            }
        }
        s = AgentTitles.collapsed(s)
        return s.isEmpty ? raw : s
    }

    // MARK: - Terminal

    static let shells: Set<String> = ["zsh", "-zsh", "bash", "-bash", "fish", "-fish", "sh", "-sh", "login", "tmux", "screen", "nu"]
    static let toolCommands: Set<String> = ["claude", "codex", "gemini", "aider", "ssh", "mosh", "sudo"]
    static let userAtHost = #"([A-Za-z0-9._-]+)@(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?)"#
    static let ipv4 = #"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?(?![\d.])"#
    static let ipv6 = #"(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![0-9A-Fa-f:])"#
    static let sshHost = #"\b(?:ssh|mosh|sftp)\s+(?:-[A-Za-z]+(?:\s+\d+)?\s+)*([A-Za-z0-9][A-Za-z0-9._-]*)"#

    /// A terminal window as tool, project (the folder or topic it is in) and host alias. Every user@host, IPv4/IPv6
    /// address and ssh target is replaced by `hostAlias`, so neither a host name nor an address ever reaches an agent.
    static func terminal(_ a: CanonicalAction, title: String) -> AgentEntity {
        var t = title
        var host: String? = nil
        func take(_ pattern: String, group: Int) {
            while let match = firstMatch(pattern, in: t) {
                let whole = match.range, part = match.range(at: group)
                if let r = Range(part, in: t) {
                    let name = String(t[r]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    if !isLocal(name) { host = host ?? hostAlias(name) }
                }
                guard let w = Range(whole, in: t) else { break }
                t.replaceSubrange(w, with: " ")
            }
        }
        take(userAtHost, group: 2)
        take(sshHost, group: 1)
        take(ipv4, group: 0)
        // An IPv6 address: "::" in it, or at least five groups (never a "10:30:00" clock).
        while let match = firstMatch(ipv6, in: t), let r = Range(match.range, in: t) {
            let found = String(t[r])
            if found.contains("::") || found.split(separator: ":").count >= 5 {
                if !isLocal(found) { host = host ?? hostAlias(found) }
                t.replaceSubrange(r, with: " ")
            } else { break }
        }
        let rawTool = a.tool.flatMap { $0.isEmpty ? nil : $0 } ?? TitleClean.terminalTool(title)
        let project = terminalProject(t, tool: rawTool)
        return .terminal(tool: rawTool, project: project, host: host)
    }

    static func terminalProject(_ raw: String, tool: String?) -> String? {
        let user = NSUserName()
        var parts = [raw]
        for sep in [" — ", " – "] { parts = parts.flatMap { $0.components(separatedBy: sep) } }
        for var part in parts {
            part = part.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":%$#>")))
            guard !part.isEmpty else { continue }
            let first = part.split(whereSeparator: \.isWhitespace).first.map { (String($0) as NSString).lastPathComponent.lowercased() } ?? ""
            if shells.contains(part.lowercased()) || part.range(of: #"^\d+\s*[×x]\s*\d+$"#, options: .regularExpression) != nil { continue }
            if toolCommands.contains(first) || part == user { continue }
            if let pathMatch = firstMatch(#"(?:^|\s)(~?/[^\s:]*|~)(?=$|\s|:)"#, in: part), let r = Range(pathMatch.range(at: 1), in: part) {
                var path = String(part[r])
                while path.count > 1, path.hasSuffix("/") { path.removeLast() }
                let last = (path as NSString).lastPathComponent
                if path == "~" || path == "/" || last.isEmpty || last == user || last == "~" { continue }
                return bounded(last)
            }
            if part.range(of: #"^(~(/\S*)?|cd(\s.*)?)$"#, options: .regularExpression) != nil { continue }
            if let tool, part.lowercased() == tool.lowercased() { continue }
            return bounded(part)
        }
        return nil
    }

    static func isLocal(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "localhost" || h == "127.0.0.1" || h == "::1" || h == "0.0.0.0" || h.hasSuffix(".local")
            || ["macbook", "mac-mini", "macmini", "imac", "mac-studio", "macstudio", "mac-pro"].contains(where: h.contains) || h.hasSuffix("-mac")
    }

    static func bounded(_ s: String) -> String {
        let t = AgentTitles.collapsed(s)
        return t.count <= 80 ? t : String(t.prefix(79)) + "…"
    }

    // MARK: - Helpers

    static func isBrowser(app: String, bundle: String) -> Bool { browserApps.contains(app) || browserBundles.contains(bundle) }

    static func cleanTitle(_ raw: String) -> String {
        let s = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !AgentTitles.invisibles.contains($0) }))
        return TitleClean.statusless(s).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func firstMatch(_ pattern: String, in s: String) -> NSTextCheckingResult? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
    }
}

extension AgentEntity {
    /// The stable grouping string: kind, sub-kind and the folded name. Item ids are hashed from it (with the day).
    public var key: String {
        let f = { (s: String) in AgentTitles.folded(s, tails: true) }
        switch self {
        case .document(let k, let name): return "\(kind.rawValue)|\(k.rawValue)|\(f(name))"
        case .webSearch(let engine, let query): return "web_search|\(f(engine))|\(query.map(f) ?? "")"
        case .aiChat(let app, let title): return "ai_chat|\(f(app))|\(title.map(f) ?? "")"
        case .person(let name): return "person|\(f(name))"
        case .email(let subject): return "email|\(subject.map { f(AgentEntities.threadName($0)) } ?? "")"
        case .terminal(let tool, let project, let host): return "terminal|\(tool.map(f) ?? "")|\(project.map(f) ?? "")|\(host ?? "")"
        case .feed(let site): return "feed|\(f(site))"
        case .page(let title, let site): return "page|\(site.lowercased())|\(f(title))"
        case .app(let name, let title, let low): return "app|\(f(name))|\(f(title))\(low ? "|low" : "")"
        }
    }
}
