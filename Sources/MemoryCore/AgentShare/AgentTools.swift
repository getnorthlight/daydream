import Foundation

// agent-tools v2, WP-C (plan §2, §6.1): timeline, search, details and status.
//
// Every tool runs on the store and an `AgentTypedSource` (the app's bridge, or a fixture) and returns the frozen
// `AgentReply` (`call`) or the whole `AgentAnswer` with WP-C's extras (`answer`): the typed excerpts and why a search
// hit matched. `run` is what the MCP server and `mac-mem --local agent-preview` call: parse, answer, render.
//
// Typed words reach a reply only through the typed source, which returns them already through
// `AgentSharePolicy.shareable`; with typed words off, WP-B's items carry no typed actions and nothing typed is said.

/// One tool call's rendered result.
public struct AgentToolOutput: Equatable, Sendable {
    public var text: String
    public var isError: Bool
    /// How many items a search or timeline answer holds (usage counts' `result_count`); nil for other tools and errors.
    public var resultCount: Int?
    public init(text: String, isError: Bool, resultCount: Int? = nil) { self.text = text; self.isError = isError; self.resultCount = resultCount }
}

extension AgentTools {
    public static func call(_ call: AgentToolCall, context: AgentToolContext) throws -> AgentReply {
        try answer(call, context: context).reply
    }

    /// The whole answer, extras included. `access`: this AI app's connection as the server checked it with its key, for
    /// `status` (nil: no AI app, as in the local preview; then nothing is said about a connection).
    public static func answer(_ call: AgentToolCall, context: AgentToolContext, access: AssistantAccess? = nil) throws -> AgentAnswer {
        let policy = AgentSharePolicy.current(bridge: context.typed)
        switch call {
        case .timeline(let args): return try timeline(args, context: context, policy: policy)
        case .search(let args): return try AgentSearch.run(args, context: context, policy: policy)
        case .details(let args): return try details(args, context: context, policy: policy)
        case .status: return try status(context: context, policy: policy, access: access)
        }
    }

    /// Parse, answer and render one tools/call. A bad argument is an error result with the arguments that work.
    public static func run(name: String, arguments: [String: Any], context: AgentToolContext, access: AssistantAccess? = nil) -> AgentToolOutput {
        do {
            let format = try self.format(arguments)
            guard let call = try parse(name: name, arguments: arguments) else {
                return AgentToolOutput(text: "Unknown tool \"\(name.prefix(60))\". DayDream's tools: timeline, search, details, status.", isError: true)
            }
            let answer = try self.answer(call, context: context, access: access)
            let count: Int?
            switch answer.reply.body {
            case .search(let reply): count = reply.items.count
            case .timeline(let reply): count = reply.days.reduce(0) { $0 + $1.items.count }
            default: count = nil
            }
            return AgentToolOutput(text: AgentRender.render(answer, format: format, budget: budget(call)).text, isError: false, resultCount: count)
        } catch {
            return AgentToolOutput(text: errorText(error, tool: name), isError: true)
        }
    }

    /// Whether a call reads today or the last two hours: the server then asks the app to write today's notes first
    /// (`WriterFreshen`), as it does for the legacy tools.
    public static func coversRecent(name: String, arguments: [String: Any], now: Date, timezone: String) -> Bool {
        guard let call = try? parse(name: name, arguments: arguments) else { return false }
        let zone = TimeZone(identifier: timezone) ?? .current
        func reaches(_ when: String?) -> Bool {
            guard let when else { return true }
            guard let period = try? AgentWhen.resolve(when, now: now, zone: zone, maxDays: nil) else { return false }
            return period.end >= now.addingTimeInterval(-2 * 3600)
        }
        switch call {
        case .timeline(let args): return reaches(args.when)
        case .search(let args): return reaches(args.when)
        case .details, .status: return false
        }
    }

    public static func budget(_ call: AgentToolCall) -> Int {
        switch call {
        case .timeline(let args): return args.detail == .full ? AgentBudget.timelineFull : AgentBudget.timelineSummary
        case .search: return AgentBudget.search
        case .details: return AgentBudget.details
        case .status: return AgentBudget.status
        }
    }

    /// `format`: text (default) or json. The legacy `response_format` (concise, detailed) is read the same way.
    public static func format(_ arguments: [String: Any]) throws -> AgentFormat {
        if let value = arguments["format"] {
            guard let text = value as? String, let format = AgentFormat(rawValue: text.lowercased()) else { throw MemError.invalid("format must be \"text\" (the default) or \"json\".") }
            return format
        }
        if let legacy = arguments["response_format"] as? String { return legacy.lowercased() == "detailed" ? .json : .text }
        return .text
    }

    static func errorText(_ error: Error, tool: String) -> String {
        let reason: String
        if case .invalid(let message)? = error as? MemError { reason = message } else { reason = AssistantCatalog.errorMessage(error) }
        let usage: [String: String] = [
            "timeline": "timeline with when (today, yesterday, this morning, this week, last week, a weekday, a date like 2026-10-03, or \"Sep 28 to Oct 2\"), optionally detail=full.",
            "search": "search with query (1-3 words), optionally kinds, person, app, site, when and limit.",
            "details": "details with id exactly as timeline or search gave it (like 1004-k7f2q).",
        ]
        guard case .invalid? = error as? MemError, let hint = usage[tool], !reason.hasPrefix(tool + " "), !reason.contains("hasn't happened yet") else { return reason }
        return reason + "\nUse: " + hint
    }

    // MARK: - Arguments

    public static func parse(name: String, arguments: [String: Any]) throws -> AgentToolCall? {
        guard let tool = AgentToolName(rawValue: name) else { return nil }
        func string(_ key: String) throws -> String? {
            guard let value = arguments[key], !(value is NSNull) else { return nil }
            guard let text = value as? String else { throw MemError.invalid("\(key) must be text.") }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(300))
        }
        switch tool {
        case .timeline:
            let detail = try string("detail").map { value -> AgentDetail in
                switch value.lowercased() {
                case "summary", "brief", "short": return .summary
                case "full", "all", "everything": return .full
                default: throw MemError.invalid("detail must be \"summary\" (the default) or \"full\".")
                }
            } ?? .summary
            return .timeline(AgentTimelineArgs(when: try string("when") ?? "today", detail: detail, cursor: try string("cursor")))
        case .search:
            var query = try string("query") ?? ""
            for key in AgentSearch.filterKeys {
                if let value = try string(key) { query += (query.isEmpty ? "" : " ") + AgentSearch.token(key, value) }
            }
            var kinds = Set<AgentEntityKind>()
            if let raw = arguments["kinds"] ?? arguments["kind"], !(raw is NSNull) {
                let names: [String]
                if let list = raw as? [Any] { names = try list.map { guard let s = $0 as? String else { throw MemError.invalid("kinds must be a list of kind names.") }; return s } }
                else if let text = raw as? String { names = text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init) }
                else { throw MemError.invalid("kinds must be a list of kind names.") }
                for name in names where !name.isEmpty {
                    guard let kind = kindAlias(name) else {
                        throw MemError.invalid("Unknown kind \"\(name.prefix(40))\". Kinds: " + AgentEntityKind.allCases.map(\.rawValue).joined(separator: ", ") + ".")
                    }
                    kinds.insert(kind)
                }
            }
            var when = try string("when")
            // Legacy arguments (chats begun on 0.1.4): start and end become a range.
            if when == nil, let start = try string("start") { when = start + " to " + (try string("end") ?? "now") }
            else if when == nil, let end = try string("end") { when = "all to " + end }
            var limit = 20
            if let raw = arguments["limit"], !(raw is NSNull) {
                if let n = raw as? Int { limit = n } else if let s = raw as? String, let n = Int(s) { limit = n } else if let d = raw as? Double { limit = Int(d) }
                else { throw MemError.invalid("limit must be a number from 1 to 50.") }
                guard (1...50).contains(limit) else { throw MemError.invalid("limit must be a number from 1 to 50.") }
            }
            return .search(AgentSearchArgs(query: query, kinds: kinds, when: when, limit: limit, cursor: try string("cursor")))
        case .details:
            guard let id = try string("id")?.lowercased(), AgentItemID.isValid(id) else {
                throw MemError.invalid("details needs id exactly as timeline or search gave it, like 1004-k7f2q.")
            }
            return .details(AgentDetailsArgs(id: id, cursor: try string("cursor")))
        case .status:
            return .status
        }
    }

    static func kindAlias(_ name: String) -> AgentEntityKind? {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        if let kind = AgentEntityKind(rawValue: key) { return kind }
        switch key {
        case "doc", "docs", "documents", "sheet", "sheets", "slides": return .document
        case "forms", "application", "applications": return .form
        case "people", "persons", "texts", "messages", "contact": return .person
        case "ai", "chat", "chats", "ai_chats", "aichat", "prompt", "prompts", "question", "questions": return .aiChat
        case "search", "searches", "web_searches", "websearch", "query", "queries": return .webSearch
        case "emails", "mail": return .email
        case "terminals", "code", "command", "commands", "shell": return .terminal
        case "pages", "web", "site", "sites", "article", "articles": return .page
        case "feeds", "social": return .feed
        case "apps", "window", "windows": return .app
        default: return nil
        }
    }

    // MARK: - Header

    /// The one header line's model. `range`: the recorded range to show; `pending`: moments waiting for a note.
    static func header(_ context: AgentToolContext, range: (from: Date, to: Date)?, pending: Int?) throws -> AgentHeader {
        let mode = (try? context.store.summaryWriter())??.mode
        let notes: AgentNotesState
        switch mode {
        case "local"?, "cloud"?: notes = (pending ?? 0) > 0 ? .catchingUp(pending ?? 0) : .on
        case "starting"?: notes = .catchingUp(pending ?? 0)
        default: notes = .paused
        }
        return AgentHeader(now: context.now, timezone: context.timezone, recordedFrom: range?.from, recordedTo: range?.to, notes: notes)
    }

    // MARK: - timeline

    /// What a timeline page is made of, in reading order: per day its start (heading and day note), its items, and its
    /// end (the Collapsed line).
    enum Unit { case start(Int), item(Int, AgentItem), end(Int) }

    static func timeline(_ args: AgentTimelineArgs, context: AgentToolContext, policy: AgentSharePolicy) throws -> AgentAnswer {
        let zone = TimeZone(identifier: context.timezone) ?? .current, now = context.now
        // A period that hasn't happened yet ("what do I need to do tomorrow?"): DayDream can't see it, but today's
        // documents and forms are where the person picks up. Said plainly, before them.
        if AgentWhen.isFuture(args.when, now: now, zone: zone) {
            var answer = try timeline(AgentTimelineArgs(when: "today", detail: .summary, cursor: args.cursor), context: context, policy: policy,
                                      groups: [.documents])
            answer.page.lead = "DayDream can't see the future: it records only what already happened on this Mac (for plans, check a calendar). "
                + (answer.reply.isEmptyTimeline ? "Nothing was open today to pick up from." : "Documents and forms from today, to pick up from:")
            answer.leftOff = nil
            return answer
        }
        return try timeline(args, context: context, policy: policy, groups: nil)
    }

    /// An item as it was inside `period`: only its visits there (clamped), its active time in proportion, and only the
    /// typed rows typed then. nil when it wasn't seen in the period. A whole day returns the item as it is.
    static func within(_ item: AgentItem, _ period: AgentPeriod, typedAt: [String: Date]) -> AgentItem? {
        if period.whole(item.day) { return item }
        let visits = item.visits.compactMap { v -> AgentVisit? in
            guard v.end > period.start || (v.end == v.start && v.start >= period.start), v.start < period.end else { return nil }
            return AgentVisit(start: max(v.start, period.start), end: min(v.end, period.end))
        }
        guard let first = visits.first, let last = visits.last else { return nil }
        guard visits != item.visits else { return item }
        var out = item
        let whole = item.visits.reduce(0.0) { $0 + max(0, $1.end.timeIntervalSince($1.start)) }
        let part = visits.reduce(0.0) { $0 + max(0, $1.end.timeIntervalSince($1.start)) }
        out.visits = visits; out.firstAt = first.start; out.lastAt = last.end
        if whole > 0 { out.minutes = (item.minutes * part / whole * 10).rounded() / 10 }
        out.typedIDs = item.typedIDs.filter { id in typedAt[id].map { $0 >= period.start && $0 < period.end } ?? false }
        return out
    }

    static func timeline(_ args: AgentTimelineArgs, context: AgentToolContext, policy: AgentSharePolicy, groups: Set<AgentGroup>?) throws -> AgentAnswer {
        let zone = TimeZone(identifier: context.timezone) ?? .current, now = context.now
        let period = try AgentWhen.resolve(args.when, now: now, zone: zone, maxDays: 7)
        let mark = try context.store.agentMark()
        var days: [(data: AgentDayData, shown: [AgentItem], collapsed: AgentCollapsed, headline: String?)] = []
        var all: [AgentItem] = [], seen: [AgentItem] = [], pending = 0
        for day in period.days {
            let data = try context.store.agentDay(day, timezone: context.timezone, policy: policy, now: now, mark: mark)
            pending += data.pendingNotes
            // Only what was seen in the period, as it was then ("this morning": the morning's visits and last time).
            let clipped = data.items.compactMap { within($0, period, typedAt: data.typedAt) }
            seen += clipped
            let items = clipped.filter { groups?.contains(AgentGroup.of($0.entity)) ?? true }
            guard !items.isEmpty else { continue }
            all += items
            let (shown, collapsed) = select(items, detail: args.detail)
            let headline = period.whole(day) && groups == nil
                ? (try? context.headlines?.dayReviewHeadline(day: day, timezone: context.timezone, typedWords: policy.typedWords)) ?? nil : nil
            days.append((data, shown, collapsed, headline))
        }
        // Reading order: each day's items by group, most important first within a group.
        var units: [Unit] = []
        for (index, day) in days.enumerated() {
            units.append(.start(index))
            for group in AgentGroup.allCases { for item in day.shown where AgentGroup.of(item.entity) == group { units.append(.item(index, item)) } }
            units.append(.end(index))
        }
        let offset = try args.cursor.map { cursor -> Int in
            guard let value = Int(cursor.trimmingCharacters(in: .whitespaces)), value >= 0, value <= units.count else {
                throw MemError.invalid("cursor must be the value from the previous timeline's More line, with the same when and detail.")
            }
            return value
        } ?? 0
        // Typed excerpts: the newest typed line of each item that can be on this page.
        let window = units.dropFirst(offset).prefix(args.detail == .full ? 200 : 120)
        var wanted: [String] = []
        for case .item(let index, let item) in window { wanted += AgentSearch.latestTyped(item, days[index].data, count: 1) }
        // Where you left off: the last thing done in the period (not a feed, not system UI).
        // A bare app window ("Messages", no title) says little: a named item used up to 10 minutes before it wins.
        let leftCandidates = all.filter { item in
            if case .feed = item.entity { return false }
            if case .app(_, _, true) = item.entity { return false }
            return true
        }
        func bare(_ item: AgentItem) -> Bool {
            if case .app(_, let title, _) = item.entity { return title.trimmingCharacters(in: .whitespaces).isEmpty }
            return false
        }
        let newest = leftCandidates.max { ($0.lastAt, $0.id) < ($1.lastAt, $1.id) }
        let left = newest.flatMap { newest -> AgentItem? in
            guard bare(newest) else { return newest }
            return leftCandidates.filter { !bare($0) && $0.lastAt >= newest.lastAt.addingTimeInterval(-600) }
                .max { ($0.lastAt, $0.id) < ($1.lastAt, $1.id) } ?? newest
        }
        let leftData = left.flatMap { item in days.first { $0.data.day == item.day }?.data }
        if let left { wanted += AgentSearch.latestTyped(left, leftData, count: 1) }
        let fetched = policy.typedWords ? AgentSearch.fetchWords(wanted, typed: context.typed) : (words: [String: String](), unavailable: nil)
        let words = fetched.words
        func typedLine(_ item: AgentItem, _ data: AgentDayData?) -> AgentTypedLine? {
            guard let id = AgentSearch.latestTyped(item, data, count: 1).first, let text = words[id] else { return nil }
            return AgentTypedLine(at: data?.typedAt[id] ?? item.lastAt, form: AgentSearch.form(item.entity), text: text)
        }
        var extras = [String: AgentItemExtra]()
        for case .item(let index, let item) in window {
            if let line = typedLine(item, days[index].data) { extras[item.id] = AgentItemExtra(typed: [line]) }
        }
        let leftOff = left.map { AgentLeftOff(item: $0, typed: typedLine($0, leftData), note: $0.noteLines.last) }
        // The recorded part of the period: the visits inside it (an item seen this morning and again tonight counts
        // only its morning visits for "this morning"). Every kind counts, also when only some groups are listed.
        let inside = seen.flatMap(\.visits).filter { $0.end >= period.start && $0.start < period.end }
        let range: (from: Date, to: Date)? = seen.isEmpty ? try context.store.agentHistoryRange(now: now)
            : inside.isEmpty ? (seen.map(\.firstAt).min()!, seen.map(\.lastAt).max()!)
            : (max(inside.map(\.start).min()!, period.start), min(inside.map(\.end).max()!, period.end))
        let header = try self.header(context, range: range, pending: pending)

        func answer(_ count: Int) -> AgentAnswer {
            let slice = units.dropFirst(offset).prefix(count)
            var byDay: [Int: (items: [AgentItem], start: Bool, end: Bool)] = [:]
            var order: [Int] = []
            for unit in slice {
                let index: Int
                switch unit { case .start(let i), .end(let i): index = i; case .item(let i, _): index = i }
                if byDay[index] == nil { byDay[index] = ([], false, false); order.append(index) }
                switch unit {
                case .start: byDay[index]!.start = true
                case .end: byDay[index]!.end = true
                case .item(_, let item): byDay[index]!.items.append(item)
                }
            }
            let pageDays = order.map { index -> AgentTimelineDay in
                let part = byDay[index]!, day = days[index]
                return AgentTimelineDay(day: day.data.day, headline: part.start ? day.headline : nil, items: part.items,
                                        collapsed: part.end ? day.collapsed : AgentCollapsed())
            }
            let restUnits = units.dropFirst(offset + slice.count)
            var remaining = 0, remainingDays: [String] = []
            for unit in restUnits {
                if case .item(let index, _) = unit {
                    remaining += 1
                    if remainingDays.last != days[index].data.day { remainingDays.append(days[index].data.day) }
                }
            }
            let more = restUnits.contains { if case .item = $0 { return true }; return false }
            let cursor = more ? String(offset + slice.count) : nil
            let reply = AgentTimelineReply(detail: args.detail, days: pageDays, cursor: cursor)
            return AgentAnswer(reply: AgentReply(header: header, body: .timeline(reply)), extras: extras, leftOff: more ? nil : leftOff,
                               page: AgentPage(remaining: remaining, remainingDays: remainingDays, period: period.label,
                                               typedNote: fetched.unavailable ?? AgentSearch.typedOffLine(policy, pageDays.flatMap(\.items))))
        }
        // The most units that fit the budget, at least one item.
        let budget = args.detail == .full ? AgentBudget.timelineFull : AgentBudget.timelineSummary
        let available = units.count - offset
        guard available > 0 else { return answer(0) }
        var low = 1, high = available
        if AgentRender.textTokens(answer(high)) <= budget { return answer(high) }
        while low < high {
            let mid = (low + high + 1) / 2
            if AgentRender.textTokens(answer(mid)) <= budget { low = mid } else { high = mid - 1 }
        }
        // Never a page without an item: past a day's start, take its first item too.
        var count = low
        while count < available, !units.dropFirst(offset).prefix(count).contains(where: { if case .item = $0 { return true }; return false }) { count += 1 }
        return answer(count)
    }

    /// summary: up to 12 items (`AgentItems.summary`: forms, documents and people first, then the rest by rank); feeds
    /// are listed as one Reading line; system UI and anything past 12 are counted by kind. full: every item.
    static func select(_ items: [AgentItem], detail: AgentDetail) -> (shown: [AgentItem], collapsed: AgentCollapsed) {
        guard detail == .summary else { return (items, AgentCollapsed()) }
        var feeds: [AgentItem] = [], low: [AgentItem] = [], rest: [AgentItem] = []
        for item in items {
            switch item.entity {
            case .feed: feeds.append(item)
            case .app(_, _, true): low.append(item)
            default: rest.append(item)
            }
        }
        var (listed, collapsed) = AgentItems.summary(rest, limit: 12)
        for item in low { collapsed.total += 1; collapsed.byKind[item.entity.kind, default: 0] += 1 }
        let keep = Set(listed.map(\.id)).union(feeds.map(\.id))
        return (items.filter { keep.contains($0.id) }, collapsed)
    }

    // MARK: - details

    static func details(_ args: AgentDetailsArgs, context: AgentToolContext, policy: AgentSharePolicy) throws -> AgentAnswer {
        let now = context.now
        let mark = try context.store.agentMark()
        let history = try context.store.agentHistoryRange(now: now)
        let notFound = "Not found: no item has this id. It may have been forgotten, or the id may be from an older result; search again for it."
        guard let day = AgentItemID.day(of: args.id, now: now, timezone: context.timezone) else {
            return AgentAnswer(reply: AgentReply(header: try header(context, range: history, pending: nil), body: .message(notFound)))
        }
        let data = try context.store.agentDay(day, timezone: context.timezone, policy: policy, now: now, mark: mark)
        let header = try self.header(context, range: history, pending: data.day == AgentClock.dayKey(now, zone: TimeZone(identifier: context.timezone) ?? .current) ? data.pendingNotes : nil)
        guard let item = data.items.first(where: { $0.id == args.id }) else {
            return AgentAnswer(reply: AgentReply(header: header, body: .message(notFound)))
        }
        // Typed lines in time order, paged.
        let ids = policy.typedWords ? item.typedIDs.sorted { (data.typedAt[$0] ?? .distantPast, $0) < (data.typedAt[$1] ?? .distantPast, $1) } : []
        let offset = try args.cursor.map { cursor -> Int in
            guard let value = Int(cursor.trimmingCharacters(in: .whitespaces)), value >= 0, value <= ids.count else {
                throw MemError.invalid("cursor must be the value from the previous details reply's More line, with the same id.")
            }
            return value
        } ?? 0
        let window = Array(ids.dropFirst(offset).prefix(400))
        let fetched = AgentSearch.fetchWords(window, typed: context.typed)
        let words = fetched.words
        let typedNote = fetched.unavailable ?? AgentSearch.typedOffLine(policy, [item])
        let form = AgentSearch.form(item.entity)
        let lines = window.compactMap { id in words[id].map { AgentTypedLine(at: data.typedAt[id] ?? item.lastAt, form: form, text: $0) } }
        // Around the same time: other items with a visit within 5 minutes of one of this item's visits.
        let related = data.items.filter { other in
            guard other.id != item.id else { return false }
            if case .feed = other.entity { return false }
            if case .app(_, _, true) = other.entity { return false }
            return other.visits.contains { v in item.visits.contains { w in v.start <= w.end.addingTimeInterval(300) && w.start <= v.end.addingTimeInterval(300) } }
        }.prefix(5)
        func answer(_ count: Int) -> AgentAnswer {
            let shown = Array(lines.prefix(count))
            let consumed = count >= lines.count ? window.count : (window.firstIndex(where: { id in id == idFor(shown.last, window, words) }) ?? count) + 1
            let rest = ids.count - offset - consumed
            let reply = AgentDetailsReply(item: item, typedLines: shown, related: Array(related), cursor: rest > 0 ? String(offset + consumed) : nil)
            return AgentAnswer(reply: AgentReply(header: header, body: .details(reply)),
                               page: AgentPage(remaining: max(0, rest), typedTotal: ids.count, typedNote: typedNote))
        }
        var low = 0, high = lines.count
        if AgentRender.textTokens(answer(high)) <= AgentBudget.details { return answer(high) }
        while low < high {
            let mid = (low + high + 1) / 2
            if AgentRender.textTokens(answer(mid)) <= AgentBudget.details { low = mid } else { high = mid - 1 }
        }
        return answer(max(1, low))
    }

    /// The typed id a shown line came from (the window's ids in order, skipping ids without words).
    private static func idFor(_ line: AgentTypedLine?, _ window: [String], _ words: [String: String]) -> String? {
        guard let line else { return nil }
        return window.last { words[$0] == line.text }
    }

    // MARK: - status

    static func status(context: AgentToolContext, policy: AgentSharePolicy, access: AssistantAccess?) throws -> AgentAnswer {
        let store = context.store, now = context.now, zone = TimeZone(identifier: context.timezone) ?? .current
        let state = try store.captureStatus(now: now)["state"] ?? "off"
        let history = try store.agentHistoryRange(now: now)
        var recording = AssistantView.recording(state).short
        if let last = history?.to {
            let minutes = Int(now.timeIntervalSince(last) / 60)
            let ago = minutes < 1 ? "just now" : minutes < 60 ? "\(minutes) min ago" : minutes < 48 * 60 ? "\(minutes / 60) h ago" : "\(minutes / 1440) days ago"
            let day = AgentClock.dayShort(AgentClock.dayKey(last, zone: zone), today: AgentClock.dayKey(now, zone: zone), zone: zone)
            recording += " · last activity " + (day == "Today" || day == "Yesterday" ? day.lowercased() : day) + " at " + AgentClock.clock(last, zone: zone) + " (" + ago + ")"
        } else {
            recording += " · nothing recorded yet"
        }
        let today = AgentClock.dayKey(now, zone: zone)
        let pending = history == nil ? 0 : (try? store.agentDay(today, timezone: context.timezone, policy: policy, now: now, mark: store.agentMark()))?.pendingNotes ?? 0
        let header = try self.header(context, range: history, pending: pending)
        var examples = ["What did I do today?", "Write my standup from yesterday.", "Where did I leave off on <project>?", "When did I last have <document> open?"]
        if policy.typedWords { examples += ["What did I ask Claude about <topic>?", "What did I text <person>?"] }
        if ReleaseFeatures.chromePageHistory { examples.append("What did I search for about <topic>?") }
        examples.append("What was I running in the terminal?")
        // The setup check (`assistantReadiness`, the same one the 0.1.4 status gave): the one line to read first, and what
        // typing and Chrome pages are doing. Metadata only. Its typing line ends with the share line, said once below.
        let readiness = (try? store.assistantReadiness(access: access, now: now, sharePolicy: policy)) ?? [:]
        var typing = readiness["typing"]
        if let line = typing, line.hasSuffix(" " + policy.typedWordsLine) { typing = String(line.dropLast(policy.typedWordsLine.count + 1)) }
        let connection = access.map(AssistantCatalog.connectionLine) ?? "local (no AI app)"
        let reply = AgentStatusReply(recording: recording, connection: connection, shared: policy.statusLines(), notes: header.notes,
                                     recordedFrom: history?.from, recordedTo: history?.to, examples: examples)
        return AgentAnswer(reply: AgentReply(header: header, body: .status(reply)),
                           page: AgentPage(setup: AgentStatusSetup(setup: readiness["setup"], typing: typing, chromePages: readiness["chrome_pages"])))
    }
}

// MARK: - when

/// A period of local time: [start, end), its local days, and how to say it.
struct AgentPeriod: Equatable {
    var start: Date
    var end: Date
    var days: [String]
    var label: String
    var zone: TimeZone
    /// The period's end as asked, before it was cut at now ("today" ends at midnight).
    var askedEnd: Date
    /// The whole local day is inside the period (a day note fits it; nothing is clipped). "today" is whole, "this
    /// morning" and "yesterday afternoon" are not.
    func whole(_ day: String) -> Bool {
        guard let interval = try? DayScope.interval(day: day, timezone: zone.identifier) else { return false }
        return start <= interval.start && askedEnd >= interval.end
    }
}

/// The `when` words timeline and search take: today, yesterday, this morning (afternoon, evening), tonight, last night,
/// this week, last week, past N days, N days ago, a weekday, a date (2026-10-03, 10/03, Oct 3), ISO times, and ranges
/// ("A to B", "from A to B", "between A and B", "A - B"). Search also takes this month, last month and all.
enum AgentWhen {
    static let usage = "when takes today, yesterday, this morning, this week, last week, past 3 days, a weekday, a date like 2026-10-03 or Oct 3, or a range like \"Sep 28 to Oct 2\"."

    /// The period hasn't started yet ("tomorrow", "next week", a later date).
    static func isFuture(_ raw: String?, now: Date, zone: TimeZone) -> Bool {
        guard var text = raw?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".?!"))), !text.isEmpty else { return false }
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        guard let span = try? period(text, now: now, cal: AgentClock.calendar(zone), zone: zone, allowLong: true) else { return false }
        return span.start >= now
    }

    static func resolve(_ raw: String, now: Date, zone: TimeZone, maxDays: Int?) throws -> AgentPeriod {
        var text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".?!")))
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        if text.isEmpty { text = "today" }
        let cal = AgentClock.calendar(zone)
        guard let span = try period(text, now: now, cal: cal, zone: zone, allowLong: true) else {
            throw MemError.invalid("Couldn't read when \"\(raw.prefix(60))\". " + usage)
        }
        var (start, end, label) = span
        let askedEnd = end
        guard start < now else {
            throw MemError.invalid("That period hasn't happened yet: DayDream records only what already happened on this Mac. For what's coming up, check a calendar.")
        }
        end = min(end, now.addingTimeInterval(1))
        var days: [String] = []
        var cursor = cal.startOfDay(for: start)
        let approx = Int((end.timeIntervalSince(cursor) / 86_400).rounded(.up))
        if let maxDays, approx > maxDays + 1 {
            throw MemError.invalid("timeline covers at most \(maxDays) days at a time; ask for a shorter period, or use search with when for one thing over a longer one.")
        }
        while cursor < end, approx <= 400 {
            days.append(AgentClock.dayKey(cursor, zone: zone))
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        if let maxDays, days.count > maxDays {
            throw MemError.invalid("timeline covers at most \(maxDays) days at a time (this is \(days.count)); ask for a shorter period, or use search with when for one thing over a longer one.")
        }
        if label.isEmpty { label = describe(start, end, zone: zone, now: now) }
        return AgentPeriod(start: start, end: end, days: days, label: label, zone: zone, askedEnd: askedEnd)
    }

    static func describe(_ start: Date, _ end: Date, zone: TimeZone, now: Date) -> String {
        let a = AgentClock.dayKey(start, zone: zone), b = AgentClock.dayKey(end.addingTimeInterval(-1), zone: zone)
        let today = AgentClock.dayKey(now, zone: zone)
        if a == b { let short = AgentClock.dayShort(a, today: today, zone: zone); return short == "Today" || short == "Yesterday" ? short.lowercased() : "on " + short }
        return AgentClock.format(start, "MMM d", zone: zone) + " – " + AgentClock.format(end.addingTimeInterval(-1), "MMM d", zone: zone)
    }

    typealias Span = (start: Date, end: Date, label: String)

    static func period(_ text: String, now: Date, cal: Calendar, zone: TimeZone, allowLong: Bool) throws -> Span? {
        // Ranges.
        var parts: [String]?
        if text.hasPrefix("between "), let r = text.range(of: " and ") { parts = [String(text[text.index(text.startIndex, offsetBy: 8)..<r.lowerBound]), String(text[r.upperBound...])] }
        else {
            let body = text.hasPrefix("from ") ? String(text.dropFirst(5)) : text
            for separator in [" to ", " through ", " until ", " till ", "..", " – ", " — ", " - "] where body.contains(separator) {
                let split = body.components(separatedBy: separator)
                if split.count == 2 { parts = split; break }
            }
        }
        if let parts {
            let a = parts[0].trimmingCharacters(in: .whitespaces), b = parts[1].trimmingCharacters(in: .whitespaces)
            let first = a == "all" || a == "the start" ? (start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 0), label: "")
                : try single(a, now: now, cal: cal, zone: zone, allowLong: true)
            let second = b == "now" || b == "today" ? (start: now, end: now.addingTimeInterval(1), label: "") : try single(b, now: now, cal: cal, zone: zone, allowLong: true)
            guard let first, let second, first.start < second.end else { return nil }
            return (first.start, second.end, "")
        }
        return try single(text, now: now, cal: cal, zone: zone, allowLong: allowLong)
    }

    static func single(_ text: String, now: Date, cal: Calendar, zone: TimeZone, allowLong: Bool) throws -> Span? {
        let today = cal.startOfDay(for: now)
        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }
        func whole(_ start: Date, _ label: String = "") -> Span { (start, cal.date(byAdding: .day, value: 1, to: start)!, label) }
        // ISO time (legacy start/end).
        if text.count > 10, text.contains("t"), let at = timestamp(text.uppercased()) ?? ISO8601DateFormatter().date(from: text.uppercased()) {
            return (at, at.addingTimeInterval(1), "")
        }
        switch text {
        case "today", "now", "right now", "so far today", "today so far": return whole(today, "today")
        case "yesterday": return whole(day(-1), "yesterday")
        case "day before yesterday", "the day before yesterday": return whole(day(-2))
        case "tonight", "this evening": return (cal.date(byAdding: .hour, value: 17, to: today)!, day(1), "this evening")
        case "last night": return (cal.date(byAdding: .hour, value: 17, to: day(-1))!, cal.date(byAdding: .hour, value: 5, to: today)!, "last night")
        case "this week", "the week", "my week", "week": return (startOfWeek(now, cal), day(1), "this week")
        case "last week", "previous week":
            let start = cal.date(byAdding: .day, value: -7, to: startOfWeek(now, cal))!
            return (start, startOfWeek(now, cal), "last week")
        case "past week", "the past week", "last 7 days", "past 7 days": return (day(-6), day(1), "the past 7 days")
        case "this month":
            guard allowLong else { return nil }
            let start = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            return (start, day(1), "this month")
        case "last month":
            guard allowLong else { return nil }
            let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            return (cal.date(byAdding: .month, value: -1, to: thisMonth)!, thisMonth, "last month")
        case "all", "any time", "anytime", "ever", "all time", "everything":
            guard allowLong else { return nil }
            return (Date(timeIntervalSince1970: 0), day(1), "")
        case "tomorrow", "next week", "next month", "later", "later today":
            return (now.addingTimeInterval(3600), now.addingTimeInterval(7200), "")
        default: break
        }
        // Parts of a day: "this morning", "yesterday afternoon", "tuesday evening".
        let parts: [(String, Int, Int)] = [("morning", 0, 12), ("afternoon", 12, 17), ("evening", 17, 24), ("night", 18, 24)]
        for (word, from, to) in parts where text.hasSuffix(" " + word) || text == word {
            let head = text == word ? "today" : String(text.dropLast(word.count + 1))
            let base: Date?
            if head == "this" || head == "today" || head == "this " { base = today }
            else { base = try single(head, now: now, cal: cal, zone: zone, allowLong: false).map { cal.startOfDay(for: $0.start) } }
            guard let base else { return nil }
            return (cal.date(byAdding: .hour, value: from, to: base)!, cal.date(byAdding: .hour, value: to, to: base)!, head == "this" || head == "today" ? "this " + word : text)
        }
        // past N days, last N days, N days ago.
        if let n = number(text, #"^(?:past|last|previous) (\d+|a|one|two|three|four|five|six|seven|ten|fourteen|thirty) days?$"#) {
            guard n >= 1, allowLong || n <= 31 else { return nil }
            return (day(-(n - 1)), day(1), n == 1 ? "today" : "the past \(n) days")
        }
        if let n = number(text, #"^(\d+|one|two|three|four|five|six|seven) days? ago$"#) { return whole(day(-n)) }
        if let n = number(text, #"^(?:past|last) (\d+|a|one|two|three) hours?$"#) { return (now.addingTimeInterval(-Double(n) * 3600), now.addingTimeInterval(1), "the past \(n) hour" + (n == 1 ? "" : "s")) }
        // Weekdays: the most recent one (today included); "last tuesday" is the one before this week's.
        var name = text, last = false
        for prefix in ["on ", "this "] where name.hasPrefix(prefix) { name = String(name.dropFirst(prefix.count)) }
        if name.hasPrefix("last ") { last = true; name = String(name.dropFirst(5)) }
        if let weekday = weekdays.first(where: { $0.names.contains(name) })?.number {
            var date = today
            while cal.component(.weekday, from: date) != weekday { date = cal.date(byAdding: .day, value: -1, to: date)! }
            if last, date >= startOfWeek(now, cal) { date = cal.date(byAdding: .day, value: -7, to: date)! }
            return whole(date)
        }
        // Dates.
        if let date = date(text, now: now, cal: cal, zone: zone) { return whole(date) }
        return nil
    }

    static let weekdays: [(number: Int, names: [String])] = [
        (1, ["sunday", "sun"]), (2, ["monday", "mon"]), (3, ["tuesday", "tue", "tues"]), (4, ["wednesday", "wed"]),
        (5, ["thursday", "thu", "thur", "thurs"]), (6, ["friday", "fri"]), (7, ["saturday", "sat"]),
    ]
    static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    static func startOfWeek(_ now: Date, _ cal: Calendar) -> Date {
        cal.dateInterval(of: .weekOfYear, for: now)?.start ?? cal.startOfDay(for: now)
    }

    static func number(_ text: String, _ pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let word = String(text[range])
        let words = ["a": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "ten": 10, "fourteen": 14, "thirty": 30]
        return Int(word) ?? words[word]
    }

    /// 2026-10-03, 10/03, 10/3/2026, Oct 3, October 3rd, 3 Oct, Oct 3 2026. A date without a year is the most recent
    /// one not after today.
    static func date(_ text: String, now: Date, cal: Calendar, zone: TimeZone) -> Date? {
        let clean = text.replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: "  ", with: " ")
            .replacingOccurrences(of: #"(\d)(st|nd|rd|th)\b"#, with: "$1", options: .regularExpression)
        var year: Int?, month: Int?, dayNumber: Int?
        let tokens = clean.split(separator: " ").map(String.init)
        if tokens.count == 1, let iso = tokens.first, iso.range(of: #"^\d{4}-\d{1,2}-\d{1,2}$"#, options: .regularExpression) != nil {
            let p = iso.split(separator: "-").compactMap { Int($0) }; year = p[0]; month = p[1]; dayNumber = p[2]
        } else if tokens.count == 1, let slash = tokens.first, slash.range(of: #"^\d{1,2}/\d{1,2}(/\d{2,4})?$"#, options: .regularExpression) != nil {
            let p = slash.split(separator: "/").compactMap { Int($0) }; month = p[0]; dayNumber = p[1]
            if p.count == 3 { year = p[2] < 100 ? 2000 + p[2] : p[2] }
        } else if (2...3).contains(tokens.count) {
            for token in tokens {
                if let m = months.firstIndex(where: { token.hasPrefix($0) && token.count <= 9 }) { month = m + 1 }
                else if let n = Int(token) { if n > 31 { year = n } else { dayNumber = n } }
                else { return nil }
            }
        }
        guard let month, let dayNumber, (1...12).contains(month), (1...31).contains(dayNumber) else { return nil }
        let thisYear = cal.component(.year, from: now)
        for y in year.map({ [$0] }) ?? [thisYear, thisYear - 1] {
            var c = DateComponents(); c.year = y; c.month = month; c.day = dayNumber
            guard let date = cal.date(from: c), cal.component(.day, from: date) == dayNumber else { continue }
            if year != nil || date <= now { return date }
        }
        return nil
    }
}

// MARK: - Legacy tools: no send state

/// agent-tools v2 (owner rule): DayDream never tells an AI app whether a message was sent, delivered or read, or is a
/// draft. The 0.1.4 tools (recap, recall, open, read, context, current-context, moment_details and the legacy search)
/// keep answering for chats begun on 0.1.4, so their bodies pass through here on the way out: a send state field is
/// dropped, a "sent" kind becomes "message", and the old send phrases become plain activity. Everything else is kept.
public enum AgentLegacyFilter {
    static let sendStates: Set<String> = ["sent", "submitted", "draft", "typed", "drafted_request"]

    /// A tool body: JSON (walked field by field) or plain text.
    public static func clean(_ body: String) -> String {
        guard let data = body.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              !(object is String) else { return text(body) }
        let cleaned = value(object, key: nil)
        // Unchanged bodies go out byte for byte.
        if let a = object as? NSObject, let b = cleaned as? NSObject, a.isEqual(b) { return body }
        guard JSONSerialization.isValidJSONObject(cleaned),
              let out = try? JSONSerialization.data(withJSONObject: cleaned, options: [.sortedKeys]) else { return body }
        return String(decoding: out, as: UTF8.self)
    }

    static func value(_ v: Any, key: String?) -> Any {
        switch v {
        case let dict as [String: Any]:
            var out = [String: Any]()
            for (k, item) in dict {
                if k == "state" || k == "actionState", let s = item as? String, sendStates.contains(s) { continue }
                if k == "kind", let s = item as? String, s == "sent" || s == "message.sent" { out[k] = "message"; continue }
                out[k] = value(item, key: k)
            }
            return out
        case let list as [Any]: return list.map { value($0, key: key) }
        case let s as String: return text(s, person: personWords(key))
        default: return v
        }
    }

    /// Fields that hold the person's own words, a title or a name (typed_text, screen text, window and note titles,
    /// the conversation, the site): never rewritten (claude/int-015). DayDream's own wording that sits in such a field
    /// (a note's line or title) was already made plain where it was built (`DisplayWords.undraft`, claude/dayeval-1005),
    /// so nothing here rewrites it a second time.
    static func personWords(_ key: String?) -> Bool {
        guard let key = key?.lowercased() else { return false }
        return key.hasSuffix("text") || key.hasSuffix("title") || key.hasSuffix("words") || key == "query"
            || ["window", "conversation", "subject", "site", "app", "url", "page", "name", "document", "file", "recipient"].contains(key)
    }

    /// The old send phrases (`AssistantView.line`, `TypedLine.withoutWords`, `TypedAccessText.exactTextIs`). The word
    /// "draft" is never DayDream's own wording (owner rule): a note line that starts "Drafted" says "Wrote". Quoted
    /// words (a title, the person's own words, as `DisplayWords.undraft` quotes them) are never rewritten.
    public static func text(_ s: String, person: Bool = false) -> String {
        guard !person, s.range(of: #"(?i)sent|send|draft"#, options: .regularExpression) != nil else { return s }
        // DayDream's own sentences that quote a label ("(draft)" lines were not sent.) go first, whole.
        var s = s
        for (pattern, template) in rewrites where pattern.contains("\"") {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        let ns = s as NSString
        var out = "", last = 0
        func plain(_ part: String) -> String {
            var t = part
            for (pattern, template) in rewrites + noteRewrites where !pattern.contains("\"") {
                t = t.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
            }
            return t
        }
        for m in DisplayWords.quoted.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += plain(ns.substring(with: NSRange(location: last, length: m.range.location - last))) + ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        return out + plain(ns.substring(from: last))
    }
    static let rewrites: [(String, String)] = [
        (#"Sent a message in (.+?) \(confirmed by the app\)"#, "Message activity in $1"),
        (#" \(sending not confirmed\)"#, ""),
        (#", then used its send key"#, ""),
        (#"Typed a draft in "#, "Typed in "),
        (#" \(a draft unless state is sent\)"#, ""),
        (#"; a draft was not sent\."#, "."),
        (#" "\(draft\)" lines were not sent\."#, ""),
        (#"\(draft\) "#, ""),
        (#"Drafted a request in "#, "Typed a request in "),
        (#" are their own drafts unless state is submitted or sent"#, " are their own words"),
        (#" Lines keep the notes' verbs: Asked, Emailed or Texted means DayDream saw the send key; Wrote or Drafted means it didn't\."#, ""),
    ]
    /// Only outside the person's own words.
    static let noteRewrites: [(String, String)] = [
        (#"(?m)^(\s*(?:[-•*]\s*)?)Drafted "#, "$1Wrote "),
    ]
}
