import Foundation
import PrivacyPolicy

// fix/show-all (owner-approved 2026-09-29): a moment's full view ("Show All") shows what the person typed in it, on this
// Mac only, in readable blocks per app and page with a time, and marks the sends (who only) in its list of actions.
//
// The same two steps and gates as the timeline's ask (fix/prompt-row, MomentPrompts.swift):
// 1. `momentTypedRows` (metadata only, any process, a reader connection): the moment's typed rows in time order, with
//    their app, page, window title, typing run and send line by code ("Asked Claude", "Texted Q7"), never their words.
//    A row flagged secure (a password field) is never listed.
// 2. `ownerMomentTyped` (the DayDream app's own process only): opens those rows with the owner disclosure through
//    `hydrateTypedText`, the one way to the words: typing on, a ready key in this process (no MCP, CLI or other process
//    holds one), a record not forgotten, hidden, blocked or past the kept period, and a sealed row that matches the
//    record. It writes nothing, and nothing it returns is stored, indexed, logged or handed to a writer, an AI app or
//    the cloud: the moment's detail view (MemoryUI) is its only caller, and it keeps the blocks in view state only.

/// One typed row of a moment, metadata only (never its words).
public struct MomentTypedRow: Equatable, Sendable {
    public let id: String
    /// The row's ISO time.
    public let at: String
    public let app: String
    public let bundle: String
    /// The page's host ("chatgpt.com"); empty in a native app.
    public let host: String
    public let title: String
    public let run: String
    public let part: Int
    /// The send by code, who only ("Asked Claude", "Texted Q7", "Emailed Sam"), where a send gesture was detected; else nil.
    public let send: String?
    public init(id: String, at: String, app: String, bundle: String, host: String, title: String, run: String, part: Int, send: String?) {
        self.id = id; self.at = at; self.app = app; self.bundle = bundle; self.host = host; self.title = title
        self.run = run; self.part = part; self.send = send
    }
}

/// What was typed in one place (one app, page and window) in a row of the moment: its words, opened on this Mac for the
/// detail view only.
public struct MomentTypedBlock: Equatable, Sendable, Identifiable {
    /// The block's first row.
    public let id: String
    /// The first row's ISO time.
    public let at: String
    public let app: String
    public let bundle: String
    public let host: String
    public let title: String
    /// The words: each typed row on its own line, cleaned (`MomentTypedText.clean`), at most `MomentTypedText.blockLimit`.
    public let text: String
    /// The block's first send line ("Asked Claude"), if any of its rows was sent.
    public let send: String?
    public init(id: String, at: String, app: String, bundle: String, host: String, title: String, text: String, send: String?) {
        self.id = id; self.at = at; self.app = app; self.bundle = bundle; self.host = host; self.title = title
        self.text = text; self.send = send
    }
}

public enum MomentTypedText {
    /// The most characters one block keeps (a long paste shows its start, cut with "…").
    public static let blockLimit = 4000
    /// At most this many typed rows of one moment are opened.
    public static let rowLimit = 400

    /// Readable text: line breaks kept (Windows and old Mac breaks, line and paragraph separators become "\n"), tabs and
    /// other whitespace runs inside a line become one space, control characters go, trailing spaces go, more than one
    /// blank line becomes one, trimmed at both ends; longer than `limit` characters, cut there with "…".
    public static func clean(_ raw: String, limit: Int = blockLimit) -> String {
        let head = raw.prefix(max(limit, 1) * 8)
        var lines = [String]()
        var line = "", space = false
        func endLine() { lines.append(line); line = ""; space = false }
        for ch in head.replacingOccurrences(of: "\r\n", with: "\n") {
            if ch == "\n" || ch == "\r" || ch == "\u{2028}" || ch == "\u{2029}" { endLine(); continue }
            if ch.isWhitespace { space = !line.isEmpty; continue }
            if ch.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .control || $0.properties.generalCategory == .format && $0.value != 0x200D }) { continue }
            if space { line.append(" "); space = false }
            line.append(ch)
        }
        endLine()
        var out = [String](), blank = false
        for l in lines {
            if l.isEmpty { if !out.isEmpty { blank = true }; continue }
            if blank { out.append(""); blank = false }
            out.append(l)
        }
        var text = out.joined(separator: "\n")
        let cut = text.count > limit || (head.endIndex != raw.endIndex && raw[head.endIndex...].contains { !$0.isWhitespace })
        if cut { text = String(text.prefix(max(0, limit - 1))).trimmingCharacters(in: .whitespacesAndNewlines) + "…" }
        return text
    }

    /// Rows in time order folded into blocks: consecutive rows in the same app, page and window title are one block,
    /// each row's words on their own line. A row whose words didn't open (`words[id]` nil or empty) is left out and
    /// doesn't split a block.
    public static func blocks(_ rows: [MomentTypedRow], words: [String: String], limit: Int = blockLimit) -> [MomentTypedBlock] {
        struct Open { var first: MomentTypedRow; var parts: [String]; var send: String? }
        var out = [MomentTypedBlock](), open: Open?
        func key(_ r: MomentTypedRow) -> String { r.bundle + "|" + r.host + "|" + r.title }
        func close() {
            guard let o = open else { return }
            let text = clean(o.parts.joined(separator: "\n"), limit: limit)
            if !text.isEmpty {
                out.append(MomentTypedBlock(id: o.first.id, at: o.first.at, app: o.first.app, bundle: o.first.bundle, host: o.first.host,
                                            title: o.first.title, text: text, send: o.send))
            }
            open = nil
        }
        for row in ordered(rows) {
            guard let w = words[row.id], !clean(w, limit: 16).isEmpty else { continue }
            if let o = open, key(o.first) == key(row) {
                open?.parts.append(w)
                if o.send == nil { open?.send = row.send }
            } else {
                close()
                open = Open(first: row, parts: [w], send: row.send)
            }
        }
        close()
        return out
    }

    /// Time order, then run part, then id.
    static func ordered(_ rows: [MomentTypedRow]) -> [MomentTypedRow] {
        rows.sorted { ($0.at, $0.part, $0.id) < ($1.at, $1.part, $1.id) }
    }
}

extension MemoryStore {
    /// Metadata only (no words, any process): the typed rows among `actionIDs`, in time order, with each one's send line
    /// by code (`label`: the moment's own name, for a conversation's who). A row flagged secure is never listed.
    public func momentTypedRows(_ actionIDs: [String], label: String = "") throws -> [MomentTypedRow] {
        let ids = Array(Set(actionIDs.filter { !$0.isEmpty }))
        guard !ids.isEmpty else { return [] }
        let found = try rows("""
            SELECT r.id, coalesce(json_extract(r.body,'$.at'),''), coalesce(json_extract(r.body,'$.app'),''),
                   coalesce(json_extract(r.body,'$.bundle'),''), coalesce(json_extract(r.body,'$.url'),''),
                   coalesce(json_extract(r.body,'$.title'),''),
                   coalesce(json_extract(r.body,'$.captureProvenance.unit.surface'),''),
                   coalesce(json_extract(r.body,'$.captureProvenance.unit.send'),''),
                   coalesce(json_extract(r.body,'$.captureProvenance.unit.runID'),''),
                   coalesce(json_extract(r.body,'$.captureProvenance.unit.part'),1)
            FROM json_each(?) j JOIN records r ON r.id=j.value
            WHERE json_extract(r.body,'$.kind')='keyboard.text_input' AND coalesce(json_extract(r.body,'$.secure'),0) IN (0,'false')
            """, [json(ids)])
        let sent = found.filter { $0[7] == "detected" }.map { $0[0] }
        let recipients = try typedRecipients(sent)
        let facts = try typedSendFacts(sent)
        let rows = found.map { f -> MomentTypedRow in
            let host = Self.promptHost(f[4])
            var send: String?
            if f[7] == "detected" {
                let action = CanonicalAction(id: f[0], evidenceIDs: [f[0]], at: f[1], kind: "keyboard.text_input", app: f[2], bundle: f[3],
                                             site: host, title: f[5], description: "", state: "submitted", revision: "", subject: "", observationKey: "")
                let to = (recipients[f[0]] ?? facts[f[0]]?.to).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty || $0.contains("@") ? nil : $0 }
                send = Self.sendLine(action, surface: f[6].isEmpty ? nil : f[6], to: to, label: label)
            }
            return MomentTypedRow(id: f[0], at: f[1], app: f[2], bundle: f[3], host: host, title: f[5], run: f[8].isEmpty ? f[0] : f[8],
                                  part: Int(f[9]) ?? 1, send: send)
        }
        return Array(MomentTypedText.ordered(rows).prefix(MomentTypedText.rowLimit))
    }

    /// The DayDream window on this Mac only: the words of these typed rows, opened with the owner disclosure
    /// (`hydrateTypedText`: typing on, a ready key in this process, the record still shown and kept) and folded into
    /// blocks per place (`MomentTypedText.blocks`). Empty in a process without a ready key (every MCP and CLI process)
    /// and while typing is off. Read only: it writes nothing.
    public func ownerMomentTyped(_ rows: [MomentTypedRow], now: Date = Date()) throws -> [MomentTypedBlock] {
        guard !rows.isEmpty, typedVaultState == .ready, try policy().captureText else { return [] }
        var words = [String: String]()
        for row in rows.prefix(MomentTypedText.rowLimit) {
            if let w = try hydrateTypedText(row.id, disclosure: .owner, now: now) { words[row.id] = w }
        }
        return MomentTypedText.blocks(rows, words: words)
    }
}
