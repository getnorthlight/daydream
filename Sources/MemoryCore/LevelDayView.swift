import Foundation
import PrivacyPolicy

// Levels of memory in the app (summaries/v3 preview UI): what the Today page and Recall read of the level notes.
// Read only. The notes are written by LevelWriterBinding (model, else code) and checked again by core on commit.

/// The level notes a day page shows: its day note (L4), its blocks (L3, in time order) and the note of the week it
/// is in (L5). Any of them can be missing (not written yet, or nothing recorded).
public struct DayLevels: Codable, Equatable, Sendable {
    public var day: LevelNote?
    public var blocks: [LevelNote]
    public var week: LevelNote?
    /// fix/day-card: the day's threads by code at read time (no model), so the page says who and what from the first
    /// minute, with summaries off, downloading, waiting for power, local or cloud. nil on a day whose day note and moment notes
    /// are all stored (nothing would use it), and on a day with nothing recorded.
    public var live: LiveDay? = nil
    /// claude/day-review-1003: the Today card's day review (DayReview.swift), by code on every read, with the model's
    /// cached clauses. nil on a day with nothing recorded.
    public var review: DayReviewFacts? = nil
    public init(day: LevelNote?, blocks: [LevelNote], week: LevelNote?, live: LiveDay? = nil, review: DayReviewFacts? = nil) {
        self.day = day; self.blocks = blocks; self.week = week; self.live = live; self.review = review
    }
    public static let empty = DayLevels(day: nil, blocks: [], week: nil)

    /// A day note the code saved plain (r2: its named note would repeat a typed draft, so it keeps only kinds: "Document",
    /// "Texts, ~40 min"). Its names never come back into what is stored or what AI apps read; the page shows the day's
    /// threads by code instead (the same names its rows already show), never "Document" as the day's headline.
    public static func savedPlain(_ note: LevelNote) -> Bool {
        guard note.generator == LevelWriterVersion.extractive, let main = note.threads?.first, main.kind != "app" else { return false }
        let plain = LevelThreads.plainLabel(main)
        return main.label == plain && main.people.isEmpty && main.places.isEmpty
            && note.title.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) == plain
    }
}

/// One moment as the day's threads name it, by code (fix/day-card). What a row says while it has no note.
public struct LiveMoment: Codable, Equatable, Sendable {
    /// "Texts with Q7", "Email with Sam", "PR #418: Weekly summaries export", "Slack in #eng", "ChatGPT". Never a raw
    /// window title (TitleClean).
    public var label: String
    /// The thread kind of what the moment is about (texts, email, slack, chat, ai, doc, code, pr, meeting, video, web...).
    public var kind: String
    /// One line per detected send, who only, never words: "Texted Q7", "Emailed Sam", "Asked Claude", "Posted on X",
    /// "Messaged #eng". A send verb only where a send gesture was detected on a typed row.
    public var sends: [String]
    /// Focused seconds (ThreadPlanner's dwell over its actions).
    public var seconds: Int
    /// Only idle rows, or no app at all: not a row of its own.
    public var idle: Bool
    /// A conversation (texts, email, Slack, a chat) or a detected send: ranked first.
    public var communication: Bool
    public init(label: String, kind: String, sends: [String], seconds: Int, idle: Bool, communication: Bool) {
        self.label = label; self.kind = kind; self.sends = sends; self.seconds = seconds; self.idle = idle; self.communication = communication
    }
    /// "~38 min": a moment's own time to the minute under an hour (a thread's is rounded to 5 minutes), "~1 hr 20 min".
    public var duration: String {
        let m = max(1, Int((Double(seconds) / 60).rounded()))
        return m < 60 ? "~\(m) min" : LevelThreads.duration(seconds)
    }
}

/// A stretch of the day as the threads cut it (ThreadPlanner blocks), named by its main thread.
public struct LiveBlock: Codable, Equatable, Sendable {
    public var start: String
    public var end: String
    public var label: String
    public var moments: [String]
    public var mainMoments: [String]
    /// Its other threads, communications first: "Texts with Q7, ~10 min".
    public var side: [String]
    public init(start: String, end: String, label: String, moments: [String], mainMoments: [String], side: [String]) {
        self.start = start; self.end = end; self.label = label; self.moments = moments; self.mainMoments = mainMoments; self.side = side
    }
}

/// The day's headline and lines by code (fix/day-card). The headline is the main thread (never passive viewing when
/// anything else ran); the lines are the other threads with names, sends and communications first, then the most
/// meaningful work by minutes, passive viewing last; at most four, never an "Also …" merge.
public struct LiveDay: Codable, Equatable, Sendable {
    public var mainTitle: String
    public var mainSeconds: Int
    /// The main thread's key ("doc:q3 investor update"): a stored day note is the headline while its main thread is this one.
    public var mainKey: String
    public var mainMoments: [String]
    public var lines: [LevelLine]
    public var blocks: [LiveBlock]
    public var moments: [String: LiveMoment]
    public init(mainTitle: String, mainSeconds: Int, mainKey: String, mainMoments: [String], lines: [LevelLine], blocks: [LiveBlock], moments: [String: LiveMoment]) {
        self.mainTitle = mainTitle; self.mainSeconds = mainSeconds; self.mainKey = mainKey; self.mainMoments = mainMoments
        self.lines = lines; self.blocks = blocks; self.moments = moments
    }
    public var mainMinutes: Int { Int((Double(mainSeconds) / 60).rounded()) }
    /// "~1 hr 5 min".
    public var mainDuration: String { LevelThreads.duration(mainSeconds) }
    /// At most this many lines under the headline.
    public static let maxLines = 4
}

/// One search hit in DayDream's notes, at any level (Recall's notes rows; the MCP `recall` search is the same match).
public struct NoteHit: Codable, Equatable, Sendable, Identifiable {
    /// "week", "month", "day", "block", "moment" or "line".
    public var level: String
    /// The matching line, or the note's title when only the title (or the note as a whole) matched.
    public var text: String
    /// The note the line is in (a moment's title, a block's or day's title); nil when `text` is the title itself.
    public var inTitle: String?
    /// When it happened: a line's first action, a moment's or note's start (ISO-8601).
    public var at: String
    /// The local day it belongs to (a week or month: its last day with a note, else its first day).
    public var day: String
    /// The MCP handle (`moment:<id>@<day>`, `block:<id>`, `day:<key>`, `week:<key>`).
    public var open: String
    /// Moments and lines: the moment, and the first action the line cites (Recall resolves the moment row by it).
    public var momentID: String?
    public var actionID: String?
    /// A line's claim label (submitted, draft, observed...).
    public var state: String?
    /// The whole note the hit is in: its title, its lines and the notes it was written from (Recall's preview card).
    public var noteTitle: String = ""
    /// The note's end (ISO-8601); a line's or moment's last action.
    public var end: String = ""
    public var lines: [String] = []
    public var children: [NoteChild] = []
    public var id: String { level + "|" + open + "|" + text }
    public init(level: String, text: String, inTitle: String?, at: String, day: String, open: String, momentID: String? = nil,
                actionID: String? = nil, state: String? = nil, noteTitle: String = "", end: String = "", lines: [String] = [],
                children: [NoteChild] = []) {
        self.level = level; self.text = text; self.inTitle = inTitle; self.at = at; self.day = day; self.open = open
        self.momentID = momentID; self.actionID = actionID; self.state = state; self.noteTitle = noteTitle; self.end = end
        self.lines = lines; self.children = children
    }
}

/// A note one level down, as a preview card lists it ("moment", "block" or "day"; its title and start).
public struct NoteChild: Codable, Equatable, Sendable {
    public var level: String
    public var title: String
    public var start: String
    public init(level: String, title: String, start: String) { self.level = level; self.title = title; self.start = start }
}

extension MemoryStore {
    /// The block, day and week notes for one local day (level notes are read by id, so a threads-version bump or a
    /// policy revision never empties them), and the day's live threads (`LiveDay`) for today and for any day without a
    /// stored day note, a day note saved plain, or with a moment still without a note.
    public func dayLevels(day: String, timezone: String, now: Date = Date()) throws -> DayLevels {
        var levels = DayLevels.empty
        if try hasLevelNotes() {
            levels.day = try levelNote(Self.levelID(.day, period: day, timezone: timezone))
            levels.blocks = try levelNotes(level: .block, periods: [day]).sorted { ($0.start, $0.id) < ($1.start, $1.id) }
            levels.week = try Self.weekKey(day: day, timezone: timezone).flatMap { try levelNote(Self.levelID(.week, period: $0, timezone: timezone)) }
        }
        // fix/sx-all round 2: a capture landing mid-read ("Day changed; retry fresh read") is read again once; if the day is
        // still changing, the notes read above stay and only the live threads wait for the next read (never a Today card
        // that loses its day note and blocks because a click landed).
        let assembled: AssembledDay
        do { assembled = try assembleDayForLevels(day: day, timezone: timezone, now: now) }
        catch MemError.invalid(let message) where message == Self.dayChanged {
            do { assembled = try assembleDayForLevels(day: day, timezone: timezone, now: now) }
            catch MemError.invalid(let message) where message == Self.dayChanged { return levels }
        }
        let today = (try? DayScope.key(now, timezone: timezone)) == day
        // The day's threads, planned once and only when something needs them (the live threads, or a review not cached).
        var planned: ThreadPlan?
        func plan() throws -> ThreadPlan {
            if let planned { return planned }
            let moments = assembled.day.activities.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
            let p = try threadPlan(moments: moments, actions: assembled.actions)
            planned = p
            return p
        }
        if !assembled.day.activities.isEmpty, today || levels.day == nil || levels.day.map(DayLevels.savedPlain) == true || assembled.day.activities.contains(where: { $0.generated == nil }) {
            levels.live = try liveDay(assembled, timezone: timezone, plan: try plan())
        }
        // claude/day-review-1003: the review's facts never hold the day's read back (a failure leaves the old card). Perf
        // pass: cached per day (`DayReviewCache`), so a read whose day didn't change costs a fingerprint and the clauses.
        if !assembled.day.activities.isEmpty {
            let started = CFAbsoluteTimeGetCurrent()
            levels.review = try? dayReview(assembled, plan: try plan(), day: day, timezone: timezone, now: now)
            Self.lastReviewMillisecondsForChecks = (CFAbsoluteTimeGetCurrent() - started) * 1000
        }
        return levels
    }

    /// Checks only: what the last day read's review cost (milliseconds), plan included when it had to be made for it.
    nonisolated(unsafe) public static var lastReviewMillisecondsForChecks = 0.0
    /// Checks only: how many of the next day reads for levels throw as a capture landing mid-read would.
    nonisolated(unsafe) public static var levelReadFailuresForChecks = 0
    private func assembleDayForLevels(day: String, timezone: String, now: Date) throws -> AssembledDay {
        if Self.levelReadFailuresForChecks > 0 { Self.levelReadFailuresForChecks -= 1; throw MemError.invalid(Self.dayChanged) }
        return try assembleDay(day: day, timezone: timezone, limit: 1, now: now, notes: true)
    }

    // MARK: live threads (fix/day-card)

    /// The day's threads, blocks and each moment's name and sends, by code only (ThreadPlanner over the day's actions;
    /// the typed rows' send facts and recipient labels, never their words). nil for a day without moments.
    func liveDay(_ assembled: AssembledDay, timezone: String, plan known: ThreadPlan? = nil) throws -> LiveDay? {
        let moments = assembled.day.activities.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        guard !moments.isEmpty else { return nil }
        let plan = try known ?? threadPlan(moments: moments, actions: assembled.actions)
        let typedIDs = moments.flatMap(\.actionIDs).filter { assembled.actions[$0]?.kind == "keyboard.text_input" }
        let facts = try typedSendFacts(typedIDs)
        let recipients = try typedRecipients(typedIDs)
        var perMoment = [String: LiveMoment]()
        for m in moments {
            let actions = m.actionIDs.compactMap { assembled.actions[$0] }
            let entity = plan.momentEntity[m.id]
            let idle = actions.allSatisfy { $0.kind == "idle" || $0.app.isEmpty } || entity == nil
            var sends = [String](), who = [String]()
            let typedRows = actions.filter { $0.kind == "keyboard.text_input" }
            func recipient(_ a: CanonicalAction) -> String? {
                if MessagesMomentIdentity.applies(a) { return recipients[a.id] }
                return (recipients[a.id] ?? facts[a.id]?.to).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty || $0.contains("@") ? nil : $0 }
            }
            for a in typedRows { if let to = recipient(a) { who.append(to) } }
            let seconds = Int(m.actionIDs.reduce(0.0) { $0 + (plan.dwell[$1] ?? 0) }.rounded())
            let kind = entity?.kind ?? "app"
            let label = Self.momentLabel(entity, moment: m, actions: actions, who: who)
            for a in typedRows where a.state == "submitted" {
                guard let line = Self.sendLine(a, surface: facts[a.id]?.surface, to: recipient(a), label: label) else { continue }
                if !sends.contains(line) { sends.append(line) }
            }
            perMoment[m.id] = LiveMoment(label: label, kind: kind, sends: sends, seconds: seconds, idle: idle,
                                         communication: !sends.isEmpty || Self.conversationKinds.contains(kind))
        }
        // Names of a conversation thread read from its moments (a group chat called "Q7" has no person name in it).
        func display(_ t: LevelThread) -> String {
            if Self.conversationKinds.contains(t.kind), t.people.isEmpty, t.places.isEmpty {
                let names = Self.unique(t.momentIDs.compactMap { perMoment[$0]?.label }.compactMap(Self.conversationName))
                if !names.isEmpty { return LevelThreads.channelLabel(t.kind, people: names, places: []) }
            }
            // A code thread over several files that share a name ("ExportView.swift", "ExportTests.swift") is named
            // by what they share: "Export code", not the project ("Daydream code"). fix/sx-all round 3: a code thread named
            // by its pull request keeps that name.
            if t.kind == "code", t.label.hasSuffix(" code"), let shared = Self.sharedFileName(t.momentIDs.compactMap { perMoment[$0]?.label }) { return shared + " code" }
            return TitleClean.label(ThreadEntities.capitalized(t.label))
        }
        func lines(_ threads: [LevelThread], main: LevelThread, max: Int) -> [LevelLine] {
            let ordered = [main] + threads.filter { $0.key != main.key }
            let byKey = Dictionary(ordered.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            var ranked = [(tier: Int, seconds: Int, index: Int, line: LevelLine)]()
            for (i, raw) in LevelThreads.bullets(ordered, max: 1000).enumerated() {
                let ids = raw.moments ?? []
                let members = ids.compactMap { perMoment[$0] }
                let communication = members.contains(where: \.communication)
                let passive = !members.isEmpty && members.allSatisfy { Self.passiveKinds.contains($0.kind) && $0.sends.isEmpty }
                var line = raw
                let parts = raw.text.components(separatedBy: ", ~")
                let duration = parts.count > 1 ? "~" + parts.last! : ""
                let name = parts.count > 1 ? parts.dropLast().joined(separator: ", ~") : raw.text
                // fix/sx-all round 1: a thread's sent or asked line ("Texted Jordan about the demo.") stays as it is; only a
                // name with minutes is relabelled. Before, the line became its bare label ("Texts with Jordan"), with
                // neither what nor how long.
                if parts.count == 1, !raw.text.isEmpty {
                    line.text = raw.text
                } else if ["Texts", "Email", "Slack", "Teams chat"].contains(name) {
                // A bare channel name ("Texts") gets the conversation names its moments show.
                    let kinds = Set(members.map(\.kind))
                    let names = Self.unique(members.compactMap { Self.conversationName($0.label) })
                    if kinds.count == 1, let k = kinds.first, !names.isEmpty {
                        line.text = LevelThreads.channelLabel(k, people: names, places: []) + (duration.isEmpty ? "" : ", " + duration)
                    }
                } else if let t = ordered.first(where: { $0.momentIDs == ids }) ?? byKey.values.first(where: { Set($0.momentIDs) == Set(ids) }) {
                    line.text = display(t) + (duration.isEmpty ? "" : ", " + duration)
                } else {
                    line.text = TitleClean.label(name) + (duration.isEmpty ? "" : ", " + duration)
                }
                // A written note's own send line ("Texted Q7 about Friday dinner") when it is the only one in the line.
                if communication {
                    let noteSends = Self.unique(ids.compactMap { id in moments.first { $0.id == id } }.flatMap(Self.noteSendLines))
                    if noteSends.count == 1 { line.text = noteSends[0] }
                }
                let seconds = raw.text.isEmpty ? 0 : members.reduce(0) { $0 + $1.seconds }
                // Communications with people first (texts, email, chat, posts), then asks of an AI app, then the rest,
                // then what only played (owner 9/28: communications are ranked on top).
                let people = members.contains { Self.conversationKinds.contains($0.kind) || $0.sends.contains { !$0.hasPrefix("Asked ") } }
                ranked.append((people ? 0 : communication ? 1 : passive ? 3 : 2, seconds, i, line))
            }
            let sorted = ranked.sorted { ($0.tier, -$0.seconds, $0.index) < ($1.tier, -$1.seconds, $1.index) }
            // fix/sx-all round 1: one line per person or group. A conversation's name-and-minutes line ("Slack with
            // Priya, ~9 min") goes when a sent line names them ("Messaged Priya Shah about the build."), and a second sent
            // line to the same person goes too (the heavier thread's stays).
            var kept = [(tier: Int, seconds: Int, index: Int, line: LevelLine)](), who = Set<String>()
            func person(_ text: String) -> String? {
                let words = text.split(separator: " ").map(String.init)
                guard words.count >= 2, Self.sendVerbs.contains(words[0]) else { return nil }
                let rest = words.dropFirst().prefix { $0.first?.isUppercase == true || $0.hasPrefix("#") }
                return rest.isEmpty ? nil : rest.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ".,")).lowercased()
            }
            let sentTo = Set(sorted.compactMap { person($0.line.text) })
            for r in sorted {
                if let p = person(r.line.text) { if !who.insert(p).inserted { continue } }
                else if let name = Self.conversationName(r.line.text.components(separatedBy: ", ~")[0])?.lowercased(),
                        sentTo.contains(where: { $0 == name || $0.hasPrefix(name + " ") || name.hasPrefix($0 + " ") }) { continue }
                kept.append(r)
            }
            // claude/summary-fail-1003 (owner 10/3, "Texts, ~8 min" over "Texts with Q7 and Jamie Lin, ~1 min"): one entry per
            // app or conversation. A bare app or channel line with only its minutes goes when a real line covers the same
            // conversation kind or app (Messages moments code couldn't name are still texts).
            func facets(_ line: LevelLine) -> Set<String> {
                let ids = line.moments ?? []
                let kinds = ids.compactMap { perMoment[$0]?.kind }.filter { Self.conversationKinds.contains($0) }.map { "kind:" + $0 }
                let apps = ids.compactMap { id in moments.first { $0.id == id } }.flatMap(\.apps).filter { !$0.isEmpty }.map { "app:" + $0.lowercased() }
                return Set(kinds + apps)
            }
            func appsOf(_ line: LevelLine) -> Set<String> {
                Set((line.moments ?? []).compactMap { id in moments.first { $0.id == id } }.flatMap(\.apps).map { $0.lowercased() })
            }
            let bare = kept.map { Self.bareLine($0.line.text, apps: appsOf($0.line)) }
            kept = kept.enumerated().filter { i, r in
                guard bare[i] else { return true }
                let mine = facets(r.line)
                return !kept.indices.contains { j in j != i && !bare[j] && !facets(kept[j].line).isDisjoint(with: mine) }
            }.map(\.element)
            // Sends lead (owner 9/28), but they never fill every line while other work ran: at most max-1 of them first.
            let people = kept.filter { $0.tier == 0 }, rest = kept.filter { $0.tier != 0 }
            let lead = rest.isEmpty ? people : Array(people.prefix(Swift.max(1, max - 1)))
            let chosen = (lead + rest + Array(people.dropFirst(lead.count))).prefix(max)
            return chosen.sorted { ($0.tier, -$0.seconds, $0.index) < ($1.tier, -$1.seconds, $1.index) }.map(\.line)
        }
        func mainThread(_ threads: [LevelThread]) -> LevelThread? {
            threads.first { t in !Self.passiveKinds.contains(t.kind) } ?? threads.first
        }
        let threads = plan.threads(for: Set(moments.filter { perMoment[$0.id]?.idle != true }.map(\.id)))
        var blocks = [LiveBlock]()
        let byID = Dictionary(uniqueKeysWithValues: moments.map { ($0.id, $0) })
        for ids in plan.blocks {
            let members = ids.compactMap { byID[$0] }.filter { perMoment[$0.id]?.idle != true }
            guard !members.isEmpty else { continue }
            let bt = plan.threads(for: Set(members.map(\.id)))
            guard let main = mainThread(bt) else { continue }
            blocks.append(LiveBlock(start: members.map(\.start).min()!, end: members.map(\.end).max()!, label: display(main),
                                    moments: ids, mainMoments: main.momentIDs, side: lines(bt, main: main, max: 3).map(\.text)))
        }
        guard let main = mainThread(threads) else {
            return LiveDay(mainTitle: "", mainSeconds: 0, mainKey: "", mainMoments: [], lines: [], blocks: blocks, moments: perMoment)
        }
        return LiveDay(mainTitle: display(main), mainSeconds: main.seconds, mainKey: main.key, mainMoments: main.momentIDs,
                       lines: lines(threads, main: main, max: LiveDay.maxLines), blocks: blocks, moments: perMoment)
    }

    /// The leading CamelCase words every source file name here shares ("ExportView.swift", "ExportTests.swift" ->
    /// "Export"), when there are two files or more and the shared part is a real word (3 letters or more); else nil.
    static func sharedFileName(_ labels: [String]) -> String? {
        let stems = unique(labels.compactMap { label -> String? in
            guard !label.contains(" "), let dot = label.lastIndex(of: "."), dot > label.startIndex else { return nil }
            let ext = label[label.index(after: dot)...]
            guard (1...6).contains(ext.count), ext.allSatisfy(\.isLetter) else { return nil }
            return String(label[..<dot])
        })
        guard stems.count >= 2 else { return nil }
        func words(_ s: String) -> [String] {
            var out = [String](), cur = ""
            for c in s {
                if (c.isUppercase && !cur.isEmpty && !(cur.last?.isUppercase ?? false)) || c == "_" || c == "-" { if !cur.isEmpty { out.append(cur) }; cur = c.isLetter || c.isNumber ? String(c) : "" }
                else { cur.append(c) }
            }
            if !cur.isEmpty { out.append(cur) }
            return out
        }
        let split = stems.map(words)
        var shared = [String]()
        for (i, w) in split[0].enumerated() {
            guard split.allSatisfy({ $0.count > i && $0[i] == w }) else { break }
            shared.append(w)
        }
        let name = shared.joined(separator: " ")
        guard let first = shared.first, first.count >= 3, first.first?.isLetter == true else { return nil }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// A typed row's code-decided send facts (`captureProvenance.unit`): its surface and its recipient or place label.
    func typedSendFacts(_ ids: [String]) throws -> [String: (surface: String?, to: String?)] {
        guard !ids.isEmpty else { return [:] }
        var out = [String: (surface: String?, to: String?)]()
        for row in try rows("SELECT id,coalesce(json_extract(body,'$.captureProvenance.unit.surface'),''),coalesce(json_extract(body,'$.captureProvenance.unit.to'),'') FROM records WHERE id IN (SELECT value FROM json_each(?))", [json(ids)]) {
            out[row[0]] = (row[1].isEmpty ? nil : row[1], row[2].isEmpty ? nil : row[2])
        }
        return out
    }

    static let conversationKinds: Set<String> = ["texts", "email", "slack", "chat"]
    /// Channel names a line carries when code knows no one in the conversation.
    static let bareChannels: Set<String> = ["texts", "messages", "email", "mail", "slack", "teams chat", "activity"]
    /// A line that only names an app or channel and how long ("Texts, ~8 min", "Ghostty, ~20 min"): filler beside a real
    /// line about the same conversation or app (claude/summary-fail-1003). `apps`: its moments' app names, lowercased.
    public static func bareLine(_ text: String, apps: Set<String>) -> Bool {
        let parts = text.components(separatedBy: ", ~")
        guard parts.count > 1 else { return false }
        let name = parts.dropLast().joined(separator: ", ~").trimmingCharacters(in: .whitespaces).lowercased()
        return bareChannels.contains(name) || apps.contains(name)
    }
    static let passiveKinds: Set<String> = ["video"]
    static let sendVerbs = ["Texted", "Emailed", "Messaged", "Asked", "Posted", "Replied", "Forwarded", "Sent", "Submitted"]

    /// "Texted Q7", "Emailed Sam", "Messaged #eng", "Asked Claude", "Posted on X": who only, never words. nil when who is
    /// unknown for a conversation (never "Texted someone"). `label` is the moment's own name (`momentLabel`).
    public static func sendLine(_ a: CanonicalAction, surface: String?, to: String?, label: String) -> String? {
        let host = ThreadEntities.host(a.site)
        let place = surface ?? SendRules.surface(bundle: a.bundle, host: host.isEmpty ? nil : host, title: a.title)
        func name(_ s: String) -> String { s.hasPrefix("#") ? s : ThreadEntities.capitalized(s) }
        let talk = conversationName(label)
        switch place {
        case "text":
            guard let who = to ?? talk else { return nil }
            return "Texted " + name(who)
        case "email":
            // email-1003 (owner decision 2026-10-03): who and the subject code read, quoted: "Emailed Sam — 'Startup credits
            // question'", "Replied to Sam's email 'Demo feedback'" (the compose window's or page's subject, `EmailLines`).
            // Was (fix/sx-all round 2): "Emailed Riley about Launch checklist".
            let titled: Bool = { if case .email? = EmailTitle.kind(a.title) { return true }; return false }()
            if let to, titled { return EmailLines.sent(title: a.title, to: name(to)) }
            if let to, let about = label.range(of: " about ") {
                return EmailLines.sent(to: name(to), subject: String(label[about.upperBound...]), reply: false, forward: false)
            }
            if let to { return EmailLines.sent(to: name(to), subject: nil, reply: false, forward: false) }
            // A reply names what it answered even when code read no recipient (Mail's reply To is filled in, not typed).
            if titled, case .email(let subject, true, _)? = EmailTitle.kind(a.title), TypedSecretScrubber.sensitiveSubject(subject) == nil {
                return EmailLines.sent(to: nil, subject: subject, reply: true, forward: false)
            }
            if label.hasPrefix("Email about ") { return "Emailed about " + label.dropFirst("Email about ".count) }
            return nil
        case "chat":
            guard let who = to ?? talk else { return nil }
            return "Messaged " + name(who)
        case "ai", "aiTool":
            return "Asked " + aiName(a, host: host)
        // terminal-1002: a terminal line run with Return ("submitted" only in a terminal).
        case "code":
            return TypedWords.ranCommandLabel
        case "social":
            guard !host.isEmpty else { return nil }
            return "Posted on " + (ThreadEntities.friendlyHosts[host] ?? host)
        default:
            return nil
        }
    }
    static func aiName(_ a: CanonicalAction, host: String) -> String {
        if host.contains("claude") { return "Claude" }
        if host.contains("chatgpt") || host.contains("openai") { return "ChatGPT" }
        if host.contains("gemini") { return "Gemini" }
        if host.contains("perplexity") { return "Perplexity" }
        let app = a.app.lowercased()
        if app.contains("claude") || a.bundle.lowercased().contains("anthropic") { return "Claude" }
        if app.contains("chatgpt") || a.bundle.lowercased().contains("openai") { return "ChatGPT" }
        if app.contains("codex") { return "Codex" }
        return a.app.isEmpty ? "an AI app" : a.app
    }
    /// The conversation a "Texts with …" or "Messages" label names, or nil.
    static func conversationName(_ label: String) -> String? {
        for prefix in ["Texts with ", "Email with ", "Slack with ", "Slack in ", "Teams chat with "] where label.hasPrefix(prefix) {
            var rest = String(label.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if let about = rest.range(of: " about ") { rest = String(rest[..<about.lowerBound]) }
            return rest.isEmpty ? nil : rest
        }
        return nil
    }
    /// A moment's name by code: who and what it is about from its own windows (a conversation's person, place or email
    /// subject; the file open in the editor), else its thread entity's label, cleaned (TitleClean). Never a raw window
    /// title. A thread's entity names the whole thread (every email moment shares one), so a conversation is named from
    /// the moment's own window and its own typed rows' recipient labels only.
    static func momentLabel(_ entity: ThreadEntity?, moment m: ActivityNote, actions: [CanonicalAction], who: [String]) -> String {
        let app = actions.first(where: { !$0.app.isEmpty })?.app ?? m.apps.first(where: { !$0.isEmpty }) ?? ""
        let site = m.sites.first ?? ""
        guard let e = entity else { return TitleClean.clean(m.subject, app: app, site: site) }
        // The moment's own window: its last titled action that isn't a typed row (a typed row's title is its place).
        let window = actions.last(where: { $0.kind != "keyboard.text_input" && !$0.title.isEmpty }) ?? actions.last(where: { !$0.title.isEmpty })
        let own = window.map { ThreadEntities.entity(app: $0.app, bundle: $0.bundle, site: $0.site, title: $0.title) }
        let named = unique(who.filter { !$0.isEmpty })
        func person(_ s: String) -> String { s.hasPrefix("#") ? s : ThreadEntities.capitalized(s) }
        switch e.kind {
        case "texts":
            // An anonymous Messages moment must not acquire a title from an
            // unclassified typed field or a neighboring conversation.
            if e.raw.hasPrefix("texts:?") { return "Texts" }
            var people = !named.isEmpty ? named : own?.kind == "texts" ? own!.people : []
            if people.isEmpty { people = named.filter { !$0.hasPrefix("#") } }
            if people.isEmpty, let window {
                // A group chat's own name ("Q7"): the conversation the Messages window shows.
                let title = TitleClean.clean(window.title, app: window.app, site: window.site)
                if !title.isEmpty, title.lowercased() != window.app.lowercased(), !["messages", "new message", "imessage"].contains(title.lowercased()) { people = [title] }
            }
            return people.isEmpty ? "Texts" : "Texts with " + LevelThreads.names(people.map(person))
        case "email":
            let people = named.filter { !$0.hasPrefix("#") }.map(person)
            var subject = own?.kind == "email" ? own!.places.first.map { TitleClean.clean($0) } : nil
            // A reply written in a compose window (its title is the site): the thread's one subject, when it has one.
            if subject?.isEmpty ?? true, !people.isEmpty, e.places.count == 1 { subject = TitleClean.clean(e.places[0]) }
            switch (people.isEmpty, subject?.isEmpty ?? true) {
            case (false, false): return "Email with " + LevelThreads.names(people) + " about " + subject!
            case (false, true): return "Email with " + LevelThreads.names(people)
            case (true, false): return "Email about " + subject!
            case (true, true): return "Email"
            }
        case "slack":
            if let own, own.kind == "slack", own.label != "Slack" { return TitleClean.label(own.label) }
            if let first = named.first { return first.hasPrefix("#") ? "Slack in " + first : "Slack with " + person(first) }
            return "Slack"
        case "chat":
            let people = own?.kind == "chat" && !own!.people.isEmpty ? own!.people : named
            return people.isEmpty ? TitleClean.label(e.label) : "Teams chat with " + LevelThreads.names(people.map(person))
        case "meeting":
            // A call with no name of its own is the app's meeting ("Zoom meeting"), not a bare "Meeting".
            if e.label == "Meeting" || e.label.isEmpty { return app.isEmpty ? "Meeting" : app + " meeting" }
            return TitleClean.label(ThreadEntities.capitalized(e.label))
        case "code":
            // The file open in the editor ("ExportView.swift — daydream"), else the project's code.
            if let window, window.app.lowercased() == "xcode" || window.bundle.lowercased() == "com.apple.dt.xcode" {
                if let file = window.title.components(separatedBy: " — ").first?.trimmingCharacters(in: .whitespaces),
                   file.contains("."), !file.contains(" "), file.count <= 60 { return file }
            }
            return TitleClean.label(ThreadEntities.capitalized(e.label))
        default:
            let label = TitleClean.label(ThreadEntities.capitalized(e.label))
            return label.isEmpty ? TitleClean.clean(m.subject, app: app, site: site) : label
        }
    }
    /// A written note's send lines (ready, else the previous note shown while a newer one is written).
    static func noteSendLines(_ m: ActivityNote) -> [String] {
        guard let note = m.generated ?? m.previous else { return [] }
        return note.output.bullets.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { t in sendVerbs.contains { t.hasPrefix($0 + " ") } }
            .map { t in var x = t; while x.hasSuffix(".") { x.removeLast() }; return x }
    }
    static func unique(_ values: [String]) -> [String] { var seen = Set<String>(); return values.filter { seen.insert($0).inserted } }

    /// Every level's notes that match `query` (each word must start a word of the text: "email" finds "Emailed"), newest
    /// first, then the higher level first. Every month, week, day and block hit; at most `limit` moment and line hits. The same match as the MCP `recall` search (LevelRecall.recallSearch), as values.
    /// Typed words never match here (the notes about them do); in the app, `ownerTypedSearch` matches them on this Mac only.
    public func noteSearch(_ query: String, timezone: String, now: Date = Date(), limit: Int = 40) throws -> [NoteHit] {
        let words = Self.folded(query)
        guard !words.isEmpty else { return [] }
        var hits = [NoteHit]()
        var titles = [String: (String, String)]()
        func child(_ ref: LevelChildRef) -> NoteChild? {
            if let known = titles[ref.id] { return NoteChild(level: known.0, title: known.1, start: ref.start) }
            if let n = try? levelNote(ref.id) { titles[ref.id] = (n.level.rawValue, n.title); return NoteChild(level: n.level.rawValue, title: n.title, start: ref.start) }
            if let body = try? rows("SELECT body FROM generated_notes WHERE id=? ORDER BY version DESC LIMIT 1", [ref.id]).first?.first,
               let g = try? decode(GeneratedNote.self, body) {
                titles[ref.id] = ("moment", g.output.title); return NoteChild(level: "moment", title: g.output.title, start: ref.start)
            }
            return nil
        }
        for note in try allLevelNotes() {
            let open = note.level.rawValue + ":" + (note.level == .block ? note.id : note.period)
            let day: String
            switch note.level {
            case .block, .day: day = note.period
            case .week, .month: day = (try? DayScope.key(timestamp(note.end) ?? now, timezone: timezone)) ?? note.period
            }
            var hit: NoteHit?
            if let line = note.lines.first(where: { Self.recallMatches(words, $0.text) }) {
                hit = NoteHit(level: note.level.rawValue, text: line.text, inTitle: note.title, at: note.start, day: day, open: open)
            } else if Self.recallMatches(words, note.title) || Self.recallMatches(words, note.title + " " + note.lines.map(\.text).joined(separator: " ")) {
                hit = NoteHit(level: note.level.rawValue, text: note.title, inTitle: nil, at: note.start, day: day, open: open)
            }
            if var hit {
                hit.noteTitle = note.title; hit.lines = note.lines.map(\.text); hit.end = note.end
                hit.children = note.children.sorted { $0.start < $1.start }.compactMap(child)
                hits.append(hit)
            }
        }
        if try hasActionLayers() {
            for row in try rows("SELECT g.body FROM generated_notes g WHERE g.version=(SELECT max(version) FROM generated_notes h WHERE h.id=g.id) AND g.id NOT LIKE 'day_%'") {
                guard let note = try? decode(GeneratedNote.self, row[0]) else { continue }
                // fix/perf7: match first. Only a note that matches reads its actions' times (a query per note, for
                // every note, on every search: most of a search's cost with thousands of moments).
                let matchedLines = note.output.bullets.filter { Self.recallMatches(words, $0.text) }
                guard !matchedLines.isEmpty || Self.recallMatches(words, note.output.title + " " + note.output.bullets.map(\.text).joined(separator: " ")) else { continue }
                let times = try rows("SELECT id,json_extract(body,'$.at') FROM records WHERE id IN (SELECT value FROM json_each(?))", [json(note.actionIDs)])
                var at = [String: String](); for r in times { at[r[0]] = r[1] }
                guard let first = at.values.min() else { continue }
                let day = (try? DayScope.key(timestamp(first) ?? now, timezone: timezone)) ?? ""
                let open = "moment:\(note.id)@\(day)"
                var matched = false
                for b in matchedLines {
                    let cited = b.actionIDs.filter { at[$0] != nil }.min { at[$0]! < at[$1]! }
                    let t = cited.flatMap { at[$0] } ?? first
                    hits.append(NoteHit(level: "line", text: b.text, inTitle: note.output.title, at: t, day: day, open: open,
                                        momentID: note.id, actionID: cited ?? note.actionIDs.first, state: b.assertion,
                                        noteTitle: note.output.title, lines: note.output.bullets.map(\.text)))
                    matched = true
                }
                if !matched, Self.recallMatches(words, note.output.title + " " + note.output.bullets.map(\.text).joined(separator: " ")) {
                    let firstID = at.min { $0.value < $1.value }?.key
                    hits.append(NoteHit(level: "moment", text: note.output.title, inTitle: nil, at: first, day: day, open: open,
                                        momentID: note.id, actionID: firstID,
                                        noteTitle: note.output.title, lines: note.output.bullets.map(\.text)))
                }
            }
        }
        let rank = ["month": 0, "week": 1, "day": 2, "block": 3, "moment": 4, "line": 5]
        // Every month, week, day and block hit is kept (notes aren't paged, so a dropped one never comes back); the cap
        // applies to moment and line hits only, newest first.
        var moments = 0
        return hits.sorted { a, b in
            if a.day != b.day { return a.day > b.day }
            if a.level != b.level { return (rank[a.level] ?? 9) < (rank[b.level] ?? 9) }
            return a.at > b.at
        }.filter { hit in
            guard hit.level == "moment" || hit.level == "line" else { return true }
            moments += 1
            return moments <= limit
        }
    }
}

/// claude/summary-fail-1003 (owner 10/3): a day card lists one entry per conversation; a bare channel line with only its
/// minutes ("Texts, ~8 min") goes when another line is about the same channel ("Texts with Q7 and Jamie Lin, ~1 min",
/// "Texted Sam about dinner"). Words only, for stored day notes; the live lines also know apps (`MemoryStore.bareLine`).
public enum DayLineFiller {
    /// The conversation channel a line is about, or nil.
    public static func channel(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        let name = t.components(separatedBy: ", ~").first ?? t
        let lower = name.lowercased()
        if ["texts", "messages"].contains(lower) || t.hasPrefix("Texts with ") || t.hasPrefix("Texted ") { return "texts" }
        if ["email", "mail"].contains(lower) || t.hasPrefix("Email with ") || t.hasPrefix("Email about ") || t.hasPrefix("Emailed ") || t.hasPrefix("Replied to ") { return "email" }
        if lower == "slack" || t.hasPrefix("Slack with ") || t.hasPrefix("Slack in ") || t.hasPrefix("Messaged #") { return "slack" }
        if lower == "teams chat" || t.hasPrefix("Teams chat with ") { return "chat" }
        return nil
    }
    /// Which lines stay: every line, except a bare channel line beside a real line about the same channel.
    public static func keep(_ texts: [String]) -> [Bool] {
        let bare = texts.map { MemoryStore.bareLine($0, apps: []) }
        let channels = texts.map(channel)
        return texts.indices.map { i in
            guard bare[i], let c = channels[i] else { return true }
            return !texts.indices.contains { j in j != i && !bare[j] && channels[j] == c }
        }
    }
}
