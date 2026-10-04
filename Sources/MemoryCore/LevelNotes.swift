import Foundation

// Levels of memory (summaries/v3). A moment note (L2, `generated_notes`) is written from actions; its bullets are the
// send lines (L1). Above it, each level is written only from the level below and links down to its children:
//
//   L3 block  - a 1-3 hour stretch of moments grouped by goal ("Most of the afternoon: making summaries smarter")
//   L4 day    - the day, from its blocks
//   L5 week   - the week, from its days; month, from its weeks
//
// Rules (NOTES.md has the why):
// - Rebuild: a level note stores the children it was written from (id + version). When the children a target would have
//   now differ (a moment grew, a block was added), the note is stale and the scheduler writes it again. Frozen notes are
//   never rebuilt.
// - Delete: deleting an action, a moment, a correction, or "Forget what I typed" deletes every block whose moments cite
//   it, and every note above it (they are rebuilt from what is left). Forget also deletes every level note written from
//   typed rows, frozen or not.
// - Retention: when history expires, blocks go with their moments; the day, week and month above them are frozen
//   (kept as written, never rebuilt). Day notes are kept 400 days; week and month notes until deleted. A change of the
//   keep period, a restore or a reset clears every level note.
public enum LevelKind: String, Codable, CaseIterable, Sendable {
    case block, day, week, month
    /// The level below, whose notes this one is written from ("moment" for a block).
    public var childKind:String { switch self { case .block: "moment"; case .day: "block"; case .week: "day"; case .month: "week" } }
    var alias:String { switch self { case .block: "m"; case .day: "b"; case .week: "d"; case .month: "w" } }
    /// Output budget in tokens, and the evidence budget in characters (about 4 per token).
    public var maxTokens:Int { switch self { case .block: 200; case .day: 250; case .week, .month: 300 } }
    public var evidenceChars:Int { switch self { case .block: 8000; case .day, .week, .month: 6000 } }
    public var maxLines:Int { self == .block ? 3 : 5 }
}
public struct LevelLine: Codable, Equatable, Sendable {
    public var text:String
    /// Child note ids this line is written from.
    public var children:[String]
    /// Threads: the moments this line is about, at any level (a day's "Texts with Maya and Sam" names the texting
    /// moments, not the blocks they sit in), so clicking it can highlight exactly them. nil on lines written before threads.
    public var moments:[String]?=nil
    public init(text:String,children:[String],moments:[String]?=nil) { self.text=text; self.children=children; self.moments=moments }
}
public struct LevelChildRef: Codable, Equatable, Sendable {
    public var id:String
    public var version:String
    public var start:String
    public var end:String
}
public struct LevelNote: Codable, Equatable, Sendable {
    public var id:String
    public var level:LevelKind
    /// 2026-09-22 (block, day), 2026-W39 (week), 2026-09 (month).
    public var period:String
    public var timezone:String
    public var start:String
    public var end:String
    /// Block: "<span>: <goal>". Day, week, month: one headline sentence.
    public var title:String
    public var lines:[LevelLine]
    public var children:[LevelChildRef]
    /// Blocks only: every action their moments cover (deletes find blocks by action).
    public var actionIDs:[String]
    public var inputRevision:String
    /// Written from notes that cite typed rows (Forget deletes it, frozen or not).
    public var typedDerived:Bool
    public var frozen:Bool
    public var generator:String
    public var generatorVersion:String
    public var generatedAt:String
    public var version:Int
    /// Blocks and days written with threads (LevelThreads): the threads they were written from, most focus first. nil on
    /// notes written before threads (and on weeks and months).
    public var threads:[LevelThread]? = nil
    /// notes-quality: when the model wrote this note's title (a code rewrite that keeps it carries the time on). Today's
    /// day note asks the model again only 2 hours after it.
    public var titledAt:String? = nil
}
/// One child as the writer sees it.
public struct LevelChildView: Codable, Equatable, Sendable {
    public var alias:String
    public var ref:LevelChildRef
    /// A plain local label: "2:05 PM to 2:40 PM" or "Tuesday, September 22".
    public var label:String
    public var title:String
    public var lines:[String]
    public var typed:Bool
}
public struct LevelRequest: Codable, Equatable, Sendable {
    public var target:String
    public var level:LevelKind
    public var period:String
    public var timezone:String
    public var start:String
    public var end:String
    public var children:[LevelChildView]
    public var actionIDs:[String]
    public var inputRevision:String
    /// Blocks and days: the threads (most focus first; the first is the main thread). nil: written the older way
    /// (weeks and months, and a day with a block written before threads).
    public var threads:[LevelThread]? = nil
    /// notes-quality: today's day note while its headline is under 2 hours old: code writes the new bullets and keeps that
    /// headline when it still holds (`LevelGrounding.check`), with no model call.
    public var keptTitle:String? = nil
    /// A one-child block is written by code: there is nothing to group. So is today's day note between model headlines.
    /// notes-quality: so is a block whose moments only had things open ("About 5 minutes."): a model would guess a goal.
    public var codeOnly:Bool {
        level == .block && (children.count == 1 || children.allSatisfy { $0.lines.allSatisfy(LevelGrounding.passive) }) || keptTitle != nil
            // fix/sx-all round 1: a week or month of one day or week says its child's headline (the main thread); a model
            // picked a one-minute side email for it.
            || ((level == .week || level == .month) && children.count == 1)
    }
}
public enum LevelWriterVersion {
    public static let prompt="levels-prompt1-validator1"
    public static let extractive="code/extractive"
    /// The generator version of a block or day written with threads (code bullets; the model writes the title only).
    public static let threads="levels-"+LevelThreads.version
}

/// Checks only: called in `commitLevel` after the checks and before the write lock, the window in which a Forget on
/// another connection can commit. Nothing listens in the app.
public enum LevelCommitWindow {
    private static let lock = NSLock()
    private static var listener: (() -> Void)?
    static func reached() { lock.lock(); let l = listener; lock.unlock(); l?() }
    public static func listen(_ f: (() -> Void)?) { lock.lock(); listener = f; lock.unlock() }
}

extension MemoryStore {
    func setupLevelNotes() throws {
        try exec("CREATE TABLE IF NOT EXISTS level_notes(id TEXT PRIMARY KEY,level TEXT NOT NULL,period TEXT NOT NULL,start TEXT NOT NULL,typed INTEGER NOT NULL,frozen INTEGER NOT NULL,body TEXT NOT NULL)")
        try exec("CREATE TABLE IF NOT EXISTS level_edges(parent TEXT NOT NULL,child TEXT NOT NULL,PRIMARY KEY(parent,child))")
        // claude/day-review-1003: the day review's per-thread clauses (DayReview.swift), derived like the level notes.
        try exec("CREATE TABLE IF NOT EXISTS review_clauses(id TEXT PRIMARY KEY,day TEXT NOT NULL,typed INTEGER NOT NULL,body TEXT NOT NULL)")
        for sql in Self.levelIndexes { try exec(sql) }
    }
    /// The level tables' own indexes. Level notes are rebuilt from moment notes, so backups hold none of them
    /// (CanonicalBackupBinding allows these tables and exactly these indexes, and exports neither).
    static let levelTables: Set<String> = ["level_notes", "level_edges", "review_clauses"]
    static let levelIndexes = [
        "CREATE INDEX IF NOT EXISTS level_edges_child ON level_edges(child)",
        "CREATE INDEX IF NOT EXISTS level_notes_period ON level_notes(level,period)",
    ]
    static func ownLevelIndex(name: String, sql: String) -> Bool {
        levelIndexes.contains { $0.replacingOccurrences(of: "IF NOT EXISTS ", with: "") == sql && $0.contains("INDEX IF NOT EXISTS \(name) ON ") }
    }
    func hasLevelNotes() throws -> Bool { !(try rows("SELECT name FROM sqlite_master WHERE name='level_notes'")).isEmpty }

    // MARK: reading

    public func levelNote(_ id:String) throws -> LevelNote? {
        guard try hasLevelNotes(), let raw=try rows("SELECT body FROM level_notes WHERE id=?",[id]).first?.first else { return nil }
        return try decode(LevelNote.self,raw)
    }
    public func levelNotes(level:LevelKind,periods:[String]) throws -> [LevelNote] {
        guard try hasLevelNotes(), !periods.isEmpty else { return [] }
        return try rows("SELECT body FROM level_notes WHERE level=? AND period IN (SELECT value FROM json_each(?)) ORDER BY start",[level.rawValue,json(periods)])
            .map { try decode(LevelNote.self,$0[0]) }
    }
    public func allLevelNotes(limit:Int=5000) throws -> [LevelNote] {
        guard try hasLevelNotes() else { return [] }
        return try rows("SELECT body FROM level_notes ORDER BY start DESC LIMIT ?",[String(limit)]).map { try decode(LevelNote.self,$0[0]) }
    }

    // MARK: ids and periods

    static func blockID(day:String,timezone:String,first:String) -> String { "blk_"+fingerprint("block|"+day+"|"+timezone+"|"+first).prefix(24) }
    static func levelID(_ level:LevelKind,period:String,timezone:String) -> String { "l"+level.rawValue+"_"+fingerprint(level.rawValue+"|"+period+"|"+timezone).prefix(24) }
    static func calendar(_ timezone:String) -> Calendar {
        var c=Calendar(identifier:.iso8601); c.timeZone=TimeZone(identifier:timezone) ?? .current; return c
    }
    /// ISO week key for a day key: 2026-W39.
    static func weekKey(day:String,timezone:String) -> String? {
        guard let start=try? DayScope.interval(day:day,timezone:timezone).start else { return nil }
        let c=calendar(timezone), comps=c.dateComponents([.yearForWeekOfYear,.weekOfYear],from:start)
        return String(format:"%04d-W%02d",comps.yearForWeekOfYear ?? 0,comps.weekOfYear ?? 0)
    }
    /// The seven day keys of an ISO week key.
    public static func days(week:String,timezone:String) -> [String] {
        let parts=week.split(separator:"-")
        guard parts.count == 2, let y=Int(parts[0]), let w=Int(parts[1].dropFirst()) else { return [] }
        let c=calendar(timezone)
        guard let monday=c.date(from:DateComponents(weekday:2,weekOfYear:w,yearForWeekOfYear:y)) else { return [] }
        return (0..<7).compactMap { c.date(byAdding:.day,value:$0,to:monday) }.compactMap { try? DayScope.key($0,timezone:timezone) }
    }
    /// A week belongs to the month its Monday is in.
    static func monthKey(week:String,timezone:String) -> String? { days(week:week,timezone:timezone).first.map { String($0.prefix(7)) } }

    // MARK: work discovery

    /// What to write next, most important first: blocks, then days, then weeks, then months (the scheduler takes one
    /// per pass, and only while background work may run the model; see LevelScheduler). `backfillDays` bounds how far back blocks and
    /// days are written. `skipping`: `workKey`s of requests the writer could not save lately (r1 levels-pipeline): they
    /// are passed over, so one note that can't be saved never holds every later block, day, week and month; a skipped
    /// block doesn't hold its day. Read only.
    ///
    /// notes-quality: `momentWillBeWritten` says whether a moment still without a note will get one (false: the writer
    /// can't write it, as with summaries off for it): its block is written without it instead of waiting. Today's day
    /// note is written from the closed blocks while the newest stretch is still going; the model writes its headline at
    /// most every 2 hours (in between, code updates the bullets and keeps the headline).
    public func levelWork(timezone:String,now:Date=Date(),backfillDays:Int=7,limit:Int=8,skipping:Set<String>=[],
                          momentWillBeWritten:(String) -> Bool = { _ in true }) throws -> [LevelRequest] {
        guard try hasLevelNotes(), try hasActionLayers() else { return [] }
        var out=[LevelRequest]()
        let today=try DayScope.key(now,timezone:timezone)
        var days=[String]()
        for back in 0..<max(1,backfillDays) {
            if let d=Self.calendar(timezone).date(byAdding:.day,value:-back,to:now) { days.append(try DayScope.key(d,timezone:timezone)) }
        }
        var daysWithPendingBlocks=Set<String>()
        for day in days {
            if let dayNote=try levelNote(Self.levelID(.day,period:day,timezone:timezone)), dayNote.frozen { continue }
            let plan=try blockPlan(day:day,timezone:timezone,now:now,momentWillBeWritten:momentWillBeWritten)
            if plan.waiting { daysWithPendingBlocks.insert(day) }
            for request in plan.requests {
                if let stored=try levelNote(request.target), stored.frozen || stored.inputRevision == request.inputRevision { continue }
                if skipping.contains(Self.workKey(request)) { continue }
                daysWithPendingBlocks.insert(day)
                out.append(request)
            }
        }
        if out.count >= limit { return Array(out.prefix(limit)) }
        // Days: once none of its blocks is waiting. Today's note at most every 2 hours.
        for day in days where !daysWithPendingBlocks.contains(day) {
            let id=Self.levelID(.day,period:day,timezone:timezone)
            let stored=try levelNote(id)
            if stored?.frozen == true { continue }
            let blocks=try levelNotes(level:.block,periods:[day])
            guard !blocks.isEmpty else { continue }
            let request=try parentRequest(.day,period:day,timezone:timezone,children:blocks,now:now)
            guard stored?.inputRevision != request.inputRevision, !skipping.contains(Self.workKey(request)) else { continue }
            out.append(request)
        }
        if out.count >= limit { return Array(out.prefix(limit)) }
        // Weeks: every week with day notes (the recent 60). The current week at most every 6 hours.
        let currentWeek=Self.weekKey(day:today,timezone:timezone)
        let dayPeriods=try rows("SELECT DISTINCT period FROM level_notes WHERE level='day' ORDER BY period DESC LIMIT 400").map { $0[0] }
        var weeks=[String]()
        for d in dayPeriods { if let w=Self.weekKey(day:d,timezone:timezone), !weeks.contains(w) { weeks.append(w) } }
        for week in weeks.prefix(60) {
            let id=Self.levelID(.week,period:week,timezone:timezone), stored=try levelNote(id)
            if stored?.frozen == true { continue }
            let children=try levelNotes(level:.day,periods:Self.days(week:week,timezone:timezone))
            guard !children.isEmpty else { continue }
            let request=try parentRequest(.week,period:week,timezone:timezone,children:children)
            guard stored?.inputRevision != request.inputRevision, !skipping.contains(Self.workKey(request)) else { continue }
            if week == currentWeek, let stored, let at=timestamp(stored.generatedAt), now.timeIntervalSince(at) < 6*3600 { continue }
            out.append(request)
        }
        if out.count >= limit { return Array(out.prefix(limit)) }
        // Months: from week notes. The current month at most once a day.
        let currentMonth=String(today.prefix(7))
        let weekPeriods=try rows("SELECT DISTINCT period FROM level_notes WHERE level='week' ORDER BY period DESC LIMIT 120").map { $0[0] }
        var months=[String:[String]]()
        for w in weekPeriods { if let m=Self.monthKey(week:w,timezone:timezone) { months[m,default:[]].append(w) } }
        for (month,weekKeys) in months.sorted(by:{ $0.key > $1.key }).prefix(24) {
            let id=Self.levelID(.month,period:month,timezone:timezone), stored=try levelNote(id)
            if stored?.frozen == true { continue }
            let children=try levelNotes(level:.week,periods:weekKeys)
            guard !children.isEmpty else { continue }
            let request=try parentRequest(.month,period:month,timezone:timezone,children:children)
            guard stored?.inputRevision != request.inputRevision, !skipping.contains(Self.workKey(request)) else { continue }
            if month == currentMonth, let stored, let at=timestamp(stored.generatedAt), now.timeIntervalSince(at) < 24*3600 { continue }
            out.append(request)
        }
        return Array(out.prefix(limit))
    }

    /// A request's key for `levelWork(skipping:)`: its target and input, so a request whose input changed is tried again.
    public static func workKey(_ request:LevelRequest) -> String { request.target+"|"+request.inputRevision }

    /// The day's moments cut into blocks by threads (LevelThreads, ThreadPlanner): a new block after a gap of more than
    /// 30 minutes, past 3 hours, or when another thread takes over; a short switch never cuts one. Only closed blocks
    /// (ended 30 minutes ago, or on a past day) whose moments all have notes are written; a moment still without a note
    /// a day after it ended is left out. `waiting` is true while a block of the day can't be written yet.
    /// `waiting` is only for closed blocks (a block still going never holds its day's note).
    func blockPlan(day:String,timezone:String,now:Date,warmOnly:Bool=false,momentWillBeWritten:(String) -> Bool = { _ in true }) throws -> (requests:[LevelRequest],waiting:Bool) {
        let assembled=try assembleDay(day:day,timezone:timezone,limit:1,now:now,notes:true,warmOnly:warmOnly)
        let layers=assembled.day
        guard !layers.partial else { return ([],true) }
        let moments=layers.activities.sorted { ($0.start,$0.id) < ($1.start,$1.id) }
        let byID=Dictionary(uniqueKeysWithValues:moments.map { ($0.id,$0) })
        let plan=try threadPlan(moments:moments,actions:assembled.actions)
        let segments=plan.blocks.map { $0.compactMap { byID[$0] } }.filter { !$0.isEmpty }
        let today=try DayScope.key(now,timezone:timezone)
        var out=[LevelRequest](), waiting=false
        for seg in segments {
            guard let end=timestamp(seg.map(\.end).max()!) else { continue }
            if day == today && now.timeIntervalSince(end) < 30*60 { continue }
            var kids=[ActivityNote]()
            var missing=false
            for m in seg {
                if m.generated != nil, m.status == "ready" { kids.append(m); continue }
                // fix/day-card: no writer is asked for a moment made only of idle rows, so it never holds its block.
                if NoteAudience.idleOnly(m) { continue }
                if let e=timestamp(m.end), now.timeIntervalSince(e) > 86400 { continue }
                // fix/sx-all round 3: a moment the writer won't write again (the rewrite rule) keeps the note shown for it
                // meanwhile (its previous note); without one it is left out. It never holds its block.
                if !momentWillBeWritten(m.id) {
                    if let previous=m.previous { var kept=m; kept.generated=previous; kids.append(kept) }
                    continue
                }
                // notes-quality: a moment of idle time only gets no note (nothing to write about); it never holds a block.
                if m.actionIDs.allSatisfy({ assembled.actions[$0]?.kind == "idle" }) { continue }
                missing=true
            }
            if missing { waiting=true; continue }
            guard !kids.isEmpty else { continue }
            let typedIDs=try typedActionIDs(kids.flatMap(\.actionIDs))
            let views=kids.enumerated().map { i,m -> LevelChildView in
                let note=m.generated!
                return LevelChildView(alias:"m\(i+1)",ref:LevelChildRef(id:m.id,version:"\(note.version)|\(note.inputRevision)",start:m.start,end:m.end),
                                      label:Self.span(m.start,m.end,timezone:timezone),title:note.output.title,lines:note.output.bullets.map(\.text),
                                      typed:m.actionIDs.contains(where:typedIDs.contains))
            }
            let threads=plan.threads(for:Set(kids.map(\.id)))
            let target=Self.blockID(day:day,timezone:timezone,first:seg[0].id)
            out.append(LevelRequest(target:target,level:.block,period:day,timezone:timezone,start:kids.map(\.start).min()!,end:kids.map(\.end).max()!,
                                    children:views,actionIDs:kids.flatMap(\.actionIDs),inputRevision:Self.revision(views,threads:threads),threads:threads))
        }
        return (out,waiting)
    }
    /// The day's actions as the thread planner reads them: each visible action's entity (app, site, window title, and a
    /// typed row's recipient label, never its words) and its moment.
    func threadPlan(moments:[ActivityNote],actions:[String:CanonicalAction]) throws -> ThreadPlan {
        let recipients=try typedRecipients(moments.flatMap(\.actionIDs).filter { actions[$0]?.kind == "keyboard.text_input" })
        var input=[ThreadAction]()
        // fix/day-card: an entity depends only on these inputs, and a day repeats a few dozen of them over its ~1,400
        // actions, so each is worked out once (36 ms -> under 1 ms on the replay day; the Today card reads this live).
        var memo=[String:ThreadEntity]()
        for m in moments {
            for id in m.actionIDs {
                guard let a=actions[id], let at=timestamp(a.at) else { continue }
                let messages=MessagesMomentIdentity.applies(a)
                let identity=messages ? MessagesMomentIdentity.name(a,recipient:recipients[id]) : nil
                let to=messages ? identity : recipients[id]
                let title=messages ? identity ?? "Messages" : Self.windowTitle(a)
                let key=[a.app,a.bundle,a.site,title,to.map { "1"+$0 } ?? "0"].joined(separator:"\u{1F}")
                let entity=memo[key] ?? ThreadEntities.entity(app:a.app,bundle:a.bundle,site:a.site,title:title,to:to)
                memo[key]=entity
                input.append(ThreadAction(id:id,moment:m.id,at:at,idle:a.kind == "idle",entity:entity))
            }
        }
        // notes-quality: each moment's note (title and sent or asked line) names AI asks and gives threads their lines.
        var gists=[String:MomentGist]()
        // fix/card7: a title that only names the app ("Worked in ChatGPT") never names its thread (the thread keeps its code name).
        for m in moments { if let note=m.generated, m.status == "ready" { gists[m.id]=MomentGist(title:Self.recallFiller(note.output.title) ? "" : note.output.title,intent:MomentGist.intent(note.output.bullets.map(\.text))) } }
        // fix/sx-all round 3: the person's own account names, from the addresses the day's mail windows show (as
        // `accountHandles`, from this day's titles only): whose pull request is whose.
        var handles=Set<String>()
        for a in actions.values where WriterFacts.mailApps.contains(a.app) || WriterFacts.mailHosts.contains(where:{ a.site == $0 || a.site.hasSuffix("."+$0) }) {
            handles.formUnion(WriterFacts.handles(inTitle:Self.windowTitle(a)))
        }
        return ThreadPlanner.plan(input,gists:gists,selfNames:handles)
    }
    /// A typed row's recipient or place label (`captureProvenance.unit.to`): code-read from the window at seal time,
    /// never taken from the typed words. Texts, chats and email only.
    func typedRecipients(_ ids:[String]) throws -> [String:String] {
        guard !ids.isEmpty else { return [:] }
        var out=[String:String]()
        for row in try rows("SELECT id,coalesce(json_extract(body,'$.captureProvenance.unit.to'),''),coalesce(json_extract(body,'$.captureProvenance.unit.surface'),''),coalesce(json_extract(body,'$.captureProvenance.unit.field'),'') FROM records WHERE id IN (SELECT value FROM json_each(?))",[json(ids)])
        where ["text","chat","email"].contains(row[2]) {
            if row[2] == "text" {
                if let to=MessagesMomentIdentity.recipient(surface:row[2],field:row[3],to:row[1]) { out[row[0]]=to }
                continue
            }
            // fix/r1-writer: an email's recipient is sealed with the typed words (kept only while they are).
            let to=row[2] == "email" ? try typedRecipient(row[0]) ?? "" : row[1]
            if !to.isEmpty { out[row[0]]=to }
        }
        return out
    }
    /// r2: the actions under level notes (a block's own; a day's, week's or month's from the typed notes below it), for
    /// the typed check of a parent note.
    func levelActionIDs(_ ids:[String]) throws -> [String] {
        var out=[String]()
        for id in ids {
            guard let n=try levelNote(id), n.typedDerived else { continue }
            out+=n.level == .block ? n.actionIDs : try levelActionIDs(n.children.map(\.id))
        }
        return out
    }
    func typedActionIDs(_ ids:[String]) throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        return Set(try rows("SELECT id FROM records WHERE id IN (SELECT value FROM json_each(?)) AND json_extract(body,'$.kind')='keyboard.text_input'",[json(ids)]).map { $0[0] })
    }
    func parentRequest(_ level:LevelKind,period:String,timezone:String,children:[LevelNote],now:Date?=nil) throws -> LevelRequest {
        let sorted=children.sorted { ($0.start,$0.id) < ($1.start,$1.id) }
        let views=sorted.enumerated().map { i,n in
            LevelChildView(alias:"\(level.alias)\(i+1)",ref:LevelChildRef(id:n.id,version:"\(n.version)|\(n.inputRevision)",start:n.start,end:n.end),
                           label:Self.childLabel(n,timezone:timezone),title:n.title,lines:n.lines.map(\.text),typed:n.typedDerived)
        }
        // A day, week or month is written with threads when every note it is written from was (a note kept from before
        // threads: the older way).
        let threads=level != .block && !sorted.isEmpty && sorted.allSatisfy({ $0.threads != nil }) ? LevelThreads.merge(sorted) : nil
        var request=LevelRequest(target:Self.levelID(level,period:period,timezone:timezone),level:level,period:period,timezone:timezone,
                                 start:sorted.map(\.start).min()!,end:sorted.map(\.end).max()!,children:views,actionIDs:[],
                                 inputRevision:Self.revision(views,threads:threads),threads:threads)
        // Today's day note: the model's headline is at most 2 hours old, so code writes this one and keeps it.
        if level == .day, threads != nil, let now, period == (try? DayScope.key(now,timezone:timezone)),
           let stored=try levelNote(request.target), !stored.frozen, let at=stored.titledAt.flatMap(timestamp), now.timeIntervalSince(at) < 2*3600 {
            request.keptTitle=stored.title
        }
        return request
    }
    static func revision(_ views:[LevelChildView],threads:[LevelThread]?=nil) -> String {
        let base=views.map { $0.ref.id+"@"+$0.ref.version }.joined(separator:",")
        guard let threads else { return fingerprint(base) }
        return fingerprint(base+"|"+LevelThreads.version+"|"+((try? json(threads)) ?? ""))
    }

    /// The request a stored level note would be written from now (nil when its level has nothing to write, or the
    /// block is no longer planned). Read only: for checks and for writing one note again.
    public func levelRequest(id:String,timezone:String,now:Date=Date()) throws -> LevelRequest? {
        guard let note=try levelNote(id) else { return nil }
        switch note.level {
        case .block: return try blockPlan(day:note.period,timezone:timezone,now:now).requests.first { $0.target == id }
        default:
            let probe=LevelRequest(target:id,level:note.level,period:note.period,timezone:timezone,start:note.start,end:note.end,children:[],actionIDs:[],inputRevision:"")
            return try currentLevelRequest(probe,now:now,warmOnly:false)
        }
    }

    // MARK: commit

    /// Saves a level note for `request`, if the request is still what `levelWork` would ask for now. Every line is
    /// checked again (LevelGrounding.check), and a block may not copy typed words (the moment rule). Returns the note.
    ///
    /// The checks run on the input as read before the write lock (the typed check may open the Keychain vault); the
    /// input is then read again inside the same BEGIN IMMEDIATE transaction as the INSERT, and must be unchanged, with
    /// every action it covers still saved. A Forget committing on another connection in between (range, one action,
    /// or what I typed) changes that input, so a note written from forgotten moments is never saved (r1 forget-range).
    @discardableResult
    /// fix/sx-all round 1: `momentWillBeWritten` is the one `levelWork` planned with, so a block that leaves out a moment the
    /// writer set aside is the same block here; before, it read as "Level input changed" on every try (and the model was
    /// asked again each hour).
    public func commitLevel(_ request:LevelRequest,title:String,lines:[LevelLine],generator:String,now:Date=Date(),
                            momentWillBeWritten:(String) -> Bool = { _ in true }) throws -> LevelNote {
        guard try hasLevelNotes() else { throw MemError.invalid("Level notes are not set up") }
        guard let current=try currentLevelRequest(request,now:now,warmOnly:false,momentWillBeWritten:momentWillBeWritten), current.inputRevision == request.inputRevision else { throw MemError.invalid(Self.levelInputChanged) }
        if let stored=try levelNote(request.target), stored.frozen { throw MemError.invalid("Frozen level notes are not rewritten") }
        if let why=LevelGrounding.check(title:title,lines:lines,request:current,extractive:generator == LevelWriterVersion.extractive) { throw MemError.invalid("Level note refused: "+why) }
        // r2: every level runs the typed check (a day, week or month over the typed rows of the blocks below it), and the
        // threads it stores are checked too (AI apps read their names): threads that would repeat a typed draft, or a
        // note saved plain, keep plain names only (`LevelThreads.plained`).
        let typed=current.level == .block ? current.actionIDs : current.children.contains(where:\.typed) ? try levelActionIDs(current.children.map(\.ref.id)) : []
        if !typed.isEmpty { try typedVerbatimGuard(texts:[title]+lines.map(\.text),actionIDs:typed) }
        var plainThreads=false
        if let threads=current.threads, !threads.isEmpty {
            let plain=LevelGrounding.plainThreadNote(current)
            if generator == LevelWriterVersion.extractive, title == plain.title, lines == plain.lines, (title,lines) != LevelGrounding.threadNote(current) { plainThreads=true }
            else if !typed.isEmpty {
                do { try typedVerbatimGuard(texts:threads.flatMap { [$0.label]+$0.people+$0.places },actionIDs:typed) } catch { plainThreads=true }
            }
        }
        LevelCommitWindow.reached()
        // The day was just read (warm), so inside the lock only what changed since is read; if it went cold meanwhile,
        // warm it again (twice), and only then read it inside (as commitNote's withWarmDay).
        for attempt in 0..<3 {
            if attempt > 0 { _ = try? currentLevelRequest(request,now:now,warmOnly:false,momentWillBeWritten:momentWillBeWritten) }
            do { return try transaction { try saveLevel(request,title:title,lines:lines,generator:generator,now:now,warmOnly:attempt < 2,plainThreads:plainThreads,momentWillBeWritten:momentWillBeWritten) } }
            catch is DayAssemblyCold { continue }
        }
        return try transaction { try saveLevel(request,title:title,lines:lines,generator:generator,now:now,warmOnly:false,plainThreads:plainThreads,momentWillBeWritten:momentWillBeWritten) }
    }
    static let levelInputChanged="Level input changed; prepare again"
    /// The request `levelWork` would make now for `request`'s target (nil: a block no longer planned, or a parent with
    /// no children left, as after a Forget took every block of the day).
    func currentLevelRequest(_ request:LevelRequest,now:Date,warmOnly:Bool,momentWillBeWritten:(String) -> Bool = { _ in true }) throws -> LevelRequest? {
        let children:[LevelNote]
        switch request.level {
        case .block: return try blockPlan(day:request.period,timezone:request.timezone,now:now,warmOnly:warmOnly,momentWillBeWritten:momentWillBeWritten).requests.first { $0.target == request.target }
        case .day: children=try levelNotes(level:.block,periods:[request.period])
        case .week: children=try levelNotes(level:.day,periods:Self.days(week:request.period,timezone:request.timezone))
        case .month:
            let weeks=try rows("SELECT DISTINCT period FROM level_notes WHERE level='week'").map { $0[0] }.filter { Self.monthKey(week:$0,timezone:request.timezone) == request.period }
            children=try levelNotes(level:.week,periods:weeks)
        }
        guard !children.isEmpty else { return nil }
        return try parentRequest(request.level,period:request.period,timezone:request.timezone,children:children,now:now)
    }
    /// Inside the write transaction: the input read again must be the one checked, and a block's actions must all still
    /// be saved (none forgotten or tombstoned); a parent's children must all still be level notes.
    private func saveLevel(_ request:LevelRequest,title:String,lines:[LevelLine],generator:String,now:Date,warmOnly:Bool,plainThreads:Bool,
                           momentWillBeWritten:(String) -> Bool = { _ in true }) throws -> LevelNote {
        guard let current=try currentLevelRequest(request,now:now,warmOnly:warmOnly,momentWillBeWritten:momentWillBeWritten), current.inputRevision == request.inputRevision else { throw MemError.invalid(Self.levelInputChanged) }
        if let stored=try levelNote(request.target), stored.frozen { throw MemError.invalid("Frozen level notes are not rewritten") }
        if current.level == .block {
            let ids=Array(Set(current.actionIDs))
            let live=try rows("SELECT count(*) FROM json_each(?) j WHERE EXISTS(SELECT 1 FROM records r WHERE r.id=j.value) AND NOT EXISTS(SELECT 1 FROM tombstones t WHERE t.id=j.value)",[json(ids)]).first?.first
            guard !ids.isEmpty, live == String(ids.count) else { throw MemError.invalid(Self.levelInputChanged) }
        } else {
            let kids=current.children.map(\.ref.id)
            let live=try rows("SELECT count(*) FROM level_notes WHERE id IN (SELECT value FROM json_each(?))",[json(kids)]).first?.first
            guard !kids.isEmpty, live == String(Set(kids).count) else { throw MemError.invalid(Self.levelInputChanged) }
        }
        let stored=try levelNote(request.target)
        let version=(stored?.version ?? 0)+1
        // The model wrote this title now, or code kept the one it wrote before.
        let titledAt=generator != LevelWriterVersion.extractive ? iso(now) : title == current.keptTitle ? stored?.titledAt : nil
        var note=LevelNote(id:request.target,level:request.level,period:request.period,timezone:request.timezone,start:current.start,end:current.end,
                           title:title,lines:lines,children:current.children.map(\.ref),actionIDs:current.actionIDs,inputRevision:current.inputRevision,
                           typedDerived:current.children.contains(where:\.typed),frozen:false,generator:generator,
                           generatorVersion:current.threads != nil ? LevelWriterVersion.threads : generator == LevelWriterVersion.extractive ? LevelWriterVersion.extractive : LevelWriterVersion.prompt,
                           generatedAt:iso(now),version:version,threads:plainThreads ? current.threads?.map(LevelThreads.plained) : current.threads)
        note.titledAt=titledAt
        // Threads can move a moment to another block as the day grows: a block written before, holding any of this
        // block's actions, is replaced (with the notes above it, which are written again).
        if note.level == .block {
            let superseded=try rows("SELECT id FROM level_notes WHERE level='block' AND period=? AND id<>? AND frozen=0 AND EXISTS(SELECT 1 FROM json_each(level_notes.body,'$.actionIDs') r JOIN json_each(?) c ON r.value=c.value)",
                                    [note.period,note.id,json(note.actionIDs)]).map { $0[0] }
            for id in superseded { try dropLevel(id,expired:false) }
        }
        try exec("INSERT OR REPLACE INTO level_notes VALUES(?,?,?,?,?,?,?)",[note.id,note.level.rawValue,note.period,note.start,note.typedDerived ? "1":"0","0",json(note)])
        try exec("DELETE FROM level_edges WHERE parent=?",[note.id])
        for child in note.children { try exec("INSERT OR IGNORE INTO level_edges VALUES(?,?)",[note.id,child.id]) }
        return note
    }

    // MARK: delete, forget, retention

    /// Every block whose moments cover any of `ids`, and every note above it. `expired`: history retention took the
    /// actions, so the notes above the block are frozen instead of deleted.
    func dropLevels(forActions ids:[String],expired:Bool=false) throws {
        guard !ids.isEmpty, try hasLevelNotes() else { return }
        // claude/day-review-1003: a day review clause written from any of these actions goes with them (Forget, delete,
        // retention, a correction): the thread's bullet is the code's own until it is written again from what is left.
        try dropReviewClauses(forActions:ids)
        let blocks=try rows("SELECT id FROM level_notes WHERE level='block' AND EXISTS(SELECT 1 FROM json_each(level_notes.body,'$.actionIDs') r JOIN json_each(?) c ON r.value=c.value)",[json(Array(Set(ids)))]).map { $0[0] }
        for id in blocks { try dropLevel(id,expired:expired) }
    }
    /// Deletes one level note and, walking up the edges, every note written from it (or freezes them when `expired`).
    func dropLevel(_ id:String,expired:Bool) throws {
        let parents=try rows("SELECT parent FROM level_edges WHERE child=?",[id]).map { $0[0] }
        try exec("DELETE FROM level_notes WHERE id=?",[id])
        try exec("DELETE FROM level_edges WHERE parent=? OR child=?",[id,id])
        for parent in parents {
            if expired { try freezeLevel(parent) } else { try dropLevel(parent,expired:false) }
        }
    }
    func freezeLevel(_ id:String) throws {
        guard let raw=try rows("SELECT body FROM level_notes WHERE id=?",[id]).first?.first, var note=try? decode(LevelNote.self,raw), !note.frozen else { return }
        note.frozen=true
        try exec("UPDATE level_notes SET frozen=1,body=? WHERE id=?",[json(note),id])
    }
    /// Forget a time range: a frozen level note (kept as written after retention took its actions, so nothing can
    /// rewrite it without them) whose span meets `range` goes, with every note above it (they are written again from
    /// what is left). Unfrozen notes are found by their actions (`dropLevels`).
    func dropFrozenLevels(overlapping range:DateInterval) throws {
        guard try hasLevelNotes() else { return }
        let found=try rows("SELECT id FROM level_notes WHERE frozen=1 AND json_valid(body) AND julianday(start)<julianday(?) AND julianday(json_extract(body,'$.end'))>julianday(?)",
                           [Self.actionBound(range.end),Self.actionBound(range.start)]).map { $0[0] }
        for id in found where try !rows("SELECT 1 FROM level_notes WHERE id=?",[id]).isEmpty { try dropLevel(id,expired:false) }
    }
    /// How many frozen level notes `dropFrozenLevels(overlapping:)` would find (the range Forget's preview).
    func frozenLevelCount(overlapping range:DateInterval) throws -> Int {
        guard try hasLevelNotes() else { return 0 }
        return Int(try rows("SELECT count(*) FROM level_notes WHERE frozen=1 AND json_valid(body) AND julianday(start)<julianday(?) AND julianday(json_extract(body,'$.end'))>julianday(?)",
                            [Self.actionBound(range.end),Self.actionBound(range.start)]).first?.first ?? "0") ?? 0
    }
    /// A person deleting a level note (a block, day, week or month) deletes it and what was written from it.
    public func deleteLevelNote(_ id:String) throws {
        guard try hasLevelNotes() else { return }
        try transaction { try dropLevel(id,expired:false) }
    }
    /// "Forget what I typed": every level note written from typed rows goes, frozen or not (typedDerived passes up).
    func forgetTypedLevels() throws {
        DayReviewCache.bump()
        guard try hasLevelNotes() else { return }
        for id in try rows("SELECT id FROM level_notes WHERE typed=1").map({ $0[0] }) { try dropLevel(id,expired:false) }
        if try hasReviewClauses() { try exec("DELETE FROM review_clauses WHERE typed=1") }
    }
    func dropAllLevels() throws {
        DayReviewCache.bump()
        guard try hasLevelNotes() else { return }
        try exec("DELETE FROM level_notes"); try exec("DELETE FROM level_edges")
        if try hasReviewClauses() { try exec("DELETE FROM review_clauses") }
    }
    /// Level notes past their own keep period: day notes after 400 days (the week above is frozen); week and month
    /// notes are kept until deleted. Blocks go with their moments.
    @discardableResult func expireLevels(now:Date=Date()) throws -> Int {
        guard try hasLevelNotes() else { return 0 }
        let cutoff=iso(now.addingTimeInterval(-400*86400))
        let old=try rows("SELECT id FROM level_notes WHERE level IN ('day','block') AND start<?",[cutoff]).map { $0[0] }
        for id in old { try dropLevel(id,expired:true) }
        if !old.isEmpty { DayReviewCache.bump() }
        if try hasReviewClauses() { try exec("DELETE FROM review_clauses WHERE day<?",[String(cutoff.prefix(10))]) }
        return old.count
    }

    // MARK: labels

    static func localFormatter(_ timezone:String,_ format:String) -> DateFormatter {
        let f=DateFormatter(); f.locale=Locale(identifier:"en_US_POSIX"); f.timeZone=TimeZone(identifier:timezone) ?? .current; f.dateFormat=format; return f
    }
    static func span(_ start:String,_ end:String,timezone:String) -> String {
        let f=localFormatter(timezone,"h:mm a")
        guard let s=timestamp(start), let e=timestamp(end) else { return "" }
        return f.string(from:s)+" to "+f.string(from:e)
    }
    static func childLabel(_ note:LevelNote,timezone:String) -> String {
        switch note.level {
        case .block: return span(note.start,note.end,timezone:timezone)
        case .day: return timestamp(note.start).map { localFormatter(timezone,"EEEE, MMMM d").string(from:$0) } ?? note.period
        case .week:
            let days=Self.days(week:note.period,timezone:timezone)
            guard let a=days.first.flatMap({ try? DayScope.interval(day:$0,timezone:timezone).start }), let b=days.last.flatMap({ try? DayScope.interval(day:$0,timezone:timezone).start }) else { return note.period }
            let f=localFormatter(timezone,"MMMM d")
            return "Week of "+f.string(from:a)+" to "+f.string(from:b)
        case .month: return timestamp(note.start).map { localFormatter(timezone,"MMMM yyyy").string(from:$0) } ?? note.period
        }
    }
    /// The code-written front of a block title: how much of which part of the day the stretch covers. It is the span of
    /// recorded activity, not time spent.
    public static func spanPhrase(start:String,end:String,timezone:String) -> String {
        guard let s=timestamp(start), let e=timestamp(end) else { return "A stretch" }
        let minutes=e.timeIntervalSince(s)/60
        let c=calendar(timezone)
        let mid=s.addingTimeInterval(e.timeIntervalSince(s)/2)
        let hour=c.component(.hour,from:mid)
        let part:(String,Double)=hour < 5 ? ("night",180) : hour < 12 ? ("morning",210) : hour < 17 ? ("afternoon",300) : hour < 21 ? ("evening",240) : ("night",180)
        if minutes >= 100 && minutes >= part.1*0.6 { return "Most of the "+part.0 }
        // Bins close enough that the phrase never overstates by much (r1: a 20-minute block read "About half an hour").
        if minutes < 15 { return "A few minutes" }
        if minutes < 25 { return "About 20 minutes" }
        if minutes < 40 { return "About half an hour" }
        if minutes < 55 { return "About 45 minutes" }
        if minutes < 75 { return "About an hour" }
        if minutes < 105 { return "About an hour and a half" }
        return "About \(Int((minutes/60).rounded())) hours"
    }
}
