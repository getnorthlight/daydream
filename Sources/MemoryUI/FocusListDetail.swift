import SwiftUI
import MemoryCore

// A moment's pushed detail (spec §3.10, plan §5 A1), the `Show all {n} actions` destination and
// `selectedCanonicalActivity`'s: find-A `ADetailBody` as the kit's `MomentDetailBody` on a card under
// a 44 pt breadcrumb bar (`‹ Today › Moment title`). `CanonicalTimeline` pushes it over the list,
// which stays mounted (opacity 0, no hit testing), so the list's scroll offset survives the round trip.
// The actions load 50 at a time (`Load More Actions` adds 200) while more can exist; each row reopens
// its own original. A page's original is verified before it opens; when that fails the row's button is
// disabled for the session and the unavailable banner shows, with no retry.
//
// States (plan §3): until the first read lands the body is drawn as a placeholder (no "0 of N" count);
// a failed read says so with `Try Again` and keeps whatever was already shown; a read that ran out of
// pages before finding every action (a partial day) says actions may be missing and offers no more
// loading. These notices sit under the breadcrumb, outside the scroll view, so they show wherever the
// person is in the list of actions. The scroll content is at least the card's height, so the metadata
// column's fill and rule run to the card's bottom.

/// A moment's pushed detail: `‹ Today` back, then the moment's actions.
public struct FocusListDetail: View {
    let moment: MomentSlice
    @ObservedObject var browser: ActivityBrowser
    let backTitle: String
    let onBack: () -> Void
    @Environment(\.daydreamNow) private var fixedNow
    @Environment(\.daydreamFocusListProbe) private var probe
    @State private var actions: [CanonicalAction] = []
    @State private var complete = false
    /// The last read found fewer actions than it asked for without finding them all: the day's pages ran
    /// out (a partial day), so asking for more would find nothing new.
    @State private var exhausted = false
    /// The first read for this moment has finished (either way).
    @State private var loaded = false
    /// The latest read failed.
    @State private var failed = false
    @State private var limit = FocusListDetail.firstPage
    @State private var unavailable: Set<String> = []
    @State private var openFailed = false
    @State private var generation = 0
    /// The moment (and its member actions) the latest read was for.
    @State private var readFor: (id: String, actionIDs: [String])?
    @StateObject private var source = OwnerSourceDetailSession()
    @State private var sourceVisible = false
    @State private var sourceWindow: Int?
    /// The typed actions' compose lines (`ActivityBrowser.loadComposeLines`).
    @State private var composeLines: [String: ComposeLine] = [:]

    /// - `backTitle`: the breadcrumb's day ("Today", "Yesterday", "Sunday").
    /// - `onBack`: pops the detail (the breadcrumb, or Esc while Recall is not visible).
    public init(moment: MomentSlice, browser: ActivityBrowser, backTitle: String, onBack: @escaping () -> Void) {
        self.moment = moment; self.browser = browser; self.backTitle = backTitle; self.onBack = onBack
    }

    /// Actions read before `Load More Actions`, and how many each press adds.
    /// fix/show-all: the first read takes what a moment's summary can cover, so its places are whole on open.
    static let firstPage = 400
    static let morePage = 1000
    /// A failed read of the moment's actions.
    public static let failedText = "These actions couldn't be loaded."
    /// The day's pages ran out before every action was found.
    public static let missingText = "Some of this moment's actions may be missing."

    /// `Load More Actions` shows only while more actions can exist: the last read found as many as it
    /// asked for, and not all of them.
    public static func canLoadMore(shown: Int, complete: Bool, exhausted: Bool) -> Bool {
        shown > 0 && !complete && !exhausted
    }

    /// The read found fewer than it asked for and not all: the pages ran out.
    public static func isExhausted(found: Int, complete: Bool, wanted: Int, members: Int) -> Bool {
        !complete && found < min(wanted, members)
    }

    public var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < CanonicalTimeline.compactWidth
            let side: CGFloat = compact ? 16 : 24
            let cardWidth = min(CanonicalTimeline.columnWidth, geo.size.width - 2 * side)
            let canLoadMore = Self.canLoadMore(shown: actions.count, complete: complete, exhausted: exhausted)
            VStack(spacing: 0) {
                breadcrumb
                Rectangle().fill(DaydreamStyle.hairline).frame(height: DaydreamStyle.hairlineWidth)
                notices
                GeometryReader { viewport in
                    ScrollView(.vertical, showsIndicators: false) {
                        // At least the card's height, so the card's fill runs to its bottom.
                        FocusDetailFill(minHeight: viewport.size.height) {
                            // fix/show-all: the summary shows at once (it never waits for the actions), and says where
                            // it is when there is none yet; only What happened waits for the read.
                            MomentDetailBody(moment: moment, actions: actions, complete: complete,
                                             showAllTitle: canLoadMore ? "Load More Actions" : nil,
                                             timeZone: browser.calendar.timeZone, calendar: browser.calendar, now: fixedNow ?? browser.now(),
                                             unavailable: unavailable,
                                             onShowAll: { limit += Self.morePage; load(moment) },
                                             onOpenOriginal: canOpen ? { open($0) } : nil,
                                             phase: browser.summaries.shown, typed: .empty, actionsLoading: !loaded,
                                             queue: browser.summaries.queue, sourcePreviews: source.state.previews,
                                             composeLines: composeLines)
                        }
                        .background(GeometryReader { g in
                            Color.clear.preference(key: FocusDetailBodySize.self, value: g.size)
                        })
                        .onPreferenceChange(FocusDetailBodySize.self) { size in probe?.detailBodySize = size }
                    }
                }
                .accessibilityIdentifier("canonical-app-detail-actions")
            }
            .frame(width: max(0, cardWidth))
            .frame(maxHeight: .infinity)
            .background(DaydreamStyle.raised)
            .clipShape(RoundedRectangle(cornerRadius: DaydreamStyle.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DaydreamStyle.cardRadius, style: .continuous).stroke(DaydreamStyle.cardStroke, lineWidth: 1))
            .padding(.top, 14).padding(.bottom, compact ? 12 : 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(OwnerSourceDetailWindowReader { id in
            sourceWindow = id
            if id == nil { clearSource() }
            else if sourceVisible, NSApplication.shared.isActive { loadSource(moment) }
        }.frame(width: 0, height: 0))
        .onAppear {
            probe?.detailMomentID = moment.id
            load(moment)
            sourceVisible = true
            if sourceWindow != nil, NSApplication.shared.isActive { loadSource(moment) }
        }
        // fix/show-all: the day's memory changed (a Forget, typing turned off, an exclusion, a restore): what was opened
        // goes at once, and is read again under the new rules.
        .onReceive(browser.dayCache.cleared) { key in
            guard key == nil || key == moment.dayKey else { return }
            if sourceVisible, NSApplication.shared.isActive { loadSource(moment) } else { clearSource() }
        }
        // The new moment comes in as the argument: an `onChange` action sees the view as it was before.
        .onChange(of: moment) { next in momentChanged(next) }
        .onDisappear {
            sourceVisible = false; clearSource()
            probe?.detailTyped = .empty
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            guard let window = note.object as? NSWindow,
                  OwnerSourceDetailState.closesOwnWindow(own: sourceWindow, closing: window.windowNumber) else { return }
            sourceVisible = false; clearSource()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemClockDidChange)) { _ in
            clearSource()
            if sourceVisible, NSApplication.shared.isActive { loadSource(moment) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in clearSource() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if sourceVisible { loadSource(moment) }
        }
    }

    /// `‹ Today`: the day goes back (Esc while Recall isn't showing). The moment's title is the heading
    /// right below, so the breadcrumb doesn't repeat it.
    private var breadcrumb: some View {
        HStack(spacing: 6) {
            Button(action: onBack) { Label(backTitle, systemImage: "chevron.left") }
                .buttonStyle(DaydreamOnboardingBackStyle())
                .keyboardShortcut(browser.recallVisible ? nil : .cancelAction)
                .help("Back to " + backTitle)
                .accessibilityLabel("Back to " + backTitle)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
    }

    /// The failed read (with `Try Again`), the missing-actions note and the unavailable original, pinned
    /// under the breadcrumb.
    @ViewBuilder private var notices: some View {
        let missing = loaded && !failed && exhausted
        // fix/show-all: a page that couldn't be opened goes quiet in its entry; no banner.
        if failed || missing {
            VStack(alignment: .leading, spacing: 8) {
                if failed {
                    FocusDetailNotice(symbol: "exclamationmark.triangle", text: Self.failedText, retry: { load(moment) })
                } else if missing {
                    FocusDetailNotice(symbol: "info.circle", text: Self.missingText)
                }
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
        }
    }

    private var canOpen: Bool { browser.reopenCanonical != nil || browser.openApp != nil }

    /// Another moment starts over; the same moment with other member actions (a refresh) reads again.
    private func momentChanged(_ next: MomentSlice) {
        // Even a same-ID update invalidates a pending source read's selected scope.
        if sourceVisible, NSApplication.shared.isActive { loadSource(next) } else { clearSource() }
        if next.id != readFor?.id {
            probe?.detailMomentID = next.id
            limit = Self.firstPage; actions = []; complete = false; exhausted = false; loaded = false; failed = false
            unavailable = []; openFailed = false
            load(next)
        } else if next.actionIDs != readFor?.actionIDs {
            load(next)
        }
    }

    private func load(_ target: MomentSlice) {
        generation += 1
        readFor = (target.id, target.actionIDs)
        let ticket = generation, wanted = limit
        let members = Set(target.actionIDs).count
        let resolver = MomentResolver(cache: browser.dayCache, calendar: browser.calendar)
        Task { @MainActor in
            do {
                let found = try await resolver.memberActions(of: target, limit: wanted)
                guard ticket == generation else { return }
                actions = found.actions
                complete = found.complete
                let typedIDs = found.actions.filter { $0.kind == "keyboard.text_input" }.map(\.id)
                if let loader = browser.loadComposeLines, !typedIDs.isEmpty {
                    let lines = await loader(typedIDs)
                    if ticket == generation { composeLines = lines }
                } else { composeLines = [:] }
                let ranOut = Self.isExhausted(found: found.actions.count, complete: found.complete, wanted: wanted, members: members)
                exhausted = ranOut
                failed = false
                loaded = true
                report(target, found.actions, complete: found.complete, exhausted: ranOut, failed: false)
            } catch {
                // What was already shown stays; the notice offers the read again (plan §3).
                guard ticket == generation else { return }
                failed = true
                loaded = true
                report(target, actions, complete: complete, exhausted: exhausted, failed: true)
            }
        }
    }

    private func clearSource() { source.close() }

    /// Hydrate only this selected detail, off-main through the host. Lifecycle
    /// notifications call close; external changes use the bounded metadata watch.
    private func loadSource(_ target: MomentSlice) {
        guard sourceWindow != nil, sourceVisible,
              let loader = browser.loadOwnerSourcePreviews,
              let revision = browser.ownerSourcePreviewRevision else { clearSource(); return }
        source.open(scope: target.dayKey + "|" + target.id, actionIDs: target.actionIDs,
                    load: loader, revision: revision, now: browser.now)
    }

    private func report(_ target: MomentSlice, _ shown: [CanonicalAction], complete: Bool, exhausted: Bool, failed: Bool) {
        guard let probe, probe.detailMomentID == target.id else { return }
        probe.detailActions = Self.chronological(shown)
        probe.detailComplete = complete
        probe.detailFailed = failed
        probe.detailCanLoadMore = Self.canLoadMore(shown: shown.count, complete: complete, exhausted: exhausted)
        probe.detailMissingNote = !failed && exhausted
    }

    /// The order the detail lists actions in: oldest first (as `MomentDetailBody` draws them).
    public static func chronological(_ actions: [CanonicalAction]) -> [CanonicalAction] {
        actions.sorted { (timestamp($0.at) ?? .distantPast, $0.id) < (timestamp($1.at) ?? .distantPast, $1.id) }
    }

    /// A page reopens through `reopenCanonical`, which verifies the original first. A window's app
    /// opens when it can (the row names no page to verify); otherwise the reopen is tried and, failing,
    /// marks the row unavailable.
    private func open(_ action: CanonicalAction) {
        if action.site.isEmpty, !action.bundle.isEmpty, let openApp = browser.openApp {
            openApp(action.bundle)
            return
        }
        guard let reopen = browser.reopenCanonical else {
            unavailable.insert(action.id)
            openFailed = true
            return
        }
        Task { @MainActor in
            do { try await reopen(action.id); openFailed = false }
            catch { unavailable.insert(action.id); openFailed = true }
        }
    }
}

/// Lays its content out at least `minHeight` tall by proposing that height, so the content's flexible
/// parts (the kit's metadata column and its rule) fill it; a frame's `minHeight` inside a scroll view
/// proposes no height, which leaves them at their own.
private struct FocusDetailFill: Layout {
    var minHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let natural = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? natural.width, height: max(natural.height, minHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

/// The detail body's size: it is the whole scroll content (for the checks probe).
private struct FocusDetailBodySize: PreferenceKey {
    static var defaultValue: CGSize { .zero }
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// One line under the breadcrumb, styled as `OriginalUnavailableBanner`: a failed read with `Try Again`,
/// or a note.
private struct FocusDetailNotice: View {
    let symbol: String
    let text: String
    var retry: (() -> Void)?
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.tertiary).accessibilityHidden(true)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let retry {
                Button("Try Again", action: retry).buttonStyle(KitCapsuleButtonStyle(height: 24))
            }
        }
        .padding(.leading, 10).padding(.trailing, retry == nil ? 10 : 6).padding(.vertical, retry == nil ? 8 : 5)
        .frame(minHeight: 34)
        .background(DaydreamStyle.wellFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
