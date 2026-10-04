import Foundation

/// MCP `recall`: DayDream's notes at any zoom. Ask at a level (month, week, day, block, moment) and drill down with the
/// `open` handles each result gives (week -> day -> block -> moment -> lines), or search every level's notes with
/// `query` (each hit says its level and time). Read only; the notes are model-written and unverified.
extension MemoryStore {
    public static let recallNote="DayDream's notes, written by a model from what was on screen and typed; they can be incomplete or wrong. Lines keep the notes' verbs: Asked, Emailed or Texted means DayDream saw the send key; Wrote or Drafted means it didn't."

    public func assistantRecall(level:String?,when:String?,open:String?,query:String?,timezone:String?=nil,now:Date=Date()) throws -> String {
        let tz=timezone.flatMap { TimeZone(identifier:$0) != nil ? $0 : nil } ?? TimeZone.current.identifier
        var out:[String:Any]
        if let q=query?.trimmingCharacters(in:.whitespacesAndNewlines), !q.isEmpty {
            out=["query":q,"hits":try recallSearch(q,timezone:tz,now:now)]
        } else if let handle=open?.trimmingCharacters(in:.whitespaces), !handle.isEmpty {
            out=try recallNode(handle,timezone:tz,now:now)
        } else {
            let lv=(level ?? "day").lowercased()
            guard let period=try Self.recallPeriod(level:lv,when:when ?? "",timezone:tz,now:now) else {
                throw MemError.invalid("Couldn't read the time \"\(when ?? "")\". Use today, yesterday, a weekday, this week, last week, this month, or a date like 2026-09-22.")
            }
            if lv == "block" {
                out=try recallBlocks(day:period.key,part:period.part,timezone:tz,now:now)
            } else {
                out=try recallNode(lv+":"+period.key,timezone:tz,now:now)
            }
        }
        out["about"]=Self.recallNote
        out["timezone"]=AssistantView.zoneLabel(TimeZone(identifier:tz) ?? .current)
        return AssistantView.serialize(out) ?? "{}"
    }

    // MARK: time words

    /// (period key, optional part of day) for a level and plain time words.
    static func recallPeriod(level:String,when raw:String,timezone:String,now:Date) throws -> (key:String,part:String?)? {
        let c=calendar(timezone)
        var text=raw.lowercased().trimmingCharacters(in:.whitespacesAndNewlines)
        var part:String?
        for p in ["morning","afternoon","evening","night"] where text.contains(p) { part=p; text=text.replacingOccurrences(of:p,with:"").trimmingCharacters(in:.whitespaces) }
        text=text.replacingOccurrences(of:"on ",with:"").replacingOccurrences(of:"last ",with:text.hasPrefix("last week") || text.hasPrefix("last month") ? "last " : "").trimmingCharacters(in:.whitespaces)
        func dayKey(_ d:Date) throws -> String { try DayScope.key(d,timezone:timezone) }
        func dayOf(_ t:String) throws -> Date? {
            if t.isEmpty || t == "today" { return now }
            if t == "yesterday" { return c.date(byAdding:.day,value:-1,to:now) }
            let names=["sunday","monday","tuesday","wednesday","thursday","friday","saturday"]
            if let i=names.firstIndex(where:{ t.hasPrefix($0) }) {
                let today=c.component(.weekday,from:now)
                var back=(today-(i+1)+7)%7
                if t.hasPrefix(names[i]) && back == 0 && raw.lowercased().contains("last") { back=7 }
                return c.date(byAdding:.day,value:-back,to:now)
            }
            if t.range(of:"^\\d{4}-\\d{2}-\\d{2}$",options:.regularExpression) != nil { return try DayScope.interval(day:t,timezone:timezone).start }
            if let m=t.range(of:"^(\\d+) days? ago$",options:.regularExpression), let n=Int(t[m].split(separator:" ")[0]) { return c.date(byAdding:.day,value:-n,to:now) }
            return nil
        }
        switch level {
        case "day","block","moment":
            guard let d=try dayOf(text) else { return nil }
            return (try dayKey(d),part)
        case "week":
            if text.range(of:"^\\d{4}-w\\d{2}$",options:.regularExpression) != nil { return (text.uppercased().replacingOccurrences(of:"W",with:"W"),nil) }
            let base:Date?
            if text.isEmpty || text == "this week" { base=now } else if text == "last week" { base=c.date(byAdding:.day,value:-7,to:now) } else { base=try dayOf(text) }
            guard let b=base, let w=weekKey(day:try dayKey(b),timezone:timezone) else { return nil }
            return (w,nil)
        case "month":
            if text.range(of:"^\\d{4}-\\d{2}$",options:.regularExpression) != nil { return (text,nil) }
            let base:Date?
            if text.isEmpty || text == "this month" { base=now } else if text == "last month" { base=c.date(byAdding:.month,value:-1,to:now) } else { base=try dayOf(text) }
            guard let b=base else { return nil }
            return (String(try dayKey(b).prefix(7)),nil)
        default: return nil
        }
    }

    // MARK: nodes

    func recallNode(_ handle:String,timezone:String,now:Date) throws -> [String:Any] {
        let parts=handle.split(separator:":",maxSplits:1).map(String.init)
        guard parts.count == 2 else { throw MemError.invalid("Use an open value from an earlier recall result.") }
        let (kind,key)=(parts[0].lowercased(),parts[1])
        switch kind {
        case "month","week","day":
            let level=LevelKind(rawValue:kind)!
            let note=try levelNote(Self.levelID(level,period:key,timezone:timezone))
            var node=levelNode(note,level:level,period:key,timezone:timezone)
            if level == .day, try levelNotes(level:.block,periods:[key]).isEmpty {
                // No blocks yet: the moments themselves, back-to-back ones with no note folded (claude/recall-1004).
                let rows=foldedMoments(try dayLayers(day:key,timezone:timezone,limit:1,now:now).activities,day:key,timezone:timezone)
                node["children"]=rows.rows
                rows.describe(into:&node)
            } else {
                node["children"]=try recallChildren(level:level,period:key,timezone:timezone,now:now)
            }
            if level == .day, key == (try? DayScope.key(now,timezone:timezone)), let open=try recallNow(day:key,timezone:timezone,now:now) { node["now"]=open }
            return node
        case "block":
            guard let note=try levelNote(key), note.level == .block else { throw MemError.invalid("That block is gone (deleted or rebuilt). Recall its day again.") }
            var node=levelNode(note,level:.block,period:note.period,timezone:timezone)
            let layers=try dayLayers(day:note.period,timezone:timezone,limit:1,now:now)
            let ids=Set(note.children.map(\.id))
            let rows=foldedMoments(layers.activities.filter { ids.contains($0.id) },day:note.period,timezone:timezone)
            node["children"]=rows.rows
            rows.describe(into:&node)
            return node
        case "moment":
            let bits=key.split(separator:"@").map(String.init)
            guard bits.count == 2 else { throw MemError.invalid("Use an open value from an earlier recall result.") }
            let layers=try dayLayers(day:bits[1],timezone:timezone,limit:1,now:now)
            guard let m=layers.activities.first(where:{ $0.id == bits[0] }) else { throw MemError.invalid("That moment is gone (deleted, expired or regrouped). Recall its day again.") }
            var node=momentSummary(m,day:bits[1],timezone:timezone)
            node.removeValue(forKey:"open")
            node["level"]="moment"
            node["lines"]=try (m.generated?.output.bullets ?? []).map { b -> [String:Any] in
                let first=try b.actionIDs.compactMap { try action($0,now:now)?.at }.min()
                return ["level":"line","text":b.text,"when":first.map { AssistantView.when($0,zone:TimeZone(identifier:timezone) ?? .current) } ?? "","state":b.assertion]
            }
            node["actions"]=ActionResources.activityURI(m.id,day:bits[1],timezone:timezone)
            return node
        case "moments":
            // claude/recall-1004: a folded line from a day or block: the back-to-back moments it stands for, one per line.
            let bits=key.split(separator:"@").map(String.init)
            let ends=bits.first?.components(separatedBy:"..") ?? []
            guard bits.count == 2, ends.count == 2 else { throw MemError.invalid("Use an open value from an earlier recall result.") }
            let moments=try dayLayers(day:bits[1],timezone:timezone,limit:1,now:now).activities
            guard let first=moments.firstIndex(where:{ $0.id == ends[0] }), let last=moments.firstIndex(where:{ $0.id == ends[1] }), first <= last else {
                throw MemError.invalid("Those moments are gone (deleted, expired or regrouped). Recall their day again.")
            }
            let part=Array(moments[first...last]), zone=TimeZone(identifier:timezone) ?? .current
            return ["level":"moments","when":AssistantView.when(part[0].start,zone:zone)+" to "+AssistantView.clock(part.map(\.end).max() ?? part[0].end,zone:zone),
                    "title":part[0].subject,"count":part.count,"children":part.map { momentSummary($0,day:bits[1],timezone:timezone) }]
        default: throw MemError.invalid("Use an open value from an earlier recall result.")
        }
    }
    /// claude/recall-1004: a day with no notes yet listed every moment on its own line, so a day of short Messages visits
    /// read as dozens of bare "Messages (no note yet)" lines at the same minute. Back-to-back moments with no note, from
    /// the same app(s) and the same title (for Messages, the same conversation: an unknown recipient stays "Messages" and
    /// never folds into a named one), less than `foldGap` apart, become one line with a time range, a count and one open
    /// handle (`moments:<first id>..<last id>@<day>`) that lists them. Moments with a note always keep their own line.
    /// At most `maxMomentRows` lines; the rest are counted, never silently dropped.
    static let foldGap:TimeInterval=30*60
    static let maxMomentRows=40
    struct FoldedMoments {
        var rows:[[String:Any]]=[], folded=0, foldedInto=0, leftOut=0
        /// Says how many moments were folded and how many lines were left out, on the node that lists them.
        func describe(into node:inout [String:Any]) {
            if folded > 0 { node["folded"]="\(folded) back-to-back moments with no note yet are folded into \(foldedInto) line\(foldedInto == 1 ? "" : "s"); open a line's handle to list them." }
            if leftOut > 0 { node["left_out"]="\(leftOut) later line\(leftOut == 1 ? "" : "s") not shown; recall level block with when set to the day and a part (morning, afternoon, evening, night) for them." }
        }
    }
    func foldedMoments(_ moments:[ActivityNote],day:String,timezone:String,cap:Int=maxMomentRows) -> FoldedMoments {
        let zone=TimeZone(identifier:timezone) ?? .current
        var runs:[[ActivityNote]]=[]
        for m in moments {
            if m.generated == nil, let run=runs.last, let prev=run.last, prev.generated == nil, prev.subject == m.subject,
               prev.apps == m.apps, prev.sites == m.sites,
               let end=timestamp(run.map(\.end).max() ?? prev.end), let start=timestamp(m.start), start.timeIntervalSince(end) <= Self.foldGap {
                runs[runs.count-1].append(m)
            } else {
                runs.append([m])
            }
        }
        var out=FoldedMoments()
        for run in runs {
            if run.count == 1 { out.rows.append(momentSummary(run[0],day:day,timezone:timezone)); continue }
            out.folded+=run.count; out.foldedInto+=1
            out.rows.append(["level":"moments","when":AssistantView.when(run[0].start,zone:zone)+" to "+AssistantView.clock(run.map(\.end).max() ?? run[0].end,zone:zone),
                             "apps":run[0].apps.map { AppNames.display(app:$0,bundle:"") },"title":run[0].subject,"written":"no note yet",
                             "count":run.count,"open":"moments:\(run[0].id)..\(run[run.count-1].id)@\(day)"])
        }
        if out.rows.count > cap { out.leftOut=out.rows.count-cap; out.rows=Array(out.rows.prefix(cap)) }
        return out
    }
    func levelNode(_ note:LevelNote?,level:LevelKind,period:String,timezone:String) -> [String:Any] {
        var node:[String:Any]=["level":level.rawValue,"open":level.rawValue+":"+(level == .block ? (note?.id ?? "") : period)]
        guard let note else { node["when"]=period; node["written"]="not written yet"; return node }
        node["when"]=level == .block ? AssistantView.when(note.start,zone:TimeZone(identifier:timezone) ?? .current)+" to "+AssistantView.clock(note.end,zone:TimeZone(identifier:timezone) ?? .current) : Self.childLabel(note,timezone:timezone)
        node["title"]=note.title
        node["lines"]=note.lines.map(\.text)
        // Threads (blocks and days): what each was about, who, and its focused minutes; the first is the main thread.
        if let threads=note.threads, !threads.isEmpty {
            node["threads"]=threads.prefix(8).map { t -> [String:Any] in
                var x:[String:Any]=["about":t.label,"kind":t.kind,"minutes":max(1,Int((Double(t.seconds)/60).rounded()))]
                if !t.people.isEmpty { x["people"]=t.people }
                if !t.places.isEmpty { x["places"]=t.places }
                if t.bursts > 1 { x["times"]=t.bursts }
                return x
            }
        }
        node["written"]=note.generator == LevelWriterVersion.extractive ? "by code from the notes below" : "by the summary model from the notes below"
        if note.frozen { node["kept"]="kept after the activity below it expired" }
        return node
    }
    /// notes-quality: today's stretch no block covers yet (still going, or waiting for its notes), by code from its threads
    /// (no model): the main thread and its side threads with their minutes, and what was sent or asked in them.
    func recallNow(day:String,timezone:String,now:Date) throws -> [String:Any]? {
        guard try hasLevelNotes(), try hasActionLayers() else { return nil }
        let assembled=try assembleDay(day:day,timezone:timezone,limit:1,now:now,notes:true,warmOnly:false)
        let covered=Set(try levelNotes(level:.block,periods:[day]).flatMap { $0.children.map(\.id) })
        let moments=assembled.day.activities.sorted { ($0.start,$0.id) < ($1.start,$1.id) }
        let open=moments.filter { !covered.contains($0.id) }
        guard let first=open.first, let last=open.map(\.end).max() else { return nil }
        let plan=try threadPlan(moments:moments,actions:assembled.actions)
        let threads=plan.threads(for:Set(open.map(\.id)))
        guard let main=threads.first else { return nil }
        let zone=TimeZone(identifier:timezone) ?? .current
        var out:[String:Any]=["level":"now","when":AssistantView.when(first.start,zone:zone)+" to "+AssistantView.clock(last,zone:zone),
                              "about":main.label,"minutes":max(1,Int((Double(main.seconds)/60).rounded())),
                              "written":"by code from what is on screen; no note is written for this stretch yet"]
        if let line=main.intent { out["line"]=line }
        let side=LevelThreads.bullets(threads,max:LevelThreads.maxBullets(.block)).map(\.text)
        if !side.isEmpty { out["lines"]=side }
        out["moments"]=open.suffix(8).map { momentSummary($0,day:day,timezone:timezone) }
        return out
    }
    func momentSummary(_ m:ActivityNote,day:String,timezone:String) -> [String:Any] {
        let zone=TimeZone(identifier:timezone) ?? .current
        var out:[String:Any]=["level":"moment","when":AssistantView.when(m.start,zone:zone)+" to "+AssistantView.clock(m.end,zone:zone),
                              "apps":m.apps.map { AppNames.display(app:$0,bundle:"") },"open":"moment:\(m.id)@\(day)"]
        if let note=m.generated {
            // notes-quality: the sent or asked line first, never a line that says nothing.
            let lines=note.output.bullets.map(\.text)
            out["title"]=note.output.title; out["preview"]=MomentGist.intent(lines) ?? lines.first { !Self.recallFiller($0) } ?? ""
        }
        else { out["title"]=m.subject; out["written"]="no note yet" }
        return out
    }
    func recallChildren(level:LevelKind,period:String,timezone:String,now:Date) throws -> [[String:Any]] {
        switch level {
        case .month:
            let weeks=try rows("SELECT DISTINCT period FROM level_notes WHERE level='week'").map { $0[0] }.filter { Self.monthKey(week:$0,timezone:timezone) == period }.sorted()
            return try weeks.map { levelNode(try levelNote(Self.levelID(.week,period:$0,timezone:timezone)),level:.week,period:$0,timezone:timezone) }
        case .week:
            return try Self.days(week:period,timezone:timezone).compactMap { day -> [String:Any]? in
                if let n=try levelNote(Self.levelID(.day,period:day,timezone:timezone)) { return levelNode(n,level:.day,period:day,timezone:timezone) }
                let blocks=try levelNotes(level:.block,periods:[day])
                guard !blocks.isEmpty else { return nil }
                return ["level":"day","when":day,"open":"day:"+day,"written":"not written yet","blocks":blocks.map(\.title)]
            }
        case .day:
            let blocks=try levelNotes(level:.block,periods:[period])
            if !blocks.isEmpty { return blocks.map { levelNode($0,level:.block,period:period,timezone:timezone) } }
            // No blocks yet: the moments themselves, folded as a day's recall shows them (claude/recall-1004).
            return foldedMoments(try dayLayers(day:period,timezone:timezone,limit:1,now:now).activities,day:period,timezone:timezone).rows
        case .block: return []
        }
    }
    /// Blocks of a day that overlap a part of it (all of them without a part); moments when no block is written yet.
    func recallBlocks(day:String,part:String?,timezone:String,now:Date) throws -> [String:Any] {
        let c=Self.calendar(timezone)
        let bounds:(Int,Int)? = part.map { p in p == "morning" ? (5,12) : p == "afternoon" ? (12,17) : p == "evening" ? (17,22) : (22,29) }
        func overlaps(_ start:String,_ end:String) -> Bool {
            guard let b=bounds, let s=timestamp(start), let e=timestamp(end), let dayStart=try? DayScope.interval(day:day,timezone:timezone).start,
                  let lo=c.date(byAdding:.hour,value:b.0,to:dayStart), let hi=c.date(byAdding:.hour,value:b.1,to:dayStart) else { return true }
            return s < hi && e > lo
        }
        let blocks=try levelNotes(level:.block,periods:[day]).filter { overlaps($0.start,$0.end) }
        var out:[String:Any]=["level":"block","when":day+(part.map { " "+$0 } ?? "")]
        if !blocks.isEmpty {
            out["blocks"]=blocks.map { levelNode($0,level:.block,period:day,timezone:timezone) }
        } else {
            out["written"]="no blocks written yet; these are the moments"
            let rows=foldedMoments(try dayLayers(day:day,timezone:timezone,limit:1,now:now).activities.filter { overlaps($0.start,$0.end) },day:day,timezone:timezone)
            out["moments"]=rows.rows
            rows.describe(into:&out)
        }
        return out
    }

    // MARK: search every level

    /// N12: note hits for the search tool (typed words stay unsearchable; the notes about them are searchable).
    public func noteHits(query:String,limit:Int=5,now:Date=Date()) throws -> [[String:Any]] {
        try recallSearch(query,timezone:TimeZone.current.identifier,now:now,limit:limit)
    }

    static func folded(_ s:String) -> [String] {
        s.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:nil).components(separatedBy:CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    /// Every query word must start a word of the text ("email" finds "Emailed", "ask" finds "Asked").
    static func recallMatches(_ words:[String],_ text:String) -> Bool {
        let have=folded(text)
        return words.allSatisfy { w in have.contains { $0.hasPrefix(w) } }
    }
    func recallSearch(_ query:String,timezone:String,now:Date,limit:Int=20) throws -> [[String:Any]] {
        let words=Self.folded(query)
        guard !words.isEmpty else { return [] }
        let zone=TimeZone(identifier:timezone) ?? .current
        var hits=[(at:String,hit:[String:Any])]()
        // Levels: the title, or a line (with the title for context).
        for note in try allLevelNotes() {
            let open=note.level.rawValue+":"+(note.level == .block ? note.id : note.period)
            let when=note.level == .block ? AssistantView.when(note.start,zone:zone) : Self.childLabel(note,timezone:timezone)
            if let line=note.lines.first(where:{ Self.recallMatches(words,$0.text) && !Self.recallFiller($0.text) }) {
                hits.append((note.start,["level":note.level.rawValue,"when":when,"text":line.text,"in":note.title,"open":open]))
            } else if Self.recallMatches(words,note.title) || Self.recallMatches(words,note.title+" "+note.lines.map(\.text).joined(separator:" ")) {
                hits.append((note.start,["level":note.level.rawValue,"when":when,"text":note.title,"open":open]))
            }
        }
        // Moments (their title) and lines (each bullet, with the time of its first action).
        if try hasActionLayers() {
            for row in try rows("SELECT g.body FROM generated_notes g WHERE g.version=(SELECT max(version) FROM generated_notes h WHERE h.id=g.id) AND g.id NOT LIKE 'day_%'") {
                guard let note=try? decode(GeneratedNote.self,row[0]) else { continue }
                let times=try rows("SELECT id,json_extract(body,'$.at') FROM records WHERE id IN (SELECT value FROM json_each(?))",[json(note.actionIDs)])
                var at=[String:String](); for r in times { at[r[0]]=r[1] }
                guard let first=at.values.min() else { continue }
                let day=(try? DayScope.key(timestamp(first) ?? now,timezone:timezone)) ?? ""
                let open="moment:\(note.id)@\(day)"
                var matched=false
                for b in note.output.bullets where Self.recallMatches(words,b.text) && !Self.recallFiller(b.text) {
                    let t=b.actionIDs.compactMap { at[$0] }.min() ?? first
                    hits.append((t,["level":"line","when":AssistantView.when(t,zone:zone),"text":b.text,"in":note.output.title,"state":b.assertion,"open":open]))
                    matched=true
                }
                if !matched, Self.recallMatches(words,note.output.title+" "+note.output.bullets.map(\.text).joined(separator:" ")) {
                    hits.append((first,["level":"moment","when":AssistantView.when(first,zone:zone),"text":note.output.title,"open":open]))
                }
            }
        }
        // notes-quality: what was sent or asked first ("Texted Q7 about Friday dinner."), then the other lines (a block's
        // "Q3 investor update, ~1 hr" says how long), then moments and blocks, then days, weeks and months (an AI app zooms
        // out with "in" and "open"); the newest first within each.
        func tier(_ h:[String:Any]) -> Int {
            let text=h["text"] as? String ?? ""
            if h["level"] as? String == "line", MomentGist.intent([text]) != nil { return 0 }
            let level=h["level"] as? String ?? ""
            if level == "line" || (h["in"] != nil && level != "moment") { return 1 }
            return level == "moment" || level == "block" ? 2 : 3
        }
        return hits.sorted { (tier($0.hit),$1.at) < (tier($1.hit),$0.at) }.prefix(limit).map(\.hit)
    }
    /// notes-quality: lines that say nothing (the day card leaves them out too): "Had the inbox open.", "Wrote a message
    /// in Messages.", "Typed in Chrome.", "Used Slack.". Never served as a hit. fix/sx-all round 2: the one shared list
    /// (`NoteFiller`, the writer's own rule), so recall keeps "Wrote an email to Dana about the offsite".
    static func recallFiller(_ text:String) -> Bool { NoteFiller.isFiller(text, apps: []) }
}
