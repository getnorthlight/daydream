import Foundation

/// claude/dayeval-1005 (owner 10/05: never "draft" anywhere a person or an AI app can see it; most "drafts" were sent).
/// Stored text keeps its words: action descriptions ("Typed a draft in Notes (a sentence).", which `TypedTextStore` and
/// others read by that prefix) and notes an earlier writer saved ("Drafted a text to Sam"). Every place that shows
/// them, on screen or to an AI app, passes them through `undraft` last, after any matching on the stored words.
/// The writer (WriterBackend `CanonicalGrounding.undraft`) applies the same rules to new notes.
public enum DisplayWords {
    static let rules: [(NSRegularExpression, String)] = [
        (#"\s*\((?:not sent|unsent|draft|a draft)\)"#, ""),
        (#"^Draft (to|in|on)\b"#, "Typed $1"),
        (#"^Draft$"#, "Typed"),
        (#"\b[Tt]yped (?:a |the )?drafts? (in|on|to|for)\b"#, "Typed $1"),
        (#"^Drafted\b"#, "Wrote"),
        (#"(,|\band|\bthen|\balso) drafted\b"#, "$1 wrote"),
        (#"^Drafting\b"#, "Writing"),
        (#"\b(was|were|is|started|kept|began|while|and|then) drafting\b"#, "$1 writing"),
        (#"(?i)[;,]?\s*(?:sending|delivery) (?:isn't|isn’t|is not|wasn't|wasn’t|was not|not) (?:confirmed|verified)"#, ""),
        (#"(?i)[;,]? (?:but |and )?(?:unsent|not sent|never sent|with no send seen|left unsent)\b"#, ""),
        (#"\b(?:[Aa]|[Tt]he|[Yy]our|[Mm]y) drafts? of (?=\w)"#, ""),
        (#"\b([Aa]) draft (email|answer|update|outline|invite)\b"#, "$1n $2"),
        (#"\b([Aa]n?|[Tt]he|[Yy]our|[Mm]y) draft (email|text|message|reply|post|note|comment|tweet|prompt|response|answer|update|outline|invite|letter|proposal|plan)(s?)\b"#, "$1 $2$3"),
        (#"\b([Tt]he|[Yy]our|[Mm]y) draft\b"#, "$1 text"),
        (#"\b([Aa]) draft\b"#, "$1 message"),
        (#"\b([Tt]he|[Yy]our|[Mm]y|[Tt]wo|[Tt]hree|[Ss]everal|[Ss]ome|[Ff]ew|\d+) drafts\b"#, "$1 messages"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
    /// Only draft words in a line's own grammar change (a lead, an article's noun, a hedge); a title's own word stays
    /// ("Read Lab Report Draft.", "Read PR #12: Fix Messages drafts on GitHub.", Gmail's Drafts).
    /// Quoted words (a title, the person's own words) are never rewritten.
    static let quoted = try! NSRegularExpression(pattern: #""[^"]*"|“[^”]*”"#)

    /// `text` with no draft, unsent or not-sent wording outside quotes: "Typed a draft in Notes (a sentence)." is
    /// "Typed in Notes (a sentence).", "Drafted a text to Sam" is "Wrote a text to Sam", "…; sending isn't confirmed." goes.
    public static func undraft(_ text: String) -> String {
        guard text.range(of: #"(?i)draft|unsent|not sent|never sent|no send seen|confirmed|verified"#, options: .regularExpression) != nil else { return text }
        let ns = text as NSString
        var out = "", last = 0
        func plain(_ part: String) -> String {
            var t = part
            for (rule, with) in rules { t = rule.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: with) }
            return t
        }
        for m in quoted.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += plain(ns.substring(with: NSRange(location: last, length: m.range.location - last))) + ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        out += plain(ns.substring(from: last))
        return out.replacingOccurrences(of: "  ", with: " ").replacingOccurrences(of: " .", with: ".")
    }
    /// True when `text` still has draft wording outside quotes (the checks' grep).
    public static func saysDraft(_ text: String) -> Bool {
        let ns = text as NSString
        var outside = text
        for m in quoted.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            outside = (outside as NSString).replacingCharacters(in: m.range, with: "\"\"")
        }
        return outside.range(of: #"(?i)\b(draft|drafts|drafted|drafting|unsent|not sent|never sent|no send seen)\b|isn['’]t confirmed"#, options: .regularExpression) != nil
    }
}
