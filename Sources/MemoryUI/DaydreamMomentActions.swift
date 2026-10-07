import Foundation
import MemoryCore

// One list of moment actions for every surface: the Focus List action bar and context menu,
// Recall's Actions menu, and (through `DaydreamCommandContext.make`) the Moment menu's
// enabled states and titles. Titles and keys follow the copy deck (§8.4) and keyboard table (§7).
// Pure: callers pass what the browser can do; nothing here performs an action.

public enum MomentActionID: String, CaseIterable, Sendable {
    case openMoment, openOriginal, openApp, showInToday, copySummary, findRelated, editCorrection, summarizeNow, forget, exclude
}

public struct MomentActionItem: Identifiable, Equatable, Sendable {
    public enum Group: String, Sendable { case open, moment, privacy }
    public let id: MomentActionID
    public let title: String
    /// SF Symbols 4 name (macOS 13).
    public let symbol: String
    /// Keycap text such as "⌘↩". Always nil in the privacy group.
    public let keys: String?
    public let enabled: Bool
    /// Why a disabled item is disabled (help text and VoiceOver hint).
    public let reason: String?
    public let destructive: Bool
    public let group: Group
    /// Help for an enabled item, e.g. "Opens github.com in your browser".
    public let help: String?

    public init(id: MomentActionID, title: String, symbol: String, keys: String? = nil, enabled: Bool = true,
                reason: String? = nil, destructive: Bool = false, group: Group = .moment, help: String? = nil) {
        self.id = id; self.title = title; self.symbol = symbol; self.keys = group == .privacy ? nil : keys
        self.enabled = enabled; self.reason = enabled ? nil : reason; self.destructive = destructive
        self.group = group; self.help = help
    }
}

public enum MomentActions {
    public enum Context: Equatable, Sendable {
        case focusList
        case focusListDetail
        case recall(dayIsToday: Bool)
    }

    /// What the browser can do right now. `init(browser:)` reads the closures that are set;
    /// renders and checks build it directly.
    public struct Capabilities: Equatable {
        public var reopen: Bool, openApp: Bool, excludeApp: Bool, generate: Bool, delete: Bool, correct: Bool
        /// "Don't Record <site>…" can run (Chrome page history).
        public var excludeSite: Bool
        public var summaries: SummaryAvailability
        public var exclusions: ExclusionSummary
        public var calendar: Calendar
        public var now: Date

        public init(reopen: Bool = false, openApp: Bool = false, excludeApp: Bool = false, generate: Bool = false,
                    delete: Bool = false, correct: Bool = false,
                    summaries: SummaryAvailability = SummaryAvailability(provider: .off, busy: false),
                    exclusions: ExclusionSummary = ExclusionSummary(alwaysPrivate: [], excludedByYou: []),
                    calendar: Calendar = .current, now: Date = Date(), excludeSite: Bool = false) {
            self.reopen = reopen; self.openApp = openApp; self.excludeApp = excludeApp; self.generate = generate
            self.delete = delete; self.correct = correct; self.summaries = summaries; self.exclusions = exclusions
            self.calendar = calendar; self.now = now; self.excludeSite = excludeSite
        }

        @MainActor public init(browser: ActivityBrowser) {
            self.init(reopen: browser.reopenCanonical != nil, openApp: browser.openApp != nil,
                      excludeApp: browser.excludeApp != nil, generate: browser.generateCanonicalNote != nil,
                      delete: browser.previewCanonicalDelete != nil && browser.confirmCanonicalDelete != nil,
                      correct: browser.correctCanonical != nil,
                      summaries: browser.summaries, exclusions: browser.exclusions,
                      calendar: browser.calendar, now: browser.now(), excludeSite: browser.excludeSite != nil)
        }
    }

    public static let partialDayReason = "Unavailable on a partial day"

    /// Items in menu order. Hidden actions are omitted; unavailable ones stay with a `reason`.
    public static func items(for m: MomentSlice, context: Context, browser caps: Capabilities) -> [MomentActionItem] {
        var items = [MomentActionItem]()
        let inRecall: Bool, dayIsToday: Bool
        switch context {
        case .focusList, .focusListDetail: inRecall = false; dayIsToday = false
        case .recall(let today): inRecall = true; dayIsToday = today
        }
        let partial = m.summary == .incomplete

        if inRecall {
            items.append(MomentActionItem(id: .openMoment, title: "Open Moment", symbol: "rectangle.stack", keys: "↩", group: .open))
        }
        if let original = openOriginal(for: m, caps: caps) { items.append(original) }
        if inRecall {
            let name = dayIsToday ? "Today" : DaydreamFormat.dayName(m.start, now: caps.now, calendar: caps.calendar)
            items.append(MomentActionItem(id: .showInToday, title: "Show in " + name, symbol: "calendar", keys: "⌘T", group: .open))
        }

        // fix/resummarize (owner, test 7): Summarize Now on any moment the writer can write, a written one too (its note
        // is written afresh from everything in the moment now), next to Copy Summary.
        // claude/notesfix-015 (owner 10/05, 0.1.6): no model writes a moment, so no menu offers Summarize Now
        // (`offersSummarizeNow`); Copy Summary stays.
        let summarize = Self.momentSummarizeNow && canSummarizeNow(m, caps: caps)
        if m.hasSummary || !summarize {
            items.append(MomentActionItem(id: .copySummary, title: "Copy Summary", symbol: "doc.on.doc",
                                          keys: inRecall ? "⇧⌘C" : "⌘C", enabled: m.hasSummary, reason: summaryReason(m)))
        }
        if summarize {
            items.append(MomentActionItem(id: .summarizeNow, title: "Summarize Now", symbol: "text.alignleft"))
        }
        if context == .focusList {
            let related = relatedFilter(for: m) != nil
            items.append(MomentActionItem(id: .findRelated, title: "Find Related Moments",
                                      symbol: "point.3.connected.trianglepath.dotted", keys: "⌘R",
                                      enabled: related, reason: "Nothing to match on"))
        }
        if caps.correct {
            items.append(MomentActionItem(id: .editCorrection, title: "Edit Correction…", symbol: "pencil",
                                          enabled: !partial, reason: partialDayReason))
        }

        if caps.delete {
            items.append(MomentActionItem(id: .forget, title: "Forget This Moment…", symbol: "trash",
                                          enabled: !partial, reason: partialDayReason, destructive: true, group: .privacy))
        }
        if caps.excludeApp, let bundle = m.primaryBundle, let app = m.primaryApp, !caps.exclusions.isExcluded(bundle) {
            items.append(MomentActionItem(id: .exclude, title: "Exclude \(app) from Recording…", symbol: "eye.slash", group: .privacy))
        }
        return items
    }

    /// "Don't Record <site>…" for a Google Chrome moment: one per site, at most five (the timeline's context
    /// menu). Empty unless the browser can save the change.
    public static func siteRequests(for m: MomentSlice, browser caps: Capabilities) -> [ExcludeSiteRequest] {
        caps.excludeSite ? ExcludeSiteRequest.requests(for: m) : []
    }

    /// The Recall filter Find Related Moments applies: the primary site for a web moment, else the
    /// primary app (bundle when known). nil when the moment has neither.
    public static func relatedFilter(for m: MomentSlice) -> RecallFilter? {
        if let site = m.sites.first(where: { !$0.isEmpty }) { return RecallFilter(kind: .site, value: site, label: site) }
        if let bundle = m.primaryBundle { return RecallFilter(kind: .app, value: bundle, label: m.primaryApp) }
        if let app = m.primaryApp ?? m.apps.first {
            return RecallFilter(kind: .app, value: app, label: DaydreamAppDirectory.looksLikeBundleID(app) ? nil : app)
        }
        return nil
    }

    private static func openOriginal(for m: MomentSlice, caps: Capabilities) -> MomentActionItem? {
        if caps.reopen, let host = m.sites.first(where: { !$0.isEmpty }) {
            return MomentActionItem(id: .openOriginal, title: "Open Original", symbol: "arrow.up.forward.square",
                                    keys: "⌘↩", group: .open, help: "Opens \(host) in your browser")
        }
        if caps.openApp, m.primaryBundle != nil, let app = m.primaryApp {
            return MomentActionItem(id: .openApp, title: "Open \(app)", symbol: "arrow.up.forward.app",
                                    keys: "⌘↩", group: .open, help: "Opens \(app)")
        }
        return nil
    }

    /// claude/notesfix-015 (owner 10/05, 0.1.6): false. A moment's lines are final; the day's summary is the only one.
    public static let momentSummarizeNow = false

    /// Whether Summarize Now can run for the moment: summaries on and not busy, and a moment the running writer can write
    /// (pending, or written: never one too long, on a partial day, or before cloud summaries were turned on).
    public static func canSummarizeNow(_ m: MomentSlice, caps: Capabilities) -> Bool {
        guard caps.generate, caps.summaries.canGenerate else { return false }
        switch m.summary {
        case .pending: return true
        case .ready:
            guard m.actionCount <= DaydreamSummaryLimit.actions else { return false }
            if caps.summaries.provider == .cloud, let from = caps.summaries.writesFrom, m.start < from { return false }
            return true
        case .summariesOff, .tooLong, .incomplete, .notWritten: return false
        }
    }

    private static func summaryReason(_ m: MomentSlice) -> String? {
        switch m.summary {
        case .ready: return nil
        case .pending: return nil
        case .summariesOff: return "Summaries are off"
        case .tooLong: return "Too long to summarize"
        case .incomplete: return "Partial day · summary unavailable"
        case .notWritten: return "No summary for this moment"
        }
    }
}

/// Find Related Moments as a Recall scope (L12): a site or an app, never a similarity claim.
public struct RecallFilter: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable { case app, site }
    public let kind: Kind
    /// The host for `.site`; the bundle ID for `.app` (the app's name only when no bundle is known).
    public let value: String
    /// What the scope chip names: the host, or the app's display name. nil when no name is known;
    /// the chip then names no app rather than showing a bundle ID.
    public let label: String?

    public init(kind: Kind, value: String, label: String?) {
        self.kind = kind; self.value = value
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = trimmed?.isEmpty == false ? trimmed : nil
    }

    /// The userInfo key for `value`: "app" or "site".
    public var key: String { kind.rawValue }
    /// Chip copy (§8.7): "From github.com" / "In Zed". nil without a label.
    public var chipTitle: String? {
        guard let label else { return nil }
        return kind == .site ? "From " + label : "In " + label
    }
    /// userInfo for `.daydreamRecallFilter`: `[key: value]`, plus `"label"` when a name is known.
    public var userInfo: [String: String] {
        var info = [key: value]
        if let label { info["label"] = label }
        return info
    }
    /// Reads a `.daydreamRecallFilter` userInfo; nil unless it names exactly one app or site.
    public init?(userInfo: [AnyHashable: Any]?) {
        guard let info = userInfo else { return nil }
        let found = Kind.allCases.compactMap { kind in (info[kind.rawValue] as? String).map { (kind, $0) } }
        guard found.count == 1, let only = found.first, !only.1.isEmpty else { return nil }
        self.init(kind: only.0, value: only.1, label: info["label"] as? String)
    }
}

extension Notification.Name {
    /// Posted by the Focus List's Find Related Moments; Recall applies the filter.
    /// userInfo: `RecallFilter.userInfo`, i.e. `["app": bundle or name]` or `["site": host]`, plus
    /// `"label"` (the name the chip shows) when known. Read it back with `RecallFilter(userInfo:)`.
    public static let daydreamRecallFilter = Notification.Name("DaydreamRecallFilter")
}

extension DaydreamCommandContext {
    /// The menu state for a selected moment (or none), from the same rules as `MomentActions.items`.
    public static func make(selection m: MomentSlice?, context: MomentActions.Context,
                            capabilities caps: MomentActions.Capabilities, recallVisible: Bool) -> DaydreamCommandContext {
        guard let m else { return DaydreamCommandContext(recallVisible: recallVisible) }
        let items = MomentActions.items(for: m, context: context, browser: caps)
        func enabled(_ id: MomentActionID) -> Bool { items.contains { $0.id == id && $0.enabled } }
        let open = items.first { ($0.id == .openOriginal || $0.id == .openApp) && $0.enabled }
        let dayTitle: String
        if case .recall(true) = context { dayTitle = "Today" } else { dayTitle = DaydreamFormat.dayName(m.start, now: caps.now, calendar: caps.calendar) }
        return DaydreamCommandContext(hasSelection: true, hasSummary: m.hasSummary, canOpenOriginal: open != nil,
                                      canForget: enabled(.forget), selectionDayTitle: dayTitle, recallVisible: recallVisible,
                                      openTitle: open?.title, excludeAppName: enabled(.exclude) ? m.primaryApp : nil,
                                      canFindRelated: enabled(.findRelated), canEditCorrection: enabled(.editCorrection),
                                      excludeSite: context == .focusList || context == .focusListDetail ? MomentActions.siteRequests(for: m, browser: caps).first?.site : nil)
    }
}
