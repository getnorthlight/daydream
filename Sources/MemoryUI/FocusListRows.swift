import SwiftUI
import MemoryCore

// The Focus List's sections and rows (spec §3.5–§3.7, plan §5 A1). Sections are Morning,
// Afternoon and Evening, newest first; rows are the kit's 52 pt `DDRow` in one raised card per
// section (white in light, so the kit's blue selection tint reads), separated by one-pixel hairlines
// inset 54 that take no layout space. Selection, hover and pending are fills only, so a row never
// changes height. A row is one VoiceOver element: `{title}, {app}, {range}, {spoken span}`, value
// `Expanded`/`Collapsed`, with the moment actions as named actions. The expanded row's header is the
// same element; its body (`FocusListExpanded`) holds sibling controls.

/// One day-part section: its moments in display order (newest first).
public struct FocusListSection: Identifiable, Equatable {
    public let part: DayPart
    public let moments: [MomentSlice]
    /// summaries/v3 levels: the block (L3) this section is, in place of a day part. nil: Morning / Afternoon / Evening.
    public let block: LevelBlockSlice?
    /// Which run of loose moments between blocks this part section is (0: the newest, or a day without blocks).
    public let run: Int
    public var id: String { block.map { "block:" + $0.id } ?? ("part:" + part.rawValue + (run == 0 ? "" : ":\(run)")) }
    public init(part: DayPart, moments: [MomentSlice], run: Int = 0) { self.part = part; self.moments = moments; self.block = nil; self.run = run }
    public init(block: LevelBlockSlice, part: DayPart, moments: [MomentSlice]) { self.part = part; self.moments = moments; self.block = block; self.run = 0 }
}

/// Pure layout and copy rules for the list (the check hooks live here).
public enum FocusListLayout {
    /// Sections newest first (Evening, Afternoon, Morning), each newest first, by the moment's start.
    public static func sections(_ moments: [MomentSlice], calendar: Calendar) -> [FocusListSection] {
        let newest = moments.sorted { ($0.start, $0.id) > ($1.start, $1.id) }
        return [DayPart.evening, .afternoon, .morning].compactMap { part in
            let rows = newest.filter { DaydreamFormat.dayPart($0.start, calendar: calendar) == part }
            return rows.isEmpty ? nil : FocusListSection(part: part, moments: rows)
        }
    }

    /// Every card in display order (the order ↑/↓ walk): each app card's anchor, its newest moment (owner 10/2: one card
    /// per app in a bracket).
    public static func order(_ sections: [FocusListSection]) -> [MomentSlice] {
        sections.flatMap { sessions($0.moments, sectionID: $0.id).compactMap { FocusAppCard.members($0).first } }
    }

    /// perf2-1005: the card each moment draws in, by the card's identity in its section's lazy rows (`TimelineSession.id`,
    /// what `FocusListRowsCard`'s `ForEach` is keyed by). A card far from view has no frame until the list scrolls near it,
    /// so a reveal scrolls to its card by this id first (a lazy stack finds a row by its `ForEach` id without building it).
    public static func cardIDs(_ sections: [FocusListSection]) -> [String: String] {
        var cards: [String: String] = [:]
        for section in sections {
            for session in sessions(section.moments, sectionID: section.id) {
                for m in session.members where cards[m.id] == nil { cards[m.id] = session.id }
                cards[session.id] = session.id
            }
        }
        return cards
    }

    /// One app per existing bracket is a display container only; each saved moment keeps its own identity and details.
    public static func sessions(_ moments: [MomentSlice], sectionID: String = "") -> [TimelineSession<MomentSlice>] {
        TimelineSessionGrouping.group(moments.map { m in
            TimelineSessionMember(id: m.id, dayKey: m.dayKey, start: m.start, end: m.end,
                channel: displayAppID(m) == nil ? nil : TimelineSessionChannel.recorded(sites: m.sites, bundles: m.bundles,
                                                        browserBundles: KitBrowsers.bundles), detail: m,
                conversation: recordedConversation(m),
                latestObserved: max(m.end, m.clusters.map(\.upperBound).max() ?? m.end),
                allowsGenericAlias: ["", "messages", "texts"].contains(m.subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
                displayAppID: displayAppID(m), displayAppName: appName(m))
        }, withinSection: true, sectionID: sectionID)
    }

    /// A single recorded app may fold visually; title/spinner text never supplies
    /// app identity, and mixed-app moments stay separate. Children remain moments.
    /// Owner 10/2: the card a moment joins in its bracket, by situation (`FocusAppCard.situation`): Messages and chat
    /// apps one card per app; a browser one per site; a terminal one per folder (else per app); any other app one per app.
    public static func displayAppID(_ m: MomentSlice) -> String? { FocusAppCard.situation(m) }

    /// Subject is the saved source name; model titles, live names and summary timestamps never
    /// participate in card identity or ordering. Reuse the existing recorded-title parser.
    public static func recordedConversation(_ m: MomentSlice) -> String? {
        guard Set(m.bundles) == ["com.apple.MobileSMS"], m.sites.isEmpty else { return nil }
        var subject = m.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !["", "messages", "texts", "new message"].contains(subject.lowercased()) else { return nil }
        for prefix in ["Texts with ", "Messages with "] where subject.hasPrefix(prefix) {
            subject = String(subject.dropFirst(prefix.count))
        }
        let entity = ThreadEntities.entity(app: "Messages", bundle: "com.apple.MobileSMS", site: "", title: subject)
        guard entity.kind == "texts", !entity.people.isEmpty else { return nil }
        // Preserve a whole group-chat identity rather than merging it with its first participant.
        return ThreadEntities.conversationName(subject)
    }

    /// The app a row names: the moment's primary app, else its only app. Never a bundle ID (typed-text
    /// evidence can name its app only by bundle ID).
    public static func appName(_ m: MomentSlice) -> String? {
        if let primary = m.primaryApp, !primary.isEmpty { return primary }
        guard m.apps.count == 1, let only = m.apps.first, !only.isEmpty, !DaydreamAppDirectory.looksLikeBundleID(only),
              !m.bundles.contains(only) else { return nil }
        return only
    }

    /// Row VoiceOver label: `{title}, {app}, {range}, {spoken span}`, e.g.
    /// "Sketching main window layouts, Freeform, 2:30 to 3:20 PM, 50 minutes".
    public static func rowAccessibilityLabel(_ m: MomentSlice, timeZone: TimeZone) -> String {
        var parts = [MomentSubtitle.rowTitle(m)]
        if let app = appName(m) { parts.append(app) }
        parts.append(DaydreamFormat.spokenRange(m.start, m.end, timeZone))
        parts.append(DaydreamFormat.spokenDuration(from: m.start, to: m.end))
        return parts.joined(separator: ", ")
    }

    public static func rowAccessibilityValue(expanded: Bool) -> String { expanded ? "Expanded" : "Collapsed" }

    /// The expanded header's subtitle: "2:30–3:20 PM" (the action count was internal).
    /// A card covering several apps names them all after the range: "5:14–5:22 PM · Terminal, Ghostty" (owner 10/2).
    public static func expandedMeta(_ m: MomentSlice, timeZone: TimeZone, updating: Bool = false) -> String {
        let apps = appNames(m)
        return DaydreamFormat.range(m.start, m.end, timeZone) + (apps.count > 1 ? " · " + apps.joined(separator: ", ") : "")
            + (updating ? " · " + MomentSubtitle.updating : "")
    }
    /// The moment's apps by name, its primary app first; never a bundle ID.
    public static func appNames(_ m: MomentSlice) -> [String] {
        let named = m.apps.filter { !$0.isEmpty && !DaydreamAppDirectory.looksLikeBundleID($0) && !m.bundles.contains($0) }
        guard let primary = m.primaryApp, named.contains(primary) else { return named }
        return [primary] + named.filter { $0 != primary }
    }

    /// The row's chip slot, as `DDRow(moment:)` fills it: the primary site, or the second app. Never a status.
    @MainActor static func chip(_ m: MomentSlice) -> AnyView? {
        if let site = m.sites.first(where: { !$0.isEmpty }) { return AnyView(SiteChip(site: site)) }
        if let second = m.bundles.first(where: { $0 != (m.primaryBundle ?? m.bundles.first) }) {
            return AnyView(AppChip(bundle: second, name: KitAppNames.name(for: second) ?? ""))
        }
        return nil
    }

    /// Copy Summary's text: the title, then the note's bullets, then the person's corrections prefixed
    /// `Correction:`. nil when the moment has no summary and no correction (nothing to copy).
    public static func copyText(_ m: MomentSlice) -> String? {
        guard m.hasSummary else { return nil }
        var lines = [MomentSubtitle.rowTitle(m)]
        if m.summary.isReady { lines += m.bullets.filter { !$0.correction }.map { "• " + $0.text } }
        lines += m.bullets.filter(\.correction).map { "Correction: " + $0.text }
        return lines.joined(separator: "\n")
    }

    /// The moment whose start is closest to `date` (a refreshed day re-selects the nearest row).
    public static func nearest(to date: Date, in moments: [MomentSlice]) -> MomentSlice? {
        moments.min { (abs($0.start.timeIntervalSince(date)), $0.id) < (abs($1.start.timeIntervalSince(date)), $1.id) }
    }
}

/// What rows need from their owner.
struct FocusListRowContext {
    var timeZone: TimeZone
    var selectedID: String?
    var expandedID: String?
    /// < 760 pt: the chip slot narrows to 150.
    var narrow: Bool
    /// < 600 pt: the chip slot is hidden.
    var compact: Bool
    var items: (MomentSlice) -> [MomentActionItem]
    var toggle: (MomentSlice) -> Void
    var perform: (MomentActionID, MomentSlice) -> Void
    /// The open card's body: its anchor (newest member) and every member, newest first.
    var expandedBody: (MomentSlice, [MomentSlice]) -> AnyView
    /// "Don't Record <site>…" items for a Google Chrome moment (context menu only).
    var siteItems: (MomentSlice) -> [ExcludeSiteRequest] = { _ in [] }
    var excludeSite: (ExcludeSiteRequest) -> Void = { _ in }
    /// "Forget a Time Range…" at the end of every row's context menu; nil hides it.
    var forgetRange: (() -> Void)? = nil
    /// The moment lit on the day card's ribbon (the pointer is on its span): its row shows the hover fill.
    var linked: String? = nil
    /// A row's hover, so the day card's ribbon can light the moment's span (nil when the pointer leaves).
    var onHover: (String?) -> Void = { _ in }
    /// What `items` and `siteItems` read (fix/scroll-perf): with it a row redraws only when its own inputs change
    /// (`FocusListRowItem ==`). nil: the row redraws with the list, as before.
    var caps: MomentActions.Capabilities? = nil
    /// fix/resummarize: moments whose Summarize Now is running.
    var updating: Set<String> = []
}

/// One section's card: the optional live-pause row, then the rows with inset hairlines.
struct FocusListRowsCard: View {
    let moments: [MomentSlice]
    let paused: AnyView?
    let context: FocusListRowContext
    var sectionID: String = ""
    @State private var layout = FocusListSessionCache()

    var body: some View {
        // perf2-1005 (owner 10/4, "clicking cards is glitchy"): lazy rows. Every card of a 276-moment day was a live view,
        // and a click (select + expand) re-ran SwiftUI's update over all of them (~120 ms a click); now only the cards near
        // the visible area exist. Collapsed rows are a fixed 52 pt, so the unbuilt rows' estimated height is exact.
        LazyVStack(spacing: 0) {
            if let paused { paused.padding(.horizontal, 6).padding(.vertical, 4) }
            let sessions = layout.sessions(moments, sectionID: sectionID)
            ForEach(Array(sessions.enumerated()), id: \.element.id) { i, session in
                // Owner 10/2: one card per app in a bracket, a single moment's card included.
                FocusAppCardItem(session: session, context: context).equatable()
                .overlay(alignment: .bottom) {
                    if i + 1 < sessions.count {
                        let adjacentIDs = session.members.map(\.id) + sessions[i + 1].members.map(\.id)
                        if !adjacentIDs.contains(where: { $0 == context.expandedID || $0 == context.selectedID }) {
                            FocusRowSeparator()
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .daydreamCard(radius: DaydreamStyle.cardRadius, fill: FocusListRowsCard.fill, shadow: false)
        .accessibilityElement(children: .contain)
    }

    /// The rows' card: raised (white / white .24), so the kit's selection tint shows against it.
    static let fill = DaydreamStyle.raised
}

/// Metadata parsing and group sorting belong to saved input changes, not every hover redraw.
/// The cached plan holds no MomentSlice payload: current summary/details always flow into the rows.
private final class FocusListSessionCache {
    private struct Source: Equatable {
        let subject: String, title: String
        let bundles: [String], sites: [String]
        let apps: [String], primaryApp: String?
    }
    private struct Metadata {
        let source: Source
        let channel: TimelineSessionChannel?
        let conversation: String?
        let alias: Bool
        let displayAppID: String?, displayAppName: String?
    }
    private var metadata: [String: Metadata] = [:]
    private let layout = TimelineSessionLayoutCache<MomentSlice>()
    private(set) var metadataBuilds = 0
    var layoutBuilds: Int { layout.builds }
    func sessions(_ moments: [MomentSlice], sectionID: String) -> [TimelineSession<MomentSlice>] {
        let members = moments.map { moment -> TimelineSessionMember<MomentSlice> in
            let source = Source(subject: moment.subject, title: moment.title, bundles: moment.bundles, sites: moment.sites,
                                apps: moment.apps, primaryApp: moment.primaryApp)
            let value: Metadata
            if let known = metadata[moment.id], known.source == source { value = known }
            else {
                value = Metadata(source: source,
                    channel: FocusListLayout.displayAppID(moment) == nil ? nil : TimelineSessionChannel.recorded(sites: moment.sites, bundles: moment.bundles, browserBundles: KitBrowsers.bundles),
                    conversation: FocusListLayout.recordedConversation(moment),
                    alias: ["", "messages", "texts"].contains(moment.subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
                    displayAppID: FocusListLayout.displayAppID(moment), displayAppName: FocusListLayout.appName(moment))
                metadata[moment.id] = value
                metadataBuilds += 1
            }
            return TimelineSessionMember(id: moment.id, dayKey: moment.dayKey, start: moment.start, end: moment.end,
                channel: value.channel, detail: moment, conversation: value.conversation,
                latestObserved: max(moment.end, moment.clusters.map(\.upperBound).max() ?? moment.end), allowsGenericAlias: value.alias,
                displayAppID: value.displayAppID, displayAppName: value.displayAppName)
        }
        if metadata.count > moments.count {
            let present = Set(moments.map(\.id)); metadata = metadata.filter { present.contains($0.key) }
        }
        return layout.sessions(members, sectionID: sectionID)
    }
}

/// A row separator: one device pixel, inset 54 (the title column) and 14, drawn over the row's bottom
/// edge so rows stay exactly 52 pt and never land on half points.
struct FocusRowSeparator: View {
    @Environment(\.displayScale) private var scale
    var body: some View {
        Rectangle().fill(DaydreamStyle.hairline).frame(height: 1 / max(scale, 1))
            .padding(.leading, 54).padding(.trailing, 14)
            .accessibilityHidden(true)
    }
}

/// Each row's frame in the list's document (the scroll content's `space`), for scroll anchoring.
struct FocusRowFrames: PreferenceKey {
    static let space = "canonical-history-content"
    /// The list content's own entry (its size), next to the rows' (no moment id starts with a NUL).
    static let contentKey = "\u{0}content"
    /// The failed-action notice (above the list, or in an expanded card), so it can be scrolled into view.
    static let noticeKey = "\u{0}notice"
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The 52 pt row button. A click selects the moment and expands or collapses it. Expanded, its
/// subtitle becomes the moment's range and action count (`2:30–3:20 PM · 17 actions`, home-C).
struct FocusListRow: View {
    let moment: MomentSlice
    let context: FocusListRowContext
    let expanded: Bool
    @Environment(\.daydreamStatic) private var isStatic
    @State private var hovered = false

    var body: some View {
        let items = context.items(moment)
        let selected = context.selectedID == moment.id
        let updating = context.updating.contains(moment.id)
        return Button { context.toggle(moment) } label: {
            if expanded {
                let meta = FocusListLayout.expandedMeta(moment, timeZone: context.timeZone, updating: updating)
                DDRow(icon: MomentIcon(moment: moment, size: 32, ring: FocusListRowsCard.fill),
                      title: MomentSubtitle.rowTitle(moment),
                      // fix/show-all (owner): no site or app pill on the open card: its icon and its Windows and pages say it.
                      // The pill's slot stays (empty), so the title keeps its width and nothing moves on expand.
                      subtitle: Text(meta).monospacedDigit(), subtitleText: meta, chip: Optional<AnyView>.none,
                      start: moment.start, end: moment.end, timeZone: context.timeZone,
                      chipWidth: context.narrow ? 150 : 176, showsChip: !context.compact)
                    // The subtitle is the range, so the start time beside it would say it twice.
                    .hidingTime()
            } else {
                DDRow(moment: moment, timeZone: context.timeZone, selected: selected, hovered: hovered || context.linked == moment.id,
                      chipWidth: context.narrow ? 150 : 176, showsChip: !context.compact, ring: FocusListRowsCard.fill, updating: updating)
            }
        }
        .buttonStyle(FocusRowButtonStyle())
        // Renders and checks draw no hover from wherever the pointer happens to be.
        .onHover { inside in
            hovered = isStatic ? false : inside
            if !isStatic { context.onHover(inside ? moment.id : nil) }
        }
        .contextMenu {
            MomentContextMenu(items: items, sites: context.siteItems(moment), excludeSite: context.excludeSite) { context.perform($0, moment) }
            // Forget a time range (threads line): after the moment's own items, as before the shared menu.
            if let forgetRange = context.forgetRange {
                Button(role: .destructive, action: forgetRange) { Label(ForgetRangeText.menuTitle, systemImage: "clock.arrow.circlepath") }
            }
        }
        .accessibilityIdentifier("focus-list-row")
        .accessibilityLabel(FocusListLayout.rowAccessibilityLabel(moment, timeZone: context.timeZone))
        .accessibilityValue(FocusListLayout.rowAccessibilityValue(expanded: expanded))
        .accessibilityHint(expanded ? "Collapses the moment" : "Expands the moment")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityCustomContent("Summary", MomentSubtitle.text(for: moment))
        .modifier(FocusRowActions(moment: moment, items: items, perform: context.perform))
    }
}

/// VoiceOver named actions for a row (amendments A1): Open Original, Copy Summary, Find Related
/// Moments and Forget This Moment…, each only when available.
struct FocusRowActions: ViewModifier {
    let moment: MomentSlice
    let items: [MomentActionItem]
    let perform: (MomentActionID, MomentSlice) -> Void

    private func enabled(_ ids: [MomentActionID]) -> MomentActionItem? {
        items.first { ids.contains($0.id) && $0.enabled }
    }

    func body(content: Content) -> some View {
        let open = enabled([.openOriginal, .openApp]), copy = enabled([.copySummary]), related = enabled([.findRelated]), forget = enabled([.forget])
        return content.accessibilityActions {
            if let open { Button(open.title) { perform(open.id, moment) } }
            if copy != nil { Button("Copy Summary") { perform(.copySummary, moment) } }
            if related != nil { Button("Find Related Moments") { perform(.findRelated, moment) } }
            if forget != nil { Button("Forget This Moment…") { perform(.forget, moment) } }
        }
    }
}

/// Plain row: the whole 52 pt row is the hit area; `DDRow` draws selection and hover.
struct FocusRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

// MARK: - Loading

// MARK: - App cards (owner 10/2)

/// One app's card in a bracket: the row ("Texts", its range, the newest summary line, a chevron), and open, the same
/// header over `FocusListExpanded` with every member. Each member keeps its own ID; the card answers for all of them
/// (selection, references, scroll frames).
struct FocusAppCardItem: View {
    let session: TimelineSession<MomentSlice>
    let context: FocusListRowContext
    @Environment(\.daydreamReferenced) private var referenced
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let members = FocusAppCard.members(session)
        let anchor = members[0]
        let open = members.first { $0.id == context.expandedID }
        let isReferenced = referenced.map { ids in members.contains { ids.contains($0.id) } } ?? false
        Group {
            if let open {
                VStack(alignment: .leading, spacing: 0) {
                    FocusAppCardHeader(members: members, target: open, context: context, expanded: true)
                        .padding(.horizontal, -6)
                    context.expandedBody(anchor, members)
                        .contextMenu {
                            MomentContextMenu(items: context.items(anchor), sites: context.siteItems(anchor),
                                              excludeSite: context.excludeSite) { context.perform($0, anchor) }
                        }
                }
                .background(DaydreamStyle.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: DaydreamStyle.expandedStroke))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                .padding(.horizontal, 6).padding(.vertical, 6)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.99, anchor: .top)))
            } else {
                FocusAppCardHeader(members: members, target: anchor, context: context, expanded: false)
            }
        }
        .background(isReferenced ? ReferenceStyle.tint : Color.clear)
        .opacity(referenced.map { _ in isReferenced ? 1 : ReferenceStyle.dimmed } ?? 1)
        // Every member (and the card) scrolls to this frame.
        .background(GeometryReader { g in
            let frame = g.frame(in: .named(FocusRowFrames.space))
            Color.clear.preference(key: FocusRowFrames.self,
                                   value: Dictionary(([session.id] + members.map(\.id)).map { ($0, frame) }, uniquingKeysWith: { a, _ in a }))
        })
        .id(anchor.id)
    }
}

/// perf (owner 10/2, after claude/perf-1002): a card redraws only when what it draws changes. A hover is the card's own
/// `@State` (the header's), and a hover elsewhere, a selection, a ribbon light or a summaries flip redraws only the cards
/// it touches, not the day. The closures a card keeps read the list's live state; what they captured by value
/// (`caps`, `narrow`) is compared.
extension FocusAppCardItem: Equatable {
    static func == (a: Self, b: Self) -> Bool {
        let ids = a.session.members.map(\.id), x = a.context, y = b.context
        guard ids == b.session.members.map(\.id), a.session.id == b.session.id else { return false }
        func touches(_ id: String?) -> Bool { id.map(ids.contains) ?? false }
        // An open card always redraws (its body reads live loads); a card that opens or closes redraws.
        guard !touches(x.expandedID), !touches(y.expandedID),
              touches(x.selectedID) == touches(y.selectedID), x.selectedID == y.selectedID || !touches(x.selectedID),
              touches(x.linked) == touches(y.linked),
              x.narrow == y.narrow, x.compact == y.compact, x.timeZone == y.timeZone,
              (x.forgetRange == nil) == (y.forgetRange == nil),
              ids.map(x.updating.contains) == ids.map(y.updating.contains),
              var xc = x.caps, let yc = y.caps else { return false }
        // The clock only names the day; summaries only say whether a note can be written now.
        if xc.calendar.isDate(xc.now, inSameDayAs: yc.now) { xc.now = yc.now }
        if xc.summaries.canGenerate == yc.summaries.canGenerate { xc.summaries = yc.summaries }
        return xc == yc && a.session.members.map(\.detail) == b.session.members.map(\.detail)
    }
}

/// The card's 52 pt row: the icon, the title with the newest summary line under it (not while open: the summary is
/// below), and the time range on the right. No chevron.
struct FocusAppCardHeader: View {
    let members: [MomentSlice]
    /// The member a click toggles: the open one, else the anchor.
    let target: MomentSlice
    let context: FocusListRowContext
    let expanded: Bool
    @Environment(\.daydreamStatic) private var isStatic
    @State private var hovered = false

    var body: some View {
        let anchor = members[0]
        let ids = Set(members.map(\.id))
        let selected = context.selectedID.map(ids.contains) ?? false
        let lit = hovered || (context.linked.map(ids.contains) ?? false)
        let updating = members.contains { context.updating.contains($0.id) }
        let range = FocusAppCard.latestTime(members, timeZone: context.timeZone) + (updating ? " · " + MomentSubtitle.updating : "")
        // claude/perf3-1005: made once per draw (the accessibility label below used to make it again).
        let collapsed = FocusAppCard.collapsedLine(members)
        let line = expanded ? "" : collapsed
        let items = context.items(anchor)
        return Button { context.toggle(target) } label: {
            // Owner 10/2 (final): the icon, the title with the newest summary line under it, the range on the right.
            HStack(spacing: 10) {
                icon(anchor, count: members.count).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(FocusAppCard.title(members)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    // claude/livefix-1004: the newest member's ask draws as `PromptLine` (cut before its closing quote).
                    if let ask = expanded ? nil : MomentSubtitle.shownPrompt(anchor) {
                        PromptLine(prompt: ask)
                    } else if !line.isEmpty {
                        Text(line).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(range).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    .fixedSize()
            }
            .padding(.leading, 12).padding(.trailing, 14)
            .frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? DaydreamStyle.panelSelection : Color.primary.opacity(lit ? 0.035 : 0))
                .padding(.horizontal, 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(FocusRowButtonStyle())
        .onHover { inside in
            hovered = isStatic ? false : inside
            if !isStatic { context.onHover(inside ? anchor.id : nil) }
        }
        .contextMenu {
            MomentContextMenu(items: items, sites: context.siteItems(anchor), excludeSite: context.excludeSite) { context.perform($0, anchor) }
            if let forgetRange = context.forgetRange {
                Button(role: .destructive, action: forgetRange) { Label(ForgetRangeText.menuTitle, systemImage: "clock.arrow.circlepath") }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("focus-list-row")
        .accessibilityLabel(FocusAppCard.accessibilityLabel(members, timeZone: context.timeZone, line: collapsed))
        .accessibilityValue(FocusListLayout.rowAccessibilityValue(expanded: expanded))
        .accessibilityHint(expanded ? "Collapses the card" : "Expands the card")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .modifier(FocusRowActions(moment: anchor, items: items, perform: context.perform))
    }

    /// One moment: its own icon (a second app stacks on it). Several moments of one app: the app's icon.
    @ViewBuilder private func icon(_ anchor: MomentSlice, count: Int) -> some View {
        if let site = FocusAppCard.site(anchor) {
            WebMonogramTile(domain: site, browserBundle: anchor.primaryBundle ?? anchor.bundles.first, size: 32)
        } else if count > 1, let bundle = anchor.primaryBundle ?? anchor.bundles.first {
            AppIcon(bundle: bundle, name: FocusAppCard.title(members), size: 32)
        } else {
            MomentIcon(moment: anchor, size: 32, ring: FocusListRowsCard.fill)
        }
    }
}
