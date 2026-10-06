import Foundation
import Combine
import SwiftUI
import MemoryCore

public struct ActivityApp: Hashable, Identifiable {
    public var id: String
    public var name: String
    public var bundle: String
    public init(name: String, bundle: String) {
        self.name = name.isEmpty ? "Unknown app" : name
        self.bundle = bundle
        self.id = bundle.isEmpty ? "unknown:" + self.name : bundle
    }
    public init(_ evidence: Evidence) {
        bundle = evidence.bundle; name = evidence.app.isEmpty ? "Unknown app" : evidence.app
        id = bundle.isEmpty ? "unknown:" + name : bundle
    }
}
public struct ActivityGroup: Identifiable {
    public var id: String
    public var day: Date
    public var items: [MemoryItem]
    public var start: Date { items.compactMap { timestamp($0.evidence.at) }.min() ?? day }
    public var end: Date { items.compactMap { timestamp($0.evidence.at) }.max() ?? start }
    public var apps: [ActivityApp] { Array(Set(items.map { ActivityApp($0.evidence) })).sorted { $0.name < $1.name } }
    public var pending: Bool { items.contains { $0.generatedAt.isEmpty || $0.writer == "pending-local-writer" } }
    public var title: String {
        if let purpose = items.first(where: { !$0.evidence.title.isEmpty })?.evidence.title { return purpose }
        if items.contains(where: { $0.actionState == "requested" || $0.actionState == "planned" }) { return "Questions and planning" }
        if items.contains(where: { ["searched","viewed_search"].contains($0.actionState) }) { return "Search and research" }
        return "Activity in " + apps.map(\.name).joined(separator: ", ")
    }
}
public struct ActivityDay: Identifiable {
    public var date: Date
    public var activities: [ActivityGroup]
    public var id: Date { date }
}
public struct AppScope: Equatable {
    public var activityID: String
    public var day: Date
    public var app: ActivityApp
    public var wholeDay: Bool = false
}
/// `failed`: a read that went wrong, drawn with its title and Try again. `held`: another DayDream has the history (gold
/// r2 review 1). Nothing failed and nothing here fixes it, so it is only its one line, with nothing to press; it clears
/// by itself once this copy opens the history.
public enum ActivityPhase { case loading, ready, failed(String), held(String) }

/// Presentation state is independent from persistence and never starts capture.
@MainActor public final class ActivityBrowser: ObservableObject {
    @Published public var items: [MemoryItem]
    @Published public var phase: ActivityPhase
    @Published public var query = ""
    @Published public var collapsedDays: Set<Date> = []
    @Published public var scope: AppScope?
    @Published public var selectedCanonicalActivity:String?
    /// An explicit Show in Context request also dismisses a previously pushed detail.
    @Published public private(set) var contextRevealSerial: UInt64 = 0
    /// Shared by Show in Today and both moment details. Identity always comes from the original moment.
    public func showInDay(_ moment: MomentSlice) {
        let today = try? DayScope.key(now(), timezone: calendar.timeZone.identifier)
        focusedDay = moment.dayKey == today ? nil : moment.dayKey
        selectedCanonicalActivity = nil
        selectedMomentID = moment.id
        expandedMomentID = moment.id
        reference = MomentReference(key: "moment:" + moment.id, day: moment.dayKey, moments: [moment.id])
        contextRevealSerial &+= 1
    }
    @Published public var evidenceOpen = false
    @Published public var dayLoading = false
    @Published public var dayError: String?
    @Published private var loadedDayItems: [MemoryItem]?
    public var loadDay: ((Date) async throws -> [MemoryItem])?
    public var loadCanonicalDay: ((String,String?) async throws -> ActionDay)?
    /// perf-1005: a moment's member actions in one read (`MemoryStore.memberActions`), off the main thread: day key and
    /// action ids → the actions in time order, or nil to walk the day's pages (`MomentResolver`). nil: always walk.
    public var loadMemberActions: ((String,[String]) async throws -> [CanonicalAction]?)?
    /// The days with any record in the display time zone (`MemoryStore.recordedDays`), oldest first: Previous/Next Day
    /// step between them (`FocusDay.step`). nil: every calendar day is a step.
    public var loadRecordedDays: ((String) async throws -> [String])?
    public var searchCanonical: ((String,String?) async throws -> MemorySearchResult)?
    /// A search in the window finished (page one), with how many results it found. The app counts it (usage counts:
    /// the number only, never the words searched).
    public var searched: ((Int) -> Void)?
    public var reopenCanonical: ((String) async throws -> Void)?
    public var generateCanonicalNote: ((String,String,String,Date) async throws -> Void)?
    /// fix/resummarize: moments whose Summarize Now is running (their row says "Updating…"; no other row changes).
    @Published public var updatingMoments: Set<String> = []
    /// claude/summary-fail-1003: moments whose last Summarize Now wrote nothing this time (a one-off, not summaries off or
    /// broken). Their card keeps its Summarize Now with `SummarizeNowNotice.quietLine`; a Summarize Now that writes clears it.
    @Published public var summarizeMisses: Set<String> = []
    /// Moments already tried again by themselves after a one-off (once each).
    private var summarizeRetried: Set<String> = []
    /// How long after a one-off it is tried again (checks shorten it).
    public var summarizeRetryDelay: TimeInterval = SummarizeNowNotice.retryDelay
    /// Summarize Now for one moment: marks it updating until the writer returns (the new note stored, or a failure).
    /// A one-off failure (`SummarizeNowNotice.banner` is nil) marks the moment missed and is tried again once, later,
    /// by itself; the error is still thrown so the caller can say what a real setup problem is.
    public func summarizeNow(day: String, timeZone: String, id: String, end: Date) async throws {
        guard let generate = generateCanonicalNote else { throw MemError.missing }
        updatingMoments.insert(id)
        defer { updatingMoments.remove(id) }
        do {
            try await generate(day, timeZone, id, end)
            summarizeMisses.remove(id)
        } catch {
            guard SummarizeNowNotice.banner(for: error, summaries: summaries) == nil else { summarizeMisses.remove(id); throw error }
            summarizeMisses.insert(id)
            if summarizeRetried.insert(id).inserted {
                let delay = summarizeRetryDelay
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                    guard let self, self.summarizeMisses.contains(id), !self.updatingMoments.contains(id) else { return }
                    try? await self.summarizeNow(day: day, timeZone: timeZone, id: id, end: end)
                }
            }
            throw error
        }
    }
    public var correctCanonical: ((MemoryActionScope,String,String) throws -> Void)?
    public var previewCanonicalDelete: ((MemoryActionScope) throws -> DeletionPreview)?
    /// gold r3-store (gate item 5): the same preview, prepared off the main thread (a day's assembly after a Correct held
    /// the main thread 280-520 ms). When set, the Forget alerts use it and ask once it lands; `previewCanonicalDelete`
    /// stays for callers that need the preview at once.
    public var previewCanonicalDeleteOffMain: ((MemoryActionScope) async throws -> DeletionPreview)?
    public var confirmCanonicalDelete: ((String) throws -> Void)?
    /// gold r3-store: the same Forget, committed off the main thread (its transaction checks the scope again: a day's
    /// assembly). When set, the Forget alerts use it; the moment goes once the commit lands, and a failure says so.
    public var confirmCanonicalDeleteOffMain: ((String) async throws -> Void)?
    public var cancelCanonicalDelete: ((String) throws -> Void)?
    /// Forget a time range (ForgetRange.swift): the preview and the commit, both off the main thread. nil (both)
    /// hides every "Forget a Time Range…".
    public var previewRangeDelete: ((MemoryActionScope) async throws -> DeletionPreview)?
    public var confirmRangeDelete: ((String) async throws -> Void)?
    public var canForgetRange: Bool { previewRangeDelete != nil && confirmRangeDelete != nil }
    /// The range sheet over the Today page (Moment ▸ Forget a Time Range…, a row's context menu).
    @Published public var forgetRangePresented = false
    private var loadGeneration = 0
    public var calendar: Calendar
    public init(items: [MemoryItem] = [], phase: ActivityPhase = .ready, calendar: Calendar = .current) {
        self.items = items; self.phase = phase; self.calendar = calendar
    }

    // MARK: Redesign state (plan §4.5). Additive: nothing below changes existing behaviour.

    /// Recall is summoned (⌘K / ⌘F). A non-empty `query` also presents it; see `recallVisible`.
    @Published public var recallPresented = false
    /// Day key ("yyyy-MM-dd") the Focus List shows; nil = today.
    @Published public var focusedDay: String?
    /// Click-to-reference (MomentReference): the moments a clicked line, span or "Show in Today" names; nil when none.
    @Published public var reference: MomentReference?
    public let referenceState = MomentReferenceState()
    /// Keyboard selection in the Focus List (an `ActivityNote.id`).
    @Published public var selectedMomentID: String?
    /// The one expanded Focus List row (an `ActivityNote.id`).
    @Published public var expandedMomentID: String?
    @Published public var summaries = SummaryAvailability(provider: .off, busy: false)
    /// fix/day-card: the failed summaries phase's one fixing button on the Today card ("Try Again", "Change Key",
    /// "Add Credits"); fix/setup-status wires it. nil shows the problem's line alone.
    public var fixSummaries: ((SummaryProblem) -> Void)?
    @Published public var exclusions = ExclusionSummary(alwaysPrivate: [], excludedByYou: [])
    /// What the selected moment allows, for the menu bar commands. Recall writes it while visible,
    /// the Focus List otherwise; the app menus read it for `.disabled` and titles.
    @Published public var commandContext = DaydreamCommandContext()
    public var recallVisible: Bool { recallPresented || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var canSearch: Bool { searchCanonicalQuery != nil || searchCanonical != nil }
    /// Preferred search entry point (app/site filters, paging); `searchCanonical` stays for older callers.
    public var searchCanonicalQuery: ((MemorySearchQuery) async throws -> MemorySearchResult)?
    /// Optional bounded canonical direct-match preview, before the ranked search.
    public var searchDirectPreview: ((MemorySearchQuery) async throws -> MemorySearchResult)?
    /// fix/search-1003: the person's own typed rows that match a query, opened on this Mac in the app's own process only
    /// (`MemoryStore.ownerTypedSearch`), with a short snippet per row held in Recall's view state only. nil: search never
    /// matches typed words.
    public var searchOwnerTyped: ((MemorySearchQuery) async throws -> OwnerTypedSearchResult)?
    /// Canonical revalidation of preview IDs with the final ranked page.
    public var reconcileSearchPreview: ((MemorySearchQuery,[String],MemorySearchResult) async throws -> MemorySearchResult)?
    /// summaries/v3 levels: DayDream's notes at every level (week, day, block, moment, line) that match a query
    /// (`MemoryStore.noteSearch`). nil: Recall shows no note rows.
    public var searchNotes: ((String) async throws -> [NoteHit])?
    /// "DayDream Preview": the one line the Today page shows over the day ("Preview: sample data, not recording").
    public var previewLine: String?
    /// fix/prompt-row: each AI-app moment's ask (moment ID → one line), opened on this Mac for the timeline only
    /// (`MemoryStore.momentPromptRows` then `ownerMomentPrompts`, off the main thread). nil: rows never show an ask.
    public var loadMomentPrompts: (([MomentPromptRequest]) async -> [String: String])?
    /// claude/day-review-1003 perf pass: a day's review facts with their newest clauses and quotes, from the store's cache
    /// (`MemoryStore.cachedDayReview`, no day read), off the main thread. nil from it: the day isn't cached, read it.
    public var loadDayReview: ((String) async -> DayReviewFacts?)?
    /// fix/show-all: a moment's typed rows for its detail ("Show All"): the sends by code for its list of actions (who only,
    /// never words), and what was typed, opened on this Mac for the detail view only (`MemoryStore.momentTypedRows` then
    /// `ownerMomentTyped`, off the main thread). The arguments are the moment's member action IDs and its own name. nil:
    /// the detail shows neither.
    public var loadMomentTyped: (([String], String) async -> MomentTypedLoad)?
    /// compose-send/v1 (owner 10/3): each typed action's compose line (`ComposeLine`, from `ComposeView` over its
    /// evidence: "Sent to Jamie", "Replied to Ada's post on X", the replied-to line), metadata only, never words. The
    /// argument is the typed action IDs of what the card or detail shows. nil: Messages rows are titled from their
    /// projection, other composers keep their action descriptions.
    public var loadComposeLines: (([String]) async -> [String: ComposeLine])?
    /// Selected timeline detail only, fresh owner source hydration off-main.
    public var loadOwnerSourcePreviews: (([String]) async -> [OwnerSourcePreview])?
    /// Metadata-only revalidation while that detail is visible; nil fails closed.
    public var ownerSourcePreviewRevision: ((Date?) async -> String?)?
    /// Activates the app with this bundle ID. nil hides "Open <App>".
    public var openApp: ((String) -> Void)?
    /// Adds the bundle to Excluded by you. The UI confirms first. nil hides the action.
    public var excludeApp: ((String) async throws -> Void)?
    /// Adds the site to the owner's "Sites not recorded" (Chrome page history). The UI confirms first.
    /// nil hides "Don't Record <site>…".
    public var excludeSite: ((String) async throws -> Void)?
    /// Opens a settings section by its legacy section string.
    public var openSettingsSection: ((String) -> Void)?
    /// The clock views and builders use; renders and checks pin it.
    public var now: () -> Date = Date.init
    /// Menu commands (plan §7), dispatched to whichever surface owns the key context.
    public let commands = PassthroughSubject<DaydreamCommand, Never>()
    public func send(_ command: DaydreamCommand) { commands.send(command) }
    public var days: [ActivityDay] {
        let filtered = items.filter { query.isEmpty || ($0.summary + $0.evidence.title + $0.evidence.app).localizedCaseInsensitiveContains(query) }
        let groups = Dictionary(grouping: filtered) { item in
            let date = timestamp(item.evidence.at) ?? .distantPast
            return activityKey(date)
        }.map { key, value -> ActivityGroup in
            let sorted = value.sorted { $0.evidence.at < $1.evidence.at }
            return ActivityGroup(id: String(key), day: calendar.startOfDay(for: timestamp(sorted[0].evidence.at) ?? .distantPast), items: sorted)
        }
        return Dictionary(grouping: groups, by: \.day).map { day, activities in
            ActivityDay(date:day, activities:activities.sorted { $0.start > $1.start })
        }.sorted { $0.date > $1.date }
    }
    private func activityKey(_ date: Date) -> String {
        // A ten-minute bucket may straddle local midnight in a quarter-hour
        // timezone. Day identity is part of the key, never inferred afterward.
        String(calendar.startOfDay(for:date).timeIntervalSince1970) + ":" + String(Int(date.timeIntervalSince1970 / 600))
    }
    public func select(_ app: ActivityApp, in activity: ActivityGroup) {
        loadGeneration += 1
        scope = AppScope(activityID:activity.id, day:activity.day, app:app)
        evidenceOpen = false; dayError = nil; loadedDayItems = nil; dayLoading = false
    }
    public func showDay() {
        scope?.wholeDay = true; evidenceOpen = false
        guard let loadDay, let selected = scope else { return }
        loadGeneration += 1
        let generation = loadGeneration
        dayLoading = true; dayError = nil; loadedDayItems = []
        Task { @MainActor in
            do {
                let result = try await loadDay(selected.day)
                guard scope == selected, generation == loadGeneration else { return }
                loadedDayItems = result; dayLoading = false
            } catch {
                guard scope == selected, generation == loadGeneration else { return }
                dayError = "Could not load the selected day. Try again."; dayLoading = false
            }
        }
    }
    public func showActivity() { loadGeneration += 1; scope?.wholeDay = false; evidenceOpen = false; dayLoading = false; dayError = nil }
    public func back() { loadGeneration += 1; scope = nil; evidenceOpen = false; dayLoading = false; dayError = nil }
    public var scopedItems: [MemoryItem] {
        guard let scope else { return [] }
        // Day scope intentionally ignores the timeline search filter.
        let candidates = scope.wholeDay ? loadedDayItems ?? items : items
        return candidates.filter { item in
            guard ActivityApp(item.evidence).id == scope.app.id, let date = timestamp(item.evidence.at), calendar.startOfDay(for:date) == scope.day else { return false }
            return scope.wholeDay || activityKey(date) == scope.activityID
        }.sorted { $0.evidence.at < $1.evidence.at }
    }
}

/// Menu commands sent through `ActivityBrowser.send(_:)`. The §4.5 cases plus `editCorrection`,
/// which the §7 Moment menu needs (`Edit Correction…`, no key equivalent).
public enum DaydreamCommand: Equatable, Sendable {
    case previousDay, nextDay, today, openRecall, find, toggleActions,
         openOriginal, copySummary, findRelated, showInToday, refresh, forget, exclude, editCorrection, excludeSite
}

/// The selection-dependent state the app menus need (enabled items and titles). The default
/// value is "nothing selected": every moment command disabled.
public struct DaydreamCommandContext: Equatable, Sendable {
    public var hasSelection: Bool
    public var hasSummary: Bool
    public var canOpenOriginal: Bool
    public var canForget: Bool
    /// Destination day for Go ▸ Show in …: "Today", "Monday", "Sep 14". nil without a selection.
    public var selectionDayTitle: String?
    public var recallVisible: Bool
    /// "Open Original" or "Open <App>" when one is available.
    public var openTitle: String?
    /// The app in "Exclude <App> from Recording…"; nil hides the item.
    public var excludeAppName: String?
    public var canFindRelated: Bool
    public var canEditCorrection: Bool
    /// The site in "Don't Record <site>…" (a Google Chrome moment's first site); nil hides the item.
    public var excludeSite: String?

    public init(hasSelection: Bool = false, hasSummary: Bool = false, canOpenOriginal: Bool = false, canForget: Bool = false,
                selectionDayTitle: String? = nil, recallVisible: Bool = false, openTitle: String? = nil,
                excludeAppName: String? = nil, canFindRelated: Bool = false, canEditCorrection: Bool = false,
                excludeSite: String? = nil) {
        self.hasSelection = hasSelection; self.hasSummary = hasSummary; self.canOpenOriginal = canOpenOriginal
        self.canForget = canForget; self.selectionDayTitle = selectionDayTitle; self.recallVisible = recallVisible
        self.openTitle = openTitle; self.excludeAppName = excludeAppName
        self.canFindRelated = canFindRelated; self.canEditCorrection = canEditCorrection
        self.excludeSite = excludeSite
    }
}

public enum ActivityWords {
    public static func day(_ date: Date, calendar: Calendar) -> String {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "EEEE, MMMM d"; return f.string(from:date)
    }
    public static func time(_ date: Date, calendar: Calendar) -> String {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "h:mm a"; return f.string(from:date)
    }
    public static func period(_ items: [MemoryItem], calendar: Calendar) -> String {
        let dates = items.compactMap { timestamp($0.evidence.at) }.sorted()
        guard let first = dates.first, let last = dates.last else { return "No observations in this scope" }
        let zone = calendar.timeZone.abbreviation(for:first) ?? calendar.timeZone.identifier
        return time(first,calendar:calendar) + (first == last ? "" : " to " + time(last,calendar:calendar)) + " " + zone
    }
    public static func narrative(_ items: [MemoryItem]) -> String {
        guard !items.isEmpty else { return "No activity for this app in the selected period." }
        let available = items.filter { !$0.generatedAt.isEmpty && $0.writer != "pending-local-writer" }
        guard !available.isEmpty else { return "Summary pending. The original observations are available separately; no outcome has been established." }
        var facts: [String] = []
        for item in available {
            let e = item.evidence, text = e.text.trimmingCharacters(in:.whitespacesAndNewlines)
            let fact: String
            // One plain sentence each (declutter), still claiming only what was seen: an ask isn't a result,
            // text on screen isn't authorship, an open window isn't reading, and an assistant's reply isn't checked.
            if e.kind == "conversation.assistant" {
                fact = "The assistant replied: \(text.prefixString(180)) (not verified)."
            } else if item.actionState == "planned" {
                fact = "Planned: \(text.prefixString(160))."
            } else if item.actionState == "requested" || e.kind == "conversation.user" {
                fact = "Asked \(e.app): \(text.prefixString(180))."
            } else if ["searched","viewed_search"].contains(item.actionState) {
                fact = item.summary
            } else if ["selection.changed", "terminal.value_changed"].contains(e.kind), !text.isEmpty {
                fact = "Text on screen in \(e.app): \(text.prefixString(160))."
            } else if !text.isEmpty {
                // Never "draft" (owner 10/05; most of them were sent): the words were typed, which is all that is known.
                fact = "Typed in \(e.app): \(text.prefixString(160))."
            } else {
                fact = "Had \(e.title.isEmpty ? "a window" : e.title) open in \(e.app)."
            }
            if !facts.contains(fact) { facts.append(fact) }
        }
        let selected = Array(facts.prefix(3))
        return selected.joined(separator:" ") + (facts.count > 3 ? " More supporting observations are available in the evidence view." : "")
    }
}

/// Fabricated render fixtures only. Never loaded into a user's store by the UI.
public enum ActivityUIFixtures {
    public static func fiveActions() -> [MemoryItem] {
        (0..<5).map { index in
            let at="2026-07-16T14:1\(index):00Z"
            let evidence=Evidence(id:"five-action-\(index)",at:at,kind:"window.changed",app:"Safari",bundle:"com.apple.Safari",title:"Sensor research",url:"https://example.org/?q=sensor%20experiment%20\(index+1)",text:"",synthetic:true)
            return IntentWriter.write(evidence,now:timestamp(at)!.addingTimeInterval(5))
        }
    }
    public static func items() -> [MemoryItem] {
        let rows: [(String,String,String,String,String,String,String)] = [
            ("garden-request","2026-07-16T14:12:00Z","conversation.user","Research assistant","invalid.fixture.assistant","Garden sensor prototype","How can I compare moisture sensors before choosing a design?"),
            ("garden-search","2026-07-16T14:14:00Z","window.changed","Safari","com.apple.Safari","Garden sensor prototype",""),
            ("garden-draft","2026-07-16T14:17:00Z","keyboard.text_input","TextEdit","com.apple.TextEdit","Garden sensor prototype","Compare response time and calibration drift in the bench notes"),
            ("recipe-request","2026-07-16T13:22:00Z","conversation.user","Research assistant","invalid.fixture.assistant","Planning a seasonal recipe collection","Please outline a recipe index organized by harvest month"),
            ("recipe-search","2026-07-16T13:25:00Z","window.changed","Safari","com.apple.Safari","Planning a seasonal recipe collection",""),
            ("report","2026-07-16T12:42:00Z","conversation.assistant","Research assistant","invalid.fixture.assistant","Reviewing a sample data parser","The parser checks passed in a local test"),
            ("pending","2026-07-15T16:12:00Z","keyboard.text_input","TextEdit","com.apple.TextEdit","Drafting a field checklist","Check the sensor before watering"),
            ("plan","2026-07-15T15:12:00Z","conversation.user","Research assistant","invalid.fixture.assistant","Planning the next bench experiment","I plan to compare two sensor positions")
        ]
        return rows.map { id, at, kind, app, bundle, title, text in
            let url = id == "garden-search" ? "https://example.org/?q=moisture%20sensor%20calibration" : id == "recipe-search" ? "https://example.org/?q=seasonal%20recipe%20index" : ""
            let e = Evidence(id:id,at:at,kind:kind,app:app,bundle:bundle,title:title,url:url,text:text,synthetic:true)
            var item = IntentWriter.write(e,now:timestamp(at)!.addingTimeInterval(10))
            if id == "pending" { item.generatedAt = ""; item.writer = "pending-local-writer" }
            return item
        }
    }
}
