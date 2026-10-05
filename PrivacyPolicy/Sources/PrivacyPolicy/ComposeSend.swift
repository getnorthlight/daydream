import Foundation

// compose-send/v1 (messages-1003, owner 2026-10-03): ONE "compose and send" model for every surface.
//
//  Draft   text typed into a composer (a typed unit).
//  Send    a submit gesture (`ComposeGesture`) AND a confirmation (`ComposeConfirmation`) seen within
//          `ComposeSend.confirmWindow` of it. A gesture with no confirmation stays a draft; time alone never confirms.
//  Text    the composer's own value read at the gesture (`TypingSession.sentValue`), the keys' reconstruction only
//          as a fallback.
//  Where   a per-surface identity adapter (`ComposeIdentity`) reads who or what it went to, and what it replied to
//          (`ComposeContext`), from metadata the capture layer already reads (window and page titles, composer labels,
//          the route). An unrecognised composer still gets draft/sent, with no destination.
//  Output  one verb line for every surface (`ComposeSend.line`): "Sent to Jamie", "Replied to Ada's post on X",
//          "Posted on X", "Emailed Sam — Pricing", "Asked ChatGPT", "Commented on r/swift", "Messaged #eng",
//          "Ran a command", "Typed to Jamie". Cards, search and summaries use these verbs.
//
// Everything here is pure: no Accessibility, no store. The privacy gates are unchanged and run before any of it.

/// What submitted the composer. Raw values are what `TypedUnitProvenance.sendBy` stores.
public enum ComposeGesture: String, Sendable, CaseIterable {
    case returnKey = "return", commandReturn, button, mailSend
}

/// What proved the gesture sent something. Raw values are what `TypedUnitProvenance.confirm` stores.
public enum ComposeConfirmation: String, Sendable, CaseIterable {
    /// The same composer (same window, same field class) read empty after the gesture.
    case fieldCleared
    /// The composer (a modal, a reply box) closed: focus left it and it no longer exists.
    case composerClosed
    /// The page's route changed (a post's own URL after posting, a compose modal's route closing).
    case routeChanged
}

/// The kind of a typed unit, for every surface. Raw values are stable API (cards, search, summaries).
public enum ComposeKind: String, Sendable, CaseIterable {
    case draft          // typed, not sent (or not proven sent)
    case sentMessage    // Messages / chat to a person ("Sent to Jamie", "Messaged #eng")
    case posted         // a new post ("Posted on X")
    case replied        // a reply to a post or message ("Replied to Ada's post on X")
    case quoted         // a quote post ("Quoted Ada's post on X")
    case commented      // a comment ("Commented on r/swift")
    case emailed        // an email ("Emailed Sam — Pricing")
    case asked          // an AI ask ("Asked ChatGPT")
    case searched       // a search ("Searched for …" is the summary's; the line is "Searched")
    case ran            // a terminal command ("Ran a command")
    case sent           // any other confirmed composer (no destination known)
}

/// Who or what a unit went to. Every field is metadata code read; nil when unknown. Never the typed words.
public struct ComposeDestination: Equatable, Sendable {
    /// A person, conversation or group ("Jamie", "Family"), a chat name ("Trip planning"), a channel ("#eng").
    public var name: String?
    /// A handle, without "@" ("ada").
    public var handle: String?
    /// A community ("swift" for r/swift).
    public var community: String?
    /// An email subject.
    public var subject: String?
    /// The surface's display name ("X", "Reddit", "ChatGPT", "Messages").
    public var service: String?
    public init(name: String? = nil, handle: String? = nil, community: String? = nil, subject: String? = nil, service: String? = nil) {
        self.name = name; self.handle = handle; self.community = community; self.subject = subject; self.service = service
    }
}

/// What a reply, comment or quote answered: the parent post or message, from the page title or Accessibility at the
/// gesture. `excerpt` is at most `ComposeSend.contextLimit` characters.
public struct ComposeContext: Equatable, Sendable {
    /// The parent's author as shown ("Ada"), or nil.
    public var author: String?
    /// The parent's text or title, trimmed ("Small tools beat big frameworks for most side projects…").
    public var excerpt: String?
    public init(author: String? = nil, excerpt: String? = nil) { self.author = author; self.excerpt = excerpt }
    public var isEmpty: Bool { (author ?? "").isEmpty && (excerpt ?? "").isEmpty }
}

/// The decided outcome of one typed unit.
public struct ComposeOutcome: Equatable, Sendable {
    public var kind: ComposeKind
    public var destination: ComposeDestination
    public var context: ComposeContext
    /// claude/messages2-1003: the send gesture that sealed the unit (Return for a Messages text), whether or not a send
    /// was confirmed; nil when a pause, click or switch sealed it (a piece of a message, not a whole one).
    public var sealedBy: ComposeGesture?
    public init(kind: ComposeKind, destination: ComposeDestination = .init(), context: ComposeContext = .init(), sealedBy: ComposeGesture? = nil) {
        self.kind = kind; self.destination = destination; self.context = context; self.sealedBy = sealedBy
    }
}

public enum ComposeSend {
    public static let version = "compose-send/v1"
    /// Re-reads after a gesture, seconds from it. A confirmation after the last one proves nothing.
    public static let confirmChecks: [Double] = [0.12, 0.35, 0.8]
    public static var confirmWindow: Double { confirmChecks.last ?? 0 }
    /// Longest replied-to excerpt kept.
    public static let contextLimit = 80

    /// Surfaces whose composers are confirmed by a fresh read after the gesture. Code and writing never send (an editor
    /// or a note does not empty on Return); terminals are decided by Return alone (`SendRules.send`, "Ran a command");
    /// search boxes submit by Return (`SendRules.send`).
    static let confirmable: Set<String> = ["text", "chat", "social", "email", "ai", "other", "form"]
    /// Field classes that empty on a gesture without sending anything (picking a recipient, a search, a subject).
    static let notComposers: Set<String> = ["to", "subject", "search"]

    /// Whether a gesture on this unit is confirmed by a read after it (and so may become a send).
    public static func confirmable(surface: String, field: String, gesture: ComposeGesture) -> Bool {
        guard confirmable.contains(surface), !notComposers.contains(field) else { return false }
        // Messages (B2): only a proven message box. New Message's unlabelled To box empties on Return too.
        if surface == "text", !["message", "body", "textArea"].contains(field) { return false }
        switch gesture {
        case .returnKey, .commandReturn, .button: return true
        case .mailSend: return surface == "email"
        }
    }

    /// The send facts a confirmed gesture gives (`TypedUnitProvenance.send/sendBy/confirm`), or nil when it can't.
    /// Shift-Return and Option-Return never reach here: they insert a new line (`TypingKeyMap`).
    public static func confirmedSend(surface: String, field: String, gesture: ComposeGesture, confirmation: ComposeConfirmation?) -> (send: String, sendBy: String, confirm: String)? {
        guard let confirmation, confirmable(surface: surface, field: field, gesture: gesture) else { return nil }
        return ("detected", gesture.rawValue, confirmation.rawValue)
    }

    /// Seal reasons a click on a send button leaves on the unit it ended (the click itself, or a pause before it).
    public static let buttonSeals: Set<String> = ["pointer", "idle", "focus"]
    /// The gesture a seal reason stands for, when it is one.
    public static func gesture(seal: String, sendBy: String? = nil) -> ComposeGesture? {
        if let sendBy, let g = ComposeGesture(rawValue: sendBy) { return g }
        switch seal {
        case "submit": return .returnKey
        case "submitChord": return .commandReturn
        case "mailSend": return .mailSend
        default: return nil
        }
    }

    // MARK: outcome

    /// The outcome of a unit from its stored facts: `surface`, `field`, `send` ("detected" = sent), `sendBy`,
    /// `sendControl` (a button's name: "post" | "reply" | "post all" | "comment" | "send" | "tweet"), `to` (the
    /// destination name code read), and the identity adapter's destination and context.
    public static func outcome(surface: String, field: String, send: String?, sendBy: String? = nil, sendControl: String? = nil,
                              to: String? = nil, destination: ComposeDestination = .init(), context: ComposeContext = .init()) -> ComposeOutcome {
        var d = destination
        if d.name == nil, let to, !to.isEmpty { d.name = to }
        guard send == "detected" else { return ComposeOutcome(kind: .draft, destination: d, context: context) }
        let control = (sendControl ?? "").lowercased()
        let kind: ComposeKind
        switch surface {
        case "code": kind = .ran
        case "ai", "aiTool": kind = .asked
        case "search": kind = .searched
        case "email": kind = .emailed
        case "text", "chat": kind = .sentMessage
        case "social":
            // A community site (Reddit): a comment answers a post; anything else there is a new post.
            if control == "quote" { kind = .quoted }
            else if d.community != nil { kind = control == "comment" || !context.isEmpty ? .commented : .posted }
            else if control == "reply" || !context.isEmpty || d.handle != nil { kind = .replied }
            else { kind = .posted }
        default: kind = .sent
        }
        return ComposeOutcome(kind: kind, destination: d, context: context)
    }

    // MARK: lines

    /// The verb line for an outcome. `service` defaults to the destination's service.
    public static func line(_ o: ComposeOutcome) -> String {
        let d = o.destination, service = d.service ?? ""
        let name = d.name.flatMap { $0.isEmpty ? nil : $0 }
        let author = o.context.author.flatMap { $0.isEmpty ? nil : $0 }
        let handle = d.handle.flatMap { $0.isEmpty ? nil : "@" + $0 }
        let on = service.isEmpty ? "" : " on " + service
        switch o.kind {
        case .draft:
            // claude/dayeval-1005 (owner 10/05): never "draft" or "not sent"; most of them were sent.
            if let name { return "Typed to \(name)" }
            return service.isEmpty ? "Typed" : "Typed in \(service)"
        case .sentMessage:
            if let name { return name.hasPrefix("#") ? "Messaged \(name)" : "Sent to \(name)" }
            return "Sent to someone"
        case .posted: return "Posted" + on
        case .replied:
            if let author { return "Replied to \(possessive(author)) post" + on }
            if let handle { return "Replied to \(handle)" + on }
            if let name { return "Replied to \(name)" + on }
            return "Replied" + on
        case .quoted:
            if let author { return "Quoted \(possessive(author)) post" + on }
            return "Quoted a post" + on
        case .commented:
            if let c = d.community { return "Commented on r/\(c)" }
            if let author { return "Commented on \(possessive(author)) post" + on }
            return "Commented" + on
        case .emailed:
            let who = name ?? "someone"
            if let s = d.subject, !s.isEmpty { return "Emailed \(who) — \(s)" }
            return "Emailed \(who)"
        case .asked:
            return "Asked " + (name ?? (service.isEmpty ? "an AI" : service))
        case .searched: return "Searched" + on
        case .ran: return "Ran a command"
        case .sent: return name.map { "Sent to \($0)" } ?? ("Sent" + (service.isEmpty ? "" : " in " + service))
        }
    }
    /// The muted line under a reply's block: `on: “<excerpt>”`, nil without an excerpt.
    public static func contextLine(_ c: ComposeContext) -> String? {
        guard let e = c.excerpt.map(clipContext), !e.isEmpty else { return nil }
        return "on: \u{201C}\(e)\u{201D}"
    }
    static func possessive(_ name: String) -> String { name.hasSuffix("s") ? name + "'" : name + "'s" }
    /// An excerpt clipped to `contextLimit` characters at a word boundary, with an ellipsis when clipped.
    public static func clipContext(_ raw: String) -> String {
        let t = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > contextLimit else { return t }
        var head = String(t.prefix(contextLimit - 1))
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) > contextLimit / 2 { head = String(head[..<space]) }
        while let last = head.last, ",.;:".contains(last) || last == " " { head.removeLast() }
        return head + "\u{2026}"
    }
}

/// Per-surface identity adapters: who or what a unit went to and what it replied to, from metadata only (a window or
/// page title, composer labels, the page's path). Never the typed words. Each returns empty values when unsure.
public enum ComposeIdentity {
    /// Messages: the conversation name from the window title (`SendRules.conversationName`). The conversation is the
    /// context of a reply; no excerpt.
    public static func messages(title: String) -> (ComposeDestination, ComposeContext) {
        (ComposeDestination(name: SendRules.conversationName(title), service: "Messages"), ComposeContext())
    }

    /// X: a status page's title is `<Name> on X: "<text>" / X`. On a status page (path `/<handle>/status/<id>`), a
    /// reply's parent is that post: author, excerpt and the handle from the path. Composer labels "Post your reply" or
    /// "Replying to @h" mark a reply; a home or compose page is a new post.
    public static func x(pageTitle: String, path: String = "", labels: [String] = []) -> (ComposeDestination, ComposeContext, reply: Bool) {
        var d = ComposeDestination(service: "X"), c = ComposeContext()
        let parts = path.split(separator: "/").map(String.init)
        let statusPage = parts.count >= 3 && parts[1] == "status"
        if statusPage, !["i", "home", "compose"].contains(parts[0]) { d.handle = parts[0] }
        let lowered = labels.map { $0.lowercased() }
        var reply = statusPage
        for l in lowered {
            if l.contains("post your reply") || l.contains("reply") { reply = true }
            if let r = l.range(of: "replying to @") {
                let h = l[r.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                if !h.isEmpty { d.handle = String(h); reply = true }
            }
        }
        if let parsed = xTitle(pageTitle) {
            c.author = parsed.author
            c.excerpt = ComposeSend.clipContext(parsed.text)
        }
        if !reply { c = ComposeContext() }
        return (d, c, reply)
    }
    /// `Ada on X: "Small tools beat big frameworks…" / X` -> ("Ada", "Small tools beat big frameworks…").
    public static func xTitle(_ raw: String) -> (author: String, text: String)? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("("), let close = t.firstIndex(of: ")") { t = String(t[t.index(after: close)...]).trimmingCharacters(in: .whitespaces) }   // "(3) Ada on X…"
        for suffix in [" / X", " / Twitter"] where t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
        guard let on = t.range(of: " on X: ") ?? t.range(of: " on Twitter: ") else { return nil }
        let author = String(t[..<on.lowerBound]).trimmingCharacters(in: .whitespaces)
        var text = String(t[on.upperBound...]).trimmingCharacters(in: .whitespaces)
        for (open, close) in [("\"", "\""), ("\u{201C}", "\u{201D}")] where text.hasPrefix(open) && text.hasSuffix(close) && text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        guard !author.isEmpty, author.count <= 60, !text.isEmpty else { return nil }
        return (author, text)
    }

    /// Reddit: a post page's title is `<post title> : r/<sub>` (or `r/<sub> - <post title>`); the path
    /// `/r/<sub>/comments/<id>/…` names the community. A comment's context is the post's title.
    public static func reddit(pageTitle: String, path: String = "") -> (ComposeDestination, ComposeContext) {
        var d = ComposeDestination(service: "Reddit"), c = ComposeContext()
        let parts = path.split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "r" { d.community = parts[1] }
        let t = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: " : r/", options: .backwards) {
            c.excerpt = ComposeSend.clipContext(String(t[..<r.lowerBound]))
            if d.community == nil { d.community = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces) }
        } else if t.hasPrefix("r/"), let dash = t.range(of: " - ") {
            if d.community == nil { d.community = String(t[t.index(t.startIndex, offsetBy: 2)..<dash.lowerBound]) }
            c.excerpt = ComposeSend.clipContext(String(t[dash.upperBound...]))
        }
        if parts.count < 3 || parts[2] != "comments" { c = ComposeContext() }   // a new post: no parent
        return (d, c)
    }

    /// Email: recipients from the To-field rule (`RecipientMemory`), the subject from the window or page title
    /// ("Re: Pricing", Gmail's "Re: Pricing - me@example.com - Gmail"). A reply's context is its subject.
    public static func email(title: String, recipient: String? = nil, service: String = "Mail") -> (ComposeDestination, ComposeContext) {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasSuffix(" - Gmail") || t.hasSuffix(" – Gmail") {
            let parts = t.components(separatedBy: " - ")
            t = parts.count >= 3 ? parts.dropLast(2).joined(separator: " - ") : (parts.first ?? t)
        }
        if ["new message", "inbox", "compose", ""].contains(t.lowercased()) { t = "" }
        let subject = t.isEmpty || t.contains("@") ? nil : t
        let lower = subject?.lowercased() ?? ""
        let isReply = lower.hasPrefix("re:") || lower.hasPrefix("re ")
        let bare = subject.map { s -> String in
            var x = s
            while let r = x.range(of: #"^(re|fwd?|aw|sv):\s*"#, options: [.regularExpression, .caseInsensitive]) { x.removeSubrange(r) }
            return x
        }
        return (ComposeDestination(name: recipient, subject: bare, service: service),
                isReply ? ComposeContext(excerpt: bare.map(ComposeSend.clipContext)) : ComposeContext())
    }

    /// ChatGPT / Claude (app or web): the chat's name from the title ("ChatGPT - Trip planning", "Trip planning - Claude").
    public static func aiChat(title: String, service: String) -> ComposeDestination {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for sep in [" - ", " – ", " | "] {
            if t.hasPrefix(service + sep) { t = String(t.dropFirst(service.count + sep.count)) }
            if t.hasSuffix(sep + service) { t = String(t.dropLast(service.count + sep.count)) }
        }
        let chat = t == service || t.isEmpty || ["new chat", "chatgpt", "claude"].contains(t.lowercased()) ? nil : t
        return ComposeDestination(name: service, subject: chat, service: service)
    }

    /// Slack (app or web): the channel or person from the composer label (`SendRules.composerPlace`).
    public static func slack(labels: [String], host: String = "app.slack.com") -> ComposeDestination {
        ComposeDestination(name: SendRules.composerPlace(labels: labels, host: host), service: "Slack")
    }
}
