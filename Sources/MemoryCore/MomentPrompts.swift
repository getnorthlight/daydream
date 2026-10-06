import Foundation
import PrivacyPolicy

// fix/prompt-row (owner-approved 2026-09-28): an AI-app moment's row shows the start of what the person typed to the AI
// ("“how do I fix the export crash…”"), on this Mac only, before and without a summary.
//
// Two steps, so the words never travel further than the one window that draws them:
// 1. `momentPromptRows` (metadata only, any process, a reader connection): for each moment, which of its typed rows is
//    the ask. Its surface (ai | aiTool, the same code decision that writes "Asked ChatGPT") and its send fact, never
//    its words.
// 2. `ownerMomentPrompts` (the DayDream app's own process only): opens those rows with the owner disclosure through
//    `hydrateTypedText`, the one way to the words, so every gate holds: typing on, a ready key in this process (no
//    MCP, CLI or other process holds one), a record not forgotten, hidden, blocked or past the kept period, and a
//    sealed row that matches the record. It writes nothing, and nothing it returns is stored, indexed, logged or
//    handed to a writer, an AI app or the cloud: the app's timeline (MemoryUI) is its only caller.

/// One moment the timeline asks about: its member actions, and its main app and first site (a prompt is shown only
/// for a moment in the AI app it was typed in, or, owner 10/6, an X moment's newest confirmed post or reply).
public struct MomentPromptRequest: Equatable, Sendable {
    public let momentID: String
    public let actionIDs: [String]
    public let primaryBundle: String?
    public let site: String?
    /// claude/livefix-1004 (owner, live test 10/3): a moment without a note yet (one still going: an hour of Claude Code
    /// in one Ghostty window is one moment) shows its NEWEST ask, so what was just asked is on the card right away. A
    /// moment with a note keeps the first ask (its note's line wins there anyway: `MomentSubtitle.shownPrompt`).
    public let newestFirst: Bool
    public init(momentID: String, actionIDs: [String], primaryBundle: String?, site: String?, newestFirst: Bool = false) {
        self.momentID = momentID; self.actionIDs = actionIDs; self.primaryBundle = primaryBundle; self.site = site
        self.newestFirst = newestFirst
    }
}

public enum MomentPromptText {
    /// The most characters a row keeps (a 12 pt line holds about 90 at the widest window; the row cuts the rest).
    public static let limit = 200
    /// One line: every run of whitespace (spaces, tabs, newlines, line and paragraph separators) or control characters
    /// becomes one space, trimmed at both ends; longer than `limit` characters, cut there with "…" (so the row's own
    /// cut shows even in a window wide enough for all of it). Empty when nothing is left.
    public static func clean(_ raw: String, limit: Int = limit) -> String {
        // A long paste costs no more than its start: collapsing can only shorten, so 8x the limit is always enough.
        let head = raw.prefix(max(limit, 1) * 8)
        let parts = head.split(whereSeparator: { $0.isWhitespace || $0.isNewline || $0.unicodeScalars.allSatisfy { $0.properties.generalCategory == .control } })
        var line = parts.joined(separator: " ")
        let cut = line.count > limit || (head.endIndex != raw.endIndex && raw[head.endIndex...].contains { !$0.isWhitespace })
        if cut { line = String(line.prefix(max(0, limit - 1))).trimmingCharacters(in: .whitespaces) + "…" }
        return line
    }
    /// Surfaces an ask goes to: an AI app or site, or Claude Code / Codex in a terminal (`SendRules.surface`).
    public static let surfaces: Set<String> = ["ai", "aiTool"]
    /// At most this many rows per moment are tried, in order, when the first doesn't open (hidden, expired, forgotten).
    static let candidatesPerMoment = 4

    // Owner 10/6: an X moment's row leads with its newest post or reply code CONFIRMED sent (`ComposeSend`: a gesture
    // and a confirmation), as the expanded card says it: "Posted “…” on X." / "Replied “…” on X.". A draft never leads.
    /// X's own hosts (a moment is on X when its first site is one).
    public static let xHosts: Set<String> = ["x.com", "twitter.com", "mobile.twitter.com"]
    /// "Posted" for a confirmed post or quote on X, "Replied" for a confirmed reply; nil for anything else (a draft, an
    /// unconfirmed gesture, another site).
    public static func xLead(_ o: ComposeOutcome) -> String? {
        guard o.destination.service == "X" else { return nil }
        switch o.kind {
        case .posted, .quoted: return "Posted"
        case .replied: return "Replied"
        default: return nil
        }
    }
    /// The words after "Posted “" / "Replied “" ("” on X." closes them).
    public static let xTail = " on X."
    /// A confirmed X send as the row's prompt: its lead, when it was typed (so a card of several X moments leads with
    /// the most recent send) and its cleaned words, carried in one value (`TodaySnapshot.withPrompts` splits them again
    /// with `split`). The mark never appears in typed words (`clean` turns control characters into spaces).
    static let sentMark = "\u{1E}"
    public static func sent(lead: String, at: String, words: String) -> String { sentMark + lead + sentMark + at + sentMark + words }
    /// A row's prompt value: its words, and for an X send its lead ("Posted", "Replied") and time.
    public struct Value: Equatable, Sendable {
        public let words: String
        public let lead: String?
        public let at: String?
    }
    public static func split(_ value: String) -> Value {
        let parts = value.components(separatedBy: sentMark)
        guard value.hasPrefix(sentMark), parts.count == 4 else { return Value(words: value, lead: nil, at: nil) }
        return Value(words: parts[3], lead: parts[1], at: parts[2])
    }
}

extension MemoryStore {
    /// Metadata only (no words, any process): for each moment, its AI ask rows in the order the timeline tries them:
    /// the first typing run with a detected send, then the other runs in time order; each run by its first part.
    /// A moment qualifies only when the ask was typed in the moment's main app (and, for a website, on its first
    /// site). A typed row flagged secure is never a candidate.
    public func momentPromptRows(_ requests: [MomentPromptRequest]) throws -> [String: [String]] {
        let wanted = requests.filter { !$0.actionIDs.isEmpty }
        guard !wanted.isEmpty, try hasTypedTables() else { return [:] }
        let ids = Array(Set(wanted.flatMap(\.actionIDs)))
        // Only rows with sealed words (typed_text, a small table) are read; the day's other actions cost a lookup each.
        let found = try rows("""
            SELECT r.id, coalesce(json_extract(r.body,'$.at'),''), coalesce(json_extract(r.body,'$.bundle'),''),
                   coalesce(json_extract(r.body,'$.url'),''), coalesce(json_extract(r.body,'$.title'),''),
                   coalesce(json_extract(r.body,'$.captureProvenance.unit.surface'),''),
                   coalesce(json_extract(r.body,'$.captureProvenance.unit.send'),''),
                   coalesce(json_extract(r.body,'$.captureProvenance.unit.runID'),''),
                   coalesce(json_extract(r.body,'$.captureProvenance.unit.part'),1)
            FROM json_each(?) j JOIN typed_text t ON t.id=j.value JOIN records r ON r.id=t.id
            WHERE json_extract(r.body,'$.kind')='keyboard.text_input' AND coalesce(json_extract(r.body,'$.secure'),0) IN (0,'false')
            """, [json(ids)])
        struct Row { let id, at, bundle, host, surface, send, run: String; let part: Int }
        var byID = [String: Row](), onX = [String: Row]()
        for f in found {
            let host = Self.promptHost(f[3])
            let surface = f[5].isEmpty ? SendRules.surface(bundle: f[2], host: host.isEmpty ? nil : host, title: f[4]) : f[5]
            let row = Row(id: f[0], at: f[1], bundle: f[2], host: host, surface: surface, send: f[6], run: f[7].isEmpty ? f[0] : f[7], part: Int(f[8]) ?? 1)
            if MomentPromptText.surfaces.contains(surface) { byID[f[0]] = row }
            else if MomentPromptText.xHosts.contains(host) { onX[f[0]] = row }
        }
        // Owner 10/6: on X, only rows code confirmed sent as a post or reply (metadata: `composeOutcomes`, never words).
        let xSent = onX.isEmpty ? [:] : try composeOutcomes(Array(onX.keys)).filter { MomentPromptText.xLead($0.value) != nil }
        guard !byID.isEmpty || !xSent.isEmpty else { return [:] }
        var out = [String: [String]]()
        for request in wanted {
            let site = Self.promptHost(request.site ?? "")
            if MomentPromptText.xHosts.contains(site) {
                // The newest confirmed send first, one row per typing run (its last part: the words that were sent).
                let sends = request.actionIDs.compactMap { xSent[$0] == nil ? nil : onX[$0] }
                    .filter { $0.bundle == request.primaryBundle }
                    .sorted { ($0.at, $0.part, $0.id) > ($1.at, $1.part, $1.id) }
                var seen = Set<String>(), ids = [String]()
                for row in sends where seen.insert(row.run).inserted { ids.append(row.id) }
                if !ids.isEmpty { out[request.momentID] = Array(ids.prefix(MomentPromptText.candidatesPerMoment)) }
                continue
            }
            let asks = request.actionIDs.compactMap { byID[$0] }.filter { row in
                guard let main = request.primaryBundle, main == row.bundle else { return false }
                // A website ask belongs to the moment only when the moment is on that site.
                return row.host.isEmpty || site.isEmpty || row.host == site || row.host.hasSuffix("." + site) || site.hasSuffix("." + row.host)
            }.sorted { ($0.at, $0.part, $0.id) < ($1.at, $1.part, $1.id) }
            guard !asks.isEmpty else { continue }
            // One candidate per typing run (its first part: the start of what was typed), sent runs first.
            var runs = [String](), firstPart = [String: Row](), sent = Set<String>()
            for row in asks {
                if firstPart[row.run] == nil { runs.append(row.run); firstPart[row.run] = row }
                else if let known = firstPart[row.run], (row.part, row.at) < (known.part, known.at) { firstPart[row.run] = row }
                if row.send == "detected" { sent.insert(row.run) }
            }
            // Newest first (claude/livefix-1004): the runs by their first part's time, latest first, sent runs still first.
            let byTime = request.newestFirst ? Array(runs.reversed()) : runs
            let ordered = byTime.filter(sent.contains) + byTime.filter { !sent.contains($0) }
            out[request.momentID] = Array(ordered.compactMap { firstPart[$0]?.id }.prefix(MomentPromptText.candidatesPerMoment))
        }
        return out
    }

    /// The DayDream window on this Mac only: each moment's ask, opened with the owner disclosure (`hydrateTypedText`:
    /// typing on, a ready key in this process, the record still shown and kept) and cleaned to one line
    /// (`MomentPromptText.clean`). Empty in a process without a ready key (every MCP and CLI process) and while typing
    /// is off. Read only: it writes nothing.
    public func ownerMomentPrompts(_ candidates: [String: [String]], now: Date = Date()) throws -> [String: String] {
        guard !candidates.isEmpty, typedVaultState == .ready, try policy().captureText else { return [:] }
        // Owner 10/6: a confirmed X post or reply carries its lead ("Posted", "Replied": `MomentPromptText.sent`).
        let outcomes = try composeOutcomes(Array(Set(candidates.values.flatMap { $0 })), now: now)
        var out = [String: String]()
        for (moment, ids) in candidates {
            for id in ids {
                guard let words = try hydrateTypedText(id, disclosure: .owner, now: now) else { continue }
                let line = MomentPromptText.clean(words)
                guard !line.isEmpty else { continue }
                let at = try rows("SELECT coalesce(json_extract(body,'$.at'),'') FROM records WHERE id=?", [id]).first?.first ?? ""
                out[moment] = outcomes[id].flatMap(MomentPromptText.xLead).map { MomentPromptText.sent(lead: $0, at: at, words: line) } ?? line
                break
            }
        }
        return out
    }

    /// "https://www.chatgpt.com/c/1" → "chatgpt.com"; "" for no address.
    static func promptHost(_ raw: String) -> String {
        var h = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        if let colon = h.firstIndex(of: ":") { h = String(h[..<colon]) }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}
