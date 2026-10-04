import SwiftUI
import AppKit
import MemoryCore

// Recall's result list (find-A `AList`/`ARow`/`ASection`, `AHomeRow`): section labels, 48 pt rows,
// the Search More History row, and the no-results, error and empty states.

// MARK: - Small parts

/// A one-pixel rule at any backing scale (find-A draws `Divider()`): a 0.5 pt frame rounds to 0 or
/// 1 px at 1× depending on where it lands, so some rules vanished.
struct RecallHairline: View {
    enum Axis { case horizontal, vertical }
    var axis: Axis = .horizontal
    @Environment(\.displayScale) private var scale
    var body: some View {
        let px = 1 / max(scale, 1)
        Rectangle().fill(DaydreamStyle.hairline)
            .frame(width: axis == .vertical ? px : nil, height: axis == .horizontal ? px : nil)
            .accessibilityHidden(true)
    }
}

/// `Best match`, `Today`, `Sep 14` (with the year trailing only for another year) (find-A `ASection`).
struct RecallSectionLabel: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1) }
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A row's icon: the site monogram for a web row, else the app icon with a second-app badge.
struct RecallRowIcon: View {
    let row: RecallRow
    let size: CGFloat
    let ring: Color
    var body: some View {
        Group {
            if let m = row.moment {
                MomentIcon(moment: m, size: size, ring: ring)
            } else if let site = row.site, KitBrowsers.isBrowser(row.bundle) || row.bundle == nil {
                WebMonogramTile(domain: site, browserBundle: row.bundle, size: size)
            } else {
                AppIcon(bundle: row.bundle, name: row.appName, size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Row

/// A 48 pt result row: icon, highlighted title, start time; the matched field (the highlight shows why it matched).
struct RecallResultRow: View {
    let row: RecallRow
    let terms: [String]
    let selected: Bool
    let best: Bool
    let timeZone: TimeZone
    let voiceOver: String

    /// Every literal match of the row's hits, in hit order.
    private var matches: [RecallMatch] { row.hits.flatMap { RecallText.matches($0, terms: terms, typed: row.typed[$0.id]) } }
    /// "Recent": no query, no hits (find-A `AHomeRow`).
    private var recent: Bool { row.isRecent }

    /// A match as the subtitle shows it (a page reads "title · host"; page-links-1003: its short link in place of the
    /// host when it has one, and never the row's own title again).
    private func line(_ m: RecallMatch) -> String { Self.line(m, row: row) }
    static func line(_ m: RecallMatch, row: RecallRow) -> String {
        if m.source == .page, let hit = row.hits.first(where: { RecallText.webHost($0.evidence.url) == m.text }) {
            let place = hit.evidence.page.flatMap(BrowserSites.shortLink) ?? m.text
            let title = hit.evidence.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty || title.caseInsensitiveCompare(row.title.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame { return place }
            return title + " · " + place
        }
        return m.text
    }

    /// The matched field, unless it only repeats the title (a moment titled by its window): then the
    /// next match that differs, else the moment's row subtitle (its note's first line; never `Summary
    /// pending`), else its site when the title doesn't already name it, else the action's description.
    private var subtitle: String { Self.subtitle(row, matches: matches.map(line)) }

    static func subtitle(_ row: RecallRow, matches: [String]) -> String {
        if let n = row.note { return noteSubtitle(n, row: row) }
        func repeats(_ text: String) -> Bool {
            text.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(row.title.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        }
        if let other = matches.first(where: { !repeats($0) }) { return other }
        if let m = row.moment {
            let text = MomentSubtitle.rowText(for: m)
            // "Had Investor update open in Claude." under "Investor update" says the title again: the app (and site) instead.
            if text.hasPrefix("Had "), row.title.count >= 3, text.localizedCaseInsensitiveContains(row.title) {
                let site = row.site.flatMap { !$0.isEmpty && !row.title.localizedCaseInsensitiveContains($0) ? $0 : nil }
                let place = [row.appName, site ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
                if !place.isEmpty { return place }
            }
            if !text.isEmpty { return text }
            guard let site = row.site, !site.isEmpty, !row.title.localizedCaseInsensitiveContains(site) else { return "" }
            return site
        }
        return row.anchor?.summary ?? ""
    }

    /// The second line of a moment found by its note: "Line in <moment>" for a line, "Moment · App" for the whole note.
    static func noteSubtitle(_ n: NoteHit, row: RecallRow) -> String {
        n.level == "line" ? "Line in " + (n.inTitle ?? n.noteTitle) : (row.appName.isEmpty ? "Moment" : "Moment · " + row.appName)
    }

    var body: some View {
        if recent { recentBody } else { resultBody }
    }

    /// find-A `AHomeRow`: the time sits centred at the trailing edge.
    private var recentBody: some View {
        HStack(spacing: 12) {
            RecallRowIcon(row: row, size: 28, ring: selected ? DaydreamStyle.panelSelection : DaydreamStyle.panelFill)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if !subtitle.isEmpty { subtitleText.font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            Text(DaydreamFormat.time(row.time, timeZone)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: RecallLayout.rowHeight)
        .background(selected ? DaydreamStyle.panelSelection : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceOver)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var resultBody: some View {
        HStack(spacing: 12) {
            RecallRowIcon(row: row, size: 28, ring: selected ? DaydreamStyle.panelSelection : DaydreamStyle.panelFill)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(RecallText.highlighted(row.title, terms: terms)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    Text(DaydreamFormat.time(row.time, timeZone)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize()
                }
                if !subtitle.isEmpty {
                    subtitleText.font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: RecallLayout.rowHeight)
        .background(selected ? DaydreamStyle.panelSelection : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceOver)
        .accessibilityValue(best ? "Best match" : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// One highlight per row (owner, Preview 2: "so much is being highlighted"): the title's match, and the subtitle's
    /// only when the title doesn't have one.
    private var subtitleText: Text {
        Text(RecallText.highlighted(subtitle, terms: RecallText.mentions(row.title, terms: terms) ? [] : terms))
    }

}

// MARK: - List

/// The scrolling list. It stays mounted while a detail is pushed, so its scroll position and selection
/// are exactly where they were when the detail pops.
struct RecallList: View {
    @ObservedObject var model: RecallModel
    @ObservedObject var today: TodayDigest

    var body: some View {
        let terms = model.terms
        let selected = model.selectedRow?.id
        let tz = model.timeZone
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if model.showsRecents {
                        let rows = model.displayRows
                        if !rows.isEmpty {
                            RecallSectionLabel(title: RecallModel.recentsTitle)
                            ForEach(rows) { row in
                                rowView(row, terms: [], selected: row.id == selected, best: false, tz: tz)
                            }
                        }
                    } else {
                        ForEach(Array(model.sections.enumerated()), id: \.element.id) { index, section in
                            RecallSectionLabel(title: section.title, detail: section.detail).padding(.top, index == 0 ? 0 : 4)
                            ForEach(section.rows) { row in
                                rowView(row, terms: terms, selected: row.id == selected, best: section.best, tz: tz)
                            }
                        }
                        if model.hasMore { searchMoreRow }
                    }
                }
                .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onChange(of: model.scrollSerial) { _ in
                if let id = model.selectedRow?.id { proxy.scrollTo(id) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Results")
    }

    private func rowView(_ row: RecallRow, terms: [String], selected: Bool, best: Bool, tz: TimeZone) -> some View {
        RecallResultRow(row: row, terms: terms, selected: selected, best: best, timeZone: tz, voiceOver: model.voiceOverLabel(row))
            .id(row.id)
            .onTapGesture { model.select(row.id); model.requestFocus() }
            .simultaneousGesture(TapGesture(count: 2).onEnded { model.select(row.id); model.openMoment(); model.requestFocus() })
            .accessibilityAction { model.select(row.id); model.openMoment() }
            // Secondary click: the ⌘K Actions menu's items for this row.
            .contextMenu { MomentContextMenu(items: model.menuItems(for: row)) { model.run($0, onRow: row.id) } }
    }

    private var searchMoreRow: some View {
        Button { model.searchMore(); model.requestFocus() } label: {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text("Search More History").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Keycap("⌥↩")
            }
            .padding(.horizontal, 10).frame(height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.busy)
        .padding(.top, 2)
        .accessibilityLabel("Search More History")
    }
}

// MARK: - States

/// `No moments match "{q}"` (+ Search More History). The range button and the footer say what was searched.
struct RecallNoResults: View {
    @ObservedObject var model: RecallModel
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 26, weight: .regular)).foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text(model.emptyTitle)
                .font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center).lineLimit(2)
            if model.hasMore {
                Button("Search More History") { model.searchMore(); model.requestFocus() }
                    .buttonStyle(ShellButtonStyle())
                    .padding(.top, 6)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// `Search unavailable.` + `Try Again` (the button says what to do).
struct RecallErrorState: View {
    @ObservedObject var model: RecallModel
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(model.error ?? RecallModel.unavailableText).font(.system(size: 13)).foregroundStyle(.secondary)
            Button("Try Again") { model.retry(); model.requestFocus() }
                .buttonStyle(ShellButtonStyle())
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// Empty query and nothing recorded today yet.
struct RecallNothingRecent: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 26)).foregroundStyle(.tertiary)
            Text("Recent moments from today appear here.").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
