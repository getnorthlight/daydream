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
    /// claude/dayeval-1005: the thread's typed AI prompts and document words (ids only, never words), which only the writer
    /// on this Mac opens when it writes the clause (`reviewTypedFacts`).
    var typedIDs: [String] = []
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
    @discardableResult public func commitReviewClause(_ r: DayReviewClauseRequest, text: String, generator: String = DayReviewClauses.activeVersion, now: Date = Date()) throws -> DayReviewClause {
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
        // claude/dayeval-1005: the measured changes (DayReviewOptions); [] is today-rank-1005's card.
        let opts = DayReview.options
        let selfWords: Set<String> = opts.contains(.projects) ? Self.reviewSelfWords : []
        // A thread's main app (the one most of its actions are in).
        func mainApp(_ ids: [String]) -> String {
            var n = [String: Int]()
            for m in ids { for a in byMoment[m]?.actionIDs ?? [] { if let app = assembled.actions[a]?.app, !app.isEmpty { n[app, default: 0] += 1 } } }
            return n.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? ""
        }

        // Projects: a name shared by two or more pieces of work ("daydream" in a Claude Code session's title, a GitHub repo
        // and a terminal folder) makes them one thread; each piece goes with its heaviest shared name.
        let peopleWords = Set(threads.flatMap { $0.people.flatMap(ThreadEntities.tokens) })
        func projectWords(_ t: LevelThread) -> Set<String> {
            guard workKinds.contains(t.kind) else { return [] }
            var text = t.label
            for m in t.momentIDs { if let e = plan.momentEntity[m] { text += " " + (e.project ?? "") + " " + e.label } }
            return Set(ThreadEntities.tokens(text).filter { $0.count >= 4 && Int($0) == nil && !ThreadEntities.stopWords.contains($0)
                && !ThreadEntities.commonWords.contains($0) && !Self.reviewGeneric.contains($0) && !peopleWords.contains($0) && !selfWords.contains($0) })
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
        // claude/dayeval-1005: a folder's own spelling for its name ("atlas-api", never "Atlasapi").
        var projectSpelling = [String: String]()
        for t in threads where projectOf[t.key] == nil && workKinds.contains(t.kind) {
            var named = [String: Int]()
            for m in t.momentIDs { if let p = plan.momentEntity[m]?.project, !p.isEmpty { named[p, default: 0] += 1 } }
            guard let best = named.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key else { continue }
            let tok = ThreadEntities.tokens(best).joined()
            if !tok.isEmpty, !Self.reviewGeneric.contains(tok), !peopleWords.contains(tok), !selfWords.contains(tok) {
                projectOf[t.key] = tok
                if best.contains("-") || best.contains("_") || best.contains(".") { projectSpelling[tok] = best }
            }
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
                add("project:" + tok, projectSpelling[tok].map { ThreadEntities.projectName($0) } ?? Self.projectName(tok, in: labels), "project", t)
            } else if personKinds.contains(t.kind), let who = (t.people.first ?? (t.kind == "slack" ? t.places.first : nil)), !t.key.hasPrefix("texts:?") {
                let name = who.hasPrefix("#") ? who : ThreadEntities.capitalized(who)
                add("person:" + ThreadEntities.norm(who), name, "person", t)
            } else if opts.contains(.workSites), t.kind == "web", let host = Self.pageHost(t.key), !host.isEmpty,
                      DayReview.category(kind: "web", key: t.key, channel: nil, options: opts) == .work {
                // claude/dayeval-1005: a work site's pages are one thread ("lakeviewlearn.com: Unit 2 Reader and Unit 2 Quiz").
                add("site:" + host, ThreadEntities.friendlyHosts[host] ?? Self.siteLabel(host), "site", t)
            } else if opts.contains(.projects), Self.toolThread(t, app: mainApp(t.momentIDs), selfWords: selfWords) {
                // claude/dayeval-1005: a terminal in the home folder, a remote screen, a camera: the app, not a piece of work.
                let app = mainApp(t.momentIDs)
                add("app:" + app.lowercased(), app, "app", t)
            } else {
                add(t.key, Self.reviewDisplay(t), t.kind, t)
            }
        }

        // claude/dayeval-1005: results the records show (a confirmation page, a note's own "Submitted …"), by group.
        var groupOfMoment = [String: String]()
        for key in order { for t in groups[key]?.members ?? [] { for m in t.momentIDs where groupOfMoment[m] == nil { groupOfMoment[m] = key } } }
        let outcomes = opts.contains(.outcomes) ? Self.reviewOutcomes(moments: active, actions: assembled.actions, groupOf: groupOfMoment) : [:]

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
                // claude/dayeval-1005 (owner 10/05: the day card is the only written summary): with `factPacket` the clause is
                // written from facts code read from the records, never from moment notes.
                let packet = opts.contains(.factPacket)
                let n = packet ? Self.reviewPacket(ids, byMoment: byMoment, actions: assembled.actions, plan: plan, typed: typed) : notes(ids)
                let typedIDs = packet && opts.contains(.typedFacts) ? Self.reviewTypedIDs(ids, byMoment: byMoment, typed: typed) : []
                // No title that says more than the thread's own name and nothing typed: nothing for the model to add, so no
                // call (code's line stands).
                if packet, typedIDs.isEmpty {
                    let named = Set(ThreadEntities.tokens(name + " " + lead))
                    let said = n.filter { $0.hasPrefix("titles:") }.flatMap { ThreadEntities.tokens(String($0.dropFirst(7))) }
                    if !said.contains(where: { $0.count >= 3 && !named.contains($0) && !ThreadEntities.stopWords.contains($0) }) { return }
                }
                // With a packet, a material change is a change in what the titles say or in what was typed (a stable hash).
                let noted = packet ? Self.stableHash((n.filter { $0.hasPrefix("titles:") } + typedIDs).joined(separator: "|")) % 1_000_000 : ids.compactMap { byMoment[$0] }.filter { ($0.generated ?? $0.previous) != nil }.count
                let (s, e) = span(ids)
                sources[clauseKey] = DayReviewSource(lead: lead, name: name, colon: colon, notes: n, signature: "s\(sendCount)|p\(askCount / 10)|m\(noted)",
                                                     actionIDs: ids.flatMap { byMoment[$0]?.actionIDs ?? [] }, start: s, end: e, typedIDs: typedIDs)
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
                if items.isEmpty { items.append(DayReviewItem(id: key + "#read", lead: "Read", tail: "posts on " + site, score: score, moments: momentIDs, filler: true)) }
            case "video", "web", "search":
                items += try pageItems(g.kind, key: key, members: g.members, momentIDs: momentIDs, byMoment: byMoment, actions: assembled.actions, plan: plan)
            case "site":
                // The site's pages, most time first: "Worked on Canvas: Homework 4 and Quiz 3".
                let host = String(key.dropFirst(5))
                let pages = g.members.sorted { ($0.seconds, $1.key) > ($1.seconds, $0.key) }
                    .map { Self.sitePage(Self.reviewDisplay($0)) }
                    .filter { !$0.isEmpty && $0.count <= 40 && $0.lowercased() != g.name.lowercased() && !$0.lowercased().contains(host) && !$0.contains(".") }
                    .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                if opts.contains(.workSites) {
                    // claude/dayeval-1005 (owner 10/04): plain words. The site by its name; pages that only name the app
                    // ("Lesson Viewer") are left out, and coursework says so ("Did coursework on Lakeviewlearn").
                    let name = Self.plainSite(host, titles: pages)
                    let topics = pages.filter { !Self.chromePage($0) }
                    let school = pages.joined(separator: " ").lowercased().split(separator: " ")
                        .contains { ["course", "courses", "assessment", "assignment", "student", "quiz", "homework", "lesson", "exam"].contains(String($0)) }
                    let lead = topics.isEmpty && school ? "Did coursework on " + name : "Worked on " + name
                    items.append(DayReviewItem(id: key, lead: lead, colon: !topics.isEmpty,
                                               tail: topics.isEmpty ? nil : LevelThreads.names(Array(topics.prefix(2))), score: score, moments: momentIDs))
                } else {
                    items.append(DayReviewItem(id: key, lead: "Worked on " + g.name, colon: !pages.isEmpty,
                                               tail: pages.isEmpty ? nil : LevelThreads.names(Array(pages.prefix(2))), score: score, moments: momentIDs))
                }
            default:
                let project = g.kind == "project" ? g.name : nil
                for t in g.members {
                    let ids = t.momentIDs
                    let ownActions = Set(ids.flatMap { byMoment[$0]?.actionIDs ?? [] })
                    let own = rows.filter { ownActions.contains($0.id) }
                    let ownAsks = own.filter { $0.sent && $0.ask }
                    let label = Self.reviewDisplay(t)
                    // claude/dayeval-1005: a project's piece by its own name when it says more ("Tallybird pricing page review").
                    let about = project.map { opts.contains(.projects) ? Self.projectDetail(label, project: $0) : $0 } ?? Self.workName(t, label: label)
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
                        // claude/dayeval-1005: "Claudecode" (a terminal title's tool, run together) names the tool too.
                        let topic = DayReview.topic(about, echoing: [tool, tool.replacingOccurrences(of: " ", with: ""), ask.app, ThreadEntities.friendlyHosts[host] ?? host] + DayReview.askPlaces)
                        items.append(DayReviewItem(id: t.key, lead: "Asked " + tool, tail: topic.map { "about " + (opts.contains(.projects) ? DayReview.lowerLead($0) : $0) },
                                                   clauseKey: t.key, quote: ask.id, score: s, moments: ids))
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
                    switch g.kind == "app" ? "app" : t.kind {
                    case "pr":
                        let url = try reviewLink(forThread: ids, byMoment: byMoment, actions: assembled.actions)
                        items.append(DayReviewItem(id: t.key, lead: "Read", link: DayReviewLink(title: label, url: url), tail: "on GitHub", score: s, moments: ids))
                    case "web":
                        let url = try reviewLink(forThread: ids, byMoment: byMoment, actions: assembled.actions)
                        // claude/dayeval-1005: a topic thread led by an email or a document has no host in its key: its pages' own.
                        // The host of the page the line names comes first: a thread can span a school's page and its tools' pages.
                        let pageActs = ids.flatMap { byMoment[$0]?.actionIDs ?? [] }.compactMap { assembled.actions[$0] }
                        let pageHosts = (pageActs.filter { $0.title.localizedCaseInsensitiveContains(label) } + pageActs).map { ThreadEntities.host($0.site) }.filter { !$0.isEmpty }
                        let keyed = Self.pageHost(t.key) != nil
                        let site = keyed || pageHosts.isEmpty || !opts.contains(.workSites) ? Self.siteName(t.label, key: t.key)
                            : Self.brand(pageHosts[0]) ?? ThreadEntities.friendlyHosts[pageHosts[0]] ?? pageHosts[0]
                        if t.key.hasPrefix("site:") || label == site {
                            // claude/dayeval-1005: coursework or a work tool's site is work, even with no page named.
                            let hosts = Set(ids.flatMap { byMoment[$0]?.actionIDs ?? [] }.compactMap { assembled.actions[$0].map { ThreadEntities.host($0.site) } })
                            let workRead = opts.contains(.workSites) && (DayReview.category(kind: "site", key: t.key, channel: nil, options: opts) == .work
                                || hosts.contains { DayReview.workSite(host: $0, title: label) })
                            items.append(DayReviewItem(id: t.key, lead: "Read", tail: site, score: s, moments: ids, filler: !workRead))
                        } else {
                            // claude/dayeval-1005 (owner 10/04: plain words): a site by its name, left out when the title names it.
                            let place = opts.contains(.workSites) && site.contains(".") ? Self.plainSite(site, titles: [label]) : site
                            let named = opts.contains(.workSites) && label.lowercased().contains(place.lowercased())
                            items.append(DayReviewItem(id: t.key, lead: "Read", link: DayReviewLink(title: label, url: url), tail: named ? nil : "on " + place, score: s, moments: ids))
                        }
                    case "doc":
                        let wrote = own.contains { $0.words > 0 }
                        // claude/dayeval-1005: a document whose words were typed (typed facts, the writer on this Mac) gets a
                        // clause from them: "Wrote notes on the catalase lab"; else code's line stands.
                        let typedDoc = wrote && opts.contains(.factPacket) && opts.contains(.typedFacts)
                            && !Self.reviewTypedIDs(ids, byMoment: byMoment, typed: typed).isEmpty
                        if typedDoc { source(t.key, lead: "Wrote", name: label, colon: false, ids: ids, sendCount: 0, askCount: 0) }
                        if opts.contains(.projects) {
                            // claude/dayeval-1005: an untitled document by what its notes say it is, else "a document in TextEdit";
                            // a project's window titled only with the project's name says nothing more (filler).
                            let blank = DayReview.topic(label.filter { !$0.isNumber }, echoing: apps + ["untitled", "document", "new", "note", "notes"]) == nil
                                || label.range(of: #"^(?i)(untitled|new document|document\d*|new note)( \d+)?$"#, options: .regularExpression) != nil
                            if blank {
                                let named = notes(ids).lazy.map { $0.components(separatedBy: ": ").first ?? $0 }
                                    .first { !Self.recallFiller($0) && DayReview.topic($0, echoing: apps + [label, "untitled"]) != nil }
                                let app = apps.first ?? mainApp(ids)
                                items.append(DayReviewItem(id: t.key, lead: wrote ? "Wrote" : "Read", tail: named ?? ("a document" + (app.isEmpty ? "" : " in " + app)),
                                                           clauseKey: typedDoc ? t.key : nil, score: s, moments: ids, filler: named == nil && !wrote))
                                continue
                            }
                            if let project, DayReview.topic(label, echoing: [project] + apps) == nil {
                                items.append(DayReviewItem(id: t.key, lead: wrote ? "Wrote" : "Read", tail: label, score: s, moments: ids, filler: true))
                                continue
                            }
                        }
                        // claude/dayeval-1005: ten minutes or more in a design, office or code app is work on the file, typed or
                        // not ("Worked on Checkout Redesign in Figma"), never "Read".
                        let maker = apps.first { app in let a = app.lowercased(); return (DayReview.workApps.contains(a) || DayReview.moreWorkApps.contains(a))
                            && !DayReview.readerApps.contains(a) }
                        if opts.contains(.projects), !wrote, t.seconds >= 600, let maker {
                            items.append(DayReviewItem(id: t.key, lead: "Worked on " + label, tail: "in " + maker, score: s, moments: ids))
                            continue
                        }
                        items.append(DayReviewItem(id: t.key, lead: wrote ? "Wrote" : "Read", tail: opts.contains(.projects) ? DayReview.titleAsObject(label) : label,
                                                   clauseKey: typedDoc ? t.key : nil, score: s, moments: ids))
                    case "email" where t.key == "email" && opts.contains(.filler):
                        // claude/dayeval-1005: a mailbox with no subject or person named is "Read email", never "Worked on
                        // Email in Google Chrome"; filler under twenty minutes.
                        let wrote = own.contains { $0.sent || $0.words > 0 }
                        items.append(DayReviewItem(id: t.key, lead: wrote ? "Wrote" : "Read", tail: "email", score: s, moments: ids,
                                                   filler: !wrote && t.seconds < 1200))
                    case "meeting":
                        // claude/dayeval-1005: the meeting by its own name, not the app's ("Zoom Meeting - Design Crit" is "Design Crit").
                        let named = label.replacingOccurrences(of: #"^(?i)(zoom meeting|zoom|google meet|meet|microsoft teams|teams)\s*[-–—:|]\s*"#,
                                                               with: "", options: .regularExpression)
                        items.append(DayReviewItem(id: t.key, lead: "Joined", tail: named.isEmpty ? label : named, score: s, moments: ids))
                    case "app":
                        items.append(DayReviewItem(id: t.key, lead: "Used", tail: g.kind == "app" ? g.name : label, score: s, moments: ids, filler: true))
                    case "texts" where opts.contains(.filler) || opts.contains(.texting),
                         "chat" where (opts.contains(.filler) || opts.contains(.texting)) && DayReview.category(kind: "chat", key: t.key, channel: nil, options: opts) == .personal:
                        // claude/dayeval-1005: a conversation with no one named is the texting line's, never "Worked on Texts".
                        let sent = own.contains { $0.sent && $0.person }
                        items.append(DayReviewItem(id: t.key, lead: sent ? "Texted" : "Read", tail: sent ? "someone" : "texts", score: s, moments: ids, filler: true))
                    default:
                        // Code, an AI chat read, anything worked on: "Worked on DayDream: <clause>", else "… in Xcode".
                        // claude/today-rank-1005: an AI app's own thread read with no ask ("Worked on Claude: in Claude.") is "Used
                        // Claude", the sentence going on after it, as "Asked Claude" does (today-copy-1004's echo rule).
                        if DayReview.topic(about, echoing: apps + DayReview.askPlaces) == nil {
                            let lead = "Used " + about
                            items.append(DayReviewItem(id: t.key, lead: lead, clauseKey: t.key, score: s, moments: ids, filler: true))
                            source(t.key, lead: lead, name: about, colon: false, ids: ids, sendCount: 0, askCount: 0)
                            continue
                        }
                        let lead = "Worked on " + about
                        items.append(DayReviewItem(id: t.key, lead: lead, colon: true, tail: apps.isEmpty ? nil : "in " + LevelThreads.names(Array(apps.prefix(2))),
                                                   clauseKey: t.key, score: s, moments: ids))
                        // claude/dayeval-1005: a project's line stands for the whole project (its other pieces fold into it on the
                        // card), so its facts are the project's.
                        source(t.key, lead: lead, name: about, colon: true, ids: g.kind == "project" && opts.contains(.factPacket) ? momentIDs : ids,
                               sendCount: 0, askCount: 0)
                    }
                }
                items.sort { ($0.score, $1.id) > ($1.score, $0.id) }
            }
            if let o = outcomes[key] {
                // The result leads the thread, and counts like a high-stakes send.
                items.insert(DayReviewItem(id: key + "#outcome", lead: o.verb, tail: o.object, score: score + DayReview.stakesBoost, moments: o.moments), at: 0)
                score += DayReview.stakesBoost
            }
            guard !items.isEmpty else { continue }
            // claude/today-rank-1005: the thread's category for the card's order (a person's by the channel they were met in).
            let channel = g.members.first.map { $0.key.hasPrefix("chat:teams") ? "teams" : $0.kind }
            let category = g.kind == "site" ? DayReview.Category.work : DayReview.category(kind: g.kind, key: key, channel: channel, name: g.name)
            let ends = momentIDs.compactMap { byMoment[$0]?.end }
            out.append(DayReviewThread(key: key, name: g.name, kind: g.kind, seconds: seconds, words: words, personSends: personSends.count, asks: asks.count,
                                       sendHours: hours, stakes: Array(Set(stakes)).sorted { $0.rawValue < $1.rawValue }, score: score, items: items, moments: momentIDs,
                                       category: category.rawValue, person: g.kind == "person" && category == .personal ? DayReview.textingName(g.name) : nil,
                                       lastEnd: ends.max(), dayPart: Self.dayPart(momentIDs.compactMap { byMoment[$0].map { ($0.start, $0.end) } }, timezone: timezone)))
        }
        out.sort { ($0.score, $1.key) > ($1.score, $0.key) }
        var facts = DayReviewFacts(day: day, threads: out, clauses: [:], activeSeconds: activeSeconds, personSends: personSendsDay)
        if opts.contains(.leftOff) { (facts.leftOff, facts.leftOffThread) = Self.reviewLeftOff(out, byMoment: byMoment, actions: assembled.actions, plan: plan, groups: groups.mapValues(\.members)) }
        return (facts, sources)
    }

    // MARK: claude/dayeval-1005

    /// The facts a clause is written from (`DayReviewOptions.factPacket`): the thread's window and page titles, most time
    /// first, as code cleans them (no ids, no paths, no conversation names); its apps and sites; and what was typed, asked
    /// or sent, counted by code. Values only: never a typed word.
    static func reviewPacket(_ ids: [String], byMoment: [String: ActivityNote], actions: [String: CanonicalAction], plan: ThreadPlan,
                             typed: [String: ReviewTyped]) -> [String] {
        var titleTime = [String: Double](), apps = [String](), sites = [String]()
        var asks = 0, sends = 0, drafts = 0, words = 0
        for m in ids {
            for id in byMoment[m]?.actionIDs ?? [] {
                guard let a = actions[id] else { continue }
                if !a.app.isEmpty, !apps.contains(a.app) { apps.append(a.app) }
                let host = ThreadEntities.host(a.site)
                if !host.isEmpty { let n = ThreadEntities.friendlyHosts[host] ?? host; if !sites.contains(n) { sites.append(n) } }
                if let t = typed[id] {
                    words += t.words
                    if t.sent && t.ask { asks += 1 } else if t.sent && t.person { sends += 1 } else if !t.sent { drafts += 1 }
                    continue
                }
                guard !MessagesMomentIdentity.applies(a) else { continue }
                var title = withoutIDs(TitleClean.clean(a.title, app: a.app, site: a.site))
                // claude/dayeval-1005: a path in a title gives way to the rest of it ("~/daydream — swift build" is "swift build").
                if title.contains("/") || title.contains("~") {
                    title = ThreadEntities.segments(title).filter { !$0.contains("/") && !$0.contains("~") }.joined(separator: " - ")
                }
                for sep in [" — ", " - ", " | ", " · "] where title.components(separatedBy: sep).count > 2 { title = title.components(separatedBy: sep).prefix(2).joined(separator: sep) }
                let lower = title.lowercased()
                guard title.count >= 3, title.count <= 80, !title.contains("/"), !title.contains("~"), !Privacy.secret(title),
                      lower != a.app.lowercased(), lower != host, !["new tab", "untitled", "home", "inbox"].contains(lower) else { continue }
                titleTime[title, default: 0] += max(plan.dwell[id] ?? 0, 1)
            }
        }
        let titles = titleTime.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(6).map(\.key)
        var out = [String]()
        if !titles.isEmpty { out.append("titles: " + titles.joined(separator: "; ")) }
        if !apps.isEmpty { out.append("apps: " + apps.prefix(4).joined(separator: ", ")) }
        if !sites.isEmpty { out.append("sites: " + sites.prefix(4).joined(separator: ", ")) }
        var did = [String]()
        if asks > 0 { did.append("asked an AI app \(asks) times") }
        if sends > 0 { did.append("sent \(sends) messages") }
        // Owner 10/04: whether something typed was sent isn't known well enough to say ("draft" was usually wrong).
        _ = drafts
        if words > 0 { did.append("typed about \(words) words") }
        out.append("typed or sent: " + (did.isEmpty ? "nothing" : did.joined(separator: ", ")))
        return out
    }

    /// claude/dayeval-1005: a site page's short name: "lab2.pdf: CHEM 101 10,12 (Fall 2026) Intro Chemistry" is
    /// "CHEM 101 Intro Chemistry" (a file name before a colon gives way, parentheses and section lists go).
    static func sitePage(_ display: String) -> String {
        let parts = display.components(separatedBy: ": ").map { $0.trimmingCharacters(in: .whitespaces) }
        var p = parts.first ?? ""
        if parts.count > 1, p.range(of: #"\.[A-Za-z0-9]{2,4}$"#, options: .regularExpression) != nil { p = parts[1] }
        p = p.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        p = p.split(separator: " ").filter { w in !(w.contains(",") && w.allSatisfy { $0.isNumber || $0 == "," }) }.joined(separator: " ")
        return p.trimmingCharacters(in: .whitespaces)
    }
    /// A page thread's host ("page:canvas.lakeview.edu|…", "topic:page:…").
    static func pageHost(_ key: String) -> String? {
        let k = key.hasPrefix("topic:") ? String(key.dropFirst(6)) : key
        for p in ["page:", "site:"] where k.hasPrefix(p) { return String(k.dropFirst(p.count).split(separator: "|").first ?? "").lowercased() }
        return nil
    }
    /// A host as a name: "canvas.lakeview.edu" -> "Canvas", "lakeviewlearn.com" stays.
    /// claude/dayeval-1005: a work tool's hosts by the tool's name ("acme.lightning.force.com" is Salesforce).
    static let brandHosts: [(String, String)] = [("force.com", "Salesforce"), ("salesforce.com", "Salesforce"), ("atlassian.net", "Jira"),
        ("sharepoint.com", "SharePoint"), ("hubspot.com", "HubSpot"), ("zendesk.com", "Zendesk"), ("linear.app", "Linear"), ("figma.com", "Figma"),
        ("notion.so", "Notion"), ("docs.google.com", "Google Docs"), ("sheets.google.com", "Google Sheets"), ("slides.google.com", "Google Slides"),
        ("instructure.com", "Canvas"), ("gradescope.com", "Gradescope"), ("quizlet.com", "Quizlet"), ("overleaf.com", "Overleaf")]
    static func brand(_ host: String) -> String? {
        var h = host.lowercased(); if h.hasPrefix("www.") { h.removeFirst(4) }
        return brandHosts.first { h == $0.0 || h.hasSuffix("." + $0.0) }?.1
    }
    /// claude/dayeval-1005 (owner 10/04: "plain words"): a site by its name, never its host: a known tool's name, else the
    /// host's own name ("en.wikipedia.org" is "Wikipedia", "lakeviewlearn.com" "Lakeviewlearn"), spelled as the site's pages spell it
    /// ("courses.northlake.edu" is "NorthLake" when a page says "NorthLake").
    public static func plainSite(_ host: String, titles: [String] = []) -> String {
        var h = host.lowercased(); if h.hasPrefix("www.") { h.removeFirst(4) }
        if let b = brand(h) ?? ThreadEntities.friendlyHosts[h] { return b }
        let tool = siteLabel(h)
        if tool != h { return tool }
        var labels = h.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return host }
        labels.removeLast()
        if ["co", "ac", "com", "org", "edu", "gov", "net"].contains(labels.last ?? ""), labels.count >= 2 { labels.removeLast() }
        let name = labels.last ?? h
        guard name.count >= 3, name.allSatisfy({ $0.isLetter || $0 == "-" }) else { return host }
        for t in titles {
            for w in t.split(whereSeparator: { !$0.isLetter && $0 != "-" }) where w.lowercased() == name { return String(w) }
        }
        return ThreadEntities.capitalized(name)
    }
    /// A page named by the app it is ("Lesson Viewer", "Student Portal", "Register"): never a topic.
    public static func chromePage(_ page: String) -> Bool {
        let words = page.lowercased().split(separator: " ").map(String.init)
        let chrome: Set<String> = ["player", "library", "register", "login", "log", "sign", "home", "dashboard", "portal", "settings", "account",
                                   "profile", "instruction", "instructions", "viewer", "launcher", "loading", "welcome", "overview"]
        return words.count <= 4 && words.contains { chrome.contains($0) }
    }
    static func siteLabel(_ host: String) -> String {
        if let b = brand(host) { return b }
        var h = host; if h.hasPrefix("www.") { h.removeFirst(4) }
        let first = h.split(separator: ".").first.map(String.init) ?? h
        return DayReview.workHostWords.contains(first) || (h.split(separator: ".").count == 2 && DayReview.workHostWords.contains { $0.count >= 5 && first == $0 })
            ? ThreadEntities.capitalized(first) : h
    }
    /// claude/dayeval-1005: the part of the day holding 60% or more of these spans' time ("morning" 5-12, "afternoon"
    /// 12-17, "evening" 17-22, "night"), nil when none does.
    public static func dayPart(_ spans: [(String, String)], timezone: String) -> String? {
        let c = calendar(timezone)
        var by = [String: Double](), total = 0.0
        for (a, b) in spans {
            guard let s = timestamp(a), let e = timestamp(b), e > s else { continue }
            var t = s
            while t < e {
                let next = min(e, t.addingTimeInterval(300))
                let h = c.component(.hour, from: t)
                let part = h >= 5 && h < 12 ? "morning" : h >= 12 && h < 17 ? "afternoon" : h >= 17 && h < 22 ? "evening" : "night"
                by[part, default: 0] += next.timeIntervalSince(t); total += next.timeIntervalSince(t); t = next
            }
        }
        guard total > 0, let best = by.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), best.value >= total * 0.6 else { return nil }
        return best.key
    }
    /// A window title without the ids test tools and files carry ("QA Mini-eb5cd00d-bb5b-…-B" -> "QA Mini").
    static func withoutIDs(_ label: String) -> String {
        var s = label.replacingOccurrences(of: #"[-_ ]?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F\[\]a-z]{6,}(-[A-Z])?"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\b[0-9a-f]{12,}\b"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-_·|")))
    }

    /// The person's own account and name: their home folder is never a project ("~" in Terminal is "jamielin").
    static let reviewSelfWords: Set<String> = Set(ThreadEntities.tokens(NSUserName() + " " + NSFullUserName()).filter { $0.count >= 3 })
    /// A thread that is the app it was in, not a piece of work: a terminal in the home folder, a remote screen, a camera.
    static func toolThread(_ t: LevelThread, app: String, selfWords: Set<String>) -> Bool {
        if DayReview.toolApps.contains(app.lowercased()) && ["doc", "app", "web"].contains(t.kind) { return true }
        if t.kind == "code" {
            let words = Set(ThreadEntities.tokens(workName(t, label: t.label)))
            return !words.isEmpty && words.isSubset(of: selfWords)
        }
        return false
    }
    /// A project's piece by its own name when it names more than the project ("tallybird pricing page review" ->
    /// "Tallybird pricing page review"); the project's name when it says nothing more or is too long.
    static func projectDetail(_ label: String, project: String) -> String {
        let projectTokens = Set(ThreadEntities.tokens(project))
        let base = label.hasSuffix(" code") ? String(label.dropLast(5)) : label
        let extra = ThreadEntities.tokens(base).filter { !projectTokens.contains($0) && !ThreadEntities.stopWords.contains($0) && $0.count >= 3 && Int($0) == nil }
        // claude/dayeval-1005: only a name that has the project's own in it ("Tallybird pricing page review"); a pull request or
        // a ticket title alone loses which project it was ("Worked on PR #77: …" for atlas-api).
        let baseTokens = Set(ThreadEntities.tokens(base).flatMap { [$0, $0.replacingOccurrences(of: "-", with: "")] })
        guard !extra.isEmpty, !projectTokens.isDisjoint(with: baseTokens) || projectTokens.contains(where: { p in baseTokens.contains { $0.replacingOccurrences(of: "-", with: "") == p } }), base.count <= 48, !base.contains("/"), !base.contains("~"), !base.contains("—") else { return project }
        // The project's own spelling inside the piece's name.
        var words = base.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        for (i, w) in words.enumerated() where ThreadEntities.tokens(w) == Array(projectTokens) && projectTokens.count == 1 { words[i] = project }
        return words.joined(separator: " ")
    }

    /// Results a window's own title shows (a confirmation page) or a note's own line states, first by the records.
    static let outcomePatterns: [(String, String)] = [
        ("Submitted", #"(?i)\b(submission (successful|received|complete|confirmed)|successfully submitted|submitted successfully|(application|assignment|form|response|quiz|exam|homework|answers?) (has been |was )?(submitted|received)|thank you for (your )?(submission|submitting|applying)|your response has been recorded)\b"#),
        ("Signed", #"(?i)\b((signing|document|envelope) (is )?(complete|completed)|you('ve| have) (finished|completed) signing|signed successfully|all parties have signed)\b"#),
        ("Ordered", #"(?i)\b(order (confirmed|placed|confirmation|received)|thank you for your (order|purchase))\b"#),
        ("Paid", #"(?i)\b(payment (successful|received|complete|completed|confirmed)|paid successfully|receipt for your payment)\b"#),
        ("Booked", #"(?i)\b((booking|reservation|appointment) (is )?confirmed|you('re| are) booked)\b"#),
        ("Registered", #"(?i)\b(registration (complete|confirmed|successful)|you('re| are) registered)\b"#),
        ("Deployed", #"(?i)\b((deployment|deploy) (succeeded|successful|complete)|published successfully|your (site|app) is live)\b"#),
    ]
    static let outcomeVerbs: Set<String> = ["Submitted", "Signed", "Ordered", "Paid", "Booked", "Registered", "Deployed", "Published", "Merged",
                                            "Shipped", "Fixed", "Sent", "Released", "Finished", "Completed", "Applied", "Filed"]
    static func outcomeVerb(_ title: String) -> String? {
        outcomePatterns.first { title.range(of: $0.1, options: .regularExpression) != nil }?.0
    }
    /// Each group's result: a confirmation page's verb with what it confirmed (the page just before it in the same app or
    /// site: "Submitted Homework 3"), else a note line that starts with a result verb, as the note says it.
    static func reviewOutcomes(moments: [ActivityNote], actions: [String: CanonicalAction], groupOf: [String: String]) -> [String: (verb: String, object: String?, moments: [String])] {
        var out = [String: (verb: String, object: String?, moments: [String])]()
        var momentOf = [String: String]()
        for m in moments { for a in m.actionIDs { momentOf[a] = m.id } }
        let rows = moments.flatMap(\.actionIDs).compactMap { actions[$0] }.filter { $0.kind != "keyboard.text_input" && !$0.title.isEmpty }
            .sorted { ($0.at, $0.id) < ($1.at, $1.id) }
        for (i, a) in rows.enumerated() {
            guard let verb = outcomeVerb(a.title), let mid = momentOf[a.id] else { continue }
            // What it confirmed: the last other page in the same app and site within half an hour before it.
            var object: String? = nil, objectMoment: String? = nil
            let at = timestamp(a.at)
            for p in rows[..<i].reversed() {
                guard let pt = timestamp(p.at), let t = at, t.timeIntervalSince(pt) <= 1800 else { break }
                guard p.app == a.app, p.site == a.site, outcomeVerb(p.title) == nil else { continue }
                let name = TitleClean.clean(p.title, app: p.app, site: p.site).components(separatedBy: " | ").first?.components(separatedBy: " - ").first?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                if !name.isEmpty, name.count <= 60, name.lowercased() != a.app.lowercased() { object = name; objectMoment = momentOf[p.id]; break }
            }
            let site = ThreadEntities.friendlyHosts[ThreadEntities.host(a.site)] ?? ThreadEntities.host(a.site)
            let key = objectMoment.flatMap { groupOf[$0] } ?? groupOf[mid]
            guard let key, out[key] == nil else { continue }
            out[key] = (verb, object ?? (site.isEmpty ? "in " + a.app : "on " + site), [objectMoment, mid].compactMap { $0 })
        }
        for m in moments {
            guard let key = groupOf[m.id], out[key] == nil, let note = m.generated ?? m.previous else { continue }
            for line in note.output.bullets.map(\.text) {
                let words = line.split(separator: " ").map(String.init)
                guard let first = words.first, outcomeVerbs.contains(first), words.count >= 2, words.count <= 14 else { continue }
                var rest = words.dropFirst().joined(separator: " ")
                while let last = rest.last, ".;,".contains(last) { rest.removeLast() }
                out[key] = (first, rest, [m.id]); break
            }
        }
        return out
    }

    /// "Left off in Ghostty: Tallybird pricing page review": the day's last piece of work, the moment it ended in.
    static func reviewLeftOff(_ threads: [DayReviewThread], byMoment: [String: ActivityNote], actions: [String: CanonicalAction], plan: ThreadPlan,
                              groups: [String: [LevelThread]]) -> (DayReviewItem?, String?) {
        guard let t = threads.filter({ $0.rankCategory == .work && $0.lastEnd != nil }).max(by: { ($0.lastEnd!, $1.key) < ($1.lastEnd!, $0.key) }),
              let m = t.moments.compactMap({ byMoment[$0] }).max(by: { ($0.end, $0.id) < ($1.end, $1.id) }) else { return (nil, nil) }
        let member = groups[t.key]?.first { $0.momentIDs.contains(m.id) }
        var n = [String: Int]()
        for a in m.actionIDs { if let app = actions[a]?.app, !app.isEmpty { n[app, default: 0] += 1 } }
        let app = n.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? ""
        var label = member.map { reviewDisplay($0) } ?? t.name
        if t.kind == "project" { label = projectDetail(label, project: t.name) }
        let site = member.flatMap { $0.kind == "web" ? siteName($0.label, key: $0.key) : nil }
        let place = site ?? app
        let says = DayReview.topic(label, echoing: [place, app] + DayReview.askPlaces)
        guard !place.isEmpty, says != nil else { return (nil, nil) }
        let item = DayReviewItem(id: "leftoff|" + t.key + "|" + (member?.key ?? ""), lead: "Left off " + (site != nil ? "on " : "in ") + place,
                                 colon: true, tail: says, score: 0, moments: [m.id])
        return (item, t.key)
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
        let label = TitleClean.label(ThreadEntities.capitalized(t.label))
        return DayReview.options.contains(.projects) ? withoutIDs(label) : label
    }
    /// What a piece of work is named by when it isn't part of a project: a code thread without its " code".
    static func workName(_ t: LevelThread, label: String) -> String {
        label.hasSuffix(" code") ? String(label.dropLast(5)) : label
    }
    static func siteName(_ label: String, key rawKey: String) -> String {
        var host = ""
        let key = DayReview.options.contains(.workSites) && rawKey.hasPrefix("topic:") ? String(rawKey.dropFirst(6)) : rawKey
        for p in ["site:", "page:", "video:", "social:"] where key.hasPrefix(p) { host = String(key.dropFirst(p.count).split(separator: "|").first ?? "") }
        if let known = ThreadEntities.friendlyHosts[host] { return known }
        if DayReview.options.contains(.workSites), let b = brand(host) { return b }
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
            // claude/dayeval-1005: a topic thread's key names no site ("topic:email:…"): the page's own host, by its tool's name.
            let siteName = ThreadEntities.friendlyHosts[x.site] ?? (DayReview.options.contains(.workSites) ? Self.brand(x.site) : nil)
                ?? (site.isEmpty || (DayReview.options.contains(.workSites) && Self.pageHost(key) == nil && !x.site.isEmpty) ? x.site : site)
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
                var shownTitle = title, place = siteName
                if DayReview.options.contains(.workSites) {
                    // claude/dayeval-1005 (owner 10/04): "Read Kite on Wikipedia", never "Kite - Wikipedia on en.wikipedia.org".
                    if place.contains(".") { place = Self.plainSite(place, titles: [title]) }
                    for sep in [" - ", " | ", " — ", " · "] where shownTitle.lowercased().hasSuffix((sep + place).lowercased()) {
                        shownTitle = String(shownTitle.dropLast(sep.count + place.count))
                    }
                }
                let named = DayReview.options.contains(.workSites) && shownTitle.lowercased().contains(place.lowercased())
                items.append(DayReviewItem(id: key + "|" + title, lead: "Read", link: DayReviewLink(title: shownTitle, url: url), tail: named ? nil : "on " + place,
                                           score: x.seconds / 60, moments: x.moments))
            }
        }
        if items.isEmpty {
            let lead = kind == "video" ? "Watched" : kind == "search" ? "Searched" : "Read"
            // claude/dayeval-1005: a site or "Web searches" with no page or query to name is filler ("Searched Web searches").
            items.append(DayReviewItem(id: key + "#site", lead: lead, tail: site, score: 0, moments: momentIDs, filler: true))
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
                    if let s = stored[key], s.generator == DayReviewClauses.activeVersion {
                        if s.signature == src.signature { continue }
                        if !final, let at = timestamp(s.writtenAt), now.timeIntervalSince(at) < DayReview.clauseEvery {
                            recheck = min(recheck, at.addingTimeInterval(DayReview.clauseEvery))
                            continue
                        }
                    }
                    var r = DayReviewClauseRequest(day: day, timezone: timezone, key: key, lead: src.lead, name: src.name, colon: src.colon, notes: src.notes,
                                                   signature: src.signature, actionIDs: src.actionIDs, start: src.start, end: src.end)
                    r.typedIDs = src.typedIDs.isEmpty ? nil : src.typedIDs
                    out.append(r)
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

    /// FNV-1a, the same in every process (Swift's `Hasher` is seeded per process).
    static func stableHash(_ s: String) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        return Int(h & 0x7fffffffffffffff)
    }
    /// claude/dayeval-1005 (owner: typed words are read by the summarizer on this Mac): a thread's typed rows a clause may
    /// be written from: prompts to an AI app and words written in a document, the latest last (at most `typedFactRows`).
    /// Never a message, an email or a post to a person, a search or a form.
    static func reviewTypedIDs(_ ids: [String], byMoment: [String: ActivityNote], typed: [String: ReviewTyped]) -> [String] {
        let rows = ids.flatMap { byMoment[$0]?.actionIDs ?? [] }.compactMap { typed[$0] }.filter { $0.ask || $0.surface == "writing" }
        return Array(rows.sorted { ($0.at, $0.id) < ($1.at, $1.id) }.suffix(DayReview.typedFactRows).map(\.id))
    }
    /// The typed facts of a clause request, for the writer on this Mac only (`writer` .local; a cloud writer gets none):
    /// "asked: …" for a prompt, "wrote: …" for a document's words, opened with the local writer's disclosure (typing on,
    /// a ready key, the safe-typing consent), whitespace folded, cut to `typedFactChars`, and only when the secret scrubber
    /// keeps every word. Lines go to the model's evidence and its checker; nothing is saved but the checked clause, which
    /// core refuses when it repeats typed words (`commitReviewClause`).
    public func reviewTypedFacts(_ r: DayReviewClauseRequest, writer: TypedWriterKind, now: Date = Date()) throws -> [String] {
        guard writer == .local, DayReview.options.contains(.typedFacts), let ids = r.typedIDs, !ids.isEmpty, typedVaultState == .ready else { return [] }
        let u = "$.captureProvenance.unit."
        var surfaces = [String: String]()
        for row in try rows("SELECT id,coalesce(json_extract(body,'\(u)surface'),'') FROM records WHERE id IN (SELECT value FROM json_each(?))", [json(ids)]) {
            surfaces[row[0]] = row[1]
        }
        var out = [String]()
        for id in ids where r.actionIDs.contains(id) {
            guard let words = try hydrateTypedText(id, disclosure: TypedWriterKind.local.disclosure, now: now),
                  case .keep(_, let redactions) = TypedSecretScrubber.scrub(words), redactions.isEmpty,
                  !words.contains(TypedSecretScrubber.marker) else { continue }
            let line = MomentPromptText.clean(words, limit: DayReview.typedFactChars)
            guard line.count >= 8 else { continue }
            out.append((["ai", "aiTool"].contains(surfaces[id] ?? "") ? "asked: " : "wrote: ") + line)
        }
        return out
    }
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
