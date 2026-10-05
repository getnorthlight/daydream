import Foundation
import MemoryCore

// summaries/v3 levels in the Today page (memory-levels plan: no new elements, only grouping and copy):
// - the day note (L4) is the summary card's headline and its first three lines;
// - on a past day, the week note (L5) is one line above it;
// - blocks (L3) replace Morning / Afternoon / Evening as the list's section headers (name, count, time range) and show
//   as bands behind the ribbon;
// - a row's second line is its intent line: the sent or asked line first, then a drafted one, then the first line.
// Values only: built from the day read (`ActionDay.levels`) like everything else in TodaySnapshot.

/// A summary line and the moments it is about (threads carry them; older lines resolve their children), so clicking
/// it highlights exactly those moments.
public struct LevelBullet: Equatable, Sendable {
    public let text: String
    public let moments: [String]
    public init(text: String, moments: [String]) { self.text = text; self.moments = moments }
}

/// One block (L3) as the Focus List and the ribbon draw it.
public struct LevelBlockSlice: Identifiable, Equatable, Sendable {
    public let id: String
    /// The goal the header names ("Fixing the export crash"): the block title without its code-written span.
    public let name: String
    /// The whole stored title ("About 2 hours: fixing the export crash").
    public let title: String
    public let start: Date, end: Date
    public let momentIDs: [String]
    public let lines: [String]
    /// Threads (Preview 4): the block's side threads ("Texts with Maya and Sam, ~10 min"), drawn as one quiet line under
    /// its header. Empty when the block has one thread, or was written before threads.
    public let sideThreads: [String]
    /// Each side thread's moments (parallel to `sideThreads`), and the main thread's (the header's).
    public let sideThreadMoments: [[String]]
    public let mainMoments: [String]
    public init(id: String, name: String, title: String, start: Date, end: Date, momentIDs: [String], lines: [String], sideThreads: [String] = [],
                sideThreadMoments: [[String]] = [], mainMoments: [String]? = nil) {
        self.id = id; self.name = name; self.title = title; self.start = start; self.end = end; self.momentIDs = momentIDs; self.lines = lines
        self.sideThreads = sideThreads; self.sideThreadMoments = sideThreadMoments; self.mainMoments = mainMoments ?? momentIDs
    }
}

/// A day's level notes, as the page shows them.
public struct DayLevelSlice: Equatable, Sendable {
    /// The day note (L4): its headline and lines. nil while it isn't written.
    public let dayTitle: String?
    public let dayLines: [String]
    public let blocks: [LevelBlockSlice]
    /// The week note (L5): "Week of Sep 14 to 20" and its headline. nil while it isn't written.
    public let weekLabel: String?
    public let weekTitle: String?
    /// The day note's lines with the moments each is about, and the headline's (the main thread's) moments.
    public let dayBullets: [LevelBullet]
    public let headlineMoments: [String]
    /// The main thread's focused time ("~2 hr 25 min"), shown beside the headline so the day reads with its bullets.
    /// nil without threads.
    public let headlineDuration: String?
    /// fix/day-card: the headline is the day's threads by code (`LiveDay`), not a stored day note (none yet, or its main
    /// thread is no longer the day's).
    public var dayIsLive: Bool = false
    public init(dayTitle: String?, dayLines: [String], blocks: [LevelBlockSlice], weekLabel: String?, weekTitle: String?,
                dayBullets: [LevelBullet]? = nil, headlineMoments: [String] = [], headlineDuration: String? = nil, dayIsLive: Bool = false) {
        self.headlineDuration = headlineDuration; self.dayIsLive = dayIsLive
        self.dayTitle = dayTitle; self.dayLines = dayLines; self.blocks = blocks; self.weekLabel = weekLabel; self.weekTitle = weekTitle
        self.dayBullets = dayBullets ?? dayLines.map { LevelBullet(text: $0, moments: []) }; self.headlineMoments = headlineMoments
    }

    /// fix/day-card: the day note is the headline while its main thread is the day's main thread by code (or nothing
    /// live says otherwise); else the day's threads (`LiveDay`). Stored blocks keep their notes; the moments no stored
    /// block holds join the stored block whose stretch they continue, or show under their live block's name.
    public static func make(_ levels: DayLevels?, calendar: Calendar) -> DayLevelSlice? { made(levels, calendar: calendar)?.shown() }
    /// claude/dayeval-1005 (owner 10/05): the slice as shown, never "draft" (`DisplayWords.undraft`), after every rule
    /// above read the stored words.
    func shown() -> DayLevelSlice {
        let u = DisplayWords.undraft
        let shownBlocks = blocks.map { b in
            LevelBlockSlice(id: b.id, name: u(b.name), title: u(b.title), start: b.start, end: b.end, momentIDs: b.momentIDs, lines: b.lines.map(u),
                            sideThreads: b.sideThreads.map(u), sideThreadMoments: b.sideThreadMoments, mainMoments: b.mainMoments)
        }
        return DayLevelSlice(dayTitle: dayTitle.map(u), dayLines: dayLines.map(u), blocks: shownBlocks, weekLabel: weekLabel, weekTitle: weekTitle.map(u),
                             dayBullets: dayBullets.map { LevelBullet(text: u($0.text), moments: $0.moments) }, headlineMoments: headlineMoments,
                             headlineDuration: headlineDuration, dayIsLive: dayIsLive)
    }
    static func made(_ levels: DayLevels?, calendar: Calendar) -> DayLevelSlice? {
        guard let levels, levels.day != nil || !levels.blocks.isEmpty || levels.week != nil || levels.live != nil else { return nil }
        var blocks = levels.blocks.compactMap { note -> LevelBlockSlice? in
            guard let s = timestamp(note.start), let e = timestamp(note.end) else { return nil }
            let side = LevelWords.sideThreadLines(note)
            return LevelBlockSlice(id: note.id, name: LevelWords.blockName(note.title), title: note.title, start: s, end: max(s, e),
                                   momentIDs: note.children.map(\.id), lines: note.lines.map(\.text), sideThreads: side.map(\.text),
                                   sideThreadMoments: side.map { $0.moments ?? $0.children }, mainMoments: note.threads?.first?.momentIDs)
        }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        if let live = levels.live { blocks = liveBlocks(live, stored: blocks) }
        // A line's moments: the ones it carries (threads), else its children, a block standing for its moments.
        var blockMoments = [String: [String]]()
        for b in blocks { blockMoments[b.id] = b.momentIDs }
        func moments(_ line: LevelLine) -> [String] {
            var out = [String]()
            for id in line.moments ?? line.children.flatMap({ blockMoments[$0] ?? [$0] }) where !out.contains(id) { out.append(id) }
            return out
        }
        let weekLabel = levels.week.map { LevelWords.weekLabel($0, calendar: calendar) }
        let weekTitle = levels.week.map { LevelWords.sentence($0.title) }
        if let live = levels.live, !live.mainTitle.isEmpty, !dayNoteFits(levels.day, live: live) {
            let lines = LevelWords.oneEntryPerConversation(live.lines.map { LevelBullet(text: LevelWords.sentence($0.text), moments: $0.moments ?? []) })
            return DayLevelSlice(dayTitle: live.mainTitle, dayLines: lines.map(\.text), blocks: blocks, weekLabel: weekLabel, weekTitle: weekTitle,
                                 dayBullets: lines, headlineMoments: live.mainMoments,
                                 headlineDuration: live.mainSeconds >= LevelThreads.minBullet ? live.mainDuration : nil, dayIsLive: true)
        }
        let headline = levels.day?.threads?.first?.momentIDs ?? blocks.flatMap(\.momentIDs)
        // Communications first (a sent or asked line, a conversation), then the rest as written.
        let bullets = LevelWords.oneEntryPerConversation(LevelWords.sendsFirst(levels.day?.lines.map { LevelBullet(text: $0.text, moments: moments($0)) } ?? []))
        return DayLevelSlice(dayTitle: levels.day.map(Self.dayTitle), dayLines: bullets.map(\.text),
                             blocks: blocks, weekLabel: weekLabel, weekTitle: weekTitle,
                             dayBullets: bullets, headlineMoments: headline,
                             headlineDuration: levels.day?.threads?.first.flatMap { $0.seconds >= LevelThreads.minBullet ? LevelThreads.duration($0.seconds) : nil })
    }

    /// The stored day note's headline. A model title that only says what was open ("Had the Q3 investor update open in
    /// Google Docs.", real Qwen 3.5 4B, 9/24) gives way to the note's own main thread as stored (its name already went
    /// through the typed check when the note was saved, so nothing typed comes back).
    static func dayTitle(_ note: LevelNote) -> String {
        if DaydreamNotes.isFiller(note.title, apps: []), let main = note.threads?.first?.label, !main.isEmpty { return LevelWords.sentence(main) }
        return LevelWords.sentence(note.title)
    }

    /// The stored day note still fits the day: nothing live to compare, or its main thread is the day's main thread now.
    /// A note written before threads can't say which thread it is about, so on a day with live threads it gives way; so
    /// does a note saved plain (kinds only, "Document"), which says less than the threads by code.
    static func dayNoteFits(_ day: LevelNote?, live: LiveDay) -> Bool {
        guard let day, !DayLevels.savedPlain(day) else { return false }
        guard let key = day.threads?.first?.key else { return false }
        return key == live.mainKey
    }

    /// Stored blocks keep their notes (stale-while-updating). A live block's moments that no stored block holds join the
    /// stored block holding most of its other moments (the stretch it continues); a live block no stored block touches
    /// shows under its own live name and side lines.
    static func liveBlocks(_ live: LiveDay, stored: [LevelBlockSlice]) -> [LevelBlockSlice] {
        var blocks = stored
        var owner = [String: Int]()
        for (i, b) in blocks.enumerated() { for id in b.momentIDs where owner[id] == nil { owner[id] = i } }
        for lb in live.blocks {
            guard let s = timestamp(lb.start), let e = timestamp(lb.end) else { continue }
            let loose = lb.moments.filter { owner[$0] == nil && live.moments[$0]?.idle != true }
            guard !loose.isEmpty else { continue }
            let held = Dictionary(lb.moments.compactMap { owner[$0] }.map { ($0, 1) }, uniquingKeysWith: +)
            if let (index, _) = held.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) }) {
                let b = blocks[index]
                blocks[index] = LevelBlockSlice(id: b.id, name: b.name, title: b.title, start: min(b.start, s), end: max(b.end, e),
                                                momentIDs: b.momentIDs + loose, lines: b.lines, sideThreads: b.sideThreads,
                                                sideThreadMoments: b.sideThreadMoments, mainMoments: b.mainMoments)
                for id in loose { owner[id] = index }
            } else {
                blocks.append(LevelBlockSlice(id: "live:" + lb.start, name: LevelWords.blockName(lb.label), title: lb.label, start: s, end: max(s, e),
                                              momentIDs: loose, lines: lb.side, sideThreads: lb.side,
                                              sideThreadMoments: lb.side.map { _ in [] }, mainMoments: lb.mainMoments))
                for id in loose { owner[id] = blocks.count - 1 }
            }
        }
        return blocks.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }
}

public enum LevelWords {
    /// The code-written front of a block title (MemoryStore.spanPhrase): "About 2 hours", "Most of the afternoon", ...
    static let spanFronts = ["About ", "A few minutes", "Most of the ", "A stretch"]
    /// "About 2 hours: fixing the export crash" → "Fixing the export crash". A title without the span stays as it is.
    public static func blockName(_ title: String) -> String {
        let title = cleanName(title)
        guard let colon = title.range(of: ": "), spanFronts.contains(where: { title.hasPrefix($0) }) else { return title }
        let goal = cleanName(String(title[colon.upperBound...]))
        guard let first = goal.first else { return title }
        return first.uppercased() + goal.dropFirst()
    }
    /// Owner 10/2: a bracket title made from a window title says what it was about, on every day, stored notes included:
    /// no terminal spinner or bell marks ("✳ ", "◐ "), no "[sensitive title omitted]", and no trailing "code" a
    /// terminal's process name left ("✳ Tallybird app design review code" → "Tallybird app design review").
    public static func cleanName(_ raw: String) -> String {
        var t = raw
        for withheld in CardTitle.withheld { t = t.replacingOccurrences(of: withheld, with: " ") }
        t = t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let c = t.unicodeScalars.first, !CharacterSet.alphanumerics.contains(c) && !"\"'(“‘#~/".unicodeScalars.contains(c) {
            t = String(t.unicodeScalars.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        let words = t.split(separator: " ")
        if words.count >= 2, words.last == "code",
           !["the", "a", "an", "of", "your", "my", "this", "that", "to", "in", "for", "new", "source", "with", "our", "some", "claude", "vs", "studio"]
            .contains(words[words.count - 2].lowercased()) {
            t = words.dropLast().joined(separator: " ")
        }
        if t.isEmpty || t.lowercased() == "code" { return "Activity" }
        return t.prefix(1).uppercased() + t.dropFirst()
    }
    /// A threaded block's side-thread bullets (its lines when it has more than one thread; with one, its lines are
    /// its moments' own and none is a side thread).
    public static func sideThreads(_ note: LevelNote) -> [String] { sideThreadLines(note).map(\.text) }
    /// fix/sx-all round 1: every side thread, its sent or asked line when it has one ("Emailed Sam about pricing"), sends
    /// first and passive viewing last; before, only the ones with minutes showed.
    static func sideThreadLines(_ note: LevelNote) -> [LevelLine] {
        guard let threads = note.threads, threads.count > 1 else { return [] }
        func rank(_ t: String) -> Int {
            if sentLeads.contains(where: { t.hasPrefix($0 + " ") }) { return 0 }
            if draftLeads.contains(where: { t.hasPrefix($0 + " ") }) { return 1 }
            let passive = ["YouTube", "Netflix", "Vimeo", "Twitch", "Music", "Spotify"]
            return passive.contains(where: { t.hasPrefix($0) }) ? 3 : 2
        }
        return note.lines.enumerated().sorted { (rank($0.element.text), $0.offset) < (rank($1.element.text), $1.offset) }.map(\.element)
    }
    /// A headline without its closing period (the card draws titles bare, like the moment titles).
    public static func sentence(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix(".") { t.removeLast() }
        return t
    }
    /// "Week of Sep 14 to 20", or "Week of Sep 28 to Oct 4" across a month.
    public static func weekLabel(_ note: LevelNote, calendar: Calendar) -> String {
        guard let a = timestamp(note.start) else { return "This week" }
        return weekLabel(containing: a, timeZone: TimeZone(identifier: note.timezone) ?? calendar.timeZone)
    }
    /// "Week of Sep 14 to 20" for the ISO week (Monday to Sunday) that holds `a`.
    public static func weekLabel(containing a: Date, timeZone: TimeZone) -> String {
        // The ISO week's Monday and Sunday (the week key's days), not the first and last activity.
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = timeZone
        let start = iso.dateInterval(of: .weekOfYear, for: a)?.start ?? a
        let end = iso.date(byAdding: .day, value: 6, to: start) ?? a
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = iso.timeZone
        f.dateFormat = "MMM d"
        let left = f.string(from: start)
        let sameMonth = iso.component(.month, from: start) == iso.component(.month, from: end)
        f.dateFormat = sameMonth ? "d" : "MMM d"
        return "Week of " + left + " to " + f.string(from: end)
    }

    /// Verbs that mean the send key was seen (validator9's send leads) or a question went to an AI.
    static let sentLeads = ["Asked", "Emailed", "Texted", "Messaged", "Replied", "Posted", "Searched", "Sent", "Submitted", "Approved"]
    static let draftLeads = ["Drafted", "Wrote", "Typed", "Noted", "Listed"]

    /// Sends and conversations first ("Texted Q7 about Friday dinner", "Texts with Q7, ~10 min"), then the rest in order.
    static func sendsFirst(_ bullets: [LevelBullet]) -> [LevelBullet] {
        let talk = ["Texts with ", "Email with ", "Email about ", "Slack with ", "Slack in ", "Teams chat with "]
        let isSend: (LevelBullet) -> Bool = { b in
            sentLeads.contains { b.text.hasPrefix($0 + " ") } || talk.contains { b.text.hasPrefix($0) }
        }
        return bullets.filter(isSend) + bullets.filter { !isSend($0) }
    }

    /// claude/summary-fail-1003 (owner 10/3): one entry per conversation; no bare "Texts, ~8 min" beside a real Texts line.
    public static func oneEntryPerConversation(_ bullets: [LevelBullet]) -> [LevelBullet] {
        let keep = DayLineFiller.keep(bullets.map(\.text))
        return bullets.enumerated().filter { keep[$0.offset] }.map(\.element)
    }

    /// The row's second line: the sent or asked line first, then a drafted one, then the first line.
    public static func intentLine(_ bullets: [MomentBullet]) -> String? {
        let own = bullets.filter { !$0.correction && !$0.text.isEmpty }
        func leads(_ verbs: [String]) -> MomentBullet? {
            own.first { b in verbs.contains { b.text.hasPrefix($0 + " ") } }
        }
        return (leads(sentLeads) ?? leads(draftLeads) ?? own.first)?.text
    }
}

extension FocusListLayout {
    /// "Nothing recorded this day." only when the day has nothing to show: no moment, no action, and (on a past day) no
    /// kept day note. Moments expire before the day note above them (it is frozen, kept as written), so such a past day
    /// shows its summary card with that note. A week note alone is not the day's: a day with nothing in it used to show a
    /// card holding only "Week of Sep 28 to Oct 4" and the week's headline over an empty ribbon, which read as a broken
    /// week view (owner 10/2).
    public static func showsEmptyCard(_ snap: TodaySnapshot, isToday: Bool) -> Bool {
        guard snap.moments.isEmpty && snap.actionCount == 0 else { return false }
        return isToday || snap.levels?.dayTitle == nil
    }
    /// A block's side threads in one line: "Texts with Maya and Sam, ~10 min · Slack with Priya and #eng, ~9 min".
    public static func sideThreadsLine(_ block: LevelBlockSlice) -> String {
        block.sideThreads.map { LevelWords.sentence($0) }.joined(separator: "  ·  ")
    }
    /// A block header as VoiceOver reads it: "Fixing the export crash, 4 moments, 9:02 to 10:40 AM".
    public static func blockHeaderAccessibilityLabel(_ block: LevelBlockSlice, count: Int, timeZone: TimeZone) -> String {
        block.name + ", " + DaydreamFormat.count(count) + (count == 1 ? " moment" : " moments") + ", "
            + DaydreamFormat.spokenRange(block.start, block.end, timeZone)
    }
    /// Sections when the day has blocks: one per block (its moments, newest first), and Morning / Afternoon / Evening
    /// for moments no block holds yet (the newest stretch of today, a moment still without a note). Newest first.
    /// Loose moments are grouped by part only within a run between the same two blocks, so a loose row never sits
    /// above a block that is later than it.
    public static func sections(_ moments: [MomentSlice], blocks: [LevelBlockSlice], calendar: Calendar) -> [FocusListSection] {
        guard !blocks.isEmpty else { return sections(moments, calendar: calendar) }
        var owner = [String: LevelBlockSlice]()
        for b in blocks { for id in b.momentIDs where owner[id] == nil { owner[id] = b } }
        var groups = [(key: Date, section: FocusListSection)]()
        var shown = [LevelBlockSlice]()
        for b in blocks {
            let rows = moments.filter { owner[$0.id]?.id == b.id }.sorted { ($0.start, $0.id) > ($1.start, $1.id) }
            guard !rows.isEmpty else { continue }
            shown.append(b)
            groups.append((rows.map(\.start).max()!, FocusListSection(block: b, part: DaydreamFormat.dayPart(b.start, calendar: calendar), moments: rows)))
        }
        // Runs of loose moments, newest first: a run ends at a block's row, or where a shown block's start or end falls
        // between two loose moments.
        let boundaries = shown.flatMap { [$0.start, $0.end] }
        var runs = [[MomentSlice]](), run = [MomentSlice]()
        for m in moments.sorted(by: { ($0.start, $0.id) > ($1.start, $1.id) }) {
            if owner[m.id] != nil {
                if !run.isEmpty { runs.append(run); run = [] }
                continue
            }
            if let previous = run.last, boundaries.contains(where: { $0 > m.start && $0 < previous.start }) { runs.append(run); run = [] }
            run.append(m)
        }
        if !run.isEmpty { runs.append(run) }
        for (index, loose) in runs.enumerated() {
            for s in sections(loose, calendar: calendar) {
                groups.append((s.moments.map(\.start).max() ?? .distantPast, FocusListSection(part: s.part, moments: s.moments, run: index)))
            }
        }
        return groups.sorted { $0.key > $1.key }.map(\.section)
    }
}
