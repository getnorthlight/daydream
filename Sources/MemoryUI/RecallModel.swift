import Foundation
import AppKit
import SwiftUI
import MemoryCore
import PrivacyPolicy

// Recall (find-A) state: the search, its grouping into moments, selection, the pushed detail, the
// Actions menu and the privacy confirmations. Views read it; the search field's delegate, the
// menu commands and the renders/checks drive it through the public methods. Nothing here starts
// or stops recording: Recall never calls a capture action.

// MARK: - Match sources (plan §3 field check)

/// Where the query text literally appears in a hit: the window title, the page's host, the app, the action
/// description, or (fix/search-1003) the words the person typed, opened on this Mac in the app only
/// (`MemoryStore.ownerTypedSearch`). Notes match as note rows (`searchNotes`), not as a hit source.
public enum RecallMatchSource: String, CaseIterable, Sendable {
    case window, page, app, action, typed

    /// "Why it matched" label.
    public var label: String {
        switch self {
        case .window: return "Window title"
        case .page: return "Page"
        case .app: return "App"
        case .action: return "Action"
        case .typed: return "You typed"
        }
    }
    /// Row label beside the source tile.
    public var short: String {
        switch self {
        case .window: return "Window"
        case .page: return "Page"
        case .app: return "App"
        case .action: return "Action"
        case .typed: return "Typed"
        }
    }
    /// SF Symbols 4 names (macOS 13).
    var symbol: String {
        switch self {
        case .window: return "macwindow"
        case .page: return "globe"
        case .app: return "app"
        case .action: return "cursorarrow.click"
        case .typed: return "keyboard"
        }
    }
    var colors: [Color] {
        switch self {
        case .window: return [Color(.sRGB, red: 0.55, green: 0.60, blue: 0.70, opacity: 1), Color(.sRGB, red: 0.38, green: 0.43, blue: 0.53, opacity: 1)]
        case .page: return [Color(.sRGB, red: 0.25, green: 0.72, blue: 0.98, opacity: 1), Color(.sRGB, red: 0.12, green: 0.45, blue: 0.95, opacity: 1)]
        case .app: return [Color(.sRGB, red: 0.62, green: 0.62, blue: 0.66, opacity: 1), Color(.sRGB, red: 0.44, green: 0.44, blue: 0.48, opacity: 1)]
        // Teal: a hue no semantic token owns (orange means permissions, accent means actions and
        // selection, the highlight yellow means search matches).
        case .action: return [Color(.sRGB, red: 0.20, green: 0.70, blue: 0.72, opacity: 1), Color(.sRGB, red: 0.07, green: 0.52, blue: 0.58, opacity: 1)]
        case .typed: return [Color(.sRGB, red: 0.62, green: 0.52, blue: 0.86, opacity: 1), Color(.sRGB, red: 0.45, green: 0.35, blue: 0.72, opacity: 1)]
        }
    }
}

/// One literal match: the source and the displayed field that holds the query.
public struct RecallMatch: Equatable, Sendable {
    public let source: RecallMatchSource
    public let text: String
}

/// Query terms, the literal field check and highlighting.
enum RecallText {
    /// The whole trimmed query plus its words of two or more characters, longest first.
    static func terms(_ query: String) -> [String] {
        let phrase = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return [] }
        var out = [phrase]
        for word in phrase.split(whereSeparator: { $0.isWhitespace }).map(String.init) where word.count >= 2 {
            if !out.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) { out.append(word) }
        }
        return out.sorted { $0.count > $1.count }
    }

    static func contains(_ text: String, _ terms: [String]) -> Bool {
        !text.isEmpty && terms.contains { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// The http(s) host of an evidence URL ("github.com"), nil for anything else.
    static func webHost(_ url: String) -> String? {
        guard let u = URL(string: url), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = u.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// Every displayed field of `item` that holds a term, in the order You typed, Window title, Page, App, Action.
    /// `typed` is the hit's typed snippet (`RecallModel.typedSnippets`), on this Mac only: the snippet is what the row
    /// shows, so a typed match leads.
    static func matches(_ item: MemoryItem, terms: [String], typed: String? = nil) -> [RecallMatch] {
        guard !terms.isEmpty else { return [] }
        var out: [RecallMatch] = []
        if let typed, !typed.isEmpty { out.append(RecallMatch(source: .typed, text: typed)) }
        let e = item.evidence
        if contains(e.title, terms) { out.append(RecallMatch(source: .window, text: e.title)) }
        if let host = webHost(e.url), contains(host, terms) { out.append(RecallMatch(source: .page, text: host)) }
        let app = appName(item)
        if contains(app, terms) { out.append(RecallMatch(source: .app, text: app)) }
        let action = indexedDescription(item)
        // claude/dayeval-1005: matched on the stored words, shown never saying "draft".
        if contains(actionOnly(action, item), terms) { out.append(RecallMatch(source: .action, text: DisplayWords.undraft(action))) }
        return out
    }

    /// The action description as search holds it: projected from the evidence with its typed text
    /// cleared and its address reduced to the host, exactly as the index document is built
    /// (`SearchDocument.make`). `item.summary` can carry up to 240 typed characters
    /// (`keyboard.text_input`), which the metadata search never matches on, so it is never a match reason; typed words
    /// match through `ownerTypedSearch` and show as the `.typed` source instead.
    static func indexedDescription(_ item: MemoryItem) -> String {
        var e = item.evidence
        e.text = ""
        e.url = URL(string: e.url)?.host.map { "https://" + $0 } ?? ""
        return ActionProjection.make(e).description
    }

    /// The description without the window title and app name it repeats: a term found only there
    /// is already listed as Window title or App.
    private static func actionOnly(_ description: String, _ item: MemoryItem) -> String {
        var rest = description
        for part in [item.evidence.title, appName(item)] where !part.isEmpty {
            rest = rest.replacingOccurrences(of: part, with: " ")
        }
        return rest
    }

    /// The hit's app as displayed: the evidence's app name, never a bundle ID when a name is known.
    static func appName(_ item: MemoryItem) -> String {
        let app = item.evidence.app.trimmingCharacters(in: .whitespacesAndNewlines)
        if !app.isEmpty && !DaydreamAppDirectory.looksLikeBundleID(app) { return app }
        return ""
    }

    /// `s` with every term marked: highlight fill, highlight text colour, bold and underlined
    /// (so the match never depends on colour alone).
    static func highlighted(_ s: String, terms: [String]) -> AttributedString {
        var a = AttributedString(s)
        guard !terms.isEmpty else { return a }
        var marked: [Range<AttributedString.Index>] = []
        for term in terms {
            var lower = a.startIndex
            while lower < a.endIndex, let r = a[lower...].range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
                if !marked.contains(where: { $0.overlaps(r) }) { marked.append(r) }
                lower = r.upperBound
            }
        }
        for r in marked {
            a[r].swiftUI.backgroundColor = DaydreamStyle.highlight
            a[r].swiftUI.foregroundColor = DaydreamStyle.highlightText
            a[r].inlinePresentationIntent = .stronglyEmphasized
        }
        return a
    }
    /// Whether any term appears in `s` (the rows highlight the title, and the subtitle only when the title has none).
    static func mentions(_ s: String, terms: [String]) -> Bool {
        terms.contains { !$0.isEmpty && s.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

// MARK: - Rows and sections

/// One result row: a moment that holds one or more hits, or a single hit not (yet) in a moment. Search is flat
/// (owner, 9/30): a row is one moment (or one hit), never a block, day or week note and never a timeline session.
public struct RecallRow: Identifiable, Equatable {
    public enum Kind: Equatable { case moment(MomentSlice), action }
    public let id: String
    public let kind: Kind
    /// The hits in this row, in result order (empty for "Pick up where you left off" rows).
    public internal(set) var hits: [MemoryItem]
    public let dayKey: String
    /// Start of the row's day in the browser calendar.
    public let day: Date
    /// The time the row shows: claude/searchui-1005, the time of its first matching line (a hit, else the note line that
    /// matched), else the moment's start. One time per row: the title never carries another.
    public internal(set) var time: Date
    /// Newest hit (the within-day sort key).
    public internal(set) var latest: Date

    /// A moment row found by one of its notes' lines (or its note as a whole): the line it is shown by.
    public internal(set) var note: NoteHit? = nil
    /// fix/search-1003: hit ID -> the typed snippet it matched by (view state only, on this Mac).
    public internal(set) var typed: [String: String] = [:]
    /// claude/searchui-1005: hit ID -> a longer part of the same words, for the detail's evidence line (view state only).
    public internal(set) var typedLines: [String: String] = [:]
    /// claude/searchui-1005: the typed hits found only by their conversation's name (their words hold no query word).
    public internal(set) var byName: Set<String> = []
    /// claude/searchui-1005 (owner 10/04: a row titled "Texts · <name> · <time>" over the moment's start time): where the row's typed hit was
    /// typed. The row reads as the conversation ("Jordan Lane", with "Texts" as a small label), never with a second time.
    public internal(set) var typedPlace: OwnerTypedPlace? = nil
    /// claude/searchui-1005: the Messages conversation the row is ("Sam Rivera"): its typed hit's place, else its moment's
    /// own thread name ("Texts with Sam Rivera"); nil for anything else.
    public internal(set) var conversation: String? = nil
    /// claude/searchui-1005 (owner 10/04): other moments of the same conversation on the same day that only matched by
    /// their note or the conversation's name ("Read texts with Sam Rivera."), folded into this row.
    public internal(set) var folded: [MomentSlice] = []

    public var itemIDs: [String] { hits.map(\.id) }
    public var moment: MomentSlice? { if case .moment(let m) = kind { return m }; return nil }
    /// "Recent" (no query): a moment with no hit and no note line.
    public var isRecent: Bool { hits.isEmpty && note == nil }
    public var anchor: MemoryItem? { hits.first }
    public var end: Date { moment?.end ?? time }

    /// The conversation's name ("Jordan Lane", with `kindLabel` "Texts"), a search typed in an app ("Searched Messages
    /// for “rivera”"), the app a typed row names no place in, else the moment's title (subject for a generic one), or
    /// `Action in <App>` for an ungrouped hit. claude/searchui-1005: never a time, and never a note line (the row's
    /// second line shows what matched).
    public var title: String {
        if let p = typedPlace {
            if p.search {
                let words = hits.lazy.compactMap { self.typed[$0.id] }.first { !$0.isEmpty } ?? ""
                return words.isEmpty ? "Searched " + p.label : "Searched " + p.label + " for \u{201C}" + words + "\u{201D}"
            }
            if !p.place.isEmpty { return p.place }
            return conversation ?? p.label
        }
        if let conversation { return conversation }
        if let m = moment { return MomentSubtitle.rowTitle(m) }
        guard let hit = anchor else { return "" }
        let app = RecallText.appName(hit)
        return app.isEmpty ? "Action" : "Action in " + app
    }
    /// The small label beside a conversation's name: "Texts" (or "Email"); nil when the title is not a conversation.
    public var kindLabel: String? {
        if let p = typedPlace, p.search { return nil }
        if let p = typedPlace, !p.place.isEmpty { return p.label }
        return conversation == nil ? nil : "Texts"
    }
    /// A search typed in an app: its words are the title, so the row has no second line.
    public var isTypedSearch: Bool { typedPlace?.search == true }

    /// claude/searchui-1005: takes another row's hits (and, for a folded moment, the moment) into this one.
    mutating func absorb(_ other: RecallRow) {
        let have = Set(itemIDs)
        hits += other.hits.filter { !have.contains($0.id) }
        latest = max(latest, other.latest)
        typed.merge(other.typed) { a, _ in a }
        typedLines.merge(other.typedLines) { a, _ in a }
        byName.formUnion(other.byName)
        if typedPlace == nil { typedPlace = other.typedPlace }
        if note == nil { note = other.note }
        if let m = other.moment, m.id != moment?.id { folded.append(m) }
        folded += other.folded
    }
    /// Display app name for VoiceOver and callouts.
    var appName: String {
        if let m = moment { return m.primaryApp ?? m.apps.first(where: { !DaydreamAppDirectory.looksLikeBundleID($0) }) ?? "" }
        return anchor.map(RecallText.appName) ?? ""
    }
    var bundle: String? {
        if let m = moment { return m.primaryBundle ?? m.bundles.first }
        let b = anchor?.evidence.bundle ?? ""
        return b.isEmpty ? nil : b
    }
    /// A web row's site (moment's primary site, or the hit's host).
    var site: String? {
        if let m = moment { return m.sites.first(where: { !$0.isEmpty }).map(KitBrowsers.host) }
        return anchor.flatMap { RecallText.webHost($0.evidence.url) }
    }
}

public struct RecallSection: Identifiable, Equatable {
    public let id: String
    public let title: String
    /// Trailing date ("Tuesday, September 22"); nil for Best match.
    public let detail: String?
    public let rows: [RecallRow]
    public var best: Bool { id == "best" }
}

/// Where Open Original goes for a row.
enum RecallOriginal: Equatable {
    /// `reopenCanonical` with this action ID (a verified web original).
    case reopen(String, host: String)
    /// `openApp` with this bundle (activates the app only).
    case app(String, name: String)

    var help: String {
        switch self {
        case .reopen(_, let host): return "Opens \(host) in your browser"
        case .app(_, let name): return "Opens \(name)"
        }
    }
    /// The ⌘↩ command's name (L15): `Open Original` only for a verified web original; an app
    /// activation is `Open <App>`.
    var title: String {
        switch self {
        case .reopen: return "Open Original"
        case .app(_, let name): return "Open \(name)"
        }
    }
    var id: MomentActionID {
        if case .reopen = self { return .openOriginal }
        return .openApp
    }
    var symbol: String {
        if case .reopen = self { return "arrow.up.forward.square" }
        return "arrow.up.forward.app"
    }
}

/// A single ungrouped hit to forget (`action` scope). Kit's `MomentForgetRequest` is activity-scoped only.
struct RecallActionForgetRequest: Identifiable, Equatable {
    let id: String
    let scope: MemoryActionScope
    let at: Date
    let timeZone: TimeZone
}

// MARK: - Model

@MainActor public final class RecallModel: ObservableObject {
    /// The date range picker (`MemorySearchQuery.start`).
    public enum Period: String, CaseIterable, Sendable {
        case week, month, all
        public var title: String {
            switch self {
            case .week: return "Past 7 Days"
            case .month: return "Past 30 Days"
            case .all: return "All Time"
            }
        }
        /// "the past 30 days", for "Searched … on this Mac."
        var phrase: String {
            switch self {
            case .week: return "the past 7 days"
            case .month: return "the past 30 days"
            case .all: return "all history"
            }
        }
        func start(now: Date, calendar: Calendar) -> Date? {
            switch self {
            case .week: return calendar.date(byAdding: .day, value: -7, to: now)
            case .month: return calendar.date(byAdding: .day, value: -30, to: now)
            case .all: return nil
            }
        }
    }

    struct Members: Equatable {
        var actions: [CanonicalAction]
        var complete: Bool
        var limit: Int
    }

    weak var browser: ActivityBrowser?

    // Search
    @Published public private(set) var items: [MemoryItem] = []
    @Published public private(set) var result: MemorySearchResult?
    @Published public private(set) var busy = false
    @Published public private(set) var error: String?
    /// The text the shown results answer (highlighting and Why it matched use it, not the live query).
    @Published public private(set) var searchedText = ""
    /// fix/search-1003: hit ID -> a short part of the words the person typed, for the hits found by them
    /// (`browser.searchOwnerTyped`). View state only: never stored, logged, copied or handed on.
    @Published public private(set) var typedSnippets: [String: String] = [:]
    /// hit ID -> where it was typed (metadata only), for the row's context line.
    @Published public private(set) var typedPlaces: [String: OwnerTypedPlace] = [:]
    /// claude/searchui-1005: hit ID -> a longer part of the typed words (the detail's evidence line), and the typed hits
    /// found only by their conversation's name. View state only, like `typedSnippets`.
    @Published public private(set) var typedLines: [String: String] = [:]
    @Published public private(set) var typedByName: Set<String> = []
    /// claude/searchui-1005 (owner 10/04: "the actual text evidence stuff is not showing"): moment ID -> the texts of that
    /// moment, read for the selected result's detail only (`browser.loadOwnerSourcePreviews`, the timeline detail's own
    /// verified owner source). In memory while search is open; dropped with every new search and when search closes.
    @Published public private(set) var evidence: [String: [OwnerSourcePreview]] = [:]
    private var loadingEvidence = Set<String>()
    @Published public private(set) var period: Period = .month
    @Published public private(set) var filter: RecallFilter?
    /// The clock when the shown results were asked for (Best match skips the core's last-ten-seconds rows).
    private var searchedAt: Date?
    private var generation = 0
    private var searchTask: Task<Void, Never>?
    /// Page one's query, reused with `after` for Search More History (the cursor is scoped to it).
    private var pageQuery: MemorySearchQuery?
    /// Keep the day sections after publishing real direct matches. Introducing
    /// a new Best match section later would move a row the person has chosen.
    /// Canonical ranking and row revalidation still run for the final answer.
    private var keepsDirectPreviewSections = false

    // Grouping
    @Published public private(set) var sections: [RecallSection] = []
    /// The note hits for the query (`browser.searchNotes`), newest day first: a moment's lines and whole notes only
    /// (`momentNoteLevels`). Block, day and week notes are the timeline's, never search rows.
    @Published public private(set) var noteHits: [NoteHit] = []
    /// Line and moment hits placed in their moment (by NoteHit.id).
    private var noteMoments: [String: MomentSlice] = [:]
    private var noteAttempted = Set<String>()
    private var resultRows: [RecallRow] = []
    private var resolved: [String: MomentSlice] = [:]
    private var attempted = Set<String>()
    private var resolveTask: Task<Void, Never>?
    private var resolverInstance: MomentResolver?
    /// The time zone the resolver was made for: it is made again when the browser's zone changes.
    private var resolverZone: String?
    @Published var members: [String: Members] = [:]
    private var loadingMembers = Set<String>()

    // Selection, menu (claude/searchui-1005: no pushed detail; opening a result shows it in context)
    @Published public private(set) var selectedRowID: String?
    private var selectedAnchor: String?
    @Published public private(set) var menuOpen = false
    /// What was typed while the Actions menu is open: it moves the highlight (type-select) and is never drawn.
    @Published public private(set) var menuFilter = ""
    @Published public private(set) var menuSelection: MomentActionID?
    @Published public internal(set) var rangeMenuOpen = false
    /// The date-range menu's highlighted row (hover and ↑/↓ share it, as in a native menu).
    @Published public internal(set) var rangeHighlight: Period?
    /// Bumped to ask the list to scroll the selection into view (keyboard moves only).
    @Published private(set) var scrollSerial = 0
    /// Bumped to ask the field to take focus (⌘F / ⌘K while visible).
    @Published private(set) var focusSerial = 0

    // Feedback
    /// Open Original failed for this query: ⌘↩ stays disabled until the query changes.
    @Published private(set) var originalFailedQuery: String?
    @Published var unavailableActions = Set<String>()
    /// A forget or exclusion failure, shown as a footer line.
    @Published public internal(set) var notice: String?
    @Published var forgetRequest: MomentForgetRequest?
    @Published var actionForgetRequest: RecallActionForgetRequest?
    @Published var excludeRequest: ExcludeAppRequest?

    /// The panel's laid-out size and whether it shows the preview (checks read these).
    @Published public internal(set) var panelSize: CGSize = .zero
    /// The panel as drawn, in the hosting view's coordinates (top-left origin), measured by the panel itself.
    @Published public internal(set) var panelFrame: CGRect = .zero
    public var split: Bool { panelSize.width >= RecallLayout.splitWidth }

    private var retriedChangedSource = false
    /// The `.daydreamRecallFilter` subscription; removed when the model goes away.
    var filterObserver: RecallObserverToken?
    private var lastAnnounced: (count: Int, at: Date)?
    /// What VoiceOver was last asked to say (checks read it).
    public private(set) var lastAnnouncement: String?
    private var announceWork: DispatchWorkItem?

    init(browser: ActivityBrowser) { self.browser = browser }

    // MARK: Derived

    var calendar: Calendar { browser?.calendar ?? .current }
    var timeZone: TimeZone { calendar.timeZone }
    var now: Date { browser?.now() ?? Date() }
    var capabilities: MomentActions.Capabilities {
        browser.map { MomentActions.Capabilities(browser: $0) } ?? MomentActions.Capabilities()
    }
    /// The live query, trimmed.
    public var queryText: String { (browser?.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    /// No query and no filter: today's last moments under "Recent".
    public var showsRecents: Bool { queryText.isEmpty && filter == nil }
    /// The label over today's last moments when nothing is typed.
    public static let recentsTitle = "Recent"
    /// A failed search (the Try Again button under it says what to do).
    public static let unavailableText = "Search unavailable."
    /// The footer line while the index is behind: the same fact as "results may be incomplete", in plain words.
    public static let catchingUpText = "Some recent moments may not show yet."
    /// The date range applies only through `searchCanonicalQuery`.
    public var rangeApplies: Bool { browser?.searchCanonicalQuery != nil }
    var terms: [String] { RecallText.terms(searchedText) }

    /// The last three real moments of today, newest first, only when they exist.
    var recents: [MomentSlice] {
        guard let snapshot = browser?.today.snapshot else { return [] }
        return Array(snapshot.moments.suffix(3).reversed())
    }

    /// The rows in display order (sections flattened, or the recents).
    public var displayRows: [RecallRow] {
        if showsRecents {
            return recents.map { m in
                RecallRow(id: m.id, kind: .moment(m), hits: [], dayKey: m.dayKey, day: calendar.startOfDay(for: m.start),
                          time: m.start, latest: m.end)
            }
        }
        return sections.flatMap(\.rows)
    }
    /// Item IDs of the rendered rows, in display order (checks compare them with the search result).
    public var renderedItemIDs: [String] { showsRecents ? [] : displayRows.flatMap(\.itemIDs) }
    public var sectionTitles: [String] { showsRecents ? (recents.isEmpty ? [] : [Self.recentsTitle]) : sections.map(\.title) }
    public var bestMatchShown: Bool { !showsRecents && sections.first?.best == true }
    /// Selection falls back to the first row, so a result is always selected.
    public var selectedRow: RecallRow? {
        let rows = displayRows
        return rows.first { $0.id == selectedRowID } ?? rows.first
    }
    public var selectedIndex: Int? {
        guard let row = selectedRow else { return nil }
        return displayRows.firstIndex { $0.id == row.id }
    }
    /// The row the Actions menu and commands act on: the selection.
    var actionRow: RecallRow? { selectedRow }
    /// A finished search with nothing in it.
    public var showsNoResults: Bool { !showsRecents && error == nil && result != nil && !busy && displayRows.isEmpty && !placingNotes }
    /// A note line found by the search is still being placed in its moment (its row shows once it is).
    private var placingNotes: Bool {
        browser?.loadCanonicalDay != nil
            && noteHits.contains { noteMoments[$0.id] == nil && $0.actionID != nil && !noteAttempted.contains($0.id) }
    }
    /// Typing: the previous results stay, dimmed, until the new ones arrive.
    var stale: Bool { busy && !items.isEmpty && searchedText != queryText }
    public var hasMore: Bool { result?.next != nil }

    /// "7" or "7+" (a lower bound when the search stopped early or found more than a page). Never a total.
    /// VoiceOver only (the announcement and the detail bar's value); the footer draws no count.
    var countText: String {
        let n = displayRows.count
        return DaydreamFormat.count(n, complete: !(result?.partial ?? false) && !hasMore)
    }
    /// The footer's one privacy line (no result count, declutter): "On this Mac" everywhere, "Searching…" while the
    /// first page is in flight.
    public var footerText: String {
        if !showsRecents && error == nil && busy && items.isEmpty { return "Searching…" }
        if !showsRecents && error == nil && busy && searchedText == queryText { return "Finding more matches…" }
        return "On this Mac"
    }
    /// The search did not cover the whole range: more pages exist, the index is behind or fell
    /// back, or the core marked the answer partial.
    public var incomplete: Bool { hasMore || indexCatchingUp || (result?.partial ?? false) }
    /// The footer's short form for a narrow panel: the same words (they are already short).
    public var footerShortText: String { footerText }
    /// `No moments match "{q}"` (the empty state's title) once the whole range was searched. While more history is
    /// left, it says how far back the search looked (`Nothing found back to yesterday 3:42 PM`) and never that
    /// nothing matches (G27 review); the Search More History button follows.
    public var emptyTitle: String {
        if hasMore {
            guard let back = result?.scannedBackTo.flatMap(timestamp) else { return "Nothing found yet" }
            let day = DaydreamFormat.dayTitle(back, now: now, calendar: calendar).title
            return "Nothing found back to " + (["Today", "Yesterday"].contains(day) ? day.lowercased() : day) + " " + DaydreamFormat.time(back, timeZone)
        }
        return searchedText.isEmpty ? "No moments match this filter" : "No moments match \u{201C}\(searchedText)\u{201D}"
    }
    /// How long one search keeps asking for more history by itself while it has found nothing (G27 review): the
    /// first answer is never an empty page that only a Search More History click would have filled. The checks
    /// shorten it.
    public static var autoContinueSeconds: TimeInterval = 6
    /// The footer status line, with results or without: the index catching up (plan §5: whenever the status is
    /// catching up or a fallback). More pages are offered by the Search More History row (or the empty state's
    /// button), so they get no second line.
    public var statusLine: String? {
        guard !showsRecents, error == nil, result != nil else { return nil }
        if hasMore { return nil }
        if indexCatchingUp { return Self.catchingUpText }
        return nil
    }
    /// The sources "Why it matched" lists for a row, in first-seen order (the checks read them).
    public func matchSources(_ row: RecallRow) -> [RecallMatchSource] {
        var out: [RecallMatchSource] = []
        for hit in row.hits {
            for m in RecallText.matches(hit, terms: terms, typed: typedSnippets[hit.id]) where !out.contains(m.source) { out.append(m.source) }
        }
        return out
    }
    /// VoiceOver label of a result row: "{title}, {Texts or app}, {matching line}, {day} {time}".
    public func voiceOverLabel(_ row: RecallRow) -> String {
        let day = DaydreamFormat.dayTitle(row.day, now: now, calendar: calendar).title
        let line = showsRecents ? RecallRowLine(text: "", at: nil, count: 0) : rowLine(row)
        return [row.title, row.kindLabel ?? row.appName, line.text, day + " " + DaydreamFormat.time(line.at ?? row.time, timeZone)]
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }
    /// The index is behind the store or fell back: results may be incomplete.
    public var indexCatchingUp: Bool {
        ["catching_up", "stale_hits_removed", "unavailable_fallback"].contains(result?.status ?? "")
    }
    public var originalBlocked: Bool { originalFailedQuery != nil }

    // MARK: Lifecycle

    /// The panel appeared: search for what is already typed.
    func appeared() {
        retriedChangedSource = false
        if !showsRecents { load(immediate: true) }
        if showsRecents, browser?.loadCanonicalDay != nil { browser?.today.refreshIfStale() }
        updateContext()
    }

    /// The panel went away: drop everything but the date range.
    func disappeared() {
        generation += 1
        keepsDirectPreviewSections = false
        searchTask?.cancel(); resolveTask?.cancel()
        items = []; result = nil; busy = false; error = nil; searchedText = ""; pageQuery = nil; typedSnippets = [:]; typedPlaces = [:]
        typedLines = [:]; typedByName = []; evidence = [:]; loadingEvidence = []
        sections = []; resultRows = []; resolved = [:]; attempted = []; members = [:]; loadingMembers = []
        noteHits = []; noteMoments = [:]; noteAttempted = []
        selectedRowID = nil; selectedAnchor = nil
        menuOpen = false; menuFilter = ""; menuSelection = nil; rangeMenuOpen = false; rangeHighlight = nil
        originalFailedQuery = nil; unavailableActions = []; notice = nil; filter = nil
        forgetRequest = nil; actionForgetRequest = nil; excludeRequest = nil
        announceWork?.cancel(); lastAnnounced = nil
        if browser?.commandContext != DaydreamCommandContext() { browser?.commandContext = DaydreamCommandContext() }
    }

    /// The live query changed (typing, or set by the toolbar).
    func queryChanged() {
        // A failed Open Original stays disabled until the query changes.
        if let failed = originalFailedQuery, failed != browser?.query { originalFailedQuery = nil }
        if menuOpen { closeMenu() }
        retriedChangedSource = false
        if showsRecents {
            generation += 1; searchTask?.cancel(); resolveTask?.cancel()
            items = []; result = nil; busy = false; error = nil; searchedText = ""; typedSnippets = [:]; typedPlaces = [:]
            typedLines = [:]; typedByName = []; evidence = [:]; loadingEvidence = []
            sections = []; resultRows = []; noteHits = []
            selectedRowID = nil; selectedAnchor = nil
            if browser?.loadCanonicalDay != nil { browser?.today.refreshIfStale() }
            updateContext()
            return
        }
        load()
    }

    // MARK: Search (ported from CanonicalSearch: 180 ms debounce, generation ticket, `next` paging)

    func load(more: Bool = false, immediate: Bool = false) {
        if more && (busy || result?.next == nil) { return }
        searchTask?.cancel()
        if !more { keepsDirectPreviewSections = false }
        // The ticket is taken here, not in the task: a superseded search that is still unwinding its
        // cancellation must not clear `busy` (or say anything) before its replacement has started.
        generation += 1; let ticket = generation
        let text = browser?.query.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if browser?.canSearch == true, more || !text.isEmpty || filter != nil { busy = true }
        searchTask = Task { @MainActor [weak self] in await self?.run(ticket: ticket, more: more, immediate: immediate) }
    }

    @MainActor private func run(ticket: Int, more: Bool, immediate: Bool) async {
        guard let browser, browser.canSearch, ticket == generation else { return }
        let query = browser.query
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filter = self.filter
        if !more && text.isEmpty && filter == nil { busy = false; return }
        busy = true; error = nil
        do {
            if !more && !immediate { try await Task.sleep(nanoseconds: 180_000_000) }
            let request: MemorySearchQuery
            if more, var q = pageQuery { q.after = result?.next; request = q } else { request = makeQuery(text, filter: filter) }
            let askedAt = now
            // Start the ranked request alongside the bounded direct read. Notes
            // also remain separate from the metadata-only direct preview.
            async let rankedPage = perform(request, filter: filter)
            // fix/search-1003: the person's own typed words, read from the store in this process (so a row typed
            // seconds ago is found before any index has it). Page one only; Search More History keeps these hits.
            var typed = OwnerTypedSearchResult()
            if !more, !text.isEmpty, let typedSearch = browser.searchOwnerTyped {
                typed = (try? await typedSearch(request)) ?? OwnerTypedSearchResult()
                guard ticket == generation, query == browser.query, !Task.isCancelled else { return }
            }
            var previewIDs: [String] = [], publishedEarly = false
            if !more, let previewSearch = browser.searchDirectPreview {
                let preview = try? await previewSearch(request)
                guard ticket == generation, query == browser.query, !Task.isCancelled else { return }
                if let preview, !preview.items.isEmpty || !typed.items.isEmpty {
                    resolved = [:]; attempted = []; members = [:]; loadingMembers = []
                    noteHits = []; noteMoments = [:]; noteAttempted = []
                    pageQuery = request; searchedText = text; searchedAt = askedAt
                    selectedRowID = nil; selectedAnchor = nil
                    var seen = Set<String>()
                    let direct = preview.items.filter { seen.insert($0.id).inserted }
                    previewIDs = direct.map(\.id)
                    typedSnippets = typed.snippets; typedPlaces = typed.places; typedLines = typed.lines; typedByName = typed.byName
                    evidence = [:]; loadingEvidence = []
                    items = direct + typed.items.filter { seen.insert($0.id).inserted }; result = preview
                    keepsDirectPreviewSections = true; publishedEarly = true
                    rebuild(); _ = resolveMoments(announcing: false)
                }
            }
            // The notes at every level (page one, no app or site filter: notes aren't one app's).
            var notes: [NoteHit] = []
            if !more, filter == nil, !text.isEmpty, let search = browser.searchNotes {
                notes = ((try? await search(text)) ?? []).filter { hit in
                    guard Self.momentNoteLevels.contains(hit.level) else { return false }
                    guard rangeApplies, let start = period.start(now: askedAt, calendar: calendar),
                          let key = try? DayScope.key(start, timezone: timeZone.identifier) else { return true }
                    return hit.day >= key
                }
                guard ticket == generation, query == browser.query, !Task.isCancelled else { return }
            }
            var page = try await rankedPage
            guard ticket == generation, query == browser.query, !Task.isCancelled else { return }
            // The store changed during the read: read again once before saying anything.
            if !more && page.items.isEmpty && page.status == "source_changed_retry" && !retriedChangedSource {
                retriedChangedSource = true
                page = try await perform(request, filter: filter)
                guard ticket == generation, query == browser.query, !Task.isCancelled else { return }
            }
            if !more && page.items.isEmpty && page.status == "source_changed_retry" { throw MemError.invalid("Search source changed") }
            // Nothing found yet and more history left: ask again by itself for a few seconds before answering (G27
            // review), so the first answer is never an empty page that only Search More History would have filled.
            // A new query or a closed panel ends it (the ticket).
            let started = ProcessInfo.processInfo.systemUptime
            while page.items.isEmpty, typed.items.isEmpty, notes.isEmpty || more, let next = page.next, ProcessInfo.processInfo.systemUptime - started < Self.autoContinueSeconds {
                var continued = request; continued.after = next
                page = try await perform(continued, filter: filter)
                guard ticket == generation, query == browser.query, !Task.isCancelled else { return }
            }
            if !more, !previewIDs.isEmpty, let reconcile=browser.reconcileSearchPreview {
                page=try await reconcile(request,previewIDs,page)
                guard ticket == generation, query == browser.query, !Task.isCancelled else { return }
            }
            var seen = Set(more ? items.map(\.id) : [])
            // The typed matches stay with the ranked page (the index never holds typed words, so it can't rank them).
            let fresh = page.items.filter { seen.insert($0.id).inserted } + (more ? [] : typed.items.filter { seen.insert($0.id).inserted })
            if !more {
                resolveTask?.cancel()
                resolved = [:]; attempted = []; members = [:]; loadingMembers = []
                noteHits = notes; noteMoments = [:]; noteAttempted = []
                pageQuery = request; searchedText = text; searchedAt = askedAt
                typedSnippets = typed.snippets; typedPlaces = typed.places; typedLines = typed.lines; typedByName = typed.byName
                evidence = [:]; loadingEvidence = []
                if !publishedEarly { selectedRowID = nil; selectedAnchor = nil }
            }
            items = more ? items + fresh : fresh; result = page
            rebuild()
            // VoiceOver hears the count once the hits sit in their moments (the list's count).
            if !resolveMoments(announcing: true) { announce() }
        } catch {
            if ticket == generation && !Task.isCancelled { self.error = Self.unavailableText }
        }
        if ticket == generation { busy = false; updateContext() }
    }

    private func makeQuery(_ text: String, filter: RecallFilter?) -> MemorySearchQuery {
        MemorySearchQuery(text, app: filter?.kind == .app ? filter?.value : nil,
                          start: rangeApplies ? period.start(now: now, calendar: calendar) : nil,
                          limit: 50, site: filter?.kind == .site ? filter?.value : nil)
    }

    /// `searchCanonicalQuery` when set; otherwise `searchCanonical(text, cursor)` with the filter applied here.
    private func perform(_ q: MemorySearchQuery, filter: RecallFilter?) async throws -> MemorySearchResult {
        guard let browser else { throw MemError.missing }
        if let search = browser.searchCanonicalQuery { return try await search(q) }
        guard let search = browser.searchCanonical else { throw MemError.missing }
        var page = try await search(q.text, q.after)
        if let filter {
            page.items = page.items.filter { item in
                switch filter.kind {
                case .app: return item.evidence.bundle == filter.value || item.evidence.app == filter.value
                case .site: return URL(string: item.evidence.url)?.host?.lowercased() == filter.value.lowercased()
                }
            }
        }
        return page
    }

    /// Try Again after an error.
    public func retry() { retriedChangedSource = false; load(immediate: true) }
    /// ⌥↩ / Search More History: the next page, appended without duplicates.
    public func searchMore() { load(more: true) }

    public func setPeriod(_ value: Period) {
        rangeMenuOpen = false; rangeHighlight = nil
        guard value != period else { return }
        period = value
        if !showsRecents { load(immediate: true) }
    }

    /// The timeline's Find Related Moments: scope the search to one app or site. The query text stays.
    public func applyFilter(_ value: RecallFilter?) {
        filter = value
        if menuOpen { closeMenu() }
        if showsRecents {
            generation += 1; searchTask?.cancel()
            items = []; result = nil; busy = false; error = nil; sections = []; resultRows = []; noteHits = []
            updateContext()
        } else {
            load(immediate: true)
        }
    }

    // MARK: Grouping

    /// The resolver for the browser's current calendar (made again when its time zone changes, so day
    /// keys near midnight follow the zone the rows are drawn in).
    private var resolver: MomentResolver? {
        guard let browser, browser.loadCanonicalDay != nil else { return nil }
        let zone = browser.calendar.timeZone.identifier
        if let r = resolverInstance, resolverZone == zone { return r }
        let r = MomentResolver(cache: browser.dayCache, calendar: browser.calendar)
        resolverInstance = r
        resolverZone = zone
        return r
    }

    /// Hits → moments, one day at a time, rebuilding after each day. A partial day's hit stays an action row.
    /// Returns whether grouping was started; with `announcing`, VoiceOver hears the count when it ends.
    @discardableResult
    private func resolveMoments(announcing: Bool = false) -> Bool {
        guard let resolver else { return false }
        let pending = items.filter { !attempted.contains($0.id) }
        let pendingNotes = noteHits.filter { $0.actionID != nil && !noteAttempted.contains($0.id) }
        guard !pending.isEmpty || !pendingNotes.isEmpty else { return false }
        resolveTask?.cancel()
        let ticket = generation
        let zone = timeZone.identifier
        var order: [String] = []
        var byDay: [String: [MemoryItem]] = [:]
        for item in pending {
            let key = timestamp(item.evidence.at).flatMap { try? DayScope.key($0, timezone: zone) } ?? ""
            if byDay[key] == nil { order.append(key) }
            byDay[key, default: []].append(item)
        }
        resolveTask = Task { @MainActor [weak self] in
            for key in order {
                for item in byDay[key] ?? [] {
                    guard let self, ticket == self.generation, !Task.isCancelled else { return }
                    if let known = self.resolved.values.first(where: { $0.actionIDs.contains(item.id) }) {
                        self.resolved[item.id] = known; self.attempted.insert(item.id); continue
                    }
                    guard let at = timestamp(item.evidence.at) else { self.attempted.insert(item.id); continue }
                    let m = await resolver.moment(containing: item.id, at: at)
                    guard ticket == self.generation, !Task.isCancelled else { return }
                    self.attempted.insert(item.id)
                    if let m, m.summary != .incomplete { self.resolved[item.id] = m }
                }
                self?.rebuild()
            }
            // Note lines and moments: placed in their moment by the action the line cites.
            for hit in pendingNotes {
                guard let self, ticket == self.generation, !Task.isCancelled else { return }
                self.noteAttempted.insert(hit.id)
                guard let id = hit.actionID, let at = timestamp(hit.at) else { continue }
                if let known = self.resolved.values.first(where: { $0.actionIDs.contains(id) }) ?? self.noteMoments.values.first(where: { $0.actionIDs.contains(id) }) {
                    self.noteMoments[hit.id] = known; continue
                }
                let m = await resolver.moment(containing: id, at: at)
                guard ticket == self.generation, !Task.isCancelled else { return }
                if let m, m.summary != .incomplete { self.noteMoments[hit.id] = m }
            }
            if !pendingNotes.isEmpty { self?.rebuild() }
            guard let self, ticket == self.generation, !Task.isCancelled else { return }
            self.updateContext()
            if announcing { self.announce() }
        }
        return true
    }

    /// The note levels search shows, each as the moment it belongs to (owner, 9/30: search is flat).
    public static let momentNoteLevels: Set<String> = ["line", "moment"]

    /// Rows from the hits (merging hits of one moment), then sections: Best match (Typesense only), then days
    /// newest first, rows by the time they show (newest first) within a day. Search's own ungrouped path: every row is
    /// one moment (or one hit), built here from the hits and never from the timeline's blocks or sessions
    /// (`FocusListLayout`), so grouping the timeline never reaches search.
    func rebuild() {
        let zone = timeZone.identifier, cal = calendar
        var rows: [RecallRow] = []
        var index: [String: Int] = [:]
        for item in items {
            let at = timestamp(item.evidence.at) ?? .distantPast
            if let m = resolved[item.id] {
                if let i = index[m.id] {
                    rows[i].hits.append(item); rows[i].latest = max(rows[i].latest, at)
                } else {
                    index[m.id] = rows.count
                    rows.append(RecallRow(id: m.id, kind: .moment(m), hits: [item], dayKey: m.dayKey, day: cal.startOfDay(for: m.start),
                                          time: m.start, latest: at))
                }
            } else {
                let key = (try? DayScope.key(at, timezone: zone)) ?? ""
                rows.append(RecallRow(id: "action:" + item.id, kind: .action, hits: [item], dayKey: key, day: cal.startOfDay(for: at),
                                      time: at, latest: at))
            }
        }
        // The note hits: a line (or a moment's note) joins its moment's row, or makes one. A line shows only once it is
        // placed in its moment: it is never a row of its own.
        for hit in noteHits where Self.momentNoteLevels.contains(hit.level) {
            guard let m = noteMoments[hit.id] else { continue }
            let at = timestamp(hit.at) ?? .distantPast
            if let i = index[m.id] {
                if rows[i].note == nil || (rows[i].note?.level == "moment" && hit.level == "line") { rows[i].note = hit }
            } else {
                index[m.id] = rows.count
                var row = RecallRow(id: m.id, kind: .moment(m), hits: [], dayKey: m.dayKey, day: cal.startOfDay(for: m.start), time: m.start, latest: at)
                row.note = hit
                rows.append(row)
            }
        }
        // claude/searchui-1005: each row knows its typed words, its conversation and the time of its first matching
        // line; hits of one conversation (or one window) close together become one row; a conversation's quiet moments
        // ("Read texts with Sam Rivera.") fold into that day's row of the same conversation.
        rows = Self.fold(rows.map(withTyped), window: Self.mergeWindow)
        let terms = self.terms
        for i in rows.indices { rows[i].time = Self.rowLine(rows[i], terms: terms).at ?? rows[i].time }
        var out: [RecallSection] = []
        var rest = rows
        // Best match: a moment whose whole note matched, else one found by a line, else Typesense's most relevant hit.
        let rank = ["moment": 0, "line": 1]
        // claude/searchui-1005: code's reading line ("Read texts with Sam Rivera.") says nothing a best match needs.
        let noteBest = rows.indices.filter { rows[$0].note.map { !$0.text.hasPrefix(Self.readingLine) } ?? false }
            .min { (rank[rows[$0].note!.level] ?? 9, $0) < (rank[rows[$1].note!.level] ?? 9, $1) }
        if !keepsDirectPreviewSections, let i = noteBest {
            out.append(RecallSection(id: "best", title: "Best match", detail: nil, rows: [rows[i]]))
            rest.remove(at: i)
        } else if !keepsDirectPreviewSections, result?.backend == "typesense", let best = bestMatchItemID, let i = rows.firstIndex(where: { $0.itemIDs.contains(best) }) {
            out.append(RecallSection(id: "best", title: "Best match", detail: nil, rows: [rows[i]]))
            rest.remove(at: i)
        }
        var days: [String] = []
        var byDay: [String: [(Int, RecallRow)]] = [:]
        for (i, row) in rest.enumerated() {
            if byDay[row.dayKey] == nil { days.append(row.dayKey) }
            byDay[row.dayKey, default: []].append((i, row))
        }
        let now = self.now
        let sortedDays = days.sorted { (byDay[$0]?.first?.1.day ?? .distantPast) > (byDay[$1]?.first?.1.day ?? .distantPast) }
        for key in sortedDays {
            // Time-descending by the time each row shows (its first matching line), so the section reads in order; ties
            // keep result order.
            let group = (byDay[key] ?? []).sorted {
                $0.1.time != $1.1.time ? $0.1.time > $1.1.time : $0.0 < $1.0
            }.map(\.1)
            guard let day = group.first?.day else { continue }
            let title = DaydreamFormat.dayTitle(day, now: now, calendar: cal)
            out.append(RecallSection(id: "day:" + key, title: title.title, detail: Self.sectionDetail(day, now: now, calendar: cal), rows: group))
        }
        resultRows = rows
        sections = out
        // Keep the selection on the same hit when its row merged into a moment.
        let display = out.flatMap(\.rows)
        if let id = selectedRowID, !display.contains(where: { $0.id == id }) {
            selectedRowID = selectedAnchor.flatMap { anchor in display.first { $0.itemIDs.contains(anchor) }?.id }
        }
        loadMembersForSelection()
    }

    /// The row with the typed words of its hits, where they were typed, and the conversation it is.
    private func withTyped(_ row: RecallRow) -> RecallRow {
        var copy = row
        for hit in row.hits {
            if let t = typedSnippets[hit.id] { copy.typed[hit.id] = t }
            if let t = typedLines[hit.id] { copy.typedLines[hit.id] = t }
            if typedByName.contains(hit.id) { copy.byName.insert(hit.id) }
        }
        // The place of the row's typed hits: a conversation first, then any other place, a search last (hits are in result
        // order: exact matches first, newest first).
        let places = row.hits.compactMap { typedPlaces[$0.id] }
        copy.typedPlace = places.first { !$0.search && !$0.place.isEmpty } ?? places.first { !$0.search } ?? places.first
        if let p = copy.typedPlace, p.label == "Texts", !p.place.isEmpty { copy.conversation = p.place }
        else if let m = row.moment { copy.conversation = Self.conversationName(m, noteTitle: row.note?.inTitle) }
        return copy
    }

    /// claude/searchui-1005: the Messages conversation a moment is, by its own thread name ("Texts with Sam Rivera" is
    /// "Sam Rivera"); nil for any other moment. The name is the one Messages showed, read by code, never a guess.
    /// `noteTitle`: the title of the note a matching line is in ("Texts with Sam Rivera"). A Messages moment still titled by
    /// its window (no note, no thread name) is the conversation its window names (`SendRules.messagesConversation`: never
    /// New Message or the app's own windows).
    public static func conversationName(_ m: MomentSlice, noteTitle: String? = nil) -> String? {
        let messages = m.bundles.contains(messagesBundle) || m.primaryBundle == messagesBundle
        var names: [String] = []
        if let live = m.live, live.kind == "texts" { names.append(live.label) }
        if messages { names += [m.title, noteTitle ?? ""] }
        for label in names where label.hasPrefix(textsWith) {
            let name = String(label.dropFirst(textsWith.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        if messages, m.bundles.allSatisfy({ $0 == messagesBundle }), m.live == nil, !m.summary.isReady, !m.stale {
            return SendRules.messagesConversation(m.title)
        }
        return nil
    }
    static let messagesBundle = "com.apple.MobileSMS"
    static let textsWith = "Texts with "
    /// How close two hits of one conversation (or one window) must be to share a row (owner 10/04: "within a few minutes").
    public static let mergeWindow: TimeInterval = 5 * 60

    /// A row's own words: typed words that hold a query word (or, found by the conversation's name, a message's words).
    static func hasWords(_ row: RecallRow) -> Bool { row.hits.contains { !(row.typed[$0.id] ?? "").isEmpty } }

    /// claude/searchui-1005 (owner 10/04): one row per conversation stretch.
    /// - Ungrouped hits (not yet placed in a moment) of one conversation, or one app window, within `window` of each other
    ///   on one day are one row: its hits in result order, its count their number.
    /// - A moment of a conversation that holds none of the person's matching words (found by its note, "Read texts with
    ///   Sam Rivera.", or by the conversation's name in a title) folds into that day's row of the same conversation:
    ///   the row with words, else the first such row. Two moments that each hold matching words stay two rows (search
    ///   is flat moments), and nothing folds across days.
    public static func fold(_ rows: [RecallRow], window: TimeInterval) -> [RecallRow] {
        func times(_ r: RecallRow) -> [Date] { r.hits.compactMap { timestamp($0.evidence.at) } }
        func near(_ a: RecallRow, _ b: RecallRow) -> Bool {
            let x = times(a), y = times(b)
            return x.contains { p in y.contains { abs($0.timeIntervalSince(p)) <= window } }
        }
        func key(_ r: RecallRow) -> String? {
            if r.isTypedSearch { return nil }
            if let c = r.conversation { return "texts|" + c.lowercased() }
            if let p = r.typedPlace { return "typed|" + p.label.lowercased() + "|" + p.place.lowercased() }
            guard let hit = r.anchor else { return nil }
            return "app|" + hit.evidence.bundle + "|" + hit.evidence.app + "|" + hit.evidence.title
        }
        var merged: [RecallRow] = []
        for row in rows {
            if row.moment == nil, let k = key(row),
               let i = merged.lastIndex(where: { $0.moment == nil && key($0) == k && $0.dayKey == row.dayKey && near($0, row) }) {
                merged[i].absorb(row)
            } else {
                merged.append(row)
            }
        }
        var out: [RecallRow] = []
        var target: [String: Int] = [:]
        // The fold target of each day's conversation: its first row with words, else its first row.
        for row in merged {
            guard row.moment != nil, let c = row.conversation else { continue }
            let k = row.dayKey + "|" + c.lowercased()
            if target[k] == nil || (!hasWords(merged[target[k]!]) && hasWords(row)) { target[k] = merged.firstIndex { $0.id == row.id } }
        }
        var moved: [Int: [RecallRow]] = [:]
        for (i, row) in merged.enumerated() {
            if row.moment != nil, let c = row.conversation, !hasWords(row), let t = target[row.dayKey + "|" + c.lowercased()], t != i {
                moved[t, default: []].append(row)
            }
        }
        let gone = Set(moved.values.flatMap { $0.map(\.id) })
        for (i, var row) in merged.enumerated() where !gone.contains(row.id) {
            for quiet in moved[i] ?? [] { row.absorb(quiet) }
            out.append(row)
        }
        return out
    }

    /// A day section's trailing text: none, since the title names the day ("Today", "Monday", "Sep 14"),
    /// except the year for a day in another year (ux/declutter).
    public static func sectionDetail(_ day: Date, now: Date, calendar: Calendar) -> String? {
        calendar.component(.year, from: day) == calendar.component(.year, from: now) ? nil : String(calendar.component(.year, from: day))
    }

    /// The Typesense answer's most relevant hit. The core puts the store's last ten seconds first,
    /// in time order and ahead of the ranked hits (`indexedSearch`), so those are skipped: a hit
    /// seen just before the search is recent, not relevant.
    var bestMatchItemID: String? {
        guard result?.backend == "typesense" else { return nil }
        let cutoff = searchedAt?.addingTimeInterval(-10)
        return items.first { item in
            guard let cutoff, let at = timestamp(item.evidence.at) else { return true }
            return at < cutoff
        }?.id
    }

    // MARK: Members (preview ticks, the Open Original target)

    func loadMembers(_ m: MomentSlice, limit: Int) {
        guard let resolver, !loadingMembers.contains(m.id), (members[m.id]?.limit ?? 0) < limit, members[m.id]?.complete != true else { return }
        loadingMembers.insert(m.id)
        let ticket = generation
        Task { @MainActor [weak self] in
            let page = try? await resolver.memberActions(of: m, limit: limit)
            guard let self else { return }
            self.loadingMembers.remove(m.id)
            guard ticket == self.generation || self.showsRecents, let page else { return }
            self.members[m.id] = Members(actions: page.actions, complete: page.complete, limit: limit)
            self.updateContext()
        }
    }

    private func loadMembersForSelection() {
        if let m = selectedRow?.moment { loadMembers(m, limit: 40) }
        loadEvidence(selectedRow)
    }

    /// claude/searchui-1005: the texts of the selected result's moment (and the moments folded into it), for its detail:
    /// the timeline detail's own verified owner source, read off the main thread, never stored. A withheld or expired
    /// one is left out.
    private func loadEvidence(_ row: RecallRow?) {
        guard let row, let load = browser?.loadOwnerSourcePreviews else { return }
        let ticket = generation
        for m in ([row.moment] + row.folded.map { Optional($0) }).compactMap({ $0 })
        where evidence[m.id] == nil && !loadingEvidence.contains(m.id) {
            loadingEvidence.insert(m.id)
            let ids = m.actionIDs
            Task { @MainActor [weak self] in
                let previews = await load(ids)
                guard let self, ticket == self.generation, self.loadingEvidence.contains(m.id) else { return }
                self.loadingEvidence.remove(m.id)
                let now = Date()
                self.evidence[m.id] = previews.filter { !$0.isWithheld && !$0.parts.isEmpty && ($0.expiresAt.map { $0 > now } ?? true) }
            }
        }
    }

    // MARK: Selection

    /// Selects a row by ID (click).
    public func select(_ id: String) {
        guard selectedRowID != id else { return }
        selectedRowID = id
        selectedAnchor = displayRows.first { $0.id == id }?.anchor?.id ?? id
        loadMembersForSelection()
        updateContext()
    }

    /// ↑/↓: moves the selection.
    public func move(_ delta: Int) {
        let rows = displayRows
        guard !rows.isEmpty else { return }
        let current = selectedIndex ?? 0
        let next = min(max(current + delta, 0), rows.count - 1)
        guard next != current || selectedRowID == nil else { return }
        selectedRowID = rows[next].id
        selectedAnchor = rows[next].anchor?.id ?? rows[next].id
        scrollSerial += 1
        loadMembersForSelection()
        updateContext()
    }

    /// claude/searchui-1005 (owner 10/04: the full-page result "repeats the preview" and adds filler): Return and a
    /// double-click show the selected result in context, in its own day with the moment open (`showInDay`). The preview
    /// beside the list is where a result is read; there is no pushed detail.
    public static let openTitle = "Show in Context"
    public func openMoment() {
        guard selectedRow != nil else { return }
        if menuOpen { closeMenu() }
        showInDay()
    }

    /// Esc (plan §5): closes a menu, else clears the query and the filter, else
    /// closes Recall. Clearing a query that alone presented Recall closes it; a summoned Recall
    /// (⌘K, ⌘F, Search…) goes back to Pick up where you left off.
    public func cancel() {
        if rangeMenuOpen { closeRangeMenu(); return }
        if menuOpen { closeMenu(); return }
        if let browser, !browser.query.isEmpty || filter != nil {
            if browser.query.isEmpty { applyFilter(nil); return }
            filter = nil
            browser.query = ""
            return
        }
        close()
    }

    // MARK: Date range menu

    /// The date-range chip: opens or closes its menu (the Actions menu closes).
    public func toggleRangeMenu() {
        if rangeMenuOpen { closeRangeMenu(); return }
        guard rangeApplies else { return }
        if menuOpen { closeMenu() }
        rangeMenuOpen = true
        rangeHighlight = period
    }
    public func closeRangeMenu() { rangeMenuOpen = false; rangeHighlight = nil }
    /// ↑/↓ while the date-range menu is open.
    public func rangeMove(_ delta: Int) {
        let all = Period.allCases
        let current = all.firstIndex(of: rangeHighlight ?? period) ?? 0
        rangeHighlight = all[min(max(current + delta, 0), all.count - 1)]
    }
    /// Return while the date-range menu is open: picks the highlighted range.
    public func rangeRun() { setPeriod(rangeHighlight ?? period) }

    /// Closes Recall: clears the query and the summon flag. The day underneath is unchanged.
    public func close() {
        guard let browser else { return }
        if menuOpen { closeMenu() }
        if !browser.query.isEmpty { browser.query = "" }
        if browser.recallPresented { browser.recallPresented = false }
    }

    func requestFocus() { focusSerial += 1 }

    // MARK: Actions menu

    /// The Actions menu for the row it acts on (kit items for a moment; the same titles and keys for a hit).
    public var menuItems: [MomentActionItem] { actionRow.map(menuItems(for:)) ?? [] }
    /// The Actions menu's items for `row`: ⌘K's for the row it acts on, and a secondary click's for any row
    /// (`MomentContextMenu`), so the two never differ.
    public func menuItems(for row: RecallRow) -> [MomentActionItem] {
        let caps = capabilities
        let original = originalTarget(row)
        if let m = row.moment {
            return MomentActions.items(for: m, context: .recall(dayIsToday: isToday(row.dayKey)), browser: caps).compactMap { item in
                switch item.id {
                case .openOriginal, .openApp:
                    // Recall's own target (a web hit's page can exist when the moment lists no site, and
                    // the reverse): the title, symbol and help follow where ⌘↩ really goes (L15).
                    guard let original else { return nil }
                    return MomentActionItem(id: original.id, title: original.title, symbol: original.symbol, keys: item.keys,
                                            enabled: !originalBlocked, reason: OriginalUnavailableBanner.text, group: item.group, help: original.help)
                case .openMoment:
                    // claude/searchui-1005: Return shows the result in context; Show in <Day> is that item.
                    return nil
                case .findRelated:
                    // Search's moments are shown in context instead (owner, 9/30: Show in Context under the summary).
                    return nil
                case .editCorrection:
                    // No correction editor is reachable from Recall yet (contract request 5): hidden
                    // rather than offered under a title it does not keep.
                    return nil
                default:
                    return item
                }
            }
        }
        guard let hit = row.anchor else { return [] }
        var out: [MomentActionItem] = []
        if let original {
            out.append(MomentActionItem(id: original.id, title: original.title, symbol: original.symbol, keys: "⌘↩",
                                        enabled: !originalBlocked, reason: OriginalUnavailableBanner.text, group: .open, help: original.help))
        }
        let dayName = isToday(row.dayKey) ? "Today" : DaydreamFormat.dayName(row.time, now: now, calendar: calendar)
        out.append(MomentActionItem(id: .showInToday, title: "Show in " + dayName, symbol: "calendar", keys: "⌘T", group: .open))
        // claude/searchui-1005: a row of several merged hits forgets nothing on its own (Forget This Action names one);
        // Show in <Day> reaches each of them.
        if caps.delete, row.hits.count == 1 {
            out.append(MomentActionItem(id: .forget, title: "Forget This Action…", symbol: "trash", destructive: true, group: .privacy))
        }
        let bundle = hit.evidence.bundle, name = RecallText.appName(hit)
        if caps.excludeApp, !bundle.isEmpty, !name.isEmpty, !caps.exclusions.isExcluded(bundle) {
            out.append(MomentActionItem(id: .exclude, title: "Exclude \(name) from Recording…", symbol: "eye.slash", group: .privacy))
        }
        return out
    }
    /// Every menu item (the menu has no search line; typing only moves the highlight).
    public var visibleMenuItems: [MomentActionItem] { ActionsMenuView.visibleRows(menuItems, filter: "") }
    /// Type-select: the first enabled item whose title starts with what was typed, else contains it.
    private func typeSelect() {
        let q = menuFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let rows = visibleMenuItems.filter(\.enabled)
        if let hit = rows.first(where: { $0.title.lowercased().hasPrefix(q.lowercased()) })
            ?? ActionsMenuView.visibleRows(rows, filter: q).first {
            menuSelection = hit.id
        }
    }

    /// ⌘K while visible: opens or closes the Actions menu for the selected result.
    public func toggleMenu() {
        if menuOpen { closeMenu(); return }
        guard actionRow != nil else { return }
        closeRangeMenu()
        menuFilter = ""
        menuOpen = true
        menuSelection = visibleMenuItems.first(where: \.enabled)?.id
    }
    public func closeMenu() { menuOpen = false; menuFilter = ""; menuSelection = nil }

    /// ↑/↓ while the menu is open: the previous/next enabled item.
    public func menuMove(_ delta: Int) {
        let rows = visibleMenuItems.filter(\.enabled)
        guard !rows.isEmpty else { menuSelection = nil; return }
        let current = rows.firstIndex { $0.id == menuSelection } ?? (delta > 0 ? -1 : rows.count)
        menuSelection = rows[min(max(current + delta, 0), rows.count - 1)].id
    }
    /// Typing while the menu is open moves the highlight to the matching item (nothing is hidden).
    public func menuType(_ text: String) {
        menuFilter += text
        typeSelect()
    }
    public func menuBackspace() {
        guard !menuFilter.isEmpty else { return }
        menuFilter.removeLast()
        typeSelect()
    }
    /// Return while the menu is open: runs the highlighted item.
    public func menuRun() {
        guard let id = menuSelection, visibleMenuItems.contains(where: { $0.id == id && $0.enabled }) else { return }
        run(id)
    }

    /// A secondary click's item on `rowID`: the row becomes the one the Actions menu acts on, then the item runs.
    public func run(_ id: MomentActionID, onRow rowID: String) {
        if actionRow?.id != rowID { select(rowID) }
        run(id)
    }

    /// Runs one Actions menu item (menu click, Return in the menu, or a menu bar command).
    public func run(_ id: MomentActionID) {
        guard menuItems.contains(where: { $0.id == id && $0.enabled }) else { closeMenu(); return }
        closeMenu()
        switch id {
        case .openMoment: openMoment()
        case .openOriginal, .openApp: openOriginal()
        case .showInToday: showInDay()
        case .copySummary: copySummary()
        case .summarizeNow: summarizeNow()
        case .findRelated, .editCorrection: break
        case .forget: forget()
        case .exclude: exclude()
        }
    }

    /// Menu bar commands while Recall is visible.
    public func handle(_ command: DaydreamCommand) {
        switch command {
        case .toggleActions: toggleMenu()
        case .openOriginal: if !menuItems.contains(where: { ($0.id == .openOriginal || $0.id == .openApp) && $0.enabled }) { return }; closeMenu(); openOriginal()
        case .copySummary: run(.copySummary)
        case .showInToday: run(.showInToday)
        case .forget: run(.forget)
        case .exclude: run(.exclude)
        case .editCorrection: run(.editCorrection)
        case .openRecall, .find: requestFocus()
        case .previousDay, .nextDay, .today, .refresh, .excludeSite, .findRelated: break
        }
    }

    // MARK: Moment actions

    func isToday(_ key: String) -> Bool { (try? DayScope.key(now, timezone: timeZone.identifier)) == key }

    /// Open Original's target: a web hit's verified original, else the moment's web action, else the app.
    func originalTarget(_ row: RecallRow) -> RecallOriginal? {
        let caps = capabilities
        if caps.reopen {
            // page-links-1003: the help names the page's own link when it has one ("Opens youtube.com/watch… in your browser").
            if let hit = row.hits.first(where: { RecallText.webHost($0.evidence.url) != nil }), let host = RecallText.webHost(hit.evidence.url) {
                return .reopen(hit.id, host: hit.evidence.page.flatMap(BrowserSites.shortLink) ?? host)
            }
            if let m = row.moment, !m.sites.filter({ !$0.isEmpty }).isEmpty,
               let action = members[m.id]?.actions.first(where: { !$0.site.isEmpty }) {
                return .reopen(action.id, host: action.link.flatMap(BrowserSites.shortLink) ?? KitBrowsers.host(action.site))
            }
        }
        if caps.openApp {
            if let m = row.moment, let bundle = m.primaryBundle, let name = m.primaryApp { return .app(bundle, name: name) }
            if row.moment == nil, let hit = row.anchor, !hit.evidence.bundle.isEmpty {
                let name = RecallText.appName(hit)
                if !name.isEmpty { return .app(hit.evidence.bundle, name: name) }
            }
        }
        return nil
    }

    /// ⌘↩: opens the selected result's original once. A failed reopen shows the banner and disables ⌘↩ until the query changes.
    public func openOriginal() {
        guard let browser, !originalBlocked, let row = actionRow, let target = originalTarget(row) else { return }
        switch target {
        case .reopen(let id, _):
            guard let reopen = browser.reopenCanonical else { return }
            let query = browser.query
            Task { @MainActor [weak self] in
                do { try await reopen(id) } catch {
                    guard let self else { return }
                    self.originalFailedQuery = query
                    self.unavailableActions.insert(id)
                    self.updateContext()
                }
            }
        case .app(let bundle, _):
            browser.openApp?(bundle)
        }
    }

    /// One action's Open Original from the detail's "What happened" rows.
    func openOriginal(action: CanonicalAction) {
        guard let browser, let reopen = browser.reopenCanonical, !unavailableActions.contains(action.id) else { return }
        Task { @MainActor [weak self] in
            do { try await reopen(action.id) } catch { self?.unavailableActions.insert(action.id) }
        }
    }

    func dismissOriginalBanner() { originalFailedQuery = nil }

    /// Show in Today / <Weekday>, the preview's Show in Context, and Return: closes Recall and expands the moment in its day
    /// (the day is the moment's own, so a moment from another day opens that day with it selected).
    public func showInDay() {
        guard let browser, let row = actionRow else { return }
        if let m = row.moment {
            browser.showInDay(m)
        } else {
            browser.focusedDay = isToday(row.dayKey) ? nil : row.dayKey
            browser.reference = nil
        }
        close()
    }

    /// ⇧⌘C: the moment's summary (title, then its bullets and the person's corrections) as plain text.
    public func copySummary() {
        guard let m = actionRow?.moment, m.hasSummary else { return }
        var lines = [MomentSubtitle.rowTitle(m)]
        for b in m.bullets { lines.append("• " + b.text + (b.correction ? " (your correction)" : "")) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    func summarizeNow() {
        guard let browser, let m = actionRow?.moment, browser.generateCanonicalNote != nil else { return }
        let zone = timeZone.identifier
        Task { @MainActor [weak self] in
            try? await browser.summarizeNow(day: m.dayKey, timeZone: zone, id: m.id, end: m.end)
            self?.browser?.dayCache.invalidate(m.dayKey)
            self?.retry()
        }
    }

    func forget() {
        guard let row = actionRow else { return }
        if let m = row.moment {
            guard m.summary != .incomplete else { return }
            forgetRequest = MomentForgetRequest(moment: m, timeZone: timeZone)
        } else if let hit = row.anchor, let at = timestamp(hit.evidence.at) {
            actionForgetRequest = RecallActionForgetRequest(id: hit.id, scope: MemoryActionScope(kind: "action", id: hit.id, day: row.dayKey, timezone: timeZone.identifier),
                                                            at: at, timeZone: timeZone)
        }
    }

    /// The footer copy after a failed exclusion. The app's own message is shown as it is: it says
    /// when recording stopped for the save and the change is still waiting (amendments F2,
    /// contract request 10). Anything else makes no claim about what happened.
    public static func excludeFailureText(_ error: Error) -> String {
        if let e = error as? MemError, case .invalid(let text) = e, !text.isEmpty { return text }
        return "The exclusion wasn't confirmed. Review exclusions in Settings."
    }

    func excludeFailed(_ error: Error) { notice = Self.excludeFailureText(error) }

    func exclude() {
        guard let row = actionRow else { return }
        if let m = row.moment { excludeRequest = ExcludeAppRequest(moment: m); return }
        guard let hit = row.anchor, !hit.evidence.bundle.isEmpty else { return }
        let name = RecallText.appName(hit)
        guard !name.isEmpty, !capabilities.exclusions.isExcluded(hit.evidence.bundle) else { return }
        excludeRequest = ExcludeAppRequest(bundle: hit.evidence.bundle, appName: name)
    }

    /// After a forget or an exclusion: the day data changed, so read again.
    func memoryChanged() {
        browser?.dayCache.invalidateAll()
        resolverInstance = nil
        items = []; result = nil; resolved = [:]; attempted = []; members = [:]; loadingMembers = []
        noteHits = []; noteMoments = [:]; noteAttempted = []; sections = []; resultRows = []; evidence = [:]; loadingEvidence = []
        if !showsRecents { load(immediate: true) } else { browser?.today.refresh(force: true) }
    }

    // MARK: Menu bar state and VoiceOver

    /// Writes `browser.commandContext` for the Moment/Go menus while Recall is visible.
    func updateContext() {
        guard let browser, browser.recallVisible else { return }
        let ctx: DaydreamCommandContext
        if let row = actionRow {
            let items = menuItems
            func enabled(_ id: MomentActionID) -> Bool { items.contains { $0.id == id && $0.enabled } }
            let open = items.first { ($0.id == .openOriginal || $0.id == .openApp) && $0.enabled }
            let exclude = enabled(.exclude) ? (row.moment?.primaryApp ?? row.anchor.map(RecallText.appName)) : nil
            ctx = DaydreamCommandContext(hasSelection: true, hasSummary: row.moment?.hasSummary ?? false, canOpenOriginal: open != nil,
                                         canForget: enabled(.forget), selectionDayTitle: isToday(row.dayKey) ? "Today" : DaydreamFormat.dayName(row.time, now: now, calendar: calendar),
                                         recallVisible: true, openTitle: open?.title, excludeAppName: exclude,
                                         canFindRelated: enabled(.findRelated), canEditCorrection: enabled(.editCorrection))
        } else {
            ctx = DaydreamCommandContext(recallVisible: true)
        }
        if browser.commandContext != ctx { browser.commandContext = ctx }
    }

    /// The count VoiceOver hears: the rows the list shows ("16 results", "7+ results", "No results").
    public var announcementText: String {
        let n = displayRows.count
        return n == 0 ? "No results" : countText + (n == 1 && countText == "1" ? " result" : " results")
    }

    /// "7 results" for VoiceOver, at most once a second (a trailing announcement carries the latest count,
    /// read when it is spoken).
    private func announce() {
        announceWork?.cancel()
        let post = { [weak self] in
            guard let self, !self.showsRecents else { return }
            let n = self.displayRows.count, text = self.announcementText
            self.lastAnnounced = (n, Date())
            self.lastAnnouncement = text
            if let window = NSApp?.keyWindow ?? NSApp?.mainWindow {
                NSAccessibility.post(element: window, notification: .announcementRequested,
                                     userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
        }
        if let last = lastAnnounced, Date().timeIntervalSince(last.at) < 1 {
            let work = DispatchWorkItem(block: post)
            announceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (1 - Date().timeIntervalSince(last.at)), execute: work)
        } else {
            post()
        }
    }
}

// MARK: - What matched (claude/searchui-1005)

/// One line of evidence in a search result: who, when and what. Owner 10/04 ("The search is shit right now", "the actual
/// text evidence stuff is not showing"): a result shows the matching message itself, with who sent it and when, and the
/// detail shows the moment's texts with the match highlighted, before any note line.
public struct RecallHitLine: Equatable, Identifiable, Sendable {
    public let id: String
    public let at: Date?
    /// "You" for the person's own words; "Your draft" for words not sent; else the app or site the line is from.
    public let who: String
    public let text: String
    /// The person's own words (typed or texted).
    public let typed: Bool
    /// Holds a query word. A message shown for context, or found by its conversation's name, doesn't.
    public let matched: Bool
    public init(id: String, at: Date?, who: String, text: String, typed: Bool, matched: Bool) {
        self.id = id; self.at = at; self.who = who; self.text = text; self.typed = typed; self.matched = matched
    }
}

/// A result row's second line and its one time: the matching line (or a conversation's latest message), when it was,
/// and how many matching lines the row holds.
public struct RecallRowLine: Equatable, Sendable {
    public let text: String
    public let at: Date?
    public let count: Int
}

extension RecallModel {
    /// Who wrote the person's own words.
    public static let you = "You"
    /// claude/dayeval-1005 (owner 10/05): never "draft"; most of them were sent.
    public static let yourDraft = "You"
    /// What code says for a Messages moment it saw only being read. It is filler, never a result's line or title.
    static let readingLine = "Read texts with "
    /// The detail shows at most this many evidence lines (every matching one first).
    public static let evidenceLimit = 8

    /// The row's matching lines in time order, each once: the person's typed words (the longer part around the match),
    /// else the field that matched (a window or page title, with its app). A typed hit with no words left shows nothing,
    /// never its conversation's name, and a title that only names the row's conversation says nothing new.
    public func hitLines(_ row: RecallRow) -> [RecallHitLine] { Self.hitLines(row, terms: terms) }

    public static func hitLines(_ row: RecallRow, terms: [String]) -> [RecallHitLine] {
        var out: [RecallHitLine] = []
        var seen = Set<String>()
        let title = row.title
        for hit in row.hits {
            let at = timestamp(hit.evidence.at)
            if row.typed[hit.id] != nil || row.typedLines[hit.id] != nil {
                let words = (row.typedLines[hit.id] ?? row.typed[hit.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !words.isEmpty, seen.insert("you|" + words.lowercased()).inserted else { continue }
                out.append(RecallHitLine(id: hit.id, at: at, who: you, text: words, typed: true,
                                         matched: !row.byName.contains(hit.id) && RecallText.contains(words, terms)))
                continue
            }
            let found = RecallText.matches(hit, terms: terms).filter { $0.source != .typed }.map { RecallResultRow.line($0, row: row) }
            guard let text = found.first(where: { !MomentSubtitle.same($0, title) }) ?? (row.conversation == nil ? found.first : nil) else { continue }
            let app = RecallText.appName(hit)
            let who = app.isEmpty ? (RecallText.webHost(hit.evidence.url) ?? "") : app
            guard seen.insert(who.lowercased() + "|" + text.lowercased()).inserted else { continue }
            out.append(RecallHitLine(id: hit.id, at: at, who: who, text: text, typed: false, matched: true))
        }
        return out.sorted { ($0.at ?? .distantFuture, $0.id) < ($1.at ?? .distantFuture, $1.id) }
    }

    /// The row's second line and time (one time per row, owner 10/04):
    /// 1. the first of the person's own lines that holds a query word;
    /// 2. found by a conversation's name: its latest message;
    /// 3. the first other matching field that doesn't repeat the title;
    /// 4. the note line that matched (never a conversation's: code's "Read texts with …" says nothing);
    /// 5. the moment's own line (its note's first line, never a reading line), else its site.
    /// Never a template ("Line in …"). A search typed in an app has no second line (its words are the title).
    public func rowLine(_ row: RecallRow) -> RecallRowLine { Self.rowLine(row, terms: terms) }

    public static func rowLine(_ row: RecallRow, terms: [String]) -> RecallRowLine {
        let lines = hitLines(row, terms: terms)
        let count = lines.count
        func short(_ l: RecallHitLine) -> String { l.typed ? (row.typed[l.id].flatMap { $0.isEmpty ? nil : $0 } ?? l.text) : l.text }
        if row.isTypedSearch { return RecallRowLine(text: "", at: lines.first?.at ?? row.time, count: 1) }
        if let l = lines.first(where: { $0.typed && $0.matched }) { return RecallRowLine(text: short(l), at: l.at, count: count) }
        if let l = lines.last(where: \.typed) { return RecallRowLine(text: short(l), at: l.at, count: count) }
        if let l = lines.first(where: { !MomentSubtitle.same($0.text, row.title) }) { return RecallRowLine(text: l.typed ? l.text : DisplayWords.undraft(l.text), at: l.at, count: count) }
        if let n = row.note, row.conversation == nil {
            let text = n.level == "line" ? n.text : (n.lines.first { RecallText.contains($0, terms) } ?? "")
            if !text.isEmpty, !MomentSubtitle.same(text, row.title) { return RecallRowLine(text: DisplayWords.undraft(text), at: timestamp(n.at), count: max(count, 1)) }
        }
        return RecallRowLine(text: fallback(row), at: lines.first?.at ?? row.time, count: count)
    }

    /// A row's own line when nothing that matched can stand there.
    static func fallback(_ row: RecallRow) -> String {
        if let m = row.moment {
            var text = MomentSubtitle.rowText(for: m)
            if text.hasPrefix(readingLine) || row.conversation != nil && MomentSubtitle.same(text, row.title) { text = "" }
            // "Had Investor update open in Claude." under "Investor update" says the title again: the app (and site) instead.
            if text.hasPrefix("Had "), row.title.count >= 3, text.localizedCaseInsensitiveContains(row.title) {
                let site = row.site.flatMap { !$0.isEmpty && !row.title.localizedCaseInsensitiveContains($0) ? $0 : nil }
                let place = [row.appName, site ?? ""].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
                if !place.isEmpty { return place }
            }
            if !text.isEmpty || row.conversation != nil { return text }
            guard let site = row.site, !site.isEmpty, !row.title.localizedCaseInsensitiveContains(site) else { return "" }
            return site
        }
        return DisplayWords.undraft(row.anchor?.summary ?? "")
    }

    /// The detail's evidence: the texts of the row's moment (read for the detail) and its matching lines, each once, in
    /// time order. When there are more than `evidenceLimit`, every matching line stays and the rest are the latest.
    public func evidenceLines(_ row: RecallRow) -> [RecallHitLine] {
        let moments = ([row.moment] + row.folded.map { Optional($0) }).compactMap { $0 }
        let texts = moments.flatMap { evidence[$0.id] ?? [] }.map { p in
            (id: p.id, at: timestamp(p.at), text: p.parts.map(\.text).joined(separator: " "), draft: p.state == "draft", actionIDs: p.actionIDs)
        }
        return Self.evidence(texts: texts, hits: hitLines(row), terms: terms)
    }

    public static func evidence(texts: [(id: String, at: Date?, text: String, draft: Bool, actionIDs: [String])], hits: [RecallHitLine],
                                terms: [String]) -> [RecallHitLine] {
        var out: [RecallHitLine] = []
        var seen = Set<String>(), covered = Set<String>()
        func norm(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased() }
        for t in texts {
            let text = t.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !text.isEmpty, seen.insert(norm(text)).inserted else { continue }
            covered.formUnion(t.actionIDs)
            out.append(RecallHitLine(id: t.id, at: t.at, who: t.draft ? yourDraft : you, text: text, typed: true, matched: RecallText.contains(text, terms)))
        }
        for h in hits where !covered.contains(h.id) {
            // A search's words are a part of a text already shown when that text holds them all.
            let key = norm(h.text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{2026}")))
            guard seen.insert(norm(h.text)).inserted, !(h.typed && out.contains { $0.typed && norm($0.text).contains(key) }) else { continue }
            out.append(h)
        }
        if out.count > evidenceLimit {
            let matched = out.filter(\.matched)
            let rest = out.filter { !$0.matched }.sorted { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) }
            let keep = Set((matched + rest.prefix(max(0, evidenceLimit - matched.count))).map(\.id))
            out = out.filter { keep.contains($0.id) }
        }
        return out.sorted { ($0.at ?? .distantFuture, $0.id) < ($1.at ?? .distantFuture, $1.id) }
    }

    /// The note's lines the detail shows: a code reading line ("Read texts with Jordan Lane.") goes when the evidence holds
    /// the person's own texts (it says less than they do).
    public static func noteLines(_ bullets: [MomentBullet], evidence: [RecallHitLine]) -> [MomentBullet] {
        guard evidence.contains(where: \.typed) else { return bullets }
        return bullets.filter { $0.correction || !$0.text.hasPrefix(readingLine) }
    }
}

/// Holds a NotificationCenter observer and removes it when released (with the model).
final class RecallObserverToken {
    let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

/// Panel geometry (find-A): 900 × 620, list 440, split from 760 wide.
enum RecallLayout {
    static let panelWidth: CGFloat = 900
    static let panelHeight: CGFloat = 620
    static let listWidth: CGFloat = 440
    static let splitWidth: CGFloat = 760
    static let headerHeight: CGFloat = 60
    static let barHeight: CGFloat = 44
    static let rowHeight: CGFloat = 48
    /// The Actions menu's room: from half-way down the query bar to 6 pt above the action bar.
    static func menuHeight(panel height: CGFloat) -> CGFloat {
        max(120, height - headerHeight / 2 - barHeight - 14)
    }
}

private enum RecallBrowserKey {
    static let model = UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))
}

extension ActivityBrowser {
    /// Recall's state, created on first use and owned by the browser (like `dayCache`), so it outlives the
    /// panel's view and Find Related Moments can be heard before the panel appears.
    public var recallModel: RecallModel {
        if let model = objc_getAssociatedObject(self, RecallBrowserKey.model) as? RecallModel { return model }
        let model = RecallModel(browser: self)
        objc_setAssociatedObject(self, RecallBrowserKey.model, model, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        model.listenForFilters()
        return model
    }
}

extension RecallModel {
    /// Find Related Moments from the Focus List (`.daydreamRecallFilter`, posted with the browser as its
    /// object): apply the filter; the poster presents Recall. Only this browser's posts are heard, so a
    /// second window (the trial beside the main window) keeps its own Recall.
    func listenForFilters() {
        guard let browser else { return }
        let token = NotificationCenter.default.addObserver(forName: .daydreamRecallFilter, object: browser, queue: .main) { [weak self] note in
            guard let filter = RecallFilter(userInfo: note.userInfo) else { return }
            Task { @MainActor in self?.applyFilter(filter) }
        }
        filterObserver = RecallObserverToken(token)
    }
}
