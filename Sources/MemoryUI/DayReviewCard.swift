import SwiftUI
import MemoryCore

// claude/day-review-1003 (owner-approved design, realmock/day-review.html): the Today card's day review. A flat list
// of bullets in rank groups (3 / 2 / 1 / 1) with a small gap between groups; no titles, durations, counts, times or
// "Updated" line. Each bullet: a lead in the full ink color, then the rest a little lighter, a link in the link color, and
// the person's own words in italic quotes; nothing bold (claude/today-copy-1004, owner 10/04: "I don't like the bold").
// Put together from the day read's facts and cached clauses (`DayReview.assemble`): no model call.

/// The review's order, kept between reads so it doesn't reshuffle on every record (`DayReviewStanding`): a thread moves
/// up only after beating the one above it by a quarter for a few minutes, and a thread's bullets the same way. Today
/// only; a past day shows its final order by score at once.
@MainActor public final class DayReviewMemory {
    public static let shared = DayReviewMemory()
    private var day = ""
    private var threads = DayReviewStanding()
    private var items = [String: DayReviewStanding]()
    public init() {}

    /// The groups to draw for `facts` now. `live`: today's card (hysteresis); otherwise the order by score.
    public func groups(_ facts: DayReviewFacts, live: Bool, now: Date = Date()) -> [DayReviewGroup] {
        // claude/today-rank-1005: threads are ordered by their category-weighted score (work first, conversations last).
        let scores = DayReview.rankScores(facts)
        guard live else { return DayReview.assemble(facts, order: DayReviewStanding.raw(scores)) }
        // Midnight: a new day starts empty.
        if facts.day != day { day = facts.day; threads = DayReviewStanding(); items = [:] }
        let order = threads.rank(scores, now: now)
        var itemOrder = [String: [String]]()
        for t in facts.threads {
            var standing = items[t.key] ?? DayReviewStanding()
            itemOrder[t.key] = standing.rank(Dictionary(t.items.map { ($0.id, $0.score) }, uniquingKeysWith: max), now: now)
            items[t.key] = standing
        }
        // A thread that went (a Forget, a delete) leaves its standing with it.
        let keys = Set(facts.threads.map(\.key))
        items = items.filter { keys.contains($0.key) }
        return DayReview.assemble(facts, order: order, itemOrder: itemOrder)
    }
}

/// The review's bullets as the card draws them. A quote shows on one line first (`DayReviewBullet.shortQuote`); clicking
/// the bullet or its quote shows all of it, smoothly (at once with Reduce Motion), and clicking again folds it back
/// (owner 10/03). That is the bullets' only interaction; a link in one (a post, a video) still opens its page.
public struct DayReviewList: View {
    let groups: [DayReviewGroup]
    let size: CGFloat
    @State private var expanded = Set<String>()
    /// When a link in a bullet last opened: the same click never also folds or unfolds the quote.
    @State private var linkOpenedAt = Date.distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    public init(groups: [DayReviewGroup], size: CGFloat = 13) {
        self.groups = groups; self.size = size
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(group.bullets) { bullet in row(bullet) }
                }
            }
        }
    }

    private func toggle(_ id: String) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    @ViewBuilder private func row(_ b: DayReviewBullet) -> some View {
        let open = expanded.contains(b.id)
        let line = HStack(alignment: .firstTextBaseline, spacing: 9) {
            Circle().fill(DaydreamStyle.model).frame(width: 5, height: 5)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + size * 0.28 }
            Text(Self.attributed(b, size: size, expanded: open)).font(.system(size: size)).lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(open || !b.expandable ? b.fullText : b.text)
        if b.expandable {
            line
                .contentShape(Rectangle())
                // A link's click opens its page (and is noted, so the tap below leaves the quote as it is).
                .environment(\.openURL, OpenURLAction { url in
                    linkOpenedAt = Date()
                    openURL(url)
                    return .handled
                })
                .simultaneousGesture(TapGesture().onEnded {
                    let id = b.id
                    DispatchQueue.main.async {
                        guard Date().timeIntervalSince(linkOpenedAt) > 0.4 else { return }
                        toggle(id)
                    }
                })
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(open ? "Shows less of the quote" : "Shows the whole quote")
                .accessibilityAction { toggle(b.id) }
        } else {
            line
        }
    }

    /// The bullet's styled text, all in regular weight (owner 10/04: no bold): the lead in the full ink color, the link
    /// in the link color, the rest a little lighter, the quote italic in curly quotes (one line of it unless `expanded`).
    /// The colors are the system's own (`.primary`, `.accentColor`), so the light and dark themes keep the same order.
    public static func attributed(_ b: DayReviewBullet, size: CGFloat = 13, expanded: Bool = false) -> AttributedString {
        var out = AttributedString()
        var lead = AttributedString(b.lead)
        lead.font = .system(size: size)
        lead.foregroundColor = .primary
        out += lead
        func plain(_ s: String) -> AttributedString {
            var a = AttributedString(s); a.foregroundColor = Color.primary.opacity(0.78); return a
        }
        if let link = b.link {
            out += plain(" ")
            var a = AttributedString(link.title)
            a.foregroundColor = Color.accentColor
            if let raw = link.url, let url = URL(string: raw) { a.link = url }
            out += a
        }
        if let rest = b.rest { out += plain(" " + rest) }
        if let quote = expanded ? b.quote : b.shortQuote {
            out += plain(b.link == nil && b.rest == nil ? " " : ": ")
            var q = AttributedString("\u{201C}" + quote + "\u{201D}")
            q.font = .system(size: size).italic()
            q.foregroundColor = Color.primary.opacity(0.88)
            out += q
        } else {
            out += plain(b.closing)
        }
        return out
    }
}
