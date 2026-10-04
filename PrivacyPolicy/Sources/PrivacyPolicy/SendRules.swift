import Foundation

// summaries/v3 (intent lines spec §3, §4): what kind of place a typed unit was typed in, and whether a send gesture
// was detected, decided by code at seal time. The model never decides whether something was sent. Everything here
// is metadata about the unit (bundle, host, field class, a composer label or window title code already read, the
// seal reason); the typed words are never an input, except the Mail To-field rule (`RecipientMemory`), which keeps
// one short name the person typed in a To field, as the spec allows.

/// The facts stored on a typed unit (`TypedUnitProvenance.surface/field/send/sendBy/to`).
public struct SendFacts: Equatable, Sendable {
    /// ai | aiTool | email | text | chat | social | search | form | code | writing | other
    public var surface: String
    /// to | subject | body | message | search | oneLine | textArea | unknown
    public var field: String
    /// detected | none | unknown. Never "sent": that stays receipt-only.
    public var send: String
    /// return | commandReturn | mailSend | button, only when `send == "detected"`. `button` comes only from a proven
    /// composer control activation (`buttonSend`, fix/chrome-capture), never from a seal reason.
    public var sendBy: String?
    /// A recipient or place code read: a Messages title ("Mom", "Family"), a chat composer's channel ("#general") or
    /// person ("sam"), or a name from Mail's To field. A value starting with "#" is a channel (an `in`, not a `to`).
    public var to: String?
    public init(surface: String, field: String, send: String, sendBy: String? = nil, to: String? = nil) {
        self.surface = surface; self.field = field; self.send = send; self.sendBy = sendBy; self.to = to
    }
}

public enum SendRules {
    public static let surfaces: Set<String> = ["ai", "aiTool", "email", "text", "chat", "social", "search", "form", "code", "writing", "other"]
    public static let fields: Set<String> = ["to", "subject", "body", "message", "search", "oneLine", "textArea", "unknown"]

    // MARK: surface

    static let aiApps: Set<String> = ["com.anthropic.claudefordesktop", "com.openai.codex", "com.openai.chat", "ai.perplexity.mac"]
    static let searchApps: Set<String> = ["com.apple.Spotlight", "com.raycast.macos"]
    static let terminals: Set<String> = ["com.apple.Terminal", "com.mitchellh.ghostty", "com.googlecode.iterm2"]
    /// claude/cc-label-1003: a terminal app, whose Return runs a line (a command, or a prompt to an AI tool running there).
    public static func terminal(bundle: String) -> Bool { terminals.contains(bundle) }
    static let codeApps: Set<String> = ["com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "dev.warp.Warp-Stable"]
    static let writingApps: Set<String> = ["com.apple.Notes", "com.apple.TextEdit", "com.apple.Pages", "com.apple.iWork.Pages", "com.microsoft.Word", "notion.id", "md.obsidian"]
    static let textApps: Set<String> = ["com.apple.MobileSMS"]
    public static let mailApp = "com.apple.mail"
    static let emailApps: Set<String> = [mailApp, "com.microsoft.Outlook"]
    static let chatApps: Set<String> = ["com.tinyspeck.slackmacgap", "com.hnc.Discord", "net.whatsapp.WhatsApp"]
    /// Hosts, most specific first where it matters (mail.google.com before google.com).
    static let hostSurfaces: [(String, String)] = [
        ("claude.ai", "ai"), ("chatgpt.com", "ai"), ("gemini.google.com", "ai"), ("perplexity.ai", "ai"),
        ("mail.google.com", "email"), ("outlook.live.com", "email"), ("outlook.office.com", "email"), ("outlook.office365.com", "email"),
        ("outlook.cloud.microsoft", "email"), ("icloud.com", "email"),
        ("app.slack.com", "chat"), ("discord.com", "chat"), ("web.whatsapp.com", "chat"),
        ("linkedin.com", "social"), ("x.com", "social"), ("twitter.com", "social"), ("threads.net", "social"), ("bsky.app", "social"),
        ("reddit.com", "social"),
        ("google.com", "search"), ("bing.com", "search"), ("duckduckgo.com", "search"), ("search.brave.com", "search"),
        ("kagi.com", "search"), ("search.yahoo.com", "search"), ("ecosia.org", "search"),
    ]
    /// Chat hosts whose composer label may name the channel or person ("Message #general", "Reply to Sam").
    public static let chatHosts: Set<String> = ["app.slack.com", "discord.com"]

    static func normalHost(_ raw: String?) -> String {
        var h = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        if let colon = h.firstIndex(of: ":") { h = String(h[..<colon]) }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }
    static func under(_ host: String, _ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }

    /// The AI an ask went to, by app or site: "Claude", "ChatGPT" (the ChatGPT app is `com.openai.codex`), nil when unknown.
    public static func aiName(bundle: String, host: String? = nil) -> String? {
        switch bundle {
        case "com.anthropic.claudefordesktop": return "Claude"
        case "com.openai.codex", "com.openai.chat": return "ChatGPT"
        case "ai.perplexity.mac": return "Perplexity"
        default: break
        }
        let h = normalHost(host)
        for (domain, name) in [("claude.ai", "Claude"), ("chatgpt.com", "ChatGPT"), ("chat.openai.com", "ChatGPT"),
                               ("gemini.google.com", "Gemini"), ("perplexity.ai", "Perplexity")] where under(h, domain) { return name }
        return nil
    }
    /// The AI tool a terminal's title names ("Claude Code", "Codex"), nil when none.
    public static func aiToolName(_ title: String) -> String? {
        let words = title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if words.contains("claude") { return "Claude Code" }
        if words.contains("codex") { return "Codex" }
        return nil
    }
    /// Claude Code or Codex running in a terminal: the window title names the tool (device check pending, spec §3).
    public static func aiToolTitle(_ title: String) -> Bool {
        let words = title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return words.contains("claude") || words.contains("codex")
    }

    /// Where a unit was typed. `host` only for website typing (and apps showing a web page); `field` is the class
    /// (`fieldClass`), used for search boxes and one-line forms on other websites.
    /// claude/cc-label-1003: `terminalTool` is the AI tool capture knows the terminal window runs (`TerminalToolMemory`:
    /// its title showed the tool's glyph, or the tool's process with a prompt-shaped line); a line typed there is a prompt
    /// to it ("aiTool"), as when the title names the tool. "" or nil: the title alone decides.
    public static func surface(bundle: String, host: String? = nil, title: String = "", field: String = "unknown", terminalTool: String? = nil) -> String {
        let h = normalHost(host)
        if !h.isEmpty && !aiApps.contains(bundle) && !emailApps.contains(bundle) && !chatApps.contains(bundle) && !writingApps.contains(bundle) {
            // A verified search box describes the action more precisely than the site's category.
            // A search-engine host alone cannot prove that this field submits a web search.
            if field == "search" { return "search" }
            for (domain, surface) in hostSurfaces where under(h, domain) && surface != "search" { return surface }
            if field == "oneLine" { return "form" }
            return "other"
        }
        if aiApps.contains(bundle) { return "ai" }
        if searchApps.contains(bundle) { return "search" }
        if terminals.contains(bundle) { return aiToolTitle(title) || !(terminalTool ?? "").isEmpty ? "aiTool" : "code" }
        if codeApps.contains(bundle) { return "code" }
        if writingApps.contains(bundle) { return "writing" }
        if textApps.contains(bundle) { return "text" }
        if emailApps.contains(bundle) { return "email" }
        if chatApps.contains(bundle) { return "chat" }
        return "other"
    }

    // MARK: field

    static let toLabels: Set<String> = ["to", "to recipients", "recipients", "add recipients", "cc", "bcc"]
    static let subjectLabels: Set<String> = ["subject", "add a subject"]
    static let bodyLabels: Set<String> = ["message body", "body"]
    static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while let last = s.last, [".", "…", ":"].contains(last) { s.removeLast() }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// The field class from its role and labels (AX title, description, placeholder; never its contents).
    /// `composer`: the site's composer rule matched (a message box). `search`: the page or box is a search box.
    public static func fieldClass(role: String, labels: [String] = [], composer: Bool = false, search: Bool = false) -> String {
        let cleaned = labels.map(clean)
        // Role/verified search metadata wins over incidental labels such as "To" or "Subject".
        if search || role == "AXSearchField" { return "search" }
        if cleaned.contains(where: toLabels.contains) { return "to" }
        if cleaned.contains(where: subjectLabels.contains) { return "subject" }
        if cleaned.contains(where: bodyLabels.contains) { return "body" }
        if cleaned.contains(where: { $0 == "search" || $0.hasPrefix("search ") }) { return "search" }
        if composer { return "message" }
        switch role {
        case "AXTextArea": return "textArea"
        case "AXTextField", "AXComboBox": return "oneLine"
        default: return "unknown"
        }
    }

    // MARK: place

    static let placePrefixes = ["message ", "reply to ", "write to ", "send to ", "text to "]
    /// A chat composer's label, only on a chat host: "Message #general" -> "#general", "Message @sam" -> "sam",
    /// "Message Sam Lee" / "Reply to Sam" -> the name. Anything longer than 40 characters, or with digits or "@" left
    /// inside, is dropped.
    public static func composerPlace(labels: [String], host: String?) -> String? {
        let h = normalHost(host)
        guard chatHosts.contains(where: { under(h, $0) }) else { return nil }
        for raw in labels {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            guard let prefix = placePrefixes.first(where: { lower.hasPrefix($0) }) else { continue }
            var rest = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            while let last = rest.last, [".", "…", ":"].contains(last) { rest.removeLast() }
            if rest.hasPrefix("@") { rest.removeFirst() }
            guard (2...40).contains(rest.count), !rest.contains("@"), !rest.contains(where: \.isNumber) || rest.hasPrefix("#") else { continue }
            if rest.hasPrefix("#") { guard rest.count >= 2, !rest.contains(" ") else { continue } }
            return rest
        }
        return nil
    }
    static let placeholderTitles: Set<String> = ["messages", "new message", "untitled", ""]
    /// Messages: the window title names the conversation unless it is the app's own name. A title that looks like a
    /// phone number or an email address is never kept (rule 7: no numbers or addresses in notes).
    /// claude/catchup-1003: Messages shows a contact Siri only suggests as "Maybe: Name". The prefix is Siri's guess
    /// marker, never part of the name.
    public static func siriSuggestion(_ name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = t.range(of: #"^Maybe:\s*"#, options: .regularExpression), r.upperBound < t.endIndex else { return t }
        return String(t[r.upperBound...])
    }
    /// claude/messages2-1003 (owner 10/3: "the card knows who"): a Messages conversation that has no contact name is
    /// titled by its phone number or email address, and the Conversations panel already shows it. That handle names the
    /// conversation in cards, What happened and summaries, formatted for reading ("+1 (646) 555-0100"); nil for anything
    /// else (a name is `conversationName`'s; the app's own windows name nobody). Read only from the typed row's own
    /// window title (the composer's window at the key), never from a nearby row.
    public static func messagesHandle(_ raw: String) -> String? {
        var t = siriSuggestion(raw)
        for suffix in [" — Messages", " - Messages"] where t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 60 else { return nil }
        if ContactShape.email(t) { return t }
        guard t.allSatisfy({ $0.isASCII && ($0.isNumber || " +()-.".contains($0)) }) else { return nil }
        let d = Array(t.filter(\.isNumber))
        guard (7...15).contains(d.count), !t.dropFirst().contains("+") else { return nil }
        func s(_ r: Range<Int>) -> String { String(d[r]) }
        // North American numbers read as Messages shows them; any other number keeps its own spacing.
        if d.count == 11, d[0] == "1" { return "+1 (\(s(1..<4))) \(s(4..<7))-\(s(7..<11))" }
        if d.count == 10, !t.hasPrefix("+") { return "(\(s(0..<3))) \(s(3..<6))-\(s(6..<10))" }
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    /// claude/messages2-1003: who a Messages conversation is, from its window title: its name, else its phone number or
    /// email address (`messagesHandle`); nil for New Message and the app's own windows.
    public static func messagesConversation(_ title: String) -> String? {
        conversationName(title) ?? messagesHandle(title)
    }
    public static func messagesPlace(title: String) -> String? {
        var t = siriSuggestion(title)
        for suffix in [" — Messages", " - Messages"] where t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces) }
        guard !placeholderTitles.contains(t.lowercased()), t.count <= 60, !t.contains("@") else { return nil }
        let digits = t.filter(\.isNumber).count
        guard digits < 3 else { return nil }
        return t
    }

    /// Messages' own labels that never name a conversation (the selected row and the header can show them).
    static let conversationLabels: Set<String> = ["imessage", "text message", "sms", "rcs", "delivered", "read", "sent", "details",
        "new message", "messages", "today", "yesterday", "now", "info", "facetime", "to:"]
    /// fix/typing-e2e: a conversation's name read from Messages' conversation list when the window title is only the
    /// app's name (`messagesPlace` rules, then: at most 5 words, no sentence ending, not a time, a date or one of
    /// Messages' own labels).
    public static func conversationName(_ raw: String) -> String? {
        guard let t = messagesPlace(title: raw) else { return nil }
        let lower = t.lowercased()
        guard !conversationLabels.contains(lower), t.split(separator: " ").count <= 5, t.count <= 40,
              !t.contains(where: { "?!.…:\n\"“”".contains($0) }) else { return nil }
        let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        guard !weekdays.contains(lower), t.range(of: #"^\d{1,2}:\d{2}( ?[ap]m)?$"#, options: [.regularExpression, .caseInsensitive]) == nil,
              t.range(of: #"^\d{1,2}/\d{1,2}(/\d{2,4})?$"#, options: .regularExpression) == nil else { return nil }
        return t
    }
    /// The selected conversation row's first text, when it names the conversation (`conversationName`), else nil. Only
    /// the first: a row that starts with a phone number or an address names nobody, and the texts after the name (the
    /// time, the last message's preview) are never taken instead.
    public static func conversationName(rowTexts: [String]) -> String? {
        guard let first = rowTexts.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
        return conversationName(first)
    }

    // MARK: send

    /// The §3 decision table. Seals other than a send key are never a send (the run's last piece decides).
    /// notes-quality + fix/typing-e2e: on a social site (X, Threads, Bluesky, Reddit, LinkedIn) Command-Return posts what is
    /// in the composer; Return is a new line. `host` is kept for callers; every social host follows the same rule.
    public static func send(surface: String, field: String, seal: SealReason, bundle: String = "", host: String? = nil) -> (send: String, sendBy: String?) {
        switch surface {
        // Owner decision 2026-10-02 (live matrix rows 1-2): Return in a terminal runs the line, so a terminal unit sealed
        // by Return is a command that was run ("submitted", cards say "Ran a command"), not a draft. Editors stay none.
        case "code" where terminals.contains(bundle) && seal == .submit: return ("detected", "return")
        case "code", "writing": return ("none", nil)
        // fix/typing-e2e (L4): Command-Return posts on X, Threads, Bluesky, Reddit and LinkedIn; anything else there
        // (Return is a new line in a post box, any click) stays unknown. A proven click on the composer's own Post
        // button is decided after the seal, by `buttonSend` (fix/chrome-capture), never from a pointer seal here.
        // A search, To or subject box there is never a post.
        case "social": return seal == .submitChord && !["to", "subject", "search"].contains(field) ? ("detected", "commandReturn") : ("unknown", nil)
        case "form", "other": return ("unknown", nil)   // forms never claim a send
        default: break
        }
        switch (surface, seal) {
        case ("ai", .submit), ("aiTool", .submit): return ("detected", "return")
        // A Return can select a recipient in Messages. Only a positively
        // classified body/message field establishes a send gesture, never
        // delivery; an unlabelled single-line field stays a draft/unknown.
        // messages-1003 (owner, 2026-10-03): in Messages a Return alone is never a send, whatever the field. A send is
        // Return followed by the composer emptying, confirmed by a fresh Accessibility read after the key
        // (`messagesClearedSend`); until then the unit is a draft with an unknown send. Never inferred from time.
        case ("text", .submit): return ("unknown", nil)
        case ("chat", .submit): return ["to", "subject", "search"].contains(field) ? ("unknown", nil) : ("detected", "return")
        case ("search", .submit): return ("detected", "return")
        case ("email", .mailSend): return bundle == mailApp ? ("detected", "mailSend") : ("unknown", nil)
        // claude/int-1003 (email-compose/v1, email-1003's recommendation): Command-Return in webmail is a send only once
        // the compose closes (`EmailComposeAdapter.send`, within `closeWindow`): a missing recipient or a blocked send
        // leaves it open. Until then the unit is a draft; the Chrome route's re-reads mark it (`markComposerSent`,
        // `.commandReturn` + `.composerClosed`). In Mail it is nothing.
        case ("email", .submitChord): return ("unknown", nil)
        default: return ("unknown", nil)   // Return in Mail (a new line or a contact pick), idle, size, Tab, clicks, ...
        }
    }

    /// messages-1003: the send a confirmed clear proves. Plain Return (no Shift or Option: those insert a new line and
    /// never seal) sealed a Messages unit, and a fresh Accessibility read after it found the same window's composer empty.
    /// Only a message field qualifies: a To, search or subject box empties on Return without sending anything.
    /// The Messages case of the generic model (`ComposeSend.confirmedSend` with `.fieldCleared`).
    public static func messagesClearedSend(surface: String, field: String, seal: String) -> (send: String, sendBy: String?) {
        guard surface == "text", seal == SealReason.submit.rawValue,
              let f = ComposeSend.confirmedSend(surface: surface, field: field, gesture: .returnKey, confirmation: .fieldCleared) else { return ("unknown", nil) }
        return (f.send, f.sendBy)
    }
    static let messagesComposerLabels: Set<String> = ["message", "imessage", "text message", "sms", "rcs", "sms/mms", "imessage message", "rcs message", "text message • sms", "text message · sms"]
    static let messagesSearchSubroles: Set<String> = ["AXSearchField"]
    /// messages-1003: the class of a field in Messages, from metadata only: its role, subrole and labels (description,
    /// placeholder, help, identifier; never its value) and whether the window title names a conversation
    /// (`conversationName`). Live 2026-10-03: Messages' composer is a single-line AXTextField, so the role alone
    /// ("oneLine") said nothing and every sent text was stored as a draft with no recipient.
    /// - search: a search subrole or a "search" label (the sidebar's search box).
    /// - to: a To/recipient label (New Message's recipient box).
    /// - message: a composer label ("iMessage", "Text Message", "RCS", "Message"), or an unlabelled text box in a window
    ///   whose title names a conversation (an open conversation has no To box; its only other box is the search box).
    /// - otherwise the role's class (`fieldClass`): a New Message window with no labels proves nothing (B2).
    public static func messagesField(role: String, subrole: String, labels: [String], title: String) -> String {
        let cleaned = labels.map(clean).filter { !$0.isEmpty }
        if messagesSearchSubroles.contains(subrole) || role == "AXSearchField" || cleaned.contains(where: { $0 == "search" || $0.hasPrefix("search ") || $0.hasSuffix(" search") }) { return "search" }
        if cleaned.contains(where: { toLabels.contains($0) || $0 == "recipient" || $0.hasPrefix("to:") }) { return "to" }
        if cleaned.contains(where: { messagesComposerLabels.contains($0) || $0.hasPrefix("imessage") || $0.hasPrefix("text message") || $0.hasPrefix("rcs") }) { return "message" }
        guard ["AXTextField", "AXTextArea"].contains(role) else { return fieldClass(role: role) }
        if cleaned.isEmpty, conversationName(title) != nil { return "message" }
        return fieldClass(role: role, labels: labels)
    }

    /// messages-1003: whether a new focused element in the same Messages window is the same composer as the previous
    /// one: same role, subrole and labels, and not a search or To box. Messages replaces its composer's Accessibility
    /// element while the person types (live 2026-10-03: "wanna me" | "et us there?", sealed "focus" with no input
    /// between); the words stay in the box, so they stay one unit.
    public static func messagesSameField(old: (role: String, subrole: String, labels: [String]), new: (role: String, subrole: String, labels: [String])) -> Bool {
        old.role == new.role && old.subrole == new.subrole && old.labels == new.labels
            && !["search", "to"].contains(messagesField(role: new.role, subrole: new.subrole, labels: new.labels, title: ""))
    }

    /// fix/chrome-capture: a click that DayDream proved activated the composer's own submit control (X's Post or
    /// Reply button in the composer the words were typed in: `BrowserSubmitControl`) after the unit was sealed by that
    /// click or by a pause. Only a social site's message box qualifies; a search, To or subject box, and every other
    /// surface, stays unknown (their buttons are not proven: a coverage limit, not a claim). A detected send is a
    /// send gesture, never a delivery: "sent" stays receipt-only.
    public static func buttonSend(surface: String, field: String) -> (send: String, sendBy: String?) {
        surface == "social" && !["to", "subject", "search"].contains(field) ? ("detected", "button") : ("unknown", nil)
    }

    /// Everything stored on the unit, in one call. `title` is the typed row's own window title (never the last window
    /// change); `composerPlace` comes from `composerPlace(labels:host:)`; `recipient` from `RecipientMemory`.
    public static func facts(bundle: String, host: String? = nil, title: String = "", field rawField: String = "unknown",
                             composerPlace: String? = nil, recipient: String? = nil, seal: SealReason, terminalTool: String? = nil) -> SendFacts {
        let field = fields.contains(rawField) ? rawField : "unknown"
        let surface = surface(bundle: bundle, host: host, title: title, field: field, terminalTool: terminalTool)
        var storedField = field
        if surface == "email", field == "message" { storedField = "body" }
        if surface == "text", field == "textArea" { storedField = "message" }
        let decision = send(surface: surface, field: storedField, seal: seal, bundle: bundle, host: host)
        var to: String?
        switch surface {
        case "text": to = ["message", "body"].contains(storedField) ? conversationName(title) : nil
        case "chat": to = composerPlace
        case "email": to = recipient
        // fix/typing-e2e: an ask goes to the AI app or site ("Claude", "ChatGPT"), so notes can say who was asked.
        case "ai": to = aiName(bundle: bundle, host: host)
        case "aiTool": to = aiToolName(title) ?? terminalTool.flatMap { $0.isEmpty ? nil : $0 }
        default: to = nil
        }
        return SendFacts(surface: surface, field: storedField, send: decision.send, sendBy: decision.sendBy, to: to)
    }
}

/// The Mail To-field rule (spec §4): a To unit that ended with Tab or a comma (`focusKey`) and is one whole name of
/// 3+ letters (at most two words, no "@", no digits) is remembered for later email units in the same window for
/// 30 minutes. A unit ended by Return or a click picked a suggestion from a prefix, so it names nobody.
public final class RecipientMemory {
    public static let lifetime: UInt64 = 30 * 60 * 1_000_000_000
    private var names: [String: (name: String, at: UInt64)] = [:]
    private var edits: [String: UInt64] = [:]
    public init() {}
    public static func name(fromToField text: String, seal: SealReason) -> String? {
        guard seal == .focusKey else { return nil }
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = t.last, [",", ";"].contains(last) { t.removeLast() }
        let words = t.split(separator: " ")
        guard (1...2).contains(words.count), !t.contains("@"),
              words.allSatisfy({ w in w.count >= 3 && w.allSatisfy { $0.isLetter || $0 == "'" || $0 == "-" } && w.first!.isLetter }) else { return nil }
        return t
    }
    /// Metadata-authorized changes invalidate a previous To even if no text is kept.
    /// The watermark also prevents an older parked To from restoring that authority.
    public func editedTo(window: String, now: UInt64) {
        edits = edits.filter { now < $0.value || now - $0.value <= Self.lifetime }
        if let previous=edits[window],now < previous {return}
        edits[window] = now
        names[window] = nil
    }
    /// A mutation without usable focus proof cannot preserve old authority.
    /// Keep a cutoff for every known scope so pending To units cannot restore it.
    public func editedUnknown(now: UInt64) {
        for window in Set(edits.keys).union(names.keys) {editedTo(window:window,now:now)}
    }
    /// Call for every email unit, in order. Returns the recipient to store on this unit (nil for the To unit itself).
    public func observe(window: String, field: String, text: String, seal: SealReason, now: UInt64, lastEditedAt: UInt64? = nil) -> String? {
        names = names.filter { now >= $0.value.at && now - $0.value.at <= Self.lifetime }
        if field == "to" {
            if let cutoff = edits[window], (lastEditedAt ?? 0) < cutoff { return nil }
            names[window] = nil
            if let name = Self.name(fromToField: text, seal: seal) { names[window] = (name, now) }
            return nil
        }
        return names[window]?.name
    }
    public func forget() { names.removeAll(); edits.removeAll() }
}

/// `pasted` (spec §2): the unit a paste sealed, and the next unit typed in the same field. Paste itself is never
/// captured; this only says that the unit's words are part of a message that had pasted text in it.
public final class PasteMemory {
    private var field: String?
    public init() {}
    public func observe(field focus: String, seal: SealReason) -> Bool {
        let after = field == focus
        field = seal == .paste ? focus : nil
        return seal == .paste || after
    }
    public func forget() { field = nil }
}
