import Foundation
import MemoryCore
import PrivacyPolicy

/// The compose line a typed row's evidence gives (`ComposeView`, compose-send/v1): "Sent to Jamie", "Replied to Ada's
/// post on X", "Posted on X", "Emailed Sam — Pricing", "Typed to Jamie", and the muted replied-to line
/// (`on: “…”`). Metadata only, never the typed words: the host reads it for a moment's typed action IDs
/// (`ActivityBrowser.loadComposeLines`) and What happened titles its rows with it.
public struct ComposeLine: Equatable, Sendable {
    public let title: String
    public let context: String?
    /// A send was detected (any kind but draft).
    public let sent: Bool
    /// The outcome's kind (`ComposeKind` raw value).
    public let kind: String
    /// The destination's name, when known (a Messages conversation keys its pieces on it).
    public let name: String?
    /// claude/messages2-1003: Return sealed the unit (`ComposeOutcome.sealedBy`), whether or not the send was confirmed:
    /// a whole message, never a piece of the next one.
    public let sealedByReturn: Bool
    public init(title: String, context: String? = nil, sent: Bool, kind: String, name: String? = nil, sealedByReturn: Bool = false) {
        self.title = title; self.context = context; self.sent = sent; self.kind = kind; self.name = name; self.sealedByReturn = sealedByReturn
    }
    public init(_ o: ComposeOutcome) {
        self.init(title: ComposeSend.line(o), context: ComposeSend.contextLine(o.context), sent: o.kind != .draft, kind: o.kind.rawValue,
                  name: o.destination.name, sealedByReturn: o.sealedBy == .returnKey)
    }
    /// The line of a typed row (`ComposeView.outcome`), nil for any other row or one without send facts.
    public init?(evidence e: Evidence) {
        guard let o = ComposeView.outcome(e) else { return nil }
        self.init(o)
    }
    /// The lines of these rows by action ID (a typed row's action ID is its evidence ID).
    public static func lines(_ evidence: [Evidence]) -> [String: ComposeLine] {
        var out = [String: ComposeLine]()
        for e in evidence { if let l = ComposeLine(evidence: e) { out[e.id] = l } }
        return out
    }
}

/// What happened for composers (owner 10/3, compose-send/v1): a typed unit is a draft or a send, never "Typed a draft"
/// with a "Drafted text" block and a separate "Pressed Return" row:
/// - one line per sent unit, titled by its compose line ("Sent to Jamie", "Replied to Ada's post on X"; `ComposeLine`),
///   its exact words as the one block and the replied-to line under it; Messages rows the host gave no line for are
///   titled the same way from their projection (`ComposeSend.line`: "Sent to Jamie", "Sent to someone");
/// - the Return marker that sealed a send is folded into it (no "Pressed Return" row);
/// - a message typed in pieces (a click, a switch or a pause sealed the first piece mid-word, "wanna me" + "et us there?")
///   is one line and one quote: consecutive pieces in the same place with no send between them; a send's words that
///   already hold the pieces (the composer's value at the gesture) are the message;
/// - a still-unsent draft is "Typed to Jamie" ("Typed" with no name). A Messages draft that a
///   Return marker follows within `returnWindow` (rows saved before the Messages composer was classified, so the send was
///   not detected) is "Typed to Jamie": neither called sent nor "not sent", and its Return row stays as before;
/// - a reply replaces the page-visit row of the same post (writing beats reading);
/// - a Messages conversation's name is only the unit's own (its projection's title, the code-read recipient): a New
///   Message with an empty To has no name and never takes another conversation's.
public enum MessagesTypedFold {
    public struct Line: Equatable {
        /// A send was detected.
        public let sent: Bool
        /// A draft that a Return marker followed (send not established either way).
        public let returned: Bool
        /// The destination, nil when unknown.
        public let name: String?
        /// The row's title ("Sent to Jamie", "Replied to Ada's post on X").
        public let title: String
        /// `ComposeKind` raw value.
        public let kind: String
        public init(sent: Bool, returned: Bool, name: String?, title: String = "", kind: String = "") {
            self.sent = sent; self.returned = returned; self.name = name; self.kind = kind
            self.title = title.isEmpty ? MessagesTypedFold.messagesTitle(sent: sent, returned: returned, name: name) : title
        }
    }

    /// A Return marker this close after a typed unit is the key that sealed it.
    public static let returnWindow: TimeInterval = 5
    /// Pieces further apart than this are not one message.
    public static let pieceWindow: TimeInterval = 15 * 60

    public static func applies(bundle: String, app: String) -> Bool {
        bundle == "com.apple.MobileSMS" || (bundle.isEmpty && (app == "Messages" || app == "Texts"))
    }

    /// The conversation a typed unit names (its projection's title is the recipient, else "Messages"); nil when unknown.
    public static func name(_ title: String) -> String? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !["messages", "texts", "new message", "window"].contains(t.lowercased()),
              !t.contains(MomentHistoryCondense.withheldTitle) else { return nil }
        return t
    }

    /// A Messages row's title in the shared wording (`ComposeSend.line`).
    static func messagesTitle(sent: Bool, returned: Bool, name: String?) -> String {
        if returned { return name.map { "Typed to " + $0 } ?? "Typed in Messages" }
        return ComposeSend.line(ComposeOutcome(kind: sent ? .sentMessage : .draft, destination: ComposeDestination(name: name)))
    }
    public static func title(_ line: Line) -> String { line.title }

    /// The card's sentence: "Texted Jamie.", "Texted someone.", "Wrote a text to Jamie.", and for
    /// other composers the line itself ("Replied to Ada's post on X.").
    public static func sentence(_ line: Line, times: Int = 1) -> String {
        let n = times > 1 ? " (\(times) times)" : ""
        let messages = line.kind.isEmpty || line.kind == ComposeKind.sentMessage.rawValue && !(line.name ?? "").hasPrefix("#")
        if line.sent, messages { return "Texted " + (line.name ?? "someone") + n + "." }
        if line.returned { return (line.name.map { "Typed to " + $0 } ?? "Typed in Messages") + n + "." }
        // claude/dayeval-1005 (owner 10/05): never "draft" or "not sent" (most of them were sent).
        if !line.sent, line.kind.isEmpty { return (line.name.map { "Wrote a text to \($0)" } ?? "Wrote a text") + n + "." }
        return line.title + n + "."
    }

    /// Two pieces of one message, as typed: a piece cut mid-word ("wanna me" + "et us there?") joins with no space; a
    /// piece that ended or starts with whitespace keeps its own; punctuation that starts the next piece follows directly;
    /// otherwise one space.
    public static func join(_ a: String, _ b: String) -> String {
        guard let x = a.last, let y = b.first else { return a + b }
        if x.isWhitespace || y.isWhitespace { return a + b }
        if (x.isLetter || x.isNumber) && (y.isLetter || y.isNumber) { return a + b }
        if ".,!?;:\u{2026}".contains(y) { return a + b }
        return a + " " + b
    }

    static func normalized(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// The message so far plus its next piece. A piece that already holds everything so far (a send's words are the
    /// field's whole value at Return) replaces it; otherwise the pieces join (`join`).
    public static func stitch(_ sofar: String, _ next: String) -> String {
        let a = normalized(sofar), b = normalized(next)
        if a.isEmpty { return next }
        if b.isEmpty { return sofar }
        if b.contains(a) { return next }
        if a.hasSuffix(b) { return sofar }
        return join(sofar, next)
    }

    /// The pre-pass of `MomentHistoryCondense.lines` over `OwnerSourceMomentProjection.history` (one entry per action, in
    /// time order): typed units with a compose line (`compose`, by action ID) and Messages typed units become compose
    /// lines (see the type's comment). Every other entry passes through in place; every action stays reachable (a folded
    /// line keeps the IDs of every piece, its Return and the page view it replaced).
    public static func fold(_ entries: [MomentDetailEntry], actions: [CanonicalAction], compose: [String: ComposeLine] = [:]) -> [MomentDetailEntry] {
        let byID = Dictionary(actions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func one(_ e: MomentDetailEntry) -> CanonicalAction? {
            guard e.actionIDs.count == 1, let a = byID[e.actionIDs[0]] else { return nil }
            return a
        }
        var out: [MomentDetailEntry] = []
        // The open (unsent) message's index and place key; the last send's index (for its Return).
        var open: (index: Int, key: String)?
        var lastSent: Int?
        // claude/messages2-1003: a Messages Return row no send absorbed yet (its unit's row can be written after it).
        var strayReturn: Int?
        for e in entries {
            guard let a = one(e) else { out.append(e); continue }
            let isMessages = applies(bundle: a.bundle, app: a.app)
            if a.kind == "keyboard.text_input", compose[a.id] != nil || isMessages {
                let given = compose[a.id]
                let name = isMessages ? (given?.name ?? name(a.title)) : given?.name
                let sent = given?.sent ?? (a.state == "submitted" || a.state == "sent")
                // claude/messages2-1003 (owner 10/3): a Messages text sealed by Return with no send confirmed is a whole
                // text ("Typed to Jamie"), never the first piece of the next one.
                let returned = isMessages && !sent && given?.sealedByReturn == true
                let line = returned ? Line(sent: false, returned: true, name: name)
                    : Line(sent: sent, returned: false, name: name, title: given?.title ?? "", kind: given?.kind ?? "")
                let key = [a.bundle.isEmpty ? a.app : a.bundle, a.site.isEmpty ? "" : KitBrowsers.host(a.site),
                           isMessages ? (name ?? "").lowercased() : a.title.lowercased()].joined(separator: "|")
                let words = e.typed.map(\.text).joined(separator: "\n")
                var made = make(e, line: line, words: words, context: given?.context)
                if let o = open, o.key == key, let prev = out[o.index].last, let now = e.first,
                   now.timeIntervalSince(prev) <= pieceWindow {
                    // The next piece of the open message: one line, at the later piece, with every piece's IDs.
                    let earlier = out.remove(at: o.index)
                    made = make(e, line: line, words: stitch(earlier.messageWords, words), context: given?.context, earlier: earlier)
                }
                // claude/messages2-1003: the Return written just before its unit's row is that unit's.
                if isMessages, sent || returned, let r = strayReturn, r < out.count, let rAt = out[r].first, let now = e.first,
                   now.timeIntervalSince(rAt) >= -1, now.timeIntervalSince(rAt) <= returnWindow {
                    let ret = out.remove(at: r)
                    if let o = open, o.index > r { open = (o.index - 1, o.key) }
                    made.actionIDs = ret.actionIDs + made.actionIDs
                }
                strayReturn = nil
                out.append(made)
                if sent || returned { open = nil; lastSent = sent ? out.count - 1 : nil } else { open = (out.count - 1, key); lastSent = nil }
                continue
            }
            if a.kind == "keyboard.submit" {
                let at = e.first
                func near(_ i: Int) -> Bool {
                    guard let t = out[i].last, let at, out[i].bundle == e.bundle || (out[i].bundle.isEmpty && out[i].app == e.app) else { return false }
                    return at.timeIntervalSince(t) >= -1 && at.timeIntervalSince(t) <= returnWindow
                }
                if let i = lastSent, near(i) {
                    // The Return that sent it: folded in.
                    out[i] = absorb(out[i], ids: e.actionIDs)
                    lastSent = nil
                    continue
                }
                if let o = open, near(o.index), let m = out[o.index].message, m.kind.isEmpty, applies(bundle: a.bundle, app: a.app) {
                    // A Messages draft then Return with no send detected (older rows): not called sent, nor "not sent".
                    out[o.index] = retitle(out[o.index], Line(sent: false, returned: true, name: m.name))
                }
                // A Return always ends the message it followed; its row stays (today's behaviour) unless it was a send's.
                open = nil; lastSent = nil
                out.append(e)
                strayReturn = applies(bundle: a.bundle, app: a.app) ? out.count - 1 : nil
                continue
            }
            out.append(e)
        }
        // Writing beats reading: a sent reply, comment or quote replaces the page-visit rows of the same post.
        let replies = out.filter { e in
            guard let m = e.message, m.sent, !e.host.isEmpty else { return false }
            return [ComposeKind.replied, .commented, .quoted].map(\.rawValue).contains(m.kind)
        }
        guard !replies.isEmpty else { return out }
        func page(_ e: MomentDetailEntry) -> String? {
            guard let id = e.actionIDs.first, let a = byID[id], !a.title.isEmpty, a.title != MomentHistoryCondense.withheldTitle else { return nil }
            return e.host + "|" + a.title.lowercased()
        }
        let replyPages = Dictionary(replies.compactMap { r in page(r).map { ($0, r.id) } }, uniquingKeysWith: { first, _ in first })
        var kept: [MomentDetailEntry] = []
        for e in out {
            if e.message == nil, e.isWeb, e.typed.isEmpty, e.sends.isEmpty, let p = page(e), let reply = replyPages[p],
               e.actionIDs.allSatisfy({ byID[$0].map { MomentHistoryCondense.viewKinds.contains($0.kind) } ?? false }) {
                kept.append(e); kept[kept.count - 1].replacedBy = reply
                continue
            }
            kept.append(e)
        }
        var ids = [String: [String]]()
        for e in kept { if let r = e.replacedBy { ids[r, default: []] += e.actionIDs } }
        return kept.filter { $0.replacedBy == nil }.map { e in
            guard e.message != nil, let more = ids[e.id] else { return e }
            return absorb(e, ids: more)
        }
    }

    // Each builder copies the whole entry and changes only what it must, so fields other folds add to
    // `MomentDetailEntry` (a withheld reason, …) carry through.
    static func make(_ e: MomentDetailEntry, line: Line, words: String, context: String?, earlier: MomentDetailEntry? = nil) -> MomentDetailEntry {
        let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = e.typed.last ?? earlier?.typed.last
        let blocks = text.isEmpty ? [] : [MomentTypedBlock(id: head?.id ?? e.id, at: head?.at ?? "", app: head?.app ?? e.app,
            bundle: head?.bundle ?? e.bundle, host: e.host, title: line.name ?? (head?.title ?? e.title), text: text, send: nil)]
        var out = e
        if let earlier { out.id = earlier.id; out.first = earlier.first ?? e.first; out.actionIDs = earlier.actionIDs + e.actionIDs }
        out.title = line.title; out.detail = ""; out.sends = []; out.typed = blocks
        out.capturedWordingUnavailable = blocks.isEmpty && (e.capturedWordingUnavailable || earlier?.capturedWordingUnavailable == true)
        out.message = line
        out.messageWords = words
        out.context = context ?? earlier?.context
        return out
    }

    static func absorb(_ e: MomentDetailEntry, ids: [String]) -> MomentDetailEntry {
        var out = e
        out.actionIDs += ids
        return out
    }

    static func retitle(_ e: MomentDetailEntry, _ line: Line) -> MomentDetailEntry {
        var out = e
        out.title = line.title
        out.message = line
        return out
    }
}
