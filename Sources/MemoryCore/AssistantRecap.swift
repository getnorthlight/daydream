import Foundation

/// MCP `recap` (mcp-recap-1002): a few days at a glance, pre-grouped so an AI app answers "what has my week been like?"
/// as a one-line answer and a short section per day, not as a wall of every visit with a time in each sentence.
///
/// Per day: a headline, then up to five time blocks (part of the day, theme, apps and sites, and at most three lines with
/// what was sent, asked, written or worked on first). Brief visits and utility noise are counted, never listed.
///
/// Built only from what `open` (day overview) and `recall` already give an AI app under the same `detail` grant: the
/// day, block and moment notes DayDream wrote, the threads' code names, app names and sites. Never typed words: typed
/// rows reach this only as the notes and thread labels about them, exactly as in `recall`.
extension MemoryStore {
    /// Most days in one recap ("past couple days" is 2, "this week" up to 7).
    public static let recapMaxDays = 7
    /// The reply stays under this many bytes (about 2,000 tokens): lines, then blocks, are trimmed until it fits.
    public static let recapMaxBytes = 8_000
    /// A moment with less focus than this, and nothing sent or asked in it, is a brief visit.
    static let recapBriefSeconds = 120
    /// A block with less focus than this, and nothing sent or asked in it, is left out (its moments counted as brief).
    static let recapMinBlockSeconds = 180
    /// Apps that are only the way to something else; under five minutes they are noise.
    static let recapUtilityApps: Set<String> = ["finder", "system settings", "system preferences", "activity monitor", "app store",
                                               "loginwindow", "dock", "spotlight", "notification center", "control center",
                                               "daydream", "mac mem", "macmem", "screenshot", "archive utility", "installer"]

    public static let recapPresent = "Answer with one plain line first. Then a bold header per day (e.g. Thu, Oct 1) and 2-5 short bullets, one per block: start with its when, then what happened, signal first (sent, asked, wrote, worked on). Times only as those block anchors. Don't list left-out visits. Plain words: no ids, links, app bundle names or tool names. At most one short caveat, at the end, only if it matters."

    public func assistantRecap(when raw:String?,timezone:String?=nil,now:Date=Date()) throws -> String {
        let tz=timezone.flatMap { TimeZone(identifier:$0) != nil ? $0 : nil } ?? TimeZone.current.identifier
        let zone=TimeZone(identifier:tz) ?? .current
        guard let days=try Self.recapDays(when:raw ?? "",timezone:tz,now:now) else {
            throw MemError.invalid("Couldn't read the time \"\(raw ?? "")\". Use today, yesterday, past 2 days, this week, last week, a weekday, or a date like 2026-09-22.")
        }
        let shown=Array(days.suffix(Self.recapMaxDays))
        let built=try shown.map { try recapDay($0,timezone:tz,now:now) }
        var out:[String:Any]=["range":Self.recapRangeLabel(shown,timezone:tz),"timezone":AssistantView.zoneLabel(zone,at:now),
                              "present":Self.recapPresent,
                              "about":"Lines are DayDream's notes, written by a model from what was on screen; they can be wrong."]
        if days.count > shown.count { out["earlier_days_not_shown"]=days.count-shown.count }
        // Fit the bound: fewer lines per block, then fewer blocks per day, then fewer apps.
        for (lines,blocks,apps) in [(3,5,4),(2,5,3),(2,4,2),(1,3,2),(1,2,1)] {
            out["days"]=built.map { $0.json(lines:lines,blocks:blocks,apps:apps) }
            if let text=AssistantView.serialize(out), text.utf8.count <= Self.recapMaxBytes { return text }
        }
        out["days"]=built.map { $0.json(lines:0,blocks:1,apps:1) }
        return AssistantView.serialize(out) ?? "{}"
    }

    // MARK: one day

    struct RecapItem { var tier:Int; var text:String }
    struct RecapBlock {
        var start:Date; var end:Date; var about:String; var seconds:Int
        var items:[RecapItem]; var apps:[(String,Int)]; var sites:[(String,Int)]
    }
    struct RecapDay {
        var date:String; var label:String; var headline:String?; var quiet:String?
        var blocks:[RecapBlock]; var brief:Int; var zone:TimeZone
        func json(lines:Int,blocks maxBlocks:Int,apps:Int) -> [String:Any] {
            var d:[String:Any]=["day":label,"date":date]
            // claude/dayeval-1005: never "draft" to an AI app (the lines were chosen on the stored words).
            if let headline { d["headline"]=DisplayWords.undraft(headline) }
            if let quiet { d["quiet"]=quiet }
            let kept=MemoryStore.recapMerge(blocks,max:maxBlocks,zone:zone)
            let labels=MemoryStore.recapAnchors(kept.map(\.start),kept.map(\.end),zone:zone)
            if !kept.isEmpty {
                d["blocks"]=zip(kept,labels).map { b,when -> [String:Any] in
                    var x:[String:Any]=["when":when,"about":b.about,"minutes":max(1,Int((Double(b.seconds)/60).rounded()))]
                    let did=MemoryStore.recapChoose(b.items,max:lines)
                    if !did.isEmpty { x["did"]=did.map(DisplayWords.undraft) }
                    let a=b.apps.sorted { $0.1 > $1.1 }.prefix(apps).map(\.0)
                    if !a.isEmpty { x["apps"]=Array(a) }
                    let s=b.sites.sorted { $0.1 > $1.1 }.prefix(max(0,apps-1)).map(\.0)
                    if !s.isEmpty { x["sites"]=Array(s) }
                    return x
                }
            }
            if brief > 0 { d["left_out"]="\(brief) brief visit\(brief == 1 ? "" : "s")" }
            return d
        }
    }

    func recapDay(_ day:String,timezone:String,now:Date) throws -> RecapDay {
        let zone=TimeZone(identifier:timezone) ?? .current
        let label=Self.recapDayLabel(day,timezone:timezone)
        let assembled:AssembledDay
        do { assembled=try assembleDay(day:day,timezone:timezone,limit:1,now:now,notes:true) }
        catch MemError.invalid(let message) where message == Self.dayChanged { assembled=try assembleDay(day:day,timezone:timezone,limit:1,now:now,notes:true) }
        let moments=assembled.day.activities.sorted { ($0.start,$0.id) < ($1.start,$1.id) }
        guard !moments.isEmpty, let live=try liveDay(assembled,timezone:timezone) else {
            return RecapDay(date:day,label:label,headline:nil,quiet:"Nothing recorded.",blocks:[],brief:0,zone:zone)
        }
        let byID=Dictionary(moments.map { ($0.id,$0) },uniquingKeysWith:{ a,_ in a })
        let levels=try hasLevelNotes()
        let dayNote=levels ? try levelNote(Self.levelID(.day,period:day,timezone:timezone)) : nil
        let blockNotes=levels ? try levelNotes(level:.block,periods:[day]).sorted { ($0.start,$0.id) < ($1.start,$1.id) } : []

        // Stretches: the written blocks first (their goal names them), then the live threads' blocks for what no block
        // note covers yet (today's open stretch, or a day whose summaries are off).
        var stretches=[(ids:[String],about:String,lines:[String])]()
        var covered=Set<String>()
        for note in blockNotes {
            let ids=note.children.map(\.id).filter { byID[$0] != nil && !covered.contains($0) }
            guard !ids.isEmpty else { continue }
            covered.formUnion(ids)
            stretches.append((ids,Self.recapGoal(note.title),note.lines.map(\.text)))
        }
        for b in live.blocks {
            let ids=b.moments.filter { byID[$0] != nil && !covered.contains($0) }
            guard !ids.isEmpty else { continue }
            covered.formUnion(ids)
            stretches.append((ids,b.label,b.side))
        }
        let orphans=moments.map(\.id).filter { !covered.contains($0) }
        if !orphans.isEmpty { stretches.append((orphans,"",[])) }

        var blocks=[RecapBlock](), brief=0
        for s in stretches {
            var kept=[ActivityNote](), items=[RecapItem]()
            for id in s.ids {
                guard let m=byID[id], let lm=live.moments[id], !lm.idle else { continue }
                // claude/catchup-1003: an earlier writer's note stays readable until it is rewritten (as on the Today page).
                let bullets=(m.generated ?? m.previous)?.output.bullets ?? []
                let intent=MomentGist.intent(bullets.map(\.text))
                let apps=m.apps.map { AppNames.display(app:$0,bundle:"").lowercased() }
                let utility = !apps.isEmpty && apps.allSatisfy(Self.recapUtilityApps.contains)
                // A glance: little focus, one or two actions (check-ins minutes apart each count up to five minutes of
                // focus), a utility app, or nothing in its note but filler. A sent or asked line is never a glance.
                let said=bullets.contains { !Self.recallFiller($0.text) }
                let steps=m.actionIDs.filter { (assembled.actions[$0]?.kind ?? "idle") != "idle" }.count
                if intent == nil && (lm.seconds < Self.recapBriefSeconds || steps <= 2 || (utility && lm.seconds < 300) || (!said && lm.seconds < 300)) {
                    brief += 1; continue
                }
                kept.append(m)
                // claude/summary-1003 (owner): code's place-only lines only when nothing says more; each line once.
                for b in SummaryLines.tidy(bullets,cap:.max,text:{ $0.text }) {
                    let text=b.text.trimmingCharacters(in:.whitespacesAndNewlines)
                    guard !text.isEmpty, !Self.recallFiller(text) else { continue }
                    items.append(RecapItem(tier:Self.recapTier(text,assertion:b.assertion,intent:intent),text:Self.recapLabel(text,assertion:b.assertion)))
                }
            }
            guard !kept.isEmpty else { continue }
            let seconds=kept.reduce(0) { $0+(live.moments[$1.id]?.seconds ?? 0) }
            let signal=items.contains { $0.tier == 0 }
            if seconds < Self.recapMinBlockSeconds && !signal { brief += kept.count; continue }
            // The block's own lines (a written block's thread lines, or the live threads' names with minutes) fill in
            // after the moments' notes; a bare app name with minutes ("Finder, ~15 min") says nothing and is left out.
            let appNames=Set(kept.flatMap { $0.apps.map { AppNames.display(app:$0,bundle:"").lowercased() } }).union(Self.recapUtilityApps)
            // Once the moments have notes, only the block's sent or asked lines are added (its thread names would repeat them).
            let noted = !items.isEmpty
            for line in s.lines {
                let text=line.trimmingCharacters(in:.whitespacesAndNewlines)
                let name=text.components(separatedBy:", ~").first?.lowercased() ?? ""
                guard !text.isEmpty, !Self.recallFiller(text), !appNames.contains(name) else { continue }
                let tier=Self.recapTier(text,assertion:"observed",intent:MomentGist.intent([text]))
                if noted && tier != 0 { continue }
                items.append(RecapItem(tier:tier == 0 ? 0 : 3,text:text))
            }
            var apps=[String:Int](), sites=[String:Int](), appOrder=[String](), siteOrder=[String]()
            for m in kept {
                let sec=max(1,live.moments[m.id]?.seconds ?? 1)
                for a in m.apps.map({ AppNames.display(app:$0,bundle:"") }) where !a.isEmpty {
                    if apps[a] == nil { appOrder.append(a) }; apps[a,default:0]+=sec
                }
                for site in m.sites where !site.isEmpty {
                    if sites[site] == nil { siteOrder.append(site) }; sites[site,default:0]+=sec
                }
            }
            let start=kept.compactMap { timestamp($0.start) }.min() ?? .distantPast, end=kept.compactMap { timestamp($0.end) }.max() ?? start
            var about=s.about.trimmingCharacters(in:.whitespacesAndNewlines)
            if about.isEmpty || Self.recallFiller(about) {
                let main=kept.max { (live.moments[$0.id]?.seconds ?? 0) < (live.moments[$1.id]?.seconds ?? 0) }
                about=main.flatMap { live.moments[$0.id]?.label } ?? appOrder.first ?? ""
            }
            blocks.append(RecapBlock(start:start,end:end,about:about,seconds:seconds,items:items,
                                     apps:appOrder.map { ($0,apps[$0]!) },sites:siteOrder.map { ($0,sites[$0]!) }))
        }
        blocks.sort { $0.start < $1.start }
        // One part of the day, one bullet: neighbouring blocks in the same part of the day with under half an hour
        // between them read as one ("Evening: asked Claude about X; looked up Y").
        var i=0
        while i+1 < blocks.count {
            if Self.recapPart(blocks[i].start,zone:zone) == Self.recapPart(blocks[i+1].start,zone:zone),
               blocks[i+1].start.timeIntervalSince(blocks[i].end) <= 30*60 {
                blocks.replaceSubrange(i...i+1,with:[Self.recapJoin(blocks[i],blocks[i+1])])
            } else { i += 1 }
        }
        var headline:String?
        if let note=dayNote, !DayLevels.savedPlain(note), !note.title.isEmpty { headline=note.title }
        else if !live.mainTitle.isEmpty { headline="Mostly "+Self.recapLower(live.mainTitle)+"." }
        let quiet:String? = blocks.isEmpty ? (brief > 0 ? "Only brief visits." : "Nothing recorded.") : nil
        return RecapDay(date:day,label:label,headline:blocks.isEmpty ? nil : headline,quiet:quiet,blocks:blocks,brief:brief,zone:zone)
    }

    // MARK: ranking and merging

    /// 0: sent or asked (or a draft to someone); 1: wrote, searched, worked on, read, looked up; 2: everything else.
    static func recapTier(_ text:String,assertion:String,intent:String?) -> Int {
        if let intent, intent == text { return 0 }
        if MomentGist.intent([text]) != nil { return 0 }
        let lead=text.split(separator:" ").first.map { String($0).lowercased() } ?? ""
        let made:Set<String>=["wrote","searched","worked","edited","built","fixed","reviewed","read","looked","researched","planned","organized",
                              "updated","drafted","created","designed","debugged","tested","compared","booked","paid","ordered","watched","studied","practiced"]
        return made.contains(lead) ? 1 : 2
    }
    static func recapLabel(_ text:String,assertion:String) -> String {
        switch assertion {
        case "draft": return DisplayWords.undraft(text)
        case "reported": return "(reported) "+text
        default: return text
        }
    }
    /// At most `max` lines, signal first, no repeats, each under 140 characters.
    static func recapChoose(_ items:[RecapItem],max:Int) -> [String] {
        guard max > 0 else { return [] }
        var seen=Set<String>(), out=[String]()
        for item in items.enumerated().sorted(by: { ($0.element.tier,$0.offset) < ($1.element.tier,$1.offset) }).map(\.element) {
            // Lines that differ only by a number ("case 1", "case 2") are one line.
            let key=item.text.lowercased().components(separatedBy:.decimalDigits).joined().trimmingCharacters(in:CharacterSet(charactersIn:". "))
            guard seen.insert(key).inserted else { continue }
            out.append(item.text.count > 140 ? String(item.text.prefix(137)).trimmingCharacters(in:.whitespaces)+"..." : item.text)
            if out.count == max { break }
        }
        return out
    }
    /// Adjacent blocks merged (the lightest neighbouring pair first, same part of the day first) until at most `max`.
    static func recapMerge(_ blocks:[RecapBlock],max:Int,zone:TimeZone) -> [RecapBlock] {
        var b=blocks
        while b.count > Swift.max(1,max) {
            func part(_ x:RecapBlock) -> String { recapPart(x.start,zone:zone) }
            var best=0, bestKey=(1,Int.max)
            for i in 0..<(b.count-1) {
                let key=(part(b[i]) == part(b[i+1]) ? 0 : 1,b[i].seconds+b[i+1].seconds)
                if key < bestKey { bestKey=key; best=i }
            }
            b.replaceSubrange(best...best+1,with:[recapJoin(b[best],b[best+1])])
        }
        return b
    }
    /// Two neighbouring blocks as one: the heavier one's theme, both blocks' lines (the heavier's first), apps and sites.
    static func recapJoin(_ x:RecapBlock,_ y:RecapBlock) -> RecapBlock {
        let heavy=x.seconds >= y.seconds ? x : y
        var m=heavy
        m.start=x.start; m.end=max(x.end,y.end); m.seconds=x.seconds+y.seconds
        m.items=heavy.items+(heavy.start == x.start ? y.items : x.items)
        func add(_ a:[(String,Int)],_ b:[(String,Int)]) -> [(String,Int)] {
            var total=[String:Int](), order=[String]()
            for (k,v) in a+b { if total[k] == nil { order.append(k) }; total[k,default:0]+=v }
            return order.map { ($0,total[$0]!) }
        }
        m.apps=add(x.apps,y.apps); m.sites=add(x.sites,y.sites)
        return m
    }

    // MARK: words for time

    /// The part of the day each block starts in ("Morning"); where two blocks of a day would share one, their clock
    /// ranges instead ("2:05–3:10 PM").
    static func recapAnchors(_ starts:[Date],_ ends:[Date],zone:TimeZone) -> [String] {
        let pairs=zip(starts,ends).map { (recapClockRange($0,$1,zone:zone),recapPart($0,zone:zone)) }
        var counts=[String:Int](); for p in pairs { counts[p.1,default:0]+=1 }
        return pairs.map { counts[$0.1]! > 1 ? $0.0 : $0.1 }
    }
    static func recapPart(_ date:Date,zone:TimeZone) -> String {
        var c=Calendar(identifier:.gregorian); c.timeZone=zone
        switch c.component(.hour,from:date) {
        case 0..<5: return "After midnight"
        case 5..<12: return "Morning"
        case 12..<17: return "Afternoon"
        case 17..<21: return "Evening"
        default: return "Late evening"
        }
    }
    /// "9:05–11:40 AM", "11:20 PM–midnight", "11:50 AM–12:30 PM".
    static func recapClockRange(_ start:Date,_ end:Date,zone:TimeZone) -> String {
        var c=Calendar(identifier:.gregorian); c.timeZone=zone
        func parts(_ d:Date,isEnd:Bool) -> (String,String) {
            let h=c.component(.hour,from:d), m=c.component(.minute,from:d)
            if isEnd && (h == 23 && m >= 55 || h == 0 && m == 0) { return ("midnight","") }
            if h == 12 && m == 0 { return ("noon","") }
            let hour=h%12 == 0 ? 12 : h%12
            return (m == 0 ? "\(hour)" : String(format:"%d:%02d",hour,m),h < 12 ? "AM" : "PM")
        }
        let a=parts(start,isEnd:false), b=parts(end,isEnd:true)
        if end.timeIntervalSince(start) < 60 { return a.1.isEmpty ? a.0 : a.0+" "+a.1 }
        let left=a.1.isEmpty || a.1 == b.1 ? a.0 : a.0+" "+a.1
        return left+"–"+(b.1.isEmpty ? b.0 : b.0+" "+b.1)
    }
    /// "Moving docs to Notion" -> "moving docs to Notion" after "Mostly"; names ("Biology 101", "Tallybird code") keep their case.
    static func recapLower(_ text:String) -> String {
        guard let first=text.split(separator:" ").first, first.count > 1, first.dropFirst().allSatisfy({ $0.isLowercase }), first.hasSuffix("ing") else { return text }
        return text.prefix(1).lowercased()+text.dropFirst()
    }
    /// A block title is "<span>: <goal>" ("About 45 minutes: fixing the export crash"): the goal, capitalized.
    static func recapGoal(_ title:String) -> String {
        var goal=title
        if let colon=title.range(of:": ") { goal=String(title[colon.upperBound...]) }
        goal=goal.trimmingCharacters(in:CharacterSet(charactersIn:". "))
        return goal.prefix(1).uppercased()+goal.dropFirst()
    }
    static func recapDayLabel(_ day:String,timezone:String) -> String {
        guard let start=try? DayScope.interval(day:day,timezone:timezone).start else { return day }
        let f=DateFormatter(); f.locale=Locale(identifier:"en_US_POSIX"); f.timeZone=TimeZone(identifier:timezone); f.dateFormat="EEE, MMM d"
        return f.string(from:start.addingTimeInterval(3600))
    }
    static func recapRangeLabel(_ days:[String],timezone:String) -> String {
        guard let first=days.first, let last=days.last else { return "" }
        return first == last ? recapDayLabel(first,timezone:timezone) : recapDayLabel(first,timezone:timezone)+" to "+recapDayLabel(last,timezone:timezone)
    }

    /// The local days a recap covers, oldest first: today, yesterday, past N days, past couple/few days, this week,
    /// last week, a weekday, N days ago, a date, or "A to B". nil when the words can't be read.
    static func recapDays(when raw:String,timezone:String,now:Date) throws -> [String]? {
        let c=calendar(timezone)
        let text=raw.lowercased().trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"  ",with:" ")
        func key(_ d:Date) throws -> String { try DayScope.key(d,timezone:timezone) }
        func back(_ n:Int) throws -> [String] { try (0..<n).reversed().map { try key(c.date(byAdding:.day,value:-$0,to:now) ?? now) } }
        if text.isEmpty || text == "today" { return try back(1) }
        let words=["one":1,"a":1,"two":2,"couple":2,"couple of":2,"three":3,"few":3,"a few":3,"four":4,"five":5,"six":6,"seven":7,"several":4]
        if let r=text.range(of:"^(the )?(past|last|previous) (a |the )?([a-z0-9 ]+?) days?$",options:.regularExpression) {
            var middle=String(text[r]).replacingOccurrences(of:"^(the )?(past|last|previous) (a |the )?",with:"",options:.regularExpression)
            middle=middle.replacingOccurrences(of:" days?$",with:"",options:.regularExpression).trimmingCharacters(in:.whitespaces)
            guard let n=Int(middle) ?? words[middle], n >= 1 else { return nil }
            return try back(min(n,31))
        }
        if ["past day","last day","past 24 hours","last 24 hours"].contains(text) { return try back(2) }
        if text == "this week" || text == "last week" {
            let base=text == "this week" ? now : c.date(byAdding:.day,value:-7,to:now) ?? now
            guard let week=weekKey(day:try key(base),timezone:timezone) else { return nil }
            let today=try key(now)
            return days(week:week,timezone:timezone).filter { $0 <= today }
        }
        for sep in [" to "," through "," until ",".."," - "] where text.contains(sep) {
            let ends=text.components(separatedBy:sep)
            guard ends.count == 2, let a=try recapPeriod(ends[0],timezone:timezone,now:now), let b=try recapPeriod(ends[1],timezone:timezone,now:now), a <= b,
                  let from=try? DayScope.interval(day:a,timezone:timezone).start else { return nil }
            var out=[String](), d=from
            while out.count < 31, let k=try? key(d), k <= b { out.append(k); d=c.date(byAdding:.day,value:1,to:d) ?? d.addingTimeInterval(86400) }
            return out
        }
        return try recapPeriod(text,timezone:timezone,now:now).map { [$0] }
    }
    static func recapPeriod(_ text:String,timezone:String,now:Date) throws -> String? {
        try recallPeriod(level:"day",when:text.trimmingCharacters(in:.whitespaces),timezone:timezone,now:now)?.key
    }
}
