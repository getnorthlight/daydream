import Foundation

// agent-tools v2, WP-B (plan §5.4): how important one item is. Importance first, time second: a 90-second application
// form outranks an hour of feed (data-audit §5: by time alone feeds and system UI beat people and searches).
//
//   score = base(kind)                                   forms > documents > people > searches, AI prompts > email >
//                                                        terminal > articles/posts > apps > feeds, home, mailbox views,
//                                                        system UI > DayDream
//         + visits·log1p(visits) + daysSeen·log1p(days − 1)
//         + minutes·log1p(min(minutes, cap)) + typed·log1p(min(typedWords, cap))     (log-capped engagement)
//         + keyword (application, form, due, deadline, assignment, interview, offer, invoice, contract, syllabus, exam)
//         + recency·(1 − age / window)
//
// Feeds, mailbox views, system UI and DayDream's own windows can never climb out of their tier: their bonus is capped
// (`lowTierBonusCap`), so no amount of scrolling outranks a page. Typed counts are a ranking signal only; they are never
// rendered. Every number is in `Weights`, and `score(_:now:)` uses `Weights.standard`.
extension AgentRank {
    public struct Weights: Equatable, Sendable {
        public var base: [AgentEntityKind: Double]
        /// `.app(lowValue: true)`: system UI, a browser's new tab, a Finder place.
        public var lowValue: Double
        /// DayDream's own windows.
        public var daydream: Double
        /// A mailbox view (`.email(nil)`: Inbox, Sent, Drafts …).
        public var mailbox: Double
        /// A search page with no words kept (`.webSearch(_, nil)`).
        public var siteOnlySearch: Double
        public var visits: Double
        public var daysSeen: Double
        public var minutes: Double
        public var minutesCap: Double
        public var typedWords: Double
        public var typedWordsCap: Double
        public var keyword: Double
        public var keywords: [String]
        public var recency: Double
        public var recencyWindowHours: Double
        /// Feeds, low-value apps and DayDream: at most this much on top of their base.
        public var lowTierBonusCap: Double

        public init(base: [AgentEntityKind: Double], lowValue: Double, daydream: Double, mailbox: Double, siteOnlySearch: Double, visits: Double, daysSeen: Double, minutes: Double,
                    minutesCap: Double, typedWords: Double, typedWordsCap: Double, keyword: Double, keywords: [String], recency: Double,
                    recencyWindowHours: Double, lowTierBonusCap: Double) {
            self.base = base; self.lowValue = lowValue; self.daydream = daydream; self.mailbox = mailbox; self.siteOnlySearch = siteOnlySearch; self.visits = visits; self.daysSeen = daysSeen
            self.minutes = minutes; self.minutesCap = minutesCap; self.typedWords = typedWords; self.typedWordsCap = typedWordsCap
            self.keyword = keyword; self.keywords = keywords; self.recency = recency; self.recencyWindowHours = recencyWindowHours
            self.lowTierBonusCap = lowTierBonusCap
        }

        public static let standard = Weights(
            base: [.form: 100, .document: 80, .person: 70, .webSearch: 60, .aiChat: 60, .email: 50, .terminal: 45, .page: 35, .app: 30, .feed: 10],
            lowValue: 10, daydream: 0, mailbox: 10, siteOnlySearch: 35, visits: 8, daysSeen: 6, minutes: 10, minutesCap: 120, typedWords: 6, typedWordsCap: 2_000,
            keyword: 25,
            keywords: ["application", "applications", "apply", "form", "forms", "due", "deadline", "deadlines", "assignment", "assignments",
                       "interview", "interviews", "offer", "offers", "invoice", "invoices", "contract", "contracts", "syllabus", "exam", "exams"],
            recency: 10, recencyWindowHours: 168, lowTierBonusCap: 15)
    }

    public static func score(_ item: AgentItem, now: Date) -> Double { score(item, now: now, weights: .standard, daysSeen: 1) }

    /// `daysSeen`: on how many days the same entity appears (a search over several days knows it; one day's items pass 1).
    public static func score(_ item: AgentItem, now: Date, weights w: Weights, daysSeen: Int = 1) -> Double {
        let (base, cap) = tier(item.entity, weights: w)
        var bonus = w.visits * log1p(Double(max(item.visitCount, 0)))
            + w.daysSeen * log1p(Double(max(daysSeen - 1, 0)))
            + w.minutes * log1p(min(max(item.minutes, 0), w.minutesCap))
            + w.typedWords * log1p(min(Double(max(item.typedWords, 0)), w.typedWordsCap))
        if cap == nil, keywordHit(AgentEntities.name(item.entity), keywords: w.keywords) { bonus += w.keyword }
        let ageHours = max(0, now.timeIntervalSince(item.lastAt) / 3600)
        bonus += w.recency * max(0, 1 - ageHours / max(w.recencyWindowHours, 1))
        if let cap { bonus = min(bonus, cap) }
        return (base + bonus).rounded(toPlaces: 3)
    }

    /// The base for an item's kind, and the cap on its bonus for the low tiers: feeds, a mailbox view, system UI, a
    /// browser's new tab or a Finder place, and DayDream's own windows. A search with no words ranks as a page.
    static func tier(_ entity: AgentEntity, weights w: Weights) -> (base: Double, cap: Double?) {
        switch entity {
        case .app(let name, _, true): return name == "DayDream" ? (w.daydream, w.lowTierBonusCap / 3) : (w.lowValue, w.lowTierBonusCap)
        case .feed: return (w.base[.feed] ?? w.lowValue, w.lowTierBonusCap)
        case .email(nil): return (w.mailbox, w.lowTierBonusCap)
        case .webSearch(_, nil): return (w.siteOnlySearch, nil)
        default: return (w.base[entity.kind] ?? w.base[.app] ?? 0, nil)
        }
    }

    /// A whole-word keyword in the item's name ("Offer letter", "Exam 2 review"; never "produce", "format", "example").
    public static func keywordHit(_ name: String, keywords: [String] = Weights.standard.keywords) -> Bool {
        let words = Set(name.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init))
        return keywords.contains(where: words.contains)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let f = pow(10, Double(places)); return (self * f).rounded() / f
    }
}
