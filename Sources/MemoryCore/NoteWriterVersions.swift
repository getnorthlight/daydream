import Foundation

/// fix/sx-all round 2: the note writer versions this build writes (the writer's `CanonicalGrounding.currentVersions`,
/// which MemoryCore can't import; notes-quality checks the two lists agree). A stored moment or day note written by an
/// earlier version of the writer (say "qwen35-4b-q4-b9723-prompt7-validator9") is rewritten for recent days: the day
/// reads it as pending with the old note kept on screen until the new one is saved (stale-while-updating), and the
/// writer queues it behind new moments, under the usual power rules. Notes from other writers (a check's fixture, an
/// import) and older days stay as they are.
public enum NoteWriterVersions {
    public static let current: [String] = ["qwen35-4b-q4-b9723-prompt21-validator32", "deepseek-v4-flash-0731-zdr-prompt20-validator26", "code-moment8-validator14", "code-fallback8-validator18"]
    /// The families the writer's versions come from; only their earlier versions are rewritten.
    static let families = ["qwen35-", "deepseek-", "code-moment", "code-fallback"]
    /// Today and the 3 days before it.
    public static let recentDays: TimeInterval = 4 * 86400
    public static func outdated(_ version: String) -> Bool {
        families.contains(where: version.hasPrefix) && !current.contains(version)
    }
    /// True for a stored note an earlier writer wrote, on a day that ended less than `recentDays` ago.
    public static func rewrites(_ note: GeneratedNote, dayEnd: Date, now: Date) -> Bool {
        outdated(note.output.generatorVersion) && now.timeIntervalSince(dayEnd) < recentDays
    }
}

/// fix/summary-fallback (QF-16): the note the writer's code writes from a moment's facts when every model answer failed
/// (WriterBackend `CanonicalGrounding.fallbackNote`, committed only after its `check` found it exactly code's note). Its
/// own lines name only a place ("Typed a draft in Notes.", "Used the send key in X."): the Today page's filler rule would
/// hide them, so for this note, and only these lines, it doesn't. Core ties the version to the provider, so a model's note
/// can't carry it and this note can't be stored as a model's.
public enum CodeFallbackNote {
    public static let version = "code-fallback8-validator18"
    public static let provider = "code/fallback-notes"
    /// Known historical notes keep their display identity; only `version` is current for writing and rewrites.
    private static let knownVersions: Set<String> = ["code-fallback1-validator12", "code-fallback2-validator12", "code-fallback3-validator13", "code-fallback4-validator14", "code-fallback5-validator15", "code-fallback6-validator16", "code-fallback7-validator17", version]
    static let place = #"[^"“”‘’\n]{1,80}"#
    /// Review C2: "Hit send" when a send wasn't sealed with a key (a Post-button click, or no method recorded).
    /// claude/messages-1003 (fallback5): a Messages draft with no conversation name read and no topic ("Drafted a text in
    /// Messages."). Its sends say who ("Texted Sam.") or "Texted someone in Messages.", which are never filler.
    static let lines = [#"^Used the send key in "# + place + #"\.$"#, #"^Typed in "# + place + #" and used the send key\.$"#, #"^Typed a draft in "# + place + #"\.$"#,
                        #"^Hit send in "# + place + #"\.$"#, #"^Typed in "# + place + #" and hit send\.$"#, #"^Drafted a text in "# + place + #"\.$"#]
    public static func isFallback(_ output: NoteWriterOutput) -> Bool { output.generator == provider && knownVersions.contains(output.generatorVersion) }
    /// Recognize only the exact known provider/version pairs. A reserved fallback version with another provider,
    /// or an unknown fallback version, is refused; a prefix is used only to deny, never to grant identity.
    public static func hasValidProviderPair(_ output: NoteWriterOutput) -> Bool {
        if output.generator != provider && !output.generatorVersion.hasPrefix("code-fallback") { return true }
        return isFallback(output)
    }
    /// One of the fallback note's own place-only lines, exactly as code writes them.
    public static func isFallbackLine(_ text: String) -> Bool {
        !text.lowercased().contains(" about ") && lines.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
}

extension MemoryStore {
    static let notesKeptID = "notes-kept-as-written-v1"
    /// A history no writer runs on (DayDream Preview's sample week, whose notes an earlier model wrote): its notes are
    /// shown as written, never read as pending for a rewrite that would never come.
    public func keepNotesAsWritten() throws {
        lock.lock(); defer { lock.unlock() }
        guard writable else { throw MemError.denied }
        try transaction { try exec("INSERT OR REPLACE INTO metadata VALUES(?,?)", [Self.notesKeptID, "{}"]) }
    }
    public func notesKeptAsWritten() throws -> Bool {
        !(try rows("SELECT 1 FROM metadata WHERE id=?", [Self.notesKeptID])).isEmpty
    }
}
