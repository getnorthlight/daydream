import Foundation
import MemoryCore
import PrivacyPolicy

/// claude/terminal-details-1003 (owner 10/03, a Claude Code session in Ghostty): "What happened" after the condense.
///
/// 1. Terminal prompts. One line typed into a terminal is saved as several typed rows whenever typing is cut (an app
///    switch, a click, a title change), and only the last piece carries the Return. Here every piece typed in the same
///    terminal app up to its Return is ONE line, whatever the window title did in between (spinner glyphs, a tool
///    renaming the tab) and whatever other apps came between. A line sent with Return into an AI coding tool (Claude
///    Code, Codex, … by its window titles) reads "Asked Claude Code"; a shell line reads "Ran a command"; pieces never
///    followed by a Return read "Typed" / "Typed, not run". The words of all pieces are one quote.
/// 2. A Return right after a typed line in the same app is that line's send, not a row of its own.
/// 3. Quiet "Worked in …" rows fold into a neighbouring line of the same app (time and actions kept behind it); one
///    stays only where no neighbour is that app's (a noise-only card is still its one line).
///
/// Display only: no stored description, state or revision changes. Every action stays behind exactly one line.
enum MomentDetailFold {
    /// A Return this soon after a typed line in the same app is its send.
    static let returnFoldSeconds: TimeInterval = 10

    static func fold(_ lines: [MomentDetailEntry], entries: [MomentDetailEntry], actions: [CanonicalAction],
                     timeZone: TimeZone) -> [MomentDetailEntry] {
        guard !lines.isEmpty else { return lines }
        let byID = Dictionary(actions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var reasons = [String: String]()
        for e in entries { if let r = e.withheldReason { for id in e.actionIDs { reasons[id] = r } } }
        var restored = lines
        for i in restored.indices where restored[i].withheldReason == nil && restored[i].typed.isEmpty {
            if let r = restored[i].actionIDs.lazy.compactMap({ reasons[$0] }).first { restored[i].withheldReason = r; restored[i].capturedWordingUnavailable = true }
        }
        let prompts = terminalPrompts(restored, byID: byID, actions: actions)
        let sends = returnsIntoTyped(prompts, byID: byID)
        return reading(quiet(sends, byID: byID), byID: byID)
    }

    // MARK: kinds

    static func kinds(_ e: MomentDetailEntry, _ byID: [String: CanonicalAction]) -> Set<String> {
        Set(e.actionIDs.compactMap { byID[$0]?.kind })
    }
    static func isTyped(_ e: MomentDetailEntry, _ byID: [String: CanonicalAction]) -> Bool {
        !e.quiet && !e.isWeb && kinds(e, byID) == ["keyboard.text_input"]
    }
    static func isReturn(_ e: MomentDetailEntry, _ byID: [String: CanonicalAction]) -> Bool {
        !e.quiet && kinds(e, byID) == ["keyboard.submit"]
    }
    static func submitted(_ e: MomentDetailEntry, _ byID: [String: CanonicalAction]) -> Bool {
        // A unit sealed by its send key, or a stored "Ran a command in …" description (terminal-1002).
        e.actionIDs.contains { byID[$0]?.state == "submitted" || byID[$0]?.description.hasPrefix(TypedWords.ranCommandLabel + " in ") == true }
    }

    // MARK: AI coding tools in terminals

    /// The AI coding tool a terminal app's window titles show, from the moment's own actions in that app: a title naming
    /// the tool ("claude", "codex", a tool command via `TitleClean.terminalName`), or Claude Code's own title mark "✳".
    /// nil: no tool is shown (a shell).
    static func aiTool(bundle: String, actions: [CanonicalAction]) -> String? {
        var spinner = false
        for a in actions where a.bundle == bundle && !a.title.isEmpty {
            // claude/int-1003: reads drop the glyph (title-spinner-1003); the tool it named is kept on the action.
            if let tool = a.tool { if !tool.isEmpty { return tool }; spinner = true; continue }
            if let named = toolNamed(a.title) { return named }
            if a.title.unicodeScalars.first.map({ claudeMarks.contains($0.value) }) == true { return "Claude Code" }
            if a.title.unicodeScalars.first.map({ spinnerMarks.contains($0.value) || (0x2800...0x28FF).contains($0.value) }) == true,
               !TitleClean.terminalName(a.title).isEmpty { spinner = true }
        }
        return spinner ? "" : nil
    }
    /// claude/cc-label-1003 (owner 10/03): the tool ONE terminal line went to. Claude Code's tab title names it by a glyph
    /// only while it shows one (core keeps it as the action's `tool`; "" a bare spinner), so a line typed while the title
    /// was plain, or only spinning, named no tool and every prompt read "Ran a command". In order:
    /// 1. the line's own typed rows' tool, else the tool any row of the moment with the same window title has (the window
    ///    keeps its tool while its title stays the same);
    /// 2. a busy spinner on the line or its title: a tool ("" when the moment names none);
    /// 3. a prompt-shaped line (`PromptShape`: sentences, not a command) in a window that is no shell's ("~",
    ///    "harborline — zsh"): the moment's tool in that app (`aiTool`), else "" ("Sent a prompt");
    /// 4. anything else, in another window: a command (nil), even beside a Claude Code tab.
    static func lineTool(_ pieces: [MomentDetailEntry], byID: [String: CanonicalAction], actions: [CanonicalAction]) -> String? {
        guard let head = pieces.last else { return nil }
        let own = pieces.flatMap(\.actionIDs).compactMap { byID[$0] }.filter { $0.kind == "keyboard.text_input" }
        if let t = own.lazy.compactMap(\.tool).first(where: { !$0.isEmpty }) { return t }
        let titles = Set((own.map(\.title) + pieces.map(\.title)).map(titleKey).filter { !$0.isEmpty })
        let same = actions.filter { $0.bundle == head.bundle && titles.contains(titleKey($0.title)) }
        if let t = same.lazy.compactMap(\.tool).first(where: { !$0.isEmpty }) { return t }
        if let t = same.lazy.compactMap({ toolNamed($0.title) ?? glyphTool($0.title) }).first(where: { !$0.isEmpty }) { return t }
        let weak = aiTool(bundle: head.bundle, actions: actions)
        if (own + same).contains(where: { $0.tool == "" || glyphTool($0.title) == "" }) { return weak ?? "" }
        let words = pieces.flatMap(\.typed).map(\.text).joined(separator: " ")
        let shaped = PromptShape.natural(words)
        let shell = (own.map(\.title) + [head.title]).contains(where: shellTitle)
        guard shaped, !shell else { return nil }
        return weak ?? ""
    }
    /// A window title as one window's: without its status glyphs, the case or the spaces.
    static func titleKey(_ title: String) -> String {
        TitleClean.statusless(title).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    /// A title still holding its glyph (a row an earlier build saved): Claude Code's star, or "" for a busy spinner.
    static func glyphTool(_ title: String) -> String? {
        guard let first = title.unicodeScalars.first else { return nil }
        if claudeMarks.contains(first.value) { return "Claude Code" }
        if spinnerMarks.contains(first.value) || (0x2800...0x28FF).contains(first.value), !TitleClean.terminalName(title).isEmpty { return "" }
        return nil
    }
    /// A shell's own title: a bare prompt ("~", "-zsh", "login — 120×30"), a folder ("~/harborline", "/Users/x"), the
    /// shell after the folder ("harborline — zsh"), or "user@host: ~/dir".
    static func shellTitle(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || TitleClean.terminalName(t).isEmpty { return true }
        if t.hasPrefix("~") || t.hasPrefix("/") { return true }
        if t.range(of: #"^[\w.-]+@[\w.-]+:"#, options: .regularExpression) != nil { return true }
        let last = t.components(separatedBy: " — ").last?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return ["zsh", "-zsh", "bash", "-bash", "fish", "-fish", "sh"].contains(last)
    }
    /// Claude Code's session title mark ("✳ Topic").
    static let claudeMarks: Set<UInt32> = [0x2733]
    /// A busy spinner a tool puts before its session title ("◐ Topic", "◑ Topic"); a tool, though not which one.
    static let spinnerMarks: Set<UInt32> = [0x25D0, 0x25D1, 0x25D2, 0x25D3]
    static func toolNamed(_ title: String) -> String? {
        let words = title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if words.contains("claude") { return "Claude Code" }
        if words.contains("codex") { return "Codex" }
        let named = TitleClean.terminalName(title)
        return ["Claude Code", "Codex", "Gemini CLI", "Aider"].contains(named) ? named : nil
    }
    /// The label of a terminal line: sent with Return into a tool, run in a shell, or never sent.
    static func promptLabel(sent: Bool, tool: String?) -> String {
        switch (sent, tool) {
        case (true, .some(let t)) where !t.isEmpty: return "Asked " + t
        case (true, .some): return "Sent a prompt"
        case (true, nil): return TypedWords.ranCommandLabel
        case (false, .some): return "Typed"
        case (false, nil): return "Typed, not run"
        }
    }

    // MARK: 1. terminal prompts

    static func terminalPrompts(_ lines: [MomentDetailEntry], byID: [String: CanonicalAction],
                                actions: [CanonicalAction]) -> [MomentDetailEntry] {
        struct Open { var pieces: [MomentDetailEntry] = []; var extra: [String] = []; var last: Date? }
        var out: [MomentDetailEntry] = []
        var open: [String: Open] = [:]
        var order: [String] = []
        func emit(_ bundle: String, sent: Bool) {
            guard let o = open.removeValue(forKey: bundle), !o.pieces.isEmpty else { return }
            order.removeAll { $0 == bundle }
            out.append(prompt(o.pieces, extra: o.extra, sent: sent, tool: lineTool(o.pieces, byID: byID, actions: actions), last: o.last))
        }
        // A Return and the piece it sealed share a second; read the piece first whichever order their IDs sorted them.
        var lines = lines
        for i in lines.indices.dropLast() where isReturn(lines[i], byID) && isTyped(lines[i + 1], byID) && lines[i].bundle == lines[i + 1].bundle {
            if let a = lines[i].first, let b = lines[i + 1].first, abs(b.timeIntervalSince(a)) <= 1 { lines.swapAt(i, i + 1) }
        }
        for l in lines {
            let terminal = MomentHistoryCondense.terminalBundles.contains(l.bundle)
            if terminal && isTyped(l, byID) {
                if open[l.bundle] == nil { order.append(l.bundle) }
                var o = open[l.bundle] ?? Open()
                o.pieces.append(l)
                o.last = max(o.last ?? .distantPast, l.last ?? l.first ?? .distantPast)
                open[l.bundle] = o
                if submitted(l, byID) { emit(l.bundle, sent: true) }
            } else if terminal && isReturn(l, byID), var o = open[l.bundle] {
                o.extra += l.actionIDs
                o.last = max(o.last ?? .distantPast, l.last ?? l.first ?? .distantPast)
                open[l.bundle] = o
                emit(l.bundle, sent: true)
            } else if l.quiet, open[l.bundle] != nil {
                // Time in the same terminal while the line was being typed belongs to it.
                open[l.bundle]?.extra += l.actionIDs
            } else {
                out.append(l)
            }
        }
        for bundle in order { emit(bundle, sent: false) }
        return out
    }

    /// One line for the pieces of one terminal line: the latest title the pieces had, the app, the label, one quote.
    static func prompt(_ pieces: [MomentDetailEntry], extra: [String], sent: Bool, tool: String?, last: Date?) -> MomentDetailEntry {
        let head = pieces[pieces.count - 1]
        let title = pieces.reversed().first { $0.title != $0.app && !$0.title.isEmpty }?.title ?? head.title
        let location = head.app == title ? "" : head.app
        let blocks = pieces.flatMap(\.typed)
        let whole = pieces.allSatisfy { !$0.typed.isEmpty }
        var typed: [MomentTypedBlock]
        if whole, let first = blocks.first {
            // The pieces were typed one after another into one line: their words in order are the line.
            let text = join(blocks.map(\.text))
            typed = [MomentTypedBlock(id: first.id, at: first.at, app: first.app, bundle: first.bundle, host: first.host,
                                      title: title, text: text, send: nil)]
        } else {
            typed = blocks.map { MomentTypedBlock(id: $0.id, at: $0.at, app: $0.app, bundle: $0.bundle, host: $0.host,
                                                  title: $0.title, text: $0.text, send: nil) }
        }
        let ids = pieces.flatMap(\.actionIDs) + extra
        let at = sent ? (head.last ?? head.first) : head.first
        var e = MomentDetailEntry(id: pieces[0].id, bundle: head.bundle, app: head.app, host: "", title: title,
            detail: [location, promptLabel(sent: sent, tool: tool)].filter { !$0.isEmpty }.joined(separator: " · "),
            first: at, last: max(last ?? .distantPast, at ?? .distantPast), actionIDs: ids, openActionID: nil, sends: [], typed: typed)
        if typed.isEmpty, let reason = pieces.lazy.compactMap(\.withheldReason).first {
            e.withheldReason = reason; e.capturedWordingUnavailable = true
        }
        return e
    }

    /// Pieces in typing order. A piece keeps its outer spaces when capture could prove them, so a boundary with a space
    /// joins as typed; a boundary with none (an older, trimmed piece) gets one space rather than gluing two words.
    static func join(_ pieces: [String]) -> String {
        var out = ""
        for p in pieces where !p.isEmpty {
            if let l = out.last, let f = p.first, !l.isWhitespace, !f.isWhitespace, !(f.isPunctuation && f != "(" && f != "\"") { out += " " }
            out += p
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 2. a Return right after typing

    /// claude/messages2-1003 (owner 10/3, "Messages · Pressed Return" between the sends): in Messages a Return row folds
    /// into the text line it belongs to (`MessagesTypedFold` already folded a confirmed send's): the line before it, or,
    /// when its unit's row was written after it, the line right after. Each text stays its own line.
    static func returnsIntoTyped(_ lines: [MomentDetailEntry], byID: [String: CanonicalAction]) -> [MomentDetailEntry] {
        var out: [MomentDetailEntry] = []
        for l in lines {
            let target = out.indices.last.map { i in messages(l) ? out[i].message != nil : true } ?? false
            if isReturn(l, byID), target, let i = out.indices.last, !out[i].quiet, out[i].bundle == l.bundle,
               out[i].actionIDs.contains(where: { byID[$0]?.kind == "keyboard.text_input" }),
               let sentAt = out[i].last ?? out[i].first, let at = l.first, at.timeIntervalSince(sentAt) <= returnFoldSeconds {
                out[i] = absorbing(out[i], l)
            } else {
                out.append(l)
            }
        }
        // A Messages Return no line before it took: the text line written right after it (quiet rows between them aside).
        var result: [MomentDetailEntry] = []
        var held: Int?
        for l in out {
            if isReturn(l, byID), messages(l) { result.append(l); held = result.count - 1; continue }
            if let h = held, l.message != nil, l.bundle == result[h].bundle, let at = result[h].first, let next = l.first,
               next.timeIntervalSince(at) >= -1, next.timeIntervalSince(at) <= returnFoldSeconds {
                let ret = result.remove(at: h)
                result.append(absorbing(l, ret, before: true))
                held = nil
                continue
            }
            if !l.quiet { held = nil }
            result.append(l)
        }
        return result
    }

    // MARK: 3. quiet rows

    static func quiet(_ lines: [MomentDetailEntry], byID: [String: CanonicalAction]) -> [MomentDetailEntry] {
        guard lines.contains(where: { !$0.quiet }) else { return lines }
        var out: [MomentDetailEntry] = []
        var pending: [MomentDetailEntry] = []   // quiet rows waiting for the next line of their app
        for l in lines {
            // claude/messages2-1003 (owner 10/3): Messages too: "Worked in Messages" between the texts folds into them.
            if l.quiet {
                if let i = out.indices.last, !out[i].quiet, out[i].bundle == l.bundle, out[i].app == l.app, pending.isEmpty {
                    out[i] = absorbing(out[i], l)
                } else {
                    pending.append(l)
                }
                continue
            }
            var line = l
            var kept: [MomentDetailEntry] = []
            for q in pending {
                if q.bundle == line.bundle && q.app == line.app { line = absorbing(line, q, before: true) } else { kept.append(q) }
            }
            out += kept
            pending = []
            out.append(line)
        }
        out += pending
        return out
    }

    /// Messages lines (claude/int-1003): their texts are MessagesTypedFold's (it runs first); claude/messages2-1003 folds
    /// their Return and quiet rows into those texts here.
    static func messages(_ l: MomentDetailEntry) -> Bool { l.bundle == "com.apple.MobileSMS" || (l.bundle.isEmpty && l.app == "Messages") }

    // MARK: 4. reading only (claude/messages2-1003)

    /// A Messages line that stayed quiet (nothing typed anywhere near it) says what it was: "Read texts with +1 (646)
    /// 555-0100", from the conversations its own windows showed (`SendRules.messagesConversation`), else "Read texts";
    /// never a bare "Worked in Messages".
    static func reading(_ lines: [MomentDetailEntry], byID: [String: CanonicalAction]) -> [MomentDetailEntry] {
        lines.map { l in
            guard l.quiet, messages(l) else { return l }
            var names: [String] = []
            for id in l.actionIDs {
                guard let a = byID[id], a.kind != "keyboard.text_input", let n = SendRules.messagesConversation(a.title),
                      !names.contains(where: { $0.lowercased() == n.lowercased() }) else { continue }
                names.append(n)
            }
            var e = l
            e.title = readingTitle(names)
            return e
        }
    }
    static func readingTitle(_ names: [String]) -> String {
        guard !names.isEmpty else { return "Read texts" }
        if names.count > 3 { return "Read texts with " + names.prefix(3).joined(separator: ", ") + " and others" }
        return "Read texts with " + (names.count <= 2 ? names.joined(separator: " and ") : names.dropLast().joined(separator: ", ") + " and " + names.last!)
    }

    /// `line` standing for `other`'s actions too; its time stays its own (a fold only lengthens how long it covers).
    static func absorbing(_ line: MomentDetailEntry, _ other: MomentDetailEntry, before: Bool = false) -> MomentDetailEntry {
        var e = line
        e.last = [line.last, other.last].compactMap { $0 }.max() ?? line.last
        e.actionIDs = before ? other.actionIDs + line.actionIDs : line.actionIDs + other.actionIDs
        return e
    }
}
