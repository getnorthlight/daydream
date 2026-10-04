import Foundation

public struct ObservationCluster: Codable, Equatable {
    public var actionIDs:[String]
    public var firstObservedAt:String
    public var lastObservedAt:String
}
public struct ActivityNote: Codable, Identifiable {
    public var id:String
    public var day:String
    public var timezone:String
    public var subject:String
    public var actionIDs:[String]
    public var apps:[String]
    public var sites:[String]
    public var start:String
    public var end:String
    public var clusters:[ObservationCluster]
    public var inputRevision:String
    public var status:String
    public var generated:GeneratedNote?
    public var corrections:[UserCorrection]? = nil
    /// Distinct non-empty member bundle IDs, most member actions first, then by ID.
    /// Display metadata, never part of inputRevision, so stored notes stay valid.
    /// nil only when decoded from JSON written before this field existed; [] means
    /// no member carried a bundle (e.g. imported days). Icon and primary-app callers
    /// treat [] like nil and still resolve any app in `apps` that has no bundle.
    public var bundles:[String]? = nil
    /// Member action count per non-empty bundle ID. Actions without a bundle are
    /// not counted. Same derivation rule and fingerprint exclusion as bundles.
    public var bundleActionCounts:[String:Int]? = nil
    /// summaries/v3: website typing rows among the members (NoteAudience.webTyped), which cloud summaries may read though
    /// their bundle is a browser. Derived like bundleActionCounts and, like it, not part of any fingerprint.
    public var webTypedCount:Int? = nil
    /// fix/day-card (stale-while-updating): the newest note stored for this moment's id when none is stored for its
    /// current input (the moment grew, the threads or the policy moved), so the page keeps showing it while the newer
    /// one is written. Display only: never read by the writer, never part of any revision, never encoded. Only a note
    /// about actions the moment still holds (a Forget deletes every note citing a forgotten action). nil when
    /// `generated` is set.
    public var previous:GeneratedNote? = nil
    private enum CodingKeys:String,CodingKey {
        case id,day,timezone,subject,actionIDs,apps,sites,start,end,clusters,inputRevision,status,generated,corrections,bundles,bundleActionCounts,webTypedCount
    }
}
public struct DaySummary: Codable {
    public var day:String
    public var timezone:String
    public var start:String
    public var end:String
    public var activityIDs:[String]
    public var actionCount:Int
    public var countIsComplete:Bool
    public var inputRevision:String
    public var status:String
    public var generated:GeneratedNote?
    public var corrections:[UserCorrection]? = nil
    /// fix/day-card: the newest day note stored for the day when none is stored for its current input. Display only,
    /// never encoded (see `ActivityNote.previous`).
    public var previous:GeneratedNote? = nil
    private enum CodingKeys:String,CodingKey {
        case day,timezone,start,end,activityIDs,actionCount,countIsComplete,inputRevision,status,generated,corrections
    }
}
public struct ActionDay: Codable {
    public var summary:DaySummary
    public var activities:[ActivityNote]
    public var actions:ActionPage
    public var defaultLayer:String
    public var partial:Bool
    /// summaries/v3 levels: the day's block, day and week notes (`MemoryStore.dayLevels`). Not filled by `dayLayers`
    /// itself (the level writer reads days through it); the app's day loader adds it. nil: not read.
    public var levels:DayLevels? = nil
}
public enum DayScope {
    /// gold r3-store: a day's interval is the same every time it is asked for, and it was made again for every moment
    /// (a DateFormatter and a regular expression each time: most of the Today list's build on the main thread, 100-220 ms
    /// on a long day in a debug build). Kept per day and zone once made; only valid days are kept.
    public static func interval(day:String,timezone:String) throws -> DateInterval {
        let key=day+"|"+timezone
        intervalLock.lock()
        if let known=intervals[key] { intervalLock.unlock(); return known }
        intervalLock.unlock()
        guard day.range(of:"^\\d{4}-\\d{2}-\\d{2}$",options:.regularExpression) != nil, let zone=TimeZone(identifier:timezone) else { throw MemError.invalid("Exact calendar date and IANA timezone required") }
        var calendar=Calendar(identifier:.gregorian); calendar.timeZone=zone
        let f=DateFormatter(); f.locale=Locale(identifier:"en_US_POSIX"); f.calendar=calendar; f.timeZone=zone; f.dateFormat="yyyy-MM-dd"; f.isLenient=false
        guard let date=f.date(from:day), f.string(from:date) == day, let interval=calendar.dateInterval(of:.day,for:date) else { throw MemError.invalid("Invalid local day") }
        intervalLock.lock()
        if intervals.count >= 512 { intervals.removeAll(keepingCapacity:true) }
        intervals[key]=interval
        intervalLock.unlock()
        return interval
    }
    private static let intervalLock=NSLock()
    nonisolated(unsafe) private static var intervals=[String:DateInterval]()
    /// fix/perf7: one formatter per time zone (a DateFormatter costs far more to make than to use; this runs per row
    /// and per search hit). Formatting happens under the lock; at most one entry per IANA zone.
    public static func key(_ date:Date,timezone:String) throws -> String {
        keyLock.lock(); defer { keyLock.unlock() }
        if let f=keyFormatters[timezone] { return f.string(from:date) }
        guard let zone=TimeZone(identifier:timezone) else { throw MemError.invalid("Unknown timezone") }
        let f=DateFormatter(); f.locale=Locale(identifier:"en_US_POSIX"); f.calendar=Calendar(identifier:.gregorian); f.timeZone=zone; f.dateFormat="yyyy-MM-dd"
        if keyFormatters.count >= 64 { keyFormatters.removeAll(keepingCapacity:true) }
        keyFormatters[timezone]=f
        return f.string(from:date)
    }
    private static let keyLock=NSLock()
    nonisolated(unsafe) private static var keyFormatters=[String:DateFormatter]()
}
extension MemoryStore {
    func setupActionLayers() throws {
        try exec("CREATE TABLE IF NOT EXISTS action_group_edits(sequence INTEGER PRIMARY KEY AUTOINCREMENT,action_id TEXT NOT NULL,subject TEXT NOT NULL)")
        try exec("CREATE TABLE IF NOT EXISTS note_requests(id TEXT PRIMARY KEY,body TEXT NOT NULL,state TEXT NOT NULL)")
        try exec("CREATE TABLE IF NOT EXISTS generated_notes(id TEXT NOT NULL,version INTEGER NOT NULL,input_revision TEXT NOT NULL,body TEXT NOT NULL,PRIMARY KEY(id,version))")
        try setupLevelNotes()
        try stampContinuationSince()
    }
    /// gold/notes G22: a store from before the continuation rule (its policy has no `continuationSince`) gets the time
    /// of this first writable open, once. Its existing days keep test 4's moments, ids and revisions, so the notes
    /// written for them stay ready. The policy revision does not change: nothing a capture or a grant checks moves.
    private func stampContinuationSince(now:Date=Date()) throws {
        guard let raw=try rows("SELECT body FROM metadata WHERE id='policy'").first?.first,
              var current=try? decode(PrivacySettings.self,raw), current.continuationSince == nil else { return }
        try transaction {
            guard let again=try rows("SELECT body FROM metadata WHERE id='policy'").first?.first, again == raw else { return }
            current.continuationSince=now.timeIntervalSince1970
            try exec("UPDATE metadata SET body=? WHERE id='policy'",[json(current)])
        }
    }
    func hasActionLayers() throws -> Bool { !(try rows("SELECT name FROM sqlite_master WHERE name='note_requests'")).isEmpty }
    /// Explicit local UI edit, reversible by passing nil. No source evidence changes.
    public func setActionSubject(_ ids:[String],subject:String?,now:Date=Date()) throws {
        guard !ids.isEmpty, ids.count <= 200, subject == nil || (!subject!.isEmpty && subject!.count <= 160 && !Privacy.secret(subject!)) else { throw MemError.invalid("Invalid grouping edit") }
        try transaction {
            for id in Set(ids) {
                guard try action(id,now:now) != nil else { throw MemError.denied }
                try exec("INSERT INTO action_group_edits(action_id,subject) VALUES(?,?)",[id,subject ?? ""])
            }
            try invalidateDisclosure()
        }
    }
    func subject(for action:CanonicalAction) throws -> String {
        let edited=try hasActionLayers() ? try rows("SELECT subject FROM action_group_edits WHERE action_id=? ORDER BY sequence DESC LIMIT 1",[action.id]).first?.first : nil
        return Self.subject(for:action,edited:edited)
    }
    /// A moment's name for one action: a grouping edit when it has one, else its window title, else its site or app.
    static func subject(for action:CanonicalAction,edited:String?) -> String {
        if let edited, !edited.isEmpty { return edited }
        if !action.subject.isEmpty {
            if ["untitled","new tab","home","search","inbox"].contains(action.subject.lowercased()) {
                return action.subject+" · "+(action.site.isEmpty ? action.app : action.site)
            }
            return action.subject
        }
        return action.site.isEmpty ? action.app : action.site
    }
    static func titleWords(_ s:String)->[String] { s.lowercased().split(whereSeparator:{$0.isWhitespace}).map(String.init) }
    /// The window title an action shows, as continuation compares it.
    static func windowTitle(_ action:CanonicalAction)->String { action.subject.isEmpty ? action.title : action.subject }
    /// No real title: empty, or only the app's name (a chat before it gets its name, a typing row, a window without one).
    static func bareTitle(_ action:CanonicalAction)->Bool {
        let words=titleWords(windowTitle(action)); return words.isEmpty || words == titleWords(action.app)
    }
    /// Whether `next`, the action right after `last` in the day, continues `last`'s moment in one desktop app (sat5):
    /// the same app, no site, within a few minutes, and a window title that grew out of the moment's own last real
    /// title (`anchor`, gold/notes G23), so two different documents in one app stay two moments. An action with no
    /// real title may join, but never links the titles on either side of it; a moment with no real title yet (a
    /// chat before it gets its name) takes the next title in the same app.
    static let continuationGap:TimeInterval=5*60
    static func continues(_ last:CanonicalAction,at a:Date?,_ next:CanonicalAction,at b:Date?,anchor:String?)->Bool {
        guard last.site.isEmpty, next.site.isEmpty else { return false }
        let sameApp = !last.bundle.isEmpty && !next.bundle.isEmpty ? last.bundle == next.bundle : !last.app.isEmpty && last.app == next.app
        guard sameApp, let a, let b else { return false }
        let gap=b.timeIntervalSince(a)
        guard gap >= 0 && gap <= continuationGap else { return false }
        if bareTitle(next) { return true }
        guard let anchor else { return true }
        return relatedTitles(anchor,windowTitle(next),app:next.app)
    }
    /// Two window titles of one window as it changes: either is empty or only the app's name (a chat before it gets its
    /// name), or one is the start of the other, word by word ("Groceries" → "Groceries and errands"). The last word of
    /// the shorter may be a word still being typed ("err" → "errands"), but only if it has a letter: "Draft 1" and
    /// "Draft 10" are two documents, and so are "Untitled" and "Untitled 2" (a number added is another document).
    public static func relatedTitles(_ a:String,_ b:String,app:String)->Bool {
        let x=titleWords(a),y=titleWords(b),bare=titleWords(app)
        if x.isEmpty || y.isEmpty || x==bare || y==bare { return true }
        // fix/sx-all round 1: Mail's compose window is "New Message" until a subject is typed: the subject is the same
        // email ("New Message" → "Pricing for the team plan" was two moments and two notes for one send).
        if app.lowercased() == "mail", x == ["new","message"] || y == ["new","message"] { return true }
        let (short,long)=x.count <= y.count ? (x,y) : (y,x)
        guard short.count > 0 else { return true }
        if long.count == short.count+1, Array(long.prefix(short.count)) == short, long[short.count].allSatisfy(\.isNumber) { return false }
        for i in 0..<(short.count-1) where short[i] != long[i] { return false }
        let last=short[short.count-1],match=long[short.count-1]
        return last == match || (last.contains(where:\.isLetter) && match.hasPrefix(last))
    }
    /// Groups one day's visible actions (in day order) into moments: member indices per moment key, and names.
    /// Actions before `since` group exactly as test 4 did (gold/notes G22); from `since` on, continuation (sat5) with
    /// the anchor rules (G23) applies, and an action with no real title never renames the moment it joins.
    static func groupMoments(_ all:[CanonicalAction],times:[Date?],day:String,timezone:String,edits:[String:String],since:Date?,messagesRecipients:[String:String]=[:]) throws -> (groups:[String:[Int]],names:[String:String]) {
        var groups=[String:[Int]](), names=[String:String](), anchors=[String:String](), sites=[String:Set<String>]()
        // Sessions may survive short interruptions, but not a long gap. Explicit
        // grouping edits can bridge sites; automatic titles cannot join two sites.
        var sessions=[String:[String]]()
        var previous:(index:Int,key:String,explicit:Bool)?
        func onOrAfter(_ index:Int)->Bool { since.flatMap { s in times[index].map { $0 >= s } } ?? false }
        for (index,action) in all.enumerated() {
            let edited=edits[action.id]
            // B2: a recipient-free Messages draft must never inherit the chat
            // visible before New. Unknown stretches stay anonymous even when a
            // recipient appears later; only matching positive identities can
            // revisit a named session. This safety rule applies to old days too.
            if MessagesMomentIdentity.applies(action), edited?.isEmpty != false {
                let identity=MessagesMomentIdentity.name(action,recipient:messagesRecipients[action.id])
                let name=identity ?? "Messages", normalized=MessagesMomentIdentity.key(name)
                let session="messages:"+normalized
                var existing:String?
                if let identity {
                    existing=sessions[session,default:[]].reversed().first { key in
                        guard let last=groups[key]?.last, let at=times[index], let prior=times[last] else { return false }
                        let gap=at.timeIntervalSince(prior)
                        return gap >= 0 && gap <= 20*60 && MessagesMomentIdentity.name(all[last],recipient:messagesRecipients[all[last].id]).map(MessagesMomentIdentity.key) == MessagesMomentIdentity.key(identity)
                    }
                } else if let before=previous, !before.explicit, MessagesMomentIdentity.applies(all[before.index]),
                          MessagesMomentIdentity.name(all[before.index],recipient:messagesRecipients[all[before.index].id]) == nil,
                          let at=times[index], let prior=times[before.index], at.timeIntervalSince(prior) >= 0,
                          at.timeIntervalSince(prior) <= continuationGap {
                    existing=before.key
                }
                let key=try existing ?? fingerprint(json([day,timezone,normalized,action.id]))
                groups[key,default:[]].append(index); names[key]=name
                if identity != nil, existing == nil { sessions[session,default:[]].append(key) }
                previous=(index,key,false)
                continue
            }
            let name=subject(for:action,edited:edited)
            let normalized=name.lowercased().split(whereSeparator:{$0.isWhitespace}).joined(separator:" ")
            let explicit=edited?.isEmpty == false
            let bare=bareTitle(action)
            // sat5: the next action in the same desktop app (no site), within a few minutes, joins the moment before it
            // when the window title grew out of the moment's title: a note titled by its first line as you type, a chat
            // that gets its name (`continues`). The owner's timeline showed "Notes app", "Notes" and "Notes app" a
            // minute apart. A grouping edit on either side, a site, another app, another document or a longer gap keeps
            // them apart. Only from `since` on, so days recorded before this rule keep their moments and notes.
            if let before=previous, onOrAfter(before.index), !explicit, !before.explicit,
               continues(all[before.index],at:times[before.index],action,at:times[index],anchor:anchors[before.key]) {
                groups[before.key,default:[]].append(index)
                if !action.site.isEmpty { sites[before.key,default:[]].insert(action.site) }
                // The moment keeps a real title: a bare app name never replaces the window title it already has.
                if names[before.key] == nil || normalized != action.app.lowercased() { names[before.key]=name }
                if !bare { anchors[before.key]=windowTitle(action) }
                if !(sessions[normalized]?.contains(before.key) ?? false) { sessions[normalized,default:[]].append(before.key) }
                previous=(index,before.key,false)
                continue
            }
            let candidates=sessions[normalized,default:[]].reversed()
            let compatible=candidates.filter { key in
                guard let members=groups[key], let last=members.last, let at=times[index], let previous=times[last], at.timeIntervalSince(previous) <= 20*60 else { return false }
                let lastAction=all[last]
                let sites=sites[key] ?? []
                // Exact non-generic subject plus a shared site, or one desktop
                // app with no site, is conservative cross-app topic continuity.
                if explicit { return true }
                if !action.site.isEmpty && !sites.isEmpty { return sites == [action.site] }
                return action.site.isEmpty && lastAction.site.isEmpty ? action.app == lastAction.app || normalized.split(separator:" ").count >= 2 : normalized.split(separator:" ").count >= 2
            }
            let candidateSites=compatible.reduce(into:Set<String>()) { $0.formUnion(sites[$1] ?? []) }
            let existing=(!explicit && action.site.isEmpty && candidateSites.count > 1) ? nil : compatible.first
            let key=try existing ?? fingerprint(json([day,timezone,normalized,action.id]))
            if existing == nil { sessions[normalized,default:[]].append(key) }
            groups[key,default:[]].append(index)
            if !action.site.isEmpty { sites[key,default:[]].insert(action.site) }
            // G23: from `since` on, an action with no real title joining a moment by name (after continuation put the
            // moment under that name) keeps the moment's title.
            if !(existing != nil && bare && action.site.isEmpty && !explicit && onOrAfter(index) && names[key] != nil) { names[key]=name }
            if !bare { anchors[key]=windowTitle(action) }
            previous=(index,key,explicit)
        }
        return (groups,names)
    }
    /// Day assembly. The whole day is read in one query and kept per process (`DayAssemblyCache`) while nothing it
    /// depends on changed; new actions are added from the end (gold/notes G15/G18/G19). Every canonical action of
    /// the day is assembled up to `DayAssemblyCache.safetyCap`; only past that are notes explicitly incomplete,
    /// never fabricated totals, and then the newest actions are the ones kept (G24).
    public func dayLayers(day:String,timezone:String,after:String?=nil,limit:Int=100,now:Date=Date()) throws -> ActionDay {
        try assembleDay(day:day,timezone:timezone,after:after,limit:limit,now:now,notes:true).day
    }
    /// The local days ("yyyy-MM-dd" in `timezone`) that hold at least one record, oldest first: the main window's
    /// Previous/Next Day steps between these and never lands on an empty day (owner 10/2: Back from Today landed on a
    /// day with nothing, whose page was only the week line). Read from the records' UTC hours, never their contents;
    /// an hour that crosses local midnight (a zone with a part-hour offset) names both of its days.
    public func recordedDays(timezone:String) throws -> [String] {
        guard TimeZone(identifier:timezone) != nil else { throw MemError.invalid("IANA timezone required") }
        let hours=try rows("SELECT DISTINCT substr(json_extract(body,'$.at'),1,13) FROM records WHERE json_extract(body,'$.at') IS NOT NULL")
        var days=Set<String>()
        for row in hours {
            guard let hour=row.first, hour.count == 13, let start=timestamp(hour+":00:00Z") else { continue }
            for at in [start,start.addingTimeInterval(3599)] { if let key=try? DayScope.key(at,timezone:timezone) { days.insert(key) } }
        }
        return days.sorted()
    }
    /// A read only the notes paths use: the assembled day plus its visible actions by id, the same values `action(_:)`
    /// returns for them. `warmOnly` refuses (`DayAssemblyCold`) instead of reading the whole day again, so a caller
    /// inside a write transaction never holds the store for a full rebuild (G18).
    struct AssembledDay { let day:ActionDay; let actions:[String:CanonicalAction] }
    struct DayAssemblyCold:Error {}
    func assembleDay(day:String,timezone:String,after:String?=nil,limit:Int=100,now:Date=Date(),notes:Bool,warmOnly:Bool=false) throws -> AssembledDay {
        let interval=try DayScope.interval(day:day,timezone:timezone), revision=try actionReadEpoch()
        let policyBody=try rows("SELECT body FROM metadata WHERE id='policy'").first?.first ?? ""
        let settings=try decode(PrivacySettings.self,policyBody)
        let top=Int64(try rows("SELECT coalesce(max(rowid),0) FROM records").first!.first!) ?? 0
        let cacheKey=home.standardizedFileURL.path+"|"+day+"|"+timezone
        var entry=try DayAssemblyCache.shared.entry(cacheKey).flatMap { try refreshed($0,epoch:revision,policyBody:policyBody,settings:settings,top:top,now:now) }
        if entry == nil {
            if warmOnly { throw DayAssemblyCold() }
            entry=try readDay(interval:interval,epoch:revision,policyBody:policyBody,settings:settings,top:top,now:now)
        }
        var assembly=entry!
        // A cursor pins its own snapshot: assemble the day as it stood then.
        let outputPage:ActionPage
        var rowsInScope=assembly.rows[...]
        let snapshot=ActionSnapshot(epoch:revision,highWater:assembly.highWater)
        if let after, !assembly.truncated, let pinned=actionCursorHighWater(after), pinned <= assembly.highWater {
            if pinned < assembly.highWater { rowsInScope=assembly.rows.filter { $0.rowid <= pinned }[...] }
            let candidates=rowsInScope.map { (id:$0.id,at:$0.at,action:$0.action) }
            if let page=try actionPage(after:after,start:interval.start,end:interval.end,limit:limit,candidates:candidates) { outputPage=page }
            else { outputPage=try actions(start:interval.start,end:interval.end,after:after,limit:limit,now:now) }
            guard outputPage.snapshot.epoch == revision, outputPage.snapshot.highWater == pinned else { throw MemError.invalid("Day changed; retry fresh read") }
        } else if after != nil || assembly.truncated {
            outputPage=try actions(start:interval.start,end:interval.end,after:after,limit:limit,now:now,snapshot:after == nil ? snapshot : nil)
            guard outputPage.snapshot.epoch == revision, outputPage.snapshot.highWater <= assembly.highWater else { throw MemError.invalid("Day changed; retry fresh read") }
            if outputPage.snapshot.highWater < assembly.highWater { rowsInScope=assembly.rows.filter { $0.rowid <= outputPage.snapshot.highWater }[...] }
        } else {
            let first=assembly.rows.prefix(max(1,min(200,limit))+1).map { (id:$0.id,at:$0.at,action:$0.action) }
            outputPage=try firstActionPage(start:interval.start,end:interval.end,limit:limit,snapshot:snapshot,candidates:first[...])
        }
        let visible=Self.droppingTitleTicks(rowsInScope.filter { $0.action != nil },edits:assembly.edits)
        let all=visible.map { $0.action! }, times=visible.map(\.time)
        let partial=assembly.truncated
        let binding=settings.notesBinding
        let messagesRecipients=Dictionary(uniqueKeysWithValues:visible.compactMap { row in row.messagesRecipient.map { (row.id,$0) } })
        let (groups,names)=try Self.groupMoments(all,times:times,day:day,timezone:timezone,edits:assembly.edits,since:settings.continuationSince.map { Date(timeIntervalSince1970:$0) },messagesRecipients:messagesRecipients)
        // Corrections: each one's actions must all still be readable (as `correctionList`).
        var readable=[String:Bool]()
        for row in assembly.rows { readable[row.id]=row.action != nil }
        func permitted(_ correction:UserCorrection) throws -> Bool {
            for id in correction.actionIDs {
                if let known=readable[id] { guard known else { return false }; continue }
                let value=try permittedOriginal(id,now:now) != nil
                readable[id]=value
                guard value else { return false }
            }
            return true
        }
        var byAction=[String:[Int]]()
        for (i,correction) in assembly.noteCorrections.enumerated() { for id in Set(correction.actionIDs) { byAction[id,default:[]].append(i) } }
        func corrections(_ ids:[String]) throws -> [UserCorrection] {
            guard !ids.isEmpty else { return [] }
            var picked=Set<Int>()
            for id in ids { for i in byAction[id] ?? [] { picked.insert(i) } }
            return try picked.sorted().map { assembly.noteCorrections[$0] }.filter(permitted)
        }
        let layers=try hasActionLayers()
        let keepOld=try notesKeptAsWritten()
        let positions=Dictionary(uniqueKeysWithValues:all.enumerated().map { ($0.element.id,$0.offset) })
        var activities=[ActivityNote](), memo=assembly.inputs, starts=[String:Date?]()
        for key in groups.keys.sorted() {
            let indices=groups[key]!, members=indices.map { all[$0] }, id="activity_"+key
            let memberCorrections=try corrections(members.map(\.id))
            let name=names[key] ?? "", correctionsJSON=try json(memberCorrections), memberIDs=members.map(\.id)
            let input:String
            if let known=memo[key], known.memberIDs == memberIDs, known.name == name, known.binding == binding, known.corrections == correctionsJSON { input=known.revision }
            else {
                input=try Self.activityInputRevision(members,binding:binding,name:name,corrections:memberCorrections)
                memo[key]=DayGroupInput(memberIDs:memberIDs,name:name,binding:binding,corrections:correctionsJSON,revision:input)
            }
            var clusters=[ObservationCluster](), previous:Int?
            for index in indices {
                let action=all[index]
                let unchanged=previous.map { all[$0] }.map { p in ActionProjection.coalescible(p) && ActionProjection.coalescible(action) && p.observationKey == action.observationKey && (times[previous!] ?? .distantFuture) < (times[index] ?? .distantPast) } ?? false
                // Only globally consecutive samples coalesce. A revisit after a
                // different action stays visible, even within the same activity.
                let consecutive=previous.flatMap { positions[all[$0].id] }.map { $0+1 == positions[action.id] } ?? false
                if unchanged && consecutive { clusters[clusters.count-1].actionIDs.append(action.id); clusters[clusters.count-1].lastObservedAt=action.at }
                else { clusters.append(ObservationCluster(actionIDs:[action.id],firstObservedAt:action.at,lastObservedAt:action.at)) }
                previous=index
            }
            var generated=partial || !notes || !layers ? nil : try storedNote(id:id,inputRevision:input,checked:true)
            // fix/sx-all round 2: a note an earlier writer wrote is pending again on a recent day, and shown meanwhile.
            var outdated:GeneratedNote?=nil
            if !keepOld, let g=generated, NoteWriterVersions.rewrites(g,dayEnd:interval.end,now:now) { outdated=g; generated=nil }
            // fix/day-card: stale-while-updating (display only; status and generated stay as they are).
            let previousNote=try outdated ?? (generated != nil || partial || !notes || !layers ? nil : try latestNote(id:id,within:Set(memberIDs)))
            // Display metadata only. Kept out of input so notes stored before it existed stay ready.
            let bundleCounts=Dictionary(members.map(\.bundle).filter{!$0.isEmpty}.map{($0,1)},uniquingKeysWith:+)
            let bundles=bundleCounts.keys.sorted { (-bundleCounts[$0]!,$0) < (-bundleCounts[$1]!,$1) }
            starts[id]=times[indices[0]]
            activities.append(ActivityNote(id:id,day:day,timezone:timezone,subject:name,actionIDs:memberIDs,apps:Array(Set(members.map(\.app))).sorted(),sites:Array(Set(members.map(\.site).filter{!$0.isEmpty})).sorted(),start:members.first!.at,end:members.last!.at,clusters:clusters,inputRevision:input,status:partial ? "incomplete" : generated == nil ? "pending" : "ready",generated:generated,corrections:memberCorrections,bundles:bundles,bundleActionCounts:bundleCounts,webTypedCount:{ let n=members.filter(NoteAudience.webTyped).count; return n > 0 ? n : nil }(),previous:previousNote))
        }
        activities.sort { ((starts[$0.id] ?? nil) ?? .distantPast,$0.id) < ((starts[$1.id] ?? nil) ?? .distantPast,$1.id) }
        let dayID="day_"+fingerprint(day+"|"+timezone)
        let dayRevision=fingerprint(try json(activities.map { [$0.id,$0.inputRevision] })+binding)
        var generated=partial || !notes || !layers ? nil : try storedNote(id:dayID,inputRevision:dayRevision,checked:true)
        var dayOutdated:GeneratedNote?=nil
        if !keepOld, let g=generated, NoteWriterVersions.rewrites(g,dayEnd:interval.end,now:now) { dayOutdated=g; generated=nil }
        let dayPrevious=try dayOutdated ?? (generated != nil || partial || !notes || !layers ? nil : try latestNote(id:dayID,within:Set(all.map(\.id))))
        let summary=DaySummary(day:day,timezone:timezone,start:iso(interval.start),end:iso(interval.end),activityIDs:activities.map(\.id),actionCount:all.count,countIsComplete:!partial,inputRevision:dayRevision,status:partial ? "incomplete" : generated == nil ? "pending" : "ready",generated:generated,corrections:try corrections(all.map(\.id)),previous:dayPrevious)
        guard try revision == actionReadEpoch() else { throw MemError.invalid("Day changed; retry fresh read") }
        if rowsInScope.count == assembly.rows.count { assembly.inputs=memo.filter { groups[$0.key] != nil } }
        DayAssemblyCache.shared.store(cacheKey,assembly)
        var byID=[String:CanonicalAction](minimumCapacity:all.count)
        for action in all { byID[action.id]=action }
        return AssembledDay(day:ActionDay(summary:summary,activities:activities,actions:outputPage,defaultLayer:interval.end <= now ? "day_summary" : "activity_notes",partial:partial),actions:byID)
    }
    /// The cached day brought up to date, or nil when it must be read again: another epoch or policy, a clock that
    /// went back, a row that became visible or expired with time, or rows changed behind the epoch.
    private func refreshed(_ cached:DayAssembly,epoch:String,policyBody:String,settings:PrivacySettings,top:Int64,now:Date) throws -> DayAssembly? {
        guard cached.epoch == epoch, cached.policyBody == policyBody, now >= cached.assembledAt, top >= cached.highWater,
              cached.minFuture.map({ $0 > now.addingTimeInterval(30) }) ?? true,
              cached.minVisible.map({ settings.retention.permits($0,now:now) }) ?? true else { return nil }
        // The day's rows up to `top` as they are now, read before the rest: a change after it shows at the next refresh.
        let current=top > cached.highWater ? try daySignature(start:cached.start,end:cached.end,top:top) : nil
        // Rows at or below the high-water mark are as read (only a raw write outside the store could change them).
        guard try daySignature(start:cached.start,end:cached.end,top:cached.highWater) == cached.signature else { return nil }
        var entry=cached
        guard let current else { return entry }
        let last=cached.rows.last, jd=Self.dayTime
        let tail=try dayRecords(start:cached.start,end:cached.end,top:top,above:cached.highWater,limit:Int.max,
                                also:"(\(jd)>julianday(?) OR (\(jd)=julianday(?) AND id>?))",
                                alsoValues:[last?.at ?? "0001-01-01T00:00:00Z",last?.at ?? "0001-01-01T00:00:00Z",last?.id ?? ""])
        // Only rows that sort after the cached day are appended; anything else (an import with old times) reads again.
        guard tail.allSatisfy({ $0[5] == "1" }) else { return nil }
        var ids=Set(cached.rows.map(\.id))
        for row in tail { guard ids.insert(row[1]).inserted else { return nil } }
        for row in tail { entry.append(try dayRow(row,settings:settings,edits:cached.edits,corrections:cached.actionCorrections,now:now),now:now) }
        // Past the cap the newest are kept, as a fresh read would (G24).
        if entry.rows.count > DayAssemblyCache.safetyCap { entry.keepNewest(DayAssemblyCache.safetyCap) }
        entry.highWater=top; entry.assembledAt=max(entry.assembledAt,now)
        entry.signature=current
        return entry
    }
    /// A record's time as the time index (`records_at_julian`) holds it.
    static let dayTime="julianday(json_extract(body,'$.at'))"
    /// A rowid fence (`op` one bound) that only filters: `+` keeps the planner from taking the rowid range as the
    /// statement's scan, so the time index bounds it. The bound is cast because every value is bound as text and
    /// `+rowid` has no affinity to convert it: `+rowid<=?` would compare an integer with text (always less) and let
    /// every row through, and `+rowid>?` none.
    static func rowidFence(_ op:String) -> String { "+rowid\(op)CAST(? AS INTEGER)" }
    /// Rows one statement of a day read returns at most (gold r2-store-perf). Each statement holds the store's lock and
    /// SQLite's lock on the file for its own rows only, found through the time index, so the recorder's writes (the
    /// heartbeat, every save) and the rest of the app go on between statements. Before, one statement read the whole
    /// day, and the day's signature read every record of the history: on a cold six-month history an AI app's first
    /// Today read held the file 1.6 s and failed the recorder's saves with busy, and on the recorder's own connection
    /// the heartbeat waited over 6 s.
    static let dayReadChunk=500
    /// What `refreshed` compares to tell a cached day is still as read: the count and rowid total of the day's records
    /// up to `top`, read through the time index (the day's own entries only; the day depends on no other record).
    /// Without the time index (a history DayDream hasn't indexed yet) any day read scans the whole table anyway, so it
    /// counts every record up to `top`, as before, which reads no JSON. The first value names the form, so the two
    /// never compare equal.
    func daySignature(start:Date,end:Date,top:Int64) throws -> [String] {
        guard try timeIndexed() else { return ["all"]+(try rows("SELECT count(*),total(rowid) FROM records WHERE rowid<=?",[String(top)]).first ?? []) }
        let jd=Self.dayTime
        return ["day"]+(try rows("SELECT count(*),total(rowid) FROM records WHERE \(Self.rowidFence("<=")) AND \(jd)>=julianday(?) AND \(jd)<julianday(?)",
                                 [String(top),Self.actionBound(start),Self.actionBound(end)]).first ?? [])
    }
    /// The day's records as `readDay` and `refreshed` use them (rowid, id, time, body, tombstoned, then `also` when
    /// given), rowid up to `top` (and past `above`), in `actions(start:end:)` order or its reverse, at most `limit`.
    /// `dayReadChunk` rows per statement, each bounded on both sides by the time index; the locks are free between
    /// statements. Without the time index, one statement, as before (each statement would scan the whole table).
    func dayRecords(start:Date,end:Date,top:Int64,above:Int64?=nil,descending:Bool=false,limit:Int,also:String?=nil,alsoValues:[String]=[]) throws -> [[String]] {
        let jd=Self.dayTime, lower=Self.actionBound(start), upper=Self.actionBound(end)
        let select="SELECT rowid,id,json_extract(body,'$.at'),body,EXISTS(SELECT 1 FROM tombstones t WHERE t.id=records.id)"+(also.map { ","+$0 } ?? "")+" FROM records WHERE "
        let order=descending ? " ORDER BY \(jd) DESC,id DESC LIMIT ?" : " ORDER BY \(jd),id LIMIT ?"
        let fence=(above == nil ? "" : Self.rowidFence(">")+" AND ")+Self.rowidFence("<="), fenceValues=(above.map { [String($0)] } ?? [])+[String(top)]
        guard try timeIndexed() else {
            return try rows(select+fence+" AND \(jd)>=julianday(?) AND \(jd)<julianday(?)"+order,alsoValues+fenceValues+[lower,upper,String(min(limit,Int(Int32.max)))])
        }
        var found=[[String]](), position:(at:String,id:String)?
        while found.count < limit {
            let want=min(Self.dayReadChunk,limit-found.count)
            var sql=select+fence, values=alsoValues+fenceValues
            switch (position,descending) {
            case (nil,_): sql += " AND \(jd)>=julianday(?) AND \(jd)<julianday(?)"; values += [lower,upper]
            // After the last row read (a later time, or the same time and a larger id): the index bounds both sides.
            case let (p?,false): sql += " AND \(jd)>=julianday(?) AND \(jd)<julianday(?) AND (\(jd)>julianday(?) OR id>?)"; values += [p.at,upper,p.at,p.id]
            case let (p?,true): sql += " AND \(jd)>=julianday(?) AND \(jd)<=julianday(?) AND (\(jd)<julianday(?) OR id<?)"; values += [lower,p.at,p.at,p.id]
            }
            let chunk=try rows(sql+order,values+[String(want)])
            found += chunk
            guard chunk.count == want, let last=chunk.last else { break }
            position=(last[2],last[1])
            // On the recorder's own connection the heartbeat waits for the store's lock, which doesn't queue its waiters.
            letWaitersInBetweenReads()
        }
        return found
    }
    /// The history has the time index `dayRecords` reads through (`records_at_julian`, as DayDream makes it). Remembered
    /// once seen (DayDream never drops it; a repaired or restored history is a new file, opened as a new store); until
    /// then read again each time, so an index another connection builds meanwhile is used from then on.
    func timeIndexed() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if timeIndexSeen { return true }
        guard let sql=try rows("SELECT sql FROM sqlite_master WHERE type='index' AND name='records_at_julian' AND tbl_name='records'").first?.first,
              Self.ownIndex(name:"records_at_julian",sql:sql) else { return false }
        timeIndexSeen=true
        return true
    }
    /// Reads one day: every record in the range up to `top`, in `actions(start:end:)` order (`dayRecords`).
    private func readDay(interval:DateInterval,epoch:String,policyBody:String,settings:PrivacySettings,top:Int64,now:Date) throws -> DayAssembly {
        let cap=DayAssemblyCache.safetyCap
        // Read first: a change after it (a raw write outside the store) shows at the next refresh.
        let signature=try daySignature(start:interval.start,end:interval.end,top:top)
        var found=try dayRecords(start:interval.start,end:interval.end,top:top,limit:cap+1)
        let truncated=found.count > cap
        // Past the cap the newest actions are kept: those are the moments the person was just in.
        if truncated { found=Array(try dayRecords(start:interval.start,end:interval.end,top:top,descending:true,limit:cap).reversed()) }
        var edits=[String:String]()
        if try hasActionLayers() { for row in try rows("SELECT action_id,subject FROM action_group_edits ORDER BY sequence") { edits[row[0]]=row[1] } }
        var actionCorrections=[String:UserCorrection](), noteCorrections=[UserCorrection]()
        if try hasMemoryControls() {
            var latest=[String:String]()
            for row in try rows("SELECT target,body FROM user_corrections WHERE kind='action' ORDER BY target,version") { latest[row[0]]=row[1] }
            for (target,body) in latest { let value=try decode(UserCorrection.self,body); if value.text != nil { actionCorrections[target]=value } }
            noteCorrections=try rows("SELECT c.body FROM user_corrections c WHERE c.kind<>'action' AND c.version=(SELECT max(n.version) FROM user_corrections n WHERE n.kind=c.kind AND n.target=c.target) ORDER BY c.kind,c.target").map { try decode(UserCorrection.self,$0[0]) }.filter { $0.text != nil }
        }
        var entry=DayAssembly(epoch:epoch,policyBody:policyBody,start:interval.start,end:interval.end,highWater:top,assembledAt:now,rows:[],truncated:truncated,edits:edits,actionCorrections:actionCorrections,noteCorrections:noteCorrections)
        entry.rows.reserveCapacity(found.count)
        for row in found { entry.append(try dayRow(row,settings:settings,edits:edits,corrections:actionCorrections,now:now),now:now) }
        entry.signature=signature
        return entry
    }
    /// One record as `action(_:now:)` presents it (nil when tombstoned or hidden by the policy), read once.
    private func dayRow(_ row:[String],settings:PrivacySettings,edits:[String:String],corrections:[String:UserCorrection],now:Date) throws -> DayRow {
        let time=timestamp(row[2])
        var action:CanonicalAction?
        var messagesRecipient:String?
        var statusGlyph=false
        if row[4] != "1" {
            let raw=try decode(Evidence.self,row[3])
            if let clean=Privacy.sanitized(raw,settings:settings,now:now) {
                action=try Self.applying(corrections[row[1]],to:ActionProjection.make(clean))
                messagesRecipient=MessagesMomentIdentity.recipient(clean.captureProvenance?.unit)
                statusGlyph=TitleClean.statusless(raw.title) != raw.title
            }
        }
        return DayRow(rowid:Int64(row[0]) ?? 0,id:row[1],at:row[2],time:time,action:action,messagesRecipient:messagesRecipient,statusGlyph:statusGlyph)
    }
    /// claude/title-spinner-1003 (audit B1): the kinds a window title change is saved as (Chrome page rows included).
    static let titleKinds:Set<String>=["window.changed","window.observed","focus.observed"]
    /// claude/title-spinner-1003 (audit B1): the day's rows without the title ticks an earlier build saved. Claude Code's
    /// spinner ("✳ / ◐ / ◑ <session>") saved a row about every 1.5 s (7,301 of 8,163 rows one night): one session became
    /// two moments that never went quiet, and past 2,000 rows could never be summarized. A title row whose title, without
    /// the glyph, is the one the previous title row of the day already showed (same app, same site), where either of the
    /// two carried a glyph, is what capture now never writes (`EventCapture.emitWindowChangeIfNeeded`), so a day reads
    /// as if it had been recorded that way: one moment per session, closed when it goes quiet, counted by what was done.
    /// The rows stay in the store (`actions`, `read`); a row with a grouping edit or a correction always stays. Rows
    /// without a glyph are never dropped, so no other moment, note or revision moves.
    static func droppingTitleTicks(_ rows:[DayRow],edits:[String:String]) -> [DayRow] {
        var last:(key:String,glyph:Bool)?
        return rows.filter { row in
            guard let action=row.action, titleKinds.contains(action.kind) else { return true }
            let key=[action.bundle.isEmpty ? action.app : action.bundle,action.title,action.site].joined(separator:"\u{1F}")
            let repeated=last.map { $0.key == key && ($0.glyph || row.statusGlyph) } ?? false
            last=(key,row.statusGlyph)
            return !repeated || edits[row.id] != nil || action.correction != nil
        }
    }
}
/// `statusGlyph`: the stored title had a status glyph at an end (claude/title-spinner-1003; `droppingTitleTicks`).
struct DayRow { let rowid:Int64; let id:String; let at:String; let time:Date?; let action:CanonicalAction?; var messagesRecipient:String? = nil; var statusGlyph:Bool = false }
struct DayGroupInput { let memberIDs:[String]; let name:String; let binding:String; let corrections:String; let revision:String }
/// One assembled day as read: valid while the epoch, the policy and the rows up to `highWater` are unchanged and the
/// clock has not crossed a visibility edge (a future-dated row coming due, a retention cutoff passing a row).
struct DayAssembly {
    let epoch:String, policyBody:String, start:Date, end:Date
    var highWater:Int64, assembledAt:Date
    var rows:[DayRow]
    var truncated:Bool
    let edits:[String:String]
    let actionCorrections:[String:UserCorrection]
    let noteCorrections:[UserCorrection]
    var signature:[String]=[]
    var minFuture:Date?=nil
    var minVisible:Date?=nil
    var inputs:[String:DayGroupInput]=[:]
    init(epoch:String,policyBody:String,start:Date,end:Date,highWater:Int64,assembledAt:Date,rows:[DayRow],truncated:Bool,edits:[String:String],actionCorrections:[String:UserCorrection],noteCorrections:[UserCorrection]) {
        self.epoch=epoch;self.policyBody=policyBody;self.start=start;self.end=end;self.highWater=highWater;self.assembledAt=assembledAt
        self.rows=rows;self.truncated=truncated;self.edits=edits;self.actionCorrections=actionCorrections;self.noteCorrections=noteCorrections
    }
    mutating func keepNewest(_ count:Int) {
        rows.removeFirst(rows.count-count); truncated=true
        minVisible=rows.compactMap { $0.action == nil ? nil : $0.time }.min()
    }
    mutating func append(_ row:DayRow,now:Date) {
        rows.append(row)
        guard let time=row.time else { return }
        if row.action != nil { minVisible=min(minVisible ?? time,time) }
        else if time > now.addingTimeInterval(30) { minFuture=min(minFuture ?? time,time) }
    }
}
/// Assembled days by store and day, for this process (Today, the writer, MCP and checks share it). A few days only.
final class DayAssemblyCache: @unchecked Sendable {
    static let shared=DayAssemblyCache()
    /// Past this many actions in one day, notes for it are marked incomplete (G24); the newest are kept.
    static let safetyCap=25_000
    private let lock=NSLock()
    private var entries=[String:DayAssembly](), order=[String]()
    /// claude/perf2-1003: the writer's catch-up reads the past 7 days in a row on every look, beside today, Today's own
    /// read and day navigation's focused day and its two prefetched neighbours. With 6 kept, those 7 days pushed each
    /// other out in turn and every look assembled all 7 again from SQLite (~0.75 s each a day of 3,000 actions, debug).
    static let capacity=12
    func entry(_ key:String) -> DayAssembly? { lock.lock(); defer { lock.unlock() }; return entries[key] }
    func store(_ key:String,_ value:DayAssembly) {
        lock.lock(); defer { lock.unlock() }
        entries[key]=value; order.removeAll { $0 == key }; order.append(key)
        while order.count > Self.capacity { entries.removeValue(forKey:order.removeFirst()) }
    }
    func removeAll() { lock.lock(); defer { lock.unlock() }; entries=[:]; order=[] }
}
