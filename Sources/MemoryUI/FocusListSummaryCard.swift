import SwiftUI
import MemoryCore

// The Focus List day summary card (spec §3.4, plan §5 A1, amendments A1; declutter; fix/day-card). Every value comes
// from the day's `TodaySnapshot`. The headline is the day note (L4) while its main thread is still the day's main
// thread, else the day's main thread by code (`LiveDay`: "Export crash fix  ~1 hr 5 min") with its named side lines,
// communications first. Never a count, never a skeleton or a pending chip: whatever is on screen stays until a newer
// note replaces it. Under it, at most one line: the summaries phase's own line (downloading, checking, a problem with
// its one fixing button), or "Summaries are off · Turn On". No stat grid, no observation range, no "Updated" time.

/// Whether the day has a stored day note, from the day read itself. `TodaySnapshot` carries a note only as a
/// headline, and drops a ready note whose title is the writer's generic "Day summary" (the usual outcome for
/// 21–100 actions under the old 20-action batch writer, data-audit fact 4; prompt4 never writes it, but stored notes
/// keep it). Such a day is summarized, not pending: the writer never rewrites it.
public enum FocusDayNote: Equatable {
    /// No day note is stored for the day's current input.
    case none
    /// A day note is stored (`status == "ready"` with a generated note), whatever its title; `local` from its generator.
    case ready(local: Bool)
    /// The day read isn't at hand: claim neither a note nor a pending one.
    case unknown

    public static func make(_ day: ActionDay) -> FocusDayNote {
        guard day.summary.status == "ready", let generated = day.summary.generated else { return .none }
        return .ready(local: DaydreamNotes.isLocal(generated))
    }
}

/// The day summary card: headline or fallback, then the day ribbon.
public struct FocusListSummaryCard: View {
    let snapshot: TodaySnapshot
    let day: DayWord
    let dayNote: FocusDayNote
    let isToday: Bool
    let state: RecordingState?
    let narrow: Bool
    let calendar: Calendar
    let openSummarySettings: (() -> Void)?
    /// The moment lit from outside the card (a hovered or open row): its span stands out on the ribbon.
    let linked: String?
    /// The ribbon's hovered moment (nil when the pointer leaves), so the Focus List can light its row.
    let onRibbonHover: (String?) -> Void
    /// The preview's sample: no "Summaries are off" line (the sample has its notes; nothing can be turned on).
    let sample: Bool
    /// The failed phase's one fixing button (`ActivityModel.fixSummaries`); nil shows the problem's line alone.
    let fixSummaries: ((SummaryProblem) -> Void)?
    @State private var showsAllBullets = false
    @State private var hoveredSegment: String?
    @Environment(\.daydreamReferenced) private var referenced
    @Environment(\.daydreamReferenceClick) private var referenceClick

    /// - `day`: how the fallback headline names the day ("today", "yesterday", "on Sunday").
    /// - `dayNote`: the day note's real state, from the read the snapshot came from (`FocusDayNote.make`).
    /// - `state`: the live recording state, drawn on today's ribbon only (now tick, live pause).
    /// - `openSummarySettings`: the "Turn On" link while summaries are off; nil shows the footnote without a link.
    /// - `fixSummaries`: the failed phase's one button ("Try Again", "Change Key", "Add Credits").
    public init(snapshot: TodaySnapshot, day: DayWord, dayNote: FocusDayNote, isToday: Bool, state: RecordingState?, narrow: Bool,
                calendar: Calendar, openSummarySettings: (() -> Void)? = nil, linked: String? = nil,
                onRibbonHover: @escaping (String?) -> Void = { _ in }, sample: Bool = false,
                fixSummaries: ((SummaryProblem) -> Void)? = nil) {
        self.snapshot = snapshot; self.day = day; self.dayNote = dayNote; self.isToday = isToday; self.state = state; self.narrow = narrow
        self.calendar = calendar; self.openSummarySettings = openSummarySettings
        self.linked = linked; self.onRibbonHover = onRibbonHover; self.sample = sample; self.fixSummaries = fixSummaries
    }

    /// The block a day-note line is about (its name is in the line: "About an hour: Investor update"), for lighting its
    /// band on the ribbon while the line is hovered. nil when no block's name is in it.
    public static func block(for line: String, in blocks: [LevelBlockSlice]) -> LevelBlockSlice? {
        blocks.filter { !$0.name.isEmpty && line.localizedCaseInsensitiveContains($0.name) }.max { $0.name.count < $1.name.count }
    }

    // MARK: Values (also the check hooks)

    /// What the card's headline area says.
    public enum Headline: Equatable {
        /// The day's headline and lines: the day note's (L4) while it still fits the day, else the day's threads by code
        /// (`LiveDay`); `locality` only for an older day summary written with the person's cloud key.
        case ready(title: String, bullets: [MomentBullet], locality: Locality?)
        /// Nothing to claim (no named moment).
        case none
    }

    /// The headline for a day (`DayLevelSlice.dayTitle` already chose the day note or the day's threads by code), else an
    /// older stored day summary. Never a count ("24 moments" said nothing).
    public static func headline(for s: TodaySnapshot, day: DayWord, timeZone: TimeZone) -> Headline {
        if let levels = s.levels, let title = levels.dayTitle, !title.isEmpty {
            let corrections = s.headlineBullets.filter(\.correction)
            return .ready(title: title, bullets: levels.dayLines.map { MomentBullet(text: $0) } + corrections, locality: nil)
        }
        if let title = s.headline {
            let locality = s.headlineLocal.map { $0 ? Locality.local : .cloudKey }
            return .ready(title: title, bullets: DaydreamNotes.sendsFirst(s.headlineBullets), locality: locality)
        }
        // A day read without its threads (a store without level notes): the moment with the most time, by its name.
        if let main = s.moments.filter({ !$0.title.isEmpty }).max(by: { ($0.end.timeIntervalSince($0.start), $1.start) < ($1.end.timeIntervalSince($1.start), $0.start) }) {
            return .ready(title: main.title, bullets: [], locality: nil)
        }
        return .none
    }

    /// The one line under the headline about summaries, from the phase: its own line while it downloads, checks or
    /// failed (with the problem's one button), "Summaries are off" while off (never on the preview's sample), nothing
    /// while on.
    public enum PhaseLine: Equatable {
        case none
        case off
        case status(String)
        case problem(SummaryProblem)
    }
    public static func phaseLine(_ s: SummaryAvailability, sample: Bool = false) -> PhaseLine {
        switch s.shown {
        case .off: return sample ? .none : .off
        case .on: return .none
        case .failed(let problem): return .problem(problem)
        case .downloading, .checking: return s.shown.line.map(PhaseLine.status) ?? .none
        }
    }

    /// Under a partial day's count: "Some of today may be missing." ("this day" on a past day).
    public static func partialFootnote(isToday: Bool) -> String {
        "Some of " + (isToday ? "today" : "this day") + " may be missing."
    }

    /// The ribbon's single VoiceOver element: "Activity from 8:42 AM to 4:18 PM, 24 moments" (amendments A1),
    /// with the live pause as its value.
    public static func ribbonAccessibility(_ s: TodaySnapshot, model: RibbonModel, timeZone: TimeZone) -> (label: String, value: String) {
        guard !model.empty, let first = s.firstObserved, let last = s.lastObserved else {
            return ("Activity", "Nothing recorded this day.")
        }
        let n = s.momentCount
        let moments = (s.partial ? "at least " : "") + DaydreamFormat.count(n) + (n == 1 ? " moment" : " moments")
        let label = "Activity from " + DaydreamFormat.spokenRange(first, last, timeZone) + ", " + moments
        let value = model.pause.map { "Paused from " + DaydreamFormat.spokenRange($0.start, $0.end, timeZone) } ?? ""
        return (label, value)
    }

    // MARK: Body

    private var tz: TimeZone { calendar.timeZone }

    public var body: some View {
        VStack(spacing: 0) {
            lead
                .padding(.leading, 18).padding(.trailing, 14).padding(.top, 16).padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
            ribbon.padding(.horizontal, 18).padding(.top, 13).padding(.bottom, 9)
        }
        .background { ZStack { DaydreamStyle.raised; DreamWash(intensity: 0.7) } }
        .clipShape(RoundedRectangle(cornerRadius: DaydreamStyle.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DaydreamStyle.cardRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
        .accessibilityElement(children: .contain)
    }

    // MARK: Headline area

    /// The day's own headline only. No week line over a past day (owner 10/2): "Week of Sep 28 to Oct 4" and the week
    /// note's headline above a day's card read as a week view, and said nothing about the day. Every day's card is
    /// drawn as Today's is.
    @ViewBuilder private var lead: some View {
        headlineArea
    }

    /// claude/day-review-1003: the day review's groups, when the day read has any; Today's keep their order between reads.
    @MainActor public static func reviewGroups(_ s: TodaySnapshot, isToday: Bool, now: Date = Date()) -> [DayReviewGroup] {
        guard let facts = s.review, !facts.threads.isEmpty else { return [] }
        return DayReviewMemory.shared.groups(facts, live: isToday, now: now)
    }

    @ViewBuilder private var headlineArea: some View {
        let groups = Self.reviewGroups(snapshot, isToday: isToday)
        if !groups.isEmpty {
            review(groups)
        } else {
            headlineFallback
        }
    }

    /// The day review: the bullets, then a partial day's note and the summaries' own line (never a problem: the hero
    /// shows no error; the card keeps its code bullets while the writer fails).
    private func review(_ groups: [DayReviewGroup]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Expanding a quote is the bullets' only interaction (owner 10/03): no click-to-reference here.
            DayReviewList(groups: groups, size: 13)
                .padding(.leading, 5).padding(.top, 2)
            if snapshot.partial { partialNote.padding(.top, 10).padding(.leading, 5) }
            if Self.reviewPhaseShown(snapshot.summaries, sample: sample) { phaseLine.padding(.top, 10).padding(.leading, 5) }
        }
    }
    /// Under the review: "Summaries are off" and the download's progress, never a problem's line.
    public static func reviewPhaseShown(_ s: SummaryAvailability, sample: Bool = false) -> Bool {
        switch phaseLine(s, sample: sample) {
        case .none, .problem: return false
        case .off, .status: return true
        }
    }

    @ViewBuilder private var headlineFallback: some View {
        switch Self.headline(for: snapshot, day: day, timeZone: tz) {
        case .ready(let title, let bullets, let locality):
            ready(title: title, bullets: bullets, locality: locality)
        case .none:
            VStack(alignment: .leading, spacing: 8) {
                if snapshot.partial { partialNote }
                phaseLine
            }
        }
    }

    private func ready(title: String, bullets: [MomentBullet], locality: Locality?) -> some View {
        let shown = showsAllBullets ? bullets : Array(bullets.prefix(3))
        return VStack(alignment: .leading, spacing: 0) {
            // No AI mark (owner: no sparkle). Threads: the main thread's time beside it, the bullets' times under it.
            referenceable(threaded.flatMap { MomentReference.headline(day: snapshot.dayKey, levels: $0) }) {
                (Text(title).font(.system(size: 17, weight: .semibold))
                    + Text(threaded?.headlineDuration.map { "  " + $0 } ?? "")
                        .font(.system(size: 13)).foregroundColor(.secondary))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
            }
            .accessibilityAddTraits(.isHeader)
            if !shown.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    // A line lights its moments by membership (click-to-reference, MomentReference), never by matching
                    // a block's name in its text (Preview 3's hover band, removed: review P2).
                    ForEach(Array(shown.enumerated()), id: \.offset) { i, bullet in
                        referenceable(threaded.flatMap { MomentReference.bullet(i, day: snapshot.dayKey, levels: $0) }) {
                            Bullet(bullet, size: 12.5)
                        }
                    }
                }
                .padding(.top, 10).padding(.leading, 5)
            }
            HStack(spacing: 8) {
                // Marked only when the person's cloud key wrote the day note, as the moment views do; a note
                // written on this Mac needs no chip.
                if locality == .cloudKey { OnThisMacChip(.cloudKey, size: .small) }
                if bullets.count > 3 {
                    Button(showsAllBullets ? "Show less" : "Show all") { showsAllBullets.toggle() }
                        .buttonStyle(FocusLinkButtonStyle())
                }
            }
            .font(.system(size: 11.5))
            .padding(.top, 11).padding(.leading, 5)
            if snapshot.partial { partialNote.padding(.top, 8).padding(.leading, 5) }
            if Self.phaseLine(snapshot.summaries, sample: sample) != .none { phaseLine.padding(.top, 8).padding(.leading, 5) }
        }
    }

    /// The day's levels when the headline is the day note's (its lines carry their moments).
    private var threaded: DayLevelSlice? {
        guard let levels = snapshot.levels, levels.dayTitle != nil else { return nil }
        return levels
    }

    /// Click-to-reference: a line (or the headline) that names moments is a plain button that lights them; lit, it
    /// has a soft tint. Anything without moments (or with no handler: checks, renders) is drawn as it was.
    @ViewBuilder private func referenceable<Label: View>(_ reference: MomentReference?, @ViewBuilder _ label: () -> Label) -> some View {
        if let reference, let referenceClick {
            let lit = referenced != nil && referenced == Set(reference.moments)
            Button { referenceClick(reference) } label: {
                label().frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(lit ? ReferenceStyle.tint.opacity(1.6) : Color.clear))
            .padding(.horizontal, -5).padding(.vertical, -1)
            .accessibilityHint("Shows these moments below")
        } else {
            label()
        }
    }

    /// `Some of today may be missing.`
    private var partialNote: some View {
        Text(Self.partialFootnote(isToday: isToday)).font(.system(size: 11.5)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The phase's one line: `Summaries are off · Turn On`, `Downloading 1.2 of 2.7 GB`, `Checking the model`, or the
    /// problem's plain words and its one fixing button.
    @ViewBuilder private var phaseLine: some View {
        switch Self.phaseLine(snapshot.summaries, sample: sample) {
        case .none:
            EmptyView()
        case .off:
            HStack(spacing: 4) {
                Text("Summaries are off").foregroundStyle(.secondary)
                if let openSummarySettings {
                    Text("·").foregroundStyle(.tertiary)
                    Button("Turn On", action: openSummarySettings).buttonStyle(FocusLinkButtonStyle())
                }
            }
            .font(.system(size: 11.5))
            .accessibilityElement(children: .contain)
        case .status(let line):
            Text(line).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.secondary)
        case .problem(let problem):
            HStack(spacing: 10) {
                Text(problem.line).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let fixSummaries {
                    Button(problem.button) { fixSummaries(problem) }.buttonStyle(KitCapsuleButtonStyle(height: 22))
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: Ribbon

    private var ribbon: some View {
        KitClock { now in
            let model = RibbonModel.make(snapshot: snapshot, state: state, now: now, calendar: calendar, isToday: isToday).dayCard
            let spoken = Self.ribbonAccessibility(snapshot, model: model, timeZone: tz)
            // One lit span at a time: the pointer on the ribbon or a day-note line first, else the row lit below.
            DDRibbon(model: model, height: .h8, axis: true, hovered: hoveredSegment ?? linked,
                     onHover: { seg in
                         hoveredSegment = seg?.group
                         onRibbonHover(seg.flatMap { $0.group.hasPrefix("band:") ? nil : $0.group })
                     }, calendar: calendar, nowClock: false, showsBands: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken.label)
                .accessibilityValue(spoken.value)
        }
    }
}

// MARK: - Empty and failure cards

/// A day with nothing recorded (spec §3.9): today's `Nothing recorded yet today` with the recording
/// state's line over a dashed ribbon (which carries the now tick or the pause), or a past day's
/// `Nothing recorded this day.` alone.
public struct FocusListEmptyCard: View {
    let isToday: Bool
    let state: RecordingState?
    let dayKey: String
    let calendar: Calendar

    public init(isToday: Bool, state: RecordingState?, dayKey: String, calendar: Calendar) {
        self.isToday = isToday; self.state = state; self.dayKey = dayKey; self.calendar = calendar
    }

    /// Title and detail for the empty day (copy deck §8.6). Past days never claim recording was off.
    /// Paused: no detail (the paused row under the card says so). Off for a reason (a blocker, the Development
    /// Trial): that reason, since the toolbar can't start recording then. Plain Off and Needs Permission: no
    /// detail, since the Start Recording pill and the orange capsule right above say it.
    public static func copy(isToday: Bool, state: RecordingState?) -> (title: String, detail: String?) {
        guard isToday else { return ("Nothing recorded this day.", nil) }
        let detail: String?
        switch state {
        case .recording?: detail = "Moments appear here as you work."
        // The preview's line already sits over the day (CanonicalTimeline): said once, not again here.
        case .off(_, let reason?)? where !reason.isEmpty && reason != PreviewSample.line: detail = reason
        case .paused?, .off?, .needsPermission?, nil: detail = nil
        }
        return ("Nothing recorded yet today", detail)
    }

    public var body: some View {
        let copy = Self.copy(isToday: isToday, state: state)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Circle().strokeBorder(Color.secondary.opacity(0.55), style: StrokeStyle(lineWidth: 1.2, dash: [2.6, 2.2]))
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(copy.title).font(.system(size: isToday ? 17 : 15, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    if let detail = copy.detail {
                        Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 14)
            // Today only: the dashed ribbon carries the now tick or the pause. On a past day it drew nothing.
            if isToday { emptyRibbon }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DaydreamStyle.raised)
        .clipShape(RoundedRectangle(cornerRadius: DaydreamStyle.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DaydreamStyle.cardRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
        .accessibilityElement(children: .contain)
    }

    private var emptyRibbon: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
            KitClock { now in
                let day = RibbonModel.dayDate(dayKey, calendar)
                let model = RibbonModel.make(snapshot: nil, state: state, now: now, calendar: calendar, isToday: true).dayCard
                let range = DDRibbon.defaultRange(segments: [], pause: model.pause, now: now, calendar: calendar, day: day ?? now)
                DDRibbon(segments: [], pause: model.pause, range: range, now: model.now, nowTint: model.nowTint, height: .h8, axis: true,
                         flag: model.flag, empty: true, calendar: calendar, nowClock: false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Activity")
                    .accessibilityValue("Nothing recorded yet today")
            }
            .padding(.horizontal, 18).padding(.top, 13).padding(.bottom, 9)
        }
    }
}

/// A day that couldn't be read (spec §3.9): `This day couldn't be loaded.` (`Today couldn't be loaded.`) and `Try Again`.
public struct FocusListFailureCard: View {
    let isToday: Bool
    let compact: Bool
    let retry: () -> Void

    public init(isToday: Bool, compact: Bool = false, retry: @escaping () -> Void) {
        self.isToday = isToday; self.compact = compact; self.retry = retry
    }

    public static func text(isToday: Bool) -> String { isToday ? "Today couldn't be loaded." : "This day couldn't be loaded." }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 13, weight: .medium)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(Self.text(isToday: isToday)).font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Try Again", action: retry).buttonStyle(KitCapsuleButtonStyle(height: 26))
        }
        .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, compact ? 8 : 14)
        .background(DaydreamStyle.raised, in: RoundedRectangle(cornerRadius: compact ? 12 : DaydreamStyle.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: compact ? 12 : DaydreamStyle.cardRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Private helpers

/// An inline accent link ("Resume", "Show all", "Turn On"): text only, no chrome.
struct FocusLinkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}
