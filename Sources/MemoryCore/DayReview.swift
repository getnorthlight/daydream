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

/// claude/dayeval-1005: the day review's measured changes (scripts/day-review-eval*), each on its own so its gain can be
/// measured; `DayReview.options` is what the app uses. `[]` is the card of claude/today-rank-1005 (faea968) exactly.
public struct DayReviewOptions: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// Projects: the person's own account name is never a project; a project's line says which piece of it ("the
    /// Tallybird pricing page review"), not only its name; remote-screen and utility windows aren't documents.
    public static let projects = DayReviewOptions(rawValue: 1 << 0)
    /// A result the records show ("Submitted", "Signed", "Ordered", "Booked", "Paid") leads its thread's first line.
    public static let outcomes = DayReviewOptions(rawValue: 1 << 1)
    /// No filler: an app only opened ("Used Claude"), posts only read ("Read posts on X"), a site with no page
    /// ("Read 127.0.0.1"), a conversation with no one named as work ("Worked on Texts").
    public static let filler = DayReviewOptions(rawValue: 1 << 2)
    /// One texting line for every personal conversation (Messages, WhatsApp, Telegram, Signal, Discord, Instagram):
    /// names only, never a phone number, "and others" past three.
    public static let texting = DayReviewOptions(rawValue: 1 << 3)
    /// With `texting`: the line keeps one quote of the person's own words (owner decision; off by default).
    public static let textingQuote = DayReviewOptions(rawValue: 1 << 4)
    /// "Left off at …": the last piece of work of the day, the unfinished thing to pick up.
    public static let leftOff = DayReviewOptions(rawValue: 1 << 5)
    /// Work sites beyond a fixed list: coursework, documents and business apps read by their host and title words.
    public static let workSites = DayReviewOptions(rawValue: 1 << 6)
    /// Lines, not threads, fill the card: at most `DayReview.lineBudget` lines, a thread past the fourth taking one.
    public static let lineBudget = DayReviewOptions(rawValue: 1 << 7)
    /// The clause writer reads a fact packet code built from the records (`MemoryStore.reviewPacket`), not moment notes,
    /// with its own instruction (`DayReviewClauses.packetInstruction`) and checks; it may answer "" (code's own line).
    public static let factPacket = DayReviewOptions(rawValue: 1 << 8)
    /// With `factPacket`: the writer on this Mac (never a cloud writer) also reads the thread's typed AI prompts and
    /// document words (owner: the local summarizer may read typed words), checked as the titles are, never copied.
    public static let typedFacts = DayReviewOptions(rawValue: 1 << 9)
    public static let recommended: DayReviewOptions = [.projects, .outcomes, .filler, .texting, .workSites, .lineBudget, .factPacket, .typedFacts]
    public static let all: DayReviewOptions = recommended.union(.leftOff)
}

public enum DayReview {
    public static let version = "day-review1"
    /// The changes the card uses (claude/dayeval-1005). Read on every build and assembly; set only by the eval tools.
    nonisolated(unsafe) public static var options: DayReviewOptions = .recommended
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
    /// claude/dayeval-1005: filler (`DayReviewOptions.filler`): shown only with its clause, else passed over.
    public var filler: Bool? = nil
    public init(id: String, lead: String, plainLead: String? = nil, colon: Bool = false, link: DayReviewLink? = nil, tail: String? = nil,
                clauseKey: String? = nil, quote: String? = nil, quoteAlways: Bool = false, inlineQuote: String? = nil, score: Double, moments: [String],
                clauseQuote: String? = nil, quoteWithClause: String? = nil, needsQuote: Bool = false, filler: Bool? = nil) {
        self.id = id; self.lead = lead; self.plainLead = plainLead; self.colon = colon; self.link = link; self.tail = tail
        self.clauseKey = clauseKey; self.quote = quote; self.quoteAlways = quoteAlways; self.inlineQuote = inlineQuote
        self.score = score; self.moments = moments
        self.clauseQuote = clauseQuote; self.quoteWithClause = quoteWithClause; self.needsQuote = needsQuote; self.filler = filler
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
    /// claude/dayeval-1005: for a personal conversation, who it was with as the texting line names them (nil: no one
    /// nameable, a phone number or a list of a group's members); for any thread, when its last moment ended (the left-off line).
    public var person: String? = nil
    public var lastEnd: String? = nil
    /// claude/dayeval-1005: the part of the day ("morning", "afternoon", "evening", "night") that holds most of the
    /// thread's time, when one does (60% or more); nil otherwise (`DayReview.timeLine`).
    public var dayPart: String? = nil
    public init(key: String, name: String, kind: String, seconds: Int, words: Int, personSends: Int, asks: Int, sendHours: Int,
                stakes: [DayReview.Stake], score: Double, items: [DayReviewItem], moments: [String], category: String? = nil,
                person: String? = nil, lastEnd: String? = nil, dayPart: String? = nil) {
        self.key = key; self.name = name; self.kind = kind; self.seconds = seconds; self.words = words; self.personSends = personSends
        self.asks = asks; self.sendHours = sendHours; self.stakes = stakes; self.score = score; self.items = items; self.moments = moments
        self.category = category; self.person = person; self.lastEnd = lastEnd; self.dayPart = dayPart
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
    /// claude/dayeval-1005: "Left off at …", the day's last piece of work (`DayReviewOptions.leftOff`), and its thread.
    public var leftOff: DayReviewItem? = nil
    public var leftOffThread: String? = nil
    enum CodingKeys: String, CodingKey { case day, threads, clauses, activeSeconds, personSends, leftOff, leftOffThread }
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
    /// Owner 10/6: an AI ask with its words reads as a search does ("Searched “red boots”."): "Asked Claude “…”.", no
    /// colon, the words plain (not italic), a period after the quote. Only code's own ask lines lead with "Asked "
    /// (`DayReviewStore`: a send detected into an AI app or tool).
    public var asksQuote: Bool { quote != nil && link == nil && lead.hasPrefix("Asked ") }
    /// What goes between the lead (and its link and rest) and the quote: a space after a lead that ends with its colon or
    /// before an ask's words, else ": ".
    public var quoteSeparator: String { asksQuote || (link == nil && rest == nil) ? " " : ": " }
    private func line(quote: String?) -> String {
        var s = lead
        if let link { s += " " + link.title }
        if let rest { s += " " + rest }
        if let quote { s += quoteSeparator + "\u{201C}" + quote + "\u{201D}" + (asksQuote ? "." : "") }
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
    /// claude/dayeval-1005: the most lines a card shows with `DayReviewOptions.lineBudget`, and the score under which a
    /// thread is filler (about two minutes and nothing sent).
    public static let lineBudget = 6
    /// claude/dayeval-1005: typed rows a clause may read (the latest), and the characters kept of each.
    public static let typedFactRows = 3
    public static let typedFactChars = 160
    public static let fillerScore = 2.0
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
    public static func category(kind: String, key: String, channel: String?, name: String = "", options: DayReviewOptions = DayReview.options) -> Category {
        switch kind {
        case "project", "ai", "code", "doc", "meeting", "pr", "email", "slack": return .work
        case "person", "texts", "chat":
            let c = channel ?? kind
            return ["email", "slack", "teams"].contains(c) || key.hasPrefix("chat:teams") ? .work : .personal
        case "social", "video": return .browsing
        case "web", "search", "site", "page":
            var host = "", page = ""
            // claude/dayeval-1005: a planner topic thread ("topic:page:host|…") is read by its page key.
            let k = options.contains(.workSites) && key.hasPrefix("topic:") ? String(key.dropFirst(6)) : key
            // claude/dayeval-1005: a topic led by an email, a document, a project or a meeting is work ("topic:email:renewal pricing").
            if options.contains(.workSites), key.hasPrefix("topic:"), ["email", "doc:", "project:", "pr:", "meeting:", "code:"].contains(where: { k.hasPrefix($0) }) { return .work }
            for p in ["site:", "page:", "video:", "social:", "web:", "search:"] where k.hasPrefix(p) {
                let parts = k.dropFirst(p.count).split(separator: "|", maxSplits: 1)
                host = String(parts.first ?? "").lowercased(); page = parts.count > 1 ? String(parts[1]) : ""
            }
            if host.hasPrefix("www.") { host.removeFirst(4) }
            func matches(_ set: Set<String>) -> Bool { set.contains { host == $0 || host.hasSuffix("." + $0) } }
            if matches(personalHosts) { return .personal }
            if matches(workHosts) { return .work }
            return options.contains(.workSites) && workSite(host: host, title: page) ? .work : .browsing
        case "app": return workApps.contains(name.lowercased()) || (options.contains(.workSites) && moreWorkApps.contains(name.lowercased())) ? .work : .browsing
        default: return .browsing
        }
    }

    // MARK: claude/dayeval-1005 (generalization: the owner's own apps are a few of many)

    /// Host words of coursework, documents and business tools: a host with one of these as a label ("canvas" in
    /// canvas.lakeview.edu, "force" in acme.lightning.force.com), or containing a long one ("pearson" in pearsonlearn.com).
    public static let workHostWords: Set<String> = ["canvas", "instructure", "blackboard", "moodle", "brightspace", "d2l", "schoology", "gradescope",
        "edfinity", "pearson", "mheducation", "mcgraw", "cengage", "wiley", "klett", "quizlet", "khanacademy", "webassign", "chegg", "coursera",
        "edx", "udemy", "overleaf", "wolframalpha", "desmos", "salesforce", "force", "hubspot", "zendesk", "atlassian", "jira", "confluence",
        "asana", "trello", "monday", "clickup", "miro", "canva", "airtable", "dropbox", "box", "sharepoint", "onedrive", "webflow", "vercel",
        "netlify", "loom", "calendly", "docusign", "quickbooks", "xero", "stripe", "shopify", "workday", "greenhouse", "lever", "intercom",
        "freshdesk", "gusto", "rippling", "replit", "codepen", "figma", "linear", "notion", "slack", "zoom", "webex", "smartsheet", "basecamp",
        "pipedrive", "zoho", "servicenow", "tableau", "looker", "mixpanel", "amplitude", "grammarly", "scribd", "jstor", "arxiv", "pubmed"]
    /// Words in a page's title that mean it is work or school ("Homework 3", "Quiz review", "Q3 invoice").
    public static let workTitleWords: Set<String> = ["assessment", "assignment", "assignments", "homework", "quiz", "exam", "midterm", "syllabus",
        "lecture", "course", "courses", "module", "grades", "gradebook", "submission", "application", "invoice", "proposal", "contract",
        "dashboard", "spreadsheet", "pipeline", "ticket", "tickets", "sprint", "roadmap", "standup", "agenda", "minutes", "report", "draft",
        "manuscript", "chapter", "thesis", "essay", "resume", "portfolio", "timesheet", "expense", "expenses", "budget", "forecast", "deal", "deals",
        "opportunity", "leads", "campaign", "inbox", "calendar", "docs", "sheet", "slides", "deck"]
    /// claude/dayeval-1005 (owner 10/04: "plain words"): a title that would read as words of the sentence ("Read How
    /// tide pools form") is quoted as a title ("Read “How tide pools form”"); any other title stays as it is.
    public static func titleAsObject(_ title: String) -> String {
        let first = title.split(separator: " ").first.map { $0.lowercased() } ?? ""
        let starts: Set<String> = ["about", "how", "why", "what", "when", "where", "who", "your", "yourself", "my", "our", "the", "a", "an", "to", "for",
                                   "with", "untitled", "new", "getting", "welcome", "is", "are", "do", "does", "can", "should", "this", "that", "on", "in"]
        guard starts.contains(first), !title.hasPrefix("\u{201C}") else { return title }
        return "\u{201C}" + title + "\u{201D}"
    }
    /// A topic after "about": an ordinary first word in lower case ("about testing Tallybird sync", never "about Testing …");
    /// a name, an acronym or a word with capitals inside stays.
    public static func lowerLead(_ topic: String) -> String {
        guard let first = topic.split(separator: " ").first, first.count > 1, first.first!.isUppercase,
              first.dropFirst().allSatisfy({ $0.isLowercase }) else { return topic }
        let w = first.lowercased()
        let common: Set<String> = ["market", "notes", "ideas", "questions", "research", "help", "setup", "review", "comparison", "meeting", "design",
                                   "plan", "plans", "planning", "draft", "update", "updates", "bug", "bugs", "fix", "fixes", "data", "app", "website",
                                   "project", "report", "summary", "analysis", "options", "pricing", "launch", "release", "feedback", "career", "job",
                                   "resume", "interview", "travel", "budget", "health", "workout", "recipe", "recipes", "homework", "essay", "code",
                                   "new", "best", "how", "what", "why", "when", "where", "which", "general", "quick", "simple", "daily", "weekly"]
        guard w.hasSuffix("ing") || common.contains(w) else { return topic }
        return w + topic.dropFirst(first.count)
    }
    /// Thread kinds that are a conversation (the texting line's).
    public static let conversationKinds: Set<String> = ["texts", "chat", "person"]
    /// Work apps that open files to read them: time in them is reading, not work on the file.
    public static let readerApps: Set<String> = ["adobe acrobat", "preview", "anki", "calendar", "fantastical", "zoom", "microsoft teams", "teams"]
    /// Apps on their own that are work, past `workApps`.
    public static let moreWorkApps: Set<String> = ["visual studio code", "code", "cursor", "zed", "sublime text", "intellij idea", "pycharm",
        "webstorm", "android studio", "microsoft outlook", "outlook", "microsoft onenote", "onenote", "slack", "discord", "sketch", "affinity designer",
        "adobe photoshop", "adobe illustrator", "adobe indesign", "adobe premiere pro", "adobe after effects", "adobe acrobat", "final cut pro",
        "logic pro", "davinci resolve", "blender", "things", "todoist", "omnifocus", "craft", "bear", "ulysses", "scrivener", "ia writer",
        "microsoft excel", "google docs", "salesforce", "hubspot", "tableau", "rstudio", "jupyterlab", "anki", "goodnotes", "notability"]
    static func workSite(host: String, title: String) -> Bool {
        guard !host.isEmpty else { return false }
        if host.hasSuffix(".edu") || host.contains(".edu.") || host.hasSuffix(".ac.uk") { return true }
        let labels = host.split(separator: ".").map(String.init)
        if labels.contains(where: { l in workHostWords.contains(l) || workHostWords.contains { $0.count >= 5 && l.contains($0) } }) { return true }
        let words = Set(ThreadEntities.tokens(title))
        return !words.isDisjoint(with: workTitleWords)
    }

    /// Apps whose windows are a tool, not a document or a piece of work: a remote screen, a camera, a player, a
    /// utility. Their lines say "Used …" (filler).
    public static let toolApps: Set<String> = ["screen sharing", "microsoft remote desktop", "windows app", "teamviewer", "anydesk", "parsec",
        "jump desktop", "vnc viewer", "royal tsx", "photo booth", "quicktime player", "activity monitor", "adobe crash reporter", "dictionary",
        "calculator", "system settings", "system preferences", "finder", "spotlight", "archive utility", "installer", "software update", "clock",
        "weather", "console", "keychain access", "disk utility", "font book", "image capture", "screenshot", "problem reporter", "crash reporter",
        "1password", "bitwarden", "raycast", "alfred", "cleanmymac", "the unarchiver", "vlc", "iina", "music", "spotify", "podcasts", "tv", "photos"]

    /// A conversation's name as the texting line says it: a person or a named group; nil for a phone number, an email
    /// address, a list of a group's members ("Ana, Ben & Cy") or anything with no letters.
    public static func textingName(_ raw: String) -> String? {
        let name = raw.unicodeScalars.filter { !$0.properties.isEmojiPresentation && !($0.properties.isEmoji && $0.value > 0x2000) && $0.value != 0xFE0F && $0.value != 0x200D }
            .map(String.init).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.contains(where: \.isLetter), !name.contains("@"), name.filter(\.isNumber).count < 5,
              !name.contains(" & "), name.components(separatedBy: ",").count < 3, name.count <= 40 else { return nil }
        return name
    }

    /// claude/dayeval-1005: one texting line for every personal conversation: "Texted Ana Ruiz, Ben and Cy Tran", past
    /// three names "…and others", no one nameable "Texted people", only read "Read texts from Ana Ruiz". Never a number.
    /// claude/dayeval-1005 (10/04 held-out round): the day's main app by time, an AI app with nothing asked, is no filler
    /// when nothing else says it: one line with when ("Spent the afternoon in ChatGPT.", "Spent time in ChatGPT in the
    /// morning."), never "Used ChatGPT.". Only that app, only from 15 minutes, only when most of it was in one part of the
    /// day, only when no line of its own shows.
    public static let timeLineSeconds = 900
    public static func timeLine(_ facts: DayReviewFacts, options: DayReviewOptions) -> (key: String, bullet: DayReviewBullet)? {
        guard options.contains(.filler), let top = facts.threads.max(by: { ($0.seconds, $1.key) < ($1.seconds, $0.key) }),
              top.kind == "ai", top.asks == 0, top.seconds >= timeLineSeconds, let part = top.dayPart else { return nil }
        let lead = top.seconds >= 5400 ? "Spent the \(part) in \(top.name)" : "Spent time in \(top.name) " + (part == "night" ? "at night" : "in the \(part)")
        let moments = top.items.flatMap(\.moments).reduce(into: top.moments) { if !$0.contains($1) { $0.append($1) } }
        return (top.key, DayReviewBullet(id: top.key + "#time", thread: top.key, lead: lead, link: nil, rest: nil, quote: nil, moments: moments))
    }
    /// How long a conversation is read before the texting line names it, when nothing was sent that day.
    public static let textingReadSeconds = 30
    public static func textingBullet(_ threads: [DayReviewThread], words: [String: String], options: DayReviewOptions) -> DayReviewBullet? {
        guard !threads.isEmpty else { return nil }
        let sent = threads.filter { $0.personSends > 0 }
        let pool = (sent.isEmpty ? threads : sent).sorted { ($0.score, $1.key) > ($1.score, $0.key) }
        var names = [String]()
        // A person's thread is named by its person (the thread's own name when no texting name was kept). With nothing sent,
        // only a conversation read for a while is named: one passed on the way to another is "others" (10/04 held-out round).
        func who(_ t: DayReviewThread) -> String? {
            guard !sent.isEmpty || t.seconds >= textingReadSeconds else { return nil }
            return t.person ?? (t.kind == "person" ? t.name : nil)
        }
        for t in pool { if let n = who(t), !names.contains(n) { names.append(n) } }
        let others = pool.contains { who($0) == nil } || names.count > 3
        let shown = Array(names.prefix(3))
        let list: String? = shown.isEmpty ? nil : others ? shown.joined(separator: ", ") + " and others"
            : shown.count == 1 ? shown[0] : shown.dropLast().joined(separator: ", ") + " and " + shown.last!
        let lead: String
        if sent.isEmpty {
            // Never dropped: a conversation with no one named is still "Read texts".
            lead = list.map { "Read texts from " + $0 } ?? "Read texts"
        } else {
            lead = list.map { "Texted " + $0 } ?? "Texted people"
        }
        var quote: String? = nil
        if options.contains(.textingQuote), !sent.isEmpty {
            for t in pool { if let q = t.items.compactMap({ $0.quote ?? $0.clauseQuote }).first, let w = words[q], !w.isEmpty { quote = w; break } }
        }
        let moments = threads.flatMap { $0.moments + $0.items.flatMap(\.moments) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return DayReviewBullet(id: "texting", thread: "texting", lead: lead + (quote != nil ? ":" : ""), link: nil, rest: nil, quote: quote, moments: moments)
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
    public static let askPlaces = ["Claude", "Claude Code", "ChatGPT", "OpenAI", "Anthropic", "Codex", "Cursor", "Gemini", "Perplexity", "Copilot", "Le Chat", "Mistral", "Poe", "Grok", "DeepSeek",
                                   "AI", "Google Chrome", "Chrome", "Safari", "Arc", "Firefox", "Terminal", "Ghostty", "Code"]
    /// Words that name no topic on their own (a new chat's title, an email with no subject).
    static let blankTopicWords: Set<String> = ["new", "untitled", "chat", "chats", "conversation", "conversations", "tab", "window", "home",
                                               "no", "subject", "re", "fwd", "the", "a", "an", "of", "and"]
    /// The topic of a code line's "about …" ("Asked Claude about DayDream", "Emailed Sam about Q3 numbers"), trimmed; nil
    /// when it would only say again who or where (`echoing`: the tool, the app, the person, compared by their words, case
    /// and spacing aside: "Asked Claude about Claude", "Asked ChatGPT about ChatGPT") or says nothing (empty, punctuation,
    /// "New chat", "(no subject)"). The line then goes on without its "about …": "Asked Claude “…”.".
    public static func topic(_ raw: String?, echoing names: [String]) -> String? {
        guard var t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        // claude/dayeval-1005: "Chat with Claude about login issues" is "login issues" ("Asked Claude about Chat with Claude…").
        if options.contains(.projects), let r = t.range(of: #"^(?i)(a |the )?(chat|conversation|discussion|session) with [\w.]+( [\w.]+)? (about|on|regarding) "#,
                                                         options: .regularExpression) { t = String(t[r.upperBound...]) }
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
    public static func assemble(_ facts: DayReviewFacts, order: [String]? = nil, itemOrder: [String: [String]] = [:], quotes: [String: String]? = nil,
                                options: DayReviewOptions = DayReview.options) -> [DayReviewGroup] {
        let words = quotes ?? facts.quotes
        let byKey = Dictionary(facts.threads.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var keys = (order ?? DayReviewStanding.raw(rankScores(facts))).filter { byKey[$0] != nil }
        let capped = hasOtherThings(facts)
        var personal = [String]()
        // claude/dayeval-1005: with one texting line, every conversation goes into it, wherever it ranks.
        let texting = options.contains(.texting)
        // A personal site only read (a feed) is no conversation: it never makes the line say "and others".
        let merged = texting ? keys.filter { k in byKey[k].map { $0.rankCategory == .personal && (conversationKinds.contains($0.kind) || $0.personSends > 0) } ?? false } : []
        if capped || texting {
            personal = keys.filter { byKey[$0]?.rankCategory == .personal }
            if capped { keys = keys.filter { byKey[$0]?.rankCategory != .personal } }
        }
        let textingLine = texting ? textingBullet(merged.compactMap { byKey[$0] }, words: words, options: options) : nil
        // The left-off line: the day's last piece of work, unless a line already says the same.
        var leftOff: DayReviewBullet? = nil
        if options.contains(.leftOff), let item = facts.leftOff, let t = byKey[facts.leftOffThread ?? ""] {
            leftOff = bullet(item, thread: t, facts: facts, words: [:], options: options)
        }
        // A conversation that can show keeps one place, the last, whatever ranks above it.
        let conversation = texting ? textingLine != nil
            : personal.contains { k in byKey[k]!.items.contains { !$0.needsQuote || ($0.quote.flatMap { words[$0] }.map { !$0.isEmpty } ?? false) } }
        let reserved = (conversation && (capped || texting) ? 1 : 0) + (leftOff != nil ? 1 : 0)
        let room = slots.count - reserved
        var groups = [DayReviewGroup](), seen = Set<String>(), rank = 0
        func put(_ bullets: [DayReviewBullet], id: String) {
            if rank >= 2, let last = groups.last, last.id.hasPrefix("rest") {
                groups[groups.count - 1].bullets += bullets
            } else {
                groups.append(DayReviewGroup(id: rank >= 2 ? "rest" : id, bullets: bullets))
            }
            rank += 1
        }
        let budget = options.contains(.lineBudget)
        var lines = 0
        var placedNames = [(name: String, key: String)]()
        func place(_ t: DayReviewThread, limit: Int) -> Bool {
            if options.contains(.filler), t.score < fillerScore, t.personSends == 0, t.words == 0 { return false }
            // claude/dayeval-1005: "Tallybird" after "Tallybird pricing page review" is the same project: its moments join that line.
            if options.contains(.projects), t.rankCategory != .personal {
                let name = t.name.lowercased()
                if let hit = placedNames.first(where: { $0.name.hasPrefix(name + " ") || name.hasPrefix($0.name + " ") || $0.name == name }),
                   let gi = groups.firstIndex(where: { $0.bullets.contains { $0.thread == hit.key } }),
                   let bi = groups[gi].bullets.firstIndex(where: { $0.thread == hit.key }) {
                    groups[gi].bullets[bi].moments += t.items.flatMap(\.moments).filter { !groups[gi].bullets[bi].moments.contains($0) }
                    return true
                }
            }
            let limit = budget ? min(limit, lineBudget - lines - reserved) : limit
            guard limit > 0 else { return false }
            let ids = itemOrder[t.key] ?? t.items.map(\.id)
            let items = ids.compactMap { id in t.items.first { $0.id == id } } + t.items.filter { !ids.contains($0.id) }
            var bullets = [DayReviewBullet]()
            for item in items {
                guard bullets.count < limit else { break }
                // claude/dayeval-1005: filler shows only with its clause.
                if options.contains(.filler), item.filler == true, item.clauseKey.flatMap({ facts.clauses[$0] }).map({ $0.isEmpty }) ?? true { continue }
                let b = bullet(item, thread: t, facts: facts, words: words, options: options)
                if item.needsQuote && b.quote == nil { continue }
                // claude/dayeval-1005: a second line that only names the thread again ("Worked on DayDream in Ghostty") joins the first.
                if options.contains(.projects), !bullets.isEmpty, b.quote == nil, b.rest.map({ $0.hasPrefix("in ") }) ?? true,
                   b.lead.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":")).hasSuffix(t.name.lowercased()) {
                    bullets[0].moments += b.moments.filter { !bullets[0].moments.contains($0) }
                    continue
                }
                let line = b.text.lowercased()
                // claude/dayeval-1005: a title the recorder held back ("[sensitive title omitted]") is never a line of its own.
                if options.contains(.filler), line.filter(\.isLetter).contains("sensitivetitleomitted") { continue }
                // claude/dayeval-1005: a line that only repeats the start of another says nothing new.
                if options.contains(.filler) {
                    let bare = String(line.dropLast(line.hasSuffix(".") ? 1 : 0))
                    if seen.contains(where: { $0.hasPrefix(bare) || bare.hasPrefix(String($0.dropLast($0.hasSuffix(".") ? 1 : 0))) }) { continue }
                }
                guard seen.insert(line).inserted else { continue }
                bullets.append(b)
            }
            guard !bullets.isEmpty else { return false }
            put(bullets, id: t.key)
            placedNames.append((t.name.lowercased(), t.key))
            lines += bullets.count
            return true
        }
        var textingPlaced = false
        let timeLine = DayReview.timeLine(facts, options: options)
        for key in keys {
            // With a line budget, threads past the fourth take one line each while lines remain.
            guard budget ? lines < lineBudget - reserved : rank < room, let t = byKey[key] else { break }
            let limit = rank < slots.count ? slots[rank] : 1
            if texting, t.rankCategory == .personal {
                // Little else: the texting line takes the best conversation's place.
                if !textingPlaced, let b = textingLine { put([b], id: "texting"); textingPlaced = true; lines += 1 }
                continue
            }
            // claude/dayeval-1005: the main app with nothing asked says when it was used (`timeLine`), once.
            if !place(t, limit: limit), let tl = timeLine, tl.key == t.key, seen.insert(tl.bullet.text.lowercased()).inserted {
                put([tl.bullet], id: t.key); lines += 1
            }
        }
        let more = budget || rank < slots.count
        if let b = leftOff, more, seen.insert(b.text.lowercased()).inserted { put([b], id: "leftoff"); lines += 1 }
        if texting {
            if !textingPlaced, budget || rank < slots.count, let b = textingLine { put([b], id: "texting") }
        } else {
            for key in personal where rank < slots.count {
                if let t = byKey[key], place(t, limit: min(personalBullets, slots[min(rank, slots.count - 1)])) { break }
            }
        }
        // Never an empty card for want of anything but filler: the day's filler then shows.
        if options.contains(.filler), !groups.flatMap(\.bullets).contains(where: { $0.thread != "texting" && !$0.id.hasPrefix("leftoff") }) {
            // claude/dayeval-1005 (owner 10/04): never a bare "Used Claude." / "Used ChatGPT.": an AI app opened with
            // nothing asked says nothing, even on a card with nothing else.
            let ai = Set(facts.threads.filter { $0.kind == "ai" }.map(\.key))
            return assemble(facts, order: order, itemOrder: itemOrder, quotes: quotes, options: options.subtracting(.filler)).compactMap { g in
                var g = g
                g.bullets.removeAll { ai.contains($0.thread) && $0.lead.hasPrefix("Used ") && $0.rest == nil && $0.quote == nil }
                return g.bullets.isEmpty ? nil : g
            }
        }
        return groups
    }

    /// One item as a bullet: its clause when cached (with the lead that goes with it), else the code's own tail; the quote
    /// when there is no clause or the item always shows it, and only when its words were opened.
    public static func bullet(_ item: DayReviewItem, thread: DayReviewThread, facts: DayReviewFacts, words: [String: String],
                              options: DayReviewOptions = DayReview.options) -> DayReviewBullet {
        let clause = item.clauseKey.flatMap { facts.clauses[$0] }.flatMap { $0.isEmpty ? nil : $0 }
        let lead = clause != nil ? item.lead : (item.plainLead ?? item.lead)
        let rest = clause ?? item.tail
        var quote = item.inlineQuote
        var quoteID = item.quote
        if let k = item.quoteWithClause, let alt = item.clauseQuote, facts.clauses[k].map({ !$0.isEmpty }) == true { quoteID = alt }
        if quote == nil, clause == nil || item.quoteAlways, let id = quoteID, let w = words[id], !w.isEmpty { quote = w }
        // A name-ended lead takes a colon before what follows it: "Worked on DayDream: …", "Texted Jamie Lin: “…”".
        // Owner 10/6: never an AI ask's ("Asked Claude “…”.", as "Searched “…”." reads: `DayReviewBullet.asksQuote`).
        var colon = item.link == nil && ((item.colon && rest != nil) || (rest == nil && quote != nil && !lead.hasPrefix("Asked ")))
        // claude/dayeval-1005: "Worked on DayDream in Ghostty", the colon only before a clause.
        if options.contains(.projects), clause == nil, quote == nil, item.tail?.hasPrefix("in ") == true { colon = false }
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
    /// claude/dayeval-1005: typed rows (ids) the writer on this Mac may open for this clause (`MemoryStore.reviewTypedFacts`).
    public var typedIDs: [String]? = nil
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

    // MARK: claude/dayeval-1005: the clause from a fact packet (`DayReviewOptions.factPacket`)

    /// review-clause4: written from facts code read from the records (titles, apps, sites, counts), never from moment
    /// notes; few-shot; may answer "" when the facts name nothing beyond the app.
    public static let packetVersion = "review-clause6-typed2"
    public static let packetInstruction = """
You finish one line of a day review of someone's Mac. The line starts with START, written by code; you write only the rest, a short clause that says what the thread was about.
Write {"clause":"..."}.
FACTS come from the computer: the thread's window and page titles (most time first), its apps and sites, what was typed or sent, counted, and sometimes what the person asked an AI app ("asked:") or wrote in a document ("wrote:").
Rules:
- 2 to 12 words. Use only names and words found in FACTS or START. Never guess a topic.
- Say the most concrete thing the titles name: a document, a page, a feature, a course, a result.
- "asked:" and "wrote:" lines are the person's own words: say in a few words what they were about. Never copy or quote them.
- If START ends with a colon, write a short description or a list. Otherwise go on with START's sentence.
- If the titles only name an app, a site or a person and nothing was asked or written, write {"clause":""}. An empty clause is a good answer.
- Never repeat START's words. No quotes, times, durations, counts, ids, file paths or links.
- Never say sent, submitted, signed, fixed, finished or shipped unless a title says it. Never say draft, unsent or not sent.
- No subject: never "the user", "they", "I" or "he".
Examples:
START: Worked on Tallybird:
FACTS:
- titles: ExportView.swift — Tallybird; Fix CSV export crash · Pull Request #418; Tallybird — Debug navigator
- apps: Xcode, Google Chrome
- typed or sent: nothing
{"clause":"the CSV export crash and its pull request"}
START: Asked Claude
FACTS:
- titles: Tallybird export crash triage
- apps: Claude
- typed or sent: asked an AI app 3 times, typed about 50 words
{"clause":"about the Tallybird export crash"}
START: Asked ChatGPT
FACTS:
- titles: ChatGPT
- apps: ChatGPT
- typed or sent: asked an AI app 2 times, typed about 40 words
- asked: why does my sourdough starter smell like nail polish remover
- asked: how often should I feed it if I keep it in the fridge
{"clause":"about feeding a sourdough starter"}
START: Asked ChatGPT
FACTS:
- titles: ChatGPT
- apps: ChatGPT
- typed or sent: asked an AI app 9 times, typed about 140 words
{"clause":""}
START: Worked on Canvas:
FACTS:
- titles: Homework 4: Series and Sequences; Quiz 3 review; Announcements
- sites: canvas.northlake.edu
- typed or sent: typed about 60 words
{"clause":"Homework 4 on series and the Quiz 3 review"}
START: Wrote
FACTS:
- titles: Q3 Board Memo — Edited; Q3 Board Memo
- apps: Pages
- typed or sent: typed about 400 words
{"clause":"the Q3 board memo"}
Answer with JSON only.
"""
    /// The evidence for a packet request: the thread, the start, then the facts.
    public static func packetEvidence(_ r: DayReviewClauseRequest) -> String {
        var out = "THREAD: " + clean(r.name) + "\nSTART: " + clean(r.lead) + (r.colon ? ":" : "") + "\nFACTS:\n"
        for n in r.notes {
            let line = "- " + clean(n) + "\n"
            if out.count + line.count > evidenceChars { break }
            out += line
        }
        return out
    }
    /// The instruction, evidence, checks and version in use (`DayReview.options`).
    public static var activeVersion: String { DayReview.options.contains(.factPacket) ? packetVersion : version }
    public static var activeInstruction: String { DayReview.options.contains(.factPacket) ? packetInstruction : instruction }
    public static func activeEvidence(_ r: DayReviewClauseRequest) -> String { DayReview.options.contains(.factPacket) ? packetEvidence(r) : evidence(r) }
    public static func activeRepair(_ r: DayReviewClauseRequest, previous: String, problem: String) -> String {
        activeEvidence(r) + "\nYOUR LAST ANSWER: " + clean(String(previous.prefix(300))) + "\nPROBLEM: " + problem + "\nWrite the clause again, or {\"clause\":\"\"}."
    }
    public static func activeValidate(_ raw: String, request r: DayReviewClauseRequest) throws -> String {
        DayReview.options.contains(.factPacket) ? try validatePacket(raw, request: r) : try validate(raw, request: r)
    }
    /// validator3: validate's checks, an empty clause allowed (code's own line then), and more: no send or result verb the
    /// facts don't show, no path or link, no count, nothing but words from the facts and the start (typos aside).
    public static func validatePacket(_ raw: String, request r: DayReviewClauseRequest) throws -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.hasPrefix("{") { text = prefill + text }
        if let close = text.range(of: "}", options: .backwards) { text = String(text[...close.lowerBound]) } else { text += "\"}" }
        if let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let c = object["clause"] as? String, c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        var c = try validate(raw, request: r)
        let lower = " " + c.lowercased() + " "
        // A clause that only says the thread's own name again adds nothing: code's own line.
        let echo = Set(ThreadEntities.tokens(r.name + " " + r.lead))
        if ThreadEntities.tokens(c).filter({ !ThreadEntities.stopWords.contains($0) }).allSatisfy({ echo.contains($0) }) { return "" }
        // "Asked Claude" goes on with what was asked: "about …", "how to …"; anything else is what it was about ("a cover
        // letter …", "refactoring the retry loop") and code says so (the small model rarely writes the "about" itself).
        if !r.colon, r.lead.hasPrefix("Asked "), let first = ThreadEntities.tokens(c).first,
           !["about", "how", "why", "what", "to", "for", "whether", "if", "which", "when", "where", "with", "who"].contains(first) {
            c = "about " + c
        }
        if c.hasPrefix("about ") { c = "about " + DayReview.lowerLead(String(c.dropFirst(6))) }
        else if !r.colon { c = DayReview.lowerLead(c) }
        // "Wrote replacing the chain" is "Wrote about replacing the chain".
        if !r.colon, r.lead == "Wrote", let first = ThreadEntities.tokens(c).first, first.count > 4, first.hasSuffix("ing") { c = "about " + c }
        let facts = r.notes.joined(separator: " ").lowercased()
        // Counts and topics come from the titles (and what was asked or written) only: the "typed or sent" line is counts,
        // never a topic.
        let titles = r.notes.filter { $0.hasPrefix("titles:") || $0.hasPrefix("asked:") || $0.hasPrefix("wrote:") }.joined(separator: " ").lowercased()
        // The person's own words are said again in other words, never copied: five words in a row from them is a copy.
        let typedRuns = r.notes.filter { $0.hasPrefix("asked:") || $0.hasPrefix("wrote:") }.map { ThreadEntities.tokens(String($0.drop { $0 != ":" }.dropFirst())) }
        let said = ThreadEntities.tokens(c)
        if said.count >= 5, typedRuns.contains(where: { run in run.count >= 5 && (0...(said.count - 5)).contains { i in
            let five = Array(said[i..<(i + 5)]); return (0...(run.count - 5)).contains { Array(run[$0..<($0 + 5)]) == five } } }) {
            throw Reject(reason: "Too close to their words: say what it was about in four words or fewer.")
        }
        guard c.range(of: #"\d"#, options: .regularExpression) == nil || ThreadEntities.tokens(c).filter({ $0.contains(where: \.isNumber) }).allSatisfy({ titles.contains($0) })
        else { throw Reject(reason: "No counts.") }
        let titleWords = Set(ThreadEntities.tokens(titles))
        let named = Set(ThreadEntities.tokens(r.name + " " + r.lead))
        guard ThreadEntities.tokens(c).contains(where: { w in w.count >= 3 && !named.contains(w) && !ThreadEntities.stopWords.contains(w) && !clauseGlue.contains(w)
            && (titleWords.contains(w) || titleWords.contains { near(w, $0) }) }) else { return "" }
        // Owner 10/04: "draft" labels are usually wrong (most were sent): a clause never says draft, unsent or not sent.
        guard lower.range(of: #"\b(draft|drafts|drafted|drafting|unsent|not sent|never sent|didn't send|did not send)\b"#, options: .regularExpression) == nil
            || titles.range(of: #"\bdrafts?\b"#, options: .regularExpression) != nil && lower.range(of: #"\b(unsent|not sent|never sent|didn't send|did not send)\b"#, options: .regularExpression) == nil
        else { throw Reject(reason: "Don't say draft or unsent: say what it was about.") }
        for verb in ["sent", "texted", "emailed", "replied", "posted", "submitted", "signed", "fixed", "shipped", "finished", "merged", "paid", "ordered", "booked"]
            where lower.contains(" " + verb + " ") && !facts.contains(verb) {
            throw Reject(reason: "Don't say \(verb): the facts don't show it.")
        }
        guard c.range(of: #"(https?://|www\.|/|\\|\.(swift|md|txt|json|py|js|ts)\b)"#, options: .regularExpression) == nil else { throw Reject(reason: "No paths or links.") }
        guard c.range(of: #"\b\d{2,}\b"#, options: .regularExpression) == nil || ThreadEntities.tokens(c).filter({ Int($0) != nil }).allSatisfy({ facts.contains($0) })
        else { throw Reject(reason: "No counts.") }
        // Grounding: most content words come from the facts, the start or the thread (an edit away counts: typos).
        let known = Set(ThreadEntities.tokens(r.notes.joined(separator: " ") + " " + r.lead + " " + r.name))
        let content = ThreadEntities.tokens(c).filter { $0.count >= 4 && !ThreadEntities.stopWords.contains($0) && !clauseGlue.contains($0) }
        let unknown = content.filter { w in !known.contains(w) && !known.contains { k in near(w, k) } }
        guard unknown.count * 3 <= max(content.count, 1) else { throw Reject(reason: "Use only words from the facts.") }
        return c
    }
    /// Words a clause may add to the facts' own (joining words and plain verbs of work).
    static let clauseGlue: Set<String> = ["about", "with", "from", "into", "over", "their", "them", "then", "while", "page", "pages", "review",
        "reviewed", "reviewing", "work", "working", "notes", "plan", "plans", "planning", "flow", "list", "fixing", "debugging", "testing", "tests",
        "reading", "writing", "setup", "settings", "changes", "update", "updates", "questions", "question", "help", "issue", "issues",
        "more", "other", "some", "next", "part", "parts", "section", "sections"]
    /// A word without its ending ("making" and "make" are "mak", "ignoring" and "ignore" are "ignor").
    static func stem(_ w: String) -> String {
        var s = w
        for end in ["ing", "ed", "es", "s"] where s.count > end.count + 2 && s.hasSuffix(end) { s.removeLast(end.count); break }
        if s.count > 3, s.hasSuffix("e") { s.removeLast() }
        return s
    }
    /// Two words an edit apart (a typo, a plural), for words of five letters or more; or the same word with another
    /// ending (claude/dayeval-1005: "making" for "make", as a clause says what was asked).
    static func near(_ a: String, _ b: String) -> Bool {
        if a.count >= 4, b.count >= 4, stem(a).count >= 3, stem(a) == stem(b) { return true }
        guard a.count >= 5, b.count >= 5, abs(a.count - b.count) <= 1 else { return a.hasPrefix(b) && b.count >= 5 || b.hasPrefix(a) && a.count >= 5 }
        let x = Array(a), y = Array(b)
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)) }
            prev = cur
        }
        return prev[y.count] <= 1
    }

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
