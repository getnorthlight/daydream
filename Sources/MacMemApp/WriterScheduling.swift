import Foundation
import MemoryCore
import WriterBackend
import CoreIntegration

/// Reads canonical targets only. No capture, summarization or model work runs
/// inside an ingest callback or while holding a core transaction open.
///
/// Closed moments follow bounded growth rewrite rules, and
/// there is no whole-day note (headlines come from the level notes and the live threads). A moment is closed when
/// - its last action is at least 10 minutes old, or
/// - a later moment exists and its last action is at least 2 minutes old, or
/// - the Mac locked, slept or went idle for 5 minutes after it (`closedBy`).
/// Local open moments receive a provisional note every ten minutes, including
/// those whose previous note is current; closure schedules their final note.
/// Cloud open moments retain the on-demand behavior.
/// fix/resummarize (owner, test 7): a written moment that got a few more minutes of use (`rewriteMinutes`, at least
/// `rewriteMinActions` more actions) is rewritten too, not only one that grew by a quarter; Summarize Now rewrites any
/// moment at once, written or not, open or closed (`isCurrent(_:written:)`).
actor WriterQueueSource {
    private let store:MemoryStore
    /// `.cloud` while the cloud writer runs: work the cloud may not read is never a target.
    private(set) var audience:NoteAudience = .local
    /// While cloud runs: when it was first turned on. Nothing at or before it is ever sent (`CloudActivation.permits`),
    /// so work that holds such an action is never queued (gold/notes G25).
    private(set) var cutoff:Date?
    static let closeAfter:TimeInterval=10*60
    static let closeAfterLater:TimeInterval=2*60
    static let liveEvery:TimeInterval=10*60
    /// Summary eligibility may precede canonical closure; it never splits or closes a moment.
    static let summaryServiceDeadline:TimeInterval=5*60
    /// Leave bounded generation room inside the service deadline; real holds/load time remain conditional.
    static let summaryGenerationReserve:TimeInterval=2*60
    static let summaryStartAfter:TimeInterval=summaryServiceDeadline-summaryGenerationReserve
    /// Rewrite rule: a written moment is written again only once it is closed again, grew (by a quarter, by a typed or
    /// sent row, or by `rewriteMinutes` more of use with at least `rewriteMinActions` more actions), and its last note is
    /// at least `rewriteAfter` old. fix/resummarize: a quarter alone never came for a long chat (a 200-action Claude
    /// moment needed 50 more actions), so a few more minutes of use is enough; `rewriteAfter` still bounds the model
    /// runs per moment (at most one rewrite every 15 minutes, and none without new actions or another revision).
    static let rewriteGrowth=0.25
    static let rewriteMinutes:TimeInterval=3*60
    static let rewriteMinActions=3
    static let rewriteAfter:TimeInterval=15*60
    /// fix/writing-forever (owner lane): ordinary growth is written at most this many times in the background and for AI
    /// apps (its first note, the note once it closes, a rewrite as it grows). An AI app's early note of a moment still going
    /// plus the note once it closed plus two growth rewrites wrote a long chat 4 times. New typed or submitted evidence
    /// still rewrites after the close/cooldown rules; a lifetime cap must not leave a note missing new clauses.
    /// Summarize Now always writes, and
    /// a moment changed without growing (Forget, a rejoin, other privacy settings) is written again whatever the count.
    static let maxWrites=3
    /// Routing metadata only; changes when the writer versions change.
    static var writerRevision:String {CanonicalGrounding.currentVersions.joined(separator:"|")}
    /// Notes written for a moment so far (a mark from before the count: 1 if it was a note, 0 if set aside).
    static func writes(_ mark:WrittenMark?) -> Int {
        guard let mark else {return 0}
        return mark.writes ?? (mark.skipped ? 0 : 1)
    }
    /// Catch-up of past days reaches back at most this many days (newest first).
    static let catchUpDays=7
    init(store:MemoryStore) {self.store=store}
    func setAudience(_ value:NoteAudience,cutoff:Date?=nil) {audience=value;self.cutoff=value == .cloud ? cutoff : nil}
    func policyRevision() throws -> String {try store.policy().revision}
    /// Summarize Now's moment as it is now, and whether it is still open (then its note is provisional: it is written
    /// again, normally, once it closes). fix/resummarize: never refused for being written already; refused only when the
    /// running writer could never write it (too long, or before the cloud cutoff).
    func selected(day:String,timezone:String,activityID:String,now:Date=Date(),closedBy:Date?=nil) throws -> (item:ScheduledWriterTarget,open:Bool) {
        let layers=try store.dayLayers(day:day,timezone:timezone,now:now)
        guard !layers.partial,let activity=layers.activities.first(where:{$0.id==activityID}),
              let end=timestamp(activity.end) else {throw MemError.invalid("Activity unavailable or incomplete")}
        guard audience.admits(activity),try writable(layers,day:day,timezone:timezone,now:now).contains(activityID) else {throw MemError.invalid("This writer can't summarize this moment")}
        let item=ScheduledWriterTarget(target:WriterTarget(kind:.activity,day:day,timezone:timezone,activityID:activityID),inputRevision:activity.inputRevision,policyRevision:try store.policy().revision,lastActivity:end)
        let later=layers.activities.contains {(timestamp($0.end) ?? .distantPast)>end}
        return (item,!Self.closed(end:end,later:later,day:day,now:now,timezone:timezone,closedBy:closedBy))
    }
    /// The close rule (see the type's comment).
    static func closed(end:Date,later:Bool,day:String,now:Date,timezone:String,closedBy:Date?) -> Bool {
        let today=(try? DayScope.key(now,timezone:timezone)) ?? day
        return day != today || now>=closesAt(end:end,later:later) || (closedBy.map {$0>=end} ?? false)
    }
    static func closesAt(end:Date,later:Bool) -> Date {end.addingTimeInterval(later ? closeAfterLater : closeAfter)}
    /// Which of a day's moments the running writer could ever write (gold/notes G25/G73). Anything else would stay
    /// pending for good and fill the queue, so it is never queued, and an entry already queued counts as obsolete:
    /// - more actions than the writer reads even in segments (2,000; Today calls such a moment too long). claude/ready-1002
    ///   (owner): a moment over one request's 400 is written in segments of about 150 and merged (`CanonicalGrounding.chunks`);
    /// - under the cloud, none it may read, or any of them at or before the moment cloud was first turned on.
    /// fix/sx-engine-battery: no 100-action cloud cap (the ModelView fold and the 24 KB request limit bound the cost).
    private func writable(_ layers:ActionDay,day:String,timezone:String,now:Date) throws -> Set<String> {
        let limit=CanonicalGrounding.maxChunkedActions
        guard audience == .cloud else {return Set(layers.activities.filter{$0.actionIDs.count<=limit}.map(\.id))}
        let scopes=try store.cloudNoteScopes(day:day,timezone:timezone,now:now)
        func fits(_ activity:ActivityNote) -> Bool {
            guard activity.actionIDs.count<=limit,let scope=scopes.activities[activity.id],scope.actionCount>0 else {return false}
            guard let cutoff else {return true}
            return (scope.earliest ?? .distantPast) > cutoff
        }
        return Set(layers.activities.filter(fits).map(\.id))
    }
    struct Discovery {
        /// Closed moments due a note: never written, written while open, or grown enough since (the rewrite rule).
        var targets:[ScheduledWriterTarget]=[]
        /// Moments still open, including current local notes.
        var open:[ScheduledWriterTarget]=[]
        /// Local open moments due their ten-minute provisional refresh.
        var live:[ScheduledWriterTarget]=[]
        var nextLive:Date?
        /// Local missing-current-note moments due early enough to reserve work inside the five-minute service deadline.
        /// Open members receive a provisional note; closed members retain ordinary/final status.
        var summaryDue:[ScheduledWriterTarget]=[]
        var nextSummary:Date?
        /// Writable, nonempty local open moments may retain one warm model lease; this does not load the model.
        var keepLocalWarm=false
        /// Provisional notes become final once closed, even at the same revision.
        var final:Set<String>=[]
        var nextFinal:Date?
        /// Idle-only or empty moments: nothing to write. The caller marks them done (`WrittenMark.skipped`).
        var skipped:[(target:ScheduledWriterTarget,mark:WrittenMark)]=[]
        /// When the next open moment closes by itself if nothing joins it (nil: none open).
        var nextClose:Date?
        /// Closed moments that wait only for the rewrite rule's 15 minutes: when the first of them is due.
        var nextRewrite:Date?
        /// fix/sx-all round 3: pending moments the rewrite rule won't write again (written or set aside at this same
        /// revision, grown too little since). Levels never wait for them (`momentWillBeWritten`): a block uses the note
        /// shown for it meanwhile (its previous note), so a block, day or week note is never held for a day.
        var willNotWrite:Set<String>=[]
        /// claude/ready-1002 (owner): the targets that only rewrite an earlier writer's note (a version bump), newest
        /// moment first at the end of `targets`. They run at background priority and only while the person isn't typing.
        var rewriteKeys:Set<String>=[]
        /// A moment still open, or one written moment still growing: the day isn't settled.
        var settling:Bool {!open.isEmpty}
    }
    /// One day's moments, sorted into targets, open moments and skipped ones.
    /// `closedBy`: the Mac locked, slept or has been idle 5 minutes since this time, which closes every moment that
    /// ended before it. `marks`: the scheduler's written marks (rewrite rule). `since`: only moments that ended after it.
    func discoverDay(_ day:String,now:Date,timezone:String,closedBy:Date?=nil,marks:[String:WrittenMark]=[:],since:Date?=nil) throws -> Discovery {
        let policy=try store.policy()
        let layers=try store.dayLayers(day:day,timezone:timezone,now:now)
        var found=Discovery()
        guard !layers.partial else {return found}
        let fit=try writable(layers,day:day,timezone:timezone,now:now)
        let today=try DayScope.key(now,timezone:timezone)
        let ends=layers.activities.compactMap {timestamp($0.end)}
        var rewrites:[ScheduledWriterTarget]=[]
        for activity in layers.activities where audience.admits(activity) {
            guard let end=timestamp(activity.end) else {continue}
            if let since,end<since {continue}
            guard fit.contains(activity.id) else {continue}
            let item=ScheduledWriterTarget(target:WriterTarget(kind:.activity,day:day,timezone:timezone,activityID:activity.id),inputRevision:activity.inputRevision,policyRevision:policy.revision,lastActivity:end)
            let mark=marks[item.key]
            // Closed?
            let later=ends.contains {$0>end}
            let closesAt=Self.closesAt(end:end,later:later)
            let closed=day != today || now>=closesAt || (closedBy.map {$0>=end} ?? false)
            guard closed else {
                if audience == .local {
                    found.open.append(item)
                    if mark?.provisional == true {found.nextFinal=min(found.nextFinal ?? closesAt,closesAt)}
                    if !(try nothingToWrite(activity,now:now)) {
                        let mature=(timestamp(activity.start) ?? end).addingTimeInterval(Self.liveEvery)
                        let due=max(mature,mark?.at.addingTimeInterval(Self.liveEvery) ?? mature)
                        found.keepLocalWarm=true
                        if activity.status != "ready" {
                            let summaryAt=end.addingTimeInterval(Self.summaryStartAfter)
                            if now>=summaryAt {found.summaryDue.append(item)}
                            else {found.nextSummary=min(found.nextSummary ?? summaryAt,summaryAt)}
                        }
                        if now>=due {found.live.append(item)}
                        else {found.nextLive=min(found.nextLive ?? due,due)}
                    }
                } else if activity.status != "ready" {found.open.append(item)}
                found.nextClose=min(found.nextClose ?? closesAt,closesAt)
                continue
            }
            let final=audience == .local && mark?.provisional == true
            guard activity.status != "ready" || final else {continue}
            if final {found.final.insert(item.key)}
            // fix/sx-all round 2: a note an earlier writer wrote for these same actions (core reads it as pending, the old
            // note still shown) is written again once by this build, after new moments.
            // Only an explicit current writer stamp proves this build tried it;
            // old-build marks are normally written after their notes too.
            let rewrite=activity.previous.map {$0.inputRevision==activity.inputRevision && NoteWriterVersions.outdated($0.output.generatorVersion)} ?? false
            if rewrite, mark?.writerRevision != Self.writerRevision {
                rewrites.append(item);continue
            }
            if let mark,!mark.provisional {
                // Written (or set aside) before: only when it grew enough, and not more often than every 15 minutes.
                let added=activity.actionIDs.count-mark.actions
                let grew=added>0 && Double(activity.actionIDs.count)>=Double(mark.actions)*(1+Self.rewriteGrowth)
                // fix/resummarize: a few more minutes of use since the note (its moment's last action then, or the write
                // itself for a mark from before this rule).
                let longer=added>=Self.rewriteMinActions && end>=(mark.end ?? mark.at).addingTimeInterval(Self.rewriteMinutes)
                let typed = added>0 ? try newTypedOrSent(activity,after:mark.actions,now:now) : false
                // fix/sx-all round 3: pending again at another revision without growing (a moment rejoined, Forget, typing
                // turned off, Summarize Now on an open moment, cloud turned on mid-day): due once, 15 minutes after the
                // mark. Before, it stayed pending for good and held its block, the day and the week for 24 hours.
                // build/launch: growth alone is not "changed" (the input revision moves with every new action, which let one
                // more click rewrite a written moment and skipped the rules above). Changed is another policy or audience,
                // or a moment whose actions changed without growing (rejoined, Forget).
                // fix/summary-fallback (QF-16): a moment an earlier build set aside when every answer failed is due once more
                // (it now ends in at least code's fallback note); marks this build sets say `fallback`.
                // claude/ready-1002 (owner): a long moment an earlier build set aside as too long is written once more,
                // now in segments.
                let long=mark.skipped && mark.writerRevision != Self.writerRevision && activity.actionIDs.count>CanonicalGrounding.maxActions
                let changed=Self.revisionChanged(mark.revision,markRevision(item),grew:added>0) || mark.recoverable || long
                guard changed || typed || ((grew || longer) && Self.writes(mark)<Self.maxWrites) else {found.willNotWrite.insert(activity.id);continue}
                let due=mark.at.addingTimeInterval(Self.rewriteAfter)
                guard now>=due else {found.nextRewrite=min(found.nextRewrite ?? due,due);continue}
            }
            if try nothingToWrite(activity,now:now) {
                found.skipped.append((item,WrittenMark(actions:activity.actionIDs.count,typed:0,at:now,skipped:true,end:end,revision:markRevision(item),fallback:true,writerRevision:Self.writerRevision)))
                continue
            }
            found.targets.append(item)
            // First eligible closed work runs promptly at closure; do not add a queue-relative delay.
            if audience == .local, activity.status != "ready" {found.summaryDue.append(item)}
        }
        // claude/ready-1002 (owner): rewrites go newest first (today before past days is the caller's order).
        let newest=rewrites.sorted {($0.lastActivity,$0.key) > ($1.lastActivity,$1.key)}
        found.targets+=newest
        found.rewriteKeys=Set(newest.map(\.key))
        return found
    }
    /// fix/sx-all round 3: the revision a written mark records (`WrittenMark.revision`): the moment's input, the privacy
    /// settings it was read under, and who reads it (this Mac or the cloud).
    func markRevision(_ item:ScheduledWriterTarget) -> String {[item.inputRevision,item.policyRevision,audience == .cloud ? "cloud" : "local"].joined(separator:"|")}
    /// build/launch: whether a written mark's revision (`input|policy|audience`) differs from now in a way that asks for a
    /// rewrite on its own: the privacy settings or the audience moved, or the input moved while the moment did not grow
    /// (a moment rejoined, Forget). A moment that grew is judged by the growth rules only. A mark from before revisions
    /// (nil) counts as changed, as before.
    static func revisionChanged(_ marked:String?,_ now:String,grew:Bool) -> Bool {
        guard let marked else {return true}
        guard marked != now else {return false}
        let a=marked.split(separator:"|",omittingEmptySubsequences:false),b=now.split(separator:"|",omittingEmptySubsequences:false)
        guard a.count == 3,b.count == 3 else {return true}
        if a[1] != b[1] || a[2] != b[2] {return true}
        return !grew
    }
    /// New typed or submitted source IDs, compared to the previous canonical
    /// note when available. Time order alone cannot identify late-arriving
    /// evidence. A mark with no stored note retains the legacy count fallback.
    private func newTypedOrSent(_ activity:ActivityNote,after count:Int,now:Date) throws -> Bool {
        let previous=activity.previous.map {Set($0.actionIDs)}
        let added=previous.map {known in activity.actionIDs.filter {!known.contains($0)}} ?? Array(activity.actionIDs.dropFirst(count))
        for id in added {
            guard let action=try store.action(id,now:now) else {continue}
            if action.kind == "keyboard.text_input" || action.kind == "keyboard.submit" {return true}
        }
        return false
    }
    /// Idle-only, or no app and no bundle at all: a note would have nothing to say.
    private func nothingToWrite(_ activity:ActivityNote,now:Date) throws -> Bool {
        if (activity.bundles ?? [""]).isEmpty && activity.apps.allSatisfy({$0.isEmpty}) {return true}
        guard activity.actionIDs.count<=64 else {return false}
        for id in activity.actionIDs {
            // An action this can't read is never taken for idle: the moment is written (core decides what it holds).
            guard let action=try store.action(id,now:now) else {return false}
            if !["idle","session.started","session.ended"].contains(action.kind) {return false}
        }
        return true
    }
    /// Past days a catch-up batch looks at: the 7 days before today, newest first.
    func catchUpDays(now:Date,timezone:String) throws -> [String] {
        guard let zone=TimeZone(identifier:timezone) else {throw MemError.invalid("Invalid writer timezone")}
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=zone
        return try (1...Self.catchUpDays).compactMap {calendar.date(byAdding:.day,value:-$0,to:now)}.map {try DayScope.key($0,timezone:timezone)}
    }
    /// Checks and simple callers: today's moments as if the Mac had just gone idle (every moment that ended 30 seconds
    /// ago counts as closed), then the past 7 days' moments, newest day first. Every result is a moment; none is written yet.
    func discover(now:Date=Date(),timezone:String=TimeZone.current.identifier) throws -> [ScheduledWriterTarget] {
        let today=try DayScope.key(now,timezone:timezone)
        var out=try discoverDay(today,now:now,timezone:timezone,closedBy:now.addingTimeInterval(-30)).targets
        for day in try catchUpDays(now:now,timezone:timezone) {out+=try discoverDay(day,now:now,timezone:timezone).targets}
        return out
    }
    /// Re-check current revision immediately before preparing. Core separately
    /// fences prepare, every page, provider disclosure and final commit.
    /// `written` (Summarize Now, fix/resummarize): a moment that already has a note for this very input is current too,
    /// so the click writes a fresh note instead of doing nothing.
    func isCurrent(_ item:ScheduledWriterTarget,written:Bool=false) throws -> Bool {
        guard item.kind == "activity",try store.policy().revision==item.policyRevision else {return false}
        if written {
            let layers=try store.dayLayers(day:item.target.day,timezone:item.target.timezone)
            guard !layers.partial,let activity=layers.activities.first(where:{$0.id==item.target.activityID}) else {return false}
            return activity.inputRevision==item.inputRevision && audience.admits(activity)
        }
        let targets=try store.noteTargets(day:item.target.day,timezone:item.target.timezone,audience:audience)
        return targets.contains { target in
            target.status=="pending" && target.kind=="activity" && target.id==item.target.activityID && target.inputRevision==item.inputRevision
        }
    }
    /// Entries that can never be written now: a whole-day entry from before fix/sx-engine-battery, a moment core no
    /// longer lists, or one the running writer can never write.
    func obsoleteKeys(_ items:[ScheduledWriterTarget],now:Date=Date()) throws -> [String] {
        var cached:[String:(targets:[NoteTarget],fit:Set<String>?)]=[:],obsolete:[String]=[]
        for item in items.prefix(4) {
            guard item.kind == "activity" else {obsolete.append(item.key);continue}
            let scope=item.day+"|"+item.timezone
            if cached[scope]==nil {
                let targets=try store.noteTargets(day:item.day,timezone:item.timezone,audience:audience,now:now)
                let layers=try store.dayLayers(day:item.day,timezone:item.timezone,now:now)
                cached[scope]=(targets,layers.partial ? nil : try writable(layers,day:item.day,timezone:item.timezone,now:now))
            }
            let (targets,fit)=cached[scope]!
            // Incomplete assembly cannot establish absence.
            guard let fit,!targets.contains(where:{$0.status=="incomplete"}) else {continue}
            if !targets.contains(where:{$0.kind=="activity" && $0.id==item.activityID}) {obsolete.append(item.key);continue}
            // Work the running writer can never write is dropped too, so it neither sits pending nor fills the queue.
            if !fit.contains(item.activityID ?? "") {obsolete.append(item.key)}
        }
        return obsolete
    }
    /// Member count of a moment now (for its written mark).
    func actionCount(_ item:ScheduledWriterTarget) throws -> Int? {
        try extent(item)?.actions
    }
    /// Member count and last action of a moment now (its written mark: the rewrite rule measures growth from these).
    func extent(_ item:ScheduledWriterTarget) throws -> (actions:Int,end:Date?)? {
        guard let activity=try store.dayLayers(day:item.day,timezone:item.timezone).activities.first(where:{$0.id==item.activityID}) else {return nil}
        return (activity.actionIDs.count,timestamp(activity.end))
    }
}
