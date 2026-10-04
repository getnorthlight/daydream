import Foundation
import PrivacyPolicy

/// compose-send/v1 (`ComposeSend`): a send proven after the row was written. A gesture (Return) sealed the unit and
/// wrote it at once (the key is still in the tap then); the capture layer then re-reads the composer and, when the same
/// window's composer is confirmed (`ComposeConfirmation`) within `ComposeSend.confirmWindow`, marks that row's send
/// facts. A send gesture, never a delivery: "sent" stays receipt-only.
public enum ComposeSendTiming {
    /// A row older than this is never marked.
    public static let rowAge: TimeInterval = 5
}

extension TypedUnitProvenance {
    /// The identity adapter's destination and context as stored.
    public var composeDestination: ComposeDestination {
        ComposeDestination(name: to, handle: handle, community: community, subject: subject)
    }
    public var composeContext: ComposeContext { ComposeContext(author: contextAuthor, excerpt: contextExcerpt) }
    /// Stores an adapter's destination and context (nil fields stay absent).
    public mutating func apply(destination d: ComposeDestination, context c: ComposeContext) {
        if let n = d.name, !n.isEmpty, (to ?? "").isEmpty { to = n }
        handle = d.handle.flatMap { $0.isEmpty ? nil : $0 }
        community = d.community.flatMap { $0.isEmpty ? nil : $0 }
        subject = d.subject.flatMap { $0.isEmpty ? nil : $0 }
        contextAuthor = c.author.flatMap { $0.isEmpty ? nil : $0 }
        contextExcerpt = c.excerpt.map(ComposeSend.clipContext).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// The one reading of a typed row's compose outcome, for cards, search and summaries.
public enum ComposeView {
    /// The surface's display name for lines ("X", "Messages", "ChatGPT"), from the row's app or site.
    public static func service(_ e: Evidence) -> String {
        let host = URL(string: e.url)?.host ?? ""
        if let ai = SendRules.aiName(bundle: e.bundle, host: host) { return ai }
        for (domain, name) in [("x.com", "X"), ("twitter.com", "X"), ("reddit.com", "Reddit"), ("linkedin.com", "LinkedIn"), ("threads.net", "Threads"),
                               ("bsky.app", "Bluesky"), ("mail.google.com", "Gmail"), ("app.slack.com", "Slack"), ("discord.com", "Discord")]
            where host == domain || host.hasSuffix("." + domain) { return name }
        return e.app
    }
    /// The outcome of a typed row (`keyboard.text_input` with send facts), or nil for any other row.
    public static func outcome(_ e: Evidence) -> ComposeOutcome? {
        guard e.kind == "keyboard.text_input", let u = e.captureProvenance?.unit, u.version == TypedUnitProvenance.sendFactsVersion else { return nil }
        var o = ComposeSend.outcome(surface: u.surface ?? "", field: u.field ?? "", send: u.send, sendBy: u.sendBy, sendControl: u.sendControl,
                                    to: u.to, destination: u.composeDestination, context: u.composeContext)
        o.destination.service = service(e)
        // B2: Messages names come only from the unit's own verified recipient. claude/messages2-1003: or, for a proven
        // message box, the number or address its own window title showed (`MessagesMomentIdentity.conversation`).
        if MessagesMomentIdentity.applies(bundle: e.bundle, app: e.app) { o.destination.name = MessagesMomentIdentity.conversation(u, title: e.title) }
        // claude/messages2-1003: a unit sealed by a send gesture is a whole message even when no send was confirmed.
        o.sealedBy = ComposeSend.gesture(seal: u.sealReason)
        return o
    }
    /// "Sent to Jamie", "Replied to Ada's post on X", "Draft to Jamie (not sent)", …
    public static func line(_ e: Evidence) -> String? { outcome(e).map(ComposeSend.line) }
    /// The muted replied-to line (`on: “…”`), or nil.
    public static func contextLine(_ e: Evidence) -> String? { outcome(e).flatMap { ComposeSend.contextLine($0.context) } }
}

extension MemoryStore {
    /// The compose outcomes of these typed rows by ID (`ComposeView.outcome`), read under the current privacy policy.
    /// Metadata only, never the typed words; rows without send facts, deleted or withheld are absent.
    public func composeOutcomes(_ ids: [String], now: Date = Date()) throws -> [String: ComposeOutcome] {
        var out = [String: ComposeOutcome]()
        for id in Set(ids) { if let e = try permittedOriginal(id, now: now), let o = ComposeView.outcome(e) { out[id] = o } }
        return out
    }
    /// Marks one typed row sent by a confirmed gesture (`ComposeSend.confirmedSend`): send "detected", `sendBy` the
    /// gesture, `confirm` the confirmation. Only a v3 row of `windowID` sealed by that gesture, in a confirmable composer,
    /// not marked yet, written within `ComposeSendTiming.rowAge`, while recording, under the policy it was written
    /// with. Returns whether the row changed.
    ///
    /// claude/int-1003: a row the seal already decided was sent by this same gesture (X's or Reddit's Command-Return,
    /// `SendRules.send`) and has no confirmation yet gets only its `confirm` (the browser route's re-read,
    /// `BrowserComposeSignals.confirmation`); its send facts stay as they were.
    @discardableResult public func markComposerSent(id: String, windowID: String, gesture: ComposeGesture = .returnKey,
                                                    confirmation: ComposeConfirmation = .fieldCleared,
                                                    expectedPolicyRevision: String, now: Date = Date()) throws -> Bool {
        try transaction {
            guard try policy().revision == expectedPolicyRevision, try captureStatus(now: now)["state"] == "recording",
                  try rows("SELECT id FROM tombstones WHERE id=?", [id]).isEmpty,
                  let row = try rows("SELECT body, revision FROM records WHERE id=?", [id]).first, row.count == 2 else { return false }
            var e = try decode(Evidence.self, row[0])
            // A native row's window, or a website row's (`BrowserVerification.windowID`, for the web routes).
            guard e.kind == "keyboard.text_input", (e.captureProvenance?.windowID ?? e.browserVerification?.windowID) == windowID,
                  let unit = e.captureProvenance?.unit, unit.version == TypedUnitProvenance.sendFactsVersion,
                  unit.send != "detected" || (unit.sendBy == gesture.rawValue && unit.confirm == nil),
                  ComposeSend.gesture(seal: unit.sealReason) == gesture || (gesture == .button && ComposeSend.buttonSeals.contains(unit.sealReason)),
                  let facts = ComposeSend.confirmedSend(surface: unit.surface ?? "", field: unit.field ?? "", gesture: gesture, confirmation: confirmation),
                  let at = timestamp(e.at), now.timeIntervalSince(at) >= -1, now.timeIntervalSince(at) <= ComposeSendTiming.rowAge,
                  try typedIngestPermitted(e, now: now) else { return false }
            e.captureProvenance?.unit?.send = facts.send
            e.captureProvenance?.unit?.sendBy = facts.sendBy
            e.captureProvenance?.unit?.confirm = facts.confirm
            let body = try json(e), revision = fingerprint(body)
            try exec("UPDATE records SET body=?, revision=? WHERE id=? AND revision=?", [body, revision, id, row[1]])
            guard try rows("SELECT revision FROM records WHERE id=?", [id]).first?.first == revision else { return false }
            try exec("DELETE FROM summaries WHERE id=? AND revision<>?", [id, revision])
            try invalidateDisclosure(invalidateSnapshots: true)
            return true
        }
    }
}
