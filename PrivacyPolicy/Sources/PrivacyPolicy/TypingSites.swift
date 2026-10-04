import Foundation

// Safe typing E, websites: the host table for website typing through the
// Chrome join (owner build only; compiled out of public builds' capture).
// Owner decision 3 (typing-all SPEC-LATER 1): websites outside the four
// categories are "Other websites", a switch that is on by default; blocked
// sites, Incognito and Guest windows never type. The Chrome typing rules in
// MemoryCore (`BrowserTypingSites.rule`) add the common search, email and chat
// hosts of Chrome page history to this table. The focus gate every website
// key passes is `WebTypingGate` (WebTypingGate.swift), which exists only in
// builds with Chrome typing.

/// What a website counts as, for later website typing (Chrome join only).
public enum TypingSiteRule: Equatable, Sendable {
    case category(TypingCategory)
    /// Never recorded, whatever the choices (canvas editors, the pinned
    /// sensitive sites, sign-in and payment pages).
    case never
    /// "Other websites": not one of the four categories. Its own switch
    /// (`TypedCategoryChoices.otherWebsites`), on by default (owner decision 3).
    case other
}

extension TypingCategories {
    // MARK: - Websites (later website typing through the Chrome join)

    public struct Site: Equatable, Sendable {
        public let host: String
        /// nil = any path on that host.
        public let path: String?
        public let rule: TypingSiteRule
        init(_ host: String, _ path: String? = nil, _ rule: TypingSiteRule) { self.host = host; self.path = path; self.rule = rule }
    }
    /// SPEC 6.2 host table. Everything else is "Other websites" (its own switch).
    public static let sites: [Site] = [
        Site("google.com", "/search", .category(.searchAndAI)),
        Site("bing.com", "/search", .category(.searchAndAI)),
        Site("duckduckgo.com", nil, .category(.searchAndAI)),
        Site("claude.ai", nil, .category(.searchAndAI)),
        Site("chatgpt.com", nil, .category(.searchAndAI)),
        Site("perplexity.ai", nil, .category(.searchAndAI)),
        Site("gemini.google.com", nil, .category(.searchAndAI)),
        Site("mail.google.com", nil, .category(.messagesAndEmail)),
        Site("outlook.live.com", nil, .category(.messagesAndEmail)),
        Site("app.slack.com", nil, .category(.messagesAndEmail)),
        Site("discord.com", nil, .category(.messagesAndEmail)),
        Site("web.whatsapp.com", nil, .category(.messagesAndEmail)),
        Site("notion.so", nil, .category(.writing)),
        // Canvas plus a hidden input frame: not supportable.
        Site("docs.google.com", nil, .never),
        Site("accounts.google.com", nil, .never),
    ]
    /// Path words that make any page a never (sign-in, payment), as the capture gate.
    static let neverPathWords = ["login", "signin", "sign-in", "oauth", "password", "checkout", "payment", "wallet", "bank"]

    /// What a page counts as. Host matching is exact or a subdomain; the most
    /// specific host wins, and a never wins a tie. Sensitive sites and
    /// sign-in or payment paths are always never.
    public static func site(host rawHost: String, path rawPath: String = "/") -> TypingSiteRule {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard !host.isEmpty else { return .never }
        let path = rawPath.isEmpty ? "/" : rawPath.lowercased()
        func under(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if CaptureGate.sensitiveDomains.contains(where: under) { return .never }
        if neverPathWords.contains(where: { (host + path).contains($0) }) { return .never }
        let matches = sites.filter { s in
            under(s.host) && (s.path.map { path == $0 || path.hasPrefix($0 + "/") } ?? true)
        }
        guard let longest = matches.map(\.host.count).max() else { return .other }
        let best = matches.filter { $0.host.count == longest }
        return best.contains { $0.rule == .never } ? .never : best[0].rule
    }
    /// Website typing: only with the gate open; a known category that is on,
    /// or an "Other websites" page while that switch is on. Never pages are
    /// never permitted. Private and incognito windows are refused before
    /// this (strict Chrome join). `other` defaults to off here; the saved
    /// choice (`TypedCategoryChoices.otherWebsites`) is on by default.
    public static func permitsSite(host: String, path: String = "/", on: (TypingCategory) -> Bool, other: Bool = false,
                                   expanded: Bool = TypingRelease.open) -> Bool {
        guard expanded else { return false }
        switch site(host: host, path: path) {
        case .never: return false
        case .category(let category): return on(category)
        case .other: return other
        }
    }
}
