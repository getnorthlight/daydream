import SwiftUI
import AppKit
import MemoryCore

// The preview beside the list (find-A `APreview`, `APendingPreview`): header and the summary by state, then Show in
// Context (a single action: what it was). The row's highlight shows why it matched, and the action bar has Open.

/// A small secondary label with an optional trailing detail (find-A `ALabel`).
struct RecallLabel: View {
    let text: String
    var trailing: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            if let trailing { Text(trailing).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The hero icon: the site tile for a web row, else the fanned apps.
struct RecallHeroIcon: View {
    let row: RecallRow
    let size: CGFloat
    var body: some View {
        Group {
            if let site = row.site, row.bundle == nil || KitBrowsers.isBrowser(row.bundle) {
                WebMonogramTile(domain: site, browserBundle: row.bundle, size: size)
            } else {
                AppFan(apps: refs, size: size)
            }
        }
        .accessibilityHidden(true)
    }
    private var refs: [MomentIcon.AppRef] {
        guard let m = row.moment else { return [(row.bundle, row.appName)] }
        let primary = m.primaryBundle ?? m.bundles.first
        var out: [MomentIcon.AppRef] = [(primary, m.primaryApp ?? "")]
        if let second = m.bundles.first(where: { $0 != primary }) { out.append((second, KitAppNames.name(for: second) ?? "")) }
        return out
    }
}

/// Help and VoiceOver for a shown span (L16): "Observed from 9:55 to 11:40 AM", so a duration is never
/// heard as active time. nil for a single action.
@MainActor func recallObserved(_ row: RecallRow, model: RecallModel) -> String? {
    guard let m = row.moment else { return nil }
    return "Observed from " + DaydreamFormat.spokenRange(m.start, m.end, model.timeZone)
}

/// VoiceOver for the time line: the day, then the observed span.
@MainActor func recallWhenSpoken(_ row: RecallRow, model: RecallModel) -> String {
    let day = DaydreamFormat.dayName(row.time, now: model.now, calendar: model.calendar)
    guard let m = row.moment else { return day + ", " + DaydreamFormat.time(row.time, model.timeZone) }
    return day + ", observed from " + DaydreamFormat.spokenRange(m.start, m.end, model.timeZone)
}

/// "Today, 9:55–11:40 AM" for a moment (no duration: the range says it); "Today, 10:02 AM" for a single action.
@MainActor func recallWhen(_ row: RecallRow, model: RecallModel) -> String {
    let day = DaydreamFormat.dayName(row.time, now: model.now, calendar: model.calendar)
    guard let m = row.moment else { return day + ", " + DaydreamFormat.time(row.time, model.timeZone) }
    return day + ", " + DaydreamFormat.range(m.start, m.end, model.timeZone)
}

struct RecallPreview: View {
    @ObservedObject var model: RecallModel
    let row: RecallRow

    var body: some View {
        let terms = model.terms
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                header(terms)
                if let m = row.moment {
                    VStack(alignment: .leading, spacing: 10) {
                        summary(m)
                        ShowInContextButton { model.showInDay() }
                    }
                } else {
                    single
                }
            }
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview")
    }

    private func header(_ terms: [String]) -> some View {
        HStack(alignment: .center, spacing: 14) {
            RecallHeroIcon(row: row, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(RecallText.highlighted(row.title, terms: terms)).font(.system(size: 18, weight: .bold)).lineLimit(2)
                Text(recallWhen(row, model: model)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    .help(recallObserved(row, model: model) ?? "")
                    .accessibilityLabel(recallWhenSpoken(row, model: model))
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func summary(_ m: MomentSlice) -> some View {
        let generated = m.bullets.filter { !$0.correction }
        // Found by one of its lines: every line, so the one that matched (and a send line) is always there.
        let shown = row.note == nil ? 3 : 12
        let corrections = m.bullets.filter(\.correction)
        VStack(alignment: .leading, spacing: 8) {
            // No "Summary" label and no Cloud chip (owner, Preview 2): the lines sit right under the title and time.
            if m.summary.isReady && !generated.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(generated.prefix(shown).enumerated()), id: \.offset) { _, b in Bullet(b, size: 13) }
                }
            } else {
                switch m.summary {
                case .pending, .notWritten:
                    // fix/day-card: no skeleton; the moment's sends by code (who only), else nothing.
                    ForEach(Array(m.lines.enumerated()), id: \.offset) { _, line in Bullet(line, size: 13) }
                case .summariesOff:
                    Text("Summaries are off.").font(.system(size: 12)).foregroundStyle(.secondary)
                default:
                    Text(MomentSubtitle.text(for: m)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if !corrections.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(corrections.enumerated()), id: \.offset) { _, b in Bullet(b, size: 13) }
                }
            }
        }
    }

    /// A single hit: what it was.
    private var single: some View {
        VStack(alignment: .leading, spacing: 8) {
            RecallLabel(text: "What happened")
            if let hit = row.anchor {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(DaydreamFormat.time(row.time, model.timeZone)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)
                    // fix/search-1003: a hit found by what was typed shows that part of the words (on this Mac only).
                    let line = row.typed[hit.id] ?? hit.summary
                    Text(RecallText.highlighted(line.isEmpty ? row.title : line, terms: model.terms))
                        .font(.system(size: 12.5)).lineLimit(3)
                }
            }
        }
    }
}
