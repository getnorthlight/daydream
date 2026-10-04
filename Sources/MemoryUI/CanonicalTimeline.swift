import AppKit
import Combine
import SwiftUI
import MemoryCore

// The main window's day: the home-C Focus List (spec §3, plan §5 A1, amendments A1). One day at a
// time (`browser.focusedDay`, nil = today): the header (calendar tile, title, day chips), the summary
// card, the live paused row, the Morning/Afternoon/Evening sections of 52 pt rows (one expanded at a
// time) and the pinned key-hint footer. Everything scrolls in `canonical-history` except the footer.
//
// Data comes only through the day cache (plan §4.4): today is `browser.today`, the one read the
// toolbar, menu bar and settings share; any other day is `dayCache.day(key)`. A read that lands after
// the day changed is dropped (generation ticket). The keyboard router owns ↑ ↓ Return Esc ⌘C; menu
// commands arrive on `browser.commands`; the selection's menu state goes to `browser.commandContext`
// while Recall is not visible. No key equivalent with modifiers is bound here (plan §7).
//
// A row another surface expands (Recall's Show in <Weekday>, the menu bar's latest moment) is scrolled
// into view once it lays out, over the day's remembered offset. A failed action's notice shows where
// the action was taken: inside the expanded card when it ran on the expanded moment, else above the
// list; either way it is scrolled into view.

public struct CanonicalTimeline: View {
    @ObservedObject var browser: ActivityBrowser
    @ObservedObject private var today: TodayDigest
    @ObservedObject private var cache: DaydreamDayCache
    /// The shell's recording state and actions (plan §4.7): the live paused row and the ribbon's live state.
    private let shell: (state: CapturePresentation, actions: CaptureActions)?
    @Environment(\.daydreamNow) private var fixedNow
    @Environment(\.daydreamStatic) private var isStatic
    @Environment(\.daydreamPasteboard) private var pasteboard
    @Environment(\.daydreamFocusListProbe) private var probe
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var box = FocusListBox()
    /// The focused past day's read and snapshot (today's lives in `browser.today`).
    @State private var past: FocusPastDay?
    /// The past day whose latest read failed.
    @State private var pastFailed: String?
    /// The moment whose pushed detail covers the list.
    @State private var detailID: String?
    /// claude/messages2-1003: the card the detail was opened from (its members' IDs): the page shows the whole card.
    @State private var detailMembers: [String] = []
    /// The moment lit across the day card's ribbon and the rows: the one under the pointer in either.
    /// Objects the list itself doesn't observe (fix/scroll-perf): a hover redraws the day card or the row cards, not the
    /// whole day, so moving the pointer (or scrolling rows under it) stays cheap.
    @State private var litMoment = FocusHover()
    @State private var ribbonMoment = FocusHover()
    @State private var scrollTarget: String?
    @State private var notice: FocusNotice?
    /// The expanded moment whose card shows `notice` (the failed action ran on it); nil: above the list.
    @State private var noticeMoment: String?
    @State private var forgetRequest: MomentForgetRequest?
    @State private var excludeRequest: ExcludeAppRequest?
    @State private var excludeSiteRequest: ExcludeSiteRequest?
    @State private var correction: FocusCorrection?
    @State private var correctionText = ""

    public init(browser: ActivityBrowser) { self.init(browser: browser, shell: nil) }
    /// The shell's entry point (plan §4.7).
    public init(browser: ActivityBrowser, state: CapturePresentation, actions: CaptureActions) {
        self.init(browser: browser, shell: (state, actions))
    }
    private init(browser: ActivityBrowser, shell: (state: CapturePresentation, actions: CaptureActions)?) {
        self.browser = browser
        _today = ObservedObject(wrappedValue: browser.today)
        _cache = ObservedObject(wrappedValue: browser.dayCache)
        self.shell = shell
    }

    /// The column's maximum width; it centres in wider windows.
    static let columnWidth: CGFloat = 920
    /// Below this column width the chips show 3 days, the stats become a capsule row and the chip slot narrows.
    static let narrowWidth: CGFloat = 760

    // MARK: Day

    private var calendar: Calendar { browser.calendar }
    private var now: Date { fixedNow ?? browser.now() }
    private var todayKey: String { cache.todayKey ?? FocusDay.key(now, calendar) ?? "" }
    /// The focused day, never later than today.
    private var dayKey: String {
        guard let focused = browser.focusedDay, !focused.isEmpty else { return todayKey }
        return todayKey.isEmpty ? focused : min(focused, todayKey)
    }
    private var recordingState: RecordingState? { shell?.state.state }

    private func snapshot(for key: String) -> TodaySnapshot? {
        if key == todayKey { return today.snapshot?.dayKey == key ? today.snapshot : nil }
        return past?.key == key ? past?.snapshot : nil
    }
    private func failed(_ key: String) -> Bool { key == todayKey ? today.failed : pastFailed == key }
    private func dayDate(_ key: String) -> Date { FocusDay.date(key, calendar) ?? now }

    /// Rows in display order (the order ↑/↓ walk).
    private var rows: [MomentSlice] {
        let snap = snapshot(for: dayKey)
        return FocusListLayout.order(FocusListLayout.sections(snap?.moments ?? [], blocks: snap?.levels?.blocks ?? [], calendar: calendar))
    }
    private var selectedMoment: MomentSlice? {
        guard let id = browser.selectedMomentID else { return nil }
        return snapshot(for: dayKey)?.moments.first { $0.id == id }
    }
    private var motion: Animation? { reduceMotion || isStatic ? nil : .easeInOut(duration: 0.16) }
    /// perf-1005 (owner 10/4, "clicking cards is glitchy" on big days): a card opens and closes at once on a day of more
    /// than `animatedOpenLimit` moments. Animated, every row below moved each frame of the 0.16 s, each move handed every
    /// row's frame to the list and re-anchored the scroll (12-15 rounds per click on a 276-moment day, about 3 without),
    /// on a list too long to draw a frame in time.
    private var expandMotion: Animation? {
        (snapshot(for: dayKey)?.moments.count ?? 0) > Self.animatedOpenLimit ? nil : motion
    }
    public static let animatedOpenLimit = 60
    /// fix/day-nav: the day's content fade; none with Reduce Motion.
    private var dayFade: Animation? { reduceMotion || isStatic ? nil : .easeOut(duration: DayNavigation.fadeDuration) }

    // MARK: Body

    public var body: some View {
        let key = dayKey
        let snap = snapshot(for: key)
        let detail = detailID.flatMap { id in snap?.moments.first { $0.id == id } }.map { anchor in
            FocusAppCard.detailMoment(anchor, members: detailMembers.compactMap { id in snap?.moments.first { $0.id == id } })
        }
        box.track(key)
        box.preferVisibleAnchor([browser.expandedMomentID, browser.selectedMomentID].compactMap { $0 })
        return GeometryReader { geo in
            ZStack(alignment: .top) {
                list(key: key, snapshot: snap, width: geo.size.width)
                    .opacity(detail == nil ? 1 : 0)
                    .allowsHitTesting(detail == nil)
                    .accessibilityHidden(detail != nil)
                if let detail {
                    FocusListDetail(moment: detail, browser: browser,
                                    backTitle: DaydreamFormat.dayHeader(dayDate(key), now: now, calendar: calendar),
                                    onBack: popDetail)
                        .accessibilityIdentifier("canonical-app-detail")
                }
            }
        }
        .font(DaydreamType.body)
        // The day card's ribbon spans: secondary click offers the row's actions (the same items as its context menu).
        .environment(\.daydreamRibbonMenu, ribbonMenu(snap))
        // Click-to-reference: the lit moments (rows and spans) and the lines' click handler.
        .environment(\.daydreamReferenced, referenced(key: key, snap: snap).map(Set.init))
        .environment(\.daydreamReferenceClick, box.referenceClick(to: { referenceClick($0) }))
        .background(MomentReferenceMonitor(active: browser.reference != nil) { byMouseDown in
            guard browser.reference != nil else { return }
            withAnimation(ReferenceStyle.animation(reduceMotion: reduceMotion || isStatic)) {
                browser.reference = browser.referenceState.cleared(browser.reference, byMouseDown: byMouseDown)
            }
        })
        .daydreamKeyRouter(enabled: !browser.recallVisible && detail == nil) { handleKey($0) }
        .onAppear { appear() }
        .onChange(of: key) { next in
            // A highlight belongs to its day: another day drops it (no stale dimming).
            if let r = browser.reference, r.day != next { browser.reference = nil }
            dayChanged(next)
        }
        .onChange(of: snap) { snapshotChanged($0) }
        .onChange(of: browser.selectedMomentID) { _ in recordSelection(); writeContext() }
        .onChange(of: detailID) { _ in writeContext() }
        .onChange(of: browser.contextRevealSerial) { _ in
            popDetail()
            // A repeated request can keep every selected/reference id unchanged after the person scrolls away.
            // Requeue the original child; the box waits for its frame when the day/session is still laying out.
            if let id = browser.expandedMomentID ?? browser.selectedMomentID { box.reveal(id, animated: false) }
            writeContext()
        }
        .onChange(of: browser.expandedMomentID) { expansionChanged($0) }
        .onChange(of: browser.recallVisible) { _ in writeContext() }
        // fix/day-card: only what the page draws from it (never every download tick).
        .onChange(of: browser.summaries.drawn) { _ in rebuildPast(); writeContext() }
        .onChange(of: browser.exclusions) { _ in writeContext() }
        .onChange(of: browser.selectedCanonicalActivity) { openCanonical($0) }
        .onReceive(browser.commands) { command($0) }
        .onReceive(cache.invalidated) { key in
            // fix/day-nav: a changed day's kept projection is never shown again.
            box.projections.drop(key)
            invalidated(key)
        }
        // fix/prompt-row: the focused past day's asks, patched in when they change (today's are TodayDigest's).
        .onReceive(browser.momentPrompts.changed) { pastPromptsChanged($0) }
        .sheet(isPresented: Binding(get: { correction != nil }, set: { if !$0 { correction = nil } })) {
            CorrectionSheet(text: $correctionText, error: correction?.error, cancel: { correction = nil }, save: saveCorrection)
        }
        .forgetRangeSheet(browser: browser, isPresented: $browser.forgetRangePresented)
        .momentForgetConfirmation(browser: browser, request: $forgetRequest,
                                  onForgotten: { id in if detailID == id { popDetail() } },
                                  onError: { notice = .message($0) })
        .excludeAppConfirmation(browser: browser, request: $excludeRequest,
                                onError: { notice = .message(Self.excludeFailureMessage($0)) })
        .excludeSiteConfirmation(browser: browser, request: $excludeSiteRequest,
                                 onError: { notice = .message(Self.excludeFailureMessage($0)) })
        // Any notice that appears (a bar action's through `report`, or a confirmation's error) is scrolled into view.
        .onChange(of: notice) { next in if next != nil { revealNotice() } }
        .onAppear {
            probe?.point = { [litMoment, ribbonMoment, box] id, onRibbon in
                if onRibbon { if ribbonMoment.id != id { ribbonMoment.id = id } } else { box.hover(id, into: litMoment) }
            }
        }
    }

    private func list(key: String, snapshot snap: TodaySnapshot?, width: CGFloat) -> some View {
        let referenceIDs = referenced(key: key, snap: snap)
        let compact = width < Self.compactWidth
        let side: CGFloat = compact ? 16 : 24
        // Narrow is about the column, not the window: 792 pt leaves a 744 pt column (home-C-narrow).
        let narrow = min(Self.columnWidth, width - 2 * side) < Self.narrowWidth
        return VStack(spacing: 0) {
            ScrollViewReader { _ in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        // "DayDream Preview": one small line over the day, the only thing it adds.
                        if let line = browser.previewLine {
                            Text(line).font(.system(size: 11.5)).foregroundStyle(.secondary)
                                .padding(.leading, 8).padding(.bottom, 8)
                                .accessibilityIdentifier("preview-line")
                        }
                        FocusListHeader(day: dayDate(key), dayKey: key, now: now, calendar: calendar,
                                        chips: FocusListHeader.chipModels(keys: chipKeys(key, count: 5),
                                                                          digests: cache.digests, calendar: calendar),
                                        narrow: narrow,
                                        recorded: Set(cache.digests.filter { $0.value.momentCount > 0 }.keys),
                                        onShowDays: { cache.loadDigests($0) },
                                        onSelectDay: { goToDay($0) }, onJump: { jump(to: $0) })
                        // fix/day-nav: a day's content fades in (0.15 s) when it arrives; the old day goes at once.
                        VStack(alignment: .leading, spacing: 0) {
                            day(key: key, snapshot: snap, narrow: narrow, compact: compact)
                                .id(FocusDayFace(key: key, loaded: snap != nil))
                                .transition(.asymmetric(insertion: .opacity, removal: .identity))
                        }
                        .animation(dayFade, value: FocusDayFace(key: key, loaded: snap != nil))
                        .padding(.top, 18)
                    }
                    .frame(maxWidth: Self.columnWidth)
                    .padding(.horizontal, side)
                    .padding(.top, 14).padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: FocusRowFrames.self, value: [FocusRowFrames.contentKey: CGRect(origin: .zero, size: g.size)])
                    })
                    .coordinateSpace(name: FocusRowFrames.space)
                    .onPreferenceChange(FocusRowFrames.self) { frames in
                        probe?.rowFrameUpdates += 1
                        box.rowsMoved(frames)
                        probe?.rowFrames = frames.filter { ![FocusRowFrames.contentKey, FocusRowFrames.noticeKey].contains($0.key) }
                        probe?.noticeFrame = frames[FocusRowFrames.noticeKey]
                    }
                    .background(FocusScrollProbe(box: box).accessibilityHidden(true))
                }
                .accessibilityIdentifier("canonical-history")
                // Resolve again when a deferred day/block read lands. The box waits for the original child
                // frame after its containing session opens; it also follows the document while layout settles.
                .onChange(of: referenceIDs) { ids in
                    if let first = ids?.first { box.reveal(first, animated: motion != nil) }
                    else { box.cancelReveal(unless: browser.expandedMomentID) }
                }
                .onAppear {
                    if let first = referenceIDs?.first { box.reveal(first, animated: false) }
                }
                .onChange(of: scrollTarget) { target in
                    guard let target else { return }
                    box.reveal(target, animated: false)
                    scrollTarget = nil
                }
            }
            // No key-hint footer (declutter): the menus show every shortcut.
        }
    }

    /// Below this width the list is compact: the rows' chip slot is hidden and the sides narrow.
    public static let compactWidth: CGFloat = 600

    @ViewBuilder
    private func day(key: String, snapshot snap: TodaySnapshot?, narrow: Bool, compact: Bool) -> some View {
        let isToday = key == todayKey
        if let snap {
            VStack(alignment: .leading, spacing: 0) {
                // A reread of today failed: say so above the last good read instead of hiding it.
                if failed(key) {
                    FocusListFailureCard(isToday: isToday, compact: true, retry: refresh).padding(.bottom, 12)
                }
                if FocusListLayout.showsEmptyCard(snap, isToday: isToday) {
                    FocusListEmptyCard(isToday: isToday, state: isToday ? recordingState : nil, dayKey: key, calendar: calendar)
                    // The live pause sits where it does on a day with moments: at the top of the list, under the day's card.
                    if isToday, let paused = pausedRow { paused.padding(.top, 22) }
                } else {
                    FocusHoverReader(hover: litMoment) { litMoment in
                    FocusListSummaryCard(snapshot: snap, day: FocusDay.word(key, today: todayKey, calendar: calendar, now: now),
                                         dayNote: dayNote(key), isToday: isToday, state: isToday ? recordingState : nil, narrow: narrow,
                                         calendar: calendar, openSummarySettings: summarySettings,
                                         linked: litMoment ?? browser.expandedMomentID,
                                         onRibbonHover: { [ribbonMoment] id in if ribbonMoment.id != id { ribbonMoment.id = id } },
                                         sample: browser.previewLine != nil, fixSummaries: browser.fixSummaries)
                    }
                    noticeView
                    // A partial day says so in the summary card, under its count (as the popover and the menu bar do).
                    sections(snap, isToday: isToday, narrow: narrow, compact: compact)
                }
            }
        } else if failed(key) {
            FocusListFailureCard(isToday: isToday, retry: refresh)
        } else {
            // The card's place for the first read: its shell and ribbon track, and (fix/day-nav) the day's rows as
            // placeholders, as many as its cached count says (no spinner, nothing animates).
            FocusSummarySkeleton(rows: DayNavigation.skeletonRows(momentCount: cache.digests[key]?.momentCount))
        }
    }

    @ViewBuilder
    private func sections(_ snap: TodaySnapshot, isToday: Bool, narrow: Bool, compact: Bool) -> some View {
        // summaries/v3 levels: blocks replace the day parts once written (moments no block holds keep their part).
        let sections = FocusListLayout.sections(snap.moments, blocks: snap.levels?.blocks ?? [], calendar: calendar)
        let paused = isToday ? pausedRow.map { AnyView($0) } : nil
        if sections.isEmpty {
            if let paused { paused.padding(.top, 22) }
        } else {
            let context = rowContext(narrow: narrow, compact: compact)
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                VStack(alignment: .leading, spacing: 8) {
                    if let block = section.block {
                        // A block fills the same header: its goal, its moment count and its time range.
                        SectionHeader(block.name, count: section.moments.count,
                                      detail: DaydreamFormat.range(block.start, block.end, calendar.timeZone))
                            .accessibilityLabel(FocusListLayout.blockHeaderAccessibilityLabel(block, count: section.moments.count,
                                                                                               timeZone: calendar.timeZone))
                        // Threads: what else ran through the block, with names and minutes, in one quiet line.
                        if !block.sideThreads.isEmpty {
                            Text(FocusListLayout.sideThreadsLine(block))
                                .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 8).padding(.top, -3)
                        }
                    } else {
                    // The part's name only: every row shows its own time, and the rows are there to count.
                    SectionHeader(section.part)
                    }
                    FocusHoverReader(hover: ribbonMoment) { linked in
                        FocusListRowsCard(moments: section.moments, paused: index == 0 ? paused : nil, context: context.linking(linked), sectionID: section.id)
                    }
                }
                .padding(.top, index == 0 ? 22 : 18)
            }
        }
    }

    private func rowContext(narrow: Bool, compact: Bool) -> FocusListRowContext {
        let caps = MomentActions.Capabilities(browser: browser)
        return FocusListRowContext(
            timeZone: calendar.timeZone, selectedID: browser.selectedMomentID, expandedID: browser.expandedMomentID,
            narrow: narrow, compact: compact,
            items: { MomentActions.items(for: $0, context: .focusList, browser: caps) },
            toggle: { toggle($0) },
            perform: { perform($0, $1) },
            expandedBody: { m, members in
                AnyView(FocusListExpanded(moment: m, members: members, browser: browser, wide: !narrow,
                                          notice: members.contains { noticeMoment == $0.id } ? cardNotice : nil,
                                          perform: { perform($0, m) }, performOn: { perform($0, $1) }, showAll: { pushDetail(m, members: members) }))
            },
            siteItems: { MomentActions.siteRequests(for: $0, browser: caps) },
            excludeSite: { excludeSiteRequest = $0 },
            forgetRange: browser.canForgetRange ? { [browser] in browser.forgetRangePresented = true } : nil,
            onHover: { [litMoment, box] id in box.hover(id, into: litMoment) },
            caps: caps, updating: browser.updatingMoments)
    }

    /// The live pause (today only): `Paused until 4:36 PM · Resume`. Nothing for any other state.
    private var pausedRow: FocusListPausedRow? {
        guard let shell, let pause = FocusListPausedRow.pause(in: shell.state.state) else { return nil }
        return FocusListPausedRow(until: pause.until, now: now, timeZone: calendar.timeZone,
                                  canResume: shell.state.canResume, resume: shell.actions.resume)
    }

    /// `Summaries are off · Turn On in Settings` opens Settings ▸ Summaries.
    private var summarySettings: (() -> Void)? {
        if let open = browser.openSettingsSection { return { open("Summaries") } }
        if let shell { return { shell.actions.openSettingsSection("Summaries") } }
        return nil
    }

    /// A notice not tied to the expanded card, above the rows. It reports its frame so it can be
    /// scrolled into view.
    @ViewBuilder private var noticeView: some View {
        if noticeMoment == nil, let banner = noticeBanner {
            banner
                .background(GeometryReader { g in
                    Color.clear.preference(key: FocusRowFrames.self, value: [FocusRowFrames.noticeKey: g.frame(in: .named(FocusRowFrames.space))])
                })
                .padding(.top, 12)
        }
    }

    /// The notice for the expanded card that owns it (drawn above its action bar).
    private var cardNotice: AnyView? { noticeMoment == nil ? nil : noticeBanner }

    private var noticeBanner: AnyView? {
        switch notice {
        case .originalUnavailable?: return AnyView(OriginalUnavailableBanner { clearNotice() })
        case .message(let text)?: return AnyView(FocusNoticeBanner(text: text) { clearNotice() })
        case nil: return nil
        }
    }

    /// Shows a failed action's notice where the person is looking: in the moment's card when the action
    /// ran on the expanded moment (its bar, its VoiceOver actions, a menu command), else above the list.
    /// Either way the list scrolls it into view (the card by its bottom, where the bar and notice are).
    private func report(_ next: FocusNotice, on momentID: String?) {
        let again = notice == next
        noticeMoment = momentID.flatMap { $0 == browser.expandedMomentID ? $0 : nil }
        notice = next
        // The same notice raised again changes nothing `onChange` sees: reveal it here.
        if again { revealNotice() }
    }

    /// Scrolls the notice into view: the card that owns it by its bottom, else the notice above the list.
    private func revealNotice() {
        box.reveal(noticeMoment ?? FocusRowFrames.noticeKey, bottom: noticeMoment != nil, animated: motion != nil)
    }

    private func clearNotice() {
        notice = nil
        noticeMoment = nil
    }

    // MARK: Loading

    private func appear() {
        if box.selectionKey == nil {
            box.selectionKey = dayKey
            box.recorded = liveSelection
        }
        today.refreshIfStale()
        if dayKey != todayKey { loadPast(dayKey) } else { prefetchNeighbours(of: dayKey) }
        loadChips(dayKey)
        // Which days have records: Previous/Next Day step between them.
        cache.loadRecordedDays()
        if let id = browser.selectedCanonicalActivity { openCanonical(id) }
        // A moment handed over before the list appeared (the menu bar opening the window on its latest moment).
        if let expanded = browser.expandedMomentID { box.reveal(expanded, animated: false) }
        writeContext()
    }

    private func chipKeys(_ key: String, count: Int) -> [String] {
        todayKey.isEmpty ? [] : FocusListHeader.chipKeys(focused: key, today: todayKey, count: count, calendar: calendar)
    }
    private func loadChips(_ key: String) {
        cache.loadDigests(Array(Set(chipKeys(key, count: 5) + chipKeys(key, count: 3))))
    }

    /// Reads a past day through the cache (fix/day-nav). A day projected moments ago (or prefetched) shows at once,
    /// with no work on the click; otherwise the header shows over a skeleton while the day is read and projected off the
    /// main thread. Rapid clicks coalesce: only the day they stop on is read. A read that lands after the focus moved on
    /// is dropped (generation ticket) and the superseded load is cancelled.
    private func loadPast(_ key: String, force: Bool = false) {
        guard key != todayKey else { return }
        box.generation += 1
        let ticket = box.generation
        box.loadTask?.cancel()
        let clicked = Date()
        let rapid = DayNavigation.isRapid(previous: box.lastLoad, now: clicked)
        box.lastLoad = clicked
        var shown = false
        if !force, let hit = box.projections.projection(key, stamp: projectionStamp(key)) {
            showPast(hit.day, snapshot: hit.snapshot, key: key)
            shown = true
        } else if isStatic, !force, let cached = cache.cachedDay(key) {
            // Checks and still renders draw in one pass: the cached read is projected at once, as before.
            setPast(cached, key: key)
            shown = true
        } else if past?.key != key { past = nil }
        let cached = force || shown ? nil : cache.cachedDay(key)
        box.loadTask = Task { @MainActor in
            if rapid && !shown { try? await Task.sleep(nanoseconds: DayNavigation.settleDelay) }
            guard !Task.isCancelled, ticket == box.generation else { return }
            // The cached read shows first (projected off the main thread); a fresher read replaces it below.
            if let cached { await projectPast(cached, key: key, ticket: ticket) }
            do {
                let day = try await cache.day(key, force: force)
                guard !Task.isCancelled, ticket == box.generation else { return }
                await projectPast(day, key: key, ticket: ticket)
                guard ticket == box.generation else { return }
                if pastFailed == key { pastFailed = nil }
                // fix/prompt-row: each read of the day opens its asks again, off the main thread.
                if let moments = past?.key == key ? past?.snapshot.moments : nil { browser.momentPrompts.reload(key, moments: moments) }
                prefetchNeighbours(of: key)
            } catch {
                guard ticket == box.generation else { return }
                pastFailed = key
            }
        }
    }

    /// What a projection of `key` is built from now: the cache's read of it and the summaries state.
    private func projectionStamp(_ key: String) -> DayProjectionStamp {
        DayProjectionStamp(loadedAt: cache.loadedAt(key), summaries: browser.summaries, bundleNames: cache.bundleNames.count)
    }

    /// Projects `day` off the main thread (or takes the kept projection of the same read) and shows it while `ticket` holds.
    private func projectPast(_ day: ActionDay, key: String, ticket: Int) async {
        let stamp = projectionStamp(key)
        if let hit = box.projections.projection(key, stamp: stamp) {
            if ticket == box.generation { showPast(hit.day, snapshot: hit.snapshot, key: key) }
            return
        }
        let snap = await DayProjectionCache.project(day: day, summaries: browser.summaries, calendar: calendar,
                                                    now: cache.loadedAt(key) ?? now, bundleNames: cache.bundleNames)
        // Kept only for a stored read: a superseded read's projection would never match again.
        if stamp.loadedAt != nil, stamp == projectionStamp(key) { box.projections.store(key, day: day, snapshot: snap, stamp: stamp) }
        guard ticket == box.generation else { return }
        showPast(day, snapshot: snap, key: key)
    }

    private func showPast(_ day: ActionDay, snapshot: TodaySnapshot, key: String) {
        let snap = snapshot.withPrompts(browser.momentPrompts.prompts(key))
        if past?.key != key || past?.snapshot != snap { past = FocusPastDay(key: key, day: day, snapshot: snap) }
    }

    /// Reads and projects the previous and next recorded days in the background, so the next click swaps at once.
    private func prefetchNeighbours(of key: String) {
        let keys = DayNavigation.neighbours(of: key, today: todayKey, recorded: cache.recordedDays, calendar: calendar)
        box.prefetchTask?.cancel()
        guard !keys.isEmpty else { return }
        box.prefetchTask = Task(priority: .utility) { @MainActor in
            for next in keys {
                guard !Task.isCancelled else { return }
                guard let day = try? await cache.day(next), !Task.isCancelled else { continue }
                let stamp = projectionStamp(next)
                guard stamp.loadedAt != nil, !box.projections.contains(next, stamp: stamp) else { continue }
                let snap = await DayProjectionCache.project(day: day, summaries: browser.summaries, calendar: calendar,
                                                            now: stamp.loadedAt ?? now, bundleNames: cache.bundleNames)
                if stamp == projectionStamp(next) { box.projections.store(next, day: day, snapshot: snap, stamp: stamp) }
            }
        }
    }

    private func setPast(_ day: ActionDay, key: String) {
        let snap = TodaySnapshot.make(day: day, summaries: browser.summaries, calendar: calendar,
                                      now: cache.loadedAt(key) ?? now, bundleNames: cache.bundleNames)
            .withPrompts(browser.momentPrompts.prompts(key))
        if past?.key != key || past?.snapshot != snap { past = FocusPastDay(key: key, day: day, snapshot: snap) }
    }

    /// fix/prompt-row: the past day's prompts changed (opened, or dropped with its memory): patched, never rebuilt.
    private func pastPromptsChanged(_ key: String?) {
        guard let past, key == nil || key == past.key else { return }
        let snap = past.snapshot.withPrompts(browser.momentPrompts.prompts(past.key))
        if snap != past.snapshot { self.past = FocusPastDay(key: past.key, day: past.day, snapshot: snap) }
    }

    private func rebuildPast() {
        if let past { setPast(past.day, key: past.key) }
    }

    /// The day note's real state, from the read the day's snapshot came from. The snapshot drops a ready
    /// note whose title is the writer's generic "Day summary"; that note is still ready, never pending.
    private func dayNote(_ key: String) -> FocusDayNote {
        let day = key == todayKey ? cache.cachedDay(key) : (past?.key == key ? past?.day : nil)
        guard let day, day.summary.day == key else { return box.dayNotes[key] ?? .unknown }
        let note = FocusDayNote.make(day)
        box.dayNotes[key] = note
        return note
    }

    /// A write changed a day (or every day): reread the focused past day. Today follows on its own.
    private func invalidated(_ key: String?) {
        let focused = dayKey
        guard focused != todayKey, key == nil || key == focused else { return }
        loadPast(focused)
    }

    private func refresh() {
        clearNotice()
        if dayKey == todayKey { today.refresh(force: true) } else { loadPast(dayKey, force: true) }
    }

    private func dayChanged(_ key: String) {
        // The row lit from the ribbon belongs to the day we left (review P2: a stale lit moment dimmed every span).
        litMoment.id = nil
        // Selection and expansion are remembered per day, so ⌘[ then ⌘] comes back to the same row.
        let live = liveSelection
        if let old = box.selectionKey, old != key {
            let next: FocusSelection?
            if live == box.recorded {
                // The ids still belong to the day we left: keep them there and bring back the new day's.
                box.selections[old] = live
                next = box.handoff ?? box.selections[key]
            } else {
                // Another surface wrote the ids with the day (Recall's Show in <Weekday>, the menu bar's
                // latest moment): they are the new day's. The day we left keeps what it last showed; an id
                // that wasn't rewritten is the old day's and is dropped (a lone expansion also selects).
                box.selections[old] = box.recorded
                let expanded = live.expanded != box.recorded.expanded ? live.expanded : nil
                next = FocusSelection(selected: live.selected != box.recorded.selected ? live.selected : expanded, expanded: expanded)
            }
            box.handoff = nil
            box.selectionKey = key
            setSelection(next ?? FocusSelection())
        }
        box.selectionKey = key
        box.recorded = liveSelection
        if let snap = snapshot(for: key) { validateSelection(snap) }
        clearNotice()
        if key == todayKey { today.refreshIfStale(); prefetchNeighbours(of: key) } else { loadPast(key) }
        loadChips(key)
        DispatchQueue.main.async { box.applyRestore(loaded: false) }
        writeContext()
    }

    private func snapshotChanged(_ snap: TodaySnapshot?) {
        guard let snap, snap.dayKey == dayKey else { return }
        let ids = Set(snap.moments.map(\.id))
        // The ids are this day's only once the day change handed them over (it validates then).
        if box.selectionKey == snap.dayKey { validateSelection(snap) }
        if let id = detailID, !ids.contains(id) { popDetail() }
        // A detail asked for before its day loaded opens only while it is still asked for.
        if let pending = box.pendingDetail, ids.contains(pending) {
            box.pendingDetail = nil
            if browser.selectedCanonicalActivity == pending { show(pending) }
        }
        DispatchQueue.main.async { box.applyRestore(loaded: true) }
        writeContext()
    }

    /// Keeps the selection and expansion on moments of `snap`. A refresh that dropped the selected moment
    /// (merged, forgotten) selects the one nearest its start; an id the day never had is cleared (a handed-over
    /// expansion keeps the selection with it). A stale read of today (older than the cache's `todayMaxAge`
    /// on the data clock) may predate a moment another surface handed over, so such an id waits for the
    /// reread (`refreshIfStale`) before it is dropped.
    private func validateSelection(_ snap: TodaySnapshot) {
        let ids = Set(snap.moments.map(\.id))
        let settled = snap.dayKey != todayKey || cache.now().timeIntervalSince(snap.loadedAt) < cache.todayMaxAge
        var next = liveSelection
        if let selected = next.selected, !ids.contains(selected) {
            let nearest = box.starts[snap.dayKey]?[selected].flatMap { FocusListLayout.nearest(to: $0, in: snap.moments)?.id }
            if nearest != nil || settled {
                if next.expanded == selected { next.expanded = nearest }
                next.selected = nearest ?? next.expanded.flatMap { ids.contains($0) ? $0 : nil }
            }
        }
        if let expanded = next.expanded, !ids.contains(expanded), settled { next.expanded = nil }
        box.starts[snap.dayKey] = Dictionary(snap.moments.map { ($0.id, $0.start) }, uniquingKeysWith: { first, _ in first })
        setSelection(next)
    }

    // MARK: Selection bookkeeping

    private var liveSelection: FocusSelection {
        FocusSelection(selected: browser.selectedMomentID, expanded: browser.expandedMomentID)
    }
    /// Remembers the ids as the shown day's, whoever wrote them, once any day change was handled (a write
    /// that came with a day change is sorted out by `dayChanged`).
    private func recordSelection() {
        if box.selectionKey == dayKey { box.recorded = liveSelection }
    }
    private func setSelection(_ next: FocusSelection) {
        if browser.selectedMomentID != next.selected { browser.selectedMomentID = next.selected }
        if browser.expandedMomentID != next.expanded {
            box.ownExpansion = .some(next.expanded)
            browser.expandedMomentID = next.expanded
        }
        recordSelection()
    }

    /// The expansion changed. Written by another surface (Recall's Show in <Weekday>, the menu bar's
    /// latest moment, with or without a day change), the row is scrolled into view once it lays out; the
    /// list's own writes (a click, Return, Esc, a day's remembered row, the detail) reveal only what they
    /// ask for. A notice in a card that closed goes with it.
    private func expansionChanged(_ id: String?) {
        let own = box.ownExpansion == .some(id)
        box.ownExpansion = nil
        recordSelection()
        if let noticeMoment, noticeMoment != id { clearNotice() }
        if let id, !own { box.reveal(id, animated: false) } else { box.cancelReveal(unless: id) }
    }
    private func setSelected(_ id: String?) { setSelection(FocusSelection(selected: id, expanded: browser.expandedMomentID)) }
    private func setExpanded(_ id: String?) { setSelection(FocusSelection(selected: browser.selectedMomentID, expanded: id)) }

    // MARK: Navigation

    /// Moves the focus to `key` (never past today). The detail closes unless `keepDetail`.
    private func goToDay(_ key: String, keepDetail: Bool = false) {
        let target = todayKey.isEmpty ? key : min(key, todayKey)
        guard target != dayKey else { return }
        if !keepDetail { popDetail() }
        browser.focusedDay = target == todayKey ? nil : target
    }

    /// Previous/Next Day: the nearest day with records (`FocusDay.step`), each drawn as Today is.
    private func step(_ direction: Int) {
        guard let key = FocusDay.step(from: dayKey, by: direction, today: todayKey, recorded: cache.recordedDays, calendar: calendar) else { return }
        goToDay(key)
    }

    private func jump(to date: Date) {
        if let key = FocusDay.key(date, calendar) { goToDay(key) }
    }

    private func toggle(_ m: MomentSlice) {
        setSelected(m.id)
        let expanding = browser.expandedMomentID != m.id
        // A row opened near the bottom scrolls just enough to show its card (never its header off the top).
        if expanding { box.reveal(m.id, animated: expandMotion != nil) }
        withAnimation(expandMotion) { setExpanded(expanding ? m.id : nil) }
    }

    private func show(_ id: String) {
        setSelection(FocusSelection(selected: id, expanded: id))
        detailMembers = []
        detailID = id
    }

    private func pushDetail(_ m: MomentSlice, members: [MomentSlice] = []) {
        setSelected(m.id)
        detailMembers = members.map(\.id)
        detailID = m.id
    }

    private func popDetail() {
        detailID = nil
        detailMembers = []
        if browser.selectedCanonicalActivity != nil { browser.selectedCanonicalActivity = nil }
    }

    /// `selectedCanonicalActivity = id` shows that moment's day, expands its row and pushes its detail;
    /// nil pops the detail and drops a request still waiting for its day. An id on no day read so far is
    /// looked for once in a fresh read of the focused day; if it isn't there the request is dropped
    /// (`selectedCanonicalActivity` back to nil), so it never opens later by surprise.
    private func openCanonical(_ id: String?) {
        guard let id else {
            box.pendingDetail = nil
            box.handoff = nil
            detailID = nil
            return
        }
        if snapshot(for: dayKey)?.moments.contains(where: { $0.id == id }) == true {
            box.pendingDetail = nil
            show(id)
            return
        }
        box.pendingDetail = id
        let keys = [todayKey] + cache.digests.keys.sorted(by: >)
        if let key = keys.first(where: { cache.cachedDay($0)?.activities.contains { $0.id == id } == true }), key != dayKey {
            box.handoff = FocusSelection(selected: id, expanded: id)
            goToDay(key, keepDetail: true)
            return
        }
        let key = dayKey
        clearNotice()
        Task { @MainActor in
            let day = try? await cache.day(key, force: true)
            guard box.pendingDetail == id, browser.selectedCanonicalActivity == id, key == dayKey else { return }
            if day?.activities.contains(where: { $0.id == id }) == true {
                // The day's snapshot follows the read; `snapshotChanged` opens the detail.
                if key == todayKey { today.refresh() } else if let day { setPast(day, key: key) }
                if snapshot(for: key)?.moments.contains(where: { $0.id == id }) == true {
                    box.pendingDetail = nil
                    show(id)
                }
                return
            }
            box.pendingDetail = nil
            browser.selectedCanonicalActivity = nil
        }
    }

    // MARK: Keys and commands

    private func handleKey(_ key: DaydreamKey) -> Bool {
        switch key {
        case .up, .down:
            let ids = rows.map(\.id)
            guard !ids.isEmpty else { return false }
            let next: String
            if let selected = browser.selectedMomentID, let i = ids.firstIndex(of: selected) {
                next = ids[key == .down ? min(i + 1, ids.count - 1) : max(i - 1, 0)]
            } else {
                next = key == .down ? ids[0] : ids[ids.count - 1]
            }
            setSelected(next)
            scrollTarget = next
            return true
        case .returnKey:
            guard let m = selectedMoment else { return false }
            toggle(m)
            return true
        case .escape:
            guard browser.expandedMomentID != nil else { return false }
            withAnimation(expandMotion) { setExpanded(nil) }
            return true
        case .copy:
            guard let m = selectedMoment else { return false }
            return copy(m)
        }
    }

    private func command(_ command: DaydreamCommand) {
        guard !browser.recallVisible else { return }
        switch command {
        case .previousDay: step(-1)
        case .nextDay: step(1)
        case .today: goToDay(todayKey)
        case .refresh: refresh()
        case .openOriginal: runSelected([.openOriginal, .openApp])
        case .copySummary: runSelected([.copySummary])
        case .findRelated: runSelected([.findRelated])
        case .forget: runSelected([.forget])
        case .exclude: runSelected([.exclude])
        case .editCorrection: runSelected([.editCorrection])
        case .excludeSite:
            // The Moment menu's "Don't Record <site>…": the selected Chrome moment's first site.
            guard let m = selectedMoment,
                  let request = MomentActions.siteRequests(for: m, browser: MomentActions.Capabilities(browser: browser)).first else { return }
            setSelected(m.id)
            excludeSiteRequest = request
        case .openRecall, .find, .toggleActions, .showInToday: break
        }
    }

    /// The ribbon spans' menu: the Focus List rows' items and actions for the span's moment.
    private func ribbonMenu(_ snap: TodaySnapshot?) -> RibbonMomentMenu {
        var caps = MomentActions.Capabilities(browser: browser)
        // The clock only names the day in the items ("Show in Today"); by day, equal menus stay equal (fix/scroll-perf).
        caps.now = caps.calendar.startOfDay(for: caps.now)
        let moments = snap?.moments ?? [], index = box
        // By position, not a scan (fix/scroll-perf): every span's menu looks its moment up each time the ribbon draws.
        func moment(_ id: String) -> MomentSlice? { index.moment(id, in: moments) }
        return RibbonMomentMenu(items: { id in moment(id).map { MomentActions.items(for: $0, context: .focusList, browser: caps) } ?? [] },
                                sites: { id in moment(id).map { MomentActions.siteRequests(for: $0, browser: caps) } ?? [] },
                                perform: { action, id in if let m = moment(id) { perform(action, m) } },
                                excludeSite: { excludeSiteRequest = $0 },
                                select: { id in
                                    guard let snap else { return }
                                    referenceClick(MomentReference.span(id, day: snap.dayKey, levels: snap.levels))
                                },
                                revision: box.ribbonMenuRevision(RibbonMenuInputs(caps: caps, snap: snap)))
    }

    /// The moments the current reference lights on this day, in the day's order; nil when nothing is referenced here.
    private func referenced(key: String, snap: TodaySnapshot?) -> [String]? {
        guard let r = browser.reference, r.day == key, let snap else { return nil }
        let ids = r.resolved(in: snap.levels, order: snap.moments.map(\.id))
        return ids.isEmpty ? nil : ids
    }

    /// A click on a line or span: lights its moments (or clears them when it is the lit one), with ~250 ms of motion.
    private func referenceClick(_ next: MomentReference) {
        withAnimation(ReferenceStyle.animation(reduceMotion: reduceMotion || isStatic)) {
            browser.reference = browser.referenceState.click(next, current: browser.reference)
        }
    }

    /// Runs the first of `ids` the selected moment offers enabled (the menus' rules).
    private func runSelected(_ ids: [MomentActionID]) {
        guard let m = selectedMoment else { return }
        let items = MomentActions.items(for: m, context: detailID == nil ? .focusList : .focusListDetail,
                                        browser: MomentActions.Capabilities(browser: browser))
        guard let item = items.first(where: { ids.contains($0.id) && $0.enabled }) else { return }
        perform(item.id, m)
    }

    private func writeContext() {
        guard !browser.recallVisible else { return }
        let next = DaydreamCommandContext.make(selection: selectedMoment, context: detailID == nil ? .focusList : .focusListDetail,
                                               capabilities: MomentActions.Capabilities(browser: browser), recallVisible: false)
        if browser.commandContext != next { browser.commandContext = next }
    }

    // MARK: Actions

    private func perform(_ id: MomentActionID, _ m: MomentSlice) {
        setSelected(m.id)
        switch id {
        case .openOriginal: openOriginal(m)
        case .openApp: if let bundle = m.primaryBundle { browser.openApp?(bundle) }
        case .copySummary: copy(m)
        case .findRelated: findRelated(m)
        case .editCorrection: editCorrection(m)
        case .summarizeNow: summarize(m)
        case .forget: forgetRequest = MomentForgetRequest(moment: m, timeZone: calendar.timeZone)
        case .exclude: excludeRequest = ExcludeAppRequest(moment: m)
        case .openMoment: pushDetail(m)
        case .showInToday: break
        }
    }

    /// Copy Summary: only a moment with a summary (or a correction) copies anything (L13).
    @discardableResult private func copy(_ m: MomentSlice) -> Bool {
        guard let text = FocusListLayout.copyText(m) else { return false }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return true
    }

    /// Opens the moment's latest action with an original (a page first, else an app window).
    private func openOriginal(_ m: MomentSlice) {
        guard let reopen = browser.reopenCanonical else { return }
        let resolver = MomentResolver(cache: cache, calendar: calendar)
        Task { @MainActor in
            do {
                let found = try await resolver.memberActions(of: m, limit: m.actionIDs.count)
                guard let target = found.actions.last(where: { !$0.site.isEmpty }) ?? found.actions.last(where: { !$0.bundle.isEmpty })
                else { throw MemError.missing }
                try await reopen(target.id)
                if notice == .originalUnavailable { clearNotice() }
            } catch {
                report(.originalUnavailable, on: m.id)
            }
        }
    }

    /// Find Related Moments (L12): Recall scoped to the moment's site or app.
    private func findRelated(_ m: MomentSlice) {
        guard let filter = MomentActions.relatedFilter(for: m) else { return }
        NotificationCenter.default.post(name: .daydreamRecallFilter, object: browser, userInfo: filter.userInfo)
        browser.recallPresented = true
    }

    private func summarize(_ m: MomentSlice) {
        guard browser.generateCanonicalNote != nil else { return }
        Task { @MainActor in
            // claude/summary-fail-1003: a one-off says nothing here (the card keeps Summarize Now with a quiet line and
            // tries again once by itself); only summaries that are off or broken get a notice, saying what is wrong.
            do { try await browser.summarizeNow(day: m.dayKey, timeZone: calendar.timeZone.identifier, id: m.id, end: m.end) }
            catch {
                if let text = SummarizeNowNotice.banner(for: error, summaries: browser.summaries) { report(.message(text), on: m.id) }
            }
        }
    }

    private func editCorrection(_ m: MomentSlice) {
        Task { @MainActor in
            guard let day = try? await cache.day(m.dayKey), let note = day.activities.first(where: { $0.id == m.id }) else {
                report(.message(FocusNotice.correctionFailed), on: m.id)
                return
            }
            correctionText = note.generated?.output.title ?? note.subject
            correction = FocusCorrection(scope: MemoryActionScope(kind: "activity", id: note.id, day: note.day, timezone: note.timezone),
                                         revision: note.inputRevision)
        }
    }

    private func saveCorrection() {
        do {
            guard let current = correction, let correct = browser.correctCanonical else { throw MemError.missing }
            try correct(current.scope, correctionText, current.revision)
            correction = nil
        } catch {
            correction?.error = FocusNotice.correctionFailed
        }
    }
}

extension CanonicalTimeline {
    /// The Focus List owns its column padding (max 920, centred; 24 pt sides, 16 below 600), so the shell adds none.
    static var shellInsets: EdgeInsets { EdgeInsets() }

    /// What a failed Exclude says: the app's own text (a guard such as "This app is always private.", or the
    /// save status "Not saved. Recording is stopped. Retry."), else the generic line when no hook ran.
    public static func excludeFailureMessage(_ error: Error) -> String {
        if case MemError.invalid(let text) = error, !text.isEmpty { return text }
        return FocusNotice.excludeFailed
    }
}

// MARK: - Pasteboard

private struct DaydreamPasteboardKey: EnvironmentKey {
    static var defaultValue: NSPasteboard { .general }
}

extension EnvironmentValues {
    /// Where Copy Summary writes: the general pasteboard. Checks inject a private `NSPasteboard(name:)`.
    public var daydreamPasteboard: NSPasteboard {
        get { self[DaydreamPasteboardKey.self] }
        set { self[DaydreamPasteboardKey.self] = newValue }
    }
}

// MARK: - Private state

/// Which face of a day the page shows: its skeleton or its content (fix/day-nav: the content fades in).
private struct FocusDayFace: Hashable {
    let key: String
    let loaded: Bool
}

private struct FocusPastDay {
    let key: String
    let day: ActionDay
    let snapshot: TodaySnapshot
}

private struct FocusSelection: Equatable {
    var selected: String?
    var expanded: String?
}

private struct FocusCorrection {
    let scope: MemoryActionScope
    let revision: String
    var error: String?
}

private enum FocusNotice: Equatable {
    case originalUnavailable
    case message(String)

    static let correctionFailed = "Couldn't save your correction. Try again."
    // claude/summary-fail-1003: a failed Summarize Now's notice, if any, is `SummarizeNowNotice.banner` (summaries off or
    // broken, saying what is wrong); a one-off stays in its card, quietly.
    static let excludeFailed = "The app wasn't excluded. Review exclusions in Settings."
}

/// A hovered moment's id, observed only by the views it lights (`FocusHoverReader`), never by the whole list.
@MainActor private final class FocusHover: ObservableObject {
    @Published var id: String?
}

/// Redraws just its content when the hover moves (fix/scroll-perf).
private struct FocusHoverReader<Content: View>: View {
    @ObservedObject var hover: FocusHover
    let content: (String?) -> Content
    init(hover: FocusHover, @ViewBuilder content: @escaping (String?) -> Content) { self.hover = hover; self.content = content }
    var body: some View { content(hover.id) }
}

private extension FocusListRowContext {
    func linking(_ id: String?) -> Self { var c = self; c.linked = id; return c }
}

/// What `CanonicalTimeline.ribbonMenu`'s closures read by value; the rest (`@State`, the browser) they read live.
private struct RibbonMenuInputs: Equatable {
    let caps: MomentActions.Capabilities
    let moments: [MomentSlice]?, dayKey: String?, levels: DayLevelSlice?
    /// Only what the menus read: the moments, the day and its levels (a span's click), and of summaries only whether a
    /// note can be written now (the writer's busy flag and a download's progress change no menu).
    init(caps: MomentActions.Capabilities, snap: TodaySnapshot?) {
        var caps = caps
        caps.summaries = SummaryAvailability(provider: caps.summaries.canGenerate ? .local : .off, busy: false)
        self.caps = caps
        moments = snap?.moments; dayKey = snap?.dayKey; levels = snap?.levels
    }
}

/// Bookkeeping that must not redraw the list: per-day scroll offsets and selections, the loads'
/// generation ticket, the detail waiting for its day to load, and scroll anchoring.
///
/// **Anchoring.** When rows above the visible area grow or shrink (a row expands or collapses, an
/// expanded card's sources arrive, a refresh reflows the summary card), the rows on screen stay where
/// they are: a visible selected/expanded row, otherwise a retained visible row or the topmost row,
/// is the anchor, and after the new layout the list scrolls by
/// however far that row moved. At the very top nothing is anchored, so new content above shows. The
/// anchor is taken after every scroll and every settled layout; clip moves that come from the layout
/// itself (AppKit clamping a shorter document) don't retake it.
///
/// **Revealing.** A card the person opens, a moment another surface hands over, or a failed action's
/// notice is scrolled into view once it has laid out (after a day change, over the day's remembered
/// offset), then followed for a second while the card settles (its sources arrive). Scrolling the list
/// after that stops it.
@MainActor private final class FocusListBox {
    weak var scrollView: NSScrollView?
    /// The day the list last drew, and the one whose offset waits to be restored after a day change.
    private var shownKey: String?
    private var pendingRestore: String?
    private var offsets: [String: CGFloat] = [:]
    /// The day `browser.selectedMomentID`/`expandedMomentID` belong to, and every other day's.
    var selectionKey: String?
    var selections: [String: FocusSelection] = [:]
    /// The selection the next day change applies instead of the remembered one.
    var handoff: FocusSelection?
    /// The ids as the shown day (`selectionKey`) last had them. A day change whose ids differ was written
    /// by another surface along with the day.
    var recorded = FocusSelection()
    /// Moment starts per day, to re-select the nearest row when a refresh drops one.
    var starts: [String: [String: Date]] = [:]
    /// Each day's last known day-note state (kept while a reread of the day is in flight).
    var dayNotes: [String: FocusDayNote] = [:]
    var pendingDetail: String?
    var generation = 0
    /// fix/day-nav: the projected days kept for instant swaps, the past-day load in flight (cancelled by a newer
    /// click), the neighbour prefetch, and when the last load started (rapid clicks coalesce).
    let projections = DayProjectionCache()
    var loadTask: Task<Void, Never>?
    var prefetchTask: Task<Void, Never>?
    var lastLoad: Date?
    /// The expansion the list itself last wrote, until its change comes back (`expansionChanged`).
    var ownExpansion: String??

    // Anchoring state.
    private weak var observedClip: NSClipView?
    private weak var observedDocument: NSView?
    private var observers: [NSObjectProtocol] = []
    /// Each row's frame in the list's content (`FocusRowFrames`), and the content's height.
    private var rowFrames: [String: CGRect] = [:]
    private var contentHeight: CGFloat?
    /// The topmost row on screen and its distance below the top of the visible area.
    private var anchor: (id: String, offset: CGFloat)?
    private var preferredAnchors: [String] = []

    /// Keep an already visible expanded/selected child in place as its containing card reflows.
    /// Offscreen selections never pull the viewport; the existing topmost-row anchor is the fallback.
    func preferVisibleAnchor(_ ids: [String]) {
        preferredAnchors = ids
        guard let scrollView, scrollView.contentView.bounds.origin.y > 0.5 else { return }
        let visible = scrollView.contentView.bounds
        if let id = ids.first(where: { rowFrames[$0]?.intersects(visible) == true }), let frame = rowFrames[id] {
            anchor = (id, frame.minY - visible.minY)
        }
    }
    /// A layout is half applied: the rows moved but AppKit hasn't sized the document yet, or the other
    /// way round. Clip moves meanwhile are AppKit reflecting the document change, not scrolling.
    private var unsettled = false
    /// The box is scrolling the clip itself (at once, or animated).
    private var adjusting = false
    private var animating = false
    /// What is being scrolled into view: a row's card (whole, or by its `bottom` edge, where the bar
    /// and a notice are) or the notice above the list. It waits up to 5 s to lay out, then follows for 1 s.
    private var revealing: (id: String, bottom: Bool, animated: Bool, requested: Date, applied: Date?)?

    deinit {
        for token in observers { NotificationCenter.default.removeObserver(token) }
    }

    /// A row's hover (fix/scroll-perf). While the list scrolls, rows passing under a resting pointer would each relight
    /// the ribbon and redraw the day card, a frame's worth of work per row; the last of them lights once the list has
    /// been still for `hoverSettle`. Otherwise at once.
    func hover(_ id: String?, into hover: FocusHover) {
        let still = CACurrentMediaTime() - scrolledAt
        guard still < Self.hoverSettle else {
            pendingHover = nil
            if hover.id != id { hover.id = id }
            return
        }
        let waiting = pendingHover != nil
        pendingHover = (hover, id)
        if !waiting { flushHover(after: Self.hoverSettle - still) }
    }
    private static let hoverSettle: CFTimeInterval = 0.12
    private var scrolledAt: CFTimeInterval = 0
    private var pendingHover: (hover: FocusHover, id: String?)?
    private func flushHover(after delay: CFTimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let pending = self.pendingHover else { return }
                let still = CACurrentMediaTime() - self.scrolledAt
                if still < Self.hoverSettle { return self.flushHover(after: Self.hoverSettle - still) }
                self.pendingHover = nil
                if pending.hover.id != pending.id { pending.hover.id = pending.id }
            }
        }
    }

    /// The click-to-reference handler the list puts in the environment: equal from one redraw to the next, calling the
    /// latest redraw's handler (`ReferenceClickAction`, fix/scroll-perf).
    func referenceClick(to latest: @escaping (MomentReference) -> Void) -> ReferenceClickAction {
        onReferenceClick = latest
        return ReferenceClickAction(owner: self) { [weak self] in self?.onReferenceClick?($0) }
    }
    private var onReferenceClick: ((MomentReference) -> Void)?

    /// The ribbon menu's revision (`RibbonMomentMenu.revision`): a new one only when what its closures read by value
    /// changes, compared once here rather than once per span (fix/scroll-perf).
    private var ribbonMenuInputs: RibbonMenuInputs?
    private var ribbonMenuCount = 0
    func ribbonMenuRevision(_ inputs: RibbonMenuInputs) -> Int {
        if inputs != ribbonMenuInputs { ribbonMenuInputs = inputs; ribbonMenuCount += 1 }
        return ribbonMenuCount
    }

    /// Moment positions by id, for the ribbon's span menus (fix/scroll-perf). A linear scan per span copied
    /// every moment on each redraw, about a third of a selection change on a full day. Kept in the box (not
    /// rebuilt in `body`) so the menu closures stay equal between redraws; a stale position is caught by its id.
    private var momentIndex: [String: Int] = [:]
    func moment(_ id: String, in moments: [MomentSlice]) -> MomentSlice? {
        if let i = momentIndex[id], moments.indices.contains(i), moments[i].id == id { return moments[i] }
        momentIndex = Dictionary(moments.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        return momentIndex[id].map { moments[$0] }
    }

    /// Called while drawing, before the new day lays out: remembers the old day's offset.
    func track(_ key: String) {
        guard key != shownKey else { return }
        if let old = shownKey, let scrollView {
            offsets[old] = scrollView.contentView.bounds.origin.y
            pendingRestore = key
        }
        shownKey = key
    }

    /// Scrolls back to the shown day's remembered offset (the top for a day not seen yet). Once the
    /// day's content is `loaded`, the restore is done.
    func applyRestore(loaded: Bool) {
        guard let key = pendingRestore, key == shownKey, let scrollView else { return }
        let clip = scrollView.contentView
        let extent = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
        let y = min(offsets[key] ?? 0, extent)
        if abs(clip.bounds.origin.y - y) >= 0.5 {
            adjusting = true
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scrollView.reflectScrolledClipView(clip)
            adjusting = false
        }
        if loaded { pendingRestore = nil }
        // A moment handed over with the day shows over the day's remembered offset.
        if !unsettled && consistent {
            applyReveal()
            takeAnchor()
        }
    }

    // MARK: Anchoring

    /// Follows the list's clip and document views (they can be replaced while the list lives).
    func attach(_ scroll: NSScrollView) {
        scrollView = scroll
        let clip = scroll.contentView, document = scroll.documentView
        guard clip !== observedClip || document !== observedDocument else { return }
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers = []
        observedClip = clip
        observedDocument = document
        let center = NotificationCenter.default
        clip.postsBoundsChangedNotifications = true
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrolledAt = CACurrentMediaTime(); self?.clipMoved() }
        })
        observers.append(center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.revealing = nil }
        })
        if let document {
            document.postsFrameChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.documentResized() }
            })
        }
        // A reference can arrive before the invisible scroll probe attaches, after its rows already laid out.
        if !unsettled && consistent { applyReveal() }
        takeAnchor()
    }

    /// Scrolls `id`'s card (or the notice, `FocusRowFrames.noticeKey`) into view once it lays out, and
    /// again as it settles for a second. `bottom`: the card's bottom edge must show.
    func reveal(_ id: String, bottom: Bool = false, animated: Bool) {
        revealing = (id, bottom, animated, Date(), nil)
        if !unsettled && consistent { applyReveal() }
    }

    /// Stops revealing anything but `id`.
    func cancelReveal(unless id: String?) {
        if let revealing, revealing.id != id { self.revealing = nil }
    }

    /// The rows' frames (and the content's height) after a layout.
    func rowsMoved(_ frames: [String: CGRect]) {
        var rows = frames
        let content = rows.removeValue(forKey: FocusRowFrames.contentKey)?.height
        guard rows != rowFrames || content != contentHeight else { return }
        rowFrames = rows
        contentHeight = content
        layoutChanged()
    }

    private func documentResized() { layoutChanged() }

    /// Half of a layout arrived (the rows' frames, or AppKit's new document size): keep the anchor row
    /// where it was. Once both halves agree the layout has settled, and the anchor is taken afresh.
    private func layoutChanged() {
        if let target = anchorTarget() { scroll(to: target) }
        if consistent {
            settle()
        } else if !unsettled {
            unsettled = true
            // A half that never comes (nothing to resize) must not freeze the anchor.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.unsettled else { return }
                self.settle()
            }
        }
    }

    private func clipMoved() {
        guard !adjusting, !animating, !unsettled, consistent else { return }
        // The list was scrolled after a reveal showed its card: stop following it.
        if revealing?.applied != nil { revealing = nil }
        takeAnchor()
    }

    /// The document is as tall as the rows' content says (pixel rounding aside), or the content fits.
    private var consistent: Bool {
        guard let scrollView, let contentHeight, let document = scrollView.documentView else { return true }
        return abs(document.frame.height - contentHeight) <= 1.5 || contentHeight <= scrollView.contentView.bounds.height + 0.5
    }

    private var extent: CGFloat {
        guard let scrollView else { return 0 }
        return max(0, (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height)
    }

    private func anchorTarget() -> CGFloat? {
        guard let anchor, let frame = rowFrames[anchor.id] else { return nil }
        return frame.minY - anchor.offset
    }

    /// Scrolls the clip, clamped to the document.
    private func scroll(to target: CGFloat, animated: Bool = false) {
        guard let scrollView else { return }
        let clip = scrollView.contentView
        let y = min(max(0, target), extent)
        guard abs(clip.bounds.origin.y - y) >= 0.5 else { return }
        let point = NSPoint(x: clip.bounds.origin.x, y: y)
        if animated {
            animating = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                clip.animator().setBoundsOrigin(point)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    scrollView.reflectScrolledClipView(clip)
                    self?.animating = false
                    self?.takeAnchor()
                }
            }
        } else {
            adjusting = true
            clip.scroll(to: point)
            scrollView.reflectScrolledClipView(clip)
            adjusting = false
        }
    }

    /// The layout settled: show what is being revealed, then take the anchor afresh.
    private func settle() {
        unsettled = false
        applyReveal()
        takeAnchor()
    }

    /// Scrolls the revealed card into view: whole when it fits (else its top), or by its bottom edge.
    private func applyReveal() {
        guard let r = revealing, let scrollView else { return }
        let now = Date()
        if let applied = r.applied, now.timeIntervalSince(applied) > 1 { revealing = nil; return }
        if r.applied == nil, now.timeIntervalSince(r.requested) > 5 { revealing = nil; return }
        guard let frame = rowFrames[r.id] else { return }
        let top = scrollView.contentView.bounds.origin.y, height = scrollView.contentView.bounds.height
        var target = top
        if r.bottom {
            // The bar and the notice are the card's last ~120 pt.
            let band = min(frame.height, 120)
            if frame.maxY > top + height || frame.maxY - band < top { target = frame.maxY - height }
        } else {
            if frame.maxY > top + height { target = min(frame.maxY - height, frame.minY) }
            if frame.minY < target { target = frame.minY }
        }
        if r.applied == nil { revealing?.applied = now }
        guard abs(target - top) >= 0.5 else { return }
        scroll(to: target, animated: r.animated)
        if !r.animated { takeAnchor() }
    }

    private func takeAnchor() {
        guard let scrollView else { anchor = nil; return }
        anchor = TimelineVisibleAnchor.select(frames: rowFrames, visible: scrollView.contentView.bounds,
                                              preferredIDs: preferredAnchors, previousID: anchor?.id)
    }
}

/// Finds the list's `NSScrollView` for the offset bookkeeping. Invisible to clicks and VoiceOver.
private struct FocusScrollProbe: NSViewRepresentable {
    let box: FocusListBox
    func makeNSView(context: Context) -> FocusScrollProbeView {
        let view = FocusScrollProbeView()
        view.box = box
        return view
    }
    func updateNSView(_ view: FocusScrollProbeView, context: Context) {
        view.box = box
        view.attach()
    }
}

private final class FocusScrollProbeView: NSView {
    weak var box: FocusListBox?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attach()
    }
    func attach() {
        guard let scroll = enclosingScrollView else { return }
        MainActor.assumeIsolated { box?.attach(scroll) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}

// MARK: - Checks probe

/// What the Focus List reports to checks (`main-layout-stress`, `dd-focus-list`), which set it with
/// `.environment(\.daydreamFocusListProbe, probe)`. The app never sets it.
@MainActor public final class FocusListProbe {
    public init() {}
    /// Each row's frame (a collapsed row, or an expanded card with its inset) in the list's document
    /// coordinates: y down from the top of `canonical-history`'s content.
    public internal(set) var rowFrames: [String: CGRect] = [:]
    /// perf-1005: how many times the row frames were handed to the list (a layout loop shows as a count that keeps rising).
    public internal(set) var rowFrameUpdates = 0
    /// A failed action's notice (above the list, or in the expanded card), in the same coordinates.
    public internal(set) var noticeFrame: CGRect?
    /// What each expanded body's `Windows and pages` lists, by moment id, and whether every member
    /// action was read for it.
    public internal(set) var sources: [String: [FocusListSource]] = [:]
    public internal(set) var sourcesComplete: [String: Bool] = [:]
    /// The pushed detail's moment, and the actions it shows (oldest first) once loaded.
    public internal(set) var detailMomentID: String?
    public internal(set) var detailActions: [CanonicalAction] = []
    /// fix/show-all: the detail's sends and typed blocks, as last read.
    public internal(set) var detailTyped: MomentTypedLoad?
    public internal(set) var detailComplete = false
    /// The detail's latest read failed (its notice offers Try Again).
    public internal(set) var detailFailed = false
    /// The detail offers `Load More Actions`.
    public internal(set) var detailCanLoadMore = false
    /// The detail says some of the moment's actions may be missing (its read ran out of pages).
    public internal(set) var detailMissingNote = false
    /// The detail body's size: the whole of the detail's scroll content.
    public internal(set) var detailBodySize: CGSize = .zero
    /// Points at a moment as the pointer would (a check can't move a pointer offscreen): over its row, so its span
    /// lights on the day card's ribbon, or (`onRibbon`) over its span, so its row lights. nil: the pointer leaves.
    public internal(set) var point: ((_ id: String?, _ onRibbon: Bool) -> Void)?
}

private struct FocusListProbeKey: EnvironmentKey {
    static var defaultValue: FocusListProbe? { nil }
}

extension EnvironmentValues {
    /// Checks only; see `FocusListProbe`.
    public var daydreamFocusListProbe: FocusListProbe? {
        get { self[FocusListProbeKey.self] }
        set { self[FocusListProbeKey.self] = newValue }
    }
}

// MARK: - Private views

/// The summary card's place while the day loads (no spinner, no skeleton lines, nothing animates), and under it
/// (fix/day-nav) a bracket of `rows` placeholder rows, the day's cached moment count.
private struct FocusSummarySkeleton: View {
    var rows = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Color.clear.frame(height: 25)
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.05)).frame(height: 8)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .daydreamCard(radius: DaydreamStyle.cardRadius, fill: DaydreamStyle.raised, shadow: false)
            if rows > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.primary.opacity(0.06))
                        .frame(width: 120, height: 10).padding(.leading, 8).padding(.bottom, 4)
                    ForEach(0..<rows, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)).frame(height: 52)
                    }
                }
                .padding(.top, 22)
                .accessibilityIdentifier("canonical-day-skeleton")
            }
        }
        .accessibilityHidden(true)
    }
}

/// An inline notice with a dismiss button, styled as `OriginalUnavailableBanner`.
private struct FocusNoticeBanner: View {
    let text: String
    let onDismiss: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.tertiary)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(DaydreamStyle.wellFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct CorrectionSheet: View {
    @Binding var text: String
    let error: String?
    let cancel: () -> Void
    let save: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The title says it is your correction; no second line.
            Text("Edit correction").font(DaydreamType.sectionTitle)
            TextEditor(text: $text).font(DaydreamType.body).scrollContentBackground(.hidden)
                .focused($focused).padding(.horizontal, 5).padding(.vertical, 7)
                .frame(minHeight: 120).daydreamField(focused: focused)
            if let error {
                Label {
                    Text(error).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(DaydreamStyle.attention)
                }
                .font(DaydreamType.detail).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel, action: cancel)
                    .buttonStyle(DaydreamPillButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(DaydreamOnboardingPrimaryStyle()).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(minWidth: 380).background(DaydreamStyle.window)
    }
}
