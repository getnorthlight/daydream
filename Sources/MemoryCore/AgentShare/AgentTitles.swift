import Foundation

// agent-tools v2, WP-B (plan §5.1): a window or page title as one stable name, at read time.
//
//   "(3) Home / X"                          -> "Home"           (count and site suffix)
//   "Q3 plan - Google Docs - Google Chrome" -> "Q3 plan"        (browser and product suffixes)
//   "Inbox (12 unread) — Mail"              -> "Inbox"
//   "\u{200e}Budget [4]  v2"                -> "Budget v2"      (marks, counts, spacing)
//   "✳ Fake session"                        -> "Fake session"   (status glyphs, TitleClean.statusless)
//
// Pure: no store, no settings, no clock. Capture already strips most of this (data-audit §4); this is the read-time
// backstop, and `flickerKey` is what makes "Budget", "budget (1)" and "Budget — 80×24" one thing.
extension AgentTitles {
    /// Browser names a window title may end with ("… - Google Chrome", "… — Safari").
    static let browserNames: Set<String> = ["google chrome", "chrome", "safari", "firefox", "arc", "microsoft edge", "brave browser", "brave",
                                            "opera", "vivaldi", "chromium", "orion"]
    /// Separators between a title and its app, site or product segment. " / " is X's ("Home / X").
    static let separators = [" — ", " – ", " - ", " | ", " · ", " • ", " / "]
    /// Invisible marks a title can carry (LRM/RLM, embeddings and isolates, zero-width, BOM).
    static let invisibles = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}\u{FEFF}")

    public static func normalized(_ title: String, app: String, site: String) -> String {
        var s = String(String.UnicodeScalarView(title.unicodeScalars.filter { !invisibles.contains($0) }))
        s = TitleClean.statusless(s).trimmingCharacters(in: .whitespacesAndNewlines)
        s = withoutCounts(s)
        s = withoutSuffixes(s, app: app, site: site)
        // A count can sit before a suffix that was just removed ("Inbox (3) - Gmail").
        s = withoutCounts(s)
        return collapsed(s)
    }

    public static func flickerKey(_ title: String, app: String, site: String) -> String {
        folded(normalized(title, app: app, site: site), tails: true)
    }

    /// Case, diacritics and width folded, spacing collapsed; with `tails`, also the digit-only tails a window adds and
    /// drops: a terminal size ("— 80×24"), a copy or tab counter ("(1)", "[2]"), an editor's unsaved "*". Not "#12" or
    /// "- 2026": those name different things (an issue, a year).
    static func folded(_ name: String, tails: Bool) -> String {
        var s = collapsed(name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil))
        guard tails else { return s }
        let patterns = [#"\s*[—–-]\s*\d+\s*[×x]\s*\d+$"#, #"\s*\(\d+\)$"#, #"\s*\[\d+\]$"#, #"^\*\s*"#, #"\s*\*$"#]
        var changed = true
        while changed {
            changed = false
            for pattern in patterns {
                let next = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
                if next != s, !next.trimmingCharacters(in: .whitespaces).isEmpty { s = next; changed = true }
            }
        }
        return collapsed(s)
    }

    // MARK: - Steps

    /// Notification and unread counts: "(3) Home", "Inbox (12 unread)", "Chat (2 new messages)", "Mail [4]".
    static func withoutCounts(_ raw: String) -> String {
        var s = raw
        for pattern in [#"^\(\d[\d,.]*\+?\)\s*"#, #"^\[\d[\d,.]*\+?\]\s*"#,
                        #"\s*\(\d[\d,.]*\+?(?:\s+(?:unread|new|notifications?))?(?:\s+messages?)?\)"#,
                        #"\s*\[\d[\d,.]*\+?\]"#, #"^[•●]\s*"#] {
            s = s.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The browser suffix (and a Chrome profile after it) and trailing app, site or product segments. A segment is
    /// removed only while something is left before it ("Slack" alone stays "Slack").
    static func withoutSuffixes(_ raw: String, app: String, site: String) -> String {
        var s = raw
        // "… - Google Chrome" or "… - Google Chrome - Work" (a profile name): everything from the browser segment on.
        for sep in [" - ", " — ", " – "] {
            for browser in ["Google Chrome", "Microsoft Edge", "Brave Browser"] {
                guard let r = s.range(of: sep + browser, options: [.caseInsensitive, .backwards]), r.lowerBound > s.startIndex else { continue }
                let rest = String(s[r.upperBound...])
                let profile = rest.hasPrefix(sep) ? String(rest.dropFirst(sep.count)) : nil
                if rest.isEmpty || (profile.map { !$0.isEmpty && $0.count <= 40 && !separators.contains(where: $0.contains) } ?? false) {
                    s = String(s[..<r.lowerBound])
                }
            }
        }
        let host = TitleClean.hostName(site)
        var strip = TitleClean.productSegments.union(browserNames)
        let appLower = app.lowercased().trimmingCharacters(in: .whitespaces)
        if !appLower.isEmpty { strip.insert(appLower) }
        if !host.isEmpty {
            strip.insert(host); strip.insert("www." + host)
            strip.insert(TitleClean.friendlyHost(host).lowercased())
            if let label = host.split(separator: ".").dropLast().last { strip.insert(String(label)) }
        }
        var changed = true
        while changed {
            changed = false
            for sep in separators {
                guard let r = s.range(of: sep, options: .backwards), r.lowerBound > s.startIndex else { continue }
                let tail = String(s[r.upperBound...]).lowercased().trimmingCharacters(in: .whitespaces)
                let head = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                if !head.isEmpty, tail.isEmpty || strip.contains(tail) { s = head; changed = true; break }
            }
        }
        return s
    }

    static func collapsed(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
