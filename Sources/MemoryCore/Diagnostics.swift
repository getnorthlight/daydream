import Foundation

// The cleaned diagnostics report (before 0.1.4, Help › Report a Problem showed it in a window). Report a Problem now opens
// an email with fixed states only and never shows this report (ProblemReportMail.swift); `DiagnosticsLog` still keeps
// DayDream's own lines in memory. The report is plain text; DayDream sends nothing. It holds settings and states only: app version and build, macOS, where the app runs from,
// permission and recording states, the size of the history database, which AI apps are connected, and the
// 50 lines of DayDream's log from this run (`DiagnosticsLog`: every kind of line keeps its share).
//
// It never holds history: no window or page titles, web addresses, typed text or keys. Log lines are the one
// free-text part, so every line is cleaned before it is shown (`Diagnostics.clean`):
// - any recent window title, page title, web address, site or typed text from the history is removed
//   (`MemoryStore.diagnosticsRedactions` reads them; they are used for matching and never shown);
// - keys and tokens (OpenRouter keys, bearer tokens, DayDream's AI app keys, long hex or base64 runs) are removed;
// - email addresses are removed, and web addresses are cut to their site;
// - the home folder is shortened to "~" (any /Users/<name> too) and temporary folders to "[temp]".
// scripts/connect-diagnostics-checks.swift seeds each kind and checks that none survives.

/// The states the report shows. Every field is a setting or a state, never content.
public struct DiagnosticsSnapshot: Equatable, Sendable {
    public var version: String
    public var build: String
    public var macOS: String
    public var architecture: String
    public var appLocation: String
    public var dataFolder: String
    public var databaseBytes: Int64?
    public var recording: String
    public var problem: String?
    public var accessibility: Bool?
    public var inputMonitoring: Bool?
    public var typedText: Bool
    public var chromePages: String
    public var summaries: String
    public var connectedApps: [String]
    /// The search index's state (the line Settings › Diagnostics showed before it was cut), or nil when unknown.
    public var search: String?
    public init(version: String, build: String, macOS: String, architecture: String, appLocation: String, dataFolder: String,
                databaseBytes: Int64?, recording: String, problem: String?, accessibility: Bool?, inputMonitoring: Bool?,
                typedText: Bool, chromePages: String, summaries: String, connectedApps: [String], search: String? = nil) {
        self.version = version; self.build = build; self.macOS = macOS; self.architecture = architecture
        self.appLocation = appLocation; self.dataFolder = dataFolder; self.databaseBytes = databaseBytes
        self.recording = recording; self.problem = problem; self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring; self.typedText = typedText; self.chromePages = chromePages
        self.summaries = summaries; self.connectedApps = connectedApps; self.search = search
    }
}

public enum Diagnostics {
    public static let logLineLimit = 50
    static let maxLineLength = 300
    static let removed = "[removed]"

    /// The report, ready to read and copy. `redactions` are strings from the history that must not appear.
    public static func report(_ s: DiagnosticsSnapshot, log: [String], userHome: String, redactions: [String], made: Date = Date()) -> String {
        func permission(_ value: Bool?) -> String { value.map { $0 ? "allowed" : "not allowed" } ?? "not checked yet" }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        // Fixed lines: DayDream's own labels and values. Paths are shortened and keys removed, but history text
        // isn't matched here, so a title such as "Recording" can't blank out a label.
        var fixed = [
            "DayDream problem report",
            "Made: \(formatter.string(from: made))",
            "",
            "App: DayDream \(s.version) (build \(s.build))",
            "macOS: \(s.macOS) (\(s.architecture))",
            "App location: \(s.appLocation)",
            "History folder: \(s.dataFolder)",
            "History database: \(s.databaseBytes.map(size) ?? "not found")",
            "",
            "Recording: \(s.recording)",
        ].map { clean($0, userHome: userHome, redactions: []) }
        #if DAYDREAM_OWNER_TYPING
        // A triager must know typing can happen beyond Notes and TextEdit here.
        fixed.insert("Typing build: more apps and websites in Google Chrome (each off until turned on)", at: (fixed.firstIndex { $0.hasPrefix("App: ") } ?? 0) + 1)
        #endif
        // Free text (a problem message, log lines) gets the full cleaning.
        fixed.append("Problem shown: " + (s.problem.map { clean($0, userHome: userHome, redactions: redactions) } ?? "none"))
        fixed += [
            "Accessibility: \(permission(s.accessibility))",
            "Input Monitoring: \(permission(s.inputMonitoring))",
            "\(typedTextLabel): \(s.typedText ? "on" : "off")",
            "Web pages in Chrome: \(s.chromePages)",
            "Summaries: \(s.summaries)",
            "Search: \(s.search ?? "unknown")",
            "AI apps connected: \(s.connectedApps.isEmpty ? "none" : s.connectedApps.joined(separator: ", "))",
            "",
        ].map { clean($0, userHome: userHome, redactions: []) }
        let recent = Array(log.suffix(logLineLimit))
        // What the cleaning removes was said once, above the report (the window before 0.1.4).
        fixed.append("\(logHeader) (\(recent.count) lines from this run, cleaned):")
        fixed += recent.isEmpty ? ["(none yet)"] : recent.map { clean($0, userHome: userHome, redactions: redactions) }
        return fixed.joined(separator: "\n") + "\n"
    }

    /// The heading over the cleaned log lines.
    public static let logHeader = "Recent log"
    /// The typed-text line names what this build types in (the full-typing build types beyond Notes and TextEdit).
    #if DAYDREAM_OWNER_TYPING
    /// The "Typing build:" line right under App: already says typing reaches more apps and websites.
    public static let typedTextLabel = "Typed text"
    #else
    public static let typedTextLabel = "Typed text (Notes and TextEdit)"
    #endif

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: Cleaning

    /// Removes history text, keys, emails, web paths and the person's name from one line.
    public static func clean(_ line: String, userHome: String, redactions: [String]) -> String {
        var text = line.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        // Longest first, so a title that contains another is removed whole. Short ones (under 8 characters)
        // only as whole words, so "Mail" doesn't eat "email".
        for value in redactions.sorted(by: { $0.count > $1.count }) where value.count >= 4 {
            guard text.range(of: value, options: .caseInsensitive) != nil else { continue }
            if value.count >= 8 {
                text = text.replacingOccurrences(of: value, with: removed, options: [.caseInsensitive])
            } else if let word = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: value) + "(?![\\p{L}\\p{N}])",
                                                           options: [.caseInsensitive]) {
                text = word.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: removed)
            }
        }
        text = shortenPaths(text, userHome: userHome)
        for (pattern, replacement) in patterns {
            text = pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
        }
        if text.count > maxLineLength { text = String(text.prefix(maxLineLength)) + "…" }
        return text
    }

    /// "/Users/<name>/…" and the given home become "~/…"; the per-user temporary folder becomes "[temp]".
    public static func shortenPaths(_ line: String, userHome: String) -> String {
        var text = line
        let home = userHome.hasSuffix("/") ? String(userHome.dropLast()) : userHome
        if home.count > 1 { text = text.replacingOccurrences(of: home, with: "~") }
        for (pattern, replacement) in pathPatterns {
            text = pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
        }
        return text
    }

    static let pathPatterns: [(NSRegularExpression, String)] = [
        (#"(?:/private)?/var/folders/[^\s"')]+"#, "[temp]"),
        (#"/Users/[^/\s"')]+"#, "~"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static let patterns: [(NSRegularExpression, String)] = [
        // Keys and tokens first, before anything else can split them.
        (#"sk-[A-Za-z0-9_\-]{8,}"#, removed),
        (#"(?i)bearer\s+[A-Za-z0-9._~+/=\-]+"#, "Bearer " + removed),
        (#"(?i)(MAC_MEM_CAPABILITY|capability|api[_-]?key|token|secret|password)(["']?\s*[:=]\s*["']?)[^\s"',}]+"#, "$1$2" + removed),
        // DayDream's AI app keys are two UUIDs; one UUID alone is removed too.
        (#"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#, removed),
        (#"\b[0-9A-Fa-f]{32,}\b"#, removed),
        // Long base64-like runs with a digit in them. A run that starts at "/", or has no digit, is taken
        // as a folder path and kept.
        (#"(?<![/A-Za-z0-9+_\-])(?=[A-Za-z0-9+/_\-]*[0-9])[A-Za-z0-9+_\-][A-Za-z0-9+/_\-]{39,}={0,2}"#, removed),
        (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "[email]"),
        // Web addresses keep only their site.
        (#"(?i)\b(https?|wss?)://([^/\s"'?#]+)[^\s"']*"#, "$1://$2"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
}

/// DayDream's own log for this run: short lines about states and errors, oldest first, at most 200.
/// Kept in memory only; `Diagnostics.report` shows 50, cleaned (Report a Problem's email holds none). Nothing here writes
/// to disk or sends.
///
/// Every line has a kind, the words before its first ": " ("Recording", "Status", "Summaries", …). No kind can crowd
/// out another: a line that repeats the last line of its kind is skipped, a full log drops the oldest line of the kind
/// with the most lines, and `recent` shares its lines between the kinds the same way. So a line that changes often
/// (a status, a summary count) keeps to its share, and the recording lines (`RecordingLog`: pauses, stop causes,
/// faults, retries) stay in the report for hours.
public final class DiagnosticsLog: @unchecked Sendable {
    public static let shared = DiagnosticsLog()
    private struct Entry { let text: String; let stamped: String; let kind: String }
    private let lock = NSLock()
    private var entries: [Entry] = []
    private let limit: Int
    private let clock: () -> Date
    /// Made once and used only under `lock` (a DateFormatter is expensive to make and not thread-safe).
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    public init(limit: Int = 200, clock: @escaping () -> Date = Date.init) {
        self.limit = limit
        self.clock = clock
    }

    /// A line's kind: the words before its first ": " when they are a short label, otherwise "other".
    public static func kind(_ line: String) -> String {
        guard let colon = line.range(of: ": ") else { return "other" }
        let label = line[..<colon.lowerBound]
        guard !label.isEmpty, label.count <= 24, label.allSatisfy({ $0.isLetter || $0 == " " }) else { return "other" }
        return String(label)
    }

    /// Adds one line. A line equal to the last line of its kind is skipped.
    public func record(_ message: String) {
        let text = message.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let kind = Self.kind(text)
        lock.lock(); defer { lock.unlock() }
        if let last = entries.last(where: { $0.kind == kind }), last.text == text { return }
        entries.append(Entry(text: text, stamped: formatter.string(from: clock()) + " " + text, kind: kind))
        if entries.count > limit { entries = Self.shared(entries, count: limit) }
    }

    /// Up to `count` lines, oldest first. When there are more, each kind keeps a fair share: the oldest line of the kind
    /// with the most lines goes first, so the newest lines of every kind are kept.
    public func recent(_ count: Int = Diagnostics.logLineLimit) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Self.shared(entries, count: count).map(\.stamped)
    }

    private static func shared(_ entries: [Entry], count: Int) -> [Entry] {
        guard count > 0 else { return [] }
        guard entries.count > count else { return entries }
        // Each kind's lines, oldest first, as indexes into `entries`.
        var byKind: [String: [Int]] = [:]
        for (index, entry) in entries.enumerated() { byKind[entry.kind, default: []].append(index) }
        var dropped = Set<Int>(), left = entries.count, start: [String: Int] = [:]
        while left > count {
            // The kind with the most lines left; on a tie, the one whose oldest line is oldest.
            var pick: String?, pickCount = 0, pickOldest = Int.max
            for (kind, indexes) in byKind {
                let n = indexes.count - start[kind, default: 0]
                guard n > 0 else { continue }
                let oldest = indexes[start[kind, default: 0]]
                if n > pickCount || (n == pickCount && oldest < pickOldest) { pick = kind; pickCount = n; pickOldest = oldest }
            }
            guard let kind = pick else { break }
            dropped.insert(pickOldest)
            start[kind, default: 0] += 1
            left -= 1
        }
        return entries.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
    }
}

extension MemoryStore {
    /// Recent history text that must never appear in a problem report: window and page titles, web addresses and
    /// their sites, and typed text, from the newest `limit` records. Used only to remove matches from log lines.
    public func diagnosticsRedactions(limit: Int = 2000) -> [String] {
        guard let rows = try? rows("SELECT body FROM records ORDER BY rowid DESC LIMIT ?", [String(limit)]) else { return [] }
        var values = Set<String>()
        for row in rows {
            guard let body = row.first, let evidence = try? decode(Evidence.self, body) else { continue }
            for value in [evidence.title, evidence.url, evidence.text] {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count >= 4 { values.insert(trimmed) }
            }
            if let host = URL(string: evidence.url)?.host, host.count >= 4 { values.insert(host) }
        }
        return Array(values)
    }
}
