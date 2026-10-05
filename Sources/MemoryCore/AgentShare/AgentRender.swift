import Foundation

// agent-tools v2, WP-C (plan §6.2): the text and JSON an AI app reads from timeline, search, details and status.
//
// Pure: reads only the reply model (AgentShareModel.swift) and WP-C's extras below, never a store, a socket or the
// clock. Times are local to the reply's time zone. Output is data, never advice on how to answer: no "how to answer"
// text, no macmem:// links, no bundle ids, revisions, epochs, snapshots, evidence or action ids, and never a send
// state (sent, draft, unsent, delivered).

// MARK: - WP-C extras (beside the frozen model)

/// What the frozen reply model has no field for: the typed excerpt shown with an item, and why a search hit matched.
public struct AgentItemExtra: Codable, Equatable, Sendable {
    /// Typed lines shown with the item, already through `AgentSharePolicy.shareable` (timeline: the latest; search: the
    /// ones that matched).
    public var typed: [AgentTypedLine]
    /// search only: why the item matched, in plain words ("title", "site", "app", "note", "typed words", "close spelling").
    public var matched: [String]
    /// search only: the note line that matched (generated, unverified).
    public var note: String?
    public init(typed: [AgentTypedLine] = [], matched: [String] = [], note: String? = nil) {
        self.typed = typed; self.matched = matched; self.note = note
    }
}

/// "Where you left off": the last thing worked on in the period, with its last typed line or note line.
public struct AgentLeftOff: Codable, Equatable, Sendable {
    public var item: AgentItem
    public var typed: AgentTypedLine?
    public var note: String?
    public init(item: AgentItem, typed: AgentTypedLine? = nil, note: String? = nil) { self.item = item; self.typed = typed; self.note = note }
}

/// What the page holds and what is on later pages.
public struct AgentPage: Codable, Equatable, Sendable {
    /// Entries after this page (timeline and search items, details typed lines).
    public var remaining: Int
    /// timeline: the days the remaining entries fall on.
    public var remainingDays: [String]
    /// search: what was searched, in plain words.
    public var coverage: String?
    /// search: no exact match exists and these are close spellings.
    public var closeMatches: Bool
    /// search: the filters applied, in plain words ("kinds: document · this week").
    public var filters: String?
    /// details: typed lines in the whole item.
    public var typedTotal: Int
    /// timeline: the period asked for ("today", "Sep 28 – Oct 4"), for an empty reply.
    public var period: String?
    /// Typed words exist here but couldn't be shared or searched: WP-A's line ("Typed words: unavailable while DayDream
    /// is closed."). Shown so a missing quote or match is never read as "nothing was typed".
    public var typedNote: String?
    /// status: the setup check's lines.
    public var setup: AgentStatusSetup?
    /// search: no item holds every word; these hold some of them.
    public var someWords: Bool = false
    /// timeline: a line read before the items ("DayDream can't see tomorrow …").
    public var lead: String?
    public init(remaining: Int = 0, remainingDays: [String] = [], coverage: String? = nil, closeMatches: Bool = false,
                filters: String? = nil, typedTotal: Int = 0, period: String? = nil, typedNote: String? = nil, setup: AgentStatusSetup? = nil,
                someWords: Bool = false, lead: String? = nil) {
        self.remaining = remaining; self.remainingDays = remainingDays; self.coverage = coverage; self.closeMatches = closeMatches
        self.filters = filters; self.typedTotal = typedTotal; self.period = period; self.typedNote = typedNote; self.setup = setup
        self.someWords = someWords; self.lead = lead
    }
}

/// status: the setup check (`MemoryStore.assistantReadiness`) in plain words. `setup` is the line to read first ("Ready:
/// …", "Not ready: …" with the fix, or what is switched off); `typing` and `chromePages` say what is recorded.
public struct AgentStatusSetup: Codable, Equatable, Sendable {
    public var setup: String?
    public var typing: String?
    public var chromePages: String?
    public init(setup: String? = nil, typing: String? = nil, chromePages: String? = nil) {
        self.setup = setup; self.typing = typing; self.chromePages = chromePages
    }
}

extension AgentReply {
    /// A timeline with no item and nothing collapsed.
    var isEmptyTimeline: Bool {
        guard case .timeline(let t) = body else { return false }
        return t.days.allSatisfy { $0.items.isEmpty && $0.collapsed.total == 0 }
    }
}

/// One tool's whole answer: the frozen reply plus WP-C's extras. `AgentTools.call` returns `reply` alone.
public struct AgentAnswer: Codable, Equatable, Sendable {
    public var reply: AgentReply
    /// By item id.
    public var extras: [String: AgentItemExtra]
    public var leftOff: AgentLeftOff?
    public var page: AgentPage
    public init(reply: AgentReply, extras: [String: AgentItemExtra] = [:], leftOff: AgentLeftOff? = nil, page: AgentPage = AgentPage()) {
        self.reply = reply; self.extras = extras; self.leftOff = leftOff; self.page = page
    }
}

// MARK: - Render

extension AgentRender {
    public static func render(_ input: AgentRenderInput) -> AgentRendered {
        render(AgentAnswer(reply: input.reply), format: input.format, budget: input.budget)
    }

    /// Text is cut to `budget` tokens (UTF-8 bytes / 4) only as a last resort, and then says so: the tools page their
    /// replies to fit first. JSON is never cut (it is the same page as the text).
    public static func render(_ answer: AgentAnswer, format: AgentFormat, budget: Int) -> AgentRendered {
        switch format {
        case .json: return AgentRendered(text: AgentJSON.text(answer), omitted: 0)
        case .text: return fit(lines: AgentTextLines.lines(answer), budget: budget)
        }
    }

    public static func header(_ header: AgentHeader) -> String {
        let zone = TimeZone(identifier: header.timezone) ?? .current
        var parts = ["DayDream", AgentClock.headerNow(header.now, zone: zone), AgentClock.recorded(header.recordedFrom, header.recordedTo, now: header.now, zone: zone)]
        switch header.notes {
        case .on: break
        case .paused: parts.append("notes paused")
        case .catchingUp(let n): parts.append(n > 0 ? "notes catching up (\(n))" : "notes catching up")
        }
        return parts.joined(separator: " · ")
    }

    /// Keeps the first lines that fit; the last line then says how many lines were left out.
    static func fit(lines: [String], budget: Int) -> AgentRendered {
        let limit = max(64, budget) * 4
        var used = 0, kept: [String] = []
        for (index, line) in lines.enumerated() {
            let cost = line.utf8.count + 1
            if used + cost > limit - 120, index > 0 {
                let left = lines.count - index
                kept.append("Cut to fit: \(left) more line\(left == 1 ? "" : "s") not shown. Ask again with a cursor or a narrower when.")
                return AgentRendered(text: kept.joined(separator: "\n"), omitted: left)
            }
            used += cost; kept.append(line)
        }
        return AgentRendered(text: kept.joined(separator: "\n"), omitted: 0)
    }

    /// The text's size in tokens as `fit` counts it (its 120-byte reserve included), before any cut: the tools page with
    /// it, so a page that fits is never cut (a cut would drop its More line and cursor).
    static func textTokens(_ answer: AgentAnswer) -> Int {
        let bytes = AgentTextLines.lines(answer).reduce(0) { $0 + $1.utf8.count + 1 } + 120
        return (bytes + 3) / 4
    }
}

// MARK: - Text

enum AgentTextLines {
    static func lines(_ answer: AgentAnswer) -> [String] {
        let header = answer.reply.header
        let zone = TimeZone(identifier: header.timezone) ?? .current
        var out = [AgentRender.header(header)]
        switch answer.reply.body {
        case .message(let text): out.append(text)
        case .timeline(let t): out += timeline(t, answer: answer, now: header.now, zone: zone)
        case .search(let s): out += search(s, answer: answer, now: header.now, zone: zone)
        case .details(let d): out += details(d, answer: answer, now: header.now, zone: zone)
        case .status(let s): out += status(s, setup: answer.page.setup, now: header.now, zone: zone)
        }
        return out
    }

    // MARK: timeline

    static func timeline(_ t: AgentTimelineReply, answer: AgentAnswer, now: Date, zone: TimeZone) -> [String] {
        var out: [String] = []
        let today = AgentClock.dayKey(now, zone: zone)
        let shown = t.days.filter { !$0.items.isEmpty || $0.collapsed.total > 0 || $0.headline != nil }
        if let lead = answer.page.lead { out.append(lead) }
        if shown.isEmpty, t.cursor == nil, answer.page.lead == nil {
            out.append("Nothing recorded \(answer.page.period ?? "in this period").")
        }
        for day in shown {
            if t.days.count > 1 || day.day != today { out.append(AgentClock.dayHeading(day.day, today: today, zone: zone)) }
            if let headline = day.headline, !headline.isEmpty { out.append("Day note: " + AgentText.clip(headline, 220)) }
            out += groupedLines(day.items) { item in itemLines(item, extra: answer.extras[item.id], zone: zone) }
            if day.collapsed.total > 0 {
                out.append("Collapsed: \(day.collapsed.total) more (\(AgentText.kindCounts(day.collapsed.byKind))) · detail=full lists them")
            }
        }
        if let left = answer.leftOff {
            var line = "Where you left off: \(AgentText.label(left.item.entity)) at \(AgentClock.clock(left.item.lastAt, zone: zone))"
            if left.item.day != today { line += " (\(AgentClock.dayShort(left.item.day, today: today, zone: zone)))" }
            if let typed = left.typed { line += " · " + AgentText.typedLine(typed, zone: zone, time: false, limit: 140) }
            else if let note = left.note { line += " · note: \(AgentText.quote(note, 140))" }
            out.append(line + " · " + left.item.id)
        }
        if let note = answer.page.typedNote { out.append(note) }
        if let cursor = t.cursor {
            let days = answer.page.remainingDays.map { AgentClock.dayShort($0, today: today, zone: zone) }
            out.append("More: \(AgentText.count(answer.page.remaining, "more item"))\(days.isEmpty ? "" : " (" + AgentText.range(days) + ")") · cursor=\"\(cursor)\"")
        }
        return out
    }

    /// One timeline item: `- label · when · active · id`, then its typed line (or its first note line).
    static func itemLines(_ item: AgentItem, extra: AgentItemExtra?, zone: TimeZone) -> [String] {
        var head = "- " + AgentText.label(item.entity) + " · " + AgentClock.when(item, zone: zone)
        if let active = AgentClock.active(item.minutes) { head += " · " + active }
        var out = [head + " · " + item.id]
        if let typed = extra?.typed.last { out.append("  " + AgentText.typedLine(typed, zone: zone, time: false, limit: 160)) }
        else if let note = item.noteLines.first { out.append("  note: " + AgentText.quote(note, 160)) }
        return out
    }

    /// Items under their group headings (Documents, People, Email, Questions, Code, Reading, Apps), each group in the order
    /// given. Feeds read as one line under Reading.
    static func groupedLines(_ items: [AgentItem], line: (AgentItem) -> [String]) -> [String] {
        var out: [String] = []
        for group in AgentGroup.allCases {
            let members = items.filter { AgentGroup.of($0.entity) == group }
            guard !members.isEmpty else { continue }
            out.append(group.rawValue)
            var feeds: [AgentItem] = []
            for item in members {
                if case .feed = item.entity { feeds.append(item) } else { out += line(item) }
            }
            if !feeds.isEmpty {
                // One line for every feed (one item per site): "Read X for 45 min (6 visits), Reddit for 10 min".
                let parts = feeds.map { feed -> String in
                    var part = AgentText.label(feed.entity)
                    if let active = AgentClock.active(feed.minutes) { part += " for " + active }
                    if feed.visitCount > 1 { part += " (" + AgentText.count(feed.visitCount, "visit") + ")" }
                    return part
                }
                out.append("- Read " + parts.joined(separator: ", "))
            }
        }
        return out
    }

    // MARK: search

    static func search(_ s: AgentSearchReply, answer: AgentAnswer, now: Date, zone: TimeZone) -> [String] {
        var out: [String] = []
        let today = AgentClock.dayKey(now, zone: zone)
        let what = s.query.isEmpty ? "" : " " + AgentText.quote(s.query, 80)
        let filters = answer.page.filters.map { " · " + $0 } ?? ""
        if s.total == 0 {
            if let coverage = answer.page.coverage, answer.page.typedNote != nil {
                out.append("No items match\(what)\(filters) in " + coverage + "; typed words weren't searched.")
            } else {
                out.append("No items match\(what)\(filters).")
                if let coverage = answer.page.coverage { out.append("Searched " + coverage + ".") }
            }
        } else {
            let first = s.offset + 1, last = s.offset + s.items.count
            let lead = answer.page.closeMatches ? "No exact matches; \(AgentText.count(s.total, "close match", "close matches")) by spelling for"
                : answer.page.someWords ? "No item holds every word; \(AgentText.count(s.total, "item")) \(s.total == 1 ? "matches" : "match") some of"
                : "\(AgentText.count(s.total, "item")) \(s.total == 1 ? "matches" : "match")"
            let shown = s.items.isEmpty ? "none on this page" : "showing \(first)–\(last)"
            out.append("\(lead)\(what)\(filters) (\(AgentText.count(s.totalVisits, "visit"))) · \(shown)")
        }
        if !s.complete, let reason = s.incompleteReason { out.append("Incomplete: " + reason) }
        if let note = answer.page.typedNote { out.append(note) }
        out += groupedLines(s.items) { item in
            var head = "- " + AgentText.label(item.entity) + " · " + AgentClock.dayShort(item.day, today: today, zone: zone) + ", " + AgentClock.when(item, zone: zone)
            if let active = AgentClock.active(item.minutes) { head += " · " + active }
            var lines = [head + " · " + item.id]
            guard let extra = answer.extras[item.id] else { return lines }
            // A title match is plain from the line itself and a typed-words match from the typed line under it, so only
            // the other reasons (site, app, note, close spelling) get a matched line.
            let why = extra.matched.filter { $0 != "title" && !($0 == "typed words" && !extra.typed.isEmpty) }
            if !why.isEmpty { lines.append("  matched: " + why.joined(separator: ", ")) }
            for typed in extra.typed.prefix(2) { lines.append("  " + AgentText.typedLine(typed, zone: zone, time: false, limit: 160)) }
            if let note = extra.note { lines.append("  note: " + AgentText.quote(note, 160)) }
            return lines
        }
        if let cursor = s.cursor {
            out.append("More: \(AgentText.count(answer.page.remaining, "more item")) · cursor=\"\(cursor)\"")
        }
        return out
    }

    // MARK: details

    static func details(_ d: AgentDetailsReply, answer: AgentAnswer, now: Date, zone: TimeZone) -> [String] {
        let item = d.item, today = AgentClock.dayKey(now, zone: zone)
        var head = AgentText.label(item.entity) + " · " + AgentClock.dayShort(item.day, today: today, zone: zone)
        head += ", " + (item.visitCount <= 1 ? AgentClock.span(item.firstAt, item.lastAt, zone: zone)
                        : "\(item.visitCount) visits, \(AgentClock.span(item.firstAt, item.lastAt, zone: zone))")
        if let active = AgentClock.active(item.minutes) { head += " · " + active + " active" }
        var out = [head + " · " + item.id]
        if item.visitCount > 1 {
            let spans = item.visits.prefix(12).map { AgentClock.span($0.start, $0.end, zone: zone) }
            out.append("Visits: " + spans.joined(separator: ", ") + (item.visitCount > 12 ? ", and \(item.visitCount - 12) more" : ""))
        }
        if !d.typedLines.isEmpty {
            let total = max(answer.page.typedTotal, d.typedLines.count)
            out.append(total > d.typedLines.count ? "Typed, in time order (\(total) lines):" : "Typed, in time order:")
            for line in d.typedLines { out.append("- " + AgentText.typedLine(line, zone: zone, time: true, limit: 1200)) }
        }
        if let note = answer.page.typedNote { out.append(note) }
        if !item.noteLines.isEmpty {
            out.append("Notes (generated, unverified):")
            for note in item.noteLines.prefix(8) { out.append("- " + AgentText.clip(note, 240)) }
        }
        if !d.related.isEmpty {
            out.append("Around the same time:")
            for other in d.related { out.append("- " + AgentText.label(other.entity) + " · " + AgentClock.when(other, zone: zone) + " · " + other.id) }
        }
        if let cursor = d.cursor {
            out.append("More: \(AgentText.count(answer.page.remaining, "more typed line")) · cursor=\"\(cursor)\"")
        }
        return out
    }

    // MARK: status

    static func status(_ s: AgentStatusReply, setup: AgentStatusSetup?, now: Date, zone: TimeZone) -> [String] {
        var out: [String] = []
        if let line = setup?.setup { out.append("Setup: " + line) }
        out += ["Recording: " + s.recording, "Connection: " + s.connection]
        if let line = setup?.typing { out.append("Typing: " + line) }
        if let line = setup?.chromePages { out.append("Chrome pages: " + line) }
        if !s.shared.isEmpty {
            out.append("Shared with AI apps:")
            out += s.shared.map { "- " + $0 }
        }
        switch s.notes {
        case .on: out.append("Notes: on (generated, unverified)")
        case .paused: out.append("Notes: paused (summaries are off; titles and typed text are still recorded)")
        case .catchingUp(let n): out.append("Notes: catching up" + (n > 0 ? " (\(n) moments waiting)" : ""))
        }
        // The recorded range is in the header line already.
        if !s.examples.isEmpty {
            out.append(s.recordedTo == nil ? "Questions DayDream can answer once there is some activity:" : "Questions DayDream can answer now:")
            out += s.examples.map { "- " + $0 }
        }
        return out
    }
}

// MARK: - Groups

/// The order a day reads in: what was made and who was talked to first, then questions, code and reading.
enum AgentGroup: String, CaseIterable {
    case documents = "Documents", people = "People", email = "Email", questions = "Questions", code = "Code", reading = "Reading", apps = "Apps"
    static func of(_ entity: AgentEntity) -> AgentGroup {
        switch entity {
        case .document: return .documents
        case .person: return .people
        case .email: return .email
        case .aiChat, .webSearch: return .questions
        case .terminal(let tool, _, _): return isAITool(tool) ? .questions : .code
        case .page, .feed: return .reading
        case .app: return .apps
        }
    }
    /// An AI coding tool running in a terminal (Claude Code, Codex, Gemini CLI, Aider …): what is typed there is a prompt,
    /// so its items sit with Questions and answer search(kinds: ai_chat).
    static func isAITool(_ tool: String?) -> Bool {
        guard let tool = tool?.trimmingCharacters(in: .whitespaces).lowercased(), !tool.isEmpty else { return false }
        if TitleClean.terminalTools.values.contains(where: { $0.lowercased() == tool }) { return true }
        return ["claude", "codex", "gemini", "aider", "copilot", "cursor", "opencode", "amp", "goose"].contains(where: { tool.hasPrefix($0) })
    }
    /// The item answers this kind filter: an AI tool's terminal also counts as ai_chat.
    static func matches(_ entity: AgentEntity, kinds: Set<AgentEntityKind>) -> Bool {
        if kinds.isEmpty || kinds.contains(entity.kind) { return true }
        if kinds.contains(.aiChat), case .terminal(let tool, _, _) = entity, isAITool(tool) { return true }
        return false
    }
}

// MARK: - Words

enum AgentText {
    /// What an item is, in a few words. Titles are quoted; nothing here is a send state.
    static func label(_ entity: AgentEntity) -> String {
        switch entity {
        case .document(let kind, let name):
            return quote(name, 100) + " (" + kind.place + ")"
        case .webSearch(let engine, let query):
            guard let query, !query.isEmpty else { return "Searched on " + engine }
            return engine + " search " + quote(query, 100)
        case .aiChat(let app, let title):
            guard let title, !title.isEmpty, title != app else { return app }
            return app + ": " + quote(title, 90)
        case .person(let name): return clip(name, 80)
        case .email(let subject):
            guard let subject, !subject.isEmpty else { return "Email (mailbox)" }
            return "Email " + quote(subject, 100)
        case .terminal(let tool, let project, let host):
            var parts = [tool.flatMap { $0.isEmpty ? nil : $0 } ?? "Terminal"]
            if let project, !project.isEmpty { parts.append(clip(project, 60)) }
            if let host, !host.isEmpty { parts.append("on " + host) }
            return parts.joined(separator: " · ")
        case .feed(let site): return site
        case .page(let title, let site):
            guard !title.isEmpty else { return site }
            return quote(title, 100) + (site.isEmpty ? "" : " (" + site + ")")
        case .app(let name, let title, _):
            guard !title.isEmpty, title != name else { return name }
            if name == "Finder" { return "Finder folder " + quote(title, 90) }
            return name + ": " + quote(title, 90)
        }
    }

    /// The place a typed line was typed in, for "Typed in <place>".
    static func place(_ entity: AgentEntity) -> String {
        switch entity {
        case .document(_, let name): return clip(name, 80)
        case .page(let title, let site): return title.isEmpty ? site : clip(title, 80)
        case .app(let name, let title, _): return title.isEmpty || title == name ? name : name + ": " + clip(title, 60)
        case .email(let subject): return subject.map { "an email " + quote($0, 80) } ?? "an email"
        default: return label(entity)
        }
    }

    /// `Texted Maya: '…'`, `Asked Claude: '…'`, `Searched Google: '…'`, `Typed in <doc>: '…'`, `Ran in <project>: '…'`.
    /// The person's own words are in single quotes; titles are in double quotes.
    static func typedLine(_ line: AgentTypedLine, zone: TimeZone, time: Bool, limit: Int) -> String {
        let verb: String
        switch line.form {
        case .texted(let name): verb = "Texted " + clip(name, 60)
        case .asked(let app): verb = "Asked " + app
        case .searched(let engine): verb = "Searched " + engine
        case .typedIn(let place): verb = "Typed in " + clip(place, 80)
        case .ran(let project): verb = "Ran in " + clip(project, 60)
        }
        return (time ? AgentClock.clock(line.at, zone: zone) + " " : "") + verb + ": " + words(line.text, limit)
    }

    /// The person's own words in single quotes on one line, cut at `limit` characters with an ellipsis.
    static func words(_ text: String, _ limit: Int) -> String { "'" + clip(text, limit) + "'" }

    /// Text in double quotes on one line, cut at `limit` characters with an ellipsis.
    static func quote(_ text: String, _ limit: Int) -> String { "\"" + clip(text, limit) + "\"" }

    static func clip(_ text: String, _ limit: Int) -> String {
        var flat = text.replacingOccurrences(of: "\r\n", with: " / ").replacingOccurrences(of: "\n", with: " / ").replacingOccurrences(of: "\r", with: " / ")
            .replacingOccurrences(of: "\t", with: " ")
        while flat.contains("  ") { flat = flat.replacingOccurrences(of: "  ", with: " ") }
        flat = flat.trimmingCharacters(in: .whitespaces)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(max(1, limit - 1))).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) " + (n == 1 ? singular : plural ?? singular + "s")
    }

    static func range(_ labels: [String]) -> String {
        guard let first = labels.first, let last = labels.last else { return "" }
        return first == last ? first : first + " – " + last
    }

    static let kindWords: [AgentEntityKind: (String, String)] = [
        .document: ("document", "documents"), .form: ("form", "forms"), .person: ("person", "people"),
        .aiChat: ("AI chat", "AI chats"), .webSearch: ("web search", "web searches"), .email: ("email", "emails"),
        .terminal: ("terminal session", "terminal sessions"), .page: ("page", "pages"), .feed: ("feed", "feeds"),
        .app: ("app window", "app windows"),
    ]

    /// "3 documents, 30 app windows", in kind order.
    static func kindCounts(_ counts: [AgentEntityKind: Int]) -> String {
        AgentEntityKind.allCases.compactMap { kind -> String? in
            guard let n = counts[kind], n > 0, let words = kindWords[kind] else { return nil }
            return count(n, words.0, words.1)
        }.joined(separator: ", ")
    }
}

// MARK: - Times

enum AgentClock {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var formatters = [String: DateFormatter]()

    static func format(_ date: Date, _ pattern: String, zone: TimeZone) -> String {
        let key = pattern + "|" + zone.identifier
        lock.lock(); defer { lock.unlock() }
        if let f = formatters[key] { return f.string(from: date) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian); f.timeZone = zone
        f.dateFormat = pattern; f.amSymbol = "AM"; f.pmSymbol = "PM"
        if formatters.count > 128 { formatters.removeAll() }
        formatters[key] = f
        return f.string(from: date)
    }

    static func dayKey(_ date: Date, zone: TimeZone) -> String { format(date, "yyyy-MM-dd", zone: zone) }

    static func dayDate(_ day: String, zone: TimeZone) -> Date? {
        (try? DayScope.interval(day: day, timezone: zone.identifier))?.start
    }

    static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone; calendar.firstWeekday = 2
        return calendar
    }

    /// The day before `day` ("yyyy-MM-dd").
    static func dayBefore(_ day: String, zone: TimeZone) -> String? {
        guard let start = dayDate(day, zone: zone), let before = calendar(zone).date(byAdding: .day, value: -1, to: start) else { return nil }
        return dayKey(before, zone: zone)
    }

    /// "Sun Oct 4, 6:12 PM CDT".
    static func headerNow(_ now: Date, zone: TimeZone) -> String {
        format(now, "EEE MMM d, h:mm a", zone: zone) + (zone.abbreviation(for: now).map { " " + $0 } ?? "")
    }

    /// "5:48 PM".
    static func clock(_ date: Date, zone: TimeZone) -> String { format(date, "h:mm a", zone: zone) }

    /// "10:05–11:20 AM", "11:40 AM–1:05 PM", or one time when both are the same minute.
    static func span(_ a: Date, _ b: Date, zone: TimeZone) -> String {
        let start = clock(a, zone: zone), end = clock(b, zone: zone)
        if start == end { return start }
        if start.suffix(2) == end.suffix(2) { return String(start.dropLast(3)) + "–" + end }
        return start + "–" + end
    }

    /// One visit: its span. More: "4 visits, last 5:48 PM".
    static func when(_ item: AgentItem, zone: TimeZone) -> String {
        if case .webSearch = item.entity {
            // A search is made at one time: when (the results page stays open after it, which says nothing).
            return item.visitCount <= 1 ? clock(item.firstAt, zone: zone) : "\(item.visitCount) times, last \(clock(item.visits.last?.start ?? item.lastAt, zone: zone))"
        }
        return item.visitCount <= 1 ? span(item.firstAt, item.lastAt, zone: zone) : "\(item.visitCount) visits, last \(clock(item.lastAt, zone: zone))"
    }

    /// "25 min", "1 h 40 min"; nil under a minute.
    static func active(_ minutes: Double) -> String? {
        guard minutes.isFinite else { return nil }
        let m = Int(minutes.rounded())
        guard m >= 1 else { return nil }
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    /// "Today", "Yesterday", or "Sat Oct 3".
    static func dayShort(_ day: String, today: String, zone: TimeZone) -> String {
        if day == today { return "Today" }
        if day == dayBefore(today, zone: zone) { return "Yesterday" }
        guard let date = dayDate(day, zone: zone) else { return day }
        return format(date, "EEE MMM d", zone: zone)
    }

    /// A day's heading in a multi-day reply: "Today, Sun Oct 4", "Sat Oct 3".
    static func dayHeading(_ day: String, today: String, zone: TimeZone) -> String {
        guard let date = dayDate(day, zone: zone) else { return day }
        let full = format(date, "EEE MMM d", zone: zone)
        let short = dayShort(day, today: today, zone: zone)
        return short == full ? full : short + ", " + full
    }

    /// "recorded 8:40 AM–6:10 PM" (today only), "recorded Sat Oct 3, 9:02 AM–11:40 PM", "recorded Oct 1 – Oct 4".
    static func recorded(_ from: Date?, _ to: Date?, now: Date, zone: TimeZone) -> String {
        guard let from, let to else { return "nothing recorded yet" }
        let a = dayKey(from, zone: zone), b = dayKey(to, zone: zone), today = dayKey(now, zone: zone)
        if a == b {
            return "recorded " + (a == today ? "" : format(from, "EEE MMM d", zone: zone) + ", ") + span(from, to, zone: zone)
        }
        let year = format(now, "yyyy", zone: zone)
        func date(_ d: Date) -> String { format(d, "yyyy", zone: zone) == year ? format(d, "MMM d", zone: zone) : format(d, "MMM d, yyyy", zone: zone) }
        return "recorded " + date(from) + " – " + date(to)
    }
}

// MARK: - JSON

/// The same page as the text, as JSON. Internal fields (action ids, typed ids, scores, word counts) never leave.
enum AgentJSON {
    static func text(_ answer: AgentAnswer) -> String {
        let header = answer.reply.header
        let zone = TimeZone(identifier: header.timezone) ?? .current
        var root: [String: Any] = ["header": AgentRender.header(header)]
        switch answer.reply.body {
        case .message(let text): root["message"] = text
        case .timeline(let t):
            root["tool"] = "timeline"; root["detail"] = t.detail.rawValue
            if let lead = answer.page.lead { root["lead"] = lead }
            root["days"] = t.days.map { day -> [String: Any] in
                var value: [String: Any] = ["day": day.day, "items": day.items.map { item($0, answer.extras[$0.id], zone) }]
                if let headline = day.headline { value["dayNote"] = headline }
                if day.collapsed.total > 0 {
                    value["collapsed"] = ["total": day.collapsed.total,
                                          "byKind": Dictionary(uniqueKeysWithValues: day.collapsed.byKind.map { ($0.key.rawValue, $0.value) })] as [String: Any]
                }
                return value
            }
            if let left = answer.leftOff {
                var value = item(left.item, nil, zone)
                if let typed = left.typed { value["typed"] = [typedLine(typed, zone)] }
                if let note = left.note { value["note"] = note }
                root["whereYouLeftOff"] = value
            }
            if let cursor = t.cursor { root["cursor"] = cursor; root["remaining"] = answer.page.remaining; root["remainingDays"] = answer.page.remainingDays }
        case .search(let s):
            root["tool"] = "search"; root["query"] = s.query; root["total"] = s.total; root["totalVisits"] = s.totalVisits
            root["offset"] = s.offset; root["complete"] = s.complete; root["closeMatches"] = answer.page.closeMatches
            if answer.page.someWords { root["someWords"] = true }
            if let reason = s.incompleteReason { root["incompleteReason"] = reason }
            if let coverage = answer.page.coverage { root["searched"] = coverage }
            if let filters = answer.page.filters { root["filters"] = filters }
            root["items"] = s.items.map { item($0, answer.extras[$0.id], zone) }
            if let cursor = s.cursor { root["cursor"] = cursor; root["remaining"] = answer.page.remaining }
        case .details(let d):
            root["tool"] = "details"
            root["item"] = item(d.item, nil, zone)
            root["typed"] = d.typedLines.map { typedLine($0, zone) }
            root["related"] = d.related.map { item($0, nil, zone) }
            if let cursor = d.cursor { root["cursor"] = cursor; root["remaining"] = answer.page.remaining }
        case .status(let s):
            root["tool"] = "status"
            let notes: String
            switch s.notes { case .on: notes = "on"; case .paused: notes = "paused"; case .catchingUp(let n): notes = "catching up (\(n))" }
            var status: [String: Any] = ["recording": s.recording, "connection": s.connection, "shared": s.shared, "notes": notes,
                                         "history": AgentClock.recorded(s.recordedFrom, s.recordedTo, now: header.now, zone: zone), "examples": s.examples]
            if let line = answer.page.setup?.setup { status["setup"] = line }
            if let line = answer.page.setup?.typing { status["typing"] = line }
            if let line = answer.page.setup?.chromePages { status["chromePages"] = line }
            root["status"] = status
        }
        if let note = answer.page.typedNote { root["typedWords"] = note }
        let data = (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func local(_ date: Date, _ zone: TimeZone) -> String {
        AgentClock.format(date, "yyyy-MM-dd'T'HH:mm:ssxxx", zone: zone)
    }

    static func item(_ item: AgentItem, _ extra: AgentItemExtra?, _ zone: TimeZone) -> [String: Any] {
        var value: [String: Any] = ["id": item.id, "day": item.day, "kind": item.entity.kind.rawValue, "title": AgentText.label(item.entity),
                                    "group": AgentGroup.of(item.entity).rawValue, "first": local(item.firstAt, zone), "last": local(item.lastAt, zone),
                                    "visits": item.visits.map { ["start": local($0.start, zone), "end": local($0.end, zone)] },
                                    "activeMinutes": item.minutes.isFinite ? Int(item.minutes.rounded()) : 0]
        if !item.noteLines.isEmpty { value["notes"] = item.noteLines }
        if let extra {
            if !extra.typed.isEmpty { value["typed"] = extra.typed.map { typedLine($0, zone) } }
            if !extra.matched.isEmpty { value["matched"] = extra.matched }
            if let note = extra.note { value["matchedNote"] = note }
        }
        return value
    }

    static func typedLine(_ line: AgentTypedLine, _ zone: TimeZone) -> [String: Any] {
        var value: [String: Any] = ["at": local(line.at, zone), "text": line.text]
        switch line.form {
        case .texted(let name): value["form"] = "texted"; value["to"] = name
        case .asked(let app): value["form"] = "asked"; value["app"] = app
        case .searched(let engine): value["form"] = "searched"; value["engine"] = engine
        case .typedIn(let place): value["form"] = "typed in"; value["place"] = place
        case .ran(let project): value["form"] = "ran"; value["in"] = project
        }
        return value
    }
}
