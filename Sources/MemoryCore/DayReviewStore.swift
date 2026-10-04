import Foundation
import PrivacyPolicy

// claude/day-review-1003: the day review's facts from the store (DayReview.swift has the values and the rules).
//
// - Facts (`dayReview`): on every day read, at no model cost: the day's threads (ThreadPlanner) grouped by project or
//   person across apps, each scored by time, words written and sends (people boosts on top), and each thread's candidate
//   bullets with their leads, links and which typed row each may quote. Metadata only: typed words are counted from
//   `typed_text.words`, never read.
// - Clauses (`review_clauses`): the model's short clause per thread, written by the level writer
//   (LevelWriterBinding.reviewClause) when a shown thread changed materially, and kept until its sources go (a Forget,
//   a delete, retention or "Forget what I typed" deletes it with them).
// - Quotes (`ownerReviewQuotes`): the quoted rows' words, opened in the DayDream app's own process only, as the timeline's
//   AI asks are (MomentPrompts.swift); never stored, indexed, logged or handed to a writer.

/// What a clause would be written from (`MemoryStore.reviewBuild`).
struct DayReviewSource {
    var lead: String
    var name: String
    var colon: Bool
    var notes: [String]
    var signature: String
    var actionIDs: [String]
    var start: String
    var end: String
}

extension MemoryStore {
    func hasReviewClauses() throws -> Bool { !(try rows("SELECT name FROM sqlite_master WHERE type='table' AND name='review_clauses'")).isEmpty }
    static func reviewClauseID(day: String, key: String) -> String { "rc_" + fingerprint("review|" + day + "|" + key).prefix(24) }

    /// The cached clauses of a day, by thread key.
    public func reviewClauses(day: String) throws -> [String: DayReviewClause] {
        guard try hasReviewClauses() else { return [:] }
        var out = [String: DayReviewClause]()
        for row in try rows("SELECT body FROM review_clauses WHERE day=?", [day]) {
            guard let c = try? decode(DayReviewClause.self, row[0]) else { continue }
            out[c.key] = c
        }
        return out
    }
    /// Every clause written from any of `ids`.
    func dropReviewClauses(forActions ids: [String]) throws {
        guard !ids.isEmpty else { return }
        // Something is being forgotten or expiring: every cached review in this process is checked again.
        DayReviewCache.bump()
        guard try hasReviewClauses() else { return }
        try exec("DELETE FROM review_clauses WHERE json_valid(body) AND EXISTS(SELECT 1 FROM json_each(review_clauses.body,'$.actionIDs') r JOIN json_each(?) c ON r.value=c.value)",
                 [json(Array(Set(ids)).sorted())])
    }

    /// Saves one clause the writer wrote and checked (`DayReviewClauses.validate`). Core checks it again: every action it
    /// was written from is still here, and it copies nothing the person typed (TypedVerbatimGuard).
    @discardableResult public func commitReviewClause(_ r: DayReviewClauseRequest, text: String, generator: String = DayReviewClauses.version, now: Date = Date()) throws -> DayReviewClause {
        guard try hasReviewClauses() else { throw MemError.invalid("Review clauses unavailable") }
        let ids = Array(Set(r.actionIDs)).sorted()
        let typed = try citesTypedText(ids)
        if typed { try typedVerbatimGuard(texts: [text], actionIDs: ids) }
        let clause = DayReviewClause(key: r.key, day: r.day, text: text, signature: r.signature, writtenAt: iso(now), generator: generator, actionIDs: ids, typed: typed)
        try transaction {
            let present = Int(try rows("SELECT count(*) FROM records WHERE id IN (SELECT value FROM json_each(?)) AND id NOT IN (SELECT id FROM tombstones)", [json(ids)]).first?.first ?? "0") ?? 0
            guard present == ids.count else { throw MemError.invalid("Review clause sources changed") }
            try exec("INSERT OR REPLACE INTO review_clauses VALUES(?,?,?,?)", [Self.reviewClauseID(day: r.day, key: r.key), r.day, typed ? "1" : "0", json(clause)])
        }
        return clause
    }

    // MARK: facts

    /// The day's review facts (nil for a day with nothing in it), with the cached clauses. `plan`: the day's threads when
    /// already planned (computed only when the cache misses).
    func dayReview(_ assembled: AssembledDay, plan known: @autoclosure () throws -> ThreadPlan? = nil, day: String, timezone: String, now: Date) throws -> DayReviewFacts? {
        try withClauses(cachedReviewBuild(assembled, plan: try known(), day: day, timezone: timezone, now: now))?.facts
    }

    // MARK: cache (perf pass 10/03)

    /// The review's facts, kept per history, day and time zone (`DayReviewCache`): built again only when the day's records
    /// or notes change (new records, a Forget, retention, an exclusion) or a clause source was dropped. Clauses are read
    /// fresh on every read (one small table), so a saved clause needs no rebuild.
    func cachedReviewBuild(_ assembled: AssembledDay, plan known: @autoclosure () throws -> ThreadPlan?, day: String, timezone: String, now: Date) throws -> (facts: DayReviewFacts, sources: [String: DayReviewSource])? {
        let key = DayReviewCache.key(home: home, day: day, timezone: timezone)
        let print = try reviewFingerprint(assembled)
        if let hit = DayReviewCache.shared.get(key, print: print) { return hit }
        let built = try reviewBuild(assembled, plan: try known(), day: day, timezone: timezone, now: now)
        DayReviewCache.shared.put(key, print: print, built: built)
        return built
    }
    /// The cached facts of a day with today's clauses, without reading the day (the Today card's refresh after a clause is
    /// saved). nil when the day isn't cached in this process: the caller reads the day instead.
    public func cachedDayReview(day: String, timezone: String) throws -> DayReviewFacts? {
        guard let hit = DayReviewCache.shared.any(DayReviewCache.key(home: home, day: day, timezone: timezone)) else { return nil }
        return try withClauses(hit)?.facts
    }
    func withClauses(_ built: (facts: DayReviewFacts, sources: [String: DayReviewSource])?) throws -> (facts: DayReviewFacts, sources: [String: DayReviewSource])? {
        guard var built else { return nil }
        var clauses = [String: String]()
        for (k, c) in try reviewClauses(day: built.facts.day) where built.sources[k] != nil && !c.text.isEmpty { clauses[k] = c.text }
        built.facts.clauses = clauses
        return built
    }
    /// What the facts are built from: the day's moments (ids, spans, actions, notes), the privacy settings and this
    /// process's drop count (a Forget or retention). Cheap: the day is already read.
    func reviewFingerprint(_ assembled: AssembledDay) throws -> Int {
        var h = Hasher()
        h.combine(DayReviewCache.epoch)
        for m in assembled.day.activities {
            h.combine(m.id); h.combine(m.start); h.combine(m.end); h.combine(m.actionIDs.count); h.combine(m.actionIDs.last)
            h.combine((m.generated ?? m.previous)?.generatedAt)
        }
        h.combine(assembled.actions.count)
        h.combine(try rows("SELECT body FROM metadata WHERE id='policy'").first?.first)
        return h.finalize()
    }

    /// One typed row as the review reads it (metadata only).
    struct ReviewTyped {
        var id: String, at: Date, surface: String, field: String, sent: Bool, to: String?, words: Int, keys: Int?, edits: Int?
        var startedAt: Date?, run: String, part: Int, author: String?, handle: String?, community: String?, subject: String?
        var app: String, bundle: String, site: String, title: String, tool: String?
        var stakes: [DayReview.Stake] = []
        var effort: Double = 0
        var person: Bool { ["text", "chat", "email", "social"].contains(surface) }
        var ask: Bool { surface == "ai" || surface == "aiTool" }
    }

    func reviewBuild(_ assembled: AssembledDay, plan known: ThreadPlan? = nil, day: String, timezone: String, now: Date) throws -> (facts: DayReviewFacts, sources: [String: DayReviewSource])? {
        let moments = assembled.day.activities.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        guard !moments.isEmpty else { return nil }
        let plan = try known ?? threadPlan(moments: moments, actions: assembled.actions)
        let byMoment = Dictionary(moments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let active = moments.filter { m in
            let actions = m.actionIDs.compactMap { assembled.actions[$0] }
            return plan.momentEntity[m.id] != nil && !actions.allSatisfy { $0.kind == "idle" || $0.app.isEmpty }
        }
        guard !active.isEmpty else { return nil }
        let threads = plan.threads(for: Set(active.map(\.id)))
        guard !threads.isEmpty else { return nil }
        var zone = Calendar(identifier: .gregorian); zone.timeZone = TimeZone(identifier: timezone) ?? .current
        let dayStart = (try? DayScope.interval(day: day, timezone: timezone).start) ?? now

        // Typed rows: counts and send facts only.
        let typedIDs = active.flatMap(\.actionIDs).filter { assembled.actions[$0]?.kind == "keyboard.text_input" }
        var typed = [String: ReviewTyped]()
        if !typedIDs.isEmpty {
            let recipients = try typedRecipients(typedIDs)
            let words = try hasTypedTables() ? "coalesce((SELECT t.words FROM typed_text t WHERE t.id=r.id),-1)" : "-1"
            let u = "$.captureProvenance.unit."
            func f(_ k: String, _ d: String = "''") -> String { "coalesce(json_extract(r.body,'\(u)\(k)'),\(d))" }
            let sql = "SELECT r.id,\(f("surface")),\(f("field")),\(f("to")),\(f("keys","-1")),\(f("edits","-1")),\(f("startedAt")),\(f("runID")),\(f("part","1")),\(f("contextAuthor")),\(f("handle")),\(f("community")),\(f("subject")),\(words),coalesce(json_extract(r.body,'$.withheld'),0) FROM records r WHERE r.id IN (SELECT value FROM json_each(?))"
            var parts = [String: Int]()
            var rows = [[String]]()
            for row in try self.rows(sql, [json(typedIDs)]) { rows.append(row); let run = row[7].isEmpty ? row[0] : row[7]; parts[run] = max(parts[run] ?? 1, Int(row[8]) ?? 1) }
            for row in rows {
                guard let a = assembled.actions[row[0]], let at = timestamp(a.at) else { continue }
                let host = ThreadEntities.host(a.site)
                let surface = row[1].isEmpty ? SendRules.surface(bundle: a.bundle, host: host.isEmpty ? nil : host, title: a.title) : row[1]
                let rawTo = MessagesMomentIdentity.applies(a) ? recipients[a.id] : (recipients[a.id] ?? (row[3].isEmpty ? nil : row[3]))
                let to = rawTo.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty || $0.contains("@") ? nil : $0 }
                let keys = Int(row[4]).flatMap { $0 < 0 ? nil : $0 }, edits = Int(row[5]).flatMap { $0 < 0 ? nil : $0 }
                let w = Int(row[13]).flatMap { $0 < 0 ? nil : $0 } ?? (keys.map { $0 / 6 } ?? 0)
                func opt(_ s: String) -> String? { s.isEmpty ? nil : s }
                let tool = a.tool.flatMap { $0.isEmpty ? nil : $0 } ?? (surface == "aiTool" ? TitleClean.terminalTool(a.title) : nil)
                var t = ReviewTyped(id: a.id, at: at, surface: surface, field: row[2], sent: a.state == "submitted" || a.state == "sent", to: to, words: w, keys: keys, edits: edits,
                                    startedAt: timestamp(row[6]), run: row[7].isEmpty ? a.id : row[7], part: Int(row[8]) ?? 1, author: opt(row[9]), handle: opt(row[10]),
                                    community: opt(row[11]), subject: opt(row[12]).flatMap { TypedSecretScrubber.sensitiveSubject($0) == nil ? $0 : nil },
                                    app: a.app, bundle: a.bundle, site: a.site, title: a.title, tool: tool)
                if t.sent, t.person, !["to", "subject"].contains(t.field) {
                    let compose = t.startedAt.map { at.timeIntervalSince($0) } ?? 0
                    let first = try t.to.map { try firstContact($0, before: dayStart, day: day) } ?? false
                    t.stakes = DayReview.stakes(words: t.words, keys: t.keys, edits: t.edits, parts: parts[t.run] ?? t.part, composeSeconds: compose,
                                                localHour: zone.component(.hour, from: at), firstContact: first)
                }
                t.effort = DayReview.effort(words: t.words, edits: t.edits, stakes: t.stakes)
                typed[a.id] = t
            }
        }
        let personKinds: Set<String> = ["texts", "chat", "slack", "email"]
        let workKinds: Set<String> = ["code", "ai", "pr", "doc", "web", "meeting"]

        // Projects: a name shared by two or more pieces of work ("daydream" in a Claude Code session's title, a GitHub repo
        // and a terminal folder) makes them one thread; each piece goes with its heaviest shared name.
        let peopleWords = Set(threads.flatMap { $0.people.flatMap(ThreadEntities.tokens) })
        func projectWords(_ t: LevelThread) -> Set<String> {
            guard workKinds.contains(t.kind) else { return [] }
            var text = t.label
            for m in t.momentIDs { if let e = plan.momentEntity[m] { text += " " + (e.project ?? "") + " " + e.label } }
            return Set(ThreadEntities.tokens(text).filter { $0.count >= 4 && Int($0) == nil && !ThreadEntities.stopWords.contains($0)
                && !ThreadEntities.commonWords.contains($0) && !Self.reviewGeneric.contains($0) && !peopleWords.contains($0) })
        }
        var tokenThreads = [String: Set<String>](), weight = [String: Int](), wordsOf = [String: Set<String>]()
        for t in threads {
            let w = projectWords(t)
            wordsOf[t.key] = w
            for tok in w { tokenThreads[tok, default: []].insert(t.key); weight[tok, default: 0] += t.seconds }
        }
        let shared = Set(tokenThreads.filter { $0.value.count >= 2 }.keys)
        var projectOf = [String: String]()
        for t in threads {
            guard let best = wordsOf[t.key]?.intersection(shared).max(by: { (weight[$0] ?? 0, $1) < (weight[$1] ?? 0, $0) }) else { continue }
            projectOf[t.key] = best
        }
        // A project of one piece is that piece's own thread, unless the piece names its repo or folder itself (code in
        // ~/daydream, a PR on acme/daydream): then it is that project's thread too.
        let projectCounts = Dictionary(projectOf.values.map { ($0, 1) }, uniquingKeysWith: +)
        projectOf = projectOf.filter { (projectCounts[$0.value] ?? 0) >= 2 }
        for t in threads where projectOf[t.key] == nil && workKinds.contains(t.kind) {
            var named = [String: Int]()
            for m in t.momentIDs { if let p = plan.momentEntity[m]?.project, !p.isEmpty { named[p, default: 0] += 1 } }
            guard let best = named.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key else { continue }
            let tok = ThreadEntities.tokens(best).joined()
            if !tok.isEmpty, !Self.reviewGeneric.contains(tok), !peopleWords.contains(tok) { projectOf[t.key] = tok }
        }

        // Groups.
        struct Group { var key: String; var name: String; var kind: String; var members: [LevelThread] }
        var groups = [String: Group](), order = [String]()
        func add(_ key: String, _ name: String, _ kind: String, _ t: LevelThread) {
            if groups[key] == nil { groups[key] = Group(key: key, name: name, kind: kind, members: []); order.append(key) }
            groups[key]!.members.append(t)
        }
        let labels = threads.map(\.label)
        for t in threads {
            if let tok = projectOf[t.key] {
                add("project:" + tok, Self.projectName(tok, in: labels), "project", t)
            } else if personKinds.contains(t.kind), let who = (t.people.first ?? (t.kind == "slack" ? t.places.first : nil)), !t.key.hasPrefix("texts:?") {
                let name = who.hasPrefix("#") ? who : ThreadEntities.capitalized(who)
                add("person:" + ThreadEntities.norm(who), name, "person", t)
            } else {
                add(t.key, Self.reviewDisplay(t), t.kind, t)
            }
        }

        // Each group's facts, items and score.
        var out = [DayReviewThread](), sources = [String: DayReviewSource]()
        var activeSeconds = 0, personSendsDay = 0
        for key in order {
            guard let g = groups[key] else { continue }
            let momentIDs = Self.unique(g.members.flatMap(\.momentIDs))
            let actionIDs = momentIDs.flatMap { byMoment[$0]?.actionIDs ?? [] }
            let rows = actionIDs.compactMap { typed[$0] }.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
            let sends = rows.filter { $0.sent && !["to", "subject"].contains($0.field) && ($0.person || $0.ask) }
            let personSends = sends.filter(\.person), asks = sends.filter(\.ask)
            let seconds = g.members.reduce(0) { $0 + $1.seconds }
            let words = rows.reduce(0) { $0 + $1.words }
            let hours = Set(personSends.map { zone.component(.hour, from: $0.at) }).count
            let stakes = personSends.flatMap(\.stakes)
            var score = DayReview.score(seconds: seconds, words: words, personSends: personSends.count, asks: asks.count,
                                        sendHours: g.kind == "person" || g.kind == "social" ? hours : 0, stakes: stakes.count)
            if g.kind == "app" { score *= 0.5 }
            activeSeconds += seconds; personSendsDay += personSends.count
            func notes(_ ids: [String]) -> [String] {
                ids.compactMap { byMoment[$0] }.sorted { $0.start > $1.start }.compactMap { m -> String? in
                    guard let note = m.generated ?? m.previous else { return nil }
                    let lines = note.output.bullets.map(\.text).filter { !$0.isEmpty }
                    return note.output.title + (lines.isEmpty ? "" : ": " + lines.joined(separator: " "))
                }
            }
            func span(_ ids: [String]) -> (String, String) {
                let ms = ids.compactMap { byMoment[$0] }
                return (ms.map(\.start).min() ?? "", ms.map(\.end).max() ?? "")
            }
            func source(_ clauseKey: String, lead: String, name: String, colon: Bool, ids: [String], sendCount: Int, askCount: Int) {
                let n = notes(ids)
                let noted = ids.compactMap { byMoment[$0] }.filter { ($0.generated ?? $0.previous) != nil }.count
                let (s, e) = span(ids)
                sources[clauseKey] = DayReviewSource(lead: lead, name: name, colon: colon, notes: n, signature: "s\(sendCount)|p\(askCount / 10)|m\(noted)",
                                                     actionIDs: ids.flatMap { byMoment[$0]?.actionIDs ?? [] }, start: s, end: e)
            }
            var items = [DayReviewItem]()
            switch g.kind {
            case "person":
                let channel = g.members.first?.kind ?? "texts"
                let verb = channel == "email" ? "Emailed" : channel == "texts" ? "Texted" : "Messaged"
                if let latest = personSends.last {
                    let effortful = personSends.max { ($0.effort, $0.at) < ($1.effort, $1.at) }!
                    let subject = channel == "email" ? personSends.compactMap(\.subject).last : nil
                    let told = channel == "email" ? "Emailed " + g.name : "Told " + g.name
                    items.append(DayReviewItem(id: key + "#said", lead: told, plainLead: verb + " " + g.name,
                                               tail: DayReview.topic(subject, echoing: [g.name]).map { "about " + $0 },
                                               clauseKey: key, quote: latest.id, score: score, moments: momentIDs))
                    source(key, lead: told, name: g.name, colon: false, ids: momentIDs, sendCount: personSends.count, askCount: 0)
                    // The second line quotes the highest-effort text (else the one before the latest); once the first line has
                    // its clause (and so no quote), the highest-effort text or the latest.
                    let second = effortful.id != latest.id ? effortful : personSends.dropLast().last
                    items.append(DayReviewItem(id: key + "#quote", lead: verb + " " + g.name, quote: second?.id, quoteAlways: true, score: score - 1,
                                               moments: momentIDs, clauseQuote: effortful.id != latest.id ? effortful.id : latest.id, quoteWithClause: key,
                                               needsQuote: true))
                } else {
                    let what = channel == "email" ? "email from " : channel == "texts" ? "texts from " : channel == "slack" ? "Slack with " : "messages from "
                    items.append(DayReviewItem(id: key + "#read", lead: "Read", tail: what + g.name, score: score, moments: momentIDs))
                }
            case "social":
                let site = Self.siteName(g.members.first?.label ?? "", key: key)
                for s in personSends.reversed() {
                    let link = try reviewLink(near: s, moments: momentIDs, byMoment: byMoment, actions: assembled.actions)
                    let clauseKey = key + "#" + s.id
                    if let author = s.author {
                        let who = author.hasSuffix("s") ? author + "'" : author + "'s"
                        items.append(DayReviewItem(id: clauseKey, lead: "Replied to", link: DayReviewLink(title: who + " post", url: link), tail: "on " + site,
                                                   clauseKey: clauseKey, quote: s.id, quoteAlways: true, score: s.effort, moments: momentIDs))
                        source(clauseKey, lead: "Replied to " + who + " post", name: site, colon: false, ids: momentIDs, sendCount: 1, askCount: 0)
                    } else if let community = s.community {
                        items.append(DayReviewItem(id: clauseKey, lead: "Commented on", link: DayReviewLink(title: "r/" + community, url: link), quote: s.id, quoteAlways: true,
                                                   score: s.effort, moments: momentIDs))
                    } else if let handle = s.handle {
                        items.append(DayReviewItem(id: clauseKey, lead: "Replied to", link: DayReviewLink(title: "@" + handle, url: link), tail: "on " + site,
                                                   quote: s.id, quoteAlways: true, score: s.effort, moments: momentIDs))
                    } else {
                        items.append(DayReviewItem(id: clauseKey, lead: "Posted on " + site, quote: s.id, quoteAlways: true, score: s.effort, moments: momentIDs))
                    }
                }
                if items.isEmpty { items.append(DayReviewItem(id: key + "#read", lead: "Read", tail: "posts on " + site, score: score, moments: momentIDs)) }
            case "video", "web", "search":
                items += try pageItems(g.kind, key: key, members: g.members, momentIDs: momentIDs, byMoment: byMoment, actions: assembled.actions, plan: plan)
            default:
                let project = g.kind == "project" ? g.name : nil
                for t in g.members {
                    let ids = t.momentIDs
                    let ownActions = Set(ids.flatMap { byMoment[$0]?.actionIDs ?? [] })
                    let own = rows.filter { ownActions.contains($0.id) }
                    let ownAsks = own.filter { $0.sent && $0.ask }
                    let label = Self.reviewDisplay(t)
                    let about = project ?? Self.workName(t, label: label)
                    let s = Double(t.seconds) / 60 + Double(own.reduce(0) { $0 + $1.words }) / DayReview.wordsPerPoint + Double(ownAsks.count) * DayReview.askSend
                    let used = Self.unique(ownActions.sorted().compactMap { assembled.actions[$0] }.sorted { ($0.at, $0.id) < ($1.at, $1.id) }.map(\.app).filter { !$0.isEmpty })
                    // The apps the work was done in: a browser only when nothing else was used (it has its own lines).
                    let browsers: Set<String> = ["Google Chrome", "Chrome", "Safari", "Arc", "Firefox", "Brave Browser", "Microsoft Edge"]
                    let apps = used.contains { !browsers.contains($0) } ? used.filter { !browsers.contains($0) } : used
                    if let ask = ownAsks.last {
                        let tool = ask.tool ?? Self.aiName(assembled.actions[ask.id]!, host: ThreadEntities.host(ask.site))
                        // claude/today-copy-1004 (owner 10/04): an AI app's own thread is named after the app ("Claude"), so
                        // its ask read "Asked Claude about Claude". No "about …" when it only names the tool, the app or
                        // the site again: "Asked Claude: “…”".
                        let host = ThreadEntities.host(ask.site)
                        let topic = DayReview.topic(about, echoing: [tool, ask.app, ThreadEntities.friendlyHosts[host] ?? host] + DayReview.askPlaces)
                        items.append(DayReviewItem(id: t.key, lead: "Asked " + tool, tail: topic.map { "about " + $0 }, clauseKey: t.key, quote: ask.id, score: s, moments: ids))
                        source(t.key, lead: "Asked " + tool, name: about, colon: false, ids: ids, sendCount: 0, askCount: ownAsks.count)
                        continue
                    }
                    // In a project, a pull request read or opened among its moments has its own line, linked.
                    if g.kind == "project", t.kind != "pr" {
                        var seen = Set<String>()
                        for m in ids {
                            guard let e = plan.momentEntity[m], e.kind == "pr", seen.insert(e.raw).inserted else { continue }
                            let prMoments = ids.filter { plan.momentEntity[$0]?.raw == e.raw }
                            let url = try reviewLink(forThread: prMoments, byMoment: byMoment, actions: assembled.actions)
                            items.append(DayReviewItem(id: t.key + "|" + e.raw, lead: "Read", link: DayReviewLink(title: e.label, url: url), tail: "on GitHub",
                                                       score: s * 0.5, moments: prMoments))
                        }
                    }
                    switch t.kind {
                    case "pr":
                        let url = try reviewLink(forThread: ids, byMoment: byMoment, actions: assembled.actions)
                        items.append(DayReviewItem(id: t.key, lead: "Read", link: DayReviewLink(title: label, url: url), tail: "on GitHub", score: s, moments: ids))
                    case "web":
                        let url = try reviewLink(forThread: ids, byMoment: byMoment, actions: assembled.actions)
                        let site = Self.siteName(t.label, key: t.key)
                        if t.key.hasPrefix("site:") || label == site {
                            items.append(DayReviewItem(id: t.key, lead: "Read", tail: site, score: s, moments: ids))
                        } else {
                            items.append(DayReviewItem(id: t.key, lead: "Read", link: DayReviewLink(title: label, url: url), tail: "on " + site, score: s, moments: ids))
                        }
                    case "doc":
                        let wrote = own.contains { $0.words > 0 }
                        items.append(DayReviewItem(id: t.key, lead: wrote ? "Wrote" : "Read", tail: label, score: s, moments: ids))
                    case "meeting":
                        items.append(DayReviewItem(id: t.key, lead: "Joined", tail: label, score: s, moments: ids))
                    case "app":
                        items.append(DayReviewItem(id: t.key, lead: "Used", tail: label, score: s, moments: ids))
                    default:
                        // Code, an AI chat read, anything worked on: "Worked on DayDream: <clause>", else "… in Xcode".
                        // claude/today-rank-1005: an AI app's own thread read with no ask ("Worked on Claude: in Claude.") is "Used
                        // Claude", the sentence going on after it, as "Asked Claude" does (today-copy-1004's echo rule).
                        if DayReview.topic(about, echoing: apps + DayReview.askPlaces) == nil {
                            let lead = "Used " + about
                            items.append(DayReviewItem(id: t.key, lead: lead, clauseKey: t.key, score: s, moments: ids))
                            source(t.key, lead: lead, name: about, colon: false, ids: ids, sendCount: 0, askCount: 0)
                            continue
                        }
                        let lead = "Worked on " + about
                        items.append(DayReviewItem(id: t.key, lead: lead, colon: true, tail: apps.isEmpty ? nil : "in " + LevelThreads.names(Array(apps.prefix(2))),
                                                   clauseKey: t.key, score: s, moments: ids))
                        source(t.key, lead: lead, name: about, colon: true, ids: ids, sendCount: 0, askCount: 0)
                    }
                }
                items.sort { ($0.score, $1.id) > ($1.score, $0.id) }
            }
            guard !items.isEmpty else { continue }
            // claude/today-rank-1005: the thread's category for the card's order (a person's by the channel they were met in).
            let channel = g.members.first.map { $0.key.hasPrefix("chat:teams") ? "teams" : $0.kind }
            let category = DayReview.category(kind: g.kind, key: key, channel: channel, name: g.name)
            out.append(DayReviewThread(key: key, name: g.name, kind: g.kind, seconds: seconds, words: words, personSends: personSends.count, asks: asks.count,
                                       sendHours: hours, stakes: Array(Set(stakes)).sorted { $0.rawValue < $1.rawValue }, score: score, items: items, moments: momentIDs,
                                       category: category.rawValue))
        }
        out.sort { ($0.score, $1.key) > ($1.score, $0.key) }
        return (DayReviewFacts(day: day, threads: out, clauses: [:], activeSeconds: activeSeconds, personSends: personSendsDay), sources)
    }

    /// Words that name a kind of work, an app or a place, never a project.
    static let reviewGeneric: Set<String> = Set("""
code coding app apps design designs test tests testing build builds error errors issue issues page pages docs website site sites github terminal \
ghostty xcode chrome safari google claude chatgpt codex cursor review reviews main branch master folder file files window session sessions fixing \
fixed writing project projects repo repos source sources pull request requests commit commits merge diff tool tools chat chats editor notes mail \
youtube reddit twitter slack zoom figma notion untitled shell bash zsh users user home desktop downloads documents library help settings
""".split(whereSeparator: \.isWhitespace).map(String.init))

    /// A project's name as written: a known spelling ("DayDream"), else the spelling with the most capitals in the day's
    /// labels, its first letter raised.
    static func projectName(_ token: String, in labels: [String]) -> String {
        if let known = ThreadEntities.knownCasing[token] { return known }
        var best: String?
        for label in labels {
            for w in label.components(separatedBy: CharacterSet.alphanumerics.inverted) where w.lowercased() == token {
                if best == nil || w.filter(\.isUppercase).count > best!.filter(\.isUppercase).count { best = w }
            }
        }
        return ThreadEntities.capitalized(best ?? token)
    }
    /// A planner thread's name for a bullet, never a raw window title.
    static func reviewDisplay(_ t: LevelThread) -> String {
        if conversationKinds.contains(t.kind), !t.people.isEmpty { return LevelThreads.channelLabel(t.kind, people: t.people, places: t.places) }
        return TitleClean.label(ThreadEntities.capitalized(t.label))
    }
    /// What a piece of work is named by when it isn't part of a project: a code thread without its " code".
    static func workName(_ t: LevelThread, label: String) -> String {
        label.hasSuffix(" code") ? String(label.dropLast(5)) : label
    }
    static func siteName(_ label: String, key: String) -> String {
        var host = ""
        for p in ["site:", "page:", "video:", "social:"] where key.hasPrefix(p) { host = String(key.dropFirst(p.count).split(separator: "|").first ?? "") }
        if let known = ThreadEntities.friendlyHosts[host] { return known }
        if key.hasPrefix("social:") { return host == "x" ? "X" : ThreadEntities.capitalized(host) }
        if !host.isEmpty { return host }
        return label
    }

    /// Videos watched, pages read, searches: one item per title, the most watched or read first.
    func pageItems(_ kind: String, key: String, members: [LevelThread], momentIDs: [String], byMoment: [String: ActivityNote],
                   actions: [String: CanonicalAction], plan: ThreadPlan) throws -> [DayReviewItem] {
        var titles = [String: (seconds: Double, last: String, action: String, moments: [String], site: String)]()
        for mid in momentIDs {
            for id in byMoment[mid]?.actionIDs ?? [] {
                guard let a = actions[id], !a.site.isEmpty, a.kind != "keyboard.text_input" else { continue }
                let host = ThreadEntities.host(a.site)
                var t = TitleClean.clean(a.title, app: a.app, site: a.site)
                for suffix in [" - YouTube", " | Netflix", " - Twitch", " on Vimeo", " - Google Search", " - Bing", " at DuckDuckGo", " - Search"] where t.hasSuffix(suffix) {
                    t = String(t.dropLast(suffix.count))
                }
                t = t.trimmingCharacters(in: .whitespaces)
                let lower = t.lowercased()
                guard !t.isEmpty, lower != host, ThreadEntities.friendlyHosts[host]?.lowercased() != lower,
                      !["youtube", "home", "netflix", "twitch", "subscriptions", "google", "new tab", "untitled"].contains(lower) else { continue }
                var x = titles[t] ?? (0, a.at, id, [], host)
                x.seconds += plan.dwell[id] ?? 0
                if a.at >= x.last { x.last = a.at; x.action = id }
                if !x.moments.contains(mid) { x.moments.append(mid) }
                titles[t] = x
            }
        }
        let site = Self.siteName(members.first?.label ?? "", key: key)
        let ranked = titles.sorted { kind == "search" ? ($0.value.last, $1.key) > ($1.value.last, $0.key) : ($0.value.seconds, $1.key) > ($1.value.seconds, $0.key) }
        var items = [DayReviewItem]()
        for (title, x) in ranked.prefix(4) {
            let siteName = ThreadEntities.friendlyHosts[x.site] ?? (site.isEmpty ? x.site : site)
            switch kind {
            case "search":
                // A search's words come from its window title; a query with anything a scrubber would hold back isn't shown.
                guard case .keep(_, let redactions) = TypedSecretScrubber.scrub(title), redactions.isEmpty else { continue }
                items.append(DayReviewItem(id: key + "|" + title, lead: "Searched", tail: siteName, inlineQuote: title, score: x.seconds / 60, moments: x.moments))
            case "video":
                let url = try reviewLinks([x.action])[x.action]
                items.append(DayReviewItem(id: key + "|" + title, lead: "Watched", link: DayReviewLink(title: "\u{201C}" + title + "\u{201D}", url: url),
                                           tail: "on " + siteName, score: x.seconds / 60, moments: x.moments))
            default:
                let url = try reviewLinks([x.action])[x.action]
                items.append(DayReviewItem(id: key + "|" + title, lead: "Read", link: DayReviewLink(title: title, url: url), tail: "on " + siteName,
                                           score: x.seconds / 60, moments: x.moments))
            }
        }
        if items.isEmpty {
            let lead = kind == "video" ? "Watched" : kind == "search" ? "Searched" : "Read"
            items.append(DayReviewItem(id: key + "#site", lead: lead, tail: site, score: 0, moments: momentIDs))
        }
        return items
    }

    /// The link a bullet opens: the action's stored page link (`Evidence.page`, on the row's own site), else its site.
    /// Never a link that could change something (send, delete, log out...), nor a blocked website.
    func reviewLinks(_ ids: [String]) throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let settings = try policy()
        var out = [String: String]()
        for row in try rows("SELECT id,coalesce(json_extract(body,'$.page'),''),coalesce(json_extract(body,'$.url'),'') FROM records WHERE id IN (SELECT value FROM json_each(?))", [json(ids)]) {
            let origin = row[2], site = URLComponents(string: origin)?.host?.lowercased()
            let page = row[1].isEmpty ? nil : BrowserSites.pageLink(row[1]).flatMap { URLComponents(string: $0)?.host?.lowercased() == site && site != nil ? $0 : nil }
            let target = page ?? origin
            guard let url = URLComponents(string: target), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil,
                  url.path.range(of: "(?i)(^|/)(send|delete|remove|logout|approve|publish|invite|unsubscribe)(/|$)", options: .regularExpression) == nil,
                  target != origin || !Privacy.secret(target), !PreCapturePrivacy.websiteDenied(target, settings: settings) else { continue }
            out[row[0]] = target
        }
        return out
    }
    /// A thread's link: its most recent page row's.
    func reviewLink(forThread ids: [String], byMoment: [String: ActivityNote], actions: [String: CanonicalAction]) throws -> String? {
        let pages = ids.flatMap { byMoment[$0]?.actionIDs ?? [] }.compactMap { actions[$0] }.filter { !$0.site.isEmpty && $0.kind != "keyboard.text_input" }
        guard let last = pages.max(by: { ($0.at, $0.id) < ($1.at, $1.id) }) else { return nil }
        return try reviewLinks([last.id])[last.id]
    }
    /// A reply's link: the post it answered (its own row's page, else the last page row before it in its moments).
    func reviewLink(near s: ReviewTyped, moments: [String], byMoment: [String: ActivityNote], actions: [String: CanonicalAction]) throws -> String? {
        if let own = try reviewLinks([s.id])[s.id], URLComponents(string: own)?.path.count ?? 0 > 1 { return own }
        let before = moments.flatMap { byMoment[$0]?.actionIDs ?? [] }.compactMap { actions[$0] }
            .filter { !$0.site.isEmpty && $0.kind != "keyboard.text_input" && (timestamp($0.at) ?? .distantFuture) <= s.at }
        guard let last = before.max(by: { ($0.at, $0.id) < ($1.at, $1.id) }) else { return try reviewLinks([s.id])[s.id] }
        return try reviewLinks([last.id])[last.id] ?? reviewLinks([s.id])[s.id]
    }

    /// A first text to someone: no typed row to them, and no Messages window titled with their name, before the day
    /// (the last 60 days). Kept per store, day and name: a day's read asks again only for a name it hasn't seen.
    func firstContact(_ name: String, before: Date, day: String) throws -> Bool {
        let key = home.standardizedFileURL.path + "|" + day + "|" + name.lowercased()
        Self.firstContactLock.lock()
        if let known = Self.firstContactMemo[key] { Self.firstContactLock.unlock(); return known }
        Self.firstContactLock.unlock()
        let lower = name.lowercased()
        var seen = false
        if try hasTypedTables() {
            seen = try !rows("SELECT 1 FROM typed_text t JOIN records r ON r.id=t.id WHERE json_extract(r.body,'$.at')<? AND lower(coalesce(json_extract(r.body,'$.captureProvenance.unit.to'),''))=? LIMIT 1",
                             [iso(before), lower]).isEmpty
        }
        if !seen {
            seen = try !rows("SELECT 1 FROM records WHERE json_extract(body,'$.at')>=? AND json_extract(body,'$.at')<? AND lower(coalesce(json_extract(body,'$.title'),''))=? AND lower(coalesce(json_extract(body,'$.bundle'),''))='com.apple.mobilesms' LIMIT 1",
                             [iso(before.addingTimeInterval(-60 * 86400)), iso(before), lower]).isEmpty
        }
        Self.firstContactLock.lock()
        if Self.firstContactMemo.count > 512 { Self.firstContactMemo.removeAll() }
        Self.firstContactMemo[key] = !seen
        Self.firstContactLock.unlock()
        return !seen
    }
    private static let firstContactLock = NSLock()
    nonisolated(unsafe) private static var firstContactMemo = [String: Bool]()

    // MARK: work for the writer

    /// The clauses due now, most important first: today's shown threads whose clause is missing, from an earlier
    /// writer, or stale after a material change (a new send, about ten more prompts, a new noted moment) and at least
    /// `DayReview.clauseEvery` old; from `DayReview.finalHour`, and for yesterday, a stale clause is due at once (the final
    /// pass). Nothing before the day is warm (`DayReviewFacts.warm`), and only threads with notes to write from.
    /// `skipping`: "key|signature" of requests the writer couldn't save lately. Read only.
    /// Perf pass 10/03: a look that found nothing due is remembered (`DayReviewCache.idle`) until the history changes
    /// (`reviewWorkStamp`), the skipped set changes, or the first time a waiting clause could fall due; the writer's
    /// passes in between cost a few small queries, never a day read.
    public func reviewClauseWork(timezone: String, now: Date = Date(), skipping: Set<String> = [], limit: Int = 4) throws -> [DayReviewClauseRequest] {
        guard try hasReviewClauses(), try hasActionLayers() else { return [] }
        var zone = Calendar(identifier: .gregorian); zone.timeZone = TimeZone(identifier: timezone) ?? .current
        let today = try DayScope.key(now, timezone: timezone)
        let idleKey = try reviewWorkStamp(timezone: timezone, today: today, skipping: skipping)
        if DayReviewCache.shared.idle(idleKey, now: now) { return [] }
        let yesterday = try zone.date(byAdding: .day, value: -1, to: now).map { try DayScope.key($0, timezone: timezone) }
        var out = [DayReviewClauseRequest]()
        // The earliest a clause passed over now could fall due without any change: its 15 minutes, the final pass, the hour.
        var recheck = now.addingTimeInterval(DayReview.idleRecheck)
        if let final = zone.date(bySettingHour: DayReview.finalHour, minute: 0, second: 0, of: now), final > now { recheck = min(recheck, final) }
        for day in [today] + (yesterday.map { [$0] } ?? []) {
            let assembled = try assembleDay(day: day, timezone: timezone, limit: 1, now: now, notes: true)
            guard !assembled.day.partial, let built = try cachedReviewBuild(assembled, plan: nil, day: day, timezone: timezone, now: now), built.facts.warm else { continue }
            let stored = try reviewClauses(day: day)
            let final = day != today || zone.component(.hour, from: now) >= DayReview.finalHour
            // claude/today-rank-1005: clauses for the items the card shows, in its order (no quotes opened here).
            let threads = Dictionary(built.facts.threads.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            let shown = DayReview.assemble(built.facts, quotes: [:]).flatMap(\.bullets).compactMap { b in threads[b.thread]?.items.first { $0.id == b.id } }
            do {
                for item in shown {
                    guard let key = item.clauseKey, let src = built.sources[key], !src.notes.isEmpty, !src.actionIDs.isEmpty,
                          !skipping.contains(key + "|" + src.signature) else { continue }
                    if let s = stored[key], s.generator == DayReviewClauses.version {
                        if s.signature == src.signature { continue }
                        if !final, let at = timestamp(s.writtenAt), now.timeIntervalSince(at) < DayReview.clauseEvery {
                            recheck = min(recheck, at.addingTimeInterval(DayReview.clauseEvery))
                            continue
                        }
                    }
                    out.append(DayReviewClauseRequest(day: day, timezone: timezone, key: key, lead: src.lead, name: src.name, colon: src.colon, notes: src.notes,
                                                      signature: src.signature, actionIDs: src.actionIDs, start: src.start, end: src.end))
                    if out.count >= limit { return out }
                }
            }
        }
        if out.isEmpty { DayReviewCache.shared.setIdle(idleKey, until: recheck) }
        return out
    }
    /// What a "nothing due" answer depends on, from a few indexed lookups: the newest record, note and tombstone, the
    /// clauses, the privacy settings, this process's drop count, the day, the time zone and the skipped requests.
    func reviewWorkStamp(timezone: String, today: String, skipping: Set<String>) throws -> String {
        func one(_ sql: String) throws -> String { try rows(sql).first?.joined(separator: ",") ?? "" }
        var h = Hasher()
        h.combine(try one("SELECT coalesce(max(rowid),0) FROM records"))
        h.combine(try one("SELECT coalesce(max(rowid),0) FROM tombstones"))
        h.combine(try one("SELECT coalesce(max(rowid),0),count(*) FROM generated_notes"))
        h.combine(try one("SELECT coalesce(max(rowid),0),count(*) FROM review_clauses"))
        h.combine(try one("SELECT body FROM metadata WHERE id='policy'"))
        h.combine(skipping.sorted())
        return home.standardizedFileURL.path + "|" + timezone + "|" + today + "|\(DayReviewCache.epoch)|\(h.finalize())"
    }

    // MARK: quotes (the DayDream app only)

    /// The quoted rows' words, on this Mac only: opened with the owner disclosure (`hydrateTypedText`: typing on, a ready
    /// key in this process, the record still shown and kept), whitespace folded to single spaces, and only when the secret scrubber
    /// would keep every word. Empty in a process without a ready key (every MCP and CLI process). Writes nothing.
    public func ownerReviewQuotes(_ ids: [String], now: Date = Date()) throws -> [String: String] {
        guard !ids.isEmpty, typedVaultState == .ready, try policy().captureText else { return [:] }
        var out = [String: String]()
        for id in Self.unique(ids) {
            guard let words = try hydrateTypedText(id, disclosure: .owner, now: now),
                  case .keep(_, let redactions) = TypedSecretScrubber.scrub(words), redactions.isEmpty,
                  !words.contains(TypedSecretScrubber.marker) else { continue }
            let line = MomentPromptText.clean(words, limit: Self.quoteLimit)
            if !line.isEmpty { out[id] = line }
        }
        return out
    }
    /// The most characters a quote keeps (cut at the limit with "…"). The card shows one line of it first
    /// (`DayReview.oneLine`) and all of it when the bullet is clicked.
    public static let quoteLimit = 1200
}


/// Perf pass 10/03: this process's review facts per history, day and time zone, and its "nothing due" looks. Values only
/// (names, titles, counts, ids): never a typed word.
final class DayReviewCache: @unchecked Sendable {
    static let shared = DayReviewCache()
    typealias Built = (facts: DayReviewFacts, sources: [String: DayReviewSource])
    private let lock = NSLock()
    private var builds = [String: (print: Int, built: Built?, used: Int)]()
    private var idleUntil = [String: Date]()
    private var uses = 0
    /// Days kept (today, yesterday and a few days looked at).
    static let capacity = 8
    /// Bumped by a Forget, a delete, retention or "Forget what I typed" in this process.
    private static let epochLock = NSLock()
    nonisolated(unsafe) private static var epochValue = 0
    static var epoch: Int { epochLock.lock(); defer { epochLock.unlock() }; return epochValue }
    static func bump() { epochLock.lock(); epochValue += 1; epochLock.unlock() }

    static func key(home: URL, day: String, timezone: String) -> String { home.standardizedFileURL.path + "|" + day + "|" + timezone }
    func get(_ key: String, print: Int) -> Built?? {
        lock.lock(); defer { lock.unlock() }
        guard let e = builds[key], e.print == print else { return nil }
        uses += 1; builds[key]?.used = uses
        return .some(e.built)
    }
    func any(_ key: String) -> Built? {
        lock.lock(); defer { lock.unlock() }
        return builds[key]?.built
    }
    func put(_ key: String, print: Int, built: Built?) {
        lock.lock(); defer { lock.unlock() }
        uses += 1
        builds[key] = (print, built, uses)
        while builds.count > Self.capacity, let oldest = builds.min(by: { $0.value.used < $1.value.used })?.key { builds[oldest] = nil }
    }
    func idle(_ key: String, now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let until = idleUntil[key] else { return false }
        if now < until { return true }
        idleUntil[key] = nil
        return false
    }
    func setIdle(_ key: String, until: Date) {
        lock.lock(); defer { lock.unlock() }
        if idleUntil.count > 32 { idleUntil.removeAll() }
        idleUntil[key] = until
    }
}
