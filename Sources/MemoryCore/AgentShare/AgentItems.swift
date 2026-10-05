import Foundation

// agent-tools v2, WP-B (plan §5.3): one day's actions as items, one per thing the person did.
//
// 1. Rows are classed. Window, page and message rows name an entity (AgentEntities). Typed rows join the entity they were
//    typed in (their own recipient first; Messages never borrows a nearby title). Clicks, activations, key presses,
//    Return, shortcuts, scrolls, context menus and idle (policy.omittedKinds plus any mouse./keyboard./app. kind) never
//    become items: they only add their time to the entity on screen in the same app, which feeds ranking.
// 2. All rows of one entity in the day are one item: repeated identical windows and title flicker (counts, glyphs,
//    suffixes, "(1)", "— 80×24") fold into it. Visits are split by a gap of more than 10 minutes. A row counts the time to
//    the next row, at most 5 minutes. A bare shell joins the terminal item before it in the same app.
// 3. An AI chat with no title of its own (the Claude and ChatGPT apps, claude.ai: data-audit §5) is split into its
//    separate sessions (one item per visit): that is all the data allows. Titled chats and Claude Code sessions are
//    already separate entities.
// 4. Notes are labels: a stored note line attaches to the item it names (else the one it overlaps most), filtered by
//    `noteLine` (no send states, no "(draft)", no tautologies). Recorded facts (the entity, visits, time) come first.
// 5. Ids (`AgentItemID.assign`) and scores (`AgentRank`); highest first.
//
// When the policy has typed words off, typed rows are omitted (no ids); their word counts still rank the item they were
// typed in. Counts are a ranking signal only and never an output line.
extension AgentItems {
    /// A gap longer than this between two rows of one entity starts a new visit.
    public static let visitGap: TimeInterval = 600
    /// The most time one row is counted for.
    public static let rowCap: TimeInterval = 300
    /// The most note lines one item carries.
    public static let noteLinesPerItem = 3

    public static func items(_ day: AgentDayInput, policy: AgentSharePolicy, now: Date) -> [AgentItem] {
        items(day, policy: policy, now: now, weights: .standard)
    }

    public static func items(_ day: AgentDayInput, policy: AgentSharePolicy, now: Date, weights: AgentRank.Weights) -> [AgentItem] {
        let rows = dayRows(day)
        guard !rows.isEmpty else { return [] }
        var groups: [String: Group] = [:]
        var order: [String] = []
        func add(_ key: String, _ entity: AgentEntity, _ entry: Entry) {
            if groups[key] == nil { groups[key] = Group(entity: entity); order.append(key) }
            groups[key]?.entries.append(entry)
        }
        var context: Context? = nil
        var lastTerminal: [String: (key: String, entity: AgentEntity)] = [:]
        // 78% of window rows repeat the row before (data-audit §4): parse each distinct window, and fold its key, once.
        var parsed: [String: AgentEntity] = [:]
        var keys: [AgentEntity: String] = [:]
        func entityOf(_ a: CanonicalAction) -> AgentEntity {
            if a.kind == "keyboard.text_input" { return AgentEntities.entity(a, unit: day.typed[a.id]?.unit) }
            let signature = [a.app, a.bundle, a.site, a.title, a.tool ?? "-", a.link ?? "-",
                             a.description.hasPrefix("Observed search results for ") ? a.description : ""].joined(separator: "\u{1F}")
            if let known = parsed[signature] { return known }
            let entity = AgentEntities.entity(a, unit: nil)
            parsed[signature] = entity
            return entity
        }
        func keyOf(_ e: AgentEntity) -> String {
            if let known = keys[e] { return known }
            let key = e.key; keys[e] = key; return key
        }
        for (i, row) in rows.enumerated() {
            let a = row.action
            let next = i + 1 < rows.count ? rows[i + 1].at : row.at
            let duration = max(0, min(next.timeIntervalSince(row.at), rowCap))
            switch role(a.kind, policy: policy) {
            case .idle:
                context = nil
            case .noise:
                if let c = context, a.app.isEmpty || a.app == c.app {
                    add(c.key, c.entity, Entry(at: row.at, duration: duration, id: nil, typed: false, words: 0))
                } else if a.kind.hasPrefix("app.") {
                    context = nil
                }
            case .entity:
                var entity = entityOf(a)
                var key = keyOf(entity)
                if let joined = bareJoin(entity, app: a.app, context: context, lastTerminal: lastTerminal) { (key, entity) = joined }
                else if case .webSearch(let engine, nil) = entity, let found = searchAhead(engine: engine, app: a.app, rows: rows, index: i, entityOf: entityOf) {
                    (key, entity) = (keyOf(found), found)
                }
                if case .terminal = entity { lastTerminal[a.app] = (key, entity) }
                add(key, entity, Entry(at: row.at, duration: duration, id: a.id, typed: false, words: 0))
                context = Context(key: key, entity: entity, app: a.app, site: TitleClean.hostName(a.site))
            case .typed:
                let fact = day.typed[a.id]
                let words = max(fact?.words ?? 0, 0)
                guard policy.typedWords else {
                    // Omitted: no id, no item of its own. Its count still ranks what it was typed in.
                    // Messages never lends a typed row to the window's person (MessagesMomentIdentity).
                    if let c = context, a.app == c.app, !MessagesMomentIdentity.applies(bundle: a.bundle, app: a.app) {
                        add(c.key, c.entity, Entry(at: row.at, duration: duration, id: nil, typed: false, words: words))
                    }
                    continue
                }
                let (key, entity) = typedTarget(a, own: entityOf(a), context: context, rows: rows, index: i, entityOf: entityOf)
                add(key, entity, Entry(at: row.at, duration: duration, id: a.id, typed: true, words: words))
                if context == nil || context?.app != a.app { context = Context(key: key, entity: entity, app: a.app, site: TitleClean.hostName(a.site)) }
            }
        }

        // Items: one per group, or one per session for an untitled AI chat.
        var built: [(key: String, item: AgentItem)] = []
        for key in order {
            guard let group = groups[key], group.entries.contains(where: { $0.id != nil }) else { continue }
            let entries = group.entries.sorted { $0.at < $1.at }
            let visits = visitsOf(entries)
            if case .aiChat(_, nil) = group.entity {
                for visit in visits {
                    let members = entries.filter { $0.at >= visit.start && $0.at <= visit.end }
                    guard members.contains(where: { $0.id != nil }) else { continue }
                    let sessionKey = key + "|@" + clock(visit.start, timezone: day.timezone)
                    built.append((sessionKey, item(day: day.day, entity: group.entity, entries: members, visits: [visit])))
                }
            } else {
                built.append((key, item(day: day.day, entity: group.entity, entries: entries, visits: visits)))
            }
        }

        attachNotes(day.notes, to: &built)
        let ids = AgentItemID.assign(day: day.day, keys: built.map(\.key))
        var out = built.map { pair -> AgentItem in
            var item = pair.item
            item.id = ids[pair.key] ?? AgentItemID.make(day: day.day, key: pair.key)
            item.score = AgentRank.score(item, now: now, weights: weights)
            return item
        }
        out.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.firstAt != b.firstAt { return a.firstAt < b.firstAt }
            return a.id < b.id
        }
        return out
    }

    /// The grouping key `items` hashed an item's id from (C can use it to match an item across calls). An untitled AI
    /// chat is one item per session, keyed by its session's local start ("ai_chat|claude||@0915"), so its id holds while
    /// later sessions are added to the day.
    public static func itemKey(_ item: AgentItem, timezone: String) -> String {
        guard case .aiChat(_, nil) = item.entity else { return item.entity.key }
        return item.entity.key + "|@" + clock(item.firstAt, timezone: timezone)
    }

    /// The `timeline` summary split: up to `limit` items shown, the rest counted by kind. Forms, documents and people are
    /// shown before anything else (never dropped silently); the shown list keeps score order. `collapsed.total` and the
    /// sum of `collapsed.byKind` both equal `items.count - shown.count`.
    public static func summary(_ items: [AgentItem], limit: Int) -> (shown: [AgentItem], collapsed: AgentCollapsed) {
        let ranked = items.sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
        let pinned: Set<AgentEntityKind> = [.form, .document, .person]
        var chosen = Set<String>()
        for item in ranked where pinned.contains(item.entity.kind) && chosen.count < max(limit, 0) { chosen.insert(item.id) }
        for item in ranked where chosen.count < max(limit, 0) { chosen.insert(item.id) }
        let shown = ranked.filter { chosen.contains($0.id) }
        var collapsed = AgentCollapsed()
        for item in ranked where !chosen.contains(item.id) {
            collapsed.total += 1
            collapsed.byKind[item.entity.kind, default: 0] += 1
        }
        return (shown, collapsed)
    }

    // MARK: - Rows

    struct Row { var action: CanonicalAction; var at: Date }
    struct Entry { var at: Date; var duration: TimeInterval; var id: String?; var typed: Bool; var words: Int }
    struct Group { var entity: AgentEntity; var entries: [Entry] = [] }
    struct Context { var key: String; var entity: AgentEntity; var app: String; var site: String }
    enum Role { case entity, typed, noise, idle }

    /// The day's actions in time order (ties by id), inside the local day when it can be read.
    static func dayRows(_ day: AgentDayInput) -> [Row] {
        let interval = try? DayScope.interval(day: day.day, timezone: day.timezone)
        var seen = Set<String>()
        var rows: [Row] = []
        for action in day.actions {
            guard let at = timestamp(action.at), seen.insert(action.id).inserted else { continue }
            if let interval, !(interval.start <= at && at < interval.end) { continue }
            rows.append(Row(action: action, at: at))
        }
        return rows.sorted { $0.at != $1.at ? $0.at < $1.at : $0.action.id < $1.action.id }
    }

    static func role(_ kind: String, policy: AgentSharePolicy) -> Role {
        if kind == "idle" || kind.hasPrefix("session.") { return .idle }
        if kind == "keyboard.text_input" { return .typed }
        if policy.omits(kind) || kind.hasPrefix("mouse.") || kind.hasPrefix("keyboard.") || kind.hasPrefix("app.") || kind.contains("scroll")
            || kind.hasPrefix("debug.") || kind.contains("context_menu") { return .noise }
        return .entity
    }

    /// Where a typed row belongs: its own recipient; for Messages only its own identity; a search box joins the results
    /// that follow it; otherwise the entity on screen in the same app and site; else what its own row names.
    static func typedTarget(_ a: CanonicalAction, own: AgentEntity, context: Context?, rows: [Row], index: Int,
                            entityOf: (CanonicalAction) -> AgentEntity) -> (String, AgentEntity) {
        if case .person = own { return (own.key, own) }
        if MessagesMomentIdentity.applies(bundle: a.bundle, app: a.app) { return (own.key, own) }
        if case .webSearch(let engine, nil) = own, let found = searchAhead(engine: engine, app: a.app, rows: rows, index: index, entityOf: entityOf) {
            return (found.key, found)
        }
        let site = TitleClean.hostName(a.site)
        if let c = context, c.app == a.app, site.isEmpty || c.site == site { return (c.key, c.entity) }
        return (own.key, own)
    }

    /// A search page with no words (the engine's home, a box being typed in) followed within 2 minutes, in the same app,
    /// by that engine's results for some words: those results.
    static func searchAhead(engine: String, app: String, rows: [Row], index: Int, entityOf: (CanonicalAction) -> AgentEntity) -> AgentEntity? {
        let at = rows[index].at
        for later in rows[(index + 1)...] {
            if later.at.timeIntervalSince(at) > 120 { break }
            guard later.action.kind != "keyboard.text_input", later.action.app == app else { continue }
            if case .webSearch(engine, let q?) = entityOf(later.action) { return .webSearch(engine: engine, query: q) }
        }
        return nil
    }

    /// A row that names nothing more than its app joins what is on screen: a bare shell joins the app's last terminal
    /// item, an untitled window joins the titled one before it in the same app, an untitled AI chat window joins the
    /// titled chat it flickers with. Messages never does (its rows' identity is their own).
    static func bareJoin(_ entity: AgentEntity, app: String, context: Context?, lastTerminal: [String: (key: String, entity: AgentEntity)]) -> (String, AgentEntity)? {
        switch entity {
        case .terminal(nil, nil, nil):
            return lastTerminal[app].map { ($0.key, $0.entity) }
        case .app(let name, "", false) where name != "Messages":
            guard let c = context, c.app == app, case .app(name, let t, _) = c.entity, !t.isEmpty else { return nil }
            return (c.key, c.entity)
        case .aiChat(let chat, nil):
            guard let c = context, c.app == app, case .aiChat(chat, _?) = c.entity else { return nil }
            return (c.key, c.entity)
        default:
            return nil
        }
    }

    static func visitsOf(_ entries: [Entry]) -> [AgentVisit] {
        var visits: [AgentVisit] = []
        for e in entries {
            let end = e.at.addingTimeInterval(e.duration)
            if var last = visits.last, e.at.timeIntervalSince(last.end) <= visitGap {
                last.end = max(last.end, end); visits[visits.count - 1] = last
            } else {
                visits.append(AgentVisit(start: e.at, end: end))
            }
        }
        return visits
    }

    static func item(day: String, entity: AgentEntity, entries: [Entry], visits: [AgentVisit]) -> AgentItem {
        let seconds = entries.reduce(0) { $0 + $1.duration }
        let ids = entries.compactMap(\.id)
        let typed = entries.filter(\.typed).compactMap(\.id)
        let words = entries.reduce(0) { $0 + $1.words }
        return AgentItem(id: "", day: day, entity: entity, firstAt: visits.first?.start ?? entries.first?.at ?? Date(timeIntervalSince1970: 0),
                         lastAt: visits.last?.end ?? entries.last?.at ?? Date(timeIntervalSince1970: 0), visits: visits,
                         minutes: (seconds / 6).rounded() / 10, actionIDs: ids, typedIDs: typed, typedWords: words, noteLines: [], score: 0)
    }

    static func clock(_ date: Date, timezone: String) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: timezone) ?? TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d%02d", c.hour ?? 0, c.minute ?? 0)
    }

    // MARK: - Notes

    /// Each note line goes to one item: the overlapping item it names (longest name wins), else the one it overlaps
    /// most (then the earliest). Lines are filtered for that item's name; duplicates and extras past the cap are left out.
    static func attachNotes(_ notes: [AgentNoteInput], to built: inout [(key: String, item: AgentItem)]) {
        guard !notes.isEmpty else { return }
        var owner: [String: [Int]] = [:]
        for (i, pair) in built.enumerated() { for id in pair.item.actionIDs { owner[id, default: []].append(i) } }
        for note in notes {
            var overlap: [Int: Int] = [:]
            for id in Set(note.actionIDs) { for i in owner[id] ?? [] { overlap[i, default: 0] += 1 } }
            guard !overlap.isEmpty else { continue }
            let candidates = overlap.keys.sorted { overlap[$0]! != overlap[$1]! ? overlap[$0]! > overlap[$1]! : built[$0].item.firstAt < built[$1].item.firstAt }
            for line in note.lines {
                let folded = AgentTitles.folded(line, tails: false)
                let named = candidates.filter { i in
                    let n = AgentTitles.folded(AgentEntities.name(built[i].item.entity), tails: false)
                    return n.count >= 3 && folded.contains(n)
                }.max { AgentEntities.name(built[$0].item.entity).count < AgentEntities.name(built[$1].item.entity).count }
                guard let target = named ?? candidates.first else { continue }
                guard let kept = noteLine(line, itemName: AgentEntities.name(built[target].item.entity)),
                      built[target].item.noteLines.count < noteLinesPerItem,
                      !built[target].item.noteLines.contains(where: { AgentTitles.folded($0, tails: false) == AgentTitles.folded(kept, tails: false) }) else { continue }
                built[target].item.noteLines.append(kept)
            }
        }
    }

    /// Words that state a send or delivery state. None of them is ever shown to an agent (owner 10/04).
    static let sendState = #"\b(drafts?|drafted|drafting|sent|unsent|delivered|undelivered|unread|not established)\b"#
    static let noiseLine = #"^(clicked|pressed|switched to|switched between|used a keyboard shortcut|used a shortcut|opened a context menu|scrolled|activated|focused)\b"#
    static let wordCountLine = #"typed (a draft|\d+ words?)|a few words|exact words (were )?not shared|not shared with ai apps|\(\d+ words?\)"#
    /// "Viewed Claude …" (any rest), or only the AI app as the place ("In ChatGPT.", "Used the Claude app").
    static let aiApps = #"^viewed (the )?(claude|chatgpt|gemini|codex|copilot|perplexity)\b|^(looked at|opened|used|was in|in) (the )?(claude|chatgpt|gemini|codex|copilot|perplexity|claude code)( app| desktop app| desktop)?( window| chat| conversation)?\.?$"#
    static let viewVerbs = #"^(viewed|looked at|opened|visited|was on|was in|browsed|used|saw|in|on) "#
    static let stopWords: Set<String> = ["the", "a", "an", "of", "on", "in", "at", "to", "for", "and", "page", "window", "tab", "app", "site",
                                         "website", "results", "search", "document", "doc", "file", "screen"]

    public static func noteLine(_ line: String, itemName: String) -> String? {
        var s = AgentTitles.collapsed(line.trimmingCharacters(in: .whitespacesAndNewlines))
        s = s.replacingOccurrences(of: #"^[-•*]\s+"#, with: "", options: .regularExpression)
        // Kept labels.
        var label = ""
        for marker in ["(interpretation)", "(reported)"] where s.lowercased().hasPrefix(marker) {
            label = marker + " "; s = String(s.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        // Send-state markers go; the line stays if it says more than the state.
        var changed = true
        while changed {
            changed = false
            if let r = s.range(of: #"^[\(\[](draft|sent|unsent|not sent|delivered|unread)[\)\]]\s*"#, options: [.regularExpression, .caseInsensitive]) {
                s.removeSubrange(r); changed = true
            }
        }
        let lower = s.lowercased()
        if lower.contains("not established") || lower.hasPrefix("observed ") { return nil }
        if lower.range(of: noiseLine, options: .regularExpression) != nil || lower.range(of: wordCountLine, options: .regularExpression) != nil { return nil }
        // A trailing state clause: "… (not sent).", "…, not sent", "; message was delivered", "— still a draft".
        s = s.replacingOccurrences(
            of: #"\s*(?:[,;—–-]\s*|\(\s*|\[\s*)(?:the |this |it |that )?(?:message|text|email|reply|post)?\s*(?:was |is |has been |not yet |still |never |left as |saved as )*(?:not sent|unsent|never sent|not delivered|undelivered|delivered|sent|an? draft|draft|unread)\s*[\)\]]?(?=[.!]?$)"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        // Send verbs said without the claim.
        let rewrites: [(String, String)] = [
            (#"^sent (?:an? )?(?:text|message|imessage|sms) to "#, "Texted "),
            (#"^sent (?:an? )?(?:e-?mail) to "#, "Emailed "),
            (#"^sent (?:an? )?reply to "#, "Replied to "),
            (#"^sent (.+) to (.+)$"#, "Shared $1 with $2"),
            (#"^drafted "#, "Wrote "), (#"^drafting "#, "Writing "), (#"\bdrafted\b"#, "wrote"), (#"\ban? draft of\s+"#, ""),
            (#"\bdraft (reply|message|email|text|post)\b"#, "$1"),
        ]
        for (pattern, template) in rewrites {
            s = s.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
        }
        s = AgentTitles.collapsed(s).trimmingCharacters(in: CharacterSet(charactersIn: " ,;—–-"))
        guard !s.isEmpty else { return nil }
        if let first = s.first, first.isLowercase { s = first.uppercased() + s.dropFirst() }
        // Anything still stating a send state is dropped, unless the word is the item's own name ("Cover letter draft").
        var probe = s.lowercased()
        let name = itemName.lowercased().trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { probe = probe.replacingOccurrences(of: name, with: " ") }
        if probe.range(of: sendState, options: .regularExpression) != nil { return nil }
        // Tautologies: the place alone ("In Terminal."), an AI app viewed, a view of the item itself, the name alone.
        let l = s.lowercased()
        let words = l.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        if l.range(of: #"^in \S+(\s\S+){0,2}\.?$"#, options: .regularExpression) != nil { return nil }
        if l.range(of: aiApps, options: .regularExpression) != nil { return nil }
        if AgentTitles.folded(s.trimmingCharacters(in: CharacterSet(charactersIn: ".")), tails: false) == AgentTitles.folded(itemName, tails: false) { return nil }
        if let r = l.range(of: viewVerbs, options: .regularExpression) {
            // The viewed thing without its product suffix ("Viewed Q3 plan - Google Docs." is a view of "Q3 plan").
            let viewed = AgentTitles.withoutSuffixes(String(l[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " .")), app: "", site: "")
            let rest = viewed.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
            let nameWords = Set(name.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init))
            if rest.allSatisfy({ nameWords.contains($0) || stopWords.contains($0) }) { return nil }
        }
        // The shared filler list (NoteFiller), except its "In <anything>" catch-all for a line that says more.
        let saysMore = l.hasPrefix("in ") && words.count > 4
        if !saysMore, !l.hasPrefix("read "), NoteFiller.isFiller(s, apps: itemName.isEmpty ? [] : [itemName]) { return nil }
        let out = label + s
        return out.count <= 240 ? out : String(out.prefix(239)) + "…"
    }
}
