import Foundation
import PrivacyPolicy

// fix/day-card: a window or page title as a name a person would say. Every fallback title in the UI (a moment with no
// note), every live thread label (LiveDay) and every page title a cloud writer reads goes through here, so no row ever
// shows an email address, an unread count, an app or site suffix, a pipe or a GitHub "· Pull Request #" string.
//
//   "Inbox (23) - sam@daydream.example - Gmail"                 -> "Email"
//   "Re: Pro plan pricing - sam@daydream.example - Gmail"       -> "Pro plan pricing"
//   "Weekly summaries export by riley · Pull Request #418 · daydream/daydream" -> "PR #418: Weekly summaries export"
//   "(3) How Linear builds product - YouTube"                    -> "How Linear builds product"
//   "#eng (Channel) - DayDream - Slack"                          -> "#eng"
//
// Code only, from the title the window already shows; typed words are never an input. The rule list is kept in step with
// WriterBackend's fallback name (fix/notes-quality); scripts/title-clean-checks.swift holds the shared fixtures.
public enum TitleClean {
    /// Trailing segments that only name the app, the site or the account's product ("- Gmail", "– iCloud").
    static let productSegments: Set<String> = [
        "gmail", "google mail", "icloud", "icloud mail", "mail", "outlook", "microsoft outlook", "outlook.com", "proton mail", "superhuman",
        "google docs", "google sheets", "google slides", "google drive", "google forms", "google calendar", "google meet", "docs", "sheets", "slides",
        "youtube", "youtube music", "netflix", "twitch", "vimeo", "slack", "github", "gitlab", "notion", "figma", "coda", "linear", "jira",
        "google chrome", "chrome", "safari", "firefox", "arc", "microsoft edge", "microsoft teams", "teams", "zoom", "zoom workplace",
        "x", "twitter", "linkedin", "reddit", "hacker news", "google search", "google", "bing", "duckduckgo", "chatgpt", "claude", "claude.ai",
        "edited", "messages", "whatsapp", "discord", "microsoft word", "word", "microsoft excel", "excel", "pages", "numbers", "keynote",
    ]
    /// Mailbox views: a title that only names one is "Email".
    static let mailboxes: Set<String> = ["inbox", "all mail", "sent", "sent mail", "drafts", "starred", "important", "archive", "outbox", "junk",
                                         "spam", "trash", "mail", "new message", "primary", "updates", "promotions", "unread", "flagged", "vip"]
    /// Microsoft Teams leads its titles with the view ("Chat | Maya Chen | Microsoft Teams").
    static let teamsViews: Set<String> = ["chat", "chats", "activity", "calendar", "teams", "calls", "files", "meeting", "meeting compact view"]
    static let separators = [" — ", " – ", " - ", " | ", " · ", " • "]

    /// claude/title-spinner-1003 (audit B1/S4): a window title without the status glyphs an app animates at its ends.
    /// Claude Code ticks "✳ / ◐ / ◑ <session>" in its terminal tab about once a second, CLI tools spin braille dots
    /// ("⠋ Building"), editors add a dirty dot ("main.swift ●"). Those are one title, so capture saves it once, moments
    /// group it once, and no read, search snippet or AI app shows the glyph. Generic for every app: only whole runs of
    /// status symbols at the start or end go (braille, geometric shapes, dingbats, misc symbols and technical, arrows,
    /// blocks, bullets, a few status emoji); letters, digits, "~", "#", "@", quotes, brackets and the middle of the title
    /// never change. A title that is only glyphs becomes "". A title with no status glyph is returned unchanged.
    public static func statusless(_ raw: String) -> String {
        guard raw.unicodeScalars.contains(where: statusGlyph) else { return raw }
        var scalars = Array(raw.unicodeScalars), glyphs = 0
        func strip(_ s: Unicode.Scalar) -> Bool {
            if statusGlyph(s) { glyphs += 1; return true }
            return s.properties.isWhitespace
        }
        while let first = scalars.first, strip(first) { scalars.removeFirst() }
        while let last = scalars.last, strip(last) { scalars.removeLast() }
        // Only a glyph at an end changes the title: "a → b" (a glyph inside) keeps even its own spacing.
        guard glyphs > 0 else { return raw }
        var out = String.UnicodeScalarView(); out.append(contentsOf: scalars)
        return String(out)
    }
    /// One status symbol (or a joiner/variation selector attached to one).
    static func statusGlyph(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x2800...0x28FF,          // braille spinners ⠋⠙⠹
             0x25A0...0x25FF,          // geometric shapes ◐◑◒◓●○◉■□▲►◆
             0x2700...0x27BF,          // dingbats ✳✶✻✽✢✓✔✗❯➜
             0x2600...0x26FF,          // misc symbols ★☆⚡⚠☐⚪⚫
             0x2300...0x23FF,          // misc technical ⏳⏸⏺⌛
             0x2190...0x21FF,          // arrows ↻↺→
             0x27F0...0x27FF,          // supplemental arrows ⟳
             0x2B00...0x2BFF,          // misc symbols and arrows ⬤⭐
             0x2580...0x259F,          // block elements ▁▂▃
             0x2022, 0x00B7, 0x2219, 0x22C5, 0x2023, 0x2043, // bullets • · ∙ ⋅ ‣ ⁃
             0x1F514, 0x1F515,         // 🔔 🔕 (a terminal bell)
             0x1F534...0x1F535, 0x1F7E0...0x1F7EB, // 🔴🔵🟠🟡🟢🟣🟤 status dots
             0xFE0E, 0xFE0F, 0x200D:   // variation selectors and the joiner after one of the above
            return true
        default:
            return false
        }
    }

    /// `raw` as a name. `app` and `site` are the action's own (an app suffix is dropped; an empty result falls back to
    /// them); `ownerEmails` are the person's own addresses, whose name segment ("Sam", "Sam Rivera") is dropped too.
    public static func clean(_ raw: String, app: String = "", site: String = "", ownerEmails: Set<String> = []) -> String {
        var s = statusless(raw.replacingOccurrences(of: "\u{200e}", with: "").replacingOccurrences(of: "\u{200f}", with: ""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let host = hostName(site)
        // claude/catchup-1003: Messages titles a contact Siri only suggests "Maybe: Name"; the name is the title.
        if app.lowercased() == "messages" { s = SendRules.siriSuggestion(s) }
        // claude/ready-1002: a terminal's title is its tool's status ("✳ Tallybird app design review") or a bare shell ("~").
        if terminalApps.contains(app.lowercased()) {
            // claude/int-1002: the account name is a bare shell too (MemoryUI `TerminalTitle` drops it the same way).
            s = terminalName(s, user: NSUserName())
            if s.isEmpty { return fallbackName(app: app, host: host) }
        }
        // X may append both site and browser suffixes. Strip only exact known trailing
        // segments before inspecting its attributed post title; quoted topic punctuation stays intact.
        let xHost = ["x.com", "twitter.com", "mobile.twitter.com"].contains(host.lowercased())
        if xHost {
            s = stripXTitleSuffixes(s)
            s = s.replacingOccurrences(of: "^\\(\\d+\\+?\\)\\s*", with: "", options: .regularExpression)
            if let attributed = attributedXTitle(s) { return bounded(attributed) }
        }
        // GitHub syntax inside an attributed X quote is topic text, so inspect it only after that path.
        if let pr = gitHub(s) { return pr }
        // Unread counts outside an attributed X topic: "Inbox (23)", "WhatsApp (5)".
        for pattern in ["^\\(\\d+\\+?\\)\\s*", "\\s*\\(\\d+\\+?(?: unread| new)?(?: messages?)?\\)", "\\s*\\[\\d+\\+?\\]"] {
            s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        if xHost, ["home", "notifications", "explore", "messages", "bookmarks", "x", "twitter"].contains(s.lowercased()) { s = "" }
        // Slack: "#eng (Channel) - DayDream - Slack" -> "#eng"; "Priya (DM) - DayDream - Slack" -> "Priya".
        var channel = false
        for tag in [" (Channel)", " (Private Channel)", " (DM)", " (Group DM)"] where s.contains(tag) {
            channel = channel || tag.hasSuffix("Channel)")
            s = s.replacingOccurrences(of: tag, with: "")
        }
        var parts = [s]
        for sep in separators { parts = parts.flatMap { $0.components(separatedBy: sep) } }
        parts = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let ownNames = ownerNames(ownerEmails)
        let appLower = app.lowercased(), hostLower = host.lowercased()
        let slack = appLower == "slack" || hostLower.hasSuffix("slack.com") || parts.last?.lowercased() == "slack"
        let teams = appLower.contains("teams") || hostLower.contains("teams.") || parts.last?.lowercased() == "microsoft teams"
        // Drop email addresses, the owner's own name, and trailing product segments ("- Gmail", "— Xcode" when it is the app).
        parts = parts.compactMap { part -> String? in
            var p = part.replacingOccurrences(of: "[^\\s<>()]+@[^\\s<>()]+\\.[^\\s<>()]+", with: "", options: .regularExpression)
                .replacingOccurrences(of: "<>", with: "").trimmingCharacters(in: .whitespaces)
            p = p.trimmingCharacters(in: CharacterSet(charactersIn: "()<>,;:").union(.whitespaces))
            if p.isEmpty || ownNames.contains(p.lowercased()) { return nil }
            return p
        }
        while parts.count > 1, let last = parts.last?.lowercased(),
              productSegments.contains(last) || last == appLower || last == hostLower || (!host.isEmpty && last == friendlyHost(host).lowercased()) {
            parts.removeLast()
        }
        // fix/sx-all round 3: a leading segment that is the page's own app ("Linear – HAR-231 Flaky resume test", "Jira - TAL-9 ...",
        // "Notion - Q3 plan") is dropped the same way as a trailing one.
        if parts.count > 1, let first = parts.first?.lowercased(), !host.isEmpty, productSegments.contains(first) || first == friendlyHost(host).lowercased(),
           hostLower == first || hostLower.hasPrefix(first + ".") || hostLower.hasSuffix("." + first + ".com") || first == friendlyHost(host).lowercased() {
            parts.removeFirst()
        }
        // A title that is only the host ("mail.google.com") names nothing more than the site.
        if parts.count == 1, let only = parts.first?.lowercased(), !host.isEmpty, only == hostLower || only == "www." + hostLower { parts = [] }
        if slack, let first = parts.first {
            // The workspace name after the channel says nothing more.
            let name = first.trimmingCharacters(in: .whitespaces)
            parts = [channel && !name.hasPrefix("#") ? "#" + name : name]
        }
        if teams, parts.count > 1, teamsViews.contains(parts[0].lowercased()) { parts.removeFirst() }
        // Reply and forward prefixes say nothing about the thread.
        if var first = parts.first {
            var changed = true
            while changed {
                changed = false
                for prefix in ["Re:", "RE:", "Fwd:", "FWD:", "Fw:", "FW:", "Aw:", "AW:"] where first.hasPrefix(prefix) {
                    first = String(first.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces); changed = true
                }
            }
            parts[0] = first
        }
        parts = parts.filter { !$0.isEmpty }
        // A mailbox view ("Inbox", "Sent Mail") is "Email".
        if parts.count <= 1, let only = parts.first?.lowercased(), mailboxes.contains(only) { return "Email" }
        if parts.isEmpty {
            if isMail(app: appLower, host: hostLower) { return "Email" }
            return fallbackName(app: app, host: host)
        }
        // Whatever is left keeps at most two segments, joined without a pipe.
        return bounded(parts.prefix(2).joined(separator: " - "))
    }

    /// Bounded display text, preserving every original word that fits before truncation.
    static func bounded(_ name: String) -> String {
        var out = name
        if out.count > 90 {
            var cut = String(out.prefix(89))
            if out[out.index(out.startIndex, offsetBy: 89)] != " ", let space = cut.lastIndex(of: " ") { cut = String(cut[..<space]) }
            out = cut.trimmingCharacters(in: .whitespaces) + "…"
        }
        return out
    }

    static func stripXTitleSuffixes(_ raw: String) -> String {
        var out = raw
        let names = ["X", "Twitter", "Google Chrome", "Chrome", "Safari", "Firefox", "Arc", "Microsoft Edge", "Brave Browser", "Brave"]
        let suffixes = names.flatMap { name in (separators + [" / "]).map { $0 + name } }
        var changed = true
        while changed {
            changed = false
            for suffix in suffixes where out.lowercased().hasSuffix(suffix.lowercased()) {
                out = String(out.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
                break
            }
        }
        return out
    }

    /// A recorded attributed X title has useful topic punctuation; do not split its quote
    /// into generic app-title segments or remove numbers that belong to the topic.
    static func attributedXTitle(_ raw: String) -> String? {
        let clean = raw.replacingOccurrences(of: "[^\\s<>()]+@[^\\s<>()]+\\.[^\\s<>()]+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let marker = [" on X:", " on Twitter:"].compactMap({ clean.range(of: $0) }).first else { return nil }
        let author = String(clean[..<marker.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !author.isEmpty else { return nil }
        let topic = String(clean[marker.upperBound...]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"\u{0027}“”‘’")))
        if !topic.isEmpty { return clean }
        // Empty quotes establish no topic. Keep only the author/site actually present.
        return String(clean[..<marker.upperBound]).trimmingCharacters(in: CharacterSet(charactersIn: ":").union(.whitespacesAndNewlines))
    }

    /// A thread label as the page shows it: GitHub's "GitHub PR #418: …" is "PR #418: …", and anything a window put in it
    /// (an unread count, an address) is cleaned.
    public static func label(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("GitHub PR #") { s = String(s.dropFirst("GitHub ".count)) }
        else if s.hasPrefix("GitHub issue #") { s = "Issue #" + s.dropFirst("GitHub issue #".count) }
        guard !s.isEmpty else { return raw }
        let cleaned = clean(s)
        return cleaned.isEmpty ? s : cleaned
    }

    static func gitHub(_ title: String) -> String? {
        let parts = title.components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, let kind = parts.first(where: { $0.hasPrefix("Pull Request #") || $0.hasPrefix("Issue #") }),
              let number = kind.components(separatedBy: "#").last, !number.isEmpty else { return nil }
        var name = parts[0]
        if name == kind { name = "" }
        if let by = name.range(of: " by ", options: .backwards) { name = String(name[..<by.lowerBound]) }
        name = name.trimmingCharacters(in: .whitespaces)
        let tag = (kind.hasPrefix("Pull") ? "PR #" : "Issue #") + number
        return name.isEmpty ? tag : tag + ": " + name
    }

    static func ownerNames(_ emails: Set<String>) -> Set<String> {
        var out = Set<String>()
        for email in emails {
            let lower = email.lowercased().trimmingCharacters(in: .whitespaces)
            guard !lower.isEmpty else { continue }
            out.insert(lower)
            let local = lower.split(separator: "@").first.map(String.init) ?? lower
            out.insert(local)
            let words = local.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" }).map(String.init)
            if words.count > 1 { out.insert(words.joined(separator: " ")) }
        }
        return out
    }

    static func hostName(_ site: String) -> String {
        var h = site.lowercased().trimmingCharacters(in: .whitespaces)
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }
    static func friendlyHost(_ host: String) -> String {
        switch host {
        case "mobile.twitter.com": return "X"
        case "instagram.com": return "Instagram"
        default: return ThreadEntities.friendlyHosts[host] ?? host
        }
    }
    static func isMail(app: String, host: String) -> Bool {
        ["mail", "outlook", "microsoft outlook", "spark", "superhuman", "mimestream"].contains(app) || host == "mail.google.com"
            || host.hasPrefix("outlook.") || host == "mail.proton.me" || host == "app.superhuman.com"
    }
    static func fallbackName(app: String, host: String) -> String {
        if !host.isEmpty { return friendlyHost(host) }
        return app
    }

    /// claude/ready-1002: terminal apps, whose window titles a shell or a tool sets (WriterBackend `terminalApps`).
    public static let terminalApps: Set<String> = ["terminal", "iterm2", "iterm", "ghostty", "warp", "alacritty", "kitty", "wezterm", "hyper", "tabby"]
    static let terminalTools = ["claude": "Claude Code", "codex": "Codex", "gemini": "Gemini CLI", "aider": "Aider"]
    static let claudeGlyphs: Set<Unicode.Scalar> = ["✳", "✶", "✻", "✽", "✢"]
    static let geminiGlyphs: Set<Unicode.Scalar> = ["◇", "✦"]
    /// claude/int-1003: a busy spinner a tool puts before its session title ("◐ <topic>"): a tool, though not which one
    /// (MomentDetailFold's `spinnerMarks`).
    public static let spinnerGlyphs: Set<UInt32> = [0x25D0, 0x25D1, 0x25D2, 0x25D3]
    static let terminalToolWords: [(String, String)] = [("claude code", "Claude Code"), ("codex", "Codex"), ("gemini cli", "Gemini CLI"), ("aider", "Aider")]
    /// claude/summary-1003 (owner): the AI coding tool a terminal window's title shows running, or nil: the process after
    /// " — " ("harborline — claude"), the tool's command first ("claude --resume"), Claude Code's status glyph ("✳ <topic>",
    /// a braille spinner or its star frames), Gemini CLI's "◇ Ready" / "✦ Working", or the tool's name as a word. The
    /// writer's `CanonicalGrounding.terminalTool(title:)` is the same rule (summary-terminal checks hold both to one list).
    public static func terminalTool(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let process = t.components(separatedBy: " — ").dropFirst().joined(separator: " ").lowercased()
        if let program = process.split(separator: " ").first.map({ (String($0) as NSString).lastPathComponent }), let tool = terminalTools[program] { return tool }
        var stripped = t
        if let r = t.range(of: #"^[^\p{L}\p{N}~/#@"'(\[._-]+\s+"#, options: .regularExpression) { stripped = String(t[r.upperBound...]) }
        let first = stripped.split(whereSeparator: \.isWhitespace).first.map { (String($0) as NSString).lastPathComponent.lowercased() } ?? ""
        if let tool = terminalTools[first] { return tool }
        if stripped != t, let g = t.unicodeScalars.first {
            if claudeGlyphs.contains(g) || (0x2801...0x28FF).contains(g.value) { return "Claude Code" }
            if geminiGlyphs.contains(g) { return "Gemini CLI" }
        }
        let lower = t.lowercased()
        for (word, tool) in terminalToolWords where lower.range(of: #"(?<![\p{L}\p{N}_-])"# + word + #"(?![\p{L}\p{N}_-])"#, options: .regularExpression) != nil { return tool }
        return nil
    }
    /// claude/ready-1002: a terminal window title as a name, the writer's rule (WriterBackend `CanonicalGrounding.terminalName`):
    /// no leading status glyph ("✳ Tallybird app design review" -> "Tallybird app design review"), a tool's command is the
    /// tool ("claude --resume" -> "Claude Code"), and a bare shell ("~", "🔔 ~", "-zsh", "cd", "login — 120×30") is "".
    /// claude/int-1002: `user` (the account name a terminal puts first) is dropped like a shell when given.
    public static func terminalName(_ raw: String, user: String? = nil) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: #"^[^\p{L}\p{N}~/#@"'(\[._-]+\s+"#, options: .regularExpression) { t = String(t[r.upperBound...]) }
        let first = t.split(whereSeparator: \.isWhitespace).first.map { (String($0) as NSString).lastPathComponent.lowercased() } ?? ""
        if let tool = terminalTools[first] { return tool }
        let shells: Set<String> = ["zsh", "-zsh", "bash", "-bash", "fish", "-fish", "sh", "login"]
        let parts = t.components(separatedBy: " — ").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !shells.contains($0.lowercased()) && $0 != user && $0.range(of: #"^\d+\s*[×x]\s*\d+$"#, options: .regularExpression) == nil }
        if parts.isEmpty { return "" }
        if parts.count == 1, parts[0].range(of: #"^(~(/\S*)?|cd(\s.*)?)$"#, options: .regularExpression) != nil { return "" }
        return parts.joined(separator: " — ")
    }
}
