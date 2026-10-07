import SwiftUI
import AppKit
import MemoryCore

// DayDream visual kit: moments (spec §3.6, §3.7, §3.10, §4.6, §10.4, §10.6, §10.13). The fixed-slot
// row, day chips, the detail body shared by the Focus List and Recall, the Actions menu, the forget
// and exclude confirmations, and the original-unavailable banner. Lifted from `home/optionC.swift`
// and `find/optionA.swift` with fixtures removed; every value comes from the caller.

// MARK: - Subtitle

/// The moment subtitle (fix/day-card), in order: the note's first line that says something, sends first (the note shown
/// may be the previous one while a newer one is written); else what the moment sent by code, who only ("Texted Q7",
/// "Asked Claude"); else its focused time ("~38 min"). Never a status ("Summary pending", "Partial day"): the day card
/// says the summaries phase once. A person's correction is never the subtitle.
public struct MomentSubtitle: View {
    let moment: MomentSlice
    public init(moment: MomentSlice) { self.moment = moment }

    static func actions(_ n: Int) -> String { DaydreamFormat.count(n) + (n == 1 ? " action" : " actions") }

    /// A Focus List row's subtitle (the same words: there is no pending state to leave out any more), except that an
    /// AI-app moment's ask stands in, in quotes, until the note has a line (fix/prompt-row: `shownPrompt`).
    public static func rowText(for m: MomentSlice) -> String {
        promptText(m) ?? text(for: m)
    }
    /// The shown prompt as one line: an ask in quotes, or (owner 10/6) an X send as the expanded card says it,
    /// "Replied “…” on X." (`MomentSlice.promptLead`); nil when no prompt is shown.
    public static func promptText(_ m: MomentSlice, asks: Int? = nil) -> String? {
        shownPrompt(m).map { PromptLine.text($0, lead: m.promptLead, asks: asks ?? m.promptAsks) }
    }

    /// fix/prompt-row: the ask a row shows (`MomentSlice.prompt`, one line), or nil. The note's line wins once there is
    /// one: the summary is the finished note, it says what the ask was for ("Asked Claude how to fix the export
    /// crash") where the ask's first words often don't ("ok now do the same for"), and it keeps the row from flipping
    /// back to raw words while a newer note is written. Before that (no note, summaries off, a note with nothing left
    /// to say) the ask beats "Asked ChatGPT" and "~10 min".
    public static func shownPrompt(_ m: MomentSlice) -> String? {
        guard let prompt = m.prompt, !prompt.isEmpty else { return nil }
        // claude/int-017 (owner 10/06): an AI app's collapsed row says what was asked, over code's note ("Used the send
        // key in ChatGPT." read as the row); a model's note still wins, and X rows and every other row are as in 0.1.6.
        if m.summary.isReady, !(m.byCode && m.promptLead == nil), let line = LevelWords.intentLine(m.bullets) ?? m.firstBullet, !line.isEmpty { return nil }
        return prompt
    }

    /// fix/resummarize: while Summarize Now runs for a moment, its row's line (the summary line dimmed, then this).
    /// Merged with fix/prompt-row: the line is `rowText(for:)`, so an ask shown in quotes stays, dimmed, before it.
    public static let updating = "Updating\u{2026}"
    public static func rowText(for m: MomentSlice, updating: Bool) -> String {
        let line = rowText(for: m)
        guard updating else { return line }
        return line.isEmpty ? Self.updating : line + " · " + Self.updating
    }

    /// The subtitle as plain text (VoiceOver, checks); empty when the moment has none.
    public static func text(for m: MomentSlice) -> String {
        // summaries/v3: the intent line (the sent or asked line first, then a drafted one, then the first line).
        // fix/sx-all round 1: one sentence, no closing period ("Texted Sam about the churn chart"), as a subtitle reads.
        // fix/sx-all round 2: never the row's own title again ("Texts with Sam" under "Texts with Sam"): the next line that
        // says something else, else the focused time.
        let title = rowTitle(m)
        func fresh(_ line: String) -> Bool { !line.isEmpty && same(line, title) == false }
        if m.summary.isReady {
            let own = m.bullets.filter { !$0.correction }.map(\.text)
            let ordered = [LevelWords.intentLine(m.bullets), m.firstBullet].compactMap { $0 } + own
            if let line = ordered.first(where: fresh) { return MenuBarMenu.sentence(line) }
        }
        if let send = m.lines.first(where: fresh) { return MenuBarMenu.sentence(send) }
        if let live = m.live, live.seconds > 0 { return live.duration }
        // fix/sx-all: a past day with its day note has no live threads; a note whose every line was filler still says
        // how long the moment was (start to end), never a blank row. Merged with fix/resummarize ("Under a minute." was
        // the owner's x.com moment's only line): the live rows' "~1 min", never "Under a minute".
        if m.summary.isReady {
            return LiveMoment(label: "", kind: "", sends: [], seconds: Int(m.span.rounded()), idle: false, communication: false).duration
        }
        return ""
    }

    /// The title a moment row shows (`DDRow(moment:)`).
    /// Never a withheld title or a terminal's raw window title (`CardTitle.safe`).
    static func rowTitle(_ m: MomentSlice) -> String { CardTitle.safe(m.title.isEmpty ? TitleClean.clean(m.subject) : m.title, moment: m) }
    /// Two lines that read the same: case, spacing and a closing period aside. "In WhatsApp" under "WhatsApp" (code's line
    /// for an app where nothing more can be said) reads the same too: the time stands in.
    public static func same(_ a: String, _ b: String) -> Bool {
        func key(_ s: String) -> String {
            var t = s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            while let last = t.last, ".!".contains(last) { t.removeLast() }
            if t.hasPrefix("in ") { t.removeFirst(3) }
            return t
        }
        return key(a) == key(b)
    }

    public var body: some View {
        Text(Self.text(for: m))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
    private var m: MomentSlice { moment }
}

/// fix/prompt-row: an ask on one line in quotes. The words are cut with "…" at the row's width and the closing quote
/// stays: the line never wraps and never runs past its column (the quotes keep their size, the words take the rest).
public struct PromptLine: View {
    static let open = "\u{201C}", close = "\u{201D}"
    let prompt: String
    /// Owner 10/6: an X send's lead ("Posted", "Replied"): "Replied “…” on X.", the words cut as an ask's are.
    let lead: String?
    /// claude/int-017 (owner 10/06): an AI ask code saw sent, and how many the card sent (`MomentSlice.promptAsks`).
    let asks: Int?
    public init(prompt: String, lead: String? = nil, asks: Int? = nil) { self.prompt = prompt; self.lead = lead; self.asks = asks }
    /// The line as text: “…”, "Replied “…” on X.", or (claude/int-017) "Asked “…”" / "Asked 5 questions · latest “…”".
    public static func text(_ prompt: String, lead: String?, asks: Int? = nil) -> String {
        if let lead { return lead + " " + open + prompt + close + MomentPromptText.xTail }
        let words = lead == nil && asks != nil ? FocusAppCard.shortQuoteWords(prompt) : prompt
        return askLead(asks) + open + words + close
    }
    /// "", "Asked ", or "Asked 5 questions · latest ".
    public static func askLead(_ asks: Int?) -> String {
        guard let asks else { return "" }
        return asks > 1 ? "Asked \(asks) questions \u{00B7} latest " : "Asked "
    }
    public var body: some View {
        HStack(spacing: 0) {
            if let lead { Text(lead + " ").fixedSize() }
            else if asks != nil { Text(Self.askLead(asks)).fixedSize() }
            Text(Self.open).fixedSize()
            Text(lead == nil && asks != nil ? FocusAppCard.shortQuoteWords(prompt) : prompt).lineLimit(1).truncationMode(.tail)
            Text(Self.close + (lead == nil ? "" : MomentPromptText.xTail)).fixedSize()
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.text(prompt, lead: lead))
    }
}

// MARK: - Row

/// A 52 pt moment row with fixed accessory slots so chips and times line up on every row: chip (176,
/// or 150 narrow; trailing-aligned), start time 60. No duration pill: the start time and the expanded
/// range say when. Selection, hover and pending are fills only: the height never changes.
public struct DDRow<Icon: View, Chip: View>: View {
    let icon: Icon
    let title: String
    let subtitle: AnyView
    let subtitleText: String
    let chip: Chip?
    let start: Date
    let end: Date
    let timeZone: TimeZone
    let selected: Bool
    let hovered: Bool
    let chipWidth: CGFloat
    let showsChip: Bool
    /// False when the row has no subtitle (the title then sits alone, centred).
    var showsSubtitle = true
    /// False in an expanded moment's header, whose subtitle is already its time range: the 60 pt time column
    /// stays, empty, so the chip lines up with the rows around it.
    var showsTime = true

    /// The row without its start time (`showsTime`).
    public func hidingTime() -> Self { var copy = self; copy.showsTime = false; return copy }

    /// The keyboard-selection fill: the selected-row blue of the Recall panel (#DAEAFE / dark #263D5E), visible on the
    /// white `raised` card the Focus List rows sit on, where `DaydreamStyle.selected` (#ECF2FA) reads as white (W2-6).
    static var selectionFill: Color { DaydreamStyle.panelSelection }

    public init(icon: Icon, title: String, subtitle: Text, subtitleText: String? = nil, chip: Chip?, start: Date, end: Date,
                timeZone: TimeZone, selected: Bool = false, hovered: Bool = false, chipWidth: CGFloat = 176, showsChip: Bool = true) {
        self.init(icon: icon, title: title, subtitleView: AnyView(subtitle.font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)),
                  subtitleText: subtitleText, chip: chip, start: start, end: end, timeZone: timeZone, selected: selected,
                  hovered: hovered, chipWidth: chipWidth, showsChip: showsChip)
    }

    /// Any one-line subtitle view (fix/prompt-row: `PromptLine`).
    init(icon: Icon, title: String, subtitleView: AnyView, subtitleText: String?, chip: Chip?, start: Date, end: Date,
         timeZone: TimeZone, selected: Bool, hovered: Bool, chipWidth: CGFloat, showsChip: Bool) {
        self.icon = icon; self.title = title
        self.subtitle = subtitleView
        self.subtitleText = subtitleText ?? ""
        self.chip = chip; self.start = start; self.end = end; self.timeZone = timeZone
        self.selected = selected; self.hovered = hovered; self.chipWidth = chipWidth; self.showsChip = showsChip
    }

    public var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if showsSubtitle { subtitle }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                if showsChip {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        if let chip { chip }
                    }
                    .frame(width: chipWidth)
                }
                Text(DaydreamFormat.time(start, timeZone)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    .lineLimit(1).frame(width: 60, alignment: .trailing)
                    .opacity(showsTime ? 1 : 0)
            }
        }
        .padding(.leading, 12).padding(.trailing, 14)
        .frame(height: 52)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Self.selectionFill : Color.primary.opacity(hovered ? 0.035 : 0))
                .padding(.horizontal, 4))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if !subtitleText.isEmpty { parts.append(subtitleText) }
        parts.append("observed from " + DaydreamFormat.spokenRange(start, end, timeZone))
        return parts.joined(separator: ", ")
    }
}

extension DDRow where Icon == MomentIcon, Chip == AnyView {
    /// A Focus List row for a moment: moment icon, title, subtitle (`MomentSubtitle.rowText`: never a status), and the
    /// chip slot (primary site | `+ second app`).
    public init(moment m: MomentSlice, timeZone: TimeZone, selected: Bool = false, hovered: Bool = false,
                chipWidth: CGFloat = 176, showsChip: Bool = true, ring: Color? = nil, updating: Bool = false) {
        let chip: AnyView?
        if let site = m.sites.first(where: { !$0.isEmpty }) {
            chip = AnyView(SiteChip(site: site))
        } else if let second = m.bundles.first(where: { $0 != (m.primaryBundle ?? m.bundles.first) }) {
            chip = AnyView(AppChip(bundle: second, name: KitAppNames.name(for: second) ?? ""))
        } else {
            chip = nil
        }
        let subtitleText = MomentSubtitle.rowText(for: m, updating: updating)
        let subtitle: AnyView
        if updating {
            // fix/resummarize: the row's line (fix/prompt-row: an ask in quotes) dims in place and "Updating…" follows it
            // on the same line (no row moves).
            let line = MomentSubtitle.rowText(for: m)
            let text = line.isEmpty ? Text(MomentSubtitle.updating)
                : Text(line).foregroundColor(Color.secondary.opacity(0.5)) + Text(" · " + MomentSubtitle.updating)
            subtitle = AnyView(text.font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1))
        } else {
            // fix/prompt-row: an ask draws as `PromptLine` (cut before its closing quote); every other subtitle as before.
            subtitle = MomentSubtitle.shownPrompt(m).map { AnyView(PromptLine(prompt: $0, lead: m.promptLead, asks: m.promptAsks)) }
                ?? AnyView(Text(subtitleText).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1))
        }
        self.init(icon: MomentIcon(moment: m, size: 32, ring: ring), title: MomentSubtitle.rowTitle(m),
                  subtitleView: subtitle, subtitleText: subtitleText, chip: chip, start: m.start, end: m.end, timeZone: timeZone,
                  selected: selected, hovered: hovered, chipWidth: chipWidth, showsChip: showsChip)
        showsSubtitle = !subtitleText.isEmpty
    }
}

/// Display names of installed apps, from the app bundle on disk (no guessing). nil when not installed.
@MainActor enum KitAppNames {
    private static var cache: [String: String?] = [:]
    static func name(for bundle: String) -> String? {
        if let hit = cache[bundle] { return hit }
        var name: String?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            let display = FileManager.default.displayName(atPath: url.path)
            name = display.hasSuffix(".app") ? String(display.dropLast(4)) : display
        }
        cache[bundle] = name
        return name
    }
}

// MARK: - Day chips

/// One day in `DayChips`. `moments == nil` is still loading; 0 is an empty day.
public struct DayChipModel: Identifiable, Equatable {
    public let id: String
    public let date: Date
    public let topBundle: String?
    public let topName: String?
    public let moments: Int?
    public init(id: String, date: Date, topBundle: String?, topName: String? = nil, moments: Int?) {
        self.id = id; self.date = date; self.topBundle = topBundle; self.topName = topName; self.moments = moments
    }
}

/// A row of day chips (`Today`, `Yesterday`, `Sun 20`) in a grey group, with optional ‹ › buttons.
/// Each chip shows the day's top app; an empty day shows a dashed circle.
public struct DayChips: View {
    let days: [DayChipModel]
    let selected: String?
    let now: Date
    let calendar: Calendar
    let canGoPrevious: Bool
    let canGoNext: Bool
    let onSelect: (String) -> Void
    let onPrevious: (() -> Void)?
    let onNext: (() -> Void)?

    public init(days: [DayChipModel], selected: String?, now: Date, calendar: Calendar, canGoPrevious: Bool = true,
                canGoNext: Bool = false, onSelect: @escaping (String) -> Void, onPrevious: (() -> Void)? = nil,
                onNext: (() -> Void)? = nil) {
        self.days = days; self.selected = selected; self.now = now; self.calendar = calendar
        self.canGoPrevious = canGoPrevious; self.canGoNext = canGoNext
        self.onSelect = onSelect; self.onPrevious = onPrevious; self.onNext = onNext
    }

    /// "Today", "Yesterday", else "Sun 20".
    public static func label(_ day: Date, now: Date, calendar: Calendar) -> String {
        let age = calendar.dateComponents([.day], from: calendar.startOfDay(for: day), to: calendar.startOfDay(for: now)).day ?? Int.max
        if age == 0 { return "Today" }
        if age == 1 { return "Yesterday" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian); f.timeZone = calendar.timeZone
        f.dateFormat = "EEE d"
        return f.string(from: day)
    }

    /// VoiceOver value of a chip: `Loading`, `No moments recorded` (plan §3), `1 moment`, `12 moments`.
    public static func accessibilityValue(moments: Int?) -> String {
        guard let n = moments else { return "Loading" }
        return n == 0 ? "No moments recorded" : n == 1 ? "1 moment" : "\(DaydreamFormat.count(n)) moments"
    }

    static func spokenDate(_ day: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian); f.timeZone = calendar.timeZone
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: day)
    }

    public var body: some View {
        HStack(spacing: 6) {
            if let onPrevious { nav("chevron.left", help: "Previous Day", enabled: canGoPrevious, action: onPrevious) }
            HStack(spacing: 2) { ForEach(days) { chip($0) } }
                .padding(3)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            if let onNext { nav("chevron.right", help: "Next Day", enabled: canGoNext, action: onNext) }
        }
    }

    private func nav(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }

    private func chip(_ d: DayChipModel) -> some View {
        let isSelected = d.id == selected
        let isEmpty = d.moments == 0
        return Button { onSelect(d.id) } label: {
            HStack(spacing: 6) {
                Group {
                    if d.moments == nil {
                        Circle().fill(Color.primary.opacity(0.08)).frame(width: 15, height: 15)
                    } else if isEmpty {
                        Circle().strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.2, dash: [2.2, 2]))
                            .frame(width: 15, height: 15)
                    } else if d.topBundle == nil && d.topName == nil {
                        // Moments, but no known top app: a neutral filled dot, never the empty-day circle.
                        Circle().fill(Color.secondary.opacity(0.45)).frame(width: 9, height: 9)
                    } else {
                        AppIcon(bundle: d.topBundle, name: d.topName ?? "", size: 20)
                    }
                }
                .frame(width: 20, height: 20)
                Text(Self.label(d.date, now: now, calendar: calendar))
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular)).monospacedDigit()
                    .lineLimit(1).fixedSize()
                    .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            }
            .padding(.leading, 6).padding(.trailing, 10).frame(height: 30)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DaydreamStyle.raised)
                        .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // No tooltip: a count on hover was clutter; VoiceOver still reads it (`accessibilityValue`).
        .accessibilityLabel(Self.spokenDate(d.date, calendar: calendar))
        .accessibilityValue(Self.accessibilityValue(moments: d.moments))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Detail body

/// The moment detail shared by the Focus List detail and Recall: optional hero header, the summary
/// by state, and "What happened" (30 pt action rows with a per-action Open Original button).
public struct MomentDetailBody: View {
    let moment: MomentSlice
    let actions: [CanonicalAction]
    let complete: Bool
    let showAllTitle: String?
    let timeZone: TimeZone
    let calendar: Calendar
    let now: Date
    let showsHeader: Bool
    let unavailable: Set<String>
    let onShowAll: (() -> Void)?
    let onOpenOriginal: ((CanonicalAction) -> Void)?
    /// fix/show-all: the summaries phase, so a moment without a note says why ("Writing the summary…"); nil (Recall)
    /// keeps the block to what the note says.
    let phase: SummaryPhase?
    /// fix/writing-forever: the writer's queue, so "Writing the summary…" shows only while this moment is queued or written.
    let queue: SummaryQueue?
    /// fix/show-all: the moment's sends by code and what was typed (`MomentTypedLoad`); nil shows neither.
    let typed: MomentTypedLoad?
    /// fix/show-all: the actions are still being read: only `What happened` is drawn as a placeholder (never the summary).
    let actionsLoading: Bool
    /// Selected timeline detail only; Recall and rows never supply this.
    let sourcePreviews: [OwnerSourcePreview]
    /// compose-send/v1: the typed actions' compose lines ("Sent to Jamie", "Replied to Ada's post on X").
    let composeLines: [String: ComposeLine]
    /// Search's Show in Context, directly under the summary; nil hides it in timeline details.
    let onShowInContext: (() -> Void)?
    /// The host's `onOpenOriginal` activates a native-only action's app (`\.daydreamDetailOpensApps`).
    @Environment(\.daydreamDetailOpensApps) private var opensApps
    /// claude/int-017: the Summary's "+N more" is open.
    @State private var summaryOpen = false

    /// - `actions`: the moment's actions loaded so far, any order (shown chronologically).
    /// - `complete`: `actions` holds every action of the moment.
    /// - `showAllTitle`: link under the rows ("Show all 64 actions", "Load More Actions"); nil hides it.
    /// - `unavailable`: actions whose original couldn't be verified this session (their button is disabled).
    /// - `onOpenOriginal`: nil disables every Open Original button.
    /// - `onShowInContext`: Show in Context under the summary (search's Show in Today); nil hides it.
    public init(moment: MomentSlice, actions: [CanonicalAction], complete: Bool, showAllTitle: String? = nil,
                timeZone: TimeZone, calendar: Calendar, now: Date, showsHeader: Bool = true,
                unavailable: Set<String> = [], onShowAll: (() -> Void)? = nil, onOpenOriginal: ((CanonicalAction) -> Void)? = nil,
                phase: SummaryPhase? = nil, typed: MomentTypedLoad? = nil, actionsLoading: Bool = false, queue: SummaryQueue? = nil,
                onShowInContext: (() -> Void)? = nil, sourcePreviews: [OwnerSourcePreview] = [],
                composeLines: [String: ComposeLine] = [:]) {
        self.composeLines = composeLines
        self.phase = phase; self.queue = queue; self.typed = typed; self.actionsLoading = actionsLoading
        self.onShowInContext = onShowInContext; self.sourcePreviews = sourcePreviews
        self.moment = moment; self.actions = actions; self.complete = complete; self.showAllTitle = showAllTitle
        self.timeZone = timeZone; self.calendar = calendar; self.now = now
        self.showsHeader = showsHeader; self.unavailable = unavailable
        self.onShowAll = onShowAll; self.onOpenOriginal = onOpenOriginal
    }

    private var sorted: [CanonicalAction] {
        actions.sorted { (timestamp($0.at) ?? .distantPast, $0.id) < (timestamp($1.at) ?? .distantPast, $1.id) }
    }
    private var range: String { DaydreamFormat.range(moment.start, moment.end, timeZone) }
    private var dayWord: String { DaydreamFormat.dayName(moment.start, now: now, calendar: calendar) }

    /// A row's open button, per plan L15 (W2-9): a web action is `Open Original` (help `Opens <host> in your
    /// browser`). A native-only action (no site, a bundle) is `Open <App>` only where the host's open activates that
    /// app (`opensApps`, from `\.daydreamDetailOpensApps`: the Focus List's detail); elsewhere, and for an action
    /// naming no app, it keeps `Open Original`, which is what the press then tries.
    public static func rowOpenTitle(_ a: CanonicalAction, opensApps: Bool = false) -> (label: String, help: String) {
        // page-links-1003: a page with its own link names it ("Opens youtube.com/watch… in your browser").
        if !a.site.isEmpty { return ("Open Original", "Opens \(a.link.flatMap(BrowserSites.shortLink) ?? KitBrowsers.host(a.site)) in your browser") }
        guard opensApps, !a.bundle.isEmpty else { return ("Open Original", "Open Original") }
        // Review G31: typed rows saved before test 5 hold the bundle ID as the app ("com.apple.Notes").
        let app = !a.app.isEmpty ? AppNames.display(app: a.app, bundle: a.bundle) : (KitAppNames.name(for: a.bundle) ?? "")
        guard !app.isEmpty else { return ("Open Original", "Open Original") }
        return ("Open " + app, "Open " + app)
    }

    /// A run of consecutive actions in one place (the same app, site and window title), drawn as one row: the
    /// first action's time, how many times, and until when. Its open button opens the run's last action.
    public struct Run: Equatable, Identifiable {
        public let first: CanonicalAction
        public let last: CanonicalAction
        public let count: Int
        /// fix/show-all: every action in the run, in order (its sends are looked up by these).
        public var ids: [String] = []
        public var id: String { first.id }
    }

    /// `sorted` (chronological) folded into runs of repeats, in order. A different action in between starts a
    /// new run, so the order of what happened is kept.
    public static func runs(_ sorted: [CanonicalAction]) -> [Run] {
        func key(_ a: CanonicalAction) -> String {
            (a.bundle.isEmpty ? a.app : a.bundle) + "|" + (a.site.isEmpty ? "" : KitBrowsers.host(a.site)) + "|" + a.title
        }
        var out: [Run] = []
        for a in sorted {
            if let run = out.last, key(run.last) == key(a) {
                out[out.count - 1] = Run(first: run.first, last: a, count: run.count + 1, ids: run.ids + [a.id])
            } else {
                out.append(Run(first: a, last: a, count: 1, ids: [a.id]))
            }
        }
        return out
    }

    /// A run's repeat line: "3 times, until 3:52 PM" ("3 times" when the last time is the first's, or unknown).
    public static func repeatText(_ run: Run, timeZone: TimeZone) -> String? {
        guard run.count > 1 else { return nil }
        let first = timestamp(run.first.at).map { DaydreamFormat.time($0, timeZone) }
        let last = timestamp(run.last.at).map { DaydreamFormat.time($0, timeZone) }
        guard let last, last != first else { return "\(run.count) times" }
        return "\(run.count) times, until " + last
    }

    /// Why an action's Open Original button is disabled, or nil when it can open.
    public static func openBlockReason(_ a: CanonicalAction, unavailable: Set<String>, canOpen: Bool) -> String? {
        if unavailable.contains(a.id) { return "The original couldn't be verified." }
        if a.bundle.isEmpty && a.site.isEmpty { return "No original to reopen" }
        if !canOpen { return "Open Original unavailable" }
        return nil
    }

    /// fix/show-all: a run's send line: the first send by code among its actions ("Asked Claude", "Texted Q7"), else
    /// "Sent" for a confirmed message send; nil when the run sent nothing.
    public static func sendText(_ run: Run, actions: [CanonicalAction], sends: [String: String]) -> String? {
        let ids = run.ids.isEmpty ? [run.first.id, run.last.id] : run.ids
        if let line = ids.lazy.compactMap({ sends[$0] }).first { return line }
        let sent = Set(actions.filter { $0.state == "sent" }.map(\.id))
        return ids.contains(where: sent.contains) ? "Sent" : nil
    }

    /// fix/show-all: the summary block's words when the moment has no note to show, by state: "Writing the summary…" while
    /// the writer is on and will write it (the phase's own line while the model downloads, is checked or stopped),
    /// "Summaries are off", "No summary for this moment" (never written), "Too long to summarize", a partial day's
    /// reason; a note with nothing left to say shows the row's own words. nil: the note (or the sends by code) shows.
    /// fix/writing-forever: with the writer's `queue`, "Writing the summary…" only while this moment is queued or running;
    /// else its real reason (still going, waiting for power, or no summary yet). nil queue (not wired): as before.
    public static func summaryStatus(_ m: MomentSlice, phase: SummaryPhase, queue: SummaryQueue? = nil) -> String? {
        let hasNote = m.summary.isReady && m.bullets.contains { !$0.correction }
        if hasNote || !m.lines.isEmpty { return nil }
        if let previous = m.previousSummaryStatus(phase: phase, queue: queue) { return previous }
        switch m.summary {
        case .ready:
            let text = MomentSubtitle.text(for: m)
            return text.isEmpty ? nil : text
        // claude/messages2-1003: "" for a moment still going (`SummaryQueue.openLine`): no summary line at all.
        // claude/notesfix-015 (owner 10/05, 0.1.6): no model writes a moment, so a moment never waits for one: nothing
        // drawn (no "Writing the summary…", "No summary yet" or waiting line left hanging on a card).
        case .pending: return ""
        case .summariesOff: return "Summaries are off"
        case .notWritten: return "No summary for this moment"
        case .tooLong: return "Too long to summarize"
        case .incomplete: return "Partial day · summary unavailable"
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if showsHeader { header }
            MomentSummaryAndHistory {
                if let onShowInContext {
                    VStack(alignment: .leading, spacing: 10) {
                        summary
                        ShowInContextButton(action: onShowInContext)
                    }
                } else {
                    summary
                }
            } history: {
                Group {
                    if let typed {
                        VStack(alignment: .leading, spacing: 0) {
                            MomentDetailEntries(entries: MomentHistoryCondense.lines(OwnerSourceMomentProjection.history(actions, previews: sourcePreviews, typed: typed), actions: actions, timeZone: timeZone, compose: composeLines), timeZone: timeZone,
                                unavailable: unavailable,
                                onOpen: onOpenOriginal.map { open in { id in if let a = actions.first(where: { $0.id == id }) { open(a) } } })
                            moreButton(shown: actions.count)
                        }
                    } else {
                        // Owner 10/2: the details page keeps its layout; What happened is condensed to its signal (no jargon, no repeats).
                        MomentDetailEntries(entries: MomentHistoryCondense.lines(OwnerSourceMomentProjection.history(actions, previews: sourcePreviews), actions: actions, timeZone: timeZone, compose: composeLines),
                            timeZone: timeZone, unavailable: unavailable,
                            onOpen: onOpenOriginal.map { open in { id in if let a = actions.first(where: { $0.id == id }) { open(a) } } })
                        moreButton(shown: actions.count)
                    }
                }
                .redacted(reason: actionsLoading ? .placeholder : [])
                .accessibilityHidden(actionsLoading)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var appRefs: [MomentIcon.AppRef] {
        var refs: [MomentIcon.AppRef] = []
        let primary = moment.primaryBundle ?? moment.bundles.first
        refs.append((primary, moment.primaryApp ?? ""))
        if let second = moment.bundles.first(where: { $0 != primary }) { refs.append((second, KitAppNames.name(for: second) ?? "")) }
        return refs
    }

    /// A web moment's hero is its site tile with the browser badge, as on its row (`MomentIcon`).
    private var heroSite: String? {
        guard let site = moment.sites.first(where: { !$0.isEmpty }) else { return nil }
        let primary = moment.primaryBundle ?? moment.bundles.first
        return primary == nil || KitBrowsers.isBrowser(primary) ? site : nil
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            if let site = heroSite {
                WebMonogramTile(domain: site, browserBundle: moment.primaryBundle ?? moment.bundles.first, size: 52)
            } else {
                AppFan(apps: appRefs, size: 52)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(moment.title.isEmpty ? TitleClean.clean(moment.subject) : moment.title).font(.system(size: 22, weight: .bold)).lineLimit(2)
                Text(dayWord + ", " + range).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The details page's summary before a note (owner 10/3): the card's left column for this one moment. Pending while
    /// the writer has it (`FocusAppCard.summaryPending`); without a phase (Recall), while its summary state is pending.
    static func capturedColumn(_ m: MomentSlice, previews: [OwnerSourcePreview], phase: SummaryPhase?, queue: SummaryQueue?,
                               compose: [String: ComposeLine] = [:], actions: [CanonicalAction] = []) -> FocusAppCard.LeftColumn {
        let pending: Bool
        if let phase { pending = FocusAppCard.summaryPending([m], phase: phase, queue: queue) }
        else if case .pending = m.currentSummaryState { pending = true } else { pending = false }
        return FocusAppCard.leftColumn([m], previews: previews, writingIDs: actions.isEmpty ? nil : FocusAppCard.writingIDs(actions),
                                       pending: pending, compose: compose, actions: actions)
    }

    /// What the summary block says without a note: the moment's sends by code (who only), a too-long or partial
    /// moment's plain reason, else nothing (no skeleton: the day card says the summaries phase once).
    static func noteless(_ m: MomentSlice) -> [String] {
        if !m.lines.isEmpty { return m.lines }
        switch m.summary {
        case .tooLong: return ["Too long to summarize"]
        case .incomplete: return ["Partial day · summary unavailable"]
        case .ready, .pending, .summariesOff, .notWritten: return []
        }
    }

    /// claude/int-017 (owner 10/06, 0.1.7): the details page's Summary is the card's: "Summary" over code's own condensed
    /// lines (`FocusAppCard.summaryLines`), at most about 5 and "+N more", then What happened with every row. Never
    /// "Summary pending", "What you wrote", "Updating…", "Writing the summary…" or "No summary yet" (no model writes a
    /// moment, so there is nothing to wait for), and never a filler line ("Used the send key in ChatGPT."). One grey dot
    /// for every line (`CardLine`).
    @ViewBuilder private var summary: some View {
        let column = Self.capturedColumn(moment, previews: sourcePreviews, phase: phase, queue: queue, compose: composeLines, actions: actions)
        let lines = FocusAppCard.summaryLines(column)
        let corrections = moment.bullets.filter(\.correction)
        if !lines.isEmpty || !corrections.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text("Summary").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    // Marked only when the person's cloud key wrote it (an older day's note); a local note needs no chip.
                    if FocusListExpanded.showsCloudKeyChip(moment) { OnThisMacChip(.cloudKey, size: .small) }
                }
                ForEach(Array(FocusAppCard.visibleSummary(lines, expanded: summaryOpen).enumerated()), id: \.offset) { _, line in
                    CardLine(line, size: 13).textSelection(.enabled)
                }
                OverflowToggle(collapsed: FocusAppCard.summaryMore(lines), expanded: $summaryOpen, size: 12)
                ForEach(Array(corrections.enumerated()), id: \.offset) { _, b in CardLine(b, size: 13) }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var happened: some View {
        let rows = sorted
        return VStack(alignment: .leading, spacing: 0) {
            Text("What happened").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.bottom, 4)
            // Repeats in one place are one row (declutter): "Grocery list · 3 times, until 3:52 PM".
            ForEach(Self.runs(rows)) { run in
                actionRow(run)
                Rectangle().fill(DaydreamStyle.hairline).frame(height: DaydreamStyle.hairlineWidth).padding(.leading, 82)
            }
            moreButton(shown: rows.count)
        }
    }

    @ViewBuilder private func moreButton(shown: Int) -> some View {
        let total = max(moment.actionCount, shown)
        if let showAllTitle, let onShowAll, shown < total || !complete {
                Button(action: onShowAll) {
                    HStack(spacing: 4) {
                        Text(showAllTitle)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor)
                    .frame(height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 82)
        }
    }

    private func actionRow(_ run: Run) -> some View {
        // The time is the run's first; the open button opens its last action.
        let a = run.last
        let when = timestamp(run.first.at)
        let block = Self.openBlockReason(a, unavailable: unavailable, canOpen: onOpenOriginal != nil)
        // The site or app, not the action's long description (that stays in the note's evidence).
        let appName = AppNames.display(app: a.app, bundle: a.bundle) // review G31: never "com.apple.Notes"
        let detail = !a.site.isEmpty ? KitBrowsers.host(a.site) : appName
        let name = a.title.isEmpty ? appName : a.title
        let repeats = Self.repeatText(run, timeZone: timeZone)
        let send = typed.flatMap { Self.sendText(run, actions: actions, sends: $0.sends) }
        let open = Self.rowOpenTitle(a, opensApps: opensApps)
        return HStack(spacing: 10) {
            Text(when.map { DaydreamFormat.time($0, timeZone) } ?? "").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                .lineLimit(1).frame(width: 56, alignment: .leading)
            Group {
                if !a.site.isEmpty && KitBrowsers.isBrowser(a.bundle) {
                    WebMonogramTile(domain: a.site, browserBundle: nil, size: 16)
                } else {
                    AppIcon(bundle: a.bundle.isEmpty ? nil : a.bundle, name: a.app, size: 16)
                }
            }
            .frame(width: 16, height: 16)
            // claude/searchui-1005 (owner 10/04: no bold in note lines): a What happened line is regular weight.
            Text(name).font(.system(size: 12.5)).lineLimit(1)
            if let send {
                // fix/show-all: a send says who (never words), where the site or app would be.
                Text(send).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            } else if !detail.isEmpty && detail != name {
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            if let repeats {
                Text(repeats).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            Spacer(minLength: 6)
            Button { if block == nil { onOpenOriginal?(a) } } label: {
                Image(systemName: "arrow.up.forward.circle").font(.system(size: 13, weight: .regular))
                    .foregroundStyle(block == nil ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(block != nil)
            .help(block ?? open.help)
            .accessibilityLabel(open.label)
            .accessibilityHint(block ?? "")
        }
        .frame(height: 30)
        .accessibilityElement(children: .contain)
    }
}

/// Show in Context (owner, 9/30): one click from a search result's detail to the moment on its own day, selected and
/// open. The caller passes search's Show in Today (`RecallModel.showInDay`); nothing else is drawn with it.
public struct ShowInContextButton: View {
    public static let title = "Show in Context"
    let action: () -> Void
    public init(action: @escaping () -> Void) { self.action = action }
    public var body: some View {
        Button(action: action) {
            Text(Self.title).font(.system(size: 12, weight: .medium))
                .frame(height: 30)
        }
        .buttonStyle(FocusLinkButtonStyle())
        .accessibilityLabel(Self.title)
        .accessibilityIdentifier("show-in-context")
    }
}

// MARK: - Actions menu

/// The ⌘K Actions menu (find-A `AActionsMenu`): 304 wide (up to 380 for a long title), 34 pt items and a `Privacy`
/// group label. No search line (declutter): it is a short menu, and typing moves the highlight (the owner's
/// type-select). It never installs key equivalents (the owner routes keys), and Privacy items carry no keys.
public struct ActionsMenuView: View {
    let items: [MomentActionItem]
    let selected: MomentActionID?
    let run: (MomentActionID) -> Void

    public init(items: [MomentActionItem], selected: MomentActionID? = nil, run: @escaping (MomentActionID) -> Void) {
        self.items = items; self.selected = selected; self.run = run
    }

    /// Items matching `filter` (case-insensitive title match), in order. Privacy items never keep keys.
    public static func visibleRows(_ items: [MomentActionItem], filter: String) -> [MomentActionItem] {
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return items
            .filter { q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) }
            .map { $0.group == .privacy && $0.keys != nil
                ? MomentActionItem(id: $0.id, title: $0.title, symbol: $0.symbol, keys: nil, enabled: $0.enabled, reason: $0.reason,
                                   destructive: $0.destructive, group: $0.group, help: $0.help)
                : $0 }
    }

    public var body: some View {
        let rows = Self.visibleRows(items, filter: "")
        let main = rows.filter { $0.group != .privacy }
        let privacy = rows.filter { $0.group == .privacy }
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(main, id: \.id) { row($0) }
            if !privacy.isEmpty {
                if !main.isEmpty { Divider().padding(.vertical, 4).padding(.horizontal, 8) }
                Text("Privacy").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.bottom, 2)
                    .accessibilityAddTraits(.isHeader)
                ForEach(privacy, id: \.id) { row($0) }
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 5)
        // 304 pt, widening like a native menu to its longest title (up to 380 pt, then truncating).
        .frame(minWidth: 304, maxWidth: 380)
        .fixedSize(horizontal: true, vertical: false)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(KitPalette.menuFill)
            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            .shadow(color: .black.opacity(0.30), radius: 28, y: 14))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(KitPalette.menuStroke, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions")
    }

    private func row(_ item: MomentActionItem) -> some View {
        let isSelected = item.id == selected
        let tint: Color = item.destructive ? KitPalette.red : .primary
        return Button { if item.enabled { run(item.id) } } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(item.destructive ? AnyShapeStyle(KitPalette.red) : AnyShapeStyle(.secondary))
                    .frame(width: 20)
                Text(item.title).font(.system(size: 13, weight: isSelected ? .medium : .regular)).foregroundStyle(tint).lineLimit(1)
                Spacer(minLength: 6)
                if let keys = item.keys { Keycap(keys) }
            }
            .padding(.horizontal, 8).frame(height: 34)
            .background(isSelected ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
            .opacity(item.enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!item.enabled)
        .help(item.enabled ? (item.help ?? item.title) : (item.reason ?? item.title))
        .accessibilityLabel(item.title)
        .accessibilityHint(item.enabled ? (item.help ?? "") : (item.reason ?? ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Forget confirmation

/// A request to forget one moment (its `activity` scope).
public struct MomentForgetRequest: Identifiable, Equatable {
    public let id: String
    public let scope: MemoryActionScope
    public let start: Date
    public let end: Date
    public let timeZone: TimeZone

    /// `timeZone` is the display zone (the caller's calendar) for the message's time range. The scope
    /// names the moment's day in the note's own zone (`MomentSlice.timeZoneID`, W2-2) and falls back to
    /// `timeZone` for a slice that doesn't carry one.
    public init(moment: MomentSlice, timeZone: TimeZone) {
        id = moment.id
        scope = MemoryActionScope(kind: "activity", id: moment.id, day: moment.dayKey, timezone: moment.scopeTimeZoneID(fallback: timeZone))
        start = moment.start; end = moment.end; self.timeZone = timeZone
    }

    /// "This permanently deletes 17 actions from 2:30–3:20 PM. This can't be undone." + the core warning.
    public func message(actionCount: Int, warning: String) -> String {
        let n = DaydreamFormat.count(actionCount) + (actionCount == 1 ? " action" : " actions")
        let base = "This permanently deletes \(n) from \(DaydreamFormat.range(start, end, timeZone)). This can't be undone."
        let w = warning.trimmingCharacters(in: .whitespacesAndNewlines)
        return w.isEmpty ? base : base + " " + w
    }
}

struct MomentForgetModifier: ViewModifier {
    @ObservedObject var browser: ActivityBrowser
    @Binding var request: MomentForgetRequest?
    let onForgotten: (String) -> Void
    let onError: (String) -> Void
    @State private var preview: DeletionPreview?
    /// The request `preview` was prepared for: a preview is only ever shown or committed for it.
    @State private var prepared: MomentForgetRequest?
    @State private var retried = false
    /// The request a preview is being prepared for off the main thread (`previewCanonicalDeleteOffMain`).
    @State private var preparing: MomentForgetRequest?
    /// The request whose Forget is being committed off the main thread (`confirmCanonicalDeleteOffMain`): nothing is
    /// prepared or asked for it meanwhile.
    @State private var committing: MomentForgetRequest?

    func body(content: Content) -> some View {
        content
            .onAppear { prepare() }
            .onChange(of: request) { next in
                retried = false
                if preview != nil && prepared != next {
                    // The owner cleared or replaced the request: release the old preview, let its
                    // alert close, then prepare (and ask about) the new request, if any.
                    discard()
                    DispatchQueue.main.async { prepare() }
                } else {
                    prepare()
                }
            }
            .alert("Forget this moment?", isPresented: Binding(get: { preview != nil && request != nil && prepared == request },
                                                               set: { if !$0 { preview = nil } })) {
                Button("Cancel", role: .cancel) { cancel() }
                Button("Forget", role: .destructive) { confirm() }
            } message: {
                Text(prepared.map { $0.message(actionCount: preview?.actionCount ?? 0, warning: preview?.warning ?? "") } ?? "")
            }
    }

    private func prepare() {
        guard let request, preview == nil, committing != request else { return }
        if let make = browser.previewCanonicalDeleteOffMain {
            // gold r3-store: prepared off the main thread; the alert asks once it lands, for the request still asked
            // about only. A preview for a request that changed or was cleared meanwhile is released.
            guard preparing != request else { return }
            preparing = request
            let browser = browser
            Task { @MainActor in
                let made: Result<DeletionPreview, Error>
                do { made = .success(try await make(request.scope)) } catch { made = .failure(error) }
                let current = preparing == request && self.request == request && preview == nil
                if preparing == request { preparing = nil }
                switch made {
                case .success(let next) where current:
                    preview = next; prepared = request
                case .success(let next):
                    try? browser.cancelCanonicalDelete?(next.id)
                    if self.request != nil && self.request != request && preview == nil { prepare() }
                case .failure where current:
                    self.request = nil
                    onError("Deletion preview unavailable. No records deleted.")
                case .failure:
                    if self.request != nil && self.request != request && preview == nil { prepare() }
                }
            }
            return
        }
        do {
            guard let make = browser.previewCanonicalDelete else { throw MemError.missing }
            preview = try make(request.scope)
            prepared = request
        } catch {
            self.request = nil
            onError("Deletion preview unavailable. No records deleted.")
        }
    }

    /// Cancels the outstanding preview (its token is released) without touching the request.
    private func discard() {
        if let id = preview?.id { try? browser.cancelCanonicalDelete?(id) }
        preview = nil; prepared = nil; preparing = nil
    }

    private func cancel() {
        discard()
        request = nil
    }

    private func confirm() {
        guard let current = preview, let request else { return }
        // Only the request the preview was made for can be committed.
        guard prepared == request else {
            discard()
            prepare()
            return
        }
        if let commit = browser.confirmCanonicalDeleteOffMain {
            // gold r3-store: committed off the main thread. The alert closes now; the moment goes once the commit
            // lands (onForgotten), and a failure is handled as below.
            preview = nil; prepared = nil; committing = request
            Task { @MainActor in
                let done: Result<Void, Error>
                do { try await commit(current.id); done = .success(()) } catch { done = .failure(error) }
                if committing == request { committing = nil }
                switch done {
                case .success:
                    if self.request == request { self.request = nil }
                    onForgotten(request.id)
                case .failure:
                    committed(failure: current, request: request)
                }
            }
            return
        }
        do {
            guard let commit = browser.confirmCanonicalDelete else { throw MemError.missing }
            try commit(current.id)
            preview = nil; prepared = nil; self.request = nil
            onForgotten(request.id)
        } catch {
            preview = nil; prepared = nil
            committed(failure: current, request: request)
        }
    }

    /// A Forget that didn't commit.
    private func committed(failure current: DeletionPreview, request: MomentForgetRequest) {
        // An expired preview (5 minutes) is prepared again once and shown for a fresh confirmation.
        if !retried, let expires = timestamp(current.expiresAt), expires <= browser.now() {
            retried = true
            DispatchQueue.main.async { prepare() }
            return
        }
        if self.request == request { self.request = nil }
        onError("Nothing confirmed deleted. Refresh and review the scope again.")
    }
}

extension View {
    /// Runs the deletion preview for `request`, asks `Forget this moment?`, then confirms or cancels
    /// the preview. Errors use the existing strings; `onForgotten` gets the moment ID.
    public func momentForgetConfirmation(browser: ActivityBrowser, request: Binding<MomentForgetRequest?>,
                                         onForgotten: @escaping (String) -> Void = { _ in },
                                         onError: @escaping (String) -> Void) -> some View {
        modifier(MomentForgetModifier(browser: browser, request: request, onForgotten: onForgotten, onError: onError))
    }
}

// MARK: - Exclude confirmation

/// A request to exclude an app from recording.
public struct ExcludeAppRequest: Identifiable, Equatable {
    public var id: String { bundle }
    public let bundle: String
    public let appName: String
    public init(bundle: String, appName: String) { self.bundle = bundle; self.appName = appName }
    /// The moment's primary app; nil without a bundle and a display name.
    public init?(moment: MomentSlice) {
        guard let bundle = moment.primaryBundle, let name = moment.primaryApp else { return nil }
        self.init(bundle: bundle, appName: name)
    }
    public var title: String { "Exclude \(appName) from recording?" }
    /// The real behaviour (§8.4 with amendments F2): `MemoryStore.updatePolicy` adds the app to the
    /// policy that every reader sanitizes under (its past moments are hidden) and deletes every stored
    /// summary (they are written again, which the message says: a person sees them change); the save stops recording
    /// while it runs (recording the person had on starts again by itself afterwards, so it isn't said). Connected AI apps
    /// stay connected: hiding more never turns their keys off (`MemoryStore.savePreferences`).
    public var message: String {
        "DayDream will skip \(appName) from now on, and its past moments are hidden. Summaries are rewritten."
    }
}

/// "Don't Record <site>…" (Chrome page history): a request to stop saving pages from one site and hide
/// the ones already saved. `site` is the `BrowserSites.siteEntry` form, so it covers the site's subdomains.
public struct ExcludeSiteRequest: Identifiable, Equatable {
    public var id: String { site }
    public let site: String
    public init(site: String) { self.site = site }
    public var title: String { "Don't record \(site)?" }
    /// The real behaviour: the site joins the owner's list that every reader sanitizes under (its past pages
    /// are hidden at once); the save stops recording while it runs, like Exclude App, and AI apps stay connected.
    public var message: String {
        "DayDream will stop saving pages from \(site) and hide the ones it already saved."
    }
    public static let cancelTitle = "Cancel"
    public static let confirmTitle = "Don't Record"
    /// The menu item that opens this confirmation.
    public var menuTitle: String { "Don't Record \(site)…" }
    /// Google Chrome moments only: one request per site the moment shows, at most `limit`, never a site
    /// that is already skipped by default. Sites that aren't a valid site entry are left out.
    public static let limit = 5
    public static func requests(for moment: MomentSlice) -> [ExcludeSiteRequest] {
        guard moment.primaryBundle == SettingsAppsContent.chromeBundle else { return [] }
        var seen = Set<String>()
        return moment.sites.compactMap { BrowserSites.siteEntry($0) }
            .filter { !BrowserSites.blockedByDefault(host: $0) && seen.insert($0).inserted }
            .prefix(limit).map(ExcludeSiteRequest.init(site:))
    }
}

struct ExcludeAppModifier: ViewModifier {
    @ObservedObject var browser: ActivityBrowser
    @Binding var request: ExcludeAppRequest?
    let onExcluded: (String) -> Void
    let onError: (Error) -> Void

    func body(content: Content) -> some View {
        content.alert(request?.title ?? "", isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
                      presenting: request) { r in
            Button("Cancel", role: .cancel) { request = nil }
            Button("Exclude") {
                request = nil
                guard let exclude = browser.excludeApp else { onError(MemError.missing); return }
                Task { @MainActor in
                    do { try await exclude(r.bundle); onExcluded(r.bundle) } catch { onError(error) }
                }
            }
        } message: { r in
            Text(r.message)
        }
    }
}

struct ExcludeSiteModifier: ViewModifier {
    @ObservedObject var browser: ActivityBrowser
    @Binding var request: ExcludeSiteRequest?
    let onExcluded: (String) -> Void
    let onError: (Error) -> Void

    func body(content: Content) -> some View {
        content.alert(request?.title ?? "", isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
                      presenting: request) { r in
            Button(ExcludeSiteRequest.cancelTitle, role: .cancel) { request = nil }
            Button(ExcludeSiteRequest.confirmTitle) {
                request = nil
                guard let exclude = browser.excludeSite else { onError(MemError.missing); return }
                Task { @MainActor in
                    do { try await exclude(r.site); onExcluded(r.site) } catch { onError(error) }
                }
            }
        } message: { r in
            Text(r.message)
        }
    }
}

extension View {
    /// Confirms `Don't record <site>?`, then calls `browser.excludeSite` once.
    public func excludeSiteConfirmation(browser: ActivityBrowser, request: Binding<ExcludeSiteRequest?>,
                                        onExcluded: @escaping (String) -> Void = { _ in },
                                        onError: @escaping (Error) -> Void) -> some View {
        modifier(ExcludeSiteModifier(browser: browser, request: request, onExcluded: onExcluded, onError: onError))
    }
    /// Confirms `Exclude <App> from recording?`, then calls `browser.excludeApp` once.
    public func excludeAppConfirmation(browser: ActivityBrowser, request: Binding<ExcludeAppRequest?>,
                                       onExcluded: @escaping (String) -> Void = { _ in },
                                       onError: @escaping (Error) -> Void) -> some View {
        modifier(ExcludeAppModifier(browser: browser, request: request, onExcluded: onExcluded, onError: onError))
    }
}

// MARK: - Original unavailable

/// Inline banner after a failed reopen: `Couldn't open the original.`
public struct OriginalUnavailableBanner: View {
    let onDismiss: (() -> Void)?
    public init(onDismiss: (() -> Void)? = nil) { self.onDismiss = onDismiss }
    public static let text = "Couldn't open the original."
    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.tertiary)
            Text(Self.text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(DaydreamStyle.wellFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Detail host

private struct DaydreamDetailOpensAppsKey: EnvironmentKey { static let defaultValue = false }
public extension EnvironmentValues {
    /// Set by a host whose `MomentDetailBody.onOpenOriginal` activates a native-only action's app (a row with no
    /// site and a bundle) instead of reopening it: those rows then say `Open <App>` (plan L15, W2-9). Default false:
    /// a host that reopens every row keeps `Open Original`.
    var daydreamDetailOpensApps: Bool {
        get { self[DaydreamDetailOpensAppsKey.self] }
        set { self[DaydreamDetailOpensAppsKey.self] = newValue }
    }
}
