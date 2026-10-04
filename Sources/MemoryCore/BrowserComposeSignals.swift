#if DAYDREAM_CHROME_TYPING
// Compiled only with -DDAYDREAM_CHROME_TYPING: every release build defines it; a plain swift build leaves this file out.
//
// fix/chrome-x (10-03): the browser side of claude/messages-1003's generic compose/send model
// (PrivacyPolicy `ComposeSend` / `ComposeIdentity`). For a Chrome composer this says, at a send gesture:
//   - which gesture it was (`gesture`, `ComposeGesture`'s raw values: "return", "commandReturn", "button") and, for a
//     click, the proven Post/Reply control (`BrowserSubmitGesture`, `control`: "post", "reply", "post all");
//   - the composer's AXValue at submit (`valueAtSubmit`, for `TypingSession.sentValue`; memory only, never written
//     here);
//   - afterwards (`BrowserTypingJoin.composeSnapshot` at `ComposeSend.confirmChecks`), whether the field was cleared,
//     the composer closed or the route changed (`confirmation`, `ComposeConfirmation`'s raw values);
//   - on X, whether it is a reply and the @handle replied to; and the reply's context: the replied-to post's author
//     and text from the status page's title (`Ada on X: "Small tools beat big frameworks…" / X`); on Reddit the
//     community and the post's title; in webmail the thread's subject.
// The inputs `ComposeIdentity.x(pageTitle:path:labels:)`, `reddit(pageTitle:path:)` and `email(title:)` take are
// exposed as they are (`pageTitle`, `path`, `labels`), so the compose model can derive the same facts itself.
//
// What is read: nothing new before a send. The route comes from the address the join already reads (step 10),
// reduced at once to its compose kind; the reply markers from the labels it already reads (step 13), only the reply
// phrases; the title is the row's place (`WebTypingTitle.clean`). After a send gesture, `composeSnapshot` reads the
// typed field's parent, role, focus and value (by the host) and the web area's AXURL, reduced at once. No Apple Event.
// Not available: an Outlook or Gmail reply's sender (it is in the reading pane, not the title or the composer's
// labels), and a reply modal's "Replying to @h" line when X doesn't put it in the composer's labels (the handle then
// comes from a status page's path only).
import Foundation
import PrivacyPolicy

/// The route of a compose page, reduced to what the compose model needs. Never the post or comment ID, a query or
/// anything else of the address.
public enum BrowserComposeRoute {
    /// x.com/twitter.com: "/<handle>/status/_" (a post's page), "/compose/post" (the compose modal), "/home"; Reddit:
    /// "/r/<sub>/comments/_" (a post's page), "/r/<sub>/submit", "/r/<sub>"; "" for anything else.
    public static func path(url: String) -> String {
        guard let c = URLComponents(string: url), let host = c.host?.lowercased() else { return "" }
        let parts = c.path.split(separator: "/").map(String.init)
        if ["x.com", "twitter.com"].contains(where: { BrowserSites.matches(host: host, domain: $0) }) {
            if parts.count >= 3, parts[1] == "status", handle(parts[0]), !["i", "home", "compose"].contains(parts[0].lowercased()) {
                return "/\(parts[0])/status/_"
            }
            if parts.count >= 2, parts[0] == "compose", parts[1] == "post" { return "/compose/post" }
            if parts == ["home"] { return "/home" }
            return ""
        }
        if BrowserSites.matches(host: host, domain: "reddit.com") {
            guard parts.count >= 2, parts[0].lowercased() == "r", community(parts[1]) else { return "" }
            if parts.count >= 3, parts[2] == "comments" { return "/r/\(parts[1])/comments/_" }
            if parts.count >= 3, parts[2] == "submit" { return "/r/\(parts[1])/submit" }
            return parts.count == 2 ? "/r/\(parts[1])" : ""
        }
        return ""
    }
    static func handle(_ s: String) -> Bool {
        (1...15).contains(s.count) && s.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" }
    }
    static func community(_ s: String) -> Bool {
        (2...21).contains(s.count) && s.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" }
    }
    /// The composer's labels that mark a reply ("Post your reply", "Replying to @ada"), at most three, each at most
    /// 80 characters. Every other label is dropped here.
    public static func replyMarkers(_ labels: [String]) -> [String] {
        Array(labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { let l = $0.lowercased(); return l.contains("post your reply") || l.contains("replying to @") }
            .map { String($0.prefix(80)) }.prefix(3))
    }
    /// "Replying to @ada" -> "ada".
    public static func repliedHandle(_ labels: [String]) -> String? {
        for l in labels {
            guard let r = l.lowercased().range(of: "replying to @") else { continue }
            let tail = l.lowercased()[r.upperBound...].prefix { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" }
            if handle(String(tail)) { return String(tail) }
        }
        return nil
    }
}

/// The composer read again after a send gesture (`BrowserTypingJoin.composeSnapshot`).
public struct BrowserComposeSnapshot: Equatable, Sendable {
    /// The typed field is still in the page, under the parent it was typed in.
    public var fieldPresent: Bool
    public var fieldFocused: Bool
    /// The field's value is empty (nil: not read, the field is gone or unreadable).
    public var valueEmpty: Bool?
    public var origin: String
    /// `BrowserComposeRoute.path` of the web area's AXURL ("" for a route of no compose kind).
    public var path: String
    public var urlRead: Bool
    public init(fieldPresent: Bool, fieldFocused: Bool, valueEmpty: Bool?, origin: String, path: String, urlRead: Bool) {
        self.fieldPresent = fieldPresent; self.fieldFocused = fieldFocused; self.valueEmpty = valueEmpty
        self.origin = origin; self.path = path; self.urlRead = urlRead
    }
}

/// What a Chrome composer says at a send gesture, for the compose model (names as in claude/messages-1003's
/// `ComposeSend`, `ComposeDestination`, `ComposeContext` and `TypedUnitProvenance`).
public struct BrowserComposeSignals: Equatable, Sendable {
    /// `ComposeGesture` raw value: "return" (Return), "commandReturn" (Command-Return), "button" (a proven Post/Reply click).
    public var gesture: String
    /// For "button": the control's normalized name ("post", "reply", "post all"); else nil.
    public var control: String?
    /// The composer's AXValue at the gesture (the host's read). Memory only.
    public var valueAtSubmit: String?
    /// `ComposeConfirmation` raw value once a re-read confirms it: "fieldCleared", "composerClosed", "routeChanged".
    public var confirmation: String?
    /// `ComposeDestination.service`: "X", "Reddit", "Gmail", "Outlook", or nil.
    public var service: String?
    /// `ComposeIdentity` inputs, as they are.
    public var pageTitle: String
    public var path: String
    public var labels: [String]
    /// X: a reply (a status page, or a composer labelled "Post your reply" / "Replying to @h"), and the @handle replied to.
    public var reply: Bool
    public var handle: String?
    /// `ComposeDestination.community` (Reddit) and `.subject` (webmail).
    public var community: String?
    public var subject: String?
    /// `ComposeContext`: the replied-to post's author display name and text (X), the post's title (Reddit), the
    /// thread's subject (webmail), each clipped to `contextLimit`.
    public var contextAuthor: String?
    public var contextExcerpt: String?

    public static let contextLimit = 80
    public static let gestures: Set<String> = ["return", "commandReturn", "button"]

    /// The signals at a send gesture, from the proof of the join that allowed the composer's words.
    public static func submit(proof p: BrowserTypingJoinProof, gesture: String, control: String? = nil,
                              valueAtSubmit: String? = nil) -> BrowserComposeSignals? {
        guard gestures.contains(gesture), gesture != "button" || control != nil, let host = BrowserSites.host(of: p.origin) else { return nil }
        var s = BrowserComposeSignals(gesture: gesture, control: gesture == "button" ? control : nil, valueAtSubmit: valueAtSubmit,
                                      confirmation: nil, service: nil, pageTitle: p.pageTitle, path: p.composeRoute, labels: p.replyLabels,
                                      reply: false, handle: nil, community: nil, subject: nil, contextAuthor: nil, contextExcerpt: nil)
        if ["x.com", "twitter.com"].contains(where: { BrowserSites.matches(host: host, domain: $0) }) {
            s.service = "X"
            let parts = p.composeRoute.split(separator: "/").map(String.init)
            let status = parts.count == 3 && parts[1] == "status"
            s.handle = BrowserComposeRoute.repliedHandle(p.replyLabels) ?? (status ? parts[0] : nil)
            s.reply = status || !p.replyLabels.isEmpty || control == "reply"
            if s.reply, let post = xTitle(p.pageTitle) { s.contextAuthor = clip(post.author); s.contextExcerpt = clip(post.text) }
        } else if BrowserSites.matches(host: host, domain: "reddit.com") {
            s.service = "Reddit"
            let parts = p.composeRoute.split(separator: "/").map(String.init)
            if parts.count >= 2, parts[0] == "r" { s.community = parts[1] }
            if parts.count == 4, parts[2] == "comments" {
                s.reply = true
                var t = p.pageTitle
                if let r = t.range(of: " : r/", options: .backwards) { t = String(t[..<r.lowerBound]) }
                if !t.isEmpty { s.contextExcerpt = clip(t) }
            }
        } else if SendRules.surface(bundle: WebTypingGate.bundle, host: host) == "email" {
            s.service = BrowserSites.matches(host: host, domain: "mail.google.com") ? "Gmail"
                : ["outlook.live.com", "outlook.office.com", "outlook.office365.com"].contains(where: { BrowserSites.matches(host: host, domain: $0) }) ? "Outlook" : nil
            if !p.pageTitle.isEmpty {
                s.subject = clip(p.pageTitle)
                s.reply = p.pageTitle.range(of: #"^(re|aw|sv):\s*"#, options: [.regularExpression, .caseInsensitive]) != nil
                if s.reply { s.contextExcerpt = s.subject }
            }
        }
        return s
    }

    /// The first re-read that confirms the send, in `ComposeConfirmation`'s order of strength: the route changed (another
    /// page, or the compose modal's route left), the composer closed (the field is gone from the page), the field was
    /// cleared (empty now, not at the gesture). nil: nothing confirms it (yet); an unread value or URL confirms nothing.
    public static func confirmation(atSubmit before: BrowserComposeSnapshot, now after: BrowserComposeSnapshot) -> String? {
        if before.urlRead, after.urlRead, before.origin == after.origin, before.path != after.path { return "routeChanged" }
        if before.fieldPresent, !after.fieldPresent { return "composerClosed" }
        if before.valueEmpty == false, after.fieldPresent, after.valueEmpty == true { return "fieldCleared" }
        return nil
    }

    /// `Ada on X: "Small tools beat big frameworks…" / X` -> ("Ada", "Small tools beat big frameworks…").
    public static func xTitle(_ raw: String) -> (author: String, text: String)? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("("), let close = t.firstIndex(of: ")") { t = String(t[t.index(after: close)...]).trimmingCharacters(in: .whitespaces) }
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
    static func clip(_ raw: String) -> String {
        let t = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return t.count <= contextLimit ? t : String(t.prefix(contextLimit - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}
// MARK: - compose-send/v1 wiring (claude/int-1003)
//
// The Chrome route (`WebTypingRoute.write`) stores a row's destination and reply context from these signals (page
// metadata the join already read: the row's own title, the route's compose kind, the reply phrases of the composer's
// labels; never the typed words), and after a Return or Command-Return re-reads the composer at `checks(surface:)`
// and marks the row (`MemoryStore.markComposerSent`) on the first confirmation. Owner decision 2026-09-27 (cloud may
// read typed words under ZDR): the replied-to excerpt is page metadata and goes to the local and the cloud writer.
extension BrowserComposeSignals {
    /// The gesture a website unit's seal is: Return or Command-Return. A Post click is the Post check's
    /// (`BrowserSubmitGesture`); any other seal is no gesture.
    public static func gesture(seal: String) -> ComposeGesture? {
        switch seal {
        case SealReason.submit.rawValue: return .returnKey
        case SealReason.submitChord.rawValue: return .commandReturn
        default: return nil
        }
    }
    /// Who or what the row went to and what it answered. X and Reddit: these signals (handle, community, the replied-to
    /// post's author and excerpt). Webmail: email-compose/v1 (`EmailComposeAdapter`) over the page title
    /// (`BrowserEmailComposeReader`), with the To-field rule's name. nil on any other site.
    public func identity(surface: String, recipient: String? = nil) -> (ComposeDestination, ComposeContext)? {
        // (The service itself is not stored: `ComposeView.service` names it from the row's site when read.)
        if surface == "email" {
            let service = service ?? ""
            let reader = BrowserEmailComposeReader(title: pageTitle)
            guard let snapshot = reader.composeSnapshot() else { return nil }
            return EmailComposeAdapter.identity(EmailComposeAdapter.facts(snapshot), recipient: recipient, service: service)
        }
        guard let service else { return nil }
        return (ComposeDestination(handle: handle, community: community, service: service),
                ComposeContext(author: contextAuthor, excerpt: contextExcerpt))
    }
    /// Whether a gesture on a website unit is re-read for a confirmation: a confirmable composer
    /// (`ComposeSend.confirmable`), except Return on a social site or in webmail, where it is a new line
    /// (`SendRules.send`); there only Command-Return is a gesture.
    public static func confirms(surface: String, field: String, gesture: ComposeGesture) -> Bool {
        if gesture == .returnKey, ["social", "email"].contains(surface) { return false }
        return ComposeSend.confirmable(surface: surface, field: field, gesture: gesture)
    }
    /// When the composer is read again after a gesture, seconds from it: email waits for the compose to close
    /// (`EmailComposeAdapter.closeChecks`); every other composer `ComposeSend.confirmChecks` (0.12, 0.35, 0.8 s).
    public static func checks(surface: String) -> [Double] {
        surface == "email" ? EmailComposeAdapter.closeChecks : ComposeSend.confirmChecks
    }
    /// The confirmation one re-read gives, `elapsed` seconds after the gesture, or nil. Email: only the compose closing
    /// (the field gone, or the route left) within `EmailComposeAdapter.closeWindow` (`EmailComposeAdapter.confirmation`);
    /// an emptied field proves nothing there. Everything else: `confirmation(atSubmit:now:)`, within
    /// `ComposeSend.confirmWindow`.
    public static func confirm(surface: String, gesture: ComposeGesture, before: BrowserComposeSnapshot, after: BrowserComposeSnapshot,
                               elapsed: Double) -> ComposeConfirmation? {
        guard elapsed >= 0, let raw = confirmation(atSubmit: before, now: after), let c = ComposeConfirmation(rawValue: raw) else { return nil }
        if surface == "email" {
            guard c != .fieldCleared else { return nil }
            return EmailComposeAdapter.confirmation(gesture: gesture, mailApp: false, closedAfter: elapsed)
        }
        return elapsed <= ComposeSend.confirmWindow + 0.05 ? c : nil
    }
}

/// email-compose/v1's reader (`EmailComposeReading`) for a webmail compose in Chrome: the page title the join already
/// read (the open thread's subject, `WebTypingTitle`), no fields (the To and Subject fields are not read: the To-field
/// rule names the recipient), and whether the composer is still in the page (`BrowserComposeSnapshot.fieldPresent`).
public struct BrowserEmailComposeReader: EmailComposeReading {
    public let title: String
    public let open: () -> Bool?
    public init(title: String, open: @escaping () -> Bool? = { nil }) { self.title = title; self.open = open }
    public func composeSnapshot() -> EmailComposeSnapshot? { EmailComposeSnapshot(title: title, fields: []) }
    /// Unknown counts as open: a send is never inferred from a read that failed.
    public func composeStillOpen() -> Bool { open() ?? true }
}
#endif
