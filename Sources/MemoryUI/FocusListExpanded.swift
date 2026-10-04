import AppKit
import SwiftUI
import MemoryCore

// The body under an open app card's header (owner 10/2, Main.dc.html). One card per app in a bracket (`FocusAppCard`):
// - left: the summary bullets of every member, about what was written (typed, sent, drafted); reading lines only when
//   nothing was written; without a summary, the condensed What happened as sentences ("Worked in Terminal for 5
//   minutes."), never a "~1 min" Summary;
// - right: "Conversations", "Pages" or "Windows": the app's icon and the name of each one written in, up to 6, no
//   times and no buttons; it stacks under the summary when the list is narrow. "Show details ›" at its bottom reveals
//   the condensed, signal-only What happened (with times) and the panel's other rows; Every Action is there when the
//   card couldn't read every action;
// - a failed action's notice, then the footer: Copy Summary on the left, Forget This Moment… on the right (a card of
//   several moments asks which one).
// The card around it and the header row belong to `FocusAppCardItem`. No key equivalent is bound here.

/// The body under an expanded row's header. Its controls are sibling VoiceOver elements of the
/// header (amendments A1).
public struct FocusListExpanded: View {
    /// The card's anchor: its newest member. Its own actions (Summarize Now, the source previews) act on it.
    let moment: MomentSlice
    /// Every moment of the card (one app in one bracket), newest first. A single moment's card is `[moment]`.
    let members: [MomentSlice]
    /// Runs an action on one member (Forget on a card of several asks which one).
    let performOn: ((MomentActionID, MomentSlice) -> Void)?
    @ObservedObject var browser: ActivityBrowser
    let wide: Bool
    let notice: AnyView?
    let perform: (MomentActionID) -> Void
    let showAll: () -> Void
    @Environment(\.daydreamFocusListProbe) private var probe
    @State private var sources: FocusSourcesLoad = .loading
    /// Sources whose original couldn't be verified this session (their arrow is disabled).
    @State private var unavailable: Set<String> = []
    @State private var generation = 0
    /// The member actions the latest read was for.
    @State private var readIDs: [String]?
    @State private var historyActions: [CanonicalAction] = []
    @State private var historyComplete = false
    @State private var historyFailed = false
    /// The typed actions' compose lines (`ActivityBrowser.loadComposeLines`).
    @State private var composeLines: [String: ComposeLine] = [:]
    @StateObject private var source = OwnerSourceDetailSession()
    @State private var sourceVisible = false
    @State private var sourceWindow: Int?
    /// A click on the quoted messages opens them from 2 lines to 4 (owner 10/2, final).
    @State private var quotesOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - `wide`: the list is at least 760 pt wide (two columns; narrower stacks).
    /// - `notice`: a failed bar action's banner (Open Original, Summarize Now…), drawn above the bar.
    /// - `perform`: runs a moment action (`MomentActions.items(for:context:.focusList,…)`) on this moment.
    /// - `showAll`: pushes the moment's detail (`Show all {n} actions`).
    public init(moment: MomentSlice, members: [MomentSlice]? = nil, browser: ActivityBrowser, wide: Bool, notice: AnyView? = nil,
                perform: @escaping (MomentActionID) -> Void, performOn: ((MomentActionID, MomentSlice) -> Void)? = nil,
                showAll: @escaping () -> Void) {
        self.moment = moment; self.members = (members?.isEmpty ?? true) ? [moment] : members!
        self.browser = browser; self.wide = wide; self.notice = notice
        self.perform = perform; self.performOn = performOn; self.showAll = showAll
    }
    private var memberActionIDs: [String] { members.flatMap(\.actionIDs) }
    private var actionCount: Int { members.reduce(0) { $0 + $1.actionCount } }

    /// The `Windows and pages` column's width beside the summary (home-C `SourcesC`).
    static let sourcesWidth: CGFloat = 336
    /// Member actions read for the sources column. Past this the column shows what it found.
    static let sourceScanLimit = 400

    /// The side panel's width beside the summary (owner 10/2 layout).
    static let panelWidth: CGFloat = 248

    private var condensed: [MomentDetailEntry] {
        MomentHistoryCondense.lines(OwnerSourceMomentProjection.history(historyActions, previews: source.state.previews),
                                    actions: historyActions, timeZone: browser.calendar.timeZone, compose: composeLines)
    }
    private var writingIDs: Set<String>? { readIDs == nil || historyActions.isEmpty ? nil : FocusAppCard.writingIDs(historyActions) }

    public var body: some View {
        let items = MomentActions.items(for: moment, context: .focusList, browser: MomentActions.Capabilities(browser: browser))
        return VStack(alignment: .leading, spacing: 16) {
            // Owner 10/2 (Main.dc.html): two columns, the summary on the left and the side panel on the right; the panel
            // stacks under the summary when the list is narrow.
            if wide {
                HStack(alignment: .top, spacing: 18) {
                    summary.frame(maxWidth: .infinity, alignment: .leading)
                    panel.frame(width: Self.panelWidth)
                }
            } else {
                VStack(alignment: .leading, spacing: 14) { summary; panel }
            }
            if let notice {
                // The list scrolls this into view (`FocusRowFrames.noticeKey`).
                notice.background(GeometryReader { g in
                    Color.clear.preference(key: FocusRowFrames.self, value: [FocusRowFrames.noticeKey: g.frame(in: .named(FocusRowFrames.space))])
                })
            }
            // Owner 10/3: the footer lines up with the card's left content edge, under the app icon's left edge (the
            // body is inset to the title column, 42 pt to the right of the icon's edge).
            footer(items).padding(.leading, -Self.footerOutdent)
        }
        // The card is inset 6 pt from the list edge, so 48 here lines up with the header's title (54 from the list
        // edge), and 8 puts the sources box and Forget on the header's time column (the header steps out 6 and
        // `DDRow` insets its trailing 14).
        .padding(.leading, 48).padding(.trailing, 8).padding(.top, 4).padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .modifier(FocusExpandedAccessibilityActions(items: Self.accessibilityActions(items), perform: perform))
        .background(OwnerSourceDetailWindowReader { id in
            sourceWindow = id
            if id == nil { source.close() }
            else if sourceVisible, NSApplication.shared.isActive { loadSource(moment) }
        }.frame(width: 0, height: 0))
        .onAppear {
            sourceVisible = true; load(moment)
            if sourceWindow != nil, NSApplication.shared.isActive { loadSource(moment) }
        }
        .onChange(of: members) { next in
            if next.flatMap(\.actionIDs) != readIDs { load(moment) }
            if sourceVisible, NSApplication.shared.isActive { loadSource(next.first ?? moment) } else { source.close() }
        }
        .onReceive(browser.dayCache.cleared) { key in
            guard key == nil || key == moment.dayKey else { return }
            historyActions = []; load(moment)
            if sourceVisible, NSApplication.shared.isActive { loadSource(moment) } else { source.close() }
        }
        .onDisappear { sourceVisible = false; source.close(); generation += 1; historyActions = [] }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            guard let window = note.object as? NSWindow,
                  OwnerSourceDetailState.closesOwnWindow(own: sourceWindow, closing: window.windowNumber) else { return }
            sourceVisible = false; source.close()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemClockDidChange)) { _ in
            source.close()
            if sourceVisible, NSApplication.shared.isActive { loadSource(moment) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in source.close() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if sourceVisible { loadSource(moment) }
        }
    }

    // MARK: Summary

    /// The left column (owner 10/2, final): summary bullets only, one per conversation or action, about what was written
    /// (typed, sent, drafted); reading lines only when nothing was written. Before the summary: the stitched messages
    /// typed, quoted, italic and grey, at most 2 and "+N earlier messages", under "Summary pending" while one is on its
    /// way (else "What you wrote"). Without either: the condensed What happened as sentences ("Worked in Terminal for 5
    /// minutes."), never a "~1 min" Summary.
    private var leftColumn: FocusAppCard.LeftColumn {
        let pending = FocusAppCard.summaryPending(members, phase: browser.summaries.shown, queue: browser.summaries.queue)
        return FocusAppCard.leftColumn(members, previews: source.state.previews, writingIDs: writingIDs, pending: pending,
                                       compose: composeLines, actions: historyActions)
    }

    private var summary: some View {
        let corrections = FocusAppCard.corrections(members)
        // claude/messages2-1003: the column as drawn (a Texts card's conversations included).
        let column = leftColumn
        let bullets = column.bullets, messages = column.quotes
        // Owner-approved summary-v2 (10/3): Summary pending → Summarizing… (one sweep over the quotes) → Summary.
        let state = cardState(column)
        let header = state.label(column.header)
        return VStack(alignment: .leading, spacing: 8) {
            if let header {
                Text(header).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CardSummaryState.violet(header) ? AnyShapeStyle(DaydreamStyle.model) : AnyShapeStyle(.secondary))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("card-summary-header")
            }
            if !column.threads.isEmpty {
                // claude/messages2-1003 (owner 10/3): each conversation, then the texts sent, verbatim, newest first.
                TextThreadList(threads: column.threads, size: 12.5).accessibilityIdentifier("card-text-threads")
            }
            if !bullets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(bullets.enumerated()), id: \.offset) { _, bullet in Bullet(bullet, size: 12.5) }
                }
                // fix/resummarize: dimmed in place while Summarize Now writes the new note.
                .opacity(members.contains { browser.updatingMoments.contains($0.id) } ? 0.5 : 1)
                // summary-v2: the bullets fade in when the summary arrives.
                .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 3)))
                .accessibilityIdentifier("card-summary-bullets")
            } else if !messages.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(messages.prefix(FocusAppCard.messageLimit).enumerated()), id: \.offset) { _, message in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text("\u{2022}").foregroundStyle(.tertiary).accessibilityHidden(true)
                            Text(FocusAppCard.quote(message, limit: quotesOpen ? FocusAppCard.openQuoteLimit : FocusAppCard.quoteLimit))
                                .italic().foregroundStyle(state.sweeps && reduceMotion ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                                .lineLimit(quotesOpen ? 4 : 2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 12.5))
                    }
                    if let earlier = FocusAppCard.earlierLine(messages.count) {
                        Text(earlier).font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    }
                }
                // summary-v2: ONE sweep over the whole quote block (a single band, a single phase), never one per line.
                .modifier(QuoteSweep(active: state.sweeps && !reduceMotion))
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { quotesOpen.toggle() }
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(quotesOpen ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("card-captured-messages")
            } else if column.threads.isEmpty, readIDs != nil, !historyActions.isEmpty {
                let start = members.map(\.start).min() ?? moment.start, end = members.map(\.end).max() ?? moment.end
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(FocusAppCard.sentences(condensed, start: start, end: end, members: members,
                                                         names: panelRows.map(\.name)).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("card-what-happened-sentences")
            }
            if !corrections.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(corrections.enumerated()), id: \.offset) { _, bullet in Bullet(bullet, size: 12.5) }
                }
                .padding(.top, 2)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: state)
    }

    /// The card's Summarize Now state (`CardSummaryState`) from the left column as drawn and the browser's running and
    /// missed moments.
    private func cardState(_ column: FocusAppCard.LeftColumn) -> CardSummaryState {
        CardSummaryState.of(bullets: !column.bullets.isEmpty, running: members.contains { browser.updatingMoments.contains($0.id) },
                            missed: members.contains { browser.summarizeMisses.contains($0.id) })
    }

    /// The footer: Copy Summary on the left, Forget This Moment… on the right. A card of several moments copies all of
    /// them and asks which one to forget. claude/summary-fail-1003 (owner 10/3): Copy Summary is always there, under the
    /// icon's edge (dimmed until there is a summary to copy), so Summarize Now sits right of it as designed.
    @ViewBuilder private func footer(_ items: [MomentActionItem]) -> some View {
        if members.count == 1 {
            FocusActionBar(items: Self.footerItems(items, moment: moment, working: summarizing), perform: perform,
                           extra: summarizeButton)
        } else {
            let text = FocusAppCard.copyText(members, timeZone: browser.calendar.timeZone)
            HStack(spacing: 8) {
                Button("Copy Summary") {
                    guard let text else { return }
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                }
                .buttonStyle(FocusActionButtonStyle())
                .disabled(text == nil || summarizing)
                .help(text == nil ? Self.noSummaryYet : "Copy Summary")
                summarizeButton
                Spacer(minLength: 12)
                Menu {
                    ForEach(members, id: \.id) { m in
                        Button(Self.forgetItemTitle(m, timeZone: browser.calendar.timeZone)) { (performOn ?? { _, _ in })(.forget, m) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "trash").font(.system(size: 11, weight: .medium))
                        Text("Forget This Moment…").font(.system(size: 12))
                    }
                    .foregroundStyle(Color.red.opacity(0.85))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(performOn == nil)
                .accessibilityLabel("Forget This Moment…")
            }
        }
    }

    /// The body's leading inset minus the icon's (the header's 12 pt inside the card's 6 pt step-out).
    static let footerOutdent: CGFloat = 42

    /// Owner 10/3: "Summarize Now" right of Copy Summary while the summary is pending or failed ("Summary pending",
    /// "What you wrote"); "Summarizing…" while it runs; gone once a summary exists. It runs the same Summarize Now as the
    /// menus (`MomentActionID.summarizeNow`, with its gates) on every member of the card that has no summary.
    /// claude/summary-fail-1003: it reads the left column exactly as drawn (`FocusAppCard.leftColumn`). Before, it rebuilt
    /// the header from every member's lines, code's send lines included, so a pending Claude Code card ("Summary pending"
    /// over its quoted prompts) counted as summarized and showed no Summarize Now. After a one-off failure the quiet
    /// `SummarizeNowNotice.quietLine` sits beside it; never a banner.
    private var summarizeButton: AnyView? {
        let caps = MomentActions.Capabilities(browser: browser)
        // A Texts card showing its texts has its Summary (claude/messages2-1003).
        let column = leftColumn
        guard column.threads.isEmpty else { return nil }
        let state = cardState(column)
        let targets = FocusAppCard.summarizeTargets(members, caps: caps)
        guard FocusAppCard.offersSummarizeNow(column, targets: targets.count, running: state == .working) else { return nil }
        // summary-v2: while it runs the button stays, greyed out and unclickable (the label above says "Summarizing…").
        return AnyView(HStack(spacing: 8) {
            Button(FocusAppCard.summarizeTitle) {
                for m in targets { if members.count == 1 { perform(.summarizeNow) } else { (performOn ?? { _, _ in })(.summarizeNow, m) } }
            }
            .buttonStyle(FocusActionButtonStyle())
            .disabled(!state.summarizeEnabled)
            .accessibilityValue(state == .working ? FocusAppCard.summarizingTitle : "")
            .accessibilityIdentifier("card-summarize-now")
            if let quiet = state.quietLine {
                Text(quiet).font(.system(size: 11.5)).foregroundStyle(.tertiary).lineLimit(1)
                    .accessibilityIdentifier("card-summarize-miss")
            }
        })
    }

    /// A Summarize Now runs on a member of this card.
    private var summarizing: Bool { members.contains { browser.updatingMoments.contains($0.id) } }

    /// The single moment's footer buttons: the bar's (`barItems`) without Summarize Now (it is `summarizeButton`), and
    /// Copy Summary first even before there is a summary (dimmed, saying why).
    static let noSummaryYet = "No summary yet"
    /// While Summarize Now runs (`working`), Copy Summary is greyed out too (summary-v2).
    public static func footerItems(_ items: [MomentActionItem], moment: MomentSlice? = nil, working: Bool = false) -> [MomentActionItem] {
        var bar = barItems(items, moment: moment).filter { $0.id != .summarizeNow }
        if let i = bar.firstIndex(where: { $0.id == .copySummary }) {
            if working { bar[i] = MomentActionItem(id: .copySummary, title: "Copy Summary", symbol: "doc.on.doc", enabled: false, reason: FocusAppCard.summarizingTitle) }
        } else {
            let reason = working ? FocusAppCard.summarizingTitle : items.first { $0.id == .copySummary }?.reason ?? noSummaryYet
            bar.insert(MomentActionItem(id: .copySummary, title: "Copy Summary", symbol: "doc.on.doc", enabled: false, reason: reason), at: 0)
        }
        return bar
    }

    /// A Forget menu item: "Q7 · 5:14–5:16 PM".
    static func forgetItemTitle(_ m: MomentSlice, timeZone: TimeZone) -> String {
        let name = FocusListLayout.recordedConversation(m) ?? MomentSubtitle.rowTitle(m)
        return name + " · " + DaydreamFormat.range(m.start, m.end, timeZone)
    }

    /// Names a filler line may carry besides its duration: the moment's apps, subject and title.
    static func summaryNames(_ m: MomentSlice) -> [String] {
        m.apps + [m.primaryApp, m.subject, m.title].compactMap { $0 }
    }

    private func statusLine(_ status: FocusSummaryStatus) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(status.text).foregroundStyle(.secondary)
                if status.settingsLink, let open = browser.openSettingsSection {
                    Text("·").foregroundStyle(.tertiary).accessibilityHidden(true)
                    Button("Turn On") { open("Summaries") }.buttonStyle(FocusLinkButtonStyle())
                }
            }
            .font(.system(size: 12))
            if let detail = status.detail {
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, status.skeleton ? 4 : 0)
        .accessibilityElement(children: .contain)
    }

    // MARK: Windows and pages

    private var panelRows: [FocusAppCard.PanelRow] {
        guard case .loaded(let all, _) = sources else { return [] }
        return FocusAppCard.panelRows(members, sources: all, writingIDs: writingIDs ?? [])
    }

    /// The side panel (owner 10/2): "Conversations", "Pages" or "Windows"; each row the app's icon (a page's favicon)
    /// and the name, no times and no buttons. Written-in ones only, unless nothing was written. "Show details ›" at its
    /// bottom reveals What happened and the panel's other rows.
    private var panel: some View {
        let rows = panelRows
        return VStack(alignment: .leading, spacing: 0) {
            Text(FocusAppCard.panelTitle(members)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            switch sources {
            case .loading:
                // Blank while its windows are read (a few ms), never a skeleton.
                Color.clear.frame(height: 30).accessibilityHidden(true)
            case .failed:
                Text("These couldn't be loaded.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).frame(minHeight: 30, alignment: .leading)
            case .loaded:
                ForEach(FocusAppCard.shownRows(rows)) { row in
                    // page-links-1003 (owner 10/03): a page opens itself (its own link, else its site) in the browser.
                    let page = FocusAppCard.panelSource(row, sources: allSources)
                    let blocked = page.map { unavailable.contains($0.id) } ?? false
                    let canOpen = page != nil && browser.reopenCanonical != nil && !blocked
                    FocusSourceEntry(help: blocked ? Self.unavailableHelp : canOpen ? page.map { "Opens \($0.place) in your browser" } : nil,
                                     dimmed: blocked, run: canOpen ? { page.map(openSource) } : nil) {
                        HStack(spacing: 8) {
                            Group {
                                if !row.site.isEmpty {
                                    WebMonogramTile(domain: row.site, browserBundle: nil, size: 18)
                                } else {
                                    AppIcon(bundle: row.bundle.isEmpty ? nil : row.bundle, name: row.name, size: 18)
                                }
                            }
                            .frame(width: 18, height: 18).accessibilityHidden(true)
                            Text(row.name).font(.system(size: 12)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 12).frame(height: 28)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            // "Show more ›" past 3 rows, else "Show details ›": both open the card's details page; nothing expands here.
            Button(action: showAll) {
                HStack(spacing: 4) {
                    Text(FocusAppCard.panelLink(rows: rows.count))
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).accessibilityHidden(true)
                }
                .font(.system(size: 12, weight: .medium))
                .frame(height: 30)
            }
            .buttonStyle(FocusLinkButtonStyle())
            .accessibilityHint("Opens the details page")
            .padding(.horizontal, 12).padding(.bottom, 2)
        }
        .padding(.bottom, 4)
        .background(DaydreamStyle.wellFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    /// The help on an entry whose page couldn't be opened.
    public static let unavailableHelp = "This page couldn't be opened."

    private var allSources: [FocusListSource] {
        guard case .loaded(let all, _) = sources else { return [] }
        return all
    }
    /// page-links-1003: opens a page entry's latest action through `reopenCanonical` (its own link, verified, else its
    /// site); a failure dims the entry for the session.
    private func openSource(_ source: FocusListSource) {
        guard let reopen = browser.reopenCanonical else { unavailable.insert(source.id); return }
        Task { @MainActor in
            do { try await reopen(source.openActionID) } catch { unavailable.insert(source.id) }
        }
    }

    /// Same ephemeral selected-owner session as the pushed detail; never a row cache.
    private func loadSource(_ target: MomentSlice) {
        guard sourceWindow != nil, sourceVisible,
              let loader = browser.loadOwnerSourcePreviews,
              let revision = browser.ownerSourcePreviewRevision else { source.close(); return }
        source.open(scope: target.dayKey + "|" + target.id, actionIDs: members.count > 1 ? memberActionIDs : target.actionIDs,
                    load: loader, revision: revision, now: browser.now)
    }

    /// Reads every member's actions (each up to the scan limit) for the panel and What happened.
    private func load(_ target: MomentSlice) {
        generation += 1
        let group = members.count > 1 ? members : [target]
        readIDs = group.flatMap(\.actionIDs)
        historyComplete = false; historyFailed = false
        let ticket = generation
        let resolver = MomentResolver(cache: browser.dayCache, calendar: browser.calendar)
        let catalog = browser.dayCache.bundleNames
        Task { @MainActor in
            do {
                var actions: [CanonicalAction] = [], complete = true
                for m in group {
                    let found = try await resolver.memberActions(of: m, limit: min(m.actionIDs.count, Self.sourceScanLimit))
                    actions += found.actions; complete = complete && found.complete
                }
                guard ticket == generation else { return }
                actions.sort { ($0.at, $0.id) < ($1.at, $1.id) }
                historyActions = actions
                historyComplete = complete; historyFailed = false
                let typedIDs = actions.filter { $0.kind == "keyboard.text_input" }.map(\.id)
                if let loader = browser.loadComposeLines, !typedIDs.isEmpty {
                    let lines = await loader(typedIDs)
                    if ticket == generation { composeLines = lines }
                } else { composeLines = [:] }
                sources = .loaded(Self.allSources(from: actions, catalog: catalog), complete: complete)
                probe?.sources[target.id] = Self.sources(from: actions, catalog: catalog)
                probe?.sourcesComplete[target.id] = complete
            } catch {
                guard ticket == generation else { return }
                sources = .failed
                historyFailed = true
            }
        }
    }
}

// MARK: - Pure rules (checks call these)

extension FocusListExpanded {
    /// At most this many windows and pages are listed; `Show all {n} actions` has the rest.
    public static let sourceLimit = 3

    /// Every distinct window, page or conversation the actions touched, most recent first: a page once per site (page-links-1003:
    /// once per page link when it has one, so each video or post opens itself), a
    /// window once per app and cleaned title (a terminal's "user — -zsh — 120×30" variants are one; a withheld title is
    /// its app), each with the range it was seen in.
    @MainActor public static func allSources(from actions: [CanonicalAction], catalog: [String: String] = [:]) -> [FocusListSource] {
        let directory = DaydreamAppDirectory(actions: actions, notes: [], overrides: [:], catalog: catalog)
        struct Group { var first: Date; var last: Date; var count: Int; var latest: CanonicalAction; var title: String; var wrote = false }
        var groups: [String: Group] = [:]
        for a in actions {
            let wrote = FocusAppCard.writingKinds.contains(a.kind)
            guard let at = timestamp(a.at), a.kind != "idle", !(a.app.isEmpty && a.bundle.isEmpty && a.site.isEmpty) else { continue }
            let app = directory.displayName(forApp: a.app).flatMap { $0.isEmpty ? nil : $0 }
                ?? (a.bundle.isEmpty ? nil : directory.name(forBundle: a.bundle) ?? KitAppNames.name(for: a.bundle))
            let site = a.site.isEmpty ? "" : KitBrowsers.host(a.site)
            let raw = a.title == MomentHistoryCondense.withheldTitle ? "" : a.title
            let title = site.isEmpty ? TerminalTitle.display(raw.isEmpty ? (app ?? "") : raw, bundle: a.bundle, app: app ?? "") : ""
            // page-links-1003: a page saved with its own link is its own entry (each video or post opens itself); one without
            // is its site, as before.
            let key = site.isEmpty ? "window|" + (a.bundle.isEmpty ? a.app : a.bundle) + "|" + title.lowercased()
                                   : "page|" + a.bundle + "|" + site + (a.link.map { "|" + $0 } ?? "")
            if var g = groups[key] {
                g.first = min(g.first, at); g.count += 1; g.wrote = g.wrote || wrote
                if at >= g.last { g.last = at; g.latest = a; if site.isEmpty, !title.isEmpty { g.title = title } else if !raw.isEmpty { g.title = raw } }
                groups[key] = g
            } else {
                groups[key] = Group(first: at, last: at, count: 1, latest: a, title: site.isEmpty ? title : raw, wrote: wrote)
            }
        }
        return groups.sorted { ($0.value.last, $0.key) > ($1.value.last, $1.key) }.map { key, g in
            let a = g.latest
            let app = directory.displayName(forApp: a.app).flatMap { $0.isEmpty ? nil : $0 }
                ?? (a.bundle.isEmpty ? nil : directory.name(forBundle: a.bundle) ?? KitAppNames.name(for: a.bundle))
            let site = a.site.isEmpty ? "" : KitBrowsers.host(a.site)
            let title = !g.title.isEmpty ? g.title : !site.isEmpty ? site : app ?? "Window"
            var source = FocusListSource(id: key, bundle: a.bundle, app: app, site: site, title: title,
                                         first: g.first, last: g.last, count: g.count, openActionID: a.id, evidenceIDs: a.evidenceIDs, wrote: g.wrote)
            source.link = site.isEmpty ? nil : a.link
            return source
        }
    }

    /// Whether the summary block shows (fix/day-card): a note's bullets, the moment's sends by code, a partial moment's
    /// reason, or a correction of the person's. Never a header over nothing: not for a note whose every bullet was
    /// filler (N16), a moment with nothing sent while summaries are off, pending or never written, or one too long
    /// to summarize (nothing will come, and nothing here can change it).
    /// fix/expanded-summary (owner, 9/30): a ready note always shows, even one bullet that is the collapsed row's
    /// subtitle. The open row's header trades that subtitle for the time range (`FocusListLayout.expandedMeta`), so
    /// hiding the bullet as a repeat left the open card with no summary at all ("Email in Gmail": Windows and pages and
    /// Summarize Now only, while the collapsed row and the menus offered Copy Summary).
    public static func showsSummary(_ m: MomentSlice) -> Bool {
        if m.bullets.contains(where: \.correction) { return true }
        switch m.summary {
        case .ready: return !m.bullets.isEmpty || !m.lines.isEmpty
        case .incomplete: return true
        case .pending, .summariesOff, .notWritten, .tooLong: return !m.lines.isEmpty
        }
    }

    /// The `Summary` label carries the model's mark only for a note the model wrote (ready, or the previous note while
    /// a newer one is written); nothing else has anything from the model (spec §1.2). fix/summary-fallback: a note code
    /// wrote (`MomentSlice.byCode`: the moment writer by code, or code's fallback note) is ready but never the model's.
    public static func showsModelMark(_ m: MomentSlice) -> Bool {
        switch m.summary {
        case .ready: return !m.byCode
        case .pending, .summariesOff, .tooLong, .incomplete, .notWritten: return false
        }
    }
    /// The one attribution the moment cards draw beside `Summary` (open card and kit card): the cloud-key chip, only on
    /// a note the model wrote with the person's cloud key. Never on code's note.
    public static func showsCloudKeyChip(_ m: MomentSlice) -> Bool {
        guard showsModelMark(m), case .ready(_, false) = m.summary else { return false }
        return true
    }

    /// The windows and pages a moment's actions touched. Pages are one source per (browser, host) and
    /// windows one per (app, title). With more than three, the three with the most actions are kept
    /// (earlier first on a tie); they are listed in the order they were first seen. Each source opens
    /// its latest action, and its app is named only by a real name, never a bundle ID.
    @MainActor public static func sources(from actions: [CanonicalAction], catalog: [String: String] = [:]) -> [FocusListSource] {
        let directory = DaydreamAppDirectory(actions: actions, notes: [], overrides: [:], catalog: catalog)
        struct Group { var first: Date; var last: Date; var count: Int; var latest: CanonicalAction; var title: String; var order: Int }
        var groups: [String: Group] = [:]
        let timed = actions.enumerated().compactMap { i, a in timestamp(a.at).map { (i, a, $0) } }
            .sorted { ($0.2, $0.0) < ($1.2, $1.0) }
        for (order, (_, a, at)) in timed.enumerated() {
            let key = sourceKey(a)
            if var g = groups[key] {
                g.first = min(g.first, at); g.count += 1
                if at >= g.last { g.last = at; g.latest = a }
                if !a.title.isEmpty { g.title = a.title }
                groups[key] = g
            } else {
                groups[key] = Group(first: at, last: at, count: 1, latest: a, title: a.title, order: order)
            }
        }
        let kept = groups.sorted { ($1.value.count, $0.value.order) < ($0.value.count, $1.value.order) }.prefix(sourceLimit)
        return kept.sorted { ($0.value.first, $0.value.order) < ($1.value.first, $1.value.order) }.map { key, g in
            let a = g.latest
            let app = directory.displayName(forApp: a.app).flatMap { $0.isEmpty ? nil : $0 }
                ?? (a.bundle.isEmpty ? nil : directory.name(forBundle: a.bundle) ?? KitAppNames.name(for: a.bundle))
            let site = a.site.isEmpty ? "" : KitBrowsers.host(a.site)
            let title = !g.title.isEmpty ? g.title : !site.isEmpty ? site : app ?? "Window"
            var source = FocusListSource(id: key, bundle: a.bundle, app: app, site: site, title: title,
                                         first: g.first, last: g.last, count: g.count, openActionID: a.id, evidenceIDs: a.evidenceIDs)
            source.link = site.isEmpty ? nil : a.link
            return source
        }
    }

    private static func sourceKey(_ a: CanonicalAction) -> String {
        if !a.site.isEmpty { return "page|" + a.bundle + "|" + KitBrowsers.host(a.site) + (a.link.map { "|" + $0 } ?? "") }
        return "window|" + (a.bundle.isEmpty ? a.app : a.bundle) + "|" + a.title
    }

    /// What the summary block says instead of bullets; nil when the note's bullets (or, without a note, the moment's
    /// sends by code) show (amendments A1; fix/day-card: never a skeleton). A ready note without bullets says nothing
    /// more (empty text). `provider` is kept for callers.
    public static func summaryStatus(for m: MomentSlice, provider: SummaryAvailability.Provider) -> FocusSummaryStatus? {
        switch m.summary {
        case .ready:
            return m.bullets.contains { !$0.correction } || !m.lines.isEmpty ? nil : FocusSummaryStatus(text: MomentSubtitle.text(for: m))
        case .pending, .notWritten, .summariesOff:
            // The sends by code when there are some; else nothing (only reached with a correction to show).
            return m.lines.isEmpty ? FocusSummaryStatus(text: "") : nil
        case .tooLong:
            return m.lines.isEmpty ? FocusSummaryStatus(text: "Too long to summarize") : nil
        case .incomplete:
            return FocusSummaryStatus(text: "Summary unavailable. Some of this moment may be missing.")
        }
    }

    /// The action bar's buttons, in order: Copy Summary (whenever it can run: the moment has a summary) or Summarize
    /// Now, then Forget This Moment…. fix/show-all (owner): no Open Original button: each Windows and pages entry opens
    /// its own page. Find Related Moments, Edit Correction and Exclude stay in the context and Moment menus
    /// (fix/resummarize: so does Summarize Now for a moment that has a summary). fix/expanded-summary: a one-bullet note
    /// that repeats the collapsed subtitle keeps Copy Summary too (the bar matches the menus and the summary above it).
    public static func barItems(_ items: [MomentActionItem], moment: MomentSlice? = nil) -> [MomentActionItem] {
        let kept = items.filter { [.copySummary, .summarizeNow, .forget].contains($0.id) }
            .filter { $0.id != .copySummary || $0.enabled }
        let copy = kept.contains { $0.id == .copySummary && $0.enabled }
        return kept.filter { $0.id != .summarizeNow || !copy }
    }

    /// The body's VoiceOver named actions, in order: open, Copy Summary and Forget This Moment…, each only while it
    /// can run. No Find Related Moments in a moment's detail (owner, 9/30); the row's menus keep it.
    public static func accessibilityActions(_ items: [MomentActionItem]) -> [MomentActionItem] {
        [[MomentActionID.openOriginal, .openApp], [.copySummary], [.forget]].compactMap { ids in
            items.first { ids.contains($0.id) && $0.enabled }
        }
    }
}

/// One window or page in `Windows and pages`.
public struct FocusListSource: Identifiable, Equatable {
    /// `page|bundle|host` (`page|bundle|host|link` for a page with its own link) or `window|bundle|title`.
    public let id: String
    public let bundle: String
    /// The app's display name; nil when only a bundle ID is known.
    public let app: String?
    /// The page's host; empty for a window.
    public let site: String
    public let title: String
    /// First and last time the source was seen in the moment.
    public let first: Date
    public let last: Date
    public let count: Int
    /// The action its arrow opens: the source's latest.
    public let openActionID: String
    /// That action's own evidence.
    public let evidenceIDs: [String]
    /// The person typed, sent or drafted here (`FocusAppCard.writingKinds`).
    public var wrote: Bool = false
    /// page-links-1003: the page's own link (`CanonicalAction.link`) its entry opens; nil for a window or a page saved
    /// without one (it opens its site).
    public var link: String? = nil

    public var isWeb: Bool { !site.isEmpty }
    /// "youtube.com/watch…", else the site.
    public var place: String { link.flatMap(BrowserSites.shortLink) ?? site }

    /// "support.apple.com · 2:40 PM", "2:31–3:18 PM": a page's host (when its title isn't the host), then
    /// when it was seen (a span of observations, never "edited"). The icon names the app, so the line doesn't.
    /// When not every action of the moment was read (`complete` false), the span isn't known, so no time.
    public func detail(_ tz: TimeZone, complete: Bool = true) -> String {
        let when = complete ? DaydreamFormat.range(first, last, tz) : nil
        let host = isWeb && title != site ? site : nil
        return [host, when].compactMap { $0 }.joined(separator: " · ")
    }
}

/// See `FocusListExpanded.summaryStatus(for:provider:)`.
public struct FocusSummaryStatus: Equatable {
    /// Kept for callers; always false (fix/day-card: no skeleton anywhere).
    public let skeleton: Bool
    public let text: String
    public let detail: String?
    /// Summaries are off: `Turn On in Settings` follows when Settings can open.
    public let settingsLink: Bool
    public init(skeleton: Bool = false, text: String, detail: String? = nil, settingsLink: Bool = false) {
        self.skeleton = skeleton; self.text = text; self.detail = detail; self.settingsLink = settingsLink
    }
}

private enum FocusSourcesLoad: Equatable {
    case loading
    /// `complete`: every member action was read (else the list is what was read).
    case loaded([FocusListSource], complete: Bool)
    case failed
}

// MARK: - Action bar

/// `Open Original  Copy Summary` … `Forget This Moment…`. When the row
/// is too narrow the privacy action moves under the others.
private struct FocusActionBar: View {
    let items: [MomentActionItem]
    let perform: (MomentActionID) -> Void
    /// Drawn right after the main buttons (Summarize Now beside Copy Summary).
    var extra: AnyView? = nil

    var body: some View {
        let main = items.filter { $0.group != .privacy }, privacy = items.filter { $0.group == .privacy }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(main) { button($0) }
                if let extra { extra }
                Spacer(minLength: 12)
                ForEach(privacy) { privacyButton($0) }
            }
            VStack(alignment: .leading, spacing: 8) {
                Flow(spacing: 8, line: 34) { ForEach(main) { button($0) }; if let extra { extra } }
                ForEach(privacy) { privacyButton($0) }
            }
        }
    }

    private func button(_ item: MomentActionItem) -> some View {
        // No shortcut text on the button: the Moment menu shows it.
        Button { perform(item.id) } label: { Text(item.title) }
        .buttonStyle(FocusActionButtonStyle(prominent: item.group == .open))
        .disabled(!item.enabled)
        .help(item.enabled ? (item.help ?? item.title) : (item.reason ?? item.title))
        .accessibilityLabel(item.title)
    }

    private func privacyButton(_ item: MomentActionItem) -> some View {
        Button { perform(item.id) } label: {
            HStack(spacing: 5) {
                Image(systemName: item.symbol).font(.system(size: 11, weight: .medium))
                Text(item.title).font(.system(size: 12))
            }
            .foregroundStyle(item.destructive ? Color.red.opacity(0.85) : Color.accentColor)
            .frame(height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(item.enabled ? 1 : 0.45)
        .disabled(!item.enabled)
        .help(item.enabled ? (item.help ?? item.title) : (item.reason ?? item.title))
        .accessibilityLabel(item.title)
    }
}

/// The expanded body's 26 pt buttons (home-C `ExpandedRowC.action`): radius 7, title 12 medium. One
/// prominent (accent) button per bar: the open action.
struct FocusActionButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return configuration.label
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1).fixedSize()
            .foregroundStyle(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary.opacity(0.85)))
            .padding(.horizontal, 11).frame(height: 26)
            .background(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(DaydreamStyle.pillFill), in: shape)
            .overlay(shape.fill(Color.black.opacity(configuration.isPressed ? 0.12 : 0)))
            .contentShape(shape)
            .opacity(enabled ? 1 : 0.45)
    }
}

/// VoiceOver named actions on the expanded body (amendments A1).
private struct FocusExpandedAccessibilityActions: ViewModifier {
    let items: [MomentActionItem]
    let perform: (MomentActionID) -> Void
    func body(content: Content) -> some View {
        content.accessibilityActions {
            ForEach(items) { item in Button(item.title) { perform(item.id) } }
        }
    }
}

/// fix/show-all: one Windows and pages entry as its own click target: a hover fill and an arrow that shows on hover (its
/// slot is always there, so nothing moves). Without `run` it is plain text.
struct FocusSourceEntry<Label: View>: View {
    let help: String?
    let dimmed: Bool
    let run: (() -> Void)?
    @ViewBuilder let label: () -> Label
    @Environment(\.daydreamStatic) private var isStatic
    @State private var hovered = false

    var body: some View {
        let row = HStack(spacing: 6) {
            label()
            Image(systemName: "arrow.up.forward").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .opacity(run != nil && hovered ? 1 : 0)
                .accessibilityHidden(true)
                .padding(.trailing, 10)
        }
        .opacity(dimmed ? 0.5 : 1)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(run != nil && hovered ? 0.05 : 0)).padding(.horizontal, 4))
        .contentShape(Rectangle())
        // Always the same button (never swapped for plain text when a page fails): no focusable view comes or goes.
        Button { run?() } label: { row }
            .buttonStyle(.plain)
            .allowsHitTesting(run != nil)
            .onHover { hovered = isStatic ? false : $0 }
            .help(help ?? "")
            .accessibilityElement(children: .combine)
            .accessibilityHint(help ?? "")
    }
}

/// claude/messages2-1003 (owner 10/3): a Texts card's (and its details page's) Summary: each conversation's name or
/// number, an optional short gist when it has more texts than shown, then the texts sent, verbatim, newest first, about
/// 3 each and "+N more".
struct TextThreadList: View {
    let threads: [FocusAppCard.TextThread]
    let size: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(threads.enumerated()), id: \.offset) { _, thread in
                VStack(alignment: .leading, spacing: 4) {
                    Text(thread.title).font(.system(size: size, weight: .semibold)).lineLimit(1)
                    if let gist = thread.gist {
                        Text(gist).font(.system(size: size - 0.5)).foregroundStyle(.secondary).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(thread.shown.enumerated()), id: \.offset) { _, text in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text("\u{2022}").foregroundStyle(.tertiary).accessibilityHidden(true)
                            Text(FocusAppCard.quote(text, limit: FocusAppCard.openQuoteLimit)).lineLimit(4)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .font(.system(size: size))
                    }
                    if let more = FocusAppCard.moreLine(thread.more) {
                        Text(more).font(.system(size: size - 1)).foregroundStyle(.tertiary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// summary-v2's `.sweeping`: one soft violet band, a strip three block-widths wide (35% / 50% / 65%), slid across the WHOLE
/// quote block by a single phase (4.5 s a pass, ease-in-out, looping) and masked to the block's own glyphs, so every line
/// lights together. Off (and gone) once the summary arrives or Summarize Now fails.
private struct QuoteSweep: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active {
            content.overlay(SweepBand().mask(content).allowsHitTesting(false).accessibilityHidden(true))
        } else {
            content
        }
    }
}

private struct SweepBand: View {
    @State private var phase: Double = 0
    var body: some View {
        GeometryReader { g in
            let w = max(g.size.width, 1)
            LinearGradient(stops: [.init(color: DaydreamStyle.sweep.opacity(0), location: SummarySweep.stops[0]),
                                   .init(color: DaydreamStyle.sweep, location: SummarySweep.stops[1]),
                                   .init(color: DaydreamStyle.sweep.opacity(0), location: SummarySweep.stops[2])],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: w * 3, height: g.size.height)
                .offset(x: w * SummarySweep.offset(phase: phase))
        }
        .onAppear {
            withAnimation(.easeInOut(duration: SummarySweep.period).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}
