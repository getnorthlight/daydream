import Foundation
import PrivacyPolicy

// email-1003 (owner decision 2026-10-03): DayDream records what happens in email, not just the site name.
//
//  Webmail page rows (Chrome)   keep a cleaned title: the opened email's subject or the folder ("Inbox", "Sent",
//                               "Re: Demo feedback"). The address stays dropped: site plus title. Only while
//                               "Save email subjects" is on (`PrivacySettings.emailSubjects`, default on); off keeps
//                               the site only, as before.
//  Mail.app window titles       were always kept; they are now cleaned the same way (no message or unread counts, no
//                               account addresses) and scrubbed at ingest and at read.
//  Every subject                goes through `TypedSecretScrubber.sensitiveSubject` (one-time codes, password, sign-in,
//                               security, verification and bank mail): a sensitive subject is never kept, a webmail
//                               page then keeps its site only and a Mail window keeps the omitted-title marker.
//
// Code only, from the title the window or tab already shows; typed words are never an input. Incognito, the block
// lists, excluded apps and sites, and retention apply before any of this (`ChromePageProbe`, `Privacy.sanitized`).
public enum EmailTitle {
    public static let version = "email-title/v1"
    /// Most kept titles are short; Chrome page rows allow 160 characters.
    public static let limit = 160

    /// Folder and view names, normalised across Gmail, Outlook, Yahoo, Proton, iCloud and Mail.
    static let views: [String: String] = [
        "inbox": "Inbox", "all inboxes": "Inbox", "focused": "Inbox", "primary": "Inbox",
        "sent": "Sent", "sent mail": "Sent", "sent items": "Sent", "sent messages": "Sent",
        "drafts": "Drafts", "draft": "Drafts",
        "starred": "Starred", "snoozed": "Snoozed", "important": "Important", "scheduled": "Scheduled", "flagged": "Flagged",
        "vip": "VIP", "unread": "Unread",
        "all mail": "All Mail", "archive": "Archive", "archived": "Archive",
        "spam": "Spam", "junk": "Junk", "junk email": "Junk", "junk e-mail": "Junk", "junk mail": "Junk",
        "trash": "Trash", "bin": "Trash", "deleted items": "Trash", "deleted messages": "Trash", "deleted": "Trash",
        "outbox": "Outbox", "mail": "Mail", "email": "Mail",
        "search results": "Search results", "search": "Search results",
        "new message": "New message", "compose": "New message", "compose mail": "New message", "new mail": "New message",
        "new email": "New message",
    ]
    /// Trailing segments that only name the mail product.
    static let products: Set<String> = [
        "gmail", "google mail", "outlook", "microsoft outlook", "outlook.com", "outlook web app", "outlook on the web", "mail",
        "yahoo mail", "yahoo! mail", "aol mail", "proton mail", "protonmail", "icloud mail", "icloud", "fastmail", "hey", "zoho mail",
        "gmx", "web.de", "mail.ru", "yandex mail", "yandex.mail", "tuta", "tuta mail", "tutanota", "superhuman", "posteo", "mailbox.org",
        "naver mail", "qq mail", "mail.com", "google chrome", "microsoft 365", "office 365",
    ]
    static let separators = [" - ", " – ", " — ", " | "]
    static let address = try! NSRegularExpression(pattern: #"<?[^\s<>()\[\]]+@[^\s<>()\[\]]+\.[A-Za-z]{2,}>?"#)

    /// A webmail tab title as kept on the page row, or nil (the row keeps its site only). `host` is the page's host.
    ///   "Inbox (3) - sam@example.com - Gmail"          -> "Inbox"
    ///   "Re: Demo feedback - sam@example.com - Gmail"  -> "Re: Demo feedback"
    ///   "Mail - Sam Rivera - Outlook"                    -> "Mail"
    ///   "Re: Demo feedback – Outlook"                   -> "Re: Demo feedback"
    ///   "Sent Items - sam@example.com - Outlook"       -> "Sent"
    ///   "Your code is 123456 - sam@example.com - Gmail" -> nil (`TypedSecretScrubber.sensitiveSubject`)
    public static func web(_ raw: String, host: String) -> String? {
        let outlook = host.lowercased().hasPrefix("outlook.") || host.lowercased().contains(".outlook.")
        return clean(raw, dropTrailingAccount: outlook)
    }

    /// A Mail.app window title as kept, or nil (nothing worth keeping, or a sensitive subject: `mailAppKept`).
    ///   "Inbox — 1,234 messages, 5 unread"  -> "Inbox"
    ///   "Inbox – iCloud — 12 messages"      -> "Inbox"
    ///   "Inbox (3 messages, 1 unread)"      -> "Inbox"
    ///   "Re: Demo feedback"                 -> "Re: Demo feedback"
    ///   "New Message"                       -> "New message"
    public static func mailApp(_ raw: String) -> String? {
        var t = raw
        // Message, unread, draft and selection counts after a dash or in parentheses.
        let count = #"[\d.,\x{202F}\x{00A0} ]+\s+(?:messages?|unread|drafts?|selected|flagged|new)"#
        t = t.replacingOccurrences(of: #"\s*[—–-]\s*"# + count + #"(?:\s*,\s*"# + count + #")*\s*$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s*\(\s*"# + count + #"(?:\s*,\s*"# + count + #")*\s*\)"#, with: "", options: .regularExpression)
        guard let cleaned = clean(t, dropTrailingAccount: false) else { return nil }
        // "Inbox – iCloud": a folder followed by the account's name.
        for sep in separators {
            let parts = cleaned.components(separatedBy: sep)
            if parts.count == 2, let view = views[parts[0].lowercased().trimmingCharacters(in: .whitespaces)] { return view }
        }
        return cleaned
    }

    /// The shared cleaner. nil when nothing is left, or the subject is sensitive.
    static func clean(_ raw: String, dropTrailingAccount: Bool) -> String? {
        var t = raw.replacingOccurrences(of: "\u{200e}", with: "").replacingOccurrences(of: "\u{200f}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" - Google Chrome", " – Google Chrome"] where t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
        // Leading unread counter or dot: "(3) Inbox", "• Inbox".
        t = t.replacingOccurrences(of: #"^\(\d[\d,.]*\+?\)\s*"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^[•●]\s*"#, with: "", options: .regularExpression)
        var parts = [t]
        for sep in separators { parts = parts.flatMap { $0.components(separatedBy: sep) } }
        parts = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // Trailing product segments ("- Gmail", "- Outlook", a Workspace's "- Acme Mail").
        while parts.count > 1, let last = parts.last?.lowercased(), products.contains(last) || (last.hasSuffix(" mail") && last.count <= 40) {
            parts.removeLast()
        }
        if parts.count == 1, products.contains(parts[0].lowercased()) { return nil }
        // The account: Gmail and others show its address; everything from that segment on is account and product.
        if let i = parts.firstIndex(where: { address.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }), i > 0 {
            parts = Array(parts[..<i])
        } else if dropTrailingAccount, parts.count >= 2 {
            // Outlook names the account by its display name: "<view or subject> - <name> - Outlook".
            parts.removeLast()
        }
        var s = parts.joined(separator: " - ")
        // Unread counts anywhere: "Inbox (3)", "Inbox (1,234)", "(5 unread)", "[2]".
        for pattern in [#"\s*\(\d[\d,.]*\+?(?:\s+(?:unread|new))?(?:\s+messages?)?\)"#, #"\s*\[\d+\+?\]"#] {
            s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        // Any address left (a sender shown in a subject line, a lone account).
        s = address.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-–—|,;:").union(.whitespaces))
        guard !s.isEmpty, !ChromePageTitle.placeholders.contains(s.lowercased()), s.lowercased() != "loading" else { return nil }
        if let view = views[s.lowercased()] { return view }
        s = normalizedPrefixes(s)
        guard TypedSecretScrubber.sensitiveSubject(s) == nil else { return nil }
        let out = Privacy.clean(s, limit: limit)
        return out.isEmpty ? nil : out
    }

    /// "RE: RE: x" -> "Re: x", "FW: x" / "Fw: x" / "FWD: x" -> "Fwd: x". One prefix is kept: it says reply or forward.
    public static func normalizedPrefixes(_ s: String) -> String {
        var rest = s, first: String?
        while let r = rest.range(of: #"^\s*(re|aw|sv|fwd?|wg|tr)\s*(?:\[\d+\])?\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) {
            let tag = rest[r].trimmingCharacters(in: .whitespaces).lowercased()
            if first == nil { first = tag.hasPrefix("re") || tag.hasPrefix("aw") || tag.hasPrefix("sv") ? "Re: " : "Fwd: " }
            rest.removeSubrange(r)
        }
        guard let first, !rest.isEmpty else { return s.trimmingCharacters(in: .whitespaces) }
        return first + rest.trimmingCharacters(in: .whitespaces)
    }

    /// What a kept title says: a folder or view, or an email (its subject without Re:/Fwd:, and whether it is a reply or
    /// a forward). Views never name an email.
    public enum Kind: Equatable, Sendable { case view(String), email(subject: String, reply: Bool, forward: Bool) }
    public static func kind(_ kept: String) -> Kind? {
        let t = kept.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != TypedHistoryScrub.omittedTitle else { return nil }
        if let view = views[t.lowercased()] { return .view(view) }
        let n = normalizedPrefixes(t)
        if n.hasPrefix("Re: ") { return .email(subject: String(n.dropFirst(4)), reply: true, forward: false) }
        if n.hasPrefix("Fwd: ") { return .email(subject: String(n.dropFirst(5)), reply: false, forward: true) }
        return .email(subject: n, reply: false, forward: false)
    }

    // MARK: ingest and read

    /// Read time (`BrowserSafety`): an email page row's title may be shown only as `web` keeps it: no address in it and
    /// no sensitive subject. A raw tab title (an account address) or a code, password or bank subject hides the row.
    public static func keepable(_ title: String) -> Bool {
        address.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) == nil
            && TypedSecretScrubber.sensitiveSubject(title) == nil
    }

    /// Mail-app bundles whose window titles are email subjects.
    public static let mailApps: Set<String> = [SendRules.mailApp]
    /// Ingest (every record, `TypedHistoryScrub`, `clean` true) and read (`Privacy.sanitized`, `clean` false): a Mail
    /// window title cleaned (ingest only, so rows saved before keep their titles and notes), or the omitted-title marker
    /// for a sensitive subject; a Chrome email page row's title kept only when it still passes the subject rules (else
    /// the site only). Anything else is unchanged.
    public static func scrubbed(_ e: Evidence, clean: Bool = false) -> Evidence {
        guard !e.title.isEmpty, e.title != TypedHistoryScrub.omittedTitle else { return e }
        var out = e
        if mailApps.contains(e.bundle) {
            if TypedSecretScrubber.sensitiveSubject(e.title) != nil { out.title = TypedHistoryScrub.omittedTitle }
            else if clean, e.kind != "keyboard.text_input", let kept = mailApp(e.title) { out.title = kept }
            return out
        }
        if e.bundle == BrowserSafety.supportedBundle, e.browserVerification?.provider == BrowserSafety.pageProvider,
           let host = BrowserSites.host(of: e.url), BrowserSites.emailHost(host: host) {
            if TypedSecretScrubber.sensitiveSubject(e.title) != nil { out.title = "" }
        }
        return out
    }
}

// MARK: - Lines (cards and summaries)

/// email-1003: the lines cards and summaries use for email, from code-read facts only (titles, the compose adapter's
/// recipients and subject). Never the typed words; the body shows in the card's typed section while typing is on.
///   read     "Read 'Demo feedback' from Sam"   (from Sam only when a sender is known)
///   emailed  "Emailed Sam — 'Startup credits question'"
///   replied  "Replied to Sam's email 'Demo feedback'"
///   forward  "Forwarded 'Demo feedback' to Sam"
public enum EmailLines {
    static func quoted(_ s: String) -> String { "'" + s + "'" }
    static func possessive(_ name: String) -> String { name.hasSuffix("s") ? name + "'" : name + "'s" }
    public static func read(subject: String, from sender: String? = nil) -> String {
        guard let sender = sender?.trimmingCharacters(in: .whitespaces), !sender.isEmpty else { return "Read " + quoted(subject) }
        return "Read " + quoted(subject) + " from " + sender
    }
    /// The send line. `subject` without Re:/Fwd:; `to` the first recipient (nil: "someone" for a new email).
    public static func sent(to: String?, subject: String?, reply: Bool, forward: Bool) -> String {
        let who = to.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let about = subject.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        if reply {
            if let who, let about { return "Replied to \(possessive(who)) email " + quoted(about) }
            if let who { return "Replied to \(possessive(who)) email" }
            if let about { return "Replied to " + quoted(about) }
            return "Replied to an email"
        }
        if forward {
            if let about, let who { return "Forwarded " + quoted(about) + " to " + who }
            if let about { return "Forwarded " + quoted(about) }
            return who.map { "Forwarded an email to " + $0 } ?? "Forwarded an email"
        }
        let name = who ?? "someone"
        if let about { return "Emailed \(name) — " + quoted(about) }
        return "Emailed \(name)"
    }
    /// The send line from a typed row's facts: its window or page title (Mail: the compose window's subject; webmail:
    /// the kept page title), its recipient, and the compose adapter's facts when present.
    public static func sent(title: String, to: String?, facts: EmailComposeFacts? = nil) -> String {
        if let facts {
            return sent(to: facts.replyTo ?? facts.recipients.first ?? to, subject: facts.subject.map { EmailComposeAdapter.bareSubject($0) },
                        reply: facts.kind == .reply, forward: facts.kind == .forward)
        }
        if case .email(let subject, let reply, let forward)? = EmailTitle.kind(title), TypedSecretScrubber.sensitiveSubject(subject) == nil {
            return sent(to: to, subject: subject, reply: reply, forward: forward)
        }
        return sent(to: to, subject: nil, reply: false, forward: false)
    }
}
