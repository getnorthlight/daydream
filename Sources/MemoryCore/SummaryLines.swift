import Foundation

/// claude/summary-1003 (owner, 10/3): a summary never mixes code's place-only lines with real ones. A Ghostty card read
/// "Typed a draft in Ghostty. / Used the send key in Ghostty. / Requested the option to summarize immediately. / Wrote code
/// in Ghostty. / Noted that the current summary is confusing. / Wrote code in Ghostty.": three notes (one of them code's
/// fallback, one salvaged) shown one after the other. Whatever writes the lines, what a card or an AI app shows is:
/// - generic lines ("Typed a draft in X", "Used the send key in X", "Wrote code in X", "Pressed Return", "Ran a command in
///   X", "Entered a command in X", and claude/cc-label-1003 a bare "Asked Claude Code") only when no line says more;
/// - each line once: the same words (case and punctuation aside), a line that only repeats the start of a fuller one
///   ("Asked Claude Code." beside "Asked Claude Code to add ..."), or nearly the same words, keep the fuller one;
/// - at most `cap` lines (about 4), the most informative, in their own order.
/// The stored note keeps every line and every action it cites; this is presentation only.
public enum SummaryLines {
    public static let cap = 4
    static let place = #"[^"“”‘’\n]{1,80}"#
    /// Code's own lines that name only a place or a gesture (the writer's fallback and salvage lines, action
    /// descriptions shown before a note exists).
    static let genericPatterns: [String] = [
        "^typed a draft in " + place + "$",
        "^used the send key in " + place + "$",
        "^typed in " + place + " and (used the send key|hit send)$",
        "^hit send in " + place + "$",
        "^typed in " + place + ", then (used its send key|clicked its .{1,40} button)(,? .{0,60})?$",
        "^typed in " + place + "(, .{0,60})?$",
        "^wrote code in " + place + "$",
        "^pressed return( in " + place + ")?(; sending is not established)?$",
        "^ran a command( in " + place + ")?$",
        "^(entered|typed) (a command|commands)( in " + place + ")?$",
        "^drafted a prompt for " + place + "$",
        // claude/cc-label-1003 (owner 10/03): "Asked Claude Code." beside a line that says what was asked is filler.
        "^(asked|told) (claude code|claude|codex|gemini cli|gemini|aider|chatgpt|cursor|copilot|perplexity|an ai)$",
        "^in " + place + "$",
    ]
    static let generic = genericPatterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// True for a line that names only a place or a gesture: no who, no what about, nothing done.
    public static func isGeneric(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
        if t.isEmpty { return true }
        let range = NSRange(t.startIndex..., in: t)
        return generic.contains { $0.firstMatch(in: t, range: range) != nil }
    }
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "#" }.map(String.init)
    }
    /// Same words, a fuller line's start, or nearly the same words (at least 3 words besides small ones, 85% shared).
    static func repeats(_ a: String, of b: String) -> Bool {
        let x = words(a), y = words(b)
        if x.isEmpty { return true }
        if x == y { return true }
        if x.count < y.count, Array(y.prefix(x.count)) == x { return true }
        let sx = Set(x).subtracting(glue), sy = Set(y).subtracting(glue)
        guard sx.count >= 3, sy.count >= 3 else { return false }
        return Double(sx.intersection(sy).count) / Double(sx.union(sy).count) >= 0.85
    }
    /// Small words that don't make two lines different ("a" or "the" Summarize Now option).
    static let glue: Set<String> = ["a", "an", "the", "to", "of", "in", "on", "for", "and", "with", "its", "his", "her", "their"]
    static let leads: Set<String> = ["asked", "told", "emailed", "texted", "messaged", "replied", "posted", "approved", "agreed", "searched", "filled"]
    /// How much a line says: a send or request first, then length.
    static func score(_ text: String) -> Double {
        let w = words(text)
        return (w.first.map(leads.contains) == true ? 2 : 0) + Double(min(w.count, 30)) / 10 - (isGeneric(text) ? 10 : 0)
    }

    /// The lines to show, in their order: `text` reads each line's words.
    public static func tidy<T>(_ lines: [T], cap: Int = cap, text: (T) -> String) -> [T] {
        let real = lines.contains { !isGeneric(text($0)) }
        var kept: [(Int, T)] = []
        for (i, line) in lines.enumerated() {
            let t = text(line)
            if real && isGeneric(t) { continue }
            if let j = kept.firstIndex(where: { repeats(text($0.1), of: t) }) {
                // A fuller line takes the earlier one's place.
                if words(t).count > words(text(kept[j].1)).count { kept[j] = (kept[j].0, line) }
                continue
            }
            if kept.contains(where: { repeats(t, of: text($0.1)) }) { continue }
            kept.append((i, line))
        }
        guard kept.count > cap else { return kept.map(\.1) }
        let best = Set(kept.enumerated().sorted { (score(text($0.element.1)), -$0.offset) > (score(text($1.element.1)), -$1.offset) }.prefix(cap).map(\.offset))
        return kept.enumerated().filter { best.contains($0.offset) }.map(\.element.1)
    }
    public static func tidy(_ lines: [String], cap: Int = cap) -> [String] { tidy(lines, cap: cap) { $0 } }
}
