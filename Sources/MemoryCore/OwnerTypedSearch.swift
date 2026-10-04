import Foundation

// fix/search-1003 (owner, 2026-09-29: typed words are visible and searchable on this Mac, in their own app).
//
// In-app search never matched what the person typed: the index document (`SearchDocument.make`) and the direct scan
// (`fallbackMatch`, `localSearchable`) both clear `evidence.text`, and a sealed typed row keeps no words in its record
// body at all. So "ZUX" typed in Messages showed on the moment's detail page but search said "No moments match".
//
// This pass matches the person's own typed rows in the DayDream app process only:
// - The words open only through `hydrateTypedText(.owner)`, the details page's gate: typing on, a ready key in this
//   process (no MCP, CLI or other process holds one), the record not forgotten, hidden or blocked, the kept period not
//   over (an expired row never matches, even before the expiry job deletes it), and a sealed row matching its record.
// - A secure-field row is never saved; one flagged secure is skipped here too. Words the scrubber withheld are gone
//   from the sealed text (`[withheld]`, which is dropped before matching), and any remaining token `Privacy.secret`
//   flags is dropped before matching and from the snippet.
// - Nothing is written: no index document, no cache, no log. The Typesense index stays metadata-only, because its
//   storage is a plain on-disk database while typed words are sealed at rest with a per-day key; holding words there
//   would break the typed store's at-rest stance. Matching here, in memory, keeps that stance.
// - The MCP and CLI never reach this: they hold no key (`typedVaultState != .ready`), and their search
//   (`searchResult`, `Access.search`, `recall`) is unchanged.
// It reads the store directly, so a row typed seconds ago matches before any index has seen it.
// The words are the sealed text of the row, whatever capture sealed: the keys' reconstruction, or (messages-1003) the
// field's own value read at the send key, which replaces the unit's text before it is sealed. Both read the same way.

/// Where a typed match was typed, for its result row ("Texts · Jamie"): metadata only, never words.
public struct OwnerTypedPlace: Equatable, Sendable {
    /// "Texts", "Email", or the app's name.
    public let label: String
    /// The conversation's name, the page's site, or the window's title; "" when none is known.
    public let place: String
    public init(label: String, place: String) { self.label = label; self.place = place }
    /// "Texts · Jamie", or the label alone.
    public var line: String { place.isEmpty || place.caseInsensitiveCompare(label) == .orderedSame ? label : label + " · " + place }
}

/// Typed matches for one query: the matching typed rows as search items, and one short snippet of the words per row
/// (in memory, for the result row only).
public struct OwnerTypedSearchResult {
    public var items: [MemoryItem]
    /// Action ID -> a short, single-line part of the typed words around the match.
    public var snippets: [String: String]
    /// Action ID -> where it was typed (the result row's context line).
    public var places: [String: OwnerTypedPlace]
    /// false: the pass stopped at its row or time bound before reading every typed row in range.
    public var complete: Bool
    public init(items: [MemoryItem] = [], snippets: [String: String] = [:], places: [String: OwnerTypedPlace] = [:], complete: Bool = true) {
        self.items = items; self.snippets = snippets; self.places = places; self.complete = complete
    }
}

/// A request to end an owner typed pass early (its search was superseded). Set from any thread.
public final class OwnerTypedSearchStop: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public var requested: Bool { lock.lock(); defer { lock.unlock() }; return value }
    public func request() { lock.lock(); value = true; lock.unlock() }
}

public enum OwnerTypedSearchText {
    /// Characters kept on each side of the match in a snippet.
    public static let radius = 48
    /// The words as search reads them: one line, the scrubber's marker gone, and every token that looks secret gone.
    public static func searchable(_ raw: String) -> String {
        let text = MomentTypedText.clean(raw).replacingOccurrences(of: TypedSecretScrubber.marker, with: " ")
        return text.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !Privacy.secret($0) }.joined(separator: " ")
    }
    /// A short part of `text` around the first literal occurrence of a query word (the start when none: a typo match).
    public static func snippet(_ text: String, words: [String]) -> String {
        let hit = words.compactMap { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) }
            .min { $0.lowerBound < $1.lowerBound }
        guard let hit else { return text.count <= radius * 2 ? text : String(text.prefix(radius * 2)) + "…" }
        let start = text.index(hit.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(hit.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        var part = String(text[start..<end]).trimmingCharacters(in: .whitespaces)
        if start != text.startIndex { part = "…" + part }
        if end != text.endIndex { part += "…" }
        return part
    }
}

extension MemoryStore {
    /// Typed rows one pass reads at most (newest first), and how long it may take.
    public static var ownerTypedSearchRowLimit = 3000
    public static var ownerTypedSearchBudget: TimeInterval = 0.8

    /// The person's own typed rows whose words (or conversation name) hold every query word: case-, accent- and
    /// width-insensitive, anywhere in the text ("Zux" finds "ZUX" and "zux's"), with the direct scan's bounded typo
    /// recovery. Exact matches first, then typo matches, newest first within each. Empty outside the DayDream app
    /// process (no ready key), while typing is off, for an empty query, or when the history changed mid-read.
    /// `stop` (claude/perf2-1003): Recall cancels a search the moment its query changes (each letter typed after the
    /// 180 ms debounce), but this pass ran on to its row or time bound on a background thread, so typing a word in Recall
    /// stacked several 0.8 s passes over the typed rows at once. It is asked before each row; once it says yes the pass
    /// ends with nothing (its caller has already dropped the result).
    public func ownerTypedSearch(_ query: MemorySearchQuery, now: Date = Date(), stop: OwnerTypedSearchStop? = nil) throws -> OwnerTypedSearchResult {
        guard !query.words.isEmpty, query.after == nil, typedVaultState == .ready, try hasTypedTables(), try policy().captureText,
              try typedDisclosureAllows(.owner, reader: nil) else { return OwnerTypedSearchResult() }
        let epoch = try actionReadEpoch(), policyBefore = try policy().revision
        let floor = query.start.map(iso) ?? "0001-01-01T00:00:00Z", end = query.end.map(iso) ?? "9999-12-31T00:00:00Z"
        let limit = Self.ownerTypedSearchRowLimit
        let candidates = try rows("""
            SELECT r.id FROM typed_text t JOIN records r ON r.id=t.id
            WHERE json_extract(r.body,'$.kind')='keyboard.text_input' AND coalesce(json_extract(r.body,'$.secure'),0) IN (0,'false')
              AND julianday(json_extract(r.body,'$.at'))>=julianday(?) AND julianday(json_extract(r.body,'$.at'))<julianday(?)
              AND (?='' OR json_extract(r.body,'$.app')=? OR json_extract(r.body,'$.bundle')=?)
            ORDER BY julianday(json_extract(r.body,'$.at')) DESC, r.id DESC LIMIT ?
            """, [floor, end, query.app ?? "", query.app ?? "", query.app ?? "", String(limit + 1)]).map { $0[0] }
        var complete = candidates.count <= limit
        let deadline = Date().addingTimeInterval(Self.ownerTypedSearchBudget)
        let recipients = try typedRecipients(Array(candidates.prefix(limit)))
        var found: [(item: MemoryItem, score: Int, snippet: String, place: OwnerTypedPlace)] = []
        for id in candidates.prefix(limit) {
            if stop?.requested == true { return OwnerTypedSearchResult(complete: false) }
            if Date() >= deadline { complete = false; break }
            guard let raw = try hydrateTypedText(id, disclosure: .owner, now: now) else { continue }
            let words = OwnerTypedSearchText.searchable(raw)
            var name = (recipients[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if name.count > 120 || Privacy.secret(name) || name.contains(TypedSecretScrubber.marker) { name = "" }
            let text = name.isEmpty ? words : words + " " + name
            guard !text.isEmpty, let score = query.lexicalScore(text),
                  let item = try searchActionItem(id, now: now), query.matches(item) else { continue }
            let shown = OwnerTypedSearchText.snippet(words, words: query.words)
            found.append((item, score, shown.isEmpty ? name : shown, try ownerTypedPlace(id, conversation: name, now: now)))
        }
        guard try epoch == actionReadEpoch(), try policyBefore == policy().revision, typedVaultState == .ready else { return OwnerTypedSearchResult() }
        found.sort {
            if ($0.score == 0) != ($1.score == 0) { return $0.score == 0 }
            let a = timestamp($0.item.evidence.at) ?? .distantPast, b = timestamp($1.item.evidence.at) ?? .distantPast
            return a == b ? $0.item.id > $1.item.id : a > b
        }
        let kept = found.prefix(query.limit)
        var snippets = [String: String](), places = [String: OwnerTypedPlace]()
        for f in kept { snippets[f.item.id] = f.snippet; places[f.item.id] = f.place }
        return OwnerTypedSearchResult(items: kept.map(\.item), snippets: snippets, places: places, complete: complete && found.count <= query.limit)
    }
    /// A typed row's context: Messages (or a text surface) is "Texts", an email "Email", else the app's name; the place is
    /// the conversation's name, else the page's site, else (outside Messages, whose window title can't name a typed
    /// row's chat) a window title that doesn't look secret.
    func ownerTypedPlace(_ id: String, conversation: String, now: Date) throws -> OwnerTypedPlace {
        guard let e = try read(id, now: now)?.evidence else { return OwnerTypedPlace(label: "Typed", place: conversation) }
        let surface = e.captureProvenance?.unit?.surface ?? ""
        let app = AppNames.display(app: e.app, bundle: e.bundle)
        let messages = MessagesMomentIdentity.applies(bundle: e.bundle, app: e.app)
        let label = messages || surface == "text" ? "Texts" : surface == "email" ? "Email" : (app.isEmpty ? "Typed" : app)
        if !conversation.isEmpty { return OwnerTypedPlace(label: label, place: conversation) }
        let host = Self.promptHost(e.url)
        if !host.isEmpty { return OwnerTypedPlace(label: label, place: host) }
        let title = TitleClean.clean(e.title, app: app, site: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !messages, !title.isEmpty, title.count <= 80, !Privacy.secret(title), title.caseInsensitiveCompare(app) != .orderedSame else {
            return OwnerTypedPlace(label: label, place: label == app ? "" : app)
        }
        return OwnerTypedPlace(label: label, place: title)
    }
}
