import Foundation

// agent-tools v2, WP-C (plan §6.1 search, §6.3): complete search over items, and the one store extension the tools use.
//
// Search returns ITEMS (one thing on one day: plan §5.3), never rows, with the complete count in one call. There is no
// scan budget, no 20-hit cap and no forced partial: the legacy Typesense path marked every text query partial
// (`requiresCanonicalCoverage`, data-audit §3) and its SQLite continuation stopped after 2 s; v2 uses neither.
//
// How a search runs:
// 1. Candidate days. For each query term, the days where it can appear: the hour lexicon of the records' title, app,
//    site, terminal tool and typed-unit recipient (folded text, built once per process, then only new rows), the days
//    of matching notes, and the days of typed-word hits (the app's bridge, through the share policy). A day is a
//    candidate when every term can appear in it.
// 2. Items. Each candidate day is read once (the store's day assembly, then WP-B's items) and kept per process
//    (`AgentDayCache`) while nothing it depends on changed.
// 3. Match. Every term must match the item: its name, a member title, site or app, a note line, or a typed hit in it.
// 4. Close spellings, only when nothing matches exactly: the local index's typo search (when it runs) picks the
//    days, and `MemorySearchQuery.lexicalScore` decides each item.
// Results are ranked by `AgentRank` across days (on how many matching days the same thing was seen counts), then the
// latest first. The cursor is an offset into that list; item ids are recomputed and stable.

// MARK: - A day as the tools read it

/// One local day: WP-B's ranked items plus what search matches them against (titles, sites, apps; never descriptions).
struct AgentDayData {
    let day: String
    let items: [AgentItem]
    let titles: [String: [String]]
    let sites: [String: [String]]
    let apps: [String: [String]]
    /// Typed action id -> its time.
    let typedAt: [String: Date]
    /// Moments of the day still waiting for a note, that ended over 30 minutes before the day was read.
    let pendingNotes: Int
    /// Past the day assembly's safety cap: only the newest actions are in it.
    let partial: Bool
}

/// Days read for the tools, per process (the MCP server lives for a whole AI-app session). An entry is used only while
/// its mark (the read epoch, the policy, the notes, the day's rows, the typed-words switch, the zone) is unchanged, and
/// for at most `maxAge`.
final class AgentDayCache: @unchecked Sendable {
    static let shared = AgentDayCache()
    static let capacity = 120
    static let maxAge: TimeInterval = 30 * 60
    private struct Entry { let mark: String; let built: Date; let data: AgentDayData }
    private let lock = NSLock()
    private var entries = [String: Entry](), order = [String]()
    func get(_ key: String, mark: String, now: Date) -> AgentDayData? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[key], entry.mark == mark, now >= entry.built, now.timeIntervalSince(entry.built) < Self.maxAge else { return nil }
        return entry.data
    }
    func put(_ key: String, mark: String, now: Date, _ data: AgentDayData) {
        lock.lock(); defer { lock.unlock() }
        entries[key] = Entry(mark: mark, built: now, data: data)
        order.removeAll { $0 == key }; order.append(key)
        while order.count > Self.capacity { entries.removeValue(forKey: order.removeFirst()) }
    }
    func removeAll() { lock.lock(); entries = [:]; order = []; lock.unlock() }
}

/// The searchable text of every hour, per history, per process (`MemoryStore.agentLexicon`).
final class AgentLexicon: @unchecked Sendable {
    static let shared = AgentLexicon()
    struct Entry { var epoch: String; var top: Int64; var lines: [String: Set<String>]; var hours: [String: String] }
    private let lock = NSLock()
    private var entries = [String: Entry]()
    func get(_ key: String) -> Entry? { lock.lock(); defer { lock.unlock() }; return entries[key] }
    func put(_ key: String, _ entry: Entry) { lock.lock(); entries[key] = entry; lock.unlock() }
    /// The form both sides are compared in: case, accents and width folded (`AgentSearch.contains`).
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

/// What every day read in one call shares: read once per call.
struct AgentStoreMark {
    let global: String
    let top: Int64
}

// MARK: - The store extension (the only one WP-C adds; read-only)

extension MemoryStore {
    func agentMark() throws -> AgentStoreMark {
        let epoch = try actionReadEpoch()
        let policyBody = try rows("SELECT body FROM metadata WHERE id='policy'").first?.first ?? ""
        let notes = try hasActionLayers() ? (try rows("SELECT count(*),coalesce(max(rowid),0) FROM generated_notes").first ?? []).joined(separator: ",") : ""
        let top = Int64(try rows("SELECT coalesce(max(rowid),0) FROM records").first?.first ?? "0") ?? 0
        return AgentStoreMark(global: fingerprint(epoch + "|" + policyBody + "|" + notes), top: top)
    }

    /// One local day for the tools, from the cache or read now.
    func agentDay(_ day: String, timezone: String, policy: AgentSharePolicy, now: Date, mark: AgentStoreMark) throws -> AgentDayData {
        let interval = try DayScope.interval(day: day, timezone: timezone)
        let signature = try daySignature(start: interval.start, end: interval.end, top: mark.top).joined(separator: ",")
        let key = home.standardizedFileURL.path + "|" + day + "|" + timezone
        let dayMark = [mark.global, signature, policy.typedWords ? "typed" : "untyped", String(policy.omittedKinds.sorted().joined(separator: ","))].joined(separator: "|")
        if let known = AgentDayCache.shared.get(key, mark: dayMark, now: now) { return known }
        let data = try agentReadDay(day, timezone: timezone, policy: policy, now: now)
        AgentDayCache.shared.put(key, mark: dayMark, now: now, data)
        return data
    }

    private func agentReadDay(_ day: String, timezone: String, policy: AgentSharePolicy, now: Date) throws -> AgentDayData {
        let assembled = try assembleDay(day: day, timezone: timezone, limit: 1, now: now, notes: true)
        var times = [String: Date](minimumCapacity: assembled.actions.count)
        for (id, action) in assembled.actions { times[id] = timestamp(action.at) ?? .distantPast }
        let actions = assembled.actions.values.sorted { (times[$0.id]!, $0.id) < (times[$1.id]!, $1.id) }
        // Typed facts: seal metadata and word counts, never words (the words come only from the app's bridge).
        var typed = [String: AgentTypedFact]()
        for action in actions where action.kind == "keyboard.text_input" {
            guard let evidence = try permittedOriginal(action.id, now: now) else { continue }
            typed[action.id] = AgentTypedFact(actionID: action.id, unit: evidence.captureProvenance?.unit,
                                              words: evidence.typed?.words ?? TypedWords.count(evidence.text))
        }
        // Notes: each bullet of the moment's note (or the one shown while it is rewritten), with the actions it cites.
        var notes = [AgentNoteInput](), pending = 0
        for activity in assembled.day.activities {
            if activity.status == "pending", let end = timestamp(activity.end), now.timeIntervalSince(end) > 30 * 60,
               activity.actionIDs.contains(where: { id in assembled.actions[id].map { !["idle", "session.started", "session.ended"].contains($0.kind) } ?? false }) {
                pending += 1
            }
            guard let note = activity.generated ?? activity.previous else { continue }
            for bullet in note.output.bullets where !bullet.text.isEmpty {
                notes.append(AgentNoteInput(actionIDs: bullet.actionIDs.isEmpty ? activity.actionIDs : bullet.actionIDs, lines: [bullet.text]))
            }
        }
        let items = AgentItems.items(AgentDayInput(day: day, timezone: timezone, actions: actions, typed: typed, notes: notes), policy: policy, now: now)
        var titles = [String: [String]](), sites = [String: [String]](), apps = [String: [String]]()
        for item in items {
            var t = [String](), s = [String](), a = [String]()
            var seenT = Set<String>(), seenS = Set<String>(), seenA = Set<String>()
            for id in item.actionIDs {
                guard let action = assembled.actions[id] else { continue }
                if !action.title.isEmpty, seenT.count < 64, seenT.insert(action.title).inserted { t.append(action.title) }
                if !action.site.isEmpty, seenS.insert(action.site).inserted { s.append(action.site) }
                let app = AppNames.display(app: action.app, bundle: action.bundle)
                if !app.isEmpty, seenA.insert(app).inserted { a.append(app) }
                if let alias = SearchDocument.alias(bundle: action.bundle, app: action.app), seenA.insert(alias).inserted { a.append(alias) }
            }
            titles[item.id] = t; sites[item.id] = s; apps[item.id] = a
        }
        var typedAt = [String: Date]()
        for id in typed.keys { typedAt[id] = times[id] }
        return AgentDayData(day: day, items: items, titles: titles, sites: sites, apps: apps, typedAt: typedAt, pendingNotes: pending,
                            partial: assembled.day.partial)
    }

    /// The first and last permitted action times in the history.
    func agentHistoryRange(now: Date) throws -> (from: Date, to: Date)? {
        guard let first = try actions(limit: 1, now: now).actions.first.flatMap({ timestamp($0.at) }),
              let last = try latestActionAt(now: now).flatMap(timestamp) else { return nil }
        return (first, max(first, last))
    }

    /// The local days in [start, end) where each term can appear in a record's title, app (and its display name and
    /// alias), site, terminal tool or typed-unit recipient: a superset of what an item can match on, from the lexicon
    /// (`AgentLexicon`, one scan per process, then only new rows). An empty `terms` gives every day with a record.
    func agentCandidateDays(terms: [String], start: Date, end: Date, timezone: String) throws -> [Set<String>] {
        let hours = try agentLexicon()
        let first = Self.lexiconHour(start.addingTimeInterval(-3600)), last = Self.lexiconHour(end.addingTimeInterval(3600))
        let folded = terms.map(AgentLexicon.fold)
        var out = Array(repeating: Set<String>(), count: max(1, terms.count))
        for (hour, blob) in hours where hour >= first && hour <= last {
            guard let at = timestamp(hour + ":00:00Z") else { continue }
            let days = Set([max(at, start), min(at.addingTimeInterval(3599), end.addingTimeInterval(-1))].filter { $0 >= start && $0 < end }
                .compactMap { try? DayScope.key($0, timezone: timezone) })
            guard !days.isEmpty else { continue }
            if terms.isEmpty { out[0].formUnion(days); continue }
            for (index, term) in folded.enumerated() where term.isEmpty || blob.contains(term) { out[index].formUnion(days) }
        }
        return out
    }

    static func lexiconHour(_ date: Date) -> String { String(iso(date).prefix(13)) }

    /// UTC hour ("2026-10-04T15") -> the folded, distinct searchable text of that hour's records, one line each. Built
    /// once per process and history; later calls read only rows added since (a superset: a replaced row's old text may
    /// stay). Rebuilt when the read epoch changes (a forget, a privacy change).
    func agentLexicon() throws -> [String: String] {
        let key = home.standardizedFileURL.path
        let epoch = try actionReadEpoch()
        let top = Int64(try rows("SELECT coalesce(max(rowid),0) FROM records").first?.first ?? "0") ?? 0
        var entry = AgentLexicon.shared.get(key).flatMap { $0.epoch == epoch && $0.top <= top ? $0 : nil } ?? AgentLexicon.Entry(epoch: epoch, top: 0, lines: [:], hours: [:])
        guard entry.top < top else { return entry.hours }
        let found = try rows("SELECT substr(json_extract(body,'$.at'),1,13),coalesce(json_extract(body,'$.title'),''),coalesce(json_extract(body,'$.app'),''),"
            + "coalesce(json_extract(body,'$.bundle'),''),coalesce(json_extract(body,'$.url'),''),coalesce(json_extract(body,'$.captureProvenance.unit.to'),''),"
            + "coalesce(json_extract(body,'$.captureProvenance.unit.handle'),'') FROM records WHERE rowid>? AND rowid<=? AND id NOT IN (SELECT id FROM tombstones)",
            [String(entry.top), String(top)])
        // Distinct raw rows first (most rows of an hour repeat a window), then fold each distinct line once.
        var raw = [String: Set<[String]>]()
        for row in found where row.count == 7 && row[0].count == 13 { raw[row[0], default: []].insert(Array(row[1...])) }
        for (hour, distinct) in raw {
            var lines = entry.lines[hour] ?? []
            let before = lines.count
            for row in distinct {
                let (title, app, bundle, url) = (row[0], row[1], row[2], row[3])
                var parts = [title, app, url, row[4], row[5], AppNames.display(app: app, bundle: bundle)]
                if let alias = SearchDocument.alias(bundle: bundle, app: app) { parts.append(alias) }
                if let tool = TitleClean.terminalTool(title) { parts.append(tool) }
                lines.insert(AgentLexicon.fold(parts.filter { !$0.isEmpty }.joined(separator: "\n")))
            }
            guard lines.count != before || entry.hours[hour] == nil else { continue }
            entry.lines[hour] = lines
            entry.hours[hour] = lines.joined(separator: "\n")
        }
        entry.top = top
        AgentLexicon.shared.put(key, entry)
        return entry.hours
    }

    /// The local days of stored moment notes whose text can hold `term` (a superset).
    func agentNoteDays(term: String, timezone: String) throws -> Set<String> {
        guard try hasActionLayers() else { return [] }
        let runs = MemorySearchQuery(term).filterRuns
        var sql = "SELECT g.body FROM generated_notes g WHERE g.version=(SELECT max(version) FROM generated_notes h WHERE h.id=g.id) AND g.id NOT LIKE 'day_%'"
        if !runs.isEmpty {
            sql += " AND ((" + runs.map { _ in "instr(lower(g.body),?)>0" }.joined(separator: " AND ") + ") OR g.body GLOB ?)"
        }
        let bodies = try rows(sql, runs.isEmpty ? [] : runs + [MemorySearchQuery.foldableGlob])
        var firstIDs = [String]()
        for row in bodies {
            guard let note = try? decode(GeneratedNote.self, row[0]), let id = note.actionIDs.first else { continue }
            firstIDs.append(id)
        }
        var days = Set<String>()
        for chunk in stride(from: 0, to: firstIDs.count, by: 400).map({ Array(firstIDs[$0..<min($0 + 400, firstIDs.count)]) }) {
            for row in try rows("SELECT json_extract(body,'$.at') FROM records WHERE id IN (SELECT value FROM json_each(?))", [json(chunk)]) {
                if let at = row.first.flatMap(timestamp), let day = try? DayScope.key(at, timezone: timezone) { days.insert(day) }
            }
        }
        return days
    }

    /// The local days the local search index finds `query` in with typos allowed; nil when the index isn't running.
    func agentIndexDays(query: String, start: Date?, end: Date?, timezone: String) -> Set<String>? {
        guard let config = try? TypesenseConfiguration.load(home: home) else { return nil }
        let transport = LocalTypesenseHTTP(config, sync: false)
        let deadline = Date().addingTimeInterval(1.5)
        var filters = [String]()
        if let start { filters.append("at:>=\(Int64(start.timeIntervalSince1970))") }
        if let end { filters.append("at:<\(Int64(end.timeIntervalSince1970))") }
        var days = Set<String>(), page = 1
        while Date() < deadline, page <= 40 {
            guard let response = try? transport.request("GET", "/collections/\(config.collection)/documents/search", query: [
                URLQueryItem(name: "q", value: query), URLQueryItem(name: "query_by", value: "summary,app,site"),
                URLQueryItem(name: "num_typos", value: "2"), URLQueryItem(name: "min_len_1typo", value: "4"), URLQueryItem(name: "min_len_2typo", value: "8"),
                URLQueryItem(name: "enable_typos_for_numerical_tokens", value: "false"), URLQueryItem(name: "drop_tokens_threshold", value: "0"),
                URLQueryItem(name: "include_fields", value: "at"), URLQueryItem(name: "highlight_fields", value: "none"),
                URLQueryItem(name: "per_page", value: "250"), URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "filter_by", value: filters.joined(separator: " && ")),
                URLQueryItem(name: "enable_analytics", value: "false"), URLQueryItem(name: "use_cache", value: "false")], body: nil, deadline: deadline),
                  response.status == 200, let root = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                  let hits = root["hits"] as? [[String: Any]] else { return days.isEmpty ? nil : days }
            for hit in hits {
                guard let at = (hit["document"] as? [String: Any])?["at"] as? Int64 ?? ((hit["document"] as? [String: Any])?["at"] as? NSNumber)?.int64Value else { continue }
                if let day = try? DayScope.key(Date(timeIntervalSince1970: TimeInterval(at)), timezone: timezone) { days.insert(day) }
            }
            if hits.count < 250 { break }
            page += 1
        }
        return days
    }
}

// MARK: - Search

enum AgentSearch {
    /// The filters `AgentTools.parse` folds into the query (`person:"Maya Chen" app:Mail site:docs.google.com`), so
    /// they travel in the frozen `AgentSearchArgs`.
    struct Query: Equatable {
        var text = ""
        var person: String?
        var app: String?
        var site: String?
        var words: [String] { Array(MemorySearchQuery(text).words.prefix(8)) }
    }

    static let filterKeys = ["person", "app", "site"]

    /// Folds a filter into the query text: `key:"value"`.
    static func token(_ key: String, _ value: String) -> String {
        key + ":\"" + value.replacingOccurrences(of: "\"", with: "") + "\""
    }

    static func parseQuery(_ raw: String) -> Query {
        var query = Query(), rest = [String]()
        var scanner = Substring(raw)
        while !scanner.isEmpty {
            scanner = scanner.drop { $0.isWhitespace }
            guard !scanner.isEmpty else { break }
            if let colon = scanner.firstIndex(of: ":"), filterKeys.contains(scanner[..<colon].lowercased()) {
                let key = scanner[..<colon].lowercased()
                var after = scanner[scanner.index(after: colon)...]
                var value: Substring
                if after.first == "\"" {
                    after = after.dropFirst()
                    let close = after.firstIndex(of: "\"") ?? after.endIndex
                    value = after[..<close]; scanner = close < after.endIndex ? after[after.index(after: close)...] : after[close...]
                } else {
                    let space = after.firstIndex(where: { $0.isWhitespace }) ?? after.endIndex
                    value = after[..<space]; scanner = after[space...]
                }
                let clean = value.trimmingCharacters(in: .whitespaces)
                if !clean.isEmpty {
                    switch key { case "person": query.person = clean; case "app": query.app = clean; default: query.site = clean.lowercased() }
                }
                continue
            }
            let end = scanner.firstIndex(where: { $0.isWhitespace }) ?? scanner.endIndex
            rest.append(String(scanner[..<end])); scanner = scanner[end...]
        }
        query.text = rest.joined(separator: " ")
        return query
    }

    static func contains(_ text: String, _ word: String) -> Bool {
        text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
    }

    /// The typed-line framing for an item (plan §6.1). Never a send state.
    static func form(_ entity: AgentEntity) -> AgentTypedLineForm {
        switch entity {
        case .person(let name): return .texted(name: name)
        case .aiChat(let app, _): return .asked(app: app)
        case .webSearch(let engine, _): return .searched(engine: engine)
        case .terminal(let tool, let project, let host):
            if AgentGroup.isAITool(tool), let tool { return .asked(app: tool) }
            return .ran(project: project ?? host ?? tool ?? "Terminal")
        default: return .typedIn(place: AgentText.place(entity))
        }
    }

    struct Hit { let item: AgentItem; var matched: [String]; var typed: [AgentTypedLine]; var note: String?; var typedIDs: Set<String> = [] }

    static func run(_ args: AgentSearchArgs, context: AgentToolContext, policy: AgentSharePolicy) throws -> AgentAnswer {
        let store = context.store, zone = TimeZone(identifier: context.timezone) ?? .current, now = context.now
        let query = parseQuery(args.query)
        let words = query.words
        let history = try store.agentHistoryRange(now: now)
        var period: AgentPeriod?
        if let when = args.when?.trimmingCharacters(in: .whitespaces), !when.isEmpty {
            period = try AgentWhen.resolve(when, now: now, zone: zone, maxDays: nil)
        }
        let start = period?.start ?? history.map { $0.from.addingTimeInterval(-1) } ?? now
        let end = period?.end ?? now.addingTimeInterval(1)
        // Terms every matching item holds: the words, and the person, app and site filters (they also narrow below).
        var terms = words
        if let person = query.person { terms.append(person) }
        if let app = query.app { terms.append(app) }
        if let site = query.site { terms.append(site) }
        let mark = try store.agentMark()

        // Typed-word hits (the app's bridge; already through the share policy), per term.
        var typedHits = [String: [String: String]]()   // term -> typed action id -> snippet
        var typedHitAt = [String: String]()
        var typedComplete = true, typedOldest: String?, typedFailed: String?
        if policy.typedWords {
            for term in Set(words + (query.person.map { [$0] } ?? [])) {
                do {
                    let result = try context.typed.search(term, start: start, end: end, limit: nil)
                    var byID = [String: String]()
                    for hit in result.hits { byID[hit.id] = hit.snippet; typedHitAt[hit.id] = hit.at }
                    typedHits[term] = byID
                    if !result.complete { typedComplete = false; typedOldest = result.oldestScanned }
                } catch { typedFailed = unavailableLine(error); break }
            }
        }

        // 1. Candidate days.
        var candidates: Set<String>
        let rowDays = try store.agentCandidateDays(terms: terms, start: start, end: end, timezone: context.timezone)
        if terms.isEmpty {
            candidates = rowDays[0]
        } else {
            var perTerm = rowDays
            for (index, term) in terms.enumerated() {
                perTerm[index].formUnion(try store.agentNoteDays(term: term, timezone: context.timezone))
                // Typed hit days: a hit's own time.
                for id in (typedHits[term] ?? [:]).keys {
                    if let at = typedHitAt[id].flatMap(timestamp), let day = try? DayScope.key(at, timezone: context.timezone) { perTerm[index].insert(day) }
                }
            }
            candidates = perTerm.dropFirst().reduce(perTerm.first ?? []) { $0.intersection($1) }
        }
        let firstDay = AgentClock.dayKey(start, zone: zone), lastDay = AgentClock.dayKey(end.addingTimeInterval(-1), zone: zone)
        candidates = candidates.filter { $0 >= firstDay && $0 <= lastDay }

        // 2-3. Items, matched.
        func matches(_ whole: AgentItem, _ data: AgentDayData, close: MemorySearchQuery?, some: Bool = false) -> Hit? {
            if !AgentGroup.matches(whole.entity, kinds: args.kinds) { return nil }
            // With a when, the item as it was then (its visits, last time and typed rows in the period).
            guard let item = period.map({ AgentTools.within(whole, $0, typedAt: data.typedAt) }) ?? whole else { return nil }
            guard item.lastAt >= start, item.firstAt < end else { return nil }
            let name = AgentText.label(item.entity)
            let titles = data.titles[item.id] ?? [], sites = data.sites[item.id] ?? [], apps = data.apps[item.id] ?? []
            if let person = query.person {
                guard case .person(let who) = item.entity, contains(who, person) else { return nil }
            }
            if let app = query.app {
                guard apps.contains(where: { contains($0, app) }) || contains(name, app) else { return nil }
            }
            if let site = query.site {
                guard sites.contains(where: { $0.lowercased() == site || $0.lowercased().hasSuffix("." + site) }) else { return nil }
            }
            var hit = Hit(item: item, matched: [], typed: [], note: nil)
            func reason(_ r: String) { if !hit.matched.contains(r) { hit.matched.append(r) } }
            if let close {
                let blob = ([name] + titles + sites + apps + item.noteLines).joined(separator: "\n")
                guard close.lexicalScore(blob) != nil else { return nil }
                reason("close spelling")
                return hit
            }
            var matchedWords = 0
            for word in words {
                matchedWords += 1
                if contains(name, word) || titles.contains(where: { contains($0, word) }) { reason("title"); continue }
                if sites.contains(where: { contains($0, word) }) { reason("site"); continue }
                if apps.contains(where: { contains($0, word) }) { reason("app"); continue }
                if let line = item.noteLines.first(where: { contains($0, word) }) { reason("note"); hit.note = hit.note ?? line; continue }
                let typedIDs = Set(item.typedIDs)
                let found = (typedHits[word] ?? [:]).filter { typedIDs.contains($0.key) }
                if !found.isEmpty {
                    reason("typed words")
                    // One line per typed row: the first word's snippet (each word's search gives its own).
                    for (id, snippet) in found.sorted(by: { (data.typedAt[$0.key] ?? .distantPast) > (data.typedAt[$1.key] ?? .distantPast) })
                    where !hit.typedIDs.contains(id) && !hit.typed.contains(where: { $0.text == snippet }) {
                        hit.typedIDs.insert(id)
                        hit.typed.append(AgentTypedLine(at: data.typedAt[id] ?? item.lastAt, form: form(item.entity), text: snippet))
                    }
                    continue
                }
                matchedWords -= 1
                if !some { return nil }
            }
            if some, matchedWords == 0 { return nil }
            if query.person != nil, words.isEmpty { reason("person") }
            return hit
        }
        var hits = [Hit]()
        var days = [String: AgentDayData]()
        for day in candidates.sorted(by: >) {
            let data = try store.agentDay(day, timezone: context.timezone, policy: policy, now: now, mark: mark)
            days[day] = data
            for item in data.items { if let hit = matches(item, data, close: nil) { hits.append(hit) } }
        }
        // 3b. Some of the words, only when no item holds them all ("launch checklist" finds "Tallybird launch notes" when
        // the checklist was only typed and typed words can't be searched now). The reply says so.
        var someWords = false
        if hits.isEmpty, words.count > 1 {
            var pool = Set<String>()
            for (index, term) in terms.enumerated() where words.contains(term) {
                pool.formUnion(rowDays[index])
                pool.formUnion(try store.agentNoteDays(term: term, timezone: context.timezone))
            }
            for day in pool.filter({ $0 >= firstDay && $0 <= lastDay }).sorted(by: >) {
                let data = try days[day] ?? store.agentDay(day, timezone: context.timezone, policy: policy, now: now, mark: mark)
                days[day] = data
                for item in data.items { if let hit = matches(item, data, close: nil, some: true) { hits.append(hit) } }
            }
            someWords = !hits.isEmpty
        }
        // 4. Close spellings, only when nothing matches exactly.
        var close = false
        let lexical = MemorySearchQuery(query.text)
        if hits.isEmpty, !words.isEmpty, lexical.permitsTypos {
            let indexDays = store.agentIndexDays(query: query.text, start: period?.start, end: period?.end, timezone: context.timezone)
            var pool: Set<String>
            if let indexDays { pool = indexDays }
            else { pool = try store.agentCandidateDays(terms: [], start: max(start, now.addingTimeInterval(-31 * 86_400)), end: end, timezone: context.timezone)[0] }
            pool = pool.filter { $0 >= firstDay && $0 <= lastDay }
            for day in pool.sorted(by: >) {
                let data = try days[day] ?? store.agentDay(day, timezone: context.timezone, policy: policy, now: now, mark: mark)
                for item in data.items { if let hit = matches(item, data, close: lexical) { hits.append(hit) } }
            }
            close = !hits.isEmpty
        }

        // Rank across days: importance first (`AgentRank`, with on how many matching days the same thing was seen),
        // then the latest first.
        var daysSeen = [String: Set<String>]()
        for hit in hits { daysSeen[hit.item.entity.key, default: []].insert(hit.item.day) }
        let ranked = hits.map { hit in (hit, AgentRank.score(hit.item, now: now, weights: .standard, daysSeen: daysSeen[hit.item.entity.key]?.count ?? 1)) }
        hits = ranked.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : ($0.0.item.lastAt, $0.0.item.id) > ($1.0.item.lastAt, $1.0.item.id) }.map(\.0)

        // Page.
        let total = hits.count, visits = hits.reduce(0) { $0 + $1.item.visitCount }
        let offset = try args.cursor.map { cursor -> Int in
            guard let value = Int(cursor.trimmingCharacters(in: .whitespaces)), value >= 0 else {
                throw MemError.invalid("cursor must be the value from the previous search's More line, with the same query, kinds and when.")
            }
            return value
        } ?? 0
        let limit = max(1, min(50, args.limit))
        var page = Array(hits.dropFirst(offset).prefix(limit))
        // Typed lines for people, AI chats and terminals that matched on something else: their latest words.
        var wanted = [String]()
        for hit in page where hit.typed.isEmpty && policy.typedWords {
            switch hit.item.entity {
            case .person, .aiChat, .terminal, .webSearch: wanted += latestTyped(hit.item, days[hit.item.day], count: 2)
            default: break
            }
        }
        let fetched = fetchWords(wanted, typed: context.typed)
        let words_ = fetched.words
        for index in page.indices where page[index].typed.isEmpty {
            let ids = latestTyped(page[index].item, days[page[index].item.day], count: 2)
            page[index].typed = ids.compactMap { id in
                words_[id].map { AgentTypedLine(at: days[page[index].item.day]?.typedAt[id] ?? page[index].item.lastAt, form: form(page[index].item.entity), text: $0) }
            }
        }

        // Typed words not searched (off, closed, locked, refused): say so with WP-A's line, never a bare "no matches".
        let typedNote = typedFailed ?? (policy.typedWords ? fetched.unavailable : policy.typedWordsLine)
        let coverage = policy.typedWords && typedFailed == nil ? "titles, sites, notes and typed words" : "titles, sites and notes"
        var filters = [String]()
        if !args.kinds.isEmpty { filters.append("kinds: " + args.kinds.map(\.rawValue).sorted().joined(separator: ", ")) }
        if let person = query.person { filters.append("person: " + person) }
        if let app = query.app { filters.append("app: " + app) }
        if let site = query.site { filters.append("site: " + site) }
        if let period { filters.append(period.label) }
        let header = try AgentTools.header(context, range: history, pending: days.values.filter { $0.day == AgentClock.dayKey(now, zone: zone) }.first?.pendingNotes)
        var incomplete: String?
        if !typedComplete {
            incomplete = "typed words were checked back to " + (typedOldest.flatMap(timestamp).map { AgentClock.format($0, "MMM d, h:mm a", zone: zone) } ?? "part of the range") + "; titles, sites and notes are complete."
        }
        func answer(_ shown: [Hit]) -> AgentAnswer {
            let rest = total - offset - shown.count
            let reply = AgentSearchReply(query: query.text, total: total, totalVisits: visits, offset: offset, items: shown.map(\.item),
                                         cursor: rest > 0 ? String(offset + shown.count) : nil, complete: incomplete == nil, incompleteReason: incomplete)
            var extras = [String: AgentItemExtra]()
            for hit in shown { extras[hit.item.id] = AgentItemExtra(typed: hit.typed, matched: hit.matched, note: hit.note) }
            return AgentAnswer(reply: AgentReply(header: header, body: .search(reply)), extras: extras,
                               page: AgentPage(remaining: max(0, rest), coverage: coverage, closeMatches: close,
                                               filters: filters.isEmpty ? nil : filters.joined(separator: " · "), typedNote: typedNote,
                                               someWords: someWords))
        }
        // Fit the budget: the most items that fit (at least one).
        var count = page.count
        while count > 1, AgentRender.textTokens(answer(Array(page.prefix(count)))) > AgentBudget.search { count -= max(1, count / 8) }
        return answer(Array(page.prefix(max(min(1, page.count), count))))
    }

    /// The item's newest typed action ids, newest first.
    static func latestTyped(_ item: AgentItem, _ data: AgentDayData?, count: Int) -> [String] {
        let at = data?.typedAt ?? [:]
        return item.typedIDs.sorted { (at[$0] ?? .distantPast, $0) > (at[$1] ?? .distantPast, $1) }.prefix(count).map { $0 }
    }

    /// Words for typed ids from the typed source (already through the share policy), 400 ids per request. A failure
    /// gives no words and its plain line (`AgentBridgeError.description`): the tool still answers and says why.
    static func fetchWords(_ ids: [String], typed: AgentTypedSource) -> (words: [String: String], unavailable: String?) {
        var out = [String: String]()
        let unique = Array(Set(ids)).sorted()
        for start in stride(from: 0, to: unique.count, by: 400) {
            let chunk = Array(unique[start..<min(start + 400, unique.count)])
            do { out.merge(try typed.words(chunk)) { a, _ in a } }
            catch { return (out, unavailableLine(error)) }
        }
        return (out, nil)
    }

    /// The plain line for a typed-words failure: WP-A's own wording, or the closed-app line for anything else.
    static func unavailableLine(_ error: Error) -> String {
        (error as? AgentBridgeError)?.description ?? AgentBridgeError.unavailable(.appClosed).description
    }

    /// The line a reply carries when items here hold typed words that weren't shared: the policy's own line.
    static func typedOffLine(_ policy: AgentSharePolicy, _ items: [AgentItem]) -> String? {
        guard !policy.typedWords, items.contains(where: { !$0.typedIDs.isEmpty }) else { return nil }
        return policy.typedWordsLine
    }
}
