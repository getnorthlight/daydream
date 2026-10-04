import Foundation
import PrivacyPolicy

// claude/day-review-1003 (owner-approved design, realmock/day-review.html): the Today card's day review. A flat list of
// bullets in rank groups (3 for the top thread, 2 for the second, then 1 each for the next two; 7 at most, fewer on a
// thin day), no titles, no durations, no counts, no times. Each bullet is a lead from the records ("Told Jamie
// Lin", "Asked Claude Code", "Watched", "Replied to"; full ink, never bold since claude/today-copy-1004), then the rest: a link (a post or video title), a
// short clause the model wrote for the thread, or the code's own tail ("on YouTube"), and a quote of the person's own
// words, picked by code.
//
// Everything here is code: threads, scores, ranks, leads, links, which typed row is quoted. The model writes only the
// short clause for a thread (`DayReviewClauses`), cached per thread and written again only when the thread changes
// materially; the review is put together from cached pieces on every read, with no model call. A quote's words are
// never part of these values: they are opened in the DayDream app's own process only (`ownerReviewQuotes`) and held in
// memory for the card that draws them.

public enum DayReview {
    public static let version = "day-review1"
    /// Bullets per rank group: the top thread, the second, then one each for the next two.
    public static let slots = [3, 2, 1, 1]
    /// Score weights: a minute of focused time is 1; words written count 1 per `wordsPerPoint`; a send to a person
    /// (a text, an email, a post) counts `personSend`, an ask of an AI app `askSend`.
    public static let wordsPerPoint = 20.0
    public static let personSend = 15.0
    public static let askSend = 4.0
    /// People boosts: texting in this many separate hours of the day multiplies the thread's score by `steadyFactor`;
    /// each high-stakes signal on a send adds `stakesBoost`, at most `stakesCap` per thread.
    public static let steadyHours = 3
    public static let steadyFactor = 1.5
    public static let stakesBoost = 25.0
    public static let stakesCap = 75.0
    /// Hysteresis: a thread moves above the one over it only after beating it by `margin` for `hold`.
    public static let margin = 1.25
    public static let hold: TimeInterval = 3 * 60
    /// The model writes clauses only once the day has this much focused time or this many sends to people.
    public static let warmSeconds = 20 * 60
    public static let warmSends = 3
    /// A thread's clause is written again at most this often (material change only), except in the final pass.
    public static let clauseEvery: TimeInterval = 15 * 60
    /// From this local hour, and on any later day, a stale clause is written again at once (the final pass).
    public static let finalHour = 21
    /// A remembered "nothing due" look is checked again after at most this long, changes or not.
    public static let idleRecheck: TimeInterval = 10 * 60

    /// High-stakes signals on a send to a person.
    public enum Stake: String, Codable, CaseIterable, Sendable {
        case long, rewritten, paused, firstContact, lateNight
    }
    /// A send is long from this many words (or keys, when the words aren't counted).
    public static let longWords = 40, longKeys = 200
    /// Rewritten: at least this many edits, and at least a quarter of the keys.
    public static let rewrittenEdits = 10
    /// Paused: composed over at least this long, or sealed in more than one part.
    public static let pausedSeconds: TimeInterval = 120

    /// The high-stakes signals of one send (code only, from its counts and times).
    public static func stakes(words: Int, keys: Int?, edits: Int?, parts: Int, composeSeconds: TimeInterval, localHour: Int, firstContact: Bool) -> [Stake] {
        var out = [Stake]()
        if words >= longWords || (keys ?? 0) >= longKeys { out.append(.long) }
        if let edits, edits >= rewrittenEdits, edits * 4 >= (keys ?? 0) { out.append(.rewritten) }
        if parts > 1 || composeSeconds >= pausedSeconds { out.append(.paused) }
        if firstContact { out.append(.firstContact) }
        if localHour >= 23 || localHour < 5 { out.append(.lateNight) }
        return out
    }
    /// How much went into a send: its words and edits, and a pause over it. The quote is the latest send or this one.
    public static func effort(words: Int, edits: Int?, stakes: [Stake]) -> Double {
        Double(words) + Double(edits ?? 0) + (stakes.contains(.paused) ? 20 : 0) + (stakes.contains(.rewritten) ? 10 : 0)
    }
    /// A thread's score: time + words written + sends, sends weighted heavily; people boosts on top.
    public static func score(seconds: Int, words: Int, personSends: Int, asks: Int, sendHours: Int, stakes: Int) -> Double {
        var s = Double(seconds) / 60 + Double(words) / wordsPerPoint + Double(personSends) * personSend + Double(asks) * askSend
        if sendHours >= steadyHours { s *= steadyFactor }
        s += min(stakesCap, Double(stakes) * stakesBoost)
        return (s * 1000).rounded() / 1000
    }
}

/// A link a bullet carries: a page, a post or a video, by its title; `url` is the stored page link (or the site).
public struct DayReviewLink: Codable, Equatable, Sendable {
    public var title: String
    public var url: String?
    public init(title: String, url: String?) { self.title = title; self.url = url }
}

/// One candidate bullet of a thread, by code.
public struct DayReviewItem: Codable, Equatable, Sendable {
    /// Stable within the day.
    public var id: String
    /// The lead when the item has its clause ("Told Jamie Lin", "Asked Claude Code", "Replied to").
    public var lead: String
    /// The lead without a clause ("Texted Jamie Lin"); nil: `lead`.
    public var plainLead: String?
    /// The rest follows the lead after a colon ("Worked on DayDream: …"), not a space ("Told Jamie Lin you …").
    public var colon: Bool
    public var link: DayReviewLink?
    /// The code's own rest when there is no clause ("on YouTube", "about DayDream").
    public var tail: String?
    /// The cached clause that fills the item (`DayReviewFacts.clauses`); nil: code only.
    public var clauseKey: String?
    /// The typed row whose words are the quote (opened in the app only), and whether it shows with a clause too.
    public var quote: String?
    public var quoteAlways: Bool
    /// The person's own words read from a window title (a search), shown as a quote with no typed row opened.
    public var inlineQuote: String?
    public var score: Double
    public var moments: [String]
    /// The typed row quoted instead of `quote` once the clause `quoteWithClause` is cached (a person's second line quotes
    /// the latest text when the first line says it in a clause). Facts are kept apart from the clauses (cached per day),
    /// so this is decided when the bullets are put together.
    public var clauseQuote: String? = nil
    public var quoteWithClause: String? = nil
    /// Shown only with a quote (a person's second line: without words it would repeat the first).
    public var needsQuote: Bool = false
    public init(id: String, lead: String, plainLead: String? = nil, colon: Bool = false, link: DayReviewLink? = nil, tail: String? = nil,
                clauseKey: String? = nil, quote: String? = nil, quoteAlways: Bool = false, inlineQuote: String? = nil, score: Double, moments: [String],
                clauseQuote: String? = nil, quoteWithClause: String? = nil, needsQuote: Bool = false) {
        self.id = id; self.lead = lead; self.plainLead = plainLead; self.colon = colon; self.link = link; self.tail = tail
        self.clauseKey = clauseKey; self.quote = quote; self.quoteAlways = quoteAlways; self.inlineQuote = inlineQuote
        self.score = score; self.moments = moments
        self.clauseQuote = clauseQuote; self.quoteWithClause = quoteWithClause; self.needsQuote = needsQuote
    }
}

/// One thread of the day as the review ranks it: a project or a person across apps, or a thing on its own.
public struct DayReviewThread: Codable, Equatable, Sendable {
    /// "project:daydream", "person:jamie lin", or the planner's key ("video:youtube.com|…", "social:x").
    public var key: String
    /// "DayDream", "Jamie Lin", "YouTube".
    public var name: String
    /// project | person | social | video | web | search | ai | code | doc | meeting | app | other
    public var kind: String
    public var seconds: Int
    public var words: Int
    public var personSends: Int
    public var asks: Int
    public var sendHours: Int
    public var stakes: [DayReview.Stake]
    public var score: Double
    /// Candidate bullets, best first.
    public var items: [DayReviewItem]
    public var moments: [String]
    /// claude/today-rank-1005: work | browsing | personal (`DayReview.Category`), as the store read the thread's channel
    /// and site; nil (an older value): from `kind` and `key` alone.
    public var category: String?
    public init(key: String, name: String, kind: String, seconds: Int, words: Int, personSends: Int, asks: Int, sendHours: Int,
                stakes: [DayReview.Stake], score: Double, items: [DayReviewItem], moments: [String], category: String? = nil) {
        self.key = key; self.name = name; self.kind = kind; self.seconds = seconds; self.words = words; self.personSends = personSends
        self.asks = asks; self.sendHours = sendHours; self.stakes = stakes; self.score = score; self.items = items; self.moments = moments
        self.category = category
    }
    /// The thread's category for ranking (`DayReview.rankScores`).
    public var rankCategory: DayReview.Category {
        category.flatMap(DayReview.Category.init(rawValue:)) ?? DayReview.category(kind: kind, key: key, channel: nil)
    }
}

/// The day's review facts, from the day read (`MemoryStore.dayLevels`): threads by score and the cached clauses.
public struct DayReviewFacts: Codable, Equatable, Sendable {
    public var day: String
    /// Best first (score, then key).
    public var threads: [DayReviewThread]
    /// Clause key -> the model's clause, as cached (`review_clauses`).
    public var clauses: [String: String]
    /// Focused seconds and sends to people across the day (the early-day gate).
    public var activeSeconds: Int
    public var personSends: Int
    /// The quotes' words by typed row, opened in the DayDream app only (`ownerReviewQuotes`). Never encoded.
    public var quotes: [String: String] = [:]
    enum CodingKeys: String, CodingKey { case day, threads, clauses, activeSeconds, personSends }
    public init(day: String, threads: [DayReviewThread], clauses: [String: String], activeSeconds: Int, personSends: Int) {
        self.day = day; self.threads = threads; self.clauses = clauses; self.activeSeconds = activeSeconds; self.personSends = personSends
    }
    /// The early-day gate: enough of the day for the model's clauses.
    public var warm: Bool { activeSeconds >= DayReview.warmSeconds || personSends >= DayReview.warmSends }
    /// Every typed row a shown bullet may quote.
    public var quoteIDs: [String] {
        var out = [String]()
        for t in threads.prefix(DayReview.slots.count + 2) {
            for i in t.items.prefix(4) { for q in [i.quote, i.clauseQuote].compactMap({ $0 }) where !out.contains(q) { out.append(q) } }
        }
        return out
    }
}

/// A bullet as the card draws it.
public struct DayReviewBullet: Equatable, Sendable, Identifiable {
    public var id: String
    /// The thread it belongs to.
    public var thread: String
    /// Full ink, regular weight (owner 10/04: no bold). Ends with ":" when the rest or the quote follows a name ("Worked on DayDream:", "Texted Jamie Lin:").
    public var lead: String
    public var link: DayReviewLink?
    /// Normal weight, after the link.
    public var rest: String?
    /// The person's exact words, drawn in italic quotes.
    public var quote: String?
    public var moments: [String]
    public init(id: String, thread: String, lead: String, link: DayReviewLink?, rest: String?, quote: String?, moments: [String]) {
        self.id = id; self.thread = thread; self.lead = lead; self.link = link; self.rest = rest; self.quote = quote; self.moments = moments
    }
    /// The bullet as one plain line, its quote cut to one line (checks): "Told Jamie Lin you and friends are going to ZUX tomorrow."
    public var text: String { line(quote: shortQuote) }
    /// The same with the whole quote (VoiceOver, the expanded bullet).
    public var fullText: String { line(quote: quote) }
    private func line(quote: String?) -> String {
        var s = lead
        if let link { s += " " + link.title }
        if let rest { s += " " + rest }
        if let quote { s += (link == nil && rest == nil ? " " : ": ") + "\u{201C}" + quote + "\u{201D}" }
        else if let last = s.last, !".?!…\u{201D}".contains(last) { s += "." }
        return s
    }
    /// The quote as the bullet first shows it: one line, about `DayReview.quoteLine` characters (owner 10/03).
    public var shortQuote: String? { quote.map { DayReview.oneLine($0) } }
    /// The quote was cut: clicking the bullet shows all of it, and clicking again folds it back.
    public var expandable: Bool { quote.map { DayReview.oneLine($0) != $0 } ?? false }
    /// The plain text's end: a period unless it ends with a quote or its own mark.
    public var closing: String {
        if quote != nil { return "" }
        let s = rest ?? link?.title ?? lead
        guard let last = s.last else { return "" }
        return ".?!…\u{201D}:".contains(last) ? "" : "."
    }
}

/// A rank group: one thread's bullets, or the last group's two single bullets.
public struct DayReviewGroup: Equatable, Sendable, Identifiable {
    public var id: String
    public var bullets: [DayReviewBullet]
    public init(id: String, bullets: [DayReviewBullet]) { self.id = id; self.bullets = bullets }
}

/// Hysteresis for an order (threads in a day, or items in a thread): a key moves above the one over it only after
/// beating it by `DayReview.margin` for `DayReview.hold`, so the review doesn't reshuffle on every record.
public struct DayReviewStanding: Equatable, Sendable {
    public var order: [String] = []
    /// Since when each key has been beating the one above it by the margin.
    public var challengers: [String: Date] = [:]
    public var updated: Date? = nil
    public init() {}
    /// An order older than this starts over from the scores (a relaunch, a day left open overnight).
    public static let forget: TimeInterval = 3600

    /// The order for `scores` now, updating the standing. The first order is the scores' own.
    public mutating func rank(_ scores: [String: Double], now: Date, margin: Double = DayReview.margin, hold: TimeInterval = DayReview.hold) -> [String] {
        let raw = DayReviewStanding.raw(scores)
        defer { updated = now }
        if order.isEmpty || updated.map({ now.timeIntervalSince($0) > Self.forget || now < $0 }) == true {
            order = raw; challengers = [:]
            return order
        }
        // Keys that went (a Forget) leave at once; new keys start below the known ones, by score.
        var next = order.filter { scores[$0] != nil }
        for k in raw where !next.contains(k) { next.append(k) }
        var kept = [String: Date]()
        var i = 1
        while i < next.count {
            let up = next[i - 1], me = next[i]
            if let a = scores[me], let b = scores[up], a > b * margin && a > b {
                let since = challengers[me] ?? now
                if now.timeIntervalSince(since) >= hold {
                    next.swapAt(i - 1, i)
                    kept[me] = since
                    // It may go on beating the next one up on a later read; the one it passed starts over.
                    i += 1
                    continue
                }
                kept[me] = since
            }
            i += 1
        }
        order = next; challengers = kept
        return order
    }
    /// Best score first; ties by key.
    public static func raw(_ scores: [String: Double]) -> [String] {
        scores.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }
}

extension DayReview {
    /// claude/today-rank-1005 (owner 10/05): what a thread is, for the order of the Today card. Work (AI apps, code and
    /// terminals, documents, work email and team chat, calendars, spreadsheets, coursework) leads; browsing and social
    /// sites (X, YouTube, a page read) come next; personal conversations (Messages, WhatsApp, Discord and Instagram DMs)
    /// come last. Browsing sits between the two: it is less private than a conversation, and it carries no one else's name.
    public enum Category: String, Codable, CaseIterable, Sendable { case work, browsing, personal }
    /// The weight on a thread's importance score for the card's order: far enough apart that a category moves only as a
    /// whole (an hour of texting stays below ten minutes in Claude), while the score still orders threads inside one.
    public static let categoryWeight: [Category: Double] = [.work: 1, .browsing: 0.01, .personal: 0.0001]
    /// Personal conversations show this many bullets in all once the day has other things (`hasOtherThings`).
    public static let personalBullets = 1
    /// A day has other things once a thread that isn't a conversation has this score (about ten minutes of focus, or an
    /// ask and a few minutes); before that the card is in score order with nothing capped.
    public static let otherThingsScore = 10.0
    /// Sites whose pages are work: documents, spreadsheets, calendars, email, code, design and coursework.
    public static let workHosts: Set<String> = ["docs.google.com", "sheets.google.com", "slides.google.com", "drive.google.com", "calendar.google.com",
        "mail.google.com", "classroom.google.com", "notion.so", "www.notion.so", "figma.com", "github.com", "gitlab.com", "linear.app", "overleaf.com",
        "canvas.instructure.com", "instructure.com", "gradescope.com", "piazza.com", "coursera.org", "edx.org", "blackboard.com", "office.com",
        "outlook.office.com", "outlook.live.com", "onedrive.live.com", "airtable.com", "claude.ai", "chatgpt.com", "chat.openai.com", "gemini.google.com",
        "perplexity.ai", "stackoverflow.com", "developer.apple.com"]
    /// Sites whose pages are private conversations.
    public static let personalHosts: Set<String> = ["web.whatsapp.com", "messenger.com", "discord.com", "instagram.com", "web.telegram.org"]
    /// Apps on their own ("Used …") that are work.
    public static let workApps: Set<String> = ["calendar", "numbers", "pages", "keynote", "microsoft word", "word", "microsoft excel", "excel",
        "microsoft powerpoint", "powerpoint", "xcode", "notion", "linear", "figma", "zoom", "microsoft teams", "teams", "fantastical", "obsidian"]

    /// A thread's category from its kind, key and, for a person, the channel ("texts", "chat", "teams", "slack", "email").
    public static func category(kind: String, key: String, channel: String?, name: String = "") -> Category {
        switch kind {
        case "project", "ai", "code", "doc", "meeting", "pr", "email", "slack": return .work
        case "person", "texts", "chat":
            let c = channel ?? kind
            return ["email", "slack", "teams"].contains(c) || key.hasPrefix("chat:teams") ? .work : .personal
        case "social", "video": return .browsing
        case "web", "search", "site", "page":
            var host = ""
            for p in ["site:", "page:", "video:", "social:", "web:", "search:"] where key.hasPrefix(p) {
                host = String(key.dropFirst(p.count).split(separator: "|").first ?? "").lowercased()
            }
            if host.hasPrefix("www.") { host.removeFirst(4) }
            func matches(_ set: Set<String>) -> Bool { set.contains { host == $0 || host.hasSuffix("." + $0) } }
            if matches(personalHosts) { return .personal }
            return matches(workHosts) ? .work : .browsing
        case "app": return workApps.contains(name.lowercased()) ? .work : .browsing
        default: return .browsing
        }
    }
    /// Whether the day has more than conversations: a thread that isn't one with `otherThingsScore`.
    public static func hasOtherThings(_ facts: DayReviewFacts) -> Bool {
        facts.threads.contains { $0.rankCategory != .personal && $0.score >= otherThingsScore }
    }
    /// The scores the card orders threads by (`DayReviewStanding`): the importance score times its category's weight once
    /// the day has other things; the score alone before that.
    public static func rankScores(_ facts: DayReviewFacts) -> [String: Double] {
        let weighted = hasOtherThings(facts)
        return Dictionary(facts.threads.map { ($0.key, weighted ? $0.score * (categoryWeight[$0.rankCategory] ?? 1) : $0.score) }, uniquingKeysWith: max)
    }

    /// claude/today-copy-1004 (owner 10/04, "it shouldn't say asked claude about claude"): an AI tool, or the app or site an
    /// ask was typed in, names where it was asked, never what it was about.
    public static let askPlaces = ["Claude", "Claude Code", "ChatGPT", "OpenAI", "Anthropic", "Codex", "Cursor", "Gemini", "Perplexity", "Copilot",
                                   "AI", "Google Chrome", "Chrome", "Safari", "Arc", "Firefox", "Terminal", "Ghostty", "Code"]
    /// Words that name no topic on their own (a new chat's title, an email with no subject).
    static let blankTopicWords: Set<String> = ["new", "untitled", "chat", "chats", "conversation", "conversations", "tab", "window", "home",
                                               "no", "subject", "re", "fwd", "the", "a", "an", "of", "and"]
    /// The topic of a code line's "about …" ("Asked Claude about DayDream", "Emailed Sam about Q3 numbers"), trimmed; nil
    /// when it would only say again who or where (`echoing`: the tool, the app, the person, compared by their words, case
    /// and spacing aside: "Asked Claude about Claude", "Asked ChatGPT about ChatGPT") or says nothing (empty, punctuation,
    /// "New chat", "(no subject)"). The line then goes on without its "about …": "Asked Claude: “…”".
    public static func topic(_ raw: String?, echoing names: [String]) -> String? {
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        let words = ThreadEntities.tokens(t)
        let echo = Set(names.flatMap(ThreadEntities.tokens))
        guard !words.isEmpty, !words.allSatisfy({ echo.contains($0) || blankTopicWords.contains($0) }) else { return nil }
        return t
    }

    /// A quote shows on one line first: about this many characters, cut at a word with "…" (owner 10/03).
    public static let quoteLine = 80
    /// `quote` cut to `limit` characters at a word boundary with "…"; as it is when it fits.
    public static func oneLine(_ quote: String, limit: Int = quoteLine) -> String {
        guard quote.count > limit else { return quote }
        var head = String(quote.prefix(limit - 1))
        if let space = head.lastIndex(where: \.isWhitespace), head.distance(from: head.startIndex, to: space) >= limit / 2 { head = String(head[..<space]) }
        while let last = head.last, last.isWhitespace || ",;:-–—".contains(last) { head.removeLast() }
        return head + "…"
    }

    /// The groups the card draws, from the facts, in `order` (nil: by `rankScores`) with each thread's items in `itemOrder`
    /// (nil: by score), and the quotes' words (`facts.quotes` when nil). Threads whose bullets would say nothing new are
    /// passed over. The last two single bullets share one group.
    ///
    /// claude/today-rank-1005 (owner 10/05: "the texting stuff makes people uncomfortable", productivity in front): once the
    /// day has other things (`hasOtherThings`), personal conversations come after every other thread and show one bullet
    /// in all, from the best of them; it keeps the last place when the others would fill every group, so a conversation
    /// is never hidden. On a day with little else the order is the importance score's and nothing is capped.
    public static func assemble(_ facts: DayReviewFacts, order: [String]? = nil, itemOrder: [String: [String]] = [:], quotes: [String: String]? = nil) -> [DayReviewGroup] {
        let words = quotes ?? facts.quotes
        let byKey = Dictionary(facts.threads.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var keys = (order ?? DayReviewStanding.raw(rankScores(facts))).filter { byKey[$0] != nil }
        let capped = hasOtherThings(facts)
        var personal = [String]()
        if capped {
            personal = keys.filter { byKey[$0]?.rankCategory == .personal }
            keys = keys.filter { byKey[$0]?.rankCategory != .personal }
        }
        var groups = [DayReviewGroup](), seen = Set<String>(), rank = 0
        func place(_ t: DayReviewThread, limit: Int) -> Bool {
            let ids = itemOrder[t.key] ?? t.items.map(\.id)
            let items = ids.compactMap { id in t.items.first { $0.id == id } } + t.items.filter { !ids.contains($0.id) }
            var bullets = [DayReviewBullet]()
            for item in items {
                guard bullets.count < limit else { break }
                let b = bullet(item, thread: t, facts: facts, words: words)
                if item.needsQuote && b.quote == nil { continue }
                let line = b.text.lowercased()
                guard seen.insert(line).inserted else { continue }
                bullets.append(b)
            }
            guard !bullets.isEmpty else { return false }
            if rank >= 2, let last = groups.last, last.id.hasPrefix("rest") {
                groups[groups.count - 1].bullets += bullets
            } else {
                groups.append(DayReviewGroup(id: rank >= 2 ? "rest" : t.key, bullets: bullets))
            }
            rank += 1
            return true
        }
        // A conversation that can show keeps one place, the last, whatever ranks above it.
        let conversation = personal.contains { k in byKey[k]!.items.contains { !$0.needsQuote || ($0.quote.flatMap { words[$0] }.map { !$0.isEmpty } ?? false) } }
        let room = slots.count - (conversation ? 1 : 0)
        for key in keys {
            guard rank < room, let t = byKey[key] else { break }
            _ = place(t, limit: slots[rank])
        }
        for key in personal where rank < slots.count {
            if let t = byKey[key], place(t, limit: min(personalBullets, slots[rank])) { break }
        }
        return groups
    }

    /// One item as a bullet: its clause when cached (with the lead that goes with it), else the code's own tail; the quote
    /// when there is no clause or the item always shows it, and only when its words were opened.
    public static func bullet(_ item: DayReviewItem, thread: DayReviewThread, facts: DayReviewFacts, words: [String: String]) -> DayReviewBullet {
        let clause = item.clauseKey.flatMap { facts.clauses[$0] }.flatMap { $0.isEmpty ? nil : $0 }
        let lead = clause != nil ? item.lead : (item.plainLead ?? item.lead)
        let rest = clause ?? item.tail
        var quote = item.inlineQuote
        var quoteID = item.quote
        if let k = item.quoteWithClause, let alt = item.clauseQuote, facts.clauses[k].map({ !$0.isEmpty }) == true { quoteID = alt }
        if quote == nil, clause == nil || item.quoteAlways, let id = quoteID, let w = words[id], !w.isEmpty { quote = w }
        // A name-ended lead takes a colon before what follows it: "Worked on DayDream: …", "Texted Jamie Lin: “…”".
        let colon = item.link == nil && ((item.colon && rest != nil) || (rest == nil && quote != nil))
        return DayReviewBullet(id: item.id, thread: thread.key, lead: lead + (colon ? ":" : ""), link: item.link, rest: rest, quote: quote, moments: item.moments)
    }
}

// MARK: - Clauses (the model's only part)

/// What the model is asked for one thread's clause.
public struct DayReviewClauseRequest: Codable, Equatable, Sendable {
    public var day: String
    public var timezone: String
    public var key: String
    /// The bullet's lead and the thread's name ("Told Jamie Lin", "Jamie Lin").
    public var lead: String
    public var name: String
    /// The clause follows the lead after a colon (a description) or a space (the sentence goes on).
    public var colon: Bool
    /// DayDream's moment notes for the thread, title then lines.
    public var notes: [String]
    /// The material-change signature: sends, prompts in tens, moments with notes.
    public var signature: String
    public var actionIDs: [String]
    public var start: String
    public var end: String
    public init(day: String, timezone: String, key: String, lead: String, name: String, colon: Bool, notes: [String], signature: String,
                actionIDs: [String], start: String, end: String) {
        self.day = day; self.timezone = timezone; self.key = key; self.lead = lead; self.name = name; self.colon = colon; self.notes = notes
        self.signature = signature; self.actionIDs = actionIDs; self.start = start; self.end = end
    }
    /// The level request a cloud writer's permit reads (only its start: the cloud reads periods after its cutoff).
    public var levelRequest: LevelRequest {
        LevelRequest(target: "review:" + key, level: .day, period: day, timezone: timezone, start: start, end: end, children: [], actionIDs: actionIDs,
                     inputRevision: signature)
    }
}

/// A cached clause (`review_clauses`).
public struct DayReviewClause: Codable, Equatable, Sendable {
    public var key: String
    public var day: String
    public var text: String
    public var signature: String
    public var writtenAt: String
    public var generator: String
    public var actionIDs: [String]
    public var typed: Bool
    public init(key: String, day: String, text: String, signature: String, writtenAt: String, generator: String, actionIDs: [String], typed: Bool) {
        self.key = key; self.day = day; self.text = text; self.signature = signature; self.writtenAt = writtenAt; self.generator = generator
        self.actionIDs = actionIDs; self.typed = typed
    }
}

public enum DayReviewClauses {
    /// Bumped when the instruction or the checks change: every cached clause is written again.
    /// review-clause2 (claude/scrub-1004): the example names a made-up person and place ("Jamie Lin", "ZUX").
    /// review-clause3 (claude/final-1004): one version above scrub-1004's, with the integrated writers.
    public static let version = "review-clause3-validator2"
    public static let maxTokens = 60
    public static let maxWords = 16
    public static let maxChars = 110
    public static let evidenceChars = 3000

    public static let instruction = """
You finish one bullet of a day review from DayDream's notes about one thread of someone's day on their Mac.
The bullet starts with the bold words you are given; you write only the rest of it, the clause.
Write {"clause":"..."}.
clause: 3 to 14 words that say what the thread was about. Use only what the notes say.
- If the start ends with a name and a colon, write a short description or a list of what was done, like "Messages sends saved as drafts, the Ghostty spinner and missing site icons".
- Otherwise go on with the sentence, like "you and friends are going to ZUX tomorrow" after "Told Jamie Lin", or "to fix the export crash in DayDream" after "Asked Claude Code".
Rules:
- Never repeat the start's words. No quotes, no times, no durations, no counts of things, no ids.
- Use only names in the notes. Name the project when the notes name it.
- Never say sent, finished, fixed or shipped unless the notes say so. A draft stays a draft.
- No subject: never "the user", "they" or "I".
- Never copy a long run of words from a note; say it in your own words.
Answer with JSON only.
"""
    public static let prefill = "{\"clause\":\""

    /// The evidence for one request: the thread, the start, then the notes (trimmed to `evidenceChars`).
    public static func evidence(_ r: DayReviewClauseRequest) -> String {
        var out = "THREAD: " + clean(r.name) + "\nSTART: " + clean(r.lead) + (r.colon ? ":" : "") + "\nNOTES:\n"
        for n in r.notes {
            let line = "- " + clean(n) + "\n"
            if out.count + line.count > evidenceChars { break }
            out += line
        }
        return out
    }
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "<", with: "‹").trimmingCharacters(in: .whitespaces)
    }
    public static func repair(_ r: DayReviewClauseRequest, previous: String, problem: String) -> String {
        evidence(r) + "\nYOUR LAST ANSWER: " + clean(String(previous.prefix(300))) + "\nPROBLEM: " + problem + "\nWrite the clause again."
    }

    public struct Reject: Error, Equatable { public let reason: String }

    /// The clause the model answered, checked: one short line in the start's own grammar, no quotes, no times or
    /// counts, no secrets, no new names, and not the start again.
    public static func validate(_ raw: String, request r: DayReviewClauseRequest) throws -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.hasPrefix("{") { text = prefill + text }
        if let close = text.range(of: "}", options: .backwards) { text = String(text[...close.lowerBound]) } else { text += "\"}" }
        guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawClause = object["clause"] as? String else { throw Reject(reason: "Answer with JSON {\"clause\":\"...\"} only.") }
        var c = rawClause.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = c.last, ".;,".contains(last) { c.removeLast() }
        if let first = c.first, first == ":" { c = String(c.dropFirst()).trimmingCharacters(in: .whitespaces) }
        let words = c.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2, words.count <= maxWords, c.count <= maxChars else { throw Reject(reason: "Write 3 to 14 words.") }
        guard c.rangeOfCharacter(from: CharacterSet(charactersIn: "\"“”«»")) == nil else { throw Reject(reason: "No quotes.") }
        let lower = c.lowercased()
        let banned = ["the user", "they ", "~", " min", " minutes", " hour", " hours", " hr", " am", " pm", "a.m.", "p.m."]
        guard !banned.contains(where: { (" " + lower + " ").contains($0) }), lower.range(of: #"\b\d{1,2}:\d{2}\b"#, options: .regularExpression) == nil
        else { throw Reject(reason: "No times, durations or subject.") }
        let leadWords = Set(ThreadEntities.tokens(r.lead).filter { $0.count >= 3 })
        let first = ThreadEntities.tokens(String(words.prefix(2).joined(separator: " ")))
        guard !first.contains(where: { leadWords.contains($0) && !["about", "with", "for"].contains($0) }) || leadWords.isEmpty
        else { throw Reject(reason: "Don't repeat the start; go on from it.") }
        if case .keep(_, let redactions) = TypedSecretScrubber.scrub(c), redactions.isEmpty {} else { throw Reject(reason: "Leave out codes, keys and numbers.") }
        guard lower.range(of: #"\b(sent|finished|shipped)\b"#, options: .regularExpression) == nil || r.notes.contains(where: { n in
            ["sent", "finished", "shipped"].contains { lower.contains($0) && n.lowercased().contains($0) } })
        else { throw Reject(reason: "Don't claim it was sent, finished or shipped.") }
        // Names: a capitalized word after the first must be in the notes, the start or the thread's name.
        let known = Set(ThreadEntities.tokens(r.notes.joined(separator: " ") + " " + r.lead + " " + r.name))
        for (i, w) in words.enumerated() where i > 0 {
            let t = w.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            guard let f = t.first, f.isUppercase, t.count > 1 else { continue }
            for tok in ThreadEntities.tokens(t) where !known.contains(tok) { throw Reject(reason: "Use only names in the notes (\(tok.count) letters unknown).") }
        }
        if !r.colon, let f = c.first, f.isUppercase, !(known.contains(String(words[0]).lowercased())) {
            c = f.lowercased() + c.dropFirst()
        }
        return c
    }
}
