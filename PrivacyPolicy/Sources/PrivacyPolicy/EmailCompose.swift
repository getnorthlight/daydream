import Foundation

// email-compose/v1 (email-1003, owner decision 2026-10-03): the email identity adapter for the compose/send model.
//
// claude/messages-1003 is building one compose/send model (`ComposeSend`, compose-send/v1) with per-surface identity
// adapters. It was not committed when this was written, so the email adapter sits behind this small protocol and plugs
// in later without changing either side:
//
//   EmailComposeReading        the capture layer's Accessibility read of a compose form (Mail's compose window, Gmail's
//                              or Outlook's compose region): its fields' roles, labels and the To/Cc tokens' names, the
//                              Subject field's value, and the window or page title. Metadata only; never the body.
//   EmailComposeAdapter.facts  who it goes to (To recipients' display names, or addresses when no name is shown), the
//                              subject, and whether it is a reply or a forward (and to whom).
//   EmailComposeAdapter.send   the send decision: a Send-button click, Command-Return (Mail: Command-Shift-D, `mailSend`)
//                              AND the compose closing within `closeWindow` seconds. Anything else stays a draft; a
//                              compose closed without a send gesture is a discarded or saved draft, never a send.
//
// Mapping onto compose-send/v1 (when it lands): `ComposeDestination(name: facts.replyTo ?? facts.recipients.first,
// subject: bareSubject(facts.subject), service: <"Mail" | "Gmail" | "Outlook">)`, `ComposeContext(author: facts.replyTo,
// excerpt: bareSubject(facts.subject))` for a reply, `ComposeKind.emailed` for a send; `ComposeGesture.button /
// .commandReturn / .mailSend` and `ComposeConfirmation.composerClosed` are `EmailSendGesture` and `composeClosedAfter`.
//
// Pure: no Accessibility, no store, no clock. The capture-side privacy gates (secure fields, Secure Input, excluded
// apps and sites, Incognito) run before any of it; the subject is scrubbed by the store (`EmailTitle`).

/// One field of a compose form as Accessibility shows it. `value` is read only for the Subject field; `tokens` are the
/// To/Cc field's recipient tokens' names ("Sam Lee", "Sam Lee <sam@example.com>", "sam@example.com").
public struct EmailComposeField: Equatable, Sendable {
    public var role: String
    public var subrole: String
    public var labels: [String]
    public var value: String?
    public var tokens: [String]
    public init(role: String, subrole: String = "", labels: [String], value: String? = nil, tokens: [String] = []) {
        self.role = role; self.subrole = subrole; self.labels = labels; self.value = value; self.tokens = tokens
    }
}

/// The capture layer's read of one compose form, at the gesture and after it.
public struct EmailComposeSnapshot: Equatable, Sendable {
    /// The compose window's title (Mail: "New Message" or the subject) or the page's title (webmail).
    public var title: String
    public var fields: [EmailComposeField]
    /// Labels of the compose region or window ("Reply", "Forward", "New Message", "Reply to Sam"), when shown.
    public var regionLabels: [String]
    public init(title: String, fields: [EmailComposeField], regionLabels: [String] = []) {
        self.title = title; self.fields = fields; self.regionLabels = regionLabels
    }
}

/// What the capture layer implements (the live Accessibility read). Checks fake it.
public protocol EmailComposeReading {
    /// The compose form the focused field is in, or nil when the focus is not in one.
    func composeSnapshot() -> EmailComposeSnapshot?
    /// Whether the same compose form still exists (the same window or region), read fresh.
    func composeStillOpen() -> Bool
}

public enum EmailComposeKind: String, Equatable, Sendable { case new, reply, forward }

/// The facts of one compose form. Never the body.
public struct EmailComposeFacts: Equatable, Sendable {
    /// To recipients' display names, or addresses where no name is shown, in order.
    public var recipients: [String]
    /// The subject as shown (with "Re:"/"Fwd:"), nil when empty.
    public var subject: String?
    public var kind: EmailComposeKind
    /// For a reply or a forward: the person it answers (the first To recipient of a reply; nil when unknown).
    public var replyTo: String?
    public init(recipients: [String], subject: String?, kind: EmailComposeKind, replyTo: String? = nil) {
        self.recipients = recipients; self.subject = subject; self.kind = kind; self.replyTo = replyTo
    }
}

/// How a send was asked for. Raw values are what `SendFacts.sendBy` stores.
public enum EmailSendGesture: String, Equatable, Sendable {
    case button, commandReturn, mailSend
}

public enum EmailComposeAdapter {
    public static let version = "email-compose/v1"
    /// Seconds after the gesture within which the compose must close for the send to count (Mail animates its window
    /// away; Gmail and Outlook close the region at once or after an "undo send" bar starts).
    public static let closeWindow: Double = 2.0
    /// Re-reads after the gesture, seconds from it.
    public static let closeChecks: [Double] = [0.15, 0.4, 0.9, 2.0]

    static let toLabels: Set<String> = ["to", "to recipients", "to:", "recipients", "add recipients", "to field"]
    static let ccLabels: Set<String> = ["cc", "bcc", "cc:", "bcc:", "cc recipients", "bcc recipients"]
    static let subjectLabels: Set<String> = ["subject", "subject:", "add a subject", "subject field"]
    static let sendLabels: Set<String> = ["send", "send now", "send email", "send message"]

    static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while let last = s.last, [".", "…"].contains(last) { s.removeLast() }
        return s
    }

    /// Whether a clicked control is the compose form's Send button, from its role and labels only.
    public static func isSendButton(role: String, labels: [String]) -> Bool {
        guard ["AXButton", "AXMenuButton", "AXLink"].contains(role) else { return false }
        return labels.map(clean).contains { l in
            // Gmail and Outlook add the shortcut: "Send (⌘Enter)", "Send (Ctrl+Enter)"; bidi marks are dropped first.
            let bare = l.unicodeScalars.filter { !(0x200E...0x202E).contains($0.value) }.map(String.init).joined()
            return sendLabels.contains(bare) || bare.hasPrefix("send (")
        }
    }

    /// A recipient token as kept: "Sam Lee <sam@example.com>" -> "Sam Lee"; "\"Lee, Sam\" <s@x.io>" -> "Lee, Sam";
    /// "sam@example.com" -> "sam@example.com" (no name shown). nil for an empty or over-long token.
    public static func recipientName(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lt = t.firstIndex(of: "<"), t.hasSuffix(">") {
            let name = t[..<lt].trimmingCharacters(in: .whitespaces)
            let addr = String(t[t.index(after: lt)..<t.index(before: t.endIndex)])
            t = name.isEmpty ? addr : name
        }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'").union(.whitespaces))
        // Gmail's token labels can carry a trailing hint ("Sam Lee, press delete to remove").
        if let comma = t.range(of: ", press ", options: .caseInsensitive) { t = String(t[..<comma.lowerBound]) }
        guard !t.isEmpty, t.count <= 80 else { return nil }
        return t
    }

    /// The class of a compose field from its labels: to | cc | subject | body | other.
    public static func fieldKind(_ f: EmailComposeField) -> String {
        let labels = f.labels.map(clean)
        if labels.contains(where: toLabels.contains) { return "to" }
        if labels.contains(where: ccLabels.contains) { return "cc" }
        if labels.contains(where: subjectLabels.contains) { return "subject" }
        if labels.contains(where: { $0 == "message body" || $0 == "body" || $0.hasPrefix("message body") }) { return "body" }
        return "other"
    }

    /// The facts of a compose form. The subject comes from the Subject field, else from the window or page title (a
    /// reply's compose window in Mail is titled with its subject). Reply/forward comes from the subject's prefix, else
    /// from the region's labels ("Reply", "Forward", "Reply all").
    public static func facts(_ s: EmailComposeSnapshot) -> EmailComposeFacts {
        var recipients: [String] = []
        var subject: String?
        for f in s.fields {
            switch fieldKind(f) {
            case "to":
                for t in f.tokens { if let n = recipientName(t), !recipients.contains(n) { recipients.append(n) } }
            case "subject":
                if let v = f.value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { subject = v }
            default: break
            }
        }
        if subject == nil {
            let t = s.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = t.lowercased()
            if !t.isEmpty, !["new message", "compose", "new email", "untitled", "new mail"].contains(lower), !t.contains("@") { subject = t }
        }
        var kind: EmailComposeKind = .new
        let lowerSubject = (subject ?? "").lowercased()
        if lowerSubject.range(of: #"^\s*(re|aw|sv)\s*:"#, options: .regularExpression) != nil { kind = .reply }
        else if lowerSubject.range(of: #"^\s*(fwd?|wg|tr)\s*:"#, options: .regularExpression) != nil { kind = .forward }
        else {
            let region = s.regionLabels.map(clean)
            if region.contains(where: { $0.hasPrefix("forward") }) { kind = .forward }
            else if region.contains(where: { $0.hasPrefix("reply") }) { kind = .reply }
        }
        let replyTo = kind == .reply ? recipients.first : nil
        return EmailComposeFacts(recipients: recipients, subject: subject, kind: kind, replyTo: replyTo)
    }

    /// The subject without "Re:"/"Fwd:" prefixes ("RE: Fwd: Demo feedback" -> "Demo feedback").
    public static func bareSubject(_ s: String) -> String {
        var x = s
        while let r = x.range(of: #"^\s*(re|aw|sv|fwd?|wg|tr)\s*(?:\[\d+\])?\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) { x.removeSubrange(r) }
        return x.trimmingCharacters(in: .whitespaces)
    }

    /// The send decision. `closedAfter`: seconds from the gesture to the first read that found the compose gone, nil
    /// when it was still open at the last read (or there was no gesture). A gesture with no close (a missing recipient,
    /// a blocked send) stays a draft; a close with no gesture is a discarded or saved draft.
    /// Mail's Command-Shift-D (`mailSend`) counts only in Mail; Command-Return only in webmail (in Mail it is nothing).
    public static func send(gesture: EmailSendGesture?, closedAfter: Double?, mailApp: Bool) -> (send: String, sendBy: String?) {
        guard let gesture else { return ("unknown", nil) }
        switch gesture {
        case .mailSend where !mailApp, .commandReturn where mailApp: return ("unknown", nil)
        default: break
        }
        guard let closedAfter, closedAfter >= 0, closedAfter <= closeWindow else { return ("unknown", nil) }
        return ("detected", gesture.rawValue)
    }

    /// The whole decision with a live reader: `reader` is asked at each of `closeChecks` (the caller waits between
    /// them); the first `false` from `composeStillOpen` closes it. For checks and for wiring.
    public static func decide(gesture: EmailSendGesture?, mailApp: Bool, stillOpenAt: [(seconds: Double, open: Bool)]) -> (send: String, sendBy: String?) {
        let closed = stillOpenAt.sorted { $0.seconds < $1.seconds }.first { !$0.open }?.seconds
        return send(gesture: gesture, closedAfter: closed, mailApp: mailApp)
    }
}

// MARK: compose-send/v1 wiring (claude/int-1003)

extension EmailComposeAdapter {
    /// The compose-send/v1 destination and context of an email (the mapping in this file's header): the person it
    /// answers or its first To recipient (`recipient`, the To-field rule's name, when the form showed none), the bare
    /// subject, and for a reply the subject as what it answered.
    public static func identity(_ f: EmailComposeFacts, recipient: String? = nil, service: String) -> (ComposeDestination, ComposeContext) {
        let bare = f.subject.map(bareSubject).flatMap { $0.isEmpty ? nil : $0 }
        let name = f.replyTo ?? f.recipients.first ?? recipient.flatMap { $0.isEmpty ? nil : $0 }
        let context = f.kind == .reply ? ComposeContext(author: f.replyTo, excerpt: bare.map(ComposeSend.clipContext)) : ComposeContext()
        return (ComposeDestination(name: name, subject: bare, service: service), context)
    }
    /// The email gesture a compose-send/v1 gesture is; nil for a plain Return (a new line or a contact pick in email).
    public static func gesture(_ g: ComposeGesture) -> EmailSendGesture? {
        switch g {
        case .returnKey: return nil
        case .commandReturn: return .commandReturn
        case .button: return .button
        case .mailSend: return .mailSend
        }
    }
    /// The compose-send/v1 confirmation of an email gesture from the adapter's decision: `.composerClosed` when the
    /// compose closed within `closeWindow` of the gesture (`send`), else nil. A field emptied or a route that stays
    /// open proves nothing for email.
    public static func confirmation(gesture: ComposeGesture, mailApp: Bool, closedAfter: Double?) -> ComposeConfirmation? {
        guard let g = Self.gesture(gesture), send(gesture: g, closedAfter: closedAfter, mailApp: mailApp).send == "detected" else { return nil }
        return .composerClosed
    }
}
