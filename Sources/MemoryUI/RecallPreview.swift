import SwiftUI
import AppKit
import MemoryCore

// The preview beside the list (find-A `APreview`, `APendingPreview`): header, then what matched (claude/searchui-1005: the
// moment's texts and matching lines, who and when, the hit highlighted), then the note by state and Show in Context. The
// action bar has Open.

/// A small secondary label with an optional trailing detail (find-A `ALabel`).
struct RecallLabel: View {
    let text: String
    var trailing: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
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

/// A result's title and its small label ("Jordan Lane  Texts"): no time, no bold but the highlight.
struct RecallTitleLine: View {
    let row: RecallRow
    let terms: [String]
    let size: CGFloat
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(RecallText.highlighted(row.title, terms: terms)).font(.system(size: size)).lineLimit(2)
            if let label = row.kindLabel {
                Text(label).font(.system(size: max(11, size - 6))).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
        }
    }
}

/// claude/searchui-1005 (owner 10/04: "the actual text evidence stuff is not showing"): the lines that are the evidence,
/// each in its real form: who ("You", or the app), when, then the words with the match highlighted. Regular weight; only
/// the highlight is emphasised.
struct RecallEvidence: View {
    let lines: [RecallHitLine]
    let terms: [String]
    let timeZone: TimeZone

    static func caption(_ line: RecallHitLine, timeZone: TimeZone) -> String {
        [line.who, line.at.map { DaydreamFormat.time($0, timeZone) } ?? ""].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(lines) { line in
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(line.matched ? DaydreamStyle.highlight : Color.primary.opacity(0.14)).frame(width: 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Self.caption(line, timeZone: timeZone)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        Text(RecallText.highlighted(line.text, terms: terms)).font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What matched")
    }
}

/// A note line with the query highlighted (the kit's `Bullet`, which draws plain text).
struct RecallNoteLine: View {
    let bullet: MomentBullet
    let terms: [String]
    var size: CGFloat = 13
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Circle().fill(bullet.correction ? Color.secondary.opacity(0.7) : DaydreamStyle.model)
                .frame(width: 5, height: 5)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + size * 0.28 }
            label.font(.system(size: size)).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
    private var label: Text {
        let body = Text(RecallText.highlighted(bullet.text, terms: terms)).foregroundColor(.primary.opacity(0.8))
        let marker = bullet.correction ? "Your correction" : bullet.interpretation ? "Interpretation" : nil
        guard let marker else { return body }
        return body + Text("  " + marker).italic().foregroundColor(.secondary)
    }
}

struct RecallPreview: View {
    @ObservedObject var model: RecallModel
    let row: RecallRow

    var body: some View {
        let terms = model.terms
        let lines = model.evidenceLines(row)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                header(terms)
                if !lines.isEmpty { RecallEvidence(lines: lines, terms: terms, timeZone: model.timeZone) }
                if let m = row.moment {
                    VStack(alignment: .leading, spacing: 10) {
                        summary(m)
                        ShowInContextButton { model.showInDay() }
                    }
                } else if lines.isEmpty {
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
                RecallTitleLine(row: row, terms: terms, size: 18)
                Text(recallWhen(row, model: model)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    .help(recallObserved(row, model: model) ?? "")
                    .accessibilityLabel(recallWhenSpoken(row, model: model))
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The note after the evidence (owner 10/04: evidence first; "Summaries are off." never stands in for it): its lines
    /// with the query highlighted, minus code's "Read texts with …" when the texts themselves are shown.
    @ViewBuilder private func summary(_ m: MomentSlice) -> some View {
        let evidence = model.evidenceLines(row)
        let generated = RecallModel.noteLines(m.bullets.filter { !$0.correction }, evidence: evidence)
        // Found by one of its lines: every line, so the one that matched (and a send line) is always there.
        let shown = row.note == nil ? 3 : 12
        let corrections = m.bullets.filter(\.correction)
        let terms = model.terms
        VStack(alignment: .leading, spacing: 8) {
            // No "Summary" label and no Cloud chip (owner, Preview 2): the lines sit right under what matched.
            if m.summary.isReady && !m.bullets.filter({ !$0.correction }).isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(generated.prefix(shown).enumerated()), id: \.offset) { _, b in RecallNoteLine(bullet: b, terms: terms) }
                }
            } else {
                switch m.summary {
                case .pending, .notWritten:
                    // fix/day-card: no skeleton; the moment's sends by code (who only), else nothing.
                    ForEach(Array(m.lines.enumerated()), id: \.offset) { _, line in Bullet(line, size: 13) }
                case .summariesOff:
                    if evidence.isEmpty { Text("Summaries are off.").font(.system(size: 12)).foregroundStyle(.secondary) }
                default:
                    let text = MomentSubtitle.text(for: m)
                    if evidence.isEmpty || !text.hasPrefix(RecallModel.readingLine) {
                        Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            if !corrections.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(corrections.enumerated()), id: \.offset) { _, b in Bullet(b, size: 13) }
                }
            }
        }
    }

    /// A single hit with nothing to show as evidence: what it was.
    private var single: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let hit = row.anchor {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(DaydreamFormat.time(row.time, model.timeZone)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)
                    let line = DisplayWords.undraft(hit.summary)
                    Text(RecallText.highlighted(line.isEmpty ? row.title : line, terms: model.terms))
                        .font(.system(size: 12.5)).lineLimit(3)
                }
            }
        }
    }
}
